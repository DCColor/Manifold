import XCTest
import RendererWatchdog

/// The picture-freeze watchdog's decision and its counts (docs/PICTURE_FREEZE_AUDIT.md; docs/BUGS.md, top 1.0 entry).
final class RendererWatchdogTests: XCTestCase {
    private let frame = 1001.0 / 60000

    /// A healthy renderer: ready, the last frame 0.13 s ahead of its clock, a callback just now.
    private func healthy(_ now: Double) -> RendererWatchdog.Reading {
        .init(now: now, ready: true, ended: false, armedHost: 0, lastCallbackHost: now, lastEnqueueHost: now,
              lastEnqueuedPTS: now + 0.13, frameDuration: frame, enqueuedSinceArm: 100, rendererClock: now)
    }

    /// The stalled state as measured four times: not ready, last callback at `lastCallback`, every frame we gave it already due.
    private func stalled(_ now: Double, lastCallback: Double = 0, enqueued: Int = 100, armed: Double = -10,
                         lastEnqueueHost: Double = 0) -> RendererWatchdog.Reading {
        .init(now: now, ready: false, ended: false, armedHost: armed, lastCallbackHost: lastCallback, lastEnqueueHost: lastEnqueueHost,
              lastEnqueuedPTS: 0, frameDuration: frame, enqueuedSinceArm: enqueued, rendererClock: now + 1)
    }

    /// Steps the watchdog every 62.5 ms (about its 50 ms timer; a power of two, so tick times are exact) over `from...to`,
    /// collecting the non-`.none` actions.
    private func run(_ w: inout RendererWatchdog, from: Double, to: Double, enabled: Bool = true,
                     _ reading: (Double) -> RendererWatchdog.Reading) -> [(Double, RendererWatchdog.Action)] {
        var out: [(Double, RendererWatchdog.Action)] = []
        var t = from
        while t <= to + 1e-9 {
            let a = w.step(reading(t), recoveryEnabled: enabled)
            if a != .none { out.append((t, a)) }
            t += 0.0625
        }
        return out
    }

    // MARK: thresholds

    func testShippingThresholds() {
        let t = RendererWatchdog.Thresholds.shipping
        XCTAssertEqual(t.recoverAfterSilence, 0.20)         // decided Robbie 2026-11-20 (was 0.5)
        XCTAssertEqual(t.nearMissAfter, 0.10)
        XCTAssertEqual(t.recoverInState, 0.15)
        XCTAssertLessThan(t.nearMissAfter, t.recoverInState, "a self-clearing state must be seen before it is recovered")
        XCTAssertLessThan(t.nearMissAfter, t.recoverAfterSilence)
        XCTAssertEqual(t.rearmWait, 1.0)
        XCTAssertEqual(t.rearmAttempts, 3)
        XCTAssertEqual(t.unarmedGrace, 0.25)
    }

    // MARK: the state: ready / not ready, pending

    func testReadyIsNeverTheState() {
        let w = RendererWatchdog()
        var r = stalled(1.0); r.ready = true
        XCTAssertFalse(w.inState(r))
    }

    func testFramesPendingIsNotTheState() {
        let w = RendererWatchdog()
        var r = stalled(1.0); r.rendererClock = 1.0; r.lastEnqueuedPTS = 1.0 + 0.13   // not ready because it is full: healthy
        XCTAssertFalse(w.inState(r))
        r.lastEnqueuedPTS = 1.0 - frame / 2                       // the last frame not yet a frame past its pts: still pending
        XCTAssertFalse(w.inState(r))
        r.lastEnqueuedPTS = 1.0 - frame * 1.5                     // a frame past it: nothing pending
        XCTAssertTrue(w.inState(r))
    }

    func testUnknownFrameDurationUsesASixtiethOfASecond() {
        let w = RendererWatchdog()
        var r = stalled(1.0); r.rendererClock = 1.0; r.frameDuration = 0
        r.lastEnqueuedPTS = 1.0 - 0.015; XCTAssertFalse(w.inState(r))
        r.lastEnqueuedPTS = 1.0 - 0.018; XCTAssertTrue(w.inState(r))
    }

    func testEndOfStreamIsNotTheState() {
        let w = RendererWatchdog()
        var r = stalled(5.0); r.ended = true
        XCTAssertFalse(w.inState(r))
    }

    func testNothingEnqueuedSinceTheArmCountsAfterTheGrace() {
        let w = RendererWatchdog()
        XCTAssertFalse(w.inState(stalled(10.20, enqueued: 0, armed: 10.0)))   // 0.20 s after the arm: the first frame may be coming
        XCTAssertTrue(w.inState(stalled(10.30, enqueued: 0, armed: 10.0)))
    }

    // MARK: healthy play, near-misses

    func testHealthyPlayNeverActs() {
        var w = RendererWatchdog()
        XCTAssertTrue(run(&w, from: 0, to: 600) { self.healthy($0) }.isEmpty)
        XCTAssertEqual(w.state, .idle)
    }

    func testAShortStateClearingByItselfIsNothing() {
        var w = RendererWatchdog()
        XCTAssertEqual(w.step(stalled(1.00, lastCallback: 0.95)), .none)
        XCTAssertEqual(w.step(stalled(1.05, lastCallback: 0.95)), .none)
        XCTAssertEqual(w.step(healthy(1.08)), .none)   // 80 ms: not over the near-miss threshold
        XCTAssertEqual(w.state, .idle)
    }

    func testAStateClearingInTheBandIsANearMissNotARecovery() {
        // The pump's last callback long ago (the silence wait already met): the in-state wait alone holds the recovery back.
        var w = RendererWatchdog()
        XCTAssertEqual(w.step(stalled(1.00, lastCallback: 0.5)), .none)
        XCTAssertEqual(w.step(stalled(1.05, lastCallback: 0.5)), .none)
        XCTAssertEqual(w.step(stalled(1.10, lastCallback: 0.5)), .none)
        guard case let .nearMiss(lasted, past) = w.step(healthy(1.12)) else { return XCTFail("expected a near-miss") }
        XCTAssertEqual(lasted, 0.12, accuracy: 1e-9); XCTAssertFalse(past)
        XCTAssertEqual(w.state, .idle)
    }

    // MARK: detection

    func testRecoversAfterTheSilenceWaitAndTheInStateWait() {
        // As measured: the pump's last callback at 0, the state from 0.16 s (its lead running out).
        var w = RendererWatchdog()
        let acts = run(&w, from: 0, to: 0.375) { t in t < 0.16 ? self.healthy(t).with { $0.lastCallbackHost = 0 } : self.stalled(t) }
        XCTAssertEqual(acts.count, 1)
        XCTAssertEqual(acts[0].0, 0.375)   // state since 0.1875 (the first tick in it); the first tick 0.15 s or more later
        XCTAssertEqual(acts[0].1, .rearm(attempt: 1, began: 0.1875))
    }

    func testSilenceWaitIsTwoHundredMilliseconds() {
        // The silence wait met, the in-state wait not yet: in the state 0.10 s, silent 0.20 s.
        var w = RendererWatchdog()
        XCTAssertEqual(w.step(stalled(1.00, lastCallback: 0.90)), .none)
        XCTAssertEqual(w.step(stalled(1.10, lastCallback: 0.90)), .none)
        XCTAssertEqual(w.step(stalled(1.16, lastCallback: 0.90)), .rearm(attempt: 1, began: 1.00))
        // The in-state wait met, the silence wait not yet: a callback as the state began.
        var v = RendererWatchdog()
        XCTAssertEqual(v.step(stalled(1.00, lastCallback: 1.00)), .none)
        XCTAssertEqual(v.step(stalled(1.1875, lastCallback: 1.00)), .none)   // in the state and silent 0.1875 s
        XCTAssertEqual(v.step(stalled(1.25, lastCallback: 1.00)), .rearm(attempt: 1, began: 1.00))
    }

    func testPauseResetsTheEpisode() {
        var w = RendererWatchdog()
        _ = w.step(stalled(1.00))
        w.notJudged()
        XCTAssertEqual(w.state, .idle)
        XCTAssertEqual(w.step(stalled(1.10)), .none)   // starts again from here
        XCTAssertEqual(w.step(stalled(1.20)), .none)
        XCTAssertEqual(w.step(stalled(1.30)), .rearm(attempt: 1, began: 1.10))
    }

    // MARK: re-arm, retry, rebuild, give up

    func testFirstReArmBringsAFrame() {
        var w = RendererWatchdog()
        _ = w.step(stalled(1.0)); XCTAssertEqual(w.step(stalled(1.2)), .rearm(attempt: 1, began: 1.0))
        XCTAssertEqual(w.state, .recovering(began: 1.0, armHost: 1.2, attempts: 1, rebuilt: false))
        XCTAssertEqual(w.step(stalled(1.25, enqueued: 0, armed: 1.2)), .none)
        guard case let .recovered(first, since, rebuilt) = w.step(stalled(1.30, enqueued: 2, armed: 1.2, lastEnqueueHost: 1.238))
        else { return XCTFail("expected recovered") }
        XCTAssertEqual(first, 0.038, accuracy: 1e-9); XCTAssertEqual(since, 0.30, accuracy: 1e-9); XCTAssertFalse(rebuilt)
        XCTAssertEqual(w.state, .idle)
    }

    func testThreeReArmsThenRebuildThenGiveUp() {
        var w = RendererWatchdog()
        let acts = run(&w, from: 0, to: 6) { t in self.stalled(t, enqueued: t < 0.2 ? 100 : 0) }
        XCTAssertEqual(acts.map { $0.1 }, [.rearm(attempt: 1, began: 0), .rearm(attempt: 2, began: 0), .rearm(attempt: 3, began: 0),
                                          .rebuild(attempts: 3, began: 0), .gaveUp(attempts: 3, began: 0)])
        XCTAssertEqual(acts.map { $0.0 }, [0.25, 1.25, 2.25, 3.25, 4.25])
        XCTAssertEqual(w.state, .gaveUp)
    }

    func testRebuildBringingAFrameIsARecovery() {
        var w = RendererWatchdog()
        _ = run(&w, from: 0, to: 3.25) { t in self.stalled(t, enqueued: t < 0.2 ? 100 : 0) }
        XCTAssertEqual(w.state, .recovering(began: 0, armHost: 3.25, attempts: 3, rebuilt: true))
        guard case let .recovered(_, _, rebuilt) = w.step(stalled(3.5, enqueued: 1, lastEnqueueHost: 3.45)) else { return XCTFail() }
        XCTAssertTrue(rebuilt)
    }

    func testGaveUpDoesNotLoopUntilTheStateClears() {
        var w = RendererWatchdog()
        _ = run(&w, from: 0, to: 4.25) { t in self.stalled(t, enqueued: t < 0.2 ? 100 : 0) }
        XCTAssertEqual(w.state, .gaveUp)
        XCTAssertTrue(run(&w, from: 4.3125, to: 30) { self.stalled($0, enqueued: 0) }.isEmpty)
        XCTAssertEqual(w.step(healthy(31)), .none)
        XCTAssertEqual(w.state, .idle)
    }

    // MARK: measurement switch

    func testRecoveryOffReportsOnceThenNearMissPastThePoint() {
        var w = RendererWatchdog()
        let acts = run(&w, from: 0, to: 2, enabled: false) { self.stalled($0) }
        XCTAssertEqual(acts.map { $0.1 }, [.wouldRecover(since: 0)])
        guard case let .nearMiss(_, past) = w.step(healthy(2.0625), recoveryEnabled: false) else { return XCTFail() }
        XCTAssertTrue(past)
    }

    // MARK: counts

    func testTallyCountsStallsNotAttempts() {
        var tally = RendererRecoveryTally()
        var w = RendererWatchdog()
        // One stall that needs three re-arms, then a frame.
        for (_, a) in run(&w, from: 0, to: 2.25, { t in self.stalled(t, enqueued: t < 0.2 ? 100 : 0) }) { tally.note(a) }
        tally.note(w.step(stalled(2.3125, enqueued: 1, lastEnqueueHost: 2.28)))
        XCTAssertEqual(tally.stalls, 1); XCTAssertEqual(tally.rearms, 3); XCTAssertEqual(tally.recovered, 1)
        XCTAssertEqual(tally.summary, "1 stall (1 recovered, 0 GAVE UP), 3 re-arms, 0 rebuilds, 0 near-misses since launch")
    }

    func testTallyCountsAGiveUp() {
        var tally = RendererRecoveryTally()
        var w = RendererWatchdog()
        for (_, a) in run(&w, from: 0, to: 4.25, { t in self.stalled(t, enqueued: t < 0.2 ? 100 : 0) }) { tally.note(a) }
        XCTAssertEqual(tally, { var t = RendererRecoveryTally(); t.stalls = 1; t.rearms = 3; t.rebuilds = 1; t.gaveUp = 1; return t }())
        XCTAssertEqual(tally.summary, "1 stall (0 recovered, 1 GAVE UP), 3 re-arms, 1 rebuild, 0 near-misses since launch")
    }

    func testTallyNearMissAndEmpty() {
        var tally = RendererRecoveryTally()
        XCTAssertEqual(tally.summary, "0 stalls (0 recovered, 0 GAVE UP), 0 re-arms, 0 rebuilds, 0 near-misses since launch")
        tally.note(.nearMiss(lasted: 0.12, pastRecoveryPoint: false))
        tally.note(.wouldRecover(since: 0))
        XCTAssertEqual(tally.nearMisses, 1); XCTAssertEqual(tally.stalls, 1); XCTAssertEqual(tally.rearms, 0)
    }
}

private extension RendererWatchdog.Reading {
    func with(_ f: (inout Self) -> Void) -> Self { var c = self; f(&c); return c }
}
