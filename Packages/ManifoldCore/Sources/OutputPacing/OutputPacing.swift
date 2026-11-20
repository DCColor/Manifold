//
//  OutputPacing.swift
//  OutputPacing
//
//  THE OUTPUT PACER'S RATE AND ITS INTERVAL STATISTICS (0.9.1, docs/DISPLAY_LINK_PER_WINDOW_PLAN.md §4.4).
//
//  While a window feeds DeckLink output its render loop is ticked by a host-clock thread, not by its display link, so SDI
//  never depends on which desktop display the window is on. The period comes from the frames, never from a display: a
//  whole number of ticks per frame (at least two, so two frames can be due in one tick only if a tick is a whole period
//  late) and at least 60 ticks a second, for the one-shots and the window.
//
//  A leaf target, no dependencies, so `swift test` can pin the rule and the statistics; the pacer thread is app code.
//

import Foundation

public enum OutputPacerTiming {
    /// The fewest ticks a second the pacer gives, whatever the frame rate.
    public static let minimumTickRate = 60.0

    /// The tick period, in seconds, for a card frame and a source frame (both in seconds; 0 or less = unknown).
    /// `f` is the shorter of the two known durations; the period is `f / k`, `k = max(2, ceil(f × 60 Hz))`.
    /// Both unknown: nil (the caller keeps its display link).
    public static func period(cardFrame: Double, sourceFrame: Double) -> (period: Double, ticksPerFrame: Int)? {
        let known = [cardFrame, sourceFrame].filter { $0.isFinite && $0 > 0 }
        guard let f = known.min() else { return nil }
        // 1e-9 so an exact multiple (1/60 s at 60 Hz) does not round up to an extra tick through floating point.
        let k = max(2, Int((f * minimumTickRate - 1e-9).rounded(.up)))
        return (f / Double(k), k)
    }
}

/// Tick intervals in 10 µs bins up to 100 ms (one overflow bin above), for a median, a p99 and the exact maximum.
/// Not thread-safe: one writer (the pacer thread), read by that writer.
public struct IntervalStats {
    public static let binWidth = 1e-5
    public static let binCount = 10_000
    private var bins = [UInt32](repeating: 0, count: IntervalStats.binCount + 1)
    public private(set) var count = 0
    public private(set) var maximum = 0.0
    public private(set) var sum = 0.0

    public init() {}

    public mutating func add(_ interval: Double) {
        guard interval.isFinite, interval >= 0 else { return }
        let i = min(Int(interval / Self.binWidth), Self.binCount)
        bins[i] &+= 1
        count += 1
        sum += interval
        maximum = max(maximum, interval)
    }

    public mutating func reset() { self = IntervalStats() }

    public var mean: Double { count > 0 ? sum / Double(count) : .nan }

    /// The interval at or below which `fraction` of the samples lie, to the bin's upper edge (10 µs). The overflow
    /// bin reports the exact maximum. NaN with no samples.
    public func quantile(_ fraction: Double) -> Double {
        guard count > 0 else { return .nan }
        let target = max(1, Int((Double(count) * fraction).rounded(.up)))
        var seen = 0
        for (i, n) in bins.enumerated() {
            seen += Int(n)
            if seen >= target { return i == Self.binCount ? maximum : min(Double(i + 1) * Self.binWidth, maximum) }
        }
        return maximum
    }

    public var median: Double { quantile(0.5) }
    public var p99: Double { quantile(0.99) }

    /// "n=… median 8.34 p99 8.90 max 9.31 ms", the form every [PACER] line uses.
    public var summary: String {
        guard count > 0 else { return "n=0" }
        return String(format: "n=%d median %.2f p99 %.2f max %.2f ms", count, median * 1000, p99 * 1000, maximum * 1000)
    }
}

/// The window's own timing, beside the pacer's (0.9.1, the two window-side entries of 2026-11-01 in docs/BUGS.md).
public enum WindowPresentTiming {
    /// A display faster than this (in Hz) may hold a second present waiting for the glass in pacer mode.
    public static let secondWaitingPresentAbove = 61.0

    /// PACER MODE. How many presents may be waiting for the glass when the window asks for another drawable. One (the
    /// gate as measured on 2026-11-01): with the one on the glass, two of the layer's three drawables are in use and
    /// `nextDrawable()` finds the third. On a display above 60 Hz, two: a present's handler lands a vsync or more after
    /// it reaches the glass, so a count of two is usually one waiting and one already shown, and the window can then
    /// keep up with a 100 or 119.88 fps file. When both really are waiting, `nextDrawable()` waits for the next vsync
    /// (one display period, ≤ 8.4 ms at 120 Hz), after this tick's SDI frame is committed. Unknown period: one.
    public static func presentsWaitingLimit(displayPeriod: Double) -> Int {
        guard displayPeriod.isFinite, displayPeriod > 0 else { return 1 }
        return 1 / displayPeriod > secondWaitingPresentAbove ? 2 : 1
    }

    /// OPTION B (the 0.9.5 default, every configuration; `MANIFOLD_PACER_PRESENT_TX=1` turns it off; docs/WINDOW_PRESENT_PATH.md §7.5): the gate keeps one of the layer's three
    /// drawables spare, so at most one present waits for the glass at any display rate. Above 60 Hz that is one drawable more free
    /// than `presentsWaitingLimit`, where the pool otherwise has no slack (§7.2). A literal fourth drawable is not possible:
    /// `CAMetalLayer.maximumDrawableCount` throws outside [2, 3] (CAMetalLayer.h). B off: `presentsWaitingLimit`, unchanged.
    public static func presentsWaitingLimit(displayPeriod: Double, keepSpareDrawable: Bool) -> Int {
        keepSpareDrawable ? 1 : presentsWaitingLimit(displayPeriod: displayPeriod)
    }

    /// OPTION B, "plain B" (docs/WINDOW_PRESENT_PATH.md §7.4 option 1, §7.5): the layer's `presentsWithTransaction` while B is on.
    /// Transactional exactly when the output pacer is not presenting. It takes nothing about the tick (no colour state, no new
    /// drawable size), so the mode never changes per tick, only when the pacer starts or stops. A per-tick switch to a transactional
    /// present on a colour-state tick stranded a drawable and stalled `nextDrawable` for its 1 s timeout (§7).
    public static func optionBPresentsWithTransaction(pacerPresenting: Bool) -> Bool { !pacerPresenting }

    /// The longest tick → glass lead taken; a longer one (a stalled link, a bad timestamp) selects at the tick.
    public static let maximumGlassLead = 0.1

    /// The clock reading a display-link tick selects its frame against: the clock carried forward to the time this
    /// tick's present will reach the glass (the link's output time), not the time the callback ran. The output times
    /// are the display's own vsync grid, so a frame due near a tick boundary is no longer put on one side or the other by
    /// the callback's jitter (a 59.94 source on a 59.936 Hz display; docs/BUGS.md 2026-11-01).
    ///
    /// Carried forward only while the clock runs at 1× (judged from the previous tick's reading, within 5 %), so a pause,
    /// a step, a seek or a shuttle selects at the tick as before. No output time (a pacer tick, which feeds SDI), a lead
    /// outside 0…`maximumGlassLead`, or an unanchored clock: the clock as read.
    public static func selectionTime(clock: Double, clockHost: Double, glassHost: Double?,
                                     previous: (clock: Double, host: Double)?) -> Double {
        guard let glassHost, let previous, clock.isFinite, previous.clock.isFinite else { return clock }
        let lead = glassHost - clockHost, dt = clockHost - previous.host
        guard lead >= 0, lead <= maximumGlassLead, dt > 0, dt <= 0.1 else { return clock }
        let rate = (clock - previous.clock) / dt
        guard abs(rate - 1) <= 0.05 else { return clock }
        return clock + lead
    }
}

// MARK: - Option C: the output pacer's phase held against the frame grid (docs/CARD_PULL_MARGIN.md §7 C)
//
// Under card lock the frames' due times run on the card's clock and the pacer ticks on the host's, so each new-frame tick
// drifts against its frame's due time (about 12 µs/s on the build Mac). When a tick drifts across a due time, that frame and every
// one after it render one tick late: a crossing, the only late-swap cause seen in the 0.9.3 and 0.9.4 gates and in Stage 1
// (§5, §12.4, §13.3). Option C measures x = selectNow − chosenPts at each new-frame tick, sets a reference from the first eight
// after a wake, a re-rate or a clock discontinuity, and moves the pacer's next deadline by at most 20 µs a tick so that x stays at
// the reference. While the reference is being set, a phase within 0.5 ms of a due time is moved off it at once, by at most 0.5 ms
// (the establishment guard, §15.3). The pull, its margin and every clock are untouched; only when the pacer's ticks land changes.
//
// The app wires it behind `MANIFOLD_PACER_PHASE=1` (DEBUG); with it off, nothing here is called (`OutputPacer`).

/// What the renderer's tick reports to the pacer after its selection, with `MANIFOLD_PACER_PHASE` on.
public enum PacerPhaseSample: Equatable, Sendable {
    /// Not playing at 1× on a matched file: paused, stepping, seeking, shuttling, a clock discontinuity, a live source, a tick
    /// that was not the pacer's, or a rate mismatch. The phase is not followed, and the reference is dropped.
    case inactive
    /// Playing at 1× on a matched file. `x` = selectNow − chosenPts (seconds) on a tick that chose a new frame; nil otherwise.
    case active(x: Double?)
}

public enum PacerPhase {
    /// The most a deadline moves in one tick (§7 C step 3): covers drift up to about 1,400 ppm, and never moves a tick visibly.
    public static let correctionClamp = 20e-6
    /// The reference's distance from both edges of the tick (§7 C step 2): about 8× the dither width seen at a crossing.
    public static let guardMargin = 0.5e-3
    /// New-frame ticks in the reference median and in the running median (§7 C steps 2–3).
    public static let window = 8
    /// "Playing at 1×": the clock's rate between two ticks within this of 1. Shuttle speeds are far outside it; the clock's own
    /// read jitter (a few µs over a tick of 4–14 ms) is far inside it. 13 of 192,154 consecutive new-frame pairs at 59.94 were
    /// outside it in Stage 1 night 2 (`pp-5994-sdi.log`), each at a transport event.
    public static let unitRateTolerance = 0.01

    /// The pacer's next deadline, in mach ticks. `correction` is signed (mach ticks); 0 gives exactly `previous + step`, which
    /// is the pacer's arithmetic with the switch off. Otherwise the arithmetic is signed and saturating: the deadline always
    /// moves forward by at least one unit, whatever the correction, and never wraps past `UInt64.max`. So a correction can
    /// never stop the ticks (§7 C, the risk against I11).
    public static func nextDeadline(previous: UInt64, step: UInt64, correction: Int64) -> UInt64 {
        if correction == 0 { return previous + step }
        let (sum, overflow) = Int64(clamping: step).addingReportingOverflow(correction)
        let delta = overflow ? (correction > 0 ? Int64.max : 1) : max(1, sum)
        let (next, wrapped) = previous.addingReportingOverflow(UInt64(delta))
        return wrapped ? UInt64.max : next
    }

    /// The correction (seconds) to add to the next deadline: clamp(−(phase − reference), ±`correctionClamp`). `phase` is x̄, the
    /// running median of x expressed at the corrections applied so far (`PacerPhaseFollower`). Disabled, or either value
    /// missing or not finite: 0.
    public static func phaseCorrection(enabled: Bool, phase: Double?, reference: Double?) -> Double {
        guard enabled, let phase, let reference, phase.isFinite, reference.isFinite else { return 0 }
        return min(correctionClamp, max(-correctionClamp, -(phase - reference)))
    }

    /// How the guard moved the reference.
    public enum Guard: String, Equatable, Sendable { case none, raised, lowered }

    /// The reference x_ref from the first `window` new-frame ticks: their median, kept at least `guardMargin` inside both edges
    /// of the tick [0, period). A median under 0.5 ms is raised to 0.5 ms (the ticks move later, the lead shrinks by ≤ 0.5 ms);
    /// one over P − 0.5 ms is lowered to P − 0.5 ms (the ticks move earlier, the lead grows). A tick shorter than 1 ms (never a
    /// pacer's: the pacer runs at ≤ 120 Hz on any real rate) takes its middle. Fewer than `window` values, or a bad period: nil.
    public static func reference(firstTicks: [Double], period: Double) -> (value: Double, median: Double, guarded: Guard)? {
        guard firstTicks.count >= window, period.isFinite, period > 0 else { return nil }
        let m = median(Array(firstTicks.prefix(window)))
        guard m.isFinite else { return nil }
        let low = min(guardMargin, period / 2), high = max(period - guardMargin, period / 2)
        if m < low { return (low, m, .raised) }
        if m > high { return (high, m, .lowered) }
        return (m, m, .none)
    }

    /// The establishment guard (CARD_PULL_MARGIN.md §15.3, §14.4): the correction (seconds) for a new-frame tick while the
    /// reference is still being set. Until the eighth new-frame tick sets x_ref nothing else moves the ticks, so a Play or a
    /// wrap whose phase lands on a due time (x near 0 or near P) would sit there, dithering across it, for those eight frames
    /// (the 4 crossings after a wrap in the A/B night). So a phase inside the guard band at either edge is moved at once to that
    /// edge, by the same rule the reference's guard applies: x < 0.5 ms → later, to 0.5 ms; x > P − 0.5 ms → earlier, to
    /// P − 0.5 ms. The move is at most `guardMargin`, in one step (the follow's 20 µs clamp would take 25 ticks, longer than the
    /// window it protects). A dead band of `correctionClamp` past each edge keeps a phase settled on the edge from being moved
    /// again by its own jitter. x outside [0, P) (an outlier), x not finite, or a bad period: 0.
    public static func establishmentCorrection(x: Double, period: Double) -> Double {
        guard x.isFinite, period.isFinite, period > 0, x >= 0, x < period else { return 0 }
        let low = min(guardMargin, period / 2), high = max(period - guardMargin, period / 2)
        if x < low - correctionClamp { return low - x }
        if x > high + correctionClamp { return high - x }
        return 0
    }

    // MARK: C+ (docs/CARD_PULL_MARGIN.md §17.3; `MANIFOLD_PACER_PHASE=2`)
    //
    // The handed frame's lead at a pull (pull host − the frame's ring publish host) is A − x − c: A, where the card's slot sits on
    // the frame grid past the frame's pts (fixed for a Play under card lock), less the tick's phase x and the tick → ring time c
    // (§17.1, measured on 11 blocks). So lead + x, the "pull phase", is the same for every frame of a Play whatever x is, and
    // lead(x) = pullPhase − x. A one-tick-late swap holds when lead < P (§17.2), so C+ chooses x so that lead ≥ P + `leadSlack`
    // where the guard band allows. Only earlier (smaller x): that never changes which pull takes the frame, because the pull one
    // frame earlier is less than margin − band after the frame's pts and is not eligible (§17.3). Never later: missing the pull at
    // k = 3 (§17.3 item 6) is not done here.

    /// The lead C+ keeps above P: covers a one-tick-late swap's measured delay at q99 (8.88 ms against P + 0.5 = 8.84 at 59.94).
    public static let leadSlack = 0.5e-3

    /// The pull phase (seconds) from one timed pull: the handed frame's lead (pull host − its publish host) plus the x of the tick
    /// that rendered it. Nil when a value is not finite, or the lead is negative (a frame published after the pull: not possible for
    /// a handed frame, so a bad reading).
    public static func pullPhase(pullHost: Double, publishHost: Double, x: Double) -> Double? {
        guard pullHost.isFinite, publishHost.isFinite, x.isFinite else { return nil }
        let lead = pullHost - publishHost
        guard lead >= 0 else { return nil }
        return lead + x
    }

    /// The lead (seconds) a tick phase x gives against a pull phase: pullPhase − x.
    public static func lead(x: Double, pullPhase: Double) -> Double { pullPhase - x }

    /// C+'s reference: x_ref, or earlier, so that lead ≥ P + `leadSlack`, never below the guard band's low edge
    /// (`min(guardMargin, period / 2)`) and never later than x_ref. `reachesSlack` is false when the band's edge stopped it short.
    /// A pull phase or reference that is not finite, or a bad period: x_ref unchanged.
    public static func leadReference(xRef: Double, pullPhase: Double, period: Double) -> (value: Double, reachesSlack: Bool) {
        guard xRef.isFinite, pullPhase.isFinite, period.isFinite, period > 0 else { return (xRef, true) }
        let low = min(guardMargin, period / 2)
        let wanted = pullPhase - period - leadSlack          // the largest x with lead ≥ P + slack
        if wanted >= xRef { return (xRef, true) }            // already enough lead: never move later
        if wanted >= low { return (wanted, true) }
        return (min(xRef, low), false)                       // the band's edge: as much lead as the guard allows (never later)
    }

    /// The median (the mean of the middle two for an even count). Empty: NaN.
    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let s = values.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// The card pull's matched-rate test, verbatim (`MetalVideoRenderer.deckLinkPullSlotLocked`, `let matched = …`). Option C is
    /// active only where the pull's half-frame band is: a source frame equal to the card frame within 1e-4 of it.
    public static func isMatched(sourceFrame: Double, cardFrame: Double) -> Bool {
        sourceFrame > 0 && abs(sourceFrame - cardFrame) < cardFrame * 1e-4
    }

    /// Whether the clock ran at 1× since the previous reading (both on the host clock, seconds): a positive host interval of at
    /// most 0.1 s and a rate within `unitRateTolerance` of 1. False with no previous reading or a non-finite value.
    public static func isUnitRate(clock: Double, host: Double, previous: (clock: Double, host: Double)?) -> Bool {
        guard let previous, clock.isFinite, host.isFinite, previous.clock.isFinite, previous.host.isFinite else { return false }
        let dt = host - previous.host
        guard dt > 0, dt <= 0.1 else { return false }
        return abs((clock - previous.clock) / dt - 1) <= unitRateTolerance
    }
}

/// |x − x_ref| in 1 µs bins up to 10 ms (one overflow bin above), for a p50, a p99 and the exact maximum. Fixed size, reset in
/// place: no allocation after init, so the pacer thread can keep it.
public struct PhaseDeviationStats {
    public static let binWidth = 1e-6
    public static let binCount = 10_000
    private var bins = [UInt32](repeating: 0, count: PhaseDeviationStats.binCount + 1)
    public private(set) var count = 0
    public private(set) var maximum = 0.0

    public init() {}

    public mutating func add(_ v: Double) {
        guard v.isFinite, v >= 0 else { return }
        bins[min(Int(v / Self.binWidth), Self.binCount)] &+= 1
        count += 1
        maximum = max(maximum, v)
    }

    public mutating func reset() {
        for i in bins.indices { bins[i] = 0 }
        count = 0; maximum = 0
    }

    /// The value at or below which `fraction` of the samples lie, to the bin's upper edge (1 µs); the overflow bin reports the
    /// exact maximum. NaN with no samples.
    public func quantile(_ fraction: Double) -> Double {
        guard count > 0 else { return .nan }
        let target = max(1, Int((Double(count) * fraction).rounded(.up)))
        var seen = 0
        for (i, n) in bins.enumerated() {
            seen += Int(n)
            if seen >= target { return i == Self.binCount ? maximum : min(Double(i + 1) * Self.binWidth, maximum) }
        }
        return maximum
    }
}

/// Option C's state on the pacer thread: the reference, the last eight x, and the corrections applied. One value per pacer.
///
/// x̄ is the median of the last eight x, each re-expressed at the corrections applied since it was taken: a sample taken before a
/// correction c read c less than the same phase reads now. So a correction is counted once, not again at every tick until the
/// median has caught up with it (which, at a median of eight, would overshoot by up to four times and ring). With that, applying
/// c = clamp(−(x̄ − x_ref), ±20 µs) at every tick, new frame or not, as §7 C step 3 says, settles in one step when unclamped.
public struct PacerPhaseFollower {
    /// Counters over a reporting window, and over the whole run.
    public struct Counts: Equatable, Sendable {
        public var newFrameTicks = 0, inactiveTicks = 0, outliers = 0, corrections = 0, clampHits = 0, references = 0, guards = 0
        public var net = 0.0
        /// Establishment-guard moves (`PacerPhase.establishmentCorrection`), counted apart from the follow's corrections.
        public var nudges = 0
        public var nudgeNet = 0.0
        /// C+ only (`leadGuard`): steps that moved the reference earlier for lead, and their total (seconds).
        public var leadMoves = 0
        public var leadNet = 0.0
        public init() {}
    }

    public enum Event: Equatable, Sendable {
        /// The reference was set: its value, the median it came from, and the guard.
        case referenceSet(reference: Double, median: Double, guarded: PacerPhase.Guard)
        /// Before the reference: a phase inside the guard band was moved to its edge. x as measured, and the move (seconds).
        case establishmentNudge(x: Double, moved: Double)
        /// C+ (`leadGuard`): the reference is being moved earlier for lead, from `from` toward `to` (seconds), against the pull
        /// phase that asked for it. `reachesSlack` false: the guard band's edge stops it short of P + `leadSlack`.
        case leadGuard(pullPhase: Double, from: Double, to: Double, reachesSlack: Bool)
    }

    /// Seconds per deadline unit (one mach tick in the app).
    public let quantum: Double
    public private(set) var reference: Double?
    /// Every deadline move since the reference was last dropped, in seconds (whole quanta): the establishment moves, then the
    /// follow's corrections, as one continuous total. Restarted only by `reset()`.
    public private(set) var applied = 0.0
    public private(set) var window = Counts()
    public private(set) var run = Counts()
    public private(set) var windowDeviation = PhaseDeviationStats()
    public private(set) var runDeviation = PhaseDeviationStats()
    private var firsts: [Double] = []
    private var recent: [Double] = []      // x − applied at the time of each sample: a ring of `PacerPhase.window`
    private var recentNext = 0
    private var establishDirection = 0     // the first establishment move's sign (−1 earlier, +1 later); 0 before one
    /// C+ (`MANIFOLD_PACER_PHASE=2`): choose the reference earlier for lead (`PacerPhase.leadReference`). False (option C): the
    /// pull phase passed to `tick` is ignored and nothing below changes.
    public let leadGuard: Bool
    private var leadTarget: Double?        // C+: where the reference is being moved, in steps of at most `guardMargin`
    private var ticksSinceLeadCheck = Int.max

    public init(quantum: Double, leadGuard: Bool = false) {
        self.quantum = quantum
        self.leadGuard = leadGuard
        firsts.reserveCapacity(PacerPhase.window)
        recent.reserveCapacity(PacerPhase.window)
    }

    /// Drop the reference: the next eight new-frame ticks set a new one. At a wake, a re-rate, and every inactive tick.
    public mutating func reset() {
        reference = nil; applied = 0; establishDirection = 0
        leadTarget = nil; ticksSinceLeadCheck = Int.max
        firsts.removeAll(keepingCapacity: true); recent.removeAll(keepingCapacity: true); recentNext = 0
    }

    /// One pacer tick, after the renderer's selection. Returns the correction for the next deadline, in quanta, and an event.
    /// `pullPhase` (C+ only, read only with `leadGuard`): the renderer's median pull phase for this Play, or nil until it has one.
    public mutating func tick(_ sample: PacerPhaseSample, period: Double, pullPhase: Double? = nil) -> (correction: Int64, event: Event?) {
        guard case .active(let x) = sample else {
            window.inactiveTicks += 1; run.inactiveTicks += 1
            if reference != nil || !firsts.isEmpty { reset() }
            return (0, nil)
        }
        var event: Event?
        if let x {
            window.newFrameTicks += 1; run.newFrameTicks += 1
            if !(x >= 0 && x < period) {
                // A frame a tick or more late (a decode, a missed deadline) or a clock oddity: not the tick's phase.
                window.outliers += 1; run.outliers += 1
            } else if let reference {
                if recent.count < PacerPhase.window { recent.append(x - applied) } else { recent[recentNext] = x - applied }
                recentNext = (recentNext + 1) % PacerPhase.window
                windowDeviation.add(abs(x - reference)); runDeviation.add(abs(x - reference))
            } else {
                // Establishing. Each sample is kept at the moves applied before it (x − applied), the same convention as
                // `recent`, so the reference is the median of the phase as it stands after those moves. `applied` is NOT
                // restarted when the reference is set: it is one continuous total from the reference's drop, so the
                // establishment moves and the follow's corrections are one account (a restart at the reference read as the
                // phase jumping back onto the due time; CARD_PULL_MARGIN.md §14.4).
                firsts.append(x - applied)
                if firsts.count == PacerPhase.window {
                    for i in firsts.indices { firsts[i] += applied }   // the phase now, for the median
                    let r = PacerPhase.reference(firstTicks: firsts, period: period)
                    for i in firsts.indices { firsts[i] -= applied }   // back to the ring's convention
                    if let r {
                        reference = r.value; establishDirection = 0
                        leadTarget = nil; ticksSinceLeadCheck = Int.max   // C+: check the lead as soon as the pull phase is in
                        recent.removeAll(keepingCapacity: true); recent.append(contentsOf: firsts); recentNext = 0
                        firsts.removeAll(keepingCapacity: true)
                        window.references += 1; run.references += 1
                        if r.guarded != .none { window.guards += 1; run.guards += 1 }
                        event = .referenceSet(reference: r.value, median: r.median, guarded: r.guarded)
                    }
                }
                if reference == nil {
                    // The establishment guard: no tick sits on a due time while the reference is being set.
                    // x near 0 and x near P are both on a due time, one each side of it. The first move's direction is
                    // latched for this establishment: a later sample read on the other side of the due time is not moved
                    // back across it, so the guard never fights itself across the wrap.
                    let c = PacerPhase.establishmentCorrection(x: x, period: period)
                    let q = quantum > 0 ? Int64((c / quantum).rounded()) : 0
                    guard q != 0, establishDirection == 0 || (q > 0) == (establishDirection > 0) else { return (0, event) }
                    establishDirection = q > 0 ? 1 : -1
                    let s = Double(q) * quantum
                    applied += s
                    window.nudges += 1; run.nudges += 1; window.nudgeNet += s; run.nudgeNet += s
                    return (q, .establishmentNudge(x: x, moved: s))
                }
            }
        }
        if leadGuard, event == nil, let move = leadStep(pullPhase: pullPhase, period: period) { return move }
        guard let reference, recent.count == PacerPhase.window, quantum > 0 else { return (0, event) }
        let phase = Self.median(ofRing: recent) + applied
        let c = PacerPhase.phaseCorrection(enabled: true, phase: phase, reference: reference)
        if abs(phase - reference) > PacerPhase.correctionClamp { window.clampHits += 1; run.clampHits += 1 }
        let q = Int64((c / quantum).rounded())
        if q != 0 {
            let s = Double(q) * quantum
            applied += s
            window.corrections += 1; run.corrections += 1; window.net += s; run.net += s
        }
        return (q, event)
    }

    /// C+, once the reference is set: every `leadCheckInterval` of pacer time (and at once after a new reference) compare the
    /// reference with `PacerPhase.leadReference`; when it should be earlier by more than `leadHysteresis`, move it there in steps of
    /// at most `PacerPhase.guardMargin` a tick (the establishment guard's step), the deadline with it. Moves are only earlier and stay
    /// inside the guard band, so no move crosses a due time. The reference and `applied` move together, so the follow's phase
    /// against the reference is unchanged by a move. Returns the tick's correction and event, or nil to fall through to the follow.
    static let leadCheckInterval = 10.0
    static let leadHysteresis = 50e-6
    private mutating func leadStep(pullPhase: Double?, period: Double) -> (correction: Int64, event: Event?)? {
        guard let ref = reference, quantum > 0, period > 0 else { return nil }
        var event: Event?
        if leadTarget == nil {
            let every = max(1, Int((Self.leadCheckInterval / period).rounded()))
            if ticksSinceLeadCheck != Int.max { ticksSinceLeadCheck += 1 }
            guard ticksSinceLeadCheck == Int.max || ticksSinceLeadCheck >= every, let pp = pullPhase, pp.isFinite else { return nil }
            ticksSinceLeadCheck = 0
            let r = PacerPhase.leadReference(xRef: ref, pullPhase: pp, period: period)
            guard r.value < ref - Self.leadHysteresis else { return nil }
            leadTarget = r.value
            event = .leadGuard(pullPhase: pp, from: ref, to: r.value, reachesSlack: r.reachesSlack)
        }
        guard let target = leadTarget else { return nil }
        let q = Int64((max(target - ref, -PacerPhase.guardMargin) / quantum).rounded())
        if q >= 0 || ref + Double(q) * quantum <= target + quantum { leadTarget = nil }
        guard q < 0 else { return event.map { (0, $0) } }
        let s = Double(q) * quantum
        reference = ref + s
        applied += s
        window.leadMoves += 1; run.leadMoves += 1; window.leadNet += s; run.leadNet += s
        return (q, event)
    }

    /// The median of the ring (at most `PacerPhase.window` values) without allocating: an insertion sort in a stack buffer, as
    /// this runs on the pacer's real-time thread at every tick. Equal to `PacerPhase.median` (tested).
    static func median(ofRing values: [Double]) -> Double {
        let n = values.count
        guard n > 0 else { return .nan }
        return withUnsafeTemporaryAllocation(of: Double.self, capacity: n) { buf in
            for i in 0..<n {
                var j = i
                let v = values[i]
                while j > 0, buf[j - 1] > v { buf[j] = buf[j - 1]; j -= 1 }
                buf[j] = v
            }
            return n % 2 == 1 ? buf[n / 2] : (buf[n / 2 - 1] + buf[n / 2]) / 2
        }
    }

    /// The window's line (after "[PACER-PHASE] "), and the window reset. `run: true` gives the whole run's line instead.
    public mutating func report(run whole: Bool = false, seconds: Double = 10) -> String {
        let c = whole ? run : window, d = whole ? runDeviation : windowDeviation
        let dev = d.count > 0
            ? String(format: "|x − x_ref| p50 %.3f p99 %.3f max %.3f ms (n=%d)", d.quantile(0.5) * 1000, d.quantile(0.99) * 1000,
                     d.maximum * 1000, d.count)
            : "|x − x_ref| n=0"
        var line = String(format: "%@: new-frame ticks %d · inactive ticks %d · outliers %d · %@ · corrections applied %d (net %+.3f ms) · "
                          + "clamp hits %d · references set %d (guard %d) · establishment nudges %d (net %+.3f ms)",
                          whole ? "run" : String(format: "%.0f s", seconds), c.newFrameTicks, c.inactiveTicks, c.outliers, dev,
                          c.corrections, c.net * 1000, c.clampHits, c.references, c.guards, c.nudges, c.nudgeNet * 1000)
        if leadGuard { line += String(format: " · lead moves %d (net %+.3f ms)", c.leadMoves, c.leadNet * 1000) }
        if !whole { window = Counts(); windowDeviation.reset() }
        return line
    }
}
