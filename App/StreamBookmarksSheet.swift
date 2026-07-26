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
//  entry, the composer saves WITHOUT connecting, and "Paste & Connect" connects a one-off URL that
//  is never persisted. Nothing here ever shows or logs a full URL — the row shows the host only,
//  because the path can carry the stream key.
//
//  ── EDITING IS A MODE, AND IT REUSES THE COMPOSER ────────────────────────────────────────────
//
//  The pencil on a row puts the sheet into edit mode: the same Name/URL/passphrase section retitles
//  itself "Edit stream", prefills, and grows a Cancel. There is no second form and no inline row
//  editor — one set of fields, one set of validation messages, one place to fix a bug in either.
//
//  Row TAP still connects. That is the common action and the documented intent of this list; edit
//  gets its own control rather than overloading the gesture that dials a stream.
//

import SwiftUI

struct StreamBookmarksSheet: View {
    @ObservedObject var store: StreamBookmarkStore
    /// Connect to a URL. Injected so the sheet holds no engine/WHEP handle and the caller owns the
    /// source takeover and dismissal.
    var onConnect: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    // The composer fields — shared by "Add a stream" and "Edit stream". See `editing`.
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newPassphrase = ""
    @State private var addError: String?
    @State private var savedNotice: String?

    /// Non-nil means the composer is EDITING this bookmark rather than adding a new one. Holding the
    /// bookmark rather than a bare id keeps its original name and type to hand, which the footer and
    /// the scheme-change warning both need.
    @State private var editing: StreamBookmark?

    /// Armed by the explicit "Remove stored passphrase" control, and ONLY by it. This is the state
    /// that distinguishes "delete the secret" from "the field is blank because we never loaded it" —
    /// a distinction a lone text field cannot make. Reset on every entry to and exit from edit mode.
    @State private var removePassphrase = false

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
                Button("Done") { dismiss() }
                    // ── RETURN GOES TO WHICHEVER BUTTON WOULD NOT LOSE WORK ────────────────────
                    //
                    // Done used to hold `.defaultAction` unconditionally, which made Return —
                    // pressed from inside the URL field, where it is the most natural keystroke in
                    // the sheet — dismiss and DISCARD the draft. The default action therefore moves
                    // to Save whenever the composer holds anything; `keyboardShortcut(_:)` takes an
                    // Optional precisely so a shortcut can be conditional, and the two conditions
                    // here are exact negations, so Return always has exactly one target and never
                    // two. Save is `.disabled` without a URL, so the one remaining case — a name
                    // typed but no URL — makes Return a no-op next to the message saying what is
                    // missing, rather than a discard.
                    .keyboardShortcut(composerIsDirty ? nil : .defaultAction)
                    // Nothing typed into the passphrase field outlives the sheet. A bare paste is
                    // session-only by design and a half-finished add is not worth keeping in memory.
                    .onDisappear { clearPassphraseEntry() }
            }
            .padding(16)
            Divider()
            List {
                savedSection
                composerSection
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
        let isEditing = editing?.id == bookmark.id
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
            Button { beginEditing(bookmark) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit this stream")
            Button {
                // Exit the mode FIRST if this is the row being edited, or the composer would keep
                // offering to save changes to an entry that no longer exists (`update` would answer
                // `.noLongerSaved`, which is a correct but pointless place to end up).
                if isEditing { cancelEditing() }
                store.delete(bookmark)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete this stream")
        }
        .opacity(supported ? 1 : 0.55)
        // The row being edited is marked, because the composer below is otherwise the only clue as
        // to WHICH stream those prefilled fields belong to.
        .listRowBackground(isEditing ? AnyView(Color.accentColor.opacity(0.12)) : AnyView(Color.clear))
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

    // MARK: Composer — add, or edit in place (save, never connect)

    @ViewBuilder private var composerSection: some View {
        Section {
            // The name is OPTIONAL and the placeholder now says so, because Save is not gated on it
            // (it is gated on the URL) and a blank one falls back to the host in `add`/`update`.
            // Labelling it plainly "Name" implied a requirement that was never enforced.
            TextField("Name (optional — defaults to the host)", text: $newName)
            TextField("Stream URL (https://… or srt://…)", text: $newURL)
            // SHOWN ONLY FOR AN SRT URL, decided from what is typed as it is typed. A passphrase
            // field on an https bookmark would be a control that does nothing — WHEP has no such
            // concept — and an unexplained empty box invites someone to paste a stream key into it.
            if isEnteringSRT {
                passphraseField
                if editing != nil { passphraseRemovalControl }
            }
            if willDropStoredPassphrase {
                Text("This is no longer an SRT address, so its stored passphrase will be removed when you save.")
                    .font(.caption).foregroundStyle(.orange)
                    .wrapsInsteadOfClipping()
            }
            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red).wrapsInsteadOfClipping()
            }
            if let savedNotice {
                Text(savedNotice).font(.caption).foregroundStyle(.orange).wrapsInsteadOfClipping()
            }
            // .firstTextBaseline, so when the reason below wraps to two lines its FIRST line still
            // sits level with the button text instead of the block centring itself against them.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(editing == nil ? "Save" : "Save Changes") { save() }
                    .disabled(!canSave)
                    .keyboardShortcut(composerIsDirty ? .defaultAction : nil)
                if editing != nil {
                    Button("Cancel") { cancelEditing() }
                        .keyboardShortcut(.cancelAction)
                }
                // ⚠️ THE REASON IS STATED, NOT LEFT TO BE INFERRED FROM THE GREY. A disabled button
                // with no explanation reads as a bug in the app rather than a gap in the form, and
                // this one was doubly misleading: the obvious guess is the empty Name field, but the
                // gate has always been the URL.
                //
                // It shares a row with up to two buttons in a 460pt sheet, so it is the most likely
                // label here to be squeezed — hence the wrap. A reason clipped to "Enter a stream…"
                // would be no better than the bare grey it replaced.
                if !canSave {
                    Text("Enter a stream URL to save")
                        .font(.caption).foregroundStyle(.secondary)
                        .wrapsInsteadOfClipping()
                }
            }
            // A CONTENT ROW, NOT `Section(footer:)` — see the measurement note on `composerFooter`.
            composerFooter
        } header: {
            Text(editing == nil ? "Add a stream" : "Edit stream")
        }
    }

    /// ── WHAT HAPPENS TO WHAT IS TYPED HERE, SAID OUT LOUD ────────────────────────────────────
    ///
    /// `Done` dismisses and nothing else: `save()` is the only path that writes to the store, so an
    /// unfinished draft is discarded. That was already true and already correct — the defect was
    /// that the sheet never said so, leaving the user to either test it or hesitate. The fix is this
    /// sentence, plus Return no longer being the discard key (see the Done button), NOT a Cancel
    /// button beside Done doing the identical thing under a name that implies otherwise.
    /// ── ⚠️ THIS IS A CONTENT ROW ON PURPOSE. DO NOT MOVE IT BACK INTO `Section(footer:)`. ───────
    ///
    /// It lived in `footer:` and was clipped to one line — the edit-mode sentence landed as
    /// `…press Save Changes. Canc…`, losing precisely the clause about Cancel that it exists to
    /// state. A truncated explanation of an ambiguity is worse than none, because it looks like the
    /// app tried to tell you and the app is what failed.
    ///
    /// THE TEXT WAS NEVER THE PROBLEM, AND NO MODIFIER ON IT IS THE FIX. Measured in an offscreen
    /// NSWindow at this sheet's real 460pt width, resolved label height for the same string:
    ///
    ///     Section footer, bare .................... 13pt — one line, clipped
    ///     Section footer + fixedSize .............. 13pt — one line, clipped
    ///     Section footer + frame(maxWidth:.inf) ... 13pt — one line, clipped
    ///     Section footer + HStack{text; Spacer} ... 13pt — one line, clipped
    ///     SECTION CONTENT + fixedSize ............. 26pt — WRAPS
    ///
    /// A macOS `List` lays a `Section` footer out against a width that does not bound its content,
    /// so the label sizes to one ideal line and the row clips it; nothing applied INSIDE the footer
    /// changes what the footer proposes. Only leaving `footer:` does. The `Group` carries the
    /// modifiers so any branch added later inherits them.
    @ViewBuilder private var composerFooter: some View {
        Group {
            if let editing {
                Text("Editing “\(editing.name)”. Changes aren’t saved until you press Save Changes. Cancel leaves this stream as it was, and Done closes the sheet without saving.")
                    .foregroundStyle(.secondary)
            } else if composerIsDirty {
                Text("Unsaved — Done will discard this draft.")
                    .foregroundStyle(.orange)
            } else {
                Text("Streams aren’t saved until you press Save. Done closes this sheet and discards anything typed here.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        // Full row width, left aligned, THEN allowed to grow downwards. The measured combination.
        .frame(maxWidth: .infinity, alignment: .leading)
        .wrapsInsteadOfClipping()
    }

    /// The one gate on Save, and the thing the disabled message describes. The name is deliberately
    /// absent: blank is legal and becomes the host.
    private var canSave: Bool { !newURL.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Is there anything in the composer that pressing Done would throw away? Edit mode counts as
    /// dirty unconditionally — the fields are prefilled, so "empty" is not a state it has, and the
    /// pending change is the whole point of being in it.
    private var composerIsDirty: Bool {
        if editing != nil { return true }
        return !newName.trimmingCharacters(in: .whitespaces).isEmpty
            || !newURL.trimmingCharacters(in: .whitespaces).isEmpty
            || !newPassphrase.isEmpty
    }

    /// True once what has been typed parses as an srt:// URL. Uses the SAME `StreamType.detect` the
    /// save path uses, so the field cannot appear for a URL that would then be saved as `.web`.
    private var isEnteringSRT: Bool {
        let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return false }
        return StreamType.detect(url) == .srt
    }

    /// Warn before an edit takes a passphrase away as a side effect of changing the address —
    /// `update` deletes the Keychain item whenever the recomputed type is not `.srt`, and that is not
    /// a consequence anyone reads into typing "https".
    ///
    /// Gated on the typed URL being VALID and of another type, not merely on `!isEnteringSRT`, so the
    /// warning does not strobe through every intermediate state while the field is being retyped.
    private var willDropStoredPassphrase: Bool {
        guard let editing, editing.type == .srt else { return false }
        guard case .success(let parsed) = StreamBookmarkStore.validate(newURL) else { return false }
        return parsed.type != .srt
    }

    @ViewBuilder private var passphraseField: some View {
        HStack(spacing: 6) {
            // ── THE PLACEHOLDER CARRIES THE SEMANTICS IN EDIT MODE ────────────────────────────
            //
            // The stored passphrase is NEVER read back into this field. Doing so would put a live
            // credential on screen in a sheet whose entire premise is that secrets are not left
            // lying in the UI, and — on this Mac's file-based keychain — the read itself can raise an
            // authorization dialog, which merely opening an edit form has no business doing.
            //
            // So the field starts blank, and blank means LEAVE IT ALONE. The placeholder is the only
            // thing that says so, which is why it is not the generic "optional" string here.
            let prompt = editing == nil ? "Passphrase (optional)"
                                        : "Passphrase (unchanged — type to replace)"
            // Two fields, one binding. SecureField is what a password manager and the window server
            // both understand; swapping to a plain TextField for the duration of a press is the
            // only way to show the text at all, since SecureField cannot be asked to unmask.
            if revealPassphrase {
                TextField(prompt, text: $newPassphrase)
                    .focused($passphraseFocused)
            } else {
                SecureField(prompt, text: $newPassphrase)
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
        // Typing is a replacement, and a replacement outranks a queued removal. Disarming here means
        // the two controls can never both be "on" and `save()` never has to guess which the user
        // meant last.
        .onChange(of: newPassphrase) { _, typed in
            if !typed.isEmpty { removePassphrase = false }
        }
    }

    /// ── REMOVAL IS ITS OWN CONTROL, NOT AN EMPTY FIELD ──────────────────────────────────────────
    ///
    /// Blank means unchanged, so blank cannot also mean delete; there has to be a second, explicit
    /// way to say it. Armed rather than immediate, so it is undoable and lands with the same Save as
    /// every other edit.
    ///
    /// ⚠️ SHOWN FOR EVERY SRT BOOKMARK, WITHOUT FIRST CHECKING WHETHER ONE IS STORED. The obvious
    /// gate — `KeychainStore.streams.get(id) != nil` — is a Keychain READ, and these items live in
    /// the ACL-guarded file keychain (verified: they are in login.keychain-db), where a read can
    /// raise an authorization prompt. A password dialog appearing because someone clicked a pencil
    /// would make the app feel like it was doing something it had not been asked to do. `update`'s
    /// `.remove` path is a no-op when nothing is stored, so the cost of showing this to a bookmark
    /// that has no passphrase is one harmless `SecItemDelete`.
    @ViewBuilder private var passphraseRemovalControl: some View {
        if removePassphrase {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Stored passphrase will be removed when you save.")
                    .font(.caption).foregroundStyle(.orange)
                    .wrapsInsteadOfClipping()
                Button("Undo") { removePassphrase = false }
                    .buttonStyle(.link).font(.caption)
                    .fixedSize()   // never let the wrapping text above squeeze the Undo away
            }
        } else {
            Button("Remove stored passphrase") {
                removePassphrase = true
                // Clear the field with the same gesture, so the armed state is not sitting next to
                // text that contradicts it.
                clearPassphraseEntry()
            }
            .buttonStyle(.link).font(.caption)
            .help("Delete this stream’s passphrase from your keychain when you save")
        }
    }

    // MARK: Save — add or update, decided by `editing`

    private func save() {
        if let editing {
            switch store.update(editing, name: newName, urlString: newURL,
                                passphrase: passphraseEdit()) {
            case .success(let b):
                addError = nil
                endEditing()
                savedNotice = b.type.isSupported ? nil : (b.type.unsupportedReason.map { "Saved. \($0)." })
            case .failure(let e):
                savedNotice = nil; addError = e.message
                // Same reasoning as the add path: a typed passphrase survives a failed save.
            }
        } else {
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
    }

    /// Collapse the two passphrase controls into the store's three-way. PRECEDENCE IS TYPED-WINS,
    /// which costs nothing in practice because `passphraseField` disarms the removal the moment
    /// anything is typed — this ordering is the belt to that braces.
    private func passphraseEdit() -> StreamBookmarkStore.PassphraseEdit {
        if !newPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .set(newPassphrase)
        }
        return removePassphrase ? .remove : .unchanged
    }

    // MARK: Edit-mode transitions

    private func beginEditing(_ bookmark: StreamBookmark) {
        editing = bookmark
        newName = bookmark.name
        newURL = bookmark.urlString      // the STORED URL, which by construction carries no secret
        clearPassphraseEntry()           // never prefilled — see `passphraseField`
        removePassphrase = false
        addError = nil
        savedNotice = nil
    }

    private func cancelEditing() {
        endEditing()
        savedNotice = nil
    }

    /// Leave edit mode and return the composer to its empty add state. Deliberately does NOT touch
    /// `savedNotice`, so `save()` can set one immediately afterwards.
    private func endEditing() {
        editing = nil
        newName = ""; newURL = ""
        clearPassphraseEntry()
        removePassphrase = false
        addError = nil
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
            // A CONTENT ROW for the same measured reason as `composerFooter` — this string is the
            // longest in the sheet and was clipping at "…won’t appear here…", which drops the one
            // fact it carries: that the URL does not survive a quit.
            Text("Connects this URL for the current session only — it is not saved and won’t appear here after you quit.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .wrapsInsteadOfClipping()
        } header: {
            Text("Connect without saving")
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

private extension View {
    /// Let a label grow DOWNWARDS to fit rather than truncating sideways.
    ///
    /// Every explanatory string in this sheet is prose that has to be read to the end to be worth
    /// anything — which button discards, which field is optional, what a save is about to remove. A
    /// `Text` in a `List` row inside a fixed 460pt sheet will happily clip such a sentence to one
    /// line and an ellipsis, and the clipped tail is reliably the consequential half.
    ///
    /// `fixedSize(vertical: true)` pins the height to the ideal height for the width on offer, so the
    /// layout must give the label the lines it asks for; `horizontal: false` leaves the width still
    /// flexible so it wraps to the sheet instead of demanding one long line. Named rather than
    /// inlined at eight call sites because the argument pair reads backwards from its effect.
    ///
    /// ⚠️ NECESSARY, NOT SUFFICIENT — IT ONLY WORKS WHERE THE PARENT PROPOSES A BOUNDED WIDTH. It is
    /// measurably a no-op inside `Section(footer:)` on macOS (13pt, still one line, with or without
    /// it). If a label wrapped with this still clips, the container is the bug; see the measurement
    /// table on `composerFooter` before adding another modifier here.
    func wrapsInsteadOfClipping() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}
