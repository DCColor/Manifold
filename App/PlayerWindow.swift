import SwiftUI
import AppKit

/// The player `WindowGroup`'s scene identity (0.9.1, docs/BUGS.md, saved window positions). Named the same way as
/// `AboutScene` and `KeyboardShortcutsScene`, and for a second reason: with no id, SwiftUI names the window's
/// frame-autosave key (`NSWindow Frame …-AppWindow-1`) after the group content's TYPE, so a modifier added to the
/// content, a renamed type, a `private` type's moving address or a macOS update started a new key and stranded the
/// old one (1,627 by 2026-10-30). With an id the key is named after the id, which changes only if this string does.
/// ⚠️ CHANGING IT RESETS EVERY USER'S SAVED WINDOW FRAME, once.
enum PlayerScene {
    static let windowID = "player"
}

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
        #if DEBUG
        ScopePerf.count("update.PlayerWindow")
        #endif
        guard let window = nsView.window else { return }

        TrafficLights.setVisible(buttonsVisible, in: window)

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
    }
}

/// ── THE TRAFFIC LIGHTS FADE WITH THE CONTROLS: THEIR CONTAINER FADES, NOT THE BUTTONS ─────────────────────────
///
/// ⚠️ A STANDARD WINDOW BUTTON AT ALPHA 0 IS A DISABLED BUTTON. `-[_NSThemeWidgetCell isEnabled]` is `super &&
/// !temporarilyDisabled && canBeEnabled && controlView.alphaValue != 0` (disassembled, macOS 26), and NSWindow
/// validates Close and Minimize against those buttons. Fading the buttons themselves, as this file did until
/// 2026-10-24, disabled File ▸ Close and Window ▸ Minimize whenever the controls had hidden, which they always have
/// by the time the pointer reaches the menu bar. ⌘W worked only with the pointer over the window, and an
/// Accessibility press on the close button reported success and closed nothing (docs/BUGS.md).
///
/// So the view that holds the three buttons is faded instead. They look the same and stay enabled, and File ▸ Close
/// (and with it ⌘W), Minimize and an Accessibility press all reach AppKit's own `performClose:` and
/// `performMiniaturize:`, the one close path. The buttons' own alpha is never written.
///
/// ⚠️ AND A CLICK ON A FADED BUTTON IS SWALLOWED. AppKit disables an invisible button for a reason: the controls hide
/// 2 s after the pointer stops, and a click in the top-left corner would otherwise close a window that shows no
/// button there (perhaps the one holding DeckLink output). One local monitor keeps that: a mouse-down on a button in a
/// faded container goes nowhere, as it did at alpha 0. An Accessibility press is not an event and is not affected.
@MainActor
enum TrafficLights {
    /// The containers faded out. Weak: a closed window's goes with it.
    private static let faded = NSHashTable<NSView>.weakObjects()
    private static var monitor: Any?

    static func setVisible(_ visible: Bool, in window: NSWindow) {
        // All three buttons share one superview (`NSTitlebarView`). Its other contents, the title bar's background and
        // title, are already drawn as nothing under `.hiddenTitleBar`.
        guard let container = window.standardWindowButton(.closeButton)?.superview else { return }
        installMonitor()
        if visible { faded.remove(container) } else { faded.add(container) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            container.animator().alphaValue = visible ? 1 : 0
        }
    }

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            let swallow = MainActor.assumeIsolated { TrafficLights.isOnFadedButton(event) }
            return swallow ? nil : event
        }
    }

    private static func isOnFadedButton(_ event: NSEvent) -> Bool {
        guard faded.count > 0, let frame = event.window?.contentView?.superview,
              let hit = frame.hitTest(event.locationInWindow) else { return false }
        var view: NSView? = hit
        while let v = view, v !== frame {
            if v is NSButton, let container = v.superview, faded.contains(container) { return true }
            view = v.superview
        }
        return false
    }
}
