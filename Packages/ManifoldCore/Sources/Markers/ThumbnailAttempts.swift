//
//  ThumbnailAttempts.swift — how often a marker thumbnail is tried (docs/MARKERS_PLAN.md §4.4, Robbie 2026-11-15).
//
//  A failed decode is retried ONCE; a second failure shows "no preview" until Regenerate resets it. Keyed by the exact
//  frame, like everything else about thumbnails.
//

public struct ThumbnailAttempts: Equatable, Sendable {
    public static let maxAttempts = 2
    private var failures: [Int: Int] = [:]

    public init() {}

    /// Record a failure. True when the frame has now used its attempts and shows "no preview".
    @discardableResult
    public mutating func recordFailure(_ frame: Int) -> Bool {
        failures[frame, default: 0] += 1
        return failures[frame, default: 0] >= Self.maxAttempts
    }

    public func gaveUp(_ frame: Int) -> Bool { failures[frame, default: 0] >= Self.maxAttempts }

    public var givenUp: Set<Int> { Set(failures.filter { $0.value >= Self.maxAttempts }.keys) }

    /// Regenerate: these frames start again (all when nil).
    public mutating func reset(_ frames: Set<Int>? = nil) {
        if let frames { for f in frames { failures[f] = nil } } else { failures = [:] }
    }

    /// Keep only these frames' records (markers deleted).
    public mutating func keep(_ frames: Set<Int>) { failures = failures.filter { frames.contains($0.key) } }
}
