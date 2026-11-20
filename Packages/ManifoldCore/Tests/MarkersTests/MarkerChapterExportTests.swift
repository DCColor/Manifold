import XCTest
@testable import Markers
import SMPTETimecode

/// docs/CHAPTER_MARKERS_PLAN.md §15: the chapter-list export (ffmpeg metadata and YouTube description text). Golden files
/// in `Fixtures/chapters-*.ffmeta` and `Fixtures/youtube-*.txt` are the writer's own output, checked by hand when written
/// (2026-11-20). Every title here is synthetic. The ffmetadata → ffmpeg → `ChapterReader` round trip is in
/// ChapterReaderTests (`testChapterListExportRoundTrip`), on a fixture made from `chapters-roundtrip-2398.ffmeta`.
///
/// To regenerate after an intended change: `MANIFOLD_WRITE_GOLDEN=1 swift test --filter MarkerChapterExportTests`, then
/// read the diff before committing it.
final class MarkerChapterExportTests: XCTestCase {

    static let r2398 = 24000.0 / 1001
    static let r2997 = 30000.0 / 1001
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static let basis2398 = TimecodeBasis(startFrame: 86_400, nfr: 24, rate: r2398, dropFrame: false, hasTimecode: true)
    static let basis25NoTC = TimecodeBasis.forFile(rate: 25, timecodeStartFrame: nil, timecodeNFR: nil, dropFrame: false,
                                                   overrideLabel: nil)
    static let basis2997DF = TimecodeBasis(startFrame: 107_892, nfr: 30, rate: r2997, dropFrame: true, hasTimecode: true)

    static func marker(_ frame: Int, duration: Int = 1, name: String = "", notes: String = "",
                       keywords: [String] = [], color: MarkerColor = .blue) -> Marker {
        Marker(frame: frame, duration: duration, name: name, notes: notes, keywords: keywords, color: color, created: date)
    }

    /// 23.976, 1440 frames (60.06 s), file timecode 01:00:00:00 (ignored: elapsed time, §15.3). Given out of order.
    static let set2398: [Marker] = [
        marker(1439, name: "Last frame"),
        marker(0, name: "Opening", notes: "dropped", keywords: ["dropped"]),
        marker(480, duration: 48, name: #"Ranged = ; # \ shot"#),
        marker(241, name: "Second"),
        marker(1000),
    ]

    /// 25 fps, 3000 frames (120 s), no timecode: every YouTube rule kept.
    static let set25: [Marker] = [
        marker(0, name: "Intro"),
        marker(250, name: "Part one"),
        marker(1000),
        marker(2500, name: "Résumé — 終わり"),
    ]

    /// 29.97 DF from 01:00:00;00, 110 889 frames (≈ 3700 s): no line at 00:00, two lines on one second, one past the hour.
    static let set2997DF: [Marker] = [
        marker(30, name: "Late start"),
        marker(31),
        marker(108_000, duration: 300, name: "Over an hour"),
    ]

    /// The round-trip list: 23.976, 72 frames, the frames of `r-track.mov` (ChapterReaderTests keeps the same list).
    static let roundTrip: [Marker] = [
        marker(0, name: "Opening"),
        marker(17),
        marker(30, duration: 12, name: #"A = b; #1 \ c"#),
        marker(49, name: "Fourth"),
        marker(70, name: "Near end"),
    ]

    /// 25 fps, 1000 frames: a 12 s ranged marker with another 2 s behind it (the attended check's overlap, 2026-11-20), and
    /// a ranged last marker that keeps its own end.
    static let overlap: [Marker] = [
        marker(0, name: "Start"),
        marker(254, duration: 300, name: "Chapter - This is a café"),
        marker(304, name: "Close behind"),
        marker(600, duration: 50, name: "Ranged last"),
    ]

    struct Golden {
        let file: String
        let text: String
    }

    static var goldens: [Golden] {
        [
            Golden(file: "chapters-2398.ffmeta", text: MarkerFFMetadata.export(markers: set2398, rate: r2398, frameCount: 1440)!.text),
            Golden(file: "chapters-25.ffmeta", text: MarkerFFMetadata.export(markers: set25, rate: 25, frameCount: 3000)!.text),
            Golden(file: "chapters-2997df.ffmeta",
                   text: MarkerFFMetadata.export(markers: set2997DF, rate: r2997, frameCount: 110_889)!.text),
            Golden(file: "chapters-roundtrip-2398.ffmeta",
                   text: MarkerFFMetadata.export(markers: roundTrip, rate: r2398, frameCount: 72)!.text),
            Golden(file: "chapters-25-overlap.ffmeta",
                   text: MarkerFFMetadata.export(markers: overlap, rate: 25, frameCount: 1000)!.text),
            Golden(file: "youtube-2398.txt", text: MarkerYouTube.export(markers: set2398, basis: basis2398, frameCount: 1440)!.text),
            Golden(file: "youtube-25.txt", text: MarkerYouTube.export(markers: set25, basis: basis25NoTC, frameCount: 3000)!.text),
            Golden(file: "youtube-2997df.txt",
                   text: MarkerYouTube.export(markers: set2997DF, basis: basis2997DF, frameCount: 110_889)!.text),
        ]
    }

    // MARK: Golden files

    func testGoldenFiles() throws {
        let regenerate = ProcessInfo.processInfo.environment["MANIFOLD_WRITE_GOLDEN"] == "1"
        for g in Self.goldens {
            let data = Data(g.text.utf8)
            if regenerate {
                try data.write(to: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("Fixtures/\(g.file)"))
                continue
            }
            let parts = g.file.split(separator: ".", maxSplits: 1)
            let url = try XCTUnwrap(Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]),
                                                      subdirectory: "Fixtures"), g.file)
            XCTAssertEqual(data, try Data(contentsOf: url), "\(g.file) differs from the writer's output")
            XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]), "\(g.file): no BOM")
            XCTAssertFalse(g.text.contains("\r"), "\(g.file): LF only")
        }
        if regenerate { throw XCTSkip("golden files rewritten; read the diff") }
    }

    // MARK: ffmetadata

    func testFFMetadataExactStartAndEndAt2398() throws {
        let out = try XCTUnwrap(MarkerFFMetadata.export(markers: Self.set2398, rate: Self.r2398, frameCount: 1440))
        let chapters = Self.parse(out.text)
        XCTAssertEqual(chapters.map(\.timebase), Array(repeating: "1001/24000", count: 5))
        XCTAssertEqual(chapters.map(\.start), [0, 241, 480, 1000, 1439])
        // Point markers run to the next marker; the ranged one ends after its 48th frame; the last runs to the file's end.
        XCTAssertEqual(chapters.map(\.end), [241, 480, 528, 1439, 1440])
        XCTAssertEqual(chapters.map(\.title), ["Opening", "Second", ##"Ranged \= \; \# \\ shot"##, "", "Last frame"])
        XCTAssertTrue(out.text.hasPrefix(";FFMETADATA1\n[CHAPTER]\n"))
        XCTAssertEqual(out.report, .init(markers: 5, emptyTitles: 1, escapedTitles: 1, cappedEnds: 0))
        XCTAssertFalse(out.text.contains("dropped"), "notes and keywords are not exported")
    }

    func testFFMetadataTimebaseAt25And2997() throws {
        let t25 = try XCTUnwrap(MarkerFFMetadata.export(markers: Self.set25, rate: 25, frameCount: 3000)).text
        XCTAssertEqual(Self.parse(t25).map(\.timebase), Array(repeating: "1/25", count: 4))
        XCTAssertEqual(Self.parse(t25).map(\.end), [250, 1000, 2500, 3000])
        let t2997 = try XCTUnwrap(MarkerFFMetadata.export(markers: Self.set2997DF, rate: Self.r2997, frameCount: 110_889)).text
        let c = Self.parse(t2997)
        XCTAssertEqual(c.map(\.timebase), Array(repeating: "1001/30000", count: 3))
        XCTAssertEqual(c.map(\.start), [30, 31, 108_000], "frames, not drop-frame timecode")
        XCTAssertEqual(c.map(\.end), [31, 108_000, 108_300])
    }

    /// START counts frames, so TIMEBASE must be one frame: never 1/24, 1/30 or 1/60 at a 1000/1001 rate. Also for a rate
    /// given rounded (23.976, 29.97, 59.94), as a container may state it.
    func testFFMetadataTimebaseIsOneFrameAtNTSCRates() throws {
        let cases: [(Double, String)] = [(Self.r2398, "1001/24000"), (23.976, "1001/24000"),
                                         (Self.r2997, "1001/30000"), (29.97, "1001/30000"),
                                         (60000.0 / 1001, "1001/60000"), (59.94, "1001/60000"),
                                         (24, "1/24"), (30, "1/30"), (60, "1/60"), (50, "1/50")]
        for (rate, tb) in cases {
            let text = try XCTUnwrap(MarkerFFMetadata.export(markers: [Self.marker(100)], rate: rate, frameCount: 200)).text
            XCTAssertEqual(Self.parse(text).map(\.timebase), [tb], "rate \(rate)")
        }
        // 59.94: frame 3596 is START=3596 against 1001/60000 (59.986 s), not 3596/60 = 59.933 s.
        let t5994 = try XCTUnwrap(MarkerFFMetadata.export(markers: [Self.marker(3596, duration: 8)], rate: 59.94,
                                                          frameCount: 3600)).text
        XCTAssertEqual(Self.parse(t5994).map(\.start), [3596])
        XCTAssertEqual(Self.parse(t5994).map(\.end), [3604])
    }

    /// `resolve_chapters - prores.mov` (23.976, §11.3) after Convert All: the markers sit on 0, 58, 254, 545 (D-C7a; 58 is
    /// 01:00:02:10), and the export writes those frames as they are.
    func testResolveChaptersFileAfterConvert() throws {
        let ms = [Self.marker(0), Self.marker(58), Self.marker(254), Self.marker(545)]
        let ff = try XCTUnwrap(MarkerFFMetadata.export(markers: ms, rate: Self.r2398, frameCount: 1000)).text
        XCTAssertEqual(Self.parse(ff).map(\.timebase), Array(repeating: "1001/24000", count: 4))
        XCTAssertEqual(Self.parse(ff).map(\.start), [0, 58, 254, 545])
        XCTAssertEqual(Self.basis2398.label(58), "01:00:02:10")
        // 58 × 1001/24000 = 2.419 s, 254 → 10.594 s, 545 → 22.731 s: Resolve's own chpl times, floored.
        let yt = try XCTUnwrap(MarkerYouTube.export(markers: ms, basis: Self.basis2398, frameCount: 1000))
        XCTAssertEqual(yt.text.split(separator: "\n").map { String($0.prefix(5)) }, ["00:00", "00:02", "00:10", "00:22"])
    }

    func testFFMetadataNeverOverlaps() throws {
        let out = try XCTUnwrap(MarkerFFMetadata.export(markers: Self.overlap, rate: 25, frameCount: 1000))
        let c = Self.parse(out.text)
        XCTAssertEqual(c.map(\.start), [0, 254, 304, 600])
        XCTAssertEqual(c.map(\.end), [254, 304, 600, 650], "254's own end (554) is capped at 304; the last keeps 650")
        for i in 1..<c.count { XCTAssertLessThanOrEqual(c[i - 1].end, c[i].start) }
        XCTAssertEqual(out.report.cappedEnds, 1)
        // A ranged marker that ends before the next keeps its own end.
        let gap = try XCTUnwrap(MarkerFFMetadata.export(markers: [Self.marker(0, duration: 10), Self.marker(50)], rate: 25,
                                                        frameCount: 100))
        XCTAssertEqual(Self.parse(gap.text).map(\.end), [10, 100])
        XCTAssertEqual(gap.report.cappedEnds, 0)
        // YouTube measures line to line: the 12 s marker is a 2 s chapter (10.16 s → 12.16 s gives 00:10 → 00:12).
        let yt = try XCTUnwrap(MarkerYouTube.export(markers: Self.overlap, basis: Self.basis25NoTC, frameCount: 1000))
        XCTAssertEqual(yt.report.underMinimum, 1)
    }

    func testUnconvertedFileMarkersNotice() throws {
        XCTAssertNil(MarkerChapterList.unconvertedNotice(0))
        XCTAssertEqual(MarkerChapterList.unconvertedNotice(1), "1 file marker not included: Convert them to include them.")
        XCTAssertEqual(MarkerChapterList.unconvertedNotice(4), "4 file markers not included: Convert them to include them.")
    }

    func testFFMetadataEscaping() {
        XCTAssertEqual(MarkerFFMetadata.escape(#"a=b;c#d\e"#), ##"a\=b\;c\#d\\e"##)
        XCTAssertEqual(MarkerFFMetadata.escape("one\ntwo"), "one\\\ntwo")
        XCTAssertEqual(MarkerFFMetadata.escape("Größe — 終わり"), "Größe — 終わり")
        // F6's reserved title (CHAPTER_MARKERS_PLAN §5).
        XCTAssertEqual(MarkerFFMetadata.escape(#"Reserved = ; # \ chars"#), ##"Reserved \= \; \# \\ chars"##)
    }

    func testFFMetadataEdgeCases() throws {
        // A ranged marker on the last frames is not clamped to the file; one marker alone runs to the end.
        let one = try XCTUnwrap(MarkerFFMetadata.export(markers: [Self.marker(10)], rate: 25, frameCount: 100)).text
        XCTAssertEqual(Self.parse(one).map(\.end), [100])
        // A file length the engine does not know yet (0 frames) still gives every chapter at least one frame.
        let unknown = try XCTUnwrap(MarkerFFMetadata.export(markers: [Self.marker(10)], rate: 25, frameCount: 0)).text
        XCTAssertEqual(Self.parse(unknown).map(\.end), [11])
        XCTAssertNil(MarkerFFMetadata.export(markers: [Self.marker(1)], rate: 0, frameCount: 10))
    }

    // MARK: YouTube

    func testYouTubeFloorsToTheSecond() {
        // 23.976: frame 240 is 10.01 s, 239 is 9.968 s, 241 is 10.05 s (§15.3's example).
        let n2398: Int64 = 24000, d2398: Int64 = 1001
        XCTAssertEqual(MarkerYouTube.second(ofFrame: 239, rateNum: n2398, rateDen: d2398), 9)
        XCTAssertEqual(MarkerYouTube.second(ofFrame: 240, rateNum: n2398, rateDen: d2398), 10)
        XCTAssertEqual(MarkerYouTube.second(ofFrame: 241, rateNum: n2398, rateDen: d2398), 10)
        // 29.97: frame 29 is 0.968 s, 30 is 1.001 s; 25: frame 24 is 0.96 s.
        XCTAssertEqual(MarkerYouTube.second(ofFrame: 29, rateNum: 30000, rateDen: 1001), 0)
        XCTAssertEqual(MarkerYouTube.second(ofFrame: 30, rateNum: 30000, rateDen: 1001), 1)
        XCTAssertEqual(MarkerYouTube.second(ofFrame: 24, rateNum: 25, rateDen: 1), 0)
        XCTAssertEqual(MarkerYouTube.second(ofFrame: 25, rateNum: 25, rateDen: 1), 1)
    }

    func testYouTubeTimestampForm() {
        XCTAssertEqual(MarkerYouTube.timestamp(0), "00:00", "the help page's own form")
        XCTAssertEqual(MarkerYouTube.timestamp(10), "00:10")
        XCTAssertEqual(MarkerYouTube.timestamp(3599), "59:59")
        XCTAssertEqual(MarkerYouTube.timestamp(3600), "1:00:00")
        XCTAssertEqual(MarkerYouTube.timestamp(3751), "1:02:31")
        XCTAssertEqual(MarkerYouTube.timestamp(36_000), "10:00:00")
    }

    func testYouTubeAllRulesKept() throws {
        let out = try XCTUnwrap(MarkerYouTube.export(markers: Self.set25, basis: Self.basis25NoTC, frameCount: 3000))
        XCTAssertEqual(out.text, "00:00 Intro\n00:10 Part one\n00:40 00:00:40:00\n01:40 Résumé — 終わり\n")
        XCTAssertFalse(out.report.breaksRules)
        XCTAssertEqual(out.report.timecodeTitles, 1)
        XCTAssertEqual(MarkerYouTube.notice(out.report, unconvertedFileMarkers: 0),
                       "Exported 4 chapters for a YouTube description. 1 unnamed marker is titled with its timecode.")
    }

    func testYouTubeEmptyNameTakesTheTimecode() throws {
        // D-C18: the marker's timecode label, with the file's start timecode and drop-frame (the line's time is elapsed).
        let out = try XCTUnwrap(MarkerYouTube.export(markers: Self.set2997DF, basis: Self.basis2997DF, frameCount: 110_889))
        XCTAssertEqual(out.text, "00:01 Late start\n00:01 01:00:01;01\n1:00:03 Over an hour\n")
        let tc = try XCTUnwrap(MarkerYouTube.export(markers: [Self.marker(1000, name: "   ")], basis: Self.basis2398,
                                                    frameCount: 1440))
        XCTAssertEqual(tc.text, "00:41 01:00:41:16\n", "a blank name is unnamed too")
    }

    func testYouTubeRuleNotices() throws {
        let out = try XCTUnwrap(MarkerYouTube.export(markers: Self.set2997DF, basis: Self.basis2997DF, frameCount: 110_889))
        XCTAssertEqual(out.report, .init(markers: 3, timecodeTitles: 1, noLineAtZero: true, tooFew: false, underMinimum: 1,
                                         sharedSecond: 1))
        XCTAssertEqual(MarkerYouTube.notice(out.report, unconvertedFileMarkers: 2),
                       "Exported 3 chapters for a YouTube description. 1 unnamed marker is titled with its timecode. "
                       + "YouTube may not show these chapters: no chapter at 00:00 (YouTube needs one); "
                       + "1 chapter under 10 s (YouTube’s minimum); 1 chapter shares a second with the one before. "
                       + "2 file markers not included: Convert them to include them.")

        // 23.976: the last line is 0.06 s from the end of the video.
        let last = try XCTUnwrap(MarkerYouTube.export(markers: Self.set2398, basis: Self.basis2398, frameCount: 1440))
        XCTAssertEqual(last.report.underMinimum, 1)
        XCTAssertFalse(last.report.noLineAtZero)
        XCTAssertEqual(last.report.sharedSecond, 0)

        let two = try XCTUnwrap(MarkerYouTube.export(markers: [Self.marker(0, name: "A"), Self.marker(500, name: "B")],
                                                     basis: Self.basis25NoTC, frameCount: 1000))
        XCTAssertTrue(two.report.tooFew)
        XCTAssertEqual(two.report.underMinimum, 0, "20 s each")
        XCTAssertEqual(MarkerYouTube.notice(two.report, unconvertedFileMarkers: 0),
                       "Exported 2 chapters for a YouTube description. "
                       + "YouTube may not show these chapters: fewer than 3 chapters (YouTube needs 3).")
    }

    func testYouTubeChapterLengthIsMeasuredOnWrittenSeconds() throws {
        // 25 fps: lines at 00:00, 00:09 (frame 249 = 9.96 s), 00:20; the video is 30 s. The 00:00 chapter is 9 s.
        let out = try XCTUnwrap(MarkerYouTube.export(markers: [Self.marker(0, name: "A"), Self.marker(249, name: "B"),
                                                               Self.marker(500, name: "C")],
                                                     basis: Self.basis25NoTC, frameCount: 750))
        XCTAssertEqual(out.report.underMinimum, 1)
        // Exactly 10 s to the end of the video is enough.
        let edge = try XCTUnwrap(MarkerYouTube.export(markers: [Self.marker(0, name: "A"), Self.marker(250, name: "B"),
                                                                Self.marker(500, name: "C")],
                                                      basis: Self.basis25NoTC, frameCount: 750))
        XCTAssertEqual(edge.report.underMinimum, 0)
    }

    // MARK: Log lines carry counts only

    func testLogLinesHoldNoTitle() throws {
        let sentinel = "SENTINEL-TITLE-c18e"
        let ms = [Self.marker(0, name: sentinel, notes: sentinel, keywords: [sentinel]), Self.marker(5)]
        let ff = try XCTUnwrap(MarkerFFMetadata.export(markers: ms, rate: 25, frameCount: 100))
        let yt = try XCTUnwrap(MarkerYouTube.export(markers: ms, basis: Self.basis25NoTC, frameCount: 100))
        XCTAssertTrue(ff.text.contains(sentinel) && yt.text.contains(sentinel), "the files hold the title")
        let lines = [MarkerLog.exported(ffmeta: ff.report, unconvertedFileMarkers: 1),
                     MarkerLog.exported(youtube: yt.report, unconvertedFileMarkers: 1),
                     MarkerLog.exportRefusedRate(.ffmeta), MarkerLog.exportRefusedRate(.youtube)]
        for l in lines {
            XCTAssertFalse(l.contains(sentinel))
            XCTAssertTrue(l.hasPrefix("[MARKERS] export "))
        }
        XCTAssertEqual(lines[1], "[MARKERS] export youtube n=2 timecode-titles=1 no-zero=no too-few=yes under-min=2 "
                       + "shared-second=1 unconverted-file-markers=1")
    }

    // MARK: Helpers

    struct Chapter { var timebase = "", start = -1, end = -1, title = "" }

    /// Reads back this writer's own layout (one key per line, escapes left in place).
    static func parse(_ text: String) -> [Chapter] {
        var out: [Chapter] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "[CHAPTER]" { out.append(Chapter()); continue }
            guard !out.isEmpty, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = String(line[line.index(after: eq)...])
            switch key {
            case "TIMEBASE": out[out.count - 1].timebase = value
            case "START": out[out.count - 1].start = Int(value) ?? -1
            case "END": out[out.count - 1].end = Int(value) ?? -1
            case "title": out[out.count - 1].title = value
            default: break
            }
        }
        return out
    }
}
