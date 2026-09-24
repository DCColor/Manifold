//
//  PolyphaseResamplerTests.swift
//  AudioResampleTests
//
//  Build step 1 of docs/AUDIO_RESAMPLER_DESIGN.md §7. Offline, against synthesised material,
//  before anything is wired into a live path.
//
//  Every test PRINTS its measurement next to its target. A pass/fail assertion alone would say
//  nothing about margin, and margin is what decides whether the structure survives step 3.
//

import XCTest
import Foundation
@testable import AudioResample

final class PolyphaseResamplerTests: XCTestCase {

    // MARK: - Helpers

    static let fs = 48000.0

    /// Run a whole input through in one call — scratch is then `taps` zeros ++ input, so absolute
    /// phases index it directly and the reference needs no bookkeeping of its own.
    func runWhole(_ input: [[Float]], ratio: Double,
                  prototype: PolyphasePrototype = PolyphasePrototype(),
                  capturePhase: Bool = false) -> (out: [[Float]], phases: [UInt64], r: PolyphaseResampler) {
        let r = PolyphaseResampler(channels: input.count, ratio: ratio, prototype: prototype)
        r.capturesPhase = capturePhase
        var out = [[Float]](repeating: [Float](repeating: 0, count: r.maximumOutputFrames(for: input[0].count)),
                            count: input.count)
        let n = r.process(input: input, output: &out)
        for c in 0..<out.count { out[c] = Array(out[c][0..<n]) }
        return (out, r.phaseTrace, r)
    }

    func rms(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
    }

    func db(_ x: Double) -> Double { x <= 0 ? -.infinity : 20 * log10(x) }

    /// Least-squares amplitude of a sinusoid at normalised frequency `f` (cycles/sample), and the
    /// residual left after removing it. Exact for any f; no windowing, no bin snapping.
    func fitTone(_ x: [Double], frequency f: Double) -> (amplitude: Double, residual: [Double]) {
        var sr = 0.0, sc = 0.0, ss = 0.0, cc = 0.0, scc = 0.0
        for (n, v) in x.enumerated() {
            let p = 2 * Double.pi * f * Double(n)
            let s = sin(p), c = cos(p)
            sr += v * s; sc += v * c; ss += s * s; cc += c * c; scc += s * c
        }
        let det = ss * cc - scc * scc
        let a = (sr * cc - sc * scc) / det
        let b = (sc * ss - sr * scc) / det
        var res = [Double](repeating: 0, count: x.count)
        for (n, v) in x.enumerated() {
            let p = 2 * Double.pi * f * Double(n)
            res[n] = v - (a * sin(p) + b * cos(p))
        }
        return ((a * a + b * b).squareRoot(), res)
    }

    /// The SAME polyphase table and the SAME branch/µ arithmetic, accumulated in Double.
    ///
    /// This is what separates the two floors the gate has to tell apart. Differencing it against
    /// the direct-sinc reference leaves ONLY the branch quantisation and the linear inter-branch
    /// interpolation; differencing the Float path against it leaves only the arithmetic. Without
    /// this, "the residual is at the arithmetic floor" is an assertion rather than a measurement.
    func polyphaseInDouble(scratch: [Float], phases: [UInt64], prototype p: PolyphasePrototype) -> [Double] {
        var out = [Double](repeating: 0, count: phases.count)
        let taps = p.taps
        var shift: UInt64 = 32
        var b = p.branches
        while b > 1 { b >>= 1; shift -= 1 }
        for (n, ph) in phases.enumerated() {
            let idx = Int(ph >> 32)
            let frac = UInt64(UInt32(truncatingIfNeeded: ph))
            let branch = Int(frac >> shift)
            let mu = Double(frac & ((1 << shift) - 1)) / Double(1 << shift)
            var acc = 0.0
            for j in 0..<taps {
                let h = Double(p.table[branch * taps + j]) + mu * Double(p.delta[branch * taps + j])
                acc += h * Double(scratch[idx + j])
            }
            out[n] = acc
        }
        return out
    }

    // MARK: - 1. Identity at ratio 1.0

    func test1_identityAtUnityRatio() {
        let n = 8192
        var rng = SystemRandomNumberGenerator()
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = Float.random(in: -0.9...0.9, using: &rng) }

        let proto = PolyphasePrototype()          // cutoff 0.5
        let (out, _, r) = runWhole([x], ratio: 1.0, prototype: proto)
        let delay = r.latencyFrames

        var worst = 0.0
        var compared = 0
        for i in 0..<(out[0].count) where i - delay >= 0 && i - delay < n {
            worst = max(worst, abs(Double(out[0][i]) - Double(x[i - delay])))
            compared += 1
        }
        print(String(format: "[1] identity @ ratio 1.0, cutoff 0.50: delay = %d frames (target %d), "
                   + "max |out[n] - in[n-%d]| = %.3e over %d frames (Float eps = %.3e)",
                     delay, proto.taps / 2, delay, worst, compared, Double(Float.ulpOfOne)))

        // The same measurement at the design document's stated cutoff, which is NOT a pass/fail
        // here — it is the evidence for the note in PolyphasePrototype.init.
        let proto45 = PolyphasePrototype(cutoff: 0.45)
        let (out45, _, r45) = runWhole([x], ratio: 1.0, prototype: proto45)
        var worst45 = 0.0
        for i in 0..<(out45[0].count) where i - r45.latencyFrames >= 0 && i - r45.latencyFrames < n {
            worst45 = max(worst45, abs(Double(out45[0][i]) - Double(x[i - r45.latencyFrames])))
        }
        print(String(format: "[1] identity @ ratio 1.0, cutoff 0.45 (design doc's value): max error = %.3e "
                   + "— branch 0 is a lowpass, not an impulse", worst45))

        // Streaming must equal one-shot: the tail bookkeeping is where an off-by-one would live.
        let rStream = PolyphaseResampler(channels: 1, ratio: 1.0, prototype: proto)
        var streamed = [Float]()
        var block = 0
        while block < n {
            let size = min(777, n - block)          // deliberately not a divisor of anything
            let chunk = [Array(x[block..<(block + size)])]
            var o = [[Float]](repeating: [Float](repeating: 0, count: rStream.maximumOutputFrames(for: size)), count: 1)
            let produced = rStream.process(input: chunk, output: &o)
            streamed.append(contentsOf: o[0][0..<produced])
            block += size
        }
        var streamWorst = 0.0
        for i in 0..<min(streamed.count, out[0].count) {
            streamWorst = max(streamWorst, abs(Double(streamed[i]) - Double(out[0][i])))
        }
        print(String(format: "[1] streaming (777-frame blocks) vs one-shot: %d vs %d frames, max diff = %.3e",
                     streamed.count, out[0].count, streamWorst))

        XCTAssertEqual(delay, proto.taps / 2)
        XCTAssertLessThan(worst, 1e-6)
        XCTAssertEqual(streamed.count, out[0].count)
        XCTAssertEqual(streamWorst, 0.0)
    }

    // MARK: - 2. Passband ripple to 20 kHz

    func measureGain(frequency hz: Double, ratio: Double, prototype: PolyphasePrototype)
        -> (gainDB: Double, spurDB: Double) {
        let n = 1 << 16
        let fin = hz / Self.fs
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = Float(0.5 * sin(2 * Double.pi * fin * Double(i))) }
        let (out, _, _) = runWhole([x], ratio: ratio, prototype: prototype)
        // Discard filter edges at both ends.
        let guardFrames = 512
        let y = out[0][guardFrames..<(out[0].count - guardFrames)].map { Double($0) }
        let fout = fin / ratio
        let (amp, res) = fitTone(y, frequency: fout)
        return (db(amp / 0.5), db(rms(res) / (amp / 2.0.squareRoot())))
    }

    func test2_passbandRipple() {
        let freqs = [20.0, 100, 1000, 5000, 10000, 15000, 18000, 19000, 20000]
        for (label, proto) in [("0.50 (default)", PolyphasePrototype()),
                               ("0.45 (design doc)", PolyphasePrototype(cutoff: 0.45))] {
            var worst = 0.0
            var line = ""
            for f in freqs {
                let g = measureGain(frequency: f, ratio: 1.001, prototype: proto).gainDB
                worst = max(worst, abs(g))
                line += String(format: " %gk:%+.4f", f / 1000, g)
            }
            print(String(format: "[2] passband ripple @ cutoff %@, ratio 1.001 — worst |gain| = %.4f dB "
                       + "(target <= 0.0200 dB).%@", label, worst, line))
            if proto.cutoff == 0.5 { XCTAssertLessThan(worst, 0.02) }
        }
    }

    // MARK: - 3. Alias / image rejection

    func test3_aliasRejection() {
        let freqs = [1000.0, 5000, 10000, 15000, 18000, 20000]
        let proto = PolyphasePrototype()
        var worst = -Double.infinity
        for ratio in [0.999, 1.001] {
            var line = ""
            for f in freqs {
                let s = measureGain(frequency: f, ratio: ratio, prototype: proto).spurDB
                worst = max(worst, s)
                line += String(format: " %gk:%.1f", f / 1000, s)
            }
            print(String(format: "[3] spurious level @ ratio %.3f (dB rel. carrier, lower is better):%@", ratio, line))
        }
        print(String(format: "[3] worst spurious over both ratios = %.1f dB → rejection = %.1f dB (target >= 95 dB)",
                     worst, -worst))
        XCTAssertLessThan(worst, -95.0)
    }

    // MARK: - 4. Effective resolution against a full-scale sweep

    func test4_effectiveResolution() {
        let n = 1 << 16
        let proto = PolyphasePrototype()
        // Full-scale linear sweep, 20 Hz → 20 kHz.
        var x = [Float](repeating: 0, count: n)
        let f0 = 20.0 / Self.fs, f1 = 20000.0 / Self.fs
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let phase = 2 * Double.pi * (f0 * Double(i) + 0.5 * (f1 - f0) * Double(i) * t)
            x[i] = Float(0.999 * sin(phase))
        }
        let ratio = 1.0005
        let (out, phases, _) = runWhole([x], ratio: ratio, prototype: proto, capturePhase: true)

        // "Ideal" = the same warp evaluated by direct sinc, in Double. The difference is the
        // polyphase implementation's own error floor, which is what effective resolution means
        // here: everything the STRUCTURE adds on top of the filter it is approximating.
        var scratch = [Float](repeating: 0, count: proto.taps + n)
        for i in 0..<n { scratch[proto.taps + i] = x[i] }
        let ref = ReferenceSincResampler.process(scratch: [scratch], phases: phases, prototype: proto)

        let g = 512
        var err = [Double](); err.reserveCapacity(out[0].count)
        var sig = [Double]()
        for i in g..<(out[0].count - g) {
            err.append(Double(out[0][i]) - ref[0][i])
            sig.append(ref[0][i])
        }
        let snr = db(rms(sig) / rms(err))
        let enob = (snr - 1.76) / 6.02
        print(String(format: "[4] full-scale sweep 20 Hz–20 kHz @ ratio %.4f: SNR vs direct-sinc reference "
                   + "= %.1f dB → %.1f effective bits (target > 20 bits). peak |err| = %.3e",
                     ratio, snr, enob, err.map(abs).max() ?? 0))

        // ── CHARACTERISING THE FLOOR, NOT TUNING IT ───────────────────────────────────────
        //
        // The default P = 512 is the design's value and is what the line above is judged on. The
        // sweep below exists to say WHY the figure lands where it does and what it is a function
        // of: linear interpolation between branches has an error that falls as 1/P^2, i.e. 12 dB
        // per doubling. Measuring three points tests that law rather than asserting it, and turns
        // "missed by 0.4 bits" into a number someone can act on.
        for branches in [512, 1024, 2048] {
            let pr = PolyphasePrototype(branches: branches)
            let (o2, ph2, _) = runWhole([x], ratio: ratio, prototype: pr, capturePhase: true)
            var sc = [Float](repeating: 0, count: pr.taps + n)
            for i in 0..<n { sc[pr.taps + i] = x[i] }
            let rf = ReferenceSincResampler.process(scratch: [sc], phases: ph2, prototype: pr)
            var e = [Double](); var sg = [Double]()
            for i in g..<(o2[0].count - g) { e.append(Double(o2[0][i]) - rf[0][i]); sg.append(rf[0][i]) }
            let s2 = db(rms(sg) / rms(e))
            print(String(format: "[4]   P = %4d branches: SNR %.1f dB → %.1f bits  (table %d KB)",
                         branches, s2, (s2 - 1.76) / 6.02,
                         (branches + 1) * pr.taps * 4 / 1024))
        }
        XCTAssertGreaterThan(enob, 20.0)
    }

    // MARK: - 5. THE GATE — continuity across ratio changes

    func test5_gateRatioChangeContinuity() {
        let proto = PolyphasePrototype()
        let blockFrames = 480                       // 10 ms at 48 kHz
        let blocks = 200                            // 2 s
        let n = blockFrames * blocks

        var x = [Float](repeating: 0, count: n)
        var rng = SystemRandomNumberGenerator()
        // Broadband, full-scale-ish: a sweep plus noise, so the residual cannot hide in a quiet band.
        let f0 = 100.0 / Self.fs, f1 = 20000.0 / Self.fs
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let phase = 2 * Double.pi * (f0 * Double(i) + 0.5 * (f1 - f0) * Double(i) * t)
            x[i] = Float(0.7 * sin(phase) + 0.2 * Double.random(in: -1...1, using: &rng))
        }

        let r = PolyphaseResampler(channels: 1, ratio: 1.0, prototype: proto)
        r.capturesPhase = true
        var out = [Float]()
        var changeOutputIndices = [Int]()
        var ratios = [Double]()

        for b in 0..<blocks {
            // A ramp across ±0.1%, plus a random step within the same bound.
            let ramp = -0.001 + 0.002 * Double(b) / Double(blocks - 1)
            let step = Double.random(in: -0.001...0.001, using: &rng)
            let ratio = 1.0 + max(-0.001, min(0.001, ramp + step))
            r.ratio = ratio
            ratios.append(ratio)
            changeOutputIndices.append(out.count)

            let chunk = [Array(x[(b * blockFrames)..<((b + 1) * blockFrames)])]
            var o = [[Float]](repeating: [Float](repeating: 0, count: r.maximumOutputFrames(for: blockFrames)), count: 1)
            let produced = r.process(input: chunk, output: &o)
            out.append(contentsOf: o[0][0..<produced])
        }

        var scratch = [Float](repeating: 0, count: proto.taps + n)
        for i in 0..<n { scratch[proto.taps + i] = x[i] }
        let ref = ReferenceSincResampler.process(scratch: [scratch], phases: r.phaseTrace, prototype: proto)

        let g = 512
        var err = [Double](repeating: 0, count: out.count)
        for i in 0..<out.count { err[i] = Double(out[i]) - ref[0][i] }
        let body = Array(err[g..<(out.count - g)])

        // Residual AT the change instants: the first output frame at or after each ratio write,
        // plus the two either side, which is where a state-dependent structure would ring.
        var atChange = [Double]()
        for idx in changeOutputIndices where idx >= g && idx < out.count - g {
            for k in max(0, idx - 2)...min(out.count - 1, idx + 2) { atChange.append(err[k]) }
        }

        let maxAll = body.map(abs).max() ?? 0
        let rmsAll = rms(body)
        let maxChange = atChange.map(abs).max() ?? 0
        let rmsChange = rms(atChange)
        let signalRMS = rms(Array(ref[0][g..<(out.count - g)]))

        print(String(format: "[5] GATE — ratio changed %d times (every 10 ms), ramp ±0.1%% + random steps.",
                     blocks))
        print(String(format: "[5]   output frames %d, ratio range %.6f … %.6f",
                     out.count, ratios.min()!, ratios.max()!))
        print(String(format: "[5]   residual vs direct-sinc reference: max %.3e  RMS %.3e  (%.1f dB below signal)",
                     maxAll, rmsAll, db(signalRMS / rmsAll)))
        print(String(format: "[5]   residual AT the %d change instants (±2 frames): max %.3e  RMS %.3e",
                     changeOutputIndices.count, maxChange, rmsChange))
        print(String(format: "[5]   change-instant RMS / overall RMS = %.4f   (1.0 = no spike; >1 = the "
                   + "structure rings on a ratio write)", rmsChange / rmsAll))

        // Which floor is the residual sitting at?
        let dbl = polyphaseInDouble(scratch: scratch, phases: r.phaseTrace, prototype: proto)
        var interpErr = [Double](repeating: 0, count: out.count)
        var arithErr  = [Double](repeating: 0, count: out.count)
        for i in 0..<out.count {
            interpErr[i] = dbl[i] - ref[0][i]          // branch quantisation + linear interpolation
            arithErr[i]  = Double(out[i]) - dbl[i]     // Float dot product vs the same maths in Double
        }
        let interpBody = Array(interpErr[g..<(out.count - g)])
        let arithBody  = Array(arithErr[g..<(out.count - g)])
        print(String(format: "[5]   decomposition — branch-interpolation floor: max %.3e RMS %.3e (%.1f dB below signal)",
                     interpBody.map(abs).max() ?? 0, rms(interpBody), db(signalRMS / rms(interpBody))))
        print(String(format: "[5]                   Float-arithmetic floor:     max %.3e RMS %.3e (%.1f dB below signal)",
                     arithBody.map(abs).max() ?? 0, rms(arithBody), db(signalRMS / rms(arithBody))))
        print(String(format: "[5]                   Float eps = %.3e; a 64-tap Float dot product on a %.2f RMS "
                   + "signal has an expected error of ~%.3e",
                     Double(Float.ulpOfOne), signalRMS, 8.0 * Double(Float.ulpOfOne) * signalRMS))
        print(String(format: "[5]   → the residual is dominated by %@",
                     rms(arithBody) > rms(interpBody)
                        ? "FLOAT ARITHMETIC, i.e. it is at the arithmetic floor"
                        : "the branch interpolation, which is a STATIC property of the structure, "
                          + "present at every sample and not a ratio-change artefact"))

        // ── THE CLAUSE THAT ACTUALLY TESTS CONTINUITY, APPLIED TO EACH FLOOR SEPARATELY ────
        //
        // The total residual cannot reach the arithmetic floor against a direct-sinc reference,
        // because any polyphase implementation differs from direct evaluation by its interpolation
        // error at EVERY sample. What a ratio change could do is disturb either floor at the
        // instant it is written. Both are therefore measured at the change instants.
        func atChangeRMS(_ e: [Double]) -> Double {
            var v = [Double]()
            for idx in changeOutputIndices where idx >= g && idx < out.count - g {
                for k in max(0, idx - 2)...min(out.count - 1, idx + 2) { v.append(e[k]) }
            }
            return rms(v)
        }
        let interpRatio = atChangeRMS(interpErr) / rms(interpBody)
        let arithRatio  = atChangeRMS(arithErr)  / rms(arithBody)
        print(String(format: "[5]   change-instant / overall, per floor — interpolation %.4f, arithmetic %.4f "
                   + "(1.0 = a ratio write is indistinguishable from any other frame)",
                     interpRatio, arithRatio))
        XCTAssertLessThan(interpRatio, 1.15)
        XCTAssertLessThan(arithRatio, 1.15)

        // The gate: a ratio write must not be distinguishable from any other output frame.
        XCTAssertLessThan(maxChange, maxAll * 1.000001, "a change instant produced the worst residual in the run")
        XCTAssertLessThan(rmsChange / rmsAll, 1.15, "residual is elevated at ratio-change instants")
    }

    // MARK: - 6. Accumulator exactness

    func test6_accumulatorExactness() {
        let n = 86_400_000                          // 48 kHz × 1800 s
        for ratio in [1.0, 1.001, 0.999, 1.0000317] {
            let inc = PolyphaseResampler.increment(forRatio: ratio)
            var acc: UInt64 = 1 << 32
            for _ in 0..<n { acc &+= inc }
            let exact = (UInt64(1) << 32) &+ UInt64(n) &* inc
            // A Double accumulator over the same schedule, for contrast.
            var d = Double(UInt64(1) << 32)
            let dinc = Double(inc)
            for _ in 0..<n { d += dinc }
            let driftFrames = (d - Double(exact)) / 4294967296.0
            print(String(format: "[6] ratio %.7f, inc = %llu: after %d increments index = %llu, "
                       + "exact = %llu, match = %@ | Double accumulator drifts %+.3f input frames (%.2f ms)",
                         ratio, inc, n, acc >> 32, exact >> 32,
                         acc == exact ? "YES" : "NO", driftFrames, driftFrames / 48.0))
            XCTAssertEqual(acc, exact)
        }
    }

    // MARK: - 7. CPU

    func test7_cpu() {
        let proto = PolyphasePrototype()
        let frames = 48000
        print("[7] µs per output frame, 48 kHz, one second of audio per iteration:")
        for channels in [1, 2, 8, 16] {
            var input = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
            for c in 0..<channels {
                for i in 0..<frames { input[c][i] = Float(sin(Double(i) * 0.01 + Double(c))) }
            }
            let r = PolyphaseResampler(channels: channels, ratio: 1.0001, prototype: proto)
            var out = [[Float]](repeating: [Float](repeating: 0, count: r.maximumOutputFrames(for: frames)),
                                count: channels)
            _ = r.process(input: input, output: &out)     // warm

            let iterations = 5
            var best = Double.infinity
            var produced = 0
            for _ in 0..<iterations {
                let t0 = DispatchTime.now().uptimeNanoseconds
                produced = r.process(input: input, output: &out)
                let t1 = DispatchTime.now().uptimeNanoseconds
                best = min(best, Double(t1 - t0) / 1e3 / Double(produced))
            }
            let realtimePercent = best * 48000 / 1e6 * 100
            print(String(format: "[7]   %2d ch: %.4f µs/frame  → %.2f%% of one core at 48 kHz  (%d frames/iter)",
                         channels, best, realtimePercent, produced))
        }
    }
}
