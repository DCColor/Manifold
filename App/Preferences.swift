import SwiftUI
import AppKit

/// How the transport controls are presented.
enum ControlDisplayMode: String, CaseIterable, Identifiable {
    case overlay   // floating auto-hide HUD over the video (default)
    case docked    // fixed control bar below the video

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overlay: return "Overlay (floating)"
        case .docked:  return "Docked (fixed bar)"
        }
    }
}

/// The app's preferences, persisted automatically via @AppStorage (UserDefaults).
/// @AppStorage can't hold a custom enum directly, so we persist its raw String
/// and expose the enum on top of that raw value.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// Backing raw value that actually persists.
    @AppStorage("controlDisplayMode") private var controlModeRaw: String = ControlDisplayMode.overlay.rawValue

    /// Typed accessor used by the rest of the app.
    var controlMode: ControlDisplayMode {
        get { ControlDisplayMode(rawValue: controlModeRaw) ?? .overlay }
        set { controlModeRaw = newValue.rawValue }
    }

    @AppStorage("autoplayOnLoad") var autoplayOnLoad: Bool = true

    // Output volume (0–1), persisted across launches. Stored as Double (@AppStorage
    // has no Float). Mute is intentionally NOT persisted — always start unmuted.
    @AppStorage("playbackVolume") var playbackVolume: Double = 1.0

    // Scope arrangement (persisted across launches). Canonical declaration lives here;
    // ContentView binds the same keys via @AppStorage for SwiftUI reactivity.
    // NOTE: showReferenceLayer (⌃⌥R) is intentionally NOT persisted — it's a diagnostic
    // toggle that must always default OFF on launch, so it stays transient @State.
    // Per-slot scope selection (manifold.scope.slot0/1/2) is owned by ContentView's @AppStorage —
    // it superseded the old per-scope presence flags (showWaveform/showParade/showVectorscope).
    @AppStorage("showTray") var showTray: Bool = false

    // Scope trace intensity — multiplies the brightness-curve gain. 1.0 = current look.
    // Per-scope values combine MULTIPLICATIVELY with the global master.
    @AppStorage("waveformIntensity") var waveformIntensity: Double = 1.0
    @AppStorage("paradeIntensity") var paradeIntensity: Double = 1.0
    @AppStorage("vectorscopeIntensity") var vectorscopeIntensity: Double = 1.0
    @AppStorage("globalScopeIntensity") var globalScopeIntensity: Double = 1.0

    // Global vertical scale for the value-axis scopes (waveform/parade). Stored as the
    // enum's String raw value. Default .bit10 (the 1023 ruler read in Resolve).
    @AppStorage("scopeScale") var scopeScale: ScopeScale = .bit10

    // Framing guide (non-destructive overlay). Canonical declarations; the overlay,
    // panel, and Settings bind these same keys. Defaults reproduce Pass 1's look.
    // Which guide is active: off / a preset aspect (guideAspect) / custom (customW/H).
    @AppStorage("guideMode") var guideMode: GuideMode = .off
    @AppStorage("guideAspect") var guideAspect: Double = 2.39
    @AppStorage("customW") var customW: Double = 9
    @AppStorage("customH") var customH: Double = 16
    // Safe lines (independent of the crop guide).
    @AppStorage("safeLinesOn") var safeLinesOn: Bool = false
    @AppStorage("safeTop") var safeTop: Double = 0.10
    @AppStorage("safeBottom") var safeBottom: Double = 0.90
    // Styling (moved out of Pass 1 code constants; tunable in Settings).
    @AppStorage("guideDarkenOpacity") var guideDarkenOpacity: Double = 0.85
    @AppStorage("guideDarkenColor") var guideDarkenColorHex: String = "000000"
    @AppStorage("guideLineColor") var guideLineColorHex: String = "FFFFFF"
    @AppStorage("guideLineWidth") var guideLineWidth: Double = 2
    @AppStorage("safeLineColor") var safeLineColorHex: String = "FFFF00"
    @AppStorage("safeLineWidth") var safeLineWidth: Double = 1
    @AppStorage("safeLineOpacity") var safeLineOpacity: Double = 0.75

    // Broadcast safe zones (SMPTE-style nested action/title boxes + centre cross).
    // ORTHOGONAL to guideMode — these coexist with any aspect/social crop guide, so
    // they're an independent flag, not a fourth GuideMode case. Percentages are stored
    // as FRACTIONS of the video rect (0.90 = 90%), matching safeTop/safeBottom.
    // Defaults are single-sourced below so the @AppStorage declarations at every
    // binding site can't drift apart.
    static let defaultBroadcastActionPct = 0.90
    static let defaultBroadcastTitlePct = 0.80
    static let defaultBroadcastSafeHex = "FFFFFF"
    static let defaultBroadcastSafeWidth = 1.0
    static let defaultBroadcastSafeOpacity = 0.75

    /// Legal range for both safe-zone percentages (fractions). Shared by the popover's
    /// entry clamp and the overlay's draw-time guard so they can't disagree.
    static let broadcastPctRange: ClosedRange<Double> = 0.5...1.0

    @AppStorage("broadcastSafeOn") var broadcastSafeOn: Bool = false
    @AppStorage("broadcastActionPct") var broadcastActionPct: Double = Preferences.defaultBroadcastActionPct
    @AppStorage("broadcastTitlePct") var broadcastTitlePct: Double = Preferences.defaultBroadcastTitlePct
    @AppStorage("broadcastSafeColor") var broadcastSafeColorHex: String = Preferences.defaultBroadcastSafeHex
    @AppStorage("broadcastSafeWidth") var broadcastSafeWidth: Double = Preferences.defaultBroadcastSafeWidth
    @AppStorage("broadcastSafeOpacity") var broadcastSafeOpacity: Double = Preferences.defaultBroadcastSafeOpacity

    /// Slider range shared by every scope-intensity control (per-scope + master).
    /// 0.25 = quite dim, 3.0 = quite hot, 1.0 = current default look.
    static let scopeIntensityRange: ClosedRange<Double> = 0.25...3.0

    // Two-way bindings so the per-scope header sliders drive these without
    // redeclaring @AppStorage in each scope view (Preferences stays the one owner).
    var waveformIntensityBinding: Binding<Double> {
        Binding(get: { self.waveformIntensity }, set: { self.waveformIntensity = $0 })
    }
    var paradeIntensityBinding: Binding<Double> {
        Binding(get: { self.paradeIntensity }, set: { self.paradeIntensity = $0 })
    }
    var vectorscopeIntensityBinding: Binding<Double> {
        Binding(get: { self.vectorscopeIntensity }, set: { self.vectorscopeIntensity = $0 })
    }

    // Per-scope trace COLOR (hue the trace is painted in; intensity stays orthogonal).
    // Stored as 6-digit sRGB hex. Defaults reproduce the current look: waveform green,
    // vectorscope white. (Parade is intentionally excluded — its R/G/B are locked.)
    // Default trace colors — single source so the @AppStorage default and the
    // header reset buttons can't drift apart.
    static let defaultWaveformTraceColorHex = "00FF00"     // green
    static let defaultVectorscopeTraceColorHex = "FFFFFF"  // white
    @AppStorage("waveformTraceColor") var waveformTraceColorHex: String = Preferences.defaultWaveformTraceColorHex
    @AppStorage("vectorscopeTraceColor") var vectorscopeTraceColorHex: String = Preferences.defaultVectorscopeTraceColorHex

    var waveformTraceColorBinding: Binding<Color> {
        Binding(get: { ScopeColorCodec.color(fromHex: self.waveformTraceColorHex) },
                set: { self.waveformTraceColorHex = ScopeColorCodec.hex(from: $0) })
    }
    var vectorscopeTraceColorBinding: Binding<Color> {
        Binding(get: { ScopeColorCodec.color(fromHex: self.vectorscopeTraceColorHex) },
                set: { self.vectorscopeTraceColorHex = ScopeColorCodec.hex(from: $0) })
    }

    // Parade is two-state: default RGB columns, or monochrome (all three columns in
    // one chosen color). Picking a color activates monochrome; the reset button (RGB)
    // turns it off. Parade has NO per-channel colors.
    @AppStorage("paradeMonochrome") var paradeMonochrome: Bool = false
    @AppStorage("paradeMonoColor") var paradeMonoColorHex: String = "FFFFFF"

    /// Swatch binding: setting a color also switches the parade into monochrome mode.
    var paradeMonoColorBinding: Binding<Color> {
        Binding(get: { ScopeColorCodec.color(fromHex: self.paradeMonoColorHex) },
                set: {
                    self.paradeMonoColorHex = ScopeColorCodec.hex(from: $0)
                    self.paradeMonochrome = true
                })
    }

    // Frame-export destination folder, stored as a SECURITY-SCOPED BOOKMARK so write
    // access to a user-picked folder survives relaunch (robust under hardened runtime /
    // if sandboxing is ever added). Empty = default to ~/Desktop.
    @AppStorage("exportFolderBookmark") var exportFolderBookmark: Data = Data()

    private static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Store the chosen folder as a security-scoped bookmark.
    func setExportFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            exportFolderBookmark = data
        }
    }

    /// Clear the chosen folder (revert to ~/Desktop).
    func clearExportFolder() { exportFolderBookmark = Data() }

    /// Resolve the export folder and run `body` with it, bracketing security-scoped
    /// access. Falls back to ~/Desktop if no folder is chosen or the bookmark is
    /// stale/unresolvable (never fails the export).
    func withExportDirectory(_ body: (URL) -> Void) {
        guard !exportFolderBookmark.isEmpty else { body(Self.desktopURL); return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: exportFolderBookmark,
                                 options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              !stale else {
            print("[EXPORT] export-folder bookmark stale/unresolvable — using Desktop")
            body(Self.desktopURL); return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        body(url)
    }

    /// Display string for Settings (resolves the bookmark for show only).
    static func displayPath(forBookmark data: Data) -> String {
        guard !data.isEmpty else { return "Desktop (default)" }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
            return url.path
        }
        return "Desktop (default)"
    }

    private init() {}
}

/// The Settings window contents (opens with ⌘,).
struct SettingsView: View {
    // NDI runtime presence for the "NDI Runtime" status row. Observed so the row updates when
    // refreshRuntimeStatus() publishes (called from that section's .onAppear).
    @ObservedObject private var ndi = NDIService.shared

    // DeckLink driver + device presence for the "DeckLink" status row. Observed so the tri-state row
    // updates when refreshDevices() publishes (called from that section's .onAppear).
    @ObservedObject private var dl = DeckLinkService.shared

    // @AppStorage here drives the picker and persists the choice. It reads/writes
    // the same "controlDisplayMode" key as Preferences above, so they stay in sync.
    @AppStorage("controlDisplayMode") private var controlModeRaw: String = ControlDisplayMode.overlay.rawValue
    @AppStorage("autoplayOnLoad") private var autoplayOnLoad: Bool = true
    @AppStorage("globalScopeIntensity") private var globalScopeIntensity: Double = 1.0
    @AppStorage("scopeScale") private var scopeScale: ScopeScale = .bit10

    // DeckLink output: explicit "start output on launch" opt-in (NOT last-session persistence).
    // Shared key with DeckLinkService so it can't drift. Default off.
    @AppStorage(DeckLinkService.enableOnLaunchKey) private var deckLinkEnableOnLaunch = false

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

    // For reactive display of the chosen export folder (writes go via Preferences).
    @AppStorage("exportFolderBookmark") private var exportFolderBookmark = Data()

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

    var body: some View {
        Form {
            // License state + key entry / deactivation (App-layer licensing subsystem).
            LicenseSettingsSection()

            // Setup/readiness concerns grouped near the top. Broader than NDI alone — a DeckLink
            // device-detection row is planned here too (hence "I/O and Runtimes").
            Section("I/O and Runtimes") {
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
                Button("Install NDI Runtime…") {
                    NSWorkspace.shared.open(NDIService.runtimeInstallURL)
                }
                Text("After installing the NDI runtime, relaunch Manifold to enable NDI sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // DeckLink — tri-state, driven by (driverInstalled, devices). Driver presence (a↔b) is
                // relaunch-only (framework load is cached); card plug/unplug (b↔c) is picked up on the
                // next refresh, so only state (a) carries a relaunch caption.
                if !dl.driverInstalled {
                    // (a) Desktop Video framework not loaded — driver absent.
                    LabeledContent("DeckLink") {
                        Text("Desktop Video not installed")
                            .foregroundStyle(.orange)
                    }
                    Button("Download Desktop Video…") {
                        NSWorkspace.shared.open(DeckLinkService.driverInstallURL)
                    }
                    Text("Install Blackmagic Desktop Video, then relaunch Manifold.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if dl.devices.isEmpty {
                    // (b) Driver present, no card — plugging one is detected on the next refresh.
                    LabeledContent("DeckLink") {
                        Text("No device detected")
                            .foregroundStyle(.secondary)
                    }
                    Text("Connect a DeckLink or UltraStudio device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // (c) One or more devices — reassurance only, no action.
                    LabeledContent("DeckLink") {
                        Text(dl.devices.count == 1 ? dl.devices[0].displayName
                                                   : "\(dl.devices.count) devices detected")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Detection is lazy; refresh when Settings opens so the rows are current. NDI is
            // relaunch-only; DeckLink card presence updates live via this re-enumeration.
            .onAppear {
                NDIService.shared.refreshRuntimeStatus()
                DeckLinkService.shared.refreshDevices()
            }

            Section("DeckLink Output") {
                Toggle("Enable output on launch", isOn: $deckLinkEnableOnLaunch)
                Text("When on, Manifold starts DeckLink output at launch if a capable device is connected. Otherwise it does nothing. Turning output on or off during a session doesn't change this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Interface Options") {
                Picker("Controls", selection: $controlModeRaw) {
                    ForEach(ControlDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)

                Toggle("Autoplay on open", isOn: $autoplayOnLoad)
            }

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

            Section("Broadcast safe zones") {
                ColorPicker("Broadcast safe zone color", selection: colorBinding($broadcastSafeHex))
                Stepper("Broadcast safe zone width: \(Int(broadcastSafeWidth)) pt",
                        value: $broadcastSafeWidth, in: 1...8, step: 1)
                sliderRow("Broadcast safe zone opacity", $broadcastSafeOpacity, in: 0.0...1.0,
                          readout: pct(broadcastSafeOpacity))
                Text("Action- and title-safe percentages are set in the framing guides popover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 520)
    }
}
