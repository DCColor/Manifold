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

    public init(id: UUID = UUID(), name: String, urlString: String, type: StreamType,
                audioOffsetMs: Int? = nil) {
        self.id = id; self.name = name; self.urlString = urlString; self.type = type
        self.audioOffsetMs = audioOffsetMs
    }

    /// The URL AS PERSISTED — no passphrase, by construction (see `StreamBookmarkStore.add`). This
    /// is the right URL to display, to inspect, and to detect a type from; it is NOT the one to
    /// dial. `StreamBookmarkStore.connectURL(for:)` is, and it is the only thing that reassembles
    /// the secret.
    public var url: URL? { URL(string: urlString) }

    /// Host for secondary display. NEVER the path — it can carry the stream key.
    public var displayHost: String { url?.host ?? "—" }
}
