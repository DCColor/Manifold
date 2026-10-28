import AppKit
import Observation

/// How the transport bar draws its playhead (2026-10-16). Testers said the round ball felt less
/// accurate than a line, which is what an NLE draws: a ball covers 20 pt of timeline and says nothing
/// about where in that 20 pt the frame is, while a line says it to the point.
public enum PlayheadStyle: String, CaseIterable, Identifiable {
    case ball
    case line

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ball: return "Ball"
        case .line: return "Line"
        }
    }

    /// One spelling of the key, read by Settings and by the scrubber.
    public static let defaultsKey = "manifold.playhead.style"
    /// LINE, because it is what testers asked for. A new key, so no install has a stored value and
    /// every one gets this until someone picks Ball in Settings.
    public static let defaultStyle: PlayheadStyle = .line

    /// The line's colour, as the app's usual 6-digit hex (see `ScopeColorCodec`). Since 2026-10-27 the
    /// playhead's OVERRIDE of the highlight colour: read only when `followsHighlight` says it is not following.
    public static let colorDefaultsKey = "manifold.playhead.lineColor"
    /// The app's yellow (`AppYellow.hex`), which started here: the value this key's absence used to mean.
    public static let defaultColorHex = AppYellow.hex

    /// "Playhead color: Same as highlight | Custom" (Robbie, 2026-10-27). Written only when the user picks one;
    /// until then `followsHighlight` infers the choice from `colorDefaultsKey`, so no existing value is migrated.
    public static let followsHighlightKey = "manifold.playhead.followsHighlight"

    /// Whether the playhead takes the highlight colour. An explicit choice wins. Otherwise: no stored colour, or
    /// the old default #FFE600 (what following looked like before the highlight existed), follows; any other
    /// stored colour is a customisation and stays the playhead's own.
    public static func followsHighlight(storedColor: String?, explicit: Bool?) -> Bool {
        if let explicit { return explicit }
        guard let stored = storedColor.flatMap(AppYellow.normalised) else { return true }
        return stored == defaultColorHex
    }

    /// The playhead's colour, as hex: the highlight when following, otherwise the stored colour.
    public static func lineHex(storedColor: String?, explicit: Bool?, highlight: String) -> String {
        guard !followsHighlight(storedColor: storedColor, explicit: explicit),
              let stored = storedColor.flatMap(AppYellow.normalised) else { return highlight }
        return stored
    }
}

/// THE APP'S ONE HIGHLIGHT COLOUR (Robbie, 2026-10-25; the user's since 2026-10-27): #FFE600 unless
/// Settings ▸ General ▸ Highlight color says otherwise. It marks something the user has turned on or
/// asserted: the pin when pinned, the playhead, an override's and an applied LUT's words and readouts, the
/// hold-to-compare badge, the field-view marker, Loop when on. Green is kept for LIVE only (DeckLink
/// output running, a connected stream), and no setting changes it. Nothing follows the macOS accent colour.
///
/// A lemon rather than `systemYellow`, and not the system orange: amber is what a WARNING wears (the Bypass
/// badge), and a yellow near it in hue would read as one more warning. #FFE600 sits at ~54°, systemOrange
/// at ~36°.
///
/// Every use reads `AppHighlight.shared` (the stored choice); the constants here are the default.
public enum AppYellow {
    /// The default, in the app's usual 6-digit hex (see `ScopeColorCodec`).
    public static let hex = "FFE600"
    /// The highlight colour, as hex. Absent means `hex`.
    public static let defaultsKey = "manifold.highlightColor"

    /// TEXT on a background that follows the appearance (the chain readout), in LIGHT appearance only (Robbie,
    /// 2026-10-26): #FFE600 is 1.3:1 on white. The same hue darkened to the first value with ≥ 4.5:1 against #D0D0D0,
    /// darker than a light popover: 6.99:1 on white, 5.92:1 on #ECECEC, 4.53:1 on #D0D0D0. Icons, the playhead, the
    /// pin and Loop stay the highlight in both appearances, and so does text on the always-dark control bar.
    /// `textOnLight(_:)` derives it for any highlight; this is its value for the default.
    public static let textOnLightHex = "645A00"

    /// The default's colour. `AppHighlight.shared.nsColor` is the one every use draws.
    public static var nsColor: NSColor { srgb(hex) }
    /// The default's text variant. `AppHighlight.shared.textNSColor` is the one every use draws.
    public static var textNSColor: NSColor { textNSColor(for: hex) }

    /// For text whose background follows the appearance: the colour in dark, `textOnLight` of it in light.
    public static func textNSColor(for hex: String) -> NSColor {
        let dark = srgb(hex), light = srgb(textOnLight(hex))
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// THE LIGHT-APPEARANCE TEXT RULE, for any highlight: keep the hue and scale the three sRGB channels down
    /// together, a step of 1/255 on the largest at a time, to the first value with ≥ 4.5:1 (WCAG) against
    /// #D0D0D0, the darkest light background it is drawn on. A colour that already has 4.5:1 is kept as it is.
    /// For #FFE600 this gives #645A00, the hand-picked value it replaces.
    public static func textOnLight(_ hex: String) -> String {
        let c = rgb255(normalised(hex) ?? Self.hex)
        let top = max(c.r, c.g, c.b)
        guard top > 0 else { return encode(c) }
        let background = luminance((208, 208, 208))
        for n in stride(from: top, through: 0, by: -1) {
            let k = Double(n) / Double(top)
            let d = (r: Int((Double(c.r) * k).rounded()), g: Int((Double(c.g) * k).rounded()),
                     b: Int((Double(c.b) * k).rounded()))
            if (background + 0.05) / (luminance(d) + 0.05) >= 4.5 { return encode(d) }
        }
        return "000000"
    }

    /// Whether a highlight is close enough to the live green to be confused with it: hue within 100°–170°
    /// (the system green is ~130°–135° in both appearances), saturation and brightness at least 0.3, so greys
    /// and near-blacks are not "green". Settings shows a one-line note when it is.
    public static func isNearLiveGreen(_ hex: String) -> Bool {
        let c = rgb255(normalised(hex) ?? Self.hex)
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let hi = max(r, g, b), lo = min(r, g, b), delta = hi - lo
        guard hi >= 0.3, hi > 0, delta / hi >= 0.3 else { return false }
        var hue: Double
        if hi == r { hue = 60 * ((g - b) / delta) } else if hi == g { hue = 60 * ((b - r) / delta) + 120 }
        else { hue = 60 * ((r - g) / delta) + 240 }
        if hue < 0 { hue += 360 }
        return (100...170).contains(hue)
    }

    /// Six hex digits, upper case, without a leading "#"; nil for anything else.
    public static func normalised(_ hex: String) -> String? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        return s.uppercased()
    }

    static func srgb(_ hex: String) -> NSColor {
        let c = rgb255(hex)
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    private static func rgb255(_ hex: String) -> (r: Int, g: Int, b: Int) {
        let v = Int(hex, radix: 16) ?? 0
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }
    private static func encode(_ c: (r: Int, g: Int, b: Int)) -> String { String(format: "%02X%02X%02X", c.r, c.g, c.b) }
    private static func luminance(_ c: (r: Int, g: Int, b: Int)) -> Double {
        func l(_ v: Int) -> Double { let v = Double(v) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * l(c.r) + 0.7152 * l(c.g) + 0.0722 * l(c.b)
    }
}

/// The highlight colour as the app draws it: the stored choice (`AppYellow.defaultsKey`), observed, so every
/// SwiftUI view that reads it during its body redraws when it changes. Settings writes it through `set`; a write to
/// the key from anywhere else in the process is picked up from `UserDefaults.didChangeNotification`.
///
/// ⚠️ MAIN THREAD ONLY: it is read by view bodies and written by Settings.
@Observable
public final class AppHighlight {
    public static let shared = AppHighlight(defaults: .standard)

    /// Normalised hex; `AppYellow.hex` when the key is absent or not a colour.
    public private(set) var hex: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        hex = Self.read(defaults)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: defaults, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    public var nsColor: NSColor { AppYellow.srgb(hex) }
    public var textNSColor: NSColor { AppYellow.textNSColor(for: hex) }
    public var isNearLiveGreen: Bool { AppYellow.isNearLiveGreen(hex) }

    /// Stores a new highlight. Nothing is written unless it differs from what is stored.
    public func set(_ newHex: String) {
        guard let value = AppYellow.normalised(newHex), value != hex else { return }
        defaults.set(value, forKey: AppYellow.defaultsKey)
        hex = value
    }

    /// Re-reads the key; assigns only on a change, so an unrelated defaults write redraws nothing.
    public func reload() {
        let value = Self.read(defaults)
        if value != hex { hex = value }
    }

    private static func read(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: AppYellow.defaultsKey).flatMap(AppYellow.normalised) ?? AppYellow.hex
    }
}

/// The line playhead's measurements, in points. Public so the tests read the numbers the drawing uses.
public enum PlayheadLineMetrics {
    /// Bold: the width an NLE playhead reads at, and well clear of the 6 pt track's hairline look.
    public static let lineWidth: CGFloat = 3
    /// The grab tab at the top: wide enough to see and aim at, narrower than the ball it replaces.
    public static let tabWidth: CGFloat = 11
    public static let tabHeight: CGFloat = 6
    /// The tab's pointed part, below its square part.
    public static let tabPoint: CGFloat = 3
    /// The track, drawn in white whatever the appearance: the transport bar is always on black (the
    /// HUD's 0.55, the docked bar's 0.85), and the system's light-mode track is black on black.
    public static let trackAlpha: CGFloat = 0.15
    /// The played part of the track. WHITE, NOT THE ACCENT COLOUR the system slider fills with: with a
    /// yellow accent (seen on the Studio, 2026-10-16) an accent fill runs straight into a yellow line
    /// and the playhead stops reading as a line.
    public static let playedAlpha: CGFloat = 0.45
    /// Colour of line and played track when the control is disabled (a live stream, or another window
    /// owns playback): the same 0.35 white the transport row greys its other position controls with.
    public static let disabledAlpha: CGFloat = 0.35

    /// The line's rectangle: centred EXACTLY on `centreX`, the knob's full height so it crosses the
    /// track. No pixel rounding — the centre is the whole point.
    public static func lineRect(centreX: CGFloat, knobRect: NSRect) -> NSRect {
        NSRect(x: centreX - lineWidth / 2, y: knobRect.minY, width: lineWidth, height: knobRect.height)
    }

    /// The tab: a downward-pointing pentagon at the TOP of the knob rect, centred on the line.
    /// `flipped` is the drawing view's, so "top" is the visual top either way.
    public static func tabPath(centreX cx: CGFloat, knobRect: NSRect, flipped: Bool) -> NSBezierPath {
        let half = tabWidth / 2
        let top = flipped ? knobRect.minY : knobRect.maxY
        let down: CGFloat = flipped ? 1 : -1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx - half, y: top))
        path.line(to: NSPoint(x: cx + half, y: top))
        path.line(to: NSPoint(x: cx + half, y: top + down * (tabHeight - tabPoint)))
        path.line(to: NSPoint(x: cx, y: top + down * tabHeight))
        path.line(to: NSPoint(x: cx - half, y: top + down * (tabHeight - tabPoint)))
        path.close()
        return path
    }
}

/// The transport bar's scrubber, in either playhead style.
///
/// ⚠️ ONE STOCK NSSlider DOES ALL THE WORK IN BOTH STYLES, AND THE STYLE IS PAINT ONLY. The obvious
/// build, an `NSSliderCell` subclass overriding `drawKnob`, was tried and measured wrong: on macOS 26
/// a cell that overrides drawing drops the whole control to AppKit's legacy path, which draws a
/// different ball (2 841+ bytes differ at 2×) AND maps x to value differently — `(x−12.5)/(w−25)`
/// against the stock `(x−10)/(w−20)` — so a click would land on a different frame per style.
///
/// So the slider keeps the STOCK cell. Ball shows it as it is: byte-identical to the SwiftUI `Slider`
/// this replaced, taking its own mouse events. Line HIDES it, and a view above it that takes no clicks
/// draws the track and the line from that slider's OWN `knobRect`/`barRect`. The scrubber then takes
/// the mouse itself and moves the slider's value with the stock control's click mapping (`LineTrack`),
/// so a click lands on the same frame in both styles (measured against the cell in the tests, and
/// Line against Ball in the app). A drag does not quite: see `LineTrack` for the Ball's own drag quirk
/// and why the Line does not copy it.
///
/// ⚠️ HIDDEN, NOT TRANSPARENT, AND BOTH CHEAPER ROUTES WERE TRIED AND SEEN TO FAIL ON macOS 26. The
/// modern knob is a glass lens built from `CABackdropLayer`/SDF portal layers, which the window server
/// composites WITHOUT the ancestors' opacity: at alpha 0 the ball vanished at rest but its lifted lens
/// came back around the line for the whole of a drag. A layer mask hid the track and not the lens,
/// and left a focus ring around the invisible knob after release. A hidden slider renders nothing —
/// so long as nothing drives its cell's tracking (see `mouseDown`).
///
/// ⚠️ THE LINE IS NOT DRAWN AT THE KNOB RECT'S CENTRE, AND THAT IS THE ACCURACY FIX ITSELF. AppKit
/// snaps the knob rect to whole points — the ball sits at `round(10 + f·(w−20))` — while a click maps
/// x to value continuously, `(x−10)/(w−20)`. So the ball can stand up to half a point off the frame it
/// shows, and a click on its centre can land on a neighbouring value. The line is drawn at the
/// UNROUNDED position, the one a click there maps back to (`lineCentreX`; the round trip is tested).
/// It is therefore within 0.5 pt of the ball by construction, and exactly on the frame.
///
/// ⚠️ …WHICH HOLDS ONLY AT A WHOLE-POINT WIDTH, SO THE SLIDER IS GIVEN ONE. At a fractional width
/// AppKit disagrees with itself: the bar (and so the click mapping) is laid out on the width rounded
/// UP — 333.5 pt tracks over 334 — while the knob is placed from the fractional bounds. Measured, the
/// stock ball then stands up to 0.69 pt from the value it shows. SwiftUI hands this view fractional
/// widths (the readouts beside it are text), so `layout()` floors the slider's width, in both styles.
/// The sub-point remainder still belongs to the slider through `hitTest`.
public final class PlayheadScrubber: NSView {
    public let slider = TrackingSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let lineView = PlayheadLineView()

    /// Every value the user's gesture produces, from click to release.
    public var onValueChanged: ((Double) -> Void)?
    /// The gesture's begin/end bracket (`Slider.onEditingChanged`'s contract).
    public var onEditingChanged: ((Bool) -> Void)? {
        get { slider.onEditingChanged }
        set { slider.onEditingChanged = newValue }
    }

    public var style: PlayheadStyle = PlayheadStyle.defaultStyle {
        didSet { if style != oldValue { applyStyle() } }
    }
    public var lineColor: NSColor = AppYellow.nsColor {
        didSet { lineView.needsDisplay = true }
    }

    public var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            guard newValue != slider.isEnabled else { return }
            slider.isEnabled = newValue
            lineView.needsDisplay = true
        }
    }

    public var isTracking: Bool { slider.isTracking || lineTracking }
    /// The Line style's own gesture (see `mouseDown`).
    private var lineTracking = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        lineView.scrubber = self
        addSubview(slider)
        addSubview(lineView)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Range and value together, from the owner. Not while the user holds the control: the engine's
    /// time must not pull the knob out from under the pointer.
    public func set(value: Double, range: ClosedRange<Double>) {
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        guard !isTracking, slider.doubleValue != value else { return }
        slider.doubleValue = value
        lineView.needsDisplay = true
    }

    public var doubleValue: Double { slider.doubleValue }

    @objc private func sliderMoved(_ sender: NSSlider) {
        lineView.needsDisplay = true
        onValueChanged?(sender.doubleValue)
    }

    private func applyStyle() {
        slider.isHidden = style == .line
        lineView.isHidden = style == .ball
        lineView.needsDisplay = true
    }

    public override var intrinsicContentSize: NSSize { slider.intrinsicContentSize }
    public override var isFlipped: Bool { true }
    /// ⚠️ LOAD-BEARING. The player window is movable by its background, and AppKit starts a WINDOW drag
    /// on a press over any view that answers true — which a non-opaque NSView does by default. In Line
    /// the press lands here, not on the slider (which declines), and dragging the playhead moved the
    /// window instead (seen 2026-10-16). Same trap as ContentView's `mouseDownCanMoveWindow` note.
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func layout() {
        super.layout()
        slider.frame = NSRect(x: 0, y: 0, width: bounds.width.rounded(.down), height: bounds.height)
        lineView.frame = slider.frame
    }

    /// Ball: the slider takes its own clicks, and the floored-off remainder (under a point, at the
    /// trailing end) is its too. Line: the slider is hidden, so every click in the scrubber is the
    /// scrubber's, and `mouseDown` hands it to the slider's cell.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self else { return hit }
        return style == .ball ? slider : self
    }

    /// The Line style's gesture, in the slider's coordinates, with the same bracket and per-move action
    /// as `TrackingSlider.mouseDown`. The values come from `LineTrack` — the stock slider's mapping, NOT
    /// its cell: driving the hidden slider's cell put the macOS 26 knob into its pressed state, and that
    /// lens rendered around the line although the slider was hidden (seen 2026-10-16).
    public override func mouseDown(with event: NSEvent) {
        guard style == .line, slider.isEnabled, let window else { return super.mouseDown(with: event) }
        lineTracking = true
        slider.onEditingChanged?(true)
        var track = beginLineTrack(at: slider.convert(event.locationInWindow, from: nil).x)
        apply(track.value(at: track.x0))
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            // The pointer's LIVE position, not the event's: what the stock slider follows (it tracked
            // correctly where posted drags' own `locationInWindow` stayed within 4 pt of the press while
            // the pointer crossed 230 — measured).
            apply(track.value(at: slider.convert(window.mouseLocationOutsideOfEventStream, from: nil).x))
            if next.type == .leftMouseUp { break }
        }
        lineTracking = false
        slider.onEditingChanged?(false)
    }

    private func apply(_ value: Double) {
        guard value != slider.doubleValue else { return }
        slider.doubleValue = value
        sliderMoved(slider)
    }

    /// One Line gesture's arithmetic. A press OFF the playhead jumps it to the pointer; a press ON it
    /// (the knob's whole-point-snapped rect, as the cell tests it) leaves the value alone until the
    /// pointer moves. While dragging, the line's centre follows the pointer: the value is the one a
    /// click at that x gives. So a drag and a click at the same x land on the same frame, and the line
    /// is drawn under the pointer (`lineCentreX` inverts the same mapping).
    ///
    /// ⚠️ THE BALL DOES NOT QUITE DO THIS, AND THE LINE DELIBERATELY DOES NOT COPY IT. Measured
    /// 2026-10-16 in the app: the macOS 26 slider follows the pointer while dragging too, but maps it
    /// over its PRESSED knob, a 25 pt lens — `(x−12.5)/(w−25)` — while its clicks map over the 20 pt
    /// knob, `(x−10)/(w−20)`. The Ball's drag and click therefore disagree by up to 2.5 pt near the
    /// track's ends (none at its middle). Copying that would put the line up to 2.5 pt off the pointer
    /// for the whole of a drag, which is the inaccuracy the Line exists to remove.
    public struct LineTrack {
        public let x0: CGFloat
        public let grabbed: Bool
        let v0: Double, minValue: Double, maxValue: Double
        let origin: CGFloat, travel: CGFloat
        private var moved = false

        init(x0: CGFloat, grabbed: Bool, v0: Double, minValue: Double, maxValue: Double,
             origin: CGFloat, travel: CGFloat) {
            self.x0 = x0; self.grabbed = grabbed; self.v0 = v0
            self.minValue = minValue; self.maxValue = maxValue; self.origin = origin; self.travel = travel
        }

        /// The value a click at `x` gives: the stock mapping, clamped to the range.
        public func clickValue(at x: CGFloat) -> Double {
            guard travel > 0 else { return minValue }
            return minValue + min(max(Double((x - origin) / travel), 0), 1) * (maxValue - minValue)
        }

        /// The gesture's value with the pointer at `x`.
        public mutating func value(at x: CGFloat) -> Double {
            if x != x0 { moved = true }
            return grabbed && !moved ? v0 : clickValue(at: x)
        }
    }

    public func beginLineTrack(at x: CGFloat) -> LineTrack {
        let bar = barRect, knob = knobRect
        return LineTrack(x0: x, grabbed: x >= knob.minX && x < knob.maxX,
                         v0: slider.doubleValue, minValue: slider.minValue, maxValue: slider.maxValue,
                         origin: bar.minX + knob.width / 2, travel: bar.width - knob.width)
    }

    // In Line the slider is hidden and so absent from the accessibility tree; the scrubber stands in.
    public override func isAccessibilityElement() -> Bool { style == .line }
    public override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    public override func accessibilityValue() -> Any? { slider.doubleValue }
    public override func isAccessibilityEnabled() -> Bool { slider.isEnabled }

    /// The knob rect in this view's coordinates: where the ball is, or would be.
    public var knobRect: NSRect {
        (slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped)
    }

    fileprivate var barRect: NSRect {
        (slider.cell as! NSSliderCell).barRect(flipped: slider.isFlipped)
    }

    /// Where the current value IS on the track, unrounded: the knob's travel is the bar less one knob
    /// width, starting half a knob in — the same mapping the cell's tracking inverts.
    public var lineCentreX: CGFloat {
        let bar = barRect, knobWidth = knobRect.width
        let span = slider.maxValue - slider.minValue
        let f = span > 0 ? min(max((slider.doubleValue - slider.minValue) / span, 0), 1) : 0
        return bar.minX + knobWidth / 2 + CGFloat(f) * (bar.width - knobWidth)
    }
}

/// The scrubber's slider: a stock-cell NSSlider whose only addition is the begin/end bracket a SwiftUI
/// `Slider`'s `onEditingChanged` gave the transport bar. `NSSlider.mouseDown` runs the whole tracking
/// loop and returns at mouse-up, so the calls around it are the gesture's start and end, and every
/// value the gesture produces arrives (through the action) between them. Subclassing the CONTROL does
/// not change how it draws or tracks (measured: byte-identical to a stock NSSlider); subclassing the
/// cell does — see `PlayheadScrubber`.
public final class TrackingSlider: NSSlider {
    public var onEditingChanged: ((Bool) -> Void)?
    public private(set) var isTracking = false

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        isTracking = true
        onEditingChanged?(true)
        super.mouseDown(with: event)
        isTracking = false
        onEditingChanged?(false)
    }
}

/// Draws the Line style. Takes no clicks, so every click passes to the slider underneath.
final class PlayheadLineView: NSView {
    weak var scrubber: PlayheadScrubber?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = scrubber else { return }
        // The slider fills the scrubber and this view fills it too, and both are flipped, so the
        // slider's rects are this view's rects.
        let knob = s.knobRect
        let bar = s.barRect
        let x = s.lineCentreX
        let enabled = s.isEnabled
        let played = NSColor.white.withAlphaComponent(enabled ? PlayheadLineMetrics.playedAlpha : PlayheadLineMetrics.trackAlpha)
        let line = enabled ? s.lineColor : NSColor.white.withAlphaComponent(PlayheadLineMetrics.disabledAlpha)

        // Track: the full bar, then the played part up to the playhead.
        let radius = bar.height / 2
        NSColor.white.withAlphaComponent(PlayheadLineMetrics.trackAlpha).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        var playedRect = bar
        playedRect.size.width = max(0, x - bar.minX)
        if playedRect.width > 0 {
            played.setFill()
            NSBezierPath(roundedRect: playedRect, xRadius: radius, yRadius: radius).fill()
        }

        line.setFill()
        PlayheadLineMetrics.lineRect(centreX: x, knobRect: knob).fill()
        PlayheadLineMetrics.tabPath(centreX: x, knobRect: knob, flipped: true).fill()
    }
}
