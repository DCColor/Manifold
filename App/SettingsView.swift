//
//  SettingsView.swift — Manifold ▸ Settings… (⌘,), redesigned 2026-10-27 (docs/SETTINGS_REDESIGN.md).
//
//  A toolbar-tabbed window, the standard macOS Settings layout, in the Keyboard Shortcuts window's visual language:
//  system body text for rows, caption-size secondary text for what a row does, section headers, nothing coloured but
//  the highlight and the orange "you can fix this" status. Resizable within bounds, and each pane opens at its own
//  content's height at the width the user left it: `SettingsWindowFit`, because the Settings scene does neither.
//
//  ⚠️ EVERY ROW KEEPS ITS KEY AND DEFAULT. The panes regroup what the single form held; no `@AppStorage` key,
//  default or write path changed, except the highlight colour (new key) and the playhead colour's "Same as highlight"
//  choice (new key, written only when the user picks it). The code map is in docs/SETTINGS_REDESIGN.md §2.
//
//  ⚠️ OPENING AND BROWSING WRITES NOTHING. The selected pane lives in memory (`SettingsNavigation`), not in a defaults
//  key, so it is not remembered across launches; the system's own window-frame key is the only thing AppKit writes.
//

import SwiftUI
import AppKit
import PlayheadSlider
import ColorimetryModel

/// The panes, in toolbar order. Why these and not the brief's list: docs/SETTINGS_REDESIGN.md §3.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, files, playback, scopes, deckLink, sources, license
    #if DEBUG
    case advanced
    #endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .files: return "Files"
        case .playback: return "Playback"
        case .scopes: return "Scopes & Guides"
        case .deckLink: return "DeckLink Output"
        case .sources: return "Sources"
        case .license: return "License"
        #if DEBUG
        case .advanced: return "Advanced"
        #endif
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .files: return "folder"
        case .playback: return "play.rectangle"
        case .scopes: return "waveform.path.ecg.rectangle"
        case .deckLink: return "rectangle.connected.to.line.below"
        case .sources: return "antenna.radiowaves.left.and.right"
        case .license: return "key"
        #if DEBUG
        case .advanced: return "wrench.and.screwdriver"
        #endif
        }
    }

    /// Advanced holds debug items only, so it exists only with the debug gate on — the Keyboard Shortcuts window's
    /// debug section's own predicate.
    static var shown: [SettingsPane] {
        #if DEBUG
        return allCases.filter { $0 != .advanced || ShortcutDebugGate.showsDebugSection }
        #else
        return allCases
        #endif
    }
}

/// Which pane is showing. In memory only (see the file note); Manifold ▸ License… selects `.license` before opening.
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var pane: SettingsPane = .general
}

/// The Settings window contents (opens with ⌘,).
struct SettingsView: View {
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.pane) {
            ForEach(SettingsPane.shown) { pane in
                content(pane)
                    .formStyle(.grouped)
                    // Flexible, so the window can be resized; `SettingsWindowFit` sets the bounds and the height.
                    .frame(minWidth: SettingsWindowFit.minWidth, maxWidth: SettingsWindowFit.maxWidth,
                           minHeight: SettingsWindowFit.minHeight, maxHeight: .infinity)
                    .background(SettingsWindowFit.Probe(pane: pane))
                    .tabItem { Label(pane.title, systemImage: pane.systemImage) }
                    .tag(pane)
            }
        }
        // The rows that report system state are re-read when Settings opens — the same four reads the single form
        // made — and again when their pane is chosen, so a pane shows current state whichever way it was reached.
        .onAppear {
            SettingsRefresh.all()
            SettingsWindowFit.opening = true
        }
        .onChange(of: navigation.pane) { _, pane in SettingsRefresh.pane(pane) }
    }

    @ViewBuilder private func content(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .files: FilesSettingsPane()
        case .playback: PlaybackSettingsPane()
        case .scopes: ScopesSettingsPane()
        case .deckLink: DeckLinkSettingsPane()
        case .sources: SourcesSettingsPane()
        case .license: Form { LicenseSettingsSection() }
        #if DEBUG
        case .advanced: AdvancedSettingsPane()
        #endif
        }
    }
}

/// THE WINDOW'S SIZE: RESIZABLE WITHIN BOUNDS, EACH PANE AT ITS CONTENT'S HEIGHT.
///
/// ⚠️ APPKIT, BECAUSE SWIFTUI'S SETTINGS SCENE DOES NEITHER. MEASURED 2026-10-27 (docs/SETTINGS_REDESIGN.md §5): with
/// flexible pane frames and `.windowResizability(.contentMinSize)`, every pane opened at the same 900 × 450 and the window
/// refused every resize. A grouped Form is a scroll view, which reports no content height to the scene; and SwiftUI
/// clears the window's resizable flag again within a second of anything else setting it.
///
/// So when a pane comes on screen, its probe (a view behind the pane) sets the window's height to the pane's content
/// (the Form's document height plus the title bar and toolbar, clamped to the screen), and the window is kept resizable
/// between `minWidth` and `maxWidth`, observing the style mask and putting the flag back when SwiftUI takes it away. The
/// width is the user's, kept across panes; Settings opens at `idealWidth`. Only the style mask, the size limits and the
/// frame are touched — never the delegate, which SwiftUI owns (WindowSizer.swift's note on what replacing it does).
@MainActor
enum SettingsWindowFit {
    static let minWidth: CGFloat = 560, idealWidth: CGFloat = 640, maxWidth: CGFloat = 1000
    static let minHeight: CGFloat = 240
    /// Set when Settings opens: the next fit also sets the opening width.
    static var opening = true

    private static weak var keptWindow: NSWindow?
    private static var maskObservation: NSKeyValueObservation?

    /// Resizable, within the width bounds. Re-applied whenever SwiftUI changes the style mask.
    static func keepResizable(_ window: NSWindow) {
        applyLimits(window)
        guard keptWindow !== window else { return }
        keptWindow = window
        maskObservation = window.observe(\.styleMask) { window, _ in
            // KVO arrives on the thread that changed the mask: SwiftUI's, the main thread.
            MainActor.assumeIsolated {
                guard !window.styleMask.contains(.resizable) else { return }
                DispatchQueue.main.async { applyLimits(window) }
            }
        }
    }

    private static func applyLimits(_ window: NSWindow) {
        if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let min = NSSize(width: minWidth, height: Swift.max(window.minSize.height, minHeight + chrome))
        let max = NSSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
        if window.minSize != min { window.minSize = min }
        if window.maxSize != max { window.maxSize = max }
    }

    struct Probe: NSViewRepresentable {
        let pane: SettingsPane
        func makeNSView(context: Context) -> ProbeView { ProbeView() }
        func updateNSView(_ view: ProbeView, context: Context) {}
    }

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After SwiftUI has finished laying the pane out and sizing the window for its tab.
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }

        func fit() {
            guard let window, let scroll = paneScrollView(), let document = scroll.documentView else { return }
            SettingsWindowFit.keepResizable(window)
            var frame = window.frame
            if SettingsWindowFit.opening {
                SettingsWindowFit.opening = false
                // The document's height depends on the width it wraps at: lay out at the opening width first.
                frame.size.width = SettingsWindowFit.idealWidth
                window.setFrame(frame, display: false)
                window.contentView?.layoutSubtreeIfNeeded()
                frame = window.frame
            }
            let chrome = window.frame.height - window.contentLayoutRect.height
            let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 1200
            let height = min(max(document.frame.height + chrome, window.minSize.height), screen)
            frame.origin.y += frame.height - height      // keep the top edge where it is
            frame.size.height = height
            window.setFrame(frame, display: true, animate: false)
            NSLog("[SETTINGS] pane %@: content %.0f pt + title bar and toolbar %.0f → window %.0f×%.0f",
                  window.title, document.frame.height, chrome, frame.width, frame.height)
        }

        /// The visible pane's Form: the largest scroll view in the window that is on screen.
        private func paneScrollView() -> NSScrollView? {
            var found: [NSScrollView] = []
            func walk(_ v: NSView) {
                if let s = v as? NSScrollView, !s.isHiddenOrHasHiddenAncestor { found.append(s) }
                v.subviews.forEach(walk)
            }
            window?.contentView.map(walk)
            return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
    }
}

/// System state shown in Settings. Detection is lazy, so each read happens when the row is about to be seen.
@MainActor
enum SettingsRefresh {
    static func all() {
        // NDI is relaunch-only; DeckLink card presence updates live via this re-enumeration. Pro Video Formats is
        // display only — registration is per-process and already happened, so a package installed mid-session
        // needs a relaunch (its caption says that).
        NDIService.shared.refreshRuntimeStatus()
        DeckLinkService.shared.refreshDevices()
        ProVideoWorkflow.shared.refresh()
        // The default handlers are system state, not ours: they can change in Finder while Settings is shut.
        DefaultHandlerStatus.videoHandlers.forEach { $0.refresh() }
    }

    static func pane(_ pane: SettingsPane) {
        switch pane {
        case .files: DefaultHandlerStatus.videoHandlers.forEach { $0.refresh() }
        case .deckLink: DeckLinkService.shared.refreshDevices()
        case .sources:
            NDIService.shared.refreshRuntimeStatus()
            ProVideoWorkflow.shared.refresh()
        default: break
        }
    }
}

// MARK: - Shared row helpers

/// A row's explanation: caption size, secondary, under the row it explains (the Keyboard Shortcuts window's subtitle).
///
/// ⚠️ SETTINGS FOLLOWS THE SYSTEM APPEARANCE: highlight-coloured TEXT here is `Color.appYellowText` (the darker variant in
/// light), never `Color.appYellow`, which is 1.3:1 on white at the default (docs/SETTINGS_REDESIGN.md §4).
private struct SettingsCaption: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
    Binding(get: { ScopeColorCodec.color(fromHex: hex.wrappedValue) },
            set: { hex.wrappedValue = ScopeColorCodec.hex(from: $0) })
}

private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

/// Consistent labeled slider row with a trailing value readout.
private func sliderRow(_ label: String, _ value: Binding<Double>,
                       in range: ClosedRange<Double>, readout: String) -> some View {
    LabeledContent(label) {
        HStack(spacing: 8) {
            Slider(value: value, in: range).frame(width: 160)
            Text(readout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Environment(\.openWindow) private var openWindow

    // @AppStorage here drives the picker and persists the choice, writing the SAME
    // "controlDisplayMode" key WindowChrome seeds each window from. This is currently the only
    // control surface for overlay-vs-docked, which is why WindowChrome adopts external writes to
    // that key — without that, flipping this picker would change nothing until the next window was
    // opened. See the observer comment in WindowChrome.
    @AppStorage("controlDisplayMode") private var controlModeRaw: String = ControlDisplayMode.overlay.rawValue

    // ── RASTER SIZE: THE SEED, NOT A REMOTE CONTROL ─────────────────────────────────────────
    //
    // The SAME key each window's `WindowChrome` seeds its raster state from, with the app's usual
    // last-writer-wins semantics — so this picker shows the last size any window was set to, and
    // sets what the NEXT window opens at.
    //
    // ⚠️ IT DELIBERATELY DOES NOT REACH OPEN WINDOWS, and that is the opposite of the "Controls"
    // picker above. That one flips every open window because it is the ONLY control surface
    // overlay-vs-docked has, and `WindowChrome` adopts external writes to its key to stop it reading
    // as dead. Raster size has a per-window control (the View menu), and `WindowChrome`'s own note
    // spells out the consequence: adopting a global write would stomp a window's local choice. Two
    // windows deliberately set to different sizes must survive a visit to Settings.
    @AppStorage(RasterSize.defaultsKey) private var rasterDefault: RasterSize = .automatic

    private var highlight: Binding<Color> {
        Binding(get: { ScopeColorCodec.color(fromHex: AppHighlight.shared.hex) },
                set: { AppHighlight.shared.set(ScopeColorCodec.hex(from: $0)) })
    }

    var body: some View {
        Form {
            Section("Appearance") {
                ColorPicker("Highlight color", selection: highlight, supportsOpacity: false)
                SettingsCaption("Used for the playhead, controls, on-picture overlays and override text.")
                if AppHighlight.shared.isNearLiveGreen {
                    // Green is the live colour and no setting changes it (AppYellow's note).
                    SettingsCaption("Live states (DeckLink output, a connected stream) also use green.", color: .orange)
                }
                if AppHighlight.shared.hex != AppYellow.hex {
                    Button("Use Default Highlight") { AppHighlight.shared.set(AppYellow.hex) }
                }
            }

            Section("Windows") {
                Picker("Controls", selection: $controlModeRaw) {
                    ForEach(ControlDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)

                Picker("Raster size for new windows", selection: $rasterDefault) {
                    ForEach(RasterSize.settingsChoices) { size in
                        Text(size.menuTitle).tag(size)
                    }
                }
                SettingsCaption("How large the picture is drawn, as a percentage of the source raster — 100% is one source pixel per source pixel, so a 3840×2160 file fills 1920×1080 points on a Retina display. Set it per window in the View menu (⌘1–⌘4, ⌘0); this is what a new window starts at, and it follows the last window you set.")
            }

            // Keyboard Shortcuts stays its own window (Robbie, 2026-10-27); this is a way to it.
            Section("Keyboard") {
                LabeledContent("Keyboard shortcuts") {
                    Button("Open Keyboard Shortcuts…") { openWindow(id: KeyboardShortcutsScene.windowID) }
                }
                SettingsCaption("Also in the Manifold and Help menus.")
            }
        }
    }
}

// MARK: - Files

/// Opening files and exporting frames: what happens to a file on the way in and a frame on the way out.
private struct FilesSettingsPane: View {
    @AppStorage(OpenDestination.defaultsKey) private var openDestination: OpenDestination = .thisWindow

    // For reactive display of the chosen export folder (writes go via Preferences).
    @AppStorage("exportFolderBookmark") private var exportFolderBookmark = Data()

    var body: some View {
        Form {
            Section("Opening Files") {
                Picker("Open files in", selection: $openDestination) {
                    ForEach(OpenDestination.allCases) { destination in
                        Text(destination.label).tag(destination)
                    }
                }
                SettingsCaption("Applies to Open… (⌘O) and the Open button. Dragging a file onto a window's picture always replaces that window, and an empty window is always re-used rather than left behind.")

                // ── DEFAULT APP FOR VIDEO TYPES ─────────────────────────────────────────────
                //
                // With "Open files in", because this is the file-opening cluster — where someone looks
                // for it. Built in the Sources pane's idiom instead: rows reporting system state, an
                // action next to each, re-read on appear.
                //
                // ⚠️ THREE ROWS, THREE BUTTONS, THREE DECISIONS — AND NO CLAIM-ALL. Taking MXF is
                // an easy call (on a stock Mac nothing opens it well; QuickTime Player claims it
                // through public.movie and then cannot play it). Taking .mov or .mp4 is not: on a
                // working editorial machine those usually point somewhere on purpose. One control
                // that took all three would make the easy call and the contested ones with the
                // same click. Each row names its current holder so the choice is made with the
                // consequence in view.
                //
                // ⚠️ BUTTONS AND NOT TOGGLES, because there is no API to give an association BACK.
                // NSWorkspace can set a default; it cannot clear one. A checkbox that could be
                // ticked but never unticked would be describing a capability this app does not
                // have — the caption under the group says where the reverse actually lives.
                if !DefaultHandlerStatus.videoHandlers.isEmpty {
                    ForEach(DefaultHandlerStatus.videoHandlers) { handler in
                        DefaultHandlerRow(status: handler)
                    }
                    // ── ONE CAPTION FOR THE GROUP, NOT ONE PER ROW ──────────────────────────
                    // The per-row captions carry what differs (who holds the type, how many apps
                    // want it, how a claim went). This paragraph is a property of the MECHANISM
                    // and is identical for all three, so printing it three times would read as
                    // three separate warnings about three separate problems rather than one fact
                    // about how macOS file associations work.
                    SettingsCaption("Manifold can take an association, but it can't hand it back — to undo one, select a file of that type in the Finder, press ⌘I, and change “Open with”.")
                }
            }

            Section("Frame Export") {
                LabeledContent("Folder") {
                    Text(Preferences.displayPath(forBookmark: exportFolderBookmark))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") { chooseExportFolder() }
                    if !exportFolderBookmark.isEmpty {
                        Button("Use Desktop") { Preferences.shared.clearExportFolder() }
                    }
                }
            }
        }
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for exported frames"
        if panel.runModal() == .OK, let url = panel.url {
            Preferences.shared.setExportFolder(url)
        }
    }
}

// MARK: - Playback

private struct PlaybackSettingsPane: View {
    // Default OFF — see the declaration in `Preferences`, which also states exactly who inherits the
    // new default and who keeps their own value. Both declarations must agree: the one that renders
    // the toggle decides what an untouched key shows.
    @AppStorage("autoplayOnLoad") private var autoplayOnLoad: Bool = false
    // The playhead's look, app-wide. Same keys and defaults as `TransportScrubber` (both read
    // `PlayheadStyle`), and written only here. The colour key is optional because its absence means
    // "follow the highlight" (`PlayheadStyle.followsHighlight`).
    @AppStorage(PlayheadStyle.defaultsKey) private var playheadStyle: PlayheadStyle = PlayheadStyle.defaultStyle
    @AppStorage(PlayheadStyle.colorDefaultsKey) private var storedLineHex: String?
    @AppStorage(PlayheadStyle.followsHighlightKey) private var followsHighlightChoice: Bool?

    private var follows: Binding<Bool> {
        Binding(get: { PlayheadStyle.followsHighlight(storedColor: storedLineHex, explicit: followsHighlightChoice) },
                set: { followsHighlightChoice = $0 })
    }

    /// The override's colour: the stored one, or the highlight until one is picked.
    private var customColor: Binding<Color> {
        Binding(get: {
                    ScopeColorCodec.color(fromHex: PlayheadStyle.lineHex(storedColor: storedLineHex, explicit: false,
                                                                         highlight: AppHighlight.shared.hex))
                },
                set: { storedLineHex = ScopeColorCodec.hex(from: $0) })
    }

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Autoplay on open", isOn: $autoplayOnLoad)
            }

            Section("Playhead") {
                // The playhead's look only: both styles are the same control, so a click or a drag
                // lands on the same frame in either (TransportScrubber). Applies to every window at once.
                Picker("Playhead", selection: $playheadStyle) {
                    ForEach(PlayheadStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                // Line only, as before: the Ball is the system slider's own knob and has no colour of ours.
                if playheadStyle == .line {
                    Picker("Playhead color", selection: follows) {
                        Text("Same as highlight").tag(true)
                        Text("Custom").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !follows.wrappedValue {
                        ColorPicker("Custom playhead color", selection: customColor, supportsOpacity: false)
                    }
                    SettingsCaption(follows.wrappedValue
                                    ? "The playhead uses the highlight color (General ▸ Highlight color)."
                                    : "The playhead keeps this color whatever the highlight color is.")
                }
            }
        }
    }
}

// MARK: - Scopes & Guides

private struct ScopesSettingsPane: View {
    @AppStorage("globalScopeIntensity") private var globalScopeIntensity: Double = 1.0
    @AppStorage("scopeScale") private var scopeScale: ScopeScale = .bit10

    // Framing-guide styling (defaults reproduce Pass 1's look).
    @AppStorage("guideDarkenOpacity") private var guideDarkenOpacity = 0.85
    @AppStorage("guideDarkenColor") private var guideDarkenHex = "000000"
    @AppStorage("guideLineColor") private var guideLineHex = "FFFFFF"
    @AppStorage("guideLineWidth") private var guideLineWidth = 2.0
    @AppStorage("safeLineColor") private var safeLineHex = "FFFF00"
    @AppStorage("safeLineWidth") private var safeLineWidth = 1.0
    @AppStorage("safeLineOpacity") private var safeLineOpacity = 0.75

    // Broadcast-safe styling only — the action/title percentages are framing decisions
    // and live in the guides popover, not here.
    @AppStorage("broadcastSafeColor") private var broadcastSafeHex = Preferences.defaultBroadcastSafeHex
    @AppStorage("broadcastSafeWidth") private var broadcastSafeWidth = Preferences.defaultBroadcastSafeWidth
    @AppStorage("broadcastSafeOpacity") private var broadcastSafeOpacity = Preferences.defaultBroadcastSafeOpacity

    var body: some View {
        Form {
            Section("Scopes") {
                Picker("Scope Scale", selection: $scopeScale) {
                    ForEach(ScopeScale.selectable) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                LabeledContent("Master scope intensity") {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(value: $globalScopeIntensity, in: Preferences.scopeIntensityRange)
                            .frame(width: 160)
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                    }
                }
                SettingsCaption("Each scope's own intensity and trace color are in its header, in the scopes tray.")
            }

            // Broadcast safe, then the crop guide (Aspect), then the social safe zones: the guides popover's order
            // (Robbie, 2026-10-29).
            Section("Broadcast safe zones") {
                ColorPicker("Broadcast safe zone color", selection: colorBinding($broadcastSafeHex))
                Stepper("Broadcast safe zone width: \(Int(broadcastSafeWidth)) pt",
                        value: $broadcastSafeWidth, in: 1...8, step: 1)
                sliderRow("Broadcast safe zone opacity", $broadcastSafeOpacity, in: 0.0...1.0,
                          readout: pct(broadcastSafeOpacity))
                SettingsCaption("Action- and title-safe percentages are set in the framing guides popover.")
            }

            Section("Framing Guides") {
                // Crop guide
                ColorPicker("Outside (darken) color", selection: colorBinding($guideDarkenHex))
                sliderRow("Outside opacity", $guideDarkenOpacity, in: 0.0...1.0,
                          readout: pct(guideDarkenOpacity))
                ColorPicker("Guide line color", selection: colorBinding($guideLineHex))
                Stepper("Guide line width: \(Int(guideLineWidth)) pt",
                        value: $guideLineWidth, in: 1...10, step: 1)
                // Social safe zones (the top/bottom platform keep-out lines)
                ColorPicker("Social safe zone color", selection: colorBinding($safeLineHex))
                Stepper("Social safe zone width: \(Int(safeLineWidth)) pt",
                        value: $safeLineWidth, in: 1...8, step: 1)
                sliderRow("Social safe zone opacity", $safeLineOpacity, in: 0.0...1.0,
                          readout: pct(safeLineOpacity))
            }
        }
    }
}

// MARK: - DeckLink Output

private struct DeckLinkSettingsPane: View {
    // DeckLink driver + device presence for the "DeckLink" status row. Observed so the tri-state row
    // updates when refreshDevices() publishes (called when Settings opens and when this pane is chosen).
    @ObservedObject private var dl = DeckLinkService.shared

    // DeckLink output: explicit "start output on launch" opt-in (NOT last-session persistence).
    // Shared key with DeckLinkService so it can't drift. Default off.
    @AppStorage(DeckLinkService.enableOnLaunchKey) private var deckLinkEnableOnLaunch = false
    // SDI scaling (§6.11): which modes Follow source may choose. Default HD/UHD only. DeckLinkService observes the write.
    @AppStorage(SDIOutputModeSet.defaultsKey) private var deckLinkModeSet: SDIOutputModeSet = .default
    // SDI scaling follow-up F1: how a source that is not a mode fills it. Default Fit to mode.
    @AppStorage(SDIScaling.defaultsKey) private var deckLinkScaling: SDIScaling = .default

    var body: some View {
        Form {
            Section("Device") {
                // DeckLink — the full readiness state (driver present / version vs the output floor /
                // devices), one row per distinguishable case. The version is included in every case
                // where we have it: a driver below the floor used to show here as a bare "No device
                // detected", which is both wrong and unactionable. Driver presence and version are
                // relaunch-only (the framework load is cached); card plug/unplug is picked up on the
                // next refresh, which is why only the driver-side states carry a relaunch caption.
                let dlStatus = dl.driverStatus
                LabeledContent("DeckLink") {
                    Text(dlStatus.headline)
                        // Orange = the user can fix it by installing/updating a driver; grey = nothing
                        // is wrong with the software, there's just no card.
                        .foregroundStyle(dlStatus == .notInstalled || dlStatus.isBelowFloor
                                         || dlStatus == .versionUnreadable ? .orange : .secondary)
                }
                if dlStatus == .notInstalled || dlStatus.isBelowFloor {
                    Button(dlStatus.isBelowFloor ? "Update Desktop Video…" : "Download Desktop Video…") {
                        NSWorkspace.shared.open(DeckLinkService.driverInstallURL)
                    }
                }
                if let detail = dlStatus.detail {
                    SettingsCaption(detail)
                } else if !dl.devices.isEmpty {
                    // Ready — name the hardware (what the old single-device row showed).
                    SettingsCaption(dl.devices.map(\.displayName).joined(separator: ", "))
                }
            }

            Section("Output") {
                Toggle("Enable output on launch", isOn: $deckLinkEnableOnLaunch)
                SettingsCaption("When on, Manifold starts DeckLink output at launch if a capable device is connected. Otherwise it does nothing. Turning output on or off during a session doesn't change this setting.")
                Picker("SDI scaling", selection: $deckLinkScaling) {
                    ForEach(SDIScaling.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                SettingsCaption(deckLinkScaling == .fit
                     ? "Fit to mode: Follow source picks the mode at the source's frame rate whose size is closest to the source's, and scales the picture up or down to fill it, keeping its shape, with black around it. A source that is exactly a mode's size goes out unscaled."
                     : "1:1 pixels: Follow source picks the smallest mode at the source's frame rate that holds the picture without scaling, and outputs it 1:1 with black around it. A picture larger than every mode is scaled down to fit.")
                Picker("SDI output modes", selection: $deckLinkModeSet) {
                    ForEach(SDIOutputModeSet.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                SettingsCaption("Include DCI adds 2048×1080 and 4096×2160, to Follow source and to the output mode picker.")
            }
        }
    }
}

// MARK: - Sources

private struct SourcesSettingsPane: View {
    // NDI runtime presence for the "NDI Runtime" status row. Observed so the row updates when
    // refreshRuntimeStatus() publishes (called when Settings opens and when this pane is chosen).
    @ObservedObject private var ndi = NDIService.shared
    @ObservedObject private var pvf = ProVideoWorkflow.shared

    var body: some View {
        Form {
            Section("NDI") {
                LabeledContent("NDI Runtime") {
                    if ndi.runtimeAvailable {
                        Text("Installed" + (ndi.runtimeVersion.map { " (\($0))" } ?? ""))
                            .foregroundStyle(.secondary)
                    } else {
                        // Attention-worthy but not alarming — orange, not red.
                        Text("Not installed")
                            .foregroundStyle(.orange)
                    }
                }
                // ⚠️ PRESENT IN BOTH STATES, AND THAT IS WHAT MAKES THE CONDITIONAL MENU ITEM
                // SAFE. The app-menu item is the "you need this" surface and hides once the
                // runtime is there; this is the inspection-and-management surface, so the
                // reinstall/update path does not disappear — it moves to where someone would look
                // for it. Removing it here as well would strand anyone with a corrupt or outdated
                // runtime.
                //
                // Worded for the state rather than one label for both: "Install" is wrong when it
                // is already installed, and the difference is the whole reason the button is still
                // here in that case.
                Button(ndi.runtimeAvailable ? "Reinstall NDI Runtime…" : "Install NDI Runtime…") {
                    NSWorkspace.shared.open(NDIService.runtimeInstallURL)
                }
                SettingsCaption("After installing the NDI runtime, relaunch Manifold to enable NDI sources.")
            }

            Section("Pro Video Formats") {
                // Pro Video Formats — Apple's optional professional codec package.
                //
                // ⚠️ THIS ROW IS WORDED DIFFERENTLY FROM NDI AND DECKLINK ON PURPOSE, AND THE
                // DIFFERENCE IS NOT COSMETIC. Those two are ALL-OR-NOTHING: without the NDI
                // runtime there is no NDI at all, without the Desktop Video driver there is no
                // output at all, so "install this to use it" is the accurate sentence and orange
                // is the accurate colour — the user has a missing thing they can go and fix.
                //
                // Pro Video Formats is ADDITIVE. Every format Manifold opens today opens without
                // it. So the row says what the package ADDS and never what Manifold lacks, and it
                // is GREY IN BOTH STATES — orange here would dress an optional extra up as a
                // defect, which is the same misreading the DeckLink row avoids by using grey for
                // "nothing is wrong with the software, there's just no card".
                LabeledContent("Pro Video Formats") {
                    switch pvf.availability {
                    case .installed(let bundles):
                        Text("Installed (\(bundles.count) components)")
                            .foregroundStyle(.secondary)
                    case .notInstalled:
                        // Deliberately NOT orange. Nothing is broken.
                        Text("Not installed")
                            .foregroundStyle(.secondary)
                    case .unknown:
                        // The launch probe has not finished. Says so rather than guessing —
                        // `.unknown` is a real state, not a synonym for absent.
                        Text("Checking…")
                            .foregroundStyle(.secondary)
                    }
                }
                // Both states, same reasoning as the NDI button above — the menu item is
                // conditional, so this is the surface that keeps the reinstall path reachable.
                //
                // "Download" rather than "Install" when absent, because unlike NDI's direct .pkg
                // this opens Apple's support PAGE — the click gets you the installer, it does not
                // start one. "Reinstall" when present, matching NDI, because that is the user's
                // intent even though the first step is the same page.
                if pvf.availability != .unknown {
                    Button(pvf.availability == .notInstalled
                           ? "Download Pro Video Formats…" : "Reinstall Pro Video Formats…") {
                        NSWorkspace.shared.open(ProVideoWorkflow.downloadURL)
                    }
                }
                switch pvf.availability {
                case .installed:
                    SettingsCaption("Apple's optional package. Adds AVC-Intra, XAVC, IMX, DVCPRO HD, "
                                  + "uncompressed and ProRes RAW to the formats Manifold can open.")
                case .notInstalled:
                    SettingsCaption("Apple's optional package. Adds AVC-Intra, XAVC, IMX, DVCPRO HD, "
                                  + "uncompressed and ProRes RAW to the formats Manifold can open. Every "
                                  + "format Manifold opens today works without it. Relaunch after installing.")
                case .unknown:
                    EmptyView()
                }
                // ⚠️ TEMPORARY, AND IT MUST BE DELETED WHEN THE MXF DECODE ROUTING LANDS.
                //
                // As of today the plug-ins are REGISTERED but nothing routes to them for MXF:
                // FrameEngine's `isMXF` branch goes straight to libav, and
                // `MediaInspector.requiresLibavDecode` sends every DNx fourCC there too. So DNxHR
                // 4:4:4 still renders green whether or not this package is installed, and a row
                // that implied otherwise would be selling a fix the app has not shipped.
                //
                // The codecs listed above ARE genuinely enabled today — MEASURED: a v210 .mov goes
                // from -12906 to a working decode with registration, and nothing routes it away.
                // It is only the MXF/DNxHR half that is still pending, which is why this sentence
                // is narrow rather than a blanket "not used yet".
                SettingsCaption("MXF and DNxHR files are decoded by Manifold itself and are not affected by "
                              + "this package.")
            }
        }
    }
}

// MARK: - Advanced (debug gate only)

#if DEBUG
/// Debug items only, and READ-ONLY: each is a launch-latched `defaults` switch with its own `defaults delete` line in
/// the log, and a toggle here would be a new way to write it. Shown only with the debug gate on (`SettingsPane.shown`).
private struct AdvancedSettingsPane: View {
    var body: some View {
        Form {
            Section("Debug (read-only; shown because the Debug menu is on)") {
                LabeledContent("Debug menu") { Text("On").foregroundStyle(.secondary) }
                SettingsCaption("Turned on by \(DebugMenuGate.environmentVariable)=1 or the \(DebugMenuGate.defaultsKey) preference; read at launch.")
                LabeledContent("Live audio WAV capture") {
                    Text(LiveAudioWAVCaptureGate.isEnabled ? "Armed" : "Off").foregroundStyle(.secondary)
                }
                SettingsCaption("\(LiveAudioWAVCaptureGate.environmentVariable)=1 or the \(LiveAudioWAVCaptureGate.defaultsKey) preference; read at launch.")
                LabeledContent("DeckLink audio trim") {
                    Text(String(format: "%+.3f s", DeckLinkService.audioTrimSeconds))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                SettingsCaption("Set with defaults write, \(DeckLinkService.audioTrimKey).")
                SettingsCaption("The debug hooks' keys are listed in Keyboard Shortcuts.")
            }
        }
    }
}
#endif
