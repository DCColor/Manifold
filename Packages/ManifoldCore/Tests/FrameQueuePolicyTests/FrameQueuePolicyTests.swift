import XCTest
@testable import FrameQueuePolicy

/// The paused-picture rules (docs/BUGS.md, "a paused step or seek can come to rest one or two frames past its target"),
/// replayed on the queue contents the 2026-10-16 traces recorded.
final class FrameQueuePolicyTests: XCTestCase {
    /// A queue modelled as the renderer keeps it: ascending pts, bounded, trimmed at the policy's end.
    private func enqueue(_ pts: [Double], bound: Int, paused: Bool) -> [Double] {
        var q: [Double] = []
        for p in pts {
            var i = q.count
            while i > 0, q[i - 1] > p { i -= 1 }
            q.insert(p, at: i)
            if q.count > bound {
                switch FrameQueuePolicy.trimEnd(paused: paused) {
                case .oldest: q.removeFirst(q.count - bound)
                case .newest: q.removeLast(q.count - bound)
                }
            }
        }
        return q
    }

    func testTrimEnd() {
        XCTAssertEqual(FrameQueuePolicy.trimEnd(paused: true), .newest)
        XCTAssertEqual(FrameQueuePolicy.trimEnd(paused: false), .oldest)
    }

    /// The traced overshoot: a step to 0.1167 at 60 fps, 13 frames arriving before any tick, bound 12.
    func testPausedBurstKeepsTheTarget() {
        let burst = (7...19).map { Double($0) / 60 }          // 0.1167 … 0.3167
        let paused = enqueue(burst, bound: 12, paused: true)
        XCTAssertEqual(paused.first!, 7.0 / 60, accuracy: 1e-12, "the target survives")
        XCTAssertEqual(paused.count, 12)
        // What the old rule did: the target is gone, and the earliest survivor is a frame late.
        let old = enqueue(burst, bound: 12, paused: false)
        XCTAssertEqual(old.first!, 8.0 / 60, accuracy: 1e-12)
    }

    /// The traced three-frame case: 15 frames after ← to 0, bound 12.
    func testLongerBurst() {
        let burst = (0...14).map { Double($0) / 60 }
        XCTAssertEqual(enqueue(burst, bound: 12, paused: true).first!, 0)
        XCTAssertEqual(enqueue(burst, bound: 12, paused: false).first!, 3.0 / 60, accuracy: 1e-12)
    }

    /// B-frame arrival order (decode order, presentation-sorted on insert) keeps the target too.
    func testReorderedBurst() {
        let order = [12, 16, 14, 13, 15, 20, 18, 17, 19, 24, 22, 21, 23, 28].map { Double($0) / 24 }
        let q = enqueue(order, bound: 12, paused: true)
        XCTAssertEqual(q.first!, 12.0 / 24, accuracy: 1e-12)
        XCTAssertEqual(q, q.sorted())
    }

    func testRelaxedRender() {
        let d = 1.0 / 60
        // A whole frame or more past the clock: refused (the overshoot).
        XCTAssertFalse(FrameQueuePolicy.relaxedRenderAllowed(nearestPts: 8 * d, secondPts: 9 * d, now: 7 * d))
        XCTAssertFalse(FrameQueuePolicy.relaxedRenderAllowed(nearestPts: 10 * d, secondPts: 11 * d, now: 7 * d))
        // A fraction of a frame past the clock (a mid-frame libav seek): allowed, as before.
        XCTAssertTrue(FrameQueuePolicy.relaxedRenderAllowed(nearestPts: 8 * d, secondPts: 9 * d, now: 7.4 * d))
        XCTAssertTrue(FrameQueuePolicy.relaxedRenderAllowed(nearestPts: 8 * d, secondPts: 9 * d, now: 7.99 * d))
        // One frame queued: nothing to judge by, allowed (e.g. the last frame of a file).
        XCTAssertTrue(FrameQueuePolicy.relaxedRenderAllowed(nearestPts: 8 * d, secondPts: nil, now: 0))
        // A non-increasing pair: no interval, allowed rather than stuck.
        XCTAssertTrue(FrameQueuePolicy.relaxedRenderAllowed(nearestPts: 8 * d, secondPts: 8 * d, now: 7 * d))
        // NTSC: 1001/60000 frames, a whole frame late refused, half a frame allowed.
        let n = 1001.0 / 60000
        XCTAssertFalse(FrameQueuePolicy.relaxedRenderAllowed(nearestPts: 16 * n, secondPts: 17 * n, now: 15 * n))
        XCTAssertTrue(FrameQueuePolicy.relaxedRenderAllowed(nearestPts: 16 * n, secondPts: 17 * n, now: 15.5 * n))
    }
}
