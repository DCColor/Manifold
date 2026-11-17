import XCTest
import AVFoundation
@testable import ChapterRead
import Markers

/// Premiere's XMP markers read from real files (docs/CHAPTER_MARKERS_PLAN.md §12, §16; Stage 3), and mapped together with
/// libav's chapters exactly as `MarkerModel` maps them (chapters + XMP items, one `ChapterMapping.map`).
///
/// Fixtures (`Fixtures/`), made once on 2026-11-17 by `~/Code/_scratch/manifold-chapters/make_xmp_fixtures.py` (recorded
/// in CHAPTER_MARKERS_PLAN §16.2) from copies of two Stage 1 fixtures; every name, comment and GUID in them is synthetic:
///  - x-uuid.mp4  r-both.mp4 (25 fps, 75 frames, chapter track + chpl at 0/25/51) + a root `uuid` XMP box appended after
///                moov: Comment 10 (5 frames, Red), Chapter 25 (Purple), WebLink 60 (skipped). Track rate f25.
///  - x-udta.mov  r-track.mov (23.976, 72 frames, chapter track at 0/24/49) + `XMP_` appended in moov/udta: Chapter 24
///                (Orange), Comment 30 (12 frames, Red), Segmentation 40 and WebLink 50 (skipped), Chapter 100 (past the
///                end). Track rate f24000s1001.
final class XMPFileTests: XCTestCase {

    private func fixture(_ name: String) throws -> URL {
        let parts = name.split(separator: ".")
        return try XCTUnwrap(Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]),
                                               subdirectory: "Fixtures"))
    }

    func testMP4RootUUID() throws {
        let url = try fixture("x-uuid.mp4")
        let xmp = XMPMarkers.read(url: url)
        XCTAssertEqual(xmp.status, .ok)
        XCTAssertEqual(xmp.location, .uuid)
        XCTAssertEqual(xmp.tracks, 1)
        XCTAssertEqual(xmp.chapters, 1)
        XCTAssertEqual(xmp.comments, 1)
        XCTAssertEqual(xmp.skipped.weblink, 1)
        XCTAssertEqual(xmp.skipped.total, 1)
        // libav still reads the file's chapters, unaffected by the appended box.
        let libav = try ChapterReader.read(url: url)
        XCTAssertEqual(libav.chapters.map(\.title), ["One", "Two", "Three"])
        let r = ChapterMapping.map(libav.chapters + xmp.items, origin: libav.videoStart, rate: 25, lastFrame: 74)
        XCTAssertEqual(r.chapters.map(\.frame), [0, 10, 25, 51])
        XCTAssertEqual(r.chapters.map(\.source), [.chapterTrack, .xmp, .xmp, .chapterTrack])
        XCTAssertEqual(r.chapters.map(\.kind), [.chapter, .comment, .chapter, .chapter])
        XCTAssertEqual(r.duplicates, 1, "the chapter track's frame 25 is shown once, as the XMP Chapter")
        XCTAssertEqual(r.chapters[1].statedDuration, 5, "the comment's stated 5 frames: a band")
        XCTAssertNil(r.chapters[2].statedDuration, "no duration: no band")
        XCTAssertEqual(r.chapters[1].color, EmbeddedColor(red: 0xD2, green: 0x2C, blue: 0x36))
        XCTAssertEqual(r.chapters[2].color, EmbeddedColor(red: 0xAF, green: 0x8B, blue: 0xB1))
        XCTAssertEqual(r.chapters[1].comment, "first line\nsecond line")
        let conv = ChapterMapping.convert(r.chapters, into: [])
        XCTAssertEqual(conv.added.map(\.color), [.blue, .red, .lavender, .blue])
        XCTAssertEqual(conv.added.map(\.keywords), [["chapter"], ["comment"], ["chapter"], ["chapter"]])
        XCTAssertEqual(conv.added.map(\.embeddedID), [nil, "guid-mp4-1", "guid-mp4-2", nil])
    }

    func testMOVUdtaXMP() throws {
        let url = try fixture("x-udta.mov")
        let xmp = XMPMarkers.read(url: url)
        XCTAssertEqual(xmp.status, .ok)
        XCTAssertEqual(xmp.location, .udta)
        XCTAssertEqual(xmp.chapters, 2)
        XCTAssertEqual(xmp.comments, 1)
        XCTAssertEqual(xmp.skipped.segmentation, 1)
        XCTAssertEqual(xmp.skipped.weblink, 1)
        let libav = try ChapterReader.read(url: url)
        XCTAssertEqual(libav.chapters.map(\.title), ["Opening", "Second", "Last"])
        let r = ChapterMapping.map(libav.chapters + xmp.items, origin: libav.videoStart, rate: 24000.0 / 1001, lastFrame: 71)
        XCTAssertEqual(r.chapters.map(\.frame), [0, 24, 30, 49])
        XCTAssertEqual(r.chapters.map(\.source), [.chapterTrack, .xmp, .xmp, .chapterTrack])
        XCTAssertEqual(r.duplicates, 1)
        XCTAssertEqual(r.droppedPastEnd, 1)
        XCTAssertEqual(r.chaptersPastEnd, 1)
        XCTAssertEqual(r.chapters[1].duration, 25, "the XMP chapter runs to the next chapter, 49")
        XCTAssertEqual(r.chapters[2].statedDuration, 12)
        XCTAssertEqual(r.chapters[1].color, EmbeddedColor(red: 0xE9, green: 0x6F, blue: 0x24))
    }

    func testFilesWithoutXMPGiveNone() throws {
        for name in ["r-both.mp4", "r-track.mov", "r-chpl.mp4", "r-chap0.mov"] {
            let r = XMPMarkers.read(url: try fixture(name))
            XCTAssertEqual(r.status, XMPMarkers.Status.none, name)
            XCTAssertEqual(r.items.count, 0, name)
        }
        XCTAssertEqual(XMPMarkers.read(url: URL(fileURLWithPath: "/nonexistent/x.mov")).status, .unreadable)
    }

    func testATruncatedCopyGivesZeroMarkers() throws {
        // The MP4 cut 100 bytes short: the walk meets a uuid box that runs past the end.
        let d = try Data(contentsOf: try fixture("x-uuid.mp4"))
        let r = XMPMarkers.read(XMPDataSource(d.prefix(d.count - 100)))
        XCTAssertEqual(r.status, .badBoxes)
        XCTAssertEqual(r.items.count, 0)
    }

    // MARK: Opt-in probe (CHAPTER_MARKERS_PLAN §16)

    /// `MANIFOLD_XMP_PROBE_LIST=<file of paths, one per line> swift test --filter XMPFileTests/testXMPProbe`
    /// Prints, per file: the XMP status, where, size and counts per kind (shown and skipped); each Chapter/Comment's kind,
    /// startTime and duration in frames at its track rate, color (hex, Premiere name, converted color) and whether it
    /// has a name, comment and GUID; then the layer after mapping with libav's chapters (frames, kinds, sources, stated
    /// durations, duplicates). NEVER a name, comment or GUID. Skipped without the variable.
    func testXMPProbe() async throws {
        guard let list = ProcessInfo.processInfo.environment["MANIFOLD_XMP_PROBE_LIST"] else {
            throw XCTSkip("MANIFOLD_XMP_PROBE_LIST not set")
        }
        let paths = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        for p in paths {
            let url = URL(fileURLWithPath: p)
            let t0 = Date()
            let xmp = XMPMarkers.read(url: url)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            var lines = [MarkerLog.xmp(xmp, readMs: ms).replacingOccurrences(of: "[MARKERS] xmp", with: "[XMP-PROBE] \(url.lastPathComponent)")]
            for (i, c) in xmp.items.enumerated() {
                let color = c.color.map { String(format: "#%02X%02X%02X", $0.red, $0.green, $0.blue) } ?? "none"
                let premiere = c.color.map { PremiereMarkerColor(nearest: $0).rawValue } ?? "-"
                let dur = c.statedDuration.map { "\($0.value)" } ?? "none"
                lines.append("    #\(i) \(c.kind.label) start=\(c.start.value) rate=\(c.start.den)/\(c.start.num) duration=\(dur) "
                             + "color=\(color) premiere=\(premiere) converts-to=\(PremiereMarkerColor.markerColor(for: c.color).name) "
                             + "name=\(c.title.isEmpty ? "no" : "yes") comment=\(c.comment.isEmpty ? "no" : "yes") "
                             + "guid=\(c.stableID == nil ? "no" : "yes")")
            }
            let libav = try? ChapterReader.read(url: url)
            let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            let rate = ProcessInfo.processInfo.environment["MANIFOLD_CHAPTER_PROBE_RATE"].flatMap(Double.init) ?? 24000.0 / 1001
            let lastFrame = Int((seconds * rate).rounded()) - 1
            let r = ChapterMapping.map((libav?.chapters ?? []) + xmp.items, origin: libav?.videoStart ?? .zero, rate: rate,
                                       lastFrame: lastFrame)
            lines.append("    layer: libav-chapters=\(libav?.chapters.count ?? -1) shown=\(r.chapters.count) duplicates=\(r.duplicates) "
                         + "past-end=\(r.droppedPastEnd) last-frame=\(lastFrame)")
            for c in r.chapters {
                lines.append("      frame=\(c.frame) \(c.kind.label) source=\(c.source.rawValue) duration=\(c.duration) "
                             + "band=\(c.statedDuration.map(String.init) ?? "none") outline=\(c.color.map { String(format: "#%02X%02X%02X", $0.red, $0.green, $0.blue) } ?? "neutral")")
            }
            print(lines.joined(separator: "\n"))
        }
    }
}
