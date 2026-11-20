import XCTest
import OutputPacing

/// The card-audio-callback watchdog's decision (docs/SDI_AUDIO_NIGHT7.md, fault (a)).
final class SDIAudioWatchdogTests: XCTestCase {
    private func input(_ callbacks: UInt64, at now: Double, running: Bool = true, sound: Bool = true, playing: Bool = true)
        -> SDIAudioWatchdog.Input {
        SDIAudioWatchdog.Input(outputRunning: running, hasSound: sound, playing: playing, callbacks: callbacks, now: now)
    }

    func testAdvancingCountNeverActs() {
        var w = SDIAudioWatchdog()
        for k in 0..<1000 { XCTAssertEqual(w.step(input(UInt64(k * 25), at: Double(k) * 0.25)), .none) }
    }

    func testStallOfThreeSecondsRecoversOnce() {
        var w = SDIAudioWatchdog()
        XCTAssertEqual(w.step(input(16722, at: 100)), .none)
        XCTAssertEqual(w.step(input(16722, at: 102.9)), .none)          // under 3 s
        XCTAssertEqual(w.step(input(16722, at: 103.0)), .recover(stalledFor: 3.0))
        XCTAssertEqual(w.step(input(16722, at: 110)), .none)            // the same stall is acted on once
    }

    func testPausedNoSoundOrNoOutputIsNotJudged() {
        for (running, sound, playing) in [(true, true, false), (true, false, true), (false, true, true)] {
            var w = SDIAudioWatchdog()
            for t in stride(from: 0.0, through: 20.0, by: 0.25) {
                XCTAssertEqual(w.step(input(5, at: t, running: running, sound: sound, playing: playing)), .none)
            }
        }
    }

    func testPauseRestartsTheStallClock() {
        var w = SDIAudioWatchdog()
        XCTAssertEqual(w.step(input(7, at: 0)), .none)
        XCTAssertEqual(w.step(input(7, at: 2.5)), .none)
        XCTAssertEqual(w.step(input(7, at: 2.75, playing: false)), .none)   // Pause
        XCTAssertEqual(w.step(input(7, at: 3.0)), .none)                    // Play: watching begins again here
        XCTAssertEqual(w.step(input(7, at: 5.9)), .none)
        XCTAssertEqual(w.step(input(7, at: 6.0)), .recover(stalledFor: 3.0))
    }

    func testRestartedOutputCountingFromZeroIsAMove() {
        var w = SDIAudioWatchdog()
        _ = w.step(input(16722, at: 0))
        XCTAssertEqual(w.step(input(16722, at: 3)), .recover(stalledFor: 3))
        XCTAssertEqual(w.step(input(16722, at: 3.25, running: false)), .none)   // the restart's 0.5 s gap
        XCTAssertEqual(w.step(input(12, at: 4)), .none)                        // the new output's callbacks
        XCTAssertEqual(w.step(input(40, at: 4.25)), .none)
        XCTAssertFalse(w.gaveUp)
    }

    func testSecondStopWithinSixtySecondsGivesUp() {
        var w = SDIAudioWatchdog()
        _ = w.step(input(100, at: 0))
        XCTAssertEqual(w.step(input(100, at: 3)), .recover(stalledFor: 3))
        _ = w.step(input(5, at: 4))                                           // recovered: callbacks again
        _ = w.step(input(500, at: 30))
        XCTAssertEqual(w.step(input(500, at: 33)), .giveUp(stalledFor: 3, sinceRecovery: 30))
        XCTAssertTrue(w.gaveUp)
        // Given up: no further action in this output session, whatever happens.
        _ = w.step(input(9, at: 40))
        XCTAssertEqual(w.step(input(9, at: 200)), .none)
    }

    func testSecondStopAfterSixtySecondsRecoversAgain() {
        var w = SDIAudioWatchdog()
        _ = w.step(input(100, at: 0))
        XCTAssertEqual(w.step(input(100, at: 3)), .recover(stalledFor: 3))
        _ = w.step(input(5, at: 4))
        _ = w.step(input(800, at: 60))
        XCTAssertEqual(w.step(input(800, at: 63)), .recover(stalledFor: 3))   // 60 s after the first recovery
    }

    func testResetAllowsRestartsAgain() {
        var w = SDIAudioWatchdog()
        _ = w.step(input(1, at: 0)); _ = w.step(input(1, at: 3))
        _ = w.step(input(2, at: 4)); _ = w.step(input(2, at: 7))
        XCTAssertTrue(w.gaveUp)
        w.reset()   // the operator restarted output
        _ = w.step(input(3, at: 10))
        XCTAssertEqual(w.step(input(3, at: 13)), .recover(stalledFor: 3))
    }
}
