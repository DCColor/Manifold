import SwiftUI
import IrisCore

struct ContentView: View {
    @ObservedObject var engine: AVPlayerEngine

    @AppStorage("controlDisplayMode") private var controlModeRaw: String = ControlDisplayMode.overlay.rawValue
    private var mode: ControlDisplayMode { ControlDisplayMode(rawValue: controlModeRaw) ?? .overlay }
    private var isDocked: Bool { mode == .docked }

    @State private var isImporterPresented = false
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    @State private var hudVisible = true
    @State private var pinned = false
    @State private var idleTask: Task<Void, Never>?

    // In docked mode the controls are always shown; in overlay they auto-hide.
    private var controlsShown: Bool { isDocked ? true : hudVisible }

    var body: some View {
        ZStack {
            VideoSurfaceView(player: engine.player)
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
        .onContinuousHover { phase in
            if case .active = phase { wakeHUD() }
        }
        .onAppear { armIdleIfNeeded() }
        .onChange(of: engine.hasMedia) { _, _ in armIdleIfNeeded() }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                engine.load(url: url)
                wakeHUD()
            }
        }
    }

    private func controls(showPin: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(timeString(isScrubbing ? scrubValue : engine.currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : engine.currentTime },
                        set: { newValue in
                            scrubValue = newValue
                            engine.scrubSeek(to: newValue)
                        }
                    ),
                    in: 0...max(engine.duration, 0.1),
                    onEditingChanged: { editing in
                        if editing {
                            scrubValue = engine.currentTime
                            isScrubbing = true
                        } else {
                            engine.exactSeek(to: scrubValue)
                            isScrubbing = false
                        }
                    }
                )

                Text(timeString(engine.duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
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

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
