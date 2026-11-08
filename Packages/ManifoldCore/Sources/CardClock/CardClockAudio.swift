//
//  CardClockAudio.swift
//  CardClock
//
//  The muted Mac renderer's own clock under card lock (docs/CARD_CLOCK_FINDINGS.md §10.7, Stage 1b). It runs on the Mac's device, so it parts from
//  the picture at their difference. Behind the picture, the tap's lead over the card's cursor shrinks by the same amount, so it is put back
//  before it can take a meaningful part of that lead.
//

import Foundation

public enum CardClockAudio {
    /// Everything Stage 1b does (the renderer's move, the sound's own clock, the lock with sound) is off unless the launch environment
    /// has `MANIFOLD_CARDLOCK_1B=1`, until the picture freeze is understood (docs/CARD_CLOCK_FINDINGS.md §10.13). Read once, at first use.
    public static let stage1b = stage1bEnabled(environment: ProcessInfo.processInfo.environment)
    static func stage1bEnabled(environment: [String: String]) -> Bool { environment["MANIFOLD_CARDLOCK_1B"] == "1" }

    /// A tenth of the tap's 250 ms look-ahead, from which the 232 ms measured lead comes (§10.7). Not from any device's or card's rate.
    public static let partBound = 0.020
    /// A paired read of the two clocks taking longer than this says nothing about the pair (the same rule as live audio, §10.2).
    public static let pairedReadLimit = 200e-6

    /// `part` is the audio clock less the picture clock, seconds.
    public static func needsAnchor(part: Double) -> Bool { part.isFinite && abs(part) > partBound }
}
