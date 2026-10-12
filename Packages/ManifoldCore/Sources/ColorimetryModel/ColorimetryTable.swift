//
//  ColorimetryTable.swift
//  ColorimetryModel
//
//  THE one table of what each CICP code means to the picture (colour S3, docs/COLOR_MANAGEMENT_FINDINGS.md
//  §6.11): primaries, transfer curve and YCbCr matrix, EACH AXIS ON ITS OWN. The renderer's
//  `makeColorSpace` builds the layer's colorspace from it, the CIE scope takes its RGB→XYZ matrix and
//  its linearising curve from it, the vectorscope's user targets and the Reference transform's gamut
//  conversion take their primaries from it, and the readout takes its names from it. No second copy.
//
//  ── WHY ONE TABLE, AND WHY PER AXIS ───────────────────────────────────────────────────────
//
//  `makeColorSpace` used to enumerate (primaries, transfer) PAIRS: (12, _), (9, 16), (9, 18), (1, 1),
//  else 709. Every pair not listed fell to the default arm, so Rec.2020 SDR (9, 1) and (9, 14),
//  DCI-P3 (11), SMPTE-C (6) and EBU (5) were all shown with 709 primaries, with nothing to say so
//  (§7.3; S0 measured all five). The CIE scope kept its own table, which put 11 on P3-D65 and 5 / 6 on
//  709. Handling each axis on its own, from one table, gives every code its own value and leaves the
//  five pairs that worked byte-for-byte as they were (S0, measured CFEqual).
//

import CoreVideo

// MARK: - Chromaticities

/// CIE 1931 xy.
public struct Chromaticity: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    /// XYZ with Y = 1.
    var xyz: [Double] { [x / y, 1, (1 - x - y) / y] }
}

/// Three primaries and a white point.
public struct PrimariesSet: Equatable, Sendable {
    public let red: Chromaticity
    public let green: Chromaticity
    public let blue: Chromaticity
    public let white: Chromaticity

    public init(red: Chromaticity, green: Chromaticity, blue: Chromaticity, white: Chromaticity) {
        self.red = red; self.green = green; self.blue = blue; self.white = white
    }

    public static let d65 = Chromaticity(0.3127, 0.3290)
    public static let dciWhite = Chromaticity(0.314, 0.351)

    /// Linear RGB → XYZ (row-major), the SMPTE RP 177 construction: each primary's unit-luminance XYZ,
    /// scaled so the three sum to the white point.
    public var rgbToXYZ: ColorMatrix3 {
        let cols = [red.xyz, green.xyz, blue.xyz]
        let m: ColorMatrix3 = (0..<3).map { r in (0..<3).map { c in cols[c][r] } }
        let s = ColorMatrix.apply(ColorMatrix.inverse(m), white.xyz)
        return (0..<3).map { r in (0..<3).map { c in m[r][c] * s[c] } }
    }

    /// The same primaries with the white moved to `target` by Bradford chromatic adaptation —
    /// "relative colorimetric": the source's white is shown as the target's white.
    public func adapted(to target: Chromaticity) -> PrimariesSet {
        guard white != target else { return self }
        let cat = ColorMatrix.bradford(from: white, to: target)
        func move(_ c: Chromaticity) -> Chromaticity {
            let v = ColorMatrix.apply(cat, c.xyz)
            let s = v[0] + v[1] + v[2]
            return Chromaticity(v[0] / s, v[1] / s)
        }
        return PrimariesSet(red: move(red), green: move(green), blue: move(blue), white: target)
    }
}

public typealias ColorMatrix3 = [[Double]]

/// 3×3 arithmetic, enough for gamut conversions.
public enum ColorMatrix {
    public static func apply(_ m: ColorMatrix3, _ v: [Double]) -> [Double] {
        (0..<3).map { r in (0..<3).reduce(0.0) { $0 + m[r][$1] * v[$1] } }
    }

    public static func multiply(_ a: ColorMatrix3, _ b: ColorMatrix3) -> ColorMatrix3 {
        (0..<3).map { r in (0..<3).map { c in (0..<3).reduce(0.0) { $0 + a[r][$1] * b[$1][c] } } }
    }

    public static func inverse(_ m: ColorMatrix3) -> ColorMatrix3 {
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

    /// Linear-light conversion between two primaries sets (through XYZ, no white adaptation: both
    /// sets passed here are D65 in this app).
    public static func conversion(from src: PrimariesSet, to dst: PrimariesSet) -> ColorMatrix3 {
        multiply(inverse(dst.rgbToXYZ), src.rgbToXYZ)
    }

    /// Bradford chromatic adaptation, XYZ → XYZ.
    static func bradford(from src: Chromaticity, to dst: Chromaticity) -> ColorMatrix3 {
        let b: ColorMatrix3 = [[0.8951, 0.2664, -0.1614],
                               [-0.7502, 1.7135, 0.0367],
                               [0.0389, -0.0685, 1.0296]]
        let s = apply(b, src.xyz), d = apply(b, dst.xyz)
        let scale: ColorMatrix3 = [[d[0] / s[0], 0, 0], [0, d[1] / s[1], 0], [0, 0, d[2] / s[2]]]
        return multiply(inverse(b), multiply(scale, b))
    }
}

// MARK: - Primaries

/// A CICP `colour_primaries` code as the picture uses it.
public enum ColorPrimaries: CaseIterable, Equatable, Sendable {
    case rec709        // 1
    case ebu3213       // 5 — BT.470BG, EBU Tech 3213 (625-line)
    case smpteC        // 6 — SMPTE 170M / SMPTE-C (525-line)
    case rec2020       // 9
    case dciP3         // 11 — DCI-P3, DCI white
    case p3D65         // 12 — Display P3 / P3-D65

    /// The entry a code names, or nil when the app has none for it (unspecified, reserved, or a code
    /// with no CoreVideo constant: 4, 7, 8, 10, 22).
    public init?(cicp code: Int?) {
        switch code {
        case 1:  self = .rec709
        case 5:  self = .ebu3213
        case 6:  self = .smpteC
        case 9:  self = .rec2020
        case 11: self = .dciP3
        case 12: self = .p3D65
        default: return nil
        }
    }

    /// What the picture is drawn with for `code`: its own entry, else Rec.709 — the fallback every
    /// CICP reader in this app takes for an absent or unknown code.
    public static func resolve(_ code: Int?) -> ColorPrimaries { ColorPrimaries(cicp: code) ?? .rec709 }

    public var cicp: Int {
        switch self {
        case .rec709:  return 1
        case .ebu3213: return 5
        case .smpteC:  return 6
        case .rec2020: return 9
        case .dciP3:   return 11
        case .p3D65:   return 12
        }
    }

    /// The published chromaticities, with the standard's own white.
    public var published: PrimariesSet {
        switch self {
        case .rec709:
            return PrimariesSet(red: .init(0.640, 0.330), green: .init(0.300, 0.600),
                                blue: .init(0.150, 0.060), white: PrimariesSet.d65)
        case .ebu3213:
            return PrimariesSet(red: .init(0.640, 0.330), green: .init(0.290, 0.600),
                                blue: .init(0.150, 0.060), white: PrimariesSet.d65)
        case .smpteC:
            return PrimariesSet(red: .init(0.630, 0.340), green: .init(0.310, 0.595),
                                blue: .init(0.155, 0.070), white: PrimariesSet.d65)
        case .rec2020:
            return PrimariesSet(red: .init(0.708, 0.292), green: .init(0.170, 0.797),
                                blue: .init(0.131, 0.046), white: PrimariesSet.d65)
        case .dciP3:
            return PrimariesSet(red: .init(0.680, 0.320), green: .init(0.265, 0.690),
                                blue: .init(0.150, 0.060), white: PrimariesSet.dciWhite)
        case .p3D65:
            return PrimariesSet(red: .init(0.680, 0.320), green: .init(0.265, 0.690),
                                blue: .init(0.150, 0.060), white: PrimariesSet.d65)
        }
    }

    /// The primaries the picture is DRAWN with: every entry on D65. DCI-P3 is the only one that
    /// moves — CoreVideo builds code 11 as DCI-P3 Bradford-adapted to D65 (S0, measured to 4
    /// decimals), so the DCI white is shown as display white. The scopes and the gamut conversions use
    /// the same set, so they describe the picture that is shown.
    public var rendered: PrimariesSet { published.adapted(to: PrimariesSet.d65) }

    /// What the readout and the inspector call it.
    public var name: String {
        switch self {
        case .rec709:  return "Rec. 709"
        case .ebu3213: return "EBU 3213"
        case .smpteC:  return "SMPTE-C"
        case .rec2020: return "Rec. 2020"
        case .dciP3:   return "DCI-P3"
        case .p3D65:   return "P3 D65"
        }
    }

    /// The chain readout's name: `name`, plus how it is drawn when that is not the standard's own
    /// statement.
    public var renderedName: String {
        self == .dciP3 ? "DCI-P3 adapted to D65" : name
    }

    /// The CoreVideo attachment.
    public var coreVideo: CFString {
        switch self {
        case .rec709:  return kCVImageBufferColorPrimaries_ITU_R_709_2
        case .ebu3213: return kCVImageBufferColorPrimaries_EBU_3213
        case .smpteC:  return kCVImageBufferColorPrimaries_SMPTE_C
        case .rec2020: return kCVImageBufferColorPrimaries_ITU_R_2020
        case .dciP3:   return kCVImageBufferColorPrimaries_DCI_P3
        case .p3D65:   return kCVImageBufferColorPrimaries_P3_D65
        }
    }

    /// Linear RGB in these (rendered) primaries → linear Rec.709. nil for Rec.709 itself.
    public var toRec709: ColorMatrix3? {
        self == .rec709 ? nil : ColorMatrix.conversion(from: rendered, to: ColorPrimaries.rec709.rendered)
    }
}

// MARK: - Transfer

/// A CICP `transfer_characteristics` code as the picture uses it.
public enum TransferCurve: CaseIterable, Equatable, Sendable {
    /// BT.709's curve, under the four codes that name it: 1 (BT.709), 6 (BT.601), 14 and 15
    /// (BT.2020 10- and 12-bit). Same OETF in all four.
    case bt709
    case pq            // 16
    case hlg           // 18

    public init?(cicp code: Int?) {
        switch code {
        case 1, 6, 14, 15: self = .bt709
        case 16:           self = .pq
        case 18:           self = .hlg
        default:           return nil
        }
    }

    /// What the picture is drawn with. Unknown and absent codes take the 709 curve, as before S3.
    ///
    /// ⚠️ sRGB (13), linear (8) and the other codes with no entry are DRAWN with the 709 curve on the
    /// display, exactly as before S3 — not changed here, because no S3 prediction covers them (§6.11,
    /// *Open after S3*). The CIE scope linearises 13 with the sRGB curve (`ScopeCurve`), as it did.
    public static func resolve(_ code: Int?) -> TransferCurve { TransferCurve(cicp: code) ?? .bt709 }

    /// The CoreVideo attachment the LAYER's colorspace is built with.
    ///
    /// ⚠️ 14 AND 15 ARE ATTACHED AS `ITU_R_709_2`, NOT `ITU_R_2020`. They are the 709 curve, and the
    /// layer's colorspace is about the curve. Measured (S3 probe, `build/colour-s3/s3-probe.txt`):
    /// `ITU_R_2020` builds a different profile ("UHD", "nclc (1,14,1)") with the same γ1.961 but primaries
    /// and white rounded differently in the 4th decimal, so (1, 14) and (12, 14) would have stopped
    /// being byte-identical to (1, 1) and (12, 1) for no change in meaning, and (9, 14) would differ
    /// from (9, 1). Spelled as 709 here, (9, 14) builds exactly (9, 1)'s space. The source's own code
    /// is still what the readout and the buffer tags say.
    public var coreVideo: CFString {
        switch self {
        case .bt709: return kCVImageBufferTransferFunction_ITU_R_709_2
        case .pq:    return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hlg:   return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
    }

    public var isHDR: Bool { self != .bt709 }
}

/// The curve the CIE scope linearises with, as the shader numbers it (`cieLinearize`).
public enum ScopeCurve: Int32, Sendable {
    case power24 = 0     // 709 family and unknown: γ2.4 (BT.1886 with Lb 0)
    case srgb = 13
    case pq = 16
    case hlg = 18

    public init(transferCode code: Int?) {
        switch code {
        case 13: self = .srgb
        case 16: self = .pq
        case 18: self = .hlg
        default: self = .power24
        }
    }
}

// MARK: - Matrix

extension YCbCrMatrix {
    /// The CoreVideo attachment. 5 (BT.470BG) and 6 are both `ITU_R_601_4`: one matrix (`YCbCrMatrix`).
    public var coreVideo: CFString {
        switch self {
        case .rec709:  return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .rec2020: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .rec601:  return kCVImageBufferYCbCrMatrix_ITU_R_601_4
        }
    }
}

// MARK: - The three axes together

/// What the layer's colorspace is built from, and whether a fallback was taken.
public struct LayerColorAttachments: Equatable, Sendable {
    public let primaries: ColorPrimaries
    public let curve: TransferCurve
    public let matrix: YCbCrMatrix
    /// Set when the codes asked for PQ or HLG on primaries CoreVideo has no HDR space for (anything but
    /// 2020 and P3-D65). The layer then gets the full Rec.709 SDR set, as before S3, and this says why.
    public let hdrFallback: String?

    public var coreVideo: (primaries: CFString, transfer: CFString, matrix: CFString) {
        (primaries.coreVideo, curve.coreVideo, matrix.coreVideo)
    }
}

public enum ColorimetryTable {

    /// The attachments the layer's colorspace is built from: each axis from its own code, nothing
    /// inferred from another axis, an absent or unknown code → that axis's 709 value.
    ///
    /// ⚠️ ONE EXCEPTION, AND IT KEEPS THE PRE-S3 PICTURE RATHER THAN MAKING A NEW WRONG ONE. PQ or HLG
    /// on primaries other than 2020 or P3-D65 (e.g. 1-16-1, 11-16-1): handed those, CoreVideo builds a
    /// v2 profile called "HDR (PQ)" / "HDR (HLG)" with a γ1.8 curve and no `cicp` tag (S3 probe), which
    /// would draw PQ code values as γ1.8 SDR. Before S3 they fell to the 709 SDR set; they still do,
    /// and `hdrFallback` says so for the log. Not fixed here: no S3 prediction covers it.
    public static func layerAttachments(primaries: Int?, transfer: Int?, matrix: Int?) -> LayerColorAttachments {
        let p = ColorPrimaries.resolve(primaries)
        let t = TransferCurve.resolve(transfer)
        let m = YCbCrMatrix(cicp: matrix)
        if t.isHDR, p != .rec2020, p != .p3D65 {
            return LayerColorAttachments(
                primaries: .rec709, curve: .bt709, matrix: .rec709,
                hdrFallback: "\(t == .pq ? "PQ" : "HLG") on \(p.name) primaries (code \(primaries.map(String.init) ?? "absent")): "
                           + "CoreVideo has no HDR colorspace for these primaries; the layer keeps the Rec.709 SDR space, as before S3")
        }
        return LayerColorAttachments(primaries: p, curve: t, matrix: m, hdrFallback: nil)
    }

    // MARK: Names — the readout's and the inspector's, every code the app names

    public static func primariesName(forCode code: Int?) -> String {
        if let p = ColorPrimaries(cicp: code) { return p.name }
        switch code {
        case 10: return "ST 428-1"
        default: return "—"
        }
    }

    public static func transferName(forCode code: Int?) -> String {
        switch code {
        case 1:  return "Rec. 709"
        case 6:  return "BT.601"
        case 7:  return "SMPTE 240M"
        case 8:  return "Linear"
        case 13: return "sRGB"
        case 14: return "Rec. 2020 SDR"
        case 15: return "Rec. 2020 SDR (12-bit)"
        case 16: return "PQ (ST 2084)"
        case 17: return "ST 428-1"
        case 18: return "HLG"
        default: return "—"
        }
    }
}
