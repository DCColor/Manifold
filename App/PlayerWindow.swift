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
            deck.sizer.setGeometry(sourceSize: displaySize, chromeHeight: chromeHeight)
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
        deck.sizer.setGeometry(sourceSize: displaySize, chromeHeight: chromeHeight)
    }
}
