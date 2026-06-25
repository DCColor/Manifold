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
}

/// Renders decoded NV12 video frames to a CAMetalLayer, presentation-timed:
/// the tap enqueues frames (with PTS); a CVDisplayLink draws the frame matching
/// the current playback clock each display refresh. Engine-agnostic — it knows
/// nothing about FrameEngine, only a clock closure returning the current time.
final class MetalVideoRenderer {

    // M3b: 10-bit migration touches here — change this format (e.g. .bgra10_xr or
    // rgb10a2 variant) when the engine decodes native 10-bit.
    static let renderPixelFormat: MTLPixelFormat = .bgra8Unorm

    let metalLayer = CAMetalLayer()

    /// Returns the current playback time in seconds. Set by the owner before start().
    var clock: (() -> Double)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache!

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
        var dropCount = 0
        for (i, frame) in frameQueue.enumerated() {
            if frame.pts <= now {
                chosen = frame.pixelBuffer
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
        }
    }

    // MARK: - Drawing

    private func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Layer colorspace is set ONCE per source in setSourceColorSpace(...) from
        // MediaInspector's authoritative tags — NOT per-frame from the buffer.

        guard let lumaTexture = makeTexture(pixelBuffer, planeIndex: 0,
                                            pixelFormat: .r8Unorm,
                                            width: width, height: height),
              let chromaTexture = makeTexture(pixelBuffer, planeIndex: 1,
                                              pixelFormat: .rg8Unorm,
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
    // M3b: 10-bit migration touches here — the bytesPerRow math assumes 4 bytes/pixel
    // bgra8; a 10-bit format changes stride and channel extraction.
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
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
            bytes.withUnsafeMutableBytes { raw in
                cpuTex.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            completion(bytes, width, height, bytesPerRow)
        }
        cmd.commit()
        return true
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
        let data = Data(bytes)

        // CRITICAL: tag with the layer's source-derived colorspace (CoreMedia709),
        // NOT deviceRGB/sRGB — so the consumer reads the raw code values under the
        // file's real colorspace. Fall back to 709 only if the layer has none.
        let cs = metalLayer.colorspace ?? CGColorSpace(name: CGColorSpace.itur_709)!
        // M3b: 10-bit migration touches here — CGImage bitsPerComponent/bitmapInfo
        // assume 8-bit bgra.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: bytesPerRow, space: cs,
                                    bitmapInfo: bitmapInfo, provider: provider,
                                    decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            print("[EXPORT] CGImage creation failed"); return
        }

        let ts = Int(Date().timeIntervalSince1970)
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = dir.appendingPathComponent("Manifold_frame_\(ts).png")

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

    /// Read the YCbCr matrix from the pixel buffer's attachment and return the
    /// RGB conversion coefficients. Defaults to Rec.709 if absent/unknown.
    private func colorParams(for pixelBuffer: CVPixelBuffer) -> ColorParams {
        let matrix = (CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String) ?? ""
        let m601 = kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
        let m2020 = kCVImageBufferYCbCrMatrix_ITU_R_2020 as String

        // Coefficients per matrix. Standard derivations from Kr/Kb.
        switch matrix {
        case m601:
            // Rec.601: Kr=0.299, Kb=0.114
            return ColorParams(a: 1.5960, b: 0.3917, c: 0.8129, d: 2.0172)
        case m2020:
            // Rec.2020: Kr=0.2627, Kb=0.0593
            return ColorParams(a: 1.4746, b: 0.1646, c: 0.5714, d: 1.8814)
        default:
            // Rec.709 (default): Kr=0.2126, Kb=0.0722
            return ColorParams(a: 1.5748, b: 0.1873, c: 0.4681, d: 1.8556)
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
