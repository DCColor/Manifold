//
//  MarkerTextExport.swift — CSV and plain-text marker lists (docs/MARKERS_PLAN.md §6.5). Both keep everything: line
//  breaks in notes, and keywords.
//

import Foundation

public enum MarkerCSV {
    public static let header = ["Timecode In", "Timecode Out", "Duration", "Duration Frames", "Frame", "Color", "Name",
                                "Notes", "Keywords"]

    /// RFC 4180: CRLF between records, a field quoted when it holds a comma, quote or line break, quotes doubled.
    /// UTF-8 with a BOM, so Excel on the Mac reads accents (Numbers reads it either way).
    public static func export(markers: [Marker], basis: TimecodeBasis) -> Data {
        var rows = [header]
        for m in markers.sorted(by: { ($0.frame, $0.created) < ($1.frame, $1.created) }) {
            rows.append([basis.label(m.frame), basis.label(m.lastFrame), basis.durationLabel(m.duration),
                         String(m.duration), String(m.frame), m.color.name, m.name, m.notes,
                         m.keywords.joined(separator: "; ")])
        }
        let text = rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public enum MarkerPlainText {
    /// A header, then one block per marker: timecode, colour, duration and name; the notes indented below, line breaks
    /// kept; keywords last. UTF-8, LF.
    public static func export(markers: [Marker], fileName: String, basis: TimecodeBasis, date: Date = Date()) -> String {
        let sorted = markers.sorted { ($0.frame, $0.created) < ($1.frame, $1.created) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "Markers: \(fileName)\n"
        out += "Start timecode: \(basis.label(0))\(basis.hasTimecode ? "" : " (the file has no timecode)")\n"
        out += "Rate: \(basis.rateLabel) \(basis.dropFrame ? "DF" : "NDF")\n"
        out += "Markers: \(sorted.count)\n"
        out += "Exported: \(df.string(from: date))\n"
        let colorWidth = MarkerColor.allCases.map(\.name.count).max() ?? 8
        for m in sorted {
            out += "\n"
            let color = m.color.name.padding(toLength: colorWidth, withPad: " ", startingAt: 0)
            let dur = m.duration == 1 ? "1 fr" : "\(m.duration) fr"
            out += "\(basis.label(m.frame))  \(color)  \(dur.padding(toLength: 7, withPad: " ", startingAt: 0))  \(m.name)"
                .trimmingCharacters(in: .whitespaces) + "\n"
            for line in m.notes.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                out += "    \(line)\n"
            }
            if !m.keywords.isEmpty { out += "    Keywords: \(m.keywords.joined(separator: ", "))\n" }
        }
        return out
    }
}
