//
//  LiveAudioResampleSteeringTests.swift
//  LiveAudioResampleTests
//
//  Build step 4d of docs/AUDIO_RESAMPLER_DESIGN.md §7: the controller wired to a content clock.
//  The coarse branch's two triggers (§2.4), and the write count: the timebase is written at the
//  first anchor and at coarse events, and at nothing else.
//
//  ⚠️ THE PLANT IS loop_sim.py's, WITH TWO THINGS THE SCRIPT DID NOT NEED. (1) The timebase and the
//  target are separate clocks, so a write is a real re-anchor of one against the other. (2) A write
//  reaches the timebase only after `writeLatency`, as `setRate` does in the app (rate synchronous,
//  timebase asynchronous). Without (2) the settle window would be untested, and it is the thing that
//  stops a coarse write from firing a second, reverse coarse event on itself.
//
//  STEP 5 ADDS (3): a splice is HEARD `queueDepth` of output time after it is requested, as the
//  stage's is — it acts on the input, behind whatever the renderer already holds. The loop reads
//  `content + ahead` across that interval, and these tests are where that is shown continuous.
//

import XCTest
import CoreMedia
@testable import LiveAudioResample

/// Output timebase on a device clock, content through a ratio, target on a separate line.
final class SimPlant: LiveAudioContentClock, @unchecked Sendable {
    var host = 0.0
    /// Device clock against host, as a fraction (+7e-6 is NDI's +7 ppm).
    var device = 0.0
    // Timebase: tbMedia at tbHost, advancing at 1 + device.
    var tbMedia = 0.0, tbHost = 0.0
    var pending: (media: Double, host: Double, applyAt: Double)?
    var writeLatency = 0.030
    // Content map: content c0 at output o0, then ρ per output second.
    var o0 = 0.0, c0 = 0.0
    var rhoValue = 1.0
    var rhoWrites = 0
    var writes: [LiveAudioResampleSteering.WriteOrigin] = []

    // Splices (step 5): content moves by `seconds` from output time `heardAt` on.
    var queueDepth = 0.300
    var splices: [(heardAt: Double, seconds: Double, requestedAtHost: Double)] = []
    var refusesSplices = false

    var timebase: Double {
        if let p = pending, host >= p.applyAt { tbMedia = p.media; tbHost = p.host; pending = nil }
        return tbMedia + (host - tbHost) * (1 + device)
    }
    func spliced(atOutputTime o: Double) -> Double {
        splices.filter { $0.heardAt <= o }.reduce(0) { $0 + $1.seconds }
    }
    func inputTime(atOutputTime o: Double) -> Double {
        c0 + rhoValue * (o - o0) + spliced(atOutputTime: o)
    }
    func outputTime(atInputTime c: Double) -> Double {
        o0 + (c - c0 - spliced(atOutputTime: timebase)) / rhoValue
    }
    var rho: Double {
        get { rhoValue }
        set {
            // The new ratio applies from the content being heard now.
            let o = timebase
            c0 = c0 + rhoValue * (o - o0); o0 = o
            rhoValue = newValue; rhoWrites += 1
        }
    }
    func requestSplice(contentSeconds: Double) -> LiveAudioResampleStage.SpliceGrant? {
        guard !refusesSplices, abs(contentSeconds) <= LiveAudioResampleStage.maximumSpliceSeconds
        else { return nil }
        let frames = Int64((contentSeconds * 48000).rounded())
        splices.append((timebase + queueDepth, Double(frames) / 48000, host))
        return .init(id: splices.count, frames: frames, sampleRate: 48000, crossfadeFrames: 480)
    }
    func spliceCorrectionAhead(ofOutputTime o: Double) -> Double {
        splices.filter { $0.heardAt > o }.reduce(0) { $0 + $1.seconds }
    }
    func write(_ media: Double, _ at: Double, _ origin: LiveAudioResampleSteering.WriteOrigin) {
        writes.append(origin)
        pending = (media, at, host + writeLatency)
    }
}

final class LiveAudioResampleSteeringTests: XCTestCase {

    typealias S = LiveAudioResampleSteering

    static let dt = 0.020
    static let saw = 0.0015

    func make(_ p: SimPlant, mode: S.Mode = .loop) -> S {
        S(tag: "[TEST-STEER]", mode: mode, clock: p, gains: .adopted, thresholds: .adopted,
          reportsWindows: false,
          readTimebase: { p.timebase }, hostNow: { p.host },
          write: { o, h, why in p.write(o, h, why) }, log: nil)
    }

    /// Run the session: `targetAt(host)` is the true target line; the reference handed to the
    /// steering carries the measured sawtooth, as the mirror's 10 Hz line does against per-buffer
    /// reads. Returns the true error `content − target` per buffer.
    @discardableResult
    func run(_ s: S, _ p: SimPlant, from t0: Double, to t1: Double,
             targetAt: (Double) -> Double) -> [(t: Double, e: Double)] {
        var out: [(Double, Double)] = []
        var t = t0
        var nextRef = t0
        while t < t1 {
            p.host = t
            if t >= nextRef {
                let noisy = targetAt(t) - Self.saw * sin(2 * Double.pi * t)
                s.setReference(media: noisy, host: t, rate: 1.0)
                nextRef += 0.1
            }
            s.sample()
            out.append((t, p.inputTime(atOutputTime: p.timebase) - targetAt(t)))
            t += Self.dt
        }
        return out
    }

    func anchor(_ s: S, _ p: SimPlant, target: Double, at t: Double) {
        p.host = t
        s.anchor(media: target, host: t)
    }

    // MARK: - 1. No rate write except the first anchor

    /// Ten minutes against the four transports' measured drifts, each with the sawtooth: exactly
    /// one write per session, and the integrator settles on the drift with §2.2's sign.
    func testNoWriteButTheFirstAnchorAcrossTheMeasuredDrifts() {
        // (name, target slope against host, device) — realised err slopes of 11.2: SRT +5, MediaMTX
        // −60, Cloudflare +14, NDI +7 ppm. At ratio 1.0 the err slope is (1+device) − targetRate.
        let cases: [(String, Double, Double)] = [
            ("SRT", 2e-6, 7e-6), ("MediaMTX", 67e-6, 7e-6),
            ("Cloudflare", -7e-6, 7e-6), ("NDI", 0, 7e-6)]
        for (name, targetSlope, device) in cases {
            let p = SimPlant(); p.device = device
            let s = make(p)
            let target: (Double) -> Double = { h in 100 + h * (1 + targetSlope) }
            anchor(s, p, target: target(1), at: 1)
            let rows = run(s, p, from: 1, to: 601, targetAt: target)
            let t = s.totals
            XCTAssertEqual(p.writes, [.firstAnchor], "\(name): the only write is the first anchor")
            XCTAssertEqual(t.writes, 1, name)
            XCTAssertEqual(t.coarseLevel + t.coarseStep, 0, name)
            XCTAssertGreaterThan(p.rhoWrites, 100, "\(name): the ratio, not the timebase, carries it")
            let realised = ((1 + device) - (1 + targetSlope)) * 1e6
            XCTAssertEqual(t.integral * 1e6, realised, accuracy: 0.5,
                           "\(name): i settles on the realised drift, §2.2's sign")
            let tail = rows.filter { $0.t > 300 }.map { abs($0.e) }.max()!
            XCTAssertLessThan(tail, 0.0005, "\(name): steady |e| under 0.5 ms after 5 min")
            print(String(format: "[4d] %@: 1 write, %d ratio updates, i %+.2f ppm (drift %+.1f), "
                         + "max |ρ−1| %.1f ppm, steady |e| ≤ %.3f ms",
                         name, p.rhoWrites, t.integral * 1e6, realised, t.maxAbsRhoMinusOne * 1e6,
                         tail * 1e3))
        }
    }

    /// A 200 ms snap mid-session: one coarse event, taken as ONE SPLICE (a drop) and NO WRITE (step
    /// 5). The splice is heard a queue-depth later; across that interval the loop reads
    /// content + ahead, which stays on the target, so there is no second, reverse event when it is
    /// heard. `i` held across it, and the heard error back to zero once the queue has played out.
    func testASnapIsOneSpliceAndNoWrite() {
        let p = SimPlant(); p.device = 7e-6
        let s = make(p)
        var jump = 0.0
        let target: (Double) -> Double = { h in 50 + h * (1 - 60e-6) + jump }
        anchor(s, p, target: target(0), at: 0)
        run(s, p, from: 0, to: 200, targetAt: target)
        let iBefore = s.totals.integral
        jump = 0.200
        let rows = run(s, p, from: 200, to: 320, targetAt: target)
        let t = s.totals
        XCTAssertEqual(p.writes, [.firstAnchor], "the session's only write is the first anchor")
        XCTAssertEqual(t.writes, 1)
        XCTAssertEqual(p.splices.count, 1, "exactly one splice")
        XCTAssertEqual(p.splices.first?.seconds ?? 0, 0.200, accuracy: 0.003,
                       "a 200 ms DROP: the content moves forward by the snap")
        XCTAssertEqual(t.spliceDrops, 1); XCTAssertEqual(t.spliceInserts, 0)
        XCTAssertEqual(t.coarseStep, 1, "no reverse event when the splice is heard")
        XCTAssertEqual(t.coarseLevel, 0); XCTAssertEqual(t.spliceFallbacks, 0)
        XCTAssertEqual(t.integral, iBefore, accuracy: 0.2e-6, "i held across the event")
        // Heard at 200 + the 0.3 s queue (+ one buffer).
        let during = rows.filter { $0.t > 200.05 && $0.t < 200.28 }.map { $0.e }
        XCTAssertLessThan(during.max()!, -0.19, "until it is heard the listener still has the old error")
        let after = rows.filter { $0.t > 200.35 }.map { abs($0.e) }.max()!
        XCTAssertLessThan(after, 0.002, "once heard, the content is on the target")
    }

    /// A backward jump (a target raise) is an INSERT of the same size, and also no write.
    func testABackwardJumpIsOneInsert() {
        let p = SimPlant()
        let s = make(p)
        var jump = 0.0
        let target: (Double) -> Double = { h in 50 + h + jump }
        anchor(s, p, target: target(0), at: 0)
        run(s, p, from: 0, to: 30, targetAt: target)
        jump = -0.200
        let rows = run(s, p, from: 30, to: 60, targetAt: target)
        XCTAssertEqual(p.writes, [.firstAnchor])
        XCTAssertEqual(p.splices.count, 1)
        XCTAssertEqual(p.splices.first?.seconds ?? 0, -0.200, accuracy: 0.003, "a 200 ms INSERT")
        XCTAssertEqual(s.totals.spliceInserts, 1)
        XCTAssertLessThan(rows.filter { $0.t > 30.4 }.map { abs($0.e) }.max()!, 0.002)
    }

    // MARK: - 2. The step trigger

    func testStepTriggerFiresAboveFiftyMillisecondsAndNotBelow() {
        for (size, fires) in [(0.049, false), (-0.049, false), (0.051, true), (-0.051, true)] {
            let p = SimPlant()
            let s = make(p)
            var jump = 0.0
            let target: (Double) -> Double = { h in 10 + h + jump }
            anchor(s, p, target: target(0), at: 0)
            run(s, p, from: 0, to: 30, targetAt: target)
            jump = size
            run(s, p, from: 30, to: 40, targetAt: target)
            let t = s.totals
            XCTAssertEqual(t.coarseStep, fires ? 1 : 0, "step \(size * 1000) ms")
            XCTAssertEqual(t.coarseLevel, 0, "step \(size * 1000) ms")
            XCTAssertEqual(t.splices, fires ? 1 : 0, "step \(size * 1000) ms")
            XCTAssertEqual(p.writes.count, 1, "never a write: step \(size * 1000) ms")
            if !fires {
                XCTAssertGreaterThan(t.maxAbsRhoMinusOne, 1e-3,
                                     "below the trigger the LOOP absorbs it: the ratio moves")
            }
        }
    }

    /// Past the 1 s splice bound the coarse branch still RE-ANCHORS (one write, counted as a
    /// fallback). The reads right after a write see the old axis, then the new: a step, and the
    /// settle window is what keeps it from being mistaken for one. Without it this would be two.
    func testPastTheSpliceBoundItReanchorsAndTheWritesOwnStepIsNotACoarseEvent() {
        let p = SimPlant(); p.writeLatency = 0.150
        let s = make(p)
        var jump = 0.0
        let target: (Double) -> Double = { h in 10 + h + jump }
        anchor(s, p, target: target(0), at: 0)
        run(s, p, from: 0, to: 20, targetAt: target)
        jump = 1.300
        let rows = run(s, p, from: 20, to: 40, targetAt: target)
        XCTAssertEqual(s.totals.coarseStep, 1, "one event, not one plus its own reverse")
        XCTAssertEqual(s.totals.spliceFallbacks, 1, "1.3 s is past the bound: re-anchored")
        XCTAssertEqual(s.totals.splices, 0)
        XCTAssertEqual(p.writes.count, 2)
        XCTAssertLessThan(rows.filter { $0.t > 20.5 }.map { abs($0.e) }.max()!, 0.002)

        // The control: with no settle window the same run fires on its own write.
        let q = SimPlant(); q.writeLatency = 0.150
        var unsettled = S.Thresholds.adopted; unsettled.settle = 0
        let u = S(tag: "[TEST-STEER]", mode: .loop, clock: q, gains: .adopted, thresholds: unsettled,
                  reportsWindows: false, readTimebase: { q.timebase }, hostNow: { q.host },
                  write: { o, h, why in q.write(o, h, why) }, log: nil)
        jump = 0
        anchor(u, q, target: target(0), at: 0)
        run(u, q, from: 0, to: 20, targetAt: target)
        jump = 1.300
        run(u, q, from: 20, to: 40, targetAt: target)
        // It re-fires as LEVEL: the first stale read after the write seeds e_f at −300 ms.
        XCTAssertGreaterThan(u.totals.coarseStep + u.totals.coarseLevel, 1,
                             "without the settle window the write re-fires")
    }

    // MARK: - 3. The level trigger

    /// A drift past the authority (5000 ppm against B = 2000) never steps by 50 ms between reads,
    /// so only the level trigger can catch it, and it must: at the rail the error still grows at
    /// 3 ms/s and reaches 250 ms in about 80 s.
    func testLevelTriggerCatchesADriftTheLoopCannotHold() {
        let p = SimPlant()
        let s = make(p)
        let target: (Double) -> Double = { h in 10 + h * (1 + 5000e-6) }
        anchor(s, p, target: target(0), at: 0)
        let rows = run(s, p, from: 0, to: 110, targetAt: target)
        let t = s.totals
        XCTAssertEqual(t.coarseLevel, 1, "exactly one level event in 110 s")
        XCTAssertEqual(t.coarseStep, 0, "never a 50 ms step between consecutive reads")
        XCTAssertEqual(p.writes.count, 1, "taken as a splice: no write")
        XCTAssertEqual(p.splices.count, 1)
        XCTAssertGreaterThan(p.splices.first?.seconds ?? 0, 0.25,
                             "fired past 250 ms, content behind the target: a drop")
        XCTAssertEqual(t.maxAbsRhoMinusOne, 0.002, accuracy: 1e-9, "at the rail, never past it")
        XCTAssertLessThan(t.integral * 1e6, 500, "anti-windup: the rail did not charge i")
        let firedAt = p.splices.first?.requestedAtHost ?? .nan
        XCTAssertLessThan(rows.filter { $0.t > firedAt + 0.4 && $0.t < firedAt + 2 }
                            .map { abs($0.e) }.max()!, 0.01, "heard, the drop lands it")
        XCTAssertEqual(firedAt, 90, accuracy: 20, "about 80 s at 3 ms/s, plus the approach")
    }

    /// A level just under the trigger must not fire. 240 ms of offset, reached by a series of 40 ms
    /// steps too close together for the loop to have absorbed them.
    func testLevelTriggerDoesNotFireBelowTwoHundredFiftyMilliseconds() {
        let p = SimPlant()
        let s = make(p)
        var jump = 0.0
        let target: (Double) -> Double = { h in 10 + h + jump }
        anchor(s, p, target: target(0), at: 0)
        run(s, p, from: 0, to: 10, targetAt: target)
        for k in 1...6 {
            jump = 0.040 * Double(k)
            run(s, p, from: 10 + 0.2 * Double(k - 1), to: 10 + 0.2 * Double(k), targetAt: target)
        }
        run(s, p, from: 11.2, to: 60, targetAt: target)
        XCTAssertEqual(s.totals.coarseLevel + s.totals.coarseStep, 0)
        XCTAssertEqual(p.writes.count, 1)
    }

    // MARK: - 3b. The queue guard and the match

    /// A drop needs the renderer queue to cover it (drop + 10 ms fade + 50 ms). A 200 ms drop
    /// against a 150 ms queue re-anchors instead, counted as a fallback.
    func testADropTheQueueCannotCoverReanchors() {
        let p = SimPlant()
        let s = make(p)
        var jump = 0.0
        let target: (Double) -> Double = { h in 10 + h + jump }
        anchor(s, p, target: target(0), at: 0)
        var t = 0.0
        func step(queue: Double) {
            p.host = t
            s.setReference(media: target(t), host: t, rate: 1.0)
            s.sample(enqueuedFrontier: p.timebase + queue)
            t += Self.dt
        }
        while t < 10 { step(queue: 0.150) }
        jump = 0.200
        while t < 12 { step(queue: 0.150) }
        XCTAssertEqual(s.totals.spliceFallbacks, 1)
        XCTAssertEqual(s.totals.splices, 0)
        XCTAssertEqual(p.writes.count, 2)

        // The same drop against a 270 ms queue — exactly drop + fade + margin + 10 ms — splices.
        let q = SimPlant()
        let u = make(q)
        jump = 0
        q.host = 0; u.anchor(media: target(0), host: 0)
        t = 0
        func stepU(queue: Double) {
            q.host = t
            u.setReference(media: target(t), host: t, rate: 1.0)
            u.sample(enqueuedFrontier: q.timebase + queue)
            t += Self.dt
        }
        while t < 10 { stepU(queue: 0.270) }
        jump = 0.200
        while t < 12 { stepU(queue: 0.270) }
        XCTAssertEqual(u.totals.splices, 1)
        XCTAssertEqual(u.totals.spliceFallbacks, 0)
        XCTAssertEqual(q.writes.count, 1)
    }

    /// Each splice takes the newest unconsumed event from the 1.5 s before it and names it; with
    /// none it logs a WARNING and counts it unmatched. An event is consumed once.
    func testEverySpliceIsMatchedToItsEventOrWarned() {
        final class Lines: @unchecked Sendable {
            let lock = NSLock(); var all: [String] = []
            func add(_ l: String) { lock.lock(); all.append(l); lock.unlock() }
            var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return all }
        }
        let lines = Lines()
        let p = SimPlant()
        let s = S(tag: "[TEST-STEER]", mode: .loop, clock: p, gains: .adopted, thresholds: .adopted,
                  reportsWindows: false, readTimebase: { p.timebase }, hostNow: { p.host },
                  write: { o, h, why in p.write(o, h, why) }, log: { lines.add($0) })
        var jump = 0.0
        let target: (Double) -> Double = { h in 10 + h + jump }
        anchor(s, p, target: target(0), at: 0)
        run(s, p, from: 0, to: 10, targetAt: target)
        // 1: matched — the event is recorded before the mapping moves, as LiveClock orders it.
        s.noteEvent("snap-to-live", host: 10, jumped: 0.2, detail: "flushed 0.200s excess")
        jump = 0.2
        run(s, p, from: 10, to: 20, targetAt: target)
        // 2: an event 3 s before its step — outside the window.
        s.noteEvent("queue-full", host: 20, jumped: 0.3, detail: "flushed 0.300s")
        run(s, p, from: 20, to: 23, targetAt: target)
        jump = 0.5
        run(s, p, from: 23, to: 30, targetAt: target)
        // 3: no event at all.
        jump = 0.3
        run(s, p, from: 30, to: 40, targetAt: target)
        XCTAssertEqual(s.totals.splices, 3)
        XCTAssertEqual(s.totals.unmatched, 2)
        s.finish()
        let deadline = Date().addingTimeInterval(2)
        while lines.snapshot.filter({ $0.contains("session END") }).isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let splices = lines.snapshot.filter { $0.contains(" SPLICE #") }
        XCTAssertEqual(splices.count, 3, "one SPLICE line per splice")
        XCTAssertEqual(splices.filter { $0.contains("matched: snap-to-live") }.count, 1)
        XCTAssertEqual(splices.filter { $0.contains("WARNING: UNMATCHED") }.count, 2)
        XCTAssertEqual(splices.filter { $0.contains("DROP") }.count, 2)
        XCTAssertEqual(splices.filter { $0.contains("INSERT") }.count, 1)
        let end = lines.snapshot.first { $0.contains("steering session END") } ?? ""
        XCTAssertTrue(end.contains("splices 3 (drop 2, insert 1)"), end)
        XCTAssertTrue(end.contains("unmatched 2"), end)
        XCTAssertTrue(end.contains("timebase writes 1"), end)
    }

    // MARK: - 4. Pinned: step 3's behaviour

    func testPinnedModeNeverMovesTheRatioAndNeverFiresCoarse() {
        let p = SimPlant(); p.device = 7e-6
        let s = make(p, mode: .pinned)
        var jump = 0.0
        let target: (Double) -> Double = { h in 10 + h * (1 - 60e-6) + jump }
        anchor(s, p, target: target(0), at: 0)
        run(s, p, from: 0, to: 60, targetAt: target)
        jump = 0.300
        run(s, p, from: 60, to: 120, targetAt: target)
        XCTAssertEqual(p.rhoWrites, 0, "the ratio is never written")
        XCTAssertEqual(p.rho, 1.0)
        XCTAssertEqual(p.writes, [.firstAnchor], "the caller's 10 ms branch owns position when pinned")
        // …and its writes go through the one writer, and are counted.
        p.host = 120
        s.anchor(media: target(120), host: 120, reason: "position branch")
        XCTAssertEqual(s.totals.reanchors, 1)
        XCTAssertEqual(s.totals.writes, 2)
    }

    // MARK: - 5. The stage's inverse map

    /// `outputTime(atInputTime:)` inverts `inputTime(atOutputTime:)` under a ramped ratio, on the
    /// real stage — the coarse branch places the timebase with it.
    func testOutputTimeInvertsInputTimeUnderARampedRatio() {
        typealias T = LiveAudioResampleStageTests
        let fmt = T.makeFormat(rate: 48000, channels: 2)
        let s = LiveAudioResampleStage(tag: "[TEST]", reportsWindows: false, log: nil)
        XCTAssertEqual(s.outputTime(atInputTime: 3.25), 3.25, "no block yet: identity")
        var tick: Int64 = 48_000
        for b in 0..<150 {
            s.rho = 1 + 0.002 * sin(Double(b) / 20)
            _ = s.process(T.makeInput(tick: tick, frames: 960, format: fmt))
            tick += 960
        }
        var worst = 0.0, moved = 0.0
        for k in stride(from: 1.05, to: 3.9, by: 0.0137) {
            let o = s.outputTime(atInputTime: k)
            worst = max(worst, abs(s.inputTime(atOutputTime: o) - k))
            moved = max(moved, abs(o - k))
        }
        XCTAssertLessThan(worst * 48000, 1e-6, "round trip within a micro-frame")
        XCTAssertGreaterThan(moved * 48000, 10, "the ramp must move content off the output axis")

        let unity = LiveAudioResampleStage(tag: "[TEST]", reportsWindows: false, log: nil)
        _ = unity.process(T.makeInput(tick: 0, frames: 960, format: fmt))
        XCTAssertEqual(unity.outputTime(atInputTime: 0.0123).bitPattern, (0.0123).bitPattern,
                       "identity at 1.0, bit for bit")
    }
}
