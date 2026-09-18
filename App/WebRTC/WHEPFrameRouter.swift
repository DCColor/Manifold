//
//  WHEPFrameRouter.swift
//  Manifold
//
//  WHEP step 4 of 4: decoded CVPixelBuffers → SCREEN.
//
//  ── WHAT IS NEW HERE, AND WHAT IS REUSE ────────────────────────────────────────────────
//
//  Almost nothing is new. Everything downstream of `renderer.enqueue` is the hardened path
//  the file, NDI and SyntheticLiveSource paths already share, and it is NOT touched: the
//  ordered insert, the queue bound, LiveClock's control loop, the display tick, the shader.
//  This file only feeds them correctly. Specifically it reuses:
//
//    * LiveClock          — verbatim from SyntheticLiveSource: registerFrame(senderPTS:) on
//                           the source thread, now() into renderer.clock, updateDepth() from
//                           renderer.onDepthSample. Same three seams, same order.
//    * the promote        — VTPixelTransferSession into a pooled buffer, the shape NDIService
//                           uses to reach the shader's 10-bit sample domain (NDIService.swift,
//                           convertToDisplayFormat). Destination is x420 rather than NDI's
//                           x422 because the source is 4:2:0, so nothing is resampled.
//    * the CMSampleBuffer — CMSampleBufferCreateReadyWithImageBuffer, same as both.
//    * the takeover       — retire the current source, repoint the renderer's providers,
//                           mirroring NDIService.start() / SyntheticLiveSource.start().
//
//  The genuinely WHEP-specific part is one line: the sender timeline is the RTP 90 kHz clock,
//  which LiveVideoDecoder has already unwrapped past the ~13-hour 32-bit wrap and handed over
//  as a CMTime. See `deliver`.
//
//  ── THREADING ──────────────────────────────────────────────────────────────────────────
//
//  Two threads, meeting at one lock — the NDIService colorLock pattern, for the same reason.
//
//    * `deliver` runs on ManifoldWHEPSession.decodeQueue (serial, USER_INITIATED — below the
//      render thread by design). It owns the promote session and pool exclusively, so those
//      need no lock. It calls LiveClock.registerFrame and MetalVideoRenderer.enqueue, both
//      documented background-safe (enqueue takes the priority-donating UnfairLock).
//    * `activate` / `deactivate` run on main (the ⌃⌥H / ⌃⌥⇧H triggers).
//
//  `stateLock` guards ONLY the (clock, renderer) pair those two exchange. It is never held
//  across enqueue: the references are copied out, the lock released, then the work is done.
//  That is deliberate — holding a lock across a call that takes the renderer's queue lock
//  would put a main-thread activate behind the render thread.
//

import CoreMedia
import CoreVideo
import Foundation
import ManifoldCore      // UnfairLock — the priority-donating lock both telemetry locks use
import QuartzCore
import VideoToolbox

/// ── WHEP'S FRAME-RATE LADDER: EXACT, THEN MEASURED, THEN REFUSED ─────────────────────────────
///
/// SRT reads `av_guess_frame_rate` from the demuxer and HLS measures item-time gaps. WHEP had
/// neither and published nothing, so DeckLink "Follow source" was permanently unavailable on it.
/// This is the third answer, and it is a LADDER because WHEP genuinely has three different
/// situations and collapsing them would mean guessing in the third.
///
/// ── RUNG 1: SPS VUI TIMING (EXACT) ───────────────────────────────────────────────────────
/// `ManifoldH264ParseSPSTiming` reads `num_units_in_tick` / `time_scale` out of the SPS the
/// depacketizer already extracts. When present this is the ENCODER'S OWN DECLARATION and nothing
/// measured can improve on it — 24000/1001 arrives exact, not as 23.9761 with a spread. VUI is
/// optional in H.264 and `timing_info_present_flag` is very often 0, so absence is ordinary and
/// falls through rather than failing.
///
/// ── RUNG 2: MEASURED FROM RTP TIMESTAMPS ─────────────────────────────────────────────────
///
/// ⚠️ THIS FILE USED TO CLAIM RTP TIMESTAMPS "DESCRIBE TRANSMISSION, NOT CAPTURE CADENCE", AND
/// THAT WAS WRONG. RFC 3550 §5.1 defines the RTP timestamp as the SAMPLING INSTANT, and RFC 6184
/// §8.2.1 has every NAL of one access unit carry the same one. It is capture time by
/// specification. This transport has also MEASURED it that way through Cloudflare's SFU — see the
/// depth-preset block below: *"PTS is correctly RTP-derived, and the sender's clock is real-time
/// locked (~90,100 tps)"*. Whatever the SFU rewrites (SSRC, sequence numbers, an offset across a
/// layer switch), it is not corrupting the tick RATE on this path.
///
/// The alternative — decoded-frame ARRIVAL intervals — would be unusable here, by this file's own
/// numbers: arrival lateness measured p50 = 57 ms, p90 = 121 ms, max = 162 ms against a 41.7 ms
/// frame interval at 23.98 fps. That jitter is three times the quantity being measured, and it is
/// the entire reason `targetDepth` is 0.400. Sender PTS is clean; arrival is not. So this measures
/// sender PTS and nothing else.
///
/// ── WHAT CHANGED FROM THE HLS ESTIMATOR'S SHAPE, AND WHY ─────────────────────────────────
///
/// The shape is borrowed (rolling window → median → trim → mean) but two things had to change,
/// both because HLS pulls from a local player and WHEP receives over a lossy link:
///
///   * HLS trims to [0.5x, 2x] of the median, which ASSUMES every sample is one frame interval.
///     WHEP drops frames, and a dropped frame makes the next gap an exact INTEGER MULTIPLE — 2x,
///     3x — of the interval. HLS's window would keep the 2x samples (2.0 is inside [0.5, 2.0])
///     and inflate the mean. This trims to [0.75x, 1.25x] instead, which admits only single-frame
///     intervals and discards every multiple, and it counts what it discarded.
///   * HLS offers an estimate as soon as the window is full. WHEP additionally requires the
///     surviving samples to be TIGHT (see the spread gate below) before publishing anything.
///
/// ── RUNG 3: REFUSAL, WHICH IS THE POINT ──────────────────────────────────────────────────
///
/// WHEP may be genuinely variable-rate — screen share, a congested encoder dropping its rate, a
/// sender changing profile mid-stream. A confident wrong rate sets a wrong cadence on the SDI
/// wire and LOOKS DELIBERATE, which for a reference tool is worse than stating nothing: the
/// operator has no way to tell a followed rate from a fabricated one. So when the measurement does
/// not settle, this publishes nil and the manual picker takes over, exactly as today.
///
/// THE THRESHOLD IS 2% RELATIVE SPREAD over the kept samples, measured as
/// `(max - min) / median`. Why 2%: the tightest pair of standard rates this has to tell apart is
/// 29.97 and 30, which differ by 0.1%. A spread of 2% is twenty times that gap, so a stream whose
/// samples fall inside it cannot be ambiguous between two standard rates once
/// `resolveOutputMode` snaps. It is also comfortably wider than the quantization floor: at 90 kHz,
/// one tick on a 30 fps interval (3000 ticks) is 0.03%, so a CFR stream measures far tighter than
/// 2% and passes easily. A VFR stream does not come close.
private struct WHEPFrameRateEstimator {
    /// Gaps in the rolling window. 120 matches HLS — ~5 s at 24 fps, ~2 s at 60.
    private static let windowSize = 120
    /// Keep only samples this close to the median. Tighter than HLS's [0.5x, 2x] so that a gap
    /// left by a dropped frame (an exact 2x or 3x) is discarded rather than averaged in.
    private static let keepLow = 0.75, keepHigh = 1.25
    /// Publish only when `(max - min) / median` over the kept samples is below this. See above.
    private static let maxRelativeSpread = 0.02
    /// A gap longer than this is a freeze, a reconnect or a keyframe stall, not a cadence sample.
    private static let implausibleGapSeconds = 1.0
    /// At least this many samples must SURVIVE the trim. A window that is mostly multiples has not
    /// measured a cadence, it has measured a loss pattern.
    private static let minKept = 60

    private var lastSenderPTS: Double?
    private var gaps: [Double] = []
    /// The published estimate, or nil while unsettled. Held until it moves >1%, for the reason the
    /// HLS estimator states: a rolling window re-computes every frame and would otherwise fail the
    /// latch's dedup on every frame.
    private(set) var estimate: Double?
    /// Last computed spread, for the refusal log.
    private(set) var lastSpread: Double = .nan
    /// Worst fit of a gap to its assigned integer multiple. THE REFUSAL SIGNAL — see `record`.
    private(set) var lastFitResidual: Double = .nan
    /// How many samples survived the trim. Read by the refusal log when `lastSpread` is NaN.
    private(set) var keptCount = 0
    private(set) var discardedAsMultiples = 0

    /// Feed one decoded frame's sender PTS. Returns true when the published answer CHANGED
    /// (including settling, or un-settling), which is the caller's cue to log.
    mutating func record(senderPTS: Double) -> Bool {
        defer { lastSenderPTS = senderPTS }
        guard let lastSenderPTS else { return false }
        let gap = senderPTS - lastSenderPTS
        // Backwards (a reorder that reached us, or a re-anchor) or implausibly long: not a sample.
        guard gap.isFinite, gap > 0, gap < Self.implausibleGapSeconds else { return false }

        gaps.append(gap)
        if gaps.count > Self.windowSize { gaps.removeFirst(gaps.count - Self.windowSize) }
        guard gaps.count == Self.windowSize else { return false }

        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return false }

        let kept = gaps.filter { $0 >= median * Self.keepLow && $0 <= median * Self.keepHigh }
        discardedAsMultiples = gaps.count - kept.count
        guard kept.count >= Self.minKept, let lo = kept.min(), let hi = kept.max() else {
            // Too few single-frame intervals survived: this window measured a LOSS PATTERN, not a
            // cadence. Reported distinctly — `lastSpread` is deliberately left NaN and the caller
            // reads `keptCount` instead, because inventing a spread for a sample set we rejected
            // before computing one would be a fabricated number in a refusal message.
            lastSpread = .nan
            keptCount = kept.count
            return demote()
        }
        keptCount = kept.count

        // Retained as an OBSERVATION, no longer a gate — see the fitResidual note below.
        lastSpread = (hi - lo) / median

        // ── SPAN MEASUREMENT, THE SAME SHAPE AS HLS'S ──────────────────────────────────────
        //
        // Intervals ÷ elapsed time, with each gap rounded to the nearest integer multiple of the
        // median, so a dropped frame contributes both its intervals AND its time and cancels
        // exactly. See the matching note in `FrameRateEstimator` (HLSClient.swift), including the
        // finding that this is NOT a precision improvement over the trimmed mean it replaces —
        // `1/mean(gaps)` and `count/span` are the same number — and is worth doing for the
        // dropped-frame handling alone. On this transport that handling matters more than it does
        // on HLS: WHEP is a push source over a lossy link and drops are ordinary.
        var totalIntervals = 0.0
        var span = 0.0
        var maxFitResidual = 0.0
        for g in kept {
            let m = max(1.0, (g / median).rounded())
            totalIntervals += m
            span += g
            maxFitResidual = max(maxFitResidual, abs(g - m * median) / median)
        }
        guard span > 0, totalIntervals > 0 else { return demote() }
        lastFitResidual = maxFitResidual

        // ⚠️ THE REFUSAL GATE MOVED FROM `spread` TO `fitResidual`, AND IT HAD TO.
        //
        // The gate exists to refuse a variable-rate stream rather than publish a confident wrong
        // cadence. It used to test the raw spread of the gaps — which was coherent while the
        // estimate was a mean of those gaps, and is INCOHERENT now: a single dropped frame makes
        // one gap 2x the median, which is a ~100% raw spread, so the old gate would refuse exactly
        // the case the multiple-rounding above was added to handle correctly.
        //
        // `fitResidual` is the right signal for this method: it asks whether each gap landed
        // cleanly on an integer multiple of one interval. A CFR stream with losses fits perfectly
        // and passes; a genuinely variable-rate stream does not fit any integer grid and is
        // refused. The threshold stays 2%, for the reason it always was — twenty times the 0.1%
        // gap between the closest pair of standard rates this has to separate.
        //
        // ⚠️ THIS GATE IS SOUND HERE AND WOULD BE WRONG ON HLS. DO NOT PORT IT THERE.
        // It works because these samples are the SENDER'S 90 kHz RTP timestamps — capture instants
        // straight from the encoder, so a CFR stream's gaps really are constant and a poor fit
        // really does mean variable-rate. HLS measures display-tick capture instants instead, where
        // a 23.976 fps source against a 60 Hz tick alternates 2- and 3-tick gaps forever and the
        // residual is ~20% on a perfectly healthy stream. Same arithmetic, different clock,
        // opposite meaning — see the matching note on `FrameRateEstimator.Diagnostics.fitResidual`.
        guard maxFitResidual <= Self.maxRelativeSpread else { return demote() }

        let fps = totalIntervals / span

        guard let held = estimate else { estimate = fps; return true }
        guard abs(fps - held) / held > 0.01 else { return false }
        estimate = fps
        return true
    }

    /// The stream stopped being measurable. Drops the estimate — a rate that was true a minute ago
    /// is not evidence about a stream that has since gone variable, and continuing to publish it
    /// would be the confident-wrong-answer this ladder exists to avoid.
    private mutating func demote() -> Bool {
        guard estimate != nil else { return false }
        estimate = nil
        return true
    }

    mutating func reset() {
        gaps.removeAll(keepingCapacity: true)
        lastSenderPTS = nil
        estimate = nil
        lastSpread = .nan
        lastFitResidual = .nan
        keptCount = 0
        discardedAsMultiples = 0
    }
}

final class WHEPFrameRouter {

    static let shared = WHEPFrameRouter()
    private init() {}

    /// The display path. Set once at startup (ContentView.onAppear), the SAME instance the file
    /// path, NDI and DeckLink use. Weak: ContentView owns it.
    weak var renderer: MetalVideoRenderer?

    /// Called on main just before WHEP takes the display, to retire whatever else is driving it
    /// (a loaded file). Set once by ContentView — this type has no engine handle. Identical role
    /// to NDIService.onWillActivateStream, and it exists for the same reason: one active source,
    /// so a file's frame pump and WHEP's push never both feed the renderer.
    var onWillActivateStream: (() -> Void)?

    // MARK: - Live audio seams
    //
    // Set by WindowDeck from the deck's engine, exactly as `NDIService.audioTap` is — this type
    // has no engine handle, for the same reason the renderer is injected rather than reached for.
    // WHEP goes further than NDI: NDI feeds only the TAP (so it meters and can reach SDI, but is
    // inaudible on the desktop), whereas these seams reach the shared audio RENDERER too, which is
    // what makes a WHEP stream actually audible.

    /// Opens the shared renderer to live audio; returns the sink. Takes NO time — the live clock
    /// is unanchored at this point in the connect sequence (it anchors on the first VIDEO frame),
    /// so there is no valid instant to hand it. See `anchorLiveAudio`.
    var beginLiveAudio: ((Double) -> FrameEngine.LiveAudioSink?)?
    /// Forwards `LiveClock`'s mapping to the engine's audio timebase. Set by `WindowDeck`; called
    /// on whichever thread changed the mapping, so the engine side is `nonisolated`.
    var mirrorLiveAudio: ((LiveClock.Mapping?) -> Void)?
    /// Closes it. Must be called on teardown or the renderer keeps a dead session's timebase.
    var endLiveAudio: (() -> Void)?
    /// Publishes the decoded channel count so the meters size their bars.
    var liveAudioEstablished: ((Int) -> Void)?
    /// Publishes positive ABSENCE — the server declined audio, or the stream carries none.
    var liveAudioAbsent: (() -> Void)?
    /// Synchronizer-timebase minus live-clock, for the stage-1 sync measurement.
    var liveAudioDrift: ((Double) -> Double?)?

    /// The Opus receive path for the current session. Non-nil only while a session is live.
    private(set) var audioReceiver: WHEPAudioReceiver?

    /// Start the audio path for a session whose answer accepted the audio m-section.
    ///
    /// `channels` is what the ANSWER agreed; the decoder re-establishes it from what actually
    /// decodes, so a server that answers stereo and sends mono still meters correctly.
    /// ── WHY LIFETIME KEYING RATHER THAN A GENERATION TOKEN ────────────────────────────────────
    ///
    /// An audit asked whether the audio anchor state should join "the same generation token as its
    /// neighbours". It cannot: THERE IS NO SUCH TOKEN HERE. This router's neighbours are keyed the
    /// same way this is — `liveClock` nil/non-nil, `route`'s saved state, `audioReceiver`
    /// nil/non-nil. (`LiveDisplaySize` and `FrameEngine.audioSessionToken` do have counters, but
    /// they guard different races: a size hopping in from the decode queue, and a file audio-track
    /// switch. Neither covers this seam.)
    ///
    /// Lifetime keying IS sufficient here, for a reason worth stating: every epoch that could go
    /// stale lives inside `WHEPAudioReceiver`, a fresh instance is constructed per session, and
    /// `stopAudio` releases it. A new receiver cannot carry an old session's epoch because it has
    /// never had one — there is no state to reset and therefore no reset to forget. That is a
    /// stronger guarantee than a counter, which only helps if every reader remembers to check it.
    ///
    /// ⚠️ WHAT WAS ACTUALLY WRONG was not the keying but the SILENCE. A second `applyAnswer` with
    /// no teardown hit `guard audioReceiver == nil else { return }` and did nothing, leaving the
    /// previous negotiation's receiver running against a new answer, with no line in the log. A new
    /// answer is a new negotiation, so the old receiver is wrong by definition — it is now torn
    /// down and rebuilt, loudly.
    func startAudio(channels: Int) {
        if audioReceiver != nil {
            NSLog("[WHEP-AUDIO] startAudio while a session is ALREADY RUNNING — a second answer "
                + "without a teardown. Retiring the previous audio session and restarting; if this "
                + "appears outside a renegotiation it is a signalling bug, not a recovery.")
            stopAudio()
        }
        guard let begin = beginLiveAudio, let drift = liveAudioDrift else {
            NSLog("[WHEP-AUDIO] no engine seam wired — audio cannot be played")
            return
        }
        // ⚠️ RETURNS `-.infinity` UNTIL THE FIRST VIDEO FRAME ANCHORS THE CLOCK — that is
        // `LiveClock.now()`'s documented "never due" sentinel, not a fault. The receiver must test
        // `isFinite` before deriving anything from it; `?? 0` covers only a torn-down router.
        let clock: () -> Double = { [weak self] in
            guard let self else { return 0 }
            self.stateLock.lock()
            let c = self.liveClock
            self.stateLock.unlock()
            return c?.now() ?? 0
        }
        // ── `cushion: 0` — AND IT IS NOT "NO CUSHION" ───────────────────────────────────────
        //
        // ⚠️ READ `FrameEngine.beginLiveAudio`'s parameter note before changing this. Despite the
        // name, this argument is not the live clock's buffer depth. Its only two consumers are
        // `mirrorLiveAudio` (`let target = m.senderPTS - cushion`) and `liveAudioDrift`, and in both
        // its actual meaning is: HOW FAR BEHIND THE MAPPING'S `senderPTS` THIS TRANSPORT STAMPS ITS
        // AUDIO. It positions the synchronizer timebase on the same axis as the PTS it will be fed.
        //
        // This used to pass `targetDepth`, and that was RIGHT for the audio this file used to
        // produce: `WHEPAudioReceiver` latched `clockEpoch = LiveClock.now()` and stamped on the
        // `now()` axis, which sits exactly `targetDepth` behind the sender timeline. Timebase and
        // PTS carried the same offset, it cancelled, and the desktop was in sync.
        //
        // The receiver now stamps ABSOLUTE SENDER TIME (the SRT shape — see the axis note there),
        // so the offset is zero and this must say zero. Passing `targetDepth` against sender-axis
        // PTS would put the timebase 400 ms behind the audio and play every buffer 400 ms LATE on
        // the desktop — trading the SDI bug for a lip-sync bug. The two edits are one change.
        //
        // ⚠️ THIS IS PER-SESSION AND CANNOT REACH SRT. `mirror.cushion` is set from this argument
        // inside `beginLiveAudio`, so SRT's own call is untouched and its behaviour is unchanged.
        guard let sink = begin(0) else {
            NSLog("[WHEP-AUDIO] engine refused a live-audio session"); return
        }
        let receiver = WHEPAudioReceiver(clock: clock)
        receiver.start(sink: sink, channels: channels, driftProbe: drift)
        audioReceiver = receiver
        NSLog("[WHEP-AUDIO] audio path ACTIVE — %d ch expected, Opus via AudioToolbox", channels)
    }

    /// The stream carries no audio. Stated positively so the meters say "NO AUDIO TRACK" rather
    /// than sitting at "waiting" forever — see `AudioMeterModel.Status`.
    func declareNoAudio() {
        liveAudioAbsent?()
        NSLog("[WHEP-AUDIO] this stream carries no audio — meters will report absence")
    }

    func stopAudio() {
        audioReceiver?.stop()
        audioReceiver = nil
        endLiveAudio?()
    }

    // MARK: - Depth preset
    //
    // 0.400 s — MEASURED AGAINST A LIVE FEED, NOT TAKEN FROM THE PRESET GRID.
    //
    // ── THE MEASUREMENT ──────────────────────────────────────────────────────────────────────
    //
    // Live Cloudflare WHEP feed at 23.98 fps, on a VALID Profile build (-O for both Swift and C —
    // an earlier Debug-build measurement was invalidated and redone, which is why [BUILD] now
    // states the optimization level on the first line of every log):
    //
    //   targetDepth 0.200 → 70 genuine underruns in 118 s. Lateness distribution
    //                       p50 = 0.057 s, p90 = 0.121 s, max = 0.162 s (n = 70), i.e.
    //                       cushion needed >= 0.362 s. Presented fps dipped repeatedly to 19–23.
    //   targetDepth 0.400 → ZERO genuine underruns over 70 s. Presented fps flat at 24.0–24.2.
    //
    // The deficits are NETWORK burstiness, not local scheduling: the same distribution appears
    // under -O as under -Onone, which is what re-measuring after the invalidated run established.
    // 0.400 is the measured 0.362 requirement plus a small margin, not a round number chosen first.
    //
    // ── WHY THE OLD 0.200 WAS WRONG ──────────────────────────────────────────────────────────
    //
    // It came from docs/LIVECLOCK_PRESETS.md ("Stable"), whose grid was swept against a
    // no-B-frame HEVC file with an even decode cadence and INJECTED jitter far smaller than real
    // network conditions. Those presets are stale for live sources — the doc's own caveat said as
    // much, and this measurement is the evidence. (Cleaning up the preset grid is a separate task;
    // the synthetic harness still uses it and is deliberately untouched here.)
    //
    // RETUNING ON OTHER NETWORKS: ⌃⌥[ / ⌃⌥] step the live target by ±0.05 s, and
    // [WHEP-UNDERRUN] / [WHEP-JITTER] report the observed lateness distribution and the
    // running-max "cushion needed" that this number was derived from. Re-derive, don't guess.
    //
    // STARTUP == TARGET, deliberately and unchanged: the initial fill lands ON the setpoint
    // instead of draining to it at ±maxSlew — at 0.005/s a 0.2 s gap would take 40 s to close.
    // This one constant supplies both (see `activate`), so they cannot drift apart.
    private static let targetDepth = 0.400

    /// LiveClock's default rail, stated here as a named constant ONLY so the backlog accountant can
    /// compute its residual bound (residual is the integrated slew, so |residual| ≤ maxSlew × elapsed).
    /// The VALUE IS UNCHANGED — 0.005, LiveClock's default — and the diagnosis explicitly settles
    /// that it stays there: slew is a ppm-scale trim for crystal drift, and DISCARD is the
    /// instrument for backlog. See the block in `routeConfig` before touching it.
    private static let maxSlew = 0.005

    // MARK: - The route's per-source configuration
    //
    // Every value here was previously assigned inline in `activate()`. The NUMBERS and their
    // reasoning stayed in this file deliberately: they are WHEP measurements against a Cloudflare
    // feed, not properties of "a live source", and LiveDisplayRoute cannot know why any of them are
    // what they are. SRT will pass its own Config with its own numbers — SRTO_LATENCY already does
    // part of what `targetDepth` does here, so it will need its own measurement, not this one.
    private static var routeConfig: LiveDisplayRoute.Config {
        LiveDisplayRoute.Config(
            targetDepth: targetDepth,

            // ── SLEW RAIL — SETTLED. DO NOT RAISE. ─────────────────────────────────────────
            //
            // The measurement is IN, and it closes: 659 pictures in 25 s from a 23.98 fps sender is
            // 27.48 s of content, a 2.48 s surplus, which landed as 0.93 s flushed plus 1.59 s left
            // in the buffer = 2.52 s. The accounting balances. Transport is clean (seqGaps=0,
            // lost=0, reorder=0, AUs assembled == pictures decoded), PTS is correctly RTP-derived,
            // and the sender's clock is real-time locked (~90,100 tps) once the backlog drains.
            // There is NO clock drift and NO measurement bias to chase.
            //
            // WHICH MEANS THE RAIL WAS NEVER THE PROBLEM. ±0.5% is a drain rate of 0.005 s of
            // buffer per second — absorbing a 2.5 s connect backlog that way would take EIGHT
            // MINUTES. Raising it would not fix that; it would only make the correction visible on
            // moving video while still losing the race. Slew is a ppm-scale trim for CRYSTAL DRIFT.
            // DISCARD is the instrument for BACKLOG, and that is what the snap, the queue-full
            // re-anchor and the freeze guard provide. Since every overfill is finite (the sender
            // makes 23.98/s and the SFU cannot exceed that indefinitely), discarding is guaranteed
            // to converge.
            //
            // 0.005 is LiveClock's default, so this changes nothing — it is here to state the
            // conclusion at the place someone would otherwise reach for the knob.
            maxSlew: maxSlew,

            // SNAP-TO-LIVE, on for this transport (LiveClock defaults it off — see `snapEnabled`).
            // A WHEP sender that pauses and resumes leaves a slab of buffered latency the ±0.5%
            // slew cannot drain, and it happens on every pause in a review session. The knobs are
            // stated rather than left implicit because they are the two things worth tuning from
            // real behaviour: threshold is how deep is "too deep", debounce is how long we tolerate
            // it before jumping. Conservative starting values — a missed snap costs latency, a
            // false snap costs a visible jump, and the second is the worse failure.
            snapEnabled: true,
            // UNCHANGED at 0.2, but note the arithmetic moved with targetDepth: the snap fires
            // above ~0.6 s (0.400 target + 0.2 threshold) rather than ~0.4 s. That is still the
            // right shape — the threshold is "how far above target is a GROSS overfill the P-loop
            // cannot drain", which scales with the target rather than being an absolute depth — but
            // it does mean the buffer tolerates more absolute latency before snapping than it used
            // to. Revisit if [WHEP-BACKLOG] ever shows a connect backlog sitting between 0.4 s and
            // 0.6 s.
            snapThreshold: 0.2,      // snap above ~0.6 s with a 0.4 s target
            snapDebounce: 0.75,      // sustained, not a burst

            // Headroom above the shallow file-path bound (12) so the control loop can correct a
            // filling buffer before it saturates and drop-oldest fires — the value the sweep was
            // run against.
            maxQueued: 30,

            // ASSUMED, NOT READ — and this is a WHEP limitation, which is exactly why it is stated
            // here rather than defaulted inside LiveDisplayRoute. H.264 signals colorimetry in the
            // SPS VUI, and our RTP depacketizer does not parse it. 709 SDR video-range is the
            // honest default for a Constrained Baseline WHEP stream, and it is the SAME default NDI
            // starts on for a source that declares nothing (NDIService.start). Range is pinned
            // rather than read from the file transport's override, which describes a file that may
            // not even be loaded — again exactly as NDI does.
            //
            // AN SRT SOURCE MUST NOT COPY THIS. libavformat fills codecpar->color_primaries /
            // color_trc / color_space from the same VUI, so SRT can state the truth instead.
            colorimetry: .assumedRec709SDR)
    }

    // MARK: - Live state (main thread, except where noted)

    private let stateLock = NSLock()
    /// The clock, published to the decode queue under `stateLock`. nil = not active, which is how
    /// `deliver` cheaply drops frames that arrive before activate or after deactivate.
    ///
    /// OWNED HERE, NOT BY `route`. LiveDisplayRoute builds and configures the clock and hands it
    /// back; this lock and this field are unchanged, so `deliver`'s per-frame read is exactly the
    /// single lock acquisition it always was. See the header note in LiveDisplayRoute.
    private var liveClock: LiveClock?

    /// The shared live-push display plumbing: renderer save/restore, the LiveClock's four seams,
    /// queue bound, flush, colorimetry. Everything in it was written here first and moved out
    /// verbatim so SRT can use the same path rather than cloning it. What stayed behind is what is
    /// genuinely WHEP's: the measured `targetDepth`, the assumed colorimetry, and the RTP-specific
    /// drift accountant. The surplus ledger and the underrun accountant moved out too, into
    /// LiveDepthTelemetry — see the note at `telemetry`.
    private let route = LiveDisplayRoute()

    // MARK: - Promote state (decode queue only)

    private var transferSession: VTPixelTransferSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)
    /// One line the first time a frame is promoted (or found already 10-bit), then silence.
    private var reportedPromote = false

    // MARK: - Drift measurement (STEP 1: diagnose before changing slew)
    //
    // THE SYMPTOM: depth creeps 0.2 → 0.6 over minutes with `rate` PINNED at the +0.5% maxSlew
    // rail the whole time. A saturated controller is a controller being asked for more authority
    // than it has — but it is ALSO what a controller chasing a phantom looks like, and yesterday's
    // Δ/2 depth offset proves this pipeline can produce exactly that. Raising maxSlew to chase a
    // measurement artifact would hide the artifact and leave the real bug. So: measure first.
    //
    // (1) TRUE SENDER RATE, measured INDEPENDENTLY OF LIVECLOCK. For each frame we hold the
    //     sender's own timestamp (unwrapped RTP, seconds) and the host time it arrived. Define
    //
    //         offset(t) = hostArrival − senderPTS
    //
    //     If the sender's clock runs at ratio `r` relative to ours, senderPTS advances as r·t, so
    //     offset drifts at exactly (1 − r) per second. Therefore
    //
    //         senderRatio = 1 − d(offset)/dt
    //
    //     Nothing in that derivation touches the anchor, the rate, the queue, or the depth signal
    //     — it is a property of the TRANSPORT alone. That independence is the entire point: it is
    //     the reference the depth-derived numbers get checked against, so a bias in the depth path
    //     cannot contaminate it.
    //
    //     JITTER REJECTION: network + decode delay is additive and NON-NEGATIVE, so it can only
    //     push `offset` up, never down. The MINIMUM offset in a window is therefore the
    //     least-delayed frame — the cleanest available estimate of the true clock relationship.
    //     Differencing window minima rejects queueing jitter that would otherwise swamp a 0.8%
    //     signal (a ±50 ms delay spike across a 5 s window is ±1%, i.e. bigger than the effect).
    //
    // (2) IS THE DEPTH SIGNAL HONEST? With the controller running at `rate`, the buffer must fill
    //     at exactly
    //
    //         predictedCreep = senderRatio − rate      [seconds of depth per second]
    //
    //     NOT `senderRatio − 1`: the loop is already clawing back `rate − 1` of the mismatch, and
    //     comparing against the raw drift would condemn a CORRECTLY-behaving system. If observed
    //     creep matches this prediction, the drift is real and the fix is slew authority. If it
    //     does not, the residual IS the bias — in seconds per second, pointing straight at it.
    //
    // Guarded by `driftLock`, its own lock rather than `stateLock`: both threads write here (the
    // decode queue supplies sender timestamps, the render thread supplies depth), and this is
    // diagnostic bookkeeping that has no business sharing a lock with the activation state.
    //
    // UNFAIR LOCK, NOT NSLock — TEXTBOOK PRIORITY INVERSION, IDENTICAL TO THE ONE INSIDE
    // LiveDepthTelemetry. The
    // real-time CVDisplayLink render thread takes this EVERY DISPLAY TICK in `recordDepthForDrift`,
    // while the lower-priority USER_INITIATED decode queue holds it per frame in
    // `recordDriftSample`. `NSLock` is a pthread_mutex and does NOT boost its holder, so the decode
    // thread can be descheduled while holding it and stall the display tick for an unbounded
    // interval — the same shape as the live-path inversion `queueLock` was converted to fix, and
    // the same one the depth accountant carries. `os_unfair_lock` DONATES the blocked render thread's
    // priority to the holder, which is what dissolves it.
    //
    // The usage rule that makes this safe, and which all three critical sections already obeyed:
    // NOTHING SLOW UNDER THIS LOCK. A boosted holder must release promptly, so `recordDriftSample`
    // snapshots the closing window's values, unlocks, and only then computes the verdict strings and
    // emits `[WHEP-DRIFT]`. Note it also reads `clock.rate` (which takes LiveClock's lock) AFTER the
    // unlock — these two locks are never nested, in either order.
    private let driftLock = UnfairLock()
    /// Report cadence. Long enough that the min-offset difference is dominated by drift rather
    /// than by the residual jitter that survives the min filter.
    private static let driftWindow = 5.0
    private var driftWindowStartHost: Double = 0
    /// min(hostArrival − senderPTS) over the current window. `.infinity` until the first frame.
    private var driftWindowMinOffset: Double = .infinity
    /// The previous window's minimum + the host time it closed — the two ends of the difference.
    private var previousWindowMinOffset: Double?
    private var previousWindowEndHost: Double?
    /// Mean measured depth over the window, and the previous window's, for the creep rate.
    private var driftDepthSum = 0.0
    private var driftDepthN = 0
    private var previousWindowMeanDepth: Double?
    /// Set when a snap/degrade fires. A coarse clock action moves depth DISCONTINUOUSLY, so any
    /// window containing one has a creep number that describes the snap, not the drift. Such a
    /// window reports the sender rate (still valid — it is anchor-independent) and explicitly
    /// declines to report creep, rather than printing a number that means nothing.
    private var driftWindowHadSnap = false

    // MARK: - Depth telemetry (the surplus ledger + the underrun accountant)
    //
    // MOVED OUT, NOT DELETED. All of it — the ledger's residual derivation, the underrun
    // accountant's "cushion needed", the 1 s arrival bins, the all-time percentile summary — now
    // lives in LiveDepthTelemetry, unchanged, so SRT gets the same instrument on day one instead
    // of a second copy that drifts from this one. The log lines are byte-identical: the prefix is
    // a parameter and this instance passes "WHEP".
    //
    // WHAT STAYED BEHIND, deliberately: the DRIFT accountant below. It reports the sender's rate
    // in RTP 90 kHz ticks per second and answers a question about a WebRTC sender's crystal that
    // SRT's TSBPD scheduling reframes rather than inherits. Sharing it would have exported a
    // derivation that is only correct for this transport.
    //
    // `cushion` is the ANCHOR offset — the value `targetDepth` had at activate(), which is what
    // the ledger's algebra is written against. A runtime step of the live target is accounted for
    // separately, as a signed clock jump (see adjustTargetDepth).
    private let telemetry = LiveDepthTelemetry(prefix: "WHEP",
                                               cushion: WHEPFrameRouter.targetDepth,
                                               maxSlew: WHEPFrameRouter.maxSlew)

    /// The measured "cushion needed" a future adaptive-depth controller will consume — or nil when
    /// telemetry is compiled out. Forwarded rather than removed: this is the seam that work will
    /// read, and it should stay findable on the router rather than only on the accountant.
    var measuredCushionNeeded: Double? { telemetry.measuredCushionNeeded }

    // MARK: - Frame-flow telemetry (decode queue writes; depth fields written on the render thread)

    private var framesDelivered = 0
    private var framesEnqueued = 0
    private var promoteFailures = 0
    private var lastFlowLogHost: CFTimeInterval = 0
    private var lastFlowLogEnqueued = 0
    /// Latest depth sample, written on the render thread from onDepthSample and read on the decode
    /// queue by the 1 Hz flow log. A benign cross-thread read of telemetry-only scalars — the same
    /// concession SyntheticLiveSource makes for `lastQueueCount`.
    private var lastDepthSpan: Double = 0
    private var lastDepthCount: Int = 0

    // MARK: - Activation (main thread)

    /// WHEP takes the display. Mirrors NDIService.start() and SyntheticLiveSource.start(): retire
    /// the current source FIRST, then repoint the renderer's providers, then let frames flow.
    ///
    /// Ordering note: this is called from WHEPClient.connect() BEFORE the answer is applied, for the
    /// same reason the decoder is wired there — RTP can arrive the instant DTLS completes, and a
    /// frame that reaches `deliver` with no clock installed is simply dropped.
    func activate() {
        // Main-thread only, asserted the way WHEPClient asserts it rather than with @MainActor:
        // connect()/disconnect() are plain nonisolated methods (they hop to main explicitly, see
        // applyAnswer), so an actor annotation here would force an await into a synchronous path.
        dispatchPrecondition(condition: .onQueue(.main))
        guard let renderer else {
            NSLog("[WHEP] no renderer wired — decoded frames will be counted but not displayed")
            return
        }
        // Everything from the takeover through the colorimetry is LiveDisplayRoute's, in the exact
        // order it was written here: retire the current source, build the clock, save the
        // renderer's providers, install ours, wire the clock's four seams, bound the queue, flush,
        // state the colour. The clock comes BACK rather than staying there — see `liveClock`.
        let clock = route.activate(
            renderer: renderer,
            config: Self.routeConfig,
            // One active source: retire the loaded file before we take the renderer.
            retireCurrentSource: { self.onWillActivateStream?() },
            // RENDER THREAD, once per display tick. The clock call already happened inside the
            // route; `event` is non-nil only on a coarse action (snap / freeze-guard re-anchor).
            // This is the WHEP-specific measurement the shared type has no business holding.
            onDepth: { [weak self] sample, event in
                self?.lastDepthSpan = sample.spanSeconds   // telemetry only (see the field comment)
                self?.lastDepthCount = sample.count
                // Underrun detection, on the selection path where count == 0 is already known.
                self?.telemetry.recordSelection(count: sample.count, presented: sample.hadEligibleFrame)
                // Feed the creep side of the drift comparison. Averaged over the window rather than
                // sampled at its edges: the raw span is a per-frame sawtooth, and the creep we are
                // hunting (~0.003 s/s) is far smaller than one tooth.
                self?.recordDepthForDrift(span: sample.spanSeconds, snapped: event != nil)
                // Only on a coarse action, never per tick. The clock's lock is already released by
                // the time this value is in hand (it is a return, not a callback, precisely so a
                // log can't run inside the critical section).
                if let event {
                    self?.telemetry.recordClockJump(event.jumped)
                    Self.log(event)
                }
            },
            // DECODE THREAD (renderer.enqueue's caller), after the renderer's queue lock is
            // released. Each firing logs and is counted into `flushed` so the accountant can prove
            // convergence.
            onOverflow: { [weak self] event in
                self?.telemetry.recordClockJump(event.jumped)
                Self.log(event)
            })

        // Clear every per-stream measurement before the first frame of this stream can arrive —
        // the underrun detector's arming flag above all, so a reconnect's startup fill cannot be
        // logged as one giant bogus underrun. See LiveDepthTelemetry.reset().
        telemetry.reset()

        stateLock.lock(); liveClock = clock; stateLock.unlock()

        // ⚠️ INSTALLED HERE, NOT IN startAudio, AND THAT ORDERING IS LOAD-BEARING. The mapping's
        // FIRST change is the initial anchor, which `registerFrame` performs on the first video
        // frame — potentially before the answer is applied and `startAudio` runs. Installing this
        // at activate() means that first anchor is not missed. The engine side no-ops until a
        // live-audio session is open, so an early mapping costs nothing.
        clock.onMappingChange = { [weak self] mapping in
            self?.mirrorLiveAudio?(mapping)
        }

        NSLog("[WHEP] display route ACTIVE — LiveClock target=%.3fs, maxQueued=30, colorimetry assumed 709 SDR",
              Self.targetDepth)
    }

    /// WHEP releases the display. Restores the file-path providers verbatim so playback can resume,
    /// and wipes the last streamed frame (there is usually nothing behind us — same call, same
    /// reason, as NDIService.disconnect).
    func deactivate() {
        dispatchPrecondition(condition: .onQueue(.main))
        // BEFORE the clock is cleared: the receiver reads it, and the engine's live-audio teardown
        // stops the synchronizer. Leaving this until after would let a decode land against a nil
        // clock and stamp a buffer at time 0.
        stopAudio()
        stateLock.lock()
        let wasActive = liveClock != nil
        // Clears the clock's per-STREAM state, freeze-guard arming (`hasPresentedOnce`) included,
        // so a reconnect re-disarms the guard for its own startup fill rather than tripping it.
        // Belt and braces: `activate()` builds a BRAND-NEW LiveClock, so the flag also starts false
        // by construction on every connect — but reset() is the seam that is correct on its own.
        liveClock?.reset()
        // Drop the mapping callback BEFORE releasing the clock: it captures self, and a mapping
        // arriving after teardown would reach a torn-down engine seam.
        liveClock?.onMappingChange = nil
        liveClock = nil
        stateLock.unlock()
        guard wasActive else { return }

        // Restores savedClock / savedIsPaused verbatim, nils onDepthSample + onQueueOverflow (which
        // must not outlive the clock they drive) and maxQueuedOverride, and wipes the last streamed
        // frame. onDisplayTick is deliberately NOT touched — activate() nil'd it and a push source
        // has nothing to restore.
        route.deactivate(renderer: renderer)
        // No picture, so no shape. Ordered AFTER the route teardown and on main, where it cannot be
        // overtaken by a size still hopping in from the decode queue — see LiveDisplaySize's
        // generation counter.
        noRateLogged = false
        declaredFrameRate = nil
        frameRateEstimator.reset()
        rateDisagreementActive = false
        DispatchQueue.main.async { DeckLinkService.shared.setSourceAdvisory(nil) }
        LiveDisplaySize.shared.clear()

        NSLog("[WHEP] display route released — file-playback clock restored")
    }

    /// Release the promote session + pool. DECODE QUEUE ONLY, and it must be scheduled behind every
    /// in-flight frame — WHEPClient does that in the same `decodeQueue.async` block that invalidates
    /// the decoder, for the same reason.
    func releaseResources() {
        transferSession = nil
        pixelBufferPool = nil
        poolSize = (0, 0)
        reportedPromote = false
        framesDelivered = 0
        framesEnqueued = 0
        promoteFailures = 0
        lastFlowLogHost = 0
        lastFlowLogEnqueued = 0

        // Drift state is per-STREAM: a reconnect gets a different sender, and differencing across
        // the gap would manufacture an enormous phantom drift from the discontinuity alone.
        driftLock.lock()
        driftWindowStartHost = 0
        driftWindowMinOffset = .infinity
        previousWindowMinOffset = nil
        previousWindowEndHost = nil
        driftDepthSum = 0
        driftDepthN = 0
        previousWindowMeanDepth = nil
        driftWindowHadSnap = false
        driftLock.unlock()

        telemetry.reset()
    }

    // MARK: - Runtime target adjustment (⌃⌥[ / ⌃⌥], main thread)

    /// Step the live clock's `targetDepth` by `delta`. The whole point is to A/B several cushion
    /// values inside ONE connection, so the underrun accountant's "cushion needed" figures are
    /// comparable against a moving setpoint rather than requiring a reconnect per value.
    ///
    /// The resulting clock jump is fed into the ledger: a target RAISE re-anchors backward, which is
    /// a negative coarse clock action, and leaving it out would trip the residual's OVER flag on a
    /// deliberate keypress. See `LiveDepthTelemetry.recordClockJump`.
    func adjustTargetDepth(by delta: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        stateLock.lock()
        let clock = liveClock
        stateLock.unlock()
        guard let clock else {
            NSLog("[WHEP] no live WHEP session — ⌃⌥[ / ⌃⌥] adjust the WHEP LiveClock target only")
            return
        }
        guard let change = clock.adjustTargetDepth(by: delta) else {
            NSLog("[WHEP] targetDepth already at the %@ (%.3fs) — not stepped",
                  delta > 0 ? "ceiling" : "floor", clock.currentTargetDepth)
            return
        }
        telemetry.recordClockJump(change.jumped)
    }

    // MARK: - Per-frame (decode queue)

    /// One decoded frame → the screen. Called from LiveVideoDecoder.onDecodedFrame, on the decode
    /// queue, with the buffer VideoToolbox produced and the sender-timeline PTS it carried.
    ///
    /// `pts` IS the sender clock: LiveVideoDecoder built it from the RTP 90 kHz timestamp, unwrapped
    /// across the 32-bit wrap by summing signed deltas (`Int32(bitPattern: new &- previous)`, which
    /// is wrap-correct in both directions) and rebased to zero at the first frame. Seconds of that
    /// is exactly what LiveClock.registerFrame wants — the same role the file PTS plays in
    /// SyntheticLiveSource — and LiveClock anchors it to the host clock on the first frame:
    ///
    ///     anchorSenderPTS = firstFrame.senderPTS
    ///     anchorHostTime  = CACurrentMediaTime() + startupDepth
    ///
    /// so a frame comes due `startupDepth` seconds after the first one arrived, then paced 1:1 with
    /// the sender timeline, with the control loop slewing `rate` to hold the buffer at target.
    func deliver(_ decoded: CVPixelBuffer, pts: CMTime) {
        framesDelivered += 1

        stateLock.lock()
        let clock = liveClock
        let renderer = self.renderer
        stateLock.unlock()
        // Not active (a frame racing activate, or arriving after deactivate). Counting it and
        // dropping it is correct — step 3b's counters keep working with no display route at all.
        guard let clock, let renderer else { logFlowIfDue(); return }

        // THE PICTURE'S SHAPE. From the DECODED buffer rather than the format description, and
        // per frame rather than at connect, for two reasons: the format description is built from
        // in-band SPS/PPS that CAN CHANGE MID-STREAM (an SFU switching spatial layer does exactly
        // this, and `updateFormatDescriptionIfNeeded` rebuilds the session for it), and the buffer
        // is what the renderer will actually draw. Placed AFTER the active guard so a frame racing
        // teardown cannot publish a shape for a stream that has already released the display.
        //
        // ⚠️ SQUARE PIXELS STILL ASSUMED — BUT THE REASON HAS CHANGED, AND docs/BUGS.md IS NOW
        // STALE ON THIS POINT. That entry records the assumption as unfixable "because nothing
        // parses the VUI". Something does now: `ManifoldH264ParseSPSTiming` walks this exact VUI
        // to reach the timing fields, and steps over `aspect_ratio_idc` on the way at a named
        // point — `MDSkipAspectRatio` in App/H264/H264SPSTiming.c. The signal is three lines from
        // being readable.
        //
        // It is deliberately NOT read here. Applying SAR means changing `LiveDisplaySize`, the
        // window aspect lock and the framing guides, which is a separate change needing its own
        // measurement against a non-square-pixel sender. The colorimetry assumption beside it is
        // unchanged and genuinely still unparsed.
        //
        // THE RATE, from the ladder: SPS VUI if the encoder declared one, else the measurement if
        // it has settled, else nil. See `WHEPFrameRateEstimator` — including why the old comment
        // here, which claimed RTP timestamps describe transmission rather than capture, was wrong.
        // nil is a real answer and reaches the menu as "Follow source — unavailable".
        let rate = frameRateToPublish(senderPTS: CMTimeGetSeconds(pts))
        LiveDisplaySize.shared.publish(width: CVPixelBufferGetWidth(decoded),
                                       height: CVPixelBufferGetHeight(decoded),
                                       frameRate: rate)

        let senderPTS = CMTimeGetSeconds(pts)
        guard senderPTS.isFinite else { logFlowIfDue(); return }

        // Sender-vs-receiver clock measurement. Deliberately placed BEFORE registerFrame, on the
        // raw arrival: this reading must describe the transport, not our correction of it.
        recordDriftSample(senderPTS: senderPTS, clock: clock)
        // Surplus accounting, same placement and same reason: content produced is a property of
        // the sender, and must be counted before we correct for it.
        //
        // ONE `now()` READ, SHARED. Both the ledger's inBuffer and the underrun lateness are
        // differences against the clock AT THIS INSTANT, so they must use the SAME reading — two
        // separate `now()` calls would be microseconds apart and would silently stop being
        // comparable. It is also one lock acquisition instead of two, on the same lock
        // `registerFrame` takes immediately below.
        let clockNow = clock.now()
        let target = clock.currentTargetDepth
        telemetry.recordArrival(senderPTS: senderPTS, clockNow: clockNow)
        // Closes a starvation episode the render thread opened, if one is open. No-op otherwise,
        // which is the overwhelmingly common case.
        telemetry.closeUnderrunIfOpen(senderPTS: senderPTS, clockNow: clockNow, target: target)

        // Sender timeline → presentation timeline. Identity at rate 1.0; a genuine remap once the
        // control loop has slewed. Register BEFORE the promote so the anchor is established from
        // the arrival instant rather than after a conversion.
        let presentationPTS = clock.registerFrame(senderPTS: senderPTS)

        guard let promoted = promoteIfNeeded(decoded) else {
            promoteFailures += 1
            logFlowIfDue()
            return
        }
        // Tag the buffer every downstream consumer actually reads (shader matrix, layer colorspace,
        // scopes, EDR gate). A pooled buffer starts untagged and VT's attachment propagation is
        // measured behavior rather than a documented contract, so tagging the OUTPUT last is the
        // ordering that holds either way — NDIService.tagOutput's reasoning, verbatim.
        NDIColorInfo.assumedRec709.apply(to: promoted)

        guard let sampleBuffer = Self.makeSampleBuffer(
                promoted,
                pts: CMTime(seconds: presentationPTS, preferredTimescale: 1_000_000)) else {
            logFlowIfDue()
            return
        }

        renderer.enqueue(sampleBuffer)
        framesEnqueued += 1
        logFlowIfDue()
    }

    // MARK: - Promote (decode queue)

    /// 8-bit → the renderer's 10-bit sample domain, via the SAME VTPixelTransferSession shape NDI
    /// uses (NDIService.convertToDisplayFormat). Destination is x420 — 10-bit biplanar 4:2:0 — so
    /// 4:2:0 in becomes 4:2:0 out with no chroma resample; the 8→10 promotion is an exact ×4 code
    /// shift, not a filter. That is the format the file path already produces and the format
    /// PassthroughShader.metal's range-expansion constants (kCodeMax = 1023.984375) assume.
    ///
    /// A NO-OP when VideoToolbox already gave us 10-bit: LiveVideoDecoder REQUESTS x420 output and
    /// only falls back to VT's native 8-bit choice if the session refuses it. When the request
    /// succeeds there is nothing to promote and the decoded buffer goes straight through, which is
    /// why this is `promoteIfNeeded` and not an unconditional conversion.
    private func promoteIfNeeded(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        if sourceFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || sourceFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
            if !reportedPromote {
                reportedPromote = true
                NSLog("[WHEP] decoded as %@ — already in the renderer's 10-bit domain, no promote needed",
                      LiveVideoDecoder.formatName(sourceFormat))
            }
            return source
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)

        if transferSession == nil {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                      pixelTransferSessionOut: &session)
            guard status == noErr, let session else {
                NSLog("[WHEP] VTPixelTransferSessionCreate failed (%d) — no picture", status)
                return nil
            }
            transferSession = session
        }
        guard let transferSession else { return nil }

        if pixelBufferPool == nil || poolSize != (width, height) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
            ]
            // MinimumBufferCount matches SyntheticLiveSource's pool: maxQueued (30) + the in-flight
            // frame + lead. A pool that recycles a small FIXED IOSurface set is what keeps the render
            // thread re-mapping known surfaces instead of first-mapping a fresh one every frame.
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 34]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                                 attrs as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                NSLog("[WHEP] CVPixelBufferPoolCreate failed (%d) — no picture", status)
                return nil
            }
            pixelBufferPool = pool
            poolSize = (width, height)
        }
        guard let pixelBufferPool else { return nil }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &destination)
                == kCVReturnSuccess, let destination else { return nil }

        // Tag the SOURCE before the transfer, so VT converts from a buffer whose colorimetry is
        // stated rather than absent. (The output is re-tagged after, in `deliver` — see there.)
        NDIColorInfo.assumedRec709.apply(to: source)

        let status = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination)
        guard status == noErr else {
            NSLog("[WHEP] pixel transfer failed (%d)", status)
            return nil
        }

        if !reportedPromote {
            reportedPromote = true
            NSLog("[WHEP] promoting %@ → 'x420' (10-bit 4:2:0) at %dx%d — the shader's sample domain",
                  LiveVideoDecoder.formatName(sourceFormat), width, height)
        }
        return destination
    }

    // MARK: - Drift measurement (decode queue + render thread, under driftLock)

    /// Fold one frame's (senderPTS, arrival) pair into the current window, and close the window
    /// when it is due. Decode queue. See the field block above for the derivation.
    private func recordDriftSample(senderPTS: Double, clock: LiveClock) {
        #if DEBUG || MANIFOLD_TELEMETRY
        let host = CACurrentMediaTime()
        let offset = host - senderPTS

        driftLock.lock()
        if driftWindowStartHost == 0 {
            driftWindowStartHost = host
            driftWindowMinOffset = offset
            driftLock.unlock()
            return
        }
        driftWindowMinOffset = min(driftWindowMinOffset, offset)
        guard host - driftWindowStartHost >= Self.driftWindow else {
            driftLock.unlock()
            return
        }

        // Close the window: snapshot everything, re-arm, then report OUTSIDE the lock.
        let minOffset = driftWindowMinOffset
        let previousMin = previousWindowMinOffset
        let previousEnd = previousWindowEndHost
        let meanDepth = driftDepthN > 0 ? driftDepthSum / Double(driftDepthN) : nil
        let previousMeanDepth = previousWindowMeanDepth
        let hadSnap = driftWindowHadSnap

        previousWindowMinOffset = minOffset
        previousWindowEndHost = host
        previousWindowMeanDepth = meanDepth
        driftWindowStartHost = host
        driftWindowMinOffset = .infinity
        driftDepthSum = 0
        driftDepthN = 0
        driftWindowHadSnap = false
        driftLock.unlock()

        // First window has no predecessor to difference against.
        guard let previousMin, let previousEnd else { return }
        let dt = host - previousEnd
        guard dt > 0 else { return }

        // senderRatio = 1 − d(offset)/dt. > 1 means the SENDER is fast: it produces media time
        // faster than we consume it at unity, so the buffer fills — the creep direction observed.
        let senderRatio = 1.0 - (minOffset - previousMin) / dt
        let senderTicksPerSecond = 90_000.0 * senderRatio
        let driftPercent = (senderRatio - 1.0) * 100.0

        // `rate` is written under the clock's lock on the render thread and read here unlocked —
        // the same benign telemetry race `logFlowIfDue` already accepts. Taking the clock's lock
        // from the decode queue to read one Double for a log line would be the worse trade.
        let rate = clock.rate
        let atRail = abs(abs(rate - 1.0) - clock.maxSlew) < 1e-6
        // What the buffer MUST do given a sender at `senderRatio` and a clock running at `rate`.
        let predictedCreep = senderRatio - rate

        // Deferred-initialized lets (assigned exactly once on every path) rather than vars —
        // the compiler would flag a never-mutated var.
        let verdict: String
        let creepText: String
        if hadSnap {
            // Honest refusal: the window contains a discontinuity, so its creep describes the
            // snap. The sender rate above is still valid — it never touches the anchor.
            creepText = "n/a (snap in window)"
            verdict = "creep not comparable this window"
        } else if let meanDepth, let previousMeanDepth {
            let observedCreep = (meanDepth - previousMeanDepth) / dt
            let residual = observedCreep - predictedCreep
            creepText = String(format: "%+.4f s/s observed vs %+.4f predicted (residual %+.4f)",
                               observedCreep, predictedCreep, residual)
            // Tolerance: the larger of an absolute floor (below which we are reading window-to-
            // window noise, not a bias) and a relative share of the predicted magnitude.
            let tolerance = max(0.0008, abs(predictedCreep) * 0.35)
            verdict = abs(residual) <= tolerance
                ? "REAL DRIFT — creep matches the measured sender rate"
                : "MISMATCH — creep does not follow the sender rate; suspect measurement bias"
        } else {
            creepText = "n/a (no depth samples)"
            verdict = "creep unavailable"
        }

        // `need` is the headline number STEP 2 is waiting on: the slew the loop must be ABLE to
        // reach just to break even. Whatever maxSlew is chosen must exceed this, with margin on
        // top for the loop to have correction authority left over rather than sitting on a new rail.
        NSLog("""
              [WHEP-DRIFT] senderRate=%.0f tps (%+.3f%% vs receiver) | clockRate=%.4f (%+.3f%%%@) \
              | depthCreep=%@ | %@ | need maxSlew ≥ %.3f%% + margin
              """,
              senderTicksPerSecond, driftPercent,
              rate, (rate - 1.0) * 100.0, atRail ? ", RAIL" : "",
              creepText, verdict, abs(driftPercent))
        #endif
    }

    /// Render thread. Accumulates the window's mean depth and latches whether a coarse clock
    /// action occurred inside it.
    private func recordDepthForDrift(span: Double, snapped: Bool) {
        #if DEBUG || MANIFOLD_TELEMETRY
        driftLock.lock()
        driftDepthSum += span
        driftDepthN += 1
        if snapped { driftWindowHadSnap = true }
        driftLock.unlock()
        #endif
    }

    // MARK: - Latency-control reporting (render thread, coarse actions only)

    /// One line per coarse clock action. These are RARE and each one is a real event in the
    /// session's latency story, so they are logged unconditionally rather than folded into the
    /// 1 Hz flow line — a snap that fires the moment the sender resumes should be visible at that
    /// moment, next to the [LIVECLOCK] line whose depth it just changed.
    private static func log(_ event: LiveClock.Event) {
        #if DEBUG || MANIFOLD_TELEMETRY
        switch event {
        case .snapped(let snap):
            NSLog("[WHEP] snap-to-live: flushed %.3fs excess (depth %.3f → %.3f) after %.2fs sustained overfill",
                  snap.excess, snap.depthBefore, snap.depthAfter, snap.sustainedFor)
        case .freezeGuard(let fg):
            // The safety net fired. This should be RARE — it means the clock reached a position it
            // could not leave on its own, and every occurrence is worth explaining rather than
            // counting. Distinct prefix from the queue-full line below.
            NSLog("""
                  [WHEP] FREEZE-GUARD: clock had fallen behind the entire queue — no eligible \
                  frame for %d ticks / %.3fs with %d queued (oldest +%.3fs ahead). Re-anchored \
                  +%.3fs (depth %.3f → %.3f).
                  """, fg.ticks, fg.heldFor, fg.queued, fg.oldestAhead,
                  fg.jumped, fg.depthBefore, fg.target)
        case .overflowReanchor(let ov):
            // Expected, repeatedly, during a connect backlog drain — NOT a fault. One line each,
            // no debounce, so the sequence can be counted in the log and confirmed to stop once
            // [WHEP-BACKLOG] shows surplus going flat.
            NSLog("[WHEP] queue-full re-anchor: over-buffered at count=%d — flushed %.3fs (depth %.3f → %.3f)",
                  ov.queued, ov.jumped, ov.depthBefore, ov.target)
        }
        #endif
    }

    // MARK: - Helpers

    /// Wrap a pixel buffer in a ready CMSampleBuffer at `pts`.
    ///
    /// NOT SHAREABLE WITH NDIService / SyntheticLiveSource, despite the same three CoreMedia calls
    /// — this comment used to claim "same call, same arguments" and that was wrong. The ARGUMENTS
    /// differ in ways that are not cosmetic:
    ///   * NDIService takes `pts: Double` and builds `CMTime(seconds:preferredTimescale: 90_000)`
    ///     internally; this one takes a CMTime the caller built at timescale 1_000_000.
    ///   * SyntheticLiveSource passes a REAL duration (not .invalid) and `allocator: nil`.
    /// Unifying them would re-quantise one path's PTS, and those PTS values feed the renderer's
    /// ordered insert and its median inter-frame-Δ tracking — i.e. the depth signal LiveClock
    /// regulates. Left as three, deliberately.
    ///
    /// Duration is .invalid:
    /// RTP does not carry one, the renderer selects on PTS alone, and a fabricated duration would be
    /// a guess nothing reads.
    ///
    /// DTS is .invalid, and NOT because the sender has no B-frames — this comment used to say that,
    /// which would make it wrong the moment a reordering stream arrived (SRT). The real reason is
    /// that by this point there is no decode order left to describe: the input was a compressed
    /// access unit whose DTS said when to DECODE it, and what is being wrapped here is the decoded
    /// picture that came out. Its only remaining property is when to SHOW it, which is the PTS.
    /// Nothing downstream reads the output DTS, and there is no honest value to put in it.
    private static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    /// 1 Hz `[WHEP-FLOW]`. This is the staged-diagnosis line: if no pixels appear, it says WHICH
    /// stage is empty. delivered > 0 with enqueued == 0 means the promote or the sample build is
    /// failing (promoteFail counts the first). Both climbing with depth/count at zero means frames
    /// reach the queue but the clock never lets them come due. Both climbing with a healthy depth
    /// and still no picture puts the problem downstream of enqueue, in the renderer.
    ///
    /// LiveClock prints its own `[LIVECLOCK] depth/target/rate/err` line at the same cadence; this
    /// one deliberately repeats depth/count so the producer and consumer sides can be read as a pair
    /// without interleaving two logs. Decode queue only.
    /// RUNG 1. The exact rate from the SPS VUI, latched the first time an SPS parses with timing
    /// info. Non-nil wins over the estimator permanently for this connection — the encoder's own
    /// declaration cannot be improved on by measuring it.
    private var declaredFrameRate: Double?
    /// RUNG 2. Decode-queue only, like everything else `deliver` touches.
    ///
    /// ⚠️ RUNS EVEN WHEN RUNG 1 HAS ANSWERED. It used to be skipped once the SPS declared a rate,
    /// on the reasoning that an exact value cannot be improved by measuring it. True, and beside
    /// the point: the measurement's second job is to CHECK the declaration. See `crossCheckRate`.
    private var frameRateEstimator = WHEPFrameRateEstimator()
    /// Whether declared and measured currently disagree beyond the threshold. Edge-triggered, like
    /// the renderer's raster mismatch — logged and surfaced on entry, retracted on exit.
    private var rateDisagreementActive = false
    /// Relative disagreement between the SPS's declared rate and the measured one that counts as
    /// real. 2%, matching `WHEPFrameRateEstimator.maxRelativeSpread` — see `crossCheckRate`.
    private static let rateDisagreementThreshold = 0.02
    /// One "no rate yet" line per connection rather than one per frame.
    private var noRateLogged = false

    /// RUNG 1 — an SPS arrived; try for the encoder's own declared cadence.
    ///
    /// Called from `WHEPClient`'s access-unit closure on the decode queue whenever the parameter
    /// sets change (which includes the first set of the connection). Cheap: a few hundred bits of
    /// exp-Golomb, and only on parameter-set changes, not per frame.
    ///
    /// LATCH-ONCE per connection. A mid-stream SPS change from an SFU layer switch re-sends the
    /// same timing in practice, and re-parsing to the same answer would only add log noise; a
    /// genuinely different declared rate is rare enough that inheriting the first is the
    /// conservative choice, and the estimator is still running underneath as a cross-check.
    func noteParameterSets(sps: Data) {
        guard declaredFrameRate == nil else { return }
        let timing: ManifoldH264SPSTiming = sps.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return ManifoldH264SPSTiming()
            }
            return ManifoldH264ParseSPSTiming(base, sps.count)
        }
        guard timing.valid else {
            // Ordinary, not a fault: VUI is optional and timing_info_present_flag is often 0.
            print("[WHEP-FORMAT] SPS carries no VUI timing info — falling through to measurement")
            return
        }
        declaredFrameRate = timing.framesPerSecond
        print(String(format: "[WHEP-FORMAT] frame rate %.3f fps from SPS VUI timing (EXACT) — "
                             + "time_scale=%u / (2 * num_units_in_tick=%u), fixed_frame_rate_flag=%@. "
                             + "DeckLink Follow source can use it.",
                     timing.framesPerSecond, timing.timeScale, timing.numUnitsInTick,
                     timing.fixedFrameRate ? "1" : "0"))
    }

    /// ── THE CROSS-CHECK: DOES THE SENDER DO WHAT IT SAYS? ───────────────────────────────────
    ///
    /// Rung 1 still WINS — the declared rate is what gets published — but the estimator now runs
    /// underneath it instead of being skipped, and a disagreement is stated.
    ///
    /// ⚠️ WHY THIS IS WORTH THE CODE: "A PUBLISHER DECLARING ONE CONFIGURATION WHILE SENDING
    /// ANOTHER, WITH EVERY COUNTER CLEAN" IS A REPEAT PATTERN IN THIS APP, NOT A HYPOTHETICAL.
    /// It is exactly the 5.1-Opus failure in docs/BUGS.md: OBS configured for 5.1 while the
    /// negotiated answer was `opus/48000/2`, nothing in the pipeline wrong, every counter healthy,
    /// and the only symptom was that the result was not what the operator had set up. That entry's
    /// conclusion was that an undetectable misconfiguration must at least be STATED IN THE UI.
    ///
    /// Here it is not undetectable. The instrument already exists — the estimator was built for
    /// rung 2 — and running it alongside rung 1 costs one subtraction per frame. Declining to look
    /// would be choosing not to know something we are already equipped to see.
    ///
    /// ⚠️ IT REPORTS, IT DOES NOT ACT. No override, no fallback, no refusal. The declared value is
    /// the SENDER'S STATED INTENT, and the measurement is the degradable one — packet loss, an SFU
    /// layer switch, a congested encoder all pull the measured rate down while the declaration
    /// stays correct. Preferring the measurement would mean letting a bad network silently change
    /// the cadence on the wire. So: publish the declaration, say the two disagree, let the operator
    /// decide which to believe.
    ///
    /// THE THRESHOLD IS 2%, the same number as the estimator's own spread gate. That is the point
    /// of choosing it: `measured` is only ever non-nil when its samples fell inside a 2% band, so a
    /// disagreement WIDER than that band is outside the measurement's own confidence and cannot be
    /// explained by its noise. 29.97 vs 30 is 0.1% and can never trip it; 24 vs 25 is 4.2% and
    /// always will.
    ///
    /// Edge-triggered — logged and surfaced when it starts, retracted when it stops — so a loss
    /// burst that resolves does not leave a stale warning on screen.
    private func crossCheckRate(declared: Double, measured: Double?) {
        guard let measured else { return }
        let disagreement = abs(measured - declared) / declared
        let nowDisagreeing = disagreement > Self.rateDisagreementThreshold
        guard nowDisagreeing != rateDisagreementActive else { return }
        rateDisagreementActive = nowDisagreeing

        if nowDisagreeing {
            let line = String(format: "SPS declares %.3f fps but measured %.3f fps over 120 frames "
                                      + "(%.1f%% disagreement) — using the declared rate; the "
                                      + "publisher may be misconfigured.",
                              declared, measured, disagreement * 100)
            print("[WHEP-FORMAT] ⚠️ " + line)
            // The UI half. Short enough for a menu row; the log carries the full sentence.
            let advisory = String(format: "Source declares %.3f fps but is sending %.3f fps — "
                                          + "output follows the declared rate.", declared, measured)
            DispatchQueue.main.async { DeckLinkService.shared.setSourceAdvisory(advisory) }
        } else {
            print(String(format: "[WHEP-FORMAT] declared and measured rates now agree "
                                 + "(%.3f vs %.3f fps) — earlier disagreement retracted.",
                         declared, measured))
            DispatchQueue.main.async { DeckLinkService.shared.setSourceAdvisory(nil) }
        }
    }

    /// RUNG 2 + 3 — feed the estimator and decide what, if anything, to publish this frame.
    /// Returns the rate for `LiveDisplaySize`, or nil to refuse. Decode queue only.
    private func frameRateToPublish(senderPTS: Double) -> Double? {
        // ⚠️ UNCONDITIONAL, AND THAT IS THE CHANGE. The estimator runs whether or not rung 1 has
        // answered, because when it has, this is the cross-check instrument rather than the source
        // of the published value.
        let changed = frameRateEstimator.record(senderPTS: senderPTS)
        let measured = frameRateEstimator.estimate

        // Rung 1 still wins outright — but it is now checked rather than merely trusted.
        if let declaredFrameRate {
            crossCheckRate(declared: declaredFrameRate, measured: measured)
            return declaredFrameRate
        }

        if changed {
            if let measured {
                print(String(format: "[WHEP-FORMAT] frame rate %.3f fps MEASURED over a 120-frame "
                                     + "window of RTP sender timestamps (intervals ÷ span, fit "
                                     + "residual %.2f%%, raw spread %.2f%%, %d sample(s) outside the "
                                     + "trim) — estimated, not declared. Follow source can use it.",
                             measured, frameRateEstimator.lastFitResidual * 100,
                             frameRateEstimator.lastSpread * 100,
                             frameRateEstimator.discardedAsMultiples))
            } else if frameRateEstimator.lastFitResidual.isFinite {
                print(String(format: "[WHEP-FORMAT] no stable rate (gaps fit no constant interval — "
                                     + "worst residual %.2f%% exceeds the 2%% threshold; raw spread "
                                     + "%.2f%%) — REFUSING to publish one. This stream may be "
                                     + "variable-rate; a guessed cadence on SDI would look "
                                     + "deliberate. Follow source unavailable, pick a mode by hand.",
                             frameRateEstimator.lastFitResidual * 100,
                             frameRateEstimator.lastSpread * 100))
            } else {
                print("[WHEP-FORMAT] no stable rate (only "
                    + "\(frameRateEstimator.keptCount) of 120 samples were single-frame intervals; "
                    + "\(frameRateEstimator.discardedAsMultiples) were dropped-frame multiples) — "
                    + "REFUSING to publish one. This window measured packet loss, not cadence. "
                    + "Follow source unavailable, pick a mode by hand.")
            }
        } else if measured == nil && !noRateLogged {
            noRateLogged = true
            print("[WHEP-FORMAT] no frame rate yet — SPS declared none and the measurement window "
                + "is still filling. Follow source unavailable until it settles.")
        }
        return measured
    }

    private func logFlowIfDue() {
        #if DEBUG || MANIFOLD_TELEMETRY
        let now = CACurrentMediaTime()
        if lastFlowLogHost == 0 { lastFlowLogHost = now; lastFlowLogEnqueued = framesEnqueued; return }
        let elapsed = now - lastFlowLogHost
        guard elapsed >= 1.0 else { return }
        let rate = Double(framesEnqueued - lastFlowLogEnqueued) / elapsed
        lastFlowLogHost = now
        lastFlowLogEnqueued = framesEnqueued

        stateLock.lock(); let clockRate = liveClock?.rate; stateLock.unlock()
        NSLog("[WHEP-FLOW] enqueued=%.1f/s (total=%d, delivered=%d, promoteFail=%d) | depth=%.3fs count=%d rate=%@",
              rate, framesEnqueued, framesDelivered, promoteFailures,
              lastDepthSpan, lastDepthCount,
              clockRate.map { String(format: "%.4f", $0) } ?? "inactive")
        #endif
    }
}
