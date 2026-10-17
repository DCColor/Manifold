//
//  ProResFrameHeaderTests.swift
//  ColorimetryModelTests
//
//  The colour a ProRes frame states (RDD 36 frame header), read from a packet for the VideoToolbox route so the
//  container check and the tagging see what libav's decoder would report (docs/BUGS.md, *ProRes MXF decodes in
//  software*).
//

import XCTest
@testable import ColorimetryModel

final class ProResFrameHeaderTests: XCTestCase {

    /// An `icpf` box and a 148-byte frame header (the size Apple's and libav's encoders write when both matrices
    /// are present), with the colour fields set.
    private func frame(primaries: UInt8, transfer: UInt8, matrix: UInt8, headerSize: Int = 148,
                       length: Int? = nil) -> [UInt8] {
        let total = length ?? (8 + headerSize + 16)
        var b = [UInt8](repeating: 0, count: total)
        let size = UInt32(total)
        b[0] = UInt8(size >> 24); b[1] = UInt8((size >> 16) & 0xff); b[2] = UInt8((size >> 8) & 0xff); b[3] = UInt8(size & 0xff)
        b[4] = UInt8(ascii: "i"); b[5] = UInt8(ascii: "c"); b[6] = UInt8(ascii: "p"); b[7] = UInt8(ascii: "f")
        if total > 9 { b[8] = UInt8(headerSize >> 8); b[9] = UInt8(headerSize & 0xff) }
        if total > 24 { b[22] = primaries; b[23] = transfer; b[24] = matrix }
        return b
    }

    private func read(_ bytes: [UInt8]) -> (primaries: Int, transfer: Int, matrix: Int)? {
        bytes.withUnsafeBytes { ProResFrameHeader.color($0) }
    }

    func testTheThreeCodesAreTheFrameHeadersBytes14To16() {
        let c = read(frame(primaries: 9, transfer: 16, matrix: 9))
        XCTAssertEqual(c?.primaries, 9)
        XCTAssertEqual(c?.transfer, 16)
        XCTAssertEqual(c?.matrix, 9)
    }

    /// Unspecified is passed on as stated, not replaced: the policy decides what an unstated axis means.
    func testUnspecifiedIsPassedOnAsStated() {
        let c = read(frame(primaries: 2, transfer: 0, matrix: 2))
        XCTAssertEqual(c?.primaries, 2)
        XCTAssertEqual(c?.transfer, 0)
        XCTAssertEqual(c?.matrix, 2)
    }

    func testNoIcpfBoxIsNotAProResFrame() {
        var b = frame(primaries: 1, transfer: 1, matrix: 1)
        b[4] = UInt8(ascii: "x")
        XCTAssertNil(read(b))
    }

    /// libav refuses anything under 28 bytes; so does this.
    func testUnderLibavsFloorIsNotAProResFrame() {
        XCTAssertNil(read(frame(primaries: 1, transfer: 1, matrix: 1, length: 27)))
    }

    func testAHeaderTooShortToReachTheColourFieldsIsNil() {
        XCTAssertNil(read(frame(primaries: 1, transfer: 1, matrix: 1, headerSize: 16)))
    }

    func testAHeaderLongerThanThePacketIsNil() {
        XCTAssertNil(read(frame(primaries: 1, transfer: 1, matrix: 1, headerSize: 148, length: 100)))
    }
}
