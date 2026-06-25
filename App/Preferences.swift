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

    // Framing-guide styling (defaults reproduce Pass 1's look).
    @AppStorage("guideDarkenOpacity") private var guideDarkenOpacity = 0.85
    @AppStorage("guideDarkenColor") private var guideDarkenHex = "000000"
    @AppStorage("guideLineColor") private var guideLineHex = "FFFFFF"
    @AppStorage("guideLineWidth") private var guideLineWidth = 2.0
    @AppStorage("safeLineColor") private var safeLineHex = "FFFF00"
    @AppStorage("safeLineWidth") private var safeLineWidth = 1.0
    @AppStorage("safeLineOpacity") private var safeLineOpacity = 0.75

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { ScopeColorCodec.color(fromHex: hex.wrappedValue) },
                set: { hex.wrappedValue = ScopeColorCodec.hex(from: $0) })
    }

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

            Section("Framing Guides") {
                ColorPicker("Outside (darken) color", selection: colorBinding($guideDarkenHex))
                HStack {
                    Text("Outside opacity")
                    Slider(value: $guideDarkenOpacity, in: 0.0...1.0)
                }
                ColorPicker("Guide line color", selection: colorBinding($guideLineHex))
                Stepper("Guide line width: \(Int(guideLineWidth)) pt",
                        value: $guideLineWidth, in: 1...10, step: 1)
                ColorPicker("Safe line color", selection: colorBinding($safeLineHex))
                Stepper("Safe line width: \(Int(safeLineWidth)) pt",
                        value: $safeLineWidth, in: 1...8, step: 1)
                HStack {
                    Text("Safe line opacity")
                    Slider(value: $safeLineOpacity, in: 0.0...1.0)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
