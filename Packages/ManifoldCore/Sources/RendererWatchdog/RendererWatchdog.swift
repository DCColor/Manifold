//
//  RendererWatchdog.swift
//  RendererWatchdog
//
//  THE PICTURE FREEZE (docs/BUGS.md, top 1.0 entry; docs/PICTURE_FREEZE_AUDIT.md). The decision only, and the counts Export
//  Diagnostics shows. `FrameEngine.rendererWatchdogTick` (20 Hz on main, only while a video file plays) reads the pacing renderer
//  and the pumps' `RendererActivity`, feeds one `Reading` here, and carries out the `Action` it gets back. A leaf target so
//  `swift test` reaches it: `swift test` cannot link ManifoldCore.
//
//  The state: renderer NOT ready, the pump not at end of stream, and nothing of ours pending (the renderer's clock is a frame past
//  the last frame we enqueued, or nothing has been enqueued `unarmedGrace` after an arm). Healthy play never holds it: the pump
//  keeps 0.1–0.2 s ahead, and a renderer with nothing due ahead is ready (0 states over 100 ms that cleared by themselves in 54 h).
//    • The state lasting over `nearMissAfter` and clearing by itself before a recovery: `.nearMiss`.
//    • In the state for `recoverInState`, with no pump callback for `recoverAfterSilence`: `.rearm(attempt: 1)`, one stall.
//    • No frame within `rearmWait` of a re-arm: `.rearm` again, up to `rearmAttempts`; then `.rebuild` once (a new session at the
//      clock); no frame within `rearmWait` of that: `.gaveUp`, which is not retried until the state clears or transport stops.
//    • A frame after a re-arm or the rebuild: `.recovered`.
//

import Foundation

public struct RendererWatchdog: Sendable, Equatable {

    public struct Thresholds: Sendable, Equatable {
        /// The state lasting longer than this, then clearing by itself, is a near-miss. Must stay below `recoverInState`, or a
        /// state that would have cleared by itself is recovered before it can be seen to clear.
        public var nearMissAfter: Double
        /// A recovery needs the state to have lasted this long ...
        public var recoverInState: Double
        /// ... and no pump callback for this long (the detection wait; 500 ms until 0.9.5, Robbie 2026-11-20).
        public var recoverAfterSilence: Double
        /// A re-arm (or the rebuild) that brings no frame within this is tried again (or given up).
        public var rearmWait: Double
        /// Re-arms on the same session before the one rebuild.
        public var rearmAttempts: Int
        /// After an arm with nothing enqueued yet, the renderer counts as holding nothing once this has passed.
        public var unarmedGrace: Double

        public init(nearMissAfter: Double, recoverInState: Double, recoverAfterSilence: Double, rearmWait: Double,
                    rearmAttempts: Int, unarmedGrace: Double) {
            self.nearMissAfter = nearMissAfter; self.recoverInState = recoverInState; self.recoverAfterSilence = recoverAfterSilence
            self.rearmWait = rearmWait; self.rearmAttempts = rearmAttempts; self.unarmedGrace = unarmedGrace
        }

        /// Shipping values. The four real stalls entered the state 0.15–0.18 s after the pump's last callback (its normal lead), so
        /// with a 200 ms silence wait the binding condition is `recoverInState`: recovery about 0.15 s into the state, where it was
        /// 0.35–0.39 s with the 500 ms wait. The 0.10–0.15 s band in between is where a self-clearing state is still seen.
        public static let shipping = Thresholds(nearMissAfter: 0.10, recoverInState: 0.15, recoverAfterSilence: 0.20,
                                                rearmWait: 1.0, rearmAttempts: 3, unarmedGrace: 0.25)
    }

    public enum State: Sendable, Equatable {
        case idle
        /// In the state since `since`. `wouldRecover`: recovery is switched off (measurement) and the recovery point was passed.
        case stalled(since: Double, wouldRecover: Bool)
        /// Re-armed (or rebuilt) at `armHost`, waiting for a frame; `attempts` re-arms so far.
        case recovering(began: Double, armHost: Double, attempts: Int, rebuilt: Bool)
        /// Out of steps for this episode: wait for the state to clear, or for transport to stop.
        case gaveUp
    }

    /// One look at the renderer and the pumps' activity (`RendererActivity.Snapshot` plus the renderer's own readings).
    public struct Reading: Sendable, Equatable {
        public var now: Double
        public var ready: Bool
        public var ended: Bool
        public var armedHost: Double
        public var lastCallbackHost: Double
        public var lastEnqueueHost: Double
        public var lastEnqueuedPTS: Double
        public var frameDuration: Double
        public var enqueuedSinceArm: Int
        /// The renderer timebase's time.
        public var rendererClock: Double

        public init(now: Double, ready: Bool, ended: Bool, armedHost: Double, lastCallbackHost: Double, lastEnqueueHost: Double,
                    lastEnqueuedPTS: Double, frameDuration: Double, enqueuedSinceArm: Int, rendererClock: Double) {
            self.now = now; self.ready = ready; self.ended = ended; self.armedHost = armedHost; self.lastCallbackHost = lastCallbackHost
            self.lastEnqueueHost = lastEnqueueHost; self.lastEnqueuedPTS = lastEnqueuedPTS; self.frameDuration = frameDuration
            self.enqueuedSinceArm = enqueuedSinceArm; self.rendererClock = rendererClock
        }
    }

    public enum Action: Sendable, Equatable {
        case none
        /// The state cleared by itself after `lasted` s. `pastRecoveryPoint`: recovery was switched off and would have run.
        case nearMiss(lasted: Double, pastRecoveryPoint: Bool)
        /// Recovery is switched off (measurement): it would run now. Once per episode. Counted as a stall.
        case wouldRecover(since: Double)
        /// Flush the renderer and re-arm its request on the same session. Attempt 1 is a new stall.
        case rearm(attempt: Int, began: Double)
        /// Three re-arms brought no frame: rebuild the session at the clock, once.
        case rebuild(attempts: Int, began: Double)
        /// The rebuild brought no frame either: the picture stays frozen.
        case gaveUp(attempts: Int, began: Double)
        /// A frame came out: `firstFrameAfterArm` s after the last re-arm (or the rebuild), `sinceStallBegan` s after the state began.
        case recovered(firstFrameAfterArm: Double, sinceStallBegan: Double, afterRebuild: Bool)
    }

    public let thresholds: Thresholds
    public private(set) var state: State = .idle

    public init(thresholds: Thresholds = .shipping) { self.thresholds = thresholds }

    /// Nothing of ours pending in the renderer: every frame we gave it is due, or none was given `unarmedGrace` after the arm.
    public func nothingPending(_ r: Reading) -> Bool {
        let frame = r.frameDuration > 0 ? r.frameDuration : 1.0 / 60
        return r.enqueuedSinceArm == 0 ? r.now - r.armedHost > thresholds.unarmedGrace : r.rendererClock > r.lastEnqueuedPTS + frame
    }

    /// The stalled state.
    public func inState(_ r: Reading) -> Bool { !r.ended && !r.ready && nothingPending(r) }

    /// Paused, no file, or no renderer: not this fault's to judge. The next look starts from idle.
    public mutating func notJudged() { state = .idle }

    public mutating func step(_ r: Reading, recoveryEnabled: Bool = true) -> Action {
        let t = thresholds
        let stalled = inState(r)
        switch state {
        case .idle:
            if stalled { state = .stalled(since: r.now, wouldRecover: false) }
            return .none
        case let .stalled(since, wouldRecover):
            if !stalled {
                state = .idle
                let lasted = r.now - since
                return lasted > t.nearMissAfter ? .nearMiss(lasted: lasted, pastRecoveryPoint: wouldRecover) : .none
            }
            guard r.now - r.lastCallbackHost >= t.recoverAfterSilence, r.now - since >= t.recoverInState else { return .none }
            guard recoveryEnabled else {
                if wouldRecover { return .none }
                state = .stalled(since: since, wouldRecover: true)
                return .wouldRecover(since: since)
            }
            state = .recovering(began: since, armHost: r.now, attempts: 1, rebuilt: false)
            return .rearm(attempt: 1, began: since)
        case let .recovering(began, armHost, attempts, rebuilt):
            if r.enqueuedSinceArm > 0 {   // the re-arm (or the rebuild's new session) zeroed it
                state = .idle
                return .recovered(firstFrameAfterArm: r.lastEnqueueHost - armHost, sinceStallBegan: r.now - began, afterRebuild: rebuilt)
            }
            guard r.now - armHost >= t.rearmWait else { return .none }
            if rebuilt {
                state = .gaveUp
                return .gaveUp(attempts: attempts, began: began)
            }
            if attempts < t.rearmAttempts {
                state = .recovering(began: began, armHost: r.now, attempts: attempts + 1, rebuilt: false)
                return .rearm(attempt: attempts + 1, began: began)
            }
            state = .recovering(began: began, armHost: r.now, attempts: attempts, rebuilt: true)
            return .rebuild(attempts: attempts, began: began)
        case .gaveUp:
            if !stalled { state = .idle }
            return .none
        }
    }
}

/// What Export Diagnostics and the `[DIAG]` line count: stalls (episodes), not re-arm attempts, and every give-up.
public struct RendererRecoveryTally: Sendable, Equatable {
    public var stalls = 0
    public var rearms = 0
    public var rebuilds = 0
    public var recovered = 0
    public var gaveUp = 0
    public var nearMisses = 0

    public init() {}

    public mutating func note(_ action: RendererWatchdog.Action) {
        switch action {
        case .none: break
        case .nearMiss: nearMisses += 1
        case .wouldRecover: stalls += 1
        case let .rearm(attempt, _): rearms += 1; if attempt == 1 { stalls += 1 }
        case .rebuild: rebuilds += 1
        case .gaveUp: gaveUp += 1
        case .recovered: recovered += 1
        }
    }

    private static func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    /// One line, e.g. "1 stall (1 recovered, 0 GAVE UP), 3 re-arms, 0 rebuilds, 0 near-misses since launch".
    public var summary: String {
        "\(Self.n(stalls, "stall", "stalls")) (\(recovered) recovered, \(gaveUp) GAVE UP), \(Self.n(rearms, "re-arm", "re-arms")), "
            + "\(Self.n(rebuilds, "rebuild", "rebuilds")), \(Self.n(nearMisses, "near-miss", "near-misses")) since launch"
    }
}
