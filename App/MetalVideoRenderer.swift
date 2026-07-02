import Foundation
import Metal
import CoreVideo
import CoreMedia
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

/// Matches the shader's ColorParams struct (memory layout).
private struct ColorParams {
    var a: Float  // Cr -> R
    var b: Float  // Cb -> G
    var c: Float  // Cr -> G
    var d: Float  // Cb -> B
    var isFullRange: Int32        // 0 = video/legal (expand), 1 = full (passthrough)
    var chromaConvention: Int32   // full-range only: 0 = full-swing (÷255), 1 = Resolve (×219/224)
}

/// Matches the shader's WaveformParams struct (memory layout). GPU waveform prototype.
private struct WaveformParams {
    var width: UInt32      // source (offscreen) width
    var height: UInt32     // source (offscreen) height
    var scopeW: UInt32     // histogram column buckets
    var bins: UInt32       // luma bins (histogram rows)
    var rowStride: UInt32  // process every rowStride-th source row
}

/// Matches the shader's ParadeParams struct (memory layout). GPU RGB parade. Same layout
/// as WaveformParams; kept separate for the clearer `colW` field name (per-channel width).
private struct ParadeParams {
    var width: UInt32      // source (offscreen) width
    var height: UInt32     // source (offscreen) height
    var colW: UInt32       // per-channel column buckets
    var bins: UInt32       // value bins (histogram rows)
    var rowStride: UInt32  // process every rowStride-th source row
}

/// Renders decoded NV12 video frames to a CAMetalLayer, presentation-timed:
/// the tap enqueues frames (with PTS); a CVDisplayLink draws the frame matching
/// the current playback clock each display refresh. Engine-agnostic — it knows
/// nothing about FrameEngine, only a clock closure returning the current time.
final class MetalVideoRenderer {

    // M3b: 10-bit render target. rgb10a2Unorm — CAMetalLayer-compatible (the 1:1
    // blit to the drawable stays same-format), 4 bytes/pixel packed 10-10-10-2.
    // Display + export get full 10-bit; the scope readback downconverts to 8-bit so
    // the existing CPU scopes are untouched (true 10-bit scopes = the GPU project).
    // Propagates to the layer + pipeline color attachment via the references below.
    static let renderPixelFormat: MTLPixelFormat = .rgb10a2Unorm

    let metalLayer = CAMetalLayer()

    /// Returns the current playback time in seconds. Set by the owner before start().
    var clock: (() -> Double)?

    /// Returns true when transport is PAUSED (synchronizer rate 0). Read per-refresh on
    /// the render thread (thread-safe accessor). Gates the post-seek one-shot render (see
    /// displayTick) to the paused state ONLY — normal playback keeps the strict pts<=now
    /// selection untouched. When nil, defaults to paused (safe: the relaxation is a
    /// one-shot and only fires right after a flush anyway).
    var isPausedProvider: (() -> Bool)?

    /// Returns the engine's effective full-range flag (override + source range).
    /// Read per-frame on the render thread; the engine's accessor is thread-safe.
    /// When nil, defaults to video/legal (expand).
    var isFullRangeProvider: (() -> Bool)?

    /// Returns the engine's full-range chroma convention rawValue (0 = full-swing,
    /// 1 = Resolve). Read per-frame on the render thread (thread-safe accessor).
    /// Only affects the full-range path. When nil, defaults to 1 (Resolve).
    var chromaConventionProvider: (() -> Int32)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache!

    // GPU scopes. Compute pipelines for the scope kernels + REUSABLE device histogram
    // buffers (shared storage so the CPU can read them back). Buffers grow on demand and
    // are never per-frame-allocated; each scope consumer gates to one in-flight compute at
    // a time, so reuse can't tear. (Waveform: Phase 1. Parade: Phase 2 — same pattern, one
    // buffer with 3 R/G/B regions.)
    private let waveformPipelineState: MTLComputePipelineState?
    private var histogramBuffer: MTLBuffer?
    private let paradePipelineState: MTLComputePipelineState?
    private var paradeHistogramBuffer: MTLBuffer?

    // Persistent owned offscreen render target: the single source of truth for
    // display (1:1 blitted to the drawable), frame export, and future scopes.
    // Written/used on the CVDisplayLink render thread; read back (via its own
    // serialized command buffer) by readbackRenderedFrame() from the main thread.
    private var offscreenTexture: MTLTexture?
    private var offscreenSize: (w: Int, h: Int)?

    // Frame queue: PTS (seconds) + pixel buffer, ordered by PTS. Guarded by lock.
    private struct QueuedFrame { let pts: Double; let pixelBuffer: CVPixelBuffer }
    private var frameQueue: [QueuedFrame] = []
    private let queueLock = NSLock()
    private let maxQueued = 12   // bounded buffer

    private var displayLink: CVDisplayLink?

    // Last rendered frame + a refresh request, so a range-override change while
    // PAUSED (no new frame arriving) still re-renders with the new shader flag.
    // lastPixelBuffer is touched only on the render thread; pendingRefresh is
    // guarded because setNeedsRefresh() is called from the main thread.
    private var lastPixelBuffer: CVPixelBuffer?
    private let refreshLock = NSLock()
    private var pendingRefresh = false

    // Set by flush() (i.e. a seek). Arms a ONE-SHOT relaxed render in displayTick: while
    // PAUSED, if no queued frame satisfies the strict pts<=now gate (a decoder that seeks
    // to the frame just AFTER the target — libav overshoot), render the nearest queued
    // frame anyway so the paused offscreen (scope data source) + display reflect the
    // seeked-to frame instead of the previous one. Guarded (set on main via flush(), read
    // on the render thread). Decoder-agnostic; does NOT touch the playing-state path.
    private var pendingSeekRender = false

    /// Request a one-shot re-render of the current frame (e.g. after a range
    /// override change while paused). Picked up on the next display refresh.
    func setNeedsRefresh() {
        refreshLock.lock(); pendingRefresh = true; refreshLock.unlock()
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("MetalVideoRenderer: no Metal device"); return nil
        }
        guard let queue = device.makeCommandQueue() else {
            print("MetalVideoRenderer: no command queue"); return nil
        }
        guard let library = device.makeDefaultLibrary() else {
            print("MetalVideoRenderer: no default library (shader not compiled in?)"); return nil
        }
        guard let vfn = library.makeFunction(name: "passthroughVertex"),
              let ffn = library.makeFunction(name: "passthroughFragment") else {
            print("MetalVideoRenderer: shader functions not found"); return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = Self.renderPixelFormat

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            print("MetalVideoRenderer: pipeline creation failed"); return nil
        }

        // GPU scope compute pipelines (same default library). Non-fatal if either fails —
        // that scope simply falls back to its CPU path; the display path is unaffected.
        if let wfn = library.makeFunction(name: "waveformKernel") {
            self.waveformPipelineState = try? device.makeComputePipelineState(function: wfn)
        } else {
            self.waveformPipelineState = nil
        }
        if let pfn = library.makeFunction(name: "paradeKernel") {
            self.paradePipelineState = try? device.makeComputePipelineState(function: pfn)
        } else {
            self.paradePipelineState = nil
        }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pipeline

        metalLayer.device = device
        metalLayer.pixelFormat = Self.renderPixelFormat
        // framebufferOnly = false so the drawable texture can be used as a blit
        // source for on-demand frame export (exportCurrentFrame). Minor cost; no
        // effect on the normal display path.
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        // Colorspace is set per-frame in renderPixelBuffer, derived from the
        // pixel buffer's own color attachments (matching the reference layer).

        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard cacheStatus == kCVReturnSuccess else {
            print("MetalVideoRenderer: texture cache creation failed (\(cacheStatus))"); return nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - Source colorspace (set once per source)

    /// Derive the layer's colorspace from the source's authoritative color tags
    /// (CICP codes from MediaInspector) and assign it ONCE. Re-call on each new
    /// source. This replaces the per-frame buffer-attachment derivation, which
    /// could flip to an unspecified-primaries space on some frames.
    func setSourceColorSpace(primaries: Int?, transfer: Int?, matrix: Int?) {
        // Never assign nil — makeColorSpace guarantees non-nil, but guard anyway.
        guard let cs = Self.makeColorSpace(primaries: primaries, transfer: transfer, matrix: matrix) else { return }
        // Assign inside a synchronized transaction (actions disabled) so this
        // once-per-source mutation can't tear against an in-flight frame on the
        // CVDisplayLink render thread.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.colorspace = cs
        CATransaction.commit()
    }

    /// Build a CoreVideo nclc attachments dict from MediaInspector's authoritative
    /// codes and run it through CVImageBufferCreateColorSpaceFromAttachments — the
    /// SAME function the reference AVSampleBufferDisplayLayer path uses. This yields
    /// the CoreMedia-family space (correct 709 toe, matches reference) but fed from
    /// stable source tags, not the flaky per-frame buffer. Absent/nil/unknown tags
    /// fall back to the full 709 attachment set; never returns nil.
    private static func makeColorSpace(primaries: Int?, transfer: Int?, matrix: Int?) -> CGColorSpace? {
        let p709 = kCVImageBufferColorPrimaries_ITU_R_709_2
        let t709 = kCVImageBufferTransferFunction_ITU_R_709_2
        let m709 = kCVImageBufferYCbCrMatrix_ITU_R_709_2

        let prim: CFString
        let trans: CFString
        let mat: CFString

        switch (primaries, transfer) {
        case (12, _):   // Display P3 (P3 D65) primaries; transfer/matrix from source else 709
            prim = kCVImageBufferColorPrimaries_P3_D65
            trans = transferAttachment(transfer) ?? t709
            mat = matrixAttachment(matrix) ?? m709
        case (9, 16):   // Rec.2020 + PQ
            prim = kCVImageBufferColorPrimaries_ITU_R_2020
            trans = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            mat = kCVImageBufferYCbCrMatrix_ITU_R_2020
        case (9, 18):   // Rec.2020 + HLG
            prim = kCVImageBufferColorPrimaries_ITU_R_2020
            trans = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            mat = kCVImageBufferYCbCrMatrix_ITU_R_2020
        case (1, 1):    // Rec.709 full set
            prim = p709; trans = t709; mat = m709
        default:        // absent / nil / unknown / unspecified -> 709
            prim = p709; trans = t709; mat = m709
        }

        let dict: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: prim,
            kCVImageBufferTransferFunctionKey: trans,
            kCVImageBufferYCbCrMatrixKey: mat
        ]
        if let cs = CVImageBufferCreateColorSpaceFromAttachments(dict as CFDictionary)?.takeRetainedValue() {
            return cs
        }
        // Last resort so the layer is never untagged.
        return CGColorSpace(name: CGColorSpace.itur_709)
    }

    /// MediaInspector transfer code -> CV transfer attachment, or nil if unknown.
    private static func transferAttachment(_ code: Int?) -> CFString? {
        switch code {
        case 1:  return kCVImageBufferTransferFunction_ITU_R_709_2
        case 16: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case 18: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: return nil
        }
    }

    /// MediaInspector matrix code -> CV matrix attachment, or nil if unknown.
    private static func matrixAttachment(_ code: Int?) -> CFString? {
        switch code {
        case 1: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case 9: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        default: return nil
        }
    }

    // MARK: - Frame intake (called from the engine's tap, background queue)

    /// Enqueue a decoded frame for presentation-timed display.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard pts.isFinite else { return }

        queueLock.lock()
        frameQueue.append(QueuedFrame(pts: pts, pixelBuffer: pixelBuffer))
        frameQueue.sort { $0.pts < $1.pts }
        // Bound the queue: drop the oldest if over capacity.
        if frameQueue.count > maxQueued {
            frameQueue.removeFirst(frameQueue.count - maxQueued)
        }
        queueLock.unlock()
    }

    /// Clear all queued frames (call on seek).
    func flush() {
        queueLock.lock()
        frameQueue.removeAll()
        queueLock.unlock()
        // A seek just cleared the queue. Arm the one-shot: if we're paused and the next
        // delivered frame overshoots the pinned clock (pts > now), displayTick renders it
        // anyway so the paused offscreen isn't left on the previous frame.
        refreshLock.lock(); pendingSeekRender = true; refreshLock.unlock()
    }

    // MARK: - Display link lifecycle

    func start() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { print("MetalVideoRenderer: CVDisplayLink create failed"); return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            let renderer = Unmanaged<MetalVideoRenderer>.fromOpaque(userInfo!).takeUnretainedValue()
            renderer.displayTick()
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
    }

    func stop() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        flush()
    }

    // MARK: - Per-refresh presentation

    /// Called each display refresh (on the CVDisplayLink thread). Picks the
    /// newest frame whose PTS <= current playback time and renders it.
    private func displayTick() {
        guard let now = clock?() else { return }

        queueLock.lock()
        // Find the newest frame with pts <= now.
        var chosen: CVPixelBuffer?
        var chosenPts: Double = -1
        var dropCount = 0
        for (i, frame) in frameQueue.enumerated() {
            if frame.pts <= now {
                chosen = frame.pixelBuffer
                chosenPts = frame.pts
                dropCount = i
            } else {
                break
            }
        }
        // Remove everything up to and including the chosen frame (consumed + stale).
        if chosen != nil, dropCount < frameQueue.count {
            frameQueue.removeFirst(dropCount + 1)
        }
        queueLock.unlock()

        if let pb = chosen {
            renderPixelBuffer(pb)
            tickPresentedFPS(chosenPts)
            // A frame satisfied the strict gate — the post-seek one-shot is moot. Clear it
            // so a seek that resolves normally (incl. seek-and-play) never touches the
            // relaxed branch below.
            refreshLock.lock(); pendingSeekRender = false; refreshLock.unlock()
        } else {
            // No frame satisfies pts<=now (e.g. paused). Two one-shot fallbacks:
            refreshLock.lock()
            let refresh = pendingRefresh; pendingRefresh = false
            let seekRender = pendingSeekRender
            refreshLock.unlock()

            if refresh, let pb = lastPixelBuffer {
                // Range/override change while paused: re-render the last frame so the
                // shader-flag change shows.
                renderPixelBuffer(pb)
            } else if seekRender, isPausedProvider?() ?? true {
                // Post-seek + PAUSED: the decoder overshot the seek target (the only
                // queued frame's pts is just past the pinned clock), so the strict gate
                // rejected it. Render the EARLIEST queued frame ONCE so the paused
                // offscreen shows the seeked-to frame instead of the previous one. Fires
                // at most once per seek (cleared on render); the paused-only guard keeps
                // normal playback pacing on the strict gate above. Decoder-agnostic.
                queueLock.lock()
                let nearest = frameQueue.first
                if nearest != nil { frameQueue.removeFirst() }
                queueLock.unlock()
                if let nearest {
                    // TEMP (STEP 1 confirm — REMOVE after validating): prove the overshoot
                    // is why the strict gate rejected the frame (pts > now on a paused seek).
                    #if DEBUG
                    FileHandle.standardError.write(Data(String(
                        format: "[ScopeSeek] paused-seek overshoot: nearest.pts=%.4f now=%.4f Δ=%+.4f → relaxed render\n",
                        nearest.pts, now, nearest.pts - now).utf8))
                    #endif
                    refreshLock.lock(); pendingSeekRender = false; refreshLock.unlock()
                    renderPixelBuffer(nearest.pixelBuffer)
                    tickPresentedFPS(nearest.pts)
                }
            }
        }
    }

    // Presented-fps tracking: the REAL on-screen playback rate — counts DISTINCT
    // source frames actually selected by displayTick (a frame re-shown across several
    // 60/120Hz refreshes counts once), recomputed once per wall-second. Useful for a
    // pro player to catch dropped frames during review. Touched only on the
    // CVDisplayLink thread. The latest value is exposed via `presentedFPS`; the
    // per-second log is DEBUG-only (no release spam).
    // FUTURE: surface `presentedFPS` on-screen next to the nominal frame rate, with a
    // dropped-frame count (nominal − presented). Not built yet.
    private(set) var presentedFPS: Double = 0
    private var presentedFrameCount = 0
    private var presentedWindowStartNs: UInt64 = 0
    private var lastPresentedPts: Double = -1

    private func tickPresentedFPS(_ pts: Double) {
        if pts != lastPresentedPts {
            lastPresentedPts = pts
            presentedFrameCount += 1
        }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if presentedWindowStartNs == 0 { presentedWindowStartNs = nowNs; return }
        let elapsed = nowNs - presentedWindowStartNs
        if elapsed >= 1_000_000_000 {
            presentedFPS = Double(presentedFrameCount) * 1e9 / Double(elapsed)
            #if DEBUG
            if presentedFrameCount > 0 {
                FileHandle.standardError.write(Data(String(format: "[Play] presented %.1f fps\n", presentedFPS).utf8))
            }
            #endif
            presentedWindowStartNs = nowNs
            presentedFrameCount = 0
        }
    }

    // MARK: - Drawing

    private func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        lastPixelBuffer = pixelBuffer   // retained for paused refresh (render thread only)
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Layer colorspace is set ONCE per source in setSourceColorSpace(...) from
        // MediaInspector's authoritative tags — NOT per-frame from the buffer.

        // M3b: pick texture sample formats from the buffer's bit depth. 10-bit x420
        // planes are 16-bit (10 bits high-aligned), sampled as r16/rg16; 8-bit 420v
        // as r8/rg8. The shader reads NORMALIZED values either way, so its YCbCr math
        // is unchanged (r16Unorm of a high-aligned 10-bit sample ≈ code/1024, ~the
        // same normalized level as r8Unorm's code/255, within ~0.3% — sub-code).
        let is10Bit = Self.isTenBit(CVPixelBufferGetPixelFormatType(pixelBuffer))
        let lumaFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let chromaFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm
        guard let lumaTexture = makeTexture(pixelBuffer, planeIndex: 0,
                                            pixelFormat: lumaFormat,
                                            width: width, height: height),
              let chromaTexture = makeTexture(pixelBuffer, planeIndex: 1,
                                              pixelFormat: chromaFormat,
                                              width: width / 2, height: height / 2)
        else { return }

        if metalLayer.drawableSize != CGSize(width: width, height: height) {
            metalLayer.drawableSize = CGSize(width: width, height: height)
        }

        // Render into the persistent owned offscreen texture (1:1 with the drawable),
        // then blit it to the drawable for display. The offscreen texture is the
        // single source of truth for display, export, and scopes.
        ensureOffscreenTexture(width: width, height: height)
        guard let offscreen = offscreenTexture else { return }
        guard let drawable = metalLayer.nextDrawable() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = offscreen
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store

        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        var params = colorParams(for: pixelBuffer)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // 1:1 blit offscreen -> drawable (same size and format). Color-neutral.
        if let blit = cmdBuffer.makeBlitCommandEncoder() {
            blit.copy(from: offscreen, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    /// (Re)create the persistent offscreen render target when missing or when the
    /// size changes. Kept 1:1 with the current drawable size — resolution-neutral.
    private func ensureOffscreenTexture(width: Int, height: Int) {
        if offscreenTexture != nil, let size = offscreenSize, size.w == width, size.h == height {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.renderPixelFormat, width: width, height: height, mipmapped: false)
        desc.storageMode = .private
        desc.usage = [.renderTarget, .shaderRead]   // render into it; allow blit source
        offscreenTexture = device.makeTexture(descriptor: desc)
        offscreenSize = (width, height)
    }

    /// Blit the persistent offscreen texture into a CPU-readable shared texture and
    /// read it back. Shared by frame export and (future) in-app scopes. Uses its own
    /// command buffer + waitUntilCompleted on the SAME queue as rendering, so it
    /// can't tear against an in-flight render (command buffers are atomic units).
    // M3b: the render target is now rgb10a2Unorm — still 4 bytes/pixel, so the
    // bytesPerRow math is unchanged, but the bytes are PACKED 10-10-10-2, not bgra8.
    // This raw form is consumed by the 10-bit export (exportCurrentFrame unpacks it);
    // the scope path uses readbackRenderedFrameAsync, which downconverts to bgra8.
    // Internal (not private) so native scopes can sample the pre-display offscreen
    // texture. Stays per-call / full-res — the THROTTLE lives in the scope consumer.
    func readbackRenderedFrame() -> (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int)? {
        guard let src = offscreenTexture else { return nil }
        let width = src.width
        let height = src.height

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.renderPixelFormat, width: width, height: height, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = [.shaderRead]
        guard let cpuTex = device.makeTexture(descriptor: desc),
              let cmd = commandQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: cpuTex, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            cpuTex.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return (bytes, width, height, bytesPerRow)
    }

    /// NON-BLOCKING readback for the continuous scope path. Blits the offscreen
    /// texture into the scope's own shared texture, then reads it back in the
    /// command buffer's completion handler (no waitUntilCompleted) — so the caller
    /// never stalls the GPU pipeline. `completion` is invoked off the render thread
    /// (on Metal's completion-handler thread) once the GPU has finished.
    ///
    /// Returns true if a readback was issued (completion WILL fire); false if it
    /// couldn't be set up (completion will NOT fire — caller should clear its gate).
    ///
    /// The caller MUST gate this so only one async readback is in flight at a time
    /// for a given `cache` texture: a new blit must not start before the previous
    /// completion handler has read it. The destination texture is CALLER-OWNED
    /// (passed via `cache`), so multiple scopes can sample concurrently — each owns
    /// its own destination and its own gate, and no two scopes blit into one texture.
    @discardableResult
    func readbackRenderedFrameAsync(
        into cache: inout MTLTexture?,
        completion: @escaping (_ bytes: [UInt8], _ width: Int, _ height: Int, _ bytesPerRow: Int) -> Void
    ) -> Bool {
        guard let src = offscreenTexture else { return false }
        let width = src.width
        let height = src.height

        // Reuse the caller's texture; (re)create it on first use or size change.
        if cache == nil || cache?.width != width || cache?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.renderPixelFormat, width: width, height: height, mipmapped: false)
            desc.storageMode = .shared
            desc.usage = [.shaderRead]
            cache = device.makeTexture(descriptor: desc)
        }
        guard let cpuTex = cache,
              let cmd = commandQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else {
            return false
        }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: cpuTex, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        let bytesPerRow = width * 4
        cmd.addCompletedHandler { _ in
            // GPU finished — safe to read the shared texture. Runs on a Metal
            // completion thread (not the render thread, not main, non-blocking).
            // Hands back the RAW rgb10a2 bytes (4 B/px) with a single allocation —
            // the scopes unpack each pixel inline (rgb10a2Channels) in their own
            // already-subsampled loop. The earlier full-frame rgb10a2→bgra8 pass
            // (a second 33MB buffer + an un-subsampled 8.3M-px loop, per readback)
            // was an M3b regression that jerked playback whenever a scope was shown.
            var packed = [UInt8](repeating: 0, count: bytesPerRow * height)
            packed.withUnsafeMutableBytes { raw in
                cpuTex.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            completion(packed, width, height, bytesPerRow)
        }
        cmd.commit()
        return true
    }

    /// GPU luma-waveform histogram (Phase 1 prototype). Runs `waveformKernel` over the
    /// persistent GPU-resident offscreen texture — NO 33MB frame readback — and reads
    /// back only the small histogram (scopeW*bins*4 bytes, ≤1MB). This is the whole win:
    /// the 8.3M-pixel bin loop moves to the GPU, off the CPU/display path.
    ///
    /// Encodes on the scope's OWN command buffer (not the render command buffer), so
    /// scope work never blocks the display. `completion` fires off the render thread on
    /// Metal's completion thread with the histogram as a flat [UInt32] in the SAME layout
    /// the CPU path uses: hist[row*scopeW + bucket].
    ///
    /// The caller MUST gate to one in-flight compute at a time (the reusable histogram
    /// buffer is cleared + accumulated + read per call). Returns true if a compute was
    /// issued (completion WILL fire); false otherwise (caller should clear its gate).
    @discardableResult
    func computeWaveformGPU(
        scopeW: Int, bins: Int, rowStride: Int,
        completion: @escaping (_ hist: [UInt32], _ scopeW: Int, _ bins: Int) -> Void
    ) -> Bool {
        guard let pipeline = waveformPipelineState, let src = offscreenTexture else { return false }
        let width = src.width
        let height = src.height
        let count = scopeW * bins
        guard count > 0 else { return false }

        // Grow the reusable histogram buffer on demand (shared so the CPU can read it).
        let neededBytes = count * MemoryLayout<UInt32>.stride
        if histogramBuffer == nil || histogramBuffer!.length < neededBytes {
            histogramBuffer = device.makeBuffer(length: neededBytes, options: .storageModeShared)
        }
        guard let hist = histogramBuffer,
              let cmd = commandQueue.makeCommandBuffer() else { return false }

        // Clear this frame's histogram to zero (blit fill), then accumulate.
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.fill(buffer: hist, range: 0..<neededBytes, value: 0)
            blit.endEncoding()
        }

        guard let enc = cmd.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(src, index: 0)
        enc.setBuffer(hist, offset: 0, index: 0)
        var params = WaveformParams(width: UInt32(width), height: UInt32(height),
                                    scopeW: UInt32(scopeW), bins: UInt32(bins),
                                    rowStride: UInt32(max(1, rowStride)))
        enc.setBytes(&params, length: MemoryLayout<WaveformParams>.stride, index: 1)
        let tpg = MTLSize(width: 16, height: 16, depth: 1)
        let tgs = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(tgs, threadsPerThreadgroup: tpg)
        enc.endEncoding()

        cmd.addCompletedHandler { _ in
            // GPU done — read the small histogram out of the shared buffer (one copy).
            let ptr = hist.contents().bindMemory(to: UInt32.self, capacity: count)
            let arr = Array(UnsafeBufferPointer(start: ptr, count: count))
            completion(arr, scopeW, bins)
        }
        cmd.commit()
        return true
    }

    /// GPU RGB-parade histograms (Phase 2). Runs `paradeKernel` over the offscreen and
    /// reads back only the small histogram — three per-channel regions in ONE buffer,
    /// laid out [R | G | B], each colW*bins (total 3*colW*bins*4 bytes ≈ 3–12MB, still
    /// trivial vs the old 33MB frame readback). Mirrors computeWaveformGPU exactly; the
    /// caller slices the flat result into R/G/B. Encodes on the scope's OWN command
    /// buffer. Caller MUST gate to one in-flight compute at a time (the buffer is cleared
    /// + accumulated + read per call). Returns true if a compute was issued.
    @discardableResult
    func computeParadeGPU(
        colW: Int, bins: Int, rowStride: Int,
        completion: @escaping (_ hist: [UInt32], _ colW: Int, _ bins: Int) -> Void
    ) -> Bool {
        guard let pipeline = paradePipelineState, let src = offscreenTexture else { return false }
        let width = src.width
        let height = src.height
        let count = colW * bins * 3          // R | G | B regions
        guard count > 0 else { return false }

        let neededBytes = count * MemoryLayout<UInt32>.stride
        if paradeHistogramBuffer == nil || paradeHistogramBuffer!.length < neededBytes {
            paradeHistogramBuffer = device.makeBuffer(length: neededBytes, options: .storageModeShared)
        }
        guard let hist = paradeHistogramBuffer,
              let cmd = commandQueue.makeCommandBuffer() else { return false }

        if let blit = cmd.makeBlitCommandEncoder() {
            blit.fill(buffer: hist, range: 0..<neededBytes, value: 0)
            blit.endEncoding()
        }

        guard let enc = cmd.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(src, index: 0)
        enc.setBuffer(hist, offset: 0, index: 0)
        var params = ParadeParams(width: UInt32(width), height: UInt32(height),
                                  colW: UInt32(colW), bins: UInt32(bins),
                                  rowStride: UInt32(max(1, rowStride)))
        enc.setBytes(&params, length: MemoryLayout<ParadeParams>.stride, index: 1)
        let tpg = MTLSize(width: 16, height: 16, depth: 1)
        let tgs = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(tgs, threadsPerThreadgroup: tpg)
        enc.endEncoding()

        cmd.addCompletedHandler { _ in
            let ptr = hist.contents().bindMemory(to: UInt32.self, capacity: count)
            let arr = Array(UnsafeBufferPointer(start: ptr, count: count))
            completion(arr, colW, bins)
        }
        cmd.commit()
        return true
    }

    /// Unpack one rgb10a2Unorm pixel (the format `readbackRenderedFrameAsync`
    /// returns) to 8-bit R,G,B — the top 8 bits of each 10-bit channel, matching
    /// the 8-bit values the scopes consumed pre-M3b. `p` is the byte offset of the
    /// pixel (little-endian 32-bit: R[0:10] G[10:20] B[20:30] A[30:32]).
    @inline(__always)
    static func rgb10a2Channels(_ buf: UnsafeBufferPointer<UInt8>, _ p: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let px = UInt32(buf[p]) | (UInt32(buf[p + 1]) << 8)
            | (UInt32(buf[p + 2]) << 16) | (UInt32(buf[p + 3]) << 24)
        return (UInt8((px & 0x3FF) >> 2),
                UInt8(((px >> 10) & 0x3FF) >> 2),
                UInt8(((px >> 20) & 0x3FF) >> 2))
    }

    /// Unpack an rgb10a2Unorm buffer to 16-bit RGBA (alpha skipped/opaque). Each
    /// 10-bit channel is left-shifted into the 16-bit range (×64) so a 16-bit PNG
    /// preserves the full 10-bit precision. Channel order R,G,B,A (byteOrder16Little).
    private static func rgb10a2ToRGBA16(_ src: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: width * 4 * height)
        src.withUnsafeBytes { inRaw in
            out.withUnsafeMutableBufferPointer { outBuf in
                for y in 0..<height {
                    let inRow = y * bytesPerRow
                    let outRow = y * width * 4
                    for x in 0..<width {
                        let p = inRow + x * 4
                        let px = UInt32(inRaw[p]) | (UInt32(inRaw[p + 1]) << 8)
                            | (UInt32(inRaw[p + 2]) << 16) | (UInt32(inRaw[p + 3]) << 24)
                        let o = outRow + x * 4
                        outBuf[o + 0] = UInt16((px & 0x3FF) << 6)
                        outBuf[o + 1] = UInt16(((px >> 10) & 0x3FF) << 6)
                        outBuf[o + 2] = UInt16(((px >> 20) & 0x3FF) << 6)
                        outBuf[o + 3] = 0xFFFF
                    }
                }
            }
        }
        return out
    }

    // MARK: - Frame export (on-demand, manual)

    /// Read back the most-recently-rendered frame and write it to a PNG on the
    /// Desktop, tagged with the layer's source-derived colorspace so a
    /// non-color-managed app (e.g. Resolve) reads the raw code values. Manual only.
    func exportCurrentFrame() {
        guard let frame = readbackRenderedFrame() else {
            print("[EXPORT] no rendered frame yet"); return
        }
        let (bytes, width, height, bytesPerRow) = frame

        // CRITICAL: tag with the layer's source-derived colorspace (CoreMedia709),
        // NOT deviceRGB/sRGB — so the consumer reads the raw code values under the
        // file's real colorspace. Fall back to 709 only if the layer has none.
        let cs = metalLayer.colorspace ?? CGColorSpace(name: CGColorSpace.itur_709)!
        // M3b: the readback is now rgb10a2 (packed 10-10-10-2). Unpack to 16-bit RGBA
        // (10-bit value placed in the high bits) so the export carries the full 10-bit
        // precision — a 16-bit PNG rather than the old 8-bit one.
        let rgba16 = Self.rgb10a2ToRGBA16(bytes, width: width, height: height, bytesPerRow: bytesPerRow)
        let outBytesPerRow = width * 8   // 4 channels × 16-bit
        let data = rgba16.withUnsafeBytes { Data($0) }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 16, bitsPerPixel: 64,
                                    bytesPerRow: outBytesPerRow, space: cs,
                                    bitmapInfo: bitmapInfo, provider: provider,
                                    decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            print("[EXPORT] CGImage creation failed"); return
        }

        let ts = Int(Date().timeIntervalSince1970)
        let filename = "Manifold_frame_\(ts).png"

        // Write into the user-chosen folder (security-scoped, resolved from a bookmark),
        // or ~/Desktop by default / on stale bookmark. Image encoding/colorspace above
        // is unchanged — only the destination differs.
        Preferences.shared.withExportDirectory { dir in
            let url = dir.appendingPathComponent(filename)
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                print("[EXPORT] destination create failed"); return
            }
            CGImageDestinationAddImage(dest, cgImage, nil)
            if CGImageDestinationFinalize(dest) {
                let csName = cs.name.map { "\($0)" } ?? "\(cs)"
                print("[EXPORT] wrote \(url.path)")
                print("[EXPORT] texture format=\(Self.renderPixelFormat) colorspace=\(csName)")
            } else {
                print("[EXPORT] PNG finalize failed")
            }
        }
    }

    /// Read the YCbCr matrix from the pixel buffer's attachment and return the
    /// RGB conversion coefficients. Defaults to Rec.709 if absent/unknown.
    private func colorParams(for pixelBuffer: CVPixelBuffer) -> ColorParams {
        let matrix = (CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String) ?? ""
        let m601 = kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
        let m2020 = kCVImageBufferYCbCrMatrix_ITU_R_2020 as String

        // Range flag comes from ENGINE STATE (override + source range), NOT the
        // buffer format. The buffer is always 420v raw (unclipped); the engine
        // decides whether the shader expands (legal/video) or passes through
        // (full). Read per-frame so an override change shows on the next frame.
        let isFull: Int32 = (isFullRangeProvider?() ?? false) ? 1 : 0
        // Full-range chroma convention from engine state (0=full-swing, 1=Resolve).
        // Only consulted by the full-range branch; nil defaults to Resolve.
        let chromaConv: Int32 = chromaConventionProvider?() ?? 1

        // Coefficients per matrix. Standard derivations from Kr/Kb.
        switch matrix {
        case m601:
            // Rec.601: Kr=0.299, Kb=0.114
            return ColorParams(a: 1.5960, b: 0.3917, c: 0.8129, d: 2.0172, isFullRange: isFull, chromaConvention: chromaConv)
        case m2020:
            // Rec.2020: Kr=0.2627, Kb=0.0593
            return ColorParams(a: 1.4746, b: 0.1646, c: 0.5714, d: 1.8814, isFullRange: isFull, chromaConvention: chromaConv)
        default:
            // Rec.709 (default): Kr=0.2126, Kb=0.0722
            return ColorParams(a: 1.5748, b: 0.1873, c: 0.4681, d: 1.8556, isFullRange: isFull, chromaConvention: chromaConv)
        }
    }

    /// Read the content's transfer function from the pixel buffer attachment.
    /// Returned as a CICP-ish code: 1=709, 16=PQ, 18=HLG, else 0.
    private func transferCode(for pixelBuffer: CVPixelBuffer) -> Int {
        let tf = (CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String) ?? ""
        let tf709 = kCVImageBufferTransferFunction_ITU_R_709_2 as String
        let tfPQ = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        let tfHLG = kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        switch tf {
        case tf709: return 1
        case tfPQ: return 16
        case tfHLG: return 18
        default: return 0
        }
    }

    /// True for the 10-bit 420 biplanar CV formats (x420 / xf20) whose planes are
    /// 16-bit-per-sample (10 bits high-aligned).
    static func isTenBit(_ pf: OSType) -> Bool {
        pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, planeIndex: Int,
                             pixelFormat: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            pixelFormat, width, height, planeIndex, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return texture
    }
}
