import SwiftUI
import AppKit
import ManifoldCore

@main
struct ManifoldApp: App {
    @StateObject private var engine = FrameEngine()
    // App-layer licensing (see LicenseManager.swift). Owns the trial + license state and the gate.
    @StateObject private var license = LicenseManager.shared

    init() {
        // FIRST LINE OF EVERY LOG, before anything else can emit. A log that cannot state which
        // build produced it is not evidence — see BuildInfo for why this is derived rather than
        // assumed, and why the "not valid for measurement" warning keys on -Onone and not on DEBUG.
        BuildInfo.logAtStartup()
        // D1: prove the DeckLink SDK links and the card is reachable — enumerate + log at startup.
        DeckLinkService.shared.logDevicesAtStartup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .frame(minWidth: 720, minHeight: 460)
                .onOpenURL { url in
                    // Finder double-click / drag-to-icon is a file-open too, and it bypasses
                    // ContentView's fileImporter — so it must retire a live stream itself, or the
                    // stream keeps pushing to the renderer alongside the new file (double source).
                    // Closes the same gap for BOTH sources: NDI (previously missing here) and WHEP.
                    if NDIService.shared.isConnected { NDIService.shared.disconnect() }
                    #if DEBUG
                    if WHEPClient.shared.isConnected { WHEPClient.shared.disconnect() }
                    #endif
                    engine.load(url: url, autoplay: Preferences.shared.autoplayOnLoad)
                }
                // Gate the whole app behind the license/trial. Offline users with a valid
                // embedded-verified key are usable and never see the gate — network is never the gate.
                .licenseGate(license)
                .task { await license.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Discoverable path to the License state — opens Settings (⌘,), where the License section lives.
            CommandGroup(after: .appSettings) {
                SettingsLink { Text("License…") }
                // Always enabled — opens the Vizrt NDI runtime download page (also useful for
                // reinstalling/updating). Single URL source of truth: NDIService.runtimeInstallURL.
                Button("Install NDI Runtime…") {
                    NSWorkspace.shared.open(NDIService.runtimeInstallURL)
                }
            }
        }

        // The standard macOS Settings window (⌘,).
        Settings {
            SettingsView()
        }
    }
}
