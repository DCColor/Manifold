import XCTest
@testable import ShortcutRegistry

/// docs/SETTINGS_EXPORT_PLAN.md §4.3: a file's shortcuts judged as one set.
@MainActor
final class ShortcutImportTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "ShortcutImportTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func registry(debug: Bool = false) -> ShortcutRegistry {
        ShortcutRegistry(store: ShortcutStore(defaults: defaults), layout: USKeyLayout(), debugTierEnabled: { _ in debug })
    }

    private func key(_ c: String, _ modifiers: [String] = ["command", "option"]) -> [String: Any] {
        ["key": c, "modifiers": modifiers]
    }

    /// A chord nothing in the catalog holds.
    private let free: KeyChord = .char("y", [.command, .option])
    private let free2: KeyChord = .char("u", [.command, .option])

    func testASwapOfTwoKeysPassesAlthoughEachHalfConflictsWithTheCurrentBindings() {
        let r = registry()
        XCTAssertTrue(r.assign(free, to: .inspector))
        XCTAssertTrue(r.assign(free2, to: .fileName))
        let plan = r.importPlan(file: ["view.inspector": key("u"), "view.fileName": key("y")], mode: .merge)
        XCTAssertEqual(plan.refused, [])
        XCTAssertEqual(plan.conflicts, [])
        XCTAssertEqual(Set(plan.changes.map(\.id)), [.inspector, .fileName])
        XCTAssertTrue(r.applyImport(plan))
        XCTAssertEqual(r.chord(for: .inspector), free2)
        XCTAssertEqual(r.chord(for: .fileName), free)
    }

    func testMergeKeepsOverridesTheFileDoesNotMention() {
        let r = registry()
        r.assign(free, to: .inspector)
        XCTAssertTrue(r.applyImport(r.importPlan(file: ["view.fileName": key("u")], mode: .merge)))
        XCTAssertEqual(r.chord(for: .inspector), free)
        XCTAssertEqual(r.chord(for: .fileName), free2)
    }

    func testReplaceAllResetsOverridesTheFileDoesNotMention() {
        let r = registry()
        r.assign(free, to: .inspector)
        let plan = r.importPlan(file: ["view.fileName": key("u")], mode: .replaceAll)
        XCTAssertTrue(r.applyImport(plan))
        XCTAssertEqual(r.chord(for: .inspector), r.definition(.inspector).defaultChord)
        XCTAssertFalse(r.isCustomised(.inspector))
        XCTAssertEqual(r.chord(for: .fileName), free2)
    }

    func testNullMeansNoKey() {
        let r = registry()
        XCTAssertTrue(r.applyImport(r.importPlan(file: ["view.inspector": NSNull()], mode: .merge)))
        XCTAssertNil(r.chord(for: .inspector))
        XCTAssertTrue(r.isCustomised(.inspector))
    }

    func testReservedKeyIsNeverImported() {
        let r = registry()
        let plan = r.importPlan(file: ["view.inspector": key("q", ["command"])], mode: .merge)
        XCTAssertEqual(plan.refused.count, 1)
        XCTAssertEqual(plan.changes, [])
    }

    func testShiftedArrowOnAMenuActionAndCommandOnAHoldAreRefused() {
        let r = registry()
        let menu = r.definitions.first { $0.dispatch == .menu && $0.rebindable }!
        let hold = r.definitions.first { $0.dispatch == .hold && $0.rebindable }!
        let plan = r.importPlan(file: [menu.id.rawValue: ["code": Int(KeyCode.left), "modifiers": ["shift"]],
                                       hold.id.rawValue: key("y", ["command"])], mode: .merge)
        XCTAssertEqual(plan.refused.count, 2)
        XCTAssertEqual(plan.changes, [])
    }

    func testAClashWithAFixedRowIsRefused() {
        let r = registry()
        let fixed = r.definitions.first { !$0.rebindable && $0.debug == nil && $0.scope != .timecodeEntry && $0.defaultChord != nil }!
        let target = r.definitions.first { $0.rebindable && $0.scope.overlaps(fixed.scope) && $0.dispatch == .key }!
        let plan = r.importPlan(file: [target.id.rawValue: ShortcutStore.encode(fixed.defaultChord!)], mode: .merge)
        XCTAssertEqual(plan.refused.count, 1)
        XCTAssertEqual(plan.changes, [])
    }

    func testAClashWithAnActionTheFileDoesNotMentionKeepsThisMacsKeyUnlessChosen() {
        let r = registry()
        r.assign(free, to: .inspector)
        let file: [String: Any] = ["view.fileName": key("y")]

        let keep = r.importPlan(file: file, mode: .merge)
        XCTAssertEqual(keep.conflicts.map(\.id), [.fileName])
        XCTAssertEqual(keep.conflicts.first?.usesFile, false)
        XCTAssertEqual(keep.changes, [])

        let use = r.importPlan(file: file, mode: .merge, useFile: [.fileName])
        XCTAssertEqual(use.conflicts.first?.usesFile, true)
        XCTAssertTrue(r.applyImport(use))
        XCTAssertEqual(r.chord(for: .fileName), free)
        XCTAssertNil(r.chord(for: .inspector))
    }

    /// Keeping a key puts an action back where a second file binding wanted to go: the second one conflicts in turn.
    func testGivingUpABindingIsJudgedAgainstTheRestOfTheFile() {
        let r = registry()
        r.assign(free, to: .inspector)        // holds Y
        r.assign(free2, to: .fileName)        // holds U
        let plan = r.importPlan(file: ["view.fileName": key("y"),
                                       "view.alwaysShowControls": key("u")], mode: .merge)
        XCTAssertEqual(Set(plan.conflicts.map(\.id)), [.fileName, .alwaysShowControls])
        XCTAssertEqual(plan.changes, [])
    }

    func testTwoFileBindingsOnOneKeyAreBothRefused() {
        let r = registry()
        let plan = r.importPlan(file: ["view.inspector": key("y"), "view.fileName": key("y")], mode: .merge)
        XCTAssertEqual(plan.refused.count, 2)
        XCTAssertEqual(plan.changes, [])
    }

    func testUnknownIdsAndRowsThatCannotBeReboundAreSkippedAndListed() {
        let r = registry()
        let plan = r.importPlan(file: ["future.action": key("y"), "file.open": key("u"),
                                       "debug.ndiToneTest": key("u")], mode: .merge)
        XCTAssertEqual(plan.skipped.count, 3)
        XCTAssertEqual(plan.changes, [])
    }

    func testMalformedBindingsAreReportedNotDropped() {
        let r = registry()
        let bad: [Any] = ["text", 7, ["modifiers": ["command"]], ["key": "ab", "modifiers": []],
                          ["key": "y", "modifiers": ["hyper"]], ["code": 500, "modifiers": []],
                          ["code": true, "modifiers": []], ["key": "\n", "modifiers": []], ["key": " ", "modifiers": []]]
        for value in bad {
            let plan = r.importPlan(file: ["view.inspector": value], mode: .merge)
            XCTAssertEqual(plan.refused.count, 1, "\(value)")
            XCTAssertEqual(plan.changes, [], "\(value)")
        }
    }

    func testAnOverrideEqualToTheDefaultStoresNothing() {
        let r = registry()
        let original = r.definition(.inspector).defaultChord!
        XCTAssertTrue(r.applyImport(r.importPlan(file: ["view.inspector": ShortcutStore.encode(original)], mode: .merge)))
        XCTAssertNil(defaults.object(forKey: ShortcutStore.defaultsKey))
    }

    func testDebugTierDecidesWhetherADebugDefaultIsTaken() {
        let debugChord = ShortcutCatalog.all.first { $0.debug == .profile && $0.defaultChord != nil }!.defaultChord!
        let file: [String: Any] = ["view.fileName": ShortcutStore.encode(debugChord)]
        XCTAssertEqual(registry(debug: true).importPlan(file: file, mode: .merge).refused.count, 1)
        XCTAssertEqual(registry(debug: false).importPlan(file: file, mode: .merge).refused.count, 0)
    }

    func testAStalePlanIsNotApplied() {
        let r = registry()
        let plan = r.importPlan(file: ["view.fileName": key("u")], mode: .merge)
        r.assign(free, to: .inspector)
        XCTAssertFalse(r.applyImport(plan))
        XCTAssertEqual(r.chord(for: .fileName), r.definition(.fileName).defaultChord)
    }

    func testNothingIsWrittenOverAStoredValueThatCannotBeRead() {
        defaults.set("not json", forKey: ShortcutStore.defaultsKey)
        let r = registry()
        XCTAssertNil(r.exportableOverrides())
        XCTAssertFalse(r.applyImport(r.importPlan(file: ["view.fileName": key("u")], mode: .merge)))
        XCTAssertEqual(defaults.string(forKey: ShortcutStore.defaultsKey), "not json")
    }

    func testEntriesThisBuildCannotReadSurviveAReplaceAll() {
        defaults.set(#"{"overrides":{"future.action":{"key":"y","modifiers":["command"]},"view.inspector":null},"version":1}"#,
                     forKey: ShortcutStore.defaultsKey)
        let r = registry()
        XCTAssertTrue(r.applyImport(r.importPlan(file: [:], mode: .replaceAll)))
        let stored = defaults.string(forKey: ShortcutStore.defaultsKey) ?? ""
        XCTAssertTrue(stored.contains("future.action"))
        XCTAssertFalse(stored.contains("view.inspector"))
    }
}
