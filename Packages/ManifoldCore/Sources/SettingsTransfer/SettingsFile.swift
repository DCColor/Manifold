//
//  SettingsFile.swift — the `.manifoldsettings` file (docs/SETTINGS_EXPORT_PLAN.md §2).
//
//  A file with shortcuts only is plain JSON, which any text editor opens. A file with streams is encrypted: that stage
//  is not built, and until it is `read` refuses one by name (`ReadError.encrypted`). The encrypted payload holds the
//  same `sections` object as a plain file, so `parseSections` is the one parser for both.
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
        public enum Reason: Equatable { case unknown, newerVersion, malformed }
        public let name: String
        public let reason: Reason

        public var message: String {
            switch reason {
            case .unknown:      return "From a newer Manifold, not imported."
            case .newerVersion: return "Made by a newer Manifold, not imported."
            case .malformed:    return "Damaged, not imported."
            }
        }
    }

    public struct Document {
        /// As the file states them; display only.
        public let appVersion: String?
        public let exportedAt: Date?
        /// The `overrides` object, as `ShortcutStore` stores it. nil when the file has no usable shortcuts section.
        public let shortcuts: [String: Any]?
        public let left: [LeftSection]
    }

    public enum ReadError: Error, Equatable {
        case tooLarge
        case damaged
        case notSettings
        /// `formatVersion` is above this build's. The file's own app version, when it states one.
        case newerFormat(String?)
        /// A file with streams. See the note at the top.
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
                return "This file holds saved streams, which this version of Manifold can’t import."
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

    /// Everything that can be refused before a preview is refused here. Writes nothing.
    public static func read(_ data: Data) -> Result<Document, ReadError> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return .failure(.damaged) }
        guard root["kind"] as? String == kind else { return .failure(.notSettings) }
        guard let version = wholeNumber(root["formatVersion"]), version >= 1 else { return .failure(.damaged) }
        let appVersion = root["appVersion"] as? String
        guard version <= formatVersion else { return .failure(.newerFormat(appVersion)) }
        if root["encryption"] != nil { return .failure(.encrypted) }
        guard let sections = root["sections"] as? [String: Any] else { return .failure(.damaged) }
        let parsed = parseSections(sections)
        return .success(Document(appVersion: appVersion,
                                 exportedAt: (root["exportedAt"] as? String).flatMap { dateFormatter().date(from: $0) },
                                 shortcuts: parsed.shortcuts, left: parsed.left))
    }

    /// One parser for a plain file's `sections` and, later, a decrypted payload's. A bad section costs that section.
    static func parseSections(_ sections: [String: Any]) -> (shortcuts: [String: Any]?, left: [LeftSection]) {
        var shortcuts: [String: Any]?
        var left: [LeftSection] = []
        for name in sections.keys.sorted() {
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
        return (shortcuts, left)
    }

    /// A JSON integer. Not a Boolean, and not 1.5.
    private static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return value as? Int
    }

    private static func dateFormatter() -> ISO8601DateFormatter { ISO8601DateFormatter() }
}
