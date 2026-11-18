//
//  PresentTimingLog.swift
//  Manifold
//
//  MEASUREMENT ONLY, DEBUG BUILDS: THE WINDOW PRESENT PATH UNDER THE OUTPUT PACER (docs/WINDOW_PRESENT_PATH.md §4.1).
//
//  On only with `MANIFOLD_PRESENT_TIMING=1`. Unset (or any other value), nothing here is created: the renderer's hooks are each
//  one test of `enabled`, a static let read once, or of a Bool that only an enabled tick sets.
//
//  What is measured, on pacer ticks only (output on; a display-link tick is never recorded):
//  - every present attempt the gate makes (`servePacedPresent`): its outcome (held in flight, held for rate, no command buffer,
//    nil drawable, presented) and the in-flight count it saw;
//  - for a presented one, each step separately: the gate, `makeCommandBuffer`, `nextDrawable`, `encodeDisplayStage`, the
//    in-flight count and handlers, `commit`, the stamp (bookkeeping and `reportCompareStamp`), `waitUntilScheduled`, the
//    [AV-LAG] probe, `CATransaction.begin` + `drawable.present()`, `CATransaction.commit`, `closeColorStateTransaction`;
//  - the rest of the tick: `performDisplayTick` without the present inside it, the 10 s stats print, `noteIdleTick`;
//  - when the frame reached the glass: the drawable's `presentedTime` against the host time `present()` was called, and how
//    long after that the presented handler (the one the gate counts) came in. `presentedTime` 0 is a dropped present.
//
//  THE HOT PATH DOES NO FORMATTING, as `CardPullPhaseLog`: the tick copies its numbers into a fixed-size `Tick` and appends it to
//  a preallocated buffer under one short lock; the presented handler does the same with a `Glass`. A utility-QoS queue swaps the
//  buffer out every 100 ms and does every join, statistic and line there. A full buffer drops records and counts them
//  (`dropped-records`); it never grows or waits.
//
//  The lines (drain queue):
//  - `[PRESENT-TIMING] miss · …`: a tick after which the pacer's next tick came more than 1.5 P later (P: the median of the
//    recent tick intervals), with every part of that tick and the part that took longest (`overran:`).
//  - `[PRESENT-TIMING] long tick · …`: any other tick over 5 ms, the same fields.
//  - `[PRESENT-TIMING] 10 s: …`: counts, in-flight at each attempt, p50/p99/max of every step and part, present → glass.
//  - `[PRESENT-TIMING] total: …`: the same since launch (10 µs bins above 2 ms, quantiles at a bin's upper edge), every 60 s and
//    when the pacer's ticks stop for 2 s; plus the share of playing 10 s windows with in-flight holds.
//
//  Nothing here is read back by the app: the gate, the present and the pacer are observed, never steered.
//

#if DEBUG
import Foundation
import QuartzCore

final class PresentTimingLog: @unchecked Sendable {
    static let enabled = ProcessInfo.processInfo.environment["MANIFOLD_PRESENT_TIMING"] == "1"
    /// Created on first use, which the renderer's init makes (off the hot threads).
    static let shared = PresentTimingLog()

    enum Outcome: UInt8 { case none = 0, heldInFlight, heldRate, noBuffer, nilDrawable, presented }

    /// The presented attempt's steps, each a duration in seconds (NaN: not reached).
    struct Steps {
        var gate = Double.nan, makeCommandBuffer = Double.nan, nextDrawable = Double.nan, encode = Double.nan
        var handler = Double.nan, commit = Double.nan, stamp = Double.nan, waitUntilScheduled = Double.nan
        var probe = Double.nan, present = Double.nan, txCommit = Double.nan, colorTx = Double.nan
        static let names = ["gate", "makeCommandBuffer", "nextDrawable", "encode", "handler", "commit", "stamp",
                            "waitUntilScheduled", "probe", "present", "CATransaction.commit", "colorTx"]
        /// Drain queue only (allocates).
        var values: [Double] {
            [gate, makeCommandBuffer, nextDrawable, encode, handler, commit, stamp, waitUntilScheduled, probe, present, txCommit, colorTx]
        }
    }

    struct Attempt {
        var start = Double.nan, end = Double.nan
        var outcome: Outcome = .none
        var inFlight: Int16 = -1
        /// Made inside `performDisplayTick` (the new-frame tick's own attempt), not by the tick's second call.
        var inRender = false
    }

    struct Tick {
        var start = Double.nan, performEnd = Double.nan, statsStart = Double.nan, statsEnd = Double.nan, end = Double.nan
        var newFrame = false
        var attempts: UInt8 = 0
        var a1 = Attempt(), a2 = Attempt()
        var steps = Steps()
        /// The presented drawable's number (0: nothing presented this tick) and the host time just before `present()`.
        var seq: Int64 = 0
        var presentHost = Double.nan
        /// The window display's period, as the gate read it.
        var period = 0.0
    }

    struct Glass { var seq: Int64; var presentedTime: Double; var handlerHost: Double }

    enum Record { case tick(Tick), glass(Glass) }

    private static let capacity = 4096
    private let lock = NSLock()
    private var buffer: [Record] = []          // lock
    private var spare: [Record] = []           // drain queue
    private var droppedRecords = 0             // lock
    private let drainQueue = DispatchQueue(label: "com.graviton.manifold.presenttiming", qos: .utility)
    private var drainTimer: DispatchSourceTimer?
    private var state = PresentTimingDrain()   // drain queue

    private init() {
        buffer.reserveCapacity(Self.capacity)
        spare.reserveCapacity(Self.capacity)
        let drain = DispatchSource.makeTimerSource(queue: drainQueue)
        drain.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        drain.setEventHandler { [unowned self] in self.drain() }
        drain.resume()
        drainTimer = drain
        print("[PRESENT-TIMING] measurement on (MANIFOLD_PRESENT_TIMING=1): every pacer tick's present attempts and steps, and each "
            + "present's glass time, formatted off the hot threads every 100 ms")
    }

    /// The tick thread, at the end of a pacer tick.
    func tick(_ t: Tick) { append(.tick(t)) }
    /// Any thread (the presented handler).
    func glass(seq: Int64, presentedTime: Double, handlerHost: Double) {
        append(.glass(Glass(seq: seq, presentedTime: presentedTime, handlerHost: handlerHost)))
    }

    private func append(_ r: Record) {
        lock.lock()
        if buffer.count < Self.capacity { buffer.append(r) } else { droppedRecords += 1 }
        lock.unlock()
    }

    private func drain() {
        lock.lock()
        swap(&buffer, &spare)
        let dropped = droppedRecords
        droppedRecords = 0
        lock.unlock()
        state.droppedRecords += dropped
        state.windowDropped += dropped
        var out = ""
        for r in spare { state.process(r, into: &out) }
        spare.removeAll(keepingCapacity: true)
        state.flushIfStopped(now: CACurrentMediaTime(), into: &out)
        if !out.isEmpty { print(out, terminator: "") }
    }
}

// MARK: - Statistics and formatting (drain queue only)

private func ms(_ s: Double) -> String { s.isFinite ? String(format: "%.3f", s * 1000) : "nan" }

/// A 10 s window's values, exact.
private struct Series {
    var v: [Double] = []
    mutating func add(_ x: Double) { if x.isFinite { v.append(x) } }
    var summary: String {
        guard !v.isEmpty else { return "nan/nan/nan" }
        let s = v.sorted()
        let p = { (q: Double) in s[max(0, min(s.count - 1, Int((q * Double(s.count)).rounded(.up)) - 1))] }
        return "\(ms(p(0.5)))/\(ms(p(0.99)))/\(ms(s.last!))"
    }
}

/// Since launch: 1 µs bins to 2 ms, 10 µs to 20 ms, 100 µs to 200 ms, then one overflow bin. The max is exact.
private struct Hist {
    static let count = 5601
    var bins = [Int](repeating: 0, count: Hist.count)
    var n = 0
    var max = -Double.infinity
    static func index(_ s: Double) -> Int {
        let us = s * 1e6
        if us < 2000 { return Swift.max(0, Int(us)) }
        if us < 20000 { return 2000 + Int((us - 2000) / 10) }
        if us < 200000 { return 3800 + Int((us - 20000) / 100) }
        return 5600
    }
    static func upper(_ i: Int) -> Double {
        if i < 2000 { return Double(i + 1) / 1e6 }
        if i < 3800 { return (2000 + Double(i - 2000 + 1) * 10) / 1e6 }
        if i < 5600 { return (20000 + Double(i - 3800 + 1) * 100) / 1e6 }
        return .infinity
    }
    mutating func add(_ x: Double) {
        guard x.isFinite else { return }
        bins[Hist.index(x)] += 1; n += 1; max = Swift.max(max, x)
    }
    func q(_ p: Double) -> Double {
        guard n > 0 else { return .nan }
        let rank = Swift.max(1, Int((p * Double(n)).rounded(.up)))
        var c = 0
        for (i, b) in bins.enumerated() { c += b; if c >= rank { return Swift.min(Hist.upper(i), max) } }
        return max
    }
    var summary: String { n > 0 ? "\(ms(q(0.5)))/\(ms(q(0.99)))/\(ms(max))" : "nan/nan/nan" }
}

/// The series kept for every present and tick, in print order: the 12 steps, then these.
private let extraNames = ["present total", "tick", "perform", "stats", "idle", "repeat tick serving a present",
                          "present → glass", "glass → handler"]
private let seriesNames = PresentTimingLog.Steps.names + extraNames
private let sPresentTotal = 12, sTick = 13, sPerform = 14, sStats = 15, sIdle = 16, sRepeatServing = 17, sToGlass = 18, sToHandler = 19

private struct Counts {
    var ticks = 0, newFrame = 0, repeatTicks = 0
    var presents = 0, presentsNewFirst = 0, presentsNewSecond = 0, presentsRepeat = 0
    var heldInFlight = 0, heldRate = 0, nilDrawable = 0, noBuffer = 0, extraAttempts = 0
    var inFlightAt = [0, 0, 0, 0]   // 0, 1, 2, 3+ at each attempt
    var glass = 0, dropped = 0, lateTwo = 0, noHandler = 0
    var longTicks = 0, misses = 0
    var overran: [String: Int] = [:]
    mutating func add(_ t: PresentTimingLog.Tick) {
        ticks += 1
        if t.newFrame { newFrame += 1 } else { repeatTicks += 1 }
        if t.attempts > 2 { extraAttempts += Int(t.attempts) - 2 }
        for a in [t.a1, t.a2] where a.outcome != .none {
            inFlightAt[Swift.min(3, Swift.max(0, Int(a.inFlight)))] += 1
            switch a.outcome {
            case .heldInFlight: heldInFlight += 1
            case .heldRate: heldRate += 1
            case .nilDrawable: nilDrawable += 1
            case .noBuffer: noBuffer += 1
            case .presented:
                presents += 1
                if !t.newFrame { presentsRepeat += 1 } else if a.inRender { presentsNewFirst += 1 } else { presentsNewSecond += 1 }
            case .none: break
            }
        }
    }
    var overranText: String {
        overran.isEmpty ? "none" : overran.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
    func line(span: Double?) -> String {
        let per = { (n: Int) in span.map { String(format: " (%.1f/s)", Double(n) / $0) } ?? "" }
        return "ticks \(ticks) (new-frame \(newFrame), repeat \(repeatTicks)) · presents \(presents)\(per(presents)) (new-frame tick "
            + "\(presentsNewFirst), same tick 2nd \(presentsNewSecond), repeat tick \(presentsRepeat)) · held in flight \(heldInFlight), "
            + "rate \(heldRate), nil drawable \(nilDrawable), no buffer \(noBuffer), attempts beyond 2 \(extraAttempts) · in flight at "
            + "attempt 0:\(inFlightAt[0]) 1:\(inFlightAt[1]) 2:\(inFlightAt[2]) 3+:\(inFlightAt[3])"
    }
}

struct PresentTimingDrain {
    var droppedRecords = 0
    var windowDropped = 0
    private var lastTick: PresentTimingLog.Tick?
    private var lastTickSeen = Double.nan        // drain host when the last tick record arrived
    private var intervals: [Double] = []         // the recent tick intervals, for P
    private var P = Double.nan
    private var pending: [Int64: (host: Double, period: Double)] = [:]   // presented, glass not yet in
    private var early: [Int64: PresentTimingLog.Glass] = [:]           // glass in before its tick record
    private var windowStart = Double.nan
    private var w = Counts()
    private var ws = [Series](repeating: Series(), count: 20)
    private var t = Counts()
    private var th = [Hist](repeating: Hist(), count: 20)
    private var windows = 0, playingWindows = 0, holdingWindows = 0
    private var lastTotalAt = Double.nan

    mutating func process(_ r: PresentTimingLog.Record, into out: inout String) {
        switch r {
        case .tick(let k): tick(k, &out)
        case .glass(let g): glass(g)
        }
    }

    private mutating func tick(_ k: PresentTimingLog.Tick, _ out: inout String) {
        lastTickSeen = CACurrentMediaTime()
        if let prev = lastTick {
            let interval = k.start - prev.start
            intervals.append(interval)
            if intervals.count > 64 { intervals.removeFirst(intervals.count - 64) }
            if intervals.count >= 8 { let s = intervals.sorted(); P = s[s.count / 2] }
            judge(prev, next: interval, &out)
        }
        if windowStart.isNaN { windowStart = k.start }
        if k.start - windowStart >= 10 { flushWindow(span: k.start - windowStart, &out); windowStart = k.start }
        w.add(k); t.add(k)
        let tickDur = k.end - k.start
        add(sTick, tickDur)
        add(sPerform, parts(k).first { $0.name == "perform" }?.d ?? .nan)
        add(sStats, k.statsEnd - k.statsStart)
        add(sIdle, k.end - k.statsEnd)
        if k.seq != 0 {
            let vals = k.steps.values
            for (i, v) in vals.enumerated() { add(i, v) }
            let presenting = [k.a1, k.a2].first { $0.outcome == .presented }
            add(sPresentTotal, presenting.map { $0.end - $0.start } ?? .nan)
            if !k.newFrame { add(sRepeatServing, tickDur) }
            pending[k.seq] = (k.presentHost, k.period)
            if let g = early.removeValue(forKey: k.seq) { glass(g) }
        }
        lastTick = k
    }

    private mutating func add(_ i: Int, _ v: Double) { ws[i].add(v); th[i].add(v) }

    private mutating func glass(_ g: PresentTimingLog.Glass) {
        guard let p = pending.removeValue(forKey: g.seq) else {
            early[g.seq] = g
            if early.count > 256 { early.removeAll() }
            return
        }
        w.glass += 1; t.glass += 1
        guard g.presentedTime > 0 else { w.dropped += 1; t.dropped += 1; return }
        let toGlass = g.presentedTime - p.host
        add(sToGlass, toGlass)
        add(sToHandler, g.handlerHost - g.presentedTime)
        if p.period > 0, toGlass >= 2 * p.period { w.lateTwo += 1; t.lateTwo += 1 }
    }

    /// Every part of a tick, in seconds: the presented attempt's steps, the held attempts, and the tick around them.
    private func parts(_ k: PresentTimingLog.Tick) -> [(name: String, d: Double)] {
        var out: [(name: String, d: Double)] = []
        var inRenderAttempts = 0.0, held = 0.0
        for a in [k.a1, k.a2] where a.outcome != .none {
            let d = a.end - a.start
            if a.inRender, d.isFinite { inRenderAttempts += d }
            if a.outcome != .presented, d.isFinite { held += d }
        }
        if k.seq != 0 {
            for (n, v) in zip(PresentTimingLog.Steps.names, k.steps.values) where v.isFinite { out.append((n, v)) }
        }
        out.append(("perform", (k.performEnd - k.start) - inRenderAttempts))
        out.append(("attempts not presented", held))
        out.append(("stats", k.statsEnd - k.statsStart))
        out.append(("idle", k.end - k.statsEnd))
        let sum = out.reduce(0.0) { $0 + ($1.d.isFinite ? $1.d : 0) }
        out.append(("unaccounted", (k.end - k.start) - sum))
        return out
    }

    /// The tick before `next`: a miss (the next tick came over 1.5 P later) or a long tick (over 5 ms), each with its parts.
    private mutating func judge(_ k: PresentTimingLog.Tick, next: Double?, _ out: inout String) {
        let dur = k.end - k.start
        var missed = false
        if let next, P.isFinite, next > 1.5 * P {
            // A pause the pacer slept through (idle) is not a miss: a long gap after a short tick.
            missed = !(next > 50 * P && dur < P)
        }
        guard missed || dur > 0.005 else { return }
        let ps = parts(k)
        let top = ps.max { ($0.d.isFinite ? $0.d : -1) < ($1.d.isFinite ? $1.d : -1) }!
        if missed {
            w.misses += 1; t.misses += 1
            w.overran[top.name, default: 0] += 1; t.overran[top.name, default: 0] += 1
        }
        if dur > 0.005 { w.longTicks += 1; t.longTicks += 1 }
        var s = "[PRESENT-TIMING] \(missed ? "miss" : "long tick") · host \(String(format: "%.6f", k.start)) · tick \(ms(dur)) ms"
        s += " · next interval \(next.map(ms) ?? "none") ms (P \(ms(P)) ms) · \(k.newFrame ? "new-frame" : "repeat") tick"
        s += " · attempts: " + attemptsText(k)
        s += " · overran: \(top.name) \(ms(top.d)) ms"
        if missed, P.isFinite, dur < P { s += " (the tick ended inside P: the deadline was missed outside the tick)" }
        s += " · parts ms: " + ps.map { "\($0.name) \(ms($0.d))" }.joined(separator: ", ") + "\n"
        out += s
    }

    private func attemptsText(_ k: PresentTimingLog.Tick) -> String {
        let name: (PresentTimingLog.Outcome) -> String = {
            switch $0 {
            case .heldInFlight: return "held in flight"
            case .heldRate: return "held for rate"
            case .noBuffer: return "no command buffer"
            case .nilDrawable: return "nil drawable"
            case .presented: return "presented"
            case .none: return "none"
            }
        }
        let a = [k.a1, k.a2].filter { $0.outcome != .none }
        if a.isEmpty { return "none" }
        return a.map { "\($0.inRender ? "in render" : "tick's 2nd call") \(name($0.outcome)) (in flight \($0.inFlight))" }
            .joined(separator: ", ")
    }

    private mutating func flushWindow(span: Double, totalToo: Bool = true, _ out: inout String) {
        guard w.ticks > 0 else { return }
        // Pending glass older than 2 s will not come: count it, drop it.
        if let last = lastTick?.start {
            for (seq, p) in pending where last - p.host > 2 { pending.removeValue(forKey: seq); w.noHandler += 1; t.noHandler += 1 }
        }
        let playing = w.newFrame > 0, holding = playing && w.heldInFlight > 0
        windows += 1
        if playing { playingWindows += 1 }
        if holding { holdingWindows += 1 }
        out += "[PRESENT-TIMING] \(String(format: "%.0f", span)) s: " + w.line(span: span)
            + " · holding \(holding ? "yes" : playing ? "no" : "not playing")"
            + " · ms p50/p99/max: " + zip(seriesNames, ws).map { "\($0.0) \($0.1.summary)" }.joined(separator: " · ")
            + " · glass n \(w.glass), dropped \(w.dropped), ≥ 2 refreshes \(w.lateTwo), no handler \(w.noHandler)"
            + " · ticks > 5 ms \(w.longTicks) · misses \(w.misses) (overran: \(w.overranText)) · dropped-records \(windowDropped)\n"
        w = Counts(); ws = [Series](repeating: Series(), count: 20); windowDropped = 0
        if totalToo, lastTotalAt.isNaN || windowStart - lastTotalAt >= 60 { total(&out); lastTotalAt = windowStart }
    }

    private func total(_ out: inout String) {
        let share = playingWindows > 0 ? 100 * Double(holdingWindows) / Double(playingWindows) : .nan
        out += "[PRESENT-TIMING] total: " + t.line(span: nil)
            + " · windows \(windows), playing \(playingWindows), holding \(holdingWindows) (\(String(format: "%.1f", share)) %)"
            + " · ms p50/p99/max: " + zip(seriesNames, th).map { "\($0.0) \($0.1.summary)" }.joined(separator: " · ")
            + " · glass n \(t.glass), dropped \(t.dropped), ≥ 2 refreshes \(t.lateTwo), no handler \(t.noHandler)"
            + " · ticks > 5 ms \(t.longTicks) · misses \(t.misses) (overran: \(t.overranText)) · dropped-records \(droppedRecords)\n"
    }

    /// No pacer tick for 2 s (output stopped, or the pacer idled): judge the last tick, close the window, print the total.
    mutating func flushIfStopped(now: Double, into out: inout String) {
        guard let last = lastTick, lastTickSeen.isFinite, now - lastTickSeen > 2 else { return }
        judge(last, next: nil, &out)
        if windowStart.isFinite { flushWindow(span: last.end - windowStart, totalToo: false, &out) }
        lastTick = nil
        windowStart = .nan
        total(&out); lastTotalAt = .nan
    }
}
#endif
