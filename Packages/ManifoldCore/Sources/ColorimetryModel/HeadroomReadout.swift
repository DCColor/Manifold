//
//  HeadroomReadout.swift
//  ColorimetryModel
//
//  Colour S4 (COLOR_MANAGEMENT_FINDINGS.md §6.11, Phase 5): the chain readout's Headroom line and the
//  `[EDR] headroom` log's change test. A readout only — no headroom cap (decision 8); the 2026-08-28
//  no-tone-map decision stands.
//

/// One reading of a screen's EDR values, as `NSScreen` reports them. A plain value so the wording and the
/// change test can be unit-tested without a display.
public struct EDRHeadroom: Equatable, Sendable {
    /// `maximumExtendedDynamicRangeColorComponentValue` — what has been GRANTED on that screen right now.
    public var current: Double
    /// `maximumPotentialExtendedDynamicRangeColorComponentValue` — what the display could offer. 1.0 is
    /// the macOS HDR switch off for that display.
    public var potential: Double
    /// `maximumReferenceExtendedDynamicRangeColorComponentValue` — logged, not shown.
    public var reference: Double

    public init(current: Double, potential: Double, reference: Double = 0) {
        self.current = current
        self.potential = potential
        self.reference = reference
    }

    /// `potential` at or below this is a display in SDR mode. The same tolerance the `[EDR]` log uses.
    public static let sdrThreshold = 1.0001

    public var isSDRMode: Bool { potential <= Self.sdrThreshold }
    public var isGranted: Bool { current > Self.sdrThreshold }

    /// True when the two readings would SHOW differently (two decimal places, the readout's precision).
    /// The log and the readout move together on this test, so a log line always means the line moved.
    public func differsVisibly(from other: EDRHeadroom) -> Bool {
        Self.hundredths(current) != Self.hundredths(other.current)
            || Self.hundredths(potential) != Self.hundredths(other.potential)
    }

    private static func hundredths(_ v: Double) -> Int { Int((v * 100).rounded()) }
}

/// The chain readout's Headroom line.
///
/// ⚠️ **`potential` IS READ FIRST, AND THE TWO ARE NEVER COLLAPSED.** The `[EDR]` log once called a
/// display "inert" from `current` alone while `potential` read 8.97 (§6.7). So the SDR-mode wording keys
/// on `potential` only, and a display offering headroom that nothing has been granted says exactly that
/// rather than reading as an SDR display.
public enum HeadroomReadout {

    public static let sdrModeText = "display is in SDR mode"

    public static func text(_ h: EDRHeadroom?) -> String {
        guard let h else { return "no screen" }
        if h.isSDRMode { return sdrModeText }
        let figures = "headroom " + format(h.current) + " of " + format(h.potential)
        return h.isGranted ? figures : figures + " — none granted"
    }

    /// Two decimal places, without Foundation (this target has no Foundation dependency in its API).
    static func format(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        let frac = n % 100
        return "\(n / 100)." + (frac < 10 ? "0" : "") + "\(frac)"
    }
}
