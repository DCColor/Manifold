//
//  PullSourcePictureDelay.swift
//  DisplayProviders
//
//  How long a real-time PULL source (NDI) holds its picture, so that the desktop audio queue is
//  not a lip-sync offset. docs/AUDIO_RESAMPLER_DESIGN.md §2.5.
//
//  ── WHY THE PICTURE, AND NOT THE AUDIO AXIS ────────────────────────────────────────────
//
//  §2.5's rule is that the renderer's audio queue is obtained by starting the audio axis early,
//  never by holding the timebase late. On SRT and WHEP that is free: LiveClock holds the picture a
//  buffer depth behind the sender, so audio arrives ahead of its picture and the queue costs
//  nothing. NDI's FrameSync hands out the audio and the video for NOW. There is no future audio to
//  queue, so the only way the renderer can hold `lead` of audio is for the timebase to run `lead`
//  behind the pull clock — and the only way that is not an A/V offset is for the picture to run the
//  same `lead` behind it. Until 2026-09-28 it did not, and desktop audio played 250 ms after its
//  picture (+252…+262 ms at the device, 2026-09-28).
//
//  ── AND BY FRAMESYNC'S AUDIO QUEUE, ADDED THE SAME DAY ────────────────────────────────
//
//  The first build held the picture by the lead alone and measured +38.6 ms at the device with the
//  hold itself exact (250.2–262.4 ms pull → display, median 256). The remainder is FrameSync: it
//  returns the CURRENT video frame but the OLDEST queued audio, so every pulled sample is
//  `framesync_audio_queue_depth` older than its pull-time stamp — 28–47 ms, different per
//  connection. That is the NDI SDK's documented shape (a time-base-corrected audio queue), not a
//  property of any sender, so it is compensated here: the picture is held `lead + mean depth`.
//
//  ── ⚠️ AND SINCE 2026-10-05, BY THE SENDER'S TIMECODES WHEN IT SENDS THEM (§19.13) ──────────────
//
//  The depth OVERSTATES the term it stands for. On an SDK sender in sync by its own stamps it held
//  the picture ~27 ms too long at 23.976 (~14 ms at 59.94), confirmed at the device: the newest
//  audio chunk is counted as if it had already played out, and the picture's wait for the display
//  tick is invisible to it. Both depend on the sender, so no constant corrects them. The quantity
//  the hold needs is how much later Manifold stamps the audio than the picture of the same content
//  instant, and NDI states content time on every frame: its timecode. `PictureHoldBasisEstimate`
//  measures that skew and the hold uses it when both streams carry timecodes that keep time; when
//  either does not, the hold is `lead + mean depth` exactly as before.
//
//  ⚠️ THE DEPTH REACHES THE PICTURE, NEVER THE PULL OR THE AUDIO STAMPS. Sizing the pull from it was
//  a shipped defect (FrameSync synthesised ~82% of the audio, docs/BUGS.md #NDI-AUDIO), and it
//  sawtooths within a session as packets land, so stamping by it would break the sample-counted
//  axis. Only a slow mean (`AudioQueueDepthEstimate`) moves the picture, by sub-frame amounts.
//
//  ── WHY NOT WHILE THE CARD OWNS AUDIO ──────────────────────────────────────────────────
//
//  The DeckLink output encodes the frame the display tick picks, and its audio is read from the tap
//  at that frame's PTS, so SDI is in sync at any picture delay — only its latency changes. While
//  the card owns the programme audio the desktop renderer is muted, there is no desktop lip-sync to
//  protect, and holding the picture would only make SDI later. So the delay is zero then, and SDI is
//  exactly what it was before this fix. The cost, accepted 2026-09-28: switching DeckLink audio
//  ownership during a session moves the picture by the whole hold (lead + depth), once.
//

import Foundation   // exp

public enum PullSourcePictureDelay {

    /// Seconds the picture is held behind the pull clock: the desktop audio lead plus the hold term
    /// while the desktop renderer is the programme output, zero while the card owns audio. The term
    /// (`frameSyncAudioDepth`) is the sender's timecode skew or, without usable timecodes,
    /// FrameSync's mean audio queue depth (`PictureHoldBasisEstimate`). A non-finite or negative term
    /// counts as none.
    public static func seconds(desktopAudioLead: Double, frameSyncAudioDepth: Double = 0,
                               cardOwnsAudio: Bool) -> Double {
        guard !cardOwnsAudio, desktopAudioLead.isFinite, desktopAudioLead > 0 else { return 0 }
        let depth = frameSyncAudioDepth.isFinite ? max(0, frameSyncAudioDepth) : 0
        return desktopAudioLead + depth
    }

    /// The hold on the TIMECODE basis: lead + the sender's skew, which may be negative (its floor is
    /// `PictureHoldBasisEstimate.skewFloor`); never below zero. Zero while the card owns audio, as
    /// for the depth. A non-finite skew counts as none.
    public static func seconds(desktopAudioLead: Double, timecodeSkew: Double,
                               cardOwnsAudio: Bool) -> Double {
        guard !cardOwnsAudio, desktopAudioLead.isFinite, desktopAudioLead > 0 else { return 0 }
        let skew = timecodeSkew.isFinite ? timecodeSkew : 0
        return max(0, desktopAudioLead + skew)
    }

    /// The highest source rate the queue bound is sized for. A bound is a ceiling, not an
    /// allocation: memory is spent only on frames that actually arrive, so sizing for a fast sender
    /// costs a slow one nothing.
    public static let boundFrameRate = 120.0

    /// Frames of slack above the delay itself, for pull-tick jitter.
    public static let boundMargin = 4

    /// The renderer queue bound that holds `delay` seconds of pulled frames. Never below `floor`
    /// (the renderer's file-path default).
    ///
    /// ⚠️ TOO SMALL IS NOT A SOFT FAILURE. The renderer drops the OLDEST frame when full, and the
    /// oldest is the one due next, so an undersized queue silently takes the delay back — the
    /// picture runs ahead again by however much did not fit.
    public static func queueBound(delay: Double, floor: Int) -> Int {
        guard delay.isFinite, delay > 0 else { return floor }
        let frames = Int((delay * boundFrameRate).rounded(.up)) + boundMargin
        return max(floor, frames)
    }
}

/// The slow mean of FrameSync's audio queue depth that `PullSourcePictureDelay` adds to the picture
/// hold. Fed once per pull on the audio pump thread; owned by it.
///
/// A time-weighted mean over the first second, then an EMA (τ = 10 s). A value is PUBLISHED —
/// returned for the picture to move to — at the end of the first second, and after that only when
/// the mean has moved ≥ 2 ms from the last published value. Within a session the depth sawtooths
/// by ~40 ms as packets land; the mean of it is the average age of a pulled sample, and ten seconds
/// of it is steady to well under a millisecond, so the picture moves a handful of times a session
/// by sub-frame amounts.
public struct AudioQueueDepthEstimate {
    /// The EMA time constant.
    public static let tau = 10.0
    /// How far the mean must move from the published value before the picture follows.
    public static let hysteresis = 0.002
    /// How much pulling to average before the first publish.
    public static let warmup = 1.0
    /// Depth readings above this are clamped: 200 ms is 4× the largest seen (47 ms), and the SDK
    /// says to treat the reading "with some care".
    public static let ceiling = 0.200
    /// A pull interval longer than this is a stall, not a sample of steady state; skipped.
    public static let maxInterval = 1.0

    private var warmSum = 0.0
    private var warmTime = 0.0
    public private(set) var mean: Double?
    public private(set) var published: Double?

    public init() {}

    /// `depthSeconds` is `framesync_audio_queue_depth ÷ rate`, read before a pull; `interval` is the
    /// seconds since the previous pull. Returns the value to hold the picture by when it changes.
    public mutating func add(depthSeconds: Double, interval: Double) -> Double? {
        guard depthSeconds.isFinite, interval.isFinite, interval > 0, interval <= Self.maxInterval
        else { return nil }
        let d = min(max(depthSeconds, 0), Self.ceiling)
        guard let current = mean else {
            warmSum += d * interval
            warmTime += interval
            guard warmTime >= Self.warmup else { return nil }
            let m = warmSum / warmTime
            mean = m
            published = m
            return m
        }
        let alpha = 1 - exp(-interval / Self.tau)
        let m = current + alpha * (d - current)
        mean = m
        if let p = published, abs(m - p) < Self.hysteresis { return nil }
        published = m
        return m
    }
}

// MARK: - The hold by the sender's timecodes (docs/AUDIO_RESAMPLER_DESIGN.md §19.13)

/// One stream's timecode offset: the slow mean of `stamp − timecode`, the pull clock minus the
/// sender's own content clock, in seconds. Fed per pulled audio block (its first sample) or per new
/// video frame. The SAME warm-up and smoothing as `AudioQueueDepthEstimate`: a time-weighted mean
/// over the first second, then an EMA with τ 10 s; a reading after a gap longer than 1 s is skipped.
///
/// ⚠️ PLUS ONE RULE THE DEPTH DID NOT NEED: THE TIMECODE MUST KEEP TIME. A sender may send a constant
/// timecode (0 is legal and arrives as 0 on video, and as the block's offset inside its chunk on
/// FrameSync's audio), or restart it when a clip loops. Either way `stamp − timecode` walks away at
/// 1 s per second or jumps. A reading more than `maxDeviation` from the running mean restarts the
/// warm-up from that reading, so such a stream never holds a mean for long: it keeps restarting.
public struct TimecodeOffsetMean {
    public static let tau = AudioQueueDepthEstimate.tau
    public static let warmup = AudioQueueDepthEstimate.warmup
    public static let maxInterval = AudioQueueDepthEstimate.maxInterval
    /// Far above a live stream's own scatter (audio ±1 ms; video up to a display tick, ~17 ms, plus
    /// arrival jitter) and far below what a constant timecode reaches before its warm-up completes
    /// (it walks 1 s per second, so it trips this in 0.2–0.4 s).
    public static let maxDeviation = 0.200

    /// The offsets are large (mach seconds minus a sender clock that may be UTC), so they are held
    /// relative to the first reading of the current warm-up.
    private var base: Double?
    private var warmSum = 0.0
    private var warmTime = 0.0
    private var relMean: Double?
    /// Readings that restarted the warm-up, since this value was created.
    public private(set) var restarts = 0

    public init() {}

    /// The warmed mean, or nil while warming (or after a restart).
    public var mean: Double? { relMean.map { $0 + base! } }

    /// `offset` is `stamp − timecode / 10⁷`; `interval` the seconds since this stream's previous
    /// reading. Returns true when the reading was taken into a WARMED mean.
    @discardableResult
    public mutating func add(offset: Double, interval: Double) -> Bool {
        guard offset.isFinite else { return false }
        guard let b = base else { begin(offset); return false }
        let x = offset - b
        let reference = relMean ?? (warmTime > 0 ? warmSum / warmTime : 0)
        if abs(x - reference) > Self.maxDeviation {
            restarts += 1
            begin(offset)
            return false
        }
        guard interval.isFinite, interval > 0, interval <= Self.maxInterval else { return false }
        guard let current = relMean else {
            warmSum += x * interval
            warmTime += interval
            guard warmTime >= Self.warmup else { return false }
            relMean = warmSum / warmTime
            return true
        }
        relMean = current + (1 - exp(-interval / Self.tau)) * (x - current)
        return true
    }

    private mutating func begin(_ offset: Double) {
        base = offset; warmSum = 0; warmTime = 0; relMean = nil
    }
}

/// What the NDI picture is held by, beyond the lead: the TIMECODE SKEW when both streams carry
/// timecodes that keep time, FrameSync's mean audio depth otherwise (§19.13).
///
/// THE SKEW is `mean(audio stamp − timecode) − mean(video stamp − timecode)`: for one content instant
/// as the sender states it, how much later Manifold stamps its audio than its picture. That is
/// exactly what the hold must add. The sender's clock, and its offset from ours, cancel in the
/// difference. Measured on an SDK sender in sync by its own stamps, the depth overstated it by
/// ~27 ms at 23.976 (~14 ms at 59.94): depth counts the newest audio chunk as if it had played out,
/// and cannot see the picture's wait for the display tick (§19.13, device-confirmed).
///
/// THE FALLBACK IS PER STREAM AND AUTOMATIC. The skew is in use only while BOTH streams have fed a
/// warmed mean within `staleAfter`. Either stream undefined (`INT64_MAX`), constant, stopped, or
/// restarting faster than it can warm, and the hold returns to the depth term: today's behaviour,
/// unchanged. A brief re-warm (a looped clip restarting its timecode) keeps the last skew published.
/// The same `hysteresis` as the depth: the picture moves only when the skew moves ≥ 2 ms.
/// THE SKEW MAY BE NEGATIVE (Robbie, 2026-10-05): a sender that stamps its audio ahead of its video.
/// Inside `skewFloor…skewCeiling`, −100…+200 ms, it is used as is (the hold, lead + skew, stays well
/// positive).
///
/// ⚠️ OUTSIDE THOSE BOUNDS THE TWO STREAMS' TIMECODES ARE NOT ON ONE CLOCK, and the session falls
/// back to the depth for good (Robbie, 2026-10-05). Omniscope stamps one stream on a Unix-epoch clock
/// and the other near zero: each keeps time, the skew between them read −1.79 × 10⁹ s, and clamping
/// it held the picture by a number the sender never stated (+94…+138 ms heard, §19.13). A relation
/// the sender does not state cannot be followed, so it is not: `notOnOneClock` latches and
/// `rawSkew` keeps the value that showed it. The depth fallback keeps its own 0…200 ms.
public struct PictureHoldBasisEstimate {
    public enum Basis: String { case depth, timecode }

    public static let skewFloor = -0.100
    public static let skewCeiling = AudioQueueDepthEstimate.ceiling

    public static let staleAfter = 2.0
    public static let hysteresis = AudioQueueDepthEstimate.hysteresis
    /// `NDIlib_recv_timestamp_undefined`: the receive side's "no timecode".
    public static let undefinedTimecode = Int64.max

    public private(set) var audio = TimecodeOffsetMean()
    public private(set) var video = TimecodeOffsetMean()
    private var lastAudio = Double.nan, lastVideo = Double.nan
    private var lastAudioWarm = -Double.infinity, lastVideoWarm = -Double.infinity
    public private(set) var basis: Basis = .depth
    /// The skew the hold uses while `basis == .timecode`; nil otherwise.
    public private(set) var skew: Double?
    /// The skew as last measured (nil before both streams warm, or after a stale fallback). On the
    /// TIMECODE basis it is the value behind `skew`; once `notOnOneClock`, the value that showed it.
    public private(set) var rawSkew: Double?
    /// Latched for the session: the streams' skew fell outside −100…+200 ms, so their timecodes are
    /// not on one clock and the hold stays on the depth.
    public private(set) var notOnOneClock = false

    public init() {}

    /// Feed one pulled audio block (stamp of its first sample, that sample's timecode). Returns true
    /// when the basis or the published skew changed.
    @discardableResult
    public mutating func addAudio(stamp: Double, timecode: Int64, now: Double) -> Bool {
        if Self.isDefined(timecode) {
            let dt = lastAudio.isFinite ? now - lastAudio : 0
            if audio.add(offset: stamp - Double(timecode) / 1e7, interval: dt) { lastAudioWarm = now }
            lastAudio = now
        }
        return update(now: now)
    }

    /// Feed one new video frame (its stamp and timecode).
    @discardableResult
    public mutating func addVideo(stamp: Double, timecode: Int64, now: Double) -> Bool {
        if Self.isDefined(timecode) {
            let dt = lastVideo.isFinite ? now - lastVideo : 0
            if video.add(offset: stamp - Double(timecode) / 1e7, interval: dt) { lastVideoWarm = now }
            lastVideo = now
        }
        return update(now: now)
    }

    public static func isDefined(_ timecode: Int64) -> Bool { timecode != undefinedTimecode }

    private mutating func update(now: Double) -> Bool {
        if notOnOneClock { return false }
        let fresh = now - lastAudioWarm <= Self.staleAfter && now - lastVideoWarm <= Self.staleAfter
        if !fresh {
            guard basis == .timecode else { return false }
            basis = .depth; skew = nil; rawSkew = nil
            return true
        }
        guard let a = audio.mean, let v = video.mean else { return false }   // re-warming: hold the last
        let raw = a - v
        rawSkew = raw
        guard raw >= Self.skewFloor, raw <= Self.skewCeiling else {
            notOnOneClock = true
            basis = .depth; skew = nil
            return true
        }
        if basis == .timecode, let current = skew, abs(raw - current) < Self.hysteresis { return false }
        basis = .timecode; skew = raw
        return true
    }
}
