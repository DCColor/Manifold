//
//  LiveAudioResampleContentTimeTests.swift
//  LiveAudioResampleTests
//
//  Build step 4a of docs/AUDIO_RESAMPLER_DESIGN.md §7: `inputTime(atOutputTime:)`, the content time
//  §2.1 revised `actual` to.
//
//    1. IDENTITY AT RATIO 1.0, bit for bit, across everything step 3's axis does (primer, hole,
//       overlap, format reset, axis break). This is what carries step 3's PAIRED figures over.
//    2. EXACT INVERSION UNDER A RAMPED RATIO, against step 1's warp fixture: the resampler's own
//       phase trace says which input instant each output frame was reconstructed at, and the map
//       must name the same instant.
//    3. THE SAME, HEARD: a sine through the ramp, where the output sample at tick T must be the
//       input signal evaluated at `inputTime(T)`. This checks the map against the audio rather than
//       against bookkeeping that shares its arithmetic.
//

import XCTest
import CoreMedia
@testable import LiveAudioResample

final class LiveAudioResampleContentTimeTests: XCTestCase {

    typealias T = LiveAudioResampleStageTests

    func stage() -> LiveAudioResampleStage {
        LiveAudioResampleStage(tag: "[TEST-RESAMPLE]", reportsWindows: false, log: nil)
    }

    // MARK: - 1. Identity at ratio 1.0

    func testContentTimeIsExactlyTheOutputTimeAtUnity() {
        let f48 = T.makeFormat(rate: 48000, channels: 2)
        let f44 = T.makeFormat(rate: 44100, channels: 2)
        let s = stage()
        var outs: [T.Out] = []
        XCTAssertEqual(s.inputTime(atOutputTime: 12.345), 12.345, "no block yet: identity")

        var tick: Int64 = 96_000
        func feed(_ n: Int, _ f: CMAudioFormatDescription) {
            outs += s.process(T.makeInput(tick: tick, frames: n, format: f)).map(T.read); tick += Int64(n)
        }
        for _ in 0..<20 { feed(960, f48) }
        tick += 960                                           // hole
        for _ in 0..<10 { feed(960, f48) }
        tick -= 1200                                          // overlap
        for _ in 0..<10 { feed(517, f48) }
        tick += 3 * 48_000                                    // axis break
        for _ in 0..<10 { feed(960, f48) }
        let pad = 48_000 - tick % 48_000
        feed(Int(pad), f48)
        tick = tick / 48_000 * 44_100                         // format reset, contiguous in seconds
        for _ in 0..<20 { feed(1024, f44) }

        let t = s.totals
        // 1200 frames of overlap across 517-frame buffers: two dropped whole, the third trimmed.
        XCTAssertEqual(t.fills, 1); XCTAssertEqual(t.drops, 3); XCTAssertEqual(t.dropFrames, 1200)
        XCTAssertEqual(t.axisBreaks, 1); XCTAssertEqual(t.formatResets, 1)

        // Every output tick, a quarter-tick in, the span's edges, and instants off either end.
        var probes: [Double] = [0, -1, 1e6, 2.0, 1.99999]
        for o in outs {
            let base = Double(o.pts.value)
            for f in stride(from: 0, to: o.frames, by: 7) {
                probes.append((base + Double(f)) / o.rate)
                probes.append((base + Double(f) + 0.25) / o.rate)
            }
            probes.append(CMTimeGetSeconds(o.endTime))
        }
        var mismatches = 0
        for p in probes where s.inputTime(atOutputTime: p).bitPattern != p.bitPattern { mismatches += 1 }
        XCTAssertEqual(mismatches, 0, "at ratio 1.0 content time must BE the output time, bit for bit")
        XCTAssertTrue(s.inputTime(atOutputTime: .nan).isNaN)
        print("[4a] identity at 1.0: \(probes.count) instants across hole, overlap, break and reset, 0 mismatches")
    }

    /// Setting ρ to exactly 1.0 must change nothing the renderer receives.
    func testExplicitUnityRhoIsByteIdenticalToStepThree() {
        let fmt = T.makeFormat(rate: 48000, channels: 2)
        let a = stage(), b = stage()
        b.rho = 1.0
        var tick: Int64 = 0
        for _ in 0..<50 {
            let sb = T.makeInput(tick: tick, frames: 960, format: fmt)
            let oa = a.process(sb).map(T.read), ob = b.process(sb).map(T.read)
            XCTAssertEqual(oa.count, ob.count)
            for (x, y) in zip(oa, ob) {
                XCTAssertEqual(x.pts, y.pts); XCTAssertEqual(x.frames, y.frames); XCTAssertEqual(x.pcm, y.pcm)
            }
            tick += 960
        }
    }

    // MARK: - 2. Exact inversion under a ramped ratio (step 1's warp fixture)

    func testContentTimeInvertsARampedRatioExactly() {
        let fmt = T.makeFormat(rate: 48000, channels: 2)
        let s = stage()
        s.capturesPhaseForTesting = true
        var rng = SplitMix(seed: 0x4A)
        var outs: [T.Out] = []
        var tick: Int64 = 96_000
        let blocks = 200
        for b in 0..<blocks {
            // −2000 → +2000 ppm (±B) plus a random step within ±500 ppm, per block — the gate
            // test's shape, at the controller's authority.
            let ramp = -0.002 + 0.004 * Double(b) / Double(blocks - 1)
            s.rho = 1 + max(-0.002, min(0.002, ramp + rng.uniform(-0.0005, 0.0005)))
            if b == 120 { tick += 960 }                       // a lost packet mid-ramp
            outs += s.process(T.makeInput(tick: tick, frames: 960, format: fmt)).map(T.read)
            tick += 960
        }
        XCTAssertEqual(s.totals.fills, 1)
        let fixture = s.phaseTraceForTesting()!
        let frames = outs.reduce(0) { $0 + $1.frames }
        XCTAssertEqual(fixture.trace.count, frames + fixture.initialPrimer, "lengths first (§9.5)")

        func expected(_ outTick: Int64) -> Double {
            let e = Int(outTick - fixture.outAnchor) + fixture.initialPrimer
            return Double(fixture.inputOrigin) + Double(fixture.trace[e]) / 4294967296.0
                - 1 - Double(fixture.latency)
        }
        var worst = 0.0, worstMid = 0.0, checked = 0
        var drift = 0.0
        for o in outs {
            for f in 0..<o.frames {
                let k = o.pts.value + Int64(f)
                let got = s.inputTime(atOutputTime: Double(k) / 48000) * 48000
                worst = max(worst, abs(got - expected(k)))
                drift = max(drift, abs(expected(k) - Double(k)))
                // Half a tick in: the block's ratio is constant, so the map is linear inside it.
                if f + 1 < o.frames {
                    let mid = s.inputTime(atOutputTime: (Double(k) + 0.5) / 48000) * 48000
                    worstMid = max(worstMid, abs(mid - (expected(k) + expected(k + 1)) / 2))
                }
                checked += 1
            }
        }
        // Double's floor at ~1e5 ticks is ~1e-11 frames; the seconds round trip costs a little more.
        XCTAssertLessThan(worst, 1e-6, "on-tick: the map must name the phase the resampler used")
        XCTAssertLessThan(worstMid, 1e-6, "between ticks: linear within a block, exactly")
        XCTAssertGreaterThan(drift, 10, "the ramp must actually move content off the output axis")
        print(String(format: "[4a] ramped ρ ±2000 ppm, %d blocks, %d output ticks: |map − phase| ≤ %.2e "
                     + "frames on tick, %.2e mid-tick; content moved up to %.1f frames off the output axis",
                     blocks, checked, worst, worstMid, drift))
    }

    // MARK: - 3. The same, heard

    func testRampedOutputCarriesTheInputAtItsContentTime() {
        let fmt = T.makeFormat(rate: 48000, channels: 1)
        let s = stage()
        let f = 997.0, amp = 0.5
        func input(_ tick: Double) -> Double { amp * sin(2 * Double.pi * f * tick / 48000) }
        var outs: [T.Out] = []
        var tick: Int64 = 0
        let blocks = 300
        for b in 0..<blocks {
            s.rho = 1 + 0.002 * Double(b) / Double(blocks - 1)       // 0 → +2000 ppm
            var pcm = [Int32](repeating: 0, count: 960)
            for i in 0..<960 { pcm[i] = Int32(input(Double(tick) + Double(i)) * 2147483648.0) }
            let sb = LiveAudioResampleStage.makeSampleBuffer(pcm, frames: 960, channels: 1,
                                                             timescale: 48000, ptsTicks: tick, format: fmt)!
            outs += s.process(sb).map(T.read)
            tick += 960
        }
        var worst = 0.0, worstIdentity = 0.0, n = 0
        for o in outs {
            for i in 0..<o.frames {
                let k = o.pts.value + Int64(i)
                guard k >= 64 else { continue }                          // past the primer and filter settle
                let got = Double(o.pcm[i]) / 2147483648.0
                let content = s.inputTime(atOutputTime: Double(k) / 48000) * 48000
                worst = max(worst, abs(got - input(content)))
                worstIdentity = max(worstIdentity, abs(got - input(Double(k))))
                n += 1
            }
        }
        // The ASRC's own error at 1 kHz is ~−120 dB (§9.1); 1e-4 is −80 dB below this sine.
        XCTAssertLessThan(worst, 1e-4, "the output at T must be the input at inputTime(T)")
        XCTAssertGreaterThan(worstIdentity, 0.1, "and the identity map must be visibly wrong, or the test proves nothing")
        print(String(format: "[4a] heard: %d samples through a 0 → +2000 ppm ramp, |out − in(inputTime)| ≤ "
                     + "%.2e; against the identity map %.3f", n, worst, worstIdentity))
    }
}

/// Deterministic, so a failing run reproduces.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53)
    }
}
