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

/// Matches the shader's VectorscopeParams struct (memory layout). GPU vectorscope — a
/// square plane×plane 2-D chroma histogram (different geometry from the value histograms).
private struct VectorscopeParams {
    var width: UInt32       // source (offscreen) width
    var height: UInt32      // source (offscreen) height
    var plane: UInt32       // square chroma-plane side
    var rowStride: UInt32   // process every rowStride-th source row
    var chromaScale: Float  // chromaScaleFrac — chroma units → fraction of the plane
}

/// Matches the shader's CIEParams struct (memory layout). GPU CIE chromaticity scope — a
/// planeW×planeH 2-D u'v' histogram. `primariesCode`/`transferCode` are the source's CICP
/// codes (RGB→XYZ matrix + EOTF choice); u/v Min/Max are the u'v' plane bounds.
private struct CIEParams {
    var width: UInt32          // source (offscreen) width
    var height: UInt32         // source (offscreen) height
    var planeW: UInt32         // histogram width  (u' axis)
    var planeH: UInt32         // histogram height (v' axis)
    var primariesCode: Int32   // CICP primaries (1=709, 9=2020, 11/12=P3); default→709
    var transferCode: Int32    // CICP transfer  (1=709, 13=sRGB, 16=PQ, 18=HLG); default→gamma 2.4
    var useUV: UInt32          // 1 = u'v' (Stage A; xy deferred)
    var uMin: Float            // u' plane lower bound
    var uMax: Float            // u' plane upper bound
    var vMin: Float            // v' plane lower bound
    var vMax: Float            // v' plane upper bound
}

/// Matches the shader's RGBToV210Params struct (memory layout). DeckLink RGB→v210 (10-bit YUV
/// 4:2:2) convert — src (offscreen) and dst (DeckLink output) dimensions are decoupled so a
/// native-res mismatch clamps rather than reads out of bounds. `dstRowWords` = v210 rowBytes / 4.
private struct RGBToV210Params {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var dstWidth: UInt32
    var dstHeight: UInt32
    var dstRowWords: UInt32
    var kr: Float          // YCbCr matrix luma coeff for R (from source colorMatrixCode)
    var kb: Float          // YCbCr matrix luma coeff for B
}

/// BT YCbCr matrix (Kr, Kb) selected STRICTLY by the source CICP matrix-coefficient code (D5) —
/// never inferred from primaries. nil / 2 (unspecified) / unknown → 709.
///   matrixCode 1 (709)  → Kr 0.2126, Kb 0.0722
///   matrixCode 9 (2020) → Kr 0.2627, Kb 0.0593
///   matrixCode 6 (601)  → Kr 0.299,  Kb 0.114
private func ycbcrKrKb(forMatrixCode code: Int?) -> (kr: Float, kb: Float) {
    switch code {
    case 9:  return (0.2627, 0.0593)   // Rec.2020
    case 6:  return (0.299,  0.114)    // Rec.601
    default: return (0.2126, 0.0722)   // Rec.709 (also 1 / nil / 2 / unknown)
    }
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

    /// Called on the CVDisplayLink render thread at the END of every renderPixelBuffer —
    /// i.e. every time the offscreen texture is updated to a new displayed frame (normal
    /// playback, paused refresh, AND the post-seek relaxed render). Lets the scopes couple
    /// their sampling to the render instead of a free-running timer, eliminating the
    /// timer/render misalignment latency. The callback must NOT block: it just triggers the
    /// scopes, which commit their own compute command buffers (the render never waits on
    /// scope work). Set by the owner; same set-on-main / read-on-render-thread pattern as
    /// the providers above. Fires only when the offscreen was actually written (after the
    /// render command buffer is committed — a bailed render doesn't signal).
    var onFrameRendered: (() -> Void)?

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
    /// Dedicated command queue for GPU scope compute (dispatchScopeKernel), SEPARATE from
    /// the render's commandQueue. This is the scope-latency fix: on the shared queue, a
    /// scope's compute buffer executed in-order AFTER the render buffer — which includes the
    /// present/vsync wait — so every scope cycle waited ~a frame behind the render and they
    /// piled up (~4:1 coalescing, 4–5 frames late). On its own queue, scope work runs
    /// CONCURRENTLY with renders instead of behind them, and — just as important — a render
    /// never waits behind scope buffers (removes the latent playback-delay risk).
    private let scopeCommandQueue: MTLCommandQueue
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
    private let vectorscopePipelineState: MTLComputePipelineState?
    private var vectorscopeHistogramBuffer: MTLBuffer?
    private let ciePipelineState: MTLComputePipelineState?
    private var cieHistogramBuffer: MTLBuffer?
    /// CIE scope mode: true = CIE 1976 u'v', false = CIE 1931 xy. Flipped live (⌃⌥X) on main;
    /// read on main in computeCIEGPU. The CIE scope's graticule mirrors this (kept in sync by
    /// the toggle) so scatter + overlay agree on the mode.
    var cieUseUV: Bool = true

    // DeckLink output (D-real). A DEDICATED queue (like scopeCommandQueue) converts the readable
    // offscreen (rgb10a2) → 10-bit v210 on each render completion (PUSH model), into a DOUBLE-
    // BUFFERED pair of .shared staging buffers sized to the DeckLink OUTPUT frame (rowBytes*height).
    // The DeckLink callback thread only memcpys the FRONT buffer — no GPU wait there. All fields
    // guarded by deckLinkLock except the pipeline/queue (immutable after init).
    private let deckLinkPipelineState: MTLComputePipelineState?
    private let deckLinkCommandQueue: MTLCommandQueue
    private let deckLinkLock = NSLock()
    private var deckLinkStaging: [MTLBuffer] = []      // 2 buffers; [frontIndex] is complete, [1-front] is written
    private var deckLinkFrontIndex = 0
    private var deckLinkFrameReady = false             // front holds a complete converted frame
    private var deckLinkConverting = false             // one-in-flight gate (push path)
    private var deckLinkActive = false                 // only convert while DeckLink output is running
    private var deckLinkOutputSize: (w: Int, h: Int)?  // DeckLink output frame dims (e.g. 3840x2160)
    private var deckLinkRowBytes = 0                   // v210 row stride (128-byte aligned), matches the frame
    private var deckLinkResMismatchLogged = false      // one-time native-res-mismatch log

    /// v210 row stride: 128-byte aligned, 48 px per 128 bytes. Matches IDeckLinkOutput
    /// RowBytesForPixelFormat(bmdFormat10BitYUV, width) (e.g. 3840 → 10240, no padding).
    private static func v210RowBytes(width: Int) -> Int { ((width + 47) / 48) * 128 }

    // Offscreen render targets — the source of truth for display (1:1 blitted to the
    // drawable), frame export, and scopes. A RING (not a single texture): the render writes
    // into offscreenWriteIndex, then — once that render's GPU work COMPLETES — publishes that
    // index as offscreenReadableIndex. Consumers (export, CPU readback, GPU scopes) only ever
    // sample the readable buffer, i.e. a FULLY-written frame. This is what makes moving scope
    // compute to its own command queue SAFE:
    //   • read-after-write: readable is published in the render's completion handler, so a
    //     reader never sees a half-written frame (no cross-queue event needed).
    //   • write-during-read: the render's NEXT write targets a DIFFERENT ring texture, so a
    //     scope reading the readable buffer on its own queue can't race the render overwriting
    //     it — that buffer isn't reused until offscreenRingCount renders later (~2 frames),
    //     far longer than a scope's ~ms read.
    private static let offscreenRingCount = 2
    private var offscreenRing: [MTLTexture] = []
    private var offscreenSize: (w: Int, h: Int)?
    private var offscreenWriteIndex = 0             // render thread only
    private let offscreenIndexLock = NSLock()
    private var offscreenReadableIndex = -1         // guarded: set in render completion, read by consumers

    /// The most-recently-COMPLETED offscreen frame — the single source of truth for export,
    /// CPU readback, and GPU scopes. Nil until the first render completes. Same name as the
    /// old single texture, so all readers are unchanged; only renderPixelBuffer writes the
    /// ring directly.
    private var offscreenTexture: MTLTexture? {
        offscreenIndexLock.lock(); defer { offscreenIndexLock.unlock() }
        guard offscreenReadableIndex >= 0, offscreenReadableIndex < offscreenRing.count else { return nil }
        return offscreenRing[offscreenReadableIndex]
    }

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
        if let vfn = library.makeFunction(name: "vectorscopeKernel") {
            self.vectorscopePipelineState = try? device.makeComputePipelineState(function: vfn)
        } else {
            self.vectorscopePipelineState = nil
        }
        if let cfn = library.makeFunction(name: "cieKernel") {
            self.ciePipelineState = try? device.makeComputePipelineState(function: cfn)
        } else {
            self.ciePipelineState = nil
        }
        // DeckLink RGB→v210 convert pipeline (same default library). Non-fatal if it fails — DeckLink
        // output just won't have real frames (the fill falls back to neutral black).
        if let dfn = library.makeFunction(name: "rgbToV210") {
            self.deckLinkPipelineState = try? device.makeComputePipelineState(function: dfn)
        } else {
            self.deckLinkPipelineState = nil
        }

        self.device = device
        self.commandQueue = queue
        // Dedicated scope queue (falls back to the render queue if creation fails — degraded
        // to the old shared-queue behavior, but never nil).
        let scopeQueue = device.makeCommandQueue() ?? queue
        scopeQueue.label = "com.graviton.manifold.scope"
        self.scopeCommandQueue = scopeQueue
        // Dedicated DeckLink convert queue (separate from render + scope queues, same rationale).
        let dlQueue = device.makeCommandQueue() ?? queue
        dlQueue.label = "com.graviton.manifold.decklink"
        self.deckLinkCommandQueue = dlQueue
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

    /// The source's raw CICP color tags, retained per source for the GPU CIE scope. The
    /// layer-colorspace path below CONSUMES the codes into a CGColorSpace and keeps nothing,
    /// but the CIE kernel needs the numeric primaries (RGB→XYZ matrix choice) and transfer
    /// (linearization EOTF) directly. Set at the TOP of setSourceColorSpace — before the
    /// colorspace guard — so they survive even if CGColorSpace construction fails. nil → 709.
    private(set) var sourcePrimariesCode: Int?
    private(set) var sourceTransferCode: Int?
    /// Source CICP matrix-coefficient code — selects the DeckLink v210 YCbCr ENCODING matrix (D5),
    /// STRICTLY from this field (never inferred from primaries). nil/2/unknown → 709.
    private(set) var sourceMatrixCode: Int?

    /// Derive the layer's colorspace from the source's authoritative color tags
    /// (CICP codes from MediaInspector) and assign it ONCE. Re-call on each new
    /// source. This replaces the per-frame buffer-attachment derivation, which
    /// could flip to an unspecified-primaries space on some frames.
    func setSourceColorSpace(primaries: Int?, transfer: Int?, matrix: Int?) {
        // Store the raw CICP codes FIRST (before the colorspace guard) so the CIE scope can
        // pick its RGB→XYZ matrix + EOTF even when CGColorSpace construction below fails.
        sourcePrimariesCode = primaries
        sourceTransferCode = transfer
        sourceMatrixCode = matrix
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

        // Render into this frame's ring texture (1:1 with the drawable), then blit it to the
        // drawable for display. We write the WRITE-index buffer (not the readable one); it's
        // published as readable in the completion handler below, once its GPU write is done.
        ensureOffscreenTexture(width: width, height: height)
        let writeIndex = offscreenWriteIndex
        guard writeIndex < offscreenRing.count else { return }
        let offscreen = offscreenRing[writeIndex]
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

        // Publish this buffer as the readable frame + trigger scope sampling ONLY once the
        // render's GPU work has COMPLETED — so scopes (on their own queue) read a fully-written
        // frame, never a half-drawn one (read-after-write safety without a cross-queue event).
        // Runs on a Metal completion thread; onFrameRendered just enqueues (non-blocking).
        cmdBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.offscreenIndexLock.lock()
            self.offscreenReadableIndex = writeIndex
            self.offscreenIndexLock.unlock()
            self.onFrameRendered?()
            // PUSH: convert this freshly-completed frame → v210 for DeckLink (no-op if not active).
            self.pushDeckLinkConvert()
        }
        cmdBuffer.commit()
        // Advance so the NEXT render targets a different ring texture (write-during-read
        // safety: a scope reading this frame's buffer won't be overwritten until the ring
        // wraps ~offscreenRingCount frames later).
        offscreenWriteIndex = (writeIndex + 1) % Self.offscreenRingCount
    }

    /// (Re)create the persistent offscreen render target when missing or when the
    /// size changes. Kept 1:1 with the current drawable size — resolution-neutral.
    private func ensureOffscreenTexture(width: Int, height: Int) {
        if !offscreenRing.isEmpty, let size = offscreenSize, size.w == width, size.h == height {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.renderPixelFormat, width: width, height: height, mipmapped: false)
        desc.storageMode = .private
        desc.usage = [.renderTarget, .shaderRead]   // render into it; allow blit / scope-read source
        var ring: [MTLTexture] = []
        for _ in 0..<Self.offscreenRingCount {
            guard let t = device.makeTexture(descriptor: desc) else { return }
            ring.append(t)
        }
        offscreenIndexLock.lock()
        offscreenRing = ring
        offscreenReadableIndex = -1     // no completed frame in the fresh ring yet
        offscreenIndexLock.unlock()
        offscreenWriteIndex = 0
        offscreenSize = (width, height)
    }

    /// Blit the most-recent completed offscreen frame into a CPU-readable shared texture and
    /// read it back (BLOCKING — own command buffer + waitUntilCompleted on the render queue, so
    /// it can't tear against an in-flight render). Used by the ⌃⌥E frame export only; the scopes
    /// sample the offscreen on the GPU (dispatchScopeKernel) and never read the full frame back.
    // M3b: the render target is rgb10a2Unorm — 4 bytes/pixel, PACKED 10-10-10-2 (not bgra8).
    // exportCurrentFrame unpacks this raw form to a 16-bit PNG (rgb10a2ToRGBA16).
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

    /// Shared GPU-scope dispatch (waveform / parade / vectorscope — the "three-of-a-kind"
    /// extraction). Runs a scope compute kernel over the persistent GPU-resident offscreen
    /// texture — NO 33MB frame readback — into a reusable device histogram buffer, and reads
    /// back only the small histogram (a flat [UInt32] of `count`). This is the whole win: the
    /// 8.3M-pixel bin loop moves to the GPU, off the CPU/display path.
    ///
    /// The clear/dispatch/readback boilerplate is identical across the three scopes; only the
    /// pipeline, reusable buffer, uniforms, and histogram `count` differ — injected here. Each
    /// kernel binds: texture(0) = offscreen, buffer(0) = histogram (atomic_uint), buffer(1) =
    /// its uniforms (set by `setParams`). Encodes on the scope's OWN command buffer (not the
    /// render command buffer), so scope work never blocks the display. `completion` fires off
    /// the render thread on Metal's completion thread with the histogram.
    ///
    /// The caller MUST gate to one in-flight compute at a time per buffer (the reusable buffer
    /// is cleared + accumulated + read per call). Returns true if a compute was issued
    /// (completion WILL fire); false otherwise (caller should clear its gate).
    @discardableResult
    private func dispatchScopeKernel(
        pipeline: MTLComputePipelineState?,
        buffer: inout MTLBuffer?,
        count: Int,
        setParams: (MTLComputeCommandEncoder) -> Void,
        completion: @escaping (_ hist: [UInt32]) -> Void
    ) -> Bool {
        guard let pipeline, let src = offscreenTexture, count > 0 else { return false }
        let width = src.width
        let height = src.height

        // Grow the reusable histogram buffer on demand (shared so the CPU can read it).
        let neededBytes = count * MemoryLayout<UInt32>.stride
        if buffer == nil || buffer!.length < neededBytes {
            buffer = device.makeBuffer(length: neededBytes, options: .storageModeShared)
        }
        // Commit on the DEDICATED scope queue (not the render's) so scope compute runs
        // concurrently with renders instead of serialized behind them + the present/vsync wait.
        // `src` is the readable (completed) frame — safe to read off-queue (see offscreen ring).
        guard let hist = buffer,
              let cmd = scopeCommandQueue.makeCommandBuffer() else { return false }

        // Clear this frame's histogram to zero (blit fill), then accumulate.
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.fill(buffer: hist, range: 0..<neededBytes, value: 0)
            blit.endEncoding()
        }

        guard let enc = cmd.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(src, index: 0)
        enc.setBuffer(hist, offset: 0, index: 0)
        setParams(enc)   // scope-specific uniforms at buffer(1) — called synchronously
        let tpg = MTLSize(width: 16, height: 16, depth: 1)
        let tgs = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(tgs, threadsPerThreadgroup: tpg)
        enc.endEncoding()

        cmd.addCompletedHandler { _ in
            // GPU done — read the small histogram out of the shared buffer (one copy).
            let ptr = hist.contents().bindMemory(to: UInt32.self, capacity: count)
            completion(Array(UnsafeBufferPointer(start: ptr, count: count)))
        }
        cmd.commit()
        return true
    }

    /// GPU luma-waveform histogram (Phase 1). scopeW*bins buffer, layout hist[row*scopeW +
    /// bucket] matching the CPU path. Thin wrapper over dispatchScopeKernel.
    @discardableResult
    func computeWaveformGPU(
        scopeW: Int, bins: Int, rowStride: Int,
        completion: @escaping (_ hist: [UInt32], _ scopeW: Int, _ bins: Int) -> Void
    ) -> Bool {
        guard let src = offscreenTexture else { return false }
        var params = WaveformParams(width: UInt32(src.width), height: UInt32(src.height),
                                    scopeW: UInt32(scopeW), bins: UInt32(bins),
                                    rowStride: UInt32(max(1, rowStride)))
        return dispatchScopeKernel(
            pipeline: waveformPipelineState, buffer: &histogramBuffer, count: scopeW * bins,
            setParams: { $0.setBytes(&params, length: MemoryLayout<WaveformParams>.stride, index: 1) },
            completion: { completion($0, scopeW, bins) })
    }

    /// GPU RGB-parade histograms (Phase 2). Three per-channel regions in ONE buffer, laid
    /// out [R | G | B], each colW*bins (total 3*colW*bins). The caller slices the flat
    /// result into R/G/B. Thin wrapper over dispatchScopeKernel.
    @discardableResult
    func computeParadeGPU(
        colW: Int, bins: Int, rowStride: Int,
        completion: @escaping (_ hist: [UInt32], _ colW: Int, _ bins: Int) -> Void
    ) -> Bool {
        guard let src = offscreenTexture else { return false }
        var params = ParadeParams(width: UInt32(src.width), height: UInt32(src.height),
                                  colW: UInt32(colW), bins: UInt32(bins),
                                  rowStride: UInt32(max(1, rowStride)))
        return dispatchScopeKernel(
            pipeline: paradePipelineState, buffer: &paradeHistogramBuffer, count: colW * bins * 3,
            setParams: { $0.setBytes(&params, length: MemoryLayout<ParadeParams>.stride, index: 1) },
            completion: { completion($0, colW, bins) })
    }

    /// GPU vectorscope histogram (Phase 3). A square plane×plane 2-D chroma histogram,
    /// layout hist[py*plane + px] matching the CPU path (Cb horizontal, Cr up). Thin wrapper
    /// over dispatchScopeKernel. `chromaScale` = VectorscopeScopeModel.chromaScaleFrac.
    @discardableResult
    func computeVectorscopeGPU(
        plane: Int, chromaScale: Float, rowStride: Int,
        completion: @escaping (_ hist: [UInt32], _ plane: Int) -> Void
    ) -> Bool {
        guard let src = offscreenTexture else { return false }
        var params = VectorscopeParams(width: UInt32(src.width), height: UInt32(src.height),
                                       plane: UInt32(plane), rowStride: UInt32(max(1, rowStride)),
                                       chromaScale: chromaScale)
        return dispatchScopeKernel(
            pipeline: vectorscopePipelineState, buffer: &vectorscopeHistogramBuffer, count: plane * plane,
            setParams: { $0.setBytes(&params, length: MemoryLayout<VectorscopeParams>.stride, index: 1) },
            completion: { completion($0, plane) })
    }

    /// GPU CIE chromaticity histogram (Phase 4). A planeW×planeH 2-D u'v' histogram, layout
    /// hist[row*planeW + col] (v' up — the row flip is in-kernel). The RGB→XYZ matrix + EOTF
    /// are selected from the STORED source CICP codes (sourcePrimariesCode/sourceTransferCode,
    /// nil → 709). Thin wrapper over dispatchScopeKernel; non-fatal if the pipeline is nil (the
    /// CIE scope simply doesn't draw — display unaffected).
    @discardableResult
    func computeCIEGPU(
        planeW: Int, planeH: Int,
        completion: @escaping (_ hist: [UInt32], _ planeW: Int, _ planeH: Int) -> Void
    ) -> Bool {
        guard let src = offscreenTexture else { return false }
        // Mode + plane bounds from the single shared source of truth (also used by the graticule).
        let bounds = CIEPlaneBounds.forMode(useUV: cieUseUV)
        var params = CIEParams(width: UInt32(src.width), height: UInt32(src.height),
                               planeW: UInt32(planeW), planeH: UInt32(planeH),
                               primariesCode: Int32(sourcePrimariesCode ?? 1),
                               transferCode: Int32(sourceTransferCode ?? 1),
                               useUV: cieUseUV ? 1 : 0,
                               uMin: bounds.aMin, uMax: bounds.aMax, vMin: bounds.bMin, vMax: bounds.bMax)
        return dispatchScopeKernel(
            pipeline: ciePipelineState, buffer: &cieHistogramBuffer, count: planeW * planeH,
            setParams: { $0.setBytes(&params, length: MemoryLayout<CIEParams>.stride, index: 1) },
            completion: { completion($0, planeW, planeH) })
    }

    // MARK: - DeckLink output (D-real: RGB offscreen → v210 10-bit, push-on-render, pull-latest)

    /// Begin DeckLink output for a fixed output frame size. Allocates the double-buffered .shared
    /// staging pair (dst v210 = rowBytes*height each) and arms the push convert. Called from the App
    /// (DeckLinkService) when scheduled playback starts. Idempotent.
    func beginDeckLinkOutput(width: Int, height: Int) {
        deckLinkLock.lock(); defer { deckLinkLock.unlock() }
        let rowBytes = Self.v210RowBytes(width: width)
        if deckLinkOutputSize?.w != width || deckLinkOutputSize?.h != height || deckLinkStaging.count != 2 {
            let bytes = rowBytes * height   // v210: full padded rows
            deckLinkStaging = (0..<2).compactMap { _ in device.makeBuffer(length: bytes, options: .storageModeShared) }
            deckLinkOutputSize = (width, height)
            deckLinkRowBytes = rowBytes
        }
        deckLinkFrontIndex = 0
        deckLinkFrameReady = false
        deckLinkConverting = false
        deckLinkResMismatchLogged = false
        deckLinkActive = (deckLinkStaging.count == 2)
    }

    /// Stop DeckLink output: disarm the convert and release the staging buffers.
    func stopDeckLinkOutput() {
        deckLinkLock.lock(); defer { deckLinkLock.unlock() }
        deckLinkActive = false
        deckLinkFrameReady = false
        deckLinkStaging = []
        deckLinkOutputSize = nil
        deckLinkRowBytes = 0
    }

    /// PUSH: convert the just-completed offscreen → v210 into the BACK staging buffer, then (on GPU
    /// completion) swap it to FRONT. Driven from the render completion handler. One-in-flight gated
    /// so converts never pile up; no-op when DeckLink output isn't active. Native-res guard: if the
    /// offscreen dims ≠ output dims, skip (mark not-ready) + log once — scaling is a later stage.
    private func pushDeckLinkConvert() {
        deckLinkLock.lock()
        guard deckLinkActive, !deckLinkConverting, deckLinkStaging.count == 2,
              let outSize = deckLinkOutputSize else { deckLinkLock.unlock(); return }
        let backIndex = 1 - deckLinkFrontIndex
        let back = deckLinkStaging[backIndex]
        deckLinkConverting = true
        deckLinkLock.unlock()

        guard let pipeline = deckLinkPipelineState, let src = offscreenTexture else {
            deckLinkLock.lock(); deckLinkConverting = false; deckLinkLock.unlock(); return
        }
        // Native-res-only guard: never convert a mismatched size (would misalign / need scaling).
        if src.width != outSize.w || src.height != outSize.h {
            deckLinkLock.lock()
            deckLinkFrameReady = false
            deckLinkConverting = false
            let alreadyLogged = deckLinkResMismatchLogged
            deckLinkResMismatchLogged = true
            deckLinkLock.unlock()
            if !alreadyLogged {
                print("DeckLink D-real: source \(src.width)x\(src.height) != output \(outSize.w)x\(outSize.h) — native-res only, holding neutral (scaling is a later stage)")
            }
            return
        }

        guard let cmd = deckLinkCommandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            deckLinkLock.lock(); deckLinkConverting = false; deckLinkLock.unlock(); return
        }
        // Matrix selected by source colorMatrixCode ONLY (never from primaries) — read live so a
        // mid-session source change is picked up on the next converted frame.
        let m = ycbcrKrKb(forMatrixCode: sourceMatrixCode)
        var params = RGBToV210Params(srcWidth: UInt32(src.width), srcHeight: UInt32(src.height),
                                     dstWidth: UInt32(outSize.w), dstHeight: UInt32(outSize.h),
                                     dstRowWords: UInt32(deckLinkRowBytes / 4),
                                     kr: m.kr, kb: m.kb)
        enc.setComputePipelineState(pipeline)
        enc.setTexture(src, index: 0)
        enc.setBuffer(back, offset: 0, index: 0)
        enc.setBytes(&params, length: MemoryLayout<RGBToV210Params>.stride, index: 1)
        // One thread per OUTPUT 6-pixel GROUP: grid ceil(dstWidth/6) × dstHeight.
        let tpg = MTLSize(width: 16, height: 16, depth: 1)
        let tgs = MTLSize(width: (((outSize.w + 5) / 6) + 15) / 16, height: (outSize.h + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(tgs, threadsPerThreadgroup: tpg)
        enc.endEncoding()

        cmd.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.deckLinkLock.lock()
            // The back buffer is now a COMPLETE frame → make it the front; clear the gate.
            self.deckLinkFrontIndex = backIndex
            self.deckLinkFrameReady = true
            self.deckLinkConverting = false
            self.deckLinkLock.unlock()
        }
        cmd.commit()
    }

    /// PULL (DeckLink callback thread): memcpy the current FRONT staging buffer into the DeckLink
    /// v210 frame pointer, respecting rowBytes. Returns false if no converted frame is ready yet or
    /// dims don't match (caller fills neutral). The ONLY work on the callback thread — NO GPU wait.
    /// The lock is held across the memcpy so the front index can't swap mid-copy (the convert's
    /// swap + the push dispatch both take the lock), guaranteeing a tear-free complete frame.
    func copyLatestDeckLinkFrame(into dst: UnsafeMutableRawPointer, rowBytes: Int, width: Int, height: Int) -> Bool {
        deckLinkLock.lock(); defer { deckLinkLock.unlock() }
        guard deckLinkFrameReady, deckLinkStaging.count == 2,
              let outSize = deckLinkOutputSize, outSize.w == width, outSize.h == height else { return false }
        let srcRowBytes = deckLinkRowBytes   // v210 stride (matches the frame's; equal for 48-multiple widths)
        let srcPtr = deckLinkStaging[deckLinkFrontIndex].contents()
        if rowBytes == srcRowBytes {
            memcpy(dst, srcPtr, srcRowBytes * height)
        } else {
            for y in 0..<height {
                memcpy(dst.advanced(by: y * rowBytes), srcPtr.advanced(by: y * srcRowBytes), srcRowBytes)
            }
        }
        return true
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
