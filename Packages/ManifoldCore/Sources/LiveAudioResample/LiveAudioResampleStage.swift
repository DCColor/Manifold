//
//  LiveAudioResampleStage.swift
//  LiveAudioResample
//
//  The ASRC at the live-audio seam: `CMSampleBuffer` in, `CMSampleBuffer`s out, on a new contiguous
//  output axis. Build step 3 of docs/AUDIO_RESAMPLER_DESIGN.md §7 — in the path, RATIO PINNED AT
//  EXACTLY 1.0, loop open. Nothing here steers anything yet.
//
//  ── WHERE IT SITS ─────────────────────────────────────────────────────────────────────────────
//
//  `FrameEngine.LiveAudioSink.enqueue`, AFTER `tap.ingest` and BEFORE `renderer.enqueue` (§1.2).
//  The tap — and through it the meters and DeckLink — keeps the ORIGINAL samples on the ORIGINAL
//  axis; only the renderer sees this stage's output (§4.2, §4.3). One instance per live-audio
//  session: constructed by `beginLiveAudio`, retired by `endLiveAudio` (§4.4, §4.6). File playback
//  and HLS never construct a `LiveAudioSink`, so they cannot reach this by construction (§1.3,
//  §1.4) — do not add an `if isLive` anywhere to get that property; it is already structural.
//
//  ── THE OUTPUT AXIS (§4.1) ────────────────────────────────────────────────────────────────────
//
//      outTicks = outAnchor + cumulative output frames      integer add, CMTimeScale(sampleRate)
//
//  Frames are counted, never derived from the phase accumulator or from a Double — the same
//  discipline as `SRTFrameRouter.audioPTSTicks` and `NDIService.audioPTSTicks`, and for the same
//  §9 reason: consecutive buffers abut BY CONSTRUCTION because the PTS *is* the running count.
//
//  ⚠️ AT RATIO 1.0 OUTPUT TICK k CARRIES INPUT SAMPLE k, EXACTLY, AND EVERY RULE BELOW EXISTS TO
//  KEEP THAT TRUE. The resampler's group delay is exactly `latencyFrames` (32) input frames
//  (§9.1 #1). If the axis were anchored at the first input tick, every sample would reach the
//  renderer 32 frames (0.67 ms at 48 kHz) LATE against its own PTS — a constant A/V offset of
//  exactly the kind §2.5 forbids, too small to hear and therefore the kind that never gets found.
//  So:
//
//    * SESSION START — anchor at `firstInputTicks − latencyFrames`. The resampler's primed zeros
//      occupy those 32 ticks as leading silence, and input sample k then lands on tick k.
//    * FORMAT RESET / AXIS BREAK — DRAIN the old resampler (feed it `latencyFrames` zeros, which
//      emits the real tail it was still holding, at its correct ticks, in the OLD format), then
//      anchor the new one at the new input tick and DISCARD its primer. The old output therefore
//      ends exactly where the old input ended and the new output begins exactly where the new
//      input begins — so the output is contiguous across a format change whenever the input is,
//      including across a RATE change, where the two sides are on different timescales and only
//      the seconds can agree.
//    * TEARDOWN — the held tail (32 frames) is discarded with the renderer flush that
//      `endLiveAudio` performs anyway. A new session anchors at its own `first − latencyFrames`,
//      so if the input axis carried straight on across the reconnect, the new output begins
//      exactly where the old output stopped.
//
//  ── INPUT DISCONTINUITIES — TIMING PRESERVED, AXIS KEPT CONTIGUOUS ──────────────────────────
//
//  The input axis is not always contiguous: WHEP stamps absolute RTP time, so a lost Opus packet
//  is a 960-frame hole; SRT and NDI re-pin their sample axes at a 25 ms tolerance. Before this
//  stage, the renderer saw those as a PTS gap (played as silence) or a PTS overlap.
//
//  ⚠️ A FREE-RUNNING OUTPUT AXIS WOULD CLOSE THE HOLE, AND AT STEP 3 NOTHING WOULD REOPEN IT. §4.1
//  item 2 hands input re-pins to §2.4's splice branch — which is step 5. Until then the mirror's
//  position branch cannot see an axis divergence either: its `predicted` is open-loop, computed
//  from what it last pushed, never from what the renderer was given. A closed-up 20 ms hole would
//  be a permanent, uncorrected 20 ms of audio-ahead-of-picture, one more per lost packet.
//
//  So the stage keeps the time-to-sample relationship the renderer had before:
//
//    * a FORWARD step (hole) of up to `maximumBridgeSeconds` is filled with SILENCE fed through
//      the resampler — exactly what the renderer played for a PTS gap, now on a contiguous axis;
//    * a BACKWARD step (overlap) of up to the same bound DROPS the overlapping input frames;
//    * anything larger is an AXIS BREAK: drain, re-anchor at the new input tick, and let the
//      output step exactly as the input did. That is the pre-existing behaviour for a jump too
//      large to be a packet, and it is logged.
//
//  Every fill, drop and break is COUNTED and reported.
//
//  ⚠️ STEP 5 LEFT THESE AS THEY ARE, ON PURPOSE. This note used to say step 5 would replace the
//  fill/drop with the cross-faded splice. It does not, because the stage cannot tell a lost packet
//  from a re-pin — both are the same input-axis step — and they need different things: a lost WHEP
//  packet is MISSING content (criterion 5 counts it as a hole), a re-pin is relabelled content.
//  Either way the timing is kept here, so neither steps the content-time error and neither reaches
//  the coarse branch. Cross-fading these edges is a separate change with its own measurement.
//
//  ── THE SPLICE (§2.4, step 5) ─────────────────────────────────────────────────────────────────
//
//  The coarse branch's action. `requestSplice` queues a jump of the input read head — forward
//  (drop) or back (insert, repeated material) — across a 10 ms equal-power fade; `LiveAudioSplicer`
//  does it, in front of the resampler. The output axis never notices: it counts output frames, and a
//  splice changes only WHICH content those frames carry. So there is no timebase write, ever.
//
//  The content-time map follows: a block whose fed span crosses a splice is recorded as two
//  breakpoints, the second offset by the splice. `inputTime(atOutputTime:)` therefore reports the
//  splice when it is HEARD, a renderer-queue later than it was requested, and
//  `spliceCorrectionAhead(ofOutputTime:)` is what the loop adds for the part not heard yet.
//
//  ── WHAT IT NEVER DOES ────────────────────────────────────────────────────────────────────────
//
//  It never touches the synchronizer, the timebase or any rate. A format change is a STATE RESET
//  (§4.1 item 3) — new filter history, new phase, new output anchor — never a rate write. It keys
//  on sample rate and channel COUNT only; a roles-only relabel (a late channel-layout declaration)
//  is not a format change here, exactly as it is not one for `AudioTapBuffer.onFormatChange`
//  (§4.4), and the relabel reaches the renderer because each output buffer carries its INPUT
//  buffer's format description.
//

import AudioResample
import CoreMedia
import Accelerate
import Foundation
import os

public final class LiveAudioResampleStage: @unchecked Sendable {

    // MARK: - Configuration

    /// The ratio every session's resampler is BUILT at. From step 4d the controller moves it per
    /// block through `rho` below, which is `internal`: nothing outside this module can set one.
    public static let ratio = 1.0

    /// The largest input-axis step bridged by silence-fill or drop rather than treated as an axis
    /// break. One second: ~50 lost Opus packets in a row, 40× the 25 ms re-pin tolerance. Past
    /// that the input did not lose a packet, it jumped, and re-anchoring is the honest response.
    public static let maximumBridgeSeconds = 1.0

    /// One coefficient table for every session and every reset in the process. 256 KB + 256 KB,
    /// built once, read-only afterwards (§9.3). Building it on the transport thread at a format
    /// change would be a multi-millisecond stall on the audio path for no reason: the table is a
    /// function of normalised frequency only and does not depend on the sample rate.
    public static let sharedPrototype = PolyphasePrototype()

    /// The splice's equal-power fade (§2.4 says 5–10 ms). 10 ms, the long end:
    ///   * a shorter fade is a steeper edge, so more of the splice is heard as a transient; a hard
    ///     cut is the limit, and 10 ms halves the edge slope of 5 ms;
    ///   * what the longer fade costs is small here — two positions overlapping for 10 ms, still
    ///     under the ~20 ms where an overlap starts to read as a doubled onset, and 10 ms of waiting
    ///     for the fade-out's material before an insert, against a renderer queue of 250–420 ms.
    /// Time, not frames: 480 at 48 kHz, 441 at 44.1 kHz.
    public static let crossfadeSeconds = 0.010

    /// The largest splice, either direction; past it the coarse branch re-anchors instead. The same
    /// second as `maximumBridgeSeconds`, for the same reason: a jump past it is not one the material
    /// should hide. An insert that size replays a whole second — a sentence heard twice — and it
    /// sizes the history ring (1 s + fade + one 4096-frame chunk: 3.4 MB at 48 kHz × 16).
    public static let maximumSpliceSeconds = 1.0

    // MARK: - Stats

    /// Counters for one reporting window, or cumulative since construction.
    public struct Stats: Sendable, Equatable {
        public var inputBuffers = 0
        public var outputBuffers = 0
        public var outputFrames: Int64 = 0
        /// Input holes filled with silence, and the frames of silence fed.
        public var fills = 0
        public var fillFrames: Int64 = 0
        /// Input overlaps, and the input frames dropped for them.
        public var drops = 0
        public var dropFrames: Int64 = 0
        /// Rate or channel-count changes — each a state reset, never a rate write.
        public var formatResets = 0
        /// Input-axis steps larger than `maximumBridgeSeconds`, re-anchored.
        public var axisBreaks = 0
        /// Output samples that exceeded full scale and were clamped (§4.3: must be counted, must
        /// not be silent). ⚠️ AT RATIO 1.0 THIS MUST BE ZERO — the output is the input, delayed —
        /// so a non-zero count at step 3 is a plumbing defect, not a property of the material.
        public var clamps = 0
        /// Buffers handed through untouched because their format is not one this stage converts.
        public var passthroughs = 0
        /// Output buffers that could not be built, so their audio was lost.
        public var buildFailures = 0
        /// Blocks resampled at a ratio other than exactly 1.0. A clamp in a window where this is 0
        /// is still a plumbing defect; with the ratio moving it can be real intersample overshoot.
        public var offUnityBlocks = 0
        /// Splices executed (step 5), and the content frames each direction moved by.
        public var spliceDrops = 0
        public var spliceDropFrames: Int64 = 0
        public var spliceInserts = 0
        public var spliceInsertFrames: Int64 = 0
        /// Splices requested and never executed — a format reset, axis break, passthrough or retire
        /// arrived first, or the history no longer held the material.
        public var splicesAbandoned = 0
        public init() {}

        /// Anything that is not the nominal path. A window with any of these is always reported.
        var isEventful: Bool {
            fills > 0 || drops > 0 || formatResets > 0 || axisBreaks > 0 || clamps > 0
                || passthroughs > 0 || buildFailures > 0
                || spliceDrops > 0 || spliceInserts > 0 || splicesAbandoned > 0
        }
    }

    // MARK: - State (all guarded by `lock`)

    private let tag: String
    private let reportsWindows: Bool
    private let log: (@Sendable (String) -> Void)?
    private let lock = UnfairLockBox()

    private struct Session {
        let sampleRate: Double
        let timescale: CMTimeScale
        let channels: Int
        let resampler: PolyphaseResampler
        /// Input tick of the resampler's input frame 0. Every frame fed afterwards is at
        /// `inputOrigin + (frames fed so far)`, because fills feed the hole's ticks and drops skip
        /// ticks already fed. That is what lets the content-time map name an INPUT tick.
        let inputOrigin: Int64
        /// Output tick of this session's first emitted frame.
        let outAnchor: Int64
        /// Primer frames discarded at construction: 0 at session start, `latencyFrames` after a
        /// reset. Emitted frame e is resampler output frame `e + initialPrimer`.
        let initialPrimer: Int
        /// Output frames emitted since `outAnchor`.
        var emitted: Int64 = 0
        /// Input tick the next buffer should start at if the input axis is contiguous.
        var nextInputTicks: Int64
        /// Primer frames still to discard. `latencyFrames` after a reset, 0 at session start.
        var primerToDiscard: Int
        /// The latest input format description. Output carries it, so a roles-only relabel reaches
        /// the renderer; a drain goes out in the one the drained audio arrived with.
        var formatDescription: CMFormatDescription
        /// Step 5. Every frame the resampler is fed comes through it; the fed index it counts is the
        /// resampler's input frame index.
        let splicer: LiveAudioSplicer
        /// Splices executed but not yet crossed by an emitted block, in fed order.
        var marks: [LiveAudioSplicer.Mark] = []
        /// Content offset (input frames) of everything fed past the marks already crossed: fed frame
        /// j is input tick `inputOrigin + j + mapBase` once j is past them.
        var mapBase: Int64 = 0
    }

    private var session: Session?
    private var retired = false
    private var passthroughLogged = false

    // MARK: - Content time (§2.1, step 4a)
    //
    // ⚠️ ONCE THE RATIO MOVES, `synchronizer.currentTime()` IS NO LONGER THE CONTENT BEING HEARD.
    // The timebase counts OUTPUT seconds on the device clock, and under a working loop it is meant
    // to drift from the target by exactly the ppm the loop absorbs. The quantity to null is the
    // input-axis time of the sample being heard, and only this stage knows the relationship.
    //
    // It is kept as one BREAKPOINT per resampled block: the ratio is constant within a block, so
    // (first output tick, input position of that tick, increment) is the whole map across it,
    // exactly — not an approximation of it. The input position is held as an OFFSET from the
    // output tick in Q32.32, which is an exact integer zero at ratio 1.0. That makes
    // `inputTime(atOutputTime:)` return its argument bit for bit at 1.0, so step 3's PAIRED
    // figures carry over unchanged (step 4a's first regression test).

    /// ρ — input seconds consumed per output second (§2.2). The resampler's increment IS ρ in
    /// Q32.32, so it is written directly rather than through `ratio`'s 1/x. Applied to every
    /// block from the next `process` on; a block never changes ratio part-way.
    ///
    /// ⚠️ INTERNAL. The only writer in the app is `LiveAudioResampleSteering` (step 4d), in this
    /// module, so ManifoldCore cannot move the ratio except through the control law.
    var rho: Double {
        get { lock.lock(); defer { lock.unlock() }; return Double(rhoIncrement) / 4294967296.0 }
        set {
            precondition(newValue.isFinite && newValue > 0.5 && newValue < 2.0, "ρ out of range")
            lock.lock(); rhoIncrement = UInt64((newValue * 4294967296.0).rounded()); lock.unlock()
        }
    }
    private var rhoIncrement: UInt64 = 1 << 32

    private struct Breakpoint {
        /// Output tick of the block's first frame, on `sampleRate`'s timescale.
        var outTick: Int64 = 0
        var frames: Int64 = 0
        var sampleRate: Double = 1
        /// (input position − output tick) at `outTick`, input frames in Q32.32. 0 at ratio 1.0.
        var offsetQ: Int64 = 0
        /// Input frames per output frame, Q32.32 — ρ exactly as the resampler applied it.
        var increment: UInt64 = 1 << 32
    }

    /// History the lookup needs is the renderer's queue: at most ~0.5 s ahead of what is heard,
    /// at up to 100 blocks/s. 512 blocks is ≥ 5 s. Preallocated, so recording never allocates.
    private static let breakpointCapacity = 512
    private var breakpoints = [Breakpoint](repeating: Breakpoint(), count: breakpointCapacity)
    private var breakpointHead = 0     // next slot to write
    private var breakpointCount = 0

    /// Step 1's warp fixture, reached through the stage: when set, each new session's resampler
    /// records the absolute phase of every output frame. Tests only; it allocates per frame.
    var capturesPhaseForTesting = false

    // MARK: - Splices (step 5)

    /// What a splice request was granted: signed content frames (+ = drop, content forward) at the
    /// session's rate.
    public struct SpliceGrant: Sendable, Equatable {
        public let id: Int
        public let frames: Int64
        public let sampleRate: Double
        public let crossfadeFrames: Int
        public var seconds: Double { Double(frames) / sampleRate }
    }

    /// One requested splice until it has certainly been heard. `outTick` is set when the emitted
    /// block containing its mark is recorded; until then it is pending in full.
    private struct SpliceRecord {
        let id: Int
        let frames: Int64
        let sampleRate: Double
        var outTick: Int64?
    }
    private var spliceRecords: [SpliceRecord] = []
    private var nextSpliceID = 1
    /// Set by `processLocked` when this call hit an axis break: its size, ms. Read after unlock.
    private var breakThisCall: Double?

    /// Told about every input axis BREAK, after the lock is released — the way an input re-pin past
    /// the bridge reaches the content-time error, so the splice it causes can be matched to it. Set
    /// once, before the first `process`.
    public var onAxisBreak: (@Sendable (_ milliseconds: Double) -> Void)?

    private var window = Stats()
    private var total = Stats()
    private var windowStartNanos: UInt64 = 0
    private static let windowNanos: UInt64 = 10_000_000_000
    /// Per-event lines are capped per window so a lossy WHEP link cannot turn this into a log
    /// flood. The counts in the window line are never capped.
    private var eventLinesThisWindow = 0
    private static let eventLinesPerWindow = 5

    /// An event, captured as scalars under the lock and formatted off it.
    private enum Line: Sendable {
        case step(hole: Bool, ms: Double, inTicks: Int64)
        case axisBreak(ms: Double, inTicks: Int64)
        case formatReset(fromRate: Double, fromChannels: Int, toRate: Double, toChannels: Int,
                         contiguous: Bool)
        case passthrough(String)
        case spliceAbandoned(id: Int, ms: Double, reason: String)

        func render(_ tag: String) -> String {
            switch self {
            case let .spliceAbandoned(id, ms, reason):
                return String(format: "%@ SPLICE #%d ABANDONED (%+.1f ms of content) — %@. Its "
                              + "correction was not applied; the loop sees the error again and the "
                              + "coarse branch decides afresh.", tag, id, ms, reason)
            case let .step(hole, ms, inTicks):
                return String(format: "%@ input axis %@ %.2f ms at in-tick %lld — %@; output axis "
                              + "contiguous, every sample kept at its original time",
                              tag, hole ? "HOLE" : "OVERLAP", ms, inTicks,
                              hole ? "filled with silence" : "overlapping frames dropped")
            case let .axisBreak(ms, inTicks):
                return String(format: "%@ input axis BREAK %+.1f ms at in-tick %lld (bridge limit "
                              + "%.0f ms) — drained and RE-ANCHORED; the output axis steps with the "
                              + "input. State reset, no rate write.",
                              tag, ms, inTicks, LiveAudioResampleStage.maximumBridgeSeconds * 1000)
            case let .formatReset(fr, fc, tr, tc, contiguous):
                return String(format: "%@ FORMAT RESET %.0f Hz × %d → %.0f Hz × %d — resampler state "
                              + "reset, output axis re-anchored at the new input (%@). No rate write.",
                              tag, fr, fc, tr, tc,
                              contiguous ? "contiguous with the old one"
                                         : "input axis was NOT contiguous across the change")
            case let .passthrough(reason):
                return "\(tag) PASSTHROUGH — \(reason). Buffer handed to the renderer unresampled, "
                    + "exactly as before this stage existed. Logged once per session; counted in "
                    + "every window."
            }
        }
    }

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - tag: log prefix, e.g. `[SRT-RESAMPLE]`.
    ///   - reportsWindows: emit a line every 10 s even when nothing unusual happened (telemetry
    ///     builds). When false, a window line is still emitted if the window saw a fill, drop,
    ///     reset, break, clamp, passthrough or build failure — the events are never silent.
    ///   - log: where lines go. Always invoked on a utility queue, never on the enqueue thread.
    public init(tag: String, reportsWindows: Bool, log: (@Sendable (String) -> Void)?) {
        self.tag = tag
        self.reportsWindows = reportsWindows
        self.log = log
    }

    /// End of session (`endLiveAudio`, or a `beginLiveAudio` that supersedes this one). The
    /// resampler is destroyed here, and any later `process` call — a pump still draining after the
    /// session closed — returns nothing, so it cannot feed a renderer that has been flushed.
    ///
    /// Waits for an in-flight `process` to finish (the lock is held across it): once this returns,
    /// this stage will never emit again.
    public func retire() {
        lock.lock()
        let wasRetired = retired
        retired = true
        var abandoned: [Line] = []
        if let s = session {
            var discard = [[Float]](repeating: [], count: s.channels)
            abandoned = settleLocked(s.splicer.abandonAll(reason: "session ended", into: &discard),
                                     rate: s.sampleRate)
        }
        session = nil
        spliceRecords = []
        let w = window, t = total
        let r = Double(rhoIncrement) / 4294967296.0
        let suppressed = max(0, eventLinesThisWindow - Self.eventLinesPerWindow)
        window = Stats()
        lock.unlock()
        guard !wasRetired else { return }
        let tag = self.tag
        for l in abandoned { emit { l.render(tag) } }
        emit { Self.windowLine(tag, w, total: t, rho: r, final: true, suppressed: suppressed) }
    }

    /// Cumulative counters since construction.
    public var totals: Stats {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    /// The input-axis time, in seconds, of the content at output time `outputSeconds` — §2.1's
    /// `actual`. Pass `CMTimeGetSeconds(synchronizer.currentTime())`.
    ///
    /// Picks the block whose output span contains the instant; failing that (the timebase is ahead
    /// of everything enqueued, or behind the oldest block kept), the newest block starting at or
    /// before it, else the oldest, extrapolated at that block's ratio. With no block yet — or after
    /// a passthrough, whose buffers are not resampled — it is the identity, which is the
    /// pre-existing behaviour.
    ///
    /// Takes this stage's lock, which only `process` and `retire` also take. Call it AFTER a paired
    /// read, never between the two host reads.
    public func inputTime(atOutputTime outputSeconds: Double) -> Double {
        guard outputSeconds.isFinite else { return outputSeconds }
        lock.lock(); defer { lock.unlock() }
        guard breakpointCount > 0 else { return outputSeconds }
        let cap = Self.breakpointCapacity
        var chosen = -1, fallback = -1
        for k in 0..<breakpointCount {
            let idx = (breakpointHead - 1 - k + cap) % cap
            let b = breakpoints[idx]
            let x = outputSeconds * b.sampleRate - Double(b.outTick)
            if x >= 0 {
                if x < Double(b.frames) { chosen = idx; break }
                if fallback < 0 { fallback = idx }
            }
        }
        if chosen < 0 { chosen = fallback >= 0 ? fallback
                                               : (breakpointHead - breakpointCount + cap) % cap }
        let b = breakpoints[chosen]
        // inputSeconds = outputSeconds + (offset + x·(ρ − 1)) / rate. Both terms are exact zeros at
        // ratio 1.0, so the result is the argument bit for bit — not merely within rounding.
        let x = outputSeconds * b.sampleRate - Double(b.outTick)
        let rhoMinusOne = Double(Int64(bitPattern: b.increment &- (1 << 32))) / 4294967296.0
        let offsetFrames = Double(b.offsetQ) / 4294967296.0 + x * rhoMinusOne
        return outputSeconds + offsetFrames / b.sampleRate
    }

    /// The output time at which the content at input-axis time `inputSeconds` is heard — the
    /// inverse of `inputTime(atOutputTime:)`, over the same breakpoints, with the same selection
    /// rule and the same identity when there is no block. Step 4d's coarse branch uses it to place
    /// the timebase so that the content heard is the target (§2.4).
    ///
    /// Within a block, input·rate = outTick + offset + x·ρ, so x = (input·rate − outTick − offset)/ρ.
    public func outputTime(atInputTime inputSeconds: Double) -> Double {
        guard inputSeconds.isFinite else { return inputSeconds }
        lock.lock(); defer { lock.unlock() }
        guard breakpointCount > 0 else { return inputSeconds }
        let cap = Self.breakpointCapacity
        func x(_ b: Breakpoint) -> Double {
            let rho = Double(b.increment) / 4294967296.0
            return (inputSeconds * b.sampleRate - Double(b.outTick)
                    - Double(b.offsetQ) / 4294967296.0) / rho
        }
        var chosen = -1, fallback = -1
        for k in 0..<breakpointCount {
            let idx = (breakpointHead - 1 - k + cap) % cap
            let xb = x(breakpoints[idx])
            if xb >= 0 {
                if xb < Double(breakpoints[idx].frames) { chosen = idx; break }
                if fallback < 0 { fallback = idx }
            }
        }
        if chosen < 0 { chosen = fallback >= 0 ? fallback
                                               : (breakpointHead - breakpointCount + cap) % cap }
        let b = breakpoints[chosen]
        // At ratio 1.0 the offset is an exact zero and ρ exactly 1, so this is the argument back.
        if b.offsetQ == 0 && b.increment == 1 << 32 { return inputSeconds }
        return (Double(b.outTick) + x(b)) / b.sampleRate
    }

    /// Queue a splice that moves the content by `contentSeconds` (+ = forward, a drop; − = back,
    /// an insert of repeated material). It is executed at the input read position as soon as the
    /// material for its fade has arrived — immediately, or ~`contentSeconds` later for a drop.
    ///
    /// nil when there is nothing to splice (no session, a passthrough, a retired stage), when it
    /// rounds to zero frames, or when it is larger than `maximumSpliceSeconds`. The caller then
    /// keeps its pre-existing action.
    public func requestSplice(contentSeconds: Double) -> SpliceGrant? {
        guard contentSeconds.isFinite,
              abs(contentSeconds) <= Self.maximumSpliceSeconds else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !retired, let s = session else { return nil }
        let frames = Int64((contentSeconds * s.sampleRate).rounded())
        guard frames != 0 else { return nil }
        let id = nextSpliceID
        nextSpliceID += 1
        s.splicer.enqueue(id: id, delta: frames)
        spliceRecords.append(SpliceRecord(id: id, frames: frames, sampleRate: s.sampleRate))
        return SpliceGrant(id: id, frames: frames, sampleRate: s.sampleRate,
                           crossfadeFrames: s.splicer.crossfade)
    }

    /// Seconds of content correction requested but not yet heard at output time `outputSeconds`:
    /// splices still queued or waiting for material, and executed ones whose mark lies after it.
    /// `inputTime(atOutputTime:)` + this is the content the listener WILL be hearing once the
    /// renderer's queue plays out — continuous across the moment a splice is heard, because the
    /// map and this switch at the same output tick.
    public func spliceCorrectionAhead(ofOutputTime outputSeconds: Double) -> Double {
        guard outputSeconds.isFinite else { return 0 }
        lock.lock(); defer { lock.unlock() }
        guard !spliceRecords.isEmpty else { return 0 }
        // Heard well in the past: nothing will read it again.
        spliceRecords.removeAll { r in
            r.outTick.map { Double($0) / r.sampleRate + 2.0 < outputSeconds } ?? false
        }
        var ahead = 0.0
        for r in spliceRecords {
            // The breakpoint lookup's own test (`x >= 0`), so the two switch on the same read.
            if let t = r.outTick, outputSeconds * r.sampleRate - Double(t) >= 0 { continue }
            ahead += Double(r.frames) / r.sampleRate
        }
        return ahead
    }

    /// The current session's phase trace and the constants that place it on the two axes: output
    /// tick `outAnchor + e` was reconstructed at absolute phase `trace[e + initialPrimer]`, which is
    /// input tick `inputOrigin + phase / 2^32 − 1 − latency`. Tests only.
    func phaseTraceForTesting() -> (trace: [UInt64], inputOrigin: Int64, outAnchor: Int64,
                                    initialPrimer: Int, latency: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let s = session else { return nil }
        return (s.resampler.phaseTrace, s.inputOrigin, s.outAnchor, s.initialPrimer,
                s.resampler.latencyFrames)
    }

    // MARK: - The seam

    /// Resample one input buffer. Returns the buffers to hand the renderer, in order: usually one,
    /// two at a format reset or axis break (the old session's drained tail, then the new session's
    /// first buffer), none when the whole buffer overlapped or the stage is retired.
    ///
    /// ⚠️ THE LOCK IS HELD ACROSS THE RESAMPLE, AND THAT IS DELIBERATE. The only other taker is
    /// `retire()`, on the main actor, once per session boundary; holding it here is what makes
    /// "destroyed in `endLiveAudio`" true rather than approximately true. The render thread never
    /// takes it. Events are captured as scalars under it and formatted on a utility queue.
    public func process(_ sampleBuffer: CMSampleBuffer) -> [CMSampleBuffer] {
        lock.lock()
        if retired { lock.unlock(); return [] }
        var lines: [Line] = []
        breakThisCall = nil
        let out = processLocked(sampleBuffer, lines: &lines)
        let breakMs = breakThisCall
        var windowReport: (Stats, Stats, Int, Double)?
        let now = DispatchTime.now().uptimeNanoseconds
        if windowStartNanos == 0 { windowStartNanos = now }
        if now &- windowStartNanos >= Self.windowNanos {
            if reportsWindows || window.isEventful {
                windowReport = (window, total, max(0, eventLinesThisWindow - Self.eventLinesPerWindow),
                                Double(rhoIncrement) / 4294967296.0)
            }
            window = Stats()
            eventLinesThisWindow = 0
            windowStartNanos = now
        }
        lock.unlock()
        let tag = self.tag
        for l in lines { emit { l.render(tag) } }
        if let r = windowReport {
            emit { Self.windowLine(tag, r.0, total: r.1, rho: r.3, final: false, suppressed: r.2) }
        }
        // Outside the lock: the observer takes the steering's.
        if let ms = breakMs { onAxisBreak?(ms) }
        return out
    }

    // MARK: - Internals

    private func processLocked(_ sb: CMSampleBuffer, lines: inout [Line]) -> [CMSampleBuffer] {
        bump { $0.inputBuffers += 1 }
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else {
            return passthrough(sb, reason: "no audio format description", lines: &lines)
        }
        let asbd = asbdPtr.pointee
        let flags = asbd.mFormatFlags
        let ch = Int(asbd.mChannelsPerFrame)
        let rate = asbd.mSampleRate
        // ⚠️ EXACTLY THE SHAPE ALL THREE PUSH TRANSPORTS BUILD — packed, interleaved, native-endian
        // signed Int32 — and nothing else. Anything else is handed through untouched and logged: a
        // format this stage does not understand must reach the renderer as it always did, not be
        // mis-read.
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              flags & kAudioFormatFlagIsFloat == 0,
              flags & kAudioFormatFlagIsSignedInteger != 0,
              flags & kAudioFormatFlagIsNonInterleaved == 0,
              flags & kAudioFormatFlagIsBigEndian == 0,
              ch > 0, asbd.mBitsPerChannel == 32,
              asbd.mBytesPerFrame == UInt32(4 * ch),
              rate > 0, rate == rate.rounded(), rate <= Double(Int32.max) else {
            let id = asbd.mFormatID, bits = asbd.mBitsPerChannel
            return passthrough(sb, reason: "unsupported format (id \(id) flags \(flags) bits "
                                           + "\(bits) ch \(ch) rate \(rate))",
                               lines: &lines)
        }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return [] }
        let timescale = CMTimeScale(rate)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid, pts.isNumeric else {
            return passthrough(sb, reason: "non-numeric PTS", lines: &lines)
        }
        let inTicks = CMTimeConvertScale(pts, timescale: timescale,
                                         method: .roundHalfAwayFromZero).value

        // Samples, as Int32 interleaved. `CopyDataBytes` handles a non-contiguous block buffer.
        let sampleCount = frames * ch
        var raw = [Int32](repeating: 0, count: sampleCount)
        guard let block = CMSampleBufferGetDataBuffer(sb),
              CMBlockBufferGetDataLength(block) >= sampleCount * 4,
              raw.withUnsafeMutableBytes({ dst in
                  CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: sampleCount * 4,
                                             destination: dst.baseAddress!)
              }) == kCMBlockBufferNoErr else {
            return passthrough(sb, reason: "unreadable sample data", lines: &lines)
        }

        var out: [CMSampleBuffer] = []
        var fill = 0
        var skip = 0

        if var s = session, s.sampleRate == rate, s.channels == ch {
            // Same shape. A roles-only relabel lands here and costs nothing — no reset, no splice:
            // the new description is simply carried onto the output from this buffer on.
            let delta = inTicks - s.nextInputTicks
            let bridge = Int64(Self.maximumBridgeSeconds * rate)
            if abs(delta) <= bridge {
                s.formatDescription = fd
                session = s
                if delta > 0 {
                    fill = Int(delta)
                    bump { $0.fills += 1; $0.fillFrames += delta }
                } else if delta < 0 {
                    skip = Int(-delta)
                    bump { $0.drops += 1; $0.dropFrames += Int64(min(skip, frames)) }
                }
                if delta != 0 {
                    note(.step(hole: delta > 0, ms: Double(abs(delta)) / rate * 1000,
                               inTicks: inTicks), into: &lines)
                }
                // Wholly behind the axis: nothing new in it, and the expected tick does not move.
                if skip >= frames { return [] }
            } else {
                // Too large to be a packet. Drain in the OLD description, re-anchor, and let the
                // output step exactly as the input did.
                bump { $0.axisBreaks += 1 }
                note(.axisBreak(ms: Double(delta) / rate * 1000, inTicks: inTicks), into: &lines)
                breakThisCall = Double(delta) / rate * 1000
                out.append(contentsOf: endSessionLocked(reason: "input axis break", lines: &lines))
                session = makeSession(rate: rate, timescale: timescale, channels: ch, fd: fd,
                                      firstInputTicks: inTicks, discardPrimer: true)
            }
        } else if let s = session {
            // Rate or channel COUNT changed: a state reset (§4.1 item 3), never a rate write.
            bump { $0.formatResets += 1 }
            let contiguous = CMTimeCompare(CMTime(value: s.nextInputTicks, timescale: s.timescale),
                                           CMTime(value: inTicks, timescale: timescale)) == 0
            note(.formatReset(fromRate: s.sampleRate, fromChannels: s.channels, toRate: rate,
                              toChannels: ch, contiguous: contiguous), into: &lines)
            out.append(contentsOf: endSessionLocked(reason: "format reset", lines: &lines))
            session = makeSession(rate: rate, timescale: timescale, channels: ch, fd: fd,
                                  firstInputTicks: inTicks, discardPrimer: true)
        } else {
            session = makeSession(rate: rate, timescale: timescale, channels: ch, fd: fd,
                                  firstInputTicks: inTicks, discardPrimer: false)
        }

        // Deinterleave to Float in [-1, 1), `fill` frames of silence first, `skip` frames dropped.
        let kept = frames - skip
        let fed = fill + kept
        var planar = [[Float]](repeating: [Float](repeating: 0, count: fed), count: ch)
        var scale = Float(1.0 / 2147483648.0)
        raw.withUnsafeBufferPointer { src in
            for c in 0..<ch {
                planar[c].withUnsafeMutableBufferPointer { dst in
                    vDSP_vflt32(src.baseAddress! + skip * ch + c, vDSP_Stride(ch),
                                dst.baseAddress! + fill, 1, vDSP_Length(kept))
                    vDSP_vsmul(dst.baseAddress! + fill, 1, &scale,
                               dst.baseAddress! + fill, 1, vDSP_Length(kept))
                }
            }
        }
        // Through the splicer (step 5): usually exactly `planar`; less while a drop waits for its
        // material, more when an insert replays.
        if let s = session {
            var toFeed = [[Float]](repeating: [], count: ch)
            for c in 0..<ch { toFeed[c].reserveCapacity(fed + s.splicer.crossfade) }
            let r = s.splicer.process(planar, count: fed, into: &toFeed)
            session?.marks.append(contentsOf: r.marks)
            lines += settleLocked(r.outcomes, rate: rate)
            if !toFeed[0].isEmpty, let built = runLocked(toFeed) { out.append(built) }
        }
        session?.nextInputTicks = inTicks + Int64(frames)
        return out
    }

    /// Count what became of splices, and drop the records of abandoned ones: their correction will
    /// never be heard, so it must stop being reported as ahead.
    private func settleLocked(_ outcomes: [LiveAudioSplicer.Outcome], rate: Double) -> [Line] {
        var lines: [Line] = []
        for o in outcomes {
            switch o {
            case let .executed(_, delta):
                if delta > 0 { bump { $0.spliceDrops += 1; $0.spliceDropFrames += delta } }
                else { bump { $0.spliceInserts += 1; $0.spliceInsertFrames += -delta } }
            case let .abandoned(id, delta, reason):
                bump { $0.splicesAbandoned += 1 }
                spliceRecords.removeAll { $0.id == id }
                lines.append(.spliceAbandoned(id: id, ms: Double(delta) / rate * 1000, reason: reason))
            }
        }
        return lines
    }

    /// The current session ends (format reset, axis break): pending splices are abandoned, the
    /// content they held back is fed, and the resampler's tail is drained. The caller replaces
    /// `session`.
    private func endSessionLocked(reason: String, lines: inout [Line]) -> [CMSampleBuffer] {
        guard let s = session else { return [] }
        var out: [CMSampleBuffer] = []
        if !s.splicer.isIdle {
            var held = [[Float]](repeating: [], count: s.channels)
            lines += settleLocked(s.splicer.abandonAll(reason: reason, into: &held),
                                  rate: s.sampleRate)
            if !held[0].isEmpty, let built = runLocked(held) { out.append(built) }
        }
        out.append(contentsOf: drainLocked())
        return out
    }

    private func makeSession(rate: Double, timescale: CMTimeScale, channels: Int,
                             fd: CMFormatDescription, firstInputTicks: Int64,
                             discardPrimer: Bool) -> Session {
        let r = PolyphaseResampler(channels: channels, ratio: Self.ratio,
                                   prototype: Self.sharedPrototype)
        r.capturesPhase = capturesPhaseForTesting
        let latency = r.latencyFrames
        let splicer = LiveAudioSplicer(
            channels: channels,
            crossfade: max(2, Int((Self.crossfadeSeconds * rate).rounded())),
            maximumSplice: Int((Self.maximumSpliceSeconds * rate).rounded(.up)))
        return Session(sampleRate: rate, timescale: timescale, channels: channels, resampler: r,
                       inputOrigin: firstInputTicks,
                       outAnchor: discardPrimer ? firstInputTicks
                                                : firstInputTicks - Int64(latency),
                       initialPrimer: discardPrimer ? latency : 0,
                       nextInputTicks: firstInputTicks,
                       primerToDiscard: discardPrimer ? latency : 0,
                       formatDescription: fd, splicer: splicer)
    }

    /// Feed `latencyFrames` of silence so the resampler emits the real tail it is holding, at its
    /// correct ticks, in the session's current description. Leaves `session` in place; the caller
    /// replaces it.
    private func drainLocked() -> [CMSampleBuffer] {
        guard let s = session else { return [] }
        let silence = [[Float]](repeating: [Float](repeating: 0, count: s.resampler.latencyFrames),
                                count: s.channels)
        return runLocked(silence).map { [$0] } ?? []
    }

    /// Resample `planar` through the current session and build the output buffer on its axis.
    private func runLocked(_ planar: [[Float]]) -> CMSampleBuffer? {
        guard var s = session else { return nil }
        let ch = s.channels
        // ρ for this whole block. At 1.0 this writes the value the resampler was built with.
        s.resampler.phaseIncrement = rhoIncrement
        let increment = rhoIncrement
        let phaseAtFirstOutput = s.resampler.nextAbsolutePhase
        let capacity = s.resampler.maximumOutputFrames(for: planar[0].count)
        var output = [[Float]](repeating: [Float](repeating: 0, count: capacity), count: ch)
        let produced = s.resampler.process(input: planar, output: &output)
        let discard = min(s.primerToDiscard, produced)
        s.primerToDiscard -= discard
        let n = produced - discard
        guard n > 0 else { session = s; return nil }

        // Interleave to Int32 with the SAME clamp `AudioTapBuffer.ingest` applies to Float input:
        // scale by 2^31, clamp (no wrap), truncate toward zero in range. A sample at exactly +1.0 is
        // Int32.max (1 LSB) and is not an overshoot; only a sample PAST full scale is counted.
        var interleaved = [Int32](repeating: 0, count: n * ch)
        var clamped = 0
        for c in 0..<ch {
            output[c].withUnsafeBufferPointer { src in
                for f in 0..<n {
                    let x = src[discard + f]
                    let v = Double(x) * 2147483648.0
                    let q: Int32
                    if v >= 2147483647.0 { q = .max; if x > 1.0 { clamped += 1 } }
                    else if v <= -2147483648.0 { q = .min; if x < -1.0 { clamped += 1 } }
                    else { q = Int32(v) }
                    interleaved[f * ch + c] = q
                }
            }
        }

        let ticks = s.outAnchor + s.emitted
        s.emitted += Int64(n)
        bump { $0.clamps += clamped; if increment != 1 << 32 { $0.offUnityBlocks += 1 } }

        // The block's breakpoint. Output tick `ticks` was reconstructed at absolute phase
        // `phaseAtFirstOutput + discard·increment`, which is fed frame `phase/2^32 − 1 − latency`
        // (the resampler's phase starts at one frame and its group delay is `latency`), and fed
        // frame j is input tick `inputOrigin + j + mapBase`. Stored as the offset from `ticks`, in
        // WRAPPING Q32.32: the phase wraps after 2^32 frames (~25 h) and a naive Int64 of it after
        // ~12 h, but the offset itself is small, so arithmetic modulo 2^64 lands on it exactly.
        //
        // STEP 5: a splice mark inside the block's fed span splits it. Output frame f is past mark
        // m when its phase reaches `(m.fed + 1 + latency)·2^32`; from there on the offset carries
        // m.delta, and m's output tick is where the splice is heard.
        let phase0 = phaseAtFirstOutput &+ UInt64(discard) &* increment
        let latency = Int64(s.resampler.latencyFrames)
        var f0 = 0
        while f0 < n {
            var fEnd = n
            while let m = s.marks.first {
                let markPhase = UInt64(bitPattern: m.fed &+ 1 &+ latency) &<< 32
                let d = Int64(bitPattern: markPhase &- (phase0 &+ UInt64(f0) &* increment))
                if d <= 0 {
                    s.mapBase &+= m.delta
                    s.marks.removeFirst()
                    if let k = spliceRecords.firstIndex(where: { $0.id == m.id }) {
                        spliceRecords[k].outTick = ticks + Int64(f0)
                    }
                    continue
                }
                let inc = Int64(increment)
                fEnd = min(n, f0 + Int((d + inc - 1) / inc))
                break
            }
            let segTick = ticks + Int64(f0)
            let segPhase = phase0 &+ UInt64(f0) &* increment
            let offsetTicks = s.inputOrigin &+ s.mapBase &- 1 &- latency &- segTick
            let offsetQ = Int64(bitPattern: segPhase &+ (UInt64(bitPattern: offsetTicks) &<< 32))
            breakpoints[breakpointHead] = Breakpoint(outTick: segTick, frames: Int64(fEnd - f0),
                                                     sampleRate: s.sampleRate, offsetQ: offsetQ,
                                                     increment: increment)
            breakpointHead = (breakpointHead + 1) % Self.breakpointCapacity
            breakpointCount = min(breakpointCount + 1, Self.breakpointCapacity)
            f0 = fEnd
        }
        session = s

        guard let built = Self.makeSampleBuffer(interleaved, frames: n, channels: ch,
                                                timescale: s.timescale, ptsTicks: ticks,
                                                format: s.formatDescription) else {
            bump { $0.buildFailures += 1 }
            return nil
        }
        bump { $0.outputBuffers += 1; $0.outputFrames += Int64(n) }
        return built
    }

    private func passthrough(_ sb: CMSampleBuffer, reason: @autoclosure () -> String,
                             lines: inout [Line]) -> [CMSampleBuffer] {
        // The pre-existing behaviour, and a fresh session afterwards: a later supported buffer must
        // not be measured against an axis this one never advanced.
        bump { $0.passthroughs += 1 }
        if let s = session, !s.splicer.isIdle {
            var discard = [[Float]](repeating: [], count: s.channels)
            lines += settleLocked(s.splicer.abandonAll(reason: "passthrough buffer", into: &discard),
                                  rate: s.sampleRate)
        }
        session = nil
        // The breakpoints go below, so no executed splice's mark can be crossed any more either.
        spliceRecords = []
        // The renderer now gets un-resampled audio, whose content time IS its output time.
        breakpointCount = 0
        if !passthroughLogged {
            passthroughLogged = true
            lines.append(.passthrough(reason()))
        }
        return [sb]
    }

    private func note(_ line: Line, into lines: inout [Line]) {
        eventLinesThisWindow += 1
        if eventLinesThisWindow <= Self.eventLinesPerWindow { lines.append(line) }
    }

    @inline(__always)
    private func bump(_ f: (inout Stats) -> Void) { f(&window); f(&total) }

    private static func windowLine(_ tag: String, _ w: Stats, total t: Stats, rho: Double,
                                   final: Bool, suppressed: Int) -> String {
        String(format: "%@ %@ — in=%d out=%d buf / %lld frames · ρ %.6f now, %d block(s) off 1.0 · holes %d "
               + "(%lld fr silence) · overlaps %d (%lld fr dropped) · format resets %d · axis breaks "
               + "%d · clamps %d%@ · passthrough %d · build failures %d · splices: drop %d (%lld fr), "
               + "insert %d (%lld fr), abandoned %d · session totals: out %lld fr, "
               + "holes %d, overlaps %d, resets %d, breaks %d, clamps %d, splices %d, abandoned %d%@",
               tag, final ? "session END" : "window",
               w.inputBuffers, w.outputBuffers, w.outputFrames, rho, w.offUnityBlocks,
               w.fills, w.fillFrames, w.drops, w.dropFrames, w.formatResets, w.axisBreaks,
               w.clamps, w.clamps > 0 && w.offUnityBlocks == 0 ? " ⚠️ NON-ZERO AT RATIO 1.0 — PLUMBING DEFECT" : "",
               w.passthroughs, w.buildFailures,
               w.spliceDrops, w.spliceDropFrames, w.spliceInserts, w.spliceInsertFrames,
               w.splicesAbandoned,
               t.outputFrames, t.fills, t.drops, t.formatResets, t.axisBreaks, t.clamps,
               t.spliceDrops + t.spliceInserts, t.splicesAbandoned,
               suppressed > 0 ? " · \(suppressed) event line(s) suppressed this window" : "")
    }

    private func emit(_ line: @escaping @Sendable () -> String) {
        guard let log else { return }
        DispatchQueue.global(qos: .utility).async { log(line()) }
    }

    /// Interleaved Int32 → `CMSampleBuffer`, PTS as an integer tick count on the sample rate's own
    /// timescale — the construction `SRTFrameRouter.makeAudioSampleBuffer` and
    /// `NDIService.makeAudioSampleBuffer` use, and for the reason they state: buffers abut by
    /// construction for any frame size and any rate.
    static func makeSampleBuffer(_ pcm: [Int32], frames: Int, channels: Int,
                                 timescale: CMTimeScale, ptsTicks: Int64,
                                 format: CMFormatDescription) -> CMSampleBuffer? {
        let byteCount = frames * channels * MemoryLayout<Int32>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              pcm.withUnsafeBytes({ raw in
                  CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                                offsetIntoDestination: 0, dataLength: byteCount)
              }) == noErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMTime(value: ptsTicks, timescale: timescale),
            decodeTimeStamp: .invalid)
        // BYTES PER SAMPLE (one interleaved frame), not the frame count — see the WHEP note.
        var sampleSize = channels * MemoryLayout<Int32>.size
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: frames,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}

/// `os_unfair_lock` behind a stable heap pointer — the same construction as ManifoldCore's
/// `UnfairLock`, which this leaf target cannot import (ManifoldCore depends on it, not the reverse).
/// Priority donation matters here: `retire()` on the main actor may wait behind the transport
/// thread's in-flight `process`, and donation boosts that thread rather than parking main.
final class UnfairLockBox {
    private let l: os_unfair_lock_t
    init() { l = .allocate(capacity: 1); l.initialize(to: os_unfair_lock()) }
    deinit { l.deinitialize(count: 1); l.deallocate() }
    func lock() { os_unfair_lock_lock(l) }
    func unlock() { os_unfair_lock_unlock(l) }
}
