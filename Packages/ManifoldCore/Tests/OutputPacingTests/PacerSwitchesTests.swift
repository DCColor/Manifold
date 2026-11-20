import XCTest
@testable import OutputPacing

/// The 0.9.5 defaults: C+ on with `MANIFOLD_PACER_PHASE` unset (Robbie, 2026-11-19), plain option B on with
/// `MANIFOLD_PACER_PRESENT_TX` unset (Robbie, 2026-11-20, CARD_PULL_MARGIN.md §19–§20); and Export Diagnostics' card-hold rule
/// (`CardHoldFilter`), which must read 0 for a normal session.
final class PacerSwitchesTests: XCTestCase {

    // MARK: MANIFOLD_PACER_PHASE

    func testPhaseModeDefaultsToCPlus() {
        XCTAssertEqual(PacerSwitches.phaseMode(nil), 2, "unset is C+, the 0.9.5 default")
        XCTAssertEqual(PacerSwitches.phaseMode(""), 2)
    }

    func testPhaseModeExplicitValues() {
        XCTAssertEqual(PacerSwitches.phaseMode("0"), 0, "=0 turns the phase hold off")
        XCTAssertEqual(PacerSwitches.phaseMode("1"), 1, "=1 is plain option C")
        XCTAssertEqual(PacerSwitches.phaseMode("2"), 2, "=2 is C+")
    }

    func testPhaseModeUnrecognisedIsTheDefault() {
        for v in ["3", "off", "yes", " 0", "00", "-1"] { XCTAssertEqual(PacerSwitches.phaseMode(v), 2, v) }
    }

    // MARK: MANIFOLD_PACER_PRESENT_TX

    func testPlainBIsTheDefault() {
        XCTAssertTrue(PacerSwitches.presentUntransacted(nil), "unset is plain B, the 0.9.5 default")
        XCTAssertTrue(PacerSwitches.presentUntransacted(""))
        XCTAssertTrue(PacerSwitches.presentUntransacted("0"), "=0 is plain B, as before the default changed")
    }

    func testOnlyOneRestoresTheTransactionalPresent() {
        XCTAssertFalse(PacerSwitches.presentUntransacted("1"), "=1 is the diagnostic off-switch")
    }

    func testPresentTxUnrecognisedIsTheDefault() {
        for v in ["2", "off", "no", " 1", "01", "-1", "true"] { XCTAssertTrue(PacerSwitches.presentUntransacted(v), v) }
    }

    /// The default reaches the gate: with the switch unset the gate keeps a drawable spare at 120 Hz; `=1` is the old gate.
    func testDefaultSwitchSelectsTheSpareDrawableGate() {
        let hz120 = 1.0 / 120
        XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: hz120,
                                                                keepSpareDrawable: PacerSwitches.presentUntransacted(nil)), 1)
        XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: hz120,
                                                                keepSpareDrawable: PacerSwitches.presentUntransacted("1")), 2)
    }

    // MARK: CardHoldFilter

    private let f = 1001.0 / 60000   // 59.94

    /// Feeds pulls one card frame apart from `host`; each entry is (timed, frame index handed). Returns holds confirmed.
    private func run(_ filter: inout CardHoldFilter, from host: Double, _ pulls: [(Bool, Int)], matched: Bool = true) -> Int {
        var total = 0
        for (i, p) in pulls.enumerated() {
            total += filter.pull(host: host + Double(i) * f, timed: p.0, pts: Double(p.1) * f, matched: matched)
        }
        return total
    }

    /// Paused (untimed) then Play: `n` timed pulls handing one new frame each, starting at frame `start`.
    private func play(_ n: Int, start: Int = 100) -> [(Bool, Int)] { (0..<n).map { (true, start + $0) } }

    func testSteadyPlayCountsNothing() {
        var c = CardHoldFilter()
        XCTAssertEqual(run(&c, from: 0, [(false, 99)] + play(600)), 0)
    }

    func testOpeningRepeatsAfterPlayAreNotCounted() {
        // Night 5: the opening repeats came on the 2nd or 3rd timed pull after the untimed one.
        var c = CardHoldFilter()
        let pulls: [(Bool, Int)] = [(false, 100), (true, 100), (true, 100), (true, 100)] + play(300, start: 101)
        XCTAssertEqual(run(&c, from: 0, pulls), 0)
    }

    func testHoldInSteadyPlayIsCountedOnceTheNextFrameArrives() {
        var c = CardHoldFilter()
        XCTAssertEqual(run(&c, from: 0, [(false, 99)] + play(120)), 0)   // 2 s of play: past the settle window
        let t = 121 * f
        XCTAssertEqual(c.pull(host: t, timed: true, pts: 219 * f, matched: true), 0, "the repeat is pending, not yet counted")
        XCTAssertEqual(c.pull(host: t + f, timed: true, pts: 221 * f, matched: true), 1, "a newer frame confirms it (§18.3's hold, skip)")
        XCTAssertEqual(c.pull(host: t + 2 * f, timed: true, pts: 222 * f, matched: true), 0)
    }

    func testEndOfFileRepeatsAreNotCounted() {
        // The clock runs past the last frame, the card repeats it, then the clock stops and the pulls go untimed.
        var c = CardHoldFilter()
        var pulls: [(Bool, Int)] = [(false, 99)] + play(200)
        pulls += Array(repeating: (true, 299), count: 6) + Array(repeating: (false, 299), count: 10)
        XCTAssertEqual(run(&c, from: 0, pulls), 0)
        // And the next Play, from the start, counts nothing either.
        XCTAssertEqual(run(&c, from: 100, play(200, start: 0)), 0)
    }

    func testLoopWrapAndSeekAreNotCounted() {
        // A wrap or a seek is an untimed pull: anything pending is dropped and the settle window restarts.
        var c = CardHoldFilter()
        var pulls: [(Bool, Int)] = [(false, 99)] + play(120)
        pulls += [(true, 219), (false, 0), (true, 0), (true, 0)] + play(120, start: 1)
        XCTAssertEqual(run(&c, from: 0, pulls), 0)
    }

    func testRateMismatchCadenceIsNotCounted() {
        // 25p on 59.94: every few pulls repeat a frame, by design.
        var c = CardHoldFilter()
        var pulls: [(Bool, Int)] = [(false, 0)]
        for i in 0..<600 { pulls.append((true, Int(Double(i) * f * 25))) }
        XCTAssertEqual(run(&c, from: 0, pulls, matched: false), 0)
        var counted = CardHoldFilter()
        XCTAssertGreaterThan(run(&counted, from: 0, pulls, matched: true), 0, "the same repeats at a matched rate would count")
    }

    func testTwoRepeatsOfOneFrameCountTwo() {
        var c = CardHoldFilter()
        _ = run(&c, from: 0, [(false, 99)] + play(120))
        let t = 121 * f
        XCTAssertEqual(c.pull(host: t, timed: true, pts: 219 * f, matched: true), 0)
        XCTAssertEqual(c.pull(host: t + f, timed: true, pts: 219 * f, matched: true), 0)
        XCTAssertEqual(c.pull(host: t + 2 * f, timed: true, pts: 222 * f, matched: true), 2)
    }

    func testNaNFrameNeitherCountsNorConfirms() {
        var c = CardHoldFilter()
        _ = run(&c, from: 0, [(false, 99)] + play(120))
        let t = 121 * f
        XCTAssertEqual(c.pull(host: t, timed: true, pts: 219 * f, matched: true), 0)
        XCTAssertEqual(c.pull(host: t + f, timed: true, pts: .nan, matched: true), 0)
        XCTAssertEqual(c.pull(host: t + 2 * f, timed: true, pts: 222 * f, matched: true), 0, "a NaN pull breaks the timed-after-timed chain")
    }
}
