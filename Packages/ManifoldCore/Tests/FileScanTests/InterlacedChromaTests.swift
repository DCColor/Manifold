import XCTest
@testable import FileScan

/// docs/INTERLACED_FINDINGS.md §8, I3: a woven interlaced picture's 4:2:0 chroma comes from each line's own field.
final class InterlacedChromaTests: XCTestCase {

    private func scan(_ interlaced: Bool?, fields: Bool = false) -> SourceScan {
        guard let interlaced else { return .notRead }
        let b = ScanReading(interlaced: interlaced, fieldOrder: interlaced ? .bottomFirst : nil,
                            scanSource: fields ? "HEVC field_seq_flag" : "H.264 pic_struct SEI", detail: "test",
                            picturesAreFields: fields)
        return SourceScan.resolve(container: nil, bitstream: b)
    }

    func testOnlyWovenInterlacedIsPerField() {
        XCTAssertTrue(InterlacedChroma.perField(scan(true)))              // either field order: parity is spatial
        XCTAssertFalse(InterlacedChroma.perField(scan(true, fields: true)))   // a field sequence is already per field
        XCTAssertFalse(InterlacedChroma.perField(scan(false)))
        XCTAssertFalse(InterlacedChroma.perField(scan(nil)))
    }

    func testEveryLineReadsOnlyItsOwnField() {
        for y in 0..<1080 {
            let t = InterlacedChroma.taps(lumaRow: y, chromaRows: 540)
            XCTAssertEqual(t.rowA & 1, y & 1, "line \(y)")
            XCTAssertEqual(t.rowB & 1, y & 1, "line \(y)")
            XCTAssertTrue((0..<540).contains(t.rowA) && (0..<540).contains(t.rowB), "line \(y)")
        }
    }

    /// The MPEG-2 field taps: 5/8·3/8 and 1/8·7/8 (top), 7/8·1/8 and 3/8·5/8 (bottom), edges clamped within the field.
    func testWeightsAndEdges() {
        func t(_ y: Int) -> (Int, Int, Double) {
            let k = InterlacedChroma.taps(lumaRow: y, chromaRows: 540); return (k.rowA, k.rowB, k.weightB)
        }
        XCTAssertEqual(t(0).0, 0); XCTAssertEqual(t(0).1, 0)                        // top edge: row 0 only
        XCTAssertTrue(t(2) == (0, 2, 0.375)); XCTAssertTrue(t(4) == (0, 2, 0.875))
        XCTAssertTrue(t(6) == (2, 4, 0.375)); XCTAssertTrue(t(8) == (2, 4, 0.875))
        XCTAssertEqual(t(1).0, 1); XCTAssertEqual(t(1).1, 1)                        // bottom field's top edge
        XCTAssertTrue(t(3) == (1, 3, 0.125)); XCTAssertTrue(t(5) == (1, 3, 0.625))
        XCTAssertTrue(t(7) == (3, 5, 0.125)); XCTAssertTrue(t(9) == (3, 5, 0.625))
        XCTAssertEqual(t(1078).0, 538); XCTAssertEqual(t(1078).1, 538)              // bottom edge, each field
        XCTAssertEqual(t(1079).0, 539); XCTAssertEqual(t(1079).1, 539)
    }

    /// Away from the edges a line's interpolated chroma position is its own position: the siting is unchanged
    /// (chroma row c at frame line 2c + 0.5), only the neighbours are.
    func testSitingIsTheProgressiveSiting() {
        for y in 4..<1076 {
            let k = InterlacedChroma.taps(lumaRow: y, chromaRows: 540)
            let at = (1 - k.weightB) * (2 * Double(k.rowA) + 0.5) + k.weightB * (2 * Double(k.rowB) + 0.5)
            XCTAssertEqual(at, Double(y), accuracy: 1e-12, "line \(y)")
        }
    }

    func testTinyPlanesStayInBounds() {
        for rows in 1...3 { for y in 0..<(2 * rows) {
            let k = InterlacedChroma.taps(lumaRow: y, chromaRows: rows)
            XCTAssertTrue((0..<rows).contains(k.rowA) && (0..<rows).contains(k.rowB), "rows \(rows) line \(y)")
        } }
    }
}
