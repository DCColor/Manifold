import SwiftUI
import CoreGraphics
import Metal
import Combine
import ManifoldCore   // ScopeTrace — the -O-compiled trace-build (fast in Debug too)

/// Native vectorscope: a 2D chroma-plane (Cb horizontal, Cr vertical) scatter on a
/// circular graticule with the six color-bar target boxes (R, G, B, Cy, Mg, Yl).
/// Pure consumer of MetalVideoRenderer.readbackRenderedFrameAsync — samples the
/// PRE-DISPLAY offscreen texture (raw code values), never screen pixels. Independent
/// of the waveform/parade: own gate, own readback texture, runs alongside them.
final class VectorscopeScopeModel: ObservableObject {

    /// A/B toggle (Phase 3 GPU-scopes). `true` = compute the 2-D chroma-plane histogram on
    /// the GPU (vectorscopeKernel over the offscreen, tiny readback); `false` = the original
    /// CPU path (full-frame readback + 8.3M-pixel bin loop). Both feed the SAME trace-build
    /// (buildVectorscopeTraceImage) + graticule — output pixel-equivalent within the same
    /// 10-bit-float-vs-8-bit rounding as waveform/parade. Mirrors the other two toggles.
    static var useGPUVectorscope = true

    @Published var image: CGImage?
    weak var renderer: MetalVideoRenderer?

    // Square chroma-plane buffer. Tracks the rendered square side, clamped — a
    // bigger slot gives a crisper plot. (Light touch: the vectorscope is usually
    // height-limited in the tray, so this mostly stays near the previous 300.)
    private var plane = 300
    private let minPlane = 256
    private let maxPlane = 600

    /// Track the rendered square side so the plane buffer resolution scales with size.
    func setDisplaySide(_ side: CGFloat) {
        let p = scopeBucketWidth(side, min: minPlane, max: maxPlane)
        if p != plane { plane = p }
    }

    /// Chroma -> plot position, as a FRACTION of the plot dimension per chroma unit.
    /// Calibrated to 75% color bars (the broadcast/Resolve convention): at this scale
    /// the 75%-bar primaries/secondaries land ON the target boxes (boxes derived with
    /// the same transform below). The outermost 75% targets (green/magenta, chroma
    /// magnitude ≈ 114) sit at ~0.35 of the plot from center ≈ 77% of the graticule
    /// circle (radius 0.46), leaving headroom — 100% content reads further out,
    /// reaching ~the circle edge. 75% bars land in-box BY CONSTRUCTION.
    static let chromaScaleFrac: Float = 0.0031

    /// The six 75% reference colors (R, G, B, Cy, Mg, Yl) — classic SMPTE 75% bar
    /// levels: active channels at 0.75·255 ≈ 191, off channels 0. Used to DERIVE the
    /// target box centers from the SAME Cb/Cr transform as the plotted data
    /// (not hand-placed), so 75% bars must land in their boxes.
    static let targets: [(name: String, r: Float, g: Float, b: Float)] = [
        ("R",  191,   0,   0),
        ("Yl", 191, 191,   0),
        ("G",    0, 191,   0),
        ("Cy",   0, 191, 191),
        ("B",    0,   0, 191),
        ("Mg", 191,   0, 191)
    ]

    /// Rec.709 normalized chroma (matches Resolve's 709 vectorscope). Used by BOTH
    /// the per-pixel plot and the target-box derivation, so they are guaranteed
    /// consistent. Cb,Cr ≈ [-128,127] for 0–255 input.
    @inline(__always)
    static func chroma(r: Float, g: Float, b: Float) -> (cb: Float, cr: Float) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let cb = (b - y) / 1.8556
        let cr = (r - y) / 1.5748
        return (cb, cr)
    }

    private let workQueue = DispatchQueue(label: "com.graviton.manifold.scope.vector",
                                          qos: .userInitiated)
    private var readbackTexture: MTLTexture?

    // Render-coupled sampling state (main-only) — see WaveformScopeModel for the rationale.
    private var active = false
    private var sampling = false
    private var pendingSample = false
    /// Live pref-coupling (paused re-sample on a scope-pref change) — see WaveformScopeModel.
    private var prefsObserver: AnyCancellable?

    /// CPU path: process every Nth source row. Legacy fallback.
    private let rowStride = 2
    /// GPU path: process EVERY row (full-res) — cheap on the GPU, like waveform/parade.
    private let gpuRowStride = 1

    /// Mark visible and sample the current offscreen frame once (covers tray-open while
    /// paused). Sampling is otherwise render-coupled (frameRendered) + pref-coupled (below),
    /// not timer-driven.
    func start() {
        active = true
        if prefsObserver == nil {
            prefsObserver = NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.requestSample() }
        }
        requestSample()
    }

    func stop() {
        active = false
        pendingSample = false
        prefsObserver?.cancel()
        prefsObserver = nil
        image = nil
    }

    /// Render-coupled trigger (CVDisplayLink render thread) — hops to main; the GPU compute
    /// self-commits on its own command buffer, so this never blocks the render.
    func frameRendered() {
        DispatchQueue.main.async { [weak self] in self?.requestSample() }
    }

    private func requestSample() {
        guard active, renderer != nil else { return }
        if sampling { pendingSample = true; return }
        startSample()
    }

    /// Release the gate (main); if a frame arrived mid-cycle, re-sample the latest at once.
    private func finishSample() {
        sampling = false
        if pendingSample { startSample() }
    }

    private func startSample() {
        guard let renderer else { return }
        sampling = true
        pendingSample = false
        // Effective gain (Preferences read on main): baseGain × vectorscope × global master.
        let gain = baseGain
            * Float(Preferences.shared.vectorscopeIntensity)
            * Float(Preferences.shared.globalScopeIntensity)
        // Trace hue (snapshot on main); brightness stays the intensity's job.
        let color = ScopeColorCodec.rgb(fromHex: Preferences.shared.vectorscopeTraceColorHex)

        if Self.useGPUVectorscope {
            // GPU PATH: the plane×plane chroma histogram is computed by vectorscopeKernel over
            // the offscreen; only the small plane buffer (≤~1.4MB) is read back — no 33MB frame
            // copy, no CPU bin loop. The trace-build runs right here on the GPU completion
            // thread (a fast -O ScopeTrace call), then hops to main to publish.
            let plane = self.plane
            let issued = renderer.computeVectorscopeGPU(plane: plane,
                                                        chromaScale: Self.chromaScaleFrac,
                                                        rowStride: gpuRowStride) { [weak self] hist, p in
                guard let self else { return }
                let img = self.buildVectorscopeTraceImage(histogram: hist, plane: p, gain: gain, color: color)
                DispatchQueue.main.async {
                    if self.active, let img { self.image = img }
                    self.finishSample()
                }
            }
            if !issued { sampling = false }
            return
        }

        // CPU PATH (original).
        let issued = renderer.readbackRenderedFrameAsync(into: &readbackTexture) { [weak self] bytes, w, h, bpr in
            guard let self else { return }
            self.workQueue.async {
                let img = self.computeVectorscope(bytes: bytes, width: w, height: h, bytesPerRow: bpr, gain: gain, color: color)
                DispatchQueue.main.async {
                    if self.active, let img { self.image = img }
                    self.finishSample()
                }
            }
        }
        if !issued { sampling = false }
    }

    /// Plot each sampled pixel's chroma into the plane buffer; log-normalize; emit a
    /// white-on-black trace image. BGRA byte order; bytesPerRow; rowStride subsampling.
    private func computeVectorscope(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int, gain: Float, color: (r: Float, g: Float, b: Float)) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let plane = self.plane
        let center = Float(plane) * 0.5
        let s = Self.chromaScaleFrac * Float(plane)   // chroma units -> plane pixels

        var accum = [UInt32](repeating: 0, count: plane * plane)

        bytes.withUnsafeBufferPointer { buf in
            for y in stride(from: 0, to: height, by: rowStride) {
                let rowBase = y * bytesPerRow
                for x in 0..<width {
                    let p = rowBase + x * 4
                    // Readback is rgb10a2 (M3b 10-bit target); unpack to 8-bit inline.
                    let rgb = MetalVideoRenderer.rgb10a2Channels(buf, p)
                    let (cb, cr) = Self.chroma(r: Float(rgb.r),
                                               g: Float(rgb.g),
                                               b: Float(rgb.b))
                    let px = Int(center + cb * s + 0.5)
                    let py = Int(center - cr * s + 0.5)   // Cr up (Y flip)
                    if px >= 0, px < plane, py >= 0, py < plane {
                        accum[py * plane + px] &+= 1
                    }
                }
            }
        }

        // Build the trace image from the plane histogram (shared with the GPU path).
        return buildVectorscopeTraceImage(histogram: accum, plane: plane, gain: gain, color: color)
    }

    /// Turn a plane×plane chroma histogram (layout hist[py*plane + px], Cb horizontal, Cr
    /// up) into the white-on-black scatter CGImage. Shared UNCHANGED by both the CPU and
    /// GPU paths — only the histogram SOURCE differs (CPU bin loop vs vectorscopeKernel).
    /// The image is square (plane×plane), matching the circular display; NO row-downsample
    /// (unlike waveform/parade — the vectorscope isn't a value histogram).
    private func buildVectorscopeTraceImage(histogram accum: [UInt32], plane: Int, gain: Float,
                                            color: (r: Float, g: Float, b: Float)) -> CGImage? {
        guard plane > 0, accum.count >= plane * plane else { return nil }

        // Numeric build (max scan → LUT → RGBA fill) is in ScopeTrace, compiled -O even in
        // Debug so it's fast during development.
        let pixels = ScopeTrace.vectorscopePixels(histogram: accum, plane: plane, gain: gain,
                                                  colorR: color.r, colorG: color.g, colorB: color.b)

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: plane, height: plane,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: plane * 4,
                       space: cs, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Floating square vectorscope panel: trace image + circular graticule with the six
/// derived target boxes. Header "VECTORSCOPE · 709".
struct VectorscopeScopeView: View {
    @ObservedObject var model: VectorscopeScopeModel

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text("VECTORSCOPE · 709")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "sun.max")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.4))
                    Slider(value: Preferences.shared.vectorscopeIntensityBinding,
                           in: Preferences.scopeIntensityRange)
                        .controlSize(.mini)
                        .frame(width: 70)
                    ColorPicker("", selection: Preferences.shared.vectorscopeTraceColorBinding)
                        .labelsHidden()
                        .controlSize(.mini)
                    Button {
                        Preferences.shared.vectorscopeTraceColorHex = Preferences.defaultVectorscopeTraceColorHex
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Reset trace color")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)

                ZStack {
                    Color.black
                    if let img = model.image {
                        Image(decorative: img, scale: 1.0)
                            .resizable()
                            .interpolation(.none)
                    }
                    graticule
                }
                .aspectRatio(1, contentMode: .fit)   // stay square, fit available space
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
            // The plot is the largest square fitting the slot (minus the header), so
            // track the smaller dimension as the square side.
            .onAppear { model.setDisplaySide(min(geo.size.width, geo.size.height)) }
            .onChange(of: min(geo.size.width, geo.size.height)) { _, side in
                model.setDisplaySide(side)
            }
        }
    }

    private var graticule: some View {
        Canvas { ctx, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let frac = CGFloat(VectorscopeScopeModel.chromaScaleFrac)

            // Outer chroma boundary circle (subtle). Sized to enclose the 100% targets.
            let circleR = size.width * 0.46
            let circleRect = CGRect(x: cx - circleR, y: cy - circleR,
                                    width: circleR * 2, height: circleR * 2)
            ctx.stroke(Path(ellipseIn: circleRect), with: .color(.white.opacity(0.14)), lineWidth: 0.5)

            // Faint center crosshair.
            var cross = Path()
            cross.move(to: CGPoint(x: cx - 6, y: cy)); cross.addLine(to: CGPoint(x: cx + 6, y: cy))
            cross.move(to: CGPoint(x: cx, y: cy - 6)); cross.addLine(to: CGPoint(x: cx, y: cy + 6))
            ctx.stroke(cross, with: .color(.white.opacity(0.2)), lineWidth: 0.5)

            // Six target boxes — derived from the SAME chroma transform as the data.
            let box: CGFloat = 9
            for t in VectorscopeScopeModel.targets {
                let (cb, cr) = VectorscopeScopeModel.chroma(r: t.r, g: t.g, b: t.b)
                let bxCenterX = cx + CGFloat(cb) * frac * size.width
                let bxCenterY = cy - CGFloat(cr) * frac * size.height   // Cr up
                let rect = CGRect(x: bxCenterX - box / 2, y: bxCenterY - box / 2,
                                  width: box, height: box)
                ctx.stroke(Path(rect), with: .color(.white.opacity(0.5)), lineWidth: 0.75)
                ctx.draw(
                    Text(t.name).font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55)),
                    at: CGPoint(x: bxCenterX, y: bxCenterY - box), anchor: .center
                )
            }
        }
    }
}
