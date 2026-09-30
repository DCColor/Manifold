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
            let c = check.correction(atVideoTime: t, srOffset: sr, srSlope: appliedSlope)
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
        // The slope check's cadence, log only: the level hold would engage inside 590 s here.
        let early = Check(tag: "[T]", parameters: Self.logOnly)
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

    // MARK: - The level hold (§18.20)

    /// A whole WHEP session through the real fit, closed loop: SR pairs `delta(x)` at 1/s, the
    /// media's true line `media(t)` (offset − depth), the queue following the APPLIED offset through
    /// a first-order loop lag `lag` s, plus `extraDepth(t)` (events the line does not cause). Returns
    /// the log lines and the queue depth per window.
    func session(seconds: Double, delta: @escaping (Double) -> Double, media: (Double) -> Double,
                 depthNoise: Double = 0.001, lag: Double = 0, seed: UInt64 = 3,
                 parameters: SenderReportSlopeCrossCheck.Parameters = .adopted,
                 extraDepth: (Double) -> Double = { _ in 0 }, excluded: (Double) -> Bool = { _ in false },
                 each: ((Double, SenderReportLineFit) -> Void)? = nil)
        -> (lines: [String], depth: [(t: Double, d: Double)], fit: SenderReportLineFit) {
        let sink = LogSink()
        let fit = SenderReportLineFit.make(timeline: .rtpSenderReports, tag: "[TEST-SRFIT]",
                                           reportsWindows: false, crossCheckParameters: parameters,
                                           log: { sink.append($0) })!
        var rng = TestRNG(state: seed)
        var depth: [(Double, Double)] = []
        var lagged: Double?
        var t = 1.0
        while t <= seconds {
            fit.notePair(videoTime: t, delta: delta(t))
            if Int(t) % 10 == 0, let e = fit.evaluate(atVideoTime: t) {
                let a = lag > 0 ? 1 - exp(-10 / lag) : 1
                lagged = lagged.map { $0 + a * (e.offset - $0) } ?? e.offset
                let d = 0.420 + lagged! - media(t) + depthNoise * rng.gaussian() + extraDepth(t)
                depth.append((t, d))
                fit.windowLines(time: t, rendererDepth: d, appliedOffset: e.offset,
                                appliedSlope: e.slope, excluded: excluded(t)).forEach(sink.append)
                each?(t, fit)
            }
            t += 1
        }
        return (sink.all, depth, fit)
    }

    func count(_ lines: [String], _ s: String) -> Int { lines.filter { $0.contains(s) }.count }
    func level(_ r: (lines: [String], depth: [(t: Double, d: Double)], fit: SenderReportLineFit),
               _ a: Double, _ b: Double) -> Double {
        let v = r.depth.filter { $0.t >= a && $0.t <= b }.map(\.d).sorted()
        return v[v.count / 2]
    }
    func noStep(_ r: (lines: [String], depth: [(t: Double, d: Double)], fit: SenderReportLineFit),
                _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for i in 1..<r.depth.count {
            XCTAssertLessThan(abs(r.depth[i].d - r.depth[i - 1].d), 0.006,
                              "\(label) at \(r.depth[i].t)", file: file, line: line)
        }
    }

    /// §18.5's A/B sessions: SRs flat to 7 µs, the media +65 ppm. The SR line alone drains the queue
    /// at 65 ppm; the hold engages once (|E| > 12 ms for 180 s), logs the deviation once, catches up
    /// at ≤ 150 ppm with no target step, and holds the queue at its session-start level.
    func testHoldsTheLevelOnFlatSRs() {
        var rng = TestRNG(state: 71)
        let r = session(seconds: 3600, delta: { _ in -0.020 + 7e-6 * rng.gaussian() },
                        media: { 65e-6 * $0 })
        XCTAssertEqual(count(r.lines, "LEVEL HOLD ENGAGED"), 1)
        XCTAssertEqual(count(r.lines, "RELEASED"), 0)
        XCTAssertEqual(count(r.lines, "SR DEVIATION"), 1)
        XCTAssertTrue(r.fit.crossCheck.isEngaged)
        // The slope is the 300 s line's, refitted every window: it only extrapolates the level for
        // ≤ 10 s, so 10 ppm is 0.1 ms. The level is what is held (below).
        XCTAssertEqual(r.fit.evaluate(atVideoTime: 3600)!.slope, 65e-6, accuracy: 10e-6)
        let start = level(r, 60, 120)
        // Engaged by ~8 min; the worst excursion is the level at engagement (≤ 12 ms + 180 s of
        // drain); back within 2 ms of the start from 20 min on, to the end.
        let worst = r.depth.filter { $0.t >= 120 }.map { abs($0.d - start) }.max()!
        XCTAssertLessThan(worst, 0.030)
        for p in r.depth where p.t >= 1200 { XCTAssertEqual(p.d - start, 0, accuracy: 0.004, "at \(p.t)") }
        XCTAssertEqual(level(r, 3500, 3600) - start, 0, accuracy: 0.002)
        noStep(r, "flat")
    }

    /// No feedback (§18.20's small-gain bound): with the queue following the applied offset through
    /// a loop lag of 0 / 10 / 30 s, the held level stays within 3 ms of the start and does not ring.
    func testTheLoopLagDoesNotDestabiliseTheHold() {
        for lag in [0.0, 10.0, 30.0] {
            var rng = TestRNG(state: 72)
            let r = session(seconds: 3600, delta: { _ in -0.020 + 7e-6 * rng.gaussian() },
                            media: { 65e-6 * $0 }, lag: lag)
            XCTAssertEqual(count(r.lines, "LEVEL HOLD ENGAGED"), 1, "lag \(lag)")
            let start = level(r, 60, 120)
            let late = r.depth.filter { $0.t >= 1500 }.map { $0.d - start }
            XCTAssertLessThan(late.map(abs).max()!, 0.003 + 0.003, "lag \(lag): held level")
            XCTAssertEqual(late.reduce(0, +) / Double(late.count), 0, accuracy: 0.0015, "lag \(lag): mean")
        }
    }

    /// Never engages when the SR line holds the level: Cloudflare-like noise, a staircase that
    /// carries the media's slope, and a clean line — 1 h each, correction exactly 0.
    func testStaysOffWhenTheSRsHoldTheLevel() {
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
            XCTAssertEqual(count(r.lines, "LEVEL HOLD ENGAGED"), 0, label)
            XCTAssertEqual(r.fit.crossCheck.currentMode, .off, label)
            XCTAssertLessThan(abs(r.fit.crossCheck.levelError ?? 1), 0.008, label)
        }
    }

    /// The lagging staircase that unwinds by itself: SRs flat, so the hold engages; at 2400 s they
    /// catch up in one stair onto the media's line THROUGH THE SESSION START (the level they gave at
    /// 60–120 s). E returns inside 4 ms, the hold releases 600 s later and returns to the SR line at
    /// ≤ 150 ppm — nothing kept, no step, and the queue stays on the start.
    func testALaggingStaircaseUnwindsByItself() {
        var rng = TestRNG(state: 91)
        let r = session(seconds: 5400, delta: { x in
            -0.020 + (x < 2400 ? 0 : 65e-6 * (x - 90)) + 7e-6 * rng.gaussian()
        }, media: { 65e-6 * $0 })
        XCTAssertEqual(count(r.lines, "LEVEL HOLD ENGAGED"), 1)
        XCTAssertEqual(count(r.lines, "RELEASED"), 1)
        XCTAssertEqual(count(r.lines, "LEVEL HOLD OFF"), 1)
        XCTAssertEqual(r.fit.crossCheck.currentMode, .off)
        let e = r.fit.evaluate(atVideoTime: 5400)!
        XCTAssertEqual(r.fit.crossCheck.correction(atVideoTime: 5400, srOffset: e.offset, srSlope: e.slope),
                       .init(), "nothing kept")
        let start = level(r, 60, 120)
        for p in r.depth where p.t >= 1200 { XCTAssertEqual(p.d - start, 0, accuracy: 0.006, "at \(p.t)") }
        noStep(r, "staircase catch-up")
    }

    /// §18.9's condition, on the level form: an engagement FORCED on correct SRs costs ≤ 10 ms and
    /// releases by itself, leaving the correction at exactly 0.
    func testAForcedFalseEngagementIsBoundedAndReleases() {
        var p = SenderReportSlopeCrossCheck.Parameters(); p.forceEngageAt = 900
        var n1 = TestRNG(state: 111), n2 = TestRNG(state: 111)
        var w1 = 0.0, w2 = 0.0
        let a = exp(-1.0 / 60)
        func sr(_ n: inout TestRNG, _ w: inout Double, _ x: Double) -> Double {
            w = a * w + (1 - a * a).squareRoot() * 0.002 * n.gaussian()
            return -0.020 + 68e-6 * x + w + 0.0095 * n.gaussian()
        }
        let forced = session(seconds: 5400, delta: { sr(&n1, &w1, $0) }, media: { 68e-6 * $0 }, parameters: p)
        let free = session(seconds: 5400, delta: { sr(&n2, &w2, $0) }, media: { 68e-6 * $0 })
        XCTAssertEqual(count(free.lines, "LEVEL HOLD ENGAGED"), 0)
        XCTAssertEqual(count(forced.lines, "LEVEL HOLD ENGAGED"), 1)
        XCTAssertEqual(count(forced.lines, "LEVEL HOLD OFF"), 1, "released by itself")
        let err = zip(forced.depth, free.depth).map { abs($0.d - $1.d) }
        XCTAssertLessThan(err.max()!, 0.010)
        XCTAssertLessThan(err.last!, 1e-9, "back on the SR line exactly")
    }

    /// No flapping at the threshold: the SR line holds the queue 12 ms off its start, with noise.
    /// At most one engagement over 2 h, and no release (E never comes inside 4 ms).
    func testNoFlappingAtTheThreshold() {
        var rng = TestRNG(state: 101)
        let r = session(seconds: 7200, delta: { x in -0.020 + 66e-6 * x - (x > 150 ? 0.012 : 0)
                                                + 7e-6 * rng.gaussian() },
                        media: { 66e-6 * $0 }, depthNoise: 0.002)
        XCTAssertLessThanOrEqual(count(r.lines, "LEVEL HOLD ENGAGED"), 1)
        XCTAssertEqual(count(r.lines, "RELEASED"), 0)
    }

    /// A deliberate line move (a LiveClock snap / target step of 80 ms) moves the queue by −80 ms.
    /// Told of it, the hold neither engages nor undoes it; the queue stays at the new level.
    func testALineJumpIsKeptNotUndone() {
        var rng = TestRNG(state: 121)
        var told = false
        let r = session(seconds: 3600, delta: { _ in -0.020 + 7e-6 * rng.gaussian() }, media: { _ in 0 },
                        extraDepth: { $0 >= 1200 ? -0.080 : 0 }, each: { t, fit in
            if t >= 1200, !told { told = true; fit.noteLineJump(0.080) }
        })
        XCTAssertEqual(count(r.lines, "LEVEL HOLD ENGAGED"), 0)
        XCTAssertEqual(level(r, 3000, 3600) - level(r, 60, 120), -0.080, accuracy: 0.002)
    }

    /// Windows the steering marks excluded (a starvation hold and its recovery: here the queue 300
    /// ms low for 60 s) are not read: no engagement, and the level is unmoved.
    func testExcludedWindowsAreNotRead() {
        var rng = TestRNG(state: 131)
        let stall: (Double) -> Bool = { $0 >= 1200 && $0 < 1260 }
        let r = session(seconds: 3600, delta: { x in -0.020 + 60e-6 * x + 7e-6 * rng.gaussian() },
                        media: { 60e-6 * $0 }, extraDepth: { stall($0) ? -0.300 : 0 }, excluded: stall)
        XCTAssertEqual(count(r.lines, "LEVEL HOLD ENGAGED"), 0)
        XCTAssertLessThan(abs(r.fit.crossCheck.levelError ?? 1), 0.004)
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
        XCTAssertFalse(box.facts[0].excluded, "a healthy window is read by the level hold")
        XCTAssertEqual(box.logged.filter { $0.contains("steering window") }.count, 0)
        XCTAssertEqual(box.logged.filter { $0.contains("companion") }.count, box.facts.count)
    }
}
