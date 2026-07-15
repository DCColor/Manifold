import SwiftUI
import CoreGraphics
import Metal
import Combine
import ManifoldCore   // ScopeTrace — the -O-compiled trace-build (fast in Debug too)

/// Vectorscope graticule reference — WHICH gamut's target boxes overlay the plot. Independent of
/// the trace math (which always uses the source matrix). Persisted @AppStorage("manifold.vectorscope.graticule"),
/// shared by VectorscopeScopeView (draw) and ContentView (the ⌃⌥G shortcut) — the single source of truth.
enum VectorscopeGraticule: String, CaseIterable, Identifiable {
    /// FIXED Rec.709 boxes, always — the reference-instrument convention. Wide-gamut content reads
    /// PAST the boxes, so the graticule doubles as a 709-gamut-usage reference. Default.
    case fixed709
    /// Boxes at the SOURCE gamut's primary positions (from colorPrimariesCode), so correctly-encoded
    /// bars of the working colorspace land in-box.
    case sourcePrimaries
    var id: String { rawValue }
    /// Menu label.
    var label: String {
        switch self {
        case .fixed709:        return "Fixed 709 (reference)"
        case .sourcePrimaries: return "Source primaries"
        }
    }
}

/// Vectorscope target-box AMPLITUDE — 75% bars, 100% bars, or both concentric sets (Resolve's
/// vectorscope idiom). ORTHOGONAL to the 709/source graticule reference: that picks the matrix/hue
/// (box angle), this picks the code amplitude (box radius). The trace is unchanged — these are just
/// reference rings. Persisted @AppStorage("manifold.vectorscope.boxAmplitude"), shared by the draw
/// and the ⌃⌥B shortcut.
enum VectorscopeBoxAmplitude: String, CaseIterable, Identifiable {
    case percent75, percent100, both
    var id: String { rawValue }
    /// Menu label.
    var label: String {
        switch self {
        case .percent75:  return "75%"
        case .percent100: return "100%"
        case .both:       return "75% + 100%"
        }
    }
    /// Compact header tag.
    var headerTag: String {
        switch self {
        case .percent75:  return "75"
        case .percent100: return "100"
        case .both:       return "75+100"
        }
    }
    var shows75: Bool { self != .percent100 }
    var shows100: Bool { self != .percent75 }
}

/// Native vectorscope: a 2D chroma-plane (Cb horizontal, Cr vertical) scatter on a circular
/// graticule with the six color-bar target boxes (R, G, B, Cy, Mg, Yl). Samples the GPU-resident
/// PRE-DISPLAY offscreen texture: vectorscopeKernel builds the plane×plane chroma histogram on
/// the GPU, only the tiny histogram is read back, and ScopeTrace paints the scatter. Render-coupled.
final class VectorscopeScopeModel: ObservableObject {

    @Published var image: CGImage?
    weak var renderer: MetalVideoRenderer?

    /// Source CICP codes, for the HEADER + GRATICULE only (the trace MATH reads matrixCode off the
    /// renderer in computeVectorscopeGPU, so label and math can't disagree). Set from ContentView on
    /// metadata change, mirroring cieModel.spaceReadout.
    /// - matrix drives the header label + the plotted chroma (WHERE points land).
    /// - primaries drives the source-primaries graticule box positions (WHICH gamut's boxes).
    /// They are INDEPENDENT (e.g. P3 source: primaries P3, matrix 709-class).
    @Published var sourceMatrixCode: Int?
    @Published var sourcePrimariesCode: Int?

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

    /// SMPTE bar active-channel code levels, in the offscreen's FULL-RANGE 0–255 domain (the
    /// offscreen is range-expanded, so 100% white = 255 and the trace shares this domain — see the
    /// vectorscope kernel). 75% = 0.75·255 ≈ 191 (the classic level); 100% = full amplitude. The box
    /// RADIUS scales with this level; the hue ANGLE comes from the matrix (Kr/Kb), so the 75% and
    /// 100% sets share angles and differ only in radius.
    static let barLevel75: Float = 191    // 0.75 · 255 — the classic SMPTE 75%-bar level
    static let barLevel100: Float = 255   // full amplitude — 100%-bar primaries/secondaries

    /// Which concentric box set — used by the draw to decide where the hue labels ride.
    enum BarSet { case p75, p100 }

    /// The six target-box colors (R/Yl/G/Cy/B/Mg) at a given active-channel code level `a`. Derives
    /// the box centers from the SAME Cb/Cr transform as the plotted data (not hand-placed), so bars
    /// of that amplitude land in their boxes.
    static func boxTargets(level a: Float) -> [(name: String, r: Float, g: Float, b: Float)] {
        [ ("R",  a, 0, 0), ("Yl", a, a, 0), ("G",  0, a, 0),
          ("Cy", 0, a, a), ("B",  0, 0, a), ("Mg", a, 0, a) ]
    }

    /// Normalized chroma for a given YCbCr matrix (Kr/Kb). Parameterized so the target-box
    /// derivation matches WHATEVER matrix the graticule mode selects — the same generalized formula
    /// the GPU kernel now uses (709: 1.8556/1.5748, 2020: 1.8814/1.4746). Cb,Cr ≈ [-128,127] for
    /// 0–255 input. This is the ONE transform shared by every box in the draw.
    @inline(__always)
    static func chroma(r: Float, g: Float, b: Float, kr: Float, kb: Float) -> (cb: Float, cr: Float) {
        let kg = 1 - kr - kb
        let y = kr * r + kg * g + kb * b
        let cb = (b - y) / (2 * (1 - kb))
        let cr = (r - y) / (2 * (1 - kr))
        return (cb, cr)
    }

    /// (Kr,Kb) that PLACES the source-primaries graticule boxes — selected by colorPrimariesCode
    /// (never the matrix code: the graticule follows the gamut). Each gamut's boxes are where a
    /// correctly-encoded 75% bar of that colorspace lands, which is that gamut's CANONICAL YCbCr
    /// matrix. NOTE the 709/P3 coincidence: P3 is a 709-MATRIX gamut, so its boxes sit exactly on
    /// 709's — a code-value vectorscope genuinely can't separate P3 from 709 (that's the CIE scope's
    /// job); only 2020's wider matrix shifts the primary hue angles. nil/2/unknown → 709.
    static func graticuleKrKb(forPrimariesCode code: Int?) -> (kr: Float, kb: Float) {
        switch code {
        case 9:  return (0.2627, 0.0593)   // Rec.2020
        default: return (0.2126, 0.0722)   // Rec.709 / P3 (709-class matrix) / unknown
        }
    }

    /// 709 luma coefficients — the FIXED-709 graticule reference (and the historical default).
    static let kr709: Float = 0.2126
    static let kb709: Float = 0.0722

    // Render-coupled sampling state (main-only) — see WaveformScopeModel for the rationale.
    private var active = false
    private var sampling = false
    private var pendingSample = false
    /// One-shot publish suppressor: set by clear() on a source teardown so a GPU sample already in
    /// flight can't republish the old trace after the panel is blanked. Reset when a genuinely new
    /// sample cycle begins (startSample), so a new source's frames draw normally.
    private var cleared = false
    /// Live pref-coupling (paused re-sample on a scope-pref change) — see WaveformScopeModel.
    private var prefsObserver: AnyCancellable?

    /// Process EVERY row (full-res) — cheap on the GPU, like waveform/parade.
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

    /// Blank the published trace on a source teardown (NDI disconnect), WITHOUT deactivating: the
    /// renderer invalidates the offscreen this scope reads, so nothing resamples the old frame, and
    /// `cleared` suppresses any sample already in flight. When a new source renders, the render-
    /// coupled frameRendered path resumes sampling and the trace returns — no restart needed.
    func clear() {
        pendingSample = false
        cleared = true
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
        cleared = false   // a real new cycle — allow its publish (supersedes any prior blank request)
        // Effective gain (Preferences read on main): baseGain × vectorscope × global master.
        let gain = baseGain
            * Float(Preferences.shared.vectorscopeIntensity)
            * Float(Preferences.shared.globalScopeIntensity)
        // Trace hue (snapshot on main); brightness stays the intensity's job.
        let color = ScopeColorCodec.rgb(fromHex: Preferences.shared.vectorscopeTraceColorHex)

        // vectorscopeKernel builds the plane×plane chroma histogram over the GPU-resident
        // offscreen; only the small plane buffer (≤~1.4MB) is read back — no full-frame copy.
        // The trace-build runs right here on the GPU completion thread (a fast -O ScopeTrace
        // call), then hops to main to publish.
        let plane = self.plane
        let issued = renderer.computeVectorscopeGPU(plane: plane,
                                                    chromaScale: Self.chromaScaleFrac,
                                                    rowStride: gpuRowStride) { [weak self] hist, p in
            guard let self else { return }
            let img = self.buildVectorscopeTraceImage(histogram: hist, plane: p, gain: gain, color: color)
            DispatchQueue.main.async {
                if self.active, !self.cleared, let img { self.image = img }
                self.finishSample()
            }
        }
        if !issued { sampling = false }
    }

    /// Turn a plane×plane chroma histogram (layout hist[py*plane + px], Cb horizontal, Cr
    /// up) into the white-on-black scatter CGImage. The image is square (plane×plane),
    /// matching the circular display; NO row-downsample (it isn't a value histogram).
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

/// Floating square vectorscope panel: trace image + circular graticule with the derived target boxes.
/// Header reads the SOURCE matrix (709/2020/601) + the active graticule reference + box amplitude; a
/// gear menu switches the graticule between FIXED 709 and SOURCE-PRIMARIES (⌃⌥G) and the target boxes
/// between 75% / 100% / both (⌃⌥B) — the two are orthogonal.
struct VectorscopeScopeView: View {
    @ObservedObject var model: VectorscopeScopeModel
    /// When shown in a tray slot, the slot's selection binding — makes the header label a picker.
    var slotSelection: Binding<ScopeKind>? = nil

    /// Persisted graticule reference — the single source of truth, same key the ⌃⌥G shortcut writes
    /// (ContentView). The draw reads it directly, so a menu pick or the shortcut redraw the overlay
    /// immediately (overlay-only — the trace math is unaffected, exactly like the CIE triangle toggles).
    @AppStorage("manifold.vectorscope.graticule") private var graticule: VectorscopeGraticule = .fixed709

    /// Persisted target-box amplitude (75% / 100% / both) — orthogonal to the graticule reference,
    /// same key the ⌃⌥B shortcut writes. Overlay-only: the draw reads it directly and redraws.
    @AppStorage("manifold.vectorscope.boxAmplitude") private var boxAmplitude: VectorscopeBoxAmplitude = .percent75

    /// Persisted outer-ring degree ticks — OFF by default (clean; opt-in). Broadcast-vectorscope
    /// idiom: small ticks radiating inward from the boundary circle. Overlay-only (graticule redraw).
    @AppStorage("manifold.vectorscope.outerTicks") private var outerTicks = false

    /// The active graticule reference label — "Rec. 709" when fixed, else the SOURCE gamut (from
    /// primaries). Canonical "Rec." form, matching the matrix label + CIE/inspector.
    private var graticuleLabel: String {
        switch graticule {
        case .fixed709:        return "Rec. 709"
        case .sourcePrimaries: return gamutPrimariesLabel(model.sourcePrimariesCode)
        }
    }

    /// Vectorscope options (gear): the graticule-reference picker. Mirrors the CIE scope's gear menu
    /// + shortcut-hint style; the plain `$graticule` binding is enough because the overlay reads the
    /// same @AppStorage (no kernel push needed — the math already tracks the source matrix).
    private var vectorscopeOptionsMenu: some View {
        Menu {
            Section("Graticule reference · ⌃⌥G") {
                Picker("Graticule", selection: $graticule) {
                    ForEach(VectorscopeGraticule.allCases) { g in
                        Text(g.label).tag(g)
                    }
                }
                .pickerStyle(.inline)
            }
            Section("Target boxes · ⌃⌥B") {
                Picker("Target boxes", selection: $boxAmplitude) {
                    ForEach(VectorscopeBoxAmplitude.allCases) { a in
                        Text(a.label).tag(a)
                    }
                }
                .pickerStyle(.inline)
            }
            Section("Graticule extras") {
                Toggle("Outer ring ticks", isOn: $outerTicks)
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Vectorscope options")
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    // Suffix = the SOURCE matrix (the value driving the plotted chroma) + the active
                    // graticule reference. Was hardcoded "709"; now it reads the real matrix, so a
                    // 2020 source no longer mislabels as 709 while CIE/inspector say 2020.
                    ScopeSlotHeader(name: "VECTORSCOPE",
                                    suffix: " · \(ycbcrMatrixLabel(model.sourceMatrixCode)) · gr \(graticuleLabel) · box \(boxAmplitude.headerTag)",
                                    selection: slotSelection)
                    vectorscopeOptionsMenu
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
                    graticuleView
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

    private var graticuleView: some View {
        Canvas { ctx, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let frac = CGFloat(VectorscopeScopeModel.chromaScaleFrac)

            // Box-placement coefficients: FIXED 709, or the SOURCE gamut's (from primariesCode).
            // The trace math is independent (source matrix, in-kernel) — this only moves the boxes.
            let (kr, kb): (Float, Float)
            switch graticule {
            case .fixed709:
                (kr, kb) = (VectorscopeScopeModel.kr709, VectorscopeScopeModel.kb709)
            case .sourcePrimaries:
                (kr, kb) = VectorscopeScopeModel.graticuleKrKb(forPrimariesCode: model.sourcePrimariesCode)
            }

            // Outer chroma boundary circle (subtle). Sized to enclose the 100% targets.
            let circleR = size.width * 0.46
            let circleRect = CGRect(x: cx - circleR, y: cy - circleR,
                                    width: circleR * 2, height: circleR * 2)
            ctx.stroke(Path(ellipseIn: circleRect), with: .color(.white.opacity(0.14)), lineWidth: 0.5)

            // Optional degree ticks radiating INWARD from the boundary circle (broadcast-vectorscope
            // idiom; off by default). Minor every 5°, longer majors every 45°, in the subtle
            // graticule weight — a reference ring, not a bright element. Overlay-only.
            if outerTicks {
                var minorTicks = Path(), majorTicks = Path()
                for deg in stride(from: 0, to: 360, by: 5) {
                    let a = CGFloat(deg) * .pi / 180
                    let ux = cos(a), uy = sin(a)
                    let isMajor = deg % 45 == 0
                    let len: CGFloat = isMajor ? 8 : 4
                    let outer = CGPoint(x: cx + ux * circleR, y: cy + uy * circleR)
                    let inner = CGPoint(x: cx + ux * (circleR - len), y: cy + uy * (circleR - len))
                    if isMajor { majorTicks.move(to: outer); majorTicks.addLine(to: inner) }
                    else       { minorTicks.move(to: outer); minorTicks.addLine(to: inner) }
                }
                ctx.stroke(minorTicks, with: .color(.white.opacity(0.42)), lineWidth: 0.5)
                ctx.stroke(majorTicks, with: .color(.white.opacity(0.58)), lineWidth: 0.5)
            }

            // Faint center crosshair.
            var cross = Path()
            cross.move(to: CGPoint(x: cx - 6, y: cy)); cross.addLine(to: CGPoint(x: cx + 6, y: cy))
            cross.move(to: CGPoint(x: cx, y: cy - 6)); cross.addLine(to: CGPoint(x: cx, y: cy + 6))
            ctx.stroke(cross, with: .color(.white.opacity(0.2)), lineWidth: 0.5)

            // Targets — derived from the SAME chroma transform as the data. Up to two concentric sets
            // (75% + 100%), selectable per the amplitude menu. Both sets render IDENTICALLY (same
            // brightness, weight, style) like Resolve — distinguished ONLY by radius + label, not by
            // dimming/dashing. Each target is drawn as four L-shaped CORNER BRACKETS framing the point
            // (open center), the broadcast-vectorscope idiom, not a closed square. Same hue angles
            // (matrix Kr/Kb); the amplitude only changes the radius. Labels ride the innermost drawn
            // set so the hue names never double up in `both` mode.
            let box: CGFloat = 9          // full bracket-frame side (target center ± box/2)
            let arm: CGFloat = box * 0.36 // length of each bracket leg (open center between them)
            let labelSet: VectorscopeScopeModel.BarSet = boxAmplitude.shows75 ? .p75 : .p100
            func drawTargets(level: Float, set: VectorscopeScopeModel.BarSet) {
                for t in VectorscopeScopeModel.boxTargets(level: level) {
                    let (cb, cr) = VectorscopeScopeModel.chroma(r: t.r, g: t.g, b: t.b, kr: kr, kb: kb)
                    let bxCenterX = cx + CGFloat(cb) * frac * size.width
                    let bxCenterY = cy - CGFloat(cr) * frac * size.height   // Cr up
                    let h = box / 2
                    let l = bxCenterX - h, r = bxCenterX + h   // frame edges
                    let tp = bxCenterY - h, bt = bxCenterY + h
                    // Four corner brackets — each an L (one horizontal + one vertical leg) meeting at
                    // a corner, leaving the center open so the trace point reads inside the frame.
                    var brackets = Path()
                    // top-left
                    brackets.move(to: CGPoint(x: l, y: tp)); brackets.addLine(to: CGPoint(x: l + arm, y: tp))
                    brackets.move(to: CGPoint(x: l, y: tp)); brackets.addLine(to: CGPoint(x: l, y: tp + arm))
                    // top-right
                    brackets.move(to: CGPoint(x: r, y: tp)); brackets.addLine(to: CGPoint(x: r - arm, y: tp))
                    brackets.move(to: CGPoint(x: r, y: tp)); brackets.addLine(to: CGPoint(x: r, y: tp + arm))
                    // bottom-left
                    brackets.move(to: CGPoint(x: l, y: bt)); brackets.addLine(to: CGPoint(x: l + arm, y: bt))
                    brackets.move(to: CGPoint(x: l, y: bt)); brackets.addLine(to: CGPoint(x: l, y: bt - arm))
                    // bottom-right
                    brackets.move(to: CGPoint(x: r, y: bt)); brackets.addLine(to: CGPoint(x: r - arm, y: bt))
                    brackets.move(to: CGPoint(x: r, y: bt)); brackets.addLine(to: CGPoint(x: r, y: bt - arm))
                    ctx.stroke(brackets, with: .color(.white.opacity(0.5)), lineWidth: 0.75)
                    if set == labelSet {
                        ctx.draw(
                            Text(t.name).font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.white.opacity(0.55)),
                            at: CGPoint(x: bxCenterX, y: bxCenterY - box), anchor: .center
                        )
                    }
                }
            }
            // 75% and 100% are peers — identical style, distinguished by radius + label.
            if boxAmplitude.shows100 { drawTargets(level: VectorscopeScopeModel.barLevel100, set: .p100) }
            if boxAmplitude.shows75  { drawTargets(level: VectorscopeScopeModel.barLevel75,  set: .p75) }
        }
    }
}
