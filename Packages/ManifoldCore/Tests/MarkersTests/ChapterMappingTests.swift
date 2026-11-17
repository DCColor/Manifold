import XCTest
@testable import Markers
import SMPTETimecode

/// Embedded chapters on the marker frame index (docs/CHAPTER_MARKERS_PLAN.md §3, D-C4, D-C6, D-C7, D-C8). Pure: the times
/// below are what a container states, as `ChapterReader` hands them over.
final class ChapterMappingTests: XCTestCase {

    static let r2398 = 24000.0 / 1001
    static let r2997 = 30000.0 / 1001

    private func ms(_ v: Int64) -> ChapterTime { ChapterTime(value: v, num: 1, den: 1000) }
    private func chapter(_ start: ChapterTime, _ end: ChapterTime? = nil, _ title: String = "") -> FileChapter {
        FileChapter(start: start, end: end, title: title)
    }

    // MARK: Rate

    func testExactRates() {
        XCTAssertEqual(ChapterMapping.exactRate(Self.r2398)?.num, 24000)
        XCTAssertEqual(ChapterMapping.exactRate(Self.r2398)?.den, 1001)
        XCTAssertEqual(ChapterMapping.exactRate(23.976)?.num, 24000)
        XCTAssertEqual(ChapterMapping.exactRate(23.98)?.num, 24000, "ffmpeg's rounded label is still NTSC")
        XCTAssertEqual(ChapterMapping.exactRate(29.97)?.num, 30000)
        XCTAssertEqual(ChapterMapping.exactRate(59.94)?.num, 60000)
        XCTAssertEqual(ChapterMapping.exactRate(25)?.num, 25)
        XCTAssertEqual(ChapterMapping.exactRate(25)?.den, 1)
        XCTAssertEqual(ChapterMapping.exactRate(24)?.num, 24)
        XCTAssertEqual(ChapterMapping.exactRate(12.5)?.num, 12500)
        XCTAssertEqual(ChapterMapping.exactRate(12.5)?.den, 1000)
        XCTAssertNil(ChapterMapping.exactRate(0))
        XCTAssertNil(ChapterMapping.exactRate(.nan))
    }

    // MARK: The frame rule (D-C7)

    func testFrameExactAtEachRate() {
        // Every frame boundary stated in the frame's own time base lands on that frame.
        for n in [0, 1, 239, 240, 241, 1437, 86_399] {
            XCTAssertEqual(ChapterMapping.frame(of: ChapterTime(value: Int64(n), num: 1001, den: 24000), rate: Self.r2398), n)
            XCTAssertEqual(ChapterMapping.frame(of: ChapterTime(value: Int64(n), num: 1001, den: 30000), rate: Self.r2997), n)
            XCTAssertEqual(ChapterMapping.frame(of: ChapterTime(value: Int64(n), num: 1, den: 25), rate: 25), n)
        }
        // In a finer base too: 23.976 frame 240 = 10.01 s exactly = 240240/24000.
        XCTAssertEqual(ChapterMapping.frame(of: ChapterTime(value: 240_240, num: 1, den: 24000), rate: Self.r2398), 240)
        // chpl's 100 ns.
        XCTAssertEqual(ChapterMapping.frame(of: ChapterTime(value: 100_100_000, num: 1, den: 10_000_000), rate: Self.r2398), 240)
    }

    func testOneTickToleranceCatchesQuantizedFrameBoundaries() {
        // Frame 241 at 23.976 is 10.0516… s. Stored to the millisecond, truncated: 10.051 s = 240.99 frames → 241.
        XCTAssertEqual(ChapterMapping.frame(of: ms(10_051), rate: Self.r2398), 241)
        // Rounded up instead: 10.052 s = 241.01 → 241.
        XCTAssertEqual(ChapterMapping.frame(of: ms(10_052), rate: Self.r2398), 241)
        // Frame 721 = 30.0717 s, the 30.072 s ffmpeg's chapter track wrote (F1b) → 721.
        XCTAssertEqual(ChapterMapping.frame(of: ms(30_072), rate: Self.r2398), 721)
        // A truly mid-frame 10.0505 s in 100 ns units (240.97 frames): one 100 ns tick is no help → 240.
        XCTAssertEqual(ChapterMapping.frame(of: ChapterTime(value: 100_505_000, num: 1, den: 10_000_000), rate: Self.r2398), 240)
        // Without a tolerance a plain floor would have said 240 for 10.051 s.
        XCTAssertEqual(Int((10.051 * Self.r2398).rounded(.down)), 240)
    }

    func testMidFrameChaptersFloorToTheFrameShowing() {
        XCTAssertEqual(ChapterMapping.frame(of: ms(10_500), rate: Self.r2398), 251)   // 251.75
        XCTAssertEqual(ChapterMapping.frame(of: ms(30_000), rate: Self.r2398), 719)   // 719.28
        XCTAssertEqual(ChapterMapping.frame(of: ms(20_020), rate: Self.r2398), 480)   // exact
        XCTAssertEqual(ChapterMapping.frame(of: ms(1_999), rate: 25), 50)             // 49.975 + 0.025 = 50.000: within one tick of 50
        XCTAssertEqual(ChapterMapping.frame(of: ms(1_998), rate: 25), 49)             // 49.95 + 0.025 → 49
    }

    /// Real-app values (CHAPTER_MARKERS_PLAN §11, W1, 2026-11-16; times only). Premiere's chapter track is frame-exact in
    /// 1/24000. Resolve's is 1/24000 too, but its times were first rounded to MILLISECONDS (its own chpl says 2.419 /
    /// 10.594 / 22.731 s), so a value can sit two ticks before the frame it was made on: 58056 against frame 58's 58058.
    /// Under D-C7 as decided (one tick of the container's own base) that chapter lands on 57. Pinned here so a change of
    /// rule (the §8 amendment) is a deliberate one.
    func testRealAppTicksUnderDC7() {
        func t(_ v: Int64) -> ChapterTime { ChapterTime(value: v, num: 1, den: 24000) }
        // Premiere ProRes .mov: 101, 280, 532 exactly (and its XMP markers say the same frames).
        XCTAssertEqual([101_101, 280_280, 532_532].map { ChapterMapping.frame(of: t($0), rate: Self.r2398) }, [101, 280, 532])
        // Resolve: 58056 (2 ticks short of 58) → 57; 254256 (2 over 254) → 254; 545544 (1 short of 545) → 545.
        XCTAssertEqual([58_056, 254_256, 545_544].map { ChapterMapping.frame(of: t($0), rate: Self.r2398) }, [57, 254, 545])
        // The same chapters as Resolve's chpl states them (100 ns): 2.419 s → 57 as well; one 100 ns tick is no help.
        XCTAssertEqual(ChapterMapping.frame(of: ChapterTime(value: 24_190_000, num: 1, den: 10_000_000), rate: Self.r2398), 57)
    }

    func testToleranceIsCappedAtHalfAFrame() {
        // A whole-second time base at 25 fps: one tick is 25 frames, capped at ½. 3 s → 75, never pushed further.
        XCTAssertEqual(ChapterMapping.frame(of: ChapterTime(value: 3, num: 1, den: 1), rate: 25), 75)
    }

    func testOriginIsSubtractedExactly() {
        // Chapter at 2.04 s, video start 1 s (r-offset.mp4): 1.04 s at 25 → 26.
        XCTAssertEqual(ChapterMapping.frame(of: ChapterTime(value: 20_400_000, num: 1, den: 10_000_000),
                                            origin: ChapterTime(value: 12800, num: 1, den: 12800), rate: 25), 26)
        // Origins in a different base from the chapter's: 2 frames of 1/24000 (2002) off a 1/1000 chapter.
        XCTAssertEqual(ChapterMapping.frame(of: ms(10_093), origin: ChapterTime(value: 2002, num: 1, den: 24000),
                                            rate: Self.r2398), 240)
        // Before the origin → negative.
        XCTAssertEqual(ChapterMapping.frame(of: .zero, origin: ChapterTime(value: 1, num: 1, den: 1), rate: 25), -25)
    }

    func testZeroTimeBaseIsUnreadable() {
        XCTAssertNil(ChapterMapping.frame(of: ChapterTime(value: 5, num: 1, den: 0), rate: 25))
        XCTAssertNil(ChapterMapping.frame(of: ChapterTime(value: 5, num: 0, den: 1), rate: 25))
        let r = ChapterMapping.map([chapter(ChapterTime(value: 5, num: 1, den: 0))], rate: 25, lastFrame: 100)
        XCTAssertEqual(r.droppedUnreadable, 1)
        XCTAssertEqual(ChapterMapping.map([chapter(ms(0))], rate: 0, lastFrame: 100).droppedUnreadable, 1)
    }

    // MARK: Mapping (§3.1, §3.2)

    func testDurationsFromEndsNextChapterAndFileEnd() {
        let r = ChapterMapping.map([
            chapter(ms(0), ms(10_010), "A"),            // stated end → 240 frames
            chapter(ms(10_010), nil, "B"),              // no end → the next chapter
            chapter(ms(20_020), ms(20_020), "C"),       // zero length (Flip) → the next chapter
            chapter(ms(30_030), ms(29_000), "D"),       // end before start → the next chapter
            chapter(ms(40_040), nil, "E"),              // last, no end → the file's end
        ], rate: Self.r2398, lastFrame: 1437)
        XCTAssertEqual(r.chapters.map(\.frame), [0, 240, 480, 720, 960])
        XCTAssertEqual(r.chapters.map(\.duration), [240, 240, 240, 240, 1438 - 960])
        XCTAssertEqual(r.dropped, 0)
    }

    func testPastTheEndIsDroppedNotClampedAndEndsAreClamped() {
        let r = ChapterMapping.map([
            chapter(ms(0), ms(70_000), "runs past the end"),
            chapter(ms(70_000), ms(71_000), "starts past the end"),
            chapter(ms(59_935), nil, "starts on the last frame"),   // frame 1437 = 59.9349 s
        ], rate: Self.r2398, lastFrame: 1437)
        XCTAssertEqual(r.chapters.map(\.title), ["runs past the end", "starts on the last frame"])
        XCTAssertEqual(r.chapters.first?.duration, 1438, "clamped to the file's end")
        XCTAssertEqual(r.chapters.last?.frame, 1437)
        XCTAssertEqual(r.chapters.last?.duration, 1)
        XCTAssertEqual(r.droppedPastEnd, 1)
    }

    func testBeforeTheStart() {
        let origin = ChapterTime(value: 1, num: 1, den: 1)   // the video starts at 1 s
        let r = ChapterMapping.map([
            chapter(ms(0), ms(1_000), "ends exactly at frame 0"),
            chapter(ms(500), ms(2_000), "starts before, ends after"),
            chapter(ms(2_000), nil, "after"),
        ], origin: origin, rate: 25, lastFrame: 74)
        XCTAssertEqual(r.droppedBeforeStart, 1)
        XCTAssertEqual(r.chapters.map(\.frame), [0, 25])
        XCTAssertEqual(r.chapters.first?.duration, 25)
    }

    func testUnsortedInputAndTwoOnOneFrame() {
        let r = ChapterMapping.map([
            chapter(ms(20_000), nil, "late"),
            chapter(ms(10_000), nil, "first on 250"),
            chapter(ms(10_010), nil, "second on 250"),    // 250.25 → 250
            chapter(ms(0), nil, "start"),
        ], rate: 25, lastFrame: 1499)
        XCTAssertEqual(r.chapters.map(\.title), ["start", "first on 250", "second on 250", "late"])
        XCTAssertEqual(r.chapters.map(\.frame), [0, 250, 250, 500])
        XCTAssertEqual(r.chapters.map(\.fileIndex), [3, 1, 2, 0], "ties in file order")
        // The next chapter is the next one on a LATER frame, so both on 250 run to 500.
        XCTAssertEqual(r.chapters.map(\.duration), [250, 250, 250, 1000])
    }

    func testTitlesSingleLineAndEmptyStaysEmpty() {
        let r = ChapterMapping.map([chapter(ms(0), nil, ""), chapter(ms(1_000), nil, "two\nlines")], rate: 25, lastFrame: 99)
        XCTAssertEqual(r.chapters.map(\.title), ["", "two lines"])
    }

    // MARK: Timecode labels come from TimecodeBasis

    func testLabelsThroughTimecodeBasis() {
        // tmcd 01:00:00:00 at 23.976: frame 240 → 01:00:10:00.
        let tc = TimecodeBasis(startFrame: 86_400, nfr: 24, rate: Self.r2398, dropFrame: false, hasTimecode: true)
        let f = ChapterMapping.map([chapter(ChapterTime(value: 240, num: 1001, den: 24000))], rate: Self.r2398, lastFrame: 1437)
        XCTAssertEqual(tc.label(f.chapters[0].frame), "01:00:10:00")
        // 29.97 DF from 01:00:00;00: frame 1800 is 01:01:00;02, frame 1799 is 01:00:59;29.
        let df = TimecodeBasis(startFrame: SMPTETimecode.frameCount(label: "01:00:00;00", nfr: 30, fps: Self.r2997, dropFrame: true)!,
                               nfr: 30, rate: Self.r2997, dropFrame: true, hasTimecode: true)
        let d = ChapterMapping.map([chapter(ChapterTime(value: 1799, num: 1001, den: 30000)),
                                    chapter(ChapterTime(value: 1800, num: 1001, den: 30000))], rate: Self.r2997, lastFrame: 2097)
        XCTAssertEqual(d.chapters.map { df.label($0.frame) }, ["01:00:59;29", "01:01:00;02"])
        // No timecode, the D6 override relabels: frame 250 at 25 with 01:00:00:00 → 01:00:10:00.
        let ov = TimecodeBasis.forFile(rate: 25, timecodeStartFrame: nil, timecodeNFR: nil, dropFrame: false, overrideLabel: "01:00:00:00")
        XCTAssertEqual(ov.label(250), "01:00:10:00")
    }

    // MARK: Convert (D-C4, D-C8, D19)

    func testConvertIsBlueWithKeywordAndDurationThroughTheMergeRule() {
        let chapters = [MappedChapter(fileIndex: 0, frame: 0, duration: 240, title: "Opening"),
                        MappedChapter(fileIndex: 1, frame: 240, duration: 481, title: "Second"),
                        MappedChapter(fileIndex: 2, frame: 721, duration: 479, title: "Third")]
        let existing = [Marker(frame: 240, name: "someone's note"),      // occupied → skipped
                        Marker(frame: 721, name: "Third")]               // identical → merged
        let r = ChapterMapping.convert(chapters, into: existing, created: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r.added.count, 1)
        XCTAssertEqual(r.occupied, 1)
        XCTAssertEqual(r.identical, 1)
        let m = r.added[0]
        XCTAssertEqual(m.frame, 0)
        XCTAssertEqual(m.duration, 240)
        XCTAssertEqual(m.name, "Opening")
        XCTAssertEqual(m.color, .blue)
        XCTAssertEqual(m.keywords, ["chapter"])
        XCTAssertEqual(m.notes, "")
    }

    func testConvertedChaptersAreNotShownTwice() {
        let chapters = [MappedChapter(fileIndex: 0, frame: 0, duration: 10, title: "A"),
                        MappedChapter(fileIndex: 1, frame: 10, duration: 10, title: "B")]
        let markers = [Marker(frame: 0, name: "A"),          // converted: hidden
                       Marker(frame: 10, name: "mine")]      // a different marker on B's frame: B still shows
        XCTAssertEqual(ChapterMapping.unconverted(chapters, markers: markers).map(\.title), ["B"])
    }

    // MARK: Navigation (D-C6) and thumbnails (§4.1)

    func testNavigationWalksMarkersAndChaptersOncePerFrame() {
        let markers = [Marker(frame: 10), Marker(frame: 30)]
        let chapters = [MappedChapter(fileIndex: 0, frame: 0, duration: 10, title: ""),
                        MappedChapter(fileIndex: 1, frame: 10, duration: 10, title: ""),
                        MappedChapter(fileIndex: 2, frame: 20, duration: 10, title: "")]
        let stops = ChapterMapping.navigationFrames(markers: markers, chapters: chapters)
        XCTAssertEqual(stops, [0, 10, 20, 30])
        XCTAssertEqual(ChapterMapping.neighbour(of: 10, forward: true, in: stops), 20)
        XCTAssertEqual(ChapterMapping.neighbour(of: 10, forward: false, in: stops), 0)
        XCTAssertEqual(ChapterMapping.neighbour(of: 15, forward: false, in: stops), 10)
        XCTAssertNil(ChapterMapping.neighbour(of: 30, forward: true, in: stops))
        XCTAssertNil(ChapterMapping.neighbour(of: 0, forward: false, in: stops))
    }

    func testThumbnailFramesKeepAChapterFrameWhenItsMarkerIsDeleted() {
        let chapters = [MappedChapter(fileIndex: 0, frame: 100, duration: 1, title: "")]
        let before = ChapterMapping.thumbnailFrames(markers: [Marker(frame: 100), Marker(frame: 200)], chapters: chapters)
        XCTAssertEqual(before, [100, 200])
        let after = ChapterMapping.thumbnailFrames(markers: [Marker(frame: 200)], chapters: chapters)
        XCTAssertEqual(after, [100, 200], "deleting the marker on 100 keeps the chapter's thumbnail")
        XCTAssertEqual(ChapterMapping.thumbnailFrames(markers: [], chapters: []), [])
    }

    // MARK: Privacy

    func testChaptersLogLineHoldsNoTitle() {
        let sentinel = "SENTINEL-CHAPTER-91c2"
        let r = ChapterMapping.map([chapter(ms(0), nil, sentinel), chapter(ms(99_000), nil, sentinel)], rate: 25, lastFrame: 99)
        let lines = [MarkerLog.chapters(r, readMs: 4), MarkerLog.chaptersUnreadable()]
        for l in lines { XCTAssertFalse(l.contains(sentinel)) }
        XCTAssertEqual(lines[0], "[MARKERS] chapters n=1 dropped-past-end=1 dropped-before-start=0 unreadable=0 reader=libav read=4ms")
    }
}
