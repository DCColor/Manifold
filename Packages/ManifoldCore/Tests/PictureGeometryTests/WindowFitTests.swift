import XCTest
@testable import PictureGeometry

/// The window half of docs/BUGS.md, "iPhone clips open rotated or flipped" (2026-10-29). MEASURED by Robbie and Joey: on a
/// MacBook Air at 2048 × 1332 pt, IMG_9457.MOV (2160 × 3840 displayed) opened at 720 × 1280 and could not be made
/// smaller, taller than the visible screen.
final class WindowFitTests: XCTestCase {

    private let minContent = CGSize(width: 720, height: 460)   // ContentView().frame(minWidth: 720, minHeight: 460)
    private let chromes: [CGFloat] = [0, 64, 300]              // no chrome, the docked bar, the bar and a tray

    // A 2048 × 1332 Air: menu bar 37 pt; with the Dock hidden, and with a 70-pt Dock at the bottom.
    private let airScreens = [CGSize(width: 2048, height: 1295), CGSize(width: 2048, height: 1225)]
    private let shapes: [(String, CGSize)] = [("vertical", CGSize(width: 2160, height: 3840)),
                                              ("square", CGSize(width: 1080, height: 1080)),
                                              ("landscape 4K", CGSize(width: 3840, height: 2160)),
                                              ("landscape HD", CGSize(width: 1920, height: 1080)),
                                              ("scope", CGSize(width: 2048, height: 858)),
                                              ("2.39", CGSize(width: 4096, height: 1714))]

    /// The opening rule's request: 80% of the visible height at up to 1:1 (2× display), as `openingContentWidth` asks.
    private func openingRequest(_ s: CGSize, _ screen: CGSize) -> CGFloat {
        let aspect = s.width / s.height
        return min(s.width / 2, screen.width * 0.8, screen.height * 0.8 * aspect)
    }

    /// W1: a new window opens inside the visible frame on the Air, for every shape and chrome the tests carry.
    func testOpeningFitsAMacBookAir() {
        for screen in airScreens { for (name, s) in shapes { for chrome in chromes {
            let aspect = s.width / s.height
            let r = WindowFit.solve(pictureWidth: openingRequest(s, screen), aspect: aspect, chrome: chrome,
                                    floor: .window, minContent: minContent, maxContent: screen)
            XCTAssertLessThanOrEqual(r.content.width, screen.width, "\(name) chrome \(chrome)")
            XCTAssertLessThanOrEqual(r.content.height, screen.height, "\(name) chrome \(chrome) on \(screen)")
            XCTAssertGreaterThanOrEqual(r.content.width, minContent.width)
            XCTAssertGreaterThanOrEqual(r.content.height, minContent.height)
            // On shape: the picture's box is the picture.
            XCTAssertEqual(r.pictureWidth / aspect + chrome, r.content.height, accuracy: 1.5,
                           "\(name) chrome \(chrome): the picture is \(r.pictureWidth) wide in \(r.content)")
        }}}
    }

    /// The case that was reported, in numbers: before, 720 × 1280 on a screen 1225–1295 tall. Now inside it.
    func testIMG9457OnTheAir() {
        let r = WindowFit.solve(pictureWidth: 720, aspect: 2160.0 / 3840.0, chrome: 64, floor: .window,
                                minContent: minContent, maxContent: airScreens[1])
        XCTAssertEqual(r.content.height, 1225)
        XCTAssertEqual(r.pictureWidth, ((1225 - 64) * 2160.0 / 3840.0).rounded())
        XCTAssertEqual(r.content.width, 720)
        XCTAssertTrue(r.isPillarboxed)
    }

    /// W1: the user's floor. Asked for nothing (a drag to 1 pt), every shape lands at its picture floor: the shorter side
    /// 320, or taller where the window's own 460-pt minimum height asks for more picture. The window never goes below
    /// 720 × 460.
    func testResizeFloorForEveryShape() {
        let big = CGSize(width: 3840, height: 2100)
        for (name, s) in shapes { for chrome in chromes {
            let aspect = s.width / s.height
            let r = WindowFit.solve(pictureWidth: 1, aspect: aspect, chrome: chrome, floor: .picture,
                                    minContent: minContent, maxContent: big)
            let pictureH = r.pictureWidth / aspect
            let short = min(r.pictureWidth, pictureH)
            let fillsMinimumHeight = (minContent.height - chrome) // the growth rule's height, when it applies
            // A picture wider than 2.25:1 stops at the window's minimum width instead (short side 301 for 2.39).
            let floorShort = min(320, 720 / max(aspect, 1))
            XCTAssertGreaterThanOrEqual(short, floorShort - 0.5, "\(name) chrome \(chrome)")
            XCTAssertTrue(abs(short - floorShort) <= 1 || abs(pictureH - fillsMinimumHeight) <= 1,
                          "\(name) chrome \(chrome): picture \(r.pictureWidth)×\(pictureH)")
            XCTAssertGreaterThanOrEqual(r.content.width, 720)
            XCTAssertGreaterThanOrEqual(r.content.height, 460)
        }}
        // The vertical case in numbers, with the docked bar: 320 × 569 in a 720 × 633 window.
        let v = WindowFit.solve(pictureWidth: 1, aspect: 9.0 / 16.0, chrome: 64, floor: .picture,
                                minContent: minContent, maxContent: big)
        XCTAssertEqual(v.pictureWidth, 320)
        XCTAssertEqual(v.content, CGSize(width: 720, height: 633))
    }

    /// The window floor keeps every fresh landscape size what it was: at or above 720 wide, the solve is the old one.
    func testLandscapeUnchangedAboveTheWindowMinimum() {
        let screen = CGSize(width: 3840, height: 2100)
        for aspect in [16.0 / 9.0, 2.39, 1.33, 1.0] { for chrome in chromes {
            for w in stride(from: CGFloat(1), through: 3000, by: 37) {
                let r = WindowFit.solve(pictureWidth: w, aspect: aspect, chrome: chrome, floor: .window,
                                        minContent: minContent, maxContent: screen)
                // The pre-2026-10-29 solve, restated.
                let oldBudget = max(min(screen.width, max(screen.height - chrome, 1) * aspect), minContent.width)
                var oldW = min(max(w, minContent.width), oldBudget)
                if oldW / aspect + chrome < minContent.height {
                    oldW = min(max(oldW, (minContent.height - chrome) * aspect), oldBudget)
                }
                let old = CGSize(width: oldW.rounded(), height: max(oldW / aspect + chrome, minContent.height).rounded())
                XCTAssertEqual(r.content, old, "aspect \(aspect) chrome \(chrome) asked \(w)")
            }
        }}
    }

    /// W3: a screen too short for the picture floor still gets a window inside it: the screen cap outranks the floor.
    /// The ASUS PA147 at 1920 × 550 pt (menu bar 25).
    func testScreenCapOutranksThePictureFloor() {
        let asus = CGSize(width: 1920, height: 525)
        for (name, s) in shapes { for chrome: CGFloat in [0, 64] {
            for floor in [WindowFit.Floor.window, .picture] {
                let r = WindowFit.solve(pictureWidth: 5000, aspect: s.width / s.height, chrome: chrome, floor: floor,
                                        minContent: minContent, maxContent: asus)
                XCTAssertLessThanOrEqual(r.content.height, asus.height, "\(name) chrome \(chrome)")
                XCTAssertLessThanOrEqual(r.content.width, asus.width, "\(name) chrome \(chrome)")
            }
        }}
    }

    /// A re-solve keeps a pillarboxed picture where the user left it, and reads an ordinary window's width as its picture's.
    func testCurrentPictureWidth() {
        let pillar = WindowFit.solve(pictureWidth: 1, aspect: 9.0 / 16.0, chrome: 64, floor: .picture,
                                     minContent: minContent, maxContent: CGSize(width: 3840, height: 2100))
        XCTAssertEqual(WindowFit.currentPictureWidth(contentWidth: 720, last: pillar), 320)
        XCTAssertEqual(WindowFit.currentPictureWidth(contentWidth: 900, last: pillar), 900)   // the window moved since
        XCTAssertEqual(WindowFit.currentPictureWidth(contentWidth: 1400, last: nil), 1400)
        let full = WindowFit.solve(pictureWidth: 1400, aspect: 16.0 / 9.0, chrome: 64, floor: .window,
                                   minContent: minContent, maxContent: CGSize(width: 3840, height: 2100))
        XCTAssertFalse(full.isPillarboxed)
        XCTAssertEqual(WindowFit.currentPictureWidth(contentWidth: 1400, last: full), 1400)
    }
}
