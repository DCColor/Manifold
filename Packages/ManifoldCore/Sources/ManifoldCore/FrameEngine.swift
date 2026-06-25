@preconcurrency import AVFoundation
import Combine

/// Frame-level playback engine (Step 4c-3c, concurrency-hardened): video + audio
/// via AVSampleBufferRenderSynchronizer. The frame pumps run on background queues
/// and capture LOCAL reader/output/renderer references (never reach through self),
/// with a per-session token so a seek can retire a stale pump cleanly. Only
/// published UI state is mutated on the main actor.
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
    public private(set) var tcInfo: TimecodeReader.Result?

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

    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private var reader: AVAssetReader?
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

    /// PlaybackEngine conformance: bare load defaults to autoplay.
    public func load(url: URL) {
        load(url: url, autoplay: true)
    }

    public func load(url: URL, autoplay: Bool) {
        currentURL = url
        Task { await loadAsset(url: url, autoplay: autoplay) }
    }

    /// If the current file's modification date has changed since it was opened
    /// (e.g. edited in Flip), re-read its metadata. Metadata-only — does not
    /// disturb playback (a metadata edit doesn't change the essence). Returns
    /// true if a refresh occurred. Constructs a FRESH asset to avoid AVFoundation
    /// serving cached metadata for the rewritten file.
    /// Re-read the current file's metadata from disk (e.g. after editing it in
    /// Flip). Metadata-only — does not disturb playback. Uses a fresh asset to
    /// avoid AVFoundation serving cached metadata for a rewritten file.
    public func reinspect() async {
        guard let url = currentURL else { return }
        let freshAsset = AVURLAsset(url: url)
        self.tcInfo = MediaInspector.timecode(for: url)
        let meta = await MediaInspector.metadata(for: freshAsset, url: url)
        self.metadata = meta
    }

    /// Set output gain (0–1). Writes through to the persistent audio renderer.
    /// Adjusting volume unmutes (standard behavior). Does not touch audio decode.
    public func setVolume(_ v: Float) {
        let clamped = min(1, max(0, v))
        volume = clamped
        audioRenderer.volume = clamped
        if isMuted {
            isMuted = false
            audioRenderer.isMuted = false
        }
    }

    public func toggleMute() {
        isMuted.toggle()
        audioRenderer.isMuted = isMuted
    }

    public func play() {
        synchronizer.rate = 1.0
        isPlaying = true
    }

    public func pause() {
        synchronizer.rate = 0
        isPlaying = false
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Fully stop playback and tear down the current reading session.
    public func stop() {
        _ = sessionToken.next()
        synchronizer.rate = 0
        videoRenderer?.stopRequestingMediaData()
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
        isPlaying = false
        currentTime = 0
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

    /// Generate a single preview frame (CGImage) at the given time, for scrub
    /// preview. Tolerant and downscaled for speed; isolated from the playback
    /// pump. Returns nil if generation fails.
    public func previewImage(at seconds: Double) async -> CGImage? {
        guard let generator = imageGenerator else { return nil }
        let time = CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600)
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

        if timeObserver == nil {
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                // This closure runs on .main; hop to the main actor explicitly.
                let t = CMTimeGetSeconds(time)
                guard t.isFinite else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.duration > 0 && t >= self.duration {
                        self.currentTime = self.duration
                        if self.isPlaying {
                            self.synchronizer.rate = 0
                            self.isPlaying = false
                        }
                    } else {
                        self.currentTime = t
                    }
                }
            }
        }

        print("FrameEngine: loaded — duration \(self.duration)s, audio: \(self.audioTrack != nil)")
        await beginReading(from: 0, resumePlaying: autoplay)
    }

    private func beginReading(from time: Double, resumePlaying: Bool) async {
        guard let asset, let vTrack = videoTrack, let videoRenderer else { return }

        // Retire any prior pump session.
        let token = sessionToken.next()

        synchronizer.rate = 0
        videoRenderer.stopRequestingMediaData()
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
        onFlush?()

        guard let newReader = try? AVAssetReader(asset: asset) else {
            print("FrameEngine: reader create failed"); return
        }
        let start = CMTime(seconds: time, preferredTimescale: 600)
        newReader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)

        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: videoSettings)
        vOut.alwaysCopiesSampleData = false
        guard newReader.canAdd(vOut) else { print("FrameEngine: cannot add video output"); return }
        newReader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        if let aTrack = audioTrack {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
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

        // Capture LOCALS for the pumps — no reaching through self.
        let vRenderer = videoRenderer
        let vReader = newReader
        let frameTap = onVideoFrame
        vRenderer.requestMediaDataWhenReady(on: videoPumpQueue) { [token, weak self] in
            guard let self, self.sessionToken.isCurrent(token) else {
                vRenderer.stopRequestingMediaData(); return
            }
            while vRenderer.isReadyForMoreMediaData {
                guard self.sessionToken.isCurrent(token) else {
                    vRenderer.stopRequestingMediaData(); return
                }
                guard vReader.status == .reading, let next = vOut.copyNextSampleBuffer() else {
                    vRenderer.stopRequestingMediaData(); return
                }
                vRenderer.enqueue(next)
                frameTap?(next)
            }
        }

        if let aOut {
            let aRenderer = audioRenderer
            let aReader = newReader
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
