//
//  FileChromaTests.swift
//  FileChromaTests
//
//  The file chroma resolver (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b S2): the ProRes table,
//  the SPS in real avcC / hvcC boxes (lifted from scripts/chroma/generate.sh's fixtures), libav pixel
//  format shifts, D8's unknown, and the force switch.
//

import XCTest
import CoreVideo
import ColorimetryModel
import SPSColor
@testable import FileChroma

final class FileChromaTests: XCTestCase {

    private let x420 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    private let x422 = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    private let x444 = kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange

    private func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    func testProResFourCCs() {
        for code in ["apco", "apcs", "apcn", "apch"] {
            XCTAssertEqual(FileChromaResolver.declared(codecType: fourCC(code), atoms: [:]).source,
                           .declared(.c422), code)
        }
        for code in ["ap4h", "ap4x"] {
            XCTAssertEqual(FileChromaResolver.declared(codecType: fourCC(code), atoms: [:]).source,
                           .declared(.c444), code)
        }
        // ProRes RAW is Bayer: no claim.
        XCTAssertEqual(FileChromaResolver.declared(codecType: fourCC("aprn"), atoms: [:]).source, .unknown)
    }

    func testH264FromTheSPSInAvcC() {
        XCTAssertEqual(FileChromaResolver.h264ChromaFormatIdc(avcC: Self.avcC420), 1)
        XCTAssertEqual(FileChromaResolver.h264ChromaFormatIdc(avcC: Self.avcC422), 2)
        XCTAssertEqual(FileChromaResolver.declared(codecType: fourCC("avc1"), atoms: ["avcC": Self.avcC422]).source,
                       .declared(.c422))
    }

    func testH264NonHighProfilesAreFourTwoZeroByDefinition() {
        // Main (77): no high-profile block, so chroma_format_idc is inferred 1. A hand-built SPS:
        // header 0x67, profile 77, flags 0, level 40, then ue(0) for the id (a single 1 bit).
        XCTAssertEqual(H264SPSColor.chromaFormatIdc(nal: [0x67, 77, 0x00, 40, 0x80]), 1)
        // A PPS is not an SPS.
        XCTAssertNil(H264SPSColor.chromaFormatIdc(nal: [0x68, 0xeb, 0xe3, 0xc4, 0xc8]))
    }

    func testHEVCFromTheSPSInHvcC() {
        XCTAssertEqual(FileChromaResolver.hevcChromaFormatIdc(hvcC: Self.hvcC420), 1)
        XCTAssertEqual(FileChromaResolver.hevcChromaFormatIdc(hvcC: Self.hvcC422), 2)
        XCTAssertEqual(FileChromaResolver.hevcChromaFormatIdc(hvcC: Self.hvcC444), 3)
        XCTAssertEqual(FileChromaResolver.declared(codecType: fourCC("hvc1"), atoms: ["hvcC": Self.hvcC444]).source,
                       .declared(.c444))
    }

    /// A truncated box, or no box, is unknown: never a guess.
    func testUnreadableParameterSetsAreUnknown() {
        XCTAssertNil(FileChromaResolver.hevcChromaFormatIdc(hvcC: Array(Self.hvcC422.prefix(40))))
        XCTAssertNil(FileChromaResolver.h264ChromaFormatIdc(avcC: Array(Self.avcC422.prefix(10))))
        XCTAssertEqual(FileChromaResolver.declared(codecType: fourCC("avc1"), atoms: [:]).source, .unknown)
    }

    /// D8: a codec with no table stays at 4:2:0 and says "unknown".
    func testUnknownCodecsCarryFourTwoZero() {
        for code in ["mp4v", "xd5c", "dvh5", "ai5q"] {
            let d = FileChromaResolver.declared(codecType: fourCC(code), atoms: [:])
            XCTAssertEqual(d.source, .unknown, code)
            let r = FileChromaResolver.resolve(d.source, basis: d.basis, force420: false, forceReason: "f")
            XCTAssertEqual(r.pixelFormat, x420, code)
            XCTAssertNil(r.reason)
        }
    }

    func testLibavPixelFormatShifts() {
        func src(_ w: Int, _ h: Int, rgb: Bool = false, n: Int = 3) -> SourceChroma {
            FileChromaResolver.declared(pixFmtName: "t", log2ChromaW: w, log2ChromaH: h, isRGB: rgb,
                                        components: n).source
        }
        XCTAssertEqual(src(1, 1), .declared(.c420))       // yuv420p10le
        XCTAssertEqual(src(1, 0), .declared(.c422))       // yuv422p10le (DNxHR HQX)
        XCTAssertEqual(src(0, 0), .declared(.c444))       // yuv444p10le
        XCTAssertEqual(src(0, 0, rgb: true), .declared(.c444))   // gbrp12le (DNxHR 444 with ACT)
        XCTAssertEqual(src(0, 0, n: 1), .unknown)         // gray
        XCTAssertEqual(src(2, 0), .unknown)               // yuv411p
    }

    func testResolveCarriesNativeChroma() {
        for (c, pf) in [(ChromaSubsampling.c420, x420), (.c422, x422), (.c444, x444)] {
            let r = FileChromaResolver.resolve(.declared(c), basis: "b", force420: false, forceReason: "f")
            XCTAssertEqual(r.pixelFormat, pf)
            XCTAssertEqual(r.source, .declared(c))
            XCTAssertNil(r.reason)
            // The readout reads it as native.
            XCTAssertTrue(ChromaReadout.text(carried: r.pixelFormat, source: r.source, reason: r.reason)
                .contains("— native"))
        }
    }

    /// The debug switch lowers 4:2:2 and 4:4:4 to 4:2:0 with its reason; 4:2:0 and unknown are untouched.
    func testForceSwitch() {
        let r = FileChromaResolver.resolve(.declared(.c422), basis: "b", force420: true, forceReason: "forced")
        XCTAssertEqual(r.pixelFormat, x420)
        XCTAssertEqual(r.reason, "forced")
        XCTAssertEqual(ChromaReadout.text(carried: r.pixelFormat, source: r.source, reason: r.reason),
                       "4:2:0 10-bit (x420) — 4:2:2 source, forced")
        let n = FileChromaResolver.resolve(.declared(.c420), basis: "b", force420: true, forceReason: "forced")
        XCTAssertNil(n.reason)
        let u = FileChromaResolver.resolve(.unknown, basis: "b", force420: true, forceReason: "forced")
        XCTAssertNil(u.reason)
        XCTAssertEqual(u.pixelFormat, x420)
    }

    // MARK: - Fixture bytes (scripts/chroma/generate.sh)

    /// `still-420-h264.mov` (x264 High, 4:2:0)
    static let avcC420: [UInt8] = [
        0x01, 0x64, 0x00, 0x28, 0xff, 0xe1, 0x00, 0x1b, 0x67, 0x64, 0x00, 0x28, 0xac, 0xd9, 0x40, 0x78,
        0x02, 0x27, 0xe5, 0xc0, 0x44, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0xc8, 0x3c,
        0x60, 0xc6, 0x58, 0x01, 0x00, 0x06, 0x68, 0xeb, 0xe3, 0xc4, 0xc8, 0x4c, 0xfd, 0xf8, 0xf8, 0x00,
    ]

    /// `lines-422-h264-intra.mov` (x264 High 4:2:2 Intra 10)
    static let avcC422: [UInt8] = [
        0x01, 0x7a, 0x10, 0x28, 0xff, 0xe1, 0x00, 0x18, 0x67, 0x7a, 0x10, 0x28, 0xb6, 0xcb, 0x80, 0xf0,
        0x04, 0x4f, 0xc4, 0xe0, 0x22, 0x00, 0x00, 0x03, 0x00, 0x02, 0x00, 0x00, 0x03, 0x00, 0x64, 0x08,
        0x01, 0x00, 0x06, 0x68, 0xee, 0x00, 0x97, 0x2c, 0x8b, 0xfe, 0xfa, 0xfa, 0x00,
    ]

    /// `still-420-hevc10.mov` (x265 Main 10), VPS/SPS/PPS only (the x265 SEI dropped)
    static let hvcC420: [UInt8] = [
        0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78, 0xf0, 0x00, 0xfc,
        0xfd, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x03, 0xa0, 0x00, 0x01, 0x00, 0x18, 0x40, 0x01, 0x0c, 0x01,
        0xff, 0xff, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
        0x78, 0x95, 0x98, 0x09, 0xa1, 0x00, 0x01, 0x00, 0x2c, 0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00,
        0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0xa0, 0x03, 0xc0, 0x80, 0x10,
        0xe4, 0xd9, 0x65, 0x66, 0x92, 0x4c, 0xaf, 0x01, 0x68, 0x08, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00,
        0x00, 0x03, 0x00, 0xc8, 0x40, 0xa2, 0x00, 0x01, 0x00, 0x07, 0x44, 0x01, 0xc1, 0x72, 0xb4, 0x62,
        0x40,
    ]

    /// `lines-422-hevc.mov` (x265 lossless 4:2:2 10), VPS/SPS/PPS only
    static let hvcC422: [UInt8] = [
        0x01, 0x04, 0x08, 0x00, 0x00, 0x00, 0x9d, 0x08, 0x00, 0x00, 0x00, 0x00, 0xff, 0xf0, 0x00, 0xfc,
        0xfe, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x03, 0xa0, 0x00, 0x01, 0x00, 0x17, 0x40, 0x01, 0x0c, 0x01,
        0xff, 0xff, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9d, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0xff,
        0x95, 0x98, 0x09, 0xa1, 0x00, 0x01, 0x00, 0x2b, 0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03,
        0x00, 0x9d, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0xff, 0xb0, 0x03, 0xc0, 0x80, 0x10, 0xe4, 0xd9,
        0x65, 0x66, 0x92, 0x4c, 0xaf, 0x01, 0x68, 0x08, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03,
        0x00, 0xc8, 0x40, 0xa2, 0x00, 0x01, 0x00, 0x06, 0x44, 0x01, 0xc1, 0x71, 0xab, 0x12,
    ]

    /// `checker-444-hevc.mov` (x265 lossless 4:4:4 10), VPS/SPS/PPS only
    static let hvcC444: [UInt8] = [
        0x01, 0x04, 0x08, 0x00, 0x00, 0x00, 0x9c, 0x08, 0x00, 0x00, 0x00, 0x00, 0xff, 0xf0, 0x00, 0xfc,
        0xff, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x03, 0xa0, 0x00, 0x01, 0x00, 0x17, 0x40, 0x01, 0x0c, 0x01,
        0xff, 0xff, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9c, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0xff,
        0x95, 0x98, 0x09, 0xa1, 0x00, 0x01, 0x00, 0x2b, 0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03,
        0x00, 0x9c, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0xff, 0x90, 0x00, 0x78, 0x10, 0x02, 0x1c, 0x9b,
        0x2c, 0xac, 0xd2, 0x49, 0x95, 0xe0, 0x2d, 0x01, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x03,
        0x00, 0x19, 0x08, 0xa2, 0x00, 0x01, 0x00, 0x08, 0x44, 0x01, 0xc1, 0x70, 0x30, 0x62, 0xb1, 0x20,
    ]

}
