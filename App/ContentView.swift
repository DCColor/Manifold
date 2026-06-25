import SwiftUI
import ManifoldCore

enum ReadoutMode: CaseIterable { case source, frame, elapsed }

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
    // Per-scope presence WITHIN the tray (default on, so opening the tray shows all three).
    @AppStorage("showWaveform") private var showWaveform = true
    @StateObject private var waveformModel = WaveformScopeModel()
    @AppStorage("showParade") private var showParade = true
    @StateObject private var paradeModel = ParadeScopeModel()
    @AppStorage("showVectorscope") private var showVectorscope = true
    @StateObject private var vectorscopeModel = VectorscopeScopeModel()
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
        .background(
            Button("") { showTray.toggle(); updateScopeSampling() }
                .keyboardShortcut("t", modifiers: [.control, .option])
                .opacity(0)
        )
        .background(
            Button("") { showWaveform.toggle(); updateScopeSampling() }
                .keyboardShortcut("w", modifiers: [.control, .option])
                .opacity(0)
        )
        .background(
            Button("") { showParade.toggle(); updateScopeSampling() }
                .keyboardShortcut("p", modifiers: [.control, .option])
                .opacity(0)
        )
        .background(
            Button("") { showVectorscope.toggle(); updateScopeSampling() }
                .keyboardShortcut("v", modifiers: [.control, .option])
                .opacity(0)
        )
        .onContinuousHover { phase in
            if case .active = phase { wakeHUD() }
        }
        .onAppear {
            armIdleIfNeeded()
            if let renderer = metalRenderer {
                renderer.clock = { engine.currentSyncTime().seconds }
                engine.onVideoFrame = { [weak renderer] sb in renderer?.enqueue(sb) }
                engine.onFlush = { [weak renderer] in renderer?.flush() }
                renderer.start()
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
        }
        .onChange(of: engine.hasMedia) { _, _ in armIdleIfNeeded() }
        .onChange(of: engine.metadata) { _, meta in
            // Derive the Metal layer colorspace once per source from the
            // inspector's authoritative color tags (not per-frame from buffers).
            if let meta {
                metalRenderer?.setSourceColorSpace(
                    primaries: meta.colorPrimariesCode,
                    transfer: meta.transferFunctionCode,
                    matrix: meta.colorMatrixCode
                )
            }
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
                InspectorPanel(metadata: engine.metadata)
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

    /// The scopes tray: the three scopes side by side, each an equal third of the
    /// tray width, scaling to fit. Reuses the existing scope views/models unchanged.
    private var scopesTray: some View {
        HStack(spacing: 1) {
            if showWaveform {
                WaveformScopeView(model: waveformModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showParade {
                ParadeScopeView(model: paradeModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showVectorscope {
                VectorscopeScopeView(model: vectorscopeModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipped()
    }

    /// A scope samples only when the tray is open AND that scope is enabled.
    /// Stops sampling otherwise (no wasted readback when the tray is closed).
    private func updateScopeSampling() {
        if showTray && showWaveform {
            waveformModel.renderer = metalRenderer; waveformModel.start()
        } else { waveformModel.stop() }

        if showTray && showParade {
            paradeModel.renderer = metalRenderer; paradeModel.start()
        } else { paradeModel.stop() }

        if showTray && showVectorscope {
            vectorscopeModel.renderer = metalRenderer; vectorscopeModel.start()
        } else { vectorscopeModel.stop() }
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

                // Scopes + tray (VIEW STATE) cluster — separated from the actions.
                Button { showTray.toggle(); updateScopeSampling() } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .foregroundStyle(showTray ? Color.green : .white.opacity(0.9))
                .help("Scopes tray (⌃⌥T)")

                scopeToggle("WFM", on: showWaveform) {
                    showWaveform.toggle()
                    if showWaveform { showTray = true }
                    updateScopeSampling()
                }
                scopeToggle("RGB", on: showParade) {
                    showParade.toggle()
                    if showParade { showTray = true }
                    updateScopeSampling()
                }
                scopeToggle("VEC", on: showVectorscope) {
                    showVectorscope.toggle()
                    if showVectorscope { showTray = true }
                    updateScopeSampling()
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

    /// A per-scope toggle pill: tinted/filled green when on, dimmed when off — so the
    /// active scopes are visible at a glance. Drives the same @State the keys toggle.
    private func scopeToggle(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(on ? Color.white.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .foregroundStyle(on ? Color.green : .white.opacity(0.35))
        .help(label)
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
