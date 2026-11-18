//
//  Marker.swift — one marker on a file, and the timecode it is shown and exported at (docs/MARKERS_PLAN.md §1, §2).
//
//  A marker's position is a FRAME INDEX from the file's first frame, never a timecode string: the start timecode it is
//  labelled with (the file's own, or the per-file override for a file without one) can change without moving a marker.
//
//  ⚠️ PRIVACY (§5.1): `name`, `notes` and `keywords` are the user's content. Nothing in this module logs, and nothing that
//  calls it may put them in a log line or in Export Diagnostics. Log counts.
//

import Foundation
import SMPTETimecode

public struct Marker: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Frame index from the file's first frame (0-based).
    public var frame: Int
    /// Frames, at least 1 (Resolve's default and minimum).
    public var duration: Int
    /// Single line. Empty by default (D3: no placeholder text to delete).
    public var name: String
    /// May hold line breaks.
    public var notes: String
    public var keywords: [String]
    public var color: MarkerColor
    public var created: Date
    public var modified: Date
    /// The stable id of the embedded item this marker was converted from (D-C14, docs/CHAPTER_MARKERS_PLAN.md §12.5:
    /// Premiere's `marker_guid`, from Stage 3), so a second Convert skips it. Nil for every other marker, and for one
    /// converted from a chapter track or `chpl`, which carry no id. Optional and omitted from the JSON when nil, so the
    /// stored document is unchanged for every marker without one, and an older build reading one with it ignores it.
    public var embeddedID: String?

    public init(id: UUID = UUID(), frame: Int, duration: Int = 1, name: String = "", notes: String = "",
                keywords: [String] = [], color: MarkerColor = .defaultColor, created: Date = Date(), modified: Date? = nil,
                embeddedID: String? = nil) {
        self.id = id
        self.frame = max(frame, 0)
        self.duration = max(duration, 1)
        self.name = Marker.singleLine(name)
        self.notes = notes
        self.keywords = Marker.cleanKeywords(keywords)
        self.color = color
        self.created = created
        self.modified = modified ?? created
        self.embeddedID = embeddedID
    }

    /// The last frame the marker covers.
    public var lastFrame: Int { frame + max(duration, 1) - 1 }

    /// A name is one line: line breaks become spaces.
    public static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// Keywords trimmed, empty ones dropped, duplicates (ignoring case) dropped, order kept.
    public static func cleanKeywords(_ k: [String]) -> [String] {
        var seen = Set<String>()
        return k.map { singleLine($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The same marker as far as an import is concerned: same frame, name and notes.
    public func isDuplicate(of other: Marker) -> Bool {
        frame == other.frame && name == other.name && notes == other.notes
    }
}

/// How a file's frames are labelled: its start timecode as a frame count, its rates and drop-frame.
public struct TimecodeBasis: Equatable, Sendable {
    /// The start timecode as a frame count (0 = 00:00:00:00).
    public var startFrame: Int
    /// Integer frames per timecode second (24 for 23.976).
    public var nfr: Int
    /// Exact rate (23.976…).
    public var rate: Double
    public var dropFrame: Bool
    /// `startFrame` is the file's own timecode (any of the four sources, docs/CHAPTER_MARKERS_PLAN.md §13): false with no
    /// timecode, and false when the per-file override replaced it.
    public var hasTimecode: Bool
    /// Where `startFrame` came from: the file's source, `.override`, or nil (no timecode, 00:00:00:00).
    public var source: StartTimecodeSource?
    /// The file's own start, the override aside (nil when it has none), and its source. Same rate and drop-frame as the
    /// basis: an override is read at the replaced timecode's (`StartTimecodePrecedence.effective`).
    public var fileStartFrame: Int?
    public var fileSource: StartTimecodeSource?

    public init(startFrame: Int, nfr: Int, rate: Double, dropFrame: Bool, hasTimecode: Bool) {
        self.init(startFrame: startFrame, nfr: nfr, rate: rate, dropFrame: dropFrame, hasTimecode: hasTimecode,
                  source: hasTimecode ? .tmcd : nil, fileStartFrame: hasTimecode ? startFrame : nil,
                  fileSource: hasTimecode ? .tmcd : nil)
    }

    public init(startFrame: Int, nfr: Int, rate: Double, dropFrame: Bool, hasTimecode: Bool,
                source: StartTimecodeSource?, fileStartFrame: Int?, fileSource: StartTimecodeSource?) {
        self.startFrame = startFrame
        self.nfr = max(nfr, 1)
        self.rate = rate
        self.dropFrame = dropFrame
        self.hasTimecode = hasTimecode
        self.source = source
        self.fileStartFrame = fileStartFrame
        self.fileSource = fileSource
    }

    /// The basis for a file (Stage 4, D-C17): its own start timecode (`StartTimecodePrecedence.file`'s answer), or the
    /// per-file override where it applies — the file has no `tmcd` and no container timecode — else 00:00:00:00 non-drop.
    /// The same `StartTimecodePrecedence.effective` the engine's readout, entry and Export Frame names use.
    public static func forFile(rate: Double, timecode: StartTimecode?, overrideLabel: String?) -> TimecodeBasis {
        let eff = StartTimecodePrecedence.effective(file: timecode, overrideLabel: overrideLabel, rate: rate)
        return TimecodeBasis(startFrame: eff?.frameCount ?? 0, nfr: eff?.nfr ?? max(Int(rate.rounded()), 1), rate: rate,
                             dropFrame: eff?.dropFrame ?? false, hasTimecode: eff.map { $0.source != .override } ?? false,
                             source: eff?.source, fileStartFrame: timecode?.frameCount, fileSource: timecode?.source)
    }

    /// A file whose timecode is a `tmcd` track (`timecodeStartFrame` given), else the override or 00:00:00:00: the
    /// pre-Stage 4 form, kept for callers that only know a track's numbers.
    public static func forFile(rate: Double, timecodeStartFrame: Int?, timecodeNFR: Int?, dropFrame: Bool,
                               overrideLabel: String?) -> TimecodeBasis {
        let nfr = timecodeNFR ?? max(Int(rate.rounded()), 1)
        let tc = timecodeStartFrame.map { StartTimecode(frameCount: $0, nfr: nfr, fps: rate, dropFrame: dropFrame, source: .tmcd) }
        return forFile(rate: rate, timecode: tc, overrideLabel: overrideLabel)
    }

    /// D-C17a: the Markers slot offers the override (no `tmcd`, no container timecode).
    public var overrideAvailable: Bool { StartTimecodePrecedence.overrideApplies(to: fileSource) }

    /// The file's own start label, the override aside; nil when it has none.
    public var fileLabel: String? {
        fileStartFrame.map { SMPTETimecode.format(frameCount: $0, nfr: nfr, fps: rate, dropFrame: dropFrame) }
    }

    /// The same frames labelled by the file's own timecode, the override aside (00:00:00:00 when it has none).
    public var fileOwn: TimecodeBasis {
        if hasTimecode { return self }
        return TimecodeBasis(startFrame: fileStartFrame ?? 0, nfr: nfr, rate: rate, dropFrame: fileStartFrame == nil ? false : dropFrame,
                             hasTimecode: fileStartFrame != nil, source: fileSource, fileStartFrame: fileStartFrame,
                             fileSource: fileSource)
    }

    public var framesPerDay: Int { SMPTETimecode.framesPerDay(nfr: nfr, fps: rate, dropFrame: dropFrame) }

    /// The label of a file frame: ";" before the frames for drop-frame, unless `separator` says otherwise.
    public func label(_ frame: Int, separator: Character? = nil) -> String {
        SMPTETimecode.format(frameCount: startFrame + frame, nfr: nfr, fps: rate, dropFrame: dropFrame, separator: separator)
    }

    /// The file frame a label names (relative to the start, across midnight), or nil if it is not a label here.
    /// Not bounded by the file's length: the caller clamps or refuses.
    public func frame(label: String) -> Int? {
        guard let count = SMPTETimecode.frameCount(label: label, nfr: nfr, fps: rate, dropFrame: dropFrame) else { return nil }
        let day = framesPerDay
        guard day > 0 else { return count - startFrame }
        return ((count - startFrame) % day + day) % day
    }

    public func durationLabel(_ frames: Int) -> String { SMPTETimecode.durationLabel(frames: frames, nfr: nfr) }

    /// A typed Time field (the transport's rules, `TypedTimecode`): the file frame it names, relative entries counted from
    /// `current`. Not bounded by the file's length: the caller refuses past the end. Nil if it is not a timecode.
    public func typedFrame(_ text: String, current: Int) -> Int? {
        guard let t = TypedTimecode(text) else { return nil }
        switch t.sign {
        case .plus: return current + t.plainFrameCount(nfr: nfr)
        case .minus: return current - t.plainFrameCount(nfr: nfr)
        case .absolute:
            guard let count = t.labelFrameCount(nfr: nfr, fps: rate, dropFrame: dropFrame) else { return nil }
            let day = framesPerDay
            return day > 0 ? ((count - startFrame) % day + day) % day : count - startFrame
        }
    }

    /// A typed Duration field: a length in frames ("100" is one second of frames, "1" one frame), relative entries
    /// counted from `current`. Never drop-frame: a duration is not a position on a clock. Nil if it is not a timecode.
    public func typedDuration(_ text: String, current: Int) -> Int? {
        guard let t = TypedTimecode(text) else { return nil }
        let n = t.plainFrameCount(nfr: nfr)
        switch t.sign {
        case .absolute: return n
        case .plus: return current + n
        case .minus: return current - n
        }
    }

    /// "23.976", "29.97", "25".
    public var rateLabel: String {
        let r = (rate * 1000).rounded() / 1000
        return r == r.rounded() ? String(Int(r)) : String(format: "%.3f", r).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}

/// Everything stored for one media file (§5): its markers and the per-file start override.
public struct MarkerDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// `FileFingerprint` of the media: the store's key.
    public var fingerprint: String
    public var markers: [Marker]
    /// D6 / D-C17: the start timecode for a file with no `tmcd` and no container timecode ("01:00:00:00"): it replaces a
    /// QuickTime user-data or XMP start, and drives the readout, entry, Export Frame names and markers. Nil = the file's
    /// own (00:00:00:00 when it has none).
    public var startOverride: String?
    /// Hints only, for finding the file again; never the key.
    public var lastPath: String?
    public var bookmark: Data?
    /// The file's own start timecode (the override aside) when the document was last saved, to notice a file whose
    /// timecode later reads otherwise. Nil when it had none.
    public var startTimecodeSeen: String?

    public init(fingerprint: String, markers: [Marker] = [], startOverride: String? = nil, lastPath: String? = nil,
                bookmark: Data? = nil, startTimecodeSeen: String? = nil) {
        self.version = Self.currentVersion
        self.fingerprint = fingerprint
        self.markers = markers
        self.startOverride = startOverride
        self.lastPath = lastPath
        self.bookmark = bookmark
        self.startTimecodeSeen = startTimecodeSeen
    }

    /// Markers in time order (then by creation), the order every list and export uses.
    public var sorted: [Marker] {
        markers.sorted { ($0.frame, $0.created) < ($1.frame, $1.created) }
    }
}

/// ONE MARKER PER FRAME (Robbie, 2026-11-15): no two markers start on the same frame. Every path that adds or moves a
/// marker asks this first — Add Marker (M, ⌥M, and an In→Out span at its In frame) opens the marker already there, the
/// editor refuses a Time on another marker's frame, and an import skips a marker landing on an occupied frame unless it
/// is identical (`ResolveEDL.merge`).
public enum MarkerRules {
    /// The marker starting on `frame`, other than `excluding`.
    public static func occupant(of frame: Int, in markers: [Marker], excluding: UUID? = nil) -> Marker? {
        markers.first { $0.frame == frame && $0.id != excluding }
    }

    /// The marker Mark ▸ Edit Marker… opens: the one starting at the playhead, else the nearest one starting before it.
    public static func markerToEdit(at playhead: Int, in markers: [Marker]) -> Marker? {
        markers.filter { $0.frame <= playhead }.max { ($0.frame, $0.created) < ($1.frame, $1.created) }
    }
}
