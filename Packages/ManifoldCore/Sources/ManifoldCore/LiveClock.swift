import Foundation
import QuartzCore

/// A free-running presentation clock for LIVE push sources (WHEP, and later SRT/HLS).
///
/// WHY THIS EXISTS: file playback rides the `AVSampleBufferRenderSynchronizer`'s file
/// timebase — every frame's presentation time is a position on a known, seekable
/// timeline. A live source has no such timeline: frames arrive carrying a *sender*
/// timestamp (the encoder's clock), off the network, at the mercy of jitter. NDI dodged
/// this entirely by leaning on the SDK's FrameSync (which owns the jitter buffer + rate
/// conversion) and simply stamping each pulled frame with `CACurrentMediaTime()` at the
/// instant before the display tick reads the clock. WHEP has no FrameSync, so we build the
/// clock ourselves. `LiveClock` is that clock's Step-1 skeleton.
///
/// WHAT IT DOES (Step 1): it anchors the sender timeline to the local host clock on the
/// FIRST frame, then free-runs at wall-clock speed. `now()` is the closure that drives
/// `MetalVideoRenderer.clock` while a live source owns the display — the same seam NDI
/// substitutes `{ CACurrentMediaTime() }` into, but timeline-aware.
///
/// THE MAPPING. With the anchor `(anchorSenderPTS, anchorHostTime)` and rate `r`:
///
///     now()  =  anchorSenderPTS + (hostNow() - anchorHostTime) * r
///
/// The anchor is established on the first frame as:
///
///     anchorSenderPTS = firstFrame.senderPTS
///     anchorHostTime  = hostNow() + targetDepth
///
/// The `+ targetDepth` is the whole trick: it pushes the host anchor into the FUTURE, so
/// `now()` starts out *behind* the first frame's PTS and only catches up after `targetDepth`
/// seconds of wall-time have elapsed. During that window the renderer's `pts <= now`
/// selection rejects every frame — which is exactly the startup buffer fill. A frame with
/// sender PTS `T` therefore becomes due at host time:
///
///     anchorHostTime + (T - anchorSenderPTS)   =   (t0 + targetDepth) + (T - firstPTS)
///
/// i.e. `targetDepth` seconds after the first frame arrived, then paced 1:1 with the sender
/// timeline. That is the "near-live with a small safety buffer" behavior we want.
///
/// STEP 1 SCOPE — read this before extending: `rate` is FIXED at 1.0. There is NO drift
/// correction and NO buffer-depth control loop yet. `now()` advances at exactly wall-clock
/// speed. Step 2 introduces the control loop that modulates `rate` slightly (±) from the
/// measured buffer depth to pull the presentation clock back toward the sender without
/// visible jumps — the single marked TODO below is where that lands.
///
/// THREADING: `registerFrame(senderPTS:)` is called from the SOURCE thread (a frame arrives
/// off the network / decode), while `now()` is read on the `CVDisplayLink` render thread.
/// The anchor state is therefore guarded by an `UnfairLock` — priority-donating, because a
/// real-time render thread blocking on a lock held by the decode thread is a textbook inversion.
/// Both entry points are cheap and never block beyond the lock; see the `lock` declaration for why
/// nothing may be formatted or written inside a critical section.
public final class LiveClock: @unchecked Sendable {

    /// The presentation/host rate — the multiplier in `now()`. Starts at 1.0 (wall-clock speed);
    /// once frames flow, `updateDepth`'s control loop is the ONLY writer, slewing it a hair around
    /// 1.0 to hold the buffer at `targetDepth`. `private(set)` because nothing outside the clock
    /// modulates it. Read in `now()` and written in `updateDepth`, both under `lock`.
    public private(set) var rate: Double = 1.0

    /// Sender-timeline PTS of the first frame — the origin the mapping is anchored to.
    /// `nil` until the first `registerFrame`; `now()` returns "never due" while it is nil.
    private var anchorSenderPTS: Double?

    /// Host time (`CACurrentMediaTime()`) the anchor is pinned to, pushed `startupDepth`
    /// into the future so the buffer fills before the first frame comes due.
    private var anchorHostTime: Double?

    /// Seconds of buffer to fill before the FIRST frame is presented — the startup delay / initial
    /// cushion, applied once when the anchor is established (see `registerFrame`). DISTINCT from
    /// `targetDepth`: startup is a one-time fill, target is the steady-state hold point.
    /// `var` (was `let`) only so the DEBUG `setDepths` sweep hook can retarget it; production sets it
    /// once at init and never writes it again. Read under `lock` in `registerFrame`.
    private var startupDepth: Double

    /// The steady-state control SETPOINT: the buffer depth (seconds of lead ahead of `now()`) the
    /// loop holds once running. `error = smoothedDepth - targetDepth` drives the rate slew.
    /// `var` (was `let`) only for the DEBUG `setDepths` sweep hook (see `startupDepth`). Read under
    /// `lock` in `updateDepth`.
    private var targetDepth: Double

    // --- Control-loop tuning (public var so the debug/tuning pass can adjust them live) ---

    /// Loop gain: rate change per second-of-depth-error. SMALL by design — start ~0.8 and tune.
    /// Proportional-only, so a tiny steady-state droop is expected: holding rate `r` needs
    /// error `(r-1)/k`; with k=0.8 and r=1.001 that is ~0.00125 s of depth offset — negligible.
    public var k: Double = 0.8

    /// Hard cap on rate deviation from 1.0. TIGHT — ±0.5% keeps `now()` in 0.995…1.005 so the
    /// correction is invisible on video. The loop can only recover senders within this ratio.
    public var maxSlew: Double = 0.005

    /// EMA weight on each incoming depth sample (0…1). Low-passes the per-tick span so the loop
    /// reacts to the trend, not refresh-rate noise. Small = smoother/slower.
    public var emaAlpha: Double = 0.1

    /// How often the rate is actually recomputed, in Hz. `updateDepth` is called at the display
    /// tick (60–120 Hz); the rate slew is rate-limited to this cadence so it doesn't chase noise.
    public var controlHz: Double = 10
    private var controlInterval: Double { 1.0 / controlHz }

    // MARK: - Snap-to-live (coarse outer loop)
    //
    // WHY THE P-LOOP IS NOT ENOUGH. `maxSlew` is ±0.5% BY DESIGN — that is what keeps a rate
    // correction invisible on moving video. It is also, arithmetically, a drain rate of 0.005 s
    // of buffer per second: recovering a 0.3 s overfill takes ~60 s at the rail, and a sender
    // that pauses again inside that minute refills faster than the loop drains. The loop is a
    // fine-settle mechanism and cannot be retuned into a coarse one without making every
    // correction visible.
    //
    // WHERE THE OVERFILL COMES FROM. A paused/static sender stops producing (or drops to a
    // trickle), then RESUMES with a burst whose RTP timestamps are continuous across the gap.
    // The newest queued PTS jumps far ahead of `now` in a fraction of a second, and depth lands
    // deep and STAYS deep, because the drain rail above cannot pull it back. Every sender pause
    // in a review session leaves another permanent slab of latency.
    //
    // THE SNAP. When the SMOOTHED depth sits above `targetDepth + snapThreshold` continuously
    // for `snapDebounce` seconds, re-anchor so `now()` jumps FORWARD by the excess. Depth is
    // `newestQueuedPTS − now`, so advancing `now` is what removes the latency; the renderer's
    // display tick then drops the frames that just went stale on its next pass, at a frame
    // boundary, through the same selection path it always uses. There is no queue surgery here
    // and none is needed — dropping the OLDEST frames would not move `newest`, and so would not
    // remove one millisecond of latency.
    //
    // The debounce is the whole discrimination: a single IDR or jitter burst spikes depth and
    // subsides (the buffer absorbing a spike is the buffer WORKING, and must not trigger a
    // jump), while a sender-pause overfill is monotonic and permanent. Sustained-over-threshold
    // is the signature of the second and not the first.

    /// Master switch. DEFAULT OFF, and deliberately so: docs/LIVECLOCK_PRESETS.md's depth grid was
    /// measured with no snap in the loop, and silently enabling one would invalidate every cell of
    /// it (a FAIL from a saturated buffer would become a PASS with a hidden jump). The synthetic
    /// harness therefore stays exactly as swept; live transports opt in.
    public var snapEnabled = false

    /// How far above target depth must sit to be considered a GROSS overfill rather than something
    /// the P-loop should handle. It is an OFFSET above the target, not an absolute depth, so it
    /// scales with whatever the caller sets: 0.2 over a 0.2 target snaps above ~0.4, over the live
    /// path's measured 0.4 target it snaps above ~0.6. Conservative on
    /// purpose: the cost of a missed snap is latency, the cost of a false snap is a visible jump.
    public var snapThreshold: Double = 0.2

    /// How long depth must stay above the threshold before snapping. This is the transient filter
    /// — long enough that a burst has time to drain through the buffer, short enough that a real
    /// overfill is not endured. Note this is also a floor on the latency a snap can leave behind:
    /// we knowingly run deep for this long before correcting.
    public var snapDebounce: Double = 0.75

    /// Host time depth first went above the threshold in the CURRENT excursion, or nil when depth
    /// is under it. Cleared on every dip back under, so the debounce measures CONTINUOUS time over
    /// threshold rather than cumulative time — one 3 s overfill snaps; six flickering 0.5 s spikes
    /// never do, which is the distinction the whole mechanism rests on. Guarded by `lock`.
    private var overThresholdSince: Double?

    // MARK: - Why there is NO repeated-snap safety valve here
    //
    // There was one, and it was DELETED. The reasoning it rested on is recorded here so it is not
    // rebuilt from the same intuition.
    //
    // It counted snaps: more than N inside a window was read as "this connection cannot sustain
    // low latency", so it stopped snapping and RAISED the effective target to the depth being
    // held (0.200 → 0.540), calling that state DEGRADED.
    //
    // THE INVERSION. That logic assumed repeated snaps mean the buffer cannot be held at target.
    // On a real WHEP connection they mean the opposite. An SFU delivers a BACKLOG on connect,
    // faster than real time — measured on this path: 659 pictures in 25 s of wall time from a
    // 23.98 fps sender, i.e. 27.48 s of content, a 2.48 s surplus — and the snaps that follow are
    // the system DRAINING it. The valve therefore disabled the only mechanism that was working,
    // at precisely the moment it was working, and the buffer ran away to a hard freeze.
    //
    // WHY A SUSTAINED DEFICIT IS NOT POSSIBLE. The valve's premise was a regime where in > out
    // permanently. There is no such regime: the sender produces 23.98 pictures per second and the
    // SFU cannot exceed that indefinitely. Every overfill is FINITE, so discarding always
    // converges. Snapping as often as needed IS the correct posture, and holding `targetDepth`
    // fixed is the correct default.
    //
    // IF ADAPTIVE DEPTH IS EVER WANTED AGAIN it must be gated on snaps that recur AFTER a
    // sustained quiet period at target — evidence of genuine ongoing instability — and never on
    // consecutive snaps inside a startup drain, which is what the deleted version keyed on.

    // MARK: - Freeze guard (the unrecoverable-state safety net)
    //
    // THE FAILURE IT CATCHES. The renderer selects the newest frame with `pts <= now()`. If the
    // clock falls behind the ENTIRE queue, nothing satisfies that predicate — and because the
    // queue evicts its OLDEST entry when full, the frames that would have become eligible are
    // exactly the ones discarded. The whole window then slides further into the future with every
    // arrival: the renderer freezes on one frame while transport keeps running, and no amount of
    // rate slew recovers it (±0.5% against a 1.4 s deficit is minutes of drain).
    //
    // THE GUARD. Queue NON-EMPTY and NO eligible frame, sustained, is not a transient — it is
    // that unrecoverable state, and the only exit is to move the clock. Re-anchor forward so
    // `now() == newest.pts − targetDepth`, which by construction makes most of the queue eligible
    // again and drains it through the renderer's ordinary consume-up-to-newest-eligible path.
    //
    // This is a SAFETY NET, not a tuning knob, so it fires unconditionally — no snap state, no
    // eligibility check, no debounce shared with anything else can suppress it.
    //
    // ── WHY IT IS NOT A BARE TICK COUNT ────────────────────────────────────────────────────────
    //
    // "No eligible frame for K ticks" alone is WRONG, by arithmetic. A 23.98 fps stream makes a
    // frame due every 41.7 ms; the display ticks every 16.7 ms (60 Hz) or 8.3 ms (120 Hz). So
    // HEALTHY playback spends 2–3 consecutive ticks at 60 Hz, and ~5 at 120 Hz, with a non-empty
    // queue and nothing eligible — every single frame. A bare K=3 fires continuously on a 120 Hz
    // panel. Hence two additional conditions, and both are load-bearing:
    //
    //   * a WALL-TIME hold (`freezeGuardHold`), so the trigger is display-rate independent. At
    //     0.25 s ≈ 6 frame intervals it is unreachable in healthy playback (where the maximum gap
    //     is ONE frame interval) and negligible as detection latency against a permanent freeze.
    //   * ARMED ONLY AFTER THE FIRST PRESENTATION — AND THIS IS NOW THE ONLY PROTECTION, NOT A
    //     REDUNDANT ONE. While the live target was 0.200 s the fill was also shorter than
    //     `freezeGuardHold` (0.25 s), so the hold alone would have rejected it; at the measured
    //     0.400 s target the fill OUTLASTS the hold and arming is all that stands between a
    //     connect and a spurious re-anchor. The startup fill IS this state by
    //     construction — the queue fills while `now()` is deliberately held `startupDepth` behind
    //     it — so an unarmed guard would re-anchor away the very cushion it exists to establish,
    //     on every connect. `hasPresentedOnce` is per-STREAM and cleared in `reset()`.

    /// Consecutive display ticks with a NON-EMPTY queue and no frame satisfying `pts <= now()`.
    /// Guarded by `lock`.
    private var ineligibleTicks = 0
    /// Host time the current ineligible run began; nil whenever a frame was presentable. Guarded
    /// by `lock`. Paired with `ineligibleTicks` — the guard needs BOTH satisfied.
    private var ineligibleSince: Double?
    /// Whether ANY frame has been presented since the anchor was established. The guard is
    /// DISARMED until this is true, which is what excludes the startup fill (see above).
    /// Per-STREAM: cleared by `reset()`, so a reconnect re-disarms for its own fill.
    private var hasPresentedOnce = false

    /// Consecutive ineligible ticks required before the guard may fire. A floor against a
    /// single-tick blip; the wall-time hold below is what actually discriminates.
    public var freezeGuardTicks = 3
    /// Wall-clock seconds the ineligible state must persist. See the arithmetic above for why
    /// this exists and why 0.25 s is both safe and fast enough.
    public var freezeGuardHold: Double = 0.25

    /// Whether COARSE intervention is permitted at this instant. Only ⌃⌥U's measurement baseline
    /// withholds it: pinning the rate to unity exists precisely to read the UNINTERVENED depth,
    /// and a snap mid-measurement would corrupt the number being measured. Unconditionally true in
    /// Release, where that diagnostic does not exist. Read under `lock`, like `forceUnityRate`.
    private var snapEligible: Bool {
        #if DEBUG || MANIFOLD_TELEMETRY
        return !forceUnityRate
        #else
        return true
        #endif
    }

    /// What `updateDepth` did that the CALLER should report. Returned rather than dispatched
    /// through a callback because `updateDepth` runs under `lock`: handing it back through the
    /// return value means the caller receives it with the lock already released (the `defer` runs
    /// first), so a logging sink can never re-enter the clock or stall the render thread inside
    /// the critical section. At most one of these can fire per call — the branches are exclusive.
    public enum Event: Sendable {
        /// A gross overfill was corrected by jumping the presentation clock forward.
        case snapped(SnapEvent)
        /// The clock had fallen behind the ENTIRE queue and was re-anchored to recover.
        case freezeGuard(FreezeGuardEvent)
        /// The queue hit its bound — by definition excess buffer — and the clock was re-anchored
        /// to `newest − targetDepth` so the surplus drains through normal selection.
        case overflowReanchor(OverflowEvent)

        /// Seconds of presentation time the clock jumped FORWARD, for whichever action fired.
        /// This is the quantity a surplus accountant must sum as "flushed": every one of these
        /// events discards exactly this much buffered content.
        public var jumped: Double {
            switch self {
            case .snapped(let e):          return e.excess
            case .freezeGuard(let e):      return e.jumped
            case .overflowReanchor(let e): return e.jumped
            }
        }
    }

    public struct SnapEvent: Sendable {
        /// Smoothed depth immediately before the snap — the latency that was actually being carried.
        public let depthBefore: Double
        /// Where the snap puts it, by construction: `targetDepth`. The NEXT depth sample is the
        /// measurement; this is the intent, and the two are worth comparing in a log.
        public let depthAfter: Double
        /// Seconds of latency removed (`depthBefore - depthAfter`).
        public let excess: Double
        /// How long depth had been continuously over threshold when it fired — the evidence that
        /// this was a sustained overfill and not a burst.
        public let sustainedFor: Double
    }

    public struct FreezeGuardEvent: Sendable {
        /// Seconds the presentation clock was moved forward.
        public let jumped: Double
        /// Consecutive ineligible display ticks when it fired.
        public let ticks: Int
        /// Wall seconds the ineligible state had persisted — the display-rate-independent number.
        public let heldFor: Double
        /// Queue depth at the moment of the freeze. Non-zero by definition (that is the pathology:
        /// frames present, none reachable).
        public let queued: Int
        /// How far AHEAD of the clock the OLDEST queued frame sat. Positive by definition; this is
        /// the direct measure of how far behind the whole queue the clock had fallen.
        public let oldestAhead: Double
        /// Smoothed depth immediately before the re-anchor.
        public let depthBefore: Double
        /// The target it was re-anchored to.
        public let target: Double
    }

    public struct OverflowEvent: Sendable {
        /// Seconds the presentation clock was moved forward.
        public let jumped: Double
        /// Queue count at the moment the bound was hit.
        public let queued: Int
        /// Depth (`newest − now`) immediately before the re-anchor.
        public let depthBefore: Double
        /// The target it was re-anchored to.
        public let target: Double
    }

    #if DEBUG || MANIFOLD_TELEMETRY
    /// DIAGNOSTIC (⌃⌥U): force the control loop OFF — pin `rate` at unity (1.0) while leaving the
    /// depth EMA and `[LIVECLOCK]` logging running UNCHANGED, so the MEASURED depth can be read under
    /// rate≡1.0 to confirm the setpoint is real (not a sawtooth / tick-quantization offset the loop
    /// would otherwise chase). `private(set)` + the locked setter below keep read (in `updateDepth`,
    /// under `lock`) and write (cross-thread, from the App harness) consistently guarded. Default OFF.
    public private(set) var forceUnityRate = false
    /// Lock-clean cross-thread write for `forceUnityRate` — same `lock` `updateDepth` reads it under,
    /// so the pin is applied with no window of ambiguity near the steady-state depth measurement.
    public func setForceUnityRate(_ on: Bool) { lock.lock(); forceUnityRate = on; lock.unlock() }

    /// DEBUG sweep hook (⌃⌥S): retarget the control SETPOINT and the startup FILL at runtime — the only
    /// reason `startupDepth`/`targetDepth` are `var`. Under `lock`, same discipline as `setForceUnityRate`,
    /// so the change is consistent with `updateDepth`'s read of `targetDepth` and `registerFrame`'s read of
    /// `startupDepth`. Callers MUST pair this with `reset()` so the next anchor re-fills to the new startup
    /// depth (setting them equal makes the fill land at the setpoint — no long drain to swamp a settle
    /// window). NOT for production paths — the setpoint is fixed there.
    public func setDepths(startup: Double, target: Double) {
        lock.lock()
        startupDepth = startup
        targetDepth = target
        lock.unlock()
    }
    #endif

    // --- Control-loop state (guarded by `lock`) ---

    /// EMA-smoothed buffer depth in seconds; `nil` until the first sample seeds it.
    private var smoothedDepth: Double?
    /// Host time of the last rate recompute — gates the slew to `controlHz`.
    private var lastControlHost: Double?
    /// Host time of the last telemetry line — gates the DEBUG log to ~1 Hz.
    private var lastLogHost: Double?
    /// Latest queue count (telemetry only).
    private var lastCount: Int = 0

    /// Guards the anchor state AND the control-loop state (`rate` / `smoothedDepth` / gates) across
    /// the source thread (writer, via `registerFrame`), the render thread (reader `now`, writer
    /// `updateDepth`), and `reset`.
    ///
    /// UNFAIR LOCK, NOT NSLock — THE HIGHEST-TRAFFIC PRIORITY INVERSION IN THE CODEBASE. The
    /// real-time `CVDisplayLink` render thread takes this TWICE PER DISPLAY TICK (`now()` at the top
    /// of the tick, `updateDepth` after selection — 120–240 acquisitions/second at 120 Hz), while
    /// the lower-priority decode/source thread holds it per frame in `registerFrame`,
    /// `overflowReanchor` and the telemetry reads. `NSLock` is a `pthread_mutex` and does NOT boost
    /// its holder, so a descheduled decode thread stalls the display tick for an unbounded interval.
    /// `os_unfair_lock` DONATES the blocked render thread's priority to the holder, which dissolves
    /// it. Same conversion, same reasoning, as the renderer's `queueLock` and the WHEP router's
    /// `backlogLock`/`driftLock`.
    ///
    /// NOTHING SLOW UNDER THIS LOCK — and that is now STRUCTURAL, not a convention. A boosted holder
    /// must release promptly, so the four `[LIVECLOCK]` telemetry lines are no longer written from
    /// inside the critical section: each locked region returns a small value-type payload, the
    /// caller unlocks, and only then is anything formatted or written to stderr. The `…Locked`
    /// helpers below are the locked halves; the public methods are the lock/unlock/emit wrappers.
    /// `String(format:)` allocates and `FileHandle.write` is a syscall — either one under a donating
    /// lock is worse than the inversion it replaced.
    ///
    /// NO LOCK NESTING, IN EITHER DIRECTION. This class never calls out while holding the lock —
    /// coarse actions are RETURNED to the caller as an `Event` rather than dispatched through a
    /// callback (see `Event`), precisely so a logging sink can never re-enter the clock or take a
    /// second lock inside this critical section. On the render side the renderer calls `clock?()`
    /// BEFORE taking `queueLock` and `onDepthSample` AFTER releasing it, so the two donating locks
    /// are strictly sequential and never held together.
    private let lock = UnfairLock()

    /// - Parameters:
    ///   - startupDepth: seconds of buffer to fill before the FIRST frame is presented (the startup
    ///     delay / initial cushion — pushes the host anchor into the future).
    ///   - targetDepth: the steady-state control SETPOINT the loop holds the buffer at once running.
    ///     Same default as `startupDepth`, independently tunable. FIXED for the life of the clock
    ///     (outside the DEBUG sweep hook): nothing inflates it any more — see the deleted
    ///     safety-valve note above for why the thing that used to is gone.
    public init(startupDepth: Double = 0.15, targetDepth: Double = 0.15) {
        self.startupDepth = startupDepth
        self.targetDepth = targetDepth
    }

    /// Register a newly-arrived frame's sender-timeline PTS and get back the presentation PTS
    /// to stamp on the `CMSampleBuffer` before enqueuing it.
    ///
    /// On the FIRST frame this establishes the anchor (`anchorSenderPTS = senderPTS`,
    /// `anchorHostTime = hostNow() + targetDepth`). On every frame it returns the presentation
    /// PTS. In Step 1, with `rate == 1.0`, the sender and presentation timelines are identical,
    /// so the returned value IS `senderPTS` — the mapping is an identity offset by the anchor,
    /// realized purely in *when* `now()` crosses each PTS (via the host anchor), not in the PTS
    /// value itself. (Step 2's non-unity rate will make this a genuine remap; keeping the call
    /// here now means the source's stamping path is already correct when that lands.)
    ///
    /// Called on the source thread.
    public func registerFrame(senderPTS: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if anchorSenderPTS == nil {
            anchorSenderPTS = senderPTS
            anchorHostTime = hostNow() + startupDepth
        }
        // rate == 1.0 (Step 1): presentation PTS == sender PTS. When Step 2 modulates `rate`,
        // this becomes the sender→presentation remap and stops being an identity.
        return senderPTS
    }

    /// Current presentation time, in the SENDER timeline's units — the closure handed to
    /// `renderer.clock`. Read on the `CVDisplayLink` render thread every tick.
    ///
    /// Before the anchor is set (no frame has arrived) it returns a value guaranteed to be
    /// less than any real PTS, so the renderer's `pts <= now` selection presents NOTHING until
    /// the first frame anchors the clock.
    public func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let anchorSenderPTS, let anchorHostTime else {
            // Not yet anchored: "never due" — nothing renders until the first frame arrives. Use
            // -.infinity (NOT -.greatestFiniteMagnitude, which is FINITE): it is still < any real PTS
            // so the renderer's `pts <= now` selection rejects everything, but being NON-FINITE it
            // lets the renderer's depth sampler detect the unanchored clock (`now.isFinite == false`)
            // and report span 0 — instead of computing `realPTS - hugeNegative ≈ 1.7e308`, a poison
            // value that would slam the control loop to max slew and never recover.
            return -.infinity
        }
        // now() = anchorSenderPTS + (hostNow() - anchorHostTime) * rate
        //
        // Step 2 (implemented): `rate` is no longer a constant. `updateDepth(...)` runs a gentle
        // control loop that slews `rate` a hair above/below 1.0 to hold the buffer at `targetDepth`,
        // writing it under `lock`. This mapping line is UNCHANGED — `rate` was always the
        // multiplier; the loop just makes it live. In steady state `rate` settles to the sender's
        // true clock ratio and the buffer pins at `targetDepth` — that settled rate IS the
        // recovered sender clock, found by the loop rather than computed.
        return anchorSenderPTS + (hostNow() - anchorHostTime) * rate
    }

    // MARK: - Runtime target adjustment (measurement tool)

    /// Floor/ceiling on a manually-stepped `targetDepth`. The floor is below any depth the presets
    /// sweep found workable; the ceiling is well past the point where a "live" claim is honest.
    /// Both exist only to keep a keypress from parking the buffer somewhere absurd.
    public var minTargetDepth: Double = 0.10
    public var maxTargetDepth: Double = 1.00

    /// The EFFECTIVE setpoint, for callers that must reason in the same units the loop holds — the
    /// underrun accountant derives "cushion that would have prevented this" from it, so it has to
    /// read the CURRENT value rather than the one configured at init. Thread-safe.
    public var currentTargetDepth: Double {
        lock.lock(); defer { lock.unlock() }
        return targetDepth
    }

    /// Step the setpoint by `delta`, clamped to `minTargetDepth...maxTargetDepth`, and re-anchor so
    /// the change takes effect immediately instead of arriving as a step error the P-loop must
    /// chase at its ±0.5% rail (0.05 s of cushion would take 10 s to acquire that way, which is
    /// useless for A/B-ing setpoints inside one connection).
    ///
    /// DIRECTION. Depth is `newest − now`, so DEEPENING the buffer by Δ means moving `now()`
    /// BACKWARD by Δ. That is safe here, and is the one place in this file where a backward jump
    /// is correct: the renderer simply holds its current frame Δ longer while the queue fills past
    /// it. Nothing is re-shown (consumed frames have already left the queue) and nothing is
    /// corrupted — only presentation is briefly paused. Shrinking the target moves `now()` FORWARD
    /// and discards Δ of buffer, identical in kind to a snap.
    ///
    /// The rebase is the usual shape (evaluate the old mapping at `t`, restart the segment there),
    /// plus the deliberate offset. `smoothedDepth` is shifted by the same Δ, so the loop is handed
    /// EXACTLY the error it already had rather than a fabricated one — the adjustment is invisible
    /// to the controller, which is the point.
    ///
    /// Returns the before/after pair and the signed presentation-time jump (NEGATIVE when
    /// deepening — the caller's ledger must account for it as a coarse clock action like any
    /// other), or nil if the clamp made this a no-op. Safe to call from any thread.
    @discardableResult
    public func adjustTargetDepth(by delta: Double) -> (from: Double, to: Double, jumped: Double)? {
        lock.lock()
        let change = adjustTargetDepthLocked(by: delta)
        lock.unlock()
        if let change { emitTargetStep(from: change.from, to: change.to) }   // outside the lock
        return change
    }

    /// The locked half of `adjustTargetDepth`. Calls out to nothing and formats nothing.
    private func adjustTargetDepthLocked(by delta: Double)
        -> (from: Double, to: Double, jumped: Double)? {
        let from = targetDepth
        let to = min(maxTargetDepth, max(minTargetDepth, from + delta))
        let shift = to - from
        guard shift != 0 else { return nil }

        targetDepth = to
        var jumped = 0.0
        if let aPTS = anchorSenderPTS, let aHost = anchorHostTime {
            let t = hostNow()
            let mappedNow = aPTS + (t - aHost) * rate   // old now() evaluated at t
            // Deeper target → now() moves BACK by the same amount, so measured depth lands on the
            // new setpoint immediately. `jumped` is the signed presentation time crossed.
            anchorSenderPTS = mappedNow - shift
            anchorHostTime  = t
            jumped = -shift
            // Shift the smoothed depth with the clock so the loop's error is preserved, not reset.
            if let s = smoothedDepth { smoothedDepth = s + shift }
            lastControlHost = nil
            // An excursion measured against the OLD threshold says nothing about the new one.
            overThresholdSince = nil
            ineligibleTicks = 0
            ineligibleSince = nil
        }
        // Unanchored: nothing to rebase — the next `registerFrame` will anchor against the new
        // setpoint on its own. (`startupDepth` is deliberately NOT stepped: it is the one-time fill
        // applied at anchor time, and this is a steady-state control.)
        return (from: from, to: to, jumped: jumped)
    }

    /// Whether the first frame has anchored the clock. `false` before the first `registerFrame` and
    /// after `reset()` (until the next frame arrives). While `false`, `now()` returns the -.infinity
    /// sentinel and the control loop must not run. Thread-safe (takes `lock`) — do NOT call it from
    /// code already holding `lock` (e.g. `updateDepth`), which checks the raw field instead.
    public var isAnchored: Bool {
        lock.lock(); defer { lock.unlock() }
        return anchorSenderPTS != nil
    }

    /// Feed a buffer-depth sample into the control loop. Called from the App-layer sampler at the
    /// display-tick rate (60–120 Hz) — the renderer PUSHES `(spanSeconds, count)` because LiveClock
    /// (ManifoldCore) cannot read the renderer (App). This is NOT a per-call rate recompute: the
    /// span is EMA-low-passed every call, but `rate` is only re-slewed at `controlHz` (a few Hz),
    /// so the loop tracks the trend, not per-refresh noise.
    ///
    /// The loop: `error = smoothedDepth - targetDepth`. A too-DEEP buffer (sender running fast)
    /// means `now()` is trailing, so we slew `rate` slightly ABOVE 1.0 to advance the clock faster
    /// and drain back to target; too-shallow slews below. `maxSlew` keeps the move invisible.
    ///
    /// ON TOP of that P-loop sits the coarse snap-to-live outer loop (see the snap section above):
    /// the P-loop does the fine settle at target, the snap handles gross overfill the P-loop's
    /// ±0.5% rail cannot drain. They do not interact — the snap re-anchors and hands the loop a
    /// zero error, which is the state the loop is designed for.
    ///
    /// AND, ahead of both, the FREEZE GUARD (see its section above) — the safety net for the state
    /// neither loop can leave, where the clock has fallen behind the entire queue.
    ///
    /// Returns a coarse-action report (snap / freeze-guard) when one fired, for the caller to log;
    /// nil (the overwhelmingly common case) otherwise. `@discardableResult` because the synthetic
    /// harness has no interest in it.
    ///
    /// - Parameters:
    ///   - oldestPTS: presentation PTS of the OLDEST queued frame, or nil if the queue is empty.
    ///   - newestPTS: presentation PTS of the NEWEST queued frame, or nil if the queue is empty.
    ///   - presented: whether the renderer selected a frame on this tick (`pts <= now()` matched).
    ///
    /// The last three are DEFAULTED so existing callers are unchanged — and, deliberately, so the
    /// freeze guard is INERT for them. The synthetic harness (`SyntheticLiveSource`) is exactly
    /// such a caller: `docs/LIVECLOCK_PRESETS.md`'s depth grid was swept with no coarse
    /// intervention in the loop, and silently arming one here would invalidate every cell of it.
    /// Live transports opt in by passing the queue's edges, the same way they opt into `snapEnabled`.
    ///
    /// Called on the render thread; writes `rate` under `lock` (the same lock `now()` reads it under).
    @discardableResult
    public func updateDepth(spanSeconds: Double, count: Int,
                            oldestPTS: Double? = nil,
                            newestPTS: Double? = nil,
                            presented: Bool = true) -> Event? {
        lock.lock()
        let (event, periodic) = updateDepthLocked(spanSeconds: spanSeconds, count: count,
                                                  oldestPTS: oldestPTS, newestPTS: newestPTS,
                                                  presented: presented)
        lock.unlock()
        // OUTSIDE THE LOCK, ALWAYS. See the `lock` declaration: formatting allocates and writing to
        // stderr is a syscall, and neither may happen while holding a priority-donating lock.
        // Periodic line first, then the coarse action — the order the log had before the split, so
        // a snap still reads as following the depth line whose value it just changed.
        emit(periodic)
        emit(event)
        return event
    }

    /// The locked half of `updateDepth`. Runs entirely under `lock`, calls out to nothing, and
    /// returns both the coarse action (if any) and the periodic telemetry payload (if due) for the
    /// caller to emit after unlocking.
    private func updateDepthLocked(spanSeconds: Double, count: Int,
                                   oldestPTS: Double?, newestPTS: Double?,
                                   presented: Bool) -> (Event?, PeriodicLog?) {

        #if DEBUG || MANIFOLD_TELEMETRY
        // forceUnityRate: control loop DISABLED. Pin `rate` at unity here so it is EXACTLY 1.0 from
        // the first call after the toggle (not just from the next 10 Hz recompute). Everything below —
        // the anchor guard, the depth EMA, the [LIVECLOCK] log — runs identically to normal; only the
        // rate SLEW is skipped (see the matching bypass in the recompute block).
        //
        // JUMP-FREE ⌃⌥U: pinning is itself a rate change, so writing rate = 1.0 in place would jump
        // now() by (hostNow − anchorHostTime)·(1.0 − rate) — the same session-age-growing hop the
        // recompute re-anchor fixes. ⌃⌥U is the loop-OFF measurement baseline and must inject NO
        // transient, so apply the identical rebase BEFORE pinning: only when the rate is ACTUALLY
        // changing (rate != 1.0) and the clock is anchored, evaluate old now() at `t` and restart the
        // segment at (mappedNow, t). This pin runs BEFORE the L224 anchor guard, so bind the anchor
        // pair rather than force-unwrap — the binding makes it a no-op before the first frame (no
        // position to preserve), and the rate != 1.0 guard prevents churn while already pinned. The
        // unconditional `rate = 1.0` below is the pin itself.
        if forceUnityRate {
            if rate != 1.0, let aPTS = anchorSenderPTS, let aHost = anchorHostTime {
                let t = hostNow()
                anchorSenderPTS = aPTS + (t - aHost) * rate   // old now() evaluated at t
                anchorHostTime  = t
            }
            rate = 1.0
        }
        #endif

        // HARDENING: never run the loop while UNANCHORED (now() is the -.infinity sentinel, so a real
        // frame PTS minus it would be a poison span), nor on a NON-FINITE or ABSURD span (sane depth
        // is 0…~1s; 10s is generous headroom). Drop the smoothed depth so the EMA re-primes cleanly
        // from the first real sample once anchored, and leave `rate` where it is — reset() pinned it
        // to 1.0 while unanchored, so a garbage sample can never slew it. Checks the RAW anchor field,
        // not `isAnchored`, because we already hold `lock` (os_unfair_lock is non-recursive — it
        // traps on re-entry rather than deadlocking, but either way it must not be re-taken).
        guard anchorSenderPTS != nil, spanSeconds.isFinite, abs(spanSeconds) < 10 else {
            smoothedDepth = nil
            // Also drop the excursion timers: a gap in valid samples is not evidence of anything,
            // and letting `overThresholdSince` survive it would let a pre-gap excursion and a
            // post-gap one add up to a debounce that never actually happened continuously. The
            // freeze-guard run is dropped for the same reason — but NOT `hasPresentedOnce`, which
            // is a per-STREAM fact and is cleared only by `reset()`.
            overThresholdSince = nil
            ineligibleTicks = 0
            ineligibleSince = nil
            return (nil, nil)
        }

        // Low-pass the raw span (reject per-tick jitter) — every call.
        if let s = smoothedDepth {
            smoothedDepth = emaAlpha * spanSeconds + (1.0 - emaAlpha) * s
        } else {
            smoothedDepth = spanSeconds
        }
        lastCount = count

        let t = hostNow()

        // ── FREEZE GUARD ────────────────────────────────────────────────────────────────────
        //
        // FIRST, and unconditionally. It is evaluated ahead of the snap block precisely so that no
        // other coarse state can suppress it: an unrecoverable clock position must be escapable
        // from every regime, not only from the regimes the snap logic considers healthy.
        if let event = evaluateFreezeGuard(t: t, count: count,
                                           oldestPTS: oldestPTS, newestPTS: newestPTS,
                                           presented: presented) {
            return (event, periodicLogIfDue(t))
        }

        // ── COARSE OUTER LOOP: snap-to-live ─────────────────────────────────────────────────
        //
        // Evaluated at the FULL sample rate, before the controlHz gate, because the excursion
        // timer below must measure real elapsed time rather than a decimated approximation of it.
        // The cost is two comparisons per display tick.
        //
        // The predicate reads the SMOOTHED depth (a single-sample sawtooth peak is not an
        // overfill; the trend is) against a FIXED `targetDepth` — nothing inflates it any more.
        if let depth = smoothedDepth {
            if depth > targetDepth + snapThreshold {
                if overThresholdSince == nil { overThresholdSince = t }
            } else {
                // Back under: the excursion is OVER, whatever it was. Restarting the debounce from
                // scratch is what makes the mechanism reject flicker — see `overThresholdSince`.
                overThresholdSince = nil
            }

            if snapEnabled, snapEligible,
               let since = overThresholdSince, t - since >= snapDebounce {
                // THE SNAP. Re-anchor so now() jumps FORWARD by the excess — the same rebase the
                // rate-change path below performs (evaluate the old mapping at `t`, restart the
                // segment there), plus the deliberate jump. Depth is `newestQueuedPTS − now`, so
                // this is what removes the latency; the renderer's next display tick drops the
                // frames that just went stale, at a frame boundary, through its normal selection.
                //
                // Fires as often as the buffer needs it to. Repeated snaps during a backlog drain
                // are the system WORKING — see the deleted-safety-valve note above.
                let excess = depth - targetDepth
                let sustained = t - since
                let mappedNow = anchorSenderPTS! + (t - anchorHostTime!) * rate
                anchorSenderPTS = mappedNow + excess
                anchorHostTime  = t
                // Hand the P-loop a clean slate at the setpoint: unity rate (not the drain rail it
                // was pinned to while trying to fight this) and a seeded EMA, so it does not spend
                // the next second unwinding a huge stale error it no longer has.
                rate = 1.0
                smoothedDepth = targetDepth
                lastControlHost = nil
                overThresholdSince = nil
                return (.snapped(SnapEvent(depthBefore: depth,
                                           depthAfter: targetDepth,
                                           excess: excess,
                                           sustainedFor: sustained)),
                        periodicLogIfDue(t))
            }
        }

        // Rate-limit the actual rate recompute to `controlHz` — don't chase refresh-rate noise.
        if let last = lastControlHost, t - last < controlInterval {
            return (nil, periodicLogIfDue(t))
        }
        lastControlHost = t

        #if DEBUG || MANIFOLD_TELEMETRY
        // Loop OFF: `rate` is already pinned to 1.0 at entry. Log at the normal cadence and return
        // WITHOUT slewing — so [LIVECLOCK] shows depth/err measured at rate≡1.0, rate=1.0000.
        if forceUnityRate { return (nil, periodicLogIfDue(t)) }
        #endif

        let depth = smoothedDepth ?? spanSeconds
        let error = depth - targetDepth
        // Proportional slew, hard-clamped to ±maxSlew so `rate` stays in ~0.995…1.005.
        // P-LAW UNCHANGED — the computed value is byte-identical to before; it is merely routed
        // through `newRate` so the write can be gated on an actual change and paired with a re-anchor.
        let proposed = 1.0 + k * error
        let newRate = min(1.0 + maxSlew, max(1.0 - maxSlew, proposed))

        // RE-ANCHOR ON RATE CHANGE. The mapping now() = anchorSenderPTS + (hostNow − anchorHostTime)·rate
        // is ABSOLUTE, so assigning a new rate in place jumps now() by (t − anchorHostTime)·(newRate − rate)
        // — a discontinuity that GROWS with session age (~6ms at 60s, ~360ms at 3600s for a 1e-4 delta),
        // yanking presentation position by an ever-larger amount on every loop correction. Instead, rebase
        // the anchor to the CURRENT mapped position (computed with the OLD rate/anchor, reusing the recompute
        // `t` already in hand) and pin the host anchor to `t`, so the new rate applies ONLY GOING FORWARD →
        // now() is continuous across the step by construction, and the rate delta affects only future slope.
        // Gated to ACTUAL changes so a settled rate doesn't churn the anchor every 10Hz tick; the
        // forceUnityRate path returns above (L249) and so never reaches here — pinning can't churn either.
        // now() thereby becomes an anchor writer alongside registerFrame — both serialize on `lock`, so this
        // is safe. The anchor pair is non-nil here (guard above) and is only ever set/cleared atomically as a
        // pair under this lock, so the force-unwraps cannot trap.
        if newRate != rate {
            let mappedNow = anchorSenderPTS! + (t - anchorHostTime!) * rate   // old now() evaluated at t
            anchorSenderPTS = mappedNow
            anchorHostTime  = t
            rate            = newRate
        }

        return (nil, periodicLogIfDue(t))   // the fine loop reports nothing; only coarse actions do
    }

    /// The freeze guard's decision, split out of `updateDepth` only for readability.
    ///
    /// PRECONDITIONS — the caller has already established both, and this method depends on both:
    /// `lock` is HELD (it is a direct extension of `updateDepth`'s critical section, not a new
    /// one), and the anchor pair is NON-NIL (`updateDepth`'s guard returned otherwise). The anchor
    /// is only ever set or cleared as a PAIR under this lock, so the force-unwraps cannot trap —
    /// the same invariant the snap and rate-change rebases rely on a few lines below.
    ///
    /// Runs on the render thread, adding no lock acquisition to the hot path.
    private func evaluateFreezeGuard(t: Double, count: Int,
                                     oldestPTS: Double?, newestPTS: Double?,
                                     presented: Bool) -> Event? {
        // Queue edges not plumbed → the caller has not opted in (the synthetic harness). Inert,
        // and deliberately so; see `updateDepth`'s parameter documentation.
        guard let oldestPTS, let newestPTS else { return nil }

        if presented {
            // A frame reached the screen. That both ARMS the guard for the rest of the stream and
            // clears any run in progress — this is the only place `hasPresentedOnce` is set.
            hasPresentedOnce = true
            ineligibleTicks = 0
            ineligibleSince = nil
            return nil
        }

        // An EMPTY queue is an underrun, not a freeze: there is simply nothing to select, and the
        // clock is positioned correctly. Only a NON-EMPTY queue can be frozen behind.
        guard count > 0 else {
            ineligibleTicks = 0
            ineligibleSince = nil
            return nil
        }

        // Disarmed until the first presentation — this is what excludes the startup fill, which is
        // this exact state by construction. See the section comment for the full argument.
        guard hasPresentedOnce else { return nil }

        ineligibleTicks += 1
        if ineligibleSince == nil { ineligibleSince = t }
        guard let since = ineligibleSince,
              ineligibleTicks >= freezeGuardTicks,
              t - since >= freezeGuardHold else { return nil }

        // FIRE. The clock is behind the entire queue; re-anchor so now() == newest − targetDepth.
        // Same rebase shape as the snap: evaluate the OLD mapping at `t` for the report, then
        // restart the segment at `t` with the corrected position.
        let mappedNow = anchorSenderPTS! + (t - anchorHostTime!) * rate
        let target = targetDepth
        let corrected = newestPTS - target
        let jumped = corrected - mappedNow

        // NEVER MOVE THE CLOCK BACKWARD — AND THIS IS NOW A LIVE PATH, NOT A THEORETICAL ONE.
        //
        // This guard used to be defensive: with the WHEP target at 0.200 s and `freezeGuardHold` at
        // 0.25 s, surviving the hold implied the newest frame was ≥0.25 s ahead, which exceeded the
        // target, so `jumped` was always positive. THAT NO LONGER HOLDS: the measured WHEP target is
        // now 0.400 s, ABOVE the hold, so a run can reach the firing threshold while the whole queue
        // still sits nearer than `targetDepth`. `newest − target` would then land BEHIND the current
        // position — rewinding presentation time, re-showing frames already displayed, and handing
        // the depth EMA a negative error.
        //
        // Bailing is the CORRECT response, not merely a safe one: if the newest frame is closer than
        // the target, the buffer is SHALLOW, which is a starvation transient rather than the runaway
        // this guard exists to escape, and the right amount of clock movement is zero. The run is
        // left counting (`ineligibleTicks`/`ineligibleSince` are untouched on this path), so a
        // genuine freeze re-fires as soon as the queue has filled enough for the jump to be forward.
        guard jumped > 0 else { return nil }
        let heldFor = t - since
        let ticks = ineligibleTicks
        let depthBefore = smoothedDepth ?? (newestPTS - mappedNow)
        let oldestAhead = oldestPTS - mappedNow

        anchorSenderPTS = corrected
        anchorHostTime  = t
        // Same clean slate the snap hands the P-loop: unity rate and a seeded EMA at the setpoint,
        // so it does not spend the next second unwinding an error it no longer has.
        rate = 1.0
        smoothedDepth = target
        lastControlHost = nil
        overThresholdSince = nil
        ineligibleTicks = 0
        ineligibleSince = nil

        // No logging here — this runs under `lock`. The Event carries every field the line needs,
        // and `updateDepth` emits it after unlocking. See the `lock` declaration.
        return .freezeGuard(FreezeGuardEvent(jumped: jumped, ticks: ticks, heldFor: heldFor,
                                             queued: count, oldestAhead: oldestAhead,
                                             depthBefore: depthBefore, target: target))
    }

    /// The queue hit its bound. Re-anchor to `newestPTS − targetDepth`.
    ///
    /// WHY THIS IS A CLOCK ACTION AND NOT A QUEUE ACTION. Reaching `maxQueued` under a LIVE source
    /// is, by definition, excess buffer — the queue is sized with headroom above what the control
    /// loop needs, so touching the bound means more content arrived than real time can carry.
    /// Silently dropping the OLDEST frame is the worst available response: it does not remove one
    /// millisecond of latency (depth is `newest − now`, and evicting the oldest does not move
    /// `newest`), while it DOES discard precisely the frames that were about to become eligible —
    /// which is how the whole window slides into the future and the renderer freezes.
    ///
    /// Moving the CLOCK is what removes the latency. The stale frames then drain naturally on the
    /// next tick through the renderer's existing consume-up-to-newest-eligible path, at a frame
    /// boundary, with no queue surgery. The caller's `removeFirst` trim stays as the mechanical
    /// backstop, but should now be a rare consequence rather than the primary policy.
    ///
    /// NO DEBOUNCE, deliberately. During a backlog drain this may fire several times in quick
    /// succession, and that is CORRECT — it is the backlog draining. Each firing logs its own jump
    /// magnitude and resulting count so the sequence can be counted in the log and confirmed to
    /// stop once surplus goes flat.
    ///
    /// THREADING: called on the SOURCE thread from the enqueue path, after the renderer's queue
    /// lock is released. It takes `lock` — the same lock `registerFrame` already takes on that
    /// thread for every frame — so this introduces no new contention class.
    @discardableResult
    public func overflowReanchor(newestPTS: Double, count: Int) -> Event? {
        lock.lock()
        let event = overflowReanchorLocked(newestPTS: newestPTS, count: count)
        lock.unlock()
        emit(event)   // outside the lock — see the `lock` declaration
        return event
    }

    /// The locked half of `overflowReanchor`. Calls out to nothing and formats nothing.
    private func overflowReanchorLocked(newestPTS: Double, count: Int) -> Event? {
        // Unanchored (no frame has established the mapping yet): nothing to correct.
        guard let aPTS = anchorSenderPTS, let aHost = anchorHostTime, newestPTS.isFinite else {
            return nil
        }
        let t = hostNow()
        let mappedNow = aPTS + (t - aHost) * rate
        let depthBefore = newestPTS - mappedNow
        // Already at or under target — the bound was reached without excess latency (a very deep
        // burst of near-simultaneous PTS, say). Moving the clock BACKWARD is never correct, so the
        // mechanical trim is the whole response.
        guard depthBefore > targetDepth else { return nil }

        let target = targetDepth
        anchorSenderPTS = newestPTS - target
        anchorHostTime  = t
        rate = 1.0
        smoothedDepth = target
        lastControlHost = nil
        overThresholdSince = nil
        // The clock just moved forward over most of the queue, so any ineligible run in progress
        // describes a position that no longer exists. `hasPresentedOnce` is untouched — the stream
        // is continuing, not restarting.
        ineligibleTicks = 0
        ineligibleSince = nil

        let jumped = depthBefore - target
        return .overflowReanchor(OverflowEvent(jumped: jumped, queued: count,
                                               depthBefore: depthBefore, target: target))
    }

    /// Snapshot of the ~1 Hz telemetry line, taken under `lock` and formatted after the unlock.
    /// Plain scalars: capturing them costs four loads, where formatting them would allocate.
    private struct PeriodicLog {
        let depth: Double
        let target: Double
        let rate: Double
        let count: Int
    }

    /// ~1 Hz telemetry gate: watch `depth` settle to `target` and `rate` settle to the sender's true
    /// ratio under injected drift. Called UNDER `lock`; it only reads state and advances the cadence
    /// gate, returning the payload for the caller to emit once unlocked. Returns nil when not due.
    private func periodicLogIfDue(_ t: Double) -> PeriodicLog? {
        #if DEBUG || MANIFOLD_TELEMETRY
        if let last = lastLogHost, t - last < 1.0 { return nil }
        lastLogHost = t
        // `target` is now always the CONFIGURED one — nothing inflates it, so there is no longer a
        // second regime to distinguish and the old DEGRADED marker has gone with the mechanism.
        return PeriodicLog(depth: smoothedDepth ?? .nan, target: targetDepth,
                           rate: rate, count: lastCount)
        #else
        return nil
        #endif
    }

    // MARK: - Emit (NEVER under `lock`)
    //
    // Everything below formats and writes. `String(format:)` allocates and `FileHandle.write` is a
    // syscall — either one inside a priority-donating critical section is worse than the inversion
    // the lock was converted to fix, because a boosted holder that blocks on I/O burns real-time
    // priority instead of yielding it. These take only value-type payloads snapshotted under the
    // lock, so they CANNOT touch clock state even by accident.

    private func emit(_ log: PeriodicLog?) {
        #if DEBUG || MANIFOLD_TELEMETRY
        guard let log else { return }
        FileHandle.standardError.write(Data(String(
            format: "[LIVECLOCK] depth=%.3fs target=%.3f rate=%.4f err=%+.4f count=%d\n",
            log.depth, log.target, log.rate, log.depth - log.target, log.count).utf8))
        #endif
    }

    /// The coarse actions LiveClock reports itself. `.snapped` is deliberately absent: the transport
    /// layer logs that one with its own context (see WHEPFrameRouter), and duplicating it here would
    /// print every snap twice.
    private func emit(_ event: Event?) {
        #if DEBUG || MANIFOLD_TELEMETRY
        switch event {
        case .freezeGuard(let fg):
            FileHandle.standardError.write(Data(String(
                format: "[LIVECLOCK] freeze-guard: no eligible frame for %d ticks / %.3fs, queue=%d, "
                      + "oldest=+%.3fs ahead — re-anchored (depth %.3f → target %.3f, jumped +%.3fs)\n",
                fg.ticks, fg.heldFor, fg.queued, fg.oldestAhead,
                fg.depthBefore, fg.target, fg.jumped).utf8))
        case .overflowReanchor(let ov):
            FileHandle.standardError.write(Data(String(
                format: "[LIVECLOCK] queue-full: over-buffered at count=%d — re-anchored "
                      + "(depth %.3f → target %.3f, jumped +%.3fs)\n",
                ov.queued, ov.depthBefore, ov.target, ov.jumped).utf8))
        case .snapped, .none:
            break
        }
        #endif
    }

    private func emitTargetStep(from: Double, to: Double) {
        #if DEBUG || MANIFOLD_TELEMETRY
        FileHandle.standardError.write(Data(String(
            format: "[LIVECLOCK] targetDepth %.3f -> %.3f (manual)\n", from, to).utf8))
        #endif
    }

    /// Clear the anchor so the next `registerFrame` re-anchors — for a new stream, a reconnect,
    /// or (in the synthetic harness) a loop back to the file's head. Also RE-ARMS the control loop.
    /// Safe to call from any thread.
    public func reset() {
        lock.lock()
        anchorSenderPTS = nil
        anchorHostTime = nil
        // Re-arm the control loop cleanly for the next stream/loop: forget the smoothed depth and
        // cadence gates, and return the rate to unity so a fresh anchor starts from wall-clock speed.
        smoothedDepth = nil
        lastControlHost = nil
        lastLogHost = nil
        lastCount = 0
        rate = 1.0
        // Snap state is per-STREAM, so it clears with everything else: a reconnect starts from the
        // aggressive low-latency posture with no excursion in progress.
        overThresholdSince = nil
        // FREEZE-GUARD STATE IS PER-STREAM TOO, AND `hasPresentedOnce` ESPECIALLY SO. A reconnect
        // performs a fresh `startupDepth` fill, which is BY CONSTRUCTION the state the guard
        // triggers on (queue filling, nothing eligible). Leaving the flag armed across a reconnect
        // would re-anchor away the whole `startupDepth` cushion on the second and every subsequent
        // connect —
        // the exact failure the arm-after-first-present rule exists to prevent, merely displaced
        // from first connect to every later one. Same discipline as clearing the drift state on
        // reconnect so a gap cannot manufacture phantom drift.
        ineligibleTicks = 0
        ineligibleSince = nil
        hasPresentedOnce = false
        lock.unlock()
    }

    /// The app's established monotonic host clock — the same one NDI stamps frames with
    /// (`CACurrentMediaTime()`). Read under `lock` by both `registerFrame` and `now`.
    private func hostNow() -> Double {
        CACurrentMediaTime()
    }
}
