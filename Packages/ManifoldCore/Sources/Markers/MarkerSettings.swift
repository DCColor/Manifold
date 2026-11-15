//
//  MarkerSettings.swift — the two marker preferences (docs/MARKERS_PLAN.md §5.2, §4.5; Robbie 2026-11-15).
//
//  Remember markers between sessions (Settings ▸ Files ▸ Markers, default ON): off, a file's markers live only while it
//  is open in that session; nothing is read from or written to Markers/ or the thumbnail cache. Turning it off deletes
//  nothing.
//
//  Show Markers (View ▸ Show Markers, default ON): off hides the timeline flags and the lists' contents; nothing is
//  deleted, and adding a marker turns it back on.
//
//  UI preferences in UserDefaults, like the app's ~70 others: no marker content.
//

import Foundation

public enum MarkerSettings {
    public static let rememberKey = "manifold.markers.remember"
    public static let showKey = "manifold.markers.show"

    /// Absent reads as ON for both.
    public static func remember(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: rememberKey) as? Bool ?? true
    }

    public static func show(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showKey) as? Bool ?? true
    }
}
