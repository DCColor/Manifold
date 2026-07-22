import Foundation
import AppKit          // E2: NSScreen — EDR headroom query
import Metal
import CoreVideo
import CoreMedia
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import ManifoldCore      // UnfairLock — priority-donating lock for the live frame queue

// `UnfairLock` used to be defined here. It now lives in ManifoldCore (Sources/ManifoldCore/
// UnfairLock.swift) because LiveClock needs the same primitive and ManifoldCore cannot depend on
// the App layer. Hoisted rather than copied — see that file for the inversion argument and the
// "nothing slow under this lock" rule that keeps donation from backfiring.

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
    var kr: Float          // YCbCr luma coeff for R (from source colorMatrixCode)
    var kb: Float          // YCbCr luma coeff for B
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
    var kr: Float           // YCbCr luma coeff for R (from source colorMatrixCode)
    var kb: Float           // YCbCr luma coeff for B
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

    // E1 (was M3b): float render target. rgba16Float — the EDR container Apple specifies for
    // extended dynamic range. CAMetalLayer-compatible (the 1:1 blit to the drawable stays
    // same-format), 8 bytes/pixel, half per channel.
    //
    // Why float, and why now: rgb10a2Unorm is UNSIGNED-NORMALIZED, so the render-target
    // write HARDWARE-CLAMPS every channel to [0,1]. That clamp is exactly what an EDR path
    // cannot live with — EDR *is* values above 1.0. half carries >1.0 and negatives, and its
    // grid is FINER than the 10-bit one everywhere in (0,1] (2× near white, more below).
    // The clamp was not hypothetical: the legal gray ramp already peaks at 1.000977, and
    // rgb10a2 was destroying that superwhite on every frame.
    //
    // This is a CONTAINER change ONLY. No EDR opt-in (no wantsExtendedDynamicRangeContent —
    // that is E2), no transfer math, no range/matrix change.
    //
    // KNOWN ACCEPTED RESIDUAL — read this before "fixing" a ±1-code scope/export diff.
    // SDR is NOT bit-identical to the rgb10a2 path, and it CANNOT be made so: half's grid is
    // finer than the 10-bit grid but NOT ALIGNED to it, so a value sitting near a 10-bit
    // rounding boundary can round-trip through half and land one code the other side. That is a
    // property of the two grids, not a bug, and no rounding mode removes it. Measured on the M3b
    // ramp fixtures (E1 validation), one affected consumer per range:
    //   legal ramp: SDI v210 output BIT-IDENTICAL (the legal round-trip is self-correcting);
    //               export re-quantized to 10-bit differs by ±1 code on 8.8% of pixels.
    //   full ramp:  export BIT-IDENTICAL (full-range codes sit exactly on the 10-bit grid);
    //               SDI v210 differs by ±1 code on 2.2% of words.
    // Every delta is exactly ±1 LSB at 10-bit and verified SYMMETRIC (unbiased), landing inside
    // bins rgb10a2 was already rounding — sub-LSB, below the panel noise floor, NOT a behavioral
    // regression. The symmetry is load-bearing: see the half4 note in PassthroughShader.metal for
    // why the fragment return type must stay half4, and what biases dark if it doesn't.
    //
    // DELIBERATE: an rgba32Float offscreen (drawable stays half) would be exactly bit-identical,
    // and was REJECTED — it doubles hot-path bandwidth and offscreen memory (133MB → 265MB at 4K)
    // to erase noise the prior container was itself manufacturing.
    //
    // Display, export, DeckLink and the SCOPES all read this target. The scopes and the
    // DeckLink v210 encoder are GPU kernels that sample it as a normalized float
    // (`offscreen.read(gid)`) — half decodes to float exactly as unorm10 did, so they are
    // format-agnostic and need no change. The CPU readback (export) is NOT format-agnostic:
    // it must unpack half, not packed 10-10-10-2 — see renderBytesPerPixel / rgba16FloatToRGBA16.
    // Propagates to the layer + pipeline color attachment via the references below.
    static let renderPixelFormat: MTLPixelFormat = .rgba16Float

    /// Bytes per pixel of `renderPixelFormat`. The CPU readback path (export) needs this to
    /// size its rows: rgb10a2Unorm was 4 (packed 10-10-10-2), rgba16Float is 8 (4 × half).
    /// It was previously an inline `width * 4` — which silently under-reads a float target
    /// (half a row per row), so it lives next to the format constant now to stay in step.
    static let renderBytesPerPixel: Int = 8

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

    /// Called at the TOP of every display tick, before a frame is selected — the hook a PULL
    /// source needs to put a frame in the queue on our clock rather than pushing on its own.
    /// (NDI's FrameSync works this way: it holds the jitter buffer and hands over whatever frame
    /// is current when we ask.) Runs on the CVDisplayLink thread, so it must not block: an
    /// implementation may only do the cheap capture + enqueue, never wait on the network.
    /// Nil for push sources (file playback), which are unaffected by this.
    var onDisplayTick: (() -> Void)?

    /// One display tick's view of the frame queue, as the live control loop needs to see it.
    ///
    /// Every field is captured in ONE `queueLock` critical section (the same one that performs
    /// selection), so they are mutually consistent: `hadEligibleFrame` describes the very
    /// selection that produced the `oldest`/`newest` edges reported alongside it. Sampling them
    /// separately would let the queue change between reads and hand the clock a state that never
    /// actually existed.
    struct DepthSample {
        /// Seconds of buffered lead ahead of the clock (`newestQueuedPTS − now`, half-frame
        /// corrected). The control loop's regulated signal.
        let spanSeconds: Double
        /// Queued frame count AFTER this tick's consumption.
        let count: Int
        /// PTS of the oldest queued frame, or nil if the queue is empty. The freeze guard's
        /// evidence: how far ahead of the clock the NEAREST reachable frame sits.
        let oldestPTS: Double?
        /// PTS of the newest queued frame, or nil if the queue is empty. What a coarse re-anchor
        /// positions the clock relative to.
        let newestPTS: Double?
        /// Whether a frame satisfied `pts <= now` on this tick. False with a NON-EMPTY queue is
        /// the freeze signature — normal for a tick or two between frames, pathological when sustained.
        let hadEligibleFrame: Bool
    }

    /// Buffer-depth telemetry for LIVE sources: called once per display tick, AFTER the queue is
    /// unlocked. The live source forwards this to its `LiveClock` control loop (ManifoldCore can't
    /// read the renderer, so the queue state is PUSHED from here). Nil for file/NDI — a pure no-op
    /// for them. Set on main by the live source's start(); cleared on stop().
    var onDepthSample: ((DepthSample) -> Void)?

    /// The queue hit `maxQueued` on enqueue — under a live source, by definition excess buffer.
    /// Called on the SOURCE thread, AFTER `queueLock` is released, with the newest queued PTS and
    /// the post-trim count. The live source forwards it to `LiveClock.overflowReanchor`, which
    /// moves the CLOCK (the only thing that removes latency) instead of relying on the drop-oldest
    /// trim (which removes none — see that method). Nil for file/NDI, where the shallow default
    /// bound is a plain backstop and there is no clock to re-anchor.
    var onQueueOverflow: ((_ newestPTS: Double, _ count: Int) -> Void)?

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
    /// D4b-2: SOURCE PTS (seconds) of the frame sitting in the FRONT v210 staging buffer — i.e. the
    /// frame the DeckLink fill block is handing to the card. NaN when no converted frame is ready.
    /// This is the number the whole A/V alignment hangs on: displayTick chooses a frame by PTS, and
    /// that PTS is carried through the convert and published HERE, alongside the pixels it belongs to,
    /// when the convert's GPU work completes and the buffer becomes the front. So "what is on the wire"
    /// and "what source time is on the wire" are published atomically under the same lock — the audio
    /// callback can never read a source time that belongs to a different frame than the one it's paired
    /// with. Guarded by deckLinkLock (written on a Metal completion thread, read on the SDK audio thread).
    private var deckLinkFrontPts: Double = .nan

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
    private let queueLock = UnfairLock()   // priority-donating; dissolves the live-path inversion
    /// Recent inter-frame PTS deltas (presentation order) + their cached median Δ, for the depth
    /// half-frame correction (see the depth read in performDisplayTick). Written in `enqueue`, read in
    /// `performDisplayTick` — BOTH under `queueLock`. The median is recomputed in `enqueue` (emit
    /// thread) so the render-thread depth read stays an O(1) load, honoring the priority-inversion
    /// discipline. Median+clamp keeps Δ stable (it's structural / fps-only) so the correction adds no
    /// jitter to the very signal it cleans.
    private var ptsDeltaHistory: [Double] = []
    private let ptsDeltaHistoryMax = 8
    /// Last-good median inter-frame interval Δ. 0 until ≥2 valid deltas seen — while 0 the correction
    /// is a no-op (+0), which is correct: with no cadence known yet, don't fabricate buffered lead.
    /// Only ever set from a valid median, so it never holds a rejected/outlier value.
    private var cachedFrameInterval: Double = 0
    /// Default queue bound (file/NDI path). Shallow on purpose — a file rides the synchronizer, not
    /// this buffer. A live source raises it via `maxQueuedOverride` for control-loop headroom.
    private let defaultMaxQueued = 12   // bounded buffer
    /// Live-path override for the queue bound. nil → `defaultMaxQueued`. Set on main by the live
    /// source's start() (e.g. 30) to give the LiveClock control loop room above the shallow file
    /// default; restored to nil on stop(). Evaluated inside `enqueue` under `queueLock`.
    var maxQueuedOverride: Int?
    private var maxQueued: Int { maxQueuedOverride ?? defaultMaxQueued }

    private var displayLink: CVDisplayLink?

    // Last rendered frame + a refresh request, so a range-override change while
    // PAUSED (no new frame arriving) still re-renders with the new shader flag.
    // lastPixelBuffer is touched only on the render thread; pendingRefresh is
    // guarded because setNeedsRefresh() is called from the main thread.
    private var lastPixelBuffer: CVPixelBuffer?
    /// SOURCE PTS of `lastPixelBuffer`, so a paused re-render (shader-flag change) carries the same
    /// source time forward instead of losing it. Render thread only, like lastPixelBuffer.
    private var lastPixelBufferPts: Double = .nan
    private let refreshLock = NSLock()
    private var pendingRefresh = false

    // Set by flush() (i.e. a seek). Arms a ONE-SHOT relaxed render in displayTick: while
    // PAUSED, if no queued frame satisfies the strict pts<=now gate (a decoder that seeks
    // to the frame just AFTER the target — libav overshoot), render the nearest queued
    // frame anyway so the paused offscreen (scope data source) + display reflect the
    // seeked-to frame instead of the previous one. Guarded (set on main via flush(), read
    // on the render thread). Decoder-agnostic; does NOT touch the playing-state path.
    private var pendingSeekRender = false

    // One-shot "wipe to black" armed by clearToBlack() (main) when a source is torn down with
    // nothing to replace it — serviced on the render thread so nextDrawable() stays single-threaded.
    private var pendingClear = false

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
        // Colorspace AND the EDR opt-in are set per SOURCE in setSourceColorSpace(...), from the
        // file's CICP tags. wantsExtendedDynamicRangeContent is deliberately NOT set here — see
        // the E2 note there for why it is HDR-conditional rather than globally on.

        // Once per PROCESS, not once per renderer. Headroom is a property of the display, not of
        // this object, so there is nothing to say a second time — and a renderer is constructed
        // per window. (This guard also predates the ContentView fix, where a @State default-value
        // expression was rebuilding the renderer on every SwiftUI update; see RendererStore.)
        Self.logStartupHeadroomOnce

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

        // E2 — EDR opt-in, DELEGATE-FIRST: we do NOT decode PQ/HLG ourselves. The buffer stays
        // transfer-ENCODED (PQ code values), the layer carries the matching PQ/HLG colorspace
        // (makeColorSpace above resolves (9,16) → kCGColorSpaceITUR_2100_PQ), and macOS applies
        // the EOTF and tone-maps to the display's headroom. This flag is what lets it: without
        // it the drawable is SDR-clamped and PQ diffuse white (0.58 in the buffer) shows as 58%
        // grey instead of white.
        //
        // HDR-CONDITIONAL, not globally on. The flag is scoped to PQ (16) and HLG (18) sources
        // and left OFF for everything else, so the SDR path's layer configuration is bit-for-bit
        // what it was before E2 — SDR cannot regress, by construction rather than by test.
        // That matters for two concrete reasons:
        //   1. SDR is committed and validated; the E1 gate work showed how easily a "global,
        //      surely-harmless" flag reaches the output.
        //   2. Our SDR content is NOT confined to [0,1]: the legal ramp peaks at 1.000977, and
        //      E1's float target now PRESERVES that superwhite instead of clamping it. Whether a
        //      global EDR opt-in would lift those values above SDR white in a non-extended
        //      CoreMedia709 space is exactly the kind of question we should not be guessing at.
        //      Scoping the flag to HDR sources removes the question instead of betting on it.
        let isHDRTransfer = (transfer == 16 || transfer == 18)   // PQ / HLG

        // Assign inside a synchronized transaction (actions disabled) so this
        // once-per-source mutation can't tear against an in-flight frame on the
        // CVDisplayLink render thread.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.colorspace = cs
        metalLayer.wantsExtendedDynamicRangeContent = isHDRTransfer
        CATransaction.commit()

        // NOTE: edrMetadata (CAEDRMetadata) is deliberately NOT set — E3. This stage tests
        // whether colorspace + the opt-in alone lift the image. If PQ content does not display
        // without it, edrMetadata is REQUIRED-to-display rather than a tonemapping refinement,
        // and that is the finding this stage exists to produce.

        let csName = cs.name.map { String($0) } ?? "<unnamed>"
        print("[EDR] source tags: primaries=\(primaries.map(String.init) ?? "nil") "
            + "transfer=\(transfer.map(String.init) ?? "nil") matrix=\(matrix.map(String.init) ?? "nil")")
        print("[EDR] layer colorspace = \(csName)  (wideGamut=\(cs.isWideGamutRGB))")
        print("[EDR] wantsExtendedDynamicRangeContent = \(isHDRTransfer)"
            + (isHDRTransfer ? "  (HDR transfer \(transfer!) → EDR ON)" : "  (SDR source → EDR OFF, unchanged path)"))
        Self.logEDRHeadroom(context: "source load")
    }

    /// Fires `logEDRHeadroom` exactly once per process (lazy static = dispatch_once).
    private static let logStartupHeadroomOnce: Void = {
        logEDRHeadroom(context: "startup")
    }()

    /// Log the display's EDR headroom. 1.0 means NO headroom — EDR is inert and PQ content
    /// cannot lift above SDR white no matter how the layer is configured (check macOS
    /// Settings ▸ Displays ▸ High Dynamic Range for the target display). Values >1.0 are the
    /// multiple of SDR white the display can currently reach; this is the number a future
    /// EDRMetadata / tone-mapping stage has to map into.
    private static func logEDRHeadroom(context: String) {
        // Prefer the screen actually hosting the app; fall back to main.
        let screen = NSApp?.mainWindow?.screen ?? NSApp?.windows.first?.screen ?? NSScreen.main
        guard let s = screen else { print("[EDR] headroom (\(context)): no screen"); return }
        let cur = s.maximumExtendedDynamicRangeColorComponentValue
        let pot = s.maximumPotentialExtendedDynamicRangeColorComponentValue
        let ref = s.maximumReferenceExtendedDynamicRangeColorComponentValue
        print(String(format: "[EDR] headroom (%@) on \"%@\": current=%.4f potential=%.4f reference=%.4f%@",
                     context, s.localizedName, cur, pot, ref,
                     cur <= 1.0001 ? "   <<< NO HEADROOM — EDR is inert on this display" : ""))
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

        let frame = QueuedFrame(pts: pts, pixelBuffer: pixelBuffer)
        queueLock.lock()
        // Ordered insert — keeps frameQueue sorted ascending by pts WITHOUT an O(n log n) sort under
        // the lock. Frames arrive at or near the tail (NDI stamps monotonic PTS; WHEP/VideoToolbox
        // emits in presentation order; the synth harness only reorders locally across B-frames), so
        // scanning backward from the end lands the insertion point in O(1) amortized for in-order
        // arrivals (O(n) worst case). The drop-oldest trim and the depth read (last?.pts, .count)
        // below both depend on this ascending order, so the invariant they rely on is preserved.
        var i = frameQueue.count
        while i > 0, frameQueue[i - 1].pts > frame.pts { i -= 1 }
        // Track the inter-frame PTS interval for the depth half-frame correction. Use the SORTED-order
        // predecessor (frameQueue[i-1]), NOT the last-arrived frame, so a B-frame reorder can't produce a
        // negative delta. Clamp out dup-PTS (≤0) and dropped-frame/absurd (>0.5s) gaps here; the MEDIAN
        // below rejects the 2Δ dropped-frame outliers that survive the clamp. Recompute the median NOW
        // (emit thread) so the render-thread depth read is just a cachedFrameInterval load.
        if i > 0 {
            let d = frame.pts - frameQueue[i - 1].pts
            if d > 0, d <= 0.5 {
                ptsDeltaHistory.append(d)
                if ptsDeltaHistory.count > ptsDeltaHistoryMax {
                    ptsDeltaHistory.removeFirst(ptsDeltaHistory.count - ptsDeltaHistoryMax)
                }
                if ptsDeltaHistory.count >= 2 {
                    let sorted = ptsDeltaHistory.sorted()
                    let mid = sorted.count / 2
                    cachedFrameInterval = sorted.count.isMultiple(of: 2)
                        ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
                }
            }
        }
        frameQueue.insert(frame, at: i)
        // Bound the queue. The removeFirst trim is retained as the MECHANICAL BACKSTOP — the array
        // must not grow without limit — but it is no longer the policy. Dropping the oldest frame
        // removes no latency at all (depth is `newest − now`, which eviction does not move) while
        // discarding exactly the frames about to become eligible; left as the only response, that
        // slides the whole window into the future until nothing satisfies `pts <= now` and the
        // renderer freezes. So: report the overflow to the live source, which re-anchors the CLOCK.
        // Captured under the lock, fired after it (see below) — never call out under queueLock.
        var overflow: (newestPTS: Double, count: Int)?
        if frameQueue.count > maxQueued {
            frameQueue.removeFirst(frameQueue.count - maxQueued)
            if let newest = frameQueue.last?.pts { overflow = (newest, frameQueue.count) }
        }
        queueLock.unlock()

        // Outside the lock: the sink takes LiveClock's lock, and holding two is how deadlocks are
        // built. Same discipline as onDepthSample below.
        if let overflow { onQueueOverflow?(overflow.newestPTS, overflow.count) }
    }

    /// Clear all queued frames (call on seek).
    func flush() {
        queueLock.lock()
        frameQueue.removeAll()
        // Source-switch boundary (seek, stop, WHEP reconnect — possibly at a different fps): drop the
        // inter-frame Δ history so the depth correction no-ops (+0) until reseeded, rather than applying
        // a stale Δ across the discontinuity / re-anchor transient.
        ptsDeltaHistory.removeAll()
        cachedFrameInterval = 0
        queueLock.unlock()
        // A seek just cleared the queue. Arm the one-shot: if we're paused and the next
        // delivered frame overshoots the pinned clock (pts > now), displayTick renders it
        // anyway so the paused offscreen isn't left on the previous frame.
        refreshLock.lock(); pendingSeekRender = true; refreshLock.unlock()
    }

    /// Wipe the screen to BLACK on the next display tick. Called when a source is torn down (NDI
    /// disconnect) with nothing replacing it: the CAMetalLayer otherwise keeps its last presented
    /// drawable, so the final streamed frame stays frozen behind the empty state. Drops the queued
    /// frames so nothing stale is selected, and arms a one-shot black present that runs on the
    /// RENDER thread (main never touches nextDrawable). If a source is still actively producing
    /// frames — e.g. a file kept playing — its next frame simply repaints over the black.
    func clearToBlack() {
        flush()   // drop queued frames; nothing stale left to select
        refreshLock.lock()
        pendingClear = true
        pendingRefresh = false     // don't let a pending refresh repaint the old frame after the wipe
        pendingSeekRender = false  // flush() just armed this; the queue is empty, so it's moot
        refreshLock.unlock()
        // Invalidate the readable offscreen too: the GPU scopes sample it, so leaving the last
        // streamed frame there would let a scope (re)sample and republish it after the source is
        // gone. -1 makes computeXxxGPU find no frame → no sample → the panels stay blank until a
        // new source renders. (The scope models also blank their published image; see clear().)
        offscreenIndexLock.lock()
        offscreenReadableIndex = -1
        offscreenIndexLock.unlock()
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
        #if DEBUG
        // DISPLAY-LINK CADENCE: stamp the interval since the previous tick BEFORE any work, so it
        // measures the callback's arrival cadence, not how long this tick takes. See rpLastTickWall.
        let rpTickWall = CACurrentMediaTime()
        if rpLastTickWall != 0 {
            let dt = rpTickWall - rpLastTickWall
            rpTickSum += dt
            rpTickMax = max(rpTickMax, dt)
            rpTickCount += 1
        }
        rpLastTickWall = rpTickWall
        #endif

        // Wrap the per-tick render in an autorelease pool. The CVDisplayLink callback runs on a
        // dedicated CoreVideo thread that has NO run-loop-drained autorelease pool, so the
        // autoreleased CAMetalDrawable returned by nextDrawable() (along with this tick's command
        // buffer and the CVMetalTexture wrappers) would linger until the thread's top-level pool
        // drains — which on this thread is effectively never. A lingering CAMetalDrawable keeps its
        // drawable checked OUT of the CAMetalLayer's (default-3) pool even after it has been presented
        // and scanned out, so the pool drains over a few seconds and nextDrawable() starts BLOCKING on
        // a free drawable — the confirmed live-path stall (drawMs balloons, presented-fps sags, while
        // the display-link interval stays flat). Draining a pool every tick returns each drawable
        // promptly, so the pool never starves under sustained 24fps.
        autoreleasepool { performDisplayTick() }
    }

    /// The body of one display-link tick, run inside `displayTick`'s per-tick autorelease pool.
    /// Split out so the pool wraps the WHOLE tick — drawable, command buffer, and texture wrappers
    /// all release at tick end — without the pool's closure swallowing this code's many early
    /// `return`s (a bare `return` inside the pool closure would only exit the closure, not the tick).
    private func performDisplayTick() {
        // Release the PREVIOUS frame's CVMetalTextureCache entries whose backing IOSurfaces are no
        // longer referenced (the in-flight command buffer still retains any it needs, so this can't
        // free a texture that's in use). Without it, the cache accumulates one texture/IOSurface per
        // DISTINCT incoming buffer — bounded for the recycled decode pool, but an unbounded leak for
        // any source of distinct-per-frame surfaces — ballooning texture-creation time on this thread
        // and throttling presentation. CVMetalTextureCacheFlush is the documented fix and is harmless
        // for normal (already-bounded) playback. Same thread as makeTexture, so no extra locking.
        CVMetalTextureCacheFlush(textureCache, 0)

        // One-shot screen wipe: a source was torn down with nothing to replace it. Present a black
        // drawable and stop, dropping the retained last frame so no later tick can repaint it.
        refreshLock.lock()
        let doClear = pendingClear
        if doClear { pendingClear = false }
        refreshLock.unlock()
        if doClear {
            lastPixelBuffer = nil
            lastPixelBufferPts = .nan
            presentBlackFrame()
            return
        }

        // Pull sources first, so a frame captured this tick is eligible for selection THIS tick
        // (and before the clock is read, so its PTS can't land in the future). No-op for push
        // sources — this is nil during file playback.
        onDisplayTick?()

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
        // Live-source depth signal, sampled under the lock right AFTER consumption so it reflects the
        // buffer the control loop must hold: span = seconds of buffered lead ahead of the clock
        // (newest queued PTS − now). Pushed to onDepthSample AFTER unlock so the sink never runs under
        // queueLock. No-op for file/NDI (they don't install onDepthSample).
        //
        // HARDENING: report span 0 (truthful "buffer empty") when the queue is empty OR the clock is
        // unanchored — a live clock's pre-anchor sentinel is -.infinity, so `now.isFinite == false`
        // there. This prevents `newestPTS - (-inf) ≈ 1.7e308` poison reaching the control loop. Clamp
        // negative spans to 0 too: a frame already past due is not "negative depth".
        let newest = frameQueue.last?.pts
        // Freeze-guard evidence, captured in the SAME critical section as the selection above so
        // the two describe one consistent instant. `oldest` is read AFTER consumption, so it is
        // the nearest frame the NEXT tick could reach — which is exactly what "the clock is behind
        // the whole queue" has to be measured against.
        let oldest = frameQueue.first?.pts
        // STRUCTURAL-OFFSET CORRECTION (pre-controller): the raw lead (newest − now) is a sawtooth whose
        // EMA-regulated MEAN rests Δ/2 (~half a frame) below the true per-frame fill. Add Δ/2 so the
        // regulated mean equals the fill — making targetDepth ≡ startupDepth ≡ physical buffered lead, so
        // a "0.100 target" means 100 ms of real fill. Δ is the source-agnostic median of recent queued
        // PTS deltas (cachedFrameInterval); it is 0 until seeded → correction is a no-op then. The max(0,)
        // floor is applied AFTER +Δ/2, so the corrected signal reaches 0 at genuine underrun (once the
        // newest frame is ≥ Δ/2 past due) — truthful where it matters for the jitter/underrun tests, and
        // identical to floor-before in the healthy sawtooth regime (raw span never near 0 there).
        let depthSpan: Double = (newest != nil && now.isFinite) ? max(0, (newest! - now) + cachedFrameInterval / 2) : 0
        let depthCount = frameQueue.count
        queueLock.unlock()

        onDepthSample?(DepthSample(spanSeconds: depthSpan,
                                   count: depthCount,
                                   oldestPTS: oldest,
                                   newestPTS: newest,
                                   hadEligibleFrame: chosen != nil))

        if let pb = chosen {
            // D4b-2: chosenPts — the SOURCE time of the frame selected for display — is no longer
            // discarded here. It rides with the pixels through the offscreen → v210 convert → staging,
            // and the DeckLink audio callback keys the audio stream to it. Serving audio at the source
            // timestamp the VIDEO carries is what makes A/V alignment structural instead of a guess:
            // it compensates the whole video pipeline delay (offscreen → convert → staging → memcpy →
            // card preroll) for free, because the delay is what the pipeline IS, not something we model.
            renderPixelBuffer(pb, pts: chosenPts)
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
                // shader-flag change shows. Same frame → same source time.
                renderPixelBuffer(pb, pts: lastPixelBufferPts)
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
                    renderPixelBuffer(nearest.pixelBuffer, pts: nearest.pts)
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

    #if DEBUG
    // [RENDER-PERF] — per-stage render timing on the CVDisplayLink thread, logged once/sec. Frame
    // PRODUCTION is already ruled out (flat [SYNTH-PERF]); this measures the render side to find what
    // degrades over a synthetic run. tex = CVMetalTextureCache texture creation, draw = nextDrawable()
    // acquire (blocks if drawables/textures accumulate), enc = command encode, pres = present+commit.
    // iosurface flags whether the incoming buffer is IOSurface-backed — a NON-IOSurface copy (the
    // alwaysCopiesSampleData suspect) forces slow CPU uploads. texFail counts makeTexture bails.
    // Shared by normal AND synthetic playback, so the two can be compared directly.
    private var rpWindowStart: Double = 0
    private var rpSamples = 0
    private var rpTexSum = 0.0,  rpTexMax = 0.0
    private var rpDrawSum = 0.0, rpDrawMax = 0.0
    private var rpEncSum = 0.0,  rpEncMax = 0.0
    private var rpPresSum = 0.0, rpPresMax = 0.0
    private var rpCommitSum = 0.0, rpCommitMax = 0.0
    private var rpTexFail = 0
    private var rpLastIOSurface = false

    // DISPLAY-LINK CADENCE — wall-clock interval between consecutive displayTick() invocations.
    // Measured at the TOP of every tick (INCLUDING ticks that render nothing, e.g. paused), so it
    // reflects the CVDisplayLink callback's true firing rate, independent of GPU work. Touched only
    // on the CVDisplayLink thread (same as recordRenderPerf, which flushes these into the log line).
    //   • interval STABLE (~41.7ms @24fps sel / ~16.7ms @60Hz) but presented-fps sags → callback is
    //     on time, frames aren't ready/committed → a GPU-THROUGHPUT problem (look at drawMs/gpuMs).
    //   • interval GROWS when the sag hits → the display-link thread is being starved/blocked →
    //     a SCHEDULING problem, not throughput.
    private var rpLastTickWall = 0.0
    private var rpTickSum = 0.0, rpTickMax = 0.0
    private var rpTickCount = 0

    // ENCODE->PRESENT TAIL, GPU side — filled from the command buffer's addCompletedHandler, which
    // runs on a Metal completion thread (NOT the render thread), so these are guarded. `gpu` is pure
    // GPU execution (cb.gpuEndTime − cb.gpuStartTime); `lat` is end-to-end pipeline latency (commit →
    // completion wall clock), which ABSORBS drawable-pool back-pressure and vsync/present wait — if
    // lat balloons while gpu stays flat, frames are stalling behind present/drawables, not on the GPU.
    private let rpGpuLock = NSLock()
    private var rpGpuSum = 0.0, rpGpuMax = 0.0
    private var rpLatSum = 0.0, rpLatMax = 0.0
    private var rpGpuSamples = 0
    #endif

    // MARK: - Drawing

    /// `pts` is the frame's SOURCE presentation time (seconds). It is carried through the render so the
    /// DeckLink v210 convert can publish it with the converted pixels (D4b-2) — the audio stream keys
    /// off it. NaN is tolerated (means "unknown source time"): the audio path then holds silence rather
    /// than guessing an alignment.
    private func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, pts: Double) {
        lastPixelBuffer = pixelBuffer   // retained for paused refresh (render thread only)
        lastPixelBufferPts = pts
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Layer colorspace is set ONCE per source in setSourceColorSpace(...) from
        // MediaInspector's authoritative tags — NOT per-frame from the buffer.

        // M3b: pick texture sample formats from the buffer's bit depth. 10-bit x420
        // planes are 16-bit (10 bits MSB-aligned), sampled as r16/rg16; 8-bit 420v
        // as r8/rg8. The two normalize DIFFERENTLY — r16Unorm of an MSB-aligned 10-bit
        // sample is code/1023.984 (= code<<6 / 65535), r8Unorm is code/255 — and the
        // shader's range-expansion constants are in the 10-bit domain to match (see the
        // kCodeMax block in PassthroughShader.metal). The gap is NOT negligible: the old
        // 8-bit constants left legal white ~4 codes low and put neutral chroma off zero,
        // casting grays. In practice both decode paths request x420, so the r8/rg8 branch
        // below is currently unreachable; reviving it means making those constants
        // per-bit-depth (a uniform), not just flipping the texture format.
        let is10Bit = Self.isTenBit(CVPixelBufferGetPixelFormatType(pixelBuffer))
        let lumaFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let chromaFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

        // The chroma plane's size is ASKED FOR, not assumed. It used to be hard-coded to
        // (width/2, height/2) — true for the 4:2:0 formats the file paths decode to, but it
        // silently mis-sizes any other subsampling. The NDI receive path arrives as 4:2:2 (x422,
        // chroma = width/2 × FULL height), where the old constant would have sampled half the
        // plane and stretched it over the frame. For every 4:2:0 buffer this is byte-for-byte the
        // value it always computed, so the file paths are untouched.
        //
        // The shader needs no matching change: it samples chroma with NORMALIZED coordinates, so
        // a correctly-sized chroma texture resolves to the right chroma regardless of subsampling.
        //
        // The planeCount guard is the other half of the fix. A single-plane (packed) buffer used
        // to fall straight through to makeTexture(planeIndex: 1) and fail, which returns here and
        // renders NOTHING — a black window with no error, the worst possible symptom. Now the
        // unsupported case is stated once, out loud.
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else {
            logUnsupportedPixelFormatOnce(CVPixelBufferGetPixelFormatType(pixelBuffer))
            return
        }
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        #if DEBUG
        let rpIOSurface = (CVPixelBufferGetIOSurface(pixelBuffer) != nil)
        let rpTexStart = CACurrentMediaTime()
        #endif
        guard let lumaTexture = makeTexture(pixelBuffer, planeIndex: 0,
                                            pixelFormat: lumaFormat,
                                            width: width, height: height),
              let chromaTexture = makeTexture(pixelBuffer, planeIndex: 1,
                                              pixelFormat: chromaFormat,
                                              width: chromaWidth, height: chromaHeight)
        else {
            #if DEBUG
            rpTexFail += 1
            #endif
            return
        }
        #if DEBUG
        let rpTexEnd = CACurrentMediaTime()
        #endif

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

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = offscreen
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store

        // Encode the offscreen render pass BEFORE acquiring a drawable. This pass targets the ring
        // texture, not the drawable, so nothing here needs one — and acquiring later means a failure
        // in makeCommandBuffer()/makeRenderCommandEncoder() can't leave us holding a drawable we then
        // return from without presenting. A drawable acquired-but-never-presented is NEVER returned to
        // the pool; each such strand permanently shrinks the (default-3) pool until nextDrawable()
        // blocks forever. Acquire the drawable LAST — immediately before the blit that consumes it —
        // so it is checked out for the minimum span and every acquisition is always presented.
        #if DEBUG
        let rpEncStart = CACurrentMediaTime()
        #endif
        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        var params = colorParams(for: pixelBuffer)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        #if DEBUG
        let rpEncEnd = CACurrentMediaTime()
        #endif

        // Acquire the drawable here and NOWHERE else in the render path. If it comes back nil (pool
        // momentarily empty / the internal ~1s wait elapsed), drop this frame: nothing was checked
        // out, so the pool is unaffected and the next tick retries. The offscreen work encoded above
        // is simply discarded with the uncommitted command buffer.
        #if DEBUG
        let rpDrawStart = CACurrentMediaTime()
        #endif
        guard let drawable = metalLayer.nextDrawable() else { return }
        #if DEBUG
        let rpDrawEnd = CACurrentMediaTime()
        #endif

        // 1:1 blit offscreen -> drawable (same size and format). Color-neutral.
        if let blit = cmdBuffer.makeBlitCommandEncoder() {
            blit.copy(from: offscreen, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }

        // present() BEFORE commit() so Metal schedules the present with this frame's GPU work and the
        // drawable is handed back to the pool as soon as the frame is scanned out (not deferred).
        cmdBuffer.present(drawable)
        #if DEBUG
        // present() is just an enqueue of the present request — cheap unless it internally blocks.
        // Kept separate from commit so a stall shows up on the stage that actually owns it.
        let rpPresEnd = CACurrentMediaTime()
        // Wall clock at commit, captured so the completion handler can compute end-to-end latency
        // (commit → GPU-done + present). A growing lat with flat gpu = drawable/present back-pressure.
        let rpCommitWall = rpPresEnd
        #endif

        // Publish this buffer as the readable frame + trigger scope sampling ONLY once the
        // render's GPU work has COMPLETED — so scopes (on their own queue) read a fully-written
        // frame, never a half-drawn one (read-after-write safety without a cross-queue event).
        // Runs on a Metal completion thread; onFrameRendered just enqueues (non-blocking).
        cmdBuffer.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            #if DEBUG
            // GPU-side tail (completion thread): pure GPU exec + end-to-end pipeline latency. Guarded
            // because recordRenderPerf reads/resets these from the render thread. gpuStartTime/EndTime
            // are 0 if the buffer never scheduled; only record a plausible (positive) sample.
            let gpu = cb.gpuEndTime - cb.gpuStartTime
            let lat = CACurrentMediaTime() - rpCommitWall
            if gpu >= 0 {
                self.rpGpuLock.lock()
                self.rpGpuSum += gpu; self.rpGpuMax = max(self.rpGpuMax, gpu)
                self.rpLatSum += lat; self.rpLatMax = max(self.rpLatMax, lat)
                self.rpGpuSamples += 1
                self.rpGpuLock.unlock()
            }
            #endif
            self.offscreenIndexLock.lock()
            self.offscreenReadableIndex = writeIndex
            self.offscreenIndexLock.unlock()
            self.onFrameRendered?()
            // PUSH: convert this freshly-completed frame → v210 for DeckLink (no-op if not active).
            // The frame's SOURCE pts rides along so it can be published with the converted pixels.
            self.pushDeckLinkConvert(sourcePts: pts)
        }
        #if DEBUG
        let rpCommitStart = CACurrentMediaTime()
        #endif
        cmdBuffer.commit()
        #if DEBUG
        let rpCommitEnd = CACurrentMediaTime()
        recordRenderPerf(texture:  rpTexEnd    - rpTexStart,
                         drawable: rpDrawEnd   - rpDrawStart,
                         encode:   rpEncEnd    - rpEncStart,
                         present:  rpPresEnd   - rpDrawEnd,   // blit + present() (drawable already acquired)
                         commit:   rpCommitEnd - rpCommitStart,
                         iosurface: rpIOSurface)
        #endif
        // Advance so the NEXT render targets a different ring texture (write-during-read
        // safety: a scope reading this frame's buffer won't be overwritten until the ring
        // wraps ~offscreenRingCount frames later).
        offscreenWriteIndex = (writeIndex + 1) % Self.offscreenRingCount
    }

    #if DEBUG
    /// Accumulate per-stage render timings and log `[RENDER-PERF]` once/sec. On the CVDisplayLink
    /// thread (renderPixelBuffer is its sole caller). Reading it, to split "callback slow" from "GPU
    /// slow" when presented-fps sags:
    ///   • tick  — display-link callback cadence (avg/max ms between ticks). STABLE while fps sags →
    ///             callback is on time, the problem is downstream (throughput). GROWS with the sag →
    ///             the CVDisplayLink thread is starved/blocked (scheduling), not a GPU limit.
    ///   • tex   — CVMetalTextureCache texture creation (accumulation / non-IOSurface uploads).
    ///   • draw  — nextDrawable() acquisition. CRITICAL: this BLOCKS when the CAMetalLayer drawable
    ///             pool (maximumDrawableCount, default 3) is exhausted — the classic N-frames-then-stall.
    ///   • enc   — command encode (encoder setup through endEncoding).
    ///   • pres  — cmdBuffer.present(drawable) enqueue.
    ///   • commit— cmdBuffer.commit().
    ///   • gpu   — pure GPU execution (gpuEndTime − gpuStartTime), from the completion handler.
    ///   • lat   — end-to-end pipeline latency (commit → completion). lat ballooning while gpu stays
    ///             flat = frames stalling behind present/drawables, NOT GPU work.
    /// (x…) suffixes are the sample counts (tick counts every callback; gpu/lat count completed frames).
    /// `iosurface=N` → the alwaysCopiesSampleData copy stripped IOSurface backing (slow CPU path).
    /// Compare normal vs synthetic runs side by side.
    private func recordRenderPerf(texture: Double, drawable: Double, encode: Double, present: Double, commit: Double, iosurface: Bool) {
        rpSamples += 1
        rpTexSum += texture;   rpTexMax    = max(rpTexMax, texture)
        rpDrawSum += drawable; rpDrawMax   = max(rpDrawMax, drawable)
        rpEncSum += encode;    rpEncMax    = max(rpEncMax, encode)
        rpPresSum += present;  rpPresMax   = max(rpPresMax, present)
        rpCommitSum += commit; rpCommitMax = max(rpCommitMax, commit)
        rpLastIOSurface = iosurface

        let now = CACurrentMediaTime()
        if rpWindowStart == 0 { rpWindowStart = now; return }
        if now - rpWindowStart < 1.0 { return }

        let n = Double(max(1, rpSamples)), ms = 1000.0
        // Snapshot the GPU-side accumulators (written on the completion thread) under the lock.
        rpGpuLock.lock()
        let gN = Double(max(1, rpGpuSamples))
        let gpuAvg = rpGpuSum / gN * ms, gpuMax = rpGpuMax * ms
        let latAvg = rpLatSum / gN * ms, latMax = rpLatMax * ms
        let gpuSamples = rpGpuSamples
        rpGpuSum = 0; rpGpuMax = 0; rpLatSum = 0; rpLatMax = 0; rpGpuSamples = 0
        rpGpuLock.unlock()

        // tickMs = display-link callback cadence (avg/max wall interval between ticks). tN can differ
        // from n: cadence counts EVERY tick (incl. non-rendering), the stage timings only rendered ones.
        let tN = Double(max(1, rpTickCount))

        // footprintMB = process phys_footprint (the number Instruments' "Memory" column tracks),
        // sampled once per log. MONOTONIC CLIMB across a clean run = a buffer/texture accumulation
        // leak on the intake path (the texMs+copyMs climb-and-recover shape predicts this branch);
        // FLAT footprint points the diagnosis at scheduling (emitLateMs) or per-alloc bandwidth/lock
        // contention instead. One task_info call/sec is negligible.
        let footprintMB = Self.processFootprintMB()

        FileHandle.standardError.write(Data(String(format:
            "[RENDER-PERF] n=%d tickMs=%.2f/%.2f(x%d) texMs=%.2f/%.2f drawMs=%.2f/%.2f encMs=%.2f/%.2f presMs=%.2f/%.2f commitMs=%.2f/%.2f gpuMs=%.2f/%.2f latMs=%.2f/%.2f(x%d) footprintMB=%.1f texFail=%d iosurface=%@\n",
            rpSamples,
            rpTickSum / tN * ms,   rpTickMax * ms, rpTickCount,
            rpTexSum / n * ms,     rpTexMax * ms,
            rpDrawSum / n * ms,    rpDrawMax * ms,
            rpEncSum / n * ms,     rpEncMax * ms,
            rpPresSum / n * ms,    rpPresMax * ms,
            rpCommitSum / n * ms,  rpCommitMax * ms,
            gpuAvg, gpuMax,
            latAvg, latMax, gpuSamples,
            footprintMB,
            rpTexFail,
            rpLastIOSurface ? "Y" : "N").utf8))

        rpWindowStart = now
        rpSamples = 0
        rpTexSum = 0; rpTexMax = 0
        rpDrawSum = 0; rpDrawMax = 0
        rpEncSum = 0; rpEncMax = 0
        rpPresSum = 0; rpPresMax = 0
        rpCommitSum = 0; rpCommitMax = 0
        rpTickSum = 0; rpTickMax = 0; rpTickCount = 0
    }

    /// Process physical memory footprint in MB (task_vm_info.phys_footprint — the same figure
    /// Instruments and `jetsam` account against). Returns -1 if the task_info call fails. Cheap
    /// enough to call once per [RENDER-PERF] log; do NOT call it per frame.
    private static func processFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }
    #endif

    /// Present ONE cleared (black) drawable, replacing whatever was last on screen. A clear-only
    /// render pass straight to the drawable — no offscreen, no blit, no scope/DeckLink publish
    /// (there is no frame to sample). Render thread only, so it is the sole nextDrawable() caller
    /// exactly as renderPixelBuffer is.
    private func presentBlackFrame() {
        guard let drawable = metalLayer.nextDrawable() else { return }
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store
        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.endEncoding()   // clear-only pass — the load action does the work
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
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
    // E1: the render target is rgba16Float — 8 bytes/pixel, 4 × half (was 4 bytes/pixel packed
    // 10-10-10-2). exportCurrentFrame unpacks this raw form to a 16-bit PNG (rgba16FloatToRGBA16).
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

        let bytesPerRow = width * Self.renderBytesPerPixel
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
        // Luma weights from the source YCbCr matrix ONLY (never inferred from primaries) — read
        // live so a mid-session source change re-weights on the next sample. nil/2/unknown → 709.
        let m = ycbcrKrKb(forMatrixCode: sourceMatrixCode)
        var params = WaveformParams(width: UInt32(src.width), height: UInt32(src.height),
                                    scopeW: UInt32(scopeW), bins: UInt32(bins),
                                    rowStride: UInt32(max(1, rowStride)),
                                    kr: m.kr, kb: m.kb)
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
        // Chroma matrix (Kr/Kb) from the source colorMatrixCode ONLY (never from primaries — that
        // drives the graticule, not the math). Read live; nil/2/unknown → 709.
        let m = ycbcrKrKb(forMatrixCode: sourceMatrixCode)
        var params = VectorscopeParams(width: UInt32(src.width), height: UInt32(src.height),
                                       plane: UInt32(plane), rowStride: UInt32(max(1, rowStride)),
                                       chromaScale: chromaScale, kr: m.kr, kb: m.kb)
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
        deckLinkFrontPts = .nan          // no frame on the wire yet → audio has nothing to align to
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
        deckLinkFrontPts = .nan
    }

    /// PUSH: convert the just-completed offscreen → v210 into the BACK staging buffer, then (on GPU
    /// completion) swap it to FRONT. Driven from the render completion handler. One-in-flight gated
    /// so converts never pile up; no-op when DeckLink output isn't active. Native-res guard: if the
    /// offscreen dims ≠ output dims, skip (mark not-ready) + log once — scaling is a later stage.
    private func pushDeckLinkConvert(sourcePts: Double) {
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
            // The back buffer is now a COMPLETE frame → make it the front; clear the gate. The frame's
            // SOURCE pts is published in the SAME critical section as the pixels it belongs to, so the
            // audio callback can never pair a source time with the wrong frame (D4b-2).
            self.deckLinkFrontIndex = backIndex
            self.deckLinkFrontPts = sourcePts
            self.deckLinkFrameReady = true
            self.deckLinkConverting = false
            self.deckLinkLock.unlock()
        }
        cmd.commit()
    }

    /// D4b-2 (SDK audio-callback thread): the SOURCE time of the frame currently in the FRONT v210
    /// staging buffer — the frame the card is being fed. NaN when no converted frame is ready (output
    /// just started, no file loaded, or a resolution mismatch is holding neutral), which the audio path
    /// reads as "nothing to align to" and answers with silence. Same lock as the staging buffers, so
    /// this time and those pixels are always the same frame.
    func currentDeckLinkSourcePts() -> Double {
        deckLinkLock.lock(); defer { deckLinkLock.unlock() }
        return deckLinkFrameReady ? deckLinkFrontPts : .nan
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

    /// Unpack an rgba16Float (4 × half) buffer to 16-bit RGBA (alpha skipped/opaque).
    /// Channel order R,G,B,A (byteOrder16Little).
    ///
    /// E1: this replaces rgb10a2ToRGBA16, which unpacked packed 10-10-10-2 by hand — a bit
    /// layout the float target no longer has. The ENCODING it produced is preserved: each
    /// channel is quantized to a 10-bit code and left-shifted ×64 into the 16-bit range, so
    /// full white stays 1023<<6 = 65472 (not 65535) exactly as the old export wrote it. E1 is
    /// a container migration, not an export-format change.
    ///
    /// This is NOT bit-identical to the old export, and cannot be — half's grid is not aligned
    /// to the 10-bit grid, so re-quantizing here lands ±1 code away wherever the value sits
    /// near a 10-bit rounding boundary. Measured: full-range ramp exports bit-identical (0 of
    /// 8.29M px differ); legal-range ramp differs by ±1 code on 8.8% of pixels, symmetric and
    /// unbiased. See the E1 note on renderPixelFormat.
    ///
    /// Two consequences worth naming, both deferred to E2 rather than silently "fixed" here:
    ///   - The ×64 shift re-quantizes to 10 bits, discarding the extra precision half carries.
    ///     Keeping the old encoding is the point; widening it is an export change.
    ///   - Values >1.0 — the whole reason for the float target — are CLAMPED here. A 16-bit
    ///     integer PNG cannot represent them at all, so an EDR export needs a different
    ///     container (half-float TIFF/EXR): an E2+ decision, not something to fake now. This
    ///     DOES bite today: the legal ramp's 1.000977 superwhite is clamped back to 1023.
    ///
    /// Rounding mode is measured to be irrelevant here (round-half-even and round-half-away
    /// agree on every sample) — a half times 1023 essentially never lands on an exact .5.
    private static func rgba16FloatToRGBA16(_ src: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: width * 4 * height)
        src.withUnsafeBytes { inRaw in
            let halfs = inRaw.bindMemory(to: Float16.self)
            let rowHalfs = bytesPerRow / MemoryLayout<Float16>.stride
            out.withUnsafeMutableBufferPointer { outBuf in
                for y in 0..<height {
                    let inRow = y * rowHalfs
                    let outRow = y * width * 4
                    for x in 0..<width {
                        let p = inRow + x * 4
                        let o = outRow + x * 4
                        for ch in 0..<3 {
                            let v = min(max(Float(halfs[p + ch]), 0.0), 1.0)   // E2: >1.0 clamped
                            let code10 = UInt16((v * 1023.0).rounded(.toNearestOrEven))
                            outBuf[o + ch] = code10 << 6
                        }
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
        // E1: the readback is now rgba16Float (4 × half). Unpack to 16-bit RGBA with the SAME
        // ENCODING the rgb10a2 path used (10-bit code in the high bits) — same format, but not
        // bit-identical values: legal-range content lands ±1 code off on ~8.8% of pixels (the
        // accepted half-vs-10-bit grid residual). See rgba16FloatToRGBA16.
        let rgba16 = Self.rgba16FloatToRGBA16(bytes, width: width, height: height, bytesPerRow: bytesPerRow)
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

    /// True for the 10-bit biplanar CV formats whose planes are 16-bit-per-sample (10 bits
    /// high-aligned) — i.e. the ones the shader's 10-bit-domain constants are written for.
    ///
    /// The 4:2:2 pair (x422 / xf22) is here for the NDI receive path: NDI's 8-bit packed UYVY is
    /// converted to x422 on arrival precisely BECAUSE it puts the samples in this domain, where
    /// the existing shader math is already correct. The subsampling differs from x420 but the
    /// SAMPLE ENCODING — which is all this predicate is about — is identical.
    static func isTenBit(_ pf: OSType) -> Bool {
        pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || pf == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || pf == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
    }

    /// One-time complaint about a pixel format this renderer can't sample (a packed/single-plane
    /// buffer). Render-thread only — a per-frame log here would be 60 lines a second.
    private var loggedUnsupportedPixelFormat = false
    private func logUnsupportedPixelFormatOnce(_ pf: OSType) {
        guard !loggedUnsupportedPixelFormat else { return }
        loggedUnsupportedPixelFormat = true
        let fourCC = String(bytes: [UInt8((pf >> 24) & 0xFF), UInt8((pf >> 16) & 0xFF),
                                    UInt8((pf >> 8) & 0xFF), UInt8(pf & 0xFF)], encoding: .ascii) ?? "????"
        print("MetalVideoRenderer: unsupported pixel format '\(fourCC)' — needs a biplanar "
            + "(2-plane) YCbCr buffer; nothing will be drawn for this source")
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
