//
//  StreamColorimetry.swift
//  Manifold
//
//  What an H.264 live stream declared about its colour, axis by axis — SRT's and WHEP's shared
//  answer, read from the stream's own SPS (docs/COLOR_MANAGEMENT_FINDINGS.md §6.9, Stage SPS).
//
//  ── THE THREE-STATE HONESTY ────────────────────────────────────────────────────────────
//
//  "The sender said nothing" is a different answer from "the sender said 709", for the same reason
//  SourceColorimetry keeps `declared` apart from `assumed`: A DEFAULT IS NOT A FACT. An axis the SPS
//  leaves absent, unspecified (2) or reserved is UNDECLARED, and keeps the behaviour every SRT and
//  WHEP stream had before this existed: assumed 709.
//
//  WHERE THE DISTINCTION LANDS, in all three places it can:
//
//   1. THE RENDERER (`route(undeclaredAxisCode:)`): the codes and the provenance tier the scopes, the
//      chain readout, the layer colorspace and the EDR gate read. How an UNDECLARED axis is spelled
//      there is each transport's own, kept as it was: SRT passes nil, WHEP passes 1 (with the tier
//      saying `assumed` either way). Both draw the same picture; unifying them is a separate change
//      with its own measurement, not something to slip in here.
//   2. THE PIXEL-BUFFER ATTACHMENTS (`bufferTags`): these cannot be nil, so an undeclared axis is
//      stamped 709 AND recorded as assumed — SourceColorimetry's own vocabulary.
//   3. THE LOG: `[SPS-COLOR]`, once per change, per axis, with the raw SPS number beside the verdict.
//
//  ⚠️ BOTH HALVES CHANGE TOGETHER OR NOT AT ALL (§6.9 finding 10). The shader takes its YCbCr matrix
//  from each buffer's tags; everything else takes its colour from `setSourceColorSpace`. Both are
//  derived here, from ONE value, so they cannot describe different streams.
//
//  RANGE IS NOT READ FROM THE SPS. Each transport fixes its range as it did before (SRT from
//  `codecpar->color_range`, WHEP pinned to limited). `video_full_range_flag` is logged beside the
//  range in use, and whether they agree, and nothing acts on it — Stage SPS records, it does not
//  decide.
//

import ColorimetryModel
import SPSColor

struct StreamColorimetry: Equatable {

    /// One axis: the CICP code the pipeline consumes, and whether the STREAM said so.
    struct Axis: Equatable {
        let code: Int
        let declared: Bool
        /// nil when assumed — SRT's spelling of "unspecified" to the renderer.
        var codeIfDeclared: Int? { declared ? code : nil }

        /// Undeclared assumes 709 (1) on every axis: the default every live source starts on.
        init(_ declaredCode: Int?) {
            code = declaredCode ?? 1
            declared = declaredCode != nil
        }
    }

    let primaries: Axis
    let transfer: Axis
    let matrix: Axis
    /// Range is a SEPARATE axis from colorimetry — legal/video vs full swing. The transport's own
    /// choice, NOT the SPS's (see the header).
    let isFullRange: Bool
    let rangeDeclared: Bool
    /// The SPS reading this came from, kept for the log: it holds the raw numbers (a 2, a reserved 3)
    /// and how far the SPS got, which the verdict above has already discarded.
    let sps: SPSColor

    init(sps: SPSColor, isFullRange: Bool, rangeDeclared: Bool) {
        self.sps = sps
        primaries = Axis(sps.primaries)
        transfer = Axis(sps.transfer)
        matrix = Axis(sps.matrix)
        self.isFullRange = isFullRange
        self.rangeDeclared = rangeDeclared
    }

    /// Before any SPS has been read: every axis undeclared.
    static func undeclared(isFullRange: Bool, rangeDeclared: Bool) -> StreamColorimetry {
        StreamColorimetry(sps: .undeclared, isFullRange: isFullRange, rangeDeclared: rangeDeclared)
    }

    /// Which honesty tier this sits in, from the axes' own `declared` flags rather than the codes.
    /// No user override exists on SRT or WHEP yet (Stages B and C), so `.overridden` cannot arise.
    var sourceProvenance: SourceColorProvenance {
        switch [primaries, transfer, matrix].filter(\.declared).count {
        case 0:  return .assumed
        case 3:  return .tagged
        default: return .partlyAssumed
        }
    }

    /// What the renderer is told. `undeclaredAxisCode` is how THIS transport spells an undeclared
    /// axis — see point 1 in the header. The tier is the same whichever spelling is used.
    func route(undeclaredAxisCode: Int?) -> LiveDisplayRoute.Colorimetry {
        func code(_ a: Axis) -> Int? { a.declared ? a.code : undeclaredAxisCode }
        return LiveDisplayRoute.Colorimetry(primaries: code(primaries),
                                            transfer: code(transfer),
                                            matrix: code(matrix),
                                            isFullRange: isFullRange,
                                            provenance: sourceProvenance)
    }

    /// What gets stamped on every pixel buffer. Cannot be nil — see point 2 in the header.
    var bufferTags: SourceColorimetry {
        func axis(_ a: Axis, _ name: String) -> ColorimetryAxis {
            a.declared ? .declaredValue(a.code, name) : .assumed(a.code)
        }
        return SourceColorimetry(
            primaries: axis(primaries, SourceColorimetry.primariesName(primaries.code)),
            transfer:  axis(transfer,  SourceColorimetry.transferName(transfer.code)),
            matrix:    axis(matrix,    SourceColorimetry.matrixName(matrix.code)))
    }

    // MARK: - Log

    /// The connect line's colour part. Says "undeclared" in words rather than printing a number that
    /// looks like the sender's statement.
    var summary: String {
        func axis(_ label: String, _ a: Axis, _ name: String) -> String {
            a.declared ? "\(label)=\(name) (declared, code \(a.code))"
                       : "\(label)=UNDECLARED → assuming \(name)"
        }
        let range = rangeDeclared
            ? (isFullRange ? "range=full (declared)" : "range=limited (declared)")
            : "range=UNDECLARED → assuming limited"
        return axis("primaries", primaries, SourceColorimetry.primariesName(primaries.code)) + "  "
             + axis("transfer", transfer, SourceColorimetry.transferName(transfer.code)) + "  "
             + axis("matrix", matrix, SourceColorimetry.matrixName(matrix.code)) + "  " + range
    }

    /// The `[SPS-COLOR]` line: per axis, the SPS's raw number, the verdict and why; then the tier;
    /// then `video_full_range_flag` against the range this transport is actually using.
    func spsColorLine(transport: String) -> String {
        let absent: String
        switch sps.reach {
        case .notAnSPS:            absent = "absent (not an SPS)"
        case .malformed:           absent = "absent (SPS unreadable before the colour fields)"
        case .noVUI:               absent = "absent (no VUI)"
        case .noVideoSignalType:   absent = "absent (no video_signal_type)"
        case .noColourDescription: absent = "absent (no colour description)"
        case .colourDescription:   absent = "absent"
        }
        func axis(_ label: String, _ raw: Int?, _ a: Axis, _ name: (Int) -> String) -> String {
            guard let raw else { return "\(label) \(absent) → undeclared" }
            if a.declared { return "\(label)=\(raw) (\(name(raw))) declared" }
            return "\(label)=\(raw) \(raw == 2 ? "unspecified" : "reserved") → undeclared"
        }
        let flag = sps.videoFullRangeFlag.map { $0 ? "1" : "0" } ?? "absent"
        let inUse = isFullRange ? "full" : "limited"
        let agreement: String
        if let declaredFull = sps.videoFullRangeFlag {
            agreement = declaredFull == isFullRange ? "agrees" : "⚠️ DISAGREES (not acted on)"
        } else {
            agreement = "nothing to compare"
        }
        return "[SPS-COLOR] \(transport): "
            + axis("primaries", sps.colourPrimaries, primaries, SourceColorimetry.primariesName) + " · "
            + axis("transfer", sps.transferCharacteristics, transfer, SourceColorimetry.transferName) + " · "
            + axis("matrix", sps.matrixCoefficients, matrix, SourceColorimetry.matrixName)
            + " → \(sourceProvenance.label) | video_full_range_flag=\(flag), range in use \(inUse) — \(agreement)"
    }
}
