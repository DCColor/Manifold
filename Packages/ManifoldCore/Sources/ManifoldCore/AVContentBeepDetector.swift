//
//  AVContentBeepDetector.swift
//  ManifoldCore
//
//  [AV-CONTENT] telemetry, pre-ship removal (docs/BUGS.md, "SRT via Cloudflare: absolute A/V").
//  READ-ONLY. Finds the onset of each flash-beep fixture beep (a 1 kHz burst once a second over
//  digital silence) in the audio a live sink handles, and logs it on that buffer's own PTS axis:
//  `in` is the transport's axis (what the tap gets), `out` the resampler's (what the renderer
//  plays). Paired offline with the renderer's `[AV-CONTENT] flash` lines, it measures the CONTENT
//  A/V on Manifold's own timestamps, which `[AV-LAG]` (timestamps only) cannot see.
//
//  Same compile and runtime gates as `LiveAudioRendererProbe`: constructed only when
//  `LiveClock.telemetryIsEnabled`, which only a DEBUG app sets.
#if DEBUG || MANIFOLD_TELEMETRY
import AVFoundation
import Foundation

public final class AVContentBeepDetector: @unchecked Sendable {
    private let tag: String
    /// Samples since the last one above `loud`, on channel 0. Counting from the last LOUD sample,
    /// not the last non-silent one: AAC pre-echo just before an onset sits between the two
    /// thresholds and would otherwise reset the count and hide the beep.
    private var sinceLoud = Int.max / 2
    private var bytes: [UInt8] = []

    /// A beep is ≥ −26 dBFS; the fixture's gaps are digital silence. An onset needs 0.3 s without
    /// a loud sample before it, so a burst's own zero crossings never re-trigger.
    private static let loud: Float = 0.05
    private static let quietBeforeOnset = 0.3

    public init(tag: String) { self.tag = tag }

    public func scan(_ sb: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        guard pts.isFinite else { return }
        let n = CMSampleBufferGetNumSamples(sb)
        let len = CMBlockBufferGetDataLength(block)
        if bytes.count < len { bytes = [UInt8](repeating: 0, count: len) }
        guard bytes.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len,
                                                                         destination: $0.baseAddress!) }) == noErr
        else { return }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let stride = interleaved ? Int(asbd.mChannelsPerFrame) : 1
        let sr = asbd.mSampleRate
        let need = Int(Self.quietBeforeOnset * sr)
        bytes.withUnsafeBytes { raw in
            for i in 0..<n {
                let k = i * stride
                let x: Float
                switch (isFloat, bits) {
                case (true, 32):  x = raw.load(fromByteOffset: k * 4, as: Float.self)
                case (false, 32): x = Float(raw.load(fromByteOffset: k * 4, as: Int32.self)) / 2_147_483_648
                case (false, 16): x = Float(raw.load(fromByteOffset: k * 2, as: Int16.self)) / 32_768
                default: return
                }
                if abs(x) > Self.loud {
                    if sinceLoud >= need {
                        FileHandle.standardError.write(Data(String(
                            format: "[AV-CONTENT] beep %@ pts=%.6f host=%.4f\n",
                            tag, pts + Double(i) / sr, CACurrentMediaTime()).utf8))
                    }
                    sinceLoud = 0
                } else {
                    sinceLoud += 1
                }
            }
        }
    }
}
#endif
