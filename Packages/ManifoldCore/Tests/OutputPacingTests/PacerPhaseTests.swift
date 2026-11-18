import XCTest
@testable import OutputPacing

/// Option C, the output pacer's phase held against the frame grid (docs/CARD_PULL_MARGIN.md §7 C): the pure arithmetic the pacer
/// runs with `MANIFOLD_PACER_PHASE=1`, and the switch-off identity it must keep.
final class PacerPhaseTests: XCTestCase {
    // MARK: nextDeadline

    func testZeroCorrectionIsExactlyPreviousPlusStep() {
        // The switch-off arithmetic is `deadline += step`; with a zero correction the function must be the same expression.
        let steps: [UInt64] = [1, 200_208, 333_667, 1_000_000_000, UInt64(Int64.max) + 7]
        let previous: [UInt64] = [0, 1, 123_456_789_012, 9_000_000_000_000_000, UInt64.max - UInt64(Int64.max) - 8]
        for p in previous { for s in steps { XCTAssertEqual(PacerPhase.nextDeadline(previous: p, step: s, correction: 0), p + s) } }
    }

    func testCorrectionSign() {
        // Positive: the next tick later (x grows). Negative: earlier.
        XCTAssertEqual(PacerPhase.nextDeadline(previous: 1_000, step: 200, correction: 5), 1_205)
        XCTAssertEqual(PacerPhase.nextDeadline(previous: 1_000, step: 200, correction: -5), 1_195)
    }

    func testCorrectionNeverStopsOrReversesTheTicks() {
        // A correction of a whole step or more (never produced: the clamp is 20 µs against a step of ≥ 4 ms) still moves the
        // deadline forward by one unit: the pacer's next wait can never be in the past by construction, nor wrap.
        XCTAssertEqual(PacerPhase.nextDeadline(previous: 1_000, step: 200, correction: -200), 1_001)
        XCTAssertEqual(PacerPhase.nextDeadline(previous: 1_000, step: 200, correction: -10_000), 1_001)
        XCTAssertEqual(PacerPhase.nextDeadline(previous: 1_000, step: 200, correction: Int64.min), 1_001)
        XCTAssertEqual(PacerPhase.nextDeadline(previous: 0, step: 200, correction: -199), 1)
    }

    func testCorrectionSaturatesInsteadOfWrapping() {
        XCTAssertEqual(PacerPhase.nextDeadline(previous: UInt64.max - 100, step: 200, correction: 1), UInt64.max)
        XCTAssertEqual(PacerPhase.nextDeadline(previous: 1_000, step: UInt64(Int64.max), correction: Int64.max), 1_000 + UInt64(Int64.max))
        XCTAssertEqual(PacerPhase.nextDeadline(previous: UInt64.max - 5, step: 1, correction: Int64.max), UInt64.max)
    }

    // MARK: phaseCorrection

    func testDisabledReturnsZero() {
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: false, phase: 0.003, reference: 0.001), 0)
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: false, phase: 0.001, reference: 0.003), 0)
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: nil, reference: 0.001), 0)
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: 0.001, reference: nil), 0)
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: .nan, reference: 0.001), 0)
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: 0.001, reference: .infinity), 0)
    }

    func testCorrectionSignAndClamp() {
        // x̄ above x_ref (the tick has drifted later against its frame): move the next tick earlier.
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: 0.003005, reference: 0.003), -5e-6, accuracy: 1e-12)
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: 0.002995, reference: 0.003), 5e-6, accuracy: 1e-12)
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: 0.003, reference: 0.003), 0)
        // Clamped at ±20 µs, both signs; exactly at the clamp passes through.
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: 0.004, reference: 0.003), -20e-6)
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: 0.002, reference: 0.003), 20e-6)
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: 0.00302, reference: 0.003), -20e-6, accuracy: 1e-12)
        XCTAssertEqual(PacerPhase.phaseCorrection(enabled: true, phase: 0.00298, reference: 0.003), 20e-6, accuracy: 1e-12)
    }

    // MARK: reference and guard

    private func eight(_ v: Double) -> [Double] { Array(repeating: v, count: 8) }

    func testReferenceIsTheMedianOfTheFirstEight() {
        let r = PacerPhase.reference(firstTicks: [3, 1, 4, 1, 5, 9, 2, 6, 99].map { $0 / 1000 }, period: 0.0139)
        // The first eight sorted: 1 1 2 3 4 5 6 9 → (3 + 4) / 2; the ninth is not used.
        XCTAssertEqual(r?.value ?? 0, 0.0035, accuracy: 1e-12)
        XCTAssertEqual(r?.guarded, PacerPhase.Guard.none)
        XCTAssertNil(PacerPhase.reference(firstTicks: [0.001, 0.002], period: 0.0139))
        XCTAssertNil(PacerPhase.reference(firstTicks: eight(0.001), period: 0))
    }

    func testGuardAtTheLowEdge() {
        let p = 0.01390
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(0.0002), period: p)?.value, 0.0005)
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(0.0002), period: p)?.guarded, .raised)
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(0.0002), period: p)?.median, 0.0002)
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(0), period: p)?.guarded, .raised)
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(0.000499), period: p)?.guarded, .raised)
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(0.0005), period: p)?.guarded, PacerPhase.Guard.none)
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(0.0005), period: p)?.value, 0.0005)
    }

    func testGuardAtTheHighEdge() {
        let p = 1001.0 / 120_000   // 59.94 at k 2: 8.34 ms
        let high = p - 0.0005
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(high), period: p)?.guarded, PacerPhase.Guard.none)
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(high + 1e-6), period: p)?.guarded, .lowered)
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(high + 1e-6), period: p)?.value ?? 0, high, accuracy: 1e-15)
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(p - 1e-9), period: p)?.guarded, .lowered)
    }

    func testGuardOnATickShorterThanTwoMargins() {
        // Not a real pacer rate; the guard must still give a value inside the tick.
        let r = PacerPhase.reference(firstTicks: eight(0.0001), period: 0.0008)
        XCTAssertEqual(r?.value ?? 0, 0.0004, accuracy: 1e-15)
        XCTAssertEqual(PacerPhase.reference(firstTicks: eight(0.0007), period: 0.0008)?.value ?? 0, 0.0004, accuracy: 1e-15)
    }

    // MARK: the gates

    func testMatchedIsThePullsTest() {
        let f2398 = 1001.0 / 24000, f25 = 1.0 / 25, f5994 = 1001.0 / 60000
        XCTAssertTrue(PacerPhase.isMatched(sourceFrame: f2398, cardFrame: f2398))
        XCTAssertTrue(PacerPhase.isMatched(sourceFrame: f25, cardFrame: f25))
        XCTAssertTrue(PacerPhase.isMatched(sourceFrame: f5994, cardFrame: f5994))
        XCTAssertFalse(PacerPhase.isMatched(sourceFrame: f25, cardFrame: f5994))   // C6, the rate-mismatch case
        XCTAssertFalse(PacerPhase.isMatched(sourceFrame: 1.0 / 24, cardFrame: f2398)) // 24 against 23.976: 1e-3 apart
        XCTAssertFalse(PacerPhase.isMatched(sourceFrame: 0, cardFrame: f2398))        // audio only, rate unknown
        XCTAssertTrue(PacerPhase.isMatched(sourceFrame: f2398 * (1 + 0.9e-4), cardFrame: f2398))
        XCTAssertFalse(PacerPhase.isMatched(sourceFrame: f2398 * (1 + 1.1e-4), cardFrame: f2398))
    }

    func testUnitRate() {
        let prev = (clock: 10.0, host: 1000.0)
        XCTAssertTrue(PacerPhase.isUnitRate(clock: 10.00834, host: 1000.00834, previous: prev))
        XCTAssertTrue(PacerPhase.isUnitRate(clock: 10.00834 * 1 + 0.00008, host: 1000.00834, previous: prev))   // +0.96 %
        XCTAssertFalse(PacerPhase.isUnitRate(clock: 10.01668, host: 1000.00834, previous: prev))   // 2×, a shuttle
        XCTAssertFalse(PacerPhase.isUnitRate(clock: 10.0, host: 1000.00834, previous: prev))       // paused
        XCTAssertFalse(PacerPhase.isUnitRate(clock: 300, host: 1000.00834, previous: prev))         // a seek
        XCTAssertFalse(PacerPhase.isUnitRate(clock: 9.9, host: 1000.00834, previous: prev))         // a wrap back
        XCTAssertFalse(PacerPhase.isUnitRate(clock: 10.2, host: 1000.2, previous: prev))            // too long a gap
        XCTAssertFalse(PacerPhase.isUnitRate(clock: 10.0, host: 1000.0, previous: prev))            // no time passed
        XCTAssertFalse(PacerPhase.isUnitRate(clock: 10.008, host: 1000.008, previous: nil))
        XCTAssertFalse(PacerPhase.isUnitRate(clock: .nan, host: 1000.008, previous: prev))
    }

    // MARK: the follower

    private let quantum = 125.0 / 3 / 1e9   // one mach tick on Apple silicon (24 MHz)

    func testInactiveIsZeroAndDropsTheReference() {
        var f = PacerPhaseFollower(quantum: quantum)
        for _ in 0..<8 { _ = f.tick(.active(x: 0.003), period: 0.0139) }
        XCTAssertEqual(f.reference, 0.003)
        let r = f.tick(.inactive, period: 0.0139)
        XCTAssertEqual(r.correction, 0)
        XCTAssertNil(r.event)
        XCTAssertNil(f.reference)
        XCTAssertEqual(f.run.inactiveTicks, 1)
    }

    func testNothingHappensWithoutEightNewFrames() {
        // A phase well inside the tick: the establishment guard has nothing to do, and the follow waits for eight new frames.
        var f = PacerPhaseFollower(quantum: quantum)
        for _ in 0..<7 { XCTAssertEqual(f.tick(.active(x: 0.004), period: 0.0139).correction, 0) }
        for _ in 0..<20 { XCTAssertEqual(f.tick(.active(x: nil), period: 0.0139).correction, 0) }
        XCTAssertNil(f.reference)
        XCTAssertEqual(f.run.corrections, 0)
    }

    func testReferenceEventAndGuardMovesTheTicksLaterInClampedSteps() {
        // A phase inside the establishment guard's dead band (0.49 ms: within 20 µs of the 0.5 ms edge) is not moved while
        // establishing; the reference's guard raises x_ref to 0.5 ms and the follow closes the 10 µs in clamped steps.
        var f = PacerPhaseFollower(quantum: quantum)
        var event: PacerPhaseFollower.Event?
        var first: Int64 = 0
        for i in 0..<8 {
            let r = f.tick(.active(x: 0.00049), period: 0.0139)
            if i < 7 { XCTAssertEqual(r.correction, 0) }
            if i == 7 { event = r.event; first = r.correction }
        }
        XCTAssertEqual(event, .referenceSet(reference: 0.0005, median: 0.00049, guarded: .raised))
        XCTAssertEqual(f.run.nudges, 0)
        XCTAssertEqual(Double(first) * quantum, 10e-6, accuracy: quantum)   // under the clamp: one step, later
        for _ in 0..<10 { XCTAssertEqual(f.tick(.active(x: nil), period: 0.0139).correction, 0) }
        XCTAssertEqual(f.applied, 10e-6, accuracy: quantum)
        XCTAssertEqual(f.run.guards, 1)
        // The follow's clamp still governs after the reference: a phase 0.3 ms early of x_ref takes 15 steps of 20 µs.
        var g = PacerPhaseFollower(quantum: quantum)
        for _ in 0..<8 { _ = g.tick(.active(x: 0.004), period: 0.0139) }
        var steps = 0
        for _ in 0..<8 { if g.tick(.active(x: 0.0037 + g.applied), period: 0.0139).correction != 0 { steps += 1 } }
        for _ in 0..<60 { if g.tick(.active(x: nil), period: 0.0139).correction != 0 { steps += 1 } }
        XCTAssertGreaterThanOrEqual(g.run.clampHits, 1)
        XCTAssertEqual(g.applied, 0.0003, accuracy: 2 * quantum)
        XCTAssertLessThanOrEqual(steps, 16)
    }

    // MARK: the establishment guard (CARD_PULL_MARGIN.md §15.3)

    private let p5994 = 1001.0 / 60000 / 2   // 59.94 at k 2: P 8.3417 ms

    func testEstablishmentCorrectionAtTheEdgesAndInside() {
        let p = p5994, low = PacerPhase.guardMargin, high = p5994 - PacerPhase.guardMargin
        // On a due time from either side: moved to the edge, in one step of at most the margin.
        XCTAssertEqual(PacerPhase.establishmentCorrection(x: 0, period: p), low, accuracy: 1e-12)            // later
        XCTAssertEqual(PacerPhase.establishmentCorrection(x: 1e-6, period: p), low - 1e-6, accuracy: 1e-12)
        XCTAssertEqual(PacerPhase.establishmentCorrection(x: p - 1e-9, period: p), high - (p - 1e-9), accuracy: 1e-12)   // earlier
        XCTAssertEqual(PacerPhase.establishmentCorrection(x: 0.008336, period: p), high - 0.008336, accuracy: 1e-12)    // the A/B wrap
        XCTAssertLessThanOrEqual(abs(PacerPhase.establishmentCorrection(x: p - 1e-12, period: p)), PacerPhase.guardMargin)
        // Normal phases, and the dead band of one clamp past each edge: nothing.
        for x in [0.001, 0.004, 0.0075, low, low - 19e-6, high, high + 19e-6] {
            XCTAssertEqual(PacerPhase.establishmentCorrection(x: x, period: p), 0, "x \(x)")
        }
        XCTAssertGreaterThan(PacerPhase.establishmentCorrection(x: low - 21e-6, period: p), 0)
        XCTAssertLessThan(PacerPhase.establishmentCorrection(x: high + 21e-6, period: p), 0)
        // Outliers, bad values, bad periods: nothing.
        for x in [-1e-6, p, p + 0.001, .nan, .infinity] { XCTAssertEqual(PacerPhase.establishmentCorrection(x: x, period: p), 0) }
        for q in [0.0, -p, .nan, .infinity] { XCTAssertEqual(PacerPhase.establishmentCorrection(x: 0, period: q), 0) }
        // The other rates' P: the same margin.
        XCTAssertEqual(PacerPhase.establishmentCorrection(x: 0.0139 - 5e-6, period: 1001.0 / 24000 / 3),
                       1001.0 / 24000 / 3 - low - (0.0139 - 5e-6), accuracy: 1e-12)
    }

    func testAWrapOnADueTimeIsMovedOffItAtTheFirstTick() {
        // The A/B night's wrap (§15.3): the phase after the wrap sat at x ≈ 8.336 ms, 5.7 µs before the next due time, with
        // ±10 µs of read jitter, so the samples straddle the due time (some read just under P, some just over 0). Model the
        // tick's true offset t from the frame grid; x = t mod P. The first tick is moved earlier to P − 0.5 ms in one step;
        // after it no tick is within 0.4 ms of a due time, and the reference is set at the phase as moved.
        let p = p5994
        var f = PacerPhaseFollower(quantum: quantum)
        let jitter: [Double] = [3e-6, -8e-6, 9e-6, -2e-6, 7e-6, -10e-6, 1e-6, 6e-6, -4e-6, 10e-6]
        var events: [PacerPhaseFollower.Event] = []
        var xs: [Double] = []
        for n in 0..<40 {
            let t = 0.008336 + f.applied + jitter[n % jitter.count]
            let x = t.truncatingRemainder(dividingBy: p) + (t < 0 ? p : 0)
            xs.append(x)
            let r = f.tick(.active(x: x), period: p)
            if let e = r.event { events.append(e) }
            _ = f.tick(.active(x: nil), period: p)   // k 2: one repeat tick per frame
        }
        guard case .establishmentNudge(let x0, let moved)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(x0, 0.008339, accuracy: 1e-9)
        XCTAssertEqual(moved, (p - PacerPhase.guardMargin) - 0.008339, accuracy: quantum)
        XCTAssertEqual(f.run.nudges, 1)
        for x in xs.dropFirst() { XCTAssertTrue(x > 0.0004 && x < p - 0.0004, "x \(x)") }
        guard case .referenceSet(let ref, let median, _)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(ref, p - PacerPhase.guardMargin, accuracy: 15e-6)   // the moved phase, not the raw first sample
        XCTAssertEqual(median, p - PacerPhase.guardMargin, accuracy: 15e-6)
    }

    func testAPhaseOnTheDueTimeFromAfterIsMovedLater() {
        // x = 0: the tick on the due time from after it. Moved 0.5 ms later at once; the reference is then 0.5 ms, unguarded or
        // raised by at most a quantum.
        let p = p5994
        var f = PacerPhaseFollower(quantum: quantum)
        var first: Int64 = 0
        for n in 0..<8 {
            let r = f.tick(.active(x: 0 + f.applied), period: p)
            if n == 0 { first = r.correction; XCTAssertEqual(r.event, .establishmentNudge(x: 0, moved: Double(r.correction) * quantum)) }
            else if n < 7 { XCTAssertEqual(r.correction, 0) }
        }
        XCTAssertEqual(Double(first) * quantum, PacerPhase.guardMargin, accuracy: quantum)
        XCTAssertEqual(f.reference ?? .nan, PacerPhase.guardMargin, accuracy: quantum)
        XCTAssertEqual(f.run.nudges, 1)
        XCTAssertEqual(f.run.nudgeNet, PacerPhase.guardMargin, accuracy: quantum)
        XCTAssertEqual(f.run.corrections, 0)   // the nudge is not a follow correction
    }

    func testANormalPhaseIsUntouchedWhileEstablishing() {
        // A phase inside the tick: exactly the previous behaviour. No move, the reference is the plain median of the eight.
        var f = PacerPhaseFollower(quantum: quantum)
        let samples = [0.0041, 0.0040, 0.0042, 0.0039, 0.0040, 0.0041, 0.0040, 0.0043]
        var event: PacerPhaseFollower.Event?
        for x in samples { let r = f.tick(.active(x: x), period: p5994); XCTAssertEqual(r.correction == 0 || r.event != nil, true); event = r.event ?? event }
        XCTAssertEqual(event, .referenceSet(reference: PacerPhase.median(samples), median: PacerPhase.median(samples), guarded: .none))
        XCTAssertEqual(f.run.nudges, 0)
        XCTAssertEqual(f.run.nudgeNet, 0)
    }

    func testTheFirstMovesDirectionIsLockedForItsEstablishment() {
        // x near P and x near 0 are both on a due time, one each side of it. After a first move earlier (x near P), a sample
        // read just after the due time (x near 0, which alone would move later) is not moved back across it; a further sample
        // on the first side still moves, the same way. And the mirror case. A restart clears the lock.
        let p = p5994
        var f = PacerPhaseFollower(quantum: quantum)
        XCTAssertLessThan(f.tick(.active(x: 0.008339), period: p).correction, 0)
        let across = f.tick(.active(x: 2e-6), period: p)
        XCTAssertEqual(across.correction, 0)
        XCTAssertNil(across.event)
        let same = f.tick(.active(x: 0.008339), period: p)
        XCTAssertLessThan(same.correction, 0)
        guard case .establishmentNudge? = same.event else { return XCTFail("\(String(describing: same.event))") }
        XCTAssertEqual(f.run.nudges, 2)
        XCTAssertNil(f.reference)

        var g = PacerPhaseFollower(quantum: quantum)
        XCTAssertGreaterThan(g.tick(.active(x: 2e-6), period: p).correction, 0)
        XCTAssertEqual(g.tick(.active(x: 0.008339), period: p).correction, 0)
        XCTAssertEqual(g.run.nudges, 1)
        // A restart drops the lock: the next establishment may move either way.
        _ = g.tick(.inactive, period: p)
        XCTAssertLessThan(g.tick(.active(x: 0.008339), period: p).correction, 0)
        XCTAssertEqual(g.run.nudges, 2)
    }

    func testEveryRestartGuardsItsOwnEstablishment() {
        // A wrap or a seek (an inactive tick) drops the reference; the next establishment is guarded afresh, from zero moves.
        let p = p5994
        var f = PacerPhaseFollower(quantum: quantum)
        var u = 0.004
        for _ in 0..<8 { _ = f.tick(.active(x: u + f.applied), period: p) }
        XCTAssertNotNil(f.reference)
        _ = f.tick(.inactive, period: p)
        XCTAssertNil(f.reference)
        XCTAssertEqual(f.applied, 0)
        u = p - 2e-6   // the wrap lands on a due time
        let r = f.tick(.active(x: u + f.applied), period: p)
        guard case .establishmentNudge? = r.event else { return XCTFail("\(String(describing: r.event))") }
        XCTAssertLessThan(r.correction, 0)
        for _ in 0..<7 { _ = f.tick(.active(x: u + f.applied), period: p) }
        XCTAssertEqual(f.reference ?? .nan, p - PacerPhase.guardMargin, accuracy: 2 * quantum)
        XCTAssertEqual(f.run.nudges, 1)
        XCTAssertEqual(f.run.references, 2)
        // An outlier while establishing is not phase: no move.
        _ = f.tick(.inactive, period: p)
        XCTAssertEqual(f.tick(.active(x: p + 0.001), period: p).correction, 0)
        XCTAssertEqual(f.tick(.active(x: -0.001), period: p).correction, 0)
        XCTAssertEqual(f.run.nudges, 1)
    }

    func testAStepIsCorrectedWithoutOvershootOrRinging() {
        // A settled phase, then x jumps 12 µs later and stays. The median of eight moves in two steps as the new value becomes
        // the majority (−6 µs, then −6 µs), and the samples taken before each correction are re-expressed at it, so neither is
        // applied again: exactly −12 µs in all, then nothing, and x back on x_ref.
        var f = PacerPhaseFollower(quantum: quantum)
        for _ in 0..<8 { _ = f.tick(.active(x: 0.004), period: 0.0139) }
        var corrections: [Double] = []
        let phase = 0.004 + 12e-6   // the uncorrected phase from here on
        var lastX = 0.0
        for _ in 0..<60 {
            lastX = phase + f.applied
            let r = f.tick(.active(x: lastX), period: 0.0139)
            if r.correction != 0 { corrections.append(Double(r.correction) * quantum) }
            for _ in 0..<2 { if f.tick(.active(x: nil), period: 0.0139).correction != 0 { corrections.append(.nan) } }
        }
        XCTAssertLessThanOrEqual(corrections.count, 2, "\(corrections)")
        XCTAssertTrue(corrections.allSatisfy { $0 < 0 }, "\(corrections)")   // never the other way: no overshoot
        XCTAssertEqual(corrections.reduce(0, +), -12e-6, accuracy: 2 * quantum)
        XCTAssertEqual(lastX, 0.004, accuracy: 2 * quantum)
    }

    func testDriftNeverCrossesADueTime() {
        // 23.976 at k 3 (P 13.90 ms), the card 11.7 ppm slow against the host: 0.49 µs of drift per frame, earlier. Start the
        // reference 0.6 ms after due, and run 10 hours of frames. With option C, x stays within a few µs of x_ref; without it,
        // the tick would cross the due time after about 51 s (and sweep the whole tick in about 19 minutes).
        let p = 1001.0 / 24000 / 3, drift = -11.7e-6 * (1001.0 / 24000)
        var f = PacerPhaseFollower(quantum: quantum)
        var u = 0.0006        // the uncorrected phase
        var worst = 0.0, crossed = false
        for n in 0..<(10 * 3600 * 24) {
            let x = u + f.applied
            if x < 0 || x >= p { crossed = true }
            let r = f.tick(.active(x: x), period: p)
            if n >= 8, let ref = f.reference { worst = max(worst, abs(x - ref)) }
            _ = r
            _ = f.tick(.active(x: nil), period: p); _ = f.tick(.active(x: nil), period: p)
            u += drift
        }
        XCTAssertFalse(crossed)
        XCTAssertLessThan(worst, 5e-6)
        XCTAssertEqual(f.run.clampHits, 0)
        // Without correction the same drift crosses 0.6 ms in under a minute of frames.
        XCTAssertLessThan(0.0006 / -drift / (24000.0 / 1001), 60)
    }

    func testOutliersAreNotPhase() {
        var f = PacerPhaseFollower(quantum: quantum)
        for _ in 0..<8 { _ = f.tick(.active(x: 0.004), period: 0.0139) }
        // A frame a whole tick late reads x ≥ P: counted, not used, no correction.
        XCTAssertEqual(f.tick(.active(x: 0.0139 + 0.004), period: 0.0139).correction, 0)
        XCTAssertEqual(f.tick(.active(x: -0.001), period: 0.0139).correction, 0)
        XCTAssertEqual(f.run.outliers, 2)
        XCTAssertEqual(f.run.corrections, 0)
    }

    func testRingMedianEqualsTheMedian() {
        let sets: [[Double]] = [[1], [2, 1], [5, 3, 9], [8, 1, 7, 2, 6, 3, 5, 4], [0.1, 0.1, 0.3, 0.2, 0.2, 0.1, 0.4, 0.0]]
        for s in sets { XCTAssertEqual(PacerPhaseFollower.median(ofRing: s), PacerPhase.median(s)) }
        XCTAssertTrue(PacerPhaseFollower.median(ofRing: []).isNaN)
    }

    func testDeviationStatsAndReport() {
        var d = PhaseDeviationStats()
        XCTAssertTrue(d.quantile(0.5).isNaN)
        for _ in 0..<98 { d.add(2.5e-6) }
        d.add(40.5e-6); d.add(0.02)                       // the last in the overflow bin: the exact maximum
        XCTAssertEqual(d.quantile(0.5), 3e-6, accuracy: 1e-12)
        XCTAssertEqual(d.quantile(0.99), 41e-6, accuracy: 1e-12)
        XCTAssertEqual(d.quantile(1), 0.02)
        d.reset()
        XCTAssertEqual(d.count, 0)

        var f = PacerPhaseFollower(quantum: quantum)
        for _ in 0..<8 { _ = f.tick(.active(x: 0.004), period: 0.0139) }
        _ = f.tick(.active(x: 0.004001), period: 0.0139)
        _ = f.tick(.inactive, period: 0.0139)
        let line = f.report()
        XCTAssertTrue(line.hasPrefix("10 s: new-frame ticks 9 · inactive ticks 1 · outliers 0 · |x − x_ref| p50 0.001"), line)
        XCTAssertTrue(line.contains("references set 1 (guard 0) · establishment nudges 0 (net +0.000 ms)"), line)
        XCTAssertEqual(f.window, PacerPhaseFollower.Counts())   // the window is reset by its report
        XCTAssertTrue(f.report(run: true).hasPrefix("run: new-frame ticks 9 · inactive ticks 1"))
    }
}
