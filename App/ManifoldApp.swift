import SwiftUI
import ManifoldCore

@main
struct ManifoldApp: App {
    @StateObject private var engine = FrameEngine()

    init() {
        // D1: prove the DeckLink SDK links and the card is reachable — enumerate + log at startup.
        DeckLinkService.shared.logDevicesAtStartup()
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
