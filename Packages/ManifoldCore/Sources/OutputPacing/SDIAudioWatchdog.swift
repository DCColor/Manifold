//
//  SDIAudioWatchdog.swift
//  OutputPacing
//
//  THE CARD'S AUDIO CALLBACK STOPPING (docs/SDI_AUDIO_NIGHT7.md, fault (a); docs/BUGS.md). On night 7 the DeckLink SDK stopped
//  calling `RenderAudioSamples` mid-session while the video callbacks ran on: 55 min of SDI picture without sound, with no recovery
//  while the output ran. The cause is on the card's side of the API and is not known, so this does not prevent it: it notices it
//  and restarts the output, as the silent-start recovery does (docs/CARD_CLOCK_FINDINGS.md §10.25).
//
//  The decision only. `DeckLinkService` feeds it the bridge's callback count a few times a second, on its serial queue, and acts on
//  the answer:
//    • While output runs with sound and the transport plays, a count that has not moved for `stallSeconds` is a stop: `.recover`.
//    • At most one recovery per `retryWindow`. A stop within `retryWindow` of the last recovery is `.giveUp`: no more restarts
//      until the operator restarts output (`reset`), and the user is told.
//    • Paused, no sound or no output: nothing is judged, and the stall clock starts again when all three hold.
//

import Foundation

public struct SDIAudioWatchdog: Sendable, Equatable {
    /// A callback count that has not moved for this long, while playing with sound, is a stop. The callback comes about every 10 ms;
    /// the card's audio queue is 80–200 ms deep, so a stop is audible within a fifth of a second and 3 s is never a slow callback.
    public static let stallSeconds = 3.0
    /// At most one restart per this long. A second stop inside it gives up for the output session.
    public static let retryWindow = 60.0

    public struct Input: Sendable, Equatable {
        /// The card's output is running (started, not stopping).
        public var outputRunning: Bool
        /// The output carries the file's sound: SDI audio enabled on the card, and SDI is a destination.
        public var hasSound: Bool
        /// The transport is playing (not paused).
        public var playing: Bool
        /// Every entry into the card's audio callback since this output started.
        public var callbacks: UInt64
        /// Host seconds (`CACurrentMediaTime`).
        public var now: Double
        public init(outputRunning: Bool, hasSound: Bool, playing: Bool, callbacks: UInt64, now: Double) {
            self.outputRunning = outputRunning; self.hasSound = hasSound; self.playing = playing; self.callbacks = callbacks; self.now = now
        }
    }

    public enum Action: Sendable, Equatable {
        case none
        /// Restart the output. `stalledFor`: seconds since the count last moved (or since the watch began).
        case recover(stalledFor: Double)
        /// A second stop within `retryWindow` of the last recovery: log it, tell the user, restart nothing more.
        case giveUp(stalledFor: Double, sinceRecovery: Double)
    }

    /// The count and when it last moved (or when watching began). nil: not watching.
    public private(set) var lastCallbacks: UInt64?
    public private(set) var lastAdvance = 0.0
    /// The current stall has already been acted on.
    public private(set) var handled = false
    public private(set) var lastRecovery: Double?
    public private(set) var gaveUp = false

    public init() {}

    public mutating func step(_ i: Input) -> Action {
        guard i.outputRunning, i.hasSound, i.playing else {
            lastCallbacks = nil   // the stall clock starts again when all three hold
            handled = false
            return .none
        }
        guard let last = lastCallbacks, last == i.callbacks else {
            // Watching begins, or the count moved (a restarted output counts from 0, which is a move too).
            lastCallbacks = i.callbacks; lastAdvance = i.now; handled = false
            return .none
        }
        let stalled = i.now - lastAdvance
        guard stalled >= Self.stallSeconds, !handled, !gaveUp else { return .none }
        handled = true
        if let r = lastRecovery, i.now - r < Self.retryWindow {
            gaveUp = true
            return .giveUp(stalledFor: stalled, sinceRecovery: i.now - r)
        }
        lastRecovery = i.now
        return .recover(stalledFor: stalled)
    }

    /// The operator stopped or started output: a new session, restarts allowed again.
    public mutating func reset() { self = SDIAudioWatchdog() }
}
