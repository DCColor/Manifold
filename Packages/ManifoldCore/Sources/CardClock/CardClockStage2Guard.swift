//
//  CardClockStage2Guard.swift
//  CardClock
//
//  Two guards on Stage 2's writes to the Mac sound's clock (docs/SDI_AUDIO_NIGHT7.md, fault (b); docs/BUGS.md).
//
//  Night 7, GOP block: a seek while playing left two pre-seek frames moving on the card, and the bridge confirmed a picture line on them
//  (φ 1106.96 s, from content 1164.88 s). Stage 2 took it as the line for the parked content 978.16 s, found that content "on the wire
//  already" 186.6 s ago, and moved the sound's clock 186.6 s forward. The pump filled the renderer up to the old position; the slip
//  correction at the real line then put the clock back, leaving the renderer holding 186 s of sound ahead of its clock, so it never
//  asked for more and SDI lost 65 s of sound until the next seek.
//
//  1. `startVerdict`: a start whose wire time is more than `maxLineDisagreement` from now, either way, is not this content's line:
//     refused, and Stage 2 waits for the next line (or its start timeout, which starts with the picture clock). Every legitimate late
//     start in the soaks since 0.9.3 was at most 378.9 ms, and every early one well under that.
//     `lineAgreesWithPicture`: a correction whose line puts the content on the wire more than `maxLineDisagreement` from the picture
//     clock is refused the same way. The SDI picture trails the picture clock by the wire's lag (about 0.1–0.5 s), never by seconds.
//  2. `needsReread`: any write that moves the sound's clock by more than `rereadJump` reads the sound again from the new time (the
//     re-read `daa09cb` uses for an automatic flush), so a renderer queue left ahead of the clock cannot stall the pump.
//

import Foundation

public enum CardClockStage2Guard {
    /// Seconds. A line that puts the content this far from where the transport says it is belongs to other content.
    public static let maxLineDisagreement = 1.0
    /// Seconds. A clock write moving the sound further than this re-reads the sound from the new time.
    public static let rereadJump = 1.0

    public enum StartVerdict: Sendable, Equatable {
        /// The content reaches the wire at `host`, in the future: start the clock then.
        case startAt(host: Double)
        /// The content was on the wire `late` seconds ago (under the bound): start now, that far on.
        case startLate(late: Double)
        /// More than `maxLineDisagreement` from now. `offset` = wire host − now (negative: late).
        case refuse(offset: Double)
    }

    /// The pending start's verdict. `wireHost`: when the line says the parked content is (or was) on the wire. `now`: host seconds.
    /// `startDelay`: how far ahead an immediate start is placed (the engine's 2 ms).
    public static func startVerdict(wireHost: Double, now: Double, startDelay: Double = 0.002) -> StartVerdict {
        let offset = wireHost - now
        if abs(offset) > maxLineDisagreement { return .refuse(offset: offset) }
        if wireHost > now + 0.001 { return .startAt(host: wireHost) }
        return .startLate(late: now + startDelay - wireHost)
    }

    /// A correction's line against the picture clock. `lineContent`: the content the line puts on the wire now, the device latency
    /// added (`w + K`). `pictureContent`: the picture clock now.
    public static func lineAgreesWithPicture(lineContent: Double, pictureContent: Double) -> Bool {
        lineContent.isFinite && pictureContent.isFinite && abs(lineContent - pictureContent) <= maxLineDisagreement
    }

    /// Whether moving the sound's clock from content `from` to content `to` must re-read the sound.
    public static func needsReread(from: Double, to: Double) -> Bool {
        from.isFinite && to.isFinite && abs(to - from) > rereadJump
    }
}
