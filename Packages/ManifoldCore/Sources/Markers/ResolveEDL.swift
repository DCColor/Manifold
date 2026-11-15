//
//  ResolveEDL.swift — DaVinci Resolve's marker EDL, written and read (docs/MARKERS_PLAN.md §6).
//
//  ── THE MODEL IS RESOLVE'S OWN EXPORT (D11), NOT FRAME.IO'S ─────────────────────────────────────────────
//
//  Resolve 21.1, Timeline ▸ Export ▸ Timeline Markers to EDL (`docs/markers/resolve-reference-2398.edl`,
//  `resolve-reference-2997DF.edl`, R1, 2026-11-15), byte for byte:
//
//      TITLE: <timeline name>␍␊
//      FCM: NON-DROP FRAME␍␊                    ("DROP FRAME" for a drop-frame timeline)
//      ␍␊
//      001  001      V     C        01:00:01:16 01:00:01:17 01:00:01:16 01:00:01:17  ␍␊
//      <notes> |C:ResolveColorBlue |M:<name> |D:<frames>␍␊
//      ␍␊
//
//  - CRLF line endings. Event number, then "001", then V and C in fixed columns; two trailing spaces.
//  - OUT IS ALWAYS IN + 1, whatever the duration: the duration is `|D:` alone (a 24-frame marker still has in + 1).
//  - DROP-FRAME TIMECODES ARE WRITTEN WITH COLONS. Only FCM says drop-frame.
//  - Empty notes leave a leading space: " |C:…".
//  - No "@" line. Frame.io writes one; Resolve imports it as the FIRST LINE OF THE NOTE (R2,
//    `docs/markers/frameio_formating.png`), so Manifold writes none (D10) and, reading, skips it.
//  - R2 also shows `|D:0` imported as one frame, and that each comment line before the `|C:` line becomes its own note
//    line in Resolve.
//
//  MULTI-LINE NOTES KEEP THEIR LINE BREAKS (D13, revised 2026-11-15): each note line is written as its own comment line,
//  the last one carrying `|C:`, because R2 shows Resolve's importer keeps every comment line as a note line. Blank lines
//  are dropped (a blank line ends an event). Resolve's OWN export flattens a multi-line note onto one line (R1, Robbie
//  2026-11-15), so notes that come back from Resolve arrive single-line.
//
//  `|` becomes "/": the line holding `|C:` is parsed from its end, and a `|` of the user's could be read as a field.
//  Keywords have no field (Resolve's own export drops them, R1): dropped, or appended as " [a, b]" if asked.
//
//  A note line that starts with "@" is written with one leading space: the reader skips an "@" line in column 0 that is
//  an event's FIRST comment line (Frame.io's author line), and must not skip the user's.
//

import Foundation
import SMPTETimecode

public enum ResolveEDL {

    // MARK: - Writing

    public struct ExportOptions: Equatable, Sendable {
        /// D13: off by default.
        public var appendKeywordsToNotes: Bool
        public init(appendKeywordsToNotes: Bool = false) { self.appendKeywordsToNotes = appendKeywordsToNotes }
    }

    /// What the export changed, for its summary line. Counts only (§5.1).
    public struct ExportReport: Equatable, Sendable {
        public var markers = 0
        /// Notes written over more than one line.
        public var multiLineNotes = 0
        /// Blank lines left out of notes (a blank line would end the event).
        public var droppedBlankLines = 0
        public var replacedBars = 0
        public var droppedKeywords = 0
        public var appendedKeywords = 0
        public init() {}
    }

    /// The EDL for `markers` (any order; written in time order). `title`: the TITLE line, Resolve's timeline name; the
    /// caller passes the clip's name without its extension.
    public static func export(markers: [Marker], title: String, basis: TimecodeBasis,
                              options: ExportOptions = ExportOptions()) -> (text: String, report: ExportReport) {
        var report = ExportReport()
        let crlf = "\r\n"
        var out = "TITLE: \(singleLine(title))" + crlf
        out += "FCM: \(basis.dropFrame ? "DROP FRAME" : "NON-DROP FRAME")" + crlf + crlf
        let sorted = markers.sorted { ($0.frame, $0.created) < ($1.frame, $1.created) }
        for (i, m) in sorted.enumerated() {
            let tcIn = basis.label(m.frame, separator: ":")
            let tcOut = basis.label(m.frame + 1, separator: ":")
            out += String(format: "%03d  001      V     C        ", i + 1)
                + "\(tcIn) \(tcOut) \(tcIn) \(tcOut)  " + crlf

            let raw = m.notes.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            var lines = raw.filter { !$0.isEmpty }
            let interiorBlanks = raw.count - lines.count
                - (raw.prefix { $0.isEmpty }.count) - (raw.reversed().prefix { $0.isEmpty }.count)
            // Blank lines BETWEEN text lines are the ones a reader would miss; leading and trailing ones are not counted.
            if !lines.isEmpty { report.droppedBlankLines += max(interiorBlanks, 0) }
            if lines.count > 1 { report.multiLineNotes += 1 }
            if !m.keywords.isEmpty {
                if options.appendKeywordsToNotes {
                    let k = "[" + m.keywords.joined(separator: ", ") + "]"
                    if lines.isEmpty { lines = [k] } else { lines[lines.count - 1] += " " + k }
                    report.appendedKeywords += 1
                } else {
                    report.droppedKeywords += 1
                }
            }
            var name = singleLine(m.name)
            if lines.contains(where: { $0.contains("|") }) || name.contains("|") { report.replacedBars += 1 }
            lines = lines.map { $0.replacingOccurrences(of: "|", with: "/") }
            name = name.replacingOccurrences(of: "|", with: "/")
            if let first = lines.first, first.hasPrefix("@") { lines[0] = " " + first }
            let last = lines.popLast() ?? ""
            for l in lines { out += l + crlf }
            out += "\(last) |C:\(m.color.resolveToken) |M:\(name) |D:\(max(m.duration, 1))" + crlf + crlf
            report.markers += 1
        }
        return (out, report)
    }

    private static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ")
    }

    // MARK: - Reading

    /// One marker as the EDL states it: an absolute timecode label, not yet placed on a file.
    public struct Entry: Equatable, Sendable {
        public var event: Int
        /// The record-in label as written.
        public var recordIn: String
        public var name: String
        public var notes: String
        public var color: MarkerColor
        /// The colour token did not name one of the 16 (the marker is Blue).
        public var unknownColor: Bool
        public var duration: Int
    }

    public struct Parsed: Equatable, Sendable {
        public var title: String?
        /// nil when the EDL has no FCM line.
        public var dropFrame: Bool?
        public var entries: [Entry]
        /// Events with no `|C:` line: not markers.
        public var skippedEvents: Int
    }

    public enum ParseError: Error, Equatable {
        case notText
        case noMarkers
    }

    /// Parse an EDL permissively: CRLF or LF; an event line, then its comment lines up to the next event or blank line;
    /// an event's first comment line starting "@" in column 0 is skipped (Frame.io's author line, D10); the line holding
    /// `|C:` gives notes, colour, name and duration, and any other comment lines before it are note lines above it, as
    /// Resolve reads them (R2). TITLE and FCM are read only before the first event, so a note line cannot be taken for one.
    public static func parse(_ data: Data) throws -> Parsed {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ParseError.notText
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var title: String?
        var dropFrame: Bool?
        var entries: [Entry] = []
        var skipped = 0
        var current: (event: Int, recordIn: String, comments: [String])?

        func flush() {
            guard let c = current else { return }
            current = nil
            guard let idx = c.comments.lastIndex(where: { $0.contains("|C:") }),
                  var entry = fields(c.comments[idx]) else { skipped += 1; return }
            let above = c.comments[..<idx]
            if !above.isEmpty {
                entry.notes = (above + (entry.notes.isEmpty ? [] : [entry.notes])).joined(separator: "\n")
            }
            entry.event = c.event
            entry.recordIn = c.recordIn
            entries.append(entry)
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\t "))
            let inHeader = current == nil && entries.isEmpty && skipped == 0
            if inHeader, raw.uppercased().hasPrefix("TITLE:") {
                title = String(raw.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue
            }
            if inHeader, raw.uppercased().hasPrefix("FCM:") {
                let v = raw.dropFirst(4).uppercased()
                dropFrame = !(v.contains("NON-DROP") || v.contains("NON DROP") || v.contains("NONDROP")); continue
            }
            if let ev = eventLine(raw) {
                flush()
                current = (ev.number, ev.recordIn, [])
                continue
            }
            if line.isEmpty { flush(); continue }
            // Frame.io's "@Author, date" line: an event's first comment line, "@" in column 0 (D10).
            if raw.hasPrefix("@"), current?.comments.isEmpty == true { continue }
            // A comment line keeps its own text: a note may begin with a space only when it is empty (" |C:").
            current?.comments.append(raw.hasPrefix(" |C:") ? raw : line)
        }
        flush()
        guard !entries.isEmpty else { throw ParseError.noMarkers }
        return Parsed(title: title, dropFrame: dropFrame, entries: entries, skippedEvents: skipped)
    }

    /// An event line: a number, then fields, ending in four timecodes (source in/out, record in/out).
    private static func eventLine(_ raw: String) -> (number: Int, recordIn: String)? {
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 6, let n = Int(tokens[0]) else { return nil }
        let tcs = tokens.filter(isTimecodeToken)
        guard tcs.count >= 4, isTimecodeToken(tokens[tokens.count - 1]) else { return nil }
        return (n, tcs[tcs.count - 2])
    }

    private static func isTimecodeToken(_ t: String) -> Bool {
        let parts = t.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        return parts.count == 4 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isNumber) }
    }

    /// `<notes> |C:<token> |M:<name> |D:<frames>`, read from its end so a note may hold anything. `|M:` and `|D:` may be
    /// missing; `D:0` reads as 1, as Resolve reads it (R2).
    private static func fields(_ line: String) -> Entry? {
        guard let cRange = line.range(of: "|C:", options: .backwards) else { return nil }
        var notes = String(line[..<cRange.lowerBound])
        if notes.hasSuffix(" ") { notes.removeLast() }
        let tail = String(line[cRange.upperBound...])
        var colorToken = tail
        var name = ""
        var duration = 1
        if let m = tail.range(of: " |M:") {
            colorToken = String(tail[..<m.lowerBound])
            var rest = String(tail[m.upperBound...])
            if let d = rest.range(of: " |D:", options: .backwards) {
                duration = Int(rest[d.upperBound...].trimmingCharacters(in: .whitespaces)) ?? 1
                rest = String(rest[..<d.lowerBound])
            }
            name = rest
        } else if let d = tail.range(of: " |D:", options: .backwards) {
            colorToken = String(tail[..<d.lowerBound])
            duration = Int(tail[d.upperBound...].trimmingCharacters(in: .whitespaces)) ?? 1
        }
        colorToken = colorToken.trimmingCharacters(in: .whitespaces)
        let color = MarkerColor(resolveToken: colorToken)
        return Entry(event: 0, recordIn: "", name: name.trimmingCharacters(in: .whitespaces), notes: notes,
                     color: color ?? .defaultColor, unknownColor: color == nil, duration: max(duration, 1))
    }

    // MARK: - Placing on a file

    public struct Placement: Equatable, Sendable {
        public var markers: [Marker]
        /// Entries whose timecode is not a label at this rate, or falls outside the file. Event numbers.
        public var outside: [Int]
        public var unknownColors: Int
        /// FCM says drop-frame and the file is not, or the reverse.
        public var dropFrameMismatch: Bool
        /// Whole hours that would put EVERY entry inside the file, when some do not fit as is (the Frame.io case:
        /// 01:00:00:00 against a file at 00:00:00:00). Offered, never applied (§6.4).
        public var suggestedShiftHours: Int?
    }

    /// Place parsed entries on a file of `lastFrame + 1` frames. Labels are counted in the EDL's own FCM, and so is the
    /// file's start label, so a Resolve timeline built at the file's start timecode lines up whichever FCM it used.
    public static func place(_ parsed: Parsed, basis: TimecodeBasis, lastFrame: Int, shiftHours: Int = 0,
                             now: Date = Date()) -> Placement {
        let edlDF = parsed.dropFrame ?? basis.dropFrame
        let startLabel = basis.label(0, separator: ":")
        let startCount = SMPTETimecode.frameCount(label: startLabel, nfr: basis.nfr, fps: basis.rate, dropFrame: edlDF)
            ?? SMPTETimecode.lenientFrameCount(timecode: startLabel, fps: basis.rate)?.frameCount ?? basis.startFrame
        let day = SMPTETimecode.framesPerDay(nfr: basis.nfr, fps: basis.rate, dropFrame: edlDF)
        let hour = SMPTETimecode.framesPerDay(nfr: basis.nfr, fps: basis.rate, dropFrame: edlDF) / 24

        func relative(_ e: Entry, shift: Int) -> Int? {
            guard let c = SMPTETimecode.frameCount(label: e.recordIn, nfr: basis.nfr, fps: basis.rate, dropFrame: edlDF)
            else { return nil }
            let r = ((c + shift * hour - startCount) % day + day) % day
            return r <= lastFrame ? r : nil
        }

        var markers: [Marker] = []
        var outside: [Int] = []
        var unknown = 0
        for e in parsed.entries {
            if e.unknownColor { unknown += 1 }
            guard let f = relative(e, shift: shiftHours) else { outside.append(e.event); continue }
            markers.append(Marker(frame: f, duration: e.duration, name: e.name, notes: e.notes, color: e.color,
                                  created: now))
        }
        // Whenever any entry falls outside, not only when all do: on the Frame.io reference (a 61-minute file, markers
        // from 01:00:11:22) a 00:00:00:00 file takes the first few markers at the wrong place and loses the rest.
        var suggestion: Int?
        if !outside.isEmpty {
            let candidates = (1...23).flatMap { [-$0, $0] }
            suggestion = candidates.first { h in parsed.entries.allSatisfy { relative($0, shift: shiftHours + h) != nil } }
                .map { shiftHours + $0 }
        }
        return Placement(markers: markers, outside: outside, unknownColors: unknown,
                         dropFrameMismatch: parsed.dropFrame.map { $0 != basis.dropFrame } ?? false,
                         suggestedShiftHours: suggestion)
    }

    /// Merge `incoming` into `existing`, skipping duplicates (same frame, name and notes; D9). Returns what was added.
    public static func merge(_ incoming: [Marker], into existing: [Marker]) -> (added: [Marker], duplicates: Int) {
        var added: [Marker] = []
        var dupes = 0
        for m in incoming {
            if existing.contains(where: { $0.isDuplicate(of: m) }) || added.contains(where: { $0.isDuplicate(of: m) }) {
                dupes += 1
            } else {
                added.append(m)
            }
        }
        return (added, dupes)
    }
}
