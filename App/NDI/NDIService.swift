import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import QuartzCore

/// STEP A: minimal NDI receive — prove NDI integrates and that frames reach Manifold's Metal
/// display path. Discovery, a receiver on the first source found, a FrameSync pull on the display
/// tick, and the frames handed to the SAME MetalVideoRenderer.enqueue the file sources feed.
///
/// Deliberately NOT here (all later steps): source picking/switching, file<->NDI coexistence,
/// clock/drift correctness, audio, HDR/metadata, P216/10-bit, capability flags.
///
/// THE FORMAT PROBLEM, and why there is a conversion in a "zero-copy" path
/// ----------------------------------------------------------------------
/// The brief assumed the renderer is source-agnostic downstream of enqueue. It is not, in two
/// ways that both bite an 8-bit packed UYVY buffer:
///
///   1. renderPixelBuffer samples TWO PLANES (luma + chroma). NDI's UYVY is single-plane packed
///      4:2:2, so a '2vuy' buffer fails makeTexture(planeIndex: 1) and renders NOTHING — a black
///      window, not a crash, which is the worst way for this to fail.
///   2. The shader's range-expansion constants are hard-wired to the 10-BIT MSB-ALIGNED sample
///      domain (kCodeMax = 1023.984375). PassthroughShader.metal says so explicitly, and says the
///      8-bit branch is unreachable and that reviving it means making those constants per-depth.
///      Feeding it 8-bit samples would expand them against the wrong code ceiling.
///
/// So the frame has to arrive in a format the existing shader already speaks. Rather than write a
/// packed-422 shader path (a bigger change to the hot display path, and it re-opens the 8-bit
/// constants problem the shader warns about), VideoToolbox converts UYVY into 'x422' —
/// 10-bit biplanar 4:2:2. That lands in EXACTLY the domain the shader's constants assume, with no
/// chroma decimation (4:2:2 in, 4:2:2 out; 'x420' would have thrown away half the chroma lines),
/// and needs no shader edit. The 8→10-bit promotion is an exact ×4 code shift, not a resample.
///
/// The zero-copy wrap still earns its keep: it is the SOURCE of that transfer, so NDI's bytes are
/// read straight out of the SDK's buffer with no intermediate memcpy, and the frame is handed back
/// to FrameSync the instant the transfer is done (see NDIVideoFrame's lifetime note).
final class NDIService: ObservableObject {

    static let shared = NDIService()
    private init() {}

    /// True while an NDI source is connected and feeding the display.
    ///
    /// STOPGAP: the UI needs to know "is something on screen" and, until the source-switching work
    /// lands, there is no unified is-any-source-active concept — the empty state just ORs this with
    /// the engine's file state. Main-thread only (start/disconnect both run there), so it is safe
    /// for SwiftUI to observe.
    @Published private(set) var isConnected = false

    /// The display path. Set once at startup (ContentView.onAppear), same instance DeckLink uses.
    weak var renderer: MetalVideoRenderer?

    private var bridge: NDIBridge?
    private var transferSession: VTPixelTransferSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)

    private var isConnecting = false
    private var frameCount = 0
    private var lastRateLogTime: CFTimeInterval = 0
    private var lastRateLogCount = 0

    /// The renderer's normal clock is the file transport's. NDI is not on that clock, so while NDI
    /// is driving we substitute a free-running monotonic one and stamp frames with it at pull time
    /// — the frame is enqueued microseconds before displayTick reads the clock, so the renderer's
    /// `pts <= now` selection always accepts it. That is all the PTS has to do this step: FrameSync
    /// is doing the actual sync, and real timestamp handling is the deferred clock step.
    private static func monotonicNow() -> Double { CACurrentMediaTime() }

    // MARK: - Debug trigger (⌃⌥N)

    /// Discover, connect to the first source, and start pulling frames onto the display.
    /// Throwaway trigger — the real source picker comes with source switching.
    ///
    /// NDI TAKES OVER the display while active: it repoints the renderer's clock and range
    /// providers at itself. Clean file<->NDI handoff is explicitly out of scope for this step.
    func connectToFirstSource() {
        guard !isConnecting else { return }
        guard bridge == nil else {
            NSLog("[NDI] already connected to \"\(bridge?.sourceName ?? "?")\" — ignoring")
            return
        }
        guard renderer != nil else {
            NSLog("[NDI] no renderer wired — cannot display")
            return
        }
        guard NDIBridge.loadRuntime() else {
            // Graceful absence: the runtime isn't there, the app keeps working, the trigger says so.
            NSLog("[NDI] runtime unavailable — trigger is a no-op (see the [NDI] log above for why)")
            return
        }

        isConnecting = true
        NSLog("[NDI] discovering sources (loader=\(NDIBridge.loaderSymbol ?? "?"), "
              + "runtime=\(NDIBridge.runtimeVersion ?? "?"))…")

        // Discovery blocks — keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let connected = NDIBridge.connectToFirstSource(withTimeout: 5.0)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isConnecting = false
                guard let connected else {
                    NSLog("[NDI] no source found — is OmniScope sending on this network?")
                    return
                }
                self.start(with: connected)
            }
        }
    }

    private func start(with connected: NDIBridge) {
        guard let renderer else { return }
        bridge = connected
        frameCount = 0
        lastRateLogTime = Self.monotonicNow()
        lastRateLogCount = 0

        // NDI is Rec.709 video-range. Tag the layer for it, and pin the shader to legal-range
        // expansion rather than letting it read the file transport's override (which describes a
        // file that may not even be loaded).
        renderer.setSourceColorSpace(primaries: 1, transfer: 1, matrix: 1)
        renderer.isFullRangeProvider = { false }
        renderer.clock = { Self.monotonicNow() }
        renderer.isPausedProvider = { false }

        // Pull on the display tick: FrameSync hands us the current frame on OUR clock.
        renderer.onDisplayTick = { [weak self] in self?.pullFrame() }

        isConnected = true
        NSLog("[NDI] receiving from \"\(connected.sourceName)\" — pulling on the display tick")
    }

    func disconnect() {
        isConnected = false
        renderer?.onDisplayTick = nil
        bridge?.disconnect()
        bridge = nil
        transferSession = nil
        pixelBufferPool = nil
        poolSize = (0, 0)
        NSLog("[NDI] disconnected")
    }

    // MARK: - Per-tick pull (CVDisplayLink thread)

    /// Called from MetalVideoRenderer's display tick, BEFORE it selects a frame — so a frame
    /// pulled here is available to the very same tick.
    private func pullFrame() {
        guard let bridge, let renderer else { return }
        // nil = no frame yet, or FrameSync is repeating one we already converted. Enqueuing
        // nothing is correct: the renderer keeps displaying the frame it has.
        guard let frame = bridge.captureVideoFrame() else { return }

        guard let converted = convertToDisplayFormat(frame.pixelBuffer,
                                                     width: Int(frame.width),
                                                     height: Int(frame.height)) else { return }
        // `frame` (and with it NDI's buffer) is released at the end of this scope — the transfer
        // above has already read every byte out of it.

        guard let sampleBuffer = makeSampleBuffer(converted, pts: Self.monotonicNow()) else { return }
        renderer.enqueue(sampleBuffer)
        logFrameRate()
    }

    /// UYVY ('2vuy', 8-bit packed 4:2:2) → 'x422' (10-bit biplanar 4:2:2) — the format the
    /// existing shader path already speaks. See the type comment for why this conversion exists.
    private func convertToDisplayFormat(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        if transferSession == nil {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                      pixelTransferSessionOut: &session)
            guard status == noErr, let session else {
                NSLog("[NDI] VTPixelTransferSessionCreate failed (\(status))")
                return nil
            }
            transferSession = session
        }
        guard let transferSession else { return nil }

        if pixelBufferPool == nil || poolSize != (width, height) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                NSLog("[NDI] CVPixelBufferPoolCreate failed (\(status))")
                return nil
            }
            pixelBufferPool = pool
            poolSize = (width, height)
            NSLog("[NDI] display pool: \(width)x\(height) x422 (10-bit biplanar 4:2:2)")
        }
        guard let pixelBufferPool else { return nil }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &destination)
                == kCVReturnSuccess, let destination else { return nil }

        let status = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination)
        guard status == noErr else {
            NSLog("[NDI] pixel transfer failed (\(status))")
            return nil
        }
        return destination
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: Double) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    /// Once a second: prove frames are LIVE, not one frozen frame. A steady rate here is the
    /// difference between "NDI connected" and "NDI is actually streaming".
    private func logFrameRate() {
        frameCount += 1
        let now = Self.monotonicNow()
        let elapsed = now - lastRateLogTime
        guard elapsed >= 1.0 else { return }
        let rate = Double(frameCount - lastRateLogCount) / elapsed
        NSLog(String(format: "[NDI] %.1f fps received (%d frames total)", rate, frameCount))
        lastRateLogTime = now
        lastRateLogCount = frameCount
    }
}
