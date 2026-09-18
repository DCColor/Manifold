//
//  HLSAudioTap.swift
//  Manifold
//
//  HLS audio: an `MTAudioProcessingTap` on the player item's audio mix → `AudioTapBuffer`, the
//  SAME PTS-keyed Int32 ring NDI, WHEP and SRT already feed — so the meters move and the SDI
//  embed has real PCM available to it. The tap PASSES THE SAMPLES THROUGH rather than consuming
//  them, so the stream is also audible on the default output device, played by AVFoundation.
//
//  ⚠️ "AVAILABLE TO IT" IS DELIBERATELY WEAKER THAN "REACHES THE WIRE", AND THE GAP IS NOT OURS.
//  `FrameEngine.applyAudioMute` ends with `setCardAudioSilent(isMuted || shuttleRate != 1)`, and
//  `shuttleRate` IS ZERO FOR EVERY LIVE SOURCE — nothing in the NDI, WHEP, SRT or HLS paths calls
//  `setShuttleRate`, and `stop()` (which a live takeover calls) zeroes it. So `isCardAudioSilent()`
//  returns true, `DeckLinkBridge`'s `RenderAudioSamples` takes its `if (silent)` branch, and the
//  card is scheduled SILENCE. By that reading no live transport has ever embedded audio on SDI,
//  and the rule's own comment says why it was written that way — for a PAUSED FILE, whose "source
//  time is frozen, so re-serving the same window at 50 Hz would drone". A live feed's source time
//  is not frozen, so the reasoning does not transfer.
//
//  This is a READING OF THE CODE, contradicted by a report that HLS SDI audio works, and it is
//  UNRESOLVED. It is recorded here rather than acted on because the fix belongs to that rule and
//  would change NDI, WHEP and SRT too. Do not cite this file as evidence that SDI carries HLS
//  audio until someone has listened to the wire.
//
//  Nothing here touches `AVSampleBufferAudioRenderer`, `beginLiveAudio`, `LiveClock` or the
//  synchronizer. For WHEP and SRT that machinery is what makes audio audible at all; for a PULL
//  source it is redundant, because `AVPlayer` already owns an output path. The price is that the
//  engine's mute rule does not reach this transport — see the mute section below, which states it
//  in full rather than leaving it to be discovered.
//
//  ══════════════════════════════════════════════════════════════════════════════════════════
//  ⚠️ THE CLOCK IS FREE, AND IT WAS MEASURED. DO NOT ADD A CONTROL LOOP HERE.
//  ══════════════════════════════════════════════════════════════════════════════════════════
//
//  Audio and video out of an `AVPlayerItem` are TWO READS OF ONE CLOCK. The item's timebase drives
//  both, and on this machine its source clock is the audio output device itself — measured, printed
//  by the probe as `FigClock[AudioDeviceClock(deviceID=154, trackDefaultDevice=true)]`. AVFoundation
//  is ALREADY doing the lip-sync. There is nothing to reconcile.
//
//  MEASURED on Apple's bipbop ladder, macOS 26.5.1, 238 consecutive callbacks over 20 s:
//
//    * the tap's `timeRangeOut` is on the ITEM'S timeline — it started at 0.0000 and advanced
//      0.08533 s per callback with **0 backwards steps and 0 discontinuities > 2 ms**;
//    * it leads presentation by a CONSTANT render-ahead — `range.start − CMTimebaseGetTime(item
//      .timebase)` read at the same instant inside the callback was +0.2910, +0.2909, +0.2910,
//      +0.2909 … across the whole run, i.e. flat to ±0.1 ms after the first few callbacks;
//    * the item↔host mapping is flat too: `hostTime − itemTime` moved −0.000266 s over 39.7 s with
//      **zero steps > 10 ms**, a residual of −7.8 ppm which is the audio device crystal against
//      mach time and which NEVER ACCUMULATES because the mapping is re-read rather than integrated.
//
//  ⚠️ THE RENDER-AHEAD IS A PROPERTY OF THE OUTPUT DEVICE, NOT OF HLS, AND NOT A CONSTANT TO PIN.
//  It was +291 ms against a Scarlett 18i20 at 48 kHz here and has been reported at ~164 ms
//  elsewhere; `maxFrames` likewise measured 4096 here and 1024 elsewhere. NOTHING below hardcodes
//  either — the frame count comes from the callback argument and the lead falls out of the mapping.
//  A number baked in from one machine's audio interface is a bug waiting for a different one.
//
//  So the ENTIRE clock handling in this file is one line in `drain()`:
//
//      let offset = hostAtCallback - output.itemTime(forHostTime: hostAtCallback).seconds
//
//  …which expresses the tap's item time on the SAME host axis `HLSClient.pullFrame` stamps video
//  with, using the SAME `itemTime(forHostTime:)` mapping `HLSPull.capture()` already queries every
//  display tick. One reading, no state, no filter, no loop. That is not reconciliation — it is
//  using the free clock, and it is what lets DeckLink's `tap.read(framesStartingAt:)` find the
//  right samples, because that read is keyed to the VIDEO frame's PTS (see `makeAudioConfig` in
//  DeckLinkService, and `currentDeckLinkSourcePts()` in MetalVideoRenderer).
//
//  >>> IF YOU ARE HERE TO ADD A `LiveClock`, A SENTINEL, A CUSHION, AN EPOCH LATCH, A DRIFT PID OR
//  >>> A RATE SLEW: STOP. WHEP needed those because its audio and video arrive on separate SSRCs
//  >>> with independent random RTP bases and no common clock — that is why `WHEPAudioReceiver`
//  >>> carries a stage-1 "SSRCs ASSUMED aligned" assumption and why the `-.infinity` LiveClock
//  >>> sentinel fix existed. SRT needed three stages for its own reasons. NEITHER APPLIES HERE.
//  >>> The measurement above is the reason, and it is reproducible with the probe in the commit
//  >>> message. Re-measure before you add anything; do not add it because the other two have it.
//
//  ── ⚠️ WHAT *DOES* MOVE, MEASURED, AND WHY IT IS NOT A CLOCK PROBLEM ────────────────────────
//
//  "The clock is free" is a statement about DRIFT, not about CONTINUITY. Over a 25 s run of 292
//  callbacks the computed PTS never went backwards and advanced at exactly 1.0 on the host axis —
//  but it took FOUR steps larger than `AudioTapBuffer`'s 50 ms discontinuity tolerance:
//
//    · callbacks 1, 2, 3 — +0.085, +0.085, +0.120 s. This is the render-ahead RAMPING IN: the
//      first callback has ~0 lead and the steady +0.291 s is reached over about three buffers.
//      Harmless — the ring re-anchors during start-up, before anything is being metered.
//    · callback 147 — **+0.817 s, mid-stream**. A rebuffer or a rendition change; the item
//      timeline genuinely jumped and the PTS followed it, which is correct.
//
//  Each of those makes `AudioTapBuffer.append` take its re-anchor branch (`writeHead = 0;
//  framesWritten = 0; basePTS = pts`), which DROPS THE RETAINED WINDOW. The meters do not care —
//  they are `peaksOfNewest`-keyed — but `DeckLinkService`'s `read(framesStartingAt:)` will return
//  0 frames until the window refills, i.e. **a brief SDI audio dropout on a rendition change**.
//
//  THAT IS THE EXISTING, DESIGNED BEHAVIOUR AND IT IS NOT PAPERED OVER HERE. Following the jump is
//  right: the alternative is serving samples from before the discontinuity against picture from
//  after it. Recorded so the dropout is recognised as the ring doing its job rather than
//  rediscovered as an HLS audio bug.
//
//  ══════════════════════════════════════════════════════════════════════════════════════════
//  ⚠️ THE MUTE IS INVERTED FROM THE OBVIOUS GUESS — MEASURED, AND IT IS THE SURPRISING PART
//  ══════════════════════════════════════════════════════════════════════════════════════════
//
//  `AVPlayer.isMuted` sits UPSTREAM of the tap. With `isMuted = true` the callbacks keep firing at
//  full rate and EVERY BUFFER IS ZEROS — measured three independent times, 238/238 buffers, peak
//  exactly 0.0, including the buffers that carry a −1.8 dBFS beep when unmuted. A `PreEffects` tap
//  is no different (239/239 zeros): the Pre/Post distinction is about the MIX's effects, not the
//  player's mute stage. `AVPlayer.volume` scales the captured samples too — at volume 0.02 the same
//  source buffer peaked at −35.7 dBFS against −1.8 dBFS at 1.0, a 33.9 dB difference against the
//  33.98 dB the volume implies.
//
//  So "leave the player muted and tap it anyway" DOES NOT WORK, and it fails in the worst available
//  way: the callbacks fire, the format is established, `AudioTapBuffer` publishes a format, the
//  meters size their bars, DeckLink re-establishes its audio stream — and every sample is silence.
//  Everything downstream reports success over a signal that is not there. The player is therefore
//  UNMUTED AT VOLUME 1.0 — see `HLSPull.init`.
//
//  ── THE TAP PASSES AUDIO THROUGH, SO HLS IS AUDIBLE ON THE DESKTOP ─────────────────────────
//
//  `process` leaves `numberFramesOut` exactly as `MTAudioProcessingTapGetSourceAudio` set it and
//  leaves the source samples in place, so AVFoundation plays them to the default output device
//  itself. NO `AVSampleBufferAudioRenderer` IS INVOLVED and none is needed: `AVPlayer` already has
//  a complete output path, which is the one structural advantage a pull source has here.
//
//  This briefly returned 0 frames instead — MTAudioProcessingTap.h specifies the remainder is then
//  "filled with silence" — on the reasoning that stage 1 means "tap only, silent on the desktop,
//  as NDI and SRT stage 1 do". THAT REASONING WAS WRONG ABOUT SRT: `SRTFrameRouter` finished its
//  stage 2 ("AUDIBLE ON THE LIVE CLOCK … the only new consumer is the speaker") and WHEP has been
//  audible since the Opus work. NDI is the only silent transport, and copying it made HLS the
//  second one for no reason anybody had asked for.
//
//  ⚠️ VERIFIED THAT PASSTHROUGH DOES NOT DISTURB THE TAP, RATHER THAN ASSUMED. Two 20 s runs,
//  identical but for this one decision, produced byte-identical capture: 238 callbacks each,
//  200 all-zero / 38 signal-bearing buffers each, session peak 0.8164637 (−1.8 dBFS) in BOTH, and
//  the same ten loudest buffers at the same item times to 0.1 dB. What the tap RECEIVES is
//  independent of what it RETURNS — so the meters and the SDI embed read identically either way,
//  and this line can be changed back without touching them.
//
//  ── THE CONTROLS REACH IT, THROUGH THE TAP RATHER THAN THROUGH AVPlayer ────────────────────
//
//  Desktop audio here comes out of `AVPlayer`'s OWN output, NOT the engine's shared
//  `AVSampleBufferAudioRenderer`. Every other audible path — files, WHEP, SRT — goes through that
//  renderer and is governed by one line in `FrameEngine.applyAudioMute`:
//
//      audioRenderer.isMuted = isMuted || offSpeed || deckLinkOwnsAudio
//
//  None of those three terms can reach `AVPlayer` by itself, so the engine now hands the
//  ALREADY-COMBINED result to `FrameEngine.externalAudioOutput`, which `DeckRegistry` routes to
//  `HLSClient.applyAudioOutput` → `HLSPull.setMonitor` → `setMonitor` here. ONE RULE, COMPUTED
//  ONCE, APPLIED TO TWO OUTPUTS — not a second control.
//
//  ⚠️ IT IS APPLIED AT THE TAP'S OUTPUT, NOT AT `player.isMuted` / `player.volume`, AND THAT IS
//  FORCED BY MEASUREMENT RATHER THAN CHOSEN FOR TIDINESS — both of those sit upstream of the tap
//  and would take the meters and the SDI embed with them. The full reasoning, including why the
//  fader must stay pre-fader to match a file's meters, is on `setMonitor`.
//
//  ══════════════════════════════════════════════════════════════════════════════════════════
//  ⚠️ THE ATTACHMENT IS A WILDCARD trackID, AND THE DOCUMENTED FORM IS THE ONE THAT FAILS
//  ══════════════════════════════════════════════════════════════════════════════════════════
//
//  `AVMutableAudioMixInputParameters(track:)` — the form every example uses — produces a tap that
//  NEVER FIRES on an HLS item. Measured, isolated 20 s cells:
//
//      AVMutableAudioMixInputParameters(track: <item's audio assetTrack>)  → trackID 1 → 0 calls
//      bare AVMutableAudioMixInputParameters()  (kCMPersistentTrackID_Invalid) → 235 calls
//      bare params with .trackID set to the assetTrack's id               → trackID 5 → 0 calls
//
//  So it is not the initializer — ANY non-invalid trackID silences it. An HLS `AVURLAsset` vends no
//  `AVAssetTrack`s at all (`asset.tracks.count == 0`, measured) and the `AVPlayerItemTrack`'s
//  synthesised `assetTrack.trackID` is not even stable across sessions (1 in one run, 5 in another),
//  so it is not an identity worth keying to in the first place. DO NOT "FIX" THIS BY LOOKING THE
//  TRACK UP; that is the change that turns the audio off.
//

import AVFoundation
import CoreMedia
import MediaToolbox
import QuartzCore
import ManifoldCore

/// Owns one HLS session's audio tap: the `MTAudioProcessingTap`, the `AVAudioMix` it rides on, and
/// the hand-off from AVFoundation's real-time audio thread to `AudioTapBuffer`.
///
/// ⚠️ THIS TYPE EXISTS FOR ITS LIFETIME, exactly as `HLSPull` does, and `HLSPull` owns one. The
/// `retired` flag plus the weak-self guard is the same harmless-by-construction teardown the file
/// header of `HLSClient` describes — see `retire()`.
final class HLSAudioTap: @unchecked Sendable {

    // MARK: - Fixed capacities
    //
    // ⚠️ CEILINGS, NOT EXPECTATIONS. `maxFrames` is a property of the OUTPUT DEVICE (measured 4096
    // against a Scarlett 18i20; reported 1024 elsewhere) and the channel count is a property of the
    // RENDITION. Both are read at runtime; these only bound the preallocation.

    /// Widest interleaved channel count the relay carries. 16 covers 7.1.4 and every SMPTE layout
    /// an HLS ladder can plausibly declare. A wider feed is REFUSED and said out loud rather than
    /// folded down — see `process`.
    private static let maxChannels = 16
    /// Frames one slot can hold. 8192 is 170 ms at 48 kHz — 2× the widest `maxFrames` measured.
    private static let slotFrames = 8192
    /// Hand-off depth. 8 × 4096 frames ≈ 680 ms of slack against a stalled drain.
    private static let slotCount = 8
    /// 8 × 8192 × 16 × 4 B = 4 MB, allocated once at connect. Noise beside the ~555 MB an AVPlayer
    /// stack costs for a 4K ladder (docs/BUGS.md), and it is what makes the callback allocation-free.
    private static let slotStride = slotFrames * maxChannels

    // MARK: - Collaborators

    /// The SAME video output `HLSPull.capture()` pulls through. Held strongly: `HLSPull` owns both
    /// and they die together, so there is no cycle and no lifetime gap. This is the ONE thing this
    /// file uses for timing — see the clock note in the header.
    private let output: AVPlayerItemVideoOutput

    /// The engine's shared ring. Weak, like `SRTFrameRouter.audioTap` and `NDIService.audioTap`:
    /// the engine owns it, and a deck swap may take it away underneath a running stream.
    private weak var sink: AudioTapBuffer?

    private var tapRef: MTAudioProcessingTap?

    /// The mix to install on the player item. Nil when the tap could not be created, in which case
    /// this whole object is inert and HLS stays video-only rather than failing the connect.
    private(set) var audioMix: AVAudioMix?

    // MARK: - The retirement flag
    //
    // Written on main (`retire()`), read on AVFoundation's audio thread (`process`) and on our own
    // drain thread. `UnfairLock` rather than `NSLock` for exactly the reason its own doc gives: it
    // is taken on a real-time thread and on a lower-priority one, and `os_unfair_lock` donates
    // priority where a pthread mutex would leave an unbounded inversion.

    private let retiredLock = UnfairLock()
    private var _retired = false
    private var retired: Bool { retiredLock.lock(); defer { retiredLock.unlock() }; return _retired }

    // MARK: - Format, established in `prepare`
    //
    // ⚠️ THE SAMPLE RATE IS THE ONE THING ONLY `prepare` CAN TELL US. The process callback receives
    // an `AudioBufferList` and a frame count — no ASBD — so rate is captured here and re-captured
    // if AVFoundation re-prepares (which MTAudioProcessingTap.h says it may, "if the client performs
    // an operation that requires the underlying audio machinery to be torn down and rebuilt").
    // CHANNEL COUNT IS NOT TAKEN FROM HERE: it is derived per callback from the buffer list, so a
    // rendition that changes width is seen even if nothing re-prepares. See `process`.

    private let formatLock = UnfairLock()
    private var _sampleRate: Double = 0
    private var _isFloat = false
    private var _isPlanar = false
    private var _bitsPerChannel: UInt32 = 0
    private var _prepareChannels: UInt32 = 0
    private var _maxFrames = 0
    private var _prepares = 0

    // MARK: - The hand-off ring (single producer: the tap callback; single consumer: `drain`)

    private let slots: UnsafeMutablePointer<Int32>
    private let slotFrames: UnsafeMutablePointer<Int32>
    private let slotChannels: UnsafeMutablePointer<Int32>
    private let slotRate: UnsafeMutablePointer<Double>
    private let slotItemTime: UnsafeMutablePointer<Double>
    private let slotHostTime: UnsafeMutablePointer<Double>

    private let indexLock = UnfairLock()
    private var writeIndex: UInt64 = 0
    private var readIndex: UInt64 = 0
    private var droppedBuffers = 0

    // MARK: - The monitoring gate
    //
    // ⚠️ THE ENGINE'S MUTE/FADER DECISION IS APPLIED HERE, AT THE TAP'S OUTPUT — NOT AT
    // `AVPlayer.isMuted` / `AVPlayer.volume`, AND THE REASON IS MEASURED. See `setMonitor`.
    //
    // Written on the main actor (`setMonitor`), read on the real-time callback. `UnfairLock` for
    // the same priority-donation reason as `retiredLock`; two scalar reads per callback.

    private let monitorLock = UnfairLock()
    private var _monitorMuted = false
    private var _monitorGain: Float = 1.0

    private let filled = DispatchSemaphore(value: 0)

    private var drainThread: Thread?
    private var drainFinished: DispatchSemaphore?

    // MARK: - Reporting (drain thread only, except where noted)

    private var buffersRelayed = 0
    private var framesRelayed = 0
    private var lastHeartbeat: CFTimeInterval = 0
    private var lastChannels = 0
    private var lastRate: Double = 0
    private var haveLoggedFirst = false
    /// Counted on the callback thread under `indexLock`; read by the heartbeat.
    private var refusedTooWide = 0

    // MARK: - Lifecycle

    init(output: AVPlayerItemVideoOutput, sink: AudioTapBuffer?) {
        self.output = output
        self.sink = sink

        let total = Self.slotCount * Self.slotStride
        slots = .allocate(capacity: total)
        slots.initialize(repeating: 0, count: total)
        slotFrames = .allocate(capacity: Self.slotCount)
        slotFrames.initialize(repeating: 0, count: Self.slotCount)
        slotChannels = .allocate(capacity: Self.slotCount)
        slotChannels.initialize(repeating: 0, count: Self.slotCount)
        slotRate = .allocate(capacity: Self.slotCount)
        slotRate.initialize(repeating: 0, count: Self.slotCount)
        slotItemTime = .allocate(capacity: Self.slotCount)
        slotItemTime.initialize(repeating: 0, count: Self.slotCount)
        slotHostTime = .allocate(capacity: Self.slotCount)
        slotHostTime.initialize(repeating: 0, count: Self.slotCount)

        guard let tap = makeTap() else {
            NSLog("[HLS-AUDIO] MTAudioProcessingTapCreate failed — this stream stays VIDEO ONLY. "
                + "The picture is unaffected.")
            return
        }
        tapRef = tap

        // ⚠️ BARE PARAMETERS, `kCMPersistentTrackID_Invalid`. See the attachment note in the file
        // header: binding this to the item's audio track is the form that produces zero callbacks.
        let params = AVMutableAudioMixInputParameters()
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        audioMix = mix

        startDrain()
    }

    deinit {
        // The one line that proves the cycle described on `detach(from:)` was actually broken. If
        // this never prints after a disconnect, the tap is still holding its +1 on us.
        NSLog("[HLS-AUDIO] tap released — %d buffer(s) relayed this session", buffersRelayed)
        slots.deallocate()
        slotFrames.deallocate()
        slotChannels.deallocate()
        slotRate.deallocate()
        slotItemTime.deallocate()
        slotHostTime.deallocate()
    }

    /// MAIN THREAD, from `HLSPull.retire()`. The ORDER is the whole safety property and it mirrors
    /// `HLSPull.retire()` exactly:
    ///
    ///   1. the flag FIRST — after this no callback can enter the relay, and one already inside
    ///      finds `retired` on its next statement and returns having touched nothing;
    ///   2. THEN wake and JOIN the drain thread. Unlike the display tick, this thread is OURS, so a
    ///      join IS available here and is taken — the same guarantee `NDIService.stopAudioPump()`
    ///      gives, and for the same reason: after this returns, no push against `AudioTapBuffer`
    ///      is in flight;
    ///   3. the caller then detaches the mix (`item.audioMix = nil`) and tears the item down.
    ///
    /// ⚠️ THE TAP CALLBACK ITSELF IS NEVER JOINED, AND DOES NOT NEED TO BE. AVFoundation owns that
    /// thread and keeps calling until the mix is detached and the item released. That is why step 1
    /// exists: an in-flight callback after retirement is HARMLESS BY CONSTRUCTION — it reads the
    /// flag, returns 0 frames, and never dereferences the sink. This is NDI's rule applied to the
    /// one thread we cannot join, which is the same rule `HLSClient`'s header sets out for the
    /// display tick.
    func retire() {
        retiredLock.lock(); _retired = true; retiredLock.unlock()
        stopDrain()
    }

    /// The engine's audio decision, applied to this transport's output. MAIN ACTOR, from
    /// `HLSClient`, which receives it from `FrameEngine.externalAudioOutput` — so `muted` is the
    /// already-combined `isMuted || offSpeed || deckLinkOwnsAudio` and `volume` is the fader. This
    /// does not re-derive anything; it applies a decision made in one place.
    ///
    /// ── ⚠️ WHY THIS IS NOT `player.isMuted` AND `player.volume`, WHICH IS THE OBVIOUS WIRING ──
    ///
    /// Because BOTH OF THOSE SIT UPSTREAM OF THE TAP, measured:
    ///
    ///   · `player.isMuted = true` → the tap receives 238/238 ALL-ZERO buffers. Muting that way
    ///     would blank the METERS and the SDI embed along with the speakers.
    ///   · `player.volume = 0.02` → the tap's samples arrive at −35.7 dBFS against −1.8 dBFS at
    ///     1.0, i.e. scaled by exactly the fader value. Fading that way would make the METERS
    ///     follow the monitoring level.
    ///
    /// ⚠️ AND THE SECOND ONE WOULD DIVERGE FROM FILES, WHICH IS THE TEST THAT DECIDES THIS.
    /// `FrameEngine`'s file pump does `tap.ingest(next, path: .avFoundation)` and THEN
    /// `aRenderer.enqueue(next)`, while the fader lives on `audioRenderer.volume` — applied inside
    /// the renderer, after the tee. **A file's meters are therefore PRE-FADER**, and they keep
    /// moving while muted. Applying the fader at `player.volume` would make an HLS stream the one
    /// source whose meters fall when you turn the monitoring down. Matching the fader's behaviour
    /// between a file and a stream matters more than where the gain is physically applied, so it
    /// is applied at the same point in the chain: after the tap, before the output.
    ///
    /// The scale needs no conversion. `AVSampleBufferAudioRenderer.volume` and `AVPlayer.volume`
    /// are documented in identical words — *"A value of 0.0 means silence all audio, while 1.0
    /// means play at the full volume of the audio media"* — with no curve stated on either, and
    /// the fader hands `FrameEngine.setVolume` a raw 0…1 `Slider` value that goes straight to
    /// `audioRenderer.volume`. So the same number is applied here as a linear gain, which is what
    /// both of those properties are.
    func setMonitor(muted: Bool, volume: Float) {
        monitorLock.lock()
        _monitorMuted = muted
        _monitorGain = max(0, min(1, volume))
        monitorLock.unlock()
    }

    /// Detach point for the mix, called by `HLSPull.retire()` AFTER `retire()` above. Separate so
    /// the ordering is visible at the call site rather than hidden in here: the flag stops the data
    /// path, this stops AVFoundation calling us at all.
    ///
    /// ── ⚠️ THIS IS ALSO WHERE THE RETAIN CYCLE IS BROKEN, AND IT IS NOT OPTIONAL ─────────────
    ///
    /// `makeTap()` hands `Unmanaged.passRetained(self)` to the tap as its `clientInfo`, because a
    /// C function pointer cannot capture context — so THE TAP HOLDS A +1 ON THIS OBJECT. This
    /// object holds the tap (`tapRef`, and again through `audioMix`). That is a cycle, and the
    /// balancing `release()` lives in the `finalize` callback, which AVFoundation only runs once
    /// the LAST reference to the tap goes away. If we keep ours, finalize never fires, the release
    /// never happens, and every HLS connect leaks an `HLSAudioTap` — its 4 MB relay included.
    ///
    /// Dropping all three references here is what lets that chain complete: our refs go, then
    /// AVFoundation's when it processes the detached mix, then finalize, then the release, then
    /// `deinit` frees the slots. Verified by the `deinit` log line.
    func detach(from item: AVPlayerItem) {
        item.audioMix = nil
        audioMix = nil
        tapRef = nil
    }

    // MARK: - Tap construction

    /// ⚠️ THE CALLBACKS ARE NON-CAPTURING CLOSURES BY NECESSITY — they become C function pointers,
    /// so context travels through `clientInfo` → `tapStorage` and is recovered with
    /// `MTAudioProcessingTapGetStorage`. `passRetained` here is balanced by `release()` in
    /// `finalize`, which AVFoundation calls exactly once when the tap object is destroyed.
    private func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<HLSAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, processingFormat in
                let me = Unmanaged<HLSAudioTap>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.prepare(maxFrames: maxFrames, format: processingFormat.pointee)
            },
            unprepare: { tap in
                let me = Unmanaged<HLSAudioTap>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.unprepare()
            },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                let me = Unmanaged<HLSAudioTap>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.process(tap: tap, numberFrames: numberFrames, flags: flags,
                           bufferList: bufferListInOut,
                           numberFramesOut: numberFramesOut, flagsOut: flagsOut)
            })

        var tap: MTAudioProcessingTap?
        // PostEffects: measured identical to PreEffects for both signal content and volume scaling,
        // so this is the conventional choice rather than a load-bearing one.
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            // Balance the retain we already handed to `clientInfo`: `finalize` will never run for a
            // tap that was not created, so without this the object leaks for the app's lifetime.
            if status != noErr, let raw = callbacks.clientInfo {
                Unmanaged<HLSAudioTap>.fromOpaque(raw).release()
            }
            NSLog("[HLS-AUDIO] MTAudioProcessingTapCreate → OSStatus %d", status)
            return nil
        }
        return tap
    }

    // MARK: - AVFoundation's audio thread

    private func prepare(maxFrames: CMItemCount, format: AudioStreamBasicDescription) {
        formatLock.lock()
        _sampleRate = format.mSampleRate
        _isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        _isPlanar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        _bitsPerChannel = format.mBitsPerChannel
        _prepareChannels = format.mChannelsPerFrame
        _maxFrames = Int(maxFrames)
        _prepares += 1
        let n = _prepares
        let rate = _sampleRate, ch = _prepareChannels, planar = _isPlanar, isFloat = _isFloat
        let bits = _bitsPerChannel
        formatLock.unlock()

        NSLog("[HLS-AUDIO] prepare #%d — %.0f Hz · %u ch · %u-bit %@ %@ · maxFrames=%ld (%.1f ms). "
            + "maxFrames is the OUTPUT DEVICE's, not the stream's; nothing here pins it.",
              n, rate, ch, bits, isFloat ? "float" : "int",
              planar ? "NON-INTERLEAVED" : "interleaved", Int(maxFrames),
              rate > 0 ? Double(maxFrames) / rate * 1000 : 0)
    }

    private func unprepare() {
        NSLog("[HLS-AUDIO] unprepare — the audio machinery was torn down; a re-prepare may follow")
    }

    /// ⚠️ REAL-TIME THREAD. MTAudioProcessingTap.h: *"A processing tap is a real-time operation, so
    /// the general Core Audio limitations for real-time processing apply. For example, care should
    /// be taken not to allocate memory or call into blocking system calls."*
    ///
    /// MEASURED: one dedicated thread for the whole session, never main, never migrating
    /// (`thread changed mid-session: 0 times`), QoS unspecified.
    ///
    /// ── WHY THIS DOES NOT CALL `AudioTapBuffer` DIRECTLY ────────────────────────────────────
    ///
    /// `pushInterleavedInt32` → `append` takes an `NSLock` that DECKLINK'S AUDIO CALLBACK ALSO TAKES
    /// AT 50 Hz, and reallocates the ring on a format change. Both are forbidden here. NDI and SRT
    /// push straight through because they own ordinary threads (NDI's pump, SRT's session thread);
    /// we are on a BORROWED real-time one, which is WHEP's situation — `WHEPAudioReceiver.receive`
    /// is on libdatachannel's network thread and its rule is *"Copies and gets off immediately."*
    /// That is the rule followed here, with the copy target preallocated because unlike WHEP's
    /// thread this one may not allocate.
    ///
    /// So: convert into a preallocated slot, signal, return. The push happens on `drain`.
    private func process(tap: MTAudioProcessingTap,
                         numberFrames: CMItemCount,
                         flags: MTAudioProcessingTapFlags,
                         bufferList: UnsafeMutablePointer<AudioBufferList>,
                         numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                         flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {

        // FIRST, BEFORE ANYTHING ELSE — the same line, in the same position, and for the same
        // reason as `HLSPull.capture()`'s. This is what makes a callback that raced the teardown
        // harmless rather than merely unlikely.
        guard !retired else { numberFramesOut.pointee = 0; return }

        // ⚠️ `timeRangeOut` IS THE WHOLE CLOCK STORY AND IT IS ASKED FOR HERE, ON THE ONE CALL THAT
        // CAN ANSWER IT. MTAudioProcessingTap.h: *"The asset time range corresponding to the
        // provided source audio frames."* It is populated only by the call that consumes the audio,
        // so it cannot be fetched later — passing nil here and trying to recover the time
        // afterwards is what makes a tap fall back to wall-clock timestamps and lose lip-sync.
        var sourceRange = CMTimeRange.invalid
        let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList,
                                                        flagsOut, &sourceRange, numberFramesOut)

        // ── ⚠️ PASSTHROUGH: `numberFramesOut` IS DELIBERATELY NOT TOUCHED FROM HERE ON ───────
        //
        // `MTAudioProcessingTapGetSourceAudio` has already set it to the frames it provided, and
        // the source samples are in `bufferList` in place. Leaving both alone IS the passthrough —
        // AVFoundation plays them to the default output device itself, with no
        // `AVSampleBufferAudioRenderer` in the path. See the mute section of the file header for
        // what that costs (the engine's mute rule does not reach `AVPlayer`).
        //
        // ⚠️ AND EVERY EARLY RETURN BELOW LEAVES IT ALONE TOO, WHICH IS THE POINT. This used to be
        // a `defer` that zeroed it on all paths; now a relay failure — a full ring, a refused
        // format, a too-wide feed — costs the METERS that buffer and NOT THE LISTENER. Audio
        // monitoring must not depend on the instrumentation succeeding, and the previous ordering
        // made a dropped relay buffer into an audible gap.
        //
        // The one exception is a FAILED `GetSourceAudio`: the buffer list may hold nothing usable,
        // so 0 frames (i.e. silence) is the only honest answer. Same for the retired guard above.
        guard status == noErr else { numberFramesOut.pointee = 0; return }

        // The host clock at the moment we were handed these samples. Paired with the item time
        // above, these two are everything the drain thread needs; the MAPPING between them is done
        // THERE, because `itemTime(forHostTime:)` is an AVFoundation call and does not belong on a
        // real-time thread.
        let hostAtCallback = CACurrentMediaTime()

        let frames = Int(numberFramesOut.pointee)
        guard frames > 0 else { return }

        // ── ⚠️ CHANNEL COUNT COMES FROM THE BUFFER LIST, EVERY CALLBACK, AND NOT FROM `prepare` ──
        //
        // An ABR rendition switch can move the format WITH THE TAP STILL ALIVE — measured: switching
        // audio rendition mid-stream produced no `unprepare`, no re-`prepare`, and the callbacks
        // continued. So a cached channel count from `prepare` would silently describe the previous
        // rendition. Derived here instead, and passed straight through to `AudioTapBuffer`, whose
        // OWN comparison (`currentFormat?.channelCount != ch`) then fires `onFormatChange` →
        // `DeckLinkService.audioFormatChanged`, which is what re-establishes the SDI stream. That
        // existing path is the notification; nothing new is invented to carry it.
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        let bufferCount = abl.count
        guard bufferCount > 0 else { return }

        let planar = bufferCount > 1 || abl[0].mNumberChannels == 1
        let channels = planar ? bufferCount : Int(abl[0].mNumberChannels)
        guard channels > 0 else { return }

        // ── ⚠️ THE MONITORING GATE, ON A `defer` SO THE ORDER IS GUARANTEED ─────────────────
        //
        // TWO PROPERTIES, AND BOTH COME FROM IT BEING A `defer` RATHER THAN A CALL HERE:
        //
        //  1. IT RUNS LAST, so every read above it — the interleave into the relay slot — sees the
        //     UNSCALED source. That is what keeps the meters pre-fader and identical to a file's.
        //     Scaling inline at this point would attenuate the meters along with the speakers.
        //  2. IT RUNS ON EVERY PATH, including the early returns below (full ring, refused format,
        //     too-wide feed). The user's mute must not be defeated by the relay having a bad
        //     buffer, and equally a relay failure must not punch an audible gap.
        defer { applyMonitor(abl, frames: frames, channels: channels, planar: planar,
                             numberFramesOut: numberFramesOut) }

        formatLock.lock()
        let rate = _sampleRate
        let isFloat = _isFloat
        let bits = _bitsPerChannel
        formatLock.unlock()
        guard rate > 0 else { return }

        // ⚠️ REFUSED, NOT FOLDED. A feed wider than the relay is a stated limit, not a licence to
        // downmix or truncate — `docs/AUDIO_PATH_FINDINGS.md` is explicit that a silent fold is the
        // failure mode that "sounds plausible rather than broken".
        guard channels <= Self.maxChannels, frames <= Self.slotFrames else {
            indexLock.lock(); refusedTooWide += 1; indexLock.unlock()
            return
        }

        // Only the shape this tap actually vends is handled. Measured: float32, planar. Anything
        // else is refused loudly by the heartbeat rather than mis-read into noise.
        guard isFloat, bits == 32 else {
            indexLock.lock(); refusedTooWide += 1; indexLock.unlock()
            return
        }

        // Reserve a slot WITHOUT blocking. A full ring drops this buffer and counts it; blocking
        // here would stall the audio render thread, which is the one thing that must never happen.
        indexLock.lock()
        let depth = writeIndex &- readIndex
        if depth >= UInt64(Self.slotCount) {
            droppedBuffers += 1
            indexLock.unlock()
            return
        }
        let slot = Int(writeIndex % UInt64(Self.slotCount))
        indexLock.unlock()

        // ── CONVERT + INTERLEAVE, OUTSIDE EVERY LOCK ────────────────────────────────────────
        //
        // ⚠️ Float32 → Int32 IS NOT AN AVOIDABLE CONVERSION, AND THERE IS NO FLOAT PATH TO USE
        // INSTEAD. `AudioTapBuffer`'s ring is `[Int32]` by design — it is the "card-ready" format
        // its own doc states ("32-bit signed integer, interleaved, source-native sample rate +
        // channel count"), both of its entry points land there (`ingest` converts float32 to Int32
        // itself; `pushInterleavedInt32` takes Int32 already), and DeckLink embeds Int32. So Int32
        // is the ring's contract, not a lossy step taken for convenience.
        //
        // ⚠️ THE ARITHMETIC IS COPIED FROM `AudioTapBuffer.ingest` DELIBERATELY, CLAMP AND ALL.
        // The meters' clip detector keys off `clipThresholdInt32` (−0.1 dBFS as an Int32 magnitude)
        // and the whole point of that threshold is that full-scale material lands exactly AT the
        // ceiling. A different rounding or a different scale here would make HLS meter differently
        // from every other producer for the same signal.
        let base = slot * Self.slotStride
        let dst = slots.advanced(by: base)
        if planar {
            for c in 0..<channels {
                guard let src = abl[c].mData?.assumingMemoryBound(to: Float.self) else { return }
                var d = c
                for f in 0..<frames {
                    let v = Double(src[f]) * 2147483648.0
                    dst[d] = v >= 2147483647.0 ? Int32.max
                           : (v <= -2147483648.0 ? Int32.min : Int32(v))
                    d += channels
                }
            }
        } else {
            guard let src = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<(frames * channels) {
                let v = Double(src[i]) * 2147483648.0
                dst[i] = v >= 2147483647.0 ? Int32.max
                       : (v <= -2147483648.0 ? Int32.min : Int32(v))
            }
        }

        slotFrames[slot] = Int32(frames)
        slotChannels[slot] = Int32(channels)
        slotRate[slot] = rate
        slotItemTime[slot] = sourceRange.start.isNumeric ? sourceRange.start.seconds : .nan
        slotHostTime[slot] = hostAtCallback

        // Publish AFTER the slot is fully written — the reader only ever looks below `writeIndex`.
        indexLock.lock(); writeIndex &+= 1; indexLock.unlock()
        filled.signal()
    }

    /// Apply the engine's decision to the samples on their way out. REAL-TIME THREAD, allocation
    /// free: at most one multiply per sample, skipped entirely at unity gain.
    ///
    /// MUTE IS `numberFramesOut = 0` rather than a multiply by zero — MTAudioProcessingTap.h:
    /// *"If less data is returned than requested, the remainder will be filled with silence."*
    /// That is cheaper and it is the documented way to emit nothing.
    private func applyMonitor(_ abl: UnsafeMutableAudioBufferListPointer,
                              frames: Int, channels: Int, planar: Bool,
                              numberFramesOut: UnsafeMutablePointer<CMItemCount>) {
        monitorLock.lock()
        let muted = _monitorMuted
        let gain = _monitorGain
        monitorLock.unlock()

        if muted {
            numberFramesOut.pointee = 0
            return
        }
        guard gain != 1.0, frames > 0 else { return }

        if planar {
            for c in 0..<min(channels, abl.count) {
                guard let p = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<frames { p[f] *= gain }
            }
        } else {
            guard let p = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<(frames * channels) { p[i] *= gain }
        }
    }

    // MARK: - Our drain thread

    /// Modelled on `NDIService.startAudioPump` — a named, `.userInteractive` thread we own, with a
    /// semaphore the stop path joins on. Owning it is what makes the join in `stopDrain()` possible.
    private func startDrain() {
        let done = DispatchSemaphore(value: 0)
        drainFinished = done
        let thread = Thread { [weak self] in self?.drain(finished: done) }
        thread.name = "com.manifold.hls.audio"
        thread.qualityOfService = .userInteractive
        drainThread = thread
        lastHeartbeat = CACurrentMediaTime()
        thread.start()
    }

    /// Signal and BLOCK until the drain has actually exited — so no `pushInterleavedInt32` is in
    /// flight when the caller goes on to dismantle the item. Idempotent. Bounded by one push.
    private func stopDrain() {
        guard drainThread != nil else { return }
        filled.signal()             // wake it so it can observe `retired`
        drainFinished?.wait()
        drainFinished = nil
        drainThread = nil
    }

    /// Ordinary priority thread: locks, logging and `AudioTapBuffer`'s ring are all legal here.
    private func drain(finished: DispatchSemaphore) {
        while true {
            filled.wait()
            if retired { break }

            indexLock.lock()
            guard readIndex != writeIndex else { indexLock.unlock(); continue }
            let slot = Int(readIndex % UInt64(Self.slotCount))
            indexLock.unlock()

            let frames = Int(slotFrames[slot])
            let channels = Int(slotChannels[slot])
            let rate = slotRate[slot]
            let itemTime = slotItemTime[slot]
            let hostAtCallback = slotHostTime[slot]

            if frames > 0, channels > 0, rate > 0, let sink {
                // ── THE ENTIRE CLOCK HANDLING, AND IT IS ONE SUBTRACTION ────────────────────
                //
                // Express the samples on the SAME host axis `HLSClient.pullFrame` stamps video
                // with, through the SAME mapping `HLSPull.capture()` already queries every display
                // tick. Measured flat — see the file header. No state is kept between iterations
                // BY DESIGN: re-reading is what stops the −7.8 ppm residual ever accumulating, and
                // it is why there is no filter here to tune.
                //
                // A non-numeric item time (the player has not established a timebase yet) falls
                // back to the callback's own host time, which is NDI's rule: label "now" samples
                // "now". Correct to within one callback, and only reachable at start-up.
                let pts: Double
                let mapped = output.itemTime(forHostTime: hostAtCallback)
                if itemTime.isFinite, mapped.isNumeric {
                    pts = itemTime + (hostAtCallback - mapped.seconds)
                } else {
                    pts = hostAtCallback
                }

                // THE SEAM. The same call NDI makes, with the same arguments in the same order —
                // see `NDIService.runAudioPump`. `roles` is left at its default empty, and that is
                // a MEASURED absence rather than an unimplemented feature: see `logFirstBuffer`.
                sink.pushInterleavedInt32(slots.advanced(by: slot * Self.slotStride),
                                          frameCount: frames,
                                          channelCount: channels,
                                          sampleRate: rate,
                                          pts: pts,
                                          path: .hls)

                buffersRelayed += 1
                framesRelayed += frames
                logFirstBuffer(frames: frames, channels: channels, rate: rate, pts: pts)
                logFormatMove(channels: channels, rate: rate)
            }

            indexLock.lock(); readIndex &+= 1; indexLock.unlock()
            heartbeat()
        }
        finished.signal()
    }

    // MARK: - Reporting (drain thread)

    private func logFirstBuffer(frames: Int, channels: Int, rate: Double, pts: Double) {
        guard !haveLoggedFirst else { return }
        haveLoggedFirst = true
        lastChannels = channels
        lastRate = rate
        NSLog("[HLS-AUDIO] first buffer — %d frames · %d ch · %.0f Hz · pts=%.3fs. "
            + "Channel ROLES are empty and that is MEASURED, not missing: an HLS AVURLAsset vends "
            + "no AVAssetTracks, the item's synthesised audio track carries NO AudioChannelLayout "
            + "(checked at runtime), and the tap's ASBD has none either. Empty means the meters "
            + "show NUMBERS, which is this codebase's stated answer for a source that declares "
            + "nothing — never a layout inferred from the count.",
              frames, channels, rate, pts)
    }

    /// The format moving mid-stream, said out loud. The ACTION is `AudioTapBuffer`'s — it compares
    /// rate and channel count on every push and fires `onFormatChange` itself — so this is purely
    /// the line that makes the event visible in the log next to the stream it happened on.
    private func logFormatMove(channels: Int, rate: Double) {
        guard haveLoggedFirst, channels != lastChannels || rate != lastRate else { return }
        NSLog("[HLS-AUDIO] ⚠️ format MOVED mid-stream: %d ch %.0f Hz → %d ch %.0f Hz. No unprepare "
            + "was required for this — an ABR rendition switch can change the shape with the tap "
            + "still alive, which is why the count is derived per callback. AudioTapBuffer's own "
            + "comparison fires onFormatChange from here, re-establishing the SDI audio stream.",
              lastChannels, lastRate, channels, rate)
        lastChannels = channels
        lastRate = rate
    }

    /// ⚠️ WALL CLOCK, NOT DELIVERED AUDIO — the same correction `WHEPAudioReceiver.heartbeat` and
    /// `HLSClient.heartbeatTick` both carry. A counter keyed to progress goes silent exactly when
    /// the thing it is meant to diagnose stops.
    private func heartbeat() {
        let now = CACurrentMediaTime()
        guard now - lastHeartbeat >= 5.0 else { return }
        lastHeartbeat = now
        indexLock.lock()
        let dropped = droppedBuffers, refused = refusedTooWide
        let depth = writeIndex &- readIndex
        indexLock.unlock()
        NSLog("[HLS-AUDIO] relayed %d buffer(s) · %.1f s of audio · %d ch · queue depth %u · "
            + "dropped %d · refused %d",
              buffersRelayed, lastRate > 0 ? Double(framesRelayed) / lastRate : 0,
              lastChannels, UInt32(depth), dropped, refused)
    }
}
