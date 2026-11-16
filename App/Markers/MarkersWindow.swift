//
//  MarkersWindow.swift — the Markers window (docs/MARKERS_PLAN.md §4.1 (b), built 2026-11-15).
//
//  ONE app-wide window (Mark ▸ Show Marker List, ⌃⌘M) that follows the KEY PLAYER WINDOW's file: it shows
//  `DeckRegistry.keyDeck`'s markers, the deck menu commands already act on, which stays the last player window to become
//  key while this window is in front. Re-read whenever any window becomes key or closes. Its title names the file.
//
//  Full columns: thumbnail, in, out, duration, colour, name, notes, keywords; the same clicks as the slot
//  (`MarkerListBody`). A normal window, not always-on-top.
//

import SwiftUI
import Combine
import ManifoldCore
import ShortcutRegistry

enum MarkersWindowScene {
    static let windowID = "markers"
}

/// Which player window the Markers window shows.
@MainActor
final class MarkersWindowFollower: ObservableObject {
    @Published private(set) var deck: WindowDeck?
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the close or key change has settled: `keyDeck` reads the registry's own state.
                DispatchQueue.main.async { MainActor.assumeIsolated { MarkersWindowFollower.shared.refresh() } }
            })
        }
        refresh()
    }

    static let shared = MarkersWindowFollower()

    func refresh() {
        let d = DeckRegistry.shared.keyDeck
        if d !== deck { deck = d }
    }
}

struct MarkersWindowView: View {
    @ObservedObject private var follower = MarkersWindowFollower.shared

    var body: some View {
        Group {
            if let deck = follower.deck, let engine = deck.engine {
                MarkersWindowContent(model: deck.markers, engine: engine, deck: deck)
                    .id(ObjectIdentifier(deck))
            } else {
                Text("No player window.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Markers")
            }
        }
        .frame(minWidth: 760, minHeight: 240)
        .onAppear { follower.refresh() }
    }
}

private struct MarkersWindowContent: View {
    @ObservedObject var model: MarkerModel
    @ObservedObject var engine: FrameEngine
    let deck: WindowDeck
    @State private var filterOpen = false

    var body: some View {
        VStack(spacing: 0) {
            MarkerListBody(model: model, engine: engine, style: .window, showThumbnails: true)
            MarkerNotice(model: model)
        }
        .navigationTitle(model.fileName.isEmpty ? "Markers" : "Markers — \(model.fileName)")
        .toolbar {
            // Text buttons, not icons (Robbie, 2026-11-15): the download and share glyphs read as Download and as Share
            // Frame. The filter stays an icon.
            ToolbarItem {
                Button { filterOpen.toggle() } label: {
                    Label("Filter by Color", systemImage: model.colorFilter.isEmpty
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter by Color")
                .popover(isPresented: $filterOpen, arrowEdge: .bottom) {
                    MarkerColorFilter(model: model).padding(12)
                }
            }
            ToolbarItem {
                Button("Regenerate Thumbnails") { model.regenerateThumbnails() }
                    .help("Make this file's marker thumbnails again (not while playing)")
                    .disabled(!model.isActive || model.markers.isEmpty)
            }
            ToolbarItem {
                Button("Import…") { model.presentImport() }
                    .help("Import Markers… (a Resolve marker EDL) into this file")
                    .disabled(!model.isActive)
            }
            ToolbarItem {
                Button("Export…") { model.presentExport() }
                    .help("Export Markers… (Resolve EDL, CSV or text)")
                    .disabled(!model.isActive || model.markers.isEmpty)
            }
        }
    }
}

/// Mark ▸ Show Marker List (⌃⌘M): opens or raises the Markers window. A menu item of its own, not `runFromMenu`,
/// because opening a scene is the App's job; it carries the registry's title and key, which is what `MenuKeyAudit` checks.
struct ShowMarkerListMenuItem: View {
    @ObservedObject var registry: ShortcutRegistry
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(registry.definition(.showMarkerList).title) { openWindow(id: MarkersWindowScene.windowID) }
            .registryShortcut(.showMarkerList, registry)
    }
}
