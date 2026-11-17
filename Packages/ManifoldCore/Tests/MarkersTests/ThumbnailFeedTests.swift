import XCTest
@testable import Markers

/// Stored markers that load before the file's frame rate (docs/BUGS.md, 2026-11-15; `ThumbnailFeed`'s note). Each test
/// replays the calls `MarkerModel` makes, in the order a large file produces them: the markers' fingerprint and store read
/// finish first, the engine's metadata (the rate) lands after.
final class ThumbnailFeedTests: XCTestCase {
    private let stored: Set<Int> = [11508, 34526, 57542, 80559, 103575]   // five markers, frame numbers at 59.94
    private let file = URL(fileURLWithPath: "/tmp/premiere_chapters - prores.mov")

    /// What the thumbnailer would start next, from the feed it was last given.
    private func next(_ feed: ThumbnailFeed, made: Set<Int> = [], givenUp: Set<Int> = [], inFlight: Int? = nil,
                      shown: Bool = true, playing: Bool = false, ready: Bool = true) -> Int? {
        ThumbnailQueue.next(wanted: feed.frames, made: made, givenUp: givenUp, rate: feed.rate, inFlight: inFlight,
                            shown: shown, playing: playing, decoderReady: ready)
    }

    private func waiting(_ feed: ThumbnailFeed, made: Set<Int> = [], ready: Bool) -> Bool {
        ThumbnailQueue.waitingForDecoder(wanted: feed.frames, made: made, givenUp: [], rate: feed.rate, inFlight: nil,
                                         shown: true, playing: false, decoderReady: ready)
    }

    // MARK: Chapters mapped after the first sync (Stage 2 attended check, 2026-11-17)

    /// `premiere_chapters - prores.mov` opened for the first time: no markers stored, so `finishLoad` syncs an empty set;
    /// the chapters are mapped after (when the rate and length land) and reach the thumbnailer BEFORE the engine has set
    /// the decoder route. They must still all be made, without Regenerate, once the route is known.
    func testChaptersMappedAfterTheFirstSyncAndBeforeTheRouteStillGetThumbnails() {
        var feed = ThumbnailFeed()
        // finishLoad: no markers, no chapters yet (the rate may or may not be in).
        feed.update(frames: ChapterLayer.thumbnailFrames(markers: [], chapters: []), rate: nil)
        XCTAssertNil(next(feed))
        // The rate and length land: the chapters are mapped, and the model syncs the union.
        let chapters = [101, 280, 532].enumerated().map { MappedChapter(fileIndex: $0.offset, frame: $0.element, duration: 1, title: "") }
        let rate = 24000.0 / 1001
        XCTAssertTrue(feed.update(frames: ChapterLayer.thumbnailFrames(markers: [], chapters: chapters), rate: rate),
                      "the thumbnailer is told about the chapter frames")
        // The decoder route is not set yet: nothing starts (the first build started one and dropped it) ...
        var wait = DecoderWait(file: file)
        XCTAssertNil(next(feed, ready: false))
        XCTAssertTrue(waiting(feed, ready: false), "... the thumbnailer holds the work back ...")
        wait.wait()
        // ... until the engine reports the route decided for this file: that event starts it, no timer.
        XCTAssertTrue(wait.decided(file))
        XCTAssertFalse(wait.waiting)
        XCTAssertFalse(waiting(feed, ready: true))
        var made: Set<Int> = []
        while let f = next(feed, made: made, ready: true) { made.insert(f) }
        XCTAssertEqual(made, [101, 280, 532])
        // A repeat of the event (the route reinstalled after a tag rewrite) starts nothing more.
        XCTAssertFalse(wait.decided(file))
    }

    func testADecoderEventForAnotherFileDoesNothing() {
        let other = URL(fileURLWithPath: "/tmp/other file.mov")
        var wait = DecoderWait(file: file)
        wait.wait()
        XCTAssertFalse(wait.decided(other), "another file's route (a stale load, or another window's engine)")
        XCTAssertTrue(wait.waiting, "still waiting for its own")
        // The window moved on to another file: the old file's late event does nothing either.
        wait.reset(file: other)
        wait.wait()
        XCTAssertFalse(wait.decided(file))
        XCTAssertTrue(wait.decided(other))
        // Nothing waiting: even its own file's event starts nothing.
        var idle = DecoderWait(file: file)
        XCTAssertFalse(idle.decided(file))
    }

    func testNothingWaitsForTheRouteWhenThereIsNothingToMake() {
        var feed = ThumbnailFeed()
        feed.update(frames: [10], rate: 25)
        XCTAssertFalse(waiting(feed, made: [10], ready: false), "all made")
        XCTAssertFalse(ThumbnailQueue.waitingForDecoder(wanted: [10], made: [], givenUp: [], rate: 25, inFlight: nil,
                                                        shown: false, playing: false, decoderReady: false), "not shown")
        XCTAssertFalse(ThumbnailQueue.waitingForDecoder(wanted: [10], made: [], givenUp: [], rate: 0, inFlight: nil,
                                                        shown: true, playing: false, decoderReady: false), "no rate yet")
    }

    func testStoredMarkersLoadedBeforeTheRateAreRequestedOnceItArrives() {
        var feed = ThumbnailFeed()
        // finishLoad: the markers are in, the metadata is not (basis nil).
        XCTAssertTrue(feed.update(frames: stored, rate: nil))
        XCTAssertEqual(feed.rate, 0)
        XCTAssertNil(next(feed), "nothing can be decoded without the rate")
        // The metadata lands: the model reports it, and the thumbnailer must be told.
        XCTAssertTrue(feed.update(frames: stored, rate: 60000.0 / 1001.0))
        XCTAssertEqual(next(feed), 11508, "the first marker's thumbnail is requested once the rate arrives")
        // Each one made in turn, until all five are.
        var made: Set<Int> = []
        while let f = next(feed, made: made) { made.insert(f) }
        XCTAssertEqual(made, stored)
    }

    func testRegenerateBeforeTheRateWaitsAndAfterItRequestsEveryFrame() {
        var feed = ThumbnailFeed()
        feed.update(frames: stored, rate: nil)
        // Regenerate pressed before the metadata: the model syncs, nothing changed, nothing can start.
        XCTAssertFalse(feed.update(frames: stored, rate: nil))
        XCTAssertNil(next(feed))
        // The metadata, then Regenerate again: every thumbnail is dropped and each is requested.
        feed.update(frames: stored, rate: 25)
        XCTAssertFalse(feed.update(frames: stored, rate: 25), "Regenerate with the rate already known changes nothing")
        var made: Set<Int> = []
        while let f = next(feed, made: made) { made.insert(f) }
        XCTAssertEqual(made, stored)
    }

    func testARepublishedRateIsNotAChangeAndAMarkerChangeIs() {
        var feed = ThumbnailFeed()
        feed.update(frames: stored, rate: 24000.0 / 1001.0)
        XCTAssertFalse(feed.update(frames: stored, rate: 24000.0 / 1001.0), "the inspector republishes the same metadata")
        XCTAssertTrue(feed.update(frames: stored.union([5]), rate: 24000.0 / 1001.0))
        XCTAssertEqual(next(feed), 5)
    }

    func testAnUnusableRateIsNotKnown() {
        var feed = ThumbnailFeed()
        for r in [0, -25, .nan, .infinity] as [Double] {
            feed.update(frames: stored, rate: r)
            XCTAssertEqual(feed.rate, 0, "\(r)")
            XCTAssertNil(next(feed), "\(r)")
        }
    }

    /// The rules the thumbnailer had before, unchanged: one at a time, never while playing, only while shown, failures
    /// given up are skipped. (The 0.9.4 soak checks the "never while playing" half on the real build.)
    func testTheQueueStillWaitsForAPauseAViewAndTheOneInFlight() {
        var feed = ThumbnailFeed()
        feed.update(frames: stored, rate: 25)
        XCTAssertNil(next(feed, playing: true))
        XCTAssertNil(next(feed, shown: false))
        XCTAssertNil(next(feed, inFlight: 11508))
        XCTAssertEqual(next(feed, givenUp: [11508]), 34526)
        XCTAssertNil(next(feed, made: stored))
    }
}
