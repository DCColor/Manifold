//
//  CardClockLineTests.swift
//  Stage 2 (docs/CARD_CLOCK_FINDINGS.md §10.27): the card's slot against the host.
//

import XCTest
@testable import CardClock

final class CardClockLineTests: XCTestCase {
    let fs = 1001.0 / 60000

    func samples(from slot: Int64, count: Int, host0: Double, ppm: Double) -> [CardClockSample] {
        (0..<count).map { k in CardClockSample(slot: slot + Int64(k), host: host0 + Double(k) * fs / (1 + ppm * 1e-6)) }
    }

    func testFitRecoversLine() throws {
        let s = samples(from: 1000, count: 300, host0: 500, ppm: -17.6)
        let line = try XCTUnwrap(CardClockLine.fit(s, frameSeconds: fs))
        XCTAssertEqual((line.rate - 1) * 1e6, -17.6, accuracy: 0.01)
        let last = s.last!
        XCTAssertEqual(line.cardTime(atHost: last.host), Double(last.slot) * fs, accuracy: 1e-7)
        XCTAssertEqual(line.host(atCardTime: Double(last.slot) * fs), last.host, accuracy: 1e-7)
        XCTAssertEqual(line.newestSlot, last.slot)
    }

    /// A position step in the window: the fit uses only what follows it.
    func testFitStopsAtStep() throws {
        var s = samples(from: 0, count: 120, host0: 100, ppm: 0)
        s += samples(from: 120, count: 120, host0: s.last!.host + fs + 0.004, ppm: 0)   // 4 ms late from slot 120 on
        let line = try XCTUnwrap(CardClockLine.fit(s, frameSeconds: fs))
        XCTAssertEqual(line.cardTime(atHost: s.last!.host), Double(s.last!.slot) * fs, accuracy: 1e-7)
    }

    func testTooFew() {
        XCTAssertNil(CardClockLine.fit(samples(from: 0, count: 2, host0: 0, ppm: 0), frameSeconds: fs))
    }

    /// Under 0.5 s: rate held at 1, offset fitted. At −100 ppm over 9 frames the error stays under 20 µs.
    func testShortSpanHoldsRate() throws {
        let s = samples(from: 8, count: 9, host0: 50, ppm: -100)
        let line = try XCTUnwrap(CardClockLine.fit(s, frameSeconds: fs))
        XCTAssertEqual(line.rate, 1)
        XCTAssertEqual(line.cardTime(atHost: s.last!.host), Double(s.last!.slot) * fs, accuracy: 2e-5)
    }

    func testPictureLineBoxSerial() {
        let box = CardPictureLineBox()
        XCTAssertTrue(box.store(CardPictureLine(serial: 1, phi: 2, firstSlot: 3, lastSlot: 3, matched: true)))
        XCTAssertFalse(box.store(CardPictureLine(serial: 1, phi: 2, firstSlot: 3, lastSlot: 4, matched: true)))
        XCTAssertEqual(box.read()?.lastSlot, 4)
        XCTAssertTrue(box.store(CardPictureLine(serial: 2, phi: 2, firstSlot: 5, lastSlot: 5, matched: true)))
        box.reset(); XCTAssertNil(box.read())
    }
}
