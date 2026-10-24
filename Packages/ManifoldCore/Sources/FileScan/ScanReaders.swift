//
//  ScanReaders.swift
//  FileScan
//
//  The readers behind `SourceScan`, one per source (docs/INTERLACED_FINDINGS.md §10.2). Each returns what its
//  source STATES, axis by axis, and nil when it cannot read the source at all. None of them guesses: a field
//  the source does not carry is an unstated axis, not a default.
//

import SPSColor

// MARK: - Container

public enum ContainerScan {

    /// The QuickTime `fiel` atom as CoreMedia exposes it: `FieldCount` and `FieldDetail` (the
    /// `kCMFormatDescriptionFieldDetail_*` names). nil when the format description carries neither (no `fiel`).
    ///
    /// FieldCount 1 is progressive. For 2, the detail gives the order: `SpatialFirstLineEarly` (`fiel` 9) and
    /// `TemporalTopFirst` (1) are top field first, `SpatialFirstLineLate` (14) and `TemporalBottomFirst` (6)
    /// bottom field first. ⚠️ FFmpeg labels 9 "top coded first (swapped)" (§6); the picture is TFF.
    public static func fiel(fieldCount: Int?, fieldDetail: String?) -> ScanReading? {
        guard fieldCount != nil || fieldDetail != nil else { return nil }
        let detail = "FieldCount \(fieldCount.map(String.init) ?? "—"), FieldDetail \(fieldDetail ?? "—")"
        switch fieldCount {
        case 1?:
            return ScanReading(interlaced: false, fieldOrder: nil, scanSource: "fiel", detail: detail)
        case 2?:
            let order: FieldOrder?
            switch fieldDetail {
            case "SpatialFirstLineEarly"?, "TemporalTopFirst"?: order = .topFirst
            case "SpatialFirstLineLate"?, "TemporalBottomFirst"?: order = .bottomFirst
            default: order = nil
            }
            return ScanReading(interlaced: true, fieldOrder: order, scanSource: "fiel", detail: detail)
        default:
            return ScanReading(interlaced: nil, fieldOrder: nil, scanSource: "fiel", detail: detail)
        }
    }

    /// The first picture descriptor in an MXF header partition (the bytes `MXFDeclaredRange` reads): its
    /// FrameLayout and FieldDominance. nil when there is no picture descriptor.
    ///
    /// FrameLayout (SMPTE 377-1): 0 full frame → progressive; 1 separate fields and 3 mixed fields →
    /// interlaced; 4 segmented frame (PsF) → progressive; 2 one field → says nothing. FieldDominance 1 means
    /// field 1 is first in time, 2 field 2; absent, the standard's default is 1, and the log says it was absent.
    /// Field 1 is the top field in 1080i (VideoLineMap 21 / 584). 525-line SD, where it is not, is out of scope
    /// (§7 decision 8).
    public static func mxf(header d: [UInt8]) -> ScanReading? {
        let metadataSetPrefix: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01]
        var o = 0
        while o + 17 < d.count {
            guard let (len, valueOffset) = ber(d, o + 16), valueOffset + len <= d.count else { return nil }
            // 0x28 CDCIDescriptor, 0x29 RGBADescriptor, 0x51 MPEG2VideoDescriptor (a CDCI subclass).
            if Array(d[o..<(o + 8)]) == metadataSetPrefix, [0x28, 0x29, 0x51].contains(d[o + 14]) {
                var tags: [UInt16: ArraySlice<UInt8>] = [:]
                var q = valueOffset
                let end = valueOffset + len
                while q + 4 <= end {
                    let tag = (UInt16(d[q]) << 8) | UInt16(d[q + 1])
                    let tl = (Int(d[q + 2]) << 8) | Int(d[q + 3])
                    q += 4
                    guard q + tl <= end else { break }
                    tags[tag] = d[q..<(q + tl)]
                    q += tl
                }
                return reading(layout: tags[0x320C]?.first, dominance: tags[0x3212]?.first,
                               lineMap: tags[0x320D].map(lineMap) ?? [])
            }
            o = valueOffset + len
        }
        return nil
    }

    static func reading(layout: UInt8?, dominance: UInt8?, lineMap: [Int]) -> ScanReading {
        let names: [UInt8: String] = [0: "full frame", 1: "separate fields", 2: "one field", 3: "mixed fields",
                                      4: "segmented frame"]
        var detail = "FrameLayout " + (layout.map { "\($0) (\(names[$0] ?? "reserved"))" } ?? "absent")
        detail += ", FieldDominance " + (dominance.map(String.init) ?? "absent (default 1)")
        if !lineMap.isEmpty { detail += ", VideoLineMap " + lineMap.map(String.init).joined(separator: "/") }
        let interlaced: Bool?
        switch layout {
        case 0?, 4?: interlaced = false
        case 1?, 3?: interlaced = true
        default: interlaced = nil
        }
        var order: FieldOrder? = nil
        if interlaced == true {
            switch dominance ?? 1 {
            case 1: order = .topFirst
            case 2: order = .bottomFirst
            default: order = nil
            }
        }
        return ScanReading(interlaced: interlaced, fieldOrder: order, scanSource: "MXF FrameLayout",
                           orderSource: "MXF FieldDominance", detail: detail)
    }

    /// VideoLineMap is a batch: element count (4 bytes), element size (4), then that many Int32.
    private static func lineMap(_ v: ArraySlice<UInt8>) -> [Int] {
        let b = Array(v)
        guard b.count >= 8 else { return [] }
        let count = be(b[0..<4]), size = be(b[4..<8])
        guard size == 4, count <= 4, b.count >= 8 + count * 4 else { return [] }
        return (0..<count).map { Int(Int32(truncatingIfNeeded: be(b[(8 + $0 * 4)..<(12 + $0 * 4)]))) }
    }

    private static func ber(_ d: [UInt8], _ offset: Int) -> (Int, Int)? {
        guard offset < d.count else { return nil }
        let first = d[offset]
        if first < 0x80 { return (Int(first), offset + 1) }
        let n = Int(first & 0x7F)
        guard n > 0, n <= 8, offset + 1 + n <= d.count else { return nil }
        var v = 0
        for i in 0..<n { v = (v << 8) | Int(d[offset + 1 + i]) }
        guard v >= 0 else { return nil }
        return (v, offset + 1 + n)
    }

    private static func be(_ d: ArraySlice<UInt8>) -> Int { d.reduce(0) { ($0 << 8) | Int($1) } }
}

// MARK: - Bitstream

public enum BitstreamScan {

    public enum Codec: Equatable, Sendable { case prores, dnx, h264, hevc }

    /// The first video packet (and, for H.264 / HEVC, the `avcC` / `hvcC` the container carries). A packet is
    /// length-prefixed when the configuration record says so, Annex B (start codes) otherwise. nil when this
    /// codec's header cannot be read from these bytes.
    public static func read(codec: Codec, configuration: [UInt8], packet: [UInt8]) -> ScanReading? {
        switch codec {
        case .prores: return prores(packet)
        case .dnx: return dnx(packet)
        case .h264: return h264(configuration: configuration, packet: packet)
        case .hevc: return hevc(configuration: configuration, packet: packet)
        }
    }

    // MARK: ProRes

    /// The frame: frame size (4), `icpf` (4), then the frame header: header size (2), version (2), creator (4),
    /// width (2), height (2), and a byte whose bits 3–2 are `interlace_mode` (0 progressive, 1 TFF, 2 BFF).
    static func prores(_ p: [UInt8]) -> ScanReading? {
        guard p.count >= 21, Array(p[4..<8]) == Array("icpf".utf8) else { return nil }
        let mode = Int(p[20] >> 2) & 3
        let detail = "interlace_mode \(mode)"
        switch mode {
        case 0: return ScanReading(interlaced: false, fieldOrder: nil, scanSource: "ProRes frame header", detail: detail)
        case 1: return ScanReading(interlaced: true, fieldOrder: .topFirst, scanSource: "ProRes frame header", detail: detail)
        case 2: return ScanReading(interlaced: true, fieldOrder: .bottomFirst, scanSource: "ProRes frame header", detail: detail)
        default: return ScanReading(interlaced: nil, fieldOrder: nil, scanSource: "ProRes frame header", detail: detail)
        }
    }

    // MARK: DNx

    /// The header prefix `00 00 02 80 0x` (x 1–3), then byte 5: bit 1 set = interlaced, and then bit 0 is the
    /// field coded first (0 top). An interlaced DNxHD packet holds the two fields one after the other, each with
    /// its own header; the first one's says which leads. DNxHR has no interlaced profile, so it reads progressive.
    static func dnx(_ p: [UInt8]) -> ScanReading? {
        guard p.count >= 6, p[0] == 0, p[1] == 0, p[2] == 0x02, p[3] == 0x80, (1...3).contains(p[4]) else { return nil }
        let b = p[5]
        let detail = "header byte 5 = " + (b < 0x10 ? "0" : "") + String(b, radix: 16)
        guard b & 0x02 != 0 else {
            return ScanReading(interlaced: false, fieldOrder: nil, scanSource: "DNx frame header", detail: detail)
        }
        return ScanReading(interlaced: true, fieldOrder: b & 0x01 == 0 ? .topFirst : .bottomFirst,
                           scanSource: "DNx frame header", detail: detail)
    }

    // MARK: H.264

    static func h264(configuration: [UInt8], packet: [UInt8]) -> ScanReading? {
        var nals: [ArraySlice<UInt8>] = []
        var lengthSize: Int? = nil
        if configuration.count >= 7, configuration[0] == 1 {
            lengthSize = Int(configuration[4] & 3) + 1
            nals += avcCNALs(configuration)
        }
        nals += split(packet, lengthSize: lengthSize)
        func of(_ type: UInt8) -> [ArraySlice<UInt8>] { nals.filter { ($0.first ?? 0x80) & 0x1F == type && $0.first! & 0x80 == 0 } }

        guard let sps = of(7).lazy.compactMap({ H264Scan.sps(nal: $0) }).first else { return nil }
        if sps.frameMbsOnly {
            return ScanReading(interlaced: false, fieldOrder: nil, scanSource: "H.264 SPS",
                               detail: "frame_mbs_only_flag 1")
        }
        let base = "frame_mbs_only_flag 0, mb_adaptive_frame_field_flag \(sps.mbAdaptiveFrameField ? 1 : 0)"
        let ppss = of(8).compactMap { H264Scan.pps(nal: $0) }
        let slice = nals.first { [1, 5].contains($0.first! & 0x1F) }.flatMap { nal -> H264ScanSlice? in
            guard let id = H264Scan.slicePPSID(nal: nal), let pps = ppss.first(where: { $0.ppsID == id }) else { return nil }
            return H264Scan.slice(nal: nal, sps: sps, pps: pps)
        }
        if let slice, slice.fieldPic {
            return ScanReading(interlaced: true, fieldOrder: slice.bottomField ? .bottomFirst : .topFirst,
                               scanSource: "H.264 field slice",
                               detail: base + ", field_pic_flag 1, bottom_field_flag \(slice.bottomField ? 1 : 0)")
        }
        if let ps = of(6).lazy.compactMap({ H264Scan.picStruct(sei: $0, sps: sps) }).first {
            let detail = base + ", pic_struct \(ps)"
            switch ps {
            case 3, 5: return ScanReading(interlaced: true, fieldOrder: .topFirst, scanSource: "H.264 pic_struct SEI", detail: detail)
            case 4, 6: return ScanReading(interlaced: true, fieldOrder: .bottomFirst, scanSource: "H.264 pic_struct SEI", detail: detail)
            case 0, 7, 8: return ScanReading(interlaced: false, fieldOrder: nil, scanSource: "H.264 pic_struct SEI", detail: detail)
            default: break   // 1, 2: a field's pic_struct on a frame slice; contradicts the slice, so unused
            }
        }
        guard let slice else {
            return ScanReading(interlaced: nil, fieldOrder: nil, scanSource: "H.264 SPS", detail: base + ", no slice read")
        }
        let delta = slice.deltaPicOrderCntBottom
        let order: FieldOrder? = delta.flatMap { $0 > 0 ? .topFirst : $0 < 0 ? .bottomFirst : nil }
        let detail = base + ", frame slice, delta_pic_order_cnt_bottom \(delta.map(String.init) ?? "not coded")"
        guard sps.mbAdaptiveFrameField else {
            // A frame of frame macroblocks in a stream that may code fields: nothing here says it is interlaced.
            return ScanReading(interlaced: nil, fieldOrder: nil, scanSource: "H.264 slice", detail: detail)
        }
        return ScanReading(interlaced: true, fieldOrder: order, scanSource: "H.264 MBAFF slice",
                           orderSource: "H.264 slice POC", detail: detail)
    }

    /// The SPS and PPS NAL units in an `avcC` (ISO/IEC 14496-15 §5.3.3.1).
    static func avcCNALs(_ c: [UInt8]) -> [ArraySlice<UInt8>] {
        var out: [ArraySlice<UInt8>] = []
        var at = 5
        for group in 0..<2 {
            guard at < c.count else { break }
            let count = group == 0 ? Int(c[at] & 0x1F) : Int(c[at])
            at += 1
            for _ in 0..<count {
                guard at + 2 <= c.count else { return out }
                let n = Int(c[at]) << 8 | Int(c[at + 1])
                at += 2
                guard at + n <= c.count else { return out }
                out.append(c[at..<(at + n)])
                at += n
            }
        }
        return out
    }

    // MARK: HEVC

    static func hevc(configuration: [UInt8], packet: [UInt8]) -> ScanReading? {
        var nals: [ArraySlice<UInt8>] = []
        var lengthSize: Int? = nil
        if configuration.count >= 23, configuration[0] == 1 {
            lengthSize = Int(configuration[21] & 3) + 1
            nals += hvcCNALs(configuration)
        }
        nals += split(packet, lengthSize: lengthSize)
        func of(_ type: UInt8) -> [ArraySlice<UInt8>] { nals.filter { $0.count >= 2 && ($0.first! >> 1) & 0x3F == type } }

        guard let sps = of(33).lazy.compactMap({ HEVCSPSColor.scan(nal: $0) }).first else { return nil }
        let base = "general_progressive_source_flag \(sps.progressiveSource ? 1 : 0), "
                 + "general_interlaced_source_flag \(sps.interlacedSource ? 1 : 0), "
                 + "field_seq_flag \(sps.fieldSequence ? 1 : 0)"
        let timing = of(39).lazy.compactMap { HEVCScan.picStruct(sei: $0, sps: sps) }.first
        let detail = base + (timing.map { ", pic_struct \($0.picStruct), source_scan_type \($0.sourceScanType)" } ?? "")

        if sps.fieldSequence {
            // Each picture is a field; the first one's pic_struct says which field leads (Table D.2:
            // 1 top, 2 bottom; 9 / 10 paired with the previous field, 11 / 12 with the next).
            let order: FieldOrder?
            switch timing?.picStruct {
            case 1?, 10?, 11?: order = .topFirst
            case 2?, 9?, 12?: order = .bottomFirst
            default: order = nil
            }
            return ScanReading(interlaced: true, fieldOrder: order, scanSource: "HEVC field_seq_flag",
                               orderSource: "HEVC pic_struct SEI", detail: detail)
        }
        switch timing?.picStruct {
        case 3?, 5?: return ScanReading(interlaced: true, fieldOrder: .topFirst, scanSource: "HEVC pic_struct SEI", detail: detail)
        case 4?, 6?: return ScanReading(interlaced: true, fieldOrder: .bottomFirst, scanSource: "HEVC pic_struct SEI", detail: detail)
        default: break
        }
        // The profile's source flags (§7.4.4): 1 / 0 progressive, 0 / 1 interlaced, 1 / 1 the SEI's source_scan_type
        // says, 0 / 0 unknown.
        switch (sps.progressiveSource, sps.interlacedSource) {
        case (true, false):
            return ScanReading(interlaced: false, fieldOrder: nil, scanSource: "HEVC SPS", detail: detail)
        case (false, true):
            return ScanReading(interlaced: true, fieldOrder: nil, scanSource: "HEVC SPS", detail: detail)
        case (true, true) where timing?.sourceScanType == 0 || timing?.sourceScanType == 1:
            return ScanReading(interlaced: timing?.sourceScanType == 0, fieldOrder: nil,
                               scanSource: "HEVC source_scan_type SEI", detail: detail)
        default:
            return ScanReading(interlaced: nil, fieldOrder: nil, scanSource: "HEVC SPS", detail: detail)
        }
    }

    /// Every NAL unit in an `hvcC`'s arrays (ISO/IEC 14496-15 §8.3.3.1).
    static func hvcCNALs(_ c: [UInt8]) -> [ArraySlice<UInt8>] {
        var out: [ArraySlice<UInt8>] = []
        guard c.count >= 23 else { return out }
        var at = 23
        for _ in 0..<Int(c[22]) {
            guard at + 3 <= c.count else { return out }
            let count = Int(c[at + 1]) << 8 | Int(c[at + 2])
            at += 3
            for _ in 0..<count {
                guard at + 2 <= c.count else { return out }
                let n = Int(c[at]) << 8 | Int(c[at + 1])
                at += 2
                guard at + n <= c.count else { return out }
                out.append(c[at..<(at + n)])
                at += n
            }
        }
        return out
    }

    // MARK: NAL framing

    /// Length-prefixed NAL units when `lengthSize` is given and the packet does not open with a start code;
    /// Annex B otherwise.
    static func split(_ p: [UInt8], lengthSize: Int?) -> [ArraySlice<UInt8>] {
        let annexB = p.count >= 4 && p[0] == 0 && p[1] == 0 && (p[2] == 1 || (p[2] == 0 && p[3] == 1))
        if let n = lengthSize, !annexB {
            var out: [ArraySlice<UInt8>] = []
            var at = 0
            while at + n <= p.count {
                let len = p[at..<(at + n)].reduce(0) { ($0 << 8) | Int($1) }
                at += n
                guard len > 0, at + len <= p.count else { break }
                out.append(p[at..<(at + len)])
                at += len
            }
            return out
        }
        var starts: [Int] = []
        var i = 0
        while i + 3 <= p.count {
            if p[i] == 0, p[i + 1] == 0, p[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        return starts.enumerated().map { k, s in
            var e = k + 1 < starts.count ? starts[k + 1] - 3 : p.count
            while e > s, p[e - 1] == 0 { e -= 1 }       // trailing zero of a 4-byte start code
            return p[s..<e]
        }.filter { !$0.isEmpty }
    }
}
