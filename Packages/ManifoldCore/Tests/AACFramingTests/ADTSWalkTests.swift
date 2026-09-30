import XCTest
@testable import AACFraming

final class ADTSWalkTests: XCTestCase {

    /// One ADTS frame: LC, 48 kHz (index 3), stereo, `body` bytes of payload, CRC when asked.
    private func frame(body: Int, crc: Bool = false, fill: UInt8 = 0xA5, rawBlocks: UInt8 = 0) -> [UInt8] {
        let header = crc ? 9 : 7
        let len = header + body
        var h: [UInt8] = [0xFF, crc ? 0xF0 : 0xF1,
                          (1 << 6) | (3 << 2) | 0,          // profile LC−1, index 3, ch bit 2 = 0
                          (2 << 6) | UInt8((len >> 11) & 0x03),
                          UInt8((len >> 3) & 0xFF),
                          UInt8((len & 0x07) << 5) | 0x1F,
                          0xFC | rawBlocks]
        if crc { h += [0x12, 0x34] }
        return h + [UInt8](repeating: fill, count: body)
    }

    private func walk(_ b: [UInt8]) -> ADTSWalk.Result? { b.withUnsafeBytes { ADTSWalk.walk($0) } }

    func testOneFrame() throws {
        let r = try XCTUnwrap(walk(frame(body: 420)))
        XCTAssertEqual(r.frames.count, 1)
        XCTAssertNil(r.stop)
        XCTAssertEqual(r.leftoverBytes, 0)
        let f = r.frames[0]
        XCTAssertEqual(f.length, 427)
        XCTAssertEqual(f.headerBytes, 7)
        XCTAssertEqual(f.payloadOffset, 7)
        XCTAssertEqual(f.payloadLength, 420)
        XCTAssertEqual(f.profileMinusOne, 1)
        XCTAssertEqual(f.samplingIndex, 3)
        XCTAssertEqual(f.channelConfig, 2)
        XCTAssertEqual(f.rawDataBlocks, 0)
    }

    func testTwoSixAndTwelveFramesPerPES() throws {
        for n in [2, 6, 12] {
            let b = (0..<n).flatMap { frame(body: 100 + $0, fill: UInt8($0)) }
            let r = try XCTUnwrap(walk(b))
            XCTAssertEqual(r.frames.count, n, "\(n) frames")
            XCTAssertNil(r.stop)
            XCTAssertEqual(r.frames.map(\.payloadLength), (0..<n).map { 100 + $0 })
            // Each payload starts on its own bytes.
            for (k, f) in r.frames.enumerated() { XCTAssertEqual(b[f.payloadOffset], UInt8(k)) }
        }
    }

    func testMixedLengthsAndSilenceSizedFrames() throws {
        // ffmpeg's grouping of digital silence: 13 tiny frames, then programme-sized ones.
        let sizes = [6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 420, 380, 1500]
        let r = try XCTUnwrap(walk(sizes.flatMap { frame(body: $0) }))
        XCTAssertEqual(r.frames.map(\.payloadLength), sizes)
        XCTAssertNil(r.stop)
    }

    func testCRCHeaders() throws {
        let r = try XCTUnwrap(walk(frame(body: 200, crc: true) + frame(body: 50, crc: true)))
        XCTAssertEqual(r.frames.map(\.headerBytes), [9, 9])
        XCTAssertEqual(r.frames.map(\.payloadLength), [200, 50])
        XCTAssertEqual(r.frames[1].offset, 209)
    }

    func testTruncatedLastFrame() throws {
        let b = frame(body: 300) + frame(body: 300).dropLast(40)
        let r = try XCTUnwrap(walk(Array(b)))
        XCTAssertEqual(r.frames.count, 1)
        XCTAssertEqual(r.leftoverBytes, 267)
        XCTAssertEqual(r.stop, .badLength(declared: 307, available: 267))
    }

    func testGarbageAfterAValidFrame() throws {
        let r = try XCTUnwrap(walk(frame(body: 64) + [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]))
        XCTAssertEqual(r.frames.count, 1)
        XCTAssertEqual(r.leftoverBytes, 8)
        XCTAssertEqual(r.stop, .noSyncword)
    }

    func testShortTail() throws {
        let r = try XCTUnwrap(walk(frame(body: 64) + [0xFF, 0xF1, 0x50]))
        XCTAssertEqual(r.frames.count, 1)
        XCTAssertEqual(r.leftoverBytes, 3)
        XCTAssertEqual(r.stop, .shortHeader)
    }

    func testLengthShorterThanHeaderStops() throws {
        var bad = frame(body: 10)
        bad[3] &= 0xFC; bad[4] = 0; bad[5] = (5 << 5) | 0x1F   // declares 5 bytes, < 7
        let r = try XCTUnwrap(walk(frame(body: 20) + bad))
        XCTAssertEqual(r.frames.count, 1)
        XCTAssertEqual(r.stop, .badLength(declared: 5, available: 17))
    }

    func testRawAACAndLATMAreNotWalked() {
        XCTAssertNil(walk([0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C, 0x00, 0x00]))   // raw AAC
        XCTAssertNil(walk([0x56, 0xE0, 0x2A, 0x20, 0x00, 0x11, 0x90, 0x00]))   // LOAS/LATM syncword
        XCTAssertNil(walk([0xFF, 0xF1, 0x50]))                                 // too short to be ADTS
        XCTAssertNil(walk([]))
    }

    func testRawDataBlocksFieldIsReported() throws {
        let r = try XCTUnwrap(walk(frame(body: 900, rawBlocks: 1)))
        XCTAssertEqual(r.frames[0].rawDataBlocks, 1)
    }
}
