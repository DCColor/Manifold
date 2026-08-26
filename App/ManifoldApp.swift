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
                // Always enabled — downloads Vizrt's macOS NDI runtime installer (also useful for
                // reinstalling/updating). It is a DIRECT .pkg download, not a page: see
                // NDIService.runtimeInstallURL, which is the single source of truth for the URL and
                // carries the measured evidence for which link this has to be.
                Button("Install NDI Runtime…") {
                    NSWorkspace.shared.open(NDIService.runtimeInstallURL)
                }
                // In the app menu and NOT behind a debug gate: the people who need it are the
                // testers, and they are on whichever configuration we shipped them.
                Button("Export Diagnostics…") { DiagnosticsExporter.shared.begin() }
            }
            // ⌘O, in the File menu directly under New Window (`.newItem` is that group), where a
            // Mac user looks for it. The app had no Open item at all: opening a file meant finding
            // the folder button on the auto-hiding control bar, or the pill on the empty state.
            //
            // Where the file LANDS is `DeckRegistry.openFromUserAction`'s decision, not this
            // button's — an empty window is re-used, otherwise the Settings preference chooses this
            // window or a new one. `from: nil` means "the key window", which is what a menu command
            // acts on.
            CommandGroup(after: .newItem) {
                Button("Open…") { DeckRegistry.shared.presentOpenPanel(from: nil) }
                    .keyboardShortcut("o", modifiers: .command)
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
        // ── NO SECOND "About Manifold", IN THE WINDOW MENU ─────────────────────────────────
        //
        // SwiftUI gives every single-instance `Window` scene an automatic Window-menu item, titled
        // with the scene's own title, so the window can be raised after it is closed. Here that put
        // a second "About Manifold" in the Window menu — a duplicate of the app-menu item above, in
        // the one menu that should list windows and nothing else.
        //
        // ⚠️ `CommandGroup(replacing: .singleWindowList) { }` DOES NOT REMOVE IT. That is the
        // obvious fix and the one the internet recommends; it was tried here and MEASURED to have
        // no effect on macOS 26 — the item survived it unchanged. `Scene.commandsRemoved()` is the
        // scene-level API for the same intent and is what actually works.
        //
        // The source was confirmed rather than assumed: renaming this scene to "ZZZPROBE" changed
        // the Window-menu entry to "ZZZPROBE", which is what proves the entry comes from the scene
        // and not from the `CommandGroup(replacing: .appInfo)` above.
        //
        // This removes ONLY this scene's automatic commands. Opening About is unaffected — that is
        // the app-menu Button, which calls `openWindow(id:)` directly.
        .commandsRemoved()
    }
}
