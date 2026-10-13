//
//  HeadroomReadoutTests.swift
//  ColorimetryModelTests
//
//  Colour S4 (COLOR_MANAGEMENT_FINDINGS.md §6.11): the Headroom line's wording and the change test the
//  `[EDR] headroom` log and the readout share.
//

import XCTest
@testable import ColorimetryModel

final class HeadroomReadoutTests: XCTestCase {

    /// HDR off: potential 1.0, whatever current says. The S0 / S3 runs read exactly this on both displays.
    func testPotentialOneIsSDRMode() {
        XCTAssertEqual(HeadroomReadout.text(EDRHeadroom(current: 1.0, potential: 1.0)), "display is in SDR mode")
        XCTAssertEqual(HeadroomReadout.text(EDRHeadroom(current: 1.0, potential: 1.00005)), "display is in SDR mode")
    }

    /// HDR on, granted: "headroom 8.97 of 8.97" — the §6.11 S4 wording, from the measured 8.965394 (§6.7).
    func testGrantedReadsCurrentOfPotential() {
        XCTAssertEqual(HeadroomReadout.text(EDRHeadroom(current: 8.965394, potential: 8.965394)),
                       "headroom 8.97 of 8.97")
        XCTAssertEqual(HeadroomReadout.text(EDRHeadroom(current: 2.5, potential: 8.965394)),
                       "headroom 2.50 of 8.97")
    }

    /// HDR on, nothing granted: the §6.7 measurement. Must not read as an SDR display.
    func testOfferedButNotGrantedSaysSo() {
        let text = HeadroomReadout.text(EDRHeadroom(current: 1.0, potential: 8.965394))
        XCTAssertEqual(text, "headroom 1.00 of 8.97 — none granted")
        XCTAssertNotEqual(text, HeadroomReadout.sdrModeText)
    }

    func testNoScreen() {
        XCTAssertEqual(HeadroomReadout.text(nil), "no screen")
    }

    func testFormatPadsHundredths() {
        XCTAssertEqual(HeadroomReadout.format(1.0), "1.00")
        XCTAssertEqual(HeadroomReadout.format(4.48), "4.48")
        XCTAssertEqual(HeadroomReadout.format(16.049), "16.05")
        XCTAssertEqual(HeadroomReadout.format(1.004), "1.00")
    }

    /// The log fires on a visible change only, so it cannot spam on sub-display jitter and cannot miss a
    /// change the readout shows.
    func testChangeIsJudgedAtTheReadoutsPrecision() {
        let a = EDRHeadroom(current: 1.0, potential: 8.965394)
        XCTAssertFalse(a.differsVisibly(from: EDRHeadroom(current: 1.001, potential: 8.9681)))
        XCTAssertTrue(a.differsVisibly(from: EDRHeadroom(current: 1.0, potential: 1.0)))     // HDR switched off
        XCTAssertTrue(a.differsVisibly(from: EDRHeadroom(current: 1.0, potential: 6.2)))     // brightness
        XCTAssertTrue(a.differsVisibly(from: EDRHeadroom(current: 8.97, potential: 8.965394))) // a grant
        // `reference` is logged, never shown, so it does not count.
        XCTAssertFalse(a.differsVisibly(from: EDRHeadroom(current: 1.0, potential: 8.965394, reference: 3)))
    }
}
