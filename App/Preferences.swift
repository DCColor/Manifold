import SwiftUI

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

    // Scope arrangement (persisted across launches). Canonical declaration lives here;
    // ContentView binds the same keys via @AppStorage for SwiftUI reactivity.
    // NOTE: showReferenceLayer (⌃⌥R) is intentionally NOT persisted — it's a diagnostic
    // toggle that must always default OFF on launch, so it stays transient @State.
    @AppStorage("showTray") var showTray: Bool = false
    @AppStorage("showWaveform") var showWaveform: Bool = true
    @AppStorage("showParade") var showParade: Bool = true
    @AppStorage("showVectorscope") var showVectorscope: Bool = true

    // Scope trace intensity — multiplies the brightness-curve gain. 1.0 = current look.
    // Per-scope values combine MULTIPLICATIVELY with the global master.
    @AppStorage("waveformIntensity") var waveformIntensity: Double = 1.0
    @AppStorage("paradeIntensity") var paradeIntensity: Double = 1.0
    @AppStorage("vectorscopeIntensity") var vectorscopeIntensity: Double = 1.0
    @AppStorage("globalScopeIntensity") var globalScopeIntensity: Double = 1.0

    // Global vertical scale for the value-axis scopes (waveform/parade). Stored as the
    // enum's String raw value. Default .bit10 (the 1023 ruler read in Resolve).
    @AppStorage("scopeScale") var scopeScale: ScopeScale = .bit10

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

    private init() {}
}

/// The Settings window contents (opens with ⌘,).
struct SettingsView: View {
    // @AppStorage here drives the picker and persists the choice. It reads/writes
    // the same "controlDisplayMode" key as Preferences above, so they stay in sync.
    @AppStorage("controlDisplayMode") private var controlModeRaw: String = ControlDisplayMode.overlay.rawValue
    @AppStorage("autoplayOnLoad") private var autoplayOnLoad: Bool = true
    @AppStorage("globalScopeIntensity") private var globalScopeIntensity: Double = 1.0
    @AppStorage("scopeScale") private var scopeScale: ScopeScale = .bit10

    var body: some View {
        Form {
            Picker("Controls", selection: $controlModeRaw) {
                ForEach(ControlDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)

            Toggle("Autoplay on open", isOn: $autoplayOnLoad)

            Picker("Scope Scale", selection: $scopeScale) {
                ForEach(ScopeScale.selectable) { scale in
                    Text(scale.label).tag(scale)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Scope Intensity (master — scales all scopes)")
                HStack(spacing: 6) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: $globalScopeIntensity, in: Preferences.scopeIntensityRange)
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
