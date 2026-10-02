//
//  PairingCheckTests.swift — SyncCalibrationTests
//
//  `scripts/syncclips/pairing_check.py`'s four checks, ported, against the MEAN score that §19.9
//  (Decisions 5) made a requirement for stage D (docs/AUDIO_RESAMPLER_DESIGN.md §19.10):
//    1. 101 offsets across ±½ of the shortest interval;
//    2. a deliberate one-interval mispair: δ = ± each coded interval (8);
//    3. 399 offsets across the whole ±½ cycle;
//    4. the same again with ±10 ms of uniform jitter on every beep.
//
//  On each clip's exact timeline (k / rate; verify.py measured every bundled clip's events there to
//  ≤ 0.55 µs, §19.9), beeps shifted by δ, dropping any that leave the clip, as a capture would. The
//  wrong-pairing MARGIN (smallest score of any wrong candidate) is printed per rate, for both scores.
//

import XCTest
@testable import SyncCalibration

final class PairingCheckTests: XCTestCase {

    /// A small deterministic generator (pairing_check.py used random.Random(1); the jitter's exact
    /// draws do not matter, its bound does).
    private struct LCG {
        var state: UInt64
        mutating func uniform(_ a: Double, _ b: Double) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return a + (b - a) * Double(state >> 11) / Double(1 << 53)
        }
    }

    private struct Run {
        var n = 0, fails: [(Double, Double?)] = [], worst = 0.0, margin = Double.infinity
        var mis: [(delta: Double, coded: Double?, nearest: Double)] = []
    }

    private func run(_ clip: SyncClips.Clip, jitter: Double, score: CodedMatcher.Score) -> Run {
        let f = clip.eventTimes, b0 = clip.eventTimes
        let dur = Double(clip.frameCount) * clip.frameSeconds
        let C = clip.cycleSeconds, I = clip.shortestIntervalSeconds
        var rnd = LCG(state: 1)
        var r = Run()

        func one(_ delta: Double) -> CodedMatcher.Candidate? {
            let b = b0.map { $0 + delta + (jitter > 0 ? rnd.uniform(-jitter, jitter) : 0) }
                .filter { $0 >= 0 && $0 <= dur }
            r.n += 1
            guard let m = CodedMatcher.match(flashes: f, beeps: b, halfCycle: C / 2, minPairs: f.count / 2,
                                             score: score) else {
                r.fails.append((delta, nil)); return nil
            }
            let err = m.best.offset - delta
            r.worst = max(r.worst, abs(err))
            if let mg = m.margin { r.margin = min(r.margin, mg) }
            if abs(err) > max(1e-6, jitter) { r.fails.append((delta, err)) }
            return m.best
        }

        let steps = 50
        for k in -steps...steps { _ = one(Double(k) / Double(steps) * I / 2) }       // 1.
        let period = I / 23
        for s in SyncClips.codeSteps {                                                   // 2.
            for sign in [1.0, -1.0] {
                let delta = sign * Double(s) * period
                let got = one(delta)
                let b = b0.map { $0 + delta }.filter { $0 >= 0 && $0 <= dur }
                let nn = CodedMatcher.median(f.map { t in b.min { abs($0 - t) < abs($1 - t) }! - t })
                r.mis.append((delta, got?.offset, nn))
            }
        }
        for k in -199...199 { _ = one(Double(k) / 400 * C) }                             // 3.
        return r
    }

    func testTheFourChecksPassWithTheMeanScoreOnEveryClip() {
        var lines: [String] = []
        for clip in SyncClips.all {
            let plain = run(clip, jitter: 0, score: .mean)
            let jit = run(clip, jitter: 0.010, score: .mean)
            let medianScore = run(clip, jitter: 0, score: .median)
            XCTAssertEqual(plain.n, 508, clip.label)
            XCTAssertTrue(plain.fails.isEmpty, "\(clip.label): \(plain.fails)")
            XCTAssertTrue(jit.fails.isEmpty, "\(clip.label) jitter: \(jit.fails)")
            // 2: every one-interval mispair comes back as injected; nearest-neighbour gets each wrong.
            for m in plain.mis {
                XCTAssertEqual(m.coded ?? .nan, m.delta, accuracy: 1e-6, clip.label)
                XCTAssertGreaterThan(abs(m.nearest - m.delta), 0.1, clip.label)
            }
            // The mean score's margin is about four code steps; the median's is one at some rates.
            let step = clip.shortestIntervalSeconds / 23
            XCTAssertGreaterThan(plain.margin, 3 * step, clip.label)
            XCTAssertGreaterThan(jit.margin, 3 * step - 0.010, clip.label)
            XCTAssertGreaterThanOrEqual(plain.margin, medianScore.margin - 1e-9, clip.label)
            lines.append(String(format: "%@p: step %.1f ms · margin mean %.1f ms (%.2f steps), with ±10 ms "
                                + "jitter %.1f ms · median-score margin %.1f ms (%.2f steps) · worst error %.3f µs "
                                + "/ %.2f ms jittered · %d + %d offsets, 0 failures",
                                clip.label, step * 1e3, plain.margin * 1e3, plain.margin / step, jit.margin * 1e3,
                                medianScore.margin * 1e3, medianScore.margin / step, plain.worst * 1e6,
                                jit.worst * 1e3, plain.n, jit.n))
        }
        print("[PAIRING-CHECK]\n" + lines.joined(separator: "\n"))
    }
}
