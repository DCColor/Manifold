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
        // Stage 2b first-light headless check — decode+convert one DNxHR frame and
        // report the center RGB. TEMPORARY, remove with FFmpegProbe.
        let probePath = "/Volumes/DCCOLOR/TEST FLIP/CS Validation Manifold/RED75_709_HQ_Full_111_DNX_HXQ.mov"
        if FileManager.default.fileExists(atPath: probePath) {
            FileHandle.standardError.write(Data("[LibavFirstLight] \(LibavFrameSource.firstLightProbe(path: probePath))\n".utf8))
        }
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
