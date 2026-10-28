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

    /// An 8-bit 4:2:0 file is decoded to `420v` (docs/BUGS.md, *8-bit H.264 files lose vertical chroma detail in the
    /// decode*): the renderer samples it as 4:2:0 and the readout names its depth. The live promotes' question
    /// (`init?(pixelFormat:)`: is this already a 10-bit carrier?) is unchanged, so 420v still needs promoting there.
    func testTheEightBitCarrierIsSampledAsFourTwoZero() {
        let v420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        XCTAssertEqual(ChromaSubsampling.eightBitCarrier420, v420)
        XCTAssertEqual(ChromaSubsampling(sampledFormat: v420), .c420)
        XCTAssertNil(ChromaSubsampling(pixelFormat: v420))
        for (pf, c) in [(x420, ChromaSubsampling.c420), (x422, .c422), (x444, .c444)] {
            XCTAssertEqual(ChromaSubsampling(sampledFormat: pf), c)
            XCTAssertEqual(ChromaSubsampling.sampledBitDepth(pf), 10)
        }
        XCTAssertEqual(ChromaSubsampling.sampledBitDepth(v420), 8)
        XCTAssertNil(ChromaSubsampling(sampledFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        XCTAssertNil(ChromaSubsampling(sampledFormat: kCVPixelFormatType_422YpCbCr8))
        XCTAssertEqual(ChromaReadout.text(carried: v420, source: .declared(.c420), reason: nil),
                       "4:2:0 8-bit (420v) — native")
    }

    // MARK: - Live decode (Stage 3b S3/S4)

    /// The request follows the SPS's chroma. A 4:2:0 SPS that is not 8-bit H.264 asks for x420, exactly
    /// what every live decode asked for before S3 (the 8-bit case is the next test).
    func testLiveDecodeRequestFollowsTheSPS() {
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 1, force420: false), x420)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 2, force420: false), x422)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 3, force420: false), x444)
        // No SPS yet, unreadable, or monochrome: x420, as before.
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: nil, force420: false), x420)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 0, force420: false), x420)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 7, force420: false), x420)
        // The DEBUG switch lowers everything to x420 (P10).
        for idc in [1, 2, 3] {
            XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: idc, force420: true), x420)
        }
    }

    /// An 8-bit 4:2:0 H.264 stream asks for `420v`, as an 8-bit 4:2:0 file does (docs/BUGS.md, *8-bit H.264 / HEVC
    /// streams lose vertical chroma detail in the decode*): only that one. 8-bit 4:2:2 / 4:4:4 keep their 10-bit
    /// carrier, an unread SPS stays x420, and forcing 4:2:0 changes nothing for a 4:2:0 stream.
    func testEightBitFourTwoZeroStreamAsksForTheEightBitCarrier() {
        let v420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 1, eightBit: true, force420: false), v420)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 1, eightBit: true, force420: true), v420)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 1, eightBit: false, force420: false), x420)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 2, eightBit: true, force420: false), x422)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 3, eightBit: true, force420: false), x444)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 2, eightBit: true, force420: true), x420)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: nil, eightBit: true, force420: false), x420)
        XCTAssertEqual(ChromaSubsampling.liveDecodeRequest(chromaFormatIdc: 0, eightBit: true, force420: false), x420)
    }

    /// `420v` refused falls back to x420 (the request every 8-bit stream had before), then native; every other
    /// request goes straight to native, as before. Only a 420v request that came back as something else is a loss.
    func testTheEightBitRequestFallsBackToTenBitWithABanner() {
        let v420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        XCTAssertEqual(ChromaSubsampling.liveDecodeAttempts(v420), [v420, x420, nil])
        for pf in [x420, x422, x444] { XCTAssertEqual(ChromaSubsampling.liveDecodeAttempts(pf), [pf, nil]) }
        XCTAssertNil(ChromaSubsampling.liveEightBitFallback(requested: v420, delivered: v420))
        XCTAssertNil(ChromaSubsampling.liveEightBitFallback(requested: x420, delivered: x420))
        XCTAssertNil(ChromaSubsampling.liveEightBitFallback(requested: x422, delivered: x420))
        XCTAssertEqual(ChromaSubsampling.liveEightBitFallback(requested: v420, delivered: x420),
                       "This stream’s 8-bit color could not be decoded exactly (VideoToolbox delivered x420 instead "
                       + "of 420v; decoded at x420, which softens vertical color detail). The picture, scopes, SDI "
                       + "output and frame export carry slightly softer vertical color detail.")
    }

    /// The promote keeps the chroma a decoder delivered: 8-bit, packed and 16-bit formats map to their
    /// own chroma, so 8-bit 4:2:2 is promoted to x422, never resampled to x420.
    func testDeliveredFormatsKeepTheirChroma() {
        let c420: [OSType] = [x420, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 0x7034_3230]
        let c422: [OSType] = [x422, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8,
                              kCVPixelFormatType_422YpCbCr10, 0x7034_3232, kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange]
        let c444: [OSType] = [x444, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10,
                              0x7034_3434, kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange]
        for pf in c420 { XCTAssertEqual(ChromaSubsampling(deliveredFormat: pf), .c420, ChromaReadout.fourCC(pf)) }
        for pf in c422 { XCTAssertEqual(ChromaSubsampling(deliveredFormat: pf), .c422, ChromaReadout.fourCC(pf)) }
        for pf in c444 { XCTAssertEqual(ChromaSubsampling(deliveredFormat: pf), .c444, ChromaReadout.fourCC(pf)) }
        XCTAssertNil(ChromaSubsampling(deliveredFormat: kCVPixelFormatType_32BGRA))
        XCTAssertEqual(ChromaSubsampling.c422.carrierPixelFormat, x422)
        XCTAssertEqual(ChromaSubsampling(chromaFormatIdc: 0), nil)
    }

    /// "software decode" is a note, not a loss: it rides after the line, native or not.
    func testReadoutSoftwareDecodeNote() {
        XCTAssertEqual(ChromaReadout.text(carried: x422, source: .declared(.c422), reason: nil, note: "software decode"),
                       "4:2:2 10-bit (x422) — native · software decode")
        XCTAssertEqual(ChromaReadout.text(carried: x444, source: .declared(.c444), reason: nil, note: "software decode"),
                       "4:4:4 10-bit (x444) — native · DeckLink v210 output: reduced once to 4:2:2 (halfband) · software decode")
        XCTAssertEqual(ChromaReadout.text(carried: x420, source: .declared(.c420), reason: nil, note: nil),
                       "4:2:0 10-bit (x420) — native")
    }
}
