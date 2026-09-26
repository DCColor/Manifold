//
//  LiveAudioResampleController.swift
//  LiveAudioResample
//
//  The control law of docs/AUDIO_RESAMPLER_DESIGN.md §2.2, as a pure function: content-time error
//  in, ρ out. Build step 4c (§7). Nothing calls it yet — step 4d wires it to the stage.
//
//      e_f  = EMA(e, τ_e)
//      u    = k_p · e_f + i                 di/dt = k_i · e_f, integrated only while |u| < B
//      ρ    = slew( clamp(1 − u, 1 − B, 1 + B), S )
//
//  `e = actual − target`, with `actual` on CONTENT time (§2.1, `inputTime(atOutputTime:)`); `e > 0`
//  is audio ahead of the picture, and ρ < 1 then consumes content more slowly so the picture catches
//  up. ρ is input seconds consumed per output second, which is exactly the stage's `rho` (the
//  resampler's increment), not the resampler's `ratio`, which is its reciprocal.
//
//  ── WHY THERE IS NO FEED-FORWARD INPUT ────────────────────────────────────────────────────────
//
//  The plant is an integrator, de/dt = (ρ − 1) − d, so PI makes a type-2 loop: a constant `d` is
//  nulled with zero steady error by the integrator alone, without the loop being told `d`. §2.2
//  removed the feed-forward because `smoothedRate` disagreed with the realised drift by tens to
//  hundreds of ppm (§11.2). There is deliberately no parameter to pass one in.
//
//  ── WHY A PURE FUNCTION ───────────────────────────────────────────────────────────────────────
//
//  Every number in §2.2's table comes from a simulation of this loop (loop_sim.py). The tests replay
//  that simulation's plant around THIS code, so the table is a property of the code rather than of
//  a script beside it. That only works if the law holds no clock, no lock and no stage.
//

public enum LiveAudioResampleController {

    public struct Gains: Sendable, Equatable {
        /// s⁻¹. §10.5's "aggressive end, still fits": a 10 s closed-loop time constant.
        public var kp: Double
        /// s⁻². k_p²/4 — critically damped.
        public var ki: Double
        /// s. Keeps the per-buffer sawtooth's ratio ripple at ~24 ppm.
        public var tauE: Double
        /// Authority, as |ρ − 1|. ±2000 ppm, ±3.5 cents.
        public var bound: Double
        /// Slew limit on ρ, per second. 200 ppm/s, 0.35 cents/s.
        public var slew: Double

        public init(kp: Double, ki: Double, tauE: Double, bound: Double, slew: Double) {
            self.kp = kp; self.ki = ki; self.tauE = tauE; self.bound = bound; self.slew = slew
        }

        /// §2.2, adopted 2026-09-25. B 0.002 / S 200 ppm/s is the conservative pitch side of the
        /// one open trade (59 ms peak lead during a jitter rail against 47 ms at 0.003 / 500).
        public static let adopted = Gains(kp: 0.1, ki: 0.0025, tauE: 2.0, bound: 0.002, slew: 200e-6)
    }

    public struct State: Sendable, Equatable {
        /// The filtered error, seconds.
        public var filteredError = 0.0
        /// The integral term, as a ratio offset. Held while `u` is at the bound.
        public var integral = 0.0
        /// ρ as last output — the slew limiter's memory.
        public var rho = 1.0
        /// The unclamped command `k_p·e_f + i`, for logging.
        public var command = 0.0
        /// `|command| ≥ bound` on the last step: at the rail, integrator held.
        public var saturated = false
        /// False until the first error arrives, which seeds the EMA rather than being averaged
        /// into a zero it never measured (§10.8's seed lesson).
        public var seeded = false
        public init() {}
    }

    /// One update, per input buffer (§2.1: 47–100 Hz).
    ///
    /// - Parameters:
    ///   - error: `e`, seconds, content time minus target.
    ///   - dt: seconds since the previous update — the buffer's duration.
    /// - Returns: the next state; its `rho` is the ratio to apply to the next block.
    ///
    /// A non-finite `error` or a non-positive or non-finite `dt` returns the state unchanged: ρ
    /// holds, nothing integrates. A bad reading must cost a held ratio, never a step.
    public static func step(_ state: State, error: Double, dt: Double,
                            gains g: Gains = .adopted) -> State {
        guard error.isFinite, dt.isFinite, dt > 0 else { return state }
        var s = state
        if s.seeded {
            s.filteredError += min(dt / g.tauE, 1) * (error - s.filteredError)
        } else {
            s.filteredError = error
            s.seeded = true
        }
        let u = g.kp * s.filteredError + s.integral
        s.command = u
        s.saturated = abs(u) >= g.bound
        // Anti-windup: integrate only while the command is inside the authority. At the rail the
        // loop is already applying all it may; integrating there stores a correction it cannot
        // deliver and spends it later as overshoot (69 ms, against 3.6 ms, after 60 s at the rail).
        if !s.saturated { s.integral += g.ki * s.filteredError * dt }
        let target = 1 - max(-g.bound, min(g.bound, u))
        let maxStep = g.slew * dt
        s.rho += max(-maxStep, min(maxStep, target - s.rho))
        return s
    }

    /// A coarse event (§2.4): the error stepped, and the stage re-anchors rather than glides.
    /// `e_f` is reset — the next error seeds it — and `i` is HELD: the drift it has learned is a
    /// property of the clocks, which a position step does not change. ρ is untouched; the slew
    /// limiter still governs where it goes next.
    public static func coarseEvent(_ state: State) -> State {
        var s = state
        s.filteredError = 0
        s.seeded = false
        return s
    }
}
