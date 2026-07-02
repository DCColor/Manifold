import SwiftUI
import CoreGraphics
import Metal

/// Trace-image pixel height (rows) for the parade — matches the waveform's sharpness fix.
/// The GPU 1024-bin per-channel histograms map down to this many rows in
/// buildParadeTraceImage; a power-of-2 divisor of 1024 (256/512/1024) maps cleanest.
let paradeDisplayRows = 512

/// Native RGB parade scope: three side-by-side waveform columns (R | G | B), each
/// plotting one channel's per-column value distribution. Pure consumer of
/// MetalVideoRenderer.readbackRenderedFrameAsync (the same non-blocking readback the
/// luma waveform uses) — it samples the PRE-DISPLAY offscreen texture (raw code
/// values), never screen pixels. Independent of the luma waveform: own gate, own
/// readback texture, so both can run at once without colliding.
final class ParadeScopeModel: ObservableObject {

    /// A/B toggle (Phase 2 GPU-scopes). `true` = compute the 3 per-channel histograms on
    /// the GPU (paradeKernel over the offscreen, tiny readback); `false` = the original CPU
    /// path (full-frame readback + 8.3M-pixel bin loop). Both feed the SAME trace-build
    /// (buildParadeTraceImage) + graticule — output pixel-equivalent within luma rounding.
    /// Mirrors WaveformScopeModel.useGPUWaveform. Debug flag; no UI surface yet.
    static var useGPUParade = true

    /// The composited three-column parade image (R|G|B), published to the view.
    @Published var image: CGImage?

    weak var renderer: MetalVideoRenderer?

    // Each channel column is columnWidth px; the full image is 3 columns wide.
    // columnWidth tracks the per-channel slot width (slot/3), clamped.
    private var columnWidth = 192
    private let minColumnWidth = 128
    private let maxColumnWidth = 512
    private let bins = 256   // CPU path: 8-bit channel value bins (value axis)

    /// GPU-path per-channel histogram precision: TRUE 10-bit (1024 bins), like the
    /// waveform. Mapped down to paradeDisplayRows in buildParadeTraceImage.
    private let gpuBins = 1024

    /// Track the scope's rendered slot width; each of the three channel sub-columns
    /// gets a third of it, so the parade resolution scales with display width.
    func setDisplayWidth(_ width: CGFloat) {
        let w = scopeBucketWidth(width / 3.0, min: minColumnWidth, max: maxColumnWidth)
        if w != columnWidth { columnWidth = w }
    }

    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "com.graviton.manifold.scope.parade",
                                          qos: .userInitiated)
    private var sampling = false                 // per-scope overlap gate
    private var readbackTexture: MTLTexture?     // this scope's own readback destination

    /// Perceptual-smoothness cap — independent of source frame rate (same as waveform).
    private let updateHz = 24.0

    /// CPU path: process every Nth source row (columns stay full-res). Legacy fallback.
    private let rowStride = 2

    /// GPU path: process EVERY row (full-res) — cheap on the GPU, like the waveform.
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
        guard !sampling, let renderer else { return }
        sampling = true
        // Effective gain (Preferences read on main): baseGain × parade × global master.
        let gain = baseGain
            * Float(Preferences.shared.paradeIntensity)
            * Float(Preferences.shared.globalScopeIntensity)
        // Snapshot the two-state mode on main: default RGB, or monochrome in one hue.
        let mono = Preferences.shared.paradeMonochrome
        let monoColor = ScopeColorCodec.rgb(fromHex: Preferences.shared.paradeMonoColorHex)

        if Self.useGPUParade {
            // GPU PATH: the 3 per-channel histograms are computed by paradeKernel over the
            // offscreen; only the small histogram (≤12MB) is read back — no 33MB frame
            // copy, no CPU bin loop. The completion fires on Metal's completion thread; hop
            // to workQueue to slice R/G/B + build the trace, then publish on main.
            let colW = columnWidth
            let bins = gpuBins
            let issued = renderer.computeParadeGPU(colW: colW, bins: bins, rowStride: gpuRowStride) { [weak self] hist, cw, b in
                guard let self else { return }
                self.workQueue.async {
                    let n = cw * b
                    let r = Array(hist[0..<n])
                    let g = Array(hist[n..<(2 * n)])
                    let bl = Array(hist[(2 * n)..<(3 * n)])
                    let img = self.buildParadeTraceImage(r: r, g: g, b: bl, colW: cw, bins: b,
                                                         gain: gain, mono: mono, monoColor: monoColor)
                    DispatchQueue.main.async {
                        if let img { self.image = img }
                        self.sampling = false
                    }
                }
            }
            if !issued { sampling = false }
            return
        }

        // CPU PATH (original). NON-BLOCKING readback into this scope's OWN texture
        // (independent of the waveform's). Compute on workQueue, publish on main.
        let issued = renderer.readbackRenderedFrameAsync(into: &readbackTexture) { [weak self] bytes, w, h, bpr in
            guard let self else { return }
            self.workQueue.async {
                let img = self.computeParade(bytes: bytes, width: w, height: h, bytesPerRow: bpr,
                                             gain: gain, mono: mono, monoColor: monoColor)
                DispatchQueue.main.async {
                    if let img { self.image = img }
                    self.sampling = false
                }
            }
        }
        if !issued { sampling = false }
    }

    /// Build the three-column RGB parade as one composited green/red/blue-tinted
    /// RGBA image. Per-channel histograms (NO luma weighting); BGRA byte order;
    /// row stride subsampling; log normalization with a SHARED max across channels
    /// so inter-channel trace density stays comparable.
    private func computeParade(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int,
                               gain: Float, mono: Bool, monoColor: (r: Float, g: Float, b: Float)) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let colW = columnWidth
        let bins = self.bins

        var accR = [UInt32](repeating: 0, count: colW * bins)
        var accG = [UInt32](repeating: 0, count: colW * bins)
        var accB = [UInt32](repeating: 0, count: colW * bins)

        bytes.withUnsafeBufferPointer { buf in
            for y in stride(from: 0, to: height, by: rowStride) {
                let rowBase = y * bytesPerRow
                for x in 0..<width {
                    let p = rowBase + x * 4
                    // Readback is rgb10a2 (M3b 10-bit target); unpack to 8-bit inline.
                    let px = MetalVideoRenderer.rgb10a2Channels(buf, p)
                    let b = Int(px.b)
                    let g = Int(px.g)
                    let r = Int(px.r)
                    let bucket = (x * colW) / width
                    accR[((bins - 1) - r) * colW + bucket] &+= 1
                    accG[((bins - 1) - g) * colW + bucket] &+= 1
                    accB[((bins - 1) - b) * colW + bucket] &+= 1
                }
            }
        }

        // Build the composited image from the three histograms (shared with the GPU path).
        return buildParadeTraceImage(r: accR, g: accG, b: accB, colW: colW, bins: bins,
                                     gain: gain, mono: mono, monoColor: monoColor)
    }

    /// Composite three per-channel value histograms (each colW*bins, layout
    /// [row*colW + bucket], row = value-max at top) into the R|G|B parade CGImage. Shared
    /// UNCHANGED by both the CPU and GPU paths — only the histogram SOURCE differs (CPU bin
    /// loop vs paradeKernel). Small CPU pass over the ~few-MB histograms, not the frame.
    private func buildParadeTraceImage(r accR: [UInt32], g accG: [UInt32], b accB: [UInt32],
                                       colW: Int, bins: Int, gain: Float,
                                       mono: Bool, monoColor: (r: Float, g: Float, b: Float)) -> CGImage? {
        let n = colW * bins
        guard colW > 0, bins > 0, accR.count >= n, accG.count >= n, accB.count >= n else { return nil }
        // Trace-image height; never more than the source bins (CPU 256 caps at 256, GPU
        // 1024 maps to paradeDisplayRows). Same mapping as the waveform's buildTraceImage.
        let displayRows = min(bins, max(1, paradeDisplayRows))

        // Map a source channel histogram (bins rows) down to displayRows by summing source
        // row srow into display row srow*displayRows/bins — no dropped rows, value-max stays
        // at the top. groupSize 1 (256->256) is the CPU no-op; groups of 2 (1024->512) GPU.
        func mapDown(_ acc: [UInt32]) -> [UInt32] {
            if displayRows == bins { return acc }
            var d = [UInt32](repeating: 0, count: colW * displayRows)
            for srow in 0..<bins {
                let drow = (srow * displayRows) / bins
                let dBase = drow * colW
                let sBase = srow * colW
                for x in 0..<colW { d[dBase + x] &+= acc[sBase + x] }
            }
            return d
        }
        let dR = mapDown(accR), dG = mapDown(accG), dB = mapDown(accB)

        // Shared max across all three DISPLAY histograms -> comparable inter-channel scaling.
        var maxCount: UInt32 = 1
        for c in dR where c > maxCount { maxCount = c }
        for c in dG where c > maxCount { maxCount = c }
        for c in dB where c > maxCount { maxCount = c }
        func intensity(_ c: UInt32) -> UInt8 {
            scopeBrightness(count: c, maxCount: maxCount, gain: gain)
        }

        // Composite: column 0 = R (red trace), 1 = G (green), 2 = B (blue).
        let totalW = colW * 3
        var pixels = [UInt8](repeating: 0, count: totalW * displayRows * 4)
        for row in 0..<displayRows {
            let rowOut = row * totalW
            for bx in 0..<colW {
                let vR = intensity(dR[row * colW + bx])
                let vG = intensity(dG[row * colW + bx])
                let vB = intensity(dB[row * colW + bx])
                let oR = (rowOut + (0 * colW + bx)) * 4   // R channel column (left)
                let oG = (rowOut + (1 * colW + bx)) * 4   // G channel column (mid)
                let oB = (rowOut + (2 * colW + bx)) * 4   // B channel column (right)

                if mono {
                    // All three columns in ONE hue; brightness still per-channel.
                    let fR = Float(vR), fG = Float(vG), fB = Float(vB)
                    pixels[oR + 0] = UInt8(fR * monoColor.r); pixels[oR + 1] = UInt8(fR * monoColor.g); pixels[oR + 2] = UInt8(fR * monoColor.b); pixels[oR + 3] = 255
                    pixels[oG + 0] = UInt8(fG * monoColor.r); pixels[oG + 1] = UInt8(fG * monoColor.g); pixels[oG + 2] = UInt8(fG * monoColor.b); pixels[oG + 3] = 255
                    pixels[oB + 0] = UInt8(fB * monoColor.r); pixels[oB + 1] = UInt8(fB * monoColor.g); pixels[oB + 2] = UInt8(fB * monoColor.b); pixels[oB + 3] = 255
                } else {
                    // Default: red / green / blue columns (unchanged).
                    pixels[oR + 0] = vR; pixels[oR + 1] = 0; pixels[oR + 2] = 0; pixels[oR + 3] = 255
                    pixels[oG + 0] = 0; pixels[oG + 1] = vG; pixels[oG + 2] = 0; pixels[oG + 3] = 255
                    pixels[oB + 0] = 0; pixels[oB + 1] = 0; pixels[oB + 2] = vB; pixels[oB + 3] = 255
                }
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: totalW, height: displayRows,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: totalW * 4,
                       space: cs, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Floating RGB parade panel. Wider than tall to give three columns room. Shows the
/// composited trace plus a subtle 8-bit code-level graticule and R|G|B separators.
struct ParadeScopeView: View {
    @ObservedObject var model: ParadeScopeModel
    // Same key as Preferences.scopeScale — @AppStorage here for live graticule updates.
    @AppStorage("scopeScale") private var scopeScale: ScopeScale = .bit10

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Header strip: name (left) + intensity slider (right). Own band.
                HStack(spacing: 4) {
                    Text("PARADE · RGB (\(scopeScale.headerTag))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "sun.max")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.4))
                    Slider(value: Preferences.shared.paradeIntensityBinding,
                           in: Preferences.scopeIntensityRange)
                        .controlSize(.mini)
                        .frame(width: 70)
                    // Pick a color -> monochrome in that color.
                    ColorPicker("", selection: Preferences.shared.paradeMonoColorBinding)
                        .labelsHidden()
                        .controlSize(.mini)
                    // Reset -> standard RGB columns.
                    Button { Preferences.shared.paradeMonochrome = false } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Reset parade to RGB")
                }
                .padding(.horizontal, 6)
                .frame(height: scopeHeaderHeight)

                // Scope area below the header: trace + graticule, vertically inset.
                ZStack {
                    Color.black
                    if let img = model.image {
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
            // Two-tier value-axis graticule (same as waveform), spanning all 3 columns.
            drawValueGraticule(ctx, size: size, scale: scopeScale)
            // Thin R|G|B column separators at 1/3 and 2/3.
            for frac in [1.0 / 3.0, 2.0 / 3.0] {
                let x = size.width * frac
                var sep = Path()
                sep.move(to: CGPoint(x: x, y: 0))
                sep.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(sep, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
            }
        }
    }
}
