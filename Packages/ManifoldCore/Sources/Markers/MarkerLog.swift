//
//  MarkerLog.swift — the only log lines markers write (docs/MARKERS_PLAN.md §5.1).
//
//  ⚠️ PRIVACY BY TYPE. Every function here takes numbers and fixed words, never a String of the user's, so a marker's
//  name, notes, keywords and the file's name cannot reach the log (and so cannot reach Export Diagnostics, whose
//  "CAPTURED LOG" is the app's stderr). App code logs markers ONLY through these.
//

import Foundation

public enum MarkerLog {
    public enum Format: String, Sendable { case edl = "edl", csv = "csv", text = "text" }

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

    public static func imported(added: Int, duplicates: Int, occupied: Int = 0, outside: Int, unknownColors: Int,
                                shiftHours: Int, dropFrameMismatch: Bool) -> String {
        "[MARKERS] import edl added=\(added) duplicates=\(duplicates) occupied=\(occupied) outside=\(outside) unknown-colours=\(unknownColors) "
            + "shift=\(shiftHours)h df-mismatch=\(dropFrameMismatch ? "yes" : "no")"
    }

    public static func importFailed() -> String { "[MARKERS] import edl: not a marker EDL" }

    public static func regenerate(thumbnails: Int) -> String { "[MARKERS] regenerate thumbnails n=\(thumbnails)" }

    public static func deletedAllStored(documents: Int) -> String { "[MARKERS] deleted all stored markers: documents=\(documents)" }

    public static func remember(_ on: Bool) -> String { "[MARKERS] remember between sessions: \(on ? "on" : "off")" }

    /// The file's embedded chapters (docs/CHAPTER_MARKERS_PLAN.md §4.1): counts only, never a title.
    public static func chapters(_ r: ChapterMapping.Result, readMs: Int) -> String {
        "[MARKERS] chapters n=\(r.chapters.count) dropped-past-end=\(r.droppedPastEnd) dropped-before-start=\(r.droppedBeforeStart) "
            + "unreadable=\(r.droppedUnreadable) reader=libav read=\(readMs)ms"
    }

    /// The file's chapters could not be read at all (open failed): no chapters, not an error the user sees.
    public static func chaptersUnreadable() -> String { "[MARKERS] chapters: file unreadable by libav" }

    /// Convert to Markers (docs/CHAPTER_MARKERS_PLAN.md §4.1): counts only, never a title.
    public static func convertedChapters(_ r: ChapterMapping.ConvertResult) -> String {
        "[MARKERS] convert chapters added=\(r.added.count) identical=\(r.identical) occupied=\(r.occupied) "
            + "already-converted=\(r.alreadyConverted)"
    }
}
