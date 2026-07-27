//
//  DiagnosticsExport.swift
//  Manifold
//
//  Manifold ▸ Export Diagnostics… — one plain .txt a tester can email us.
//
//  ── THE PROBLEM THIS SOLVES ────────────────────────────────────────────────────────────
//
//  Every diagnostic Manifold produces goes to NSLog or print(), which means the only way to
//  read it is Xcode. Testers do not have Xcode. Until this file existed, a tester reporting
//  "it went black after a few minutes" could send us nothing at all, and we could ask for
//  nothing that would help.
//
//  ── WHY THE LOG IS CAPTURED BY TAPPING FILE DESCRIPTORS ────────────────────────────────
//
//  The obvious alternative — read our own entries back out of the unified log via
//  OSLogStore — WAS TRIED AND MEASURED, AND IT DOES NOT WORK. `OSLogStore(scope:
//  .currentProcessIdentifier)` opens without any entitlement, so that part of the worry is
//  unfounded; the fatal part is what it returns. NSLog routes through Foundation, which
//  marks the composed message PRIVATE, so every one of our ~240 NSLog lines reads back as
//  the literal string "<private>" unless the reading process holds
//  com.apple.private.logging.read-private-data — an Apple-internal entitlement. Measured on
//  both a format-argument NSLog and a bare literal one; both redacted. And print() never
//  reaches the unified log at all, which would silently drop another ~59 sites including
//  every [EDR] line.
//
//  So the capture happens one level down, at the file descriptors those calls already write
//  to: dup2 a pipe over fd 1 and fd 2, drain it on one thread, tee it back to the saved
//  originals so Xcode still shows everything. NO CALL SITE IS EDITED — which is the whole
//  point, at ~299 of them — and it also catches libsrt, libdatachannel and libavformat
//  writing to stderr, which nothing on the Swift side could have reached.
//
//  ⚠️ THE setvbuf CALL IS LOAD-BEARING, NOT TIDINESS. stdout is BLOCK-buffered whenever it
//  is not a tty, and a bundled app launched from Finder never has one. Measured: without it,
//  print() output sits in libc's 4 KB buffer and never reaches the pipe at all — the first
//  version of this tap captured NSLog perfectly and silently lost every print().
//
//  ── WHAT A RELEASE BUILD ACTUALLY CAPTURES ─────────────────────────────────────────────
//
//  Measured by diffing log tags between the Debug dylib and the Release binary. Release
//  KEEPS the whole connection lifecycle: [BUILD], [SRT], [WHEP], [WHEP-RTP], [NDI],
//  [STREAMS], [EDR], part of [LIVECLOCK], and the decoder's keyframe/format/decode-error
//  lines. Release LOSES the per-second rollups behind `#if DEBUG || MANIFOLD_TELEMETRY`:
//  [SRT-FLOW], [WHEP-FLOW], the decode-rate tick, and the depth/jitter/underrun telemetry.
//
//  That is enough to diagnose "won't connect", "connects then black", "drops after N
//  minutes" and "wrong colour" — the things testers actually report. It is NOT enough to
//  diagnose "smooth here, judders there", which lives entirely in the gated lines. The
//  export states which configuration produced it, so we always know which we are reading.
//
//  ── THE SECRETS RULE ───────────────────────────────────────────────────────────────────
//
//  See `DiagnosticsRedactor`. The short version: the source audit says the log is clean
//  today, and the redactor assumes it will not stay that way.
//

import AppKit
import Combine
import Foundation
import ManifoldCore   // ManifoldCoreBuild — the package reporting its OWN telemetry state
import SwiftUI

// MARK: - Line formatting

/// Strips the logging envelope off a captured line, leaving a short local time and the message.
///
/// ── WHY A CAPTURED LINE HAS AN ENVELOPE AT ALL ─────────────────────────────────────────
///
/// `NSLog` and `os_log` write a framed record to stderr, not the bare message. Which framing
/// depends on how the process was launched, and BOTH are seen in the field:
///
///   LEGACY   2026-07-27 16:03:16.634 Manifold[64312:12748325] [NDI] runtime loaded: …
///   OS_LOG   OSLOG-D300AE4E-…-A58A8322CC14 7 80 L 9 {t:1785182379.896387,offset:0xaaf4}<TAB>[NDI] …
///
/// The second is os_log's RAW RECORD ENCODING — the same bytes Xcode's console decodes before
/// it shows you a tidy line. It carries an image UUID, record indices, a mach offset and, on
/// some records, imgPath — 88 characters of framing on the shortest example seen, more on
/// longer ones, wrapped around a 45-character message. Left in place it buries the content AND
/// spends the capture budget on the same UUID thousands of times over.
///
/// ⚠️ THIS RUNS AT CAPTURE TIME, NOT AT EXPORT TIME, and that is the point rather than an
/// optimisation: framing that is stripped before it reaches the ring buffer never consumed the
/// budget in the first place. Stripping at export would have produced a readable file that
/// still held only a third of the history.
///
/// ⚠️ IT NEVER DISCARDS CONTENT IT DID NOT UNDERSTAND. Both formats are undocumented and can
/// change under us, so every branch that fails to parse returns the line UNCHANGED. The failure
/// mode is an ugly line in the report, never a missing one.
enum LogLineFormatter {

    /// Width of the rendered time column, including its trailing gap. Continuation lines are
    /// padded to it so the messages stay aligned down the page.
    private static let timeColumn = "HH:mm:ss.SSS  ".count

    static func clean(_ raw: String) -> String {
        if raw.isEmpty { return raw }

        // ── os_log raw record. Everything before the first TAB is envelope. ──
        if raw.hasPrefix("OSLOG-") {
            guard let tab = raw.firstIndex(of: "\t") else { return raw }   // unparsed → verbatim
            let envelope = raw[raw.startIndex..<tab]
            let message = String(raw[raw.index(after: tab)...])
            return render(time: unixTime(in: envelope), message: message)
        }

        // ── Legacy NSLog: "YYYY-MM-DD HH:MM:SS.mmm Name[pid:tid] message". ──
        // Validated by shape before it is trusted, so a message that merely happens to start
        // with digits is not mistaken for a header and truncated.
        let chars = Array(raw.utf16)
        if chars.count > 24,
           isDigit(chars[0]), isDigit(chars[1]), isDigit(chars[2]), isDigit(chars[3]),
           chars[4] == UInt16(UnicodeScalar("-").value),
           chars[7] == UInt16(UnicodeScalar("-").value),
           chars[10] == UInt16(UnicodeScalar(" ").value),
           let bracket = raw.range(of: "["),
           let close = raw.range(of: "] ", range: bracket.upperBound..<raw.endIndex) {
            // The clock is already local and already formatted — take the HH:MM:SS.mmm slice
            // rather than reparsing a date we would only reformat identically.
            let start = raw.index(raw.startIndex, offsetBy: 11)
            let end = raw.index(raw.startIndex, offsetBy: 23)
            let time = String(raw[start..<end])
            let message = String(raw[close.upperBound...])
            return render(time: time, message: message)
        }

        // ── Anything else: print(), fputs, a C library writing to stderr. No envelope, so no
        //    timestamp exists to show. See `render` for why the column is blanked and not faked.
        return render(time: nil, message: raw)
    }

    private static func isDigit(_ u: UInt16) -> Bool { u >= 48 && u <= 57 }

    /// Pull `{t:<unix seconds>.<fraction>` out of an os_log envelope and format it as local
    /// HH:mm:ss.SSS. `localtime_r` rather than `DateFormatter`: this runs on the tap thread for
    /// every line, and DateFormatter is neither cheap nor thread-safe.
    private static func unixTime(in envelope: Substring) -> String? {
        guard let marker = envelope.range(of: "{t:") else { return nil }
        let rest = envelope[marker.upperBound...]
        let digits = rest.prefix { $0.isNumber || $0 == "." }
        guard let seconds = Double(digits), seconds > 0 else { return nil }
        var t = time_t(seconds)
        var tm = tm()
        guard localtime_r(&t, &tm) != nil else { return nil }
        let millis = Int((seconds - seconds.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", tm.tm_hour, tm.tm_min, tm.tm_sec, millis)
    }

    /// ⚠️ A LINE WITH NO TIMESTAMP GETS A BLANK COLUMN, NOT THE PREVIOUS LINE'S TIME.
    ///
    /// The alternative — carrying the last seen timestamp forward — reads better and is a small
    /// lie: it prints a time that was never measured for that line, and a reader correlating a
    /// tester's report against these timings has no way to tell a carried value from a real one.
    /// Blank keeps the column alignment (so the line still visibly belongs with the one above)
    /// while asserting nothing. print() and C-library stderr output genuinely have no timestamp;
    /// saying so is free.
    private static func render(time: String?, message: String) -> String {
        guard let time else { return String(repeating: " ", count: timeColumn) + message }
        return time + "  " + message
    }
}

// MARK: - The capture

/// Bounded in-memory copy of everything the process writes to stdout and stderr, from launch,
/// with each line's logging envelope stripped as it arrives (see `LogLineFormatter`).
///
/// ── THE BOUND, AND WHAT HAPPENS AT THE BOUND ───────────────────────────────────────────
///
/// 4 MB total, split into a HEAD and a TAIL rather than kept as one ring, and the split is the
/// whole design rather than a refinement:
///
///   * HEAD — the first 128 KB, captured once and NEVER evicted. The `[BUILD]` banner, the
///     startup device enumeration and the connection handshake are the FIRST things logged and
///     among the most valuable, so a plain ring buffer would evict precisely the lines the
///     export is required to contain. A long session would produce a diagnostics file with no
///     build identity in it at all.
///   * TAIL — the last ~3.9 MB, a ring over whole lines. What the user was doing when it broke.
///
/// ⚠️ THE HEAD WAS 512 KB AND IS NOW 128 KB, because stripping the envelope changed the
/// arithmetic. Measured against a real launch, a cleaned line averages ~91 characters, so
/// 128 KB is ~1,400 lines — five to ten times more than any startup sequence this app produces,
/// where before 512 KB reserved ~5,600 lines for the same job and spent an eighth of the budget
/// doing it. The SPLIT still earns its place; its old proportions did not.
///
/// When the tail wraps it drops whole lines from its oldest end and COUNTS them, and the export
/// prints a marker between the two sections naming how many lines and bytes went. Truncation is
/// stated in the file, never silent — a gap a reader cannot see is worse than a smaller log.
final class LogTap {
    static let shared = LogTap()

    /// The wrap marker, recognised again at export time so it stays with our own log rather
    /// than being classified as system output. Spelled once.
    static let dropMarkerPrefix = "─── "

    private static let headLimit = 128 * 1024
    private static let tailLimit = 3_968 * 1024
    /// How far the head may overshoot `headLimit` to finish the line it is in the middle of.
    /// Bounded so a pathological single line cannot make the head unbounded.
    private static let headOvershoot = 64 * 1024

    private let lock = NSLock()
    private var head = Data()
    private var tail = Data()
    private var droppedBytes = 0
    private var droppedLines = 0
    private var installed = false
    /// Bytes read since the last newline. A pipe read returns whatever happened to be in the
    /// pipe, which does NOT align to lines — so the envelope stripper, which only makes sense on
    /// a whole line, is fed from here rather than from the raw chunk.
    private var partial = Data()
    /// Ceiling on `partial`, so a stream that never emits a newline (a progress bar writing \r,
    /// a wedged library) cannot grow it without bound. On overflow it is flushed as-is.
    private static let partialLimit = 256 * 1024

    private init() {}

    /// Install the tap. MUST be called before anything else logs — the head section is only
    /// worth reserving if it actually contains the first lines. Idempotent.
    func install() {
        lock.lock()
        guard !installed else { lock.unlock(); return }
        installed = true
        lock.unlock()

        // See the file header: without this, print() is invisible to the tap.
        setvbuf(stdout, nil, _IOLBF, 0)

        // ONE PIPE FOR BOTH DESCRIPTORS, not one each. Two pipes means two reader threads
        // appending to one buffer, and the interleaving of stdout against stderr then depends on
        // thread scheduling — measured, and it does reorder lines. With a single pipe the kernel
        // serialises the writes and the captured order is the order they happened, which is what
        // makes a log readable as a sequence of events.
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        let readEnd = fds[0], writeEnd = fds[1]

        // Saved so the tee can put everything back where it was going. In a bundled app these
        // are usually /dev/null, and writing to them is then a no-op — but under Xcode or a
        // terminal they are the console, and losing that would make this file a debugging
        // regression for us in exchange for a feature for testers.
        let savedOut = dup(1), savedErr = dup(2)
        dup2(writeEnd, 1)
        dup2(writeEnd, 2)
        close(writeEnd)

        let thread = Thread { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(readEnd, &chunk, chunk.count)
                if n <= 0 { break }
                // TEE THE RAW BYTES, unmodified, BEFORE any parsing. What Xcode and the terminal
                // show must be exactly what they showed before this file existed — the envelope
                // stripping is for the tester's report, not a change to how we debug.
                _ = chunk.withUnsafeBytes { write(savedErr, $0.baseAddress, n) }
                self?.ingest(chunk, count: n)
            }
            _ = savedOut   // kept alive with savedErr; see the tee note above
        }
        thread.name = "com.manifold.logtap"
        // Below the transports and the render thread on purpose: draining a pipe must never
        // compete with decode. If this thread falls behind, the pipe fills and the WRITER
        // blocks — which is the one way a log tap can affect playback — so it is sized to keep
        // up (8 KB reads against a 64 KB pipe) and left at utility priority.
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Reassemble whole lines out of an arbitrary pipe chunk, strip each one's envelope, and
    /// hand the result to the bounded buffer. Runs on the tap thread only.
    private func ingest(_ bytes: [UInt8], count: Int) {
        lock.lock()
        partial.append(contentsOf: bytes[0..<count])
        // Flush an over-long unterminated run rather than growing forever. Rare enough that the
        // formatter's pass-through branch handles the result correctly by itself.
        let forced = partial.count > Self.partialLimit
        var complete: [Data] = []
        while let nl = partial.firstIndex(of: 0x0A) {
            complete.append(partial[partial.startIndex..<nl])
            partial.removeSubrange(partial.startIndex...nl)
        }
        if forced, !partial.isEmpty {
            complete.append(partial)
            partial.removeAll(keepingCapacity: true)
        }
        lock.unlock()

        guard !complete.isEmpty else { return }
        var out = ""
        for line in complete {
            out += LogLineFormatter.clean(String(decoding: line, as: UTF8.self))
            out += "\n"
        }
        let encoded = [UInt8](out.utf8)
        append(encoded, count: encoded.count)
    }

    private func append(_ bytes: [UInt8], count: Int) {
        lock.lock()
        defer { lock.unlock() }

        var slice = bytes[0..<count]

        // Fill the head first, then everything else goes to the tail.
        //
        // ⚠️ THE HEAD ENDS ON A NEWLINE, NOT ON THE BYTE LIMIT. The first version cut at exactly
        // `headLimit` and split whatever line straddled it — measured: the head ended
        // "…log content padd" and the rest of that line went into the tail, where it was later
        // evicted. So the export's most-read section ended in a truncated sentence, and the
        // retained + dropped line counts did not balance. The cut is now extended to the next
        // newline (bounded by `headOvershoot`), which is the same whole-line discipline the tail
        // wrap already had.
        if head.count < Self.headLimit {
            let room = Self.headLimit - head.count
            var take = min(room, slice.count)
            if take < slice.count {
                let from = slice.startIndex + take
                let to = min(from + Self.headOvershoot, slice.endIndex)
                if let nl = slice[from..<to].firstIndex(of: 0x0A) {
                    take = slice.distance(from: slice.startIndex, to: nl) + 1
                }
            }
            head.append(contentsOf: slice[slice.startIndex..<(slice.startIndex + take)])
            slice = slice[(slice.startIndex + take)...]
            if slice.isEmpty { return }
        }

        tail.append(contentsOf: slice)
        guard tail.count > Self.tailLimit else { return }

        // WRAP: drop from the front, but only ever at a newline, so the file never opens on
        // half a line. Scan forward from the raw cut point to the next \n.
        let overflow = tail.count - Self.tailLimit
        var cut = overflow
        if let nl = tail[tail.startIndex.advanced(by: overflow)...].firstIndex(of: 0x0A) {
            cut = tail.distance(from: tail.startIndex, to: nl) + 1
        }
        cut = min(cut, tail.count)
        droppedLines += tail[tail.startIndex..<tail.startIndex.advanced(by: cut)]
            .reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        droppedBytes += cut
        tail.removeFirst(cut)
    }

    /// The captured log, head then tail, with the wrap stated between them if one happened.
    func snapshot() -> String {
        lock.lock()
        let h = String(decoding: head, as: UTF8.self)
        let t = String(decoding: tail, as: UTF8.self)
        // The line still being written when the export was taken. Included rather than dropped —
        // if the app is about to misbehave, the half-written line is the interesting one.
        let openLine = partial.isEmpty ? ""
            : LogLineFormatter.clean(String(decoding: partial, as: UTF8.self)) + "\n"
        let bytes = droppedBytes, lines = droppedLines
        let live = installed
        lock.unlock()

        guard live else {
            return "[ the log tap was never installed — this build captured nothing. "
                 + "This is a bug; please report it. ]"
        }
        guard bytes > 0 else { return h + t + openLine }
        return h
            + "\n\(Self.dropMarkerPrefix)\(lines) line(s), \(bytes) bytes DROPPED HERE — the "
            + "session outran the 4 MB capture bound. The oldest middle of the log went; the "
            + "start above and the end below are intact. ───\n\n"
            + t + openLine
    }
}

// MARK: - Ours vs. the system

/// Splits the captured stream into Manifold's own output and framework chatter.
///
/// ── THE PROBLEM ────────────────────────────────────────────────────────────────────────
///
/// The tap captures a FILE DESCRIPTOR, so by construction everything in it came from OUR
/// PROCESS — but not from our CODE. CoreFoundation plugin errors, libsqlite3 complaints,
/// ViewBridge, AudioAnalytics and the Network framework all write to our stderr, and
/// interleaved with the transport log they bury it.
///
/// ── HOW THE TWO ARE TOLD APART, AND WHY IT IS THIS WAY ROUND ───────────────────────────
///
/// Three tests, in order:
///
///   1. Does the message open with a tag from `manifoldTags` or a prefix from
///      `manifoldPrefixes`? → OURS. Both lists were generated by grepping every `NSLog`/`print`
///      format string in App/ and Packages/, not written from memory, so they match what the
///      code actually emits (including the untagged ones — "DeckLink:", "FrameEngine:",
///      "AudioTap[", "HDR10 [").
///   2. Otherwise, does it match a known system-noise signature? → SYSTEM.
///   3. Otherwise → OURS.
///
/// ⚠️ RULE 3 IS THE WHOLE DESIGN. The default is OURS, and the system list is the exception —
/// not the other way round. A tag allowlist with "everything else is system" would quietly
/// swallow the next log line somebody adds without a tag, and a diagnostics report that hides
/// our own output is worse than useless: it is misleading, because the section header claims
/// completeness. With this polarity the worst case is a system message appearing among ours —
/// visible, harmless, and fixable by adding one signature.
///
/// Rule 1 runs BEFORE rule 2 so a tagged line is never diverted by a noise keyword that happens
/// to appear inside it (`[SRT] nw_connection …` is ours, whatever `nw_` usually means).
enum LogPartitioner {

    /// Every bracket tag emitted anywhere in App/ or Packages/, plus the two supplied at runtime
    /// through `LiveVideoDecoder(logTag:)`. Regenerate with:
    ///   grep -rhoE '@?"\s*\[[A-Za-z0-9_-]+\]' --include=*.swift --include=*.m --include=*.c App Packages
    private static let manifoldTags: Set<String> = [
        "ABOUT", "BUILD", "CAPTIONS", "CSDEBUG", "CSPROBE", "DIAG", "EDR", "EXPORT", "LICENSE",
        "LIVECLOCK", "NDI", "Play", "RENDER-PERF", "SRT", "SRT-AU", "SRT-BACKLOG", "SRT-DECODE",
        "SRT-FLOW", "SRT-JITTER", "SRT-LIB", "SRT-UNDERRUN", "STREAM", "STREAMS", "SWEEP",
        "SWEEP-SUMMARY", "SYNTH-PERF", "ScopeSeek", "SyntheticLive", "WEBRTC", "WEBRTC-SMOKE",
        "WHEP", "WHEP-BRIDGE", "WHEP-DECODE", "WHEP-FLOW", "WHEP-RTP",
    ]

    /// Our log lines that carry no bracket tag at all. These are exactly why rule 3 defaults to
    /// ours: they existed before any tag convention and nothing forces a new one to adopt it.
    private static let manifoldPrefixes = [
        "DeckLink", "FrameEngine", "AudioTap[", "HDR10 [", "LibavThumbnailSource",
        "MetalVideoRenderer", "Edit in Flip", "ScopeCompute", "LiveClock",
    ]

    /// Framework noise. An ALLOWLIST OF THINGS TO MOVE ASIDE, deliberately not exhaustive —
    /// anything unrecognised stays with our log, so a gap here costs tidiness and never content.
    private static let systemSignatures = [
        "CFBundle", "CoreFoundation", "Cannot find executable", "not valid for use in process",
        "libsqlite3", "BUG IN CLIENT OF", "ViewBridge", "NSViewService", "ViewService",
        "AudioAnalytics", "HALC_", "HALPlugIn", "AudioObject", "AQMEIO", "CADefaultDevice",
        "nw_connection", "nw_endpoint", "nw_path", "nw_socket", "nw_protocol", "boringssl",
        "quic_", "tcp_connection", "Connection has no local endpoint",
        "IMKClient", "IMKInputSession", "TSMSendMessage", "HIToolbox",
        "CFPrefs", "CFPreferences", "kCFPreferences", "Couldn't read values in CFPrefsPlistSource",
        "objc[", "dyld[", "class is implemented in both",
        "+[CATransaction synchronize]", "CGSWindow", "SkyLight", "WindowServer",
        "XPC connection", "xpc_", "Sandbox: ", "deny(1)",
        "NSBundle", "Failed to get bundle", "AddInstanceForFactory", "Unable to open mach-O",
        "MessageTracer", "os_unix.c", "cannot open file at line",
    ]

    /// (our log, system messages). Blank lines follow the section they were written into so the
    /// original spacing survives in whichever half a reader is looking at.
    static func partition(_ text: String) -> (ours: String, system: String) {
        var ours: [Substring] = []
        var system: [Substring] = []
        var lastWasOurs = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                (lastWasOurs ? { ours.append(line) } : { system.append(line) })()
                continue
            }
            let mine = isOurs(line)
            lastWasOurs = mine
            if mine { ours.append(line) } else { system.append(line) }
        }
        return (ours.joined(separator: "\n"), system.joined(separator: "\n"))
    }

    private static func isOurs(_ line: Substring) -> Bool {
        // The rendered time column is fixed-width; skip it to reach the message.
        let message = line.drop { $0 == " " || $0.isNumber || $0 == ":" || $0 == "." }
        // The wrap marker is ours — it is our own annotation about our own buffer.
        if message.hasPrefix(LogTap.dropMarkerPrefix) || line.contains(LogTap.dropMarkerPrefix) {
            return true
        }
        // 1. A known tag.
        if message.hasPrefix("["), let close = message.firstIndex(of: "]") {
            let tag = String(message[message.index(after: message.startIndex)..<close])
            if manifoldTags.contains(tag) { return true }
        }
        // 1b. A known untagged prefix.
        for prefix in manifoldPrefixes where message.hasPrefix(prefix) { return true }
        // 2. Recognised framework noise.
        for signature in systemSignatures where line.contains(signature) { return false }
        // 3. Default: ours. See the note on this type.
        return true
    }
}

// MARK: - The secrets rule

/// Strips credentials from the captured text before it is written to disk.
///
/// ── WHY THIS EXISTS EVEN THOUGH THE SOURCE AUDIT CAME BACK CLEAN ───────────────────────
///
/// Auditing what is logged TODAY is necessary and not sufficient, because the file that gets
/// written is whatever the process happened to print — including from a log line somebody adds
/// next month without thinking about it. So there are two layers, and this is the second:
///
///   LAYER 1, the source audit. Every site that touches a secret already withholds it, and I
///   read each one rather than trusting the convention:
///     * SRTSession.m:633 — "passphrase set (value withheld)". The C struct's copy is
///       memset to zero immediately after srt_setsockflag, so from that point there is no
///       plaintext in the process to print. NO LENGTH IS LOGGED ANYWHERE — grepped for it
///       specifically, because "10–79 characters" appears in user-facing VALIDATION text and
///       that is a statement of SRT's rule, never a measurement of what was typed.
///     * SRTClient.swift:494 — "a passphrase was supplied (value withheld)".
///     * WHEPClient.swift:168 — "endpoint host %@ (path withheld — it carries the stream key)".
///       The Cloudflare path is never printed. The WHEP resource from the Location header is
///       likewise announced without its value (line 539).
///     * SRTClient.swift:497 — the streamid goes through `redactedStreamId`, which blanks the
///       `s=` token of SRT's `#!::` access-control syntax.
///     * SRTClient.swift:501 — logs the NAMES of ignored URL parameters, never their values.
///
///   LAYER 2, this. Pattern-matched over the whole assembled document — captured log, machine
///   context AND the tester's own free-text answers, because "what were you doing" is exactly
///   where someone pastes the URL they were connecting to.
///
/// ⚠️ IT REDACTS BY PATTERN, NOT BY PARSING, and that is deliberate: it must fire on text
/// produced by code that does not exist yet. A URL path is dropped wholesale rather than
/// inspected for whether this particular one looks secret, and `passphrase=` is blanked
/// wherever it appears in any casing.
///
/// ⚠️ LENGTH IS NOT A LEAK WE ARE WILLING TO SHIP EITHER. A redaction that preserved the
/// value's length would narrow a brute-force search, so every replacement below is a
/// FIXED-WIDTH token — `(redacted)` regardless of what it replaced.
enum DiagnosticsRedactor {

    /// (pattern, replacement template, human label for the report's own audit line).
    ///
    /// ⚠️ ORDER MATTERS AND IS NOT ALPHABETICAL. Two orderings were tested against the corpus in
    /// the note below, and the first one written here LEAKED: with a generic `streamid=` rule
    /// running before the SRT `#!::` one, the generic rule's value class stopped at the first
    /// comma and left `,s=<token>` — the session credential — standing in the output. The value
    /// classes now admit commas (a streamid legitimately contains them) and `streamid=` runs
    /// first, with `#!::` behind it as the catch-all for the syntax appearing on its own.
    private static let rules: [(pattern: String, template: String, label: String)] = [
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

        // ── URL PATHS. Host and port survive; everything after them does not. This is the
        //    existing "path withheld" convention applied to text rather than to one call site,
        //    and it is what stops a Cloudflare stream key reaching us in a line nobody audited.
        (#"(?i)\b(https?|srt|rtmps?|ws{1,2}s?)://([^/\s"'<>?]+)(/[^\s"'<>]*)"#,
         "$1://$2/(path withheld)", "URL paths"),
        // A URL with no path but a query is the same exposure by another route.
        (#"(?i)\b(https?|srt|rtmps?|ws{1,2}s?)://([^/\s"'<>?]+)\?[^\s"'<>]*"#,
         "$1://$2/(query withheld)", "URL query strings"),

        // ── Not a credential, but not ours to send either: the tester's account name, which
        //    appears in any absolute path we log (still exports, opened files). ──
        (#"/Users/[^/\s"':]+"#, "/Users/(user)", "home directory paths"),
    ]

    /// Returns the scrubbed text and the per-rule hit counts, so the export can state what it
    /// removed instead of asserting that it removed nothing.
    static func redact(_ input: String) -> (text: String, hits: [(label: String, count: Int)]) {
        var text = input
        var hits: [(String, Int)] = []
        for rule in rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern) else {
                // A rule that does not compile is a rule that is not protecting anything, and
                // shipping quietly without it is the failure mode this branch exists to prevent.
                NSLog("[DIAG] ⚠️ redaction rule failed to compile: %@", rule.label)
                hits.append(("\(rule.label) — RULE FAILED TO COMPILE", -1))
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            let count = re.numberOfMatches(in: text, range: range)
            if count > 0 {
                text = re.stringByReplacingMatches(in: text, range: range,
                                                   withTemplate: rule.template)
            }
            hits.append((rule.label, count))
        }
        return (text, hits)
    }
}

// MARK: - Machine context

enum MachineContext {
    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// ⚠️ MODEL AND CHIP, NEVER THE SERIAL NUMBER OR THE MACHINE'S NAME. `hw.model` is a model
    /// identifier shared by every unit of that model; the serial and the user-set computer name
    /// identify a person and are not needed to interpret a frame-rate spread.
    @MainActor
    static func lines() -> [String] {
        var out: [String] = []
        let p = ProcessInfo.processInfo
        out.append("macOS            : \(p.operatingSystemVersionString)")
        out.append("Hardware model   : \(sysctl("hw.model") ?? "?")")
        out.append("CPU              : \(sysctl("machdep.cpu.brand_string") ?? "?")")
        out.append("Cores            : \(p.processorCount) (\(p.activeProcessorCount) active)")
        out.append(String(format: "Physical memory  : %.1f GB",
                          Double(p.physicalMemory) / 1_073_741_824))
        out.append("Uptime           : \(Int(p.systemUptime)) s")

        out.append("")
        out.append("Displays:")
        for (i, screen) in NSScreen.screens.enumerated() {
            let f = screen.frame
            let profile = screen.colorSpace?.localizedName ?? "no colour profile"
            out.append(String(format: "  [%d] %@ — %.0fx%.0f @%.0fx", i, screen.localizedName,
                              f.width, f.height, screen.backingScaleFactor))
            out.append("      colour profile: \(profile)")
            out.append(String(format: "      EDR headroom: current=%.3f potential=%.3f reference=%.3f",
                              screen.maximumExtendedDynamicRangeColorComponentValue,
                              screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                              screen.maximumReferenceExtendedDynamicRangeColorComponentValue))
        }

        out.append("")
        let deckLink = DeckLinkService.shared
        out.append("DeckLink driver  : \(deckLink.driverInstalled ? "installed" : "NOT installed")")
        let devices = deckLink.devices
        if devices.isEmpty {
            out.append("DeckLink devices : none enumerated")
        } else {
            out.append("DeckLink devices : \(devices.count)")
            out.append("DeckLink output  : \(deckLink.isOutputting ? "active" : "idle") — \(deckLink.signalLine)")
        }

        let ndi = NDIService.shared
        out.append("NDI runtime      : \(ndi.runtimeAvailable ? "installed" : "NOT installed")"
                 + (ndi.runtimeVersion.map { " (\($0))" } ?? ""))
        out.append("NDI sources seen : \(ndi.discoveredSources.count)")
        return out
    }
}

// MARK: - The report

/// The tester's answers to the three questions. Without these we get numbers and no way to
/// interpret their spread, which is the entire point of a tester round: a 400 ms depth reading
/// means one thing on wifi three time zones away and another on wired ethernet in the next room.
struct DiagnosticsContext {
    enum Connection: String, CaseIterable, Identifiable {
        case wired = "Wired (ethernet)"
        case wifi = "Wi-Fi"
        case other = "Other / not sure"
        var id: String { rawValue }
    }
    /// ⚠️ OPTIONAL, AND IT STARTS nil ON PURPOSE. This defaulted to `.wifi`, which was the worst
    /// available choice: connection type is the single biggest determinant of the latency and
    /// cushion numbers in the report, testers leave defaults alone, and a pre-selected answer is
    /// indistinguishable in the file from one somebody actually gave. Every wired tester would
    /// have been silently recorded as Wi-Fi and their numbers misread. nil until chosen; Export
    /// is disabled until it is not nil.
    var connection: Connection?
    /// City or region. Coarse ON PURPOSE — this is for interpreting latency, and the prompt says
    /// so to the tester rather than collecting something more precise and explaining later.
    var location: String = ""
    var activity: String = ""
}

@MainActor
enum DiagnosticsReport {

    static func build(context: DiagnosticsContext) -> String {
        var out = ""
        func section(_ title: String) {
            out += "\n" + String(repeating: "=", count: 78) + "\n\(title)\n"
                 + String(repeating: "=", count: 78) + "\n"
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        out += "Manifold diagnostics\n"
        out += "Generated        : \(ISO8601DateFormatter().string(from: Date()))\n"
        out += "App version      : \(version) (build \(build))\n"

        // ── The tester's context, FIRST, because it is what the numbers below mean. ──
        section("WHAT THE TESTER REPORTED")
        // Unreachable while the sheet gates Export on a choice, but written as the honest
        // fallback rather than force-unwrapped: if a future caller builds a report without going
        // through the sheet, the file must say the answer is missing, never invent one.
        out += "Connection       : \(context.connection?.rawValue ?? "(not given)")\n"
        out += "Location         : \(context.location.isEmpty ? "(not given)" : context.location)\n"
        out += "What they were doing:\n"
        out += (context.activity.isEmpty ? "(not given)" : context.activity) + "\n"

        section("BUILD")
        // Regenerated here rather than scraped out of the captured log: the [BUILD] banner is at
        // the very start of the log and would be the first casualty of any future change to the
        // capture bound. Two independent copies of the same facts is the right redundancy for
        // the one line that says what this binary is.
        out += "configuration    : \(BuildInfo.configuration)\n"
        out += "swift            : \(BuildInfo.isOptimized ? "-O" : "-Onone")"
             + (BuildInfo.wholeModule ? " +WMO" : "") + "\n"
        out += "c/objc           : \(BuildInfo.cOptimization)\n"
        out += "DEBUG defined    : \(BuildInfo.debugDefined)\n"
        out += "app telemetry    : \(BuildInfo.debugDefined ? "ON" : "OFF")\n"
        out += "core telemetry   : \(ManifoldCoreBuild.telemetryEnabled ? "ON" : "OFF")"
             + " (via \(ManifoldCoreBuild.telemetrySource))\n"
        if !BuildInfo.debugDefined {
            // Said in the file rather than left for us to remember, because the absence of a
            // whole class of line is invisible to whoever reads this.
            out += """

                   NOTE: this is a build without app telemetry. The per-second rollups
                   ([SRT-FLOW], [WHEP-FLOW], the decode-rate tick, depth/jitter/underrun) are
                   compiled out and WILL NOT APPEAR BELOW. The connection lifecycle, decode
                   errors and colorimetry lines are all present. If this report is about
                   stutter rather than about connecting, ask for a Profile build.

                   """
        }

        section("MACHINE")
        out += MachineContext.lines().joined(separator: "\n") + "\n"

        section("ACTIVE ERROR STATE")
        var errors: [String] = []
        if let e = SRTClient.shared.lastError { errors.append("SRT   : \(e)") }
        if let e = WHEPClient.shared.lastError { errors.append("WHEP  : \(e)") }
        if let e = LicenseManager.shared.lastMessage { errors.append("License: \(e)") }
        out += errors.isEmpty ? "(no error state active at export time)\n"
                              : errors.joined(separator: "\n") + "\n"

        // ── TWO SECTIONS, OURS FIRST. See LogPartitioner for how they are told apart, and why
        //    an unrecognised line lands here rather than below.
        let (ourLog, systemLog) = LogPartitioner.partition(LogTap.shared.snapshot())

        section("CAPTURED LOG")
        out += "Manifold's own output. Times are local; a blank time column means the line came\n"
        out += "from print() or a C library and carried no timestamp of its own.\n\n"
        out += ourLog.isEmpty ? "(nothing captured)\n" : ourLog + "\n"

        section("SYSTEM MESSAGES")
        out += "Framework chatter from inside our process (CoreFoundation, libsqlite3,\n"
        out += "ViewBridge, audio and Network framework). Separated because it is almost never\n"
        out += "relevant — but kept, because occasionally it is.\n\n"
        out += systemLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(none)\n" : systemLog + "\n"

        // ── REDACT THE WHOLE DOCUMENT, INCLUDING WHAT THE TESTER TYPED. ──
        //
        // ⚠️ ORDER: PARSE, THEN PARTITION, THEN REDACT — redaction runs LAST, over the fully
        // assembled document, so it sees every line in the form that will actually be written.
        // Reversing it would be a real hole: scrubbing before the envelope came off would leave
        // the redactor matching against framing it does not understand, and scrubbing before
        // partitioning would mean the second section was never scrubbed at all.
        let (redacted, hits) = DiagnosticsRedactor.redact(out)

        var footer = "\n" + String(repeating: "=", count: 78) + "\n"
        footer += "REDACTION\n" + String(repeating: "=", count: 78) + "\n"
        footer += "Every line above was pattern-scrubbed before this file was written.\n"
        footer += "Removed: passphrases, stream IDs, tokens, URL paths and query strings, and\n"
        footer += "home-directory user names. Replacements are fixed-width, so no length of any\n"
        footer += "removed value can be inferred from this file.\n\n"
        for hit in hits {
            footer += String(format: "  %-32@ %@\n", hit.label,
                             hit.count < 0 ? "RULE FAILED TO COMPILE"
                                           : "\(hit.count) occurrence(s) removed")
        }
        return redacted + footer
    }

    /// Default filename: app version + a sortable timestamp, so a folder of these from several
    /// testers sorts usefully and no two collide.
    static func suggestedFilename() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Manifold-\(version)-diagnostics-\(f.string(from: Date())).txt"
    }
}

// MARK: - Presentation

/// Drives the prompt sheet. A singleton because the menu command lives in the `App` scene and
/// the sheet has to appear on the document window — the same shape `showStreamBookmarks` uses,
/// hoisted to an ObservableObject so a `.commands` block can reach it.
@MainActor
final class DiagnosticsExporter: ObservableObject {
    static let shared = DiagnosticsExporter()
    @Published var isPresenting = false
    private init() {}

    func begin() { isPresenting = true }

    /// Build, scrub, and offer a save panel. Called from the sheet's Export button.
    func write(context: DiagnosticsContext) {
        let text = DiagnosticsReport.build(context: context)

        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = DiagnosticsReport.suggestedFilename()
        panel.allowedContentTypes = [.plainText]
        // Plain .txt and nothing else: a tester must be able to open it, read it, and satisfy
        // themselves about what they are sending before they send it. An archive would hide it.
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                NSLog("[DIAG] diagnostics written (%d bytes)", text.utf8.count)
            } catch {
                NSLog("[DIAG] ⚠️ could not write diagnostics: %@", String(describing: error))
                let alert = NSAlert()
                alert.messageText = "Couldn’t save the diagnostics file."
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

struct DiagnosticsPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var context = DiagnosticsContext()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Diagnostics").font(.title3.weight(.semibold))
            Text("""
                 This writes a plain text file you can send us. Three questions first — without \
                 them the measurements in the file have no context, and interpreting them is \
                 mostly guesswork.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // ── AN UNSELECTED PICKER, WHICH SwiftUI SUPPORTS ONLY THROUGH AN OPTIONAL SELECTION.
            //
            // A `Picker` bound to a non-optional always displays SOME case, so there is no
            // "nothing chosen" state to express. Binding it to `Connection?` and giving the
            // placeholder row `.tag(Connection?.none)` is the idiomatic way to get one — but the
            // TAGS MUST ALSO BE OPTIONAL for the real rows (`.tag(Optional($0))`), because tag
            // matching is by exact type: `.tag($0)` on a `Connection?` selection matches nothing
            // and the picker silently sticks on the placeholder forever.
            Picker("Connection", selection: $context.connection) {
                Text("Select…").tag(DiagnosticsContext.Connection?.none)
                Divider()
                ForEach(DiagnosticsContext.Connection.allCases) {
                    Text($0.rawValue).tag(Optional($0))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                TextField("City or region", text: $context.location)
                Text("Roughly where you are — for interpreting latency. A city or region is "
                   + "plenty; we don’t want anything more precise.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("What were you doing?").font(.callout)
                TextEditor(text: $context.activity)
                    .font(.body)
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.separator, lineWidth: 1))
                Text("What you were watching, what went wrong, and roughly when.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Said before the file is written, not after — the tester decides whether to send it,
            // and they can only decide that if they know what is in it.
            Text("""
                 The file contains your build, machine and display details, and Manifold’s log. \
                 Stream passphrases, stream IDs and the paths of any stream URLs are removed \
                 before it is written; the file lists what it removed, and you can read the \
                 whole thing in any text editor before sending it.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline) {
                // THE REASON IS STATED, NOT LEFT TO BE INFERRED FROM THE GREY — the same rule the
                // stream composer's disabled Save follows. A greyed button with no explanation
                // reads as a broken app rather than an unanswered question.
                if context.connection == nil {
                    Text("Choose a connection type to export")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    dismiss()
                    DiagnosticsExporter.shared.write(context: context)
                }
                .disabled(context.connection == nil)
                // Return is only the default action once the form can actually be submitted, so
                // it cannot fire against a disabled button and appear to do nothing.
                .keyboardShortcut(context.connection == nil ? nil : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
