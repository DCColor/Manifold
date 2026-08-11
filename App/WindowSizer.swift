//
//  WindowSizer.swift
//  Manifold
//
//  ONE WINDOW'S SIZE CONSTRAINT. Arc B of the window-sizing work.
//
//  ── WHY contentAspectRatio HAD TO GO ───────────────────────────────────────────────────
//
//  `NSWindow.contentAspectRatio` was not merely set to the wrong value — it cannot express the
//  right relationship AT ALL. It constrains
//
//        contentH = contentW / k
//
//  for a constant k. What the window actually needs, once anything is drawn below the picture, is
//
//        contentH = contentW / videoAspect + chromeH
//
//  which is AFFINE, not linear. The two agree at exactly one width, so no value of k is a fix: pick
//  k for the tray-open case and the tray-closed case is wrong, and vice versa. There is no third
//  option in AppKit's declarative API, which is why this is a delegate.
//
//  The visible symptom: the window never grew when chrome appeared, so SwiftUI shrank the video to
//  fit everything into an unchanged box. With the tray open at 33% of a 16:9-locked window the
//  video's box became 2.65:1, a 1.78 picture filled 67% of the width, and 16.5% of the window was
//  black down each side. The docked control bar had the same cause and hid it by being drawn OVER
//  the picture.
//
//  ── WHAT THE CONSTRAINT PRODUCES ───────────────────────────────────────────────────────
//
//    * The video region keeps the source aspect and does NOT shrink when chrome appears.
//    * Chrome is added BELOW the video and the WINDOW GROWS TALLER by exactly its height.
//    * Window width tracks the video width; height follows.
//    * Chrome is FIXED height, so dragging the window scales the VIDEO and leaves the scopes and
//      the control bar alone. A waveform does not get more useful when taller.
//    * Turning chrome off shrinks the window back.
//    * A window NEVER grows past what the screen can show. When the computed size would exceed the
//      visible frame the VIDEO shrinks to fit — that is the one case where letterboxing is correct,
//      and it is the only place this file allows it.
//
//  ── THE PROXY, AND THE TWO THINGS MEASUREMENT FORCED ───────────────────────────────────
//
//  SwiftUI installs its own `AppKitWindowController` as the delegate of every WindowGroup window and
//  uses it for window restoration and close handling, so this must PROXY rather than replace: every
//  message it does not implement is forwarded by ObjC dispatch (`responds(to:)` +
//  `forwardingTarget(for:)`) rather than by an enumerated list of ~40 optional methods that would
//  silently rot. Even the two it does implement forward FIRST and constrain SwiftUI's answer.
//
//  Two things about taking that slot are NOT obvious, and both were found by measurement rather than
//  by reading. Neither is defensive:
//
//  1. **THE DELEGATE MUST NOT BE TAKEN DURING SCENE SETUP.** Assigning `window.delegate` from
//     `DeckRegistry.register` (i.e. from `viewDidMoveToWindow`) makes SwiftUI TEAR THE SCENE DOWN.
//     MEASURED, launching with a document — `open -n -a Manifold.app wedge.mov`, the cold Finder
//     double-click: with the assignment in place the log reads `register` → `deregister` 13 ms later
//     → nothing, `decks=0`, and the window never comes on screen at all. The SAME build with only
//     the `window.delegate = self` line skipped reads `register` → `key window` → the file loads, in
//     a correct 1920×1080 window. Isolated to that one line: skipping the `resizeIncrements` write
//     instead reproduced the failure exactly, so it is the delegate assignment and nothing else.
//
//     Hence `bind(to:)` and `installConstraint()` are separate, and the second waits until the
//     window has become KEY, by which point SwiftUI has finished. A window that is never key simply
//     has no INTERACTIVE constraint until it is clicked; every PROGRAMMATIC resize works from
//     `bind` onwards, which is what the chrome and source-change paths use.
//
//  2. **`NSWindow.delegate` IS WEAK, so a sizer that dies holding it leaves the window with NO
//     delegate** — and a SwiftUI window whose delegate has silently gone away never appears. See
//     `deinit`.
//

import AppKit
import Foundation

// ══════════════════════════════════════════════════════════════════════════════════════════
//  THE INVARIANT — CHROME NEVER REDUCES THE VIDEO'S SIZE.
//
//  Opening the scopes tray, or docking the control bar, makes the WINDOW TALLER. It does not make
//  the picture smaller and it never puts a bar beside it. That is the whole of Arc B, stated as one
//  sentence, and every other rule in this file is a consequence of it.
//
//  THE SINGLE EXCEPTION IS THE SCREEN CAP: when the window the constraint asks for is larger than
//  the display can actually show, the picture shrinks — on-shape, never letterboxed — because there
//  is nowhere else for the height to come from. That exception is taken in exactly one place
//  (`constrainedContentSize`, marked ROUTE 2) and nowhere else in the app.
//
//  ── WHY THIS IS A TYPE AND NOT A COMMENT ─────────────────────────────────────────────────
//
//  The violating expression is short, plausible, and reads like a fix:
//
//        w = (availableHeight - chrome) * aspect        // ← makes the picture pay for the tray
//
//  It is exactly what someone reaches for when a window looks too tall, and the symptom it produces
//  is a slightly-smaller picture — which nobody files a bug about. A comment asking people not to
//  write it would be obeyed until the first person in a hurry.
//
//  So the chrome height is NOT IN SCOPE where the picture's size is computed. `chromeHeight` is
//  instance state on `WindowSizer`; every member of `VideoBox` is `static`. Inside them the
//  identifier `chrome` DOES NOT RESOLVE, and the line above is a compile error rather than a
//  regression. Chrome reaches the geometry by exactly two routes, both of them in
//  `constrainedContentSize`, both labelled there, and both auditable by grepping this file for
//  `chrome`:
//
//      ROUTE 1 — ADDED to the window's height. The operator is `+`. There is no `-`.
//      ROUTE 2 — charged against the picture's WIDTH BUDGET at the screen cap. The exception.
//
//  `assertChromeDidNotShrinkVideo` closes the remaining gap at runtime: scoping cannot stop a
//  caller from narrowing the budget for some reason that ISN'T the screen cap, so the result is
//  re-checked against the chrome-free answer on every solve in DEBUG.
//
//  ⚠️ IF YOU ADD A NEW PIECE OF CHROME, it goes in `ContentView.chromeHeight` and nowhere else.
//  Do not teach this file about it.
// ══════════════════════════════════════════════════════════════════════════════════════════

/// The picture's geometry. **No member of this type can see `chromeHeight`** — see the header above;
/// that is the enforcement, not a convention.
private enum VideoBox {
    /// The picture's height at a given width.
    static func height(width: CGFloat, aspect: CGFloat) -> CGFloat { width / max(aspect, 0.01) }

    /// The picture's width at a given height. Used ONLY to turn a height budget into a width budget
    /// (ROUTE 2). Still chrome-blind: the caller subtracts chrome from the budget BEFORE calling, so
    /// the subtraction is visible at the call site instead of buried in here.
    static func width(height: CGFloat, aspect: CGFloat) -> CGFloat { height * max(aspect, 0.01) }
}

@MainActor
final class WindowSizer: NSObject, NSWindowDelegate {

    // MARK: - Geometry inputs

    /// The picture's shape. Falls back to 16:9 before a source states one — the SAME fallback
    /// `ContentView.videoAspect` uses, deliberately, so the window's constraint and the view's
    /// layout can never disagree about what shape is being laid out for.
    private var videoAspect: CGFloat = 16.0 / 9.0

    /// Total height of everything drawn BELOW the picture: the scopes tray and the docked control
    /// bar. Per window, because `WindowChrome` is per window (Arc A).
    private var chromeHeight: CGFloat = 0

    /// Has this window been given its opening size for a real source yet? Guards the one-time "fit
    /// the source into 80% of the screen and centre" step, so a second file — or a mid-stream
    /// resolution change — re-derives the height in place instead of jumping the window under the
    /// user.
    private var hasSizedToSource = false

    /// Has the empty-window default size been installed? Separate from the flag above because the
    /// two can happen in either order: `WindowConfigurator.makeNSView` hops to the main queue to
    /// install the default, and a window re-used by an `.onOpenURL` can have taken a source first.
    private var hasInstalledDefault = false

    // MARK: - Delegate identity

    /// `nonisolated(unsafe)` for `deinit`'s sake — see the note there. Written only on main.
    private nonisolated(unsafe) weak var window: NSWindow?

    /// SwiftUI's delegate, held STRONGLY and released in `detach()`.
    ///
    /// Strong because nothing else here is guaranteed to keep it alive once `window.delegate` (which
    /// is weak) stops pointing at it, and a released delegate is a window with no restoration and no
    /// close handling. `detach()` puts it back and drops the reference, so the pairing is symmetric
    /// and cannot outlive the window.
    ///
    /// `nonisolated(unsafe)` because `responds(to:)` and `forwardingTarget(for:)` override
    /// NONISOLATED NSObject methods and so cannot be actor-isolated themselves. It is written only
    /// on the main thread, and AppKit dispatches delegate messages only there, so the unsafety is
    /// nominal.
    private nonisolated(unsafe) var inner: NSWindowDelegate?

    /// TRUE once the delegate slot has been taken at least once for this window — i.e. once SwiftUI's
    /// scene setup is demonstrably finished. Only then is re-asserting the proxy safe (hazard 1 in
    /// the header), which is what `reassertConstraintIfInstalled()` gates on.
    private var hasInstalledConstraint = false

    // MARK: - Binding (safe at any time)

    /// Learn which window this deck is in. Deliberately does NOT touch the delegate — hazard 1 in
    /// the header. Called from `DeckRegistry.register`, so every PROGRAMMATIC resize (chrome
    /// toggled, a source arriving, a resolution change) works from the moment the deck exists,
    /// whether or not the window has been key yet.
    func bind(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window

        // ⚠️ CLEAR THE OLD ASPECT LOCK THE DOCUMENTED WAY, NOT BY ASSIGNING `.zero`. `.zero` is not
        // "no constraint" — it marks the window aspect-CONSTRAINED with a degenerate 0/0 ratio, and
        // AppKit's resize math then trips an internal __builtin_trap (EXC_BREAKPOINT in
        // -[NSWindow _adjustNeedsDisplayRegionForNewFrame:]) on the first resize. Aspect ratio and
        // resize increments are mutually exclusive in AppKit, so setting increments to 1×1 is the
        // supported way to drop the lock. The constraint lives in `windowWillResize` now.
        //
        // Measured safe during scene setup, unlike the delegate assignment: the isolation test in
        // the header applied THIS line alone and the document launch was correct.
        window.resizeIncrements = NSSize(width: 1, height: 1)
    }

    // MARK: - The delegate slot (only once the scene has settled)

    /// Take the delegate slot, proxying SwiftUI's. **Only call once the window has become key** —
    /// hazard 1 in the header. Idempotent.
    func installConstraint() {
        guard let window, window.delegate !== self else { return }
        if let existing = window.delegate, existing !== self { inner = existing }
        window.delegate = self
        hasInstalledConstraint = true
    }

    /// Put the proxy back if something replaced it — but ONLY once it has been safely installed at
    /// least once. Before that, re-asserting IS the setup-time assignment that tears the scene down;
    /// after it, SwiftUI is finished and the self-heal is free. Called from
    /// `WindowConfigurator.updateNSView`, i.e. on every body pass, and a no-op in the normal case.
    func reassertConstraintIfInstalled() {
        guard hasInstalledConstraint else { return }
        installConstraint()
    }

    /// Hand the window back to SwiftUI. Called from `DeckRegistry.deregister`, i.e. on
    /// `viewDidMoveToWindow(nil)` and on `NSWindow.willCloseNotification`, whichever lands first.
    func detach() {
        if let window, window.delegate === self { window.delegate = inner }
        inner = nil
        window = nil
        hasInstalledConstraint = false
    }

    /// ⚠️ THE LAST LINE OF DEFENCE, AND IT IS NOT THEORETICAL.
    ///
    /// `NSWindow.delegate` is a WEAK reference. A sizer that dies while holding the slot therefore
    /// leaves `window.delegate == nil`, and a SwiftUI window whose delegate has silently gone away
    /// never comes on screen and says nothing about why.
    ///
    /// That is reachable by an ordinary path: SwiftUI builds a `ContentView`, discards it and builds
    /// another during scene setup (MEASURED — `register` followed by `deregister` 13 ms later on the
    /// document-launch path). Each discard takes the `@StateObject` deck and this object with it, and
    /// the designed teardown cannot cover it: `DeckRegistry`'s reference to the deck is WEAK, so by
    /// the time `deregister` runs the deck is already nil and `detach()` never happens.
    ///
    /// By the time `deinit` runs, the weak back-reference from `window.delegate` to `self` has
    /// already been zeroed — so `delegate == nil` is PRECISELY the test for "we still held the slot",
    /// and it correctly declines to stomp a successor sizer that has taken it since.
    deinit {
        if let window, window.delegate == nil { window.delegate = inner }
    }

    // MARK: - Message forwarding

    // Everything we do not implement is SwiftUI's — including window restoration and close handling,
    // which is what breaks if a delegate is REPLACED rather than proxied.

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return inner?.responds(to: aSelector) ?? false
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let inner, inner.responds(to: aSelector) { return inner }
        return super.forwardingTarget(for: aSelector)
    }

    // MARK: - The constraint

    /// Live resize. Forwards to SwiftUI first and constrains ITS answer, so anything SwiftUI wants to
    /// say about the size (a resizability policy, a content minimum) is honoured and then made to
    /// satisfy the video's shape — rather than being thrown away, which is what a plain override
    /// would do.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = inner?.windowWillResize?(sender, to: frameSize) ?? frameSize

        // Full screen is the SCREEN's shape, not the picture's. SwiftUI's `.aspectRatio(.fit)`
        // letterboxes inside it, which is the right answer there.
        guard !sender.styleMask.contains(.fullScreen) else { return proposed }

        let content = sender.contentRect(forFrameRect: NSRect(origin: sender.frame.origin,
                                                              size: proposed)).size
        let current = sender.contentRect(forFrameRect: sender.frame).size

        // WHICH EDGE IS THE USER DRAGGING? `windowWillResize` is handed a size, not an edge, so
        // driving height from width unconditionally would make the top and bottom edges feel dead.
        // Whichever dimension moved further is the one the user is steering; the other follows.
        let drivenByHeight = abs(content.height - current.height) > abs(content.width - current.width)
        let width = drivenByHeight
            ? (content.height - chromeHeight) * videoAspect
            : content.width

        let fitted = constrainedContentSize(for: sender, contentWidth: width)
        return sender.frameRect(forContentRect: NSRect(origin: sender.frame.origin,
                                                       size: fitted)).size
    }

    /// Zoom (green button, double-click the title bar). Same forward-then-constrain shape, so the
    /// zoomed window is the largest correctly-proportioned one the screen can show instead of a
    /// screen-shaped box with the picture letterboxed inside it.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let proposed = inner?.windowWillUseStandardFrame?(window, defaultFrame: newFrame) ?? newFrame
        guard !window.styleMask.contains(.fullScreen) else { return proposed }

        let content = window.contentRect(forFrameRect: proposed).size
        let fitted = constrainedContentSize(for: window, contentWidth: content.width)
        var frame = window.frameRect(forContentRect: NSRect(origin: proposed.origin, size: fitted))
        frame.origin.y = proposed.maxY - frame.height     // keep the top edge where zoom put it
        return frame
    }

    // MARK: - Driving it from the view layer

    /// The picture's shape and the chrome below it, as SwiftUI currently has them. Called from
    /// `WindowConfigurator.updateNSView`, i.e. on every body pass, and a no-op when nothing moved.
    ///
    /// `sourceSize` is `FrameEngine.displaySize` verbatim — nil means "no source", which is a
    /// different statement from "16:9". The fallback is applied HERE and nowhere else.
    func setGeometry(sourceSize: CGSize?, chromeHeight: CGFloat) {
        let aspect: CGFloat = {
            guard let s = sourceSize, s.width > 0, s.height > 0 else { return 16.0 / 9.0 }
            return s.width / s.height
        }()
        let chrome = max(0, chromeHeight)

        let aspectChanged = abs(aspect - videoAspect) > 0.0001
        let chromeChanged = abs(chrome - self.chromeHeight) > 0.5
        let gainedSource = (sourceSize != nil && !hasSizedToSource)

        videoAspect = aspect
        self.chromeHeight = chrome

        guard aspectChanged || chromeChanged || gainedSource else { return }
        guard let window, isResizable(window) else { return }

        if gainedSource, let sourceSize {
            hasSizedToSource = true
            hasInstalledDefault = true
            sizeToSource(sourceSize, in: window)
        } else {
            // ⚠️ RE-DERIVED FROM THE CURRENT WIDTH, WHICH IS WHAT MAKES THE VIDEO HOLD STILL. The
            // width is the video's width; re-solving the affine constraint at that width changes
            // ONLY the height, by exactly the chrome delta. Opening the tray therefore grows the
            // window and leaves the picture the size it was, which is the whole point of the arc.
            applyConstraint(to: window)
        }
    }

    /// The opening size of a window with nothing in it: 16:9 at up to 1280 wide (or 60% of the
    /// screen, whichever is smaller), PLUS whatever chrome is already showing — a window whose tray
    /// was left open reopens with the tray open, and the height has to account for it.
    ///
    /// Runs at most once per window, and never after a source has already sized it.
    func installDefaultSize() {
        guard let window, isResizable(window), !hasInstalledDefault, !hasSizedToSource else { return }
        hasInstalledDefault = true

        let width: CGFloat
        if let screen = window.screen ?? NSScreen.main {
            width = min(screen.visibleFrame.width * 0.6, 1280)
        } else {
            width = 960
        }
        window.setContentSize(constrainedContentSize(for: window, contentWidth: width))
        window.center()
    }

    // MARK: - Geometry

    /// A source's first appearance in this window: fit it into 80% of the visible frame at up to
    /// 1:1, then centre. Chrome is charged against the SAME 80% budget, so a window with the tray
    /// open opens smaller rather than overflowing the screen.
    private func sizeToSource(_ source: CGSize, in window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            applyConstraint(to: window)
            return
        }
        let budgetW = visible.width * 0.8
        let budgetH = max(visible.height * 0.8 - chromeHeight, 1)
        let scale = min(budgetW / source.width, budgetH / source.height, 1.0)
        window.setContentSize(constrainedContentSize(for: window,
                                                     contentWidth: source.width * scale))
        window.center()
    }

    /// Re-solve the constraint at the window's CURRENT content width and apply it, anchored to the
    /// top-left so the window grows downward from where the user put it rather than jumping.
    private func applyConstraint(to window: NSWindow) {
        let current = window.contentRect(forFrameRect: window.frame).size
        let fitted = constrainedContentSize(for: window, contentWidth: current.width)
        guard abs(fitted.width - current.width) > 0.5 || abs(fitted.height - current.height) > 0.5
        else { return }

        var frame = window.frameRect(forContentRect: NSRect(origin: window.frame.origin, size: fitted))
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height     // top edge stays put

        // Growing taller must not push the window off the bottom of the screen (or its title bar
        // under the menu bar). Nudge it back into the visible frame rather than letting it grow
        // somewhere the user cannot reach it.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
        }
        window.setFrame(frame, display: true)
    }

    /// THE CONSTRAINT ITSELF: the content size that satisfies
    ///
    ///     contentH = contentW / videoAspect + chromeHeight
    ///
    /// at (or as near as possible to) the requested width, clamped to the window's own minimum and
    /// to what the screen can actually show.
    ///
    /// Read `VideoBox`'s note above before editing this function. The two routes by which chrome is
    /// allowed to touch the geometry are marked below; there is no third, and the `assert` at the
    /// bottom is what says so at runtime.
    private func constrainedContentSize(for window: NSWindow, contentWidth: CGFloat) -> NSSize {
        let aspect = max(videoAspect, 0.01)
        let chrome = max(chromeHeight, 0)
        let minSize = window.contentMinSize
        let maxSize = maximumContentSize(for: window)

        // ── ROUTE 2 — THE SCREEN CAP, AND THE ONLY PLACE CHROME MAY COST PICTURE ──────────
        //
        // A window must never grow beyond what the screen can show, so chrome is charged HERE,
        // against the display's height, and converted into a WIDTH the picture may not exceed.
        // Spending the cap as width rather than as height is what keeps the picture exactly
        // on-shape while it shrinks — the window is smaller, the image is smaller, and no bar
        // appears. This is the sole exception named in `VideoBox`'s header.
        let heightBudget = max(maxSize.height - chrome, 1)
        let widthBudget = max(min(maxSize.width, VideoBox.width(height: heightBudget, aspect: aspect)),
                              minSize.width)

        // ── THE PICTURE, SIZED WITHOUT REFERENCE TO CHROME ───────────────────────────────
        var videoW = min(max(contentWidth, minSize.width), widthBudget)

        // The window's own minimum height can exceed the constraint at this width. Honour it by
        // GROWING the picture — never by shrinking it — so the surplus height is filled with
        // picture rather than with a bar. `max(videoW, …)` is what makes that one-directional, and
        // the budget clamp keeps the growth inside the screen cap.
        if VideoBox.height(width: videoW, aspect: aspect) + chrome < minSize.height {
            videoW = min(max(videoW, VideoBox.width(height: minSize.height - chrome, aspect: aspect)),
                         widthBudget)
        }

        // ── ROUTE 1 — CHROME IS ADDED. THE OPERATOR IS `+`. ──────────────────────────────
        let videoH = VideoBox.height(width: videoW, aspect: aspect)
        // The outer `max` is the residual case the cap cannot solve: the screen cannot show even the
        // smallest legal window, so the content is padded to the window's minimum and the picture
        // pillarboxes inside a box it cannot fill. That is the honest outcome and the only one
        // available — and it is a WINDOW-MINIMUM effect, not a chrome effect.
        let contentH = max(videoH + chrome, minSize.height)

        #if DEBUG
        assertChromeDidNotShrinkVideo(videoWidth: videoW, requestedWidth: contentWidth,
                                      minWidth: minSize.width, maxWidth: maxSize.width,
                                      widthBudget: widthBudget)
        #endif
        return NSSize(width: videoW.rounded(), height: contentH.rounded())
    }

    #if DEBUG
    /// THE INVARIANT, RE-CHECKED AGAINST THE CHROME-FREE ANSWER.
    ///
    /// `VideoBox`'s scoping makes the violation unwriteable inside the picture's own math; this
    /// catches the other half — a caller that narrows the WIDTH BUDGET for some reason other than
    /// the screen cap and so smuggles the shrink in through route 2. If the picture came out
    /// smaller than the same solve would have given with no chrome at all, the budget must be what
    /// bound it. Anything else is the defect this file exists to prevent, and it fails here rather
    /// than shipping as a black bar somebody has to notice and report.
    private func assertChromeDidNotShrinkVideo(videoWidth: CGFloat, requestedWidth: CGFloat,
                                               minWidth: CGFloat, maxWidth: CGFloat,
                                               widthBudget: CGFloat) {
        let chromeFree = min(max(requestedWidth, minWidth), maxWidth)   // the same solve, chrome = 0
        guard videoWidth + 0.5 < chromeFree else { return }             // not smaller — nothing to check
        assert(widthBudget + 0.5 < chromeFree, """
            CHROME REDUCED THE VIDEO'S SIZE — invariant violated.
            picture \(videoWidth) wide against a chrome-free \(chromeFree), with a width budget of \
            \(widthBudget) that is NOT the screen cap. Chrome may only be ADDED to the window's \
            height; the screen cap is the one exception, and it is not what bound this solve. \
            See the VideoBox header in WindowSizer.swift.
            """)
    }
    #endif

    /// The largest CONTENT size this window's screen can show. Derived through
    /// `contentRect(forFrameRect:)` rather than by subtracting an assumed title-bar height: the app
    /// uses `.hiddenTitleBar`, so the inset is nominally zero today, but assuming that is how a
    /// style-mask change turns into a window that is quietly a title bar too tall.
    private func maximumContentSize(for window: NSWindow) -> NSSize {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return NSSize(width: CGFloat.greatestFiniteMagnitude,
                          height: CGFloat.greatestFiniteMagnitude)
        }
        return window.contentRect(forFrameRect: NSRect(origin: .zero, size: visible.size)).size
    }

    /// Programmatic resizes are refused in the three states where the window's size is not ours to
    /// state: full screen (the screen owns it), miniaturised (there is nothing to resize), and mid
    /// live-resize (the user's hand is on it — `windowWillResize` is already applying the
    /// constraint, and a `setFrame` from underneath would fight the drag).
    private func isResizable(_ window: NSWindow) -> Bool {
        !window.styleMask.contains(.fullScreen) && !window.isMiniaturized && !window.inLiveResize
    }
}
