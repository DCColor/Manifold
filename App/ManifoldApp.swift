import SwiftUI
import ManifoldCore

@main
struct ManifoldApp: App {
    @StateObject private var engine = AVPlayerEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .frame(minWidth: 720, minHeight: 460)
                .onOpenURL { url in
                    engine.load(url: url)
                }
        }
        .windowStyle(.hiddenTitleBar)

        // The standard macOS Settings window (⌘,).
        Settings {
            SettingsView()
        }
    }
}
