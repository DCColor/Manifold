//
//  WHEPFrameRouter.swift
//  Manifold
//
//  WHEP step 4 of 4: decoded CVPixelBuffers → SCREEN.
//
//  ── WHAT IS NEW HERE, AND WHAT IS REUSE ────────────────────────────────────────────────
//
//  Almost nothing is new. Everything downstream of `renderer.enqueue` is the hardened path
//  the file, NDI and SyntheticLiveSource paths already share, and it is NOT touched: the
//  ordered insert, the queue bound, LiveClock's control loop, the display tick, the shader.
//  This file only feeds them correctly. Specifically it reuses:
//
//    * LiveClock          — verbatim from SyntheticLiveSource: registerFrame(senderPTS:) on
//                           the source thread, now() into renderer.clock, updateDepth() from
//                           renderer.onDepthSample. Same three seams, same order.
//    * the promote        — VTPixelTransferSession into a pooled buffer, the shape NDIService
//                           uses to reach the shader's 10-bit sample domain (NDIService.swift,
//                           convertToDisplayFormat). Destination is x420 rather than NDI's
//                           x422 because the source is 4:2:0, so nothing is resampled.
//    * the CMSampleBuffer — CMSampleBufferCreateReadyWithImageBuffer, same as both.
//    * the takeover       — retire the current source, repoint the renderer's providers,
//                           mirroring NDIService.start() / SyntheticLiveSource.start().
//
//  The genuinely WHEP-specific part is one line: the sender timeline is the RTP 90 kHz clock,
//  which WHEPVideoDecoder has already unwrapped past the ~13-hour 32-bit wrap and handed over
//  as a CMTime. See `deliver`.
//
//  ── THREADING ──────────────────────────────────────────────────────────────────────────
//
//  Two threads, meeting at one lock — the NDIService colorLock pattern, for the same reason.
//
//    * `deliver` runs on ManifoldWHEPSession.decodeQueue (serial, USER_INITIATED — below the
//      render thread by design). It owns the promote session and pool exclusively, so those
//      need no lock. It calls LiveClock.registerFrame and MetalVideoRenderer.enqueue, both
//      documented background-safe (enqueue takes the priority-donating UnfairLock).
//    * `activate` / `deactivate` run on main (the ⌃⌥H / ⌃⌥⇧H triggers).
//
//  `stateLock` guards ONLY the (clock, renderer) pair those two exchange. It is never held
//  across enqueue: the references are copied out, the lock released, then the work is done.
//  That is deliberate — holding a lock across a call that takes the renderer's queue lock
//  would put a main-thread activate behind the render thread.
//

import CoreMedia
import CoreVideo
import Foundation
import ManifoldCore      // UnfairLock — the priority-donating lock both telemetry locks use
import QuartzCore
import VideoToolbox

final class WHEPFrameRouter {

    static let shared = WHEPFrameRouter()
    private init() {}

    /// The display path. Set once at startup (ContentView.onAppear), the SAME instance the file
    /// path, NDI and DeckLink use. Weak: ContentView owns it.
    weak var renderer: MetalVideoRenderer?

    /// Called on main just before WHEP takes the display, to retire whatever else is driving it
    /// (a loaded file). Set once by ContentView — this type has no engine handle. Identical role
    /// to NDIService.onWillActivateStream, and it exists for the same reason: one active source,
    /// so a file's frame pump and WHEP's push never both feed the renderer.
    var onWillActivateStream: (() -> Void)?

    // MARK: - Depth preset
    //
    // 0.400 s — MEASURED AGAINST A LIVE FEED, NOT TAKEN FROM THE PRESET GRID.
    //
    // ── THE MEASUREMENT ──────────────────────────────────────────────────────────────────────
    //
    // Live Cloudflare WHEP feed at 23.98 fps, on a VALID Profile build (-O for both Swift and C —
    // an earlier Debug-build measurement was invalidated and redone, which is why [BUILD] now
    // states the optimization level on the first line of every log):
    //
    //   targetDepth 0.200 → 70 genuine underruns in 118 s. Lateness distribution
    //                       p50 = 0.057 s, p90 = 0.121 s, max = 0.162 s (n = 70), i.e.
    //                       cushion needed >= 0.362 s. Presented fps dipped repeatedly to 19–23.
    //   targetDepth 0.400 → ZERO genuine underruns over 70 s. Presented fps flat at 24.0–24.2.
    //
    // The deficits are NETWORK burstiness, not local scheduling: the same distribution appears
    // under -O as under -Onone, which is what re-measuring after the invalidated run established.
    // 0.400 is the measured 0.362 requirement plus a small margin, not a round number chosen first.
    //
    // ── WHY THE OLD 0.200 WAS WRONG ──────────────────────────────────────────────────────────
    //
    // It came from docs/LIVECLOCK_PRESETS.md ("Stable"), whose grid was swept against a
    // no-B-frame HEVC file with an even decode cadence and INJECTED jitter far smaller than real
    // network conditions. Those presets are stale for live sources — the doc's own caveat said as
    // much, and this measurement is the evidence. (Cleaning up the preset grid is a separate task;
    // the synthetic harness still uses it and is deliberately untouched here.)
    //
    // RETUNING ON OTHER NETWORKS: ⌃⌥[ / ⌃⌥] step the live target by ±0.05 s, and
    // [WHEP-UNDERRUN] / [WHEP-JITTER] report the observed lateness distribution and the
    // running-max "cushion needed" that this number was derived from. Re-derive, don't guess.
    //
    // STARTUP == TARGET, deliberately and unchanged: the initial fill lands ON the setpoint
    // instead of draining to it at ±maxSlew — at 0.005/s a 0.2 s gap would take 40 s to close.
    // This one constant supplies both (see `activate`), so they cannot drift apart.
    private static let targetDepth = 0.400

    /// LiveClock's default rail, stated here as a named constant ONLY so the backlog accountant can
    /// compute its residual bound (residual is the integrated slew, so |residual| ≤ maxSlew × elapsed).
    /// The VALUE IS UNCHANGED — 0.005, LiveClock's default — and the diagnosis explicitly settles
    /// that it stays there: slew is a ppm-scale trim for crystal drift, and DISCARD is the
    /// instrument for backlog. See the block in `routeConfig` before touching it.
    private static let maxSlew = 0.005

    // MARK: - The route's per-source configuration
    //
    // Every value here was previously assigned inline in `activate()`. The NUMBERS and their
    // reasoning stayed in this file deliberately: they are WHEP measurements against a Cloudflare
    // feed, not properties of "a live source", and LiveDisplayRoute cannot know why any of them are
    // what they are. SRT will pass its own Config with its own numbers — SRTO_LATENCY already does
    // part of what `targetDepth` does here, so it will need its own measurement, not this one.
    private static var routeConfig: LiveDisplayRoute.Config {
        LiveDisplayRoute.Config(
            targetDepth: targetDepth,

            // ── SLEW RAIL — SETTLED. DO NOT RAISE. ─────────────────────────────────────────
            //
            // The measurement is IN, and it closes: 659 pictures in 25 s from a 23.98 fps sender is
            // 27.48 s of content, a 2.48 s surplus, which landed as 0.93 s flushed plus 1.59 s left
            // in the buffer = 2.52 s. The accounting balances. Transport is clean (seqGaps=0,
            // lost=0, reorder=0, AUs assembled == pictures decoded), PTS is correctly RTP-derived,
            // and the sender's clock is real-time locked (~90,100 tps) once the backlog drains.
            // There is NO clock drift and NO measurement bias to chase.
            //
            // WHICH MEANS THE RAIL WAS NEVER THE PROBLEM. ±0.5% is a drain rate of 0.005 s of
            // buffer per second — absorbing a 2.5 s connect backlog that way would take EIGHT
            // MINUTES. Raising it would not fix that; it would only make the correction visible on
            // moving video while still losing the race. Slew is a ppm-scale trim for CRYSTAL DRIFT.
            // DISCARD is the instrument for BACKLOG, and that is what the snap, the queue-full
            // re-anchor and the freeze guard provide. Since every overfill is finite (the sender
            // makes 23.98/s and the SFU cannot exceed that indefinitely), discarding is guaranteed
            // to converge.
            //
            // 0.005 is LiveClock's default, so this changes nothing — it is here to state the
            // conclusion at the place someone would otherwise reach for the knob.
            maxSlew: maxSlew,

            // SNAP-TO-LIVE, on for this transport (LiveClock defaults it off — see `snapEnabled`).
            // A WHEP sender that pauses and resumes leaves a slab of buffered latency the ±0.5%
            // slew cannot drain, and it happens on every pause in a review session. The knobs are
            // stated rather than left implicit because they are the two things worth tuning from
            // real behaviour: threshold is how deep is "too deep", debounce is how long we tolerate
            // it before jumping. Conservative starting values — a missed snap costs latency, a
            // false snap costs a visible jump, and the second is the worse failure.
            snapEnabled: true,
            // UNCHANGED at 0.2, but note the arithmetic moved with targetDepth: the snap fires
            // above ~0.6 s (0.400 target + 0.2 threshold) rather than ~0.4 s. That is still the
            // right shape — the threshold is "how far above target is a GROSS overfill the P-loop
            // cannot drain", which scales with the target rather than being an absolute depth — but
            // it does mean the buffer tolerates more absolute latency before snapping than it used
            // to. Revisit if [WHEP-BACKLOG] ever shows a connect backlog sitting between 0.4 s and
            // 0.6 s.
            snapThreshold: 0.2,      // snap above ~0.6 s with a 0.4 s target
            snapDebounce: 0.75,      // sustained, not a burst

            // Headroom above the shallow file-path bound (12) so the control loop can correct a
            // filling buffer before it saturates and drop-oldest fires — the value the sweep was
            // run against.
            maxQueued: 30,

            // ASSUMED, NOT READ — and this is a WHEP limitation, which is exactly why it is stated
            // here rather than defaulted inside LiveDisplayRoute. H.264 signals colorimetry in the
            // SPS VUI, and our RTP depacketizer does not parse it. 709 SDR video-range is the
            // honest default for a Constrained Baseline WHEP stream, and it is the SAME default NDI
            // starts on for a source that declares nothing (NDIService.start). Range is pinned
            // rather than read from the file transport's override, which describes a file that may
            // not even be loaded — again exactly as NDI does.
            //
            // AN SRT SOURCE MUST NOT COPY THIS. libavformat fills codecpar->color_primaries /
            // color_trc / color_space from the same VUI, so SRT can state the truth instead.
            colorimetry: .assumedRec709SDR)
    }

    // MARK: - Live state (main thread, except where noted)

    private let stateLock = NSLock()
    /// The clock, published to the decode queue under `stateLock`. nil = not active, which is how
    /// `deliver` cheaply drops frames that arrive before activate or after deactivate.
    ///
    /// OWNED HERE, NOT BY `route`. LiveDisplayRoute builds and configures the clock and hands it
    /// back; this lock and this field are unchanged, so `deliver`'s per-frame read is exactly the
    /// single lock acquisition it always was. See the header note in LiveDisplayRoute.
    private var liveClock: LiveClock?

    /// The shared live-push display plumbing: renderer save/restore, the LiveClock's four seams,
    /// queue bound, flush, colorimetry. Everything in it was written here first and moved out
    /// verbatim so SRT can use the same path rather than cloning it. What stayed behind is what is
    /// genuinely WHEP's: the measured `targetDepth`, the assumed colorimetry, and the RTP-specific
    /// drift accountant. The surplus ledger and the underrun accountant moved out too, into
    /// LiveDepthTelemetry — see the note at `telemetry`.
    private let route = LiveDisplayRoute()

    // MARK: - Promote state (decode queue only)

    private var transferSession: VTPixelTransferSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)
    /// One line the first time a frame is promoted (or found already 10-bit), then silence.
    private var reportedPromote = false

    // MARK: - Drift measurement (STEP 1: diagnose before changing slew)
    //
    // THE SYMPTOM: depth creeps 0.2 → 0.6 over minutes with `rate` PINNED at the +0.5% maxSlew
    // rail the whole time. A saturated controller is a controller being asked for more authority
    // than it has — but it is ALSO what a controller chasing a phantom looks like, and yesterday's
    // Δ/2 depth offset proves this pipeline can produce exactly that. Raising maxSlew to chase a
    // measurement artifact would hide the artifact and leave the real bug. So: measure first.
    //
    // (1) TRUE SENDER RATE, measured INDEPENDENTLY OF LIVECLOCK. For each frame we hold the
    //     sender's own timestamp (unwrapped RTP, seconds) and the host time it arrived. Define
    //
    //         offset(t) = hostArrival − senderPTS
    //
    //     If the sender's clock runs at ratio `r` relative to ours, senderPTS advances as r·t, so
    //     offset drifts at exactly (1 − r) per second. Therefore
    //
    //         senderRatio = 1 − d(offset)/dt
    //
    //     Nothing in that derivation touches the anchor, the rate, the queue, or the depth signal
    //     — it is a property of the TRANSPORT alone. That independence is the entire point: it is
    //     the reference the depth-derived numbers get checked against, so a bias in the depth path
    //     cannot contaminate it.
    //
    //     JITTER REJECTION: network + decode delay is additive and NON-NEGATIVE, so it can only
    //     push `offset` up, never down. The MINIMUM offset in a window is therefore the
    //     least-delayed frame — the cleanest available estimate of the true clock relationship.
    //     Differencing window minima rejects queueing jitter that would otherwise swamp a 0.8%
    //     signal (a ±50 ms delay spike across a 5 s window is ±1%, i.e. bigger than the effect).
    //
    // (2) IS THE DEPTH SIGNAL HONEST? With the controller running at `rate`, the buffer must fill
    //     at exactly
    //
    //         predictedCreep = senderRatio − rate      [seconds of depth per second]
    //
    //     NOT `senderRatio − 1`: the loop is already clawing back `rate − 1` of the mismatch, and
    //     comparing against the raw drift would condemn a CORRECTLY-behaving system. If observed
    //     creep matches this prediction, the drift is real and the fix is slew authority. If it
    //     does not, the residual IS the bias — in seconds per second, pointing straight at it.
    //
    // Guarded by `driftLock`, its own lock rather than `stateLock`: both threads write here (the
    // decode queue supplies sender timestamps, the render thread supplies depth), and this is
    // diagnostic bookkeeping that has no business sharing a lock with the activation state.
    //
    // UNFAIR LOCK, NOT NSLock — TEXTBOOK PRIORITY INVERSION, IDENTICAL TO THE ONE INSIDE
    // LiveDepthTelemetry. The
    // real-time CVDisplayLink render thread takes this EVERY DISPLAY TICK in `recordDepthForDrift`,
    // while the lower-priority USER_INITIATED decode queue holds it per frame in
    // `recordDriftSample`. `NSLock` is a pthread_mutex and does NOT boost its holder, so the decode
    // thread can be descheduled while holding it and stall the display tick for an unbounded
    // interval — the same shape as the live-path inversion `queueLock` was converted to fix, and
    // the same one the depth accountant carries. `os_unfair_lock` DONATES the blocked render thread's
    // priority to the holder, which is what dissolves it.
    //
    // The usage rule that makes this safe, and which all three critical sections already obeyed:
    // NOTHING SLOW UNDER THIS LOCK. A boosted holder must release promptly, so `recordDriftSample`
    // snapshots the closing window's values, unlocks, and only then computes the verdict strings and
    // emits `[WHEP-DRIFT]`. Note it also reads `clock.rate` (which takes LiveClock's lock) AFTER the
    // unlock — these two locks are never nested, in either order.
    private let driftLock = UnfairLock()
    /// Report cadence. Long enough that the min-offset difference is dominated by drift rather
    /// than by the residual jitter that survives the min filter.
    private static let driftWindow = 5.0
    private var driftWindowStartHost: Double = 0
    /// min(hostArrival − senderPTS) over the current window. `.infinity` until the first frame.
    private var driftWindowMinOffset: Double = .infinity
    /// The previous window's minimum + the host time it closed — the two ends of the difference.
    private var previousWindowMinOffset: Double?
    private var previousWindowEndHost: Double?
    /// Mean measured depth over the window, and the previous window's, for the creep rate.
    private var driftDepthSum = 0.0
    private var driftDepthN = 0
    private var previousWindowMeanDepth: Double?
    /// Set when a snap/degrade fires. A coarse clock action moves depth DISCONTINUOUSLY, so any
    /// window containing one has a creep number that describes the snap, not the drift. Such a
    /// window reports the sender rate (still valid — it is anchor-independent) and explicitly
    /// declines to report creep, rather than printing a number that means nothing.
    private var driftWindowHadSnap = false

    // MARK: - Depth telemetry (the surplus ledger + the underrun accountant)
    //
    // MOVED OUT, NOT DELETED. All of it — the ledger's residual derivation, the underrun
    // accountant's "cushion needed", the 1 s arrival bins, the all-time percentile summary — now
    // lives in LiveDepthTelemetry, unchanged, so SRT gets the same instrument on day one instead
    // of a second copy that drifts from this one. The log lines are byte-identical: the prefix is
    // a parameter and this instance passes "WHEP".
    //
    // WHAT STAYED BEHIND, deliberately: the DRIFT accountant below. It reports the sender's rate
    // in RTP 90 kHz ticks per second and answers a question about a WebRTC sender's crystal that
    // SRT's TSBPD scheduling reframes rather than inherits. Sharing it would have exported a
    // derivation that is only correct for this transport.
    //
    // `cushion` is the ANCHOR offset — the value `targetDepth` had at activate(), which is what
    // the ledger's algebra is written against. A runtime step of the live target is accounted for
    // separately, as a signed clock jump (see adjustTargetDepth).
    private let telemetry = LiveDepthTelemetry(prefix: "WHEP",
                                               cushion: WHEPFrameRouter.targetDepth,
                                               maxSlew: WHEPFrameRouter.maxSlew)

    /// The measured "cushion needed" a future adaptive-depth controller will consume — or nil when
    /// telemetry is compiled out. Forwarded rather than removed: this is the seam that work will
    /// read, and it should stay findable on the router rather than only on the accountant.
    var measuredCushionNeeded: Double? { telemetry.measuredCushionNeeded }

    // MARK: - Frame-flow telemetry (decode queue writes; depth fields written on the render thread)

    private var framesDelivered = 0
    private var framesEnqueued = 0
    private var promoteFailures = 0
    private var lastFlowLogHost: CFTimeInterval = 0
    private var lastFlowLogEnqueued = 0
    /// Latest depth sample, written on the render thread from onDepthSample and read on the decode
    /// queue by the 1 Hz flow log. A benign cross-thread read of telemetry-only scalars — the same
    /// concession SyntheticLiveSource makes for `lastQueueCount`.
    private var lastDepthSpan: Double = 0
    private var lastDepthCount: Int = 0

    // MARK: - Activation (main thread)

    /// WHEP takes the display. Mirrors NDIService.start() and SyntheticLiveSource.start(): retire
    /// the current source FIRST, then repoint the renderer's providers, then let frames flow.
    ///
    /// Ordering note: this is called from WHEPClient.connect() BEFORE the answer is applied, for the
    /// same reason the decoder is wired there — RTP can arrive the instant DTLS completes, and a
    /// frame that reaches `deliver` with no clock installed is simply dropped.
    func activate() {
        // Main-thread only, asserted the way WHEPClient asserts it rather than with @MainActor:
        // connect()/disconnect() are plain nonisolated methods (they hop to main explicitly, see
        // applyAnswer), so an actor annotation here would force an await into a synchronous path.
        dispatchPrecondition(condition: .onQueue(.main))
        guard let renderer else {
            NSLog("[WHEP] no renderer wired — decoded frames will be counted but not displayed")
            return
        }
        // Everything from the takeover through the colorimetry is LiveDisplayRoute's, in the exact
        // order it was written here: retire the current source, build the clock, save the
        // renderer's providers, install ours, wire the clock's four seams, bound the queue, flush,
        // state the colour. The clock comes BACK rather than staying there — see `liveClock`.
        let clock = route.activate(
            renderer: renderer,
            config: Self.routeConfig,
            // One active source: retire the loaded file before we take the renderer.
            retireCurrentSource: { self.onWillActivateStream?() },
            // RENDER THREAD, once per display tick. The clock call already happened inside the
            // route; `event` is non-nil only on a coarse action (snap / freeze-guard re-anchor).
            // This is the WHEP-specific measurement the shared type has no business holding.
            onDepth: { [weak self] sample, event in
                self?.lastDepthSpan = sample.spanSeconds   // telemetry only (see the field comment)
                self?.lastDepthCount = sample.count
                // Underrun detection, on the selection path where count == 0 is already known.
                self?.telemetry.recordSelection(count: sample.count, presented: sample.hadEligibleFrame)
                // Feed the creep side of the drift comparison. Averaged over the window rather than
                // sampled at its edges: the raw span is a per-frame sawtooth, and the creep we are
                // hunting (~0.003 s/s) is far smaller than one tooth.
                self?.recordDepthForDrift(span: sample.spanSeconds, snapped: event != nil)
                // Only on a coarse action, never per tick. The clock's lock is already released by
                // the time this value is in hand (it is a return, not a callback, precisely so a
                // log can't run inside the critical section).
                if let event {
                    self?.telemetry.recordClockJump(event.jumped)
                    Self.log(event)
                }
            },
            // DECODE THREAD (renderer.enqueue's caller), after the renderer's queue lock is
            // released. Each firing logs and is counted into `flushed` so the accountant can prove
            // convergence.
            onOverflow: { [weak self] event in
                self?.telemetry.recordClockJump(event.jumped)
                Self.log(event)
            })

        // Clear every per-stream measurement before the first frame of this stream can arrive —
        // the underrun detector's arming flag above all, so a reconnect's startup fill cannot be
        // logged as one giant bogus underrun. See LiveDepthTelemetry.reset().
        telemetry.reset()

        stateLock.lock(); liveClock = clock; stateLock.unlock()

        NSLog("[WHEP] display route ACTIVE — LiveClock target=%.3fs, maxQueued=30, colorimetry assumed 709 SDR",
              Self.targetDepth)
    }

    /// WHEP releases the display. Restores the file-path providers verbatim so playback can resume,
    /// and wipes the last streamed frame (there is usually nothing behind us — same call, same
    /// reason, as NDIService.disconnect).
    func deactivate() {
        dispatchPrecondition(condition: .onQueue(.main))
        stateLock.lock()
        let wasActive = liveClock != nil
        // Clears the clock's per-STREAM state, freeze-guard arming (`hasPresentedOnce`) included,
        // so a reconnect re-disarms the guard for its own startup fill rather than tripping it.
        // Belt and braces: `activate()` builds a BRAND-NEW LiveClock, so the flag also starts false
        // by construction on every connect — but reset() is the seam that is correct on its own.
        liveClock?.reset()
        liveClock = nil
        stateLock.unlock()
        guard wasActive else { return }

        // Restores savedClock / savedIsPaused verbatim, nils onDepthSample + onQueueOverflow (which
        // must not outlive the clock they drive) and maxQueuedOverride, and wipes the last streamed
        // frame. onDisplayTick is deliberately NOT touched — activate() nil'd it and a push source
        // has nothing to restore.
        route.deactivate(renderer: renderer)

        NSLog("[WHEP] display route released — file-playback clock restored")
    }

    /// Release the promote session + pool. DECODE QUEUE ONLY, and it must be scheduled behind every
    /// in-flight frame — WHEPClient does that in the same `decodeQueue.async` block that invalidates
    /// the decoder, for the same reason.
    func releaseResources() {
        transferSession = nil
        pixelBufferPool = nil
        poolSize = (0, 0)
        reportedPromote = false
        framesDelivered = 0
        framesEnqueued = 0
        promoteFailures = 0
        lastFlowLogHost = 0
        lastFlowLogEnqueued = 0

        // Drift state is per-STREAM: a reconnect gets a different sender, and differencing across
        // the gap would manufacture an enormous phantom drift from the discontinuity alone.
        driftLock.lock()
        driftWindowStartHost = 0
        driftWindowMinOffset = .infinity
        previousWindowMinOffset = nil
        previousWindowEndHost = nil
        driftDepthSum = 0
        driftDepthN = 0
        previousWindowMeanDepth = nil
        driftWindowHadSnap = false
        driftLock.unlock()

        telemetry.reset()
    }

    // MARK: - Runtime target adjustment (⌃⌥[ / ⌃⌥], main thread)

    /// Step the live clock's `targetDepth` by `delta`. The whole point is to A/B several cushion
    /// values inside ONE connection, so the underrun accountant's "cushion needed" figures are
    /// comparable against a moving setpoint rather than requiring a reconnect per value.
    ///
    /// The resulting clock jump is fed into the ledger: a target RAISE re-anchors backward, which is
    /// a negative coarse clock action, and leaving it out would trip the residual's OVER flag on a
    /// deliberate keypress. See `LiveDepthTelemetry.recordClockJump`.
    func adjustTargetDepth(by delta: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        stateLock.lock()
        let clock = liveClock
        stateLock.unlock()
        guard let clock else {
            NSLog("[WHEP] no live WHEP session — ⌃⌥[ / ⌃⌥] adjust the WHEP LiveClock target only")
            return
        }
        guard let change = clock.adjustTargetDepth(by: delta) else {
            NSLog("[WHEP] targetDepth already at the %@ (%.3fs) — not stepped",
                  delta > 0 ? "ceiling" : "floor", clock.currentTargetDepth)
            return
        }
        telemetry.recordClockJump(change.jumped)
    }

    // MARK: - Per-frame (decode queue)

    /// One decoded frame → the screen. Called from WHEPVideoDecoder.onDecodedFrame, on the decode
    /// queue, with the buffer VideoToolbox produced and the sender-timeline PTS it carried.
    ///
    /// `pts` IS the sender clock: WHEPVideoDecoder built it from the RTP 90 kHz timestamp, unwrapped
    /// across the 32-bit wrap by summing signed deltas (`Int32(bitPattern: new &- previous)`, which
    /// is wrap-correct in both directions) and rebased to zero at the first frame. Seconds of that
    /// is exactly what LiveClock.registerFrame wants — the same role the file PTS plays in
    /// SyntheticLiveSource — and LiveClock anchors it to the host clock on the first frame:
    ///
    ///     anchorSenderPTS = firstFrame.senderPTS
    ///     anchorHostTime  = CACurrentMediaTime() + startupDepth
    ///
    /// so a frame comes due `startupDepth` seconds after the first one arrived, then paced 1:1 with
    /// the sender timeline, with the control loop slewing `rate` to hold the buffer at target.
    func deliver(_ decoded: CVPixelBuffer, pts: CMTime) {
        framesDelivered += 1

        stateLock.lock()
        let clock = liveClock
        let renderer = self.renderer
        stateLock.unlock()
        // Not active (a frame racing activate, or arriving after deactivate). Counting it and
        // dropping it is correct — step 3b's counters keep working with no display route at all.
        guard let clock, let renderer else { logFlowIfDue(); return }

        let senderPTS = CMTimeGetSeconds(pts)
        guard senderPTS.isFinite else { logFlowIfDue(); return }

        // Sender-vs-receiver clock measurement. Deliberately placed BEFORE registerFrame, on the
        // raw arrival: this reading must describe the transport, not our correction of it.
        recordDriftSample(senderPTS: senderPTS, clock: clock)
        // Surplus accounting, same placement and same reason: content produced is a property of
        // the sender, and must be counted before we correct for it.
        //
        // ONE `now()` READ, SHARED. Both the ledger's inBuffer and the underrun lateness are
        // differences against the clock AT THIS INSTANT, so they must use the SAME reading — two
        // separate `now()` calls would be microseconds apart and would silently stop being
        // comparable. It is also one lock acquisition instead of two, on the same lock
        // `registerFrame` takes immediately below.
        let clockNow = clock.now()
        let target = clock.currentTargetDepth
        telemetry.recordArrival(senderPTS: senderPTS, clockNow: clockNow)
        // Closes a starvation episode the render thread opened, if one is open. No-op otherwise,
        // which is the overwhelmingly common case.
        telemetry.closeUnderrunIfOpen(senderPTS: senderPTS, clockNow: clockNow, target: target)

        // Sender timeline → presentation timeline. Identity at rate 1.0; a genuine remap once the
        // control loop has slewed. Register BEFORE the promote so the anchor is established from
        // the arrival instant rather than after a conversion.
        let presentationPTS = clock.registerFrame(senderPTS: senderPTS)

        guard let promoted = promoteIfNeeded(decoded) else {
            promoteFailures += 1
            logFlowIfDue()
            return
        }
        // Tag the buffer every downstream consumer actually reads (shader matrix, layer colorspace,
        // scopes, EDR gate). A pooled buffer starts untagged and VT's attachment propagation is
        // measured behavior rather than a documented contract, so tagging the OUTPUT last is the
        // ordering that holds either way — NDIService.tagOutput's reasoning, verbatim.
        NDIColorInfo.assumedRec709.apply(to: promoted)

        guard let sampleBuffer = Self.makeSampleBuffer(
                promoted,
                pts: CMTime(seconds: presentationPTS, preferredTimescale: 1_000_000)) else {
            logFlowIfDue()
            return
        }

        renderer.enqueue(sampleBuffer)
        framesEnqueued += 1
        logFlowIfDue()
    }

    // MARK: - Promote (decode queue)

    /// 8-bit → the renderer's 10-bit sample domain, via the SAME VTPixelTransferSession shape NDI
    /// uses (NDIService.convertToDisplayFormat). Destination is x420 — 10-bit biplanar 4:2:0 — so
    /// 4:2:0 in becomes 4:2:0 out with no chroma resample; the 8→10 promotion is an exact ×4 code
    /// shift, not a filter. That is the format the file path already produces and the format
    /// PassthroughShader.metal's range-expansion constants (kCodeMax = 1023.984375) assume.
    ///
    /// A NO-OP when VideoToolbox already gave us 10-bit: WHEPVideoDecoder REQUESTS x420 output and
    /// only falls back to VT's native 8-bit choice if the session refuses it. When the request
    /// succeeds there is nothing to promote and the decoded buffer goes straight through, which is
    /// why this is `promoteIfNeeded` and not an unconditional conversion.
    private func promoteIfNeeded(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        if sourceFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || sourceFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
            if !reportedPromote {
                reportedPromote = true
                NSLog("[WHEP] decoded as %@ — already in the renderer's 10-bit domain, no promote needed",
                      WHEPVideoDecoder.formatName(sourceFormat))
            }
            return source
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)

        if transferSession == nil {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                      pixelTransferSessionOut: &session)
            guard status == noErr, let session else {
                NSLog("[WHEP] VTPixelTransferSessionCreate failed (%d) — no picture", status)
                return nil
            }
            transferSession = session
        }
        guard let transferSession else { return nil }

        if pixelBufferPool == nil || poolSize != (width, height) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
            ]
            // MinimumBufferCount matches SyntheticLiveSource's pool: maxQueued (30) + the in-flight
            // frame + lead. A pool that recycles a small FIXED IOSurface set is what keeps the render
            // thread re-mapping known surfaces instead of first-mapping a fresh one every frame.
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 34]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                                 attrs as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                NSLog("[WHEP] CVPixelBufferPoolCreate failed (%d) — no picture", status)
                return nil
            }
            pixelBufferPool = pool
            poolSize = (width, height)
        }
        guard let pixelBufferPool else { return nil }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &destination)
                == kCVReturnSuccess, let destination else { return nil }

        // Tag the SOURCE before the transfer, so VT converts from a buffer whose colorimetry is
        // stated rather than absent. (The output is re-tagged after, in `deliver` — see there.)
        NDIColorInfo.assumedRec709.apply(to: source)

        let status = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination)
        guard status == noErr else {
            NSLog("[WHEP] pixel transfer failed (%d)", status)
            return nil
        }

        if !reportedPromote {
            reportedPromote = true
            NSLog("[WHEP] promoting %@ → 'x420' (10-bit 4:2:0) at %dx%d — the shader's sample domain",
                  WHEPVideoDecoder.formatName(sourceFormat), width, height)
        }
        return destination
    }

    // MARK: - Drift measurement (decode queue + render thread, under driftLock)

    /// Fold one frame's (senderPTS, arrival) pair into the current window, and close the window
    /// when it is due. Decode queue. See the field block above for the derivation.
    private func recordDriftSample(senderPTS: Double, clock: LiveClock) {
        #if DEBUG || MANIFOLD_TELEMETRY
        let host = CACurrentMediaTime()
        let offset = host - senderPTS

        driftLock.lock()
        if driftWindowStartHost == 0 {
            driftWindowStartHost = host
            driftWindowMinOffset = offset
            driftLock.unlock()
            return
        }
        driftWindowMinOffset = min(driftWindowMinOffset, offset)
        guard host - driftWindowStartHost >= Self.driftWindow else {
            driftLock.unlock()
            return
        }

        // Close the window: snapshot everything, re-arm, then report OUTSIDE the lock.
        let minOffset = driftWindowMinOffset
        let previousMin = previousWindowMinOffset
        let previousEnd = previousWindowEndHost
        let meanDepth = driftDepthN > 0 ? driftDepthSum / Double(driftDepthN) : nil
        let previousMeanDepth = previousWindowMeanDepth
        let hadSnap = driftWindowHadSnap

        previousWindowMinOffset = minOffset
        previousWindowEndHost = host
        previousWindowMeanDepth = meanDepth
        driftWindowStartHost = host
        driftWindowMinOffset = .infinity
        driftDepthSum = 0
        driftDepthN = 0
        driftWindowHadSnap = false
        driftLock.unlock()

        // First window has no predecessor to difference against.
        guard let previousMin, let previousEnd else { return }
        let dt = host - previousEnd
        guard dt > 0 else { return }

        // senderRatio = 1 − d(offset)/dt. > 1 means the SENDER is fast: it produces media time
        // faster than we consume it at unity, so the buffer fills — the creep direction observed.
        let senderRatio = 1.0 - (minOffset - previousMin) / dt
        let senderTicksPerSecond = 90_000.0 * senderRatio
        let driftPercent = (senderRatio - 1.0) * 100.0

        // `rate` is written under the clock's lock on the render thread and read here unlocked —
        // the same benign telemetry race `logFlowIfDue` already accepts. Taking the clock's lock
        // from the decode queue to read one Double for a log line would be the worse trade.
        let rate = clock.rate
        let atRail = abs(abs(rate - 1.0) - clock.maxSlew) < 1e-6
        // What the buffer MUST do given a sender at `senderRatio` and a clock running at `rate`.
        let predictedCreep = senderRatio - rate

        // Deferred-initialized lets (assigned exactly once on every path) rather than vars —
        // the compiler would flag a never-mutated var.
        let verdict: String
        let creepText: String
        if hadSnap {
            // Honest refusal: the window contains a discontinuity, so its creep describes the
            // snap. The sender rate above is still valid — it never touches the anchor.
            creepText = "n/a (snap in window)"
            verdict = "creep not comparable this window"
        } else if let meanDepth, let previousMeanDepth {
            let observedCreep = (meanDepth - previousMeanDepth) / dt
            let residual = observedCreep - predictedCreep
            creepText = String(format: "%+.4f s/s observed vs %+.4f predicted (residual %+.4f)",
                               observedCreep, predictedCreep, residual)
            // Tolerance: the larger of an absolute floor (below which we are reading window-to-
            // window noise, not a bias) and a relative share of the predicted magnitude.
            let tolerance = max(0.0008, abs(predictedCreep) * 0.35)
            verdict = abs(residual) <= tolerance
                ? "REAL DRIFT — creep matches the measured sender rate"
                : "MISMATCH — creep does not follow the sender rate; suspect measurement bias"
        } else {
            creepText = "n/a (no depth samples)"
            verdict = "creep unavailable"
        }

        // `need` is the headline number STEP 2 is waiting on: the slew the loop must be ABLE to
        // reach just to break even. Whatever maxSlew is chosen must exceed this, with margin on
        // top for the loop to have correction authority left over rather than sitting on a new rail.
        NSLog("""
              [WHEP-DRIFT] senderRate=%.0f tps (%+.3f%% vs receiver) | clockRate=%.4f (%+.3f%%%@) \
              | depthCreep=%@ | %@ | need maxSlew ≥ %.3f%% + margin
              """,
              senderTicksPerSecond, driftPercent,
              rate, (rate - 1.0) * 100.0, atRail ? ", RAIL" : "",
              creepText, verdict, abs(driftPercent))
        #endif
    }

    /// Render thread. Accumulates the window's mean depth and latches whether a coarse clock
    /// action occurred inside it.
    private func recordDepthForDrift(span: Double, snapped: Bool) {
        #if DEBUG || MANIFOLD_TELEMETRY
        driftLock.lock()
        driftDepthSum += span
        driftDepthN += 1
        if snapped { driftWindowHadSnap = true }
        driftLock.unlock()
        #endif
    }

    // MARK: - Latency-control reporting (render thread, coarse actions only)

    /// One line per coarse clock action. These are RARE and each one is a real event in the
    /// session's latency story, so they are logged unconditionally rather than folded into the
    /// 1 Hz flow line — a snap that fires the moment the sender resumes should be visible at that
    /// moment, next to the [LIVECLOCK] line whose depth it just changed.
    private static func log(_ event: LiveClock.Event) {
        #if DEBUG || MANIFOLD_TELEMETRY
        switch event {
        case .snapped(let snap):
            NSLog("[WHEP] snap-to-live: flushed %.3fs excess (depth %.3f → %.3f) after %.2fs sustained overfill",
                  snap.excess, snap.depthBefore, snap.depthAfter, snap.sustainedFor)
        case .freezeGuard(let fg):
            // The safety net fired. This should be RARE — it means the clock reached a position it
            // could not leave on its own, and every occurrence is worth explaining rather than
            // counting. Distinct prefix from the queue-full line below.
            NSLog("""
                  [WHEP] FREEZE-GUARD: clock had fallen behind the entire queue — no eligible \
                  frame for %d ticks / %.3fs with %d queued (oldest +%.3fs ahead). Re-anchored \
                  +%.3fs (depth %.3f → %.3f).
                  """, fg.ticks, fg.heldFor, fg.queued, fg.oldestAhead,
                  fg.jumped, fg.depthBefore, fg.target)
        case .overflowReanchor(let ov):
            // Expected, repeatedly, during a connect backlog drain — NOT a fault. One line each,
            // no debounce, so the sequence can be counted in the log and confirmed to stop once
            // [WHEP-BACKLOG] shows surplus going flat.
            NSLog("[WHEP] queue-full re-anchor: over-buffered at count=%d — flushed %.3fs (depth %.3f → %.3f)",
                  ov.queued, ov.jumped, ov.depthBefore, ov.target)
        }
        #endif
    }

    // MARK: - Helpers

    /// Wrap a pixel buffer in a ready CMSampleBuffer at `pts`.
    ///
    /// NOT SHAREABLE WITH NDIService / SyntheticLiveSource, despite the same three CoreMedia calls
    /// — this comment used to claim "same call, same arguments" and that was wrong. The ARGUMENTS
    /// differ in ways that are not cosmetic:
    ///   * NDIService takes `pts: Double` and builds `CMTime(seconds:preferredTimescale: 90_000)`
    ///     internally; this one takes a CMTime the caller built at timescale 1_000_000.
    ///   * SyntheticLiveSource passes a REAL duration (not .invalid) and `allocator: nil`.
    /// Unifying them would re-quantise one path's PTS, and those PTS values feed the renderer's
    /// ordered insert and its median inter-frame-Δ tracking — i.e. the depth signal LiveClock
    /// regulates. Left as three, deliberately.
    ///
    /// Duration is .invalid:
    /// RTP does not carry one, the renderer selects on PTS alone, and a fabricated duration would be
    /// a guess nothing reads.
    ///
    /// DTS is .invalid, and NOT because the sender has no B-frames — this comment used to say that,
    /// which would make it wrong the moment a reordering stream arrived (SRT). The real reason is
    /// that by this point there is no decode order left to describe: the input was a compressed
    /// access unit whose DTS said when to DECODE it, and what is being wrapped here is the decoded
    /// picture that came out. Its only remaining property is when to SHOW it, which is the PTS.
    /// Nothing downstream reads the output DTS, and there is no honest value to put in it.
    private static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    /// 1 Hz `[WHEP-FLOW]`. This is the staged-diagnosis line: if no pixels appear, it says WHICH
    /// stage is empty. delivered > 0 with enqueued == 0 means the promote or the sample build is
    /// failing (promoteFail counts the first). Both climbing with depth/count at zero means frames
    /// reach the queue but the clock never lets them come due. Both climbing with a healthy depth
    /// and still no picture puts the problem downstream of enqueue, in the renderer.
    ///
    /// LiveClock prints its own `[LIVECLOCK] depth/target/rate/err` line at the same cadence; this
    /// one deliberately repeats depth/count so the producer and consumer sides can be read as a pair
    /// without interleaving two logs. Decode queue only.
    private func logFlowIfDue() {
        #if DEBUG || MANIFOLD_TELEMETRY
        let now = CACurrentMediaTime()
        if lastFlowLogHost == 0 { lastFlowLogHost = now; lastFlowLogEnqueued = framesEnqueued; return }
        let elapsed = now - lastFlowLogHost
        guard elapsed >= 1.0 else { return }
        let rate = Double(framesEnqueued - lastFlowLogEnqueued) / elapsed
        lastFlowLogHost = now
        lastFlowLogEnqueued = framesEnqueued

        stateLock.lock(); let clockRate = liveClock?.rate; stateLock.unlock()
        NSLog("[WHEP-FLOW] enqueued=%.1f/s (total=%d, delivered=%d, promoteFail=%d) | depth=%.3fs count=%d rate=%@",
              rate, framesEnqueued, framesDelivered, promoteFailures,
              lastDepthSpan, lastDepthCount,
              clockRate.map { String(format: "%.4f", $0) } ?? "inactive")
        #endif
    }
}
