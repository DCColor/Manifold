import SwiftUI
import ManifoldCore

@main
struct ManifoldApp: App {
    @StateObject private var engine = FrameEngine()

    // Stage 2a proof-of-link: prove the vendored static libav links + bridges in
    // the real build. TEMPORARY — remove once the DNxHR decode source lands.
    // Written to stderr (unbuffered) so it's visible immediately on launch.
    init() {
        FileHandle.standardError.write(Data("[FFmpegProbe] \(FFmpegProbe.summary())\n".utf8))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .frame(minWidth: 720, minHeight: 460)
                .onOpenURL { url in
                    engine.load(url: url, autoplay: Preferences.shared.autoplayOnLoad)
                }
        }
        .windowStyle(.hiddenTitleBar)

        // The standard macOS Settings window (⌘,).
        Settings {
            SettingsView()
        }
    }
}
