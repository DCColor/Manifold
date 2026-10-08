//
//  LiveAudioOffsetTests.swift
//  LiveAudioResampleTests
//
//  The per-source audio offset O, stage A (docs/AUDIO_RESAMPLER_DESIGN.md §19.1, §19.7): O lives in
//  the steering's line, and a change moves the line and requests the matching splice in one step.
//
//  On `QueuePlant` (LiveAudioStarvationHoldTests): content arrives, is laid on the output axis, and
//  a splice is consumed at the input and heard a queue later. Two figures per 100 ms:
//    heard  = the picture's line WITHOUT O − the content heard (+ = the audio heard later): the
//             at-glass quantity, which must move by each ΔO;
//    e      = content heard + splice correction ahead − (the line WITH O): what the loop sees, which
//             must not step.
//

import XCTest
@testable import LiveAudioResample

final class LiveAudioOffsetTests: XCTestCase {

    typealias S = LiveAudioResampleSteering

    struct Run {
        var heard: [(t: Double, h: Double)] = []
        var loopErr: [(t: Double, e: Double)] = []
        var debt: [(t: Double, d: Double)] = []
        var outcomes: [(t: Double, o: S.UserOffsetOutcome)] = []
        /// The renderer queue at the moment of each change request (frontier − timebase): the
        /// MOMENTARY figure the stage A rule judged an advance on.
        var queueAtChange: [Double] = []
        var totals = S.Totals()
        var granted: [Double] = []
        var writes = 0
        var maxDry = 0.0
        /// What the first anchor returned: a refused saved advance, or nil.
        var startRefusal: S.StartOffsetRefusal?
    }

    /// `changes`: (host s, O) requested at that time. `stall`: (at, seconds, catch-up ×). `ndi`: no
    /// mapping — the line is the anchor's alone, as NDI's (§2.8). The line is content `100 + t`.
    func run(lead: Double = 0.340, seconds: Double, startOffset: Double = 0,
             changes: [(at: Double, o: Double)] = [], stall: (at: Double, s: Double, k: Double)? = nil,
             ndi: Bool = false, reanchorAt: Double? = nil, mode: S.Mode = .loop,
             sampledBeforeAnchor: Bool = false) -> Run {
        let p = QueuePlant()
        final class Box: @unchecked Sendable { var at = Double.infinity }
        let deadline = Box()
        let s = S(tag: "[TEST-OFFSET]", mode: mode, clock: p, gains: .adopted, thresholds: .adopted,
                  reportsWindows: false, readTimebase: { p.timebase }, hostNow: { p.host },
                  write: { o, h, why in p.write(o, h, why) }, hold: { o, h in p.hold(o, h) },
                  armDeadline: { deadline.at = $0 }, log: nil)
        let line: (Double) -> Double = { 100 + $0 }
        var out = Run()
        var sent = line(0) + lead
        p.arrived = line(0)
        p.pieces = [.init(outStart: 0, outEnd: 0, content: line(0), rho: 1)]
        p.deliver(upTo: sent)
        if startOffset != 0 { out.outcomes.append((0, s.setUserOffset(startOffset))) }
        // The app's order: the sink enqueues (and samples) before the first anchor, while the
        // renderer holds the queue at rate 0. Off by default, as every test here was written.
        final class RefusalBox: @unchecked Sendable { var r: S.StartOffsetRefusal? }
        let refusalBox = RefusalBox()
        s.onStartOffsetRefused = { refusalBox.r = $0 }
        if sampledBeforeAnchor { s.sample(enqueuedFrontier: p.frontier) }
        s.anchor(media: line(0), host: 0)
        var pendingChanges = changes
        var lastSend = 0.0, nextRef = 0.0, dryStart: Double?, reanchored = false
        var t = 0.0
        while t < seconds {
            t += 0.001; p.host = t
            if !ndi, t >= nextRef { s.setReference(media: line(t), host: t, rate: 1, pictureLate: max(0, line(t) - sent)); nextRef += 0.1 }
            if let r = reanchorAt, !reanchored, t >= r { reanchored = true; s.anchor(media: line(t), host: t, reason: "test re-anchor") }
            while let c = pendingChanges.first, t >= c.at {
                pendingChanges.removeFirst()
                out.queueAtChange.append(p.frontier - p.timebase)
                out.outcomes.append((t, s.setUserOffset(c.o)))
            }
            let stalled = stall.map { t >= $0.at && t < $0.at + $0.s } ?? false
            if stalled { lastSend = t }
            if !stalled, t - lastSend >= 0.0213 {
                let rate = stall.map { t >= $0.at + $0.s ? $0.k : 1 } ?? 1
                let next = min(line(t) + lead, sent + (t - lastSend) * rate)
                if next > sent + 1e-6 {
                    sent = next
                    p.deliver(upTo: sent)
                    s.sample(enqueuedFrontier: p.frontier)
                }
                lastSend = t
            }
            if t >= deadline.at { deadline.at = .infinity; s.starvationCheck() }
            let tb = p.timebase
            if tb > p.frontier + 1e-6 {
                if dryStart == nil { dryStart = t }
                out.maxDry = max(out.maxDry, t - dryStart!)
            } else { dryStart = nil }
            if Int((t * 1000).rounded()) % 100 == 0 {
                let heardContent = p.inputTime(atOutputTime: tb)
                out.heard.append((t, line(t) - heardContent))
                out.loopErr.append((t, heardContent + p.spliceCorrectionAhead(ofOutputTime: tb)
                                    - (line(t) - s.userOffsetSeconds)))
                out.debt.append((t, s.totals.recoveryOffset))
            }
        }
        s.finish()
        out.startRefusal = refusalBox.r
        out.totals = s.totals
        out.granted = p.granted
        out.writes = p.writes.count + p.holds
        return out
    }

    func heard(_ r: Run, at t: Double) -> Double {
        r.heard.min { abs($0.t - t) < abs($1.t - t) }!.h
    }

    // MARK: - A change is one splice, and the loop sees nothing

    /// Robbie's live sequence, 0 → +80 → +200 → −40 → 0 ms: each change is ONE splice of −ΔO, the
    /// heard figure moves by ΔO once the queue in front of the splice has played out, and e, the
    /// triggers, ρ, D and the write count are exactly what they are with no change at all.
    func testChangesAreOneSpliceEachAndTheLoopSeesNothing() {
        let plan: [(at: Double, o: Double)] = [(30, 0.080), (50, 0.200), (70, -0.040), (90, 0)]
        let r = run(seconds: 120, changes: plan)
        let none = run(seconds: 120)
        XCTAssertEqual(r.outcomes.count, 4)
        var old = 0.0
        for ((_, outcome), c) in zip(r.outcomes, plan) {
            guard case let .applied(o, n, splice) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(o, old); XCTAssertEqual(n, c.o)
            XCTAssertEqual(splice, -(c.o - old), accuracy: 1 / 48000.0, "one splice of −ΔO")
            old = c.o
        }
        XCTAssertEqual(r.granted.count, 4, "one splice per change, nothing else")
        XCTAssertEqual(r.totals.userOffsetChanges, 4)
        XCTAssertEqual(r.totals.userOffset, 0)
        // Nothing written, no trigger, no recovery.
        XCTAssertEqual(r.writes, 1)
        XCTAssertEqual(r.totals.writes, 1)
        XCTAssertEqual(r.totals.coarseLevel + r.totals.coarseStep, 0)
        XCTAssertEqual(r.totals.splices, 0, "no coarse splice")
        XCTAssertEqual(r.totals.residualSplices + r.totals.recoveryDrops, 0)
        XCTAssertEqual(r.maxDry, 0)
        // e continuous: never more than a sample's rounding off the line, through every change.
        XCTAssertLessThan(r.loopErr.filter { $0.t > 5 }.map { abs($0.e) }.max()!, 0.0005)
        // ρ unchanged: the same as the run with no change.
        XCTAssertEqual(r.totals.maxAbsRhoMinusOne, none.totals.maxAbsRhoMinusOne, accuracy: 0.5e-6)
        XCTAssertEqual(r.totals.rho, none.totals.rho, accuracy: 0.5e-6)
        // D never takes O.
        XCTAssertEqual(r.debt.map(\.d).max()!, 0)
        // Heard moves by ΔO: on the old value until the queue in front of the splice plays out
        // (≤ the queue, ~0.34 s + O), on the new one from there, within a sample.
        for (k, c) in plan.enumerated() {
            let before = k == 0 ? 0 : plan[k - 1].o
            XCTAssertEqual(heard(r, at: c.at - 0.05), before, accuracy: 0.0005, "before change \(k)")
            XCTAssertEqual(heard(r, at: c.at + 1.0), c.o, accuracy: 0.0005, "after change \(k)")
        }
    }

    /// A start value (`MANIFOLD_AUDIO_OFFSET_MS`) set before the anchor is placed BY the anchor:
    /// no splice, the one write, heard = O from the start.
    func testAStartValueIsPlacedByTheFirstAnchor() {
        let r = run(seconds: 30, startOffset: 0.120)
        guard case .pending(0, 0.120) = r.outcomes.first!.o else { return XCTFail("\(r.outcomes)") }
        XCTAssertEqual(r.granted.count, 0)
        XCTAssertEqual(r.writes, 1)
        XCTAssertEqual(heard(r, at: 5), 0.120, accuracy: 0.0005)
        XCTAssertLessThan(r.loopErr.filter { $0.t > 1 }.map { abs($0.e) }.max()!, 0.0005)
    }

    // MARK: - A saved advance is judged at playback start (COLOR_MANAGEMENT_FINDINGS.md §6.10, decision 7)

    struct StartRun {
        var refusal: S.StartOffsetRefusal?
        var offset = 0.0
        var writes: [S.WriteOrigin] = []
        var maxDry = 0.0
        var heardAt5 = 0.0
    }

    /// SRT's start, as the 2026-10-08 OBS run logged it: the picture's first anchor is placed `fill`
    /// in the FUTURE with NOTHING enqueued (audio before the video anchor is dropped), and the audio
    /// then arrives in real time, `interleave` ahead of the picture's line. At playback start the queue
    /// is fill + interleave (0.34 s, local SRT's measured lead).
    func srtStart(offset: Double, fill: Double = 0.250, interleave: Double = 0.090) -> StartRun {
        let p = QueuePlant()
        p.writeLatency = 0
        final class Box: @unchecked Sendable { var r: S.StartOffsetRefusal?; var at = Double.infinity }
        let box = Box()
        let s = S(tag: "[TEST-START]", mode: .loop, clock: p, gains: .adopted, thresholds: .adopted,
                  reportsWindows: false, readTimebase: { p.timebase }, hostNow: { p.host },
                  write: { o, h, why in p.write(o, h, why) }, hold: { o, h in p.hold(o, h) },
                  armDeadline: { box.at = $0 }, log: nil)
        s.onStartOffsetRefused = { box.r = $0 }
        let line: (Double) -> Double = { 100 + $0 - fill }      // the picture's line: 100 heard at `fill`
        p.arrived = 100
        p.pieces = [.init(outStart: 0, outEnd: 0, content: 100, rho: 1)]
        _ = s.setUserOffset(offset)
        s.anchor(media: 100, host: fill)                        // t = 0, nothing enqueued
        var out = StartRun()
        var lastSend = -1.0, nextRef = 0.0, t = 0.0, dryStart: Double?
        while t < 6 {
            t += 0.001; p.host = t
            if t >= nextRef { s.setReference(media: line(t), host: t, rate: 1); nextRef += 0.1 }
            if t - lastSend >= 0.0213 {
                p.deliver(upTo: 100 + t + interleave)
                s.sample(enqueuedFrontier: p.frontier)
                lastSend = t
            }
            if t >= box.at { box.at = .infinity; s.starvationCheck() }
            let tb = p.timebase
            if t > fill, tb > p.frontier + 1e-6 {
                if dryStart == nil { dryStart = t }
                out.maxDry = max(out.maxDry, t - dryStart!)
            } else { dryStart = nil }
            if abs(t - 5) < 0.0005 { out.heardAt5 = line(t) - p.inputTime(atOutputTime: tb) }
        }
        s.finish()
        out.refusal = box.r
        out.offset = s.totals.userOffset
        out.writes = p.writes
        return out
    }

    /// −100 ms: ~180 ms is available at playback start, so it is placed exactly as before — the one
    /// write, heard = O from the start, never dry.
    func testASavedAdvanceTheQueueCoversIsPlacedAtPlaybackStart() {
        let r = srtStart(offset: -0.100)
        XCTAssertNil(r.refusal)
        XCTAssertEqual(r.offset, -0.100)
        XCTAssertEqual(r.writes, [.firstAnchor])
        XCTAssertEqual(r.heardAt5, -0.100, accuracy: 0.0005)
        XCTAssertEqual(r.maxDry, 0)
    }

    /// −250 ms (the OBS run that broke up at an 87 ms queue): refused WHOLE before anything plays —
    /// the anchor written again without O, heard 0 from the start, the queue and the figure stated.
    func testASavedAdvanceBeyondTheQueueIsRefusedBeforePlayback() {
        let r = srtStart(offset: -0.250)
        guard let refusal = r.refusal else { return XCTFail("not refused") }
        XCTAssertEqual(refusal.requested, -0.250)
        XCTAssertEqual(refusal.queue, 0.340, accuracy: 0.022, "the queue at playback start, within a packet")
        XCTAssertEqual(refusal.available, refusal.queue - 0.160, accuracy: 1e-9)
        XCTAssertEqual(r.offset, 0, "refused whole, never clamped")
        XCTAssertEqual(r.writes, [.firstAnchor, .reanchor("saved advance refused before playback")])
        XCTAssertEqual(r.heardAt5, 0, accuracy: 0.0005)
        XCTAssertEqual(r.maxDry, 0)
    }

    /// Judged at the anchor, as 0b-2a first did, the queue is EMPTY by construction on this start —
    /// which is why the judgement moved. Nothing is enqueued at t = 0 here, and −250 is still refused.
    func testTheJudgementWaitsForTheStartupFill() {
        XCTAssertNotNil(srtStart(offset: -0.250).refusal)
        XCTAssertNil(srtStart(offset: -0.150).refusal, "0.34 − 0.16 = 0.18 available")
        XCTAssertNotNil(srtStart(offset: -0.200).refusal)
    }

    /// A shallower lead (Cloudflare SRT's ~205 ms): even −50 ms is refused.
    func testAShallowLeadRefusesSmallAdvances() {
        let r = srtStart(offset: -0.050, interleave: -0.045)
        XCTAssertNotNil(r.refusal)
        XCTAssertEqual(r.offset, 0)
    }

    /// A delay (O > 0) is never judged: it deepens the queue.
    func testASavedDelayIsNeverJudged() {
        let r = srtStart(offset: 0.400)
        XCTAssertNil(r.refusal)
        XCTAssertEqual(r.offset, 0.400)
        XCTAssertEqual(r.writes, [.firstAnchor])
    }

    /// The harness's own start (content enqueued before an anchor at "now"): judged on the first
    /// buffer after it — late by one packet, so a refusal is a re-anchor — and placed when covered.
    func testAnAnchorAtNowIsJudgedOnTheNextBuffer() {
        XCTAssertNil(run(seconds: 5, startOffset: -0.100, sampledBeforeAnchor: true).startRefusal)
        let r = run(seconds: 5, startOffset: -0.250, sampledBeforeAnchor: true)
        XCTAssertNotNil(r.startRefusal)
        XCTAssertEqual(r.totals.userOffset, 0)
    }

    // MARK: - A stall with O ≠ 0: hold, resume and recovery land on line − O; D never takes O

    func testStallWithAnOffsetRecoversOntoTheLineLessO() {
        // (stall, catch-up): slow tracking cuts, a burst (resume on the target), and a burst over a
        // few packets (the catch-up write onto the line).
        for (stall, k) in [(1.0, 1.05), (1.0, 1000.0), (2.0, 30.0)] {
            for o in [0.150, -0.100] {
                let r = run(seconds: 140, changes: [(20, o)], stall: (60, stall, k))
                let base = run(seconds: 140, stall: (60, stall, k))
                let what = String(format: "O %+.0f ms, %.0f ms stall at %.2f×", o * 1000, stall * 1000, k)
                print(String(format: "[§19.7] %@: heard−O at 135 s %+.2f ms (O = 0 run: %+.2f ms) · e %+.2f ms (O = 0: %+.2f) · D max %.0f ms (O = 0: %.0f) · cuts %d (O = 0: %d)",
                             what, (heard(r, at: 135) - o) * 1000, heard(base, at: 135) * 1000,
                             r.loopErr.last!.e * 1000, base.loopErr.last!.e * 1000,
                             r.debt.map(\.d).max()! * 1000, base.debt.map(\.d).max()! * 1000,
                             r.totals.recoveryDrops, base.totals.recoveryDrops))
                guard case .applied = r.outcomes[0].o else { return XCTFail("\(what): \(r.outcomes)") }
                XCTAssertEqual(r.totals.holds, 1, what)
                XCTAssertEqual(r.maxDry, 0, what)
                XCTAssertEqual(r.totals.recoveryOffset, 0, what)
                // Back on line − O, and heard = O: the recovery did not cut O back out. What is left
                // is the loop's own residual after the recovery, the same as with O = 0 (−2.65 ms at
                // 1.05×, still converging at ≤ 2 ms/s), so the two runs are compared.
                XCTAssertEqual(heard(r, at: 135) - o, heard(base, at: 135), accuracy: 0.001, what)
                XCTAssertEqual(r.loopErr.last!.e, base.loopErr.last!.e, accuracy: 0.001, what)
                XCTAssertEqual(heard(r, at: 135), o, accuracy: 0.005, what)
                // D is the physical debt: the queue was O deeper at the stall (O > 0) or shallower
                // (O < 0), so the time held and the debt are O less (or more) — never O MORE.
                let dO = r.debt.map(\.d).max()!, d0 = base.debt.map(\.d).max()!
                if d0 > 0 {
                    XCTAssertEqual(dO, max(0, d0 - o), accuracy: 0.030, "\(what): D \(dO) vs \(d0)")
                }
                XCTAssertEqual(r.writes, base.writes, "\(what): no extra write")
            }
        }
    }

    /// An O change WHILE a debt is owed: D is unchanged by it (the line and the content move together).
    func testAChangeDuringRecoveryLeavesTheDebtAlone() {
        let r = run(seconds: 160, changes: [(63, 0.050)], stall: (60, 2.0, 1.05))
        guard case .applied = r.outcomes[0].o else { return XCTFail("\(r.outcomes)") }
        let before = r.debt.last { $0.t < 63 }!.d, after = r.debt.first { $0.t > 63 }!.d
        XCTAssertGreaterThan(before, 0.5, "the debt is owed at the change")
        XCTAssertEqual(after, before, accuracy: 0.003, "D does not take ΔO")
        XCTAssertEqual(r.totals.recoveryOffset, 0)
        // The loop's residual after a 1.05× recovery is a few ms either way (see above).
        XCTAssertEqual(heard(r, at: 155), 0.050, accuracy: 0.005)
    }

    // MARK: - Refusals

    /// An advance larger than the queue allows is REFUSED whole, and the refusal reports the most
    /// available now: queue − 100 keep − 10 fade − 50 margin.
    func testAnAdvancePastTheGuardIsRefusedWithTheAvailableFigure() {
        let r = run(seconds: 40, changes: [(10, -0.250), (15, -0.150), (25, -0.200)])
        guard case let .refusedAdvance(old, requested, available, queue) = r.outcomes[0].o else {
            return XCTFail("\(r.outcomes[0])")
        }
        XCTAssertEqual(old, 0); XCTAssertEqual(requested, -0.250)
        XCTAssertEqual(queue, 0.33, accuracy: 0.0215, "the queue at a 340 ms lead, between packets")
        XCTAssertEqual(available, queue - 0.160, accuracy: 1e-9)
        guard case .applied(0, -0.150, _) = r.outcomes[1].o else { return XCTFail("\(r.outcomes[1])") }
        // The queue is now 150 ms shallower: a further 50 ms needs 210 ms and is refused.
        guard case let .refusedAdvance(o2, _, a2, q2) = r.outcomes[2].o else { return XCTFail("\(r.outcomes[2])") }
        XCTAssertEqual(o2, -0.150)
        XCTAssertEqual(q2, 0.18, accuracy: 0.0215)
        XCTAssertEqual(a2, max(0, q2 - 0.160), accuracy: 1e-9)
        XCTAssertEqual(r.granted.count, 1, "a refusal splices nothing")
        XCTAssertEqual(r.totals.userOffset, -0.150)
        XCTAssertEqual(r.totals.userOffsetRefusals, 2)
        XCTAssertEqual(r.writes, 1)
        XCTAssertEqual(heard(r, at: 39), -0.150, accuracy: 0.0005)
    }

    /// §19.8 follow-up: the refusal's "at most N ms" is judged on the LOWEST queue over the recent
    /// window, so pressing exactly N ms a few seconds later is accepted. The plant's queue oscillates
    /// by one packet (21.3 ms, an AAC frame: SRT's case). Ten request phases across one packet cycle:
    /// every one states a figure that a press of that size, 3 s later, gets. The stage A figure (the
    /// momentary queue) promised more than the queue gives on some phases, and that press is refused.
    func testTheStatedAdvanceIsAcceptedOnALaterPress() {
        var momentaryPromisedTooMuch = 0
        for k in 0..<10 {
            let at = 20.0 + Double(k) * 0.00213
            // −150 leaves ~170–190 ms of queue; −250 then needs 260 and is refused.
            let base: [(at: Double, o: Double)] = [(10, -0.150), (at, -0.250)]
            let r = run(seconds: at + 1, changes: base)
            guard case let .refusedAdvance(_, _, available, queue) = r.outcomes[1].o else {
                return XCTFail("phase \(k): \(r.outcomes[1].o)")
            }
            XCTAssertLessThanOrEqual(queue, r.queueAtChange[1] + 1e-9, "phase \(k): never above the queue now")
            let stated = (available * 1000).rounded(.down) / 1000      // what the banner says, whole ms
            XCTAssertGreaterThan(stated, 0, "phase \(k): a figure worth stating")
            // Press exactly that amount 3 s later: accepted.
            let r2 = run(seconds: at + 5, changes: base + [(at + 3, -0.150 - stated)])
            guard case .applied(_, let new, _) = r2.outcomes[2].o else {
                return XCTFail("phase \(k): stated \(stated * 1000) ms, then \(r2.outcomes[2].o)")
            }
            XCTAssertEqual(new, -0.150 - stated, accuracy: 1e-12)
            // And one ms more than stated is refused: the figure is the most there is.
            let r3 = run(seconds: at + 5, changes: base + [(at + 3, -0.151 - stated)])
            guard case .refusedAdvance = r3.outcomes[2].o else {
                return XCTFail("phase \(k): one ms past the stated figure was \(r3.outcomes[2].o)")
            }
            // The stage A figure: the momentary queue at the refusal.
            let momentary = ((r.queueAtChange[1] - 0.160) * 1000).rounded(.down) / 1000
            if momentary > stated {
                let r4 = run(seconds: at + 5, changes: base + [(at + 3, -0.150 - momentary)])
                if case .refusedAdvance = r4.outcomes[2].o { momentaryPromisedTooMuch += 1 }
            }
        }
        XCTAssertGreaterThan(momentaryPromisedTooMuch, 0,
                             "the test has teeth: the momentary figure was refused on a later press")
        print("[§19.8] momentary figure refused on a later press on \(momentaryPromisedTooMuch) / 10 phases")
    }

    func testValuesOutsideTheRangeAreRejected() {
        XCTAssertEqual(S.userOffsetRange, -0.250...0.500)
        let r = run(seconds: 20, changes: [(5, 0.501), (6, -0.251), (7, .nan), (8, 0.500)])
        for k in 0..<3 {
            guard case .outOfRange = r.outcomes[k].o else { return XCTFail("\(r.outcomes[k])") }
        }
        guard case .applied(0, 0.500, _) = r.outcomes[3].o else { return XCTFail("\(r.outcomes[3])") }
        XCTAssertEqual(r.granted.count, 1)
        XCTAssertEqual(r.totals.userOffsetRefusals, 3)
        XCTAssertEqual(heard(r, at: 19), 0.500, accuracy: 0.0005)
    }

    func testPinnedHasNoOffset() {
        let r = run(seconds: 10, changes: [(5, 0.100)], mode: .pinned)
        guard case .disabledPinned(0.100) = r.outcomes[0].o else { return XCTFail("\(r.outcomes)") }
        XCTAssertEqual(r.totals.userOffset, 0)
        XCTAssertEqual(r.granted.count, 0)
        XCTAssertEqual(heard(r, at: 9), 0, accuracy: 0.0005)
    }

    // MARK: - NDI: the anchor line carries O

    /// NDI has no mapping: its line is its anchor (`mediaNow − lead`). The first anchor places the
    /// content O behind it, a change takes the same entry point (one splice, no re-anchor), and a
    /// later re-anchor (a Desktop Audio Lead change) keeps O.
    func testNDIAnchorLineCarriesO() {
        let r = run(lead: 0.250, seconds: 60, startOffset: 0.080, changes: [(20, 0.030)], ndi: true,
                    reanchorAt: 40)
        XCTAssertEqual(heard(r, at: 15), 0.080, accuracy: 0.0005, "placed by the first anchor")
        guard case .applied(0.080, 0.030, _) = r.outcomes[1].o else { return XCTFail("\(r.outcomes)") }
        XCTAssertEqual(heard(r, at: 35), 0.030, accuracy: 0.0005, "one splice, no re-anchor")
        XCTAssertEqual(r.granted.count, 1)
        XCTAssertEqual(heard(r, at: 55), 0.030, accuracy: 0.0005, "a re-anchor keeps O")
        XCTAssertEqual(r.writes, 2, "the first anchor and the test's re-anchor, nothing for O")
        XCTAssertLessThan(r.loopErr.filter { $0.t > 1 }.map { abs($0.e) }.max()!, 0.0005)
    }

    // MARK: - The SDI read

    /// The tap read with O: `startTime − O`, a change crossfaded (equal power, 10 ms) from the old
    /// position, and the plain read again once cleared at the session's end.
    func testTapReadWithOffsetCrossfadesAndClears() {
        let rate = 48000.0, ch = 2
        // The ring: frame f (source time 10 + f/rate) holds f on channel 0 and −f on channel 1.
        func base(_ t: Double, _ n: Int, _ dst: UnsafeMutablePointer<Int32>) -> Int {
            let f0 = Int(((t - 10) * rate).rounded())
            guard f0 >= 0, f0 < 480_000 else { return 0 }
            for i in 0..<n { dst[i * ch] = Int32(f0 + i); dst[i * ch + 1] = -Int32(f0 + i) }
            return n
        }
        var fader = LiveReadOffsetFader()
        var buf = [Int32](repeating: 0, count: 2048 * ch), ref = buf
        func read(_ t: Double, _ n: Int) -> Int {
            buf.withUnsafeMutableBufferPointer { b in
                fader.read(startTime: t, frameCount: n, channels: ch, sampleRate: rate, into: b.baseAddress!, base: base)
            }
        }
        // O = 0: exactly the plain read.
        XCTAssertTrue(fader.isIdentity)
        XCTAssertEqual(read(11.0, 1024), 1024)
        _ = ref.withUnsafeMutableBufferPointer { base(11.0, 1024, $0.baseAddress!) }
        XCTAssertEqual(buf, ref)
        // O = +100 ms: the first 480 frames fade from the old position to the new, then the new.
        fader.set(0.100)
        XCTAssertEqual(read(11.0, 1024), 1024)
        let old0 = 48000, new0 = 48000 - 4800
        for i in [0, 100, 239, 479] {
            let th = Double.pi / 2 * (Double(i) + 0.5) / 480
            let want = (Double(old0 + i) * cos(th) + Double(new0 + i) * sin(th)).rounded()
            XCTAssertEqual(Double(buf[i * ch]), want, accuracy: 1, "fade frame \(i)")
            XCTAssertEqual(Double(buf[i * ch + 1]), -want, accuracy: 1)
        }
        for i in 480..<1024 { XCTAssertEqual(buf[i * ch], Int32(new0 + i)) }
        // The next read is on the new position with no fade.
        XCTAssertEqual(read(11.0 + 1024 / rate, 256), 256)
        XCTAssertEqual(buf[0], Int32(new0 + 1024))
        // A fade spanning two reads carries its position across them.
        fader.set(0.050)
        XCTAssertEqual(read(12.0, 300), 300)
        XCTAssertEqual(read(12.0 + 300 / rate, 300), 300)
        let th = Double.pi / 2 * (300 + 0.5) / 480
        let want = (Double(96000 - 4800 + 300) * cos(th) + Double(96000 - 2400 + 300) * sin(th)).rounded()
        XCTAssertEqual(Double(buf[0]), want, accuracy: 1)
        XCTAssertEqual(buf[180 * ch], Int32(96000 - 2400 + 480), "fade over after 480 frames")
        // The session ends: cleared at once, the plain read again.
        fader.clear()
        XCTAssertTrue(fader.isIdentity)
        XCTAssertEqual(read(11.0, 1024), 1024)
        XCTAssertEqual(buf, ref)
    }

    // MARK: - The WHEP level hold (observe-only): re-based on a change, the change window excluded

    func testLevelHoldRebasesOnAnOffsetChange() {
        func feed(rebase: Bool) -> (SenderReportSlopeCrossCheck, [String]) {
            let c = SenderReportSlopeCrossCheck(tag: "[T]")
            var lines: [String] = []
            for k in 0...150 {
                let t = Double(k) * 10
                // A healthy session: depth 400 ms; O +200 ms accepted in the window ending at 600 s.
                let changed = k == 60
                if changed && rebase { c.noteUserOffsetMove(0.200) }
                let depth = 0.400 + (t >= 600 ? 0.200 : 0)
                lines += c.note(time: t, videoTime: t, rendererDepth: depth, appliedOffset: 0, srOffset: 0,
                                appliedSlope: 0, reportsInfo: false, excluded: changed && rebase,
                                loop: .init(saturated: false, integral: 0, liveClockBufferError: 0))
            }
            return (c, lines)
        }
        let (c, lines) = feed(rebase: true)
        XCTAssertEqual(c.reference!, 0.600, accuracy: 1e-9, "D_ref re-based by ΔO")
        XCTAssertEqual(c.levelError!, 0, accuracy: 1e-9)
        XCTAssertEqual(c.engageCount, 0)
        XCTAssertEqual(c.warningCount, 0)
        XCTAssertEqual(c.latest!.implied, 0, accuracy: 1e-12, "the slope check reads no step")
        XCTAssertFalse(lines.contains { $0.contains("ENGAGE") })
        XCTAssertTrue(c.summary(atVideoTime: 1500, time: 1500).contains("1 audio-offset change(s) re-based"))
        // Without the re-base the same step reads as SR error: the test has teeth.
        let (u, uLines) = feed(rebase: false)
        XCTAssertEqual(u.levelError!, 0.200, accuracy: 1e-9)
        XCTAssertTrue(uLines.contains { $0.contains("WOULD ENGAGE") })
    }
}
