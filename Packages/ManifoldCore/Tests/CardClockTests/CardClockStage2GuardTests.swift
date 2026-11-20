import XCTest
import CardClock

/// Stage 2's guards, from night 7's GOP block (docs/SDI_AUDIO_NIGHT7.md, fault (b); `n7-gop25-sdi-bon.log:5674-5904`).
/// 1080p25 out, card frame 0.04 s. The seek to 978.16 s from 1165.03 s, while playing; latch #2 at slot 1448 on pre-seek content.
final class CardClockStage2GuardTests: XCTestCase {
    private let frame = 0.04
    /// The card's line: slot 1448 completed at host 535937.40 (shortly after the seek at 535937.268), rate 1.
    private let slot0: Int64 = 1448, host0 = 535_937.40
    private let k = 0.0   // the device latency term; the guard's margin dwarfs it

    /// `stage2WireHost`'s arithmetic (FrameEngine): the host at which `content` is on the wire under line φ, through
    /// `CardClockLine.host(atCardTime:)` at rate 1.
    private func wireHost(content: Double, phi: Double) -> Double { host0 + (content - k - phi - Double(slot0) * frame) }

    func testNight7StaleLineStartIsRefused() {
        // Picture line #2: φ 1106.96 s (pts 1164.92 at slot 1449). Parked content 978.16 s.
        let now = 535_937.42
        let host = wireHost(content: 978.16, phi: 1106.96)
        guard case .refuse(let offset) = CardClockStage2Guard.startVerdict(wireHost: host, now: now) else {
            return XCTFail("night 7's stale line must be refused")
        }
        // The engine logged "starts 186606.2 ms into the SDI picture's run": the same lateness, within the hosts assumed here.
        XCTAssertEqual(-offset, 186.7, accuracy: 0.2)
    }

    func testNight7RealLineStartsLateWithinTheBound() {
        // Picture line #3: φ 920.24 s (pts 978.28 at slot 1451); content 978.16 s was at card time 57.92 s = slot 1448.
        let now = 535_937.50
        let host = wireHost(content: 978.16, phi: 920.24)
        guard case .startLate(let late) = CardClockStage2Guard.startVerdict(wireHost: host, now: now) else {
            return XCTFail("the real line is a normal late start")
        }
        XCTAssertEqual(late, 0.102, accuracy: 1e-6)
    }

    func testFutureStartsWithinTheBoundWaitAndBeyondItAreRefused() {
        XCTAssertEqual(CardClockStage2Guard.startVerdict(wireHost: 100.0827, now: 100), .startAt(host: 100.0827))   // "82.7 ms from now"
        guard case .refuse = CardClockStage2Guard.startVerdict(wireHost: 1700, now: 100) else {
            return XCTFail("a forward seek's stale line points the start far into the future")
        }
    }

    func testTheSoaksLargestLegitimateLateStartPasses() {
        // 378.9 ms, the largest late start in every soak log but night 7's.
        guard case .startLate(let late) = CardClockStage2Guard.startVerdict(wireHost: 99.623_1, now: 100) else { return XCTFail() }
        XCTAssertEqual(late, 0.3789, accuracy: 1e-6)
    }

    func testBoundIsOneSecondEitherWay() {
        guard case .startLate = CardClockStage2Guard.startVerdict(wireHost: 99.0, now: 100) else { return XCTFail("1.000 s is allowed") }
        guard case .refuse = CardClockStage2Guard.startVerdict(wireHost: 98.999, now: 100) else { return XCTFail("1.001 s is refused") }
        guard case .refuse = CardClockStage2Guard.startVerdict(wireHost: 101.001, now: 100) else { return XCTFail() }
    }

    func testCorrections() {
        // :5904, the slip to line #3: the line puts 978.33 s on the wire with the picture clock at about 978.43 s: agrees.
        XCTAssertTrue(CardClockStage2Guard.lineAgreesWithPicture(lineContent: 978.33, pictureContent: 978.43))
        // A stale line (pre-seek content 1164.92 s) against the picture clock after the seek: refused.
        XCTAssertFalse(CardClockStage2Guard.lineAgreesWithPicture(lineContent: 1164.92, pictureContent: 978.40))
        // The wire's lag, at its largest seen (0.5 s): agrees.
        XCTAssertTrue(CardClockStage2Guard.lineAgreesWithPicture(lineContent: 977.9, pictureContent: 978.4))
        XCTAssertFalse(CardClockStage2Guard.lineAgreesWithPicture(lineContent: .nan, pictureContent: 978.4))
    }

    func testReread() {
        // The correction at :5904 moved the clock from ≈ 1165.05 s back to 978.33 s: re-read.
        XCTAssertTrue(CardClockStage2Guard.needsReread(from: 1165.05, to: 978.33))
        // The bogus start's forward jump, had it been allowed: re-read.
        XCTAssertTrue(CardClockStage2Guard.needsReread(from: 978.16, to: 1164.77))
        // A slip of one frame, a coarse write of 20 ms, the largest late start: no re-read.
        XCTAssertFalse(CardClockStage2Guard.needsReread(from: 298.50, to: 298.54))
        XCTAssertFalse(CardClockStage2Guard.needsReread(from: 100, to: 100.3789))
        XCTAssertFalse(CardClockStage2Guard.needsReread(from: 100, to: 101))
        XCTAssertFalse(CardClockStage2Guard.needsReread(from: .nan, to: 5))
    }
}
