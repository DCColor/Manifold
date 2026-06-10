import SwiftUI
import IrisCore

struct ContentView: View {
    @StateObject private var engine = AVPlayerEngine()
    @State private var isImporterPresented = false

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    @State private var hudVisible = true
    @State private var idleTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            VideoSurfaceView(player: engine.player)
                .background(.black)
                .ignoresSafeArea()

            VStack {
                Spacer()
                transportHUD
                    .padding(16)
            }
            .opacity(hudVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.30), value: hudVisible)

            // Drives both the window styling and the traffic-light fade.
            WindowConfigurator(buttonsVisible: hudVisible, displaySize: engine.displaySize).frame(width: 0, height: 0)
        }
        .onContinuousHover { phase in
            if case .active = phase { wakeHUD() }
        }
        .onAppear { scheduleIdle() }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                engine.load(url: url)
            }
        }
    }

    private var transportHUD: some View {
        VStack(spacing: 8) {
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
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Open…", systemImage: "folder")
                }

                Button {
                    engine.togglePlayPause()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24)
                }
                .keyboardShortcut(.space, modifiers: [])

                Spacer()
            }
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 640)
    }

    private func wakeHUD() {
        hudVisible = true
        scheduleIdle()
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(2.0))
            if !Task.isCancelled && !isScrubbing {
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
