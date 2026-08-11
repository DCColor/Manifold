//
//  WindowDeck.swift
//  Manifold
//
//  THE REGISTRATION SEAM. One window = one deck = one FrameEngine + one MetalVideoRenderer, and
//  this file is the ONLY place that wires a deck to anything app-wide.
//
//  ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
//
//  Stage 1 gave every window its own FrameEngine. Before that there was exactly one engine, and
//  ContentView's `.onAppear` wired it to five singletons — the four `*.shared.renderer`
//  assignments, the three `onWillActivateStream` hooks, both audio taps, the SDI silence gate and
//  the system-audio routing closure. With one engine those assignments were IDEMPOTENT: every
//  window wrote the same object, so "last writer wins" and "only writer" were the same statement
//  and nothing could go wrong.
//
//  With N engines they stop being idempotent and become N conflicting writers of app-wide state,
//  spread across a sixty-line block that every window runs. The POLICY is unchanged in stage 1 —
//  most recently registered window wins, exactly as before — but it is now stated ONCE, here,
//  instead of being an emergent property of who happened to run `.onAppear` last.
//
//  That is the whole point of this file. Stage 2 (arbitration: only one window plays; a window
//  owning an exclusive device disables every other window's transport) is a change to
//  `adoptHost` and the key-window observation marked below. It is NOT a change to ContentView,
//  and it does not require unpicking four copies of anything.
//
//  ── WHY viewDidMoveToWindow AND NOT .onAppear ──────────────────────────────────────────
//
//  `.onAppear` fires per VIEW INSERTION and hands back no window identity. It can fire more than
//  once for one window, and it cannot tell you WHICH window it fired for — so it cannot key a
//  registry, and it cannot deregister. `viewDidMoveToWindow` fires with the NSWindow in hand, and
//  fires again with nil on teardown, which is exactly the register/deregister pair a registry
//  needs. It is also the app's existing idiom for reaching the window: WindowConfigurator
//  (PlayerWindow.swift) already does this, though via a `DispatchQueue.main.async` hop because
//  `view.window` is nil during `makeNSView`. Overriding `viewDidMoveToWindow` needs no hop and
//  also survives a view being re-hosted into a different window.
//
//  ── LIFETIME ───────────────────────────────────────────────────────────────────────────
//
//  Every reference held here is WEAK. SwiftUI owns the engine and the renderer (both
//  `@StateObject` in ContentView) and AppKit owns the window; this registry is a directory, not
//  an owner. A missed deregistration therefore degrades to a pruned nil rather than to a window
//  that outlives its own close. The closures installed into the singletons capture the engine
//  weakly for the same reason — before stage 1 they captured it strongly and that was harmless
//  (the engine was app-lifetime), but a strong capture now would pin a closed window's engine,
//  and its audio renderer, inside `DeckLinkService.shared` forever.
//

import SwiftUI
import AppKit
import ManifoldCore

// MARK: - One window's deck

/// The per-window playback deck: this window's identity, engine and renderer.
///
/// `ObservableObject` ONLY so ContentView can hold it in a `@StateObject` — which is the point,
/// because `@StateObject` evaluates its initializer exactly once per window and `@State` would
/// re-run the expression on every View-struct re-creation (the measured bug documented on
/// `RendererStore` in ContentView.swift).
///
/// NOTHING HERE IS `@Published`, DELIBERATELY. These properties are written from AppKit callbacks
/// (`viewDidMoveToWindow`) and from `updateNSView`, both of which can land inside a SwiftUI update
/// pass. Publishing them would invalidate the view mid-update ("Modifying state during view
/// update"). No view needs to re-render when they change — they are read at action time (a file
/// load), never rendered.
@MainActor
final class WindowDeck: ObservableObject {

    /// The NSWindow hosting this deck, or nil before the view is in a window / after teardown.
    fileprivate(set) weak var window: NSWindow?

    /// This window's engine and renderer. Populated by `WindowDeckRegistrar` before the window
    /// callback can run, so `DeckRegistry.register` always sees a complete deck.
    fileprivate weak var engine: FrameEngine?
    fileprivate weak var renderer: MetalVideoRenderer?

    /// TRUE only when this deck is positively identifiable as a NON-front window while another
    /// registered deck IS front.
    ///
    /// ⚠️ THE CONSERVATIVE DIRECTION IS LOAD-BEARING — read `DeckRegistry.frontmostDeckWindow`
    /// before changing it. This answers "is some OTHER deck definitely in front", not "am I key".
    /// The naive form (`window === NSApp.keyWindow`) is wrong for the single-window case that is
    /// 99% of use: a Finder double-click that launches or reactivates the app can arrive before
    /// the window is key, so the naive test would report the ONE open window as a background deck
    /// and silently suppress autoplay on the app's most common path.
    var isBackgroundDeck: Bool {
        guard let window else { return false }                        // no identity → never assume
        guard let front = DeckRegistry.shared.frontmostDeckWindow else { return false }
        return front !== window
    }

    /// Autoplay for a load originating in THIS window: the user's preference, suppressed when
    /// this deck is demonstrably not the front one. Stage 1's simple frontmost check — stage 2
    /// replaces the whole question with arbitration (only one deck is playable at all).
    var shouldAutoplayOnLoad: Bool {
        Preferences.shared.autoplayOnLoad && !isBackgroundDeck
    }
}

// MARK: - The registry

/// Every open deck, and the one that currently holds the app-wide hooks.
///
/// STAGE 1 POLICY, STATED ONCE: the most recently REGISTERED deck is the host. That is
/// byte-identical to the behaviour before this file existed (the last window to run `.onAppear`
/// won every assignment), and registration happens at window creation, so the frequency is
/// unchanged too. What has changed is only that the rule is now written down in one method
/// instead of being an accident of ordering across sixty lines that every window ran.
@MainActor
final class DeckRegistry {

    static let shared = DeckRegistry()

    /// Weak by design — see the LIFETIME note in the file header.
    private struct Entry {
        weak var deck: WindowDeck?
        weak var window: NSWindow?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// The deck currently holding the app-wide hooks. Weak: if its window closes without a clean
    /// deregistration, this goes nil rather than resurrecting a dead deck.
    private weak var hostDeck: WindowDeck?

    private var closeObserver: NSObjectProtocol?

    private init() {
        // BELT AND BRACES. `viewDidMoveToWindow(nil)` is the primary deregistration path and it is
        // the one that fires in practice, but it depends on AppKit tearing the view hierarchy down
        // in the order we expect. A window close is unambiguous, so observe it too; `deregister`
        // is idempotent, so whichever arrives first wins and the second is a no-op.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { DeckRegistry.shared.deregister(window: window) }
        }
    }

    // MARK: Frontmost

    /// The front window AMONG REGISTERED DECKS, or nil when the question is unanswerable or
    /// meaningless.
    ///
    /// Returns nil in three cases, and each nil is a deliberate "don't suppress anything":
    ///   * fewer than two decks — a lone window can never be "a background window";
    ///   * the key/main window is not a deck (Settings, About, an NSOpenPanel, a popover) — the
    ///     user is in a panel, which says nothing about which DECK is front;
    ///   * nothing is key or main at all (the app is in the background, e.g. a Finder open
    ///     arriving at a launch).
    ///
    /// AppKit's key window is checked first and its main window second: a Manifold window that is
    /// front while a panel holds key still reads as main, which is the answer we want.
    var frontmostDeckWindow: NSWindow? {
        prune()
        guard entries.count > 1 else { return nil }
        let deckWindows = entries.values.compactMap(\.window)
        if let key = NSApp.keyWindow, deckWindows.contains(where: { $0 === key }) { return key }
        if let main = NSApp.mainWindow, deckWindows.contains(where: { $0 === main }) { return main }
        return nil
    }

    // MARK: Registration

    /// Register a deck's window and configure it. Idempotent for a window already registered to
    /// the same deck (a re-entrant `viewDidMoveToWindow` re-runs the wiring harmlessly — every
    /// assignment in `configure` is a plain overwrite of a per-window value).
    fileprivate func register(_ deck: WindowDeck, window: NSWindow) {
        prune()
        deck.window = window
        entries[ObjectIdentifier(window)] = Entry(deck: deck, window: window)
        configure(deck)
        adoptHost(deck)
    }

    /// Drop a window's deck. Safe to call for a window that was never registered.
    ///
    /// ⚠️ STAGE 1 DOES NOT RELEASE EXCLUSIVE DEVICES HERE, and that is a known gap, not an
    /// oversight: if the host window closes while DeckLink output is running or a stream is live,
    /// the device stays claimed and the singletons' `weak var renderer` simply goes nil (the card
    /// falls to its neutral-black fallback). Fixing that is device ownership, which is stage 2 —
    /// see docs/MULTIWINDOW_FINDINGS.md. This is the method stage 2 extends.
    fileprivate func deregister(window: NSWindow) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.deck?.window = nil
        if let host = hostDeck, host === entry.deck {
            relinquishHost(host)
            hostDeck = nil
            // Hand the hooks to a surviving deck so the app keeps working with the windows that
            // are left. Arbitrary among survivors — which is exactly as arbitrary as the "most
            // recent registration" rule it continues, and stage 2 replaces both with a real
            // active-deck concept.
            if let successor = entries.values.compactMap(\.deck).first {
                adoptHost(successor)
            }
        }
    }

    private func prune() {
        entries = entries.filter { $0.value.window != nil && $0.value.deck != nil }
    }

    // MARK: Per-deck wiring (runs for EVERY window)

    /// Wire one deck's engine to its own renderer. Purely per-window — nothing here touches
    /// app-wide state, so every deck runs it and no deck can disturb another.
    ///
    /// This is the half that was ALREADY correct per window before stage 1 and merely could not
    /// take effect: with one shared engine, `engine.onVideoFrame` is a single-assignment closure,
    /// so the second window to run `.onAppear` repointed the shared engine's video tee at its own
    /// Metal renderer and the FIRST window's picture froze. One engine per deck makes these
    /// assignments correct by construction.
    private func configure(_ deck: WindowDeck) {
        guard let engine = deck.engine else { return }

        // Apply persisted volume (mute is not persisted — starts unmuted). Per deck: each engine
        // has its own output gain. See the volume note in docs/MULTIWINDOW_FINDINGS.md.
        engine.setVolume(Float(Preferences.shared.playbackVolume))

        guard let renderer = deck.renderer else { return }

        // The renderer reads the engine for its clock, pause state and range/chroma flags. Strong
        // captures are correct HERE and only here: the renderer and the engine are both owned by
        // the same window and die together, and the reverse edge (engine → renderer, below) is
        // weak, so there is no cycle.
        renderer.clock = { engine.currentSyncTime().seconds }
        renderer.isPausedProvider = { engine.isPausedNow() }
        renderer.isFullRangeProvider = { engine.currentEffectiveIsFullRange() }
        renderer.chromaConventionProvider = { engine.currentChromaConventionRaw() }

        // …and the engine feeds this window's renderer, and only this one.
        engine.onVideoFrame = { [weak renderer] sb in renderer?.enqueue(sb) }
        engine.onFlush = { [weak renderer] in renderer?.flush() }

        // Seed the kernel's CIE mode from the persisted value so the scatter opens in the
        // last-left mode even if a source loaded before the CIE scope is shown. Set BEFORE
        // start(), so the first rendered frame already plots in the right mode. (The CIE view's
        // header/graticule read the same @AppStorage directly, so they are already correct; this
        // keeps the kernel-side plot in agreement.) ⌃⌥X and the header menu push their own
        // updates afterwards via CIEScopeModel.applyMode.
        renderer.cieUseUV = UserDefaults.standard.object(forKey: Self.cieUseUVKey) as? Bool ?? true

        renderer.start()
    }

    /// The @AppStorage key ContentView and CIEScopeView both bind. Read here rather than passed
    /// in, so the seeding cannot silently diverge from the value the CIE views themselves read.
    private static let cieUseUVKey = "manifold.cie.useUV"

    // MARK: Host adoption (the app-wide hooks — ONE deck at a time)

    /// Point every app-wide consumer at `deck`. THIS METHOD IS THE POLICY.
    ///
    /// Stage 1 keeps the pre-existing rule verbatim — most recently registered deck wins — and
    /// makes no attempt to arbitrate. Every hook below was previously a line in ContentView's
    /// `.onAppear`; the assignments and their order are unchanged, only their location is.
    ///
    /// ⚠️ STAGE 2 CHANGES THIS METHOD AND (almost) NOTHING ELSE. Arbitration means: observe
    /// `NSWindow.didBecomeKeyNotification`, look the window up in `entries`, IGNORE it entirely if
    /// it is not a registered deck (Settings, About, NSOpenPanel and popovers all become key and
    /// must not count), and on a real deck change pause the outgoing deck and make the incoming
    /// one playable. The device half — refusing a claim while another deck owns DeckLink/NDI/WHEP/
    /// SRT — also lands here, next to the assignments it has to guard.
    private func adoptHost(_ deck: WindowDeck) {
        if let previous = hostDeck, previous !== deck { relinquishHost(previous) }
        hostDeck = deck

        guard let engine = deck.engine else { return }
        let renderer = deck.renderer   // weak on every service below; nil is tolerated everywhere

        // DeckLink output sources real video from this renderer (⌃⌥O / toolbar control).
        DeckLinkService.shared.renderer = renderer
        // NDI displays THROUGH this same renderer — it pulls frames on the display tick and feeds
        // the same enqueue the file sources do.
        NDIService.shared.renderer = renderer
        // A web stream displays through this SAME renderer, feeding the same enqueue NDI and the
        // file sources feed — but paced by LiveClock rather than FrameSync or the file timebase.
        WHEPFrameRouter.shared.renderer = renderer
        // An SRT stream is a push source exactly like WHEP — same renderer, same enqueue, same
        // LiveClock pacing through the same LiveDisplayRoute.
        SRTFrameRouter.shared.renderer = renderer

        // One active source (the reverse of the file-open path disconnecting the stream): when a
        // stream is about to take over, retire the loaded file first so both don't feed the
        // renderer at once. The services have no engine handle, so they call back through here.
        //
        // ⚠️ KNOWN-WRONG UNDER THE MULTI-WINDOW MODEL, KEPT VERBATIM FOR STAGE 1. This reaches
        // exactly ONE engine — the host's — so a stream taking the display leaves every other
        // deck playing into a renderer it no longer owns. And `stop()` is a full unload (it zeroes
        // hasMedia / currentURL / duration / tcInfo), which is the correct verb for the deck being
        // taken over and the WRONG one for a deck that should merely yield the transport and keep
        // its paused frame, scopes and inspector. Introducing the softer retirement is stage 2 —
        // see docs/MULTIWINDOW_FINDINGS.md, "bigger than it looks".
        NDIService.shared.onWillActivateStream = { [weak engine] in engine?.stop() }
        WHEPFrameRouter.shared.onWillActivateStream = { [weak engine] in engine?.stop() }
        SRTFrameRouter.shared.onWillActivateStream = { [weak engine] in engine?.stop() }

        // Tee NDI audio into the SAME PTS-keyed PCM ring the file paths feed, so the clock-anchored
        // SDI output, SDI/Computer routing and mute apply to NDI for free.
        NDIService.shared.audioTap = engine.audioTap
        // D4b-2: SDI audio from the engine's PTS-keyed PCM ring, gated by the transport. The card's
        // audio callback pulls from the ring at the SOURCE TIME of the frame the renderer currently
        // has staged for the card, so A/V are aligned by construction.
        DeckLinkService.shared.audioTap = engine.audioTap
        // Weak capture, and the `?? true` matches DeckLinkService's own default at the call site
        // (`isCardAudioSilentProvider?() ?? true`): with no engine to ask, the honest answer is
        // silence, never a drone of whatever PCM the ring last held.
        DeckLinkService.shared.isCardAudioSilentProvider = { [weak engine] in
            engine?.isCardAudioSilent() ?? true
        }
        // D4b-3: the SDI and computer paths are mutually exclusive. This is the service's ONLY
        // authority over the system renderer — it passes (outputEnabled && destination == .sdi),
        // and the engine folds that into its existing applyAudioMute rule.
        DeckLinkService.shared.systemAudioRouting = { [weak engine] owns in
            engine?.setDeckLinkOwnsAudio(owns)
        }
        // The card must be ENABLED with a fixed rate/channel count before playback starts, so a
        // file whose audio format differs re-establishes the output (this is also what lets you
        // enable output BEFORE loading a file and still get audio).
        //
        // HOST-ONLY, AND THAT IS THE BEHAVIOUR-PRESERVING CHOICE. Before stage 1 this was set on
        // `engine.audioTap` — one engine, one tap, so exactly one handler existed. Setting it on
        // every deck's tap (the literal transcription of the old line into a per-window context)
        // would be a NEW behaviour: any background window loading a 5.1 file would re-establish
        // the card out from under the foreground window. `relinquishHost` clears it again.
        engine.audioTap.onFormatChange = { fmt in DeckLinkService.shared.audioFormatChanged(fmt) }

        DeckLinkService.shared.refreshDevices()   // populate the device picker
        // Explicit "Enable output on launch" preference (Settings → DeckLink Output): start output
        // now IF the pref is on AND a capable device is present (no-op otherwise). Self-guarded to
        // once per process by `hasAutoStarted`, so running it per host adoption is the same
        // single start it always was.
        DeckLinkService.shared.autoStartOnLaunchIfEnabled()
    }

    /// Undo the host-only wiring for a deck that is no longer the host. Only `onFormatChange`
    /// needs undoing — every other hook above is an assignment that the incoming host overwrites.
    private func relinquishHost(_ deck: WindowDeck) {
        deck.engine?.audioTap.onFormatChange = nil
    }
}

// MARK: - The representable

/// Mounts a zero-size NSView whose only job is to hand its NSWindow to `DeckRegistry`.
///
/// A sibling of `WindowConfigurator` (PlayerWindow.swift), which does the same reach-for-the-window
/// trick for aspect locking and the traffic-light fade.
struct WindowDeckRegistrar: NSViewRepresentable {
    let deck: WindowDeck
    let engine: FrameEngine
    let renderer: MetalVideoRenderer?

    func makeNSView(context: Context) -> NSView {
        // Populate BEFORE the view can be added to a window, so `viewDidMoveToWindow` — and
        // therefore `DeckRegistry.register` — never observes a half-built deck. Plain stored
        // properties on a non-@Published class, so this cannot invalidate a view mid-update.
        deck.engine = engine
        deck.renderer = renderer
        return DeckHostView(deck: deck)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        deck.engine = engine
        deck.renderer = renderer
    }
}

/// The NSView that owns the window callback. `viewDidMoveToWindow` fires with the window in hand
/// on insertion and with nil on teardown — the register/deregister pair, with identity, that
/// `.onAppear`/`.onDisappear` cannot supply.
private final class DeckHostView: NSView {
    private let deck: WindowDeck
    /// Guards against a re-entrant callback for the SAME window (AppKit may call this more than
    /// once) and gives the nil case the identity it needs to deregister the right entry.
    private var registeredWindow: NSWindow?

    init(deck: WindowDeck) {
        self.deck = deck
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== registeredWindow else { return }
        if let previous = registeredWindow {
            DeckRegistry.shared.deregister(window: previous)
        }
        registeredWindow = window
        if let window {
            DeckRegistry.shared.register(deck, window: window)
        } else {
            deck.window = nil
        }
    }
}
