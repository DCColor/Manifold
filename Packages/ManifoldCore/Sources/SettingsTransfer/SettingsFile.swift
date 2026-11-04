//
//  SettingsFile.swift — the `.manifoldsettings` file (docs/SETTINGS_EXPORT_PLAN.md §2).
//
//  A file with shortcuts only is plain JSON, which any text editor opens. A file with streams is encrypted
//  (`SettingsEncryption.swift`), and there is no way to write a plain one: `encodePlain` takes no streams, and a plain
//  file's `streams` section is never read. The encrypted payload holds the same `sections` object as a plain file, so
//  `parseSections` is the one parser for both.
//
//  `inspect` is the reader for a file the user chose. `read` takes plain files only, which is what a backup is.
//
//  No machine name, user name, path or display identity is ever written. `formatVersion` goes up only when an older
//  reader would misread a file: new optional fields and new sections do not raise it.
//

import Foundation

public enum SettingsFile {
    public static let kind = "com.graviton.manifold.settings"
    public static let fileExtension = "manifoldsettings"
    public static let formatVersion = 1
    public static let shortcutsVersion = 1
    public static let streamsVersion = 1
    /// Far above any real file. A larger one is refused before it is parsed.
    public static let maxBytes = 1_048_576

    public struct Provenance: Equatable {
        public var appVersion: String
        public var appBuild: String
        public var exportedAt: Date

        public init(appVersion: String, appBuild: String, exportedAt: Date) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.exportedAt = exportedAt
        }
    }

    /// A section this build read past, and why.
    public struct LeftSection: Equatable {
        public enum Reason: Equatable { case unknown, newerVersion, malformed, notEncrypted }
        public let name: String
        public let reason: Reason

        public var message: String {
            switch reason {
            case .unknown:      return "From a newer Manifold, not imported."
            case .newerVersion: return "Made by a newer Manifold, not imported."
            case .malformed:    return "Damaged, not imported."
            case .notEncrypted: return "Not encrypted, so not imported."
            }
        }
    }

    public struct Document: @unchecked Sendable {
        /// As the file states them; display only.
        public let appVersion: String?
        public let exportedAt: Date?
        /// The `overrides` object, as `ShortcutStore` stores it. nil when the file has no usable shortcuts section.
        public let shortcuts: [String: Any]?
        /// The `entries` array, unjudged: each entry stands or falls alone (`StreamImportPlan`). Only ever set from an
        /// encrypted payload. nil when the file has no usable streams section.
        public let streams: [Any]?
        public let left: [LeftSection]
    }

    /// What `inspect` found.
    public enum Inspected {
        case plain(Document)
        case encrypted(SealedFile)
    }

    public enum ReadError: Error, Equatable {
        case tooLarge
        case damaged
        case notSettings
        /// `formatVersion` is above this build's. The file's own app version, when it states one.
        case newerFormat(String?)
        /// An encrypted file, given to `read`: a backup is never one.
        case encrypted

        public var message: String {
            switch self {
            case .tooLarge, .damaged:
                return "This file is damaged, or it isn’t a Manifold settings file."
            case .notSettings:
                return "This isn’t a Manifold settings file."
            case .newerFormat(let version):
                return "This file was made by \(version.map { "Manifold \($0)" } ?? "a newer Manifold"). "
                    + "Update Manifold to import it."
            case .encrypted:
                return "This file is encrypted, so it isn’t a shortcuts backup. Use Import Settings… to open it."
            }
        }
    }

    // MARK: Writing

    /// A plain file. Sorted keys, so the same settings give the same bytes.
    public static func encodePlain(shortcuts: [String: Any], provenance: Provenance) throws -> Data {
        let document: [String: Any] = [
            "kind": kind,
            "formatVersion": formatVersion,
            "appVersion": provenance.appVersion,
            "appBuild": provenance.appBuild,
            "exportedAt": dateFormatter().string(from: provenance.exportedAt),
            "sections": ["shortcuts": ["version": shortcutsVersion, "overrides": shortcuts] as [String: Any]],
        ]
        return try JSONSerialization.data(withJSONObject: document,
                                          options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    /// `Manifold Settings 2026-11-03.manifoldsettings`
    public static func suggestedFilename(on date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "Manifold Settings \(f.string(from: date)).\(fileExtension)"
    }

    // MARK: Reading

    /// A plain file. Everything that can be refused before a preview is refused here. Writes nothing.
    public static func read(_ data: Data) -> Result<Document, ReadError> {
        switch root(of: data) {
        case .failure(let error): return .failure(error)
        case .success(let root):
            if root["encryption"] != nil { return .failure(.encrypted) }
            return plainDocument(root)
        }
    }

    /// Either kind of file. An encrypted file that cannot be read as a header is refused here, before any password is
    /// asked for (R6). Everything past that is `SealedFile.open`, and its one message. Writes nothing.
    public static func inspect(_ data: Data) -> Result<Inspected, ReadError> {
        switch root(of: data) {
        case .failure(let error): return .failure(error)
        case .success(let root):
            guard root["encryption"] != nil else { return plainDocument(root).map(Inspected.plain) }
            guard let sealed = SealedFile(root: root) else { return .failure(.damaged) }
            return .success(.encrypted(sealed))
        }
    }

    /// The checks both kinds of file share.
    private static func root(of data: Data) -> Result<[String: Any], ReadError> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return .failure(.damaged) }
        guard root["kind"] as? String == kind else { return .failure(.notSettings) }
        guard let version = wholeNumber(root["formatVersion"]), version >= 1 else { return .failure(.damaged) }
        guard version <= formatVersion else { return .failure(.newerFormat(root["appVersion"] as? String)) }
        return .success(root)
    }

    private static func plainDocument(_ root: [String: Any]) -> Result<Document, ReadError> {
        guard let sections = root["sections"] as? [String: Any] else { return .failure(.damaged) }
        let parsed = parseSections(sections, encrypted: false)
        return .success(Document(appVersion: root["appVersion"] as? String, exportedAt: exportDate(root),
                                 shortcuts: parsed.shortcuts, streams: nil, left: parsed.left))
    }

    static func exportDate(_ root: [String: Any]) -> Date? {
        (root["exportedAt"] as? String).flatMap { dateFormatter().date(from: $0) }
    }

    /// One parser for a plain file's `sections` and a decrypted payload's. A bad section costs that section. Streams are
    /// read from a decrypted payload only.
    static func parseSections(_ sections: [String: Any],
                              encrypted: Bool) -> (shortcuts: [String: Any]?, streams: [Any]?, left: [LeftSection]) {
        var shortcuts: [String: Any]?
        var streams: [Any]?
        var left: [LeftSection] = []
        for name in sections.keys.sorted() {
            if name == "streams" {
                guard encrypted else {
                    left.append(LeftSection(name: name, reason: .notEncrypted))
                    continue
                }
                guard let section = sections[name] as? [String: Any], let version = wholeNumber(section["version"]),
                      version >= 1 else {
                    left.append(LeftSection(name: name, reason: .malformed))
                    continue
                }
                guard version <= streamsVersion else {
                    left.append(LeftSection(name: name, reason: .newerVersion))
                    continue
                }
                guard let entries = section["entries"] as? [Any] else {
                    left.append(LeftSection(name: name, reason: .malformed))
                    continue
                }
                streams = entries
                continue
            }
            guard name == "shortcuts" else {
                left.append(LeftSection(name: name, reason: .unknown))
                continue
            }
            guard let section = sections[name] as? [String: Any], let version = wholeNumber(section["version"]),
                  version >= 1 else {
                left.append(LeftSection(name: name, reason: .malformed))
                continue
            }
            guard version <= shortcutsVersion else {
                left.append(LeftSection(name: name, reason: .newerVersion))
                continue
            }
            guard let overrides = section["overrides"] as? [String: Any] else {
                left.append(LeftSection(name: name, reason: .malformed))
                continue
            }
            shortcuts = overrides
        }
        return (shortcuts, streams, left)
    }

    /// A JSON integer. Not a Boolean, and not 1.5.
    static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return value as? Int
    }

    static func dateFormatter() -> ISO8601DateFormatter { ISO8601DateFormatter() }
}
