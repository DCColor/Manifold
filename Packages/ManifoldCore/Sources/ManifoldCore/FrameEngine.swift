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
    public private(set) var tcInfo: TimecodeReader.Result?

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var videoRenderer: AVSampleBufferVideoRenderer?
    private let audioRenderer = AVSampleBufferAudioRenderer()

    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private var reader: AVAssetReader?
    private var timeObserver: Any?

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

    public func load(url: URL) {
        Task { await loadAsset(url: url) }
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
        _ = sessionToken.next()          // retire any in-flight pump
        synchronizer.rate = 0
        videoRenderer?.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        reader?.cancelReading()
        videoRenderer?.flush()
        audioRenderer.flush()
        isPlaying = false
        currentTime = 0
        hasMedia = false
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

    /// Scrub seek (tolerant) and exact seek both map to seek(to:) for now.
    public func scrubSeek(to seconds: Double) { seek(to: seconds) }
    public func exactSeek(to seconds: Double) { seek(to: seconds) }

    public func currentSourceTimecode(at seconds: Double) -> String? {
        guard let tc = tcInfo, tc.nfr > 0 else { return nil }
        let elapsedFrames = Int((seconds * Double(tc.nfr)).rounded())
        return TimecodeReader.format(frameCount: tc.startFrame + elapsedFrames,
                                     nfr: tc.nfr, fps: tc.fps, dropFrame: tc.dropFrame)
    }

    public func endSourceTimecode() -> String? {
        currentSourceTimecode(at: duration)
    }

    private func loadAsset(url: URL) async {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        self.hasMedia = true

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
        await beginReading(from: 0, resumePlaying: true)
    }

    private func beginReading(from time: Double, resumePlaying: Bool) async {
        guard let asset, let vTrack = videoTrack, let videoRenderer else { return }

        // Retire any prior pump session.
        let token = sessionToken.next()

        synchronizer.rate = 0
        videoRenderer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        reader?.cancelReading()
        videoRenderer.flush()
        audioRenderer.flush()

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
        let videoQueue = DispatchQueue(label: "com.graviton.manifold.pump.video")
        vRenderer.requestMediaDataWhenReady(on: videoQueue) { [token, weak self] in
            guard let self, self.sessionToken.isCurrent(token) else {
                vRenderer.stopRequestingMediaData(); return
            }
            while vRenderer.isReadyForMoreMediaData {
                guard vReader.status == .reading, let next = vOut.copyNextSampleBuffer() else {
                    vRenderer.stopRequestingMediaData(); return
                }
                vRenderer.enqueue(next)
            }
        }

        if let aOut {
            let aRenderer = audioRenderer
            let aReader = newReader
            let audioQueue = DispatchQueue(label: "com.graviton.manifold.pump.audio")
            aRenderer.requestMediaDataWhenReady(on: audioQueue) { [token, weak self] in
                guard let self, self.sessionToken.isCurrent(token) else {
                    aRenderer.stopRequestingMediaData(); return
                }
                while aRenderer.isReadyForMoreMediaData {
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
