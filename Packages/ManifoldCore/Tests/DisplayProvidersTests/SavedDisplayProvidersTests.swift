import XCTest
@testable import DisplayProviders

/// Stand-in for MetalVideoRenderer: the three providers, and a count of colour releases.
private final class FakeRenderer: DisplayProviderHost {
    var clock: (() -> Double)?
    var isPausedProvider: (() -> Bool)?
    var isFullRangeProvider: (() -> Bool)?
    /// How many times a live source told this renderer it had let go.
    var releases = 0
    func liveSourceReleased() { releases += 1 }
}

/// What `WindowDeck.configure` installs: the file engine's clock, pause state and range.
/// Distinct sentinel values so a test can tell whose closure is installed.
private func installFileProviders(_ r: FakeRenderer, time: Double = 12.5, paused: Bool = true,
                                  fullRange: Bool = true) {
    r.clock = { time }
    r.isPausedProvider = { paused }
    r.isFullRangeProvider = { fullRange }
}

/// What NDI's `start(with:)` and HLS's `connect` install: host time, never paused, video range.
private let hostSinceBoot = 600_000.0
private func installStreamProviders(_ r: FakeRenderer) {
    r.clock = { hostSinceBoot }
    r.isPausedProvider = { false }
    r.isFullRangeProvider = { false }
}

final class SavedDisplayProvidersTests: XCTestCase {

    /// THE DEFECT: an NDI session ends and the file's providers are back, all three.
    /// Before the fix the file played against host time, +195 ms picture-ahead at the device.
    func testProvidersRestoredAfterAnNDISessionEnds() {
        let r = FakeRenderer()
        installFileProviders(r)
        let saved = SavedDisplayProviders<FakeRenderer>()

        XCTAssertTrue(saved.save(from: r))          // connect
        installStreamProviders(r)
        XCTAssertEqual(r.clock?(), hostSinceBoot)

        XCTAssertTrue(saved.restore() === r)        // disconnect
        XCTAssertEqual(r.clock?(), 12.5)
        XCTAssertEqual(r.isPausedProvider?(), true)
        XCTAssertEqual(r.isFullRangeProvider?(), true)
        XCTAssertFalse(saved.isHolding)
    }

    /// NDI's source switch and HLS's swap re-enter the start path while connected. The second save
    /// must not capture the stream's own providers, or disconnect would restore the stream clock.
    func testSourceSwitchDoesNotOverwriteTheFileSave() {
        let r = FakeRenderer()
        installFileProviders(r)
        let saved = SavedDisplayProviders<FakeRenderer>()

        saved.save(from: r)
        installStreamProviders(r)
        XCTAssertFalse(saved.save(from: r))         // switch to another NDI source
        installStreamProviders(r)

        saved.restore()
        XCTAssertEqual(r.clock?(), 12.5)
        XCTAssertEqual(r.isPausedProvider?(), true)
        XCTAssertEqual(r.isFullRangeProvider?(), true)
    }

    /// Two sessions back to back: the second saves afresh and restores the file again.
    func testSecondSessionAfterARestoreSavesAgain() {
        let r = FakeRenderer()
        installFileProviders(r)
        let saved = SavedDisplayProviders<FakeRenderer>()

        saved.save(from: r); installStreamProviders(r); saved.restore()
        installFileProviders(r, time: 30.0, paused: false, fullRange: false)
        XCTAssertTrue(saved.save(from: r))
        installStreamProviders(r)
        saved.restore()
        XCTAssertEqual(r.clock?(), 30.0)
        XCTAssertEqual(r.isPausedProvider?(), false)
    }

    /// A restore with nothing held writes nothing: a stray disconnect must not un-clock a renderer
    /// showing a paused file.
    func testRestoreWithNothingHeldWritesNothing() {
        let r = FakeRenderer()
        installFileProviders(r)
        let saved = SavedDisplayProviders<FakeRenderer>()

        XCTAssertNil(saved.restore())
        XCTAssertEqual(r.clock?(), 12.5)

        saved.save(from: r); installStreamProviders(r); saved.restore()
        XCTAssertNil(saved.restore())               // second disconnect
        XCTAssertEqual(r.clock?(), 12.5)
    }

    /// Nil providers are restored as nil, verbatim, not left as the stream's.
    func testNilProvidersRestoreAsNil() {
        let r = FakeRenderer()
        let saved = SavedDisplayProviders<FakeRenderer>()
        saved.save(from: r)
        installStreamProviders(r)
        saved.restore()
        XCTAssertNil(r.clock)
        XCTAssertNil(r.isPausedProvider)
        XCTAssertNil(r.isFullRangeProvider)
    }

    /// Providers go back to the renderer they came from, never to another window's.
    func testRestoreTargetsTheRendererSavedFrom() {
        let a = FakeRenderer(), b = FakeRenderer()
        installFileProviders(a, time: 1.0)
        installFileProviders(b, time: 2.0)
        let saved = SavedDisplayProviders<FakeRenderer>()

        saved.save(from: a)
        installStreamProviders(a)
        installStreamProviders(b)
        XCTAssertTrue(saved.restore() === a)
        XCTAssertEqual(a.clock?(), 1.0)
        XCTAssertEqual(b.clock?(), hostSinceBoot)   // untouched
    }

    /// A closed window's renderer is not kept alive, and a later save starts clean.
    func testDeallocatedRendererIsNotHeld() {
        let saved = SavedDisplayProviders<FakeRenderer>()
        do {
            let r = FakeRenderer()
            installFileProviders(r)
            saved.save(from: r)
        }
        XCTAssertFalse(saved.isHolding)
        XCTAssertNil(saved.restore())

        let r2 = FakeRenderer()
        installFileProviders(r2, time: 7.0)
        XCTAssertTrue(saved.save(from: r2))
    }

    // MARK: - The colour release (stale scope colour, 2026-10-06)

    /// A session that ends releases the renderer's source colour exactly once — the live twin of
    /// `FrameEngine.stop()` publishing nil codes. Without it the scope headers and the chain
    /// readout kept describing the departed stream.
    func testASessionEndReleasesTheColourOnce() {
        let r = FakeRenderer()
        let saved = SavedDisplayProviders<FakeRenderer>()
        saved.save(from: r); installStreamProviders(r)
        XCTAssertEqual(r.releases, 0, "nothing is released while the stream holds the renderer")
        saved.restore()
        XCTAssertEqual(r.releases, 1)
        saved.restore()                             // a stray second disconnect
        XCTAssertEqual(r.releases, 1, "a restore with nothing held releases nothing")
    }

    /// A source switch (NDI's, HLS's) keeps its save and does not come through restore, so it
    /// releases nothing until the session finally ends — once.
    func testASourceSwitchReleasesOnlyWhenTheSessionEnds() {
        let r = FakeRenderer()
        let saved = SavedDisplayProviders<FakeRenderer>()
        saved.save(from: r); installStreamProviders(r)
        saved.save(from: r); installStreamProviders(r)   // switch
        XCTAssertEqual(r.releases, 0)
        saved.restore()
        XCTAssertEqual(r.releases, 1)
    }

    /// A restore that never saved (a connect that failed before taking the display) releases
    /// nothing, so it cannot clear the colour of a file another path is showing.
    func testARestoreThatNeverSavedReleasesNothing() {
        let r = FakeRenderer()
        let saved = SavedDisplayProviders<FakeRenderer>()
        XCTAssertNil(saved.restore())
        XCTAssertEqual(r.releases, 0)
    }

    /// The release goes to the renderer the session took, never to another window's.
    func testTheReleaseTargetsTheRendererSavedFrom() {
        let a = FakeRenderer(), b = FakeRenderer()
        let saved = SavedDisplayProviders<FakeRenderer>()
        saved.save(from: a)
        saved.restore()
        XCTAssertEqual(a.releases, 1)
        XCTAssertEqual(b.releases, 0)
    }
}
