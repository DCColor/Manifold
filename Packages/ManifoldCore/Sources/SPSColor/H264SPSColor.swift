//
//  H264SPSColor.swift
//  SPSColor
//
//  The H.264 reader: what one H.264 SPS says about colour, from the VUI's `video_signal_type`,
//  per axis (docs/COLOR_MANAGEMENT_FINDINGS.md §6.9, Stage SPS). Returns the shared `SPSColor`.
//  Why it exists, why CoreMedia's reading is not used, and what it does not do: SPSColor.swift.
//

/// The H.264 reader. A namespace: the result is the codec-neutral `SPSColor`.
public enum H264SPSColor {

    // The names the H.264 reader had before decision 4 (§6.10) moved them to `SPSColor`.
    public typealias Reach = SPSColor.Reach
    public static let undeclared = SPSColor.undeclared
    public static func isDeclared(primaries code: Int) -> Bool { SPSColor.isDeclared(primaries: code) }
    public static func isDeclared(transfer code: Int) -> Bool { SPSColor.isDeclared(transfer: code) }
    public static func isDeclared(matrix code: Int) -> Bool { SPSColor.isDeclared(matrix: code) }
    static func unescape<Bytes: Collection>(_ bytes: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        SPSColor.unescape(bytes)
    }

    // MARK: - Parse

    /// Read `nal` — ONE SPS NAL unit, with its 1-byte NAL header, with NO start code and NO length
    /// prefix (what both access-unit builders store). Never throws.
    public static func parse<Bytes: Collection>(nal: Bytes) -> SPSColor where Bytes.Element == UInt8 {
        // Header + profile_idc + constraint flags + level_idc + at least one bit of the id.
        guard nal.count >= 5, let header = nal.first,
              header & 0x80 == 0,          // forbidden_zero_bit
              header & 0x1F == 7 else {    // nal_unit_type 7 = SPS. A PPS must not parse as one.
            return SPSColor(reach: .notAnSPS)
        }
        guard nal.count <= SPSColor.maximumSPSBytes else { return SPSColor(reach: .malformed) }

        var reader = BitReader(rbsp: SPSColor.unescape(nal.dropFirst()))
        return readSPS(&reader)
    }

    // MARK: - seq_parameter_set_data(), H.264 §7.3.2.1.1, up to the colour fields only

    private static func readSPS(_ r: inout BitReader) -> SPSColor {
        let malformed = SPSColor(reach: .malformed)

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
        guard vuiPresent == 1 else { return SPSColor(reach: .noVUI) }

        if r.bit() == 1 {                               // aspect_ratio_info_present_flag
            if r.bits(8) == 255 {                       // aspect_ratio_idc == Extended_SAR
                _ = r.bits(16)                          // sar_width
                _ = r.bits(16)                          // sar_height
            }
        }
        if r.bit() == 1 { _ = r.bit() }                 // overscan_info_present → overscan_appropriate
        return SPSColor.readVideoSignalType(&r)         // video_signal_type() to matrix_coefficients
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
