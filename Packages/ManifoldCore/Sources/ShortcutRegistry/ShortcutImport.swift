//
//  ShortcutImport.swift — judging a settings file's shortcuts as ONE SET (docs/SETTINGS_EXPORT_PLAN.md §4.3).
//
//  `propose` judges a key against the bindings in force, so a file that swaps two keys would be refused halfway. This
//  builds the set the import would leave, then judges each file binding against that set, with `propose`'s own checks
//  (`unusableReason`, `conflicts`), on this Mac's layout and this build's debug tiers.
//
//  An invalid binding is never imported. A binding that clashes with an action the file does not mention keeps
//  this Mac's key unless the user chooses the file's (`useFile`), which unbinds the other action, as Replace does in
//  the Keyboard Shortcuts window. Giving up a binding can put an action back on a key another file binding wanted, so
//  the judging repeats until nothing changes. It can only remove bindings, so it ends.
//
//  Writes nothing. `applyImport` does, in one `store.apply`, so entries this build cannot read stay in defaults.
//

import Foundation

public enum ShortcutImportMode: Sendable {
    /// The result is the defaults plus the file.
    case replaceAll
    /// The result is this Mac's overrides with the file's on top.
    case merge
}

public struct ShortcutImportPlan: Equatable {
    /// An action whose key the import changes.
    public struct Change: Equatable, Identifiable {
        public let id: ShortcutID
        public let title: String
        /// "None" is shown for nil.
        public let fromLabel: String?
        public let toLabel: String?
        public let warnings: [String]
    }

    /// A file binding on a key another action holds here.
    public struct Conflict: Equatable, Identifiable {
        public let id: ShortcutID
        public let title: String
        public let keyLabel: String
        /// The actions holding the key, by title.
        public let heldBy: [String]
        /// The user chose the file's key, so the actions above lose it.
        public let usesFile: Bool
    }

    /// A file entry that is not imported.
    public struct Left: Equatable {
        public let name: String
        public let reason: String
    }

    public let mode: ShortcutImportMode
    public let changes: [Change]
    public let conflicts: [Conflict]
    /// Invalid bindings. Never imported.
    public let refused: [Left]
    /// Entries this build has no use for: unknown ids, rows that cannot be rebound.
    public let skipped: [Left]

    /// The overrides the import leaves. An entry equal to the default is absent.
    let result: [ShortcutID: KeyChord?]
    /// The registry's revision this was judged against. A plan cannot be applied to bindings that have moved.
    let revision: Int
}

extension ShortcutRegistry {
    /// The stored `overrides` object as it stands, for a file. nil when the stored value cannot be read: nothing may be
    /// exported from it, and nothing may be imported over it.
    public func exportableOverrides() -> [String: Any]? {
        guard case .success(let document) = store.read() else { return nil }
        return document["overrides"] as? [String: Any] ?? [:]
    }

    /// How many actions the user has rebound.
    public var customizedCount: Int { overrides.count }

    /// `file` is a settings file's `overrides` object. `useFile`: the conflicts where the user chose the file's key.
    public func importPlan(file: [String: Any], mode: ShortcutImportMode,
                           useFile: Set<ShortcutID> = []) -> ShortcutImportPlan {
        var refused: [ShortcutImportPlan.Left] = []
        var skipped: [ShortcutImportPlan.Left] = []
        var accepted: [ShortcutID: KeyChord?] = [:]

        for name in file.keys.sorted() {
            guard let id = ShortcutID(rawValue: name) else {
                skipped.append(.init(name: name, reason: "This action isn’t in this version of Manifold."))
                continue
            }
            let def = definition(id)
            guard def.rebindable else {
                skipped.append(.init(name: def.title, reason: "This shortcut cannot be changed."))
                continue
            }
            let value = file[name] as Any
            if value is NSNull {
                accepted.updateValue(nil, forKey: id)
                continue
            }
            guard let chord = Self.fileChord(value) else {
                refused.append(.init(name: def.title, reason: "The file’s key for this action isn’t valid."))
                continue
            }
            if let reason = unusableReason(chord, on: def) {
                refused.append(.init(name: def.title, reason: reason))
                continue
            }
            accepted.updateValue(chord, forKey: id)
        }

        let base: [ShortcutID: KeyChord?] = mode == .merge ? overrides : [:]
        var kept: [ShortcutID: [ShortcutID]] = [:]      // conflicts that stay as they are
        var used: [ShortcutID: [ShortcutID]] = [:]      // conflicts the file wins
        var result = base

        while true {
            result = base.merging(accepted) { _, file in file }
            let current = result
            let holding: (ShortcutID) -> KeyChord? = { id in
                if let override = current[id] { return override }
                return self.definition(id).defaultChord
            }
            used = [:]
            var dropped: Set<ShortcutID> = []
            for def in definitions where accepted.keys.contains(def.id) {
                guard let chord = accepted[def.id] ?? nil else { continue }
                let clashes = conflicts(for: chord, scope: def.scope, excluding: def.id, holding: holding)
                guard !clashes.isEmpty else { continue }
                let key = normalized(chord)
                let immovable = clashes.first { other in
                    let d = definition(other)
                    return !d.rebindable || d.fixedChords.contains { normalized($0) == key }
                }
                if let immovable {
                    refused.append(.init(name: def.title, reason: "\(label(chord)) is used by “\(definition(immovable).title)”, "
                                         + "which cannot be changed."))
                    dropped.insert(def.id)
                } else if let other = clashes.first(where: { accepted.keys.contains($0) }) {
                    refused.append(.init(name: def.title, reason: "The file gives \(label(chord)) to “\(definition(other).title)” too."))
                    dropped.insert(def.id)
                } else if useFile.contains(def.id) {
                    used[def.id] = clashes
                } else {
                    kept[def.id] = clashes
                    dropped.insert(def.id)
                }
            }
            if dropped.isEmpty { break }
            for id in dropped { accepted.removeValue(forKey: id) }
        }

        for other in used.values.flatMap({ $0 }) { result.updateValue(nil, forKey: other) }
        for (id, value) in result where value == definition(id).defaultChord { result.removeValue(forKey: id) }

        let finished = result
        let after: (ShortcutID) -> KeyChord? = { id in
            if let override = finished[id] { return override }
            return self.definition(id).defaultChord
        }
        let changes: [ShortcutImportPlan.Change] = definitions.compactMap { def in
            guard def.rebindable else { return nil }
            let from = chord(for: def.id), to = after(def.id)
            guard from != to else { return nil }
            return .init(id: def.id, title: def.title, fromLabel: from.map { label($0, holdFor: def) },
                         toLabel: to.map { label($0, holdFor: def) },
                         warnings: to.map { warnings(for: $0, on: def) } ?? [])
        }
        let conflicts: [ShortcutImportPlan.Conflict] = definitions.compactMap { def in
            guard let holders = used[def.id] ?? kept[def.id], let chord = Self.fileChord(file[def.id.rawValue] as Any) else {
                return nil
            }
            return .init(id: def.id, title: def.title, keyLabel: label(chord, holdFor: def),
                         heldBy: holders.map { definition($0).title }, usesFile: used[def.id] != nil)
        }
        return ShortcutImportPlan(mode: mode, changes: changes, conflicts: conflicts, refused: refused, skipped: skipped,
                                  result: result, revision: revision)
    }

    /// Apply a plan in one write. False, with nothing changed, when the store refuses or the bindings have moved since
    /// the plan was made.
    @discardableResult
    public func applyImport(_ plan: ShortcutImportPlan) -> Bool {
        guard plan.revision == revision else { return false }
        guard !plan.changes.isEmpty else { return true }
        var changes: [ShortcutID: Change] = [:]
        for id in Set(overrides.keys).union(plan.result.keys) {
            if let value = plan.result[id] { changes[id] = .set(value) } else { changes[id] = .reset }
        }
        return commit(changes)
    }

    /// `ShortcutStore.decode`, held to more than the store needs: the file was not necessarily written by Manifold.
    static func fileChord(_ value: Any) -> KeyChord? {
        if let entry = value as? [String: Any], let code = entry["code"] as? NSNumber,
           CFGetTypeID(code) == CFBooleanGetTypeID() { return nil }
        guard let chord = ShortcutStore.decode(value) else { return nil }
        if case .character(let c) = chord.key,
           let scalar = c.unicodeScalars.first, scalar.value < 0x20 || scalar.properties.isWhitespace { return nil }
        return chord
    }
}
