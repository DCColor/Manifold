//
//  FieldView.swift
//  FileScan
//
//  How the WINDOW shows a woven interlaced picture (docs/INTERLACED_FINDINGS.md §3, §14, stage I4). Display only: the
//  scopes, SDI and export read the woven frame in the offscreen ring, which no view touches. The renderer draws the
//  view into a separate texture between the offscreen pass and the display copy; `MetalVideoRenderer.setFieldView`.
//
//  THE VIEWS (§14.2, the decisions):
//    • Weave — the frame as stored, both fields woven. Today's picture and the default; no field pass runs.
//    • Field 1 / Field 2 — one field, each of its lines repeated (stored samples only). Field 1 is the FIRST FIELD IN TIME
//      from the detected field order; with no order stated, the top field.
//    • Deinterlace — Field 1 kept, the other field's lines the mean of the kept lines above and below (edges repeat the
//      nearest). One picture per frame; no motion adaptivity. True bob is I5, after 1.0.
//
//  Rows are the raster's: the top field is the even rows, the bottom field the odd rows, whatever the temporal order.
//  `fieldViewKernel` (PassthroughShader.metal) restates `rows`; these tests pin it.
//

public enum FieldView: String, CaseIterable, Equatable, Sendable {
    case weave, field1, field2, deinterlace

    /// Whether a source offers the views: woven interlaced pictures only (I3's rule). A field sequence is already one field
    /// per picture; progressive, unknown and live sources have nothing to separate.
    public static func offered(_ scan: SourceScan) -> Bool { InterlacedChroma.perField(scan) }

    /// The raster parity (0 top, 1 bottom) of the field a view shows or keeps. nil for Weave.
    public func parity(_ order: FieldOrder?) -> Int? {
        let first = order == .bottomFirst ? 1 : 0
        switch self {
        case .weave: return nil
        case .field1, .deinterlace: return first
        case .field2: return 1 - first
        }
    }

    /// The woven rows output row `y` reads, and the weight of the second. Weave: the row itself.
    public struct Rows: Equatable, Sendable {
        public let rowA: Int
        public let rowB: Int
        public let weightB: Double
    }

    public func rows(outputRow y: Int, height: Int, order: FieldOrder?) -> Rows {
        guard let p = parity(order), height > 1 else { return Rows(rowA: y, rowB: y, weightB: 0) }
        // The last row of the shown field: H − 1 when it has the field's parity, else H − 2.
        let last = (height - 1) & 1 == p ? height - 1 : height - 2
        switch self {
        case .field1, .field2:
            let r = min((y & ~1) | p, last)
            return Rows(rowA: r, rowB: r, weightB: 0)
        default:
            if y & 1 == p { return Rows(rowA: y, rowB: y, weightB: 0) }
            let above = y - 1, below = y + 1
            if above < 0 { return Rows(rowA: below, rowB: below, weightB: 0) }
            if below > last { return Rows(rowA: above, rowB: above, weightB: 0) }
            return Rows(rowA: above, rowB: below, weightB: 0.5)
        }
    }

    // MARK: - Words

    private func fieldWords(_ order: FieldOrder?) -> String {
        let raster = parity(order) == 1 ? "bottom field" : "top field"
        guard let order else { return raster + ", field order not stated" }
        let first = (order == .topFirst) == (parity(order) == 0)
        return raster + (first ? ", first in time" : ", second in time")
    }

    /// The menu's and the pulldown's item: "Weave", "Field 1", "Field 2", "Deinterlace".
    public var menuTitle: String {
        switch self {
        case .weave: return "Weave"
        case .field1: return "Field 1"
        case .field2: return "Field 2"
        case .deinterlace: return "Deinterlace"
        }
    }

    /// What the view does, for the pulldown's subtitle and the chain readout's Fields row.
    public func detail(_ order: FieldOrder?) -> String {
        switch self {
        case .weave: return "both fields woven, as stored"
        case .field1, .field2: return fieldWords(order) + ", each line repeated"
        case .deinterlace: return "from field 1 (\(fieldWords(order))), the other field's lines interpolated"
        }
    }

    /// The chain readout's Fields row and the `[CHAIN] Fields` line.
    public func readout(_ order: FieldOrder?) -> String {
        self == .weave ? "Weave — " + detail(order)
                       : "\(menuTitle) — \(detail(order)) — DISPLAY ONLY; scopes, SDI and export read the woven frame"
    }

    /// The Inspector's Window View row.
    public func inspectorText(_ order: FieldOrder?) -> String {
        self == .weave ? "Weave (fields as stored)" : "\(menuTitle) — \(fieldWords(order)) (display only)"
    }

    /// The window-title suffix and the badge: nil for Weave.
    public var titleSuffix: String? { self == .weave ? nil : "\(menuTitle) (display only)" }
    public var badge: String? { self == .weave ? nil : "\(menuTitle.uppercased()) · DISPLAY ONLY" }

    /// The `[FIELDS]` log label.
    public var logLabel: String {
        switch self {
        case .weave: return "WEAVE"
        case .field1: return "FIELD 1"
        case .field2: return "FIELD 2"
        case .deinterlace: return "DEINTERLACE"
        }
    }

    /// The shader's view code (`FieldViewParams.mode`): 0 Weave (never dispatched), 1 one field line-repeated,
    /// 2 deinterlace.
    public var shaderMode: UInt32 {
        switch self {
        case .weave: return 0
        case .field1, .field2: return 1
        case .deinterlace: return 2
        }
    }
}

extension SourceScan {
    /// The chain readout's Source-row prefix: "1080i59.94 TFF", "field sequence, TFF". nil when not interlaced, so a
    /// progressive or unknown source's line is unchanged. `fieldToken` is the field rate's label ("59.94"). The scan can
    /// arrive before the metadata does: with no height yet it says "interlaced, TFF", never "0i TFF" (found on the I4 run).
    public func chainPrefix(height: Int, fieldToken: String?) -> String? {
        guard isInterlaced else { return nil }
        let order = fieldOrder?.short ?? "order not stated"
        if picturesAreFields { return "field sequence, \(order)" }
        guard height > 0 else { return "interlaced, \(order)" }
        return "\(height)i\(fieldToken ?? "") \(order)"
    }
}
