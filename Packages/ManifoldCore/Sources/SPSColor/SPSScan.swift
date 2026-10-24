//
//  SPSScan.swift
//  SPSColor
//
//  What an H.264 or HEVC bitstream says about scan: progressive or interlaced, and which field comes first
//  (docs/INTERLACED_FINDINGS.md §10, stage I1). The raw fields only, per NAL unit; deciding what they add up
//  to is `FileScan`'s job. Here because the bit reader and the SPS walks are here, and the scan fields sit
//  in the same SPS the colour walk already steps through.
//
//  Every reader takes ONE NAL unit with its header and no start code or length prefix, never throws, and
//  returns nil when the bits run out or a field is outside the standard's range.
//

// MARK: - H.264

/// The SPS fields a slice header and a picture timing SEI need, plus the two that say scan outright.
public struct H264ScanSPS: Equatable, Sendable {
    public let spsID: Int
    public let separateColourPlane: Bool
    public let log2MaxFrameNum: Int
    public let picOrderCntType: Int
    public let log2MaxPocLsb: Int
    /// 1: every picture is a frame of frame macroblocks, so the stream is progressive by construction.
    public let frameMbsOnly: Bool
    /// MBAFF: frame pictures may switch macroblock pairs to field coding.
    public let mbAdaptiveFrameField: Bool
    /// The VUI's `pic_struct_present_flag`: picture timing SEIs carry `pic_struct`.
    public let picStructPresent: Bool
    /// `CpbDpbDelaysPresentFlag` and the two delay lengths in front of `pic_struct` in the SEI.
    public let cpbDpbDelaysPresent: Bool
    public let cpbRemovalDelayLength: Int
    public let dpbOutputDelayLength: Int
}

public struct H264ScanPPS: Equatable, Sendable {
    public let ppsID: Int
    public let spsID: Int
    /// A frame slice then codes `delta_pic_order_cnt_bottom`, whose sign gives the field order.
    public let bottomFieldPicOrderInFramePresent: Bool
}

public struct H264ScanSlice: Equatable, Sendable {
    public let fieldPic: Bool
    public let bottomField: Bool
    /// `delta_pic_order_cnt_bottom`, coded only for a frame slice with picture order count type 0 when the PPS
    /// says so. Bottom field POC minus top field POC: positive, the top field is shown first.
    public let deltaPicOrderCntBottom: Int?
}

public enum H264Scan {

    /// The SPS, walked by the colour reader's own walk and continued through the VUI to `pic_struct_present_flag`.
    public static func sps<Bytes: Collection>(nal: Bytes) -> H264ScanSPS? where Bytes.Element == UInt8 {
        guard nal.count >= 5, let header = nal.first, header & 0x80 == 0, header & 0x1F == 7,
              nal.count <= SPSColor.maximumSPSBytes else { return nil }
        var r = BitReader(rbsp: SPSColor.unescape(nal.dropFirst()))
        var shape = H264SPSColor.Shape()
        var picStruct = false, delays = false, cpbLength = 0, dpbLength = 0
        switch H264SPSColor.readSPS(&r, &shape).reach {
        case .noVUI:
            break
        case .noVideoSignalType, .noColourDescription, .colourDescription:
            // vui_parameters(), §E.1.1, after video_signal_type().
            if r.bit() == 1 {                           // chroma_loc_info_present_flag
                guard r.ue() <= 5, r.ue() <= 5 else { return nil }
            }
            if r.bit() == 1 {                           // timing_info_present_flag
                _ = r.bits(32); _ = r.bits(32); _ = r.bit()  // num_units_in_tick, time_scale, fixed_frame_rate_flag
            }
            let nalHRD = r.bit() == 1                   // nal_hrd_parameters_present_flag
            if nalHRD {
                guard let lengths = hrd(&r) else { return nil }
                (cpbLength, dpbLength) = lengths
            }
            let vclHRD = r.bit() == 1                   // vcl_hrd_parameters_present_flag
            if vclHRD {
                guard let lengths = hrd(&r) else { return nil }
                if !nalHRD { (cpbLength, dpbLength) = lengths }   // the two are equal when both are coded
            }
            delays = nalHRD || vclHRD
            if delays { _ = r.bit() }                   // low_delay_hrd_flag
            picStruct = r.bit() == 1                    // pic_struct_present_flag
            guard !r.overrun else { return nil }
        default:
            return nil
        }
        return H264ScanSPS(spsID: shape.spsID, separateColourPlane: shape.separateColourPlane,
                           log2MaxFrameNum: shape.log2MaxFrameNum, picOrderCntType: shape.picOrderCntType,
                           log2MaxPocLsb: shape.log2MaxPocLsb, frameMbsOnly: shape.frameMbsOnly,
                           mbAdaptiveFrameField: shape.mbAdaptiveFrameField, picStructPresent: picStruct,
                           cpbDpbDelaysPresent: delays, cpbRemovalDelayLength: cpbLength,
                           dpbOutputDelayLength: dpbLength)
    }

    /// hrd_parameters(), §E.1.2: returns (cpb_removal_delay_length, dpb_output_delay_length).
    private static func hrd(_ r: inout BitReader) -> (Int, Int)? {
        let cpbCount = r.ue() + 1                       // cpb_cnt_minus1
        guard cpbCount <= 32 else { return nil }
        _ = r.bits(8)                                   // bit_rate_scale, cpb_size_scale
        for _ in 0..<cpbCount where !r.overrun {
            _ = r.ue(); _ = r.ue(); _ = r.bit()         // bit_rate_value_minus1, cpb_size_value_minus1, cbr_flag
        }
        _ = r.bits(5)                                   // initial_cpb_removal_delay_length_minus1
        let cpb = r.bits(5) + 1                         // cpb_removal_delay_length_minus1
        let dpb = r.bits(5) + 1                         // dpb_output_delay_length_minus1
        _ = r.bits(5)                                   // time_offset_length
        return r.overrun ? nil : (cpb, dpb)
    }

    /// pic_parameter_set_rbsp(), §7.3.2.2, up to `bottom_field_pic_order_in_frame_present_flag`.
    public static func pps<Bytes: Collection>(nal: Bytes) -> H264ScanPPS? where Bytes.Element == UInt8 {
        guard nal.count >= 2, let header = nal.first, header & 0x80 == 0, header & 0x1F == 8 else { return nil }
        var r = BitReader(rbsp: SPSColor.unescape(nal.dropFirst().prefix(64)))
        let ppsID = r.ue(), spsID = r.ue()
        _ = r.bit()                                     // entropy_coding_mode_flag
        let bottom = r.bit() == 1                       // bottom_field_pic_order_in_frame_present_flag
        guard !r.overrun, ppsID <= 255, spsID <= 31 else { return nil }
        return H264ScanPPS(ppsID: ppsID, spsID: spsID, bottomFieldPicOrderInFramePresent: bottom)
    }

    /// The PPS id a slice refers to, so the caller can find the right PPS before reading the rest.
    public static func slicePPSID<Bytes: Collection>(nal: Bytes) -> Int? where Bytes.Element == UInt8 {
        guard nal.count >= 2, let header = nal.first, header & 0x80 == 0, [1, 5].contains(header & 0x1F)
        else { return nil }
        var r = BitReader(rbsp: SPSColor.unescape(nal.dropFirst().prefix(16)))
        _ = r.ue(); _ = r.ue()                          // first_mb_in_slice, slice_type
        let id = r.ue()
        return r.overrun || id > 255 ? nil : id
    }

    /// slice_header(), §7.3.3, up to `delta_pic_order_cnt_bottom`. A coded slice (NAL type 1 or 5) only.
    public static func slice<Bytes: Collection>(nal: Bytes, sps: H264ScanSPS, pps: H264ScanPPS) -> H264ScanSlice?
    where Bytes.Element == UInt8 {
        guard nal.count >= 2, let header = nal.first, header & 0x80 == 0 else { return nil }
        let type = header & 0x1F
        guard type == 1 || type == 5 else { return nil }
        // The header is a few dozen bits; 64 bytes is far more than it can need.
        var r = BitReader(rbsp: SPSColor.unescape(nal.dropFirst().prefix(64)))
        _ = r.ue()                                      // first_mb_in_slice
        guard r.ue() <= 9, r.ue() == pps.ppsID else { return nil }   // slice_type, pic_parameter_set_id
        if sps.separateColourPlane { _ = r.bits(2) }    // colour_plane_id
        _ = r.bits(sps.log2MaxFrameNum)                 // frame_num
        var field = false, bottom = false
        if !sps.frameMbsOnly {
            field = r.bit() == 1                        // field_pic_flag
            if field { bottom = r.bit() == 1 }          // bottom_field_flag
        }
        if type == 5 { _ = r.ue() }                     // idr_pic_id
        var delta: Int? = nil
        if sps.picOrderCntType == 0 {
            _ = r.bits(sps.log2MaxPocLsb)               // pic_order_cnt_lsb
            if pps.bottomFieldPicOrderInFramePresent && !field { delta = r.se() }   // delta_pic_order_cnt_bottom
        }
        guard !r.overrun else { return nil }
        return H264ScanSlice(fieldPic: field, bottomField: bottom, deltaPicOrderCntBottom: delta)
    }

    /// `pic_struct` from the picture timing SEI (payload type 1) in one SEI NAL (type 6), §D.1.3. nil when the
    /// NAL carries no picture timing message or the SPS says it has no `pic_struct`.
    public static func picStruct<Bytes: Collection>(sei nal: Bytes, sps: H264ScanSPS) -> Int?
    where Bytes.Element == UInt8 {
        guard sps.picStructPresent, nal.count >= 2, let header = nal.first, header & 0x80 == 0, header & 0x1F == 6
        else { return nil }
        guard let payload = SEIWalk.payload(type: 1, rbsp: SPSColor.unescape(nal.dropFirst())) else { return nil }
        var r = BitReader(rbsp: payload)
        if sps.cpbDpbDelaysPresent {
            _ = r.bits(sps.cpbRemovalDelayLength)       // cpb_removal_delay
            _ = r.bits(sps.dpbOutputDelayLength)        // dpb_output_delay
        }
        let value = r.bits(4)                           // pic_struct
        return r.overrun || value > 8 ? nil : value
    }
}

// MARK: - HEVC

public struct HEVCScanSPS: Equatable, Sendable {
    public let progressiveSource: Bool
    public let interlacedSource: Bool
    /// Each coded picture is a field.
    public let fieldSequence: Bool
    /// Picture timing SEIs carry `pic_struct`, `source_scan_type` and `duplicate_flag`.
    public let frameFieldInfoPresent: Bool
}

public enum HEVCScan {

    /// `pic_struct` and `source_scan_type` from the picture timing SEI (payload type 1) in one prefix SEI NAL
    /// (type 39), §D.2.3. nil without one, or when the SPS says the SEI carries no frame-field information.
    public static func picStruct<Bytes: Collection>(sei nal: Bytes, sps: HEVCScanSPS)
    -> (picStruct: Int, sourceScanType: Int)? where Bytes.Element == UInt8 {
        guard sps.frameFieldInfoPresent, nal.count >= 3 else { return nil }
        let b0 = nal[nal.startIndex]
        guard b0 & 0x80 == 0, (b0 >> 1) & 0x3F == 39 else { return nil }
        guard let payload = SEIWalk.payload(type: 1, rbsp: SPSColor.unescape(nal.dropFirst(2))) else { return nil }
        var r = BitReader(rbsp: payload)
        let picStruct = r.bits(4)                       // pic_struct
        let scanType = r.bits(2)                        // source_scan_type
        return r.overrun || picStruct > 12 ? nil : (picStruct, scanType)
    }
}

// MARK: - SEI messages

/// sei_rbsp(): a run of messages, each a payload type and size coded as runs of 0xFF plus a last byte, then the
/// payload. The same in H.264 (§7.3.2.3.1) and HEVC (§7.3.5).
enum SEIWalk {
    static func payload(type wanted: Int, rbsp: [UInt8]) -> [UInt8]? {
        var at = 0
        while at < rbsp.count, rbsp[at] != 0x80 {       // 0x80 alone is rbsp_trailing_bits
            var type = 0, size = 0
            while at < rbsp.count, rbsp[at] == 0xFF { type += 255; at += 1 }
            guard at < rbsp.count else { return nil }
            type += Int(rbsp[at]); at += 1
            while at < rbsp.count, rbsp[at] == 0xFF { size += 255; at += 1 }
            guard at < rbsp.count else { return nil }
            size += Int(rbsp[at]); at += 1
            guard at + size <= rbsp.count else { return nil }
            if type == wanted { return Array(rbsp[at..<(at + size)]) }
            at += size
        }
        return nil
    }
}
