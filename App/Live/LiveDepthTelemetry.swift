//
//  LiveDepthTelemetry.swift
//  Manifold
//
//  The MEASUREMENT half of a LiveClock-paced push source: the surplus ledger, the underrun
//  accountant and the arrival-rate bins.
//
//  ── WHY THIS MOVED OUT OF WHEPFrameRouter ──────────────────────────────────────────────
//
//  It was written there, against a Cloudflare feed, and it is what turned `targetDepth` from a
//  guessed number into a measured one: `[WHEP-UNDERRUN]` gives the true deficit the renderer's
//  clamped depth signal hides, and `[WHEP-BACKLOG]`'s residual is a real bound rather than a
//  fitted one. SRT arrives needing exactly that instrument and NOT WHEP's answer — SRT has its
//  own transport-level de-jitter buffer doing part of the same job, so its cushion has to be
//  re-derived from scratch. Cloning ~350 lines of accounting to do that would have meant two
//  copies of the residual derivation, drifting apart from the first bug fixed in one of them.
//
//  So the accounting moved here, verbatim, and both routers own an instance. The log PREFIX is
//  a parameter, so WHEP's lines are byte-identical to what they were and SRT's read
//  `[SRT-BACKLOG]` / `[SRT-JITTER]` / `[SRT-UNDERRUN]`.
//
//  ── WHY NOT INTO LiveDisplayRoute ──────────────────────────────────────────────────────
//
//  Because that type's header says, in the load-bearing paragraph, that it does NOT own the
//  per-frame state: `activate` RETURNS the LiveClock rather than holding it, precisely so the
//  owner's lock discipline on the hot path is not disturbed. Telemetry is per-frame state with
//  two writer threads and its own lock. Putting it inside LiveDisplayRoute would have made that
//  type the owner of exactly the thing it documents itself as not owning, and would have put a
//  second lock in the path of a `deactivate` that runs on main. A sibling that each router owns
//  keeps the sharing and keeps the discipline.
//
//  ── WHAT DELIBERATELY DID NOT MOVE ─────────────────────────────────────────────────────
//
//  The DRIFT accountant (`[WHEP-DRIFT]`, senderRatio = 1 − d(offset)/dt) stayed in
//  WHEPFrameRouter. It is not general: it reports the sender's rate in RTP 90 kHz ticks per
//  second and it answers a question — "is the Cloudflare sender's crystal fast?" — that SRT's
//  TSBPD scheduling reframes rather than inherits. When SRT needs a drift number it needs a
//  different derivation, not this one under a different prefix.
//
//  ── THREADING ──────────────────────────────────────────────────────────────────────────
//
//  Written from BOTH threads, exactly as it was in WHEPFrameRouter: the source's decode/demux
//  thread supplies arrivals and queue-full jumps; the CVDisplayLink render thread supplies
//  snap/freeze-guard jumps and, every display tick, the selection occupancy.
//
//  UNFAIR LOCK, NOT NSLock — TEXTBOOK PRIORITY INVERSION. The real-time render thread takes this
//  every tick in `recordSelection`, while the lower-priority source thread holds it per frame.
//  `NSLock` is a pthread_mutex and does NOT boost its holder, so the source thread can be
//  descheduled while holding it and stall the display tick for an unbounded interval — the same
//  shape as the live-path inversion `queueLock` was converted to fix. `os_unfair_lock` DONATES
//  the blocked render thread's priority to the holder, which is what dissolves it.
//
//  The usage rule that makes this safe, and which every critical section below obeys: NOTHING
//  SLOW UNDER THIS LOCK. Every site snapshots what it needs, unlocks, and only then formats and
//  emits its NSLog — a boosted holder must release promptly, and an NSLog inside the critical
//  section would defeat the whole point.
//

import Foundation
import ManifoldCore      // UnfairLock — the priority-donating lock
import QuartzCore

final class LiveDepthTelemetry {

    /// Log prefix: "WHEP" or "SRT". Produces `[WHEP-BACKLOG]`, `[SRT-UNDERRUN]`, and so on.
    private let prefix: String

    /// The clock's one-time ANCHOR offset, fixed at activate() — `startupDepth`, which is the same
    /// field as the configured `targetDepth`. NOT the live target: the ledger's cushion term is the
    /// offset the anchor was actually built with, and a runtime step of the target is accounted for
    /// separately, through `recordClockJump`.
    private let cushion: Double

    /// The clock's rate rail. The residual IS the integrated slew and nothing else, so
    /// |residual| ≤ maxSlew × elapsed is a REAL bound; this is the number that makes it computable.
    private let maxSlew: Double

    init(prefix: String, cushion: Double, maxSlew: Double) {
        self.prefix = prefix
        self.cushion = cushion
        self.maxSlew = maxSlew
    }

    // MARK: - Surplus accountant (the convergence proof)
    //
    // WHAT IT PROVES. A live sender's SFU (or an SRT publisher resuming after a pause) delivers a
    // BACKLOG on connect, faster than real time, and every latency fix rests on that surplus being
    // FINITE — the sender makes N pictures/s and cannot exceed that indefinitely, so discarding is
    // guaranteed to converge. This ledger is what turns that argument into an observation: SURPLUS
    // MUST GO FLAT once the backlog drains. A surplus that keeps climbing after the first few
    // seconds would falsify the whole diagnosis.
    //
    // THE LEDGER. Content is measured from the SENDER's own timeline
    // (`lastSenderPTS − firstSenderPTS`) rather than an assumed fps — it is the sender's own
    // statement of how much media it produced, and it is the same quantity LiveClock is anchored to.
    //
    //     surplus  = content − wall            (media produced beyond real time)
    //     netJump  = Σ every coarse clock jump, SIGNED (see below)
    //     inBuffer = lastSenderPTS − now()     (media sitting AHEAD of the presentation clock)
    //
    // WHY THERE IS A CUSHION TERM. At rate 1.0 with no jump the anchor gives, identically,
    //
    //     depth(T) = lastPTS − now(T) = (content − wall) + startupDepth = surplus + startupDepth
    //
    // because `now()` is anchored `startupDepth` BEHIND the first frame on purpose. That cushion is
    // deliberately-injected latency, not surplus, so a ledger reading `surplus − netJump − inBuffer`
    // rests at a constant −startupDepth and never closes. Carrying it explicitly makes it close:
    //
    //     residual = surplus + cushion − netJump − inBuffer
    //
    // ── WHY inBuffer IS MEASURED AT THE ARRIVAL AND NOT TAKEN FROM THE RENDERER ────────────────
    //
    // It used to be the renderer's depth sample. That made the residual a LIE, and the arithmetic
    // of why is worth keeping: with no backlog `surplus ≈ 0`, so the printed residual collapsed to
    // `cushion − inBuffer` and faithfully re-reported the current depth while claiming to be a
    // convergence proof. The renderer's span is the wrong quantity three times over: it is
    // `max(0, …)`-CLAMPED (so an empty queue reads 0 when the true lead is strongly NEGATIVE —
    // exactly the case worth seeing), it carries a `+Δ/2` half-frame correction the ledger never
    // asked for, and it is sampled on a different thread at a different instant.
    //
    // Measuring `lastSenderPTS − clock.now()` at the arrival — same PTS timeline as `content`, same
    // instant, UNCLAMPED — makes every other term cancel identically. With
    // `now(h) = firstPTS − cushion + ∫rate·dt + Σjumps`:
    //
    //     inBuffer = content + cushion − ∫rate·dt − netJump
    //     residual = (content − wall) + cushion − netJump − inBuffer  =  ∫rate·dt − wall
    //
    // WHICH IS THE INTEGRATED SLEW, EXACTLY — and nothing else. `rate` is hard-clamped to
    // 1 ± maxSlew, so |residual| ≤ maxSlew × wall is a REAL bound, not a fitted one, and OVER can
    // only mean a clock jump happened that is not in `netJump`. That is a bug, and it is the only
    // thing the flag should ever fire on. A small epsilon covers read-skew between `senderPTS` and
    // `now()` plus float error; it is stated, not tuned to keep the flag quiet.
    //
    // Unclamped `inBuffer` also goes NEGATIVE during an underrun — the newest frame is already
    // overdue — which is the truthful reading and directly useful next to the underrun line.
    //
    // WHY netJump IS SIGNED. A manual `targetDepth` RAISE re-anchors the clock BACKWARD to acquire
    // the extra cushion immediately. That is a coarse clock action like any other, but a negative
    // one. Accumulating only positive discards would put every keypress outside the ledger and trip
    // OVER on a deliberate action. Discards are positive, added cushion is negative, and the label
    // says `netJump` so a negative total reads correctly rather than as a nonsensical negative
    // "flushed".

    private let lock = UnfairLock()
    private static let window = 5.0
    /// Read-skew + float slop allowed on top of the slew bound before the residual is flagged OVER.
    private static let residualEpsilon = 0.002

    /// First frame's sender PTS + the host time it arrived — the two origins the ledger measures from.
    private var firstSenderPTS: Double?
    private var firstHost: Double = 0
    /// Newest sender PTS seen. `content = lastSenderPTS − firstSenderPTS`.
    private var lastSenderPTS: Double = 0
    /// Pictures delivered since the stream began (the headline count).
    private var pictures = 0
    /// Cumulative SIGNED presentation time crossed by coarse clock actions: positive = discarded
    /// (snap / freeze-guard / queue-full), negative = deliberately added cushion (manual target raise).
    private var netJump: Double = 0
    private var lastLogHost: CFTimeInterval = 0

    /// Accumulate one coarse clock jump. SIGNED — see `netJump`. Called from the RENDER thread
    /// (snap, freeze-guard), the SOURCE thread (queue-full re-anchor) and MAIN (manual target step),
    /// hence the lock.
    func recordClockJump(_ seconds: Double) {
        #if DEBUG || MANIFOLD_TELEMETRY
        guard seconds.isFinite, seconds != 0 else { return }
        lock.lock()
        netJump += seconds
        lock.unlock()
        #endif
    }

    // MARK: - Underrun accounting (how much cushion is ACTUALLY required)
    //
    // THE MISSING MEASUREMENT. The renderer's depth signal is `max(0, …)`-clamped, so a 50 ms
    // shortfall and a 400 ms shortfall both read `depth=0.000 count=0`. That makes every underrun
    // look identical and gives no basis whatever for choosing `targetDepth` — the number gets
    // guessed instead of measured. This measures the TRUE deficit.
    //
    // WHY IT SPANS TWO THREADS. The two halves only exist in different places and neither alone
    // gives the deficit:
    //
    //   * RENDER THREAD (the selection path, via onDepthSample ← performDisplayTick): `count == 0`
    //     at a display tick is already known there, captured in the same `queueLock` critical
    //     section as selection. Opens the episode and counts starved ticks.
    //   * SOURCE THREAD (on arrival): only there do the arriving frame's PTS and the clock's
    //     current position coexist. Closes the episode and computes the lateness.
    //
    // THE DERIVATION — "cushion needed". At the arrival instant the clock reads N = now() and the
    // frame carries PTS P:
    //
    //     lateness  L = N − P        (positive ⇒ the frame was already overdue when it landed)
    //
    // The cushion IS the clock's backward offset: a `targetDepth` larger by Δ means `now()` reads
    // N − Δ at that same instant, so the frame would have been on time iff N − Δ ≤ P, i.e. iff
    // Δ ≥ L. Therefore
    //
    //     cushionNeeded(event) = currentTargetDepth + max(0, L)
    //
    // read from the LIVE target (the ⌃⌥[ / ⌃⌥] stepper moves it), not the value configured at init.
    //
    // L ≤ 0 IMPLIES NO INCREASE IS REQUIRED: the queue reached zero margin but nothing was actually
    // missed. Real, worth counting, but not a reason to add latency — only genuine misses move the
    // number.
    //
    // SELF-CHECK. The queue empties when `now` crosses the last frame's PTS, so
    // `starvedDuration ≈ L + Δframe`. An underrun SHORTER than one frame interval must therefore
    // have L ≤ 0. A sub-frame-interval starvation reporting a large positive L would mean this
    // measurement is broken, and the log carries both numbers so that is visible rather than assumed.
    //
    // ARMING. `armed` gates everything, and is set on the first tick that actually presents a frame.
    // Before that the queue is empty at EVERY tick by construction (the startup fill), so an unarmed
    // detector would log one enormous bogus episode on every connect. Per-STREAM, for the same
    // reason as LiveClock's `hasPresentedOnce`: on a RECONNECT a still-armed detector does exactly
    // that again across the new stream's fill. Cleared in `reset()`.

    /// False until a frame has actually been presented on this stream. See ARMING above.
    private var armed = false
    /// Host time the current starvation episode began; nil when the queue is not empty.
    private var underrunSince: CFTimeInterval?
    /// Display ticks observed with an empty queue in the current episode.
    private var underrunTicks = 0
    /// Running max of `cushionNeeded` across the whole stream — the figure an adaptive-depth
    /// controller will read to size `targetDepth`.
    ///
    /// ON THE FUNCTIONAL PATH, NOT THE TELEMETRY PATH. This used to be written only inside
    /// `#if DEBUG || MANIFOLD_TELEMETRY`, with a standing note saying to move it out when adaptive
    /// depth shipped. It is moved out now, ahead of that work, because SRT's `targetDepth` is an
    /// ARGUED starting value rather than a measured one — a cushion figure that exists only in
    /// Debug and Profile cannot inform a controller that has to run in Release. What it costs is a
    /// lock acquisition and a handful of integer stores per starvation EPISODE (not per frame and
    /// not per tick beyond the existing one), which is nothing next to being unable to measure the
    /// thing at all.
    private var cushionNeededMax: Double = 0
    /// Episodes across the stream. Ungated for the same reason as `cushionNeededMax`: a max with
    /// no sample count behind it is not a basis for any decision.
    private var totalUnderrunCount = 0

    /// The measured "cushion needed" an adaptive-depth controller will consume.
    ///
    /// STILL AN OPTIONAL, AND DELIBERATELY SO. It is nil until at least one starvation episode has
    /// CLOSED, which is the difference between "no cushion was ever needed" and "nothing has been
    /// measured yet" — the same fail-loud property the old telemetry gate gave it, now expressed
    /// against the sample count instead of against the build configuration. It is NOT flattened to
    /// a non-optional with a 0.0 default: a caller must not be able to read "measured zero" out of
    /// "measured nothing".
    var measuredCushionNeeded: Double? {
        lock.lock(); defer { lock.unlock() }
        return totalUnderrunCount > 0 ? cushionNeededMax : nil
    }

    /// How many starvation episodes have closed on this stream. The sample count behind
    /// `measuredCushionNeeded`, exposed so a caller can weigh it.
    var measuredUnderrunCount: Int {
        lock.lock(); defer { lock.unlock() }
        return totalUnderrunCount
    }

    /// Every positive lateness seen this stream, for the all-time shape. Bounded so a long session
    /// cannot grow it without limit; the running max above is unaffected by the bound.
    private var allLatenessValues: [Double] = []
    private static let latenessCap = 512
    /// Positive latenesses observed in the CURRENT 5 s window, listed verbatim in the rollup.
    /// DIAGNOSTIC ONLY — it feeds the `[…-JITTER]` line's verbatim list and nothing else, so it
    /// stays behind the gate and a Release build allocates neither array.
    private var windowLateness: [Double] = []
    /// Episodes (including L ≤ 0 ones) in the current window. Diagnostic; the stream total that
    /// backs `measuredCushionNeeded` is `totalUnderrunCount`, above and ungated.
    private var windowUnderrunCount = 0

    /// Arrival-rate bins: pictures delivered per 1 s sub-window, so the rollup can report the
    /// min/max arrival rate WITHIN the 5 s window. A window mean would hide exactly the burstiness
    /// at issue — 15 in one second and 32 in the next averages to a healthy-looking 23.5.
    private var arrivalBinStart: CFTimeInterval = 0
    private var arrivalBinCount = 0
    private var arrivalWindowMin = Int.max
    private var arrivalWindowMax = 0

    /// RENDER THREAD, from the selection path. One display tick's queue occupancy.
    /// `count == 0` opens or extends a starvation episode; anything else closes the run and arms.
    ///
    /// UNGATED — it is the opening half of `measuredCushionNeeded`, which now has to exist in
    /// Release (see that property). One uncontended lock acquisition and three integer stores per
    /// display tick, on a thread that has just done a Metal draw.
    func recordSelection(count: Int, presented: Bool) {
        lock.lock()
        if presented { armed = true }
        if count == 0, armed {
            if underrunSince == nil {
                underrunSince = CACurrentMediaTime()
                underrunTicks = 0
            }
            underrunTicks += 1
        }
        lock.unlock()
    }

    /// SOURCE THREAD, on arrival. Closes an open starvation episode and emits its line.
    /// `senderPTS` is the presentation PTS (identity at this seam) and `clockNow` is `now()` read
    /// at the same instant — the pair the lateness is computed from.
    ///
    /// SPLIT DOWN THE MIDDLE, AND THE SPLIT IS THE POINT: the ACCOUNTING is unconditional and the
    /// REPORTING is gated. Everything that feeds `measuredCushionNeeded` — closing the episode,
    /// computing the lateness, advancing the running max and the sample count — runs in every
    /// configuration. The per-window lateness arrays and the `[…-UNDERRUN]` line are diagnostics
    /// and stay behind the gate, so Release does the arithmetic without allocating or logging.
    func closeUnderrunIfOpen(senderPTS: Double, clockNow: Double, target: Double) {
        lock.lock()
        guard let since = underrunSince, clockNow.isFinite else {
            lock.unlock()
            return
        }
        let host = CACurrentMediaTime()
        let starved = host - since
        let ticks = underrunTicks
        underrunSince = nil
        underrunTicks = 0

        let lateness = clockNow - senderPTS
        let cushionNeeded = target + max(0, lateness)
        totalUnderrunCount += 1
        cushionNeededMax = max(cushionNeededMax, cushionNeeded)
        #if DEBUG || MANIFOLD_TELEMETRY
        windowUnderrunCount += 1
        if lateness > 0 {
            windowLateness.append(lateness)
            if allLatenessValues.count < Self.latenessCap {
                allLatenessValues.append(lateness)
            }
        }
        #endif
        lock.unlock()

        #if DEBUG || MANIFOLD_TELEMETRY
        NSLog("""
              [%@-UNDERRUN] queue empty for %.3fs, %d ticks starved, recovered when frame \
              arrived %+.3fs late vs clock — would have needed cushion >= %.3fs (target now %.3fs)
              """, prefix, starved, ticks, lateness, cushionNeeded, target)
        #else
        _ = (starved, ticks)   // measured above; only the reporting is compiled out
        #endif
    }

    /// Fold one arrival into the 1 s arrival bins. Source thread, called under `lock`.
    private func foldArrivalBinLocked(host: CFTimeInterval) {
        #if DEBUG || MANIFOLD_TELEMETRY
        if arrivalBinStart == 0 { arrivalBinStart = host }
        // CLOSE ELAPSED BINS FIRST, THEN COUNT. Counting before advancing would attribute this
        // arrival to whichever bin happened to still be open — so a 3 s gap would dump the frames
        // from BEFORE the gap plus this one into the first bin and record the gap's seconds as
        // separate zeros afterwards. Advancing first puts the arrival in the bin its timestamp
        // actually falls in, and the intervening zero-count bins are then truthful: no frames
        // arrived in those seconds, which is precisely the starvation the min is meant to expose.
        while host - arrivalBinStart >= 1.0 {
            arrivalWindowMin = min(arrivalWindowMin, arrivalBinCount)
            arrivalWindowMax = max(arrivalWindowMax, arrivalBinCount)
            arrivalBinStart += 1.0
            arrivalBinCount = 0
        }
        arrivalBinCount += 1
        #endif
    }

    /// Fold one arriving picture into the ledger and emit the 5 s lines when due. Source thread.
    ///
    /// `clockNow` is `now()` read at this same instant on this same thread — see the inBuffer
    /// discussion in the ledger block above for why it must be measured here rather than taken
    /// from the renderer's clamped span.
    func recordArrival(senderPTS: Double, clockNow: Double) {
        #if DEBUG || MANIFOLD_TELEMETRY
        let host = CACurrentMediaTime()

        lock.lock()
        pictures += 1
        lastSenderPTS = senderPTS
        foldArrivalBinLocked(host: host)
        if firstSenderPTS == nil {
            firstSenderPTS = senderPTS
            firstHost = host
            lastLogHost = host
            lock.unlock()
            return
        }
        guard host - lastLogHost >= Self.window, let originPTS = firstSenderPTS else {
            lock.unlock()
            return
        }
        lastLogHost = host
        let picturesSnapshot = pictures
        let content = senderPTS - originPTS
        let wall = host - firstHost
        let netJumpSnapshot = netJump

        // Snapshot + re-arm the per-window jitter/underrun state in the SAME critical section, so
        // the two lines below describe one consistent window with no arrivals lost between them.
        let windowL = windowLateness
        let windowUnderruns = windowUnderrunCount
        let cushionNeededSnapshot = cushionNeededMax
        let totalUnderruns = totalUnderrunCount
        let allL = allLatenessValues
        // A window with no closed bin yet (fewer than 1 s of arrivals) leaves min at Int.max.
        let arrivalsMin = arrivalWindowMin == Int.max ? arrivalBinCount : arrivalWindowMin
        let arrivalsMax = max(arrivalWindowMax, 0)
        windowLateness.removeAll(keepingCapacity: true)
        windowUnderrunCount = 0
        arrivalWindowMin = Int.max
        arrivalWindowMax = 0
        lock.unlock()

        // ── THE LEDGER ──────────────────────────────────────────────────────────────────────
        // inBuffer on the SAME timeline as content, at the SAME instant, UNCLAMPED. Negative
        // during an underrun, which is the truthful reading.
        let inBuffer = senderPTS - clockNow
        let surplus = content - wall
        let residual = surplus + cushion - netJumpSnapshot - inBuffer
        // residual IS the integrated rate slew and nothing else (see the derivation above), so it
        // cannot exceed maxSlew × elapsed. Beyond that bound, a clock jump happened that is not in
        // netJump — a bug, and the only thing this flag should ever fire on.
        let bound = maxSlew * wall + Self.residualEpsilon
        let flag = abs(residual) > bound ? " OVER" : ""

        NSLog("""
              [%@-BACKLOG] pictures=%d over %.1fs (=%.2fs content) vs wall %.1fs → \
              surplus %+.2fs cumulative | netJump %+.2fs | inBuffer %+.2fs | cushion %.3fs | \
              residual %+.3fs (bound ±%.3fs)%@
              """,
              prefix, picturesSnapshot, wall, content, wall,
              surplus, netJumpSnapshot, inBuffer, cushion, residual, bound, flag)

        // ── THE DISTRIBUTION ────────────────────────────────────────────────────────────────
        // Running max alone is pinned forever by one outlier, which makes it a poor basis for
        // choosing a target and a worse one for any later adaptive control. The SHAPE is what
        // distinguishes "many small misses" (a modestly deeper cushion fixes it) from "a few large
        // ones" (it does not, and something smarter is needed).
        //
        // With a handful of events per window a computed percentile is noise dressed as a
        // statistic, so the window's individual latenesses are listed VERBATIM. The all-time
        // p50/p90 appears only once there are enough samples to mean something.
        let nominal = content > 0 ? Double(picturesSnapshot - 1) / content : 0
        let windowShape = windowL.isEmpty
            ? "none"
            : windowL.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        let worst = windowL.max() ?? 0
        let allTime = Self.percentileSummary(allL)

        NSLog("""
              [%@-JITTER] window arrivals min=%d max=%d (nominal %.2f) | underruns=%d \
              (stream %d) | worst deficit %.3fs | window L: [%@] | cushion needed >= %.3fs \
              (running max)%@
              """,
              prefix, arrivalsMin, arrivalsMax, nominal, windowUnderruns, totalUnderruns,
              worst, windowShape, cushionNeededSnapshot, allTime)
        #endif
    }

    /// All-time p50/p90 of the positive latenesses, or "" while the sample is too small for a
    /// percentile to be more informative than the raw list already printed per window. 8 is the
    /// point below which p90 is just "the largest value" wearing a statistical hat.
    private static func percentileSummary(_ values: [Double]) -> String {
        #if DEBUG || MANIFOLD_TELEMETRY
        guard values.count >= 8 else { return "" }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            let idx = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
            return sorted[idx]
        }
        return String(format: " | all-time L p50=%.3fs p90=%.3fs (n=%d)",
                      percentile(0.5), percentile(0.9), sorted.count)
        #else
        return ""
        #endif
    }

    /// Clear ALL per-stream measurement state: the ledger, the underrun detector and its arming
    /// flag, and the arrival bins.
    ///
    /// PER-STREAM, AND THAT IS LOAD-BEARING. A reconnect is a different sender and a different
    /// backlog; carrying the previous stream's content origin across the gap would manufacture an
    /// enormous phantom surplus from the discontinuity alone.
    ///
    /// `armed` ESPECIALLY. A reconnect performs a fresh startup fill, during which the queue is
    /// empty at every display tick by construction. A still-armed detector would open an episode on
    /// the first of those ticks and hold it open across the whole fill, logging one enormous bogus
    /// underrun on the second and every subsequent connect — the exact failure the
    /// arm-after-first-present rule exists to prevent, merely displaced from first connect to every
    /// later one. Identical reasoning to LiveClock's `hasPresentedOnce`, which its `reset()` clears.
    ///
    /// Callers do this from BOTH activate (before any frame of the new stream can arrive — the
    /// strongest guarantee point, and it does not depend on teardown having run) and teardown.
    /// Either alone would do; both means no connect path can miss it.
    func reset() {
        lock.lock()
        // ── FUNCTIONAL. Cleared in EVERY configuration, because the underrun accounting runs in
        //    every configuration. Leaving these behind a gate would mean a Release build carried
        //    the previous stream's `armed` flag and cushion max across a reconnect — the exact
        //    stale-state bug this method exists to prevent, present only in the build nobody can
        //    watch a log on.
        armed = false
        underrunSince = nil
        underrunTicks = 0
        cushionNeededMax = 0
        totalUnderrunCount = 0
        #if DEBUG || MANIFOLD_TELEMETRY
        // ── DIAGNOSTIC. The ledger, the lateness arrays and the arrival bins exist only under the
        //    gate, so there is nothing to clear without it.
        firstSenderPTS = nil
        firstHost = 0
        lastSenderPTS = 0
        pictures = 0
        netJump = 0
        lastLogHost = 0
        allLatenessValues.removeAll()
        windowLateness.removeAll()
        windowUnderrunCount = 0
        arrivalBinStart = 0
        arrivalBinCount = 0
        arrivalWindowMin = Int.max
        arrivalWindowMax = 0
        #endif
        lock.unlock()
    }
}
