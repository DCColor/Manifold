//
//  ColorimetryTableTests.swift
//  ColorimetryModelTests
//
//  Colour S3 (docs/COLOR_MANAGEMENT_FINDINGS.md §6.11): the one primaries / curve / matrix table. Each
//  axis on its own; the pairs that worked before S3 still build exactly the same attachments; every pair
//  S0 found falling back to 709 gets its own primaries; the CIE scope's matrices are the shader's old ones.
//

import XCTest
import CoreVideo
@testable import ColorimetryModel

final class ColorimetryTableTests: XCTestCase {

    private func attachments(_ p: Int?, _ t: Int?, _ m: Int?) -> [String] {
        let a = ColorimetryTable.layerAttachments(primaries: p, transfer: t, matrix: m).coreVideo
        return [a.primaries as String, a.transfer as String, a.matrix as String]
    }

    /// The five pairs `makeColorSpace` enumerated before S3 build the attachments its arms did.
    func testPairsThatWorkedBeforeS3AreUnchanged() {
        let p709 = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        let t709 = kCVImageBufferTransferFunction_ITU_R_709_2 as String
        let m709 = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        let p2020 = kCVImageBufferColorPrimaries_ITU_R_2020 as String
        let m2020 = kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
        XCTAssertEqual(attachments(1, 1, 1), [p709, t709, m709])
        XCTAssertEqual(attachments(nil, nil, nil), [p709, t709, m709])
        XCTAssertEqual(attachments(12, 1, 1), [kCVImageBufferColorPrimaries_P3_D65 as String, t709, m709])
        XCTAssertEqual(attachments(9, 16, 9), [p2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String, m2020])
        XCTAssertEqual(attachments(9, 18, 9), [p2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String, m2020])
        XCTAssertEqual(attachments(12, 16, 1),
                       [kCVImageBufferColorPrimaries_P3_D65 as String, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String, m709])
    }

    /// Every combination S0 found falling back to 709 gets its own primaries, with the 709 curve.
    func testS0FallbacksGetTheirOwnPrimaries() {
        let t709 = kCVImageBufferTransferFunction_ITU_R_709_2 as String
        XCTAssertEqual(attachments(9, 1, 9)[0], kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        XCTAssertEqual(attachments(9, 14, 9)[0], kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        XCTAssertEqual(attachments(11, 1, 1)[0], kCVImageBufferColorPrimaries_DCI_P3 as String)
        XCTAssertEqual(attachments(6, 6, 6)[0], kCVImageBufferColorPrimaries_SMPTE_C as String)
        XCTAssertEqual(attachments(5, 6, 5)[0], kCVImageBufferColorPrimaries_EBU_3213 as String)
        for (p, t, m) in [(9, 1, 9), (9, 14, 9), (11, 1, 1), (6, 6, 6), (5, 6, 5)] {
            XCTAssertEqual(attachments(p, t, m)[1], t709, "\(p)-\(t)-\(m)")
        }
    }

    /// (9, 14) is the 709 curve: it builds exactly (9, 1)'s attachments, so a Rec.2020 SDR override
    /// and a declared 9-1-9 stream get the same layer colorspace.
    func testTransfer14BuildsTheSameSpaceAsTransfer1() {
        XCTAssertEqual(attachments(9, 14, 9), attachments(9, 1, 9))
        XCTAssertEqual(attachments(9, 15, 9), attachments(9, 1, 9))
        XCTAssertEqual(attachments(1, 14, 1), attachments(1, 1, 1))
        XCTAssertEqual(attachments(12, 14, 1), attachments(12, 1, 1))
    }

    /// PQ / HLG on primaries CoreVideo has no HDR space for keeps the pre-S3 709 SDR set, and says so.
    func testHDROnUnsupportedPrimariesKeepsThePreS3SpaceAndSaysSo() {
        for (p, t): (Int?, Int) in [(nil, 16), (1, 16), (1, 18), (11, 16), (6, 18), (5, 16)] {
            let a = ColorimetryTable.layerAttachments(primaries: p, transfer: t, matrix: 9)
            XCTAssertNotNil(a.hdrFallback, "\(String(describing: p))-\(t)")
            XCTAssertEqual(attachments(p, t, 9), attachments(1, 1, 1), "\(String(describing: p))-\(t)")
        }
        for (p, t) in [(9, 16), (9, 18), (12, 16), (12, 18)] {
            XCTAssertNil(ColorimetryTable.layerAttachments(primaries: p, transfer: t, matrix: 9).hdrFallback)
        }
    }

    /// Each axis on its own: the matrix code never moves the primaries or the curve, and vice versa.
    func testAxesAreIndependent() {
        for m in [nil, 1, 5, 6, 9] as [Int?] {
            let a = ColorimetryTable.layerAttachments(primaries: 9, transfer: 1, matrix: m)
            XCTAssertEqual(a.primaries, .rec2020)
            XCTAssertEqual(a.curve, .bt709)
            XCTAssertEqual(a.matrix, YCbCrMatrix(cicp: m))
        }
    }

    /// Code 11 is drawn as DCI-P3 Bradford-adapted to D65 — the primaries S0 read out of CoreVideo's
    /// profile, to 4 decimals: R (0.6807, 0.3189) G (0.2812, 0.6742) B (0.1488, 0.0577).
    func testDCIP3IsAdaptedToD65AsCoreVideoBuildsIt() {
        let r = ColorPrimaries.dciP3.rendered
        XCTAssertEqual(r.red.x, 0.6807, accuracy: 0.0001);   XCTAssertEqual(r.red.y, 0.3189, accuracy: 0.0001)
        XCTAssertEqual(r.green.x, 0.2812, accuracy: 0.0001); XCTAssertEqual(r.green.y, 0.6742, accuracy: 0.0001)
        XCTAssertEqual(r.blue.x, 0.1488, accuracy: 0.0001);  XCTAssertEqual(r.blue.y, 0.0577, accuracy: 0.0001)
        XCTAssertEqual(r.white, PrimariesSet.d65)
        XCTAssertEqual(ColorPrimaries.dciP3.renderedName, "DCI-P3 adapted to D65")
        // Every other entry is already on D65 and is not moved.
        for p in ColorPrimaries.allCases where p != .dciP3 { XCTAssertEqual(p.rendered, p.published, "\(p)") }
    }

    /// The CIE scope's RGB→XYZ matrices, now from the table, against the ones the shader hardcoded before
    /// S3: P3 and 2020 to ~1e-6; 709 to 3e-4 (the published 709 matrix is a rounded one: worst cell Z_b,
    /// 0.95053 vs 0.95030 — about 1e-5 in u'v', far below one histogram bin).
    func testCIEMatricesMatchTheShadersPreviousOnes() {
        func check(_ p: ColorPrimaries, _ rows: [[Double]], _ tol: Double) {
            let m = p.rendered.rgbToXYZ
            for r in 0..<3 { for c in 0..<3 { XCTAssertEqual(m[r][c], rows[r][c], accuracy: tol, "\(p) [\(r)][\(c)]") } }
        }
        check(.rec2020, [[0.6369580, 0.1446169, 0.1688809], [0.2627002, 0.6779981, 0.0593017],
                         [0.0000000, 0.0280727, 1.0609851]], 1e-6)
        check(.p3D65, [[0.4865709, 0.2656677, 0.1982173], [0.2289746, 0.6917385, 0.0792869],
                       [0.0000000, 0.0451134, 1.0439444]], 1e-6)
        check(.rec709, [[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750],
                        [0.0193339, 0.1191920, 0.9503041]], 3e-4)
    }

    func testCodesAndFallback() {
        for p in ColorPrimaries.allCases { XCTAssertEqual(ColorPrimaries(cicp: p.cicp), p) }
        for code: Int? in [nil, 0, 2, 3, 4, 7, 8, 10, 22, 255] {
            XCTAssertNil(ColorPrimaries(cicp: code)); XCTAssertEqual(ColorPrimaries.resolve(code), .rec709)
        }
        XCTAssertEqual(ScopeCurve(transferCode: 13), .srgb)
        XCTAssertEqual(ScopeCurve(transferCode: 14), .power24)
        XCTAssertEqual(ScopeCurve(transferCode: 16), .pq)
        XCTAssertEqual(ScopeCurve(transferCode: nil), .power24)
    }

    /// The readout names transfer 14 (it printed "—" before S3).
    func testNames() {
        XCTAssertEqual(ColorimetryTable.transferName(forCode: 14), "Rec. 2020 SDR")
        XCTAssertEqual(ColorimetryTable.transferName(forCode: 1), "Rec. 709")
        XCTAssertEqual(ColorimetryTable.primariesName(forCode: 11), "DCI-P3")
        XCTAssertEqual(ColorimetryTable.primariesName(forCode: 6), "SMPTE-C")
        XCTAssertEqual(ColorimetryTable.primariesName(forCode: 10), "ST 428-1")
        XCTAssertEqual(ColorimetryTable.primariesName(forCode: 2), "—")
    }
}
