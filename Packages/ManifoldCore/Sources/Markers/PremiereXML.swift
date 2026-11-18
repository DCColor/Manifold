//
//  PremiereXML.swift — Premiere Pro marker export: FCP 7 XML (xmeml), one sequence that holds the clip, with the markers
//  on the sequence (docs/MARKER_EXPORT_PLAN.md §1, §4; decisions §8: E2 keywords into comments opt-in, E3 the sequence
//  holds the clip).
//
//  ── THE MODEL IS PREMIERE'S OWN EXPORT (P0, §1.3) ────────────────────────────────────────────────────────
//
//  `~/Code/Manifold/fixtures/markers/premiere-p0.xml` and `premiere-p0-df.xml`, written by Robbie's Premiere and read
//  for STRUCTURE ONLY:
//
//  - UTF-8 with a BOM, LF, `<!DOCTYPE xmeml>` with no DTD, `<xmeml version="4">`.
//  - `<sequence>`: uuid, duration, rate, name, media, timecode, then the markers. Not inside any clipitem.
//  - `<marker>`: `<comment>` (always written, empty when none), `<name>`, `<in>`, `<out>`, then `<pproColor>` unless
//    the color is Green. No type element: xmeml carries no marker type, so every marker arrives as a Comment marker.
//  - `<in>` is the frame from the sequence start. `<out>` is -1 for a one-frame marker (P0).
//  - Sequence `<timecode>`: `<frame>` is the plain frame count at the timebase, `<string>` is its label (all `;` for
//    drop-frame), `<displayformat>` DF or NDF.
//  - `<file>` written in full on its first use, then `<file id="file-1"/>`; `<pathurl>` `file://localhost/` + the
//    path, percent-escaped (RFC 2396).
//
//  ── PENDING ATTENDED STEPS (§6.3) ───────────────────────────────────────────────────────────────────────
//
//  - P2: whether Premiere reads `<pproColor>` back; a ranged marker's `<out>` as frame + duration (EXCLUSIVE; P0 is
//    consistent with it but does not prove it); the AUDIO LAYOUT (UNKNOWN beyond P0's stereo, see `audioTracks`);
//    whether import needs `<pproTicksIn>`/`<pproTicksOut>` (omitted, as Frame.io omits them).
//  - P3: 59.94 DF in xmeml (written as DF at timebase 60; UNKNOWN whether Premiere accepts it).
//  - P4: whether a line break in `<comment>` survives import. Until then, each run of line breaks becomes one space.
//
//  Omitted on purpose: `MZ.*`/`TL.*` attributes, `<labels>`, `<logginginfo>`, `<colorinfo>`, codec blocks (UI state or
//  re-read from the media).
//
//  ⚠️ PRIVACY: the file holds marker names, comments, keywords and the media's full path, by necessity. Nothing here
//  logs; `ExportReport` is counts only (`MarkerLog.exported(xmeml:)`).
//

import Foundation

public enum PremiereXML {

    // MARK: - Inputs

    /// The media the sequence holds. Everything here comes from the player's own reading of the file.
    public struct Media: Equatable, Sendable {
        /// The media file. Written as `<pathurl>`.
        public var url: URL
        /// Frames in the file (the last frame's index + 1).
        public var frameCount: Int
        public var width: Int
        public var height: Int
        /// Audio channels across the file's audio tracks; 0 = no audio.
        public var audioChannels: Int
        /// Hz; 48000 when the file does not say.
        public var audioSampleRate: Int
        /// 16 or 24; 16 otherwise.
        public var audioBitDepth: Int

        public init(url: URL, frameCount: Int, width: Int, height: Int, audioChannels: Int = 0,
                    audioSampleRate: Int = 48000, audioBitDepth: Int = 16) {
            self.url = url
            self.frameCount = max(frameCount, 1)
            self.width = max(width, 0)
            self.height = max(height, 0)
            self.audioChannels = max(audioChannels, 0)
            self.audioSampleRate = audioSampleRate > 0 ? audioSampleRate : 48000
            self.audioBitDepth = audioBitDepth == 24 ? 24 : 16
        }
    }

    public struct ExportOptions: Equatable, Sendable {
        /// E2: keywords appended to the comment as `[a, b]`. Off by default, as the EDL's.
        public var appendKeywordsToComments: Bool
        public init(appendKeywordsToComments: Bool = false) { self.appendKeywordsToComments = appendKeywordsToComments }
    }

    /// What the export changed, for its notice and log line. Counts only.
    public struct ExportReport: Equatable, Sendable {
        public var markers = 0
        /// Markers whose color is not one of the eight Premiere has a direct match for (§4.1's hue-rule rows).
        public var nearestColors = 0
        /// Notes that held a line break, written on one line.
        public var flattenedNotes = 0
        public var appendedKeywords = 0
        public var droppedKeywords = 0
        public var ranged = 0
        public init() {}
    }

    public enum ExportError: Error, Equatable {
        /// The rate is neither an integer rate nor an NTSC (1000/1001) one: xmeml cannot state it. Never guessed.
        case unsupportedRate
    }

    // MARK: - Writing

    /// The xmeml file for `markers` (any order; written in time order) on a sequence named `sequenceName` holding `media`.
    /// The sequence's start timecode is `basis` (the file's own, or the per-file override, §4.2); the clip's `<file>`
    /// timecode is the file's own (00:00:00:00 for a file without one). `sequenceUUID` is the caller's (a fresh one per
    /// export; fixed in tests).
    public static func export(markers: [Marker], sequenceName: String, media: Media, basis: TimecodeBasis,
                              sequenceUUID: UUID, options: ExportOptions = ExportOptions()) throws
        -> (data: Data, report: ExportReport) {
        guard let rate = Rate(basis) else { throw ExportError.unsupportedRate }
        var report = ExportReport()
        var w = Writer()
        let frames = media.frameCount
        let fileName = media.url.lastPathComponent
        let channels = media.audioChannels
        let stereo = channels == 2

        w.line(0, #"<?xml version="1.0" encoding="UTF-8"?>"#)
        w.line(0, "<!DOCTYPE xmeml>")
        w.line(0, #"<xmeml version="4">"#)
        w.line(1, #"<sequence id="sequence-1" explodedTracks="true">"#)
        w.element(2, "uuid", sequenceUUID.uuidString.lowercased())
        w.element(2, "duration", String(frames))
        rate.write(&w, 2)
        w.element(2, "name", sequenceName)
        w.line(2, "<media>")

        // Video: the format, then V1 with the clip.
        w.line(3, "<video>")
        w.line(4, "<format>")
        w.line(5, "<samplecharacteristics>")
        rate.write(&w, 6)
        videoCharacteristics(&w, 6, media)
        w.line(5, "</samplecharacteristics>")
        w.line(4, "</format>")
        w.line(4, "<track>")
        w.line(5, #"<clipitem id="clipitem-1">"#)
        clipHead(&w, 6, name: fileName, frames: frames, rate: rate)
        w.line(6, #"<file id="file-1">"#)
        w.element(7, "name", fileName)
        w.element(7, "pathurl", pathURL(media.url))
        rate.write(&w, 7)
        w.element(7, "duration", String(frames))
        // The file's OWN timecode: an override is the sequence's, never the clip's (§4.2). A user-data or XMP start the
        // override replaced is still the clip's own (CHAPTER_MARKERS_PLAN §13): Premiere reads it as the clip's timecode.
        let own = basis.fileOwn
        timecode(&w, 7, own, rate)
        w.line(7, "<media>")
        w.line(8, "<video>")
        w.line(9, "<samplecharacteristics>")
        rate.write(&w, 10)
        videoCharacteristics(&w, 10, media)
        w.line(9, "</samplecharacteristics>")
        w.line(8, "</video>")
        if channels > 0 {
            w.line(8, "<audio>")
            audioCharacteristics(&w, 9, media)
            w.element(9, "channelcount", String(channels))
            w.line(8, "</audio>")
        }
        w.line(7, "</media>")
        w.line(6, "</file>")
        links(&w, 6, channels: channels)
        w.line(5, "</clipitem>")
        w.element(5, "enabled", "TRUE")
        w.element(5, "locked", "FALSE")
        w.line(4, "</track>")
        w.line(3, "</video>")

        // Audio (LAYOUT UNKNOWN beyond stereo, P2): one clipitem per source channel, on its own track, as Premiere
        // wrote P0's stereo clip (two mono-exploded items, A1 and A2). Stereo carries `premiereChannelType` and a link
        // group, as in P0; other counts use the plain FCP 7 form.
        if channels > 0 {
            w.line(3, "<audio>")
            w.line(4, "<format>")
            audioCharacteristics(&w, 5, media)
            w.line(4, "</format>")
            for ch in 1...channels {
                w.line(4, "<track>")
                w.line(5, "<clipitem id=\"clipitem-\(ch + 1)\"\(stereo ? #" premiereChannelType="stereo""# : "")>")
                clipHead(&w, 6, name: fileName, frames: frames, rate: rate)
                w.line(6, #"<file id="file-1"/>"#)
                w.line(6, "<sourcetrack>")
                w.element(7, "mediatype", "audio")
                w.element(7, "trackindex", String(ch))
                w.line(6, "</sourcetrack>")
                links(&w, 6, channels: channels)
                w.line(5, "</clipitem>")
                w.element(5, "enabled", "TRUE")
                w.element(5, "locked", "FALSE")
                w.line(4, "</track>")
            }
            w.line(3, "</audio>")
        }
        w.line(2, "</media>")
        timecode(&w, 2, basis, rate)

        let sorted = markers.sorted { ($0.frame, $0.created) < ($1.frame, $1.created) }
        for m in sorted {
            var comment = flatten(m.notes)
            // A note whose text spans more than one line; a break only before or after the text loses nothing.
            if m.notes.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline) {
                report.flattenedNotes += 1
            }
            if !m.keywords.isEmpty {
                if options.appendKeywordsToComments {
                    let k = "[" + m.keywords.joined(separator: ", ") + "]"
                    comment = comment.isEmpty ? k : comment + " " + k
                    report.appendedKeywords += 1
                } else {
                    report.droppedKeywords += 1
                }
            }
            let premiere = PremiereMarkerColor(exporting: m.color)
            if !premiere.isDirectMatch(for: m.color) { report.nearestColors += 1 }
            let duration = max(m.duration, 1)
            if duration > 1 { report.ranged += 1 }
            w.line(2, "<marker>")
            w.element(3, "comment", comment)
            w.element(3, "name", Marker.singleLine(m.name))
            w.element(3, "in", String(m.frame))
            // EXCLUSIVE end (P0-consistent; P2 confirms).
            w.element(3, "out", duration == 1 ? "-1" : String(m.frame + duration))
            if let value = premiere.pproColor { w.element(3, "pproColor", String(value)) }
            w.line(2, "</marker>")
            report.markers += 1
        }
        w.line(1, "</sequence>")
        w.line(0, "</xmeml>")
        return (Data([0xEF, 0xBB, 0xBF]) + Data(w.text.utf8), report)
    }

    /// The line shown after an export: counts only, never a marker's words. `unconvertedFileMarkers`: the file's chapters
    /// and XMP markers not converted, which are not exported (D-C5, §4.4).
    public static func notice(_ r: ExportReport, unconvertedFileMarkers: Int) -> String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        var parts = ["Exported \(n(r.markers, "marker", "markers")) to Premiere Pro XML."]
        if r.nearestColors > 0 {
            parts.append("\(n(r.nearestColors, "marker", "markers")) took the nearest of Premiere’s 8 colors.")
        }
        if r.flattenedNotes > 0 {
            parts.append("\(n(r.flattenedNotes, "multi-line note was", "multi-line notes were")) joined onto one line.")
        }
        if r.droppedKeywords > 0 {
            parts.append("\(n(r.droppedKeywords, "marker has", "markers have")) keywords; Premiere has no field for them.")
        }
        if r.appendedKeywords > 0 { parts.append("Keywords were added to the comments.") }
        if unconvertedFileMarkers > 0 {
            parts.append("This file’s \(n(unconvertedFileMarkers, "file marker was", "file markers were")) not exported; convert them first.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Pieces

    /// `<rate>`: the integer timebase, and NTSC for a 1000/1001 rate. Nil for a rate xmeml cannot state.
    struct Rate {
        var timebase: Int
        var ntsc: Bool

        init?(_ basis: TimecodeBasis) {
            let r = basis.rate, n = basis.nfr
            guard r > 0, n > 0 else { return nil }
            if abs(r - Double(n)) < 0.0005 { timebase = n; ntsc = false; return }
            if abs(r - Double(n) * 1000 / 1001) < 0.0005 { timebase = n; ntsc = true; return }
            return nil
        }

        func write(_ w: inout Writer, _ depth: Int) {
            w.line(depth, "<rate>")
            w.element(depth + 1, "timebase", String(timebase))
            w.element(depth + 1, "ntsc", ntsc ? "TRUE" : "FALSE")
            w.line(depth, "</rate>")
        }
    }

    /// `<timecode>` as P0 writes it: the plain frame count, its label, DF/NDF. A drop-frame label is written with `;`
    /// throughout (`01;00;03;18`, P0-DF).
    private static func timecode(_ w: inout Writer, _ depth: Int, _ basis: TimecodeBasis, _ rate: Rate) {
        w.line(depth, "<timecode>")
        rate.write(&w, depth + 1)
        w.element(depth + 1, "string", timecodeString(basis))
        w.element(depth + 1, "frame", String(basis.startFrame))
        w.element(depth + 1, "displayformat", basis.dropFrame ? "DF" : "NDF")
        w.line(depth, "</timecode>")
    }

    static func timecodeString(_ basis: TimecodeBasis) -> String {
        let label = basis.label(0, separator: ":")
        return basis.dropFrame ? label.replacingOccurrences(of: ":", with: ";") : label
    }

    private static func clipHead(_ w: inout Writer, _ depth: Int, name: String, frames: Int, rate: Rate) {
        w.element(depth, "masterclipid", "masterclip-1")
        w.element(depth, "name", name)
        w.element(depth, "enabled", "TRUE")
        w.element(depth, "duration", String(frames))
        rate.write(&w, depth)
        w.element(depth, "start", "0")
        w.element(depth, "end", String(frames))
        w.element(depth, "in", "0")
        w.element(depth, "out", String(frames))
    }

    private static func videoCharacteristics(_ w: inout Writer, _ depth: Int, _ media: Media) {
        w.element(depth, "width", String(media.width))
        w.element(depth, "height", String(media.height))
        w.element(depth, "anamorphic", "FALSE")
        w.element(depth, "pixelaspectratio", "square")
        w.element(depth, "fielddominance", "none")
    }

    private static func audioCharacteristics(_ w: inout Writer, _ depth: Int, _ media: Media) {
        w.line(depth, "<samplecharacteristics>")
        w.element(depth + 1, "depth", String(media.audioBitDepth))
        w.element(depth + 1, "samplerate", String(media.audioSampleRate))
        w.line(depth, "</samplecharacteristics>")
    }

    /// The links that tie the video item and every audio item together (P0); stereo items share link group 1.
    private static func links(_ w: inout Writer, _ depth: Int, channels: Int) {
        guard channels > 0 else { return }
        w.line(depth, "<link>")
        w.element(depth + 1, "linkclipref", "clipitem-1")
        w.element(depth + 1, "mediatype", "video")
        w.element(depth + 1, "trackindex", "1")
        w.element(depth + 1, "clipindex", "1")
        w.line(depth, "</link>")
        for ch in 1...channels {
            w.line(depth, "<link>")
            w.element(depth + 1, "linkclipref", "clipitem-\(ch + 1)")
            w.element(depth + 1, "mediatype", "audio")
            w.element(depth + 1, "trackindex", String(ch))
            w.element(depth + 1, "clipindex", "1")
            if channels == 2 { w.element(depth + 1, "groupindex", "1") }
            w.line(depth, "</link>")
        }
    }

    /// Notes as one line (§1.3, pending P4): each run of line breaks becomes one space; the ends are trimmed.
    public static func flatten(_ notes: String) -> String {
        var out = ""
        var inBreak = false
        for ch in notes {
            if ch.isNewline {
                if !inBreak { out.append(" ") }
                inBreak = true
            } else {
                out.append(ch)
                inBreak = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// `file://localhost` + the absolute path, each byte outside RFC 2396's unreserved set and "/" percent-escaped
    /// (spaces as `%20`, as Premiere writes them, P0). The path is written in NFC: Foundation hands it back decomposed,
    /// and APFS finds a file under either form. Which form Premiere itself writes for a non-ASCII path is UNKNOWN (P0's
    /// path was ASCII).
    public static func pathURL(_ url: URL) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()/".utf8)
        var out = "file://localhost"
        for b in url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.utf8 {
            if allowed.contains(b) { out.append(Character(Unicode.Scalar(b))) } else { out += String(format: "%%%02X", b) }
        }
        return out
    }

    /// Text for an element: `& < > " '` escaped, and characters XML 1.0 cannot hold (controls other than tab, LF and CR;
    /// U+FFFE, U+FFFF) dropped.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            default:
                if u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// Tab-indented lines, LF, as Premiere writes them.
    struct Writer {
        var text = ""
        mutating func line(_ depth: Int, _ s: String) {
            text += String(repeating: "\t", count: depth) + s + "\n"
        }
        mutating func element(_ depth: Int, _ name: String, _ value: String) {
            line(depth, "<\(name)>\(PremiereXML.escape(value))</\(name)>")
        }
    }
}
