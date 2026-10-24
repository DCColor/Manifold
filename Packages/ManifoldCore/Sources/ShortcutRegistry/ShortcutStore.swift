//
//  ShortcutStore.swift — the user's overrides, in ONE defaults key, as JSON with sorted keys.
//
//      manifold.shortcuts = {"overrides":{"view.inspector":{"key":"i","modifiers":["command","option"]},
//                                         "view.fileName":null},"version":1}
//
//  `null` is "no key". A `code` entry names a physical key (`{"code":30,"modifiers":["option"]}`).
//
//  ── ⚠️ WRITTEN ONLY WHEN THE USER CHANGES A BINDING, AND ALWAYS READ FIRST ─────────────────────
//
//  CLAUDE.md: a defaults write replaces the value wholesale, and `streamBookmarks` was lost that way. So every
//  write starts from the value as it is in defaults NOW, changes the one entry, and writes the whole thing back.
//  Entries this build does not know (a newer build's actions) pass through untouched. When nothing is left, the
//  key is removed, so a user who resets everything has the same domain as one who never rebound anything.
//  A stored value that does not parse is never overwritten: the change is refused and logged.
//

import Foundation

public struct ShortcutStore {
    public static let defaultsKey = "manifold.shortcuts"
    public static let version = 1

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = ShortcutStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public enum ReadError: Error, Equatable { case notJSON, wrongShape }

    /// The stored document, or an empty one when the key is absent.
    public func read() -> Result<[String: Any], ReadError> {
        guard let value = defaults.object(forKey: key) else { return .success([:]) }
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return .failure(.notJSON) }
        guard let document = object as? [String: Any] else { return .failure(.wrongShape) }
        if let overrides = document["overrides"], !(overrides is [String: Any]) { return .failure(.wrongShape) }
        return .success(document)
    }

    /// Every stored override this build can read. Unknown IDs and unreadable entries are left out here and kept in
    /// defaults.
    public func overrides() -> [ShortcutID: KeyChord?] {
        guard case .success(let document) = read(),
              let raw = document["overrides"] as? [String: Any] else { return [:] }
        var result: [ShortcutID: KeyChord?] = [:]
        for (name, value) in raw {
            guard let id = ShortcutID(rawValue: name) else { continue }
            if value is NSNull { result.updateValue(nil, forKey: id); continue }
            if let chord = Self.decode(value) { result.updateValue(chord, forKey: id) }
        }
        return result
    }

    /// Read, apply `changes` (`.some(nil)` stores "no key", `nil` removes the override), write. Refuses, and
    /// writes nothing, when the stored value cannot be read.
    @discardableResult
    public func apply(_ changes: [ShortcutID: KeyChord??]) -> Bool {
        guard case .success(var document) = read() else {
            NSLog("[SHORTCUTS] the stored %@ value cannot be read — not overwriting it; the change is not saved", key)
            return false
        }
        var raw = document["overrides"] as? [String: Any] ?? [:]
        for (id, change) in changes {
            switch change {
            case .none: raw.removeValue(forKey: id.rawValue)
            case .some(.none): raw[id.rawValue] = NSNull()
            case .some(.some(let chord)): raw[id.rawValue] = Self.encode(chord)
            }
        }
        if raw.isEmpty {
            document.removeValue(forKey: "overrides")
        } else {
            document["overrides"] = raw
        }
        document.removeValue(forKey: "version")
        if document.isEmpty {
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            return true
        }
        document["version"] = Self.version
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return false }
        defaults.set(text, forKey: key)
        return true
    }

    static func encode(_ chord: KeyChord) -> [String: Any] {
        var entry: [String: Any] = ["modifiers": chord.modifiers.storedNames]
        switch chord.key {
        case .character(let c): entry["key"] = c
        case .code(let c): entry["code"] = Int(c)
        }
        return entry
    }

    static func decode(_ value: Any) -> KeyChord? {
        guard let entry = value as? [String: Any],
              let names = entry["modifiers"] as? [String], let mods = KeyModifiers(storedNames: names) else { return nil }
        if let c = entry["key"] as? String, c.count == 1 { return .char(c, mods) }
        if let n = entry["code"] as? Int, (0...0x7F).contains(n) { return .code(UInt16(n), mods) }
        return nil
    }
}
