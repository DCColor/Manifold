//
//  LiveAudioPairedProbe.swift
//  ManifoldCore
//
//  Build step 2 of docs/AUDIO_RESAMPLER_DESIGN.md §7: measure the quantity the resampler's
//  control loop will null, BEFORE anything is inserted into the path.
//
//  ⚠️ INSTRUMENT ONLY. It reads two clocks and writes a log line every 10 s. It enqueues nothing,
//  changes nothing about what is enqueued or when, and takes no lock the audio path did not
//  already take. Compiled out entirely outside DEBUG || MANIFOLD_TELEMETRY.
//
//  ── WHAT IS MEASURED, AND WHY IT IS PAIRED ────────────────────────────────────────────────
//
//  §2.1 settled the reader question: read tightly, `synchronizer.currentTime()` is good to
//  0.97 µs sd — 0.047 samples at 48 kHz. THE PAIRING IS THE INSTRUMENT, NOT THE READER. A read
//  pair straddling a preemption produces an error dominated by scheduling, and §11.11 measured
//  exactly that failure at up to 1.1 ms — a hundred times the quantity being measured. So the
//  host clock is read either side of the timebase read and the sample is DISCARDED if the pair
//  spans more than 200 µs. Discards are counted and reported, never silently dropped: a window
//  that discarded half its samples is a window about the scheduler, not about the clocks.
//
//      t0     = CACurrentMediaTime()
//      actual = CMTimeGetSeconds(synchronizer.currentTime())     // device-clock axis
//      t1     = CACurrentMediaTime()
//      target = refMedia + (t1 - refHost) * refRate              // sender/mapping axis
//      err    = actual - target                                  // + = audio timebase AHEAD
//
//  ── WHY THE MAPPING IS EVALUATED LOCALLY ──────────────────────────────────────────────────
//
//  `LiveClock.now()` takes LiveClock's lock, which the 10 Hz control tick also holds. Calling it
//  here would put the audio enqueue thread behind the video control loop, on every buffer. The
//  reference line is instead PUSHED to this probe by `mirrorLiveAudio` / `anchorLiveAudio` and
//  cached under this object's own lock, which nothing else contends. That is a property worth
//  having independently of jitter.
//
//  ── THE TWO REFERENCE SHAPES, AND WHY ONE STRUCT COVERS BOTH ──────────────────────────────
//
//  * MIRRORED transports (SRT, WHEP) carry a `LiveClock.Mapping`, and §2.1's target is
//    `senderPTS + (t1 - hostTime) * rate - cushion`. `mirrorLiveAudio` already computes
//    `senderPTS - cushion` as `target`, so the line is (that, hostTime, mapping rate).
//  * ANCHORED transports (NDI) have no mapping at all — `anchorLiveAudio` sets the timebase to
//    (mediaTime, hostTime) at rate 1.0 and leaves it. The line is (mediaTime, hostTime, 1.0).
//
//  ⚠️ THOSE TWO MEASURE DIFFERENT THINGS AND THE REPORT MUST NOT POOL THEM. On a mirrored
//  transport the reference is refreshed at 10 Hz, so `err` is a SAWTOOTH — it accumulates between
//  rate pushes and is reset by them — and its slope is the instantaneous mismatch the control loop
//  would have to absorb. On NDI the reference is set once and essentially never refreshed
//  (measured: 0 re-anchors in 40 s), so `err` accumulates freely and its slope IS the audio device
//  crystal against mach time. Same arithmetic, two different quantities.
//

#if DEBUG || MANIFOLD_TELEMETRY

import Foundation
import CoreMedia
import QuartzCore

public final class LiveAudioPairedProbe: @unchecked Sendable {

    /// Reject a read pair that spans more than this. §2.1.
    public static let pairingGateSeconds = 200e-6
    /// Reporting cadence. §7 step 2 asks for the implied ppm per 10 s window.
    public static let windowSeconds = 10.0

    /// Ring capacity. 10 s at the fastest cadence in the app (NDI's 10 ms pump, 100 Hz) is 1000
    /// samples; 4096 leaves room for a window that overruns without ever allocating on the audio
    /// thread, which is the property that matters more than the size.
    private static let capacity = 4096

    private let tag: String
    private let readTimebaseSeconds: @Sendable () -> Double

    private let lock = UnfairLock()

    // Reference line, pushed by the mapping/anchor sites.
    private var refMedia = 0.0
    private var refHost = 0.0
    private var refRate = 1.0
    private var refValid = false
    private var refUpdates = 0

    // ── THE SMOOTHED RATE, TRACKED SEPARATELY FROM THE MAPPING'S ─────────────────────────
    //
    // ⚠️ ADDED AFTER THE FIRST SMOKE RUN, WHICH SHOWED WHY §2.1's FORMULA ALONE IS NOT ENOUGH
    // TO SIZE ANYTHING. `mapping.rate` is LiveClock's INSTANTANEOUS rate — the video depth
    // controller's output, which §5.2 describes as bang-bang on a ±5000 ppm rail. Measured over
    // 80 s of local SRT it swung 0.996849 … 1.002282, i.e. ±3400 ppm, window to window.
    //
    // So a straight-line fit of `err` inside one 10 s window is dominated by that rail, not by
    // any clock ratio: the smoke run produced -1886, -278, +83, +239 ppm with r² from 0.03 to
    // 0.70. Those numbers are real and they are not the quantity `B` has to cover.
    //
    // §5.2 is explicit that the rail must NOT be absorbed and reaches the ratio only through the
    // τ=30 s feed-forward. **The rate the resampler actually has to produce is therefore the
    // SMOOTHED one**, which is what `mirrorLiveAudio` already computes and pushes. It is tracked
    // here so the report can state both, and never pool them.
    private var smoothedRate = 1.0
    private var smoothedMin = Double.infinity
    private var smoothedMax = -Double.infinity

    // Window accumulation. Preallocated: no allocation on the audio thread in steady state.
    private var errs = [Double](repeating: 0, count: capacity)
    private var hosts = [Double](repeating: 0, count: capacity)
    private var count = 0
    private var overflowed = 0
    private var discarded = 0
    private var windowStart = 0.0
    private var windowIndex = 0
    private var sessionStart = 0.0

    public init(tag: String, readTimebaseSeconds: @escaping @Sendable () -> Double) {
        self.tag = tag
        self.readTimebaseSeconds = readTimebaseSeconds
    }

    /// Push the reference line. Called from `mirrorLiveAudio` (10 Hz plus mapping changes) and
    /// from `anchorLiveAudio` (rarely). Cheap and non-blocking; never called from the audio thread.
    /// - Parameter smoothed: the rate the mirror would PUSH — `mirror.smoothedRate` on a mirrored
    ///   transport, and 1.0 on an anchored one (NDI never smooths; its timebase is set and left).
    public func noteReference(media: Double, host: Double, rate: Double, smoothed: Double) {
        guard media.isFinite, host.isFinite, rate.isFinite, rate > 0 else { return }
        lock.lock()
        refMedia = media; refHost = host; refRate = rate
        refValid = true; refUpdates += 1
        if smoothed.isFinite, smoothed > 0 {
            smoothedRate = smoothed
            smoothedMin = min(smoothedMin, smoothed)
            smoothedMax = max(smoothedMax, smoothed)
        }
        lock.unlock()
    }

    /// One paired sample. **Called per input buffer, on the enqueue thread.**
    ///
    /// ⚠️ THE TWO HOST READS BRACKET THE TIMEBASE READ AND NOTHING ELSE SITS BETWEEN THEM.
    /// Everything after `t1` is arithmetic on values already in hand.
    public func sample() {
        let t0 = CACurrentMediaTime()
        let actual = readTimebaseSeconds()
        let t1 = CACurrentMediaTime()

        lock.lock()
        if sessionStart == 0 { sessionStart = t1; windowStart = t1 }
        guard refValid else { lock.unlock(); return }

        if t1 - t0 > Self.pairingGateSeconds {
            discarded += 1
            let due = t1 - windowStart >= Self.windowSeconds
            lock.unlock()
            if due { emitWindow() }
            return
        }

        // Straight-line arithmetic: nothing here can block, allocate or format.
        let target = refMedia + (t1 - refHost) * refRate
        let err = actual - target
        if actual.isFinite {
            if count < Self.capacity {
                errs[count] = err; hosts[count] = t1; count += 1
            } else {
                overflowed += 1
            }
        }
        let due = t1 - windowStart >= Self.windowSeconds
        lock.unlock()
        if due { emitWindow() }
    }

    /// Snapshot and reset under the lock; do every expensive thing on a background queue.
    ///
    /// ⚠️ THE SORT, THE FIT, THE FORMATTING AND THE `NSLog` ARE ALL OFF THIS THREAD, AND THAT IS
    /// NOT TIDINESS. `sample()` runs on the transport's enqueue thread 47–100 times a second —
    /// the exact path whose timing is under investigation. `LiveAudioRendererProbe` states the
    /// rule directly for its own rows: *"an `NSLog` there is a syscall on the exact path whose
    /// timing is under investigation"*, and it hops to `qos: .utility` for the same reason. An
    /// instrument that perturbs its own measurement is the failure this whole line of work is
    /// about, so the only work left on the audio thread here is two array copies.
    public func emitWindow() {
        lock.lock()
        let n = count
        guard n > 0 || discarded > 0 else { lock.unlock(); return }
        let e0 = Array(errs[0..<n])
        let h = Array(hosts[0..<n])
        let disc = discarded, over = overflowed, updates = refUpdates
        let start = windowStart
        let end = n > 0 ? h[n - 1] : start
        let sessionElapsed = end - sessionStart
        let refAge = n > 0 ? (end - refHost) : 0
        let rate = refRate
        let sm = smoothedRate
        let smMin = smoothedMin.isFinite ? smoothedMin : sm
        let smMax = smoothedMax.isFinite ? smoothedMax : sm
        windowIndex += 1
        let index = windowIndex
        count = 0; discarded = 0; overflowed = 0; refUpdates = 0
        smoothedMin = .infinity; smoothedMax = -.infinity
        windowStart = CACurrentMediaTime()
        lock.unlock()

        let tag = self.tag
        DispatchQueue.global(qos: .utility).async {
            guard n >= 2 else {
                NSLog("%@ +%.0fs  window %d — %d paired sample(s), %d discarded by the 200 µs gate. "
                    + "Too few to fit; reporting nothing rather than a slope from one point.",
                      tag, sessionElapsed, index, n, disc)
                return
            }

            // Implied ppm: least-squares slope of err against host time. d(err)/dt is
            // dimensionless — seconds of error per second of host time — so x1e6 is ppm directly.
            let mx = h.reduce(0, +) / Double(n)
            let my = e0.reduce(0, +) / Double(n)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for i in 0..<n {
                let dx = h[i] - mx, dy = e0[i] - my
                sxy += dx * dy; sxx += dx * dx; syy += dy * dy
            }
            let slope = sxx > 0 ? sxy / sxx : 0
            let r2 = (sxx > 0 && syy > 0) ? (sxy * sxy) / (sxx * syy) : 0
            let ppm = slope * 1e6

            var e = e0
            e.sort()
            let med = e[n / 2]
            let p99 = e[min(n - 1, Int(Double(n) * 0.99))]
            let p01 = e[max(0, Int(Double(n) * 0.01))]

            // TWO RATE FIGURES, DELIBERATELY SIDE BY SIDE AND LABELLED.
            //   `smoothed`  — what the mirror would push, and therefore what the resampler's
            //                 ratio must produce. THIS is the number that sizes B (§5.2).
            //   `inst`      — LiveClock's instantaneous rate, i.e. the depth controller's rail.
            //                 Reported so the difference between them is visible rather than
            //                 argued, and so a reader cannot mistake one for the other.
            //   `errSlope`  — the straight-line fit of err inside this window. Carries r²,
            //                 because on a mirrored transport it is a sawtooth and a low r² is
            //                 the honest signal that the slope is not a clock ratio.
            NSLog("%@ +%.0fs  window %d · n=%d discarded=%d (%.1f%%)%@ · err ms: med %+.3f "
                + "p01 %+.3f p99 %+.3f min %+.3f max %+.3f · errSlope %+.1f ppm (r²=%.3f over "
                + "%.1f s) · smoothed %.6f (%+.1f ppm, window range %+.1f … %+.1f) · "
                + "inst %.6f (%+.1f ppm) · refUpdates=%d refAge=%.0f ms",
                  tag, sessionElapsed, index, n, disc,
                  (n + disc) > 0 ? 100.0 * Double(disc) / Double(n + disc) : 0,
                  over > 0 ? String(format: " OVERFLOW=%d", over) : "",
                  med * 1e3, p01 * 1e3, p99 * 1e3, e[0] * 1e3, e[n - 1] * 1e3,
                  ppm, r2, end - start,
                  sm, (sm - 1) * 1e6, (smMin - 1) * 1e6, (smMax - 1) * 1e6,
                  rate, (rate - 1) * 1e6,
                  updates, refAge * 1e3)
        }
    }

    /// Final window, so the last partial 10 s is not lost at teardown.
    public func finish() {
        emitWindow()
        NSLog("%@ probe detached.", tag)
    }
}

#endif
