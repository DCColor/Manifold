//
//  ShortcutCatalog.swift — every shortcut Manifold defines, in one list (docs/SHORTCUTS_AUDIT.md §4.2, decided by
//  Robbie 2026-10-23). The menus, the key dispatcher and the Keyboard Shortcuts window all read this; nothing else
//  in the app names a key. Stock items (⌘Q, ⌘W, the Edit menu, Enter Full Screen) are not here: they are macOS's,
//  and `ShortcutRegistry.reserved` refuses them.
//

import Foundation

public enum ShortcutID: String, CaseIterable, Sendable {
    // File
    case fileOpen = "file.open"
    case exportFrame = "file.exportFrame"
    // Sources and output
    case connectFirstNDI = "sources.connectFirstNDI"
    case disconnectLive = "sources.disconnectLive"
    case startDeckLink = "output.startDeckLink"
    case stopDeckLink = "output.stopDeckLink"
    // Transport
    case playPause = "transport.playPause"
    case shuttleReverse = "transport.shuttleReverse"
    case shuttlePause = "transport.shuttlePause"
    case shuttleForward = "transport.shuttleForward"
    case kjlGesture = "transport.kjlGesture"
    case stepBackFrame = "transport.stepBackFrame"
    case stepForwardFrame = "transport.stepForwardFrame"
    case stepBackSecond = "transport.stepBackSecond"
    case stepForwardSecond = "transport.stepForwardSecond"
    case goToStart = "transport.goToStart"
    case goToEnd = "transport.goToEnd"
    case goToStartAlternate = "transport.goToStartAlternate"
    case goToEndAlternate = "transport.goToEndAlternate"
    case loop = "transport.loop"
    // Timecode entry
    case timecodeOpen = "timecode.open"
    case timecodeCommit = "timecode.commit"
    case timecodeCancel = "timecode.cancel"
    case timecodeBackspace = "timecode.backspace"
    // View
    case raster100 = "view.raster100"
    case raster75 = "view.raster75"
    case raster50 = "view.raster50"
    case raster25 = "view.raster25"
    case rasterFit = "view.rasterFit"
    case inspector = "view.inspector"
    case fileName = "view.fileName"
    case alwaysShowControls = "view.alwaysShowControls"
    case fullScreen = "view.fullScreen"
    // Scopes
    case scopesTray = "scopes.tray"
    case cieSpace = "scopes.cieSpace"
    case vectorscopeGraticule = "scopes.vectorscopeGraticule"
    case vectorscopeBoxes = "scopes.vectorscopeBoxes"
    case cie709 = "scopes.cie709"
    case cieP3 = "scopes.cieP3"
    case cie2020 = "scopes.cie2020"
    // Colour
    case displayOS = "color.displayOS"
    case displayReference = "color.displayReference"
    case displayBypass = "color.displayBypass"
    case holdCompare = "color.holdCompare"
    case holdCompareBypass = "color.holdCompareBypass"
    case cycleInterpretation = "color.cycleInterpretation"
    case resetInterpretation = "color.resetInterpretation"
    // Audio
    case audioLater1 = "audio.offsetLater1"
    case audioEarlier1 = "audio.offsetEarlier1"
    case audioLater10 = "audio.offsetLater10"
    case audioEarlier10 = "audio.offsetEarlier10"
    case mute = "audio.mute"
    case volumeUp = "audio.volumeUp"
    case volumeDown = "audio.volumeDown"
    // Debug — the Profile tier
    case debugToneTest = "debug.ndiToneTest"
    case debugScrubBench = "debug.chromaScrubBench"
    case debugRenderLayer = "debug.renderLayer"
    case debugWebRTCSmoke = "debug.webrtcSmoke"
    case debugWHEPConnect = "debug.whepConnect"
    case debugWHEPRetire = "debug.whepRetire"
    case debugWHEPExportFrame = "debug.whepExportFrame"
    case debugSRTConnect = "debug.srtConnect"
    case debugSRTRetire = "debug.srtRetire"
    // Debug — the Debug-configuration tier (LiveClock setpoint mutators, docs/BUGS.md)
    case debugSyntheticStart = "debug.syntheticStart"
    case debugSyntheticStop = "debug.syntheticStop"
    case debugSyntheticPreset = "debug.syntheticPreset"
    case debugForceUnityRate = "debug.forceUnityRate"
    case debugSyntheticSweep = "debug.syntheticSweep"
    case debugDepthDown = "debug.liveDepthDown"
    case debugDepthUp = "debug.liveDepthUp"
}

public enum ShortcutCategory: String, CaseIterable, Sendable {
    case transport = "Transport"
    case timecode = "Timecode Entry"
    case view = "View"
    case scopes = "Scopes"
    case color = "Color"
    case audio = "Audio"
    case file = "File"
    case sources = "Sources and Output"
    case debug = "Debug"
}

/// Where a shortcut can act. Two shortcuts may share a key only in scopes that never overlap.
public enum ShortcutScope: String, Sendable {
    /// Anywhere in the app.
    case app
    /// A Manifold window is key.
    case window
    /// A window showing a FILE, whose transport this window holds.
    case fileTransport
    /// A window showing a LIVE source.
    case live
    /// Timecode entry is open. Its keys are swallowed ahead of everything bare, so it overlaps every scope.
    case timecodeEntry

    public var label: String {
        switch self {
        case .app: return "Anywhere"
        case .window: return "Any window"
        case .fileTransport: return "Files only"
        case .live: return "Live sources only"
        case .timecodeEntry: return "While entering timecode"
        }
    }

    /// A file window and a live window are never the same window at the same moment; everything else meets.
    public func overlaps(_ other: ShortcutScope) -> Bool {
        let pair: Set<ShortcutScope> = [self, other]
        return pair != [.fileTransport, .live]
    }
}

public enum ShortcutDispatch: Sendable {
    /// A menu item. Its key is shown in the menu and AppKit dispatches it; when bound to a bare or ⇧ key it cannot be
    /// a key equivalent (it would take the key from text fields), so the key dispatcher takes it and the menu shows
    /// none.
    case menu
    /// The key dispatcher only: bare keys, ⇧-arrows, gestures and hidden debug hooks.
    case key
    /// The key dispatcher, on key-down and key-up.
    case hold
    /// Shown, never rebindable, handled by the dispatcher's own rules (timecode entry, the K+J/L gesture).
    case fixed
}

public enum DebugTier: String, Sendable {
    /// In every `#if DEBUG` build, which includes Profile, the configuration every build so far has shipped.
    case profile
    /// Only in the Debug configuration (`MANIFOLD_CONFIG_DEBUG`).
    case configDebug
}

public struct ShortcutDefinition: Identifiable, Sendable {
    public let id: ShortcutID
    public let title: String
    public let category: ShortcutCategory
    public let scope: ShortcutScope
    public let dispatch: ShortcutDispatch
    public let defaultChord: KeyChord?
    /// Further keys a fixed row answers to, for display and for conflicts (timecode entry's digits).
    public let fixedChords: [KeyChord]
    /// What a fixed row shows instead of a key.
    public let fixedLabel: String?
    public let debug: DebugTier?
    /// Auto-repeat performs again (J/K/L, the arrows, the nudge). Toggles ignore it.
    public let repeats: Bool
    public let note: String?

    public var rebindable: Bool { dispatch != .fixed && debug == nil && id != .fileOpen }

    init(_ id: ShortcutID, _ title: String, _ category: ShortcutCategory, _ scope: ShortcutScope,
         _ dispatch: ShortcutDispatch, _ chord: KeyChord?, debug: DebugTier? = nil, repeats: Bool = false,
         fixedChords: [KeyChord] = [], fixedLabel: String? = nil, note: String? = nil) {
        self.id = id
        self.title = title
        self.category = category
        self.scope = scope
        self.dispatch = dispatch
        self.defaultChord = chord
        self.debug = debug
        self.repeats = repeats
        self.fixedChords = fixedChords
        self.fixedLabel = fixedLabel
        self.note = note
    }

    /// Every key this row holds by default.
    public var defaultChords: [KeyChord] { (defaultChord.map { [$0] } ?? []) + fixedChords }
}

public enum ShortcutCatalog {
    private static let cmd: KeyModifiers = [.command]
    private static let optCmd: KeyModifiers = [.option, .command]
    private static let ctlOpt: KeyModifiers = [.control, .option]
    private static let ctlOptShift: KeyModifiers = [.control, .option, .shift]

    public static let all: [ShortcutDefinition] = [
        // ── File ────────────────────────────────────────────────────────────────────────────────
        .init(.fileOpen, "Open…", .file, .app, .menu, .char("o", cmd),
              note: "The standard Mac key; not rebindable"),
        .init(.exportFrame, "Export Frame", .file, .window, .menu, .char("e", optCmd)),

        // ── Sources and output: device claims, no default key (audit §4.1 rule 4) ─────────────
        .init(.connectFirstNDI, "Connect to First NDI Source", .sources, .window, .menu, nil),
        .init(.disconnectLive, "Disconnect Live Source", .sources, .window, .menu, nil),
        .init(.startDeckLink, "Start DeckLink Output", .sources, .window, .menu, nil),
        .init(.stopDeckLink, "Stop DeckLink Output", .sources, .window, .menu, nil),

        // ── Transport (Resolve R20 p728-729, Premiere, Final Cut Pro; audit §3) ────────────────
        .init(.playPause, "Play / Pause", .transport, .fileTransport, .key, .code(KeyCode.space)),
        .init(.shuttleReverse, "Shuttle Reverse (press again for faster)", .transport, .fileTransport, .key,
              .char("j"), repeats: true),
        .init(.shuttlePause, "Stop Shuttle", .transport, .fileTransport, .key, .char("k"), repeats: true),
        .init(.shuttleForward, "Shuttle Forward (press again for faster)", .transport, .fileTransport, .key,
              .char("l"), repeats: true),
        .init(.kjlGesture, "Hold K, press J or L: one frame; keep holding: ½× play", .transport, .fileTransport,
              .fixed, nil, fixedLabel: "K + J / L",
              note: "As DaVinci Resolve (R20 p729) and Final Cut Pro; follows the keys bound to J, K and L"),
        .init(.stepBackFrame, "Step Back One Frame", .transport, .fileTransport, .key, .code(KeyCode.left),
              repeats: true),
        .init(.stepForwardFrame, "Step Forward One Frame", .transport, .fileTransport, .key, .code(KeyCode.right),
              repeats: true),
        .init(.stepBackSecond, "Step Back One Second", .transport, .fileTransport, .key,
              .code(KeyCode.left, [.shift]), repeats: true),
        .init(.stepForwardSecond, "Step Forward One Second", .transport, .fileTransport, .key,
              .code(KeyCode.right, [.shift]), repeats: true),
        .init(.goToStart, "Go to Start", .transport, .fileTransport, .key, .code(KeyCode.home)),
        .init(.goToEnd, "Go to End", .transport, .fileTransport, .key, .code(KeyCode.end)),
        .init(.goToStartAlternate, "Go to Start (no Fn needed)", .transport, .fileTransport, .key,
              .code(KeyCode.left, [.option])),
        .init(.goToEndAlternate, "Go to End (no Fn needed)", .transport, .fileTransport, .key,
              .code(KeyCode.right, [.option])),
        .init(.loop, "Loop Playback", .transport, .fileTransport, .menu, .char("l", cmd)),

        // ── Timecode entry (fixed: typing a timecode is not a shortcut) ────────────────────────
        .init(.timecodeOpen, "Type a Timecode (+ or − for relative)", .timecode, .window, .fixed, nil,
              fixedChords: (0...9).map { .char(String($0)) } + [.char("="), .char("-"), .char("+", [.shift]),
                                                                  .char("_", [.shift])],
              fixedLabel: "0–9, +, −"),
        .init(.timecodeCommit, "Go to the Typed Timecode", .timecode, .timecodeEntry, .fixed, nil,
              fixedChords: [.code(KeyCode.returnKey), .code(KeyCode.keypadEnter)], fixedLabel: "Return"),
        .init(.timecodeCancel, "Cancel Timecode Entry", .timecode, .timecodeEntry, .fixed, nil,
              fixedChords: [.code(KeyCode.escape)], fixedLabel: "Esc"),
        .init(.timecodeBackspace, "Delete the Last Digit", .timecode, .timecodeEntry, .fixed, nil,
              fixedChords: [.code(KeyCode.delete), .code(KeyCode.forwardDelete)], fixedLabel: "Delete"),

        // ── View ────────────────────────────────────────────────────────────────────────────────
        .init(.raster100, "100%", .view, .window, .menu, .char("1", cmd)),
        .init(.raster75, "75%", .view, .window, .menu, .char("2", cmd)),
        .init(.raster50, "50%", .view, .window, .menu, .char("3", cmd)),
        .init(.raster25, "25%", .view, .window, .menu, .char("4", cmd)),
        .init(.rasterFit, "Fit to Screen", .view, .window, .menu, .char("0", cmd)),
        .init(.inspector, "Show/Hide Inspector", .view, .window, .menu, .char("i", cmd)),
        .init(.fileName, "Show/Hide File Name", .view, .window, .menu, .char("n")),
        .init(.alwaysShowControls, "Always Show Controls", .view, .window, .menu, .char("t", optCmd)),
        .init(.fullScreen, "Enter or Exit Full Screen", .view, .window, .key, .char("f", cmd),
              note: "An alias of the system's Enter Full Screen (⌃⌘F, fn-F)"),

        // ── Scopes ──────────────────────────────────────────────────────────────────────────────
        .init(.scopesTray, "Show/Hide Scopes", .scopes, .window, .menu, .char("7", cmd)),
        .init(.cieSpace, "CIE: Switch xy / u′v′", .scopes, .window, .key, nil),
        .init(.vectorscopeGraticule, "Vectorscope: Rec. 709 / Source Primaries Graticule", .scopes, .window, .key, nil),
        .init(.vectorscopeBoxes, "Vectorscope: 75% / 100% / Both Boxes", .scopes, .window, .key, nil),
        .init(.cie709, "CIE: Show/Hide Rec. 709 Triangle", .scopes, .window, .key, nil),
        .init(.cieP3, "CIE: Show/Hide P3 Triangle", .scopes, .window, .key, nil),
        .init(.cie2020, "CIE: Show/Hide Rec. 2020 Triangle", .scopes, .window, .key, nil),

        // ── Colour ──────────────────────────────────────────────────────────────────────────────
        .init(.displayOS, "As macOS Shows It", .color, .window, .menu, .char("1", optCmd)),
        .init(.displayReference, "Reference (BT.1886)", .color, .window, .menu, .char("2", optCmd)),
        .init(.displayBypass, "Bypass — No Colour Management", .color, .window, .menu, .char("3", optCmd)),
        .init(.holdCompare, "Hold to Compare: macOS ↔ Reference", .color, .window, .hold, .char("d"),
              note: "Release to go back"),
        .init(.holdCompareBypass, "Hold to Compare with Bypass", .color, .window, .hold, .char("d", [.shift]),
              note: "As DaVinci Resolve's ⇧D bypass (R20 p504), held"),
        .init(.cycleInterpretation, "Next Color Interpretation", .color, .window, .menu, nil),
        .init(.resetInterpretation, "Reset Color Interpretation to Auto", .color, .window, .menu, nil),

        // ── Audio ───────────────────────────────────────────────────────────────────────────────
        .init(.audioLater1, "Audio Later by 1 ms", .audio, .live, .key, .code(KeyCode.rightBracket, [.option]),
              repeats: true),
        .init(.audioEarlier1, "Audio Earlier by 1 ms", .audio, .live, .key, .code(KeyCode.leftBracket, [.option]),
              repeats: true),
        .init(.audioLater10, "Audio Later by 10 ms", .audio, .live, .key,
              .code(KeyCode.rightBracket, [.option, .shift]), repeats: true),
        .init(.audioEarlier10, "Audio Earlier by 10 ms", .audio, .live, .key,
              .code(KeyCode.leftBracket, [.option, .shift]), repeats: true),
        .init(.mute, "Mute / Unmute", .audio, .window, .key, nil),
        .init(.volumeUp, "Volume Up", .audio, .window, .key, nil, repeats: true),
        .init(.volumeDown, "Volume Down", .audio, .window, .key, nil, repeats: true),

        // ── Debug: ⌃⌥ is the debug namespace (audit §4.1 rule 3). Not rebindable. ────────────────
        .init(.debugToneTest, "NDI Audio Tone Test", .debug, .app, .menu, .char("a", ctlOpt), debug: .profile),
        .init(.debugScrubBench, "Chroma Scrub Bench", .debug, .app, .menu, .char("b", ctlOptShift), debug: .profile),
        .init(.debugRenderLayer, "Show AVFoundation Layer Instead of Metal (A/B)", .debug, .window, .key,
              .char("r", ctlOpt), debug: .profile),
        .init(.debugWebRTCSmoke, "libdatachannel Link Smoke Test", .debug, .window, .key, .char("w", ctlOpt),
              debug: .profile),
        .init(.debugWHEPConnect, "Connect WHEP (debug URL or first saved)", .debug, .window, .key,
              .char("h", ctlOpt), debug: .profile),
        .init(.debugWHEPRetire, "Retire Live Source (WHEP)", .debug, .window, .key, .char("h", ctlOptShift),
              debug: .profile),
        .init(.debugWHEPExportFrame, "Export Next Decoded WHEP Frame", .debug, .window, .key,
              .char("e", ctlOptShift), debug: .profile),
        .init(.debugSRTConnect, "Connect SRT (debug URL or first saved)", .debug, .window, .key, .char("d", ctlOpt),
              debug: .profile),
        .init(.debugSRTRetire, "Retire Live Source (SRT)", .debug, .window, .key, .char("d", ctlOptShift),
              debug: .profile),
        .init(.debugSyntheticStart, "SyntheticLive: Replay the File Live", .debug, .window, .key, .char("l", ctlOpt),
              debug: .configDebug),
        .init(.debugSyntheticStop, "SyntheticLive: Stop", .debug, .window, .key, .char("l", ctlOptShift),
              debug: .configDebug),
        .init(.debugSyntheticPreset, "SyntheticLive: Next Preset", .debug, .window, .key, .char("p", ctlOpt),
              debug: .configDebug),
        .init(.debugForceUnityRate, "Force Unity Rate", .debug, .window, .key, .char("u", ctlOpt),
              debug: .configDebug),
        .init(.debugSyntheticSweep, "SyntheticLive: Sweep", .debug, .window, .key, .char("s", ctlOpt),
              debug: .configDebug),
        .init(.debugDepthDown, "Live Target Depth −50 ms", .debug, .window, .key, .char("[", ctlOpt),
              debug: .configDebug),
        .init(.debugDepthUp, "Live Target Depth +50 ms", .debug, .window, .key, .char("]", ctlOpt),
              debug: .configDebug),
    ]

    public static let byID: [ShortcutID: ShortcutDefinition] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
