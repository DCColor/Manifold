import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// How the transport controls are presented.
/// Where **Open…** puts a file: into the window you invoked it from, or into a new one.
///
/// ⚠️ IT IS A PREFERENCE ABOUT `Open…` AND NOTHING ELSE. A drop onto a window's picture always
/// targets THAT window (the drop names its own target, which is the whole point of dropping), and an
/// empty window is always re-used whatever this says — see `DeckRegistry.openFromUserAction`.
enum OpenDestination: String, CaseIterable, Identifiable {
    /// Replace what is in the current window. The app's behaviour before this preference existed,
    /// and therefore the default — a preference should not change what anyone already has.
    case thisWindow
    /// Leave the current window alone and open a second deck.
    case newWindow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisWindow: return "This window"
        case .newWindow:  return "A new window"
        }
    }

    /// One spelling of the key, read by Settings and by the registry that acts on it.
    static let defaultsKey = "manifold.open.destination"
}

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

    /// ⚠️ DEFAULTS OFF, AND THE DEFAULT IS THE ONLY THING THAT CHANGED — the preference stays.
    ///
    /// Opening a file should show you a frame, not start running it: this is a monitoring and
    /// inspection tool, and a clip that begins playing the instant it lands has already moved off
    /// the frame the user opened it to look at. Reported by testers.
    ///
    /// WHO THIS CHANGES IT FOR, exactly. `@AppStorage`'s default applies only when the key is
    /// ABSENT, so:
    ///   * a user who has NEVER touched the toggle has no stored value and gets the new `false`;
    ///   * a user who has EVER flipped it — including flipping it off and back on — has a stored
    ///     value and keeps it, autoplay included.
    /// Nothing else in the app writes this key (it is read by `WindowDeck.shouldAutoplayOnLoad` and
    /// written only by the Settings toggle), so "never touched it" really does mean "no key".
    @AppStorage("autoplayOnLoad") var autoplayOnLoad: Bool = false

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
/// later implementation needs no migration. All three connect today — `.web` from the start,
/// `.srt` from stage 3e, `.hls` once the AVPlayer pull route landed — and each arrived by
/// changing `isSupported` and nothing else. See that property for what a single gate bought.
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
    var isSupported: Bool { true }

    /// Honest greyed-row reason for an unsupported entry; nil when supported.
    ///
    /// ⚠️ KEPT, AND DELIBERATELY NOT DELETED NOW THAT NOTHING RETURNS A REASON. This is the seam a
    /// FOURTH transport is detected on before it is implemented — the state `.srt` and `.hls` both
    /// passed through, where a bookmark is saved, listed and honestly refused rather than rejected
    /// at the door and lost. Deleting it would mean the next transport's detection-only stage has
    /// to rebuild all four call sites above instead of returning a string.
    var unsupportedReason: String? {
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

    /// Set when the Keychain REFUSED a stream-passphrase read (never when there simply is none).
    ///
    /// The sibling of `storedDataUnreadable`, one layer down: that one means "the bookmark list
    /// would not decode", this one means "a bookmark's secret would not come out of the Keychain".
    /// Same doctrine — say so, change nothing, and do not let the app act as though the value was
    /// never there. See `connectURL`, which is where treating a refusal as absence used to turn a
    /// readable secret into an unexplained SRT handshake failure.
    @Published private(set) var passphraseUnreadable: String?

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
        // ⚠️ `migratePassphrasesToKeychain()` USED TO BE CALLED HERE, AND THE PLACEMENT WAS THE BUG
        // — not the migration, which is unchanged below. See `migratePassphrasesAtLaunch`.
        //
        // `ContentView` holds `@ObservedObject private var bookmarks = StreamBookmarkStore.shared`
        // as a STORED PROPERTY INITIALISER, so this `init` runs the first time `ContentView()` is
        // evaluated — inside the `WindowGroup` content closure, on the main thread, BEFORE the
        // scene's `.task` modifiers are attached and before the window has painted. A Keychain
        // WRITE therefore sat ahead of the first frame, earlier in the launch than licensing, where
        // no amount of restructuring `LicenseManager.bootstrap` could reach it.
        //
        // This `init` now does only what it claims: decode the list. No Keychain, no I/O beyond
        // the one `UserDefaults` read above, nothing that can block a paint or raise a dialog.
    }

    /// Whether this process has already ATTEMPTED the passphrase migration.
    /// See `migratePassphrasesAtLaunch`, which is the only thing that reads or writes it.
    private var hasAttemptedPassphraseMigration = false

    /// Runs the one-shot passphrase migration, once per process, from after the first frame.
    ///
    /// ── WHY THIS IS A DEFERRAL AND NOT AN `async` SPLIT ─────────────────────────────────────
    ///
    /// The alternative was to make the migration itself asynchronous — batch the Keychain writes
    /// off the main actor, then return to mutate `bookmarks`. That was REJECTED, and the reason is
    /// worth keeping. `migratePassphrasesToKeychain` is NOT PURE I/O: it maps over `bookmarks`,
    /// which is `@Published` on an `ObservableObject`. An async version therefore has to carry the
    /// correlation between "which write succeeded" and "which entry may be stripped" across a
    /// suspension point — and getting that correlation wrong strips a passphrase whose write
    /// FAILED, destroying the only copy of a credential the user may never have written down. That
    /// is the one place in this line of work where a mistake loses user data, and it is not a risk
    /// worth taking inside a change about launch responsiveness.
    ///
    /// Deferring buys the actual goal — the migration is off the launch path — without touching one
    /// line of the migration's logic. Nothing needs it before the first frame: no stream passphrase
    /// is read until connect, and `connectURL` is the only reader.
    ///
    /// ⚠️ IF THE APP IS QUIT BEFORE THIS RUNS, NOTHING IS LOST AND NOTHING CHANGES. An unmigrated
    /// bookmark still carries its passphrase inline in `urlString`, exactly as it does today.
    /// `connectURL` reads the Keychain, gets `.absent` — NOT `.failed`, so it does not refuse — and
    /// returns the stored URL unchanged, which still has `?passphrase=` on it for `SRTClient.parse`
    /// to lift back out. The stream dials and works. The migration simply runs at the next launch.
    ///
    /// ── ONCE PER PROCESS, NOT ONCE PER WINDOW ──────────────────────────────────────────────
    ///
    /// ⚠️ THE GUARD IS ON THE ATTEMPT, NOT ON SUCCESS, and that is deliberate. `.task` is attached
    /// to the `WindowGroup`'s content, so it fires for EVERY window — without this, opening a second
    /// deck would re-run the migration and, on a keychain that prompts, raise a second dialog for
    /// something the user did not ask for. Guarding the attempt reproduces exactly the cadence the
    /// `init` call had: one attempt per process, and a failure retried on the NEXT LAUNCH.
    ///
    /// ⚠️ AND THAT RETRY-FOREVER BEHAVIOUR IS CORRECT. A keychain that keeps refusing means this
    /// runs at every launch and never converges. That is the price of the confirmed-write gate
    /// below, which exists so a failed write can never destroy the only copy of a credential. It is
    /// not a defect to be fixed by dropping the retry or by relaxing the gate.
    ///
    /// `@MainActor` because this class is main-thread only (see the type's own note) and `.task`
    /// hands us a nonisolated closure — the annotation is what makes the hop explicit at the call
    /// site rather than accidental.
    @MainActor
    func migratePassphrasesAtLaunch() {
        guard !hasAttemptedPassphraseMigration else { return }
        hasAttemptedPassphraseMigration = true
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
            let status = KeychainStore.streams.write(passphrase, for: bookmark.id.uuidString)
            guard status == errSecSuccess else {
                failed += 1
                // ⚠️ Logs the OSStatus, never the value or the bookmark's host. The status is what
                // tells a locked keychain apart from a denied one; the rest is not ours to send.
                NSLog("[STREAMS] ⚠️ passphrase migration write failed (%@)",
                      keychainStatusDescription(status))
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
                let status = KeychainStore.streams.write(write, for: account)
                guard status == errSecSuccess else {
                    NSLog("[STREAMS] ⚠️ keychain write failed (%@) — stream not updated",
                          keychainStatusDescription(status))
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

    /// Record/clear the passphrase-read fault. `connectURL` is `static` and the flag is instance
    /// state, so these exist to keep the hop through `shared` in one named place.
    fileprivate func notePassphraseUnreadable(_ status: OSStatus) {
        let text = """
                   Manifold couldn’t read this stream’s saved passphrase from the Keychain                    (\(keychainStatusDescription(status))). The passphrase is still saved and hasn’t                    been changed. Manifold didn’t connect rather than connect without it — quitting                    and reopening usually clears this, and there’s no need to re-enter it.
                   """
        if passphraseUnreadable != text { passphraseUnreadable = text }
    }

    fileprivate func notePassphraseReadable() {
        if passphraseUnreadable != nil { passphraseUnreadable = nil }
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
    /// ⚠️ RETURNS NIL WHEN THE PASSPHRASE READ IS REFUSED, rather than the bare URL.
    ///
    /// This used to be `get(...)` collapsing to nil, so a refused read and a stream that needs no
    /// passphrase produced the SAME RESULT: dial without one. For an encrypted SRT stream that is
    /// a rejected handshake several seconds later, reported as a connection failure — the user is
    /// told the stream is unreachable when what actually happened is that their saved passphrase
    /// was sitting right there and we were not allowed to read it. Refusing to dial is the honest
    /// answer, and it is also the recoverable one: nothing is overwritten and the next attempt,
    /// against an unlocked keychain, just works.
    static func connectURL(for bookmark: StreamBookmark) -> URL? {
        guard let url = bookmark.url else { return nil }
        let read = KeychainStore.streams.read(bookmark.id.uuidString)
        if let status = read.failureStatus {
            NSLog("[STREAMS] ⚠️ stored passphrase could not be read (%@) — not dialling without it",
                  keychainStatusDescription(status))
            shared.notePassphraseUnreadable(status)
            return nil
        }
        shared.notePassphraseReadable()
        guard let secret = read.value, !secret.isEmpty else {
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

/// ── THE LAUNCH SERVICES DEFAULT HANDLER FOR ONE CONTENT TYPE, AS A SETTINGS ROW ─────────────
///
/// Built in the "I/O and Runtimes" idiom — read the system's state, show what it says, offer to
/// change it, re-read on appear — and deliberately NOT in the `@AppStorage` idiom every other row
/// in Settings uses.
///
/// ⚠️ THIS IS NOT A PREFERENCE AND MUST NOT BE STORED AS ONE. The default handler lives in the
/// Launch Services database. The user can change it from Finder's Get Info without this app ever
/// running, and installing another video app can change it too. A mirrored `@AppStorage` copy would
/// be a second answer to a question the system already answers, and it would be the WRONG answer
/// the moment either of those happens. Everything below is read from `NSWorkspace` on demand.
///
/// ── ⚠️ ONE INSTANCE PER TYPE, AND NEVER A CONTROL THAT CLAIMS SEVERAL AT ONCE ───────────────
///
/// Each type gets its own instance, its own row and its own button, because taking `.mov` and
/// taking `.mp4` are genuinely different decisions and a user may want one without the other.
/// A single "make Manifold the default video player" action would collapse three deliberate
/// choices into one click that displaces associations the user made on purpose — which is exactly
/// the aggressive move this design exists to avoid. There is deliberately no claim-all path.
final class DefaultHandlerStatus: ObservableObject, Identifiable {

    /// ── WHERE THE INSTANCES LIVE, AND WHY THEY ARE STATIC RATHER THAN `@StateObject` ────────
    ///
    /// Statics, in one array, for three reasons:
    ///
    ///   1. It is the idiom already in this file — every other observed object in `SettingsView`
    ///      (`NDIService.shared`, `DeckLinkService.shared`) is a shared instance, and a reader
    ///      should not have to work out why this one is different.
    ///   2. THE ARRAY IS WHAT KEEPS THE WIRING SINGULAR. The section's `.onAppear` refreshes the
    ///      whole array in one line; adding a fourth type is one entry here and nothing else. Three
    ///      `@StateObject`s would mean three declarations, three refresh calls and three chances
    ///      to forget one.
    ///   3. `@StateObject` cannot express this shape anyway: the rows are rendered from a
    ///      `ForEach`, and per-element state has to be owned outside the loop. `DefaultHandlerRow`
    ///      observes its own instance, which is what makes a single row re-render when its own
    ///      claim completes without the parent observing anything.
    ///
    /// Lifetime is not a concern in either direction: these are three tiny objects that hold no
    /// resources, and `refresh()` on appear means a stale read cannot survive the window opening.
    ///
    /// ⚠️ `.mov` AND `.mp4` ARE HERE BECAUSE THEY WERE ASKED FOR, NOT BECAUSE THEY ARE SAFE. On an
    /// editorial machine both usually have associations someone chose on purpose. That is an
    /// argument for three separate buttons and against a claim-all, NOT an argument for hiding
    /// them — the row states the current holder by name, so the user can see what they would be
    /// displacing before they do it.
    static let videoHandlers: [DefaultHandlerStatus] = [
        // `org.smpte.mxf` is a string because macOS declares the type but the SDK exposes no
        // constant for it; the other two have constants whose identifiers were CHECKED against the
        // strings in project.yml's CFBundleDocumentTypes (com.apple.quicktime-movie, public.mpeg-4)
        // rather than assumed to match.
        DefaultHandlerStatus(contentType: UTType("org.smpte.mxf"), name: "MXF files"),
        DefaultHandlerStatus(contentType: .quickTimeMovie,         name: "QuickTime movies"),
        DefaultHandlerStatus(contentType: .mpeg4Movie,             name: "MP4 files")
    ].filter { $0.contentType != nil }

    /// The type this row is about. Optional only because `UTType(_: String)` is; the array above
    /// filters the nil case out, so a rendered row always has one.
    let contentType: UTType?

    /// How the row names the type, as a plural noun phrase — the row label reads "\(name) open in"
    /// and the count caption reads "…can open \(name)".
    let name: String

    var id: String { contentType?.identifier ?? name }

    /// Display name of the app that currently opens the type; nil if nothing claims it.
    @Published private(set) var currentHandlerName: String?

    /// Whether THIS bundle is that app.
    ///
    /// ⚠️ DECIDED BY BUNDLE IDENTIFIER, NEVER BY URL EQUALITY. MEASURED on the development machine:
    /// `urlsForApplications(toOpen:)` returns 32 URLs for `org.smpte.mxf` but only SIX distinct
    /// bundle identifiers — a sibling app alone accounts for four of them, registered from
    /// `/Applications`, from two dev trees and from a mounted DMG. Comparing URLs would report "not
    /// the default" while the app in question plainly was, and the failure would be invisible to
    /// anyone whose machine had never mounted a disk image.
    @Published private(set) var isSelf = false

    /// How many DISTINCT applications can open the type, counted by bundle identifier for the
    /// reason above — 6 / 11 / 8 for the three types here, from 32 raw URLs apiece.
    ///
    /// ⚠️ A FLOOR, NOT A TOTAL, WHICH IS WHY THE CAPTION SAYS "AT LEAST". MEASURED: this returns
    /// exactly 32 URLs for all three video types AND for com.red.r3d, while returning 3 for BRAW,
    /// 5 for DPX and 14 for PDF. A number that stops dead at 32 for every type popular enough to
    /// reach it, and never exceeds it, is a cap — so a type with more than 32 registrations has
    /// candidates we were never shown, and any count derived from this list can only be a lower
    /// bound. Stating it as an exact total would be asserting something this API does not tell us.
    @Published private(set) var candidateCount = 0

    /// ── WHAT A CLAIM ENDED AS, WHEN IT DID NOT END AS SUCCESS ──────────────────────────────
    ///
    /// Two cases and NOT one string, because the row has to render them DIFFERENTLY: a decline is
    /// not a failure and must not be dressed as one. Success is the absence of this value — the
    /// row states it by saying "Manifold" and dropping the button, which is a stronger statement
    /// than any sentence would be.
    enum ClaimOutcome {

        /// The user was asked and said no. `keeping` is whatever still holds the type, taken from
        /// the re-query rather than remembered from before — so the sentence and the row above it
        /// come from the same read and cannot disagree.
        case declined(keeping: String?)

        /// Something went wrong and we do not know what. Carries the system's own description,
        /// which is the honest thing to show when we have nothing better to say.
        case failed(String)

        var message: String {
            switch self {
            case .declined(let keeping):
                // Names WHAT SURVIVED rather than what did not happen. "Kept “Screen”" describes
                // the state of the machine; "the default wasn't changed" describes our failed
                // attempt, which is not the user's concern — they answered a question and the
                // machine did what they said.
                if let keeping { return "Kept “\(keeping)”." }
                return "No change."
            case .failed(let description):
                return description
            }
        }

        /// Whether the row should draw attention to this. Only a genuine failure earns the orange
        /// the NDI and DeckLink rows use; a decline is ordinary secondary text, because there is
        /// nothing in it to act on.
        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// The outcome of the last claim attempt, when it was anything other than success. Cleared by
    /// the next read. See `claim()` — this is a first-class outcome, not an error path.
    @Published private(set) var lastOutcome: ClaimOutcome?

    /// A claim is in flight. The system may be showing the user a consent sheet during this, which
    /// is why the button disables rather than pretending the work is instantaneous.
    @Published private(set) var isChanging = false

    private init(contentType: UTType?, name: String) {
        self.contentType = contentType
        self.name = name
    }

    /// Read the truth from Launch Services. Cheap, synchronous, main-thread; called on appear and
    /// again after every claim.
    func refresh() {
        lastOutcome = nil
        guard let type = contentType else {
            currentHandlerName = nil; isSelf = false; candidateCount = 0
            return
        }
        let workspace = NSWorkspace.shared

        var identifiers = Set<String>()
        for url in workspace.urlsForApplications(toOpen: type) {
            if let identifier = Bundle(url: url)?.bundleIdentifier { identifiers.insert(identifier) }
        }
        candidateCount = identifiers.count

        guard let handler = workspace.urlForApplication(toOpen: type) else {
            currentHandlerName = nil
            isSelf = false
            return
        }
        currentHandlerName = Self.displayName(of: handler)
        let handlerID = Bundle(url: handler)?.bundleIdentifier
        isSelf = handlerID != nil && handlerID == Bundle.main.bundleIdentifier
    }

    /// Ask the system to make this app the default for the type.
    ///
    /// ── ⚠️ THE COMPLETION HANDLER RE-READS. IT DOES NOT ASSUME IT WON. ──────────────────────
    ///
    /// `setDefaultApplication(at:toOpen:completion:)` is asynchronous BECAUSE the system may put
    /// the question to the user first — AppKit's own header says so: "Some types require user
    /// consent before you can change their handlers. If a change requires user consent, the system
    /// will ask the user asynchronously before invoking the completion handler."
    ///
    /// A user who is asked can say no. So the only honest thing this can do on completion is ask
    /// Launch Services again and render whatever came back. Flipping a local flag on the strength
    /// of having CALLED the setter would put a row on screen claiming an association the app does
    /// not hold — and it would claim it most confidently in exactly the case where the user had
    /// just declined.
    ///
    /// Refusal reaches us two ways and both are handled: an `Error`, or NO error and simply no
    /// change. The `isSelf` re-read below is what catches the second, which is why the outcome is
    /// derived from the re-read rather than from `error == nil`.
    func claim() {
        guard let type = contentType, !isChanging else { return }
        isChanging = true
        lastOutcome = nil

        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { [weak self] error in
            // The callback's queue is not documented as main; the published properties below drive
            // a view. Marshal, exactly as NDIService's status refresh does.
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChanging = false
                self.refresh()                    // clears lastOutcome; re-establishes the truth
                if self.isSelf { return }         // it took — the row now says so on its own
                if let error {
                    // POSITIVE IDENTIFICATION, NOT ELIMINATION. A decline is recognised by the
                    // OSStatus it nests, so anything we cannot recognise is reported as itself
                    // rather than guessed at — which is why question 2 (does a genuine failure
                    // return something other than 256?) stopped mattering: we no longer need it
                    // to differ.
                    let ns = error as NSError
                    self.lastOutcome = Self.isUserCancelled(ns)
                        ? .declined(keeping: self.currentHandlerName)
                        : .failed(ns.localizedDescription)
                } else {
                    // ⚠️ THIS IS NOT THE DECLINE PATH. It used to claim it was, and that was
                    // provably wrong: a decline arrives WITH an error and is handled above.
                    //
                    // What this branch actually is: the setter reported success and the re-query
                    // still does not name us. It has NEVER BEEN OBSERVED TO FIRE. It is retained
                    // because whether it CAN is unknown — the completion contract is undocumented,
                    // so "no error, no change" is not ruled out — and if it ever does happen this
                    // message is the only thing that will say so.
                    self.lastOutcome = .failed("The default wasn't changed.")
                }
            }
        }
    }

    /// Did the user decline, as opposed to something going wrong?
    ///
    /// ── THE MEASUREMENT THIS IS BUILT ON ────────────────────────────────────────────────────
    ///
    /// RUN: pressed "Use Manifold" on the MP4 row (public.mpeg-4), then chose Keep “Screen” in the
    /// system's consent dialog.
    ///
    /// CAME BACK: NSCocoaErrorDomain 256 — `NSFileReadUnknownError`, Cocoa's generic "read failed,
    /// reason unspecified" — carrying NSUnderlyingError = NSOSStatusErrorDomain -128,
    /// `userCanceledErr`.
    ///
    /// THE TOP-LEVEL CODE SAYS NOTHING. 256 is what Cocoa returns when it has nothing specific, a
    /// genuine failure could carry it too, and its `localizedDescription` is "The file couldn’t be
    /// opened." — a sentence about files, which is what this row used to show a user who had just
    /// answered a question correctly. THE UNDERLYING CODE IS THE WHOLE SIGNAL, which is why this
    /// walks the chain rather than reading the top.
    ///
    /// ⚠️ APPKIT DOCUMENTS NONE OF THIS, so it is measured behaviour and not a contract.
    /// NSWorkspace.h describes the consent prompt but says nothing about what the completion
    /// handler reports, and the whole NSWorkspace error range in AppKitErrors.h (67328–67455)
    /// holds exactly one named code — NSWorkspaceAuthorizationInvalidError — which concerns
    /// NSWorkspaceAuthorization and not default handlers. There is no "user declined" constant to
    /// match against. If a future macOS stops nesting -128, the cost is that a decline reads as a
    /// failure again; the row stays correct about the STATE either way, because that comes from
    /// the re-query and not from here.
    ///
    /// ⚠️ MATCHED ON DOMAIN AND CODE, NEVER ON TEXT. Every OSStatus error renders as the same
    /// sentence with a different number in it — "The operation couldn’t be completed. (OSStatus
    /// error N.)" — so the description distinguishes nothing whatsoever and the number is the
    /// entire content. Matching the string would also break in every localisation.
    private static func isUserCancelled(_ error: NSError) -> Bool {
        // Over the WHOLE chain: -128 was measured one level down, but nothing promises it stays
        // there, and an NSError can nest or carry several underlying errors at once.
        var pending: [NSError] = [error]
        while let current = pending.popLast() {
            if current.domain == NSOSStatusErrorDomain, current.code == userCanceledErr {
                return true
            }
            if let next = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(next)
            }
            if let several = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                pending.append(contentsOf: several)
            }
        }
        return false
    }

    /// An app's name as the user knows it. `FileManager.displayName(atPath:)` is not used: it
    /// returns "Screen.app" for anyone who has "Show all filename extensions" turned on, and the
    /// row reads badly with the extension in it.
    private static func displayName(of url: URL) -> String {
        let bundle = Bundle(url: url)
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle?.localizedInfoDictionary?[key] as? String, !name.isEmpty { return name }
            if let name = bundle?.infoDictionary?[key] as? String, !name.isEmpty { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

/// One type's row: who opens it now, and the offer to change that.
///
/// ⚠️ A VIEW OF ITS OWN SO THAT EACH ROW OBSERVES ITS OWN OBJECT. `@ObservedObject` cannot be
/// declared inside a `ForEach` closure, so without this the parent would have to observe all three
/// and every claim would re-render the whole Settings form. Here a completed claim re-renders one
/// row — the one that changed.
private struct DefaultHandlerRow: View {

    @ObservedObject var status: DefaultHandlerStatus

    var body: some View {
        LabeledContent("\(status.name) open in") {
            HStack(spacing: 8) {
                if status.isSelf {
                    // No button: the only thing it could do has already happened. A disabled one
                    // would invite "why can't I turn this off?", which is the question the caption
                    // under the group answers.
                    Text("Manifold").foregroundStyle(.secondary)
                } else {
                    // Named, not just counted — the user should see WHAT they are displacing
                    // before they press the button, not after.
                    Text(status.currentHandlerName ?? "No app").foregroundStyle(.secondary)
                    Button("Use Manifold") { status.claim() }
                        .disabled(status.isChanging)
                }
            }
        }
        if let outcome = status.lastOutcome {
            // ⚠️ ORANGE ONLY FOR A GENUINE FAILURE. That is the signal the NDI and DeckLink rows
            // use for "you can fix this", and a decline is not that — the user answered a question
            // and the machine did what they said, so it reads as ordinary secondary text. Colouring
            // both the same would put a warning next to a correctly-honoured choice.
            Text(outcome.message)
                .font(.caption)
                .foregroundStyle(outcome.isFailure ? Color.orange : Color.secondary)
        }
        if status.candidateCount > 1 {
            // "At least" is load-bearing — see `candidateCount`.
            Text("At least \(status.candidateCount) apps on this Mac can open \(status.name).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
    // Default OFF — see the declaration in `Preferences`, which also states exactly who inherits the
    // new default and who keeps their own value. Both declarations must agree: the one that renders
    // the toggle decides what an untouched key shows.
    @AppStorage("autoplayOnLoad") private var autoplayOnLoad: Bool = false
    @AppStorage(OpenDestination.defaultsKey) private var openDestination: OpenDestination = .thisWindow
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

                Picker("Open files in", selection: $openDestination) {
                    ForEach(OpenDestination.allCases) { destination in
                        Text(destination.label).tag(destination)
                    }
                }
                Text("Applies to Open… (⌘O) and the Open button. Dragging a file onto a window's picture always replaces that window, and an empty window is always re-used rather than left behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Raster size for new windows", selection: $rasterDefault) {
                    ForEach(RasterSize.settingsChoices) { size in
                        Text(size.menuTitle).tag(size)
                    }
                }
                Text("How large the picture is drawn, as a percentage of the source raster — 100% is one source pixel per source pixel, so a 3840×2160 file fills 1920×1080 points on a Retina display. Set it per window in the View menu (⌘1–⌘4, ⌘0); this is what a new window starts at, and it follows the last window you set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // ── DEFAULT APP FOR VIDEO TYPES ─────────────────────────────────────────────
                //
                // In Interface Options because this is the file-opening cluster — it sits with
                // "Autoplay on open" and "Open files in", which is where someone looks for it.
                // Built in the I/O and Runtimes idiom instead: rows reporting system state, an
                // action next to each, re-read on appear.
                //
                // ⚠️ THREE ROWS, THREE BUTTONS, THREE DECISIONS — AND NO CLAIM-ALL. Taking MXF is
                // an easy call (on a stock Mac nothing opens it well; QuickTime Player claims it
                // through public.movie and then cannot play it). Taking .mov or .mp4 is not: on a
                // working editorial machine those usually point somewhere on purpose. One control
                // that took all three would make the easy call and the contested ones with the
                // same click. Each row names its current holder so the choice is made with the
                // consequence in view.
                //
                // ⚠️ BUTTONS AND NOT TOGGLES, because there is no API to give an association BACK.
                // NSWorkspace can set a default; it cannot clear one. A checkbox that could be
                // ticked but never unticked would be describing a capability this app does not
                // have — the caption under the group says where the reverse actually lives.
                if !DefaultHandlerStatus.videoHandlers.isEmpty {
                    ForEach(DefaultHandlerStatus.videoHandlers) { handler in
                        DefaultHandlerRow(status: handler)
                    }
                    // ── ONE CAPTION FOR THE GROUP, NOT ONE PER ROW ──────────────────────────
                    // The per-row captions carry what differs (who holds the type, how many apps
                    // want it, how a claim went). This paragraph is a property of the MECHANISM
                    // and is identical for all three, so printing it three times would read as
                    // three separate warnings about three separate problems rather than one fact
                    // about how macOS file associations work.
                    Text("Manifold can take an association, but it can't hand it back — to undo one, select a file of that type in the Finder, press ⌘I, and change “Open with”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // The default handlers are system state, not ours: they can change in Finder while
            // Settings is shut, so every row is re-read on each appearance rather than cached. Same
            // reason and same shape as the I/O and Runtimes section's refresh above — and one line
            // for the whole group, which is the point of holding the instances in an array.
            .onAppear { DefaultHandlerStatus.videoHandlers.forEach { $0.refresh() } }

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
