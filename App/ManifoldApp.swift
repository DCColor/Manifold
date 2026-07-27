import SwiftUI
import AppKit
import ManifoldCore

@main
struct ManifoldApp: App {
    @StateObject private var engine = FrameEngine()
    // App-layer licensing (see LicenseManager.swift). Owns the trial + license state and the gate.
    @StateObject private var license = LicenseManager.shared
    // Opens the About scene below. `openWindow` and not `orderFrontStandardAboutPanel`, because the
    // standard panel cannot host the attributions — see AboutWindow.swift.
    @Environment(\.openWindow) private var openWindow

    init() {
        // ⚠️ BEFORE THE FIRST LOG LINE, AND THAT ORDERING IS THE POINT. The tap reserves a head
        // section that is never evicted so the [BUILD] banner survives a long session — which is
        // only worth doing if the tap is already listening when that banner is emitted. Installed
        // here rather than in a scene, because a scene body runs after startup logging has begun.
        LogTap.shared.install()
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
                    // Closes the gap for EVERY live source through the one entry point the file
                    // importer also uses, so the two paths cannot drift as sources are added.
                    LiveSource.retireActive()
                    engine.load(url: url, autoplay: Preferences.shared.autoplayOnLoad)
                }
                // Gate the whole app behind the license/trial. Offline users with a valid
                // embedded-verified key are usable and never see the gate — network is never the gate.
                .licenseGate(license)
                .task { await license.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // REPLACING, not adding: `.appInfo` is the "About Manifold" slot at the top of the app
            // menu, and leaving the stock item in place alongside ours would put two About entries
            // there. The stock panel reads the same bundle keys this one does, so nothing is lost
            // by taking the slot — what is gained is the attributions the stock panel cannot show.
            CommandGroup(replacing: .appInfo) {
                Button("About Manifold") { openWindow(id: AboutScene.windowID) }
            }
            // Discoverable path to the License state — opens Settings (⌘,), where the License section lives.
            CommandGroup(after: .appSettings) {
                SettingsLink { Text("License…") }
                // Always enabled — opens the Vizrt NDI runtime download page (also useful for
                // reinstalling/updating). Single URL source of truth: NDIService.runtimeInstallURL.
                Button("Install NDI Runtime…") {
                    NSWorkspace.shared.open(NDIService.runtimeInstallURL)
                }
                // In the app menu and NOT behind a debug gate: the people who need it are the
                // testers, and they are on whichever configuration we shipped them.
                Button("Export Diagnostics…") { DiagnosticsExporter.shared.begin() }
            }
        }

        // The standard macOS Settings window (⌘,).
        Settings {
            SettingsView()
        }

        // About Manifold. A single-instance `Window` rather than a `WindowGroup`: choosing About
        // twice should raise the window that is already open, not stack a second copy of it.
        // NOT gated behind the license gate — attribution and licence text must be readable
        // whatever the app's own licensing state is.
        Window("About Manifold", id: AboutScene.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}
