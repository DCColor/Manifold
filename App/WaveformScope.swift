import SwiftUI
import CoreGraphics
import AppKit

/// Stores/restores a scope trace color as a 6-digit sRGB hex string (no alpha) so it
/// can live in @AppStorage, and converts to RGB floats for the trace compute.
enum ScopeColorCodec {
    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
    static func color(fromHex hex: String) -> Color {
        let (r, g, b) = rgb(fromHex: hex)
        return Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b))
    }
    /// RGB floats 0–1 for the trace compute. Falls back to white on a bad string.
    static func rgb(fromHex hex: String) -> (r: Float, g: Float, b: Float) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return (1, 1, 1) }
        return (Float((v >> 16) & 0xFF) / 255.0,
                Float((v >> 8) & 0xFF) / 255.0,
                Float(v & 0xFF) / 255.0)
    }
}

/// Snap a rendered slot width (points) to the nearest 64 and clamp — used by all
/// scopes to size their internal compute buffer to the slot they actually occupy,
/// so a wider scope computes MORE horizontal detail instead of upscaling a fixed
/// buffer. Snapping avoids reallocating the buffer on every sub-pixel resize:
/// the value only changes when the width crosses a 64-pt boundary.
func scopeBucketWidth(_ width: CGFloat, min lo: Int, max hi: Int) -> Int {
    let snapped = ((Int(Swift.max(0, width)) + 32) / 64) * 64
    return Swift.max(lo, Swift.min(hi, snapped))
}

// MARK: - Trace brightness mapping (shared by all scopes)

// baseGain is the gain at intensity 1.0 — i.e. perScope=global=1.0 reproduces the
// current look. The user-facing intensities multiply this (see each scope's tick).
// gamma/floor stay fixed good constants; only the gain side is user-driven.
let baseGain: Float = 1.6      // dense bins reach full white a bit before the very max
let traceGamma: Float = 1.25   // gentle low-end darkening without eating mid-density structure
let traceFloor: Float = 0.008  // brightness below this clamps to pure black (kills pure haze only)

/// Trace-image pixel height (rows) for the waveform. The GPU 1024-bin histogram is
/// mapped down to this many rows in buildTraceImage; the image is then scaled to fill
/// the panel. Taller = sharper (less upscale of the small image), at a tiny CPU cost on
/// the ~1MB histogram. A/B lever: try 256 / 512 / 1024 — best kept a power-of-2 divisor
/// of the 1024 GPU bins so the group-sum is exact (any value ≤1024 still counts every
/// pixel — see buildTraceImage — but divisors map cleanest).
let waveformDisplayRows = 512

/// Map an accumulated bin count to 0–255 trace brightness with a gain + gamma curve.
/// `gain` is the effective gain (baseGain × perScopeIntensity × globalScopeIntensity).
/// gamma > 1 pushes low counts toward black so sparse areas stay dark and dense areas
/// build to full brightness — a Resolve-style readable trace.
func scopeBrightness(count: UInt32, maxCount: UInt32, gain: Float) -> UInt8 {
    guard count > 0, maxCount > 0 else { return 0 }
    let normalized = Float(count) / Float(maxCount)
    var b = powf(Swift.min(normalized * gain, 1.0), traceGamma)
    if b < traceFloor { b = 0 }
    return UInt8(Swift.min(255.0, b * 255.0))
}

// MARK: - Vertical scale (waveform + parade value axis)

/// Graticule line opacities — scope-prefs: tunable.
let graticuleMajorOpacity: Double = 0.22   // labeled major lines (brighter)
let graticuleMinorOpacity: Double = 0.10   // unlabeled minor ticks (fainter)
// Label legibility — scope-prefs: tunable. Labels read brighter/larger than the
// lines, with a dark backing so they survive over a bright trace.
let graticuleLabelFontSize: CGFloat = 11    // was 8
let graticuleLabelOpacity: Double = 0.6     // was 0.5 — brighter than the 0.22 lines
let graticuleLabelBackingOpacity: Double = 0.45  // dark pill behind each label
// Header strip + plot inset — scope-prefs: tunable. The header strip (name + slider)
// is its own band; the graticule/trace render in the area below it, inset top/bottom
// so the max- and min-value labels stay fully visible and clear of the slider.
let scopeHeaderHeight: CGFloat = 22
let scopePlotInset: CGFloat = 10

/// The user-selectable vertical scale for the value-axis scopes (waveform, parade).
/// PURELY a display remap: the trace data is the same normalized 0–1 buffer; each
/// scale just maps that to its own labels/positions (8-bit 128 and 10-bit 512 land
/// at the same screen position because both are the same normalized 0.5).
enum ScopeScale: String, CaseIterable, Identifiable {
    case bit8, bit10, ire
    // HDR scale — enable when EDR/10-bit path lands (M3b+)
    case pq, hlg

    var id: String { rawValue }

    /// Scales offered in the picker today (PQ/HLG excluded until the HDR path exists).
    static let selectable: [ScopeScale] = [.bit8, .bit10, .ire]

    /// Header tag appended to each scope's title.
    var headerTag: String {
        switch self {
        case .bit8:  return "8-bit"
        // Shared with parade (still CPU/8-bit), so this stays honest for that path. The
        // waveform's GPU path computes a genuine 10-bit histogram and overrides this to
        // plain "10-bit" locally (see WaveformScopeView.headerTag).
        case .bit10: return "10-bit scale (8-bit data)"
        case .ire:   return "IRE"
        case .pq:    return "PQ"
        case .hlg:   return "HLG"
        }
    }

    /// Picker label.
    var label: String {
        switch self {
        case .bit8:  return "8-bit (0–255)"
        case .bit10: return "10-bit (0–1023)"
        case .ire:   return "IRE (0–100)"
        case .pq:    return "PQ"
        case .hlg:   return "HLG"
        }
    }

    /// Top of the scale (range is 0...rangeMax, in the scale's own units).
    var rangeMax: Double {
        switch self {
        case .bit8:  return 255
        case .bit10: return 1023
        case .ire:   return 100
        case .pq, .hlg: return 1023
        }
    }

    /// Major (labeled) line values, in scale units.
    var majors: [Double] {
        switch self {
        case .bit8:  return [0, 32, 64, 96, 128, 160, 192, 224, 255]
        case .bit10: return [0, 128, 256, 384, 512, 640, 768, 896, 1023]
        case .ire:   return [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        case .pq, .hlg: return []
        }
    }

    /// Minor (unlabeled) tick values, in scale units.
    var minors: [Double] {
        switch self {
        case .bit8:  return Array(stride(from: 0.0, through: 255.0, by: 16.0))
        case .bit10: return Array(stride(from: 0.0, through: 1023.0, by: 64.0))
        case .ire:   return Array(stride(from: 0.0, through: 100.0, by: 5.0))
        case .pq, .hlg: return []
        }
    }
}

/// Native luma waveform scope. Pure consumer of MetalVideoRenderer.readbackRenderedFrame()
/// — it samples the PRE-DISPLAY offscreen texture (raw code values), never screen pixels,
/// so it agrees with a Resolve waveform on the same frame. Sampling is throttled here
/// (the renderer's readback stays per-call/full-res for ⌃⌥E export).
final class WaveformScopeModel: ObservableObject {

    /// A/B toggle (Phase 1 GPU-scopes prototype). `true` = compute the histogram on the
    /// GPU (waveformKernel over the offscreen texture, tiny readback); `false` = the
    /// original CPU path (full-frame readback + 8.3M-pixel bin loop). Both paths are kept
    /// side-by-side and feed the SAME trace-build (buildTraceImage) + graticule, so the
    /// output should be pixel-equivalent within luma rounding — flip this to validate.
    /// Debug flag: flip in the debugger or edit here; no UI surface yet.
    static var useGPUWaveform = true

    /// The computed waveform trace image (green-on-black), published to the view.
    @Published var image: CGImage?

    /// Set by the owner when the scope is shown. Weak — the renderer outlives nothing here.
    weak var renderer: MetalVideoRenderer?

    // Scope intensity buffer dimensions. Width = column buckets (tracks the rendered
    // slot width, clamped); height = luma bins (8-bit, value axis — unchanged).
    private var columns = 512
    private let minColumns = 256
    private let maxColumns = 1024
    // Display rows of the trace image (the panel is 256px tall). The CPU path also uses
    // this as its histogram bin count; the GPU path computes at gpuLumaBins precision and
    // maps down to these rows in buildTraceImage.
    private let lumaBins = 256

    /// GPU-path histogram precision: TRUE 10-bit (1024 bins). The offscreen render target
    /// is rgb10a2 — the CPU path quantized luma to 8-bit (256 bins), throwing the low 2
    /// bits away ("10-bit scale (8-bit data)"). The GPU kernel bins the full 10-bit luma,
    /// then buildTraceImage maps 1024 → 256 display rows. Cheap: the histogram grows to
    /// scopeW*1024*4 ≈ 1–4MB, still trivial vs the old 33MB frame readback.
    private let gpuLumaBins = 1024

    /// Track the scope's rendered slot width so the per-column histogram resolution
    /// scales with display width (wider scope -> finer detail, no upscaling smear).
    func setDisplayWidth(_ width: CGFloat) {
        let w = scopeBucketWidth(width, min: minColumns, max: maxColumns)
        if w != columns { columns = w }
    }

    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "com.graviton.manifold.scope.waveform",
                                          qos: .userInitiated)
    private var sampling = false   // gate: skip a tick if the prior compute is still running
    private var readbackTexture: MTLTexture?   // this scope's own readback destination

    /// Perceptual-smoothness cap, NOT a framerate sync — independent of the source
    /// frame rate (a 24 fps and a 60 fps clip both update the scope at this rate).
    /// The overlap gate drops ticks if compute can't keep up; it never slows playback.
    private let updateHz = 24.0

    /// CPU path: process every Nth source row in the luma compute (columns stay full-res).
    /// 1 = every row (most accurate), 2 = default, 4 = cheapest. A waveform is a
    /// per-column luma distribution, so halving rows is visually equivalent at ~half cost.
    /// (Kept at 2 — this is the legacy fallback path; the GPU path runs full-res below.)
    private let rowStride = 2

    /// GPU path: process EVERY row (full-res). Row subsampling was only to match the CPU
    /// path for the A/B comparison — now proven, so the GPU samples every pixel. Full-res
    /// is cheap on the GPU (the kernel is the fast part) and yields a denser, more accurate
    /// trace, especially for thin features (fine text, single-pixel edges).
    private let gpuRowStride = 1

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / updateHz, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        image = nil
    }

    private func tick() {
        // Throttle gate + renderer presence. The gate is touched only on the main
        // thread (set here; cleared in the async completion's main hop below).
        guard !sampling, let renderer else { return }
        sampling = true

        // Snapshot the effective gain on the main thread (Preferences read here):
        // baseGain × this scope's intensity × the global master.
        let gain = baseGain
            * Float(Preferences.shared.waveformIntensity)
            * Float(Preferences.shared.globalScopeIntensity)
        // Trace hue (snapshot on main); brightness stays the intensity's job.
        let color = ScopeColorCodec.rgb(fromHex: Preferences.shared.waveformTraceColorHex)

        if Self.useGPUWaveform {
            // GPU PATH: the histogram is computed by waveformKernel over the GPU-resident
            // offscreen texture; only the small histogram (≤1MB) is read back — no 33MB
            // frame copy, no CPU bin loop. The completion fires on Metal's completion
            // thread; hop to workQueue for the tiny trace-build, then publish on main.
            let scopeW = columns
            // True 10-bit histogram at full source resolution — both cheap on the GPU,
            // both impossible on the CPU path (which quantized to 8-bit + subsampled rows).
            let bins = gpuLumaBins
            let issued = renderer.computeWaveformGPU(scopeW: scopeW, bins: bins, rowStride: gpuRowStride) { [weak self] hist, sw, b in
                guard let self else { return }
                self.workQueue.async {
                    let img = self.buildTraceImage(histogram: hist, scopeW: sw, bins: b, gain: gain, color: color)
                    DispatchQueue.main.async {
                        if let img { self.image = img }
                        self.sampling = false
                    }
                }
            }
            if !issued { sampling = false }
            return
        }

        // CPU PATH (original). NON-BLOCKING readback: issue the GPU->CPU copy and return
        // immediately. The completion fires off the render thread once the GPU is done; we
        // then compute on workQueue and publish on main. This avoids the waitUntilCompleted
        // stall that landed the scope 2-3 presented frames late.
        let issued = renderer.readbackRenderedFrameAsync(into: &readbackTexture) { [weak self] bytes, w, h, bpr in
            // Called on Metal's completion thread (background). Hop to workQueue for
            // the heavy luma compute, then publish + clear the gate on main.
            guard let self else { return }
            self.workQueue.async {
                let img = self.computeWaveform(bytes: bytes, width: w, height: h, bytesPerRow: bpr, gain: gain, color: color)
                DispatchQueue.main.async {
                    if let img { self.image = img }
                    self.sampling = false   // gate held from issue until compute published
                }
            }
        }
        // If no readback was issued (no frame yet / setup failed), the completion
        // will never fire — release the gate so the next tick can try again.
        if !issued { sampling = false }
    }

    /// Build the luma waveform as a green-on-black RGBA CGImage.
    /// BGRA byte order (bytes B,G,R,A); row stride uses bytesPerRow, not width*4.
    private func computeWaveform(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int, gain: Float, color: (r: Float, g: Float, b: Float)) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let scopeW = columns
        let bins = lumaBins

        // 2D histogram: [bin * scopeW + bucket] = pixel count.
        var accum = [UInt32](repeating: 0, count: scopeW * bins)

        bytes.withUnsafeBufferPointer { buf in
            // Row-subsampled (every rowStride-th row); columns stay full-res so
            // ramps/edges remain crisp.
            for y in stride(from: 0, to: height, by: rowStride) {
                let rowBase = y * bytesPerRow
                for x in 0..<width {
                    let p = rowBase + x * 4
                    // Readback is rgb10a2 (M3b 10-bit target); unpack to 8-bit inline.
                    let px = MetalVideoRenderer.rgb10a2Channels(buf, p)
                    let b = Float(px.b)
                    let g = Float(px.g)
                    let r = Float(px.r)
                    // Rec.709 luma on display-RGB 0-255 values.
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let lv = min(255, max(0, Int(luma + 0.5)))
                    let bucket = (x * scopeW) / width          // source column -> scope bucket
                    let row = (bins - 1) - lv                  // luma 255 at top
                    accum[row * scopeW + bucket] &+= 1
                }
            }
        }

        // Build the trace image from the accumulated histogram (shared with the GPU path).
        return buildTraceImage(histogram: accum, scopeW: scopeW, bins: bins, gain: gain, color: color)
    }

    /// Turn a luma histogram (layout [row*scopeW + bucket], row = luma-max at top) into
    /// the green-on-black trace CGImage. Shared UNCHANGED by both the CPU and GPU paths —
    /// only the histogram's SOURCE differs (CPU bin loop vs waveformKernel). This is the
    /// small CPU pass (operates on the ~1MB histogram, not the frame).
    /// BGRA-agnostic RGBA output; row stride = scopeW*4.
    private func buildTraceImage(histogram accum: [UInt32], scopeW: Int, bins: Int, gain: Float, color: (r: Float, g: Float, b: Float)) -> CGImage? {
        guard scopeW > 0, bins > 0, accum.count >= scopeW * bins else { return nil }
        // Trace-image height. Never more than the source bins (no invented rows): the GPU
        // path (1024 bins) uses waveformDisplayRows; the CPU fallback (256 bins) caps at 256.
        let displayRows = min(bins, max(1, waveformDisplayRows))

        // Map the source histogram (bins rows, luma-max at row 0) down to displayRows by
        // SUMMING source rows into display rows. Each source row srow is assigned to display
        // row srow*displayRows/bins — so EVERY sampled pixel is counted (no dropped rows) for
        // ANY displayRows ≤ bins, and a power-of-2 divisor (256/512/1024) yields exact equal
        // groups. Row 0 stays luma-max at the top. maxCount is scanned on the SUMMED display
        // histogram below, so the gain/gamma curve maps onto the same displayed-count scale.
        let display: [UInt32]
        if displayRows == bins {
            display = accum
        } else {
            var d = [UInt32](repeating: 0, count: scopeW * displayRows)
            for srow in 0..<bins {
                let drow = (srow * displayRows) / bins
                let dBase = drow * scopeW
                let sBase = srow * scopeW
                for x in 0..<scopeW {
                    d[dBase + x] &+= accum[sBase + x]
                }
            }
            display = d
        }

        // Per-frame max for normalization (brightness adapts to content per frame).
        var maxCount: UInt32 = 1
        for c in display where c > maxCount { maxCount = c }

        var pixels = [UInt8](repeating: 0, count: scopeW * displayRows * 4)
        for i in 0..<(scopeW * displayRows) {
            let v = scopeBrightness(count: display[i], maxCount: maxCount, gain: gain)
            // final pixel = traceColor × computedIntensity (hue from picker, brightness
            // from the curve — orthogonal). Default green reproduces the old (0,v,0).
            let fv = Float(v)
            let o = i * 4
            pixels[o + 0] = UInt8(fv * color.r)
            pixels[o + 1] = UInt8(fv * color.g)
            pixels[o + 2] = UInt8(fv * color.b)
            pixels[o + 3] = 255
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: scopeW, height: displayRows,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: scopeW * 4,
                       space: cs, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Floating waveform panel. Fixed size for v1. Shows the trace image plus a subtle
/// 8-bit code-level graticule.
struct WaveformScopeView: View {
    @ObservedObject var model: WaveformScopeModel
    // Same key as Preferences.scopeScale — @AppStorage here for live graticule updates.
    @AppStorage("scopeScale") private var scopeScale: ScopeScale = .bit10

    /// Header scale tag. The GPU path computes a real 10-bit histogram from the rgb10a2
    /// offscreen, so on the 10-bit scale it reads plain "10-bit" — the old "(8-bit data)"
    /// caveat was only true for the CPU fallback (which still shows it). Other scales
    /// (8-bit / IRE) are display remaps and keep the shared enum tag unchanged.
    private var headerTag: String {
        if WaveformScopeModel.useGPUWaveform, scopeScale == .bit10 { return "10-bit" }
        return scopeScale.headerTag
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Header strip: name (left) + intensity slider (right). Own band.
                HStack(spacing: 4) {
                    Text("WAVEFORM · luma (\(headerTag))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "sun.max")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.4))
                    Slider(value: Preferences.shared.waveformIntensityBinding,
                           in: Preferences.scopeIntensityRange)
                        .controlSize(.mini)
                        .frame(width: 70)
                    ColorPicker("", selection: Preferences.shared.waveformTraceColorBinding)
                        .labelsHidden()
                        .controlSize(.mini)
                    Button {
                        Preferences.shared.waveformTraceColorHex = Preferences.defaultWaveformTraceColorHex
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Reset trace color")
                }
                .padding(.horizontal, 6)
                .frame(height: scopeHeaderHeight)

                // Scope area below the header: trace + graticule, vertically inset so
                // the top (max) and bottom (0) labels stay fully visible.
                ZStack {
                    Color.black
                    if let img = model.image {
                        // .none (nearest-neighbor): keeps the thin bright trace crisp
                        // against black. A smoothing filter (.low/.high) would blur the
                        // trace into the background and read softer — the wrong direction
                        // for a scope. Softness came from upscaling the small 256-row
                        // image; the fix is the taller source (waveformDisplayRows), not
                        // smoothing here. Sharpness lever if ever wanted: swap to .low.
                        Image(decorative: img, scale: 1.0)
                            .resizable()
                            .interpolation(.none)
                            .padding(.vertical, scopePlotInset)
                    }
                    graticule
                        .padding(.vertical, scopePlotInset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
            .onAppear { model.setDisplayWidth(geo.size.width) }
            .onChange(of: geo.size.width) { _, w in model.setDisplayWidth(w) }
        }
    }

    private var graticule: some View {
        Canvas { ctx, size in
            drawValueGraticule(ctx, size: size, scale: scopeScale)
        }
    }
}

/// Two-tier value-axis graticule shared by waveform + parade: full-width labeled
/// MAJOR lines (brighter) + short unlabeled MINOR edge ticks (fainter). Positions
/// come from the selected scale, mapped value/rangeMax -> normalized height.
func drawValueGraticule(_ ctx: GraphicsContext, size: CGSize, scale: ScopeScale) {
    let maxV = scale.rangeMax
    guard maxV > 0 else { return }

    // Minor ticks: short marks at both edges (reduces clutter vs full-width lines).
    for v in scale.minors {
        let y = size.height * (1.0 - v / maxV)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: 6, y: y))
        p.move(to: CGPoint(x: size.width - 6, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(p, with: .color(.white.opacity(graticuleMinorOpacity)), lineWidth: 0.5)
    }

    // Major lines: full width + value label (larger, brighter, on a dark backing
    // so it stays legible over a bright trace).
    for v in scale.majors {
        let y = size.height * (1.0 - v / maxV)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(p, with: .color(.white.opacity(graticuleMajorOpacity)), lineWidth: 0.5)

        // Plain integer, NO thousands separator: Text(verbatim:) avoids SwiftUI's
        // LocalizedStringKey Int interpolation, which would render "1,023".
        let resolved = ctx.resolve(
            Text(verbatim: String(Int(v)))
                .font(.system(size: graticuleLabelFontSize, design: .monospaced))
                .foregroundColor(.white.opacity(graticuleLabelOpacity))
        )
        let ts = resolved.measure(in: CGSize(width: 200, height: 100))
        // Clamp the label's vertical center so its full text box stays inside the
        // plot area: the top (max) label nudges down, the bottom (0) label nudges
        // up, interior labels stay centered on their line. Never clips, any font/inset.
        let halfH = ts.height / 2
        let ly = Swift.min(Swift.max(y, halfH), size.height - halfH)
        let cx = size.width - 4
        let bg = CGRect(x: cx - ts.width - 3, y: ly - halfH - 1,
                        width: ts.width + 6, height: ts.height + 2)
        ctx.fill(Path(roundedRect: bg, cornerRadius: 3),
                 with: .color(.black.opacity(graticuleLabelBackingOpacity)))
        ctx.draw(resolved, at: CGPoint(x: cx, y: ly), anchor: .trailing)
    }
}
