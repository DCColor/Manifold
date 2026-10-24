//
//  KeyboardShortcutsView.swift — Help ▸ Keyboard Shortcuts… (docs/SHORTCUTS_AUDIT.md §4.5).
//
//  Every shortcut, grouped as the registry groups them, with the key as THIS layout prints it. Search by name, or
//  press a key to find what it does. Click a key to record a new one: Esc cancels, Delete removes the key. A key
//  another action holds asks Replace or Cancel, inline; a key macOS owns is refused; the registry's warnings (⌃⌥,
//  Fn, layout, not shown in a menu) show under the row. A customised row is marked and can be reset; so can a
//  category, or everything. With the debug gate on (the Debug menu's opt-in), the debug hooks are listed read-only.
//
//  ⚠️ RECORDING TAKES EVERY KEY, AND THE APP'S DISPATCHER TAKES NONE MEANWHILE (`registry.isRecording`): a key being
//  recorded must not also play, step or hold.
//

import SwiftUI
import AppKit
import ShortcutRegistry

enum KeyboardShortcutsScene {
    static let windowID = "keyboard-shortcuts"
    static let title = "Keyboard Shortcuts"
}

struct KeyboardShortcutsView: View {
    @ObservedObject var registry: ShortcutRegistry

    @State private var search = ""
    @State private var findChord: KeyChord?
    @State private var recording: Recording?
    @State private var pending: Pending?
    @State private var notes: [ShortcutID: Note] = [:]
    @State private var confirmResetAll = false
    @State private var monitor: Any?

    enum Recording: Equatable { case row(ShortcutID), find }
    struct Pending: Equatable { let id: ShortcutID; let chord: KeyChord; let others: [ShortcutID]; let warnings: [String] }
    struct Note: Equatable { let text: String; let isError: Bool }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(12)
            Divider()
            List {
                ForEach(ShortcutCategory.allCases.filter { $0 != .debug }, id: \.self) { category in
                    let rows = visible(in: category)
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { row($0) }
                        } header: {
                            categoryHeader(category)
                        }
                    }
                }
                if ShortcutDebugGate.showsDebugSection {
                    let rows = visible(in: .debug)
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { row($0) }
                        } header: {
                            Text("Debug hooks (read-only; shown because the Debug menu is on)")
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            footer
                .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 520, idealHeight: 680)
        .alert("Reset every shortcut to its default?", isPresented: $confirmResetAll) {
            Button("Reset All", role: .destructive) {
                registry.resetAll()
                notes = [:]
                pending = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every key you changed goes back to Manifold’s default.")
        }
        .onDisappear { stopRecording() }
    }

    // MARK: Parts

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search shortcuts", text: $search)
                .textFieldStyle(.roundedBorder)
            if let findChord {
                Button { self.findChord = nil } label: {
                    Label("Key: \(registry.label(findChord))", systemImage: "xmark.circle.fill")
                }
                .help("Show every shortcut again")
            }
            Button(recording == .find ? "Press a key…" : "Find by Key") {
                recording == .find ? stopRecording() : startRecording(.find)
            }
            .help("Press a key to see what it does")
        }
    }

    private func categoryHeader(_ category: ShortcutCategory) -> some View {
        HStack {
            Text(category.rawValue)
            Spacer()
            if registry.hasOverrides(in: category) {
                Button("Reset \(category.rawValue)") {
                    registry.reset(category: category)
                    for def in registry.definitions where def.category == category { notes[def.id] = nil }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    /// The mark on a row whose key differs from Manifold's default, and in the legend that explains it.
    private var customizedDot: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Click a shortcut to change it. Esc cancels; Delete removes the key.")
                // The dot's legend (Robbie, 2026-10-24: the dot alone did not say "customized").
                HStack(spacing: 5) {
                    customizedDot
                    Text("Customized: differs from Manifold’s default. The arrow resets it.")
                }
                .accessibilityElement(children: .combine)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Reset All…") { confirmResetAll = true }
                .disabled(!registry.hasOverrides)
                .help("Reset every shortcut to its default")
        }
    }

    @ViewBuilder
    private func row(_ def: ShortcutDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(def.title)
                    Text(subtitle(def))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if registry.isCustomised(def.id) {
                    customizedDot
                        .help("Customized")
                        .accessibilityLabel("Customized")
                }
                keyChip(def)
                if registry.isCustomised(def.id) {
                    Button {
                        registry.reset(def.id)
                        notes[def.id] = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(defaultLabel(def))")
                    .accessibilityLabel("Reset \(def.title)")
                }
            }
            if let pending, pending.id == def.id {
                conflictLine(pending)
            }
            if let note = notes[def.id] {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(note.isError ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func keyChip(_ def: ShortcutDefinition) -> some View {
        let label = registry.label(for: def.id) ?? "None"
        if def.rebindable {
            Button(recording == .row(def.id) ? "Type a shortcut…" : label) {
                recording == .row(def.id) ? stopRecording() : startRecording(.row(def.id))
            }
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 120)
            .help("Click, then press the new shortcut")
            // A SwiftUI Button in a List row exposes no title to Accessibility (MEASURED: only AXHelp), so VoiceOver
            // would not say the key. Say it.
            .accessibilityLabel("Shortcut for \(def.title)")
            .accessibilityValue(recording == .row(def.id) ? "Type a shortcut" : label)
        } else {
            Text(label)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 120)
                .help(def.debug != nil ? "A debug hook: not changeable" : "This shortcut cannot be changed")
        }
    }

    private func conflictLine(_ p: Pending) -> some View {
        let names = p.others.map { "“\(registry.definition($0).title)”" }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(registry.label(p.chord)) is used by \(names). Replace it there?")
                .font(.caption)
            if !p.warnings.isEmpty {
                Text(p.warnings.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Replace") {
                    if registry.assign(p.chord, to: p.id, replacing: true) {
                        for other in p.others {
                            notes[other] = Note(text: "Its key went to “\(registry.definition(p.id).title)”.", isError: false)
                        }
                        notes[p.id] = p.warnings.isEmpty ? nil : Note(text: p.warnings.joined(separator: " "), isError: false)
                    } else {
                        notes[p.id] = Note(text: "Not saved: the stored shortcuts could not be read.", isError: true)
                    }
                    pending = nil
                }
                Button("Cancel") { pending = nil }
            }
            .controlSize(.small)
        }
    }

    // MARK: Rows shown

    private func visible(in category: ShortcutCategory) -> [ShortcutDefinition] {
        registry.definitions.filter { def in
            guard def.category == category else { return false }
            if let tier = def.debug, !registry.isDebugEnabled(tier) { return false }
            if let findChord {
                let holds = registry.conflicts(for: findChord, scope: .app).contains(def.id)
                    || registry.chord(for: def.id) == findChord
                if !holds { return false }
            }
            let q = search.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return true }
            return def.title.localizedCaseInsensitiveContains(q)
                || (registry.label(for: def.id)?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func subtitle(_ def: ShortcutDefinition) -> String {
        var parts = [def.scope.label]
        if def.debug == .configDebug { parts.append("Debug configuration only") }
        if registry.isCustomised(def.id) { parts.append("Default: \(defaultLabel(def))") }
        if let note = def.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private func defaultLabel(_ def: ShortcutDefinition) -> String {
        def.defaultChord.map { registry.label($0, holdFor: def) } ?? "None"
    }

    // MARK: Recording

    private func startRecording(_ r: Recording) {
        stopRecording()
        pending = nil
        recording = r
        registry.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only this window's keys: a key typed elsewhere ends nothing and records nothing.
            guard event.window?.title == KeyboardShortcutsScene.title, let key = KeyEvent(event) else { return event }
            MainActor.assumeIsolated { recorded(key) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        registry.isRecording = false
    }

    private func recorded(_ key: KeyEvent) {
        guard let r = recording else { return }
        if key.modifiers.isEmpty, key.keyCode == KeyCode.escape { stopRecording(); return }
        stopRecording()
        if case .row(let id) = r, key.modifiers.isEmpty,
           key.keyCode == KeyCode.delete || key.keyCode == KeyCode.forwardDelete {
            apply(nil, to: id)
            return
        }
        switch r {
        case .find: findChord = key.recordedChord
        case .row(let id): apply(key.recordedChord, to: id)
        }
    }

    private func apply(_ chord: KeyChord?, to id: ShortcutID) {
        switch registry.propose(chord, for: id) {
        case .unchanged:
            notes[id] = nil
        case .refused(let message):
            notes[id] = Note(text: message, isError: true)
        case .accepted(let warnings):
            if registry.assign(chord, to: id) {
                notes[id] = warnings.isEmpty ? nil : Note(text: warnings.joined(separator: " "), isError: false)
            } else {
                notes[id] = Note(text: "Not saved: the stored shortcuts could not be read.", isError: true)
            }
        case .conflict(let others, let warnings):
            guard let chord else { return }
            notes[id] = nil
            pending = Pending(id: id, chord: chord, others: others, warnings: warnings)
        }
    }
}
