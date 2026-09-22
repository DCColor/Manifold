//
//  HLSClient.swift
//  Manifold
//
//  HLS as a source: QC on the EGRESS side — what the platform actually PUBLISHED, after its
//  transcode, at its latency. See "⏸ BANKED: HLS as a source" in docs/BUGS.md, whose gate this
//  builds against.
//
//  ── ⚠️ THIS IS A PULL SOURCE, MODELLED ON NDI, AND THAT CHOICE DECIDES EVERYTHING BELOW ──────
//
//  `AVPlayer` owns the pacing. It fetches segments, decodes, and re-times on its own schedule, and
//  `AVPlayerItemVideoOutput` vends whatever is current when we ask. So this is NDI's shape — pull
//  on `renderer.onDisplayTick`, a free-running monotonic clock — and NOT WHEP's or SRT's. It does
//  NOT use `LiveDisplayRoute`: that type is the PUSH axis, and its `LiveClock` + depth control loop
//  regulate a queue we do not fill and a cadence we do not own. There is nothing here for them to
//  control, and installing them would be a control loop with no actuator.
//
//  The measured shape is in docs/BUGS.md ("✅ MEASURED 2026-08-29"): 597 frames in 25 s at 23.9 fps,
//  ZERO empty pulls, ZERO repeated display times, `copyPixelBuffer` at 0.1 ms mean / 4.7 ms max,
//  and the buffer arriving as **x420 — the app's own decode contract** (`FrameEngine`'s
//  `videoPixelFormat`), so it reaches `enqueue` with no conversion and lands in the offscreen ring
//  the scopes read. NDI needs a `VTPixelTransferSession` to get there; this does not.
//
//  ── ⚠️ AND IT DECIDES THE TEARDOWN, WHICH IS NDI'S AND NOT SRT'S ─────────────────────────────
//
//  Hanging the pull on the renderer's tick means WE DO NOT OWN THE THREAD THAT CAN DELIVER A FRAME.
//  The CVDisplayLink belongs to `MetalVideoRenderer` and keeps running across a source swap, so
//  there is NO JOIN AVAILABLE — `renderer.onDisplayTick = nil` is a store the render thread may
//  already have raced past. SRT can join because it owns its session thread; we cannot, and
//  half-adopting SRT's discipline here would be worse than not having it, because it would read
//  like a guarantee that is not being made.
//
//  So this follows NDI exactly: AN IN-FLIGHT TICK IS MADE HARMLESS BY CONSTRUCTION.
//
//    * the hook captures `[weak self]`, so a tick after this object dies does nothing;
//    * it re-reads `pull` through the guard, so a tick after teardown finds nil and returns;
//    * a tick that ALREADY PASSED that guard holds a strong `HLSPull` — ARC keeps the object
//      alive for the duration of the call — and `HLSPull.capture()` checks its own `retired`
//      flag FIRST and returns nil without touching AVFoundation at all.
//
//  That last point is the whole safety property, and it is why `retire()` is on `HLSPull` rather
//  than inlined here: the flag and the objects it protects are the same lifetime, so there is no
//  window in which one is gone and the other is still reachable. The equivalent in NDI is
//  `captureVideoFrame()` returning nil on a disconnected bridge.
//
//  ── HLS → HLS IS A SWAP, ON NDI'S RULE ───────────────────────────────────────────────────────
//
//  See `connect(to:arbitratedBy:)`. Not SRT's swap (that one is safe because of a join we do not
//  have) and not WHEP's refusal (which exists because WHEP cannot even sequence its teardown
//  safely). NDI's: retire the old pull and stand the new one up IN THE SAME MAIN-THREAD TURN, so
//  `isConnected` never dips to false and the control bar and empty state never flicker.
//

import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import ManifoldCore
import QuartzCore

// MARK: - The retirable half

/// The AVFoundation objects, plus the one flag that makes an in-flight display tick harmless.
///
/// ⚠️ THIS TYPE EXISTS FOR ITS LIFETIME, NOT ITS FIELDS. Bundling player/item/output into one
/// object is what lets a tick take a strong reference to ALL of them in a single `guard let` — the
/// property ARC gives us for free and which three separate optionals on the service would not. See
/// the teardown note in the file header.
///
/// THREADING: `retired` is written on main (`retire()`) and read on the CVDisplayLink thread
/// (`capture()`), so it takes a lock. That is the same idiom `AVPlayerScrubProducer` uses for its
/// `closed` flag and for the same reason — an unsynchronised `Bool` here is a torn read on the one
/// path that must never touch a dying `AVPlayerItemVideoOutput`. One uncontended lock per tick.
private final class HLSPull: @unchecked Sendable {

    let player: AVPlayer
    let item: AVPlayerItem
    let output: AVPlayerItemVideoOutput

    /// The audio tap for this session, or nil when no `AudioTapBuffer` was wired (no host deck) or
    /// the tap could not be created. Owned here BECAUSE IT SHARES THIS OBJECT'S LIFETIME — the same
    /// reason player/item/output are bundled: one `guard let` in the retirement path takes all of
    /// them, and `retire()` below is the single site that stands them all down in order.
    let audioTap: HLSAudioTap?

    private let retiredLock = NSLock()
    private var _retired = false
    private var retired: Bool { retiredLock.lock(); defer { retiredLock.unlock() }; return _retired }

    init(url: URL, pixelFormat: OSType, audioSink: AudioTapBuffer?,
         monitorMuted: Bool, monitorVolume: Float) {
        // ⚠️ NO `AVURLAssetPreferPreciseDurationAndTimingKey`. `AVPlayerScrubProducer` asks for it
        // on FILE urls only, with the note that it "forces a walk an HLS playlist cannot cheaply
        // serve". This is that case, stated from the other side.
        let asset = AVURLAsset(url: url)
        item = AVPlayerItem(asset: asset)
        // x420 — `FrameEngine.videoPixelFormat`, the app's decode contract. MEASURED as what an
        // HLS item actually vends (docs/BUGS.md), so this is honoured rather than hoped for; if a
        // future stream refuses it, `logFirstFrame` says so out loud instead of guessing.
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)

        // ── ⚠️ NOT MUTED, AND THE MUTE IS THE OPPOSITE OF WHAT IT LOOKS LIKE. MEASURED. ──────
        //
        // This line was `player.isMuted = true` while HLS shipped picture-only, where it cost
        // nothing. IT IS NOT A MUTE IN THE SENSE THAT COMMENT IMPLIED, and leaving it would now
        // break far more than the speakers: `AVPlayer.isMuted` sits UPSTREAM of an
        // `MTAudioProcessingTap`, so with it set the callbacks still fire at full rate and every
        // buffer is ZEROS — measured three times, 238/238 buffers, peak exactly 0.0. It would take
        // the METERS and the SDI EMBED down with it, silently, while every status line still
        // reported success.
        //
        // `AVPlayer.volume` likewise SCALES what the tap sees (−35.7 dBFS at volume 0.02 against
        // −1.8 dBFS at 1.0 on the same source buffer), so it is pinned at 1.0 rather than left to
        // whatever a caller might set: an attenuated player would make the meters read low, which
        // is a lie told by an instrument.
        //
        // So these two lines now serve the tap first and the speakers second. HLS IS AUDIBLE ON
        // THE DESKTOP, played by AVFoundation's own output — the tap passes its samples through
        // rather than consuming them.
        //
        // ⚠️ AND THEY MUST STAY AT THESE VALUES FOREVER. THE MUTE AND THE FADER DO REACH HLS, BUT
        // NOT THROUGH HERE. `HLSAudioTap.setMonitor` applies the engine's decision at the TAP'S
        // OUTPUT, precisely so the tap keeps seeing full-scale signal — routing the mute to
        // `player.isMuted` would blank the meters and SDI, and routing the fader to
        // `player.volume` would make the meters follow the monitoring level, which no other source
        // in this app does. Wiring the controls here instead would look tidier and would be the
        // bug. The measurements are on `HLSAudioTap.setMonitor`.
        player.isMuted = false
        player.volume = 1.0

        // The tap rides on the item's audio mix. Built BEFORE `startPlayback`, and harmless when
        // `audioSink` is nil (no host deck): `HLSAudioTap` is simply never constructed and the
        // stream is video-only exactly as it was before this arc.
        if let audioSink {
            let tap = HLSAudioTap(output: output, sink: audioSink)
            // SEEDED BEFORE A SINGLE CALLBACK CAN FIRE. Connecting a stream while the app is
            // already muted, or with the fader down, or with SDI owning the audio, must not
            // produce a burst at full volume before the first `externalAudioOutput` push arrives.
            // The state is cached on `HLSClient` for exactly this moment; see `applyAudioOutput`.
            tap.setMonitor(muted: monitorMuted, volume: monitorVolume)
            audioTap = tap
            // MEASURED to work attached either before or after `.readyToPlay`; here is simply the
            // point at which the item and the tap are both in hand.
            item.audioMix = tap.audioMix
        } else {
            audioTap = nil
            NSLog("[HLS-AUDIO] no AudioTapBuffer wired for this deck — stream stays VIDEO ONLY")
        }

        // ── ⚠️ `automaticallyWaitsToMinimizeStalling` IS DELIBERATELY LEFT AT ITS DEFAULT ────
        //
        // It was previously set to `false` here, copied from `AVPlayerScrubProducer`, and that was
        // a real bug with a two-part failure. THE COPY WAS WRONG BECAUSE THE TWO PLAYERS ARE NOT
        // THE SAME KIND OF OBJECT: that one is "a DECODER, NOT A TRANSPORT" — rate 0, no layer,
        // seeked by hand — and the flag is correct there precisely so it "can never … wait on a
        // buffer for a picture nobody is playing". THIS one IS a transport. It has to wait on a
        // buffer; that is what playing a stream is.
        //
        // WHAT `false` ACTUALLY DID, from AVPlayer.h's own discussion:
        //
        //   "setting rate to a non-zero value in AVPlayerTimeControlStatusPaused will cause
        //    playback to start immediately AS LONG AS THE PLAYBACK BUFFER IS NOT EMPTY"
        //
        // At connect the buffer IS empty — the manifest has not been fetched — so `play()` did
        // nothing. And there was no recovery, because the same discussion says that with the flag
        // NO, "reasonForWaitingToPlay cannot assume a value of AVPlayerWaitingToMinimizeStalls
        // Reason": there is no waiting state to complete later. The item's timebase therefore
        // never ran, `itemTime(forHostTime:)` returned a CONSTANT, and since `copyPixelBuffer`
        // "marks the image as acquired" while `hasNewPixelBuffer` only reports output "not marked
        // as acquired", exactly ONE frame was ever delivered and the picture never advanced.
        //
        // The default (`true`) is what makes a live transport survive: `play()` on an unready item
        // parks in `.waitingToPlayAtSpecifiedRate` and starts by itself once enough is buffered,
        // and a MID-STREAM STALL does the same rather than — as `false` specifies — switching to
        // Paused with the rate stuck at 0.0 and nothing to restart it.
        //
        // ⚠️ THE DEFAULT IS NOT A LICENCE TO SKIP THE READY-WAIT. It would have MASKED the missing
        // one, which is a different thing: `HLSClient.connect` still arms nothing until the item
        // reports `.readyToPlay`, because a pull against an unready timebase is the bug above and
        // relying on this flag to paper over it is how it comes back.
    }

    /// One tick's worth of picture, or nil. ANY THREAD — called from the CVDisplayLink.
    ///
    /// nil is the ordinary answer between frames: at 60 Hz against a 25 fps ladder most ticks have
    /// nothing new, and `hasNewPixelBuffer` is the cheap way to say so. Enqueuing nothing is
    /// correct — the renderer keeps displaying the frame it has (same contract as NDI's).
    /// Returns the buffer AND the item time it was taken at. The caller needs the timestamp to
    /// measure the source's cadence (`FrameRateEstimator`) — HLS declares no frame rate anywhere in
    /// the manifest or the item, so the only honest answer is a measured one, and this is the only
    /// place the timeline is read.
    func capture() -> (buffer: CVPixelBuffer, itemTime: CMTime)? {
        // FIRST, BEFORE ANY AVFOUNDATION CALL. This is the line that makes a tick which raced the
        // teardown harmless rather than merely unlikely.
        guard !retired else { return nil }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return nil
        }
        return (buffer, itemTime)
    }

    /// What this item can honestly say about its own timeline. THREE states, not two, and keeping
    /// them distinct is the entire fix — see `HLSClient.logLiveLatency`.
    enum TimelineReading {
        /// A live playlist: how far the picture sits behind the live edge, in seconds.
        case live(behindEdge: Double)
        /// A VOD playlist: position within a finite asset. NOT a latency, and never reported as one.
        case vod(position: Double, duration: Double)
        /// The item cannot answer yet (not ready) or at all (retired, broken). NOT VOD.
        case unknown
    }

    /// ── ⚠️ THE LIVE/VOD TEST IS `duration`, AND IT WAS PREVIOUSLY ABSENT ────────────────────
    ///
    /// `AVPlayerItem.duration` is `kCMTimeIndefinite` for a live playlist and FINITE for VOD. That
    /// is the whole test, it is one line, and this function did not make it.
    ///
    /// What it did instead was read `seekableTimeRanges.last.end` and call the answer a live edge.
    /// For a live playlist that IS the live edge. For VOD the seekable range is the WHOLE ASSET, so
    /// the same arithmetic returns TIME REMAINING — which on Apple's bipbop VOD stream reported
    /// **"the picture is 1790.7 s behind the live edge"** ten seconds in. Arithmetically correct,
    /// semantically meaningless, and stated with total confidence.
    ///
    /// ⚠️ `.readyToPlay` IS CHECKED FIRST AND IT IS LOAD-BEARING, NOT DEFENSIVE. An item that has
    /// not reached ready ALSO reports `duration == .indefinite` — so without this guard the test
    /// above would classify every not-yet-ready item as live and start reporting a live-edge delay
    /// computed from a timeline it does not have yet. The unready case is `.unknown`, which is a
    /// third answer precisely because it is neither of the other two.
    ///
    /// The harness this feature was measured with has always made this test —
    /// `docs/scrub-fixtures/avpvomeas.swift`: `if dur.isFinite && dur > 5 { … } else { "LIVE
    /// playlist, not seekable this way" }`. It is the second check from that file that was not
    /// carried across (the `readyToPlay` wait was the first).
    func timelineReading() -> TimelineReading {
        guard !retired, item.status == .readyToPlay else { return .unknown }

        let duration = item.duration
        // `isNumeric` is false for BOTH indefinite and invalid, so a finite value here is a real
        // VOD duration and nothing else.
        if duration.isNumeric {
            let now = item.currentTime()
            guard now.isNumeric else { return .unknown }
            return .vod(position: now.seconds, duration: duration.seconds)
        }

        guard duration.isIndefinite,
              let live = item.seekableTimeRanges.last?.timeRangeValue.end, live.isNumeric else {
            return .unknown
        }
        let now = item.currentTime()
        guard now.isNumeric else { return .unknown }
        return .live(behindEdge: max(0, (live - now).seconds))
    }

    /// Push a new monitoring decision at a RUNNING player. MAIN THREAD. No-op on a retired pull,
    /// and no-op for a stream with no tap (video only) — there is no second output to govern.
    func setMonitor(muted: Bool, volume: Float) {
        guard !retired else { return }
        audioTap?.setMonitor(muted: muted, volume: volume)
    }

    /// Begin playback. MAIN THREAD. Returns false when this pull was already retired — the same
    /// harmless-by-construction check `capture()` makes, for the same reason: `armPlayback` runs
    /// from a KVO hop, so the stream it belongs to can have been swapped away before it lands, and
    /// starting a retired player would leave an orphan fetching segments nobody displays.
    @discardableResult
    func startPlayback() -> Bool {
        guard !retired else { return false }
        player.play()
        return true
    }

    /// The readbacks the connect-time assertion needs. ANY THREAD (all are AVFoundation atomics);
    /// nil-ish answers on a retired pull rather than touching a dismantled object.
    var timeControlStatus: AVPlayer.TimeControlStatus {
        retired ? .paused : player.timeControlStatus
    }
    var waitingReason: AVPlayer.WaitingReason? {
        retired ? nil : player.reasonForWaitingToPlay
    }
    var itemStatus: AVPlayerItem.Status { retired ? .unknown : item.status }

    /// MAIN THREAD. Flag first, then the AVFoundation teardown — the order is the point: after the
    /// flag is set no tick can enter the objects being dismantled, so the dismantling does not have
    /// to race anything. There is deliberately NO join; see the file header.
    func retire() {
        retiredLock.lock(); _retired = true; retiredLock.unlock()

        // ── AUDIO FIRST, AND IN TWO STEPS, BECAUSE THE TWO THREADS DIFFER ───────────────────
        //
        // `HLSAudioTap.retire()` sets ITS flag (making an in-flight real-time tap callback
        // harmless, exactly as this object's flag does for an in-flight display tick) and then
        // JOINS our drain thread — which we CAN do, because we own that one. After it returns, no
        // push against `AudioTapBuffer` is in flight, so the ring cannot be written by a stream
        // that is being torn down.
        //
        // ⚠️ THE MIX IS DETACHED ONLY AFTER THAT JOIN, AND THE ORDER MATTERS. Detaching first
        // would leave the drain thread running against an item AVFoundation is dismantling;
        // detaching after is what guarantees the data path is already stopped when AVFoundation
        // stops calling us. The tap callback thread itself is never joined and does not need to
        // be — the flag is what makes it harmless, which is the same NDI rule this file's header
        // sets out for the display tick.
        audioTap?.retire()
        audioTap?.detach(from: item)

        player.rate = 0
        player.cancelPendingPrerolls()
        item.remove(output)
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - The service

/// HLS receive. One at a time, arbitrated through `LiveSource`.
///
/// ── AUDIO: METERED, AUDIBLE, AND IN THE RING THAT FEEDS SDI ─────────────────────────────────
///
/// This type used to be VIDEO ONLY. It now feeds `AudioTapBuffer` through `HLSAudioTap`, so the
/// meters move and the SDI path has real PCM to read — and the stream is AUDIBLE on the default
/// output device, played by AVFoundation itself. (Whether SDI actually transmits it is a separate,
/// unresolved question about `setCardAudioSilent` that affects every live transport, not just this
/// one; the reading is written out at the top of `HLSAudioTap`.)
///
/// ⚠️ THAT LAST PART COSTS NOTHING HERE AND IS WHY A PULL SOURCE IS THE EASY CASE. WHEP and SRT
/// have to open `beginLiveAudio`, obtain a `LiveAudioSink`, and mirror `LiveClock`'s mapping into
/// the synchronizer's timebase before a single sample can be heard. `AVPlayer` ALREADY HAS AN
/// OUTPUT PATH; the tap reads the samples on their way to it and passes them on. Nothing here
/// opens `beginLiveAudio`, mirrors `LiveClock` or touches the synchronizer — not because audio is
/// being withheld, but because none of that machinery is required to play it.
///
/// ⚠️ THE AUDIO CONTROLS STILL GOVERN IT, AND THAT TOOK A SEAM. Because the audio never enters
/// the engine's shared `AVSampleBufferAudioRenderer`, `FrameEngine.applyAudioMute` cannot reach
/// it directly. The engine therefore publishes its combined decision through
/// `externalAudioOutput`, which `DeckRegistry` routes to `applyAudioOutput` below and on into the
/// running pull. The toolbar mute, the volume fader and the SDI/Computer destination all apply.
///
/// The clock needs no help either: `AVPlayerItem`'s timebase drives audio and video together and
/// AVFoundation does the lip-sync. That is measured, and the measurement plus the standing
/// instruction not to build a control loop over it are in `HLSAudioTap`'s header.
/// ── MEASURING HLS'S FRAME RATE, BECAUSE NOTHING DECLARES IT ──────────────────────────────────
///
/// An HLS manifest has no frame-rate attribute we can rely on (`FRAME-RATE` is optional on
/// `EXT-X-STREAM-INF` and absent from most real ladders, including Apple's own bipbop), and
/// `AVPlayerItem` exposes no cadence for a remote stream — `AVAssetTrack.nominalFrameRate` needs an
/// asset track, which an HLS item may never populate. So the rate the DeckLink output mode needs has
/// to be MEASURED, or left nil. This measures it.
///
/// ── WHAT IS SAMPLED, AND WHY IT IS THE FRAME RATE AND NOT THE TICK RATE ─────────────────
///
/// `HLSPull.capture()` runs on every display tick but returns a buffer only when
/// `hasNewPixelBuffer(forItemTime:)` says a NEW one exists — i.e. once per SOURCE frame. The item
/// time at those instants is on the item's own timeline (measured flat to ±0.1 ms against the
/// presentation clock — see `HLSAudioTap`'s clock notes), so the gap between successive successful
/// captures is one source frame duration. Ticks that produce nothing are never sampled, so a 60 Hz
/// display watching a 25 fps ladder measures 25, not 60.
///
/// ── WINDOW: 120 SAMPLES, AND THE TRIMMED MEAN ───────────────────────────────────────────
///
/// 120 inter-frame gaps ≈ 2 s at 60 fps, ≈ 4 s at 30 fps, ≈ 5 s at 25 fps. Long enough that display-
/// tick quantization averages out, short enough that the rate is available well inside a normal
/// connect-and-watch.
///
/// The estimate is a TRIMMED MEAN, not a plain mean and not a bare median, because the two failure
/// modes pull opposite ways:
///   * a plain mean is wrecked by ONE outlier — a stall, a segment boundary, an ABR switch, or the
///     app being suspended, any of which contributes a gap of seconds;
///   * a bare median is robust to those but keeps the display-tick QUANTIZATION BIAS: a 59.94 fps
///     source on a 60 Hz display lands on alternating 1- and 2-tick gaps whose median is one of the
///     two, not the average of them.
/// So: take the median, discard every gap outside [0.5×, 2×] of it, and average what survives. The
/// discard kills the outliers; the average over the survivors kills the quantization.
///
/// The result is NOT snapped here. `DeckLinkService.resolveOutputMode` already does exact
/// nearest-match against the eight standard broadcast rates with no boundaries and no seams, and
/// doing it twice would be two rounding rules to keep in step. This reports fps and stops.
///
/// ⚠️ RESET ON AN ABR STEP. The caller resets this when the raster changes: the new rendition is a
/// different encode and may well be a different cadence, and carrying gaps across the step would
/// average two rates into one that is neither.
///
/// Single-threaded by construction — every method is called from the CVDisplayLink tick that owns
/// `pullFrame`, and from nowhere else.
/// ── RUNG 1 FOR HLS: `FRAME-RATE` OFF THE MASTER PLAYLIST ─────────────────────────────────────
///
/// `EXT-X-STREAM-INF` carries an OPTIONAL `FRAME-RATE` attribute (RFC 8216 §4.3.4.2). When the
/// packager writes it, it is a declaration and beats anything measured — which matters here more
/// than on WHEP, because HLS's measurement is quantised by the display tick and cannot reliably
/// separate 29.97 from 30 (see `FrameRateEstimator.windowSize`).
///
/// MEASURED, 2026-09-18:
///   * Cloudflare Stream:  PRESENT on every variant — `FRAME-RATE=23.976` across all five rungs.
///   * Apple bipbop:       ABSENT on every variant. No `FRAME-RATE` anywhere in the master.
/// So this is worth having AND cannot be relied on; the estimator stays as the fallback.
///
/// ⚠️ THE SPEC SAYS "MAXIMUM FRAME RATE", NOT AVERAGE (§4.3.4.2). For CFR content those are the
/// same number. For a variable-rate source they are not, and the declaration would then be an
/// upper bound rather than a cadence — which is one more reason the estimator keeps running
/// underneath as a cross-check rather than being switched off.
enum HLSMasterPlaylist {

    /// Every `FRAME-RATE` value in the master, in variant order. Empty when the attribute is
    /// absent, or when this is a MEDIA playlist rather than a master (no `EXT-X-STREAM-INF` at
    /// all) — both are ordinary and both mean "fall through to measurement".
    static func frameRates(in playlist: String) -> [Double] {
        var out: [Double] = []
        for line in playlist.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { continue }
            // Attributes are comma-separated, but quoted values may contain commas (CODECS="a,b"),
            // so the split has to respect quotes rather than being a plain `split(",")`.
            var inQuotes = false
            var field = ""
            var fields: [String] = []
            for ch in line.dropFirst("#EXT-X-STREAM-INF:".count) {
                if ch == "\"" { inQuotes.toggle(); field.append(ch) }
                else if ch == "," && !inQuotes { fields.append(field); field = "" }
                else { field.append(ch) }
            }
            fields.append(field)
            for f in fields {
                let kv = f.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "FRAME-RATE",
                      let v = Double(kv[1].trimmingCharacters(in: .whitespaces)),
                      v.isFinite, v > 0 else { continue }
                out.append(v)
            }
        }
        return out
    }

    /// The ONE declared rate for this ladder, or nil.
    ///
    /// ⚠️ `FRAME-RATE` IS PER-VARIANT, AND DISAGREEMENT MEANS REFUSE — NOT "PICK ONE".
    /// The ABR ladder switches renditions mid-stream and we are not told which one is playing, so
    /// if the variants declare different cadences there is no single correct answer to publish. A
    /// mixed 30/60 ladder is a real configuration, and picking the highest-resolution variant's
    /// value would set the wrong cadence on the wire for every second the player spends on another
    /// rung. Exact agreement is required — not "within a tolerance", because the pair this has to
    /// be careful about (29.97 vs 30) is 0.1% apart and any tolerance wide enough to be useful
    /// would swallow it. Disagreement falls through to the estimator, which at least measures
    /// whatever is actually playing.
    static func declaredFrameRate(in playlist: String) -> (rate: Double?, allValues: [Double]) {
        let rates = frameRates(in: playlist)
        guard let first = rates.first else { return (nil, rates) }
        return (rates.allSatisfy { $0 == first } ? first : nil, rates)
    }
}

private struct FrameRateEstimator {
    /// Gaps needed before an estimate is offered. See the window note above.
    ///
    /// ⚠️ THIS CONSTANT — NOT THE AVERAGING METHOD — IS WHAT DECIDES WHETHER THE MODE IS STABLE,
    /// AND AT 120 IT IS NOT. MEASURED across two runs: 458 windows on bipbop split 240x 1080p29.97
    /// / 218x 1080p30, and 560 windows on a live source split 312x 1080p23.98 / 248x 1080p24. The
    /// estimate varies +/-0.25% window to window while the pairs it must separate are 0.1% apart,
    /// so which mode gets picked is decided by whichever window happens to be current at connect
    /// time and then frozen by the 1% hold.
    ///
    /// THE CAUSE IS ENDPOINT QUANTISATION, WHICH NO FORMULA CAN AVERAGE AWAY. Capture instants are
    /// snapped to the display tick; over a span of N x interval the two endpoints each carry up to
    /// half a tick, so precision is ~(tick / span) and improves only with a LONGER SPAN.
    ///
    /// Modelled against the real beat pattern, windows needed for a single stable mode:
    ///
    ///     N=120  4.0s  +/-0.415%  two modes      N=480  16.0s  +/-0.104%  two modes
    ///     N=240  8.0s  +/-0.208%  two modes      N=600  20.0s  +/-0.083%  ONE MODE
    ///     N=360 12.0s  +/-0.139%  two modes      N=900  30.0s  +/-0.056%  ONE MODE
    ///
    /// So ~600 (20 s at 30 fps, 20 s at 24 fps) is where this becomes reliable. LEFT AT 120
    /// DELIBERATELY AND NOT RAISED HERE: it trades 4 s to a first answer for 20 s, which is a
    /// product decision about how long "Follow source" may sit unavailable after a connect, not a
    /// correctness one. Raising it is a one-line change once that trade is made.
    private static let windowSize = 120
    /// Gaps outside this band, at more than the window's span, are not a cadence — a segment
    /// boundary, a stall, or an app suspension. Sampling stops making sense long before this.
    private static let implausibleGapSeconds = 1.0

    private var lastItemTime: CMTime?
    private var gaps: [Double] = []
    /// The last value handed out, so the caller can log a CHANGE rather than a stream of samples.
    private(set) var estimate: Double?

    /// ── DIAGNOSTICS ONLY. READ NOTHING HERE INTO A DECISION. ────────────────────────────
    ///
    /// Populated on every call that actually COMPUTES an estimate, and set to nil on every call
    /// that does not, so a caller testing it for non-nil is asking "was a fresh estimate produced
    /// this frame?" — which is the question the per-estimate log needs and which the `Bool` return
    /// (deliberately "did the HELD value change?") cannot answer.
    ///
    /// ⚠️ THIS EXISTS TO SETTLE ONE QUESTION AND CHANGES NOTHING WHILE IT DOES. The trim below is
    /// `[0.5x, 2.0x]`, and 2.0 is INCLUSIVE — so the gap left by a single missed display tick,
    /// which is almost exactly 2x the frame interval, sits on the boundary and may be kept. Kept
    /// samples at 2x drag the mean up and the fps down: modelled at 30 fps over a 120-sample
    /// window, ONE surviving 2x gap moves the estimate to 29.752, which snaps to 29.97 rather than
    /// 30 — a different mode on the wire. `nearDoubleKept` counts exactly those samples. If it is
    /// reliably 0 on a live playlist the concern is theoretical; if it is not, the trim needs
    /// tightening, and that is a SEPARATE change with its own justification.
    struct Diagnostics {
        let keptCount: Int
        let discardedCount: Int
        /// Kept samples between 1.75x and 2.25x of the median — missed-tick intervals that
        /// survived the filter. THE NUMBER THIS WHOLE BLOCK EXISTS FOR.
        let nearDoubleKept: Int
        let medianInterval: Double
        /// `(max - min) / median` over the KEPT samples — RAW per-sample jitter.
        ///
        /// ⚠️ THIS IS NOT THE ESTIMATOR'S PRECISION AND WILL NOT IMPROVE WHEN THE ESTIMATOR DOES.
        /// It is a property of the SOURCE SAMPLING, not of the arithmetic: a display tick captures
        /// frames on a 60 Hz grid, the source rate is incommensurate with it, and the capture
        /// instants therefore beat against the grid by up to half a tick. Modelled, that alone
        /// produces 50% spread for a 29.97 source and 33% for a 23.98 one — which is exactly the
        /// 5-50% measured. Read `fitResidual` for confidence in the answer, and the `fps` column
        /// across successive windows for its stability.
        let spread: Double
        /// Worst |gap - multiple x median| / median over the kept samples.
        ///
        /// ⚠️ DIAGNOSTIC ONLY ON THIS TRANSPORT. DO NOT MAKE IT A GATE, AND DO NOT UNIFY IT WITH
        /// WHEP'S — WHEP REFUSES ON THIS NUMBER AND HLS MUST NOT.
        ///
        /// MEASURED ~20% here, BY CONSTRUCTION, on a perfectly healthy stream. The cause is
        /// display-tick sampling: at 23.976 fps against a 60 Hz tick the frame interval is 2.5
        /// ticks, so capture instants cannot land on a constant gap — they alternate 2 and 3 ticks
        /// (33.3 ms / 50.0 ms) forever. No integer multiple of any median fits both, so the residual
        /// is large no matter how clean the source is. Porting WHEP's 2% gate here would refuse
        /// every HLS stream at every rate whose interval is not a whole number of ticks.
        ///
        /// WHEP IS IMMUNE BECAUSE IT MEASURES A DIFFERENT CLOCK. Its samples are the sender's 90 kHz
        /// RTP timestamps — capture instants from the encoder, never resampled by our display — so
        /// its gaps genuinely are constant and a 2% fit residual is a real signal there.
        ///
        /// The two estimators share a shape and NOT a confidence metric, and that is correct.
        let fitResidual: Double
        /// Sum of the assigned integer multiples, and the elapsed time they span.
        let totalIntervals: Double
        let span: Double
        let fps: Double
    }
    /// Non-nil only for the frame on which it was computed. See the note above.
    private(set) var diagnostics: Diagnostics?

    /// Feed one captured frame's item time. Returns true when `estimate` changed meaningfully
    /// (first estimate, or a move of more than 1%), which is the caller's cue to log.
    mutating func record(itemTime: CMTime) -> Bool {
        // Cleared first so that "non-nil" means "computed on THIS call" — see `diagnostics`.
        diagnostics = nil
        defer { lastItemTime = itemTime }
        guard let lastItemTime else { return false }
        let gap = CMTimeGetSeconds(CMTimeSubtract(itemTime, lastItemTime))
        // Backwards (a seek / a live-edge jump) or implausibly long (a stall): not a cadence sample.
        guard gap.isFinite, gap > 0, gap < Self.implausibleGapSeconds else { return false }

        gaps.append(gap)
        if gaps.count > Self.windowSize { gaps.removeFirst(gaps.count - Self.windowSize) }
        guard gaps.count == Self.windowSize else { return false }

        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return false }
        let kept = gaps.filter { $0 >= median * 0.5 && $0 <= median * 2.0 }
        guard !kept.isEmpty else { return false }

        // ── SPAN MEASUREMENT: FRAME INTERVALS ÷ ELAPSED TIME ────────────────────────────────
        //
        // Each gap is rounded to the nearest INTEGER MULTIPLE of the median, and the multiples are
        // summed rather than the samples counted. A gap left by a dropped frame then contributes
        // both 2 intervals and 2 intervals' worth of elapsed time, so it cancels exactly instead of
        // dragging the answer down.
        //
        // ⚠️ THIS MAKES THE TRIM QUESTION MOOT, WHICH IS THE POINT. A 2x gap gives the same answer
        // whether the `[0.5x, 2.0x]` filter keeps it (span += 2 iv, intervals += 2) or discards it
        // (span += 0, intervals += 0). VERIFIED: 120-sample window at 30 fps with 3 dropped frames
        // reads 30.0000 either way, against 29.2683 under the old trimmed mean. The trim is
        // therefore left exactly as it is — the missed-tick concern it was suspected of is refuted
        // by measurement (nearDbl=0 across 1018 windows on two sources), and this method would not
        // care if it were not.
        //
        // ⚠️ AND IT IS NOT A PRECISION IMPROVEMENT. `span` is the SUM of the kept gaps, not
        // `last - first`, because a gap rejected above (a stall, a seek) must contribute neither
        // time nor intervals. In the ordinary case where nothing is rejected the sum telescopes and
        // the two are identical — which also means the OLD formula was already a span measurement:
        // `1/mean(gaps)` == `count/sum(gaps)` == `count/span`, identical to 3.5e-15 fps. The
        // window-to-window variation this was expected to fix comes from somewhere else entirely;
        // see `windowSize`.
        var totalIntervals = 0.0
        var span = 0.0
        var maxFitResidual = 0.0
        for g in kept {
            let m = max(1.0, (g / median).rounded())
            totalIntervals += m
            span += g
            // How far this gap sits from the integer multiple it was assigned, relative to one
            // interval. Large values mean the multiple assignment is guesswork — a variable-rate
            // source — and that the answer below should not be trusted.
            maxFitResidual = max(maxFitResidual, abs(g - m * median) / median)
        }
        guard span > 0, totalIntervals > 0 else { return false }

        let fps = totalIntervals / span

        // DIAGNOSTICS, computed from the SAME `median` and `kept` the estimate above used — not
        // recomputed, so the log cannot describe a different window than the one that produced the
        // number. Pure observation: nothing below reads any of it.
        // One pass, no second allocation — `kept` is already an allocated filter result and this
        // runs on the display tick.
        var nearDouble = 0
        var keptMin = Double.greatestFiniteMagnitude, keptMax = 0.0
        for g in kept {
            if g >= median * 1.75 && g <= median * 2.25 { nearDouble += 1 }
            if g < keptMin { keptMin = g }
            if g > keptMax { keptMax = g }
        }
        diagnostics = Diagnostics(keptCount: kept.count,
                                  discardedCount: gaps.count - kept.count,
                                  nearDoubleKept: nearDouble,
                                  medianInterval: median,
                                  spread: median > 0 ? (keptMax - keptMin) / median : .nan,
                                  fitResidual: maxFitResidual,
                                  totalIntervals: totalIntervals,
                                  span: span,
                                  fps: fps)

        // ⚠️ THE ESTIMATE IS HELD UNTIL IT MOVES MEANINGFULLY, AND THAT IS NOT COSMETIC. A rolling
        // window re-computes every frame and lands a few thousandths of an fps away each time. If
        // every one of those became the published value, `LiveVideoFormat` would differ on EVERY
        // FRAME, `LiveDisplaySize.publish` would fail its dedup 60 times a second and hop to main
        // 60 times a second, and the mode decision would re-run just as often — all to arrive at
        // the same standard rate. Holding until a 1% move means a steady stream publishes ONCE and
        // costs one comparison per frame thereafter, which is the contract the latch was built to.
        //
        // 1% is far tighter than the gaps between adjacent standard rates (the closest pair,
        // 29.97 and 30, are 0.1% apart — but they resolve to different modes only if the estimate
        // crosses the midpoint, and a 1% hold cannot stop that; it only stops the noise).
        guard let held = estimate else { estimate = fps; return true }
        guard abs(fps - held) / held > 0.01 else { return false }
        estimate = fps
        return true
    }

    /// An ABR step, or a new connection: the gaps collected so far describe a different encode.
    /// Keeps `estimate` so the card is not dropped back to "unknown" mid-stream on every ladder
    /// step — a rendition change is a reason to RE-measure, not a reason to forget.
    mutating func resetWindow() {
        gaps.removeAll(keepingCapacity: true)
        lastItemTime = nil
    }

    /// A new connection: forget everything, including the estimate.
    mutating func reset() {
        resetWindow()
        estimate = nil
    }
}

final class HLSClient: ObservableObject {

    static let shared = HLSClient()
    private init() {}

    /// Whether a stream is on screen. Read by `LiveSource`, and observed by ContentView so the
    /// control bar and the empty state follow a connect. Never dips across an HLS→HLS swap.
    @Published private(set) var isConnected = false

    /// The connect banner's message, or nil. Same contract as WHEP's and SRT's: set on failure,
    /// deliberately NOT cleared by our own teardown (a message about a failure must outlive the
    /// teardown that failure caused), retired by the next attempt or by `clearError()`.
    @Published private(set) var lastError: String?

    func clearError() { lastError = nil }

    /// The display path. Owned by `DeckRegistry`, which points it at the host deck's renderer.
    weak var renderer: MetalVideoRenderer?

    /// The engine's shared PCM ring. Weak, and wired by `DeckRegistry` alongside NDI's and SRT's —
    /// the engine owns it. Nil means no host deck, which this transport treats as "video only"
    /// rather than as a failure: see `HLSPull.init`.
    weak var audioTap: AudioTapBuffer?

    // MARK: - Desktop monitoring (the engine's decision, applied to AVPlayer's own output)

    /// The last decision `FrameEngine.externalAudioOutput` handed us. CACHED BECAUSE A CONNECT CAN
    /// HAPPEN AT ANY POINT IN THE SESSION: the engine pushes only when the decision CHANGES, so a
    /// stream connected while the app is already muted would otherwise come up at full volume and
    /// stay there until the user happened to touch a control. `HLSPull.init` seeds the new tap
    /// from these two before its first callback can fire.
    private var monitorMuted = false
    private var monitorVolume: Float = 1.0

    /// ── THE HOOK THAT MAKES A *LATER* CHANGE REACH A *RUNNING* STREAM ────────────────────────
    ///
    /// Wired by `DeckRegistry.attachDeviceHooks` to `FrameEngine.externalAudioOutput`, which fires
    /// from inside `applyAudioMute()` — the single place the app decides what the audio outputs
    /// should be doing. Every path that can change that decision already funnels through there:
    /// `toggleMute()`, `setVolume()`, `setShuttleRate()` (off-speed), `setDeckLinkOwnsAudio()`
    /// (the SDI destination and the DeckLink enable state), plus `beginLiveAudio` and `stop()`.
    ///
    /// ⚠️ SO THE HOOK IS ON THE DECISION, NOT ON THE CONNECT. That is the difference between a
    /// mute that works and one that only works if you set it before connecting: this arrives
    /// whenever the state moves, and `pull?.setMonitor` walks it into whatever player is running
    /// at that instant. `didSet` on the engine's property also fires it once at wiring time, so
    /// adopting a deck mid-session seeds correctly too.
    ///
    /// MAIN THREAD — `applyAudioMute` is main-actor and so is everything here.
    func applyAudioOutput(muted: Bool, volume: Float) {
        dispatchPrecondition(condition: .onQueue(.main))
        monitorMuted = muted
        monitorVolume = volume
        pull?.setMonitor(muted: muted, volume: volume)
    }

    /// Retire whatever else is driving the display, just before we take it. Installed once by
    /// `DeckRegistry.init` alongside NDI's, WHEP's and SRT's — the deck losing the display gets a
    /// full `stop()` (so no departed file's duration, timecode, aspect, colour tags or clean
    /// aperture survive behind the stream) and every other deck merely yields its transport.
    var onWillActivateStream: (() -> Void)?

    /// RUNG 1 — `FRAME-RATE` from the master playlist, or nil when the packager did not write one
    /// (Apple's bipbop does not; Cloudflare Stream does). Written ONCE by the fetch below, read on
    /// every display tick, so it needs the lock: `UnfairLock` rather than `NSLock` for the reason
    /// `LiveDisplaySize` states — the render thread must not block behind a lower-priority holder.
    private let declaredRateLock = UnfairLock()
    private var declaredFrameRateStorage: Double?
    private var declaredFrameRate: Double? {
        get { declaredRateLock.lock(); defer { declaredRateLock.unlock() }; return declaredFrameRateStorage }
        set { declaredRateLock.lock(); declaredFrameRateStorage = newValue; declaredRateLock.unlock() }
    }
    /// Edge-triggered, like WHEP's: the declared-vs-measured disagreement state.
    private var rateDisagreementActive = false
    /// Relative disagreement that counts as real. Same 2% as WHEP, same reasoning.
    private static let rateDisagreementThreshold = 0.02

    /// Cadence measurement for the DeckLink output mode. Display-tick thread only, like `pullFrame`.
    private var frameRateEstimator = FrameRateEstimator()
    /// The raster the last pulled frame had, so an ABR step can be detected here rather than inferred
    /// from the latch (which this function is the one writing). Display-tick thread only.
    private var lastPulledRaster: (Int, Int)?

    private var pull: HLSPull?
    /// Bumped on every teardown. An async KVO/status hop captures it and bows out if superseded —
    /// the same delivery-side generation check `FrameEngine.installScrubProducer` applies to scrub
    /// completions, and needed here for the same reason: we cannot join, so a late callback from a
    /// retired stream is a real event rather than a hypothetical one.
    private var generation: UInt64 = 0
    private var statusObservation: NSKeyValueObservation?
    /// Watches `AVPlayer.timeControlStatus`. THE ASSERTION THAT PLAYBACK ACTUALLY STARTED — see
    /// `armPlayback`. Nothing read this back before, which is why a player that never started
    /// looked exactly like a player that had.
    private var timeControlObservation: NSKeyValueObservation?

    /// 1 Hz, for the life of the connection, ARMED AT CONNECT AND NOT AT FIRST FRAME. See
    /// `heartbeatTick` — this is the reporting path that survives a stall.
    private var heartbeat: Timer?

    // Per-connection reporting state. Main thread only.
    private var frameCount = 0
    private var lastRateLogCount = 0
    private var lastRateLogTime: Double = 0
    private var heartbeatTicks = 0
    private var haveLoggedFirstFrame = false
    private var haveReachedPlaying = false
    /// One-shot, so the start-up fault is stated once rather than once a second forever.
    private var announcedStartFailure = false
    private var armedAt: Double = 0
    private var lastPublishedCICP: (Int?, Int?, Int?)?

    private static func monotonicNow() -> Double { CACurrentMediaTime() }

    /// How often the live-edge delay is restated, in heartbeat ticks (so, seconds). Segment-bound
    /// latency drifts — a rebuffer pushes us further behind and we never catch up — so ONE line at
    /// connect would be a number that stops being true. See `logLiveLatency`.
    private static let latencyLogInterval = 10

    /// How long playback may sit at anything other than `.playing` after being armed before it is
    /// reported as a fault rather than as start-up. Generous on purpose: a cold DNS lookup plus a
    /// master and media playlist fetch plus a first segment is seconds on a slow link, and the
    /// measured `AVURLAsset` → `readyToPlay` install alone reached 215.6 ms worst on a LOCAL file.
    /// This is the point at which "still starting" stops being the honest description.
    private static let playbackStartDeadline = 10

    // MARK: - Connect

    /// Stand an HLS stream up. `arbitratedBy` proves the caller came through `LiveSource`, which is
    /// the only place that can mint one — so this cannot be reached without the retire-first rule
    /// having run, and a direct call from a view or a debug shortcut DOES NOT COMPILE.
    ///
    /// ── ⚠️ HLS → HLS IS A SWAP, ON NDI'S RULE, AND THIS IS THE SITE THAT SAYS SO ──────────────
    ///
    /// `LiveSource.connectHLS` passes `except: .hls`, so a live HLS stream is NOT retired by the
    /// arbiter before we get here — WE swap it, below, and the reason is NDI's rather than SRT's:
    ///
    ///   * NOT SRT's swap. That one is defensible because `SRTClient.disconnect()` JOINS the
    ///     session thread, so the old session is provably finished before the new one exists. We
    ///     hang off the renderer's display link and own no thread, so no such proof is available
    ///     and claiming it would be a lie. What makes the swap safe here is `HLSPull.retire()`
    ///     making an in-flight tick harmless, not a join.
    ///   * NOT WHEP's refusal either. WHEP refuses because it can neither join nor safely sequence
    ///     its own teardown. We can sequence ours: `retire()` is synchronous, ordered, and total.
    ///
    /// So: tear the old pull down and stand the new one up IN THE SAME MAIN-THREAD TURN.
    /// `isConnected` is not touched between the two, so the control bar and the empty state see one
    /// continuous connection and never flicker — which is exactly what `NDIService.connect(to:)`
    /// buys by rebuilding its receiver without flipping the flag.
    func connect(to url: URL, arbitratedBy _: LiveSource.Arbitration) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let renderer else {
            NSLog("[HLS] refusing to connect — no renderer is attached to this deck")
            return
        }
        lastError = nil

        // ── THE SWAP, IN ONE TURN ────────────────────────────────────────────────────────────
        // Retire the OLD pull without touching `isConnected`. Ordered before the takeover below so
        // two pulls can never both answer a tick — the double-source condition `LiveSource` exists
        // to prevent, in the one shape arbitration cannot see because both sides are us.
        let isSwap = pull != nil
        retirePull()

        // One active source: retire a loaded file (and any OTHER live source's claim on this deck)
        // before we take the renderer. Harmless when there is nothing to retire, which is the
        // HLS→HLS case — the old pull is already gone, one line up.
        onWillActivateStream?()

        let fresh = HLSPull(url: url, pixelFormat: Self.videoPixelFormat, audioSink: audioTap,
                            monitorMuted: monitorMuted, monitorVolume: monitorVolume)
        pull = fresh
        generation &+= 1
        let token = generation

        // RUNG 1: ask the master playlist what cadence it declares. A SECOND fetch of a URL
        // AVFoundation is also fetching, deliberately — AVPlayer exposes no way to read the
        // master's attributes, and the alternative is not having the answer. Small, cached by
        // URLSession, and entirely off the critical path: the estimator runs regardless and the
        // declaration simply overrides it when it lands.
        declaredFrameRate = nil
        rateDisagreementActive = false
        // ⚠️ `token`, NOT `generation &+ 1`. This read `generation &+ 1` and the completion's
        // `guard self.generation == token` therefore compared n against n+1 and returned SILENTLY
        // on every connect — the rung never ran once, and said nothing while not running. The
        // increment happened ten lines up; `token` is already the value to match.
        fetchDeclaredFrameRate(from: url, token: token)

        frameCount = 0
        lastRateLogCount = 0
        lastRateLogTime = Self.monotonicNow()
        heartbeatTicks = 0
        haveLoggedFirstFrame = false
        haveReachedPlaying = false
        armedAt = 0
        lastPublishedCICP = nil

        // Start on the ASSUMED default (709 SDR), replaced from the buffer's own CICP on the first
        // frame that carries any. Same rule and same reason as NDI's: a "set it once at connect"
        // hardcode would hand the NEXT stream the previous one's colorimetry.
        renderer.setSourceColorSpace(primaries: 1, transfer: 1, matrix: 1, provenance: .assumed)

        // x420 is 10-bit VIDEO range by definition, so the shader expands legal range. Pinned here
        // rather than read from the file transport's override, which describes a file that may not
        // even be loaded.
        renderer.isFullRangeProvider = { false }
        renderer.clock = { Self.monotonicNow() }
        renderer.isPausedProvider = { false }

        // ⚠️ THE PULL IS **NOT** ARMED HERE, AND `play()` IS **NOT** CALLED HERE. Both wait for
        // `.readyToPlay`; see `armPlayback` and the status observer below. This ordering is the
        // fix for the one-frame bug: `capture()` asks `output.itemTime(forHostTime:)`, which maps
        // through the ITEM'S TIMEBASE, and an item that has not reached `.readyToPlay` has no
        // running timebase to map through. Ticking against it returned a constant item time, and a
        // constant item time yields exactly one frame ever — `copyPixelBuffer` "marks the image as
        // acquired" and `hasNewPixelBuffer` then reports NO for that same time forever.
        //
        // THE HARNESS THAT PRODUCED THIS FEATURE'S MEASURED NUMBERS ALWAYS DID THIS. `ScrubPlayer.
        // init` in docs/scrub-fixtures/avpvomeas.swift spins until `item.status == .readyToPlay`
        // (30 s deadline, nil on failure) BEFORE `hlsRun` calls `play()` and enters its pull loop.
        // That wait is load-bearing, not harness scaffolding, and it was omitted here.

        // Both terminal statuses are handled, and that is the change: this observer previously read
        // `guard item.status == .failed else { return }`, which dropped `.readyToPlay` on the floor
        // — the observer existed only to raise a banner. Generation-checked because we cannot join:
        // a status change from a stream retired three seconds ago must neither raise a banner over
        // the one running now nor arm a tick against a dismantled pull.
        let onStatus: (AVPlayerItem) -> Void = { [weak self] item in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.pull === fresh else { return }
                switch item.status {
                case .readyToPlay: self.armPlayback(fresh)
                case .failed:      self.failed(item.error, url: url)
                case .unknown:     break          // still resolving; the observer will fire again
                @unknown default:  break
                }
            }
        }
        // ALREADY-READY IS A REAL CASE AND KVO WILL NOT REPLAY IT. An item whose asset is warm in
        // AVFoundation's cache can be `.readyToPlay` before `observe` is installed, and `.new`
        // delivers nothing for a value that did not change afterwards — the stream would then sit
        // armed-never, connected and black. `AVPlayerScrubProducer` handles the same race the same
        // way (`if item.status == .readyToPlay { … } else { observe }`).
        if fresh.item.status == .readyToPlay || fresh.item.status == .failed {
            onStatus(fresh.item)
        } else {
            statusObservation = fresh.item.observe(\.status, options: [.new]) { item, _ in
                onStatus(item)
            }
        }

        // ARMED AT CONNECT, NOT AT FIRST FRAME — see `heartbeatTick`. A stream that never reaches
        // `.readyToPlay`, or that reaches it and then stalls, is exactly the case that most needs
        // reporting, and it is the case a frame-driven reporter cannot cover.
        startHeartbeat()

        isConnected = true
        NSLog("%@", "[HLS] \(isSwap ? "swapped to" : "connecting to") a stream — waiting for "
            + "readyToPlay before arming the pull; AVFoundation owns the pacing")
    }

    /// `.readyToPlay` has arrived: start playback, arm the display tick, and — the part that was
    /// missing entirely — WATCH WHETHER PLAYBACK ACTUALLY STARTS.
    ///
    /// ── ⚠️ WHY THE ASSERTION EXISTS ──────────────────────────────────────────────────────────
    ///
    /// Nothing read `timeControlStatus` back before, and that is precisely why the original defect
    /// failed SILENTLY rather than loudly: `play()` returns void, cannot fail, and a player that
    /// never left `.paused` was indistinguishable from one that was streaming perfectly. The only
    /// visible symptom was a frame counter that had no frames to count.
    ///
    /// `.waitingToPlayAtSpecifiedRate` is NOT a fault on its own — with
    /// `automaticallyWaitsToMinimizeStalling` at its default it is the NORMAL start-up state, and
    /// the normal recovery from a mid-stream stall. So the fault condition is not "waiting", it is
    /// "STILL not playing, `playbackStartDeadline` seconds after being armed", which the heartbeat
    /// decides rather than this method.
    private func armPlayback(_ fresh: HLSPull) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let renderer, armedAt == 0 else { return }   // once per connection
        armedAt = Self.monotonicNow()

        // THE PULL. Same seam NDI uses, and the reason is the same: AVFoundation holds the frames
        // and hands over whatever is current when we ask, so asking on OUR display tick is what
        // puts the picture on our clock instead of a second one. Armed HERE — after the item is
        // ready — so the timebase the tick maps through is a running one.
        renderer.onDisplayTick = { [weak self] in self?.pullFrame() }

        // Every transition, named. This is the log that would have made the original bug a
        // ten-second diagnosis instead of a measurement: a player stuck at `paused` after `play()`
        // says so in one line, and a `waiting` state carries the reason AVFoundation gives.
        timeControlObservation = fresh.player.observe(\.timeControlStatus, options: [.new]) {
            [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.pull === fresh else { return }
                if player.timeControlStatus == .playing { self.haveReachedPlaying = true }
                NSLog("%@", "[HLS] playback state → \(Self.describe(player.timeControlStatus))"
                    + Self.describeWaiting(player.reasonForWaitingToPlay))
            }
        }

        guard fresh.startPlayback() else { return }   // retired between the KVO hop and here
        NSLog("%@", "[HLS] item is readyToPlay — pull armed, play() issued (state now "
            + "\(Self.describe(fresh.timeControlStatus)))")
    }

    /// The app's decode contract, restated. `FrameEngine.videoPixelFormat` is private to the
    /// package, so the constant is spelled here — and it is asserted on the first frame
    /// (`logFirstFrame`) rather than assumed, which is what keeps a divergence loud.
    private static let videoPixelFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    private func failed(_ error: Error?, url: URL) {
        // NEVER THE URL. An HLS path can carry a token exactly as an SRT path can carry a stream
        // key — same rule the bookmark rows follow when they show a name and not a link.
        let detail = (error as NSError?)?.localizedDescription
        lastError = detail.map { "That stream could not be played — \($0)" }
            ?? "That stream could not be played."
        NSLog("%@", "[HLS] connect failed: \(detail ?? "no reason given by AVFoundation")")
        disconnect()
    }

    // MARK: - The tick (CVDisplayLink thread)

    /// Called from `MetalVideoRenderer`'s display tick, BEFORE it selects a frame — so a frame
    /// pulled here is eligible on the very same tick.
    ///
    /// ⚠️ EVERY GUARD HERE IS THE TEARDOWN CONTRACT, NOT DEFENSIVE PADDING. See the file header:
    /// `pull` may be nil (already retired), and a `pull` captured strongly here may be retired
    /// underneath us mid-call — which `capture()` answers with nil rather than a crash.
    /// Fetch and parse the master playlist for its declared `FRAME-RATE`. Fire-and-forget: a
    /// failure, a media playlist, or an absent attribute all mean "fall through to measurement",
    /// which is the state we are already in.
    ///
    /// ⚠️ THE URL IS NEVER LOGGED. An HLS path can carry a stream key — the same rule the connect
    /// error banner follows.
    /// ⚠️ EVERY PATH THROUGH THIS FUNCTION LOGS, INCLUDING THE ONES THAT DO NOTHING.
    ///
    /// It shipped with a wrong generation token, so the completion's staleness guard rejected its
    /// own result on every connect — and because that guard was a bare `return`, the rung produced
    /// no picture of itself at all: no success line, no failure line, nothing to grep for. It read
    /// exactly like a rung that had never been wired. A silent failure inside the instrument built
    /// to remove silent failures is the specific mistake this file has spent a day undoing, so the
    /// rule here is absolute: this function states what it attempted, what came back, what it
    /// parsed and what it decided, on every path, including "superseded" and "torn down".
    private func fetchDeclaredFrameRate(from url: URL, token: UInt64) {
        // ⚠️ REDACTED, DELIBERATELY. An HLS path can carry a stream key — the same rule the connect
        // error banner follows ("never a full URL"). Scheme, host and the final component are
        // enough to answer the question this log exists for: "did it fetch the master, or something
        // else?" Everything between is replaced.
        let shown = Self.redactedForLog(url)
        print("[HLS-FORMAT] rung 1: fetching master playlist for FRAME-RATE — \(shown)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                print("[HLS-FORMAT] rung 1: client gone before the playlist returned — no rate")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bytes = data?.count ?? 0
            DispatchQueue.main.async {
                // Superseded by a later connect: this answer is about a stream we have left. LOGGED,
                // not silent — this is the exact branch whose silence hid the bug.
                guard self.generation == token else {
                    print("[HLS-FORMAT] rung 1: result superseded (token \(token), now "
                        + "\(self.generation)) — discarding; a newer connect owns this deck")
                    return
                }
                guard error == nil, let data, let text = String(data: data, encoding: .utf8) else {
                    print("[HLS-FORMAT] rung 1: FAILED — HTTP \(status), \(bytes) byte(s), "
                        + "\(error?.localizedDescription ?? "body was not UTF-8"). "
                        + "Falling through to measurement.")
                    return
                }
                let variantLines = text.split(whereSeparator: \.isNewline)
                    .filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }.count
                let (declared, all) = HLSMasterPlaylist.declaredFrameRate(in: text)
                let preamble = "rung 1: HTTP \(status), \(bytes) byte(s), "
                             + "\(variantLines) EXT-X-STREAM-INF line(s), "
                             + "\(all.count) with FRAME-RATE"
                if let declared {
                    self.declaredFrameRate = declared
                    print(String(format: "[HLS-FORMAT] %@ → frame rate %.3f fps DECLARED "
                                         + "(all variants agree) — exact, beats measurement.",
                                 preamble, declared))
                } else if all.isEmpty {
                    print("[HLS-FORMAT] \(preamble) → no FRAME-RATE declared. Falling through to "
                        + "measurement (ordinary; Apple's bipbop ladder has none either).")
                } else {
                    let list = all.map { String(format: "%.3f", $0) }.joined(separator: ", ")
                    print("[HLS-FORMAT] \(preamble) → variants DISAGREE [\(list)]. No single "
                        + "declared cadence for this ladder, and the player does not say which rung "
                        + "it is on. Falling through to measurement.")
                }
            }
        }.resume()
    }

    /// Scheme + host + final path component, with everything between replaced. See the call site.
    private static func redactedForLog(_ url: URL) -> String {
        let scheme = url.scheme ?? "?"
        let host = url.host ?? "?"
        let last = url.lastPathComponent
        let depth = url.pathComponents.count
        return "\(scheme)://\(host)/…(\(max(0, depth - 2)) segment(s))…/\(last)"
    }

    /// ── THE CROSS-CHECK, THE SAME SHAPE AS WHEP'S ───────────────────────────────────────────
    ///
    /// The declaration wins and the estimator keeps running underneath it as a check. Rationale is
    /// WHEP's verbatim and it applies here for the same reason: "a publisher declaring one
    /// configuration while sending another, with every counter clean" is the 5.1-Opus failure in
    /// docs/BUGS.md, whose conclusion was that a misconfiguration nothing can fix must at least be
    /// STATED. Here it is detectable and the instrument already exists.
    ///
    /// REPORTS, DOES NOT ACT — no override, no fallback. The declaration is the packager's stated
    /// intent; the measurement is the degradable one (display-tick quantisation alone moves it
    /// ±0.25%). Edge-triggered so a transient does not leave a stale warning.
    ///
    /// ⚠️ 2% IS COMFORTABLY WIDER THAN THIS ESTIMATOR'S OWN NOISE, WHICH IS THE POINT. A declared
    /// 30 against a measured 29.93 is 0.23% and will NOT trip it — that gap is the quantisation
    /// described on `windowSize`, not a misconfiguration. 24 vs 25 is 4.2% and always will.
    private func crossCheckDeclaredRate(declared: Double, measured: Double?) {
        guard let measured else { return }
        let disagreement = abs(measured - declared) / declared
        let nowDisagreeing = disagreement > Self.rateDisagreementThreshold
        guard nowDisagreeing != rateDisagreementActive else { return }
        rateDisagreementActive = nowDisagreeing
        if nowDisagreeing {
            print(String(format: "[HLS-FORMAT] ⚠️ master playlist declares %.3f fps but measured "
                                 + "%.3f fps over 120 frames (%.1f%% disagreement) — using the "
                                 + "declared rate; the publisher may be misconfigured.",
                         declared, measured, disagreement * 100))
            let advisory = String(format: "Source declares %.3f fps but is sending %.3f fps — "
                                          + "output follows the declared rate.", declared, measured)
            DispatchQueue.main.async { DeckLinkService.shared.setSourceAdvisory(advisory) }
        } else {
            print(String(format: "[HLS-FORMAT] declared and measured rates now agree "
                                 + "(%.3f vs %.3f fps) — earlier disagreement retracted.",
                         declared, measured))
            DispatchQueue.main.async { DeckLinkService.shared.setSourceAdvisory(nil) }
        }
    }

    private func pullFrame() {
        guard let pull, let renderer else { return }
        guard let captured = pull.capture() else { return }
        let pixelBuffer = captured.buffer

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // ── THE CADENCE, MEASURED ───────────────────────────────────────────────────────────
        //
        // An ABR step means a different encode, so the window is thrown away and re-measured; the
        // ESTIMATE survives it (see `resetWindow`) rather than dropping the card back to "unknown"
        // on every rung of the ladder. The raster comparison is against the last raster THIS
        // function saw, not against the latch, because the latch is what we are about to write.
        if lastPulledRaster.map({ $0 != (width, height) }) ?? true {
            if lastPulledRaster != nil {
                print("[HLS-FORMAT] rendition changed to \(width)x\(height) — re-measuring frame rate "
                    + "(previous estimate "
                    + (frameRateEstimator.estimate.map { String(format: "%.3f fps", $0) } ?? "none")
                    + " retained meanwhile)")
            }
            lastPulledRaster = (width, height)
            frameRateEstimator.resetWindow()
        }
        let rateChanged = frameRateEstimator.record(itemTime: captured.itemTime)
        if rateChanged, let fps = frameRateEstimator.estimate {
            print(String(format: "[HLS-FORMAT] frame rate measured %.3f fps over a 120-frame window "
                                 + "(trimmed mean of item-time gaps) — DeckLink Follow source can use it",
                         fps))
        }
        #if DEBUG
        // ── PER-ESTIMATE DIAGNOSTICS (DEBUG builds only) ────────────────────────────────────
        //
        // EVERY estimate, not only the ones that move the published value — the question is
        // whether the figure is STABLE or oscillating across the 29.97/30 boundary, and a
        // log that fires only on change cannot show a value sitting still. Changes NOTHING:
        // `frameRateEstimator.diagnostics` is pure observation of the window just computed.
        //
        // `nearDbl` IS THE NUMBER TO READ. It counts kept samples at ~2x the median — missed-tick
        // gaps that survived the inclusive `[0.5x, 2.0x]` trim. Modelled, one of them moves a
        // 30 fps window to 29.752, which resolves to 1080p29.97 instead of 1080p30. `mode` is what
        // `resolveOutputMode` would actually pick from this window, so the consequence is in the
        // line rather than left to be worked out.
        //
        // ⚠️ OBSERVER EFFECT, STATED SO IT IS NOT DISCOVERED LATER. This prints from the
        // CVDisplayLink tick — the same thread whose missed ticks are the thing being counted. At
        // 30 fps it is ~30 lines/s. If `nearDbl` is high here but the stream looks clean, re-check
        // with a shorter run before concluding the source drops frames: the logging may be causing
        // some of what it reports.
        if let d = frameRateEstimator.diagnostics {
            let mode = DeckLinkService.resolveOutputMode(width: width, height: height,
                                                         frameRate: d.fps)
            print(String(format: "[HLS-RATE] %@ kept=%d disc=%d nearDbl=%d · median=%.4fms "
                                 + "spread=%.2f%% fit=%.2f%% · ivals=%.0f span=%.3fs · "
                                 + "fps=%.4f → %@",
                         declaredFrameRate == nil ? "measured" : "declared+check",
                         d.keptCount, d.discardedCount, d.nearDoubleKept,
                         d.medianInterval * 1000, d.spread * 100, d.fitResidual * 100,
                         d.totalIntervals, d.span, d.fps, mode.label))
        }
        #endif

        // ⚠️ THE SHAPE, PER FRAME, AND FOR HLS THIS IS NOT A FORMALITY. MEASURED: the ABR ladder
        // settled from 4K to 1280×720 inside a 25 s window (docs/BUGS.md). The raster of a live
        // HLS feed is NOT under our control and WILL change during a session, so a connect-time
        // size would be wrong within seconds. `LiveDisplaySize` was already built per-frame for
        // exactly this class of change (an SPS change on WHEP/SRT, a source switch on NDI) and it
        // latches internally — a steady stream costs one comparison per tick and no main hop.
        //
        // WHAT A LADDER STEP THEN DOES, END TO END:
        //   * the OFFSCREEN reallocates (`ensureOffscreenTexture`) and republishes its ring with
        //     `offscreenReadableIndex = -1`, so the scopes decline exactly one tick and hold their
        //     previous plot rather than sampling a texture whose extent has moved;
        //   * the SCOPES then re-bin at the new size with no plumbing, because every kernel takes
        //     its extent from the texture (`src.width`), never from the pixel buffer;
        //   * the WINDOW does not move: `WindowSizer.setGeometry` compares the ASPECT RATIO, and
        //     3840/2160 == 1280/720. It DOES move if a raster percentage is active, because
        //     "100% of source" is a statement about a raster the ladder is entitled to change.
        //
        // THE LADDER: the master playlist's declaration if there is one, else the measurement.
        // nil until one of them exists, which is the honest state — "we have a picture and do not
        // yet know its cadence" — and is exactly when `DeckLinkService` declines to follow.
        //
        // The estimator has already run this frame regardless (above), because when a declaration
        // exists the measurement's job becomes CHECKING it. See `crossCheckDeclaredRate`.
        let declared = declaredFrameRate
        if let declared { crossCheckDeclaredRate(declared: declared, measured: frameRateEstimator.estimate) }
        LiveDisplaySize.shared.publish(width: width, height: height,
                                       frameRate: declared ?? frameRateEstimator.estimate)

        publishColorTagsIfChanged(of: pixelBuffer)

        // NO CONVERSION. The buffer is already x420 — the format `AVPlayerItemVideoOutput` was
        // asked for and MEASURED to honour — so it goes straight to the enqueue the file paths use
        // and lands in the offscreen ring the scopes, the export and DeckLink all read. This is
        // the whole reason the feature is cheap; NDI needs a VTPixelTransferSession to get here.
        guard let sampleBuffer = Self.makeSampleBuffer(pixelBuffer, pts: Self.monotonicNow()) else {
            return
        }
        renderer.enqueue(sampleBuffer)

        // The first frame's FORMAT is inherently a success-path fact, so it stays here. The RATE
        // and the LATENCY do not: both moved to `heartbeatTick`, because a reporter that only runs
        // when a frame arrives goes silent in exactly the condition worth reporting. All this path
        // now owes the reporting is a count.
        frameCount += 1
        logFirstFrame(pixelBuffer, width: width, height: height)
    }

    /// The source's colour tags, from the buffer's own attachments, re-read per frame for the same
    /// reason the shape is: an ABR switch crosses a rendition boundary, and an SDR ladder with an
    /// HDR top rung is a real thing to point a scope at. MEASURED on bipbop: primaries/matrix
    /// 6→1 (BT.601 → Rec.709) as the ladder stepped up from the 416×234 rendition.
    ///
    /// `AVPlayerItemVideoOutput` propagates the CICP the stream signalled in-band onto the vended
    /// buffer, so this reads what the platform published rather than what we hoped it published.
    /// Hopped to main because `setSourceColorSpace` runs a `CATransaction`.
    ///
    /// ── ⚠️ THE COLOUR STATE LANDS ONE FRAME LATE, BY CONSTRUCTION. RECORDED, NOT FIXED. ──────
    ///
    /// The install is `DispatchQueue.main.async`; `renderer.enqueue` on the next line is
    /// synchronous, on the display-tick thread. So the very buffer whose tags triggered the change
    /// is enqueued — and presented — under the PREVIOUS rendition's colour state. On a 601→709 step
    /// that is one frame decoded with the wrong Kr/Kb, which is a visible chroma error.
    ///
    /// THIS PATH CANNOT HAVE THE FILE PATH'S PROPERTY, AND THE REASON IS STRUCTURAL RATHER THAN A
    /// MISSING PRECAUTION. `setSourceGeometry`'s own doc comment states how the file path is immune:
    /// `FrameEngine` calls `setSourceColorSpace` on the main actor, off the format description
    /// already in hand, and *"BEFORE `beginReading` — which is the only thing in that function that
    /// creates a reader and therefore the only thing that can enqueue a frame."* The tags are known
    /// before any frame can exist. **Here the tags arrive ON the buffer.** There is no instant at
    /// which they are known and the frame does not yet exist, so no ordering of these two lines can
    /// produce that guarantee. Fixing it would mean holding a frame back one tick whenever the tags
    /// change — trading a one-frame colour error for a one-frame stutter, on a live monitor, at
    /// every rendition step.
    ///
    /// WHAT BOUNDS IT TO ONE FRAME IS `pendingRefresh`, which `setSourceColorSpace` sets alongside
    /// the state so that *"a frame already on screen is re-presented under the new state rather
    /// than waiting for the next one."* The next tick re-presents correctly.
    ///
    /// ⚠️ AND THAT IS WHY THIS IS NOT THE STUCK CASE BUGS.md RECORDS. In *"A file's first frame is
    /// presented before the layer knows what colour it is"*, the wrong state PERSISTS — a
    /// `CAMetalLayer` applies its colorspace at PRESENT time, so "the presented drawable keeps the
    /// interpretation it was presented under, and nothing in a paused deck presents again". A
    /// PAUSED deck has no next present, so the error is permanent until playback. A live stream
    /// presents continuously and is never paused (`isPausedProvider = { false }`), so the same
    /// mechanism that makes the file case stick is what makes this one self-clear in ~16–40 ms.
    /// **If a live source ever gains a freeze/pause, this stops being bounded and becomes the
    /// stuck case** — that is the condition to re-read this note under, not the arithmetic.
    private func publishColorTagsIfChanged(of buffer: CVPixelBuffer) {
        let codes = Self.cicp(of: buffer)
        if let last = lastPublishedCICP, last == codes { return }
        lastPublishedCICP = codes
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pull != nil else { return }
            // `Self.cicp(of:)` returns nil for an attachment the buffer does not carry, so the
            // codes are the resolution here — the file rule, not NDI's.
            self.renderer?.setSourceColorSpace(
                primaries: codes.0, transfer: codes.1, matrix: codes.2,
                provenance: .fromCodes(primaries: codes.0, transfer: codes.1, matrix: codes.2))
        }
        NSLog("%@", "[HLS] colour signalling: primaries=\(codes.0.map(String.init) ?? "—") "
            + "transfer=\(codes.1.map(String.init) ?? "—") matrix=\(codes.2.map(String.init) ?? "—")"
            + (codes == (1, 1, 1) ? " (Rec.709 SDR)" : ""))
    }

    // MARK: - Reporting

    /// The first frame, once per connection: what actually arrived, and whether it is the format
    /// this whole route depends on. `x420` is the claim the measurement made; a stream that vends
    /// something else would still DISPLAY (the renderer handles it) but would have taken a
    /// conversion nobody costed, so it says so rather than passing silently.
    private func logFirstFrame(_ buffer: CVPixelBuffer, width: Int, height: Int) {
        guard !haveLoggedFirstFrame else { return }
        haveLoggedFirstFrame = true
        let fourCC = Self.fourCC(CVPixelBufferGetPixelFormatType(buffer))
        let verdict = CVPixelBufferGetPixelFormatType(buffer) == Self.videoPixelFormat
            ? "— the app's decode contract, unchanged"
            : "— ⚠️ NOT x420; the requested format was not honoured and a conversion is happening"
        NSLog("%@", "[HLS] first frame \(width)×\(height) \(fourCC) \(verdict)")
    }

    /// ── ⚠️ THE REPORTING PATH, AND IT IS DELIBERATELY NOT THE FRAME PATH ────────────────────
    ///
    /// A TIMER, ARMED AT CONNECT, running for the life of the connection whether or not a single
    /// frame ever arrives.
    ///
    /// It used to be two functions called from the tail of `pullFrame`, and that was wrong in the
    /// specific way instrumentation is usually wrong: **it could only report success.** A stream
    /// that stalled stopped calling them, so the fps line and the latency line simply stopped
    /// appearing — the log went quiet at the exact moment it had something to say, and "no output"
    /// read identically to "nothing is wrong". The original one-frame bug produced precisely that:
    /// one `1.0 fps` line, which was not a rate at all but one frame divided by the ~1 s since
    /// connect, printed once and never again.
    ///
    /// On a timer, a stall is LOUD: `0.0 fps` once a second, with the live-edge delay and the
    /// player's own `timeControlStatus` beside it saying whether AVFoundation thinks it is
    /// playing, waiting, or paused. Those three facts together distinguish every failure this
    /// transport has — a dead link, a stalled encoder, a player that never started — and no one of
    /// them does it alone.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.heartbeatTick()
        }
    }

    private func heartbeatTick() {
        guard let pull else { return }
        heartbeatTicks += 1

        let now = Self.monotonicNow()
        let elapsed = max(now - lastRateLogTime, 0.001)
        let delivered = frameCount - lastRateLogCount
        let rate = Double(delivered) / elapsed
        lastRateLogTime = now
        lastRateLogCount = frameCount

        let state = Self.describe(pull.timeControlStatus)
        // ⚠️ THE PLAYER'S OWN VIEW IS PRINTED ALONGSIDE OUR FRAME COUNT, ALWAYS, NOT ONLY WHEN
        // THEY DISAGREE — because the disagreement is the diagnosis. "0.0 fps / playing" is a
        // pull-side fault (our tick, our timebase mapping, our acquire). "0.0 fps / waiting" is
        // the network. "0.0 fps / paused" after arming is a player that never started, which is
        // the bug this whole block exists because of.
        NSLog("%@", String(format: "[HLS] %.1f fps — player says %@", rate, state)
            + Self.describeWaiting(pull.waitingReason))

        // ── THE START-UP ASSERTION ───────────────────────────────────────────────────────────
        //
        // Fires ONCE, `playbackStartDeadline` seconds after the pull was armed, if the player has
        // never once reached `.playing`. Deliberately NOT a check for "is playing right now": a
        // mid-stream stall legitimately parks in `.waitingToPlayAtSpecifiedRate` and recovers, and
        // reporting that as a failed start would be false. `haveReachedPlaying` is a latch, so
        // this asks the honest question — did playback EVER begin?
        //
        // ⚠️ WHAT HAPPENS IF IT NEVER REACHES PLAYING: the banner is raised and the fault is named,
        // AND THE STREAM IS LEFT RUNNING. It is NOT torn down, and that is the deliberate half —
        // with `automaticallyWaitsToMinimizeStalling` at its default the player is still trying,
        // and a slow link that starts at 12 s is a stream that works. Disconnecting here would
        // convert a slow start into a permanent failure, which is the shape of the bug this
        // assertion was added to catch. The user gets told; the transport keeps its chance.
        if armedAt > 0, !haveReachedPlaying, !announcedStartFailure,
           now - armedAt >= Double(Self.playbackStartDeadline) {
            announcedStartFailure = true
            let reason = Self.describeWaiting(pull.waitingReason)
            NSLog("%@", "[HLS] ⚠️ playback has NOT started \(Self.playbackStartDeadline)s after "
                + "readyToPlay — player is \(state)\(reason). Not tearing down: AVFoundation is "
                + "still trying and a slow link may yet start.")
            lastError = "That stream is not playing yet — it connected, but no video has started "
                      + "after \(Self.playbackStartDeadline) seconds. Still trying."
        }

        if heartbeatTicks % Self.latencyLogInterval == 0 { logLiveLatency(pull) }
    }

    /// ── ⚠️ THE LATENCY IS REPORTED, NOT HIDDEN ───────────────────────────────────────────────
    ///
    /// A required property of the feature, not telemetry (docs/BUGS.md, "What done would mean"):
    /// **segment-bound latency is inherent to the transport and a viewer needs to know that what it
    /// is looking at is seconds old.** A QC instrument that shows a delayed picture without saying
    /// so invites the one wrong conclusion it exists to prevent — that a fault seen here is
    /// happening NOW.
    ///
    /// PERMANENT, not `#if DEBUG` — the difference between this and `[SRT] latency budget`, which
    /// reports a tuning cushion rather than a viewing delay and can afford to be telemetry-only.
    ///
    /// RESTATED PERIODICALLY, NOT ONCE AT CONNECT, because the live-edge delay DRIFTS: a rebuffer
    /// pushes us further behind and AVFoundation does not catch back up, so a single connect-time
    /// number would go quietly false while still on screen. Measured against the live edge each
    /// time rather than accumulated — and now driven by the heartbeat, so it keeps being measured
    /// through a stall, when the number is changing fastest.
    private func logLiveLatency(_ pull: HLSPull) {
        switch pull.timelineReading() {
        case .live(let behindEdge):
            NSLog("%@", String(format: "[HLS] latency: the picture is %.1f s behind the live edge "
                + "(segment-bound, inherent to HLS — you are looking at the platform's EGRESS, "
                + "after its transcode)", behindEdge))

        // ⚠️ A LATENCY IS NOT REPORTED HERE, AND THAT IS THE POINT. A finite duration means there
        // is no live edge to be behind, so any number of that shape would be a fiction. Position
        // is reported instead because it is the true fact this item HAS.
        //
        // Worth flagging beyond the arithmetic: BUGS.md scopes this feature as live monitoring
        // ("the QC use, which is live monitoring with no scrubber"), and separately measured that
        // seeking a VOD HLS item is slow — 188 ms mean, 624 ms worst. A VOD `.m3u8` playing here is
        // not wrong, but it is outside what was scoped, and until this line existed nothing told
        // the user which of the two they had connected to.
        case .vod(let position, let duration):
            NSLog("%@", String(format: "[HLS] VOD playlist (finite duration %.1f s) — no live edge, "
                + "so there is no latency to report. Position %.1f s. NOTE: this feature is scoped "
                + "to LIVE egress monitoring; a VOD stream plays but is not what it is for.",
                duration, position))

        // ⚠️ THIS BRANCH USED TO SAY "this is a VOD playlist". It was unreachable for any healthy
        // item — a VOD asset has a perfectly good seekable range — so the ONLY thing that could
        // ever reach it was a broken or not-yet-ready item, which it then announced as VOD. The
        // message named the one state that could not produce it.
        case .unknown:
            NSLog("%@", "[HLS] latency: the item cannot state a timeline yet — not ready, or it "
                + "stopped answering. This is NOT a VOD playlist; it is an item with no usable "
                + "duration (player is \(Self.describe(pull.timeControlStatus)))")
        }
    }

    /// Plain-speak `timeControlStatus`. Exhaustive over the enum so a future case cannot be
    /// silently printed as a number.
    private static func describe(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused:                      return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        case .playing:                     return "playing"
        @unknown default:                  return "unknown(\(status.rawValue))"
        }
    }

    /// AVFoundation's own reason for waiting, when it has one. Empty string when it does not, so
    /// callers can concatenate unconditionally.
    private static func describeWaiting(_ reason: AVPlayer.WaitingReason?) -> String {
        guard let reason else { return "" }
        switch reason {
        case .toMinimizeStalls:            return " (buffering to avoid a stall)"
        case .evaluatingBufferingRate:     return " (measuring the link)"
        case .noItemToPlay:                return " (no item to play)"
        case .interstitialEvent:           return " (interstitial)"
        default:                           return " (\(reason.rawValue))"
        }
    }

    // MARK: - Teardown

    /// Retire the pull and the display hook WITHOUT touching `isConnected`. Shared by `disconnect()`
    /// and the HLS→HLS swap — the swap rebuilds immediately afterwards, so it must NOT flip the
    /// flag (which would drop the control bar to the empty state mid-swap). Exactly the split
    /// `NDIService.tearDownReceiver` makes, and for exactly that reason.
    private func retirePull() {
        dispatchPrecondition(condition: .onQueue(.main))
        statusObservation = nil
        // The playback assertion belongs to the pull being retired. Left installed it would report
        // the dying player's transition to `paused` as if it described the incoming stream — on a
        // swap, one line after the new one armed.
        timeControlObservation = nil
        heartbeat?.invalidate()
        heartbeat = nil
        // Both latches are per-connection. `armedAt` is also the "armed once" guard in
        // `armPlayback`, so leaving it set would stop the NEXT stream ever arming its tick.
        armedAt = 0
        haveReachedPlaying = false
        announcedStartFailure = false
        generation &+= 1
        // The hook FIRST, then the objects — so ticks stop being scheduled before the thing they
        // would read is dismantled. This narrows the race; `HLSPull.retire()` is what CLOSES it,
        // because this store alone cannot be ordered against a render thread we do not own.
        renderer?.onDisplayTick = nil
        pull?.retire()
        pull = nil
    }

    /// Full teardown. MAIN THREAD.
    func disconnect() {
        dispatchPrecondition(condition: .onQueue(.main))
        // The flag FIRST, before the no-pull early-out, so a redundant disconnect — or one after a
        // connect that failed before a pull existed — can never leave `isConnected` stuck true.
        // Same ordering rule as WHEP's and SRT's.
        isConnected = false
        guard pull != nil else { return }
        retirePull()
        // Wipe the last streamed frame: with the source gone and (usually) no file behind it, the
        // renderer would otherwise leave its final drawable frozen behind the empty state.
        renderer?.clearToBlack()
        // No picture, so no shape — the window must not stay locked to the departed stream's
        // aspect. HERE and not in `retirePull`, deliberately: the SWAP path goes through that one,
        // and clearing there would drop the window to the 16:9 fallback for the few frames between
        // pulls rather than holding the old shape until the new one states its own. Same reasoning
        // as `isConnected` not dipping across a swap.
        frameRateEstimator.reset()
        lastPulledRaster = nil
        declaredFrameRate = nil
        rateDisagreementActive = false
        DeckLinkService.shared.setSourceAdvisory(nil)
        LiveDisplaySize.shared.clear()
        NSLog("[HLS] disconnected")
    }

    // MARK: - Plumbing

    private static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: Double) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
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

    /// The buffer's colour attachments as CICP codes — the form `setSourceColorSpace`, the shader
    /// matrix, the CIE scope and the parade's AUTO ruler all already speak.
    ///
    /// CoreVideo states these as CFStrings; the rest of the app states them as the integers the
    /// bitstream carries. This is the one translation, and anything unrecognised comes back nil
    /// rather than guessing — nil is "not declared", which every CICP reader in this app already
    /// treats as 709. Never invent a code for a stream that did not send one.
    private static func cicp(of buffer: CVPixelBuffer) -> (Int?, Int?, Int?) {
        func attachment(_ key: CFString) -> CFString? {
            guard let raw = CVBufferCopyAttachment(buffer, key, nil) else { return nil }
            let value = raw as AnyObject
            return CFGetTypeID(value) == CFStringGetTypeID() ? (value as! CFString) : nil
        }

        let primaries: Int? = {
            guard let p = attachment(kCVImageBufferColorPrimariesKey) else { return nil }
            switch p {
            case kCVImageBufferColorPrimaries_ITU_R_709_2:  return 1
            case kCVImageBufferColorPrimaries_EBU_3213:     return 5
            case kCVImageBufferColorPrimaries_SMPTE_C:      return 6
            case kCVImageBufferColorPrimaries_ITU_R_2020:   return 9
            case kCVImageBufferColorPrimaries_P3_D65:       return 11
            default:                                        return nil
            }
        }()

        let transfer: Int? = {
            guard let t = attachment(kCVImageBufferTransferFunctionKey) else { return nil }
            switch t {
            case kCVImageBufferTransferFunction_ITU_R_709_2:      return 1
            case kCVImageBufferTransferFunction_SMPTE_240M_1995:  return 7
            case kCVImageBufferTransferFunction_sRGB:             return 13
            // ⚠️ 1, NOT 14. CICP 14/15 ("BT.2020 10/12-bit") name the SAME transfer CURVE as 709 at
            // greater precision; the renderer's table (1=709, 13=sRGB, 16=PQ, 18=HLG) keys off the
            // curve. Reporting 14 would fall through to the gamma-2.4 default — the same picture,
            // by accident rather than on purpose — so the curve is named directly.
            case kCVImageBufferTransferFunction_ITU_R_2020:       return 1
            case kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ: return 16
            case kCVImageBufferTransferFunction_ITU_R_2100_HLG:   return 18
            default:                                              return nil
            }
        }()

        let matrix: Int? = {
            guard let m = attachment(kCVImageBufferYCbCrMatrixKey) else { return nil }
            switch m {
            case kCVImageBufferYCbCrMatrix_ITU_R_709_2:     return 1
            case kCVImageBufferYCbCrMatrix_ITU_R_601_4:     return 6
            case kCVImageBufferYCbCrMatrix_SMPTE_240M_1995: return 7
            case kCVImageBufferYCbCrMatrix_ITU_R_2020:      return 9
            default:                                        return nil
            }
        }()

        return (primaries, transfer, matrix)
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
