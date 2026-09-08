import SwiftUI
import AppKit

/// Full-bleed NSWindow whose size is governed by `WindowSizer` — the video keeps the source aspect,
/// and chrome (scopes tray, docked control bar) is added BELOW it by growing the window taller.
/// Traffic-light buttons fade with the controls.
///
/// ⚠️ THIS NO LONGER TOUCHES `contentAspectRatio`, AND THAT IS THE ARC. That property constrains
/// `contentH = contentW / k`, but the relationship the window needs once anything is drawn under the
/// picture is `contentH = contentW / videoAspect + chromeH` — affine, not linear. The two agree at
/// exactly one width, so there is no value of `k` that works for both tray-open and tray-closed. See
/// WindowSizer.swift, which computes the constraint per resize instead, and proxies SwiftUI's own
/// window delegate rather than replacing it.
struct WindowConfigurator: NSViewRepresentable {
    var buttonsVisible: Bool
    /// The deck that owns this window's `WindowSizer`. Passed rather than looked up, because this
    /// view is mounted inside the same `videoRegion` that mounts `WindowDeckRegistrar` and already
    /// has the deck in hand.
    var deck: WindowDeck
    /// `FrameEngine.displaySize` verbatim — nil means "no source", which is a different statement
    /// from "16:9". The fallback is applied inside the sizer, in one place.
    var displaySize: CGSize?
    /// Total height of everything drawn BELOW the picture in THIS window, in points.
    var chromeHeight: CGFloat
    /// How large the picture is to be drawn — `WindowChrome.rasterSize` reduced to what the geometry
    /// can act on. Travels with the chrome height because it is the same kind of input: a per-window
    /// statement about the window's size that only `WindowSizer` may act on. See RasterSize.swift.
    var raster: RasterRequest
    /// ── PROBE INPUTS (temporary) ─────────────────────────────────────────────────────────
    /// The chrome height above arrives already TOTALLED, so a window whose tray is open but whose
    /// total reads zero cannot be told apart from a window with no chrome at all. These carry the
    /// terms separately, for `WindowLayoutProbe` and for nothing else — nothing sizes from them.
    var trayVisible: Bool
    var trayHeight: CGFloat
    var barDocked: Bool
    var barHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            // ⚠️ THE GEOMETRY GOES IN BEFORE THE DEFAULT SIZE, AND THE ORDER IS THE WHOLE POINT.
            // "Chrome included" is only true if the sizer has been TOLD the chrome height first, and
            // this hop can beat the first `updateNSView` that would have supplied it. MEASURED: a ⌘N
            // window whose stored arrangement had the tray open came up 1280×720 with the tray
            // eating 240 of the picture's 720 — the exact squeeze this arc exists to remove — and it
            // stayed that way, because an idle empty window produces no second update pass to
            // correct it.
            //
            // `setGeometry` first, `installDefaultSize` second: the default size is then computed
            // through the same constraint as everything else, and it is a no-op if a source has
            // already sized the window (the `.onOpenURL` re-use path can get there first).
            deck.sizer.bind(to: window)
            deck.sizer.setGeometry(sourceSize: displaySize, chromeHeight: chromeHeight, raster: raster)
            deck.sizer.installDefaultSize()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }

        let buttons: [NSButton?] = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ]
        let target: CGFloat = buttonsVisible ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            for button in buttons { button?.animator().alphaValue = target }
        }

        // ⚠️ BOUND HERE AND NOT ONLY IN `DeckRegistry.register`, BECAUSE THE ORDER IS NOT GUARANTEED
        // AND THE WRONG ORDER LOSES THE CHROME HEIGHT SILENTLY. This representable and
        // `WindowDeckRegistrar` are siblings in `videoRegion`'s ZStack, and this `updateNSView` can
        // run before the registrar's `viewDidMoveToWindow` has registered the deck. MEASURED: a ⌘N
        // window whose stored arrangement had the tray OPEN came up 1280×720 instead of 1280×960 —
        // `setGeometry` was skipped on the one pass that carried the change, and an idle empty
        // window produces no second pass, so the window stayed the wrong height for good.
        //
        // `bind` is idempotent and — unlike taking the delegate — measured safe at any point in the
        // scene's life, so there is nothing to gate it on.
        deck.sizer.bind(to: window)
        // SELF-HEAL, BUT ONLY AFTER THE CONSTRAINT HAS BEEN SAFELY INSTALLED ONCE. If something
        // replaces the window delegate behind our back this puts the proxy back, with SwiftUI's
        // replacement chained underneath it, rather than losing the constraint silently. It is a
        // no-op before the first install, because that assignment during scene setup is exactly the
        // thing that tears the scene down — see the WindowSizer header.
        deck.sizer.reassertConstraintIfInstalled()
        // THE ONLY WRITER OF THE CONSTRAINT'S INPUTS. A no-op when neither the picture's shape nor
        // the chrome height moved, which is the overwhelming majority of update passes.
        deck.sizer.setGeometry(sourceSize: displaySize, chromeHeight: chromeHeight, raster: raster)

        // TEMPORARY. Runs after `setGeometry` so the window it measures is the one the sizer has
        // just finished shaping, and dedupes internally so an idle window prints once.
        WindowLayoutProbe.log(window: window,
                              from: nsView,
                              trayVisible: trayVisible,
                              trayHeight: trayHeight,
                              barDocked: barDocked,
                              barHeight: barHeight,
                              chromeHeight: chromeHeight)
    }
}

// ── THE LAYOUT PROBE ────────────────────────────────────────────────────────────────────────
//
// TEMPORARY DIAGNOSTIC. One line per distinct layout, from the main thread on an update pass,
// stating the three sizes that sit BETWEEN the window and the video region — window frame,
// content view bounds, hosting view bounds — plus the video region's own rect in WINDOW
// coordinates, and the three chrome terms the sizer was fed.
//
// The question it answers: when every measurement INSIDE the display path reads 2880×1080 and
// black bars are still on screen, is the content area wider than the picture with the picture
// centred in it (a layout problem above the video region), or is the content area 2880 too (in
// which case nothing in the app is drawing the black)?
//
// It also prints the chrome breakdown against the total, because a `[RASTER]` line reporting
// chrome=0 on a window that visibly has a tray means the sizer sized for picture-only and the
// picture is being fitted into less room than was allocated for it.
enum WindowLayoutProbe {

    /// Last line printed per window, so an idle app does not repeat itself on every body pass.
    /// Main-thread only, which is where `updateNSView` runs.
    private static var lastLine: [ObjectIdentifier: String] = [:]

    static func log(window: NSWindow,
                    from anchor: NSView,
                    trayVisible: Bool,
                    trayHeight: CGFloat,
                    barDocked: Bool,
                    barHeight: CGFloat,
                    chromeHeight: CGFloat) {
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame).size
        let contentView = window.contentView
        let hosting = firstDescendant(of: window.contentView) { view in
            String(describing: type(of: view)).contains("NSHostingView")
        }
        // The video region as the WINDOW sees it — origin included, because "2880 wide, centred in
        // something wider" and "2880 wide, filling it" are the two answers being separated here and
        // a size alone cannot tell them apart.
        let videoRect: CGRect? = firstDescendant(of: window.contentView) { view in
            view is MetalHostView
        }.map { $0.convert($0.bounds, to: nil) }

        var line = "[WINPROBE]"
            + " window.frame=\(fmt(frame))"
            + " contentRect=\(fmt(content))"
            + " contentView=\(describe(contentView))"
            + " hosting=\(describe(hosting))"
            + " video=\(videoRect.map(fmt) ?? "—")"
            + " anchorInWindow=\(fmt(anchor.convert(anchor.bounds, to: nil)))"
            + " tray=\(trayVisible ? "shown" : "hidden")/\(r(trayHeight))"
            + " bar=\(barDocked ? "docked" : "overlay")/\(r(barHeight))"
            + " chrome=\(r(chromeHeight))"
        // The one arithmetic check worth making inline: does the chrome the sizer was handed match
        // the chrome that is actually on screen? A mismatch is the bug, not a symptom of it.
        let expected = (trayVisible ? trayHeight : 0) + (barDocked ? barHeight : 0)
        if abs(expected - chromeHeight) > 0.5 { line += " ⚠️MISMATCH expected=\(r(expected))" }

        let key = ObjectIdentifier(window)
        guard lastLine[key] != line else { return }
        lastLine[key] = line
        NSLog("%@", line)
    }

    private static func firstDescendant(of root: NSView?,
                                        where match: (NSView) -> Bool) -> NSView? {
        guard let root else { return nil }
        if match(root) { return root }
        for subview in root.subviews {
            if let hit = firstDescendant(of: subview, where: match) { return hit }
        }
        return nil
    }

    private static func describe(_ view: NSView?) -> String {
        guard let view else { return "—" }
        return "\(type(of: view))\(fmt(view.bounds))"
    }

    private static func r(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
    private static func fmt(_ size: CGSize) -> String { "\(r(size.width))×\(r(size.height))" }
    private static func fmt(_ rect: CGRect) -> String {
        "(\(r(rect.origin.x)),\(r(rect.origin.y)) \(r(rect.width))×\(r(rect.height)))"
    }
}
