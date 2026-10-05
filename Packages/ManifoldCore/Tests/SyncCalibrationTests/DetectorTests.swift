//
//  DetectorTests.swift — SyncCalibrationTests
//
//  The tone-onset detector on clip audio synthesised exactly as generate.sh's `aevalsrc` writes it
//  (the tone anchored to k / rate, sampled, 5 ms raised-cosine edges, −20 dBFS, a −60 dBFS RMS
//  noise floor), fed in uneven buffers. Every event, at every rate, at three levels. The truth check
//  against the bundled clips themselves (decoded) is offline: §19.10 (the old MP4s), §19.11 (H.264 + PCM).
//

import XCTest
@testable import SyncCalibration

final class DetectorTests: XCTestCase {

    /// The first `seconds` of a clip's audio, interleaved stereo, at 48 kHz, scaled by `gain`.
    private func clipAudio(_ clip: SyncClips.Clip, seconds: Double, gain: Double, seed: UInt64) -> [Float] {
        let sr = 48_000.0, n = Int(seconds * sr)
        let events = Set(clip.eventFrames)
        let F = clip.rate
        var state = seed
        func noise() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return 0.0017320508 * (2 * Double(state >> 11) / Double(1 << 53) - 1)
        }
        var out = [Float](repeating: 0, count: 2 * n)
        for i in 0..<n {
            let t = Double(i) / sr
            let k = Int((t * F + 1e-6).rounded(.down))
            let dt = t - Double(k) / F
            var tone = 0.0
            if events.contains(k) {
                let T = 1 / F
                let env = dt < 0.005 ? 0.5 - 0.5 * cos(.pi * dt / 0.005)
                    : dt > T - 0.005 ? 0.5 - 0.5 * cos(.pi * (T - dt) / 0.005) : 1
                tone = 0.1 * env * sin(2 * .pi * 1000 * dt)
            }
            out[2 * i] = Float(gain * (tone + noise()))
            out[2 * i + 1] = Float(gain * (tone + noise()))
        }
        return out
    }

    func testOnsetsAtEveryRateAndLevelInUnevenBuffers() {
        var lines: [String] = []
        for clip in SyncClips.all {
            for gainDB in [-12.0, 0.0, 6.0] {
                let gain = pow(10, gainDB / 20)
                let audio = clipAudio(clip, seconds: 12, gain: gain, seed: 7)
                let det = ToneOnsetDetector()
                var found: [ToneOnset] = []
                let sizes = [1024, 960, 313, 2048, 1]
                var pos = 0, k = 0
                // A pts axis that does not start at zero, as a transport's does not.
                let base = 1234.5
                audio.withUnsafeBufferPointer { all in
                    while pos < audio.count / 2 {
                        let m = min(sizes[k % sizes.count], audio.count / 2 - pos)
                        k += 1
                        let slice = UnsafeBufferPointer(rebasing: all[(2 * pos)..<(2 * (pos + m))])
                        found += det.process(slice, frames: m, channels: 2, sampleRate: 48_000,
                                             firstSampleTime: base + Double(pos) / 48_000)
                        pos += m
                    }
                }
                let truth = clip.eventTimes.filter { $0 < 11.9 }.map { $0 + base }
                XCTAssertEqual(found.count, truth.count, "\(clip.label) \(gainDB) dB")
                var worst = 0.0
                for (a, b) in zip(found, truth) { worst = max(worst, abs(a.time - b)) }
                XCTAssertLessThan(worst, 50e-6, "\(clip.label) \(gainDB) dB")
                for o in found {
                    XCTAssertEqual(o.widthSeconds, clip.frameSeconds - 0.005, accuracy: 0.0002)
                    XCTAssertEqual(o.peak, 0.1 * gain, accuracy: 0.01 * gain)
                }
                if gainDB == 0 {
                    lines.append(String(format: "%@p: %d tones, worst onset error %.2f µs", clip.label,
                                        found.count, worst * 1e6))
                }
            }
        }
        print("[TONE-ONSET synthetic]\n" + lines.joined(separator: "\n"))
    }

    func testNoiseFloorAloneFindsNothing() {
        let det = ToneOnsetDetector()
        var state: UInt64 = 3
        let n = 48_000 * 5
        var x = [Float](repeating: 0, count: 2 * n)
        for i in 0..<(2 * n) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            x[i] = Float(0.0017320508 * (2 * Double(state >> 11) / Double(1 << 53) - 1))
        }
        let found = x.withUnsafeBufferPointer {
            det.process($0, frames: n, channels: 2, sampleRate: 48_000, firstSampleTime: 0)
        }
        XCTAssertTrue(found.isEmpty)
    }

    func testFlashEdgeOnlyOnTheFirstNewFlashFrame() {
        let d = FlashDetector()
        XCTAssertFalse(d.observe(pts: 0.0, meanLuma: 0.07))
        XCTAssertTrue(d.isNew(pts: 0.04))
        XCTAssertTrue(d.observe(pts: 0.04, meanLuma: 0.92))
        XCTAssertFalse(d.isNew(pts: 0.04))              // the same frame on a later tick
        XCTAssertFalse(d.observe(pts: 0.08, meanLuma: 0.92))   // a second white frame: not a new flash
        XCTAssertFalse(d.observe(pts: 0.12, meanLuma: 0.07))
        XCTAssertTrue(d.observe(pts: 0.16, meanLuma: 0.92))
    }

    func testTheClipCatalogueMatchesTheGeneratedSet() {
        // The bundled clips (§19.11): four whole code cycles, 16 events each, whole frames and whole
        // 48 kHz samples at every rate.
        XCTAssertEqual(SyncClips.all.map { $0.eventFrames.count }, [16, 16, 16, 16, 16, 16, 16])
        XCTAssertEqual(SyncClips.all.map(\.frameCount), [480, 480, 480, 480, 480, 960, 960])
        for c in SyncClips.all {
            let samples = Double(c.frameCount) * 48000 * Double(c.den) / Double(c.num)
            XCTAssertEqual(samples, samples.rounded(), "\(c.label): \(samples) samples")
            // The code runs on across the seam: the last event is one closing interval (37 steps)
            // before the clip's end + its first event.
            XCTAssertEqual(c.frameCount + c.firstEventFrame - c.eventFrames.last!, 37 * c.unit, c.label)
        }
        XCTAssertEqual(SyncClips.halfCycleLimitSeconds, 2.0, accuracy: 1e-9)
        // Nearest supported rate, and whether it is the stream's own.
        XCTAssertEqual(SyncClips.clip(forRate: 24000.0 / 1001)?.clip.label, "23.976")
        XCTAssertEqual(SyncClips.clip(forRate: 90000.0 / 3754)?.exact, true)      // a 90 kHz pts median
        XCTAssertEqual(SyncClips.clip(forRate: 90000.0 / 1501)?.clip.label, "59.94")
        XCTAssertEqual(SyncClips.clip(forRate: 90000.0 / 1501)?.exact, true)
        XCTAssertEqual(SyncClips.clip(forRate: 60)?.clip.label, "59.94")
        XCTAssertEqual(SyncClips.clip(forRate: 60)?.exact, false)
        XCTAssertEqual(SyncClips.clip(forRate: 48)?.clip.label, "50")
        XCTAssertEqual(SyncClips.clip(forRate: 48)?.exact, false)
        XCTAssertEqual(SyncClips.clip(forRate: 24)?.clip.label, "24")
        XCTAssertNil(SyncClips.clip(forRate: 0))
    }
}
