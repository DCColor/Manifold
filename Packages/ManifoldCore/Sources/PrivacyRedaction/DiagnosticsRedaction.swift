//
//  DiagnosticsRedaction.swift
//  PrivacyRedaction — the pattern scrub a diagnostics export goes through before it is written.
//
//  Moved out of App/DiagnosticsExport.swift (where it was `DiagnosticsRedactor`) in privacy stage
//  P1, so `swift test` can run every rule against real log lines, and extended with IP addresses,
//  absolute paths, file names and display serial numbers (docs/PRIVACY_AUDIT.md).
//
//  ⚠️ IT REDACTS BY PATTERN, NOT BY PARSING, and that is deliberate: it must fire on text
//  produced by code that does not exist yet. A URL path is dropped wholesale rather than
//  inspected for whether this particular one looks secret, and `passphrase=` is blanked
//  wherever it appears in any casing.
//
//  ⚠️ LENGTH IS NOT A LEAK WE ARE WILLING TO SHIP EITHER. A redaction that preserved the
//  value's length would narrow a brute-force search, so every replacement below is a
//  FIXED-WIDTH token — `(redacted)` regardless of what it replaced.
//

import Foundation

public enum DiagnosticsRedaction {

    /// What the caller knows that a pattern cannot.
    public struct Options {
        /// Keep file names (the last component of a path, and names on their own). Off by default:
        /// the export sheet's "Include file names" checkbox turns it on. Folders are withheld
        /// either way.
        public var includeFileNames: Bool
        /// Full paths this session is known to have opened or written (media, LUTs, captions,
        /// exports, recent files). Matched LITERALLY before the generic path rule, because a
        /// pattern cannot tell where a path with spaces in it ends.
        public var knownPaths: [String]
        /// Display serial numbers, as decimal strings. Matched as whole numbers. Serials shorter
        /// than five digits are ignored: they identify nothing, and replacing every `12` in a log
        /// would destroy it.
        public var displaySerials: [String]
        /// Strings that look like something withheld and are not — the NDI runtime's version
        /// (`6.3.2.0`) is the shape of an IPv4 address. Protected verbatim.
        public var preserve: [String]
        /// Machine names to withhold wherever they appear: this Mac's own names, and the sending
        /// hosts of NDI sources (the `MACHINE` in `MACHINE (Source)`). Names shorter than three
        /// characters are ignored.
        public var hostNames: [String]

        public init(includeFileNames: Bool = false, knownPaths: [String] = [],
                    displaySerials: [String] = [], preserve: [String] = [],
                    hostNames: [String] = []) {
            self.includeFileNames = includeFileNames
            self.knownPaths = knownPaths
            self.displaySerials = displaySerials
            self.preserve = preserve
            self.hostNames = hostNames
        }
    }

    public static let pathWithheld = "(path withheld)"
    public static let fileNameWithheld = "(file name withheld)"
    public static let serialWithheld = "(serial withheld)"

    /// (pattern, replacement template, human label for the report's own audit line).
    ///
    /// ⚠️ ORDER MATTERS AND IS NOT ALPHABETICAL. Two orderings were tested against the corpus in
    /// the note below, and the first one written here LEAKED: with a generic `streamid=` rule
    /// running before the SRT `#!::` one, the generic rule's value class stopped at the first
    /// comma and left `,s=<token>` — the session credential — standing in the output. The value
    /// classes now admit commas (a streamid legitimately contains them) and `streamid=` runs
    /// first, with `#!::` behind it as the catch-all for the syntax appearing on its own.
    static let credentialRules: [(pattern: String, template: String, label: String)] = [
        // ── Credentials in query strings, whatever produced them. ──
        (#"(?i)\bpassphrase\s*[=:]\s*[^\s&"'<>;)\]]+"#, "passphrase=(redacted)", "passphrase="),
        (#"(?i)\bstream\s?id\s*[=:]\s*[^\s&"'<>;)\]]+"#, "streamid=(redacted)", "streamid="),
        // SRT's access-control syntax carries its session token as `s=`. Behind the rule above,
        // as the catch-all for a `#!::…` that appears without a `streamid=` in front of it.
        (#"#!::[^\s"']*"#, "#!::(redacted)", "SRT #!:: streamid"),
        (#"(?i)\bstream[_-]?key\s*[=:]\s*[^\s&"'<>;)\]]+"#, "stream_key=(redacted)", "stream_key="),

        // ── HTTP credential headers. SEPARATE RULES BECAUSE THE SHAPES DIFFER, and the first
        //    version of this collapsed them into one `(auth|bearer)\s*[=:]` rule that MATCHED
        //    NEITHER: "Authorization:" has more word after "auth" before the colon, and
        //    "Bearer eyJ…" is separated by a space, not by "=" or ":". Both leaked the whole
        //    JWT in testing. Header values run to end of line — they have no delimiter.
        (#"(?i)\b((?:proxy-)?authorization)\s*[=:]\s*[^\r\n]+"#, "$1: (redacted)", "Authorization header"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer (redacted)", "Bearer token"),
        (#"(?i)\b(token|secret|password|passwd|auth|api[_-]?key|access[_-]?key)\b\s*[=:]\s*[^\s&"'<>;)\]]+"#,
         "$1=(redacted)", "token/secret/password/api key"),

        // ── URL PATHS. Host and port survive (an IP host is withheld by the IP rule, later);
        //    everything after them does not. This is what stops a Cloudflare stream key reaching
        //    us in a line nobody audited.
        (#"(?i)\b(https?|srt|rtmps?|ws{1,2}s?)://([^/\s"'<>?]+)(/[^\s"'<>]*)"#,
         "$1://$2/(path withheld)", "URL paths"),
        // A URL with no path but a query is the same exposure by another route.
        (#"(?i)\b(https?|srt|rtmps?|ws{1,2}s?)://([^/\s"'<>?]+)\?[^\s"'<>]*"#,
         "$1://$2/(query withheld)", "URL query strings"),
        // A file URL is a local path in another spelling, including its file name.
        (#"(?i)\bfile://[^\s"'<>]*"#, "file://(path withheld)", "file URLs"),

        // ── Display serials asked for by name. The numbers themselves are matched literally from
        //    the attached displays (see `Options.displaySerials`); this catches a labelled one. ──
        (#"(?i)\bserial(?:\s*(?:number|no\.?|#))?\s*[=:]\s*[A-Za-z0-9-]+"#, "serial=(serial withheld)", "labelled serial numbers"),
    ]

    /// Absolute-path roots that hold only the system's own files and are KEPT, because a
    /// diagnostics report that cannot say which NDI runtime or DeckLink framework it loaded is
    /// worth much less. Nothing under these is the user's: `/Users`, `/Volumes`, `/private`,
    /// `/tmp`, `/var` and `~` are not here and are withheld.
    static let systemRoots = ["/System/", "/Library/", "/usr/", "/bin/", "/sbin/", "/dev/",
                              "/Applications/", "/opt/"]

    /// An absolute (or `~`) path: starts at a boundary — start of line, whitespace, a quote, an
    /// opening bracket, `=` or `:` — then `/name/…`. It runs to the LAST slash on the line (folder
    /// names may contain spaces), then takes the final component up to whitespace or a closing
    /// delimiter. Two slashes at least, so `w/h` and `24/1` are never paths.
    ///
    /// ⚠️ OVER-REDACTION IS THE CHOSEN FAILURE. Text between two paths on one line goes with them;
    /// a file name with a space keeps its tail after the space (the file-name rules catch that
    /// tail when it carries a media extension). Known paths are removed literally first, which is
    /// what handles a spaced path exactly.
    static let absolutePathPattern =
        #"(?:^|(?<=[\s"'(\[=:,]))(~?/[A-Za-z0-9._ -][^\n"'<>]*/)([^\s/"'<>)\],;]*)"#

    /// File names on their own, by extension: media, images, audio, LUTs, captions. A name with no
    /// space in it is caught whole; a name with spaces only by its last word (the known-path and
    /// known-name rules, which run first, catch it whole).
    static let fileNameExtensions = [
        "mov", "mp4", "m4v", "mxf", "mkv", "avi", "mts", "m2ts", "ts", "r3d", "braw", "ari", "dng",
        "exr", "dpx", "tif", "tiff", "png", "jpg", "jpeg", "heic", "wav", "aif", "aiff", "caf",
        "mp3", "m4a", "aac", "cube", "3dl", "srt", "vtt", "scc", "itt", "stl",
    ]
    static var fileNamePattern: String {
        // A "/" may precede it: after a known FOLDER is replaced literally, the file inside it
        // reads `(path withheld)/name.png`, and that name must still go (measured, P1).
        #"(?<![\w.-])[^\s/\\"'<>:()\[\],;]*[^\s/\\"'<>:()\[\],;.]\.(?i:"#
            + fileNameExtensions.joined(separator: "|") + #")(?![\w])"#
    }

    /// Returns the scrubbed text and the per-rule hit counts, so the export can state what it
    /// removed instead of asserting that it removed nothing.
    public static func redact(_ input: String, options: Options = Options())
        -> (text: String, hits: [(label: String, count: Int)]) {
        var text = input
        var hits: [(String, Int)] = []

        // ── 0. Protect what only LOOKS like something withheld. Private-use characters cannot
        //       occur in a log line, so the placeholders cannot collide. ──
        let preserved = options.preserve.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        for (i, literal) in preserved.enumerated() {
            text = text.replacingOccurrences(of: literal, with: "\u{E000}\(i)\u{E001}")
        }

        // ── 1. Credentials, URL paths, file URLs, labelled serials. ──
        for rule in credentialRules {
            let n = apply(rule.pattern, template: rule.template, to: &text)
            hits.append((rule.label, n))
        }

        // ── 2. Known full paths, literally, longest first (so a folder never pre-empts a file
        //       inside it). ──
        var pathHits = 0
        let known = Set(options.knownPaths.filter { $0.hasPrefix("/") && $0.count > 1 })
            .sorted { $0.count > $1.count }
        for path in known {
            let name = (path as NSString).lastPathComponent
            let replacement = options.includeFileNames && !name.isEmpty
                ? "\(pathWithheld)/\(name)" : pathWithheld
            let n = text.components(separatedBy: path).count - 1
            if n > 0 {
                text = text.replacingOccurrences(of: path, with: replacement)
                pathHits += n
            }
        }

        // ── 3. Every other absolute path, outside the system roots. ──
        pathHits += replaceAbsolutePaths(in: &text, keepFileName: options.includeFileNames)
        hits.append(("absolute paths (folders\(options.includeFileNames ? "" : " and file names"))", pathHits))

        // ── 4. File names, unless the export asked to keep them. Known names literally first. ──
        if !options.includeFileNames {
            var nameHits = 0
            // FILE names only — a known path with an extension. A folder's name is not one: the
            // export folder is `~/Desktop`, and withholding "Desktop" literally turned the DeckLink
            // driver's "Desktop Video 16.4.0" into "(file name withheld) Video" (measured, P1).
            let names = Set(options.knownPaths.map { ($0 as NSString).lastPathComponent }
                .filter { $0.count >= 3 && !($0 as NSString).pathExtension.isEmpty })
                .sorted { $0.count > $1.count }
            for name in names {
                let n = text.components(separatedBy: name).count - 1
                if n > 0 {
                    text = text.replacingOccurrences(of: name, with: fileNameWithheld)
                    nameHits += n
                }
            }
            nameHits += apply(fileNamePattern, template: fileNameWithheld, to: &text)
            hits.append(("file names", nameHits))
        } else {
            hits.append(("file names — KEPT (Include file names was on)", 0))
        }

        // ── 5. Display serial numbers, as whole numbers. ──
        var serialHits = 0
        for serial in Set(options.displaySerials) where serial.count >= 5 && serial.allSatisfy(\.isNumber) {
            serialHits += apply(#"(?<!\d)"# + serial + #"(?!\d)"#, template: serialWithheld, to: &text)
        }
        hits.append(("display serial numbers", serialHits))

        // ── 6. Machine names, literally and case-insensitively, longest first. ──
        var hostHits = 0
        for host in Set(options.hostNames.filter { $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            hostHits += apply(#"(?i)(?<![\w-])"# + NSRegularExpression.escapedPattern(for: host) + #"(?![\w-])"#,
                              template: NSRegularExpression.escapedTemplate(for: LogRedaction.hostWithheld),
                              to: &text)
        }
        hits.append(("machine names", hostHits))

        // ── 7. IP addresses, last: a URL host or a path can contain one, and those rules have run. ──
        var ipHits = 0
        text = LogRedaction.withholdingIPAddresses(text, count: &ipHits)
        hits.append(("IP addresses", ipHits))

        // ── 8. Put back what was protected. ──
        for (i, literal) in preserved.enumerated() {
            text = text.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: literal)
        }
        return (text, hits)
    }

    // MARK: - Helpers

    /// Applies one rule in place; returns its match count. A pattern that does not compile is
    /// reported as -1 — a rule that is not protecting anything must say so in the report rather
    /// than ship quietly without it.
    private static func apply(_ pattern: String, template: String, to text: inout String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return -1
        }
        let range = NSRange(text.startIndex..., in: text)
        let n = re.numberOfMatches(in: text, range: range)
        if n > 0 {
            text = re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        return n
    }

    private static let absolutePath = try! NSRegularExpression(pattern: absolutePathPattern,
                                                                options: [.anchorsMatchLines])

    /// The generic path rule. Done by hand rather than by template because what replaces a match
    /// depends on its root (system paths are kept) and on `keepFileName`.
    private static func replaceAbsolutePaths(in text: inout String, keepFileName: Bool) -> Int {
        let ns = text as NSString
        let matches = absolutePath.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        var count = 0
        // Back to front, so earlier ranges stay valid.
        for m in matches.reversed() {
            let whole = ns.substring(with: m.range)
            if systemRoots.contains(where: { whole.hasPrefix($0) }) { continue }
            let name = ns.substring(with: m.range(at: 2))
            let replacement = keepFileName && !name.isEmpty ? "\(pathWithheld)/\(name)" : pathWithheld
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: replacement)
            count += 1
        }
        text = out
        return count
    }
}
