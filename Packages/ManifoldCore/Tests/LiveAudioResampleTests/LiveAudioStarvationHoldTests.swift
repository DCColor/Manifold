//
//  LiveAudioStarvationHoldTests.swift
//  LiveAudioResampleTests
//
//  The starvation hold of docs/AUDIO_RESAMPLER_DESIGN.md §18.16 (option A of §18.14): the timebase
//  is held when the renderer is about to run dry, restarted when the refill lands, and whatever the
//  restart could not reach is taken back by forward splices as the queue allows.
//
//  THE PLANT MODELS THE RENDERER QUEUE, WHICH `SimPlant` DOES NOT. Content ARRIVES (the transport)
//  and is laid on the output axis behind what is already there; the frontier is its end. A drop is
//  consumed at the stage's input from the next content to arrive, so it is heard a queue later, and
//  `spliceCorrectionAhead` reports it until then. The timebase takes a write after `writeLatency`
//  (rate synchronous, timebase asynchronous), a rate-0 hold included. "Dry" is the timebase past
//  the frontier: the renderer playing silence, and every later refill dropped.
//
//  THE PICTURE (§18.19): the video comes from the same sender as the audio, on the same axis, so
//  the newest frame that has arrived is `sent`, and the picture is behind the line by `line − sent`,
//  floored at 0 — LiveClock's `Mapping.pictureLate` (now − newest arrived). Lip-sync is judged
//  against it: content heard − (line − late).
//

import XCTest
@testable import LiveAudioResample

final class QueuePlant: LiveAudioContentClock, @unchecked Sendable {
    var host = 0.0
    // Timebase: tbMedia at tbHost, advancing at tbRate (1 or 0).
    var tbMedia = 0.0, tbHost = 0.0, tbRate = 1.0
    var pending: (media: Double, host: Double, rate: Double, applyAt: Double)?
    /// The rate write's landing. Not measured (§18.16); the app logs it. 10 ms here, and one test
    /// runs 30 ms (SimPlant's figure) to show what a landing slower than the margin costs.
    var writeLatency = 0.010
    var writes: [LiveAudioResampleSteering.WriteOrigin] = []
    var holds = 0

    // The output axis: pieces of content laid end to end.
    struct Piece { var outStart: Double; var outEnd: Double; var content: Double; var rho: Double }
    var pieces: [Piece] = []
    var arrived = 0.0                 // content end delivered so far
    var pendingDrop = 0.0             // requested, not yet consumed at the input
    var consumedDrops: [(out: Double, seconds: Double)] = []
    var rhoValue = 1.0
    var dropsGranted = 0
    var granted: [Double] = []

    var timebase: Double {
        if let p = pending, host >= p.applyAt {
            tbMedia = p.media; tbHost = p.host; tbRate = p.rate; pending = nil
        }
        return tbMedia + (host - tbHost) * tbRate
    }
    var frontier: Double { pieces.last?.outEnd ?? 0 }

    /// Lay content up to `contentEnd` on the output axis, a drop first taking what it needs.
    func deliver(upTo contentEnd: Double) {
        guard contentEnd > arrived else { return }
        var from = arrived
        arrived = contentEnd
        if pendingDrop < 0 {              // an insert: replay from `|pendingDrop|` back, at once
            consumedDrops.append((frontier, pendingDrop))
            from += pendingDrop; pendingDrop = 0
        }
        if pendingDrop > 0 {
            let take = min(pendingDrop, contentEnd - from)
            pendingDrop -= take; from += take
            if take > 0 { consumedDrops.append((frontier, take)) }
            if from >= contentEnd { return }
        }
        let start = frontier
        let length = (contentEnd - from) / rhoValue
        if var last = pieces.last, abs(last.content + (last.outEnd - last.outStart) * last.rho - from) < 1e-9,
           last.rho == rhoValue {
            last.outEnd += length; pieces[pieces.count - 1] = last
        } else {
            pieces.append(Piece(outStart: start, outEnd: start + length, content: from, rho: rhoValue))
        }
    }

    func inputTime(atOutputTime o: Double) -> Double {
        guard let p = pieces.last(where: { $0.outStart <= o }) ?? pieces.first else { return o }
        return p.content + (o - p.outStart) * p.rho
    }
    func outputTime(atInputTime c: Double) -> Double {
        for p in pieces.reversed() where p.content <= c {
            return p.outStart + (c - p.content) / p.rho
        }
        guard let p = pieces.first else { return c }
        return p.outStart + (c - p.content) / p.rho
    }
    var rho: Double {
        get { rhoValue }
        set { rhoValue = newValue }
    }
    func requestSplice(contentSeconds: Double) -> LiveAudioResampleStage.SpliceGrant? {
        guard contentSeconds <= LiveAudioResampleStage.maximumDropSeconds,
              -contentSeconds <= LiveAudioResampleStage.maximumSpliceSeconds, contentSeconds != 0
        else { return nil }
        let frames = Int64((contentSeconds * 48000).rounded())
        pendingDrop += Double(frames) / 48000
        dropsGranted += 1
        granted.append(Double(frames) / 48000)
        return .init(id: dropsGranted, frames: frames, sampleRate: 48000, crossfadeFrames: 480)
    }
    func spliceCorrectionAhead(ofOutputTime o: Double) -> Double {
        pendingDrop + consumedDrops.filter { $0.out > o }.reduce(0) { $0 + $1.seconds }
    }
    func write(_ media: Double, _ at: Double, _ origin: LiveAudioResampleSteering.WriteOrigin) {
        writes.append(origin)
        pending = (media, at, 1.0, host + writeLatency)
    }
    func hold(_ media: Double, _ at: Double) {
        holds += 1
        pending = (media, at, 0.0, host + writeLatency)
    }
}

final class LiveAudioStarvationHoldTests: XCTestCase {

    typealias S = LiveAudioResampleSteering

    /// Arrival of the transport. `lead` is the audio's arrival lead over the target (§18.14's
    /// ~340 ms local, ~205 ms Cloudflare). A stall stops arrival for `stall` from `at`; afterwards
    /// the sender catches up at `catchUp`× (ffmpeg's -readrate catch-up is 1.05; a burst is huge).
    struct Sender {
        var lead = 0.340
        var packet = 0.0213              // one AAC frame
        var stalls: [(at: Double, stall: Double, catchUp: Double)] = []
    }

    struct Run {
        var maxDry = 0.0                 // longest the timebase sat past the frontier
        var errs: [(t: Double, e: Double)] = []     // content heard − the line (the loop's target)
        var lipSync: [(t: Double, e: Double)] = []  // content heard − the picture on the glass
        var totals = S.Totals()
        var cuts: [Double] = []          // recovery + residual splices granted, seconds, in order
    }

    func make(_ p: QueuePlant, deadline: @escaping @Sendable (Double) -> Void,
              mode: S.Mode = .loop) -> S {
        S(tag: "[TEST-STARVE]", mode: mode, clock: p, gains: .adopted, thresholds: .adopted,
          reportsWindows: false,
          readTimebase: { p.timebase }, hostNow: { p.host },
          write: { o, h, why in p.write(o, h, why) },
          hold: { o, h in p.hold(o, h) }, armDeadline: deadline, log: nil)
    }

    /// 1 ms steps. The target is content `100 + t`; content is delivered in `packet`s up to
    /// target + lead, except through a stall, after which delivery catches up at `catchUp`×.
    /// `lineShift(t)`: how far LiveClock has moved the line from the sender's real time (− = back),
    /// e.g. slewing towards a late picture. 0 by default.
    func run(_ sender: Sender, seconds: Double, mode: S.Mode = .loop,
             writeLatency: Double = 0.010, lineShift: @escaping (Double) -> Double = { _ in 0 }) -> Run {
        let p = QueuePlant()
        p.writeLatency = writeLatency
        final class Box: @unchecked Sendable { var at = Double.infinity }
        let deadline = Box()
        let s = make(p, deadline: { deadline.at = $0 }, mode: mode)
        let base: (Double) -> Double = { 100 + $0 }             // the sender's real time
        let target: (Double) -> Double = { base($0) + lineShift($0) }
        var out = Run()
        var sent = target(0) + sender.lead      // delivered content, the sender's axis
        p.arrived = target(0)
        p.pieces = [.init(outStart: 0, outEnd: 0, content: target(0), rho: 1)]
        p.deliver(upTo: sent)
        p.host = 0
        s.anchor(media: target(0), host: 0)
        var lastSend = 0.0, nextRef = 0.0, dryStart: Double?
        var t = 0.0
        while t < seconds {
            t += 0.001; p.host = t
            let late = max(0, target(t) - sent)
            if t >= nextRef {
                s.setReference(media: target(t), host: t, rate: 1, pictureLate: late); nextRef += 0.1
            }
            // The sender: in-stall → nothing; otherwise send towards target + lead, capped by the
            // catch-up rate after a stall.
            let stall = sender.stalls.first { t >= $0.at && t < $0.at + $0.stall }
            // A stalled sender accrues no catch-up credit: without this the first packet after the
            // stall was granted `stall × catchUp` at once, so every catch-up rate was a burst
            // (found 2026-09-30; §18.16's offline 1.05× cases were bursts).
            if stall != nil { lastSend = t }
            if stall == nil, t - lastSend >= sender.packet {
                let recent = sender.stalls.last { t >= $0.at + $0.stall }
                let rate = recent?.catchUp ?? 1
                let want = base(t) + sender.lead
                let can = sent + (t - lastSend) * rate
                let next = min(want, can)
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
                let heard = p.inputTime(atOutputTime: tb)
                out.errs.append((t, heard - target(t)))
                out.lipSync.append((t, heard - (target(t) - late)))
            }
        }
        s.finish()
        out.totals = s.totals
        out.cuts = p.granted
        return out
    }

    func worst(_ r: Run, from: Double, to: Double) -> Double {
        r.errs.filter { $0.t >= from && $0.t < to }.map { abs($0.e) }.max() ?? 0
    }

    // MARK: - Never on a healthy stream

    /// Twenty minutes at the leads measured on every transport (§18.16's table, down to the lowest
    /// healthy window), with delivery jitter up to 60 ms: no hold, one write, D never set.
    func testHealthyStreamsNeverHold() {
        for lead in [0.110, 0.205, 0.340, 0.420] {
            var sender = Sender(); sender.lead = lead
            sender.packet = 0.060     // bursty delivery: three frames at a time
            let r = run(sender, seconds: 1200)
            XCTAssertEqual(r.totals.holds, 0, "lead \(lead)")
            XCTAssertEqual(r.totals.writes, 1, "lead \(lead)")
            XCTAssertEqual(r.totals.recoveryDrops, 0, "lead \(lead)")
            XCTAssertEqual(r.maxDry, 0, "lead \(lead)")
            XCTAssertLessThan(worst(r, from: 30, to: 1200), 0.005, "lead \(lead)")
        }
    }

    /// Stalls shorter than the lead less the margin and one packet (340 − 20 − 21 ms) drain the
    /// queue but never to the margin: no hold.
    func testStallsInsideTheLeadNeverHold() {
        var sender = Sender()
        sender.stalls = [(60, 0.1, 1.05), (80, 0.2, 1.05), (100, 0.28, 1.05)]
        let r = run(sender, seconds: 200)
        XCTAssertEqual(r.totals.holds, 0)
        XCTAssertEqual(r.totals.writes, 1)
        XCTAssertEqual(r.maxDry, 0)
    }

    // MARK: - A stall past the lead

    /// The sender redelivers in a burst. All of it in one packet (1000×): the restart is on the
    /// target, D = 0, two writes. Over a few packets (30×: a 2 s backlog in ~70 ms): the restart,
    /// placed on the first 100 ms, owes most of the hold, and the burst lands within the catch-up
    /// window — ONE catch-up write puts it on the line (§18.19 option 2), no cut. Never dry; the hold
    /// is §18.16's (no wait for the burst).
    func testBurstRedeliveryIsOnTheLineAtOnce() {
        for (stall, rate) in [(0.4, 1000.0), (1.0, 1000), (2.0, 1000), (1.0, 30), (2.0, 30)] {
            var sender = Sender()
            sender.stalls = [(60, stall, rate)]
            let r = run(sender, seconds: 120)
            report(String(format: "%.0f× burst, %.0f ms stall", rate, stall * 1000), r, stallEnd: 60 + stall)
            XCTAssertEqual(r.totals.holds, 1, "stall \(stall)")
            XCTAssertEqual(r.totals.resumes, 1, "stall \(stall)")
            XCTAssertEqual(r.totals.recoveryDrops, 0, "stall \(stall): no cut")
            XCTAssertLessThanOrEqual(r.totals.catchUpWrites, 1, "stall \(stall)")
            XCTAssertEqual(r.totals.writes, 3 + r.totals.catchUpWrites, "stall \(stall)")
            XCTAssertEqual(r.maxDry, 0, "stall \(stall)")
            XCTAssertEqual(r.totals.recoveryOffset, 0, "stall \(stall)")
            let bare = stall - (0.340 - S.starvationMarginSeconds)
            XCTAssertGreaterThanOrEqual(r.totals.heldSeconds, bare - 0.03, "stall \(stall)")
            XCTAssertLessThanOrEqual(r.totals.heldSeconds, bare + 0.080 + 0.0213 + 0.005, "stall \(stall)")
            // On the line, and with the picture, within half a second of the restart's settle.
            XCTAssertLessThan(worst(r, from: 60 + stall + 0.5, to: 120), 0.002, "stall \(stall)")
            let lip = r.lipSync.filter { $0.t >= 60 + stall + 0.5 }.map { abs($0.e) }.max() ?? 0
            XCTAssertLessThan(lip, 0.020, "stall \(stall): with the picture")
        }
    }

    // MARK: - §18.19: one cut for the whole debt; small cuts only while the picture stays late

    /// Seconds from `from` until |content − line| is within `band` and stays there for 5 s.
    func timeToSync(_ r: Run, from: Double, band: Double = 0.020) -> Double? {
        let after = r.errs.filter { $0.t >= from }
        for (k, x) in after.enumerated() where abs(x.e) <= band {
            let hold = after[k...].prefix { $0.t < x.t + 5 }
            if hold.allSatisfy({ abs($0.e) <= band }) { return x.t - from }
        }
        return nil
    }

    func report(_ what: String, _ r: Run, stallEnd: Double) {
        // From the resume on: during the stall itself the picture freezes while the audio plays out
        // its queue, and neither is anything the recovery decides.
        let lip = r.lipSync.filter { $0.t >= stallEnd + 0.3 }.map { abs($0.e) }.max() ?? 0
        print(String(format: "[§18.19] %@: sync %@ after the stall · cuts %@ (largest %.0f ms, %d tracking) · "
                     + "residual %d · worst lip-sync vs picture %.0f ms · writes %d · dry %.0f ms",
                     what, timeToSync(r, from: stallEnd).map { String(format: "%.2f s", $0) } ?? "never",
                     r.cuts.map { String(format: "%.0f", $0 * 1000) }.joined(separator: "/"),
                     r.totals.recoveryLargestCut * 1000, r.totals.recoveryTrackingCuts,
                     r.totals.residualSplices, lip * 1000, r.totals.writes, r.maxDry * 1000))
    }

    /// A fast catch-up (3×, SRT flushing its send buffer at its bandwidth cap): the resume is late
    /// by what the first refill could not reach, the picture is back within a second, and the debt
    /// goes in ONE action — a cut, or the catch-up write when it is over 125 ms and all queued
    /// within 1 s of the restart — on the line within 3 s of the stall's end, never dry.
    func testFastCatchUpTakesTheWholeDebtInOneAction() {
        for stall in [0.4, 1.0, 2.0] {
            var sender = Sender()
            sender.stalls = [(60, stall, 3.0)]
            let r = run(sender, seconds: 120)
            report(String(format: "3× catch-up, %.0f ms stall", stall * 1000), r, stallEnd: 60 + stall)
            XCTAssertEqual(r.totals.holds, 1, "stall \(stall)")
            XCTAssertEqual(r.totals.writes, 3 + r.totals.catchUpWrites, "stall \(stall)")
            XCTAssertEqual(r.maxDry, 0, "stall \(stall)")
            // One action for the whole debt: a cut, or — over 125 ms, all queued within 1 s — a write.
            XCTAssertLessThanOrEqual(r.totals.recoveryDrops + r.totals.catchUpWrites, 1, "stall \(stall): one action")
            XCTAssertEqual(r.totals.recoveryTrackingCuts, 0, "stall \(stall)")
            XCTAssertEqual(r.totals.recoveryOffset, 0, "stall \(stall)")
            let sync = timeToSync(r, from: 60 + stall)
            XCTAssertNotNil(sync, "stall \(stall)")
            XCTAssertLessThanOrEqual(sync ?? .infinity, 3.0, "stall \(stall): within ±20 ms in ≤ 3 s")
        }
    }

    /// The slow catch-up (ffmpeg's 1.05×): the audio the line needs has not arrived, and the picture
    /// is as late as the audio. Cuts keep the audio with the PICTURE (never more than ~one tracking
    /// cut behind it, never ahead of it), then the debt is gone when the sender has caught up.
    func testSlowCatchUpTracksTheLatePicture() {
        for stall in [0.4, 1.0, 2.0] {
            var sender = Sender()
            sender.stalls = [(60, stall, 1.05)]
            let r = run(sender, seconds: 60 + stall + 80)
            report(String(format: "1.05× catch-up, %.0f ms stall", stall * 1000), r, stallEnd: 60 + stall)
            XCTAssertEqual(r.totals.writes, 3, "stall \(stall)")
            XCTAssertEqual(r.maxDry, 0, "stall \(stall)")
            XCTAssertEqual(r.totals.recoveryOffset, 0, "stall \(stall)")
            // Held: the stall less the lead, plus the refill of the resume fill at 1.05× (R − M),
            // rounded up to a 21 ms packet — §18.16's rule exactly: a 1.05× refill is never a burst.
            let bare = stall - (0.340 - S.starvationMarginSeconds)
            XCTAssertLessThanOrEqual(r.totals.heldSeconds, bare + 0.080 + 0.0213 + 0.005, "stall \(stall): held")
            // Back on the line once the sender has caught up: ≈ 20 × D at 1.05×, plus the loop.
            let d = stall - (0.340 - S.starvationMarginSeconds) + 0.1
            XCTAssertLessThan(timeToSync(r, from: 60 + stall) ?? .infinity, 21 * d + 5, "stall \(stall)")
            // Cuts ≥ 100 ms each (bar the last), so no more than D / 100 ms + 2.
            XCTAssertLessThanOrEqual(r.totals.recoveryDrops, Int(d / 0.1) + 2, "stall \(stall)")
            let after = r.lipSync.filter { $0.t > 60 + stall + 0.5 }
            // Behind the picture by at most the resume fill plus what accrues while the queue grows
            // to cover the first cut (cut + keep + fade + margin): R + 160 ms ≈ 0.27 s at 1.05×.
            XCTAssertLessThan(after.map { -$0.e }.max() ?? 0, 0.300, "stall \(stall): late vs picture")
            XCTAssertLessThan(after.map { $0.e }.max() ?? 0, 0.005, "stall \(stall): never ahead of it")
        }
    }

    /// LiveClock slews its line BACK 150 ms towards the late picture during a slow catch-up. The debt
    /// is re-measured against the line, so repaying it leaves the audio on the line — not 150 ms
    /// early, which is what fixed bookkeeping did (§18.17's +138 ms).
    func testALineMovedDuringRecoveryLeavesNoEarlyAudio() {
        var sender = Sender()
        sender.stalls = [(60, 2.0, 1.05)]
        let shift: (Double) -> Double = { t in -min(0.150, max(0, t - 62) * 0.005) }
        let r = run(sender, seconds: 160, lineShift: shift)
        report("1.05× catch-up, 2000 ms stall, line slewed back 150 ms", r, stallEnd: 62)
        XCTAssertEqual(r.totals.recoveryOffset, 0)
        XCTAssertLessThan(r.errs.filter { $0.t > 62 }.map { $0.e }.max() ?? 0, 0.020,
                          "audio never more than the residual band ahead of the line")
        XCTAssertLessThan(worst(r, from: 120, to: 160), 0.005)
    }

    /// After a resume on the target (a burst), the line moves 60 ms forward in one step (a LiveClock
    /// re-anchor too small for the 250 ms level trigger and inside the 50 ms step trigger's reach
    /// only as a ramp): one residual splice takes it, instead of 30 s of ratio at its rail.
    func testOneResidualSpliceAfterAHold() {
        var sender = Sender()
        sender.stalls = [(60, 1.0, 1000)]
        let shift: (Double) -> Double = { t in min(0.060, max(0, t - 63) * 0.040) }   // +60 ms over 1.5 s
        let r = run(sender, seconds: 120, lineShift: shift)
        report("burst, 1000 ms stall, line +60 ms after", r, stallEnd: 61)
        XCTAssertEqual(r.totals.residualSplices, 1)
        XCTAssertEqual(r.totals.writes, 3)
        XCTAssertLessThan(worst(r, from: 70, to: 120), 0.020)
    }

    /// After a hold, LiveClock keeps moving its line at its 0.5 % rail for 40 s (§18.19's live 2000 ms
    /// stall: ρ sat 86 s at its 0.2 % rail). Residual splices repeat, ≥ 2 s apart, so the error stays
    /// inside ~the 20 ms threshold and the ratio is not pinned at its rail for the episode.
    func testResidualSplicesRepeatWhileTheLineKeepsMoving() {
        var sender = Sender()
        sender.stalls = [(60, 1.0, 1000)]
        let shift: (Double) -> Double = { t in min(0.200, max(0, t - 63) * 0.005) }   // 5 ms/s for 40 s
        let r = run(sender, seconds: 180, lineShift: shift)
        report("burst, 1000 ms stall, line +5 ms/s for 40 s after", r, stallEnd: 61)
        XCTAssertGreaterThan(r.totals.residualSplices, 3)
        XCTAssertLessThan(worst(r, from: 64, to: 180), 0.030, "held near the 20 ms threshold throughout")
        XCTAssertLessThan(r.totals.railSeconds, 20, "not pinned at the rail for the 40 s the line moves")
        XCTAssertEqual(r.totals.writes, 3)
    }

    /// The same line move with NO hold before it: no watch is open, so no residual splice — the loop
    /// and its triggers are exactly as before.
    func testNoResidualWatchWithoutAHold() {
        let shift: (Double) -> Double = { t in min(0.060, max(0, t - 63) * 0.040) }
        let r = run(Sender(), seconds: 120, lineShift: shift)
        XCTAssertEqual(r.totals.residualSplices, 0)
        XCTAssertEqual(r.totals.holds, 0)
        XCTAssertEqual(r.totals.writes, 1)
        XCTAssertEqual(r.cuts.count, 0)
    }

    /// A write that lands SLOWER than the margin lets the renderer run dry for the difference, and
    /// no longer: once the hold lands the timebase is back behind the frontier, so the refill is
    /// not behind the playhead. Bounded, not zero — the in-app readback says which case the Mac is.
    func testSlowLandingCostsOnlyTheDifference() {
        var sender = Sender()
        sender.stalls = [(60, 1.0, 1.05)]
        let r = run(sender, seconds: 120, writeLatency: 0.030)
        XCTAssertEqual(r.totals.holds, 1)
        XCTAssertEqual(r.totals.writes, 3)
        XCTAssertLessThanOrEqual(r.maxDry, 0.030 - S.starvationMarginSeconds + 0.001)
        XCTAssertEqual(r.totals.recoveryOffset, 0)
    }

    /// Two stalls back to back: the second hold carries D and adds to it; everything recovers.
    func testSecondStallDuringRecovery() {
        var sender = Sender()
        sender.stalls = [(60, 1.0, 1.05), (65, 1.0, 1.05)]
        let r = run(sender, seconds: 200)
        XCTAssertEqual(r.totals.holds, 2)
        XCTAssertEqual(r.totals.resumes, 2)
        XCTAssertEqual(r.maxDry, 0)
        XCTAssertEqual(r.totals.recoveryOffset, 0)
        XCTAssertLessThan(worst(r, from: 150, to: 200), 0.005)
    }

    /// The deadline is only a wake-up: fired early (queue above the margin) it holds nothing.
    func testEarlyDeadlineHoldsNothing() {
        let p = QueuePlant()
        let s = make(p, deadline: { _ in })
        p.pieces = [.init(outStart: 0, outEnd: 0, content: 100, rho: 1)]
        p.arrived = 100
        p.deliver(upTo: 100.34)
        s.anchor(media: 100, host: 0)
        p.host = 0.5
        p.deliver(upTo: 100.84)
        s.sample(enqueuedFrontier: p.frontier)
        s.starvationCheck()
        XCTAssertEqual(s.totals.holds, 0)
        XCTAssertEqual(p.holds, 0)
    }

    /// Pinned (step 3, the back-out switch) never holds: it is step 3 exactly.
    func testPinnedNeverHolds() {
        var sender = Sender()
        sender.stalls = [(60, 1.0, 1.05)]
        let r = run(sender, seconds: 90, mode: .pinned)
        XCTAssertEqual(r.totals.holds, 0)
        XCTAssertEqual(r.totals.writes, 1)
    }

    /// After `retire()` (a new session owns the renderer) a deadline that still fires writes nothing.
    func testRetiredSteeringNeverWrites() {
        let p = QueuePlant()
        let s = make(p, deadline: { _ in })
        p.pieces = [.init(outStart: 0, outEnd: 0, content: 100, rho: 1)]
        p.arrived = 100
        p.deliver(upTo: 100.34)
        s.anchor(media: 100, host: 0)
        p.host = 0.4
        s.sample(enqueuedFrontier: p.frontier)
        s.retire()
        p.host = 0.31 + 0.4
        s.starvationCheck()
        XCTAssertEqual(p.holds, 0)
    }
}
