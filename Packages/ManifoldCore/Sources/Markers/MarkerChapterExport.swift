//
//  MarkerChapterExport.swift — markers out as a chapter list: ffmpeg metadata and YouTube description text
//  (docs/CHAPTER_MARKERS_PLAN.md §15). The reverse of the chapter reader. Pure: text in, text out.
//
//  Both formats are ELAPSED time from the file's first frame, never timecode (§15.3): the start timecode, drop-frame and the
//  start override do not apply. Markers only; the file's own chapters are exported after Convert (D-C5).
//
//  ⚠️ PRIVACY: titles are the user's content. The reports hold counts only, for `MarkerLog`.
//

import Foundation

public enum MarkerFFMetadata {
    public struct ExportReport: Equatable, Sendable {
        public var markers = 0
        /// Markers with no name, written as `title=` (D3; Flip does the same).
        public var emptyTitles = 0
        /// Titles holding a character ffmetadata reserves (`=`, `;`, `#`, `\`, a line break), escaped.
        public var escapedTitles = 0
        /// Ranged markers whose own end passed the next marker's frame, ended there instead (no overlaps).
        public var cappedEnds = 0
    }

    /// `;FFMETADATA1`, then one `[CHAPTER]` per marker in time order. `TIMEBASE` is the file's exact frame duration, so
    /// `START`/`END` are frames and nothing is rounded. A ranged marker ends after its last frame, or at the next marker's
    /// frame if that comes first, so chapters never overlap (Robbie, 2026-11-20); a point marker runs to the next marker's
    /// frame, the last to the file's end (§3.2's chapter rule). The last marker, ranged, keeps its own end.
    /// `frameCount` is the file's number of frames. UTF-8, LF, no BOM. Nil for a rate with no exact form.
    public static func export(markers: [Marker], rate: Double, frameCount: Int) -> (text: String, report: ExportReport)? {
        guard let r = ChapterMapping.exactRate(rate) else { return nil }
        let sorted = MarkerChapterList.sorted(markers)
        var report = ExportReport()
        var out = ";FFMETADATA1\n"
        for (i, m) in sorted.enumerated() {
            let hasNext = i + 1 < sorted.count
            let next = hasNext ? sorted[i + 1].frame : max(frameCount, m.frame + 1)
            var end = m.duration > 1 ? m.frame + m.duration : next
            if hasNext, end > next {
                end = next
                report.cappedEnds += 1
            }
            end = max(end, m.frame + 1)
            let title = escape(m.name)
            if m.name.isEmpty { report.emptyTitles += 1 }
            if title != m.name { report.escapedTitles += 1 }
            out += "[CHAPTER]\nTIMEBASE=\(r.den)/\(r.num)\nSTART=\(m.frame)\nEND=\(end)\ntitle=\(title)\n"
            report.markers += 1
        }
        return (out, report)
    }

    /// ffmetadata's escaping: `=`, `;`, `#`, `\` and a line break each take a backslash.
    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "=" || ch == ";" || ch == "#" || ch == "\\" || ch == "\n" { out.append("\\") }
            if ch == "\r\n" { out.append("\\\n"); continue }
            out.append(ch)
        }
        return out
    }
}

public enum MarkerYouTube {
    /// YouTube's chapter rules, from its help page "Video Chapters" (support.google.com/youtube/answer/9884579, read
    /// 2026-11-20): "the first timestamp you list starts with 00:00", "at least three timestamps listed in ascending order",
    /// "The minimum length for video chapters is 10 seconds." UNKNOWN on that page: whether 0:00 (one minute digit) is
    /// accepted, how a chapter's length is measured (here: to the next line, the last to the end of the video, as YouTube's
    /// player shows it; a marker's stored duration is never used, so it cannot reach past the next line), and any maximum
    /// count.
    public static let minimumChapters = 3
    public static let minimumSeconds = 10

    public struct ExportReport: Equatable, Sendable {
        public var markers = 0
        /// D-C18: lines for an unnamed marker, titled with the marker's timecode.
        public var timecodeTitles = 0
        /// The first line is not 00:00.
        public var noLineAtZero = false
        /// Fewer than `minimumChapters` lines.
        public var tooFew = false
        /// Chapters under `minimumSeconds`, the last measured to the end of the video.
        public var underMinimum = 0
        /// Lines on the same whole second as the line before (D19 keeps frames apart; seconds can still meet).
        public var sharedSecond = 0
        public var breaksRules: Bool { noLineAtZero || tooFew || underMinimum > 0 || sharedSecond > 0 }
    }

    /// One line per marker in time order: `MM:SS` under an hour, `H:MM:SS` from an hour on (the help page's own example is
    /// `00:00`), one space, then the name, or the marker's timecode label when it has none (D-C18). Frame `f` is written as
    /// `f / rate` seconds floored (§15.3), so a line never points after its marker. Every marker is written, whatever the
    /// rules; the report counts what breaks them. UTF-8, LF. Nil for a rate with no exact form.
    public static func export(markers: [Marker], basis: TimecodeBasis, frameCount: Int)
        -> (text: String, report: ExportReport)? {
        guard let r = ChapterMapping.exactRate(basis.rate) else { return nil }
        let sorted = MarkerChapterList.sorted(markers)
        var report = ExportReport()
        var out = ""
        let seconds = sorted.map { second(ofFrame: $0.frame, rateNum: r.num, rateDen: r.den) }
        for (i, m) in sorted.enumerated() {
            var title = m.name.trimmingCharacters(in: .whitespaces)
            if title.isEmpty {
                title = basis.label(m.frame)
                report.timecodeTitles += 1
            }
            out += "\(timestamp(seconds[i])) \(title)\n"
            report.markers += 1
            if i > 0, seconds[i] == seconds[i - 1] { report.sharedSecond += 1 }
        }
        // The video's length in exact seconds (frames × den / num), against the last line's whole second.
        let endNum = Int64(max(frameCount, 0)) * r.den
        for i in seconds.indices {
            let short: Bool
            if i + 1 < seconds.count {
                short = seconds[i + 1] - seconds[i] < Int64(minimumSeconds)
            } else {
                short = endNum - seconds[i] * r.num < Int64(minimumSeconds) * r.num
            }
            if short { report.underMinimum += 1 }
        }
        report.noLineAtZero = seconds.first.map { $0 != 0 } ?? true
        report.tooFew = sorted.count < minimumChapters
        return (out, report)
    }

    /// floor(frame × den / num): the whole second the frame falls in.
    static func second(ofFrame f: Int, rateNum: Int64, rateDen: Int64) -> Int64 {
        (Int64(max(f, 0)) * rateDen) / rateNum
    }

    /// `MM:SS` under an hour, `H:MM:SS` from an hour on.
    static func timestamp(_ s: Int64) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%lld:%02lld:%02lld", h, m, sec) : String(format: "%02lld:%02lld", m, sec)
    }

    /// The export notice: the count, then one sentence per broken rule (counts only), then the unconverted file markers.
    public static func notice(_ r: ExportReport, unconvertedFileMarkers: Int) -> String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        var parts = ["Exported \(n(r.markers, "chapter", "chapters")) for a YouTube description."]
        if r.timecodeTitles > 0 {
            parts.append("\(n(r.timecodeTitles, "unnamed marker is", "unnamed markers are")) titled with its timecode.")
        }
        if r.breaksRules {
            var rules: [String] = []
            if r.noLineAtZero { rules.append("no chapter at 00:00 (YouTube needs one)") }
            if r.tooFew { rules.append("fewer than \(minimumChapters) chapters (YouTube needs \(minimumChapters))") }
            if r.underMinimum > 0 {
                rules.append("\(n(r.underMinimum, "chapter", "chapters")) under \(minimumSeconds) s (YouTube’s minimum)")
            }
            if r.sharedSecond > 0 {
                rules.append("\(n(r.sharedSecond, "chapter shares", "chapters share")) a second with the one before")
            }
            parts.append("YouTube may not show these chapters: " + rules.joined(separator: "; ") + ".")
        }
        if let line = MarkerChapterList.unconvertedNotice(unconvertedFileMarkers) { parts.append(line) }
        return parts.joined(separator: " ")
    }
}

public enum MarkerChapterList {
    /// D-C5: the file's chapters and XMP markers are not exported until converted. Counts only (Robbie, 2026-11-20).
    public static func unconvertedNotice(_ count: Int) -> String? {
        count > 0 ? "\(count) file marker\(count == 1 ? "" : "s") not included: Convert them to include them." : nil
    }

    /// Time order, as the CSV and text exports take them (§15.2).
    static func sorted(_ markers: [Marker]) -> [Marker] {
        markers.sorted { ($0.frame, $0.created) < ($1.frame, $1.created) }
    }
}
