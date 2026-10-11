//
//  StartupRealignWindow.swift — StartupRealign
//
//  The arithmetic of LiveClock's windowed start-up realign (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10,
//  *The B-frame start-up offset*): the mean of the depth samples over a whole number of TEETH. A leaf
//  target with no dependencies so `swift test` reaches it — LiveClock itself reads the host clock and
//  lives in a module a test bundle cannot link.
//
//  WHY TEETH, COUNTED FROM ARRIVALS. On a stream that reorders its pictures the depth the clock
//  regulates is a sawtooth: it jumps when the newest queued PTS advances (a leading picture arrives)
//  and falls with the clock until the next one. The anchor lands anywhere on it, so its offset is
//  `mean − target`. The mean over whole teeth is exact whatever their length, which a span of time is
//  not: one step of the pre-anchor backlog measured half a tooth on a sender that delivers pictures in
//  pairs. And the teeth differ with arrival jitter, so one tooth is not enough: measured, one tooth's
//  mean is ±20 ms (1 sd) from the long run, four teeth' ±9 (§6.10, step 2). Decided (Robbie,
//  2026-10-10): at least four whole teeth.
//

/// One window's worth of depth samples, over `teeth` whole teeth. Value type; the owner holds it
/// under its own lock.
public struct StartupRealignWindow: Sendable, Equatable {
    /// Whole teeth to average. 0 = disabled.
    public let teeth: Int
    /// The newest PTS seen so far — what an advance is measured against.
    public private(set) var lastNewest: Double?
    /// Whether the window has opened (the first advance has been seen).
    public private(set) var opened = false
    /// Advances seen since the window opened: the number of teeth completed.
    public private(set) var advances = 0
    public private(set) var sum = 0.0
    public private(set) var count = 0

    /// ≤ 0 = disabled.
    public init(teeth: Int) {
        self.teeth = max(0, teeth)
    }

    public var isEnabled: Bool { teeth > 0 }

    /// Add the depth sample `span`, taken while the newest queued PTS was `newest`. The window opens at
    /// the first sample on which `newest` has advanced, so its first sample is a tooth's top; it closes
    /// on the sample at which the `teeth`-th further advance is seen, and returns the mean then. That
    /// closing sample starts the next tooth and is NOT in the mean, so the mean covers exactly `teeth`
    /// whole teeth. nil while waiting or filling. Disabled: always nil.
    public mutating func add(span: Double, newest: Double) -> Double? {
        guard isEnabled else { return nil }
        let advanced = lastNewest.map { newest > $0 } ?? false
        lastNewest = max(lastNewest ?? newest, newest)
        guard opened else {
            if advanced {
                opened = true
                sum = span
                count = 1
            }
            return nil
        }
        if advanced {
            advances += 1
            if advances >= teeth { return sum / Double(count) }
        }
        sum += span
        count += 1
        return nil
    }

    /// Something moved the clock under the window (a target step, a queue-full re-anchor): what was
    /// measured describes a position that no longer exists. The next advance opens it again.
    public mutating func restart() {
        opened = false
        advances = 0
        sum = 0
        count = 0
    }
}
