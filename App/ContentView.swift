import SwiftUI
import ManifoldCore

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
    @State private var metalRenderer: MetalVideoRenderer? = MetalVideoRenderer()
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
    @State private var readoutMode: ReadoutMode = .source
    @State private var idleTask: Task<Void, Never>?

    // In docked mode the controls are always shown; in overlay they auto-hide.
    private var controlsShown: Bool { isDocked ? true : hudVisible }

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
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                engine.load(url: url, autoplay: Preferences.shared.autoplayOnLoad)
                wakeHUD()
            }
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

            if isScrubbing, let preview = scrubPreviewImage {
                Image(decorative: preview, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            if engine.hasMedia {
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
                emptyState
            }

            WindowConfigurator(
                buttonsVisible: engine.hasMedia ? controlsShown : true,
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

    /// Route the device picker through selectDevice (which cleanly stop/restarts if output is ON).
    private var deckLinkDeviceBinding: Binding<Int> {
        Binding(get: { deckLink.selectedDeviceIndex },
                set: { DeckLinkService.shared.selectDevice($0) })
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

    /// CIE header readout of the DETECTED source space (primaries · transfer). Honest about
    /// untagged sources: CICP primaries nil / Unspecified (2) means the kernel assumes 709, so the
    /// header SAYS "untagged → 709 (assumed)" rather than laundering the default into a confident
    /// label. Same for an absent/unspecified transfer (assumed 709 gamma).
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
                Button { } label: { Image(systemName: "repeat") }
                    .help("Loop (coming soon)").disabled(true)
                Button { showGuidesPanel.toggle() } label: { Image(systemName: "grid") }
                    .help("Framing guides")
                    .popover(isPresented: $showGuidesPanel, arrowEdge: .bottom) {
                        GuidesPanel()
                    }
                Button { } label: { Image(systemName: "textformat") }
                    .help("Overlay data (coming soon)").disabled(true)
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
            Text("Open a file to begin")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.65))
            Button { isImporterPresented = true } label: {
                Label("Open…", systemImage: "folder")
            }
            .controlSize(.large)
            .tint(.white)
        }
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
        guard engine.hasMedia, !isDocked else { return }
        pinned.toggle()
        idleTask?.cancel()
        hudVisible = pinned
    }

    private func wakeHUD() {
        guard engine.hasMedia, !isDocked else { return }
        hudVisible = true
        if !pinned { scheduleIdle() }
    }

    // Start the auto-hide countdown when appropriate (overlay mode, media loaded,
    // not pinned). Safe to call repeatedly — it cancels any prior pending task.
    private func armIdleIfNeeded() {
        guard engine.hasMedia, !isDocked, !pinned else { return }
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
