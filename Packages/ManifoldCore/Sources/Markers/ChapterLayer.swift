//
//  ChapterLayer.swift — the read-only chapter layer beside a file's markers (docs/CHAPTER_MARKERS_PLAN.md §4.1, Stage 2).
//
//  Pure: what the Markers slot, the Markers window, the timeline strip, ⇧↑/⇧↓ and the thumbnailer are given, from the
//  markers, the file's mapped chapters and the view settings. `MarkerModel` (App) calls it; the tests call it directly.
//
//  THE RULES:
//    · Chapters are not markers (D-C1): they occupy no frame (D19 ignores them), are never stored, never edited.
//    · Converted chapters are shown as their marker only (§3.3, D-C14: `ChapterMapping.isConverted`).
//    · View ▸ Show Chapters off hides them from the lists and the strip. (View ▸ Show Markers off hides both; the views
//      check that, as they always have for markers.)
//    · The filter: with any colour or the Chapters chip chosen, markers show only in the colours chosen, and chapters
//      only if the chip is chosen. Nothing chosen shows everything.
//    · ⇧↑/⇧↓ walk the union of the visible markers' and visible chapters' frames, each frame once (D-C6). ⇧M ignores
//      chapters (it stays on `MarkerRules.markerToEdit`).
//    · The thumbnailer keeps the union of EVERY marker's and EVERY chapter's frame, filters and Show settings aside, so
//      deleting a marker (or hiding chapters) never deletes a chapter's thumbnail (§4.1).
//
//  ⚠️ PRIVACY: titles are the file's content. Nothing here logs.
//

import Foundation

/// The Markers list's filter: colours, and the Chapters chip.
public struct MarkerFilter: Equatable, Sendable {
    public var colors: Set<MarkerColor>
    public var chapters: Bool

    public init(colors: Set<MarkerColor> = [], chapters: Bool = false) {
        self.colors = colors
        self.chapters = chapters
    }

    /// Something is chosen: only what is chosen shows.
    public var isActive: Bool { !colors.isEmpty || chapters }

    public func shows(_ m: Marker) -> Bool { !isActive || colors.contains(m.color) }
    public var showsChapters: Bool { !isActive || chapters }
}

/// One row of the Markers list: a marker, or a chapter (book symbol, not editable).
public enum MarkerListRow: Identifiable, Equatable, Sendable {
    case marker(Marker)
    case chapter(MappedChapter)

    public enum ID: Hashable, Sendable {
        case marker(UUID)
        case chapter(Int)
    }

    public var id: ID {
        switch self {
        case .marker(let m): return .marker(m.id)
        case .chapter(let c): return .chapter(c.fileIndex)
        }
    }

    public var frame: Int {
        switch self {
        case .marker(let m): return m.frame
        case .chapter(let c): return c.frame
        }
    }

    public var lastFrame: Int {
        switch self {
        case .marker(let m): return m.lastFrame
        case .chapter(let c): return c.lastFrame
        }
    }
}

public enum ChapterLayer {

    /// The markers the list and the strip show.
    public static func visibleMarkers(_ markers: [Marker], filter: MarkerFilter) -> [Marker] {
        filter.isActive ? markers.filter(filter.shows) : markers
    }

    /// The chapters the list and the strip show: not converted, Show Chapters on, and the filter lets them through.
    public static func visibleChapters(_ chapters: [MappedChapter], markers: [Marker], filter: MarkerFilter,
                                       showChapters: Bool) -> [MappedChapter] {
        guard showChapters, filter.showsChapters else { return [] }
        return ChapterMapping.unconverted(chapters, markers: markers)
    }

    /// Markers and chapters interleaved by frame. On one frame the marker comes first (it is drawn over the chapter on
    /// the strip too); chapters on one frame keep file order.
    public static func rows(markers: [Marker], chapters: [MappedChapter]) -> [MarkerListRow] {
        var out: [MarkerListRow] = []
        out.reserveCapacity(markers.count + chapters.count)
        var i = 0, j = 0
        while i < markers.count || j < chapters.count {
            if j >= chapters.count || (i < markers.count && markers[i].frame <= chapters[j].frame) {
                out.append(.marker(markers[i])); i += 1
            } else {
                out.append(.chapter(chapters[j])); j += 1
            }
        }
        return out
    }

    /// "12 markers · 8 chapters"; "3 of 12 markers · 8 chapters" with a filter. The chapters part only when the file has
    /// unconverted chapters.
    public static func countLabel(markersShown: Int, markersTotal: Int, chaptersShown: Int, chaptersTotal: Int) -> String {
        func part(_ shown: Int, _ total: Int, _ one: String, _ many: String) -> String {
            let noun = total == 1 ? one : many
            return shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
        }
        let m = part(markersShown, markersTotal, "marker", "markers")
        guard chaptersTotal > 0 else { return m }
        return m + " · " + part(chaptersShown, chaptersTotal, "chapter", "chapters")
    }

    /// The frames ⇧↑/⇧↓ stop on.
    public static func navigationFrames(visibleMarkers: [Marker], visibleChapters: [MappedChapter]) -> [Int] {
        ChapterMapping.navigationFrames(markers: visibleMarkers, chapters: visibleChapters)
    }

    /// The frames the thumbnailer keeps: every marker's and every chapter's, whatever is shown.
    public static func thumbnailFrames(markers: [Marker], chapters: [MappedChapter]) -> Set<Int> {
        ChapterMapping.thumbnailFrames(markers: markers, chapters: chapters)
    }

    /// A chapter row's tooltip (Robbie, 2026-11-17): "Chapter · 01:00:10:00 · <title>" (the title left out when empty),
    /// then "Chapter from the file · Convert to edit". `timecode` is the row's label. Local UI only; never logged.
    public static func rowToolTip(_ c: MappedChapter, timecode: String) -> String {
        let first = c.title.isEmpty ? "\(c.kind.label) · \(timecode)" : "\(c.kind.label) · \(timecode) · \(c.title)"
        return first + "\n\(c.kind.label) from the file · Convert to edit"
    }

    /// The notice after Convert. Counts and words only.
    public static func convertNotice(_ r: ChapterMapping.ConvertResult) -> String {
        let n = r.added.count
        var s = n == 0 ? "No chapters converted." : "Converted \(n) \(n == 1 ? "chapter" : "chapters") to markers."
        var skips: [String] = []
        if r.occupied > 0 { skips.append("\(r.occupied) skipped: another marker starts on \(r.occupied == 1 ? "its frame" : "their frames")") }
        if r.identical > 0 { skips.append("\(r.identical) already \(r.identical == 1 ? "a marker" : "markers")") }
        if r.alreadyConverted > 0 { skips.append("\(r.alreadyConverted) converted before") }
        if !skips.isEmpty { s += " " + skips.joined(separator: "; ") + "." }
        return s
    }
}
