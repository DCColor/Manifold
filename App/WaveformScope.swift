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
let baseGain: Float = 2.0      // dense bins reach full white a bit before the very max (was 1.6, +25%)

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

// MARK: - Label gutter (waveform + parade) — keep the value labels off the trace
//
// The trace used to run edge-to-edge, so the value labels (0 / 128 / … / 1023) sat ON TOP of it
// and were unreadable wherever the signal was bright. The plot region now starts to the right of
// a narrow label column: the trace image is inset by `leading`, the graticule LINES start there
// too, and the labels stay anchored to the panel edge — on clean background. Only the value-axis
// scopes need this; the vectorscope and CIE scopes have no edge label column (their labels ride
// the plotted features), so their geometry is untouched.

/// Horizontal insets of the plot region inside a value-axis scope panel.
struct ScopePlotGutters {
    /// Left label column (the primary ruler — every ruler labels the left edge).
    let leading: CGFloat
    /// Right label column — only HLG, whose secondary nits ruler labels the right edge.
    let trailing: CGFloat
}

/// Rendered width of a graticule label. The labels draw in SF Mono (`.monospaced` design), whose
/// advance is exactly 0.6 em, so character-count × 0.6 × size IS the advance width — no text
/// layout pass on the draw path, and the value is stable frame to frame.
private func graticuleLabelWidth(_ text: String, fontSize: CGFloat = graticuleLabelFontSize) -> CGFloat {
    CGFloat(text.count) * fontSize * 0.6
}

/// Gutter wide enough for the widest of `labels`: the label pill (4pt edge offset + text + 3pt
/// pad — see drawGraticuleLabel) plus 3pt of clearance before the plot starts. Sized to the
/// ACTUAL strings the active ruler draws, so a 3-digit ruler (8-bit / IRE) costs less plot area
/// than PQ's 5-digit "10000" — plot area is precious on a monitoring tool.
private func scopeLabelGutter(widest labels: [String]) -> CGFloat {
    guard let w = labels.map({ graticuleLabelWidth($0) }).max(), w > 0 else { return 0 }
    return ceil(w) + 10
}

/// Plot-region gutters for the active value-axis ruler (waveform + parade share this).
///
/// ⚠️ `userLines` IS NOT OPTIONAL AND HAS NO DEFAULT, ON PURPOSE. The left gutter is what keeps the
/// value labels OFF the trace, and it is sized from the widest label the ruler will actually draw.
/// A user line draws a label too, and its label can be WIDER than any of the ruler's own — a PQ line
/// low in the plot reads "0.05" where the ruler's narrowest is "0.1", and an HLG line reads
/// "75%·203" against a ruler whose widest is "100%". Left out of this calculation, that label runs
/// over the trace. Making the parameter required means a future value-axis scope cannot forget it;
/// it is a compile error rather than a rendering bug. Positions are NORMALIZED heights (0…1).
///
/// Two assumptions inherited from the helpers above, both of which the user labels satisfy because
/// they are drawn by the same `drawGraticuleLabel`: `graticuleLabelWidth` assumes a 0.6 em advance,
/// true only for `.monospaced`; and `scopeLabelGutter`'s `+ 10` encodes that function's pill
/// geometry (4pt edge offset + 3pt pad + 3pt clearance). A user label drawn any other way would
/// need its own width rule.
func scopePlotGutters(active: ActiveVerticalScale, sdrScale: ScopeScale,
                      userLines: [Double]) -> ScopePlotGutters {
    // The SAME strings the draw will render — sized from `userLineLabels`, not approximated.
    let userLabels = userLines.map { userLineLabels(position: $0, active: active, sdrScale: sdrScale) }
    let userLeading = userLabels.map(\.leading)
    let userTrailing = userLabels.compactMap(\.trailing)
    switch active {
    case .sdr:
        return ScopePlotGutters(leading: scopeLabelGutter(widest: sdrScale.majors.map { String(Int($0)) } + userLeading),
                                trailing: 0)
    case .pq:
        return ScopePlotGutters(leading: scopeLabelGutter(widest: pqNitsLevels.map(\.label) + userLeading),
                                trailing: 0)
    case .hlg:
        // Primary % ruler on the left, secondary nits ruler on the right — both get a gutter, and a
        // user line's two labels join the matching side.
        return ScopePlotGutters(leading: scopeLabelGutter(widest: hlgPercentLevels.map { "\(Int($0))%" } + userLeading),
                                trailing: scopeLabelGutter(widest: hlgNitsLevels.map { String(Int($0)) } + userTrailing))
    }
}

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

// MARK: - The INVERSES (normalized height → ruler value), for the user-line readout
//
// Every function above answers "where does this value sit?". A user line is stored the other way
// round — as a NORMALIZED HEIGHT — so its readout needs the opposite direction, and nothing in this
// app had it. All four are closed-form; none needs a numeric solve.
//
// PRIOR ART, AND WHY IT COULD NOT BE CALLED: `PassthroughShader.metal` already carries `ciePqEOTF`
// and `cieHlgInvOETF` for the CIE scope's linearization. They prove the inversion is analytic, and
// the PQ one is the same algebra as `pqNits` below — but they are MSL, running on the GPU, not
// reachable from Swift. They also stop short of what a readout needs: `ciePqEOTF` returns
// NORMALIZED linear and discards the absolute nit scale on purpose ("irrelevant for chromaticity"),
// and `cieHlgInvOETF` deliberately OMITS the display OOTF, which is exactly the half that turns an
// HLG signal into a luminance. So these are written fresh, against the forward functions above.

/// Absolute display luminance in NITS at a normalized PQ code — THE INVERSE of `pqCodeNormalized`.
/// ST 2084 solved for L: L = ((max(E'^(1/m2) − c1, 0)) / (c2 − c3·E'^(1/m2)))^(1/m1), nits = L·10000.
///
/// The denominator cannot vanish for a clamped code: E' ≤ 1 so c2 − c3·E' ≥ c2 − c3 = 0.164, which
/// is why there is no guard here. The `max(…, 0)` on the numerator is load-bearing though — below
/// the PQ code floor E'^(1/m2) dips under c1 and a negative base would make `pow` return NaN.
func pqNits(codeNormalized code: Double) -> Double {
    let m1 = 0.1593017578125
    let m2 = 78.84375
    let c1 = 0.8359375
    let c2 = 18.8515625
    let c3 = 18.6875
    let ep = pow(clampedUnit(code), 1.0 / m2)
    let num = max(ep - c1, 0.0)
    let den = c2 - c3 * ep
    return pow(num / den, 1.0 / m1) * 10000.0
}

/// Scene-linear E at an HLG signal value E′ — the inverse OETF, i.e. the inverse of `hlgSignal`.
/// Branches at E′ = 0.5, which is where the forward function's own branch (scene-linear 1/12) lands:
/// sqrt(3·(1/12)) = 0.5, and the log branch agrees there to 5 decimal places.
private func hlgSceneLinear(signal s: Double) -> Double {
    let a = 0.17883277, b = 0.28466892, c = 0.55991073
    let x = clampedUnit(s)
    if x <= 0.5 { return x * x / 3.0 }
    return (exp((x - c) / a) + b) / 12.0
}

/// Display NITS at an HLG signal value — THE INVERSE of `hlgSignalForNits`, and it must undo BOTH
/// of that function's steps: the OETF (above) and then the OOTF, L ≈ peak·E^γ. Same nominal peak and
/// system gamma as the forward function, so the two round-trip; a different peak here would silently
/// disagree with the secondary nits ruler drawn beside it.
private func hlgNitsForSignal(_ s: Double, peak: Double = 1000.0, gamma: Double = 1.2) -> Double {
    peak * pow(hlgSceneLinear(signal: s), gamma)
}

/// Clamp to the unit interval. User-line positions are normalized heights and every entry point
/// takes one, including values that could have been hand-written into the defaults plist.
@inline(__always)
func clampedUnit(_ v: Double) -> Double { Swift.max(0.0, Swift.min(1.0, v)) }

/// Format a nits value for a label: integers once the value is big enough for a fraction to be
/// noise, more precision as it shrinks.
///
/// ⚠️ THE THRESHOLDS ARE 9.95 AND 0.995, NOT 10 AND 1, AND THE TRAILING ZEROS ARE STRIPPED. Both
/// exist so a user line and the FIXED LADDER spell the same height the same way — the ladder draws
/// "10" and "0.1", and a user line sitting on it must not read "10.0" and "0.10" beside it.
/// Round-tripping 10 nits through the transfer lands a hair BELOW 10 (9.999999999999998), so a bare
/// `>= 10` test drops into the one-decimal branch and renders "10.0"; testing against the value that
/// will round to 10 at zero decimals is the fix. Verified against all eight PQ ladder levels and all
/// five HLG ones — every label matches the ruler's own string exactly.
private func nitsLabel(_ n: Double) -> String {
    guard n.isFinite, n > 0 else { return "0" }
    let dp = n >= 9.95 ? 0 : (n >= 0.995 ? 1 : 2)
    var s = String(format: "%.\(dp)f", n)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return s
}

/// What a user line reads on the ACTIVE ruler. This is the whole point of the inverses above: the
/// line is STORED as a normalized height, and this is the only place that height is interpreted.
///
/// ⚠️ THE LINE DOES NOT MOVE WHEN THIS STRING CHANGES. Switching 8-bit → 10-bit → IRE relabels the
/// same line ("128" → "512" → "50"), because all three are spellings of one normalized value.
/// Switching SDR → PQ relabels it too ("512" → "94"), and that is a change of INTERPRETATION, not a
/// change of position: nits are what a transfer function ASSIGNS to a code, so the same code is a
/// different luminance under PQ than under HLG and is not a luminance at all under SDR. Storing the
/// height rather than the reading is what makes the line mark the SIGNAL.
///
/// ⚠️ HLG RETURNS TWO LABELS, SPLIT THE SAME WAY THE HLG RULER SPLITS ITS OWN. That ruler is two
/// ladders — signal % anchored LEFT, nits @1000-nit peak anchored RIGHT — and a user line sits on
/// both, so it reads on both. Putting the pair in one left-hand label ("75%·203") was the first
/// version and it is worse twice over: it stops matching the ruler it is drawn against, and it
/// widens the LEFT gutter to fit nine characters where the ruler's widest is four, costing plot
/// width on every HLG line. Split, each label joins a gutter that is already sized for that ladder's
/// own strings, and neither gutter grows at all.
private func userLineLabels(position: Double, active: ActiveVerticalScale,
                            sdrScale: ScopeScale) -> (leading: String, trailing: String?) {
    let p = clampedUnit(position)
    switch active {
    case .sdr: return (String(Int((p * sdrScale.rangeMax).rounded())), nil)
    case .pq:  return (nitsLabel(pqNits(codeNormalized: p)), nil)
    case .hlg: return ("\(Int((p * 100).rounded()))%", nitsLabel(hlgNitsForSignal(p)))
    }
}

// MARK: - The user-line FIELD: what unit it edits in, and the two conversions

/// The unit a user-line field edits in on the active ruler, and what counts as a valid entry.
///
/// ⚠️ THIS IS A DISPLAY UNIT, NOT THE STORED ONE. The line is stored as a normalized height and
/// nothing here changes that — the field converts on the way in and on the way out, which is what
/// makes switching the ruler RELABEL the field instead of MOVING the line.
struct UserLineUnit {
    /// Printed after the field. Also what the entry means, so it must name a real ruler unit.
    let suffix: String
    /// Valid entries are 0…this. The lower bound is always 0 — every ruler starts at the plot floor.
    let upperBound: Double
    /// True only where the ruler spans orders of magnitude and a fraction carries information: PQ
    /// nits run from 0.1 to 10000. Code values, IRE and HLG % are integer domains.
    let allowsFractions: Bool
}

/// The active ruler's field unit.
///
/// ⚠️ HLG EDITS IN PERCENT, NOT NITS, THOUGH ITS RULER DRAWS BOTH. Three reasons, in order of
/// weight. (1) Percent is the PRIMARY ladder — `drawHLGGraticule` labels it left and dominant and
/// calls nits "secondary ... fainter". (2) Percent is EXACT: for HLG the signal value IS the
/// normalized height, so percent is that stored number with the point moved, and a typed 75 round
/// trips to exactly 75. (3) Nits for HLG is not a property of the signal at all — it exists only
/// under an assumed 1000-nit peak display and γ 1.2 (see `hlgSignalForNits`'s defaults), so a typed
/// nit value would silently bake a display assumption into stored data. The nits reading is not
/// lost: `userLineLabels` still prints it on the line's right-hand label, where the ruler puts it.
func userLineUnit(active: ActiveVerticalScale, sdrScale: ScopeScale) -> UserLineUnit {
    switch active {
    case .sdr:
        return UserLineUnit(suffix: sdrScale == .ire ? "IRE" : "code",
                            upperBound: sdrScale.rangeMax, allowsFractions: false)
    case .pq:
        return UserLineUnit(suffix: "nits", upperBound: 10000, allowsFractions: true)
    case .hlg:
        return UserLineUnit(suffix: "%", upperBound: 100, allowsFractions: false)
    }
}

/// Normalized height → the number the field shows. The same interpretation `userLineLabels` draws,
/// as a value rather than a string, so the field and the line's own label can never disagree.
func userLineFieldValue(position: Double, active: ActiveVerticalScale, sdrScale: ScopeScale) -> Double {
    let p = clampedUnit(position)
    switch active {
    case .sdr: return p * sdrScale.rangeMax
    case .pq:  return pqNits(codeNormalized: p)
    case .hlg: return p * 100
    }
}

/// A typed value → the normalized height to store. The exact inverse of `userLineFieldValue`, which
/// for PQ means the FORWARD transfer function: the field is in nits, storage is in code, and
/// `pqCodeNormalized` is the map between them. Not clamped here — the caller decides what to do with
/// an out-of-range entry, and this one silently coercing is precisely what it must not do.
func userLineNormalized(fieldValue v: Double, active: ActiveVerticalScale, sdrScale: ScopeScale) -> Double {
    switch active {
    case .sdr: return sdrScale.rangeMax > 0 ? v / sdrScale.rangeMax : 0
    case .pq:  return pqCodeNormalized(nits: v)
    case .hlg: return v / 100
    }
}

/// Line-emphasis tiers for the HDR graticules: normal, strong (SDR white 100 nits), key
/// (BT.2408 HDR diffuse/graphics white 203 nits — the primary grading reference).
enum GratEmphasis { case normal, strong, key }

/// The line + label style for an emphasis tier. Extracted from the inline switch in
/// `drawPQGraticule` so a user line can ask for `.key` BY NAME and get literally the same weight the
/// 203-nit line draws at, rather than a second copy of three numbers that agree until someone tunes
/// one of them. `.normal` defers to the shared graticule constants; `.strong` and `.key` are the two
/// deliberate steps above them.
func graticuleEmphasisStyle(_ e: GratEmphasis) -> (lineOpacity: Double, lineWidth: CGFloat, labelOpacity: Double) {
    switch e {
    case .key:    return (0.60, 1.0, 0.9)
    case .strong: return (0.42, 1.0, 0.8)
    case .normal: return (graticuleMajorOpacity, 0.5, graticuleLabelOpacity)
    }
}

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

/// HLG PRIMARY signal-% ladder (left-edge ruler) — the signal axis maps ~directly to the code
/// range, so % ≈ code fraction. Named (not inlined in the draw) so the label gutter can be sized
/// from the same strings the draw renders.
let hlgPercentLevels: [Double] = [0, 25, 50, 75, 100]

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

    // ── This scope's two user reference lines ───────────────────────────────────────────────
    //
    // Four scalar keys on the `outerTicks` precedent: dotted names, declared here in the view,
    // nothing in Preferences, no JSON store — two lines is not a collection. The `manifold.waveform.`
    // prefix is what keeps them SEPARATE from the parade's identically-shaped set; the two scopes
    // share the drawing code and share nothing else. Off by default, like every graticule extra.
    //
    // ⚠️ THE POSITION IS A NORMALIZED HEIGHT (0 = bottom of the plot, 1 = top), NOT A NIT OR A CODE
    // VALUE. 8-bit, 10-bit and IRE are three spellings of one normalized value, so a line stored
    // this way does not move when the ruler changes — only `userLineLabels`' reading of it does.
    @AppStorage("manifold.waveform.line1.enabled")  private var line1On = false
    @AppStorage("manifold.waveform.line1.position") private var line1Position = 0.50
    @AppStorage("manifold.waveform.line2.enabled")  private var line2On = false
    @AppStorage("manifold.waveform.line2.position") private var line2Position = 0.75

    /// The enabled lines' positions, in draw order. The ONE value handed to both `scopePlotGutters`
    /// and `drawActiveValueGraticule`: they must agree, or the gutter is sized for labels the draw
    /// never renders — or, worse, not sized for ones it does.
    private var userLines: [Double] {
        var v: [Double] = []
        if line1On { v.append(line1Position) }
        if line2On { v.append(line2Position) }
        return v
    }

    /// Resolved ruler (auto follows the source transfer, else forced). Drives header + graticule.
    private var activeScale: ActiveVerticalScale {
        resolveVerticalScale(override: verticalScale, transferCode: model.sourceTransferCode)
    }

    /// Label-column insets for the active ruler — the trace starts past them so the value labels
    /// stay on clean background instead of on top of a bright trace.
    private var gutters: ScopePlotGutters {
        scopePlotGutters(active: activeScale, sdrScale: scopeScale, userLines: userLines)
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
                    ScopeValueAxisGear(line1On: $line1On, line1Position: $line1Position,
                                       line2On: $line2On, line2Position: $line2Position,
                                       active: activeScale, sdrScale: scopeScale)
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
                            // Start the trace to the RIGHT of the label column (and left of the
                            // right-hand one, when a ruler uses it) so the labels stay readable.
                            .padding(.leading, gutters.leading)
                            .padding(.trailing, gutters.trailing)
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
        // The Canvas spans the FULL panel width (no leading padding): the lines are inset by the
        // gutters, but the labels anchor to the panel edge so they land in the gutter.
        let g = gutters
        return Canvas { ctx, size in
            drawActiveValueGraticule(ctx, size: size, active: activeScale, sdrScale: scopeScale,
                                     gutters: g, userLines: userLines)
        }
    }
}

/// Two-tier value-axis graticule shared by waveform + parade: labeled MAJOR lines (brighter)
/// spanning the plot region + short unlabeled MINOR edge ticks (fainter). Positions come from
/// the selected scale, mapped value/rangeMax -> normalized height. Lines span the PLOT region
/// (inside `gutters`), never the label column — the labels sit in the gutter on clean background.
func drawValueGraticule(_ ctx: GraphicsContext, size: CGSize, scale: ScopeScale,
                        gutters: ScopePlotGutters) {
    let maxV = scale.rangeMax
    guard maxV > 0 else { return }
    let x0 = gutters.leading
    let x1 = size.width - gutters.trailing

    // Minor ticks: short marks at both plot edges (reduces clutter vs full-width lines).
    for v in scale.minors {
        let y = size.height * (1.0 - v / maxV)
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x0 + 6, y: y))
        p.move(to: CGPoint(x: x1 - 6, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(p, with: .color(.white.opacity(graticuleMinorOpacity)), lineWidth: 0.5)
    }

    // Major lines: full plot width + value label (larger, brighter, on a dark backing).
    for v in scale.majors {
        let y = size.height * (1.0 - v / maxV)
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(p, with: .color(.white.opacity(graticuleMajorOpacity)), lineWidth: 0.5)

        // Value label in the LEFT gutter (standard scope convention — Resolve/broadcast
        // waveforms put the scale on the left). Plain integer, no thousands separator.
        drawGraticuleLabel(ctx, size: size, y: y, text: String(Int(v)),
                           trailing: false, opacity: graticuleLabelOpacity)
    }
}

// MARK: - HDR (PQ / HLG) graticules — relabel the same code-value axis, trace unchanged

/// Draw a graticule value label in a dark pill at vertical position `y`, anchored to an edge.
/// `trailing == false` → LEFT edge (the primary scale, standard scope convention); true → right
/// edge (used only for a secondary ruler that must stay distinct from the left-side primary).
/// The vertical center is clamped so the full text box stays inside the plot (never clipped).
/// Labels anchor to the PANEL edge and therefore land inside the label gutter (see
/// ScopePlotGutters / scopeLabelGutter, which is sized from these same strings + this pill's
/// 4pt edge offset and 3pt padding) — clear of the trace, which starts past the gutter.
///
/// ── INTERNAL, NOT `private`, BECAUSE THE METERS DRAW THE SAME PILL ────────────────────────
///
/// ⚠️ THE FIVE NUMBERS IN HERE — 4 pt edge offset, 3 pt pad, corner radius 3, the ±1 plate bleed,
/// and the end-clamp — ARE THE PILL, and they were briefly hand-copied into AudioMeterScope.swift
/// so the meters' graticule could label its dBFS ruler. A comment saying "keep these in step"
/// does not keep five numbers in step; the same argument that made `graticuleEmphasisStyle` a
/// function rather than a fourth copy of three opacities applies verbatim here, so this is now one
/// implementation with two callers instead. `AudioMeterScopeView.graticule` is the second.
///
/// ⚠️ THE GUTTER IS THE WAVEFORM'S, NOT THIS FUNCTION'S. The paragraph above describes how the
/// value-axis scopes USE these labels, and the meters do not have a label gutter at all — their
/// labels sit directly ON the bars, which is why the backing pill is load-bearing there rather than
/// merely tidy. Nothing in this function assumes a gutter exists; do not add such an assumption.
func drawGraticuleLabel(_ ctx: GraphicsContext, size: CGSize, y: CGFloat,
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
func drawPQGraticule(_ ctx: GraphicsContext, size: CGSize, gutters: ScopePlotGutters) {
    let x0 = gutters.leading
    let x1 = size.width - gutters.trailing
    for level in pqNitsLevels {
        let norm = pqCodeNormalized(nits: level.nits)   // 0…1 == full-range code fraction == height
        let y = size.height * (1.0 - norm)
        let style = graticuleEmphasisStyle(level.emphasis)
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(p, with: .color(.white.opacity(style.lineOpacity)), lineWidth: style.lineWidth)
        // Nits label in the LEFT gutter (standard scope convention); line spans the plot region.
        drawGraticuleLabel(ctx, size: size, y: y, text: level.label, trailing: false,
                           opacity: style.labelOpacity)
    }
}

/// HLG graticule. PRIMARY (dominant): HLG signal % (0–100%) at 0/25/50/75/100 — the signal axis
/// maps ~directly to the code range, so % ≈ code fraction. SECONDARY: nits assuming a nominal
/// 1000-nit peak display (via the HLG OOTF/EOTF), as a fainter reference. The dominant % labels
/// anchor LEFT (standard scope convention); the nits secondary anchors RIGHT so the two rulers
/// stay visually distinct and never collide. Trace unchanged — graticule only.
func drawHLGGraticule(_ ctx: GraphicsContext, size: CGSize, gutters: ScopePlotGutters) {
    let x0 = gutters.leading
    let x1 = size.width - gutters.trailing
    // PRIMARY — HLG signal %: plot-width lines, dominant labels in the LEFT gutter.
    for pct in hlgPercentLevels {
        let y = size.height * (1.0 - pct / 100.0)
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(p, with: .color(.white.opacity(graticuleMajorOpacity)), lineWidth: 0.5)
        drawGraticuleLabel(ctx, size: size, y: y, text: "\(Int(pct))%", trailing: false, opacity: graticuleLabelOpacity)
    }
    // SECONDARY — nits @1000-nit peak: fainter short ticks at the plot edges, labels in the RIGHT
    // gutter (opposite the dominant % scale) so the practical nits reference reads clearly apart.
    for nits in hlgNitsLevels {
        let ep = hlgSignalForNits(nits)   // signal 0…1 == height fraction
        let y = size.height * (1.0 - ep)
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x0 + 28, y: y))
        p.move(to: CGPoint(x: x1 - 28, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(p, with: .color(.cyan.opacity(0.28)), lineWidth: 0.5)
        drawGraticuleLabel(ctx, size: size, y: y, text: "\(Int(nits))", trailing: true, opacity: 0.5)
    }
}

/// Draw the active transfer-aware graticule onto a value-axis scope. Dispatches on the RESOLVED
/// ruler; SDR falls through to the existing (unchanged) %/code graticule. Shared by waveform +
/// parade so both annotate the same axis identically.
func drawActiveValueGraticule(_ ctx: GraphicsContext, size: CGSize,
                              active: ActiveVerticalScale, sdrScale: ScopeScale,
                              gutters: ScopePlotGutters, userLines: [Double]) {
    switch active {
    case .sdr: drawValueGraticule(ctx, size: size, scale: sdrScale, gutters: gutters)
    case .pq:  drawPQGraticule(ctx, size: size, gutters: gutters)
    case .hlg: drawHLGGraticule(ctx, size: size, gutters: gutters)
    }
    // AFTER the ruler, so a user line reads on top of the structure it is measured against — the
    // same ordering decision the vectorscope's skintone axis records. Both scopes reach this one
    // call, so a line drawn here appears on both by construction; the waveform's lines and the
    // parade's differ only by the array that arrives here.
    drawUserLines(ctx, size: size, active: active, sdrScale: sdrScale,
                  gutters: gutters, positions: userLines)
}

/// User-placed reference lines. `positions` are NORMALIZED HEIGHTS (0 = bottom of the plot, 1 = top)
/// and are already filtered to the enabled ones by the caller.
///
/// ⚠️ A NORMALIZED HEIGHT IS THE STORED QUANTITY, AND THAT IS WHY THIS FUNCTION NEEDS NO INVERSE TO
/// POSITION ANYTHING. The height IS the fraction of the plot, exactly as the trace's own 0–1 code
/// values are, so placement is one multiply on every ruler. The inverse is needed only for the
/// LABEL, which is `userLineLabels`' job. Storing nits instead would invert the situation: placement
/// would need a forward map per ruler, and the line would jump whenever the transfer changed.
///
/// Drawn at the `.key` tier — the weight the 203-nit BT.2408 line uses — via the shared
/// `graticuleEmphasisStyle`, because a user line is the same KIND of thing: a reference you put
/// there deliberately and read against, not background structure you look past.
private func drawUserLines(_ ctx: GraphicsContext, size: CGSize,
                           active: ActiveVerticalScale, sdrScale: ScopeScale,
                           gutters: ScopePlotGutters, positions: [Double]) {
    guard !positions.isEmpty else { return }
    let x0 = gutters.leading
    let x1 = size.width - gutters.trailing
    let style = graticuleEmphasisStyle(.key)
    for pos in positions {
        let y = size.height * (1.0 - clampedUnit(pos))
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(p, with: .color(.white.opacity(style.lineOpacity)), lineWidth: style.lineWidth)
        // Both gutters were sized from these exact strings — see scopePlotGutters — so the labels
        // land on clean background rather than on the trace. The trailing one exists only under HLG,
        // whose ruler carries a second ladder on the right.
        let labels = userLineLabels(position: pos, active: active, sdrScale: sdrScale)
        drawGraticuleLabel(ctx, size: size, y: y, text: labels.leading,
                           trailing: false, opacity: style.labelOpacity)
        if let secondary = labels.trailing {
            drawGraticuleLabel(ctx, size: size, y: y, text: secondary,
                               trailing: true, opacity: style.labelOpacity)
        }
    }
}

// MARK: - Shared value-axis gear menu (waveform + parade)

/// What a commit attempt decided. Pure data, so `userLineCommitDecision` can be exercised directly
/// instead of only through a live text field.
enum UserLineCommitOutcome: Equatable {
    /// Nothing was typed, or what was typed means the height already stored. Write NOTHING.
    case unchanged
    /// The buffer was typed under a ruler that is no longer the active one. Write NOTHING.
    case discarded
    /// Unparseable, or outside the ruler's range. Write NOTHING.
    case rejected
    /// A genuinely new normalized height.
    case write(Double)
}

/// THE WHOLE COMMIT DECISION, WITH NO VIEW STATE IN IT — the fix for a bug that could only be
/// diagnosed by reading the preferences plist, because the logic was buried in a `View` where
/// nothing could reach it. Every guard below is here rather than in `UserLineRow.commit()` so it can
/// be tested against the exact sequences that broke it.
///
/// ── 1. IDEMPOTENT: `text != seeded` IS THE ONLY DEFINITION OF "THE USER TYPED SOMETHING" ──
///
/// ⚠️ THE OLD `abs(normalized - position) > 1e-9` GUARD CANNOT DO THIS JOB, AND ASSUMING IT COULD IS
/// THE BUG. That guard asks "is the parsed value different from what is stored", and a value parsed
/// back from a ROUNDED DISPLAY STRING is legitimately different — 378 code shows as "23" nits, and
/// "23" re-derives to 377.68 code. So merely focusing a field and leaving moved the line, every
/// time, with no typing at all. Comparing the BUFFER against WHAT IT WAS SEEDED WITH asks the right
/// question: a buffer nobody edited is byte-identical to its seed, whatever rounding produced it.
///
/// ── 2. THE BUFFER REMEMBERS ITS RULER, AND A STALE ONE IS DISCARDED ───────────────────────
///
/// ⚠️ A BUFFER TYPED UNDER ONE RULER MUST NEVER BE COMMITTED UNDER ANOTHER. The ruler radio rows and
/// these fields share a popover, so clicking a ruler BLURS a focused field — the blur and the ruler
/// change land in the same update and their order is SwiftUI's to choose, not ours. Interpreting the
/// buffer under whatever ruler happens to be current is how "378" typed as a code value becomes 378
/// PQ nits and stores 661 code (measured). Comparing the seeded ruler against the current one makes
/// the guard independent of that ordering.
///
/// DISCARD, NOT REINTERPRET — chosen over converting the entry through the ruler it was typed under.
/// Both are safe from the 661-code failure; the difference is what a half-typed value MEANS. The
/// user did not press Return; they clicked a different control, and treating that as "commit 378"
/// moves the line to a value they never confirmed, then relabels it into units they were not looking
/// at — so the field reads 661 and the line has jumped, from an action that was about the ruler. The
/// two failure modes are not symmetric: discarding costs a retype of something still on screen,
/// reinterpreting silently moves a reference line on a measurement instrument. Discarding is also
/// the behaviour the unfocused case already had, so focused and unfocused now agree.
func userLineCommitDecision(text: String, seeded: String,
                            seededActive: ActiveVerticalScale, seededSdrScale: ScopeScale,
                            active: ActiveVerticalScale, sdrScale: ScopeScale,
                            position: Double) -> UserLineCommitOutcome {
    // (1) Nobody typed anything. This is the guard that makes focus-and-leave a no-op.
    guard text != seeded else { return .unchanged }
    // (2) The ruler moved under the buffer.
    guard seededActive == active, seededSdrScale == sdrScale else { return .discarded }

    let trimmed = text.trimmingCharacters(in: .whitespaces)
    // Locale-aware first (a decimal-comma locale types "0,5"), then the plain parse as a fallback so
    // a "0.5" typed on such a system is still understood.
    let entered = (try? Double(trimmed, format: .number)) ?? Double(trimmed)
    let unit = userLineUnit(active: active, sdrScale: sdrScale)
    guard let v = entered, v.isFinite, v >= 0, v <= unit.upperBound else { return .rejected }

    let normalized = clampedUnit(userLineNormalized(fieldValue: v, active: active, sdrScale: sdrScale))
    // Still worth asking: a retype of the value already there must not cost every scope a GPU
    // re-sample. This is now a genuine no-op test, not a substitute for guard (1).
    guard abs(normalized - position) > 1e-9 else { return .unchanged }
    return .write(normalized)
}

/// One user line's row in the gear popover: a checkbox that draws it, and a field carrying its
/// value IN THE ACTIVE RULER'S UNITS.
///
/// ── WHY THIS IS A STRING BUFFER AND NOT `TextField(value:format:)` ────────────────────────
///
/// ⚠️ THE WRITE MUST HAPPEN ON SUBMIT AND ON BLUR, AND AT NO OTHER TIME. `position` is `@AppStorage`,
/// so every write reaches `UserDefaults` — and every scope model subscribes to
/// `UserDefaults.didChangeNotification` and re-samples the current frame on it (see
/// `WaveformScopeModel.start`). A binding that wrote per keystroke would fire a GPU compute pass per
/// scope per character: typing `203` would place the line at 2, then 20, then 203, with the trace
/// jumping under it twice on the way to the value that was meant. So the field edits a LOCAL STRING
/// and `commit()` is the only thing that ever assigns, called from `.onSubmit` and from focus
/// leaving. This is the one place this deliberately departs from `GuidesPanel`, whose fields write
/// straight through — free there, because guides are a SwiftUI overlay with no GPU behind them.
///
/// The field's own style still follows that panel: `.roundedBorder`, fixed narrow width, centred-ish
/// text, a caption unit beside it.
///
/// ── OUT-OF-RANGE ENTRIES ARE REJECTED, NOT CLAMPED ────────────────────────────────────────
///
/// ⚠️ A REJECTED ENTRY PUTS THE FIELD BACK AND WRITES NOTHING. Clamping would be worse than useless
/// on an instrument: type 2000 on a 10-bit ruler and a clamp gives you a line at 1023 labelled
/// "1023" — the app has quietly answered a different question and the only evidence is a number you
/// have already stopped looking at. The commonest way to land out of range is a UNIT error (typing
/// nits while the ruler is showing code), which is exactly the mistake a clamp hides and a snap-back
/// exposes. Reverting is visible, costs one retype, and never leaves a line somewhere unintended.
struct UserLineRow: View {
    let label: String
    @Binding var isOn: Bool
    /// ⚠️ NORMALIZED HEIGHT, 0…1 — never the number in the field. See `userLineFieldValue`.
    @Binding var position: Double
    let active: ActiveVerticalScale
    let sdrScale: ScopeScale

    /// What is being typed. Not the stored value, and deliberately allowed to disagree with it while
    /// a caret is in the field — that disagreement IS the deferred write.
    @State private var text = ""

    /// ⚠️ THE BUFFER AS IT WAS LAST SEEDED, AND THE RULER IT WAS SEEDED UNDER. Together these are
    /// what make a commit safe: `text != seeded` is the only thing that counts as "the user typed",
    /// and the two ruler fields let a commit tell that the axis moved beneath a half-typed value.
    /// Written ONLY by `seed(from:)`, so they cannot drift out of step with `text`.
    @State private var seeded = ""
    @State private var seededActive: ActiveVerticalScale = .sdr
    @State private var seededSdrScale: ScopeScale = .bit10

    @FocusState private var focused: Bool

    private var unit: UserLineUnit { userLineUnit(active: active, sdrScale: sdrScale) }
    private var displayed: Double { userLineFieldValue(position: position, active: active, sdrScale: sdrScale) }

    var body: some View {
        HStack(spacing: 6) {
            Toggle(label, isOn: $isOn)
                .font(.caption)
                .fixedSize()
            Spacer(minLength: 4)
            TextField("", text: $text)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focused)
                .onSubmit { commit() }
            Text(unit.suffix)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
        }
        // NOT `.disabled(!isOn)`, which is what GuidesPanel does to its dependent controls. A
        // position is a property of the line whether or not the line is being drawn, and setting a
        // value before switching it on is a natural order; a safe-zone slider with the zones off has
        // no such reading. Deliberate divergence, not an oversight.
        .onAppear { reseed() }
        // Re-format when the STORED value changes under us — another window editing the same
        // @AppStorage key, or this row's own commit. Skipped while focused so it cannot overwrite
        // what is being typed.
        .onChange(of: displayed) { _, _ in if !focused { reseed() } }
        // ⚠️ A RULER CHANGE RESEEDS EVEN WHILE FOCUSED, AND THAT IS THE DISCARD. Switching 8-bit →
        // 10-bit → PQ relabels the field (378 → 378 → 23) while the line stays exactly where it is,
        // which is the whole normalized-storage argument made visible. Anything half-typed is
        // dropped rather than carried into units it was not meant for — see `userLineCommitDecision`.
        .onChange(of: active) { _, _ in reseed() }
        .onChange(of: sdrScale) { _, _ in reseed() }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    /// Stored value → field text. Integer rulers print plainly; PQ borrows `nitsLabel`, so the field
    /// spells a value the same way the drawn label does.
    private func format(_ v: Double) -> String {
        unit.allowsFractions ? nitsLabel(v) : String(Int(v.rounded()))
    }

    /// Fill the buffer from a normalized height under the CURRENT ruler, and record both, so a later
    /// commit can tell whether anything was typed and whether the axis has moved since.
    ///
    /// ⚠️ THE ONLY WRITER OF `text`, `seeded`, `seededActive` AND `seededSdrScale`. Setting `text`
    /// anywhere else would leave `seeded` stale, and a stale seed reads as "the user typed
    /// something" — which is the bug this replaced, wearing a different hat.
    private func seed(from height: Double) {
        let s = format(userLineFieldValue(position: height, active: active, sdrScale: sdrScale))
        text = s
        seeded = s
        seededActive = active
        seededSdrScale = sdrScale
    }

    /// Seed from what is actually stored. Takes `position` explicitly rather than reading it back
    /// after a write, because a `@Binding` over `@AppStorage` is not guaranteed to read back the new
    /// value within the same update.
    private func reseed() { seed(from: position) }

    /// The ONLY writer of `position`. Every decision lives in `userLineCommitDecision`; this applies
    /// the answer and nothing more.
    private func commit() {
        switch userLineCommitDecision(text: text, seeded: seeded,
                                      seededActive: seededActive, seededSdrScale: seededSdrScale,
                                      active: active, sdrScale: sdrScale, position: position) {
        case .unchanged, .discarded, .rejected:
            // Nothing stored moves. Put the buffer back to what IS stored, under the ruler now
            // showing — a rejected entry snaps back visibly, a discarded one re-reads in new units.
            reseed()
        case .write(let height):
            position = height
            // Seed from the height just written, not from `position`. Also re-formats, so a PQ nits
            // entry reads back as the nearest code actually kept.
            seed(from: height)
        }
    }
}

/// Gear menu for the value-axis scopes: the shared transfer-aware vertical scale (Auto / SDR / PQ /
/// HLG), and THAT scope's own two user reference lines. Placed in BOTH the waveform and parade
/// headers. Mirrors the vectorscope's gear-menu pattern; overlay-only — nothing here touches the
/// trace math.
///
/// ⚠️ THE TWO HALVES ARE STORED DIFFERENTLY BECAUSE THEY MEAN DIFFERENT THINGS. The vertical scale
/// is ONE @AppStorage key, read directly here: the two scopes annotate the same axis and must stay
/// in lock-step, so sharing the key IS the feature. The USER LINES are the opposite — per-scope and
/// independent, nothing linked — so they arrive as BINDINGS from the view that owns them. That keeps
/// the literal-key @AppStorage declarations in the views (the `outerTicks` precedent) while leaving
/// exactly one copy of this UI, and it is what makes "same feature, separate storage" enforceable:
/// there is no key in here for the two scopes to end up sharing by accident.
///
/// (Was `ScopeVerticalScaleMenu`, then `ScopeValueAxisMenu`. Renamed again with the popover
/// conversion: it is not a menu any more, and a name that says otherwise is how the next person
/// reaches for `Section` and wonders why it renders as a grey bar.)
struct ScopeValueAxisGear: View {
    @AppStorage("manifold.scope.verticalScale") private var verticalScale: ScopeVerticalScale = .auto

    @Binding var line1On: Bool
    @Binding var line1Position: Double
    @Binding var line2On: Bool
    @Binding var line2Position: Double

    /// The RESOLVED ruler and its SDR sub-scale, passed in rather than re-derived. The owning view
    /// already computes these for `gutters` and `drawActiveValueGraticule`, and the field must edit
    /// in the units the line is actually drawn against — deriving them a second time here is how the
    /// two would come to disagree. `active` cannot be computed from `verticalScale` alone anyway: on
    /// `.auto` it depends on the source's transfer code, which only the scope's model carries.
    let active: ActiveVerticalScale
    let sdrScale: ScopeScale

    var body: some View {
        ScopeGear(title: "Vertical scale & reference markers",
                  help: "Vertical scale: Auto follows the source transfer (PQ→nits, HLG→%/nits); force a ruler to annotate untagged media or A/B. Reference markers are this scope's own: type a value in the active ruler's units. Storage is a normalized height, so switching rulers re-labels a marker rather than moving it. The trace never changes.") {
            ScopeGearSectionHeader("Vertical scale · transfer", isFirst: true)
            ForEach(ScopeVerticalScale.allCases) { s in
                ScopeGearRadioRow(label: s.label, selected: verticalScale == s) { verticalScale = s }
            }
            ScopeGearSectionHeader("Reference markers")
            UserLineRow(label: "Marker 1", isOn: $line1On, position: $line1Position,
                        active: active, sdrScale: sdrScale)
            UserLineRow(label: "Marker 2", isOn: $line2On, position: $line2Position,
                        active: active, sdrScale: sdrScale)
        }
    }
}
