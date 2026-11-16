//
//  CardPullPhaseLog.swift
//  Manifold
//
//  MEASUREMENT ONLY, DEBUG BUILDS: THE CARD-PULL MEASUREMENT BUILD'S LOG (docs/CARD_PULL_MARGIN.md, *Measurement build*).
//
//  On only with `MANIFOLD_DECKLINK_CADENCE_LOG=2`. Unset or `=1`, nothing here is created: the renderer's hooks are each one test
//  of `enabled`, a static let read once.
//
//  THE HOT PATHS DO NO FORMATTING. The SDK's fill callback (the pull), the output pacer's tick, the convert's completion (the
//  publish) and the frame intake (the enqueue) each copy a few numbers into a fixed-size `Record` and append it to a preallocated
//  buffer under one short lock (`append`). A utility-QoS queue swaps the buffer out every 100 ms, joins the records and formats
//  every line there. A full buffer drops records and counts them (`dropped-records` in each summary); it never grows or waits.
//
//  Nothing here is read back by the app: the pull, the pacer, the card lock and the audio paths are observed, never steered.
//

#if DEBUG
import Foundation
import QuartzCore
import OutputPacing

final class CardPullPhaseLog: @unchecked Sendable {
    /// The switch. `=1` keeps today's [CADENCE] lines only; `=2` adds these.
    static let enabled = ProcessInfo.processInfo.environment["MANIFOLD_DECKLINK_CADENCE_LOG"] == "2"
    /// Created on first use, which the renderer's init makes (off the hot threads).
    static let shared = CardPullPhaseLog()

    enum Kind: UInt8 { case pull, publish, tick, enqueue }

    /// One observation, copied by value. Fields by kind:
    /// - pull: `index` slot, `host` the fill's host time; `a` clock, `b` handed pts, `c` target (NaN untimed), `d` margin,
    ///   `e` card frame, `f` source frame, `g` front (newest converted) pts, `ring`/`ringHost` the four slots' pts and publish
    ///   hosts, `flag` timed.
    /// - publish: `host` the publish host, `a` pts.
    /// - tick (a pacer tick that chose a new frame): `host` the clock read's host, `a` selectNow, `b` pts, `c` the tick before's
    ///   selectNow, `d` the tick before's host, `e` the interval before this tick, `f` the tick before's duration, `g` time since
    ///   the main heartbeat last ran.
    /// - enqueue: `host` when the frame entered the frame queue, `a` pts.
    struct Record {
        var kind: Kind
        var owner = 0
        var index: Int64 = 0
        var host = Double.nan
        var a = Double.nan, b = Double.nan, c = Double.nan, d = Double.nan, e = Double.nan, f = Double.nan, g = Double.nan
        var ring: (Double, Double, Double, Double) = (.nan, .nan, .nan, .nan)
        var ringHost: (Double, Double, Double, Double) = (.nan, .nan, .nan, .nan)
        var flag = false
        init(kind: Kind) { self.kind = kind }
    }

    private static let capacity = 16_384
    private let lock = NSLock()
    private var buffer: [Record] = []          // lock
    private var spare: [Record] = []           // drain queue
    private var droppedRecords = 0             // lock
    private var mainLastFire = Double.nan      // lock
    private let drainQueue = DispatchQueue(label: "com.graviton.manifold.pullphase", qos: .utility)
    private var drainTimer: DispatchSourceTimer?
    private var heartbeat: DispatchSourceTimer?
    private var state = DrainState()           // drain queue

    private init() {
        buffer.reserveCapacity(Self.capacity)
        spare.reserveCapacity(Self.capacity)
        let drain = DispatchSource.makeTimerSource(queue: drainQueue)
        drain.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        drain.setEventHandler { [unowned self] in self.drain() }
        drain.resume()
        drainTimer = drain
        // The main-thread heartbeat: a 4 ms timer on main. A tick reads how long ago it last ran ([TICKPHASE] main-ago).
        let beat = DispatchSource.makeTimerSource(queue: .main)
        beat.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .nanoseconds(0))
        beat.setEventHandler { [unowned self] in
            let now = CACurrentMediaTime()
            self.lock.lock(); self.mainLastFire = now; self.lock.unlock()
        }
        beat.resume()
        heartbeat = beat
        print("[PULLPHASE] measurement on (MANIFOLD_DECKLINK_CADENCE_LOG=2): pull, tick, publish and enqueue records, formatted off "
            + "the hot threads every 100 ms; main heartbeat every 4 ms")
    }

    /// Any thread. A copy into the preallocated buffer under one short lock; no allocation while there is room.
    func append(_ r: Record) {
        lock.lock()
        if buffer.count < Self.capacity { buffer.append(r) } else { droppedRecords += 1 }
        lock.unlock()
    }

    /// Any thread: seconds since the main heartbeat last ran (NaN before its first run).
    func mainAgo(at host: Double) -> Double {
        lock.lock(); let m = mainLastFire; lock.unlock()
        return host - m
    }

    private func drain() {
        lock.lock()
        swap(&buffer, &spare)
        let dropped = droppedRecords
        droppedRecords = 0
        lock.unlock()
        state.droppedRecords += dropped
        var out = ""
        for r in spare { state.process(r, into: &out) }
        spare.removeAll(keepingCapacity: true)
        state.flushStaleTicks(now: CACurrentMediaTime(), into: &out)
        if !out.isEmpty { print(out, terminator: "") }
    }
}

// MARK: - Joining and formatting (drain queue only)

private func ms(_ s: Double, _ digits: Int = 3) -> String {
    s.isFinite ? String(format: "%.\(digits)f", s * 1000) : "nan"
}
private func signedMs(_ s: Double, _ digits: Int = 3) -> String {
    s.isFinite ? String(format: "%+.\(digits)f", s * 1000) : "nan"
}
private func key(_ pts: Double) -> Int64 { Int64((pts * 1e6).rounded()) }

private struct TickInfo {
    var host: Double, selectNow: Double, pts: Double, prevNow: Double, prevHost: Double
    var interval: Double, prevDuration: Double, mainAgo: Double
}

/// One Play: from the first timed pull after an untimed one to the next untimed pull (a Pause, seek, step, wrap or shuttle).
private struct PlayAcc {
    var startHost = Double.nan
    var lastHost = Double.nan
    var pulls = 0, timedPulls = 0, holds = 0, exposed = 0
    var x0: [Double] = []
    var xFit = SlopeFit()
    var xLast = Double.nan, xUnwrap = 0.0
    var clockFit = SlopeFit()
    var late: [LateSwapClass: Int] = [:]
    var lateTotal = 0
    var crossings = 0
    var lastWasCrossing = false
    var establish: (branch: PullBranch, u: Double, lead: Double, behind: Int)?
    var playLinePrinted = false
}

private struct DrainState {
    var droppedRecords = 0
    var owner = 0
    var enqueue: [(pts: Double, host: Double)] = []
    var ticks: [Int64: TickInfo] = [:]
    var tickOrder: [Int64] = []
    var lastPull: (clock: Double, handed: Double, host: Double)?
    var repeatHosts: [Double] = []
    var inPlay = false
    var play = PlayAcc()
    var baseline = LateSwapBaseline()
    var period = Double.nan, ticksPerFrame = 0, cardFrame = Double.nan, sourceFrame = Double.nan
    var matched = false, margin = Double.nan
    var previousRatePpm = Double.nan

    mutating func process(_ r: CardPullPhaseLog.Record, into out: inout String) {
        switch r.kind {
        case .pull: pull(r, &out)
        case .tick: tick(r, &out)
        case .publish: publish(r, &out)
        case .enqueue:
            if owner != 0, r.owner != owner { return }
            enqueue.append((r.a, r.host))
            if enqueue.count > 512 { enqueue.removeFirst(enqueue.count - 512) }
        }
    }

    func enqueueHost(near pts: Double) -> Double {
        guard pts.isFinite else { return .nan }
        for e in enqueue.reversed() where abs(e.pts - pts) < 0.0005 { return e.host }
        return .nan
    }

    func tickInfo(near pts: Double) -> TickInfo? {
        guard pts.isFinite else { return nil }
        if let t = ticks[key(pts)] { return t }
        for k in tickOrder.reversed() { if let t = ticks[k], abs(t.pts - pts) < 0.0005 { return t } }
        return nil
    }

    // MARK: pull

    private mutating func pull(_ r: CardPullPhaseLog.Record, _ out: inout String) {
        owner = r.owner
        let timed = r.flag, clock = r.a, handed = r.b, target = r.c, front = r.g
        margin = r.d; cardFrame = r.e; sourceFrame = r.f
        matched = sourceFrame > 0 && cardFrame > 0 && abs(sourceFrame - cardFrame) < cardFrame * 1e-4
        if let t = OutputPacerTiming.period(cardFrame: cardFrame, sourceFrame: sourceFrame) { period = t.period; ticksPerFrame = t.ticksPerFrame }
        let band = matched ? cardFrame / 2 : 0.002
        let ring = [r.ring.0, r.ring.1, r.ring.2, r.ring.3]
        let ringHost = [r.ringHost.0, r.ringHost.1, r.ringHost.2, r.ringHost.3]
        let previous = lastPull?.handed ?? .nan
        let clockMoved = lastPull.map { abs(clock - $0.clock) >= 1e-4 } ?? true
        let branch = PullOutcome.branch(timed: timed, clockMoved: clockMoved, handed: handed, previous: previous,
                                        target: target, ring: ring)

        if timed && !inPlay { startPlay(r.host) }
        if !timed && inPlay { endPlay(&out) }

        var handedPub = Double.nan
        for i in 0..<4 where ring[i] == handed { handedPub = ringHost[i] }
        let lead = r.host - handedPub

        // The frame after the one handed last: in the ring (converted), else its nominal time.
        var next = Double.nan, nextPub = Double.nan
        if previous.isFinite {
            for i in 0..<4 where ring[i].isFinite && ring[i] > previous && (next.isNaN || ring[i] < next) { next = ring[i]; nextPub = ringHost[i] }
        }
        let nextInRing = next.isFinite
        if !nextInRing, previous.isFinite, sourceFrame > 0 { next = previous + sourceFrame }
        let queued = enqueueHost(near: next)
        let nextTick = tickInfo(near: next)
        let nextX = nextTick.map { $0.selectNow - next } ?? .nan
        let behind = sourceFrame > 0 && front.isFinite && handed.isFinite ? Int(((front - handed) / sourceFrame).rounded()) : 0
        let isRepeat = timed && previous.isFinite && handed == previous

        if inPlay {
            play.pulls += 1
            play.lastHost = r.host
            if timed {
                play.timedPulls += 1
                play.clockFit.add(x: r.host, y: clock)
                if isRepeat { play.holds += 1 }
                if behind == 0, lead.isFinite, period.isFinite, lead < period { play.exposed += 1 }
                if play.establish == nil, previous.isFinite, handed > previous {
                    play.establish = (branch, handed - target, lead, behind)
                }
            }
        }
        if isRepeat { repeatHosts.append(r.host); if repeatHosts.count > 64 { repeatHosts.removeFirst() } }

        out += String(format: "[PULLPHASE] pull #%lld host %.6f clock %.6f %@ target %@ band %@ ms margin %@ ms handed %.6f branch %@",
                      r.index, r.host, clock, timed ? "timed" : "untimed", target.isFinite ? String(format: "%.6f", target) : "nan",
                      ms(band, 2), ms(margin, 2), handed, branch.rawValue)
        out += " next " + (next.isFinite ? String(format: "%.6f", next) : "nan") + (nextInRing ? " (ring)" : " (nominal)")
        out += " queued " + (queued.isFinite ? signedMs(queued - r.host, 2) + " ms" : "no")
        out += " converted " + (nextPub.isFinite ? signedMs(nextPub - r.host, 2) + " ms" : "no")
        out += " tick-x " + (nextX.isFinite ? ms(nextX) + " ms" : "none")
        out += " lead " + (lead.isFinite ? ms(lead) + " ms" : "nan")
        out += behind == 0 ? " newest\n" : " behind \(behind)\n"

        lastPull = (clock, handed, r.host)
        if inPlay { maybePlayLine(&out, force: false) }
    }

    private mutating func startPlay(_ host: Double) {
        inPlay = true
        play = PlayAcc()
        play.startHost = host
        baseline.reset()
    }

    private mutating func maybePlayLine(_ out: inout String, force: Bool) {
        guard !play.playLinePrinted, force || (play.x0.count >= 8 && play.establish != nil) else { return }
        play.playLinePrinted = true
        let x0 = play.x0.isEmpty ? Double.nan : play.x0.sorted()[play.x0.count / 2]
        let e = play.establish
        out += String(format: "[PULLPHASE] play host %.6f P %@ ms k %d F %@ ms matched %@ margin %@ ms band %@ ms x0 %@ ms establish %@ u %@ ms lead0 %@ ms behind %d previous-play content-clock-vs-host %@ ppm\n",
                      play.startHost, ms(period), ticksPerFrame, ms(sourceFrame), matched ? "yes" : "no", ms(margin, 2),
                      ms(matched ? cardFrame / 2 : 0.002, 2), ms(x0), e?.branch.rawValue ?? "none", signedMs(e?.u ?? .nan, 2),
                      ms(e?.lead ?? .nan), e?.behind ?? 0,
                      previousRatePpm.isFinite ? String(format: "%+.2f", previousRatePpm) : "nan")
    }

    private mutating func endPlay(_ out: inout String) {
        maybePlayLine(&out, force: true)
        let slope = play.xFit.slope            // seconds per second
        let rate = play.clockFit.slope
        let ppm = rate.isFinite ? (rate - 1) * 1e6 : Double.nan
        if play.clockFit.count >= 200 { previousRatePpm = ppm }
        func n(_ c: LateSwapClass) -> Int { play.late[c] ?? 0 }
        let pct = play.timedPulls > 0 ? 100 * Double(play.exposed) / Double(play.timedPulls) : 0
        out += String(format: "[PULLPHASE] summary host %.6f duration %.1f s pulls %d timed %d holds %d exposed %d (%.1f %%) x-slope %@ us/s late-swaps %d (crossing %d, decode %d, render %d, pacer %d, main %d, other %d) crossings %d content-clock-vs-host %@ ppm dropped-records %d\n",
                      play.lastHost, play.lastHost - play.startHost, play.pulls, play.timedPulls, play.holds, play.exposed, pct,
                      slope.isFinite ? String(format: "%+.2f", slope * 1e6) : "nan", play.lateTotal,
                      n(.crossing), n(.decode), n(.render), n(.pacer), n(.main), n(.other), play.crossings,
                      ppm.isFinite ? String(format: "%+.2f", ppm) : "nan", droppedRecords)
        droppedRecords = 0
        inPlay = false
    }

    // MARK: tick

    private mutating func tick(_ r: CardPullPhaseLog.Record, _ out: inout String) {
        if owner != 0, r.owner != owner { return }
        let t = TickInfo(host: r.host, selectNow: r.a, pts: r.b, prevNow: r.c, prevHost: r.d, interval: r.e,
                         prevDuration: r.f, mainAgo: r.g)
        let k = key(t.pts)
        ticks[k] = t
        tickOrder.append(k)
        if inPlay, period.isFinite {
            var x = t.selectNow - t.pts
            // Unwrap: across a crossing x jumps by about one tick; the fit wants the continuous phase.
            if play.xLast.isFinite {
                let jump = (x + play.xUnwrap) - play.xLast
                if jump > period / 2 { play.xUnwrap -= period } else if jump < -period / 2 { play.xUnwrap += period }
            }
            x += play.xUnwrap
            play.xLast = x
            if play.x0.count < 8 { play.x0.append(t.selectNow - t.pts) }
            play.xFit.add(x: t.host, y: x)
        }
    }

    // MARK: publish

    private mutating func publish(_ r: CardPullPhaseLog.Record, _ out: inout String) {
        if owner != 0, r.owner != owner { return }
        let pts = r.a, k = key(pts)
        guard let t = ticks.removeValue(forKey: k) else { return }
        if let i = tickOrder.firstIndex(of: k) { tickOrder.remove(at: i) }
        let x = t.selectNow - t.pts
        let ring = r.host - t.host
        let queued = enqueueHost(near: pts)
        out += tickLine(t, ring: ring, queued: queued)
        guard inPlay, period.isFinite else { return }
        let s = x + ring
        let judged = baseline.observe(s, period: period)
        guard judged.late else { play.lastWasCrossing = false; return }
        let evidence = LateSwapEvidence(pts: pts, period: period, tickClock: t.selectNow, previousTickClock: t.prevNow,
                                        previousTickHost: t.prevHost, enqueueHost: queued, tickToRing: ring,
                                        intervalBefore: t.interval, mainLag: t.mainAgo)
        let cls = LateSwapClassifier.classify(evidence)
        play.late[cls, default: 0] += 1
        play.lateTotal += 1
        if cls == .crossing, !play.lastWasCrossing { play.crossings += 1 }
        play.lastWasCrossing = cls == .crossing
        let held = repeatHosts.contains { t.prevHost.isFinite && $0 >= t.prevHost && $0 <= r.host }
        out += String(format: "[LATE-SWAP] pts %.6f class %@ s %@ ms baseline %@ ms x %@ ms prev-to-due %@ ms queued-before-prev-tick %@ ring %@ ms interval %@ ms main-ago %@ ms held %@\n",
                      pts, cls.rawValue, ms(s), ms(judged.baseline), ms(x), signedMs(t.prevNow - pts),
                      queued.isFinite && t.prevHost.isFinite ? (queued <= t.prevHost ? "yes" : "no") : "unknown",
                      ms(ring), ms(t.interval), ms(t.mainAgo, 1), held ? "yes" : "no")
    }

    private func tickLine(_ t: TickInfo, ring: Double, queued: Double) -> String {
        String(format: "[TICKPHASE] pts %.6f host %.6f x %@ ms prev-to-due %@ ms interval %@ ms prev-tick %@ ms ring %@ queued %@ main-ago %@ ms\n",
               t.pts, t.host, ms(t.selectNow - t.pts), signedMs(t.prevNow - t.pts), ms(t.interval), ms(t.prevDuration),
               ring.isFinite ? ms(ring) + " ms" : "none", queued.isFinite ? signedMs(queued - t.host, 2) + " ms" : "no",
               ms(t.mainAgo, 1))
    }

    /// A tick whose frame never reached the ring within 0.5 s (a convert skipped by the one-in-flight gate, output stopped):
    /// its line is written without a ring time.
    mutating func flushStaleTicks(now: Double, into out: inout String) {
        while let k = tickOrder.first, let t = ticks[k], now - t.host > 0.5 {
            tickOrder.removeFirst()
            ticks.removeValue(forKey: k)
            out += tickLine(t, ring: .nan, queued: enqueueHost(near: t.pts))
        }
        while let k = tickOrder.first, ticks[k] == nil { tickOrder.removeFirst() }
        if tickOrder.count > 1024 { tickOrder.removeFirst(tickOrder.count - 1024) }
    }
}
#endif
