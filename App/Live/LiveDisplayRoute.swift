//
//  LiveDisplayRoute.swift
//  Manifold
//
//  The renderer plumbing every LiveClock-paced PUSH source needs, in one place.
//
//  ── WHAT THIS IS ───────────────────────────────────────────────────────────────────────
//
//  A live push source takes the display by doing the same eleven things in the same order:
//  retire whoever is driving it, build a LiveClock, SAVE the renderer's existing providers,
//  install its own, wire the clock's four seams, size the queue, flush, and state the
//  colorimetry. Releasing it restores the saved providers verbatim. None of that is specific
//  to a transport — it was written for WHEP and it is what SRT needs too, so it lives here
//  rather than being cloned.
//
//  ── WHAT THIS IS DELIBERATELY NOT ──────────────────────────────────────────────────────
//
//  NOT an abstraction over NDI. NDI is a PULL source: it sets `renderer.onDisplayTick`, reads
//  a free-running monotonic clock, and has no LiveClock and no depth loop at all. Nothing
//  here applies to it, and generalising over "who owns the clock" would be the hard,
//  low-payoff part. This type is the PUSH axis only. See LiveSource for the arbitration axis,
//  which DOES span both.
//
//  NOT the owner of the per-frame state. `activate` RETURNS the LiveClock; it does not hold
//  it. That is deliberate and load-bearing: WHEPFrameRouter guards its `liveClock` with
//  `stateLock` and reads it under that lock on every delivered frame, with a documented
//  lock-ordering discipline. Holding the clock here would put a second lock on the per-frame
//  path and change threading in the hottest, most carefully reasoned code in that file. So
//  this type does activation and teardown; the caller keeps the clock exactly as it did.
//
//  ── TELEMETRY: HOOKS, NOT POLICY ───────────────────────────────────────────────────────
//
//  The two renderer callbacks this installs must call into the clock (`updateDepth`,
//  `overflowReanchor`) AND into whatever measurement the owner keeps. Rather than move the
//  owner's telemetry here — which would drag the drift accountant, the surplus ledger and the
//  underrun detector into shared code they have no business in — the installed closures do the
//  clock call and forward the result. The owner supplies the rest. One extra closure call per
//  display tick; no lock, no allocation, no change to what is measured or when.
//
//  ── THREADING ──────────────────────────────────────────────────────────────────────────
//
//  MAIN THREAD ONLY, both methods, asserted. `savedClock` / `savedIsPaused` are touched
//  nowhere else. The closures this INSTALLS run on other threads (onDepthSample on the
//  CVDisplayLink render thread, onQueueOverflow on the source's own thread) — they touch none
//  of this type's state, only the captured clock and the owner's hook.
//

import Foundation
import ManifoldCore   // LiveClock

final class LiveDisplayRoute {

    // MARK: - Colorimetry

    /// What the source says its pictures are, as CICP codes — the renderer half of colorimetry
    /// (shader matrix + layer colorspace), distinct from the per-buffer attachments a source
    /// stamps on its own pixel buffers.
    ///
    /// A SOURCE PROPERTY, NOT A CONSTANT, on purpose. WHEP must assume 709 SDR because H.264
    /// signals colorimetry in the SPS VUI and its RTP depacketizer does not parse it. That is a
    /// limitation of THAT transport and it must not be baked in here: an SRT source reaches
    /// libavformat, which fills `codecpar->color_primaries` / `color_trc` / `color_space` from
    /// the same VUI, so it can state the truth. Anything shared that hardcoded 709 would quietly
    /// downgrade it.
    struct Colorimetry {
        /// CICP codes; nil means "unspecified", which the renderer reads as its own default.
        var primaries: Int?
        var transfer: Int?
        var matrix: Int?
        /// Range is a SEPARATE axis from colorimetry — legal/video vs full swing.
        var isFullRange: Bool

        /// 709 SDR, video range. The honest default for a source that declares nothing, and the
        /// value WHEP passes because it cannot read what the stream actually declared.
        static let assumedRec709SDR = Colorimetry(primaries: 1, transfer: 1, matrix: 1,
                                                  isFullRange: false)
    }

    // MARK: - Config

    /// Everything that genuinely differs between one live push source and another.
    ///
    /// Every value here is a per-source measurement or a per-source fact. The REASONING for
    /// each belongs at the source's config site, next to the number it justifies — not on this
    /// type, which cannot know why any particular transport wanted a particular cushion.
    struct Config {
        /// Seconds of buffer the control loop holds, and the clock's startup offset.
        ///
        /// ONE FIELD SUPPLIES BOTH `startupDepth` AND `targetDepth`, so they cannot drift apart:
        /// the initial fill lands ON the setpoint instead of draining to it at ±maxSlew, which at
        /// 0.005/s would take ~40 s to close a 0.2 s gap. Both existing users (WHEP, and the
        /// synthetic harness at 0.15) already set them equal. If a source ever genuinely needs
        /// them split, that is a second field here, not a workaround at the call site.
        var targetDepth: Double

        /// The clock's rate rail, ±this. A ppm-scale trim for crystal drift — NOT the instrument
        /// for a connect backlog, which is what the snap and the queue-full re-anchor are for.
        var maxSlew: Double

        /// Snap-to-live: jump the clock when the buffer sits GROSSLY above target for a sustained
        /// interval. Off in LiveClock by default; a transport opts in.
        var snapEnabled: Bool
        /// How far ABOVE target counts as a gross overfill (so the snap fires above
        /// `targetDepth + snapThreshold`).
        var snapThreshold: Double
        /// How long that overfill must be sustained before jumping — a missed snap costs latency,
        /// a false snap costs a visible jump, and the second is the worse failure.
        var snapDebounce: Double

        /// Renderer queue bound while this source owns the display. Needs headroom above the
        /// shallow file-path default so the control loop can correct a filling buffer before
        /// drop-oldest fires.
        var maxQueued: Int

        /// What the source's pictures are. See `Colorimetry`.
        var colorimetry: Colorimetry
    }

    // MARK: - Saved renderer state (main thread only)

    /// Renderer providers saved at activate, restored VERBATIM at deactivate — the discipline the
    /// synthetic harness uses rather than NDI's (NDI leaves its clock installed on disconnect).
    /// We restore because a file may be sitting behind us and can resume the moment the live
    /// source goes away.
    private var savedClock: (() -> Double)?
    private var savedIsPaused: (() -> Bool)?

    // MARK: - Activate

    /// Take the display. Returns the configured LiveClock for the caller to own — see the
    /// "NOT the owner of the per-frame state" note in the header.
    ///
    /// `retireCurrentSource` runs FIRST, before anything is repointed, so the outgoing source's
    /// frame pump and this one's push never both feed the renderer. Same signature and same role
    /// as SyntheticLiveSource.start's parameter of the same name.
    ///
    /// `onDepth` fires on the RENDER THREAD once per display tick, with the raw sample and
    /// whatever coarse clock event `updateDepth` returned (nil on an ordinary tick).
    /// `onOverflow` fires on the SOURCE's thread, only when the queue overflowed AND the clock
    /// chose to re-anchor.
    // Not @discardableResult on purpose: the caller MUST take ownership of the returned clock
    // (that is the whole point of it not living here), so dropping it is a bug worth a warning.
    func activate(renderer: MetalVideoRenderer,
                  config: Config,
                  retireCurrentSource: () -> Void,
                  onDepth: @escaping (MetalVideoRenderer.DepthSample, LiveClock.Event?) -> Void,
                  onOverflow: @escaping (LiveClock.Event) -> Void) -> LiveClock {
        dispatchPrecondition(condition: .onQueue(.main))

        // One active source: retire whatever is driving the renderer BEFORE we repoint it.
        retireCurrentSource()

        let clock = LiveClock(startupDepth: config.targetDepth, targetDepth: config.targetDepth)

        savedClock = renderer.clock
        savedIsPaused = renderer.isPausedProvider

        // The three live-path seams. now() is "never due" until the first frame anchors it, so
        // nothing renders until the source pushes. onDisplayTick is nil'd because this is a PUSH
        // source — a pull source (NDI) is the case that sets it, and leaving a previous source's
        // hook installed would have it pulling into our queue.
        renderer.clock = { [clock] in clock.now() }
        renderer.isPausedProvider = { false }
        renderer.onDisplayTick = nil

        clock.snapEnabled = config.snapEnabled
        clock.snapThreshold = config.snapThreshold
        clock.snapDebounce = config.snapDebounce
        clock.maxSlew = config.maxSlew

        // Forwards the FULL sample — including the queue edges and the eligibility flag — which is
        // what ARMS LiveClock's freeze guard. Captures the clock and the hook, never `self`: this
        // object must not be kept alive by a renderer callback.
        renderer.onDepthSample = { [clock, onDepth] sample in
            let event = clock.updateDepth(spanSeconds: sample.spanSeconds,
                                          count: sample.count,
                                          oldestPTS: sample.oldestPTS,
                                          newestPTS: sample.newestPTS,
                                          presented: sample.hadEligibleFrame)
            onDepth(sample, event)
        }

        // QUEUE-FULL → CLOCK RE-ANCHOR. Runs on the SOURCE thread (renderer.enqueue's caller),
        // after the renderer's queue lock is released. Dropping the oldest frame removes no
        // latency; moving the clock does. No debounce: during a backlog drain this fires
        // repeatedly and that IS the drain working.
        renderer.onQueueOverflow = { [clock, onOverflow] newestPTS, count in
            if let event = clock.overflowReanchor(newestPTS: newestPTS, count: count) {
                onOverflow(event)
            }
        }

        renderer.maxQueuedOverride = config.maxQueued
        renderer.flush()   // drop any file frames still queued behind us

        let color = config.colorimetry
        renderer.setSourceColorSpace(primaries: color.primaries,
                                     transfer: color.transfer,
                                     matrix: color.matrix)
        renderer.isFullRangeProvider = { [isFullRange = color.isFullRange] in isFullRange }

        return clock
    }

    // MARK: - Deactivate

    /// Release the display, restoring the file-path providers verbatim so playback can resume,
    /// and wiping the last streamed frame (there is usually nothing behind us).
    ///
    /// `onDisplayTick` is deliberately NOT touched here: a push source set it to nil on the way
    /// in and has nothing to restore. Callers must be idempotent-safe — this is written to be
    /// harmless if called twice, and the caller's own "was I active" check is what gates it.
    func deactivate(renderer: MetalVideoRenderer?) {
        dispatchPrecondition(condition: .onQueue(.main))

        if let renderer {
            renderer.clock = savedClock
            renderer.isPausedProvider = savedIsPaused
            renderer.onDepthSample = nil
            renderer.onQueueOverflow = nil   // must not outlive the clock it re-anchors
            renderer.maxQueuedOverride = nil
            renderer.clearToBlack()
        }
        savedClock = nil
        savedIsPaused = nil
    }
}
