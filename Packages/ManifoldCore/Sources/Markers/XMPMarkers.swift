//
//  XMPMarkers.swift — Premiere's XMP markers (`xmpDM:markers`), read from the file (docs/CHAPTER_MARKERS_PLAN.md §12, Stage 3).
//
//  WHAT IS SHOWN (Robbie, 2026-11-17, supersedes D-C12): only markers of type **Chapter** and **Comment**. Segmentation,
//  WebLink, FLVCuePoint and any other type (or none) are skipped and COUNTED, never shown or converted.
//
//  WHERE THE PACKET IS (§12.1, CONFIRMED on Premiere's own files): MOV `moov/udta/XMP_`; MP4 a top-level `uuid` box with
//  Adobe's XMP UUID BE7ACFCB-97A9-42E8-9C71-999491E3AFAC. `XMPBoxWalk` walks boxes by their sizes, reading box HEADERS
//  only (and the packet itself): it never reads `mdat` or any other box's payload, and stops at the first box whose size
//  does not fit its parent.
//
//  THE PACKET CAP: `maxPacketBytes`, 8 MiB. Premiere's packets measured 8–11 KB (§16); 8 MiB is ~800× that, leaves room
//  for a long `xmpMM:History`/`Pantry`, and bounds what a hostile file can make the app allocate. Bigger: zero markers.
//
//  THE PARSE (Foundation's XMLParser, no third-party XML): external entities are never resolved
//  (`shouldResolveExternalEntities = false`, and `resolveExternalEntityName` answers nil), and a packet holding ANY
//  `<!DOCTYPE` or `<!ENTITY` is refused before the parser sees it. XMP forbids DTDs, so no real packet has one, and
//  refusing them also closes off internal entity expansion. Malformed, oversized or refused: zero markers and one
//  counts-only log line (`MarkerLog.xmp`), never an error the user sees.
//
//  UNITS (§12.1, §12.6, CONFIRMED): `xmpDM:startTime` and `xmpDM:duration` are integer frame counts at the track's
//  `xmpDM:frameRate` (`f24000s1001`, `f25`, `f30000s1001`, …), counted from the FILE'S FIRST FRAME, not from its start
//  timecode. Tolerated besides (never seen from Premiere): a count with its own rate (`186f24000s1001`) and a timecode
//  (`00:00:07:18`, `;` for drop-frame) at the track's rate.
//
//  RDF FORMS: Premiere writes every field as an attribute of an `rdf:Description` inside each `rdf:li` (§16). The
//  element form (`<xmpDM:startTime>186</xmpDM:startTime>`) and attributes on the `rdf:li` itself are read the same way.
//
//  COLOR (§12.2, §12.5, CONFIRMED A,B,G,R): the `keywordExtDVAv1_<GUID>` cuePointParam, JSON `{"color": <uint32>}`.
//
//  ⚠️ PRIVACY: names, comments and GUIDs are the file's content. Nothing here logs; callers log `Result`'s counts only.
//

import Foundation
import SMPTETimecode

// MARK: - Premiere's marker colors (§12.5, D-C13)

/// Premiere's 8 marker colors, in its dialog's order, and the decided 8→16 table (§12.5).
public enum PremiereMarkerColor: String, CaseIterable, Sendable {
    case green = "Green", red = "Red", purple = "Purple", orange = "Orange", yellow = "Yellow", white = "White",
         blue = "Blue", cyan = "Cyan"

    /// D-C13, decided 2026-11-16: Orange → Sand and Purple → Lavender (kept distinct from Red and from Resolve's vivid
    /// Purple), White → Cream, the rest by name.
    public var markerColor: MarkerColor {
        switch self {
        case .green: return .green
        case .red: return .red
        case .purple: return .lavender
        case .orange: return .sand
        case .yellow: return .yellow
        case .white: return .cream
        case .blue: return .blue
        case .cyan: return .cyan
        }
    }

    /// The three values measured on Premiere's own exports (§12.5), sRGB.
    public static let measured: [EmbeddedColor: PremiereMarkerColor] = [
        EmbeddedColor(red: 0xD2, green: 0x2C, blue: 0x36): .red,
        EmbeddedColor(red: 0xAF, green: 0x8B, blue: 0xB1): .purple,
        EmbeddedColor(red: 0xE9, green: 0x6F, blue: 0x24): .orange,
    ]

    /// Which of the 8 a decoded color is. The three measured values exactly; any other value by its hue (an INFERENCE:
    /// Green, Yellow, White, Blue and Cyan are not measured yet, so this names them by where those hues lie):
    /// White when nearly grey (saturation under 0.12); otherwise Red below 12° or from 330°, Orange to 40°, Yellow to 75°, Green to
    /// 160°, Cyan to 200°, Blue to 250°, Purple to 330°. (Measured Purple, #AF8BB1, is 297°; Orange 23°; Red 356°.)
    public init(nearest c: EmbeddedColor) {
        if let m = Self.measured[c] { self = m; return }
        let r = Double(c.red) / 255, g = Double(c.green) / 255, b = Double(c.blue) / 255
        let mx = max(r, g, b), mn = min(r, g, b), delta = mx - mn
        let saturation = mx == 0 ? 0 : delta / mx
        if saturation < 0.12 { self = .white; return }   // Premiere has no grey or black marker: any grey is White
        var hue: Double
        if mx == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if mx == g { hue = 60 * ((b - r) / delta + 2) }
        else { hue = 60 * ((r - g) / delta + 4) }
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<12: self = .red
        case ..<40: self = .orange
        case ..<75: self = .yellow
        case ..<160: self = .green
        case ..<200: self = .cyan
        case ..<250: self = .blue
        case ..<330: self = .purple
        default: self = .red
        }
    }

    /// The marker color a converted XMP item gets: its own color through the table, else D-C4's Blue.
    public static func markerColor(for c: EmbeddedColor?) -> MarkerColor {
        c.map { PremiereMarkerColor(nearest: $0).markerColor } ?? .blue
    }
}

// MARK: - Finding the packet

/// Random access to a file's bytes, so the box walk can be tested on `Data`.
public protocol XMPByteSource {
    var byteCount: UInt64 { get }
    /// Exactly `count` bytes at `offset`, or nil.
    func bytes(at offset: UInt64, count: Int) -> Data?
}

public struct XMPDataSource: XMPByteSource {
    public let data: Data
    public init(_ data: Data) { self.data = data }
    public var byteCount: UInt64 { UInt64(data.count) }
    public func bytes(at offset: UInt64, count: Int) -> Data? {
        guard count >= 0, offset <= UInt64(data.count), UInt64(count) <= UInt64(data.count) - offset else { return nil }
        let start = data.startIndex + Int(offset)
        return data.subdata(in: start..<(start + count))
    }
}

/// A file, read by seeking. Only what is asked for is read.
public final class XMPFileSource: XMPByteSource {
    private let handle: FileHandle
    public let byteCount: UInt64

    public init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url), let end = try? h.seekToEnd() else { return nil }
        handle = h
        byteCount = end
    }

    deinit { try? handle.close() }

    public func bytes(at offset: UInt64, count: Int) -> Data? {
        guard count >= 0, offset <= byteCount, UInt64(count) <= byteCount - offset else { return nil }
        do {
            try handle.seek(toOffset: offset)
            guard let d = try handle.read(upToCount: count), d.count == count else { return nil }
            return d
        } catch { return nil }
    }
}

public enum XMPBoxWalk {

    /// Adobe's XMP UUID, as the root `uuid` box's 16-byte user type.
    public static let adobeXMPUUID = Data([0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
                                           0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC])

    public enum Location: String, Equatable, Sendable {
        /// A top-level `uuid` box (Premiere's MP4s).
        case uuid
        /// `moov/udta/XMP_` (Premiere's `.mov`s).
        case udta
    }

    public enum Found: Equatable {
        case packet(Data, Location)
        /// No XMP packet in the file.
        case none
        /// A packet larger than the cap (its stated size).
        case oversized(UInt64)
        /// A box whose size does not fit (truncated or wrong), before any packet was found.
        case malformed
    }

    private struct Box { let type: String; let start: UInt64; let headerLength: UInt64; let end: UInt64 }

    private enum Walk { case box(Box), end, malformed }

    /// The box at `offset` within `[offset, limit)`. `topLevel`: a size of 0 runs to the end of the file.
    private static func box(at offset: UInt64, limit: UInt64, in src: XMPByteSource, topLevel: Bool) -> Walk {
        guard limit > offset else { return .end }
        if limit - offset < 8 { return limit - offset == 0 ? .end : .malformed }
        guard let h = src.bytes(at: offset, count: 8) else { return .malformed }
        let size32 = h.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let type = String(decoding: h.dropFirst(4), as: UTF8.self)
        var size = size32
        var hl: UInt64 = 8
        if size32 == 1 {
            guard limit - offset >= 16, let l = src.bytes(at: offset + 8, count: 8) else { return .malformed }
            size = l.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            hl = 16
        } else if size32 == 0 {
            guard topLevel else { return .malformed }
            size = limit - offset
        }
        guard size >= hl, size <= limit - offset else { return .malformed }
        return .box(Box(type: type, start: offset, headerLength: hl, end: offset + size))
    }

    /// The first XMP packet: a top-level `uuid` box with Adobe's XMP UUID, or `moov/udta/XMP_`, whichever comes first.
    /// Box headers only are read on the way; at most 100 000 boxes are visited.
    public static func find(in src: XMPByteSource, maxPacketBytes: Int = XMPMarkers.maxPacketBytes) -> Found {
        var visited = 0
        func payload(_ b: Box, skip: UInt64, _ loc: Location) -> Found {
            let size = b.end - b.start - b.headerLength - skip
            guard size <= UInt64(maxPacketBytes) else { return .oversized(size) }
            guard let d = src.bytes(at: b.start + b.headerLength + skip, count: Int(size)) else { return .malformed }
            return .packet(d, loc)
        }
        /// Walks `[start, end)`'s children, calling `visit` on each; stops at the first non-nil answer.
        func children(_ start: UInt64, _ end: UInt64, topLevel: Bool, _ visit: (Box) -> Found?) -> Found? {
            var off = start
            while true {
                visited += 1
                if visited > 100_000 { return .malformed }
                switch box(at: off, limit: end, in: src, topLevel: topLevel) {
                case .end: return nil
                case .malformed: return .malformed
                case .box(let b):
                    if let f = visit(b) { return f }
                    off = b.end
                }
            }
        }
        let top = children(0, src.byteCount, topLevel: true) { b in
            switch b.type {
            case "uuid":
                guard b.end - b.start - b.headerLength >= 16,
                      src.bytes(at: b.start + b.headerLength, count: 16) == adobeXMPUUID else { return nil }
                return payload(b, skip: 16, .uuid)
            case "moov":
                return children(b.start + b.headerLength, b.end, topLevel: false) { m in
                    guard m.type == "udta" else { return nil }
                    return children(m.start + m.headerLength, m.end, topLevel: false) { u in
                        u.type == "XMP_" ? payload(u, skip: 0, .udta) : nil
                    }
                }
            default:
                return nil   // mdat, free, ftyp, …: skipped by size, never read
            }
        }
        return top ?? .none
    }
}

// MARK: - The packet

public enum XMPMarkers {

    /// The largest XMP packet read (see the header): 8 MiB.
    public static let maxPacketBytes = 8 << 20

    public enum Status: String, Equatable, Sendable {
        /// The file has no XMP packet.
        case none
        case ok
        /// Not well-formed XML (or too deep or too large a tree).
        case malformed
        /// Larger than `maxPacketBytes`.
        case oversized
        /// It holds a DTD or an entity declaration: refused unparsed.
        case refusedDTD = "refused-dtd"
        /// A box did not fit (truncated or wrong size) before a packet was found.
        case badBoxes = "bad-boxes"
        /// The file could not be opened.
        case unreadable
    }

    /// Marker types other than Chapter and Comment, counted by fixed words only: the type string is the file's, so it
    /// never reaches the log as such.
    public struct Skipped: Equatable, Sendable {
        public var segmentation = 0
        public var weblink = 0
        public var flvCuePoint = 0
        public var cue = 0
        public var index = 0
        /// Any other type, or none stated.
        public var other = 0
        public init() {}
        public var total: Int { segmentation + weblink + flvCuePoint + cue + index + other }
    }

    public struct Result: Equatable, Sendable {
        /// Chapter and Comment markers, in file order (track by track), source `.xmp`.
        public var items: [FileChapter] = []
        public var status: Status = .none
        public var location: XMPBoxWalk.Location?
        public var packetBytes = 0
        public var tracks = 0
        public var chapters = 0
        public var comments = 0
        public var skipped = Skipped()
        /// Chapter or Comment markers whose startTime or track frameRate could not be read: dropped.
        public var unreadable = 0
        public init() {}
    }

    /// Finds and parses the file's XMP. Call it off the main thread.
    public static func read(url: URL) -> Result {
        guard let src = XMPFileSource(url: url) else { var r = Result(); r.status = .unreadable; return r }
        return read(src)
    }

    public static func read(_ src: XMPByteSource) -> Result {
        switch XMPBoxWalk.find(in: src) {
        case .none: return Result()
        case .malformed: var r = Result(); r.status = .badBoxes; return r
        case .oversized(let n):
            var r = Result(); r.status = .oversized; r.packetBytes = Int(clamping: n); return r
        case .packet(let data, let loc):
            var r = parse(data)
            r.location = loc
            return r
        }
    }

    /// Parses one XMP packet.
    public static func parse(_ packet: Data) -> Result {
        var r = Result()
        r.packetBytes = packet.count
        guard packet.count <= maxPacketBytes else { r.status = .oversized; return r }
        if containsDeclaration(packet) { r.status = .refusedDTD; return r }
        // Trailing NULs (padding some writers leave in the box) are not XML.
        var data = packet
        while let last = data.last, last == 0 { data.removeLast() }
        guard let root = XMPTree.build(data) else { r.status = .malformed; return r }
        r.status = .ok
        for tracksNode in root.descendants(ns: XMPTree.dm, name: "Tracks") {
            for track in XMPTree.items(tracksNode) {
                r.tracks += 1
                let rate = XMPTree.value(track, "frameRate").flatMap(frameRate)
                guard let markers = XMPTree.child(track, "markers") else { continue }
                for m in XMPTree.items(markers) {
                    let type = XMPTree.value(m, "type")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                    let kind: EmbeddedMarkerKind
                    switch type {
                    case "chapter": kind = .chapter
                    case "comment": kind = .comment
                    case "segmentation": r.skipped.segmentation += 1; continue
                    case "weblink": r.skipped.weblink += 1; continue
                    case "flvcuepoint": r.skipped.flvCuePoint += 1; continue
                    case "cue": r.skipped.cue += 1; continue
                    case "index": r.skipped.index += 1; continue
                    default: r.skipped.other += 1; continue
                    }
                    guard let rate, let start = XMPTree.value(m, "startTime").flatMap({ time($0, rate: rate) }),
                          start.value >= 0 else {
                        r.unreadable += 1
                        continue
                    }
                    let duration = XMPTree.value(m, "duration").flatMap { time($0, rate: rate) }.flatMap { $0.value > 0 ? $0 : nil }
                    var color: EmbeddedColor?
                    var paramGUID: String?
                    if let params = XMPTree.child(m, "cuePointParams") {
                        for p in XMPTree.items(params) {
                            guard let key = XMPTree.value(p, "key") else { continue }
                            let value = XMPTree.value(p, "value") ?? ""
                            if key.hasPrefix("keywordExtDVAv1_"), color == nil { color = colorParam(value) }
                            else if key == "marker_guid", paramGUID == nil, !value.isEmpty { paramGUID = value }
                        }
                    }
                    let guid = XMPTree.value(m, "guid").flatMap { $0.isEmpty ? nil : $0 } ?? paramGUID
                    if kind == .chapter { r.chapters += 1 } else { r.comments += 1 }
                    r.items.append(FileChapter(start: start, end: nil, title: XMPTree.value(m, "name") ?? "",
                                               source: .xmp, kind: kind, color: color, statedDuration: duration,
                                               stableID: guid, comment: XMPTree.value(m, "comment") ?? ""))
                }
            }
        }
        return r
    }

    /// `<!DOCTYPE` or `<!ENTITY` anywhere, any case (ASCII; UTF-16 packets are refused by the parser on their own if
    /// they hold one, since XMLParser is told never to load external entities).
    static func containsDeclaration(_ d: Data) -> Bool {
        let needles: [[UInt8]] = [Array("<!doctype".utf8), Array("<!entity".utf8)]
        let bytes = [UInt8](d)
        guard bytes.count >= 8 else { return false }
        for i in 0..<bytes.count where bytes[i] == 0x3C /* < */ {
            for n in needles where i + n.count <= bytes.count {
                var match = true
                for k in 1..<n.count {
                    var c = bytes[i + k]
                    if c >= 0x41 && c <= 0x5A { c += 0x20 }
                    if c != n[k] { match = false; break }
                }
                if match { return true }
            }
        }
        return false
    }

    /// `f24000s1001` → 24000/1001, `f25` → 25/1. Nil for anything else, or a zero.
    public static func frameRate(_ s: String) -> (num: Int64, den: Int64)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.first == "f" else { return nil }
        let parts = t.dropFirst().split(separator: "s", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let num = Int64(parts[0]), num > 0 else { return nil }
        let den = parts.count == 2 ? Int64(parts[1]) : 1
        guard let den, den > 0 else { return nil }
        return (num, den)
    }

    /// A marker time at the track's rate, as a `ChapterTime` (value frames × den/num seconds):
    /// - `186`: frames at the track's rate (Premiere);
    /// - `186f24000s1001` / `186f25`: frames at the rate it states;
    /// - `00:00:07:18` (`;` before the frames for drop-frame): a timecode at the track's rate, from 00:00:00:00.
    public static func time(_ s: String, rate: (num: Int64, den: Int64)) -> ChapterTime? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int64(t) { return ChapterTime(value: n, num: rate.den, den: rate.num) }
        if let f = t.firstIndex(of: "f"), let n = Int64(t[..<f]), let own = frameRate(String(t[f...])) {
            return ChapterTime(value: n, num: own.den, den: own.num)
        }
        if t.contains(":") {
            let fps = Double(rate.num) / Double(rate.den)
            let nfr = max(Int(fps.rounded()), 1)
            let drop = t.contains(";")
            guard let count = SMPTETimecode.frameCount(label: t, nfr: nfr, fps: fps, dropFrame: drop) else { return nil }
            return ChapterTime(value: Int64(count), num: rate.den, den: rate.num)
        }
        return nil
    }

    /// `{"color": 4281740498}` → A,B,G,R → sRGB (§12.5). Nil for anything else.
    public static func colorParam(_ json: String) -> EmbeddedColor? {
        guard json.utf8.count <= 4096,
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let n = obj["color"] as? NSNumber else { return nil }
        let d = n.doubleValue
        guard d >= 0, d <= Double(UInt32.max), d == d.rounded() else { return nil }
        return abgr(UInt32(d))
    }

    /// A,B,G,R (Premiere's byte order, CONFIRMED §12.5): the low byte is red.
    public static func abgr(_ v: UInt32) -> EmbeddedColor {
        EmbeddedColor(red: UInt8(v & 0xFF), green: UInt8((v >> 8) & 0xFF), blue: UInt8((v >> 16) & 0xFF))
    }
}

// MARK: - A small tree from XMLParser

/// The packet as a tree: element namespace + local name, attributes resolved to namespace + local name, text. Built by
/// XMLParser with namespaces on and external entities off; at most 64 deep and 200 000 elements.
final class XMPTree: NSObject, XMLParserDelegate {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let dm = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"

    final class Node {
        let ns: String
        let name: String
        var attributes: [(ns: String?, name: String, value: String)] = []
        var text = ""
        var children: [Node] = []
        init(ns: String, name: String) { self.ns = ns; self.name = name }

        func descendants(ns: String, name: String) -> [Node] {
            var out: [Node] = []
            var stack = children.reversed() as [Node]
            while let n = stack.popLast() {
                if n.ns == ns && n.name == name { out.append(n) } else { stack.append(contentsOf: n.children.reversed()) }
            }
            return out
        }
    }

    private let root = Node(ns: "", name: "#root")
    private var stack: [Node] = []
    private var prefixes: [String: String] = ["xml": "http://www.w3.org/XML/1998/namespace"]
    private var count = 0
    private var failed = false

    static func build(_ data: Data) -> Node? {
        let t = XMPTree()
        t.stack = [t.root]
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.shouldReportNamespacePrefixes = true
        p.shouldResolveExternalEntities = false
        p.delegate = t
        guard p.parse(), !t.failed else { return nil }
        return t.root
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix] = namespaceURI
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        count += 1
        guard count <= 200_000, stack.count <= 64 else { failed = true; parser.abortParsing(); return }
        let n = Node(ns: namespaceURI ?? "", name: elementName)
        for (key, value) in attributeDict {
            if let colon = key.firstIndex(of: ":") {
                let prefix = String(key[..<colon])
                if prefix == "xmlns" { continue }
                n.attributes.append((prefixes[prefix], String(key[key.index(after: colon)...]), value))
            } else if key != "xmlns" {
                n.attributes.append((nil, key, value))
            }
        }
        stack.last?.children.append(n)
        stack.append(n)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard stack.count > 1 else { return }
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard stack.count > 1 else { return }
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }

    // MARK: Reading RDF

    /// The `rdf:li` items of a property's `rdf:Seq`/`rdf:Bag`/`rdf:Alt`.
    static func items(_ n: Node) -> [Node] {
        n.children.filter { $0.ns == rdf && ($0.name == "Seq" || $0.name == "Bag" || $0.name == "Alt") }
            .flatMap { $0.children.filter { $0.ns == rdf && $0.name == "li" } }
    }

    /// A resource's own node and its `rdf:Description` children: where its properties may be.
    private static func holders(_ n: Node) -> [Node] {
        [n] + n.children.filter { $0.ns == rdf && $0.name == "Description" }
    }

    /// An `xmpDM:` property's text: an attribute, or a simple element (its text, or its `rdf:value`).
    static func value(_ n: Node, _ name: String) -> String? {
        for h in holders(n) {
            if let a = h.attributes.first(where: { $0.ns == dm && $0.name == name }) { return a.value }
            if let e = h.children.first(where: { $0.ns == dm && $0.name == name }) {
                if let v = e.attributes.first(where: { $0.ns == rdf && $0.name == "value" }) { return v.value }
                return e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !e.children.isEmpty
                    ? nil : e.text
            }
        }
        return nil
    }

    /// An `xmpDM:` property that is a structure or an array (`markers`, `cuePointParams`).
    static func child(_ n: Node, _ name: String) -> Node? {
        for h in holders(n) {
            if let e = h.children.first(where: { $0.ns == dm && $0.name == name }) { return e }
        }
        return nil
    }
}
