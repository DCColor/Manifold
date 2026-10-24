import XCTest
import AppKit
@testable import ShortcutRegistry

/// Dispatch, in-process: synthesized `NSEvent`s through the app's adapter (`KeyEvent(_ : NSEvent)`) into the
/// dispatcher, against a host that records what it was asked to do. No keystroke reaches any app.
/// Predictions P1–P4, docs/SHORTCUTS_AUDIT.md §5.
@MainActor
final class KeyDispatchTests: XCTestCase {

    final class Host: KeyDispatchHost {
        var isEditingText = false
        var isTimecodeEntryOpen = false
        var unavailable: Set<ShortcutID> = []
        var holdsHaveSomethingToCompare = true
        var performed: [ShortcutID] = []
        var holds: [String] = []
        var steps: [Int] = []
        var rates: [Float] = []
        var entryKeys: [UInt16] = []
        var opened: [String] = []

        func timecodeEntryKey(_ event: KeyEvent) -> Bool { entryKeys.append(event.keyCode); return true }
        func timecodeEntryOpen(_ event: KeyEvent) -> Bool {
            guard event.modifiers.isDisjoint(with: .commandLike) else { return false }
            let c = event.characters
            guard c.count == 1, "0123456789+-=_".contains(c) else { return false }
            opened.append(c); return true
        }
        func canPerform(_ id: ShortcutID) -> Bool { !unavailable.contains(id) }
        func perform(_ id: ShortcutID) { performed.append(id) }
        func beginHold(_ id: ShortcutID) -> Bool {
            guard holdsHaveSomethingToCompare else { return false }
            holds.append("begin \(id.rawValue)"); return true
        }
        func endHold(reason: String) { holds.append("end \(reason)") }
        func stepFrames(_ frames: Int) { steps.append(frames) }
        func shuttle(rate: Float) { rates.append(rate) }
    }

    /// A scheduler the test fires by hand.
    final class Clock {
        final class Timer { let work: @MainActor () -> Void; var cancelled = false; init(_ w: @escaping @MainActor () -> Void) { work = w } }
        var pending: [Timer] = []
        lazy var scheduler: KeyDispatcher.Scheduler = { [unowned self] _, work in
            let t = Timer(work)
            self.pending.append(t)
            return { t.cancelled = true }
        }
        @MainActor func fire() {
            let due = pending; pending = []
            for t in due where !t.cancelled { t.work() }
        }
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private var host: Host!
    private var clock: Clock!
    private var dispatcher: KeyDispatcher!

    override func setUp() {
        super.setUp()
        suite = "KeyDispatchTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        host = Host()
        clock = Clock()
        dispatcher = makeDispatcher(debug: { _ in false })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeDispatcher(debug: @escaping (DebugTier) -> Bool) -> KeyDispatcher {
        let registry = ShortcutRegistry(store: ShortcutStore(defaults: defaults), layout: USKeyLayout(),
                                        debugTierEnabled: debug)
        return KeyDispatcher(registry: registry, schedule: clock.scheduler)
    }

    // MARK: Synthesized events

    private static let arrows: [UInt16: Int] = [KeyCode.left: NSLeftArrowFunctionKey, KeyCode.right: NSRightArrowFunctionKey,
                                                KeyCode.up: NSUpArrowFunctionKey, KeyCode.down: NSDownArrowFunctionKey,
                                                KeyCode.home: NSHomeFunctionKey, KeyCode.end: NSEndFunctionKey]

    /// An `NSEvent` as AppKit builds one, then the adapter. `chars` is `charactersIgnoringModifiers`.
    private func event(_ type: NSEvent.EventType, _ code: UInt16, _ chars: String,
                       _ flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) -> KeyEvent {
        var flags = flags
        var chars = chars
        if let f = Self.arrows[code] {
            chars = String(Character(UnicodeScalar(UInt32(f))!))
            flags.formUnion([.function, .numericPad])   // as AppKit sets them; the adapter must drop both
        }
        let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: isRepeat, keyCode: code)!
        return KeyEvent(e)!
    }
    private func down(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = [], repeat r: Bool = false) -> Bool {
        dispatcher.handle(event(.keyDown, code, chars, flags, repeat: r), host: host)
    }
    private func up(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> Bool {
        dispatcher.handle(event(.keyUp, code, chars, flags), host: host)
    }
    /// Press and release; returns what the press reached (nil = nothing), and whether it was consumed.
    private func press(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> (ShortcutID?, Bool) {
        let before = host.performed.count
        let consumed = down(code, chars, flags)
        _ = up(code, chars, flags)
        return (host.performed.count > before ? host.performed.last : nil, consumed)
    }

    // Key codes, ANSI.
    private let kD: UInt16 = 2, kJ: UInt16 = 38, kK: UInt16 = 40, kL: UInt16 = 37, kN: UInt16 = 45, kI: UInt16 = 34
    private let kT: UInt16 = 17, kE: UInt16 = 14, kR: UInt16 = 15, kF: UInt16 = 3, kH: UInt16 = 4, kW: UInt16 = 13
    private let kX: UInt16 = 7, kG: UInt16 = 5, kB: UInt16 = 11, kO: UInt16 = 31, kC: UInt16 = 8, kA: UInt16 = 0
    private let kBackslash: UInt16 = 42, kP: UInt16 = 35, kU: UInt16 = 32, kS: UInt16 = 1, kL1: UInt16 = 18

    // MARK: P1 — unmoved keys reach HEAD's action

    func testUnmovedTransportAndViewKeys() {
        let cases: [(UInt16, String, NSEvent.ModifierFlags, ShortcutID)] = [
            (KeyCode.space, " ", [], .playPause),
            (kJ, "j", [], .shuttleReverse), (kK, "k", [], .shuttlePause), (kL, "l", [], .shuttleForward),
            (kN, "n", [], .fileName),
            (KeyCode.left, "", [], .stepBackFrame), (KeyCode.right, "", [], .stepForwardFrame),
            (KeyCode.left, "", [.shift], .stepBackSecond), (KeyCode.right, "", [.shift], .stepForwardSecond),
            (KeyCode.rightBracket, "]", [.option], .audioLater1), (KeyCode.leftBracket, "[", [.option], .audioEarlier1),
            (KeyCode.rightBracket, "}", [.option, .shift], .audioLater10),
            (KeyCode.leftBracket, "{", [.option, .shift], .audioEarlier10),
        ]
        for (code, chars, flags, id) in cases {
            let (reached, consumed) = press(code, chars, flags)
            XCTAssertEqual(reached, id, "\(code) \(flags)")
            XCTAssertTrue(consumed, "\(code)")
        }
    }

    /// ⇧← is not ←: exact modifiers, the reason the arrows moved to a monitor in the first place (audit C7).
    func testShiftedArrowIsDistinctFromArrow() {
        XCTAssertEqual(press(KeyCode.left, "", [.shift]).0, .stepBackSecond)
        XCTAssertEqual(press(KeyCode.left, "").0, .stepBackFrame)
        XCTAssertEqual(press(KeyCode.right, "").0, .stepForwardFrame)
        XCTAssertEqual(press(KeyCode.right, "", [.shift]).0, .stepForwardSecond)
    }

    func testTimecodeEntryOpensOnDigitsAndSignsAndTakesEveryBareKeyWhileOpen() {
        for c in ["0", "5", "9", "+", "=", "-", "_"] {
            XCTAssertTrue(down(kL1, c, c == "+" || c == "_" ? [.shift] : []), c)
        }
        XCTAssertEqual(host.opened, ["0", "5", "9", "+", "=", "-", "_"])
        host.isTimecodeEntryOpen = true
        for code in [KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.escape, KeyCode.delete, KeyCode.forwardDelete,
                     KeyCode.space, kJ, kD] {
            XCTAssertTrue(down(code, ""), "\(code)")
        }
        XCTAssertTrue(host.performed.isEmpty, "nothing moves behind the entry overlay")
        XCTAssertTrue(host.holds.isEmpty)
        // ⌘ / ⌃ / ⌥ keys keep working through entry, as at HEAD: the nudge.
        XCTAssertTrue(down(KeyCode.rightBracket, "]", [.option]))
        XCTAssertEqual(host.performed, [.audioLater1])
    }

    func testDebugHooksWithThePredicateOn() {
        dispatcher = makeDispatcher(debug: { _ in true })
        let cases: [(UInt16, String, NSEvent.ModifierFlags, ShortcutID)] = [
            (kW, "w", [.control, .option], .debugWebRTCSmoke), (kH, "h", [.control, .option], .debugWHEPConnect),
            (kH, "H", [.control, .option, .shift], .debugWHEPRetire),
            (kE, "E", [.control, .option, .shift], .debugWHEPExportFrame),
            (kD, "d", [.control, .option], .debugSRTConnect), (kD, "D", [.control, .option, .shift], .debugSRTRetire),
            (kR, "r", [.control, .option], .debugRenderLayer),
            (kL, "l", [.control, .option], .debugSyntheticStart), (kL, "L", [.control, .option, .shift], .debugSyntheticStop),
            (kP, "p", [.control, .option], .debugSyntheticPreset), (kU, "u", [.control, .option], .debugForceUnityRate),
            (kS, "s", [.control, .option], .debugSyntheticSweep),
            (KeyCode.leftBracket, "[", [.control, .option], .debugDepthDown),
            (KeyCode.rightBracket, "]", [.control, .option], .debugDepthUp),
        ]
        for (code, chars, flags, id) in cases {
            XCTAssertEqual(press(code, chars, flags).0, id, id.rawValue)
        }
        XCTAssertTrue(host.holds.isEmpty, "⌃⌥D is the SRT hook, never a hold")
    }

    /// The menu-bar debug items (⌃⌥A, ⌃⌥⇧B) are the menu's; the dispatcher leaves them to AppKit.
    func testMenuKeysAreLeftToTheMenus() {
        dispatcher = makeDispatcher(debug: { _ in true })
        for (code, chars, flags) in [(kA, "a", NSEvent.ModifierFlags([.control, .option])),
                                     (kB, "B", [.control, .option, .shift]), (kI, "i", [.command]),
                                     (kO, "o", [.command]), (kL1, "1", [.command]), (kE, "e", [.option, .command])] {
            let (reached, consumed) = press(code, chars, flags)
            XCTAssertNil(reached); XCTAssertFalse(consumed, "\(chars) \(flags)")
        }
    }

    // MARK: P2 — moved keys

    func testNewKeysReachTheirActions() {
        XCTAssertEqual(press(kF, "f", [.command]).0, .fullScreen)
        XCTAssertEqual(press(KeyCode.home, "").0, .goToStart)
        XCTAssertEqual(press(KeyCode.end, "").0, .goToEnd)
        XCTAssertEqual(press(KeyCode.left, "", [.option]).0, .goToStartAlternate)
        XCTAssertEqual(press(KeyCode.right, "", [.option]).0, .goToEndAlternate)
    }

    func testOldKeysReachNothingAndPassThrough() {
        let old: [(UInt16, String, NSEvent.ModifierFlags)] = [
            (kI, "i", []), (KeyCode.tab, "\t", []), (kT, "t", [.control, .option]), (kE, "e", [.control, .option]),
            (kX, "x", [.control, .option]), (kG, "g", [.control, .option]), (kB, "b", [.control, .option]),
            (18, "1", [.control, .option]), (19, "2", [.control, .option]), (20, "3", [.control, .option]),
            (kO, "o", [.control, .option]), (kO, "O", [.control, .option, .shift]), (kN, "n", [.control, .option]),
            (kN, "N", [.control, .option, .shift]), (kC, "c", [.control, .option]), (kR, "r", [.control, .option]),
            (kBackslash, "\\", []), (kBackslash, "|", [.shift]),
        ]
        for (code, chars, flags) in old {
            let (reached, consumed) = press(code, chars, flags)
            XCTAssertNil(reached, "\(chars) \(flags)")
            XCTAssertFalse(consumed, "\(chars) \(flags)")
        }
        XCTAssertTrue(host.holds.isEmpty, "\\ no longer holds")
    }

    /// Menu items AppKit dispatches: the registry's menu key goes into a real NSMenu, and a synthesized key event
    /// fires it. This is AppKit's matcher, the one the menus use.
    func testMenuKeysFireThroughAnNSMenu() {
        _ = NSApplication.shared   // a menu item's action is sent through NSApp
        let registry = ShortcutRegistry(store: ShortcutStore(defaults: defaults), layout: USKeyLayout(),
                                        debugTierEnabled: { _ in false })
        final class Target: NSObject {
            var fired: [String] = []
            @objc func fire(_ sender: NSMenuItem) { fired.append(sender.title) }
        }
        let target = Target()
        let menu = NSMenu()
        for id in [ShortcutID.inspector, .alwaysShowControls, .scopesTray, .exportFrame, .displayOS, .displayReference,
                   .displayBypass, .raster100, .rasterFit, .loop, .fileOpen] {
            let chord = registry.menuChord(for: id)!
            guard case .character(let c) = chord.key else { return XCTFail(id.rawValue) }
            let item = NSMenuItem(title: id.rawValue, action: #selector(Target.fire(_:)), keyEquivalent: c)
            var mask = NSEvent.ModifierFlags()
            if chord.modifiers.contains(.command) { mask.insert(.command) }
            if chord.modifiers.contains(.option) { mask.insert(.option) }
            if chord.modifiers.contains(.control) { mask.insert(.control) }
            if chord.modifiers.contains(.shift) { mask.insert(.shift) }
            item.keyEquivalentModifierMask = mask
            item.target = target
            menu.addItem(item)
        }
        func send(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) -> Bool {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
            return menu.performKeyEquivalent(with: e)
        }
        XCTAssertTrue(send(kI, "i", [.command]))
        XCTAssertTrue(send(kT, "t", [.option, .command]))
        XCTAssertTrue(send(26, "7", [.command]))
        XCTAssertTrue(send(kE, "e", [.option, .command]))
        XCTAssertTrue(send(18, "1", [.option, .command]))
        XCTAssertTrue(send(19, "2", [.option, .command]))
        XCTAssertTrue(send(20, "3", [.option, .command]))
        XCTAssertTrue(send(18, "1", [.command]))
        XCTAssertTrue(send(29, "0", [.command]))
        XCTAssertTrue(send(kL, "l", [.command]))
        XCTAssertTrue(send(kO, "o", [.command]))
        XCTAssertEqual(target.fired, ["view.inspector", "view.alwaysShowControls", "scopes.tray", "file.exportFrame",
                                      "color.displayOS", "color.displayReference", "color.displayBypass",
                                      "view.raster100", "view.rasterFit", "transport.loop", "file.open"])
        XCTAssertFalse(send(kI, "i", []), "bare I fires no menu item")
        XCTAssertFalse(send(kT, "t", [.control, .option]), "⌃⌥T fires no menu item")
    }

    // MARK: P3 — hold to compare

    func testHoldDAndRelease() {
        XCTAssertTrue(down(kD, "d"))
        XCTAssertTrue(down(kD, "d", repeat: true))
        XCTAssertTrue(down(kD, "d", repeat: true))
        XCTAssertTrue(up(kD, "d"))
        XCTAssertEqual(host.holds, ["begin color.holdCompare", "end key up"])
    }

    func testShiftHoldIsBypass() {
        XCTAssertTrue(down(kD, "D", [.shift]))
        XCTAssertTrue(up(kD, "D", [.shift]))
        XCTAssertEqual(host.holds, ["begin color.holdCompareBypass", "end key up"])
    }

    /// Decision 2: never swallows ⌘D, ⌥D or any other modified D.
    func testModifiedDIsNotSwallowed() {
        for flags: NSEvent.ModifierFlags in [[.command], [.option], [.control], [.shift, .command], [.option, .shift],
                                             [.control, .option], [.control, .shift], [.option, .command]] {
            let (reached, consumed) = press(kD, flags.contains(.shift) ? "D" : "d", flags)
            XCTAssertNil(reached, "\(flags)")
            XCTAssertFalse(consumed, "\(flags)")
        }
        XCTAssertTrue(host.holds.isEmpty)
    }

    func testTextFieldFocusPassesEverythingThrough() {
        host.isEditingText = true
        for (code, chars, flags) in [(kD, "d", NSEvent.ModifierFlags()), (kD, "D", [.shift]), (KeyCode.space, " ", []),
                                     (kJ, "j", []), (KeyCode.left, "", []), (kL1, "1", []),
                                     (KeyCode.rightBracket, "]", [.option]), (kF, "f", [.command])] {
            XCTAssertFalse(down(code, chars, flags), "\(chars)")
        }
        XCTAssertTrue(host.holds.isEmpty)
        XCTAssertTrue(host.performed.isEmpty)
        XCTAssertTrue(host.opened.isEmpty)
    }

    func testNothingToCompareLetsTheKeyGoOn() {
        host.holdsHaveSomethingToCompare = false
        XCTAssertFalse(down(kD, "d"))
        XCTAssertFalse(up(kD, "d"))
    }

    func testAMissedKeyUpNeverLeavesTheWindowStuck() {
        XCTAssertTrue(down(kD, "d"))
        XCTAssertTrue(down(kD, "D", [.shift]))      // fresh down, no up in between
        XCTAssertEqual(host.holds, ["begin color.holdCompare", "end missed key up", "begin color.holdCompareBypass"])
        dispatcher.reset(host: host, reason: "window not key")
        XCTAssertEqual(host.holds.last, "end window not key")
        XCTAssertFalse(up(kD, "D"), "the key-up after a reset is not ours")
    }

    // MARK: P4 — K + J / L

    func testKHeldThenJOrLStepsOneFramePerPress() {
        XCTAssertTrue(down(kK, "k"))
        XCTAssertEqual(host.performed, [.shuttlePause])
        XCTAssertTrue(down(kJ, "j")); XCTAssertTrue(up(kJ, "j") == false)
        XCTAssertTrue(down(kJ, "j")); _ = up(kJ, "j")
        XCTAssertTrue(down(kL, "l")); _ = up(kL, "l")
        XCTAssertEqual(host.steps, [-1, -1, 1])
        XCTAssertEqual(host.performed, [.shuttlePause], "no shuttle while K is held")
        XCTAssertTrue(host.rates.isEmpty)
        clock.fire()                                  // timers of released presses are cancelled
        XCTAssertTrue(host.rates.isEmpty)
        _ = up(kK, "k")
        XCTAssertEqual(press(kJ, "j").0, .shuttleReverse, "K released: J is shuttle again")
    }

    func testKHeldAndJOrLHeldPlaysAtHalfSpeedUntilRelease() {
        XCTAssertTrue(down(kK, "k"))
        XCTAssertTrue(down(kL, "l"))
        XCTAssertTrue(down(kL, "l", repeat: true))   // auto-repeat while held changes nothing
        XCTAssertEqual(host.steps, [1])
        clock.fire()
        XCTAssertEqual(host.rates, [0.5])
        XCTAssertTrue(dispatcher.isSlowPlaying)
        _ = up(kL, "l")
        XCTAssertEqual(host.rates, [0.5, 0])
        XCTAssertTrue(down(kJ, "j"))
        clock.fire()
        XCTAssertEqual(host.rates, [0.5, 0, -0.5])
        _ = up(kK, "k")                               // releasing K also stops it
        XCTAssertEqual(host.rates, [0.5, 0, -0.5, 0])
        XCTAssertEqual(host.steps, [1, -1])
    }

    func testJAloneIsHEADsShuttle() {
        XCTAssertEqual(press(kJ, "j").0, .shuttleReverse)
        XCTAssertTrue(down(kL, "l"))
        XCTAssertTrue(down(kL, "l", repeat: true))   // HEAD: a held L repeats, and each press speeds up
        XCTAssertEqual(host.performed, [.shuttleReverse, .shuttleForward, .shuttleForward])
        XCTAssertTrue(host.steps.isEmpty)
    }

    // MARK: Gates and repeats

    func testAnActionTheWindowCannotPerformPassesOn() {
        host.unavailable = [.playPause, .stepBackFrame]
        XCTAssertEqual(press(KeyCode.space, " ").1, false)
        XCTAssertEqual(press(KeyCode.left, "").1, false)
        host.unavailable = [.audioLater1]
        XCTAssertEqual(press(KeyCode.rightBracket, "]", [.option]).1, false, "not live: ⌥] goes on to the field / beep")
    }

    func testTogglesIgnoreAutoRepeat() {
        XCTAssertTrue(down(KeyCode.space, " "))
        XCTAssertTrue(down(KeyCode.space, " ", repeat: true))
        XCTAssertTrue(down(kN, "n", repeat: true))
        XCTAssertEqual(host.performed, [.playPause])
        XCTAssertTrue(down(KeyCode.right, "", repeat: true))
        XCTAssertEqual(host.performed, [.playPause, .stepForwardFrame], "the arrows repeat")
    }

    func testRecordingTakesNothing() {
        dispatcher.registry.isRecording = true
        XCTAssertFalse(down(kD, "d"))
        XCTAssertFalse(down(KeyCode.space, " "))
        XCTAssertTrue(host.performed.isEmpty && host.holds.isEmpty)
    }

    /// A rebound key dispatches at once, and the old key stops.
    func testRebindingTakesEffectImmediately() {
        XCTAssertTrue(dispatcher.registry.assign(.char("y"), to: .fileName))
        XCTAssertEqual(press(16, "y").0, .fileName)
        XCTAssertNil(press(kN, "n").0)
        XCTAssertTrue(dispatcher.registry.assign(.char("i"), to: .inspector))   // a menu action on a bare key
        XCTAssertEqual(press(kI, "i").0, .inspector)
    }

    /// A Cyrillic layout types "в" on the D key: the ANSI letter stands in, as macOS does for ⌘ keys.
    func testNonLatinLayoutFallsBackToTheANSILetter() {
        XCTAssertTrue(down(kD, "в"))
        XCTAssertEqual(host.holds, ["begin color.holdCompare"])
    }
}
