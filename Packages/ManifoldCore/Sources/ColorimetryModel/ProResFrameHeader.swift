import Foundation

/// The colour a ProRes frame states about itself: its frame header's `color_primaries`, `transfer_characteristic`
/// and `matrix_coefficients` (SMPTE RDD 36, the frame header after the `icpf` frame box).
///
/// ── WHY IT IS READ HERE ─────────────────────────────────────────────────────────────────────────────
///
/// On the libav route the decoder's statement is the decoded frame's colour, and for ProRes that is exactly these
/// three bytes: libav's `prores` decoder copies them, raw, into every frame (`decode_frame_header`). The VideoToolbox
/// route (`ProResVideoToolboxDecoder`) has no libav frame, so it reads the same three bytes from the packet. The
/// container-versus-decoder comparison (`ContainerColorPolicy`) and the per-axis tagging then see what they would
/// have seen had libav decoded the packet. No new interpretation: the codes are passed on as stated.
public enum ProResFrameHeader {

    /// The frame's three codes, as stated (0 and 2 mean "unspecified", as everywhere in `ContainerColorPolicy`).
    /// nil when the bytes are not a ProRes frame: shorter than libav's 28-byte floor, no `icpf` box, or a frame
    /// header too short to reach the colour fields.
    public static func color(_ frame: UnsafeRawBufferPointer) -> (primaries: Int, transfer: Int, matrix: Int)? {
        guard frame.count >= 28,
              frame[4] == UInt8(ascii: "i"), frame[5] == UInt8(ascii: "c"),
              frame[6] == UInt8(ascii: "p"), frame[7] == UInt8(ascii: "f") else { return nil }
        // The frame header follows the 8-byte box. Its first two bytes are its own size, big-endian; the colour
        // fields are its bytes 14, 15 and 16.
        let headerSize = Int(frame[8]) << 8 | Int(frame[9])
        guard headerSize >= 17, 8 + headerSize <= frame.count else { return nil }
        return (Int(frame[8 + 14]), Int(frame[8 + 15]), Int(frame[8 + 16]))
    }
}
