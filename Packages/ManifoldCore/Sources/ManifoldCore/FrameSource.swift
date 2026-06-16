import CoreMedia

/// A source of decoded video frames.
///
/// This is a seam, not yet used. Later, each input becomes a `FrameSource`:
/// local file decode, NDI receive, SRT (demux + decode), and WHEP (WebRTC playback).
/// Because they all conform to one protocol, the renderer never has to know
/// where a frame came from.
public protocol FrameSource: AnyObject {
    /// Called whenever a new decoded video frame is ready.
    /// A `CMSampleBuffer` carries the pixels plus presentation timing and format info.
    var onVideoFrame: ((CMSampleBuffer) -> Void)? { get set }

    func start() throws
    func stop()
}
