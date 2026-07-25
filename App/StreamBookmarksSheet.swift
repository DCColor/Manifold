//
//  StreamBookmarksSheet.swift
//  Manifold
//
//  The stream-bookmark manager — a SHEET, not a submenu (renaming and deleting from a menu is
//  awkward). Reached from the streaming button's chevron ("Stream URL…") and the empty-state
//  "Connect Stream…" menu. This is shipping UI: it references WHEPClient, which now compiles in
//  every configuration.
//
//  Connecting and saving are DELIBERATELY separate actions: the saved list connects an existing
//  entry, the Add row saves WITHOUT connecting, and "Paste & Connect" connects a one-off URL that
//  is never persisted. Nothing here ever shows or logs a full URL — the row shows the host only,
//  because the path can carry the stream key.
//

import SwiftUI

struct StreamBookmarksSheet: View {
    @ObservedObject var store: StreamBookmarkStore
    /// Connect to a URL. Injected so the sheet holds no engine/WHEP handle and the caller owns the
    /// source takeover and dismissal.
    var onConnect: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    // Add form
    @State private var newName = ""
    @State private var newURL = ""
    @State private var addError: String?
    @State private var savedNotice: String?

    // Bare paste-and-connect (session only)
    @State private var pasteURL = ""
    @State private var pasteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Stream Sources").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            List {
                savedSection
                addSection
                pasteSection
            }
        }
        .frame(width: 460, height: 540)
    }

    // MARK: Saved list

    @ViewBuilder private var savedSection: some View {
        Section("Saved") {
            if store.bookmarks.isEmpty {
                Text("No saved streams. Add one below.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.bookmarks) { row($0) }
            }
        }
    }

    private func row(_ bookmark: StreamBookmark) -> some View {
        let supported = bookmark.type.isSupported
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(bookmark.name).fontWeight(.medium)
                    Text(bookmark.type.label)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                // Host only — never the path.
                Text(bookmark.type.unsupportedReason ?? bookmark.displayHost)
                    .font(.caption)
                    .foregroundStyle(supported ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
            Spacer()
            if supported {
                Button("Connect") { connect(bookmark) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button { store.delete(bookmark) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete this stream")
        }
        .opacity(supported ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { if supported { connect(bookmark) } }
    }

    private func connect(_ bookmark: StreamBookmark) {
        guard bookmark.type.isSupported, let url = bookmark.url else { return }
        onConnect(url)
    }

    // MARK: Add (save, no connect)

    @ViewBuilder private var addSection: some View {
        Section("Add a stream") {
            TextField("Name", text: $newName)
            TextField("Stream URL (https://… or srt://…)", text: $newURL)
            if let addError { Text(addError).font(.caption).foregroundStyle(.red) }
            if let savedNotice { Text(savedNotice).font(.caption).foregroundStyle(.orange) }
            Button("Save") { save() }
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func save() {
        switch store.add(name: newName, urlString: newURL) {
        case .success(let b):
            addError = nil; newName = ""; newURL = ""
            // Saved, but say plainly if it cannot connect yet — it is still listed.
            savedNotice = b.type.isSupported ? nil : (b.type.unsupportedReason.map { "Saved. \($0)." })
        case .failure(let e):
            savedNotice = nil; addError = e.message
        }
    }

    // MARK: Paste & connect (session only, not saved)

    @ViewBuilder private var pasteSection: some View {
        Section {
            TextField("Paste a URL to connect once", text: $pasteURL)
            if let pasteError { Text(pasteError).font(.caption).foregroundStyle(.red) }
            Button("Paste & Connect") { pasteAndConnect() }
                .disabled(pasteURL.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Connect without saving")
        } footer: {
            Text("Connects this URL for the current session only — it is not saved and won’t appear here after you quit.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pasteAndConnect() {
        switch StreamBookmarkStore.validate(pasteURL) {
        case .success(let (url, type)):
            guard type.isSupported else { pasteError = type.unsupportedReason; return }
            pasteError = nil
            onConnect(url)
        case .failure(let e):
            pasteError = e.message
        }
    }
}
