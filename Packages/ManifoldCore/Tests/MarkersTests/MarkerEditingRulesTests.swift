import XCTest
@testable import Markers
import SMPTETimecode

/// Robbie's first attended feedback (2026-11-15): timecode fields that behave like the transport's entry, one marker
/// per frame, Edit Marker's choice, and the thumbnail cache (docs/MARKERS_PLAN.md §3.3, §4.4).
final class MarkerEditingRulesTests: XCTestCase {

    static let r2398 = 24000.0 / 1001, r2997 = 30000.0 / 1001
    let b2398 = TimecodeBasis(startFrame: 0, nfr: 24, rate: r2398, dropFrame: false, hasTimecode: true)
    let b25 = TimecodeBasis(startFrame: 0, nfr: 25, rate: 25, dropFrame: false, hasTimecode: true)
    let b2997DF = TimecodeBasis(startFrame: 0, nfr: 30, rate: r2997, dropFrame: true, hasTimecode: true)

    // MARK: "100" (the reported bug: Duration "100" was stored as 100 frames)

    func testHundredIsOneSecondAtEveryRate() {
        for (basis, nfr) in [(b2398, 24), (b25, 25), (b2997DF, 30)] {
            XCTAssertEqual(basis.typedDuration("100", current: 1), nfr, "duration \(basis.rateLabel)")
            XCTAssertEqual(basis.durationLabel(basis.typedDuration("100", current: 1)!), "00:00:01:00")
            XCTAssertEqual(basis.typedFrame("100", current: 0), nfr, "time \(basis.rateLabel)")
            XCTAssertEqual(basis.label(basis.typedFrame("100", current: 0)!), basis.dropFrame ? "00:00:01;00" : "00:00:01:00")
            XCTAssertEqual(basis.typedDuration("1", current: 5), 1)
            XCTAssertEqual(basis.typedFrame("1", current: 0), 1)
        }
    }

    func testTimeFieldsFollowTheFileStart() {
        let b = TimecodeBasis(startFrame: 86_400, nfr: 24, rate: Self.r2398, dropFrame: false, hasTimecode: true)
        XCTAssertEqual(b.typedFrame("1000100", current: 0), 24)          // 01:00:01:00
        XCTAssertEqual(b.typedFrame("01:00:01:19", current: 0), 43)      // a pasted label
        XCTAssertEqual(b.typedFrame("1:00:01:19", current: 0), 43)       // one-digit group
    }

    func testFillFromRightNormalisesAsTimecodeEntryDoes() {
        XCTAssertEqual(b2398.typedDuration("75", current: 0), 75)        // 3 s 3 f at 24
        XCTAssertEqual(b2398.durationLabel(75), "00:00:03:03")
        XCTAssertEqual(b2398.typedDuration("115", current: 0), 39)       // 1 s 15 f
        let f = SMPTETimecode.fillFromRight(digits: [7, 5], nfr: 24)
        XCTAssertEqual([f.h, f.m, f.s, f.f], [0, 0, 3, 3])
    }

    func testRelativeEntries() {
        XCTAssertEqual(b2398.typedFrame("+10", current: 100), 110)
        XCTAssertEqual(b2398.typedFrame("=100", current: 100), 124)
        XCTAssertEqual(b2398.typedFrame("-1", current: 100), 99)
        XCTAssertEqual(b2398.typedFrame("−100", current: 100), 76)
        XCTAssertEqual(b2398.typedDuration("+1", current: 24), 25)
        XCTAssertEqual(b2398.typedDuration("-24", current: 48), 24)
    }

    func testDropFrameLabelThatDoesNotExistMovesToTheMinutesFirstFrame() {
        XCTAssertEqual(b2997DF.typedFrame("10000", current: 0), 1800)           // 00:01:00;00 → ;02
        XCTAssertEqual(b2997DF.label(1800), "00:01:00;02")
        XCTAssertEqual(b2997DF.typedFrame("100000", current: 0), 17_982)        // minute 10: no drop
        XCTAssertEqual(b2997DF.typedDuration("10000", current: 0), 1800)        // a duration is never DF
    }

    func testNotATimecode() {
        for t in ["", "abc", "123456789", "1:234", "1::2", "+", "12a"] {
            XCTAssertNil(TypedTimecode(t), t)
            XCTAssertNil(b2398.typedFrame(t, current: 0), t)
        }
        XCTAssertNil(b2398.typedFrame("24000000", current: 0))                  // 24:00:00:00
    }

    // MARK: One marker per frame

    func testOccupantAndEditChoice() {
        let a = Marker(frame: 10, created: Date(timeIntervalSince1970: 1))
        let b = Marker(frame: 40, created: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(MarkerRules.occupant(of: 10, in: [a, b])?.id, a.id)
        XCTAssertNil(MarkerRules.occupant(of: 10, in: [a, b], excluding: a.id))
        XCTAssertNil(MarkerRules.occupant(of: 11, in: [a, b]))
        XCTAssertEqual(MarkerRules.markerToEdit(at: 40, in: [a, b])?.id, b.id)   // exactly at the playhead
        XCTAssertEqual(MarkerRules.markerToEdit(at: 39, in: [a, b])?.id, a.id)   // the nearest before
        XCTAssertNil(MarkerRules.markerToEdit(at: 9, in: [a, b]))
    }

    func testImportSkipsOccupiedFramesAndMergesIdenticalOnes() {
        let here = Marker(frame: 10, name: "x", notes: "n")
        let identical = Marker(frame: 10, name: "x", notes: "n")
        let different = Marker(frame: 10, name: "y")
        let fresh = Marker(frame: 20)
        let sameFrameAsFresh = Marker(frame: 20, name: "z")
        let r = ResolveEDL.merge([identical, different, fresh, sameFrameAsFresh], into: [here])
        XCTAssertEqual(r.added.map(\.frame), [20])
        XCTAssertEqual(r.added.first?.id, fresh.id)
        XCTAssertEqual(r.identical, 1)
        XCTAssertEqual(r.occupied, 2)
    }

    // MARK: Thumbnail cache

    func testThumbnailCacheKeysAndClearing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = MarkerThumbnailCache(directory: dir)
        let fp = String(repeating: "0f", count: 32)
        XCTAssertNil(cache.url(fingerprint: "../x", frame: 1))
        XCTAssertNil(cache.url(fingerprint: fp, frame: -1))
        cache.write(Data([1]), fingerprint: fp, frame: 10)
        cache.write(Data([2]), fingerprint: fp, frame: 20)
        XCTAssertEqual(cache.read(fingerprint: fp, frame: 20), Data([2]))
        cache.keepOnly([20], fingerprint: fp)
        XCTAssertNil(cache.read(fingerprint: fp, frame: 10))
        XCTAssertEqual(cache.read(fingerprint: fp, frame: 20), Data([2]))
        cache.keepOnly([], fingerprint: fp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(fp).path))
    }
}

/// Follow-ups (Robbie, 2026-11-15): the cache version, regenerate, delete all, the two preferences.
final class MarkerFollowUpTests: XCTestCase {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("mk-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    func testThumbnailCacheIsVersionedAndOldVersionsArePurged() throws {
        let dir = tempDir()
        let cache = MarkerThumbnailCache(directory: dir)
        let fp = String(repeating: "ab", count: 32)
        // What the unversioned first build left: MarkerThumbnails/<fingerprint>/10.jpg.
        let old = dir.appendingPathComponent(fp)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data([9]).write(to: old.appendingPathComponent("10.jpg"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("v1"), withIntermediateDirectories: true)
        XCTAssertNil(cache.read(fingerprint: fp, frame: 10))          // never read from an older build
        XCTAssertTrue(cache.url(fingerprint: fp, frame: 10)!.path.contains("/v\(MarkerThumbnailCache.version)/"))
        cache.write(Data([1]), fingerprint: fp, frame: 10)
        cache.purgeOtherVersions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("v1").path))
        XCTAssertEqual(cache.read(fingerprint: fp, frame: 10), Data([1]))
    }

    func testRegenerateRemovesOnlyTheChosenFramesAndDeleteAllRemovesEverything() {
        let cache = MarkerThumbnailCache(directory: tempDir())
        let fp = String(repeating: "cd", count: 32)
        for f in [1, 2, 3] { cache.write(Data([UInt8(f)]), fingerprint: fp, frame: f) }
        cache.remove([2], fingerprint: fp)
        XCTAssertNotNil(cache.read(fingerprint: fp, frame: 1))
        XCTAssertNil(cache.read(fingerprint: fp, frame: 2))
        cache.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.path))
    }

    func testStoreDeleteAll() throws {
        let store = MarkerStore(directory: tempDir())
        for fp in ["aa", "bb"].map({ String(repeating: $0, count: 32) }) {
            try store.save(MarkerDocument(fingerprint: fp, markers: [Marker(frame: 1)]))
        }
        XCTAssertEqual(store.deleteAll(), 2)
        XCTAssertNil(try store.load(fingerprint: String(repeating: "aa", count: 32)))
        XCTAssertEqual(store.deleteAll(), 0)
    }

    func testPreferencesDefaultOn() throws {
        let suite = "markers-prefs-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        XCTAssertTrue(MarkerSettings.remember(d))
        XCTAssertTrue(MarkerSettings.show(d))
        d.set(false, forKey: MarkerSettings.rememberKey)
        d.set(false, forKey: MarkerSettings.showKey)
        XCTAssertFalse(MarkerSettings.remember(d))
        XCTAssertFalse(MarkerSettings.show(d))
    }
}

final class ThumbnailAttemptsTests: XCTestCase {
    /// A failed decode is retried once, then shows "no preview"; Regenerate starts it again; frames are exact.
    func testOneRetryThenNoPreview() {
        var a = ThumbnailAttempts()
        XCTAssertFalse(a.recordFailure(751))      // first failure: retried
        XCTAssertFalse(a.gaveUp(751))
        XCTAssertFalse(a.gaveUp(750))             // the frame beside it is its own
        XCTAssertTrue(a.recordFailure(751))       // second: no preview
        XCTAssertEqual(a.givenUp, [751])
        a.reset([751])
        XCTAssertFalse(a.gaveUp(751))
        a.recordFailure(1); a.recordFailure(1); a.recordFailure(2); a.recordFailure(2)
        a.keep([2])
        XCTAssertEqual(a.givenUp, [2])
        a.reset()
        XCTAssertTrue(a.givenUp.isEmpty)
    }
}
