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
