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
//  Every fill, drop and break is COUNTED and reported. Step 5 replaces the fill/drop with the
//  cross-faded splice; this is the scaffolding that keeps step 3's measurements about the
//  plumbing rather than about packet loss.
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

    /// ⚠️ PINNED. Step 3 puts the resampler in the path with the loop open (§7). There is no setter
    /// on purpose: step 4 adds the control law, and until then the only honest value is 1.0.
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
        public init() {}

        /// Anything that is not the nominal path. A window with any of these is always reported.
        var isEventful: Bool {
            fills > 0 || drops > 0 || formatResets > 0 || axisBreaks > 0 || clamps > 0
                || passthroughs > 0 || buildFailures > 0
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
        /// Output tick of this session's first emitted frame.
        let outAnchor: Int64
        /// Output frames emitted since `outAnchor`.
        var emitted: Int64 = 0
        /// Input tick the next buffer should start at if the input axis is contiguous.
        var nextInputTicks: Int64
        /// Primer frames still to discard. `latencyFrames` after a reset, 0 at session start.
        var primerToDiscard: Int
        /// The latest input format description. Output carries it, so a roles-only relabel reaches
        /// the renderer; a drain goes out in the one the drained audio arrived with.
        var formatDescription: CMFormatDescription
    }

    private var session: Session?
    private var retired = false
    private var passthroughLogged = false

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

        func render(_ tag: String) -> String {
            switch self {
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
        session = nil
        let w = window, t = total
        let suppressed = max(0, eventLinesThisWindow - Self.eventLinesPerWindow)
        window = Stats()
        lock.unlock()
        guard !wasRetired else { return }
        let tag = self.tag
        emit { Self.windowLine(tag, w, total: t, final: true, suppressed: suppressed) }
    }

    /// Cumulative counters since construction.
    public var totals: Stats {
        lock.lock(); defer { lock.unlock() }
        return total
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
        let out = processLocked(sampleBuffer, lines: &lines)
        var windowReport: (Stats, Stats, Int)?
        let now = DispatchTime.now().uptimeNanoseconds
        if windowStartNanos == 0 { windowStartNanos = now }
        if now &- windowStartNanos >= Self.windowNanos {
            if reportsWindows || window.isEventful {
                windowReport = (window, total, max(0, eventLinesThisWindow - Self.eventLinesPerWindow))
            }
            window = Stats()
            eventLinesThisWindow = 0
            windowStartNanos = now
        }
        lock.unlock()
        let tag = self.tag
        for l in lines { emit { l.render(tag) } }
        if let r = windowReport {
            emit { Self.windowLine(tag, r.0, total: r.1, final: false, suppressed: r.2) }
        }
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
                out.append(contentsOf: drainLocked())
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
            out.append(contentsOf: drainLocked())
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
        if let built = runLocked(planar) { out.append(built) }
        session?.nextInputTicks = inTicks + Int64(frames)
        return out
    }

    private func makeSession(rate: Double, timescale: CMTimeScale, channels: Int,
                             fd: CMFormatDescription, firstInputTicks: Int64,
                             discardPrimer: Bool) -> Session {
        let r = PolyphaseResampler(channels: channels, ratio: Self.ratio,
                                   prototype: Self.sharedPrototype)
        let latency = r.latencyFrames
        return Session(sampleRate: rate, timescale: timescale, channels: channels, resampler: r,
                       outAnchor: discardPrimer ? firstInputTicks
                                                : firstInputTicks - Int64(latency),
                       nextInputTicks: firstInputTicks,
                       primerToDiscard: discardPrimer ? latency : 0,
                       formatDescription: fd)
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
        session = s
        bump { $0.clamps += clamped }

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
        session = nil
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

    private static func windowLine(_ tag: String, _ w: Stats, total t: Stats, final: Bool,
                                   suppressed: Int) -> String {
        String(format: "%@ %@ — in=%d out=%d buf / %lld frames · ratio %.6f (pinned) · holes %d "
               + "(%lld fr silence) · overlaps %d (%lld fr dropped) · format resets %d · axis breaks "
               + "%d · clamps %d%@ · passthrough %d · build failures %d · session totals: out %lld fr, "
               + "holes %d, overlaps %d, resets %d, breaks %d, clamps %d%@",
               tag, final ? "session END" : "window",
               w.inputBuffers, w.outputBuffers, w.outputFrames, ratio,
               w.fills, w.fillFrames, w.drops, w.dropFrames, w.formatResets, w.axisBreaks,
               w.clamps, w.clamps > 0 ? " ⚠️ NON-ZERO AT RATIO 1.0 — PLUMBING DEFECT" : "",
               w.passthroughs, w.buildFailures,
               t.outputFrames, t.fills, t.drops, t.formatResets, t.axisBreaks, t.clamps,
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
