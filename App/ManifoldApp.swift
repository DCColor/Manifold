import SwiftUI
import AppKit
import ManifoldCore

@main
struct ManifoldApp: App {
    // ⚠️ THERE IS NO ENGINE HERE ANY MORE, AND THAT IS THE POINT. `@StateObject private var engine
    // = FrameEngine()` used to live on this line, giving the whole app ONE playback engine that
    // every window shared. Windows are independent decks now: ContentView owns its own engine, so
    // a second window is a second deck rather than a second view onto the first one's transport.
    // See WindowDeck.swift for the registration seam that keeps the app-wide hooks coherent.
    //
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
            ContentView()
                .frame(minWidth: 720, minHeight: 460)
                // `.onOpenURL` MOVED DOWN INTO ContentView, because it needs an engine and this
                // scope no longer has one. SwiftUI delivers an opened URL to a window in the
                // group, and the modifier now sits on the view that owns that window's deck — so
                // the file lands in the engine belonging to the window that received it. See the
                // measured multi-window behaviour in docs/MULTIWINDOW_FINDINGS.md.
                //
                // Gate the whole app behind the license/trial. Offline users with a valid
                // embedded-verified key are usable and never see the gate — network is never the gate.
                .licenseGate(license)
                .task { await license.bootstrap() }
                // Update NOTIFIER (see UpdateChecker). A `.task` and not `init()`: this must run
                // after the window is up and must never delay startup. Silent unless there is
                // genuinely something newer — and silent on every failure, so a tester with no
                // network sees nothing at all. Guarded to one check per process.
                .task { await UpdateChecker.shared.checkAtLaunch() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // REPLACING, not adding: `.appInfo` is the "About Manifold" slot at the top of the app
            // menu, and leaving the stock item in place alongside ours would put two About entries
            // there. The stock panel reads the same bundle keys this one does, so nothing is lost
            // by taking the slot — what is gained is the attributions the stock panel cannot show.
            CommandGroup(replacing: .appInfo) {
                Button("About Manifold") { openWindow(id: AboutScene.windowID) }
                // Directly under About, where macOS apps conventionally put it. Runs the SAME check
                // the launch path runs, but reports "up to date" as well — the one path where
                // silence would be wrong, because the user asked.
                Button("Check for Updates…") { UpdateChecker.shared.checkFromMenu() }
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
            // The View menu: raster size (⌘1–⌘4, ⌘0) — how large the picture is drawn, as a
            // percentage of the source raster. The app's first real menu of window commands; see
            // RasterSize.swift for why it is a menu and not another item on the control bar.
            RasterSizeCommands()
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
