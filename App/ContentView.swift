import SwiftUI
import ManifoldCore
import UniformTypeIdentifiers   // UTType(filenameExtension:) for the .srt picker

enum ReadoutMode: CaseIterable { case source, frame, elapsed }

/// The four scopes any tray slot can display. `rawValue` (String) backs @AppStorage persistence
/// of per-slot selections; `displayName` labels the slot picker menu.
enum ScopeKind: String, CaseIterable, Identifiable {
    case waveform, parade, vectorscope, cie
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .waveform:    return "Waveform"
        case .parade:      return "Parade"
        case .vectorscope: return "Vectorscope"
        case .cie:         return "CIE"
        }
    }
}

/// A tray slot's leading header element: the scope's display label rendered as a Menu (pick which
/// scope fills this slot) followed by the scope's own context suffix (e.g. "· luma (10-bit)"). The
/// Menu always lists all four `ScopeKind`s. When `selection` is nil the label is plain text (the
/// view isn't in a slot-picker context). Leading-edge only — the scope's trailing controls (e.g.
/// intensity slider) are untouched.
struct ScopeSlotHeader: View {
    let name: String                        // shown on the button, e.g. "WAVEFORM"
    let suffix: String                      // context suffix incl. its separator, e.g. " · luma (10-bit)"
    let selection: Binding<ScopeKind>?      // nil → plain label (no picker)

    var body: some View {
        HStack(spacing: 3) {
            if let selection {
                Menu {
                    ForEach(ScopeKind.allCases) { kind in
                        Button(kind.displayName) { selection.wrappedValue = kind }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(name)
                        Image(systemName: "chevron.down").font(.system(size: 6))
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text(name)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if !suffix.isEmpty {
                Text(suffix)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// Owns the single MetalVideoRenderer for ContentView's lifetime.
///
/// WHY THIS EXISTS — it is not ceremony. The renderer used to be held as
///     @State private var metalRenderer = MetalVideoRenderer()
/// and Swift evaluates a @State default-value EXPRESSION on every re-creation of the View
/// struct. SwiftUI re-creates View structs constantly (any parent re-render, any @State
/// change), so that expression was building a COMPLETE renderer stack — Metal device, three
/// command queues, every render/compute pipeline, the texture cache — and @State then threw
/// all but the first away. Measured: 95 constructions in ~18 seconds of idle playback.
///
/// @StateObject is the purpose-built fix: its initializer is an @autoclosure that SwiftUI
/// evaluates EXACTLY ONCE for the view's lifetime. MetalVideoRenderer can't be a @StateObject
/// directly — its init is failable, so the property must stay Optional, and @StateObject cannot
/// wrap an Optional — so this trivial ObservableObject holds it instead. MetalVideoRenderer
/// itself is untouched, and the renderer stays Optional exactly as the call sites expect.
///
/// Constructing in .onAppear would also fix the count, but would leave the renderer nil for the
/// first body evaluation (one frame with no Metal surface). This keeps it available immediately,
/// so display timing is unchanged.
///
/// Scope: one store — and so one renderer — per ContentView, i.e. per WINDOW. That is correct:
/// each window needs its own Metal layer. The bug was never "more than one window", it was the
/// same window rebuilding its renderer on every SwiftUI update.
private final class RendererStore: ObservableObject {
    let renderer: MetalVideoRenderer? = MetalVideoRenderer()
}

struct ContentView: View {

    /// THIS WINDOW'S playback engine. `@StateObject`, not `@ObservedObject` on a parameter: each
    /// window OWNS one, and SwiftUI evaluates the initializer exactly once per window, which is
    /// precisely the lifetime a deck should have.
    ///
    /// It used to be `@StateObject` on ManifoldApp and passed in, so every window was a second
    /// view onto ONE transport — and worse than merely shared, because the engine's consumer hooks
    /// are single-assignment: opening a second window repointed `engine.onVideoFrame` at the new
    /// window's Metal renderer and FROZE the first window's picture, and closing either window ran
    /// `engine.stop()` on the file the other one was playing.
    ///
    /// The app-wide hooks that one engine used to own are now brokered by DeckRegistry — read
    /// WindowDeck.swift before adding anything to `.onAppear` below.
    @StateObject private var engine = FrameEngine()

    /// This window's identity in `DeckRegistry` — the seam that replaced the old `.onAppear` hook
    /// block. Populated with the NSWindow by `WindowDeckRegistrar` (mounted in `videoRegion`).
    @StateObject private var deck = WindowDeck()

    /// PER-WINDOW chrome state: tray open/close, the three slot selections, and overlay-vs-docked.
    /// Was five `@AppStorage` declarations here, which made all five app-wide — see WindowChrome for
    /// the seeding/write-back semantics and for why the split matters. `@StateObject` (not
    /// `@ObservedObject`) because each window must OWN one: SwiftUI evaluates the initializer
    /// exactly once per window, which is precisely the lifetime this state should have.
    @StateObject private var chrome = WindowChrome()

    /// Unchanged in shape from the @AppStorage era — a computed read of the stored mode. Only the
    /// backing store moved, so every `isDocked` call site below is untouched.
    private var isDocked: Bool { chrome.isDocked }

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var scrubPreviewImage: CGImage?
    @State private var previewRequestInFlight = false
    @State private var lastPreviewTime: Double = -1
    @State private var wasPlayingBeforeScrub = false

    @State private var hudVisible = true
    @State private var pinned = false
    @State private var showInspector = false
    @State private var showFileNameOverlay = false
    @State private var showGetFlipSheet = false
    @State private var showGuidesPanel = false
    @State private var volumeHovering = false
    /// Constructed exactly once (see RendererStore). Same instance for display, scopes, DeckLink
    /// and export — read-only here; nothing reassigns it.
    @StateObject private var rendererStore = RendererStore()
    private var metalRenderer: MetalVideoRenderer? { rendererStore.renderer }
    /// NDI connection state — the empty-state overlay has to know a stream is on screen even
    /// though no file is loaded. Observed, so ⌃⌥N / ⌃⌥⇧N update the UI.
    @ObservedObject private var ndi = NDIService.shared
    // WHEP's published connection state — feeds `hasSource` so the empty-state overlay hides while a
    // web stream drives the shared renderer, and drives the teardown scope-clear below.
    @ObservedObject private var whep = WHEPClient.shared
    // SRT's published connection state — same role as `whep` above: it feeds `hasSource`, drives
    // `activeLiveSource`, and surfaces a failed connect through the shared error banner.
    @ObservedObject private var srt = SRTClient.shared
    // Saved stream bookmarks — observed so the chevron and empty-state menus rebuild when the set
    // changes (empty ↔ non-empty flips the "Stream URL" item between a flat entry and a flyout).
    @ObservedObject private var bookmarks = StreamBookmarkStore.shared
    // Stream-bookmark manager sheet (chevron ▸ "Stream URL…" / "Manage…" and the empty-state menu).
    @State private var showStreamBookmarks = false
    // Diagnostics export prompt. Observed rather than @State because the menu item that raises it
    // lives in the App scene — see DiagnosticsExporter.
    @ObservedObject private var diagnostics = DiagnosticsExporter.shared
    // M4 tuning: A/B Metal vs AVSampleBufferDisplayLayer, toggled by ⌃⌥R. KEPT — this is the A/B
    // switch itself (it selects the surface at the `metalRenderer` branch below), not the removed
    // on-screen METAL/REFERENCE badge that used to read it. With the badge gone the switch is
    // silent, which is correct for a shipped build: nothing announces the render path unasked.
    @State private var showReferenceLayer = false
    // A droppable file is hovering over this window's picture — see the drop destination on
    // `videoRegion`. Purely the highlight's state; the drop itself carries no view state.
    @State private var dropTargeted = false

    // Scopes tray: a FIXED bottom strip (`WindowChrome.trayHeight`), not the proportional share it
    // used to be — resizing the window scales the video and leaves the scopes alone. See the note on
    // that constant for why, and WindowSizer.swift for the window-height consequence.
    //
    // MEASURED height of the docked control bar, seeded from `WindowChrome.dockedControlBarHeight`.
    // Measured rather than asserted because this number is an input to the WINDOW's height: a
    // hard-coded constant that drifted from the bar's real intrinsic height would show as a sliver
    // of the picture cropped, or a sliver of black under the bar, with nothing on screen saying why.
    // Changes at most once per window (the bar's content is fixed-height and width-independent), and
    // `WindowSizer` ignores sub-point differences, so this cannot oscillate against the resize.
    @State private var dockedBarHeight: CGFloat = WindowChrome.dockedControlBarHeight
    // Scope-tray divider (Arc C). `dividerDragBaseline` is the tray height at mouse-down and is
    // non-nil ONLY for the duration of a drag, so it doubles as the "is dragging" flag.
    @State private var dividerHovered = false
    @State private var dividerDragBaseline: CGFloat?
    // ── RASTER SIZE (see RasterSize.swift) ──────────────────────────────────────────────────
    // The picture's MEASURED size in points — the laid-out video rect, not a derived one. Feeds the
    // readout's dimensions, which is what makes them true for the two cases a derivation would get
    // wrong: an anamorphic source (whose display shape is not its encoded shape) and a window the
    // screen cap has bound. Written by `.onGeometryChange` on the aspect-fitted surface.
    @State private var drawnVideoSize: CGSize = .zero
    // The transient readout's text, or nil when nothing is showing. Auto-hides on its own `.task`
    // timer, keyed on the text — see `rasterReadout`.
    @State private var rasterNotice: String?
    // Tray open/close and the three per-slot scope selections now live on `chrome` (per window).
    // They were @AppStorage here, which shared them across every open window; the keys and their
    // defaults are unchanged, so an existing install's arrangement carries over. Each slot can show
    // ANY of the four scopes, chosen live from its header picker. Variable slot count / arrangement
    // / saved layouts are still a later pass.
    // Persisted CIE view state (written by the CIE shortcuts, read here + by CIEScopeView via the
    // same keys). useUV also seeds the renderer's kernel copy so the scatter opens in the last mode.
    @AppStorage("manifold.cie.useUV")    private var cieUseUV = true
    @AppStorage("manifold.cie.show709")  private var cieShow709 = true
    @AppStorage("manifold.cie.showP3")   private var cieShowP3 = true
    @AppStorage("manifold.cie.show2020") private var cieShow2020 = true
    // Persisted vectorscope graticule reference (written by ⌃⌥G, read here + by VectorscopeScopeView
    // via the same key). Overlay-only — no kernel push, so a toggle just redraws the boxes.
    @AppStorage("manifold.vectorscope.graticule") private var vectorscopeGraticule: VectorscopeGraticule = .fixed709
    // Persisted vectorscope target-box amplitude (75%/100%/both), cycled by ⌃⌥B, read here + by
    // VectorscopeScopeView via the same key. Overlay-only — a change just redraws the boxes.
    @AppStorage("manifold.vectorscope.boxAmplitude") private var vectorscopeBoxAmplitude: VectorscopeBoxAmplitude = .percent75
    // The four scope models (one each, rendered wherever its kind is selected — duplicates share
    // the single model). A model samples/computes only while its kind is in the active set.
    @StateObject private var waveformModel = WaveformScopeModel()
    @StateObject private var paradeModel = ParadeScopeModel()
    @StateObject private var vectorscopeModel = VectorscopeScopeModel()
    @StateObject private var cieModel = CIEScopeModel()
    /// DeckLink output state (on/off + selected device) — shared singleton, observed so the toolbar
    /// control and the ⌃⌥O/⌃⌥⇧O shortcuts always agree.
    @ObservedObject private var deckLink = DeckLinkService.shared
    /// External .srt sidecar state (cues + on/off). Per-window like the scope models, not a
    /// singleton: captions are view-level overlay state synced to the engine's clock, with no
    /// device/stream lifecycle to share. The engine stays unaware of them.
    @StateObject private var captions = CaptionController()
    /// Caption position — same key CaptionOverlay reads; declared here for the Aa menu's Picker
    /// binding (the guides panel binds its percentages the same way).
    @AppStorage("manifold.caption.positionPreset") private var captionPosition: CaptionPosition = .titleSafe
    @State private var readoutMode: ReadoutMode = .source
    @State private var idleTask: Task<Void, Never>?

    // In docked mode the controls are always shown; in overlay they auto-hide.
    private var controlsShown: Bool { isDocked ? true : hudVisible }

    // A source is "active" whenever a file is loaded OR ANY live source is on screen. The whole
    // auto-hiding control surface (HUD / control bar, scopes, guides, overlay data, output toggle)
    // is source-agnostic — it reveals for ANY active source. Every live source drives frames
    // straight into the shared renderer without ever setting `hasMedia`, so gating the reveal on
    // `hasMedia` alone left streaming with no reachable controls. Every reveal gate keys off this
    // instead, and the "Open… to begin" empty state is the `else` of the same expression — it means
    // NOTHING is on screen, no file and no stream.
    //
    // THE LIVE TERM IS `activeLiveSource != nil`, NOT A PAIRWISE CHAIN, and that is the whole point
    // of LiveSource: an SRT stream pushes into the renderer exactly as NDI and WHEP do and never
    // sets `engine.hasMedia`, so a hand-written `ndi || whep` here would have drawn the empty state
    // over live SRT video. Adding `.srt` to `activeLiveSource` below fixed this site, the control
    // reveal, the WindowConfigurator and the Disconnect menu item in one edit, which is exactly what
    // a single enumeration buys over four restatements.
    private var hasSource: Bool {
        return engine.hasMedia || activeLiveSource != nil
    }

    /// The live (non-file) source currently on screen IN THIS WINDOW, or nil. THE single place this
    /// view asks "what is streaming" — every gate below keys off it rather than restating a
    /// pairwise chain.
    ///
    /// Reads the `@ObservedObject` instances, which is what makes `body` re-render on connect and
    /// disconnect. `LiveSource.isLive` exists but is deliberately not for views (reading a
    /// singleton does not subscribe a `body` to it), so there is no shortcut to reach for here by
    /// mistake. Adding SRT is one more line here and one more case there.
    ///
    /// ⚠️ THE OWNERSHIP TERM IS NOT DECORATION. The three clients are singletons, so before stage 2
    /// EVERY window answered "yes, NDI is connected" for a stream that was displaying in ONE of
    /// them — which drew a full control bar over a black picture in windows that had nothing, wiped
    /// THEIR scopes when the stream disconnected, and offered a Disconnect the model says belongs
    /// only to the owner. `drivesDevices` is the arbiter's answer to "do the singleton routers
    /// point at MY renderer", i.e. "is that stream mine". Gating here fixes `hasSource`, the empty
    /// state, the colour control, the Disconnect item and the depth stepper in one edit.
    private var activeLiveSource: LiveSource? {
        guard deck.gate.drivesDevices else { return nil }
        if ndi.isConnected { return .ndi }
        if whep.isConnected { return .web }
        if srt.isConnected { return .srt }
        return nil
    }

    var body: some View {
        // ══════════════════════════════════════════════════════════════════════════════════
        //  THE INVARIANT — CHROME NEVER REDUCES THE VIDEO'S SIZE.
        //
        //  This is the LAYOUT half of the rule; `WindowSizer` holds the sizing half and states it
        //  in full (see the `VideoBox` header there, which makes the violation a compile error
        //  rather than something to remember). The two halves must agree or the window is a
        //  correctly-sized box around a wrongly-sized picture.
        //
        //  What this VStack must keep true:
        //
        //    * Every child BELOW `videoRegion` states a FIXED height and declares it in
        //      `chromeHeight`. `WindowSizer` then makes the window taller by exactly that much, so
        //      the remainder handed to `videoRegion` is still the picture's own shape.
        //    * `videoRegion` takes the REMAINDER (`maxHeight: .infinity`). It is never given a
        //      computed height, and nothing below it is proportional to the window.
        //    * THE SOLE EXCEPTION is the SCREEN CAP — a window the display cannot show. It is
        //      handled once, in `WindowSizer.constrainedContentSize`, by shrinking the picture
        //      ON-SHAPE. Nothing in this file may create a second exception.
        //
        //  ⚠️ ADDING CHROME IS A TWO-LINE CHANGE AND BOTH LINES ARE REQUIRED: put the view here
        //  with a fixed height, and add that height to `chromeHeight`. A view added here WITHOUT
        //  the second line takes its height out of the picture and silently pillarboxes it — which
        //  is exactly the bug this arc removed and is invisible unless you go looking.
        //
        //  For the record of what that looks like: the GeometryReader this replaced divided a FIXED
        //  window between the video and a proportional tray, so opening the tray took a third of the
        //  height from the picture and `.aspectRatio(.fit)` pillarboxed a 16:9 image into a 2.65:1
        //  box — 16.5% of the window black down each side.
        // ══════════════════════════════════════════════════════════════════════════════════
        VStack(spacing: 0) {
            videoRegion
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // DOCKED CONTROLS ARE CHROME, NOT AN OVERLAY. They used to be drawn inside
            // `videoRegion`'s ZStack pinned to its bottom edge, i.e. ON TOP OF the picture — which
            // is what "docked" was hiding: there was no room made for the bar, so it covered the
            // frame it was meant to sit under. Overlay mode still draws inside the picture, which is
            // what an auto-hiding floating HUD is for.
            if isDocked && hasSource {
                dockedControlBar
            }
            if chrome.showTray {
                scopesTray
                    .frame(height: effectiveTrayHeight)
                    // THE DIVIDER ADDS NO HEIGHT. It is an overlay on the tray's own top edge, not
                    // a VStack child, so `chromeHeight` stays `bar + tray` and the window arithmetic
                    // is unchanged by its existence. A 10-pt grab band straddles the boundary; only
                    // the hairline is drawn.
                    .overlay(alignment: .top) { scopeTrayDivider }
            }
        }
        .ignoresSafeArea()
        .background(
            Button("") { showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [])
                .opacity(0)
        )
        .background(
            Button("") { showFileNameOverlay.toggle() }
                .keyboardShortcut("n", modifiers: [])
                .opacity(0)
        )
        .background(
            Button("") { showReferenceLayer.toggle() }
                .keyboardShortcut("r", modifiers: [.control, .option])
                .opacity(0)
        )
        .background(
            Button("") { metalRenderer?.exportCurrentFrame() }
                .keyboardShortcut("e", modifiers: [.control, .option])
                .opacity(0)
        )
        #if DEBUG
        // ⚠️ EXPERIMENT 3 — TEMPORARY. ⌃⌥D cycles the layer's destination colorspace so the
        // CAMetalLayer display path can be measured. Delete with the block in MetalVideoRenderer.
        .background(
            Button("") { metalRenderer?.cycleDebugDestination() }
                .keyboardShortcut("d", modifiers: [.control, .option])
                .opacity(0)
        )
        #endif
        // Scope shortcuts (tray + per-scope toggles + CIE live toggles) consolidated into one
        // hidden group so the view body's modifier chain stays type-checkable.
        .background(scopeShortcuts)
        // Device-CLAIM accelerators. Gated together, because they all reach a singleton that
        // another window may be holding, and silently stealing a broadcast output is the worst
        // outcome available here. Non-owning windows keep every INSPECTION shortcut (⌃⌥E, I, ⌃⌥T,
        // the scope shortcuts, ⌃⌥R, N, Tab) — it is the device, not the window, that is claimed.
        .background(deckLinkShortcuts.disabled(!deck.gate.deviceControlsEnabled))
        .background(ndiShortcuts.disabled(!deck.gate.deviceControlsEnabled))
        .background(syntheticLiveShortcuts.disabled(!deck.gate.deviceControlsEnabled))
        // JKL shuttle + frame jog (bare keys — pro NLE muscle memory). Mounted UNCONDITIONALLY,
        // outside the `if hasSource` branch, so before stage 2 they were live even in a window
        // with no media (they no-oped on the engine) and in a window arbitration had gated. They
        // need the explicit transport gate below.
        //
        // ⚠️ `.disabled` ON A HIDDEN BUTTON REALLY DOES SUPPRESS ITS SHORTCUT — MEASURED, not
        // assumed, because the whole disable layer rests on it and the audit flagged it untested.
        // A probe harness mounted the exact constructs used here (hidden `.background` Button,
        // hidden Button inside a disabled `Group`, and a visible Button) with `⌃⌥`-modified keys,
        // bare Space and a bare arrow key. Disabled: none fired. The SAME build with the Space and
        // arrow cases re-enabled: both fired. So the null result is the gate working, not the
        // keystroke going astray — the failure mode docs/MULTIWINDOW_FINDINGS.md §3.1 warns about.
        //
        // K is "pause" and a gated deck is already paused, so disabling it changes nothing —
        // it is in the set to keep the set COHERENT, because a transport row where one key still
        // responds reads as broken rather than as gated.
        .background(
            Group {
                Button("") { engine.shuttleBackward() }
                    .keyboardShortcut("j", modifiers: [])
                Button("") { engine.shuttlePause() }
                    .keyboardShortcut("k", modifiers: [])
                Button("") { engine.shuttleForward() }
                    .keyboardShortcut("l", modifiers: [])
                Button("") { engine.stepFrame(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { engine.stepFrame(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .disabled(!deck.gate.transportEnabled)
        )
        .onContinuousHover { phase in
            if case .active = phase { wakeHUD() }
        }
        // Finder double-click / drag-to-icon is a file-open too, and it bypasses this view's
        // fileImporter — so it must retire a live stream itself, or the stream keeps pushing to the
        // renderer alongside the new file (double source). Closes the gap for EVERY live source
        // through the one entry point the file importer also uses, so the two paths cannot drift as
        // sources are added.
        //
        // MOVED HERE FROM ManifoldApp, which no longer has an engine to load into. SwiftUI routes
        // an opened URL to a window in the group, so it lands in THAT window's deck.
        .onOpenURL { url in
            // Retire this deck's stream, through the arbiter so a stream another window owns is
            // left alone (and so the record of who owns what is updated, not just the transport).
            DeckRegistry.shared.retireLiveIfOwned(by: deck)
            // ⚠️ THE HOP IS MEASURED, NOT DEFENSIVE. SwiftUI creates (or targets) a window for an
            // opened URL and delivers this callback BEFORE that window becomes key — so testing
            // frontmost-ness synchronously asks "is the window the user just asked for in front?"
            // at the one instant the answer is still no. MEASURED with autoplayOnLoad = YES and
            // the launch window still open: the file loaded and sat at frame 0, i.e. the gate
            // refused to autoplay the very window it had just been opened into. Deferring the
            // TEST (not the load's meaning) by one main-actor turn lets the window become key
            // first, which is what makes `deck.shouldAutoplayOnLoad` answer the question that was
            // actually being asked.
            Task { @MainActor in
                // ── RE-USE AN EMPTY WINDOW RATHER THAN LEAVING A STRAY ONE ─────────────────
                //
                // MEASURED (docs/MULTIWINDOW_FINDINGS.md §3.2): SwiftUI creates a NEW window for
                // an opened URL and delivers this callback there, without reusing an existing
                // empty one — so the common "launch, then double-click a file" path left the
                // launch window sitting empty behind the file. The file lands in the window that
                // was ALREADY on screen, at the position and size the user left it, and the window
                // SwiftUI just made for us — which the user never asked for and has never seen
                // content in — closes. Net effect: one file, one window, no stray.
                //
                // Only ever an EMPTY deck is targeted (no media, no stream of its own), and never
                // this one, so nothing loaded is ever displaced and we cannot close the window we
                // just loaded into.
                // `deck.window != nil` is the proof that THIS deck is registered and therefore
                // closable. Without it a callback arriving before registration would load into the
                // other window and then fail to close this one — leaving the stray window the
                // re-use exists to prevent, and a log line claiming otherwise.
                if deck.window != nil,
                   let target = DeckRegistry.shared.emptyDeckToReuse(excluding: deck) {
                    target.load(url: url)
                    target.window?.makeKeyAndOrderFront(nil)
                    NSLog("%@", "[OPEN] loaded into an existing empty window; closing the one this "
                        + "open created")
                    deck.window?.close()
                    return
                }
                engine.load(url: url, autoplay: deck.shouldAutoplayOnLoad)
                wakeHUD()
            }
        }
        // ⚠️ WHAT USED TO BE HERE IS NOW IN WindowDeck.swift — READ THAT FILE BEFORE ADDING TO THIS
        // BLOCK. Sixty lines of engine↔renderer wiring plus five singletons' worth of app-wide
        // hooks (the four `*.shared.renderer` assignments, the three `onWillActivateStream`
        // closures, both audio taps, the SDI silence gate, the system-audio routing) lived in this
        // `.onAppear`. With ONE shared engine every window wrote the same values and the block was
        // idempotent; with one engine PER window it became N conflicting writers of app-wide state.
        //
        // `DeckRegistry` now owns all of it, keyed on `viewDidMoveToWindow` (which knows WHICH
        // window it is firing for — `.onAppear` does not, and cannot deregister). The stage-1
        // policy is unchanged: most recently registered deck wins.
        //
        // WHAT LEGITIMATELY REMAINS: work that needs THIS VIEW'S state and touches nothing app-wide.
        .onAppear {
            armIdleIfNeeded()
            // Persisted arrangement may reopen the tray with scopes already on —
            // start their sampling to match the restored visibility.
            updateScopeSampling()
            // A WINDOW-EDGE DRAG (or the zoom button) ENDS THE RASTER POLICY. The sizer detects it —
            // it is the window's delegate and nothing else sees a live resize — and this is the wire
            // back to the state that owns the answer. `[weak chrome]` because the closure is held by
            // the sizer, which is held by the deck, for as long as the window lives.
            //
            // Assigned here rather than in `WindowConfigurator.updateNSView` deliberately: that runs
            // on every body pass and would rebuild the closure each time for no reason. The sizer is
            // a plain `let` on the deck, so it exists whether or not the window does yet.
            deck.sizer.onUserResize = { [weak chrome] in
                guard let chrome, chrome.rasterSize != .custom else { return }
                chrome.rasterSize = .custom
            }
            RasterMenuState.shared.refresh()
        }
        .onDisappear {
            engine.stop()
            metalRenderer?.stop()
            waveformModel.stop()
            paradeModel.stop()
            vectorscopeModel.stop()
            cieModel.stop()
        }
        .onChange(of: engine.hasMedia) { _, _ in armIdleIfNeeded() }
        // ── THE THREE RASTER TRIGGERS ───────────────────────────────────────────────────────
        //
        // 1. THE SIZE CHANGED. A menu choice, or the sizer flipping this window to `.custom`. The
        //    readout is shown from the size ALREADY DRAWN, so it is a frame behind — trigger 2 then
        //    corrects it the moment the resize lands, which is imperceptible and always true.
        .onChange(of: chrome.rasterSize) { _, _ in
            showRasterNotice()
            RasterMenuState.shared.refresh()
        }
        // 2. THE PICTURE CHANGED SIZE. Refresh the text while the readout is up (so the numbers
        //    track a live drag), and RAISE it during a live resize even when the state did not
        //    change — a second drag of an already-`custom` window still deserves its dimensions.
        .onChange(of: drawnVideoSize) { _, _ in
            if rasterNotice != nil || (deck.window?.inLiveResize ?? false) { showRasterNotice() }
        }
        // 3. THE SOURCE CHANGED. A percentage is a percentage OF something; the View menu is dead
        //    until this window has a raster to take one of.
        .onChange(of: engine.displaySize) { _, _ in RasterMenuState.shared.refresh() }
        // A slot's selection changed → start newly-active scopes, stop ones that left the tray.
        .onChange(of: activeKinds) { _, _ in updateScopeSampling() }
        .onChange(of: engine.effectiveIsFullRange) { _, _ in
            // Range override changed: decode is unchanged (always 420v), so just
            // re-render the current frame with the new shader flag (covers paused).
            metalRenderer?.setNeedsRefresh()
        }
        .onChange(of: engine.metadata) { _, meta in
            // Derive the Metal layer colorspace once per source from the
            // inspector's authoritative color tags (not per-frame from buffers).
            if let meta {
                metalRenderer?.setSourceColorSpace(
                    primaries: meta.colorPrimariesCode,
                    transfer: meta.transferFunctionCode,
                    matrix: meta.colorMatrixCode
                )
                // D5: if DeckLink output is running, re-tag its colorspace from the new primaries
                // (the encoding matrix follows the matrix code automatically, per converted frame).
                //
                // ⚠️ GATED ON OWNERSHIP, AND NOT AS A TIDINESS MEASURE. `sourceFormatChanged` does
                // not merely update a label: if output is RUNNING and the mode changed, it stops
                // and re-establishes the card at the new mode. Ungated, a background window
                // loading a 1080p25 file would live-switch a 2160p23.98 broadcast output that
                // another window is feeding. `drivesDevices` is the arbiter's "the card is talking
                // to MY renderer", which is exactly the deck whose source the card's mode should
                // follow — with output off it is simply the active deck, so the natural
                // "enable output, then load a file" order still works.
                if deck.gate.drivesDevices {
                    DeckLinkService.shared.sourceColorChanged()
                    // D4a: derive the output display mode (video cadence) from the file's
                    // resolution + rate. Updates the status label; live-switches the output mode if
                    // it's running and changed.
                    DeckLinkService.shared.sourceFormatChanged(width: meta.width, height: meta.height,
                                                               frameRate: meta.frameRate)
                }
            }
            // Feed the CIE header the detected source space (honest about untagged → 709 assumed).
            cieModel.spaceReadout = meta.map(Self.cieSpaceReadout) ?? ""
            // Feed the matrix-aware scopes their source CICP codes (header labels + vectorscope
            // graticule). The MATH reads the same codes off the renderer, so labels can't disagree.
            waveformModel.sourceMatrixCode = meta?.colorMatrixCode
            vectorscopeModel.sourceMatrixCode = meta?.colorMatrixCode
            vectorscopeModel.sourcePrimariesCode = meta?.colorPrimariesCode
            // Transfer code drives the waveform/parade AUTO vertical scale (PQ nits / HLG %·nits),
            // independent of the matrix/primaries. Graticule-only — the trace is unchanged.
            waveformModel.sourceTransferCode = meta?.transferFunctionCode
            paradeModel.sourceTransferCode = meta?.transferFunctionCode
        }
        // NDI's colorimetry reaches the shader, the layer and the scope KERNELS through the pixel
        // buffer's CICP attachments, with no help from here. The scope HEADERS and the auto
        // vertical scale do not read the buffer, though — they read these models, which the block
        // above only ever fills from a FILE. So an NDI source needs the same wiring, from the same
        // codes, or the scopes would do PQ math under a "Rec.709" label. Fires on connect and on a
        // mid-stream colorimetry change (NDIService republishes on both).
        //
        // ⚠️ EVERY ONE OF THE FOUR STREAM OBSERVERS BELOW IS GATED ON `drivesDevices`, because they
        // observe SINGLETONS and therefore fire in EVERY open window. Ungated, a stream connecting
        // or disconnecting in window A would repoint window B's scope colorimetry and — on
        // disconnect — call `clearScopes()` on window B, blanking the scopes of a window that is
        // quietly showing a paused file and has nothing to do with the stream.
        .onChange(of: ndi.colorInfo) { _, info in
            guard deck.gate.drivesDevices, ndi.isConnected else { return }
            applyNDIColorToScopes(info)
        }
        .onChange(of: ndi.isConnected) { _, connected in
            guard deck.gate.drivesDevices else { return }
            if connected {
                applyNDIColorToScopes(ndi.colorInfo)
                // A connecting stream is a newly-active source — arm the auto-hide so the control
                // surface reveals then settles exactly as it does when a file loads (line 295).
                armIdleIfNeeded()
            } else {
                // Stream torn down → blank the scopes so they don't sit showing the last stream's
                // trace over the now-black video (clearToBlack handled the picture). Together that
                // is a fully clean empty state. A file taking over instead repaints both on its
                // next frame. NOT called on an NDI→NDI switch (isConnected stays true throughout).
                clearScopes()
            }
        }
        // WHEP teardown ends a source exactly as an NDI disconnect does. clearToBlack (in
        // WHEPFrameRouter.deactivate) already wipes the PICTURE, but the SCOPES still show the last
        // stream's trace — the identical stale-overlay NDI clears just above — so blank them here too
        // for a fully clean empty state. A file taking over instead repaints both on its next frame.
        // On connect, arm the auto-hide so the control surface reveals then settles, matching NDI;
        // there is no color push, because WHEP colorimetry is assumed 709 and set in
        // WHEPFrameRouter.activate rather than published as a source property.
        .onChange(of: whep.isConnected) { _, connected in
            guard deck.gate.drivesDevices else { return }
            if connected {
                armIdleIfNeeded()
            } else {
                clearScopes()
            }
        }
        // SRT is the first PUSH source that can state its own colour, so it gets the wiring NDI
        // has and WHEP could not: the scope HEADERS and the auto vertical scale read these models,
        // not the pixel buffer, so without this an SRT stream that declared PQ would be scoped with
        // PQ math under a "Rec.709" label. `bufferTags` is an NDIColorInfo carrying the SAME
        // declared/assumed provenance, so `applyNDIColorToScopes` and `cieSpaceReadout` label an
        // undeclared axis "(assumed)" for free — which is the common case, since the measured
        // OBS→SRT feed declares nothing at all. (That helper's NDI-prefixed name is now wrong; the
        // type it takes has been the shared CICP vocabulary since WHEP started using it.)
        //
        // Keyed on the colorimetry rather than on `isConnected`, because `isConnected` is published
        // at connect() — seconds before the demuxer has identified the stream — and would fire with
        // nothing to read.
        .onChange(of: srt.colorimetry) { _, colorimetry in
            guard deck.gate.drivesDevices, srt.isConnected, let colorimetry else { return }
            applyNDIColorToScopes(colorimetry.bufferTags)
        }
        // Teardown ends a source exactly as WHEP's does, and needs the same scope wipe for the same
        // reason: clearToBlack wipes the PICTURE, but the scopes would sit showing the last
        // stream's trace over it.
        .onChange(of: srt.isConnected) { _, connected in
            guard deck.gate.drivesDevices else { return }
            if connected {
                armIdleIfNeeded()
            } else {
                clearScopes()
            }
        }
        // ⚠️ WHAT WAS HERE — A `.fileImporter` THAT LOADED STRAIGHT INTO THIS DECK — IS NOW
        // `DeckRegistry.presentOpenPanel(from:)`, and the move is not cosmetic. Opening a file now
        // has a POLICY (re-use an empty window; otherwise this window or a new one, per the
        // preference), there are three places it can be invoked from, and one of them is a menu
        // command in the App scene that has no view state to bind an `isPresented` to. A policy
        // stated once and called from three places beats three call sites agreeing by hand. The
        // retire-the-live-source step the importer did moved into `DeckRegistry.load(_:into:)`
        // with it, so every path still retires before it loads.
        // An .srt is a sidecar to ONE file, so a new source retires it — otherwise the old cues
        // would keep firing confidently against unrelated pictures. Keyed on currentURL rather than
        // the load call sites because media also arrives via ManifoldApp's .onOpenURL (Finder
        // double-click / drag-to-icon), which can't reach this view's state. Also covers the nil
        // transition engine.stop() makes on NDI takeover.
        .onChange(of: engine.currentURL) { _, _ in captions.clear() }
        .sheet(isPresented: $showStreamBookmarks) {
            StreamBookmarksSheet(store: .shared) { url in
                // Same connect+takeover path the chevron rows use; then close the sheet so the async
                // result — a connect-error banner or live video — is visible in the main window.
                connectToStreamURL(url)
                showStreamBookmarks = false
            }
        }
        // Manifold ▸ Export Diagnostics…. Hosted here because the menu command lives in the App
        // scene, which has no window to present on; the exporter singleton is the seam between them.
        .sheet(isPresented: $diagnostics.isPresenting) {
            DiagnosticsPromptSheet()
        }
        .sheet(isPresented: $showGetFlipSheet) {
            VStack(spacing: 16) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Edit in Flip")
                    .font(.title2).bold()
                Text("Flip edits audio layout declarations, timecode, color tags, and other metadata — and writes them back to your file. Manifold inspects; Flip edits.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Not Now") { showGetFlipSheet = false }
                    Button("Get Flip") {
                        if let url = URL(string: "https://graviton.tools/flip") {
                            NSWorkspace.shared.open(url)
                        }
                        showGetFlipSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
            .frame(width: 380)
        }
    }

    /// Source aspect ratio (falls back to 16:9 before metadata loads).
    ///
    /// ⚠️ `WindowSizer` APPLIES THE SAME FALLBACK TO THE SAME INPUT (`engine.displaySize`), and the
    /// two must agree: the window is shaped so that the video region is exactly this ratio, so a
    /// window computed for 16:9 around a region laid out for something else is black bars by
    /// construction. That is why the sizer takes the SIZE and does its own fallback rather than
    /// taking this already-resolved ratio — nil ("no source") and 16:9 ("a 16:9 source") are
    /// different statements to the sizer, which sizes to a source the first time it sees one.
    private var videoAspect: CGFloat {
        if let s = engine.displaySize, s.width > 0, s.height > 0 { return s.width / s.height }
        return 16.0 / 9.0
    }

    /// Total height of everything drawn BELOW the picture in THIS window, in points — the `chromeH`
    /// term in `WindowSizer`'s constraint, and the reason the window grows instead of the video
    /// shrinking.
    ///
    /// PER WINDOW, because every term is: `chrome` is this window's `WindowChrome` (Arc A) and
    /// `hasSource` is this window's engine. Two windows with different chrome states therefore size
    /// independently, with no coordination anywhere — each one's `WindowConfigurator` feeds its own
    /// deck's sizer.
    ///
    /// The docked bar counts only while `hasSource`, because that is exactly when it is in the view
    /// tree; the empty state has no transport to dock.
    private var chromeHeight: CGFloat {
        var height: CGFloat = 0
        if isDocked && hasSource { height += dockedBarHeight }
        if chrome.showTray { height += effectiveTrayHeight }
        return height
    }

    /// ── THE TRAY HEIGHT ACTUALLY LAID OUT, AS OPPOSED TO THE ONE STORED ─────────────────────
    ///
    /// `chrome.trayHeight` is the user's INTENT and is not clamped in storage. This is that intent
    /// reduced to what this window can hold right now, and it is what both the layout
    /// (`.frame(height:)`) and the window arithmetic (`chromeHeight`) use — the two MUST be the same
    /// number or the window is sized for a tray of one height around a tray of another.
    ///
    /// ⚠️ CLAMPING ONLY DURING THE DRAG IS NOT ENOUGH, and the case that proves it is ordinary:
    /// drag the tray to its maximum in OVERLAY mode (1050 pt on this display), then switch to DOCKED.
    /// The bar adds 75, total chrome becomes 1125 against a 1050 ceiling, `constrainedContentSize`
    /// takes the screen cap and THE PICTURE SHRINKS — the exact outcome the divider exists to
    /// prevent, arrived at without touching the divider. Same story for a window dragged onto a
    /// shorter display, or a source whose aspect makes the picture taller.
    ///
    /// Clamping on USE rather than on LOAD is what makes it recoverable: the stored 1050 survives, so
    /// switching back to overlay — or back to the big display — restores the tray the user set
    /// instead of leaving it permanently truncated by a trip through a smaller configuration.
    private var effectiveTrayHeight: CGFloat { clampedTrayHeight(chrome.trayHeight) }

    /// Everything below the picture that the DIVIDER does not size — today just the docked control
    /// bar. Split out from `chromeHeight` because the divider's ceiling is "how much room is left
    /// under the picture, minus what isn't mine to spend", and conflating the two is how a divider
    /// silently starts eating the bar's height.
    private var nonTrayChromeHeight: CGFloat {
        (isDocked && hasSource) ? dockedBarHeight : 0
    }

    /// The tray height the divider is allowed to land on. Floor and ceiling come from different
    /// places on purpose — see `WindowChrome.trayHeight`.
    ///
    /// THE CEILING IS THE WHOLE INVARIANT. `sizer.maxChromeHeight()` is the last total chrome the
    /// window can GROW to hold; subtract the docked bar and what remains is the tray's travel. Past
    /// it the window would hit the screen cap and `constrainedContentSize` would start shrinking the
    /// picture — so the divider stops here instead. It does not push through and let the video pay,
    /// which is the rejected design (docs/ARC-C-SCOPE-DIVIDER.md).
    ///
    /// The `max(…, floor)` guard matters on a small display: if the screen cannot fit even the
    /// minimum tray, the ceiling would come out BELOW the floor and `min(max())` would invert. The
    /// floor wins there, and the screen cap then does what it always does — shrinks the picture on
    /// shape — because at that point there is no arrangement that satisfies both.
    private func clampedTrayHeight(_ proposed: CGFloat) -> CGFloat {
        let floor = WindowChrome.minTrayHeight
        let ceiling = max(deck.sizer.maxChromeHeight(openingFor: engine.displaySize,
                                                     raster: rasterRequest)
                          - nonTrayChromeHeight, floor)
        return min(max(proposed, floor), ceiling)
    }

    /// THIS WINDOW'S RASTER POLICY, as the geometry layer takes it. The view holds the user-facing
    /// state (`RasterSize`, which knows about menu titles and readouts); `WindowSizer` takes the
    /// three-case `RasterRequest`, which knows about widths. See RasterSize.swift.
    ///
    /// `.automatic` and `.custom` both mean "no policy" here, from opposite directions — nothing has
    /// been chosen yet, or the user has chosen with their hands — and the window keeps its width in
    /// both cases.
    private var rasterRequest: RasterRequest {
        if chrome.rasterSize == .fitToScreen { return .fitToScreen }
        guard let fraction = chrome.rasterSize.fraction else { return .unconstrained }
        return .sourceFraction(fraction)
    }

    /// The picture's measured size in DEVICE PIXELS — points × this window's backing scale. The
    /// quantity the readout reports, and the one that makes "100% — 3840×2160" a statement about
    /// source pixels rather than about points. nil until the surface has been laid out.
    private var drawnVideoPixels: CGSize? {
        guard drawnVideoSize.width > 0, drawnVideoSize.height > 0 else { return nil }
        let scale = deck.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: drawnVideoSize.width * scale, height: drawnVideoSize.height * scale)
    }

    /// ── THE TRANSIENT RASTER READOUT ────────────────────────────────────────────────────────
    ///
    /// "100% — 3840×2160", top-left, on change, then gone. The DIMENSIONS are the load-bearing half:
    /// they are what makes a 100% picture occupying 1920×1080 points legible as "every source pixel
    /// is on screen" without a word of explanation anywhere in the app.
    ///
    /// ⚠️ PLACED BELOW THE TRAFFIC LIGHTS, NOT BESIDE THEM. The window is `.hiddenTitleBar`, so the
    /// close/minimise/zoom buttons float in the picture's top-left corner and fade with the control
    /// surface. 44 points of top padding clears them; putting the readout at the corner itself would
    /// have it appear underneath three buttons that are usually visible at exactly the moment it is.
    ///
    /// The auto-hide is `.task(id:)` — the same idiom `connectErrorBanner` uses, for the same
    /// reason: the id is the TEXT, so a new value restarts the timer. That is also what keeps the
    /// readout up for the whole of a window drag, where the dimensions change continuously and each
    /// change re-arms it. What makes "a stale timer cannot wipe a fresh message" actually TRUE is
    /// the cancellation guard inside the task — see the note there, and note that the same guard was
    /// missing from `connectErrorBanner` until this arc.
    @ViewBuilder private var rasterReadout: some View {
        if let text = rasterNotice {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.6), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .padding(.top, 44)
                .padding(.leading, 16)
                .transition(.opacity)
                .task(id: text) {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    // ⚠️ THE CANCELLATION TEST IS WHY THIS READOUT IS VISIBLE AT ALL, and leaving it
                    // out is a silent failure rather than a flicker. Changing the id CANCELS the
                    // running task, `Task.sleep` throws `CancellationError`, `try?` swallows it —
                    // and execution falls straight through to the line below, clearing the notice
                    // the OUTGOING task was never meant to touch.
                    //
                    // MEASURED: a raster change publishes twice within ~10 ms (once when the state
                    // changes, once when the resize lands and the measured dimensions update), so
                    // the first task was always cancelled by the second and always wiped it. The
                    // readout set its text, logged it, and never appeared on screen — three
                    // consecutive screenshots at 0.35 s, 0.5 s and 0.8 s after a menu click caught
                    // nothing. Guarding here fixes it; the incoming task owns the timer.
                    guard !Task.isCancelled else { return }
                    rasterNotice = nil
                }
        }
    }

    /// Is this something this app can show? Guards the drop, so dragging a PDF onto the picture is
    /// refused by the drop itself rather than accepted and then failed at load.
    ///
    /// `public.movie` conformance, which is the same filter the open panel uses. MEASURED against
    /// the formats that matter here: .mov/.mp4/.mxf/.mkv/.avi/.m4v/.r3d all conform; .txt/.pdf/.srt
    /// do not. Deliberately NOT `.audiovisualContent` — a .wav conforms to that, and this app has
    /// nothing to show for an audio-only file.
    private static func isPlayableMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }

    /// Show (or refresh) the readout from CURRENT facts. Never takes the text from its caller — the
    /// three triggers below know that something moved, not what it moved to.
    private func showRasterNotice() {
        guard let text = RasterReadout.text(for: chrome.rasterSize,
                                            displaySize: engine.displaySize,
                                            drawnPixels: drawnVideoPixels) else { return }
        rasterNotice = text
    }

    /// The video region: aspect-fit picture (never cropped/stretched), transport
    /// controls, empty state, and the picture-only overlays (inspector, filename).
    /// Fills whatever height the split gives it.
    private var videoRegion: some View {
        ZStack {
            Color.black
            ZStack {
                // AV surface stays for pump + synchronizer clock, covered by Metal.
                SampleBufferSurfaceView { nsView in
                    Task { @MainActor in
                        engine.attach(renderer: nsView.displayLayer.sampleBufferRenderer)
                    }
                }
                // Metal is the visible surface; hide to reveal the AV reference (⌃⌥R).
                if let renderer = metalRenderer, !showReferenceLayer {
                    MetalSurfaceView(renderer: renderer)
                }
            }
            .aspectRatio(videoAspect, contentMode: .fit)   // full image, aspect preserved
            // THE PICTURE, MEASURED. Attached to the aspect-fitted surface itself, so this is the
            // video rect and not the region around it — the same distinction the guides overlay
            // relies on. Feeds the raster readout's dimensions; see `drawnVideoPixels`.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard abs(size.width - drawnVideoSize.width) > 0.5
                        || abs(size.height - drawnVideoSize.height) > 0.5 else { return }
                drawnVideoSize = size
            }
            // Framing guide overlay — bounds == displayed video rect, so it tracks
            // letterbox/pillarbox + scaling. Self-contained (reads guide prefs); draws
            // nothing when off. Above the video, below the controls.
            .overlay { GuideOverlay() }
            // Captions ride the SAME layer as the guides — bounds == displayed video rect — so the
            // text lands on the real title-safe line rather than a window-relative guess, and
            // tracks letterbox/pillarbox + scaling for free. Gated out of the tree entirely when
            // off: the overlay reads engine.currentTime (10 Hz), so it shouldn't exist when idle.
            .overlay {
                if captions.enabled, captions.isLoaded {
                    CaptionOverlay(engine: engine, captions: captions)
                }
            }

            if isScrubbing, let preview = scrubPreviewImage {
                // SAME aspect authority as the video rect above — deliberately NOT the preview
                // image's own pixel aspect. The two preview producers disagree about pixel aspect
                // ratio: AVAssetImageGenerator applies PAR (its default aperture mode is clean-
                // aperture), while LibavThumbnailSource — the DNxHR path — builds from the raw
                // frame.width/height and ignores sample_aspect_ratio entirely. A ratio-less
                // .aspectRatio(.fit) sizes from the image, so on anamorphic DNx the scrub preview
                // changed shape the moment it appeared. Pinning it to videoAspect lands the preview
                // exactly on the video rect for BOTH producers, whatever the PAR.
                Image(decorative: preview, scale: 1.0)
                    .resizable()
                    .aspectRatio(videoAspect, contentMode: .fit)
            }

            if hasSource {
                // Full control surface for ANY active source (file OR NDI stream). Streaming is a
                // monitoring mode — it needs the same reveal-on-hover HUD, scopes, guides and overlay
                // as file playback. The transport row lives here too; its file-specific affordances
                // simply no-op over a live stream, which is a separate (banked) concern.
                //
                // OVERLAY MODE ONLY. The docked bar left this ZStack: it is chrome, laid out BELOW
                // the picture by `body`, and it used to be drawn here — pinned to the bottom of the
                // video region, i.e. over the frame it was meant to sit under. A floating HUD that
                // auto-hides is the one control surface that belongs on top of the picture.
                if !isDocked {
                    VStack {
                        Spacer()
                        controls(showPin: true)
                            .padding(12)
                            .background(.black.opacity(0.55),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: 760)
                            .padding(16)
                    }
                    .opacity(controlsShown ? 1 : 0)
                    .animation(.easeInOut(duration: 0.30), value: controlsShown)
                }
            } else {
                // "Open… to begin" means NOTHING is on screen — no file and no stream. `hasSource`
                // already folds in the NDI flag, so this branch is reached only when truly idle.
                emptyState
            }

            WindowConfigurator(
                buttonsVisible: hasSource ? controlsShown : true,
                deck: deck,
                displaySize: engine.displaySize,
                chromeHeight: chromeHeight,
                raster: rasterRequest
            )
            .frame(width: 0, height: 0)

            // THE REGISTRATION SEAM. Hands this window's NSWindow (and with it this deck's engine
            // and renderer) to DeckRegistry via `viewDidMoveToWindow`. A sibling of the
            // WindowConfigurator above, which reaches for the same window to lock the aspect —
            // this is the app's established way to get at the NSWindow from SwiftUI.
            WindowDeckRegistrar(deck: deck, engine: engine, renderer: metalRenderer, chrome: chrome)
                .frame(width: 0, height: 0)

            Button("") { togglePin() }
                .keyboardShortcut(.tab, modifiers: [])
                .opacity(0)
        }
        .clipped()
        .overlay(alignment: .topTrailing) {
            if showInspector && engine.hasMedia {
                InspectorPanel(metadata: engine.metadata, engine: engine)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if showFileNameOverlay, engine.hasMedia, let name = engine.metadata?.fileName {
                Text(name)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .padding(.top, 24)
                    .transition(.opacity)
            }
        }
        // ── DROP A FILE ON THE PICTURE TO REPLACE WHAT THIS WINDOW IS SHOWING ───────────────
        //
        // Requested by testers, and with one engine per window it is the natural reading of the
        // gesture rather than a special case: the drop NAMES ITS TARGET — this window's picture —
        // so it loads here, whatever this window is currently showing and whatever the Open…
        // preference says about menus. `DeckRegistry.load(_:into:)` is the explicit path; it retires
        // this deck's live source first and never touches another window's.
        //
        // ⚠️ ON THE VIDEO REGION AND NOT ON `body`. The scopes tray is a sibling of this view, not a
        // child, so it is NOT a drop target — dropping a file on a waveform means nothing. Dragging
        // to the Dock icon or onto an empty area of the app still opens a NEW window, because that
        // path is LaunchServices → `.onOpenURL`, which this does not touch.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isPlayableMedia) else { return false }
            DeckRegistry.shared.load(url, into: deck)
            wakeHUD()
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        // The only affordance a drop gets: the picture's edge lights while a droppable file is over
        // it. Inside the region, so it cannot disturb the window's geometry.
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.white.opacity(0.65), lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: dropTargeted)
        .overlay(alignment: .topLeading) { rasterReadout }
        // The two top-edge notices, stacked so they can never overlap: the STANDING arbitration
        // message (a condition that persists until the user acts, in another window) above the
        // TRANSIENT connect-error banner (a thing that just happened, here). Both non-blocking.
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                arbitrationNotice
                connectErrorBanner
            }
        }
        .animation(.easeInOut(duration: 0.25), value: whep.lastError)
        .animation(.easeInOut(duration: 0.2), value: showInspector)
        .animation(.easeInOut(duration: 0.2), value: showFileNameOverlay)
    }

    /// The DOCKED control bar: the same transport row the overlay HUD shows, laid out as a real bar
    /// BELOW the picture instead of on top of it. Always visible (docking is the mode that opts out
    /// of auto-hide), no pin button (there is nothing to pin), full window width.
    ///
    /// IT MEASURES ITSELF, and that is load-bearing rather than tidy. Its height is an input to the
    /// WINDOW's height — `WindowSizer` grows the window by exactly `chromeHeight` — so a constant
    /// that drifted from the bar's real intrinsic height would silently crop the bottom of the
    /// picture or leave a black sliver under the bar, and the only symptom would be "the framing
    /// looks slightly off". Reporting the laid-out height closes that by construction, and keeps
    /// doing so when the row gains a control.
    ///
    /// The measurement cannot oscillate against the resize it feeds: the row's height is set by its
    /// fixed-size content, not by the width (both readouts are `lineLimit(1)` and the slider absorbs
    /// horizontal squeeze), so a wider or narrower window reports the same number back.
    private var dockedControlBar: some View {
        controls(showPin: false)
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.85))
            .overlay(alignment: .top) {
                // Hairline against the picture, so the bar reads as chrome rather than as a
                // letterbox bar the video happens to stop above.
                Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard height > 0, abs(height - dockedBarHeight) > 0.5 else { return }
                dockedBarHeight = height
            }
    }

    /// ── THE SCOPE TRAY DIVIDER (Arc C) ──────────────────────────────────────────────────────
    ///
    /// Drag it to set the TRAY's height; the WINDOW grows or shrinks to match and the picture is
    /// never touched. That is the Arc B invariant applied to a control instead of to a constant —
    /// see the `VideoBox` header in WindowSizer.swift for why the alternative (re-apportioning a
    /// fixed window) is not on the table: it changes the video region's aspect and pillarboxes the
    /// picture, continuously, under the user's finger.
    ///
    /// ⚠️ THE LINE YOU GRAB DOES NOT MOVE, AND THE SIGN BELOW IS INVERTED BECAUSE OF IT.
    ///
    /// This is NOT a split-pane divider and it cannot behave like one. A split-pane divider moves
    /// because both panes are negotiable; here the picture is fixed by the window's WIDTH, so the
    /// video/tray boundary is always exactly `videoHeight` below the window's top edge and is
    /// therefore PINNED. What actually moves when the tray resizes is the window's BOTTOM edge —
    /// `applyConstraint` anchors the top.
    ///
    /// So the usual divider convention ("drag down → the lower pane shrinks") would put the only
    /// moving edge in the window OPPOSITE to the drag, with nothing under the pointer confirming
    /// anything. Dragging DOWN therefore makes the tray TALLER: the window's bottom edge travels the
    /// same way the pointer does, which is the only co-directional reading available. Grabbing the
    /// boundary and pulling downward opens the tray, like a drawer.
    ///
    /// (Near the screen cap the picture DOES shift up a little: once the window can no longer grow
    /// downward inside the visible frame, `applyConstraint` nudges it back on screen. The picture
    /// never changes SIZE, which is the invariant; it can change position.)
    ///
    /// Drawn as a hairline on the tray's top edge inside a 10-pt grab band that straddles the
    /// boundary — five points of it over the picture, five over the tray. The band is an OVERLAY, so
    /// it contributes nothing to `chromeHeight` and the window arithmetic does not know it exists.
    private var scopeTrayDivider: some View {
        Rectangle()
            .fill(.white.opacity(isDividerActive ? 0.45 : 0.12))
            .frame(height: 1)
            .frame(height: Self.dividerGrabHeight)      // hairline centred in a taller hit box
            .overlay {
                // ⚠️ AN AppKit HANDLE, NOT A SwiftUI `DragGesture`, AND THAT IS NOT A STYLE CHOICE.
                //
                // MEASURED: with a `DragGesture` here, dragging the divider MOVED THE WINDOW —
                // 960,242 → 960,30 — and never changed the tray at all. The window sets
                // `isMovableByWindowBackground = true` (WindowConfigurator), so AppKit begins a
                // window drag on mouse-down over any view that reports `mouseDownCanMoveWindow`, and
                // it wins that race before SwiftUI's gesture recogniser ever sees the event.
                // `DividerHandle` overrides that property to false, which is the only way to decline
                // it, and once it owns mouse-down it may as well own the whole drag.
                DividerHandle(
                    onHoverChange: { dividerHovered = $0 },
                    // Baseline is the EFFECTIVE height, not the stored one: a drag that starts
                    // from a clamped state must start where the user can see the boundary.
                    onBegin: { dividerDragBaseline = effectiveTrayHeight },
                    onDragDown: { deltaDown in
                        // Baseline captured at mouse-down, never re-read: applying an absolute
                        // pointer delta to a live-updating height would integrate the same movement
                        // every event and run away.
                        guard let base = dividerDragBaseline else { return }
                        let next = clampedTrayHeight(base + deltaDown)   // DOWN = taller; see above
                        if abs(next - chrome.trayHeight) > 0.01 { chrome.trayHeight = next }
                    },
                    onEnd: { dividerDragBaseline = nil }
                )
            }
            .offset(y: -Self.dividerGrabHeight / 2)     // straddle the tray's top edge
    }

    /// Hairline is lit while hovered OR mid-drag — the drag half matters because the pointer leaves
    /// the 10-pt band immediately (the band is pinned; the pointer is not).
    private var isDividerActive: Bool { dividerHovered || dividerDragBaseline != nil }

    /// Grab-band height. Wider than the 1-pt hairline it draws, so the target is hittable; narrow
    /// enough that it does not swallow clicks meant for the top row of the scope slots.
    private static let dividerGrabHeight: CGFloat = 10

    /// The scopes tray: three equal-width slots, each rendering the scope its @AppStorage selection
    /// names (data-driven — no scope is special-cased to a fixed slot). The leading header label of
    /// each slot is a live picker (see slotView / ScopeSlotHeader).
    private var scopesTray: some View {
        HStack(spacing: 1) {
            slotView(kind: chrome.slot0, selection: $chrome.slot0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            slotView(kind: chrome.slot1, selection: $chrome.slot1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            slotView(kind: chrome.slot2, selection: $chrome.slot2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipped()
    }

    /// Render the scope view for a slot's kind, wired to that scope's shared model and given the
    /// slot's selection binding so its header label acts as the per-slot picker.
    @ViewBuilder
    private func slotView(kind: ScopeKind, selection: Binding<ScopeKind>) -> some View {
        switch kind {
        case .waveform:    WaveformScopeView(model: waveformModel, slotSelection: selection)
        case .parade:      ParadeScopeView(model: paradeModel, slotSelection: selection)
        case .vectorscope: VectorscopeScopeView(model: vectorscopeModel, slotSelection: selection)
        case .cie:         CIEScopeView(model: cieModel, slotSelection: selection)
        }
    }

    /// The scopes currently occupying a slot — the single source of truth for which models do work.
    private var activeKinds: Set<ScopeKind> { [chrome.slot0, chrome.slot1, chrome.slot2] }

    /// A scope samples only while the tray is open AND its kind occupies a slot. Everything else is
    /// stopped, so a scope not in any slot does ZERO GPU work. Driven purely by `activeKinds` (the
    /// three slot selections) — call on tray toggle, on any slot change, and at startup/teardown.
    /// start()/stop() are idempotent (all four models guard on an `active` flag + a nil-guarded
    /// prefs observer), so repeated calls are safe.
    ///
    /// Sampling is render-coupled: the renderer's onFrameRendered fans out to the active scopes.
    /// The fan-out is GATED to the active set (captured booleans) — not merely relying on stopped
    /// models no-oping — and is cleared entirely when nothing is active, so a closed/empty tray
    /// adds zero per-frame overhead on the render thread.
    private func updateScopeSampling() {
        let active = chrome.showTray ? activeKinds : []

        // Waveform / parade / vectorscope: plain start/stop. The matrix-aware scopes also (re)seed
        // their source CICP codes on (re)start, so a scope opened after the source loaded shows the
        // right header/graticule (mirrors the CIE detected-space refresh below).
        if active.contains(.waveform) {
            waveformModel.renderer = metalRenderer
            waveformModel.sourceMatrixCode = engine.metadata?.colorMatrixCode
            waveformModel.sourceTransferCode = engine.metadata?.transferFunctionCode
            waveformModel.start()
        }
        else { waveformModel.stop() }
        if active.contains(.parade) {
            paradeModel.renderer = metalRenderer
            paradeModel.sourceTransferCode = engine.metadata?.transferFunctionCode
            paradeModel.start()
        }
        else { paradeModel.stop() }
        if active.contains(.vectorscope) {
            vectorscopeModel.renderer = metalRenderer
            vectorscopeModel.sourceMatrixCode = engine.metadata?.colorMatrixCode
            vectorscopeModel.sourcePrimariesCode = engine.metadata?.colorPrimariesCode
            vectorscopeModel.start()
        }
        else { vectorscopeModel.stop() }
        // CIE also refreshes its detected-space header on (re)start.
        if active.contains(.cie) {
            cieModel.renderer = metalRenderer
            cieModel.spaceReadout = engine.metadata.map(Self.cieSpaceReadout) ?? ""
            cieModel.start()
        } else { cieModel.stop() }

        let wf = active.contains(.waveform), pd = active.contains(.parade)
        let vs = active.contains(.vectorscope), cie = active.contains(.cie)
        metalRenderer?.onFrameRendered = active.isEmpty
            ? nil
            : { [weak waveformModel, weak paradeModel, weak vectorscopeModel, weak cieModel] in
                if wf { waveformModel?.frameRendered() }
                if pd { paradeModel?.frameRendered() }
                if vs { vectorscopeModel?.frameRendered() }
                if cie { cieModel?.frameRendered() }
              }
    }

    /// Blank every scope's published trace — called when a stream disconnects so the tray doesn't
    /// keep showing the last stream's trace over the now-black video. The models stay ACTIVE (not
    /// stopped): the renderer invalidated the offscreen they sample, so nothing resamples the old
    /// frame, and when a new source renders they resume automatically. NOT called on an NDI→NDI
    /// switch (isConnected never dips), so switching keeps the scopes live.
    private func clearScopes() {
        waveformModel.clear()
        paradeModel.clear()
        vectorscopeModel.clear()
        cieModel.clear()
    }

    /// Hidden keyboard shortcuts for the scopes tray + CIE live toggles. Grouped into one view
    /// (instead of many chained `.background(Button…)`) to keep the main body's type-check tractable.
    /// Per-scope presence shortcuts (formerly ⌃⌥W/P/V) are gone — tray content is now the per-slot
    /// picker. The CIE shortcuts act on the CIE model wherever it sits (no-op if it's in no slot).
    ///   ⌃⌥T  scopes tray open/close.
    ///   ⌃⌥X  CIE u'v' ↔ xy — flips renderer (kernel) + model (graticule/header) together, then
    ///        setNeedsRefresh re-plots the current frame (covers paused).
    ///   ⌃⌥G  Vectorscope graticule FIXED 709 ↔ SOURCE-PRIMARIES (overlay-only → redraws immediately).
    ///   ⌃⌥B  Vectorscope target boxes cycle 75% → 100% → both (overlay-only → redraws immediately).
    ///   ⌃⌥1/2/3  CIE per-triangle show/hide (overlay-only → SwiftUI re-renders immediately).
    @ViewBuilder private var scopeShortcuts: some View {
        Group {
            Button("") { chrome.showTray.toggle(); updateScopeSampling() }
                .keyboardShortcut("t", modifiers: [.control, .option])
            Button("") {
                // Shared path with the header options menu — writes the stored value, drives the
                // kernel copy, and re-plots. Toggle = apply the negation of the current value.
                CIEScopeModel.applyMode(useUV: !cieUseUV, storage: $cieUseUV, renderer: metalRenderer)
            }
            .keyboardShortcut("x", modifiers: [.control, .option])
            // ⌃⌥G  Vectorscope graticule: FIXED 709 ↔ SOURCE-PRIMARIES. Overlay-only — write the
            // stored value; VectorscopeScopeView's @AppStorage on the same key redraws immediately
            // (the trace math already tracks the source matrix, so no re-plot is needed).
            Button("") {
                vectorscopeGraticule = (vectorscopeGraticule == .fixed709) ? .sourcePrimaries : .fixed709
            }
            .keyboardShortcut("g", modifiers: [.control, .option])
            // ⌃⌥B  Vectorscope target boxes: cycle 75% → 100% → both. Overlay-only (redraws the boxes).
            Button("") {
                switch vectorscopeBoxAmplitude {
                case .percent75:  vectorscopeBoxAmplitude = .percent100
                case .percent100: vectorscopeBoxAmplitude = .both
                case .both:       vectorscopeBoxAmplitude = .percent75
                }
            }
            .keyboardShortcut("b", modifiers: [.control, .option])
            // Triangle visibility is overlay-only — write the stored flag; CIEScopeView's @AppStorage
            // on the same key redraws immediately (no re-plot needed).
            Button("") { cieShow709.toggle() }
                .keyboardShortcut("1", modifiers: [.control, .option])
            Button("") { cieShowP3.toggle() }
                .keyboardShortcut("2", modifiers: [.control, .option])
            Button("") { cieShow2020.toggle() }
                .keyboardShortcut("3", modifiers: [.control, .option])
        }
        .opacity(0)
    }

    /// DeckLink output accelerators — route through the SAME start/stop path as the toolbar control,
    /// so button and shortcut never disagree. ⌃⌥O = start, ⌃⌥⇧O = stop (both no-op if already there).
    @ViewBuilder private var deckLinkShortcuts: some View {
        Group {
            Button("") { DeckRegistry.shared.startDeckLinkOutput(from: deck) }
                .keyboardShortcut("o", modifiers: [.control, .option])
            Button("") { DeckRegistry.shared.stopDeckLinkOutput(from: deck) }
                .keyboardShortcut("o", modifiers: [.control, .option, .shift])
        }
        .opacity(0)
    }

    /// NDI keyboard accelerators — the fast path for the SAME actions the toolbar streaming control
    /// drives (one action, two triggers): ⌃⌥N quick-connects (the first discovered source, or a
    /// blocking discovery when the picker hasn't run yet), ⌃⌥⇧N disconnects. The toolbar chevron is
    /// the discoverable path (pick/switch a specific source); these are the muscle-memory path. NDI
    /// takes over the display while connected (see NDIService); file<->NDI handoff is a later step.
    @ViewBuilder private var ndiShortcuts: some View {
        Group {
            Button("") {
                DeckRegistry.shared.connectLive(.ndi, from: deck) {
                    LiveSource.connectNDIFirstSource()
                }
            }
            .keyboardShortcut("n", modifiers: [.control, .option])
            Button("") { DeckRegistry.shared.retireLiveIfOwned(by: deck) }
                .keyboardShortcut("n", modifiers: [.control, .option, .shift])
            // ⌃⌥C cycles the colorimetry override. The toolbar picker is the real control; this is
            // a keyboard path for driving it hands-off (and for A/B-ing a preset against the picture
            // without moving the pointer, which is how you actually judge one).
            Button("") { cycleNDIColorimetryOverride() }
                .keyboardShortcut("c", modifiers: [.control, .option])
        }
        .opacity(0)
    }

    /// DEBUG-only synthetic live-source probe — Step 1 of the live-streaming clock foundation.
    /// Replays the CURRENTLY-LOADED file through the LIVE path (driven by `LiveClock`, not the
    /// file-timeline synchronizer), with zero networking, to validate the anchor + presentation-
    /// clock skeleton before any WHEP transport exists. Same keyboard-probe role the early NDI
    /// ⌃⌥N trigger played — a test harness, NOT user-facing UI. Compiled out of Release.
    ///   ⌃⌥L   start: re-feed the loaded file's decoded frames as if they were arriving live
    ///   ⌃⌥⇧L  stop: restore normal file playback (also ABORTS a running ⌃⌥S sweep, with a partial table)
    ///   ⌃⌥P   cycle drift/jitter tuning preset (clean → drift → drift+jitter), live + next start
    ///   ⌃⌥U   toggle control loop OFF (rate≡1.0) to read measured depth at unity — live + next start
    ///   ⌃⌥S   auto-sweep the (targetDepth × jitter) grid — 24 cells × 15s, per-cell verdict + summary
    ///         table to stderr; load a clip, hit ⌃⌥S, walk away. Second ⌃⌥S aborts early.
    ///   ⌃⌥W   libdatachannel link smoke test (WHEP step 1) — logs version + PeerConnection
    ///         create/delete. No networking; proves the static lib linked and runs. Temporary.
    ///   ⌃⌥H   WHEP session (steps 2–4) — recvonly offer → POST → answer → ICE/DTLS, then RTP
    ///         → RFC 6184 depacketize → VideoToolbox decode → promote → LiveClock → SCREEN.
    ///         WHEP takes the display while connected (a loaded file is retired), so this is
    ///         also the source-activation trigger. Watch [WHEP-RTP] for NAL counts,
    ///         [WHEP-DECODE] for the decode rate, and [WHEP-FLOW] + [LIVECLOCK] for the
    ///         producer/consumer pair. Connects the FIRST saved stream bookmark (a convenience over
    ///         the shipping Stream Sources sheet); no-op with a log if none is saved. ⌃⌥⇧H tears down.
    ///   ⌃⌥⇧E  export the next decoded WHEP frame to a PNG (pre-render, decoder-side check)
    ///   ⌃⌥D   SRT session (stage 3d) — libsrt caller → AVIOContext → mpegts demux → access
    ///         units → VideoToolbox decode → promote → LiveClock → SCREEN. SRT takes the display
    ///         while connected (a loaded file is retired), so this is a source-activation trigger
    ///         like ⌃⌥H. Watch [SRT] for the connect facts and colorimetry, [SRT-AU] for the
    ///         demux/reader counters and the reorder measurement, and [SRT-FLOW] + [LIVECLOCK] for
    ///         the producer/consumer pair. ⌃⌥⇧D tears it down.
    ///         TARGET IS HARDCODED to srt://127.0.0.1:9000 — the SHORTCUT is the temporary part,
    ///         not the path it drives. Stage 3e wires the stream-bookmark UI (StreamType.srt is
    ///         still marked unsupported there, deliberately, until it does).
    /// The property is defined in all configs (the `.background` mounting it is unconditional);
    /// only the triggers are `#if DEBUG`.
    @ViewBuilder private var syntheticLiveShortcuts: some View {
        #if DEBUG
        Group {
            Button("") {
                guard let url = engine.currentURL, let renderer = metalRenderer else {
                    NSLog("[SyntheticLive] load a file first — ⌃⌥L replays the loaded file through the live path")
                    return
                }
                // Retire file playback first (one active source), exactly as an NDI takeover does.
                SyntheticLiveSource.shared.start(url: url, renderer: renderer,
                                                 // Through the arbiter, not `engine.stop()`: the
                                                 // deck the harness is taking the display FROM is
                                                 // fully unloaded, every other deck merely yields
                                                 // its transport and keeps its picture.
                                                 retireCurrentSource: {
                                                     DeckRegistry.shared.liveStreamWillActivate()
                                                 })
            }
            .keyboardShortcut("l", modifiers: [.control, .option])
            Button("") { SyntheticLiveSource.shared.stop() }
                .keyboardShortcut("l", modifiers: [.control, .option, .shift])
            // ⌃⌥P cycles the drift/jitter tuning preset — the injected sender-clock conditions the
            // control loop is tuned against. Applies to a running harness immediately + to next start.
            Button("") { SyntheticLiveSource.shared.cyclePreset() }
                .keyboardShortcut("p", modifiers: [.control, .option])
            // ⌃⌥U toggles the LiveClock control loop OFF (rate≡1.0) so [LIVECLOCK] reports the MEASURED
            // depth at unity — the setpoint-reality check before tuning. Applies live + to next ⌃⌥L.
            Button("") { SyntheticLiveSource.shared.toggleForceUnityRate() }
                .keyboardShortcut("u", modifiers: [.control, .option])
            // ⌃⌥S runs the automated (targetDepth × jitter) sweep from the loaded file: steps the grid,
            // holds 15s/cell, logs a [SWEEP] verdict per cell + a [SWEEP-SUMMARY] table. Ensures the
            // harness is up first (same start path as ⌃⌥L). Second ⌃⌥S (or ⌃⌥⇧L) aborts early.
            Button("") {
                guard let url = engine.currentURL, let renderer = metalRenderer else {
                    NSLog("[SWEEP] load a file first — ⌃⌥S sweeps the loaded file through the live path")
                    return
                }
                SyntheticLiveSource.shared.startSweep(url: url, renderer: renderer,
                                                      // Through the arbiter, not `engine.stop()`: the
                                                 // deck the harness is taking the display FROM is
                                                 // fully unloaded, every other deck merely yields
                                                 // its transport and keeps its picture.
                                                 retireCurrentSource: {
                                                     DeckRegistry.shared.liveStreamWillActivate()
                                                 })
            }
            .keyboardShortcut("s", modifiers: [.control, .option])
            // ⌃⌥W — libdatachannel LINK SMOKE TEST (WHEP step 1 of 4). Not a WHEP handshake and
            // not networking: it only proves the vendored static libdatachannel is linked into
            // this binary, initialized, and callable, alongside the DeckLink C++. Delete once a
            // real WHEP session exists. Expect [WEBRTC] lines from the library's own logger too.
            Button("") {
                var message: NSString?
                let ok = ManifoldWebRTCLinkSmokeTest(&message)
                let version = String(cString: ManifoldWebRTCVersion())
                NSLog("[WEBRTC-SMOKE] header version %@ | %@ | %@",
                      version, ok ? "PASS" : "FAIL", message ?? "no detail")
            }
            .keyboardShortcut("w", modifiers: [.control, .option])
            // ⌃⌥H — WHEP HANDSHAKE (step 2 of 4). Builds a recvonly offer, waits for ICE
            // gathering to complete, POSTs the offer SDP to the configured WHEP endpoint,
            // applies the answer, and logs the transport coming up. A spec-compliant WHEP
            // exchange — no server-specific behaviour. Success is "[WHEP] connected"; there is
            // deliberately no picture yet. ⌃⌥⇧H tears the session down (and DELETEs it).
            Button("") {
                // Convenience shortcut over the shipping Stream Sources sheet: connect the first
                // saved WEB bookmark. With the dotfile backdoor gone there is no ambient URL, so
                // ⌃⌥H is a speed path over saved state — never a URL-entry path.
                //
                // `ofType: .web`, not `firstConnectable` — SRT bookmarks became connectable in 3e,
                // so the general form can now return one, and ⌃⌥⇧H (which tears down WHEP and only
                // WHEP) would then have no way to undo what ⌃⌥H did. ⌃⌥D is SRT's trigger.
                if let bookmark = StreamBookmarkStore.shared.firstConnectable(ofType: .web),
                   let url = StreamBookmarkStore.connectURL(for: bookmark) {
                    // Through the arbitration funnel, exactly like the shipping menu path. This
                    // used to call WHEPClient.connect directly and so retired nothing — a live SRT
                    // session stayed up and both pushed to the renderer.
                    DeckRegistry.shared.connectLive(.web, from: deck, label: bookmark.name) {
                        LiveSource.connectWeb(to: url)
                    }
                } else {
                    NSLog("[WHEP] no saved stream — add one via the streaming menu ▸ Stream URL…")
                }
            }
            .keyboardShortcut("h", modifiers: [.control, .option])
            Button("") { DeckRegistry.shared.retireLiveIfOwned(by: deck) }
                .keyboardShortcut("h", modifiers: [.control, .option, .shift])
            // ⌃⌥⇧E — WHEP DECODED-FRAME STILL (step 3b). Writes the next decoded WHEP frame
            // to a PNG in the export folder. Distinct from ⌃⌥E, which reads back the RENDERED
            // frame: nothing is rendered from WHEP yet, so this goes straight from the
            // decoder's CVPixelBuffer via VideoToolbox. A content/geometry check, not a
            // colour-managed export — see LiveVideoDecoder.exportStill.
            Button("") { WHEPClient.shared.exportNextDecodedFrame() }
                .keyboardShortcut("e", modifiers: [.control, .option, .shift])
            // ⌃⌥[ / ⌃⌥] — step the live WHEP buffer target by ∓/± 0.05 s (clamped 0.10…1.00).
            //
            // WHY THIS EXISTS: the cushion is being SIZED against measured jitter, and one
            // connection has to test several values or the comparison is confounded by whatever
            // the network was doing on each separate connect. Each press logs
            // `[LIVECLOCK] targetDepth A -> B (manual)` and the ongoing [LIVECLOCK] line carries
            // the current target, so the log is self-documenting about which value each stretch of
            // [WHEP-UNDERRUN] / [WHEP-JITTER] output was measured at.
            //
            // The clock re-anchors on the step, so the new depth is acquired immediately instead of
            // over ~10 s at the ±0.5% rail — see LiveClock.adjustTargetDepth for the direction
            // argument (deepening moves now() BACKWARD, which only holds the current frame longer).
            //
            // ROUTED TO WHICHEVER PUSH SOURCE IS LIVE, not hardwired to WHEP. SRT's 0.250 target
            // is an ARGUED starting value rather than a measured one, so it needs this stepper
            // more than WHEP does — a stepper that only moved WHEP's clock would have left the
            // newer number the harder one to measure. The switch is exhaustive over LiveSource on
            // purpose: a fourth push source cannot be added without deciding what this does.
            Button("") { stepLiveTargetDepth(by: -0.05) }
                .keyboardShortcut("[", modifiers: [.control, .option])
            Button("") { stepLiveTargetDepth(by: 0.05) }
                .keyboardShortcut("]", modifiers: [.control, .option])
            // ⌃⌥D — SRT SESSION (stage 3d). D for Demux, kept from the stage-2 spike this
            // replaces: S, R and T are all taken (⌃⌥S sweep, ⌃⌥R, ⌃⌥T), and D is free in both
            // plain and shifted form and is not adjacent to ⌃⌥L or ⌃⌥H, the two other live-path
            // triggers most likely to be pressed in the same session.
            //
            // ⚠️ THE SHORTCUT IS THE TEMPORARY PART, NOT WHAT IT DRIVES. Everything below the
            // button — SRTClient, SRTFrameRouter, ManifoldSRTSession — ships in Release. Only
            // this trigger is #if DEBUG.
            //
            // THE SHIPPING ENTRY POINT NOW EXISTS: stage 3e un-gated StreamType.srt, so a saved
            // srt:// bookmark connects from the menu and the sheet like any other. This shortcut
            // therefore prefers the first saved SRT bookmark — passphrase and all, through the same
            // connectURL path the UI uses — and falls back to the loopback probe only when nothing
            // is saved, which is what makes it still useful on a fresh machine.
            //
            // UNLIKE the spike, this DOES take the display: the file is retired and the screen
            // blacked at connect, and the route is configured once the demuxer has reported the
            // stream's colorimetry.
            Button("") {
                let bookmark = StreamBookmarkStore.shared.firstConnectable(ofType: .srt)
                let saved = bookmark.flatMap { StreamBookmarkStore.connectURL(for: $0) }
                // One lookup, used for BOTH the URL and the name another window would be shown —
                // two lookups could disagree if the store changed between them.
                DeckRegistry.shared.connectLive(.srt, from: deck, label: bookmark?.name) {
                    LiveSource.connectSRT(to: saved ?? Self.srtDebugTarget)
                }
            }
            .keyboardShortcut("d", modifiers: [.control, .option])
            Button("") { DeckRegistry.shared.retireLiveIfOwned(by: deck) }
                .keyboardShortcut("d", modifiers: [.control, .option, .shift])
        }
        .opacity(0)
        #else
        EmptyView()
        #endif
    }

    /// ⌃⌥D's target. HARDCODED ON PURPOSE for this stage, exactly as the stage-2 spike's was: a
    /// URL-entry path here would be a second, parallel way to name a stream that then has to be
    /// kept in step with the shipping one (the bookmark sheet), and stage 3e is what makes the
    /// shipping one reach SRT. 127.0.0.1:9000 is what an `obs → SRT output` on this machine
    /// listens on by default.
    private static let srtDebugTarget = URL(string: "srt://127.0.0.1:9000")!

    /// Step the LIVE push source's LiveClock target. The two push transports keep their own
    /// routers (and their own measured cushions), so this asks which one owns the display rather
    /// than assuming. NDI is a PULL source with no LiveClock at all — there is nothing to step,
    /// and saying so beats silently doing nothing.
    private func stepLiveTargetDepth(by delta: Double) {
        switch activeLiveSource {
        case .web: WHEPFrameRouter.shared.adjustTargetDepth(by: delta)
        case .srt: SRTFrameRouter.shared.adjustTargetDepth(by: delta)
        case .ndi: NSLog("[LIVECLOCK] NDI is a pull source with no depth loop — ⌃⌥[ / ⌃⌥] do nothing")
        case nil:  NSLog("[LIVECLOCK] no live push source — ⌃⌥[ / ⌃⌥] adjust WHEP or SRT while connected")
        }
    }

    private func cycleNDIColorimetryOverride() {
        guard ndi.isConnected else { return }
        let all = NDIColorimetryOverride.allCases
        let i = all.firstIndex(of: ndi.colorimetryOverride) ?? 0
        NDIService.shared.setColorimetryOverride(all[(i + 1) % all.count])
    }

    /// Color — the color-interpretation control: how Manifold reads the incoming color, and the
    /// user's power to override that reading. This is a source-AGNOSTIC control by design. Today it
    /// hosts a single section — the live stream's colorimetry override — because stream content is
    /// all there is to interpret right now. When files gain color-management modes (Bypass /
    /// Embedded / Match-QuickTime) they become a SECOND section in this SAME menu, not a new control:
    /// file and stream are two answers to one question ("what color is this, really?"), so they
    /// belong under one "Color" roof. Build here, don't restructure later — the seam is marked below.
    ///
    /// The face states the EFFECTIVE interpretation and its tier, because the honest thing and the
    /// useful thing are the same sentence here — "709 · Assumed" tells the user both what the scopes
    /// are doing and that nobody actually verified it. The chevron (matching the streaming / DeckLink
    /// split-buttons) makes it read as a menu you OPEN, not a passive readout. An override turns the
    /// control amber: something on screen is a human assertion, not a reading, and that should never
    /// look like the neutral resting state.
    ///
    /// Most NDI senders declare nothing (OmniScope declares nothing at all), so for the common case
    /// the colorimetry section is not a corner-case escape hatch — it is how the stream's colorimetry
    /// gets set.
    private var colorControl: some View {
        // Two-part split face mirroring the streaming / DeckLink controls: a readout element + a
        // lone-chevron menu. The chevron MUST be its own borderlessButton Menu label, not the
        // trailing item of a multi-element label — `.menuStyle(.borderlessButton)` reserves and
        // clips a trailing region for its disclosure indicator, and `.menuIndicator(.hidden)` hides
        // the drawn arrow but not the clip, so a chevron sitting at a rich label's trailing edge is
        // swallowed (the 3b bug: palette + text showed, chevron didn't). A lone chevron sits at its
        // label's leading edge with only empty, harmlessly-clipped space after it — which is exactly
        // why the streaming / DeckLink chevrons render. Both halves open the SAME presets, so the
        // whole face stays clickable; the readout half also reads the effective colorimetry + tier.
        HStack(spacing: 2) {
            Menu {
                colorStreamColorimetrySection
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paintpalette")
                    Text(ndiColorimetryFaceLabel)
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            // The interactive affordance — same size-8 chevron.down as the streaming / DeckLink
            // controls, so the control reads as a menu you open, not a passive readout.
            Menu {
                colorStreamColorimetrySection
                // SEAM: a future file color-management section (Bypass / Embedded / Match-QuickTime)
                // drops into colorStreamColorimetrySection's peer set — same menu, same control —
                // when files gain those modes. Nothing is stubbed today (an inert row would read as
                // broken); the structure is simply ready.
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(ndi.colorInfo.isOverridden ? Color.orange : .white.opacity(0.9))
        .help("Color interpretation — Auto trusts the stream; a preset asserts it (⌃⌥C cycles)")
    }

    /// The live stream's colorimetry override — the one color-interpretation section with content
    /// today. Presets assert a colorimetry; the "Stream" subsection keeps the sender's own claim
    /// visible so an override reads as CONTRADICTING a declaration rather than filling a silence.
    /// Same NDIColorimetryOverride path and tagging as before — relocated into the Color control,
    /// logic untouched.
    @ViewBuilder private var colorStreamColorimetrySection: some View {
        Section("Colorimetry") {
            Picker("Colorimetry", selection: ndiColorimetryBinding) {
                ForEach(NDIColorimetryOverride.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
        }
        Section("Stream") {
            Button(ndiStreamStatusLine) {}.disabled(true)
        }
    }

    /// Effective colorimetry + tier: "2020 PQ · Overridden", "709 · Assumed", "709 · Declared".
    private var ndiColorimetryFaceLabel: String {
        let info = ndi.colorInfo
        return "\(NDIColorInfo.primariesName(info.primaries.code).replacingOccurrences(of: "Rec.", with: "")) "
             + "\(NDIColorInfo.transferName(info.transfer.code).replacingOccurrences(of: "Rec.", with: "")) · \(info.tier)"
    }

    /// The stream's own claim, independent of the override — an absence stated as an absence.
    private var ndiStreamStatusLine: String {
        let d = ndi.declaredColorInfo
        guard d.isDeclared else { return "Declares no colorimetry" }
        return "Declares \(NDIColorInfo.primariesName(d.primaries.code)) · "
             + "\(NDIColorInfo.transferName(d.transfer.code)) · "
             + "\(NDIColorInfo.matrixName(d.matrix.code))"
    }

    private var ndiColorimetryBinding: Binding<NDIColorimetryOverride> {
        Binding(get: { ndi.colorimetryOverride },
                set: { NDIService.shared.setColorimetryOverride($0) })
    }

    /// Route the device picker through selectDevice (which cleanly stop/restarts if output is ON).
    private var deckLinkDeviceBinding: Binding<Int> {
        Binding(get: { deckLink.selectedDeviceIndex },
                set: { DeckLinkService.shared.selectDevice($0) })
    }

    /// D4b-3: route the destination picker through setAudioDestination — routing only, so a mid-session
    /// flip re-points the audio WITHOUT re-establishing the card (no video blip, no lost preroll depth).
    private var deckLinkAudioDestinationBinding: Binding<DeckLinkService.AudioDestination> {
        Binding(get: { deckLink.audioDestination },
                set: { DeckLinkService.shared.setAudioDestination($0) })
    }

    /// DeckLink output split-button: main button toggles output (green/filled when ON), chevron
    /// opens a Menu (device picker + plain-speak status). Mirrors the CIE gear-menu interaction.
    /// Button face = icon + on/off only; format text lives in the menu.
    private var deckLinkOutputControl: some View {
        // Driver readiness is known at startup, so a driver-side blocker greys the button out INSTEAD
        // of accepting the click and failing at the moment of use. The tooltip carries the specific
        // reason — including the installed Desktop Video version when it's below our floor, which used
        // to surface only in the output log after a failed attempt.
        //
        // Only DRIVER-side states disable (see isDriverBlocked): they can't change without a relaunch.
        // "No device" stays clickable — a card can appear at any moment, and the start path re-probes.
        let status = deckLink.driverStatus
        // A deck that does not own the devices may not claim the card — the SAME greying the
        // below-floor driver already uses, with the arbitration reason in the tooltip in place of
        // the driver one. Silent theft of a broadcast output is the worst outcome available here,
        // so the refusal is visible before the click rather than a surprise after it.
        let arbitrated = !deck.gate.deviceControlsEnabled
        let blocked = (status.isDriverBlocked && !deckLink.isOutputting) || arbitrated
        return HStack(spacing: 2) {
            Button { DeckRegistry.shared.toggleDeckLinkOutput(from: deck) } label: {
                Image(systemName: deckLink.isOutputting ? "tv.fill" : "tv")
            }
            .disabled(blocked)
            .foregroundStyle(deckLink.isOutputting && !arbitrated ? Color.green
                             : .white.opacity(blocked ? 0.35 : 0.9))
            .help((arbitrated ? deck.gate.reason : nil)
                  ?? (blocked ? status.blockedReason : nil)
                  ?? (deckLink.isOutputting ? "DeckLink output ON — click to stop (⌃⌥⇧O)"
                                            : "DeckLink output — click to start (⌃⌥O)"))

            Menu {
                Section("Output device") {
                    if deckLink.devices.isEmpty {
                        // Say WHICH absence this is — an old driver is not a missing card.
                        Button(status.headline) {}.disabled(true)
                    } else {
                        Picker("Output device", selection: deckLinkDeviceBinding) {
                            ForEach(deckLink.devices, id: \.index) { d in
                                Text(d.displayName).tag(d.index)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
                // D4b-3: a live operational choice (a client may want the room speakers for a minute),
                // so it lives in the toolbar menu, not Settings. Mutually exclusive — there is no
                // "Both": the same program on two paths is never wanted. Only meaningful while output
                // is ON; with DeckLink off, audio is plain desktop playback governed by the mute button.
                Section("Audio") {
                    Picker("Audio destination", selection: deckLinkAudioDestinationBinding) {
                        Text("SDI (follows video)").tag(DeckLinkService.AudioDestination.sdi)
                        Text("Computer").tag(DeckLinkService.AudioDestination.computer)
                    }
                    .pickerStyle(.inline)
                    .disabled(!deckLink.isOutputting)
                }
                Section("Signal") {
                    Button(deckLink.signalLine) {}.disabled(true)
                }
                // A below-floor driver enumerates devices perfectly well, so the picker above can look
                // healthy while output is impossible. State the reason where the picker is.
                if let reason = status.blockedReason, !deckLink.devices.isEmpty {
                    Section("Unavailable") {
                        Button(reason) {}.disabled(true)
                    }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("DeckLink output options")
            // The device picker and the audio destination are DEVICE controls too: switching the
            // output device stops and restarts the card, and the destination decides which window's
            // engine is muted. Neither belongs to a window that does not own the card.
            .disabled(arbitrated)
        }
    }

    /// Streaming source control — a split-button mirroring `deckLinkOutputControl` and sitting next
    /// to it. The main button quick-connects to the first NDI source (or disconnects when already
    /// streaming); the chevron opens the technology → source picker. Lit green while streaming,
    /// full-brightness white when LOCAL — local is a legitimate resting mode, so it must read as
    /// available, not as a disabled/off look. Discovery runs only while this control is on screen
    /// (onAppear/onDisappear), so `discoveredSources` is already warm when the menu is opened.
    private var streamingControl: some View {
        // Same rule as the DeckLink control: a non-owning deck may neither connect a stream nor
        // disconnect somebody else's. `activeLiveSource` is ownership-scoped, so the lit-green
        // state and the "click to stop" copy describe THIS window's stream, never another's.
        let arbitrated = !deck.gate.deviceControlsEnabled
        let mine = (activeLiveSource == .ndi)
        return HStack(spacing: 2) {
            Button { toggleStreaming() } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
            }
            .foregroundStyle(mine ? Color.green : .white.opacity(arbitrated ? 0.35 : 0.9))
            .help(arbitrated ? (deck.gate.reason ?? "Streaming is in another window")
                  : mine
                  ? "Streaming — \(ndi.connectedSourceName ?? "NDI") — click to stop (⌃⌥⇧N)"
                  : "Streaming — local mode; click to connect the first NDI source, or use the menu to pick (⌃⌥N)")

            Menu {
                streamingMenuContent
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Streaming sources")
        }
        .disabled(arbitrated)
        .onAppear { ndi.startDiscovery() }
        .onDisappear { ndi.stopDiscovery() }
    }

    /// Caption control — a split-button mirroring `streamingControl` / `deckLinkOutputControl`. The
    /// main button toggles the caption overlay, or opens the picker on the first click when nothing
    /// is loaded yet (an Aa that does nothing until you've found a hidden menu item reads as broken).
    /// The chevron loads/replaces/clears the sidecar and picks the position preset. Lit green while
    /// captions are showing, same on/off language as loop and the scopes tray.
    ///
    /// The chevron MUST stay the LONE element of the Menu's label — see the note on `colorControl`:
    /// `.menuStyle(.borderlessButton)` clips a trailing region for its disclosure indicator, and
    /// `.menuIndicator(.hidden)` hides the arrow but not the clip, so a chevron at a rich label's
    /// trailing edge gets swallowed.
    private var captionControl: some View {
        HStack(spacing: 2) {
            Button {
                if captions.isLoaded { captions.enabled.toggle() } else { presentCaptionPicker() }
            } label: {
                Image(systemName: "textformat")
            }
            .foregroundStyle(captions.enabled ? Color.green : .white.opacity(0.9))
            .help(captions.isLoaded
                  ? (captions.enabled ? "Captions on — click to hide" : "Captions off — click to show")
                  : "Load subtitles…")

            Menu {
                Button(captions.isLoaded ? "Load different subtitles…" : "Load subtitles…") {
                    presentCaptionPicker()
                }
                if captions.isLoaded {
                    Button("Clear subtitles") { captions.clear() }
                    Divider()
                    Section("Position") {
                        Picker("Position", selection: $captionPosition) {
                            ForEach(CaptionPosition.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                    }
                    if let name = captions.sourceURL?.lastPathComponent {
                        Divider()
                        Button("\(name) — \(captions.cues.count) cues") {}.disabled(true)
                    }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Subtitle options")
        }
        // File-only, same rule as loop: NDI takeover calls engine.stop(), which zeroes hasMedia,
        // so this self-disables for live sources. Captions over no picture are meaningless.
        .disabled(!engine.hasMedia)
    }

    /// Subtitle picker. NSOpenPanel directly, NOT SwiftUI's .fileImporter: .fileImporter silently
    /// no-ops against this app's custom PlayerWindow — the binding flips and no panel is ever
    /// constructed (confirmed by dumping NSApp.windows: no NSOpenPanel appears at all). The
    /// export-folder picker in Preferences has always used NSOpenPanel for the same reason, so this
    /// is the app's working idiom, not a workaround.
    ///
    /// `runModal()` is application-modal — no parent window to pick, so it's safe with several
    /// Manifold windows open — and is the same presentation the working export-folder picker uses.
    ///
    /// The extension-derived type resolves to a DYNAMIC UTType (nothing on macOS declares .srt),
    /// which matches real .srt files correctly. Do NOT "simplify" this to .plainText: .srt does not
    /// conform to public.plain-text, so that would grey out every .srt file in the panel.
    private func presentCaptionPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        panel.message = "Choose a subtitle file (.srt) for this clip"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt")].compactMap { $0 }
        // A sidecar almost always sits beside its movie. nil (no file loaded) means "default
        // location" to NSOpenPanel, so this needs no guard.
        panel.directoryURL = engine.currentURL?.deletingLastPathComponent()
        // load() logs its own parse failures; a cancel is a no-op, same as the media importer.
        if panel.runModal() == .OK, let url = panel.url { captions.load(url) }
    }

    /// The streaming menu: SUPPORTED TECHNOLOGIES, each a submenu of its sources. NDI is the only
    /// real entry today; WHEP / SRT / HLS get sibling `Menu`s here when they land — the structure is
    /// ready, but nothing is stubbed (an inert "coming soon" row would read as broken). "Disconnect"
    /// appears at the top level whenever a source is live, so stopping streaming is always one reach.
    @ViewBuilder private var streamingMenuContent: some View {
        Menu {
            ndiSourceListItems
        } label: {
            Label("NDI", systemImage: "antenna.radiowaves.left.and.right")
        }
        // Sibling to NDI: saved URL streams. Flat "Stream URL…" (opens the sheet) until a bookmark
        // exists, then a "Streams" section of flat rows + "Manage…". Shared with the empty-state pill.
        streamURLMenuItems

        // Ownership-scoped: `activeLiveSource` is nil in a window that does not own the stream,
        // so Disconnect appears ONLY in the owning window. That is the copy the standing message
        // promises every other window — "turn it off there".
        if activeLiveSource != nil {
            Divider()
            Button(role: .destructive) {
                DeckRegistry.shared.retireLiveIfOwned(by: deck)
            } label: {
                Label("Disconnect", systemImage: "stop.circle")
            }
        }
    }

    /// The live NDI source rows — the one place the discovered list becomes menu items, so every
    /// entry point (toolbar chevron, empty-state "Connect Stream…") shows the SAME sources and
    /// picks through the SAME `NDIService.connect(to:)`. Honest when empty (no silent menu). The
    /// active source is checkmarked; picking it again is a no-op guarded in NDIService.
    @ViewBuilder private var ndiSourceListItems: some View {
        if ndi.discoveredSources.isEmpty {
            // Distinguish "runtime absent" from "runtime present but no sources" — the former must
            // NOT read as "no sources found". startDiscovery() (this view's .onAppear) sets the
            // flag; NDIBridge.loadRuntime() is the same idempotent probe, used as an ordering-safe
            // fallback should the empty state render before the flag publishes.
            if !(ndi.runtimeAvailable || NDIBridge.loadRuntime()) {
                Button("NDI runtime not installed — install it in Settings (⌘,) and relaunch.") {}
                    .disabled(true)
            } else {
                Button("No NDI sources found") {}.disabled(true)
            }
        } else {
            ForEach(ndi.discoveredSources, id: \.name) { source in
                Button {
                    DeckRegistry.shared.connectLive(.ndi, from: deck, label: source.name) {
                        LiveSource.connectNDI(to: source)
                    }
                } label: {
                    if source.name == ndi.connectedSourceName {
                        Label(source.name, systemImage: "checkmark")   // the live source
                    } else {
                        Text(source.name)
                    }
                }
            }
        }
    }

    /// The saved stream-bookmark rows — the one place bookmarks become menu items, so the toolbar
    /// chevron and the empty-state pill show the SAME entries and connect through the SAME path
    /// (connectToStreamURL). Mirrors ndiSourceListItems. NEVER shows the URL — name only, because the
    /// path can carry the stream key. Unsupported types (SRT/HLS today) appear DISABLED with the same
    /// honest reason the sheet uses; they are never hidden.
    @ViewBuilder private var streamBookmarkRows: some View {
        ForEach(bookmarks.bookmarks) { bookmark in
            if bookmark.type.isSupported {
                Button(bookmark.name) {
                    // connectURL rejoins the Keychain passphrase; bookmark.url is display-only.
                    if let url = StreamBookmarkStore.connectURL(for: bookmark) {
                        // The NAME, never the URL — a stream path can carry the stream key, and
                        // this is the label another window will show in its standing message.
                        connectToStreamURL(url, name: bookmark.name)
                    }
                }
            } else {
                Button(bookmark.type.unsupportedReason ?? bookmark.name) {}
                    .disabled(true)
            }
        }
    }

    /// The "Stream URL" entry, shared by BOTH menu entry points so their structure can't drift: a
    /// FLAT item that opens the sheet when nothing is saved (never a submenu containing only
    /// "Manage…"), promoted to a flyout of the saved rows + "Manage…" once a bookmark exists.
    @ViewBuilder private var streamURLMenuItems: some View {
        // Leads with the separator that divides the NDI entries above from the stream entries — in
        // BOTH the chevron and the empty-state pill, so neither caller adds its own (which would
        // double up). When bookmarks exist the rows sit FLAT at the top level, NOT in a nested Menu:
        // an AppKit submenu dismisses on the micro-movements of the diagonal hover from parent row
        // into flyout, which made it unusably twitchy. A Section header groups them without adding a
        // hover target — the same reason NDI's discovered sources sit flat.
        Divider()
        if bookmarks.bookmarks.isEmpty {
            Button {
                showStreamBookmarks = true
            } label: {
                Label("Stream URL…", systemImage: "link")
            }
        } else {
            Section("Streams") {
                streamBookmarkRows
            }
            Divider()
            Button("Manage…") { showStreamBookmarks = true }
        }
    }

    /// Connect to a bookmarked or pasted stream URL. Shared by the menu rows and the sheet so the
    /// takeover rule can't diverge.
    ///
    /// THIS IS A TRANSPORT DECISION, NOT AN ARBITRATION ONE — the retire-then-stand-up rule lives
    /// in `LiveSource`, which is the only thing that can call a client's `connect`. What stays here
    /// is the question only a URL can answer: which transport dials it.
    ///
    /// ONE SWITCH, FROM THE SAME `StreamType.detect` THAT DECIDED THE SAVED TYPE, so a bookmark
    /// listed as SRT cannot be dialled by WHEP. Every caller — menu row, sheet row, paste, ⌃⌥H —
    /// arrives here, which is what makes that guarantee worth anything.
    private func connectToStreamURL(_ url: URL, name: String? = nil) {
        switch StreamType.detect(url) {
        case .web:
            DeckRegistry.shared.connectLive(.web, from: deck, label: name) {
                LiveSource.connectWeb(to: url)
            }
        case .srt:
            DeckRegistry.shared.connectLive(.srt, from: deck, label: name) {
                LiveSource.connectSRT(to: url)
            }
        case .hls:
            // Unreachable through the UI: every entry point gates on `type.isSupported`, which
            // still excludes HLS. Handled rather than ignored so a future caller that forgets the
            // gate gets a message instead of a silent no-op.
            NSLog("[STREAM] refusing to connect — HLS is not supported in this build")
        }
    }

    /// Non-blocking error banner for a failed stream connect — the presentation for BOTH the menu
    /// path (no modal open) and the sheet path (which closes on connect, so the async failure lands
    /// here). Shows the TRANSPORT'S own message where there is one (Cloudflare's "Live broadcast not
    /// started yet" on a 409; libsrt's reject reason on a bad passphrase), else a clear generic —
    /// and never a full URL, never a passphrase. Auto-dismisses; the close button or a new attempt
    /// clears it sooner. Never blocks: the user can pick another bookmark or open a file immediately.
    ///
    /// ONE BANNER FOR BOTH TRANSPORTS. They cannot both be connecting, so there is at most one
    /// message to show, and WHEP is checked first only because it is the older path. Both are
    /// cleared on dismissal so a stale message from the other transport cannot re-appear behind
    /// this one.
    ///
    /// THAT PREMISE IS NOW ENFORCED RATHER THAN ASSERTED. It was written when `retireActive` was
    /// merely the convention, and two call sites (⌃⌥D, ⌃⌥H) went around it — so a live WHEP
    /// session and a connecting SRT one could both hold a `lastError` and this `??` would silently
    /// show one and hide the other. Standing a source up now requires a `LiveSource.Arbitration`,
    /// which only LiveSource.swift can mint, and every funnel there retires first.
    /// ALSO CARRIES NON-FATAL PLAYBACK NOTICES, not just connect errors — `engine.playbackNotice`
    /// is the third source. Today's producer is the video-only fallback: when a file's audio track
    /// can't be added to the reader, playback continues without it, and a file that plays silently
    /// with no explanation is its own confusing bug. Checked last so a live connect error, which is
    /// the more urgent condition, still wins.
    /// THE STANDING ARBITRATION NOTICE — another window owns an exclusive device, so this window's
    /// transport is gated. Names the owning file (or stream) and says to turn it off there.
    ///
    /// ⚠️ DELIBERATELY NOT A FOURTH `??` TERM ON `connectErrorBanner`, AND NOT A COPY OF IT. That
    /// banner's own doc comment explains that its single `whep.lastError ?? srt.lastError ??
    /// engine.playbackNotice` slot works ONLY because those three are mutually exclusive — an
    /// arbitration message is not, and a window can perfectly well be gated AND have just failed a
    /// connect. It also auto-dismisses after 9 s, which is exactly wrong here: this is a STANDING
    /// CONDITION, true until someone acts in another window, and a message that quietly vanishes
    /// while the thing it describes is still true is worse than no message.
    ///
    /// So: no timer, no close button, and a neutral (not alarm-orange) treatment — nothing is
    /// broken, the app is telling the user where the controls went.
    @ViewBuilder private var arbitrationNotice: some View {
        if deck.gate.isStanding, let message = deck.gate.reason {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.display")
                    .foregroundStyle(.white.opacity(0.75))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.22)))
            .padding(.top, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder private var connectErrorBanner: some View {
        if let message = whep.lastError ?? srt.lastError ?? engine.playbackNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { whep.clearError(); srt.clearError(); engine.playbackNotice = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
            }
            .padding(12)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.55)))
            .padding(.top, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: message) {
                // Auto-dismiss. A new attempt or the close button clears it sooner; the id change
                // then cancels this sleep, so a stale timer can't wipe a fresh message.
                //
                // ⚠️ THE GUARD IS WHAT MAKES THAT SENTENCE TRUE, and it was missing. A cancelled
                // `Task.sleep` THROWS, `try?` swallows the throw, and the three `clearError()` calls
                // below then ran IMMEDIATELY — so a second failure arriving inside the 9 s window
                // wiped itself on the way in. Found while building the raster readout, which shows
                // twice within ~10 ms and therefore hit it every single time; this banner only hits
                // it when two connect errors land close together, which is why it survived.
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                guard !Task.isCancelled else { return }
                whep.clearError()
                srt.clearError()
                engine.playbackNotice = nil
            }
        }
    }

    /// The streaming button's main-click action (and the ⌃⌥N/⌃⌥⇧N shortcuts funnel through the same
    /// NDIService calls): stop when streaming, quick-connect the first discovered source otherwise.
    private func toggleStreaming() {
        if activeLiveSource == .ndi {
            DeckRegistry.shared.retireLiveIfOwned(by: deck)
        } else {
            DeckRegistry.shared.connectLive(.ndi, from: deck) {
                LiveSource.connectNDIFirstSource()
            }
        }
    }

    /// CIE header readout of the DETECTED source space (primaries · transfer). Honest about
    /// untagged sources: CICP primaries nil / Unspecified (2) means the kernel assumes 709, so the
    /// header SAYS "untagged → 709 (assumed)" rather than laundering the default into a confident
    /// label. Same for an absent/unspecified transfer (assumed 709 gamma).
    /// Point the matrix/transfer-aware scopes at the NDI source's colorimetry — the same fields the
    /// file path fills from MediaInspector, from the same CICP codes, so the two sources cannot
    /// disagree about what a code means. Provenance is preserved on the way through: an ASSUMED
    /// axis reads "(assumed)" in the CIE header exactly as an untagged file does.
    private func applyNDIColorToScopes(_ info: NDIColorInfo) {
        waveformModel.sourceMatrixCode = info.matrix.code
        vectorscopeModel.sourceMatrixCode = info.matrix.code
        vectorscopeModel.sourcePrimariesCode = info.primaries.code
        waveformModel.sourceTransferCode = info.transfer.code
        paradeModel.sourceTransferCode = info.transfer.code
        cieModel.spaceReadout = Self.cieSpaceReadout(info)
    }

    /// CIE header readout for an NDI source. Same honesty rule as the file version below, now over
    /// three tiers — a value the sender never declared is labelled assumed, and one the USER
    /// asserted is labelled an override. Neither is allowed to read like a fact off the wire.
    private static func cieSpaceReadout(_ info: NDIColorInfo) -> String {
        func axis(_ a: NDIColorAxis, _ name: String) -> String {
            switch a.provenance {
            case .declared:   return name
            case .assumed:    return "\(name) (assumed)"
            case .overridden: return "\(name) (override)"
            }
        }
        return axis(info.primaries, NDIColorInfo.primariesName(info.primaries.code)) + " · "
             + axis(info.transfer, NDIColorInfo.transferName(info.transfer.code))
    }

    private static func cieSpaceReadout(_ meta: VideoMetadata) -> String {
        func known(_ s: String) -> Bool { !s.isEmpty && s != "—" }
        let primUntagged = (meta.colorPrimariesCode == nil) || (meta.colorPrimariesCode == 2)
        let transUntagged = (meta.transferFunctionCode == nil) || (meta.transferFunctionCode == 2)
        let primStr = (!primUntagged && known(meta.colorPrimaries))
            ? meta.colorPrimaries : "untagged → 709 (assumed)"
        let transStr = (!transUntagged && known(meta.transferFunction))
            ? meta.transferFunction : "709 gamma (assumed)"
        return "\(primStr) · \(transStr)"
    }

    private func controls(showPin: Bool) -> some View {
        // ONE DECK PLAYS AT A TIME, so everything that moves the transport is gated on this deck
        // being the active one. The set is the scrubber, play/pause + Space, mute, the volume
        // fader and loop; J/K/L and the arrow jog are gated at their hidden buttons in `body`.
        //
        // MUTE AND VOLUME ARE DISABLED, NOT HIDDEN, and for two reasons. A paused engine is silent
        // by construction, so the fader has nothing to act on; and leaving it live lets a window
        // that cannot play mutate the app-wide stored default (the slider writes
        // `Preferences.shared.playbackVolume`, which seeds every window opened afterwards). That
        // second reason is why the gate — not a removal of the write — is the right fix: the pref
        // is still the seed a user sets by moving the fader, and only the deck that may actually
        // play can move it now.
        let transport = deck.gate.transportEnabled
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(leadingReadout)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    // ONE LINE, ALWAYS. In the docked bar this row's height is measured and fed to
                    // the WINDOW's height; a readout that wrapped at a narrow width would make the
                    // bar taller, which would resize the window, which would change the width. One
                    // line breaks that loop at the only place it could start.
                    .lineLimit(1)
                    .frame(minWidth: 86, alignment: .leading)
                    .onTapGesture { cycleReadout() }

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : engine.currentTime },
                        set: { newValue in
                            scrubValue = newValue
                            engine.scrubSeek(to: newValue)
                            requestScrubPreview(at: newValue)
                        }
                    ),
                    in: 0...max(engine.duration, 0.1),
                    onEditingChanged: { editing in
                        if editing {
                            wasPlayingBeforeScrub = engine.isPlaying
                            if engine.isPlaying { engine.pause() }
                            scrubValue = engine.currentTime
                            isScrubbing = true
                        } else {
                            engine.exactSeek(to: scrubValue)
                            isScrubbing = false
                            scrubPreviewImage = nil
                            lastPreviewTime = -1
                            if wasPlayingBeforeScrub { engine.play() }
                        }
                    }
                )
                .disabled(!transport)

                Text(trailingReadout)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)                       // see the leading readout
                    .frame(minWidth: 86, alignment: .trailing)
                    .onTapGesture { cycleReadout() }
            }

            HStack(spacing: 16) {
                Button { DeckRegistry.shared.presentOpenPanel(from: deck) } label: {
                    Image(systemName: "folder")
                }
                .help("Open… (⌘O)")

                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").frame(width: 24)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!transport)
                .help(transport ? (engine.isPlaying ? "Pause (Space)" : "Play (Space)")
                                : (deck.gate.reason ?? "Playback is in another window"))

                Divider().frame(height: 16).overlay(.white.opacity(0.25))

                HStack(spacing: 6) {
                    Button { engine.toggleMute() } label: {
                        Image(systemName: speakerSymbol)
                    }
                    .help(engine.isMuted ? "Unmute" : "Mute")
                    if volumeHovering {
                        Slider(
                            value: Binding(
                                get: { Double(engine.volume) },
                                set: { newValue in
                                    engine.setVolume(Float(newValue))
                                    Preferences.shared.playbackVolume = newValue
                                }
                            ),
                            in: 0...1
                        )
                        .controlSize(.mini)
                        .frame(width: 70)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .onHover { h in
                    withAnimation(.easeInOut(duration: 0.15)) { volumeHovering = h }
                }
                .disabled(!transport)
                Button { engine.toggleLoop() } label: { Image(systemName: "repeat") }
                    .help("Loop playback")
                    // File-only: NDI takeover calls engine.stop(), which zeroes hasMedia, so this
                    // self-disables for live sources (loop is meaningless on an indefinite stream).
                    .disabled(!engine.hasMedia || !transport)
                    .foregroundStyle(engine.isLooping ? Color.green : .white.opacity(0.9))
                Button { showGuidesPanel.toggle() } label: {
                    // `viewfinder.rectangular` — an outer frame with corner brackets and OPEN space
                    // inside it, which is what a framing guide is: marks over a picture you can
                    // still see through.
                    //
                    // It replaces `rectangle.inset.filled`, whose inner rectangle is SOLID. At the
                    // size this row draws (`.imageScale(.large)`, ~16 pt) that fill reads as a block
                    // — a filled tile, or a slide — rather than as an inset. The distinction the
                    // glyph exists to carry is exactly the one the fill destroys: guides are LINES
                    // at an inset, not a filled area. `rectangle.inset.filled` was itself a
                    // replacement for `grid`, which rendered as a bare `#` with no outer frame at
                    // all and read as a table.
                    //
                    // AVAILABILITY CHECKED, NOT ASSUMED — an SF Symbol that postdates the
                    // deployment target renders BLANK at run time and raises no build error, so
                    // compiling proves nothing. The OS's own catalog
                    // (CoreGlyphs.bundle/Contents/Resources/name_availability.plist) lists this
                    // symbol under release year 2023, which that file's `year_to_release` table maps
                    // to macOS 14.0. This target's floor is macOS 15.0, so it is present on every OS
                    // the app can launch on.
                    Image(systemName: "viewfinder.rectangular")
                }
                    .help("Framing guides")
                    .popover(isPresented: $showGuidesPanel, arrowEdge: .bottom) {
                        GuidesPanel()
                    }
                // Captions: split-button — main toggles the overlay (or opens the picker when
                // nothing's loaded yet), chevron loads/clears the sidecar and picks position.
                captionControl
                Button { showInspector.toggle() } label: {
                    Image(systemName: "info.circle")
                }
                .help("Inspector (I)")

                Button(action: editInFlip) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Edit in Flip")
                .disabled(engine.currentURL == nil)

                Button(action: { Task { await engine.reinspect() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh metadata")
                .disabled(engine.currentURL == nil)

                // Export the current frame (ACTION) — sits with the file/action controls.
                Button(action: { metalRenderer?.exportCurrentFrame() }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Export frame (⌃⌥E)")
                .disabled(engine.currentURL == nil)

                Divider().frame(height: 16).overlay(.white.opacity(0.25))

                // Scopes tray (VIEW STATE) — open/close. Which scopes fill the three slots is
                // chosen per-slot via each slot's header picker, not from here.
                Button { chrome.showTray.toggle(); updateScopeSampling() } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .foregroundStyle(chrome.showTray ? Color.green : .white.opacity(0.9))
                .help("Scopes tray (⌃⌥T)")

                // DeckLink output: split-button — main toggles output, chevron picks device + status.
                deckLinkOutputControl

                // Streaming source: split-button next to DeckLink output — main quick-connects/stops,
                // chevron opens the tech → source picker. Lit while streaming, dark (local) otherwise.
                streamingControl

                // Color — the color-interpretation control (source-agnostic). It hosts an ASSERTION
                // about the source, so it lives with the actions, not in the inspector (which reports
                // what things ARE). Today its only section is the live stream's colorimetry override,
                // so it's gated to NDI: it has nothing to say about a file yet (file color-management
                // modes are the future second section). Same appearance rule as before.
                if activeLiveSource == .ndi {
                    colorControl
                }

                Spacer()

                if showPin {
                    Button { togglePin() } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                    }
                    .help(pinned ? "Unpin controls (Tab)" : "Pin controls (Tab)")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .imageScale(.large)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "film")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.45))
            Text("Open a file — or connect a stream")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 12) {
                Button { DeckRegistry.shared.presentOpenPanel(from: deck) } label: {
                    Label("Open…", systemImage: "folder")
                }

                // Cold-start streaming entry (Stage 3a-2): a sibling pill of the same weight as Open…,
                // opening the SAME discovered-source list the toolbar chevron uses — one click to the
                // network sources, picking connects via the SAME NDIService.connect(to:). Discovery
                // runs while this view is on screen (see the ndi.startDiscovery/stopDiscovery below).
                Menu {
                    ndiSourceListItems
                    streamURLMenuItems
                } label: {
                    Label("Connect Stream…", systemImage: "antenna.radiowaves.left.and.right")
                }
                .menuStyle(.button)          // present as a button (pill), matching Open…'s weight
                .buttonStyle(.bordered)
                .fixedSize()
                // The cold-start streaming entry is a device-CLAIM control like the toolbar one,
                // and gets the same gate. Open… stays live beside it: loading a file into a gated
                // deck to inspect it is legitimate, and the autoplay gate covers the rest.
                .disabled(!deck.gate.deviceControlsEnabled)
            }
            .controlSize(.large)
            .tint(.white)
        }
        // The empty state is the ONLY streaming entry when no source is active (the toolbar control
        // lives in the control bar, which isn't shown here), so it drives discovery for its lifetime.
        // Discovery is reference-counted in NDIService, so the brief overlap with the toolbar control
        // during the connect transition doesn't stop it out from under the newly-shown control bar.
        .onAppear { ndi.startDiscovery() }
        .onDisappear { ndi.stopDiscovery() }
    }

    /// Open the current file in Flip (tools.graviton.flip). If Flip isn't
    /// installed, show the upsell sheet. Sniff happens on press.
    private func editInFlip() {
        guard let url = engine.currentURL else { return }
        let flipBundleID = "tools.graviton.flip"
        if let flipURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: flipBundleID) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: flipURL, configuration: config) { _, error in
                if let error { print("Edit in Flip: open failed — \(error.localizedDescription)") }
            }
        } else {
            showGetFlipSheet = true
        }
    }

    /// Speaker icon reflecting mute + volume level.
    private var speakerSymbol: String {
        if engine.isMuted || engine.volume <= 0.0001 { return "speaker.slash.fill" }
        return engine.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    private func togglePin() {
        guard hasSource, !isDocked else { return }
        pinned.toggle()
        idleTask?.cancel()
        hudVisible = pinned
    }

    private func wakeHUD() {
        guard hasSource, !isDocked else { return }
        hudVisible = true
        if !pinned { scheduleIdle() }
    }

    // Start the auto-hide countdown when appropriate (overlay mode, media loaded,
    // not pinned). Safe to call repeatedly — it cancels any prior pending task.
    private func armIdleIfNeeded() {
        guard hasSource, !isDocked, !pinned else { return }
        hudVisible = true
        scheduleIdle()
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(2.0))
            if !Task.isCancelled && !isScrubbing && !pinned && !isDocked {
                hudVisible = false
            }
        }
    }

    private var displayTime: Double { isScrubbing ? scrubValue : engine.currentTime }

    private var leadingReadout: String {
        switch effectiveMode {
        case .source:  return engine.currentSourceTimecode(at: displayTime) ?? timeString(displayTime)
        case .elapsed: return timeString(displayTime)
        case .frame:   return "\(Int((displayTime * frameRateOrDefault).rounded()))"
        }
    }

    private var trailingReadout: String {
        switch effectiveMode {
        case .source:  return engine.endSourceTimecode() ?? timeString(engine.duration)
        case .elapsed: return timeString(engine.duration)
        case .frame:   return "\(engine.totalFrames)"
        }
    }

    private var frameRateOrDefault: Double {
        let f = engine.metadata?.frameRate ?? 0
        return f > 0 ? f : 24
    }

    // If source TC is requested but the file has none, fall back to elapsed.
    private var effectiveMode: ReadoutMode {
        if readoutMode == .source && engine.currentSourceTimecode(at: 0) == nil {
            return .elapsed
        }
        return readoutMode
    }

    private func requestScrubPreview(at time: Double) {
        // Throttle: skip if a request is in flight or the time barely moved.
        guard !previewRequestInFlight else { return }
        guard abs(time - lastPreviewTime) > 0.05 else { return }
        previewRequestInFlight = true
        lastPreviewTime = time
        Task {
            let image = await engine.previewImage(at: time)
            await MainActor.run {
                if isScrubbing { scrubPreviewImage = image }
                previewRequestInFlight = false
            }
        }
    }

    private func cycleReadout() {
        let all = ReadoutMode.allCases
        if let i = all.firstIndex(of: readoutMode) {
            readoutMode = all[(i + 1) % all.count]
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// ── THE SCOPE-TRAY DIVIDER'S HANDLE ─────────────────────────────────────────────────────────
///
/// An AppKit view rather than a SwiftUI `DragGesture`, for one measured reason and one consequence
/// of it.
///
/// THE REASON: the window sets `isMovableByWindowBackground = true`, so AppKit starts a WINDOW DRAG
/// on mouse-down over any view that reports `mouseDownCanMoveWindow == true` — and it decides that
/// before SwiftUI's gesture recogniser is consulted. Measured with a `DragGesture` in this position:
/// dragging the divider moved the window from y=242 to y=30 and left the tray height untouched.
/// Overriding `mouseDownCanMoveWindow` is the only way to decline, and it has to be an NSView.
///
/// THE CONSEQUENCE: since this view must already own mouse-down, it owns the whole drag, which also
/// gets the cursor right. The cursor is a TRACKING AREA (`.cursorUpdate`) plus a re-`set()` on every
/// drag event — not `NSCursor.push()/pop()`. Push/pop unbalances the moment the pointer leaves the
/// band, which here is immediately: the band is pinned to the video's bottom edge and the pointer is
/// not, so it exits within a few points of the start of every drag. An unbalanced `pop` corrupts the
/// app-wide cursor stack; a tracking area owns no global state and cannot.
private struct DividerHandle: NSViewRepresentable {
    var onHoverChange: (Bool) -> Void
    var onBegin: () -> Void
    /// Points dragged DOWN from mouse-down. Positive = downward. See the sign note on
    /// `ContentView.scopeTrayDivider` for why down means a TALLER tray.
    var onDragDown: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) { apply(to: nsView) }

    private func apply(to view: HandleView) {
        view.onHoverChange = onHoverChange
        view.onBegin = onBegin
        view.onDragDown = onDragDown
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onHoverChange: ((Bool) -> Void)?
        var onBegin: (() -> Void)?
        var onDragDown: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?

        private var trackingArea: NSTrackingArea?
        /// Non-nil only while a drag is live. SCREEN y at mouse-down — see `mouseDragged`.
        private var dragOriginScreenY: CGFloat?

        /// ⚠️ THE LINE THAT MAKES THE DIVIDER WORK AT ALL. Without it AppKit moves the window
        /// instead — see the type's header, where the measurement is.
        override var mouseDownCanMoveWindow: Bool { false }

        /// Adjusting the scopes in a window that is not yet key should not cost a click.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.cursorUpdate, .mouseEnteredAndExited,
                                                .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeUpDown.set() }

        override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }

        override func mouseExited(with event: NSEvent) {
            // Mid-drag exits are expected and must NOT unlight the handle — the band is pinned to
            // the video's bottom edge and the pointer leaves it almost immediately.
            if dragOriginScreenY == nil { onHoverChange?(false) }
        }

        override func mouseDown(with event: NSEvent) {
            dragOriginScreenY = NSEvent.mouseLocation.y
            onHoverChange?(true)
            onBegin?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin = dragOriginScreenY else { return }
            // ⚠️ SCREEN COORDINATES, NOT `locationInWindow`. The window is being RESIZED by this very
            // drag, and AppKit window coordinates are measured from its bottom-left — the corner that
            // moves. A window-relative delta would therefore feed the resize back into its own input
            // and diverge. Screen space is the only frame of reference this drag does not perturb.
            // (Same class of bug as `windowWillResize` comparing a mouse-derived size against a
            // self-derived one; see the notes in WindowSizer.swift.)
            NSCursor.resizeUpDown.set()   // transient — re-asserted per event so it survives the drag
            onDragDown?(origin - NSEvent.mouseLocation.y)   // screen y is UP, so down is positive
        }

        override func mouseUp(with event: NSEvent) {
            dragOriginScreenY = nil
            onEnd?()
            // The pointer has usually left the band by now; re-test so the hairline unlights unless
            // it genuinely finished over the handle.
            onHoverChange?(bounds.contains(convert(event.locationInWindow, from: nil)))
        }
    }
}
