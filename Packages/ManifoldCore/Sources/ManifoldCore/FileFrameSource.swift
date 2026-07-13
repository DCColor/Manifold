@preconcurrency import AVFoundation

/// A `FrameSource` backed by an `AVAssetReader` reading a local file's video track.
///
/// Stage 1 of the FrameSource seam: the file decode pump that used to live inline
/// in `FrameEngine` is now expressed through the protocol. It produces decoded
/// `CMSampleBuffer`s and hands each one out through `onVideoFrame`; the engine
/// routes those to the same two consumers as before — the on-screen Metal renderer
/// (via the engine's tap) and the reference `AVSampleBufferVideoRenderer`. Frames
/// are byte-for-byte what the old pump produced, so playback is unchanged.
///
/// Scope (deliberately narrow for Stage 1): this owns ONLY the video pump and the
/// video output. The `AVAssetReader` itself is created and torn down by the engine
/// (it is shared with the still-in-engine audio path), and clock / transport / sync
/// remain in `FrameEngine`. The pump is paced by an `AVSampleBufferVideoRenderer`'s
/// readiness — the identical backpressure the old pump used. A later push-based
/// source (libav) will conform to the same `FrameSource` protocol but pace itself.
///
/// Lifecycle under rapid churn (J reverse-jog re-seeks ~10 Hz, a new source per
/// tick): currency is judged by the engine's session token — the SINGLE authority,
/// passed in as `isCurrent` — never a per-source flag that could race it. A
/// superseded pump invocation simply returns; it must NEVER call
/// `stopRequestingMediaData()` on the SHARED renderer, because by the time it runs
/// the next session has already re-armed that renderer and stopping it would kill
/// the live pump. Only the engine (ordered, on the main actor) and a genuine
/// end-of-stream stop the renderer.
public final class FileFrameSource: FrameSource, @unchecked Sendable {

    /// The decoded video output format, parameterized rather than hardcoded so a
    /// non-AVFoundation decoder can vary it without touching the pump. Raw video-range
    /// either way: the file's stored values, unclipped — range expansion happens in the
    /// shader, never in the decode.
    ///
    /// x420 = 10-bit 4:2:0 biplanar (M3b). This is only a fallback default — FrameEngine
    /// always passes `videoPixelFormat` explicitly and both decode paths (AVFoundation and
    /// libav) request x420. It MUST stay 10-bit: the shader's range-expansion constants are
    /// in the 10-bit sample domain (see kCodeMax in PassthroughShader.metal), so handing it
    /// an 8-bit buffer would expand with the wrong constants. It previously defaulted to
    /// 8-bit 420v, which was dead but would have been quietly wrong if ever exercised.
    public static let defaultPixelFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    /// Handed each decoded frame on the pump queue, in addition to nothing else —
    /// this is the only way frames leave the source. Set by the owner before
    /// `start()`. Called on a background queue; consumers hop threads as needed.
    public var onVideoFrame: ((CMSampleBuffer) -> Void)?

    private let output: AVAssetReaderTrackOutput
    private let reader: AVAssetReader
    private let pacingRenderer: AVSampleBufferVideoRenderer
    private let pumpQueue: DispatchQueue
    /// Returns true while THIS source is still the engine's current reading session.
    /// Backed by the engine's monotonic session token (the same authority the old
    /// inline pump used), so a seek/reload retires this pump the instant the next
    /// session starts — and this source and the engine can never disagree.
    private let isCurrent: @Sendable () -> Bool

    /// Adds a video output for `track` to `reader` using `pixelFormat`, ready to
    /// pump once the owner has called `reader.startReading()`. Returns nil if the
    /// reader cannot accept the output (mirrors the old `canAdd` guard).
    ///
    /// - Parameters:
    ///   - reader: the shared reader (owned/torn down by the engine).
    ///   - track: the video track to read.
    ///   - pixelFormat: requested decode format; defaults to 420v 8-bit.
    ///   - pacingRenderer: provides the readiness backpressure that paces the pump.
    ///   - pumpQueue: the queue the pump runs on.
    ///   - isCurrent: engine-supplied currency check (its session token).
    public init?(reader: AVAssetReader,
                 track: AVAssetTrack,
                 pixelFormat: OSType = FileFrameSource.defaultPixelFormat,
                 pacingRenderer: AVSampleBufferVideoRenderer,
                 pumpQueue: DispatchQueue,
                 isCurrent: @escaping @Sendable () -> Bool) {
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        self.output = out
        self.reader = reader
        self.pacingRenderer = pacingRenderer
        self.pumpQueue = pumpQueue
        self.isCurrent = isCurrent
    }

    /// Begin pumping decoded frames out through `onVideoFrame`. Must be called after
    /// the owner has called `reader.startReading()`. The loop drains while the
    /// pacing renderer wants data and the reader is still delivering — identical to
    /// the old inline pump.
    ///
    /// The block captures only locals (renderer, output, reader, the emit closure,
    /// the currency check) — never `self`. So this source may be deallocated the
    /// instant the engine drops it without leaving a `weak self == nil` path that
    /// would stop the shared renderer.
    public func start() throws {
        let renderer = pacingRenderer
        let out = output
        let rdr = reader
        let emit = onVideoFrame
        let current = isCurrent
        renderer.requestMediaDataWhenReady(on: pumpQueue) {
            // Superseded by a newer session: do NOT stop the renderer — the new
            // session already re-armed it; just bow out.
            guard current() else { return }
            while renderer.isReadyForMoreMediaData {
                guard current() else { return }
                guard rdr.status == .reading, let next = out.copyNextSampleBuffer() else {
                    // Genuine end-of-stream for the CURRENT session: stop requesting
                    // so the renderer doesn't spin on an exhausted reader.
                    renderer.stopRequestingMediaData(); return
                }
                emit?(next)
            }
        }
    }

    /// Stop requesting frames. Called by the engine on the main actor, ordered
    /// before it re-arms the renderer for the next session (and on full teardown).
    /// The pump block itself never calls this on supersession — only the engine and
    /// a real end-of-stream do — so a retiring source can't cancel the live pump.
    public func stop() {
        pacingRenderer.stopRequestingMediaData()
    }
}
