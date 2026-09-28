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

    /// Seconds the picture is held behind the pull clock: the desktop audio lead plus FrameSync's
    /// mean audio queue depth while the desktop renderer is the programme output, zero while the
    /// card owns audio. A non-finite or negative depth counts as none.
    public static func seconds(desktopAudioLead: Double, frameSyncAudioDepth: Double = 0,
                               cardOwnsAudio: Bool) -> Double {
        guard !cardOwnsAudio, desktopAudioLead.isFinite, desktopAudioLead > 0 else { return 0 }
        let depth = frameSyncAudioDepth.isFinite ? max(0, frameSyncAudioDepth) : 0
        return desktopAudioLead + depth
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
