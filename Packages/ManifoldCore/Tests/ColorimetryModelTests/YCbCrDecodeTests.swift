//
//  YCbCrDecodeTests.swift
//  ColorimetryModelTests
//
//  The two 601 defects colour S3 found (docs/COLOR_MANAGEMENT_FINDINGS.md §6.11): the decode coefficients
//  the shader multiplies by, and the one reading of a CoreVideo YCbCrMatrix tag.
//

import XCTest
@testable import ColorimetryModel

final class YCbCrDecodeTests: XCTestCase {

    /// Every set is the UNSCALED derivation from Kr / Kb (the shader expands chroma range itself), to the
    /// 4 places the literals are written to.
    func testCoefficientsAreTheUnscaledDerivation() {
        for m in [YCbCrMatrix.rec709, .rec601, .rec2020] {
            let kr = Double(m.kr), kb = Double(m.kb), kg = 1 - kr - kb
            let k = m.decodeCoefficients
            XCTAssertEqual(Double(k.a), 2 * (1 - kr), accuracy: 6e-5, "\(m) a")
            XCTAssertEqual(Double(k.d), 2 * (1 - kb), accuracy: 6e-5, "\(m) d")
            XCTAssertEqual(Double(k.b), 2 * kb * (1 - kb) / kg, accuracy: 6e-5, "\(m) b")
            XCTAssertEqual(Double(k.c), 2 * kr * (1 - kr) / kg, accuracy: 6e-5, "\(m) c")
        }
    }

    /// 709 and 2020 are bit-identical to the literals the shader used before the fix.
    func test709And2020AreUnchanged() {
        let a = YCbCrMatrix.rec709.decodeCoefficients, b = YCbCrMatrix.rec2020.decodeCoefficients
        XCTAssertEqual([a.a, a.b, a.c, a.d], [1.5748, 0.1873, 0.4681, 1.8556] as [Float])
        XCTAssertEqual([b.a, b.b, b.c, b.d], [1.4746, 0.1646, 0.5714, 1.8814] as [Float])
    }

    /// The old 601 set was the new one × 255/224: the double expansion, stated as a number.
    func testOld601SetWasDoublyScaled() {
        let k = YCbCrMatrix.rec601.decodeCoefficients
        for (old, new) in zip([1.5960, 0.3917, 0.8129, 2.0172], [k.a, k.b, k.c, k.d]) {
            XCTAssertEqual(old / Double(new), 255.0 / 224.0, accuracy: 2e-4)
        }
    }

    func testCoreVideoTagReading() {
        XCTAssertEqual(YCbCrMatrix.cicpCode(forCoreVideo: "ITU_R_709_2"), 1)
        XCTAssertEqual(YCbCrMatrix.cicpCode(forCoreVideo: "ITU_R_601_4"), 6)
        XCTAssertEqual(YCbCrMatrix.cicpCode(forCoreVideo: "ITU_R_2020"), 9)
        XCTAssertEqual(YCbCrMatrix.cicpCode(forCoreVideo: "SMPTE_240M_1995"), 7)
        // CoreMedia's spelling for a code it has no constant for — measured on a BT.470BG file.
        XCTAssertEqual(YCbCrMatrix.cicpCode(forCoreVideo: "YCbCrMatrix#5"), 5)
        XCTAssertEqual(YCbCrMatrix(cicp: YCbCrMatrix.cicpCode(forCoreVideo: "YCbCrMatrix#5")), .rec601)
        // SMPTE_C is a primaries constant; the old file map used it as the 601 matrix key.
        XCTAssertNil(YCbCrMatrix.cicpCode(forCoreVideo: "SMPTE_C"))
        for bad in [nil, "", "YCbCrMatrix#", "YCbCrMatrix#x", "YCbCrMatrix#999", "garbage"] as [String?] {
            XCTAssertNil(YCbCrMatrix.cicpCode(forCoreVideo: bad), String(describing: bad))
        }
    }
}
