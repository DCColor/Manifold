//
//  CardPullMeasurement.swift
//  OutputPacing
//
//  MEASUREMENT ONLY: THE PURE PIECES OF THE CARD-PULL MEASUREMENT BUILD (docs/CARD_PULL_MARGIN.md, *Measurement build*).
//
//  The app uses these only under `#if DEBUG`, and only with `MANIFOLD_DECKLINK_CADENCE_LOG=2` (the [PULLPHASE], [TICKPHASE] and
//  [LATE-SWAP] lines) or `MANIFOLD_DECKLINK_LATE_SWAP_AT` (the forced-late-swap test switch) in the launch environment. Nothing
//  here is called by the pull, the pacer, the card lock or the audio paths: they are read for the log, never steered.
//
//  Kept here, a leaf target with tests, so the parser, the pull's outcome, the late-swap detector and its classifier can be pinned
//  by `swift test` without a card.
//

import Foundation

// MARK: - The forced-late-swap switch (§9.2)

/// What one entry of `MANIFOLD_DECKLINK_LATE_SWAP_AT` does to the first new frame at or past its content time.
public enum LateSwapMode: Equatable {
    /// The window withholds that frame from selection for this many output-pacer ticks, as a tick crossing its due time does.
    case ticks(Int)
    /// That frame's publish to the DeckLink ring is delayed by this many seconds (a slow convert). The window is unaffected.
    case publishDelay(Double)
}

public struct LateSwapEntry: Equatable {
    public let at: Double
    public let mode: LateSwapMode
    public init(at: Double, mode: LateSwapMode) { self.at = at; self.mode = mode }
}

public enum LateSwapSchedule {
    /// Ticks per entry: at least one, at most this many.
    public static let maximumTicks = 16
    /// Longest publish delay, in milliseconds.
    public static let maximumDelayMs = 1000.0

    /// `"120,247:2,374:ms6"` → content 120 s, one tick; 247 s, two ticks; 374 s, publish delayed 6 ms. Comma-separated
    /// `seconds[:mode]`, mode `n` (ticks, 1…16, default 1) or `msN` (0 < N ≤ 1000). An item that does not parse is dropped, as
    /// `MANIFOLD_DECKLINK_SLIP_AT` drops its own. Order is kept: each entry fires once, at the first new frame at or past it.
    public static func parse(_ spec: String) -> [LateSwapEntry] {
        spec.split(separator: ",").compactMap { raw in
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 1 || parts.count == 2, let at = Double(parts[0]), at.isFinite, at >= 0 else { return nil }
            if parts.count == 1 { return LateSwapEntry(at: at, mode: .ticks(1)) }
            let mode = parts[1]
            if mode.hasPrefix("ms") {
                guard let ms = Double(mode.dropFirst(2)), ms.isFinite, ms > 0, ms <= maximumDelayMs else { return nil }
                return LateSwapEntry(at: at, mode: .publishDelay(ms / 1000))
            }
            guard let n = Int(mode), n >= 1, n <= maximumTicks else { return nil }
            return LateSwapEntry(at: at, mode: .ticks(n))
        }
    }
}

// MARK: - The pull's outcome, read from what it handed

/// Which way a pull went, RECONSTRUCTED from its outcome (the frame handed, the frame handed before, the target, the ring), not
/// instrumented inside `deckLinkPullSlotLocked`, which the measurement build leaves untouched.
public enum PullBranch: String {
    /// Not a timed pull, with the clock moving: a step, seek, loop wrap, shuttle, live source or no clock (the newest frame).
    case untimed
    /// Not a timed pull, with the clock still since the last pull: paused.
    case paused
    /// Timed: the frame handed is due by the target.
    case due
    /// Timed: the frame after the one handed last, taken inside the band although it is not due by the target.
    case nextByBand = "next-by-band"
    /// Timed: the frame after the one handed last, taken although a newer frame was due (the one-new-frame rule).
    case wouldSkip = "would-skip"
    /// Timed: the frame handed last, again. A repeat.
    case held
    /// Timed: none of the above (the ring had nothing due and not the frame handed last: its earliest frame).
    case earliest
}

public enum PullOutcome {
    /// Matching tolerance for "due by the target", as the pull's own (`pts <= target + 1e-4`).
    public static let dueTolerance = 1e-4

    public static func branch(timed: Bool, clockMoved: Bool, handed: Double, previous: Double, target: Double,
                              ring: [Double]) -> PullBranch {
        guard timed else { return clockMoved ? .untimed : .paused }
        if previous.isFinite, handed == previous { return .held }
        if target.isFinite, handed <= target + dueTolerance {
            let newerDue = ring.contains { $0.isFinite && $0 > handed && $0 <= target + dueTolerance }
            return newerDue && previous.isFinite && handed > previous ? .wouldSkip : .due
        }
        if previous.isFinite, handed > previous { return .nextByBand }
        return .earliest
    }
}

// MARK: - Late swaps

/// A swap is late when its swap − due (`s`: the tick's lateness after the frame's due time plus the tick → ring time) is more than
/// half a pacer tick above the running cluster: the 10th percentile of the previous `window` values of the same Play.
public struct LateSwapBaseline {
    public let window: Int
    public let minimum: Int
    private var recent: [Double] = []

    public init(window: Int = 48, minimum: Int = 8) {
        self.window = max(1, window)
        self.minimum = max(1, minimum)
    }

    public mutating func reset() { recent.removeAll(keepingCapacity: true) }

    public var count: Int { recent.count }

    /// Adds `s` (seconds). Returns whether it is late against the values before it, and the baseline it was judged against
    /// (NaN until `minimum` values have been seen; those first values are never late).
    public mutating func observe(_ s: Double, period: Double) -> (late: Bool, baseline: Double) {
        guard s.isFinite else { return (false, .nan) }
        var baseline = Double.nan
        if recent.count >= minimum {
            let sorted = recent.sorted()
            baseline = sorted[(sorted.count - 1) / 10]
        }
        recent.append(s)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        guard baseline.isFinite, period.isFinite, period > 0 else { return (false, baseline) }
        return (s > baseline + period / 2, baseline)
    }
}

/// Why a swap was late (docs/CARD_PULL_MARGIN.md §9.1).
public enum LateSwapClass: String, CaseIterable {
    /// The tick before ran just short of the frame's due time: a tick crossing it.
    case crossing
    /// The frame was due at the tick before, but had not entered the frame queue by then.
    case decode
    /// The rendering tick was on time, but the frame reached the ring after the next tick boundary.
    case render
    /// The pacer's interval before the rendering tick was over 1.5 ticks: a missed deadline.
    case pacer
    /// The main thread had not run its heartbeat for over a tick at the rendering tick.
    case main
    case other
}

/// What is known about one late swap. Times in seconds; NaN = not known.
public struct LateSwapEvidence {
    public var pts: Double
    public var period: Double
    /// The clock the rendering tick selected at, and the tick before's.
    public var tickClock: Double
    public var previousTickClock: Double
    /// Host time of the tick before, and of the frame's entry into the frame queue.
    public var previousTickHost: Double
    public var enqueueHost: Double
    public var tickToRing: Double
    public var intervalBefore: Double
    public var mainLag: Double

    public init(pts: Double, period: Double, tickClock: Double, previousTickClock: Double, previousTickHost: Double,
                enqueueHost: Double, tickToRing: Double, intervalBefore: Double, mainLag: Double) {
        self.pts = pts; self.period = period; self.tickClock = tickClock; self.previousTickClock = previousTickClock
        self.previousTickHost = previousTickHost; self.enqueueHost = enqueueHost; self.tickToRing = tickToRing
        self.intervalBefore = intervalBefore; self.mainLag = mainLag
    }
}

public enum LateSwapClassifier {
    /// A tick before that fell short of the due time by up to this much is a crossing (seconds).
    public static let crossingWindow = 0.0002

    /// First match wins: pacer, decode, crossing, render, main, other.
    public static func classify(_ e: LateSwapEvidence) -> LateSwapClass {
        if e.intervalBefore.isFinite, e.period > 0, e.intervalBefore > 1.5 * e.period { return .pacer }
        if e.previousTickClock.isFinite, e.previousTickClock >= e.pts {
            let queuedInTime = e.enqueueHost.isFinite && e.previousTickHost.isFinite && e.enqueueHost <= e.previousTickHost
            if !queuedInTime { return .decode }
        }
        if e.previousTickClock.isFinite {
            let short = e.pts - e.previousTickClock
            if short > 0, short <= crossingWindow + 1e-9 { return .crossing }
        }
        // Render: the rendering tick WAS the first at or after the due time (x < one tick), and the frame still reached the ring
        // past the next tick boundary. A tick that was itself late (x ≥ one tick) is not the render's doing.
        if e.tickToRing.isFinite, e.tickClock.isFinite {
            let x = e.tickClock - e.pts
            if x >= 0, x < e.period, e.tickToRing > e.period - x { return .render }
        }
        if e.mainLag.isFinite, e.mainLag > e.period { return .main }
        return .other
    }
}

// MARK: - A least-squares slope

/// y against x, about the first point (host times are large; their differences are what matter).
public struct SlopeFit {
    private var x0 = Double.nan, y0 = Double.nan
    private var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
    public init() {}
    public var count: Int { Int(n) }
    public mutating func add(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        if !x0.isFinite { x0 = x; y0 = y }
        let dx = x - x0, dy = y - y0
        n += 1; sx += dx; sy += dy; sxx += dx * dx; sxy += dx * dy
    }
    /// NaN with fewer than two points or no spread in x.
    public var slope: Double {
        let d = n * sxx - sx * sx
        guard n >= 2, d > 0 else { return .nan }
        return (n * sxy - sx * sy) / d
    }
}
