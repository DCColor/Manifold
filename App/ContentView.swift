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
    @State private var metalRenderer: MetalVideoRenderer? = MetalVideoRenderer()
    @State private var readoutMode: ReadoutMode = .source
    @State private var idleTask: Task<Void, Never>?

    // In docked mode the controls are always shown; in overlay they auto-hide.
    private var controlsShown: Bool { isDocked ? true : hudVisible }

    var body: some View {
        ZStack {
            ZStack {
                // AV surface stays for pump + synchronizer clock, but is covered by Metal.
                SampleBufferSurfaceView { nsView in
                    Task { @MainActor in
                        engine.attach(renderer: nsView.displayLayer.sampleBufferRenderer)
                    }
                }
                // Metal is the visible surface (opaque, drawn on top).
                if let renderer = metalRenderer {
                    MetalSurfaceView(renderer: renderer)
                }
                if isScrubbing, let preview = scrubPreviewImage {
                    Image(decorative: preview, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
                .background(.black)
                .ignoresSafeArea()

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
        .overlay(alignment: .topTrailing) {
            if showInspector && engine.hasMedia {
                InspectorPanel(metadata: engine.metadata)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showInspector)
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
        .animation(.easeInOut(duration: 0.2), value: showFileNameOverlay)
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
        }
        .onDisappear {
            engine.stop()
            metalRenderer?.stop()
        }
        .onChange(of: engine.hasMedia) { _, _ in armIdleIfNeeded() }
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

                Button { } label: { Image(systemName: "speaker.wave.2.fill") }
                    .help("Volume (coming soon)").disabled(true)
                Button { } label: { Image(systemName: "repeat") }
                    .help("Loop (coming soon)").disabled(true)
                Button { } label: { Image(systemName: "grid") }
                    .help("Guides (coming soon)").disabled(true)
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
