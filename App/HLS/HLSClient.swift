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

    private let retiredLock = NSLock()
    private var _retired = false
    private var retired: Bool { retiredLock.lock(); defer { retiredLock.unlock() }; return _retired }

    init(url: URL, pixelFormat: OSType) {
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
        player.isMuted = true   // stage 1 is VIDEO ONLY — see HLSClient

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
    func capture() -> CVPixelBuffer? {
        // FIRST, BEFORE ANY AVFOUNDATION CALL. This is the line that makes a tick which raced the
        // teardown harmless rather than merely unlikely.
        guard !retired else { return nil }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        return output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
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
        player.rate = 0
        player.cancelPendingPrerolls()
        item.remove(output)
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - The service

/// HLS receive. One at a time, arbitrated through `LiveSource`.
///
/// ⚠️ VIDEO ONLY, DELIBERATELY, AND SAID OUT LOUD RATHER THAN LEFT TO BE DISCOVERED. The player is
/// muted and no `audioTap` is wired, so the meters stay still and SDI embeds silence. This is the
/// same stage-1 position SRT shipped in (tap only, then the renderer), and it is honest for the QC
/// use — the feature is "put the scopes on the egress feed", and the scopes are visual. Reaching
/// audio means an `AVAudioMix`/tap on the item feeding `engine.audioTap`, which is a second
/// mechanism with its own clock question, not a line in this file.
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

    /// Retire whatever else is driving the display, just before we take it. Installed once by
    /// `DeckRegistry.init` alongside NDI's, WHEP's and SRT's — the deck losing the display gets a
    /// full `stop()` (so no departed file's duration, timecode, aspect, colour tags or clean
    /// aperture survive behind the stream) and every other deck merely yields its transport.
    var onWillActivateStream: (() -> Void)?

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

        let fresh = HLSPull(url: url, pixelFormat: Self.videoPixelFormat)
        pull = fresh
        generation &+= 1
        let token = generation

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
        renderer.setSourceColorSpace(primaries: 1, transfer: 1, matrix: 1)

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
    private func pullFrame() {
        guard let pull, let renderer else { return }
        guard let pixelBuffer = pull.capture() else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

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
        LiveDisplaySize.shared.publish(width: width, height: height)

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
            self.renderer?.setSourceColorSpace(primaries: codes.0, transfer: codes.1, matrix: codes.2)
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
