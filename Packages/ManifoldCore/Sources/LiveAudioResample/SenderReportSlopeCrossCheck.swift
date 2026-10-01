//
//  SenderReportSlopeCrossCheck.swift
//  LiveAudioResample
//
//  The SR line's cross-check, and its LEVEL HOLD (docs/AUDIO_RESAMPLER_DESIGN.md §18.7, §18.20;
//  docs/BUGS.md "the depth-slope fallback should hold the queue's LEVEL"): the slope the SR line
//  delivers, checked against the slope the renderer's own audio queue measures (log only); and, only
//  when the SR line demonstrably takes the queue off its session-start level, the queue's own line in
//  its place.
//
//  ── WHY THE QUEUE MEASURES THE MEDIA, WHATEVER LINE IS APPLIED ─────────────────────────────────
//
//  With the loop holding the audio content on its target, at host time t:
//
//      arrived content   A(t) ≈ (1 + ε_a)·t + const         the sender's audio clock
//      consumed content  T(t) = p(t) − offset(p(t)),  p(t) ≈ (1 + ε_v)·t
//      renderer depth    D(t) = A − T = offset(t) − (ε_v − ε_a)·t + const
//
//  so   u(t) = offset(t) − D(t) = b_true · t + const,   b_true = ε_v − ε_a,
//
//  the media's audio↔video line in the SR line's own sign convention, and INDEPENDENT of the offset
//  the target applied: a different line moves D and offset together. Lip-sync walk ∝ D − D_start.
//
//  ── THE SLOPE CHECK (§18.7, log only) ──────────────────────────────────────────────────────────
//
//  Once a minute, over 600 s of steering windows: b_depth = Theil–Sen slope of u, b_SR = that of the
//  SR-derived offset. |b_depth − b_SR| > 10 ppm (18 ms / 30 min) with the hold off: a WARNING.
//
//  ── THE LEVEL HOLD (§18.20, replacing §18.7's rate-based fallback) ─────────────────────────────
//
//  Per steering window k (10 s), windows the steering marks EXCLUDED (a starvation hold, its
//  recovery, a splice or fallback) skipped entirely:
//
//    D_ref   median depth over the first settled 60 s span (see below) — the session start
//    û(x)    Theil–Sen line of u against video time over the trailing 300 s, at x
//    E       = O_SR(x) − û(x) − D_ref: the queue level the SR line ALONE would give, less the start.
//            O_SR excludes the correction and u does not depend on it: E has no feedback path.
//
//    ENGAGE     |E| > 12 ms at every window for 180 s
//    ENGAGED    the target offset is the queue's line, O*(x) = D_ref + û(x): D is held at D_ref, and
//               the SR line — stairs and all — drops out of the target. The applied offset Ô reaches
//               O* at ≤ 150 ppm (the slope clamp) from wherever it was, so the target never steps.
//    RELEASE    |E| < 4 ms at every window for 600 s: Ô returns to the SR line at ≤ 150 ppm and the
//               correction ends. NOTHING IS KEPT — no rate was integrated, so there is nothing to
//               give back. A false engagement costs at most E while engaged and < 4 ms after.
//
//  Feedback: û sees the resampler loop's lag τ (≈ 20–40 s) as a transient τ·dÔ/dx ≤ τ·150 ppm =
//  4.5 ms at τ = 30 s; a robust line over W = 300 s passes a slope change at ≤ ≈1.5·τ/W = 0.15 of
//  itself, so the loop gain is < 1 and it is stable whatever its phase (§18.20).
//
//  ⚠️ OBSERVE-ONLY THIS RELEASE (Robbie, 2026-09-30, §18.21): `levelHoldApplies` is false. Everything
//  above is computed and logged — the reference, E, the sustain timers, "WOULD ENGAGE" / "WOULD
//  RELEASE" — and `correction` returns zero: the target, the rate and the splices are untouched.
//  Research builds flip the one flag. A live MediaMTX run with the hold applied moved device lip-sync
//  +98.6 ms between captures while the queue said +10.5 ms; until that is explained, it corrects
//  nothing.
//
//  THE SESSION-START REFERENCE IS TAKEN ON A SETTLED SPAN, not at a fixed 60–120 s (§18.21): the
//  first 60 s of consecutive windows with the loop unsaturated and its integrator moving < 10 ppm
//  across them, the SR slope in use, LiveClock's picture buffer within ±10 ms of its target, and no
//  hold, splice or write (an excluded window) inside. §6.3's capture-side start uses the same span,
//  from the "LEVEL REFERENCE" line.
//
//  Line moves: a LiveClock position jump j (+ = picture forward) moves the audio queue by −j and
//  leaves the applied offset alone, so u moves by +j. `noteLineJump` shifts D_ref by −j and the
//  stored u by +j: E and the engaged target are unchanged, and the latency change is kept.
//
//  The per-source audio offset O (§19.1) is the same kind of move: a change ΔO deepens the queue by
//  ΔO, by design, while the applied offset this sees (the SR line's) is unchanged. `noteUserOffsetMove`
//  re-bases by it (D_ref + ΔO, u − ΔO), and the window that contains the change is excluded like a
//  recovery window, so neither the level error nor the 600 s slope reads a deliberate step as SR error.
//

import Foundation

public final class SenderReportSlopeCrossCheck: @unchecked Sendable {

    /// THE ONE SWITCH (§18.21): false = observe-only (this release): computed and logged, never
    /// applied. true = research builds only: the hold corrects the target. Not user-facing.
    public static let levelHoldApplies = false

    /// The loop's state over one window, for the settled-reference rule. nil fields are unknown
    /// (offline replays, tests) and do not block the reference.
    public struct LoopState: Sendable {
        public var saturated: Bool
        public var integral: Double?
        public var liveClockBufferError: Double?
        public init(saturated: Bool = false, integral: Double? = nil, liveClockBufferError: Double? = nil) {
            self.saturated = saturated; self.integral = integral; self.liveClockBufferError = liveClockBufferError
        }
    }

    public struct Parameters: Sendable {
        // The slope check (log only).
        public var window = 600.0
        public var minimumSpan = 540.0
        public var warmup = 60.0
        public var bound = 10e-6
        public var checkEvery = 60.0
        public var slopeSEBound = 5e-6
        // The level hold.
        /// The settled-reference rule (§18.21).
        public var referenceSpan = 60.0
        public var referenceIntegratorMove = 10e-6
        public var referenceBufferTolerance = 0.010
        public var levelWindow = 300.0
        public var levelMinimumSpan = 240.0
        public var engageLevel = 0.012
        public var engageSustain = 180.0
        public var releaseLevel = 0.004
        public var releaseSustain = 600.0
        public var catchUpRate = 150e-6
        /// false: log only — the slope check and the level error, no engage/release state machine.
        public var fallbackEnabled = true
        /// Whether an engaged hold corrects the target (`levelHoldApplies`); false = observe-only.
        public var applies = SenderReportSlopeCrossCheck.levelHoldApplies
        /// Offline sweeps only (§18.9's method): engage at the first window at or after this session
        /// time, whatever the evidence. Never set in the app.
        public var forceEngageAt: Double?
        public init() {}
        public static let adopted = Parameters()
    }

    /// The steering window's length: the slope reported for a catch-up in progress assumes the next
    /// evaluation of the line comes within it.
    static let windowSeconds = 10.0

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

    public enum Mode: String, Sendable { case off = "off", engaged = "ENGAGED", releasing = "RELEASING" }

    public let parameters: Parameters
    private let tag: String
    private let lock = UnfairLockBox()

    // The slope check.
    private var points: [(t: Double, x: Double, y: Double, depth: Double, sr: Double)] = []
    private var lastCheckAt: Double?
    private var checks = 0, warnings = 0
    private var worst: Check?
    private var latestCheck: Check?

    // The level hold.
    /// Consecutive qualifying windows toward the settled reference: (t, depth, integrator).
    private var referenceCandidates: [(t: Double, depth: Double, integral: Double?)] = []
    private var referenceSpanFound: (from: Double, to: Double, move: Double?)?
    private var dRef: Double?
    private var level: [(t: Double, x: Double, u: Double)] = []
    private var line: (a: Double, b: Double)?          // û(x) = a + b·x
    private var lastE: Double?
    private var worstE = 0.0
    private var mode = Mode.off
    private var engageRun: Double?, releaseRun: Double?
    private var episodes = 0
    private var engagedSeconds = 0.0, engagedSince: Double?
    private var deviationLogged = false
    /// Ô(x) − goal(x) = excess0 at excessX, shrinking toward 0 at `catchUpRate`.
    private var excess0 = 0.0, excessX = 0.0
    private var excludedWindows = 0, jumps = 0, offsetMoves = 0

    public init(tag: String, parameters: Parameters = .adopted) {
        self.tag = tag; self.parameters = parameters
    }

    // MARK: - The correction

    /// What to add to the SR line at video time x, given the SR line's own offset and slope there.
    /// Zero unless the hold is engaged or releasing.
    public func correction(atVideoTime x: Double, srOffset: Double, srSlope: Double) -> Correction {
        lock.lock(); defer { lock.unlock() }
        guard parameters.applies, mode != .off, x.isFinite, srOffset.isFinite else { return Correction() }
        let (o, s) = appliedLocked(x, srOffset: srOffset, srSlope: srSlope)
        return Correction(offset: o - srOffset, slope: s - srSlope)
    }

    /// Ô(x) and its slope.
    private func appliedLocked(_ x: Double, srOffset: Double, srSlope: Double) -> (Double, Double) {
        let e = excessLocked(x)
        // The excess's slope: the catch-up rate, but never more than clears it within one window —
        // a new line re-anchors a µs-sized excess every window, which is not a 150 ppm ramp.
        let eSlope = -(e >= 0 ? 1.0 : -1.0) * min(parameters.catchUpRate, abs(e) / Self.windowSeconds)
        switch mode {
        case .off: return (srOffset, srSlope)
        case .releasing: return (srOffset + e, srSlope + eSlope)
        case .engaged:
            guard let l = line, let r = dRef else { return (srOffset + e, srSlope + eSlope) }
            return (r + l.a + l.b * x + e, l.b + eSlope)
        }
    }

    private func excessLocked(_ x: Double) -> Double {
        let caught = parameters.catchUpRate * max(0, x - excessX)
        return abs(excess0) <= caught ? 0 : excess0 - (excess0 > 0 ? caught : -caught)
    }

    /// Re-anchor the excess so Ô is continuous at x across a change of goal (a new line, a mode
    /// change). `before` is Ô at x under the old goal. A change under `stepThrough` is taken as is:
    /// each window's refit moves the goal by a fraction of a millisecond, which the loop absorbs in
    /// its own noise, and slewing it would only make the reported slope ring.
    private func reanchorLocked(_ x: Double, before: Double, srOffset: Double, srSlope: Double) {
        excess0 = 0; excessX = x
        let goal = appliedLocked(x, srOffset: srOffset, srSlope: srSlope).0
        excess0 = abs(before - goal) <= Self.stepThrough ? 0 : before - goal
    }

    /// The largest target move taken without a catch-up (see `reanchorLocked`).
    static let stepThrough = 0.001

    public var currentMode: Mode { lock.lock(); defer { lock.unlock() }; return mode }
    public var isEngaged: Bool { currentMode == .engaged }
    /// E at the latest window: the queue level the SR line alone gives, less the session start.
    public var levelError: Double? { lock.lock(); defer { lock.unlock() }; return lastE }
    public var reference: Double? { lock.lock(); defer { lock.unlock() }; return dRef }

    // MARK: - Line moves

    /// A deliberate move of the target line by `jumped` seconds (+ = the picture moved forward): the
    /// audio queue moves by −jumped and u by +jumped. The session-start reference and the stored
    /// points move with it, so the hold neither reads it as SR error nor undoes the latency change.
    public func noteLineJump(_ jumped: Double) {
        guard jumped.isFinite, jumped != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        jumps += 1
        shiftLocked(jumped)
    }

    /// A change of the audio offset O by `delta` seconds (+ = the audio heard later, §19.1): the queue
    /// deepens by delta and u moves by −delta, exactly as a line jump of −delta. Counted apart.
    public func noteUserOffsetMove(_ delta: Double) {
        guard delta.isFinite, delta != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        offsetMoves += 1
        shiftLocked(-delta)
    }

    /// The re-base both take: the queue moved by −jumped, u by +jumped.
    private func shiftLocked(_ jumped: Double) {
        if dRef != nil { dRef! -= jumped } else {
            referenceCandidates = referenceCandidates.map { ($0.t, $0.depth - jumped, $0.integral) }
        }
        level = level.map { ($0.t, $0.x, $0.u + jumped) }
        points = points.map { ($0.t, $0.x, $0.y + jumped, $0.depth - jumped, $0.sr) }
        if let l = line { line = (l.a + jumped, l.b) }
    }

    // MARK: - Per window

    /// One steering window. `time` is seconds since the session's anchor, `videoTime` the SR fit's
    /// latest video content time; `rendererDepth` the window's median queue depth; `appliedOffset`
    /// what the target used (SR offset + correction), `srOffset` the SR line's alone. `excluded`: the
    /// steering saw a starvation hold, its recovery, a splice or a fallback in this window, so its
    /// depth is not the SR line's doing and is not used. Returns the lines to log.
    public func note(time t: Double, videoTime x: Double, rendererDepth: Double?, appliedOffset: Double,
                     srOffset: Double, appliedSlope: Double, reportsInfo: Bool,
                     excluded: Bool = false, loop: LoopState? = nil,
                     srSlopeInUse: Bool = true) -> [String] {
        guard let depth = rendererDepth, depth.isFinite, t.isFinite, x.isFinite, appliedOffset.isFinite,
              srOffset.isFinite, appliedSlope.isFinite else { return [] }
        let p = parameters
        lock.lock()
        defer { lock.unlock() }
        guard t >= p.warmup else { return [] }
        if excluded {
            excludedWindows += 1
            if dRef == nil { referenceCandidates.removeAll() }   // a hold, splice or write breaks a span
            return []
        }
        // Only Ô's offset is used per window, never its slope: the SR slope does not enter.
        var lines = referenceLocked(t: t, depth: depth, loop: loop, srSlopeInUse: srSlopeInUse)
        lines += levelLocked(t: t, x: x, depth: depth, applied: appliedOffset, sr: srOffset, srSlope: 0)
        lines += slopeCheckLocked(t: t, x: x, depth: depth, applied: appliedOffset, sr: srOffset,
                                  appliedSlope: appliedSlope, reportsInfo: reportsInfo)
        return lines
    }

    /// The settled-reference rule (§18.21; see the header). Returns the one "LEVEL REFERENCE" line.
    private func referenceLocked(t: Double, depth: Double, loop: LoopState?, srSlopeInUse: Bool) -> [String] {
        let p = parameters
        guard dRef == nil else { return [] }
        let qualifies = srSlopeInUse && !(loop?.saturated ?? false)
            && (loop?.liveClockBufferError.map { abs($0) <= p.referenceBufferTolerance } ?? true)
        guard qualifies else { referenceCandidates.removeAll(); return [] }
        referenceCandidates.append((t, depth, loop?.integral))
        // Slide: drop from the front until the integrator's range over the span is < 10 ppm.
        func move() -> Double? {
            let i = referenceCandidates.compactMap(\.integral)
            return i.isEmpty ? nil : i.max()! - i.min()!
        }
        while referenceCandidates.count > 1, let m = move(), m >= p.referenceIntegratorMove {
            referenceCandidates.removeFirst()
        }
        guard let first = referenceCandidates.first, t - first.t >= p.referenceSpan - 1e-6 else { return [] }
        dRef = SenderReportLineFit.median(referenceCandidates.map(\.depth))
        referenceSpanFound = (first.t, t, move())
        let span = referenceSpanFound!
        referenceCandidates.removeAll()
        return [String(format: "%@ LEVEL REFERENCE set at t=%.0f s: queue %.1f ms, the median over the settled "
            + "span %.0f–%.0f s (SR slope in use, loop unsaturated, integrator moved %@, LiveClock within "
            + "±%.0f ms of its target, no hold / splice / write). §6.3's capture-side start is this span",
            tag, t, dRef! * 1e3, span.from, span.to,
            span.move.map { String(format: "%.1f ppm", $0 * 1e6) } ?? "n/a",
            p.referenceBufferTolerance * 1e3)]
    }

    private func levelLocked(t: Double, x: Double, depth: Double, applied: Double, sr: Double,
                             srSlope: Double) -> [String] {
        let p = parameters
        var lines: [String] = []
        // The media line, robustly.
        level.append((t, x, applied - depth))
        var drop = 0
        while drop < level.count - 1, level[drop].t < t - p.levelWindow { drop += 1 }
        if drop > 0 { level.removeFirst(drop) }
        guard let ref = dRef, t - level[0].t >= p.levelMinimumSpan else { return lines }
        let before = appliedLocked(x, srOffset: sr, srSlope: srSlope).0
        let xs = level.map(\.x), us = level.map(\.u)
        let b = Self.theilSen(xs, us)
        let a = SenderReportLineFit.median((0..<xs.count).map { us[$0] - b * xs[$0] })
        line = (a, b)
        let e = sr - (a + b * x) - ref
        lastE = e
        if abs(e) > abs(worstE) { worstE = e }
        // A new line moves the engaged goal: keep Ô continuous.
        if mode == .engaged { reanchorLocked(x, before: before, srOffset: sr, srSlope: srSlope) }
        guard p.fallbackEnabled else { return lines }

        switch mode {
        case .off, .releasing:
            if abs(e) > p.engageLevel { engageRun = engageRun ?? t } else { engageRun = nil }
            let forced = p.forceEngageAt.map { t >= $0 && episodes == 0 } ?? false
            if forced || (engageRun.map { t - $0 >= p.engageSustain - 1e-6 } ?? false) {
                let now = appliedLocked(x, srOffset: sr, srSlope: srSlope).0
                mode = .engaged; episodes += 1; engagedSince = t; engageRun = nil; releaseRun = nil
                reanchorLocked(x, before: now, srOffset: sr, srSlope: srSlope)
                lines.append(String(format: "%@ %@ at video t=%.0f s%@ — the SR line "
                    + "alone puts the renderer queue %+.1f ms from its session-start level (%.1f ms) "
                    + "for %.0f s (> %.0f ms). The target offset now comes from the queue's own line "
                    + "(%+.2f ppm), holding it at the session start; the %+.1f ms is caught up at ≤ "
                    + "%.0f ppm. The SR line is not used while engaged%@", tag,
                    p.applies ? "⚠️ LEVEL HOLD ENGAGED" : "LEVEL HOLD WOULD ENGAGE (observe-only)", x,
                    forced ? " (FORCED, offline sweep)" : "", e * 1e3, ref * 1e3, p.engageSustain,
                    p.engageLevel * 1e3, b * 1e6, -excess0 * 1e3, p.catchUpRate * 1e6,
                    p.applies ? "" : " — OBSERVE-ONLY this release: nothing is applied"))
                if !deviationLogged {
                    deviationLogged = true
                    lines.append(String(format: "%@ ⚠️ SR DEVIATION (once per session): this "
                        + "session's Sender Reports do not hold the media's audio↔video line — the "
                        + "queue it produces left its session-start level by %+.1f ms. RFC 3550 "
                        + "§6.4.1 SRs relate each stream's RTP clock to one wallclock; these do not. "
                        + "%@", tag, e * 1e3,
                        p.applies ? "Holding the queue's level" : "Logged only (the level hold is observe-only)"))
                }
            } else if mode == .releasing, excessLocked(x) == 0 {
                mode = .off
                lines.append(String(format: "%@ %@ at video t=%.0f s — back on the SR line exactly, "
                    + "correction 0", tag, p.applies ? "LEVEL HOLD OFF" : "LEVEL HOLD WOULD BE OFF (observe-only)", x))
            }
        case .engaged:
            if abs(e) < p.releaseLevel { releaseRun = releaseRun ?? t } else { releaseRun = nil }
            if let s = releaseRun, t - s >= p.releaseSustain - 1e-6 {
                let now = appliedLocked(x, srOffset: sr, srSlope: srSlope).0
                mode = .releasing; releaseRun = nil
                if let since = engagedSince { engagedSeconds += t - since }
                engagedSince = nil
                reanchorLocked(x, before: now, srOffset: sr, srSlope: srSlope)
                lines.append(String(format: "%@ %@ at video t=%.0f s — the SR line "
                    + "alone is within %.0f ms of the session-start level (%+.1f ms) for %.0f s; "
                    + "returning to it at ≤ %.0f ppm (%+.1f ms), nothing kept", tag,
                    p.applies ? "LEVEL HOLD RELEASED" : "LEVEL HOLD WOULD RELEASE (observe-only)", x,
                    p.releaseLevel * 1e3, e * 1e3, p.releaseSustain, p.catchUpRate * 1e6,
                    excess0 * 1e3))
            }
        }
        return lines
    }

    private func slopeCheckLocked(t: Double, x: Double, depth: Double, applied: Double, sr: Double,
                                  appliedSlope: Double, reportsInfo: Bool) -> [String] {
        let p = parameters
        points.append((t, x, applied - depth, depth, sr))
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
        let dis = check.disagreement
        let describe = String(format: "SR slope %+.2f ppm vs renderer-depth slope %+.2f ppm (SE %.2f) "
            + "over the last %.0f s (%d windows): disagreement %+.2f ppm", check.srSlope * 1e6,
            check.implied * 1e6, check.impliedSE * 1e6, check.span, check.points, dis * 1e6)
        let levelText = lastE.map { String(format: "queue level %+.1f ms from the session start on "
            + "the SR line alone", $0 * 1e3) } ?? "no session-start level yet"
        if mode == .off, abs(dis) > p.bound {
            warnings += 1
            return [String(format: "%@ ⚠️ WARNING SLOPE CROSS-CHECK — %@ > %.0f ppm (the fit "
                + "applies %+.2f ppm). The renderer queue is moving %+.2f ppm; at this disagreement "
                + "lip-sync walks %.1f ms per 30 min. The SRs are not carrying this session's "
                + "audio↔video slope · %@%@", tag, describe, p.bound * 1e6, check.applied * 1e6,
                check.depthSlope * 1e6, abs(dis) * 1800 * 1e3, levelText,
                !p.fallbackEnabled ? " (log only)"
                    : p.applies ? String(format: " (the level hold engages beyond ±%.0f ms for %.0f s)",
                                         p.engageLevel * 1e3, p.engageSustain)
                    : " (the level hold is observe-only this release)")]
        } else if reportsInfo {
            return [String(format: "%@ slope cross-check — %@ · %@ · level hold %@", tag, describe,
                           levelText, mode.rawValue)]
        }
        return []
    }

    public var latest: Check? { lock.lock(); defer { lock.unlock() }; return latestCheck }
    public var warningCount: Int { lock.lock(); defer { lock.unlock() }; return warnings }
    public var engageCount: Int { lock.lock(); defer { lock.unlock() }; return episodes }

    /// For the fit's session summary.
    public func summary(atVideoTime x: Double, time t: Double?) -> String {
        lock.lock(); defer { lock.unlock() }
        let slope: String
        if let w = worst, let l = latestCheck {
            slope = String(format: "slope cross-check: %d checks, %d WARNING(s) (bound %.0f ppm) · last: "
                + "SR %+.2f vs renderer-depth %+.2f ppm · worst disagreement %+.2f ppm", checks, warnings,
                parameters.bound * 1e6, l.srSlope * 1e6, l.implied * 1e6, w.disagreement * 1e6)
        } else {
            slope = "slope cross-check: no check (the session never spanned "
                + "\(Int(parameters.minimumSpan)) s of renderer depth)"
        }
        let engagedTotal = engagedSeconds + (engagedSince.map { max(0, (t ?? $0) - $0) } ?? 0)
        let hold = String(format: "level hold (%@): session-start level %@%@, SR-line level error last %@ / "
            + "worst %+.1f ms, %@ · %d line jump(s), %d window(s) excluded",
            parameters.applies ? "APPLIED" : "observe-only", dRef.map {
                String(format: "%.1f ms", $0 * 1e3) } ?? "never set (no settled span)",
            referenceSpanFound.map { String(format: " (span %.0f–%.0f s)", $0.from, $0.to) } ?? "",
            lastE.map { String(format: "%+.1f ms", $0 * 1e3) } ?? "—", worstE * 1e3,
            episodes == 0 ? "never engaged"
                : String(format: "%d episode(s), engaged %.0f s, %@ at end", episodes, engagedTotal,
                         mode.rawValue), jumps, excludedWindows)
            + (offsetMoves > 0 ? String(format: ", %d audio-offset change(s) re-based", offsetMoves) : "")
        return slope + " · " + hold
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
