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
/// Only P3-D65 (12) and Rec.2020 (9) have an entry. Every other code returns nil: 1 needs none, and
/// 5, 6 and 11 are left to S3, where primaries are handled independently (§6.11). Built from the
/// published xy primaries and D65, so there is no hand-typed matrix to get wrong.
public enum ReferenceGamut {
    public typealias Matrix3 = [[Double]]

    public static func toRec709(fromPrimariesCode code: Int?) -> Matrix3? {
        switch code {
        case 12: return conversion(from: p3D65, to: rec709)
        case 9:  return conversion(from: rec2020, to: rec709)
        default: return nil
        }
    }

    /// xy of R, G, B.
    public typealias Primaries = [(Double, Double)]
    public static let rec709: Primaries  = [(0.640, 0.330), (0.300, 0.600), (0.150, 0.060)]
    public static let p3D65: Primaries   = [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)]
    public static let rec2020: Primaries = [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)]
    public static let d65 = (0.3127, 0.3290)

    public static func conversion(from src: Primaries, to dst: Primaries) -> Matrix3 {
        multiply(inverse(rgbToXYZ(dst)), rgbToXYZ(src))
    }

    static func rgbToXYZ(_ p: Primaries) -> Matrix3 {
        func xyz(_ xy: (Double, Double)) -> [Double] { [xy.0 / xy.1, 1, (1 - xy.0 - xy.1) / xy.1] }
        let cols = p.map(xyz)
        let m: Matrix3 = (0..<3).map { r in (0..<3).map { c in cols[c][r] } }
        let s = apply(inverse(m), xyz(d65))
        return (0..<3).map { r in (0..<3).map { c in m[r][c] * s[c] } }
    }

    public static func apply(_ m: Matrix3, _ v: [Double]) -> [Double] {
        (0..<3).map { r in (0..<3).reduce(0.0) { $0 + m[r][$1] * v[$1] } }
    }

    static func multiply(_ a: Matrix3, _ b: Matrix3) -> Matrix3 {
        (0..<3).map { r in (0..<3).map { c in (0..<3).reduce(0.0) { $0 + a[r][$1] * b[$1][c] } } }
    }

    static func inverse(_ m: Matrix3) -> Matrix3 {
        let c00 = m[1][1] * m[2][2] - m[1][2] * m[2][1]
        let c01 = m[0][2] * m[2][1] - m[0][1] * m[2][2]
        let c02 = m[0][1] * m[1][2] - m[0][2] * m[1][1]
        let c10 = m[1][2] * m[2][0] - m[1][0] * m[2][2]
        let c11 = m[0][0] * m[2][2] - m[0][2] * m[2][0]
        let c12 = m[0][2] * m[1][0] - m[0][0] * m[1][2]
        let c20 = m[1][0] * m[2][1] - m[1][1] * m[2][0]
        let c21 = m[0][1] * m[2][0] - m[0][0] * m[2][1]
        let c22 = m[0][0] * m[1][1] - m[0][1] * m[1][0]
        let det = m[0][0] * c00 + m[0][1] * c10 + m[0][2] * c20
        return [[c00 / det, c01 / det, c02 / det],
                [c10 / det, c11 / det, c12 / det],
                [c20 / det, c21 / det, c22 / det]]
    }
}

// `pow` without importing Foundation into every client of this target.
#if canImport(Darwin)
import Darwin
@inline(__always) func Foundation_pow(_ x: Double, _ y: Double) -> Double { Darwin.pow(x, y) }
#else
import Glibc
@inline(__always) func Foundation_pow(_ x: Double, _ y: Double) -> Double { Glibc.pow(x, y) }
#endif
