import XCTest
import AppKit
@testable import PlayheadSlider

/// The chapter flag style (docs/CHAPTER_MARKERS_PLAN.md §4.1, §6.4; Stage 2): `.outline` draws a 1 pt stroke with no fill
/// and NO BAND; a filled flag at the same x is drawn over it and takes the click; filled flags draw as before.
@MainActor
final class MarkerTrackStyleTests: XCTestCase {
    private var windows: [NSWindow] = []
    private let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func scrubber(_ markers: [TrackMarker], width: CGFloat = 400) -> PlayheadScrubber {
        let s = PlayheadScrubber(frame: .zero)
        s.style = .ball
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 20, height: 40),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView!.addSubview(s)
        s.frame = NSRect(x: 10, y: 10, width: width, height: s.intrinsicContentSize.height)
        s.layoutSubtreeIfNeeded()
        windows.append(win)
        s.set(value: 0, range: 0...1)
        s.markers = markers
        s.layoutSubtreeIfNeeded()
        return s
    }

    private func track(_ s: PlayheadScrubber) -> MarkerTrackView { s.subviews.compactMap { $0 as? MarkerTrackView }.first! }

    private func render(_ v: NSView) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((v.bounds.width * 2).rounded()),
                                   pixelsHigh: Int((v.bounds.height * 2).rounded()), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    private func bytes(_ r: NSBitmapImageRep) -> [UInt8] { Array(UnsafeBufferPointer(start: r.bitmapData!, count: r.bytesPerRow * r.pixelsHigh)) }

    /// The pixel at a point of the marker track (flipped), in a render of the scrubber.
    private func pixel(_ rep: NSBitmapImageRep, _ s: PlayheadScrubber, _ p: NSPoint) -> [CGFloat] {
        let q = s.convert(p, from: track(s))
        let y = s.isFlipped ? q.y : s.bounds.height - q.y
        guard let c = rep.colorAt(x: Int(q.x * 2), y: Int(y * 2)) else {
            XCTFail("\(p) is outside the control"); return []
        }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { ($0 * 255).rounded() }
    }

    /// The middle of the flag drawn for `value`: inside its fill, clear of its edge.
    private func flagMiddle(_ s: PlayheadScrubber, _ value: Double) -> NSPoint {
        let top = max(0, s.markerBarRect.minY - MarkerTrackView.flagHeight - 1)
        return NSPoint(x: s.centreX(for: value), y: top + MarkerTrackView.flagHeight * 0.3)
    }

    func testOutlineHasNoBand() {
        // An outlined chapter whose stated span is 0.2…0.6 draws exactly as one with no span: no band.
        let spanned = scrubber([TrackMarker(start: 0.2, end: 0.6, color: red, label: "", style: .outline)])
        let point = scrubber([TrackMarker(start: 0.2, end: 0.2, color: red, label: "", style: .outline)])
        XCTAssertEqual(bytes(render(spanned)), bytes(render(point)))
        // A filled marker with the same span does draw one (so the comparison above can fail).
        let filled = scrubber([TrackMarker(start: 0.2, end: 0.6, color: red, label: "")])
        let filledPoint = scrubber([TrackMarker(start: 0.2, end: 0.2, color: red, label: "")])
        XCTAssertNotEqual(bytes(render(filled)), bytes(render(filledPoint)))
    }

    func testOutlineHasNoFillButIsDrawn() {
        let none = scrubber([])
        let outline = scrubber([TrackMarker(start: 0.5, end: 0.5, color: red, label: "", style: .outline)])
        let filled = scrubber([TrackMarker(start: 0.5, end: 0.5, color: red, label: "")])
        let mid = flagMiddle(outline, 0.5)
        XCTAssertEqual(pixel(render(outline), outline, mid), pixel(render(none), none, mid), "the outline's middle is not filled")
        XCTAssertNotEqual(pixel(render(filled), filled, mid), pixel(render(none), none, mid), "a filled flag's middle is")
        XCTAssertNotEqual(bytes(render(outline)), bytes(render(none)), "the stroke is drawn")
    }

    func testFilledFlagIsDrawnOverAnOutlineOnTheSameFrame() {
        // Whatever the array order, the filled flag's middle is the filled flag's colour.
        let alone = scrubber([TrackMarker(start: 0.5, end: 0.5, color: red, label: "")])
        let mid = flagMiddle(alone, 0.5)
        let want = pixel(render(alone), alone, mid)
        for order in [[0, 1], [1, 0]] {
            let items = [TrackMarker(start: 0.5, end: 0.5, color: .white, label: "", style: .outline),
                         TrackMarker(start: 0.5, end: 0.5, color: red, label: "")]
            let s = scrubber(order.map { items[$0] })
            XCTAssertEqual(pixel(render(s), s, mid), want, "order \(order)")
        }
    }

    func testAClickOnTheSameFrameTakesTheFilledFlag() {
        let outline = TrackMarker(start: 0.5, end: 0.5, color: .white, label: "", style: .outline)
        let filled = TrackMarker(start: 0.5, end: 0.5, color: red, label: "")
        for (markers, want) in [([outline, filled], 1), ([filled, outline], 0)] {
            let s = scrubber(markers)
            XCTAssertEqual(track(s).flagIndex(at: flagMiddle(s, 0.5)), want)
        }
        // An outline on its own still takes its click (a chapter jumps).
        let s = scrubber([outline])
        XCTAssertEqual(track(s).flagIndex(at: flagMiddle(s, 0.5)), 0)
    }

    func testFilledFlagsAreUnchangedByOutlinesElsewhere() {
        // A filled marker at 0.25 renders the same around itself with or without an outlined chapter at 0.75.
        let filled = TrackMarker(start: 0.25, end: 0.3, color: red, label: "")
        let a = scrubber([filled])
        let b = scrubber([TrackMarker(start: 0.75, end: 0.75, color: .white, label: "", style: .outline), filled])
        let ra = render(a), rb = render(b)
        let top = max(0, a.markerBarRect.minY - MarkerTrackView.flagHeight - 1)
        let x0 = a.centreX(for: 0.25)
        for dx in stride(from: -5.0, through: 5.0, by: 0.5) {
            for y in stride(from: max(0, top - 1), through: min(a.bounds.height - 0.5, a.markerBarRect.minY + 1), by: 0.5) {
                let p = NSPoint(x: x0 + dx, y: y)
                XCTAssertEqual(pixel(ra, a, p), pixel(rb, b, p), "at \(p)")
            }
        }
    }

    func testDefaultStyleIsFilled() {
        XCTAssertEqual(TrackMarker(start: 0, end: 1, color: red, label: "").style, .filled)
    }
}
