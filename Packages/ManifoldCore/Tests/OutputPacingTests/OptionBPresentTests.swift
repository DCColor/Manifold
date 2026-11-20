import XCTest
@testable import OutputPacing

/// Option B after docs/WINDOW_PRESENT_PATH.md §7.5 (Robbie, 2026-11-19): plain B never changes the layer's present mode per tick, and
/// the gate keeps one drawable spare at any display rate. B off (`MANIFOLD_PACER_PRESENT_TX=1`): the gate exactly as before.
/// Plain B is the 0.9.5 default since 2026-11-20 (`PacerSwitchesTests`).
final class OptionBPresentTests: XCTestCase {
    private let hz120 = 1.0 / 120, hz11988 = 1001.0 / 120000, hz60 = 1.0 / 60, hz5994 = 1001.0 / 60000

    func testPlainBIsTransactionalExactlyWhenThePacerIsNotPresenting() {
        XCTAssertFalse(WindowPresentTiming.optionBPresentsWithTransaction(pacerPresenting: true))
        XCTAssertTrue(WindowPresentTiming.optionBPresentsWithTransaction(pacerPresenting: false))
    }

    /// A pacer run with colour-state and resize ticks in it: the mode the tick top would write never changes inside the run, so the
    /// layer toggles twice in all (pacer start, pacer stop), never per tick. Before §7.5 a state tick flipped it to true and back.
    func testModeChangesOnlyAtPacerStartAndStop() {
        struct Tick { let pacer: Bool; let colourState: Bool; let resize: Bool }
        var ticks = [Tick](repeating: Tick(pacer: false, colourState: false, resize: false), count: 5)
        for i in 0..<200 { ticks.append(Tick(pacer: true, colourState: i % 37 == 5, resize: i % 53 == 9)) }
        ticks += [Tick](repeating: Tick(pacer: false, colourState: true, resize: false), count: 5)
        var mode = true, writes = 0
        for t in ticks {
            let want = WindowPresentTiming.optionBPresentsWithTransaction(pacerPresenting: t.pacer)
            if want != mode { mode = want; writes += 1 }
        }
        XCTAssertEqual(writes, 2)
    }

    func testOptionBKeepsOneDrawableSpareAtEveryRate() {
        for p in [hz120, hz11988, hz60, hz5994, 1.0 / 144, 0, .nan] {
            XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: p, keepSpareDrawable: true), 1, "\(p)")
        }
    }

    func testAbove60HzOptionBHasOneMoreDrawableFree() {
        // Pool of 3: one on the glass plus the waiting limit in use; the rest free.
        func free(_ limit: Int) -> Int { 3 - 1 - limit }
        XCTAssertEqual(free(WindowPresentTiming.presentsWaitingLimit(displayPeriod: hz120)), 0, "today at 120 Hz: no slack (§7.2)")
        XCTAssertEqual(free(WindowPresentTiming.presentsWaitingLimit(displayPeriod: hz120, keepSpareDrawable: true)), 1)
        XCTAssertEqual(free(WindowPresentTiming.presentsWaitingLimit(displayPeriod: hz60, keepSpareDrawable: true)), 1, "60 Hz: as today")
    }

    func testBOffIsTheGateUnchanged() {
        for p in [hz120, hz11988, hz60, hz5994, 1.0 / 144, 0, .nan] {
            XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: p, keepSpareDrawable: false),
                           WindowPresentTiming.presentsWaitingLimit(displayPeriod: p), "\(p)")
        }
        XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: hz120), 2)
        XCTAssertEqual(WindowPresentTiming.presentsWaitingLimit(displayPeriod: hz5994), 1)
    }
}
