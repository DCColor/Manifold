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
        guard contentSeconds > 0, contentSeconds <= LiveAudioResampleStage.maximumSpliceSeconds
        else { return nil }
        let frames = Int64((contentSeconds * 48000).rounded())
        pendingDrop += Double(frames) / 48000
        dropsGranted += 1
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
        var errs: [(t: Double, e: Double)] = []     // content heard − the picture's target
        var totals = S.Totals()
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
    func run(_ sender: Sender, seconds: Double, mode: S.Mode = .loop,
             writeLatency: Double = 0.010) -> Run {
        let p = QueuePlant()
        p.writeLatency = writeLatency
        final class Box: @unchecked Sendable { var at = Double.infinity }
        let deadline = Box()
        let s = make(p, deadline: { deadline.at = $0 }, mode: mode)
        let target: (Double) -> Double = { 100 + $0 }
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
            if t >= nextRef { s.setReference(media: target(t), host: t, rate: 1); nextRef += 0.1 }
            // The sender: in-stall → nothing; otherwise send towards target + lead, capped by the
            // catch-up rate after a stall.
            let stall = sender.stalls.first { t >= $0.at && t < $0.at + $0.stall }
            if stall == nil, t - lastSend >= sender.packet {
                let recent = sender.stalls.last { t >= $0.at + $0.stall }
                let rate = recent?.catchUp ?? 1
                let want = target(t) + sender.lead
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
                out.errs.append((t, p.inputTime(atOutputTime: tb) - target(t)))
            }
        }
        s.finish()
        out.totals = s.totals
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

    /// The sender catches up at once (SRT redelivering its buffer): resume ON the target, D = 0,
    /// two writes, the renderer never dry.
    func testBurstRedeliveryResumesOnTheTarget() {
        for stall in [0.4, 1.0, 2.0] {
            var sender = Sender()
            sender.stalls = [(60, stall, 1000)]
            let r = run(sender, seconds: 120)
            XCTAssertEqual(r.totals.holds, 1, "stall \(stall)")
            XCTAssertEqual(r.totals.resumes, 1, "stall \(stall)")
            XCTAssertEqual(r.totals.writes, 3, "stall \(stall)")
            XCTAssertEqual(r.totals.recoveryDrops, 0, "stall \(stall)")
            XCTAssertEqual(r.maxDry, 0, "stall \(stall)")
            XCTAssertEqual(r.totals.heldSeconds, stall - (0.340 - S.starvationMarginSeconds), accuracy: 0.03)
            // On the target within a millisecond once the resume has settled.
            XCTAssertLessThan(worst(r, from: 60 + stall + 0.5, to: 120), 0.002, "stall \(stall)")
        }
    }

    /// The sender catches up at 1.05× (ffmpeg -readrate): resume late by what the queue cannot
    /// reach, then forward splices as it grows, back on the target by ≈ 20 × D.
    func testSlowCatchUpRecoversBySplices() {
        for stall in [0.4, 1.0, 2.0] {
            var sender = Sender()
            sender.stalls = [(60, stall, 1.05)]
            let r = run(sender, seconds: 60 + stall + 80)
            let excess = stall - (0.340 - S.starvationMarginSeconds)
            XCTAssertEqual(r.totals.holds, 1, "stall \(stall)")
            XCTAssertEqual(r.totals.writes, 3, "stall \(stall)")
            XCTAssertEqual(r.maxDry, 0, "stall \(stall)")
            XCTAssertEqual(r.totals.recoveryOffset, 0, "stall \(stall): D not recovered")
            // Late by at most the hold plus the resume fill, never early.
            let late = r.errs.filter { $0.t > 60 }.map { -$0.e }.max() ?? 0
            XCTAssertLessThanOrEqual(late, excess + 0.070, "stall \(stall)")
            XCTAssertGreaterThan(r.errs.filter { $0.t > 60 }.map { $0.e }.max() ?? 0, -0.001)
            // Recovered: back within 2 ms of the target by 25 × D after the stall.
            let back = 60 + stall + 25 * excess + 2
            XCTAssertLessThan(worst(r, from: back, to: 60 + stall + 80), 0.002, "stall \(stall)")
            XCTAssertLessThanOrEqual(r.totals.recoveryDrops, Int(excess / 0.1) + 2, "stall \(stall)")
        }
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
        XCTAssertLessThan(worst(r, from: 150, to: 200), 0.002)
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
