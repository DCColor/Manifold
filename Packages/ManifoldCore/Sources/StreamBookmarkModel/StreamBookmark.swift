//
//  StreamBookmark.swift
//  StreamBookmarkModel
//
//  The persisted shape of a saved stream: `StreamType` and `StreamBookmark`, moved here verbatim from
//  App/Preferences.swift (which keeps the store) so `swift test` can decode a stored `streamBookmarks`
//  blob with the real type. A leaf target for the same reason as DisplayProviders: a test bundle
//  cannot link ManifoldCore (libav), and this needs only Foundation. The app links it through the
//  StreamBookmarkModel product; nothing in this package does.
//

import Foundation

/// The transport a bookmarked URL uses, detected from the URL on save and stored per entry so a
/// later implementation needs no migration. All three connect today — `.web` from the start,
/// `.srt` from stage 3e, `.hls` once the AVPlayer pull route landed — and each arrived by
/// changing `isSupported` and nothing else. See that property for what a single gate bought.
public enum StreamType: String, Codable, Sendable {
    case web    // http(s) — the default; there is no reliable WHEP signature, it is just an https URL
    case srt    // srt://
    case hls    // a path containing .m3u8

    /// Detect from a URL. srt:// wins first, then an .m3u8 path, then the http(s) default. A URL
    /// matching none of the accepted schemes is rejected before this is reached (see `validate`).
    public static func detect(_ url: URL) -> StreamType {
        if url.scheme?.lowercased() == "srt" { return .srt }
        if url.path.lowercased().contains(".m3u8") { return .hls }
        return .web
    }

    /// Row label — reads naturally, never a protocol acronym, EXCEPT SRT, which broadcast people
    /// know by name and expect to see. Deliberately never "WHEP".
    public var label: String {
        switch self {
        case .web: return "Web Stream"
        case .srt: return "SRT"
        case .hls: return "HLS"
        }
    }

    /// ALL THREE CONNECT. SRT joined in stage 3e and HLS joins here — `type` has been stored per
    /// entry since the beginning precisely so this line could change without a migration, and an
    /// `.m3u8` bookmark saved months ago becomes connectable the moment this admits it. That
    /// promise is now spent twice and it held both times.
    ///
    /// ⚠️ VERIFIED, NOT ASSUMED, and the check is worth restating because the value of a single
    /// gate is exactly that it has no second copy. Admitting `.hls` here lights up every refusal
    /// site at once, all four of which read THIS property and none of which name a transport:
    ///
    ///   1. `ContentView.streamBookmarkRows`  — the disabled menu row becomes a live Button
    ///   2. `StreamBookmarksSheet.row`        — the Connect button and the tap gesture appear,
    ///                                          the orange reason line reverts to the host, and
    ///                                          the row's 0.55 opacity lifts
    ///   3. `StreamBookmarksSheet.savedNotice`— "Saved. HLS — not yet supported." stops being said
    ///   4. `StreamBookmarksSheet.pasteAndConnect` — "Connect without saving" stops refusing
    ///
    /// …plus `firstConnectable`, which gates the empty-state pill's default entry.
    /// `firstConnectable(ofType:)` is unaffected: ⌃⌥H and ⌃⌥D name their transports explicitly.
    public var isSupported: Bool { true }

    /// Honest greyed-row reason for an unsupported entry; nil when supported.
    ///
    /// ⚠️ KEPT, AND DELIBERATELY NOT DELETED NOW THAT NOTHING RETURNS A REASON. This is the seam a
    /// FOURTH transport is detected on before it is implemented — the state `.srt` and `.hls` both
    /// passed through, where a bookmark is saved, listed and honestly refused rather than rejected
    /// at the door and lost. Deleting it would mean the next transport's detection-only stage has
    /// to rebuild all four call sites above instead of returning a string.
    public var unsupportedReason: String? {
        switch self {
        case .web, .srt, .hls: return nil
        }
    }
}

/// One saved stream endpoint. `id` is stable across launches so SwiftUI list identity and per-row
/// delete are unambiguous. `urlString` is stored verbatim and only ever handed to WHEPClient.connect
/// — the host is derived for display, the full string is never shown or logged.
///
/// ⚠️ ADDING A FIELD HERE IS THE ONE MIGRATION HAZARD IN THIS FILE, AND IT IS OURS, NOT THE DISK'S.
/// A new REQUIRED field — no default value, not Optional — makes every already-persisted entry
/// undecodable (`DecodingError.keyNotFound`), for EVERY USER AT ONCE, on the first launch after
/// that ship. Nothing about the failure is local to one bad install. So: new fields are Optional
/// or defaulted, or they arrive with an explicit migration that reads the old shape first.
/// `StreamBookmarkStore.storedDataUnreadable` is the backstop that stops the damage compounding
/// when this rule is broken; it is not permission to break it, because it cannot recover the data
/// — it can only decline to overwrite it.
public struct StreamBookmark: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var urlString: String
    public var type: StreamType
    /// The per-source audio offset O for this stream, in ms (docs/AUDIO_RESAMPLER_DESIGN.md §19.4,
    /// §19.8): + = the sound heard later. **Optional, per the rule above: nil = 0**, and nil is what
    /// every bookmark saved before this field existed decodes to. Never written unless the user
    /// sets a non-zero value — synthesized Codable uses `encodeIfPresent` for an Optional, so nil
    /// stays ABSENT from the stored JSON and an untouched bookmark round-trips byte-for-byte.
    /// The range (−250…+500) is the steering's constant, checked where the value is entered.
    public var audioOffsetMs: Int?
    /// The saved colorimetry override for this stream (docs/COLOR_MANAGEMENT_FINDINGS.md §6.9,
    /// Stage D): `ColorimetryOverride.storageID`, a RAW STRING, not the enum — this target does not
    /// know the presets, and a preset added by a later build must not make this entry undecodable.
    /// **nil = Auto, and Auto is stored as ABSENT**, the `audioOffsetMs` rule: an untouched bookmark
    /// round-trips unchanged, byte for byte (`storeEncoding`). The app reads it through
    /// `ColorimetryOverride(storageID:on:)`, which turns absent, empty, unknown or
    /// not-offered-on-this-transport into Auto.
    ///
    /// Kept VERBATIM, unknown strings included: a downgraded build that loads a newer build's preset
    /// shows Auto and writes the string back unchanged, so going back a version and returning loses
    /// nothing. Only a Save from the live menu replaces it.
    public var colorOverride: String?
    /// Privacy P2 (docs/PRIVACY_AUDIT.md): the stream's NON-SECRET address, `scheme://host[:port]`
    /// (`StreamSecrets.address(of:)`), stored once the full URL has moved to the Keychain. Display
    /// only: the host for the list, never something to dial. nil on an entry not yet migrated, whose
    /// `urlString` still holds the URL. Optional, absent until set, never fails the entry.
    public var address: String?
    /// Privacy P2: the Keychain account that holds this stream's secret (`StreamSecret`: the full URL
    /// and the SRT passphrase), in the one stream service. Always `id.uuidString` when written here.
    /// PRESENT means the plist holds no part of the URL beyond `address` and `urlString` is empty;
    /// absent means a pre-P2 entry. Optional, absent until set, never fails the entry.
    public var secretRef: String?

    public init(id: UUID = UUID(), name: String, urlString: String, type: StreamType,
                audioOffsetMs: Int? = nil, colorOverride: String? = nil,
                address: String? = nil, secretRef: String? = nil) {
        self.id = id; self.name = name; self.urlString = urlString; self.type = type
        self.audioOffsetMs = audioOffsetMs
        self.colorOverride = colorOverride
        self.address = address
        self.secretRef = secretRef
    }

    /// Synthesized, except that `colorOverride` NEVER FAILS THE ENTRY: a value that is not a string
    /// (a hand edit, a future shape) reads as nil = Auto, and one bad field cannot cost the user the
    /// list (`StreamBookmarkStore.storedDataUnreadable`). Every other field decodes exactly as the
    /// synthesized init did; encoding stays synthesized (`encodeIfPresent` for the optionals).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        urlString = try c.decode(String.self, forKey: .urlString)
        type = try c.decode(StreamType.self, forKey: .type)
        audioOffsetMs = try c.decodeIfPresent(Int.self, forKey: .audioOffsetMs)
        colorOverride = (try? c.decodeIfPresent(String.self, forKey: .colorOverride)) ?? nil
        address = (try? c.decodeIfPresent(String.self, forKey: .address)) ?? nil
        secretRef = (try? c.decodeIfPresent(String.self, forKey: .secretRef)) ?? nil
    }

    /// The URL TO DISPLAY: `address` once the secret is in the Keychain (privacy P2), else the
    /// pre-P2 `urlString` (no passphrase, by construction). It is NOT the one to dial, and after P2
    /// it has no path to detect a type from. `StreamBookmarkStore.connectURL(for:)` is the dial URL,
    /// and it is the only thing that reassembles the secret.
    public var url: URL? { URL(string: address ?? urlString) }

    /// True once this entry's URL lives in the Keychain and the plist holds only `address`.
    public var secretInKeychain: Bool { secretRef != nil }

    /// Host for secondary display. NEVER the path — it can carry the stream key.
    public var displayHost: String { url?.host ?? "—" }
}

extension StreamBookmark {
    /// The stored form of the list: what `StreamBookmarkStore.persist()` writes to `streamBookmarks`.
    ///
    /// SORTED KEYS, so the same list always writes the same bytes. A plain `JSONEncoder` writes an
    /// object's keys in an order that changes from one process to the next, and between entries within
    /// one encode (measured, COLOR_MANAGEMENT_FINDINGS.md §6.9 Stage D): every save re-ordered every
    /// entry, untouched ones included, so "an untouched bookmark round-trips byte-for-byte" held only
    /// after sorting. With this, a load and a save of an unchanged list give back the stored bytes.
    ///
    /// Nothing else changes: the same escaping as before (slashes escaped, non-ASCII as UTF-8), and no
    /// reader depends on key order, so older builds decode it as before. A list written by an earlier
    /// build is re-ordered once, at its first save here; its content is unchanged.
    public static func storeEncoding(_ list: [StreamBookmark]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(list)
    }
}
