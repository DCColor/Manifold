import SwiftUI
import CoreGraphics
import Metal
import Combine
import ManifoldCore   // ScopeTrace — the -O-compiled trace-build (fast in Debug too)

/// Native CIE chromaticity scope (Stage A): a CIE 1976 u'v' scatter of the frame's pixels, plotted
/// in the SOURCE gamut. Samples the GPU-resident PRE-DISPLAY offscreen texture (source-primaries,
/// transfer-encoded RGB): cieKernel linearizes each pixel (by the source transfer), converts
/// source-primaries linear RGB → XYZ → u'v', and builds a planeW×planeH histogram on the GPU. Only
/// the tiny histogram is read back; ScopeTrace paints the scatter and the graticule Canvas overlays
/// the spectral-locus horseshoe + 709/P3/2020 gamut triangles. Render-coupled, mirroring the
/// vectorscope. Stage A: u'v' only, all three triangles always shown; xy toggle / per-triangle
/// show-hide / dedicated prefs are later stages (it reuses the vectorscope's intensity + trace color
/// prefs for now).
final class CIEScopeModel: ObservableObject {

    @Published var image: CGImage?
    weak var renderer: MetalVideoRenderer?

    // u'v' plane bounds — SHARED with the graticule draw code (single source of truth) so the
    // GPU scatter and the SwiftUI overlay map chromaticity to the plot identically. Chosen to
    // frame the whole spectral locus with a little headroom (u' ≲ 0.62, v' ≲ 0.60).
    static let uMin: Float = 0.0
    static let uMax: Float = 0.62
    static let vMin: Float = 0.0
    static let vMax: Float = 0.60

    // Square histogram side, tracking the rendered slot (clamped), like the vectorscope.
    private var plane = 300
    private let minPlane = 256
    private let maxPlane = 600

    /// Track the rendered square side so the plane buffer resolution scales with size.
    func setDisplaySide(_ side: CGFloat) {
        let p = scopeBucketWidth(side, min: minPlane, max: maxPlane)
        if p != plane { plane = p }
    }

    // MARK: - Graticule reference data (xy chromaticities; converted to u'v' in the draw code)

    /// CIE 1976 u'v' from CIE 1931 xy. Single conversion used by every overlay element so the
    /// locus, the gamut triangles, and the white point are all consistent with the GPU mapping.
    @inline(__always)
    static func uv(x: CGFloat, y: CGFloat) -> (u: CGFloat, v: CGFloat) {
        let d = -2 * x + 12 * y + 3
        return (4 * x / d, 9 * y / d)
    }

    /// CIE 1931 2° spectral locus (xy), ~380–700 nm. Drawn as a closed polyline (locus + the
    /// straight "line of purples" from 700 nm back to 380 nm) — the horseshoe boundary.
    static let spectralLocusXY: [(x: CGFloat, y: CGFloat)] = [
        (0.1741, 0.0050), // 380
        (0.1740, 0.0050), // 385
        (0.1738, 0.0049), // 390
        (0.1733, 0.0048), // 400
        (0.1726, 0.0048), // 410
        (0.1714, 0.0051), // 420
        (0.1703, 0.0058), // 425
        (0.1689, 0.0069), // 430
        (0.1669, 0.0086), // 435
        (0.1644, 0.0109), // 440
        (0.1611, 0.0138), // 445
        (0.1566, 0.0177), // 450
        (0.1510, 0.0227), // 455
        (0.1440, 0.0297), // 460
        (0.1355, 0.0399), // 465
        (0.1241, 0.0578), // 470
        (0.1096, 0.0868), // 475
        (0.0913, 0.1327), // 480
        (0.0687, 0.2007), // 485
        (0.0454, 0.2950), // 490
        (0.0235, 0.4127), // 495
        (0.0082, 0.5384), // 500
        (0.0039, 0.6548), // 505
        (0.0139, 0.7502), // 510
        (0.0389, 0.8120), // 515
        (0.0743, 0.8338), // 520
        (0.1142, 0.8262), // 525
        (0.1547, 0.8059), // 530
        (0.1929, 0.7816), // 535
        (0.2296, 0.7543), // 540
        (0.2658, 0.7243), // 545
        (0.3016, 0.6923), // 550
        (0.3373, 0.6589), // 555
        (0.3731, 0.6245), // 560
        (0.4087, 0.5896), // 565
        (0.4441, 0.5547), // 570
        (0.4788, 0.5202), // 575
        (0.5125, 0.4866), // 580
        (0.5448, 0.4544), // 585
        (0.5752, 0.4242), // 590
        (0.6029, 0.3965), // 595
        (0.6270, 0.3725), // 600
        (0.6482, 0.3514), // 605
        (0.6658, 0.3340), // 610
        (0.6801, 0.3197), // 615
        (0.6915, 0.3083), // 620
        (0.7006, 0.2993), // 625
        (0.7079, 0.2920), // 630
        (0.7190, 0.2809), // 640
        (0.7260, 0.2740), // 650
        (0.7300, 0.2700), // 660
        (0.7334, 0.2666), // 680
        (0.7347, 0.2653)  // 700
    ]

    /// A gamut triangle: three primary chromaticities in xy + a display color + label.
    struct Gamut {
        let name: String
        let r: (x: CGFloat, y: CGFloat)
        let g: (x: CGFloat, y: CGFloat)
        let b: (x: CGFloat, y: CGFloat)
        let color: Color
    }

    /// 709 / P3 / 2020 gamut triangles (xy primaries) — all three always shown in Stage A.
    static let gamuts: [Gamut] = [
        Gamut(name: "709",  r: (0.640, 0.330), g: (0.300, 0.600), b: (0.150, 0.060),
              color: Color(white: 0.85)),
        Gamut(name: "P3",   r: (0.680, 0.320), g: (0.265, 0.690), b: (0.150, 0.060),
              color: Color(red: 0.35, green: 0.85, blue: 1.0)),   // cyan
        Gamut(name: "2020", r: (0.708, 0.292), g: (0.170, 0.797), b: (0.131, 0.046),
              color: Color(red: 1.0, green: 0.75, blue: 0.30))     // amber
    ]

    /// D65 white point (xy).
    static let whiteXY: (x: CGFloat, y: CGFloat) = (0.3127, 0.3290)

    // Render-coupled sampling state (main-only) — see WaveformScopeModel for the rationale.
    private var active = false
    private var sampling = false
    private var pendingSample = false
    /// Live pref-coupling (paused re-sample on a scope-pref change) — see WaveformScopeModel.
    private var prefsObserver: AnyCancellable?

    /// Mark visible and sample the current offscreen frame once (covers tray-open while paused).
    /// Sampling is otherwise render-coupled (frameRendered) + pref-coupled (below).
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
        // Effective gain (Preferences read on main). Stage A reuses the vectorscope's intensity
        // + global master; a dedicated CIE intensity is a later stage.
        let gain = baseGain
            * Float(Preferences.shared.vectorscopeIntensity)
            * Float(Preferences.shared.globalScopeIntensity)
        // Trace hue (snapshot on main); reuses the vectorscope trace color for now.
        let color = ScopeColorCodec.rgb(fromHex: Preferences.shared.vectorscopeTraceColorHex)

        // cieKernel builds the planeW×planeH u'v' histogram over the GPU-resident offscreen; only
        // the small plane buffer is read back. The trace-build runs on the GPU completion thread
        // (a fast -O ScopeTrace call), then hops to main to publish.
        let plane = self.plane
        let issued = renderer.computeCIEGPU(planeW: plane, planeH: plane, useUV: true,
                                            uMin: Self.uMin, uMax: Self.uMax,
                                            vMin: Self.vMin, vMax: Self.vMax) { [weak self] hist, w, h in
            guard let self else { return }
            let img = self.buildCIETraceImage(histogram: hist, planeW: w, planeH: h, gain: gain, color: color)
            DispatchQueue.main.async {
                if self.active, let img { self.image = img }
                self.finishSample()
            }
        }
        if !issued { sampling = false }
    }

    /// Turn a planeW×planeH u'v' histogram (layout hist[row*planeW + col], v' up) into the
    /// scatter CGImage. NO row-downsample (it's a 2-D scatter, not a value histogram).
    private func buildCIETraceImage(histogram accum: [UInt32], planeW: Int, planeH: Int,
                                    gain: Float, color: (r: Float, g: Float, b: Float)) -> CGImage? {
        guard planeW > 0, planeH > 0, accum.count >= planeW * planeH else { return nil }

        let pixels = ScopeTrace.ciePixels(histogram: accum, planeW: planeW, planeH: planeH, gain: gain,
                                          colorR: color.r, colorG: color.g, colorB: color.b)

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: planeW, height: planeH,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: planeW * 4,
                       space: cs, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Floating square CIE chromaticity panel: u'v' scatter image + spectral-locus horseshoe and
/// 709/P3/2020 gamut-triangle overlays. Header "CIE 1976 u'v'".
struct CIEScopeView: View {
    @ObservedObject var model: CIEScopeModel

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text("CIE 1976 u′v′")
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
            .onAppear { model.setDisplaySide(min(geo.size.width, geo.size.height)) }
            .onChange(of: min(geo.size.width, geo.size.height)) { _, side in
                model.setDisplaySide(side)
            }
        }
    }

    /// Map a u'v' coordinate to a point in the plot — the SAME normalization the kernel uses
    /// (fu/fv over the shared bounds, v' flipped for image row order), so overlay and scatter align.
    private func point(u: CGFloat, v: CGFloat, in size: CGSize) -> CGPoint {
        let fu = (u - CGFloat(CIEScopeModel.uMin)) / CGFloat(CIEScopeModel.uMax - CIEScopeModel.uMin)
        let fv = (v - CGFloat(CIEScopeModel.vMin)) / CGFloat(CIEScopeModel.vMax - CIEScopeModel.vMin)
        return CGPoint(x: fu * size.width, y: (1 - fv) * size.height)
    }

    private var graticule: some View {
        Canvas { ctx, size in
            // Spectral-locus horseshoe: closed polyline (locus + line of purples).
            var locus = Path()
            let pts = CIEScopeModel.spectralLocusXY.map { xy -> CGPoint in
                let (u, v) = CIEScopeModel.uv(x: xy.x, y: xy.y)
                return point(u: u, v: v, in: size)
            }
            if let first = pts.first {
                locus.move(to: first)
                for p in pts.dropFirst() { locus.addLine(to: p) }
                locus.closeSubpath()   // 700 nm → 380 nm: the line of purples
            }
            ctx.stroke(locus, with: .color(.white.opacity(0.35)), lineWidth: 0.75)

            // Gamut triangles — vertices from xy primaries via the shared uv() conversion.
            for gamut in CIEScopeModel.gamuts {
                let rP = triPoint(gamut.r, size)
                let gP = triPoint(gamut.g, size)
                let bP = triPoint(gamut.b, size)
                var tri = Path()
                tri.move(to: rP); tri.addLine(to: gP); tri.addLine(to: bP); tri.closeSubpath()
                ctx.stroke(tri, with: .color(gamut.color.opacity(0.85)), lineWidth: 0.9)
            }

            // D65 white-point marker (small cross).
            let (wu, wv) = CIEScopeModel.uv(x: CIEScopeModel.whiteXY.x, y: CIEScopeModel.whiteXY.y)
            let w = point(u: wu, v: wv, in: size)
            var cross = Path()
            cross.move(to: CGPoint(x: w.x - 4, y: w.y)); cross.addLine(to: CGPoint(x: w.x + 4, y: w.y))
            cross.move(to: CGPoint(x: w.x, y: w.y - 4)); cross.addLine(to: CGPoint(x: w.x, y: w.y + 4))
            ctx.stroke(cross, with: .color(.white.opacity(0.7)), lineWidth: 0.75)

            // Legend (top-left) — name + swatch color for each gamut.
            var ly: CGFloat = 8
            for gamut in CIEScopeModel.gamuts {
                var swatch = Path()
                swatch.move(to: CGPoint(x: 8, y: ly + 4)); swatch.addLine(to: CGPoint(x: 20, y: ly + 4))
                ctx.stroke(swatch, with: .color(gamut.color.opacity(0.9)), lineWidth: 1.5)
                ctx.draw(
                    Text(gamut.name).font(.system(size: 8, design: .monospaced))
                        .foregroundColor(gamut.color.opacity(0.9)),
                    at: CGPoint(x: 24, y: ly + 4), anchor: .leading
                )
                ly += 12
            }
        }
    }

    private func triPoint(_ xy: (x: CGFloat, y: CGFloat), _ size: CGSize) -> CGPoint {
        let (u, v) = CIEScopeModel.uv(x: xy.x, y: xy.y)
        return point(u: u, v: v, in: size)
    }
}
