//
//  ChapterMapping.swift — a file's embedded chapters, placed on the marker frame index (docs/CHAPTER_MARKERS_PLAN.md §3).
//
//  Pure: no libav, no AVFoundation. The reader (`ChapterRead.ChapterReader`) hands over each chapter's start and end
//  exactly as the container states them (an integer in the chapter's own time base) and the timeline origin to take off
//  them (the video stream's `start_time` on the libav path, §2.3). Everything here is exact rational arithmetic, so a
//  chapter on a 23.976 frame boundary lands on that frame, not one either side of it.
//
//  THE FRAME RULE (D-C7, Robbie 2026-11-16): floor, with one tick of tolerance.
//    frame = floor(t × rate + min(one tick of the chapter's own time base, in frames, 0.5))
//  Floor, because a chapter part-way through a frame names the frame SHOWING at that time (what a seek to it displays,
//  `FrameGrid.frame(atSeconds:)`, and what Flip's player showed when its marker was made). The tick, because writers
//  quantize: ffmpeg's chapter track and Flip use 1/1000, so frame 241 at 23.976 (10.0516… s) is stored as 10.051 s,
//  240.99 frames, and a plain floor would put it one frame early. One tick cannot move a truly mid-frame chapter by more
//  than one tick.
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
}

/// One chapter as the file states it, in file order. `end` is nil when the file states none.
public struct FileChapter: Equatable, Sendable {
    public var start: ChapterTime
    public var end: ChapterTime?
    public var title: String

    public init(start: ChapterTime, end: ChapterTime?, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }
}

/// A chapter on the marker frame index: shown, navigated to and converted like a marker, never stored (Option A, D-C1).
public struct MappedChapter: Equatable, Sendable {
    /// Its position in the file's own list (0-based), kept so ties stay in file order.
    public var fileIndex: Int
    /// Frame index from the file's first frame, as `Marker.frame`.
    public var frame: Int
    /// Frames, at least 1.
    public var duration: Int
    /// Single line; empty stays empty (D3; Flip keeps empty titles too).
    public var title: String

    public init(fileIndex: Int, frame: Int, duration: Int, title: String) {
        self.fileIndex = fileIndex
        self.frame = frame
        self.duration = max(duration, 1)
        self.title = title
    }

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

    /// The frame a time names (D-C7): floor(t × rate + min(tick in frames, ½)), with `t = time − origin` and the tick
    /// `time`'s own time base. Exact (Int128). Nil for a zero time base or rate.
    public static func frame(of time: ChapterTime, origin: ChapterTime = .zero, rate: Double) -> Int? {
        guard let r = exactRate(rate) else { return nil }
        return frame(of: time, origin: origin, rateNum: r.num, rateDen: r.den)
    }

    public static func frame(of time: ChapterTime, origin: ChapterTime = .zero, rateNum: Int64, rateDen: Int64) -> Int? {
        guard time.den != 0, time.num != 0, origin.den != 0, rateNum > 0, rateDen > 0 else { return nil }
        // Normalise signs so every denominator is positive.
        let (tv, tn, td) = normalised(time)
        let (ov, on, od) = normalised(origin)
        // t × rate = (tv·tn/td − ov·on/od) · rN/rD = (tv·tn·od − ov·on·td) · rN / (td·od·rD)
        let rN = Int128(rateNum), rD = Int128(rateDen)
        let numerator = (Int128(tv) * Int128(tn) * Int128(od) - Int128(ov) * Int128(on) * Int128(td)) * rN
        let denominator = Int128(td) * Int128(od) * rD
        // One tick of `time`'s base, in frames: |tn|/td · rN/rD = |tn|·od·rN / denominator. Capped at half a frame.
        let tick = abs(Int128(tn)) * Int128(od) * rN
        let tolerance = min(tick, denominator / 2)
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
    /// - end (exclusive): the stated end when it is after the start; otherwise (none, or `end ≤ start`, as Flip's zero-length
    ///   markers) the next chapter starting on a later frame; the last chapter runs to the end of the file. Clamped to the
    ///   file's end. Duration = end − start, at least 1.
    /// - Sorted by frame; ties keep file order. Titles made single-line; empty stays empty.
    public static func map(_ chapters: [FileChapter], origin: ChapterTime = .zero, rate: Double, lastFrame: Int) -> Result {
        var result = Result(chapters: [], droppedPastEnd: 0, droppedBeforeStart: 0, droppedUnreadable: 0)
        guard let r = exactRate(rate) else {
            result.droppedUnreadable = chapters.count
            return result
        }
        struct Placed { let index: Int; let start: Int; let statedEnd: Int?; let title: String }
        var placed: [Placed] = []
        for (i, c) in chapters.enumerated() {
            guard let s = frame(of: c.start, origin: origin, rateNum: r.num, rateDen: r.den) else {
                result.droppedUnreadable += 1
                continue
            }
            var e: Int?
            if let end = c.end, let ef = frame(of: end, origin: origin, rateNum: r.num, rateDen: r.den), ef > s,
               end.seconds > c.start.seconds { e = ef }
            placed.append(Placed(index: i, start: s, statedEnd: e, title: Marker.singleLine(c.title)))
        }
        placed.sort { ($0.start, $0.index) < ($1.start, $1.index) }
        let fileEnd = lastFrame + 1
        for (k, p) in placed.enumerated() {
            if p.start > lastFrame { result.droppedPastEnd += 1; continue }
            let next = placed[(k + 1)...].first { $0.start > p.start }?.start
            let end = min(p.statedEnd ?? next ?? fileEnd, fileEnd)
            if end <= 0 { result.droppedBeforeStart += 1; continue }
            let start = max(p.start, 0)
            result.chapters.append(MappedChapter(fileIndex: p.index, frame: start, duration: end - start, title: p.title))
        }
        return result
    }

    // MARK: Beside the markers

    /// Chapters not yet converted: a chapter whose frame holds a marker with the same name is shown as that marker only
    /// (§3.3).
    public static func unconverted(_ chapters: [MappedChapter], markers: [Marker]) -> [MappedChapter] {
        chapters.filter { c in !markers.contains { $0.frame == c.frame && $0.name == c.title } }
    }

    /// Convert Chapters to Markers (D-C4, D-C8): Blue, keyword "chapter", the chapter's duration, through the import merge
    /// rule, so a chapter on a frame that already holds a different marker is skipped and counted, and one identical to a
    /// marker there merges (D19, `ResolveEDL.merge`).
    public static func convert(_ chapters: [MappedChapter], into existing: [Marker], created: Date = Date()) -> ResolveEDL.MergeResult {
        let incoming = chapters.map {
            Marker(frame: $0.frame, duration: $0.duration, name: $0.title, keywords: [convertedKeyword], color: .blue,
                   created: created)
        }
        return ResolveEDL.merge(incoming, into: existing)
    }

    public static let convertedKeyword = "chapter"

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
