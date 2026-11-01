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
