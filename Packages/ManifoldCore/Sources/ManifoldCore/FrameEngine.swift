import AVFoundation
import Combine

/// Frame-level playback engine (Step 4c-3b): decode + play via
/// AVSampleBufferRenderSynchronizer, with seeking by rebuilding the reader at a
/// target time. Video only; audio + PlaybackEngine conformance still to come.
@MainActor
public final class FrameEngine: ObservableObject {

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var renderer: AVSampleBufferVideoRenderer?

    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private let pumpQueue = DispatchQueue(label: "com.graviton.manifold.framepump")
    private var timeObserver: Any?

    public init() {}

    public func attach(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
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

    /// Seek to a time in seconds: rebuild the reader positioned there.
    public func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        Task { await beginReading(from: clamped, resumePlaying: isPlaying) }
    }

    private func loadAsset(url: URL) async {
        let asset = AVURLAsset(url: url)
        self.asset = asset

        if let dur = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(dur)
            if seconds.isFinite { self.duration = seconds }
        }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            print("FrameEngine: no video track")
            return
        }
        self.videoTrack = track

        if timeObserver == nil {
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self else { return }
                let t = CMTimeGetSeconds(time)
                if t.isFinite { self.currentTime = t }
            }
        }

        print("FrameEngine: loaded — duration \(self.duration)s")
        await beginReading(from: 0, resumePlaying: true)
    }

    /// Build a fresh reader starting at `time` and (re)start the frame pump.
    private func beginReading(from time: Double, resumePlaying: Bool) async {
        guard let asset, let track = videoTrack, let renderer else { return }

        // Tear down the current session.
        synchronizer.rate = 0
        renderer.stopRequestingMediaData()
        reader?.cancelReading()
        renderer.flush()

        guard let newReader = try? AVAssetReader(asset: asset) else {
            print("FrameEngine: reader create failed"); return
        }
        // Start the read at the target time.
        let start = CMTime(seconds: time, preferredTimescale: 600)
        newReader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard newReader.canAdd(output) else { print("FrameEngine: cannot add output"); return }
        newReader.add(output)
        guard newReader.startReading() else {
            print("FrameEngine: startReading failed: \(String(describing: newReader.error))"); return
        }

        self.reader = newReader
        self.trackOutput = output

        // Reset the clock to the seek target.
        synchronizer.setRate(0, time: start)

        renderer.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            guard let self else { return }
            guard let output = self.trackOutput, let renderer = self.renderer else { return }
            while renderer.isReadyForMoreMediaData {
                guard self.reader?.status == .reading,
                      let next = output.copyNextSampleBuffer() else {
                    renderer.stopRequestingMediaData()
                    return
                }
                renderer.enqueue(next)
            }
        }

        if resumePlaying { play() }
        print("FrameEngine: reading from \(time)s")
    }
}
