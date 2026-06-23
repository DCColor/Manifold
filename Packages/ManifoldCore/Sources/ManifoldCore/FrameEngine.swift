import AVFoundation
import Combine

/// Frame-level playback engine (Step 4c, in progress).
///
/// Decodes a file into CMSampleBuffers via AVAssetReader. In 4c-1 it only
/// decodes and hands over the FIRST frame (proving decode → surface). Timing,
/// playback, and PlaybackEngine conformance arrive in 4c-2 / 4c-3.
@MainActor
public final class FrameEngine: ObservableObject {

    /// Called with each decoded frame ready for display.
    /// The surface's enqueue() is hooked up to this.
    public var onFrame: ((CMSampleBuffer) -> Void)?

    public init() {}

    /// 4c-1: decode and emit just the first video frame of the file.
    public func loadFirstFrame(url: URL) {
        Task {
            await decodeFirstFrame(url: url)
        }
    }

    private func decodeFirstFrame(url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            print("FrameEngine: no video track")
            return
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            print("FrameEngine: could not create reader")
            return
        }
        // Decode to a pixel format the display layer accepts.
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            print("FrameEngine: cannot add output")
            return
        }
        reader.add(output)
        guard reader.startReading() else {
            print("FrameEngine: startReading failed: \(String(describing: reader.error))")
            return
        }
        guard let sample = output.copyNextSampleBuffer() else {
            print("FrameEngine: no first sample")
            return
        }
        print("FrameEngine: decoded first frame OK")
        let frame = sample
        await MainActor.run {
            self.onFrame?(frame)
        }
    }
}
