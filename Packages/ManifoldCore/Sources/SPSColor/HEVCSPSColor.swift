//
//  HEVCSPSColor.swift
//  SPSColor
//
//  The HEVC reader: what one H.265 SPS says about colour, from the VUI's `video_signal_type`, per
//  axis (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 2). Returns the shared `SPSColor`.
//
//  ── WHY IT IS LONGER THAN THE H.264 READER ─────────────────────────────────────────────
//
//  In HEVC the colour fields come after almost everything else in the SPS, and much of what comes
//  first has a length that depends on its own contents: `profile_tier_level` with its sub-layers,
//  the HEVC scaling lists, and above all the short-term reference picture sets, where an
//  inter-predicted set carries one flag per picture of the set BEFORE it. None of it is used here,
//  and all of it has to be walked at exactly its width, or the colour fields are read from the
//  wrong bits — a plausible NUMBER, which is worse than nothing.
//
//  Every count and size is checked against the bound the standard gives it, as the walk goes. Real
//  streams sit well inside those bounds; a desynchronised parse almost never does, so the bounds
//  are what turn a misread into `.malformed` rather than a wrong colour.
//
//  ── SCOPE ──────────────────────────────────────────────────────────────────────────────
//
//  Base layer only (decision 8): an SPS with `nuh_layer_id` > 0 has a different syntax and is
//  `.notAnSPS`. The SPS extensions come AFTER the VUI, so they never need parsing. The colour walk
//  reads nothing after `matrix_coefficients`; `timing` continues it to `vui_timing_info` (Stage 4).
//  Never throws, never traps.
//

/// The HEVC reader. A namespace: the result is the codec-neutral `SPSColor`.
public enum HEVCSPSColor {

    /// Read `nal` — ONE SPS NAL unit, with its 2-byte NAL header, with NO start code and NO length
    /// prefix. Never throws.
    public static func parse<Bytes: Collection>(nal: Bytes) -> SPSColor where Bytes.Element == UInt8 {
        walk(nal: nal).color
    }

    // MARK: - What the walk stepped over

    /// Every structural field the walk passes on the way to the colour fields. NOT used by anything:
    /// kept so the tests can check the walk against FFmpeg's `trace_headers` field by field, which
    /// is far stronger than checking only the colour it ends on.
    struct Walk: Equatable {
        var maxSubLayersMinus1 = 0
        var chromaFormatIdc = 0
        var width = 0
        var height = 0
        var confWin = [0, 0, 0, 0]                      // left, right, top, bottom
        var bitDepthLumaMinus8 = 0
        var bitDepthChromaMinus8 = 0
        var log2MaxPocLsbMinus4 = 0
        var scalingListEnabled = false
        var scalingListDataPresent = false
        var pcmEnabled = false
        var numDeltaPocs: [Int] = []                    // per short-term RPS, in order
        var numInterPredicted = 0
        var numLongTermRefPicsSps = 0
        var aspectRatioIdc: Int? = nil
        var sarWidth: Int? = nil
        var sarHeight: Int? = nil
    }

    /// Deliberately broken readers, for the tests only: each must FAIL CLOSED (read undeclared) on
    /// every fixture its defect touches, never produce a colour. (§6.10, Stage 2, prediction 3.)
    enum Mutant {
        case keepEmulationPrevention          // the 03 in 00 00 03 left in the payload
        case skipShortTermRefPicSets          // num_short_term_ref_pic_sets read, the sets not walked
        case interPredictionReadAsExplicit    // an inter-predicted set read as an explicit one
    }

    static func walk<Bytes: Collection>(nal: Bytes, mutant: Mutant? = nil) -> (color: SPSColor, walk: Walk)
    where Bytes.Element == UInt8 {
        let all = walkAll(nal: nal, mutant: mutant)
        return (all.color, all.walk)
    }

    // MARK: - The format: profile, chroma format, bit depths

    /// What the SRT gate needs from an HEVC SPS (§6.10, Stage 3; decision 7): the general profile, the
    /// chroma format and the bit depths. Read by the same walk as the colour, which stops at
    /// `matrix_coefficients`; the format fields come early in it, so an SPS damaged LATER still has a
    /// format. `nil` when the SPS ends, or is out of range, before the bit depths.
    public static func format<Bytes: Collection>(nal: Bytes) -> HEVCSPSFormat? where Bytes.Element == UInt8 {
        let all = walkAll(nal: nal, mutant: nil)
        guard all.shape.bitDepthsRead else { return nil }
        return HEVCSPSFormat(generalProfileIdc: all.shape.generalProfileIdc,
                             generalProfileCompatibility: all.shape.generalProfileCompatibility,
                             chromaFormatIdc: all.walk.chromaFormatIdc,
                             bitDepthLuma: all.walk.bitDepthLumaMinus8 + 8,
                             bitDepthChroma: all.walk.bitDepthChromaMinus8 + 8)
    }

    // MARK: - Timing (§6.10, Stage 4)

    /// The SPS VUI's `vui_timing_info`, or nil when the SPS declares none or cannot be read that far.
    /// The walk is the colour walk, continued past `video_signal_type`.
    public static func timing<Bytes: Collection>(nal: Bytes) -> SPSTiming? where Bytes.Element == UInt8 {
        // The same header and size checks as the colour walk, which `walkAll` makes; repeated here only
        // because the reader has to be kept to continue from.
        guard nal.count >= 4, nal.count <= SPSColor.maximumSPSBytes else { return nil }
        let b0 = nal[nal.startIndex], b1 = nal[nal.index(after: nal.startIndex)]
        guard b0 & 0x80 == 0, (b0 >> 1) & 0x3F == 33, ((b0 & 1) << 5) | (b1 >> 3) == 0, b1 & 0x07 != 0
        else { return nil }
        var r = BitReader(rbsp: SPSColor.unescape(nal.dropFirst(2)))
        var w = Walk(), shape = Shape()
        switch readSPS(&r, &w, &shape, nil).reach {
        case .noVideoSignalType, .noColourDescription, .colourDescription: break
        default: return nil
        }
        // vui_parameters(), §E.2.1, from chroma_loc_info_present_flag.
        if r.bit() == 1 {                               // chroma_loc_info_present_flag
            guard r.ue() <= 5, r.ue() <= 5 else { return nil }  // chroma_sample_loc_type_top/bottom_field
        }
        _ = r.bit()                                     // neutral_chroma_indication_flag
        let fieldSequence = r.bit() == 1                // field_seq_flag
        _ = r.bit()                                     // frame_field_info_present_flag
        if r.bit() == 1 {                               // default_display_window_flag
            for _ in 0..<4 { _ = r.ue() }               // def_disp_win_left/right/top/bottom_offset
        }
        guard r.bit() == 1, !r.overrun else { return nil }      // vui_timing_info_present_flag
        return SPSTiming.read(&r, source: .sps, fieldSequence: fieldSequence)
    }

    /// A VPS's `vps_timing_info`, or nil when it declares none or cannot be read that far. ONE VPS NAL,
    /// 2-byte header, no start code or length prefix. §7.3.2.1.
    public static func vpsTiming<Bytes: Collection>(nal: Bytes) -> SPSTiming? where Bytes.Element == UInt8 {
        guard nal.count >= 4, nal.count <= SPSColor.maximumSPSBytes else { return nil }
        let b0 = nal[nal.startIndex], b1 = nal[nal.index(after: nal.startIndex)]
        guard b0 & 0x80 == 0, (b0 >> 1) & 0x3F == 32,  // nal_unit_type 32 = VPS
              ((b0 & 1) << 5) | (b1 >> 3) == 0, b1 & 0x07 != 0 else { return nil }
        var r = BitReader(rbsp: SPSColor.unescape(nal.dropFirst(2)))
        _ = r.bits(4)                                   // vps_video_parameter_set_id
        _ = r.bits(2)                                   // vps_base_layer_internal/available_flag
        _ = r.bits(6)                                   // vps_max_layers_minus1
        let maxSubLayersMinus1 = r.bits(3)              // vps_max_sub_layers_minus1
        guard maxSubLayersMinus1 <= 6 else { return nil }
        _ = r.bit()                                     // vps_temporal_id_nesting_flag
        guard r.bits(16) == 0xFFFF else { return nil }  // vps_reserved_0xffff_16bits
        var shape = Shape()
        guard skipProfileTierLevel(&r, maxSubLayersMinus1: maxSubLayersMinus1, shape: &shape) else { return nil }
        let orderingInfoPresent = r.bit()               // vps_sub_layer_ordering_info_present_flag
        for _ in (orderingInfoPresent == 1 ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
            let buffering = r.ue()                      // vps_max_dec_pic_buffering_minus1
            let reorder = r.ue()                        // vps_max_num_reorder_pics
            _ = r.ue()                                  // vps_max_latency_increase_plus1
            guard buffering <= 15, reorder <= buffering else { return nil }
        }
        let maxLayerId = r.bits(6)                      // vps_max_layer_id
        let numLayerSetsMinus1 = r.ue()                 // vps_num_layer_sets_minus1: 0…1023
        guard maxLayerId <= 62, numLayerSetsMinus1 <= 1023 else { return nil }
        if numLayerSetsMinus1 > 0 {
            for _ in 1...numLayerSetsMinus1 where !r.overrun {
                _ = r.bits(maxLayerId + 1)              // layer_id_included_flag[i][0…vps_max_layer_id]
            }
        }
        guard r.bit() == 1, !r.overrun else { return nil }      // vps_timing_info_present_flag
        return SPSTiming.read(&r, source: .vps)
    }

    /// What `format` reads that `Walk` does not hold. Kept out of `Walk` so that the thirty
    /// field-by-field `trace_headers` expectations stay exactly what Stage 2 verified.
    private struct Shape {
        var generalProfileIdc = 0
        var generalProfileCompatibility: UInt32 = 0
        var bitDepthsRead = false
    }

    private static func walkAll<Bytes: Collection>(nal: Bytes, mutant: Mutant?)
    -> (color: SPSColor, walk: Walk, shape: Shape) where Bytes.Element == UInt8 {
        var w = Walk()
        var shape = Shape()
        // The 2-byte header (§7.3.1.2): forbidden_zero_bit, nal_unit_type(6), nuh_layer_id(6),
        // nuh_temporal_id_plus1(3). Plus at least the VPS id and the sub-layer count.
        guard nal.count >= 4 else { return (SPSColor(reach: .notAnSPS), w, shape) }
        let b0 = nal[nal.startIndex], b1 = nal[nal.index(after: nal.startIndex)]
        guard b0 & 0x80 == 0,                           // forbidden_zero_bit
              (b0 >> 1) & 0x3F == 33,                   // nal_unit_type 33 = SPS. A VPS or PPS must not parse as one.
              ((b0 & 1) << 5) | (b1 >> 3) == 0,         // nuh_layer_id 0: base layer only (decision 8)
              b1 & 0x07 != 0 else {                     // nuh_temporal_id_plus1 0 is forbidden
            return (SPSColor(reach: .notAnSPS), w, shape)
        }
        guard nal.count <= SPSColor.maximumSPSBytes else { return (SPSColor(reach: .malformed), w, shape) }

        let payload = nal.dropFirst(2)
        var r = BitReader(rbsp: mutant == .keepEmulationPrevention ? Array(payload) : SPSColor.unescape(payload))
        let color = readSPS(&r, &w, &shape, mutant)
        return (color, w, shape)
    }

    // MARK: - seq_parameter_set_rbsp(), H.265 §7.3.2.2.1, nuh_layer_id 0, up to the colour fields

    private static func readSPS(_ r: inout BitReader, _ w: inout Walk, _ shape: inout Shape,
                                _ mutant: Mutant?) -> SPSColor {
        let malformed = SPSColor(reach: .malformed)

        _ = r.bits(4)                                   // sps_video_parameter_set_id
        let maxSubLayersMinus1 = r.bits(3)              // sps_max_sub_layers_minus1
        guard maxSubLayersMinus1 <= 6 else { return malformed }   // 7 is not allowed
        w.maxSubLayersMinus1 = maxSubLayersMinus1
        _ = r.bit()                                     // sps_temporal_id_nesting_flag
        guard skipProfileTierLevel(&r, maxSubLayersMinus1: maxSubLayersMinus1, shape: &shape) else { return malformed }

        guard r.ue() <= 15 else { return malformed }    // sps_seq_parameter_set_id
        let chromaFormatIdc = r.ue()
        guard chromaFormatIdc <= 3 else { return malformed }
        w.chromaFormatIdc = chromaFormatIdc
        if chromaFormatIdc == 3 { _ = r.bit() }         // separate_colour_plane_flag
        w.width = r.ue()                                // pic_width_in_luma_samples
        w.height = r.ue()                               // pic_height_in_luma_samples
        guard w.width > 0, w.height > 0 else { return malformed }
        if r.bit() == 1 {                               // conformance_window_flag
            w.confWin = [r.ue(), r.ue(), r.ue(), r.ue()] // left, right, top, bottom offsets
        }
        w.bitDepthLumaMinus8 = r.ue()
        w.bitDepthChromaMinus8 = r.ue()
        guard w.bitDepthLumaMinus8 <= 8, w.bitDepthChromaMinus8 <= 8 else { return malformed }
        shape.bitDepthsRead = !r.overrun
        w.log2MaxPocLsbMinus4 = r.ue()                  // log2_max_pic_order_cnt_lsb_minus4
        guard w.log2MaxPocLsbMinus4 <= 12 else { return malformed }

        // Sub-layer ordering: one triple per sub-layer, or only the highest one's.
        let orderingInfoPresent = r.bit()
        var maxDecPicBufferingMinus1 = 0
        for _ in (orderingInfoPresent == 1 ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
            maxDecPicBufferingMinus1 = r.ue()           // sps_max_dec_pic_buffering_minus1
            let reorder = r.ue()                        // sps_max_num_reorder_pics
            _ = r.ue()                                  // sps_max_latency_increase_plus1
            // MaxDpbSize is at most 16 (§A.4.2), and reordering cannot exceed the buffer.
            guard maxDecPicBufferingMinus1 <= 15, reorder <= maxDecPicBufferingMinus1 else { return malformed }
        }

        // Block sizes (§7.4.3.2.1): CTB 16…64, transform blocks nested inside the coding blocks.
        let minCbLog2 = r.ue() + 3                      // log2_min_luma_coding_block_size_minus3
        let ctbLog2 = minCbLog2 + r.ue()                // log2_diff_max_min_luma_coding_block_size
        let minTbLog2 = r.ue() + 2                      // log2_min_luma_transform_block_size_minus2
        let maxTbLog2 = minTbLog2 + r.ue()              // log2_diff_max_min_luma_transform_block_size
        let depthInter = r.ue()                         // max_transform_hierarchy_depth_inter
        let depthIntra = r.ue()                         // max_transform_hierarchy_depth_intra
        guard (4...6).contains(ctbLog2), minTbLog2 < minCbLog2, maxTbLog2 <= min(ctbLog2, 5),
              depthInter <= ctbLog2 - minTbLog2, depthIntra <= ctbLog2 - minTbLog2 else { return malformed }

        if r.bit() == 1 {                               // scaling_list_enabled_flag
            w.scalingListEnabled = true
            if r.bit() == 1 {                           // sps_scaling_list_data_present_flag
                w.scalingListDataPresent = true
                guard skipScalingListData(&r) else { return malformed }
            }
        }
        _ = r.bit()                                     // amp_enabled_flag
        _ = r.bit()                                     // sample_adaptive_offset_enabled_flag
        if r.bit() == 1 {                               // pcm_enabled_flag
            w.pcmEnabled = true
            let pcmLuma = r.bits(4) + 1                 // pcm_sample_bit_depth_luma_minus1
            let pcmChroma = r.bits(4) + 1               // pcm_sample_bit_depth_chroma_minus1
            let minPcmLog2 = r.ue() + 3                 // log2_min_pcm_luma_coding_block_size_minus3
            let maxPcmLog2 = minPcmLog2 + r.ue()        // log2_diff_max_min_pcm_luma_coding_block_size
            _ = r.bit()                                 // pcm_loop_filter_disabled_flag
            guard pcmLuma <= w.bitDepthLumaMinus8 + 8, pcmChroma <= w.bitDepthChromaMinus8 + 8,
                  minPcmLog2 >= min(minCbLog2, 5), maxPcmLog2 <= min(ctbLog2, 5) else { return malformed }
        }

        // ── Short-term reference picture sets (§7.3.7) ──────────────────────────────────
        let numShortTermRefPicSets = r.ue()
        guard numShortTermRefPicSets <= 64 else { return malformed }
        if mutant != .skipShortTermRefPicSets {
            for idx in 0..<numShortTermRefPicSets {
                guard let count = readShortTermRefPicSet(&r, idx: idx, previous: w.numDeltaPocs.last,
                                                         maxDecPicBufferingMinus1: maxDecPicBufferingMinus1,
                                                         interPredicted: &w.numInterPredicted, mutant: mutant)
                else { return malformed }
                w.numDeltaPocs.append(count)
            }
        }

        if r.bit() == 1 {                               // long_term_ref_pics_present_flag
            let count = r.ue()                          // num_long_term_ref_pics_sps
            guard count <= 32 else { return malformed }
            w.numLongTermRefPicsSps = count
            for _ in 0..<count where !r.overrun {
                _ = r.bits(w.log2MaxPocLsbMinus4 + 4)   // lt_ref_pic_poc_lsb_sps, u(v)
                _ = r.bit()                             // used_by_curr_pic_lt_sps_flag
            }
        }
        _ = r.bit()                                     // sps_temporal_mvp_enabled_flag
        _ = r.bit()                                     // strong_intra_smoothing_enabled_flag

        // ── vui_parameters(), H.265 §E.2.1 — up to the colour description only ─────────────
        let vuiPresent = r.bit()
        guard !r.overrun else { return malformed }
        guard vuiPresent == 1 else { return SPSColor(reach: .noVUI) }

        if r.bit() == 1 {                               // aspect_ratio_info_present_flag
            let idc = r.bits(8)
            w.aspectRatioIdc = idc
            if idc == 255 {                             // Extended_SAR
                w.sarWidth = r.bits(16)
                w.sarHeight = r.bits(16)
            }
        }
        if r.bit() == 1 { _ = r.bit() }                 // overscan_info_present → overscan_appropriate
        return SPSColor.readVideoSignalType(&r)         // video_signal_type() to matrix_coefficients
    }

    // MARK: - profile_tier_level(1, sps_max_sub_layers_minus1), §7.3.3

    /// The general profile is 88 bits and the level 8; each sub-layer may repeat either. With any
    /// sub-layers at all, the flags are padded to eight entries with reserved_zero_2bits.
    private static func skipProfileTierLevel(_ r: inout BitReader, maxSubLayersMinus1: Int,
                                             shape: inout Shape) -> Bool {
        // The general profile's 88 bits, read as the format needs them and stepped over otherwise.
        _ = r.bits(2)                                   // general_profile_space
        _ = r.bit()                                     // general_tier_flag
        shape.generalProfileIdc = r.bits(5)             // general_profile_idc
        shape.generalProfileCompatibility = UInt32(truncatingIfNeeded: r.bits(32)) // ..._compatibility_flag[0…31]
        _ = r.bits(48)                                  // progressive_source_flag … general_inbld_flag
        _ = r.bits(8)                                   // general_level_idc
        var profilePresent: [Bool] = [], levelPresent: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 {
            profilePresent.append(r.bit() == 1)         // sub_layer_profile_present_flag[i]
            levelPresent.append(r.bit() == 1)           // sub_layer_level_present_flag[i]
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 { _ = r.bits(2) }   // reserved_zero_2bits
        }
        for i in 0..<maxSubLayersMinus1 {
            if profilePresent[i] { _ = r.bits(88) }     // sub_layer profile space … inbld
            if levelPresent[i] { _ = r.bits(8) }        // sub_layer_level_idc[i]
        }
        return !r.overrun
    }

    // MARK: - scaling_list_data(), §7.3.4

    /// Four sizes; six matrices each, except 32×32 where only matrixId 0 and 3 are coded. A matrix is
    /// either predicted (a reference delta) or coded (a DC term for 16×16 and 32×32, then up to 64
    /// deltas). Returns false when a value is outside the standard's range.
    private static func skipScalingListData(_ r: inout BitReader) -> Bool {
        for sizeId in 0..<4 {
            let step = sizeId == 3 ? 3 : 1
            for matrixId in stride(from: 0, to: 6, by: step) {
                if r.bit() == 0 {                       // scaling_list_pred_mode_flag
                    // scaling_list_pred_matrix_id_delta: 0…matrixId (in steps of 3 for 32×32)
                    guard r.ue() <= matrixId / step else { return false }
                } else {
                    let coefNum = min(64, 1 << (4 + (sizeId << 1)))
                    if sizeId > 1 {
                        guard (-7...247).contains(r.se()) else { return false }   // scaling_list_dc_coef_minus8
                    }
                    for _ in 0..<coefNum {
                        guard (-128...127).contains(r.se()), !r.overrun else { return false }   // scaling_list_delta_coef
                    }
                }
                guard !r.overrun else { return false }
            }
        }
        return true
    }

    // MARK: - st_ref_pic_set(stRpsIdx), §7.3.7, in the SPS (stRpsIdx < num_short_term_ref_pic_sets)

    /// Returns the set's NumDeltaPocs, or nil when the set is malformed. An inter-predicted set
    /// (always from the set before it, in the SPS) carries one used_by_curr_pic_flag per picture of
    /// that set plus one, and a use_delta_flag after each 0; its own size is the number of entries
    /// kept (use_delta_flag, inferred 1 when used_by_curr_pic_flag is 1). This count is the one
    /// thing a later set needs, so it is the one thing kept.
    private static func readShortTermRefPicSet(_ r: inout BitReader, idx: Int, previous: Int?,
                                               maxDecPicBufferingMinus1: Int, interPredicted: inout Int,
                                               mutant: Mutant?) -> Int? {
        let interRefPicSetPrediction = idx != 0 && r.bit() == 1
        if interRefPicSetPrediction && mutant != .interPredictionReadAsExplicit {
            guard let previous else { return nil }
            interPredicted += 1
            // delta_idx_minus1 is present only in a slice header's own set; in the SPS the
            // reference is always the set before.
            _ = r.bit()                                 // delta_rps_sign
            guard r.ue() <= 32767 else { return nil }   // abs_delta_rps_minus1: 0…2^15 − 1
            var kept = 0
            for _ in 0...previous {
                if r.bit() == 1 {                       // used_by_curr_pic_flag[j]
                    kept += 1
                } else if r.bit() == 1 {                // use_delta_flag[j]
                    kept += 1
                }
            }
            // A decoded picture buffer holds at most 16 pictures (§A.4.2).
            guard !r.overrun, kept <= 16 else { return nil }
            return kept
        }
        let negative = r.ue()                           // num_negative_pics
        guard negative <= maxDecPicBufferingMinus1 else { return nil }
        let positive = r.ue()                           // num_positive_pics
        guard positive <= maxDecPicBufferingMinus1 - negative else { return nil }
        for _ in 0..<(negative + positive) {
            guard r.ue() <= 32767 else { return nil }   // delta_poc_s0/s1_minus1: 0…2^15 − 1
            _ = r.bit()                                 // used_by_curr_pic_s0/s1_flag
        }
        return r.overrun ? nil : negative + positive
    }
}

// MARK: - The format an HEVC SPS declares

/// Profile, chroma format and bit depths of one HEVC SPS: what the SRT gate decides on (§6.10, Stage 3;
/// decision 7). The colour is `SPSColor`'s; this is only the shape of the samples.
public struct HEVCSPSFormat: Equatable, Sendable {
    public let generalProfileIdc: Int
    /// `general_profile_compatibility_flag[j]` at bit `31 - j`, as it is coded.
    public let generalProfileCompatibility: UInt32
    public let chromaFormatIdc: Int
    public let bitDepthLuma: Int
    public let bitDepthChroma: Int

    public init(generalProfileIdc: Int, generalProfileCompatibility: UInt32, chromaFormatIdc: Int,
                bitDepthLuma: Int, bitDepthChroma: Int) {
        self.generalProfileIdc = generalProfileIdc
        self.generalProfileCompatibility = generalProfileCompatibility
        self.chromaFormatIdc = chromaFormatIdc
        self.bitDepthLuma = bitDepthLuma
        self.bitDepthChroma = bitDepthChroma
    }

    /// The profile names a Main or Main 10 decoder (A.3.2, A.3.3): `general_profile_idc` 1 or 2, or the
    /// compatibility flag for either (a Main Still Picture stream sets Main's).
    public var isMainOrMain10: Bool {
        func compatible(_ j: Int) -> Bool { generalProfileCompatibility & (UInt32(1) << UInt32(31 - j)) != 0 }
        return generalProfileIdc == 1 || generalProfileIdc == 2 || compatible(1) || compatible(2)
    }

    /// HEVC Main or Main 10 at 4:2:0 and at most 10 bits: what Manifold plays over SRT today. 4:2:2 is
    /// Stage 3b; 4:4:4 stays refused.
    public var isSupported420: Bool {
        isMainOrMain10 && chromaFormatIdc == 1 && bitDepthLuma <= 10 && bitDepthChroma <= 10
    }

    /// "4:2:0", "4:2:2", "4:4:4", or "4:0:0" (monochrome).
    public var chromaName: String {
        switch chromaFormatIdc {
        case 0:  return "4:0:0"
        case 1:  return "4:2:0"
        case 2:  return "4:2:2"
        default: return "4:4:4"
        }
    }

    /// The general profile by name (H.265 Annex A), for the log and the banner.
    public var profileName: String {
        switch generalProfileIdc {
        case 1:  return "Main"
        case 2:  return "Main 10"
        case 3:  return "Main Still Picture"
        case 4:  return "Format Range Extensions"
        case 5:  return "High Throughput"
        case 9:  return "Screen Content Coding"
        default: return "profile \(generalProfileIdc)"
        }
    }
}
