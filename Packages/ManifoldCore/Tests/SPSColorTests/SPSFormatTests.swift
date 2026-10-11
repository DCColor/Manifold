//
//  SPSFormatTests.swift
//  SPSColorTests
//
//  The SRT gate's reading of an SPS — chroma format and bit depths — and its rule (docs/
//  COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b S3/S4; D5, D6, D7). Every SPS below came out of an
//  encoder (the system ffmpeg's libx264 / libx265, on scripts/chroma/generate.sh's fixtures), and
//  every expected value is `trace_headers`'s reading of it, not this reader's.
//

import XCTest
@testable import SPSColor

final class SPSFormatTests: XCTestCase {

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

    // H.264 — lines-422-h264.ts (x264 High 4:2:2, 10-bit), lines-422-h264-8bit.ts (8-bit),
    // checker-444-h264.ts (High 4:4:4 Predictive, 10-bit), and a monochrome x264 (`-pix_fmt gray`).
    private lazy var h264High422 = bytes("677a0028b6cd940780227e27011000000300100000030320f1831960")
    private lazy var h264High422x8 = bytes("677a0028bcd940780227e27011000003000100000300320f183196")
    private lazy var h264High444 = bytes("67f4002890dd6401e0089f89c044000003000400000300c83c60c920")
    private lazy var h264Gray = bytes("6764000df3650507ec05b2000003000200000300641e28532c")
    // From H264SPSColorTests: x264 High 4:2:0 8-bit, and openh264 Baseline (no high-profile block).
    private lazy var h264High420 = bytes("6764000cacb202833f3e02d4040405000003000100000300320f142a48")
    private lazy var h264Baseline = bytes("6742c0148c68141979f0101e1108d4")

    // HEVC — still-420-hevc10-intra.ts (x265 keyint=1: "Main 10 Intra", RExt, 4:2:0 10-bit),
    // lines-422-hevc.ts, checker-444-hevc.ts, and x265 at yuv422p12le (12-bit).
    private lazy var hevcMain10Intra = bytes("4201010408000003009da8000003000078a003c08010e4d96ea4932bc05a020000030002000003003210")
    private lazy var hevc422 = bytes("4201010408000003009d080000030000ffb003c08010e4d96566924caf016808000003000800000300c840")
    private lazy var hevc444 = bytes("4201010408000003009c080000030000ff90007810021c9b2cacd24995e02d010000030001000003001908")
    private lazy var hevc422x12 = bytes("420101040800000300990800000300003cb00a080f114a5959a4932bc05a020000030002000003003210")

    func testH264FormatMatchesTraceHeaders() {
        let cases: [([UInt8], Int, Int, Int, Int, String)] = [
            (h264High422, 122, 2, 10, 10, "High 4:2:2"),
            (h264High422x8, 122, 2, 8, 8, "High 4:2:2"),
            (h264High444, 244, 3, 10, 10, "High 4:4:4 Predictive"),
            (h264Gray, 100, 0, 8, 8, "High"),
            (h264High420, 100, 1, 8, 8, "High"),
            (h264Baseline, 66, 1, 8, 8, "Baseline"),   // no high-profile block: 4:2:0 8-bit by definition
        ]
        for (sps, profile, idc, luma, chroma, name) in cases {
            guard let f = H264SPSColor.format(nal: sps) else { XCTFail("no format: \(name)"); continue }
            XCTAssertEqual(f.codec, .h264)
            XCTAssertEqual([f.profileIdc, f.chromaFormatIdc, f.bitDepthLuma, f.bitDepthChroma],
                           [profile, idc, luma, chroma], name)
            XCTAssertEqual(f.profileName, name)
            // The same chroma format the S2 file resolver reads from the same SPS.
            XCTAssertEqual(H264SPSColor.chromaFormatIdc(nal: sps), idc, name)
        }
    }

    func testHEVCFormatMatchesTraceHeaders() {
        let cases: [([UInt8], Int, Int, Int)] = [
            (hevcMain10Intra, 4, 1, 10), (hevc422, 4, 2, 10), (hevc444, 4, 3, 10), (hevc422x12, 4, 2, 12),
        ]
        for (sps, profile, idc, depth) in cases {
            guard let f = HEVCSPSColor.format(nal: sps)?.neutral else { XCTFail("no format"); continue }
            XCTAssertEqual(f.codec, .hevc)
            XCTAssertEqual([f.profileIdc, f.chromaFormatIdc, f.bitDepthLuma, f.bitDepthChroma],
                           [profile, idc, depth, depth])
            XCTAssertEqual(f.profileName, "Format Range Extensions")
        }
    }

    /// The rule: chroma format and bit depth, never the profile (D6, D7; docs/BUGS.md, "Main 10 Intra").
    func testTheGateAcceptsEveryChromaFormatUpToTenBits() {
        for sps in [h264High422, h264High422x8, h264High444, h264High420, h264Baseline, h264Gray] {
            XCTAssertEqual(H264SPSColor.format(nal: sps)?.verdict, .accept)
        }
        for sps in [hevcMain10Intra, hevc422, hevc444] {
            XCTAssertEqual(HEVCSPSColor.format(nal: sps)?.neutral.verdict, .accept)
        }
        // The bug this closes: Stage 3's rule refused the RExt 4:2:0 10-bit stream.
        XCTAssertFalse(HEVCSPSColor.format(nal: hevcMain10Intra)!.isSupported420)
    }

    /// D5: more than 10 bits is refused, on either plane, whatever the chroma.
    func testTheGateRefusesMoreThanTenBits() {
        XCTAssertEqual(HEVCSPSColor.format(nal: hevc422x12)?.neutral.verdict, .refuseBitDepth)
        func f(_ luma: Int, _ chroma: Int) -> SPSFormat.Verdict {
            SPSFormat(codec: .h264, profileIdc: 244, profileName: "", chromaFormatIdc: 3,
                      bitDepthLuma: luma, bitDepthChroma: chroma).verdict
        }
        XCTAssertEqual(f(10, 10), .accept)
        XCTAssertEqual(f(12, 10), .refuseBitDepth)
        XCTAssertEqual(f(10, 12), .refuseBitDepth)
    }

    /// The log text for a 4:2:0 HEVC stream is Stage 3's, word for word (P11a: identical lines).
    func testTheHEVCLogTextIsStageThrees() {
        let f = SPSFormat(codec: .hevc, profileIdc: 2, profileName: "Main 10", chromaFormatIdc: 1,
                          bitDepthLuma: 10, bitDepthChroma: 10)
        XCTAssertEqual(f.described, "Main 10 (general_profile_idc 2), 4:2:0, 10-bit luma / 10-bit chroma")
        XCTAssertEqual(H264SPSColor.format(nal: h264High422)?.described,
                       "High 4:2:2 (profile_idc 122), 4:2:2, 10-bit luma / 10-bit chroma")
    }

    /// Truncated, mis-typed, out of range: no format, never a different one.
    func testAFormatIsAbsentOrExact() {
        for sps in [h264High422, h264High444, h264High420, h264Baseline] {
            let full = H264SPSColor.format(nal: sps)
            for n in 0..<sps.count {
                if let cut = H264SPSColor.format(nal: sps.prefix(n)) { XCTAssertEqual(cut, full) }
            }
        }
        XCTAssertNil(H264SPSColor.format(nal: [0x68, 0xeb, 0xe3, 0xc4, 0xc8]), "a PPS is not an SPS")
        XCTAssertNil(H264SPSColor.format(nal: hevc422), "an HEVC SPS is not an H.264 one")
    }
}
