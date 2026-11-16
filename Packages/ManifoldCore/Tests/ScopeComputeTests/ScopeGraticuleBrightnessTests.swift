import XCTest
@testable import ScopeCompute

/// Settings ▸ Scopes ▸ Graticule brightness: the pure scaling the four image scopes draw with.
final class ScopeGraticuleBrightnessTests: XCTestCase {
    typealias B = ScopeGraticuleBrightness

    func testRangeAndDefault() {
        XCTAssertEqual(B.range, 0.0...2.0)
        XCTAssertEqual(B.defaultValue, 1.0)
    }

    /// 1× draws the built-in values exactly: lines, labels and the skin-tone axis.
    func testDefaultIsIdentity() {
        for base in [0.0, 0.12, 0.20, 0.35, 0.55, 0.70, 0.85, 0.90, 1.0] {
            XCTAssertEqual(B.line(base, 1.0), base, accuracy: 1e-12)
            XCTAssertEqual(B.label(base, 1.0), base, accuracy: 1e-12)
            XCTAssertEqual(B.reference(base, 1.0), base, accuracy: 1e-12)
        }
    }

    /// 0 turns every line off.
    func testZeroTurnsLinesOff() {
        for base in [0.12, 0.20, 0.35, 0.75, 1.0] {
            XCTAssertEqual(B.line(base, 0), 0)
        }
    }

    /// 2× doubles a line, clamped to full opacity.
    func testDoubleScalesAndClamps() {
        XCTAssertEqual(B.line(0.20, 2), 0.40, accuracy: 1e-12)
        XCTAssertEqual(B.line(0.12, 2), 0.24, accuracy: 1e-12)
        XCTAssertEqual(B.line(0.30, 2), 0.60, accuracy: 1e-12)    // HLG nits ticks
        XCTAssertEqual(B.line(0.55, 2), 1.0)
        XCTAssertEqual(B.line(0.90, 2), 1.0)
        XCTAssertEqual(B.label(0.85, 2), 1.0)
        XCTAssertEqual(B.reference(0.70, 2), 1.0)
    }

    /// Labels and the vectorscope references (skin-tone axis, target brackets, both 0.70) stop at their floors; above
    /// the floor they follow the slider.
    func testLabelAndReferenceFloors() {
        XCTAssertEqual(B.labelFloor, 0.60)
        XCTAssertEqual(B.referenceFloor, 0.50)
        XCTAssertEqual(B.label(0.85, 0), 0.60)
        XCTAssertEqual(B.label(0.85, 0.5), 0.60)                       // 0.425 → floor
        XCTAssertEqual(B.label(0.85, 0.8), 0.68, accuracy: 1e-12)      // above the floor: scaled
        XCTAssertEqual(B.label(1.0, 0), 0.60)
        XCTAssertEqual(B.reference(0.70, 0), 0.50)
        XCTAssertEqual(B.reference(0.70, 0.5), 0.50)                   // 0.35 → floor
        XCTAssertEqual(B.reference(0.70, 0.8), 0.56, accuracy: 1e-12)
        XCTAssertEqual(B.reference(0.70, 1.2), 0.84, accuracy: 1e-12)
    }

    /// A base below its floor is never dimmed below itself and never raised to the floor.
    func testBaseBelowFloor() {
        XCTAssertEqual(B.label(0.40, 0), 0.40)
        XCTAssertEqual(B.label(0.40, 1), 0.40)
        XCTAssertEqual(B.label(0.40, 2), 0.80, accuracy: 1e-12)
    }

    /// Labels never drop below the floor, and lines never leave 0…1, at any slider position.
    func testMonotoneAndBoundedAcrossTheRange() {
        for base in [0.12, 0.20, 0.30, 0.45, 0.70, 0.85, 1.0] {
            var lastLine = -1.0, lastLabel = -1.0
            for i in 0...200 {
                let b = Double(i) / 100
                let l = B.line(base, b), t = B.label(base, b)
                XCTAssert((0...1).contains(l)); XCTAssert((0...1).contains(t))
                XCTAssertGreaterThanOrEqual(l, lastLine); XCTAssertGreaterThanOrEqual(t, lastLabel)
                XCTAssertGreaterThanOrEqual(t, min(B.labelFloor, base))
                XCTAssertGreaterThanOrEqual(B.reference(base, b), min(B.referenceFloor, base))
                lastLine = l; lastLabel = t
            }
        }
    }

    /// A stored value outside the range (a hand-edited defaults key) is clamped; a non-finite one reads as 1×.
    func testOutOfRangeAndNonFiniteStoredValues() {
        XCTAssertEqual(B.clamped(-1), 0)
        XCTAssertEqual(B.clamped(5), 2)
        XCTAssertEqual(B.clamped(.nan), 1)
        XCTAssertEqual(B.clamped(.infinity), 1)
        XCTAssertEqual(B.line(0.20, -1), 0)
        XCTAssertEqual(B.line(0.20, 5), 0.40, accuracy: 1e-12)
        XCTAssertEqual(B.line(0.20, .nan), 0.20, accuracy: 1e-12)
        XCTAssertEqual(B.label(0.85, -3), 0.60)
    }
}
