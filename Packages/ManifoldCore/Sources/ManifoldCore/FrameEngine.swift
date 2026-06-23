import AVFoundation
import Combine

/// Frame-level playback engine (Step 4c-2): decodes a file via AVAssetReader and
/// plays it through an AVSampleBufferRenderSynchronizer driving the surface's
/// renderer. Video only; play/pause via the synchronizer's rate. Seek, audio,
/// and PlaybackEngine conformance arrive in 4c-3.
@MainActor
public final class FrameEngine: ObservableObject {

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var renderer: AVSampleBufferVideoRenderer?

    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private let pumpQueue = DispatchQueue(label: "com.graviton.manifold.framepump")
    private var timeObserver: Any?

    public init() {}

    /// Attach the display surface's renderer. Call once when the surface exists.
    public func attach(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
        synchronizer.addRenderer(renderer)
    }

    /// Load a file and begin feeding frames to the attached renderer.
    public func load(url: URL) {
        Task { await start(url: url) }
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

    private func start(url: URL) async {
        guard let renderer else {
            print("FrameEngine: no renderer attached")
            return
        }

        // Stop any prior session.
        synchronizer.rate = 0
        renderer.flush()
        reader?.cancelReading()

        let asset = AVURLAsset(url: url)
        if let dur = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(dur)
            if seconds.isFinite { self.duration = seconds }
        }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let newReader = try? AVAssetReader(asset: asset) else {
            print("FrameEngine: reader setup failed")
            return
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard newReader.canAdd(output) else { print("FrameEngine: cannot add output"); return }
        newReader.add(output)
        guard newReader.startReading() else {
            print("FrameEngine: startReading failed: \(String(describing: newReader.error))")
            return
        }

        self.reader = newReader
        self.trackOutput = output

        // Start the clock at zero, then pump frames under the renderer's back-pressure.
        synchronizer.setRate(0, time: .zero)

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

        if timeObserver == nil {
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self else { return }
                let t = CMTimeGetSeconds(time)
                if t.isFinite { self.currentTime = t }
            }
        }

        print("FrameEngine: playback session started — duration \(self.duration)s")
        // Auto-start playback for the test.
        play()
    }
}
