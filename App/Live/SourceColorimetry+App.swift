import Foundation
import CoreVideo
import ColorimetryModel

/// The app's side of `SourceColorimetry` (ColorimetryModel): NDI's `<ndi_color_info/>` parse, the
/// CoreVideo tagging and the log wording, which NDI, SRT and WHEP all use. The type itself — the
/// axes, their provenance, the override presets and `resolve` — lives in the package so
/// `swift test` reaches it (§6.9, Stage A). This file was App/NDI/NDIColorInfo.swift.
///
/// WHERE IT COMES FROM, on NDI: the per-frame `p_metadata` XML string, e.g.
///     <ndi_color_info transfer="bt_2100_pq" matrix="bt_2020" primaries="bt_2020"/>
/// Vocabulary (NDI SDK): transfer = bt_601 | bt_709 | bt_2020 | bt_2100_pq | bt_2100_hlg;
/// matrix = bt_601 | bt_709 | bt_2020; primaries = bt_601 | bt_709 | bt_2020. Senders may emit
/// words outside that list; an unrecognized word is treated as ABSENT for that axis (assumed),
/// never guessed at.
///
/// WHERE IT GOES: `apply(to:)` writes the standard CICP attachments onto the CVPixelBuffer, which
/// is the ONLY thing the rest of the pipeline reads. That makes an NDI buffer indistinguishable
/// from a file buffer downstream — the shader's YCbCr matrix (`colorParams`), the layer colorspace
/// (`CVImageBufferCreateColorSpaceFromAttachments` / `makeColorSpace`), the GPU scopes and the EDR
/// gate (transfer 16/18) all consume it with no NDI-specific code.
extension SourceColorimetry {
    // MARK: - Parse

    /// Pull `<ndi_color_info .../>` out of a frame's `p_metadata` and map it to CICP.
    ///
    /// Deliberately NOT an XML parser. This is one flat, attribute-only element inside a string
    /// that arrives on EVERY frame; a targeted scan for the three attributes costs a few
    /// microseconds and adds no dependency, where XMLParser would allocate a parser + delegate per
    /// frame to read three words. Anything the scan can't make sense of falls through to assumed —
    /// malformed metadata degrades to the default, it never throws and never guesses.
    static func parse(metadataXML: String?) -> SourceColorimetry {
        guard let xml = metadataXML,
              let element = colorInfoElement(in: xml) else { return .assumedRec709 }

        return SourceColorimetry(
            primaries: axis(attribute("primaries", in: element), map: primariesCode, default: 1),
            transfer:  axis(attribute("transfer",  in: element), map: transferCode,  default: 1),
            matrix:    axis(attribute("matrix",    in: element), map: matrixCode,    default: 1))
    }

    /// One axis: declared only when the attribute is present AND its word is one we know.
    /// An unknown word is NOT a value — it's a hole, and a hole is assumed.
    private static func axis(_ raw: String?, map: (String) -> Int?, default fallback: Int) -> ColorimetryAxis {
        guard let raw, let code = map(raw.lowercased()) else { return .assumed(fallback) }
        return .declaredValue(code, raw)
    }

    /// The `<ndi_color_info ...>` element's body (everything up to the closing `>`), or nil.
    private static func colorInfoElement(in xml: String) -> Substring? {
        guard let start = xml.range(of: "<ndi_color_info", options: .caseInsensitive) else { return nil }
        let rest = xml[start.upperBound...]
        guard let end = rest.firstIndex(of: ">") else { return nil }
        return rest[..<end]
    }

    /// `name="value"` / `name='value'`, tolerant of whitespace around the `=`. Returns nil when the
    /// attribute is absent or unterminated.
    private static func attribute(_ name: String, in element: Substring) -> String? {
        var searchFrom = element.startIndex
        while let nameRange = element.range(of: name, options: .caseInsensitive,
                                            range: searchFrom..<element.endIndex) {
            searchFrom = nameRange.upperBound
            // Must be a whole attribute name, not the tail of another one (e.g. "primaries" must
            // not match inside "xyz_primaries").
            if nameRange.lowerBound > element.startIndex {
                let before = element[element.index(before: nameRange.lowerBound)]
                if !before.isWhitespace { continue }
            }
            var i = nameRange.upperBound
            while i < element.endIndex, element[i].isWhitespace { i = element.index(after: i) }
            guard i < element.endIndex, element[i] == "=" else { continue }
            i = element.index(after: i)
            while i < element.endIndex, element[i].isWhitespace { i = element.index(after: i) }
            guard i < element.endIndex, element[i] == "\"" || element[i] == "'" else { continue }
            let quote = element[i]
            let valueStart = element.index(after: i)
            guard let valueEnd = element[valueStart...].firstIndex(of: quote) else { return nil }
            return String(element[valueStart..<valueEnd])
        }
        return nil
    }

    // MARK: - NDI vocabulary -> CICP
    //
    // The codes are the SAME ones the file path produces from its format-description tags
    // (MediaInspector.colorTags), because they end up in the same fields: the renderer's
    // sourcePrimariesCode / sourceTransferCode / sourceMatrixCode, and the buffer attachments the
    // shader reads. An NDI 2020/PQ frame must be numerically identical to a PQ file's, or the EDR
    // gate and the scopes would need to know which source they were looking at.

    /// primaries: bt_709 → 1, bt_2020 → 9, bt_601 → 6.
    /// bt_601 → 6 (SMPTE-C / 170M, the 525-line set) rather than 5 (EBU 3213, 625-line): NDI's
    /// vocabulary does not distinguish them, and CoreVideo's SMPTE_C is the one MediaInspector maps
    /// to 6. Stated because it IS a choice, not a derivation.
    private static func primariesCode(for s: String) -> Int? {
        switch s {
        case "bt_709":  return 1
        case "bt_2020": return 9
        case "bt_601":  return 6
        default:        return nil
        }
    }

    /// transfer: bt_709 → 1, bt_2020 → 14, bt_2100_pq → 16 (PQ), bt_2100_hlg → 18 (HLG),
    /// bt_601 → 1.
    ///
    /// bt_601 → 1 is not a fudge: BT.601's transfer characteristic IS the BT.709 curve, and
    /// CoreVideo has no separate 601 transfer constant to attach. The declared word is kept
    /// verbatim in the axis, so the inspector can still say the sender declared bt_601.
    /// 16 and 18 are the codes the EDR gate keys off — this is the line that makes PQ/HLG over NDI
    /// reach the display path as HDR.
    private static func transferCode(for s: String) -> Int? {
        switch s {
        case "bt_709":      return 1
        case "bt_601":      return 1    // same curve as 709; no distinct CV constant
        case "bt_2020":     return 14   // BT.2020 SDR — again the 709 curve, but a distinct tag
        case "bt_2100_pq":  return 16
        case "bt_2100_hlg": return 18
        default:            return nil
        }
    }

    /// matrix: bt_709 → 1, bt_2020 → 9, bt_601 → 6. Selected STRICTLY on its own — never inferred
    /// from primaries (the renderer's `ycbcrKrKb` makes the same point from the other end).
    private static func matrixCode(for s: String) -> Int? {
        switch s {
        case "bt_709":  return 1
        case "bt_2020": return 9
        case "bt_601":  return 6
        default:        return nil
        }
    }

    // MARK: - CICP -> CoreVideo attachments

    private static func primariesAttachment(_ code: Int) -> CFString {
        switch code {
        case 9:  return kCVImageBufferColorPrimaries_ITU_R_2020
        case 6:  return kCVImageBufferColorPrimaries_SMPTE_C
        case 5:  return kCVImageBufferColorPrimaries_EBU_3213
        case 12: return kCVImageBufferColorPrimaries_P3_D65
        default: return kCVImageBufferColorPrimaries_ITU_R_709_2
        }
    }

    private static func transferAttachment(_ code: Int) -> CFString {
        switch code {
        case 16: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case 18: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case 14: return kCVImageBufferTransferFunction_ITU_R_2020
        default: return kCVImageBufferTransferFunction_ITU_R_709_2
        }
    }

    private static func matrixAttachment(_ code: Int) -> CFString {
        switch code {
        case 9: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        case 6: return kCVImageBufferYCbCrMatrix_ITU_R_601_4
        default: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
    }

    /// Stamp the three CICP attachments onto a pixel buffer.
    ///
    /// WHAT VIDEOTOOLBOX ACTUALLY DOES, measured rather than assumed (the UYVY→x422 transfer sits
    /// between the NDI buffer and the display buffer, so its behavior decides where this call has
    /// to go): VTPixelTransferSession PROPAGATES the source buffer's color attachments onto its
    /// output, and does NOT convert pixels on account of them — a 709-tagged and a PQ/2020-tagged
    /// source produce byte-identical output. It does not stamp a default of its own.
    ///
    /// Which means the old Rec.709 hardcode on the NDI buffer was the entire bug: VT carried that
    /// 709 faithfully to the display buffer, and every source read 709 because every source was
    /// TOLD to be 709 on arrival.
    ///
    /// We still tag the transfer's OUTPUT, after it runs, and not only its input: a pooled
    /// destination buffer starts with no attachments at all, attachment propagation is not a
    /// contract Apple documents (it need not hold for another format pair or another OS version),
    /// and the output buffer is the one every downstream consumer actually reads. Tagging it last
    /// is the only ordering that is correct whether VT propagates, defaults, or does nothing —
    /// and NDIService logs what the output really carried, so this stays a measurement.
    ///
    /// ShouldPropagate so the tags survive the CMSampleBuffer/format-description wrap, like a file
    /// buffer's do.
    func apply(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              Self.primariesAttachment(primaries.code), .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              Self.transferAttachment(transfer.code), .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              Self.matrixAttachment(matrix.code), .shouldPropagate)
    }

    /// What a buffer ACTUALLY carries right now, as "primaries · transfer · matrix" (or "—" for an
    /// axis with no attachment). Used to VERIFY the tagging rather than assume it: the interesting
    /// line in the log is the one that shows what VideoToolbox left on its output before we
    /// overrode it.
    static func attachmentSummary(of pixelBuffer: CVPixelBuffer) -> String {
        func read(_ key: CFString) -> String {
            guard let v = CVBufferCopyAttachment(pixelBuffer, key, nil) else { return "—" }
            return (v as? String) ?? String(describing: v)
        }
        return "\(read(kCVImageBufferColorPrimariesKey)) · "
             + "\(read(kCVImageBufferTransferFunctionKey)) · "
             + "\(read(kCVImageBufferYCbCrMatrixKey))"
    }

    // MARK: - Readout

    /// Human-readable, honest about provenance — "declared" values read plainly, assumed ones say
    /// so. (The inspector is a later step; this is the log's version of the same rule.)
    var summary: String {
        func axis(_ label: String, _ a: ColorimetryAxis, _ name: String) -> String {
            switch a.provenance {
            case .declared:   return "\(label)=\(a.declared ?? "?") (\(name), code \(a.code))"
            case .assumed:    return "\(label)=\(name) code \(a.code) (assumed)"
            case .overridden: return "\(label)=\(name) code \(a.code) (OVERRIDE)"
            }
        }
        return axis("primaries", primaries, Self.primariesName(primaries.code)) + "  "
             + axis("transfer", transfer, Self.transferName(transfer.code)) + "  "
             + axis("matrix", matrix, Self.matrixName(matrix.code))
    }

    static func primariesName(_ code: Int) -> String {
        switch code {
        case 1:  return "Rec.709"
        case 9:  return "Rec.2020"
        case 6:  return "SMPTE-C"
        case 5:  return "EBU 3213"
        case 12: return "P3 D65"
        default: return "code \(code)"
        }
    }

    static func transferName(_ code: Int) -> String {
        switch code {
        case 1:  return "Rec.709"
        case 14: return "Rec.2020 (SDR)"
        case 16: return "PQ (ST 2084)"
        case 18: return "HLG"
        default: return "code \(code)"
        }
    }

    static func matrixName(_ code: Int) -> String {
        switch code {
        case 1:  return "Rec.709"
        case 9:  return "Rec.2020"
        case 6:  return "SMPTE-C / 170M"
        default: return "code \(code)"
        }
    }
}
