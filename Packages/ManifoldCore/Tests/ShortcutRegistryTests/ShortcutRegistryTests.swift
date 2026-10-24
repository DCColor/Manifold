import XCTest
@testable import ShortcutRegistry

/// The catalog's invariants, Robbie's scheme (docs/SHORTCUTS_AUDIT.md §4.2, decided 2026-10-23), the store, and the
/// verdicts the Keyboard Shortcuts window shows.
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
            for chord in def.defaultChords {
                XCTAssertNil(ShortcutRegistry.reserved[r.normalized(chord)], "\(def.id.rawValue) \(r.label(chord))")
                XCTAssertNil(ShortcutRegistry.reserved[chord], def.id.rawValue)
            }
        }
    }

    /// Audit C7: AppKit's key-equivalent matcher cannot tell ⇧← from ←.
    func testNoShiftedArrowOnAMenuDispatchedAction() {
        for def in ShortcutCatalog.all where def.dispatch == .menu {
            XCTAssertFalse(def.defaultChord?.isShiftedArrow ?? false, def.id.rawValue)
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

    // MARK: Robbie's scheme, 2026-10-23

    func testDecidedDefaults() {
        let r = registry()
        let expected: [ShortcutID: String?] = [
            .fileOpen: "⌘O", .exportFrame: "⌥⌘E", .inspector: "⌘I", .alwaysShowControls: "⌥⌘T", .scopesTray: "⌘7",
            .displayOS: "⌥⌘1", .displayReference: "⌥⌘2", .displayBypass: "⌥⌘3",
            .holdCompare: "D (hold)", .holdCompareBypass: "⇧D (hold)",
            .raster100: "⌘1", .raster75: "⌘2", .raster50: "⌘3", .raster25: "⌘4", .rasterFit: "⌘0",
            .fullScreen: "⌘F", .loop: "⌘L", .playPause: "Space", .shuttleReverse: "J", .shuttlePause: "K",
            .shuttleForward: "L", .stepBackFrame: "←", .stepForwardFrame: "→", .stepBackSecond: "⇧←",
            .stepForwardSecond: "⇧→", .goToStart: "Home", .goToEnd: "End", .goToStartAlternate: "⌥←",
            .goToEndAlternate: "⌥→", .fileName: "N", .audioLater1: "⌥]", .audioEarlier1: "⌥[",
            .audioLater10: "⌥⇧]", .audioEarlier10: "⌥⇧[",
            // No default (decision 1).
            .startDeckLink: nil, .stopDeckLink: nil, .connectFirstNDI: nil, .disconnectLive: nil,
            .cycleInterpretation: nil, .resetInterpretation: nil, .cieSpace: nil, .vectorscopeGraticule: nil,
            .vectorscopeBoxes: nil, .cie709: nil, .cieP3: nil, .cie2020: nil, .mute: nil,
            // Debug, unmoved except ⌃⌥R, which is now a debug hook (decision 7).
            .debugToneTest: "⌃⌥A", .debugScrubBench: "⌃⌥⇧B", .debugRenderLayer: "⌃⌥R", .debugWebRTCSmoke: "⌃⌥W",
            .debugWHEPConnect: "⌃⌥H", .debugWHEPRetire: "⌃⌥⇧H", .debugWHEPExportFrame: "⌃⌥⇧E",
            .debugSRTConnect: "⌃⌥D", .debugSRTRetire: "⌃⌥⇧D", .debugSyntheticStart: "⌃⌥L",
            .debugSyntheticStop: "⌃⌥⇧L", .debugSyntheticPreset: "⌃⌥P", .debugForceUnityRate: "⌃⌥U",
            .debugSyntheticSweep: "⌃⌥S", .debugDepthDown: "⌃⌥[", .debugDepthUp: "⌃⌥]",
        ]
        for (id, label) in expected {
            XCTAssertEqual(r.label(for: id), label, id.rawValue)
        }
        XCTAssertEqual(r.definition(.debugRenderLayer).debug, .profile)
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
                                   .char("r", [.control, .option]), .char("\\"), .char("|", [.shift])]
        for chord in removed {
            XCTAssertEqual(r.conflicts(for: chord, scope: .app), [], r.label(chord))
        }
    }

    // MARK: Menus

    func testMenuChordIsNilForBareKeys() {
        let r = registry()
        XCTAssertEqual(r.menuChord(for: .inspector), .char("i", [.command]))
        XCTAssertNil(r.menuChord(for: .fileName))       // N: the dispatcher's
        XCTAssertNil(r.menuChord(for: .startDeckLink))  // no key
        XCTAssertTrue(r.dispatcherBindings().contains { $0.0.id == .fileName })
        XCTAssertFalse(r.dispatcherBindings().contains { $0.0.id == .inspector })
    }

    func testDebugBindingsFollowTheirTier() {
        let on = ShortcutRegistry(store: ShortcutStore(defaults: defaults), layout: USKeyLayout(),
                                  debugTierEnabled: { $0 == .profile })
        let ids = Set(on.dispatcherBindings().map(\.0.id))
        XCTAssertTrue(ids.contains(.debugRenderLayer))
        XCTAssertFalse(ids.contains(.debugSyntheticStart))
        XCTAssertFalse(Set(registry(debug: false).dispatcherBindings().map(\.0.id)).contains(.debugRenderLayer))
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
        guard case .conflict(let with, _) = r.propose(.char("7", [.command]), for: .inspector) else { return XCTFail() }
        XCTAssertEqual(with, [.scopesTray])
        XCTAssertFalse(r.assign(.char("7", [.command]), to: .inspector))            // Cancel
        XCTAssertEqual(r.chord(for: .inspector), .char("i", [.command]))
        XCTAssertTrue(r.assign(.char("7", [.command]), to: .inspector, replacing: true))
        XCTAssertEqual(r.chord(for: .inspector), .char("7", [.command]))
        XCTAssertNil(r.chord(for: .scopesTray))
        XCTAssertTrue(r.isCustomised(.scopesTray))
    }

    func testFixedRowsCannotBeTakenOrChanged() {
        let r = registry()
        guard case .refused = r.propose(.char("5"), for: .fileName) else { return XCTFail("digit is timecode entry") }
        guard case .refused = r.propose(.code(KeyCode.escape), for: .fileName) else { return XCTFail("Esc") }
        guard case .refused = r.propose(.char("x"), for: .timecodeOpen) else { return XCTFail("fixed row") }
        guard case .refused = r.propose(.char("x", [.command]), for: .fileOpen) else { return XCTFail("⌘O") }
        guard case .refused = r.propose(.char("x", [.control, .option]), for: .debugRenderLayer) else { return XCTFail() }
    }

    func testShiftedArrowRefusedOnMenuAndCommandRefusedOnHold() {
        let r = registry()
        guard case .refused = r.propose(.code(KeyCode.up, [.shift]), for: .inspector) else { return XCTFail() }
        guard case .accepted = r.propose(.code(KeyCode.up, [.shift]), for: .mute) else { return XCTFail() }
        guard case .refused = r.propose(.char("d", [.command, .option]), for: .holdCompare) else { return XCTFail() }
    }

    func testWarnings() {
        let r = registry()
        guard case .accepted(let w1) = r.propose(.char("y", [.control, .option]), for: .mute) else { return XCTFail() }
        XCTAssertTrue(w1.contains { $0.contains("VoiceOver") })
        guard case .accepted(let w2) = r.propose(.code(KeyCode.pageUp), for: .mute) else { return XCTFail() }
        XCTAssertTrue(w2.contains { $0.contains("Fn") })
        guard case .accepted(let w3) = r.propose(.char("y"), for: .inspector) else { return XCTFail() }
        XCTAssertTrue(w3.contains { $0.contains("Not shown in the menu") })
        guard case .accepted(let w4) = r.propose(.char(";"), for: .mute) else { return XCTFail() }
        XCTAssertTrue(w4.contains { $0.contains("keyboard layouts") })
        guard case .accepted(let w5) = r.propose(.code(KeyCode.tab), for: .mute) else { return XCTFail() }
        XCTAssertTrue(w5.contains { $0.contains("Keyboard navigation") })
    }

    /// A code binding and a character binding for the same key on this layout are one key.
    func testCodeAndCharacterBindingsOfOneKeyConflict() {
        let r = registry()
        guard case .conflict(let with, _) = r.propose(.char("]", [.option]), for: .mute) else { return XCTFail() }
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
        XCTAssertNil(r.chord(for: .mute))
    }

    func testStoredKeyForADebugOrFixedRowIsIgnored() {
        defaults.set(#"{"overrides":{"debug.renderLayer":{"key":"z","modifiers":["command"]},"timecode.open":null},"version":1}"#,
                     forKey: ShortcutStore.defaultsKey)
        let r = registry()
        XCTAssertEqual(r.chord(for: .debugRenderLayer), .char("r", [.control, .option]))
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
        XCTAssertEqual(r.helpText("Start output", .startDeckLink), "Start output")
    }

    func testMenuShortcutConversion() {
        XCTAssertNil(KeyChord.char("n").menuShortcut(layout: USKeyLayout()))
        let s = KeyChord.char("1", [.option, .command]).menuShortcut(layout: USKeyLayout())
        XCTAssertEqual(s?.key.character, "1")
        XCTAssertEqual(s?.modifiers, [.option, .command])
        XCTAssertEqual(KeyChord.code(KeyCode.rightBracket, [.option]).menuShortcut(layout: USKeyLayout())?.key.character, "]")
    }
}
