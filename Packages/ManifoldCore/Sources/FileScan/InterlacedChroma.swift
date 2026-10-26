//
//  InterlacedChroma.swift
//  FileScan
//
//  Per-field 4:2:0 chroma (docs/INTERLACED_FINDINGS.md §8, stage I3). In a woven interlaced 4:2:0 picture each chroma
//  row belongs to ONE field: row c to field c mod 2 (top field = even rows, whatever the temporal order). The progressive
//  upsample mixes neighbouring chroma rows, which here are the two fields, so field 2's colour bled into field 1's in the
//  frame the window, scopes, export and SDI all read.
//
//  THE RULE: a woven interlaced file's 4:2:0 chroma is reconstructed from the fragment's own field. A field sequence
//  (`SourceScan.picturesAreFields`: each coded picture is one field) is already per field, so it keeps the progressive
//  upsample, as does anything progressive or unknown. 4:2:2 and 4:4:4 have a chroma row per line and no vertical upsample.
//
//  THE FILTER (`taps`): chroma row c sits at frame line 2c + 0.5 — MPEG-2's interlaced siting (a top-field chroma row ¼
//  of the way between its field's lines, a bottom-field one ¾), the same place the progressive upsample already assumes —
//  so only the neighbours change. Frame line y of field f = y mod 2 interpolates linearly between the nearest two chroma
//  rows OF ITS FIELD: t = (y − 2f − 0.5) / 4, rows 2⌊t⌋ + f and 2⌊t⌋ + 2 + f, weight frac(t). The weights come out as
//  5/8·3/8 and 1/8·7/8 on the top field and 7/8·1/8 and 3/8·5/8 on the bottom, clamped within the field at the edges.
//  `passthroughFragment` (PassthroughShader.metal) restates this; these tests pin it.
//

import Foundation

public enum InterlacedChroma {

    /// Whether a source's 4:2:0 chroma is reconstructed per field: woven interlaced pictures only.
    public static func perField(_ scan: SourceScan) -> Bool { scan.isInterlaced && !scan.picturesAreFields }

    /// The two chroma rows frame line `lumaRow` mixes, and the weight of the second.
    public struct Taps: Equatable, Sendable {
        public let rowA: Int
        public let rowB: Int
        public let weightB: Double
    }

    /// `chromaRows` is the 4:2:0 chroma plane's height (half the luma's, rounded up).
    public static func taps(lumaRow y: Int, chromaRows: Int) -> Taps {
        let f = y & 1
        let t = (Double(y - 2 * f) - 0.5) / 4
        let j0 = t.rounded(.down)
        let last = max((chromaRows - 1 - f) / 2, 0)
        let ja = min(max(Int(j0), 0), last), jb = min(max(Int(j0) + 1, 0), last)
        return Taps(rowA: min(2 * ja + f, chromaRows - 1), rowB: min(2 * jb + f, chromaRows - 1), weightB: t - j0)
    }
}
