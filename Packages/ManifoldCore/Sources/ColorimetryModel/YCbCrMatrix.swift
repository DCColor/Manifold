//
//  YCbCrMatrix.swift
//  ColorimetryModel
//
//  The YCbCr matrix a CICP `matrix_coefficients` code selects — the ONE table the renderer's
//  scope maths and DeckLink encode (Kr/Kb), the scope header label and the live buffer tags all
//  read, so they cannot pick different matrices for the same code. In the package so `swift test`
//  reaches it.
//
//  Selected STRICTLY by the matrix code, never inferred from primaries (D5).
//

/// The matrix family a CICP matrix code decodes and encodes with.
public enum YCbCrMatrix: Equatable, Sendable {
    case rec709
    case rec601
    case rec2020

    /// nil, 2 (unspecified) and every code with no entry here → `.rec709`, the app's default.
    ///
    /// **5 AND 6 ARE THE SAME MATRIX.** BT.470BG (5, the 625-line system) and SMPTE 170M (6, the
    /// 525-line system) both define Kr 0.299, Kb 0.114 — BT.601's matrix; only their primaries
    /// differ, and primaries are a separate axis. Until 2026-10-07 only 6 was listed here, so a
    /// stream declaring 5 was decoded and scoped with the 709 matrix (docs/BUGS.md).
    public init(cicp code: Int?) {
        switch code {
        case 9:    self = .rec2020
        case 5, 6: self = .rec601
        default:   self = .rec709
        }
    }

    /// Luma coefficient for R. Float, because that is what the GPU kernels take — stated as Float
    /// literals so the values are bit-identical to the ones they replace.
    public var kr: Float {
        switch self {
        case .rec709:  return 0.2126
        case .rec601:  return 0.299
        case .rec2020: return 0.2627
        }
    }

    /// Luma coefficient for B.
    public var kb: Float {
        switch self {
        case .rec709:  return 0.0722
        case .rec601:  return 0.114
        case .rec2020: return 0.0593
        }
    }

    /// The YCbCr → RGB decode coefficients the shader's `passthroughFragment` multiplies by:
    ///
    ///     R = Y + a·Cr,   G = Y − b·Cb − c·Cr,   B = Y + d·Cb
    ///     a = 2(1 − Kr),  d = 2(1 − Kb),  b = 2·Kb(1 − Kb)/Kg,  c = 2·Kr(1 − Kr)/Kg
    ///
    /// with Cb, Cr ALREADY range-expanded to ±0.5 by the shader (legal range: × 1023/896, i.e. 255/224).
    /// So these are the unscaled constants, for every matrix.
    ///
    /// ⚠️ **THE 601 SET WAS THE TEXTBOOK LIMITED-RANGE ONE (1.5960, 0.3917, 0.8129, 2.0172) UNTIL
    /// 2026-10-12**, which already contains the 255/224 chroma expansion, so 601-tagged chroma was
    /// expanded twice: ×1.138 too saturated (colour S3 found it; §6.11). The 709 and 2020 sets were always
    /// unscaled. Stated as Float literals, rounded to 4 places like the 709 and 2020 sets, so those two stay
    /// bit-identical to the values they replace; the tests hold all three to the formula.
    public var decodeCoefficients: (a: Float, b: Float, c: Float, d: Float) {
        switch self {
        case .rec709:  return (1.5748, 0.1873, 0.4681, 1.8556)
        case .rec601:  return (1.4020, 0.3441, 0.7141, 1.7720)
        case .rec2020: return (1.4746, 0.1646, 0.5714, 1.8814)
        }
    }

    /// The CICP matrix code a CoreVideo / CoreMedia `YCbCrMatrix` attachment names, or nil when it names
    /// none this app knows. The ONE reading of that string — the file reader (`MediaInspector`), the
    /// shader's per-buffer matrix (`MetalVideoRenderer.colorParams`) and the HLS buffer reader all use it,
    /// so the picture and the scopes cannot read the same tag two ways (§6.11, the two 601 defects).
    ///
    /// CoreMedia has no constant for some codes and spells them `YCbCrMatrix#<code>` — measured: a
    /// BT.470BG (5) file's format description and decoded buffers both carry `YCbCrMatrix#5`. That form is
    /// read as its code.
    public static func cicpCode(forCoreVideo name: String?) -> Int? {
        guard let name else { return nil }
        switch name {
        case "ITU_R_709_2":     return 1
        case "ITU_R_601_4":     return 6
        case "SMPTE_240M_1995": return 7
        case "ITU_R_2020":      return 9
        default:
            let prefix = "YCbCrMatrix#"
            guard name.hasPrefix(prefix), let code = Int(name.dropFirst(prefix.count)), (0...255).contains(code)
            else { return nil }
            return code
        }
    }

    /// The scope headers' short label, in the canonical "Rec." form the CIE scope and inspector use.
    public var label: String {
        switch self {
        case .rec709:  return "Rec. 709"
        case .rec601:  return "Rec. 601"
        case .rec2020: return "Rec. 2020"
        }
    }
}
