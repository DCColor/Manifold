import XCTest
@testable import FileScan

/// docs/INTERLACED_FINDINGS.md §14, I4: the window's field views read only the rows they say they read.
final class FieldViewTests: XCTestCase {

    private func scan(_ interlaced: Bool?, order: FieldOrder? = .topFirst, fields: Bool = false) -> SourceScan {
        guard let interlaced else { return .notRead }
        let b = ScanReading(interlaced: interlaced, fieldOrder: interlaced ? order : nil,
                            scanSource: fields ? "HEVC field_seq_flag" : "ProRes frame header", detail: "test",
                            picturesAreFields: fields)
        return SourceScan.resolve(container: nil, bitstream: b)
    }

    func testOfferedOnlyForWovenInterlaced() {
        XCTAssertTrue(FieldView.offered(scan(true)))
        XCTAssertTrue(FieldView.offered(scan(true, order: .bottomFirst)))
        XCTAssertTrue(FieldView.offered(scan(true, order: nil)))
        XCTAssertFalse(FieldView.offered(scan(true, fields: true)))
        XCTAssertFalse(FieldView.offered(scan(false)))
        XCTAssertFalse(FieldView.offered(scan(nil)))
    }

    /// Field 1 is the first field in time: the top rows on TFF, the bottom rows on BFF, the top rows when no order is stated.
    func testFieldOneIsTheFirstFieldInTime() {
        XCTAssertEqual(FieldView.field1.parity(.topFirst), 0)
        XCTAssertEqual(FieldView.field2.parity(.topFirst), 1)
        XCTAssertEqual(FieldView.field1.parity(.bottomFirst), 1)
        XCTAssertEqual(FieldView.field2.parity(.bottomFirst), 0)
        XCTAssertEqual(FieldView.deinterlace.parity(.bottomFirst), 1)
        XCTAssertEqual(FieldView.field1.parity(nil), 0)
        XCTAssertNil(FieldView.weave.parity(.topFirst))
    }

    func testWeaveReadsEachRowItself() {
        for y in 0..<1080 {
            XCTAssertEqual(FieldView.weave.rows(outputRow: y, height: 1080, order: .bottomFirst),
                           FieldView.Rows(rowA: y, rowB: y, weightB: 0))
        }
    }

    /// Every output row of a field view reads one stored row of that field, each stored row is read exactly twice, and
    /// every row of the field is used.
    func testFieldViewsRepeatEachLineOfOneField() {
        for order in [FieldOrder.topFirst, .bottomFirst, nil] {
            for view in [FieldView.field1, .field2] {
                let p = view.parity(order)!
                var uses = [Int: Int]()
                for y in 0..<1080 {
                    let r = view.rows(outputRow: y, height: 1080, order: order)
                    XCTAssertEqual(r.rowA, r.rowB); XCTAssertEqual(r.weightB, 0)
                    XCTAssertEqual(r.rowA & 1, p, "\(view) \(String(describing: order)) row \(y)")
                    XCTAssertEqual(r.rowA / 2, y / 2)
                    uses[r.rowA, default: 0] += 1
                }
                XCTAssertEqual(uses.count, 540)
                XCTAssertTrue(uses.values.allSatisfy { $0 == 2 })
            }
        }
    }

    /// Deinterlace keeps its field's rows and fills the others from the kept rows above and below, edges repeated.
    func testDeinterlaceKeepsOneFieldAndInterpolatesTheOther() {
        for order in [FieldOrder.topFirst, .bottomFirst] {
            let p = FieldView.deinterlace.parity(order)!
            for y in 0..<1080 {
                let r = FieldView.deinterlace.rows(outputRow: y, height: 1080, order: order)
                XCTAssertEqual(r.rowA & 1, p); XCTAssertEqual(r.rowB & 1, p)
                if y & 1 == p {
                    XCTAssertEqual(r, FieldView.Rows(rowA: y, rowB: y, weightB: 0))
                } else if y == 0 {
                    XCTAssertEqual(r, FieldView.Rows(rowA: 1, rowB: 1, weightB: 0))          // BFF top edge
                } else if y == 1079 {
                    XCTAssertEqual(r, FieldView.Rows(rowA: 1078, rowB: 1078, weightB: 0))    // TFF bottom edge
                } else {
                    XCTAssertEqual(r, FieldView.Rows(rowA: y - 1, rowB: y + 1, weightB: 0.5))
                }
            }
        }
    }

    /// An odd height stays inside the raster on both parities.
    func testOddHeightStaysInBounds() {
        for view in FieldView.allCases {
            for order in [FieldOrder.topFirst, .bottomFirst] {
                for y in 0..<5 {
                    let r = view.rows(outputRow: y, height: 5, order: order)
                    XCTAssertTrue((0..<5).contains(r.rowA) && (0..<5).contains(r.rowB), "\(view) \(order) \(y)")
                }
            }
        }
    }

    func testWordsSayWhichFieldAndDisplayOnly() {
        XCTAssertEqual(FieldView.field1.inspectorText(.bottomFirst), "Field 1 — bottom field, first in time (display only)")
        XCTAssertEqual(FieldView.field2.inspectorText(.bottomFirst), "Field 2 — top field, second in time (display only)")
        XCTAssertEqual(FieldView.field1.inspectorText(nil), "Field 1 — top field, field order not stated (display only)")
        XCTAssertEqual(FieldView.weave.inspectorText(.topFirst), "Weave (fields as stored)")
        XCTAssertTrue(FieldView.deinterlace.readout(.topFirst).contains("DISPLAY ONLY"))
        XCTAssertNil(FieldView.weave.titleSuffix); XCTAssertNil(FieldView.weave.badge)
        XCTAssertEqual(FieldView.field2.titleSuffix, "Field 2 (display only)")
        XCTAssertEqual(FieldView.deinterlace.badge, "DEINTERLACE · DISPLAY ONLY")
    }

    /// §14.8: the on-picture marker names every field view and is absent in Weave.
    func testMarkerOnlyOutsideWeave() {
        XCTAssertNil(FieldView.weave.marker)
        XCTAssertEqual(FieldView.field1.marker, "FIELD 1")
        XCTAssertEqual(FieldView.field2.marker, "FIELD 2")
        XCTAssertEqual(FieldView.deinterlace.marker, "DEINTERLACE")
    }

    func testChainPrefix() {
        XCTAssertEqual(scan(true).chainPrefix(height: 1080, fieldToken: "59.94"), "1080i59.94 TFF")
        XCTAssertEqual(scan(true, order: .bottomFirst).chainPrefix(height: 1080, fieldToken: "50"), "1080i50 BFF")
        XCTAssertEqual(scan(true, fields: true).chainPrefix(height: 540, fieldToken: "59.94"), "field sequence, TFF")
        XCTAssertEqual(scan(true).chainPrefix(height: 0, fieldToken: nil), "interlaced, TFF")
        XCTAssertNil(scan(false).chainPrefix(height: 1080, fieldToken: "29.97"))
        XCTAssertNil(scan(nil).chainPrefix(height: 1080, fieldToken: "29.97"))
    }
}
