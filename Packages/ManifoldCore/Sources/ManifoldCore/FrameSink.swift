import CoreMedia

/// A consumer of decoded video frames.
///
/// This is a seam, not yet used. The on-screen renderer will always be a sink.
/// A Blackmagic DeckLink **output** (feeding a reference monitor) becomes an
/// optional second sink fed from the same decoded frames.
public protocol FrameSink: AnyObject {
    func consume(_ sampleBuffer: CMSampleBuffer)
}
