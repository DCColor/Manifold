import AVFoundation
import Combine

/// Step-2 playback engine: AVPlayer plus accurate transport state and the
/// loaded clip's display size (for sizing the window to the video).
@MainActor
public final class AVPlayerEngine: ObservableObject {

    public let player = AVPlayer()

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0

    /// The clip's correct *display* size in points (accounts for non-square
    /// pixels / anamorphic). nil until a clip is loaded and resolved.
    @Published public private(set) var displaySize: CGSize?

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
            self.currentTime = time.seconds
            if let dur = self.player.currentItem?.duration.seconds, dur.isFinite {
                self.duration = dur
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
        resolveDisplaySize(for: asset)
    }

    /// Load the first video track's size + preferred transform off the main
    /// thread, compute the true display rect, then publish it on the main thread.
    private func resolveDisplaySize(for asset: AVURLAsset) {
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let naturalSize = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform)
            else { return }
            // Applying the track's transform yields the correct display shape,
            // including rotation and anamorphic pixel-aspect correction.
            let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            let size = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
            await MainActor.run {
                self.displaySize = size
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
}
