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
//  OPTION C (docs/CARD_PULL_MARGIN.md §7 C; `MANIFOLD_PACER_PHASE=1`; every configuration). With `phaseSample` set, after each
//  tick the pacer asks the renderer what its selection saw and moves the next deadline by at most 20 µs, so the new-frame
//  ticks keep their phase against the frames' due times (`PacerPhaseFollower`). Before the reference is set, a phase within
//  0.5 ms of a due time is moved off it in one step of at most 0.5 ms (the establishment guard). With `phaseSample` nil (`=0`, in any configuration) the loop's deadline arithmetic is `deadline += step`, as before; the switch costs one nil test a tick.
//
//  C+ (docs/CARD_PULL_MARGIN.md §17.3; `MANIFOLD_PACER_PHASE=2`; **the default since 0.9.5, Release included**: unset is C+, `=0` is off,
//  `PacerSwitches.phaseMode`). Option C, plus `leadSample`: the renderer's pull phase for
//  this Play (the handed frame's lead plus its tick's x). The follower then moves its reference earlier, inside the guard band, so the
//  card's lead is at least P + 0.5 ms where the band allows (`PacerPhaseFollower.leadGuard`). With `leadSample` nil (=1) the follower
//  is option C exactly.
//
//  Export Diagnostics (production): each missed deadline is also added to `PlaybackCounters`, in the branch that already counts it.
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
    /// Option C: what the renderer's selection saw on the tick just run. Nil with the switch off; then nothing of option C runs.
    private let phaseSample: (() -> PacerPhaseSample)?
    /// C+ only: the renderer's pull phase (seconds) for this Play, or nil. Nil for option C; then the follower never reads it.
    private let leadSample: (() -> Double?)?
    private var phaseMatched = false      // cond: the card and source rates are matched (`PacerPhase.isMatched`)

    // Pacer thread only, then read by `cancel()` after the join.
    private var window = IntervalStats()
    private var run = IntervalStats()
    private var missedWindow = 0
    private var missedRun = 0
    private var windowStart: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var policyNote = ""
    // Option C, pacer thread only, used only with `phaseSample` set.
    private var follower: PacerPhaseFollower?
    private var phaseMatchedNow = false
    private var phaseResetPending = false
    private var phaseWindowStart: CFTimeInterval = 0

    init(period: Double, label: String, phaseSample: (() -> PacerPhaseSample)? = nil, phaseMatched: Bool = false,
         leadSample: (() -> Double?)? = nil, tick: @escaping () -> Void) {
        self.period = period
        self.label = label
        self.tick = tick
        self.phaseSample = phaseSample
        self.phaseMatched = phaseMatched
        self.leadSample = leadSample
        if phaseSample != nil { follower = PacerPhaseFollower(quantum: Self.secondsPerMachTick, leadGuard: leadSample != nil) }
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

    /// Option C only (`MANIFOLD_PACER_PHASE=1`): a new rate and whether it is matched, together, so the restart sees both.
    func setPeriod(_ p: Double, phaseMatched matched: Bool) {
        cond.lock(); period = p; phaseMatched = matched; resumed = true; cond.broadcast(); cond.unlock()
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
    /// Option C's quantum: one mach tick in seconds.
    private static var secondsPerMachTick: Double { Double(timebase.numer) / Double(timebase.denom) / 1e9 }

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
            if resumed {
                resumed = false; deadline = 0; lastTick = 0
                // Option C: a wake or a re-rate restarts the phase, so the reference is set afresh.
                if phaseSample != nil { phaseResetPending = true; phaseMatchedNow = phaseMatched }
            }
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

            if let phaseSample {
                deadline = followPhase(phaseSample, deadline: deadline, step: step, period: p)
            } else {
                deadline += step
            }
            let after = mach_absolute_time()
            if after >= deadline {
                let missed = (after - deadline) / step + 1
                deadline += missed * step
                missedWindow += Int(missed); missedRun += Int(missed)
                PlaybackCounters.addPacerMissedDeadlines(Int(missed))
            }
        }
        if phaseSample != nil, follower != nil { print("[PACER-PHASE] " + follower!.report(run: true)) }
        finished.signal()
    }

    /// Option C, pacer thread, after the tick: ask the renderer what its selection saw, follow the phase, and return the next
    /// deadline (`PacerPhase.nextDeadline`, signed and saturating; correction 0 is `deadline + step`). At a rate mismatch every
    /// tick is inactive, so the pacer is exactly as with the switch off, apart from the summary line.
    private func followPhase(_ sample: () -> PacerPhaseSample, deadline: UInt64, step: UInt64, period p: Double) -> UInt64 {
        if phaseResetPending { phaseResetPending = false; follower!.reset() }
        let (correction, event) = follower!.tick(phaseMatchedNow ? sample() : .inactive, period: p,
                                                 pullPhase: phaseMatchedNow ? leadSample?() : nil)
        if case .referenceSet(let ref, let median, let guarded)? = event {
            print(String(format: "[PACER-PHASE] reference set · x_ref %.3f ms · median of the first %d new-frame ticks %.3f ms · guard %@ · P %.2f ms",
                         ref * 1000, PacerPhase.window, median * 1000,
                         guarded == .none ? "none" : guarded == .raised ? "applied (raised to 0.5 ms)" : "applied (lowered to P − 0.5 ms)",
                         p * 1000))
        } else if case .establishmentNudge(let x, let moved)? = event {
            print(String(format: "[PACER-PHASE] establishment guard · x %.3f ms within %.1f ms of a due time · moved %+.3f ms · P %.2f ms",
                         x * 1000, PacerPhase.guardMargin * 1000, moved * 1000, p * 1000))
        } else if case .leadGuard(let pp, let from, let to, let reaches)? = event {
            print(String(format: "[PACER-PHASE] lead guard · pull phase %.3f ms · lead %.3f ms < P + %.1f ms · x_ref %.3f → %.3f ms (lead %.3f ms)%@ · P %.2f ms",
                         pp * 1000, PacerPhase.lead(x: from, pullPhase: pp) * 1000, PacerPhase.leadSlack * 1000, from * 1000, to * 1000,
                         PacerPhase.lead(x: to, pullPhase: pp) * 1000, reaches ? "" : " · at the guard band's edge", p * 1000))
        }
        let now = CACurrentMediaTime()
        if phaseWindowStart == 0 { phaseWindowStart = now }
        if now - phaseWindowStart >= 10 {
            print("[PACER-PHASE] " + follower!.report(seconds: now - phaseWindowStart) + (phaseMatchedNow ? "" : " · rate mismatched: inactive"))
            phaseWindowStart = now
        }
        return PacerPhase.nextDeadline(previous: deadline, step: step, correction: correction)
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
