//
//  PacingRendererWatchdog.swift
//  ManifoldCore
//
//  THE PICTURE FREEZE (docs/BUGS.md, top 1.0 entry; docs/CARD_CLOCK_FINDINGS.md §10.14–§10.15).
//
//  A playing file's hidden pacing renderer (the AVSampleBufferDisplayLayer's AVSampleBufferVideoRenderer) can report
//  `isReadyForMoreMediaData` false while it holds nothing: CoreMedia logs its video queue at 0 frames and its image queue
//  at 0 unconsumed, its timebase runs, and its `requestMediaDataWhenReady` block is never called again. The decode pump
//  is paced by that callback alone, so the picture stops for good while the clock and the sound run on. Measured five
//  times, with the 1b gate on and off, on both decode paths. No ordering fault on our side was found that leaves it there
//  (§10.15), so this does not prevent it: it notices it and gets out of it.
//
//  Both pumps report here (`RendererActivity`). The engine's watchdog (`FrameEngine.rendererWatchdogTick`, 20 Hz on main,
//  reads only while a file plays) feeds the decision, `RendererWatchdog` (its own leaf target, with tests): rate > 0,
//  renderer NOT ready, and nothing of ours pending in it (its timebase is a frame past the last frame we enqueued, so every
//  frame we gave it is due). That state never happens in healthy play: the pump keeps 0.1–0.2 s ahead, and a renderer with
//  nothing due ahead is ready.
//    • Lasting over 100 ms and clearing on its own: one `[RENDERER-NEARMISS]` line and a count.
//    • In the state for 150 ms with no pump callback for 200 ms (500 ms until 0.9.5): one `[RENDERER-RECOVER]` line, then
//      flush the renderer and re-arm the request on the same session (no seek, no audio touched). If three re-arms in a row
//      do not bring a frame out, the session is rebuilt at the clock (a seek), said in its own line; then GAVE UP.
//  The counts (stalls, re-arms, rebuilds, recovered, gave up, near-misses) are process-wide and go into Export Diagnostics.
//

import Foundation
import QuartzCore
import RendererWatchdog

/// What the pump has done to the pacing renderer in the current arm. The pump queue writes; main reads.
public final class RendererActivity: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var armedHost = 0.0
        public var lastCallbackHost = 0.0
        public var lastEnqueueHost = 0.0
        public var lastEnqueuedPTS = Double.nan
        public var frameDuration = 0.0
        public var enqueuedSinceArm = 0
        public var ended = false
    }
    private let lock = NSLock()
    private var s = Snapshot()

    public init() {}

    public func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return s }

    /// The request was armed (a new session, or a recovery's re-arm).
    public func armed() {
        let now = CACurrentMediaTime()
        lock.lock(); s.armedHost = now; s.lastCallbackHost = now; s.enqueuedSinceArm = 0; s.ended = false; lock.unlock()
    }

    /// The pump body was entered.
    public func callback() { let now = CACurrentMediaTime(); lock.lock(); s.lastCallbackHost = now; lock.unlock() }

    /// A frame went into the pacing renderer.
    public func enqueued(pts: Double) {
        let now = CACurrentMediaTime()
        lock.lock()
        if s.lastEnqueuedPTS.isFinite, pts > s.lastEnqueuedPTS, pts - s.lastEnqueuedPTS < 0.5 { s.frameDuration = pts - s.lastEnqueuedPTS }
        s.lastEnqueuedPTS = pts; s.lastEnqueueHost = now; s.enqueuedSinceArm += 1
        lock.unlock()
    }

    /// The pump took its end-of-stream branch: a not-ready renderer after it is not a stall.
    public func ended() { lock.lock(); s.ended = true; lock.unlock() }
}

/// Process-wide counts for Export Diagnostics and the `[DIAG]` line: stalls, not re-arm attempts, and every give-up.
public enum RendererRecoveryStats {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tally = RendererRecoveryTally()
    nonisolated(unsafe) private static var lastStallLine: String?
    nonisolated(unsafe) private static var lastOutcomeLine: String?

    /// Count one decision. `line` is the log line it printed: a stall's first re-arm is kept as the last stall, a recovery or a
    /// give-up as the last outcome.
    static func note(_ action: RendererWatchdog.Action, line: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        tally.note(action)
        switch action {
        case .rearm(attempt: 1, _), .wouldRecover: lastStallLine = line
        case .recovered, .gaveUp: lastOutcomeLine = line
        default: break
        }
    }

    public static var counts: RendererRecoveryTally { lock.lock(); defer { lock.unlock() }; return tally }

    /// One line for the diagnostics report.
    public static var summary: String { counts.summary }
    /// The last stall's first attempt line, with the renderer's state.
    public static var lastStall: String? { lock.lock(); defer { lock.unlock() }; return lastStallLine }
    /// The last stall's outcome: "picture moving again" or GAVE UP.
    public static var lastOutcome: String? { lock.lock(); defer { lock.unlock() }; return lastOutcomeLine }
}
