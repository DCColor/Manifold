//
//  ScopeGraticuleBrightness.swift
//  ManifoldCore / ScopeCompute
//
//  Settings ▸ Scopes & Guides ▸ Scopes ▸ "Graticule brightness" (0.9.5, docs/SCOPES_095_PLAN.md): one global multiplier
//  on the image scopes' graticule alphas (Waveform, Parade, Vectorscope, CIE). Pure functions, so `swift test` reaches
//  them; the scopes call these at every graticule stroke and label. The audio meters do not read it.
//

/// The scale every image scope's graticule draws with.
///
/// - LINES (`line`) scale linearly: 0 turns them off, 1 is the built-in default, 2 doubles the alpha. The result is
///   clamped to 0…1, so a line whose default is already over 0.5 reaches full opacity before 2×.
/// - LABELS (`label`) and the vectorscope's REFERENCES (`reference`: the skin-tone axis and the color-bar target
///   brackets) scale the same way but never go below a readable floor: at 0 the lines are gone and these stay. A base
///   already below its floor is never dimmed below that base (and never raised to the floor at 1×), so the default look
///   is exactly the base values.
/// - The user's own markings (user lines on the value scopes, user targets on the vectorscope) are NOT graticule and do
///   not call this at all: they draw at their own values at every slider position (Robbie, 2026-11-16).
public enum ScopeGraticuleBrightness {
    /// The slider's range: 0 (lines off, labels stay) to 2× the default.
    public static let range: ClosedRange<Double> = 0.0...2.0
    /// 1× — the built-in values in the app's `ScopeGraticuleStyle`, unchanged.
    public static let defaultValue: Double = 1.0
    /// The lowest a graticule label goes. 0.60 is the scopes' label opacity before 0.9.5, and the audio meters' today.
    public static let labelFloor: Double = 0.60
    /// The lowest the vectorscope's references go: the skin-tone axis and the color-bar target brackets. 0.50 is both
    /// opacities before 0.9.5; the axis shipped at 0.22 first and was reported unreadable on a trace (VectorscopeScope.swift,
    /// at the axis's draw site).
    public static let referenceFloor: Double = 0.50

    /// The stored value made safe to multiply by: clamped to `range`; a non-finite value (a hand-edited defaults key)
    /// reads as the default.
    public static func clamped(_ brightness: Double) -> Double {
        guard brightness.isFinite else { return defaultValue }
        return min(range.upperBound, max(range.lowerBound, brightness))
    }

    /// A graticule LINE's alpha: `base × brightness`, clamped to 0…1.
    public static func line(_ base: Double, _ brightness: Double) -> Double {
        unit(base * clamped(brightness))
    }

    /// A graticule LABEL's alpha: as `line`, but never below `labelFloor` (or below `base`, if `base` is lower).
    public static func label(_ base: Double, _ brightness: Double) -> Double {
        floored(base, brightness, floor: labelFloor)
    }

    /// A vectorscope reference's alpha (the skin-tone axis, the target brackets): as `line`, but never below
    /// `referenceFloor` (or below `base`, if `base` is lower).
    public static func reference(_ base: Double, _ brightness: Double) -> Double {
        floored(base, brightness, floor: referenceFloor)
    }

    /// `line`, held at or above `min(floor, base)`.
    public static func floored(_ base: Double, _ brightness: Double, floor: Double) -> Double {
        max(unit(min(floor, base)), line(base, brightness))
    }

    @inline(__always) private static func unit(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(1, max(0, v))
    }
}
