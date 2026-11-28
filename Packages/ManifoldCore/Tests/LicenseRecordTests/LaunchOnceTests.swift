import XCTest
@testable import LicenseRecord

/// The once-per-launch gate on license startup (docs/BUGS.md 0.9.6, part C).
final class LaunchOnceTests: XCTestCase {

    func testFirstClaimWinsLaterClaimsLose() {
        let once = LaunchOnce()
        XCTAssertFalse(once.hasRun)
        XCTAssertTrue(once.claim())
        XCTAssertTrue(once.hasRun)
        XCTAssertFalse(once.claim())
        XCTAssertFalse(once.claim())
    }

    func testSeparateInstancesAreIndependent() {
        let a = LaunchOnce(), b = LaunchOnce()
        XCTAssertTrue(a.claim())
        XCTAssertTrue(b.claim())
    }

    /// Many threads at once (several windows opening together): exactly one claim.
    func testConcurrentClaimsGiveExactlyOne() {
        let once = LaunchOnce()
        let lock = NSLock()
        var wins = 0
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if once.claim() {
                lock.lock(); wins += 1; lock.unlock()
            }
        }
        XCTAssertEqual(wins, 1)
    }

    /// `run` performs the body once, even when called again while the first body is still running.
    func testRunPerformsBodyOnceAcrossOverlappingCalls() async {
        let once = LaunchOnce()
        let counter = Counter()
        async let first: Bool = once.run {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)   // still running when the others arrive
        }
        async let second: Bool = once.run { await counter.increment() }
        async let third: Bool = once.run { await counter.increment() }
        let results = await [first, second, third]
        let runs = await counter.value
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(results.filter { $0 }.count, 1)
    }

    /// A later call (a window opened long after launch) does not run it again.
    func testRunAfterCompletionDoesNothing() async {
        let once = LaunchOnce()
        let counter = Counter()
        let ranFirst = await once.run { await counter.increment() }
        let ranAgain = await once.run { await counter.increment() }
        let runs = await counter.value
        XCTAssertTrue(ranFirst)
        XCTAssertFalse(ranAgain)
        XCTAssertEqual(runs, 1)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
