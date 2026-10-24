import XCTest
@testable import FileScan
import SPSColor

/// docs/INTERLACED_FINDINGS.md §10 (I1). Real bytes come from build/interlaced-fixtures (scripts/interlaced/
/// generate.sh, FFmpeg 8.1.1) and S0's progressive fixtures; every value was checked against FFmpeg's
/// `trace_headers` and `showinfo`. PAFF has no free encoder (§6), so its slices are written bit by bit.
final class FileScanTests: XCTestCase {

    // MARK: - ProRes and DNx headers

    func testProResInterlaceModeFromRealHeaders() {
        let tff = hex("00067faf69637066009400004c6176630780043884000202")
        let bff = hex("0006829969637066009400004c6176630780043888000202")
        let prog = hex("00055ace69637066009400004c6176630780043880000202")
        XCTAssertEqual(BitstreamScan.prores(tff), reading(true, .topFirst, "ProRes frame header", "interlace_mode 1"))
        XCTAssertEqual(BitstreamScan.prores(bff)?.fieldOrder, .bottomFirst)
        XCTAssertEqual(BitstreamScan.prores(prog)?.interlaced, false)
        XCTAssertNil(BitstreamScan.prores(Array("not a ProRes frame header".utf8)))
    }

    func testDNxHeaderByteFive() {
        XCTAssertEqual(BitstreamScan.dnx(hex("00000280010280a0")),
                       reading(true, .topFirst, "DNx frame header", "header byte 5 = 02"))
        XCTAssertEqual(BitstreamScan.dnx(hex("00000280010380a0"))?.fieldOrder, .bottomFirst)
        XCTAssertEqual(BitstreamScan.dnx(hex("00000280030000a0"))?.interlaced, false)   // DNxHR: no fields
        XCTAssertNil(BitstreamScan.dnx(hex("00000180010280a0")))
    }

    // MARK: - Container

    func testFielAsCoreMediaNamesIt() {
        XCTAssertEqual(ContainerScan.fiel(fieldCount: 2, fieldDetail: "SpatialFirstLineEarly")?.fieldOrder, .topFirst)
        XCTAssertEqual(ContainerScan.fiel(fieldCount: 2, fieldDetail: "TemporalTopFirst")?.fieldOrder, .topFirst)
        XCTAssertEqual(ContainerScan.fiel(fieldCount: 2, fieldDetail: "SpatialFirstLineLate")?.fieldOrder, .bottomFirst)
        XCTAssertEqual(ContainerScan.fiel(fieldCount: 2, fieldDetail: "TemporalBottomFirst")?.fieldOrder, .bottomFirst)
        XCTAssertEqual(ContainerScan.fiel(fieldCount: 1, fieldDetail: nil)?.interlaced, false)
        let noDetail = ContainerScan.fiel(fieldCount: 2, fieldDetail: nil)
        XCTAssertEqual(noDetail?.interlaced, true)
        XCTAssertNil(noDetail?.fieldOrder)
        XCTAssertNil(ContainerScan.fiel(fieldCount: nil, fieldDetail: nil))   // no fiel: the container says nothing
    }

    func testMXFDescriptor() {
        // FFmpeg's DNxHD 1080i MXF: FrameLayout 1, no FieldDominance, VideoLineMap 21 / 584.
        let ffmpeg = ContainerScan.mxf(header: mxfHeader([0x320C: [1], 0x320D: lineMap(21, 584)]))
        XCTAssertEqual(ffmpeg?.interlaced, true)
        XCTAssertEqual(ffmpeg?.fieldOrder, .topFirst)                 // the standard's default, 1
        XCTAssertEqual(ffmpeg?.detail,
                       "FrameLayout 1 (separate fields), FieldDominance absent (default 1), VideoLineMap 21/584")
        XCTAssertEqual(ContainerScan.mxf(header: mxfHeader([0x320C: [1], 0x3212: [2]]))?.fieldOrder, .bottomFirst)
        // A field-order dissent names the field that carries the order, not the one that carries the scan.
        let bff = BitstreamScan.dnx(hex("00000280010380a0"))
        XCTAssertEqual(SourceScan.resolve(container: ffmpeg, bitstream: bff).readout,
                       "Interlaced, bottom field first (DNx frame header) · ⚠️ MXF FieldDominance says top field first")
        XCTAssertEqual(ContainerScan.mxf(header: mxfHeader([0x320C: [3], 0x3212: [1]]))?.fieldOrder, .topFirst)
        XCTAssertEqual(ContainerScan.mxf(header: mxfHeader([0x320C: [0]]))?.interlaced, false)
        XCTAssertEqual(ContainerScan.mxf(header: mxfHeader([0x320C: [4]]))?.interlaced, false)   // PsF
        XCTAssertNil(ContainerScan.mxf(header: mxfHeader([0x320C: [2]]))?.interlaced)          // one field
        XCTAssertNil(ContainerScan.mxf(header: hex("060e2b34025301010d01010101012f00" + "00")))  // no descriptor
    }

    // MARK: - H.264

    // x264, `-flags +ildct+ilme -x264-params tff=1` / `bff=1`: MBAFF, picture timing SEI with pic_struct.
    let mbaffSPS = "67640028acd94078044fde022000007d20001d4c03e2c5b2c0"
    let mbaffPPS = "68fba3cb22c0"
    let tffSEI = "0601013280", bffSEI = "0601014280"
    let tffSlice = "6588820217cc4a8184f2e2c41e628bc6a8fd2232397c9dd6"
    let bffSlice = "6588820b17cc33f4cb27f1237164e7f870435956bf2dcf64"

    func testH264SPSScanFields() throws {
        let sps = try XCTUnwrap(H264Scan.sps(nal: hex(mbaffSPS)))
        XCTAssertFalse(sps.frameMbsOnly)
        XCTAssertTrue(sps.mbAdaptiveFrameField)
        XCTAssertTrue(sps.picStructPresent)
        XCTAssertFalse(sps.cpbDpbDelaysPresent)
        XCTAssertEqual(sps.picOrderCntType, 0)
        // The colour walk is unchanged by what it now records.
        XCTAssertEqual(H264SPSColor.parse(nal: hex(mbaffSPS)).reach, .noVideoSignalType)
    }

    func testH264MBAFFOrderFromPicStruct() {
        let tff = BitstreamScan.h264(configuration: [], packet: annexB([mbaffSPS, mbaffPPS, tffSEI, tffSlice]))
        XCTAssertEqual(tff, ScanReading(interlaced: true, fieldOrder: .topFirst, scanSource: "H.264 pic_struct SEI",
                                        detail: "frame_mbs_only_flag 0, mb_adaptive_frame_field_flag 1, pic_struct 3"))
        let bff = BitstreamScan.h264(configuration: [], packet: annexB([mbaffSPS, mbaffPPS, bffSEI, bffSlice]))
        XCTAssertEqual(bff?.fieldOrder, .bottomFirst)
    }

    func testH264MBAFFOrderFromSlicePOCWithoutSEI() {
        // trace_headers: delta_pic_order_cnt_bottom = 1 (tff) and −1 (bff) on these slices.
        let tff = BitstreamScan.h264(configuration: [], packet: annexB([mbaffSPS, mbaffPPS, tffSlice]))
        XCTAssertEqual(tff?.scanSource, "H.264 MBAFF slice")
        XCTAssertEqual(tff?.orderSource, "H.264 slice POC")
        XCTAssertEqual(tff?.fieldOrder, .topFirst)
        let bff = BitstreamScan.h264(configuration: [], packet: annexB([mbaffSPS, mbaffPPS, bffSlice]))
        XCTAssertEqual(bff?.fieldOrder, .bottomFirst)
        XCTAssertTrue(bff?.detail.hasSuffix("delta_pic_order_cnt_bottom -1") ?? false)
    }

    func testH264ProgressiveFromSPS() {
        // S0's patches-9-14-9-h264.mov: frame_mbs_only_flag 1.
        let p = BitstreamScan.h264(configuration: [],
                                   packet: annexB(["67640028acd940780227e59a848704a0000003002000000641e30632c0"]))
        XCTAssertEqual(p, ScanReading(interlaced: false, fieldOrder: nil, scanSource: "H.264 SPS",
                                      detail: "frame_mbs_only_flag 1"))
    }

    func testH264FromAvcCAndLengthPrefixedSample() {
        let sps = hex(mbaffSPS), pps = hex(mbaffPPS)
        var avcC: [UInt8] = [1, sps[1], sps[2], sps[3], 0xFF, 0xE1, UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)]
        avcC += sps + [1, UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)] + pps
        let sample = [tffSEI, tffSlice].flatMap { nal -> [UInt8] in
            let b = hex(nal); return [0, 0, UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b
        }
        XCTAssertEqual(BitstreamScan.h264(configuration: avcC, packet: sample)?.fieldOrder, .topFirst)
    }

    func testH264PAFFFieldSlice() {
        // No encoder makes PAFF (§6): an SPS with frame_mbs_only_flag 0 and no MBAFF, and IDR field slices.
        let sps = h264SPS(mbaff: false)
        let pps = h264PPS(bottomFieldPicOrderInFramePresent: true)
        let top = BitstreamScan.h264(configuration: [], packet: annexBBytes([sps, pps, h264Slice(field: true, bottom: false)]))
        XCTAssertEqual(top?.scanSource, "H.264 field slice")
        XCTAssertEqual(top?.fieldOrder, .topFirst)
        let bottom = BitstreamScan.h264(configuration: [], packet: annexBBytes([sps, pps, h264Slice(field: true, bottom: true)]))
        XCTAssertEqual(bottom?.fieldOrder, .bottomFirst)
        // A frame slice of frame macroblocks in a field-capable stream, with no SEI: nothing says interlaced.
        let frame = BitstreamScan.h264(configuration: [], packet: annexBBytes([sps, pps, h264Slice(field: false, bottom: false, delta: 1)]))
        XCTAssertNil(frame?.interlaced)
    }

    // MARK: - HEVC

    // x265 `interlace=tff` on `separatefields`: 1920×540 field pictures.
    let fieldSPS = "4201010408000003004d08000003000078b003c080221f2b65959a4932bc05a1a000007d20001d4c01"

    func testHEVCFieldSequence() throws {
        let sps = try XCTUnwrap(HEVCSPSColor.scan(nal: hex(fieldSPS)))
        XCTAssertEqual([sps.progressiveSource, sps.interlacedSource, sps.fieldSequence, sps.frameFieldInfoPresent],
                       [false, true, true, true])
        // The active-parameter-sets SEI (payload 129) first, then the picture timing SEI: pic_struct 1, top field.
        let r = BitstreamScan.hevc(configuration: [], packet: annexB([fieldSPS, "4e0181010f80", "4e0101011180"]))
        XCTAssertEqual(r?.interlaced, true)
        XCTAssertEqual(r?.fieldOrder, .topFirst)
        XCTAssertEqual(r?.scanSource, "HEVC field_seq_flag")
        XCTAssertEqual(r?.orderSource, "HEVC pic_struct SEI")
        // Without the SEI the fields are known and their order is not.
        let noSEI = BitstreamScan.hevc(configuration: [], packet: annexB([fieldSPS]))
        XCTAssertEqual(noSEI?.interlaced, true)
        XCTAssertNil(noSEI?.fieldOrder)
    }

    func testHEVCProgressiveFromSourceFlags() {
        // S7's hdr10-9-16-9-p3mastering-hevc.mov.
        let p = BitstreamScan.hevc(configuration: [], packet: annexB(
            ["420101022000000300900000030000030078a003c08010e4d96566924cae6a122013c20000030002000003003210"]))
        XCTAssertEqual(p?.interlaced, false)
        XCTAssertEqual(p?.scanSource, "HEVC SPS")
    }

    // MARK: - The rule

    func testBitstreamWinsPerAxisAndDisagreementsAreKept() {
        let fielBFF = ContainerScan.fiel(fieldCount: 2, fieldDetail: "SpatialFirstLineLate")
        let fielProg = ContainerScan.fiel(fieldCount: 1, fieldDetail: nil)
        let tff = BitstreamScan.prores(hex("00067faf69637066009400004c6176630780043884000202"))

        let order = SourceScan.resolve(container: fielBFF, bitstream: tff)
        XCTAssertEqual(order.scan, .interlaced(.topFirst))
        XCTAssertEqual(order.disagreements, [.init(axis: .fieldOrder, container: "bottom field first",
                                                   bitstream: "top field first")])
        XCTAssertEqual(order.readout, "Interlaced, top field first (ProRes frame header) · ⚠️ fiel says bottom field first")

        let scan = SourceScan.resolve(container: fielProg, bitstream: tff)
        XCTAssertEqual(scan.scan, .interlaced(.topFirst))
        XCTAssertEqual(scan.disagreements.map(\.axis), [.scan])
        XCTAssertTrue(scan.logLine.contains("⚠️ DISAGREE on scan (container progressive, bitstream interlaced)"))
    }

    func testContainerFillsOnlyAnAxisTheBitstreamLeaves() {
        // HEVC fields with no pic_struct: interlaced from the bitstream, the order from fiel.
        let fields = ScanReading(interlaced: true, fieldOrder: nil, scanSource: "HEVC field_seq_flag", detail: "")
        let fiel = ContainerScan.fiel(fieldCount: 2, fieldDetail: "SpatialFirstLineEarly")
        let s = SourceScan.resolve(container: fiel, bitstream: fields)
        XCTAssertEqual(s.scan, .interlaced(.topFirst))
        XCTAssertEqual(s.scanSource, "HEVC field_seq_flag")
        XCTAssertEqual(s.orderSource, "fiel")
        XCTAssertEqual(s.readout, "Interlaced (HEVC field_seq_flag), top field first (fiel)")
        XCTAssertTrue(s.disagreements.isEmpty)

        // A container that says progressive lends no order to an interlaced bitstream.
        let none = SourceScan.resolve(container: ContainerScan.fiel(fieldCount: 1, fieldDetail: nil), bitstream: fields)
        XCTAssertEqual(none.scan, .interlaced(nil))
        XCTAssertEqual(none.readout, "Interlaced (HEVC field_seq_flag), field order not stated · ⚠️ fiel says progressive")
    }

    func testNothingStated() {
        XCTAssertEqual(SourceScan.notRead.readout, "Not read")
        let silent = SourceScan.resolve(container: nil,
                                        bitstream: ScanReading(interlaced: nil, fieldOrder: nil, scanSource: "H.264 slice", detail: "x"))
        XCTAssertEqual(silent.scan, .unknown)
        XCTAssertEqual(silent.readout, "Unknown — neither the container nor the bitstream says")
        XCTAssertTrue(silent.logLine.hasSuffix("— nothing stated"))
        let containerOnly = SourceScan.resolve(container: ContainerScan.fiel(fieldCount: 2, fieldDetail: "SpatialFirstLineLate"),
                                               bitstream: nil)
        XCTAssertEqual(containerOnly.readout, "Interlaced, bottom field first (fiel)")
    }

    // MARK: - Helpers

    private func reading(_ i: Bool?, _ o: FieldOrder?, _ source: String, _ detail: String) -> ScanReading {
        ScanReading(interlaced: i, fieldOrder: o, scanSource: source, detail: detail)
    }

    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var it = s.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        return out
    }

    private func annexB(_ nals: [String]) -> [UInt8] { annexBBytes(nals.map(hex)) }
    private func annexBBytes(_ nals: [[UInt8]]) -> [UInt8] { nals.flatMap { [0, 0, 0, 1] + $0 } }

    private func lineMap(_ a: Int32, _ b: Int32) -> [UInt8] {
        func be32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }
        return be32(2) + be32(4) + be32(a) + be32(b)
    }

    /// A header partition with one CDCIDescriptor set holding `tags`.
    private func mxfHeader(_ tags: [UInt16: [UInt8]]) -> [UInt8] {
        var value: [UInt8] = []
        for (tag, v) in tags.sorted(by: { $0.key < $1.key }) {
            value += [UInt8(tag >> 8), UInt8(tag & 0xFF), UInt8(v.count >> 8), UInt8(v.count & 0xFF)] + v
        }
        let key = hex("060e2b34025301010d01010101012800")
        return key + [0x83, 0, UInt8(value.count >> 8), UInt8(value.count & 0xFF)] + value
    }

    // An H.264 Main SPS, 1920×1088 in field-capable form, POC type 0, no VUI.
    private func h264SPS(mbaff: Bool) -> [UInt8] {
        var w = BitWriter()
        w.bits(77, 8); w.bits(0, 8); w.bits(40, 8)            // profile_idc Main, constraints, level 4.0
        w.ue(0); w.ue(0); w.ue(0); w.ue(2)                     // sps id, log2_max_frame_num−4, poc type 0, log2_max_poc_lsb−4
        w.ue(1); w.bits(0, 1)                                  // max_num_ref_frames, gaps
        w.ue(119); w.ue(33)                                    // 120 MBs wide, 34 map units (68 MB rows)
        w.bits(0, 1); w.bits(mbaff ? 1 : 0, 1)                 // frame_mbs_only_flag 0, mb_adaptive_frame_field_flag
        w.bits(1, 1); w.bits(0, 1); w.bits(0, 1)               // direct_8x8, cropping, vui
        return [0x67] + w.rbsp()
    }

    private func h264PPS(bottomFieldPicOrderInFramePresent: Bool) -> [UInt8] {
        var w = BitWriter()
        w.ue(0); w.ue(0); w.bits(0, 1); w.bits(bottomFieldPicOrderInFramePresent ? 1 : 0, 1)
        w.ue(0); w.ue(0); w.ue(0)                              // slice groups, ref idx defaults (unread)
        return [0x68] + w.rbsp()
    }

    private func h264Slice(field: Bool, bottom: Bool, delta: Int = 0) -> [UInt8] {
        var w = BitWriter()
        w.ue(0); w.ue(7); w.ue(0)                              // first_mb, slice_type I, pps id
        w.bits(0, 4)                                           // frame_num
        w.bits(field ? 1 : 0, 1)                               // field_pic_flag
        if field { w.bits(bottom ? 1 : 0, 1) }                 // bottom_field_flag
        w.ue(0)                                                // idr_pic_id
        w.bits(0, 6)                                           // pic_order_cnt_lsb
        if !field { w.se(delta) }                              // delta_pic_order_cnt_bottom
        w.ue(0)                                                // (dec_ref_pic_marking onward, unread)
        return [0x65] + w.rbsp()
    }
}

/// MSB-first, with rbsp_trailing_bits and emulation prevention, for the hand-made H.264 NALs.
private struct BitWriter {
    private var out: [UInt8] = []
    private var acc = 0, n = 0
    mutating func bits(_ v: Int, _ count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) {
            acc = (acc << 1) | ((v >> i) & 1); n += 1
            if n == 8 { out.append(UInt8(acc)); acc = 0; n = 0 }
        }
    }
    mutating func ue(_ v: Int) {
        let x = v + 1, len = Int.bitWidth - x.leadingZeroBitCount
        bits(0, len - 1); bits(x, len)
    }
    mutating func se(_ v: Int) { ue(v > 0 ? 2 * v - 1 : -2 * v) }
    mutating func rbsp() -> [UInt8] {
        bits(1, 1); while n != 0 { bits(0, 1) }
        var escaped: [UInt8] = [], zeros = 0
        for b in out {
            if zeros >= 2 && b <= 3 { escaped.append(3); zeros = 0 }
            escaped.append(b); zeros = b == 0 ? zeros + 1 : 0
        }
        return escaped
    }
}
