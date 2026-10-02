//
//  AVContentBeepDetector.swift
//  ManifoldCore
//
//  READ-ONLY. Finds beeps in the audio a live sink handles, on that buffer's own PTS axis. Two users:
//
//    * CALIBRATION MODE (docs/AUDIO_RESAMPLER_DESIGN.md §19.2, §19.10) — SHIPS, in every
//      configuration, but exists only while calibration is on: `CalibrationBeepTap` constructs it at
//      start and drops it at stop, so with calibration off there is no detector, no buffer and no
//      timer. It finds each sync-clip tone's START (`SyncCalibration.ToneOnsetDetector`: the
//      half-amplitude point of the 1 kHz envelope, less half the 5 ms edge) on the transport's axis
//      (`in`: content time) and hands it to its owner.
//    * The `[AV-CONTENT] beep` PROBE — DEBUG, pre-ship removal (docs/BUGS.md, "SRT via Cloudflare:
//      absolute A/V"). Constructed only when `LiveClock.telemetryIsEnabled`, which only a DEBUG app
//      sets. It prints the first sample above 0.05 after 0.3 s of quiet, exactly as before, so its
//      figures stay comparable with every `[AV-CONTENT]` reading in §18 (avcontent.py pairs them with
//      the renderer's `[AV-CONTENT] flash` lines).
//
//  Every scan counts in `SyncCalibrationCounters` — the evidence for "off = zero work" — the probe's
//  apart from calibration's.
import AVFoundation
import Foundation
import SyncCalibration

public final class AVContentBeepDetector: @unchecked Sendable {
    private enum Mode {
        case probe(tag: String)
        case calibration(ToneOnsetDetector, (ToneOnset) -> Void)
    }
    private let mode: Mode
    /// Probe: samples since the last one above `loud`, on channel 0. Counting from the last LOUD
    /// sample, not the last non-silent one: AAC pre-echo just before an onset sits between the two
    /// thresholds and would otherwise reset the count and hide the beep.
    private var sinceLoud = Int.max / 2
    private var bytes: [UInt8] = []
    private var floats: [Float] = []

    /// Probe: a beep is ≥ −26 dBFS; the fixture's gaps are digital silence. An onset needs 0.3 s
    /// without a loud sample before it, so a burst's own zero crossings never re-trigger.
    private static let loud: Float = 0.05
    private static let quietBeforeOnset = 0.3

    #if DEBUG || MANIFOLD_TELEMETRY
    /// The `[AV-CONTENT] beep <tag>` probe (pre-ship removal).
    public init(tag: String) { mode = .probe(tag: tag) }
    #endif

    /// Calibration mode: each tone's start, on the scanned buffers' axis. `onTone` is called on the
    /// scanning (transport) thread.
    public init(onTone: @escaping (ToneOnset) -> Void) {
        mode = .calibration(ToneOnsetDetector(), onTone)
    }

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
        let channels = Int(asbd.mChannelsPerFrame)
        let sr = asbd.mSampleRate
        func sample(_ raw: UnsafeRawBufferPointer, _ k: Int) -> Float? {
            switch (isFloat, bits) {
            case (true, 32):  return raw.load(fromByteOffset: k * 4, as: Float.self)
            case (false, 32): return Float(raw.load(fromByteOffset: k * 4, as: Int32.self)) / 2_147_483_648
            case (false, 16): return Float(raw.load(fromByteOffset: k * 2, as: Int16.self)) / 32_768
            default: return nil
            }
        }
        switch mode {
        case let .calibration(detector, onTone):
            // Interleaved Float for the detector, whatever the transport handed in.
            let used = min(channels, 2)
            guard len >= n * channels * (bits / 8) else { return }
            if floats.count < n * used { floats = [Float](repeating: 0, count: n * used) }
            var ok = true
            bytes.withUnsafeBytes { raw in
                for i in 0..<n { for c in 0..<used {
                    let k = interleaved ? i * channels + c : c * n + i
                    guard let x = sample(raw, k) else { ok = false; return }
                    floats[i * used + c] = x
                } }
            }
            guard ok else { return }
            let tones = floats.withUnsafeBufferPointer {
                detector.process(UnsafeBufferPointer(rebasing: $0[0..<(n * used)]), frames: n, channels: used,
                                 sampleRate: sr, firstSampleTime: pts)
            }
            SyncCalibrationCounters.countAudioBuffer(tones: tones.count)
            for t in tones { onTone(t) }
        case let .probe(tag):
            SyncCalibrationCounters.countDebugProbeBuffer()
            let stride = interleaved ? channels : 1
            let need = Int(Self.quietBeforeOnset * sr)
            bytes.withUnsafeBytes { raw in
                for i in 0..<n {
                    guard let x = sample(raw, i * stride) else { return }
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
}

/// Calibration mode's slot on the live sink (§19.10). Owned by `FrameEngine`, handed to every live
/// sink it opens. EMPTY unless calibration is on: then each enqueued buffer costs one lock and a nil
/// test, and no detector, buffer or timer exists. `start` puts a detector in; `stop` takes it out.
public final class CalibrationBeepTap: @unchecked Sendable {
    private let lock = UnfairLock()
    private var detector: AVContentBeepDetector?

    public init() {}

    public var isOn: Bool { lock.lock(); defer { lock.unlock() }; return detector != nil }

    /// `onTone` runs on the transport's enqueue thread.
    public func start(onTone: @escaping (ToneOnset) -> Void) {
        let d = AVContentBeepDetector(onTone: onTone)
        lock.lock(); detector = d; lock.unlock()
    }

    public func stop() { lock.lock(); detector = nil; lock.unlock() }

    func scan(_ sb: CMSampleBuffer) {
        lock.lock(); let d = detector; lock.unlock()
        d?.scan(sb)
    }
}
