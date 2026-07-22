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

#if DEBUG
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
    /// instrument for backlog. See the block at the assignment site before touching it.
    private static let maxSlew = 0.005

    // MARK: - Live state (main thread, except where noted)

    private let stateLock = NSLock()
    /// The clock, published to the decode queue under `stateLock`. nil = not active, which is how
    /// `deliver` cheaply drops frames that arrive before activate or after deactivate.
    private var liveClock: LiveClock?

    /// Renderer providers saved at activate, restored verbatim at deactivate — SyntheticLiveSource's
    /// discipline rather than NDI's (NDI leaves its clock installed on disconnect). We restore
    /// because a file may be sitting behind us and can resume the moment WHEP goes away.
    private var savedClock: (() -> Double)?
    private var savedIsPaused: (() -> Bool)?

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
    // UNFAIR LOCK, NOT NSLock — TEXTBOOK PRIORITY INVERSION, IDENTICAL TO `backlogLock`. The
    // real-time CVDisplayLink render thread takes this EVERY DISPLAY TICK in `recordDepthForDrift`,
    // while the lower-priority USER_INITIATED decode queue holds it per frame in
    // `recordDriftSample`. `NSLock` is a pthread_mutex and does NOT boost its holder, so the decode
    // thread can be descheduled while holding it and stall the display tick for an unbounded
    // interval — the same shape as the live-path inversion `queueLock` was converted to fix, and
    // the same one `backlogLock` carries. `os_unfair_lock` DONATES the blocked render thread's
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

    // MARK: - Surplus accountant (the convergence proof)
    //
    // WHAT IT PROVES. Cloudflare's SFU delivers a BACKLOG on connect, faster than real time, and
    // every fix here rests on that surplus being FINITE — the sender makes 23.98 pictures/s and the
    // SFU cannot exceed that indefinitely, so discarding is guaranteed to converge. This ledger is
    // what turns that argument into an observation: SURPLUS MUST GO FLAT once the backlog drains.
    // A surplus that keeps climbing after the first few seconds would falsify the whole diagnosis.
    //
    // THE LEDGER. Content is measured from the RTP sender timeline (`lastSenderPTS − firstSenderPTS`)
    // rather than an assumed fps — it is the sender's own statement of how much media it produced,
    // and it is the same quantity LiveClock is anchored to.
    //
    //     surplus  = content − wall            (media produced beyond real time)
    //     netJump  = Σ every coarse clock jump, SIGNED (see below)
    //     inBuffer = lastSenderPTS − now()     (media sitting AHEAD of the presentation clock)
    //
    // WHY THERE IS A CUSHION TERM. At rate 1.0 with no jump the anchor gives, identically,
    //
    //     depth(T) = lastPTS − now(T) = (content − wall) + startupDepth = surplus + startupDepth
    //
    // because `now()` is anchored `startupDepth` BEHIND the first frame on purpose. That cushion
    // (0.400 s — see the `targetDepth` constant) is deliberately-injected latency, not surplus, so a
    // ledger reading `surplus − netJump − inBuffer` rests at a constant −startupDepth and never
    // closes. Carrying the cushion explicitly makes it close:
    //
    //     residual = surplus + cushion − netJump − inBuffer
    //
    // ── WHY inBuffer IS MEASURED HERE AND NOT TAKEN FROM THE RENDERER ──────────────────────────
    //
    // It used to be `lastDepthSpan`, the renderer's depth sample. That made the residual a LIE, and
    // the arithmetic of why is worth keeping: with no backlog `surplus ≈ 0`, so the printed residual
    // collapsed to `cushion − inBuffer` — measured at the then-current 0.200 target it sat at ~+0.2
    // whenever the buffer was empty and ~0.0
    // whenever it was at target, faithfully re-reporting the current depth while claiming to be a
    // convergence proof. The renderer's span is the wrong quantity for this ledger three times over:
    // it is `max(0, …)`-CLAMPED (so an empty queue reads 0 when the true lead is strongly NEGATIVE —
    // exactly the case worth seeing), it carries a `+Δ/2` half-frame correction the ledger never
    // asked for, and it is sampled on a different thread at a different instant.
    //
    // Measuring `lastSenderPTS − clock.now()` right here — same PTS timeline as `content`, same
    // instant, UNCLAMPED — makes every other term cancel identically. With
    // `now(h) = firstPTS − cushion + ∫rate·dt + Σjumps`:
    //
    //     inBuffer = content + cushion − ∫rate·dt − netJump
    //     residual = (content − wall) + cushion − netJump − inBuffer  =  ∫rate·dt − wall
    //
    // WHICH IS THE INTEGRATED SLEW, EXACTLY — and nothing else. `rate` is hard-clamped to
    // 1 ± maxSlew, so |residual| ≤ maxSlew × wall is a REAL bound, not a fitted one, and OVER can
    // only mean a clock jump happened that is not in `netJump`. That is a bug, and it is the only
    // thing the flag should ever fire on. A small epsilon covers read-skew between `senderPTS` and
    // `now()` plus float error; it is stated, not tuned to keep the flag quiet.
    //
    // Unclamped `inBuffer` also goes NEGATIVE during an underrun — the newest frame is already
    // overdue — which is the truthful reading and directly useful next to [WHEP-UNDERRUN].
    //
    // WHY netJump IS SIGNED. A manual `targetDepth` RAISE (⌃⌥]) re-anchors the clock BACKWARD to
    // acquire the extra cushion immediately. That is a coarse clock action like any other, but a
    // negative one. Accumulating only positive discards would put every keypress outside the ledger
    // and trip OVER on a deliberate action. Discards are positive, added cushion is negative, and
    // the label says `netJump` so a negative total reads correctly rather than as a nonsensical
    // negative "flushed".
    //
    // Guarded by `backlogLock` — its own lock rather than `driftLock`, which answers a different
    // question (is the SENDER's clock drifting) and is read on a different cadence. Written from
    // BOTH threads: the decode queue supplies sender timestamps and queue-full jumps, the render
    // thread supplies snap/freeze-guard jumps and (every display tick) the underrun accounting.
    //
    // UNFAIR LOCK, NOT NSLock — THE SAME INVERSION THE ENQUEUE PATH ALREADY HIT. The real-time
    // CVDisplayLink render thread takes this every tick in `recordSelection`, while the
    // USER_INITIATED decode queue holds it to fold arrivals into the ledger. `NSLock` is a
    // pthread_mutex and does NOT boost its holder, so the decode thread can be descheduled holding
    // it and stall the display tick for an unbounded interval — the exact shape of the live-path
    // inversion `queueLock` was converted to fix. `os_unfair_lock` DONATES the blocked render
    // thread's priority to the holder, which dissolves it.
    //
    // The usage rule that makes this safe: NOTHING SLOW UNDER THIS LOCK. Every site snapshots the
    // state it needs, unlocks, and only then formats and emits its NSLog — a boosted holder must
    // release promptly, and an `NSLog` inside the critical section would defeat the whole point.
    private let backlogLock = UnfairLock()
    private static let backlogWindow = 5.0
    /// Read-skew + float slop allowed on top of the slew bound before the residual is flagged OVER.
    private static let residualEpsilon = 0.002
    /// First frame's sender PTS + the host time it arrived — the two origins the ledger measures from.
    private var backlogFirstSenderPTS: Double?
    private var backlogFirstHost: Double = 0
    /// Newest sender PTS seen. `content = backlogLastSenderPTS − backlogFirstSenderPTS`.
    private var backlogLastSenderPTS: Double = 0
    /// Pictures decoded since the stream began (the headline count).
    private var backlogPictures = 0
    /// Cumulative SIGNED presentation time crossed by coarse clock actions: positive = discarded
    /// (snap / freeze-guard / queue-full), negative = deliberately added cushion (manual target raise).
    private var backlogNetJump: Double = 0
    private var backlogLastLogHost: CFTimeInterval = 0

    /// Accumulate one coarse clock jump. SIGNED — see `backlogNetJump`. Called from the RENDER
    /// thread (snap, freeze-guard), the DECODE thread (queue-full re-anchor) and MAIN (manual
    /// target step), hence the lock.
    private func recordClockJump(_ seconds: Double) {
        guard seconds.isFinite, seconds != 0 else { return }
        backlogLock.lock()
        backlogNetJump += seconds
        backlogLock.unlock()
    }

    // MARK: - Underrun accounting (how much cushion is ACTUALLY required)
    //
    // THE MISSING MEASUREMENT. The renderer's depth signal is `max(0, …)`-clamped, so a 50 ms
    // shortfall and a 400 ms shortfall both read `depth=0.000 count=0`. That makes every underrun
    // look identical and gives no basis whatever for choosing `targetDepth` — the number gets
    // guessed instead of measured. This measures the TRUE deficit.
    //
    // WHY IT SPANS TWO THREADS. The two halves of the measurement only exist in different places
    // and neither alone gives the deficit:
    //
    //   * RENDER THREAD (the selection path, via onDepthSample ← performDisplayTick): `count == 0`
    //     at a display tick is already known there, captured in the same `queueLock` critical
    //     section as selection. Opens the episode and counts starved ticks.
    //   * DECODE THREAD (`deliver`, on arrival): only here do the arriving frame's PTS and the
    //     clock's current position coexist. Closes the episode and computes the lateness.
    //
    // THE DERIVATION — "cushion needed". At the arrival instant the clock reads N = now() and the
    // frame carries PTS P:
    //
    //     lateness  L = N − P        (positive ⇒ the frame was already overdue when it landed)
    //
    // The cushion IS the clock's backward offset: a `targetDepth` larger by Δ means `now()` reads
    // N − Δ at that same instant, so the frame would have been on time iff N − Δ ≤ P, i.e. iff
    // Δ ≥ L. Therefore
    //
    //     cushionNeeded(event) = currentTargetDepth + max(0, L)
    //
    // read from the LIVE target (⌃⌥[ / ⌃⌥] steps it), not the value configured at init.
    //
    // L ≤ 0 IMPLIES NO INCREASE IS REQUIRED: the queue reached zero margin but nothing was actually
    // missed. Real, worth counting, but not a reason to add latency — only genuine misses move the
    // number.
    //
    // SELF-CHECK. The queue empties when `now` crosses the last frame's PTS, so
    // `starvedDuration ≈ L + Δframe`. An underrun SHORTER than one frame interval (41.7 ms at
    // 23.98) must therefore have L ≤ 0. A sub-frame-interval starvation reporting a large positive
    // L would mean this measurement is broken, and the log carries both numbers so that is visible
    // rather than assumed.
    //
    // ARMING. `underrunArmed` gates everything, and is set on the first tick that actually presents
    // a frame. Before that the queue is empty at EVERY tick by construction (the startup fill), so
    // an unarmed detector would log one enormous bogus episode on every connect. Per-STREAM, for
    // the same reason as LiveClock's `hasPresentedOnce`: on a RECONNECT a still-armed detector does
    // exactly that again across the new stream's fill. Cleared in `resetStreamTelemetry()`.
    //
    // Shares `backlogLock` with the ledger: same 5 s window boundary, same two writer threads, and
    // the [WHEP-JITTER] rollup is emitted alongside [WHEP-BACKLOG] from one consistent snapshot.

    /// False until a frame has actually been presented on this stream. See ARMING above.
    private var underrunArmed = false
    /// Host time the current starvation episode began; nil when the queue is not empty.
    private var underrunSince: CFTimeInterval?
    /// Display ticks observed with an empty queue in the current episode.
    private var underrunTicks = 0
    /// Running max of `cushionNeeded` across the whole stream — the figure that sets `targetDepth`.
    private var underrunCushionNeededMax: Double = 0
    /// Every positive lateness seen this stream, for the all-time shape. Bounded so a long session
    /// cannot grow it without limit; the running max above is unaffected by the bound.
    private var underrunAllLatenessValues: [Double] = []
    private static let underrunLatenessCap = 512
    /// Positive latenesses observed in the CURRENT 5 s window, listed verbatim in the rollup.
    private var underrunWindowLateness: [Double] = []
    /// Episodes (including L ≤ 0 ones) in the current window and across the stream.
    private var underrunWindowCount = 0
    private var underrunTotalCount = 0

    /// Arrival-rate bins: pictures decoded per 1 s sub-window, so the rollup can report the min/max
    /// arrival rate WITHIN the 5 s window. A window mean would hide exactly the burstiness at issue
    /// — 15 in one second and 32 in the next averages to a healthy-looking 23.5.
    private var arrivalBinStart: CFTimeInterval = 0
    private var arrivalBinCount = 0
    private var arrivalWindowMin = Int.max
    private var arrivalWindowMax = 0

    /// RENDER THREAD, from the selection path. One display tick's queue occupancy.
    /// `count == 0` opens or extends a starvation episode; anything else closes the run and arms.
    private func recordSelection(count: Int, presented: Bool) {
        backlogLock.lock()
        if presented { underrunArmed = true }
        if count == 0, underrunArmed {
            if underrunSince == nil {
                underrunSince = CACurrentMediaTime()
                underrunTicks = 0
            }
            underrunTicks += 1
        }
        backlogLock.unlock()
    }

    /// DECODE THREAD, on arrival. Closes an open starvation episode and emits its line.
    /// `senderPTS` is the presentation PTS (identity at this seam) and `clockNow` is `now()` read
    /// at the same instant — the pair the lateness is computed from.
    private func closeUnderrunIfOpen(senderPTS: Double, clockNow: Double, target: Double) {
        backlogLock.lock()
        guard let since = underrunSince, clockNow.isFinite else {
            backlogLock.unlock()
            return
        }
        let host = CACurrentMediaTime()
        let starved = host - since
        let ticks = underrunTicks
        underrunSince = nil
        underrunTicks = 0

        let lateness = clockNow - senderPTS
        let cushionNeeded = target + max(0, lateness)
        underrunWindowCount += 1
        underrunTotalCount += 1
        underrunCushionNeededMax = max(underrunCushionNeededMax, cushionNeeded)
        if lateness > 0 {
            underrunWindowLateness.append(lateness)
            if underrunAllLatenessValues.count < Self.underrunLatenessCap {
                underrunAllLatenessValues.append(lateness)
            }
        }
        backlogLock.unlock()

        NSLog("""
              [WHEP-UNDERRUN] queue empty for %.3fs, %d ticks starved, recovered when frame \
              arrived %+.3fs late vs clock — would have needed cushion >= %.3fs (target now %.3fs)
              """, starved, ticks, lateness, cushionNeeded, target)
    }

    /// Fold one arrival into the 1 s arrival bins. Decode queue, called under `backlogLock`.
    private func foldArrivalBinLocked(host: CFTimeInterval) {
        if arrivalBinStart == 0 { arrivalBinStart = host }
        // CLOSE ELAPSED BINS FIRST, THEN COUNT. Counting before advancing would attribute this
        // arrival to whichever bin happened to still be open — so a 3 s gap would dump the frames
        // from BEFORE the gap plus this one into the first bin and record the gap's seconds as
        // separate zeros afterwards. Advancing first puts the arrival in the bin its timestamp
        // actually falls in, and the intervening zero-count bins are then truthful: no frames
        // arrived in those seconds, which is precisely the starvation the min is meant to expose.
        while host - arrivalBinStart >= 1.0 {
            arrivalWindowMin = min(arrivalWindowMin, arrivalBinCount)
            arrivalWindowMax = max(arrivalWindowMax, arrivalBinCount)
            arrivalBinStart += 1.0
            arrivalBinCount = 0
        }
        arrivalBinCount += 1
    }

    /// Fold one arriving picture into the ledger and emit the 5 s lines when due. Decode queue.
    ///
    /// `clockNow` is `now()` read at this same instant on this same thread — see the inBuffer
    /// discussion in the ledger block above for why it must be measured here rather than taken
    /// from the renderer's clamped span.
    private func recordBacklogSample(senderPTS: Double, clockNow: Double) {
        let host = CACurrentMediaTime()

        backlogLock.lock()
        backlogPictures += 1
        backlogLastSenderPTS = senderPTS
        foldArrivalBinLocked(host: host)
        if backlogFirstSenderPTS == nil {
            backlogFirstSenderPTS = senderPTS
            backlogFirstHost = host
            backlogLastLogHost = host
            backlogLock.unlock()
            return
        }
        guard host - backlogLastLogHost >= Self.backlogWindow, let firstPTS = backlogFirstSenderPTS else {
            backlogLock.unlock()
            return
        }
        backlogLastLogHost = host
        let pictures = backlogPictures
        let content = senderPTS - firstPTS
        let wall = host - backlogFirstHost
        let netJump = backlogNetJump

        // Snapshot + re-arm the per-window jitter/underrun state in the SAME critical section, so
        // the two lines below describe one consistent window with no arrivals lost between them.
        let windowLateness = underrunWindowLateness
        let windowUnderruns = underrunWindowCount
        let cushionNeededMax = underrunCushionNeededMax
        let totalUnderruns = underrunTotalCount
        let allLateness = underrunAllLatenessValues
        // A window with no closed bin yet (fewer than 1 s of arrivals) leaves min at Int.max.
        let arrivalsMin = arrivalWindowMin == Int.max ? arrivalBinCount : arrivalWindowMin
        let arrivalsMax = max(arrivalWindowMax, 0)
        underrunWindowLateness.removeAll(keepingCapacity: true)
        underrunWindowCount = 0
        arrivalWindowMin = Int.max
        arrivalWindowMax = 0
        backlogLock.unlock()

        // ── THE LEDGER ──────────────────────────────────────────────────────────────────────
        // inBuffer on the SAME timeline as content, at the SAME instant, UNCLAMPED. Negative
        // during an underrun, which is the truthful reading.
        let inBuffer = senderPTS - clockNow
        let cushion = Self.targetDepth      // the one-time ANCHOR offset, fixed at activate()
        let surplus = content - wall
        let residual = surplus + cushion - netJump - inBuffer
        // residual IS the integrated rate slew and nothing else (see the derivation above), so it
        // cannot exceed maxSlew × elapsed. Beyond that bound, a clock jump happened that is not in
        // netJump — a bug, and the only thing this flag should ever fire on.
        let bound = Self.maxSlew * wall + Self.residualEpsilon
        let flag = abs(residual) > bound ? " OVER" : ""

        NSLog("""
              [WHEP-BACKLOG] pictures=%d over %.1fs (=%.2fs content) vs wall %.1fs → \
              surplus %+.2fs cumulative | netJump %+.2fs | inBuffer %+.2fs | cushion %.3fs | \
              residual %+.3fs (bound ±%.3fs)%@
              """,
              pictures, wall, content, wall,
              surplus, netJump, inBuffer, cushion, residual, bound, flag)

        // ── THE DISTRIBUTION ────────────────────────────────────────────────────────────────
        // Running max alone is pinned forever by one outlier, which makes it a poor basis for
        // choosing a target and a worse one for any later adaptive control. The SHAPE is what
        // distinguishes "many small misses" (a modestly deeper cushion fixes it) from "a few large
        // ones" (it does not, and something smarter is needed).
        //
        // With a handful of events per window a computed percentile is noise dressed as a
        // statistic, so the window's individual latenesses are listed VERBATIM. The all-time
        // p50/p90 appears only once there are enough samples to mean something.
        let nominal = content > 0 ? Double(pictures - 1) / content : 0
        let windowShape = windowLateness.isEmpty
            ? "none"
            : windowLateness.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        let worst = windowLateness.max() ?? 0
        let allTime = Self.percentileSummary(allLateness)

        NSLog("""
              [WHEP-JITTER] window arrivals min=%d max=%d (nominal %.2f) | underruns=%d \
              (stream %d) | worst deficit %.3fs | window L: [%@] | cushion needed >= %.3fs \
              (running max)%@
              """,
              arrivalsMin, arrivalsMax, nominal, windowUnderruns, totalUnderruns,
              worst, windowShape, cushionNeededMax, allTime)
    }

    /// All-time p50/p90 of the positive latenesses, or "" while the sample is too small for a
    /// percentile to be more informative than the raw list already printed per window. 8 is the
    /// point below which p90 is just "the largest value" wearing a statistical hat.
    private static func percentileSummary(_ values: [Double]) -> String {
        guard values.count >= 8 else { return "" }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            let idx = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
            return sorted[idx]
        }
        return String(format: " | all-time L p50=%.3fs p90=%.3fs (n=%d)",
                      percentile(0.5), percentile(0.9), sorted.count)
    }

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
        // One active source: retire the loaded file before we take the renderer.
        onWillActivateStream?()

        let clock = LiveClock(startupDepth: Self.targetDepth, targetDepth: Self.targetDepth)

        savedClock = renderer.clock
        savedIsPaused = renderer.isPausedProvider

        // The three live-path seams, in SyntheticLiveSource's order. now() is "never due" until the
        // first frame anchors it, so nothing renders until WHEP pushes. onDisplayTick stays nil:
        // this is a PUSH source (NDI is the pull case that sets it).
        renderer.clock = { [clock] in clock.now() }
        renderer.isPausedProvider = { false }
        renderer.onDisplayTick = nil
        // SNAP-TO-LIVE, on for this transport (LiveClock defaults it off — see `snapEnabled`).
        // A WHEP sender that pauses and resumes leaves a slab of buffered latency the ±0.5% slew
        // cannot drain, and it happens on every pause in a review session. The knobs are stated
        // here rather than left implicit because they are the two things worth tuning from real
        // behaviour: threshold is how deep is "too deep", debounce is how long we tolerate it
        // before jumping. Conservative starting values — a missed snap costs latency, a false snap
        // costs a visible jump, and the second is the worse failure.
        clock.snapEnabled = true
        // UNCHANGED at 0.2, but note the arithmetic moved with targetDepth: the snap now fires
        // above ~0.6 s (0.400 target + 0.2 threshold) rather than ~0.4 s. That is still the right
        // shape — the threshold is "how far above target is a GROSS overfill the P-loop cannot
        // drain", which scales with the target rather than being an absolute depth — but it does
        // mean the buffer tolerates more absolute latency before snapping than it used to. Revisit
        // if [WHEP-BACKLOG] ever shows a connect backlog sitting between 0.4 s and 0.6 s.
        clock.snapThreshold = 0.2    // snap above ~0.6 s with a 0.4 s target
        clock.snapDebounce = 0.75    // sustained, not a burst

        // ── SLEW RAIL — SETTLED. DO NOT RAISE. ─────────────────────────────────────────────
        //
        // The measurement is IN, and it closes: 659 pictures in 25 s from a 23.98 fps sender is
        // 27.48 s of content, a 2.48 s surplus, which landed as 0.93 s flushed plus 1.59 s left in
        // the buffer = 2.52 s. The accounting balances. Transport is clean (seqGaps=0, lost=0,
        // reorder=0, AUs assembled == pictures decoded), PTS is correctly RTP-derived, and the
        // sender's clock is real-time locked (~90,100 tps) once the backlog drains. There is NO
        // clock drift and NO measurement bias to chase.
        //
        // WHICH MEANS THE RAIL WAS NEVER THE PROBLEM. ±0.5% is a drain rate of 0.005 s of buffer
        // per second — absorbing a 2.5 s connect backlog that way would take EIGHT MINUTES. Raising
        // it would not fix that; it would only make the correction visible on moving video while
        // still losing the race. Slew is a ppm-scale trim for CRYSTAL DRIFT. DISCARD is the
        // instrument for BACKLOG, and that is what the snap, the queue-full re-anchor and the
        // freeze guard now provide. Since every overfill is finite (the sender makes 23.98/s and
        // the SFU cannot exceed that indefinitely), discarding is guaranteed to converge.
        //
        // 0.005 is LiveClock's default, so this line changes nothing — it is here to state the
        // conclusion at the place someone would otherwise reach for the knob.
        clock.maxSlew = Self.maxSlew

        // Forwards the FULL sample — including the queue edges and the eligibility flag — which is
        // what ARMS LiveClock's freeze guard. This transport opts in; the synthetic harness
        // deliberately does not (see SyntheticLiveSource's matching hook).
        renderer.onDepthSample = { [clock, weak self] sample in
            let event = clock.updateDepth(spanSeconds: sample.spanSeconds,
                                          count: sample.count,
                                          oldestPTS: sample.oldestPTS,
                                          newestPTS: sample.newestPTS,
                                          presented: sample.hadEligibleFrame)
            self?.lastDepthSpan = sample.spanSeconds   // telemetry only (see the field comment)
            self?.lastDepthCount = sample.count
            // Underrun detection, on the selection path where count == 0 is already known.
            self?.recordSelection(count: sample.count, presented: sample.hadEligibleFrame)
            // Feed the creep side of the drift comparison. Averaged over the window rather than
            // sampled at its edges: the raw span is a per-frame sawtooth, and the creep we are
            // hunting (~0.003 s/s) is far smaller than one tooth.
            self?.recordDepthForDrift(span: sample.spanSeconds, snapped: event != nil)
            // Fires on the render thread, but only on a coarse action — a snap or a freeze-guard
            // re-anchor — never per tick. The clock's lock is already released by the time this
            // value is in hand (it is a return, not a callback, precisely so a log can't run
            // inside the critical section).
            if let event {
                self?.recordClockJump(event.jumped)
                Self.log(event)
            }
        }

        // QUEUE-FULL → CLOCK RE-ANCHOR. Runs on the DECODE thread (renderer.enqueue's caller),
        // after the renderer's queue lock is released; `overflowReanchor` takes LiveClock's lock,
        // which registerFrame already takes on this same thread every frame. No debounce: during a
        // backlog drain this fires repeatedly and that IS the drain working. Each firing logs and
        // is counted into `flushed` so the accountant can prove convergence.
        renderer.onQueueOverflow = { [clock, weak self] newestPTS, count in
            if let event = clock.overflowReanchor(newestPTS: newestPTS, count: count) {
                self?.recordClockJump(event.jumped)
                Self.log(event)
            }
        }
        // Headroom above the shallow file-path bound (12) so the control loop can correct a filling
        // buffer before it saturates and drop-oldest fires — the value the sweep was run against.
        renderer.maxQueuedOverride = 30
        renderer.flush()   // drop any file frames still queued behind us

        // Colorimetry is ASSUMED, not read: H.264 signals it in the SPS VUI, which the depacketizer
        // does not parse. 709 SDR video-range is the honest default for a Constrained Baseline WHEP
        // stream, and it is the SAME default NDI starts on for a source that declares nothing
        // (NDIService.start). Range is pinned rather than read from the file transport's override,
        // which describes a file that may not even be loaded — again exactly as NDI does.
        renderer.setSourceColorSpace(primaries: 1, transfer: 1, matrix: 1)
        renderer.isFullRangeProvider = { false }

        // Clear every per-stream measurement before the first frame of this stream can arrive —
        // `underrunArmed` above all, so a reconnect's startup fill cannot be logged as one giant
        // bogus underrun. See resetStreamTelemetry().
        resetStreamTelemetry()

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

        if let renderer {
            renderer.clock = savedClock
            renderer.isPausedProvider = savedIsPaused
            renderer.onDepthSample = nil
            renderer.onQueueOverflow = nil   // must not outlive the clock it re-anchors
            renderer.maxQueuedOverride = nil
            renderer.clearToBlack()
        }
        savedClock = nil
        savedIsPaused = nil

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

        resetStreamTelemetry()
    }

    /// Clear ALL per-stream measurement state: the surplus ledger, the underrun detector and its
    /// arming flag, and the arrival bins.
    ///
    /// PER-STREAM FOR THE SAME REASON THE DRIFT STATE IS. A reconnect is a different sender and a
    /// different backlog; carrying the previous stream's content origin across the gap would
    /// manufacture an enormous phantom surplus from the discontinuity alone.
    ///
    /// `underrunArmed` ESPECIALLY. A reconnect performs a fresh startup fill, during which the queue
    /// is empty at every display tick by construction. A still-armed detector would open an episode
    /// on the first of those ticks and hold it open across the whole fill, logging one enormous
    /// bogus underrun on the second and every subsequent connect — the exact failure the
    /// arm-after-first-present rule exists to prevent, merely displaced from first connect to every
    /// later one. Identical reasoning to LiveClock's `hasPresentedOnce`, which its `reset()` clears.
    ///
    /// Called from BOTH `activate()` (before any frame of the new stream can arrive — the strongest
    /// guarantee point, and it does not depend on teardown having run) and `releaseResources()`
    /// (teardown hygiene). Either alone would do; both means no connect path can miss it.
    private func resetStreamTelemetry() {
        backlogLock.lock()
        backlogFirstSenderPTS = nil
        backlogFirstHost = 0
        backlogLastSenderPTS = 0
        backlogPictures = 0
        backlogNetJump = 0
        backlogLastLogHost = 0
        underrunArmed = false
        underrunSince = nil
        underrunTicks = 0
        underrunCushionNeededMax = 0
        underrunAllLatenessValues.removeAll()
        underrunWindowLateness.removeAll()
        underrunWindowCount = 0
        underrunTotalCount = 0
        arrivalBinStart = 0
        arrivalBinCount = 0
        arrivalWindowMin = Int.max
        arrivalWindowMax = 0
        backlogLock.unlock()
    }

    // MARK: - Runtime target adjustment (⌃⌥[ / ⌃⌥], main thread)

    /// Step the live clock's `targetDepth` by `delta`. The whole point is to A/B several cushion
    /// values inside ONE connection, so the underrun accountant's "cushion needed" figures are
    /// comparable against a moving setpoint rather than requiring a reconnect per value.
    ///
    /// The resulting clock jump is fed into the ledger: a target RAISE re-anchors backward, which is
    /// a negative coarse clock action, and leaving it out would trip the residual's OVER flag on a
    /// deliberate keypress. See `backlogNetJump`.
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
        recordClockJump(change.jumped)
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
        recordBacklogSample(senderPTS: senderPTS, clockNow: clockNow)
        // Closes a starvation episode the render thread opened, if one is open. No-op otherwise,
        // which is the overwhelmingly common case.
        closeUnderrunIfOpen(senderPTS: senderPTS, clockNow: clockNow, target: target)

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
    }

    /// Render thread. Accumulates the window's mean depth and latches whether a coarse clock
    /// action occurred inside it.
    private func recordDepthForDrift(span: Double, snapped: Bool) {
        driftLock.lock()
        driftDepthSum += span
        driftDepthN += 1
        if snapped { driftWindowHadSnap = true }
        driftLock.unlock()
    }

    // MARK: - Latency-control reporting (render thread, coarse actions only)

    /// One line per coarse clock action. These are RARE and each one is a real event in the
    /// session's latency story, so they are logged unconditionally rather than folded into the
    /// 1 Hz flow line — a snap that fires the moment the sender resumes should be visible at that
    /// moment, next to the [LIVECLOCK] line whose depth it just changed.
    private static func log(_ event: LiveClock.Event) {
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
    }

    // MARK: - Helpers

    /// Wrap a pixel buffer in a ready CMSampleBuffer at `pts`. Same call, same arguments, as
    /// NDIService.makeSampleBuffer and SyntheticLiveSource.makeSampleBuffer. Duration is .invalid:
    /// RTP does not carry one, the renderer selects on PTS alone, and a fabricated duration would be
    /// a guess nothing reads. DTS is .invalid too — CoreMedia reads that as decode order ==
    /// presentation order, which is exactly true for Cloudflare's B-frame-free H.264.
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
    }
}
#endif
