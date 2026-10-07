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

    /// The scope headers' short label, in the canonical "Rec." form the CIE scope and inspector use.
    public var label: String {
        switch self {
        case .rec709:  return "Rec. 709"
        case .rec601:  return "Rec. 601"
        case .rec2020: return "Rec. 2020"
        }
    }
}
