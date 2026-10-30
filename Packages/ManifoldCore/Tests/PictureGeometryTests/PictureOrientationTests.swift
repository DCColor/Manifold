import XCTest
@testable import PictureGeometry

/// docs/BUGS.md, "iPhone clips open rotated or flipped" (2026-10-29). The matrices here are the ones MEASURED on the two
/// iPhone files and on the ffmpeg fixtures (build/orient-1029/mkfix.sh), read with exiftool.
final class PictureOrientationTests: XCTestCase {

    private func read(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> PictureOrientation? {
        if case .orientation(let o) = PictureOrientation.read(a: a, b: b, c: c, d: d) { return o }
        return nil
    }

    // MARK: - Reading

    /// IMG_9457.MOV: tkhd `0 1 0 / -1 0 0 / 2160 0 1`, 3840×2160 stored; QuickTime shows it upright, 2160×3840.
    func testIPhonePortraitIsNinetyClockwise() throws {
        let o = try XCTUnwrap(read(0, 1, -1, 0))
        XCTAssertEqual(o.clockwiseDegrees, 90)
        XCTAssertFalse(o.isMirrored)
        XCTAssertTrue(o.swapsAxes)
        XCTAssertEqual(o.description, "Rotated 90° clockwise")
        XCTAssertTrue(o.displayedSize(width: 3840, height: 2160) == (2160, 3840))
    }

    /// IMG_5070.MOV: tkhd `-1 0 0 / 0 -1 0 / 1920 1080 1`.
    func testIPhoneUpsideDownIsOneEighty() throws {
        let o = try XCTUnwrap(read(-1, 0, 0, -1))
        XCTAssertEqual(o.clockwiseDegrees, 180)
        XCTAssertFalse(o.isMirrored)
        XCTAssertFalse(o.swapsAxes)
        XCTAssertEqual(o.description, "Rotated 180°")
        XCTAssertTrue(o.displayedSize(width: 1920, height: 1080) == (1920, 1080))
    }

    func testTheFixtureMatrices() throws {
        // exiftool's MatrixStructure for each fixture, a b / c d.
        let cases: [(String, Double, Double, Double, Double, Int, Bool, String)] = [
            ("rot0", 1, 0, 0, 1, 0, false, "none"),
            ("rot90", 0, 1, -1, 0, 90, false, "rot90cw"),
            ("rot180", -1, 0, 0, -1, 180, false, "rot180cw"),
            ("rot270", 0, -1, 1, 0, 270, false, "rot270cw"),
            ("hflip", -1, 0, 0, 1, 0, true, "hflip"),
            ("rot90-hflip", 0, 1, 1, 0, 90, true, "rot90cw+hflip"),
        ]
        for (name, a, b, c, d, deg, mirrored, token) in cases {
            let o = try XCTUnwrap(read(a, b, c, d), name)
            XCTAssertEqual(o.clockwiseDegrees, deg, name)
            XCTAssertEqual(o.isMirrored, mirrored, name)
            XCTAssertEqual(o.logToken, token, name)
        }
        XCTAssertEqual(read(1, 0, 0, 1), .identity)
        XCTAssertEqual(read(1, 0, 0, -1)?.description, "Mirrored top to bottom")
        XCTAssertEqual(read(-1, 0, 0, 1)?.description, "Mirrored left to right")
        XCTAssertEqual(read(0, 1, 1, 0)?.description, "Rotated 90° clockwise, then mirrored left to right")
    }

    /// A uniform scale changes no direction and is divided out; float noise in a stored matrix is tolerated.
    func testScaleAndNoiseAreTolerated() {
        XCTAssertEqual(read(0, 2, -2, 0)?.clockwiseDegrees, 90)
        XCTAssertEqual(read(0.00001, 0.99999, -1.00001, 0.0)?.clockwiseDegrees, 90)
    }

    /// Anything not axis-aligned is refused and drawn as stored, never rounded to the nearest quarter turn.
    func testNonAxisAlignedIsRefused() {
        let s = sqrt(0.5)
        XCTAssertEqual(PictureOrientation.read(a: s, b: s, c: -s, d: s).applied, .identity)
        if case .orientation = PictureOrientation.read(a: s, b: s, c: -s, d: s) { XCTFail("45° must be refused") }
        if case .orientation = PictureOrientation.read(a: 1, b: 0.5, c: 0, d: 1) { XCTFail("skew must be refused") }
        if case .orientation = PictureOrientation.read(a: 0, b: 0, c: 0, d: 0) { XCTFail("zero must be refused") }
        if case .orientation = PictureOrientation.read(a: 1, b: 1, c: 1, d: 1) { XCTFail("degenerate must be refused") }
        if case .orientation = PictureOrientation.read(a: .nan, b: 0, c: 0, d: 1) { XCTFail("NaN must be refused") }
    }

    /// libav's AV_PKT_DATA_DISPLAYMATRIX: nine int32, a b u / c d v / x y w, 16.16 except the third column (2.30).
    func testLibavDisplayMatrix() {
        let one: Int32 = 1 << 16, w: Int32 = 1 << 30
        XCTAssertEqual(PictureOrientation.read(displayMatrix: [0, one, 0, -one, 0, 0, 0, 0, w]).applied.clockwiseDegrees, 90)
        XCTAssertEqual(PictureOrientation.read(displayMatrix: [-one, 0, 0, 0, -one, 0, 0, 0, w]).applied.clockwiseDegrees, 180)
        XCTAssertEqual(PictureOrientation.read(displayMatrix: [one, 0, 0, 0, one, 0, 0, 0, w]).applied, .identity)
        XCTAssertEqual(PictureOrientation.read(displayMatrix: [-one, 0, 0, 0, one, 0, 0, 0, w]).applied.logToken, "hflip")
        if case .orientation = PictureOrientation.read(displayMatrix: [one, 0]) { XCTFail("short matrix must be refused") }
    }

    func testPixelAspectFollowsTheTurn() throws {
        XCTAssertTrue(try XCTUnwrap(read(0, 1, -1, 0)).displayedPixelAspect(horizontal: 2, vertical: 1) == (1, 2))
        XCTAssertTrue(try XCTUnwrap(read(-1, 0, 0, -1)).displayedPixelAspect(horizontal: 2, vertical: 1) == (2, 1))
    }

    // MARK: - The sampling rule, against rotations written out by hand

    /// The CPU reference the shader is held to: for every displayed pixel, the stored pixel it shows equals the one an
    /// explicitly written rotation or mirror gives. Odd and even sizes, both shapes.
    func testSamplingMatchesExplicitTransforms() throws {
        // displayed (x, y) → stored (x, y), for a stored raster w × h; the displayed raster is W × H.
        let explicit: [(String, PictureOrientation, (Int, Int, Int, Int) -> (Int, Int))] = [
            ("rot0", .identity, { x, y, _, _ in (x, y) }),
            ("rot90", try XCTUnwrap(read(0, 1, -1, 0)), { x, y, w, h in (y, h - 1 - x) }),
            ("rot180", try XCTUnwrap(read(-1, 0, 0, -1)), { x, y, w, h in (w - 1 - x, h - 1 - y) }),
            ("rot270", try XCTUnwrap(read(0, -1, 1, 0)), { x, y, w, h in (w - 1 - y, x) }),
            ("hflip", try XCTUnwrap(read(-1, 0, 0, 1)), { x, y, w, h in (w - 1 - x, y) }),
            ("vflip", try XCTUnwrap(read(1, 0, 0, -1)), { x, y, w, h in (x, h - 1 - y) }),
            ("transpose", try XCTUnwrap(read(0, 1, 1, 0)), { x, y, w, h in (y, x) }),
            ("antitranspose", try XCTUnwrap(read(0, -1, -1, 0)), { x, y, w, h in (w - 1 - y, h - 1 - x) }),
        ]
        for (w, h) in [(8, 4), (7, 5), (3, 9), (640, 360)] {
            for (name, o, f) in explicit {
                let out = o.displayedSize(width: w, height: h)
                for y in 0..<out.height { for x in 0..<out.width {
                    let got = o.storedPixel(forDisplayed: x, y, storedWidth: w, storedHeight: h)
                    let want = f(x, y, w, h)
                    if got != want {
                        XCTFail("\(name) \(w)×\(h): displayed (\(x),\(y)) → \(got), want \(want)"); return
                    }
                }}
            }
        }
    }

    /// The displayed top-left corner of a 90° clockwise picture is the stored BOTTOM-left: the iPhone's case, said in
    /// the words a person checks it by.
    func testNinetyClockwiseCorners() throws {
        let o = try XCTUnwrap(read(0, 1, -1, 0))
        XCTAssertTrue(o.storedPixel(forDisplayed: 0, 0, storedWidth: 3840, storedHeight: 2160) == (0, 2159))
        XCTAssertTrue(o.storedPixel(forDisplayed: 2159, 0, storedWidth: 3840, storedHeight: 2160) == (0, 0))
        XCTAssertTrue(o.storedPixel(forDisplayed: 2159, 3839, storedWidth: 3840, storedHeight: 2160) == (3839, 0))
    }

    /// All eight are distinct, and the sampling coefficients of the identity are exactly 1 0 / 0 1 (what keeps every
    /// unrotated file's texture coordinates bit-identical to before).
    func testEightDistinctAndIdentitySampling() {
        var all = Set<PictureOrientation>()
        for a in -1...1 { for b in -1...1 { for c in -1...1 { for d in -1...1 {
            if case .orientation(let o) = PictureOrientation.read(a: Double(a), b: Double(b), c: Double(c), d: Double(d)) {
                all.insert(o)
            }
        }}}}
        XCTAssertEqual(all.count, 8)
        XCTAssertTrue(PictureOrientation.identity.sampling == (1, 0, 0, 1))
        XCTAssertEqual(Set(all.map(\.description)).count, 8)
    }
}
