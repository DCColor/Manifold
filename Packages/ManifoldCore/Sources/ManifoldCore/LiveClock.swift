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
    ///
    /// ⚠️ SETTING THIS TO 0 IS NOT "DISABLE THE VIDEO LOOP" — it also silently removes WHEP's and
    /// SRT's only audio-drift correction. Read the slew-site note in `updateDepthLocked` first.
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

    #if DEBUG || MANIFOLD_TELEMETRY
    // ── STARTUP TELEMETRY: depth at the first presentation, and arrivals either side of it ──────
    //
    // `docs/AUDIO_RESAMPLER_DESIGN.md` §10.9: the connect-time rail is an offset created at the
    // anchor, partly by frames that arrive in a burst straight after it. These answer the two
    // questions that analysis could only infer from 1 Hz lines: what depth the stream actually
    // had when the picture started, and whether any burst frame arrived AFTER that.
    //
    // ⚠️ THE ORIGIN IS THE FIRST FRAME'S (senderPTS, arrival host), NOT THE MAPPING. The mapping is
    // re-anchored during startup; the arrival schedule is not. `lead` = how early a frame arrived
    // against the first frame's schedule — a burst frame has a large positive lead; an on-time
    // frame has ≈ 0 plus network jitter.
    private var startupOriginPTS: Double?
    private var startupOriginHost: Double?
    private var startupPresentHost: Double?
    private var startupPreMaxLead = -Double.infinity
    private var startupPostMaxLead = -Double.infinity
    private var startupPostFrames = 0
    private var startupPostMinErr = Double.infinity
    private var startupPostMaxErr = -Double.infinity
    private var startupRealigns = 0
    private var startupRealignNet = 0.0
    private var startupSummaryDone = false
    /// Payloads captured under `lock`, formatted after it — the same discipline as `PeriodicLog`.
    private var pendingStartupPresent: StartupPresentLog?
    private var pendingStartupSummary: StartupSummaryLog?
    /// How long after the first presentation arrivals are still watched for a late burst. Two
    /// seconds is ~48 frame intervals: a decoder backlog drains in milliseconds, so anything still
    /// arriving early after this is network jitter, not startup.
    private static let startupWatchSeconds = 2.0
    #endif

    /// Smallest startup-fill offset worth a re-anchor. See the startup-fill block in
    /// `updateDepthLocked`.
    private static let startupRealignFloor = 0.001

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
        /// During the startup fill (before the first presentation), the anchor's depth offset was
        /// corrected by position at rate 1.0 instead of by rate. Either sign. See
        /// `updateDepthLocked`'s startup-fill block.
        case startupRealign(StartupRealignEvent)

        /// Seconds of presentation time the clock jumped FORWARD, for whichever action fired.
        /// This is the quantity a surplus accountant must sum as "flushed": every one of these
        /// events discards exactly this much buffered content.
        public var jumped: Double {
            switch self {
            case .snapped(let e):          return e.excess
            case .freezeGuard(let e):      return e.jumped
            case .overflowReanchor(let e): return e.jumped
            case .startupRealign(let e):   return e.jumped
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

    public struct StartupRealignEvent: Sendable {
        /// Seconds the presentation clock moved — FORWARD if positive (the fill was too deep),
        /// BACKWARD if negative (too shallow). Negative is legitimate here and only here: nothing
        /// has been presented yet, so there is no shown position to go back past.
        public let jumped: Double
        /// Smoothed depth immediately before the re-anchor.
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
    ///
    /// ⚠️ DIAGNOSTIC-ONLY FOR A REASON BEYOND THE MEASUREMENT IT SERVES: while pinned, WHEP's and
    /// SRT's desktop audio has NO drift correction at all (the slew is what supplies it — see the
    /// note at the slew site in `updateDepthLocked`). Fine for a short depth reading, which is all
    /// this is for. NOT a mechanism to promote to a shipping low-latency mode as it stands.
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
    #if DEBUG || MANIFOLD_TELEMETRY
    // ── WHETHER [LIVECLOCK] IS WRITTEN AT ALL ────────────────────────────────────────────────
    //
    // ⚠️ THE `#if` ABOVE EVERY EMIT SITE IS NOT A GATE, AND THAT IS WHY THIS EXISTS.
    // `MANIFOLD_TELEMETRY` is defined UNCONDITIONALLY in Package.swift (see the long note there:
    // Xcode maps a package's configuration by NAME, so no package-side predicate can tell Profile
    // from Release). The condition is therefore ALWAYS TRUE in this module, in every configuration
    // — so the compile-time gate decides nothing and a shipping Release build wrote
    // `[LIVECLOCK] depth=…` to stderr at 1 Hz for every live source. Measured 2026-09-21.
    //
    // This runtime flag is what actually decides. Default OFF, so Release is silent by omission
    // rather than by anyone remembering to switch it off. The app opts in, in `#if DEBUG` only.
    private static let telemetryOptInLock = UnfairLock()
    private static var telemetryOptIn = false

    /// Turn `[LIVECLOCK]` emission on for clocks created AFTER this call.
    ///
    /// ⚠️ **CALL ONCE, AT LAUNCH, BEFORE ANY LIVE SOURCE CAN CONNECT** — see the capture note on
    /// `telemetryEnabled`. Calling it later is not a race, it simply does not affect clocks that
    /// already exist, which is the safe direction to fail in.
    public static func enableTelemetry() {
        telemetryOptInLock.lock()
        telemetryOptIn = true
        telemetryOptInLock.unlock()
    }

    /// Whether `enableTelemetry()` has been called — i.e. whether this is a build that emits
    /// diagnostics at all.
    ///
    /// ⚠️ EXPOSED SO OTHER DIAGNOSTICS SHARE THIS ONE SWITCH RATHER THAN INVENTING THEIR OWN.
    /// `MANIFOLD_TELEMETRY` is defined in every configuration including Release (see
    /// `Package.swift`), so a compile gate cannot keep package-side diagnostics out of a shipping
    /// build and a RUNTIME gate is what does it. `ManifoldApp.init` sets this under `#if DEBUG`
    /// and nothing else calls it, which makes this the app's single answer to "is this a
    /// diagnostic build". A second switch alongside it could disagree, and then a Release build
    /// would emit from one subsystem and not another.
    public static var telemetryIsEnabled: Bool {
        telemetryOptInLock.lock(); defer { telemetryOptInLock.unlock() }
        return telemetryOptIn
    }

    /// ⚠️ **CAPTURED ONCE, AT CONSTRUCTION, AND `let` THEREAFTER — WHICH IS THE WHOLE POINT.**
    ///
    /// The emit sites are reached from the frame-registration path, i.e. the source/clock thread.
    /// Reading a mutable `static var` there would be a genuine data race against the app's write,
    /// and taking a lock per emit would put a lock acquisition in a path whose own doc comment
    /// forbids doing anything slow. Snapshotting into an immutable instance `let` removes both:
    /// the only synchronised read happens on the constructing thread, and every later read on the
    /// clock thread touches a `let` that cannot change.
    ///
    /// A clock is constructed per connection (`LiveDisplayRoute`, `SyntheticLiveSource`), always
    /// after launch, so an opt-in at startup is captured by every clock that can ever exist.
    private let telemetryEnabled: Bool
    #endif

    public init(startupDepth: Double = 0.15, targetDepth: Double = 0.15) {
        self.startupDepth = startupDepth
        self.targetDepth = targetDepth
        #if DEBUG || MANIFOLD_TELEMETRY
        Self.telemetryOptInLock.lock()
        self.telemetryEnabled = Self.telemetryOptIn
        Self.telemetryOptInLock.unlock()
        #endif
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
        if anchorSenderPTS == nil {
            // `hostNow() + startupDepth` — the anchor is pinned into the FUTURE so the buffer fills
            // before the first frame comes due. The audio mirror inherits this for free now that it
            // tracks the mapping rather than copying now()'s value once.
            setMappingLocked(senderPTS: senderPTS, hostTime: hostNow() + startupDepth, rate: rate)
            #if DEBUG || MANIFOLD_TELEMETRY
            startupOriginPTS = senderPTS
            startupOriginHost = hostNow()
            #endif
        } else {
            #if DEBUG || MANIFOLD_TELEMETRY
            if let oPTS = startupOriginPTS, let oHost = startupOriginHost, !startupSummaryDone {
                let h = hostNow()
                let lead = (senderPTS - oPTS) - (h - oHost)
                if let p = startupPresentHost {
                    if h - p <= Self.startupWatchSeconds {
                        startupPostMaxLead = max(startupPostMaxLead, lead)
                        startupPostFrames += 1
                    }
                } else {
                    startupPreMaxLead = max(startupPreMaxLead, lead)
                }
            }
            #endif
        }
        lock.unlock()
        publishMappingIfChanged()
        // rate == 1.0 (Step 1): presentation PTS == sender PTS. When Step 2 modulates `rate`,
        // this becomes the sender→presentation remap and stops being an identity.
        return senderPTS
    }

    // ══════════════════════════════════════════════════════════════════════════════════════
    // THE MAPPING SEAM — ONE PLACE, BECAUSE THERE WERE ALREADY MORE SITES THAN ANYONE THOUGHT
    // ══════════════════════════════════════════════════════════════════════════════════════
    //
    // `now()` is a cursor: `anchorSenderPTS + (hostNow() - anchorHostTime) * rate`. Video reads it
    // every frame, so it follows any change for free. Anything else that must stay in lockstep —
    // the WHEP audio timebase — cannot, because it holds its own clock and can only be TOLD.
    //
    // ⚠️ THE COUNT IS WHY THIS IS A FUNNEL AND NOT N CALL SITES. An audit of this file listed five
    // places that rewrite the mapping. There are SEVEN: `registerFrame`, `adjustTargetDepthLocked`,
    // the `forceUnityRate` pin, the snap, the P-loop rate change, `evaluateFreezeGuard`, and
    // `overflowReanchorLocked` — the last of which the audit's own grep truncated away. A design
    // that needs a mirror call added to each one was already one site out of date before it shipped.
    //
    // So the fields are written through `setMappingLocked` and nowhere else, and
    // `publishMappingIfChanged` is called after every unlock that could have touched them. An
    // eighth site that assigns the fields directly is caught by the tripwire below rather than
    // silently desynchronising the audio.

    /// The sender→host mapping, whole. `now()` at `hostTime` is exactly `senderPTS`, advancing at
    /// `rate` per host second.
    public struct Mapping: Sendable, Equatable {
        public let senderPTS: Double
        public let hostTime: Double
        public let rate: Double
    }

    /// Fires whenever the mapping changes — including the first anchor — and with `nil` when
    /// `reset()` un-anchors. CALLED OUTSIDE `lock`, on whichever thread made the change (the source
    /// thread for `registerFrame`, the display tick for `updateDepth`, main for the tuning hooks).
    /// A consumer must therefore be safe to call from any thread and must not block.
    public var onMappingChange: ((Mapping?) -> Void)?

    /// ── THE HEARTBEAT: THE MAPPING RE-STATED AT THE CONTROL CADENCE, CHANGED OR NOT ──────────
    ///
    /// Fires at `controlHz` while anchored, carrying the live mapping **re-expressed at the instant
    /// it fires**: `senderPTS = now()`, `hostTime = t`, same `rate`. Same thread contract as
    /// `onMappingChange` — called OUTSIDE `lock`, from whichever thread drained it, must not block.
    ///
    /// ⚠️ WHY THIS EXISTS, AND WHY IT IS NOT A LOOSENING OF THE PUBLICATION GATE. The gate above is
    /// correct and is deliberately untouched: it exists so a SETTLED rate does not churn the anchor
    /// at 10 Hz, and churning the anchor is a real defect (it was audible pitch wobble). But the
    /// consumer's job is not "react to rate changes" — it is "keep a SEPARATE timebase, running at a
    /// DELIBERATELY DIFFERENT rate, from walking away from this one". `FrameEngine.mirrorLiveAudio`
    /// smooths the rate it mirrors with a 30 s EMA precisely so it does NOT follow the P-loop's
    /// ±0.5% depth correction — so the two rates differ BY DESIGN, so a position error accrues BY
    /// DESIGN, and correcting it cannot be conditional on the clock's rate happening to move.
    ///
    /// The failure that produced this: while the P-loop is saturated against its slew clamp, every
    /// recompute yields a bit-identical `Double`, `newRate != rate` is deterministically false, and
    /// publication stops for as long as saturation lasts. The audio timebase was then left running
    /// at its own rate with nothing watching, walking at ~5 ms/s until a coarse re-anchor yanked it
    /// back in one audible step. Full derivation: `docs/LIVECLOCK_AUDIO_MIRROR_FINDINGS.md`.
    ///
    /// ⚠️ THE TICK AND THE CHANGE DESCRIBE THE SAME TIMEBASE — that is what makes this safe. A
    /// mapping is a LINE: `(senderPTS, hostTime)` is one point on it and `rate` is its slope. The
    /// tick hands over a different POINT on the SAME line, so a consumer that anchors from it lands
    /// on exactly the timebase the anchor form would have produced. The heartbeat cannot change what
    /// the mapping MEANS; it can only change WHEN the consumer gets to notice it has drifted from
    /// it. Nothing here writes clock state, so `now()` is bit-identical with the heartbeat installed
    /// or not, and video cannot be affected by it.
    ///
    /// ⚠️ A CONSUMER MUST BE IDEMPOTENT UNDER IT. This fires whether or not anything changed, so a
    /// consumer that acts unconditionally on every call will act 10×/second. `mirrorLiveAudio` is
    /// safe because its `shouldPush` gate decides for itself; a new consumer needs the same property.
    public var onMappingTick: ((Mapping) -> Void)?

    /// Set under `lock` by `setMappingLocked`; drained by `publishMappingIfChanged` after unlock.
    private var mappingDirty = false
    /// What was last handed to `onMappingChange` — the tripwire's reference.
    private var lastPublishedMapping: Mapping?
    /// Host time of the last mirror EVALUATION — a publication or a heartbeat, whichever came last.
    /// Gates the heartbeat to `controlHz`, and is why a healthily-publishing clock emits almost no
    /// ticks: every publication re-stamps this, so the heartbeat only fills SILENCE.
    private var lastMirrorTickHost: Double?
    /// Host time of the last actual PUBLICATION — the starvation tripwire's reference. Distinct from
    /// `lastMirrorTickHost` on purpose: the tripwire must measure the gate, not the thing covering
    /// for it, or it would be silenced by its own remedy.
    private var lastPublishHost: Double?
    /// Rate-limits the starvation tripwire. Nil until it has fired once in this anchored run.
    private var lastStarvationWarnHost: Double?

    /// How long the P-loop may publish nothing before the tripwire says so. Healthy is ~8–9/s, and
    /// the dead band produces ZERO — so 3 s is ~25 missed control ticks, far outside anything a
    /// working loop does, and well inside the 15–20 s period of the failure it exists to catch.
    private static let publicationStarvationSeconds = 3.0
    /// Re-warn interval once starving, so a stream that sits in the dead band for ten minutes leaves
    /// a readable trail rather than 6,000 lines.
    private static let starvationRewarnSeconds = 30.0

    /// ── THE PUBLICATION-GAP DISTRIBUTION ────────────────────────────────────────────────────
    ///
    /// Intervals between successive PUBLICATIONS (not evaluations), bucketed. This is the number
    /// that decides every question about the heartbeat — whether a healthy clock needs one, what
    /// interval it should run at, whether a given transport is entering the dead band and for how
    /// long — and it lived in a throwaway bench script until it falsified a design premise. It is
    /// in the log so the next such question is answered from a session rather than re-derived.
    ///
    /// FIXED FIELDS RATHER THAN AN ARRAY OR A SAMPLE BUFFER, because this is accumulated under
    /// `lock`: adding a gap must not allocate, must not grow, and must not depend on how many gaps
    /// a window happens to contain. A histogram gives the shape; percentiles over retained samples
    /// would give two more digits and a heap allocation on the highest-traffic lock in the codebase.
    private struct GapHistogram {
        var n = 0
        var maxMs = 0.0
        var under50 = 0, under100 = 0, under200 = 0, under500 = 0
        var under1k = 0, under2k = 0, over2k = 0

        mutating func add(_ ms: Double) {
            n += 1
            if ms > maxMs { maxMs = ms }
            switch ms {
            case ..<50:    under50  += 1
            case ..<100:   under100 += 1
            case ..<200:   under200 += 1
            case ..<500:   under500 += 1
            case ..<1000:  under1k  += 1
            case ..<2000:  under2k  += 1
            default:       over2k   += 1
            }
        }
    }

    /// Accumulating window. Snapshotted and cleared by `publicationGapsLocked`.
    private var gaps = GapHistogram()
    /// Host time the current gap window opened. Nil until the first publication of a stream.
    private var gapWindowStart: Double?

    /// 10 s, matching `mirrorLiveAudio`'s own stats cadence so the two lines pair up in the log:
    /// one says what the clock published, the next says what the mirror did about it.
    private static let gapReportSeconds = 10.0

    /// What the starvation tripwire needs to say. Assembled under `lock`, formatted outside it —
    /// the same split every other telemetry payload in this file uses, for the same reason.
    private struct PublicationStarvation {
        let silentFor: Double
        let rate: Double
        let err: Double
        let railed: Bool
        /// Whether anyone actually installed `onMappingTick`. The line says what the consequence IS,
        /// and it cannot know that without asking — a tripwire that assures the reader audio is
        /// covered when nothing is covering it would be the fourth instrument reading healthy while
        /// something is wrong, which is the thing this was added to stop.
        let heartbeatInstalled: Bool
    }

    /// THE ONLY writer of `anchorSenderPTS` / `anchorHostTime` / `rate`. Call under `lock`.
    private func setMappingLocked(senderPTS: Double, hostTime: Double, rate newRate: Double) {
        anchorSenderPTS = senderPTS
        anchorHostTime  = hostTime
        rate            = newRate
        mappingDirty    = true
    }

    /// Un-anchor. Call under `lock`. Publishes `nil`.
    private func clearMappingLocked() {
        anchorSenderPTS = nil
        anchorHostTime  = nil
        rate            = 1.0
        mappingDirty    = true
    }

    /// Drain a pending mapping change to `onMappingChange`. MUST be called with `lock` NOT held —
    /// the consumer touches a CMTimebase, which is not work to do under a priority-donating lock.
    /// Cheap and safe to call unconditionally after any unlock.
    /// ⚠️ IT ALSO DRAINS THE HEARTBEAT, AND THAT IS WHY IT IS STILL ONE LOCK ACQUISITION. The
    /// heartbeat needs the same three fields under the same lock, on the same call, at the same
    /// instant. Giving it its own entry point would mean a SECOND acquisition of the highest-traffic
    /// donating lock in the codebase on every display tick — see the `lock` declaration for why that
    /// is not a small thing. So the `guard mappingDirty` branch, which is where the mapping is by
    /// definition NOT being published, is exactly where the heartbeat belongs.
    ///
    /// THE PUBLICATION GATE ITSELF IS UNCHANGED, deliberately and completely: same condition, same
    /// dirty flag, same callback, same tripwire. What follows the `guard` is new; the `guard` is not.
    private func publishMappingIfChanged() {
        let t = hostNow()
        lock.lock()
        let live: Mapping? = (anchorSenderPTS != nil && anchorHostTime != nil)
            ? Mapping(senderPTS: anchorSenderPTS!, hostTime: anchorHostTime!, rate: rate) : nil
        guard mappingDirty else {
            // ── TRIPWIRE ────────────────────────────────────────────────────────────────────
            // Nothing declared a change, so the live mapping must equal what we last published.
            // If it does not, some site assigned the fields directly instead of going through
            // `setMappingLocked`, and the audio timebase is now silently wrong. Loud on purpose.
            let drifted = live != lastPublishedMapping
            // Same critical section, no extra acquisition: is a heartbeat due, and has the gate
            // been silent long enough to report?
            let tick = mirrorTickLocked(at: t)
            let starving = starvationLocked(at: t, tickDue: tick != nil)
            let gapReport = publicationGapsLocked(at: t)
            let tickCallback = onMappingTick
            lock.unlock()
            if drifted {
                NSLog("[LIVECLOCK] ⚠️ MAPPING CHANGED WITHOUT setMappingLocked — an anchor/rate "
                    + "write bypassed the funnel; the audio timebase will not be mirrored")
            }
            // Mirror first, log second — the same ordering `updateDepth` uses, so the audio timebase
            // is never behind a line describing it.
            if let tick { tickCallback?(tick) }
            emit(starving)
            emit(gapReport)
            return
        }
        mappingDirty = false
        lastPublishedMapping = live
        // A publication IS an evaluation: the consumer has just been handed the current mapping, so
        // the heartbeat has nothing to add and its cadence restarts here. The heartbeat fills
        // SILENCE rather than running alongside publication.
        //
        // ⚠️ A HEALTHY CLOCK STILL EMITS TICKS, AND A LONGER INTERVAL DOES NOT FIX THAT — it was
        // tried and measured. At a 500 ms interval, profiles with a HEALTHY ±13 ms error envelope
        // still went silent for longer than that 45–54 times per 90 s, with single gaps reaching
        // 1.0–1.4 s, because an envelope twice the 6.25 ms rail threshold RAILS ON EVERY EXCURSION;
        // it simply does not stay there. So the dead band is not a condition the healthy path
        // avoids — it enters it dozens of times a minute and leaves before the ~5 ms/s walk reaches
        // the mirror's 10 ms tolerance. The margin is about 2×, not immunity.
        //
        // The 500 ms trial bought no healthy-path invariance and cost 2.8× on the case the
        // heartbeat exists for (worst |timebase−clock| 10.22 ms → 28.83 ms over ten minutes), so the
        // interval is the control cadence. `publicationGapsLocked` below is what measures this, and
        // it is in the log precisely so the question is never re-argued from a bench script.
        // The gap this publication closes, recorded before the stamp that would erase it.
        if let lastPub = lastPublishHost { gaps.add((t - lastPub) * 1000) }
        if gapWindowStart == nil { gapWindowStart = t }
        lastMirrorTickHost = t
        lastPublishHost = t
        lastStarvationWarnHost = nil     // the gate is alive again; re-arm for the next silence
        let gapReport = publicationGapsLocked(at: t)
        let callback = onMappingChange
        lock.unlock()
        callback?(live)
        emit(gapReport)
    }

    /// The heartbeat's locked half: is one due, and if so, what is the mapping RIGHT NOW?
    ///
    /// Returns the live mapping re-expressed at `t` — `senderPTS` is `now()` evaluated at `t` using
    /// the CURRENT anchor and rate, `hostTime` is `t`. That is the same rebase the P-loop performs
    /// when it changes rate, minus the part that writes anything: **this function does not touch
    /// `anchorSenderPTS`, `anchorHostTime` or `rate`, does not call `setMappingLocked`, and does not
    /// set `mappingDirty`.** It is a read, expressed in a different basis.
    ///
    /// ⚠️ THE RE-EXPRESSION IS THE ENTIRE POINT — THE ANCHOR FORM WOULD NOT WORK HERE. A consumer
    /// evaluating a SATURATED clock repeatedly sees a constant `(anchorSenderPTS, anchorHostTime)`,
    /// so `mirrorLiveAudio`'s `target` would be constant, its `predicted` would be constant, and its
    /// position error would read the same value forever while the real divergence grew. Handing over
    /// the CURRENT point on the line is what makes the accruing error visible to a gate that
    /// compares "where the mapping says we are" against "where we last said we were".
    ///
    /// Call under `lock`.
    private func mirrorTickLocked(at t: Double) -> Mapping? {
        guard let aPTS = anchorSenderPTS, let aHost = anchorHostTime else {
            // Un-anchored: `now()` is the -.infinity sentinel and there is nothing truthful to say.
            // The mirror is told to hold by the `nil` publication `reset()` already sends.
            lastMirrorTickHost = nil
            return nil
        }
        guard let last = lastMirrorTickHost else {
            // First drain after the anchor — seed the cadence rather than fire immediately. The
            // anchor itself was a publication, so the consumer is already current.
            lastMirrorTickHost = t
            return nil
        }
        guard t - last >= controlInterval else { return nil }
        lastMirrorTickHost = t
        return Mapping(senderPTS: aPTS + (t - aHost) * rate, hostTime: t, rate: rate)
    }

    /// Snapshot and reset the gap window if it is due. Call under `lock`.
    ///
    /// ⚠️ CALLED FROM BOTH BRANCHES OF THE DRAIN, AND THAT IS NOT REDUNDANT. A window driven only by
    /// publications would stop reporting exactly when publication stops — the failure this whole
    /// mechanism exists for would erase its own measurement. The tick path is what keeps the window
    /// turning through silence, so a starved stream still prints `n=0` rather than printing nothing.
    private func publicationGapsLocked(at t: Double) -> (window: Double, gaps: GapHistogram)? {
        guard let start = gapWindowStart else { return nil }
        let window = t - start
        guard window >= Self.gapReportSeconds else { return nil }
        let snapshot = gaps
        gaps = GapHistogram()
        gapWindowStart = t
        return (window, snapshot)
    }

    /// ── THE STARVATION TRIPWIRE ──────────────────────────────────────────────────────────────
    ///
    /// The P-loop has published nothing for `publicationStarvationSeconds` while anchored. Say so.
    ///
    /// ⚠️ WHY THIS IS NOT COVERED BY THE TRIPWIRES THAT ALREADY EXIST. The slew-site note in
    /// `updateDepthLocked` enumerates the ways the slew can stop — `forceUnityRate`, `maxSlew = 0`,
    /// an early return on stable depth — and every one of them is a code change somebody would have
    /// to make on purpose. The way it actually stopped needed no edit at all: the loop kept running
    /// and kept computing, but SATURATED, and a railed rate publishes nothing for exactly the same
    /// reason a settled one does not. A tripwire that watches for the slew pinned at UNITY is blind
    /// to it pinned at the RAIL, which looks healthier in every log.
    ///
    /// ⚠️ IT MEASURES `lastPublishHost`, NOT `lastMirrorTickHost`. The heartbeat now covers this
    /// condition, so a tripwire keyed to evaluations would be permanently silenced by its own
    /// remedy — reporting health because the workaround is working. It reports the GATE.
    ///
    /// Call under `lock`. `tickDue` keeps the check on the heartbeat's cadence rather than the
    /// display tick's, so it costs one comparison per tick and nothing else.
    private func starvationLocked(at t: Double, tickDue: Bool) -> PublicationStarvation? {
        guard tickDue, let lastPub = lastPublishHost else { return nil }
        let silentFor = t - lastPub
        guard silentFor >= Self.publicationStarvationSeconds else { return nil }
        if let warned = lastStarvationWarnHost, t - warned < Self.starvationRewarnSeconds {
            return nil
        }
        lastStarvationWarnHost = t
        let err = (smoothedDepth ?? targetDepth) - targetDepth
        // "Railed" = sitting on the slew clamp, which is the saturation case this was written for.
        // Stated as a measurement rather than inferred from `err`, so a future change to how the
        // rate is computed cannot make the label lie.
        let railed = abs(abs(rate - 1.0) - maxSlew) < 1e-12
        return PublicationStarvation(silentFor: silentFor, rate: rate, err: err, railed: railed,
                                     heartbeatInstalled: onMappingTick != nil)
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
        publishMappingIfChanged()                                           // outside the lock
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
            setMappingLocked(senderPTS: mappedNow - shift, hostTime: t, rate: rate)
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
        #if DEBUG || MANIFOLD_TELEMETRY
        let startupPresent = pendingStartupPresent, startupSummary = pendingStartupSummary
        pendingStartupPresent = nil; pendingStartupSummary = nil
        #endif
        lock.unlock()
        // The mapping mirror goes FIRST: a snap or rate change must reach the audio timebase before
        // the line describing it reaches the log, so the two cannot be read in the wrong order.
        publishMappingIfChanged()
        // OUTSIDE THE LOCK, ALWAYS. See the `lock` declaration: formatting allocates and writing to
        // stderr is a syscall, and neither may happen while holding a priority-donating lock.
        // Periodic line first, then the coarse action — the order the log had before the split, so
        // a snap still reads as following the depth line whose value it just changed.
        emit(periodic)
        emit(event)
        #if DEBUG || MANIFOLD_TELEMETRY
        emit(startupPresent, startupSummary)
        #endif
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
                setMappingLocked(senderPTS: aPTS + (t - aHost) * rate,   // old now() evaluated at t
                                 hostTime: t, rate: 1.0)
            } else {
                rate = 1.0
            }
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

        #if DEBUG || MANIFOLD_TELEMETRY
        if let p = startupPresentHost, !startupSummaryDone, let d = smoothedDepth {
            startupPostMinErr = min(startupPostMinErr, d - targetDepth)
            startupPostMaxErr = max(startupPostMaxErr, d - targetDepth)
            if t - p >= Self.startupWatchSeconds {
                startupSummaryDone = true
                pendingStartupSummary = StartupSummaryLog(
                    window: t - p, postFrames: startupPostFrames, postMaxLead: startupPostMaxLead,
                    minErr: startupPostMinErr, maxErr: startupPostMaxErr)
            }
        }
        #endif

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
                // Hand the P-loop a clean slate at the setpoint: unity rate (not the drain rail it
                // was pinned to while trying to fight this) and a seeded EMA, so it does not spend
                // the next second unwinding a huge stale error it no longer has.
                setMappingLocked(senderPTS: mappedNow + excess, hostTime: t, rate: 1.0)
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

        // ══════════════════════════════════════════════════════════════════════════════════
        // ⚠️ THE SLEW IS LOAD-BEARING FOR **AUDIO DRIFT CORRECTION**, NOT ONLY FOR VIDEO DEPTH.
        // ⚠️ DO NOT PIN `rate` AT UNITY WITHOUT READING THIS. IT LOOKS FREE. IT IS NOT.
        // ══════════════════════════════════════════════════════════════════════════════════
        //
        // Everything below reads as a VIDEO control loop, and that is all it was written to be.
        // It is also, entirely by accident, the only thing keeping WHEP's and SRT's DESKTOP AUDIO
        // from drifting out of lip-sync over a long session. The chain is not visible from here,
        // which is exactly why this comment is here and not only in the docs:
        //
        //   * `FrameEngine.mirrorLiveAudio` forwards every mapping change to the audio
        //     synchronizer as `setRate(_:time:atHostTime:)`, which is an ABSOLUTE re-anchor: it
        //     restates "media time T at host time H" and so WIPES whatever error had accumulated.
        //   * The synchronizer's timebase is driven by the AUDIO DEVICE's clock, not by mach time
        //     (`AVSampleBufferRenderSynchronizer.h`: "this timebase will be driven by the clock of
        //     an added AVSampleBufferAudioRenderer"; `FrameEngine` adds one unconditionally at
        //     init). The PTS fed to it are on the mach axis. Two crystals — they diverge, measured
        //     at −7.8 ppm on one machine (≈28 ms/hour), and that figure is a property of the
        //     output device, not a constant.
        //   * `mirrorLiveAudio`'s push gate is OPEN-LOOP — its `predicted` comes from what it last
        //     pushed plus host time, never from `synchronizer.currentTime()` — so it CANNOT SEE
        //     that divergence. Nothing in the audio path detects it. Nothing corrects it.
        //
        // What actually corrects it is the line below moving `rate`. Each move publishes a mapping,
        // which becomes a `setRate(atHostTime:)`, which re-anchors, which wipes the drift. **Nobody
        // designed a drift corrector; one fell out of the video path.** WHEP and SRT are bounded by
        // ACCIDENT.
        //
        // ⚠️ SO IF THE SLEW EVER STOPS — pinned at unity for a low-latency mode, `maxSlew` set to 0,
        // an early return because "depth is stable, stop correcting" — WHEP AND SRT SILENTLY BECOME
        // UNBOUNDED TOO. The failure is the worst shape available: slow lip-sync drift over a long
        // session, with EVERY COUNTER READING CLEAN, because every counter in the audio path is
        // measured on the mach axis and the mach axis is not where the error lives.
        //
        // This is not hypothetical — it is the state NDI is in TODAY, and it is the reason NDI has
        // no desktop audio path. NDI genuinely runs at rate 1.0, so its mapping never changes, so
        // it would anchor once and integrate the crystal offset forever. Full reasoning, the source
        // citations, and what a REAL corrector would have to look like: docs/BUGS.md, "NDI has no
        // desktop playback path at all".
        //
        // Pinning the rate is therefore a change to the AUDIO contract as well as the video one. If
        // you pin it, WHEP and SRT need a real closed-loop re-anchor first — the one NDI needs.
        let depth = smoothedDepth ?? spanSeconds

        // ── STARTUP FILL: CORRECT THE ANCHOR'S OFFSET BY POSITION, NOT BY RATE ────────────────
        //
        // `registerFrame` anchors on ONE frame's arrival, and on a cold decoder that frame is
        // LATE: the frames queued behind it during ~100 ms of hardware session setup land as a
        // burst straight after it, so the fill starts ~100 ms too deep (+88.7 ms measured at first
        // presentation against 87 ms of setup). The slew below can only remove an offset D by
        // integrating ∫(rate − 1)dt = D, at 5 ms/s: 20+ s on the rail, which the audio mirror
        // follows for 1–2.5 minutes. `docs/AUDIO_RESAMPLER_DESIGN.md` §10.9–§10.10.
        //
        // Until the first frame is presented, nothing is on screen and the audio is waiting on
        // this same anchor, so the offset can be removed by POSITION, in EITHER direction, for
        // free. Same re-anchor as the snap — evaluate the old mapping at `t`, restart the segment
        // there shifted by the excess, at unity — gated to the fill window. The EMA is shifted by
        // the same amount (every depth sample moves by −excess), which lands it on `targetDepth`;
        // that is a shift of its state, not a reset of it.
        //
        // ⚠️ GATED ON THE QUEUE EDGES BEING PRESENT, SO THE SYNTHETIC HARNESS STAYS INERT. It
        // passes no edges, and `docs/LIVECLOCK_PRESETS.md`'s grid was swept with no coarse
        // intervention in the loop — the same reason the freeze guard needs edges. Live transports
        // pass them whenever the queue is non-empty, which the fill always is.
        //
        // ⚠️ NOTHING CHANGES AFTER THE FIRST PRESENTATION. `hasPresentedOnce` is set by the freeze
        // guard the first tick a frame is eligible and cleared only by `reset()`; from then on this
        // block is unreachable and the slew is exactly what it was.
        //
        // Reported as an `Event` so the surplus ledger's `recordClockJump` sees it — an unreported
        // +100 ms re-anchor would put the ledger's residual outside its maxSlew × elapsed bound.
        if newestPTS != nil, !hasPresentedOnce {
            let excess = depth - targetDepth
            // Below 1 ms there is nothing worth publishing a mapping for: it is under a
            // fortieth of a frame and a tenth of the audio mirror's position tolerance.
            guard abs(excess) >= Self.startupRealignFloor else { return (nil, periodicLogIfDue(t)) }
            let mappedNow = anchorSenderPTS! + (t - anchorHostTime!) * rate
            setMappingLocked(senderPTS: mappedNow + excess, hostTime: t, rate: 1.0)
            smoothedDepth = targetDepth
            #if DEBUG || MANIFOLD_TELEMETRY
            startupRealigns += 1
            startupRealignNet += excess
            #endif
            return (.startupRealign(StartupRealignEvent(jumped: excess, depthBefore: depth,
                                                        target: targetDepth)),
                    periodicLogIfDue(t))
        }

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
            setMappingLocked(senderPTS: mappedNow, hostTime: t, rate: newRate)
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
            #if DEBUG || MANIFOLD_TELEMETRY
            if !hasPresentedOnce, let oHost = startupOriginHost {
                startupPresentHost = t
                pendingStartupPresent = StartupPresentLog(
                    sinceFirstFrame: t - oHost, depth: smoothedDepth ?? .nan, target: targetDepth,
                    count: count, rate: rate,
                    preMaxLead: startupPreMaxLead, realigns: startupRealigns,
                    realignNet: startupRealignNet)
            }
            #endif
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

        // Same clean slate the snap hands the P-loop: unity rate and a seeded EMA at the setpoint,
        // so it does not spend the next second unwinding an error it no longer has.
        setMappingLocked(senderPTS: corrected, hostTime: t, rate: 1.0)
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
        publishMappingIfChanged()   // outside the lock — see the `lock` declaration
        emit(event)                 // outside the lock — see the `lock` declaration
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
        setMappingLocked(senderPTS: newestPTS - target, hostTime: t, rate: 1.0)
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

    #if DEBUG || MANIFOLD_TELEMETRY
    private struct StartupPresentLog {
        let sinceFirstFrame: Double
        let depth: Double
        let target: Double
        let count: Int
        let rate: Double
        let preMaxLead: Double
        let realigns: Int
        let realignNet: Double
    }

    private struct StartupSummaryLog {
        let window: Double
        let postFrames: Int
        let postMaxLead: Double
        let minErr: Double
        let maxErr: Double
    }
    #endif

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
        // ⚠️ AFTER THE NIL-GUARD, DELIBERATELY. `periodicLogIfDue` has already run under the lock
        // and advanced the cadence gate, so the timing path is untouched whether this is on or
        // off — only the write is conditional. It also keeps the check at 1 Hz rather than
        // per frame.
        guard telemetryEnabled else { return }
        FileHandle.standardError.write(Data(String(
            format: "[LIVECLOCK] depth=%.3fs target=%.3f rate=%.4f err=%+.4f count=%d\n",
            log.depth, log.target, log.rate, log.depth - log.target, log.count).utf8))
        #endif
    }

    #if DEBUG || MANIFOLD_TELEMETRY
    /// The two `[LIVECLOCK] startup:` lines — once per stream each. §10.9/§10.10.
    private func emit(_ present: StartupPresentLog?, _ summary: StartupSummaryLog?) {
        guard telemetryEnabled else { return }
        if let p = present {
            FileHandle.standardError.write(Data(String(
                format: "[LIVECLOCK] startup: first presentation +%.3fs after first frame · "
                      + "depth=%.4fs target=%.3f err=%+.1f ms count=%d rate=%.4f · "
                      + "max arrival lead before=%+.1f ms · startup realigns=%d net %+.1f ms\n",
                p.sinceFirstFrame, p.depth, p.target, (p.depth - p.target) * 1e3, p.count, p.rate,
                p.preMaxLead.isFinite ? p.preMaxLead * 1e3 : 0, p.realigns, p.realignNet * 1e3).utf8))
        }
        if let s = summary {
            FileHandle.standardError.write(Data(String(
                format: "[LIVECLOCK] startup: %.1fs after first presentation · %d frame(s) arrived, "
                      + "max arrival lead=%+.1f ms · smoothed err min %+.1f / max %+.1f ms\n",
                s.window, s.postFrames, s.postMaxLead.isFinite ? s.postMaxLead * 1e3 : 0,
                s.minErr * 1e3, s.maxErr * 1e3).utf8))
        }
    }
    #endif

    /// The coarse actions LiveClock reports itself. `.snapped` and `.startupRealign` are deliberately
    /// absent: the transport layer logs those with its own context (see WHEPFrameRouter), and
    /// duplicating them here would print each twice.
    private func emit(_ event: Event?) {
        #if DEBUG || MANIFOLD_TELEMETRY
        // Gated for the same reason as the periodic line above. These are the `[LIVECLOCK]`
        // freeze-guard and queue-full lines; "no [LIVECLOCK] in Release" means these too.
        guard telemetryEnabled else { return }
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
        case .snapped, .startupRealign, .none:
            break
        }
        #endif
    }

    /// ⚠️ GATED ON `telemetryEnabled`, LIKE EVERY OTHER `[LIVECLOCK]` LINE, AND THAT IS A CHOICE.
    /// The `MAPPING CHANGED WITHOUT setMappingLocked` tripwire above is an UNCONDITIONAL `NSLog`
    /// because it reports a broken INVARIANT — a code defect that must never occur in any build.
    /// This one reports a TRANSPORT CONDITION that legitimately occurs on a stream running deep, so
    /// an unconditional log here would put a recurring line into shipping builds on an ordinary
    /// session. `MANIFOLD_TELEMETRY` is defined in Release (see `Package.swift`), so `#if` is not
    /// what keeps it quiet there — the runtime flag is, and this line respects it.
    private func emit(_ starvation: PublicationStarvation?) {
        #if DEBUG || MANIFOLD_TELEMETRY
        guard let starvation, telemetryEnabled else { return }
        FileHandle.standardError.write(Data(String(
            format: "[LIVECLOCK] ⚠️ publication starved: no mapping published for %.1fs "
                  + "(rate=%.4f%@ err=%+.4f) — %@\n",
            starvation.silentFor, starvation.rate,
            starvation.railed ? " RAILED" : "", starvation.err,
            starvation.heartbeatInstalled
                ? "the mirror is being fed by the heartbeat, so audio is covered; read this as a "
                + "DEPTH signal, not an audio one."
                : "AND NO onMappingTick CONSUMER IS INSTALLED, so nothing is mirroring this clock "
                + "— any audio timebase driven from it is drifting free.").utf8))
        #endif
    }

    /// The publication-gap distribution for one window. Gated on `telemetryEnabled` like every
    /// other `[LIVECLOCK]` line.
    ///
    /// Reads as a shape rather than a statistic on purpose: `<100:2 <200:5 <500:12 <1k:25` says
    /// "this loop rails for half a second at a time, twenty-five times a window", which is the
    /// sentence that matters. A p95 would have said "987 ms" and hidden that it was 25 separate
    /// excursions rather than one stall.
    private func emit(_ report: (window: Double, gaps: GapHistogram)?) {
        #if DEBUG || MANIFOLD_TELEMETRY
        guard let report, telemetryEnabled else { return }
        let g = report.gaps
        FileHandle.standardError.write(Data(String(
            format: "[LIVECLOCK] publication gaps (%.1fs): n=%d max=%.0fms · <50:%d <100:%d "
                  + "<200:%d <500:%d <1k:%d <2k:%d 2k+:%d\n",
            report.window, g.n, g.maxMs, g.under50, g.under100, g.under200,
            g.under500, g.under1k, g.under2k, g.over2k).utf8))
        #endif
    }

    private func emitTargetStep(from: Double, to: Double) {
        #if DEBUG || MANIFOLD_TELEMETRY
        guard telemetryEnabled else { return }
        FileHandle.standardError.write(Data(String(
            format: "[LIVECLOCK] targetDepth %.3f -> %.3f (manual)\n", from, to).utf8))
        #endif
    }

    /// Clear the anchor so the next `registerFrame` re-anchors — for a new stream, a reconnect,
    /// or (in the synthetic harness) a loop back to the file's head. Also RE-ARMS the control loop.
    /// Safe to call from any thread.
    public func reset() {
        lock.lock()
        clearMappingLocked()
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
        #if DEBUG || MANIFOLD_TELEMETRY
        startupOriginPTS = nil; startupOriginHost = nil; startupPresentHost = nil
        startupPreMaxLead = -.infinity; startupPostMaxLead = -.infinity; startupPostFrames = 0
        startupPostMinErr = .infinity; startupPostMaxErr = -.infinity
        startupRealigns = 0; startupRealignNet = 0; startupSummaryDone = false
        pendingStartupPresent = nil; pendingStartupSummary = nil
        #endif
        // Mirror-heartbeat state is per-STREAM for the same reason everything above it is.
        //
        // These three are BELT AND BRACES, and knowingly so: `clearMappingLocked` above sets
        // `mappingDirty`, so the `publishMappingIfChanged()` below takes the publication branch and
        // re-stamps all three on its way out. Clearing them here is what makes `reset()` correct
        // STANDING ALONE rather than correct-because-of-what-the-next-line-happens-to-do — the same
        // discipline the freeze-guard flags above are cleared under.
        lastMirrorTickHost = nil
        lastPublishHost = nil
        lastStarvationWarnHost = nil
        gaps = GapHistogram()
        gapWindowStart = nil
        lock.unlock()
        publishMappingIfChanged()   // publishes nil — the mirror must un-anchor with us
    }

    /// The app's established monotonic host clock — the same one NDI stamps frames with
    /// (`CACurrentMediaTime()`). Read under `lock` by both `registerFrame` and `now`.
    private func hostNow() -> Double {
        CACurrentMediaTime()
    }
}
