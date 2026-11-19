import XCTest
@testable import OutputPacing

/// C+ (docs/CARD_PULL_MARGIN.md §17.3; `MANIFOLD_PACER_PHASE=2`): the lead computation, the choice of x_ref inside the guard band,
/// the band's edges at k = 2 and k = 3, and the follower moving its reference with the no-crossing property kept. Option C (=1,
/// `leadGuard` false) must be unchanged by a pull phase.
final class PacerLeadTests: XCTestCase {
    private let quantum = 1.0 / 24_000_000            // one mach tick on Apple silicon
    private let p5994 = 1001.0 / 60000 / 2             // 8.3417 ms, k 2
    private let p2398 = 1001.0 / 24000 / 3             // 13.9028 ms, k 3
    private let p25 = 1.0 / 25 / 3                     // 13.3333 ms, k 3

    // MARK: lead computation

    func testPullPhaseIsLeadPlusX() {
        // §17.1: lead = A − x − c, so lead + x is the same for every frame of a Play.
        let pp = PacerPhase.pullPhase(pullHost: 100.020, publishHost: 100.013, x: 0.003)!
        XCTAssertEqual(pp, 0.010, accuracy: 1e-12)
        XCTAssertEqual(PacerPhase.lead(x: 0.003, pullPhase: pp), 0.007, accuracy: 1e-12)
        // A frame of the same Play with another x gives the same pull phase.
        XCTAssertEqual(PacerPhase.pullPhase(pullHost: 200.020, publishHost: 200.015, x: 0.005)!, pp, accuracy: 1e-12)
    }

    func testPullPhaseRejectsBadReadings() {
        XCTAssertNil(PacerPhase.pullPhase(pullHost: .nan, publishHost: 1, x: 0.001))
        XCTAssertNil(PacerPhase.pullPhase(pullHost: 1, publishHost: .nan, x: 0.001))   // a slot with no publish host recorded
        XCTAssertNil(PacerPhase.pullPhase(pullHost: 1, publishHost: 1, x: .nan))       // a slot with no tick x recorded
        XCTAssertNil(PacerPhase.pullPhase(pullHost: 1.000, publishHost: 1.001, x: 0.001)) // published after the pull: impossible
        XCTAssertEqual(PacerPhase.pullPhase(pullHost: 1, publishHost: 1, x: 0.002)!, 0.002, accuracy: 1e-12)   // lead 0 is valid
    }

    // MARK: the choice inside the band

    func testEnoughLeadIsNeverMovedLater() {
        // 59.94: pull phase 20 ms, x_ref 4 ms → lead 16 ms ≥ P + 0.5: unchanged (C+ only ever moves earlier).
        let r = PacerPhase.leadReference(xRef: 0.004, pullPhase: 0.020, period: p5994)
        XCTAssertEqual(r.value, 0.004); XCTAssertTrue(r.reachesSlack)
    }

    func testShortLeadMovesEarlierToPPlusSlack() {
        // 59.94: pull phase 15 ms, x_ref 7.5 ms → lead 7.5 ms < P: x_ref → 15 − 8.3417 − 0.5 = 6.158 ms, lead exactly P + 0.5.
        let r = PacerPhase.leadReference(xRef: 0.0075, pullPhase: 0.015, period: p5994)
        XCTAssertEqual(r.value, 0.015 - p5994 - 0.0005, accuracy: 1e-12)
        XCTAssertTrue(r.reachesSlack)
        XCTAssertEqual(PacerPhase.lead(x: r.value, pullPhase: 0.015), p5994 + PacerPhase.leadSlack, accuracy: 1e-12)
    }

    func testTheBandsLowEdgeStopsTheMove() {
        // 59.94, the worst Play: A = G = 10.0 ms, c 0.75 → pull phase 9.25 ms. Wanted x = 0.408 ms < 0.5: x_ref stops at 0.5 ms,
        // which still gives lead 8.75 ms > P (§17.3: the two margins share 0.91 ms there).
        let r = PacerPhase.leadReference(xRef: 0.007, pullPhase: 0.00925, period: p5994)
        XCTAssertEqual(r.value, PacerPhase.guardMargin, accuracy: 1e-12)
        XCTAssertFalse(r.reachesSlack)
        XCTAssertGreaterThan(PacerPhase.lead(x: r.value, pullPhase: 0.00925), p5994)
        // A pull phase so short that even 0.5 ms cannot reach P: still the edge, never below it.
        let r2 = PacerPhase.leadReference(xRef: 0.003, pullPhase: 0.004, period: p5994)
        XCTAssertEqual(r2.value, PacerPhase.guardMargin, accuracy: 1e-12); XCTAssertFalse(r2.reachesSlack)
        // Exactly at the edge: reaches.
        let r3 = PacerPhase.leadReference(xRef: 0.003, pullPhase: PacerPhase.guardMargin + p5994 + PacerPhase.leadSlack, period: p5994)
        XCTAssertEqual(r3.value, PacerPhase.guardMargin, accuracy: 1e-12); XCTAssertTrue(r3.reachesSlack)
    }

    func testAReferenceAlreadyBelowTheEdgeIsNeverRaised() {
        let r = PacerPhase.leadReference(xRef: 0.0003, pullPhase: 0.004, period: p5994)
        XCTAssertEqual(r.value, 0.0003, accuracy: 1e-12); XCTAssertFalse(r.reachesSlack)
    }

    func testBadInputsLeaveTheReference() {
        for (pp, per) in [(Double.nan, p5994), (.infinity, p5994), (0.015, 0), (0.015, -1), (0.015, .nan)] {
            let r = PacerPhase.leadReference(xRef: 0.005, pullPhase: pp, period: per)
            XCTAssertEqual(r.value, 0.005); XCTAssertTrue(r.reachesSlack)
        }
    }

    func testK3Rates() {
        // 23.976 (P 13.90): pull phase 20 ms, x_ref 9 ms → lead 11 ms: moved to 20 − 13.9028 − 0.5 = 5.597 ms.
        let a = PacerPhase.leadReference(xRef: 0.009, pullPhase: 0.020, period: p2398)
        XCTAssertEqual(a.value, 0.020 - p2398 - 0.0005, accuracy: 1e-12); XCTAssertTrue(a.reachesSlack)
        // 23.976, A near G (3.05 ms) → pull phase 2.2 ms: no x in the band reaches the slack; the edge, and only earlier.
        let b = PacerPhase.leadReference(xRef: 0.001, pullPhase: 0.0022, period: p2398)
        XCTAssertEqual(b.value, PacerPhase.guardMargin, accuracy: 1e-12); XCTAssertFalse(b.reachesSlack)
        // 25 (P 13.33): the card a frame behind (pull phase ≈ F + something): lead already large, unchanged.
        let c = PacerPhase.leadReference(xRef: 0.012, pullPhase: 0.045, period: p25)
        XCTAssertEqual(c.value, 0.012); XCTAssertTrue(c.reachesSlack)
        // 25: the band's edge is min(0.5 ms, P / 2), the same rule as the guard's.
        let d = PacerPhase.leadReference(xRef: 0.010, pullPhase: 0.010, period: p25)
        XCTAssertEqual(d.value, 0.0005, accuracy: 1e-12); XCTAssertFalse(d.reachesSlack)
    }

    // MARK: the follower

    /// Drive a follower: `u` the uncorrected phase (x = u + applied), a constant pull phase, k ticks per frame.
    private func run(_ f: inout PacerPhaseFollower, u: Double, pullPhase: Double?, period: Double, k: Int, frames: Int,
                     xs: inout [Double], moves: inout [Double]) {
        for _ in 0..<frames {
            let x = u + f.applied
            xs.append(x)
            let r = f.tick(.active(x: x), period: period, pullPhase: pullPhase)
            if case .leadGuard? = r.event {} // logged by the pacer
            if r.correction != 0, f.leadGuard { moves.append(Double(r.correction) * quantum) }
            for _ in 1..<k {
                let r2 = f.tick(.active(x: nil), period: period, pullPhase: pullPhase)
                if r2.correction != 0, f.leadGuard { moves.append(Double(r2.correction) * quantum) }
            }
        }
    }

    func testLeadGuardMovesTheReferenceEarlierInBoundedStepsAt5994() {
        // x settles at 7.5 ms, pull phase 15 ms (lead 7.5 ms, exposed). C+ moves x_ref to 6.158 ms in steps of ≤ 0.5 ms, x follows,
        // the lead ends at P + 0.5, and no x ever leaves the guard band.
        var f = PacerPhaseFollower(quantum: quantum, leadGuard: true)
        var xs: [Double] = [], moves: [Double] = []
        run(&f, u: 0.0075, pullPhase: 0.015, period: p5994, k: 2, frames: 200, xs: &xs, moves: &moves)
        let target = 0.015 - p5994 - PacerPhase.leadSlack
        XCTAssertEqual(f.reference!, target, accuracy: 2 * quantum)
        XCTAssertEqual(xs.last!, target, accuracy: 2 * quantum)
        XCTAssertGreaterThanOrEqual(PacerPhase.lead(x: xs.last!, pullPhase: 0.015), p5994 + PacerPhase.leadSlack - 2 * quantum)
        XCTAssertTrue(moves.allSatisfy { $0 < 0 && $0 >= -PacerPhase.guardMargin - quantum }, "\(moves)")
        XCTAssertEqual(f.run.leadMoves, 3)                              // 1.342 ms in steps of 0.5, 0.5, 0.342
        XCTAssertTrue(xs.allSatisfy { $0 >= PacerPhase.guardMargin - 1e-9 && $0 <= p5994 - PacerPhase.guardMargin + 1e-9 })
        XCTAssertTrue(f.report(run: true).contains("lead moves 3 (net -1.342 ms)"), f.report(run: true))
    }

    func testLeadGuardAtTheEdgeKeepsTheNoCrossingProperty() {
        // The worst 59.94 Play (pull phase 9.25 ms), x_ref 7.8 ms: moved to 0.5 ms, never below, never across 0.
        var f = PacerPhaseFollower(quantum: quantum, leadGuard: true)
        var xs: [Double] = [], moves: [Double] = []
        run(&f, u: 0.0078, pullPhase: 0.00925, period: p5994, k: 2, frames: 400, xs: &xs, moves: &moves)
        XCTAssertEqual(f.reference!, PacerPhase.guardMargin, accuracy: 2 * quantum)
        XCTAssertGreaterThanOrEqual(xs.min()!, PacerPhase.guardMargin - 2 * quantum)
        XCTAssertTrue(xs.allSatisfy { $0 > 0 && $0 < p5994 })
        XCTAssertEqual(f.run.leadMoves, 15)                             // 7.3 ms in steps of ≤ 0.5 ms
    }

    func testLeadGuardAtK3() {
        // 23.976: x 9 ms, pull phase 20 ms → x_ref 5.597 ms.
        var f = PacerPhaseFollower(quantum: quantum, leadGuard: true)
        var xs: [Double] = [], moves: [Double] = []
        run(&f, u: 0.009, pullPhase: 0.020, period: p2398, k: 3, frames: 200, xs: &xs, moves: &moves)
        XCTAssertEqual(f.reference!, 0.020 - p2398 - PacerPhase.leadSlack, accuracy: 2 * quantum)
        XCTAssertTrue(xs.allSatisfy { $0 >= PacerPhase.guardMargin - 1e-9 && $0 <= p2398 - PacerPhase.guardMargin + 1e-9 })
    }

    func testEnoughLeadOrNoPullPhaseMovesNothing() {
        for pp: Double? in [0.020, nil] {
            var f = PacerPhaseFollower(quantum: quantum, leadGuard: true)
            var xs: [Double] = [], moves: [Double] = []
            run(&f, u: 0.004, pullPhase: pp, period: p5994, k: 2, frames: 100, xs: &xs, moves: &moves)
            XCTAssertEqual(f.run.leadMoves, 0); XCTAssertTrue(moves.isEmpty)
            XCTAssertEqual(f.reference!, 0.004, accuracy: 1e-12)
        }
    }

    func testOptionCIgnoresThePullPhase() {
        // =1: `leadGuard` false. The same exposed Play as above: the reference stays where Play put it, every correction is the
        // follow's (none here), and the report has no lead suffix: option C exactly.
        var c = PacerPhaseFollower(quantum: quantum)
        var plain = PacerPhaseFollower(quantum: quantum)
        for _ in 0..<200 {
            let a = c.tick(.active(x: 0.0075 + c.applied), period: p5994, pullPhase: 0.015)
            let b = plain.tick(.active(x: 0.0075 + plain.applied), period: p5994)
            XCTAssertEqual(a.correction, b.correction); XCTAssertEqual(a.event, b.event)
            _ = c.tick(.active(x: nil), period: p5994, pullPhase: 0.015); _ = plain.tick(.active(x: nil), period: p5994)
        }
        XCTAssertEqual(c.reference, plain.reference)
        XCTAssertEqual(c.run, plain.run)
        XCTAssertFalse(c.report(run: true).contains("lead moves"))
    }

    func testAResetDropsAMoveInProgress() {
        var f = PacerPhaseFollower(quantum: quantum, leadGuard: true)
        for _ in 0..<8 { _ = f.tick(.active(x: 0.0078), period: p5994, pullPhase: 0.00925) }   // reference set at 7.8 ms
        let first = f.tick(.active(x: nil), period: p5994, pullPhase: 0.00925)                 // the first 0.5 ms step
        XCTAssertLessThan(first.correction, 0)
        if case .leadGuard(_, let from, let to, let reaches)? = first.event {
            XCTAssertEqual(from, 0.0078, accuracy: 1e-12); XCTAssertEqual(to, PacerPhase.guardMargin, accuracy: 1e-12); XCTAssertFalse(reaches)
        } else { XCTFail("no lead-guard event") }
        _ = f.tick(.inactive, period: p5994, pullPhase: nil)                                   // a pause: everything dropped
        XCTAssertNil(f.reference)
        let after = f.tick(.active(x: nil), period: p5994, pullPhase: 0.00925)
        XCTAssertEqual(after.correction, 0)                                                     // no step without a reference
    }
}
