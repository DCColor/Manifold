//
//  SettingsTransferUI.swift — Export Settings…, Import Settings… and Restore from Backup… (Settings ▸ General;
//  docs/SETTINGS_EXPORT_PLAN.md §4, §5).
//
//  Nothing is written until Import is pressed. Then: back up the shortcuts, read the backup back, apply in one write, and
//  add the streams. A backup that fails stops the import. The rules live in the packages (`SettingsFile`, `SealedFile`,
//  `StreamImportPlan`, `SettingsBackups`, `ShortcutRegistry.importPlan`), where `swift test` reaches them; this file
//  presents plans and applies them.
//
//  ⚠️ `[SETTINGS]` log lines carry counts only: never a name, host, URL, path or password. A wrong password and a changed
//  file are one failure, and the log does not tell them apart. Keychain reads and key derivation stay off the main thread.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ManifoldCore
import SettingsTransfer
import ShortcutRegistry
import StreamBookmarkModel

/// What Settings ▸ General presents: the two sheets and a refusal.
@MainActor
final class SettingsTransferModel: ObservableObject {
    @Published var showingExport = false
    @Published var importing: SettingsImportSession?
    @Published var refusal: String?

    static var fileType: UTType { UTType(filenameExtension: SettingsFile.fileExtension) ?? .json }

    var hasBackups: Bool { !SettingsBackups().list().isEmpty }

    static func chooseExportDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Settings"
        // The stem only: the panel adds the extension from `allowedContentTypes`, and given the full name it doubled it.
        panel.nameFieldStringValue = (SettingsFile.suggestedFilename(on: Date()) as NSString).deletingPathExtension
        panel.allowedContentTypes = [fileType]
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseFileToImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a Manifold settings file"
        panel.allowedContentTypes = [Self.fileType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, restoring: false)
    }

    func chooseBackupToRestore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a shortcuts backup"
        panel.allowedContentTypes = [Self.fileType]
        panel.directoryURL = SettingsBackups().directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, restoring: true)
    }

    private func open(_ url: URL, restoring: Bool) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= SettingsFile.maxBytes else { refusal = SettingsFile.ReadError.tooLarge.message; return }
        guard let data = try? Data(contentsOf: url) else {
            refusal = "Manifold couldn’t read this file."
            return
        }
        switch SettingsFile.inspect(data) {
        case .failure(let error):
            NSLog("[SETTINGS] file refused before the preview")
            refusal = error.message
        case .success(.encrypted(let sealed)):
            guard !restoring else {
                refusal = SettingsFile.ReadError.encrypted.message
                return
            }
            importing = SettingsImportSession(sealed: sealed)
        case .success(.plain(let document)):
            guard ShortcutCenter.shared.registry.exportableOverrides() != nil else {
                refusal = SettingsTransferWords.storedUnreadable
                return
            }
            importing = SettingsImportSession(document: document, restoring: restoring)
        }
    }
}

enum SettingsTransferWords {
    static let storedUnreadable = "Manifold can’t read your saved shortcuts, so it won’t export them or write over them."
    static let streamsUnreadable = "Manifold can’t read your saved streams, so it won’t export them or add to them."

    static var provenance: SettingsFile.Provenance {
        let info = Bundle.main.infoDictionary
        return SettingsFile.Provenance(appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                                       appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
                                       exportedAt: Date())
    }
}

// MARK: - Export

/// One export with streams: the Keychain pass, then the save. Off the main thread, because a read can wait on a macOS prompt
/// and the key derivation is slow on purpose.
@MainActor
final class SettingsExportRun: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case reading(position: Int, of: Int)
        case leftOut(StreamExportPass.Outcome)
        case saving
    }

    @Published private(set) var phase = Phase.choosing
    @Published var failure: String?
    private var reader: Task<StreamExportPass.Outcome?, Never>?

    /// The pass, in list order. `finish` gets a pass with nothing left out; otherwise the sheet asks.
    func read(_ bookmarks: [StreamBookmark], finish: @escaping (StreamExportPass.Outcome) -> Void) {
        failure = nil
        phase = .reading(position: 0, of: bookmarks.count)
        let store = StreamBookmarkStore.secretStore
        let total = bookmarks.count
        let reader = Task.detached { [weak self] in
            StreamExportPass.collect(bookmarks, from: store, progress: { position in
                Task { @MainActor in
                    guard let self, case .reading = self.phase else { return }
                    self.phase = .reading(position: position, of: total)
                }
            }, cancelled: { Task.isCancelled })
        }
        self.reader = reader
        Task {
            guard let outcome = await reader.value else { return }
            guard case .reading = phase else { return }
            NSLog("[SETTINGS] export pass: %d of %d stream(s) read, %d left out",
                  outcome.entries.count, total, outcome.leftOut.count)
            if outcome.leftOut.isEmpty { finish(outcome) } else { phase = .leftOut(outcome) }
        }
    }

    func stop() {
        reader?.cancel()
        phase = .choosing
    }

    /// The save panel, then the file. Nothing exists on disk before the user picks a place.
    func save(shortcuts: [String: Any]?, streams: StreamExportPass.Outcome, password: String, done: @escaping () -> Void) {
        guard let url = SettingsTransferModel.chooseExportDestination() else {
            phase = .choosing
            return
        }
        phase = .saving
        let provenance = SettingsTransferWords.provenance
        Task {
            let sealing = Task.detached { () -> Data? in
                try? SettingsFile.encodeEncrypted(shortcuts: shortcuts, streams: streams.entries, password: password,
                                                  provenance: provenance)
            }
            guard let data = await sealing.value, (try? data.write(to: url, options: .atomic)) != nil else {
                NSLog("[SETTINGS] ⚠️ export failed")
                failure = "Manifold couldn’t save the file. Nothing was exported."
                phase = .choosing
                return
            }
            NSLog("[SETTINGS] exported %d shortcut override(s), %d stream(s), %d left out, encrypted",
                  shortcuts?.count ?? 0, streams.entries.count, streams.leftOut.count)
            done()
        }
    }
}

struct ExportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = ShortcutCenter.shared.registry
    @ObservedObject private var streams = StreamBookmarkStore.shared
    @StateObject private var run = SettingsExportRun()
    @State private var includeShortcuts = true
    @State private var includeStreams = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var failure: String?

    private var overrides: [String: Any]? { registry.exportableOverrides() }
    private var count: Int { registry.customizedCount }
    private var shortcutsAvailable: Bool { overrides != nil && count > 0 }
    private var streamsAvailable: Bool { !streams.storedDataUnreadable && !streams.bookmarks.isEmpty }
    private var wantsShortcuts: Bool { includeShortcuts && shortcutsAvailable }
    private var wantsStreams: Bool { includeStreams && streamsAvailable }
    private var passwordProblem: String? { SettingsEncryption.passwordProblem(password, confirmation: confirmation) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Settings").font(.headline)
            switch run.phase {
            case .choosing: choosing
            case .reading(let position, let total): working("Reading stream \(max(position, 1)) of \(total)…", canStop: true)
            case .leftOut(let outcome): leftOut(outcome)
            case .saving: working("Encrypting…", canStop: false)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear { if case .reading = run.phase { run.stop() } }
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Keyboard shortcuts (\(count) customized)", isOn: $includeShortcuts)
                .disabled(!shortcutsAvailable)
            if overrides == nil {
                note(SettingsTransferWords.storedUnreadable, color: .orange)
            } else if count == 0 {
                note("You haven’t customized any shortcuts, so there’s nothing to export.")
            }
            Toggle("Saved streams (\(streams.bookmarks.count))", isOn: $includeStreams)
                .disabled(!streamsAvailable)
            if streams.storedDataUnreadable { note(SettingsTransferWords.streamsUnreadable, color: .orange) }
            if wantsStreams {
                passwordFields
            } else {
                note("A shortcuts file is plain text. It holds no stream addresses, passwords or license details.")
            }
            if let failure = failure ?? run.failure { note(failure, color: .orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(wantsShortcuts || wantsStreams) || (wantsStreams && passwordProblem != nil))
            }
        }
    }

    private var passwordFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            note("Stream names, addresses, URLs and passphrases are in this file, encrypted with your password.")
            labeled("Password") {
                SecureField("At least \(SettingsEncryption.minimumPasswordLength) characters", text: $password)
            }
            labeled("Confirm password") {
                SecureField("The same password again", text: $confirmation)
            }
            if let passwordTip { note(passwordTip.text, color: passwordTip.color) }
            note("This password can’t be recovered. Without it, nobody can open this file, including Graviton.", color: .orange)
        }
    }

    /// A title above the field, because a field's own hint goes as soon as it is typed in, and an empty one reads as a label.
    private func labeled(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout)
            field().labelsHidden()
        }
    }

    /// What Export is waiting for, while it is greyed.
    private var passwordTip: (text: String, color: Color)? {
        guard let passwordProblem else { return nil }
        if password.isEmpty { return ("Enter a password in both fields to export.", .secondary) }
        if SettingsEncryption.passwordProblem(password, confirmation: password) != nil { return (passwordProblem, .orange) }
        if confirmation.isEmpty { return ("Enter the same password in the second field to export.", .secondary) }
        return (passwordProblem, .orange)
    }

    private func working(_ text: String, canStop: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text)
            }
            if canStop {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { run.stop() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    /// A stream is in the file complete or not at all.
    private func leftOut(_ outcome: StreamExportPass.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(outcome.leftOut.count == 1 ? "1 stream couldn’t be read." : "\(outcome.leftOut.count) streams couldn’t be read.")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(outcome.leftOut.enumerated()), id: \.offset) { _, stream in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stream.name)
                            note(stream.reason)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            note("No file has been written yet.")
            HStack {
                Button("Cancel", role: .cancel) { run.stop() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export Without Them") { saveEncrypted(outcome) }
                    .disabled(outcome.entries.isEmpty && !wantsShortcuts)
                Button("Try Again") { readStreams() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func note(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.callout).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func export() {
        failure = nil
        if wantsStreams { readStreams() } else { exportPlain() }
    }

    private func readStreams() {
        run.read(streams.bookmarks) { saveEncrypted($0) }
    }

    private func saveEncrypted(_ outcome: StreamExportPass.Outcome) {
        run.save(shortcuts: wantsShortcuts ? overrides : nil, streams: outcome, password: password) { dismiss() }
    }

    private func exportPlain() {
        guard let overrides, let url = SettingsTransferModel.chooseExportDestination() else { return }
        do {
            let data = try SettingsFile.encodePlain(shortcuts: overrides, provenance: SettingsTransferWords.provenance)
            try data.write(to: url, options: .atomic)
            NSLog("[SETTINGS] exported %d shortcut override(s)", overrides.count)
            dismiss()
        } catch {
            NSLog("[SETTINGS] ⚠️ export failed")
            failure = "Manifold couldn’t save the file. Nothing was exported."
        }
    }
}

// MARK: - Import

/// One open file, from preview to done.
@MainActor
final class SettingsImportSession: ObservableObject, Identifiable {
    struct Done: Equatable {
        var changed = 0
        var backup: URL?
        var streams = StreamImport.Applied()
    }

    enum Phase: Equatable {
        /// An encrypted file, waiting for its password.
        case locked
        case opening
        /// Reading the existing streams the file's names match. Before the preview, because a read can raise a prompt.
        case comparing
        case preview
        case done(Done)
        case undone
    }

    private let sealed: SealedFile?
    @Published private(set) var document: SettingsFile.Document?
    /// A backup being restored: the result is exactly the backup, so there is no Merge.
    let restoring: Bool
    @Published var includeShortcuts = true
    @Published var includeStreams = true
    @Published var mode: ShortcutImportMode
    /// The conflicts where the user chose the file's key.
    @Published var useFile: Set<ShortcutID> = []
    @Published private(set) var streamPlan: StreamImportPlan?
    @Published private(set) var phase: Phase
    @Published private(set) var failure: String?

    private let registry = ShortcutCenter.shared.registry
    private let streams = StreamBookmarkStore.shared

    init(document: SettingsFile.Document, restoring: Bool) {
        sealed = nil
        self.document = document
        self.restoring = restoring
        mode = restoring ? .replaceAll : .merge
        phase = .preview
    }

    init(sealed: SealedFile) {
        self.sealed = sealed
        restoring = false
        mode = .merge
        phase = .locked
    }

    /// Off the main thread. Every failure is the one failure, and nothing has been written.
    func unlock(password: String) {
        guard let sealed, phase == .locked else { return }
        failure = nil
        phase = .opening
        Task {
            let opened = await Task.detached { sealed.open(password: password) }.value
            switch opened {
            case .failure(let error):
                NSLog("[SETTINGS] encrypted file not opened")
                failure = error.message
                phase = .locked
            case .success(let document):
                self.document = document
                await compare(document)
                phase = .preview
            }
        }
    }

    private func compare(_ document: SettingsFile.Document) async {
        guard let entries = document.streams, !streams.storedDataUnreadable else { return }
        phase = .comparing
        let existing = streams.bookmarks
        let store = StreamBookmarkStore.secretStore
        let rules = Self.rules
        streamPlan = await Task.detached {
            StreamImportPlan.make(entries: entries, existing: existing, rules: rules) {
                StreamSecrets.resolve($0, read: store.read(StreamExportPass.account(of: $0)))
            }
        }.value
    }

    private static var rules: StreamImportRules {
        StreamImportRules(urlProblem: { raw in
            if case .failure(let error) = StreamBookmarkStore.validate(raw) { return error.message }
            return nil
        }, passphraseLength: SRTClient.Endpoint.passphraseLengthRange, audioOffsetMs: FrameEngine.liveAudioOffsetRangeMs)
    }

    var streamsRefused: Bool { document?.streams != nil && streams.storedDataUnreadable }
    var shortcutsRefused: Bool { document?.shortcuts != nil && registry.exportableOverrides() == nil }

    /// Judged afresh on every draw, against the bindings as they are now.
    var plan: ShortcutImportPlan? {
        guard !shortcutsRefused else { return nil }
        return document?.shortcuts.map { registry.importPlan(file: $0, mode: mode, useFile: useFile) }
    }

    private var shortcutChanges: Bool { includeShortcuts && plan?.changes.isEmpty == false }
    private var streamAdditions: Bool { includeStreams && streamPlan?.additions.isEmpty == false }
    var canImport: Bool { shortcutChanges || streamAdditions }

    func perform() {
        failure = nil
        guard canImport else { return }
        var done = Done()
        if shortcutChanges, let plan {
            guard let current = registry.exportableOverrides() else {
                failure = SettingsTransferWords.storedUnreadable
                return
            }
            let backup: URL
            do {
                let data = try SettingsFile.encodePlain(shortcuts: current, provenance: SettingsTransferWords.provenance)
                backup = try SettingsBackups().write(data, at: Date())
            } catch {
                NSLog("[SETTINGS] ⚠️ backup failed — nothing imported")
                failure = "Manifold couldn’t save a backup of your shortcuts, so it imported nothing."
                return
            }
            guard registry.applyImport(plan) else {
                NSLog("[SETTINGS] ⚠️ shortcuts not imported — the store refused, or they changed during the preview")
                failure = "Your shortcuts weren’t changed. Check the list and try again."
                return
            }
            NSLog("[SETTINGS] imported: %d changed, %d conflict(s) kept, %d refused, %d skipped",
                  plan.changes.count, plan.conflicts.filter { !$0.usesFile }.count, plan.refused.count, plan.skipped.count)
            done.changed = plan.changes.count
            done.backup = backup
        }
        if streamAdditions, let streamPlan {
            done.streams = StreamImport.apply(streamPlan) { addition in
                switch streams.add(name: addition.name, urlString: addition.url, passphrase: addition.passphrase,
                                   audioOffsetMs: addition.audioOffsetMs, colorOverride: addition.colorOverride) {
                case .success(let bookmark): return .success(bookmark.id)
                case .failure(let error): return .failure(.init(reason: error.message))
                }
            }
            NSLog("[SETTINGS] imported streams: %d added, %d failed", done.streams.added.count, done.streams.failed.count)
        }
        phase = .done(done)
    }

    func undo() {
        failure = nil
        guard case .done(var done) = phase else { return }
        // Only the ids this import added: nothing else can be reached from here.
        StreamImport.undo(done.streams) { id in
            if let bookmark = streams.bookmarks.first(where: { $0.id == id }) { streams.delete(bookmark) }
        }
        done.streams.added = []
        if let backup = done.backup {
            guard let data = try? Data(contentsOf: backup),
                  case .success(let saved) = SettingsFile.read(data), let overrides = saved.shortcuts,
                  registry.applyImport(registry.importPlan(file: overrides, mode: .replaceAll)) else {
                NSLog("[SETTINGS] ⚠️ undo failed")
                failure = "Manifold couldn’t undo the import. Your backup is still saved: use Restore from Backup…"
                phase = .done(done)
                return
            }
        }
        NSLog("[SETTINGS] import undone")
        phase = .undone
    }
}

struct ImportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: SettingsImportSession
    @ObservedObject private var registry = ShortcutCenter.shared.registry
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.restoring ? "Restore Shortcuts" : "Import Settings").font(.headline)
            switch session.phase {
            case .locked: locked
            case .opening: working("Opening…")
            case .comparing: working("Comparing with your saved streams…")
            case .preview: preview
            case .done(let done): self.done(done)
            case .undone: finished("Everything is back as it was.")
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    // MARK: Password

    private var locked: some View {
        VStack(alignment: .leading, spacing: 12) {
            caption("This file is encrypted. Enter the password it was exported with.")
            SecureField("Password", text: $password)
                .onSubmit { if !password.isEmpty { session.unlock(password: password) } }
            if let failure = session.failure { caption(failure, color: .orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { session.unlock(password: password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
    }

    // MARK: Preview

    private var preview: some View {
        let plan = session.plan
        return VStack(alignment: .leading, spacing: 12) {
            if let origin { caption(origin) }
            if let plan {
                Toggle("Keyboard shortcuts", isOn: $session.includeShortcuts)
                if !session.restoring {
                    Picker("Keyboard shortcuts", selection: $session.mode) {
                        Text("Merge").tag(ShortcutImportMode.merge)
                        Text("Replace All").tag(ShortcutImportMode.replaceAll)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!session.includeShortcuts)
                    caption(session.mode == .merge
                            ? "Adds the file’s shortcuts to yours. Shortcuts the file doesn’t mention stay as they are."
                            : "Your shortcuts become the file’s. Shortcuts the file doesn’t mention go back to their defaults.")
                }
                if session.includeShortcuts { lists(plan) }
            } else if session.shortcutsRefused {
                caption(SettingsTransferWords.storedUnreadable, color: .orange)
            } else if session.streamPlan == nil {
                caption("This file has no shortcuts Manifold can import.")
            }
            if let streamPlan = session.streamPlan {
                Toggle("Saved streams", isOn: $session.includeStreams)
                if session.includeStreams { streamRows(streamPlan) }
            } else if session.streamsRefused {
                caption(SettingsTransferWords.streamsUnreadable, color: .orange)
            }
            ForEach(session.document?.left ?? [], id: \.name) { section in
                caption("“\(section.name)”: \(section.message)")
            }
            if let failure = session.failure { caption(failure, color: .orange) }
            HStack {
                if !session.canImport { caption("Nothing to change.") }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(session.restoring ? "Restore" : "Import") { session.perform() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canImport)
            }
        }
    }

    private var origin: String? {
        guard let version = session.document?.appVersion else { return nil }
        let date = session.document?.exportedAt?.formatted(date: .abbreviated, time: .shortened)
        return "Made by Manifold \(version)" + (date.map { ", \($0)" } ?? "") + "."
    }

    private func lists(_ plan: ShortcutImportPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !plan.changes.isEmpty {
                    header("Will change (\(plan.changes.count))")
                    ForEach(plan.changes) { change in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(change.title)
                                Spacer()
                                Text("\(change.fromLabel ?? "None") → \(change.toLabel ?? "None")")
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(change.warnings, id: \.self) { caption($0, color: .orange) }
                        }
                    }
                }
                if !plan.conflicts.isEmpty {
                    header("Key already in use (\(plan.conflicts.count))")
                    ForEach(plan.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("\(conflict.title): use the file’s key, \(conflict.keyLabel)", isOn: binding(conflict.id))
                            caption(conflict.usesFile
                                    ? "\(conflict.heldBy.joined(separator: ", ")) will have no key."
                                    : "Keeps this Mac’s key. \(conflict.heldBy.joined(separator: ", ")) holds \(conflict.keyLabel).")
                        }
                    }
                }
                let left = plan.refused + plan.skipped
                if !left.isEmpty {
                    header("Not imported (\(left.count))")
                    ForEach(Array(left.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            caption(item.reason)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
    }

    /// Add-only: nothing here can change a stream you already have.
    private func streamRows(_ plan: StreamImportPlan) -> some View {
        let added = plan.rows.filter { if case .added = $0.outcome { return true } else { return false } }
        let renamed = plan.rows.filter { if case .renamed = $0.outcome { return true } else { return false } }
        let here = plan.rows.filter { $0.outcome == .alreadyHere }
        let left = plan.rows.filter { if case .notImported = $0.outcome { return true } else { return false } }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !added.isEmpty {
                    header("Added (\(added.count))")
                    ForEach(added) { Text($0.name) }
                }
                if !renamed.isEmpty {
                    header("Renamed (\(renamed.count))")
                    ForEach(renamed) { row in
                        if case .renamed(let addition, let reason) = row.outcome {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(row.name) → \(addition.name)")
                                if let message = reason.message { caption(message) }
                            }
                        }
                    }
                }
                if !here.isEmpty {
                    header("Already here (\(here.count))")
                    ForEach(here) { Text($0.name).foregroundStyle(.secondary) }
                }
                if !left.isEmpty {
                    header("Not imported (\(left.count))")
                    ForEach(left) { row in
                        if case .notImported(let reason) = row.outcome {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                caption(reason)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
    }

    private func binding(_ id: ShortcutID) -> Binding<Bool> {
        Binding(get: { session.useFile.contains(id) },
                set: { if $0 { session.useFile.insert(id) } else { session.useFile.remove(id) } })
    }

    // MARK: After

    private func done(_ done: SettingsImportSession.Done) -> some View {
        let added = done.streams.added.count
        let backedUp = done.backup != nil
        return VStack(alignment: .leading, spacing: 12) {
            if done.changed > 0 {
                Text(done.changed == 1 ? "1 shortcut changed." : "\(done.changed) shortcuts changed.")
                caption("Your previous shortcuts were saved first. To go back later, use Restore from Backup… in Settings.")
            }
            if added > 0 || !done.streams.failed.isEmpty {
                Text(added == 1 ? "1 stream added." : "\(added) streams added.")
            }
            ForEach(Array(done.streams.failed.enumerated()), id: \.offset) { _, failed in
                caption("“\(failed.name)” wasn’t added. \(failed.reason)", color: .orange)
            }
            if done.streams.withOffset > 0 {
                caption((done.streams.withOffset == 1 ? "1 stream kept its saved A/V offset."
                         : "\(done.streams.withOffset) streams kept their saved A/V offsets.")
                        + " If this Mac monitors differently, check sync with A/V ▸ Calibrate…")
            }
            if let failure = session.failure { caption(failure, color: .orange) }
            HStack {
                if backedUp || added > 0 {
                    Button(session.restoring ? "Undo Restore" : "Undo Import") { session.undo() }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finished(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold))
    }

    private func caption(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.callout).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
