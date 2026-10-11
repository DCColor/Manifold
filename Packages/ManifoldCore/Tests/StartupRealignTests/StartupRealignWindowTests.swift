//
//  StartupRealignWindowTests.swift — StartupRealignTests
//
//  The windowed start-up realign's mean (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, *The B-frame
//  start-up offset*), on the depth signal the renderer actually produces: newest queued PTS − now
//  + Δ/2, sampled at the display tick, on a stream whose newest PTS advances by a whole step when
//  a leading picture arrives.
//

import XCTest
@testable import StartupRealign

final class StartupRealignWindowTests: XCTestCase {

    private let delta = 1001.0 / 24000.0
    private let cushion = 0.259

    /// Feeds the window display-tick samples of the renderer's depth (anchor at t = 0, rate 1, so
    /// now = t − cushion) until it answers. Leading pictures arrive every `step` from `phase`, picture
    /// k carrying PTS k·step; before the first, the backlog's newest is PTS −step.
    private func measure(teeth: Int, tick: Double, step: Double, phase: Double)
        -> (mean: Double, window: StartupRealignWindow) {
        var w = StartupRealignWindow(teeth: teeth)
        var t = tick
        while t < 60 {
            let k = (t - phase) >= 0 ? Double(Int(((t - phase) / step).rounded(.down))) : -1
            let newest = k * step
            if let mean = w.add(span: newest - (t - cushion) + delta / 2, newest: newest) { return (mean, w) }
            t += tick
        }
        XCTFail("the window never answered"); return (.nan, w)
    }

    /// The exact mean of the sawtooth: each tooth falls from cushion + Δ/2 − phase over one step.
    private func exact(step: Double, phase: Double) -> Double { cushion + delta / 2 - phase - step / 2 }

    /// Four whole teeth give the sawtooth's mean wherever the anchor fell, for one-frame, mini-GOP and
    /// deep-pyramid teeth. At a 120 Hz tick the sampled mean is within one tick: every tooth's
    /// samples start on the first tick at or after its jump, which is up to a tick late.
    func testFourWholeTeethGiveTheMeanAtEveryPhase() {
        let tick = 1.0 / 120
        for step in [delta, 4 * delta, 9 * delta] {
            for j in 0..<12 {
                let phase = step * Double(j) / 12 + 0.0001
                let r = measure(teeth: 4, tick: tick, step: step, phase: phase)
                XCTAssertEqual(r.mean, exact(step: step, phase: phase), accuracy: tick + 1e-9,
                               "step \(step) phase \(phase)")
                XCTAssertEqual(r.window.advances, 4)
            }
        }
    }

    /// A sender that delivers pictures in PAIRS makes two-frame teeth on a stream with no B-frames —
    /// the case where step 2's one-frame window measured half a tooth and realigned +14…+19 ms. Whole
    /// teeth are exact there too.
    func testPairedArrivalsAreWholeTeeth() {
        let tick = 1.0 / 120, step = 2 * delta
        for j in 0..<8 {
            let phase = step * Double(j) / 8 + 0.0001
            let r = measure(teeth: 4, tick: tick, step: step, phase: phase)
            XCTAssertEqual(r.mean, exact(step: step, phase: phase), accuracy: tick + 1e-9)
        }
    }

    /// Nothing opens the window until the newest PTS advances: a tooth cannot be measured from its
    /// middle.
    func testWaitsForTheFirstAdvance() {
        var w = StartupRealignWindow(teeth: 1)
        for i in 0..<100 { XCTAssertNil(w.add(span: Double(i), newest: 5)) }
        XCTAssertFalse(w.opened)
        XCTAssertNil(w.add(span: 1, newest: 6))
        XCTAssertTrue(w.opened)
    }

    /// The window closes on the sample that sees the last advance, and that sample (the next tooth's
    /// top) is not in the mean.
    func testTheClosingSampleIsExcluded() {
        var w = StartupRealignWindow(teeth: 2)
        XCTAssertNil(w.add(span: 9, newest: 0))     // before anything has advanced
        XCTAssertNil(w.add(span: 3, newest: 1))     // opens: tooth 1
        XCTAssertNil(w.add(span: 1, newest: 1))
        XCTAssertNil(w.add(span: 3, newest: 2))     // tooth 2
        XCTAssertNil(w.add(span: 1, newest: 2))
        XCTAssertEqual(w.add(span: 100, newest: 3), 2)
        XCTAssertEqual(w.count, 4)
    }

    /// A restart drops what was measured; the next advance opens it again.
    func testRestartStartsAgain() {
        var w = StartupRealignWindow(teeth: 1)
        _ = w.add(span: 7, newest: 0)
        _ = w.add(span: 7, newest: 1)
        w.restart()
        XCTAssertFalse(w.opened)
        XCTAssertNil(w.add(span: 2, newest: 1))     // no advance: still closed
        XCTAssertNil(w.add(span: 2, newest: 2))     // opens
        XCTAssertNil(w.add(span: 4, newest: 2))
        XCTAssertEqual(w.add(span: 50, newest: 3), 3)
    }

    /// 0 or fewer teeth is today's behaviour: disabled, never answers.
    func testDisabledNeverAnswers() {
        for teeth in [0, -3] {
            var w = StartupRealignWindow(teeth: teeth)
            XCTAssertFalse(w.isEnabled)
            for i in 0..<100 { XCTAssertNil(w.add(span: 0.3, newest: Double(i))) }
        }
    }
}
