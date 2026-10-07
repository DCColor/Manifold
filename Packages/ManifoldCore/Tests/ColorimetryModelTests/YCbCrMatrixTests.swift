//
//  YCbCrMatrixTests.swift
//  ColorimetryModelTests
//
//  The CICP matrix code → YCbCr matrix table the renderer's scope maths and DeckLink encode, the scope
//  header label and the live buffer tags share. Matrix 5 (BT.470BG) was decoded and scoped as 709
//  until 2026-10-07 (docs/BUGS.md).
//

import XCTest
@testable import ColorimetryModel

final class YCbCrMatrixTests: XCTestCase {

    func testMatrixFiveIsTheSameMatrixAsSix() {
        XCTAssertEqual(YCbCrMatrix(cicp: 5), .rec601)
        XCTAssertEqual(YCbCrMatrix(cicp: 5), YCbCrMatrix(cicp: 6))
        XCTAssertEqual(YCbCrMatrix(cicp: 5).kr, YCbCrMatrix(cicp: 6).kr)
        XCTAssertEqual(YCbCrMatrix(cicp: 5).kb, YCbCrMatrix(cicp: 6).kb)
        XCTAssertEqual(YCbCrMatrix(cicp: 5).label, "Rec. 601")
    }

    /// Every other code gives exactly what the three tables it replaced gave: 9 → 2020, 6 → 601,
    /// everything else → 709.
    func testEveryOtherCodeIsUnchanged() {
        XCTAssertEqual(YCbCrMatrix(cicp: 1), .rec709)
        XCTAssertEqual(YCbCrMatrix(cicp: 6), .rec601)
        XCTAssertEqual(YCbCrMatrix(cicp: 9), .rec2020)
        for code: Int? in [nil, 0, 2, 3, 4, 7, 8, 10, 11, 12, 13, 14, 255] {
            XCTAssertEqual(YCbCrMatrix(cicp: code), .rec709, "code \(String(describing: code))")
        }
    }

    /// Bit-identical to the Float literals the renderer used before, so codes 1, 6 and 9 cannot
    /// move a single scope trace or DeckLink sample.
    func testCoefficientsAreTheRendererLiterals() {
        let expected: [(YCbCrMatrix, Float, Float, String)] = [
            (.rec709, 0.2126, 0.0722, "Rec. 709"),
            (.rec601, 0.299, 0.114, "Rec. 601"),
            (.rec2020, 0.2627, 0.0593, "Rec. 2020"),
        ]
        for (m, kr, kb, label) in expected {
            XCTAssertEqual(m.kr.bitPattern, kr.bitPattern, "\(m)")
            XCTAssertEqual(m.kb.bitPattern, kb.bitPattern, "\(m)")
            XCTAssertEqual(m.label, label)
        }
    }
}
