// Dumps the CGColorSpace that CVImageBufferCreateColorSpaceFromAttachments returns for the exact
// attachment sets MetalVideoRenderer.makeColorSpace builds. That function is a pure function of
// three CICP integers, so this reproduces it without needing a file, a decoder, or the app.
//
// Prints the reported name and IDENTITY comparisons against every plausible system constant, then
// writes the raw ICC bytes to disk for byte-level parsing.
import Foundation
import CoreVideo
import CoreGraphics

// ── verbatim from MetalVideoRenderer.makeColorSpace ─────────────────────────────────────────────
func transferAttachment(_ code: Int?) -> CFString? {
    switch code {
    case 1:  return kCVImageBufferTransferFunction_ITU_R_709_2
    case 16: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    case 18: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
    default: return nil
    }
}
func matrixAttachment(_ code: Int?) -> CFString? {
    switch code {
    case 1: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
    case 9: return kCVImageBufferYCbCrMatrix_ITU_R_2020
    default: return nil
    }
}
func makeColorSpace(primaries: Int?, transfer: Int?, matrix: Int?) -> CGColorSpace? {
    let p709 = kCVImageBufferColorPrimaries_ITU_R_709_2
    let t709 = kCVImageBufferTransferFunction_ITU_R_709_2
    let m709 = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    let prim: CFString, trans: CFString, mat: CFString
    switch (primaries, transfer) {
    case (12, _):
        prim = kCVImageBufferColorPrimaries_P3_D65
        trans = transferAttachment(transfer) ?? t709
        mat = matrixAttachment(matrix) ?? m709
    case (9, 16):
        prim = kCVImageBufferColorPrimaries_ITU_R_2020
        trans = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        mat = kCVImageBufferYCbCrMatrix_ITU_R_2020
    case (9, 18):
        prim = kCVImageBufferColorPrimaries_ITU_R_2020
        trans = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        mat = kCVImageBufferYCbCrMatrix_ITU_R_2020
    case (1, 1):
        prim = p709; trans = t709; mat = m709
    default:
        prim = p709; trans = t709; mat = m709
    }
    let dict: [CFString: Any] = [
        kCVImageBufferColorPrimariesKey: prim,
        kCVImageBufferTransferFunctionKey: trans,
        kCVImageBufferYCbCrMatrixKey: mat
    ]
    if let cs = CVImageBufferCreateColorSpaceFromAttachments(dict as CFDictionary)?.takeRetainedValue() {
        return cs
    }
    return CGColorSpace(name: CGColorSpace.itur_709)
}

// ── identity comparison against every constant worth ruling out ────────────────────────────────
let candidates: [(String, CFString)] = [
    ("kCGColorSpaceITUR_709",             CGColorSpace.itur_709),
    ("kCGColorSpaceITUR_709_PQ",          "kCGColorSpaceITUR_709_PQ" as CFString),
    ("kCGColorSpaceITUR_709_HLG",         "kCGColorSpaceITUR_709_HLG" as CFString),
    ("kCGColorSpaceCoreMedia709",         "kCGColorSpaceCoreMedia709" as CFString),
    ("kCGColorSpaceDisplayP3",            CGColorSpace.displayP3),
    ("kCGColorSpaceDisplayP3_PQ",         "kCGColorSpaceDisplayP3_PQ" as CFString),
    ("kCGColorSpaceDisplayP3_HLG",        "kCGColorSpaceDisplayP3_HLG" as CFString),
    ("kCGColorSpaceITUR_2020",            CGColorSpace.itur_2020),
    ("kCGColorSpaceITUR_2100_PQ",         CGColorSpace.itur_2100_PQ),
    ("kCGColorSpaceITUR_2100_HLG",        CGColorSpace.itur_2100_HLG),
    ("kCGColorSpaceSRGB",                 CGColorSpace.sRGB),
    ("kCGColorSpaceGenericRGBLinear",     CGColorSpace.genericRGBLinear),
]

let cases: [(label: String, p: Int?, t: Int?, m: Int?)] = [
    ("709  (primaries 1, transfer 1, matrix 1)",  1,  1, 1),
    ("P3   (primaries 12, transfer 1, matrix 1)", 12, 1, 1),
    ("PQ   (primaries 9, transfer 16, matrix 9)",  9, 16, 9),
    ("HLG  (primaries 9, transfer 18, matrix 9)",  9, 18, 9),
    ("untagged fallback (nil,nil,nil)",         nil, nil, nil),
]

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

for c in cases {
    print("═══════════════════════════════════════════════════════════════════════")
    print("CASE: \(c.label)")
    guard let cs = makeColorSpace(primaries: c.p, transfer: c.t, matrix: c.m) else {
        print("  makeColorSpace returned nil"); continue
    }
    let name = cs.name.map { String($0) } ?? "<nil / unnamed>"
    print("  CGColorSpaceCopyName        : \(name)")
    print("  model                       : \(cs.model)")
    print("  isWideGamutRGB              : \(cs.isWideGamutRGB)")
    print("  usesITUR_2100TF             : \(CGColorSpaceUsesITUR_2100TF(cs))")
    print("  numberOfComponents          : \(cs.numberOfComponents)")

    // IDENTITY, not assumption.
    var hits: [String] = []
    for (label, constant) in candidates {
        guard let ref = CGColorSpace(name: constant) else { continue }
        if CFEqual(cs, ref) { hits.append("CFEqual==\(label)") }
        if let n = cs.name, CFEqual(n, constant) { hits.append("nameEqual==\(label)") }
    }
    print("  identity matches            : \(hits.isEmpty ? "NONE of the tested constants" : hits.joined(separator: ", "))")

    if let icc = cs.copyICCData() as Data? {
        let f = outDir.appendingPathComponent(c.label.prefix(3).trimmingCharacters(in: .whitespaces) + ".icc")
        try! icc.write(to: f)
        print("  CGColorSpaceCopyICCData     : \(icc.count) bytes → \(f.lastPathComponent)")
    } else {
        print("  CGColorSpaceCopyICCData     : nil (no ICC representation)")
    }
}
print("═══════════════════════════════════════════════════════════════════════")
