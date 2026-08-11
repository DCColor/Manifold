//
//  WindowDeck.swift
//  Manifold
//
//  THE REGISTRATION SEAM AND THE ARBITER. One window = one deck = one FrameEngine + one
//  MetalVideoRenderer, and this file is the ONLY place that wires a deck to anything app-wide OR
//  decides which deck may play.
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
//  spread across a sixty-line block that every window runs. Stage 1 moved them here and kept the
//  old policy verbatim (most recently registered deck wins). Stage 2 replaces that policy with
//  arbitration.
//
//  ── THE MODEL STAGE 2 IMPLEMENTS ───────────────────────────────────────────────────────
//
//    * ONE DECK PLAYS AT A TIME. Becoming key PAUSES the previously-playing deck and makes the new
//      one playable. Pause via `yieldTransport()` (rate 0), never a mute — a paused synchronizer is
//      already silent, and a second silence mechanism would drift out of step with the first.
//    * A DECK OWNING AN EXCLUSIVE DEVICE — DeckLink output, or a live NDI/WHEP/SRT connection —
//      keeps playback and audio. Every other deck's transport is DISABLED, with a standing message
//      naming the owning file and saying to turn it off there.
//    * NON-OWNING DECKS STAY FULLY USABLE OTHERWISE: paused frame, scopes, inspector, frame export,
//      guides, raster size, Refresh metadata, Edit in Flip, captions. It is PLAYBACK that is gated,
//      not the window.
//    * RELEASING THE DEVICE PAUSES EVERYTHING. Nothing auto-resumes; the user presses play where
//      they want it.
//    * DEVICE-CLAIM CONTROLS ARE DISABLED IN NON-OWNING DECKS, with the reason in the tooltip.
//      Silent theft of a broadcast output is the worst outcome available here.
//
//  ── THE ONE INVARIANT ──────────────────────────────────────────────────────────────────
//
//  EVERY transition — key change, device claim, device release, registration, deregistration,
//  app reactivation, a stream dropping on its own — runs through `applyArbitration`, which
//  recomputes the WHOLE picture from current facts and applies it. Nothing computes a delta and
//  nothing patches one field. This is modelled on `DeckLinkService.applyAudioRouting`, whose
//  comment states the principle: "The SINGLE place the system-renderer mute is re-evaluated… so a
//  stale destination can never leave desktop audio muted."
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
import Combine
import ManifoldCore

// MARK: - Exclusive devices

/// A device that only ONE deck may hold at a time.
///
/// AN ENUM WITH EXHAUSTIVE SWITCHES, for the reason `LiveSource`'s own header gives: adding a
/// device must FAIL THE BUILD, not silently skip a site. Every question the arbiter asks about a
/// device — is it live, how do I release it, what do I call it in front of a user — is answered by
/// a switch below, so a fifth device cannot be added without answering all three.
///
/// The three live cases wrap `LiveSource` rather than restating it. The two types compose and must
/// not merge: `LiveSource` is the authority on WHICH TRANSPORT owns the renderer (mutual exclusion
/// among transports, enforced by its `Arbitration` token), and `DeckRegistry` is the authority on
/// WHICH DECK owns it. Do not add a window parameter to `LiveSource`'s API — its safety property
/// comes from being small and having one job.
enum ExclusiveDevice: Hashable {
    case deckLink
    case live(LiveSource)

    static var everyDevice: [ExclusiveDevice] { [.deckLink] + LiveSource.allCases.map(Self.live) }

    /// Is this device ACTUALLY live right now, as the owning service reports it?
    ///
    /// The arbiter's record of who claimed what is reconciled against this on every pass, so a
    /// device that went away by ANY path — a stream dropping, a card unplugged, a failed start
    /// reverting `isOutputting` — releases its claim without needing a bespoke notification.
    var isLive: Bool {
        switch self {
        case .deckLink:      return DeckLinkService.shared.isOutputting
        case .live(let src): return src.isLive
        }
    }

    /// Turn it off. Idempotent, and reachable from window teardown — the owning window closing must
    /// not leave a broadcast output running against a renderer that no longer exists.
    @MainActor
    func release() {
        switch self {
        case .deckLink: DeckLinkService.shared.stopScheduledOutput()
        // Retires whatever live source is up, through the one funnel that knows a disconnect must
        // be guarded on `isConnected` (see LiveSource.retireActive).
        case .live:     LiveSource.retireActive()
        }
    }

    /// Plain-speak name for the standing message and tooltips.
    var label: String {
        switch self {
        case .deckLink:      return "DeckLink output"
        case .live(let src): return src.displayLabel
        }
    }
}

// MARK: - What a deck is allowed to do

/// The arbitration verdict for ONE deck. Recomputed in full on every pass and assigned wholesale;
/// `Equatable` so an unchanged verdict does not republish and re-render the window.
struct DeckGate: Equatable {

    /// May this deck's TRANSPORT act — play/pause and Space, the scrubber, J/K/L, the arrow jog,
    /// loop, mute and the volume fader? True for exactly one deck at a time.
    var transportEnabled = true

    /// May this deck CLAIM OR RELEASE an exclusive device — ⌃⌥O / ⌃⌥N, the DeckLink and streaming
    /// controls, Disconnect? False in every deck while another deck owns one.
    var deviceControlsEnabled = true

    /// Does this deck hold the device hook bundle — i.e. do the four singleton routers' renderers,
    /// the DeckLink audio tap and the system-audio routing point HERE?
    ///
    /// Views read this to answer "is that live source MINE": a stream connected in another window
    /// must not draw this window's control bar, wipe this window's scopes on disconnect, or let
    /// this window's file load live-switch the card's output mode.
    var drivesDevices = false

    /// Why the transport is gated, in one sentence. nil when it is not. Feeds tooltips always, and
    /// the standing banner when `isStanding`.
    var reason: String?

    /// TRUE when `reason` describes a STANDING CONDITION the user must clear somewhere else —
    /// another deck owns an exclusive device. Only these get an on-screen affordance; a deck that
    /// is merely not the front one has a reason for its tooltips and says nothing on screen,
    /// because "click me" is not news.
    var isStanding = false
}

// MARK: - One window's deck

/// The per-window playback deck: this window's identity, engine and renderer.
///
/// `ObservableObject` so ContentView can hold it in a `@StateObject` — which is also the point,
/// because `@StateObject` evaluates its initializer exactly once per window and `@State` would
/// re-run the expression on every View-struct re-creation (the measured bug documented on
/// `RendererStore` in ContentView.swift).
///
/// ⚠️ ONLY `gate` IS `@Published`, AND THE REST DELIBERATELY ARE NOT. `window` / `engine` /
/// `renderer` are written from AppKit callbacks (`viewDidMoveToWindow`) and from `updateNSView`,
/// both of which can land INSIDE a SwiftUI update pass; publishing them would invalidate the view
/// mid-update ("Modifying state during view update"). No view needs to re-render when they change —
/// they are read at action time, never rendered.
///
/// `gate` is different: views must re-render when it changes, so it has to publish. It is written
/// from exactly one place (`DeckRegistry.applyArbitration`), and the two triggers that CAN fire
/// inside a view update — registration and deregistration — schedule that pass for the next
/// main-actor turn rather than running it inline. See `DeckRegistry.setNeedsArbitration`.
@MainActor
final class WindowDeck: ObservableObject {

    /// The NSWindow hosting this deck, or nil before the view is in a window / after teardown.
    fileprivate(set) weak var window: NSWindow?

    /// This window's engine and renderer. Populated by `WindowDeckRegistrar` before the window
    /// callback can run, so `DeckRegistry.register` always sees a complete deck.
    fileprivate weak var engine: FrameEngine?
    fileprivate weak var renderer: MetalVideoRenderer?

    /// What this deck is allowed to do. THE ARBITER OWNS THIS — see `DeckRegistry`.
    @Published fileprivate(set) var gate = DeckGate()

    /// A human name for this deck, for the message another deck shows while this one holds a
    /// device. FILE ONLY — a deck showing a live stream has no file name (the takeover unloaded
    /// it), so the registry falls back to the name recorded at claim time and then to an honest
    /// "another window". Deliberately NOT a `??` chain at the call site: guessing is what produced
    /// the fallback bugs this stage exists to clean up.
    var displayName: String? {
        if let name = engine?.metadata?.fileName, !name.isEmpty { return name }
        if let url = engine?.currentURL { return url.lastPathComponent }
        return nil
    }

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

    /// Autoplay for a load originating in THIS window: the user's preference, suppressed when this
    /// deck is demonstrably not the front one OR when its transport is gated (another deck owns a
    /// device — loading a file to inspect it is legitimate, starting it playing is not).
    var shouldAutoplayOnLoad: Bool {
        Preferences.shared.autoplayOnLoad && !isBackgroundDeck && gate.transportEnabled
    }

    /// Nothing here has media or a stream of its own — the state that makes a window a candidate
    /// for re-use when a Finder open arrives. `drivesDevices` folds in "and no stream is showing
    /// here", so a window displaying NDI is never treated as empty.
    var isEmptyDeck: Bool {
        guard let engine else { return false }
        if engine.hasMedia { return false }
        if gate.drivesDevices, LiveSource.connected != nil { return false }
        return true
    }

    /// Load a file INTO THIS DECK, honouring its own autoplay gate. Exists so a call site holding
    /// one deck can load into ANOTHER (the `.onOpenURL` window re-use) without `engine` having to
    /// leave this file — the whole point of the registration seam is that nothing outside it wires
    /// itself to a deck's internals.
    func load(url: URL) {
        engine?.load(url: url, autoplay: shouldAutoplayOnLoad)
    }
}

// MARK: - The registry / arbiter

/// Every open deck, which one may play, and which one holds the app-wide device hooks.
@MainActor
final class DeckRegistry {

    static let shared = DeckRegistry()

    /// Weak by design — see the LIFETIME note in the file header.
    private struct Entry {
        weak var deck: WindowDeck?
        weak var window: NSWindow?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// A recorded device claim. `label` is what to CALL the claimant in the standing message when
    /// it has no file name (a stream-owning deck does not) — the source or bookmark name, supplied
    /// by the call site that knows it. Never a URL: a stream path can carry the stream key.
    private struct Claim {
        let deck: ObjectIdentifier
        let label: String?
        /// Set the first time the device is observed LIVE. Until then the claim is PENDING: a
        /// stream connect is asynchronous (SRT's can be ~8 s of connect plus analysis), and a
        /// device that is not live yet must still block a second deck from claiming it, or the
        /// connect window is exactly the hole a broadcast output could be stolen through.
        var confirmedLive: Bool
    }

    private var claims: [ExclusiveDevice: Claim] = [:]

    /// The deck whose transport is live. One at a time, by construction.
    private var activeDeckID: ObjectIdentifier?

    /// The owner as of the previous pass, so the pass that observes ownership ENDING can pause
    /// everything exactly once. "Releasing the device pauses everything; nothing auto-resumes."
    private var previousOwnerID: ObjectIdentifier?

    /// The deck currently holding the app-wide device hooks. Weak: if its window closes without a
    /// clean deregistration, this goes nil rather than resurrecting a dead deck.
    private weak var hostDeck: WindowDeck?

    /// The last DECK window to become key. Survives app deactivation on purpose: `NSApp.keyWindow`
    /// is nil while the app is in the background, and a colourist ⌘-Tabbing away to check a note
    /// must not lose playback. This is the memory that makes "keep the active deck on resign" work
    /// without an observer that has to do anything.
    private weak var keyDeckWindow: NSWindow?

    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    /// One-shot launch work that belongs to the APP, not to whichever deck registered first.
    private var hasRunLaunchTasks = false

    /// Set for the duration of one pass to expire claims that never went live. See `Claim`.
    private var lapsePendingClaims = false
    private var lapseTask: Task<Void, Never>?

    /// How long a claim may stay PENDING before it lapses. Bounded rather than indefinite: a
    /// connect that silently fails (NDI logs and gives up; it publishes no failure state) would
    /// otherwise leave every other deck's device controls disabled forever, naming a stream that
    /// never arrived. Comfortably longer than the slowest real connect — SRT's worst case is ~3 s
    /// of connect plus ~5 s of `avformat_find_stream_info`.
    private static let claimGracePeriod: Duration = .seconds(20)

    private var arbitrationScheduled = false

    private init() {
        // BELT AND BRACES. `viewDidMoveToWindow(nil)` is the primary deregistration path and it is
        // the one that fires in practice, but it depends on AppKit tearing the view hierarchy down
        // in the order we expect. A window close is unambiguous, so observe it too; `deregister`
        // is idempotent, so whichever arrives first wins and the second is a no-op.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { DeckRegistry.shared.deregister(window: window) }
        })

        // ── HOW THE APP LEARNS WHICH WINDOW IS ACTIVE ──────────────────────────────────────
        //
        // `NSWindow.didBecomeKeyNotification`, filtered through the registry. NOT SwiftUI's
        // mechanisms: `@Environment(\.controlActiveState)` reports `.inactive` for EVERY window
        // when the application deactivates, including the one that was key, so you cannot recover
        // which deck to make playable on reactivation; `.focusedSceneValue` inherits the same
        // ambiguity.
        //
        // ⚠️ THE RULE IS A LOOKUP, NOT AN EXCEPTION LIST. This notification also fires for the
        // About window, the Settings window, the NSOpenPanels in `presentCaptionPicker()` and the
        // Preferences export-folder picker, and the GuidesPanel popover (NSPopover is backed by a
        // window that can take key). If the window is NOT a registered deck we do NOTHING AT ALL —
        // which handles every auxiliary window present and future, and gives the right UX for
        // free: opening Settings or a file picker does not pause your playback. Filtering by class
        // or title would be a bug farm.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                let registry = DeckRegistry.shared
                guard registry.entries[ObjectIdentifier(window)] != nil else { return }
                registry.keyDeckWindow = window
                registry.applyArbitration("key window")
            }
        })

        // APP REACTIVATION: re-derive from `NSApp.keyWindow`. Deferred one turn because key status
        // is not necessarily settled at the moment this fires.
        //
        // There is deliberately NO `didResignActiveNotification` observer, and that absence IS the
        // handling: `keyDeckWindow` is a stored reference that outlives deactivation, so the
        // active deck simply persists across a ⌘-Tab. An observer here could only do the wrong
        // thing (recompute from a nil `keyWindow` and drop the active deck).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DeckRegistry.shared.setNeedsArbitration() }
        })

        // A DEVICE CAN GO AWAY WITHOUT ANYONE ASKING — a stream drops, a card is unplugged, a
        // start fails and reverts. Those are the transitions no call site reports, so observe the
        // services themselves and let the ordinary pass reconcile. Deferred one turn because
        // `objectWillChange` fires BEFORE the value lands, and the pass reads the value. Written
        // out four times rather than looped over `[any ObservableObject]`: the protocol's
        // publisher is an associated type, so an existential cannot be asked for it.
        let needsPass: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.setNeedsArbitration() }
        }
        DeckLinkService.shared.objectWillChange.sink { _ in needsPass() }.store(in: &cancellables)
        NDIService.shared.objectWillChange.sink { _ in needsPass() }.store(in: &cancellables)
        WHEPClient.shared.objectWillChange.sink { _ in needsPass() }.store(in: &cancellables)
        SRTClient.shared.objectWillChange.sink { _ in needsPass() }.store(in: &cancellables)

        // ── THE SOFT-RETIREMENT SEAM, INSTALLED ONCE AT APP SCOPE ─────────────────────────
        //
        // These used to be per-host closures capturing ONE engine and calling `stop()` on it. Both
        // halves were wrong under the multi-window model: reaching one engine left every other
        // deck playing into a renderer it no longer owned, and `stop()` is a full UNLOAD that
        // destroys the paused frame, scopes, inspector and frame export the model promises
        // non-owning decks keep. They capture no engine at all now — the registry decides, per
        // deck, which verb applies. See `liveStreamWillActivate`.
        //
        // `[weak self]` and not `DeckRegistry.shared`: these are installed from inside `shared`'s
        // own initializer, and reaching back through the static there is re-entrant.
        let willActivate: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.liveStreamWillActivate() }
        }
        NDIService.shared.onWillActivateStream = willActivate
        WHEPFrameRouter.shared.onWillActivateStream = willActivate
        SRTFrameRouter.shared.onWillActivateStream = willActivate

        // ── AND THE SAME SEAM FOR THE PICTURE'S SHAPE ─────────────────────────────────────
        //
        // ONE hook, not three, because `LiveSource` guarantees one live source at a time and the
        // hooks above guarantee one deck it displays in — so there is exactly one live frame size
        // in existence. `LiveDisplaySize` holds the latch and the thread discipline (it is called
        // from the render thread, a decode queue and a session thread); this end knows which deck
        // it belongs to, which is the half no transport can answer.
        LiveDisplaySize.shared.onChange = { [weak self] size in
            MainActor.assumeIsolated { self?.liveDisplaySizeChanged(size) }
        }
    }

    /// A live source stated its frame size (or lost it). Goes to the HOST deck — the one whose
    /// renderer the routers point at, i.e. the window the stream is actually in — for the same
    /// reason `liveStreamWillActivate` picks that deck to `stop()`. Every other deck's engine
    /// describes its own file and must not be told about somebody else's stream.
    ///
    /// A no-op when there is no host deck — there is no window for the size to be about. The latch
    /// does NOT re-publish an unchanged size, so a deck adopting the hooks mid-stream is seeded
    /// from `LiveDisplaySize.current` in `attachDeviceHooks` rather than waiting for a change that
    /// may never come.
    private func liveDisplaySizeChanged(_ size: CGSize?) {
        hostDeck?.engine?.setLiveDisplaySize(size)
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
        // DEFERRED, NOT INLINE: this runs inside `viewDidMoveToWindow`, which can land in a SwiftUI
        // update pass, and the pass publishes `gate`. One main-actor turn also lets the new window
        // become key first, which is the same ordering the autoplay gate needs.
        setNeedsArbitration()
    }

    /// Drop a window's deck. Safe to call for a window that was never registered.
    ///
    /// ⚠️ THE OWNING WINDOW CLOSING IS THE CASE THAT BITES. If a deck closes while holding DeckLink
    /// output or a live stream, doing nothing leaves the device claimed, the singletons' `weak var
    /// renderer` nil, the card falling to neutral black — and every surviving window still
    /// transport-disabled, naming a window that no longer exists. So the device is RELEASED here,
    /// synchronously, before anything else. Everything is then left PAUSED: the next key window
    /// becomes the active deck so its transport is enabled, but nothing auto-promotes to playing.
    fileprivate func deregister(window: NSWindow) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.deck?.window = nil

        if let deck = entry.deck {
            let id = ObjectIdentifier(deck)
            for (device, claim) in claims where claim.deck == id {
                NSLog("%@", "[ARBITER] owning window closed while holding \(device.label) — releasing it")
                device.release()
                claims[device] = nil
            }
        }

        // The hooks must not stay pointed at a dead deck even for one turn — the arbitration pass
        // below is deferred, and a live audio tap on a departing engine is not something to carry
        // across a main-actor hop.
        if hostDeck === entry.deck { detachDeviceHooks(from: hostDeck); hostDeck = nil }

        setNeedsArbitration()
    }

    private func prune() {
        entries = entries.filter { $0.value.window != nil && $0.value.deck != nil }
    }

    private func deck(for id: ObjectIdentifier?) -> WindowDeck? {
        guard let id else { return nil }
        return entries.values.compactMap(\.deck).first { ObjectIdentifier($0) == id }
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
        // THE SOURCE'S COLOUR TAGS, ON THE LOAD PATH RATHER THAN BEHIND THE INSPECTION TASK.
        // Same per-window wiring as the two above, and per-window for the same reason: this
        // deck's engine describes this deck's file to this deck's layer. The engine calls it on
        // main, before it starts reading, so the layer knows what it is looking at before a frame
        // can exist. See `FrameEngine.onSourceColorTags`.
        engine.onSourceColorTags = { [weak renderer] primaries, transfer, matrix in
            renderer?.setSourceColorSpace(primaries: primaries, transfer: transfer, matrix: matrix)
        }

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

    // MARK: - THE ONE METHOD

    /// Schedule a pass for the next main-actor turn, coalescing bursts.
    ///
    /// Used by every AppKit-lifecycle trigger — registration, deregistration, app reactivation, a
    /// service publishing a change — because those can fire inside a SwiftUI update pass and the
    /// pass writes `@Published` state. Action-initiated triggers (a claim, a release, a key change)
    /// call `applyArbitration` directly: they arrive on ordinary event handling, where publishing
    /// is safe and where being one turn late would be visible.
    private func setNeedsArbitration() {
        guard !arbitrationScheduled else { return }
        arbitrationScheduled = true
        Task { @MainActor [weak self] in
            self?.arbitrationScheduled = false
            self?.applyArbitration("deferred")
        }
    }

    /// RECOMPUTE THE WHOLE PICTURE AND APPLY IT. The single place any of this is decided.
    ///
    /// Deliberately computes from current facts every time rather than reacting to a delta: the
    /// triggers are many (key change, claim, release, register, deregister, reactivation, a stream
    /// dropping on its own) and a per-trigger patch would need to be right in every combination.
    /// Six steps, in this order, each one a consequence of the last:
    ///
    ///   1. Reconcile the claim records against what the devices actually report.
    ///   2. Decide the owner — the deck holding any claim.
    ///   3. Decide the active deck — the owner if there is one, else the key deck.
    ///   4. Pause every deck that is not the active one (and the active one too, on the pass that
    ///      observes ownership ending — nothing auto-resumes).
    ///   5. Point the device hooks at the active deck, atomically.
    ///   6. Publish each deck's gate.
    private func applyArbitration(_ trigger: String) {
        prune()

        // ── 1. RECONCILE ──────────────────────────────────────────────────────────────────
        for (device, claim) in claims {
            guard deck(for: claim.deck) != nil else { claims[device] = nil; continue }
            if device.isLive {
                claims[device]?.confirmedLive = true
            } else if claim.confirmedLive || lapsePendingClaims {
                // It went live and has now stopped, or it never came up inside the grace period.
                claims[device] = nil
            }
        }

        // ── 2. OWNER ──────────────────────────────────────────────────────────────────────
        // Single-deck by construction: `claim(_:by:_:)` refuses a claim from any deck other than
        // the one already holding something, so one deck can hold several devices (DeckLink output
        // OF an NDI stream is the ordinary broadcast case) and two decks can never hold one each.
        let ownerID = claims.values.first?.deck
        let ownerDeck = deck(for: ownerID)
        let ownershipEnded = (previousOwnerID != nil && ownerID == nil)
        previousOwnerID = ownerID

        // ── 3. ACTIVE DECK ────────────────────────────────────────────────────────────────
        // An owner outranks key status: that is what "the owner trumps" means. Otherwise the key
        // deck plays. `keyDeckID` falls back to the last key DECK, which is what keeps playback
        // alive while a panel holds key or the app is in the background.
        let stillAlive = deck(for: activeDeckID) != nil ? activeDeckID : nil
        activeDeckID = ownerID ?? keyDeckID() ?? stillAlive

        // ── 4. PAUSE ──────────────────────────────────────────────────────────────────────
        for entry in entries.values {
            guard let deck = entry.deck, let engine = deck.engine else { continue }
            let isActive = ObjectIdentifier(deck) == activeDeckID
            if isActive && !ownershipEnded { continue }
            // SOFT: yield the transport, keep the media. A non-active deck stays a fully usable
            // inspection surface — paused frame, scopes, inspector, frame export.
            engine.yieldTransport()
        }
        if ownershipEnded {
            NSLog("[ARBITER] exclusive device released — every deck paused; nothing auto-resumes")
        }

        // ── 5. HOOKS ──────────────────────────────────────────────────────────────────────
        retargetDeviceHooks(to: deck(for: activeDeckID))

        // ── 6. GATES ──────────────────────────────────────────────────────────────────────
        let ownedDevices = claims.keys.sorted { $0.label < $1.label }
        let standing = ownedDevices.isEmpty ? nil
            : standingMessage(devices: ownedDevices, ownerDeck: ownerDeck)

        for entry in entries.values {
            guard let deck = entry.deck else { continue }
            let id = ObjectIdentifier(deck)
            let isActive = id == activeDeckID
            let isOwner = (ownerID == id)

            var gate = DeckGate()
            gate.transportEnabled = isActive
            gate.deviceControlsEnabled = (ownerID == nil) || isOwner
            gate.drivesDevices = (deck === hostDeck)
            if let standing, !isOwner {
                gate.reason = standing
                gate.isStanding = true
            } else if !isActive {
                // Two different truths, and saying the wrong one is a small lie the user can catch:
                // with no active deck at all (2+ windows, none of them key yet) there IS no other
                // window holding the transport.
                gate.reason = activeDeckID == nil
                    ? "Click this window to make it the active deck."
                    : "The transport is in another window — click there, or here to take it over."
            }
            if deck.gate != gate { deck.gate = gate }
        }

        // ── LAUNCH WORK THAT BELONGS TO THE APP ───────────────────────────────────────────
        //
        // ⚠️ WHY NOT `ManifoldApp.init()`, WHICH IS WHERE "APP SCOPE" WOULD LITERALLY PUT IT.
        // Output needs a renderer: `startScheduledOutput` arms the renderer's v210 staging convert,
        // and a start with no renderer establishes a card that is fed neutral black forever,
        // because nothing re-arms the convert when a renderer later appears. So this runs at the
        // earliest moment a renderer is attached — the first pass with a host deck — and is
        // guarded to once per process HERE. That is the actual fix: it used to sit in the
        // host-adoption path, so it fired from whichever deck adopted the hooks first, which was
        // arbitrary, and re-ran (harmlessly, on the service's own guard) for every adoption after.
        if !hasRunLaunchTasks, let host = hostDeck {
            hasRunLaunchTasks = true
            DeckLinkService.shared.autoStartOnLaunchIfEnabled()
            // `isOutputting` flips synchronously and optimistically inside the start path, so this
            // reads the real answer: the launch window claims the card only if it actually took it.
            // A pref that is off, or hardware that is not ready, leaves no phantom claim behind.
            if DeckLinkService.shared.isOutputting {
                claims[.deckLink] = Claim(deck: ObjectIdentifier(host), label: nil, confirmedLive: true)
                setNeedsArbitration()
            }
        }

        // ONLY WHEN THE PICTURE ACTUALLY CHANGED. Passes are cheap and frequent — the four service
        // subscriptions mean NDI's ~1 Hz discovery republish alone triggers one — and a line per
        // pass would bury the diagnostics log this app exists to be debugged from. The trigger is
        // deliberately outside the comparison: the same verdict reached for a different reason is
        // not news.
        let summary = "decks=\(entries.count)"
            + " active=\(deck(for: activeDeckID)?.displayName ?? (activeDeckID == nil ? "none" : "untitled"))"
            + " owner=\(ownerDeck?.displayName ?? (ownerID == nil ? "none" : "untitled"))"
            + (ownedDevices.isEmpty ? "" : " devices=\(ownedDevices.map(\.label).joined(separator: "+"))")
        if summary != lastLoggedSummary {
            lastLoggedSummary = summary
            NSLog("%@", "[ARBITER] \(trigger) — \(summary)")
        }
    }

    private var lastLoggedSummary: String?

    /// Which deck the user is working in, best available answer. Four fallbacks, each covering a
    /// state the one above it cannot see:
    ///
    ///   1. `NSApp.keyWindow`, if it is a deck — the ordinary answer.
    ///   2. The last deck that WAS key, if it is still open. This is what makes app deactivation
    ///      and auxiliary windows harmless: `keyWindow` is nil while the app is in the background
    ///      and is the panel while Settings or an NSOpenPanel is up, and in neither case has the
    ///      user said anything about which DECK should play.
    ///   3. `NSApp.mainWindow`, if it is a deck — a Manifold window that is front while a panel
    ///      holds key still reads as main.
    ///   4. THE SOLE DECK, if there is exactly one. ⚠️ THIS ONE IS LOAD-BEARING, not tidiness: a
    ///      window that was already key before it registered posts no `didBecomeKey` afterwards, so
    ///      without this the app's overwhelmingly common case — one window — could come up with
    ///      NO active deck and a permanently dead transport. Same principle as
    ///      `frontmostDeckWindow`: a lone window can never be the background one.
    private func keyDeckID() -> ObjectIdentifier? {
        if let key = NSApp.keyWindow, let deck = entries[ObjectIdentifier(key)]?.deck {
            return ObjectIdentifier(deck)
        }
        if let window = keyDeckWindow, let deck = entries[ObjectIdentifier(window)]?.deck {
            return ObjectIdentifier(deck)
        }
        if let main = NSApp.mainWindow, let deck = entries[ObjectIdentifier(main)]?.deck {
            return ObjectIdentifier(deck)
        }
        if entries.count == 1, let deck = entries.values.first?.deck {
            return ObjectIdentifier(deck)
        }
        return nil
    }

    /// The standing message a non-owning deck shows. Names the owning file (or the stream, when
    /// the owner has no file) and says to turn it off there.
    ///
    /// ⚠️ NOT A FOURTH `??` TERM ON `connectErrorBanner`. That chain is documented as working only
    /// because its sources are mutually exclusive — an arbitration message is not — and it
    /// auto-dismisses after 9 s, which is exactly wrong for a condition that stands until the user
    /// acts. ContentView renders this in a separate, non-dismissing affordance.
    private func standingMessage(devices: [ExclusiveDevice], ownerDeck: WindowDeck?) -> String {
        let list = devices.map(\.label).joined(separator: " and ")
        let verb = devices.count > 1 ? "are" : "is"
        let them = devices.count > 1 ? "them" : "it"
        // File name first; then the name recorded at claim time (an NDI source, a bookmark); then
        // an honest fallback. Never a URL — a stream path can carry the stream key.
        let name = ownerDeck?.displayName ?? claims.values.compactMap(\.label).first
        let where_ = name.map { "“\($0)”" } ?? "another window"
        return "\(list) \(verb) running in \(where_). Turn \(them) off there to play here."
    }

    // MARK: - The device hook bundle (ONE deck at a time, attached and detached atomically)

    /// Point every app-wide device consumer at `deck`, or at nothing.
    ///
    /// THE BUNDLE MOVES AS ONE UNIT. Renderer, audio tap, SDI silence gate, system-audio routing
    /// and the audio format hook are five hooks describing ONE relationship — "this deck is the one
    /// the card and the live routers talk to" — and a half-transferred bundle is a window whose
    /// picture goes to the card while another window's audio does.
    private func retargetDeviceHooks(to deck: WindowDeck?) {
        guard hostDeck !== deck else { return }
        // ⚠️ NEVER RE-POINT AN ACTIVE ROUTER. `LiveDisplayRoute` saves the outgoing renderer's clock
        // providers at activate and restores them at deactivate; moving the router's renderer in
        // between is what cross-wires one window's picture to another's synchronizer. It is also
        // how a `clearToBlack` on disconnect would land on a window showing a paused file. This
        // cannot normally happen — a live device pins its owner as the active deck, and a closing
        // owner releases before this runs — so reaching here at all is worth a line in the log.
        if let live = ExclusiveDevice.everyDevice.first(where: \.isLive) {
            NSLog("%@", "[ARBITER] refusing to re-point the device hooks while \(live.label) is live")
            return
        }
        detachDeviceHooks(from: hostDeck)
        hostDeck = deck
        attachDeviceHooks(to: deck)
    }

    private func detachDeviceHooks(from deck: WindowDeck?) {
        guard let deck else { return }

        DeckLinkService.shared.renderer = nil
        DeckLinkService.shared.audioTap = nil
        DeckLinkService.shared.isCardAudioSilentProvider = nil
        DeckLinkService.shared.systemAudioRouting = nil
        deck.engine?.audioTap.onFormatChange = nil

        // ⚠️ THE OUTGOING ENGINE MUST BE TOLD IT NO LONGER OWES THE CARD ITS SILENCE. It is holding
        // `deckLinkOwnsAudio == true` from the last routing call, and nothing else will ever clear
        // it — this window's desktop audio would stay muted for the rest of the session. Through
        // `setDeckLinkOwnsAudio` → `applyAudioMute`, which is the engine's one mute rule; not a
        // second mechanism.
        deck.engine?.setDeckLinkOwnsAudio(false)

        NDIService.shared.renderer = nil
        NDIService.shared.audioTap = nil
        WHEPFrameRouter.shared.renderer = nil
        SRTFrameRouter.shared.renderer = nil
    }

    private func attachDeviceHooks(to deck: WindowDeck?) {
        guard let deck, let engine = deck.engine else { return }
        let renderer = deck.renderer   // weak on every service below; nil is tolerated everywhere

        // DeckLink output sources real video from this renderer (⌃⌥O / toolbar control).
        DeckLinkService.shared.renderer = renderer
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
        // …and evaluate it NOW for the incoming engine, from DeckLinkService's own rule rather than
        // a copy of it. Without this the new owner would not learn the card's state until the next
        // start/stop/destination change — which, if output is already running, is never.
        engine.setDeckLinkOwnsAudio(DeckLinkService.shared.ownsSystemAudio)
        // The card must be ENABLED with a fixed rate/channel count before playback starts, so a
        // file whose audio format differs re-establishes the output (this is also what lets you
        // enable output BEFORE loading a file and still get audio).
        //
        // HOST-ONLY, AND THAT IS THE BEHAVIOUR-PRESERVING CHOICE. Before stage 1 this was set on
        // `engine.audioTap` — one engine, one tap, so exactly one handler existed. Setting it on
        // every deck's tap would be a NEW behaviour: any background window loading a 5.1 file
        // would re-establish the card out from under the foreground window.
        engine.audioTap.onFormatChange = { fmt in DeckLinkService.shared.audioFormatChanged(fmt) }

        // NDI displays THROUGH this same renderer — it pulls frames on the display tick and feeds
        // the same enqueue the file sources do.
        NDIService.shared.renderer = renderer
        // Tee NDI audio into the SAME PTS-keyed PCM ring the file paths feed, so the clock-anchored
        // SDI output, SDI/Computer routing and mute apply to NDI for free.
        NDIService.shared.audioTap = engine.audioTap
        // A web stream displays through this SAME renderer, feeding the same enqueue NDI and the
        // file sources feed — but paced by LiveClock rather than FrameSync or the file timebase.
        WHEPFrameRouter.shared.renderer = renderer
        // An SRT stream is a push source exactly like WHEP — same renderer, same enqueue, same
        // LiveClock pacing through the same LiveDisplayRoute.
        SRTFrameRouter.shared.renderer = renderer

        // SEED THE INCOMING DECK WITH WHATEVER SHAPE IS ALREADY ON SCREEN. `LiveDisplaySize` only
        // fires on a CHANGE, so a deck that becomes host while a source is running would otherwise
        // hold a nil size until the stream's dimensions happened to change — i.e. usually forever,
        // and the window would sit on the 16:9 fallback over a picture that is not 16:9. Normally
        // unreachable (a live device pins its owner, and `retargetDeviceHooks` refuses to move the
        // hooks while one is live), but the synthetic harness is not an `ExclusiveDevice` and can
        // reach it, and "normally unreachable" is not a reason to be wrong when it is reached.
        //
        // ONLY WHEN THERE IS ONE. Passing nil here would run on EVERY ordinary host adoption — a
        // key-window change with no stream anywhere near it — and wipe the incoming deck's own
        // FILE size. `nil` from this seam means "nothing to say", not "no picture".
        if let liveSize = LiveDisplaySize.shared.current {
            engine.setLiveDisplaySize(liveSize)
        }

        DeckLinkService.shared.refreshDevices()   // populate the device picker
    }

    // MARK: - Claim and release

    /// The deck holding any exclusive device, if any.
    private var currentOwnerID: ObjectIdentifier? { claims.values.first?.deck }

    /// Claim `device` for `deck`, then run the action that actually stands it up.
    ///
    /// THE RECORDING POINT, and it is deliberately a WRAPPER rather than a parameter on the
    /// services. `LiveSource` answers which TRANSPORT owns the renderer and must not learn about
    /// windows; `DeckLinkService` has no window concept at all. So the registry records the
    /// claimant immediately before calling the existing funnels, and clears it after the teardown.
    ///
    /// Refuses when another deck owns something — belt and braces behind the disabled controls,
    /// because a refusal is the only correct answer if a claim ever reaches here another way.
    /// Returns whether the claim was taken.
    @discardableResult
    func claim(_ device: ExclusiveDevice, by deck: WindowDeck, label: String? = nil,
               _ standUp: () -> Void) -> Bool {
        prune()
        let id = ObjectIdentifier(deck)
        if let owner = currentOwnerID, owner != id {
            NSLog("%@", "[ARBITER] refusing \(device.label): another window owns "
                + claims.keys.map(\.label).joined(separator: "+"))
            return false
        }
        claims[device] = Claim(deck: id, label: label, confirmedLive: device.isLive)
        scheduleClaimLapse()
        // BEFORE the stand-up, so the hooks and the host deck are already correct when the service
        // calls straight back into `liveStreamWillActivate` — which NDI and SRT do synchronously.
        applyArbitration("claiming \(device.label)")
        standUp()
        applyArbitration("claimed \(device.label)")
        return true
    }

    /// Release `device` (and, for a live source, whatever else is live — `retireActive` retires the
    /// lot) and run the teardown. Idempotent; a deck that owns nothing is refused with a log.
    func release(_ device: ExclusiveDevice, from deck: WindowDeck, _ tearDown: (() -> Void)? = nil) {
        let id = ObjectIdentifier(deck)
        if let owner = currentOwnerID, owner != id {
            NSLog("%@", "[ARBITER] refusing to release \(device.label) from a window that does not own it")
            return
        }
        if let tearDown { tearDown() } else { device.release() }
        claims[device] = nil
        // A live teardown goes through `LiveSource.retireActive`, which retires EVERY transport —
        // so drop every live claim, not just the named one, rather than leaving a record the next
        // reconcile would have to clean up.
        if case .live = device {
            claims = claims.filter { key, _ in
                if case .live = key { return false }
                return true
            }
        }
        applyArbitration("released \(device.label)")
    }

    // MARK: - Convenience funnels for the view layer

    /// Start or stop DeckLink output from `deck`, recording (or dropping) the claim around it.
    /// One entry point so the toolbar button, ⌃⌥O and ⌃⌥⇧O can never disagree about ownership.
    func toggleDeckLinkOutput(from deck: WindowDeck) {
        if DeckLinkService.shared.isOutputting {
            release(.deckLink, from: deck) { DeckLinkService.shared.stopScheduledOutput() }
        } else {
            claim(.deckLink, by: deck) { DeckLinkService.shared.startScheduledOutput() }
        }
    }

    func startDeckLinkOutput(from deck: WindowDeck) {
        claim(.deckLink, by: deck) { DeckLinkService.shared.startScheduledOutput() }
    }

    func stopDeckLinkOutput(from deck: WindowDeck) {
        release(.deckLink, from: deck) { DeckLinkService.shared.stopScheduledOutput() }
    }

    /// Stand a live source up from `deck`. `label` is what to call this deck in another window's
    /// standing message — an NDI source name or a bookmark name. NEVER a URL: a stream path can
    /// carry the stream key, which is why the bookmark rows pass the name they display.
    func connectLive(_ source: LiveSource, from deck: WindowDeck, label: String? = nil,
                     _ standUp: () -> Void) {
        claim(.live(source), by: deck, label: label, standUp)
    }

    /// Retire this deck's live source. A no-op when this deck has none — which is what makes it
    /// safe on the file-open paths, where the old code called the blanket `LiveSource.retireActive`
    /// and would now tear down a stream belonging to a different window.
    func retireLiveIfOwned(by deck: WindowDeck) {
        let id = ObjectIdentifier(deck)
        // The device actually held, so the log names the transport being torn down rather than a
        // placeholder. `release` drops every live claim regardless — `LiveSource.retireActive`
        // retires the lot, so leaving a sibling record behind would be a lie the next pass has to
        // clean up.
        let owned = claims.first { key, claim in
            if case .live = key { return claim.deck == id }
            return false
        }
        guard let device = owned?.key else { return }
        release(device, from: deck) { LiveSource.retireActive() }
    }

    /// An empty deck a newly-opened file could be loaded into instead of leaving a stray window.
    /// Prefers the front one, so "the front window has no media" is answered literally when it can
    /// be. Never returns `excluding`, and never a deck with media or a stream of its own.
    func emptyDeckToReuse(excluding deck: WindowDeck) -> WindowDeck? {
        prune()
        let candidates = entries.values.compactMap(\.deck).filter { $0 !== deck && $0.isEmptyDeck }
        if let front = frontmostDeckWindow, let d = entries[ObjectIdentifier(front)]?.deck,
           candidates.contains(where: { $0 === d }) {
            return d
        }
        return candidates.first
    }

    private func scheduleClaimLapse() {
        lapseTask?.cancel()
        lapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.claimGracePeriod)
            guard !Task.isCancelled, let self else { return }
            self.lapsePendingClaims = true
            self.applyArbitration("claim grace expired")
            self.lapsePendingClaims = false
        }
    }

    // MARK: - The soft-retirement seam

    /// A live source is about to take the display. Called by NDI, WHEP and SRT through the hooks
    /// installed in `init`, and by the synthetic harness through the same entry point.
    ///
    /// ⚠️ TWO DIFFERENT VERBS, AND THE DISTINCTION IS THE WHOLE POINT. The deck the stream is taking
    /// the display FROM — the one whose renderer the routers point at — genuinely loses its file:
    /// its picture is about to be something else, so `stop()` (a full unload) is the honest verb,
    /// and it is what leaves no stale duration, end timecode or scrubber length behind the live
    /// source. EVERY OTHER DECK merely stops being allowed to play, and must keep its paused frame,
    /// scopes, inspector and frame export — so it gets `yieldTransport()`.
    ///
    /// This used to be one closure capturing one engine and calling `stop()` on it, which was wrong
    /// in both directions at once: it unloaded a file it had no business unloading, and it left
    /// every other deck playing into a renderer it no longer owned.
    func liveStreamWillActivate() {
        prune()
        for entry in entries.values {
            guard let deck = entry.deck, let engine = deck.engine else { continue }
            if deck === hostDeck { engine.stop() } else { engine.yieldTransport() }
        }
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
