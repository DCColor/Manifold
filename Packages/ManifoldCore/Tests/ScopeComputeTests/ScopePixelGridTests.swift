import XCTest
import ScopeCompute

/// The graticule pixel grid (docs/SCOPES_095_PLAN.md §2.1, §2.4 B): a line's center lands so that the line covers
/// whole device pixels, at 1× (the LG and the ASUS) and 2× (a Retina display), and never leaves the drawing area.
final class ScopePixelGridTests: XCTestCase {

    private func center(_ v: Double, _ w: Double, _ s: Double, extent: Double? = nil) -> Double {
        ScopePixelGrid.alignedCenter(v, lineWidth: w, scale: s, extent: extent)
    }

    // MARK: 1×

    func testOnePointAtOneXCentersOnAPixelMiddle() {
        // 1 pt = 1 px (odd): the center is n + 0.5, the pixel the coordinate falls in.
        XCTAssertEqual(center(10.0, 1, 1), 10.5)
        XCTAssertEqual(center(10.3, 1, 1), 10.5)
        XCTAssertEqual(center(10.99, 1, 1), 10.5)
        XCTAssertEqual(center(0.0, 1, 1), 0.5)
    }

    func testTwoPointsAtOneXCentersOnAPixelBoundary() {
        // 2 pt = 2 px (even): the center is the nearest boundary.
        XCTAssertEqual(center(10.3, 2, 1), 10.0)
        XCTAssertEqual(center(10.6, 2, 1), 11.0)
    }

    func testHalfPointAtOneXIsTreatedAsOnePixel() {
        // Under a device pixel is drawn as one, so it is placed like one.
        XCTAssertEqual(ScopePixelGrid.devicePixels(lineWidth: 0.5, scale: 1), 1)
        XCTAssertEqual(center(10.3, 0.5, 1), 10.5)
    }

    // MARK: 2×

    func testOnePointAtTwoXCentersOnABoundary() {
        // 1 pt = 2 px (even): the center is a whole device pixel, i.e. a multiple of 0.5 pt.
        XCTAssertEqual(center(10.0, 1, 2), 10.0)
        XCTAssertEqual(center(10.2, 1, 2), 10.0)    // 20.4 px → 20
        XCTAssertEqual(center(10.3, 1, 2), 10.5)    // 20.6 px → 21
        XCTAssertEqual(center(10.74, 1, 2), 10.5)   // 21.48 px → 21
    }

    func testHalfPointAtTwoXCentersOnAPixelMiddle() {
        // 0.5 pt = 1 px at 2× (odd).
        XCTAssertEqual(center(10.0, 0.5, 2), 10.25)
        XCTAssertEqual(center(10.4, 0.5, 2), 10.25)
    }

    // MARK: Any scale: the line's edges are on the grid

    func testEdgesLandOnDevicePixelsAtEveryScale() {
        var rng = SystemRandomNumberGenerator()
        for s in [1.0, 2.0, 3.0] {
            for w in [0.5, 1.0, 1.5, 2.0] {
                let px = ScopePixelGrid.devicePixels(lineWidth: w, scale: s)
                for _ in 0..<500 {
                    let v = Double.random(in: 0...400, using: &rng)
                    let top = center(v, w, s) * s - px / 2
                    XCTAssertEqual(top, top.rounded(), accuracy: 1e-9, "scale \(s) width \(w) at \(v)")
                    // Never more than one device pixel from where it was asked for.
                    XCTAssertLessThanOrEqual(abs(center(v, w, s) - v) * s, 1.0 + 1e-9)
                }
            }
        }
    }

    // MARK: Edges of the drawing area

    func testALineAtTheFarEdgeStaysInside() {
        // The 0 line of a value scope sits at y = height. Unclamped, a 1 px line there would be centered at
        // height + 0.5 and fall outside the canvas.
        XCTAssertEqual(center(100, 1, 1, extent: 100), 99.5)
        XCTAssertEqual(center(100, 1, 2, extent: 100), 99.5)   // 2 px wide: covers 198–199 of 200
        XCTAssertEqual(center(0, 1, 2, extent: 100), 0.5)      // covers 0–1
        XCTAssertEqual(center(0, 1, 1, extent: 100), 0.5)
    }

    func testAFractionalExtentStillClampsOntoTheGrid() {
        // A plot 100.6 pt tall at 1×: the last whole pixel row is 99, center 99.5.
        XCTAssertEqual(center(100.6, 1, 1, extent: 100.6), 99.5)
    }

    func testAnInteriorLineIsUnaffectedByTheClamp() {
        XCTAssertEqual(center(50.2, 1, 1, extent: 100), center(50.2, 1, 1))
        XCTAssertEqual(center(50.2, 1, 2, extent: 100), center(50.2, 1, 2))
    }

    func testANonPositiveScaleIsTreatedAsOneX() {
        XCTAssertEqual(center(10.3, 1, 0), 10.5)
    }
}
