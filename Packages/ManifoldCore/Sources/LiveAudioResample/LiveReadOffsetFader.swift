//
//  LiveReadOffsetFader.swift
//  LiveAudioResample
//
//  The per-source audio offset O on the SDI read (docs/AUDIO_RESAMPLER_DESIGN.md §19.1, stage A).
//  DeckLink reads the tap by the staged video frame's source PTS (`AudioTapBuffer.read(framesStartingAt:)`),
//  so the same O is applied there as `startTime − O` (O > 0 = heard later), and SDI and the desktop
//  move together. A change crossfades from the old read position to the new, equal power, over the
//  stage's splice fade (10 ms), instead of a hard cut on the wire.
//
//  Here rather than in ManifoldCore so it can be tested: a test bundle cannot link ManifoldCore
//  (libav), and this needs nothing but the read it wraps. `AudioTapBuffer` owns one, under its lock;
//  FrameEngine sets it while a live session is open and clears it when the session ends, because the
//  card's read closure is shared with file playback.
//

import Foundation

public struct LiveReadOffsetFader: Sendable {
    /// The crossfade a change takes on SDI: the stage's own splice fade.
    public static let fadeSeconds = LiveAudioResampleStage.crossfadeSeconds

    /// O now, seconds.
    public private(set) var offset = 0.0
    /// (old offset, fade frames already served); nil = no fade in progress.
    private var fade: (from: Double, done: Int)?
    private var scratch: [Int32] = []

    public init() {}

    /// No offset and no fade: `read` is exactly the wrapped read.
    public var isIdentity: Bool { offset == 0 && fade == nil }

    /// A change starts a fade from the current offset. A change during a fade starts a new one from
    /// the old offset; the rest of the first is not finished.
    public mutating func set(_ seconds: Double) {
        guard seconds.isFinite, seconds != offset else { return }
        fade = (offset, 0)
        offset = seconds
    }

    /// The session ended: back to the wrapped read at once.
    public mutating func clear() { offset = 0; fade = nil }

    /// Read `frameCount` interleaved frames of `channels` for source time `startTime`, through `base`
    /// (the tap's own read: start, count, destination → frames copied).
    public mutating func read(startTime: Double, frameCount: Int, channels: Int, sampleRate: Double,
                              into dst: UnsafeMutablePointer<Int32>,
                              base: (Double, Int, UnsafeMutablePointer<Int32>) -> Int) -> Int {
        guard !isIdentity else { return base(startTime, frameCount, dst) }
        let copied = base(startTime - offset, frameCount, dst)
        guard let f = fade, channels > 0, sampleRate > 0, frameCount > 0 else { return copied }
        let n = max(2, Int((Self.fadeSeconds * sampleRate).rounded()))
        let span = min(frameCount, n - f.done)
        if scratch.count < span * channels { scratch = [Int32](repeating: 0, count: span * channels) }
        let old = scratch.withUnsafeMutableBufferPointer { base(startTime - f.from, span, $0.baseAddress!) }
        for i in 0..<span {
            let theta = Double.pi / 2 * (Double(f.done + i) + 0.5) / Double(n)
            let gOld = cos(theta), gNew = sin(theta)
            for c in 0..<channels {
                let k = i * channels + c
                let a = i < old ? Double(scratch[k]) : 0
                let b = i < copied ? Double(dst[k]) : 0
                dst[k] = Int32(clamping: Int64((a * gOld + b * gNew).rounded()))
            }
        }
        fade = f.done + span >= n ? nil : (f.from, f.done + span)
        // The fade's frames are served even where only the old side existed.
        return max(copied, min(old, span))
    }
}
