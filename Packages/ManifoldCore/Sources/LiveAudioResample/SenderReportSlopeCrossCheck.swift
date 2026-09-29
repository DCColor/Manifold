//
//  SenderReportSlopeCrossCheck.swift
//  LiveAudioResample
//
//  The SR line's cross-check and its depth-slope FALLBACK (docs/AUDIO_RESAMPLER_DESIGN.md §18.7,
//  docs/BUGS.md "the SR line fit cannot follow a staircase"): the slope the SR line delivers,
//  checked against the slope the renderer's own audio queue measures, over a long window; and,
//  only when the SRs are demonstrably wrong, the queue's slope in their place.
//
//  ── WHY THE QUEUE MEASURES THE TRUE SLOPE, WHATEVER LINE IS APPLIED ────────────────────────────
//
//  With the loop holding the audio content on its target, at host time t:
//
//      arrived content   A(t) ≈ (1 + ε_a)·t + const         the sender's audio clock
//      consumed content  T(t) = p(t) − offset(p(t)),  p(t) ≈ (1 + ε_v)·t
//      renderer depth    D(t) = A − T = offset(t) − (ε_v − ε_a)·t + const
//
//  so   offset(t) − D(t) = b_true · t + const,   b_true = ε_v − ε_a,
//
//  the physical audio↔video slope in the SR line's own sign convention (`SenderReportLineFit
//  .reference`), and INDEPENDENT of the offset the target applied: a different line moves D and
//  offset together. When the SRs carry the true slope, the SR-derived offset walks at b_true and D
//  is flat; when they do not (a sender or relay whose SRs deviate from the media clocks, §18.5), D
//  drains or fills at the difference.
//
//  ── THE FALLBACK, AND WHY IT CANNOT FEED BACK ON ITSELF ─────────────────────────────────────────
//
//  The SR fit stays the primary source of offset and slope. Two slopes are measured per check, both
//  Theil–Sen over the same 600 s of steering windows:
//
//      b_depth = slope of (applied offset − D)      the media's slope, from the queue (above)
//      b_SR    = slope of the SR-derived offset     what the SR line delivers, level walks included
//
//  Engaged, the target's offset is the SR offset PLUS a correction that walks at (b_depth − b_SR):
//  the SR's own level and short-term changes are kept, and only its long-run slope is replaced.
//
//  No feedback: the correction enters the APPLIED offset, and D follows the applied offset one for
//  one (the loop tracks its target), so (applied − D) — hence b_depth — is unchanged by it; b_SR is
//  read from the SR-derived offset, which excludes the correction by construction. Neither input to
//  the decision moves when the decision acts. A loop lag τ only delays D by a constant for a ramp,
//  which a slope does not see. Pinned by `testEngagedCorrectionLeavesTheDepthSlopeUnbiased`.
//
//  ── THE NUMBERS ────────────────────────────────────────────────────────────────────────────────
//
//  * window 600 s, the fit's own slope window. First check once the points span ≥ 540 s; the first
//    60 s after anchoring are skipped (startup realign, provisional first line). One check a minute.
//  * estimator Theil–Sen: a rail event or a splice moves D by up to ~100 ms for tens of seconds
//    (§13.4); the median of pairwise slopes ignores up to 29 % of the points.
//  * bound 10 ppm: the fit's own slope SE bound (§15.1); 18 ms of lip-sync walk per 30 min.
//    Beyond it (and not engaged): a WARNING.
//  * ENGAGE: |b_depth − b_SR| > 10 ppm with b_depth's SE ≤ 5 ppm, at EVERY check for 10 min.
//    SE ≤ 5 ppm puts a 10 ppm disagreement ≥ 2 SE out. The SE is the residual σ (MAD) over
//    √n · sd(t), inflated by √((1+ρ₁)/(1−ρ₁)), ρ₁ the residuals' lag-1 autocorrelation — the
//    window points are not independent.
//  * DISENGAGE: |b_depth − b_SR| < 5 ppm (half the bound) at every check for 10 min. The
//    correction accumulated so far is KEPT (frozen): dropping it would step the target back by the
//    error it removed. A later SR catch-up shows as the opposite disagreement and re-engages to
//    unwind it — symmetric by construction, and each transition needs 10 min of evidence, so no
//    oscillation faster than that is possible.
//  * while the catch-up runs, and for one window after it ends, the rate is held and no disengage
//    decision is made: those windows span a change of the correction's rate, which a loop lag τ
//    turns into a Δr·τ hump that a slope would misread (measured in test: 12.7 ppm at τ = 30 s).
//  * the correction is anchored where the evidence starts (the first disagreeing check's window
//    start), so the error accumulated before engaging is removed too; that back-correction is
//    caught up at ≤ 150 ppm — the fit's slope clamp, the fastest slope the design admits — so the
//    target never steps. 80 ms takes ~9 min.
//

import Foundation

public final class SenderReportSlopeCrossCheck: @unchecked Sendable {

    public struct Parameters: Sendable {
        public var window = 600.0
        public var minimumSpan = 540.0
        public var warmup = 60.0
        public var bound = 10e-6
        public var checkEvery = 60.0
        public var slopeSEBound = 5e-6
        public var engageSustain = 600.0
        public var disengageBound = 5e-6
        public var disengageSustain = 600.0
        public var catchUpRate = 150e-6
        /// false: log only (the pre-fallback behaviour).
        public var fallbackEnabled = true
        public init() {}
        public static let adopted = Parameters()
    }

    public struct Check: Sendable, Equatable {
        /// Theil–Sen slope of (applied offset − renderer depth): the physical A/V slope.
        public let implied: Double
        /// Theil–Sen slope of the SR-derived offset: the slope the SR line delivers.
        public let srSlope: Double
        /// The fit's slope applied at the check (for the log).
        public let applied: Double
        /// Theil–Sen slope of the renderer depth alone.
        public let depthSlope: Double
        /// Standard error of `implied`.
        public let impliedSE: Double
        public let span: Double
        public let points: Int
        public var disagreement: Double { implied - srSlope }
    }

    public struct Correction: Sendable, Equatable {
        public var offset = 0.0
        public var slope = 0.0
    }

    public let parameters: Parameters
    private let tag: String
    private let lock = UnfairLockBox()
    private var points: [(t: Double, x: Double, y: Double, depth: Double, sr: Double)] = []
    private var lastCheckAt: Double?
    private var checks = 0, warnings = 0
    private var worst: Check?
    private var latestCheck: Check?

    // Fallback state.
    private var engaged = false
    private var runStart: Double?                 // first check of the current sustained run
    private var runAnchorX: Double?               // its window start, in video time
    private var runSign: Bool?
    private var episodes = 0
    private var engagedSeconds = 0.0, engagedSince: Double?
    private var deviationLogged = false
    // correction(x) = K + r·(x − xk) − remaining(x),  remaining = R0 caught up at catchUpRate from xe
    private var k = 0.0, r = 0.0, xk = 0.0
    private var r0 = 0.0, xe = 0.0
    /// Until this time the fallback holds its rate and makes no disengage decision: the window still
    /// spans a change in the correction's rate (the catch-up's start or end).
    private var holdDecisionsUntil = -Double.infinity

    public init(tag: String, parameters: Parameters = .adopted) {
        self.tag = tag; self.parameters = parameters
    }

    /// The correction to add to the SR line's offset (and slope) at video time x. Zero until the
    /// fallback first engages.
    public func correction(atVideoTime x: Double) -> Correction {
        lock.lock(); defer { lock.unlock() }
        return correctionLocked(x)
    }

    private func correctionLocked(_ x: Double) -> Correction {
        guard episodes > 0, x.isFinite else { return Correction() }
        return Correction(offset: k + r * (x - xk) - remainingLocked(x), slope: engaged ? r : 0)
    }

    /// Back-correction not yet caught up at x: r0 at xe, shrinking toward 0 at `catchUpRate`.
    private func remainingLocked(_ x: Double) -> Double {
        let caught = min(abs(r0), parameters.catchUpRate * max(0, x - xe))
        return r0 - (r0 < 0 ? -caught : caught)
    }

    public var isEngaged: Bool { lock.lock(); defer { lock.unlock() }; return engaged }
    /// Engaged and past the catch-up's hold: its checks now steer the rate and the disengage test.
    public var isSettled: Bool {
        lock.lock(); defer { lock.unlock() }
        return engaged && (lastCheckAt ?? -.infinity) >= holdDecisionsUntil
    }

    /// One steering window. `time` is seconds since the session's anchor on any steady clock and
    /// `videoTime` the SR fit's latest video content time; `rendererDepth` the window's median queue
    /// depth; `appliedOffset` what the target used (SR offset + correction), `srOffset` the SR line's
    /// alone. Returns the lines to log (WARNING, ENGAGE, DISENGAGE, SR DEVIATION regardless of
    /// `reportsInfo`).
    public func note(time t: Double, videoTime x: Double, rendererDepth: Double?, appliedOffset: Double,
                     srOffset: Double, appliedSlope: Double, reportsInfo: Bool) -> [String] {
        guard let depth = rendererDepth, depth.isFinite, t.isFinite, x.isFinite, appliedOffset.isFinite,
              srOffset.isFinite, appliedSlope.isFinite else { return [] }
        let p = parameters
        lock.lock()
        defer { lock.unlock() }
        guard t >= p.warmup else { return [] }
        points.append((t, x, appliedOffset - depth, depth, srOffset))
        var drop = 0
        while drop < points.count - 1, points[drop].t < t - p.window { drop += 1 }
        if drop > 0 { points.removeFirst(drop) }
        let span = t - points[0].t
        guard span >= p.minimumSpan, lastCheckAt.map({ t - $0 >= p.checkEvery - 1e-6 }) ?? true
        else { return [] }
        lastCheckAt = t
        let ts = points.map(\.t)
        let ys = points.map(\.y)
        let implied = Self.theilSen(ts, ys)
        let check = Check(implied: implied, srSlope: Self.theilSen(ts, points.map(\.sr)),
                          applied: appliedSlope, depthSlope: Self.theilSen(ts, points.map(\.depth)),
                          impliedSE: Self.slopeSE(ts, ys, slope: implied), span: span,
                          points: points.count)
        checks += 1
        latestCheck = check
        if abs(check.disagreement) > abs(worst?.disagreement ?? 0) { worst = check }
        var lines: [String] = []
        let dis = check.disagreement
        let describe = String(format: "SR slope %+.2f ppm vs renderer-depth slope %+.2f ppm (SE %.2f) "
            + "over the last %.0f s (%d windows): disagreement %+.2f ppm", check.srSlope * 1e6,
            check.implied * 1e6, check.impliedSE * 1e6, check.span, check.points, dis * 1e6)

        // ── The fallback's state machine ────────────────────────────────────────────────────────
        if p.fallbackEnabled {
            if !engaged {
                // A run is broken by a check that does not disagree, or disagrees the other way.
                if abs(dis) > p.bound, check.impliedSE <= p.slopeSEBound,
                   runSign == nil || runSign == (dis > 0) {
                    if runStart == nil { runStart = t; runAnchorX = points[0].x; runSign = dis > 0 }
                } else {
                    runStart = nil; runAnchorX = nil; runSign = nil
                }
                if let s = runStart, t - s >= p.engageSustain - 1e-6, let anchor = runAnchorX {
                    // Engage: the correction walks at the disagreement from now, and the error
                    // accumulated since the evidence began is caught up at ≤ catchUpRate.
                    // Target moves by `back`; the part not yet caught up grows by the same, so the
                    // applied correction is continuous at x. An earlier episode's unfinished
                    // catch-up carries over.
                    let back = dis * (x - anchor)
                    let remaining = remainingLocked(x) + back
                    k = k + r * (x - xk) + back; r = dis; xk = x
                    r0 = remaining; xe = x
                    engaged = true; episodes += 1; engagedSince = t
                    holdDecisionsUntil = t + abs(remaining) / p.catchUpRate + p.window
                    runStart = nil; runAnchorX = nil; runSign = nil
                    lines.append(String(format: "%@ ⚠️ DEPTH-SLOPE FALLBACK ENGAGED at video t=%.0f s — %@, "
                        + "sustained %.0f s. The slope term now comes from the renderer depth: the "
                        + "target is the SR offset plus a correction walking at %+.2f ppm; the %+.1f ms "
                        + "accumulated since video t=%.0f s is caught up at ≤ %.0f ppm. The offset's "
                        + "level stays from the SRs", tag, x, describe, p.engageSustain, dis * 1e6,
                        back * 1e3, anchor, p.catchUpRate * 1e6))
                    if !deviationLogged {
                        deviationLogged = true
                        lines.append(String(format: "%@ ⚠️ SR DEVIATION (once per session): this "
                            + "session's Sender Reports do not carry the media's audio↔video slope — "
                            + "SR %+.2f ppm against %+.2f ppm measured on the audio queue. RFC 3550 "
                            + "§6.4.1 SRs relate each stream's RTP clock to one wallclock; these do "
                            + "not. Falling back to the queue's slope, SR offset kept", tag,
                            check.srSlope * 1e6, check.implied * 1e6))
                    }
                }
            } else {
                // Engaged: follow the disagreement while it is measured well; watch for agreement.
                // Not while the window spans the catch-up: a loop lag τ turns a change of the
                // correction's rate Δr into a Δr·τ hump in (applied − D), which a slope over that
                // window would read as a few ppm (§18.7) — a transient, but the rate integrates.
                let settled = t >= holdDecisionsUntil
                if settled, check.impliedSE <= p.slopeSEBound {
                    k += r * (x - xk); xk = x; r = dis
                }
                if !settled {
                    runStart = nil
                } else if abs(dis) < p.disengageBound {
                    if runStart == nil { runStart = t }
                } else {
                    runStart = nil
                }
                if let s = runStart, t - s >= p.disengageSustain - 1e-6 {
                    k += r * (x - xk); xk = x; r = 0
                    engaged = false; runStart = nil
                    if let e = engagedSince { engagedSeconds += t - e }
                    engagedSince = nil
                    lines.append(String(format: "%@ DEPTH-SLOPE FALLBACK DISENGAGED at video t=%.0f s — "
                        + "%@, agreeing within %.0f ppm for %.0f s. The SR slope is used again; the "
                        + "correction accumulated so far (%+.1f ms) is kept, frozen", tag, x, describe,
                        p.disengageBound * 1e6, p.disengageSustain, correctionLocked(x).offset * 1e3))
                }
            }
        }

        if !engaged, abs(dis) > p.bound {
            warnings += 1
            lines.append(String(format: "%@ ⚠️ WARNING SLOPE CROSS-CHECK — %@ > %.0f ppm (the fit "
                + "applies %+.2f ppm). The renderer queue is moving %+.2f ppm; at this disagreement "
                + "lip-sync walks %.1f ms per 30 min. The SRs are not carrying this session's "
                + "audio↔video slope%@", tag, describe, p.bound * 1e6, check.applied * 1e6,
                check.depthSlope * 1e6, abs(dis) * 1800 * 1e3,
                p.fallbackEnabled ? String(format: " (fallback engages after %.0f s of this with SE ≤ "
                    + "%.0f ppm)", p.engageSustain, p.slopeSEBound * 1e6) : " (log only)"))
        } else if reportsInfo {
            lines.append(String(format: "%@ slope cross-check — %@ · fallback %@ (correction %+.1f ms, "
                + "%+.2f ppm) · queue %+.2f ppm", tag, describe, engaged ? "ENGAGED" : "off",
                correctionLocked(x).offset * 1e3, (engaged ? r : 0) * 1e6, check.depthSlope * 1e6))
        }
        return lines
    }

    public var latest: Check? { lock.lock(); defer { lock.unlock() }; return latestCheck }
    public var warningCount: Int { lock.lock(); defer { lock.unlock() }; return warnings }
    public var engageCount: Int { lock.lock(); defer { lock.unlock() }; return episodes }

    /// For the fit's session summary.
    public func summary(atVideoTime x: Double, time t: Double?) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let w = worst, let l = latestCheck else {
            return "slope cross-check: no check (the session never spanned "
                + "\(Int(parameters.minimumSpan)) s of renderer depth) · depth-slope fallback never engaged"
        }
        let engagedTotal = engagedSeconds + (engagedSince.map { max(0, (t ?? $0) - $0) } ?? 0)
        return String(format: "slope cross-check: %d checks, %d WARNING(s) (bound %.0f ppm) · last: "
            + "SR %+.2f vs renderer-depth %+.2f ppm · worst disagreement %+.2f ppm · depth-slope "
            + "fallback: %@", checks, warnings, parameters.bound * 1e6, l.srSlope * 1e6,
            l.implied * 1e6, w.disagreement * 1e6,
            episodes == 0 ? "never engaged"
                : String(format: "%d episode(s), engaged %.0f s, %@ at end, correction %+.1f ms "
                    + "(%+.2f ppm)", episodes, engagedTotal, engaged ? "ENGAGED" : "disengaged",
                    correctionLocked(x).offset * 1e3, (engaged ? r : 0) * 1e6))
    }

    /// The median of all pairwise slopes. n ≤ 60 here, so the O(n²) is 1770 slopes a minute.
    static func theilSen(_ x: [Double], _ y: [Double]) -> Double {
        var slopes: [Double] = []
        slopes.reserveCapacity(x.count * (x.count - 1) / 2)
        for i in 0..<x.count {
            for j in (i + 1)..<x.count where x[j] > x[i] {
                slopes.append((y[j] - y[i]) / (x[j] - x[i]))
            }
        }
        return SenderReportLineFit.median(slopes)
    }

    /// SE of a slope from its residuals: robust σ (MAD) / (√n · sd(x)), × √((1+ρ₁)/(1−ρ₁)).
    static func slopeSE(_ x: [Double], _ y: [Double], slope b: Double) -> Double {
        let n = x.count
        guard n > 3 else { return .infinity }
        let mx = x.reduce(0, +) / Double(n)
        let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return .infinity }
        var res = (0..<n).map { y[$0] - b * x[$0] }
        let m = SenderReportLineFit.median(res)
        res = res.map { $0 - m }
        let sigma = 1.4826 * SenderReportLineFit.median(res.map(abs))
        var c0 = 0.0, c1 = 0.0
        for i in 0..<n { c0 += res[i] * res[i]; if i > 0 { c1 += res[i] * res[i - 1] } }
        let rho = c0 > 0 ? max(0, min(0.95, c1 / c0)) : 0
        return sigma / sxx.squareRoot() * ((1 + rho) / (1 - rho)).squareRoot()
    }
}
