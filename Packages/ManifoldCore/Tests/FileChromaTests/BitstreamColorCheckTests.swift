//
//  BitstreamColorCheckTests.swift
//  FileChromaTests
//
//  Colour S3: a file's container colour tags against the SPS in its avcC / hvcC. The avcC boxes are the
//  real ones from S0's fixtures (`build/colour-s0/fixtures/`), read through AVFoundation.
//

import XCTest
import SPSColor
@testable import FileChroma

final class BitstreamColorCheckTests: XCTestCase {

    private func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// `caseg-colr2020-vui709-h264.mov`: `colr` 9-1-9 (CoreMedia reads ITU_R_2020 / ITU_R_709_2 / ITU_R_2020),
    /// SPS VUI 1 / 1 / 1.
    static let avcCCaseG: [UInt8] = [
        0x01, 0x64, 0x00, 0x28, 0xff, 0xe1, 0x00, 0x1d, 0x67, 0x64, 0x00, 0x28, 0xac, 0xd9, 0x40, 0x78, 0x02,
        0x27, 0xe5, 0x9a, 0x80, 0x80, 0x80, 0xa0, 0x00, 0x00, 0x03, 0x00, 0x20, 0x00, 0x00, 0x06, 0x41, 0xe3,
        0x06, 0x32, 0xc0, 0x01, 0x00, 0x05, 0x68, 0xef, 0x81, 0x6f, 0x2c, 0xfd, 0xf8, 0xf8, 0x00]

    /// `patches-9-14-9-h264.mov`: `colr` 9-14-9, which CoreMedia reads as 9-1-9; SPS VUI 9 / 14 / 9.
    static let avcC9149: [UInt8] = [
        0x01, 0x64, 0x00, 0x28, 0xff, 0xe1, 0x00, 0x1d, 0x67, 0x64, 0x00, 0x28, 0xac, 0xd9, 0x40, 0x78, 0x02,
        0x27, 0xe5, 0x9a, 0x84, 0x87, 0x04, 0xa0, 0x00, 0x00, 0x03, 0x00, 0x20, 0x00, 0x00, 0x06, 0x41, 0xe3,
        0x06, 0x32, 0xc0, 0x01, 0x00, 0x05, 0x68, 0xef, 0x81, 0x6f, 0x2c, 0xfd, 0xf8, 0xf8, 0x00]

    /// Case (g): primaries and matrix disagree, transfer agrees; the readout names both axes.
    func testCaseGDisagreesOnPrimariesAndMatrix() throws {
        let r = try XCTUnwrap(BitstreamColorCheck.check(codecType: fourCC("avc1"), atoms: ["avcC": Self.avcCCaseG],
                                                        container: (9, 1, 9)))
        XCTAssertEqual(r.bitstream.primaries, 1); XCTAssertEqual(r.bitstream.transfer, 1); XCTAssertEqual(r.bitstream.matrix, 1)
        XCTAssertEqual(r.disagreements, [.init(axis: .primaries, container: 9, bitstream: 1),
                                         .init(axis: .matrix, container: 9, bitstream: 1)])
        let line = try XCTUnwrap(r.readout)
        XCTAssertTrue(line.contains("container 9-1-9"), line)
        XCTAssertTrue(line.contains("avcC SPS"), line)
        XCTAssertTrue(line.contains("1-1-1"), line)
        XCTAssertTrue(r.logLine.contains("DISAGREE on primaries, matrix"), r.logLine)
    }

    /// CoreMedia respells 14 as 1: 9-1-9 against a 9-14-9 SPS is the same statement, not a disagreement.
    func testTransfer14RespelledAs1IsNotADisagreement() throws {
        let r = try XCTUnwrap(BitstreamColorCheck.check(codecType: fourCC("avc1"), atoms: ["avcC": Self.avcC9149],
                                                        container: (9, 1, 9)))
        XCTAssertEqual(r.bitstream.transfer, 14)
        XCTAssertEqual(r.disagreements, [])
        XCTAssertNil(r.readout)
        XCTAssertTrue(r.logLine.hasSuffix("— agree"), r.logLine)
    }

    func testEquivalencesAndSilence() {
        let sps = SPSColor(reach: .colourDescription, colourPrimaries: 6, transferCharacteristics: 6, matrixCoefficients: 5)
        // Transfer 1 vs 6 is one curve; matrix 6 vs 5 is one matrix; primaries 6 vs 6 agree.
        XCTAssertEqual(BitstreamColorCheck.compare(container: (6, 1, 6), bitstream: sps), [])
        // A container axis that says nothing is not a disagreement.
        XCTAssertEqual(BitstreamColorCheck.compare(container: (nil, nil, nil), bitstream: sps), [])
        // A bitstream that says nothing is not one either.
        XCTAssertEqual(BitstreamColorCheck.compare(container: (9, 16, 9), bitstream: .undeclared), [])
        // Unspecified (2) in the SPS is undeclared.
        let two = SPSColor(reach: .colourDescription, colourPrimaries: 2, transferCharacteristics: 2, matrixCoefficients: 2)
        XCTAssertEqual(BitstreamColorCheck.compare(container: (9, 16, 9), bitstream: two), [])
        // A real disagreement on the curve.
        let pq = SPSColor(reach: .colourDescription, colourPrimaries: 9, transferCharacteristics: 16, matrixCoefficients: 9)
        XCTAssertEqual(BitstreamColorCheck.compare(container: (9, 1, 9), bitstream: pq),
                       [.init(axis: .transfer, container: 1, bitstream: 16)])
    }

    /// Codecs whose bitstream the app does not read give no report — never a guess.
    func testOtherCodecsGiveNoReport() {
        XCTAssertNil(BitstreamColorCheck.check(codecType: fourCC("apch"), atoms: [:], container: (9, 1, 9)))
        XCTAssertNil(BitstreamColorCheck.check(codecType: fourCC("avc1"), atoms: [:], container: (9, 1, 9)))
        XCTAssertNil(BitstreamColorCheck.check(codecType: fourCC("hvc1"), atoms: ["hvcC": [0x01]], container: (9, 1, 9)))
    }
}
