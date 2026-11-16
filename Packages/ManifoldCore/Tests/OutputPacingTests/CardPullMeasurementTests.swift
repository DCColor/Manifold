import XCTest
@testable import OutputPacing

/// The card-pull measurement build's pure pieces (docs/CARD_PULL_MARGIN.md, *Measurement build*): the forced-late-swap switch's
/// parser, the pull's outcome, the late-swap baseline and classifier, and the slope fit.
final class CardPullMeasurementTests: XCTestCase {

    // MARK: Parser

    func testParseDefaultsToOneTick() {
        XCTAssertEqual(LateSwapSchedule.parse("120"), [LateSwapEntry(at: 120, mode: .ticks(1))])
    }

    func testParseTicksAndPublishDelay() {
        XCTAssertEqual(LateSwapSchedule.parse("120,247:2,374:ms6"), [
            LateSwapEntry(at: 120, mode: .ticks(1)),
            LateSwapEntry(at: 247, mode: .ticks(2)),
            LateSwapEntry(at: 374, mode: .publishDelay(0.006)),
        ])
    }

    func testParseKeepsOrderAndTrimsSpaces() {
        XCTAssertEqual(LateSwapSchedule.parse(" 30.5 : 3 , 10:ms0.5"), [
            LateSwapEntry(at: 30.5, mode: .ticks(3)),
            LateSwapEntry(at: 10, mode: .publishDelay(0.0005)),
        ])
    }

    func testParseDropsWhatDoesNotParse() {
        // Empty, garbage, negative, non-finite, zero ticks, too many ticks, zero or over-long delay, an extra field.
        XCTAssertEqual(LateSwapSchedule.parse(""), [])
        XCTAssertEqual(LateSwapSchedule.parse("abc,-1,nan,inf,5:0,5:17,5:ms0,5:ms1001,5:2:3,5:x,5:ms"), [])
        XCTAssertEqual(LateSwapSchedule.parse("abc,7,5:0"), [LateSwapEntry(at: 7, mode: .ticks(1))])
    }

    func testParseBounds() {
        XCTAssertEqual(LateSwapSchedule.parse("1:16,2:ms1000"), [
            LateSwapEntry(at: 1, mode: .ticks(16)),
            LateSwapEntry(at: 2, mode: .publishDelay(1.0)),
        ])
    }

    // MARK: Pull outcome

    private let f = 1001.0 / 24000

    func testUntimedAndPaused() {
        XCTAssertEqual(PullOutcome.branch(timed: false, clockMoved: true, handed: 5, previous: 4, target: .nan, ring: []), .untimed)
        XCTAssertEqual(PullOutcome.branch(timed: false, clockMoved: false, handed: 5, previous: 5, target: .nan, ring: []), .paused)
    }

    func testHeldIsARepeat() {
        XCTAssertEqual(PullOutcome.branch(timed: true, clockMoved: true, handed: 10, previous: 10, target: 10.03, ring: [10, 9.9]), .held)
    }

    func testDue() {
        let ring = [10.0, 10 + f, 10 - f, .nan]
        XCTAssertEqual(PullOutcome.branch(timed: true, clockMoved: true, handed: 10 + f, previous: 10, target: 10 + f + 0.005,
                                          ring: ring), .due)
    }

    func testNextByBand() {
        // The 0.9.4 hold Play: the handed frame sat 12 ms past the target, taken inside the half-frame band.
        XCTAssertEqual(PullOutcome.branch(timed: true, clockMoved: true, handed: 10 + f, previous: 10, target: 10 + f - 0.012,
                                          ring: [10, 10 + f]), .nextByBand)
    }

    func testWouldSkip() {
        // Two newer frames due; the rule took the first of them.
        XCTAssertEqual(PullOutcome.branch(timed: true, clockMoved: true, handed: 10 + f, previous: 10, target: 10 + 2 * f + 0.001,
                                          ring: [10, 10 + f, 10 + 2 * f]), .wouldSkip)
    }

    func testEarliestWithNoFloor() {
        XCTAssertEqual(PullOutcome.branch(timed: true, clockMoved: true, handed: 3, previous: .nan, target: 2.9, ring: [3, 3 + f]),
                       .earliest)
    }

    // MARK: Late-swap baseline

    func testBaselineNeedsItsMinimumAndFlagsHalfATickAbove() {
        var b = LateSwapBaseline(window: 48, minimum: 8)
        let p = 0.0139
        for _ in 0..<8 { XCTAssertFalse(b.observe(0.001, period: p).late) }
        XCTAssertFalse(b.observe(0.001 + p / 2 - 1e-6, period: p).late)
        let r = b.observe(0.001 + p + 0.0009, period: p)   // a crossing: one tick later
        XCTAssertTrue(r.late)
        XCTAssertEqual(r.baseline, 0.001, accuracy: 1e-12)
    }

    func testBaselineFollowsANewClusterAfterTheWindow() {
        var b = LateSwapBaseline(window: 48, minimum: 8)
        let p = 0.0083
        for _ in 0..<48 { _ = b.observe(0.001, period: p) }
        var late = 0
        for _ in 0..<100 { if b.observe(0.001 + p, period: p).late { late += 1 } }
        // Late until the 10th percentile of the last 48 has moved up: 48 − 4 = 44 of them (the lowest five must leave).
        XCTAssertEqual(late, 44)
        b.reset()
        XCTAssertEqual(b.count, 0)
        XCTAssertFalse(b.observe(1.0, period: p).late)
    }

    func testBaselineIgnoresNonFinite() {
        var b = LateSwapBaseline()
        XCTAssertFalse(b.observe(.nan, period: 0.01).late)
        XCTAssertEqual(b.count, 0)
    }

    // MARK: Classifier

    private func evidence(pts: Double = 100, period: Double = 0.0139, tick: Double = 100.0139 + 0.00005,
                          prevTick: Double = 100 - 0.00005, prevHost: Double = 50, enqueue: Double = 49,
                          ring: Double = 0.0009, interval: Double = 0.0139, main: Double = 0.002) -> LateSwapEvidence {
        LateSwapEvidence(pts: pts, period: period, tickClock: tick, previousTickClock: prevTick, previousTickHost: prevHost,
                         enqueueHost: enqueue, tickToRing: ring, intervalBefore: interval, mainLag: main)
    }

    func testCrossing() {
        XCTAssertEqual(LateSwapClassifier.classify(evidence()), .crossing)
    }

    func testCrossingWindowEdge() {
        XCTAssertEqual(LateSwapClassifier.classify(evidence(prevTick: 100 - 0.0002)), .crossing)
        XCTAssertEqual(LateSwapClassifier.classify(evidence(prevTick: 100 - 0.0003)), .other)
    }

    func testDecodeWhenDueButNotQueued() {
        XCTAssertEqual(LateSwapClassifier.classify(evidence(prevTick: 100.004, enqueue: 50.001)), .decode)
        XCTAssertEqual(LateSwapClassifier.classify(evidence(prevTick: 100.004, enqueue: .nan)), .decode)
        // Due and queued in time: not decode; nothing else fits.
        XCTAssertEqual(LateSwapClassifier.classify(evidence(prevTick: 100.004, enqueue: 49)), .other)
    }

    func testPacerComesFirst() {
        XCTAssertEqual(LateSwapClassifier.classify(evidence(prevTick: 100.004, enqueue: .nan, interval: 0.0139 * 1.6)), .pacer)
    }

    func testRender() {
        // Tick 3 ms after due, ring 11.5 ms later: past the next tick boundary (13.9 − 3 = 10.9).
        XCTAssertEqual(LateSwapClassifier.classify(evidence(tick: 100.003, prevTick: 99.99, ring: 0.0115)), .render)
        XCTAssertEqual(LateSwapClassifier.classify(evidence(tick: 100.003, prevTick: 99.99, ring: 0.0100)), .other)
    }

    func testMain() {
        XCTAssertEqual(LateSwapClassifier.classify(evidence(prevTick: 99.99, main: 0.02)), .main)
    }

    // MARK: Slope

    func testSlopeAboutALargeOrigin() {
        var s = SlopeFit()
        XCTAssertTrue(s.slope.isNaN)
        // A content clock 11 ppm slow against a host near 184,000 s.
        for i in 0..<1000 {
            let h = 184_046.0 + Double(i) * 0.0417
            s.add(x: h, y: 986.0 + (h - 184_046.0) * (1 - 11e-6))
        }
        XCTAssertEqual((s.slope - 1) * 1e6, -11, accuracy: 0.01)
        XCTAssertEqual(s.count, 1000)
    }
}
