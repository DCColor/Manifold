//
//  SettingsTransferUI.swift — Export Settings…, Import Settings… and Restore from Backup… (Settings ▸ General;
//  docs/SETTINGS_EXPORT_PLAN.md §4, §5).
//
//  Nothing is written until Import is pressed. Then: back up the shortcuts, read the backup back, apply in one write. A
//  backup that fails stops the import. The rules live in the packages (`SettingsFile`, `SettingsBackups`,
//  `ShortcutRegistry.importPlan`), where `swift test` reaches them; this file presents plans and applies them.
//
//  `[SETTINGS]` log lines carry counts only.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SettingsTransfer
import ShortcutRegistry

/// What Settings ▸ General presents: the two sheets and a refusal.
@MainActor
final class SettingsTransferModel: ObservableObject {
    @Published var showingExport = false
    @Published var importing: SettingsImportSession?
    @Published var refusal: String?

    static var fileType: UTType { UTType(filenameExtension: SettingsFile.fileExtension) ?? .json }

    var hasBackups: Bool { !SettingsBackups().list().isEmpty }

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
        switch SettingsFile.read(data) {
        case .failure(let error):
            NSLog("[SETTINGS] file refused before the preview")
            refusal = error.message
        case .success(let document):
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

    static var provenance: SettingsFile.Provenance {
        let info = Bundle.main.infoDictionary
        return SettingsFile.Provenance(appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                                       appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
                                       exportedAt: Date())
    }
}

// MARK: - Export

struct ExportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = ShortcutCenter.shared.registry
    @State private var includeShortcuts = true
    @State private var failure: String?

    private var overrides: [String: Any]? { registry.exportableOverrides() }
    private var count: Int { registry.customizedCount }
    private var available: Bool { overrides != nil && count > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Settings").font(.headline)
            Toggle("Keyboard shortcuts (\(count) customized)", isOn: $includeShortcuts)
                .disabled(!available)
            if overrides == nil {
                note(SettingsTransferWords.storedUnreadable, color: .orange)
            } else if count == 0 {
                note("You haven’t customized any shortcuts, so there’s nothing to export.")
            }
            note("A shortcuts file is plain text. It holds no stream addresses, passwords or license details.")
            if let failure { note(failure, color: .orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!available || !includeShortcuts)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func note(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.callout).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func export() {
        guard let overrides else { return }
        let panel = NSSavePanel()
        panel.title = "Export Settings"
        // The stem only: the panel adds the extension from `allowedContentTypes`, and given the full name it doubled it.
        panel.nameFieldStringValue = (SettingsFile.suggestedFilename(on: Date()) as NSString).deletingPathExtension
        panel.allowedContentTypes = [SettingsTransferModel.fileType]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
    enum Phase: Equatable {
        case preview
        case done(changed: Int, backup: URL)
        case undone
    }

    let document: SettingsFile.Document
    /// A backup being restored: the result is exactly the backup, so there is no Merge.
    let restoring: Bool
    @Published var includeShortcuts = true
    @Published var mode: ShortcutImportMode
    /// The conflicts where the user chose the file's key.
    @Published var useFile: Set<ShortcutID> = []
    @Published private(set) var phase = Phase.preview
    @Published private(set) var failure: String?

    private let registry = ShortcutCenter.shared.registry

    init(document: SettingsFile.Document, restoring: Bool) {
        self.document = document
        self.restoring = restoring
        mode = restoring ? .replaceAll : .merge
    }

    /// Judged afresh on every draw, against the bindings as they are now.
    var plan: ShortcutImportPlan? {
        document.shortcuts.map { registry.importPlan(file: $0, mode: mode, useFile: useFile) }
    }

    func perform() {
        failure = nil
        guard includeShortcuts, let plan, !plan.changes.isEmpty else { return }
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
        phase = .done(changed: plan.changes.count, backup: backup)
    }

    func undo() {
        failure = nil
        guard case .done(_, let backup) = phase,
              let data = try? Data(contentsOf: backup),
              case .success(let saved) = SettingsFile.read(data), let overrides = saved.shortcuts,
              registry.applyImport(registry.importPlan(file: overrides, mode: .replaceAll)) else {
            NSLog("[SETTINGS] ⚠️ undo failed")
            failure = "Manifold couldn’t undo the import. Your backup is still saved: use Restore from Backup…"
            return
        }
        NSLog("[SETTINGS] import undone")
        phase = .undone
    }
}

struct ImportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: SettingsImportSession
    @ObservedObject private var registry = ShortcutCenter.shared.registry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.restoring ? "Restore Shortcuts" : "Import Settings").font(.headline)
            switch session.phase {
            case .preview: preview
            case .done(let changed, _): done(changed)
            case .undone: finished("Your shortcuts are back as they were.")
            }
        }
        .padding(20)
        .frame(width: 540)
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
            } else {
                caption("This file has no shortcuts Manifold can import.")
            }
            if !session.document.left.isEmpty {
                ForEach(session.document.left, id: \.name) { section in
                    caption("“\(section.name)”: \(section.message)")
                }
            }
            if let failure = session.failure { caption(failure, color: .orange) }
            HStack {
                if let plan, session.includeShortcuts, plan.changes.isEmpty { caption("Nothing to change.") }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(session.restoring ? "Restore" : "Import") { session.perform() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.includeShortcuts || plan?.changes.isEmpty != false)
            }
        }
    }

    private var origin: String? {
        guard let version = session.document.appVersion else { return nil }
        let date = session.document.exportedAt?.formatted(date: .abbreviated, time: .shortened)
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

    private func binding(_ id: ShortcutID) -> Binding<Bool> {
        Binding(get: { session.useFile.contains(id) },
                set: { if $0 { session.useFile.insert(id) } else { session.useFile.remove(id) } })
    }

    // MARK: After

    private func done(_ changed: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(changed == 1 ? "1 shortcut changed." : "\(changed) shortcuts changed.")
            caption("Your previous shortcuts were saved first. To go back later, use Restore from Backup… in Settings.")
            if let failure = session.failure { caption(failure, color: .orange) }
            HStack {
                Button(session.restoring ? "Undo Restore" : "Undo Import") { session.undo() }
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
