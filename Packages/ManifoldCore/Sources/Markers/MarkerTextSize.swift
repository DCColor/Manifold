//
//  MarkerTextSize.swift — the Markers scope's text size: Small, Medium, Large (Robbie, 2026-11-21, for 0.9.5).
//
//  One stored value, `key`, read live by the scope's gear and by Settings ▸ Scopes & Guides. Absent or unknown reads as Medium.
//  Medium is exactly the slot row's metrics before this setting (MarkersScopeView.swift, 2026-11-21); each step scales every
//  metric, fonts and row height (thumbnail, padding, spacing) together, by one factor. The Markers window is not affected.
//  Not in settings export: that file carries shortcuts and streams only (docs/SETTINGS_EXPORT_PLAN.md §1.3, scope looks "Out").
//

import Foundation

public enum MarkerTextSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    public static let key = "manifold.markers.slotTextSize"
    public static let defaultSize: MarkerTextSize = .medium

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// The one factor every metric is scaled by. Small's 0.875 keeps the smallest text, the IN/OUT chip, at 7 pt.
    public var scale: Double {
        switch self {
        case .small: return 0.875
        case .medium: return 1.0
        case .large: return 1.25
        }
    }

    public var metrics: MarkerSlotMetrics { MarkerSlotMetrics.medium.scaled(by: scale) }

    /// The stored size; absent or unknown is Medium.
    public static func current(_ defaults: UserDefaults = .standard) -> MarkerTextSize {
        defaults.string(forKey: key).flatMap(MarkerTextSize.init(rawValue:)) ?? defaultSize
    }
}

/// The Markers slot's row and chip metrics, in points.
public struct MarkerSlotMetrics: Equatable, Sendable {
    public var timecode: Double       // a row's timecode (monospaced)
    public var name: Double           // the marker or chapter name
    public var notes: Double          // the note's first line
    public var duration: Double       // the duration (monospaced)
    public var chip: Double           // the header's IN / OUT chips (monospaced, semibold)
    public var swatch: Double         // the color dot, and the chapter symbol's size and frame
    public var thumbnail: Double      // the thumbnail's height
    public var rowSpacing: Double     // between a row's items
    public var rowPadding: Double     // above and below a row
    public var chipPaddingH: Double
    public var chipPaddingV: Double

    /// Today's slot (before the setting): the literal values MarkersScopeView used.
    public static let medium = MarkerSlotMetrics(timecode: 10, name: 11, notes: 10, duration: 9, chip: 8, swatch: 8, thumbnail: 32,
                                                 rowSpacing: 6, rowPadding: 2, chipPaddingH: 4, chipPaddingV: 1)

    public func scaled(by s: Double) -> MarkerSlotMetrics {
        MarkerSlotMetrics(timecode: timecode * s, name: name * s, notes: notes * s, duration: duration * s, chip: chip * s,
                          swatch: swatch * s, thumbnail: thumbnail * s, rowSpacing: rowSpacing * s, rowPadding: rowPadding * s,
                          chipPaddingH: chipPaddingH * s, chipPaddingV: chipPaddingV * s)
    }
}
