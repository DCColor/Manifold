//
//  SourceScan.swift
//  FileScan
//
//  A file's scan — progressive or interlaced — and its field order, with where each answer came from
//  (docs/INTERLACED_FINDINGS.md §10, stage I1). Detection only: nothing about how a picture is shown or
//  output depends on it yet. Later stages (I2 SDI modes, I3 per-field colour, I4 the display options) read
//  `VideoMetadata.scan`, which holds one of these.
//
//  THE RULE (§8, I1): THE BITSTREAM WINS, PER AXIS. The two axes are scan (progressive / interlaced) and field
//  order. Where the bitstream states an axis, its answer is used; the container fills only an axis the
//  bitstream leaves unstated; an axis neither states is unknown. A disagreement on an axis both state is
//  logged and shown in the Inspector row, and changes nothing else. The bitstream is what the decoder acts
//  on, and §6 measured the container's field label going wrong (FFmpeg's "(swapped)").
//

/// Which field comes first in time.
public enum FieldOrder: String, Equatable, Sendable {
    case topFirst, bottomFirst

    var words: String { self == .topFirst ? "top field first" : "bottom field first" }
    var short: String { self == .topFirst ? "TFF" : "BFF" }
}

/// What ONE source states. nil on an axis means it says nothing about that axis.
public struct ScanReading: Equatable, Sendable {
    public let interlaced: Bool?
    public let fieldOrder: FieldOrder?
    /// The name shown for the scan answer: "fiel", "MXF FrameLayout", "ProRes frame header", "H.264 SPS" …
    public let scanSource: String
    /// The name shown for the field order, when it comes from a different field than the scan.
    public let orderSource: String
    /// The values as coded, for the log: "FieldCount 2, FieldDetail SpatialFirstLineEarly".
    public let detail: String

    public init(interlaced: Bool?, fieldOrder: FieldOrder?, scanSource: String, orderSource: String? = nil,
                detail: String) {
        self.interlaced = interlaced
        // An order is only meaningful for an interlaced picture; a reading that says progressive has none.
        self.fieldOrder = interlaced == false ? nil : fieldOrder
        self.scanSource = scanSource
        self.orderSource = orderSource ?? scanSource
        self.detail = detail
    }

    /// True when the reading states neither axis.
    public var isSilent: Bool { interlaced == nil && fieldOrder == nil }

    var summary: String {
        switch (interlaced, fieldOrder) {
        case (false?, _): return "progressive"
        case (true?, let o?): return "interlaced \(o.short)"
        case (true?, nil): return "interlaced, order not stated"
        case (nil, let o?): return "order \(o.short), scan not stated"
        case (nil, nil): return "states nothing"
        }
    }
}

/// The answer for one file: the scan, the field order, which source decided each, both readings, and every
/// axis on which they disagreed.
public struct SourceScan: Equatable, Sendable {

    public enum Scan: Equatable, Sendable {
        case progressive
        /// nil: interlaced, but no source states which field is first.
        case interlaced(FieldOrder?)
        case unknown
    }

    public enum Axis: String, Equatable, Sendable { case scan, fieldOrder = "field order" }

    public struct Disagreement: Equatable, Sendable {
        public let axis: Axis
        /// What the container said on that axis, in words ("progressive", "bottom field first").
        public let container: String
        public let bitstream: String
    }

    public let scan: Scan
    /// The source that decided the scan, and the field order. nil when nothing decided it.
    public let scanSource: String?
    public let orderSource: String?
    public let container: ScanReading?
    public let bitstream: ScanReading?
    public let disagreements: [Disagreement]

    /// Before a file is read, and for anything that is not a file. Says what it is rather than guessing.
    public static let notRead = SourceScan(scan: .unknown, scanSource: nil, orderSource: nil,
                                           container: nil, bitstream: nil, disagreements: [])

    public var isInterlaced: Bool { if case .interlaced = scan { return true }; return false }
    public var fieldOrder: FieldOrder? { if case .interlaced(let o) = scan { return o }; return nil }

    // MARK: - The rule

    public static func resolve(container: ScanReading?, bitstream: ScanReading?) -> SourceScan {
        let c = container?.isSilent == false ? container : nil
        let b = bitstream?.isSilent == false ? bitstream : nil

        // Scan: the bitstream's statement, else the container's.
        let interlaced: Bool?
        let scanSource: String?
        if let v = b?.interlaced { interlaced = v; scanSource = b?.scanSource }
        else if let v = c?.interlaced { interlaced = v; scanSource = c?.scanSource }
        else { interlaced = nil; scanSource = nil }

        // Field order, for an interlaced picture: the bitstream's, else the container's. A container that says
        // progressive has no order to lend (`ScanReading.init` drops it).
        var order: FieldOrder? = nil
        var orderSource: String? = nil
        if interlaced != false {
            if let o = b?.fieldOrder { order = o; orderSource = b?.orderSource }
            else if let o = c?.fieldOrder { order = o; orderSource = c?.orderSource }
        }

        var disagreements: [Disagreement] = []
        if let cv = c?.interlaced, let bv = b?.interlaced, cv != bv {
            disagreements.append(Disagreement(axis: .scan, container: cv ? "interlaced" : "progressive",
                                              bitstream: bv ? "interlaced" : "progressive"))
        }
        if let co = c?.fieldOrder, let bo = b?.fieldOrder, co != bo {
            disagreements.append(Disagreement(axis: .fieldOrder, container: co.words, bitstream: bo.words))
        }

        let scan: Scan
        switch interlaced {
        case false?: scan = .progressive
        case true?: scan = .interlaced(order)
        case nil: scan = order != nil ? .interlaced(order) : .unknown   // an order implies fields
        }
        return SourceScan(scan: scan, scanSource: interlaced == nil && order != nil ? orderSource : scanSource,
                          orderSource: orderSource, container: container, bitstream: bitstream,
                          disagreements: disagreements)
    }

    // MARK: - Words

    /// The Inspector's Scan row: "Interlaced, top field first (ProRes frame header)".
    public var readout: String {
        var s: String
        switch scan {
        case .progressive:
            s = "Progressive (\(scanSource ?? "—"))"
        case .interlaced(let o?):
            if scanSource == orderSource { s = "Interlaced, \(o.words) (\(scanSource ?? "—"))" }
            else { s = "Interlaced (\(scanSource ?? "—")), \(o.words) (\(orderSource ?? "—"))" }
        case .interlaced(nil):
            s = "Interlaced (\(scanSource ?? "—")), field order not stated"
        case .unknown:
            s = container == nil && bitstream == nil ? "Not read"
                : "Unknown — neither the container nor the bitstream says"
        }
        for d in disagreements {
            let source = d.axis == .scan ? container?.scanSource : container?.orderSource
            s += " · ⚠️ \(source ?? "container") says \(d.container)"
        }
        return s
    }

    /// The `[SCAN]` log line: always one per file read.
    public var logLine: String {
        func side(_ r: ScanReading?, _ none: String) -> String {
            guard let r else { return none }
            return "\(r.scanSource == r.orderSource ? r.scanSource : r.scanSource + " / " + r.orderSource)"
                 + " [\(r.detail)] → \(r.summary)"
        }
        let verdict: String
        if !disagreements.isEmpty {
            verdict = "⚠️ DISAGREE on " + disagreements.map {
                "\($0.axis.rawValue) (container \($0.container), bitstream \($0.bitstream))"
            }.joined(separator: ", ") + " — the bitstream is used"
        } else if container?.isSilent == false && bitstream?.isSilent == false {
            verdict = "agree"
        } else if container?.isSilent == false || bitstream?.isSilent == false {
            verdict = "one source"
        } else {
            verdict = "nothing stated"
        }
        return "[SCAN] container: \(side(container, "none read")) · bitstream: \(side(bitstream, "none read"))"
             + " ⇒ \(readout) — \(verdict)"
    }
}
