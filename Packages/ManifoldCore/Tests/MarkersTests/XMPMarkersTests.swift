import XCTest
@testable import Markers

/// Premiere's XMP markers (docs/CHAPTER_MARKERS_PLAN.md §12, §16; Stage 3): the packet parser on synthetic packets, the
/// color table, the box walk on synthetic bytes, the mapping onto the layer, Convert, and the log line. Every name,
/// comment and GUID here is synthetic.
final class XMPMarkersTests: XCTestCase {

    // §12.5's three measured values.
    static let red: UInt32 = 4281740498, purple: UInt32 = 4289825711, orange: UInt32 = 4280578025
    static let r2398 = 24000.0 / 1001

    // MARK: Packet builders (Premiere's form: attributes on rdf:Description, §16)

    static func marker(_ type: String?, _ start: String, name: String = "", comment: String = "", duration: String? = nil,
                       guid: String? = nil, paramGUID: String? = nil, color: UInt32? = nil) -> String {
        var a = "xmpDM:startTime=\"\(start)\" xmpDM:name=\"\(name)\""
        if let type { a += " xmpDM:type=\"\(type)\"" }
        if let duration { a += " xmpDM:duration=\"\(duration)\"" }
        if !comment.isEmpty { a += " xmpDM:comment=\"\(comment.replacingOccurrences(of: "\n", with: "&#xA;"))\"" }
        if let guid { a += " xmpDM:guid=\"\(guid)\"" }
        var lis = ""
        if let paramGUID { lis += "<rdf:li xmpDM:key=\"marker_guid\" xmpDM:value=\"\(paramGUID)\"/>" }
        if let color {
            lis += "<rdf:li xmpDM:key=\"keywordExtDVAv1_1A2B\" xmpDM:value=\"{&quot;color&quot;:\(color)}\"/>"
        }
        let params = lis.isEmpty ? "" : "<xmpDM:cuePointParams><rdf:Seq>\(lis)</rdf:Seq></xmpDM:cuePointParams>"
        return "<rdf:li><rdf:Description \(a)>\(params)</rdf:Description></rdf:li>"
    }

    static func track(_ rate: String?, _ markers: [String]) -> String {
        let r = rate.map { " xmpDM:frameRate=\"\($0)\"" } ?? ""
        return "<rdf:li><rdf:Description xmpDM:trackName=\"Markers\"\(r)><xmpDM:markers><rdf:Seq>"
            + markers.joined() + "</rdf:Seq></xmpDM:markers></rdf:Description></rdf:li>"
    }

    static func packet(_ tracks: [String], prefix: String = "xmpDM") -> Data {
        var s = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/">
        <xmpDM:startTimecode xmpDM:timeFormat="23976Timecode" xmpDM:timeValue="00:00:00:00"/>
        <xmpDM:Tracks><rdf:Bag>\(tracks.joined())</rdf:Bag></xmpDM:Tracks>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
        if prefix != "xmpDM" { s = s.replacingOccurrences(of: "xmpDM", with: prefix) }
        return Data(s.utf8)
    }

    // MARK: Parser

    func testChapterAndCommentWithAndWithoutDurationOthersSkippedAndCounted() {
        let p = Self.packet([Self.track("f24000s1001", [
            Self.marker("Comment", "78", name: "c0", comment: "line one\nline two", guid: "g0", color: Self.red),
            Self.marker("Chapter", "197", name: "c1", comment: "chapter words", guid: "g1", color: Self.orange),
            Self.marker("Segmentation", "325", name: "c2", guid: "g2", color: Self.purple),
            Self.marker("WebLink", "501", name: "c3", guid: "g3", color: Self.orange),
            Self.marker("Comment", "186", name: "ranged", duration: "96", guid: "g4", color: Self.red),
            Self.marker("FLVCuePoint", "10", name: "flv"),
            Self.marker("Cue", "11"), Self.marker("Index", "12"), Self.marker("Something", "13"), Self.marker(nil, "14"),
        ])])
        let r = XMPMarkers.parse(p)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.tracks, 1)
        XCTAssertEqual(r.items.map(\.kind), [.comment, .chapter, .comment])
        XCTAssertEqual(r.chapters, 1)
        XCTAssertEqual(r.comments, 2)
        XCTAssertEqual(r.skipped.segmentation, 1)
        XCTAssertEqual(r.skipped.weblink, 1)
        XCTAssertEqual(r.skipped.flvCuePoint, 1)
        XCTAssertEqual(r.skipped.cue, 1)
        XCTAssertEqual(r.skipped.index, 1)
        XCTAssertEqual(r.skipped.other, 2, "an unknown type and a missing one")
        XCTAssertEqual(r.skipped.total, 7)
        // Frames at the track's rate: value frames × 1001/24000 s.
        XCTAssertEqual(r.items[0].start, ChapterTime(value: 78, num: 1001, den: 24000))
        XCTAssertNil(r.items[0].statedDuration, "a point marker has no duration element")
        XCTAssertEqual(r.items[2].statedDuration, ChapterTime(value: 96, num: 1001, den: 24000))
        XCTAssertEqual(r.items.map(\.title), ["c0", "c1", "ranged"])
        XCTAssertEqual(r.items[0].comment, "line one\nline two", "the comment as stated, line break kept")
        XCTAssertEqual(r.items.map(\.stableID), ["g0", "g1", "g4"])
        XCTAssertEqual(Set(r.items.map(\.source)), [.xmp])
        XCTAssertNil(r.items[0].end)
    }

    func testColorsDecodeAsABGRAgainstTheThreeMeasuredValues() {
        // §12.5: Red #D22C36, Purple #AF8BB1, Orange #E96F24.
        XCTAssertEqual(XMPMarkers.abgr(Self.red), EmbeddedColor(red: 0xD2, green: 0x2C, blue: 0x36))
        XCTAssertEqual(XMPMarkers.abgr(Self.purple), EmbeddedColor(red: 0xAF, green: 0x8B, blue: 0xB1))
        XCTAssertEqual(XMPMarkers.abgr(Self.orange), EmbeddedColor(red: 0xE9, green: 0x6F, blue: 0x24))
        XCTAssertEqual(XMPMarkers.colorParam("{\"color\":4281740498}"), EmbeddedColor(red: 0xD2, green: 0x2C, blue: 0x36))
        XCTAssertEqual(XMPMarkers.colorParam("{\"color\": 4289825711 }"), EmbeddedColor(red: 0xAF, green: 0x8B, blue: 0xB1))
        for bad in ["", "{}", "{\"color\":-1}", "{\"color\":4294967296}", "{\"color\":1.5}", "{\"color\":\"red\"}", "[1]", "nope"] {
            XCTAssertNil(XMPMarkers.colorParam(bad), bad)
        }
        // Through the parser: no color param, no color (drawn neutral).
        let r = XMPMarkers.parse(Self.packet([Self.track("f25", [Self.marker("Chapter", "1", color: Self.purple),
                                                                 Self.marker("Chapter", "2")])]))
        XCTAssertEqual(r.items.map(\.color), [EmbeddedColor(red: 0xAF, green: 0x8B, blue: 0xB1), nil])
    }

    func testGUIDFromTheAttributeElseTheMarkerGUIDParam() {
        let r = XMPMarkers.parse(Self.packet([Self.track("f25", [
            Self.marker("Chapter", "1", guid: "attr", paramGUID: "param"),
            Self.marker("Chapter", "2", paramGUID: "param-only"),
            Self.marker("Chapter", "3"),
        ])]))
        XCTAssertEqual(r.items.map(\.stableID), ["attr", "param-only", nil])
    }

    func testMultipleTracksEachAtItsOwnRate() {
        let r = XMPMarkers.parse(Self.packet([
            Self.track("f25", [Self.marker("Chapter", "50")]),
            Self.track("f30000s1001", [Self.marker("Comment", "60")]),
            Self.track(nil, [Self.marker("Chapter", "70")]),        // no frameRate: unreadable, dropped
        ]))
        XCTAssertEqual(r.tracks, 3)
        XCTAssertEqual(r.items.map(\.start), [ChapterTime(value: 50, num: 1, den: 25),
                                              ChapterTime(value: 60, num: 1001, den: 30000)])
        XCTAssertEqual(r.unreadable, 1)
    }

    func testFrameRateForms() {
        XCTAssertTrue(XMPMarkers.frameRate("f24000s1001")! == (24000, 1001))
        XCTAssertTrue(XMPMarkers.frameRate("f25")! == (25, 1))
        XCTAssertTrue(XMPMarkers.frameRate("f30000s1001")! == (30000, 1001))
        XCTAssertTrue(XMPMarkers.frameRate("f60000s1001")! == (60000, 1001))
        XCTAssertTrue(XMPMarkers.frameRate(" f50 ")! == (50, 1))
        XCTAssertTrue(XMPMarkers.frameRate("f254016000000")! == (254_016_000_000, 1))
        for bad in ["", "25", "f", "fs", "f0", "f25s0", "f25s", "fxs1", "f-25", "f25s1001s2", "24000/1001"] {
            XCTAssertNil(XMPMarkers.frameRate(bad), bad)
        }
    }

    func testStartTimeForms() {
        let r = (num: Int64(24000), den: Int64(1001))
        XCTAssertEqual(XMPMarkers.time("186", rate: r), ChapterTime(value: 186, num: 1001, den: 24000))
        // A count with its own rate.
        XCTAssertEqual(XMPMarkers.time("50f25", rate: r), ChapterTime(value: 50, num: 1, den: 25))
        XCTAssertEqual(XMPMarkers.time("186f24000s1001", rate: r), ChapterTime(value: 186, num: 1001, den: 24000))
        // A timecode at the track's rate: 00:00:07:18 at 24 is frame 186.
        XCTAssertEqual(XMPMarkers.time("00:00:07:18", rate: r), ChapterTime(value: 186, num: 1001, den: 24000))
        // Drop-frame at 29.97: 00:01:00;02 is frame 1800.
        XCTAssertEqual(XMPMarkers.time("00:01:00;02", rate: (30000, 1001)), ChapterTime(value: 1800, num: 1001, den: 30000))
        for bad in ["", "abc", "1.5", "12s", "f25"] { XCTAssertNil(XMPMarkers.time(bad, rate: r), bad) }
        // An unreadable startTime drops the marker and counts it.
        let p = XMPMarkers.parse(Self.packet([Self.track("f25", [Self.marker("Chapter", "soon"), Self.marker("Comment", "-3"),
                                                                 Self.marker("Chapter", "4")])]))
        XCTAssertEqual(p.items.count, 1)
        XCTAssertEqual(p.unreadable, 2, "unparseable and negative")
    }

    func testZeroOrUnreadableDurationIsNoDuration() {
        let r = XMPMarkers.parse(Self.packet([Self.track("f25", [Self.marker("Comment", "1", duration: "0"),
                                                                 Self.marker("Comment", "2", duration: "x")])]))
        XCTAssertEqual(r.items.map(\.statedDuration), [nil, nil])
    }

    func testElementFormAndAnyPrefix() {
        // Properties as elements in an rdf:parseType="Resource" li, with the namespace bound to another prefix.
        let s = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dm="http://ns.adobe.com/xmp/1.0/DynamicMedia/">
         <dm:Tracks><rdf:Bag><rdf:li rdf:parseType="Resource">
          <dm:frameRate>f25</dm:frameRate>
          <dm:markers><rdf:Seq>
           <rdf:li rdf:parseType="Resource">
            <dm:startTime>  40 </dm:startTime><dm:duration>10</dm:duration><dm:type>Comment</dm:type>
            <dm:name>element</dm:name><dm:comment>two
        lines</dm:comment>
            <dm:cuePointParams><rdf:Seq>
             <rdf:li rdf:parseType="Resource"><dm:key>keywordExtDVAv1_X</dm:key><dm:value>{"color":4281740498}</dm:value></rdf:li>
             <rdf:li rdf:parseType="Resource"><dm:key>marker_guid</dm:key><dm:value>eg</dm:value></rdf:li>
            </rdf:Seq></dm:cuePointParams>
           </rdf:li>
          </rdf:Seq></dm:markers>
         </rdf:li></rdf:Bag></dm:Tracks>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let r = XMPMarkers.parse(Data(s.utf8))
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.items.count, 1)
        let c = r.items[0]
        XCTAssertEqual(c.kind, .comment)
        XCTAssertEqual(c.start, ChapterTime(value: 40, num: 1, den: 25))
        XCTAssertEqual(c.statedDuration, ChapterTime(value: 10, num: 1, den: 25))
        XCTAssertEqual(c.title, "element")
        XCTAssertEqual(c.comment, "two\nlines")
        XCTAssertEqual(c.stableID, "eg")
        XCTAssertEqual(c.color, EmbeddedColor(red: 0xD2, green: 0x2C, blue: 0x36))
        // The attribute form under another prefix too.
        let other = XMPMarkers.parse(Self.packet([Self.track("f25", [Self.marker("Chapter", "5")])], prefix: "q"))
        XCTAssertEqual(other.items.count, 1)
    }

    func testTypeIsCaseInsensitiveAndAWrongNamespaceIsNotRead() {
        let r = XMPMarkers.parse(Self.packet([Self.track("f25", [Self.marker("chapter", "1"), Self.marker("COMMENT", "2")])]))
        XCTAssertEqual(r.items.map(\.kind), [.chapter, .comment])
        // The same structure in a namespace that is not xmpDM's: nothing.
        let wrong = String(decoding: Self.packet([Self.track("f25", [Self.marker("Chapter", "1")])]), as: UTF8.self)
            .replacingOccurrences(of: "http://ns.adobe.com/xmp/1.0/DynamicMedia/", with: "http://example.com/notdm/")
        let w = XMPMarkers.parse(Data(wrong.utf8))
        XCTAssertEqual(w.status, .ok)
        XCTAssertEqual(w.items.count, 0)
        XCTAssertEqual(w.tracks, 0)
    }

    func testMalformedXMLGivesZeroMarkers() {
        for bad in ["<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><unclosed>", "not xml at all", "", "<a></b>",
                    String(decoding: Self.packet([Self.track("f25", [Self.marker("Chapter", "1")])]), as: UTF8.self).dropLast(40).description] {
            let r = XMPMarkers.parse(Data(bad.utf8))
            XCTAssertEqual(r.status, .malformed, bad)
            XCTAssertEqual(r.items.count, 0, bad)
        }
    }

    func testTooDeepIsMalformed() {
        let deep = String(repeating: "<a>", count: 100) + String(repeating: "</a>", count: 100)
        XCTAssertEqual(XMPMarkers.parse(Data(deep.utf8)).status, .malformed)
    }

    func testTrailingNULPaddingIsIgnored() {
        var p = Self.packet([Self.track("f25", [Self.marker("Chapter", "1")])])
        p.append(Data(repeating: 0, count: 32))
        XCTAssertEqual(XMPMarkers.parse(p).items.count, 1)
    }

    func testAnExternalEntityIsNeverResolved() throws {
        // A file with a sentinel the entity would pull in.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xmp-entity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("secret.txt")
        let sentinel = "SENTINEL-ENTITY-7f3a"
        try Data(sentinel.utf8).write(to: secret)
        let s = """
        <?xml version="1.0"?>
        <!DOCTYPE x:xmpmeta [ <!ENTITY e SYSTEM "\(secret.absoluteString)"> ]>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/">
        <xmpDM:Tracks><rdf:Bag><rdf:li rdf:parseType="Resource"><xmpDM:frameRate>f25</xmpDM:frameRate>
        <xmpDM:markers><rdf:Seq><rdf:li rdf:parseType="Resource"><xmpDM:startTime>1</xmpDM:startTime>
        <xmpDM:type>Chapter</xmpDM:type><xmpDM:name>&e;</xmpDM:name></rdf:li></rdf:Seq></xmpDM:markers>
        </rdf:li></rdf:Bag></xmpDM:Tracks></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        // The packet is refused before parsing: zero markers.
        let r = XMPMarkers.parse(Data(s.utf8))
        XCTAssertEqual(r.status, .refusedDTD)
        XCTAssertEqual(r.items.count, 0)
        // And the parser itself, given it anyway, does not load the file.
        if let root = XMPTree.build(Data(s.utf8)) {
            var stack = [root]
            while let n = stack.popLast() {
                XCTAssertFalse(n.text.contains(sentinel))
                XCTAssertFalse(n.attributes.contains { $0.value.contains(sentinel) })
                stack.append(contentsOf: n.children)
            }
        }
        // An internal entity declaration is refused too (no expansion at all), in any case.
        XCTAssertEqual(XMPMarkers.parse(Data("<!doctype a [<!entity x \"y\">]><a>&x;</a>".utf8)).status, .refusedDTD)
    }

    func testOversizedPacketGivesZeroMarkers() {
        var big = Self.packet([Self.track("f25", [Self.marker("Chapter", "1")])])
        big.append(Data(repeating: 0x20, count: XMPMarkers.maxPacketBytes))
        let r = XMPMarkers.parse(big)
        XCTAssertEqual(r.status, .oversized)
        XCTAssertEqual(r.items.count, 0)
        XCTAssertEqual(XMPMarkers.maxPacketBytes, 8 << 20)
    }

    // MARK: Premiere's 8 colors → Resolve's 16 (§12.5, D-C13)

    func testTheDecidedEightToSixteenTable() {
        let table: [PremiereMarkerColor: MarkerColor] = [.green: .green, .red: .red, .purple: .lavender, .orange: .sand,
                                                         .yellow: .yellow, .white: .cream, .blue: .blue, .cyan: .cyan]
        for (p, m) in table { XCTAssertEqual(p.markerColor, m, p.rawValue) }
        XCTAssertEqual(Set(table.values).count, 8, "one-to-one: Premiere's eight stay distinct")
        XCTAssertEqual(PremiereMarkerColor.allCases.map(\.rawValue),
                       ["Green", "Red", "Purple", "Orange", "Yellow", "White", "Blue", "Cyan"], "the dialog's order")
    }

    func testMeasuredValuesExactlyAndTheRestByHue() {
        XCTAssertEqual(PremiereMarkerColor(nearest: XMPMarkers.abgr(Self.red)), .red)
        XCTAssertEqual(PremiereMarkerColor(nearest: XMPMarkers.abgr(Self.purple)), .purple)
        XCTAssertEqual(PremiereMarkerColor(nearest: XMPMarkers.abgr(Self.orange)), .orange)
        // Not measured yet: by hue (an inference, §16).
        let cases: [(UInt8, UInt8, UInt8, PremiereMarkerColor)] = [
            (0x33, 0xCC, 0x33, .green), (0xE6, 0xC6, 0x19, .yellow), (0xF0, 0xF0, 0xF0, .white), (0x80, 0x80, 0x80, .white),
            (0x2D, 0x6B, 0xE0, .blue), (0x19, 0xC8, 0xD2, .cyan), (0xE0, 0x10, 0x10, .red), (0xE0, 0x10, 0x40, .red),
            (0x90, 0x30, 0xE0, .purple), (0xF0, 0x90, 0x20, .orange),
        ]
        for (r, g, b, want) in cases {
            XCTAssertEqual(PremiereMarkerColor(nearest: EmbeddedColor(red: r, green: g, blue: b)), want, "\(r) \(g) \(b)")
        }
        XCTAssertEqual(PremiereMarkerColor.markerColor(for: nil), .blue, "no color: D-C4's Blue")
    }

    // MARK: Box walk (synthetic bytes)

    static func box(_ type: String, _ payload: Data) -> Data {
        var d = Data()
        withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: Array(type.utf8))
        return d + payload
    }

    static func largeBox(_ type: String, _ payload: Data) -> Data {
        var d = Data()
        withUnsafeBytes(of: UInt32(1).bigEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: Array(type.utf8))
        withUnsafeBytes(of: UInt64(16 + payload.count).bigEndian) { d.append(contentsOf: $0) }
        return d + payload
    }

    static let xmp = packet([track("f25", [marker("Chapter", "1")])])
    static let ftyp = box("ftyp", Data("isom\0\0\0\0isom".utf8))
    static let mdatPayload = Data(repeating: 0xAB, count: 4096)

    /// Records every read, so a test can say what was never read.
    final class Recording: XMPByteSource {
        let inner: XMPDataSource
        var reads: [(UInt64, Int)] = []
        init(_ d: Data) { inner = XMPDataSource(d) }
        var byteCount: UInt64 { inner.byteCount }
        func bytes(at offset: UInt64, count: Int) -> Data? { reads.append((offset, count)); return inner.bytes(at: offset, count: count) }
    }

    func testRootUUIDAfterMdatIsFoundAndTheMediaIsNeverRead() {
        let mdat = Self.box("mdat", Self.mdatPayload)
        let file = Self.ftyp + mdat + Self.box("moov", Self.box("mvhd", Data(count: 100)))
            + Self.box("uuid", XMPBoxWalk.adobeXMPUUID + Self.xmp)
        let src = Recording(file)
        XCTAssertEqual(XMPBoxWalk.find(in: src), .packet(Self.xmp, .uuid))
        let mdatStart = UInt64(Self.ftyp.count + 8), mdatEnd = mdatStart + UInt64(Self.mdatPayload.count)
        for (o, n) in src.reads { XCTAssertFalse(o < mdatEnd && o + UInt64(n) > mdatStart, "read \(n) at \(o) inside mdat") }
        XCTAssertEqual(XMPMarkers.read(src).items.count, 1)
        XCTAssertEqual(XMPMarkers.read(src).location, .uuid)
    }

    func testMoovUdtaXMPIsFound() {
        let udta = Self.box("udta", Self.box("name", Data("x".utf8)) + Self.box("XMP_", Self.xmp))
        let moov = Self.box("moov", Self.box("mvhd", Data(count: 100)) + Self.box("trak", Data(count: 40)) + udta)
        let file = Self.ftyp + Self.box("wide", Data()) + Self.box("mdat", Self.mdatPayload) + moov
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(file)), .packet(Self.xmp, .udta))
        // An XMP_ inside a trak's udta is not the movie's: only moov/udta is read.
        let trakOnly = Self.ftyp + Self.box("moov", Self.box("trak", Self.box("udta", Self.box("XMP_", Self.xmp))))
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(trakOnly)), XMPBoxWalk.Found.none)
    }

    func testAnotherUUIDIsNotXMPAndLargeAndZeroSizesWalk() {
        let other = Self.box("uuid", Data(repeating: 0x11, count: 16) + Self.xmp)
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(Self.ftyp + other)), XMPBoxWalk.Found.none)
        // A 64-bit mdat, then the XMP box; and the XMP box as a size-0 "to the end" last box.
        let large = Self.ftyp + Self.largeBox("mdat", Self.mdatPayload) + Self.box("uuid", XMPBoxWalk.adobeXMPUUID + Self.xmp)
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(large)), .packet(Self.xmp, .uuid))
        var toEnd = Self.box("uuid", XMPBoxWalk.adobeXMPUUID + Self.xmp)
        toEnd.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(Self.ftyp + toEnd)), .packet(Self.xmp, .uuid))
        // No XMP at all.
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(Self.ftyp + Self.box("mdat", Self.mdatPayload))), XMPBoxWalk.Found.none)
        XCTAssertEqual(XMPMarkers.read(XMPDataSource(Data())).status, XMPMarkers.Status.none)
    }

    func testTruncatedAndWrongSizeBoxesGiveZeroMarkers() {
        let good = Self.ftyp + Self.box("mdat", Self.mdatPayload) + Self.box("uuid", XMPBoxWalk.adobeXMPUUID + Self.xmp)
        // Truncated: the file ends inside the XMP box.
        let truncated = good.prefix(good.count - 10)
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(Data(truncated))), .malformed)
        XCTAssertEqual(XMPMarkers.read(XMPDataSource(Data(truncated))).status, .badBoxes)
        XCTAssertEqual(XMPMarkers.read(XMPDataSource(Data(truncated))).items.count, 0)
        // mdat claiming more than the file: the walk stops there, before the XMP box.
        var long = good
        long.replaceSubrange(Self.ftyp.count..<(Self.ftyp.count + 4), with: [0x7F, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(long)), .malformed)
        // A size smaller than its own header.
        var tiny = good
        tiny.replaceSubrange(Self.ftyp.count..<(Self.ftyp.count + 4), with: [0, 0, 0, 4])
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(tiny)), .malformed)
        // A 64-bit size smaller than its 16-byte header.
        var bad64 = Self.ftyp + Self.largeBox("mdat", Self.mdatPayload)
        bad64.replaceSubrange((Self.ftyp.count + 8)..<(Self.ftyp.count + 16), with: [0, 0, 0, 0, 0, 0, 0, 9])
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(bad64)), .malformed)
        // A child that overruns moov.
        var moov = Self.box("moov", Self.box("udta", Self.box("XMP_", Self.xmp)))
        moov.replaceSubrange(8..<12, with: [0, 0, 0x7F, 0xFF])   // udta's size, now far past moov's end
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(Self.ftyp + moov)), .malformed)
        // A size 0 is "to the end" only at the top level.
        var zeroChild = Self.box("moov", Self.box("udta", Self.box("XMP_", Self.xmp)))
        zeroChild.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(Self.ftyp + zeroChild)), .malformed)
        // A uuid box too short for its 16-byte user type is not XMP.
        XCTAssertEqual(XMPBoxWalk.find(in: XMPDataSource(Self.ftyp + Self.box("uuid", Data(count: 4)))), XMPBoxWalk.Found.none)
    }

    func testAnOversizedPacketIsNeverRead() {
        /// Claims a file of 1 GB whose one box is a 1 GB XMP uuid; only its header and user type are readable.
        final class Huge: XMPByteSource {
            var largestRead = 0
            let header: Data
            init() {
                var h = Data()
                withUnsafeBytes(of: UInt32(1 << 30).bigEndian) { h.append(contentsOf: $0) }
                h.append(contentsOf: Array("uuid".utf8))
                header = h + XMPBoxWalk.adobeXMPUUID
            }
            var byteCount: UInt64 { 1 << 30 }
            func bytes(at offset: UInt64, count: Int) -> Data? {
                largestRead = max(largestRead, count)
                guard offset + UInt64(count) <= UInt64(header.count) else { return nil }
                return header.subdata(in: Int(offset)..<(Int(offset) + count))
            }
        }
        let src = Huge()
        XCTAssertEqual(XMPBoxWalk.find(in: src), .oversized(UInt64(1 << 30) - 24))
        XCTAssertLessThanOrEqual(src.largestRead, 16)
        let r = XMPMarkers.read(src)
        XCTAssertEqual(r.status, .oversized)
        XCTAssertEqual(r.items.count, 0)
    }

    // MARK: Mapping onto the layer

    func testSameRateFrameIsTheStartAndAStatedDurationIsTheBand() {
        let p = XMPMarkers.parse(Self.packet([Self.track("f24000s1001", [
            Self.marker("Comment", "186", duration: "96", color: Self.red),     // §12.6's ranged marker
            Self.marker("Chapter", "197"),
            Self.marker("Comment", "300"),
        ])]))
        let r = ChapterMapping.map(p.items, rate: Self.r2398, lastFrame: 719)
        XCTAssertEqual(r.chapters.map(\.frame), [186, 197, 300])
        XCTAssertEqual(r.chapters[0].statedDuration, 96, "a stated duration: a band (D-C16)")
        XCTAssertEqual(r.chapters[0].duration, 96)
        XCTAssertNil(r.chapters[1].statedDuration, "a chapter with no duration: no band")
        XCTAssertEqual(r.chapters[1].duration, 720 - 197, "it runs to the end (no later chapter; a comment doesn't end it)")
        XCTAssertNil(r.chapters[2].statedDuration)
        XCTAssertEqual(r.chapters[2].duration, 1, "a comment with no duration is one frame")
    }

    func testOtherRatesAreRescaledByExactFloor() {
        // 27 frames at 30 = 0.9 s = 21.6 frames at 24: frame 21 (the tolerant rule would give 22).
        let item = FileChapter(start: ChapterTime(value: 27, num: 1, den: 30), end: nil, title: "", source: .xmp)
        XCTAssertEqual(ChapterMapping.map([item], rate: 24, lastFrame: 999).chapters.first?.frame, 21)
        var track = item; track.source = .chapterTrack
        XCTAssertEqual(ChapterMapping.map([track], rate: 24, lastFrame: 999).chapters.first?.frame, 22, "chapters keep D-C7a")
        // 50 frames at 25 = 2 s: frame 100 at 50, 47 at 23.976 (47.95), 59 at 29.97 (59.94).
        let two = FileChapter(start: ChapterTime(value: 50, num: 1, den: 25), end: nil, title: "", source: .xmp, kind: .comment,
                              statedDuration: ChapterTime(value: 25, num: 1, den: 25))
        XCTAssertEqual(ChapterMapping.map([two], rate: 50, lastFrame: 999).chapters.first?.frame, 100)
        XCTAssertEqual(ChapterMapping.map([two], rate: 50, lastFrame: 999).chapters.first?.statedDuration, 50)
        XCTAssertEqual(ChapterMapping.map([two], rate: Self.r2398, lastFrame: 999).chapters.first?.frame, 47)
        // End floored too, duration = end − start: 3 s × 23.976 = 71.93 → 71; 71 − 47 = 24.
        XCTAssertEqual(ChapterMapping.map([two], rate: Self.r2398, lastFrame: 999).chapters.first?.statedDuration, 24)
        XCTAssertEqual(ChapterMapping.map([two], rate: 30000.0 / 1001, lastFrame: 999).chapters.first?.frame, 59)
    }

    func testXMPTakesNoOriginWhileChaptersDo() {
        // §12.6: XMP counts from the first frame. A 1 s origin moves a chapter-track chapter, never an XMP item.
        let origin = ChapterTime(value: 1, num: 1, den: 1)
        let items = [FileChapter(start: ChapterTime(value: 2000, num: 1, den: 1000), end: nil, title: "track"),
                     FileChapter(start: ChapterTime(value: 50, num: 1, den: 25), end: nil, title: "xmp", source: .xmp)]
        let r = ChapterMapping.map(items, origin: origin, rate: 25, lastFrame: 999)
        XCTAssertEqual(r.chapters.map(\.frame), [25, 50])
        XCTAssertEqual(r.chapters.map(\.title), ["track", "xmp"])
    }

    func testPastTheEndIsDroppedAndCounted() {
        let p = XMPMarkers.parse(Self.packet([Self.track("f24000s1001", [Self.marker("Chapter", "10"), Self.marker("Comment", "719"),
                                                                         Self.marker("Comment", "720"), Self.marker("Chapter", "5000")])]))
        let r = ChapterMapping.map(p.items, rate: Self.r2398, lastFrame: 719)
        XCTAssertEqual(r.chapters.map(\.frame), [10, 719])
        XCTAssertEqual(r.droppedPastEnd, 2)
        XCTAssertEqual(r.chaptersPastEnd, 1, "one of them a chapter")
    }

    func testAChapterTrackChapterOnAnXMPChaptersFrameIsShownOnceAsTheXMPOne() {
        // Premiere's .mov (§11.3): chapter track 101101/24000 (frame 101) and XMP Chapter 101, agreeing to the frame.
        let track = [FileChapter(start: ChapterTime(value: 101_101, num: 1, den: 24000), end: nil, title: "A"),
                     FileChapter(start: ChapterTime(value: 280_280, num: 1, den: 24000), end: nil, title: "B"),
                     FileChapter(start: ChapterTime(value: 0, num: 1, den: 10_000_000), end: nil, title: "C", source: .chpl)]
        let orange = XMPMarkers.abgr(Self.orange)
        let xmp = [FileChapter(start: ChapterTime(value: 101, num: 1001, den: 24000), end: nil, title: "A", source: .xmp,
                               color: orange, stableID: "g-a"),
                   // A Comment on a chapter's frame is not the same marker: both shown.
                   FileChapter(start: ChapterTime(value: 280, num: 1001, den: 24000), end: nil, title: "note", source: .xmp,
                               kind: .comment),
                   // An XMP Chapter on frame 0 replaces the chpl one there too.
                   FileChapter(start: ChapterTime(value: 0, num: 1001, den: 24000), end: nil, title: "C", source: .xmp)]
        let r = ChapterMapping.map(track + xmp, rate: Self.r2398, lastFrame: 719)
        XCTAssertEqual(r.duplicates, 2)
        XCTAssertEqual(r.chapters.map(\.frame), [0, 101, 280, 280])
        XCTAssertEqual(r.chapters.map(\.source), [.xmp, .xmp, .chapterTrack, .xmp])
        XCTAssertEqual(r.chapters[1].color, orange, "the XMP one, with its color and id")
        XCTAssertEqual(r.chapters[1].stableID, "g-a")
        // The XMP chapter at 101 still runs to the next chapter (280), not to the comment.
        XCTAssertEqual(r.chapters[1].duration, 179)
        XCTAssertEqual(r.dropped, 0, "duplicates are not drops")
    }

    // MARK: Convert

    func testConvertUsesTheColorTableKeywordNotesAndDuration() {
        let items = [
            MappedChapter(fileIndex: 0, frame: 10, duration: 96, title: "ranged", source: .xmp, kind: .comment,
                          color: XMPMarkers.abgr(Self.red), statedDuration: 96, stableID: "g-1", comment: "line one\nline two"),
            MappedChapter(fileIndex: 1, frame: 20, duration: 50, title: "act", source: .xmp, kind: .chapter,
                          color: XMPMarkers.abgr(Self.orange), stableID: "g-2", comment: "chapter note"),
            MappedChapter(fileIndex: 2, frame: 30, duration: 1, title: "lav", source: .xmp, kind: .comment,
                          color: XMPMarkers.abgr(Self.purple), stableID: "g-3"),
            MappedChapter(fileIndex: 3, frame: 40, duration: 1, title: "none", source: .xmp, kind: .comment, stableID: "g-4"),
            MappedChapter(fileIndex: 4, frame: 50, duration: 9, title: "track"),
        ]
        let r = ChapterMapping.convert(items, into: [])
        XCTAssertEqual(r.added.map(\.color), [.red, .sand, .lavender, .blue, .blue])
        XCTAssertEqual(r.added.map(\.keywords), [["comment"], ["chapter"], ["comment"], ["comment"], ["chapter"]])
        XCTAssertEqual(r.added.map(\.notes), ["line one\nline two", "chapter note", "", "", ""])
        XCTAssertEqual(r.added.map(\.name), ["ranged", "act", "lav", "none", "track"])
        XCTAssertEqual(r.added.map(\.duration), [96, 50, 1, 1, 9])
        XCTAssertEqual(r.added.map(\.embeddedID), ["g-1", "g-2", "g-3", "g-4", nil])
        // A second Convert skips every XMP item by its id (D-C14); the chapter-track one merges by frame and name.
        let again = ChapterMapping.convert(items, into: r.added)
        XCTAssertEqual(again.added.count, 0)
        XCTAssertEqual(again.alreadyConverted, 4)
        XCTAssertEqual(again.identical, 1)
    }

    // MARK: Privacy

    func testXMPLogLineHoldsCountsOnly() {
        let sentinel = "SENTINEL-XMP-5b1d"
        let p = XMPMarkers.parse(Self.packet([Self.track("f25", [
            Self.marker("Chapter", "1", name: sentinel, comment: sentinel, guid: sentinel, color: Self.red),
            Self.marker("Comment", "2", name: sentinel, comment: sentinel, paramGUID: sentinel),
            Self.marker("WebLink", "3", name: sentinel), Self.marker(sentinel, "4", name: sentinel),
        ])]))
        let line = MarkerLog.xmp(p, readMs: 2)
        XCTAssertFalse(line.contains(sentinel))
        XCTAssertEqual(line, "[MARKERS] xmp status=ok where=- bytes=\(p.packetBytes) tracks=1 chapter=1 comment=1 unreadable=0 "
                       + "skipped=2 segmentation=0 weblink=1 flvcuepoint=0 cue=0 index=0 other=1 read=2ms")
        let mapped = ChapterMapping.map(p.items, rate: 25, lastFrame: 99)
        XCTAssertFalse(MarkerLog.chapters(mapped, readMs: 1).contains(sentinel))
        let conv = ChapterMapping.convert(mapped.chapters, into: [])
        XCTAssertFalse(MarkerLog.convertedChapters(conv).contains(sentinel))
        XCTAssertFalse(ChapterLayer.convertNotice(conv).contains(sentinel))
        var bad = XMPMarkers.Result(); bad.status = .malformed; bad.packetBytes = 12
        XCTAssertEqual(MarkerLog.xmp(bad, readMs: 0), "[MARKERS] xmp status=malformed where=- bytes=12 tracks=0 chapter=0 comment=0 "
                       + "unreadable=0 skipped=0 segmentation=0 weblink=0 flvcuepoint=0 cue=0 index=0 other=0 read=0ms")
    }
}
