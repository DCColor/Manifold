//
//  H264SPSColorTests.swift
//  H264SPSColorTests
//
//  The SPS colour reader against REAL SPS bytes (docs/COLOR_MANAGEMENT_FINDINGS.md §6.9, Stage SPS).
//
//  Every fixture's bytes came out of an encoder — the system ffmpeg with libx264, libopenh264 or
//  h264_videotoolbox — or out of ffmpeg's own `h264_metadata` bitstream filter rewriting such an SPS.
//  The one exception is `scalingLists`: x264 writes scaling matrices only in the PPS, so lists were
//  spliced into x264's pq2020 SPS; FFmpeg's reader accepts the result, reads 9/16/9 after the lists,
//  and its decode differs from the flat-matrix original, so the lists are live.
//
//  EVERY EXPECTED VALUE IS FFMPEG'S READING, NOT THIS READER'S. ffprobe is not installed on the build
//  Mac; `ffmpeg -i x.h264 -c copy -bsf:v trace_headers -f null -` (libavcodec's CBS parser, which
//  prints every SPS field) was used instead, and the literals below were generated from its output.
//

import XCTest
@testable import H264SPSColor

final class H264SPSColorTests: XCTestCase {

    private struct Fixture {
        let name: String
        let sps: [UInt8]
        let reach: H264SPSColor.Reach
        let primaries: Int?
        let transfer: Int?
        let matrix: Int?
        let fullRange: Bool?

        init(_ name: String, _ hex: String, reach: H264SPSColor.Reach,
             primaries: Int?, transfer: Int?, matrix: Int?, fullRange: Bool?) {
            self.name = name
            var bytes: [UInt8] = []
            var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                bytes.append(UInt8(hex[i..<j], radix: 16)!)
                i = j
            }
            sps = bytes
            self.reach = reach
            self.primaries = primaries; self.transfer = transfer; self.matrix = matrix
            self.fullRange = fullRange
        }
    }

    private let fixtures: [Fixture] = [
        // x264 High, colorprim/transfer/colormatrix=bt709
        Fixture("bt709", "6764000cacb202833f3e02d4040405000003000100000300320f142a48",
                reach: .colourDescription, primaries: 1, transfer: 1, matrix: 1, fullRange: false),
        // x264 High, bt2020 / smpte2084 / bt2020nc
        Fixture("pq2020", "6764000cacb202833f3e02d4244025000003000100000300320f142a48",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false),
        // x264 High, bt2020 / arib-std-b67 / bt2020nc
        Fixture("hlg2020", "6764000cacb202833f3e02d4244825000003000100000300320f142a48",
                reach: .colourDescription, primaries: 9, transfer: 18, matrix: 9, fullRange: false),
        // x264 High, smpte170m ×3
        Fixture("bt601", "6764000cacb202833f3e02d4181819000003000100000300320f142a48",
                reach: .colourDescription, primaries: 6, transfer: 6, matrix: 6, fullRange: false),
        // x264 High, fullrange=on, no colour flags: video_signal_type present, no colour description
        Fixture("noColourDescription", "6764000cacb202833f3e02d9000003000100000300320f142a48",
                reach: .noColourDescription, primaries: nil, transfer: nil, matrix: nil, fullRange: true),
        // x264 High defaults: VUI present, no video_signal_type
        Fixture("noVideoSignalType", "6764000cacb202833f3e0220000003002000000641e28549",
                reach: .noVideoSignalType, primaries: nil, transfer: nil, matrix: nil, fullRange: nil),
        // h264_videotoolbox High: no VUI at all
        Fixture("noVUI", "2764000dac56281419f9d0",
                reach: .noVUI, primaries: nil, transfer: nil, matrix: nil, fullRange: nil),
        // libopenh264 Constrained Baseline: VUI present, no video_signal_type
        Fixture("openh264Baseline", "6742c0148c68141979f0101e1108d4",
                reach: .noVideoSignalType, primaries: nil, transfer: nil, matrix: nil, fullRange: nil),
        // x264 Baseline (non-high branch), bt709 ×3
        Fixture("baseline709", "6742c00cd901419f9f016a020202800000030080000019078a1524",
                reach: .colourDescription, primaries: 1, transfer: 1, matrix: 1, fullRange: false),
        // x264 High 4:4:4 Predictive (profile 244, chroma_format_idc 3), bt709 ×3
        Fixture("high444", "67f4000c919b282833f1b80b50101014000003000400000300c83c50a658",
                reach: .colourDescription, primaries: 1, transfer: 1, matrix: 1, fullRange: false),
        // x264 High 10 (profile 110, bit_depth_luma_minus8 2), bt2020 / smpte2084 / bt2020nc
        Fixture("high10PQ", "676e001fa6cd9405005bb016a12201280000030008000003019078c18cb0",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false),
        // x264 High, interlaced (frame_mbs_only_flag 0), bt2020 / arib-std-b67 / bt2020nc
        Fixture("interlacedHLG", "67640015acd941433f2602d4244825000003000100000300321f142996",
                reach: .colourDescription, primaries: 9, transfer: 18, matrix: 9, fullRange: false),
        // x264 High, 318×178 (frame cropping), bt2020 / smpte2084 / bt2020nc
        Fixture("croppedPQ", "6764000cacd941419ea23016a12201280000030008000003019078a14cb0",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false),
        // pq2020 + h264_metadata sample_aspect_ratio=256/1: Extended_SAR puts 00 00 03 inside the VUI, before the colour fields
        Fixture("emulationPreventionInVUI", "6764000cacb202833f3ffe0200000302d4244025000003000100000300320f142a48",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false),
        // pq2020 with SPS scaling lists spliced in (x264 writes them only in the PPS): list 0 explicit, list 1 use-default, list 6 explicit 8×8
        Fixture("scalingLists", "6764000cadb318c6318c6318c6318d0884c6318c6318c6318c6318c6318c6318c6318c6318c6318c6318c6318c6318c6318c6318c6318c63196405067e7c05a848804a000003000200000300641e285490",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false),
        // bt709 + h264_metadata colour_primaries/transfer/matrix = 2: colour description present, every axis unspecified
        Fixture("unspecified222", "6764000cacb202833f3e02d4080809000003000100000300320f142a48",
                reach: .colourDescription, primaries: 2, transfer: 2, matrix: 2, fullRange: false),
        // bt709 + h264_metadata 9 / 2 / 9: transfer unspecified
        Fixture("partial9_2_9", "6764000cacb202833f3e02d4240825000003000100000300320f142a48",
                reach: .colourDescription, primaries: 9, transfer: 2, matrix: 9, fullRange: false),
        // bt709 + h264_metadata 3 / 0 / 3: reserved on every axis
        Fixture("reservedLow", "6764000cacb202833f3e02d40c000d000003000100000300320f142a48",
                reach: .colourDescription, primaries: 3, transfer: 0, matrix: 3, fullRange: false),
        // bt709 + h264_metadata 200 / 100 / 99: reserved on every axis
        Fixture("reservedHigh", "6764000cacb202833f3e02d721918d000003000100000300320f142a48",
                reach: .colourDescription, primaries: 200, transfer: 100, matrix: 99, fullRange: false),
        // bt709 + h264_metadata 5 / 6 / 5 (BT.470BG 625-line)
        Fixture("pal555", "6764000cacb202833f3e02d4141815000003000100000300320f142a48",
                reach: .colourDescription, primaries: 5, transfer: 6, matrix: 5, fullRange: false),
        // bt709 + h264_metadata 12 / 13 / 0: matrix 0 (identity) is a DECLARATION, not reserved
        Fixture("identityMatrix", "6764000cacb202833f3e02d4303401000003000100000300320f142a48",
                reach: .colourDescription, primaries: 12, transfer: 13, matrix: 0, fullRange: false),
        // bt709 + h264_metadata 11 / 4 / 14
        Fixture("dciP3", "6764000cacb202833f3e02d42c1039000003000100000300320f142a48",
                reach: .colourDescription, primaries: 11, transfer: 4, matrix: 14, fullRange: false),
    ]

    private func fixture(_ name: String) -> Fixture { fixtures.first { $0.name == name }! }

    // MARK: Raw fields — each fixture against FFmpeg's reading

    func testEveryFixtureMatchesFFmpegsReading() {
        for f in fixtures {
            let r = H264SPSColor.parse(nal: f.sps)
            XCTAssertEqual(r.reach, f.reach, f.name)
            XCTAssertEqual(r.colourPrimaries, f.primaries, f.name)
            XCTAssertEqual(r.transferCharacteristics, f.transfer, f.name)
            XCTAssertEqual(r.matrixCoefficients, f.matrix, f.name)
            XCTAssertEqual(r.videoFullRangeFlag, f.fullRange, f.name)
        }
    }

    // MARK: Per-axis verdict — absent, unspecified (2) and reserved are undeclared

    private func verdict(_ name: String) -> [Int?] {
        let r = H264SPSColor.parse(nal: fixture(name).sps)
        return [r.primaries, r.transfer, r.matrix]
    }

    func testDeclaredFixtures() {
        XCTAssertEqual(verdict("bt709"), [1, 1, 1])
        XCTAssertEqual(verdict("pq2020"), [9, 16, 9])
        XCTAssertEqual(verdict("hlg2020"), [9, 18, 9])
        XCTAssertEqual(verdict("bt601"), [6, 6, 6])
        XCTAssertEqual(verdict("pal555"), [5, 6, 5])
        XCTAssertEqual(verdict("dciP3"), [11, 4, 14])
    }

    func testEveryProfileBranchReachesTheColourFields() {
        XCTAssertEqual(verdict("baseline709"), [1, 1, 1])        // no high-profile block
        XCTAssertEqual(verdict("high444"), [1, 1, 1])            // chroma_format_idc 3
        XCTAssertEqual(verdict("high10PQ"), [9, 16, 9])          // bit depth fields non-zero
        XCTAssertEqual(verdict("interlacedHLG"), [9, 18, 9])     // mb_adaptive_frame_field_flag
        XCTAssertEqual(verdict("croppedPQ"), [9, 16, 9])         // four cropping offsets
        XCTAssertEqual(verdict("scalingLists"), [9, 16, 9])      // scaling lists walked, not skipped
        XCTAssertEqual(verdict("emulationPreventionInVUI"), [9, 16, 9])
    }

    func testUndeclaredWhenAbsent() {
        for name in ["noVUI", "noVideoSignalType", "openh264Baseline", "noColourDescription"] {
            XCTAssertEqual(verdict(name), [nil, nil, nil], name)
        }
    }

    func testUnspecifiedAndReservedAreUndeclaredPerAxis() {
        XCTAssertEqual(verdict("unspecified222"), [nil, nil, nil])
        XCTAssertEqual(verdict("partial9_2_9"), [9, nil, 9])     // judged per axis, not as a triple
        XCTAssertEqual(verdict("reservedLow"), [nil, nil, nil])  // 3 / 0 / 3
        XCTAssertEqual(verdict("reservedHigh"), [nil, nil, nil]) // 200 / 100 / 99
    }

    func testMatrixZeroIsIdentityNotReserved() {
        // 0 is reserved for primaries and transfer, and is Identity (GBR) for the matrix.
        XCTAssertEqual(verdict("identityMatrix"), [12, 13, 0])
        XCTAssertFalse(H264SPSColor.isDeclared(primaries: 0))
        XCTAssertFalse(H264SPSColor.isDeclared(transfer: 0))
        XCTAssertTrue(H264SPSColor.isDeclared(matrix: 0))
    }

    func testDeclaredTablesAtTheirEdges() {
        XCTAssertEqual((0...23).filter(H264SPSColor.isDeclared(primaries:)), [1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 22])
        XCTAssertEqual((0...19).filter(H264SPSColor.isDeclared(transfer:)), [1] + Array(4...18))
        XCTAssertEqual((0...15).filter(H264SPSColor.isDeclared(matrix:)), [0, 1] + Array(4...14))
        XCTAssertFalse(H264SPSColor.isDeclared(primaries: 255))
    }

    // MARK: Never throws, never traps: anything odd is undeclared

    func testEveryTruncationIsUndeclaredOrExact() {
        // Every prefix of a real SPS: either the colour was fully read (then it must be the right
        // colour) or it reads as undeclared. A prefix must never produce a DIFFERENT colour.
        for name in ["pq2020", "scalingLists", "emulationPreventionInVUI", "high444", "interlacedHLG"] {
            let f = fixture(name)
            for n in 0...f.sps.count {
                let r = H264SPSColor.parse(nal: f.sps.prefix(n))
                let axes = [r.primaries, r.transfer, r.matrix]
                XCTAssertTrue(axes == [nil, nil, nil] || axes == [f.primaries, f.transfer, f.matrix],
                              "\(name) cut at \(n): \(axes)")
            }
        }
    }

    func testCutBeforeTheColourFieldsIsMalformed() {
        let f = fixture("pq2020")
        XCTAssertEqual(H264SPSColor.parse(nal: f.sps.prefix(12)).reach, .malformed)
    }

    func testNotAnSPS() {
        XCTAssertEqual(H264SPSColor.parse(nal: [UInt8]()).reach, .notAnSPS)
        XCTAssertEqual(H264SPSColor.parse(nal: [0x67, 0x64]).reach, .notAnSPS)
        // A PPS (type 8) must not be read as an SPS, however plausible its bytes.
        var pps = fixture("pq2020").sps
        pps[0] = 0x68
        XCTAssertEqual(H264SPSColor.parse(nal: pps).reach, .notAnSPS)
        // forbidden_zero_bit set.
        var forbidden = fixture("pq2020").sps
        forbidden[0] |= 0x80
        XCTAssertEqual(H264SPSColor.parse(nal: forbidden).reach, .notAnSPS)
    }

    func testGarbageNeverTrapsAndNeverDeclaresByAccident() {
        // Deterministic pseudo-random SPS-typed garbage. The reader must return for every one; the
        // bound checks are what keep a desynchronised parse from walking into the colour fields.
        var state: UInt32 = 0x2545F491
        func next() -> UInt8 { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return UInt8(state & 0xFF) }
        var malformed = 0
        for length in 5..<64 {
            for _ in 0..<200 {
                var bytes = [UInt8(0x67)]
                for _ in 1..<length { bytes.append(next()) }
                if H264SPSColor.parse(nal: bytes).reach == .malformed { malformed += 1 }
            }
        }
        XCTAssertGreaterThan(malformed, 0)
        // All zeros: an unbounded ue() would spin here.
        XCTAssertEqual(H264SPSColor.parse(nal: [0x67] + [UInt8](repeating: 0, count: 200)).reach, .malformed)
        // Oversized.
        XCTAssertEqual(H264SPSColor.parse(nal: [0x67] + [UInt8](repeating: 0xFF, count: 2000)).reach, .malformed)
    }

    func testUnescapeDropsOnlyTheEscapeByte() {
        XCTAssertEqual(H264SPSColor.unescape([0x00, 0x00, 0x03, 0x01]), [0x00, 0x00, 0x01])
        XCTAssertEqual(H264SPSColor.unescape([0x00, 0x00, 0x03, 0x03]), [0x00, 0x00, 0x03])
        XCTAssertEqual(H264SPSColor.unescape([0x00, 0x03, 0x00]), [0x00, 0x03, 0x00])
        XCTAssertEqual(H264SPSColor.unescape([0x00, 0x00, 0x03, 0x00, 0x00, 0x03]), [0x00, 0x00, 0x00, 0x00])
    }

    func testArraySliceInputMatchesArrayInput() {
        // The transports hand over Data; slices and arrays must read identically.
        let f = fixture("emulationPreventionInVUI")
        let padded = [UInt8(0xAA)] + f.sps + [0xBB]
        XCTAssertEqual(H264SPSColor.parse(nal: padded[1..<(padded.count - 1)]), H264SPSColor.parse(nal: f.sps))
    }
}
