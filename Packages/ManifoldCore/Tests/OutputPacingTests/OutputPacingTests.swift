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
