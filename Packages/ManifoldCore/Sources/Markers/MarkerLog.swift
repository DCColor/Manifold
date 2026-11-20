//
//  MarkerLog.swift — the only log lines markers write (docs/MARKERS_PLAN.md §5.1).
//
//  ⚠️ PRIVACY BY TYPE. Every function here takes numbers and fixed words, never a String of the user's, so a marker's
//  name, notes, keywords and the file's name cannot reach the log (and so cannot reach Export Diagnostics, whose
//  "CAPTURED LOG" is the app's stderr). App code logs markers ONLY through these.
//

import Foundation

public enum MarkerLog {
    public enum Format: String, Sendable { case edl = "edl", csv = "csv", text = "text", xmeml = "xmeml" }

    public static func loaded(count: Int, fingerprintMs: Int) -> String {
        "[MARKERS] loaded n=\(count) fingerprint=\(fingerprintMs)ms"
    }

    public static func unavailable(reason: Reason) -> String { "[MARKERS] unavailable: \(reason.rawValue)" }

    public enum Reason: String, Sendable {
        case unreadable = "file unreadable"
        case storeUnreadable = "stored markers unreadable; not saving over them"
        case saveFailed = "save failed"
    }

    public static func changed(count: Int, action: Action) -> String { "[MARKERS] \(action.rawValue) n=\(count)" }

    public enum Action: String, Sendable { case add, edit, delete, undo, startOverride = "start-override", convert }

    public static func exported(_ format: Format, report: ResolveEDL.ExportReport) -> String {
        "[MARKERS] export \(format.rawValue) n=\(report.markers) multi-line=\(report.multiLineNotes) blank-lines-dropped=\(report.droppedBlankLines) "
            + "bars=\(report.replacedBars) dropped-keywords=\(report.droppedKeywords) keywords-in-notes=\(report.appendedKeywords)"
    }

    public static func exported(_ format: Format, count: Int) -> String { "[MARKERS] export \(format.rawValue) n=\(count)" }

    /// Premiere Pro XML (docs/MARKER_EXPORT_PLAN.md §5): counts only. Never the media path, which the file holds.
    public static func exported(xmeml r: PremiereXML.ExportReport, audioChannels: Int, unconvertedFileMarkers: Int) -> String {
        "[MARKERS] export \(Format.xmeml.rawValue) n=\(r.markers) ranged=\(r.ranged) nearest-colors=\(r.nearestColors) "
            + "flattened-notes=\(r.flattenedNotes) dropped-keywords=\(r.droppedKeywords) keywords-in-comments=\(r.appendedKeywords) "
            + "audio-channels=\(audioChannels) unconverted-file-markers=\(unconvertedFileMarkers)"
    }

    /// Premiere Pro XML refused: the file's rate is not one xmeml can state.
    public static func exportRefusedRate() -> String { "[MARKERS] export xmeml refused: rate not expressible" }

    public static func imported(added: Int, duplicates: Int, occupied: Int = 0, outside: Int, unknownColors: Int,
                                shiftHours: Int, dropFrameMismatch: Bool) -> String {
        "[MARKERS] import edl added=\(added) duplicates=\(duplicates) occupied=\(occupied) outside=\(outside) unknown-colors=\(unknownColors) "
            + "shift=\(shiftHours)h df-mismatch=\(dropFrameMismatch ? "yes" : "no")"
    }

    public static func importFailed() -> String { "[MARKERS] import edl: not a marker EDL" }

    public static func regenerate(thumbnails: Int) -> String { "[MARKERS] regenerate thumbnails n=\(thumbnails)" }

    public static func deletedAllStored(documents: Int) -> String { "[MARKERS] deleted all stored markers: documents=\(documents)" }

    public static func remember(_ on: Bool) -> String { "[MARKERS] remember between sessions: \(on ? "on" : "off")" }

    /// The file's markers on the layer, chapters (libav) and XMP items together (docs/CHAPTER_MARKERS_PLAN.md §4.1, §12):
    /// counts only, never a title. `duplicates`: chapter-track chapters shown as their XMP Chapter instead.
    public static func chapters(_ r: ChapterMapping.Result, readMs: Int) -> String {
        let chapters = r.chapters.filter { $0.kind == .chapter }.count
        return "[MARKERS] chapters n=\(r.chapters.count) chapter=\(chapters) comment=\(r.chapters.count - chapters) "
            + "dropped-past-end=\(r.droppedPastEnd) dropped-before-start=\(r.droppedBeforeStart) "
            + "unreadable=\(r.droppedUnreadable) duplicates=\(r.duplicates) reader=libav+xmp read=\(readMs)ms"
    }

    /// The file's XMP markers (docs/CHAPTER_MARKERS_PLAN.md §12, Stage 3): the packet's status and size, and counts per
    /// kind, shown and skipped. Fixed words and numbers only: never a name, comment, GUID or type string from the file.
    public static func xmp(_ r: XMPMarkers.Result, readMs: Int) -> String {
        let k = r.skipped
        return "[MARKERS] xmp status=\(r.status.rawValue) where=\(r.location?.rawValue ?? "-") bytes=\(r.packetBytes) "
            + "tracks=\(r.tracks) chapter=\(r.chapters) comment=\(r.comments) unreadable=\(r.unreadable) "
            + "skipped=\(k.total) segmentation=\(k.segmentation) weblink=\(k.weblink) flvcuepoint=\(k.flvCuePoint) "
            + "cue=\(k.cue) index=\(k.index) other=\(k.other) read=\(readMs)ms"
    }

    /// The file's chapters could not be read at all (open failed): no chapters, not an error the user sees.
    public static func chaptersUnreadable() -> String { "[MARKERS] chapters: file unreadable by libav" }

    /// Convert to Markers (docs/CHAPTER_MARKERS_PLAN.md §4.1): file markers of either kind; counts only, never a title.
    public static func convertedChapters(_ r: ChapterMapping.ConvertResult) -> String {
        "[MARKERS] convert chapters added=\(r.added.count) identical=\(r.identical) occupied=\(r.occupied) "
            + "already-converted=\(r.alreadyConverted)"
    }
}
