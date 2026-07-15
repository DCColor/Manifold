import SwiftUI
import CoreGraphics
import AppKit
import Combine
import ManifoldCore   // ScopeTrace — the -O-compiled trace-build (fast in Debug too)

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

// MARK: - Source-colorspace header labels (shared by the matrix-aware scopes)

/// Short YCbCr-matrix label for scope headers, in the canonical "Rec." form (period + space) that the
/// CIE scope + inspector already render (MediaInspector.matrixName / primariesName) — so every surface
/// reads character-identically. Driven by the SAME colorMatrixCode that selects the luma/chroma Kr/Kb
/// in the kernels (via ycbcrKrKb), so the header and the math can never disagree. nil / 2 (unspecified)
/// / unknown → "Rec. 709" (the math's default; the scope always plots with a concrete matrix).
func ycbcrMatrixLabel(_ code: Int?) -> String {
    switch code {
    case 9: return "Rec. 2020"
    case 6: return "Rec. 601"
    default: return "Rec. 709"   // also 1 / nil / 2 / unknown
    }
}

/// Short gamut label for the SOURCE-PRIMARIES vectorscope graticule — driven by colorPrimariesCode
/// (the gamut whose primaries place the boxes), INDEPENDENT of the matrix. Canonical "Rec." form to
/// match the other surfaces; P3 has no "Rec." form and stays "P3". nil/2/unknown → "Rec. 709".
func gamutPrimariesLabel(_ code: Int?) -> String {
    switch code {
    case 9:      return "Rec. 2020"
    case 11, 12: return "P3"          // DCI-P3 / Display P3 — no "Rec." form
    default:     return "Rec. 709"    // Rec.709 / sRGB (also 1 / nil / 2 / unknown)
    }
}

// MARK: - Trace brightness mapping (shared by all scopes)

// baseGain is the gain at intensity 1.0 — i.e. perScope=global=1.0 reproduces the
// current look. The user-facing intensities multiply this (see each scope's tick).
// The gamma/floor curve constants live in ScopeTrace (ManifoldCore); baseGain stays here
// because it feeds the gain the models compute on the main thread.
let baseGain: Float = 1.6      // dense bins reach full white a bit before the very max

/// Trace-image pixel height (rows) for the waveform. The GPU 1024-bin histogram is
/// mapped down to this many rows in the trace-build; the image is then scaled to fill
/// the panel. Taller = sharper (less upscale of the small image), at a tiny CPU cost on
/// the ~1MB histogram. A/B lever: try 256 / 512 / 1024 — best kept a power-of-2 divisor
/// of the 1024 GPU bins so the group-sum is exact (any value ≤1024 still counts every
/// pixel — see ScopeTrace.waveformPixels — but divisors map cleanest).
let waveformDisplayRows = 512

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
        // Waveform + parade both compute a genuine 10-bit histogram on the GPU (off the
        // rgb10a2 offscreen), so the 10-bit scale is real 10-bit — no "(8-bit data)" caveat.
        case .bit10: return "10-bit"
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

// MARK: - Transfer-aware vertical scale (waveform + parade) — TRANSFER-ANNOTATION, not trace-transform
//
// PRINCIPLE: the trace NEVER changes — it stays 10-bit code values (0–1023), same positions,
// same histogram. Only the GRATICULE (horizontal reference lines + labels) changes to annotate
// what those code values MEAN under the source's transfer function. We relabel the ruler; the
// signal is the signal.

/// Transfer-aware vertical-scale OVERRIDE for the value-axis scopes (waveform + parade).
/// SEPARATE from `scopeScale` (which only chooses the SDR sub-representation 8-bit/10-bit/IRE).
/// This chooses WHICH RULER annotates the unchanged code-value trace:
///   .auto → follows the source `transferFunctionCode` (16→PQ nits, 18→HLG %+nits, else SDR)
///   .sdr / .pq / .hlg → forces that ruler regardless of the source (for A/B and untagged media).
/// @AppStorage-persisted under one key, shared by BOTH scopes (one setting, one axis). Mirrors
/// the vectorscope's gear-menu + @AppStorage override pattern. Overlay-only: the trace math is
/// untouched — exactly like the vectorscope graticule toggles.
enum ScopeVerticalScale: String, CaseIterable, Identifiable {
    case auto, sdr, pq, hlg
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (follow source)"
        case .sdr:  return "SDR (%/code)"
        case .pq:   return "PQ (nits)"
        case .hlg:  return "HLG (% + nits)"
        }
    }
}

/// The resolved ruler after applying the override to the source transfer — what actually draws.
enum ActiveVerticalScale { case sdr, pq, hlg }

/// Resolve the active ruler from the override + the source CICP `transferFunctionCode`.
/// Read INDEPENDENTLY of the matrix/primaries codes (transfer is its own axis): 16 = PQ (ST2084),
/// 18 = HLG; everything else (1/709, 13/sRGB, nil, 2/unspecified, unknown) = SDR default.
func resolveVerticalScale(override: ScopeVerticalScale, transferCode: Int?) -> ActiveVerticalScale {
    switch override {
    case .sdr: return .sdr
    case .pq:  return .pq
    case .hlg: return .hlg
    case .auto:
        switch transferCode {
        case 16: return .pq
        case 18: return .hlg
        default: return .sdr
        }
    }
}

/// Header suffix for a value-axis scope, transfer-aware. `lead` is the per-scope signal descriptor
/// ("luma Rec. 709" for waveform, "RGB" for parade). A trailing `*` marks a FORCED (manual) ruler
/// so it reads as an override, not an auto-detected one.
func valueScopeHeaderSuffix(lead: String, active: ActiveVerticalScale,
                            sdrScale: ScopeScale, forced: Bool) -> String {
    let star = forced ? "*" : ""
    switch active {
    case .sdr: return " · \(lead) (\(sdrScale.headerTag))"
    case .pq:  return " · \(lead) · PQ (nits)\(star)"
    case .hlg: return " · \(lead) · HLG (%·nits)\(star)"
    }
}

// MARK: - PQ / HLG graticule math (ITU-R BT.2100)

/// ST 2084 (PQ) inverse-EOTF: absolute display luminance in NITS → normalized PQ code [0,1].
/// L = nits / 10000 (PQ peak is 10000 nits); code = ((c1 + c2·L^m1) / (1 + c3·L^m1))^m2.
/// For a FULL-RANGE 10-bit trace the normalized code IS the vertical height fraction (code/1023),
/// so this value places the marker directly. (203 nits → ~0.581 → ~code 594; confirmed inline.)
func pqCodeNormalized(nits: Double) -> Double {
    let m1 = 0.1593017578125
    let m2 = 78.84375
    let c1 = 0.8359375
    let c2 = 18.8515625
    let c3 = 18.6875
    let L = max(0.0, nits) / 10000.0
    let Lm1 = pow(L, m1)
    let num = c1 + c2 * Lm1
    let den = 1.0 + c3 * Lm1
    return pow(num / den, m2)
}

/// HLG OETF (scene-linear E [0,1] → signal E' [0,1]), ITU-R BT.2100.
private func hlgSignal(sceneLinear e: Double) -> Double {
    let a = 0.17883277, b = 0.28466892, c = 0.55991073
    let x = max(0.0, min(1.0, e))
    if x <= 1.0 / 12.0 { return (3.0 * x).squareRoot() }
    return a * log(12.0 * x - b) + c
}

/// HLG display NITS (via the OOTF at a nominal peak) → HLG signal value E' [0,1].
/// Display L ≈ peak · E^γ (scene-linear E, system gamma γ). Invert: E = (nits/peak)^(1/γ), then
/// signal = OETF(E). γ = 1.2 is the nominal HLG system gamma at a 1000-nit peak display. For the
/// full-range trace the signal value IS the height fraction. (203 nits → 75%; 1000 nits → 100%.)
private func hlgSignalForNits(_ nits: Double, peak: Double = 1000.0, gamma: Double = 1.2) -> Double {
    let e = pow(max(0.0, nits) / peak, 1.0 / gamma)   // scene-linear normalized
    return hlgSignal(sceneLinear: e)
}

/// Line-emphasis tiers for the HDR graticules: normal, strong (SDR white 100 nits), key
/// (BT.2408 HDR diffuse/graphics white 203 nits — the primary grading reference).
enum GratEmphasis { case normal, strong, key }

/// One PQ nits reference line: its nits value, label, and emphasis.
struct PQNitsLevel { let nits: Double; let label: String; let emphasis: GratEmphasis }

/// PQ nits ladder — non-linearly spaced (perceptual); each lands at its ST2084 code height.
/// 203 nits (BT.2408 diffuse white) and 100 nits (SDR white) are the emphasized references.
let pqNitsLevels: [PQNitsLevel] = [
    .init(nits: 0.1,   label: "0.1",   emphasis: .normal),
    .init(nits: 1,     label: "1",     emphasis: .normal),
    .init(nits: 10,    label: "10",    emphasis: .normal),
    .init(nits: 100,   label: "100",   emphasis: .strong),
    .init(nits: 203,   label: "203",   emphasis: .key),
    .init(nits: 1000,  label: "1000",  emphasis: .normal),
    .init(nits: 4000,  label: "4000",  emphasis: .normal),
    .init(nits: 10000, label: "10000", emphasis: .normal),
]

/// HLG secondary nits ladder (assuming a nominal 1000-nit peak display). Placed via the HLG
/// OOTF/EOTF; labels are secondary to the primary % scale.
let hlgNitsLevels: [Double] = [1, 10, 100, 203, 1000]

/// Native luma waveform scope. Samples the GPU-resident PRE-DISPLAY offscreen texture (raw
/// code values), never screen pixels, so it agrees with a Resolve waveform on the same frame:
/// waveformKernel bins the 10-bit luma histogram on the GPU, only the tiny histogram is read
/// back, and ScopeTrace builds the trace image. Render-coupled sampling (see frameRendered).
final class WaveformScopeModel: ObservableObject {

    /// The computed waveform trace image (green-on-black), published to the view.
    @Published var image: CGImage?

    /// Set by the owner when the scope is shown. Weak — the renderer outlives nothing here.
    weak var renderer: MetalVideoRenderer?

    /// Source YCbCr matrix code (CICP), for the header label ONLY — the luma MATH reads the same
    /// code off the renderer (computeWaveformGPU), so label and weighting stay in lock-step. Set
    /// from ContentView on metadata change, mirroring cieModel.spaceReadout. nil/2/unknown → 709.
    @Published var sourceMatrixCode: Int?

    /// Source transfer-function code (CICP) — drives the AUTO vertical-scale ruler (16=PQ, 18=HLG,
    /// else SDR), INDEPENDENTLY of the matrix/primaries. Set from ContentView the same way as
    /// sourceMatrixCode; the graticule is the only consumer (the TRACE is unaffected). nil/2 → SDR.
    @Published var sourceTransferCode: Int?

    // Column buckets (histogram width) — tracks the rendered slot width, clamped, so a wider
    // scope computes more horizontal detail instead of upscaling a fixed buffer.
    private var columns = 512
    private let minColumns = 256
    private let maxColumns = 1024

    /// Histogram precision: TRUE 10-bit (1024 luma bins), read straight off the rgb10a2
    /// offscreen by waveformKernel. buildTraceImage maps 1024 → waveformDisplayRows for the
    /// panel. The histogram is scopeW*1024*4 ≈ 1–4MB — tiny (no full-frame readback).
    private let gpuLumaBins = 1024

    /// Track the scope's rendered slot width so the per-column histogram resolution
    /// scales with display width (wider scope -> finer detail, no upscaling smear).
    func setDisplayWidth(_ width: CGFloat) {
        let w = scopeBucketWidth(width, min: minColumns, max: maxColumns)
        if w != columns { columns = w }
    }

    // Render-coupled sampling state (all touched only on main). `active` = this scope is
    // visible and should sample. `sampling` = a compute cycle is in flight (the one-in-
    // flight gate). `pendingSample` = a frame rendered while sampling — coalesce and
    // re-sample the LATEST frame once the in-flight cycle publishes (so the final frame of
    // a burst / a paused frame is never missed).
    private var active = false
    private var sampling = false
    private var pendingSample = false
    /// One-shot publish suppressor: set by clear() on a source teardown so a GPU sample already in
    /// flight can't republish the old trace after the panel is blanked. Reset when a genuinely new
    /// sample cycle begins (startSample), so a new source's frames draw normally.
    private var cleared = false

    /// Live pref-coupling: re-sample the current frame when a scope-display preference
    /// changes (intensity/gain/trace color/scale…) so a paused colorist sees the trace
    /// respond without needing a render. All scope prefs are @AppStorage, which does NOT
    /// drive Preferences.objectWillChange — so we observe UserDefaults.didChangeNotification
    /// (posted AFTER the write, so the re-sample reads the NEW value). Coalesced by the
    /// existing gate; no separate throttle. Active only while the scope is visible.
    private var prefsObserver: AnyCancellable?

    /// Process EVERY source row (full-res). Cheap on the GPU (the kernel is the fast part)
    /// and yields a denser, more accurate trace, especially for thin features (fine text,
    /// single-pixel edges).
    private let gpuRowStride = 1

    /// Mark the scope visible and sample the current offscreen frame once (covers opening
    /// the tray while paused — the offscreen already holds the current frame). Sampling is
    /// otherwise driven by the renderer's per-frame callback (frameRendered) plus a
    /// preference-change re-sample (below), not a timer.
    func start() {
        active = true
        if prefsObserver == nil {
            prefsObserver = NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)   // deliver on main; value is already written
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

    /// Render-coupled trigger: called by MetalVideoRenderer on the CVDisplayLink render
    /// thread right after a new frame is written to the offscreen. Hops to main so the gate
    /// + Preferences reads stay on main; the GPU compute self-commits on its own command
    /// buffer, so this never blocks the render path.
    func frameRendered() {
        DispatchQueue.main.async { [weak self] in self?.requestSample() }
    }

    /// Main-thread entry to the one-in-flight gate. If a cycle is already running, remember
    /// to re-sample when it finishes (coalescing bursts to the latest frame); otherwise
    /// start a cycle now.
    private func requestSample() {
        guard active, renderer != nil else { return }
        if sampling { pendingSample = true; return }
        startSample()
    }

    private func startSample() {
        // The gate is claimed here (main); released on the completion's main hop below.
        guard let renderer else { return }
        sampling = true
        pendingSample = false
        cleared = false   // a real new cycle — allow its publish (supersedes any prior blank request)

        // Snapshot the effective gain on the main thread (Preferences read here):
        // baseGain × this scope's intensity × the global master.
        let gain = baseGain
            * Float(Preferences.shared.waveformIntensity)
            * Float(Preferences.shared.globalScopeIntensity)
        // Trace hue (snapshot on main); brightness stays the intensity's job.
        let color = ScopeColorCodec.rgb(fromHex: Preferences.shared.waveformTraceColorHex)

        // waveformKernel bins the histogram over the GPU-resident offscreen texture; only the
        // small histogram (≤4MB) is read back — no full-frame copy. The trace-build runs right
        // here on the GPU completion thread (a fast -O ScopeTrace call), then hops to main to
        // publish.
        let scopeW = columns
        let bins = gpuLumaBins   // true 10-bit histogram, full source resolution
        let issued = renderer.computeWaveformGPU(scopeW: scopeW, bins: bins, rowStride: gpuRowStride) { [weak self] hist, sw, b in
            guard let self else { return }
            let img = self.buildTraceImage(histogram: hist, scopeW: sw, bins: b, gain: gain, color: color)
            DispatchQueue.main.async {
                if self.active, !self.cleared, let img { self.image = img }
                self.finishSample()
            }
        }
        // If no compute was issued (no frame yet / setup failed), the completion will never
        // fire — release the gate so the next request can try again.
        if !issued { sampling = false }
    }

    /// Release the one-in-flight gate (main) and, if a frame arrived while this cycle was
    /// running, immediately sample the latest offscreen frame — so the final frame of a
    /// burst (or a paused frame) is never left unsampled.
    private func finishSample() {
        sampling = false
        if pendingSample { startSample() }
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

        // Numeric build (downsample → maxCount → LUT → RGBA fill) is in ScopeTrace, compiled
        // -O even in Debug so it's fast during development (it's ~100× slower under -Onone).
        let pixels = ScopeTrace.waveformPixels(histogram: accum, scopeW: scopeW, bins: bins,
                                               displayRows: displayRows, gain: gain,
                                               colorR: color.r, colorG: color.g, colorB: color.b)

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
    /// When shown in a tray slot, the slot's selection binding — makes the header label a picker.
    var slotSelection: Binding<ScopeKind>? = nil
    // Same key as Preferences.scopeScale — @AppStorage here for live graticule updates.
    @AppStorage("scopeScale") private var scopeScale: ScopeScale = .bit10
    // Transfer-aware ruler override, SHARED with parade (one key). Default .auto follows the source.
    @AppStorage("manifold.scope.verticalScale") private var verticalScale: ScopeVerticalScale = .auto

    /// Resolved ruler (auto follows the source transfer, else forced). Drives header + graticule.
    private var activeScale: ActiveVerticalScale {
        resolveVerticalScale(override: verticalScale, transferCode: model.sourceTransferCode)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Header strip: name (left) + intensity slider (right). Own band.
                HStack(spacing: 4) {
                    // Luma is weighted by the SOURCE matrix (colorMatrixCode) — surface it so a
                    // 2020-weighted trace can't silently read as 709. Same code that drives the math.
                    // The transfer-aware suffix annotates the ruler (SDR code / PQ nits / HLG %·nits).
                    ScopeSlotHeader(name: "WAVEFORM",
                                    suffix: valueScopeHeaderSuffix(lead: "luma \(ycbcrMatrixLabel(model.sourceMatrixCode))",
                                                                   active: activeScale, sdrScale: scopeScale,
                                                                   forced: verticalScale != .auto),
                                    selection: slotSelection)
                    ScopeVerticalScaleMenu()
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
            drawActiveValueGraticule(ctx, size: size, active: activeScale, sdrScale: scopeScale)
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

        // Value label on the LEFT edge (standard scope convention — Resolve/broadcast
        // waveforms put the scale on the left). The line still spans full width; only the
        // label anchors left. Plain integer, no thousands separator (see drawGraticuleLabel).
        drawGraticuleLabel(ctx, size: size, y: y, text: String(Int(v)),
                           trailing: false, opacity: graticuleLabelOpacity)
    }
}

// MARK: - HDR (PQ / HLG) graticules — relabel the same code-value axis, trace unchanged

/// Draw a graticule value label in a dark pill at vertical position `y`, anchored to an edge.
/// `trailing == false` → LEFT edge (the primary scale, standard scope convention); true → right
/// edge (used only for a secondary ruler that must stay distinct from the left-side primary).
/// The vertical center is clamped so the full text box stays inside the plot (never clipped).
private func drawGraticuleLabel(_ ctx: GraphicsContext, size: CGSize, y: CGFloat,
                                text: String, trailing: Bool, opacity: Double,
                                fontSize: CGFloat = graticuleLabelFontSize) {
    let resolved = ctx.resolve(
        Text(verbatim: text)
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundColor(.white.opacity(opacity))
    )
    let ts = resolved.measure(in: CGSize(width: 200, height: 100))
    let halfH = ts.height / 2
    let ly = Swift.min(Swift.max(y, halfH), size.height - halfH)
    if trailing {
        let cx = size.width - 4
        let bg = CGRect(x: cx - ts.width - 3, y: ly - halfH - 1, width: ts.width + 6, height: ts.height + 2)
        ctx.fill(Path(roundedRect: bg, cornerRadius: 3), with: .color(.black.opacity(graticuleLabelBackingOpacity)))
        ctx.draw(resolved, at: CGPoint(x: cx, y: ly), anchor: .trailing)
    } else {
        let cx: CGFloat = 4
        let bg = CGRect(x: cx - 3, y: ly - halfH - 1, width: ts.width + 6, height: ts.height + 2)
        ctx.fill(Path(roundedRect: bg, cornerRadius: 3), with: .color(.black.opacity(graticuleLabelBackingOpacity)))
        ctx.draw(resolved, at: CGPoint(x: cx, y: ly), anchor: .leading)
    }
}

/// PQ (ST 2084) NITS graticule. The TRACE is unchanged 10-bit code values; this ONLY relabels
/// the ruler. Each nits level is placed at its ST2084 inverse-EOTF code height (non-linear /
/// perceptual). 203 nits (BT.2408 HDR diffuse/graphics white — the key HDR grading reference)
/// and 100 nits (SDR white) draw brighter/thicker so they stand out.
func drawPQGraticule(_ ctx: GraphicsContext, size: CGSize) {
    for level in pqNitsLevels {
        let norm = pqCodeNormalized(nits: level.nits)   // 0…1 == full-range code fraction == height
        let y = size.height * (1.0 - norm)
        let lineOp: Double
        let lineW: CGFloat
        let labelOp: Double
        switch level.emphasis {
        case .key:    lineOp = 0.60; lineW = 1.0; labelOp = 0.9
        case .strong: lineOp = 0.42; lineW = 1.0; labelOp = 0.8
        case .normal: lineOp = graticuleMajorOpacity; lineW = 0.5; labelOp = graticuleLabelOpacity
        }
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(p, with: .color(.white.opacity(lineOp)), lineWidth: lineW)
        // Nits label on the LEFT edge (standard scope convention); line spans full width.
        drawGraticuleLabel(ctx, size: size, y: y, text: level.label, trailing: false, opacity: labelOp)
    }
}

/// HLG graticule. PRIMARY (dominant): HLG signal % (0–100%) at 0/25/50/75/100 — the signal axis
/// maps ~directly to the code range, so % ≈ code fraction. SECONDARY: nits assuming a nominal
/// 1000-nit peak display (via the HLG OOTF/EOTF), as a fainter reference. The dominant % labels
/// anchor LEFT (standard scope convention); the nits secondary anchors RIGHT so the two rulers
/// stay visually distinct and never collide. Trace unchanged — graticule only.
func drawHLGGraticule(_ ctx: GraphicsContext, size: CGSize) {
    // PRIMARY — HLG signal %: full-width lines, dominant labels on the LEFT edge.
    for pct in [0.0, 25.0, 50.0, 75.0, 100.0] {
        let y = size.height * (1.0 - pct / 100.0)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(p, with: .color(.white.opacity(graticuleMajorOpacity)), lineWidth: 0.5)
        drawGraticuleLabel(ctx, size: size, y: y, text: "\(Int(pct))%", trailing: false, opacity: graticuleLabelOpacity)
    }
    // SECONDARY — nits @1000-nit peak: fainter short edge ticks, labels on the RIGHT edge
    // (opposite the dominant % scale) so the practical nits reference reads clearly apart.
    for nits in hlgNitsLevels {
        let ep = hlgSignalForNits(nits)   // signal 0…1 == height fraction
        let y = size.height * (1.0 - ep)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: 28, y: y))
        p.move(to: CGPoint(x: size.width - 28, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(p, with: .color(.cyan.opacity(0.28)), lineWidth: 0.5)
        drawGraticuleLabel(ctx, size: size, y: y, text: "\(Int(nits))", trailing: true, opacity: 0.5)
    }
}

/// Draw the active transfer-aware graticule onto a value-axis scope. Dispatches on the RESOLVED
/// ruler; SDR falls through to the existing (unchanged) %/code graticule. Shared by waveform +
/// parade so both annotate the same axis identically.
func drawActiveValueGraticule(_ ctx: GraphicsContext, size: CGSize,
                              active: ActiveVerticalScale, sdrScale: ScopeScale) {
    switch active {
    case .sdr: drawValueGraticule(ctx, size: size, scale: sdrScale)
    case .pq:  drawPQGraticule(ctx, size: size)
    case .hlg: drawHLGGraticule(ctx, size: size)
    }
}

// MARK: - Shared vertical-scale gear menu (waveform + parade)

/// Gear menu for the shared transfer-aware vertical scale (Auto / SDR / PQ / HLG), placed in BOTH
/// the waveform and parade headers. Reads/writes the single @AppStorage("manifold.scope.verticalScale")
/// so the two scopes stay in lock-step (one setting, one axis). Mirrors the vectorscope's gear-menu
/// pattern; overlay-only — picking a scale re-labels the ruler without touching the trace math.
struct ScopeVerticalScaleMenu: View {
    @AppStorage("manifold.scope.verticalScale") private var verticalScale: ScopeVerticalScale = .auto
    var body: some View {
        Menu {
            Section("Vertical scale · transfer") {
                Picker("Vertical scale", selection: $verticalScale) {
                    ForEach(ScopeVerticalScale.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Vertical scale: Auto follows the source transfer (PQ→nits, HLG→%/nits); force a ruler to annotate untagged media or A/B. The trace never changes.")
    }
}
