//
//  ReferenceTransformTests.swift
//  ColorimetryModelTests
//
//  Colour S1 (docs/COLOR_MANAGEMENT_FINDINGS.md §6.11): BT.1886 from Lb / Lw, the per-display
//  calibration record, and the primaries conversion for a display calibrated to Rec.709.
//

import XCTest
@testable import ColorimetryModel

final class ReferenceTransformTests: XCTestCase {

    /// Lb = 0 is EXACTLY 2.4 — not approximately: a = 1, b = 0, and the drive equals pow(V, 2.4)
    /// bit for bit. S1 prediction 3 rests on this.
    func testBlackZeroIsExactlyGamma24() {
        let c = BT1886(whiteNits: 100, blackNits: 0)
        XCTAssertEqual(c.a, 1)
        XCTAssertEqual(c.b, 0)
        XCTAssertTrue(c.isPurePower)
        for i in 0...1023 {
            let v = Double(i) / 1023
            XCTAssertEqual(c.drive(v), pow(v, 2.4), "V = \(v)")
        }
        // Lw alone does not change the shape.
        XCTAssertEqual(BT1886(whiteNits: 250, blackNits: 0), c)
    }

    /// The table in §6.11, to 5 decimals.
    func testTheTableInTheFindingsDocument() {
        let vs = [0.02, 0.05, 0.10, 0.20, 0.50, 0.90, 1.00]
        let rows: [(Double, [Double])] = [
            (0.00, [0.00008, 0.00075, 0.00398, 0.02101, 0.18946, 0.77657, 1]),
            (0.05, [0.00073, 0.00259, 0.00812, 0.03005, 0.20879, 0.78522, 1]),
            (0.10, [0.00100, 0.00332, 0.00965, 0.03323, 0.21526, 0.78806, 1]),
        ]
        for (lb, expected) in rows {
            let c = BT1886(whiteNits: 100, blackNits: lb)
            for (v, e) in zip(vs, expected) {
                XCTAssertEqual(c.drive(v), e, accuracy: 0.000005, "Lb \(lb), V \(v)")
            }
        }
    }

    /// Black maps to 0 and white to 1 whatever Lb is; sub-black is clamped, never NaN.
    func testEndpointsAndSubBlack() {
        for lb in [0.0, 0.05, 0.1, 1, 10] {
            let c = BT1886(whiteNits: 100, blackNits: lb)
            XCTAssertEqual(c.drive(0), 0, accuracy: 1e-12)
            XCTAssertEqual(c.drive(1), 1, accuracy: 1e-12)
            XCTAssertEqual(c.drive(-0.05), 0)
            XCTAssertFalse(c.drive(1.0009765625).isNaN)   // the legal ramp's superwhite peak
        }
    }

    /// A raised black lifts the shadows and leaves black and white where they were.
    func testRaisedBlackLiftsShadows() {
        let flat = BT1886(whiteNits: 100, blackNits: 0)
        let lifted = BT1886(whiteNits: 100, blackNits: 0.1)
        for v in stride(from: 0.01, through: 0.99, by: 0.01) {
            XCTAssertGreaterThan(lifted.drive(v), flat.drive(v), "V \(v)")
        }
    }

    /// Nonsense in a text field never builds a curve: it falls back field by field.
    func testSanitizing() {
        XCTAssertEqual(DisplayCalibration(calibrated: true, whiteNits: -5, blackNits: 0).sanitized.whiteNits, 100)
        XCTAssertEqual(DisplayCalibration(calibrated: true, whiteNits: .nan, blackNits: 0).sanitized.whiteNits, 100)
        XCTAssertEqual(DisplayCalibration(calibrated: false, whiteNits: 100, blackNits: 100).sanitized.blackNits, 0)
        XCTAssertEqual(DisplayCalibration(calibrated: false, whiteNits: 100, blackNits: -1).sanitized.blackNits, 0)
        XCTAssertEqual(DisplayCalibration(calibrated: false, whiteNits: 120, blackNits: 0.05).sanitized,
                       DisplayCalibration(calibrated: false, whiteNits: 120, blackNits: 0.05))
        XCTAssertEqual(DisplayCalibration.standard,
                       DisplayCalibration(calibrated: false, whiteNits: 100, blackNits: 0))
    }

    /// Round trip through JSON, which is how the store persists it.
    func testCodableRoundTrip() throws {
        let c = DisplayCalibration(calibrated: true, whiteNits: 120, blackNits: 0.05)
        let back = try JSONDecoder().decode(DisplayCalibration.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    /// The 2020 → 709 matrix against ITU-R BT.2087's published values, and white preserved.
    func testRec2020ToRec709MatchesBT2087() throws {
        let m = try XCTUnwrap(ReferenceGamut.toRec709(fromPrimariesCode: 9))
        let bt2087: [[Double]] = [[1.6605, -0.5876, -0.0728],
                                  [-0.1246, 1.1329, -0.0083],
                                  [-0.0182, -0.1006, 1.1187]]
        for r in 0..<3 { for c in 0..<3 { XCTAssertEqual(m[r][c], bt2087[r][c], accuracy: 0.0001) } }
        let white = ReferenceGamut.apply(m, [1, 1, 1])
        for w in white { XCTAssertEqual(w, 1, accuracy: 1e-9) }
    }

    /// P3-D65 → 709: white preserved, and the shared blue primary maps onto 709 blue's row pattern.
    func testP3ToRec709PreservesWhite() throws {
        let m = try XCTUnwrap(ReferenceGamut.toRec709(fromPrimariesCode: 12))
        XCTAssertEqual(m[0][0], 1.2249, accuracy: 0.0001)
        XCTAssertEqual(m[0][1], -0.2249, accuracy: 0.0001)
        for w in ReferenceGamut.apply(m, [1, 1, 1]) { XCTAssertEqual(w, 1, accuracy: 1e-9) }
    }

    /// Colour S3: every primaries code in the table converts; 709, absent and unknown do not.
    func testEveryNon709TableEntryConverts() {
        for code: Int? in [nil, 1, 2, 4, 7, 10, 22, 255] {
            XCTAssertNil(ReferenceGamut.toRec709(fromPrimariesCode: code), "code \(String(describing: code))")
        }
        for code in [5, 6, 9, 11, 12] {
            guard let m = ReferenceGamut.toRec709(fromPrimariesCode: code) else {
                return XCTFail("code \(code) has no conversion")
            }
            // White preserved: every rendered set is on D65.
            for w in ReferenceGamut.apply(m, [1, 1, 1]) { XCTAssertEqual(w, 1, accuracy: 1e-9, "code \(code)") }
        }
    }
}
