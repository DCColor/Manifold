import XCTest
@testable import Markers

/// The read-only chapter layer beside the markers (docs/CHAPTER_MARKERS_PLAN.md §4.1, §6.4; Stage 2): what the lists, the
/// strip, ⇧↑/⇧↓ and the thumbnailer are given.
final class ChapterLayerTests: XCTestCase {

    private func ch(_ i: Int, _ frame: Int, _ title: String = "") -> MappedChapter {
        MappedChapter(fileIndex: i, frame: frame, duration: 10, title: title)
    }

    // MARK: The filter and Show Chapters

    func testNoFilterShowsEverything() {
        let markers = [Marker(frame: 5, color: .red), Marker(frame: 15, color: .blue)]
        let chapters = [ch(0, 0), ch(1, 10)]
        let f = MarkerFilter()
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(ChapterLayer.visibleMarkers(markers, filter: f).count, 2)
        XCTAssertEqual(ChapterLayer.visibleChapters(chapters, markers: markers, filter: f, showChapters: true).count, 2)
    }

    func testAColourFilterHidesChaptersUnlessTheChipIsChosen() {
        let markers = [Marker(frame: 5, color: .red), Marker(frame: 15, color: .blue)]
        let chapters = [ch(0, 0), ch(1, 10)]
        let red = MarkerFilter(colors: [.red])
        XCTAssertEqual(ChapterLayer.visibleMarkers(markers, filter: red).map(\.frame), [5])
        XCTAssertEqual(ChapterLayer.visibleChapters(chapters, markers: markers, filter: red, showChapters: true), [])
        let redAndChapters = MarkerFilter(colors: [.red], chapters: true)
        XCTAssertEqual(ChapterLayer.visibleMarkers(markers, filter: redAndChapters).map(\.frame), [5])
        XCTAssertEqual(ChapterLayer.visibleChapters(chapters, markers: markers, filter: redAndChapters, showChapters: true).count, 2)
        // The chip alone: chapters only.
        let chip = MarkerFilter(chapters: true)
        XCTAssertTrue(chip.isActive)
        XCTAssertEqual(ChapterLayer.visibleMarkers(markers, filter: chip), [])
        XCTAssertEqual(ChapterLayer.visibleChapters(chapters, markers: markers, filter: chip, showChapters: true).count, 2)
    }

    func testShowChaptersOffHidesThemWhateverTheFilter() {
        let chapters = [ch(0, 0)]
        for f in [MarkerFilter(), MarkerFilter(chapters: true)] {
            XCTAssertEqual(ChapterLayer.visibleChapters(chapters, markers: [], filter: f, showChapters: false), [])
        }
    }

    func testConvertedChaptersAreSuppressed() {
        // §3.3: a chapter whose frame holds a marker with the same name is shown as that marker only.
        let chapters = [ch(0, 0, "Opening"), ch(1, 10, "Second")]
        let markers = [Marker(frame: 0, name: "Opening", keywords: ["chapter"]), Marker(frame: 10, name: "mine")]
        XCTAssertEqual(ChapterLayer.visibleChapters(chapters, markers: markers, filter: MarkerFilter(), showChapters: true)
                       .map(\.title), ["Second"])
    }

    // MARK: Rows

    func testRowsInterleaveByFrameMarkerFirstAndChaptersInFileOrder() {
        let markers = [Marker(frame: 10, name: "m10"), Marker(frame: 30, name: "m30")]
        let chapters = [ch(0, 0), ch(1, 10), ch(3, 20), ch(2, 20), ch(4, 40)]
        let rows = ChapterLayer.rows(markers: markers, chapters: chapters)
        XCTAssertEqual(rows.map(\.id), [.chapter(0), .marker(markers[0].id), .chapter(1), .chapter(3), .chapter(2),
                                        .marker(markers[1].id), .chapter(4)])
        XCTAssertEqual(rows.map(\.frame), [0, 10, 10, 20, 20, 30, 40])
        XCTAssertEqual(ChapterLayer.rows(markers: [], chapters: []), [])
        XCTAssertEqual(ChapterLayer.rows(markers: markers, chapters: []).count, 2)
    }

    func testRowIDsDoNotCollide() {
        // A chapter's id is its file index; a marker's, its UUID: two kinds, never equal.
        let rows = ChapterLayer.rows(markers: [Marker(frame: 0)], chapters: [ch(0, 0)])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows[1].lastFrame, 9)
    }

    // MARK: The header count

    func testCountLabel() {
        XCTAssertEqual(ChapterLayer.countLabel(markersShown: 12, markersTotal: 12, chaptersShown: 8, chaptersTotal: 8),
                       "12 markers · 8 chapters")
        XCTAssertEqual(ChapterLayer.countLabel(markersShown: 3, markersTotal: 12, chaptersShown: 0, chaptersTotal: 8),
                       "3 of 12 markers · 0 of 8 chapters")
        XCTAssertEqual(ChapterLayer.countLabel(markersShown: 1, markersTotal: 1, chaptersShown: 1, chaptersTotal: 1),
                       "1 marker · 1 chapter")
        XCTAssertEqual(ChapterLayer.countLabel(markersShown: 0, markersTotal: 0, chaptersShown: 0, chaptersTotal: 0),
                       "0 markers", "no chapters part on a file without them")
    }

    // MARK: Navigation union (D-C6)

    func testNavigationWalksVisibleMarkersAndChaptersOncePerFrame() {
        let markers = [Marker(frame: 10, color: .red), Marker(frame: 30, color: .blue), Marker(frame: 50, color: .red)]
        let chapters = [ch(0, 0), ch(1, 10), ch(2, 20), ch(3, 20)]
        let all = ChapterLayer.navigationFrames(
            visibleMarkers: ChapterLayer.visibleMarkers(markers, filter: MarkerFilter()),
            visibleChapters: ChapterLayer.visibleChapters(chapters, markers: markers, filter: MarkerFilter(), showChapters: true))
        XCTAssertEqual(all, [0, 10, 20, 30, 50], "deduplicated: 10 holds both, 20 two chapters")
        // Walking forward from 0 stops on each once.
        var f = 0, stops: [Int] = []
        while let n = ChapterMapping.neighbour(of: f, forward: true, in: all) { stops.append(n); f = n }
        XCTAssertEqual(stops, [10, 20, 30, 50])
        // Chapters hidden: markers only.
        let hidden = ChapterLayer.navigationFrames(
            visibleMarkers: markers,
            visibleChapters: ChapterLayer.visibleChapters(chapters, markers: markers, filter: MarkerFilter(), showChapters: false))
        XCTAssertEqual(hidden, [10, 30, 50])
        // A red filter without the chip: red markers only.
        let red = MarkerFilter(colors: [.red])
        let filtered = ChapterLayer.navigationFrames(
            visibleMarkers: ChapterLayer.visibleMarkers(markers, filter: red),
            visibleChapters: ChapterLayer.visibleChapters(chapters, markers: markers, filter: red, showChapters: true))
        XCTAssertEqual(filtered, [10, 50])
    }

    // MARK: Thumbnail union (§4.1)

    func testThumbnailFramesIgnoreFiltersAndKeepChaptersWhenAMarkerGoes() {
        let chapters = [ch(0, 100), ch(1, 300)]
        let before = ChapterLayer.thumbnailFrames(markers: [Marker(frame: 100), Marker(frame: 200)], chapters: chapters)
        XCTAssertEqual(before, [100, 200, 300])
        let after = ChapterLayer.thumbnailFrames(markers: [Marker(frame: 200)], chapters: chapters)
        XCTAssertEqual(after, [100, 200, 300], "deleting the marker on 100 keeps the chapter's frame")
        // The feed tells the thumbnailer: the frames changed (200 kept, 100 kept through the chapter).
        var feed = ThumbnailFeed()
        feed.update(frames: before, rate: 25)
        XCTAssertFalse(feed.update(frames: after, rate: 25), "same set: nothing to resync, nothing dropped")
        // Even a converted chapter (its marker then deleted) keeps its frame: the union takes EVERY chapter.
        let converted = [Marker(frame: 100, name: "")]
        XCTAssertTrue(ChapterLayer.thumbnailFrames(markers: converted, chapters: chapters).contains(300))
    }

    func testDeletingAMarkerKeepsTheChaptersThumbnailOnDisk() {
        // What `MarkerThumbnailer.sync` does on disk (`keepOnly`) with the union the model hands it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chthumbs-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = MarkerThumbnailCache(directory: dir)
        let fp = String(repeating: "5e", count: 32)
        let chapters = [ch(0, 100)]
        var markers = [Marker(frame: 100), Marker(frame: 200)]
        for f in ChapterLayer.thumbnailFrames(markers: markers, chapters: chapters) { cache.write(Data([UInt8(f % 256)]), fingerprint: fp, frame: f) }
        markers.removeAll { $0.frame == 100 }   // delete the marker sharing the chapter's frame
        cache.keepOnly(ChapterLayer.thumbnailFrames(markers: markers, chapters: chapters), fingerprint: fp)
        XCTAssertNotNil(cache.read(fingerprint: fp, frame: 100), "the chapter's thumbnail survives")
        XCTAssertNotNil(cache.read(fingerprint: fp, frame: 200))
        // Delete the other marker too: the chapter's thumbnail still survives, the folder stays.
        markers = []
        cache.keepOnly(ChapterLayer.thumbnailFrames(markers: markers, chapters: chapters), fingerprint: fp)
        XCTAssertNotNil(cache.read(fingerprint: fp, frame: 100))
        XCTAssertNil(cache.read(fingerprint: fp, frame: 200))
    }

    // MARK: The row's tooltip

    func testRowToolTipIsTimecodeAndTitleThenTheReadOnlyLine() {
        XCTAssertEqual(ChapterLayer.rowToolTip(ch(0, 240, "Second"), timecode: "01:00:10:00"),
                       "Chapter · 01:00:10:00 · Second\nChapter from the file · Convert to edit")
        XCTAssertEqual(ChapterLayer.rowToolTip(ch(0, 0), timecode: "01:00:00:00"),
                       "Chapter · 01:00:00:00\nChapter from the file · Convert to edit", "an empty title is left out")
    }

    // MARK: Convert and its notice

    func testConvertNoticeCounts() {
        let items = [ch(0, 0, "a"), ch(1, 10, "b"), ch(2, 20, "c")]
        let existing = [Marker(frame: 10, name: "someone's"), Marker(frame: 20, name: "c")]
        let r = ChapterMapping.convert(items, into: existing)
        XCTAssertEqual(r.added.count, 1)
        XCTAssertEqual(ChapterLayer.convertNotice(r),
                       "Converted 1 chapter to markers. 1 skipped: another marker starts on its frame; 1 already a marker.")
        XCTAssertEqual(ChapterLayer.convertNotice(ChapterMapping.convert([], into: [])), "No chapters converted.")
    }

    func testConvertThenRestoreIsTheUndo() {
        // `MarkerModel.convert` applies `existing + added` as one step and registers the old list as its undo; the old
        // list is untouched by Convert, so restoring it removes exactly the converted markers.
        let existing = [Marker(frame: 5, name: "mine")]
        let r = ChapterMapping.convert([ch(0, 0, "a"), ch(1, 10, "b")], into: existing)
        let applied = existing + r.added
        XCTAssertEqual(applied.count, 3)
        let undone = applied.filter { m in !r.added.contains { $0.id == m.id } }
        XCTAssertEqual(undone, existing)
        // After the undo the chapters are unconverted again, so they show.
        XCTAssertEqual(ChapterMapping.unconverted([ch(0, 0, "a"), ch(1, 10, "b")], markers: undone).count, 2)
        XCTAssertEqual(ChapterMapping.unconverted([ch(0, 0, "a"), ch(1, 10, "b")], markers: applied).count, 0)
    }

    // MARK: The stored marker (D-C14's id)

    func testEmbeddedIDIsOmittedWhenNilAndRoundTrips() throws {
        let enc = JSONEncoder()
        let plain = Marker(frame: 1, name: "x", created: Date(timeIntervalSince1970: 0))
        let json = String(data: try enc.encode(plain), encoding: .utf8)!
        XCTAssertFalse(json.contains("embeddedID"), "unchanged on disk for every marker without one")
        let withID = Marker(frame: 1, name: "x", created: Date(timeIntervalSince1970: 0), embeddedID: "g-1")
        XCTAssertEqual(try JSONDecoder().decode(Marker.self, from: enc.encode(withID)).embeddedID, "g-1")
        // A document written before the field existed decodes with nil.
        XCTAssertNil(try JSONDecoder().decode(Marker.self, from: Data(json.utf8)).embeddedID)
    }

    // MARK: Settings

    func testShowChaptersDefaultsOn() {
        let suite = "chapters-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertTrue(MarkerSettings.showChapters(d))
        d.set(false, forKey: MarkerSettings.showChaptersKey)
        XCTAssertFalse(MarkerSettings.showChapters(d))
        XCTAssertNotEqual(MarkerSettings.showChaptersKey, MarkerSettings.showKey)
    }
}
