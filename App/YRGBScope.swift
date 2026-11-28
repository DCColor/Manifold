import SwiftUI
import CoreGraphics
import Metal
import Combine
import ManifoldCore   // ScopeTrace — the -O-compiled trace-build (fast in Debug too)

/// The YRGB parade's Y trace color: a neutral gray-white, so Y does not read as a fourth color channel (Robbie,
/// 2026-11-16). R, G and B are pure red, green and blue, as in the RGB parade. With the RGB Parade's monochrome setting
/// on, all four columns take its mono color instead (Robbie, 2026-11-16: YRGB follows that setting).
let yrgbLumaTraceHex = "E6E6E6"

/// YRGB parade (0.9.5, docs/SCOPES_095_PLAN.md part 1): four side-by-side columns, Y | R | G | B. A scope of its own:
/// the Waveform and the RGB Parade are unchanged.
///
/// ⚠️ Y IS THE Y WAVEFORM'S Y, AND R, G, B ARE THE RGB PARADE'S, BY CONSTRUCTION RATHER THAN BY COPY.
/// - The histograms come from the waveform's and the parade's own kernels, at the same column width, through
///   `MetalVideoRenderer.computeYRGBGPU`: same pipelines, same `scopeCodes.matrix`, same binning.
/// - The image comes from `ScopeTrace.yrgbPixels`, which calls `waveformPixels` and `paradePixels`. Y keeps its own
///   normalization; R, G and B share theirs.
/// - Its histogram buffers are its own, never the waveform's or the parade's: each model gates only its own compute.
/// - It re-samples on the picture matrix exactly as the waveform does (`sampleInputs`). Its header fields are written
///   only by `ScopeColorFeed` (CLAUDE.md).
///
/// At equal columns the Y column is byte-equal to the waveform and R, G, B to the parade (ScopeComputeTests). In a tray
/// the Y column has about a quarter of a waveform slot's columns: the same measurement at a coarser horizontal step.
final class YRGBScopeModel: ObservableObject {

    /// The composited four-column image (Y|R|G|B). Kept in `trace`, NOT `@Published` here, so a new image re-renders
    /// only the `ScopeTraceLayer` that draws it, not this scope's header and controls (see `ScopeTraceImage`).
    let trace = ScopeTraceImage()
    var image: CGImage? {
        get { trace.image }
        set { trace.image = newValue }
    }

    weak var renderer: MetalVideoRenderer?

    /// Picture YCbCr matrix code (CICP), for the header label ONLY — the Y MATH reads the same code off the renderer
    /// (`computeYRGBGPU`, as `computeWaveformGPU` does). Written ONLY by `ScopeColorFeed`. nil/2/unknown → 709.
    @Published var sourceMatrixCode: Int?
    /// Transfer code (CICP) for the AUTO ruler (16 = PQ, 18 = HLG, else SDR). Written ONLY by `ScopeColorFeed`.
    @Published var sourceTransferCode: Int?
    /// A still's caveat for the header, or nil. Written only by `ScopeColorFeed`.
    @Published var headerNote: String?

    // Each column (Y, R, G, B) is columnWidth px; the image is 4 columns wide. Tracks slot/4, clamped: at the
    // minimum, 4 × 128 = 512 columns in all.
    private var columnWidth = 128
    private let minColumnWidth = 128
    private let maxColumnWidth = 512

    /// TRUE 10-bit (1024 bins) per column, like the waveform and the parade; mapped down to `paradeDisplayRows`.
    private let gpuBins = 1024

    func setDisplayWidth(_ width: CGFloat) {
        let w = scopeBucketWidth(width / 4.0, min: minColumnWidth, max: maxColumnWidth)
        if w != columnWidth { columnWidth = w }
    }

    // Render-coupled sampling state (main-only) — see WaveformScopeModel for the rationale.
    private var active = false
    private var sampling = false
    private var pendingSample = false
    /// One-shot publish suppressor, as in the other scopes: set by `clear()`, reset by a new sample cycle.
    private var cleared = false
    private var prefsObserver: AnyCancellable?
    /// What a sample is built from apart from the frame. INCLUDES THE PICTURE MATRIX, as the waveform's does
    /// (`WaveformScopeModel.sampleInputs`): Y is weighted by it. The parade's leaves it out because its kernel takes
    /// none, so it is the wrong template here (docs/SCOPES_095_PLAN.md §1.2).
    private var sampleInputs: [AnyHashable] {
        [Preferences.shared.yrgbIntensity, Preferences.shared.globalScopeIntensity, columnWidth,
         renderer?.pictureMatrixCode, Preferences.shared.paradeMonochrome, Preferences.shared.paradeMonoColorHex]
    }
    private var sampledWith: [AnyHashable]?

    /// Process EVERY row (full-res), like the waveform and the parade.
    private let gpuRowStride = 1

    func start() {
        active = true
        if prefsObserver == nil {
            prefsObserver = NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.defaultsChanged() }
        }
        requestSample()
    }

    private func defaultsChanged() {
        guard image == nil || sampleInputs != sampledWith else { return }
        requestSample()
    }

    func stop() {
        active = false
        pendingSample = false
        prefsObserver?.cancel()
        prefsObserver = nil
        image = nil
    }

    /// Blank the trace on a source teardown without deactivating — `ParadeScopeModel.clear()`'s contract.
    func clear() {
        pendingSample = false
        cleared = true
        image = nil
    }

    /// Render-coupled trigger (render thread) — hops to main.
    func frameRendered() {
        DispatchQueue.main.async { [weak self] in self?.requestSample() }
    }

    private func requestSample() {
        guard active, renderer != nil else { return }
        if sampling { pendingSample = true; return }
        startSample()
    }

    private func finishSample() {
        sampling = false
        if pendingSample { startSample() }
    }

    private func startSample() {
        guard let renderer else { return }
        sampling = true
        pendingSample = false
        cleared = false
        // Effective gain (Preferences read on main): baseGain × this scope's intensity × the global master. One gain for
        // all four columns; Y's brightness is still its own because it is normalized on its own (`yrgbPixels`).
        let gain = baseGain
            * Float(Preferences.shared.yrgbIntensity)
            * Float(Preferences.shared.globalScopeIntensity)
        let yColor = ScopeColorCodec.rgb(fromHex: yrgbLumaTraceHex)
        // The RGB Parade's monochrome setting, read here as the parade reads it (Robbie, 2026-11-16): one preference
        // drives both scopes. Mono paints all four columns in the parade's mono color (`yrgbPixels`).
        let mono = Preferences.shared.paradeMonochrome
        let monoColor = ScopeColorCodec.rgb(fromHex: Preferences.shared.paradeMonoColorHex)

        let colW = columnWidth
        let bins = gpuBins
        let issued = renderer.computeYRGBGPU(colW: colW, bins: bins, rowStride: gpuRowStride) { [weak self] y, rgb, cw, b in
            guard let self else { return }
            let n = cw * b
            guard y.count >= n, rgb.count >= 3 * n else {
                DispatchQueue.main.async { self.finishSample() }
                return
            }
            let img = Self.buildTraceImage(y: y, r: Array(rgb[0..<n]), g: Array(rgb[n..<(2 * n)]),
                                           b: Array(rgb[(2 * n)..<(3 * n)]), colW: cw, bins: b, gain: gain,
                                           yColor: yColor, mono: mono, monoColor: monoColor)
            DispatchQueue.main.async {
                if self.active, !self.cleared, let img { self.image = img }
                #if DEBUG
                if self.active, !self.cleared, let img { ScopePerf.published("yrgb", img) }
                #endif
                self.finishSample()
            }
        }
        if !issued { sampling = false } else { sampledWith = sampleInputs }
        #if DEBUG
        if issued { ScopePerf.count("compute.yrgb") }
        #endif
    }

    /// The Y|R|G|B CGImage, `4·colW × paradeDisplayRows`, premultiplied like every scope trace.
    private static func buildTraceImage(y: [UInt32], r: [UInt32], g: [UInt32], b: [UInt32], colW: Int, bins: Int,
                                        gain: Float, yColor: (r: Float, g: Float, b: Float),
                                        mono: Bool, monoColor: (r: Float, g: Float, b: Float)) -> CGImage? {
        guard colW > 0, bins > 0 else { return nil }
        let displayRows = min(bins, max(1, paradeDisplayRows))
        let totalW = colW * 4
        let pixels = ScopeTrace.yrgbPixels(y: y, r: r, g: g, b: b, colW: colW, bins: bins, displayRows: displayRows,
                                           gain: gain, yColorR: yColor.r, yColorG: yColor.g, yColorB: yColor.b,
                                           mono: mono, monoR: monoColor.r, monoG: monoColor.g, monoB: monoColor.b)
        guard pixels.count == totalW * displayRows * 4 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: totalW, height: displayRows,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: totalW * 4,
                       space: cs, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The YRGB parade panel: the RGB parade's layout with a fourth column, Y, on the left. Same value-axis graticule, same
/// layering (structure under the trace, references and labels over it) and the same Graticule brightness.
struct YRGBScopeView: View {
    @ObservedObject var model: YRGBScopeModel
    /// When shown in a tray slot, the slot's selection binding — makes the header label a picker.
    var slotSelection: Binding<ScopeKind>? = nil
    // Same keys as the waveform and the parade — @AppStorage here for live graticule updates.
    @AppStorage("scopeScale") private var scopeScale: ScopeScale = .bit10
    @AppStorage(Preferences.graticuleBrightnessKey) private var graticuleBrightness = Preferences.defaultGraticuleBrightness
    // The transfer-aware ruler override, SHARED by the value-axis scopes (one key). Default .auto follows the source.
    @AppStorage("manifold.scope.verticalScale") private var verticalScale: ScopeVerticalScale = .auto
    @Environment(\.displayScale) private var displayScale

    // This scope's two user reference lines: the parade's shape under a `manifold.yrgb.` prefix. Separate storage,
    // shared drawing (drawUserLines, through drawActiveValueGraticule). A line spans all four columns.
    @AppStorage("manifold.yrgb.line1.enabled")  private var line1On = false
    @AppStorage("manifold.yrgb.line1.position") private var line1Position = 0.50
    @AppStorage("manifold.yrgb.line2.enabled")  private var line2On = false
    @AppStorage("manifold.yrgb.line2.position") private var line2Position = 0.75

    private var userLines: [Double] {
        var v: [Double] = []
        if line1On { v.append(line1Position) }
        if line2On { v.append(line2Position) }
        return v
    }

    private var activeScale: ActiveVerticalScale {
        resolveVerticalScale(override: verticalScale, transferCode: model.sourceTransferCode)
    }

    private var gutters: ScopePlotGutters {
        scopePlotGutters(active: activeScale, sdrScale: scopeScale, userLines: userLines)
    }

    var body: some View {
#if DEBUG
        let _ = ScopePerf.count("body.YRGBScopeView")
#endif
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    // Y is weighted by the picture matrix, named here from the same feed-written code the waveform's
                    // header reads, so it changes with a LUT or an override exactly as the waveform's does.
                    ScopeSlotHeader(name: "YRGB PARADE",
                                    suffix: valueScopeHeaderSuffix(lead: "Y \(ycbcrMatrixLabel(model.sourceMatrixCode)) · RGB",
                                                                   active: activeScale, sdrScale: scopeScale,
                                                                   forced: verticalScale != .auto, note: model.headerNote),
                                    selection: slotSelection)
                    ScopeValueAxisGear(line1On: $line1On, line1Position: $line1Position,
                                       line2On: $line2On, line2Position: $line2Position,
                                       active: activeScale, sdrScale: scopeScale)
                    Spacer(minLength: 4)
                    Image(systemName: "sun.max")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.4))
                    Slider(value: Preferences.shared.yrgbIntensityBinding,
                           in: Preferences.scopeIntensityRange)
                        .controlSize(.mini)
                        .frame(width: 70)
                    // The RGB Parade's own mono controls, on the SAME preferences: picking a color here or there turns
                    // both scopes monochrome in it; reset returns both to color.
                    ColorPicker("", selection: Preferences.shared.paradeMonoColorBinding)
                        .labelsHidden()
                        .controlSize(.mini)
                    Button { Preferences.shared.paradeMonochrome = false } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Reset parade colors")
                }
                .padding(.horizontal, 6)
                .frame(height: scopeHeaderHeight)

                ZStack {
                    Color.black
                    // Structure UNDER the trace, references and labels OVER it (ScopeGraticuleLayer).
                    graticule(.underTrace)
                        .padding(.vertical, scopePlotInset)
                    ScopeTraceLayer(trace: model.trace) { img in
                        Image(decorative: img, scale: 1.0)
                            .resizable()
                            .interpolation(.none)
                            .padding(.vertical, scopePlotInset)
                            .padding(.leading, gutters.leading)
                            .padding(.trailing, gutters.trailing)
                    }
                    graticule(.overTrace)
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

    /// One layer of the graticule: the parade's, with separators at 1/4, 2/4 and 3/4 of the plot region.
    private func graticule(_ layer: ScopeGraticuleLayer) -> some View {
        let key = ValueGraticuleKey(active: activeScale, sdrScale: scopeScale, gutters: gutters, userLines: userLines,
                                    displayScale: displayScale, graticuleBrightness: graticuleBrightness)
        let g = key.gutters
        return KeyedCanvas(key: key) { ctx, size in
            drawActiveValueGraticule(ctx, size: size, active: key.active, sdrScale: key.sdrScale,
                                     gutters: g, userLines: key.userLines,
                                     layer: layer, displayScale: key.displayScale, brightness: key.graticuleBrightness)
            // Y|R|G|B column separators: structure, under the trace, on the pixel grid, at the parade's weight.
            guard layer == .underTrace else { return }
            let x0 = g.leading, x1 = size.width - g.trailing
            for frac in [0.25, 0.5, 0.75] {
                let x = gridAligned(x0 + (x1 - x0) * frac, scale: key.displayScale, extent: size.width)
                var sep = Path()
                sep.move(to: CGPoint(x: x, y: 0))
                sep.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(sep, with: .color(.white.opacity(
                               ScopeGraticuleBrightness.line(ScopeGraticuleStyle.paradeSeparatorOpacity,
                                                             key.graticuleBrightness))),
                           lineWidth: ScopeGraticuleStyle.lineWidth)
            }
        }
        .equatable()
    }
}
