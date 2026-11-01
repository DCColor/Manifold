//
//  OutputPacer.swift
//  Manifold
//
//  THE TICK SOURCE OF A RENDERER THAT FEEDS DECKLINK OUTPUT (0.9.1, docs/DISPLAY_LINK_PER_WINDOW_PLAN.md §4.4).
//
//  Every SDI frame is made by the owning window's render, and a window's display link follows the display the window is
//  on. Left there, SDI would be paced by a desktop display: 119.88 out of a window on a 60 Hz display could never be fed,
//  and 59.94 would beat against it. So while output runs, the renderer's tick comes from here instead: one thread on the
//  host clock, at a period set by the card's mode and the source's rate (`OutputPacerTiming`), never by a display. It
//  calls the same `displayTick` the link calls; selection, render, convert, ring and pull do not change.
//
//  ⚠️ THE SAME CONTRACT AS THE LINK IT REPLACES, BECAUSE THE RENDERER'S IDLE MACHINERY DRIVES BOTH:
//    • `setRunning(false)` returns only once no tick is in flight (as `CVDisplayLinkStop` waits for its callback);
//    • the tick never waits on the caller of `setRunning` or `cancel` (the renderer calls them on `linkQueue` only);
//    • a missed deadline is skipped, not made up in a burst.
//  `cancel()` joins the thread. Neither may be called from the tick itself.
//
//  The interval statistics (median, p99, max) go to the log every 10 s while ticking, and for the whole run at cancel.
//

import Foundation
import QuartzCore
import OutputPacing

final class OutputPacer: @unchecked Sendable {
    private let cond = NSCondition()
    private var period: Double            // cond
    private var running = false           // cond
    private var cancelled = false         // cond
    private var inTick = false            // cond
    private var resumed = false           // cond: the thread restarts its phase and its interval chain
    private let finished = DispatchSemaphore(value: 0)
    private let label: String
    private let tick: () -> Void

    // Pacer thread only, then read by `cancel()` after the join.
    private var window = IntervalStats()
    private var run = IntervalStats()
    private var missedWindow = 0
    private var missedRun = 0
    private var windowStart: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var policyNote = ""

    init(period: Double, label: String, tick: @escaping () -> Void) {
        self.period = period
        self.label = label
        self.tick = tick
        // Strong: the thread keeps the pacer until `cancel()` ends the loop, so a pacer can never be freed under its thread.
        let thread = Thread { self.loop() }
        thread.name = "com.graviton.manifold.outputpacer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Start or stop the ticks. Stopping waits for a tick in flight. Never from the tick.
    func setRunning(_ on: Bool) {
        cond.lock()
        if on, !running { resumed = true }
        running = on
        cond.broadcast()
        while !on && inTick { cond.wait() }
        cond.unlock()
    }

    var isRunning: Bool { cond.lock(); defer { cond.unlock() }; return running && !cancelled }

    /// A new rate (the source changed under a running output). Takes effect from the next deadline, phase restarted.
    func setPeriod(_ p: Double) {
        cond.lock(); period = p; resumed = true; cond.broadcast(); cond.unlock()
    }

    /// Stop for good and join the thread; returns the whole run's interval line. Never from the tick.
    @discardableResult
    func cancel() -> String {
        cond.lock(); cancelled = true; running = false; cond.broadcast(); cond.unlock()
        finished.wait()
        return "intervals over the run: \(run.summary) · missed deadlines \(missedRun)\(policyNote)"
    }

    // MARK: - The thread

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()
    private static func machTicks(_ seconds: Double) -> UInt64 {
        UInt64(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// Real-time scheduling like CoreVideo's link thread: the period, half of it as computation, all of it as constraint.
    private func applyTimeConstraint(period p: Double) {
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(clamping: Self.machTicks(p)),
            computation: UInt32(clamping: Self.machTicks(p / 2)),
            constraint: UInt32(clamping: Self.machTicks(p)),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        policyNote = rc == KERN_SUCCESS ? "" : " · ⚠️ time-constraint policy refused (\(rc)), user-interactive QoS only"
        if rc != KERN_SUCCESS { print("[PACER] ⚠️ time-constraint policy refused (\(rc)) — running at user-interactive QoS") }
    }

    private func loop() {
        var deadline: UInt64 = 0
        var appliedPeriod = 0.0
        while true {
            cond.lock()
            while !running && !cancelled { cond.wait() }
            if cancelled { cond.unlock(); break }
            let p = period
            if resumed { resumed = false; deadline = 0; lastTick = 0 }
            cond.unlock()
            if p != appliedPeriod { applyTimeConstraint(period: p); appliedPeriod = p }
            let step = Self.machTicks(p)
            if deadline == 0 { deadline = mach_absolute_time() + step }
            mach_wait_until(deadline)

            cond.lock()
            guard running, !cancelled, !resumed else { cond.unlock(); continue }
            inTick = true
            cond.unlock()
            note(CACurrentMediaTime(), period: p)
            tick()
            cond.lock(); inTick = false; cond.broadcast(); cond.unlock()

            deadline += step
            let after = mach_absolute_time()
            if after >= deadline {
                let missed = (after - deadline) / step + 1
                deadline += missed * step
                missedWindow += Int(missed); missedRun += Int(missed)
            }
        }
        finished.signal()
    }

    private func note(_ now: CFTimeInterval, period p: Double) {
        if lastTick > 0 { let dt = now - lastTick; window.add(dt); run.add(dt) }
        lastTick = now
        if windowStart == 0 { windowStart = now }
        guard now - windowStart >= 10 else { return }
        print(String(format: "[PACER] %@ · P %.2f ms · intervals 10 s: %@ · missed %d", label, p * 1000, window.summary, missedWindow))
        window.reset(); missedWindow = 0; windowStart = now
    }
}
