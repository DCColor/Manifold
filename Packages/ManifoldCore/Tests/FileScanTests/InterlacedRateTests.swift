import XCTest
@testable import FileScan

/// docs/INTERLACED_FINDINGS.md §5, decision 3 (I2): an interlaced file of woven frames reporting a field rate is halved.
final class InterlacedRateTests: XCTestCase {

    private func scan(_ interlaced: Bool, fields: Bool = false) -> SourceScan {
        let b = ScanReading(interlaced: interlaced, fieldOrder: interlaced ? .topFirst : nil,
                            scanSource: fields ? "HEVC field_seq_flag" : "ProRes frame header", detail: "test",
                            picturesAreFields: fields)
        return SourceScan.resolve(container: nil, bitstream: b)
    }

    func testFieldRatesHalveOnWovenInterlaced() {
        let ntsc = InterlacedRate.resolve(reported: 60000.0 / 1001.0, scan: scan(true))
        XCTAssertEqual(ntsc.frameRate, 30000.0 / 1001.0, accuracy: 1e-12)
        XCTAssertEqual(ntsc.halvedFrom!, 60000.0 / 1001.0, accuracy: 1e-12)
        XCTAssertEqual(InterlacedRate.resolve(reported: 50, scan: scan(true)).frameRate, 25)
        XCTAssertEqual(InterlacedRate.resolve(reported: 60, scan: scan(true)).frameRate, 30)
        XCTAssertEqual(InterlacedRate.resolve(reported: 59.94, scan: scan(true)).frameRate, 30000.0 / 1001.0, accuracy: 1e-9)   // a rounded rate
        XCTAssertNotNil(InterlacedRate.resolve(reported: 50, scan: scan(true)).logLine)
    }

    func testFrameRatesAndOthersAreKept() {
        for r in [25.0, 30000.0 / 1001.0, 30, 24000.0 / 1001.0, 24, 48, 100, 119.88] {
            let got = InterlacedRate.resolve(reported: r, scan: scan(true))
            XCTAssertEqual(got.frameRate, r, "\(r)"); XCTAssertNil(got.halvedFrom); XCTAssertNil(got.logLine)
        }
    }

    func testProgressiveUnknownAndFieldSequencesAreNotHalved() {
        XCTAssertNil(InterlacedRate.resolve(reported: 50, scan: scan(false)).halvedFrom)
        XCTAssertNil(InterlacedRate.resolve(reported: 60000.0 / 1001.0, scan: .notRead).halvedFrom)
        let fieldSeq = scan(true, fields: true)
        XCTAssertTrue(fieldSeq.picturesAreFields)
        XCTAssertNil(InterlacedRate.resolve(reported: 60000.0 / 1001.0, scan: fieldSeq).halvedFrom)
        // A container saying "fields" cannot make the pictures fields: only the bitstream that decided the scan can.
        XCTAssertFalse(scan(true).picturesAreFields)
    }

    func testFieldRateSuffix() {
        XCTAssertEqual(scan(true).fieldRateSuffix(frameRate: 30000.0 / 1001.0), " (59.94 fields/s)")
        XCTAssertEqual(scan(true).fieldRateSuffix(frameRate: 25), " (50 fields/s)")
        XCTAssertEqual(scan(true).fieldRateSuffix(frameRate: 30), " (60 fields/s)")
        XCTAssertEqual(scan(false).fieldRateSuffix(frameRate: 25), "")
        XCTAssertEqual(scan(true, fields: true).fieldRateSuffix(frameRate: 60000.0 / 1001.0), "")
    }
}
