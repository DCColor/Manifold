import XCTest
import AVFoundation
import CoreMedia
@testable import ChapterRead
import Markers

/// The libav chapter reader on small fixtures (docs/CHAPTER_MARKERS_PLAN.md §6.4, §11), each ALSO read with AVFoundation
/// as the cross-check (D-C2). libav is asserted exactly; AVFoundation's answer is recorded (one `[CHAPTER-XCHECK]` line per
/// file, counts, times and "same title" flags only) and asserted only where the plan relies on it.
///
/// Fixtures (`Fixtures/`), 160×90, made once on 2026-11-16 with `/opt/homebrew/bin/ffmpeg` ("ffmpeg version
/// 8.1.1-https://www.martin-riedl.de", run only) by the script recorded in ~/Code/Manifold/fixtures/chapters/README.txt:
///  - r-tc-track.mov  H.264 23.976, 72 frames, tmcd 01:00:00:00, chapter track, no chpl (F1). ffmpeg's tref holds tmcd only.
///  - r-track.mov     the same without tmcd: chapter track linked by tref chap, no chpl (F1b).
///  - r-chpl.mp4      25 fps, 75 frames, chpl only: r-both.mp4 with its tref patched to free (F2).
///  - r-both.mp4      25 fps, chapter track and chpl (F3).
///  - r-offgrid.mp4   23.976 with B-frames (edit list, media time 2002), 1/1000 chapters off frames, zero length, past the end (F4).
///  - r-unicode.mp4   25 fps, a long non-ASCII title and one holding = ; # \ (F6).
///  - r-offset.mp4    25 fps, the video delayed 1 s with -itsoffset (an empty edit): libav's video start_time is 1 s.
///  - r-chap0.mov     r-track.mov with its video tref `chap` target set to track ID 0 (2026-11-17, a 4-byte patch of a
///                    copy, same size), as Premiere writes in a comment-only ProRes .mov (§12.6).
final class ChapterReaderTests: XCTestCase {

    private func fixture(_ name: String) throws -> URL {
        let parts = name.split(separator: ".")
        return try XCTUnwrap(Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]),
                                               subdirectory: "Fixtures"))
    }

    private func seconds(_ c: [FileChapter]) -> [Double] { c.map { ($0.start.seconds * 1000).rounded() / 1000 } }

    // MARK: F1: chapter track beside a timecode track — ffmpeg leaves it unlinked

    func testTimecodeAndChapterTrackInAMovGivesNoChapters() async throws {
        let url = try fixture("r-tc-track.mov")
        let r = try ChapterReader.read(url: url)
        XCTAssertEqual(r.chapters.count, 0, "ffmpeg's video tref holds tmcd only, so the chapter track is a mov_text stream")
        XCTAssertTrue(r.hasVideo)
        await crossCheck(url, libav: r)
    }

    // MARK: F1b: chapter track only

    func testChapterTrackOnly() async throws {
        let url = try fixture("r-track.mov")
        let r = try ChapterReader.read(url: url)
        XCTAssertEqual(r.chapters.map(\.title), ["Opening", "Second", "Last"])
        // The chapter track's time base is milliseconds: frame 24 (1.001 s) and frame 49 (2.0437… s → 2.044).
        XCTAssertEqual(r.chapters.first?.start.num, 1)
        XCTAssertEqual(r.chapters.first?.start.den, 1000)
        XCTAssertEqual(seconds(r.chapters), [0, 1.001, 2.044])
        let mapped = ChapterMapping.map(r.chapters, origin: r.videoStart, rate: 24000.0 / 1001, lastFrame: 71)
        XCTAssertEqual(mapped.chapters.map(\.frame), [0, 24, 49], "the tick tolerance puts 2.044 s on frame 49")
        XCTAssertEqual(mapped.chapters.map(\.duration), [24, 25, 23])
        XCTAssertEqual(Set(r.chapters.map(\.source)), [.chapterTrack], "1/1000: the chapter track")
        await crossCheck(url, libav: r)
    }

    // MARK: A chap tref pointing at track ID 0 (Premiere's comment-only .mov)

    func testChapReferenceToTrackZeroGivesNoChaptersAndNoError() async throws {
        let url = try fixture("r-chap0.mov")
        let r = try ChapterReader.read(url: url)   // no throw
        XCTAssertEqual(r.chapters.count, 0)
        XCTAssertTrue(r.hasVideo)
        let mapped = ChapterMapping.map(r.chapters, origin: r.videoStart, rate: 24000.0 / 1001, lastFrame: 71)
        XCTAssertEqual(mapped.chapters.count, 0)
        XCTAssertEqual(mapped.dropped, 0)
        await crossCheck(url, libav: r)
    }

    // MARK: F2: chpl only

    func testNeroChplOnly() async throws {
        let url = try fixture("r-chpl.mp4")
        let r = try ChapterReader.read(url: url)
        XCTAssertEqual(r.chapters.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(r.chapters.first?.start.den, 10_000_000, "chpl is in 100 ns units")
        XCTAssertEqual(seconds(r.chapters), [0, 1, 2.04])
        let mapped = ChapterMapping.map(r.chapters, origin: r.videoStart, rate: 25, lastFrame: 74)
        XCTAssertEqual(mapped.chapters.map(\.frame), [0, 25, 51])
        XCTAssertEqual(Set(r.chapters.map(\.source)), [.chpl], "100 ns: the Nero list")
        await crossCheck(url, libav: r)
    }

    // MARK: F3: both forms

    func testBothFormsAreListedOnce() async throws {
        let url = try fixture("r-both.mp4")
        let r = try ChapterReader.read(url: url)
        XCTAssertEqual(r.chapters.map(\.title), ["One", "Two", "Three"], "each chapter once, not once per form")
        let mapped = ChapterMapping.map(r.chapters, origin: r.videoStart, rate: 25, lastFrame: 74)
        XCTAssertEqual(mapped.chapters.map(\.frame), [0, 25, 51])
        XCTAssertEqual(mapped.chapters.map(\.duration), [25, 26, 24])
        XCTAssertEqual(Set(r.chapters.map(\.source)), [.chapterTrack], "with both forms libav lists the track's")
        XCTAssertEqual(Set(mapped.chapters.map(\.kind)), [.chapter])
        XCTAssertTrue(mapped.chapters.allSatisfy { $0.color == nil && $0.statedDuration == nil && $0.stableID == nil },
                      "Stage 2: no colour, no stated duration, no id from libav")
        await crossCheck(url, libav: r)
    }

    // MARK: F4: off-frame, zero length, past the end, edit list

    func testOffFrameChaptersOnAnEditListedFile() async throws {
        let url = try fixture("r-offgrid.mp4")
        let r = try ChapterReader.read(url: url)
        XCTAssertEqual(r.chapters.count, 7)
        XCTAssertEqual(r.videoStart.value, 0, "libav's start_time is 0 after the B-frame edit (media time 2002)")
        let mapped = ChapterMapping.map(r.chapters, origin: r.videoStart, rate: 24000.0 / 1001, lastFrame: 71)
        XCTAssertEqual(mapped.chapters.map(\.frame), [0, 25, 35, 48, 59, 64])
        XCTAssertEqual(mapped.droppedPastEnd, 1)
        // libav fills the zero-length chapter's end with the next start (5 s), so it runs to the file's end.
        XCTAssertEqual(mapped.chapters.last?.duration, 72 - 64)
        await crossCheck(url, libav: r)
    }

    // MARK: F6: titles

    func testLongNonASCIIAndReservedCharacterTitles() async throws {
        let url = try fixture("r-unicode.mp4")
        let r = try ChapterReader.read(url: url)
        XCTAssertEqual(r.chapters.count, 2)
        let first = try XCTUnwrap(r.chapters.first?.title)
        XCTAssertTrue(first.hasPrefix("Café Zürich — Ærøskøbing, Łódź, 東京, Ελληνικά, 🎬 a long chapter title"))
        XCTAssertFalse(first.contains("\u{FFFD}"))
        XCTAssertEqual(r.chapters.last?.title, "Reserved = ; # \\ characters", "unescaped: libav's API has no ffmetadata layer")
        await crossCheck(url, libav: r)
    }

    // MARK: start_time

    func testVideoStartTimeIsReportedAndSubtracted() async throws {
        let url = try fixture("r-offset.mp4")
        let r = try ChapterReader.read(url: url)
        XCTAssertEqual(r.videoStart.seconds, 1, accuracy: 1e-9)
        XCTAssertEqual(seconds(r.chapters), [0, 1, 2.04], "chapters stay on the movie timeline; only the video moved")
        // On the libav timeline (frame 0 = the first video frame) the chapter at 1 s is frame 0, the one at 0 s is before it.
        let libavTimeline = ChapterMapping.map(r.chapters, origin: r.videoStart, rate: 25, lastFrame: 74)
        XCTAssertEqual(libavTimeline.chapters.map(\.frame), [0, 26])
        XCTAssertEqual(libavTimeline.droppedBeforeStart, 1)
        await crossCheck(url, libav: r)
    }

    // MARK: Unreadable

    func testAFileLibavCannotOpenThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/chapters.mov")
        XCTAssertThrowsError(try ChapterReader.read(url: missing)) { XCTAssertEqual($0 as? ChapterReader.ReadError, .open) }
    }

    // MARK: Cross-check

    /// AVFoundation's chapters for the same file, recorded beside libav's (no titles printed: only whether each matches).
    private func crossCheck(_ url: URL, libav: ChapterReader.Result) async {
        let av = await AVFChapters.read(url)
        let line = ChapterXCheck.line(file: url.lastPathComponent, libav: libav, avf: av)
        print(line)
        add(XCTAttachment(string: line))
    }

    // MARK: Opt-in probe (CHAPTER_MARKERS_PLAN §11)

    /// `MANIFOLD_CHAPTER_PROBE_LIST=<file of paths, one per line> swift test --filter ChapterReaderTests/testProbe`
    /// Prints one `[CHAPTER-PROBE]` block per file: counts, time bases, start/end seconds, read time, and title FLAGS only
    /// (non-ASCII present, U+FFFD present, libav title == AVFoundation title). Never a title. Skipped without the variable.
    func testProbe() async throws {
        guard let list = ProcessInfo.processInfo.environment["MANIFOLD_CHAPTER_PROBE_LIST"] else {
            throw XCTSkip("MANIFOLD_CHAPTER_PROBE_LIST not set")
        }
        let paths = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        for p in paths {
            let url = URL(fileURLWithPath: p)
            let t0 = Date()
            let r: ChapterReader.Result
            do { r = try ChapterReader.read(url: url) } catch {
                print("[CHAPTER-PROBE] \(url.lastPathComponent) libav: unreadable (\(error))")
                continue
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let av = await AVFChapters.read(url)
            print(ChapterXCheck.probe(file: url.lastPathComponent, libav: r, avf: av, readMs: ms))
        }
    }
}

/// AVFoundation's chapters, read two ways: Manifold's current Inspector rule (first available locale, else
/// `Locale.current`), and `bestMatchingPreferredLanguages`.
struct AVFChapters {
    struct Chapter { let start: Double; let duration: Double; let timescale: Int32; let title: String? }
    var locales: [String] = []
    var byLocale: [Chapter] = []
    var byPreferred: [Chapter] = []
    var error: String?

    static func read(_ url: URL) async -> AVFChapters {
        var out = AVFChapters()
        let asset = AVURLAsset(url: url)
        do {
            let locales = try await asset.load(.availableChapterLocales)
            out.locales = locales.map(\.identifier)
            let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locales.first ?? Locale.current,
                                                                   containingItemsWithCommonKeys: [])
            out.byLocale = await chapters(groups)
            let preferred = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"] + Locale.preferredLanguages)
            out.byPreferred = await chapters(preferred)
        } catch {
            out.error = "\(type(of: error))"
        }
        return out
    }

    private static func chapters(_ groups: [AVTimedMetadataGroup]) async -> [Chapter] {
        var result: [Chapter] = []
        for g in groups {
            var title: String?
            if let item = g.items.first(where: { $0.commonKey == .commonKeyTitle }) {
                title = (try? await item.load(.stringValue)) ?? nil
            }
            result.append(Chapter(start: g.timeRange.start.seconds, duration: g.timeRange.duration.seconds,
                                  timescale: g.timeRange.start.timescale, title: title))
        }
        return result
    }
}

/// One line per file, titles never printed.
enum ChapterXCheck {
    static func r3(_ d: Double) -> String { String(format: "%.3f", d) }

    static func line(file: String, libav: ChapterReader.Result, avf: AVFChapters) -> String {
        let lt = libav.chapters.map { r3($0.start.seconds) }.joined(separator: ",")
        let at = avf.byLocale.map { r3($0.start) }.joined(separator: ",")
        let sameStarts = libav.chapters.count == avf.byLocale.count
            && zip(libav.chapters, avf.byLocale).allSatisfy { abs($0.start.seconds - $1.start) < 0.0005 }
        let sameTitles = libav.chapters.count == avf.byLocale.count
            && zip(libav.chapters, avf.byLocale).allSatisfy { $0.title == ($1.title ?? "") }
        let tb = libav.chapters.first.map { "\($0.start.num)/\($0.start.den)" } ?? "-"
        let avTs = avf.byLocale.first.map { "1/\($0.timescale)" } ?? "-"
        return "[CHAPTER-XCHECK] \(file) libav n=\(libav.chapters.count) tb=\(tb) videoStart=\(r3(libav.videoStart.seconds)) starts=[\(lt)] | "
            + "avf locales=\(avf.locales) n=\(avf.byLocale.count) preferred-n=\(avf.byPreferred.count) ts=\(avTs) starts=[\(at)]"
            + (avf.error.map { " error=\($0)" } ?? "")
            + " | same-starts=\(sameStarts ? "yes" : "no") same-titles=\(sameTitles ? "yes" : "no")"
    }

    static func probe(file: String, libav: ChapterReader.Result, avf: AVFChapters, readMs: Int) -> String {
        let rate = ProcessInfo.processInfo.environment["MANIFOLD_CHAPTER_PROBE_RATE"].flatMap(Double.init)
        var lines = [line(file: file, libav: libav, avf: avf).replacingOccurrences(of: "[CHAPTER-XCHECK]", with: "[CHAPTER-PROBE]")
                     + " read=\(readMs)ms"]
        for (i, c) in libav.chapters.enumerated() {
            let a = i < avf.byLocale.count ? avf.byLocale[i] : nil
            let nonASCII = c.title.unicodeScalars.contains { $0.value > 127 }
            let fffd = c.title.contains("\u{FFFD}")
            let match = a.map { $0.title == c.title } ?? false
            let end = c.end.map { r3($0.seconds) } ?? "none"
            // UTF-8 read as Latin-1/Mac Roman shows up as Ã or Â before another accented letter.
            let mojibake = c.title.contains("Ã") || c.title.contains("Â")
            let frame = rate.flatMap { ChapterMapping.frame(of: c.start, origin: libav.videoStart, rate: $0) }.map(String.init) ?? "-"
            lines.append("    #\(i) libav start=\(r3(c.start.seconds)) end=\(end) tb=\(c.start.num)/\(c.start.den) frame=\(frame) title-len=\(c.title.count) "
                         + "non-ascii=\(nonASCII ? "yes" : "no") fffd=\(fffd ? "yes" : "no") mojibake=\(mojibake ? "yes" : "no") | avf start=\(a.map { r3($0.start) } ?? "-") "
                         + "dur=\(a.map { r3($0.duration) } ?? "-") ts=\(a.map { String($0.timescale) } ?? "-") "
                         + "title-equal=\(match ? "yes" : "no")")
        }
        if avf.byLocale.count > libav.chapters.count {
            for (i, a) in avf.byLocale.enumerated().dropFirst(libav.chapters.count) {
                lines.append("    #\(i) libav - | avf start=\(r3(a.start)) dur=\(r3(a.duration)) ts=\(a.timescale)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
