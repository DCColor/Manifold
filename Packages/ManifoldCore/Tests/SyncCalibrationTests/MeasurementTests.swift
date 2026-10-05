//
//  MeasurementTests.swift — SyncCalibrationTests
//
//  One calibration run on a synthetic live feed: the clip's events, a heard − clock reading with
//  jitter, beeps detected ahead of their flashes (audio is scanned on arrival, flashes on display), a
//  missed flash and a missed beep. And the confidence rules and the proposal's arithmetic
//  (docs/AUDIO_RESAMPLER_DESIGN.md §19.10).
//

import XCTest
@testable import SyncCalibration

final class MeasurementTests: XCTestCase {

    private struct Feed {
        enum Event { case flash(Double, Double), beep(Double) }
        var events: [(at: Double, e: Event)] = []
    }

    /// `heard` = the true heard A/V (s); `h` = heard − clock, constant plus ± `jitter`.
    private func feed(_ clip: SyncClips.Clip, heard: Double, h: Double, jitter: Double,
                      dropFlash: Set<Int> = [], dropBeep: Set<Int> = [], loops: Int = 2) -> Feed {
        var f = Feed()
        var state: UInt64 = 11
        func u() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return 2 * Double(state >> 11) / Double(1 << 53) - 1
        }
        let clipLength = Double(clip.frameCount) * clip.frameSeconds
        var idx = 0
        for l in 0..<loops {
            for t in clip.eventTimes {
                let pts = 1000 + Double(l) * clipLength + t
                let hi = h + jitter * u()
                // The beep's content time: heard = b − (f + h) at the true h.
                let b = pts + h + heard
                if !dropFlash.contains(idx) { f.events.append((pts + 0.3, .flash(pts, hi))) }
                if !dropBeep.contains(idx) { f.events.append((b - 0.2, .beep(b))) }
                idx += 1
            }
        }
        f.events.sort { $0.at < $1.at }
        return f
    }

    private func play(_ f: Feed, into m: CalibrationMeasurement,
                      until stop: (CalibrationMeasurement) -> Bool = { _ in false }) {
        for (_, e) in f.events {
            switch e {
            case let .flash(p, h): m.addFlash(pts: p, heardMinusClock: h)
            case let .beep(b): m.addBeep(b)
            }
            if stop(m) { return }
        }
    }

    func testLocksPairsAndOffersOnlyWhenConfident() {
        for clip in SyncClips.all {
            for heard in [0.0, 0.080, -0.040, -0.076, 0.450] {
                let m = CalibrationMeasurement(frameSeconds: clip.frameSeconds)
                let f = feed(clip, heard: heard, h: -0.12, jitter: 0.0008, dropFlash: [3], dropBeep: [8])
                var offeredAt: Int?
                play(f, into: m) { m in
                    if m.snapshot.verdict == .confident, offeredAt == nil { offeredAt = m.snapshot.pairs }
                    // Before ten pairs there is never a figure.
                    if m.snapshot.pairs < 10 { XCTAssertNotEqual(m.snapshot.verdict, .confident) }
                    return false
                }
                let s = m.snapshot
                XCTAssertEqual(s.verdict, .confident, "\(clip.label) \(heard)")
                XCTAssertNotNil(offeredAt)
                XCTAssertEqual(s.median!, heard, accuracy: 0.001, "\(clip.label) \(heard)")
                // Every event but the two dropped ones' partners paired; none mispaired.
                XCTAssertEqual(s.pairs, 2 * clip.eventTimes.count - 2, "\(clip.label) \(heard)")
                for p in m.pairs { XCTAssertEqual(p.heard, heard, accuracy: 0.001) }
            }
        }
    }

    /// The clip looping, as an encoder plays it (§19.11): its event times from 0 up to `seconds`. The
    /// bundled clip is whole code cycles, so at 23.976 and 59.94 this is exactly the old 60 s clip's
    /// timeline, and the code runs on unbroken across every seam.
    private func looped(_ clip: SyncClips.Clip, _ seconds: Double) -> [Double] {
        var out: [Double] = []
        var l = 0
        while true {
            for t in clip.eventTimes {
                let x = t + Double(l) * clip.durationSeconds
                if x >= seconds { return out }
                out.append(x)
            }
            l += 1
        }
    }

    func testTheFigureIsTheRecentWindowNotTheStartUpWalk() {
        // The live shape (§19.10): the heard figure walks from +95 to +77 ms over 40 s while the
        // steering settles, then holds +80. The result must be +80, not a median over the walk.
        let clip = SyncClips.all[0]
        let m = CalibrationMeasurement(frameSeconds: clip.frameSeconds)
        var events: [(Double, Bool, Double, Double)] = []      // (arrival, isFlash, time, h)
        for (n, t) in looped(clip, 60.06).enumerated() {
            let pts = 500 + t
            let heard = t < 40 ? 0.095 - 0.018 * t / 40 : 0.080 + (n % 2 == 0 ? 0.0005 : -0.0005)
            events.append((pts + 0.3, true, pts, -0.1))
            events.append((pts - 0.1 + heard - 0.2, false, pts - 0.1 + heard, 0))
        }
        events.sort { $0.0 < $1.0 }
        var offered: Double?
        for e in events {
            if e.1 { m.addFlash(pts: e.2, heardMinusClock: e.3) } else { m.addBeep(e.2) }
            if offered == nil, m.snapshot.verdict == .confident { offered = m.snapshot.median }
        }
        XCTAssertEqual(offered ?? .nan, 0.080, accuracy: 0.001)
    }

    func testASlowWalkOffersNothingUntilItStops() {
        // The live SRT 59.94 shape: +46 ms falling to the settled −5 ms as an exponential approach
        // (fast, then slowing: the loop pulling e in). Tight pairs, so only the walk guard can hold
        // the figure back while it is still approaching; the offer must be within ±2 ms of −5.
        let clip = SyncClips.all[6]
        let m = CalibrationMeasurement(frameSeconds: clip.frameSeconds)
        var events: [(Double, Bool, Double)] = []
        for t in looped(clip, 120.12) {
            let pts = 900 + t
            let heard = -0.005 + 0.051 * exp(-t / 10)
            events.append((pts + 0.3, true, pts))
            events.append((pts + heard - 0.2, false, pts + heard))
        }
        events.sort { $0.0 < $1.0 }
        var offered: Double?
        for e in events {
            if e.1 { m.addFlash(pts: e.2, heardMinusClock: 0) } else { m.addBeep(e.2) }
            if offered == nil, m.snapshot.verdict == .confident { offered = m.snapshot.median }
        }
        XCTAssertEqual(offered ?? .nan, -0.005, accuracy: 0.002)
        // The teeth: the brief's three rules alone offer a figure mid-walk, more than 2 ms from −5.
        var rules = CalibrationMeasurement.Rules(); rules.maxWalkPerSecond = .infinity
        let bare = CalibrationMeasurement(frameSeconds: clip.frameSeconds, rules: rules)
        var bareOffer: Double?
        for e in events {
            if e.1 { bare.addFlash(pts: e.2, heardMinusClock: 0) } else { bare.addBeep(e.2) }
            if bareOffer == nil, bare.snapshot.verdict == .confident { bareOffer = bare.snapshot.median }
        }
        XCTAssertGreaterThan(abs((bareOffer ?? .nan) + 0.005), 0.002)
    }

    func testAOneIntervalWrongStartCannotLock() {
        // Beeps only, then flashes only from later in the clip: the code still finds the true pairing.
        let clip = SyncClips.all[0]
        let m = CalibrationMeasurement(frameSeconds: clip.frameSeconds)
        let f = feed(clip, heard: 0.959, h: 0, jitter: 0)   // one whole 23-frame interval at 23.976
        play(f, into: m)
        XCTAssertEqual(m.snapshot.median!, 0.959, accuracy: 1e-6)
    }

    func testSpreadAndInstabilityHoldTheFigureBack() {
        let clip = SyncClips.all[6]    // 59.94: one frame is 16.7 ms
        // ±20 ms on every flash's heard − clock: p90 − p10 ≈ 32 ms, far over one frame.
        let m = CalibrationMeasurement(frameSeconds: clip.frameSeconds)
        play(feed(clip, heard: 0.05, h: 0, jitter: 0.020), into: m)
        if case .waiting(.spread) = m.snapshot.verdict {} else {
            // The lock may also refuse such a noisy feed; either way, no figure.
            XCTAssertNotEqual(m.snapshot.verdict, .confident)
        }
        // ±4 ms of scatter on every pair (NDI's shape) with a steady median: a figure, and the right one.
        let m2 = CalibrationMeasurement(frameSeconds: clip.frameSeconds)
        play(feed(clip, heard: 0.05, h: 0, jitter: 0.004), into: m2)
        XCTAssertEqual(m2.snapshot.verdict, .confident)
        XCTAssertEqual(m2.snapshot.median!, 0.05, accuracy: 0.002)
        // A step of 6 ms in the figure: the median moves only once most of the window has stepped, and
        // nothing in between (a half-way 53 ms) is ever offered; the offer ends on the new value.
        let m4 = CalibrationMeasurement(frameSeconds: clip.frameSeconds)
        var events: [(Double, Bool, Double)] = []
        for (n, t) in looped(clip, 60.06).enumerated() {
            let heard = n < 30 ? 0.050 : 0.056
            events.append((700 + t + 0.3, true, 700 + t))
            events.append((700 + t + heard - 0.2, false, 700 + t + heard))
        }
        events.sort { $0.0 < $1.0 }
        var offers: [Double] = []
        for e in events {
            if e.1 { m4.addFlash(pts: e.2, heardMinusClock: 0) } else { m4.addBeep(e.2) }
            if m4.snapshot.verdict == .confident, m4.pairs.count > 30 { offers.append(m4.snapshot.median!) }
        }
        for o in offers { XCTAssertTrue(abs(o - 0.050) < 0.001 || abs(o - 0.056) < 0.001, "offered \(o)") }
        XCTAssertEqual(offers.last ?? .nan, 0.056, accuracy: 1e-6)
        // Unknown frame rate: never a figure.
        let m3 = CalibrationMeasurement(frameSeconds: nil)
        play(feed(clip, heard: 0.05, h: 0, jitter: 0), into: m3)
        XCTAssertEqual(m3.snapshot.verdict, .waiting(.frameRate))
    }

    func testProposalArithmetic() {
        let r = -250...500
        // Sound 76.4 ms early with O = 0: +76 ms.
        var p = CalibrationProposal(currentMs: 0, residualSeconds: -0.0764, range: r, availableAdvanceSeconds: nil)
        XCTAssertEqual(p.proposedMs, 76); XCTAssertTrue(p.applicable); XCTAssertFalse(p.clamped)
        // Re-run with +76 applied, residual +0.6 ms: stays (in sync), nothing to apply.
        p = CalibrationProposal(currentMs: 76, residualSeconds: 0.0004, range: r, availableAdvanceSeconds: 0.2)
        XCTAssertEqual(p.proposedMs, 76); XCTAssertTrue(p.inSync); XCTAssertFalse(p.applicable)
        // +80 ms late: −80, an advance, applicable only if the queue allows it.
        p = CalibrationProposal(currentMs: 0, residualSeconds: 0.080, range: r, availableAdvanceSeconds: 0.030)
        XCTAssertEqual(p.proposedMs, -80); XCTAssertEqual(p.advanceMs, 80); XCTAssertFalse(p.applicable)
        XCTAssertEqual(p.availableAdvanceMs!, 30, accuracy: 1e-9)
        p = CalibrationProposal(currentMs: 0, residualSeconds: 0.080, range: r, availableAdvanceSeconds: 0.080)
        XCTAssertTrue(p.applicable)
        // Clamped to the range.
        p = CalibrationProposal(currentMs: 0, residualSeconds: -0.6, range: r, availableAdvanceSeconds: nil)
        XCTAssertEqual(p.unclampedMs, 600); XCTAssertEqual(p.proposedMs, 500); XCTAssertTrue(p.clamped)
        p = CalibrationProposal(currentMs: -200, residualSeconds: 0.1, range: r, availableAdvanceSeconds: 1)
        XCTAssertEqual(p.proposedMs, -250); XCTAssertTrue(p.clamped)
        // Rounding is to the nearest ms.
        p = CalibrationProposal(currentMs: 10, residualSeconds: 0.0125, range: r, availableAdvanceSeconds: 1)
        XCTAssertEqual(p.proposedMs, -3)
    }
}
