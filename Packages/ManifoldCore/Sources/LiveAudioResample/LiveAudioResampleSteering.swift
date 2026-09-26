//
//  LiveAudioResampleSteering.swift
//  LiveAudioResample
//
//  Build step 4d of docs/AUDIO_RESAMPLER_DESIGN.md §7: the 4c controller wired to the live path.
//  Per input buffer: a paired read of the timebase (§2.1), mapped to content time through the stage
//  (4a), against the session's target line (§2.8); one controller step (§2.2); the ratio into the
//  stage for the next block. Plus the one coarse branch (§2.4) and the session's only timebase
//  writer.
//
//  ── THE ONE WRITER ────────────────────────────────────────────────────────────────────────────
//
//  Every `setRate` a live-audio session makes after `beginLiveAudio`'s hold goes through `write`
//  here: the first anchor, a coarse event, and — with the ratio pinned — step 3's position branch
//  and NDI's re-anchor. So the count this object logs IS the session's rate-write count, and §7
//  step 4's "setRate rows with a non-zero rate: 1 + COARSE count" can be read off one line rather
//  than reconstructed from several.
//
//  ── THE COARSE BRANCH (§2.4, REVISED 2026-09-25) ──────────────────────────────────────────────
//
//  Two triggers, both on CONTENT-time error, never on the raw timebase — under a working loop the
//  timebase drifts from the target by design, so anything comparing it would fire on a correct
//  loop:
//
//    * level: |e_f| > 250 ms
//    * step:  |e_k − e_(k−1)| > 50 ms between consecutive accepted evaluations
//
//  Action until step 5: one timebase write, placed so the content heard is the target
//  (`outputTime(atInputTime: target)`), then `e_f` reset and `i` held. ⚠️ THE STAGE'S AXIS IS NOT
//  DRAINED OR RE-ANCHORED. §2.4 says "drain the stage, then re-anchor its axis and the timebase";
//  re-anchoring the output axis would restart it at the next input tick while the renderer still
//  holds buffers on the old one, which overlaps or gaps them by the offset the loop has
//  accumulated. Inverting the content-time map moves the timebase alone, which is exactly the
//  write step 3's position branch made — one write, one mute, the renderer discarding or waiting
//  exactly as it did then. Step 5 replaces the write with a splice; the triggers stay.
//
//  ── THE SETTLE WINDOW ─────────────────────────────────────────────────────────────────────────
//
//  `setRate(_:time:atHostTime:)` updates the rate synchronously and the TIMEBASE asynchronously
//  (see `FrameEngine.LiveAudioRendererState`). A read taken in between still sees the old axis, and
//  the next one the new — which is a step, and would fire a second, reverse coarse event on the
//  write the first one made. So after every write the loop ignores `settleSeconds` of reads: no
//  controller step, no trigger, and the first read after it seeds `e_f` afresh. The figure is a
//  bound on that window, not a measurement of it; the reads it discards are counted.
//
//  ── PINNED MODE — THE BACK-OUT SWITCH ─────────────────────────────────────────────────────────
//
//  `.pinned` is step 3, exactly: the ratio stays at 1.0, the controller is never stepped, and the
//  coarse branch is off, because the caller's pre-4d 10 ms position branches are back on and write
//  through `reanchor`. The error is still measured and logged, so the two modes read on the same
//  line format and can be A/B'd from the log alone.
//

import Foundation

/// What the steering needs from the stage, as a seam so the trigger and write-count tests can
/// drive the law against loop_sim.py's plant without resampling audio. Internal: the stage is the
/// only conformer outside tests, and `rho` must not become settable from ManifoldCore.
protocol LiveAudioContentClock: AnyObject {
    func inputTime(atOutputTime outputSeconds: Double) -> Double
    func outputTime(atInputTime inputSeconds: Double) -> Double
    var rho: Double { get set }
}

extension LiveAudioResampleStage: LiveAudioContentClock {}

public final class LiveAudioResampleSteering: @unchecked Sendable {

    public enum Mode: String, Sendable {
        /// Step 4: the ratio carries the correction; the coarse branch is the only other writer.
        case loop = "LOOP"
        /// Step 3: ratio 1.0, controller idle, coarse branch off; the caller's 10 ms branches write.
        case pinned = "PINNED 1.0"
    }

    public struct Thresholds: Sendable, Equatable {
        /// §2.4 level trigger on |e_f|, seconds.
        public var level: Double
        /// §2.4 step trigger on |e_k − e_(k−1)|, seconds.
        public var step: Double
        /// Reads ignored after a write while the timebase takes the new anchor, seconds.
        public var settle: Double
        public init(level: Double, step: Double, settle: Double) {
            self.level = level; self.step = step; self.settle = settle
        }
        /// §2.4's figures. The settle is a bound, not a measurement (see the header).
        public static let adopted = Thresholds(level: 0.250, step: 0.050, settle: 0.25)
    }

    public enum Trigger: String, Sendable { case level, step }

    /// Why the timebase was written. Carried to the caller's rate-log row and counted here.
    public enum WriteOrigin: Sendable, Equatable {
        /// The session's first anchor (the gate, or NDI's first pull).
        case firstAnchor
        /// §2.4's coarse branch.
        case coarse(Trigger, errorSeconds: Double)
        /// A deliberate re-anchor by the caller: a pinned-mode position branch, NDI's pinned
        /// re-anchor or a Desktop Audio Lead change, or the anchor after a clock reset.
        case reanchor(String)

        public var label: String {
            switch self {
            case .firstAnchor: return "FIRST ANCHOR — the session's rate write"
            case let .coarse(t, e):
                return String(format: "COARSE (%@, e %+.1f ms)", t.rawValue, e * 1000)
            case let .reanchor(why): return "re-anchor (\(why))"
            }
        }
    }

    /// One tightly paired timebase read (§2.1): two host reads bracketing it. Handed on to the
    /// step-2 paired probe so the timebase is read once per buffer, not twice.
    public struct PairedRead: Sendable {
        public let t0: Double
        public let timebase: Double
        public let t1: Double
    }

    /// §2.1: a read pair spanning more than this is scheduling, not clocks.
    public static let pairingGateSeconds = 200e-6
    public static let windowSeconds = 10.0
    /// Longest `dt` one evaluation may claim. A stalled pump must not hand the integrator or the
    /// slew limiter a second of authority in one step.
    static let maximumStepSeconds = 0.25

    public let mode: Mode
    private let tag: String
    private let reportsWindows: Bool
    private let clock: LiveAudioContentClock
    private let gains: LiveAudioResampleController.Gains
    private let thresholds: Thresholds
    private let readTimebase: @Sendable () -> Double
    private let hostNow: @Sendable () -> Double
    private let write: @Sendable (_ outputSeconds: Double, _ hostSeconds: Double,
                                  _ origin: WriteOrigin) -> Void
    private let log: (@Sendable (String) -> Void)?

    private let lock = UnfairLockBox()

    // ── Session state, under `lock` ─────────────────────────────────────────────────────────────
    private var anchored = false
    private var refMedia = 0.0, refHost = 0.0, refRate = 1.0
    private var state = LiveAudioResampleController.State()
    private var previousError: Double?
    private var lastEvaluationHost = 0.0
    private var settleUntil = -Double.infinity
    private var sessionStart = 0.0

    // Counters, session-long.
    private var firstAnchors = 0
    private var coarseLevel = 0
    private var coarseStep = 0
    private var reanchors = 0
    private var maxAbsRhoMinusOne = 0.0

    // Window. Preallocated: 10 s at 100 Hz is 1000 reads.
    private static let capacity = 4096
    private var errs = [Double](repeating: 0, count: capacity)
    private var count = 0
    private var overflowed = 0
    private var discarded = 0
    private var settling = 0
    private var saturatedSteps = 0
    private var rhoMin = Double.infinity, rhoMax = -Double.infinity
    private var slewMax = 0.0
    private var windowCoarse = 0
    private var windowWrites = 0
    private var windowStart = 0.0

    /// - Parameters:
    ///   - readTimebase: `CMTimeGetSeconds(synchronizer.currentTime())`. Called between the two
    ///     host reads and nothing else is.
    ///   - hostNow: `CACurrentMediaTime`.
    ///   - write: `setRate(1.0, time: outputSeconds, atHostTime: hostSeconds)`, plus whatever the
    ///     caller logs about it. Called without this object's lock held.
    public convenience init(tag: String, mode: Mode, stage: LiveAudioResampleStage,
                            reportsWindows: Bool,
                            readTimebase: @escaping @Sendable () -> Double,
                            hostNow: @escaping @Sendable () -> Double,
                            write: @escaping @Sendable (Double, Double, WriteOrigin) -> Void,
                            log: (@Sendable (String) -> Void)?) {
        self.init(tag: tag, mode: mode, clock: stage, gains: .adopted, thresholds: .adopted,
                  reportsWindows: reportsWindows, readTimebase: readTimebase, hostNow: hostNow,
                  write: write, log: log)
    }

    init(tag: String, mode: Mode, clock: LiveAudioContentClock,
         gains: LiveAudioResampleController.Gains, thresholds: Thresholds,
         reportsWindows: Bool,
         readTimebase: @escaping @Sendable () -> Double,
         hostNow: @escaping @Sendable () -> Double,
         write: @escaping @Sendable (Double, Double, WriteOrigin) -> Void,
         log: (@Sendable (String) -> Void)?) {
        self.tag = tag; self.mode = mode; self.clock = clock; self.gains = gains
        self.thresholds = thresholds; self.reportsWindows = reportsWindows
        self.readTimebase = readTimebase; self.hostNow = hostNow; self.write = write; self.log = log
    }

    // MARK: - The target line

    /// The session's target line (§2.8): content time `media` at host `host`, advancing at `rate`.
    /// Mirrored transports push the LiveClock mapping minus cushion on every evaluation; NDI's is
    /// set by its anchor and left. Never writes the timebase — a moved line is an error for the
    /// loop, or, if it moved by more than 50 ms, a step for the coarse branch.
    public func setReference(media: Double, host: Double, rate: Double) {
        guard media.isFinite, host.isFinite, rate.isFinite, rate > 0 else { return }
        lock.lock()
        refMedia = media; refHost = host; refRate = rate
        lock.unlock()
    }

    /// Anchor the timebase so the content heard at `host` is `media`, and make that the target
    /// line. The first call is the session's rate write; later ones are deliberate re-anchors.
    ///
    /// `e_f` is reset and `i` held, exactly as for a coarse event: a re-anchor moves position, and
    /// the drift the integrator learned is a property of the clocks.
    public func anchor(media: Double, host: Double, rate: Double = 1.0, reason: String? = nil) {
        guard media.isFinite, host.isFinite else { return }
        lock.lock()
        let first = firstAnchors == 0
        let origin: WriteOrigin = first ? .firstAnchor : .reanchor(reason ?? "caller")
        refMedia = media; refHost = host; refRate = rate.isFinite && rate > 0 ? rate : 1.0
        anchored = true
        if sessionStart == 0 { sessionStart = host; windowStart = host }
        if first { firstAnchors = 1 } else { reanchors += 1 }
        windowWrites += 1
        restartAfterWriteLocked(host: host)
        lock.unlock()
        // Outside the lock: the inverse takes the stage's, and the write reaches the synchronizer.
        write(clock.outputTime(atInputTime: media), host, origin)
    }

    /// The clock un-anchored (`LiveClock.reset()`): the synchronizer is being held at rate 0, so
    /// there is nothing to steer until the next `anchor`. The ratio and `i` are kept.
    public func hold() {
        lock.lock()
        anchored = false
        previousError = nil
        lock.unlock()
    }

    // MARK: - Per buffer

    /// One evaluation, per input buffer, on the enqueue thread, AFTER the buffer went through the
    /// stage (so its block is in the content-time map) and before it reaches the renderer.
    ///
    /// Returns the paired read if one was taken, for the step-2 probe. Nothing is read before the
    /// first anchor: the timebase is held at rate 0 and there is no line to compare it with.
    @discardableResult
    public func sample() -> PairedRead? {
        lock.lock()
        let live = anchored
        lock.unlock()
        guard live else { return nil }

        let t0 = hostNow()
        let timebase = readTimebase()
        let t1 = hostNow()
        let read = PairedRead(t0: t0, timebase: timebase, t1: t1)
        // After the pair, never inside it: this takes the stage's lock.
        let content = clock.inputTime(atOutputTime: timebase)

        var newRho: Double?
        var coarse: (Trigger, Double, Double)?     // trigger, e, target
        var windowLine: (() -> String)?

        lock.lock()
        if !anchored { lock.unlock(); return read }
        if t1 - t0 > Self.pairingGateSeconds || !content.isFinite {
            discarded += 1
            windowLine = windowIfDueLocked(now: t1)
            lock.unlock()
            if let w = windowLine { emit(w) }
            return read
        }
        let target = refMedia + (t1 - refHost) * refRate
        let e = content - target
        let dt = lastEvaluationHost > 0
            ? max(0, min(Self.maximumStepSeconds, t1 - lastEvaluationHost)) : 0
        lastEvaluationHost = t1

        if t1 < settleUntil {
            settling += 1
        } else {
            if count < Self.capacity { errs[count] = e; count += 1 } else { overflowed += 1 }
            if mode == .loop {
                if let p = previousError, abs(e - p) > thresholds.step {
                    coarse = (.step, e, target)
                } else {
                    let before = state.rho
                    state = LiveAudioResampleController.step(state, error: e, dt: dt, gains: gains)
                    if state.saturated { saturatedSteps += 1 }
                    if dt > 0 { slewMax = max(slewMax, abs(state.rho - before) / dt) }
                    // ρ goes to the stage whether or not the level trigger fires: the state now
                    // holds it, and the stage must never disagree with the state.
                    if state.rho != before { newRho = state.rho }
                    if abs(state.filteredError) > thresholds.level {
                        coarse = (.level, e, target)
                    }
                }
            }
            previousError = e
        }
        rhoMin = min(rhoMin, state.rho); rhoMax = max(rhoMax, state.rho)
        maxAbsRhoMinusOne = max(maxAbsRhoMinusOne, abs(state.rho - 1))

        var filteredAtEvent = 0.0
        if let c = coarse {
            filteredAtEvent = state.filteredError
            if c.0 == .level { coarseLevel += 1 } else { coarseStep += 1 }
            windowCoarse += 1
            windowWrites += 1
            state = LiveAudioResampleController.coarseEvent(state)
            restartAfterWriteLocked(host: t1)
        }
        let integralPpm = state.integral * 1e6
        let writes = firstAnchors + coarseLevel + coarseStep + reanchors
        windowLine = windowIfDueLocked(now: t1)
        lock.unlock()

        if let r = newRho { clock.rho = r }
        if let (trigger, e, target) = coarse {
            // Place the timebase so the content heard now is the target: one write (§2.4).
            write(clock.outputTime(atInputTime: target), t1, .coarse(trigger, errorSeconds: e))
            let tag = self.tag
            let threshold = trigger == .level ? thresholds.level : thresholds.step
            emit {
                String(format: "%@ COARSE — %@ trigger: e %+.1f ms (e_f %+.1f ms, threshold %.0f ms) "
                       + "· action: one timebase re-anchor (step 5 makes it a splice) · e_f reset, "
                       + "i held at %+.2f ppm · session writes %d",
                       tag, trigger.rawValue.uppercased(), e * 1000, filteredAtEvent * 1000,
                       threshold * 1000, integralPpm, writes)
            }
        }
        if let w = windowLine { emit(w) }
        return read
    }

    /// Counters for the session, for the END line and for tests.
    public struct Totals: Sendable, Equatable {
        public var firstAnchors = 0
        public var coarseLevel = 0
        public var coarseStep = 0
        public var reanchors = 0
        public var writes: Int { firstAnchors + coarseLevel + coarseStep + reanchors }
        public var rho = 1.0
        public var integral = 0.0
        public var filteredError = 0.0
        public var maxAbsRhoMinusOne = 0.0
    }

    public var totals: Totals {
        lock.lock(); defer { lock.unlock() }
        return totalsLocked()
    }

    /// End of session: the last partial window, then one summary line.
    public func finish() {
        lock.lock()
        let w = windowLocked(final: true)
        let t = totalsLocked()
        lock.unlock()
        if let w { emit(w) }
        let tag = self.tag, mode = self.mode
        emit {
            String(format: "%@ steering session END — mode %@ · timebase writes %d (first anchor %d + "
                   + "coarse %d [level %d, step %d] + re-anchor %d) · ρ−1 at end %+.1f ppm, max "
                   + "|ρ−1| %.1f ppm · i %+.2f ppm",
                   tag, mode.rawValue, t.writes, t.firstAnchors, t.coarseLevel + t.coarseStep,
                   t.coarseLevel, t.coarseStep, t.reanchors, (t.rho - 1) * 1e6,
                   t.maxAbsRhoMinusOne * 1e6, t.integral * 1e6)
        }
    }

    // MARK: - Internals

    private func totalsLocked() -> Totals {
        var t = Totals()
        t.firstAnchors = firstAnchors; t.coarseLevel = coarseLevel; t.coarseStep = coarseStep
        t.reanchors = reanchors; t.rho = state.rho; t.integral = state.integral
        t.filteredError = state.filteredError; t.maxAbsRhoMinusOne = maxAbsRhoMinusOne
        return t
    }

    /// After any write: `e_f` reset, `i` held, no step comparison across the write, and reads
    /// ignored until the timebase has taken the new anchor.
    private func restartAfterWriteLocked(host: Double) {
        state = LiveAudioResampleController.coarseEvent(state)
        previousError = nil
        settleUntil = host + thresholds.settle
    }

    private func windowIfDueLocked(now: Double) -> (() -> String)? {
        guard windowStart > 0, now - windowStart >= Self.windowSeconds else { return nil }
        return windowLocked(final: false, now: now)
    }

    /// Snapshot and reset the window. Only the copy happens under the lock; the sort and the
    /// formatting run in the returned closure, which `emit` runs on a utility queue — the same
    /// discipline as the paired probe, for the same reason: this is the audio thread.
    private func windowLocked(final: Bool, now: Double? = nil) -> (() -> String)? {
        let n = count
        let hadAnything = n > 0 || discarded > 0 || settling > 0 || windowWrites > 0
        guard hadAnything, reportsWindows || windowCoarse > 0 || final else {
            resetWindowLocked(now: now); return nil
        }
        let e = Array(errs[0..<n])
        let snap = (n: n, disc: discarded, settle: settling, over: overflowed,
                    sat: saturatedSteps, rho: state.rho, rhoMin: rhoMin, rhoMax: rhoMax,
                    slew: slewMax, i: state.integral, ef: state.filteredError,
                    coarse: windowCoarse, writes: windowWrites,
                    total: totalsLocked(), elapsed: (now ?? lastEvaluationHost) - sessionStart)
        resetWindowLocked(now: now)
        let tag = self.tag, mode = self.mode
        return {
            var sorted = e
            sorted.sort()
            let errText = snap.n > 0
                ? String(format: "min %+.2f med %+.2f max %+.2f", sorted[0] * 1e3,
                         sorted[snap.n / 2] * 1e3, sorted[snap.n - 1] * 1e3)
                : "no reads"
            let rhoRange = snap.rhoMin.isFinite
                ? String(format: "%+.1f … %+.1f", (snap.rhoMin - 1) * 1e6, (snap.rhoMax - 1) * 1e6)
                : "—"
            return String(format: "%@ steering %@ +%.0fs · mode %@ · ρ−1 %+.1f ppm (window %@, "
                          + "slew max %.1f ppm/s) · i %+.2f ppm · e_f %+.2f ms · e ms %@ · n=%d "
                          + "discarded=%d settling=%d%@ · saturated %d · coarse this window %d · "
                          + "writes this window %d · session: writes %d = first %d + coarse %d "
                          + "(level %d, step %d) + re-anchor %d, max |ρ−1| %.1f ppm",
                          tag, final ? "END" : "window", snap.elapsed, mode.rawValue,
                          (snap.rho - 1) * 1e6, rhoRange, snap.slew * 1e6, snap.i * 1e6,
                          snap.ef * 1e3, errText, snap.n, snap.disc, snap.settle,
                          snap.over > 0 ? String(format: " OVERFLOW=%d", snap.over) : "",
                          snap.sat, snap.coarse, snap.writes, snap.total.writes,
                          snap.total.firstAnchors, snap.total.coarseLevel + snap.total.coarseStep,
                          snap.total.coarseLevel, snap.total.coarseStep, snap.total.reanchors,
                          snap.total.maxAbsRhoMinusOne * 1e6)
        }
    }

    private func resetWindowLocked(now: Double?) {
        count = 0; overflowed = 0; discarded = 0; settling = 0; saturatedSteps = 0
        rhoMin = .infinity; rhoMax = -.infinity; slewMax = 0
        windowCoarse = 0; windowWrites = 0
        if let now { windowStart = now }
    }

    private func emit(_ line: @escaping () -> String) {
        guard let log else { return }
        let box = UncheckedLine(make: line)
        DispatchQueue.global(qos: .utility).async { log(box.make()) }
    }
}

/// The window closure captures only value snapshots; this lets it cross to the utility queue.
private struct UncheckedLine: @unchecked Sendable { let make: () -> String }
