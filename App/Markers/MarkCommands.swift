//
//  MarkCommands.swift — the Mark menu (docs/MARKERS_PLAN.md §3.1, D8): Resolve's name for the menu that holds markers
//  and In/Out. Every item is a registry action, so its key is the registry's and the key window's deck answers it
//  (`ShortcutCenter.runFromMenu`, which beeps when the window cannot). Import and export live in File.
//
//  Previous and Next Marker (⇧↑ / ⇧↓) are `.key` actions, not menu items: ⇧ + an arrow cannot be a menu key equivalent
//  (docs/SHORTCUTS_AUDIT.md C7). They are listed here as plain items that name their keys, so the menu still teaches them.
//

import SwiftUI
import ShortcutRegistry
import Markers

struct MarkCommands: Commands {
    @ObservedObject private var shortcuts = ShortcutCenter.shared.registry

    var body: some Commands {
        // View ▸ Show Markers (⇧⌥⌘M): in the existing View menu (`.toolbar`, as RasterSizeCommands explains).
        CommandGroup(after: .toolbar) {
            ShowMarkersToggle(registry: shortcuts)
            ShowChaptersToggle(registry: shortcuts)
        }
        CommandMenu("Mark") {
            ShortcutMenuItem(id: .addMarker, registry: shortcuts)
            ShortcutMenuItem(id: .addMarkerAndEdit, registry: shortcuts)
            ShortcutMenuItem(id: .editMarker, registry: shortcuts)
            ShortcutMenuItem(id: .deleteMarker, registry: shortcuts)
            Divider()
            Button("Previous Marker") { ShortcutCenter.shared.runFromMenu(.previousMarker) }
            Button("Next Marker") { ShortcutCenter.shared.runFromMenu(.nextMarker) }
            Divider()
            ShortcutMenuItem(id: .markIn, registry: shortcuts)
            ShortcutMenuItem(id: .markOut, registry: shortcuts)
            ShortcutMenuItem(id: .clearInOut, registry: shortcuts)
            Divider()
            // The file's embedded chapters into markers (docs/CHAPTER_MARKERS_PLAN.md §4.1). No default key.
            ShortcutMenuItem(id: .convertAllChapters, registry: shortcuts)
            Divider()
            ShowMarkerListMenuItem(registry: shortcuts)
        }
    }
}

/// View ▸ Show Markers: app-wide and remembered (`MarkerSettings.showKey`). Off hides the timeline flags and the Markers
/// slot's and window's contents; nothing is deleted, and adding a marker turns it back on (`MarkerModel.revealMarkers`).
private struct ShowMarkersToggle: View {
    @ObservedObject var registry: ShortcutRegistry
    @AppStorage(MarkerSettings.showKey) private var showMarkers = true

    var body: some View {
        Toggle(registry.definition(.showMarkers).title, isOn: $showMarkers)
            .registryShortcut(.showMarkers, registry)
    }
}

/// View ▸ Show Chapters (D-C3, docs/CHAPTER_MARKERS_PLAN.md §4.1): app-wide and remembered (`MarkerSettings.showChaptersKey`),
/// default on, no default key. Off hides the file's embedded chapters from the timeline, the lists and ⇧↑/⇧↓; nothing is
/// deleted. View ▸ Show Markers off hides them too.
private struct ShowChaptersToggle: View {
    @ObservedObject var registry: ShortcutRegistry
    @AppStorage(MarkerSettings.showChaptersKey) private var showChapters = true

    var body: some View {
        Toggle(registry.definition(.showChapters).title, isOn: $showChapters)
            .registryShortcut(.showChapters, registry)
    }
}
