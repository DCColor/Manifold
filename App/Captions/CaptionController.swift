import Foundation

/// A single subtitle cue. Times are MEDIA-ELAPSED SECONDS FROM ZERO — the same space as
/// `FrameEngine.currentTime`, so SRT timestamps map straight across with no conversion
/// (no start-timecode offset, no in-point, no rate scaling). See `cue(at:)`.
struct Cue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// External subtitle sidecar (.srt) state: the parsed cues, whether they're showing, and
/// where they came from. Deliberately NOT part of FrameEngine — captions are a view-level
/// overlay concern synced to the engine's clock, not a playback concern, so the engine
/// stays unaware of them. Owned as a @StateObject by ContentView (one per window, like the
/// scope models), not a singleton: there's no device/stream lifecycle here to share.
///
/// Main-thread only (SwiftUI observes it). Everything here is cheap and synchronous —
/// parsing is a string walk over a file that is realistically kilobytes — so there's no
/// off-main work to hop back from and no @MainActor annotation, matching NDIService /
/// DeckLinkService house style.
final class CaptionController: ObservableObject {

    /// Parsed cues, sorted by start time. Empty until a successful load.
    @Published private(set) var cues: [Cue] = []
    /// True once a file has parsed to at least one cue. A parse yielding zero cues is a
    /// FAILURE and leaves this false (see `load`).
    @Published private(set) var isLoaded = false
    /// The Aa toggle. Set true on successful load so a freshly loaded file shows at once.
    @Published var enabled = false
    /// The .srt the cues came from — informational; nothing reloads from it.
    @Published private(set) var sourceURL: URL?

    // MARK: - Lifecycle

    /// Parse `url` and adopt its cues. On any failure (unreadable file, or a parse yielding
    /// zero cues) the previous state is left UNTOUCHED and the reason is logged: there is no
    /// alert surface anywhere in this app, and silently blanking a working caption track
    /// because the user picked a bad file would be worse than doing nothing.
    func load(_ url: URL) {
        // Two separate attempts, not `try? (utf8 ?? latin1)` — the first operand throws rather
        // than returning nil, so a coalesce there would make the fallback dead code. Latin-1
        // can't fail, which is the point: it's the last-resort decode for legacy .srt files.
        guard let raw = (try? String(contentsOf: url, encoding: .utf8))
                     ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            print("[CAPTIONS] unreadable file — \(url.lastPathComponent)")
            return
        }
        let parsed = Self.parse(raw)
        guard !parsed.isEmpty else {
            print("[CAPTIONS] no cues parsed from \(url.lastPathComponent) — not an SRT, or malformed")
            return
        }
        cues = parsed
        sourceURL = url
        isLoaded = true
        enabled = true
    }

    /// Drop everything. Called when a new media file opens — an SRT is a sidecar to one
    /// specific file, so carrying it onto the next one would show wrong text confidently.
    func clear() {
        guard isLoaded || !cues.isEmpty || sourceURL != nil else { return }
        cues = []
        isLoaded = false
        enabled = false
        sourceURL = nil
    }

    // MARK: - Lookup

    /// Text of the cue covering `t`, or nil if none. Half-open interval [start, end) so a
    /// cue ending exactly where the next begins doesn't briefly render both.
    ///
    /// Linear scan: SRT files are small and this runs at the engine's 10 Hz observer rate,
    /// so the scan is far below noise. Correctness over cleverness — a hint index would need
    /// to be mutated from inside a view body evaluation, which is a side effect this doesn't
    /// need to take on.
    func cue(at t: Double) -> String? {
        for c in cues {
            if t < c.start { break }        // sorted by start — nothing later can match
            if t < c.end { return c.text }
        }
        return nil
    }

    // MARK: - Parsing

    /// SRT → cues. Tolerates a BOM, CRLF/CR line endings, '.' or ',' as the millisecond
    /// separator, a missing index line, and HH:MM:SS or MM:SS timestamps. Returns [] on
    /// anything it can't make cues out of; the caller decides that's a failure.
    static func parse(_ raw: String) -> [Cue] {
        var body = raw.replacingOccurrences(of: "\r\n", with: "\n")
                      .replacingOccurrences(of: "\r", with: "\n")
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }

        var cues: [Cue] = []
        var block: [String] = []

        func flush() {
            defer { block = [] }
            // A block is: [optional index], timing, text… — so find the timing line rather
            // than assuming it's at a fixed offset. Everything after it is the text.
            guard let i = block.firstIndex(where: { $0.contains("-->") }) else { return }
            let bounds = block[i].components(separatedBy: "-->")
            guard bounds.count == 2,
                  let start = seconds(from: bounds[0]),
                  let end = seconds(from: bounds[1]) else { return }
            let text = block[(i + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, end > start else { return }
            cues.append(Cue(start: start, end: end, text: stripTags(text)))
        }

        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else { block.append(line) }
        }
        flush()   // last block may not be followed by a blank line

        return cues.sorted { $0.start < $1.start }
    }

    /// "HH:MM:SS,mmm" (or MM:SS, or '.' as separator) → seconds. Trailing junk on the end
    /// timestamp — SRT position coordinates like "X1:0 X2:640" — is ignored.
    private static func seconds(from field: String) -> Double? {
        let token = field.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: " ").first.map(String.init) ?? ""
        let parts = token.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let nums = parts.compactMap { Double($0) }
        guard nums.count == parts.count else { return nil }
        return nums.count == 3
            ? nums[0] * 3600 + nums[1] * 60 + nums[2]
            : nums[0] * 60 + nums[1]
    }

    /// Strip the handful of inline tags SRT files carry (<i>, </b>, <font color="…">).
    /// Not a sanitizer and not a renderer — we draw one default style, so a tag we'd only
    /// ignore is better removed than shown as literal text.
    /// Matches only a complete <…> pair, so dialogue containing a bare "<" or ">" ("5 > 3")
    /// survives untouched.
    private static func stripTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        return s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
