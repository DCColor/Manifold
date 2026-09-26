//
//  LiveAudioResampleControllerTests.swift
//  LiveAudioResampleTests
//
//  Build step 4c of docs/AUDIO_RESAMPLER_DESIGN.md §7: the controller replays §2.2's three measured
//  disturbances, and its numbers must be loop_sim.py's.
//
//  ⚠️ THE PLANT BELOW IS loop_sim.py's, LINE FOR LINE, AND THAT IS THE POINT. The table in §2.2 was
//  produced by that script's inline copy of the law. Driving the SAME plant, with the same step,
//  sawtooth and settle rule, around the production `step` makes the table a property of the code
//  that will run. The expected values are the script's output at the adopted gains (run
//  2026-09-26), to the digits printed; the tolerances are far tighter than any design margin, so a
//  change to the law shows up here as a mismatch with the simulation rather than as a pass.
//
//      e = content − target (s). de/dt = (ρ − 1) − dm. dm is the uncorrected slope of −e:
//      (mapping rate − 1) − device drift. Measured error = e + 1.5 ms · sin(2π · 1 Hz · t),
//      the sawtooth step 3's PAIRED windows showed.
//

import XCTest
@testable import LiveAudioResample

final class LiveAudioResampleControllerTests: XCTestCase {

    typealias C = LiveAudioResampleController

    static let dt = 0.020          // one Opus buffer
    static let saw = 0.0015

    struct Row { let t: Double; let e: Double; let rho: Double; let state: C.State }

    /// loop_sim.py's `run`, with the law replaced by `LiveAudioResampleController.step`.
    static func replay(_ dm: (Double) -> Double, seconds: Double, saw: Double = saw) -> [Row] {
        var e = 0.0, t = 0.0
        var s = C.State()
        var out: [Row] = []
        out.reserveCapacity(Int(seconds / dt) + 2)
        while t < seconds {
            let d = dm(t)
            let measured = e + saw * sin(2 * Double.pi * 1.0 * t)
            s = C.step(s, error: measured, dt: dt)
            e += ((s.rho - 1) - d) * dt
            t += dt
            out.append(Row(t: t, e: e, rho: s.rho, state: s))
        }
        return out
    }

    static func rail(ppm: Double, from t0: Double, for dur: Double) -> (Double) -> Double {
        { t in (t0 <= t && t < t0 + dur) ? ppm * 1e-6 : 0 }
    }

    /// loop_sim.py's `settle`: the last time after `after` at which |e| exceeded `tol`.
    static func settle(_ rows: [Row], tol: Double = 0.002, after: Double) -> Double? {
        rows.last { $0.t >= after && abs($0.e) > tol }?.t
    }

    // MARK: - 1. Steady drift: −65 ppm (MediaMTX, §11.2)

    /// Zero steady error with no feed-forward, the integrator having learned the drift; ~24 ppm
    /// ripple from the sawtooth.
    func testSteadyDriftIsNulledWithZeroErrorAndTwentyFourPpmRipple() {
        let rows = Self.replay({ _ in 65e-6 }, seconds: 240)
        XCTAssertEqual(rows.count, 12_000, "same step count as loop_sim.py")
        let last60 = rows.filter { $0.t > 180 }
        let ripplePpm = (last60.map(\.rho).max()! - last60.map(\.rho).min()!) * 1e6
        let meanRhoPpm = last60.reduce(0) { $0 + ($1.rho - 1) } / Double(last60.count) * 1e6
        let maxAbsE = last60.map { abs($0.e) }.max()!
        let peak = rows.map { abs($0.e) }.max()!

        // loop_sim.py: ripple 24.014877 ppm, e@240 s −0.000016782 ms, mean ρ−1 +65.029430 ppm,
        // peak 0.529208115 ms.
        XCTAssertEqual(ripplePpm, 24.014877, accuracy: 1e-4)
        XCTAssertEqual(rows.last!.e * 1e3, -0.000016782, accuracy: 1e-8)
        XCTAssertEqual(meanRhoPpm, 65.029430, accuracy: 1e-4)
        XCTAssertEqual(peak * 1e3, 0.529208115, accuracy: 1e-8)

        // The design's claims, independent of the script.
        XCTAssertLessThan(maxAbsE, 10e-6, "type 2: zero steady error — under 10 µs over the last minute")
        XCTAssertEqual(meanRhoPpm, 65, accuracy: 0.5, "ρ settles on the drift it was never told")
        // u = k_p·e_f + i and ρ = 1 − u, so the drift lives in the integrator, not in a standing error.
        XCTAssertEqual(rows.last!.state.integral, -65e-6, accuracy: 15e-6)
        XCTAssertFalse(last60.contains { $0.state.saturated })
        print(String(format: "[4c] steady −65 ppm: e over last 60 s ≤ %.4f ms, ripple %.2f ppm p-p, "
                     + "mean ρ−1 %+.3f ppm, i %+.2f ppm", maxAbsE * 1e3, ripplePpm, meanRhoPpm,
                     rows.last!.state.integral * 1e6))
    }

    // MARK: - 2. Post-presentation relay: +5000 ppm for 2 s, a 10 ms move (§10.10)

    func testStartupRelaySettlesInFourteenSeconds() {
        let rows = Self.replay(Self.rail(ppm: 5000, from: 20, for: 2), seconds: 240)
        let peak = rows.map { abs($0.e) }.max()!
        let settled = Self.settle(rows, after: 20)! - 20
        let maxRho = rows.map { abs($0.rho - 1) }.max()!

        // loop_sim.py: peak 9.759146381 ms, settles below 2 ms 13.52 s after the relay starts.
        XCTAssertEqual(peak * 1e3, 9.759146381, accuracy: 1e-6)
        XCTAssertEqual(settled, 13.52, accuracy: Self.dt / 2)
        XCTAssertLessThanOrEqual(settled, 20, "§7 4c: a 10 ms relay settled within 20 s")
        // §2.2: at k_p = 0.1 the relay asks for ~1000 ppm and never reaches B.
        XCTAssertLessThan(maxRho, C.Gains.adopted.bound)
        XCTAssertFalse(rows.contains { $0.state.saturated }, "the relay must never reach the rail")
        print(String(format: "[4c] relay 2 s @ +5000 ppm: peak %.3f ms, settled < 2 ms in %.2f s, "
                     + "max |ρ−1| %.0f ppm", peak * 1e3, settled, maxRho * 1e6))
    }

    // MARK: - 3. Jitter recovery: −5000 ppm for 16 s, an 80 ms move (§10.3, n = 1)

    func testJitterRecoveryRailPeaksAtFiftyNineMilliseconds() {
        let rows = Self.replay(Self.rail(ppm: -5000, from: 20, for: 16), seconds: 400)
        let peak = rows.map { abs($0.e) }.max()!
        let settled = Self.settle(rows, after: 20)! - 20
        let maxRho = rows.map { abs($0.rho - 1) }.max()!

        // loop_sim.py: peak 58.971487764 ms, settles below 2 ms in 91.56 s.
        XCTAssertEqual(peak * 1e3, 58.971487764, accuracy: 1e-6)
        XCTAssertEqual(settled, 91.56, accuracy: Self.dt / 2)
        XCTAssertLessThanOrEqual(peak, 0.060, "§7 4c: the jitter peak ≤ 60 ms")
        XCTAssertEqual(maxRho, C.Gains.adopted.bound, accuracy: 1e-12, "the rail is reached and not exceeded")
        print(String(format: "[4c] jitter 16 s @ −5000 ppm: peak %.3f ms, settled < 2 ms in %.2f s",
                     peak * 1e3, settled))
    }

    // MARK: - 4. Anti-windup: 60 s at the rail, then release

    /// dm = +3000 ppm for 60 s (an uncorrected error slope of −3000 ppm): 1000 ppm past the
    /// authority, so the loop sits at the rail for the whole hold (and past it, while it walks the
    /// accumulated error back down).
    ///
    /// §7 4c's criterion (REVISED 2026-09-26): ≤ 4 ms overshoot after a 60 s rail hold, with the
    /// integrator held at ≤ 500 ppm. Measured 3.65 ms and 448 ppm; integrating unconditionally takes
    /// them to 68.9 ms and 9379 ppm (loop_sim.py, same scenario, anti-windup removed).
    ///
    /// The 3.65 ms is not windup. It is the critically damped loop's own recovery from where it
    /// leaves the rail: |u| = B at e = B/k_p = 20 ms, closing at 2 ms/s, which in the linear loop
    /// undershoots by 20 ms · e⁻² = 2.7 ms before the EMA and slew add their lag. Any rail recovery
    /// at these gains overshoots by about that, whatever the hold length.
    func testAntiWindupHoldsTheIntegratorAtTheRail() {
        let holdStart = 20.0, hold = 60.0
        let rows = Self.replay(Self.rail(ppm: 3000, from: holdStart, for: hold), seconds: 600)
        let release = holdStart + hold

        let railSeconds = Double(rows.filter { $0.state.saturated }.count) * Self.dt
        let maxIntegral = rows.map { abs($0.state.integral) }.max()!
        let eAtRelease = rows.last { $0.t <= release }!.e
        let after = rows.filter { $0.t >= release }
        // Overshoot: the excursion past zero, opposite in sign to the error held at release.
        let heldSign = eAtRelease < 0 ? -1.0 : 1.0
        let overshoot = max(0, after.map { -heldSign * $0.e }.max()!)
        let tail = rows.last!.e

        // dm > 0 is content falling BEHIND (de/dt = (ρ − 1) − dm), so the held error is negative.
        XCTAssertLessThan(eAtRelease, 0)
        XCTAssertGreaterThanOrEqual(railSeconds, hold, "the loop must be held at the rail for the whole 60 s")
        XCTAssertEqual(railSeconds, 79.3, accuracy: 0.05)           // loop_sim.py
        XCTAssertEqual(maxIntegral * 1e6, 448, accuracy: 1)         // loop_sim.py; 9379 without anti-windup
        XCTAssertLessThanOrEqual(maxIntegral, 500e-6,
                                 "§7 4c: the integrator held (≤ 500 ppm) — it must not store what the rail could not deliver")
        XCTAssertEqual(overshoot * 1e3, 3.647, accuracy: 0.001)     // loop_sim.py; 68.872 without
        XCTAssertLessThanOrEqual(overshoot, 0.004, "§7 4c: ≤ 4 ms overshoot after a 60 s rail hold")
        XCTAssertLessThan(abs(tail), 10e-6, "and the loop still nulls afterwards")
        print(String(format: "[4c] anti-windup: %.1f s at the rail, |i| ≤ %.0f ppm (9379 without), "
                     + "overshoot %.3f ms after release (68.9 without; §7 criterion ≤ 4 ms, ≤ 500 ppm)",
                     railSeconds, maxIntegral * 1e6, overshoot * 1e3))
    }

    // MARK: - 5. Edges

    /// A bad reading holds ρ and integrates nothing; a coarse event resets e_f and holds i.
    func testBadReadingsHoldAndCoarseEventHoldsTheIntegrator() {
        var s = C.State()
        for _ in 0..<500 { s = C.step(s, error: 0.005, dt: Self.dt) }
        let before = s
        XCTAssertEqual(C.step(s, error: .nan, dt: Self.dt), before)
        XCTAssertEqual(C.step(s, error: .infinity, dt: Self.dt), before)
        XCTAssertEqual(C.step(s, error: 0.005, dt: 0), before)
        XCTAssertEqual(C.step(s, error: 0.005, dt: -Self.dt), before)
        XCTAssertEqual(C.step(s, error: 0.005, dt: .nan), before)

        let c = C.coarseEvent(s)
        XCTAssertEqual(c.integral, s.integral, "i is held across a coarse event (§2.4)")
        XCTAssertEqual(c.rho, s.rho, "ρ does not step; the slew limiter still governs it")
        XCTAssertFalse(c.seeded)
        let next = C.step(c, error: -0.030, dt: Self.dt)
        XCTAssertEqual(next.filteredError, -0.030, "the first error after a coarse event seeds e_f")
        XCTAssertLessThanOrEqual(abs(next.rho - c.rho), C.Gains.adopted.slew * Self.dt + 1e-15,
                                 "even a seeded step is slew-limited")
    }
}
