import SwiftUI
import ShortcutRegistry
import ManifoldCore
import UniformTypeIdentifiers   // UTType(filenameExtension:) for the .srt picker
import StreamBookmarkModel

enum ReadoutMode: CaseIterable { case source, frame, elapsed }

/// The scopes any tray slot can display. `rawValue` (String) backs @AppStorage persistence of
/// per-slot selections; `displayName` labels the slot picker menu.
///
/// ADDING A CASE IS SAFE FOR EXISTING PREFERENCES: `WindowChrome` decodes with
/// `ScopeKind(rawValue:) ?? .waveform`, so a stored selection written by an older build still
/// resolves and an unknown one falls back rather than throwing.
///
/// ⚠️ `meters` IS THE ONE THAT IS NOT RENDER-COUPLED. The other four sample the frame the
/// renderer just drew; the meters sample audio on their own timer, because audio moves when no
/// frame is being drawn and a paused file draws nothing at all. See AudioMeterScope.swift.
enum ScopeKind: String, CaseIterable, Identifiable {
    case waveform, parade, vectorscope, cie, meters
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .waveform:    return "Waveform"
        case .parade:      return "Parade"
        case .vectorscope: return "Vectorscope"
        case .cie:         return "CIE"
        case .meters:      return "Audio Meters"
        }
    }
}

/// A tray slot's leading header element: the scope's display label rendered as a Menu (pick which
/// scope fills this slot) followed by the scope's own context suffix (e.g. "· luma (10-bit)"). The
/// Menu always lists every `ScopeKind`. When `selection` is nil the label is plain text (the
/// view isn't in a slot-picker context). Leading-edge only — the scope's trailing controls (e.g.
/// intensity slider) are untouched.
struct ScopeSlotHeader: View {
    let name: String                        // shown on the button, e.g. "WAVEFORM"
    let suffix: String                      // context suffix incl. its separator, e.g. " · luma (10-bit)"
    let selection: Binding<ScopeKind>?      // nil → plain label (no picker)

    var body: some View {
#if DEBUG
        let _ = ScopePerf.count("body.ScopeSlotHeader")
#endif
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

/// A tray slot's trailing header element: the per-scope options GEAR, and the popover it opens.
///
/// ── WHY A POPOVER AND NOT A MENU ──────────────────────────────────────────────────────────
///
/// A menu dismisses on every selection. These panels are mostly multi-toggle work — three gamut
/// triangles, two graticule extras, two user lines — so a menu made the common case "open, flip one,
/// reopen, flip the next". A popover stays up until it is dismissed. It is also the only container
/// that can hold a text field: an `NSTextField` inside an AppKit menu does not reliably take focus,
/// which is what numeric entry for the user lines needs (a later step; nothing here types).
///
/// THE LABEL IS UNCHANGED FROM THE MENU IT REPLACES — same glyph, same 9pt, same 0.5 white, same
/// `.fixedSize()`. Only what it opens is different.
///
/// ⚠️ DO NOT ENLARGE THE HIT TARGET. The scope tray's divider grab band is an overlay on the tray's
/// top edge — `.frame(height: 10)` with `.offset(y: -5)`, see `ContentView.scopeTrayDivider` — so 5
/// points of it lie over the top of EVERY scope header, backed by an NSView that takes `mouseDown`
/// and will swallow anything underneath. This glyph is ~11pt centred in the 22pt header band, so it
/// clears that strip by a hair, and the band's own comment claims it "does not swallow clicks meant
/// for the top row of the scope slots" on exactly that margin. A larger frame, extra padding, or a
/// `.contentShape` here spends a budget that has about 5 points in it. `.buttonStyle(.plain)` is
/// load-bearing for the same reason: the default button style would add its own chrome and padding.
///
/// ⚠️ `arrowEdge: .top`, WHICH PUTS THE PANEL ABOVE THE GEAR. The gear sits in the 22-pt header at
/// the TOP of a tray pinned to the BOTTOM of the window, so there is the whole picture above it and
/// very little below. Opening upward has the video to spread over. AppKit treats this as a
/// preference and repositions if the panel does not fit, so this is the good case, not a promise.
///
/// ── ⚠️ `.bottom` WAS TRIED AND REVERTED. DO NOT TRY IT AGAIN WITHOUT READING THIS. ───────────
///
/// Opening downward, over the scopes rather than over the picture, is the obviously nicer idea and
/// it does not survive the measurements. The room below the gear is the tray's height
/// (`WindowChrome.minTrayHeight` 186, `defaultTrayHeight` 204) less the ~11 pt to the gear's centre,
/// PLUS whatever screen lies under the window — and a window sized to its display has almost none.
/// So roughly 175–195 points, against panels of approximately:
///
///     Meters                        ~90    fits
///     CIE                          ~195    marginal at the default, over at the 186 floor
///     Waveform / parade            ~225    does not fit
///     Vectorscope                  ~360    does not fit at any tray height
///
/// (Derived from the panel contents — 12 pt padding each side, a headline, `ScopeGearSectionHeader`
/// dividers, and per-row heights — NOT measured on screen. The right order of magnitude, not figures
/// to design against.)
///
/// TWO OF FOUR WOULD THEREFORE FLIP ALWAYS AND CIE WOULD FLIP AT THE MINIMUM TRAY HEIGHT, which
/// makes `.bottom` INCONSISTENT PLACEMENT rather than a preference: the same gesture would put the
/// meters panel below the gear and the vectorscope panel above it, on the same tray. Uniformly
/// upward is worse in the abstract and better in the hand. Nothing is broken either way — AppKit
/// repositions rather than clipping — which is exactly why this is a judgement about consistency
/// and not a bug report.
///
/// ⚠️ THE THING THAT WOULD ACTUALLY CHANGE THE ANSWER IS MAKING THE PANELS SHORTER, NOT FLIPPING
/// THE EDGE. The vectorscope is the binding constraint at ~360 pt (it grew a section when the
/// reference markers landed); shortening it, or giving it a `ScrollView`, is what would bring the
/// set close enough to a common answer for `.bottom` to be worth revisiting. Changing this constant
/// on its own only moves the inconsistency to a different pair of scopes.
///
/// Container metrics — `.padding(12)`, `.frame(width: 280)`, `VStack(alignment: .leading, spacing:
/// 4)`, a `.headline` title — are `GuidesPanel`'s, deliberately copied rather than re-chosen. That
/// panel is this app's only other popover, and two popovers that agree on their metrics read as one
/// idiom; two that each picked their own read as an accident.
struct ScopeGear<Content: View>: View {
    /// Headline inside the panel.
    let title: String
    /// Tooltip on the gear itself.
    let help: String
    let content: Content

    /// Popover presentation is the gear's OWN state, not the scope's. Each slot's gear opens and
    /// closes independently, and nothing outside needs to know whether one is up.
    @State private var isOpen = false

    /// Content is built EAGERLY (`content()` here, not a stored closure) so its evaluation timing
    /// matches the `Menu { … }` this replaced: constructed when the owning scope's `body` runs.
    /// `ScopeValueAxisGear`'s position submenus read the current position to build their own titles,
    /// which a deferred closure would sample at a different moment.
    init(title: String, help: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).padding(.bottom, 2)
                content
            }
            .padding(12)
            .frame(width: 280)
        }
    }
}

/// A section heading inside a gear popover: a rule, then a caption label.
///
/// `Section` is menu-native and has no popover equivalent, so this is what replaces it — and it is
/// `GuidesPanel`'s spelling of the same thing (`Divider().padding(.vertical, 2)` followed by
/// `Text(...).font(.caption).foregroundStyle(.secondary)`), not a new one.
///
/// `isFirst` suppresses the rule for the section directly under the panel's title, where a divider
/// would be separating the heading from nothing.
struct ScopeGearSectionHeader: View {
    let title: String
    let isFirst: Bool

    init(_ title: String, isFirst: Bool = false) {
        self.title = title
        self.isFirst = isFirst
    }

    var body: some View {
        if !isFirst { Divider().padding(.vertical, 2) }
        Text(title).font(.caption).foregroundStyle(.secondary)
    }
}

/// One option of a mutually-exclusive set inside a gear popover — what an inline `Picker` was in the
/// menu, which likewise has no popover equivalent.
///
/// Lifted from `GuidesPanel.row(label:selected:action:)`: the same `largecircle.fill.circle` /
/// `circle` glyph pair, the same accent-vs-secondary colouring, the same full-width
/// `.contentShape(Rectangle())` so the whole row is the target rather than just the glyph.
///
/// ⚠️ THE LABEL FONT IS THE DEFAULT, NOT `.caption`, WHICH LOOKS INCONSISTENT WITH THE TOGGLES BESIDE
/// IT — and it is inconsistent, in `GuidesPanel` too, where the radio rows run at body size and the
/// toggles at `.caption`. Copied as-is on purpose: matching the one popover this app already has
/// matters more than tidying it, and changing it here would leave the two panels disagreeing. If it
/// is worth fixing it is worth fixing in both, as its own change.
struct ScopeGearRadioRow: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.appYellow : .secondary)
                Text(label)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// Owns this window's five scope models, WITHOUT making `ContentView` observe them.
///
/// ⚠️ A SCOPE PUBLISH MUST REDRAW ONLY THAT SCOPE'S VIEW. The models used to be `@StateObject`s of
/// `ContentView`, and a `@StateObject` subscribes the view that declares it: every trace image a
/// scope published (once per frame each) re-ran the whole window's body — the picture region, the
/// control bar, the transport, the guides — and with it every OTHER scope's view. Measured
/// 2026-10-27 at 23.976 fps, three scopes: 56 `ContentView` bodies a second, ~41 % of a core on the
/// main thread (docs/BUGS.md, "while playing with the scopes tray open, each scope update redraws
/// the whole window").
///
/// This store publishes nothing, so `ContentView` never re-renders because of it, and SwiftUI does
/// not forward a nested object's changes. Each scope view still holds its model as `@ObservedObject`,
/// so a publish invalidates that view and nothing else (and a new trace image only its
/// `ScopeTraceLayer`, see `ScopeTraceImage`). Same `@StateObject` lifetime as before: one
/// set of models per window, built once (see `RendererStore` for why a `@State` default would not do).
///
/// ContentView reads nothing from the models in its body. If it ever needs to, observe that one value
/// in a small child view, never the model here.
private final class ScopeModelStore: ObservableObject {
    let waveform = WaveformScopeModel()
    let parade = ParadeScopeModel()
    let vectorscope = VectorscopeScopeModel()
    let cie = CIEScopeModel()
    let meter = AudioMeterModel()
}

#if DEBUG
/// ⌃⌥H's `MANIFOLD_STREAM_DEBUG_BOOKMARK` list position (pre-ship removal, docs/BUGS.md).
@MainActor enum DebugBookmarkCursor {
    private static var index = 0
    static func next() -> Int { defer { index += 1 }; return index }
}

/// `MANIFOLD_DEBUG_DIAL_URL=<url>` (launch environment; added 2026-10-23 for the SDI scaling follow-ups' in-app HLS
/// ladder check; pre-ship removal, docs/BUGS.md): the first window to appear dials this URL once, 2 s after it appears,
/// through `connectToStreamURL`, the dispatch the Stream URL sheet uses (WHEP, SRT or HLS by the URL). An unattended
/// run can then connect a stream with no keystroke, and without reading or writing `streamBookmarks`. Unset, nothing
/// happens. Compiled out of Release.
@MainActor enum DebugDial {
    private static var fired = false
    static func fireOnce(_ dial: @escaping (URL) -> Void) {
        guard !fired, let raw = ProcessInfo.processInfo.environment["MANIFOLD_DEBUG_DIAL_URL"],
              let url = URL(string: raw) else { return }
        fired = true
        // The host only: a stream URL's path or query can carry a key (the `windowTitle` rule).
        print("[DEBUG-DIAL] MANIFOLD_DEBUG_DIAL_URL set — dialling \(url.scheme ?? "?")://\(url.host ?? "?")/… in 2 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { dial(url) }
    }
}
#endif

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

    /// PER-WINDOW KEYBOARD TRANSPORT: the app's only `NSEvent` monitor. It owns timecode entry (the
    /// modal "type a position and land on it" state, and the type-to-enter capture that opens it)
    /// AND the ← / → / ⇧← / ⇧→ frame stepping — the two things in this app that must READ a
    /// keystroke rather than declare one. Owned here like `chrome`: an entry in one window must not
    /// seek another. See TimecodeEntry.swift for both reasons a key equivalent could not do it.
    @StateObject private var transportKeys = TransportKeyMonitor()

    /// PER-WINDOW watch on this deck's file: has it changed on disk since the engine last read it?
    /// Owned like `chrome` and for the same reason — two windows hold two different files and each
    /// watches its own. Read only by the reload button, which tints itself from it. See
    /// SourceFileWatcher for why this polls, and for why it never reloads on its own.
    @StateObject private var fileWatch = SourceFileWatcher()

    /// Unchanged in shape from the @AppStorage era — a computed read of the stored mode. Only the
    /// backing store moved, so every `isDocked` call site below is untouched.
    private var isDocked: Bool { chrome.isDocked }

    @State private var isScrubbing = false
    /// Whether THIS window holds an NDI discovery client (privacy P1). Taken when the NDI source
    /// list is first opened, released when the control that holds it leaves the screen. See
    /// `requestNDIDiscovery`.
    @State private var ndiDiscoveryHeld = false
    @State private var scrubValue: Double = 0
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
    /// though no file is loaded. Observed, so File ▸ Connect to First NDI Source / Disconnect Live Source update the UI.
    @ObservedObject private var ndi = NDIService.shared
    // WHEP's published connection state — feeds `hasSource` so the empty-state overlay hides while a
    // web stream drives the shared renderer, and drives the teardown scope-clear below.
    @ObservedObject private var whep = WHEPClient.shared
    // SRT's published connection state — same role as `whep` above: it feeds `hasSource`, drives
    // `activeLiveSource`, and surfaces a failed connect through the shared error banner.
    @ObservedObject private var srt = SRTClient.shared
    // HLS's published connection state — same role again. ⚠️ ONE OF THE THREE SITES ADDING A
    // `LiveSource` CASE DOES **NOT** BREAK THE BUILD (the others are `activeLiveSource` below and
    // `connectToStreamURL`'s `StreamType` switch). Omitting this line compiles perfectly and fails
    // silently at runtime: reading `HLSClient.shared` without observing it does not subscribe this
    // `body` to its `@Published` changes, so the view would render once and then never update —
    // the empty state would sit over live HLS video and the control bar would never appear. See
    // the warning on `LiveSource.isConnected`, which is the same trap stated from the other end.
    @ObservedObject private var hls = HLSClient.shared
    // Saved stream bookmarks — observed so the chevron and empty-state menus rebuild when the set
    // changes (empty ↔ non-empty flips the "Stream URL" item between a flat entry and a flyout).
    @ObservedObject private var bookmarks = StreamBookmarkStore.shared
    // Stream-bookmark manager sheet (chevron ▸ "Stream URL…" / "Manage…" and the empty-state menu).
    @State private var showStreamBookmarks = false
    // Diagnostics export prompt. Observed rather than @State because the menu item that raises it
    // lives in the App scene — see DiagnosticsExporter.
    @ObservedObject private var diagnostics = DiagnosticsExporter.shared
    /// The shortcut registry, for tooltips that name a key (`helpText`), so a rebound key is the one they name.
    private var keys: ShortcutRegistry { ShortcutCenter.shared.registry }
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
    // Persisted vectorscope graticule reference (written by the graticule shortcut, read here + by VectorscopeScopeView
    // via the same key). Overlay-only — no kernel push, so a toggle just redraws the boxes.
    @AppStorage("manifold.vectorscope.graticule") private var vectorscopeGraticule: VectorscopeGraticule = .fixed709
    // Persisted vectorscope target-box amplitude (75%/100%/both), cycled by the boxes shortcut, read here + by
    // VectorscopeScopeView via the same key. Overlay-only — a change just redraws the boxes.
    @AppStorage("manifold.vectorscope.boxAmplitude") private var vectorscopeBoxAmplitude: VectorscopeBoxAmplitude = .percent75
    // The four scope models (one each, rendered wherever its kind is selected — duplicates share
    // the single model). A model samples/computes only while its kind is in the active set.
    // Held through `ScopeModelStore`, NOT as `@StateObject`s here: see that type for why.
    @StateObject private var scopeModels = ScopeModelStore()
    private var waveformModel: WaveformScopeModel { scopeModels.waveform }
    private var paradeModel: ParadeScopeModel { scopeModels.parade }
    private var vectorscopeModel: VectorscopeScopeModel { scopeModels.vectorscope }
    private var cieModel: CIEScopeModel { scopeModels.cie }
    private var meterModel: AudioMeterModel { scopeModels.meter }
    /// The ONLY writer of the four models' source colour fields — from this window's renderer, for
    /// every source. Bound in `.onAppear`; see ScopeColorFeed.swift and CLAUDE.md.
    @StateObject private var scopeColorFeed = ScopeColorFeed()
    /// DeckLink output state (on/off + selected device) — shared singleton, observed so the toolbar
    /// control and File ▸ Start / Stop DeckLink Output always agree.
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
    /// mistake. Adding SRT was one more line here and one more case there; adding HLS was the same.
    ///
    /// ⚠️ AND THIS SITE IS AN IF-CHAIN, NOT A SWITCH, SO THE COMPILER DOES NOT ENFORCE IT. That is
    /// deliberate — it must read the `@ObservedObject` instances rather than `LiveSource`'s own
    /// `isConnected`, which is what makes `body` re-render — but it means a new case added to
    /// `LiveSource` compiles cleanly while never being reported here. Two other sites share that
    /// property: the `@ObservedObject` declaration above, and `connectToStreamURL`'s `StreamType`
    /// switch. All three are named in `LiveSource.hls`'s doc comment so the next transport finds
    /// them from the enumeration rather than by accident.
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
        if hls.isConnected { return .hls }
        return nil
    }

    var body: some View {
#if DEBUG
        let _ = ScopePerf.count("body.ContentView")
        let _ = MenuProbe.enabled ? Self._printChanges() : ()
#endif
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
        // ── NO HIDDEN SHORTCUT BUTTONS HERE ANY MORE ────────────────────────────────────────────
        //
        // I, N, ⌃⌥R, ⌃⌥E, the scope keys, the device-claim keys, the debug hooks and J/K/L were zero-opacity
        // `.background` Buttons on this chain. They are now the shortcut registry's (docs/SHORTCUTS_AUDIT.md §4.4):
        // this window registers what each action DOES in `installShortcutHandlers()` (called from `.onAppear`, so this
        // chain gains nothing), and `ShortcutCenter`'s one key monitor and the menus dispatch to it. The gates the
        // buttons carried through `.disabled` (MEASURED to suppress a key, docs/MULTIWINDOW_FINDINGS.md §3.1) are each
        // handler's `enabled` closure, with the same predicates: position for J/K/L and the arrows, device control for
        // DeckLink, NDI and the debug connects.
        .onContinuousHover { phase in
            if case .active = phase { wakeHUD() }
        }
        // ── WINDOW TITLE: NOT HERE ANY MORE, AND DELIBERATELY NOT ───────────────────────────
        //
        // This used to be `.onChange(of: deck.windowTitle, initial: true)`. It was wrong twice:
        // its first fire lands before this view is in a window, so `applyWindowTitle` had nowhere
        // to write and dropped it silently; and being edge-triggered on a derived string, it got
        // exactly one edge per load and never fired again to make up for the loss. The title was
        // then repaired only by the arbitration pass — reached from `didBecomeActive`, i.e. by the
        // user activating the app. The file-side trigger now lives in `DeckHostView`, whose
        // lifetime is the window's, so it cannot subscribe before there is somewhere to write.
        // See the note there. (This chain is also at the type-checker's limit, so a modifier that
        // does not need to be here should not be.)
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
                // A window closed between the open and this turn (or before SwiftUI delivered the URL at
                // all) must not be loaded into: its engine is stopped and nothing would ever stop it again.
                // MEASURED 2026-10-21: a window closed 0.1 s after `open` got this callback ~1 s later and
                // played the whole file with no window. See `WindowDeck.hasClosed`.
                guard !deck.hasClosed else {
                    NSLog("%@", "[OPEN] not loading \(url.lastPathComponent) — the window it was opened into has closed")
                    return
                }
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
                SessionPaths.note(url)   // for the diagnostics redactor (privacy P1)
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
            #if DEBUG
            DebugDial.fireOnce { url in connectToStreamURL(url) }
            #endif
            // The scope headers' source colour, from this window's renderer — BEFORE the sampling
            // below, which reseeds through it. Here and not as its own modifier (§6.7).
            scopeColorFeed.bind(deck: deck, waveform: waveformModel, parade: paradeModel,
                                vectorscope: vectorscopeModel, cie: cieModel)
            // Persisted arrangement may reopen the tray with scopes already on —
            // start their sampling to match the restored visibility.
            updateScopeSampling()
            // Timecode entry, and this window's shortcut actions (docs/SHORTCUTS_AUDIT.md §4.4). Here rather than
            // as their own `.onAppear` because this view's modifier chain is at the type-checker's limit — see the
            // note on the currentURL observer below. Both idempotent, so a second onAppear costs nothing.
            transportKeys.attach(deck: deck, engine: engine)
            installShortcutHandlers()
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
            RasterMenuState.shared.setNeedsRefresh()
            // Phase 2a (§6.4): the renderer starts in the same mode this window's chrome does, so
            // the two cannot be out of step before the first user action. `displayTransform` is
            // session-scoped and always `.os` at construction (see `WindowChrome`), which makes
            // this a no-op today — it is here so it stays true if that ever stops being the case.
            metalRenderer?.setDisplayTransform(chrome.displayTransform)
            DisplayTransformMenuState.shared.setNeedsRefresh()
        }
        .onDisappear {
            // Before the engine goes: a closed window must stop answering keystrokes, and its handlers (which hold
            // this view's objects) must not outlive it.
            transportKeys.detach()
            deck.shortcutHandlers = [:]
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
            RasterMenuState.shared.setNeedsRefresh()
        }
        // 2. THE PICTURE CHANGED SIZE. Refresh the text while the readout is up (so the numbers
        //    track a live drag), and RAISE it during a live resize even when the state did not
        //    change — a second drag of an already-`custom` window still deserves its dimensions.
        .onChange(of: drawnVideoSize) { _, _ in
            if rasterNotice != nil || (deck.window?.inLiveResize ?? false) { showRasterNotice() }
        }
        // 3. THE SOURCE CHANGED. A percentage is a percentage OF something; the View menu is dead
        //    until this window has a raster to take one of.
        //    Both menus that describe the key deck are re-derived here: a display transform is a
        //    transform OF something, so the Color menu is dead until this window has a picture,
        //    exactly as the View menu is. One trigger, because it is one event.
        .onChange(of: engine.displaySize) { _, _ in
            RasterMenuState.shared.setNeedsRefresh()
            DisplayTransformMenuState.shared.setNeedsRefresh()
        }
        // ⚠️ NO `.onChange(of: chrome.displayTransform)` HERE, AND THAT IS FORCED, NOT PREFERRED.
        // This chain is at the type-checker's limit (see the note in `.onAppear` below, and the
        // currentURL observer): adding one more modifier fails the build outright with "unable to
        // type-check this expression in reasonable time". So the forward to the renderer lives in
        // `DeckRegistry.setDisplayTransform`, which already holds both this window's chrome and
        // its renderer. READ THAT FUNCTION BEFORE ADDING A SECOND CONTROL SURFACE — it is the one
        // mutator, and a Phase 2b pulldown must call it rather than writing `chrome` directly.
        // A slot's selection changed → start newly-active scopes, stop ones that left the tray.
        .onChange(of: activeKinds) { _, _ in updateScopeSampling() }
        .onChange(of: engine.effectiveIsFullRange) { _, _ in
            // Range override changed: decode is unchanged (always 420v), so just
            // re-render the current frame with the new shader flag (covers paused).
            metalRenderer?.setNeedsRefresh()
            // …and the chain readout's Source line names the range, so it has to hear about it.
            // NO NEW MODIFIER — this is one more line inside an observer that already exists,
            // which is the only shape this file can afford (§6.7).
            metalRenderer?.sourceColorStateChanged()
        }
        .onChange(of: engine.metadata) { _, meta in
            // ⚠️ FIRST, AND UNRELATED TO THE COLORSPACE WORK BELOW — it is here because publishing
            // metadata is the honest "the engine has just READ the file" edge, and this chain
            // cannot afford another `.onChange` (see the currentURL observer further down for what
            // happens when it gets one). Re-baselining the changed-on-disk watch here is what makes
            // re-opening the file the deck ALREADY has clear the reload button's highlight: that
            // path assigns `currentURL` the value it already held, so the URL observer never fires.
            // It cannot defeat the feature — nothing but a read publishes metadata, so an external
            // rewrite still lights the button.
            fileWatch.rebaseline()
            // Derive the Metal layer colorspace once per source from the
            // inspector's authoritative color tags (not per-frame from buffers).
            if let meta {
                // Through the window's file override (colour S5), as the engine's own tag edge is in
                // `WindowDeck`: on Auto the same `.fromCodes` call as before, so the two still agree and
                // the readout does not flicker between tiers; with an override, the override stays.
                deck.fileColor.fileTags(primaries: meta.colorPrimariesCode,
                                        transfer: meta.transferFunctionCode,
                                        matrix: meta.colorMatrixCode,
                                        hdr10: meta.hdr10)
                // D5: the DeckLink Signal line from the new colour. Colour S7: the frames carry their own tag,
                // so nothing is re-tagged here.
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
                    // I2: and its scan, so an interlaced 1080 file goes out as 1080i with its fields intact.
                    DeckLinkService.shared.sourceFormatChanged(width: meta.width, height: meta.height,
                                                               pixelAspect: meta.pixelAspect.ratio,
                                                               frameRate: meta.frameRate,
                                                               scan: .init(interlaced: meta.isInterlaced,
                                                                           bottomFieldFirst: meta.isBottomFieldFirst,
                                                                           fieldOrderStated: meta.isFieldOrderStated,
                                                                           picturesAreFields: meta.interlacedPicturesAreFields))
                }
            }
            // ⚠️ NO SCOPE COLOUR HERE ANY MORE. The scope headers read the RENDERER, through
            // `ScopeColorFeed`, which the `setSourceColorSpace` call above already reaches. This
            // block used to write them from the file's metadata, which is why they kept a file's
            // PQ ruler over a WHEP stream (2026-10-06). See CLAUDE.md's source-colour rule.
        }
        // ⚠️ EVERY ONE OF THE THREE STREAM OBSERVERS BELOW IS GATED ON `drivesDevices`, because they
        // observe SINGLETONS and therefore fire in EVERY open window. Ungated, a stream connecting
        // or disconnecting in window A would call `clearScopes()` on window B, blanking the scopes
        // of a window that is quietly showing a paused file and has nothing to do with the stream.
        //
        // NONE OF THEM CARRIES SCOPE COLOUR. That used to be per transport — NDI's colour info and
        // SRT's colorimetry each had an `.onChange` here, WHEP and HLS had none, and nothing reset
        // them — and it is now `ScopeColorFeed`, from the renderer, for every source. Both of those
        // `.onChange`s were removed, not emptied: they did nothing else.
        .onChange(of: ndi.isConnected) { _, connected in
            guard deck.gate.drivesDevices else { return }
            if connected {
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
        // On connect, arm the auto-hide so the control surface reveals then settles, matching NDI.
        .onChange(of: whep.isConnected) { _, connected in
            guard deck.gate.drivesDevices else { return }
            if connected {
                armIdleIfNeeded()
            } else {
                clearScopes()
            }
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
        //
        // ⚠️ THE CHANGED-ON-DISK WATCH RIDES ALONG IN THIS SAME CLOSURE rather than taking an
        // `.onChange` of its own, and that is not tidiness: this `body` is one long modifier chain,
        // and a second observer on the same value pushed it past the Swift type-checker's
        // "unable to type-check this expression in reasonable time" threshold. Two statements in
        // one closure cost the checker nothing. The two hooks want the identical edge anyway — a
        // new file means new captions AND a new file to watch — and nil (empty deck, or a live
        // source) correctly stops the watch. Keyed on currentURL for the reason stated above:
        // media also arrives via ManifoldApp's .onOpenURL, which cannot reach this view's state.
        .onChange(of: engine.currentURL) { _, url in
            captions.clear()
            fileWatch.watch(url)
            // File ▸ Open Recent is recorded HERE and nowhere else, because this is the commit
            // edge: `currentURL` is assigned in `loadAsset`'s phase 2, so a file phase 1 refused
            // (a still, an R3D, anything with no readable video track) never reaches this line and
            // never enters the list. Noting at the open panel would have listed every refusal.
            // Streams cannot arrive here at all — they never call `load(url:)` — so there is no
            // guard for them; see the note on `RecentFiles.note`.
            if let url { RecentFiles.note(url) }
            // A load while an entry is open would leave the overlay holding the OLD file's frame
            // arithmetic — its rate, its start timecode, its last frame — and commit it against the
            // new one. The entry belonged to the file that just left.
            transportKeys.cancel()
            #if DEBUG
            DebugStepHook.run(engine: engine, renderer: metalRenderer)   // measurement only, env-gated
            #endif
        }
        // The watch's OTHER re-baseline — the one that covers re-opening the file this deck already
        // has — rides in the `engine.metadata` observer further up, for the same type-checker
        // reason. See the note there.
        .sheet(isPresented: $showStreamBookmarks) {
            StreamBookmarksSheet(store: .shared) { url, bookmark in
                // Same connect+takeover path the chevron rows use; then close the sheet so the async
                // result — a connect-error banner or live video — is visible in the main window.
                // `bookmark` is nil for "Connect without saving": a session-only audio offset.
                connectToStreamURL(url, name: bookmark?.name, bookmark: bookmark)
                showStreamBookmarks = false
            }
        }
        // Calibration mode (docs/AUDIO_RESAMPLER_DESIGN.md §19.10), opened from the A/V menu. A host
        // view with its own sheet, so this body does not grow (it is at the type-checker's limit).
        .background(CalibrationSheetHost(model: deck.calibration, offset: deck.audioOffset))
        // Help ▸ Export Diagnostics…. Hosted here because the menu command lives in the App
        // scene, which has no window to present on; the exporter singleton is the seam between them.
        .sheet(isPresented: $diagnostics.isPresenting) {
            DiagnosticsPromptSheet()
        }
        .sheet(isPresented: $showGetFlipSheet) {
            VStack(spacing: 16) {
                // Same mark as the control bar's Edit-in-Flip button, for the same reason — see
                // there. One glyph for one app, at both sizes.
                Image(systemName: "f.square")
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

    /// Is this a file the app should ACCEPT and try to open — which is a different question from
    /// whether it can play it, and the difference is the point.
    ///
    /// ⚠️ IMAGES ARE ACCEPTED HERE **SO THAT THEY CAN BE REFUSED PROPERLY**. That is not a
    /// contradiction, it is the fix. This predicate used to be `public.movie` alone, so dropping a
    /// PNG returned false and NOTHING HAPPENED — no message, no log, nothing to tell the user
    /// apart from a window that ignored them. Meanwhile an .r3d, which does conform to
    /// `public.movie`, was accepted and then refused by the engine with a message. Two ways of
    /// saying "no", one of them silent, chosen by a UTType hierarchy that knows nothing about what
    /// this app can decode.
    ///
    /// Letting images through means both land in the SAME place — `FrameEngine.loadAsset`, which
    /// empties the deck and raises the one banner — and each gets the sentence that is true of it:
    /// a still is named as a still, an unreadable video track is named as that. See the refusal in
    /// FrameEngine, which is also where the reason stills are banked is written down.
    ///
    /// Everything else (.pdf, .txt, a folder) is still declined here, silently, and that is
    /// UNCHANGED rather than endorsed: this widening is deliberately the smallest one that closes
    /// the reported case. A real capability filter — "what can this engine actually open", asked
    /// once, ahead of acceptance — is the fix for the general problem, and it is the work the drop
    /// commit already flags as needing to be BUILT rather than extended.
    private static func acceptsForLoad(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .image)
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
                //
                // ⚠️ THE ⌃⌥R A/B THAT HID METAL TO SHOW THIS LAYER IS GONE (2026-10-24, docs/SHORTCUTS_AUDIT.md §8
                // item 4). It served M4's tuning and the 2026-08-28 HDR decision (BUGS.md). Since then As macOS Shows
                // It is built to draw what this layer draws, so in the default mode the A/B showed no change ("does
                // nothing"), and in every mode it ignored the LUT, the tag override, the raster size and live sources
                // (this layer is fed by the file pump only): a comparison that could mislead. Hold C compares modes.
                SampleBufferSurfaceView { nsView in
                    Task { @MainActor in
                        engine.attach(renderer: nsView.displayLayer.sampleBufferRenderer)
                    }
                }
                if let renderer = metalRenderer {
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
            // Interlaced I4: the field-view marker, on the same picture-rect layer, so it stays with the picture in full
            // screen and with the controls hidden. Nothing in Weave or for a source that offers no field views (§14.8).
            .overlay(alignment: .topTrailing) { FieldViewMarker(chrome: chrome) }

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

        }
        .clipped()
        .overlay(alignment: .topTrailing) {
            if showInspector && engine.hasMedia {
                InspectorPanel(metadata: engine.metadata, engine: engine, chrome: chrome)
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
            guard let url = urls.first(where: Self.acceptsForLoad) else { return false }
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
        // TIMECODE ENTRY, CENTRED OVER THE PICTURE. On the video region and not on `body` for the
        // same reason the drop target is: the scopes tray is a sibling, and an entry overlay
        // centred over "the picture plus the waveforms" is centred over neither.
        .overlay { timecodeEntryLayer }
        .overlay(alignment: .topLeading) { rasterReadout }
        // The two top-edge notices, stacked so they can never overlap: the STANDING arbitration
        // message (a condition that persists until the user acts, in another window) above the
        // TRANSIENT connect-error banner (a thing that just happened, here). Both non-blocking.
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                arbitrationNotice
                connectErrorBanner
                deckLinkRefusalBanner
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
        case .meters:      AudioMeterScopeView(model: meterModel, slotSelection: selection)
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

        // The source colour the headers show comes from the RENDERER, never from `engine.metadata`.
        // This used to reseed each scope from the window's last FILE on every (re)start, so opening
        // the tray during a live stream put that file's colour over the stream's picture.
        scopeColorFeed.refresh()

        // Waveform / parade / vectorscope / CIE: plain start/stop.
        if active.contains(.waveform) {
            waveformModel.renderer = metalRenderer
            waveformModel.start()
        }
        else { waveformModel.stop() }
        if active.contains(.parade) {
            paradeModel.renderer = metalRenderer
            paradeModel.start()
        }
        else { paradeModel.stop() }
        if active.contains(.vectorscope) {
            vectorscopeModel.renderer = metalRenderer
            vectorscopeModel.start()
        }
        else { vectorscopeModel.stop() }
        if active.contains(.cie) {
            cieModel.renderer = metalRenderer
            cieModel.start()
        } else { cieModel.stop() }

        // ── METERS: the one scope gated on AUDIO work rather than GPU work ──────────────────
        //
        // start()/stop() add and remove a meter subscriber on the engine's audio tap, and the
        // tap's peak scan refuses to run at zero subscribers. So a tray with no meter slot costs
        // NOTHING — which is the whole point, because unlike the other four this samples
        // continuously rather than once per rendered frame.
        //
        // ⚠️ THE TAP ITSELF IS NOT SLEPT, AND MUST NOT BE. DeckLink's audio callback pulls from
        // the same ring; a tap that stopped ingesting would silence SDI output. What sleeps is
        // the peak scan, which is the only work metering adds.
        if active.contains(.meters) {
            meterModel.tap = engine.audioTap
            meterModel.playhead = { [weak engine] in engine?.currentTime ?? 0 }
            meterModel.isPlaying = { [weak engine] in engine?.isPlaying ?? false }
            meterModel.presence = { [weak engine] in engine?.audioPresence ?? .unknown }
            // Roles for the MONITORED track — the same index join the selector uses, and
            // bounds-guarded for the same reason: `metadata` lands after the decoder has already
            // sized the bars, so there is a real window where the engine has three tracks and the
            // inspector has none. Empty means "declared nothing", which is what the meter falls
            // back to numbers on.
            //
            // ── STAGE 3: THE TAP IS THE SECOND SOURCE, AND IT IS THE ONLY ONE A LIVE FEED HAS ──
            //
            // `metadata.audioTracks` is built from `AVAssetTrack`s. A live source has none — which
            // is why a 5.1 SRT feed metered as six bars numbered 1–6 even while the mux was
            // declaring the layout on every packet. The tap's format now carries the roles the
            // DECODER established (read off the CMSampleBuffer's AudioChannelLayout by the same
            // `AudioChannelLayoutBridge` the inspector uses), so this closure has somewhere to look
            // when there is no track list.
            //
            // ⚠️ THE TRACK LIST WINS WHERE IT EXISTS, AND THE ORDER IS NOT ARBITRARY. A file can
            // hold several audio tracks and the meters follow the SELECTED one; the tap only ever
            // holds the monitored track's format, so preferring the tap would be right by accident
            // for a single-track file and wrong the moment a second track was chosen. The tap is
            // the fallback, not the source of truth.
            //
            // ⚠️ AN EMPTY TAP ARRAY STAYS EMPTY. It means the source declared nothing usable, and
            // the meter's answer to that is channel NUMBERS — never a layout inferred from the
            // count. See `AudioTapBuffer.Format.roles`.
            meterModel.channelRoles = { [weak engine] in
                guard let engine else { return [] }
                // ⚠️ THE LIVE TEST COMES FIRST, AND IT IS NOT BELT-AND-BRACES. `engine.metadata`
                // describes the last FILE this deck opened and is not cleared when a stream takes
                // the picture over — so a deck that played a stereo file and then connected to a
                // 5.1 SRT feed would satisfy the track-list branch and label six live bars "L R"
                // from a file that is no longer on screen. Asking `LiveSource.connected` is the
                // same question `isLive` above asks, for the same reason, and it cannot be missed
                // by a fifth transport the way an enumeration can.
                if LiveSource.connected != nil { return engine.audioTap.format?.roles ?? [] }
                if let tracks = engine.metadata?.audioTracks,
                   tracks.indices.contains(engine.selectedAudioTrackIndex) {
                    return tracks[engine.selectedAudioTrackIndex].roles
                }
                // No track list and no live transport. NOT the ordinary libav path any more —
                // `applyLibavAudioTrack` fills a row per stream there, and the branch above is
                // what keeps a stream SWITCH relabelling the bars (row N is decoded stream N; see
                // `FrameEngine.selectedAudioTrackIndex`). This is the remainder: a libav file
                // whose rows never landed, whose roles — if its sample buffers carry a layout —
                // reach the tap and nowhere else.
                return engine.audioTap.format?.roles ?? []
            }
            // A live source has no playhead to key the ring against — see the note in
            // AudioMeterModel.tick.
            //
            // ⚠️ ASK "IS A LIVE TRANSPORT CONNECTED", DO NOT ENUMERATE THE TRANSPORTS. This was
            // `NDIService.shared.isConnected || WHEPClient.shared.isConnected`, and the enumeration
            // is exactly what broke: SRT gained a working audio path — 2.4 M frames reaching this
            // very tap — and the third term was never added, so the meters read NO SOURCE for a
            // whole session while the audio was decoding correctly. `LiveSource.connected` is the
            // question actually being asked, and a fourth transport cannot silently miss it.
            //
            // ⚠️ WHEP AND SRT ARE LIVE HERE EVEN THOUGH THEIR TAP PTS *WOULD* KEY AGAINST THE
            // PLAYHEAD. Live audio anchors the synchronizer to the live clock, so `currentTime`
            // and the tap's PTS share a timeline and a playhead-keyed read would find data. But the
            // playhead branch is gated on `isPlaying()`, which is false for a stream (no file is
            // loaded), so the meter would take the PAUSED branch and decay to silence over a stream
            // that is playing. Newest-keyed is both correct and simpler here.
            //
            // ⚠️ DO NOT "IMPROVE" THIS BY ALSO SETTING `audioPresence` ON THE LIVE TRANSPORTS THAT
            // LACK IT. It reads like the missing half and it is not. With `channels` empty and no
            // scan, `tick` leaves `status` at its initial `.noSource` — which is honest. Give it a
            // presence without giving it a scan and it takes
            // `status = isPlaying() || isLive() ? .metering : .paused` instead, so the panel shows
            // sized bars decaying to silence and reads PAUSED: a claim about the MATERIAL rather
            // than about our state, which is the one thing the "NEVER SILENT BARS" rule in
            // AudioMeterScope forbids. Presence is a refinement on top of a working scan (it sizes
            // the bars before the first buffer lands), never a substitute for one.
            meterModel.isLive = { LiveSource.connected != nil }
            // ⚠️ THE TRACK INDEX IS PART OF THE IDENTITY, NOT JUST THE URL. Switching tracks changes
            // the material the meter is describing as surely as opening a different file does, so a
            // clip latch earned on the mono track must not survive onto the 5.1 track — it would be
            // a claim about audio that is no longer being monitored. `resetForNewSource` is polled
            // off this string every tick (see AudioMeterModel.sourceIdentity), so appending the index
            // is the whole fix.
            meterModel.sourceIdentity = { [weak engine] in
                guard let engine else { return NDIService.shared.connectedSourceName }
                guard let url = engine.currentURL?.absoluteString else {
                    return NDIService.shared.connectedSourceName
                }
                return "\(url)#audio\(engine.selectedAudioTrackIndex)"
            }
            meterModel.start()
        } else { meterModel.stop() }

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

    // MARK: - Shortcut actions

    /// What this window does for each shortcut (docs/SHORTCUTS_AUDIT.md §4.4). The registry (`ShortcutCatalog`) says
    /// which key; `ShortcutCenter` sends menu picks and keys here, for this window only (the key window's deck, the
    /// scoping MULTIWINDOW_FINDINGS.md §3.1 measured for the hidden buttons these replace). Each `enabled` is the
    /// gate the old hidden button carried through `.disabled`, or the control bar's for the same action, so a key
    /// and its button never disagree. Closures read this view's state when they run, not when they are built.
    private func installShortcutHandlers() {
        // POSITION, not merely transport: J/K/L and the arrows move the playhead, and a live source has none.
        let position = { deck.gate.transportEnabled && deck.gate.positionControlsEnabled }
        let transport = { deck.gate.transportEnabled }
        // Device claims: they reach a singleton another window may hold, and silently stealing a broadcast output
        // is the worst outcome available here.
        let device = { deck.gate.deviceControlsEnabled }
        let playhead = { transportKeys.canMovePlayhead }
        let nudge = { (ms: Int) in
            DeckShortcut(enabled: { DeckRegistry.shared.liveLabel(for: deck) != nil }) { deck.audioOffset.nudge(byMs: ms) }
        }
        var handlers: [ShortcutID: DeckShortcut] = [
            // Transport
            .playPause: DeckShortcut(enabled: { hasSource && position() }) { engine.togglePlayPause() },
            .shuttleReverse: DeckShortcut(enabled: position) { engine.shuttleBackward() },
            .shuttlePause: DeckShortcut(enabled: position) { engine.shuttlePause() },
            .shuttleForward: DeckShortcut(enabled: position) { engine.shuttleForward() },
            .stepBackFrame: DeckShortcut(enabled: playhead) { engine.stepFrame(by: -1) },
            .stepForwardFrame: DeckShortcut(enabled: playhead) { engine.stepFrame(by: 1) },
            .stepBackSecond: DeckShortcut(enabled: playhead) { engine.stepFrame(by: -transportKeys.framesPerSecondStep) },
            .stepForwardSecond: DeckShortcut(enabled: playhead) { engine.stepFrame(by: transportKeys.framesPerSecondStep) },
            .goToStart: DeckShortcut(enabled: { playhead() && engine.hasMedia }) { transportKeys.goToEdge(end: false) },
            .goToEnd: DeckShortcut(enabled: { playhead() && engine.hasMedia }) { transportKeys.goToEdge(end: true) },
            .goToStartAlternate: DeckShortcut(enabled: { playhead() && engine.hasMedia }) { transportKeys.goToEdge(end: false) },
            .goToEndAlternate: DeckShortcut(enabled: { playhead() && engine.hasMedia }) { transportKeys.goToEdge(end: true) },
            .loop: DeckShortcut(enabled: { engine.hasMedia && position() }) { engine.toggleLoop() },
            // View
            .inspector: DeckShortcut { showInspector.toggle() },
            .fileName: DeckShortcut { showFileNameOverlay.toggle() },
            .alwaysShowControls: DeckShortcut(enabled: { hasSource && !isDocked }) { togglePin() },
            .exportFrame: DeckShortcut(enabled: { metalRenderer != nil }) { metalRenderer?.exportCurrentFrame() },
            // Help ▸ Export Frame for Support…: the diagnostic set through a save panel, on this window.
            .exportFrameForSupport: DeckShortcut(enabled: { metalRenderer != nil }) {
                metalRenderer?.exportFrameForSupport(window: deck.window)
            },
            // The readout hangs off the display-transform control, so the controls are woken to show it.
            .transformChain: DeckShortcut(enabled: { hasSource }) {
                if !chrome.showTransformChain { wakeHUD() }
                chrome.showTransformChain.toggle()
            },
            // Scopes. The CIE keys act on the CIE model wherever it sits (a no-op if it is in no slot).
            .scopesTray: DeckShortcut { chrome.showTray.toggle(); updateScopeSampling() },
            // u′v′ ↔ xy flips the renderer's kernel and the model's graticule together; setNeedsRefresh re-plots
            // the current frame, which covers a paused picture.
            .cieSpace: DeckShortcut {
                CIEScopeModel.applyMode(useUV: !cieUseUV, storage: $cieUseUV, renderer: metalRenderer)
            },
            .vectorscopeGraticule: DeckShortcut {
                vectorscopeGraticule = (vectorscopeGraticule == .fixed709) ? .sourcePrimaries : .fixed709
            },
            .vectorscopeBoxes: DeckShortcut {
                switch vectorscopeBoxAmplitude {
                case .percent75:  vectorscopeBoxAmplitude = .percent100
                case .percent100: vectorscopeBoxAmplitude = .both
                case .both:       vectorscopeBoxAmplitude = .percent75
                }
            },
            .cie709: DeckShortcut { cieShow709.toggle() },
            .cieP3: DeckShortcut { cieShowP3.toggle() },
            .cie2020: DeckShortcut { cieShow2020.toggle() },
            // Colour interpretation: the control bar's Color control, for whatever this window shows.
            .cycleInterpretation: DeckShortcut(enabled: device) { deck.cycleColorOverride(live: activeLiveSource) },
            .resetInterpretation: DeckShortcut(enabled: device) {
                if let live = activeLiveSource { deck.colorOverride.set(.auto, on: live) } else { deck.fileColor.reset() }
            },
            // Audio. The nudge acts only while this window shows a live source; otherwise ⌥[ / ⌥] go on (to a text
            // field, as “ and ‘), as they always have. Mute and volume are `transport`, as the fader is.
            .audioLater1: nudge(1), .audioEarlier1: nudge(-1), .audioLater10: nudge(10), .audioEarlier10: nudge(-10),
            // ±0.1 of the fader's 0–1 range, clamped by the engine, and kept as the fader keeps it.
            .mute: DeckShortcut(enabled: transport) { engine.toggleMute() },
            .volumeUp: DeckShortcut(enabled: transport) { stepVolume(0.1) },
            .volumeDown: DeckShortcut(enabled: transport) { stepVolume(-0.1) },
            // Sources and output: the SAME funnels as the toolbar controls, so a menu pick and a button never
            // disagree.
            .disconnectLive: DeckShortcut(enabled: { device() && DeckRegistry.shared.liveLabel(for: deck) != nil }) {
                DeckRegistry.shared.retireLiveIfOwned(by: deck)
            },
            // One toggle (⇧⌘D): stop when the card is outputting, else start.
            .toggleDeckLink: DeckShortcut(enabled: device) {
                if DeckLinkService.shared.isOutputting {
                    DeckRegistry.shared.stopDeckLinkOutput(from: deck)
                } else {
                    DeckRegistry.shared.startDeckLinkOutput(from: deck)
                }
            },
        ]
        #if DEBUG
        handlers.merge(debugShortcutHandlers(device: device)) { $1 }
        #endif
        deck.shortcutHandlers = handlers
    }

    #if DEBUG
    /// The debug hooks' actions. `#if DEBUG` only because the symbols they reach are DEBUG-only; WHETHER a hook
    /// answers is `ShortcutDebugGate`'s, the one predicate (Shortcuts/ShortcutCenter.swift). Its `.configDebug` tier —
    /// ⌃⌥L, ⌃⌥⇧L, ⌃⌥P, ⌃⌥U, ⌃⌥S, ⌃⌥[ and ⌃⌥], every hook that reaches a LiveClock setpoint mutator — is on only in
    /// the Debug configuration, never in Profile (docs/BUGS.md). The connects and retires carry the device-claim
    /// gate, as their hidden buttons did.
    private func debugShortcutHandlers(device: @escaping @MainActor () -> Bool) -> [ShortcutID: DeckShortcut] {
        [
            // ⌃⌥N, its key before the registry; a File menu item 2026-10-23 → 10-24.
            .debugNDIConnect: DeckShortcut(enabled: device) {
                DeckRegistry.shared.connectLive(.ndi, from: deck) { LiveSource.connectNDIFirstSource() }
            },
            // libdatachannel link smoke test: logs the version and a PeerConnection create/delete. No networking.
            .debugWebRTCSmoke: DeckShortcut(enabled: device) {
                var message: NSString?
                let ok = ManifoldWebRTCLinkSmokeTest(&message)
                let version = String(cString: ManifoldWebRTCVersion())
                NSLog("[WEBRTC-SMOKE] header version %@ | %@ | %@",
                      version, ok ? "PASS" : "FAIL", message ?? "no detail")
            },
            // WHEP: `MANIFOLD_STREAM_DEBUG_URL`, else `MANIFOLD_STREAM_DEBUG_BOOKMARK` (a saved stream of that name,
            // any type, cycling through a comma list), else the first saved web stream (docs/BUGS.md).
            .debugWHEPConnect: DeckShortcut(enabled: device) {
                if let override = ProcessInfo.processInfo.environment["MANIFOLD_STREAM_DEBUG_URL"]
                    .flatMap(URL.init(string:)) {
                    connectToStreamURL(override)   // unnamed: the title names its host
                } else if let names = ProcessInfo.processInfo.environment["MANIFOLD_STREAM_DEBUG_BOOKMARK"]?
                            .split(separator: ",").map(String.init),
                          let name = names.isEmpty ? nil : names[DebugBookmarkCursor.next() % names.count],
                          let bookmark = StreamBookmarkStore.shared.bookmarks.first(where: { $0.name == name }),
                          let url = StreamBookmarkStore.connectURL(for: bookmark) {
                    connectToStreamURL(url, name: bookmark.name, bookmark: bookmark)
                } else if let bookmark = StreamBookmarkStore.shared.firstConnectable(ofType: .web),
                   let url = StreamBookmarkStore.connectURL(for: bookmark) {
                    DeckRegistry.shared.connectLive(.web, from: deck, label: bookmark.name, bookmark: bookmark) {
                        LiveSource.connectWeb(to: url)
                    }
                } else {
                    NSLog("[WHEP] no saved stream — add one via the streaming menu ▸ Stream URL…")
                }
            },
            .debugWHEPRetire: DeckShortcut(enabled: device) { DeckRegistry.shared.retireLiveIfOwned(by: deck) },
            // The next decoded WHEP frame to a PNG: pre-render, the decoder-side check.
            .debugWHEPExportFrame: DeckShortcut(enabled: device) { WHEPClient.shared.exportNextDecodedFrame() },
            // SRT: `MANIFOLD_SRT_DEBUG_URL`, else the first saved SRT stream, else srt://127.0.0.1:9000.
            .debugSRTConnect: DeckShortcut(enabled: device) {
                let override = ProcessInfo.processInfo.environment["MANIFOLD_SRT_DEBUG_URL"]
                    .flatMap(URL.init(string:))
                let bookmark = override == nil ? StreamBookmarkStore.shared.firstConnectable(ofType: .srt) : nil
                let saved = bookmark.flatMap { StreamBookmarkStore.connectURL(for: $0) }
                let target = override ?? saved ?? Self.srtDebugTarget
                DeckRegistry.shared.connectLive(.srt, from: deck, label: bookmark?.name ?? Self.hostLabel(target),
                                                bookmark: bookmark) {
                    LiveSource.connectSRT(to: target)
                }
            },
            .debugSRTRetire: DeckShortcut(enabled: device) { DeckRegistry.shared.retireLiveIfOwned(by: deck) },
            // SyntheticLive (the live-clock harness): replays the LOADED file through the live path, with no
            // networking. ⌃⌥⇧L also aborts a running sweep, with a partial table.
            .debugSyntheticStart: DeckShortcut(enabled: device) {
                guard let url = engine.currentURL, let renderer = metalRenderer else {
                    NSLog("[SyntheticLive] load a file first — ⌃⌥L replays the loaded file through the live path")
                    return
                }
                SyntheticLiveSource.shared.start(url: url, renderer: renderer,
                                                 retireCurrentSource: { DeckRegistry.shared.liveStreamWillActivate() })
            },
            .debugSyntheticStop: DeckShortcut(enabled: device) { SyntheticLiveSource.shared.stop() },
            // ⌃⌥P mutates no clock (only driftRate / jitterAmplitude), but configures a harness nothing can start
            // outside the Debug configuration, so it is in that tier with the others.
            .debugSyntheticPreset: DeckShortcut(enabled: device) { SyntheticLiveSource.shared.cyclePreset() },
            .debugForceUnityRate: DeckShortcut(enabled: device) {
                let on = SyntheticLiveSource.shared.toggleForceUnityRate()
                SRTFrameRouter.shared.setForceUnityRate(on)
            },
            // The (targetDepth × jitter) grid, 24 cells × 15 s; a second ⌃⌥S aborts.
            .debugSyntheticSweep: DeckShortcut(enabled: device) {
                guard let url = engine.currentURL, let renderer = metalRenderer else {
                    NSLog("[SWEEP] load a file first — ⌃⌥S sweeps the loaded file through the live path")
                    return
                }
                SyntheticLiveSource.shared.startSweep(url: url, renderer: renderer,
                                                      retireCurrentSource: { DeckRegistry.shared.liveStreamWillActivate() })
            },
            // Step a live WHEP or SRT LiveClock target: the reason the Debug-configuration tier exists.
            .debugDepthDown: DeckShortcut(enabled: device) { stepLiveTargetDepth(by: -0.05) },
            .debugDepthUp: DeckShortcut(enabled: device) { stepLiveTargetDepth(by: 0.05) },
        ]
    }
    #endif

    /// ⌃⌥D's target. HARDCODED ON PURPOSE for this stage, exactly as the stage-2 spike's was: a
    /// URL-entry path here would be a second, parallel way to name a stream that then has to be
    /// kept in step with the shipping one (the bookmark sheet), and stage 3e is what makes the
    /// shipping one reach SRT. 127.0.0.1:9000 is what an `obs → SRT output` on this machine
    /// listens on by default.
    private static let srtDebugTarget = URL(string: "srt://127.0.0.1:9000")!

    /// Step the LIVE push source's LiveClock target. The two push transports keep their own
    /// routers (and their own measured cushions), so this asks which one owns the display rather
    /// than assuming. NDI and HLS are PULL sources with no LiveClock at all — there is nothing to
    /// step, and saying so beats silently doing nothing.
    ///
    /// ⚠️ THIS SITE WAS FOUND BY THE COMPILER WHEN `.hls` WAS ADDED, WHICH IS THE POINT OF THE
    /// ENUMERATION. It is not listed among the three hand-checked sites in `LiveSource.hls`'s doc
    /// comment precisely because it did not need to be: a non-exhaustive switch failed the build,
    /// which is the guarantee the hand-written pairwise chains could not give. Note the asymmetry
    /// worth keeping in mind — `case .ndi` and `case .hls` are spelled separately rather than
    /// folded together, so the message can name the transport the user actually has connected.
    private func stepLiveTargetDepth(by delta: Double) {
        switch activeLiveSource {
        case .web: WHEPFrameRouter.shared.adjustTargetDepth(by: delta)
        case .srt: SRTFrameRouter.shared.adjustTargetDepth(by: delta)
        case .ndi: NSLog("[LIVECLOCK] NDI is a pull source with no depth loop — ⌃⌥[ / ⌃⌥] do nothing")
        case .hls: NSLog("[LIVECLOCK] HLS is a pull source with no depth loop — ⌃⌥[ / ⌃⌥] do nothing. "
                       + "Its latency is segment-bound and set by the platform, not by us; see the "
                       + "[HLS] latency line for what it actually is")
        case nil:  NSLog("[LIVECLOCK] no live push source — ⌃⌥[ / ⌃⌥] adjust WHEP or SRT while connected")
        }
    }

    // MARK: - Audio track selection

    /// Short face/menu description of audio track `index` — "Stereo", "5.1 SMPTE", "6 ch".
    ///
    /// ⚠️ THE ENGINE OWNS THE COUNT, THE INSPECTOR OWNS THE DESCRIPTION, AND THEY ARE JOINED BY
    /// INDEX. On the AVFoundation path both enumerate `loadTracks(withMediaType: .audio)` on the
    /// same asset, which returns file order; on the libav path both come from the SAME
    /// `LibavAudioSource` stream enumeration (`FrameEngine.libavAudioInfo` for the count,
    /// `applyLibavAudioTrack`'s order-preserving `map` of it for the rows). Either way index N
    /// means the same track to both. The join is still bounds-guarded rather than assumed:
    /// `metadata` lands asynchronously on the AVFoundation path (`MediaInspector.metadata` is a
    /// detached Task), so there is a real window where the engine has three tracks and the
    /// inspector has none. In that window a plain track number is the honest answer, not a blank.
    private func audioTrackLabel(_ index: Int) -> String {
        guard let tracks = engine.metadata?.audioTracks, tracks.indices.contains(index) else {
            return "Track \(index + 1)"
        }
        let t = tracks[index]
        return t.layoutName == "—" ? (t.channelCount > 0 ? "\(t.channelCount) ch" : "Track \(index + 1)")
                                   : t.layoutName
    }

    /// The face text: which track is being monitored, readable WITHOUT opening the menu. Numbered
    /// only when there is more than one — "1 · Stereo" on a single-track file would imply a choice
    /// that isn't there.
    private var audioTrackFaceLabel: String {
        let n = engine.audioTrackCount
        // ⚠️ ZERO SELECTABLE TRACKS IS NOT THE SAME QUESTION AS "NO AUDIO", and conflating them
        // reads as a bug on every push source. `audioTrackCount` is 0 for WHEP even while audio is
        // decoding and the meters are moving. Saying "No audio" there contradicts the meters
        // standing next to it.
        //
        // ⚠️ THIS FALLBACK IS NOT DEAD NOW THAT THE libav PATH REPORTS A COUNT. Its purpose is the
        // paths that never get one, and WHEP is still one of them — it has no track list, no
        // stream enumeration, and nothing but `audioPresence` to say what it decoded. Deleting it
        // would put "No audio" under moving meters on every live source.
        //
        // So when there is no track LIST, defer to what actually decoded. `.absent` is the only
        // state that earns "No audio" — it is set positively, either by a video-only file or by a
        // server declining the m-section. `.unknown` keeps the old wording: nothing is loaded yet,
        // and a source that never establishes audio should not be announced as having it.
        guard n > 0 else {
            if case .present(let ch) = engine.audioPresence {
                return ch == 1 ? "Mono" : (ch == 2 ? "Stereo" : "\(ch) ch")
            }
            return "No audio"
        }
        let sel = engine.selectedAudioTrackIndex
        return n == 1 ? audioTrackLabel(0) : "\(sel + 1) · \(audioTrackLabel(sel))"
    }

    private var audioTrackBinding: Binding<Int> {
        Binding(get: { engine.selectedAudioTrackIndex },
                set: { engine.selectAudioTrack($0) })
    }

    /// Audio track — which of the file's audio tracks is MONITORED. Split face (readout + lone
    /// chevron) mirroring `ColorInterpretationControl` (LiveColorOverride.swift); see the note there on why the chevron must be its own
    /// Menu label rather than a trailing element.
    ///
    /// ── SHOWN DISABLED RATHER THAN HIDDEN WHEN THERE IS NO CHOICE ─────────────────────────────
    ///
    /// One audio track is a FACT about the file worth reading at a glance, and a control that
    /// appears and disappears as you move between files is harder to learn than one that is
    /// consistently present and sometimes inert. So a single-track file shows the control, disabled,
    /// stating that track's layout; a video-only file shows "No audio". Neither is a dead end the
    /// user has to go looking for.
    ///
    /// ⚠️ THE libav (MXF / DNxHR) PATH NOW REPORTS A COUNT OF ITS OWN — `FrameEngine` keeps the
    /// stream enumeration `LibavAudioSource.open()` produced and `audioTrackCount` reads it there,
    /// so a four-stream MXF offers four. It is still NOT `audioTracks.count`: that is an
    /// `AVAssetTrack` list and AVFoundation cannot open MXF at all.
    ///
    /// ⚠️ A LIVE SOURCE STILL REPORTS ZERO, and the control still falls back to the
    /// presence-derived single-track presentation there. That remains honest for the same reason
    /// it always was: we cannot offer a choice we cannot honour.
    private var audioTrackControl: some View {
        let n = engine.audioTrackCount
        // Nothing to switch between: one track, or a path that can't offer the choice.
        let inert = n < 2
        return HStack(spacing: 2) {
            Menu {
                audioTrackMenuContent
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                    Text(audioTrackFaceLabel)
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(inert)

            Menu {
                audioTrackMenuContent
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(inert)
        }
        .foregroundStyle(.white.opacity(inert ? 0.35 : 0.9))
        .help(audioTrackHelp)
    }

    private var audioTrackHelp: String {
        switch engine.audioTrackCount {
        case 0:
            // Same distinction as the face label: "cannot offer a choice" and "there is nothing to
            // choose between" are different facts and the tooltip is where the difference fits.
            if case .present(let ch) = engine.audioPresence {
                return "Audio track — this source decodes \(ch) channel(s) and offers no track selection"
            }
            return "Audio track — this source offers no track selection"
        case 1:  return "Audio track — this file has one: \(audioTrackLabel(0))"
        default: return "Audio track — which track you are monitoring (speakers, meters and SDI all follow)"
        }
    }

    @ViewBuilder
    private var audioTrackMenuContent: some View {
        // ⚠️ NO ENCLOSING `Section` — an inline Picker RENDERS ITS OWN LABEL as the group header,
        // so wrapping it in a Section titled the same thing prints the title twice.
        Picker("Monitored audio track", selection: audioTrackBinding) {
            ForEach(0..<max(engine.audioTrackCount, 1), id: \.self) { i in
                Text("\(i + 1) · \(audioTrackLabel(i))").tag(i)
            }
        }
        .pickerStyle(.inline)
        // State the reach of the choice INSIDE the control that makes it. "Which track am I
        // hearing" and "which track is on the wire" being the same answer is the whole point of
        // putting this with the output controls rather than in a scope — so say so where the
        // decision is made, not only in a release note.
        Section {
            Button("Speakers, meters and SDI all follow this track") {}.disabled(true)
        }
    }

    /// Route the device picker through selectDevice (which cleanly stop/restarts if output is ON).
    private var deckLinkDeviceBinding: Binding<Int> {
        Binding(get: { deckLink.selectedDeviceIndex },
                set: { DeckLinkService.shared.selectDevice($0) })
    }

    /// The output-mode picker. `nil` tag = "Follow source"; a mode tag = the operator's pick, which
    /// wins until they clear it. Routed through `setManualMode` so the picker, persistence and the
    /// re-establish decision cannot diverge — the same discipline as the device and destination
    /// pickers beside it.
    private var deckLinkModeBinding: Binding<String> {
        Binding(get: {
                    let service = DeckLinkService.shared
                    if let manual = service.manualMode { return manual.id }
                    if service.followSourceAvailable { return Self.followSourceTag }
                    // ⚠️ NO MANUAL PICK AND NOTHING TO FOLLOW — AND THIS USED TO RETURN THE FOLLOW
                    // TAG ANYWAY. That drew a checkmark against "Follow source — unavailable": a row
                    // whose own subtitle told the operator to pick something else was rendered as
                    // the thing they had already picked, while `applyEffectiveMode` quietly fell
                    // through to `.default2160p2398` (or whatever a restored preference had left in
                    // `currentMode`) — 2160p23.98 against a 1080 source, a black wire under a
                    // checkmark that said everything was fine.
                    //
                    // Naming `currentMode` makes the selection TRUE: it is the mode the card is on.
                    // It is not a pin — `manualMode` stays nil — so the moment the source states a
                    // rate (or a file is loaded), the selection returns to Follow source on its own.
                    // That reversibility is the load-bearing part: HLS publishes its raster long
                    // before its measured rate, so pinning here would permanently disable
                    // follow-source on the transport that needs it most.
                    return service.currentMode.id
                },
                set: { tag in
                    DeckLinkService.shared.setManualMode(
                        tag == Self.followSourceTag
                            ? nil
                            : DeckLinkService.shared.pickerModes.first { $0.id == tag })
                })
    }
    /// Sentinel tag for the "Follow source" row. A `Picker` over `OutputMode?` would need the
    /// optional to be Hashable and tagged nil, which SwiftUI handles badly; a String tag is the
    /// plain thing that works, and `OutputMode.id` is already a String.
    private static let followSourceTag = "__follow_source__"

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
        // Named first: inline, the `??` chain below no longer type-checks in reasonable time.
        let stopHelp: String = keys.helpText("click to stop", .toggleDeckLink)
        let onOffHelp: String = deckLink.isOutputting ? "DeckLink output ON — " + stopHelp
                                                      : "DeckLink output — " + keys.helpText("click to start", .toggleDeckLink)
        let placedHelp: String? = deckLink.isOutputting
            ? deckLink.placementLine.map { "DeckLink output ON — \($0) — " + stopHelp } : nil
        return HStack(spacing: 2) {
            Button { DeckRegistry.shared.toggleDeckLinkOutput(from: deck) } label: {
                Image(systemName: deckLink.isOutputting ? "tv.fill" : "tv")
            }
            .disabled(blocked)
            .foregroundStyle(deckLink.isOutputting && !arbitrated ? Color.green
                             : .white.opacity(blocked ? 0.35 : 0.9))
            .help((arbitrated ? deck.gate.reason : nil)
                  ?? (blocked ? status.blockedReason : nil)
                  // A mismatch means the card is ON and the picture is BLACK — the one state where
                  // the green tv.fill icon is actively misleading, so it is said in the tooltip
                  // rather than only inside the menu.
                  ?? deckLink.rasterMismatch
                  // A refused start (another app holds the card): output is off, and the button says why.
                  ?? (deckLink.isOutputting ? nil : deckLink.startRefusal)
                  // SDI scaling (D8): a placed or scaled picture is said here too, so the green icon is never
                  // taken for a native 1:1 output.
                  ?? placedHelp
                  ?? onOffHelp)

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
                // THE OUTPUT MODE. Above Signal deliberately: Signal READS the mode, so the control
                // that sets it belongs before the readout, and a mismatch warning shown in Signal is
                // then immediately above the picker that fixes it.
                Section("Output mode") {
                    // STILL SHOWN WHEN UNAVAILABLE, STILL NOT A PICKER OPTION. Greyed rather than
                    // hidden for the original reason — "Follow source" vanishing whenever a source
                    // cannot state a rate would read as a missing feature, and present-and-explained
                    // is the honest shape, with the reason directly beneath it.
                    //
                    // But it is a DISABLED BUTTON and no longer a tagged row inside the Picker,
                    // because a tagged row is selectable and, worse, gets the checkmark whenever the
                    // binding has nothing else to name. A Button cannot be checked and cannot be
                    // chosen, which is half the fix; `deckLinkModeBinding` — which now names the
                    // mode actually in force instead of this row — is the other half.
                    if !deckLink.followSourceAvailable {
                        Button("Follow source — unavailable") {}.disabled(true)
                    }
                    Picker("Output mode", selection: deckLinkModeBinding) {
                        if deckLink.followSourceAvailable {
                            Text("Follow source (\(deckLink.sourceDerivedMode?.label ?? ""))")
                                .tag(Self.followSourceTag)
                        }
                        // SDI scaling follow-up F3: 2160p, 1080p and 720p at every rate the card offers each, then 2K
                        // and 4K DCI only while Settings ▸ SDI output modes is Include DCI. Interlaced I2: 1080i50,
                        // 1080i59.94 and 1080i60 after the 1080p rows.
                        ForEach(deckLink.pickerModes, id: \.id) { mode in
                            Text(mode.label).tag(mode.id)
                        }
                    }
                    .pickerStyle(.inline)
                    if let reason = deckLink.followSourceUnavailableReason {
                        Button(reason) {}.disabled(true)
                    }
                }
                Section("Signal") {
                    // `signalLineOrWarning`, not `signalLine`: a healthy-looking mode/format/
                    // colorspace reading is a FALSE statement while the renderer is refusing the
                    // copy and the wire is carrying black. See DeckLinkService.rasterMismatch.
                    Button(deckLink.signalLineOrWarning) {}.disabled(true)
                    // SDI scaling (D8): the picture is not the source 1:1 at its own raster — placed with black
                    // around it, or scaled. Stated whenever it is so, never silent.
                    if let placed = deckLink.placementLine, deckLink.rasterMismatch == nil {
                        Button(placed) {}.disabled(true)
                    }
                    // Colour S7-3: the HDR static metadata a PQ signal sends, and whether it is the defaults. HDMI
                    // only: SDI carries colorimetry and transfer (D6).
                    if let hdr = deckLink.hdrMetadataLine, deckLink.rasterMismatch == nil {
                        Button("HDMI: \(hdr)") {}.disabled(true)
                    }
                    // AN ADDITIONAL ROW, NOT A REPLACEMENT. A raster mismatch says the wire is
                    // black; an advisory says the wire is fine and the SOURCE is not what it
                    // claims. Both can be true at once and they are different problems, so the
                    // advisory sits beside the signal line rather than overwriting it the way the
                    // mismatch does. See DeckLinkService.sourceAdvisory.
                    if let advisory = deckLink.sourceAdvisory {
                        Button("⚠️ \(advisory)") {}.disabled(true)
                    }
                }
                // A below-floor driver enumerates devices perfectly well, so the picker above can look
                // healthy while output is impossible. State the reason where the picker is.
                if let reason = status.blockedReason, !deckLink.devices.isEmpty {
                    Section("Unavailable") {
                        Button(reason) {}.disabled(true)
                    }
                }
                // The last start was refused with a message (another app holds the card). Output is off until the
                // user starts it again; see DeckLinkService.startRefusal.
                if let refusal = deckLink.startRefusal, !deckLink.isOutputting {
                    Section("Not started") {
                        Button("⚠️ \(refusal)") {}.disabled(true)
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
    /// available, not as a disabled/off look. Discovery starts the first time the NDI source list
    /// is opened (privacy P1 — never merely because this control is on screen), and is released
    /// when the control leaves the screen.
    private var streamingControl: some View {
        // Same rule as the DeckLink control: a non-owning deck may neither connect a stream nor
        // disconnect somebody else's. `activeLiveSource` is ownership-scoped, so the lit-green
        // state and the "click to stop" copy describe THIS window's stream, never another's.
        let arbitrated = !deck.gate.deviceControlsEnabled
        // GREEN EXACTLY WHILE THIS WINDOW'S LIVE SOURCE IS CONNECTED, whichever transport (green = live; Robbie,
        // 2026-10-27). Was `== .ndi`, so an SRT, WHEP or HLS stream never lit it (checklist item 2). `activeLiveSource`
        // is the same predicate `hasSource` and the Disconnect item use: connected, and this window's.
        let mine = activeLiveSource != nil
        return HStack(spacing: 2) {
            Button { toggleStreaming() } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
            }
            .foregroundStyle(mine ? Color.green : .white.opacity(arbitrated ? 0.35 : 0.9))
            .help(arbitrated ? (deck.gate.reason ?? "Streaming is in another window")
                  : mine
                  ? "Streaming — \(DeckRegistry.shared.liveLabel(for: deck) ?? activeLiveSource?.displayLabel ?? "live") — "
                    + keys.helpText("click to stop", .disconnectLive)
                  : "Streaming — local mode; click to connect the first NDI source, or use the menu to pick")

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
        .onReceive(NotificationCenter.default.publisher(for: NDIMenuOpenWatcher.ndiSubmenuWillOpen)) { _ in
            // The menu belongs to the key window; other windows ignore it (privacy P1).
            if deck.window?.isKeyWindow == true { requestNDIDiscovery() }
        }
        .onDisappear { releaseNDIDiscovery() }
    }

    /// Caption control — a split-button mirroring `streamingControl` / `deckLinkOutputControl`. The
    /// main button toggles the caption overlay, or opens the picker on the first click when nothing
    /// is loaded yet (an Aa that does nothing until you've found a hidden menu item reads as broken).
    /// The chevron loads/replaces/clears the sidecar and picks the position preset. Lit green while
    /// captions are showing, same on/off language as loop and the scopes tray.
    ///
    /// The chevron MUST stay the LONE element of the Menu's label — see the note on `ColorInterpretationControl` (LiveColorOverride.swift):
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
            .foregroundStyle(captions.enabled ? Color.appYellow : .white.opacity(0.9))
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
    ///
    /// ⚠️ OPENING THE "NDI" SUBMENU THAT HOLDS THIS LIST IS WHAT STARTS NDI DISCOVERY (privacy P1).
    /// Nothing else in the window does: not the empty state or the control bar appearing, and not
    /// the PARENT menu opening. Before P1 both views started it on `.onAppear`, so a launch with the
    /// NDI runtime installed put mDNS queries on the network — and, on macOS 15, raised the
    /// local-network prompt — before anyone had touched NDI. The signal is
    /// `NDIMenuOpenWatcher.ndiSubmenuWillOpen`, answered in `body`; NOT `.onAppear` here, which
    /// SwiftUI fires when the parent menu opens (measured). Connecting to a source (File ▸ Connect to First NDI Source, the
    /// streaming button) still discovers on its own.
    @ViewBuilder private var ndiSourceListItems: some View {
        Group {
            if ndi.discoveredSources.isEmpty {
                // Distinguish "runtime absent" from "runtime present, no sources yet" — the former
                // must NOT read as a search in progress.
                //
                // ⚠️ NO `NDIBridge.loadRuntime()` IN HERE (privacy P1). SwiftUI composes a Menu's
                // content when the window is built, NOT when the menu opens, so a load here ran at
                // every launch: measured, `libndi.dylib` mapped and `NDIlib_initialize` called before
                // anyone touched NDI. The launch probe (`runtimePresence`, a file stat, no dlopen)
                // answers "not installed"; a runtime that is present but will not load is known only
                // once discovery has tried, which `requestNDIDiscovery` does on opening.
                if ndi.runtimePresence == .notInstalled
                    || (ndiDiscoveryHeld && !ndi.runtimeAvailable) {
                    Button("NDI runtime not installed — install it in Settings (⌘,) and relaunch.") {}
                        .disabled(true)
                } else {
                    // SEARCHING UNTIL A SOURCE APPEARS, not "No NDI sources found": the list is
                    // composed as it opens, and on the first opening discovery has only just been
                    // asked for, so "none found" would be a verdict nobody has reached.
                    Button("Searching for NDI sources…") {}.disabled(true)
                }
            } else {
                ndiSourceRows
            }
        }
        // ⚠️ NOT THE TRIGGER — THE SAFETY NET. SwiftUI composes this as its menu opens (the empty state's
        // parent; the control bar's NDI flyout), so `.onAppear` here is the moment to ask whether that menu
        // is being watched. If it is not, discovery starts now rather than never. But it fires at other
        // moments too, with no menu open (measured 2026-10-29: the window becoming key after a flyout was
        // opened in it unkeyed), and those must start nothing. See `NDIMenuOpenWatcher.fallbackNeeded`.
        .onAppear { checkNDISubmenuIsWatched() }
    }

    @ViewBuilder private var ndiSourceRows: some View {
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
                        connectToStreamURL(url, name: bookmark.name, bookmark: bookmark)
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

    /// What an unnamed stream is called in the window title: its URL's host ("127.0.0.1",
    /// "customer-x.cloudflarestream.com"), or nil (then the transport's name). Only the host: a path or query can
    /// carry a stream key or passphrase, and the title reaches the Window menu, Mission Control and screenshots.
    static func hostLabel(_ url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return host
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
    ///
    /// ⚠️ THE THIRD SITE A NEW `LiveSource` CASE DOES NOT BREAK. This switches over `StreamType`,
    /// not over `LiveSource`, so the two enumerations are related only by this function — adding
    /// `.hls` to `LiveSource` left this arm compiling with its old refusal in place, and it had to
    /// be replaced by hand. The refusal it replaced (`NSLog("… not supported in this build")`)
    /// existed precisely because `isSupported` excluded HLS; both changed in the same pass, and
    /// they have to.
    /// `bookmark`: the saved stream, when the connect came from one — its audio offset starts the
    /// session (docs/AUDIO_RESAMPLER_DESIGN.md §19.8). nil = a session value only.
    private func connectToStreamURL(_ url: URL, name: String? = nil, bookmark: StreamBookmark? = nil) {
        // The window's name for this stream: the bookmark's, else the URL's HOST — never the URL, whose path or
        // query can carry a stream key or passphrase (the `windowTitle` rule).
        let name = (name?.isEmpty == false ? name : nil) ?? Self.hostLabel(url)
        switch StreamType.detect(url) {
        case .web:
            DeckRegistry.shared.connectLive(.web, from: deck, label: name, bookmark: bookmark) {
                LiveSource.connectWeb(to: url)
            }
        case .srt:
            DeckRegistry.shared.connectLive(.srt, from: deck, label: name, bookmark: bookmark) {
                LiveSource.connectSRT(to: url)
            }
        case .hls:
            DeckRegistry.shared.connectLive(.hls, from: deck, label: name, bookmark: bookmark) {
                LiveSource.connectHLS(to: url)
            }
        }
    }

    /// Non-blocking error banner for a failed stream connect — the presentation for BOTH the menu
    /// path (no modal open) and the sheet path (which closes on connect, so the async failure lands
    /// here). Shows the TRANSPORT'S own message where there is one (Cloudflare's "Live broadcast not
    /// started yet" on a 409; libsrt's reject reason on a bad passphrase), else a clear generic —
    /// and never a full URL, never a passphrase. Auto-dismisses; the close button or a new attempt
    /// clears it sooner. Never blocks: the user can pick another bookmark or open a file immediately.
    ///
    /// ONE BANNER FOR EVERY TRANSPORT. They cannot all be connecting at once — `LiveSource` is what
    /// guarantees that — so there is at most one message to show, and the order is age, not
    /// priority: WHEP, then SRT, then HLS. ALL are cleared on dismissal so a stale message from
    /// another transport cannot re-appear behind this one. (NDI publishes no `lastError`; its
    /// failures are log-only, which is why it is absent here and `break`s in `clearBanner`.)
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
    /// hls.lastError ?? engine.playbackNotice` slot works ONLY because those are mutually
    /// exclusive — an
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

    /// A refused DeckLink output start that has a message (`DeckLinkService.startRefusal`: another app holds the card).
    ///
    /// ITS OWN BANNER, NOT A TERM ON `connectErrorBanner`: that one's single `??` slot holds only mutually exclusive
    /// messages, and a window can fail a connect and have its output refused at once. No timer: output stays off until
    /// the user starts it again, so the message stays until then or until it is closed. Shown only in a window that may
    /// drive the card.
    @ViewBuilder private var deckLinkRefusalBanner: some View {
        if let message = deckLink.startRefusal, !deckLink.isOutputting, deck.gate.deviceControlsEnabled {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    DeckLinkService.shared.clearStartRefusal()
                } label: {
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
        }
    }

    @ViewBuilder private var connectErrorBanner: some View {
        if let message = whep.lastError ?? srt.lastError ?? hls.lastError ?? engine.playbackNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    whep.clearError(); srt.clearError(); hls.clearError()
                    engine.playbackNotice = nil
                } label: {
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

    /// The streaming button's main-click action (and File ▸ Connect to First NDI Source / Disconnect Live Source funnel through the same
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

    private func controls(showPin: Bool) -> some View {
        // ONE DECK PLAYS AT A TIME, so everything that moves the transport is gated on this deck
        // being the active one. The set is the scrubber, play/pause + Space, mute, the volume
        // fader and loop; J/K/L and the arrow jog are gated in their shortcut handlers (`installShortcutHandlers`).
        //
        // MUTE AND VOLUME ARE DISABLED, NOT HIDDEN, and for two reasons. A paused engine is silent
        // by construction, so the fader has nothing to act on; and leaving it live lets a window
        // that cannot play mutate the app-wide stored default (the slider writes
        // `Preferences.shared.playbackVolume`, which seeds every window opened afterwards). That
        // second reason is why the gate — not a removal of the write — is the right fix: the pref
        // is still the seed a user sets by moving the fader, and only the deck that may actually
        // play can move it now.
        let transport = deck.gate.transportEnabled
        // POSITION vs TRANSPORT — two gates, and the split is the point. `transport` is "is this
        // the active deck"; `position` is "is there a playback position at all". A live source
        // fails the second and passes the first, and mute/volume must survive that (see DeckGate).
        let position = transport && deck.gate.positionControlsEnabled
        // One sentence for every position control's tooltip, so a greyed play button and a greyed
        // scrubber never disagree about why. In the STANDING case this is the arbiter's message,
        // which already names the owning window's file (`DeckRegistry.standingMessage` →
        // `WindowDeck.displayName`, with "another window" as the honest fallback) — so the tooltip
        // tells the user where to go, and no second string has to be invented here.
        let positionWhy = deck.gate.positionReason ?? deck.gate.reason
        // ── GREY IS PART OF THE GATE, NOT DECORATION ──────────────────────────────────────────
        //
        // ⚠️ `.disabled` ALONE DOES NOT GREY ANYTHING IN THIS ROW. The HStack below sets an
        // explicit `.foregroundStyle(.white.opacity(0.9))`, and an explicit foreground style is
        // what a `.plain` button's label is drawn with whether or not it is enabled. So a disabled
        // play button here renders at FULL BRIGHTNESS and simply stops responding — which is the
        // "looks enabled, does nothing" reading the gate exists to prevent, and is the worse half
        // of it: an inert control that looks live reads as broken software, where a greyed one
        // reads as inapplicable.
        //
        // `deckLinkOutputControl` already meets this and already solves it the same way — it sets
        // its own foreground style (it has a green ON state), so it computes `0.35` for its
        // blocked case by hand. Same value here, so a greyed transport control and a greyed device
        // control are the same grey.
        //
        // ONLY THE POSITION CONTROLS. Mute and the volume fader take `transport`, not `position`,
        // and keep their own brightness for the reason stated at the fader below.
        let live = Color.white.opacity(0.9)
        let dim = Color.white.opacity(0.35)
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
                    // ⚠️ THE LEADING READOUT NO LONGER CYCLES THE MODE — IT OPENS TIMECODE ENTRY.
                    // The settled design says clicking the timecode display is one of the two ways
                    // in, and this is the timecode display: it is the PLAYHEAD, which is the only
                    // number on this bar you can be taken to. Mode cycling did not go anywhere — the
                    // trailing readout still carries it, and it cycles both, so the pair behaves
                    // exactly as before for anyone who reaches for the other end.
                    // Opens timecode entry, which exists to SEEK — so it is a position control and
                    // carries the position gate. `TransportKeyMonitor.begin` guards on the same
                    // condition for the type-to-enter route; this is the click route.
                    .onTapGesture { if position { transportKeys.begin() } }
                    // A pointer cue, because a click target that looks like a label is a click
                    // target nobody finds — AND ONLY WHILE IT IS ONE. A pointing hand over a gated
                    // readout promises a click that `position` will refuse, which is the same lie
                    // the ungreyed play button was telling.
                    .onHover { inside in
                        if inside && position { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    // NOT DIMMED, unlike the buttons: this is a READOUT first and a click target
                    // second, and the playhead it shows is still true in a gated window — greying
                    // the number would cost information to make a point about a click. The tooltip
                    // is what carries the point.
                    .help(position ? "Go to timecode — click, or type a number"
                                   : (positionWhy ?? ""))

                // THE PLAYHEAD. A `TransportScrubber`, not a `Slider`, so it can draw the playhead
                // as a Ball or a Line (Settings ▸ Playback). Same contract as the Slider it
                // replaced — the value, the per-move setter, the editing bracket below are unchanged —
                // and the Ball is that Slider's knob, byte for byte. See TransportScrubber.
                TransportScrubber(
                    value: isScrubbing ? scrubValue : engine.currentTime,
                    range: 0...max(engine.duration, 0.1),
                    onChange: { newValue in
                        scrubValue = newValue
                        engine.scrubSeek(to: newValue)
                    },
                    onEditingChanged: { editing in
                        if editing {
                            #if DEBUG
                            // The v210 baseline for the interval BEFORE the drag, so the line
                            // printed at release has something to be read against. Silent unless
                            // DeckLink output is running.
                            metalRenderer?.debugFlushV210Stats(label: "before-drag")
                            #endif
                            wasPlayingBeforeScrub = engine.isPlaying
                            if engine.isPlaying { engine.pause() }
                            scrubValue = engine.currentTime
                            isScrubbing = true
                        } else {
                            // ── RELEASE. FOUR ORDERED STEPS BECAME THREE, AND THE ONE THAT WENT
                            //    WAS THE HOLD ─────────────────────────────────────────────────
                            //
                            // It used to be: retire the readout, open a handoff, fire a corrective
                            // un-throttled preview, seek — with the overlay held up by a one-shot
                            // and a 400 ms timeout until the seeked-to frame was PRESENTED. All of
                            // that existed to keep a SECOND surface alive across the gap.
                            //
                            // ⚠️ THERE IS NOTHING IN ITS PLACE, AND THAT IS CORRECT RATHER THAN AN
                            // OMISSION. There is no second surface to keep alive: the Metal layer
                            // is ALREADY showing the release frame, because it got there through
                            // the ordinary present path during the drag. `exactSeek` →
                            // `beginReading` → `flush()` clears the queue, and a CAMetalLayer keeps
                            // its last presented drawable — which is that scrub frame. The hold now
                            // happens by default instead of by machinery. That is what "one display
                            // path" buys, stated concretely.
                            //
                            // ⚠️ AND IT IS NOW TRUE OF EVERY FILE. Stage 2 had to keep an MXF-only
                            // hold, because MXF still had no producer and its Metal layer held the
                            // PRE-DRAG frame for the whole gesture — the reasoning above simply did
                            // not reach it. With `LibavScrubProducer` putting real frames on that
                            // layer, it does, and the hold, the 400 ms fallback and the last
                            // `CGImage` in the scrub path are gone with it. MEASURED, not assumed:
                            // the `[SETTLE]` line on MXF (see MetalVideoRenderer).
                            isScrubbing = false          // the readout goes back to the engine

                            // 1. THE PENDING SLOT, FLUSHED AT THE RELEASE POINT. This is what the
                            //    old `requestScrubPreview(at:final:)` became. Its job was to close
                            //    a staleness floor created by a media-DISTANCE gate that was never
                            //    re-asked at the release point; that gate is gone, so there is no
                            //    floor and no corrective request. What survives is the in-flight
                            //    LATCH: one decode may still be outstanding at a marginally older
                            //    position, so the release point is submitted and the coalescer
                            //    issues it the moment that decode completes. Latest wins, and the
                            //    latest is now exactly where the user let go.
                            engine.scrubSeek(to: scrubValue)
                            // 2. The real seek.
                            engine.exactSeek(to: scrubValue)
                            #if DEBUG
                            // Flushed BEFORE the resume so playback's converts cannot land in the
                            // drag's numbers.
                            metalRenderer?.debugFlushV210Stats(label: "drag")
                            #endif
                            // 3. …and the transport resumes if it was running.
                            if wasPlayingBeforeScrub { engine.play() }
                        }
                    }
                )
                // A stream has no duration, so this slider's range collapses to 0...0.1 and its
                // thumb sits pinned at zero. Inert AND operable-looking is the worst pairing.
                .disabled(!position)
                .help(position ? "" : (positionWhy ?? ""))

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
                .help(keys.helpText("Open…", .fileOpen))

                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").frame(width: 24)
                }
                // Space is the shortcut registry's (`.playPause`), dispatched with this button's gate.
                .disabled(!position)
                // See the `dim` note above: `.disabled` does not grey a control in this row.
                .foregroundStyle(position ? live : dim)
                .help(position ? keys.helpText(engine.isPlaying ? "Pause" : "Play", .playPause)
                               : (positionWhy ?? "Playback is in another window"))

                Divider().frame(height: 16).overlay(.white.opacity(0.25))

                // ⚠️ FIXED GEOMETRY, AND THE JITTER WAS GEOMETRY (§8 item 17, MEASURED by Accessibility on HEAD
                // `3c5526d`). This row is centred, and the fader used to be inserted on hover: hovering the speaker
                // moved the play button and the speaker itself 38 pt left (half the fader and its spacing). The
                // speaker slid out from under the pointer, the hover ended, the fader went, the speaker slid back
                // under the pointer, and round again: the shake, with the play button passing under the pointer. The
                // speaker glyph also changes width with the level (wave.1 / wave.2 / slash), which nudged the fader
                // during a drag. Now the fader is always laid out (hidden and untouchable until hovered), the glyph
                // has a fixed frame, and the whole group is the hover area: nothing in the row moves (measured, 0 pt).
                HStack(spacing: 6) {
                    Button { engine.toggleMute() } label: {
                        Image(systemName: speakerSymbol)
                            .frame(width: 26, alignment: .leading)
                    }
                    .help(keys.helpText(engine.isMuted ? "Unmute" : "Mute", .mute))
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
                    .opacity(volumeHovering ? 1 : 0)
                    .allowsHitTesting(volumeHovering)
                    .accessibilityHidden(!volumeHovering)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onHover { h in
                    withAnimation(.easeInOut(duration: 0.15)) { volumeHovering = h }
                }
                // ⚠️ `transport`, NOT `position`, AND THAT IS DELIBERATE. Audio is not a position:
                // NDI carries it, and mute reaches the DeckLink card through `applyAudioMute`, so
                // a stream being up is no reason to take the fader away. The one live source with
                // no audio at all is WHEP (its audio track is wired to
                // ManifoldWHEPDiscardMessage) — not enough to justify a third gate, and greying
                // the control per-transport would be less predictable than leaving it alone.
                .disabled(!transport)
                Button { engine.toggleLoop() } label: { Image(systemName: "repeat") }
                    .help(position ? "Loop playback" : (positionWhy ?? "Loop playback"))
                    // File-only, and now gated twice on purpose. `!engine.hasMedia` already
                    // self-disabled it for live sources — a live takeover calls engine.stop() —
                    // but that was incidental, not stated: it read as a no-file gate that happened
                    // to catch streams. `position` says the intended thing, and the pair costs
                    // nothing.
                    .disabled(!engine.hasMedia || !position)
                    // Three states, and the middle one is the new part: ON (the app's yellow; green
                    // until 2026-10-25, now kept for live), available (0.9), gated (0.35). This button
                    // ALREADY overrode the row's foreground style to carry its colour, so it was the
                    // clearest case of a disabled control drawn at full brightness — see the `dim` note above.
                    .foregroundStyle(engine.isLooping ? Color.appYellow
                                     : ((engine.hasMedia && position) ? live : dim))
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
                .help(keys.helpText("Inspector", .inspector))

                Button(action: editInFlip) {
                    // AN F IN A ROUNDED SQUARE — the silhouette of an app icon, so it reads as
                    // "the app Flip" rather than as a letter badge. A SQUARE and not `f.circle`
                    // because the neighbours here are square-ish (`square.and.arrow.down`, `tv`,
                    // `viewfinder.rectangular`) while the circles in this row mean something else —
                    // `info.circle` is a status affordance — so the square keeps the row's geometry
                    // consistent AND keeps the two apart at a glance.
                    //
                    // UNFILLED, and that is a weight decision made by looking at the built bar.
                    // `f.square.fill` was the first cut: it is a solid tile with the letter knocked
                    // out, and next to a row drawn entirely in thin strokes it was the heaviest mark
                    // present — it read as selected, or as a badge, rather than as one control among
                    // twelve. `f.square` carries the same silhouette at the row's own weight.
                    Image(systemName: "f.square")
                }
                .help("Edit in Flip")
                .disabled(engine.currentURL == nil)

                // Refresh metadata — ALWAYS PRESSABLE, and lit when there is a reason to press it.
                //
                // The press always re-reads, whether or not anything changed; pressing it on an
                // unchanged file is never wrong, it just re-reads. The alternative design — enable
                // it only when the file has changed — was rejected: it makes the common case a dead
                // control, and it is the DEAD-CONTROL reading that produced the bug report this
                // fixes (a tester pressed it on an unchanged file, saw nothing happen, and
                // concluded it was broken). `.disabled` here is only the same no-file gate its
                // neighbours in this row carry; it never tracks the changed state.
                //
                // ⚠️ THE GREEN MEANS SOMETHING DIFFERENT HERE THAN IT DOES THREE BUTTONS ALONG.
                // On the DeckLink and scopes-tray buttons this tint means "this is ON" — a mode the
                // user turned on and can turn off. Here it means "there is something waiting" — a
                // notification, cleared by acting on it, not by pressing it again. Same treatment,
                // different meaning, deliberately: a second highlight colour in a twelve-button row
                // would be read as a third state of the first meaning rather than as a new one, and
                // "this control has something for you" is exactly what green already says at a
                // glance. If it ever reads oddly, that is why.
                //
                // ⚠️ TWO DIFFERENT REASONS PRODUCE THIS ONE GREEN, and the tooltip is the ONLY
                // place they are told apart — see `reloadHelp` below, and `sentForEditing` in
                // SourceFileWatcher for why they are two flags and not one. Deliberately not two
                // colours: a second highlight in this row would read as a third state of the
                // first meaning rather than as a new meaning.
                Button(action: {
                    // The press IS the acknowledgement — adopt what is on disk now as the truth
                    // before the read, so the highlight clears immediately rather than on the next
                    // poll. See SourceFileWatcher.rebaseline for the during-the-read race.
                    fileWatch.rebaseline()
                    Task { await engine.reinspect() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .foregroundStyle(fileWatch.isHighlighted ? Color.appYellow : .white.opacity(0.9))
                .help(reloadHelp)
                .disabled(engine.currentURL == nil)

                // Export the current frame (ACTION) — sits with the file/action controls.
                Button(action: { metalRenderer?.exportCurrentFrame() }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help(keys.helpText("Export frame", .exportFrame))
                .disabled(engine.currentURL == nil)

                Divider().frame(height: 16).overlay(.white.opacity(0.25))

                // Audio track (WHAT YOU ARE HEARING) — first in the group, ahead of the scopes /
                // DeckLink / streaming controls. It governs PLAYBACK, not display: it decides which
                // of the file's audio tracks feeds the speakers, the meters and SDI. That is why it
                // is a control-bar control and not a scope setting — you should not have to open a
                // scope slot to change what you are listening to.
                audioTrackControl

                // Scopes tray (VIEW STATE) — open/close. Which scopes fill the three slots is
                // chosen per-slot via each slot's header picker, not from here.
                Button { chrome.showTray.toggle(); updateScopeSampling() } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .foregroundStyle(chrome.showTray ? Color.appYellow : .white.opacity(0.9))
                .help(keys.helpText("Scopes tray", .scopesTray))

                // DeckLink output: split-button — main toggles output, chevron picks device + status.
                deckLinkOutputControl

                // Streaming source: split-button next to DeckLink output — main quick-connects/stops,
                // chevron opens the tech → source picker. Lit while streaming, dark (local) otherwise.
                streamingControl

                // Color — the color-interpretation control (source-agnostic). It hosts an ASSERTION
                // about the source, so it lives with the actions, not in the inspector (which reports
                // what things ARE). The live stream's override on NDI, SRT, WHEP and HLS; the file's since
                // colour S5 (§6.11, decision 6). One element, no modifiers (§6.7): the slot picks which, so
                // this body does not grow a branch — see LiveColorOverride.swift.
                ColorInterpretationSlot(deck: deck, live: activeLiveSource, hasFile: engine.hasMedia)

                // Display transform (§6.3 tiers 1–3) — Phase 2b. Next to the Color control because
                // they are the two halves §6.3 names: that one is INTERPRETATION (what the source
                // is), this one is the DISPLAY TRANSFORM (what is sent to the screen). Kept as two
                // adjacent controls rather than merged, because "keeping them visibly separate is
                // what stops 'Embedded' creeping back in as a concept."
                //
                // ⚠️ NOT GATED ON `activeLiveSource` the way the Color control is. That gate exists
                // because the interpretation control has nothing to say about a FILE yet; this one
                // has everything to say about a file — §6.5 and §6.6 were measured on file
                // playback, and gating it to NDI would put the mode out of reach of its main case.
                // Gated on `hasSource` only, matching when the Color menu's items are enabled.
                //
                // ⚠️ ONE ELEMENT, NO MODIFIERS — see DisplayTransformControl.swift's header and
                // §6.7: this file's body is at the type-checker's limit.
                if hasSource {
                    DisplayTransformControl(deck: deck, chrome: chrome)
                }

                // The per-source audio offset (docs/AUDIO_RESAMPLER_DESIGN.md §19.8): its control and
                // its standing badge, while this window has a live source. One element, no modifiers,
                // for the same reason as the line above.
                if activeLiveSource != nil {
                    AudioOffsetControl(model: deck.audioOffset, calibration: deck.calibration)
                }

                Spacer()

                if showPin {
                    Button { togglePin() } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                    }
                    // Pinned reads in the app's yellow, as Loop does when on (§8 item 16; Robbie, 2026-10-25).
                    .foregroundStyle(pinned ? Color.appYellow : live)
                    .help(keys.helpText(pinned ? "Unpin controls" : "Pin controls", .alwaysShowControls))
                    // Test drivers find the button by this, not by its help text, which names the shortcut.
                    .accessibilityIdentifier("pinControls")
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
                // network sources, picking connects via the SAME NDIService.connect(to:). Opening its
                // NDI submenu is what starts discovery (privacy P1; `ndiSourceListItems`).
                Menu {
                    // NDI in a SUBMENU, as in the toolbar's menu (decided 2026-10-19, P1): opening
                    // "Connect Stream…" to pick a saved stream must not start NDI discovery, and
                    // the source list's own `.onAppear` is what starts it.
                    Menu {
                        ndiSourceListItems
                    } label: {
                        Label("NDI", systemImage: "antenna.radiowaves.left.and.right")
                    }
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
        // Discovery is NOT started by this view appearing (privacy P1): opening "Connect Stream…"
        // starts it (`ndiSourceListItems`), and leaving the empty state releases it. Discovery is
        // reference-counted in NDIService, so a hand-over to the control bar's own request during
        // the connect transition doesn't stop it out from under the newly-shown control.
        .onReceive(NotificationCenter.default.publisher(for: NDIMenuOpenWatcher.ndiSubmenuWillOpen)) { _ in
            // The menu belongs to the key window; other windows ignore it (privacy P1).
            if deck.window?.isKeyWindow == true { requestNDIDiscovery() }
        }
        .onDisappear { releaseNDIDiscovery() }
    }

    /// Take this window's NDI discovery client, once. Called when an "NDI" submenu opens in this
    /// window (`NDIMenuOpenWatcher.ndiSubmenuWillOpen`, key window only).
    private func requestNDIDiscovery() {
        guard !ndiDiscoveryHeld else { return }
        ndiDiscoveryHeld = true
        NSLog("[NDI] discovery requested — the NDI source list was opened")
        ndi.startDiscovery()
    }

    /// The fallback for `NDIMenuOpenWatcher`: called as the NDI list is composed. Checked 0.3 s later, so the
    /// menu's tracking notification has landed; starts discovery only if a menu was open at the composition
    /// and could not be watched (`fallbackNeeded`), never for a composition with no menu open (privacy P1).
    private func checkNDISubmenuIsWatched() {
        let composedAt = CACurrentMediaTime()
        #if DEBUG
        MenuProbe.log("NDI list composed (.onAppear): key=\(deck.window?.isKeyWindow == true) held=\(ndiDiscoveryHeld)")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let needed = NDIMenuOpenWatcher.fallbackNeeded(composedAt: composedAt)
            #if DEBUG
            MenuProbe.log("NDI list check +0.3 s: key=\(deck.window?.isKeyWindow == true) held=\(ndiDiscoveryHeld) "
                          + "fallbackNeeded=\(needed)")
            #endif
            guard deck.window?.isKeyWindow == true, !ndiDiscoveryHeld else { return }
            // Only a menu that was OPEN when the list was composed, and could not be watched (privacy P1).
            guard needed else { return }
            NSLog("[NDI] ⚠️ FALLBACK — the NDI submenu could not be watched (NDIMenuOpenWatcher did not "
                  + "attach); starting discovery now that the menu has opened, so NDI keeps working")
            requestNDIDiscovery()
        }
    }

    /// Give it back, if held. Called when the empty state or the streaming control leaves the screen.
    private func releaseNDIDiscovery() {
        guard ndiDiscoveryHeld else { return }
        ndiDiscoveryHeld = false
        ndi.stopDiscovery()
    }

    /// Open the current file in Flip (tools.graviton.flip). If Flip isn't
    /// installed, show the upsell sheet. Sniff happens on press.
    private func editInFlip() {
        guard let url = engine.currentURL else { return }
        let flipBundleID = "tools.graviton.flip"
        if let flipURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: flipBundleID) {
            let config = NSWorkspace.OpenConfiguration()
            // Captured as a local rather than reached through `self` in the escaping closure below:
            // this is a struct, and the closure only ever needs the watcher's identity. A
            // `@MainActor` class is Sendable, so the capture is clean.
            let watcher = fileWatch
            NSWorkspace.shared.open([url], withApplicationAt: flipURL, configuration: config) { _, error in
                if let error {
                    print("Edit in Flip: open failed — \(error.localizedDescription)")
                    return
                }
                // ⚠️ THE HIGHLIGHT IS ARMED HERE, IN THE COMPLETION HANDLER ON SUCCESS — NOT AT THE
                // TOP OF THIS FUNCTION, AND THE DIFFERENCE IS A REAL USER.
                //
                // This function has three outcomes and only one of them is intent-to-modify: Flip
                // opens; Flip is not installed, and we show the Get Flip sheet instead (the `else`
                // below); or the open is attempted and FAILS. Arming before the open would light
                // the button in all three — including the not-installed case, which is the one a
                // NEW USER hits, on the very first press, for a file that nothing has touched and
                // no editor has even launched against. A hint that fires when nothing happened is
                // how a control loses its meaning; this one is only worth having while it is
                // believed. The cost of getting it right is this hop back to the main actor.
                //
                // Success here means AppKit launched or activated Flip with the file — not that
                // Flip wrote anything. That weaker claim is exactly what the tooltip says.
                Task { @MainActor in watcher.noteSentForEditing() }
            }
        } else {
            showGetFlipSheet = true
        }
    }

    /// The reload button's tooltip, and the ONLY place the highlight's two reasons are told apart.
    ///
    /// `changedOnDisk` takes precedence because an OBSERVATION BEATS AN INFERENCE: if a reading of
    /// the file actually differs, say so plainly. The middle case says only the two things we know
    /// — that this window handed the file to Flip, and what the press will do — and deliberately
    /// does NOT claim Flip wrote anything, because nothing here can know that. See
    /// `SourceFileWatcher.sentForEditing`.
    ///
    /// A computed property rather than a ternary chain inline in `.help(…)`: this body is at the
    /// Swift type-checker's limit (see the notes on the currentURL observer), and a nested
    /// conditional inside an already-enormous modifier chain is exactly the shape that tips it.
    private var reloadHelp: String {
        if fileWatch.changedOnDisk { return "This file changed on disk — click to reload" }
        if fileWatch.sentForEditing { return "Editing in Flip — reload to pick up any changes" }
        return "Refresh metadata"
    }

    /// Speaker icon reflecting mute + volume level.
    private var speakerSymbol: String {
        if engine.isMuted || engine.volume <= 0.0001 { return "speaker.slash.fill" }
        return engine.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    /// Volume Up / Down (⌘↑ / ⌘↓): the fader's step, saved as the fader saves it.
    private func stepVolume(_ delta: Float) {
        engine.setVolume(engine.volume + delta)
        Preferences.shared.playbackVolume = Double(engine.volume)
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

    /// The entry overlay and its clamp confirmation, as one layer so `videoRegion`'s chain gains a
    /// single modifier. The two are mutually exclusive by construction: `commit()` clears `isActive`
    /// in the same turn it raises a notice.
    @ViewBuilder private var timecodeEntryLayer: some View {
        if transportKeys.isActive, let ctx = transportKeys.context {
            TimecodeEntryOverlay(entry: transportKeys.entry, context: ctx, clampNotice: nil)
        } else if let notice = transportKeys.clampNotice {
            TimecodeClampOverlay(notice: notice)
        }
    }

    private var displayTime: Double { isScrubbing ? scrubValue : engine.currentTime }

    private var leadingReadout: String {
        // DURING ENTRY THE SMALL DISPLAY IS THE ENTRY. It renders from the same value the centred
        // overlay does, so the two cannot drift, and nothing on the bar goes on claiming a playhead
        // position while the user is typing a different one.
        if transportKeys.isActive, let ctx = transportKeys.context {
            return transportKeys.entry.masked(dropFrame: ctx.dropFrame)
        }
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
