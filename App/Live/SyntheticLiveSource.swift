#if DEBUG
@preconcurrency import AVFoundation
import QuartzCore
import ManifoldCore

/// DEBUG-ONLY test harness that validates `LiveClock` end-to-end with ZERO networking.
///
/// It re-feeds a LOCAL file's already-decoded frames into the renderer through the LIVE
/// path — as if they were arriving off the wire — so the anchor + presentation-clock
/// skeleton can be proven before any WebRTC/WHEP transport exists. This is the exact role
/// the early NDI `⌃⌥N` throwaway trigger played for the NDI display path: a keyboard-driven
/// probe, NOT user-facing UI.
///
/// WHAT "THROUGH THE LIVE PATH" MEANS. Normal file playback rides the engine's
/// `AVSampleBufferRenderSynchronizer` (file timebase) and lets the renderer read
/// `engine.currentSyncTime()`. This harness instead:
///   1. retires file playback (mirrors NDI's `onWillActivateStream` → `engine.stop()`),
///   2. substitutes `renderer.clock = { liveClock.now() }` — the free-running LiveClock,
///   3. PUSHES each decoded frame on its own cadence (a timer at the file's frame rate),
///      stamping the presentation PTS `LiveClock.registerFrame` returns, and enqueuing it.
/// So the frames are genuine file frames, but every timing decision comes from `LiveClock`.
/// `renderer.onDisplayTick` stays nil: this is a PUSH source (unlike NDI's pull-on-tick).
///
/// FRAME SOURCE (how we get decoded frames — see report item (d)): we reuse the exact
/// AVFoundation decode configuration `FileFrameSource` uses — an `AVAssetReaderTrackOutput`
/// requesting `x420` (10-bit 4:2:0 biplanar, the format the shader's range-expansion
/// constants require) with `alwaysCopiesSampleData = false`. We do NOT build a new decoder;
/// we drive that same reader at LIVE cadence (one `copyNextSampleBuffer()` per frame-rate
/// tick) instead of `FileFrameSource`'s renderer-readiness backpressure, because a live
/// source pushes at frame rate, not on the renderer's pull. The `CVPixelBuffer`s are
/// byte-identical to what normal file playback decodes.
///
/// AUDIO (see report item — Step 1 scope): DELIBERATELY OMITTED. Step 1 validates the VIDEO
/// clock path only. Feeding audio through `AudioTapBuffer` on the same LiveClock is the next
/// step, once the video clock is proven.
///
/// THREADING: `start`/`stop` are main-thread only (driven from the SwiftUI shortcut). The
/// emit timer runs on a dedicated serial queue; its tick calls the thread-safe
/// `LiveClock.registerFrame` and `renderer.enqueue` (both documented background-safe). The
/// decode reader is created on main before the timer starts and only mutated/torn down on
/// the emit queue, so its lifecycle is single-threaded.
final class SyntheticLiveSource {

    static let shared = SyntheticLiveSource()
    private init() {}

    /// Serial queue the emit timer + reader lifecycle live on ("frames arriving live").
    // .utility (NOT .userInitiated): the harness must never outrank the render thread. The
    // CVDisplayLink callback + Metal command submission run on a real-time display-link thread;
    // keeping decode subordinate ensures sustained harness decode can't preempt display.
    private let emitQueue = DispatchQueue(label: "com.manifold.synthetic-live", qos: .utility)

    // --- Live state (set on main in start(), torn down on stop()) ---
    private weak var renderer: MetalVideoRenderer?
    private var liveClock: LiveClock?
    private var emitTimer: DispatchSourceTimer?
    /// Absolute deadline for the NEXT emit, advanced by the intended interval each tick (NOT measured
    /// from `.now()` after the handler ran). This makes the emit period exactly `nextInterval()`
    /// instead of `nextInterval() + decode/handler time`, so the producer can't drift slower than the
    /// display consumes and starve the buffer.
    private var nextEmitDeadline: DispatchTime = .now()
    /// The URL being replayed — kept so the loop can rebuild the reader at EOF.
    private var url: URL?
    /// Emit interval = 1 / fps, captured at start.
    private var frameInterval: Double = 1.0 / 30.0

    // --- Drift / jitter injection (Step 2 tuning knobs — see cyclePreset). These alter the EMIT
    // WALL-CLOCK CADENCE ONLY; `senderPTS` is always the frame's real file PTS, never touched. ---

    /// Sender-clock drift: emit at `fps * driftRate`. 1.0 = true rate; 1.001 = 0.1% fast (buffer
    /// fills, the LiveClock loop should slew rate UP to ~driftRate to drain it). Cadence only.
    var driftRate: Double = 1.0
    /// Inter-frame jitter amplitude in seconds: each interval is perturbed by a zero-mean offset in
    /// ±jitterAmplitude, with a running-sum correction so the AVERAGE rate stays exact. 0 = none.
    var jitterAmplitude: Double = 0.0
    /// Running jitter accumulator — keeps the cumulative injected timing offset bounded (mean → 0).
    private var jitterAccum: Double = 0.0
    /// Current tuning-preset label (cycled by the debug shortcut), applied live + to the next start().
    private(set) var presetName = "clean"

    #if DEBUG
    // --- Per-frame emit timing (⌃⌥L tuning). Accumulated per stage over a 1s window, logged as
    // [SYNTH-PERF]. All touched on emitQueue EXCEPT lastQueueCount, written from the display-tick
    // onDepthSample (a benign cross-thread read for telemetry). Reset per run in start(). ---
    private var perfFrameCounter = 0
    private var perfWindowStart: Double = 0
    private var perfSamples = 0
    private var copySum = 0.0,    copyMax = 0.0
    private var copy2Sum = 0.0,   copy2Max = 0.0
    private var enqueueSum = 0.0, enqueueMax = 0.0
    private var totalSum = 0.0,   totalMax = 0.0
    // emitLate = actual fire time − the deadline this tick was scheduled for (see nextEmitDeadline).
    // Grows POSITIVE when the emit timer fires late → the .utility emitQueue is losing CPU to
    // scheduling/QoS contention, so frames are produced late even though each stage is cheap — the
    // "footprint flat + emitLateMs grows" branch. Near 0 while fps still sags = on-time but slow
    // (per-alloc bandwidth / lock contention), a different axis. Signed: can be slightly negative.
    private var emitLateSum = 0.0, emitLateMax = 0.0
    private var lastQueueCount = 0
    #endif

    #if DEBUG
    // --- Auto-sweep (⌃⌥S). Automated 2D grid over (targetDepth × jitter): steps the grid itself, holds
    // each cell 15s (3s settle EXCLUDED from the verdict + 12s measured), logs a one-line verdict per
    // cell, prints a summary table at the end. Replaces manual ⌃⌥P cycling for mapping the near-live
    // depth floor. Drift is pinned 1.0 (this maps depth-vs-jitter headroom, not drift recovery — drift
    // is already validated). Reset-per-cell: each cell gets a fresh anchor + zeroed loop state via
    // LiveClock.setDepths + reset(), so there's no cross-cell contamination. ---
    private static let sweepTargets: [Double] = [0.250, 0.200, 0.150, 0.120, 0.100, 0.080]
    private static let sweepJitters: [Double] = [0.000, 0.004, 0.010, 0.020]
    private static let sweepCellSeconds = 15.0
    private static let sweepSettleSeconds = 3.0        // per-cell settle transient, excluded from accumulators
    private static let sweepMaxQueued = 30             // == start()'s maxQueuedOverride; the overflow line
    private static var sweepCellCount: Int { sweepTargets.count * sweepJitters.count }

    /// Serial queue the 15s per-cell advance timer runs on (separate from emitQueue so cell stepping
    /// never contends with frame emission).
    private let sweepQueue = DispatchQueue(label: "com.manifold.synthetic-sweep", qos: .utility)
    private var sweepTimer: DispatchSourceTimer?
    private(set) var sweepActive = false
    private var sweepCell = 0

    // Per-cell accumulators. WRITTEN on the display-tick thread (sweepAccumulate ← onDepthSample);
    // snapshot + zeroed on sweepQueue at cell boundaries → all guarded by sweepLock, together with
    // sweepCellStartHost (the settle-window origin the accumulator reads to gate itself).
    private let sweepLock = NSLock()
    private var sweepCellStartHost: Double = 0
    private var accFpsMin = Double.infinity, accFpsSum = 0.0, accFpsN = 0
    private var accCountMin = Int.max, accCountMax = 0
    private var accDepthSum = 0.0, accDepthN = 0, accDepthMin = Double.infinity, accDepthMax = 0.0
    private var accStarved = false, accOverflowed = false
    // Results grid [targetIdx][jitterIdx] → (countMin, pass). Touched only on sweepQueue. A cell left at
    // its default (cMin == Int.max) is one the sweep never reached (partial abort) → shown as "—".
    private var sweepResults: [[(cMin: Int, pass: Bool)]] = []
    #endif

    // --- Decode state (created on main, mutated/cleared on emitQueue) ---
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    // --- Owned recycled-surface pool (fix-shape a). Decoded frames are COPIED into a pool buffer so
    // the renderer maps a SMALL FIXED IOSurface set (like the libav file pool, MinimumBufferCount=20)
    // instead of the reader's churning decode surfaces that pinned texMs ~3.0ms every frame. Touched
    // only on emitQueue: created lazily in emitNextFrame, cleared in stop()'s emitQueue teardown.
    // Harness-only — WHEP's VideoToolbox output pool recycles natively and needs none of this. ---
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    // --- Saved renderer providers, restored verbatim on stop() ---
    private var savedClock: (() -> Double)?
    private var savedIsPaused: (() -> Bool)?

    private(set) var isRunning = false

    /// Requested decode format — the SAME 10-bit biplanar format `FileFrameSource` requests.
    /// Must stay 10-bit: the shader's range-expansion constants are in the 10-bit sample domain.
    private static let pixelFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    // MARK: - Control (main thread)

    /// Start replaying `url` through the live path. `retireCurrentSource` is called first to
    /// enforce one active source — ContentView passes `{ engine.stop() }`, mirroring the NDI
    /// `onWillActivateStream` handoff. No-op if already running or the file can't be opened.
    @MainActor
    func start(url: URL, renderer: MetalVideoRenderer, retireCurrentSource: () -> Void) {
        guard !isRunning else { return }

        // Build the decode reader up front (fails fast if the file has no video track).
        guard let built = Self.makeReader(url: url) else {
            NSLog("[SyntheticLive] cannot open \(url.lastPathComponent) — no readable video track")
            return
        }

        // One active source: retire whatever is driving the display (the loaded file) BEFORE we
        // repoint the renderer, so the file pump and our push don't both feed it. Mirrors NDI.
        retireCurrentSource()

        self.url = url
        self.reader = built.reader
        self.output = built.output
        self.frameInterval = built.frameInterval

        let clock = LiveClock(startupDepth: 0.15, targetDepth: 0.15)
        self.liveClock = clock
        clock.setForceUnityRate(forceUnityRate)   // ⌃⌥U diagnostic: carry the current toggle into this run

        // Save the file-path providers so stop() restores normal playback exactly.
        savedClock = renderer.clock
        savedIsPaused = renderer.isPausedProvider

        // Substitute the LIVE clock. now() is "never due" until the first frame anchors it, so
        // nothing renders until we push. isPaused pinned false (we are "playing"). onDisplayTick
        // stays nil — this is a PUSH source (NDI is the pull case that sets it).
        renderer.clock = { [clock] in clock.now() }
        renderer.isPausedProvider = { false }
        renderer.onDisplayTick = nil
        // Push buffer depth into the control loop each tick (App→Core; ManifoldCore can't read the
        // renderer). Strong-captures the clock like renderer.clock above; both cleared on stop().
        // Deliberately forwards ONLY (span, count) and NOT the queue edges the sample now also
        // carries. Passing them would arm LiveClock's freeze guard, and this harness is the
        // measurement baseline: docs/LIVECLOCK_PRESETS.md's depth grid was swept with no coarse
        // intervention in the loop, so a hidden re-anchor would turn a saturated-buffer FAIL into
        // a PASS and invalidate every cell of it. Same reason `snapEnabled` stays off here.
        // This harness has no queue-full policy of its own (drop-oldest is the swept behaviour, and
        // the presets grid depends on it). Explicitly clear the hook so a hook left by a previous
        // WHEP session cannot re-anchor the clock installed just above — which is a DIFFERENT clock
        // than the one that hook captured.
        renderer.onQueueOverflow = nil
        renderer.onDepthSample = { [clock, weak self] sample in
            clock.updateDepth(spanSeconds: sample.spanSeconds, count: sample.count)
            #if DEBUG
            self?.lastQueueCount = sample.count   // stash for [SYNTH-PERF] (display-tick write; benign race)
            // no-op unless a ⌃⌥S sweep is active + past settle
            self?.sweepAccumulate(span: sample.spanSeconds, count: sample.count)
            #endif
        }
        // Give the loop headroom above the shallow file-path bound (12) so a filling buffer has room
        // to be corrected before it saturates and drops the oldest (a visible glitch).
        // 30 (design's original): a DEEP bound so the Step-2 PI integrator's anti-windup clamp sits
        // comfortably BELOW the queue cap — otherwise the buffer saturates and drop-oldest fires before
        // the integrator can recover, and the two fight. (Was temporarily 6 for the pool-pinning
        // diagnostic, since fixed by the recycled-surface pool in copyIntoPool.)
        renderer.maxQueuedOverride = 30
        renderer.flush()   // drop any file frames still queued behind us
        self.renderer = renderer

        jitterAccum = 0.0
        #if DEBUG
        // Reset per-run perf window so [SYNTH-PERF] frame indexing starts at 0 each ⌃⌥L.
        perfFrameCounter = 0; perfWindowStart = 0; perfSamples = 0
        copySum = 0; copyMax = 0; copy2Sum = 0; copy2Max = 0
        enqueueSum = 0; enqueueMax = 0; totalSum = 0; totalMax = 0
        emitLateSum = 0; emitLateMax = 0
        #endif
        isRunning = true

        // Push frames on a SELF-RESCHEDULING one-shot timer so inter-frame spacing can vary per
        // frame (drift + jitter). Each fire emits one frame then arms the next at nextInterval().
        let timer = DispatchSource.makeTimerSource(queue: emitQueue)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            self.emitNextFrame()
            self.rescheduleTimer()
        }
        emitTimer = timer
        // Baseline the absolute emit clock; the first frame fires immediately, subsequent ones
        // advance from this deadline (see rescheduleTimer) rather than from post-handler .now().
        nextEmitDeadline = DispatchTime.now()
        timer.schedule(deadline: nextEmitDeadline, repeating: .never)
        timer.resume()

        NSLog("[SyntheticLive] replaying \(url.lastPathComponent) through the live path @ \(String(format: "%.3f", 1.0 / frameInterval)) fps (LiveClock; preset=\(presetName) drift=\(driftRate) jitter=\(jitterAmplitude)s, maxQueued=\(renderer.maxQueuedOverride ?? 0))")
    }

    /// Stop the harness and restore normal file-playback renderer state.
    @MainActor
    func stop(clearScreen: Bool = true) {
        guard isRunning else { return }
        isRunning = false

        #if DEBUG
        // ⌃⌥⇧L (or a second ⌃⌥S routed here) during a sweep aborts it — cancel the advance timer and
        // print whatever cells completed — BEFORE the harness teardown below. No-op if no sweep is
        // active; on NORMAL sweep completion finishSweep() has already cleared sweepActive, so this
        // won't double-print the summary.
        if sweepActive { abortSweep() }
        #endif

        emitTimer?.cancel()
        emitTimer = nil

        // Restore the file-path providers verbatim (unlike NDI, which leaves its clock in place
        // on disconnect — we restore because file playback may resume right after).
        if let renderer {
            renderer.clock = savedClock
            renderer.isPausedProvider = savedIsPaused
            renderer.onDisplayTick = nil
            renderer.onDepthSample = nil          // stop pushing depth into the (going-away) loop
            renderer.maxQueuedOverride = nil      // back to the file-path default bound
            if clearScreen { renderer.clearToBlack() }   // no source behind us: wipe the last live frame
        }
        savedClock = nil
        savedIsPaused = nil
        renderer = nil

        // Tear the decode state down on the emit queue, serialized AFTER any in-flight tick, so
        // a running emitNextFrame() never races the teardown.
        emitQueue.async { [self] in
            reader?.cancelReading()
            reader = nil
            output = nil
            pool = nil                      // release the recycled surface set
            liveClock?.reset()
            liveClock = nil
            url = nil
        }

        NSLog("[SyntheticLive] stopped — file-playback clock restored")
    }

    // MARK: - Emit (emit queue)

    /// One "frame arrived live" tick: pull the next decoded frame, register it with the clock,
    /// stamp the returned presentation PTS, and enqueue it. On EOF, loop back to the head.
    private func emitNextFrame() {
        guard isRunning,
              let output, let reader, let liveClock, let renderer else { return }

        #if DEBUG
        let tStart = CACurrentMediaTime()
        // Lateness of THIS fire vs the deadline it was armed for. nextEmitDeadline still holds the
        // deadline that scheduled this tick — rescheduleTimer only advances it AFTER this handler
        // returns — so (now − nextEmitDeadline) is exactly actualFire − scheduledDeadline. DispatchTime
        // uptime and CACurrentMediaTime share the mach clock, but we stay in the DispatchTime domain
        // to compare like-for-like against the deadline. Signed ms.
        let emitLateMs = (Double(DispatchTime.now().uptimeNanoseconds) - Double(nextEmitDeadline.uptimeNanoseconds)) / 1e6
        #endif

        guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
            // End of file (or reader error): loop so the harness runs continuously for eyeballing.
            loopToHead()
            return
        }
        #if DEBUG
        let tAfterCopy = CACurrentMediaTime()
        #endif

        let senderPTS = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard senderPTS.isFinite else { return }

        // Sender PTS in → presentation PTS out (identity at rate 1.0). Stamp it on the frame so
        // the enqueue path is already correct for Step 2, when the mapping stops being identity.
        let presentationPTS = liveClock.registerFrame(senderPTS: senderPTS)

        #if DEBUG
        let tBeforeCopy2 = CACurrentMediaTime()   // brackets the pool copy + sample build
        #endif
        // Copy the decoded frame into our OWN recycled pool buffer (on emitQueue, off the render
        // thread), carrying the color attachments, then build the CMSampleBuffer fresh with the
        // LiveClock PTS. Replaces the zero-copy CMSampleBufferCreateCopyWithNewTiming retime, which
        // shared the reader's churning surface — the exact thing that pinned texMs on the render thread.
        guard let sourceImage = CMSampleBufferGetImageBuffer(sample),
              let pooled = copyIntoPool(sourceImage),
              let outSample = Self.makeSampleBuffer(
                  pooled,
                  pts: CMTime(seconds: presentationPTS, preferredTimescale: 1_000_000),
                  duration: CMSampleBufferGetDuration(sample)) else { return }
        #if DEBUG
        let tAfterCopy2 = CACurrentMediaTime()
        #endif

        renderer.enqueue(outSample)

        #if DEBUG
        let tAfterEnqueue = CACurrentMediaTime()
        recordPerf(copy:     tAfterCopy    - tStart,        // (a) reader pull (copyNextSampleBuffer)
                   copy2:    tAfterCopy2   - tBeforeCopy2,  // (b) pool copy + makeSampleBuffer
                   enqueue:  tAfterEnqueue - tAfterCopy2,   // (c) renderer.enqueue (ordered insert)
                   total:    tAfterEnqueue - tStart,        // (d) whole handler
                   emitLate: emitLateMs / 1000.0)          // (e) fire lateness (s; scaled to ms in log)
        #endif
    }

    #if DEBUG
    /// Accumulate per-stage emit timings and log `[SYNTH-PERF]` once/sec. Reveals WHICH stage's time
    /// grows when the sag starts (~frame 168): copy = reader pull, copy2 = pool copy + sample build,
    /// enqueue = queue ordered insert. If all three stay FLAT while presented-fps still sags, the
    /// bottleneck is OUTSIDE this handler — on the display-link/render thread (prime suspect: the
    /// un-flushed CVMetalTextureCache accumulating one texture/IOSurface per distinct frame). Runs on
    /// emitQueue (serial); `lastQueueCount` is a benign cross-thread read of the display tick's count.
    private func recordPerf(copy: Double, copy2: Double, enqueue: Double, total: Double, emitLate: Double) {
        perfFrameCounter += 1
        perfSamples += 1
        copySum += copy;       copyMax    = max(copyMax, copy)
        copy2Sum += copy2;     copy2Max   = max(copy2Max, copy2)
        enqueueSum += enqueue; enqueueMax = max(enqueueMax, enqueue)
        totalSum += total;     totalMax   = max(totalMax, total)
        emitLateSum += emitLate; emitLateMax = max(emitLateMax, emitLate)

        let now = CACurrentMediaTime()
        if perfWindowStart == 0 { perfWindowStart = now; return }
        if now - perfWindowStart < 1.0 { return }

        let n = Double(max(1, perfSamples)), ms = 1000.0
        FileHandle.standardError.write(Data(String(format:
            "[SYNTH-PERF] frame=%d n=%d copyMs=%.2f/%.2f copyMs2=%.2f/%.2f enqueueMs=%.2f/%.2f totalMs=%.2f/%.2f emitLateMs=%.2f/%.2f qCount=%d\n",
            perfFrameCounter, perfSamples,
            copySum / n * ms,    copyMax * ms,
            copy2Sum / n * ms,   copy2Max * ms,
            enqueueSum / n * ms, enqueueMax * ms,
            totalSum / n * ms,   totalMax * ms,
            emitLateSum / n * ms, emitLateMax * ms,
            lastQueueCount).utf8))

        perfWindowStart = now
        perfSamples = 0
        copySum = 0; copyMax = 0
        copy2Sum = 0; copy2Max = 0
        enqueueSum = 0; enqueueMax = 0
        totalSum = 0; totalMax = 0
        emitLateSum = 0; emitLateMax = 0
    }
    #endif

    /// At EOF, rebuild the reader (AVAssetReader is one-shot — can't rewind) and RE-ANCHOR the
    /// clock so the looped playback re-establishes a clean live timeline from the file's head.
    private func loopToHead() {
        guard let url, let liveClock, let built = Self.makeReader(url: url) else {
            NSLog("[SyntheticLive] loop failed — stopping")
            return
        }
        reader?.cancelReading()
        reader = built.reader
        output = built.output
        liveClock.reset()   // next frame re-anchors (startupDepth re-buffer) + re-arms the control loop
    }

    // MARK: - Pacing (emit queue) — drift + jitter injection

    /// Arm the next emit. Called on emitQueue at the end of each tick.
    ///
    /// DRIFT-FREE: advance an ABSOLUTE deadline by the intended interval, so the emit period is
    /// exactly `nextInterval()` and does NOT accumulate the handler's decode/retime/enqueue time
    /// (the bug that made the producer fall below the display's consumption rate and starve).
    private func rescheduleTimer() {
        guard let timer = emitTimer else { return }
        nextEmitDeadline = nextEmitDeadline + nextInterval()

        // Fall-behind guard: if decode stalled and the deadline is now more than a couple frames in
        // the PAST, re-baseline to now instead of letting the scheduler fire a rapid back-to-back
        // catch-up burst (each fire is one frame; a large backlog would flood the buffer). We drop
        // the few late frames rather than emit them all at once. A SMALL lateness is left alone so
        // it self-corrects gently over the next ticks (deadline slightly past → fires promptly).
        let now = DispatchTime.now()
        if nextEmitDeadline < now,
           now.uptimeNanoseconds - nextEmitDeadline.uptimeNanoseconds > UInt64(2.0 * frameInterval * 1e9) {
            nextEmitDeadline = now
        }
        timer.schedule(deadline: nextEmitDeadline, repeating: .never)
    }

    /// The wall-clock interval until the next frame is emitted — where drift + jitter are injected.
    /// DRIFT scales the base interval; JITTER perturbs it with a zero-mean, running-sum-corrected
    /// offset so the mean rate stays exact. This changes ONLY when frames are pushed, never their PTS.
    private func nextInterval() -> Double {
        let base = frameInterval / max(0.0001, driftRate)   // DRIFT: cadence only
        guard jitterAmplitude > 0 else { return base }
        // JITTER: pick a raw offset in ±amplitude, then subtract the accumulated offset. The applied
        // offset telescopes (offsetᵢ = rawᵢ − rawᵢ₋₁), so the cumulative injected error stays bounded
        // by ±amplitude and the mean interval converges to `base` — noisy spacing, exact mean rate.
        let raw = Double.random(in: -jitterAmplitude...jitterAmplitude)
        let offset = raw - jitterAccum
        jitterAccum = raw
        return max(0.0005, base + offset)   // never schedule a non-positive deadline
    }

    /// Cycle the tuning preset (drift/jitter) live — bound to a debug shortcut. Applies to a running
    /// harness immediately (next reschedule) and to the next start(): clean → drift → drift+jitter.
    func cyclePreset() {
        switch presetName {
        case "clean":
            driftRate = 1.001; jitterAmplitude = 0.0;   presetName = "drift"
        case "drift":
            driftRate = 1.001; jitterAmplitude = 0.004; presetName = "drift+jitter"
        default:
            driftRate = 1.0;   jitterAmplitude = 0.0;   presetName = "clean"
        }
        NSLog("[SyntheticLive] preset → \(presetName)  (drift=\(driftRate) jitter=\(jitterAmplitude)s)")
    }

    /// ⌃⌥U diagnostic: force the LiveClock control loop OFF (rate ≡ 1.0) so the MEASURED depth can be
    /// read at unity — the setpoint-reality check before tuning the loop. Applies to a RUNNING clock
    /// immediately AND to the next ⌃⌥L start() (mirrors how cyclePreset applies live + next start).
    private var forceUnityRate = false
    func toggleForceUnityRate() {
        forceUnityRate.toggle()
        liveClock?.setForceUnityRate(forceUnityRate)   // lock-clean; live if the harness is running
        NSLog("[SyntheticLive] forceUnityRate → \(forceUnityRate) — control loop "
            + (forceUnityRate ? "DISABLED (rate≡1.0)" : "ENABLED"))
    }

    // MARK: - Auto-sweep (⌃⌥S) — 2D (targetDepth × jitter) grid, 15s/cell, verdict + summary table

    /// ⌃⌥S: start the automated (targetDepth × jitter) sweep from the currently-loaded file. If a sweep
    /// is ALREADY running, this routes through `stop()` instead — the second-⌃⌥S early-abort path
    /// (stop() calls `abortSweep()` then tears the harness down). Otherwise it ensures the live harness
    /// is up (start() is a no-op if already running — the SAME clock/emit path the sweep just steps),
    /// forces the control loop ON, pins drift 1.0, sizes the results grid, arms cell 0, and starts the
    /// 15s advance timer. Main-thread only (SwiftUI trigger).
    @MainActor
    func startSweep(url: URL, renderer: MetalVideoRenderer, retireCurrentSource: () -> Void) {
        if sweepActive { stop(); return }   // second ⌃⌥S → abort (stop aborts the sweep + restores playback)

        // The sweep validates the CURRENTLY-LOADED clip's rate, so frameInterval must be that clip's. If the
        // harness is already running on a DIFFERENT file (e.g. ⌃⌥L on clip A, then clip B loaded), refuse
        // rather than silently sweep clip A while labeling it clip B's rate — sourceFps is the gate's
        // reference now, so a stale frameInterval would falsify every verdict. Stop, reload, ⌃⌥S. (We do NOT
        // restart in place: a synchronous stop()+start() would race stop()'s async emitQueue teardown, which
        // nils url/liveClock AFTER start() re-sets them.) Same file already running (⌃⌥L then ⌃⌥S) is fine —
        // frameInterval already matches — and falls through.
        if isRunning, self.url != url {
            NSLog("[SWEEP] harness is running on \(self.url?.lastPathComponent ?? "?") — press ⌃⌥⇧L to stop, "
                + "then ⌃⌥S to sweep \(url.lastPathComponent)")
            return
        }

        // Sweep measures the P-loop's depth-vs-jitter headroom, so: loop ON (not ⌃⌥U-pinned) and drift
        // pinned to true rate. Set BEFORE start() so start() carries the loop-ON state into the run.
        forceUnityRate = false
        driftRate = 1.0
        jitterAmplitude = 0.0
        if !isRunning {
            // Not running → start() on the passed (currently-loaded) url reads ITS frameInterval → sourceFps.
            start(url: url, renderer: renderer, retireCurrentSource: retireCurrentSource)
        }
        guard isRunning, liveClock != nil else {
            NSLog("[SWEEP] cannot start — harness not running (load a file first)")
            return
        }
        liveClock?.setForceUnityRate(false)   // in case the harness was already running under ⌃⌥U

        // FRESH PER-SWEEP STATE (not just at init): rebuild the results grid + reset the cell index HERE,
        // and beginCell(0) below zeroes every accumulator + sweepCellStartHost — so no state from a previous
        // clip's sweep bleeds in. sweepActive/sweepTimer are (re)armed at the tail. Nothing sweep-scoped
        // resets only at init.
        sweepResults = Array(repeating: Array(repeating: (Int.max, false), count: Self.sweepJitters.count),
                             count: Self.sweepTargets.count)
        sweepCell = 0
        FileHandle.standardError.write(Data(String(format:
            "[SWEEP] starting — %d cells × %.0fs (%.0fs settle + %.0fs measured), rate=%.3f fps, maxQueued=%d\n",
            Self.sweepCellCount, Self.sweepCellSeconds, Self.sweepSettleSeconds,
            Self.sweepCellSeconds - Self.sweepSettleSeconds, 1.0 / frameInterval, Self.sweepMaxQueued).utf8))
        beginCell(0)              // configure cell 0 (params + cellStartHost + zeroed accumulators) FIRST
        sweepActive = true        // then arm accumulation — the render thread never folds into a half-set cell

        let timer = DispatchSource.makeTimerSource(queue: sweepQueue)
        timer.schedule(deadline: .now() + Self.sweepCellSeconds, repeating: Self.sweepCellSeconds)
        timer.setEventHandler { [weak self] in self?.advanceCell() }
        sweepTimer = timer
        timer.resume()
    }

    /// Configure sweep cell `i`: set the clock's target + startup depth (EQUAL, so the startup FILL lands
    /// at the setpoint — otherwise a deep startup draining to a shallow target at ±maxSlew takes many
    /// seconds and swamps the 3s settle exclusion), reset the clock (clean anchor + zeroed loop state →
    /// no cross-cell contamination), flush the renderer queue (drop the previous cell's frames), set the
    /// cell's jitter, and zero the accumulators + stamp the settle-window origin. Runs on main (cell 0)
    /// or sweepQueue (advance); the clock writes are lock-guarded, jitterAmplitude is a benign race with
    /// nextInterval() on emitQueue (same as cyclePreset), and the accumulators are under sweepLock.
    private func beginCell(_ i: Int) {
        let tgt = Self.sweepTargets[i / Self.sweepJitters.count]
        let jit = Self.sweepJitters[i % Self.sweepJitters.count]

        liveClock?.setDepths(startup: tgt, target: tgt)   // DEBUG setter, under the clock's lock
        liveClock?.reset()                                 // clean anchor + zeroed loop state; next frame re-anchors
        renderer?.flush()                                  // drop the previous cell's queued frames
        jitterAmplitude = jit
        jitterAccum = 0.0

        sweepLock.lock()
        accFpsMin = .infinity; accFpsSum = 0; accFpsN = 0
        accCountMin = .max; accCountMax = 0
        accDepthSum = 0; accDepthN = 0; accDepthMin = .infinity; accDepthMax = 0
        accStarved = false; accOverflowed = false
        sweepCellStartHost = CACurrentMediaTime()          // settle window is measured from here
        sweepLock.unlock()
    }

    /// Fold one depth sample into the CURRENT cell's accumulators. Runs on the display-tick thread (from
    /// onDepthSample). No-op unless a sweep is active AND we're past the per-cell settle window (the first
    /// sweepSettleSeconds after a reset — the re-anchor/re-fill transient, excluded so it can't pollute the
    /// verdict). Reads presentedFPS off the renderer (a benign live read); all accumulator writes + the
    /// sweepCellStartHost read are under sweepLock (shared with beginCell / finishCurrentCell).
    private func sweepAccumulate(span: Double, count: Int) {
        guard sweepActive else { return }
        let fps = renderer?.presentedFPS ?? 0
        sweepLock.lock(); defer { sweepLock.unlock() }
        guard CACurrentMediaTime() - sweepCellStartHost >= Self.sweepSettleSeconds else { return }
        if fps > 0 { accFpsMin = min(accFpsMin, fps); accFpsSum += fps; accFpsN += 1 }
        accCountMin = min(accCountMin, count)
        accCountMax = max(accCountMax, count)
        accDepthSum += span; accDepthN += 1
        accDepthMin = min(accDepthMin, span); accDepthMax = max(accDepthMax, span)
        if count <= 0 { accStarved = true }
        if count >= Self.sweepMaxQueued { accOverflowed = true }   // hit the cap → drop-oldest fired
    }

    /// Per-cell boundary (fires every sweepCellSeconds on sweepQueue): score + log the current cell, then
    /// advance to the next — or finish + print the summary after the last cell.
    private func advanceCell() {
        guard sweepActive else { return }
        finishCurrentCell()
        let next = sweepCell + 1
        if next >= Self.sweepCellCount {
            finishSweep()
            return
        }
        sweepCell = next
        beginCell(next)
    }

    /// Snapshot the current cell's accumulators (under sweepLock, since the render thread is still
    /// writing), compute PASS/FAIL, store the result, and log the one-line verdict. sweepQueue only.
    private func finishCurrentCell() {
        sweepLock.lock()
        let fpsMin = accFpsN > 0 ? accFpsMin : 0
        let fpsMean = accFpsN > 0 ? accFpsSum / Double(accFpsN) : 0
        let countMin = accCountMin == .max ? 0 : accCountMin
        let countMax = accCountMax
        let depthMean = accDepthN > 0 ? accDepthSum / Double(accDepthN) : 0
        let depthMin = accDepthN > 0 ? accDepthMin : 0
        let depthMax = accDepthMax
        let starved = accStarved
        let overflowed = accOverflowed
        sweepLock.unlock()

        let i = sweepCell
        let tIdx = i / Self.sweepJitters.count, jIdx = i % Self.sweepJitters.count
        let tgt = Self.sweepTargets[tIdx], jit = Self.sweepJitters[jIdx]

        // PASS = held the SOURCE rate within 2% AND never starved AND never overflowed. The fps gate is
        // RATE-RELATIVE (sourceFps * 0.98), NOT a fixed 23.5: at 30 fps a sag to 24 is a genuine 6-fps
        // drop that a fixed 23.5 gate would misread as PASS, silently corrupting the 25/30 tables — the
        // very runs whose point is confirming the clock holds AT those rates. sourceFps = 1/frameInterval,
        // recomputed here from THIS run's file (stable across the run).
        let sourceFps = 1.0 / frameInterval
        let pass = (fpsMin >= sourceFps * 0.98) && (countMin >= 1) && (countMax < Self.sweepMaxQueued)
        sweepResults[tIdx][jIdx] = (countMin, pass)

        let flags = (starved ? " STARVED" : "") + (overflowed ? " OVERFLOW" : "")
        FileHandle.standardError.write(Data(String(format:
            "[SWEEP] srcFps=%.3f tgt=%.3f jit=%.3f | fpsMin=%.1f fpsMean=%.1f countMin=%d countMax=%d "
            + "depthMean=%.3f depthMin=%.3f depthMax=%.3f%@ | %@\n",
            sourceFps, tgt, jit, fpsMin, fpsMean, countMin, countMax,
            depthMean, depthMin, depthMax, flags, pass ? "PASS" : "FAIL").utf8))
    }

    /// Last-cell wrap-up: print the summary grid, clear sweep state, then hop to main to tear the harness
    /// down (stop() is @MainActor). sweepActive is cleared BEFORE stop() so stop()'s abort hook is a no-op
    /// (the summary is already printed here).
    private func finishSweep() {
        printSweepSummary()
        sweepActive = false
        sweepTimer?.cancel(); sweepTimer = nil
        DispatchQueue.main.async { [weak self] in self?.stop() }
    }

    /// Early abort (second ⌃⌥S, or ⌃⌥⇧L): cancel the advance timer, clear the flag, and print whatever
    /// cells completed (unreached cells show as "—"). Called from stop() BEFORE its teardown; leaves the
    /// harness teardown to stop() itself.
    private func abortSweep() {
        guard sweepActive else { return }
        // Serialize teardown onto sweepQueue so it can't race an in-flight advanceCell (which writes
        // sweepResults / the accumulators). sync is deadlock-safe here: sweepQueue never blocks on the
        // caller's thread (finishSweep hops to main via async), and abortSweep is only ever called from
        // stop() on main — never from sweepQueue — so this is not a sync-on-self.
        sweepQueue.sync {
            guard sweepActive else { return }
            sweepActive = false
            sweepTimer?.cancel(); sweepTimer = nil
            FileHandle.standardError.write(Data(String(format:
                "[SWEEP] ABORTED at cell %d/%d\n", sweepCell + 1, Self.sweepCellCount).utf8))
            printSweepSummary()
        }
    }

    /// Print the compact summary grid: rows = targets, cols = jitter, each cell showing countMin and
    /// PASS/FAIL. The FAIL boundary walking up the shallow / high-jitter corner IS the preset map — the
    /// shallowest PASSING target at each jitter level. sweepQueue only.
    private func printSweepSummary() {
        // Fixed 11-char columns so the grid stays aligned in the log.
        func col(_ s: String) -> String {
            s.count >= 11 ? s + " " : s + String(repeating: " ", count: 11 - s.count)
        }
        var out = String(format: "[SWEEP-SUMMARY] srcFps=%.3f (PASS gate: fpsMin ≥ srcFps×0.98)\n", 1.0 / frameInterval)
        out += col("")   // 11-space lead under the row labels
        for jit in Self.sweepJitters { out += col(String(format: "jit=%.3f", jit)) }
        out += "\n"
        for (tIdx, tgt) in Self.sweepTargets.enumerated() {
            out += col(String(format: "tgt=%.3f:", tgt))
            for jIdx in Self.sweepJitters.indices {
                let r = sweepResults[tIdx][jIdx]
                out += col(r.cMin == .max ? "cMin=—/—" : "cMin=\(r.cMin)/\(r.pass ? "P" : "F")")
            }
            out += "\n"
        }
        FileHandle.standardError.write(Data(out.utf8))
    }

    // MARK: - Helpers

    /// Build an AVFoundation reader with the SAME config `FileFrameSource` uses: x420 10-bit
    /// biplanar, no data copy. Returns the reader (already started), its output, and the emit
    /// interval derived from the track's nominal frame rate. `nil` if there is no video track.
    private static func makeReader(url: URL) -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput, frameInterval: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        // Request IOSurface-backed, Metal-compatible pixel buffers so CVMetalTextureCache can create
        // ZERO-COPY textures (the same fast path normal decoder frames get). Without the IOSurface
        // key, a copied buffer is non-IOSurface-backed, forcing a slow CPU→GPU upload per frame on the
        // render thread that accumulates and throttles presentation to 14-19fps. The x420/x422 10-bit
        // format key is unchanged; we only ADD the IOSurface + Metal-compat attributes.
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],   // IOSurface backing (zero-copy)
            kCVPixelBufferMetalCompatibilityKey as String: true    // usable as a Metal texture
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        // Zero-copy from the decoder pool (false). The earlier alwaysCopiesSampleData=true workaround
        // (to stop downstream retention pinning the pool) is REVERTED: it produced non-IOSurface
        // copies, which was the real render-thread cost. The pool-pinning is now fixed at the RIGHT
        // layer — MetalVideoRenderer flushes its CVMetalTextureCache each displayTick, so it no longer
        // retains pool buffers indefinitely (the actual cause of the pinning).
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let fps = track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 30.0
        return (reader, output, 1.0 / fps)
    }

    /// Lazily create / reuse an IOSurface-backed, Metal-compatible pool sized to the decoded frame.
    /// MinimumBufferCount=34 (maxQueued 30 + in-flight + reader lead) so the renderer re-maps a small
    /// fixed IOSurface set instead of first-mapping a fresh surface every frame. Mirrors
    /// LibavFrameSource.ensurePool. emitQueue only.
    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, poolWidth == width, poolHeight == height { return pool }
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Self.pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 34
        ]
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, pbAttrs as CFDictionary,
                                      &newPool) == kCVReturnSuccess else { return nil }
        self.pool = newPool
        self.poolWidth = width
        self.poolHeight = height
        return newPool
    }

    /// Copy `source` (the reader's decode surface) into a recycled pool buffer, plane by plane and
    /// stride-honest, then carry ALL propagatable attachments across. Returns the owned buffer the
    /// renderer maps repeatedly (cheap re-map) instead of a never-seen churning surface. emitQueue only.
    private func copyIntoPool(_ source: CVImageBuffer) -> CVPixelBuffer? {
        let width  = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard let pool = ensurePool(width: width, height: height) else { return nil }

        var dest: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dest) == kCVReturnSuccess,
              let dest else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        // Per-plane (biplanar 10-bit = 2), row by row, honoring each buffer's OWN stride — never
        // assume src and dst strides match; copy min(stride) bytes for GetHeightOfPlane rows.
        let planeCount = CVPixelBufferGetPlaneCount(source)
        for plane in 0..<planeCount {
            guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let dst = CVPixelBufferGetBaseAddressOfPlane(dest, plane) else { return nil }
            let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(dest, plane)
            let rows      = CVPixelBufferGetHeightOfPlane(source, plane)
            let rowBytes  = min(srcStride, dstStride)
            if srcStride == dstStride {
                memcpy(dst, src, rows * srcStride)          // strides match → one contiguous copy
            } else {
                for row in 0..<rows {
                    memcpy(dst + row * dstStride, src + row * srcStride, rowBytes)
                }
            }
        }

        // Carry EVERY .shouldPropagate attachment the source declared — not just the color triplet.
        // A copy (unlike libav's fresh constructor) must preserve chroma location and the full/video-
        // range flag the 10-bit range read keys on; dropping the range flag misreads legal vs full →
        // wrong black level. Also avoids the soft-deprecated Get/SetAttachment API.
        CVBufferPropagateAttachments(source, dest)
        return dest
    }

    /// Wrap a pool pixel buffer in a ready CMSampleBuffer at `pts`. Mirrors LibavFrameSource.
    private static func makeSampleBuffer(_ pb: CVPixelBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescriptionOut: &formatDesc) == noErr,
            let formatDesc else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pb, formatDescription: formatDesc,
            sampleTiming: &timing, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
#endif
