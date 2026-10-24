//
//  PictureCodes.swift
//  ColorimetryModel
//
//  Colour S6, L2 (COLOR_MANAGEMENT_FINDINGS.md §6.11, *S6 — LUT*, D3 and D4): which CICP codes describe the
//  PICTURE, as against the SOURCE.
//
//  Without a LUT the two are the same. A LUT in Interpretation changes what the picture is, so its stated output
//  space describes everything downstream of it — the layer, EDR, the scopes, the SDI tag, the v210 matrix, the
//  export ICC, Reference and the CIE scope — while the source codes keep describing the source: the Source line,
//  the override's decode matrix, provenance.
//

/// The LUT's output space (D4) is a `ColorimetryOverride`, read here with `.auto` meaning **Same as Source**: the
/// presets and Custom are the same choices the Interpretation menu already offers, so a stated space is always one
/// the S3 table draws as stated.
public enum PictureCodes {
    /// The picture's codes, and whether a LUT's stated output space supplied them.
    ///
    /// - `lutLoaded` false → the source codes, whatever `lutOutput` holds (a stated space without a LUT states
    ///   nothing about any picture).
    /// - `.auto` (Same as Source) → the source codes.
    /// - a preset, or a supported Custom → its triple, every axis stated.
    /// - an unsupported Custom → the source codes. The menu never builds one; this keeps a bad value from
    ///   naming a curve the picture is not drawn with.
    public static func resolve(source: (primaries: Int?, transfer: Int?, matrix: Int?),
                               lutLoaded: Bool,
                               lutOutput: ColorimetryOverride)
        -> (primaries: Int?, transfer: Int?, matrix: Int?, statedByLUT: Bool) {
        guard lutLoaded, let t = lutOutput.preset, CustomColorimetry.isSupported(t) else {
            return (source.primaries, source.transfer, source.matrix, false)
        }
        return (t.primaries, t.transfer, t.matrix, true)
    }

    /// The menu's and the log's words for an output space: "Same as Source" for `.auto`, a triple as "Custom 9·1·9",
    /// else the preset's label. "Custom" and not the interpretation's "Override" (2026-10-24): a LUT's stated output
    /// space is a statement about the LUT, not an override of the source's tags.
    public static func outputLabel(_ o: ColorimetryOverride) -> String {
        if o == .auto { return "Same as Source" }
        guard o.isCustom, let t = o.preset else { return o.label }
        return "Custom \(t.primaries)·\(t.transfer)·\(t.matrix)"
    }
}
