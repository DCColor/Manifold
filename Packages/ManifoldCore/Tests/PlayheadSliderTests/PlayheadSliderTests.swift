import XCTest
import AppKit
import SwiftUI
@testable import PlayheadSlider

/// The playhead style's predictions (2026-10-16), measured against what the transport bar had before:
/// the SwiftUI `Slider`, and the stock NSSlider it is drawn by.
///
///   1. The line's centre lands on the ball's centre for the same value, ±0.5 pt, at every width.
///   2. A click and a drag land on the same value in both styles.
///   3. Switching style changes nothing but the paint: Ball renders as before, the height is the
///      SwiftUI Slider's (the docked bar's height sizes the window), the value and knob rect stay put.
///
/// Every control is hosted in an offscreen window. Out of a window a stock NSSlider's cell reports a
/// knob rect for a zero-width control ((-10,-8,20,16) at every width, measured), so a comparison made
/// there would be against nothing.
@MainActor
final class PlayheadSliderTests: XCTestCase {
    private let widths: [CGFloat] = [120, 180, 240, 333.5, 480, 640, 760, 1024, 1400]
    private let values: [Double] = [0, 0.001, 0.1, 0.25, 0.3333, 0.5, 0.75, 0.9, 0.999, 1]
    private let yellow = NSColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1)
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func host(_ v: NSView, width: CGFloat, height: CGFloat = 16) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 20, height: 40),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView!.addSubview(v)
        v.frame = NSRect(x: 10, y: 10, width: width, height: height)
        v.layoutSubtreeIfNeeded()
        windows.append(win)
    }

    private func stockSlider(width: CGFloat, value: Double = 0) -> NSSlider {
        let s = NSSlider(value: value, minValue: 0, maxValue: 1, target: nil, action: nil)
        host(s, width: width)
        return s
    }

    private func swiftUISlider(width: CGFloat, value: Double) -> NSView {
        let h = NSHostingView(rootView: Slider(value: .constant(value), in: 0...1))
        host(h, width: width)
        return h
    }

    private func scrubber(width: CGFloat, style: PlayheadStyle, value: Double = 0) -> PlayheadScrubber {
        let s = PlayheadScrubber(frame: .zero)
        s.style = style
        s.lineColor = yellow
        host(s, width: width)
        s.set(value: value, range: 0...1)
        return s
    }

    /// The control as drawn, at 2× (the Studio's displays are 2×).
    private func render(_ v: NSView) -> NSBitmapImageRep {
        v.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((v.bounds.width * 2).rounded()),
                                   pixelsHigh: Int(v.bounds.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    private func differingBytes(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        let n = a.bytesPerRow * a.pixelsHigh
        guard n == b.bytesPerRow * b.pixelsHigh else { return -1 }
        var d = 0
        for i in 0..<n where a.bitmapData![i] != b.bitmapData![i] { d += 1 }
        return d
    }

    /// The drawn knob's centre in points: the alpha-weighted centroid of one pixel row two points above
    /// the control's bottom edge. That row crosses the ball and the line and misses the track (5…11 pt).
    private func drawnCentre(_ rep: NSBitmapImageRep) -> CGFloat? {
        let y = rep.pixelsHigh - 4
        var sum = 0.0, weight = 0.0
        for x in 0..<rep.pixelsWide {
            let a = Double(rep.colorAt(x: x, y: y)!.alphaComponent)
            guard a > 0.3 else { continue }
            sum += (Double(x) + 0.5) * a
            weight += a
        }
        return weight > 0 ? CGFloat(sum / weight / 2) : nil
    }

    // MARK: 1 — centre

    /// As DRAWN: the line's centre against the ball's, the same control at the same width in the two
    /// styles, on rendered pixels at 2×.
    func testDrawnLineCentreIsDrawnBallCentre() {
        var worst: CGFloat = 0
        var measured = 0
        for w in widths {
            let ball = scrubber(width: w, style: .ball)
            let line = scrubber(width: w, style: .line)
            for v in values {
                ball.set(value: v, range: 0...1)
                line.set(value: v, range: 0...1)
                guard let b = drawnCentre(render(ball)), let l = drawnCentre(render(line)) else {
                    return XCTFail("nothing drawn at w=\(w) v=\(v)")
                }
                let d = abs(l - b)
                worst = max(worst, d)
                measured += 1
                XCTAssertLessThanOrEqual(d, 0.5, "w=\(w) v=\(v) ball=\(b) line=\(l)")
            }
        }
        print("[PLAYHEAD] drawn centres: worst |line − ball| = \(worst) pt over \(measured) renders, \(widths.count) widths")
    }

    /// The line is drawn at the UNROUNDED position; the ball's knob rect is snapped to whole points.
    /// So line − knob centre is the rounding and nothing else: ≤ 0.5 pt, and the tab shares the line's x.
    func testLineSitsAtTheUnroundedPosition() {
        var worst: CGFloat = 0
        for w in widths {
            let s = scrubber(width: w, style: .line)
            for v in values {
                s.set(value: v, range: 0...1)
                let k = s.knobRect, x = s.lineCentreX
                // The click mapping's position, over the whole-point width the slider is given.
                XCTAssertEqual(x, 10 + CGFloat(v) * (w.rounded(.down) - 20), accuracy: 1e-9, "w=\(w) v=\(v)")
                XCTAssertEqual(k.midX, k.midX.rounded(), "the knob rect is whole-point snapped")
                XCTAssertLessThanOrEqual(abs(x - k.midX), 0.5)
                worst = max(worst, abs(x - k.midX))
                XCTAssertEqual(PlayheadLineMetrics.lineRect(centreX: x, knobRect: k).midX, x, accuracy: 1e-9)
                XCTAssertEqual(PlayheadLineMetrics.tabPath(centreX: x, knobRect: k, flipped: true).bounds.midX, x, accuracy: 1e-9)
            }
        }
        print("[PLAYHEAD] geometry: worst |line − snapped knob centre| = \(worst) pt")
    }

    /// The round trip that makes the line exact: the value a click at the line's centre gives is the
    /// value the line was drawn for (the ball's centre cannot promise this; it is snapped).
    func testClickOnTheLineLandsOnItsValue() {
        var worst = 0.0
        for w in widths {
            let s = scrubber(width: w, style: .line)
            for v in values + [0.123456, 0.6180339, 0.987654] {
                s.set(value: v, range: 0...1)
                let got = s.beginLineTrack(at: 0).clickValue(at: s.lineCentreX)
                worst = max(worst, abs(got - v))
                XCTAssertEqual(got, v, accuracy: 1e-9, "w=\(w) v=\(v)")
            }
        }
        print("[PLAYHEAD] click at line centre → value: worst error \(worst) (1.0 = whole clip)")
    }

    // MARK: 2 — click and drag

    // ⚠️ NO TEST HERE DRIVES `NSSliderCell`'S TRACKING API AS A REFERENCE. It was tried and is not one:
    // outside a real event loop, after its first session the cell's knob rect stays stuck and a click at
    // x = 100 on a 120 pt slider returned 0.5, then 0.0, for an expected 0.9 (measured 2026-10-16). The
    // stock click mapping is measured instead in the app, with real events, Ball against Line, at full
    // precision through accessibility while the button is down.

    /// Where a click goes: Ball → the visible slider; Line → the scrubber (which drives the hidden
    /// slider's cell), across the full height and along the whole track including the floored-off
    /// remainder. The line view takes nothing.
    func testHitTestingIsTheSameInBothStyles() {
        let w: CGFloat = 480.75
        for style in PlayheadStyle.allCases {
            let s = scrubber(width: w, style: style, value: 0.4)
            let parent = s.superview!
            for x in Array(stride(from: 0, through: w - 1, by: 7) as StrideThrough<CGFloat>) + [480.5] {
                for y in [0.5, 4, 8, 12, 15.5] as [CGFloat] {
                    let p = parent.convert(NSPoint(x: x, y: y), from: s)
                    let expected: NSView = style == .ball ? s.slider : s
                    XCTAssertTrue(parent.hitTest(p) === expected, "style=\(style) x=\(x) y=\(y)")
                }
            }
        }
    }

    /// Both styles carry a STOCK cell: the measured reason a cell subclass is not used.
    func testSliderKeepsTheStockCell() {
        XCTAssertTrue(type(of: PlayheadScrubber(frame: .zero).slider.cell!) == NSSliderCell.self)
    }

    /// A press on the playhead must never start a window drag (the player window moves by background).
    func testDeclinesWindowMove() {
        for style in PlayheadStyle.allCases {
            let s = scrubber(width: 400, style: style)
            XCTAssertFalse(s.mouseDownCanMoveWindow)
            XCTAssertFalse(s.slider.mouseDownCanMoveWindow)
            for v in s.subviews { XCTAssertFalse(v.mouseDownCanMoveWindow, "\(type(of: v))") }
        }
    }

    /// Line hides the slider (nothing of the glass knob can render); Ball shows it.
    func testLineHidesTheSlider() {
        let s = scrubber(width: 400, style: .line, value: 0.3)
        XCTAssertTrue(s.slider.isHidden)
        s.style = .ball
        XCTAssertFalse(s.slider.isHidden)
    }

    /// The Line tracker's rules, at every width and starting value: a press ON the playhead (its
    /// snapped knob rect) holds the value; a press OFF it jumps to the stock click mapping; a drag gives,
    /// at every x, what a click there gives — overshoot both ends included, clamped to the range — and
    /// the line is then drawn under the pointer.
    func testLineTrackRules() {
        var checked = 0
        var worstUnderPointer: CGFloat = 0
        for w in widths {
            let s = scrubber(width: w, style: .line)
            let fw = w.rounded(.down)
            for v0 in [0.0, 0.2, 0.5, 0.83, 1.0] {
                s.set(value: v0, range: 0...1)
                let k = s.knobRect
                for press in [k.midX, k.minX + 0.5, k.maxX - 0.5, k.minX - 0.5, k.maxX + 0.5, w * 0.1, w * 0.62, w - 1] as [CGFloat] {
                    s.set(value: v0, range: 0...1)
                    var track = s.beginLineTrack(at: press)
                    XCTAssertEqual(track.grabbed, press >= k.minX && press < k.maxX)
                    let atPress = track.value(at: press)
                    if track.grabbed {
                        XCTAssertEqual(atPress, v0, "a press on the playhead must not move it")
                    } else {
                        XCTAssertEqual(atPress, min(max(Double((press - 10) / (fw - 20)), 0), 1), accuracy: 1e-12)
                    }
                    for x in [press + 3, press - 40.5, -50, press, w + 60, w * 0.3, press + 0.25] as [CGFloat] {
                        let v = track.value(at: x)
                        XCTAssertEqual(v, min(max(Double((x - 10) / (fw - 20)), 0), 1), accuracy: 1e-12, "w=\(w) x=\(x)")
                        XCTAssertEqual(v, track.clickValue(at: x))
                        s.set(value: v, range: 0...1)
                        let target = min(max(x, 10), fw - 10)
                        worstUnderPointer = max(worstUnderPointer, abs(s.lineCentreX - target))
                        XCTAssertEqual(s.lineCentreX, target, accuracy: 1e-6, "line under pointer w=\(w) x=\(x)")
                        checked += 1
                    }
                }
            }
        }
        print("[PLAYHEAD] Line tracker: \(checked) drag points = click mapping; line under pointer within \(worstUnderPointer) pt")
    }

    /// Any range, not just 0…1: the transport's is 0…duration.
    func testLineTrackOverAClipRange() {
        let s = scrubber(width: 641.5, style: .line)
        s.set(value: 12.5, range: 0...3600)
        var t = s.beginLineTrack(at: 400)
        XCTAssertFalse(t.grabbed)
        XCTAssertEqual(t.value(at: 400), (400 - 10) / (641 - 20) * 3600, accuracy: 1e-9)
        XCTAssertEqual(t.value(at: -5), 0)
        XCTAssertEqual(t.value(at: 9999), 3600)
    }

    // MARK: 3 — nothing else changes

    /// Ball is the ball testers have today: byte-identical to the SwiftUI Slider it replaces and to a
    /// stock NSSlider. At whole-point widths only: at a fractional width the scrubber floors the
    /// slider (see `PlayheadScrubber`), which moves today's ball by up to its own sub-point error.
    func testBallRendersAsTodaysSlider() {
        for w in [120, 333, 760, 1400] as [CGFloat] {
            for v in [0, 0.37, 1] as [Double] {
                let ours = render(scrubber(width: w, style: .ball, value: v))
                XCTAssertEqual(differingBytes(ours, render(stockSlider(width: w, value: v))), 0, "vs stock w=\(w) v=\(v)")
                XCTAssertEqual(differingBytes(ours, render(swiftUISlider(width: w, value: v))), 0, "vs SwiftUI w=\(w) v=\(v)")
            }
        }
    }

    func testHeightIsTheSwiftUISlidersHeight() {
        let host = NSHostingView(rootView: Slider(value: .constant(0.5), in: 0...1).frame(width: 400))
        let swiftUIHeight = host.fittingSize.height
        for style in PlayheadStyle.allCases {
            let s = PlayheadScrubber(frame: .zero)
            s.style = style
            XCTAssertEqual(s.intrinsicContentSize.height, swiftUIHeight, "style=\(style)")
        }
        print("[PLAYHEAD] height: SwiftUI Slider \(swiftUIHeight) pt = scrubber (both styles)")
    }

    /// Flipping style on a live control moves nothing: value, knob rect, intrinsic size.
    func testSwitchingStyleChangesNoState() {
        for w in widths {
            let s = scrubber(width: w, style: .ball, value: 0.4)
            let before = (s.doubleValue, s.knobRect, s.intrinsicContentSize, s.slider.frame)
            XCTAssertEqual(s.slider.frame.width, w.rounded(.down))
            for style in [PlayheadStyle.line, .ball, .line] {
                s.style = style
                s.layoutSubtreeIfNeeded()
                XCTAssertEqual(s.doubleValue, before.0)
                XCTAssertEqual(s.knobRect, before.1)
                XCTAssertEqual(s.intrinsicContentSize, before.2)
                XCTAssertEqual(s.slider.frame, before.3)
            }
        }
    }

    /// The owner's value reaches the control when the user is not holding it.
    func testSetValueAppliesWhenNotTracking() {
        let s = scrubber(width: 400, style: .line, value: 0.2)
        s.set(value: 0.6, range: 0...1)
        XCTAssertEqual(s.doubleValue, 0.6)
        XCTAssertFalse(s.isTracking)
    }

    func testDisabledLineIsGrey() {
        let s = scrubber(width: 400, style: .line, value: 0.5)
        s.isEnabled = false
        let rep = render(s)
        let c = rep.colorAt(x: Int(s.knobRect.midX * 2), y: rep.pixelsHigh - 4)!.usingColorSpace(.sRGB)!
        // Grey (equal channels), not yellow.
        XCTAssertEqual(c.redComponent, c.blueComponent, accuracy: 0.02)
    }

    func testDefaults() {
        XCTAssertEqual(PlayheadStyle.defaultStyle, .line)
        XCTAssertEqual(PlayheadStyle(rawValue: "ball"), .ball)
        XCTAssertEqual(PlayheadStyle(rawValue: "line"), .line)
        XCTAssertEqual(PlayheadStyle.defaultColorHex, "FFE600")
        XCTAssertEqual(PlayheadStyle.defaultsKey, "manifold.playhead.style")
    }

    /// The app's one yellow (Robbie, 2026-10-25) is #FFE600 in sRGB, and the playhead's default is it, not
    /// `systemYellow`.
    func testAppYellowIsThePlayheadDefault() {
        XCTAssertEqual(AppYellow.hex, "FFE600")
        XCTAssertEqual(PlayheadStyle.defaultColorHex, AppYellow.hex)
        for c in [AppYellow.nsColor, PlayheadScrubber(frame: .zero).lineColor] {
            let s = c.usingColorSpace(.sRGB)!
            XCTAssertEqual(s.redComponent, 1, accuracy: 1e-6)
            XCTAssertEqual(s.greenComponent, 230.0 / 255, accuracy: 1e-6)
            XCTAssertEqual(s.blueComponent, 0, accuracy: 1e-6)
        }
    }

    /// The text variant: #FFE600 in dark, #645A00 in light, the light one ≥ 4.5:1 (WCAG) against white, #ECECEC and
    /// #D0D0D0, and the same hue as the yellow.
    func testAppYellowTextVariant() {
        func resolved(_ name: NSAppearance.Name) -> NSColor {
            var out = NSColor.clear
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                out = AppYellow.textNSColor.usingColorSpace(.sRGB)!
            }
            return out
        }
        func lum(_ c: NSColor) -> Double {
            func l(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * l(c.redComponent) + 0.7152 * l(c.greenComponent) + 0.0722 * l(c.blueComponent)
        }
        let dark = resolved(.darkAqua), light = resolved(.aqua)
        XCTAssertEqual(dark.greenComponent, 230.0 / 255, accuracy: 1e-6)
        XCTAssertEqual(light.redComponent, 0x64 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(light.greenComponent, 0x5A / 255.0, accuracy: 1e-6)
        XCTAssertEqual(light.greenComponent / light.redComponent, 230.0 / 255, accuracy: 0.01, "same hue")
        for grey in [1.0, 236.0 / 255, 208.0 / 255] {
            let bg = lum(NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1))
            XCTAssertGreaterThanOrEqual((bg + 0.05) / (lum(light) + 0.05), 4.5, "on grey \(grey)")
        }
    }
}
