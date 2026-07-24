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
    @ObservedObject var engine: FrameEngine

    @AppStorage("controlDisplayMode") private var controlModeRaw: String = ControlDisplayMode.overlay.rawValue
    private var mode: ControlDisplayMode { ControlDisplayMode(rawValue: controlModeRaw) ?? .overlay }
    private var isDocked: Bool { mode == .docked }

    @State private var isImporterPresented = false
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
    #if DEBUG
    // WHEP's published connection state. WHEPClient is #if DEBUG, so this observation is too; it
    // feeds `hasSource` below so the empty-state overlay hides while WHEP drives the shared renderer.
    @ObservedObject private var whep = WHEPClient.shared
    #endif
    @State private var showReferenceLayer = false   // M4 tuning: A/B Metal vs AVSampleBufferDisplayLayer

    // Scopes tray: a proportional bottom share of the content area (NOT fixed pixels),
    // so video + tray both scale with the window. trayHeightFraction is the tunable ratio.
    static let trayHeightFraction: CGFloat = 0.33   // bottom third
    // Persisted scope arrangement — same UserDefaults keys declared on Preferences
    // (the canonical owner); @AppStorage here gives SwiftUI reactivity + write-through.
    @AppStorage("showTray") private var showTray = false
    // Per-slot scope selection (3-up tray). Each slot can show ANY of the four scopes, chosen live
    // and persisted. Defaults reproduce the prior layout exactly (waveform / parade / CIE) so the
    // first launch after this build looks unchanged until the user picks. Variable slot count /
    // arrangement / saved layouts are a later pass.
    @AppStorage("manifold.scope.slot0") private var slot0: ScopeKind = .waveform
    @AppStorage("manifold.scope.slot1") private var slot1: ScopeKind = .parade
    @AppStorage("manifold.scope.slot2") private var slot2: ScopeKind = .cie
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

    // A source is "active" whenever a file is loaded OR an NDI stream is on screen. The whole
    // auto-hiding control surface (HUD / control bar, scopes, guides, overlay data, output toggle)
    // is source-agnostic — it reveals for ANY active source. NDI drives frames straight into the
    // shared renderer without ever setting `hasMedia`, so gating the reveal on `hasMedia` alone left
    // streaming with no reachable controls. Every reveal gate keys off this instead. Only the
    // "Open… to begin" prompt stays file-vs-nothing specific (it means NOTHING is on screen).
    // The WHEP term is #if DEBUG because WHEPClient itself is: the whole WHEP path compiles only in
    // DEBUG, so the Release build has no such symbol and must not reference it. WHEP pushes frames
    // into the shared renderer exactly like NDI and never sets engine.hasMedia, so without this term
    // the empty state would draw over live WHEP video. Collapses back to one expression when WHEP
    // leaves DEBUG.
    private var hasSource: Bool {
        #if DEBUG
        return engine.hasMedia || ndi.isConnected || whep.isConnected
        #else
        return engine.hasMedia || ndi.isConnected
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                videoRegion
                    .frame(height: showTray
                           ? geo.size.height * (1 - Self.trayHeightFraction)
                           : geo.size.height)
                if showTray {
                    scopesTray
                        .frame(height: geo.size.height * Self.trayHeightFraction)
                }
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
        // Scope shortcuts (tray + per-scope toggles + CIE live toggles) consolidated into one
        // hidden group so the view body's modifier chain stays type-checkable.
        .background(scopeShortcuts)
        .background(deckLinkShortcuts)
        .background(ndiShortcuts)
        .background(syntheticLiveShortcuts)
        // JKL shuttle transport (bare keys — pro NLE muscle memory).
        .background(
            Button("") { engine.shuttleBackward() }
                .keyboardShortcut("j", modifiers: [])
                .opacity(0)
        )
        .background(
            Button("") { engine.shuttlePause() }
                .keyboardShortcut("k", modifiers: [])
                .opacity(0)
        )
        .background(
            Button("") { engine.shuttleForward() }
                .keyboardShortcut("l", modifiers: [])
                .opacity(0)
        )
        // Frame jog (arrow keys — back/forward one frame, pauses).
        .background(
            Button("") { engine.stepFrame(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .opacity(0)
        )
        .background(
            Button("") { engine.stepFrame(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .opacity(0)
        )
        .onContinuousHover { phase in
            if case .active = phase { wakeHUD() }
        }
        .onAppear {
            armIdleIfNeeded()
            if let renderer = metalRenderer {
                renderer.clock = { engine.currentSyncTime().seconds }
                renderer.isPausedProvider = { engine.isPausedNow() }
                renderer.isFullRangeProvider = { engine.currentEffectiveIsFullRange() }
                renderer.chromaConventionProvider = { engine.currentChromaConventionRaw() }
                engine.onVideoFrame = { [weak renderer] sb in renderer?.enqueue(sb) }
                engine.onFlush = { [weak renderer] in renderer?.flush() }
                // Seed the kernel's CIE mode from the persisted value so the scatter opens in the
                // last-left mode even if a source loaded before the CIE scope is shown. (The CIE
                // view's header/graticule read the same @AppStorage directly, so they're already
                // correct; this keeps the kernel-side plot in agreement.)
                renderer.cieUseUV = cieUseUV
                renderer.start()
                // DeckLink output sources real video from this renderer (⌃⌥O / toolbar control).
                DeckLinkService.shared.renderer = renderer
                // NDI step A (throwaway trigger, ⌃⌥N) displays THROUGH this same renderer — it
                // pulls frames on the display tick and feeds the same enqueue the file sources do.
                NDIService.shared.renderer = renderer
                // One active source (reverse of the file-open path disconnecting the stream): when a
                // stream is about to take over, retire any loaded file first so both don't feed the
                // renderer at once. NDIService has no engine handle, so it calls back through here.
                NDIService.shared.onWillActivateStream = { [weak engine] in engine?.stop() }
                #if DEBUG
                // WHEP step 4 (⌃⌥H) displays through this SAME renderer, feeding the same enqueue
                // NDI and the file sources feed — but paced by LiveClock rather than FrameSync or
                // the file timebase. Same two hooks as NDI, for the same two reasons.
                WHEPFrameRouter.shared.renderer = renderer
                WHEPFrameRouter.shared.onWillActivateStream = { [weak engine] in engine?.stop() }
                #endif
                // …and tees NDI audio into the SAME PTS-keyed PCM ring the file paths feed, so the
                // clock-anchored SDI output, SDI/Computer routing and mute apply to NDI for free.
                NDIService.shared.audioTap = engine.audioTap
                // D4b-2: …and SDI audio from the engine's PTS-keyed PCM ring, gated by the transport.
                // The card's audio callback pulls from the ring at the SOURCE TIME of the frame the
                // renderer currently has staged for the card, so A/V are aligned by construction.
                DeckLinkService.shared.audioTap = engine.audioTap
                DeckLinkService.shared.isCardAudioSilentProvider = { engine.isCardAudioSilent() }
                // D4b-3: the SDI and computer paths are mutually exclusive. This is the service's ONLY
                // authority over the system renderer — it passes (outputEnabled && destination == .sdi),
                // and the engine folds that into its existing applyAudioMute rule.
                DeckLinkService.shared.systemAudioRouting = { owns in engine.setDeckLinkOwnsAudio(owns) }
                // The card must be ENABLED with a fixed rate/channel count before playback starts, so a
                // file whose audio format differs re-establishes the output (this is also what lets you
                // enable output BEFORE loading a file and still get audio).
                engine.audioTap.onFormatChange = { fmt in DeckLinkService.shared.audioFormatChanged(fmt) }
                DeckLinkService.shared.refreshDevices()   // populate the device picker
                // Explicit "Enable output on launch" preference (Settings → DeckLink Output): start
                // output now IF the pref is on AND a capable device is present (no-op otherwise).
                DeckLinkService.shared.autoStartOnLaunchIfEnabled()
            }
            // Apply persisted volume (mute is not persisted — starts unmuted).
            engine.setVolume(Float(Preferences.shared.playbackVolume))
            // Persisted arrangement may reopen the tray with scopes already on —
            // start their sampling to match the restored visibility.
            updateScopeSampling()
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
                DeckLinkService.shared.sourceColorChanged()
                // D4a: derive the output display mode (video cadence) from the file's resolution + rate.
                // Updates the status label; live-switches the output mode if it's running and changed.
                DeckLinkService.shared.sourceFormatChanged(width: meta.width, height: meta.height,
                                                           frameRate: meta.frameRate)
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
        .onChange(of: ndi.colorInfo) { _, info in
            guard ndi.isConnected else { return }
            applyNDIColorToScopes(info)
        }
        .onChange(of: ndi.isConnected) { _, connected in
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
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                // One active source: a new file retires any live stream FIRST, so both don't feed
                // the renderer at once (NDI pushing on its tick + the file's frame pump = the
                // double-source flashing). Full-replacement, same teardown ⌃⌥⇧N / UI Disconnect use.
                // No-op when not streaming.
                if ndi.isConnected { NDIService.shared.disconnect() }
                #if DEBUG
                // Same rule for WHEP: a new file retires a live WHEP stream so both don't feed the
                // renderer at once. WHEP→file was the missing half — file→stream already works via
                // WHEPFrameRouter.activate()'s onWillActivateStream (ContentView.swift ~:278).
                if WHEPClient.shared.isConnected { WHEPClient.shared.disconnect() }
                #endif
                engine.load(url: url, autoplay: Preferences.shared.autoplayOnLoad)
                wakeHUD()
            }
        }
        // An .srt is a sidecar to ONE file, so a new source retires it — otherwise the old cues
        // would keep firing confidently against unrelated pictures. Keyed on currentURL rather than
        // the load call sites because media also arrives via ManifoldApp's .onOpenURL (Finder
        // double-click / drag-to-icon), which can't reach this view's state. Also covers the nil
        // transition engine.stop() makes on NDI takeover.
        .onChange(of: engine.currentURL) { _, _ in captions.clear() }
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
    private var videoAspect: CGFloat {
        if let s = engine.displaySize, s.width > 0, s.height > 0 { return s.width / s.height }
        return 16.0 / 9.0
    }

    /// The video region: aspect-fit picture (never cropped/stretched), transport
    /// controls, empty state, and the picture-only overlays (inspector, filename,
    /// METAL indicator). Fills whatever height the split gives it.
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
                Image(decorative: preview, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            if hasSource {
                // Full control surface for ANY active source (file OR NDI stream). Streaming is a
                // monitoring mode — it needs the same reveal-on-hover HUD, scopes, guides and overlay
                // as file playback. The transport row lives here too; its file-specific affordances
                // simply no-op over a live stream, which is a separate (banked) concern.
                VStack {
                    Spacer()
                    controls(showPin: !isDocked)
                        .padding(isDocked ? 14 : 12)
                        .background(
                            isDocked
                                ? AnyShapeStyle(.black.opacity(0.85))
                                : AnyShapeStyle(.black.opacity(0.55)),
                            in: RoundedRectangle(cornerRadius: isDocked ? 0 : 12)
                        )
                        .frame(maxWidth: isDocked ? .infinity : 760)
                        .padding(isDocked ? 0 : 16)
                }
                .opacity(controlsShown ? 1 : 0)
                .animation(.easeInOut(duration: 0.30), value: controlsShown)
            } else {
                // "Open… to begin" means NOTHING is on screen — no file and no stream. `hasSource`
                // already folds in the NDI flag, so this branch is reached only when truly idle.
                emptyState
            }

            WindowConfigurator(
                buttonsVisible: hasSource ? controlsShown : true,
                displaySize: engine.displaySize
            )
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
        .overlay(alignment: .topLeading) {
            if engine.hasMedia {
                Text(showReferenceLayer ? "REFERENCE (AVSampleBufferDisplayLayer)" : "METAL")
                    .font(.caption2.monospaced())
                    .padding(4)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(showReferenceLayer ? .yellow : .green)
                    .padding(8)
                    .allowsHitTesting(false)
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
        .animation(.easeInOut(duration: 0.2), value: showInspector)
        .animation(.easeInOut(duration: 0.2), value: showFileNameOverlay)
    }

    /// The scopes tray: three equal-width slots, each rendering the scope its @AppStorage selection
    /// names (data-driven — no scope is special-cased to a fixed slot). The leading header label of
    /// each slot is a live picker (see slotView / ScopeSlotHeader).
    private var scopesTray: some View {
        HStack(spacing: 1) {
            slotView(kind: slot0, selection: $slot0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            slotView(kind: slot1, selection: $slot1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            slotView(kind: slot2, selection: $slot2)
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
    private var activeKinds: Set<ScopeKind> { [slot0, slot1, slot2] }

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
        let active = showTray ? activeKinds : []

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
            Button("") { showTray.toggle(); updateScopeSampling() }
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
            Button("") { DeckLinkService.shared.startScheduledOutput() }
                .keyboardShortcut("o", modifiers: [.control, .option])
            Button("") { DeckLinkService.shared.stopScheduledOutput() }
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
            Button("") { NDIService.shared.connectToFirstSource() }
                .keyboardShortcut("n", modifiers: [.control, .option])
            Button("") { NDIService.shared.disconnect() }
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
    ///         producer/consumer pair. Needs an endpoint in ~/.manifold-whep-config or
    ///         $MANIFOLD_WHEP_URL (see WHEPClient). ⌃⌥⇧H tears down and restores playback.
    ///   ⌃⌥⇧E  export the next decoded WHEP frame to a PNG (pre-render, decoder-side check)
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
                                                 retireCurrentSource: { engine.stop() })
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
                                                      retireCurrentSource: { engine.stop() })
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
            Button("") { WHEPClient.shared.connect() }
                .keyboardShortcut("h", modifiers: [.control, .option])
            Button("") { WHEPClient.shared.disconnect() }
                .keyboardShortcut("h", modifiers: [.control, .option, .shift])
            // ⌃⌥⇧E — WHEP DECODED-FRAME STILL (step 3b). Writes the next decoded WHEP frame
            // to a PNG in the export folder. Distinct from ⌃⌥E, which reads back the RENDERED
            // frame: nothing is rendered from WHEP yet, so this goes straight from the
            // decoder's CVPixelBuffer via VideoToolbox. A content/geometry check, not a
            // colour-managed export — see WHEPVideoDecoder.exportStill.
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
            Button("") { WHEPFrameRouter.shared.adjustTargetDepth(by: -0.05) }
                .keyboardShortcut("[", modifiers: [.control, .option])
            Button("") { WHEPFrameRouter.shared.adjustTargetDepth(by: 0.05) }
                .keyboardShortcut("]", modifiers: [.control, .option])
        }
        .opacity(0)
        #else
        EmptyView()
        #endif
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
        HStack(spacing: 2) {
            Button { deckLink.toggleOutput() } label: {
                Image(systemName: deckLink.isOutputting ? "tv.fill" : "tv")
            }
            .foregroundStyle(deckLink.isOutputting ? Color.green : .white.opacity(0.9))
            .help(deckLink.isOutputting ? "DeckLink output ON — click to stop (⌃⌥⇧O)"
                                        : "DeckLink output — click to start (⌃⌥O)")

            Menu {
                Section("Output device") {
                    if deckLink.devices.isEmpty {
                        Button("No DeckLink device") {}.disabled(true)
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
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("DeckLink output options")
        }
    }

    /// Streaming source control — a split-button mirroring `deckLinkOutputControl` and sitting next
    /// to it. The main button quick-connects to the first NDI source (or disconnects when already
    /// streaming); the chevron opens the technology → source picker. Lit green while streaming,
    /// full-brightness white when LOCAL — local is a legitimate resting mode, so it must read as
    /// available, not as a disabled/off look. Discovery runs only while this control is on screen
    /// (onAppear/onDisappear), so `discoveredSources` is already warm when the menu is opened.
    private var streamingControl: some View {
        HStack(spacing: 2) {
            Button { toggleStreaming() } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
            }
            .foregroundStyle(ndi.isConnected ? Color.green : .white.opacity(0.9))
            .help(ndi.isConnected
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
        // Structural room for future streaming tech (WHEP / SRT / HLS) — sibling Menus go here.

        if ndi.isConnected {
            Divider()
            Button(role: .destructive) {
                NDIService.shared.disconnect()
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
                Button { NDIService.shared.connect(to: source) } label: {
                    if source.name == ndi.connectedSourceName {
                        Label(source.name, systemImage: "checkmark")   // the live source
                    } else {
                        Text(source.name)
                    }
                }
            }
        }
    }

    /// The streaming button's main-click action (and the ⌃⌥N/⌃⌥⇧N shortcuts funnel through the same
    /// NDIService calls): stop when streaming, quick-connect the first discovered source otherwise.
    private func toggleStreaming() {
        if ndi.isConnected {
            NDIService.shared.disconnect()
        } else {
            NDIService.shared.connectToFirstSource()
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
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(leadingReadout)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
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

                Text(trailingReadout)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(minWidth: 86, alignment: .trailing)
                    .onTapGesture { cycleReadout() }
            }

            HStack(spacing: 16) {
                Button { isImporterPresented = true } label: { Image(systemName: "folder") }
                    .help("Open…")

                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").frame(width: 24)
                }
                .keyboardShortcut(.space, modifiers: [])

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
                Button { engine.toggleLoop() } label: { Image(systemName: "repeat") }
                    .help("Loop playback")
                    // File-only: NDI takeover calls engine.stop(), which zeroes hasMedia, so this
                    // self-disables for live sources (loop is meaningless on an indefinite stream).
                    .disabled(!engine.hasMedia)
                    .foregroundStyle(engine.isLooping ? Color.green : .white.opacity(0.9))
                Button { showGuidesPanel.toggle() } label: { Image(systemName: "grid") }
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
                Button { showTray.toggle(); updateScopeSampling() } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .foregroundStyle(showTray ? Color.green : .white.opacity(0.9))
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
                if ndi.isConnected {
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
                Button { isImporterPresented = true } label: {
                    Label("Open…", systemImage: "folder")
                }

                // Cold-start streaming entry (Stage 3a-2): a sibling pill of the same weight as Open…,
                // opening the SAME discovered-source list the toolbar chevron uses — one click to the
                // network sources, picking connects via the SAME NDIService.connect(to:). Discovery
                // runs while this view is on screen (see the ndi.startDiscovery/stopDiscovery below).
                Menu {
                    ndiSourceListItems
                } label: {
                    Label("Connect Stream…", systemImage: "antenna.radiowaves.left.and.right")
                }
                .menuStyle(.button)          // present as a button (pill), matching Open…'s weight
                .buttonStyle(.bordered)
                .fixedSize()
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
