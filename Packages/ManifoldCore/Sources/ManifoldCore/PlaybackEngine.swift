import Foundation
import AVFoundation

/// The interface any Manifold playback engine exposes to the UI.
///
/// Today the only conformer is AVPlayerEngine (AVPlayer-backed). The future
/// frame-level engine (AVSampleBufferRenderSynchronizer) will conform to this
/// same contract, so the UI can drive either one through a shared surface.
///
/// NOTE: conformers are also ObservableObject (concrete) so SwiftUI observation
/// of the @Published properties keeps working — the UI holds a concrete type for
/// now; generic engine-swapping comes in a later step alongside the display
/// surface abstraction.
@MainActor
public protocol PlaybackEngine: AnyObject {
    // Observed state (these are @Published on the concrete conformer)
    var isPlaying: Bool { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var displaySize: CGSize? { get }
    var hasMedia: Bool { get }
    var metadata: VideoMetadata? { get }

    // Derived readouts
    var totalFrames: Int { get }

    // Transport / loading
    func load(url: URL)
    func play()
    func pause()
    func togglePlayPause()
    func scrubSeek(to seconds: Double)
    func exactSeek(to seconds: Double)

    // Timecode readouts
    func currentSourceTimecode(at seconds: Double) -> String?
    func endSourceTimecode() -> String?
}
