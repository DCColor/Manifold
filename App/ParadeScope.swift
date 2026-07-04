import SwiftUI
import CoreGraphics
import Metal
import Combine
import ManifoldCore   // ScopeTrace — the -O-compiled trace-build (fast in Debug too)

/// Trace-image pixel height (rows) for the parade — matches the waveform's sharpness fix.
/// The GPU 1024-bin per-channel histograms map down to this many rows in
/// buildParadeTraceImage; a power-of-2 divisor of 1024 (256/512/1024) maps cleanest.
let paradeDisplayRows = 512

/// Native RGB parade scope: three side-by-side waveform columns (R | G | B), each plotting
/// one channel's per-column value distribution. Samples the GPU-resident PRE-DISPLAY offscreen
/// texture: paradeKernel bins the three 10-bit per-channel histograms on the GPU, only the tiny
/// histogram is read back, and ScopeTrace composites the R|G|B image. Render-coupled sampling.
final class ParadeScopeModel: ObservableObject {

    /// The composited three-column parade image (R|G|B), published to the view.
    @Published var image: CGImage?

    weak var renderer: MetalVideoRenderer?

    // Each channel column is columnWidth px; the full image is 3 columns wide.
    // columnWidth tracks the per-channel slot width (slot/3), clamped.
    private var columnWidth = 192
    private let minColumnWidth = 128
    private let maxColumnWidth = 512

    /// Per-channel histogram precision: TRUE 10-bit (1024 bins), like the waveform. Mapped
    /// down to paradeDisplayRows in buildParadeTraceImage.
    private let gpuBins = 1024

    /// Track the scope's rendered slot width; each of the three channel sub-columns
    /// gets a third of it, so the parade resolution scales with display width.
    func setDisplayWidth(_ width: CGFloat) {
        let w = scopeBucketWidth(width / 3.0, min: minColumnWidth, max: maxColumnWidth)
        if w != columnWidth { columnWidth = w }
    }

    // Render-coupled sampling state (main-only) — see WaveformScopeModel for the rationale.
    private var active = false
    private var sampling = false
    private var pendingSample = false
    /// Live pref-coupling (paused re-sample on a scope-pref change) — see WaveformScopeModel.
    private var prefsObserver: AnyCancellable?

    /// Process EVERY row (full-res) — cheap on the GPU, like the waveform.
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
        // Effective gain (Preferences read on main): baseGain × parade × global master.
        let gain = baseGain
            * Float(Preferences.shared.paradeIntensity)
            * Float(Preferences.shared.globalScopeIntensity)
        // Snapshot the two-state mode on main: default RGB, or monochrome in one hue.
        let mono = Preferences.shared.paradeMonochrome
        let monoColor = ScopeColorCodec.rgb(fromHex: Preferences.shared.paradeMonoColorHex)

        // paradeKernel bins the 3 per-channel histograms over the GPU-resident offscreen; only
        // the small histogram (≤12MB) is read back — no full-frame copy. The trace-build runs
        // right here on the GPU completion thread (a fast -O ScopeTrace call), then publishes.
        let colW = columnWidth
        let bins = gpuBins   // true 10-bit per-channel, full source resolution
        let issued = renderer.computeParadeGPU(colW: colW, bins: bins, rowStride: gpuRowStride) { [weak self] hist, cw, b in
            guard let self else { return }
            let n = cw * b
            let r = Array(hist[0..<n])
            let g = Array(hist[n..<(2 * n)])
            let bl = Array(hist[(2 * n)..<(3 * n)])
            let img = self.buildParadeTraceImage(r: r, g: g, b: bl, colW: cw, bins: b,
                                                 gain: gain, mono: mono, monoColor: monoColor)
            DispatchQueue.main.async {
                if self.active, let img { self.image = img }
                self.finishSample()
            }
        }
        if !issued { sampling = false }
    }

    /// Composite three per-channel value histograms (each colW*bins, layout
    /// [row*colW + bucket], row = value-max at top) into the R|G|B parade CGImage.
    private func buildParadeTraceImage(r accR: [UInt32], g accG: [UInt32], b accB: [UInt32],
                                       colW: Int, bins: Int, gain: Float,
                                       mono: Bool, monoColor: (r: Float, g: Float, b: Float)) -> CGImage? {
        let n = colW * bins
        guard colW > 0, bins > 0, accR.count >= n, accG.count >= n, accB.count >= n else { return nil }
        // Trace-image height; never more than the source bins (CPU 256 caps at 256, GPU
        // 1024 maps to paradeDisplayRows). Same mapping as the waveform's trace-build.
        let displayRows = min(bins, max(1, paradeDisplayRows))
        let totalW = colW * 3

        // Numeric build (downsample × 3, shared max, LUT, R|G|B composite) is in ScopeTrace,
        // compiled -O even in Debug so it's fast during development.
        let pixels = ScopeTrace.paradePixels(r: accR, g: accG, b: accB, colW: colW, bins: bins,
                                             displayRows: displayRows, gain: gain, mono: mono,
                                             monoR: monoColor.r, monoG: monoColor.g, monoB: monoColor.b)

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
