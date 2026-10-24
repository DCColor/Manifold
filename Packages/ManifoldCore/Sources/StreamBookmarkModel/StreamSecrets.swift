//
//  StreamSecrets.swift
//  StreamBookmarkModel — privacy P2 (docs/PRIVACY_AUDIT.md): a saved stream's secret leaves the
//  preferences plist for the Keychain.
//
//  The SECRET is the whole URL plus the SRT passphrase, not a chosen part of it. A WHEP or HLS path
//  can be the stream key, an SRT `streamid` can be one, a query can carry a token and the user part
//  of a URL a password, and no rule can tell which path segment is the key. So the plist keeps the
//  stream's non-secret `address` (`scheme://host[:port]`, what the list shows) and a Keychain
//  reference; the Keychain item keeps the rest.
//
//  The rules, in the order they bind (P1's, `LicenseRecordSync`):
//   1. A plist entry is changed ONLY after its secret has been written AND READ BACK equal.
//   2. Any failure leaves that entry exactly as it was, and the log says why — never the secret,
//      the URL, the host or the name: an entry is named by its position in the list.
//   3. Idempotent and resumable: an entry already migrated is not read or written again, and an
//      item that already holds what the entry would write is linked without a write.
//
//  Here rather than in the app so `swift test` runs every case against an in-memory store. The app's
//  `KeychainStore` is the real `StreamSecretStore` (App/KeychainStore.swift).
//

import Foundation

/// What one bookmark's Keychain item holds. Its own JSON shape with a marker, because the item
/// that held only the SRT passphrase before P2 is the same item (same service, same account): a
/// value that does not decode as this IS a pre-P2 passphrase.
public struct StreamSecret: Equatable, Sendable {
    /// The full URL, as the user saved it, WITHOUT the passphrase (that is the field below).
    public var url: String
    /// The SRT passphrase, nil when there is none. Empty is stored as nil.
    public var passphrase: String?

    public init(url: String, passphrase: String?) {
        self.url = url
        self.passphrase = (passphrase?.isEmpty == false) ? passphrase : nil
    }

    private struct Wire: Codable {
        var kind: String
        var v: Int
        var url: String
        var passphrase: String?
    }

    private static let kind = "manifold.stream-secret"
    private static let version = 1

    /// The item's value. Sorted keys, so the same secret always writes the same bytes.
    public func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Wire(kind: Self.kind, v: Self.version, url: url,
                                                  passphrase: passphrase)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil when `value` is not this shape — a pre-P2 passphrase, or something else.
    public static func decode(_ value: String) -> StreamSecret? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: Data(value.utf8)),
              wire.kind == kind, wire.v == version else { return nil }
        return StreamSecret(url: wire.url, passphrase: wire.passphrase)
    }
}

/// A Keychain read, with "not there" kept apart from "could not look" (the app's `KeychainRead`).
public enum StreamSecretRead: Equatable, Sendable {
    case found(String)
    case absent
    /// Refused, locked, cancelled or undecodable. Something may be stored: change nothing.
    case failed(Int32)
}

/// One Keychain service, one item per bookmark. `write` is an upsert returning an OSStatus
/// (0 = errSecSuccess).
public protocol StreamSecretStore {
    func read(_ account: String) -> StreamSecretRead
    func write(_ value: String, for account: String) -> Int32
    func delete(_ account: String)
}

public enum StreamSecrets {

    // MARK: - The passphrase: split from a URL, joined back for the dial

    /// The query key, spelled once. SRT URLs use `passphrase`, matching libsrt's own option name and
    /// what OBS/ffmpeg write, and the comparison below is case-insensitive because a hand-typed URL
    /// is not reliably lowercase.
    public static let passphraseQueryKey = "passphrase"

    /// Split a URL into (URL without any passphrase, the passphrase). Returns nil only when the URL
    /// cannot be decomposed at all — a caller treats that as "nothing to strip" and keeps the
    /// original, which is correct: an un-parseable URL has no query items to leak through.
    ///
    /// An EMPTY value (`?passphrase=`) yields a nil secret but still strips the key, so a pointless
    /// empty parameter never reaches the wire or the Keychain.
    ///
    /// ⚠️ RETURNS THE URL UNTOUCHED WHEN THERE IS NO PASSPHRASE KEY, and that early-out is
    /// load-bearing rather than an optimisation. Rebuilding `queryItems` RE-ENCODES every remaining
    /// parameter: `?streamid=live%2Fabc` comes back as `?streamid=live/abc`. Both decode to the
    /// same value through any query parser — ours included, since `SRTClient.parse` reads
    /// `queryItems` the same way — so it is safe where we must rebuild. But it is not something to
    /// do to a URL we have no business rewriting. Every web bookmark falls in that category, and
    /// their query strings can carry a token the server may compare literally; saving one must not
    /// silently normalise it. So the rebuild happens only when a secret is actually being removed.
    ///
    /// (Moved verbatim from `StreamBookmarkStore` in App/Preferences.swift for P2.)
    public static func strippingPassphrase(from url: URL) -> (url: URL, passphrase: String?)? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        guard let items = components.queryItems, !items.isEmpty else { return (url, nil) }
        guard items.contains(where: { $0.name.lowercased() == passphraseQueryKey }) else {
            return (url, nil)   // nothing to remove — hand back the original bytes, not a rebuild
        }
        let found = items.first { $0.name.lowercased() == passphraseQueryKey }?.value
        let kept = items.filter { $0.name.lowercased() != passphraseQueryKey }
        // nil, not [], or `absoluteString` keeps a trailing "?" on a URL whose only parameter was
        // the one we removed — which then round-trips into the stored string and looks like damage.
        components.queryItems = kept.isEmpty ? nil : kept
        guard let stripped = components.url else { return nil }
        return (stripped, (found?.isEmpty == false) ? found : nil)
    }

    /// The URL with `passphrase` put back as the last query item — the join `connectURL` made
    /// before P2, unchanged, so a stream dials the bytes it dialled before. No passphrase: the URL
    /// unchanged. Any passphrase item already in the URL is dropped rather than doubled.
    public static func joining(_ url: URL, passphrase: String?) -> URL {
        guard let secret = passphrase, !secret.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name.lowercased() == passphraseQueryKey }
        items.append(URLQueryItem(name: passphraseQueryKey, value: secret))
        components.queryItems = items
        return components.url ?? url
    }

    /// The URL to dial for a secret. ⚠️ SECRET-BEARING: to `LiveSource.connect*` and nowhere else.
    public static func dialURL(_ secret: StreamSecret) -> URL? {
        URL(string: secret.url).map { joining($0, passphrase: secret.passphrase) }
    }

    // MARK: - The plist's half

    /// What the plist keeps: `scheme://host[:port]`. No user or password, path, query or fragment.
    /// nil when the URL has no scheme or host (nothing `validate` would have saved).
    public static func address(of url: URL) -> String? {
        guard url.scheme?.isEmpty == false, url.host?.isEmpty == false,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.user = nil
        c.password = nil
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.string
    }

    /// The entry as the plist stores it once its secret is in the Keychain under `account`.
    /// nil when the secret's URL has no address to keep.
    public static func migrated(_ bookmark: StreamBookmark, secret: StreamSecret,
                                account: String) -> StreamBookmark? {
        guard let url = URL(string: secret.url), let address = address(of: url) else { return nil }
        var moved = bookmark
        moved.urlString = ""
        moved.address = address
        moved.secretRef = account
        return moved
    }

    // MARK: - Resolve: the plist entry and its item, to one secret

    public enum Resolution: Equatable {
        case secret(StreamSecret)
        /// The Keychain refused the read. Something may be stored: dial nothing, change nothing.
        case failed(Int32)
        /// The plist says the item holds the URL, and there is no item.
        case missing
        /// Nothing to dial: an empty or unparseable pre-P2 URL, or an item that is not a
        /// `StreamSecret` where the plist says one is.
        case unusable
    }

    /// The secret a bookmark stands for, from its plist entry and its item's read.
    ///
    /// A MIGRATED entry (`secretRef` set) is the item, which must be a `StreamSecret`.
    ///
    /// A PRE-P2 entry gives the target the pre-P2 build dialled, byte for byte. That build moved an
    /// inline `?passphrase=` to the Keychain at launch (so the inline value wins and the URL is the
    /// stripped one) and joined the item's passphrase onto the stored URL at connect. Two more
    /// shapes are read here because P2 itself can leave them:
    ///   - the item is already a `StreamSecret` and the entry still holds its URL: a migration
    ///     interrupted between the Keychain write and the plist write, or an older build that edited
    ///     the URL. The plist's URL wins, the item's passphrase is kept.
    ///   - the entry's `urlString` is empty: an older build re-saved a migrated list and dropped
    ///     `address` and `secretRef` (it writes only the keys it knows). The item is the copy.
    public static func resolve(_ bookmark: StreamBookmark, read: StreamSecretRead) -> Resolution {
        if bookmark.secretInKeychain {
            switch read {
            case .failed(let status): return .failed(status)
            case .absent:             return .missing
            case .found(let value):   return StreamSecret.decode(value).map(Resolution.secret) ?? .unusable
            }
        }
        var stored: StreamSecret?
        var legacyPassphrase: String?
        switch read {
        case .failed(let status): return .failed(status)
        case .absent: break
        case .found(let value):
            if let s = StreamSecret.decode(value) { stored = s }
            else if !value.isEmpty { legacyPassphrase = value }
        }
        if bookmark.urlString.isEmpty {
            return stored.map(Resolution.secret) ?? .unusable
        }
        guard let url = URL(string: bookmark.urlString) else { return .unusable }
        if let split = strippingPassphrase(from: url), let inline = split.passphrase {
            return .secret(StreamSecret(url: split.url.absoluteString, passphrase: inline))
        }
        return .secret(StreamSecret(url: bookmark.urlString,
                                    passphrase: legacyPassphrase ?? stored?.passphrase))
    }

    // MARK: - Store: write, read back, compare

    public enum StoreResult: Equatable {
        case stored
        case unencodable
        case writeFailed(Int32)
        case readBackFailed(Int32)
        case readBackMissing
        case readBackDiffers

        /// For a log line. No values.
        public var reason: String {
            switch self {
            case .stored:                 return "stored"
            case .unencodable:            return "the secret could not be encoded"
            case .writeFailed(let s):     return "the Keychain write failed (OSStatus \(s))"
            case .readBackFailed(let s):  return "the read-back failed (OSStatus \(s))"
            case .readBackMissing:        return "the read-back found no item"
            case .readBackDiffers:        return "the read-back did not match what was written"
            }
        }
    }

    /// Write `secret` under `account` and read it back. `.stored` only when the read-back decodes
    /// equal. When the write went through and the read-back did not confirm it, the item is put
    /// back as `previous` was (rewritten, or deleted if there was none), best effort, so a pre-P2
    /// passphrase is never left overwritten by a value nobody could confirm.
    public static func store(_ secret: StreamSecret, account: String, in store: StreamSecretStore,
                             previous: StreamSecretRead) -> StoreResult {
        guard let value = secret.encoded() else { return .unencodable }
        let status = store.write(value, for: account)
        guard status == 0 else { return .writeFailed(status) }
        let result: StoreResult
        switch store.read(account) {
        case .found(let back): result = StreamSecret.decode(back) == secret ? .stored : .readBackDiffers
        case .absent:          result = .readBackMissing
        case .failed(let s):   result = .readBackFailed(s)
        }
        if result != .stored {
            switch previous {
            case .found(let old): _ = store.write(old, for: account)
            case .absent:         store.delete(account)
            case .failed:         break   // never written over: callers do not write after a failed read
            }
        }
        return result
    }

    // MARK: - Migrate

    public struct MigrationOutcome: Equatable {
        /// The list to persist. Entries not migrated are the input's, unchanged.
        public var bookmarks: [StreamBookmark]
        /// Secret written, read back equal, entry stripped.
        public var moved = 0
        /// The item already held the secret (an interrupted run, or an older build's re-save); entry
        /// stripped with no write.
        public var relinked = 0
        /// Migrated before this run. Not read, not written.
        public var already = 0
        /// Left in the plist exactly as it was; `log` says why.
        public var kept = 0
        /// Keychain writes attempted, restores not counted.
        public var keychainWrites = 0
        /// One line per entry kept, plus a summary. No secret, URL, host or name.
        public var log: [String] = []

        /// Whether the plist needs writing.
        public var changed: Bool { moved + relinked > 0 }
    }

    /// One pass over the list. Each entry is independent: a failure keeps that entry as it was and
    /// the pass goes on. The caller persists `bookmarks` once, only if `changed`.
    public static func migrate(_ bookmarks: [StreamBookmark], store: StreamSecretStore) -> MigrationOutcome {
        var out = MigrationOutcome(bookmarks: bookmarks)
        let n = bookmarks.count
        for (i, bookmark) in bookmarks.enumerated() {
            let entry = "entry \(i + 1) of \(n)"
            if bookmark.secretInKeychain { out.already += 1; continue }
            let account = bookmark.id.uuidString
            let read = store.read(account)
            switch resolve(bookmark, read: read) {
            case .failed(let status):
                out.kept += 1
                out.log.append("\(entry): the Keychain refused the read (OSStatus \(status)) — left in the preferences plist")
            case .missing, .unusable:
                out.kept += 1
                out.log.append("\(entry): no stream URL to move — left as it is")
            case .secret(let secret):
                guard let target = migrated(bookmark, secret: secret, account: account) else {
                    out.kept += 1
                    out.log.append("\(entry): the URL has no host to keep — left in the preferences plist")
                    continue
                }
                if case .found(let value) = read, StreamSecret.decode(value) == secret {
                    out.relinked += 1
                    out.bookmarks[i] = target
                    continue
                }
                let result = Self.store(secret, account: account, in: store, previous: read)
                if result != .unencodable { out.keychainWrites += 1 }
                if result == .stored {
                    out.moved += 1
                    out.bookmarks[i] = target
                } else {
                    out.kept += 1
                    out.log.append("\(entry): \(result.reason) — left in the preferences plist")
                }
            }
        }
        if out.moved + out.relinked + out.kept > 0 {
            out.log.append("stream secrets: \(out.moved) moved to the Keychain, \(out.relinked) linked to an "
                           + "item that already held them, \(out.already) already there, \(out.kept) left in "
                           + "the preferences plist")
        }
        return out
    }
}
