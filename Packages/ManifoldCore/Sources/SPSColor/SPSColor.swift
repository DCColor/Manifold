//
//  SPSColor.swift
//  SPSColor
//
//  What one sequence parameter set says about colour, per axis — the result type both readers
//  return, and what they share: the CICP tables, emulation-prevention removal and the bit reader.
//  H264SPSColor.swift reads H.264 (docs/COLOR_MANAGEMENT_FINDINGS.md §6.9, Stage SPS);
//  HEVCSPSColor.swift reads HEVC (§6.10, Stage 2). One target, decision 4 of §6.10.
//
//  ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
//
//  Neither live transport could say what colour its stream declared. SRT copied
//  `codecpar->color_*`, which libavformat fills only by DECODING, and the vendored FFmpeg has
//  parsers and no H.264 or HEVC decoder, so every SRT stream arrived undeclared (docs/BUGS.md, "SRT
//  colour always reads UNDECLARED"). WHEP never looked. Both hand the same SPS to VideoToolbox, so
//  one reader per codec serves both, and the FFmpeg build does not change.
//
//  ── WHY NOT COREMEDIA'S READING ────────────────────────────────────────────────────────
//
//  `CMVideoFormatDescriptionCreateFromH264ParameterSets` does put colour extensions on the format
//  description, and it was measured first (Stage SPS, step 1). It is not reliable PER AXIS:
//    * reserved codes come back as if declared (`ColorPrimaries#3`, `#200`, `YCbCrMatrix#99`);
//    * transfer 0 (reserved) and matrix 0 (identity, a real declaration) both vanish;
//    * transfer 6 (BT.601) is respelled `ITU_R_709_2`, so the declared code is gone;
//    * `FullRangeVideo` reads 0 both when the flag says 0 and when the VUI has no flag at all.
//  And VideoToolbox's decoded buffers are worse: an SPS that declares nothing comes out stamped
//  SMPTE-C / 709 / 601, a guess wearing a tag. So the bits are read here, and every rule below is
//  the standard's, not a platform's.
//
//  ── WHAT THE READERS DO NOT DO ─────────────────────────────────────────────────────────
//
//  The colour readers stop after `matrix_coefficients`. Everything before the VUI is stepped over at
//  the width the standard gives it, never interpreted. SAR is stepped over too; applying it is a
//  separate change. HEVC's timing reader (SPSTiming.swift) continues the same walk to `timing_info`.
//
//  They NEVER throw and never trap. A short, truncated, mis-typed or desynchronised SPS returns
//  `.malformed` (or `.notAnSPS`), and both read as undeclared on every axis — the caller's
//  assumed-709 behaviour, exactly what it did before these readers existed.
//

/// What one SPS says about colour, axis by axis. The same for H.264 and HEVC: both VUIs carry
/// `video_signal_type` with the H.273 code points, in the same order.
public struct SPSColor: Equatable, Sendable {

    /// How far into the SPS the colour signalling went. Every case but `.colourDescription` means
    /// all three axes are undeclared; the case says why, for the log.
    public enum Reach: Equatable, Sendable {
        /// Not an SPS NAL (wrong type, or too short to be one). For HEVC, also an SPS that is not the
        /// base layer's (`nuh_layer_id` > 0, decision 8 of §6.10) or carries a forbidden header.
        case notAnSPS
        /// The bits ran out, or a field held a value the standard forbids, before the colour
        /// fields. The parse cannot be trusted past that point, so nothing after it is used.
        case malformed
        /// `vui_parameters_present_flag` = 0. Common: VideoToolbox's own H.264 encoder writes no VUI.
        case noVUI
        /// VUI present, `video_signal_type_present_flag` = 0. x264's default.
        case noVideoSignalType
        /// Signal type present, `colour_description_present_flag` = 0. Range is stated, colour is not.
        case noColourDescription
        /// The three colour fields were read. Each is still checked on its own (see `primaries`).
        case colourDescription
    }

    public let reach: Reach

    /// The SPS's own numbers, verbatim — present only when `reach == .colourDescription`. Kept so
    /// the log can show what the sender wrote (a 2, a reserved 3) rather than only our verdict.
    public let colourPrimaries: Int?
    public let transferCharacteristics: Int?
    public let matrixCoefficients: Int?

    /// `video_full_range_flag`, or nil when the SPS has no `video_signal_type`. RECORDED, NOT ACTED
    /// ON: each transport fixes its range today, and Stage SPS only logs whether this disagrees.
    public let videoFullRangeFlag: Bool?

    public init(reach: Reach, colourPrimaries: Int? = nil, transferCharacteristics: Int? = nil,
                matrixCoefficients: Int? = nil, videoFullRangeFlag: Bool? = nil) {
        self.reach = reach
        self.colourPrimaries = colourPrimaries
        self.transferCharacteristics = transferCharacteristics
        self.matrixCoefficients = matrixCoefficients
        self.videoFullRangeFlag = videoFullRangeFlag
    }

    // MARK: - Per-axis verdict

    /// The declared CICP code for each axis, or nil when that axis is undeclared: absent,
    /// unspecified (2) or reserved. Each axis is judged ALONE — a declared transfer says nothing
    /// about the primaries beside it.
    public var primaries: Int? { colourPrimaries.flatMap { Self.isDeclared(primaries: $0) ? $0 : nil } }
    public var transfer: Int? { transferCharacteristics.flatMap { Self.isDeclared(transfer: $0) ? $0 : nil } }
    public var matrix: Int? { matrixCoefficients.flatMap { Self.isDeclared(matrix: $0) ? $0 : nil } }

    /// The values H.264 Table E-3 / H.265 Table E.3 / ITU-T H.273 define for `colour_primaries`.
    /// 2 is unspecified; 0, 3, 13–21 and 23–255 are reserved.
    public static func isDeclared(primaries code: Int) -> Bool {
        switch code {
        case 1, 4...12, 22: return true
        default:            return false
        }
    }

    /// Table E-4 / E.4 / H.273 `transfer_characteristics`. 2 is unspecified; 0, 3 and 19–255 are reserved.
    public static func isDeclared(transfer code: Int) -> Bool {
        switch code {
        case 1, 4...18: return true
        default:        return false
        }
    }

    /// Table E-5 / E.5 / H.273 `matrix_coefficients`. 2 is unspecified; 3 and 15–255 are reserved.
    /// ⚠️ 0 IS NOT RESERVED HERE, unlike the other two axes: it is Identity (GBR), a declaration.
    public static func isDeclared(matrix code: Int) -> Bool {
        switch code {
        case 0, 1, 4...14: return true
        default:           return false
        }
    }

    /// The result for an SPS that says nothing, whatever the reason.
    public static let undeclared = SPSColor(reach: .noVUI)

    // MARK: - Shared by both readers

    /// Strip emulation prevention: in `00 00 03`, the 03 is an inserted byte, not payload. Reading
    /// without removing it shifts every later bit and yields plausible-looking garbage — a NUMBER,
    /// which is worse than a failure. Identical in H.264 (§7.4.1) and HEVC (§7.4.2).
    static func unescape<Bytes: Collection>(_ bytes: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 0x03 {
                zeros = 0           // drop the escape; a following 03 is a literal
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// SPS NALs are tens of bytes, or a few hundred with explicit scaling lists. A kilobyte is not
    /// an SPS, and refusing it bounds the work.
    static let maximumSPSBytes = 1024

    /// video_signal_type() through the colour description: the same bits in H.264 §E.1.1 and HEVC
    /// §E.2.1, read once the caller has stepped to `video_signal_type_present_flag`.
    static func readVideoSignalType(_ r: inout BitReader) -> SPSColor {
        let signalTypePresent = r.bit()                 // video_signal_type_present_flag
        guard !r.overrun else { return SPSColor(reach: .malformed) }
        guard signalTypePresent == 1 else { return SPSColor(reach: .noVideoSignalType) }

        _ = r.bits(3)                                   // video_format
        let fullRange = r.bit() == 1                    // video_full_range_flag
        let colourDescriptionPresent = r.bit()          // colour_description_present_flag
        guard !r.overrun else { return SPSColor(reach: .malformed) }
        guard colourDescriptionPresent == 1 else {
            return SPSColor(reach: .noColourDescription, videoFullRangeFlag: fullRange)
        }

        let primaries = r.bits(8)                       // colour_primaries
        let transfer = r.bits(8)                        // transfer_characteristics
        let matrix = r.bits(8)                          // matrix_coefficients
        // One test for everything the reader accumulated. Stop here: nothing after is ours.
        guard !r.overrun else { return SPSColor(reach: .malformed) }
        return SPSColor(reach: .colourDescription,
                        colourPrimaries: primaries, transferCharacteristics: transfer,
                        matrixCoefficients: matrix, videoFullRangeFlag: fullRange)
    }
}

// MARK: - Bit reader

/// MSB-first over unescaped RBSP. FAILS CLOSED: past the end, `overrun` is set, stays set, and every
/// read returns 0, so a caller tests it once rather than after every field.
struct BitReader {
    private let data: [UInt8]
    private var position = 0
    private(set) var overrun = false

    init(rbsp: [UInt8]) { data = rbsp }

    mutating func bit() -> Int {
        guard !overrun, position >> 3 < data.count else { overrun = true; return 0 }
        let value = Int(data[position >> 3] >> (7 - UInt8(position & 7))) & 1
        position += 1
        return value
    }

    mutating func bits(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count { value = (value << 1) | bit() }
        return value
    }

    /// ue(v). The leading-zero run is BOUNDED at 31: an unbounded loop over a corrupt buffer is how
    /// a parser hangs, and no SPS field these readers pass needs more. Beyond it is malformed.
    mutating func ue() -> Int {
        var zeros = 0
        while bit() == 0 {
            if overrun { return 0 }
            zeros += 1
            if zeros > 31 { overrun = true; return 0 }
        }
        return zeros == 0 ? 0 : (1 << zeros) - 1 + bits(zeros)
    }

    /// se(v). Read with the right width or the cursor desynchronises, even where the value is unused.
    mutating func se() -> Int {
        let k = ue()
        let magnitude = (k + 1) / 2
        return k & 1 == 1 ? magnitude : -magnitude
    }
}
