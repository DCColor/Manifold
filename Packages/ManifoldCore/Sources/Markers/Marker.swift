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

    public init(id: UUID = UUID(), frame: Int, duration: Int = 1, name: String = "", notes: String = "",
                keywords: [String] = [], color: MarkerColor = .defaultColor, created: Date = Date(), modified: Date? = nil) {
        self.id = id
        self.frame = max(frame, 0)
        self.duration = max(duration, 1)
        self.name = Marker.singleLine(name)
        self.notes = notes
        self.keywords = Marker.cleanKeywords(keywords)
        self.color = color
        self.created = created
        self.modified = modified ?? created
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
    /// The file states a timecode of its own.
    public var hasTimecode: Bool

    public init(startFrame: Int, nfr: Int, rate: Double, dropFrame: Bool, hasTimecode: Bool) {
        self.startFrame = startFrame
        self.nfr = max(nfr, 1)
        self.rate = rate
        self.dropFrame = dropFrame
        self.hasTimecode = hasTimecode
    }

    /// The basis for a file: its own timecode, else 00:00:00:00 non-drop, or the per-file override (D6). An override is
    /// used only for a file without timecode.
    public static func forFile(rate: Double, timecodeStartFrame: Int?, timecodeNFR: Int?, dropFrame: Bool,
                               overrideLabel: String?) -> TimecodeBasis {
        let nfr = timecodeNFR ?? max(Int(rate.rounded()), 1)
        if let start = timecodeStartFrame {
            return TimecodeBasis(startFrame: start, nfr: nfr, rate: rate, dropFrame: dropFrame, hasTimecode: true)
        }
        let start = overrideLabel.flatMap { SMPTETimecode.frameCount(label: $0, nfr: nfr, fps: rate, dropFrame: false) } ?? 0
        return TimecodeBasis(startFrame: start, nfr: nfr, rate: rate, dropFrame: false, hasTimecode: false)
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
    public func durationFrames(_ label: String) -> Int? { SMPTETimecode.durationFrames(label: label, nfr: nfr) }

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
    /// D6: the start timecode markers use for a file WITHOUT timecode ("01:00:00:00"); nil = 00:00:00:00.
    public var startOverride: String?
    /// Hints only, for finding the file again; never the key.
    public var lastPath: String?
    public var bookmark: Data?
    /// The file's start timecode when the document was last saved, to notice a file whose timecode later reads otherwise.
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
