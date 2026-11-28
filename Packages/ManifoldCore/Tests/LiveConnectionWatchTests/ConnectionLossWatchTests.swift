import XCTest
@testable import LiveConnectionWatch

/// docs/BUGS.md, 0.9.6 UI polish, batch 2 fix 3: an NDI connection lost after it started.
final class ConnectionLossWatchTests: XCTestCase {

    func testGraceMatchesSRTPeerIdle() {
        XCTAssertEqual(ConnectionLossWatch.defaultGrace, 5)
        XCTAssertEqual(ConnectionLossWatch().grace, 5)
    }

    /// A receiver that never connected is a connect failure, not a loss.
    func testNeverConnectedIsNeverLost() {
        var w = ConnectionLossWatch()
        for t in stride(from: 0.0, through: 60, by: 1) { XCTAssertFalse(w.observe(connections: 0, now: t)) }
        XCTAssertFalse(w.hasConnected)
    }

    func testLostAfterGraceAtZero() {
        var w = ConnectionLossWatch()
        XCTAssertFalse(w.observe(connections: 1, now: 0))
        XCTAssertFalse(w.observe(connections: 0, now: 1))     // falls to zero at t = 1
        XCTAssertFalse(w.observe(connections: 0, now: 5.9))
        XCTAssertTrue(w.observe(connections: 0, now: 6))      // 5 s at zero
    }

    /// NDI rides through a brief drop by itself: a count that comes back inside the grace is not a loss, and the next drop
    /// starts its own grace.
    func testRecoveryInsideGraceResetsTheClock() {
        var w = ConnectionLossWatch()
        _ = w.observe(connections: 1, now: 0)
        XCTAssertFalse(w.observe(connections: 0, now: 1))
        XCTAssertFalse(w.observe(connections: 0, now: 4))
        XCTAssertFalse(w.observe(connections: 1, now: 5))
        XCTAssertNil(w.zeroSince)
        XCTAssertFalse(w.observe(connections: 0, now: 7))
        XCTAssertFalse(w.observe(connections: 0, now: 11.9))
        XCTAssertTrue(w.observe(connections: 0, now: 12))
    }

    func testReportsOnce() {
        var w = ConnectionLossWatch()
        _ = w.observe(connections: 1, now: 0)
        _ = w.observe(connections: 0, now: 1)
        XCTAssertTrue(w.observe(connections: 0, now: 6))
        XCTAssertFalse(w.observe(connections: 0, now: 7))
        XCTAssertFalse(w.observe(connections: 1, now: 8))
        XCTAssertFalse(w.observe(connections: 0, now: 20))
    }

    /// A count of 2 (the SDK says "normally 0 or 1") is connected.
    func testAnyPositiveCountIsConnected() {
        var w = ConnectionLossWatch()
        _ = w.observe(connections: 2, now: 0)
        XCTAssertTrue(w.hasConnected)
    }

    /// A late first poll (the timer fires after the grace has already passed) reports on the reading after the drop is
    /// first seen plus the grace, not on the first zero it sees: the drop time is unknown, so it is not back-dated.
    func testFirstZeroStartsTheClock() {
        var w = ConnectionLossWatch()
        _ = w.observe(connections: 1, now: 0)
        XCTAssertFalse(w.observe(connections: 0, now: 100))
        XCTAssertTrue(w.observe(connections: 0, now: 105))
    }
}
