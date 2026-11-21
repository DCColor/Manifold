import XCTest
@testable import Markers

final class MarkerTextSizeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "MarkerTextSizeTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// Medium is exactly the slot's metrics before the setting (MarkersScopeView.swift, 2026-11-21).
    func testMediumIsTodaysMetrics() {
        let m = MarkerTextSize.medium.metrics
        XCTAssertEqual(m, MarkerSlotMetrics.medium)
        XCTAssertEqual(m.timecode, 10); XCTAssertEqual(m.name, 11); XCTAssertEqual(m.notes, 10); XCTAssertEqual(m.duration, 9)
        XCTAssertEqual(m.chip, 8); XCTAssertEqual(m.swatch, 8); XCTAssertEqual(m.thumbnail, 32)
        XCTAssertEqual(m.rowSpacing, 6); XCTAssertEqual(m.rowPadding, 2); XCTAssertEqual(m.chipPaddingH, 4); XCTAssertEqual(m.chipPaddingV, 1)
    }

    func testDefaultIsMedium() {
        let d = defaults()
        XCTAssertEqual(MarkerTextSize.defaultSize, .medium)
        XCTAssertEqual(MarkerTextSize.current(d), .medium)            // absent
        d.set("huge", forKey: MarkerTextSize.key)
        XCTAssertEqual(MarkerTextSize.current(d), .medium)            // unknown
        d.set("large", forKey: MarkerTextSize.key)
        XCTAssertEqual(MarkerTextSize.current(d), .large)
        d.set("small", forKey: MarkerTextSize.key)
        XCTAssertEqual(MarkerTextSize.current(d), .small)
    }

    /// Each step scales every metric, fonts and row height together, by one factor.
    func testStepsScaleEverythingTogether() {
        for size in MarkerTextSize.allCases {
            XCTAssertEqual(size.metrics, MarkerSlotMetrics.medium.scaled(by: size.scale), "\(size)")
            XCTAssertEqual(size.metrics.thumbnail / MarkerSlotMetrics.medium.thumbnail, size.scale, accuracy: 1e-12)
            XCTAssertEqual(size.metrics.timecode / MarkerSlotMetrics.medium.timecode, size.scale, accuracy: 1e-12)
        }
        XCTAssertLessThan(MarkerTextSize.small.scale, 1); XCTAssertGreaterThan(MarkerTextSize.large.scale, 1)
        XCTAssertEqual(MarkerTextSize.allCases.map(\.label), ["Small", "Medium", "Large"])
    }

    /// Small keeps the smallest text, the IN/OUT chip, at 7 pt or more; Large's chip still fits the 22 pt scope header.
    func testExtremesStayInBounds() {
        XCTAssertGreaterThanOrEqual(MarkerTextSize.small.metrics.chip, 7)
        let l = MarkerTextSize.large.metrics
        XCTAssertLessThanOrEqual(l.chip * 1.3 + 2 * l.chipPaddingV, 22)   // a line is ~1.2–1.3 × the point size
    }
}
