import XCTest
@testable import ShortcutRegistry

/// The catalog's invariants, Robbie's scheme (docs/SHORTCUTS_AUDIT.md §4.2, decided 2026-10-23; §8, 2026-10-24), the
/// store, and the verdicts the Keyboard Shortcuts window shows.
@MainActor
final class ShortcutRegistryTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "ShortcutRegistryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func registry(debug: Bool = true) -> ShortcutRegistry {
        ShortcutRegistry(store: ShortcutStore(defaults: defaults), layout: USKeyLayout(), debugTierEnabled: { _ in debug })
    }

    // MARK: Catalog invariants

    func testEveryActionIsInTheCatalogOnceAndTitled() {
        XCTAssertEqual(ShortcutCatalog.all.count, ShortcutID.allCases.count)
        XCTAssertEqual(Set(ShortcutCatalog.all.map(\.id)).count, ShortcutCatalog.all.count)
        for def in ShortcutCatalog.all {
            XCTAssertFalse(def.title.trimmingCharacters(in: .whitespaces).isEmpty, def.id.rawValue)
        }
    }

    /// No two defaults share a key in scopes that overlap: debug tiers on, which is the most crowded case.
    func testNoTwoDefaultsConflictInOverlappingScopes() {
        let r = registry(debug: true)
        for def in ShortcutCatalog.all {
            for chord in def.defaultChords {
                XCTAssertEqual(r.conflicts(for: chord, scope: def.scope, excluding: def.id), [],
                               "\(def.id.rawValue) \(r.label(chord))")
            }
        }
    }

    func testNoDefaultIsReservedByMacOS() {
        let r = registry()
        for def in ShortcutCatalog.all {
            // Full screen's ⌃⌘F alias IS the system's full-screen key, answered for the same action (§8 item 3).
            for chord in def.defaultChords where !(def.id == .fullScreen && chord == .char("f", [.control, .command])) {
                XCTAssertNil(ShortcutRegistry.reserved[r.normalized(chord)], "\(def.id.rawValue) \(r.label(chord))")
                XCTAssertNil(ShortcutRegistry.reserved[chord], def.id.rawValue)
            }
        }
    }

    /// Audit C7: AppKit's key-equivalent matcher cannot tell ⇧← from ←, so a menu arrow carries ⌘, ⌃ or ⌥.
    func testNoBareOrShiftedArrowOnAMenuDispatchedAction() {
        for def in ShortcutCatalog.all where def.dispatch == .menu {
            guard let chord = def.defaultChord, chord.isArrow else { continue }
            XCTAssertFalse(chord.isBare, def.id.rawValue)
        }
    }

    func testNoHoldUsesCommand() {
        for def in ShortcutCatalog.all where def.dispatch == .hold {
            XCTAssertFalse(def.defaultChord?.modifiers.contains(.command) ?? false, def.id.rawValue)
        }
    }

    /// Every shipping key is outside ⌃⌥, the namespace kept for debug hooks (audit §4.1 rule 3).
    func testControlOptionIsOnlyForDebugHooks() {
        for def in ShortcutCatalog.all where def.debug == nil {
            XCTAssertFalse(def.defaultChord?.modifiers.isSuperset(of: [.control, .option]) ?? false, def.id.rawValue)
        }
    }

    // MARK: Robbie's scheme, 2026-10-23, and its follow-ups, 2026-10-24

    func testDecidedDefaults() {
        let r = registry()
        let expected: [ShortcutID: String?] = [
            .fileOpen: "⌘O", .exportFrame: "⌥⌘E", .inspector: "⌘I", .alwaysShowControls: "⌥⌘T", .scopesTray: "⌥⌘S",
            .displayOS: "⌥⌘1", .displayReference: "⌥⌘2", .displayBypass: "⌥⌘3", .transformChain: "⌥⌘4",
            .holdCompare: "C (hold)", .holdCompareBypass: "⇧C (hold)", .holdCompareLUTOff: "⌥C (hold)",
            .toggleDeckLink: "⇧⌘D", .disconnectLive: "⌥⌘Delete",
            .volumeUp: "⌘↑", .volumeDown: "⌘↓", .mute: "⌥⌘↓",
            .raster100: "⌘1", .raster75: "⌘2", .raster50: "⌘3", .raster25: "⌘4", .rasterFit: "⌘0",
            .fullScreen: "⌘F", .loop: "⌘L", .playPause: "Space", .shuttleReverse: "J", .shuttlePause: "K",
            .shuttleForward: "L", .stepBackFrame: "←", .stepForwardFrame: "→", .stepBackSecond: "⇧←",
            .stepForwardSecond: "⇧→", .goToStart: "Home", .goToEnd: "End", .goToStartAlternate: "⌥←",
            .goToEndAlternate: "⌥→", .fileName: "N", .audioLater1: "⌥]", .audioEarlier1: "⌥[",
            .audioLater10: "⌥⇧]", .audioEarlier10: "⌥⇧[",
            // No default.
            .cycleInterpretation: nil, .resetInterpretation: nil, .cieSpace: nil, .vectorscopeGraticule: nil,
            .vectorscopeBoxes: nil, .cie709: nil, .cieP3: nil, .cie2020: nil, .exportFrameForSupport: nil,
            // Debug. ⌃⌥R is gone (§8 item 4); Connect to First NDI Source is back on ⌃⌥N, as a debug hook (item 6).
            .debugToneTest: "⌃⌥A", .debugScrubBench: "⌃⌥⇧B", .debugNDIConnect: "⌃⌥N", .debugWebRTCSmoke: "⌃⌥W",
            .debugWHEPConnect: "⌃⌥H", .debugWHEPRetire: "⌃⌥⇧H", .debugWHEPExportFrame: "⌃⌥⇧E",
            .debugSRTConnect: "⌃⌥D", .debugSRTRetire: "⌃⌥⇧D", .debugSyntheticStart: "⌃⌥L",
            .debugSyntheticStop: "⌃⌥⇧L", .debugSyntheticPreset: "⌃⌥P", .debugForceUnityRate: "⌃⌥U",
            .debugSyntheticSweep: "⌃⌥S", .debugDepthDown: "⌃⌥[", .debugDepthUp: "⌃⌥]",
        ]
        for (id, label) in expected {
            XCTAssertEqual(r.label(for: id), label, id.rawValue)
        }
        XCTAssertEqual(r.definition(.debugNDIConnect).debug, .profile)
        // The support export is public (2026-10-24): no debug tier, so the release-gate switch cannot hide it.
        XCTAssertNil(r.definition(.exportFrameForSupport).debug)
        XCTAssertEqual(r.definition(.exportFrameForSupport).title, "Export Frame for Support…")
        XCTAssertEqual(r.definition(.cycleInterpretation).title, "Next Tag Override")
        XCTAssertEqual(r.definition(.resetInterpretation).title, "Reset Tags to Source")
    }

    /// Help ▸ Export Frame for Support… is not a debug action: with every debug tier off (the release-gate switch) it
    /// can still be given a key, and its menu item carries it.
    func testSupportExportSurvivesTheDebugSwitch() {
        let r = registry(debug: false)
        let chord = KeyChord.char("g", [.control, .option, .command])
        XCTAssertEqual(r.definition(.exportFrameForSupport).category, .help)
        XCTAssertTrue(r.assign(chord, to: .exportFrameForSupport))
        XCTAssertEqual(r.menuChord(for: .exportFrameForSupport), chord)
    }

    /// ⌥⌘D is macOS's Show or Hide the Dock: it never reaches an app, so it is refused (§8).
    func testDockKeyIsReserved() {
        guard case .refused = registry().propose(.char("d", [.option, .command]), for: .toggleDeckLink) else {
            return XCTFail()
        }
    }

    /// The keys the scheme took away are held by nothing outside the debug tiers.
    func testRemovedKeysAreFree() {
        let r = registry(debug: false)
        let removed: [KeyChord] = [.char("i"), .code(KeyCode.tab), .char("t", [.control, .option]),
                                   .char("e", [.control, .option]), .char("x", [.control, .option]),
                                   .char("g", [.control, .option]), .char("b", [.control, .option]),
                                   .char("1", [.control, .option]), .char("2", [.control, .option]),
                                   .char("3", [.control, .option]), .char("o", [.control, .option]),
                                   .char("o", [.control, .option, .shift]), .char("n", [.control, .option]),
                                   .char("n", [.control, .option, .shift]), .char("c", [.control, .option]),
                                   .char("r", [.control, .option]), .char("\\"), .char("|", [.shift]),
                                   // 2026-10-24: compare left D for C, Scopes left ⌘7 for ⌥⌘S.
                                   .char("d"), .char("d", [.shift]), .char("7", [.command])]
        for chord in removed {
            XCTAssertEqual(r.conflicts(for: chord, scope: .app), [], r.label(chord))
        }
        // ⌃⌥R is gone in every tier.
        XCTAssertEqual(registry(debug: true).conflicts(for: .char("r", [.control, .option]), scope: .app), [])
    }

    // MARK: Menus

    /// §8 item 5: every action with a menu item shows its binding there, bare keys included (N).
    func testEveryMenuActionShowsItsBinding() {
        let r = registry()
        for def in r.definitions where def.dispatch == .menu {
            XCTAssertEqual(r.menuChord(for: def.id), r.chord(for: def.id), def.id.rawValue)
            if let chord = r.chord(for: def.id) {
                XCTAssertNotNil(chord.menuShortcut(layout: USKeyLayout()), "\(def.id.rawValue) cannot be drawn")
            }
        }
        XCTAssertEqual(r.menuChord(for: .fileName), .char("n"))
        XCTAssertTrue(r.dispatcherBindings().contains { $0.0.id == .fileName }, "N is still dispatched outside fields")
        XCTAssertFalse(r.dispatcherBindings().contains { $0.0.id == .inspector })
        // A rebound bare key shows too.
        XCTAssertTrue(r.assign(.char("y"), to: .inspector))
        XCTAssertEqual(r.menuChord(for: .inspector), .char("y"))
    }

    /// §8 item 2: no registry key lands on a menu item the registry does not own. Only menu actions have a menu
    /// key; no key or alias of any action is one of the stock items' keys (MEASURED by Accessibility on HEAD's menu
    /// bar, 2026-10-24: App, File, Edit, View and Window menus); and the full-screen alias stays a dispatcher key.
    func testNoRegistryKeyLandsOnAStockMenuItem() {
        let r = registry(debug: true)
        let stock: [KeyChord: String] = [
            .char("q", [.command]): "Quit", .char("h", [.command]): "Hide", .char("h", [.option, .command]): "Hide Others",
            .char(",", [.command]): "Settings", .char("n", [.command]): "New Window", .char("w", [.command]): "Close",
            .char("w", [.option, .command]): "Close All", .char("z", [.command]): "Undo",
            .char("z", [.shift, .command]): "Redo", .char("x", [.command]): "Cut", .char("c", [.command]): "Copy",
            .char("v", [.command]): "Paste", .char("a", [.command]): "Select All",
            .char("\\", [.shift, .command]): "Show All Tabs", .char("m", [.command]): "Minimize",
            .char("m", [.option, .command]): "Minimize All", .char("f", [.control, .command]): "Enter Full Screen",
        ]
        for id in ShortcutID.allCases {
            let def = r.definition(id)
            if def.dispatch != .menu { XCTAssertNil(r.menuChord(for: id), id.rawValue) }
            for chord in [r.menuChord(for: id)].compactMap({ $0 }) + def.defaultChords
            where !(id == .fullScreen && chord == .char("f", [.control, .command])) {
                XCTAssertNil(stock[chord], "\(id.rawValue) holds \(stock[chord] ?? "")'s key")
            }
        }
        XCTAssertEqual(r.definition(.fullScreen).dispatch, .key, "⌃⌘F must never be set on a menu item")
    }

    /// ⌃⌘F is an alias the dispatcher always matches (§8 item 3); ⌘F is still the rebindable key.
    func testFullScreenAnswersBothKeys() {
        let r = registry()
        let keys = r.dispatcherBindings().filter { $0.0.id == .fullScreen }.map(\.1)
        XCTAssertEqual(Set(keys), [.char("f", [.command]), .char("f", [.control, .command])])
    }

    /// Keys a text field uses itself: these go to a field being typed into, not to the menu.
    func testTextFieldKeys() {
        for chord in [KeyChord.char("n"), .char("n", [.shift]), .char("c", [.option]), .code(KeyCode.up, [.command]),
                      .code(KeyCode.down, [.option, .command]), .code(KeyCode.delete, [.option, .command])] {
            XCTAssertTrue(chord.isTextFieldKey, "\(chord)")
        }
        for chord in [KeyChord.char("i", [.command]), .char("s", [.option, .command]), .char("d", [.shift, .command]),
                      .char("4", [.option, .command]), .code(KeyCode.up, [.control]), .char("a", [.control, .option])] {
            XCTAssertFalse(chord.isTextFieldKey, "\(chord)")
        }
    }

    /// A shortcut-override value written by HEAD (`9bedbe6`) still loads: known IDs keep their keys, the retired
    /// DeckLink IDs are kept untouched in the store, and nothing is rewritten by reading.
    func testHEADOverridesStillLoad() {
        let head = #"{"overrides":{"color.cycleInterpretation":{"key":"y","modifiers":["command"]},"output.startDeckLink":{"key":"k","modifiers":["command","shift"]},"view.inspector":{"key":"i","modifiers":["command","option"]}},"version":1}"#
        defaults.set(head, forKey: ShortcutStore.defaultsKey)
        let r = registry()
        XCTAssertEqual(r.chord(for: .inspector), .char("i", [.option, .command]))
        XCTAssertEqual(r.chord(for: .cycleInterpretation), .char("y", [.command]))
        XCTAssertEqual(r.label(for: .cycleInterpretation), "⌘Y")
        XCTAssertEqual(defaults.string(forKey: ShortcutStore.defaultsKey), head)
        XCTAssertTrue(r.reset(.inspector))
        XCTAssertTrue(defaults.string(forKey: ShortcutStore.defaultsKey)!.contains(#""output.startDeckLink""#))
    }

    func testDebugBindingsFollowTheirTier() {
        let on = ShortcutRegistry(store: ShortcutStore(defaults: defaults), layout: USKeyLayout(),
                                  debugTierEnabled: { $0 == .profile })
        let ids = Set(on.dispatcherBindings().map(\.0.id))
        XCTAssertTrue(ids.contains(.debugNDIConnect))
        XCTAssertFalse(ids.contains(.debugSyntheticStart))
        XCTAssertFalse(Set(registry(debug: false).dispatcherBindings().map(\.0.id)).contains(.debugNDIConnect))
    }

    // MARK: Verdicts

    func testReservedKeysAreRefused() {
        let r = registry()
        for chord in [KeyChord.char("q", [.command]), .char("w", [.command]), .code(KeyCode.space, [.command]),
                      .char("\\", [.shift, .command]), .code(KeyCode.up, [.control]), .char("f", [.control, .command])] {
            guard case .refused = r.propose(chord, for: .inspector) else { return XCTFail(r.label(chord)) }
        }
    }

    func testConflictThenReplace() {
        let r = registry()
        let scopes = KeyChord.char("s", [.option, .command])
        guard case .conflict(let with, _) = r.propose(scopes, for: .inspector) else { return XCTFail() }
        XCTAssertEqual(with, [.scopesTray])
        XCTAssertFalse(r.assign(scopes, to: .inspector))            // Cancel
        XCTAssertEqual(r.chord(for: .inspector), .char("i", [.command]))
        XCTAssertTrue(r.assign(scopes, to: .inspector, replacing: true))
        XCTAssertEqual(r.chord(for: .inspector), scopes)
        XCTAssertNil(r.chord(for: .scopesTray))
        XCTAssertTrue(r.isCustomised(.scopesTray))
    }

    func testFixedRowsCannotBeTakenOrChanged() {
        let r = registry()
        guard case .refused = r.propose(.char("5"), for: .fileName) else { return XCTFail("digit is timecode entry") }
        guard case .refused = r.propose(.code(KeyCode.escape), for: .fileName) else { return XCTFail("Esc") }
        guard case .refused = r.propose(.char("x"), for: .timecodeOpen) else { return XCTFail("fixed row") }
        guard case .refused = r.propose(.char("x", [.command]), for: .fileOpen) else { return XCTFail("⌘O") }
        guard case .refused = r.propose(.char("x", [.control, .option]), for: .debugNDIConnect) else { return XCTFail() }
    }

    func testBareOrShiftedArrowRefusedOnMenuAndCommandRefusedOnHold() {
        let r = registry()
        guard case .refused = r.propose(.code(KeyCode.up, [.shift]), for: .inspector) else { return XCTFail() }
        guard case .refused = r.propose(.code(KeyCode.up), for: .mute) else { return XCTFail("mute is a menu item") }
        guard case .accepted = r.propose(.code(KeyCode.up, [.shift]), for: .cieSpace) else { return XCTFail() }
        guard case .refused = r.propose(.char("c", [.command, .option]), for: .holdCompare) else { return XCTFail() }
    }

    func testWarnings() {
        let r = registry()
        guard case .accepted(let w1) = r.propose(.char("y", [.control, .option]), for: .cieSpace) else { return XCTFail() }
        XCTAssertTrue(w1.contains { $0.contains("VoiceOver") })
        guard case .accepted(let w2) = r.propose(.code(KeyCode.pageUp), for: .cieSpace) else { return XCTFail() }
        XCTAssertTrue(w2.contains { $0.contains("Fn") })
        guard case .accepted(let w3) = r.propose(.char("y"), for: .inspector) else { return XCTFail() }
        XCTAssertTrue(w3.contains { $0.contains("text field") })
        guard case .accepted(let w4) = r.propose(.char(";"), for: .cieSpace) else { return XCTFail() }
        XCTAssertTrue(w4.contains { $0.contains("keyboard layouts") })
        guard case .accepted(let w5) = r.propose(.code(KeyCode.tab), for: .cieSpace) else { return XCTFail() }
        XCTAssertTrue(w5.contains { $0.contains("Keyboard navigation") })
    }

    /// A code binding and a character binding for the same key on this layout are one key.
    func testCodeAndCharacterBindingsOfOneKeyConflict() {
        let r = registry()
        guard case .conflict(let with, _) = r.propose(.char("]", [.option]), for: .cieSpace) else { return XCTFail() }
        XCTAssertEqual(with, [.audioLater1])
    }

    // MARK: Store

    func testNoOverridesWritesNothing() {
        let r = registry()
        _ = r.dispatcherBindings(); _ = r.label(for: .inspector)
        r.resetAll(); r.reset(.inspector); r.reset(category: .view)
        XCTAssertNil(defaults.object(forKey: ShortcutStore.defaultsKey))
    }

    func testOverrideRoundTripsWithSortedKeysAndSurvivesARelaunch() throws {
        let r = registry()
        XCTAssertTrue(r.assign(.char("i", [.option, .command]), to: .inspector))
        XCTAssertTrue(r.assign(nil, to: .fileName))
        let text = try XCTUnwrap(defaults.string(forKey: ShortcutStore.defaultsKey))
        XCTAssertEqual(text, #"{"overrides":{"view.fileName":null,"view.inspector":{"key":"i","modifiers":["command","option"]}},"version":1}"#)
        let relaunched = registry()
        XCTAssertEqual(relaunched.chord(for: .inspector), .char("i", [.option, .command]))
        XCTAssertNil(relaunched.chord(for: .fileName))
        XCTAssertTrue(relaunched.isCustomised(.fileName))
        XCTAssertEqual(relaunched.label(for: .inspector), "⌥⌘I")
    }

    func testUnknownIDsArePreservedAndResetAllRemovesOnlyOurs() throws {
        defaults.set(#"{"future":true,"overrides":{"later.thing":{"key":"q","modifiers":["control"]}},"version":1}"#,
                     forKey: ShortcutStore.defaultsKey)
        let r = registry()
        XCTAssertTrue(r.assign(.code(KeyCode.up, [.option]), to: .mute))
        let text = try XCTUnwrap(defaults.string(forKey: ShortcutStore.defaultsKey))
        XCTAssertEqual(text, #"{"future":true,"overrides":{"audio.mute":{"code":126,"modifiers":["option"]},"later.thing":{"key":"q","modifiers":["control"]}},"version":1}"#)
        XCTAssertTrue(r.resetAll())
        XCTAssertEqual(defaults.string(forKey: ShortcutStore.defaultsKey),
                       #"{"future":true,"overrides":{"later.thing":{"key":"q","modifiers":["control"]}},"version":1}"#)
    }

    func testResetToEmptyRemovesTheKey() {
        let r = registry()
        XCTAssertTrue(r.assign(.char("y", [.command]), to: .mute))
        XCTAssertNotNil(defaults.object(forKey: ShortcutStore.defaultsKey))
        XCTAssertTrue(r.reset(category: .audio))
        XCTAssertNil(defaults.object(forKey: ShortcutStore.defaultsKey))
        XCTAssertFalse(r.isCustomised(.mute))
    }

    func testAssigningTheDefaultIsNotAnOverride() {
        let r = registry()
        XCTAssertTrue(r.assign(.char("y", [.command]), to: .inspector))
        XCTAssertTrue(r.assign(.char("i", [.command]), to: .inspector))
        XCTAssertFalse(r.isCustomised(.inspector))
        XCTAssertNil(defaults.object(forKey: ShortcutStore.defaultsKey))
    }

    func testUnreadableStoredValueIsNeverOverwritten() {
        defaults.set("not json", forKey: ShortcutStore.defaultsKey)
        let r = registry()
        XCTAssertFalse(r.assign(.char("y", [.command]), to: .mute))
        XCTAssertEqual(defaults.string(forKey: ShortcutStore.defaultsKey), "not json")
        XCTAssertEqual(r.chord(for: .mute), r.definition(.mute).defaultChord)
    }

    func testStoredKeyForADebugOrFixedRowIsIgnored() {
        defaults.set(#"{"overrides":{"debug.ndiConnectFirst":{"key":"z","modifiers":["command"]},"timecode.open":null},"version":1}"#,
                     forKey: ShortcutStore.defaultsKey)
        let r = registry()
        XCTAssertEqual(r.chord(for: .debugNDIConnect), .char("n", [.control, .option]))
        XCTAssertFalse(r.isCustomised(.timecodeOpen))
    }

    func testRevisionBumpsOnEveryChange() {
        let r = registry()
        let before = r.revision
        r.assign(.char("y", [.command]), to: .mute)
        r.reset(.mute)
        XCTAssertEqual(r.revision, before + 2)
    }

    // MARK: Labels

    func testLabelsAreTheLayoutsCharacter() {
        let r = registry()
        XCTAssertEqual(r.label(.code(42, [])), "\\")
        struct German: KeyLayout {
            func character(for keyCode: UInt16, shift: Bool) -> String? { keyCode == 42 ? (shift ? "'" : "#") : nil }
        }
        XCTAssertEqual(KeyLabel.label(.code(42, [.shift]), layout: German()), "⇧#")
        XCTAssertEqual(KeyLabel.label(.code(KeyCode.space, [.option, .command])), "⌥⌘Space")
        XCTAssertEqual(r.helpText("Pin controls", .alwaysShowControls), "Pin controls (⌥⌘T)")
        XCTAssertEqual(r.helpText("Next", .cycleInterpretation), "Next")
    }

    func testMenuShortcutConversion() {
        XCTAssertEqual(KeyChord.char("n").menuShortcut(layout: USKeyLayout())?.key.character, "n")
        XCTAssertEqual(KeyChord.char("n").menuShortcut(layout: USKeyLayout())?.modifiers, [])
        XCTAssertEqual(KeyChord.char("d", [.shift, .command]).menuShortcut(layout: USKeyLayout())?.key.character, "D")
        XCTAssertEqual(KeyChord.code(KeyCode.delete, [.option, .command]).menuShortcut(layout: USKeyLayout())?.key, .delete)
        XCTAssertEqual(KeyChord.code(KeyCode.down, [.option, .command]).menuShortcut(layout: USKeyLayout())?.key, .downArrow)
        let s = KeyChord.char("1", [.option, .command]).menuShortcut(layout: USKeyLayout())
        XCTAssertEqual(s?.key.character, "1")
        XCTAssertEqual(s?.modifiers, [.option, .command])
        XCTAssertEqual(KeyChord.code(KeyCode.rightBracket, [.option]).menuShortcut(layout: USKeyLayout())?.key.character, "]")
    }
}
