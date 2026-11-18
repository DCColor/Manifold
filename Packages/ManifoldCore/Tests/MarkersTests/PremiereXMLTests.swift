import XCTest
@testable import Markers
import SMPTETimecode

/// docs/MARKER_EXPORT_PLAN.md §6.2: the Premiere xmeml writer. Golden files in `Fixtures/premiere-*.xml` are the
/// writer's own output: they catch regressions only, and become the reference once P2 imports them (§6.3). Every name,
/// note and path here is synthetic.
///
/// To regenerate the golden files after an intended change: `MANIFOLD_WRITE_GOLDEN=1 swift test --filter PremiereXMLTests`,
/// then read the diff before committing it.
final class PremiereXMLTests: XCTestCase {

    static let r2398 = 24000.0 / 1001
    static let r2997 = 30000.0 / 1001
    static let r5994 = 60000.0 / 1001
    static let uuid = UUID(uuidString: "00000000-0000-4000-8000-00000000A001")!
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    /// 23.976 with no timecode, start override 01:00:00:00 (§4.2): the sequence takes the override, the clip does not.
    static let basis2398Override = TimecodeBasis.forFile(rate: r2398, timecodeStartFrame: nil, timecodeNFR: nil,
                                                         dropFrame: false, overrideLabel: "01:00:00:00")
    /// 29.97 DF from 01:00:00;00.
    static let basis2997DF = TimecodeBasis(startFrame: 107_892, nfr: 30, rate: r2997, dropFrame: true, hasTimecode: true)
    static let basis25NoTC = TimecodeBasis.forFile(rate: 25, timecodeStartFrame: nil, timecodeNFR: nil, dropFrame: false,
                                                   overrideLabel: nil)
    /// 59.94 DF from 01:00:00;00 (P3 pending): 60 × 3600 − 108 × 60 + 108 × 6 frames.
    static let basis5994DF = TimecodeBasis(startFrame: 215_784, nfr: 60, rate: r5994, dropFrame: true, hasTimecode: true)

    static func media(_ path: String, frames: Int, channels: Int = 2) -> PremiereXML.Media {
        PremiereXML.Media(url: URL(fileURLWithPath: path), frameCount: frames, width: 640, height: 360,
                          audioChannels: channels, audioSampleRate: 48000, audioBitDepth: 24)
    }

    static func marker(_ frame: Int, _ color: MarkerColor = .blue, duration: Int = 1, name: String = "", notes: String = "",
                       keywords: [String] = []) -> Marker {
        Marker(frame: frame, duration: duration, name: name, notes: notes, keywords: keywords, color: color, created: date)
    }

    /// The attended-check shape: one-frame, ranged, and two-line notes with keywords.
    static let mixed: [Marker] = [
        marker(240, .red, duration: 48, name: "Ranged shot", notes: "Hold for the whole move"),
        marker(24, .green, name: "Head"),
        marker(480, .yellow, name: "Two lines", notes: "First line\nSecond line", keywords: ["titles", "graphics"]),
        marker(1439, .cyan, name: "Last frame", keywords: ["end"]),
    ]

    /// One marker per Manifold color, in `MarkerColor.allCases` order, plus XML specials, CRLF and blank lines, an empty
    /// name, and a ranged marker crossing a drop-frame minute.
    static let allColors: [Marker] = MarkerColor.allCases.enumerated().map { i, c in
        switch i {
        case 0: return marker(0, c, name: "", notes: "")
        case 1: return marker(100, c, name: #"Tom & Jerry <"quoted"> 'single'"#, notes: "a < b && c > d\r\n\r\n\"e\" 'f'")
        case 2: return marker(1790, c, duration: 30, name: "Crosses 01:01:00;02", notes: "\nleading\n\ntrailing\n")
        default: return marker(200 + i * 10, c, name: c.name)
        }
    }

    struct Golden {
        let file: String
        let markers: [Marker]
        let name: String
        let media: PremiereXML.Media
        let basis: TimecodeBasis
        let keywords: Bool
    }

    static let goldens: [Golden] = [
        Golden(file: "premiere-2398-override", markers: mixed, name: "mk-2398-notc",
               media: media("/Volumes/Media/Job 12/mk-2398-notc.mp4", frames: 1440), basis: basis2398Override, keywords: false),
        Golden(file: "premiere-2398-override-keywords", markers: mixed, name: "mk-2398-notc",
               media: media("/Volumes/Media/Job 12/mk-2398-notc.mp4", frames: 1440), basis: basis2398Override, keywords: true),
        Golden(file: "premiere-2997df-colors", markers: allColors, name: "mk-2997df-tc",
               media: media("/Users/editor/Média #1/100% done?/mk-2997df-tc.mov", frames: 2100, channels: 0),
               basis: basis2997DF, keywords: false),
        Golden(file: "premiere-25-empty", markers: [], name: "mk-25-notc",
               media: media("/Volumes/Media/mk-25-notc.mp4", frames: 1500, channels: 6), basis: basis25NoTC, keywords: false),
        Golden(file: "premiere-5994df", markers: [marker(0, .blue, name: "First"), marker(3596, .mint, duration: 8, name: "Minute")],
               name: "mk-5994df", media: media("/Volumes/Media/mk-5994df.mov", frames: 3600, channels: 1),
               basis: basis5994DF, keywords: false),
    ]

    static func write(_ g: Golden) throws -> (data: Data, report: PremiereXML.ExportReport) {
        try PremiereXML.export(markers: g.markers, sequenceName: g.name, media: g.media, basis: g.basis, sequenceUUID: uuid,
                               options: .init(appendKeywordsToComments: g.keywords))
    }

    static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).xml")
    }

    // MARK: Golden files

    func testGoldenFiles() throws {
        let regenerate = ProcessInfo.processInfo.environment["MANIFOLD_WRITE_GOLDEN"] == "1"
        for g in Self.goldens {
            let out = try Self.write(g).data
            if regenerate {
                try out.write(to: Self.fixtureURL(g.file))
                continue
            }
            let url = try XCTUnwrap(Bundle.module.url(forResource: g.file, withExtension: "xml", subdirectory: "Fixtures"),
                                    g.file)
            let golden = try Data(contentsOf: url)
            XCTAssertEqual(out, golden, "\(g.file).xml differs from the writer's output")
            XCTAssertNoThrow(try XMLDocument(data: golden), "\(g.file).xml parses as XML")
            XCTAssertTrue(Self.parses(golden), "\(g.file).xml parses with XMLParser")
        }
        if regenerate { throw XCTSkip("golden files rewritten; read the diff") }
    }

    static func parses(_ data: Data) -> Bool {
        let p = XMLParser(data: data)
        p.shouldResolveExternalEntities = false
        return p.parse()
    }

    // MARK: Structure (P0)

    func testFileFrameAndSequenceStructure() throws {
        let data = try Self.write(Self.goldens[0]).data
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 with a BOM, as Premiere writes it")
        let text = try XCTUnwrap(String(data: data.dropFirst(3), encoding: .utf8))
        XCTAssertFalse(text.contains("\r"), "LF only")
        XCTAssertTrue(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE xmeml>\n<xmeml version=\"4\">\n"))
        let doc = try XMLDocument(data: data)
        let seq = try XCTUnwrap(doc.rootElement()?.elements(forName: "sequence").first)
        let names = seq.children?.compactMap(\.name) ?? []
        XCTAssertEqual(Array(names.prefix(6)), ["uuid", "duration", "rate", "name", "media", "timecode"])
        XCTAssertEqual(Set(names.dropFirst(6)), ["marker"], "markers sit on the sequence, after its timecode")
        XCTAssertEqual(try doc.nodes(forXPath: "//clipitem/marker").count, 0, "no clip markers")
        for m in seq.elements(forName: "marker") {
            let order = m.children?.compactMap(\.name) ?? []
            XCTAssertTrue(order == ["comment", "name", "in", "out"] || order == ["comment", "name", "in", "out", "pproColor"],
                          "\(order)")
        }
        XCTAssertEqual(try doc.nodes(forXPath: "//sequence/media/video/track/clipitem/file/pathurl").first?.stringValue,
                       "file://localhost/Volumes/Media/Job%2012/mk-2398-notc.mp4")
        XCTAssertEqual(try doc.nodes(forXPath: "//sequence/duration").first?.stringValue, "1440")
        XCTAssertEqual(try doc.nodes(forXPath: "//sequence/media/audio/track").count, 2)
        XCTAssertEqual(try doc.nodes(forXPath: "//samplecharacteristics/samplecharacteristics").count, 0)
        XCTAssertEqual(try doc.nodes(forXPath: "//sequence/media/audio/format/samplecharacteristics/samplerate")
            .first?.stringValue, "48000")
        XCTAssertEqual(try doc.nodes(forXPath: "//sequence/media/audio/track/clipitem/sourcetrack/trackindex")
            .map { $0.stringValue ?? "" }, ["1", "2"])
    }

    /// The writer's placement and order against Robbie's P0 capture (§1.3). Structure only: no marker text is read into
    /// an assertion message. Skips when the capture is not on this Mac.
    func testMatchesP0Structure() throws {
        let p0URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Code/Manifold/fixtures/markers/premiere-p0.xml")
        guard let p0Data = try? Data(contentsOf: p0URL) else { throw XCTSkip("P0 capture not on this Mac: \(p0URL.path)") }
        let p0 = try XMLDocument(data: p0Data)
        let ours = try XMLDocument(data: try Self.write(Self.goldens[0]).data)
        XCTAssertEqual(Array(p0Data.prefix(3)), [0xEF, 0xBB, 0xBF])
        for doc in [p0, ours] {
            XCTAssertEqual(doc.rootElement()?.name, "xmeml")
            XCTAssertEqual(doc.rootElement()?.attribute(forName: "version")?.stringValue, "4")
            let seq = try XCTUnwrap(doc.rootElement()?.elements(forName: "sequence").first)
            let names = seq.children?.compactMap(\.name) ?? []
            let tc = try XCTUnwrap(names.firstIndex(of: "timecode"))
            let markers = names.indices.filter { names[$0] == "marker" }
            XCTAssertFalse(markers.isEmpty)
            XCTAssertTrue(markers.allSatisfy { $0 > tc }, "markers after the sequence timecode")
            XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "media")), tc)
            for m in seq.elements(forName: "marker") {
                let order = m.children?.compactMap(\.name) ?? []
                XCTAssertTrue(order == ["comment", "name", "in", "out"] || order == ["comment", "name", "in", "out", "pproColor"])
                let out = m.elements(forName: "out").first?.stringValue ?? ""
                XCTAssertTrue(out == "-1" || Int(out) != nil)
            }
            let stc = try XCTUnwrap(seq.elements(forName: "timecode").first)
            XCTAssertEqual(stc.children?.compactMap(\.name), ["rate", "string", "frame", "displayformat"])
            XCTAssertEqual(try doc.nodes(forXPath: "//sequence/media/audio/track/clipitem").count, 2, "stereo: two items")
            XCTAssertEqual(try doc.nodes(forXPath: "//sequence/media/audio/track/clipitem/@premiereChannelType")
                .map { $0.stringValue ?? "" }, ["stereo", "stereo"])
        }
        // Every value P0 wrote is one the writer writes (§4.1).
        let p0Colors = Set(try p0.nodes(forXPath: "//sequence/marker/pproColor").compactMap { UInt32($0.stringValue ?? "") })
        let ours8 = Set(PremiereMarkerColor.allCases.compactMap(\.pproColor))
        XCTAssertEqual(p0Colors, ours8)
    }

    // MARK: Markers

    func testOneFrameOutIsMinusOneAndRangedOutIsExclusive() throws {
        let doc = try XMLDocument(data: try Self.write(Self.goldens[0]).data)
        let ins = try doc.nodes(forXPath: "//sequence/marker/in").map { $0.stringValue ?? "" }
        let outs = try doc.nodes(forXPath: "//sequence/marker/out").map { $0.stringValue ?? "" }
        XCTAssertEqual(ins, ["24", "240", "480", "1439"], "time order")
        XCTAssertEqual(outs, ["-1", "288", "-1", "-1"], "ranged: frame + duration (P2 confirms exclusive)")
    }

    func testCommentsFlattenLineBreaksAndAppendKeywordsOnlyWhenAsked() throws {
        let off = try XMLDocument(data: try Self.write(Self.goldens[0]).data)
        let on = try XMLDocument(data: try Self.write(Self.goldens[1]).data)
        XCTAssertEqual(try off.nodes(forXPath: "//sequence/marker/comment").map { $0.stringValue ?? "?" },
                       ["", "Hold for the whole move", "First line Second line", ""])
        XCTAssertEqual(try on.nodes(forXPath: "//sequence/marker/comment").map { $0.stringValue ?? "?" },
                       ["", "Hold for the whole move", "First line Second line [titles, graphics]", "[end]"])
        let rOff = try Self.write(Self.goldens[0]).report
        XCTAssertEqual(rOff.droppedKeywords, 2)
        XCTAssertEqual(rOff.appendedKeywords, 0)
        XCTAssertEqual(rOff.flattenedNotes, 1)
        XCTAssertEqual(rOff.ranged, 1)
        let rOn = try Self.write(Self.goldens[1]).report
        XCTAssertEqual(rOn.droppedKeywords, 0)
        XCTAssertEqual(rOn.appendedKeywords, 2)
    }

    func testFlatten() {
        XCTAssertEqual(PremiereXML.flatten("a\nb"), "a b")
        XCTAssertEqual(PremiereXML.flatten("a\r\nb"), "a b")
        XCTAssertEqual(PremiereXML.flatten("a\rb"), "a b")
        XCTAssertEqual(PremiereXML.flatten("a\n\n\r\n\rb"), "a b", "a run of breaks is one space")
        XCTAssertEqual(PremiereXML.flatten("a\u{2028}b"), "a b")
        XCTAssertEqual(PremiereXML.flatten("\nleading\n\ntrailing\n"), "leading trailing")
        XCTAssertEqual(PremiereXML.flatten(""), "")
        XCTAssertEqual(PremiereXML.flatten("\n\n"), "")
        XCTAssertEqual(PremiereXML.flatten("no break"), "no break")
    }

    func testXMLSpecialsAndUnicodeRoundTripThroughAParser() throws {
        let long = String(repeating: "é", count: 1000)
        let name = #"A & B < C > D "E" 'F' 🎬 e\#u{301}"#
        let ms = [Self.marker(1, name: name, notes: "x & y\n<z>"), Self.marker(2, name: long),
                  Self.marker(3, name: "bell\u{07}tab\there")]
        let out = try PremiereXML.export(markers: ms, sequenceName: "Seq & <1>", media: Self.media("/tmp/x.mov", frames: 10),
                                         basis: Self.basis25NoTC, sequenceUUID: Self.uuid).data
        XCTAssertTrue(Self.parses(out))
        let doc = try XMLDocument(data: out)
        XCTAssertEqual(try doc.nodes(forXPath: "//sequence/marker/name").map { $0.stringValue ?? "" },
                       [name, long, "belltab\there"], "a control character XML cannot hold is dropped")
        XCTAssertEqual(try doc.nodes(forXPath: "//sequence/marker/comment").first?.stringValue, "x & y <z>")
        XCTAssertEqual(try doc.nodes(forXPath: "//sequence/name").first?.stringValue, "Seq & <1>")
        XCTAssertEqual(PremiereXML.escape(#"& < > " '"#), "&amp; &lt; &gt; &quot; &apos;")
    }

    func testEmptyNameAndNotesWriteEmptyElements() throws {
        let text = String(decoding: try Self.write(Self.goldens[2]).data, as: UTF8.self)
        XCTAssertTrue(text.contains("\t\t<marker>\n\t\t\t<comment></comment>\n\t\t\t<name></name>\n\t\t\t<in>0</in>\n"))
    }

    func testZeroMarkersWritesAValidSequenceWithNoMarkers() throws {
        let doc = try XMLDocument(data: try Self.write(Self.goldens[3]).data)
        XCTAssertEqual(try doc.nodes(forXPath: "//marker").count, 0)
        XCTAssertEqual(try doc.nodes(forXPath: "//sequence/media/video/track/clipitem").count, 1)
    }

    // MARK: Paths

    func testPathURLEscaping() {
        XCTAssertEqual(PremiereXML.pathURL(URL(fileURLWithPath: "/Volumes/A B/c.mov")), "file://localhost/Volumes/A%20B/c.mov")
        XCTAssertEqual(PremiereXML.pathURL(URL(fileURLWithPath: "/x/#1 100%?/c.mov")),
                       "file://localhost/x/%231%20100%25%3F/c.mov")
        XCTAssertEqual(PremiereXML.pathURL(URL(fileURLWithPath: "/x/Média/c.mov")), "file://localhost/x/M%C3%A9dia/c.mov")
        XCTAssertEqual(PremiereXML.pathURL(URL(fileURLWithPath: "/x/Me\u{301}dia/c.mov")), "file://localhost/x/M%C3%A9dia/c.mov",
                       "NFC whichever form the path arrives in")
        XCTAssertEqual(PremiereXML.pathURL(URL(fileURLWithPath: "/x/a&b;c=d+e,f@g:h/c.mov")),
                       "file://localhost/x/a%26b%3Bc%3Dd%2Be%2Cf%40g%3Ah/c.mov")
        // The escaped path reads back as the same file.
        let path = "/x/#1 100%?/Média/c.mov"
        let url = URL(string: PremiereXML.pathURL(URL(fileURLWithPath: path)))
        XCTAssertEqual(url?.path.precomposedStringWithCanonicalMapping, path.precomposedStringWithCanonicalMapping)
    }

    // MARK: Timecode (§4.2)

    func testSequenceTimecodeIsTheBasisAndTheClipsIsTheFilesOwn() throws {
        let doc = try XMLDocument(data: try Self.write(Self.goldens[0]).data)
        func tc(_ xpath: String) throws -> [String] {
            let e = try XCTUnwrap(try doc.nodes(forXPath: xpath).first as? XMLElement)
            return ["rate/timebase", "rate/ntsc", "string", "frame", "displayformat"].map {
                (try? e.nodes(forXPath: $0).first?.stringValue) ?? nil ?? "?"
            }
        }
        XCTAssertEqual(try tc("//sequence/timecode"), ["24", "TRUE", "01:00:00:00", "86400", "NDF"], "the override")
        XCTAssertEqual(try tc("//clipitem/file/timecode"), ["24", "TRUE", "00:00:00:00", "0", "NDF"],
                       "a file without timecode reads 00:00:00:00 in Premiere")
    }

    func testDropFrameTimecodes() throws {
        let df = try XMLDocument(data: try Self.write(Self.goldens[2]).data)
        XCTAssertEqual(try df.nodes(forXPath: "//sequence/timecode/string").first?.stringValue, "01;00;00;00")
        XCTAssertEqual(try df.nodes(forXPath: "//sequence/timecode/frame").first?.stringValue, "107892")
        XCTAssertEqual(try df.nodes(forXPath: "//sequence/timecode/displayformat").first?.stringValue, "DF")
        XCTAssertEqual(try df.nodes(forXPath: "//sequence/rate/timebase").first?.stringValue, "30")
        XCTAssertEqual(try df.nodes(forXPath: "//sequence/rate/ntsc").first?.stringValue, "TRUE")
        XCTAssertEqual(try df.nodes(forXPath: "//clipitem/file/timecode/string").first?.stringValue, "01;00;00;00",
                       "a file with timecode: its own, DF")
        // P0-DF: frame 108000 is labelled 01;00;03;18.
        let p0 = TimecodeBasis(startFrame: 108_000, nfr: 30, rate: Self.r2997, dropFrame: true, hasTimecode: true)
        XCTAssertEqual(PremiereXML.timecodeString(p0), "01;00;03;18")
        // 59.94 DF (P3 pending): the same form at timebase 60.
        let d59 = try XMLDocument(data: try Self.write(Self.goldens[4]).data)
        XCTAssertEqual(try d59.nodes(forXPath: "//sequence/timecode/string").first?.stringValue, "01;00;00;00")
        XCTAssertEqual(try d59.nodes(forXPath: "//sequence/timecode/frame").first?.stringValue, "215784")
        XCTAssertEqual(try d59.nodes(forXPath: "//sequence/rate/timebase").first?.stringValue, "60")
    }

    func testRates() throws {
        func rate(_ r: Double, _ nfr: Int) -> (Int, Bool)? {
            PremiereXML.Rate(TimecodeBasis(startFrame: 0, nfr: nfr, rate: r, dropFrame: false, hasTimecode: false))
                .map { ($0.timebase, $0.ntsc) }
        }
        XCTAssertTrue(rate(Self.r2398, 24)! == (24, true))
        XCTAssertTrue(rate(24, 24)! == (24, false))
        XCTAssertTrue(rate(25, 25)! == (25, false))
        XCTAssertTrue(rate(Self.r2997, 30)! == (30, true))
        XCTAssertTrue(rate(50, 50)! == (50, false))
        XCTAssertTrue(rate(Self.r5994, 60)! == (60, true))
        XCTAssertNil(rate(12.5, 13), "not an integer or NTSC rate")
        XCTAssertNil(rate(29.5, 30))
        let b = TimecodeBasis(startFrame: 0, nfr: 13, rate: 12.5, dropFrame: false, hasTimecode: false)
        XCTAssertThrowsError(try PremiereXML.export(markers: [], sequenceName: "x", media: Self.media("/x.mov", frames: 1),
                                                    basis: b, sequenceUUID: Self.uuid)) {
            XCTAssertEqual($0 as? PremiereXML.ExportError, .unsupportedRate)
        }
    }

    // MARK: Colors (§4.1)

    func testColorTable() throws {
        let expected: [MarkerColor: (PremiereMarkerColor, UInt32?)] = [
            .green: (.green, nil), .red: (.red, 4281740498), .lavender: (.purple, 4289825711),
            .sand: (.orange, 4280578025), .yellow: (.yellow, 4281049552), .cream: (.white, 4294967295),
            .blue: (.blue, 4294741314), .cyan: (.cyan, 4292277273), .pink: (.purple, 4289825711),
            .purple: (.purple, 4289825711), .fuchsia: (.red, 4281740498), .rose: (.red, 4281740498),
            .sky: (.cyan, 4292277273), .mint: (.green, nil), .lemon: (.yellow, 4281049552), .cocoa: (.orange, 4280578025),
        ]
        XCTAssertEqual(expected.count, 16)
        for c in MarkerColor.allCases {
            let p = PremiereMarkerColor(exporting: c)
            XCTAssertEqual(p, expected[c]?.0, c.name)
            XCTAssertEqual(p.pproColor, expected[c]?.1, c.name)
        }
        // The golden file holds all 16, with Green and Mint writing no value.
        let doc = try XMLDocument(data: try Self.write(Self.goldens[2]).data)
        let markers = try doc.nodes(forXPath: "//sequence/marker").compactMap { $0 as? XMLElement }
        XCTAssertEqual(markers.count, 16)
        let byIn = Dictionary(uniqueKeysWithValues: markers.map {
            (Int($0.elements(forName: "in").first?.stringValue ?? "") ?? -1,
             $0.elements(forName: "pproColor").first.flatMap { UInt32($0.stringValue ?? "") })
        })
        for m in Self.allColors { XCTAssertEqual(byIn[m.frame] ?? 0, expected[m.color]?.1, m.color.name) }
        XCTAssertEqual(try Self.write(Self.goldens[2]).report.nearestColors, 8)
    }

    func testExportIsTheReverseOfTheImportTable() {
        for p in PremiereMarkerColor.allCases {
            XCTAssertEqual(PremiereMarkerColor(exporting: p.markerColor), p, p.rawValue)
            XCTAssertTrue(p.isDirectMatch(for: p.markerColor))
        }
    }

    func testHueRuleOnManifoldSwatchesGivesTheTable() {
        for c in MarkerColor.allCases {
            let e = EmbeddedColor(red: UInt8((c.hex >> 16) & 0xFF), green: UInt8((c.hex >> 8) & 0xFF), blue: UInt8(c.hex & 0xFF))
            XCTAssertEqual(PremiereMarkerColor(nearest: e), PremiereMarkerColor(exporting: c), c.name)
        }
    }

    func testPproColorsDecodeToTheMeasuredColors() {
        for p in PremiereMarkerColor.allCases {
            guard let v = p.pproColor else { XCTAssertEqual(p, .green); continue }
            XCTAssertEqual(PremiereMarkerColor(nearest: XMPMarkers.abgr(v)), p, p.rawValue)
            XCTAssertEqual(PremiereMarkerColor.measured[XMPMarkers.abgr(v)], p, "an exact match, \(p.rawValue)")
        }
    }

    // MARK: Privacy

    func testLogLineHoldsCountsOnly() throws {
        let sentinel = "SENTINEL-XMEML-7c2e"
        let ms = [Self.marker(1, .pink, duration: 3, name: sentinel, notes: "\(sentinel)\n\(sentinel)", keywords: [sentinel])]
        let r = try PremiereXML.export(markers: ms, sequenceName: sentinel,
                                       media: Self.media("/\(sentinel)/\(sentinel).mov", frames: 10),
                                       basis: Self.basis25NoTC, sequenceUUID: Self.uuid).report
        let line = MarkerLog.exported(xmeml: r, audioChannels: 2, unconvertedFileMarkers: 3)
        XCTAssertFalse(line.contains(sentinel))
        XCTAssertEqual(line, "[MARKERS] export xmeml n=1 ranged=1 nearest-colors=1 flattened-notes=1 dropped-keywords=1 "
                       + "keywords-in-comments=0 audio-channels=2 unconverted-file-markers=3")
        XCTAssertFalse(PremiereXML.notice(r, unconvertedFileMarkers: 3).contains(sentinel))
    }

    func testNotice() {
        var r = PremiereXML.ExportReport()
        r.markers = 5; r.nearestColors = 2; r.flattenedNotes = 1; r.droppedKeywords = 3
        XCTAssertEqual(PremiereXML.notice(r, unconvertedFileMarkers: 6),
                       "Exported 5 markers to Premiere Pro XML. 2 markers took the nearest of Premiere’s 8 colors. "
                       + "1 multi-line note was joined onto one line. 3 markers have keywords; Premiere has no field for them. "
                       + "This file’s 6 file markers were not exported; convert them first.")
        var one = PremiereXML.ExportReport(); one.markers = 1; one.appendedKeywords = 1
        XCTAssertEqual(PremiereXML.notice(one, unconvertedFileMarkers: 0),
                       "Exported 1 marker to Premiere Pro XML. Keywords were added to the comments.")
    }
}
