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
    // ⚠️ OBSERVED HERE, AND THAT IS WHAT MAKES File ▸ Open Recent UPDATE. The commands below are
    // rebuilt when state this scene observes changes; an unobserved read of `RecentFiles.shared`
    // inside the menu would render once and then never follow the list.
    @StateObject private var recents = RecentFiles.shared
    // ⚠️ OBSERVED HERE FOR THE SAME REASON `recents` IS, and it is the only thing that makes the
    // conditional Pro Video Formats item below appear/disappear. Reading
    // `ProVideoWorkflow.shared.availability` inside the menu closure WITHOUT this property would
    // evaluate once — at launch, while the probe is still `.unknown` — and never follow it.
    @StateObject private var proVideo = ProVideoWorkflow.shared
    // Observed for the same reason again — the NDI runtime item below is now conditional too.
    @StateObject private var ndi = NDIService.shared
    // Opens the About scene below. `openWindow` and not `orderFrontStandardAboutPanel`, because the
    // standard panel cannot host the attributions — see AboutWindow.swift.
    @Environment(\.openWindow) private var openWindow

    init() {
        // ⚠️ BEFORE THE FIRST LOG LINE, AND THAT ORDERING IS THE POINT. The tap reserves a head
        // section that is never evicted so the [BUILD] banner survives a long session — which is
        // only worth doing if the tap is already listening when that banner is emitted. Installed
        // here rather than in a scene, because a scene body runs after startup logging has begun.
        LogTap.shared.install()
        #if DEBUG
        // ⚠️ THE ONLY THING THAT TURNS [LIVECLOCK] ON, AND IT IS `#if DEBUG` ON PURPOSE.
        //
        // ManifoldCore cannot gate its own telemetry at compile time: `MANIFOLD_TELEMETRY` is
        // defined unconditionally in Package.swift because Xcode maps a package's configuration by
        // NAME, so `#if DEBUG || MANIFOLD_TELEMETRY` is always true there and a Release build was
        // emitting `[LIVECLOCK]` at 1 Hz for every live source. The decision has to be made HERE,
        // in the app, which is the only layer that can tell the configurations apart.
        //
        // ORDERING IS LOAD-BEARING: `LiveClock` captures this at CONSTRUCTION, so it must be set
        // before any live source can connect. This is app `init`, before any scene body has run and
        // long before a transport exists, which is as early as the app has.
        LiveClock.enableTelemetry()
        #endif
        // ⚠️ OUTSIDE THE `#if DEBUG` ABOVE, ON PURPOSE. The rate pin is runtime-gated rather than
        // compile-gated so the same experiment can be run in a Release build — see
        // `AudioMirrorRatePin` for why that trade was made and what it costs. Touching it here
        // latches the preference and prints the armed line before any transport exists, rather
        // than at the first audio buffer.
        _ = AudioMirrorRatePin.isEnabled
        // FIRST LINE OF EVERY LOG, before anything else can emit. A log that cannot state which
        // build produced it is not evidence — see BuildInfo for why this is derived rather than
        // assumed, and why the "not valid for measurement" warning keys on -Onone and not on DEBUG.
        BuildInfo.logAtStartup()
        // D1: prove the DeckLink SDK links and the card is reachable — enumerate + log at startup.
        DeckLinkService.shared.logDevicesAtStartup()
        // …and restore the operator's manual output-mode pick BEFORE any source can be opened, so a
        // file or stream arriving early cannot briefly establish the card at a mode the operator
        // already overrode. Cheap and synchronous: one UserDefaults read.
        DeckLinkService.shared.restoreManualMode()
        // Opt this PROCESS in to Apple's professional-video-workflow plug-in decoders and format
        // readers. See ProVideoWorkflow.swift for what it costs (12–15 ms, hence off the main
        // actor) and why "we called it" is not the same as "they are installed".
        //
        // ⚠️ WHY HERE. The registration is documented as PER-PROCESS and must precede any file
        // open. `init()` runs before the first scene body — and therefore before ContentView's
        // stored property initialisers, which the licensing entry in docs/BUGS.md establishes run
        // earlier than the scene's `.task` modifiers are even attached. So this is ahead of
        // `.onOpenURL`, ahead of the Open dialog, and ahead of Open Recent: every route media can
        // arrive by. It sits with the other two process-wide installs above for that reason.
        //
        // ⚠️ AND `init()` ALONE IS NOT THE ORDERING GUARANTEE, BECAUSE THE WORK IS OFF-MAIN.
        // Starting early makes the race vanishingly unlikely; it does not make it impossible. The
        // guarantee is `await ProVideoWorkflow.shared.ready()` on the open path, which is what
        // actually orders registration before the first decode.
        //
        // ⚠️ THE HEADER'S NETWORK-FACING CAVEAT — DECIDED, NOT ASSUMED. Apple warns that opting in
        // "is not recommended for network-facing applications such as web browsers, messaging
        // clients, mail clients". Manifold is a QC tool and is squarely the intended audience, but
        // it also carries NDI, WHEP, SRT and HLS, so the caveat is answered per transport rather
        // than waved off. Registration is process-global: it cannot be scoped to the file path.
        //
        //   NDI   — STRUCTURAL. No VideoToolbox decoder is ever created. The NDI SDK hands back
        //           CVPixelBuffers and NDIService converts them; there is no codec lookup to reach
        //           a plug-in with.
        //   SRT   — STRUCTURAL. The only decoder is LiveVideoDecoder, whose format description
        //   WHEP    comes from CMVideoFormatDescriptionCreateFromH264ParameterSets — which can
        //           only ever produce 'avc1', a codec built into VideoToolbox. The fourCC is
        //           chosen by US from the transport's payload type and is never read off the wire,
        //           so no stream can name a plug-in codec into existence. (SRTClient.swift's own
        //           comment records that the access-unit builder is H.264-only by construction.)
        //
        //   HLS   — ⚠️ NOT STRUCTURAL, AND SAYING OTHERWISE WOULD BE FALSE. HLSClient plays
        //           through AVPlayer, which selects a decoder from what the STREAM declares. With
        //           the plug-ins registered process-wide, a manifest declaring a plug-in fourCC
        //           could in principle reach one. What bounds it is narrower than structure: HLS
        //           carries H.264/HEVC by spec, the URL is typed by the user rather than followed
        //           from a document, and the plug-ins are Apple-signed bundles from an Apple
        //           package. That is a real residual, accepted knowingly, and it is the thing to
        //           re-examine if HLS ever starts following URLs it was not handed directly.
        ProVideoWorkflow.shared.beginRegistrationAtLaunch()
        // Filesystem presence only — NOT `refreshRuntimeStatus()`, which would dlopen the runtime
        // and call NDIlib_initialize() at launch for every user. See NDIService.runtimePresence.
        NDIService.shared.probeRuntimePresenceAtLaunch()
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
                // One-shot migration of legacy inline SRT passphrases into the Keychain. A `.task`
                // for the same reason the update check is one — it must never delay startup — and
                // MOVED OUT OF `StreamBookmarkStore.init` for a stronger reason than that: the
                // store is built by `ContentView`'s stored property initialiser, which runs before
                // these modifiers are even attached, so a Keychain WRITE sat ahead of the first
                // frame in a place no restructuring of the licensing path could reach. Guarded to
                // one attempt per process, because this closure runs once per window.
                .task { await StreamBookmarkStore.shared.migratePassphrasesAtLaunch() }
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
                // Downloads Vizrt's macOS NDI runtime installer. It is a DIRECT .pkg download,
                // not a page: see NDIService.runtimeInstallURL, which is the single source of
                // truth for the URL and carries the measured evidence for which link this has to
                // be.
                //
                // ⚠️ WAS UNCONDITIONAL UNTIL 2026-09-09, AND THE OLD REASONING IS KEPT BECAUSE IT
                // IS STILL TRUE — JUST OUTWEIGHED. It read: "Always enabled — also useful for
                // reinstalling/updating." A direct .pkg link genuinely does stay useful when you
                // already have the runtime, which a support PAGE does not. What changed is that a
                // second item of this kind arrived (Pro Video Formats below), and two items of the
                // same kind following two different rules is worse than either rule applied to
                // both. Weighed against that: deliberately reinstalling the NDI runtime is rare,
                // and someone doing it can reach Vizrt's site — or, now, Preferences, which keeps
                // a button in BOTH states precisely so this path did not disappear, only move.
                //
                // ⚠️ HIDDEN WHILE `.unknown` TOO, same rule as Pro Video Formats: the probe lands a
                // few ms after launch, and flashing the item on screen and removing it on every
                // launch of a machine that HAS the runtime is worse than appearing a moment late on
                // one that does not.
                //
                // ⚠️ KEYED ON `runtimePresence`, NOT `runtimeAvailable`. The latter is a Bool that
                // is `false` until something calls `refreshRuntimeStatus()`, which does not happen
                // at launch by design — so it would show this item on EVERY machine until the user
                // visited Settings. See NDIService.runtimePresence.
                if ndi.runtimePresence == .notInstalled {
                    Button("Install NDI Runtime…") {
                        NSWorkspace.shared.open(NDIService.runtimeInstallURL)
                    }
                }
                // Same rule as the NDI item above — offered only when we know it is missing,
                // hidden while `.unknown`. The two are deliberately identical in shape: these are
                // the app's only two "you need this" menu items, and one rule applied to both
                // beats a rule each.
                //
                // MEASURED that the conditional works at all — see `proVideo`'s declaration for
                // why the observed property must exist. The commands closure evaluates with
                // `.unknown` and then RE-EVALUATES once the probe lands, confirmed in both
                // directions: `.unknown` → `.installed` on this machine, and `.unknown` →
                // `.notInstalled` with the probe pointed at a missing directory.
                if proVideo.availability == .notInstalled {
                    Button("Download Pro Video Formats…") {
                        // Same URL the Preferences button opens — ProVideoWorkflow.downloadURL is
                        // the single source of truth, exactly as NDIService.runtimeInstallURL is
                        // for the item above. Not duplicated here.
                        NSWorkspace.shared.open(ProVideoWorkflow.downloadURL)
                    }
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
                // Directly under Open…, where a Mac user looks for it. A SwiftUI command rather
                // than an item inserted into `NSApp.mainMenu`: the insertion approach was built,
                // measured, and RETIRED — SwiftUI removes a foreign item the first time the menu
                // bar is displayed, so it passed every in-process check and was never once on
                // screen. The measurement is written up on `OpenRecentMenu`.
                OpenRecentMenu(recents: recents)
            }
            // The View menu: raster size (⌘1–⌘4, ⌘0) — how large the picture is drawn, as a
            // percentage of the source raster. The app's first real menu of window commands; see
            // RasterSize.swift for why it is a menu and not another item on the control bar.
            RasterSizeCommands()
            #if DEBUG
            // ── ⚠️ GATED: A MENU BAR ITEM IS A CATEGORICALLY MORE EXPOSED AFFORDANCE ────────────
            //
            // Every dev affordance before this one was a hidden keystroke — undiscoverable without
            // being told the chord, and harmless to someone who was not. A TOP-LEVEL MENU is the
            // opposite: it is in the menu bar, in front of anyone who looks, and behind it sit a
            // tone generator that REPLACES PROGRAMME AUDIO and a recorder that WRITES FILES TO THE
            // DESKTOP. `#if DEBUG` does not cover this — Profile defines DEBUG and every build cut
            // to date has been Profile, so "DEBUG-gated" means "in front of every tester".
            //
            // So the menu is opt-in at launch. Nothing behind it changed; only whether it exists.
            if DebugMenuGate.isEnabled {
            //
            // The ⌃⌥A binding for this lives in `ContentView.syntheticLiveShortcuts` as a hidden
            // Button, which fires only when that view is mounted AND nothing upstream has already
            // claimed the chord. That space is crowded — ⌃⌥T, for instance, is the scope tray — and
            // a chord that loses the race fails SILENTLY, as a system beep. A CommandMenu is bound
            // to the application, not to whatever has focus, so it cannot be shadowed and cannot be
            // missed. When a diagnostic has to be reachable on demand during a live capture, this
            // is the shape it should take.
            //
            // `#if DEBUG`, matching the trigger it drives — Profile carries DEBUG, so this is
            // present in the builds testers actually run, and absent from Release.
            CommandMenu("Debug") {
                NDIAudioToneTestCommand()
                NDIAudioGroupedCommand()
                NDIAudioLeadCommand()
                Divider()
                NDIAudioWAVCaptureCommand()
            }
            }
            #endif
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

#if DEBUG
/// ── WHETHER THE DEBUG MENU IS IN THE MENU BAR AT ALL ─────────────────────────────────────────
///
/// Two ways in, because the two use cases have opposite ergonomics and the app already has a
/// precedent for each:
///
///   **1. A preference — the primary one.**
///
///         defaults write com.graviton.manifold manifold.debugMenu -bool YES
///
///      Survives relaunch, works with an ordinary double-click launch, and is turned off with
///      `defaults delete`. This is the one for the case that has to keep working: somebody on
///      different hardware checking whether the 250 ms desktop-audio lead is enough for THEIR
///      output device. That person is listening to a normally-launched app over a session, and
///      requiring them to run from Terminal to have the ladder would be friction on exactly the
///      workflow this gate is supposed to preserve. Same shape as
///      `DeckLinkService.audioTrimKey`, which is already documented as a `defaults write`.
///
///   **2. An environment variable — for a single run that leaves nothing behind.**
///
///         MANIFOLD_DEBUG_MENU=1 /Applications/Manifold.app/Contents/MacOS/Manifold
///
///      Matches `ScrubFrameProducer.stats` (`MANIFOLD_SCRUB_STATS`), and fits the run-from-Terminal-
///      to-capture-logs workflow. Nothing persists, so it cannot be left on by accident.
///
/// ⚠️ LATCHED ONCE, AT FIRST READ. `static let` with an initialiser closure is evaluated exactly
/// once and is thread-safe. A gate re-read per menu build could change under a running app and
/// leave half the surface live — a menu that has gone while a keyboard shortcut it owns has not.
/// The answer is fixed for the process lifetime.
///
/// ⚠️ IT SAYS SO WHEN IT IS ON, AND NOTHING WHEN IT IS OFF. A tester who set the preference weeks
/// ago and forgot needs the log to remind them why there is a Debug menu; someone who never asked
/// for it should see no trace of the feature at all.
enum DebugMenuGate {
    static let defaultsKey = "manifold.debugMenu"
    static let environmentVariable = "MANIFOLD_DEBUG_MENU"

    static let isEnabled: Bool = {
        let viaEnvironment = ProcessInfo.processInfo.environment[environmentVariable] == "1"
        let viaPreference = UserDefaults.standard.bool(forKey: defaultsKey)
        guard viaEnvironment || viaPreference else { return false }
        NSLog("[DEBUG-MENU] enabled via %@ — the Debug menu is in the menu bar. It contains a tone "
            + "generator that REPLACES programme audio and a recorder that writes .wav files to the "
            + "Desktop. Turn it off with: defaults delete com.graviton.manifold %@",
              viaEnvironment ? "\(environmentVariable)=1" : "the \(defaultsKey) preference",
              defaultsKey)
        return true
    }()
}

/// Debug ▸ NDI Audio Tone Test — one item that cycles OFF → 1 kHz 0 dBFS → 1 kHz −6 dBFS → OFF and
/// names the state it is in.
///
/// ⚠️ A SEPARATE `View` RATHER THAN A `Button` INLINE IN THE `CommandMenu`, and that is not style.
/// The title has to track `NDIService.audioToneTestTitle`, so something has to OBSERVE the service;
/// a `@StateObject`/`@ObservedObject` cannot be declared inside a `commands` builder. Giving the
/// item its own view is what lets the menu re-title itself when the mode changes, so the menu is the
/// readout and there is no need to go and find the log line.
///
/// WHAT IT DOES: substitutes a continuous synthesised sine for NDI's pulled samples at the single
/// point where they enter `makeAudioSampleBuffer`, and changes nothing else — same buffer sizes
/// (the real 480..530 from this tick's pull), same rate and channel count, same PTS ticks, same
/// construction, same `LiveAudioSink`, same renderer. It bisects "is the desktop crackle in the
/// SAMPLES or in the PATH".
///
/// ⚠️ The tap tees BEFORE the renderer, so the meters show the tone and SDI CARRIES IT if DeckLink
/// output is on. Do not leave it running into a real output.
private struct NDIAudioToneTestCommand: View {
    @ObservedObject private var ndi = NDIService.shared
    var body: some View {
        Button(ndi.audioToneTestTitle) { NDIService.shared.cycleAudioToneTest() }
            .keyboardShortcut("a", modifiers: [.control, .option])
    }
}

/// Debug ▸ Record NDI Audio to WAV — writes the EXACT bytes handed to `LiveAudioSink`, copied out
/// of the CMSampleBuffer's own block buffer at the enqueue point, to a .wav on the Desktop.
///
/// It captures whatever is in the buffers, so it serves the tone test and real NDI audio equally —
/// the filename records which was running when the capture started. This is the one instrument that
/// separates "are the bytes good" from "is the renderer playing them properly", which every
/// counter-based measurement so far has been unable to do.
///
/// Same `@ObservedObject` reasoning as the item above: the title has to track the service so the
/// menu can show the elapsed time and size while recording.
/// Debug ▸ Renderer Input — TEST 2. Toggles NDI's renderer input between its native shape
/// (variable 480..530 samples at ~92 Hz) and WHEP's (fixed 960 at 50 Hz), which is known good
/// through this exact renderer. A/B it live; the samples are identical either way, only the
/// packaging changes.
private struct NDIAudioGroupedCommand: View {
    @ObservedObject private var ndi = NDIService.shared
    var body: some View {
        Button(ndi.audioGroupedTitle) { NDIService.shared.toggleGroupedAudio() }
    }
}

/// Debug ▸ Desktop Audio Lead — cycles 40 / 150 / 300 / 400 / 600 ms, re-anchoring the timebase on
/// the next pull rather than requiring a reconnect.
///
/// This is the one that matters: the renderer reports
/// `hasSufficientMediaDataForReliablePlaybackStart = NO` for entire sessions at 40 ms, while WHEP
/// (400 ms) and SRT (250 ms) run clean through the same renderer. Watch `sufficientForStart` and
/// `queue` in the per-second `[NDI-AUDIO] renderer:` line as you step it.
private struct NDIAudioLeadCommand: View {
    @ObservedObject private var ndi = NDIService.shared
    var body: some View {
        Button(ndi.audioLeadTitle) { NDIService.shared.cycleDesktopAudioLead() }
    }
}

private struct NDIAudioWAVCaptureCommand: View {
    @ObservedObject private var ndi = NDIService.shared
    var body: some View {
        Button(ndi.audioCaptureTitle) { NDIService.shared.toggleAudioWAVCapture() }
    }
}
#endif
