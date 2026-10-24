//
//  LUTReadout.swift — the LUT line of the chain readout and the Interpretation menu (colour S6, L3; §6.11 D7).
//
//      name.cube — 3D 33³ + 1D 4096 shaper · tetrahedral · out Rec.2020 PQ (HDR10) (stated)
//      name.cube — 3D 33³ · trilinear · ignored: LUT_IN_VIDEO_RANGE (line 2)
//      BYPASSED — name.cube — 1D 1024 · linear — not applied
//      name.cube — 3D 33³ · tetrahedral · no source
//
//  The interpolation word is the one the shader runs: a 1D-only table is always interpolated linearly, so it does
//  not name the 3D setting. Unknown keywords are named with their lines (D7), the first four and a count of the
//  rest. With no source the line names no output space: there is no picture for it to describe (L2's open item).
//  At Same as Source it names none either (Robbie, 2026-10-24): the LUT's output space is mentioned only when one is
//  stated.
//  A bypassed line LEADS with the word, so the row says what is bypassed before it says which (LG session, 2026-10-22:
//  "bypass of what?").
//

public enum LUTReadout {
    /// How many ignored keywords are named before "+N more".
    public static let namedIgnoredLimit = 4

    /// - Parameters:
    ///   - outputLabel: the stated output space's label, or nil for Same as Source.
    public static func line(name: String, lut: CubeLUT, interpolation: CubeInterpolation,
                            outputLabel: String?, bypassed: Bool, sourcePresent: Bool) -> String {
        var parts = [lut.shapeDescription, lut.cube == nil ? "linear" : interpolation.rawValue]
        // A bypassed LUT has no output space in force; the word is put around the whole line, below.
        if !bypassed {
            if !sourcePresent { parts.append("no source") } else if let outputLabel { parts.append("out \(outputLabel) (stated)") }
        }
        if !lut.ignored.isEmpty {
            let named = lut.ignored.prefix(namedIgnoredLimit).map { "\($0.keyword) (line \($0.line))" }
            let more = lut.ignored.count - named.count
            parts.append("ignored: " + named.joined(separator: ", ") + (more > 0 ? ", +\(more) more" : ""))
        }
        let body = "\(name) — " + parts.joined(separator: " · ")
        return bypassed ? "BYPASSED — \(body) — not applied" : body
    }
}
