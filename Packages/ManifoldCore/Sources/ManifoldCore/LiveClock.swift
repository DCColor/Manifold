import Foundation
import QuartzCore

/// A free-running presentation clock for LIVE push sources (WHEP, and later SRT/HLS).
///
/// WHY THIS EXISTS: file playback rides the `AVSampleBufferRenderSynchronizer`'s file
/// timebase — every frame's presentation time is a position on a known, seekable
/// timeline. A live source has no such timeline: frames arrive carrying a *sender*
/// timestamp (the encoder's clock), off the network, at the mercy of jitter. NDI dodged
/// this entirely by leaning on the SDK's FrameSync (which owns the jitter buffer + rate
/// conversion) and simply stamping each pulled frame with `CACurrentMediaTime()` at the
/// instant before the display tick reads the clock. WHEP has no FrameSync, so we build the
/// clock ourselves. `LiveClock` is that clock's Step-1 skeleton.
///
/// WHAT IT DOES (Step 1): it anchors the sender timeline to the local host clock on the
/// FIRST frame, then free-runs at wall-clock speed. `now()` is the closure that drives
/// `MetalVideoRenderer.clock` while a live source owns the display — the same seam NDI
/// substitutes `{ CACurrentMediaTime() }` into, but timeline-aware.
///
/// THE MAPPING. With the anchor `(anchorSenderPTS, anchorHostTime)` and rate `r`:
///
///     now()  =  anchorSenderPTS + (hostNow() - anchorHostTime) * r
///
/// The anchor is established on the first frame as:
///
///     anchorSenderPTS = firstFrame.senderPTS
///     anchorHostTime  = hostNow() + targetDepth
///
/// The `+ targetDepth` is the whole trick: it pushes the host anchor into the FUTURE, so
/// `now()` starts out *behind* the first frame's PTS and only catches up after `targetDepth`
/// seconds of wall-time have elapsed. During that window the renderer's `pts <= now`
/// selection rejects every frame — which is exactly the startup buffer fill. A frame with
/// sender PTS `T` therefore becomes due at host time:
///
///     anchorHostTime + (T - anchorSenderPTS)   =   (t0 + targetDepth) + (T - firstPTS)
///
/// i.e. `targetDepth` seconds after the first frame arrived, then paced 1:1 with the sender
/// timeline. That is the "near-live with a small safety buffer" behavior we want.
///
/// STEP 1 SCOPE — read this before extending: `rate` is FIXED at 1.0. There is NO drift
/// correction and NO buffer-depth control loop yet. `now()` advances at exactly wall-clock
/// speed. Step 2 introduces the control loop that modulates `rate` slightly (±) from the
/// measured buffer depth to pull the presentation clock back toward the sender without
/// visible jumps — the single marked TODO below is where that lands.
///
/// THREADING: `registerFrame(senderPTS:)` is called from the SOURCE thread (a frame arrives
/// off the network / decode), while `now()` is read on the `CVDisplayLink` render thread.
/// The anchor state is therefore guarded by an `NSLock` (same discipline as `AudioTapBuffer`).
/// Both entry points are cheap and never block beyond the lock.
public final class LiveClock: @unchecked Sendable {

    /// The presentation/host rate — the multiplier in `now()`. Starts at 1.0 (wall-clock speed);
    /// once frames flow, `updateDepth`'s control loop is the ONLY writer, slewing it a hair around
    /// 1.0 to hold the buffer at `targetDepth`. `private(set)` because nothing outside the clock
    /// modulates it. Read in `now()` and written in `updateDepth`, both under `lock`.
    public private(set) var rate: Double = 1.0

    /// Sender-timeline PTS of the first frame — the origin the mapping is anchored to.
    /// `nil` until the first `registerFrame`; `now()` returns "never due" while it is nil.
    private var anchorSenderPTS: Double?

    /// Host time (`CACurrentMediaTime()`) the anchor is pinned to, pushed `startupDepth`
    /// into the future so the buffer fills before the first frame comes due.
    private var anchorHostTime: Double?

    /// Seconds of buffer to fill before the FIRST frame is presented — the startup delay / initial
    /// cushion, applied once when the anchor is established (see `registerFrame`). DISTINCT from
    /// `targetDepth`: startup is a one-time fill, target is the steady-state hold point.
    private let startupDepth: Double

    /// The steady-state control SETPOINT: the buffer depth (seconds of lead ahead of `now()`) the
    /// loop holds once running. `error = smoothedDepth - targetDepth` drives the rate slew.
    private let targetDepth: Double

    // --- Control-loop tuning (public var so the debug/tuning pass can adjust them live) ---

    /// Loop gain: rate change per second-of-depth-error. SMALL by design — start ~0.8 and tune.
    /// Proportional-only, so a tiny steady-state droop is expected: holding rate `r` needs
    /// error `(r-1)/k`; with k=0.8 and r=1.001 that is ~0.00125 s of depth offset — negligible.
    public var k: Double = 0.8

    /// Hard cap on rate deviation from 1.0. TIGHT — ±0.5% keeps `now()` in 0.995…1.005 so the
    /// correction is invisible on video. The loop can only recover senders within this ratio.
    public var maxSlew: Double = 0.005

    /// EMA weight on each incoming depth sample (0…1). Low-passes the per-tick span so the loop
    /// reacts to the trend, not refresh-rate noise. Small = smoother/slower.
    public var emaAlpha: Double = 0.1

    /// How often the rate is actually recomputed, in Hz. `updateDepth` is called at the display
    /// tick (60–120 Hz); the rate slew is rate-limited to this cadence so it doesn't chase noise.
    public var controlHz: Double = 10
    private var controlInterval: Double { 1.0 / controlHz }

    #if DEBUG
    /// DIAGNOSTIC (⌃⌥U): force the control loop OFF — pin `rate` at unity (1.0) while leaving the
    /// depth EMA and `[LIVECLOCK]` logging running UNCHANGED, so the MEASURED depth can be read under
    /// rate≡1.0 to confirm the setpoint is real (not a sawtooth / tick-quantization offset the loop
    /// would otherwise chase). `private(set)` + the locked setter below keep read (in `updateDepth`,
    /// under `lock`) and write (cross-thread, from the App harness) consistently guarded. Default OFF.
    public private(set) var forceUnityRate = false
    /// Lock-clean cross-thread write for `forceUnityRate` — same `lock` `updateDepth` reads it under,
    /// so the pin is applied with no window of ambiguity near the steady-state depth measurement.
    public func setForceUnityRate(_ on: Bool) { lock.lock(); forceUnityRate = on; lock.unlock() }
    #endif

    // --- Control-loop state (guarded by `lock`) ---

    /// EMA-smoothed buffer depth in seconds; `nil` until the first sample seeds it.
    private var smoothedDepth: Double?
    /// Host time of the last rate recompute — gates the slew to `controlHz`.
    private var lastControlHost: Double?
    /// Host time of the last telemetry line — gates the DEBUG log to ~1 Hz.
    private var lastLogHost: Double?
    /// Latest queue count (telemetry only).
    private var lastCount: Int = 0

    /// Guards the anchor state AND the control-loop state (`rate` / `smoothedDepth` / gates) across
    /// the source thread (writer, via `registerFrame`), the render thread (reader `now`, writer
    /// `updateDepth`), and `reset`. Same discipline as `AudioTapBuffer`.
    private let lock = NSLock()

    /// - Parameters:
    ///   - startupDepth: seconds of buffer to fill before the FIRST frame is presented (the startup
    ///     delay / initial cushion — pushes the host anchor into the future).
    ///   - targetDepth: the steady-state control SETPOINT the loop holds the buffer at once running.
    ///     Same default as `startupDepth`, independently tunable.
    public init(startupDepth: Double = 0.15, targetDepth: Double = 0.15) {
        self.startupDepth = startupDepth
        self.targetDepth = targetDepth
    }

    /// Register a newly-arrived frame's sender-timeline PTS and get back the presentation PTS
    /// to stamp on the `CMSampleBuffer` before enqueuing it.
    ///
    /// On the FIRST frame this establishes the anchor (`anchorSenderPTS = senderPTS`,
    /// `anchorHostTime = hostNow() + targetDepth`). On every frame it returns the presentation
    /// PTS. In Step 1, with `rate == 1.0`, the sender and presentation timelines are identical,
    /// so the returned value IS `senderPTS` — the mapping is an identity offset by the anchor,
    /// realized purely in *when* `now()` crosses each PTS (via the host anchor), not in the PTS
    /// value itself. (Step 2's non-unity rate will make this a genuine remap; keeping the call
    /// here now means the source's stamping path is already correct when that lands.)
    ///
    /// Called on the source thread.
    public func registerFrame(senderPTS: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if anchorSenderPTS == nil {
            anchorSenderPTS = senderPTS
            anchorHostTime = hostNow() + startupDepth
        }
        // rate == 1.0 (Step 1): presentation PTS == sender PTS. When Step 2 modulates `rate`,
        // this becomes the sender→presentation remap and stops being an identity.
        return senderPTS
    }

    /// Current presentation time, in the SENDER timeline's units — the closure handed to
    /// `renderer.clock`. Read on the `CVDisplayLink` render thread every tick.
    ///
    /// Before the anchor is set (no frame has arrived) it returns a value guaranteed to be
    /// less than any real PTS, so the renderer's `pts <= now` selection presents NOTHING until
    /// the first frame anchors the clock.
    public func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let anchorSenderPTS, let anchorHostTime else {
            // Not yet anchored: "never due" — nothing renders until the first frame arrives. Use
            // -.infinity (NOT -.greatestFiniteMagnitude, which is FINITE): it is still < any real PTS
            // so the renderer's `pts <= now` selection rejects everything, but being NON-FINITE it
            // lets the renderer's depth sampler detect the unanchored clock (`now.isFinite == false`)
            // and report span 0 — instead of computing `realPTS - hugeNegative ≈ 1.7e308`, a poison
            // value that would slam the control loop to max slew and never recover.
            return -.infinity
        }
        // now() = anchorSenderPTS + (hostNow() - anchorHostTime) * rate
        //
        // Step 2 (implemented): `rate` is no longer a constant. `updateDepth(...)` runs a gentle
        // control loop that slews `rate` a hair above/below 1.0 to hold the buffer at `targetDepth`,
        // writing it under `lock`. This mapping line is UNCHANGED — `rate` was always the
        // multiplier; the loop just makes it live. In steady state `rate` settles to the sender's
        // true clock ratio and the buffer pins at `targetDepth` — that settled rate IS the
        // recovered sender clock, found by the loop rather than computed.
        return anchorSenderPTS + (hostNow() - anchorHostTime) * rate
    }

    /// Whether the first frame has anchored the clock. `false` before the first `registerFrame` and
    /// after `reset()` (until the next frame arrives). While `false`, `now()` returns the -.infinity
    /// sentinel and the control loop must not run. Thread-safe (takes `lock`) — do NOT call it from
    /// code already holding `lock` (e.g. `updateDepth`), which checks the raw field instead.
    public var isAnchored: Bool {
        lock.lock(); defer { lock.unlock() }
        return anchorSenderPTS != nil
    }

    /// Feed a buffer-depth sample into the control loop. Called from the App-layer sampler at the
    /// display-tick rate (60–120 Hz) — the renderer PUSHES `(spanSeconds, count)` because LiveClock
    /// (ManifoldCore) cannot read the renderer (App). This is NOT a per-call rate recompute: the
    /// span is EMA-low-passed every call, but `rate` is only re-slewed at `controlHz` (a few Hz),
    /// so the loop tracks the trend, not per-refresh noise.
    ///
    /// The loop: `error = smoothedDepth - targetDepth`. A too-DEEP buffer (sender running fast)
    /// means `now()` is trailing, so we slew `rate` slightly ABOVE 1.0 to advance the clock faster
    /// and drain back to target; too-shallow slews below. `maxSlew` keeps the move invisible.
    ///
    /// Called on the render thread; writes `rate` under `lock` (the same lock `now()` reads it under).
    public func updateDepth(spanSeconds: Double, count: Int) {
        lock.lock()
        defer { lock.unlock() }

        #if DEBUG
        // forceUnityRate: control loop DISABLED. Pin `rate` at unity here so it is EXACTLY 1.0 from
        // the first call after the toggle (not just from the next 10 Hz recompute). Everything below —
        // the anchor guard, the depth EMA, the [LIVECLOCK] log — runs identically to normal; only the
        // rate SLEW is skipped (see the matching bypass in the recompute block).
        //
        // JUMP-FREE ⌃⌥U: pinning is itself a rate change, so writing rate = 1.0 in place would jump
        // now() by (hostNow − anchorHostTime)·(1.0 − rate) — the same session-age-growing hop the
        // recompute re-anchor fixes. ⌃⌥U is the loop-OFF measurement baseline and must inject NO
        // transient, so apply the identical rebase BEFORE pinning: only when the rate is ACTUALLY
        // changing (rate != 1.0) and the clock is anchored, evaluate old now() at `t` and restart the
        // segment at (mappedNow, t). This pin runs BEFORE the L224 anchor guard, so bind the anchor
        // pair rather than force-unwrap — the binding makes it a no-op before the first frame (no
        // position to preserve), and the rate != 1.0 guard prevents churn while already pinned. The
        // unconditional `rate = 1.0` below is the pin itself.
        if forceUnityRate {
            if rate != 1.0, let aPTS = anchorSenderPTS, let aHost = anchorHostTime {
                let t = hostNow()
                anchorSenderPTS = aPTS + (t - aHost) * rate   // old now() evaluated at t
                anchorHostTime  = t
            }
            rate = 1.0
        }
        #endif

        // HARDENING: never run the loop while UNANCHORED (now() is the -.infinity sentinel, so a real
        // frame PTS minus it would be a poison span), nor on a NON-FINITE or ABSURD span (sane depth
        // is 0…~1s; 10s is generous headroom). Drop the smoothed depth so the EMA re-primes cleanly
        // from the first real sample once anchored, and leave `rate` where it is — reset() pinned it
        // to 1.0 while unanchored, so a garbage sample can never slew it. Checks the RAW anchor field,
        // not `isAnchored`, because we already hold `lock` (NSLock is non-recursive).
        guard anchorSenderPTS != nil, spanSeconds.isFinite, abs(spanSeconds) < 10 else {
            smoothedDepth = nil
            return
        }

        // Low-pass the raw span (reject per-tick jitter) — every call.
        if let s = smoothedDepth {
            smoothedDepth = emaAlpha * spanSeconds + (1.0 - emaAlpha) * s
        } else {
            smoothedDepth = spanSeconds
        }
        lastCount = count

        let t = hostNow()

        // Rate-limit the actual rate recompute to `controlHz` — don't chase refresh-rate noise.
        if let last = lastControlHost, t - last < controlInterval {
            logIfDue(t)
            return
        }
        lastControlHost = t

        #if DEBUG
        // Loop OFF: `rate` is already pinned to 1.0 at entry. Log at the normal cadence and return
        // WITHOUT slewing — so [LIVECLOCK] shows depth/err measured at rate≡1.0, rate=1.0000.
        if forceUnityRate { logIfDue(t); return }
        #endif

        let depth = smoothedDepth ?? spanSeconds
        let error = depth - targetDepth
        // Proportional slew, hard-clamped to ±maxSlew so `rate` stays in ~0.995…1.005.
        // P-LAW UNCHANGED — the computed value is byte-identical to before; it is merely routed
        // through `newRate` so the write can be gated on an actual change and paired with a re-anchor.
        let proposed = 1.0 + k * error
        let newRate = min(1.0 + maxSlew, max(1.0 - maxSlew, proposed))

        // RE-ANCHOR ON RATE CHANGE. The mapping now() = anchorSenderPTS + (hostNow − anchorHostTime)·rate
        // is ABSOLUTE, so assigning a new rate in place jumps now() by (t − anchorHostTime)·(newRate − rate)
        // — a discontinuity that GROWS with session age (~6ms at 60s, ~360ms at 3600s for a 1e-4 delta),
        // yanking presentation position by an ever-larger amount on every loop correction. Instead, rebase
        // the anchor to the CURRENT mapped position (computed with the OLD rate/anchor, reusing the recompute
        // `t` already in hand) and pin the host anchor to `t`, so the new rate applies ONLY GOING FORWARD →
        // now() is continuous across the step by construction, and the rate delta affects only future slope.
        // Gated to ACTUAL changes so a settled rate doesn't churn the anchor every 10Hz tick; the
        // forceUnityRate path returns above (L249) and so never reaches here — pinning can't churn either.
        // now() thereby becomes an anchor writer alongside registerFrame — both serialize on `lock`, so this
        // is safe. The anchor pair is non-nil here (guard above) and is only ever set/cleared atomically as a
        // pair under this lock, so the force-unwraps cannot trap.
        if newRate != rate {
            let mappedNow = anchorSenderPTS! + (t - anchorHostTime!) * rate   // old now() evaluated at t
            anchorSenderPTS = mappedNow
            anchorHostTime  = t
            rate            = newRate
        }

        logIfDue(t)
    }

    /// DEBUG-only ~1 Hz telemetry: watch `depth` settle to `target` and `rate` settle to the
    /// sender's true ratio under injected drift. Called under `lock`; the write is tiny and once/sec.
    private func logIfDue(_ t: Double) {
        #if DEBUG
        if let last = lastLogHost, t - last < 1.0 { return }
        lastLogHost = t
        let d = smoothedDepth ?? .nan
        FileHandle.standardError.write(Data(String(
            format: "[LIVECLOCK] depth=%.3fs target=%.3f rate=%.4f err=%+.4f count=%d\n",
            d, targetDepth, rate, d - targetDepth, lastCount).utf8))
        #endif
    }

    /// Clear the anchor so the next `registerFrame` re-anchors — for a new stream, a reconnect,
    /// or (in the synthetic harness) a loop back to the file's head. Also RE-ARMS the control loop.
    /// Safe to call from any thread.
    public func reset() {
        lock.lock()
        anchorSenderPTS = nil
        anchorHostTime = nil
        // Re-arm the control loop cleanly for the next stream/loop: forget the smoothed depth and
        // cadence gates, and return the rate to unity so a fresh anchor starts from wall-clock speed.
        smoothedDepth = nil
        lastControlHost = nil
        lastLogHost = nil
        lastCount = 0
        rate = 1.0
        lock.unlock()
    }

    /// The app's established monotonic host clock — the same one NDI stamps frames with
    /// (`CACurrentMediaTime()`). Read under `lock` by both `registerFrame` and `now`.
    private func hostNow() -> Double {
        CACurrentMediaTime()
    }
}
