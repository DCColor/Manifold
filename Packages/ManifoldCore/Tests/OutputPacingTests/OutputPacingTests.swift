import XCTest
@testable import OutputPacing

/// The pacer's rate (docs/DISPLAY_LINK_PER_WINDOW_PLAN.md §4.4, the table) and the interval statistics its log reads.
final class OutputPacingTests: XCTestCase {
    private func check(_ fps: Double, k: Int, periodMs: Double, file: StaticString = #filePath, line: UInt = #line) {
        let r = OutputPacerTiming.period(cardFrame: 1 / fps, sourceFrame: 1 / fps)
        XCTAssertEqual(r?.ticksPerFrame, k, file: file, line: line)
        XCTAssertEqual((r?.period ?? 0) * 1000, periodMs, accuracy: 0.005, file: file, line: line)
    }

    func testThePlanTable() {
        check(24000.0 / 1001, k: 3, periodMs: 13.90)
        check(25, k: 3, periodMs: 13.33)
        check(30000.0 / 1001, k: 3, periodMs: 11.12)
        check(60000.0 / 1001, k: 2, periodMs: 8.34)
        check(100, k: 2, periodMs: 5.00)
        check(120000.0 / 1001, k: 2, periodMs: 4.17)
    }

    func testExactSixtyIsTwoTicksNotThree() {
        // 1/60 × 60 = 1 in exact arithmetic: k = max(2, 1) = 2, not 2 from a rounding-up of 1.0000000002.
        XCTAssertEqual(OutputPacerTiming.period(cardFrame: 1.0 / 60, sourceFrame: 0)?.ticksPerFrame, 2)
        XCTAssertEqual(OutputPacerTiming.period(cardFrame: 1.0 / 30, sourceFrame: 0)?.ticksPerFrame, 2)
        XCTAssertEqual(OutputPacerTiming.period(cardFrame: 1.0 / 50, sourceFrame: 0)?.ticksPerFrame, 2)
    }

    func testTheShorterFrameWinsAndEveryRateIsAtLeastSixtyTicks() {
        // A 59.94 file into a 23.98 output: paced by the file's frames, so none is superseded.
        let r = OutputPacerTiming.period(cardFrame: 1001.0 / 24000, sourceFrame: 1001.0 / 60000)
        XCTAssertEqual(r?.period ?? 0, 1001.0 / 120000, accuracy: 1e-12)
        for fps in [1.0, 12, 15, 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 72, 96, 100, 119.88, 120] {
            let p = OutputPacerTiming.period(cardFrame: 1 / fps, sourceFrame: 0)!
            XCTAssertLessThanOrEqual(p.period, 1 / OutputPacerTiming.minimumTickRate + 1e-12, "\(fps)")
            XCTAssertGreaterThanOrEqual(p.ticksPerFrame, 2, "\(fps)")
            XCTAssertEqual(p.period * Double(p.ticksPerFrame), 1 / fps, accuracy: 1e-12, "\(fps)")
        }
    }

    func testUnknownRates() {
        XCTAssertNil(OutputPacerTiming.period(cardFrame: 0, sourceFrame: 0))
        XCTAssertNil(OutputPacerTiming.period(cardFrame: .nan, sourceFrame: -1))
        XCTAssertEqual(OutputPacerTiming.period(cardFrame: 0, sourceFrame: 1.0 / 25)?.ticksPerFrame, 3)
    }

    func testIntervalStats() {
        var s = IntervalStats()
        XCTAssertTrue(s.median.isNaN)
        XCTAssertEqual(s.summary, "n=0")
        for _ in 0..<98 { s.add(0.00834) }
        s.add(0.0120)
        s.add(0.0250)
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.median, 0.00835, accuracy: 1e-9)   // the bin's upper edge
        XCTAssertEqual(s.p99, 0.01201, accuracy: 1e-9)
        XCTAssertEqual(s.maximum, 0.0250)
        s.add(0.5)                                            // overflow bin: the exact maximum
        XCTAssertEqual(s.quantile(1), 0.5)
        s.add(.nan); s.add(-1)
        XCTAssertEqual(s.count, 101)
        s.reset()
        XCTAssertEqual(s.count, 0)
    }
}

/// The window's present gate and frame selection (docs/BUGS.md, the two window-side entries of 2026-11-01).
final class WindowPresentTimingTests: XCTestCase {
    func testASecondWaitingPresentOnlyAboveSixtyHertz() {
        XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: 1 / 59.936), 1)
        XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: 1 / 60.0), 1)
        XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: 1 / 100.0), 2)
        XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: 1 / 120.0), 2)
        XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: 0), 1)
        XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: .nan), 1)
    }

    func testARunningClockIsCarriedToTheGlass() {
        let t = WindowPresentTiming.selectionTime(clock: 10.0, clockHost: 500.0, glassHost: 500.025,
                                                  previous: (clock: 9.98332, host: 499.98332))
        XCTAssertEqual(t, 10.025, accuracy: 1e-9)
    }

    func testJitterInTheCallbackDoesNotMoveTheSelection() {
        // The same vsync, the callback 0.2 ms or 1.8 ms after it: the clock is read later, the lead is shorter, and the
        // selection time is the clock at the glass either way.
        let early = WindowPresentTiming.selectionTime(clock: 10.0002, clockHost: 500.0002, glassHost: 500.0334,
                                                      previous: (clock: 9.9835, host: 499.9835))
        let late = WindowPresentTiming.selectionTime(clock: 10.0018, clockHost: 500.0018, glassHost: 500.0334,
                                                     previous: (clock: 9.9835, host: 499.9835))
        XCTAssertEqual(early, late, accuracy: 1e-9)
        XCTAssertEqual(early, 10.0334, accuracy: 1e-9)
    }

    func testPausedSteppedSeekedOrShuttledSelectsAtTheTick() {
        let glass = 500.025
        // Paused: the clock did not move.
        XCTAssertEqual(WindowPresentTiming.selectionTime(clock: 10, clockHost: 500, glassHost: glass,
                                                         previous: (clock: 10, host: 499.983)), 10)
        // A seek: the clock jumped.
        XCTAssertEqual(WindowPresentTiming.selectionTime(clock: 42, clockHost: 500, glassHost: glass,
                                                         previous: (clock: 10, host: 499.983)), 42)
        // A shuttle at 2×.
        XCTAssertEqual(WindowPresentTiming.selectionTime(clock: 10.034, clockHost: 500, glassHost: glass,
                                                         previous: (clock: 10, host: 499.983)), 10.034)
        // No previous reading.
        XCTAssertEqual(WindowPresentTiming.selectionTime(clock: 10, clockHost: 500, glassHost: glass, previous: nil), 10)
    }

    func testAPacerTickOrABadLeadSelectsAtTheTick() {
        let prev = (clock: 9.983, host: 499.983)
        XCTAssertEqual(WindowPresentTiming.selectionTime(clock: 10, clockHost: 500, glassHost: nil, previous: prev), 10)
        XCTAssertEqual(WindowPresentTiming.selectionTime(clock: 10, clockHost: 500, glassHost: 499.99, previous: prev), 10)
        XCTAssertEqual(WindowPresentTiming.selectionTime(clock: 10, clockHost: 500, glassHost: 500.2, previous: prev), 10)
        // An unanchored live clock (−∞) stays −∞: nothing is due.
        XCTAssertEqual(WindowPresentTiming.selectionTime(clock: -.infinity, clockHost: 500, glassHost: 500.02,
                                                         previous: prev), -.infinity)
    }
}
