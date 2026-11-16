import XCTest
@testable import Markers

/// Stored markers that load before the file's frame rate (docs/BUGS.md, 2026-11-15; `ThumbnailFeed`'s note). Each test
/// replays the calls `MarkerModel` makes, in the order a large file produces them: the markers' fingerprint and store read
/// finish first, the engine's metadata (the rate) lands after.
final class ThumbnailFeedTests: XCTestCase {
    private let stored: Set<Int> = [11508, 34526, 57542, 80559, 103575]   // five markers, frame numbers at 59.94

    /// What the thumbnailer would start next, from the feed it was last given.
    private func next(_ feed: ThumbnailFeed, made: Set<Int> = [], givenUp: Set<Int> = [], inFlight: Int? = nil,
                      shown: Bool = true, playing: Bool = false) -> Int? {
        ThumbnailQueue.next(wanted: feed.frames, made: made, givenUp: givenUp, rate: feed.rate, inFlight: inFlight,
                            shown: shown, playing: playing)
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
