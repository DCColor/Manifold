@preconcurrency import AVFoundation
import Combine

/// Frame-level playback engine (Step 4c-3c, concurrency-hardened): video + audio
/// via AVSampleBufferRenderSynchronizer. The frame pumps run on background queues
/// and capture LOCAL reader/output/renderer references (never reach through self),
/// with a per-session token so a seek can retire a stale pump cleanly. Only
/// published UI state is mutated on the main actor.
/// User assertion of a clip's color range, overriding the file's tag. Transient
/// per-file (resets to `.auto` on each load) — never globally persisted, since
/// one file's correct override would be wrong for the next.
public enum RangeOverride: String, CaseIterable, Sendable {
    case auto    // trust the file's tag (full if tagged-full; else video/legal)
    case full    // force full-range decode regardless of tag
    case legal   // force video/legal-range decode regardless of tag

    public var label: String {
        switch self {
        case .auto:  return "Auto"
        case .full:  return "Full"
        case .legal: return "Legal"
        }
    }
}

/// How to interpret FULL-range chroma — a decode property, not a UI concept.
/// Two conventions exist in the wild (verified against real files):
///  - `.fullSwing`: chroma scale 255 (H.273 / full-swing spec). Renders a
///    spec-conformant full file (75% red Cr≈224) correctly.
///  - `.resolve`: chroma scaled by 219/224 (net ~260.8). Resolve expands
///    full-range chroma by the LUMA factor (255/219), storing Cr≈226 for 75%
///    red; this inverse renders Resolve full files correctly (~191).
/// Only affects the full-range path; legal is unchanged either way. The numeric
/// rawValue is passed to the shader.
public enum FullRangeChromaConvention: Int32, CaseIterable, Sendable {
    case fullSwing = 0
    case resolve   = 1

    /// The single shipping default — Resolve, the common case for this audience.
    public static let defaultConvention: FullRangeChromaConvention = .resolve

    public var label: String {
        switch self {
        case .fullSwing: return "Full-swing (spec)"
        case .resolve:   return "Resolve"
        }
    }
}

@MainActor
public final class FrameEngine: ObservableObject, PlaybackEngine {

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var displaySize: CGSize?
    @Published public private(set) var hasMedia = false
    @Published public private(set) var metadata: VideoMetadata?
    @Published public private(set) var currentURL: URL?
    // Audio output gain/mute (passthrough to the persistent audioRenderer).
    @Published public private(set) var volume: Float = 1.0
    @Published public private(set) var isMuted: Bool = false
    // JKL shuttle transport rate (transient session state — not persisted).
    // Signed: > 0 forward, 0 paused, < 0 reverse. Forward rates drive the
    // synchronizer directly; reverse is a best-effort jog (see setShuttleRate).
    @Published public private(set) var shuttleRate: Float = 0
    public private(set) var tcInfo: TimecodeReader.Result?

    /// Maximum shuttle multiplier in either direction (1 → 2 → 4 → 8).
    private let maxShuttleRate: Float = 8
    /// Reverse jog: the forward-only AVAssetReader pump cannot decode backward,
    /// so reverse "playback" is a timer that re-seeks toward the head. Best-effort.
    private var reverseTimer: Timer?
    private let reverseTickInterval: Double = 0.1

    /// Optional tap: called on the video pump queue with each decoded frame,
    /// in ADDITION to the normal display enqueue. Used by a parallel Metal
    /// renderer. Called on a background queue — consumers must hop threads as needed.
    public var onVideoFrame: ((CMSampleBuffer) -> Void)?

    /// Optional: called when the engine flushes for a seek/reload, so a parallel
    /// renderer can clear its frame queue. Called on the main actor.
    public var onFlush: (() -> Void)?

    nonisolated(unsafe) private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var videoRenderer: AVSampleBufferVideoRenderer?
    private let audioRenderer = AVSampleBufferAudioRenderer()

    /// D4b-1: PCM audio tap. Tees decoded audio at BOTH enqueue sites into a PTS-keyed, card-ready
    /// (int32 interleaved) ring buffer, WITHOUT altering what the renderer receives. Read by D4b-2's
    /// DeckLink audio callback; nothing is sent to the card yet. Captured as a local in the enqueue
    /// closures (like the renderers) so it never crosses the main-actor boundary.
    public let audioTap = AudioTapBuffer()

    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    /// The source's signaled range (from the format description), captured once
    /// per load. Combined with `rangeOverride` to derive the effective range.
    private var sourceRange: MediaInspector.SourceColorRange = .untagged
    /// User range assertion. Transient per-file: reset to `.auto` on each load.
    @Published public private(set) var rangeOverride: RangeOverride = .auto
    /// Effective full-range flag fed to the shader (override resolves source
    /// range). Decode is ALWAYS 420v (raw, unclipped); this flag — not the buffer
    /// format — decides whether the shader expands (legal/video) or passes through
    /// (full). Published for the UI.
    @Published public private(set) var effectiveIsFullRange: Bool = false
    /// Thread-safe mirror of `effectiveIsFullRange` for the render thread
    /// (CVDisplayLink), which cannot touch main-actor state.
    private nonisolated let rangeLock = NSLock()
    private nonisolated(unsafe) var effectiveRangeMirror = false
    /// Active full-range chroma convention (decode property). Default Resolve —
    /// the common case for this audience; full-swing/spec path retained. No
    /// runtime control yet — this is just the default + an inspector readout.
    @Published public private(set) var fullRangeChromaConvention: FullRangeChromaConvention = .defaultConvention
    /// Render-thread mirror of `fullRangeChromaConvention` (guarded by `rangeLock`).
    private nonisolated(unsafe) var chromaConventionMirror: Int32 = FullRangeChromaConvention.defaultConvention.rawValue
    /// Convention rawValue, readable from the render thread (CVDisplayLink).
    public nonisolated func currentChromaConventionRaw() -> Int32 {
        rangeLock.lock(); defer { rangeLock.unlock() }
        return chromaConventionMirror
    }
    private var audioTrack: AVAssetTrack?
    private var reader: AVAssetReader?
    /// The current file's video `FrameSource`. The file decode now flows through
    /// this (Stage 1 seam): it owns the video pump and emits frames via
    /// `onVideoFrame`, which we route to the display renderer + Metal tap below.
    /// Recreated per reading session (a seek retires the old one via `stop()`).
    private var currentSource: FileFrameSource?
    /// The libav-backed video source, used for formats VideoToolbox can't decode
    /// (DNxHR). Stage 2b first light: a single static frame. When set, the
    /// AVFoundation decode path is bypassed for this file.
    private var libavSource: LibavFrameSource?
    /// The libav audio sibling — decodes the DNx file's audio to PCM on the shared
    /// `audioRenderer` (same synchronizer → A/V sync). Nil if the file has no audio.
    private var libavAudioSource: LibavAudioSource?
    /// Set in `loadAsset` when the file's codec needs the libav path (DNxHR).
    private var useLibav = false
    /// Scrub-preview thumbnail generator for libav (DNx/MXF) files — a DETACHED decoder with
    /// its own AVFormatContext (AVAssetImageGenerator can't decode DNxHR). Opened at load for
    /// libav files, nil for AVFoundation files (which use `imageGenerator`). See previewImage.
    private var libavThumbnailSource: LibavThumbnailSource?
    /// Decoded video format requested at the decode-request site. A named property
    /// rather than a magic constant so the sources/decoders can vary it.
    /// M3b: 10-bit 420 biplanar (x420, raw video-range). 10-bit ProRes and DNxHR
    /// HQX now flow through at full bit depth; 8-bit sources decode cleanly into the
    /// 10-bit container. Range expansion stays in the shader (the VideoRange label
    /// is just the container — raw values are preserved, exactly as the 8-bit path).
    private let videoPixelFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    private var timeObserver: Any?
    private var imageGenerator: AVAssetImageGenerator?
    private let videoPumpQueue = DispatchQueue(label: "com.graviton.manifold.pump.video")
    private let audioPumpQueue = DispatchQueue(label: "com.graviton.manifold.pump.audio")

    /// Increments each new reading session; a pump checks its captured token
    /// against this and stops if it's been superseded (e.g. by a seek).
    private let sessionToken = SessionToken()

    public init() {
        synchronizer.addRenderer(audioRenderer)
    }

    public func attach(renderer: AVSampleBufferVideoRenderer) {
        self.videoRenderer = renderer
        synchronizer.addRenderer(renderer)
    }

    /// The synchronizer's current playback time, readable from any thread
    /// (e.g. a CVDisplayLink render loop). The synchronizer handles its own
    /// thread-safety for this call, so it is nonisolated despite @MainActor.
    public nonisolated func currentSyncTime() -> CMTime {
        synchronizer.currentTime()
    }

    /// True when transport is paused (synchronizer rate 0). Readable from any thread
    /// (the CVDisplayLink render loop), same thread-safety rationale as currentSyncTime().
    public nonisolated func isPausedNow() -> Bool {
        synchronizer.rate == 0
    }

    /// PlaybackEngine conformance: bare load defaults to autoplay.
    public func load(url: URL) {
        load(url: url, autoplay: true)
    }

    public func load(url: URL, autoplay: Bool) {
        currentURL = url
        Task { await loadAsset(url: url, autoplay: autoplay) }
    }

    /// Re-read the current file's metadata from disk (e.g. after editing it in
    /// Flip). Uses a FRESH asset to avoid AVFoundation serving cached metadata for
    /// a rewritten file. The inspector readout always refreshes (cheap, display-
    /// only). If the COLOR-relevant tags actually changed, the render path is
    /// re-derived to match exactly what a fresh open produces — otherwise playback
    /// is left completely undisturbed.
    ///
    /// Why the render path needs more than a metadata refresh: the shader reads the
    /// YCbCr→RGB matrix and transfer from the DECODED pixel buffer's attachments,
    /// and the range from `sourceRange` — both seeded from the DECODE asset, not the
    /// inspector. Re-reading metadata fixes the inspector (and, via the UI's
    /// metadata observer, the layer colorspace) but the decode keeps running on the
    /// stale asset, so the conversion matrix / transfer / range stay old until the
    /// file is reopened. Adopting the fresh asset for decode and rebuilding at the
    /// current position re-stamps buffers with the new attachments and re-reads the
    /// range — the same derivation a fresh open performs.
    public func reinspect() async {
        guard let url = currentURL else { return }
        let freshAsset = AVURLAsset(url: url)
        let newTc = MediaInspector.timecode(for: url)
        let newMeta = await MediaInspector.metadata(for: freshAsset, url: url)

        // Inspector always refreshes.
        let old = self.metadata
        self.tcInfo = newTc
        self.metadata = newMeta

        // Re-derive the render path ONLY when a color-relevant tag changed, so a
        // no-op refresh (or a non-color metadata edit) never disturbs playback.
        let colorChanged =
            old?.colorPrimariesCode   != newMeta.colorPrimariesCode ||
            old?.transferFunctionCode != newMeta.transferFunctionCode ||
            old?.colorMatrixCode      != newMeta.colorMatrixCode ||
            old?.colorRange           != newMeta.colorRange
        guard colorChanged else { return }

        // Adopt the fresh asset for DECODE too (the stale one may serve cached
        // format descriptions for the rewritten file).
        self.asset = freshAsset

        // Rebuild the scrub-preview generator on the fresh asset.
        let generator = AVAssetImageGenerator(asset: freshAsset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 960, height: 540)
        self.imageGenerator = generator

        guard let vTrack = try? await freshAsset.loadTracks(withMediaType: .video).first else { return }
        self.videoTrack = vTrack
        self.audioTrack = try? await freshAsset.loadTracks(withMediaType: .audio).first

        // Re-read the source range from the fresh format description and reset the
        // per-file override to Auto — a fresh open does the same; the new tags are
        // authoritative. updateEffectiveRange() pushes the thread-safe mirror the
        // render thread reads, so this can't race the CVDisplayLink.
        rangeOverride = .auto
        if let formats = try? await vTrack.load(.formatDescriptions), let fmt = formats.first {
            sourceRange = MediaInspector.sourceColorRange(for: fmt)
        } else {
            sourceRange = .untagged
        }
        updateEffectiveRange()

        // Rebuild the decode at the current position, preserving play state, so the
        // shader reads buffers stamped with the NEW color attachments. The layer
        // colorspace re-applies separately via the UI's metadata observer
        // (setSourceColorSpace, CATransaction-guarded).
        await beginReading(from: currentTime, resumePlaying: isPlaying)
    }

    /// Set output gain (0–1). Writes through to the persistent audio renderer.
    /// Adjusting volume unmutes (standard behavior). Does not touch audio decode.
    public func setVolume(_ v: Float) {
        let clamped = min(1, max(0, v))
        volume = clamped
        audioRenderer.volume = clamped
        if isMuted { isMuted = false }
        applyAudioMute()
    }

    public func toggleMute() {
        isMuted.toggle()
        applyAudioMute()
    }

    /// D4b-3: TRUE while DeckLink output is enabled AND the audio destination is SDI — i.e. the card
    /// owns the program audio, so the system (computer) renderer must be silent. The two paths are
    /// mutually exclusive: the same program never plays twice.
    ///
    /// This is the ONLY authority the destination has over the system renderer, and it is gated on
    /// DeckLink being enabled, not on the destination alone. When DeckLink output is disabled the App
    /// sets this false and the term simply drops out of the mute rule below — desktop playback returns
    /// to being governed by `isMuted` alone, no matter what the destination enum still says.
    private var deckLinkOwnsAudio = false

    /// Called by the App whenever the DeckLink enable state OR the audio destination changes. Routing
    /// only: it re-evaluates the existing mute, and adds no second mechanism.
    public func setDeckLinkOwnsAudio(_ owns: Bool) {
        guard deckLinkOwnsAudio != owns else { return }
        deckLinkOwnsAudio = owns
        applyAudioMute()
    }

    /// Effective renderer mute = the user's mute OR an active non-1× shuttle OR the SDI destination
    /// owning the program (D4b-3).
    /// Fast-forward replays audio at >1× (pitch/garble), so we mute off-speed and
    /// restore the user's choice when returning to 1× — standard NLE behavior.
    private func applyAudioMute() {
        let offSpeed = shuttleRate != 0 && shuttleRate != 1
        audioRenderer.isMuted = isMuted || offSpeed || deckLinkOwnsAudio
        // D4b-2: mirror the same decision for the SDI audio stream, which pulls from a callback thread
        // and cannot touch main-actor state. One addition the PULL model forces: PAUSE is silence too.
        // The system renderer gets that for free (a stopped synchronizer clock simply stops pulling);
        // the card asks for samples at ~50 Hz regardless, and the source time it asks at is frozen while
        // paused — so serving PCM would re-send the same window forever (a drone). Silence is the honest
        // answer. Net: real PCM only at exactly 1× forward, unmuted.
        setCardAudioSilent(isMuted || shuttleRate != 1)
    }

    /// D4b-2: thread-safe mirror of the SDI audio gate, readable from the DeckLink audio-callback
    /// thread (same rationale as `effectiveRangeMirror` for the render thread). TRUE → the SDI stream
    /// must carry silence. Starts true: nothing is playing at init.
    private nonisolated let cardAudioLock = NSLock()
    private nonisolated(unsafe) var cardAudioSilentMirror = true

    private nonisolated func setCardAudioSilent(_ silent: Bool) {
        cardAudioLock.lock(); cardAudioSilentMirror = silent; cardAudioLock.unlock()
    }

    /// True when the SDI audio stream must carry SILENCE — the user muted, or the transport is not at
    /// exactly 1× forward (paused, or an off-speed JKL shuttle whose audio the 1×-only decode pump
    /// cannot supply). The card is still fed zeros, never starved. Real scrub audio is a separate DSP
    /// feature, deliberately deferred.
    public nonisolated func isCardAudioSilent() -> Bool {
        cardAudioLock.lock(); defer { cardAudioLock.unlock() }
        return cardAudioSilentMirror
    }

    public func play() { setShuttleRate(1) }

    public func pause() { setShuttleRate(0) }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    // MARK: - JKL shuttle transport

    /// Core rate control. Positive rates are REAL forward playback driven by the
    /// synchronizer (the pump feeds frames as fast as the renderer requests).
    /// Zero pauses. Negative rates start a best-effort reverse jog (the
    /// forward-only reader can't decode backward — see startReverseJog).
    public func setShuttleRate(_ rate: Float) {
        let clamped = max(-maxShuttleRate, min(maxShuttleRate, rate))
        if clamped >= 0 { stopReverseJog() }
        shuttleRate = clamped
        applyAudioMute()
        if clamped > 0 {
            synchronizer.rate = clamped
            isPlaying = true
        } else if clamped == 0 {
            synchronizer.rate = 0
            isPlaying = false
        } else {
            synchronizer.rate = 0      // synchronizer can't drive the backward pump
            isPlaying = true
            startReverseJog()
        }
    }

    /// L — step forward (1 → 2 → 4 → 8). Tapping forward while reversed or paused
    /// snaps to 1× (direction switch interrupts).
    public func shuttleForward() {
        setShuttleRate(shuttleRate < 1 ? 1 : min(shuttleRate * 2, maxShuttleRate))
    }

    /// J — step reverse (-1 → -2 → -4 → -8). Tapping reverse while forward or
    /// paused snaps to -1× (direction switch interrupts).
    public func shuttleBackward() {
        setShuttleRate(shuttleRate > -1 ? -1 : max(shuttleRate * 2, -maxShuttleRate))
    }

    /// K — pause from any shuttle speed.
    public func shuttlePause() { setShuttleRate(0) }

    /// Step exactly one frame and pause (arrow-key jog). Re-seeks to the target
    /// frame via the reader and holds it at rate 0.
    public func stepFrame(by frames: Int) {
        let fps = (metadata?.frameRate ?? 0) > 0 ? metadata!.frameRate : 24
        setShuttleRate(0)
        let target = max(0, min(currentTime + Double(frames) / fps, duration))
        currentTime = target
        Task { await beginReading(from: target, resumePlaying: false) }
    }

    private func startReverseJog() {
        reverseTimer?.invalidate()
        let speed = -shuttleRate                 // positive magnitude
        let tick = reverseTickInterval
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reverseStep(speed: speed, tick: tick) }
        }
        RunLoop.main.add(timer, forMode: .common)
        reverseTimer = timer
    }

    private func reverseStep(speed: Float, tick: Double) {
        let newTime = currentTime - Double(speed) * tick
        if newTime <= 0 {
            currentTime = 0
            setShuttleRate(0)                    // hit the head — stop at 0
            return
        }
        currentTime = newTime
        Task { await beginReading(from: newTime, resumePlaying: false) }
    }

    private func stopReverseJog() {
        reverseTimer?.invalidate()
        reverseTimer = nil
    }

    /// Fully stop playback and tear down the current reading session.
    public func stop() {
        _ = sessionToken.next()
        stopReverseJog()
        shuttleRate = 0
        applyAudioMute()
        synchronizer.rate = 0
        currentSource?.stop()           // retire the video pump (FrameSource seam)
        currentSource = nil
        libavSource?.stop()             // retire the libav sources (DNxHR path)
        libavSource = nil
        libavAudioSource?.stop()
        libavAudioSource = nil
        libavThumbnailSource?.close()   // retire the detached scrub-thumbnail decoder
        libavThumbnailSource = nil
        audioRenderer.stopRequestingMediaData()

        let readerToCancel = reader
        reader = nil
        // Serialize cancellation behind both pump queues so it can't overlap an
        // in-flight copyNextSampleBuffer() on either queue.
        videoPumpQueue.async {
            self.audioPumpQueue.async {
                readerToCancel?.cancelReading()
            }
        }

        videoRenderer?.flush()
        audioRenderer.flush()
        audioTap.reset()   // D4b-1: drop buffered PCM so nothing survives a stop
        isPlaying = false
        currentTime = 0
        // A full teardown must leave NO transport readout from the departed source: the same
        // incoherence we fixed for scopes (blank-on-disconnect). duration + tcInfo drive the
        // scrubber range and the source/end-timecode readouts; without this a file→stream takeover
        // (this runs via onWillActivateStream) or a disconnect leaves the old file's end timecode
        // (e.g. 01:00:37:17) and scrubber length on screen behind the live source. A stream is not
        // seekable, so zeroed readouts (00:00:00 / empty scrubber) are the correct resting state —
        // no live-transport model is implied here. metadata is intentionally left alone: it drives
        // the metadata-onChange scope wiring, which the connecting stream immediately repopulates.
        duration = 0
        tcInfo = nil
        hasMedia = false
        currentURL = nil
    }

    public func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        Task { await beginReading(from: clamped, resumePlaying: isPlaying) }
    }

    /// Current frame from the start of the file (0-based).
    public var currentFrame: Int {
        let fps = (metadata?.frameRate ?? 0) > 0 ? metadata!.frameRate : 24
        return Int((currentTime * fps).rounded())
    }

    public var totalFrames: Int {
        let fps = (metadata?.frameRate ?? 0) > 0 ? metadata!.frameRate : 24
        return max(Int((duration * fps).rounded()) - 1, 0)
    }

    /// During a scrub drag: just track the target and show it on the clock,
    /// WITHOUT rebuilding the reader every tick (that storms the decoder).
    public func scrubSeek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        currentTime = clamped
    }

    /// On scrub release (or a discrete seek): do the real reader rebuild.
    public func exactSeek(to seconds: Double) {
        seek(to: seconds)
    }

    /// Generate a single preview frame (CGImage) at the given time, for scrub preview.
    /// Tolerant and downscaled for speed; isolated from the playback pump. Returns nil on
    /// failure. Libav files (DNx/MXF) use the detached libav thumbnail decoder; AVFoundation
    /// files (ProRes/H.264) use AVAssetImageGenerator — same published preview, same overlay.
    public func previewImage(at seconds: Double) async -> CGImage? {
        let clamped = max(0, min(seconds, duration))
        if useLibav {
            return await libavThumbnailSource?.thumbnail(at: clamped)
        }
        guard let generator = imageGenerator else { return nil }
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                continuation.resume(returning: image)
            }
        }
    }

    public func currentSourceTimecode(at seconds: Double) -> String? {
        guard let tc = tcInfo, tc.nfr > 0 else { return nil }
        let elapsedFrames = Int((seconds * Double(tc.nfr)).rounded())
        return TimecodeReader.format(frameCount: tc.startFrame + elapsedFrames,
                                     nfr: tc.nfr, fps: tc.fps, dropFrame: tc.dropFrame)
    }

    public func endSourceTimecode() -> String? {
        currentSourceTimecode(at: duration)
    }

    private func loadAsset(url: URL, autoplay: Bool) async {
        // New file: retire any prior libav sources (bound to the old file). The
        // per-file libav video+audio sources are created lazily in beginLibavReading.
        libavSource?.stop(); libavSource = nil
        libavAudioSource?.stop(); libavAudioSource = nil
        libavThumbnailSource?.close(); libavThumbnailSource = nil

        // MXF: AVFoundation can't demux it — route straight to libav (container-based
        // detection; not a VT-failed fallback). Its metadata comes from libav.
        if url.pathExtension.lowercased() == "mxf" {
            self.asset = nil
            self.videoTrack = nil
            await loadMXF(url: url, autoplay: autoplay)
            return
        }

        let asset = AVURLAsset(url: url)
        self.asset = asset
        self.hasMedia = true

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 960, height: 540)
        self.imageGenerator = generator

        // Same inspection as AVPlayerEngine, via the shared inspector.
        self.tcInfo = MediaInspector.timecode(for: url)
        Task { [weak self] in
            let meta = await MediaInspector.metadata(for: asset, url: url)
            await MainActor.run { self?.metadata = meta }
        }
        Task { [weak self] in
            let size = await MediaInspector.displaySize(for: asset)
            await MainActor.run { self?.displaySize = size }
        }

        if let dur = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(dur)
            if seconds.isFinite { self.duration = seconds }
        }
        guard let vTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            print("FrameEngine: no video track"); return
        }
        self.videoTrack = vTrack
        self.audioTrack = try? await asset.loadTracks(withMediaType: .audio).first

        // Range (8-bit): capture the SOURCE's signaled range (same format-
        // description determination the inspector uses) and reset the user
        // override to Auto for the new file (transient per-file). Decode is ALWAYS
        // 420v; the override drives the shader's expansion via effectiveIsFullRange.
        rangeOverride = .auto
        useLibav = false
        if let formats = try? await vTrack.load(.formatDescriptions), let fmt = formats.first {
            sourceRange = MediaInspector.sourceColorRange(for: fmt)
            // DNxHR can't decode through VideoToolbox; route it to libav. Its real
            // range (DNxHR/MXF ACLR) comes from libav's color_range, applied in
            // beginLibavReading — overriding the often-untagged AVFoundation read.
            useLibav = MediaInspector.requiresLibavDecode(fmt)
        } else {
            sourceRange = .untagged
        }
        updateEffectiveRange()

        // DNx-in-.mov decodes via libav → AVAssetImageGenerator can't make scrub thumbnails
        // (VideoToolbox rejects DNxHR). Open the detached libav thumbnail decoder instead; the
        // AVFoundation `imageGenerator` above stays for the non-libav (ProRes/H.264) files.
        if useLibav {
            let thumb = LibavThumbnailSource(url: url)
            thumb.openAsync()
            libavThumbnailSource = thumb
        }

        installTimeObserverIfNeeded()

        print("FrameEngine: loaded — duration \(self.duration)s, audio: \(self.audioTrack != nil)")
        await beginReading(from: 0, resumePlaying: autoplay)
    }

    /// The periodic clock observer that publishes `currentTime` and stops at the end.
    /// Shared by the AVFoundation and libav/MXF load paths (added once).
    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let t = CMTimeGetSeconds(time)
            guard t.isFinite else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.duration > 0 && t >= self.duration {
                    self.currentTime = self.duration
                    if self.isPlaying {
                        self.synchronizer.rate = 0
                        self.isPlaying = false
                        self.shuttleRate = 0
                        self.applyAudioMute()
                    }
                } else {
                    self.currentTime = t
                }
            }
        }
    }

    /// The MXF load path. AVFoundation has no MXF demuxer, so it can't open the file
    /// at all — MXF routes DIRECTLY to libav (not an AVFoundation-attempt-then-fall-
    /// back). All the facts AVFoundation normally supplies (duration, size, fps,
    /// color) are read from libav in `beginLibavReading` (gated on `videoTrack == nil`).
    private func loadMXF(url: URL, autoplay: Bool) async {
        self.hasMedia = true
        self.tcInfo = MediaInspector.timecode(for: url)   // nil for MXF; harmless
        self.imageGenerator = nil                          // AVFoundation can't open MXF at all
        self.videoTrack = nil                              // AVFoundation blind → libav supplies metadata
        self.audioTrack = nil
        self.rangeOverride = .auto
        self.useLibav = true
        // Scrub thumbnails come from the detached libav decoder (AVFoundation is blind to MXF).
        let thumb = LibavThumbnailSource(url: url)
        thumb.openAsync()
        libavThumbnailSource = thumb
        installTimeObserverIfNeeded()
        await beginReading(from: 0, resumePlaying: autoplay)
    }

    /// Populate the UI-facing metadata/duration/size from libav's stream facts, for
    /// the MXF path where AVFoundation supplies nothing. Color codes drive the layer
    /// colorspace (via the metadata observer → setSourceColorSpace) exactly as the
    /// AVFoundation-read codes do; the shader's YCbCr matrix still comes from the
    /// pixel-buffer attachment the source sets. Called on the main actor.
    private func applyLibavMetadata(_ info: LibavFrameSource.StreamInfo, url: URL) {
        if info.durationSeconds.isFinite, info.durationSeconds > 0 { self.duration = info.durationSeconds }
        if info.width > 0, info.height > 0 { self.displaySize = CGSize(width: info.width, height: info.height) }

        var meta = VideoMetadata()
        meta.fileName = url.lastPathComponent
        meta.container = url.pathExtension.uppercased()
        meta.codecName = info.codecName
        meta.width = info.width
        meta.height = info.height
        meta.frameRate = info.frameRate
        meta.colorPrimariesCode = info.primariesCode
        meta.transferFunctionCode = info.transferCode
        meta.colorMatrixCode = info.matrixCode
        // Resolve the human-readable names the SAME way the .mov path does (the
        // inspector renders `labeled(name, code)`; without the name it shows "— (1)").
        meta.colorPrimaries = MediaInspector.primariesName(forCode: info.primariesCode)
        meta.transferFunction = MediaInspector.transferName(forCode: info.transferCode)
        meta.colorMatrix = MediaInspector.matrixName(forCode: info.matrixCode)
        meta.colorRange = (info.isFullRange
            ? MediaInspector.SourceColorRange.full
            : MediaInspector.SourceColorRange.videoLegal).displayName
        meta.startTimecode = info.startTimecode   // MXF Material Package TC (libav)
        // Same HDR10 reader the AVFoundation path uses, so the inspector's HDR10 section
        // reads identically whichever backend supplied the rest of the metadata.
        meta.hdr10 = HDR10MetadataReader.read(url: url)

        // Feed the SAME transport time-display path the .mov tmcd path uses: build a
        // TimecodeReader.Result from libav's TC string + frame rate so the scrubber/
        // controls show REAL timecode (start TC + elapsed), not a 00:00:00 counter.
        // Nil string → no source TC (transport falls back to the elapsed counter).
        if let tcString = info.startTimecode {
            self.tcInfo = TimecodeReader.parse(timecode: tcString, fps: info.frameRate)
        }

        // Data rate: estimate from file size / duration (libav reports no per-stream
        // bit_rate for MXF DNxHR; video dominates so audio/overhead is negligible) —
        // same "estimated" spirit as the .mov path's estimatedDataRate.
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            meta.fileModifiedDate = attrs[.modificationDate] as? Date
            meta.fileCreatedDate = attrs[.creationDate] as? Date
            fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        if fileSize > 0, info.durationSeconds > 0 {
            meta.videoDataRate = Double(fileSize) * 8 / info.durationSeconds
        }
        self.metadata = meta
    }

    /// Resolve override + source range into the effective full-range flag the
    /// shader uses. Auto trusts the tag (full only if tagged-full); Full and Legal
    /// force their respective ranges. Decode stays 420v regardless — only this
    /// flag changes, so the shader expands (legal/video) or passes through (full).
    private func updateEffectiveRange() {
        let isFull: Bool
        switch rangeOverride {
        case .auto:  isFull = (sourceRange == .full)
        case .full:  isFull = true
        case .legal: isFull = false
        }
        effectiveIsFullRange = isFull
        rangeLock.lock(); effectiveRangeMirror = isFull; rangeLock.unlock()
    }

    /// Effective full-range flag, readable from the render thread (CVDisplayLink).
    public nonisolated func currentEffectiveIsFullRange() -> Bool {
        rangeLock.lock(); defer { rangeLock.unlock() }
        return effectiveRangeMirror
    }

    /// Apply a manual range override. Decode is always 420v, so the buffer never
    /// changes — only the shader's expansion flag does. No reader rebuild needed;
    /// the next rendered frame (or a forced refresh when paused) reflects it.
    public func setRangeOverride(_ override: RangeOverride) {
        guard override != rangeOverride else { return }
        rangeOverride = override
        updateEffectiveRange()
    }

    /// Stage 3a: the libav decode path (DNxHR), continuous clock-driven playback.
    /// The source is created+opened ONCE per file (then nil after a file change);
    /// each call seeks it to `time` and re-arms the decode pump with a fresh session
    /// token. The pump is paced by the SAME renderer backpressure the AVFoundation
    /// source uses, and the synchronizer is the master clock — so play/pause/seek
    /// all work through the existing transport.
    private func beginLibavReading(from time: Double, resumePlaying: Bool) async {
        guard let url = currentURL, let videoRenderer else { return }

        let token = sessionToken.next()
        synchronizer.rate = 0
        currentSource?.stop(); currentSource = nil      // retire any AVFoundation pump
        audioRenderer.stopRequestingMediaData()
        videoRenderer.stopRequestingMediaData()          // stop the prior pump arm
        videoRenderer.flush(); audioRenderer.flush(); audioTap.reset(); onFlush?()   // D4b-1: PTS discontinuity → drop stale PCM

        // Create + open once per file. The libav-reported range is authoritative for
        // DNxHR (ACLR), where AVFoundation's FullRangeVideo extension is often absent.
        if libavSource == nil {
            let source = LibavFrameSource(url: url,
                                          pixelFormat: videoPixelFormat,
                                          pacingRenderer: videoRenderer,
                                          pumpQueue: videoPumpQueue)
            do {
                // open() enables auto-threaded decode so the 4K 10-bit source cost
                // doesn't contend with the render pipeline (locks 23.976fps).
                let info = try source.open()
                sourceRange = info.isFullRange ? .full : .videoLegal
                updateEffectiveRange()
                // MXF: AVFoundation is blind to the container, so the UI facts
                // (duration/size/fps/color/codec) come from libav. .mov-DNx already
                // has them from AVFoundation (videoTrack set) — leave those untouched.
                if videoTrack == nil { applyLibavMetadata(info, url: url) }
                print("FrameEngine: libav opened — \(info.width)x\(info.height), "
                    + "src \(info.sourcePixelFormat), range \(info.rangeName), "
                    + "matrix \(info.matrixName), audio=\(info.hasAudio)")
            } catch {
                print("FrameEngine: libav open failed for \(url.lastPathComponent): \(error)")
                return
            }
            // Same consumer wiring as the AVFoundation source: reference renderer +
            // Metal tap, both fed off the source's onVideoFrame.
            let vRenderer = videoRenderer
            let frameTap = onVideoFrame
            source.onVideoFrame = { sb in
                vRenderer.enqueue(sb)
                frameTap?(sb)
            }
            libavSource = source

            // Audio (if present): decode the audio stream to interleaved-float PCM
            // and feed the SHARED audioRenderer on the SAME synchronizer → A/V sync
            // is free. Absent audio → video-only (no source created).
            let audio = LibavAudioSource(url: url, pacingRenderer: audioRenderer, pumpQueue: audioPumpQueue)
            if let ainfo = try? audio.open() {
                let aRenderer = audioRenderer
                let tap = audioTap   // local capture (thread-safe class) — no main-actor hop on the pump
                audio.onAudioFrame = { sb in
                    tap.ingest(sb, path: .libav)   // D4b-1 tee — does not alter the enqueued buffer
                    aRenderer.enqueue(sb)
                }
                libavAudioSource = audio
                print("FrameEngine: libav audio — \(ainfo.codecName) \(ainfo.sampleRate)Hz "
                    + "\(ainfo.channels)ch (\(ainfo.layoutName))")
            } else {
                print("FrameEngine: libav — no audio stream (video-only)")
            }
        }

        // Anchor the clock at the seek target, then seek + arm both pumps (video +
        // audio) with the SAME session token so they retire together cleanly.
        let session = sessionToken
        synchronizer.setRate(0, time: CMTime(seconds: time, preferredTimescale: 600))
        libavSource?.arm(fromSeconds: time, isCurrent: { session.isCurrent(token) })
        libavAudioSource?.arm(fromSeconds: time, isCurrent: { session.isCurrent(token) })
        if resumePlaying { play() }
    }

    private func beginReading(from time: Double, resumePlaying: Bool) async {
        if useLibav {
            await beginLibavReading(from: time, resumePlaying: resumePlaying)
            return
        }
        guard let asset, let vTrack = videoTrack, let videoRenderer else { return }

        // Retire any prior pump session.
        let token = sessionToken.next()

        synchronizer.rate = 0
        currentSource?.stop()           // retire the prior session's video pump
        currentSource = nil
        audioRenderer.stopRequestingMediaData()
        let oldReader = reader
        reader = nil
        videoPumpQueue.async {
            self.audioPumpQueue.async {
                oldReader?.cancelReading()
            }
        }
        videoRenderer.flush()
        audioRenderer.flush()
        audioTap.reset()   // D4b-1: PTS discontinuity on seek → drop stale PCM
        onFlush?()

        guard let newReader = try? AVAssetReader(asset: asset) else {
            print("FrameEngine: reader create failed"); return
        }
        let start = CMTime(seconds: time, preferredTimescale: 600)
        newReader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)

        // The file decode now flows through the FrameSource seam: FileFrameSource
        // owns the video output + pump and emits frames via onVideoFrame (wired to
        // the consumers below). Always decode videoPixelFormat (420v, raw video-
        // range): the file's stored values, unclipped — range handling happens in
        // the shader via effectiveIsFullRange, never by a full-range decode (which
        // would pre-expand and clip super-white / sub-black content).
        // Currency is gated by the session token — the SAME monotonic authority the
        // engine already uses (bumped to `token` above). A superseded source's pump
        // sees this go false and bows out without touching the shared renderer, so
        // rapid create→retire churn (J jog, aggressive scrub) can't let a dying
        // source cancel the live one.
        let session = sessionToken
        guard let source = FileFrameSource(reader: newReader,
                                           track: vTrack,
                                           pixelFormat: videoPixelFormat,
                                           pacingRenderer: videoRenderer,
                                           pumpQueue: videoPumpQueue,
                                           isCurrent: { session.isCurrent(token) }) else {
            print("FrameEngine: cannot add video output"); return
        }

        var aOut: AVAssetReaderTrackOutput?
        if let aTrack = audioTrack {
            // 32-bit signed int (not 16): a reference tool must not downconvert. 24-bit sources reach
            // the renderer + the D4b-1 audio tap at full precision; the tap reads the ASBD generically
            // (int32 pass-through), and AVSampleBufferAudioRenderer accepts int32 interleaved LPCM, so
            // the system-audio path is unaffected. This also matches the libav/MXF path's fidelity.
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let out = AVAssetReaderTrackOutput(track: aTrack, outputSettings: audioSettings)
            out.alwaysCopiesSampleData = false
            if newReader.canAdd(out) { newReader.add(out); aOut = out }
        }

        guard newReader.startReading() else {
            print("FrameEngine: startReading failed: \(String(describing: newReader.error))"); return
        }

        self.reader = newReader
        synchronizer.setRate(0, time: start)

        // Route the FrameSource's frames to the SAME two consumers as before:
        // the reference AVSampleBufferVideoRenderer (display + sync clock) and the
        // engine's Metal tap (onVideoFrame, set by the UI). Set unconditionally so
        // the display path enqueues even when no Metal tap is attached — exactly
        // the old pump's behavior, just routed through the protocol.
        let vRenderer = videoRenderer
        let frameTap = onVideoFrame
        source.onVideoFrame = { sb in
            vRenderer.enqueue(sb)
            frameTap?(sb)
        }
        self.currentSource = source
        try? source.start()

        if let aOut {
            let aRenderer = audioRenderer
            let aReader = newReader
            let tap = audioTap   // local capture (thread-safe class) — no main-actor hop on the pump
            aRenderer.requestMediaDataWhenReady(on: audioPumpQueue) { [token, weak self] in
                guard let self, self.sessionToken.isCurrent(token) else {
                    aRenderer.stopRequestingMediaData(); return
                }
                while aRenderer.isReadyForMoreMediaData {
                    guard self.sessionToken.isCurrent(token) else {
                        aRenderer.stopRequestingMediaData(); return
                    }
                    guard aReader.status == .reading, let next = aOut.copyNextSampleBuffer() else {
                        aRenderer.stopRequestingMediaData(); return
                    }
                    tap.ingest(next, path: .avFoundation)   // D4b-1 tee — does not alter the enqueued buffer
                    aRenderer.enqueue(next)
                }
            }
        }

        if resumePlaying { play() }
        print("FrameEngine: reading from \(time)s (audio: \(aOut != nil))")
    }
}

// AVAssetReader/AVAssetReaderTrackOutput predate Swift concurrency and have no
// Sendable annotation. Each session's instances are exclusively owned by one pump
// queue, so the unchecked conformance is safe.
extension AVAssetReader: @retroactive @unchecked Sendable {}
extension AVAssetReaderTrackOutput: @retroactive @unchecked Sendable {}

/// Thread-safe session counter so a background pump can tell if it's been
/// superseded by a newer reading session (seek/reload) without touching the
/// main actor.
private final class SessionToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
    func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == value
    }
}
