//
//  RTPTimestampUnwrapper.swift
//  Manifold
//
//  32-bit RTP timestamp → monotonic CMTime on the sender's timeline.
//
//  ── WHY THIS IS NOT IN THE DECODER ─────────────────────────────────────────
//
//  Everything here is a property of the RTP FIELD, not of decoding: it is 32
//  bits wide, it starts at a random value (RFC 3550 §5.1 requires that), and it
//  wraps every ~13.25 hours at 90 kHz. A stream that arrives any other way has
//  none of those problems — libavformat hands the SRT path a 64-bit PTS it has
//  already unwrapped from MPEG-TS's 33-bit field — so a decoder shared by both
//  transports must not carry this. It belongs to the transport that has the
//  defect, which is WHEP.
//
//  ── THREADING, AND WHY THE OWNERSHIP CHANGED ───────────────────────────────
//
//  Stateful and NOT thread-safe: `unwrap` must be called once per access unit,
//  in arrival order, from one thread. The call site that satisfies all three is
//  WHEPClient's `onVideoAccessUnit` closure, which the bridge invokes on
//  `session.decodeQueue` — serial, one access unit at a time, in order.
//  Constructed on main in `connect()`, before the closure can run.
//
//  ONE INSTANCE PER CONNECTION, and that is the reset. This state used to live
//  in WHEPVideoDecoder, where `invalidate()` did NOT clear it — harmless only
//  because `connect()` always built a fresh decoder, i.e. the correctness came
//  from a lifetime accident somewhere else. Here the object's lifetime IS the
//  connection's, so there is no reset to forget.
//

import CoreMedia
import Foundation

final class RTPTimestampUnwrapper {

    /// H.264's RTP payload format fixes the clock at 90 kHz (RFC 6184 §8.2.1).
    /// This is a property of the RTP profile, not a value negotiated per stream.
    private static let clockRate: Int32 = 90_000

    private var previous: UInt32?
    private var unwrapped: Int64 = 0

    /// Decode-queue only. Monotonic across the wrap, and rebased so the first
    /// access unit of the connection is zero.
    ///
    /// THE REBASE IS COSMETIC, and deliberately kept on this side rather than
    /// pushed down into anything shared. LiveClock anchors on whatever the first
    /// senderPTS it sees happens to be (`registerFrame`, LiveClock.swift:409) —
    /// so an origin of zero versus a random 32-bit start buys log readability
    /// and nothing else. That makes it a per-transport presentation choice: the
    /// SRT path should keep libavformat's own timeline rather than copy this,
    /// because there the PTS values are meaningful in the stream's terms.
    func unwrap(_ rtpTimestamp: UInt32) -> CMTime {
        if let previous {
            // Signed 32-bit difference handles the wrap in both directions.
            unwrapped += Int64(Int32(bitPattern: rtpTimestamp &- previous))
        } else {
            unwrapped = 0
        }
        previous = rtpTimestamp
        return CMTime(value: unwrapped, timescale: Self.clockRate)
    }
}
