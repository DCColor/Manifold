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
    @State private var newPassphrase = ""
    @State private var addError: String?
    @State private var savedNotice: String?

    /// ── THE REVEAL IS MOMENTARY, AND THAT IS A DESIGN DECISION, NOT A DEFAULT ───────────────
    ///
    /// A sticky show/hide toggle is the common pattern and it is the wrong one here. The state it
    /// creates is invisible from across a room and outlives the glance that wanted it: a passphrase
    /// revealed to check a typo stays revealed through the save, through the next screen share, and
    /// until someone notices. Manifold's whole reason for showing hosts and never paths is that a
    /// monitoring app is READ OVER SHOULDERS AND SHARED ON CALLS.
    ///
    /// So the plaintext is bound to a press: it appears while the eye is held down and is gone the
    /// instant it is released, and `newPassphrase` is never rendered unmasked without a finger on
    /// the control. There is no state to forget to undo.
    @State private var revealPassphrase = false
    @FocusState private var passphraseFocused: Bool

    // Bare paste-and-connect (session only)
    @State private var pasteURL = ""
    @State private var pasteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Stream Sources").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    // Nothing typed into the passphrase field outlives the sheet. A bare paste is
                    // session-only by design and a half-finished add is not worth keeping in memory.
                    .onDisappear { clearPassphraseEntry() }
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
        // connectURL, NOT bookmark.url — the stored URL has had its passphrase stripped out of it,
        // and this is the call that puts the Keychain's copy back for the duration of the dial.
        guard bookmark.type.isSupported,
              let url = StreamBookmarkStore.connectURL(for: bookmark) else { return }
        onConnect(url)
    }

    // MARK: Add (save, no connect)

    @ViewBuilder private var addSection: some View {
        Section("Add a stream") {
            TextField("Name", text: $newName)
            TextField("Stream URL (https://… or srt://…)", text: $newURL)
            // SHOWN ONLY FOR AN SRT URL, decided from what is typed as it is typed. A passphrase
            // field on an https bookmark would be a control that does nothing — WHEP has no such
            // concept — and an unexplained empty box invites someone to paste a stream key into it.
            if isEnteringSRT { passphraseField }
            if let addError { Text(addError).font(.caption).foregroundStyle(.red) }
            if let savedNotice { Text(savedNotice).font(.caption).foregroundStyle(.orange) }
            Button("Save") { save() }
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// True once what has been typed parses as an srt:// URL. Uses the SAME `StreamType.detect` the
    /// save path uses, so the field cannot appear for a URL that would then be saved as `.web`.
    private var isEnteringSRT: Bool {
        let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return false }
        return StreamType.detect(url) == .srt
    }

    @ViewBuilder private var passphraseField: some View {
        HStack(spacing: 6) {
            // Two fields, one binding. SecureField is what a password manager and the window server
            // both understand; swapping to a plain TextField for the duration of a press is the
            // only way to show the text at all, since SecureField cannot be asked to unmask.
            if revealPassphrase {
                TextField("Passphrase (optional)", text: $newPassphrase)
                    .focused($passphraseFocused)
            } else {
                SecureField("Passphrase (optional)", text: $newPassphrase)
                    .focused($passphraseFocused)
            }
            Image(systemName: revealPassphrase ? "eye.slash" : "eye")
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                // `pressing:` IS the whole mechanism: true on press-down, false on release, with no
                // tap-to-latch path. `perform:` is deliberately empty — a completed long press must
                // not leave anything switched on.
                .onLongPressGesture(minimumDuration: .infinity,
                                    pressing: { revealPassphrase = $0 },
                                    perform: {})
                .help("Hold to show the passphrase")
                .accessibilityLabel("Hold to show the passphrase")
        }
        // BELT AND BRACES FOR THE PRESS. If focus leaves the row while a press is somehow still
        // registered — a drag off the control, a window deactivation mid-press — the plaintext is
        // re-masked rather than left standing.
        .onChange(of: passphraseFocused) { _, focused in
            if !focused { revealPassphrase = false }
        }
    }

    private func save() {
        switch store.add(name: newName, urlString: newURL,
                         passphrase: isEnteringSRT ? newPassphrase : nil) {
        case .success(let b):
            addError = nil; newName = ""; newURL = ""
            clearPassphraseEntry()
            // Saved, but say plainly if it cannot connect yet — it is still listed.
            savedNotice = b.type.isSupported ? nil : (b.type.unsupportedReason.map { "Saved. \($0)." })
        case .failure(let e):
            savedNotice = nil; addError = e.message
            // The typed passphrase SURVIVES a failed save — the likeliest failure is the 10–79
            // length rule, and clearing the field would make the user retype a long secret to fix a
            // URL typo. It is cleared on success and on dismissal, not on a message.
        }
    }

    /// Wipe the entry state and the reveal with it, so no later render can show a stale value.
    private func clearPassphraseEntry() {
        newPassphrase = ""
        revealPassphrase = false
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
