//
//  ChromaFormatTests.swift
//  ColorimetryModelTests
//
//  Native chroma (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b, S1): which chroma a buffer
//  carries, the v210 output's reduction per source, the D3 halfband, and the chain readout's line.
//

import XCTest
import CoreVideo
@testable import ColorimetryModel

final class ChromaFormatTests: XCTestCase {

    private let x420 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    private let x422 = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    private let x444 = kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange

    func testTheTenBitBiplanarFamilyMapsBothRanges() {
        XCTAssertEqual(ChromaSubsampling(pixelFormat: x420), .c420)
        XCTAssertEqual(ChromaSubsampling(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange), .c420)
        XCTAssertEqual(ChromaSubsampling(pixelFormat: x422), .c422)
        XCTAssertEqual(ChromaSubsampling(pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange), .c422)
        XCTAssertEqual(ChromaSubsampling(pixelFormat: x444), .c444)
        XCTAssertEqual(ChromaSubsampling(pixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange), .c444)
    }

    /// Packed and 16-bit formats are not the shader's sample domain; 12-bit stays out (D5).
    func testFormatsTheRendererDoesNotSampleAreNil() {
        XCTAssertNil(ChromaSubsampling(pixelFormat: kCVPixelFormatType_422YpCbCr8))              // 2vuy
        XCTAssertNil(ChromaSubsampling(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        XCTAssertNil(ChromaSubsampling(pixelFormat: kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange)) // sv22
        XCTAssertNil(ChromaSubsampling(pixelFormat: kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange)) // sv44
    }

    func testOrderingMeansMoreChroma() {
        XCTAssertLessThan(ChromaSubsampling.c420, .c422)
        XCTAssertLessThan(ChromaSubsampling.c422, .c444)
    }

    /// 4:2:0 keeps today's kernel, so the 4:2:0 wire cannot change (P1).
    func testV210ModePerSource() {
        XCTAssertEqual(V210ChromaMode(carrying: .c420), .pairAverage)
        XCTAssertEqual(V210ChromaMode(carrying: nil), .pairAverage)
        XCTAssertEqual(V210ChromaMode(carrying: .c422), .cosited)
        XCTAssertEqual(V210ChromaMode(carrying: .c444), .halfband)
        XCTAssertEqual(V210ChromaMode.pairAverage.rawValue, 0, "the kernel's chromaMode uniform")
        XCTAssertEqual(V210ChromaMode.cosited.rawValue, 1)
        XCTAssertEqual(V210ChromaMode.halfband.rawValue, 2)
    }

    /// The two properties that make D3's filter a halfband: unity DC gain, and nothing at Nyquist,
    /// so a one-pixel chroma alternation reduces to its mean instead of aliasing onto the wire.
    func testHalfbandHasUnityDCAndZeroNyquist() {
        let taps = V210ChromaMode.halfbandTaps
        XCTAssertEqual(taps.count, 7)
        XCTAssertEqual(taps, taps.reversed(), "symmetric: cosited, no phase shift")
        XCTAssertEqual(taps.reduce(0, +), V210ChromaMode.halfbandDivisor)
        let nyquist = taps.enumerated().reduce(0) { $0 + ($1.offset % 2 == 0 ? $1.element : -$1.element) }
        XCTAssertEqual(nyquist, 0)
    }

    func testReadoutNative() {
        XCTAssertEqual(ChromaReadout.text(carried: x422, source: .declared(.c422), reason: nil),
                       "4:2:2 10-bit (x422) — native")
    }

    func testReadoutNotStatedAndUnknownAreDifferentStatements() {
        XCTAssertEqual(ChromaReadout.text(carried: x420, source: .notStated, reason: nil),
                       "4:2:0 10-bit (x420) — source chroma not stated")
        XCTAssertEqual(ChromaReadout.text(carried: x420, source: .unknown, reason: nil),
                       "4:2:0 10-bit (x420) — source chroma unknown")
    }

    /// Never silent: a loss names its reason, and with none it still says it was converted.
    func testReadoutALossIsStated() {
        XCTAssertEqual(ChromaReadout.text(carried: x420, source: .declared(.c422),
                                          reason: "forced to 4:2:0 by MANIFOLD_FORCE_CHROMA_420"),
                       "4:2:0 10-bit (x420) — 4:2:2 source, forced to 4:2:0 by MANIFOLD_FORCE_CHROMA_420")
        XCTAssertEqual(ChromaReadout.text(carried: x420, source: .declared(.c444), reason: nil),
                       "4:2:0 10-bit (x420) — 4:4:4 source, converted at decode")
    }

    func testReadoutFourFourFourNamesTheOneReduction() {
        XCTAssertEqual(ChromaReadout.text(carried: x444, source: .declared(.c444), reason: nil),
                       "4:4:4 10-bit (x444) — native · DeckLink v210 output: reduced once to 4:2:2 (halfband)")
    }

    func testReadoutNoPictureAndUnsampledFormat() {
        XCTAssertEqual(ChromaReadout.text(carried: nil, source: .declared(.c422), reason: nil), "no picture")
        XCTAssertEqual(ChromaReadout.text(carried: kCVPixelFormatType_422YpCbCr8, source: .notStated, reason: nil),
                       "2vuy — not a format the renderer samples")
    }
}
