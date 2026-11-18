//
//  StartTimecode.swift — where a file's start timecode comes from, and which one wins (docs/CHAPTER_MARKERS_PLAN.md §13,
//  Stage 4: D-C15, D-C17).
//
//  PRECEDENCE (one function, `StartTimecodePrecedence`):
//
//      1. a `tmcd` track                     (ManifoldCore's `TimecodeReader`)
//      2. the container's timecode           (libav's `timecode` metadata, format then stream; MXF)
//      3. QuickTime user data                (`moov/udta` `©TIM`, at `©TSC` / `©TSZ`; Premiere's MP4s)
//      4. XMP `xmpDM:startTimecode`          (else `xmpDM:altTimecode`, with its `timeFormat`)
//
//  A lower source is used only when nothing above exists. The per-file override (D-C17) applies only when the file has
//  no source 1 or 2: it can replace a user-data or XMP start, never a `tmcd` or container timecode. Where it applies it is
//  what the transport readout, timecode entry, Export Frame names and markers all use.
//
//  Pure Foundation, in the Markers target, so `MarkersTests` tests it without libav. The reads reuse Stage 3's box walk
//  (`XMPBoxWalk`) and its XMLParser setup (`XMPTree`: namespaces on, no external entities, DTDs refused, depth and size
//  capped).
//
//  ⚠️ PRIVACY: a start timecode is not user content in the sense of a marker's name, but nothing here logs, and the one
//  log line (`StartTimecodeLog`) carries the source kind and counts only.
//

import Foundation
import SMPTETimecode

/// Where a start timecode came from.
public enum StartTimecodeSource: String, Equatable, Sendable, CaseIterable {
    case tmcd
    case container
    case userData = "user-data"
    case xmp
    /// The per-file start override (D-C17), set in the Markers slot.
    case override

    /// The file's own timecode track or container timecode: the override never replaces these (D-C17a).
    public var isAuthoritative: Bool { self == .tmcd || self == .container }

    /// From the file's metadata rather than a timecode: QuickTime user data or XMP.
    public var isFileMetadata: Bool { self == .userData || self == .xmp }

    /// After the value in the Inspector's Start TC row. Nil for a `tmcd` track, the ordinary case.
    public var inspectorNote: String? {
        switch self {
        case .tmcd: return nil
        case .container: return "from the container"
        case .userData: return "from file metadata (QuickTime)"
        case .xmp: return "from file metadata (XMP)"
        case .override: return "set in Manifold"
        }
    }

    /// The transport readout's indicator tooltip. Nil for a `tmcd` track (no indicator).
    public var readoutHelp: String? {
        switch self {
        case .tmcd: return nil
        case .container: return "TC from the container’s metadata"
        case .userData: return "TC from file metadata (QuickTime user data), not a timecode track"
        case .xmp: return "TC from file metadata (XMP), not a timecode track"
        case .override: return "TC set in Manifold for this file (Markers ▸ Start timecode)"
        }
    }

    /// The SF Symbol by the transport readout. Nil for a `tmcd` track.
    public var readoutSymbol: String? {
        switch self {
        case .tmcd: return nil
        case .container, .userData, .xmp: return "doc.text"
        case .override: return "pencil"
        }
    }
}

/// A start timecode: a frame count at its own rate, and where it came from.
public struct StartTimecode: Equatable, Sendable {
    /// 0 = 00:00:00:00.
    public var frameCount: Int
    /// Integer frames per timecode second (24 for 23.976).
    public var nfr: Int
    /// Exact rate.
    public var fps: Double
    public var dropFrame: Bool
    public var source: StartTimecodeSource

    public init(frameCount: Int, nfr: Int, fps: Double, dropFrame: Bool, source: StartTimecodeSource) {
        self.frameCount = frameCount
        self.nfr = max(nfr, 1)
        self.fps = fps
        self.dropFrame = dropFrame
        self.source = source
    }

    /// A label at a stated rate: strict (`SMPTETimecode.frameCount`), drop-frame when `dropFrame` or the label has ";".
    /// Nil for anything that is not a label at this rate, drop-frame at a rate without it (only 29.97 and 59.94), or a
    /// rate outside 1…240 fps (a `©TSC` without its `©TSZ` would otherwise read 24000 fps).
    public init?(label: String, fps: Double, dropFrame: Bool = false, source: StartTimecodeSource) {
        guard fps.isFinite, fps >= 1, fps <= 240 else { return nil }
        let drop = dropFrame || label.contains(";")
        if drop && !StartTimecode.hasDropFrame(fps) { return nil }
        let nfr = max(Int(fps.rounded()), 1)
        guard let count = SMPTETimecode.frameCount(label: label, nfr: nfr, fps: fps, dropFrame: drop) else { return nil }
        self.init(frameCount: count, nfr: nfr, fps: fps, dropFrame: drop, source: source)
    }

    /// "01:00:00:00", ";" before the frames for drop-frame.
    public var label: String { SMPTETimecode.format(frameCount: frameCount, nfr: nfr, fps: fps, dropFrame: dropFrame) }

    /// Drop-frame exists at 29.97 and 59.94 only.
    public static func hasDropFrame(_ fps: Double) -> Bool {
        abs(fps - 30000.0 / 1001) < 0.005 || abs(fps - 60000.0 / 1001) < 0.005
    }
}

// MARK: - Precedence

public enum StartTimecodePrecedence {

    /// Every source a file was read for. Nil = the file has none (or it did not read).
    public struct Candidates: Equatable, Sendable {
        public var tmcd: StartTimecode?
        public var container: StartTimecode?
        public var userData: StartTimecode?
        public var xmp: StartTimecode?
        public init(tmcd: StartTimecode? = nil, container: StartTimecode? = nil, userData: StartTimecode? = nil,
                    xmp: StartTimecode? = nil) {
            self.tmcd = tmcd
            self.container = container
            self.userData = userData
            self.xmp = xmp
        }
        /// Sources 1 and 2 are absent, so 3 and 4 are worth reading.
        public var needsMetadata: Bool { tmcd == nil && container == nil }
    }

    /// The file's own start timecode, the override aside: the highest source present. Each candidate is re-stamped with
    /// its slot's source, so a caller cannot mislabel one.
    public static func file(_ c: Candidates) -> StartTimecode? {
        func stamped(_ t: StartTimecode?, _ s: StartTimecodeSource) -> StartTimecode? {
            guard var t else { return nil }
            t.source = s
            return t
        }
        return stamped(c.tmcd, .tmcd) ?? stamped(c.container, .container) ?? stamped(c.userData, .userData)
            ?? stamped(c.xmp, .xmp)
    }

    /// D-C17a: the override is offered, and applies, only when the file has no `tmcd` and no container timecode.
    /// `fileSource` is the file's own (from `file`), nil when it has none.
    public static func overrideApplies(to fileSource: StartTimecodeSource?) -> Bool {
        !(fileSource?.isAuthoritative ?? false)
    }

    /// What every reader uses: the file's own start, or the override where it applies (D-C17).
    ///
    /// The override is read at the replaced timecode's rate and drop-frame, so replacing a 29.97 DF user-data start keeps
    /// drop-frame labels; with no file timecode, at `rate` (the file's), non-drop, as D6 always was. An override that is
    /// not a label there is ignored (the file's own stays). Nil when there is neither, or no usable rate for an override.
    public static func effective(file: StartTimecode?, overrideLabel: String?, rate: Double) -> StartTimecode? {
        if let file, file.source.isAuthoritative { return file }
        guard let label = overrideLabel?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return file }
        let nfr: Int, fps: Double, drop: Bool
        if let file {
            (nfr, fps, drop) = (file.nfr, file.fps, file.dropFrame)
        } else {
            guard rate > 0, rate.isFinite else { return nil }
            (nfr, fps, drop) = (max(Int(rate.rounded()), 1), rate, false)
        }
        guard let count = SMPTETimecode.frameCount(label: label, nfr: nfr, fps: fps, dropFrame: drop) else { return file }
        return StartTimecode(frameCount: count, nfr: nfr, fps: fps, dropFrame: drop, source: .override)
    }

    /// `file`, then `effective`, in one call.
    public static func resolve(_ c: Candidates, overrideLabel: String?, rate: Double) -> StartTimecode? {
        effective(file: file(c), overrideLabel: overrideLabel, rate: rate)
    }
}

// MARK: - Sources 3 and 4: the file's metadata

public enum StartTimecodeMetadata {

    /// `©TIM`, `©TSC`, `©TSZ` as box type codes.
    public static let timCode: UInt32 = 0xA954_494D
    public static let tscCode: UInt32 = 0xA954_5343
    public static let tszCode: UInt32 = 0xA954_535A

    public struct Result: Equatable, Sendable {
        public var userData: StartTimecode?
        public var xmp: StartTimecode?
        /// `©TIM` was there (read or not).
        public var userDataPresent = false
        /// `xmpDM:startTimecode` or `xmpDM:altTimecode` was there (read or not).
        public var xmpPresent = false
        public init() {}
        /// Present but not readable (a label that is not one at its rate, or no rate): counted, never used.
        public var unreadable: Int { (userDataPresent && userData == nil ? 1 : 0) + (xmpPresent && xmp == nil ? 1 : 0) }
    }

    /// Sources 3 and 4 of a `.mov` / `.mp4`. Anything that does not start like one (an MXF) is not walked. Call it off
    /// the main thread, or where `TimecodeReader`'s own walk already runs: box headers and two small payloads only.
    public static func read(url: URL) -> Result {
        guard let src = XMPFileSource(url: url) else { return Result() }
        return read(src)
    }

    public static func read(_ src: XMPByteSource) -> Result {
        var r = Result()
        guard XMPBoxWalk.looksLikeISOBMFF(src) else { return r }
        let ud = XMPBoxWalk.userData(in: src, codes: [timCode, tscCode, tszCode])
        if let tim = ud[timCode] {
            r.userDataPresent = true
            r.userData = userData(tim: tim, tsc: ud[tscCode], tsz: ud[tszCode])
        }
        if case .packet(let data, _) = XMPBoxWalk.find(in: src) {
            let x = xmp(data)
            r.xmpPresent = x.present
            r.xmp = x.timecode
        }
        return r
    }

    // MARK: QuickTime user data

    /// `©TIM` at `©TSC` / `©TSZ` (24000 / 1001). Each payload is QuickTime international text (UInt16 length, UInt16
    /// language, the text), or an iTunes-style `data` box. No rate, or a label that is not one at it: nil.
    public static func userData(tim: Data, tsc: Data?, tsz: Data?) -> StartTimecode? {
        guard let label = text(tim), let scale = tsc.flatMap(text).flatMap({ Int64($0) }), scale > 0 else { return nil }
        let size = tsz.flatMap(text).flatMap { Int64($0) } ?? 1
        guard size > 0 else { return nil }
        return StartTimecode(label: label, fps: Double(scale) / Double(size), source: .userData)
    }

    /// The text of a user-data string payload, trimmed; nil unless it is short printable ASCII.
    static func text(_ d: Data) -> String? {
        let b = [UInt8](d)
        var body: ArraySlice<UInt8>
        if b.count >= 16, b[4] == 0x64, b[5] == 0x61, b[6] == 0x74, b[7] == 0x61 {        // "data": 8 header, 4 type, 4 locale
            let size = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard size >= 16, size <= b.count else { return nil }
            body = b[16..<size]
        } else if b.count >= 4 {
            let len = Int(b[0]) << 8 | Int(b[1])
            guard 4 + len <= b.count else { return nil }
            body = b[4..<(4 + len)]
        } else {
            return nil
        }
        while let last = body.last, last == 0 { body = body.dropLast() }
        guard !body.isEmpty, body.count <= 64, body.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // MARK: XMP

    /// `xmpDM:startTimecode` of the packet's top-level description, else its `xmpDM:altTimecode`: `timeValue` at
    /// `timeFormat`, with `startTimeScale` / `startTimeSampleSize` as the rate when the format does not read. Only the
    /// top-level `rdf:Description`s are asked: `xmpMM:Pantry` and `History` hold other files' metadata.
    public static func xmp(_ packet: Data) -> (timecode: StartTimecode?, present: Bool) {
        guard packet.count <= XMPMarkers.maxPacketBytes, !XMPMarkers.containsDeclaration(packet) else { return (nil, false) }
        var data = packet
        while let last = data.last, last == 0 { data.removeLast() }
        guard let root = XMPTree.build(data) else { return (nil, false) }
        let descriptions = root.descendants(ns: XMPTree.rdf, name: "RDF")
            .flatMap { $0.children.filter { $0.ns == XMPTree.rdf && $0.name == "Description" } }
        var present = false
        for name in ["startTimecode", "altTimecode"] {
            for d in descriptions {
                guard let node = XMPTree.child(d, name) else { continue }
                present = true
                guard let value = XMPTree.value(node, "timeValue")?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                var format = XMPTree.value(node, "timeFormat").flatMap(timeFormat)
                if format == nil, let scale = XMPTree.value(d, "startTimeScale").flatMap({ Int64($0) }), scale > 0 {
                    let size = XMPTree.value(d, "startTimeSampleSize").flatMap { Int64($0) } ?? 1
                    if size > 0 { format = (Double(scale) / Double(size), false) }
                }
                guard let format,
                      let tc = StartTimecode(label: value, fps: format.fps, dropFrame: format.dropFrame, source: .xmp) else { continue }
                return (tc, true)
            }
        }
        return (nil, present)
    }

    /// XMP's `timeFormat` (`23976Timecode`, `25Timecode`, `2997DropTimecode`, `5994NonDropTimecode`, …) → rate and
    /// drop-frame. The digits are the rate without its point for the 1000/1001 rates (23976, 2997, 4795, 5994, 11988),
    /// else whole frames per second (1…240). Drop-frame only at 29.97 and 59.94. Nil for anything else.
    public static func timeFormat(_ s: String) -> (fps: Double, dropFrame: Bool)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix("Timecode") else { return nil }
        var head = String(t.dropLast("Timecode".count))
        var drop = false
        if head.hasSuffix("NonDrop") {
            head = String(head.dropLast("NonDrop".count))
        } else if head.hasSuffix("Drop") {
            head = String(head.dropLast("Drop".count))
            drop = true
        }
        guard !head.isEmpty, head.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(head) else { return nil }
        let ntsc: [Int: Double] = [23976: 24000.0 / 1001, 2398: 24000.0 / 1001, 2997: 30000.0 / 1001,
                                   4795: 48000.0 / 1001, 47952: 48000.0 / 1001, 5994: 60000.0 / 1001,
                                   11988: 120000.0 / 1001]
        let fps: Double
        if let r = ntsc[n] { fps = r } else if (1...240).contains(n) { fps = Double(n) } else { return nil }
        if drop && !StartTimecode.hasDropFrame(fps) { return nil }
        return (fps, drop)
    }
}

// MARK: - The "start timecode now reads differently" notice

public enum StartTimecodeNotice {
    /// What `MarkerModel` does once per load, when the rate and timecode are known: a notice, and whether to save the
    /// file's own start as seen so it is told once.
    ///
    /// - A stored `seen` that differs from the file's own start: told (as before Stage 4), unless an override still
    ///   applies, in which case the labels did not move.
    /// - No `seen` (the document was saved while the file read as having no timecode) and the file's own start now
    ///   comes from QuickTime user data or XMP (Premiere's MP4s), with no override: the labels moved from 00:00:00:00, so
    ///   it is told, and why ("now read from the file's metadata"). One that reads 00:00:00:00 moved nothing: saved as
    ///   seen, untold.
    /// - No markers, or no file timecode: nothing.
    public static func check(seen: String?, basis: TimecodeBasis, storedOverride: String?, hasMarkers: Bool)
        -> (notice: String?, saveSeen: Bool) {
        guard hasMarkers, let now = basis.fileLabel else { return (nil, false) }
        let was: String
        if let seen {
            guard seen != now else { return (nil, false) }
            was = seen
        } else {
            guard basis.fileSource?.isFileMetadata == true, storedOverride == nil else { return (nil, false) }
            was = "00:00:00:00"
            if now == was { return (nil, true) }
        }
        if basis.source == .override { return (nil, true) }
        if basis.source?.isFileMetadata == true {
            return ("This file’s start timecode is now read from the file’s metadata: \(now). Its markers were made when it read \(was). They stay on the same frames.", true)
        }
        return ("This file’s start timecode now reads \(now); its markers were made at \(was). They stay on the same frames.", true)
    }
}

// MARK: - Log

public enum StartTimecodeLog {
    /// `[TIMECODE] start source=user-data user-data=1 xmp=1 unreadable=0`: the source kind and counts only, never a
    /// timecode. Written when sources 3 and 4 were read and either was present.
    public static func line(source: StartTimecodeSource?, metadata m: StartTimecodeMetadata.Result) -> String {
        "[TIMECODE] start source=\(source?.rawValue ?? "none") user-data=\(m.userDataPresent ? 1 : 0) xmp=\(m.xmpPresent ? 1 : 0) unreadable=\(m.unreadable)"
    }
}
