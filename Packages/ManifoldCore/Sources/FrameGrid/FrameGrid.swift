import CoreMedia

/// A constant-rate video track's frame times, exactly: frame n presents at `origin + n × frameDuration`, both in
/// the track's own rational time. What frame-stepping on the AVFoundation path steps on (docs/BUGS.md, "frame-
/// stepping on the AVFoundation file path lands one frame early").
///
/// ⚠️ WHY NOT `Double(n) / fps`. That is what stepping used, with `fps` = `nominalFrameRate`, a Float. At every
/// NTSC rate it lands just BEFORE frame n (23.976: 0.04170833220 s against 0.04170833333 s for frame 1), and the
/// reader start built from it, `CMTime(seconds:preferredTimescale: 600)`, rounds further — frame 1 became 25/600 s,
/// inside frame 0. A reader presents the frame whose interval holds its start, so → from frame 0 showed frame 0
/// again and every step showed n−1. Measured 2026-10-16 with a reader started exactly as the engine started it:
/// 23.976, 29.97 and 59.94 gave n−1 at n = 1, 2, 15, 29; 24 and 60 were exact (their 1/fps is a whole number of
/// 600ths). A `CMTime` built from the index cannot land anywhere but on the frame.
///
/// Built only for a CONSTANT-rate track (`init` returns nil otherwise, and the caller keeps its old arithmetic):
/// a variable-rate track has no single frame duration, and its frame n is not at `n × anything`.
public struct FrameGrid: Equatable, Sendable {
    /// Frame 0's presentation time (the track's time-range start).
    public let origin: CMTime
    /// One frame, exactly (the track's `minFrameDuration`, in its own timescale).
    public let frameDuration: CMTime
    /// How many frames the track holds: its duration over one frame, rounded.
    public let frameCount: Int

    /// How far the rate implied by `frameDuration` may sit from `nominalFrameRate` before the track is treated as
    /// variable-rate. Relative. `nominalFrameRate` is a Float average: on a constant-rate track it agrees with
    /// 1/minFrameDuration to its own precision (~1e-7); a variable-rate track's minimum duration is its FASTEST
    /// frame, which sits far from the average.
    public static let constantRateTolerance = 1e-4

    /// Nil when the facts do not describe a constant-rate track whose frames can be counted.
    public init?(origin: CMTime, frameDuration: CMTime, trackDuration: CMTime, nominalFrameRate: Float) {
        guard origin.isNumeric, frameDuration.isNumeric, trackDuration.isNumeric,
              frameDuration.value > 0, frameDuration.timescale > 0, nominalFrameRate > 0 else { return nil }
        let exactRate = Double(frameDuration.timescale) / Double(frameDuration.value)
        guard abs(exactRate - Double(nominalFrameRate)) / exactRate <= Self.constantRateTolerance else { return nil }
        let count = Int((trackDuration.seconds / frameDuration.seconds).rounded())
        guard count >= 1, count < Int(Int32.max) else { return nil }
        self.origin = origin
        self.frameDuration = frameDuration
        self.frameCount = count
    }

    /// The last frame's index. Stepping's ceiling.
    public var lastIndex: Int { frameCount - 1 }

    /// The exact rate (24000/1001 at 23.976), for display and conversions that need a number.
    public var rate: Double { Double(frameDuration.timescale) / Double(frameDuration.value) }

    /// Frame n's presentation time, exactly. `n` is clamped to the track.
    public func time(ofFrame n: Int) -> CMTime {
        let i = Int32(min(max(n, 0), lastIndex))
        return CMTimeAdd(origin, CMTimeMultiply(frameDuration, multiplier: i))
    }

    /// Frame n's presentation time in seconds — for the engine's `currentTime`, which is a Double.
    public func seconds(ofFrame n: Int) -> Double { time(ofFrame: n).seconds }

    /// The frame on screen at `seconds`: the one whose interval holds it, clamped to the track.
    ///
    /// FLOOR, with a millionth of a frame of slack: a frame's own time, carried as a Double, can come back a
    /// hair short of the exact rational (~1e-11 frame even 48 minutes in) and must still name that frame rather
    /// than the one before. No more slack than that: the old 600-timescale target for 23.976 frame 1 sat only
    /// 0.001 frame short, and it really did show frame 0. A time part-way through an interval (paused mid-frame
    /// by the clock) names the frame showing, not the next.
    public func frame(atSeconds seconds: Double) -> Int {
        let f = (seconds - origin.seconds) / frameDuration.seconds
        guard f.isFinite else { return 0 }
        return min(max(Int((f + 1e-6).rounded(.down)), 0), lastIndex)
    }

    /// The frame `frames` away from the one at `seconds`, clamped to 0…lastIndex.
    public func frame(steppingFrom seconds: Double, by frames: Int) -> Int {
        let (sum, overflow) = frame(atSeconds: seconds).addingReportingOverflow(frames)
        if overflow { return frames < 0 ? 0 : lastIndex }
        return min(max(sum, 0), lastIndex)
    }
}
