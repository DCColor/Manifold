//
//  StreamTransfer.swift — saved streams in a settings file (docs/SETTINGS_EXPORT_PLAN.md §2.4, §3.2, §4.2).
//
//  Here rather than in the app so `swift test` runs every rule on an in-memory store. The app passes in its Keychain
//  reads, `StreamBookmarkStore.add` and `delete`, and the limits only it knows (`StreamImportRules`).
//
//  ⚠️ STREAM IMPORT IS ADD-ONLY. Nothing here can change or remove an existing stream or its Keychain item: `apply` only
//  adds, and `undo` removes only the ids `apply` returned. Log lines elsewhere carry counts and positions only: never a
//  value from these types.
//

import Foundation
import StreamBookmarkModel

/// One stream in a file: these six fields and no others. `StreamBookmark` is never encoded. `url` is `StreamSecret.url`,
/// without the passphrase, which has its own field. There is no `id`: an import mints a new one, as `add` does.
public struct StreamExportEntry: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var url: String
    public var passphrase: String?
    public var audioOffsetMs: Int?
    public var colorOverride: String?

    public init(name: String, type: String, url: String, passphrase: String?, audioOffsetMs: Int?, colorOverride: String?) {
        self.name = name
        self.type = type
        self.url = url
        self.passphrase = passphrase
        self.audioOffsetMs = audioOffsetMs
        self.colorOverride = colorOverride
    }
}

// MARK: - Export

/// One pass over the list. A stream is in the file complete or not at all, and one refusal does not end the pass.
public enum StreamExportPass {
    public struct LeftOut: Equatable, Sendable {
        public let name: String
        public let reason: String
    }

    public struct Outcome: Equatable, Sendable {
        public var entries: [StreamExportEntry] = []
        public var leftOut: [LeftOut] = []
    }

    /// The Keychain account that holds `bookmark`'s secret.
    public static func account(of bookmark: StreamBookmark) -> String { bookmark.secretRef ?? bookmark.id.uuidString }

    /// `progress` gets each position before its read. nil when `cancelled` said stop.
    public static func collect(_ bookmarks: [StreamBookmark], from store: StreamSecretStore,
                               progress: (Int) -> Void = { _ in }, cancelled: () -> Bool = { false }) -> Outcome? {
        var out = Outcome()
        for (i, bookmark) in bookmarks.enumerated() {
            if cancelled() { return nil }
            progress(i + 1)
            switch StreamSecrets.resolve(bookmark, read: store.read(account(of: bookmark))) {
            case .secret(let secret):
                out.entries.append(StreamExportEntry(name: bookmark.name, type: bookmark.type.rawValue, url: secret.url,
                                                     passphrase: secret.passphrase, audioOffsetMs: bookmark.audioOffsetMs,
                                                     colorOverride: bookmark.colorOverride))
            case .failed:
                out.leftOut.append(LeftOut(name: bookmark.name, reason: "Couldn’t read this stream’s URL."))
            case .missing, .unusable:
                out.leftOut.append(LeftOut(name: bookmark.name, reason: "This stream has no saved URL."))
            }
        }
        return cancelled() ? nil : out
    }
}

// MARK: - Import

/// The limits that live in the app.
public struct StreamImportRules {
    /// Why this URL can't be saved, or nil. `StreamBookmarkStore.validate`.
    public var urlProblem: (String) -> String?
    public var passphraseLength: ClosedRange<Int>
    public var audioOffsetMs: ClosedRange<Int>

    public init(urlProblem: @escaping (String) -> String?, passphraseLength: ClosedRange<Int>,
                audioOffsetMs: ClosedRange<Int>) {
        self.urlProblem = urlProblem
        self.passphraseLength = passphraseLength
        self.audioOffsetMs = audioOffsetMs
    }
}

public struct StreamImportPlan: Equatable, Sendable {
    /// What `add` is given.
    public struct Addition: Equatable, Sendable {
        public let name: String
        public let url: String
        public let passphrase: String?
        public let audioOffsetMs: Int?
        public let colorOverride: String?
    }

    public enum RenameReason: Equatable, Sendable {
        case differentURL
        /// R2. The file's passphrase is never dropped.
        case passphraseDiffers
        /// R3. Counts as different.
        case couldNotCompare

        public var message: String? {
            switch self {
            case .differentURL:      return nil
            case .passphraseDiffers: return "Passphrase differs."
            case .couldNotCompare:   return "Couldn’t compare with the existing stream."
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case added(Addition)
        case renamed(Addition, RenameReason)
        case alreadyHere
        case notImported(String)
    }

    public struct Row: Equatable, Identifiable, Sendable {
        /// The entry's position in the file.
        public let id: Int
        /// The name in the file, or "Stream N" when it has none that can be shown.
        public let name: String
        public let outcome: Outcome
    }

    public let rows: [Row]

    public var additions: [Addition] {
        rows.compactMap { row in
            switch row.outcome {
            case .added(let a), .renamed(let a, _): return a
            case .alreadyHere, .notImported: return nil
            }
        }
    }

    /// Plan an import. `read` is asked only about streams whose name is in an entry's family (R1), so a fresh Mac raises
    /// no Keychain read, and at most once for each stream. Writes nothing.
    public static func make(entries: [Any], existing: [StreamBookmark], rules: StreamImportRules,
                            read: (StreamBookmark) -> StreamSecrets.Resolution) -> StreamImportPlan {
        var list = existing.map { Member.saved($0) }
        var cache: [UUID: StreamSecret?] = [:]
        func secret(of member: Member) -> StreamSecret? {
            switch member {
            case .planned(_, let secret): return secret
            case .saved(let bookmark):
                if let known = cache[bookmark.id] { return known }
                var found: StreamSecret?
                if case .secret(let s) = read(bookmark) { found = s }
                cache.updateValue(found, forKey: bookmark.id)
                return found
            }
        }

        var rows: [Row] = []
        for (i, raw) in entries.enumerated() {
            let fallback = "Stream \(i + 1)"
            switch judge(raw, rules: rules) {
            case .failure(let refusal):
                rows.append(Row(id: i, name: refusal.name ?? fallback, outcome: .notImported(refusal.reason)))
            case .success(let entry):
                let family = list.filter { isFamily($0.name, of: entry.name) }
                var unreadable = false, passphraseDiffers = false, here = false
                for member in family {
                    guard let held = secret(of: member) else { unreadable = true; continue }
                    guard held.url == entry.secret.url else { continue }
                    if held.passphrase == entry.secret.passphrase { here = true; break }
                    passphraseDiffers = true
                }
                if here {
                    rows.append(Row(id: i, name: entry.name, outcome: .alreadyHere))
                    continue
                }
                let name = firstFreeName(entry.name, taken: Set(list.map(\.name)))
                let addition = Addition(name: name, url: entry.secret.url, passphrase: entry.secret.passphrase,
                                        audioOffsetMs: entry.audioOffsetMs, colorOverride: entry.colorOverride)
                list.append(.planned(name, entry.secret))
                if name == entry.name {
                    rows.append(Row(id: i, name: entry.name, outcome: .added(addition)))
                } else {
                    let reason: RenameReason = passphraseDiffers ? .passphraseDiffers
                        : unreadable ? .couldNotCompare : .differentURL
                    rows.append(Row(id: i, name: entry.name, outcome: .renamed(addition, reason)))
                }
            }
        }
        return StreamImportPlan(rows: rows)
    }

    private enum Member {
        case saved(StreamBookmark)
        case planned(String, StreamSecret)

        var name: String {
            switch self {
            case .saved(let bookmark): return bookmark.name
            case .planned(let name, _): return name
            }
        }
    }

    private struct Entry {
        let name: String
        let secret: StreamSecret
        let audioOffsetMs: Int?
        let colorOverride: String?
    }

    private struct Refusal: Error {
        let name: String?
        let reason: String
    }

    /// One entry alone. Anything unknown in it is ignored and never stored. The URL and passphrase come out as `add`
    /// would store them, so they compare with a stored secret.
    private static func judge(_ raw: Any, rules: StreamImportRules) -> Result<Entry, Refusal> {
        let damaged = "This entry is damaged."
        guard let fields = raw as? [String: Any] else { return .failure(Refusal(name: nil, reason: damaged)) }
        func present(_ key: String) -> Any? {
            guard let value = fields[key], !(value is NSNull) else { return nil }
            return value
        }
        let rawName = present("name")
        guard rawName == nil || rawName is String else { return .failure(Refusal(name: nil, reason: damaged)) }
        let trimmed = (rawName as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return .failure(Refusal(name: nil, reason: "This entry’s name has characters Manifold can’t use."))
        }
        let shown = trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        guard trimmed.count <= 200 else { return .failure(Refusal(name: shown, reason: "This entry’s name is too long.")) }

        guard let rawURL = fields["url"] as? String else { return .failure(Refusal(name: shown, reason: damaged)) }
        if let problem = rules.urlProblem(rawURL) { return .failure(Refusal(name: shown, reason: problem)) }
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(Refusal(name: shown, reason: damaged))
        }

        var typed: String?
        if let value = present("passphrase") {
            guard let text = value as? String else { return .failure(Refusal(name: shown, reason: damaged)) }
            typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let split = StreamSecrets.strippingPassphrase(from: url)
        let passphrase = (typed?.isEmpty == false ? typed : nil) ?? split?.passphrase
        if let passphrase {
            guard url.scheme?.lowercased() == "srt" else {
                return .failure(Refusal(name: shown, reason: "Only an SRT stream can have a passphrase."))
            }
            guard rules.passphraseLength.contains(passphrase.count) else {
                return .failure(Refusal(name: shown, reason: "This stream’s passphrase isn’t the right length."))
            }
        }

        var offset: Int?
        if let value = present("audioOffsetMs") {
            guard let ms = SettingsFile.wholeNumber(value) else { return .failure(Refusal(name: shown, reason: damaged)) }
            guard rules.audioOffsetMs.contains(ms) else {
                return .failure(Refusal(name: shown, reason: "This stream’s audio offset is out of range."))
            }
            offset = ms == 0 ? nil : ms
        }

        var color: String?
        if let value = present("colorOverride") {
            guard let text = value as? String, text.count <= 64 else {
                return .failure(Refusal(name: shown, reason: damaged))
            }
            color = text
        }

        let name = shown ?? url.host ?? "Stream"
        return .success(Entry(name: name, secret: StreamSecret(url: (split?.url ?? url).absoluteString, passphrase: passphrase),
                              audioOffsetMs: offset, colorOverride: color))
    }

    /// R1: "A", "A (copy)" and "A (copy N)".
    static func isFamily(_ candidate: String, of name: String) -> Bool {
        if candidate == name || candidate == "\(name) (copy)" { return true }
        let prefix = "\(name) (copy "
        guard candidate.hasPrefix(prefix), candidate.hasSuffix(")") else { return false }
        let number = candidate.dropFirst(prefix.count).dropLast()
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func firstFreeName(_ name: String, taken: Set<String>) -> String {
        if !taken.contains(name) { return name }
        if !taken.contains("\(name) (copy)") { return "\(name) (copy)" }
        var n = 2
        while taken.contains("\(name) (copy \(n))") { n += 1 }
        return "\(name) (copy \(n))"
    }
}

/// Applying a plan, and taking it back.
public enum StreamImport {
    public struct Failed: Equatable, Sendable {
        public let name: String
        public let reason: String
    }

    public struct Applied: Equatable, Sendable {
        /// The ids this import added. Undo removes these and nothing else.
        public var added: [UUID] = []
        public var failed: [Failed] = []
        /// Added streams with a non-zero saved offset (§6).
        public var withOffset = 0

        public init() {}
    }

    /// `add` per entry. A failure costs that entry.
    public static func apply(_ plan: StreamImportPlan,
                             add: (StreamImportPlan.Addition) -> Result<UUID, Failure>) -> Applied {
        var out = Applied()
        for addition in plan.additions {
            switch add(addition) {
            case .success(let id):
                out.added.append(id)
                if addition.audioOffsetMs != nil { out.withOffset += 1 }
            case .failure(let failure):
                out.failed.append(Failed(name: addition.name, reason: failure.reason))
            }
        }
        return out
    }

    public struct Failure: Error, Equatable {
        public let reason: String
        public init(reason: String) { self.reason = reason }
    }

    public static func undo(_ applied: Applied, delete: (UUID) -> Void) {
        applied.added.forEach(delete)
    }
}
