//
//  SourceBitDepth.swift
//  ColorimetryModel
//
//  The per-frame "8-bit source" flag (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, *8-bit sources mapped
//  exactly ×4*; docs/BUGS.md). Every decoded buffer the renderer samples is 10-bit (`x420` / `x422` /
//  `x444`), and when VideoToolbox widens an 8-bit source into one it uses a full-scale map (≈ v·1023/255,
//  measured between 4v and 4v+3), not BT.709 / BT.2100's ×4: mid-grey 128 → 514, white 235 → 943. The
//  shader clears the two low bits of a flagged buffer's samples, which is exact for every map measured.
//
//  ⚠️ A FLAG, NOT A GUESS. Set only where the source's bit depth is KNOWN to be 8 (the SPS, the file's
//  `avcC` / `hvcC`, the NDI frame format). A 10-bit source flagged 8-bit would lose its two low bits, so
//  absent means "not 8-bit" and every route that does not set it is untouched.
//

import CoreVideo

public enum SourceBitDepth {

    /// The attachment's key. Not propagated: a buffer made FROM a flagged one (a promote) is flagged by
    /// the code that made it, from what it knows, rather than by VideoToolbox's propagation rules.
    public static let attachmentKey = "ManifoldEightBitSource" as CFString

    /// Whether a source of these bit depths is 8-bit on both planes: the only case the flag describes.
    public static func isEightBit(luma: Int, chroma: Int) -> Bool { luma == 8 && chroma == 8 }

    /// Flag `buffer` as decoded from an 8-bit source (`true`), or clear the flag (`false`) — a pooled
    /// buffer can carry a previous frame's attachment, so a producer that flags states both answers.
    public static func mark(_ buffer: CVBuffer, eightBit: Bool) {
        if eightBit {
            CVBufferSetAttachment(buffer, attachmentKey, kCFBooleanTrue, .shouldNotPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, attachmentKey)
        }
    }

    /// Whether `buffer` is flagged.
    public static func isEightBit(_ buffer: CVBuffer) -> Bool {
        (CVBufferCopyAttachment(buffer, attachmentKey, nil) as? Bool) == true
    }

    /// Carry the flag from the buffer a promote read to the buffer it wrote.
    public static func carry(from source: CVBuffer, to destination: CVBuffer) {
        mark(destination, eightBit: isEightBit(source))
    }
}
