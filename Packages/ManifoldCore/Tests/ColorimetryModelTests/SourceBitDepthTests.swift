//
//  SourceBitDepthTests.swift
//  ColorimetryModelTests
//
//  The per-frame "8-bit source" flag (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, *8-bit sources mapped
//  exactly ×4*): only 8 bits on both planes flags, the flag lives on the buffer, a pooled buffer is
//  cleared as well as set, and a promote carries it.
//

import XCTest
import CoreVideo
@testable import ColorimetryModel

final class SourceBitDepthTests: XCTestCase {

    private func buffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &pb)
        return pb!
    }

    func testOnlyEightBitsOnBothPlanes() {
        XCTAssertTrue(SourceBitDepth.isEightBit(luma: 8, chroma: 8))
        XCTAssertFalse(SourceBitDepth.isEightBit(luma: 10, chroma: 10))
        XCTAssertFalse(SourceBitDepth.isEightBit(luma: 8, chroma: 10))
        XCTAssertFalse(SourceBitDepth.isEightBit(luma: 10, chroma: 8))
    }

    /// Absent means not 8-bit; marking false clears a previous frame's flag on a recycled buffer.
    func testMarkSetsAndClears() {
        let pb = buffer()
        XCTAssertFalse(SourceBitDepth.isEightBit(pb))
        SourceBitDepth.mark(pb, eightBit: true)
        XCTAssertTrue(SourceBitDepth.isEightBit(pb))
        SourceBitDepth.mark(pb, eightBit: false)
        XCTAssertFalse(SourceBitDepth.isEightBit(pb))
    }

    func testCarryFollowsTheSource() {
        let source = buffer(), destination = buffer()
        SourceBitDepth.mark(destination, eightBit: true)     // a recycled destination
        SourceBitDepth.carry(from: source, to: destination)
        XCTAssertFalse(SourceBitDepth.isEightBit(destination))
        SourceBitDepth.mark(source, eightBit: true)
        SourceBitDepth.carry(from: source, to: destination)
        XCTAssertTrue(SourceBitDepth.isEightBit(destination))
    }
}
