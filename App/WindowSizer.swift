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

/// WHAT THE RASTER CONTROL ASKS THE WINDOW TO BE. The view layer's `RasterSize` reduced to the only
/// three things this file can act on, so the geometry never has to know what a menu item is called.
///
/// Declared here rather than in RasterSize.swift because the conversion from a fraction to a width
/// is a GEOMETRY question — it needs the display's backing scale — and this is the file that owns
/// window geometry. See `rasterContentWidth`.
enum RasterRequest: Equatable {

    /// No policy. The window keeps the width it has, and a chrome change re-derives from it exactly
    /// as it did before this control existed. Both `.automatic` (nothing chosen yet) and `.custom`
    /// (the user dragged an edge) arrive here.
    case unconstrained

    /// A fraction of the source's DISPLAY width, in SOURCE PIXELS. 1.0 is one source pixel per
    /// source pixel.
    case sourceFraction(CGFloat)

    /// The largest picture the visible frame can show WITH the chrome. Expressed as an unbounded
    /// width request, because `constrainedContentSize`'s screen cap already computes exactly that —
    /// there is no second fitting routine, and so no second answer to keep in step with the first.
    case fitToScreen
}

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

    /// The content width the raster policy last asked for, in points, or nil for "no policy". Held
    /// so `setGeometry` can tell a raster CHANGE from the many passes that carry the same one — the
    /// same job `videoAspect` and `chromeHeight` do for their own inputs.
    private var lastRasterWidth: CGFloat?

    /// THE USER PUT THEIR HAND ON A WINDOW EDGE. Fired from `windowWillResize` during a live resize
    /// and from the zoom button, and wired by `WindowConfigurator` to set this window's raster state
    /// to `.custom`.
    ///
    /// A callback and not a direct write, because the state it changes is a `WindowChrome` — a
    /// SwiftUI `@StateObject` owned by `ContentView` — and this file's whole discipline is that it
    /// knows about NSWindows and nothing about views.
    var onUserResize: (() -> Void)?

    /// ⚠️ SET AROUND EVERY RESIZE THIS FILE ITSELF PERFORMS, AND IT IS NOT BELT-AND-BRACES.
    /// `windowWillResize(_:to:)` is delivered for programmatic `setFrame`/`setContentSize` calls as
    /// well as for user drags. Without this flag, applying a raster preset would resize the window,
    /// be told about its own resize, and immediately declare the result `.custom` — the control
    /// would cancel itself on every use. `inLiveResize` alone is not enough to separate the two:
    /// a programmatic resize DURING a live resize is exactly what the divider does.
    private var isApplyingProgrammaticResize = false

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

        // A HAND ON THE EDGE ENDS THE RASTER POLICY. The drag is honoured as it always was — this
        // does NOT snap to the nearest preset, and the constraint below still keeps the picture on
        // shape — but the window is no longer at a size anything can claim to have chosen, so the
        // state becomes `.custom` and the readout says so. Gated on `inLiveResize` so this file's
        // own resizes (which arrive here too) cannot mistake themselves for the user.
        if sender.inLiveResize && !isApplyingProgrammaticResize { onUserResize?() }

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

        // Zoom is a user gesture that sets a size, so it ends the raster policy exactly as an edge
        // drag does. It is deliberately NOT routed to `.fitToScreen` even though the two land in
        // almost the same place: Fit is a MODE that re-fits when the chrome changes, and silently
        // putting a window into a mode because the green button was pressed would then move the
        // window again later, for a reason the user could not connect to anything they did.
        if !isApplyingProgrammaticResize { onUserResize?() }

        let content = window.contentRect(forFrameRect: proposed).size
        let fitted = constrainedContentSize(for: window, contentWidth: content.width)
        var frame = window.frameRect(forContentRect: NSRect(origin: proposed.origin, size: fitted))
        frame.origin.y = proposed.maxY - frame.height     // keep the top edge where zoom put it
        return frame
    }

    // MARK: - Driving it from the view layer

    /// ── WHERE THE SCOPE DIVIDER STOPS (Arc C) ───────────────────────────────────────────────
    ///
    /// The tallest total chrome this window can carry while the window is still ALLOWED TO GROW to
    /// hold it — i.e. the last value at which `constrainedContentSize` does not have to take the
    /// screen cap and start charging the difference to the picture.
    ///
    /// This is the whole of the divider's upper limit, and it is expressed HERE rather than in the
    /// view because the three quantities it needs are all this file's: the screen's usable content
    /// height, the picture's aspect, and the window's current width. Returning a number the view
    /// clamps to is what makes the divider STOP at the cap instead of pushing through it and
    /// silently shrinking the video — the rejected design in docs/ARC-C-SCOPE-DIVIDER.md.
    ///
    /// Derived from the window's CURRENT WIDTH, deliberately: the picture's height is
    /// `width / aspect` and a divider drag does not change the width, so `maxContentH − videoH` is
    /// exactly the room left underneath. Re-read on every drag event, so widening the window (or
    /// moving it to a larger display) immediately gives the divider more travel.
    ///
    /// `.greatestFiniteMagnitude` when there is no window yet — "not limited by anything I know
    /// about", which the view's own floor still bounds from below.
    ///
    /// ⚠️ `sourceSize` IS NOT DECORATION — IT CLOSES THE COLD-LAUNCH CASE, and the failure it fixes
    /// is one a self-consistent answer cannot recover from. Before the first source has sized this
    /// window, the current width is the placeholder default (1280), which understates the picture's
    /// height and so OVERSTATES the room left for chrome. `sizeToSource` then spends the
    /// overstatement in the same pass, the screen cap shrinks the picture to make it fit, and every
    /// subsequent pass agrees with the shrunken result — because a smaller picture really does leave
    /// more room for chrome. The state is stable and wrong.
    ///
    /// MEASURED: launching docked with a 1050-pt tray opened a 1920×1080 file into a 1787-wide
    /// picture. Taking the width the source is ABOUT to open at makes the tray yield the 75 points
    /// instead, which is what the divider's contract says should happen.
    ///
    /// Only consulted until `hasSizedToSource`; after that the window's real width is authoritative,
    /// so deliberately narrowing a window still buys tray room.
    func maxChromeHeight(openingFor sourceSize: CGSize?, raster: RasterRequest) -> CGFloat {
        guard let window else { return .greatestFiniteMagnitude }
        let maxContentHeight = maximumContentSize(for: window).height
        // The source's own aspect when it is known: on the pass that first carries a source,
        // `videoAspect` has not been updated yet (this is read while the view is computing the
        // chrome height it is about to hand to `setGeometry`).
        let aspect: CGFloat = {
            guard let s = sourceSize, s.width > 0, s.height > 0 else { return videoAspect }
            return s.width / s.height
        }()

        // ── FIT TO SCREEN MEASURES AGAINST THE SMALLEST LEGAL PICTURE, NOT THE CURRENT ONE ────
        //
        // Under every other state the picture's size is FIXED and the divider's ceiling is the room
        // left under it. Under Fit the picture is DEFINED as "whatever is left after the chrome", so
        // measuring against the current picture is circular and the answer it produces is a stuck
        // control: a fitted window is already at the screen cap, so `maxContentHeight − videoHeight`
        // comes out as exactly the chrome that is already there. The divider could shrink and never
        // grow, and dragging down would do nothing.
        //
        // So under Fit the tray's travel is bounded by the smallest window this app allows
        // (`contentMinSize`), and the picture pays for the tray as it grows — through the SCREEN CAP
        // in `constrainedContentSize`, which is route 2, the one documented exception. That is not a
        // new exception and not a violation of the invariant: it is what the user asked for when
        // they chose a size defined as "as large as fits, chrome included".
        // `sourceSize != nil` for the same reason `rasterContentWidth` insists on it: with no
        // picture there is no policy in force, so the ordinary answer below is the right one.
        if case .fitToScreen = raster, sourceSize != nil {
            let smallestPicture = VideoBox.height(width: window.contentMinSize.width, aspect: aspect)
            return max(maxContentHeight - smallestPicture, 0)
        }

        var width = window.contentRect(forFrameRect: window.frame).size.width
        if !hasSizedToSource, let sourceSize {
            // A RASTER POLICY STATES THE OPENING WIDTH EXACTLY, so it replaces the prediction rather
            // than being max()'d with it. `max` is right for the classic rule (which only ever
            // ENLARGES on the placeholder width) and wrong here: a 25% preset opens a window
            // NARROWER than the 1280-pt placeholder, and keeping the placeholder would understate
            // the tray's room instead of overstating it — a different wrong answer, not a safe one.
            if let rasterWidth = rasterContentWidth(raster, sourceSize: sourceSize),
               !Self.isUnbounded(rasterWidth) {
                width = rasterWidth
            } else if let opening = openingContentWidth(for: sourceSize, in: window) {
                width = max(width, opening)
            }
        }
        return max(maxContentHeight - VideoBox.height(width: width, aspect: aspect), 0)
    }

    /// ── THE PERCENTAGE, TURNED INTO A WIDTH — AND THE ONE DIVISION THAT DEFINES "100%" ──────
    ///
    /// The content width, IN POINTS, that a raster request asks for. nil means "no policy, leave the
    /// width alone"; `.greatestFiniteMagnitude` means "as large as allowed", which
    /// `constrainedContentSize` resolves against the screen cap and nothing else has to.
    ///
    /// ⚠️ THE DIVISION BY `backingScaleFactor` IS THE WHOLE DEFINITION OF 100%, and it is here
    /// exactly once. A 3840-pixel-wide source at 100% is 1920 POINTS wide on a 2× display, because
    /// 1920 points ARE 3840 pixels there — one source pixel per source pixel, which is what a
    /// colourist means by 100% and the only reading under which the control is worth having.
    /// Removing the division would draw each source pixel across a 2×2 block and label it 100%.
    ///
    /// The scale is read from the WINDOW, so a window living on a 1× display gets 1× and the
    /// promise holds there too.
    /// "AS LARGE AS THE DISPLAY ALLOWS" — a width REQUEST, not a number to compute with.
    /// `constrainedContentSize` resolves it against the screen cap, and no other code should do
    /// arithmetic on it.
    ///
    /// ⚠️ IT IS FINITE. `.greatestFiniteMagnitude` is by definition the largest finite Double, so
    /// `isFinite` returns TRUE for it and is NOT a guard — a `Int(_:)` conversion behind an
    /// `isFinite` test traps at runtime, which is exactly how it crashed the first build of the
    /// diagnostic line below. `isUnbounded` is the test; use it.
    static let unboundedWidth = CGFloat.greatestFiniteMagnitude

    static func isUnbounded(_ width: CGFloat) -> Bool { width >= 1_000_000 }

    func rasterContentWidth(_ raster: RasterRequest, sourceSize: CGSize?) -> CGFloat? {
        // ⚠️ NO SOURCE, NO POLICY — INCLUDING FIT, WHICH DOES NOT NEED THE SOURCE TO COMPUTE A WIDTH
        // AND MUST STILL DECLINE. Raster size is a statement about the PICTURE, and an empty window
        // has none. MEASURED: without this, relaunching with Fit stored opened the empty launch
        // window at the full 3135×2130 visible frame — a window with nothing in it claiming the whole
        // display — while a stored PERCENTAGE (which cannot be computed without a source) correctly
        // left it at the 1280-pt default. Two states, two different opening sizes, for a window in
        // the same condition. Declining here makes every state agree: no source, `installDefaultSize`
        // decides, exactly as before this arc.
        guard let source = sourceSize, source.width > 0, source.height > 0 else { return nil }

        switch raster {
        case .unconstrained:
            return nil
        case .fitToScreen:
            return Self.unboundedWidth
        case .sourceFraction(let fraction):
            guard fraction > 0 else { return nil }
            let scale = window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
            return (source.width * fraction / max(scale, 1)).rounded()
        }
    }

    /// The content width a source opens at: fitted into 80% of the visible frame, never magnified
    /// past 1:1. Shared by `sizeToSource` (which applies it) and `maxChromeHeight` (which has to
    /// predict it one pass early) so the two cannot drift — the whole cold-launch bug above was the
    /// two disagreeing about how wide the picture was going to be.
    private func openingContentWidth(for source: CGSize, in window: NSWindow) -> CGFloat? {
        guard source.width > 0, source.height > 0,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let scale = min(visible.width * 0.8 / source.width,
                        visible.height * 0.8 / source.height, 1.0)
        return source.width * scale
    }

    /// The picture's shape and the chrome below it, as SwiftUI currently has them. Called from
    /// `WindowConfigurator.updateNSView`, i.e. on every body pass, and a no-op when nothing moved.
    ///
    /// `sourceSize` is `FrameEngine.displaySize` verbatim — nil means "no source", which is a
    /// different statement from "16:9". The fallback is applied HERE and nowhere else.
    func setGeometry(sourceSize: CGSize?, chromeHeight: CGFloat, raster: RasterRequest) {
        let aspect: CGFloat = {
            guard let s = sourceSize, s.width > 0, s.height > 0 else { return 16.0 / 9.0 }
            return s.width / s.height
        }()
        let chrome = max(0, chromeHeight)
        let rasterWidth = rasterContentWidth(raster, sourceSize: sourceSize)

        let aspectChanged = abs(aspect - videoAspect) > 0.0001
        let chromeChanged = abs(chrome - self.chromeHeight) > 0.5
        let gainedSource = (sourceSize != nil && !hasSizedToSource)
        let rasterChanged: Bool = {
            switch (rasterWidth, lastRasterWidth) {
            case (nil, nil):               return false
            case let (new?, old?):         return abs(new - old) > 0.5
            default:                       return true   // a policy appeared, or went away
            }
        }()

        videoAspect = aspect
        self.chromeHeight = chrome
        lastRasterWidth = rasterWidth

        guard aspectChanged || chromeChanged || gainedSource || rasterChanged else { return }
        guard let window, isResizable(window) else { return }

        // ONE LINE PER RASTER CHANGE, and only on a change — this is the record that says whether a
        // window ended up the size it was ASKED to be or the size the display ALLOWED, which is the
        // one question a "my picture is smaller than 100%" report cannot answer from a screenshot.
        // It carries the backing scale explicitly because that term IS the definition of 100%, and
        // it is the first thing to doubt when the numbers come out twice or half what they should.
        defer {
            if rasterChanged, let rasterWidth {
                let content = window.contentRect(forFrameRect: window.frame).size
                // See `isUnbounded` — `isFinite` is not the test, and using it here is what SIGTRAPed
                // on the first click of Fit to Screen.
                let asked = Self.isUnbounded(rasterWidth) ? "unbounded" : "\(Int(rasterWidth))"
                NSLog("%@", "[RASTER] \(raster)"
                    + " source=\(Int(sourceSize?.width ?? 0))×\(Int(sourceSize?.height ?? 0))"
                    + " scale=\(window.backingScaleFactor)"
                    + " asked=\(asked)"
                    + " → content=\(Int(content.width))×\(Int(content.height))"
                    + " video=\(Int(content.width))×\(Int((content.height - chrome).rounded()))"
                    + " chrome=\(Int(chrome))")
            }
        }

        if gainedSource, let sourceSize {
            hasSizedToSource = true
            hasInstalledDefault = true
            // A raster policy OVERRIDES the classic opening rule, which is the point of persisting
            // one: a user who has chosen 50% has said what "open this file" should look like. With
            // no policy (`.automatic`, and therefore every fresh install) `sizeToSource` runs
            // exactly as it always has, so this arc changes nothing until someone asks it to.
            if let rasterWidth {
                setContentSize(constrainedContentSize(for: window, contentWidth: rasterWidth),
                               of: window)
                window.center()
            } else {
                sizeToSource(sourceSize, in: window)
            }
        } else {
            // ⚠️ RE-DERIVED FROM THE CURRENT WIDTH WHEN THERE IS NO RASTER POLICY, WHICH IS WHAT
            // MAKES THE VIDEO HOLD STILL. The width is the video's width; re-solving the affine
            // constraint at that width changes ONLY the height, by exactly the chrome delta. Opening
            // the tray therefore grows the window and leaves the picture the size it was, which is
            // the whole point of the arc before this one.
            //
            // With a policy, the requested width is passed instead — and for a PRESET that is the
            // same statement, because a preset's width does not depend on the chrome either. The
            // one state where the two genuinely differ is `.fitToScreen`, which is defined in terms
            // of the chrome and therefore MUST re-solve when it changes.
            applyConstraint(to: window, contentWidth: rasterWidth)
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
        setContentSize(constrainedContentSize(for: window, contentWidth: width), of: window)
        window.center()
    }

    // MARK: - Geometry

    /// A source's first appearance in this window: fit it into 80% of the visible frame at up to
    /// 1:1, then centre.
    ///
    /// ⚠️ THE 80% BUDGET IS THE PICTURE'S, AND CHROME IS NOT CHARGED AGAINST IT. This used to read
    /// `visible.height * 0.8 - chromeHeight`, on the reasoning that a window with the tray open
    /// should open smaller rather than overflow the screen. That is the invariant inverted: it makes
    /// the PICTURE pay for the tray, at the one moment the user cannot see it happen.
    ///
    /// MEASURED, and this is why it changed: with a tray dragged to 1050 pt (Arc C's divider makes
    /// that reachable), a 1920×1080 file opened into a 1163×654 picture — the source scaled to 60%
    /// for no reason the user could see, because 1704 − 1050 left the picture 654 points of budget.
    /// Charging only the picture opens it at 1920×1080 with the window 2130 tall, which is exactly
    /// the visible frame.
    ///
    /// So a window with tall chrome now opens TALLER than 80% of the screen — up to the screen cap,
    /// which `constrainedContentSize` still enforces and which remains the sole place the picture is
    /// allowed to shrink. The 80% is a rule about how much of the display the PICTURE claims, not
    /// about the window.
    private func sizeToSource(_ source: CGSize, in window: NSWindow) {
        guard let width = openingContentWidth(for: source, in: window) else {
            applyConstraint(to: window)
            return
        }
        setContentSize(constrainedContentSize(for: window, contentWidth: width), of: window)
        window.center()
    }

    /// Re-solve the constraint and apply it, anchored to the top-left so the window grows downward
    /// from where the user put it rather than jumping.
    ///
    /// `contentWidth` is the raster policy's requested width, or nil to re-solve at the window's
    /// CURRENT width — the two callers this file has always had (a chrome change, a shape change)
    /// pass nil and are unchanged by the raster arc.
    private func applyConstraint(to window: NSWindow, contentWidth: CGFloat? = nil) {
        let current = window.contentRect(forFrameRect: window.frame).size
        let fitted = constrainedContentSize(for: window, contentWidth: contentWidth ?? current.width)
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
        setFrame(frame, of: window)
    }

    // MARK: - Resizing under our own name

    /// The two window-resizing calls this file makes, wrapped so `windowWillResize` can tell them
    /// apart from the user's hand. See `isApplyingProgrammaticResize` — without this, applying a
    /// preset would be reported back to us as a manual drag and would immediately undo itself.
    private func setFrame(_ frame: NSRect, of window: NSWindow) {
        isApplyingProgrammaticResize = true
        window.setFrame(frame, display: true)
        isApplyingProgrammaticResize = false
    }

    private func setContentSize(_ size: NSSize, of window: NSWindow) {
        isApplyingProgrammaticResize = true
        window.setContentSize(size)
        isApplyingProgrammaticResize = false
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
