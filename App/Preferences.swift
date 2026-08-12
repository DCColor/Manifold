import SwiftUI
import AppKit

/// How the transport controls are presented.
enum ControlDisplayMode: String, CaseIterable, Identifiable {
    case overlay   // floating auto-hide HUD over the video (default)
    case docked    // fixed control bar below the video

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overlay: return "Overlay (floating)"
        case .docked:  return "Docked (fixed bar)"
        }
    }
}

/// The app's preferences, persisted automatically via @AppStorage (UserDefaults).
/// @AppStorage can't hold a custom enum directly, so we persist its raw String
/// and expose the enum on top of that raw value.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    // NOTE: `controlDisplayMode` is no longer declared here. It is PER-WINDOW state now — owned by
    // WindowChrome, which seeds from and writes back to the same key. This class used to expose a
    // `controlMode` accessor over it that nothing ever read; leaving it would have offered a
    // process-wide writer that could silently disagree with the windows. SettingsView still binds
    // the key directly for its picker (see the comment there).

    @AppStorage("autoplayOnLoad") var autoplayOnLoad: Bool = true

    // Output volume (0–1), persisted across launches. Stored as Double (@AppStorage
    // has no Float). Mute is intentionally NOT persisted — always start unmuted.
    @AppStorage("playbackVolume") var playbackVolume: Double = 1.0

    // Scope ARRANGEMENT is no longer declared here either. Tray open/close ("showTray") and the
    // per-slot selections ("manifold.scope.slot0/1/2") are PER-WINDOW state owned by WindowChrome,
    // which seeds from and writes back to the same keys. The `showTray` property this class used to
    // expose had no readers; it is gone for the same reason `controlMode` is (see above).
    // Scope STYLING below (intensities, colours, scales) stays app-wide and stays here.
    //
    // NOTE: showReferenceLayer (⌃⌥R) is intentionally NOT persisted — it's a diagnostic
    // toggle that must always default OFF on launch, so it stays transient @State.

    // Scope trace intensity — multiplies the brightness-curve gain. 1.0 = current look.
    // Per-scope values combine MULTIPLICATIVELY with the global master.
    @AppStorage("waveformIntensity") var waveformIntensity: Double = 1.0
    @AppStorage("paradeIntensity") var paradeIntensity: Double = 1.0
    @AppStorage("vectorscopeIntensity") var vectorscopeIntensity: Double = 1.0
    @AppStorage("globalScopeIntensity") var globalScopeIntensity: Double = 1.0

    // Global vertical scale for the value-axis scopes (waveform/parade). Stored as the
    // enum's String raw value. Default .bit10 (the 1023 ruler read in Resolve).
    @AppStorage("scopeScale") var scopeScale: ScopeScale = .bit10

    // Framing guide (non-destructive overlay). Canonical declarations; the overlay,
    // panel, and Settings bind these same keys. Defaults reproduce Pass 1's look.
    // Which guide is active: off / a preset aspect (guideAspect) / custom (customW/H).
    @AppStorage("guideMode") var guideMode: GuideMode = .off
    @AppStorage("guideAspect") var guideAspect: Double = 2.39
    @AppStorage("customW") var customW: Double = 9
    @AppStorage("customH") var customH: Double = 16
    // Safe lines (independent of the crop guide).
    @AppStorage("safeLinesOn") var safeLinesOn: Bool = false
    @AppStorage("safeTop") var safeTop: Double = 0.10
    @AppStorage("safeBottom") var safeBottom: Double = 0.90
    // Styling (moved out of Pass 1 code constants; tunable in Settings).
    @AppStorage("guideDarkenOpacity") var guideDarkenOpacity: Double = 0.85
    @AppStorage("guideDarkenColor") var guideDarkenColorHex: String = "000000"
    @AppStorage("guideLineColor") var guideLineColorHex: String = "FFFFFF"
    @AppStorage("guideLineWidth") var guideLineWidth: Double = 2
    @AppStorage("safeLineColor") var safeLineColorHex: String = "FFFF00"
    @AppStorage("safeLineWidth") var safeLineWidth: Double = 1
    @AppStorage("safeLineOpacity") var safeLineOpacity: Double = 0.75

    // Broadcast safe zones (SMPTE-style nested action/title boxes + centre cross).
    // ORTHOGONAL to guideMode — these coexist with any aspect/social crop guide, so
    // they're an independent flag, not a fourth GuideMode case. Percentages are stored
    // as FRACTIONS of the video rect (0.90 = 90%), matching safeTop/safeBottom.
    // Defaults are single-sourced below so the @AppStorage declarations at every
    // binding site can't drift apart.
    static let defaultBroadcastActionPct = 0.90
    static let defaultBroadcastTitlePct = 0.80
    static let defaultBroadcastSafeHex = "FFFFFF"
    static let defaultBroadcastSafeWidth = 1.0
    static let defaultBroadcastSafeOpacity = 0.75

    /// Legal range for both safe-zone percentages (fractions). Shared by the popover's
    /// entry clamp and the overlay's draw-time guard so they can't disagree.
    static let broadcastPctRange: ClosedRange<Double> = 0.5...1.0

    @AppStorage("broadcastSafeOn") var broadcastSafeOn: Bool = false
    @AppStorage("broadcastActionPct") var broadcastActionPct: Double = Preferences.defaultBroadcastActionPct
    @AppStorage("broadcastTitlePct") var broadcastTitlePct: Double = Preferences.defaultBroadcastTitlePct
    @AppStorage("broadcastSafeColor") var broadcastSafeColorHex: String = Preferences.defaultBroadcastSafeHex
    @AppStorage("broadcastSafeWidth") var broadcastSafeWidth: Double = Preferences.defaultBroadcastSafeWidth
    @AppStorage("broadcastSafeOpacity") var broadcastSafeOpacity: Double = Preferences.defaultBroadcastSafeOpacity

    /// Slider range shared by every scope-intensity control (per-scope + master).
    /// 0.25 = quite dim, 3.0 = quite hot, 1.0 = current default look.
    static let scopeIntensityRange: ClosedRange<Double> = 0.25...3.0

    // Two-way bindings so the per-scope header sliders drive these without
    // redeclaring @AppStorage in each scope view (Preferences stays the one owner).
    var waveformIntensityBinding: Binding<Double> {
        Binding(get: { self.waveformIntensity }, set: { self.waveformIntensity = $0 })
    }
    var paradeIntensityBinding: Binding<Double> {
        Binding(get: { self.paradeIntensity }, set: { self.paradeIntensity = $0 })
    }
    var vectorscopeIntensityBinding: Binding<Double> {
        Binding(get: { self.vectorscopeIntensity }, set: { self.vectorscopeIntensity = $0 })
    }

    // Per-scope trace COLOR (hue the trace is painted in; intensity stays orthogonal).
    // Stored as 6-digit sRGB hex. Defaults reproduce the current look: waveform green,
    // vectorscope white. (Parade is intentionally excluded — its R/G/B are locked.)
    // Default trace colors — single source so the @AppStorage default and the
    // header reset buttons can't drift apart.
    static let defaultWaveformTraceColorHex = "00FF00"     // green
    static let defaultVectorscopeTraceColorHex = "FFFFFF"  // white
    @AppStorage("waveformTraceColor") var waveformTraceColorHex: String = Preferences.defaultWaveformTraceColorHex
    @AppStorage("vectorscopeTraceColor") var vectorscopeTraceColorHex: String = Preferences.defaultVectorscopeTraceColorHex

    var waveformTraceColorBinding: Binding<Color> {
        Binding(get: { ScopeColorCodec.color(fromHex: self.waveformTraceColorHex) },
                set: { self.waveformTraceColorHex = ScopeColorCodec.hex(from: $0) })
    }
    var vectorscopeTraceColorBinding: Binding<Color> {
        Binding(get: { ScopeColorCodec.color(fromHex: self.vectorscopeTraceColorHex) },
                set: { self.vectorscopeTraceColorHex = ScopeColorCodec.hex(from: $0) })
    }

    // Parade is two-state: default RGB columns, or monochrome (all three columns in
    // one chosen color). Picking a color activates monochrome; the reset button (RGB)
    // turns it off. Parade has NO per-channel colors.
    @AppStorage("paradeMonochrome") var paradeMonochrome: Bool = false
    @AppStorage("paradeMonoColor") var paradeMonoColorHex: String = "FFFFFF"

    /// Swatch binding: setting a color also switches the parade into monochrome mode.
    var paradeMonoColorBinding: Binding<Color> {
        Binding(get: { ScopeColorCodec.color(fromHex: self.paradeMonoColorHex) },
                set: {
                    self.paradeMonoColorHex = ScopeColorCodec.hex(from: $0)
                    self.paradeMonochrome = true
                })
    }

    // Frame-export destination folder, stored as a SECURITY-SCOPED BOOKMARK so write
    // access to a user-picked folder survives relaunch (robust under hardened runtime /
    // if sandboxing is ever added). Empty = default to ~/Desktop.
    @AppStorage("exportFolderBookmark") var exportFolderBookmark: Data = Data()

    private static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Store the chosen folder as a security-scoped bookmark.
    func setExportFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            exportFolderBookmark = data
        }
    }

    /// Clear the chosen folder (revert to ~/Desktop).
    func clearExportFolder() { exportFolderBookmark = Data() }

    /// Resolve the export folder and run `body` with it, bracketing security-scoped
    /// access. Falls back to ~/Desktop if no folder is chosen or the bookmark is
    /// stale/unresolvable (never fails the export).
    func withExportDirectory(_ body: (URL) -> Void) {
        guard !exportFolderBookmark.isEmpty else { body(Self.desktopURL); return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: exportFolderBookmark,
                                 options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              !stale else {
            print("[EXPORT] export-folder bookmark stale/unresolvable — using Desktop")
            body(Self.desktopURL); return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        body(url)
    }

    /// Display string for Settings (resolves the bookmark for show only).
    static func displayPath(forBookmark data: Data) -> String {
        guard !data.isEmpty else { return "Desktop (default)" }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
            return url.path
        }
        return "Desktop (default)"
    }

    private init() {}
}

// MARK: - Stream bookmarks
//
// Named endpoints for the streaming button's URL sources. Lives here with the rest of the
// preferences plumbing rather than as a one-off; a Codable array does not fit @AppStorage, so it is
// a small store over one JSON key.
//
// ── TWO STORES, BECAUSE THERE ARE TWO DIFFERENT RISKS ──────────────────────────────────────
//
// THE URL STAYS IN USERDEFAULTS. The risk it carries is a raw endpoint — whose PATH can be a
// Cloudflare stream key — being read off a client's screen during a share. A user-supplied NAME is
// what solves that, so the list shows the name and the HOST only, never the path. Encryption at
// rest is the wrong tool for a screen-visible-URL problem, and it would not have helped: the app
// must dial the URL, so it must be able to read it.
//
// THE SRT PASSPHRASE DOES NOT. It is a credential in its own right rather than an address — the
// thing that decrypts the stream, typed once and reusable by anyone who reads it back out. Nothing
// about it needs to be legible to a person, so nothing is served by leaving it in a plist that any
// process running as the user can read with `defaults read`. It goes to the Keychain, keyed by the
// bookmark's UUID (`KeychainStore.streams`), and the persisted `urlString` is stripped of it before
// it is ever written — see `add` and `strippingPassphrase`.

/// The transport a bookmarked URL uses, detected from the URL on save and stored per entry so a
/// later SRT/HLS implementation needs no migration. Only `.web` connects today; the others are
/// saved, listed, and shown disabled with an honest reason.
enum StreamType: String, Codable {
    case web    // http(s) — the default; there is no reliable WHEP signature, it is just an https URL
    case srt    // srt://
    case hls    // a path containing .m3u8

    /// Detect from a URL. srt:// wins first, then an .m3u8 path, then the http(s) default. A URL
    /// matching none of the accepted schemes is rejected before this is reached (see `validate`).
    static func detect(_ url: URL) -> StreamType {
        if url.scheme?.lowercased() == "srt" { return .srt }
        if url.path.lowercased().contains(".m3u8") { return .hls }
        return .web
    }

    /// Row label — reads naturally, never a protocol acronym, EXCEPT SRT, which broadcast people
    /// know by name and expect to see. Deliberately never "WHEP".
    var label: String {
        switch self {
        case .web: return "Web Stream"
        case .srt: return "SRT"
        case .hls: return "HLS"
        }
    }

    /// Web and SRT connect; HLS does not. SRT joined in stage 3e — `type` has been stored per entry
    /// since the beginning precisely so this line could change without a migration, and an srt://
    /// bookmark saved months ago becomes connectable the moment this admits it.
    var isSupported: Bool { self == .web || self == .srt }

    /// Honest greyed-row reason for an unsupported entry; nil when supported.
    var unsupportedReason: String? {
        switch self {
        case .web, .srt: return nil
        case .hls:       return "HLS — not yet supported"
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
struct StreamBookmark: Codable, Identifiable {
    let id: UUID
    var name: String
    var urlString: String
    var type: StreamType

    init(id: UUID = UUID(), name: String, urlString: String, type: StreamType) {
        self.id = id; self.name = name; self.urlString = urlString; self.type = type
    }

    /// The URL AS PERSISTED — no passphrase, by construction (see `StreamBookmarkStore.add`). This
    /// is the right URL to display, to inspect, and to detect a type from; it is NOT the one to
    /// dial. `StreamBookmarkStore.connectURL(for:)` is, and it is the only thing that reassembles
    /// the secret.
    var url: URL? { URL(string: urlString) }

    /// Host for secondary display. NEVER the path — it can carry the stream key.
    var displayHost: String { url?.host ?? "—" }
}

/// Why a pasted URL was rejected — distinct cases so the sheet can give a specific message rather
/// than saving an entry that fails mysteriously later.
enum StreamValidationError: Error {
    case empty
    case notAURL
    case unrecognisedScheme(String?)
    /// SRT's own 10–79 rule, checked at save so the failure names the rule while the user is
    /// looking at the field — not three layers down as a libsrt errno at connect time.
    case passphraseLength
    /// The Keychain refused the write. The bookmark is NOT saved when this happens: a saved entry
    /// silently missing its passphrase would fail at connect with a wrong-secret rejection and no
    /// hint as to why, which is worse than not saving at all.
    case passphraseNotStored
    /// `update` was handed a bookmark that is no longer in the list — it was deleted while its edit
    /// form was open. Distinct from every other case because nothing the user can retype fixes it.
    case noLongerSaved
    /// Saved streams exist on disk and this build cannot decode them, so saving anything would
    /// overwrite them. See `StreamBookmarkStore.storedDataUnreadable`. Like `.noLongerSaved`,
    /// nothing typed into the form fixes it — but unlike every other case, refusing is what
    /// PROTECTS the user's data rather than merely declining to store theirs.
    case storeUnreadable

    var message: String {
        switch self {
        case .empty:    return "Enter a stream URL."
        case .notAURL:  return "That doesn’t look like a URL."
        case .unrecognisedScheme(let s):
            return "Unsupported URL scheme\(s.map { " “\($0)”" } ?? ""). Use https://, srt://, or an .m3u8 link."
        // ⚠️ THE RULE, NEVER A MEASUREMENT OF WHAT WAS TYPED — the same sentence, for the same
        // reason, as SRTClient.ParseError.passphraseLength, which is where that reasoning is
        // written out in full. Sourced from there rather than restated, so the two can never
        // drift into disagreeing about what SRT requires.
        case .passphraseLength:    return SRTClient.ParseError.passphraseLength.message
        case .passphraseNotStored:
            return "Couldn’t store the stream passphrase in your keychain, so this stream wasn’t saved."
        case .noLongerSaved:
            return "That stream was deleted, so there was nothing to update."
        case .storeUnreadable:
            return """
                   Your saved streams can’t be read by this version, so nothing can be saved right \
                   now — saving would overwrite them. They’re still on disk and untouched.
                   """
        }
    }
}

/// Persisted list of stream bookmarks — a small ObservableObject over one JSON-encoded UserDefaults
/// key. Main-thread only (SwiftUI drives it).
final class StreamBookmarkStore: ObservableObject {
    static let shared = StreamBookmarkStore()

    private static let key = "streamBookmarks"

    @Published private(set) var bookmarks: [StreamBookmark]

    /// ── THERE IS SAVED DATA AND WE CANNOT READ IT ───────────────────────────────────────────
    ///
    /// TRUE only for the one case worth separating: the key EXISTS and `JSONDecoder` threw. A
    /// fresh install (no key) leaves this false, and so does an empty saved list.
    ///
    /// ⚠️ WHY THIS FLAG EXISTS AT ALL. `init` used to be `try?` over the decode with `bookmarks = []`
    /// on any failure — no log, no flag — which made "you have never saved a stream" and "you have
    /// saved streams and this build cannot read them" the SAME observable state. The launch itself
    /// was non-destructive, so this looked harmless. It was not, because of what happens next: the
    /// UI says "No saved streams. Add one below.", the user does exactly that, and `add` →
    /// `persist()` writes the new one-element array OVER the original bytes. The user's own list
    /// destroys itself, on the first action the app invited.
    ///
    /// ⚠️ THE TRIGGER IS OURS, NOT THE DISK'S. This does not need corruption. ADDING A REQUIRED
    /// FIELD TO `StreamBookmark` — a `var latencyMs: Int` with no default and not Optional — makes
    /// every previously-persisted entry undecodable (`DecodingError.keyNotFound`), and it does so
    /// for EVERY USER AT ONCE, on the first launch after that ship. Any new field must therefore be
    /// Optional or defaulted, or arrive with an explicit migration; this flag is the backstop for
    /// the day someone forgets, not a substitute for remembering.
    ///
    /// While it is true: `persist()` refuses to write, and `add` refuses outright with
    /// `.storeUnreadable` rather than accepting an entry it cannot save. There is no in-app repair
    /// — the fix is a build that can read the data — so the state is REPORTED, never worked around.
    @Published private(set) var storedDataUnreadable = false

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        if let data {
            do {
                bookmarks = try JSONDecoder().decode([StreamBookmark].self, from: data)
            } catch {
                // The one case the old `try?` erased. Logged with the byte count and the decoder's
                // own error, because "which field" is the whole diagnosis and the error names it.
                bookmarks = []
                storedDataUnreadable = true
                NSLog("""
                      [STREAMS] ⚠️ %d bytes of saved streams are present and CANNOT BE DECODED by \
                      this build — the list is being shown as empty, and NOTHING WILL BE WRITTEN \
                      OVER IT. The original bytes are intact under UserDefaults key "%@". \
                      Decoder said: %@
                      """, data.count, Self.key, String(describing: error))
            }
        } else {
            bookmarks = []   // fresh install: no key. Distinct from the case above.
        }
        migratePassphrasesToKeychain()
    }

    /// ── ONE-SHOT MIGRATION: PASSPHRASES OUT OF THE PLIST ────────────────────────────────────
    ///
    /// Before the passphrase moved to the Keychain, nothing stopped a user pasting
    /// `srt://host:9000?passphrase=…` into the Add field: `validate` accepted the scheme, `add`
    /// stored `absoluteString` verbatim, and the row sat greyed as an unsupported type with the
    /// secret sitting in cleartext in the preferences plist. Those bookmarks exist in the wild —
    /// SRT being unconnectable never stopped anyone SAVING one — and shipping the Keychain path
    /// without this would leave them exactly where they are, forever, while the new code looks
    /// correct.
    ///
    /// So: move the value, rewrite the entry without it, persist once. Idempotent — a second run
    /// finds nothing to strip. It writes to the Keychain but never reads it, so it cannot
    /// clobber a value already migrated: `strippingPassphrase` only yields one when the URL still
    /// carries it, which is the case this exists for.
    ///
    /// ⚠️ THE STRIP IS GATED ON A CONFIRMED WRITE. `KeychainStore.set` returns whether the value is
    /// actually stored, and it can fail for reasons that have nothing to do with us — a locked
    /// keychain, a denied ACL, a full disk. Stripping anyway would destroy the only copy of a
    /// credential the user may not have written down, to fix an exposure. So a failed write leaves
    /// the entry BYTE-FOR-BYTE ALONE, still carrying its passphrase, still working, and the next
    /// launch tries again.
    ///
    /// ── WHAT THIS DOES NOT DO ───────────────────────────────────────────────────────────────
    ///
    /// IT DOES NOT RECALL A SECRET ALREADY WRITTEN. Rewriting the preferences plist removes the
    /// value from the CURRENT file and nothing more. Copies plausibly persist in Time Machine
    /// snapshots and local APFS snapshots, in whatever backup or sync service holds the user's
    /// Library, and in unallocated disk blocks the old file occupied — none of which this code can
    /// reach, and none of which it should pretend to. What migration buys is that the exposure
    /// stops GROWING: no new plist write carries the value, and every future read comes from the
    /// Keychain. A passphrase that was already sitting in a synced preferences file should still be
    /// rotated at the sender; moving it here is not a substitute for that.
    ///
    /// ⚠️ Logs COUNTS and nothing else. Not the value, not its length, not the host it belongs to.
    private func migratePassphrasesToKeychain() {
        var migrated = 0
        var failed = 0
        bookmarks = bookmarks.map { bookmark in
            guard let url = bookmark.url,
                  let split = Self.strippingPassphrase(from: url),
                  let passphrase = split.passphrase else { return bookmark }
            guard KeychainStore.streams.set(passphrase, for: bookmark.id.uuidString) else {
                failed += 1
                return bookmark   // untouched — the URL keeps the only copy there is
            }
            migrated += 1
            var moved = bookmark
            moved.urlString = split.url.absoluteString
            return moved
        }
        if failed > 0 {
            NSLog("""
                  [STREAMS] ⚠️ could not write %d stream passphrase(s) to the Keychain — those \
                  bookmarks were left untouched and still carry the value in preferences. Will \
                  retry on the next launch.
                  """, failed)
        }
        guard migrated > 0 else { return }
        NSLog("[STREAMS] moved %d saved stream passphrase(s) out of preferences and into the Keychain",
              migrated)
        persist()
    }

    /// The single write. Two things it will NOT do silently.
    ///
    /// 1. IT WILL NOT WRITE OVER DATA IT COULD NOT READ. See `storedDataUnreadable`. Every caller
    ///    is gated ahead of this too (`add` returns `.storeUnreadable`; `update` and `delete` are
    ///    unreachable with an empty list), so reaching this guard means a new call site was added
    ///    without one — which is exactly when a backstop earns its keep. Logged, not just skipped.
    ///
    /// 2. IT WILL NOT SWALLOW AN ENCODE FAILURE. This was `if let data = try? …`, so a throwing
    ///    encode skipped the `set` and returned as if it had saved: `add` answered `.success`, the
    ///    row appeared in the list, and the entry was gone at the next launch with nothing in the
    ///    log to connect the two. `JSONEncoder` on this type should not throw — every field is
    ///    trivially Codable — which is the reason to log it rather than to assume it away, since
    ///    an occurrence would mean the type had changed into something that can.
    private func persist() {
        guard !storedDataUnreadable else {
            NSLog("""
                  [STREAMS] ⚠️ refusing to persist: saved data is present but undecodable by this \
                  build, and writing now would destroy it. %d in-memory bookmark(s) NOT saved.
                  """, bookmarks.count)
            return
        }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(bookmarks), forKey: Self.key)
        } catch {
            NSLog("[STREAMS] ⚠️ could not encode %d stream bookmark(s) — NOTHING WAS SAVED: %@",
                  bookmarks.count, String(describing: error))
        }
    }

    /// The single gate every add/connect path runs through, so what can be SAVED and what can be
    /// CONNECTED can never diverge: parses as a URL, has a host, and uses a scheme we recognise.
    static func validate(_ raw: String) -> Result<(url: URL, type: StreamType), StreamValidationError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host != nil else {
            return .failure(.notAURL)
        }
        switch scheme {
        case "http", "https", "srt": return .success((url, StreamType.detect(url)))
        default:                     return .failure(.unrecognisedScheme(url.scheme))
        }
    }

    /// Add a validated bookmark (name falls back to the host if blank). Returns the created entry —
    /// even when its type is unsupported, so it is still saved and listed — or the validation error.
    ///
    /// `passphrase` is the editor's dedicated field. It WINS over one embedded in the URL's query,
    /// because it is the one the user just typed into a control labelled for the purpose; a
    /// leftover `?passphrase=` in a pasted URL is the older, likelier-stale value. Either way the
    /// URL is stripped, so exactly one of them survives and it is never the plist's copy.
    @discardableResult
    func add(name: String, urlString: String,
             passphrase: String? = nil) -> Result<StreamBookmark, StreamValidationError> {
        // ⚠️ BEFORE VALIDATION, AND BEFORE ANY KEYCHAIN WRITE. This is the one path that can reach
        // `persist()` while the list is empty, so it is the path on which the user's undecodable
        // saved streams actually get destroyed — see `storedDataUnreadable`. Refusing here (rather
        // than only inside `persist`) is what keeps the answer honest: appending to the in-memory
        // list and returning `.success` while nothing is written would put the row on screen and
        // lose it at the next launch, which is a second silent failure stacked on the first.
        guard !storedDataUnreadable else { return .failure(.storeUnreadable) }
        switch Self.validate(urlString) {
        case .failure(let e): return .failure(e)
        case .success(let (url, type)):
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmedName.isEmpty ? (url.host ?? "Stream") : trimmedName

            // STRIP BEFORE THE STRING IS EVER BUILT, not after it is stored. `sanitized` is what
            // becomes `urlString`, so there is no window — not even a transient plist write — in
            // which the persisted entry carries the secret.
            let split = Self.strippingPassphrase(from: url)
            let sanitized = split?.url ?? url
            let typed = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = (typed?.isEmpty == false ? typed : nil) ?? split?.passphrase

            // Same rule the URL path enforces, applied to whichever value survived above, so a
            // typed field and a pasted `?passphrase=` cannot be held to different standards.
            if let secret, !SRTClient.Endpoint.passphraseLengthRange.contains(secret.count) {
                return .failure(.passphraseLength)
            }

            let bookmark = StreamBookmark(name: finalName, urlString: sanitized.absoluteString,
                                          type: type)
            if let secret {
                // Keyed by the bookmark's own UUID, which is why the write happens here rather
                // than in the sheet: this is where the id exists and where `delete` can match it.
                //
                // WRITE FIRST, APPEND SECOND, and fail the whole save if the write fails — same
                // reasoning as the migration's gate. A listed bookmark whose secret silently went
                // nowhere would fail at connect as a wrong-passphrase rejection from the server,
                // which is the least debuggable outcome available.
                guard KeychainStore.streams.set(secret, for: bookmark.id.uuidString) else {
                    NSLog("[STREAMS] ⚠️ keychain write failed — stream not saved")
                    return .failure(.passphraseNotStored)
                }
            }
            bookmarks.append(bookmark)
            persist()
            return .success(bookmark)
        }
    }

    // MARK: - Edit in place

    /// What an edit does to the stored passphrase. THREE-WAY ON PURPOSE, because the two-way version
    /// (a string that is either empty or not) cannot express the case the edit form is actually in
    /// most of the time: the field is blank because the passphrase was never loaded into it, not
    /// because the user wants it gone. Collapsing those two would delete a working credential every
    /// time someone edited a stream's name.
    enum PassphraseEdit {
        /// Leave whatever is stored exactly as it is. THE DEFAULT, and what a blank field means.
        case unchanged
        /// Replace the stored value with this one (subject to the same 10–79 rule as `add`).
        case set(String)
        /// Delete the stored item. Only ever reached from an explicit control the user pressed.
        case remove
    }

    /// Edit a saved bookmark IN PLACE. The name, the URL, the derived type, and — per `passphrase` —
    /// the Keychain item, all under the entry's EXISTING id.
    ///
    /// ── WHY THIS EXISTS AT ALL RATHER THAN delete() + add() ─────────────────────────────────────
    ///
    /// `add` mints a fresh `UUID`, and the Keychain account name is that UUID's string and nothing
    /// else. So a delete-then-add "edit" would file the passphrase under a NEW account while the old
    /// account keeps its value — except `delete` would have removed it, so the honest failure mode is
    /// worse than orphaning: the user edits a stream's name and the passphrase silently vanishes, or
    /// (if the delete were skipped to avoid that) a secret is stranded under an id no code path in
    /// the app can ever produce again. Neither is recoverable from the UI that created it. Editing
    /// therefore mutates the element in place; `id` is `let` and this function never constructs a
    /// `StreamBookmark`, so there is no expression here that could produce a different UUID.
    ///
    /// ── THE TYPE IS RECOMPUTED, NOT CARRIED OVER ────────────────────────────────────────────────
    ///
    /// `type` is a STORED field derived from the URL at save time, so an edit that changes the scheme
    /// must re-derive it — `validate` does, through the same `StreamType.detect` the add path uses.
    /// And when the result is not `.srt`, THE KEYCHAIN ITEM GOES, whatever `passphrase` asked for.
    /// A passphrase on a `.web` entry is not merely useless, it is unreachable: nothing in the UI
    /// would offer to edit or remove it (the field is SRT-only), and `connectURL` would splice a
    /// `passphrase=` query onto an https URL. srt:// → https:// is exactly the edit that would leave
    /// one behind, so it is the one case handled explicitly.
    ///
    /// Ordering matches `add`'s: the Keychain WRITE happens first and aborts the whole update on
    /// failure, leaving the bookmark byte-for-byte alone. The Keychain DELETE happens last, after the
    /// list has been mutated and persisted, so no early return can destroy a secret whose bookmark
    /// was never actually changed.
    @discardableResult
    func update(_ bookmark: StreamBookmark, name: String, urlString: String,
                passphrase: PassphraseEdit) -> Result<StreamBookmark, StreamValidationError> {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else {
            return .failure(.noLongerSaved)
        }
        switch Self.validate(urlString) {
        case .failure(let e): return .failure(e)
        case .success(let (url, type)):
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmedName.isEmpty ? (url.host ?? "Stream") : trimmedName

            // Same strip-before-the-string-is-built discipline as `add`: `sanitized` is what becomes
            // `urlString`, so an edit that pastes a `?passphrase=` URL never persists it either.
            let split = Self.strippingPassphrase(from: url)
            let sanitized = split?.url ?? url

            // Resolve the three-way against the recomputed type. `write` and `clear` are mutually
            // exclusive by construction — every branch below sets at most one of them.
            var write: String?
            var clear = false
            if type != .srt {
                // Non-SRT wins over the requested edit. See the note above.
                clear = true
            } else {
                switch passphrase {
                case .remove:
                    clear = true
                case .set(let typed):
                    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                    // A `.set` that trims to nothing is not a removal — removal has its own case, and
                    // treating whitespace as one would be the two-way collapse this enum exists to
                    // avoid. It falls through to the same rule as `.unchanged`.
                    write = trimmed.isEmpty ? split?.passphrase : trimmed
                case .unchanged:
                    // "Unchanged" is about the FIELD, not the URL. A `?passphrase=` in a URL the user
                    // just pasted is a value they explicitly supplied, so it is adopted here for the
                    // same reason `add` honours one — and stripped from the stored string either way.
                    write = split?.passphrase
                }
            }

            if let write, !SRTClient.Endpoint.passphraseLengthRange.contains(write.count) {
                return .failure(.passphraseLength)
            }

            let account = bookmark.id.uuidString
            if let write {
                guard KeychainStore.streams.set(write, for: account) else {
                    NSLog("[STREAMS] ⚠️ keychain write failed — stream not updated")
                    return .failure(.passphraseNotStored)
                }
            }

            // MUTATE, never re-create. `bookmarks[index]` already carries the id, and `id` is `let`,
            // so the copy below cannot acquire a different one.
            var updated = bookmarks[index]
            updated.name = finalName
            updated.urlString = sanitized.absoluteString
            updated.type = type
            bookmarks[index] = updated
            persist()

            // Last, and only now. Harmless when there was never an item — `SecItemDelete` on a
            // missing account is a no-op — which is the common case for a `.web` entry that has
            // simply been renamed.
            if clear { KeychainStore.streams.delete(account) }
            return .success(updated)
        }
    }

    /// Delete the entry AND its passphrase. Both, always, in that order — a Keychain item whose
    /// bookmark is gone is unreachable by every code path in the app (the account name is the
    /// bookmark's UUID and nothing else can produce it), so it would be an orphaned secret that
    /// outlives the app, survives reinstalls, and is invisible in the UI that created it.
    /// `KeychainStore.delete` is a no-op when there is nothing stored, so this is safe for the
    /// common case of a bookmark that never had one.
    func delete(_ bookmark: StreamBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        KeychainStore.streams.delete(bookmark.id.uuidString)
        persist()
    }

    /// First saved bookmark of a supported (connectable) type. NOW POSSIBLY SRT — it meant "the
    /// first web one" only because web was the only supported type, and every caller must be able
    /// to dial whatever comes back. nil when nothing connectable is saved.
    var firstConnectable: StreamBookmark? { bookmarks.first { $0.type.isSupported } }

    /// First saved bookmark of ONE transport. The per-transport debug shortcuts use this so ⌃⌥H
    /// stays WHEP and ⌃⌥D stays SRT no matter which type happens to sit first in the list — each is
    /// paired with a disconnect shortcut for the same client, and a trigger that sometimes drove
    /// the other transport would leave its partner unable to tear it down.
    func firstConnectable(ofType type: StreamType) -> StreamBookmark? {
        bookmarks.first { $0.type == type && $0.type.isSupported }
    }

    // MARK: - Passphrase: the split at save, the join at connect

    /// The query key, spelled once. SRT URLs use `passphrase`, matching libsrt's own option name and
    /// what OBS/ffmpeg write, and the comparison below is case-insensitive because a hand-typed URL
    /// is not reliably lowercase.
    private static let passphraseQueryKey = "passphrase"

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
    static func strippingPassphrase(from url: URL) -> (url: URL, passphrase: String?)? {
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

    /// The URL TO DIAL — the stored one with its Keychain passphrase put back. The only place the
    /// two halves are rejoined, and the reason `StreamBookmark.url` is documented as display-only.
    ///
    /// ⚠️ THE RETURN VALUE IS A SECRET-BEARING URL. It goes to `LiveSource.connect*` and no further:
    /// never to a log, never to `lastError`, never into a bookmark. `SRTClient.parse` lifts the
    /// passphrase straight back out of the query and the rest of that path is already disciplined
    /// about it (see the ⚠️ notes there) — this function's job is to keep the value in memory
    /// between the Keychain and that parse, and nowhere else.
    ///
    /// Falls back to the stored URL unchanged when there is no stored passphrase, which is every
    /// web bookmark and any SRT one that does not need encryption.
    static func connectURL(for bookmark: StreamBookmark) -> URL? {
        guard let url = bookmark.url else { return nil }
        guard let secret = KeychainStore.streams.get(bookmark.id.uuidString), !secret.isEmpty else {
            return url
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        // Defensive: the stored URL should never carry one (add + the migration both strip it), so
        // drop any duplicate rather than appending a second `passphrase=` the parser would have to
        // choose between.
        items.removeAll { $0.name.lowercased() == passphraseQueryKey }
        items.append(URLQueryItem(name: passphraseQueryKey, value: secret))
        components.queryItems = items
        return components.url ?? url
    }
}

/// The Settings window contents (opens with ⌘,).
struct SettingsView: View {
    // NDI runtime presence for the "NDI Runtime" status row. Observed so the row updates when
    // refreshRuntimeStatus() publishes (called from that section's .onAppear).
    @ObservedObject private var ndi = NDIService.shared

    // DeckLink driver + device presence for the "DeckLink" status row. Observed so the tri-state row
    // updates when refreshDevices() publishes (called from that section's .onAppear).
    @ObservedObject private var dl = DeckLinkService.shared

    // @AppStorage here drives the picker and persists the choice, writing the SAME
    // "controlDisplayMode" key WindowChrome seeds each window from. This is currently the only
    // control surface for overlay-vs-docked, which is why WindowChrome adopts external writes to
    // that key — without that, flipping this picker would change nothing until the next window was
    // opened. See the observer comment in WindowChrome.
    @AppStorage("controlDisplayMode") private var controlModeRaw: String = ControlDisplayMode.overlay.rawValue

    // ── RASTER SIZE: THE SEED, NOT A REMOTE CONTROL ─────────────────────────────────────────
    //
    // The SAME key each window's `WindowChrome` seeds its raster state from, with the app's usual
    // last-writer-wins semantics — so this picker shows the last size any window was set to, and
    // sets what the NEXT window opens at.
    //
    // ⚠️ IT DELIBERATELY DOES NOT REACH OPEN WINDOWS, and that is the opposite of the "Controls"
    // picker above. That one flips every open window because it is the ONLY control surface
    // overlay-vs-docked has, and `WindowChrome` adopts external writes to its key to stop it reading
    // as dead. Raster size has a per-window control (the View menu), and `WindowChrome`'s own note
    // spells out the consequence: adopting a global write would stomp a window's local choice. Two
    // windows deliberately set to different sizes must survive a visit to Settings.
    @AppStorage(RasterSize.defaultsKey) private var rasterDefault: RasterSize = .automatic
    @AppStorage("autoplayOnLoad") private var autoplayOnLoad: Bool = true
    @AppStorage("globalScopeIntensity") private var globalScopeIntensity: Double = 1.0
    @AppStorage("scopeScale") private var scopeScale: ScopeScale = .bit10

    // DeckLink output: explicit "start output on launch" opt-in (NOT last-session persistence).
    // Shared key with DeckLinkService so it can't drift. Default off.
    @AppStorage(DeckLinkService.enableOnLaunchKey) private var deckLinkEnableOnLaunch = false

    // Framing-guide styling (defaults reproduce Pass 1's look).
    @AppStorage("guideDarkenOpacity") private var guideDarkenOpacity = 0.85
    @AppStorage("guideDarkenColor") private var guideDarkenHex = "000000"
    @AppStorage("guideLineColor") private var guideLineHex = "FFFFFF"
    @AppStorage("guideLineWidth") private var guideLineWidth = 2.0
    @AppStorage("safeLineColor") private var safeLineHex = "FFFF00"
    @AppStorage("safeLineWidth") private var safeLineWidth = 1.0
    @AppStorage("safeLineOpacity") private var safeLineOpacity = 0.75

    // Broadcast-safe styling only — the action/title percentages are framing decisions
    // and live in the guides popover, not here.
    @AppStorage("broadcastSafeColor") private var broadcastSafeHex = Preferences.defaultBroadcastSafeHex
    @AppStorage("broadcastSafeWidth") private var broadcastSafeWidth = Preferences.defaultBroadcastSafeWidth
    @AppStorage("broadcastSafeOpacity") private var broadcastSafeOpacity = Preferences.defaultBroadcastSafeOpacity

    // For reactive display of the chosen export folder (writes go via Preferences).
    @AppStorage("exportFolderBookmark") private var exportFolderBookmark = Data()

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for exported frames"
        if panel.runModal() == .OK, let url = panel.url {
            Preferences.shared.setExportFolder(url)
        }
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { ScopeColorCodec.color(fromHex: hex.wrappedValue) },
                set: { hex.wrappedValue = ScopeColorCodec.hex(from: $0) })
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    /// Consistent labeled slider row with a trailing value readout.
    private func sliderRow(_ label: String, _ value: Binding<Double>,
                           in range: ClosedRange<Double>, readout: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range).frame(width: 160)
                Text(readout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    var body: some View {
        Form {
            // License state + key entry / deactivation (App-layer licensing subsystem).
            LicenseSettingsSection()

            // Setup/readiness concerns grouped near the top. Broader than NDI alone — a DeckLink
            // device-detection row is planned here too (hence "I/O and Runtimes").
            Section("I/O and Runtimes") {
                LabeledContent("NDI Runtime") {
                    if ndi.runtimeAvailable {
                        Text("Installed" + (ndi.runtimeVersion.map { " (\($0))" } ?? ""))
                            .foregroundStyle(.secondary)
                    } else {
                        // Attention-worthy but not alarming — orange, not red.
                        Text("Not installed")
                            .foregroundStyle(.orange)
                    }
                }
                Button("Install NDI Runtime…") {
                    NSWorkspace.shared.open(NDIService.runtimeInstallURL)
                }
                Text("After installing the NDI runtime, relaunch Manifold to enable NDI sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // DeckLink — the full readiness state (driver present / version vs the output floor /
                // devices), one row per distinguishable case. The version is included in every case
                // where we have it: a driver below the floor used to show here as a bare "No device
                // detected", which is both wrong and unactionable. Driver presence and version are
                // relaunch-only (the framework load is cached); card plug/unplug is picked up on the
                // next refresh, which is why only the driver-side states carry a relaunch caption.
                let dlStatus = dl.driverStatus
                LabeledContent("DeckLink") {
                    Text(dlStatus.headline)
                        // Orange = the user can fix it by installing/updating a driver; grey = nothing
                        // is wrong with the software, there's just no card.
                        .foregroundStyle(dlStatus == .notInstalled || dlStatus.isBelowFloor
                                         || dlStatus == .versionUnreadable ? .orange : .secondary)
                }
                if dlStatus == .notInstalled || dlStatus.isBelowFloor {
                    Button(dlStatus.isBelowFloor ? "Update Desktop Video…" : "Download Desktop Video…") {
                        NSWorkspace.shared.open(DeckLinkService.driverInstallURL)
                    }
                }
                if let detail = dlStatus.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !dl.devices.isEmpty {
                    // Ready — name the hardware (what the old single-device row showed).
                    Text(dl.devices.map(\.displayName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Detection is lazy; refresh when Settings opens so the rows are current. NDI is
            // relaunch-only; DeckLink card presence updates live via this re-enumeration.
            .onAppear {
                NDIService.shared.refreshRuntimeStatus()
                DeckLinkService.shared.refreshDevices()
            }

            Section("DeckLink Output") {
                Toggle("Enable output on launch", isOn: $deckLinkEnableOnLaunch)
                Text("When on, Manifold starts DeckLink output at launch if a capable device is connected. Otherwise it does nothing. Turning output on or off during a session doesn't change this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Interface Options") {
                Picker("Controls", selection: $controlModeRaw) {
                    ForEach(ControlDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)

                Toggle("Autoplay on open", isOn: $autoplayOnLoad)

                Picker("Raster size for new windows", selection: $rasterDefault) {
                    ForEach(RasterSize.settingsChoices) { size in
                        Text(size.menuTitle).tag(size)
                    }
                }
                Text("How large the picture is drawn, as a percentage of the source raster — 100% is one source pixel per source pixel, so a 3840×2160 file fills 1920×1080 points on a Retina display. Set it per window in the View menu (⌘1–⌘4, ⌘0); this is what a new window starts at, and it follows the last window you set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Scopes") {
                Picker("Scope Scale", selection: $scopeScale) {
                    ForEach(ScopeScale.selectable) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                LabeledContent("Master scope intensity") {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(value: $globalScopeIntensity, in: Preferences.scopeIntensityRange)
                            .frame(width: 160)
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Frame Export") {
                LabeledContent("Folder") {
                    Text(Preferences.displayPath(forBookmark: exportFolderBookmark))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") { chooseExportFolder() }
                    if !exportFolderBookmark.isEmpty {
                        Button("Use Desktop") { Preferences.shared.clearExportFolder() }
                    }
                }
            }

            Section("Framing Guides") {
                // Crop guide
                ColorPicker("Outside (darken) color", selection: colorBinding($guideDarkenHex))
                sliderRow("Outside opacity", $guideDarkenOpacity, in: 0.0...1.0,
                          readout: pct(guideDarkenOpacity))
                ColorPicker("Guide line color", selection: colorBinding($guideLineHex))
                Stepper("Guide line width: \(Int(guideLineWidth)) pt",
                        value: $guideLineWidth, in: 1...10, step: 1)
                // Social safe zones (the top/bottom platform keep-out lines)
                ColorPicker("Social safe zone color", selection: colorBinding($safeLineHex))
                Stepper("Social safe zone width: \(Int(safeLineWidth)) pt",
                        value: $safeLineWidth, in: 1...8, step: 1)
                sliderRow("Social safe zone opacity", $safeLineOpacity, in: 0.0...1.0,
                          readout: pct(safeLineOpacity))
            }

            Section("Broadcast safe zones") {
                ColorPicker("Broadcast safe zone color", selection: colorBinding($broadcastSafeHex))
                Stepper("Broadcast safe zone width: \(Int(broadcastSafeWidth)) pt",
                        value: $broadcastSafeWidth, in: 1...8, step: 1)
                sliderRow("Broadcast safe zone opacity", $broadcastSafeOpacity, in: 0.0...1.0,
                          readout: pct(broadcastSafeOpacity))
                Text("Action- and title-safe percentages are set in the framing guides popover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 520)
    }
}
