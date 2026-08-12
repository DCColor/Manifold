//
//  RasterSize.swift
//  Manifold
//
//  HOW LARGE THE PICTURE IS DRAWN, AS A PERCENTAGE OF THE SOURCE RASTER — the model, the menu, and
//  the transient readout's text. The geometry that applies it is in `WindowSizer`; the per-window
//  state that stores it is in `WindowChrome`.
//
//  ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
//
//  It is the counterweight to the window-sizing arc. Chrome is ADDITIVE there — opening the scopes
//  tray or docking the control bar makes the WINDOW taller and never makes the picture smaller — so
//  a UHD file with the tray open asks for a window taller than most displays can show, and the
//  screen cap then shrinks the picture on the user's behalf. This is the control that lets them
//  make that decision themselves, deliberately, instead of discovering it as a capped window.
//
//  ── THE THREE THINGS THE PERCENTAGE MEANS, AND ONE IT DOES NOT ─────────────────────────
//
//  1. **100% IS ONE SOURCE PIXEL PER SOURCE PIXEL.** A 3840×2160 file at 100% occupies 1920×1080
//     POINTS on a 2× Retina display, because 1920 points ARE 3840 pixels there. It looks half-size
//     next to a window measured in points and it is showing every pixel of the source at native
//     resolution. `WindowSizer.rasterContentWidth` is the one place that division happens.
//
//     ⚠️ DO NOT "CORRECT" FOR BACKING SCALE. Making 100% mean 3840 POINTS would draw each source
//     pixel across a 2×2 block of device pixels — a 200% magnification wearing a 100% label, and
//     the one reading that makes the control useless to the people it is for.
//
//  2. **IT IS MEASURED AGAINST DISPLAY GEOMETRY, NOT ENCODED PIXELS.** An anamorphic 2048×858 that
//     displays as 2389×1000 is 2389 wide at 100%. The percentage is a FRAMING control and display
//     geometry is what the user is looking at; the encoded dimensions stay in the inspector, which
//     is where this app does its honest-metadata reporting. `FrameEngine.displaySize` is the single
//     input, and it is the same value that shapes the window — so the picture cannot be sized
//     against one shape while the window is built for another.
//
//  3. **IT SIZES THE VIDEO, NOT THE WINDOW.** Chrome is added below it exactly as before, so 50%
//     with the scopes open is a half-size picture and a FULL-size tray. The percentage never
//     appears in the tray's height or the control bar's.
//
//  What it is NOT: a snap grid for the window's edges. A manual edge-drag stays permitted and
//  produces `.custom` — see `WindowSizer.onUserResize`. Snapping a hand-dragged window to the
//  nearest preset would make the drag feel broken, and there is nothing to gain: `.custom` is a
//  perfectly honest state, and the readout says so.
//

import SwiftUI
import AppKit

// MARK: - The state

/// What size the picture is drawn at, for ONE window.
///
/// `String`-backed because it is persisted through `UserDefaults` from two directions — the
/// per-window state in `WindowChrome` and the app-wide default in Settings — and both must read the
/// same key with the same spelling.
enum RasterSize: String, CaseIterable, Identifiable, Hashable {

    /// ⚠️ THE PRE-EXISTING BEHAVIOUR, KEPT AS A NAMED STATE RATHER THAN DELETED. This is the app's
    /// original opening rule: fit the source into 80% of the visible frame, never magnified past
    /// 1:1, then centre (`WindowSizer.sizeToSource`). It is the DEFAULT on a fresh install, so this
    /// arc changes nothing about how a window opens until the user asks it to.
    ///
    /// It is deliberately NOT in the View menu. The rule only ever acts at the moment a source
    /// first sizes a window, so an item that says "do that now" would have nothing to do — the
    /// window is already open. It is reachable from Settings, where it belongs, because that is the
    /// control that decides what the NEXT window opens at.
    case automatic = "auto"

    case percent100 = "100"
    case percent75  = "75"
    case percent50  = "50"
    case percent25  = "25"

    /// The largest picture that fits the visible frame WITH the chrome — a mode, not a one-shot.
    /// Opening the tray under Fit re-fits, which is the only reading of "fits including chrome"
    /// that stays true after the chrome changes.
    case fitToScreen = "fit"

    /// The user dragged a window edge. Never chosen from a menu and NEVER PERSISTED — see the
    /// `didSet` on `WindowChrome.rasterSize`. It means "no policy": the window keeps whatever size
    /// the user left it at, and chrome changes re-derive from that width exactly as they always did.
    case custom = "custom"

    var id: String { rawValue }

    /// The fraction of the source's DISPLAY width this state asks for, or nil where the answer is
    /// not a fixed fraction (`automatic`, `fitToScreen`, `custom`).
    var fraction: CGFloat? {
        switch self {
        case .percent100: return 1.00
        case .percent75:  return 0.75
        case .percent50:  return 0.50
        case .percent25:  return 0.25
        case .automatic, .fitToScreen, .custom: return nil
        }
    }

    /// What the View menu and the Settings picker call it.
    var menuTitle: String {
        switch self {
        case .automatic:   return "Automatic (fit on open)"
        case .percent100:  return "100%"
        case .percent75:   return "75%"
        case .percent50:   return "50%"
        case .percent25:   return "25%"
        case .fitToScreen: return "Fit to Screen"
        case .custom:      return "Custom"
        }
    }

    /// The View menu's accelerators. ⌘1–⌘4 descend through the presets; ⌘0 is Fit, which is where
    /// media apps have put "make it fit" for long enough that it is muscle memory.
    ///
    /// Checked against every shortcut this app already claims: the bare keys (I, N, Tab, J/K/L, the
    /// arrows, Space), the ⌃⌥ block (T, X, G, B, R, E, O, N, D and ⌃⌥1/2/3 for the CIE triangles)
    /// and the standard ⌘ items. ⌘1–⌘4 and ⌘0 were unclaimed; ⌃⌥1/2/3 carry two extra modifiers and
    /// do not collide.
    var shortcut: KeyEquivalent? {
        switch self {
        case .percent100:  return "1"
        case .percent75:   return "2"
        case .percent50:   return "3"
        case .percent25:   return "4"
        case .fitToScreen: return "0"
        case .automatic, .custom: return nil
        }
    }

    /// The states a user can CHOOSE from a menu, in menu order. `automatic` and `custom` are both
    /// states a window can be IN without being states a window can be PUT in from here.
    static let menuChoices: [RasterSize] = [.percent100, .percent75, .percent50, .percent25,
                                            .fitToScreen]

    /// What Settings offers as the default for new windows — the menu choices plus `automatic`,
    /// which is the only way back to the original opening rule once something else has been chosen.
    static let settingsChoices: [RasterSize] = [.automatic] + menuChoices

    /// The `UserDefaults` key. ONE key, written by both the per-window control and the Settings
    /// picker, with the app's usual last-writer-wins semantics: the stored value is simply the last
    /// size any window was set to, and that is what the next window opens with. See the seeding
    /// note in `WindowChrome`.
    static let defaultsKey = "manifold.raster.size"
}

// MARK: - The readout's text

/// The transient top-left readout: a percentage AND the dimensions it produces.
///
/// ⚠️ THE DIMENSIONS ARE THE WHOLE POINT OF THE READOUT, and they are why "100% looks half-size"
/// needs no explanation anywhere in the app. "100% — 3840×2160" over a picture occupying 1920×1080
/// points says, in one line, that every source pixel is on screen. A bare "100%" would say nothing
/// and would read as a bug.
///
/// The numbers are DEVICE PIXELS — the picture's measured size in points times the display's
/// backing scale — which is the same quantity as "source pixels drawn" whenever the source is being
/// drawn at a whole fraction of itself. That equivalence is the readout's entire claim, so it is
/// computed from the MEASURED picture rather than from the requested percentage: if the screen cap
/// bound the window, the measurement is what is true and the request is not.
enum RasterReadout {

    /// Build the readout, or nil when there is nothing honest to say (no source, nothing drawn yet).
    ///
    /// - Parameters:
    ///   - size: the window's raster state.
    ///   - displaySize: `FrameEngine.displaySize` — the source's DISPLAY geometry, in pixels.
    ///   - drawnPixels: the picture's measured size, in DEVICE PIXELS. Measured, not derived: this
    ///     is what makes the anamorphic and screen-capped cases report what is actually on screen.
    static func text(for size: RasterSize, displaySize: CGSize?, drawnPixels: CGSize?) -> String? {
        guard let source = displaySize, source.width > 0, source.height > 0 else { return nil }
        guard let drawn = drawnPixels, drawn.width > 0, drawn.height > 0 else { return nil }

        let measured = dimensions(drawn)
        let measuredPercent = Int((drawn.width / source.width * 100).rounded())

        switch size {
        case .custom:
            // Stated as `custom`, with the dimensions — the drag was deliberate and the readout's
            // job is to say what it landed on, not to round it to a preset it is not.
            return "Custom — \(measured)"

        case .automatic:
            // Reachable only if something changes size while the window is still on the opening
            // rule. Report the measurement, since there is no requested percentage to report.
            return "\(measuredPercent)% — \(measured)"

        case .fitToScreen:
            return "Fit — \(measuredPercent)% — \(measured)"

        case .percent100, .percent75, .percent50, .percent25:
            guard let fraction = size.fraction else { return nil }
            let nominal = CGSize(width: source.width * fraction, height: source.height * fraction)
            // ⚠️ WITHIN TOLERANCE, NOT EQUAL. The window's content size is rounded to whole POINTS,
            // so a source whose display width is odd (an anamorphic 2389 at 100% → 1194.5 pt →
            // 1195 pt → 2390 px) lands a pixel or two off its own nominal. Two pixels is rounding;
            // anything more is the screen cap, which is a different statement and gets said.
            if abs(drawn.width - nominal.width) <= 2 {
                return "\(size.menuTitle) — \(dimensions(nominal))"
            }
            // SOMETHING BOUND IT, AND WHICH ONE IS NOT A DETAIL — the two limits are in opposite
            // directions and blaming the wrong one is worse than saying nothing. A picture SMALLER
            // than asked for is the screen cap. A picture LARGER than asked for is the window's own
            // minimum content size, which the app sets at 720×460: 25% of an HD source is a 480-pt
            // picture, and a window cannot be that narrow, so the picture is grown to fill it.
            // (MEASURED — 25% of 1920×1080 came out 720×405, and the first version of this line
            // called that a screen limit on a display with 3840 points of width to spare.)
            let cause = drawn.width < nominal.width ? "screen limit" : "window minimum"
            return "\(size.menuTitle) — \(measured) (\(cause))"
        }
    }

    private static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }
}

// MARK: - The menu's view of the key window

/// WHAT THE VIEW MENU SHOWS A CHECKMARK AGAINST, and whether its items are live at all.
///
/// A `CommandMenu` is built in the APP scene, which has no window's state in scope — every piece of
/// per-window state in this app lives on a `WindowChrome` or a `WindowDeck` owned by one
/// `ContentView`. So the menu needs a mirror of the KEY window's raster state, and this is it.
///
/// ⚠️ ONE FUNCTION RECOMPUTES THE WHOLE THING FROM CURRENT FACTS — deliberately modelled on
/// `DeckRegistry.applyArbitration`, whose header states the principle. `refresh()` reads the key
/// deck and overwrites both fields; nothing patches one of them, and no caller passes a value in.
/// That is what lets it be called from three unrelated triggers (a key-window change, a raster
/// change, a source arriving) without the three having to agree about anything.
///
/// It is a MIRROR AND NOT THE TRUTH. `WindowChrome.rasterSize` is the truth, one per window; this
/// object holds a copy of whichever one the menu is currently describing, and writes nothing back —
/// the menu's ACTION goes through `DeckRegistry.setRasterSize`, which finds the same key deck by
/// the same lookup the arbiter uses.
@MainActor
final class RasterMenuState: ObservableObject {

    static let shared = RasterMenuState()

    /// The key window's raster state, or nil when there is no deck to describe.
    @Published private(set) var current: RasterSize?

    /// FALSE when the key window has no source. A raster percentage is a percentage OF something,
    /// and an empty window has no raster to take a percentage of — the menu items would be
    /// well-formed no-ops, which is worse than being visibly unavailable.
    @Published private(set) var enabled = false

    private init() {}

    func refresh() {
        let deck = DeckRegistry.shared.keyDeck
        current = deck?.chrome?.rasterSize
        enabled = (deck?.engine?.displaySize != nil)
    }
}

// MARK: - The View menu

/// The View menu: the five raster presets and their accelerators.
///
/// ── WHY A MENU, AND WHY NOT A CONTROL-BAR ITEM ─────────────────────────────────────────
///
/// A menu is where a windowing app puts a window-geometry command, it is where a user looks for
/// one, and it is the only surface in this app that can carry an accelerator that is visible before
/// you press it. Every other shortcut here (⌃⌥T, ⌃⌥O, ⌃⌥X …) is a hidden `Button` in a `.background`
/// and is discoverable only by reading the release notes.
///
/// The control bar was considered and REFUSED. It is already carrying the transport, the scrubber,
/// two readouts, volume, scopes, guides, captions, output and the inspector affordances, and it is
/// the surface that has to survive a narrow window. Raster size is a set-it-and-look-at-it framing
/// decision — closer to "which display is this window on" than to anything else on that bar — and
/// it is used a handful of times per session, not continuously. What a bar item would really have
/// bought is FEEDBACK ("what am I at right now"), and the transient readout provides that at the
/// moment it is wanted without spending permanent width on it.
struct RasterSizeCommands: Commands {

    @ObservedObject private var state = RasterMenuState.shared

    var body: some Commands {
        // ⚠️ `CommandGroup(after: .toolbar)` AND NOT `CommandMenu("View")`, AND THE DIFFERENCE IS
        // VISIBLE IN THE MENU BAR. SwiftUI already synthesizes a View menu for every `WindowGroup`
        // (Show Tab Bar / Show All Tabs / Enter Full Screen), and a `CommandMenu` with the same
        // title does not merge with it — it appends a SECOND menu.
        //
        // MEASURED, which is why this note exists: with `CommandMenu("View")` the running app's menu
        // bar read `Apple, Manifold, File, Edit, View, View, Window, Help` — two View menus side by
        // side, the stock one holding the tab items and ours holding the presets. `.toolbar` is the
        // placement that lands INSIDE the existing View menu, which is where a raster size belongs.
        CommandGroup(after: .toolbar) {
            ForEach(RasterSize.menuChoices) { size in
                // A `Toggle` and not a `Button`, because AppKit draws a menu Toggle with a real
                // checkmark. A Button would need a checkmark glyph faked into its label, which
                // indents wrongly next to the shortcut column.
                Toggle(size.menuTitle, isOn: binding(for: size))
                    .modifier(OptionalShortcut(key: size.shortcut))
                    // PER ITEM, because `Commands` has no `.disabled` — the modifier exists on
                    // View, and a menu's contents are views. Same predicate on all five, so the
                    // menu greys out as a unit.
                    .disabled(!state.enabled)
            }
        }
    }

    /// Selecting an item applies it; selecting the one already checked is a no-op rather than a
    /// toggle-off, because there is no "off" for a size — the window is always some size.
    private func binding(for size: RasterSize) -> Binding<Bool> {
        Binding(
            get: { state.current == size },
            set: { isOn in
                guard isOn else { return }
                DeckRegistry.shared.setRasterSize(size)
            }
        )
    }
}

/// `.keyboardShortcut` takes a non-optional `KeyEquivalent`, and a `ViewBuilder` `if` around the
/// modifier would give the two branches different types inside a `ForEach` in a menu. This applies
/// it only where there is one, without branching the view's type.
private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}
