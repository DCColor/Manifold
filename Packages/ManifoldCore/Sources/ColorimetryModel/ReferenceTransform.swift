//
//  ReferenceTransform.swift
//  ColorimetryModel
//
//  The arithmetic behind the Reference display transform (colour S1, docs/COLOR_MANAGEMENT_FINDINGS.md
//  §6.11): the BT.1886 EOTF from a display's white and black luminance, the per-display calibration
//  record it reads them from, and the primaries conversion a display calibrated to Rec.709 needs. In
//  the package so `swift test` reaches it; the shader (`displayReferenceFragment`) evaluates the same
//  formulas from the coefficients computed here.
//

/// What one display was calibrated to, stated by the user (§6.6: the app cannot detect it).
///
/// Stored per display. **Default: not calibrated, Lw 100, Lb 0** — Lb 0 makes BT.1886 exactly
/// gamma 2.4 (§6.11, decision 2).
public struct DisplayCalibration: Codable, Equatable, Sendable {
    /// The display applies Rec.709 / BT.1886 in its own hardware, so Reference sends the code values
    /// untouched and Lb / Lw are the display's business, not Manifold's.
    public var calibrated: Bool
    /// Lw, cd/m².
    public var whiteNits: Double
    /// Lb, cd/m².
    public var blackNits: Double

    public static let defaultWhiteNits = 100.0
    public static let defaultBlackNits = 0.0
    public static let standard = DisplayCalibration(calibrated: false,
                                                    whiteNits: defaultWhiteNits,
                                                    blackNits: defaultBlackNits)

    public init(calibrated: Bool, whiteNits: Double, blackNits: Double) {
        self.calibrated = calibrated
        self.whiteNits = whiteNits
        self.blackNits = blackNits
    }

    /// Values a BT.1886 curve can be built from: Lw > 0 and 0 ≤ Lb < Lw, finite. Anything else
    /// falls back to the default for that field, so a typo in a text field can never produce NaN.
    public var sanitized: DisplayCalibration {
        var c = self
        if !(c.whiteNits.isFinite && c.whiteNits > 0) { c.whiteNits = Self.defaultWhiteNits }
        if !(c.blackNits.isFinite && c.blackNits >= 0 && c.blackNits < c.whiteNits) {
            c.blackNits = Self.defaultBlackNits
        }
        return c
    }
}

/// ITU-R BT.1886 Annex 1, normalised black-to-white:
///
///     L(V) = a · max(V + b, 0)^2.4
///     a = (Lw^(1/2.4) − Lb^(1/2.4))^2.4,   b = Lb^(1/2.4) / (Lw^(1/2.4) − Lb^(1/2.4))
///     D(V) = (L(V) − Lb) / (Lw − Lb)          0 at black, 1 at white
///
/// Computed with Lw normalised to 1 (only Lb / Lw changes the shape). **With Lb = 0, b = 0 and
/// a = 1 exactly, so D(V) = V^2.4** — the identity the S1 predictions test.
public struct BT1886: Equatable, Sendable {
    public static let gamma = 2.4

    /// `a`, with Lw normalised to 1.
    public let a: Double
    public let b: Double
    /// Lb / Lw.
    public let blackRatio: Double

    public init(whiteNits: Double, blackNits: Double) {
        let c = DisplayCalibration(calibrated: false, whiteNits: whiteNits, blackNits: blackNits).sanitized
        let ratio = c.blackNits / c.whiteNits
        let k = ratio > 0 ? Foundation_pow(ratio, 1 / Self.gamma) : 0
        self.a = Foundation_pow(1 - k, Self.gamma)
        self.b = k / (1 - k)
        self.blackRatio = ratio
    }

    public init(_ calibration: DisplayCalibration) {
        self.init(whiteNits: calibration.whiteNits, blackNits: calibration.blackNits)
    }

    /// True when the curve is exactly V^2.4.
    public var isPurePower: Bool { blackRatio == 0 }

    /// D(V), normalised drive: 0 at black, 1 at white. Below black it is clamped to 0, as the shader
    /// does, so a sub-black code can never take a fractional power of a negative number.
    public func drive(_ v: Double) -> Double {
        let l = a * Foundation_pow(max(v + b, 0), Self.gamma)
        return max((l - blackRatio) / (1 - blackRatio), 0)
    }
}

/// The source-primaries → Rec.709 conversion a display calibrated to Rec.709 needs, in linear light.
///
/// Every code with primaries other than 709 in `ColorimetryTable` has an entry: P3-D65 (12), Rec.2020
/// (9) and, since colour S3, DCI-P3 adapted to D65 (11), SMPTE-C (6) and EBU 3213 (5). 1, absent and
/// unknown return nil: those are drawn as 709 and need none. Built from the table's xy, so there is no
/// hand-typed matrix to get wrong and no second copy of the primaries.
public enum ReferenceGamut {
    public typealias Matrix3 = ColorMatrix3

    public static func toRec709(fromPrimariesCode code: Int?) -> Matrix3? {
        ColorPrimaries(cicp: code)?.toRec709
    }

    public static func apply(_ m: Matrix3, _ v: [Double]) -> [Double] { ColorMatrix.apply(m, v) }
}

/// Reference's HLG → PQ transcode (docs/HLG_MACOS_MODE_PLAN.md §6; 0.9.1). Reference is absolute display light, 1.0 = 100 nits;
/// HLG is transcoded to PQ per BT.2408 at a 1000-nit nominal peak, so the layer can be tagged PQ exactly as a PQ source is:
///
///     E  = HLG inverse OETF (E′), per channel          scene-linear, [0, 1] for legal signal
///     Ys = kR·R + kG·G + kB·B                            luminance of the PICTURE primaries
///     F  = Lw · Ys^(γ − 1) · E,  Lw 1000, γ 1.2          cd/m² (BT.2100 OOTF, on luminance: hue kept)
///     out = PQ inverse EOTF (F / 10000), per channel
///
/// HLG 75 % → 203.2 nits (PQ 0.5808); 100 nits is reached at HLG 62.96 %. The shader's mode 2 (`displayReferenceFragment`)
/// evaluates the same formulas from `luminanceWeights`; these tests are the arbiter.
public enum HLGToPQ {
    public static let nominalPeak = 1000.0
    public static let systemGamma = 1.2

    static let a = 0.17883277, b = 0.28466892, c = 0.55991073

    /// HLG inverse OETF (BT.2100): E′ → scene-linear E. Below 0 clamps to 0; above 1 continues the curve.
    public static func inverseOETF(_ e: Double) -> Double {
        let v = max(e, 0)
        return v <= 0.5 ? v * v / 3 : (Foundation_exp((v - c) / a) + b) / 12
    }

    /// The OOTF, in cd/m², for one pixel's scene-linear RGB.
    public static func displayLight(_ rgb: [Double], weights w: [Double]) -> [Double] {
        let ys = w[0] * rgb[0] + w[1] * rgb[1] + w[2] * rgb[2]
        guard ys > 0 else { return [0, 0, 0] }
        let gain = nominalPeak * Foundation_pow(ys, systemGamma - 1)
        return rgb.map { gain * $0 }
    }

    /// PQ inverse EOTF (ST 2084): cd/m² → E′, clamped to [0, 1].
    public static func pqEncode(_ nits: Double) -> Double {
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
        let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let y = Foundation_pow(min(max(nits / 10000, 0), 1), m1)
        return Foundation_pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    /// HLG-encoded R′G′B′ → PQ-encoded R′G′B′.
    public static func transcode(_ rgb: [Double], weights: [Double]) -> [Double] {
        displayLight(rgb.map(inverseOETF), weights: weights).map(pqEncode)
    }

    /// The luminance row (Y of RGB → XYZ) of the primaries as drawn, or nil for primaries the layer cannot be tagged PQ
    /// with (`ColorimetryTable.layerAttachments` falls back to Rec.709 SDR for those, so Reference refuses rather than guess).
    public static func luminanceWeights(primariesCode code: Int?) -> [Double]? {
        guard ColorimetryTable.layerAttachments(primaries: code, transfer: 16, matrix: nil).hdrFallback == nil else { return nil }
        return ColorPrimaries.resolve(code).rendered.rgbToXYZ[1]
    }
}

// `pow` without importing Foundation into every client of this target.
#if canImport(Darwin)
import Darwin
@inline(__always) func Foundation_pow(_ x: Double, _ y: Double) -> Double { Darwin.pow(x, y) }
@inline(__always) func Foundation_exp(_ x: Double) -> Double { Darwin.exp(x) }
#else
import Glibc
@inline(__always) func Foundation_pow(_ x: Double, _ y: Double) -> Double { Glibc.pow(x, y) }
@inline(__always) func Foundation_exp(_ x: Double) -> Double { Glibc.exp(x) }
#endif
