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
//  ── WHY NOT WHILE THE CARD OWNS AUDIO ──────────────────────────────────────────────────
//
//  The DeckLink output encodes the frame the display tick picks, and its audio is read from the tap
//  at that frame's PTS, so SDI is in sync at any picture delay — only its latency changes. While
//  the card owns the programme audio the desktop renderer is muted, there is no desktop lip-sync to
//  protect, and holding the picture would only make SDI later. So the delay is zero then, and SDI is
//  exactly what it was before this fix. The cost, accepted 2026-09-28: switching DeckLink audio
//  ownership during a session moves the picture by the lead, once.
//

public enum PullSourcePictureDelay {

    /// Seconds the picture is held behind the pull clock. Equal to the desktop audio lead while the
    /// desktop renderer is the programme output, zero while the card owns audio.
    public static func seconds(desktopAudioLead: Double, cardOwnsAudio: Bool) -> Double {
        guard !cardOwnsAudio, desktopAudioLead.isFinite, desktopAudioLead > 0 else { return 0 }
        return desktopAudioLead
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
