//
//  H264SPSColor.swift
//  H264SPSColor
//
//  What one H.264 sequence parameter set says about colour: the VUI's `video_signal_type` block,
//  read per axis. SRT and WHEP both use it (docs/COLOR_MANAGEMENT_FINDINGS.md §6.9, Stage SPS).
//
//  ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
//
//  Neither live H.264 transport could say what colour its stream declared. SRT copied
//  `codecpar->color_*`, which libavformat fills only by DECODING, and the vendored FFmpeg has the
//  H.264 parser and no decoder, so every SRT stream arrived undeclared (docs/BUGS.md, "SRT colour
//  always reads UNDECLARED"). WHEP never looked. Both hand the same SPS to VideoToolbox, so one
//  reader serves both, and the FFmpeg build does not change.
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
//  ── WHAT IT DOES NOT DO ────────────────────────────────────────────────────────────────
//
//  It stops after `matrix_coefficients`. Nothing after the colour fields is read: not
//  chroma_loc_info, not timing (App/H264/H264SPSTiming.c does that), not the bitstream
//  restriction. Everything before the VUI is stepped over at the width the standard gives it,
//  never interpreted. SAR is stepped over too; applying it is a separate change.
//
//  It NEVER throws and never traps. A short, truncated, mis-typed or desynchronised SPS returns
//  `.malformed` (or `.notAnSPS`), and both read as undeclared on every axis — the caller's
//  assumed-709 behaviour, exactly what it did before this reader existed.
//

/// What one SPS says about colour, axis by axis.
public struct H264SPSColor: Equatable, Sendable {

    /// How far into the SPS the colour signalling went. Every case but `.colourDescription` means
    /// all three axes are undeclared; the case says why, for the log.
    public enum Reach: Equatable, Sendable {
        /// Not an SPS NAL (wrong type, or too short to be one).
        case notAnSPS
        /// The bits ran out, or a field held a value the standard forbids, before the colour
        /// fields. The parse cannot be trusted past that point, so nothing after it is used.
        case malformed
        /// `vui_parameters_present_flag` = 0. Common: VideoToolbox's own encoder writes no VUI.
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

    /// The values H.264 Table E-3 / ITU-T H.273 define for `colour_primaries`. 2 is unspecified;
    /// 0, 3, 13–21 and 23–255 are reserved.
    public static func isDeclared(primaries code: Int) -> Bool {
        switch code {
        case 1, 4...12, 22: return true
        default:            return false
        }
    }

    /// Table E-4 / H.273 `transfer_characteristics`. 2 is unspecified; 0, 3 and 19–255 are reserved.
    public static func isDeclared(transfer code: Int) -> Bool {
        switch code {
        case 1, 4...18: return true
        default:        return false
        }
    }

    /// Table E-5 / H.273 `matrix_coefficients`. 2 is unspecified; 3 and 15–255 are reserved.
    /// ⚠️ 0 IS NOT RESERVED HERE, unlike the other two axes: it is Identity (GBR), a declaration.
    public static func isDeclared(matrix code: Int) -> Bool {
        switch code {
        case 0, 1, 4...14: return true
        default:           return false
        }
    }

    /// The result for an SPS that says nothing, whatever the reason.
    public static let undeclared = H264SPSColor(reach: .noVUI)

    // MARK: - Parse

    /// Read `nal` — ONE SPS NAL unit, with its 1-byte NAL header, with NO start code and NO length
    /// prefix (what both access-unit builders store). Never throws.
    public static func parse<Bytes: Collection>(nal: Bytes) -> H264SPSColor where Bytes.Element == UInt8 {
        // Header + profile_idc + constraint flags + level_idc + at least one bit of the id.
        guard nal.count >= 5, let header = nal.first,
              header & 0x80 == 0,          // forbidden_zero_bit
              header & 0x1F == 7 else {    // nal_unit_type 7 = SPS. A PPS must not parse as one.
            return H264SPSColor(reach: .notAnSPS)
        }
        // SPS NALs are tens of bytes. A kilobyte is not an SPS, and refusing it bounds the work.
        guard nal.count <= 1024 else { return H264SPSColor(reach: .malformed) }

        var reader = BitReader(rbsp: unescape(nal.dropFirst()))
        return readSPS(&reader)
    }

    /// Strip emulation prevention: in `00 00 03`, the 03 is an inserted byte, not payload. Reading
    /// without removing it shifts every later bit and yields plausible-looking garbage — a NUMBER,
    /// which is worse than a failure.
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

    // MARK: - seq_parameter_set_data(), H.264 §7.3.2.1.1, up to the colour fields only

    private static func readSPS(_ r: inout BitReader) -> H264SPSColor {
        let malformed = H264SPSColor(reach: .malformed)

        let profileIdc = r.bits(8)
        _ = r.bits(8)                                   // constraint_set0..5_flag + reserved_zero_2bits
        _ = r.bits(8)                                   // level_idc
        guard r.ue() <= 31 else { return malformed }    // seq_parameter_set_id

        // The high-profile block, present ONLY for these profile_idc values. The most commonly
        // botched part of SPS parsing: getting the list wrong shifts everything after it.
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profileIdc) {
            let chromaFormatIdc = r.ue()
            guard chromaFormatIdc <= 3 else { return malformed }
            if chromaFormatIdc == 3 { _ = r.bit() }     // separate_colour_plane_flag
            guard r.ue() <= 6, r.ue() <= 6 else { return malformed }   // bit_depth_luma/chroma_minus8
            _ = r.bit()                                 // qpprime_y_zero_transform_bypass_flag
            if r.bit() == 1 {                           // seq_scaling_matrix_present_flag
                let lists = chromaFormatIdc != 3 ? 8 : 12
                for i in 0..<lists where r.bit() == 1 { // seq_scaling_list_present_flag[i]
                    guard skipScalingList(&r, size: i < 6 ? 16 : 64) else { return malformed }
                }
            }
        }

        guard r.ue() <= 12 else { return malformed }    // log2_max_frame_num_minus4
        switch r.ue() {                                 // pic_order_cnt_type
        case 0:
            guard r.ue() <= 12 else { return malformed } // log2_max_pic_order_cnt_lsb_minus4
        case 1:
            _ = r.bit()                                 // delta_pic_order_always_zero_flag
            _ = r.se()                                  // offset_for_non_ref_pic
            _ = r.se()                                  // offset_for_top_to_bottom_field
            let cycle = r.ue()                          // num_ref_frames_in_pic_order_cnt_cycle
            guard cycle <= 255 else { return malformed }
            for _ in 0..<cycle { _ = r.se() }           // offset_for_ref_frame[i]
        case 2:
            break
        default:
            return malformed
        }

        _ = r.ue()                                      // max_num_ref_frames
        _ = r.bit()                                     // gaps_in_frame_num_value_allowed_flag
        _ = r.ue()                                      // pic_width_in_mbs_minus1
        _ = r.ue()                                      // pic_height_in_map_units_minus1
        if r.bit() == 0 { _ = r.bit() }                 // frame_mbs_only_flag → mb_adaptive_frame_field_flag
        _ = r.bit()                                     // direct_8x8_inference_flag
        if r.bit() == 1 {                               // frame_cropping_flag
            for _ in 0..<4 { _ = r.ue() }               // left, right, top, bottom offsets
        }

        // ── vui_parameters(), H.264 §E.1.1 — optional, and absent is common ────────────────
        let vuiPresent = r.bit()
        guard !r.overrun else { return malformed }
        guard vuiPresent == 1 else { return H264SPSColor(reach: .noVUI) }

        if r.bit() == 1 {                               // aspect_ratio_info_present_flag
            if r.bits(8) == 255 {                       // aspect_ratio_idc == Extended_SAR
                _ = r.bits(16)                          // sar_width
                _ = r.bits(16)                          // sar_height
            }
        }
        if r.bit() == 1 { _ = r.bit() }                 // overscan_info_present → overscan_appropriate
        let signalTypePresent = r.bit()                 // video_signal_type_present_flag
        guard !r.overrun else { return malformed }
        guard signalTypePresent == 1 else { return H264SPSColor(reach: .noVideoSignalType) }

        _ = r.bits(3)                                   // video_format
        let fullRange = r.bit() == 1                    // video_full_range_flag
        let colourDescriptionPresent = r.bit()          // colour_description_present_flag
        guard !r.overrun else { return malformed }
        guard colourDescriptionPresent == 1 else {
            return H264SPSColor(reach: .noColourDescription, videoFullRangeFlag: fullRange)
        }

        let primaries = r.bits(8)                       // colour_primaries
        let transfer = r.bits(8)                        // transfer_characteristics
        let matrix = r.bits(8)                          // matrix_coefficients
        // One test for everything the reader accumulated. Stop here: nothing after is ours.
        guard !r.overrun else { return malformed }
        return H264SPSColor(reach: .colourDescription,
                            colourPrimaries: primaries, transferCharacteristics: transfer,
                            matrixCoefficients: matrix, videoFullRangeFlag: fullRange)
    }

    /// H.264 §7.3.2.1.1.1 scaling_list(). Its length depends on its own contents, so it is walked.
    /// Returns false if a delta is outside the standard's −128…127.
    private static func skipScalingList(_ r: inout BitReader, size: Int) -> Bool {
        var lastScale = 8, nextScale = 8
        for _ in 0..<size where !r.overrun {
            if nextScale != 0 {
                let delta = r.se()                      // delta_scale
                guard (-128...127).contains(delta) else { return false }
                nextScale = (lastScale + delta + 256) % 256
            }
            lastScale = nextScale == 0 ? lastScale : nextScale
        }
        return !r.overrun
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
    /// a parser hangs, and no SPS field this reader passes needs more. Beyond it is malformed.
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
