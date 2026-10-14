//
//  PictureCodesTests.swift
//  ColorimetryModelTests
//
//  Colour S6, L2 (COLOR_MANAGEMENT_FINDINGS.md §6.11, D3): source codes and picture codes are identical without a
//  LUT and at Same as Source; a stated output space replaces every axis of the picture and none of the source.
//

import XCTest
@testable import ColorimetryModel

final class PictureCodesTests: XCTestCase {

    private let rec709Source: (primaries: Int?, transfer: Int?, matrix: Int?) = (1, 1, 1)

    private func assertCodes(_ r: (primaries: Int?, transfer: Int?, matrix: Int?, statedByLUT: Bool),
                             _ p: Int?, _ t: Int?, _ m: Int?, stated: Bool,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.primaries, p, "primaries", file: file, line: line)
        XCTAssertEqual(r.transfer, t, "transfer", file: file, line: line)
        XCTAssertEqual(r.matrix, m, "matrix", file: file, line: line)
        XCTAssertEqual(r.statedByLUT, stated, "statedByLUT", file: file, line: line)
    }

    /// No LUT: the source codes, whatever output space is held — every preset and a Custom.
    func testNoLUTIsAlwaysTheSource() {
        for o in ColorimetryOverride.allCases + [.custom(primaries: 9, transfer: 1, matrix: 9)] {
            assertCodes(PictureCodes.resolve(source: rec709Source, lutLoaded: false, lutOutput: o), 1, 1, 1, stated: false)
        }
        // An untagged source stays untagged: nil is not filled in here.
        assertCodes(PictureCodes.resolve(source: (nil, nil, nil), lutLoaded: false, lutOutput: .rec2020PQ),
                    nil, nil, nil, stated: false)
    }

    /// Same as Source (`.auto`) with a LUT: the source codes, not stated.
    func testSameAsSourceIsTheSource() {
        assertCodes(PictureCodes.resolve(source: (9, 1, 9), lutLoaded: true, lutOutput: .auto), 9, 1, 9, stated: false)
        assertCodes(PictureCodes.resolve(source: (nil, 16, nil), lutLoaded: true, lutOutput: .auto), nil, 16, nil, stated: false)
    }

    /// P7's case: a 709 source, a LUT stated 2020 PQ → 9-16-9 on every axis.
    func testStatedPresetReplacesEveryAxis() {
        assertCodes(PictureCodes.resolve(source: rec709Source, lutLoaded: true, lutOutput: .rec2020PQ), 9, 16, 9, stated: true)
        // P3-D65 PQ carries a 709-class matrix, as the preset says: no axis is derived from another.
        assertCodes(PictureCodes.resolve(source: rec709Source, lutLoaded: true, lutOutput: .p3d65PQ), 12, 16, 1, stated: true)
        // A stated space applies over an untagged source too.
        assertCodes(PictureCodes.resolve(source: (nil, nil, nil), lutLoaded: true, lutOutput: .rec709), 1, 1, 1, stated: true)
    }

    /// Custom: a supported triple is stated as given; an unsupported one (PQ on 709 primaries) falls back to the source.
    func testCustomSupportedAndRefused() {
        assertCodes(PictureCodes.resolve(source: rec709Source, lutLoaded: true,
                                         lutOutput: .custom(primaries: 9, transfer: 1, matrix: 6)), 9, 1, 6, stated: true)
        assertCodes(PictureCodes.resolve(source: (5, 6, 5), lutLoaded: true,
                                         lutOutput: .custom(primaries: 1, transfer: 16, matrix: 1)), 5, 6, 5, stated: false)
    }

    func testOutputLabel() {
        XCTAssertEqual(PictureCodes.outputLabel(.auto), "Same as Source")
        XCTAssertEqual(PictureCodes.outputLabel(.rec2020PQ), "Rec.2020 PQ (HDR10)")
        XCTAssertEqual(PictureCodes.outputLabel(.custom(primaries: 9, transfer: 1, matrix: 9)), "Custom 9·1·9")
    }
}
