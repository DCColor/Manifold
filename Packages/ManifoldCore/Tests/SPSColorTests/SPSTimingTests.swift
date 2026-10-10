//
//  SPSTimingTests.swift
//  SPSColorTests
//
//  The HEVC timing readers against VPS and SPS bytes from real senders (docs/COLOR_MANAGEMENT_FINDINGS.md
//  §6.10, Stage 4). EVERY EXPECTED VALUE IS FFMPEG'S READING (`trace_headers`), not this reader's.
//
//  Senders: x265 build 215 and hevc_videotoolbox through the system ffmpeg 8.1.1, the same streams
//  through MediaMTX v1.21.1's SRT, and hevc_metadata `tick_rate=25/1` on the VideoToolbox stream (VPS +
//  VUI). H.264's timing is read by App/H264/H264SPSTiming.c, not here.
//

import XCTest
@testable import SPSColor

final class SPSTimingTests: XCTestCase {

    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // HEVC
    private let x265PQ_VPS = "40010c01ffff022000000300900000030000030078959809"
    private let x265PQ_SPS = "420101022000000300900000030000030078a003c08010e4d96566924caf016a12201208000003000800000300c840"
    private let x265B8_SPS = "420101022000000300900000030000030078a003c08010e4d96562a4932bc05a84880482000007d20000bb8010"
    private let x265_709MTX_SPS = "420101016000000300900000030000030078a003c08010e596566924caf016a020202080000003008000000c84"
    private let vt_VPS = "40010c01ffff022000000300b000000300000300781b0240"
    private let vtMeta_SPS = "420101022000000300b00000030000030078a003c0801107cad881bb916452ffcb9fc4feb016a122012010"
    private let vtTick25_VPS = "40010c01ffff022000000300b000000300000300781b030000030001000003001950"
    private let vtTick25_SPS = "420101022000000300b00000030000030078a003c0801107cad881bb916452ffcb9fc4feb016a122012080000003008000000c84"

    func testHEVCSendersThatDeclare() throws {
        let pq = HEVCSPSColor.timing(nal: bytes(x265PQ_SPS))
        XCTAssertEqual(pq, SPSTiming(source: .sps, numUnitsInTick: 1, timeScale: 25))
        XCTAssertEqual(pq?.frameRate, 25)

        let b8 = HEVCSPSColor.timing(nal: bytes(x265B8_SPS))
        XCTAssertEqual(b8, SPSTiming(source: .sps, numUnitsInTick: 1001, timeScale: 24000))
        XCTAssertEqual(try XCTUnwrap(b8?.frameRate), 24000.0 / 1001, accuracy: 1e-9)

        // Through MediaMTX: the SPS is the sender's, untouched.
        XCTAssertEqual(HEVCSPSColor.timing(nal: bytes(x265_709MTX_SPS))?.frameRate, 25)

        // hevc_metadata writes both; each is read on its own.
        XCTAssertEqual(HEVCSPSColor.timing(nal: bytes(vtTick25_SPS)),
                       SPSTiming(source: .sps, numUnitsInTick: 1, timeScale: 25))
        XCTAssertEqual(HEVCSPSColor.vpsTiming(nal: bytes(vtTick25_VPS)),
                       SPSTiming(source: .vps, numUnitsInTick: 1, timeScale: 25))
    }

    func testHEVCSendersThatDoNot() {
        // VideoToolbox: a VUI with colour, and vui_timing_info_present_flag 0; the VPS declares none.
        XCTAssertNil(HEVCSPSColor.timing(nal: bytes(vtMeta_SPS)))
        XCTAssertNil(HEVCSPSColor.vpsTiming(nal: bytes(vt_VPS)))
        // x265 writes timing in the SPS only (vps_timing_info_present_flag 0).
        XCTAssertNil(HEVCSPSColor.vpsTiming(nal: bytes(x265PQ_VPS)))
    }

    /// The colour walk is unchanged by the timing walk that continues it.
    func testColourStillReadsTheSame() {
        XCTAssertEqual(HEVCSPSColor.parse(nal: bytes(vtTick25_SPS)), HEVCSPSColor.parse(nal: bytes(vtMeta_SPS)))
    }

    /// A truncated parameter set declares nothing or exactly the full reading, never another rate.
    func testEveryTruncationIsNilOrExact() {
        let cases: [(String, ([UInt8]) -> SPSTiming?)] = [
            (x265PQ_SPS, { HEVCSPSColor.timing(nal: $0) }),
            (x265B8_SPS, { HEVCSPSColor.timing(nal: $0) }),
            (vtTick25_SPS, { HEVCSPSColor.timing(nal: $0) }),
            (vtTick25_VPS, { HEVCSPSColor.vpsTiming(nal: $0) }),
        ]
        for (hex, read) in cases {
            let full = bytes(hex)
            let expected = read(full)
            XCTAssertNotNil(expected)
            for n in 0..<full.count {
                let got = read(Array(full.prefix(n)))
                XCTAssertTrue(got == nil || got == expected, "\(hex.prefix(8))… cut at \(n): \(String(describing: got))")
            }
        }
    }

    func testWrongNALTypesDeclareNothing() {
        XCTAssertNil(HEVCSPSColor.timing(nal: bytes(vtTick25_VPS)))    // a VPS is not an SPS
        XCTAssertNil(HEVCSPSColor.vpsTiming(nal: bytes(vtTick25_SPS))) // and the reverse
        XCTAssertNil(HEVCSPSColor.timing(nal: [0x67, 0x42, 0xc0, 0x28, 0xda, 0x01, 0xe0]))  // an H.264 SPS header
    }

    func testFrameRateIsNilWhenTheDeclarationIsNotOne() {
        XCTAssertNil(SPSTiming(source: .sps, numUnitsInTick: 0, timeScale: 25).frameRate)
        XCTAssertNil(SPSTiming(source: .vps, numUnitsInTick: 1, timeScale: 0).frameRate)
        XCTAssertNil(SPSTiming(source: .sps, numUnitsInTick: 1, timeScale: 50, fieldSequence: true).frameRate)
    }

    func testGarbageNeverTraps() {
        // Deterministic pseudo-random bytes behind each reader's header; every call must return.
        var state: UInt32 = 0x2545F491
        func next() -> UInt8 { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return UInt8(state & 0xFF) }
        for length in 4..<96 {
            for _ in 0..<100 {
                var body: [UInt8] = []
                for _ in 2..<length { body.append(next()) }
                _ = HEVCSPSColor.timing(nal: [0x42, 0x01] + body)
                _ = HEVCSPSColor.vpsTiming(nal: [0x40, 0x01] + body)
            }
        }
        // All zeros: an unbounded ue() would spin here.
        XCTAssertNil(HEVCSPSColor.vpsTiming(nal: [0x40, 0x01] + [UInt8](repeating: 0, count: 200)))
        XCTAssertNil(HEVCSPSColor.timing(nal: [0x42, 0x01] + [UInt8](repeating: 0, count: 200)))
    }
}
