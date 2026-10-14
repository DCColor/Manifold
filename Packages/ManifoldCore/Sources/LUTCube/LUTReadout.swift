//
//  LUTReadout.swift — the LUT line of the chain readout and the Interpretation menu (colour S6, L3; §6.11 D7).
//
//      name.cube — 3D 33³ + 1D 4096 shaper · tetrahedral · out Rec.2020 PQ (HDR10) (stated)
//      name.cube — 3D 33³ · trilinear · out same as source · ignored: LUT_IN_VIDEO_RANGE (line 2)
//      name.cube — 1D 1024 · linear · BYPASSED — not applied
//      name.cube — 3D 33³ · tetrahedral · no source
//
//  The interpolation word is the one the shader runs: a 1D-only table is always interpolated linearly, so it does
//  not name the 3D setting. Unknown keywords are named with their lines (D7), the first four and a count of the
//  rest. With no source the line names no output space: there is no picture for it to describe (L2's open item).
//

public enum LUTReadout {
    /// How many ignored keywords are named before "+N more".
    public static let namedIgnoredLimit = 4

    /// - Parameters:
    ///   - outputLabel: the stated output space's label, or nil for Same as Source.
    public static func line(name: String, lut: CubeLUT, interpolation: CubeInterpolation,
                            outputLabel: String?, bypassed: Bool, sourcePresent: Bool) -> String {
        var parts = [lut.shapeDescription, lut.cube == nil ? "linear" : interpolation.rawValue]
        if bypassed {
            parts.append("BYPASSED — not applied")
        } else if !sourcePresent {
            parts.append("no source")
        } else {
            parts.append(outputLabel.map { "out \($0) (stated)" } ?? "out same as source")
        }
        if !lut.ignored.isEmpty {
            let named = lut.ignored.prefix(namedIgnoredLimit).map { "\($0.keyword) (line \($0.line))" }
            let more = lut.ignored.count - named.count
            parts.append("ignored: " + named.joined(separator: ", ") + (more > 0 ? ", +\(more) more" : ""))
        }
        return "\(name) — " + parts.joined(separator: " · ")
    }
}
