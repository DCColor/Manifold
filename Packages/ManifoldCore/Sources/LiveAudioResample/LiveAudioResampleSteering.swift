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
//  here: the first anchor, a coarse event the splice cannot take (below), and — with the ratio
//  pinned — step 3's position branch and NDI's re-anchor. So the count this object logs IS the
//  session's rate-write count, and §7 step 5's "setRate rows with a non-zero rate == 1 per session"
//  can be read off one line rather than reconstructed from several.
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
//  ACTION (step 5): a SPLICE, never a rate write. The content moves by −e — a drop when the audio
//  is behind (a snap, freeze guard or queue-full moved the picture forward), an insert of repeated
//  material when it is ahead — across the stage's 10 ms equal-power fade, at the stage's input.
//  The output axis stays contiguous. `e_f` is reset and `i` held, exactly as before.
//
//  The splice is heard a renderer-queue later than it is requested. Until then the content heard
//  still carries the old error, so every read adds the stage's `spliceCorrectionAhead` — the part
//  requested and not yet heard. `content + ahead` is continuous through the moment the splice is
//  heard, so no settle window is needed after a splice: nothing was written.
//
//  ⚠️ TWO CASES STILL RE-ANCHOR, LOGGED AND COUNTED, WITH THE PRE-STEP-5 WRITE:
//    * |e| > `maximumSpliceSeconds` (1 s) — past it the material cannot hide the jump;
//    * a DROP larger than the renderer queue can cover (drop + fade + 50 ms > queue depth). A drop
//      feeds nothing for about its own length while the material it jumps to arrives; the renderer
//      plays that out of its queue. If the queue is shorter, the output axis falls behind the
//      timebase, every later buffer arrives late, and the loop — which reads what was ENQUEUED —
//      cannot see it. The events that cause drops over-fill the queue by the drop, so this is a
//      guard, not an expected path.
//  The write is placed so the content heard is the target (`outputTime(atInputTime: target)`),
//  moving the timebase alone, as step 4 did.
//
//  ── MATCHING (§2.4: an unmatched splice is a defect) ──────────────────────────────────────────
//
//  Callers report the events that move content: LiveClock's position jumps (snap-to-live,
//  freeze-guard, queue-full, target-step), an input axis RE-PINNED, the stage's own axis BREAK,
//  and on RTP audio a first SR pair that arrived after the gate gave up on it (the target moves by
//  the first offset).
//  Each splice or fallback takes the newest unconsumed one from the `matchWindowSeconds` before it,
//  and its line names it; with none it says WARNING. LiveClock reports a jump BEFORE it publishes
//  the moved mapping, so the event always precedes the step it causes; the window only has to
//  cover the time from the event to the read that sees it.
//
//  ── THE SETTLE WINDOW ─────────────────────────────────────────────────────────────────────────
//
//  `setRate(_:time:atHostTime:)` updates the rate synchronously and the TIMEBASE asynchronously
//  (see `FrameEngine.LiveAudioRendererState`). A read taken in between still sees the old axis, and
//  the next one the new — which is a step, and would fire a second, reverse coarse event on the
//  write the first one made. So after every WRITE (the anchor, a fallback) the loop ignores
//  `settleSeconds` of reads: no controller step, no trigger, and the first read after it seeds `e_f`
//  afresh. The figure is a bound on that window, not a measurement of it; the reads it discards are
//  counted. A splice writes nothing and takes no settle window.
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
    func requestSplice(contentSeconds: Double) -> LiveAudioResampleStage.SpliceGrant?
    func spliceCorrectionAhead(ofOutputTime outputSeconds: Double) -> Double
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
        /// §2.4's coarse branch, on the one path a splice cannot take (see the header).
        case coarse(Trigger, errorSeconds: Double)
        /// A deliberate re-anchor by the caller: a pinned-mode position branch, NDI's pinned
        /// re-anchor or a Desktop Audio Lead change, or the anchor after a clock reset.
        case reanchor(String)

        public var label: String {
            switch self {
            case .firstAnchor: return "FIRST ANCHOR — the session's rate write"
            case let .coarse(t, e):
                return String(format: "COARSE RE-ANCHOR — splice fallback (%@, e %+.1f ms)",
                              t.rawValue, e * 1000)
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

    /// How far back from a splice its event may lie. The longest legitimate path from an event to
    /// the read that sees it: a preceding drop, which feeds nothing — so takes no reads — for up to
    /// its own length (≤ 1 s, `maximumSpliceSeconds`); then a settle window if a fallback wrote
    /// (0.25 s); then one input buffer, with room for a bursty one (0.25 s). Events are rare — none
    /// fired in ~5 h of the saved step-4 sessions — so a wide window costs no false matches.
    public static let matchWindowSeconds = 1.5
    /// A drop may take at most the renderer queue less its fade and this margin — one late buffer.
    static let dropQueueMarginSeconds = 0.050

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
    /// A line printed right after each window line, on the same utility-queue block so the two stay
    /// adjacent: WHEP's `[WHEP-SRFIT]` fit state (step 4e-2). nil on every other transport.
    private let windowCompanion: (@Sendable () -> String?)?

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
    private var spliceDrops = 0
    private var spliceInserts = 0
    private var splicedSeconds = 0.0
    private var spliceFallbacks = 0
    private var unmatched = 0

    /// Content-moving events reported by the callers, newest last. A splice consumes the one it
    /// matches, so one event cannot account for two splices.
    private struct NotedEvent {
        let label: String
        let host: Double
        let jumped: Double?
        let detail: String
        var consumed = false
    }
    private var events: [NotedEvent] = []
    private static let eventCapacity = 32

    // Window. Preallocated: 10 s at 100 Hz is 1000 reads.
    private static let capacity = 4096
    private var errs = [Double](repeating: 0, count: capacity)
    private var count = 0
    /// Renderer queue depth per accepted read: enqueued output frontier − timebase, seconds.
    /// MEASUREMENT ONLY — nothing reads it but the window line.
    private var depths = [Double](repeating: 0, count: capacity)
    private var depthCount = 0
    private var overflowed = 0
    private var discarded = 0
    private var settling = 0
    private var saturatedSteps = 0
    private var rhoMin = Double.infinity, rhoMax = -Double.infinity
    private var slewMax = 0.0
    private var windowCoarse = 0
    private var windowSplices = 0
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
                            log: (@Sendable (String) -> Void)?,
                            windowCompanion: (@Sendable () -> String?)? = nil) {
        self.init(tag: tag, mode: mode, clock: stage, gains: .adopted, thresholds: .adopted,
                  reportsWindows: reportsWindows, readTimebase: readTimebase, hostNow: hostNow,
                  write: write, log: log, windowCompanion: windowCompanion)
    }

    init(tag: String, mode: Mode, clock: LiveAudioContentClock,
         gains: LiveAudioResampleController.Gains, thresholds: Thresholds,
         reportsWindows: Bool,
         readTimebase: @escaping @Sendable () -> Double,
         hostNow: @escaping @Sendable () -> Double,
         write: @escaping @Sendable (Double, Double, WriteOrigin) -> Void,
         log: (@Sendable (String) -> Void)?,
         windowCompanion: (@Sendable () -> String?)? = nil) {
        self.tag = tag; self.mode = mode; self.clock = clock; self.gains = gains
        self.thresholds = thresholds; self.reportsWindows = reportsWindows
        self.readTimebase = readTimebase; self.hostNow = hostNow; self.write = write; self.log = log
        self.windowCompanion = windowCompanion
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

    /// Record an event that moves content — a LiveClock position jump, an input axis re-pin, a stage
    /// axis break — for the next splice to be matched against. Any thread; takes only this lock.
    ///
    /// - Parameters:
    ///   - label: the event's log name: `snap-to-live`, `freeze-guard`, `queue-full`,
    ///     `target-step`, `axis RE-PINNED`, `axis BREAK`, `late SR pair`.
    ///   - jumped: signed seconds the PICTURE moved (+ = forward), when the event has one.
    ///   - detail: the event's own figures, carried onto the SPLICE line.
    public func noteEvent(_ label: String, host: Double, jumped: Double?, detail: String) {
        lock.lock()
        events.append(NotedEvent(label: label, host: host, jumped: jumped, detail: detail))
        if events.count > Self.eventCapacity { events.removeFirst(events.count - Self.eventCapacity) }
        lock.unlock()
    }

    /// The newest unconsumed event in the window before `host`, consumed. A small forward slack
    /// covers two threads' reads of one host clock; ordering is otherwise guaranteed (see header).
    private func matchEventLocked(host: Double) -> NotedEvent? {
        guard let k = events.lastIndex(where: {
            !$0.consumed && $0.host <= host + 0.005 && host - $0.host <= Self.matchWindowSeconds
        }) else { return nil }
        events[k].consumed = true
        return events[k]
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
    ///
    /// `enqueuedFrontier` is the output-axis END of what the renderer will hold once this call's
    /// buffers are enqueued (the caller enqueues them immediately after). `frontier − timebase` is
    /// the renderer queue's absolute depth, logged per window and never acted on.
    @discardableResult
    public func sample(enqueuedFrontier: Double? = nil) -> PairedRead? {
        lock.lock()
        let live = anchored
        lock.unlock()
        guard live else { return nil }

        let t0 = hostNow()
        let timebase = readTimebase()
        let t1 = hostNow()
        let read = PairedRead(t0: t0, timebase: timebase, t1: t1)
        // After the pair, never inside it: these take the stage's lock. `ahead` is splice correction
        // requested and not yet heard (step 5): 0 whenever no splice is in the renderer's queue.
        let content = clock.inputTime(atOutputTime: timebase)
            + clock.spliceCorrectionAhead(ofOutputTime: timebase)

        var newRho: Double?
        var coarse: (Trigger, Double, Double)?     // trigger, e, target
        var windowLine: (() -> String)?

        lock.lock()
        if !anchored { lock.unlock(); return read }
        if t1 - t0 > Self.pairingGateSeconds || !content.isFinite {
            discarded += 1
            windowLine = windowIfDueLocked(now: t1)
            lock.unlock()
            if let w = windowLine { emitWindow(w) }
            return read
        }
        if let f = enqueuedFrontier, f.isFinite, depthCount < Self.capacity {
            depths[depthCount] = f - timebase; depthCount += 1
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
            // e_f reset, i held; the next read seeds the step comparison afresh.
            state = LiveAudioResampleController.coarseEvent(state)
            previousError = nil
        }
        windowLine = windowIfDueLocked(now: t1)
        lock.unlock()

        if let r = newRho { clock.rho = r }
        if let (trigger, e, target) = coarse {
            let depth = enqueuedFrontier.flatMap { $0.isFinite ? $0 - timebase : nil }
            coarseAction(trigger: trigger, error: e, filtered: filteredAtEvent, target: target,
                         host: t1, queueDepth: depth)
        }
        if let w = windowLine { emitWindow(w) }
        return read
    }

    /// §2.4's action: splice the content by −e, or — past the bound, or a drop the renderer queue
    /// cannot cover — the pre-step-5 re-anchor. Either way one line, naming the event it matched.
    /// Called without the lock.
    private func coarseAction(trigger: Trigger, error e: Double, filtered: Double, target: Double,
                              host t1: Double, queueDepth: Double?) {
        // + = the content moves forward: a drop. The audio is behind the picture by −e.
        let move = -e
        let fade = LiveAudioResampleStage.crossfadeSeconds
        var refusal: String?
        if abs(move) > LiveAudioResampleStage.maximumSpliceSeconds {
            refusal = String(format: "|e| %.0f ms is past the %.0f ms splice bound", abs(e) * 1000,
                             LiveAudioResampleStage.maximumSpliceSeconds * 1000)
        } else if move > 0, let d = queueDepth, move + fade + Self.dropQueueMarginSeconds > d {
            refusal = String(format: "a %.1f ms drop needs %.0f ms of renderer queue (drop + %.0f ms "
                             + "fade + %.0f ms margin) and the queue holds %.1f ms",
                             move * 1000, (move + fade + Self.dropQueueMarginSeconds) * 1000,
                             fade * 1000, Self.dropQueueMarginSeconds * 1000, d * 1000)
        }
        let grant = refusal == nil ? clock.requestSplice(contentSeconds: move) : nil
        if refusal == nil, grant == nil {
            refusal = "the stage refused it (no resampled session, or under one frame)"
        }

        lock.lock()
        let matched = matchEventLocked(host: t1)
        if matched == nil { unmatched += 1 }
        if let g = grant {
            if g.frames > 0 { spliceDrops += 1 } else { spliceInserts += 1 }
            splicedSeconds += abs(g.seconds)
            windowSplices += 1
        } else {
            spliceFallbacks += 1
            windowWrites += 1
            restartAfterWriteLocked(host: t1)
        }
        let number = spliceDrops + spliceInserts
        let integralPpm = state.integral * 1e6
        let writes = firstAnchors + spliceFallbacks + reanchors
        lock.unlock()

        // The fallback: place the timebase so the content heard now is the target, as step 4 did.
        if grant == nil {
            write(clock.outputTime(atInputTime: target), t1, .coarse(trigger, errorSeconds: e))
        }

        let tag = self.tag
        let threshold = trigger == .level ? thresholds.level : thresholds.step
        let triggerText = String(format: "trigger %@: e %+.1f ms (e_f %+.1f ms, threshold %.0f ms)",
                                 trigger.rawValue.uppercased(), e * 1000, filtered * 1000,
                                 threshold * 1000)
        let queueText = queueDepth.map { String(format: "%.1f ms", $0 * 1000) } ?? "unknown"
        let matchText: String
        if let m = matched {
            matchText = String(format: "matched: %@%@ at host %.3f s (%.0f ms before) — %@",
                               m.label,
                               m.jumped.map { String(format: " %+.3f s", $0) } ?? "",
                               m.host, (t1 - m.host) * 1000, m.detail)
        } else {
            matchText = String(format: "⚠️ WARNING: UNMATCHED — no snap-to-live / freeze-guard / "
                               + "queue-full / target-step / axis RE-PINNED / axis BREAK / late SR pair in the %.1f s "
                               + "before it; §2.4 calls an unmatched splice a defect",
                               Self.matchWindowSeconds)
        }
        if let g = grant {
            emit {
                String(format: "%@ SPLICE #%d %@ %lld fr / %.1f ms (content %@) · %@ · host %.3f s · "
                       + "%d fr (%.1f ms) equal-power cross-fade · renderer queue %@ · %@ · no rate "
                       + "write (session writes %d) · e_f reset, i held at %+.2f ppm",
                       tag, number, g.frames > 0 ? "DROP" : "INSERT", abs(g.frames),
                       abs(g.seconds) * 1000, g.frames > 0 ? "forward" : "back, repeated material",
                       triggerText, t1, g.crossfadeFrames,
                       Double(g.crossfadeFrames) / g.sampleRate * 1000, queueText, matchText,
                       writes, integralPpm)
            }
        } else {
            let why = refusal ?? "—"
            emit {
                String(format: "%@ COARSE RE-ANCHOR — no splice: %@ · %@ · host %.3f s · renderer "
                       + "queue %@ · %@ · action: one timebase write (session writes %d) · e_f reset, "
                       + "i held at %+.2f ppm",
                       tag, why, triggerText, t1, queueText, matchText, writes, integralPpm)
            }
        }
    }

    /// Counters for the session, for the END line and for tests.
    public struct Totals: Sendable, Equatable {
        public var firstAnchors = 0
        public var coarseLevel = 0
        public var coarseStep = 0
        public var reanchors = 0
        /// Coarse events taken as splices, by direction, and the content they moved in total.
        public var spliceDrops = 0
        public var spliceInserts = 0
        public var splicedSeconds = 0.0
        /// Coarse events the splice could not take, re-anchored instead — each one a write.
        public var spliceFallbacks = 0
        /// Splices and fallbacks with no event in the window before them.
        public var unmatched = 0
        public var splices: Int { spliceDrops + spliceInserts }
        /// `coarseLevel + coarseStep == splices + spliceFallbacks`.
        public var writes: Int { firstAnchors + spliceFallbacks + reanchors }
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
        if let w { emitWindow(w) }
        let tag = self.tag, mode = self.mode
        emit {
            String(format: "%@ steering session END — mode %@ · timebase writes %d (first anchor %d + "
                   + "coarse %d [splice fallbacks] + re-anchor %d) · coarse events %d [level %d, step %d] · "
                   + "splices %d (drop %d, insert %d), %.1f ms spliced, unmatched %d · ρ−1 at end "
                   + "%+.1f ppm, max |ρ−1| %.1f ppm · i %+.2f ppm",
                   tag, mode.rawValue, t.writes, t.firstAnchors, t.spliceFallbacks, t.reanchors,
                   t.coarseLevel + t.coarseStep, t.coarseLevel, t.coarseStep,
                   t.splices, t.spliceDrops, t.spliceInserts, t.splicedSeconds * 1000, t.unmatched,
                   (t.rho - 1) * 1e6, t.maxAbsRhoMinusOne * 1e6, t.integral * 1e6)
        }
    }

    // MARK: - Internals

    private func totalsLocked() -> Totals {
        var t = Totals()
        t.firstAnchors = firstAnchors; t.coarseLevel = coarseLevel; t.coarseStep = coarseStep
        t.reanchors = reanchors; t.rho = state.rho; t.integral = state.integral
        t.filteredError = state.filteredError; t.maxAbsRhoMinusOne = maxAbsRhoMinusOne
        t.spliceDrops = spliceDrops; t.spliceInserts = spliceInserts
        t.splicedSeconds = splicedSeconds; t.spliceFallbacks = spliceFallbacks
        t.unmatched = unmatched
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
        let d = Array(depths[0..<depthCount])
        let snap = (n: n, disc: discarded, settle: settling, over: overflowed,
                    sat: saturatedSteps, rho: state.rho, rhoMin: rhoMin, rhoMax: rhoMax,
                    slew: slewMax, i: state.integral, ef: state.filteredError,
                    coarse: windowCoarse, splices: windowSplices, writes: windowWrites,
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
            var sortedDepth = d
            sortedDepth.sort()
            let depthText = sortedDepth.isEmpty
                ? "—"
                : String(format: "min %.1f med %.1f max %.1f", sortedDepth[0] * 1e3,
                         sortedDepth[sortedDepth.count / 2] * 1e3, sortedDepth[sortedDepth.count - 1] * 1e3)
            let rhoRange = snap.rhoMin.isFinite
                ? String(format: "%+.1f … %+.1f", (snap.rhoMin - 1) * 1e6, (snap.rhoMax - 1) * 1e6)
                : "—"
            return String(format: "%@ steering %@ +%.0fs · mode %@ · ρ−1 %+.1f ppm (window %@, "
                          + "slew max %.1f ppm/s) · i %+.2f ppm · e_f %+.2f ms · e ms %@ · n=%d "
                          + "discarded=%d settling=%d%@ · saturated %d · coarse this window %d "
                          + "(splices %d) · writes this window %d · session: writes %d = first %d + "
                          + "coarse %d (splice fallbacks) + re-anchor %d · coarse events %d (level %d, "
                          + "step %d) · "
                          + "splices %d, %.1f ms, unmatched %d · max |ρ−1| %.1f ppm · "
                          + "renderer depth ms %@",
                          tag, final ? "END" : "window", snap.elapsed, mode.rawValue,
                          (snap.rho - 1) * 1e6, rhoRange, snap.slew * 1e6, snap.i * 1e6,
                          snap.ef * 1e3, errText, snap.n, snap.disc, snap.settle,
                          snap.over > 0 ? String(format: " OVERFLOW=%d", snap.over) : "",
                          snap.sat, snap.coarse, snap.splices, snap.writes, snap.total.writes,
                          snap.total.firstAnchors, snap.total.spliceFallbacks, snap.total.reanchors,
                          snap.total.coarseLevel + snap.total.coarseStep,
                          snap.total.coarseLevel, snap.total.coarseStep, snap.total.splices,
                          snap.total.splicedSeconds * 1000, snap.total.unmatched,
                          snap.total.maxAbsRhoMinusOne * 1e6, depthText)
        }
    }

    private func resetWindowLocked(now: Double?) {
        count = 0; depthCount = 0; overflowed = 0; discarded = 0; settling = 0; saturatedSteps = 0
        rhoMin = .infinity; rhoMax = -.infinity; slewMax = 0
        windowCoarse = 0; windowSplices = 0; windowWrites = 0
        if let now { windowStart = now }
    }

    private func emit(_ line: @escaping () -> String) {
        guard let log else { return }
        let box = UncheckedLine(make: line)
        DispatchQueue.global(qos: .utility).async { log(box.make()) }
    }

    /// A window line, then its companion's, in one block so nothing interleaves between them. The
    /// companion is read on the utility queue, never on the enqueue thread that closed the window.
    private func emitWindow(_ line: @escaping () -> String) {
        guard let log else { return }
        let box = UncheckedLine(make: line)
        let companion = windowCompanion
        DispatchQueue.global(qos: .utility).async {
            log(box.make())
            if let c = companion?() { log(c) }
        }
    }
}

/// The window closure captures only value snapshots; this lets it cross to the utility queue.
private struct UncheckedLine: @unchecked Sendable { let make: () -> String }
