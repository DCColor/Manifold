import SwiftUI
import AppKit
import PlayheadSlider

/// The transport bar's scrubber: `PlayheadScrubber` (Packages/ManifoldCore/Sources/PlayheadSlider) in
/// SwiftUI, drawing its playhead as a Ball or a Line per Settings.
///
/// It replaces a SwiftUI `Slider`, and keeps that Slider's contract exactly: `value` is read, `onChange`
/// gets every value the user's gesture produces, and `onEditingChanged` brackets the gesture (true at
/// mouse-down, before the first value; false at mouse-up, after the last). In Ball style the control is
/// byte-identical to that Slider; the package's tests measure that, the line's centre, and that a click
/// lands on the same value in both styles.
///
/// The style and colour are app-wide preferences read here and nowhere else: they reach no engine,
/// renderer, output or export path. A change in Settings repaints every window's scrubber and moves
/// nothing.
struct TransportScrubber: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Double>
    var onChange: (Double) -> Void
    var onEditingChanged: (Bool) -> Void

    // Same keys and defaults as the Settings pickers; both read `PlayheadStyle`'s constants so the two
    // declarations cannot drift. The colour is the highlight's unless the playhead has its own: optional, because
    // whether a colour is stored is what `PlayheadStyle.lineHex` decides from.
    @AppStorage(PlayheadStyle.defaultsKey) private var style: PlayheadStyle = PlayheadStyle.defaultStyle
    @AppStorage(PlayheadStyle.colorDefaultsKey) private var storedLineHex: String?
    @AppStorage(PlayheadStyle.followsHighlightKey) private var followsHighlight: Bool?
    @AppStorage(AppYellow.defaultsKey) private var highlightHex = AppYellow.hex

    func makeNSView(context: Context) -> PlayheadScrubber {
        PlayheadScrubber(frame: .zero)
    }

    func updateNSView(_ scrubber: PlayheadScrubber, context: Context) {
        #if DEBUG
        ScopePerf.count("update.TransportScrubber")
        #endif
        scrubber.onValueChanged = onChange
        scrubber.onEditingChanged = onEditingChanged
        scrubber.style = style
        let highlight = AppYellow.normalised(highlightHex) ?? AppYellow.hex
        let lineHex = PlayheadStyle.lineHex(storedColor: storedLineHex, explicit: followsHighlight, highlight: highlight)
        scrubber.lineColor = NSColor(ScopeColorCodec.color(fromHex: lineHex))
        // `.disabled(!position)` at the call site arrives as the environment, as it did for Slider.
        scrubber.isEnabled = context.environment.isEnabled
        scrubber.set(value: value, range: range)
    }

    /// As wide as offered, as tall as the slider: the Slider's own sizing. The height is load-bearing —
    /// the docked bar measures itself and sizes the window from it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlayheadScrubber, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: nsView.intrinsicContentSize.height)
    }
}
