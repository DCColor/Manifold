import AVFoundation
import AudioToolbox
import Combine

@MainActor
public final class AVPlayerEngine: ObservableObject, PlaybackEngine {

    public let player = AVPlayer()

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var displaySize: CGSize?
    @Published public private(set) var hasMedia = false
    @Published public private(set) var metadata: VideoMetadata?

    /// Raw start-timecode info for the loaded clip (nil if no TC track).
    public private(set) var tcInfo: TimecodeReader.Result?

    private var timeObserverToken: Any?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = (status == .playing)
            }
            .store(in: &cancellables)

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            let dur = self.player.currentItem?.duration.seconds
            Task { @MainActor in
                self.currentTime = seconds
                if let dur, dur.isFinite { self.duration = dur }
            }
        }

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isPlaying = false
            }
            .store(in: &cancellables)
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
    }

    public func load(url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        currentTime = 0
        duration = 0
        displaySize = nil
        metadata = nil
        tcInfo = nil
        hasMedia = true
        Task {
            let size = await MediaInspector.displaySize(for: asset)
            await MainActor.run { self.displaySize = size }
        }
        Task {
            let meta = await MediaInspector.metadata(for: asset, url: url)
            let tc = MediaInspector.timecode(for: url)
            await MainActor.run {
                self.metadata = meta
                self.tcInfo = tc
            }
        }
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func scrubSeek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
    }

    public func exactSeek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Current frame number from the START of the file (0-based, like Resolve).
    public var currentFrame: Int {
        let fps = (metadata?.frameRate ?? 0) > 0 ? metadata!.frameRate : 24
        return Int((currentTime * fps).rounded())
    }

    /// Total frame count of the clip (0-based: last frame = total - 1).
    public var totalFrames: Int {
        let fps = (metadata?.frameRate ?? 0) > 0 ? metadata!.frameRate : 24
        return max(Int((duration * fps).rounded()) - 1, 0)
    }

    /// Live source timecode at the current position (start TC + elapsed frames).
    /// nil if the file has no timecode track.
    public func currentSourceTimecode(at seconds: Double) -> String? {
        guard let tc = tcInfo, tc.nfr > 0 else { return nil }
        let elapsedFrames = Int((seconds * Double(tc.nfr)).rounded())
        return TimecodeReader.format(frameCount: tc.startFrame + elapsedFrames,
                                     nfr: tc.nfr, fps: tc.fps, dropFrame: tc.dropFrame)
    }

    /// Source timecode at the END of the clip.
    public func endSourceTimecode() -> String? {
        currentSourceTimecode(at: duration)
    }
}
