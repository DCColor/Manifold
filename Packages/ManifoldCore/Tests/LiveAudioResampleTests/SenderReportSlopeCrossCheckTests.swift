//
//  SenderReportSlopeCrossCheckTests.swift
//  LiveAudioResampleTests
//
//  The SR line's safety net: the applied slope against the renderer queue's. The queue is simulated
//  from the plant equation the check rests on — depth = offset_applied − b_true·t + c — so each test
//  states the true slope and the applied one separately.
//

import XCTest
@testable import LiveAudioResample

final class SenderReportSlopeCrossCheckTests: XCTestCase {

    typealias Check = SenderReportSlopeCrossCheck

    static var logOnly: Check.Parameters { var p = Check.Parameters(); p.fallbackEnabled = false; return p }

    /// One steering window every 10 s for `seconds`, CLOSED LOOP: the SR line's offset walks at
    /// `appliedSlope` (with a 1 ms level jitter), the check's own correction is added to it, and the
    /// queue follows the applied offset: depth = applied − b_true·t + noise. Returns every line.
    func run(_ check: Check, seconds: Double, trueSlope: Double, appliedSlope: Double,
             depthNoise: Double = 0.001, seed: UInt64 = 1, reportsInfo: Bool = true,
             extraDepth: (Double) -> Double = { _ in 0 }) -> [String] {
        var rng = TestRNG(state: seed)
        var lines: [String] = []
        var t = 10.0
        while t <= seconds {
            let sr = -0.020 + appliedSlope * t + 0.001 * rng.gaussian()
            let c = check.correction(atVideoTime: t)
            let offset = sr + c.offset
            let depth = 0.420 + offset + 0.020 - trueSlope * t + depthNoise * rng.gaussian()
                + extraDepth(t)
            lines += check.note(time: t, videoTime: t, rendererDepth: depth, appliedOffset: offset,
                                srOffset: sr, appliedSlope: appliedSlope + c.slope,
                                reportsInfo: reportsInfo)
            t += 10
        }
        return lines
    }

    func testAgreementIsQuietAndMeasuresTheTrueSlope() {
        let check = Check(tag: "[TEST-SRFIT]")
        let lines = run(check, seconds: 1800, trueSlope: 66e-6, appliedSlope: 66e-6)
        XCTAssertEqual(lines.filter { $0.contains("WARNING") }.count, 0)
        XCTAssertGreaterThan(lines.filter { $0.contains("slope cross-check") }.count, 15)
        let c = check.latest!
        XCTAssertEqual(c.implied, 66e-6, accuracy: 2e-6)
        XCTAssertEqual(c.depthSlope, 0, accuracy: 2e-6, "the SR line carries the slope: a flat queue")
    }

    /// The 2026-09-28 MediaMTX case: the SRs carry +42 ppm, the media +66 → WARNING, naming both.
    func testDisagreementBeyondTheBoundWarns() {
        let check = Check(tag: "[TEST-SRFIT]", parameters: Self.logOnly)
        let lines = run(check, seconds: 1800, trueSlope: 66e-6, appliedSlope: 42e-6)
        let warnings = lines.filter { $0.contains("⚠️ WARNING SLOPE CROSS-CHECK") }
        XCTAssertEqual(warnings.count, check.warningCount)
        XCTAssertGreaterThan(warnings.count, 15)
        XCTAssertTrue(warnings[0].contains("SR slope +4"), warnings[0])
        XCTAssertTrue(warnings[0].contains("(log only)"), warnings[0])
        XCTAssertEqual(check.latest!.disagreement, 24e-6, accuracy: 2e-6)
        XCTAssertEqual(check.latest!.depthSlope, -24e-6, accuracy: 2e-6)
        XCTAssertTrue(check.summary(atVideoTime: 0, time: nil).contains("WARNING"))
    }

    /// Inside the bound: quiet, both ways.
    func testDisagreementInsideTheBoundIsQuiet() {
        for applied in [61e-6, 71e-6] {        // half the bound: the check's sd here is ~1 ppm
            let check = Check(tag: "[TEST-SRFIT]")
            let lines = run(check, seconds: 1800, trueSlope: 66e-6, appliedSlope: applied)
            XCTAssertEqual(lines.filter { $0.contains("WARNING") }.count, 0, "\(applied)")
        }
    }

    /// A §13.4 rail event — the queue down 100 ms for 70 s, then back — must not warn by itself.
    func testRailEventDoesNotWarn() {
        let check = Check(tag: "[TEST-SRFIT]")
        let lines = run(check, seconds: 1800, trueSlope: 66e-6, appliedSlope: 66e-6,
                        extraDepth: { t in t >= 900 && t < 970 ? -0.100 * (1 - (t - 900) / 70) : 0 })
        XCTAssertEqual(lines.filter { $0.contains("WARNING") }.count, 0)
    }

    /// No check before the window spans 540 s, INFO only when reported, WARNING always.
    func testCadenceAndReporting() {
        let early = Check(tag: "[T]")
        XCTAssertTrue(run(early, seconds: 590, trueSlope: 66e-6, appliedSlope: 0).isEmpty)
        XCTAssertNil(early.latest)
        XCTAssertTrue(early.summary(atVideoTime: 0, time: nil).contains("no check"))

        let quietAgree = Check(tag: "[T]")
        XCTAssertTrue(run(quietAgree, seconds: 1800, trueSlope: 66e-6, appliedSlope: 66e-6,
                          reportsInfo: false).isEmpty)
        let quietDisagree = Check(tag: "[T]", parameters: Self.logOnly)
        let lines = run(quietDisagree, seconds: 1800, trueSlope: 66e-6, appliedSlope: 0,
                        reportsInfo: false)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.contains("WARNING") })
        // One check a minute: (1800 − 600) / 60 + 1.
        XCTAssertEqual(lines.count, 21)
    }

    /// The fit's window companion: its window line when windows are reported, the check always.
    func testFitWindowLinesCarryTheCheck() {
        let fit = SenderReportLineFit.make(timeline: .rtpSenderReports, tag: "[Q]", reportsWindows: false,
                                           crossCheckParameters: Self.logOnly, log: nil)!
        var lines: [String] = []
        for k in 1...180 {
            let t = Double(k) * 10
            fit.notePair(videoTime: t, delta: -0.020)
            lines += fit.windowLines(time: t, rendererDepth: 0.420 - 60e-6 * t, appliedOffset: 0,
                                     appliedSlope: 0)
        }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.contains("WARNING SLOPE CROSS-CHECK") })
        XCTAssertEqual(fit.crossCheck.latest!.implied, 60e-6, accuracy: 0.1e-6)
    }

    // MARK: - The depth-slope fallback

    /// A whole WHEP session through the real fit, closed loop: SR pairs `delta(x)` at 1/s, the
    /// media's true line `media(t)` (offset − depth), the queue following the APPLIED offset through
    /// a first-order loop lag `lag` s. Returns the log lines and the queue depth per window.
    func session(seconds: Double, delta: @escaping (Double) -> Double, media: (Double) -> Double,
                 depthNoise: Double = 0.001, lag: Double = 0, seed: UInt64 = 3,
                 each: ((Double, SenderReportLineFit) -> Void)? = nil)
        -> (lines: [String], depth: [(t: Double, d: Double)], fit: SenderReportLineFit) {
        let sink = LogSink()
        let fit = SenderReportLineFit.make(timeline: .rtpSenderReports, tag: "[TEST-SRFIT]",
                                           reportsWindows: false, log: { sink.append($0) })!
        var rng = TestRNG(state: seed)
        var depth: [(Double, Double)] = []
        var lagged: Double?
        var t = 1.0
        while t <= seconds {
            fit.notePair(videoTime: t, delta: delta(t))
            if Int(t) % 10 == 0, let e = fit.evaluate(atVideoTime: t) {
                let a = lag > 0 ? 1 - exp(-10 / lag) : 1
                lagged = lagged.map { $0 + a * (e.offset - $0) } ?? e.offset
                let d = 0.420 + lagged! - media(t) + depthNoise * rng.gaussian()
                depth.append((t, d))
                fit.windowLines(time: t, rendererDepth: d, appliedOffset: e.offset,
                                appliedSlope: e.slope).forEach(sink.append)
                each?(t, fit)
            }
            t += 1
        }
        return (sink.all, depth, fit)
    }

    func count(_ lines: [String], _ s: String) -> Int { lines.filter { $0.contains(s) }.count }

    /// §18.5's A/B sessions: SRs flat to 7 µs, the media +65 ppm. Engages once, after the 10 min of
    /// sustained evidence; the deviation is logged once; the queue then flattens and the error the
    /// SRs let accumulate is caught up — within 2 ms of the start by 1 h.
    func testEngagesOnFlatSRsWithDriftingMedia() {
        var rng = TestRNG(state: 71)
        let r = session(seconds: 3600, delta: { _ in -0.020 + 7e-6 * rng.gaussian() },
                        media: { 65e-6 * $0 })
        XCTAssertEqual(count(r.lines, "FALLBACK ENGAGED"), 1)
        XCTAssertEqual(count(r.lines, "DISENGAGED"), 0)
        XCTAssertEqual(count(r.lines, "SR DEVIATION"), 1)
        let at = r.lines.first { $0.contains("FALLBACK ENGAGED") }!
        XCTAssertTrue(at.contains("video t=1200 s") || at.contains("video t=1190 s"), at)
        XCTAssertTrue(r.fit.crossCheck.isEngaged)
        XCTAssertEqual(r.fit.evaluate(atVideoTime: 3600)!.slope, 65e-6, accuracy: 2e-6)
        // Lip-sync error ∝ depth change: from the first minutes to the last, back within 5 ms (a
        // third of §5.3's ±15 ms; the residual is the integrated noise of the measured rate).
        let start = r.depth.filter { $0.t >= 60 && $0.t <= 120 }.map(\.d).reduce(0, +) / 7
        let end = r.depth.filter { $0.t >= 3540 }.map(\.d).reduce(0, +) / 7
        XCTAssertEqual(end - start, 0, accuracy: 0.005)
        // Never a target step: consecutive windows differ by the slope plus noise, never ~ms jumps.
        for i in 1..<r.depth.count {
            XCTAssertLessThan(abs(r.depth[i].d - r.depth[i - 1].d), 0.006, "at \(r.depth[i].t)")
        }
    }

    /// No feedback: while engaged, the depth-slope measurement stays on the media's true slope —
    /// with and without a loop lag between the applied offset and the queue.
    func testEngagedCorrectionLeavesTheDepthSlopeUnbiased() {
        for lag in [0.0, 10.0, 30.0] {
            var worst = 0.0
            var rng = TestRNG(state: 72)
            let r = session(seconds: 3600, delta: { _ in -0.020 + 7e-6 * rng.gaussian() },
                            media: { 65e-6 * $0 }, lag: lag, each: { t, fit in
                // The checks that steer: engaged and past the catch-up's hold. Unbiased means within
                // the measurement's own noise: 3 SE.
                guard fit.crossCheck.isSettled, let c = fit.crossCheck.latest else { return }
                worst = max(worst, abs(c.implied - 65e-6) / c.impliedSE)
            })
            XCTAssertTrue(r.fit.crossCheck.isEngaged, "lag \(lag)")
            XCTAssertLessThan(worst, 3, "lag \(lag) s: implied slope off by \(worst) SE")
            XCTAssertEqual(count(r.lines, "FALLBACK ENGAGED"), 1, "lag \(lag)")
        }
    }

    /// Stays disengaged whenever the SRs carry the media's slope: Cloudflare-like noise, a
    /// staircase, and a clean line.
    func testStaysDisengagedWhenTheSRsCarryTheSlope() {
        var n = TestRNG(state: 81)
        var wander = 0.0
        let a = exp(-1.0 / 60)
        var lastJump = 1.0, nextJump = 1.0
        let shapes: [(String, (Double) -> Double, Double)] = [
            ("white noise", { x in
                wander = a * wander + (1 - a * a).squareRoot() * 0.002 * n.gaussian()
                return -0.020 + 68e-6 * x + wander + 0.0095 * n.gaussian() }, 68e-6),
            ("staircase", { x in
                if x >= nextJump { lastJump = x; nextJump = x + 10 + 50 * n.uniform() }
                return -0.020 + 54e-6 * lastJump + 7e-6 * n.gaussian() }, 54e-6),
            ("clean", { x in -0.020 + 20e-6 * x + 7e-6 * n.gaussian() }, 20e-6),
        ]
        for (label, delta, slope) in shapes {
            let r = session(seconds: 3600, delta: delta, media: { slope * $0 })
            XCTAssertEqual(count(r.lines, "FALLBACK ENGAGED"), 0, label)
            XCTAssertEqual(r.fit.crossCheck.correction(atVideoTime: 3600).offset, 0, label)
        }
    }

    /// Hysteresis: engaged on flat SRs; when the SRs begin to carry the slope (from 2400 s) it
    /// disengages once, 10 min after they agree, keeping its correction — no step, no re-engage.
    func testDisengagesWithHysteresisAndKeepsItsCorrection() {
        var rng = TestRNG(state: 91)
        var correctionAt: [Double: Double] = [:]
        let r = session(seconds: 5400, delta: { x in
            -0.020 + 65e-6 * max(0, x - 2400) + 7e-6 * rng.gaussian()
        }, media: { 65e-6 * $0 }, each: { t, fit in
            correctionAt[t] = fit.crossCheck.correction(atVideoTime: t).offset
        })
        XCTAssertEqual(count(r.lines, "FALLBACK ENGAGED"), 1)
        XCTAssertEqual(count(r.lines, "DISENGAGED"), 1)
        XCTAssertFalse(r.fit.crossCheck.isEngaged)
        let off = r.lines.first { $0.contains("DISENGAGED") }!
        XCTAssertTrue(off.contains("kept, frozen"), off)
        // Frozen after disengaging: constant to the end.
        XCTAssertEqual(correctionAt[5400]!, correctionAt[5000]!, accuracy: 1e-9)
        for i in 1..<r.depth.count {
            XCTAssertLessThan(abs(r.depth[i].d - r.depth[i - 1].d), 0.006, "at \(r.depth[i].t)")
        }
    }

    /// No oscillation at the margin: a disagreement hovering at the 10 ppm bound engages at most
    /// once and never flaps over two hours.
    func testNoOscillationAtTheBound() {
        var rng = TestRNG(state: 101)
        let r = session(seconds: 7200, delta: { _ in -0.020 + 7e-6 * rng.gaussian() },
                        media: { 10.3e-6 * $0 }, depthNoise: 0.002)
        XCTAssertLessThanOrEqual(count(r.lines, "FALLBACK ENGAGED"), 1)
        XCTAssertEqual(count(r.lines, "DISENGAGED"), 0)
    }

    /// The steering hands its companion the window's time and median depth EVEN WHEN it does not
    /// report windows, so the check's WARNING reaches a Release log — and prints no window line then.
    func testSteeringCallsItsCompanionWithoutReportingWindows() {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var facts: [LiveAudioResampleSteering.WindowFacts] = []
            var logged: [String] = []
        }
        let box = Box()
        let p = SimPlant()
        let s = LiveAudioResampleSteering(
            tag: "[TEST-STEER]", mode: .loop, clock: p, gains: .adopted, thresholds: .adopted,
            reportsWindows: false, readTimebase: { p.timebase }, hostNow: { p.host },
            write: { o, h, why in p.write(o, h, why) },
            log: { l in box.lock.lock(); box.logged.append(l); box.lock.unlock() },
            windowCompanion: { f in
                box.lock.lock(); box.facts.append(f); box.lock.unlock()
                return ["[TEST-SRFIT] companion"]
            })
        // Host 100, not 0: the steering's window clock treats 0 as "not started".
        p.host = 100
        s.anchor(media: 10, host: 100)
        var t = 100.0
        while t < 135 {
            p.host = t
            s.setReference(media: 10 + t - 100, host: t, rate: 1.0)
            s.sample(enqueuedFrontier: p.timebase + 0.400)
            t += 0.02
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            box.lock.lock(); let n = box.facts.count; box.lock.unlock()
            if n >= 3 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        box.lock.lock(); defer { box.lock.unlock() }
        XCTAssertGreaterThanOrEqual(box.facts.count, 3)
        XCTAssertEqual(box.facts[0].rendererDepthMedian ?? 0, 0.400, accuracy: 0.001)
        XCTAssertEqual(box.facts[0].elapsed, 10, accuracy: 0.1)
        XCTAssertEqual(box.logged.filter { $0.contains("steering window") }.count, 0)
        XCTAssertEqual(box.logged.filter { $0.contains("companion") }.count, box.facts.count)
    }
}
