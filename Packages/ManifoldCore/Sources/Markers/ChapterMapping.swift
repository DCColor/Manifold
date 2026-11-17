//
//  ChapterMapping.swift — a file's embedded chapters, placed on the marker frame index (docs/CHAPTER_MARKERS_PLAN.md §3).
//
//  Pure: no libav, no AVFoundation. The reader (`ChapterRead.ChapterReader`) hands over each chapter's start and end
//  exactly as the container states them (an integer in the chapter's own time base) and the timeline origin to take off
//  them (the video stream's `start_time` on the libav path, §2.3). Everything here is exact rational arithmetic, so a
//  chapter on a 23.976 frame boundary lands on that frame, not one either side of it.
//
//  THE FRAME RULE (D-C7, amended by D-C7a, Robbie 2026-11-16/17): floor, with a tolerance of max(one tick, 1 ms).
//    frame = floor(t × rate + min(max(one tick of the chapter's own time base, 1 ms), in frames, 0.5))
//  Floor, because a chapter part-way through a frame names the frame SHOWING at that time (what a seek to it displays,
//  `FrameGrid.frame(atSeconds:)`, and what Flip's player showed when its marker was made). The tolerance, because writers
//  quantize: ffmpeg's chapter track and Flip use 1/1000, so frame 241 at 23.976 (10.0516… s) is stored as 10.051 s,
//  240.99 frames, and a plain floor would put it one frame early. D-C7a's 1 ms floor on it is for Resolve, which rounds
//  its chapter times to milliseconds BEFORE writing them in 1/24000 (CHAPTER_MARKERS_PLAN §11.3.1): 58056 against frame
//  58's 58058 is two ticks short. A truly mid-frame chapter moves only if it is within 1 ms (or one tick) of the next frame.
//
//  THE LAYER'S ITEMS ("file markers"). Each item says where it came from (`source`: a chapter track, a Nero `chpl`, or
//  Premiere's XMP markers), what it is (`kind`: Chapter or Comment), and optionally a color, a STATED duration, a stable
//  id and a comment. libav's chapters (Stage 2) are chapters with none of those; XMP items (Stage 3, `XMPMarkers`) can
//  carry all of them.
//
//  XMP ITEMS (Stage 3, 2026-11-17): their start is a whole frame count at the track's rate, from the file's first frame
//  (§12.6), so they take NO origin and NO tolerance: the frame is the exact floor of start × file rate, which is the
//  start itself when the rates match (§12.4.5). DE-DUPLICATION: Premiere's `.mov` carries its Chapter markers both in the
//  chapter track and in XMP, to the frame (§11.3); a chapter-track or `chpl` chapter on the frame of an XMP Chapter is
//  left out (counted as `duplicates`), and the XMP one, which has a color and an id, is shown.
//
//  ⚠️ PRIVACY (§5.1, MARKERS_PLAN): chapter titles are the file's content, often a client's. Nothing here logs; callers
//  log through `MarkerLog.chapters`, which takes counts only.
//

import Foundation

/// A time stated by a container: `value × num / den` seconds.
public struct ChapterTime: Equatable, Sendable {
    public var value: Int64
    public var num: Int64
    public var den: Int64

    public init(value: Int64, num: Int64, den: Int64) {
        self.value = value
        self.num = num
        self.den = den
    }

    public static let zero = ChapterTime(value: 0, num: 1, den: 1)

    public var seconds: Double { den == 0 ? 0 : Double(value) * Double(num) / Double(den) }

    /// `self + other`, exact. In `self`'s base when both share it; otherwise over a common base, reduced. Nil for a zero
    /// base or a sum that does not fit.
    public func adding(_ other: ChapterTime) -> ChapterTime? {
        guard den != 0, other.den != 0 else { return nil }
        if num == other.num, den == other.den {
            let (v, o) = value.addingReportingOverflow(other.value)
            return o ? nil : ChapterTime(value: v, num: num, den: den)
        }
        // value·num/den + ov·on/od = (value·num·od + ov·on·den) / (den·od), as value × 1/(den·od).
        let n = Int128(value) * Int128(num) * Int128(other.den) + Int128(other.value) * Int128(other.num) * Int128(den)
        var d = Int128(den) * Int128(other.den)
        var v = n
        var a = v < 0 ? -v : v, b = d < 0 ? -d : d
        while b != 0 { (a, b) = (b, a % b) }
        if a > 1 { v /= a; d /= a }
        if d < 0 { v = -v; d = -d }
        guard v >= Int128(Int64.min), v <= Int128(Int64.max), d <= Int128(Int64.max) else { return nil }
        return ChapterTime(value: Int64(v), num: 1, den: Int64(d))
    }
}

/// Where an embedded item came from.
public enum EmbeddedMarkerSource: String, Equatable, Sendable {
    /// A QuickTime/MP4 chapter text track (linked by a `tref chap`).
    case chapterTrack
    /// A Nero `moov/udta/chpl` list.
    case chpl
    /// Premiere's `xmpDM:markers` (Stage 3, `XMPMarkers`).
    case xmp
}

/// What an embedded item is. Chapter tracks and `chpl` carry chapters only. Of Premiere's XMP types only Chapter and
/// Comment are shown (Robbie, 2026-11-17, superseding D-C12); the rest are skipped and counted by `XMPMarkers`.
public enum EmbeddedMarkerKind: String, CaseIterable, Equatable, Sendable {
    case chapter, comment

    /// The word the tooltip and the list lead with.
    public var label: String {
        switch self {
        case .chapter: return "Chapter"
        case .comment: return "Comment"
        }
    }

    /// The keyword a converted item gets (D-C4 for chapters; "comment" for comments).
    public var keyword: String { rawValue }

    /// The row's SF Symbol in place of a color swatch.
    public var symbolName: String {
        switch self {
        case .chapter: return "book.closed"
        case .comment: return "text.bubble"
        }
    }
}

/// An item's own colour, sRGB (D-C13: XMP markers carry one; chapter tracks and `chpl` never do).
public struct EmbeddedColor: Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red; self.green = green; self.blue = blue
    }
}

/// One chapter as the file states it, in file order. `end` is nil when the file states none.
public struct FileChapter: Equatable, Sendable {
    public var start: ChapterTime
    public var end: ChapterTime?
    public var title: String
    public var source: EmbeddedMarkerSource
    public var kind: EmbeddedMarkerKind
    /// Nil: drawn neutral (D-C13).
    public var color: EmbeddedColor?
    /// A duration the file STATES for the item (XMP `xmpDM:duration`, Stage 3), as opposed to a chapter's implied run to
    /// the next one. Only a stated duration gets a band (D-C16). Nil for chapter tracks and `chpl`.
    public var statedDuration: ChapterTime?
    /// A stable id the file gives the item (XMP `xmpDM:guid`, else its `marker_guid` param), so a repeat Convert skips it
    /// (D-C14). Nil for chapter tracks and `chpl`.
    public var stableID: String?
    /// The item's comment (XMP `xmpDM:comment`), as stated: may hold line breaks. Empty for chapter tracks and `chpl`.
    public var comment: String

    public init(start: ChapterTime, end: ChapterTime?, title: String, source: EmbeddedMarkerSource = .chapterTrack,
                kind: EmbeddedMarkerKind = .chapter, color: EmbeddedColor? = nil, statedDuration: ChapterTime? = nil,
                stableID: String? = nil, comment: String = "") {
        self.start = start
        self.end = end
        self.title = title
        self.source = source
        self.kind = kind
        self.color = color
        self.statedDuration = statedDuration
        self.stableID = stableID
        self.comment = comment
    }
}

/// A chapter on the marker frame index: shown, navigated to and converted like a marker, never stored (Option A, D-C1).
public struct MappedChapter: Equatable, Identifiable, Sendable {
    /// Its position in the file's own list (0-based), kept so ties stay in file order. Unique within one file.
    public var fileIndex: Int
    /// Frame index from the file's first frame, as `Marker.frame`.
    public var frame: Int
    /// Frames, at least 1.
    public var duration: Int
    /// Single line; empty stays empty (D3; Flip keeps empty titles too).
    public var title: String
    public var source: EmbeddedMarkerSource
    public var kind: EmbeddedMarkerKind
    public var color: EmbeddedColor?
    /// Frames, when the file states a duration (D-C16: only these get a band). Nil for chapters.
    public var statedDuration: Int?
    public var stableID: String?
    /// As stated (line breaks kept): the converted marker's notes, and a Comment's second tooltip line.
    public var comment: String

    public init(fileIndex: Int, frame: Int, duration: Int, title: String, source: EmbeddedMarkerSource = .chapterTrack,
                kind: EmbeddedMarkerKind = .chapter, color: EmbeddedColor? = nil, statedDuration: Int? = nil,
                stableID: String? = nil, comment: String = "") {
        self.fileIndex = fileIndex
        self.frame = frame
        self.duration = max(duration, 1)
        self.title = title
        self.source = source
        self.kind = kind
        self.color = color
        self.statedDuration = statedDuration.map { max($0, 1) }
        self.stableID = stableID
        self.comment = comment
    }

    public var id: Int { fileIndex }
    public var lastFrame: Int { frame + max(duration, 1) - 1 }
}

public enum ChapterMapping {

    /// What a mapping kept and what it left out, for the notice line and `MarkerLog.chapters`.
    public struct Result: Equatable, Sendable {
        public var chapters: [MappedChapter]
        /// Started after the file's last frame: listed nowhere, never clamped (§3.1).
        public var droppedPastEnd: Int
        /// Ended at or before the file's first frame.
        public var droppedBeforeStart: Int
        /// Start or rate unusable (a zero time base).
        public var droppedUnreadable: Int
        /// Chapter-track or `chpl` chapters left out because an XMP Chapter is on the same frame (shown instead).
        public var duplicates: Int = 0
        /// Of `droppedPastEnd`, the chapters (for the Inspector's Chapters row).
        public var chaptersPastEnd: Int = 0

        public var dropped: Int { droppedPastEnd + droppedBeforeStart + droppedUnreadable }
    }

    // MARK: Rate

    /// The exact rate as a fraction. NTSC rates (n × 1000/1001 for n = 24, 30, 48, 60, 120…) become n000/1001; whole rates
    /// n/1; anything else is taken to a thousandth. `MarkerModel.basis.rate` is a Double; this undoes its rounding.
    public static func exactRate(_ rate: Double) -> (num: Int64, den: Int64)? {
        guard rate.isFinite, rate > 0 else { return nil }
        let ntsc = (rate * 1001 / 1000).rounded()
        if ntsc >= 1, abs(rate - ntsc * 1000 / 1001) < 5e-3, abs(rate - rate.rounded()) > 1e-3 {
            return (Int64(ntsc) * 1000, 1001)
        }
        if abs(rate - rate.rounded()) < 1e-6 { return (Int64(rate.rounded()), 1) }
        return (Int64((rate * 1000).rounded()), 1000)
    }

    // MARK: Frames

    /// The frame a time names (D-C7a): floor(t × rate + min(max(tick, 1 ms) in frames, ½)), with `t = time − origin` and
    /// the tick `time`'s own time base. Exact (Int128). Nil for a zero time base or rate.
    public static func frame(of time: ChapterTime, origin: ChapterTime = .zero, rate: Double) -> Int? {
        guard let r = exactRate(rate) else { return nil }
        return frame(of: time, origin: origin, rateNum: r.num, rateDen: r.den)
    }

    /// `tolerant: false` is the exact floor, for XMP's whole frame counts (§12.4.5): a count at one rate rescaled to
    /// another names the frame showing at that time, with no writer's rounding to allow for.
    public static func frame(of time: ChapterTime, origin: ChapterTime = .zero, rateNum: Int64, rateDen: Int64,
                             tolerant: Bool = true) -> Int? {
        guard time.den != 0, time.num != 0, origin.den != 0, rateNum > 0, rateDen > 0 else { return nil }
        // Normalise signs so every denominator is positive.
        let (tv, tn, td) = normalised(time)
        let (ov, on, od) = normalised(origin)
        // t × rate = (tv·tn/td − ov·on/od) · rN/rD = (tv·tn·od − ov·on·td) · rN / (td·od·rD). Everything is scaled by
        // 1000 so that 1 ms is a whole number over the same denominator.
        let rN = Int128(rateNum), rD = Int128(rateDen)
        let numerator = (Int128(tv) * Int128(tn) * Int128(od) - Int128(ov) * Int128(on) * Int128(td)) * rN * 1000
        let denominator = Int128(td) * Int128(od) * rD * 1000
        // One tick of `time`'s base, in frames: |tn|/td · rN/rD = |tn|·od·rN·1000 / denominator.
        let tick = abs(Int128(tn)) * Int128(od) * rN * 1000
        // 1 ms in frames: rN/(1000·rD) = td·od·rN / denominator.
        let millisecond = Int128(td) * Int128(od) * rN
        // D-C7a: the larger of the two, capped at half a frame.
        let tolerance = tolerant ? min(max(tick, millisecond), denominator / 2) : 0
        let q = floorDiv(numerator + tolerance, denominator)
        guard q >= Int128(Int.min), q <= Int128(Int.max) else { return nil }
        return Int(q)
    }

    private static func normalised(_ t: ChapterTime) -> (Int64, Int64, Int64) {
        t.den < 0 ? (t.value, -t.num, -t.den) : (t.value, t.num, t.den)
    }

    private static func floorDiv(_ a: Int128, _ b: Int128) -> Int128 {
        let q = a / b
        return (a % b != 0) && ((a < 0) != (b < 0)) ? q - 1 : q
    }

    // MARK: Mapping

    /// Places every chapter on the frame index (§3.1, §3.2).
    ///
    /// - start: `frame(of:)`. Before frame 0 → frame 0 if it ends after frame 0, else dropped. After `lastFrame` → dropped.
    /// - end (exclusive): a STATED duration first (XMP, Stage 3: start + duration, and the band, D-C16); else, for a
    ///   chapter, the stated end when it is after the start; otherwise (none, or `end ≤ start`, as Flip's zero-length
    ///   markers) the next chapter starting on a later frame; the last chapter runs to the end of the file. A non-chapter
    ///   item with no stated duration is one frame, as a marker (§12.4.4). Clamped to the file's end. Duration =
    ///   end − start, at least 1.
    /// - Sorted by frame; ties keep file order. Titles made single-line; empty stays empty.
    /// - XMP items take no origin and no tolerance (see the header); a chapter-track or `chpl` chapter on an XMP
    ///   Chapter's frame is left out and counted in `duplicates`.
    public static func map(_ chapters: [FileChapter], origin: ChapterTime = .zero, rate: Double, lastFrame: Int) -> Result {
        var result = Result(chapters: [], droppedPastEnd: 0, droppedBeforeStart: 0, droppedUnreadable: 0)
        guard let r = exactRate(rate) else {
            result.droppedUnreadable = chapters.count
            return result
        }
        struct Placed { let index: Int; let start: Int; let statedEnd: Int?; let stated: Bool; let source: FileChapter }
        var placed: [Placed] = []
        for (i, c) in chapters.enumerated() {
            let xmp = c.source == .xmp
            let o = xmp ? ChapterTime.zero : origin
            guard let s = frame(of: c.start, origin: o, rateNum: r.num, rateDen: r.den, tolerant: !xmp) else {
                result.droppedUnreadable += 1
                continue
            }
            var e: Int?
            var stated = false
            if let d = c.statedDuration, let endTime = c.start.adding(d), d.value > 0,
               let ef = frame(of: endTime, origin: o, rateNum: r.num, rateDen: r.den, tolerant: !xmp) {
                e = max(ef, s + 1)
                stated = true
            } else if c.kind == .chapter, let end = c.end,
                      let ef = frame(of: end, origin: o, rateNum: r.num, rateDen: r.den, tolerant: !xmp), ef > s,
                      end.seconds > c.start.seconds {
                e = ef
            } else if c.kind != .chapter {
                e = s + 1
            }
            placed.append(Placed(index: i, start: s, statedEnd: e, stated: stated, source: c))
        }
        placed.sort { ($0.start, $0.index) < ($1.start, $1.index) }
        let fileEnd = lastFrame + 1
        // The frames of XMP Chapters: a chapter-track or `chpl` chapter there is the same chapter (see the header).
        let xmpChapterFrames = Set(placed.filter { $0.source.source == .xmp && $0.source.kind == .chapter }.map { max($0.start, 0) })
        for (k, p) in placed.enumerated() {
            if p.start > lastFrame {
                result.droppedPastEnd += 1
                if p.source.kind == .chapter { result.chaptersPastEnd += 1 }
                continue
            }
            if p.source.source != .xmp, p.source.kind == .chapter, xmpChapterFrames.contains(max(p.start, 0)) {
                result.duplicates += 1
                continue
            }
            // The next CHAPTER on a later frame: a comment between two chapters does not cut the first one short.
            let next = placed[(k + 1)...].first { $0.start > p.start && $0.source.kind == .chapter }?.start
            let end = min(p.statedEnd ?? next ?? fileEnd, fileEnd)
            if end <= 0 { result.droppedBeforeStart += 1; continue }
            let start = max(p.start, 0)
            let c = p.source
            result.chapters.append(MappedChapter(fileIndex: p.index, frame: start, duration: end - start,
                                                 title: Marker.singleLine(c.title), source: c.source, kind: c.kind,
                                                 color: c.color, statedDuration: p.stated ? end - start : nil,
                                                 stableID: c.stableID, comment: c.comment))
        }
        return result
    }

    // MARK: Beside the markers

    /// Whether `chapter` has been converted already, so it is shown as its marker only (§3.3, D-C14):
    /// - an item with a stable id: a marker carries that id (`Marker.embeddedID`), wherever it has been moved since;
    /// - any item: its frame holds a marker with the same name. Chapter-track and `chpl` chapters have no id, so this is
    ///   their only rule.
    public static func isConverted(_ chapter: MappedChapter, markers: [Marker]) -> Bool {
        if let id = chapter.stableID, markers.contains(where: { $0.embeddedID == id }) { return true }
        return markers.contains { $0.frame == chapter.frame && $0.name == chapter.title }
    }

    /// Chapters not yet converted (`isConverted`).
    public static func unconverted(_ chapters: [MappedChapter], markers: [Marker]) -> [MappedChapter] {
        chapters.filter { !isConverted($0, markers: markers) }
    }

    /// What Convert did: the import merge rule's counts, plus the items skipped because a marker already carries their
    /// stable id (D-C14).
    public struct ConvertResult: Equatable, Sendable {
        public var merge: ResolveEDL.MergeResult
        public var alreadyConverted: Int

        public var added: [Marker] { merge.added }
        /// Identical to the marker already on the frame (the same name and empty notes): merged, nothing added.
        public var identical: Int { merge.identical }
        /// A different marker starts on the frame (D19): skipped.
        public var occupied: Int { merge.occupied }
    }

    /// Convert to Markers (D-C4, D-C8, D-C13, D-C14): the item's own color through Premiere's 8→16 table
    /// (`PremiereMarkerColor`), else Blue; the kind's keyword ("chapter" or "comment"); name = its title; notes = its
    /// comment; the item's duration (stated, else D-C8's run for a chapter, 1 frame for a comment); its stable id when it
    /// has one. Through the import merge rule, so an item on a frame that already holds a different marker is skipped and
    /// counted, and one identical to a marker there merges (D19, `ResolveEDL.merge`). An item whose stable id a marker
    /// already carries is skipped first.
    public static func convert(_ chapters: [MappedChapter], into existing: [Marker], created: Date = Date()) -> ConvertResult {
        var skipped = 0
        var incoming: [Marker] = []
        for c in chapters {
            if let id = c.stableID, existing.contains(where: { $0.embeddedID == id }) { skipped += 1; continue }
            incoming.append(Marker(frame: c.frame, duration: c.duration, name: c.title, notes: c.comment,
                                   keywords: [c.kind.keyword], color: PremiereMarkerColor.markerColor(for: c.color),
                                   created: created, embeddedID: c.stableID))
        }
        return ConvertResult(merge: ResolveEDL.merge(incoming, into: existing), alreadyConverted: skipped)
    }

    public static let convertedKeyword = EmbeddedMarkerKind.chapter.keyword

    /// The frames ⇧↑/⇧↓ stop on (D-C6): markers and chapters together, each frame once, in order.
    public static func navigationFrames(markers: [Marker], chapters: [MappedChapter]) -> [Int] {
        Array(Set(markers.map(\.frame)).union(chapters.map(\.frame))).sorted()
    }

    /// The next (or previous) stop from `frame`, or nil at the end.
    public static func neighbour(of frame: Int, forward: Bool, in frames: [Int]) -> Int? {
        forward ? frames.first { $0 > frame } : frames.last { $0 < frame }
    }

    /// The frames the thumbnailer keeps (§4.1): markers' and chapters' together, so deleting a marker never deletes the
    /// thumbnail of a chapter on the same frame.
    public static func thumbnailFrames(markers: [Marker], chapters: [MappedChapter]) -> Set<Int> {
        Set(markers.map(\.frame)).union(chapters.map(\.frame))
    }
}
