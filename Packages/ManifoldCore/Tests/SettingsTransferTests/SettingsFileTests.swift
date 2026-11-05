import XCTest
@testable import SettingsTransfer
import ShortcutRegistry

/// docs/SETTINGS_EXPORT_PLAN.md §8: the plain file, its refusals, and the backups.
final class SettingsFileTests: XCTestCase {
    private let provenance = SettingsFile.Provenance(appVersion: "0.9.2", appBuild: "24",
                                                     exportedAt: Date(timeIntervalSince1970: 1_793_000_000))
    private let overrides: [String: Any] = ["view.inspector": ["key": "i", "modifiers": ["command", "option"]],
                                            "view.fileName": NSNull()]

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func root(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var r: [String: Any] = ["kind": SettingsFile.kind, "formatVersion": 1, "appVersion": "0.9.2",
                                "sections": ["shortcuts": ["version": 1, "overrides": [:] as [String: Any]]]]
        change(&r)
        return json(r)
    }

    private func document(_ data: Data) -> SettingsFile.Document? { try? SettingsFile.read(data).get() }
    private func failure(_ data: Data) -> SettingsFile.ReadError? {
        if case .failure(let e) = SettingsFile.read(data) { return e }
        return nil
    }

    func testRoundTrip() throws {
        let data = try SettingsFile.encodePlain(shortcuts: overrides, provenance: provenance)
        let read = try XCTUnwrap(document(data))
        XCTAssertEqual(read.appVersion, "0.9.2")
        XCTAssertEqual(read.exportedAt, provenance.exportedAt)
        XCTAssertEqual(read.shortcuts?.keys.sorted(), overrides.keys.sorted())
        XCTAssertTrue(read.shortcuts?["view.fileName"] is NSNull)
        XCTAssertEqual(read.left, [])
    }

    func testTheSameSettingsGiveTheSameBytes() throws {
        XCTAssertEqual(try SettingsFile.encodePlain(shortcuts: overrides, provenance: provenance),
                       try SettingsFile.encodePlain(shortcuts: overrides, provenance: provenance))
    }

    /// The exact top-level keys. A new one fails here until someone has decided it belongs in a plain file.
    func testAPlainFileHoldsExactlyTheseKeys() throws {
        let data = try SettingsFile.encodePlain(shortcuts: overrides, provenance: provenance)
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(top.keys.sorted(), ["appBuild", "appVersion", "exportedAt", "formatVersion", "kind", "sections"])
        XCTAssertEqual((top["sections"] as? [String: Any])?.keys.sorted(), ["shortcuts"])
    }

    func testAFrozenVersionOneFileStillReads() throws {
        let frozen = #"{"appBuild":"24","appVersion":"0.9.2","exportedAt":"2026-11-03T18:30:00Z","formatVersion":1,"kind":"com.graviton.manifold.settings","sections":{"shortcuts":{"overrides":{"view.inspector":{"key":"i","modifiers":["command","option"]}},"version":1}}}"#
        XCTAssertEqual(document(Data(frozen.utf8))?.shortcuts?.count, 1)
    }

    func testUnreadableFiles() {
        XCTAssertEqual(failure(Data("not json".utf8)), .damaged)
        XCTAssertEqual(failure(Data()), .damaged)
        XCTAssertEqual(failure(json([1, 2])), .damaged)
        let whole = root()
        XCTAssertEqual(failure(whole.prefix(whole.count / 2)), .damaged)
        XCTAssertEqual(failure(Data(repeating: 0x20, count: SettingsFile.maxBytes + 1)), .tooLarge)
        XCTAssertEqual(failure(Data(String(repeating: "[", count: 100_000).utf8)), .damaged)
    }

    func testHeaderTampering() {
        XCTAssertEqual(failure(root { $0["kind"] = "something.else" }), .notSettings)
        XCTAssertEqual(failure(root { $0["kind"] = nil }), .notSettings)
        XCTAssertEqual(failure(root { $0["formatVersion"] = "1" }), .damaged)
        XCTAssertEqual(failure(root { $0["formatVersion"] = true }), .damaged)
        XCTAssertEqual(failure(root { $0["formatVersion"] = 1.5 }), .damaged)
        XCTAssertEqual(failure(root { $0["formatVersion"] = 0 }), .damaged)
        XCTAssertEqual(failure(root { $0["sections"] = [1] }), .damaged)
    }

    func testANewerFormatIsRefusedWhole() {
        XCTAssertEqual(failure(root { $0["formatVersion"] = 2; $0["appVersion"] = "1.4.0" }), .newerFormat("1.4.0"))
        XCTAssertTrue(SettingsFile.ReadError.newerFormat("1.4.0").message.contains("Manifold 1.4.0"))
    }

    func testAnEncryptedFileIsRefusedByNameUntilThatStageExists() {
        XCTAssertEqual(failure(root { $0["encryption"] = ["cipher": "AES-GCM-256"] }), .encrypted)
    }

    func testUnknownKeysAreIgnoredAndUnknownSectionsListed() throws {
        let read = try XCTUnwrap(document(root {
            $0["futureKey"] = "x"
            $0["sections"] = ["shortcuts": ["version": 1, "overrides": ["view.inspector": NSNull()], "futureKey": 1],
                              "preferences": ["version": 1]]
        }))
        XCTAssertEqual(read.shortcuts?.count, 1)
        XCTAssertEqual(read.left, [.init(name: "preferences", reason: .unknown)])
    }

    func testANewerOrDamagedSectionCostsOnlyThatSection() throws {
        let newer = try XCTUnwrap(document(root {
            $0["sections"] = ["shortcuts": ["version": 2, "overrides": [:] as [String: Any]]]
        }))
        XCTAssertNil(newer.shortcuts)
        XCTAssertEqual(newer.left, [.init(name: "shortcuts", reason: .newerVersion)])
        for bad: Any in [1, ["version": 1], ["version": "1", "overrides": [:] as [String: Any]],
                         ["version": 1, "overrides": [1]]] {
            let read = try XCTUnwrap(document(root { $0["sections"] = ["shortcuts": bad] }))
            XCTAssertNil(read.shortcuts)
            XCTAssertEqual(read.left, [.init(name: "shortcuts", reason: .malformed)])
        }
    }

    func testSuggestedFilename() {
        let name = SettingsFile.suggestedFilename(on: Date())
        XCTAssertTrue(name.hasPrefix("Manifold Settings 20"))
        XCTAssertTrue(name.hasSuffix(".manifoldsettings"))
    }
}

final class SettingsBackupsTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsBackups-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testWritesReadsBackAndListsNewestFirst() throws {
        let backups = SettingsBackups(directory: directory)
        let first = try backups.write(Data("a".utf8), at: Date(timeIntervalSince1970: 1_000_000))
        let second = try backups.write(Data("b".utf8), at: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(backups.list().map(\.lastPathComponent), [second, first].map(\.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: first), Data("a".utf8))
    }

    func testTwoInOneSecondBothSurvive() throws {
        let backups = SettingsBackups(directory: directory)
        let date = Date()
        try backups.write(Data("a".utf8), at: date)
        try backups.write(Data("b".utf8), at: date)
        XCTAssertEqual(backups.list().count, 2)
    }

    func testKeepsTheNewestAndTouchesNothingElse() throws {
        let backups = SettingsBackups(directory: directory, keep: 3)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let other = directory.appendingPathComponent("Notes.txt")
        try Data("mine".utf8).write(to: other)
        for i in 0..<6 { try backups.write(Data([UInt8(i)]), at: Date(timeIntervalSince1970: Double(1_000_000 + i * 60))) }
        XCTAssertEqual(backups.list().count, 3)
        XCTAssertEqual(try Data(contentsOf: backups.list()[0]), Data([5]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testAFolderThatCannotBeWrittenStopsTheBackup() throws {
        try Data("a file, not a folder".utf8).write(to: directory)
        XCTAssertThrowsError(try SettingsBackups(directory: directory).write(Data("a".utf8), at: Date())) {
            XCTAssertEqual($0 as? SettingsBackups.BackupError, .notWritten)
        }
    }
}

/// Shortcuts end to end, on two stores standing for two Macs.
@MainActor
final class ShortcutTransferTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for s in suites { UserDefaults(suiteName: s)?.removePersistentDomain(forName: s) }
        super.tearDown()
    }

    private func mac() -> ShortcutRegistry {
        let name = "ShortcutTransferTests.\(UUID().uuidString)"
        suites.append(name)
        return ShortcutRegistry(store: ShortcutStore(defaults: UserDefaults(suiteName: name)!), layout: USKeyLayout(),
                                debugTierEnabled: { _ in false })
    }

    private let provenance = SettingsFile.Provenance(appVersion: "0.9.2", appBuild: "24", exportedAt: Date())

    private func export(_ r: ShortcutRegistry) throws -> Data {
        try SettingsFile.encodePlain(shortcuts: try XCTUnwrap(r.exportableOverrides()), provenance: provenance)
    }

    func testRoundTripToAnotherMac() throws {
        let studio = mac(), air = mac()
        studio.assign(.char("y", [.command, .option]), to: .inspector)
        studio.assign(nil, to: .fileName)
        let file = try XCTUnwrap(try SettingsFile.read(export(studio)).get().shortcuts)
        XCTAssertTrue(air.applyImport(air.importPlan(file: file, mode: .replaceAll)))
        for def in ShortcutCatalog.all { XCTAssertEqual(air.chord(for: def.id), studio.chord(for: def.id), def.id.rawValue) }
    }

    /// Undo: the backup taken before an import, applied, gives back exactly what was there.
    func testBackupRestoresTheExactPriorState() throws {
        let r = mac()
        r.assign(.char("y", [.command, .option]), to: .inspector)
        let backup = try export(r)
        let before = ShortcutCatalog.all.map { r.chord(for: $0.id) }

        let incoming: [String: Any] = ["view.inspector": ["key": "u", "modifiers": ["command", "option"]],
                                       "view.fileName": NSNull()]
        XCTAssertTrue(r.applyImport(r.importPlan(file: incoming, mode: .replaceAll)))
        XCTAssertNotEqual(ShortcutCatalog.all.map { r.chord(for: $0.id) }, before)

        let saved = try XCTUnwrap(try SettingsFile.read(backup).get().shortcuts)
        let plan = r.importPlan(file: saved, mode: .replaceAll)
        XCTAssertEqual(plan.refused, [])
        XCTAssertEqual(plan.conflicts, [])
        XCTAssertTrue(r.applyImport(plan))
        XCTAssertEqual(ShortcutCatalog.all.map { r.chord(for: $0.id) }, before)
    }

    func testASettingsFileIsKnownByItsExtension() {
        XCTAssertTrue(SettingsFile.isSettingsFile(URL(fileURLWithPath: "/tmp/My Mac.manifoldsettings")))
        XCTAssertTrue(SettingsFile.isSettingsFile(URL(fileURLWithPath: "/tmp/SHOUT.MANIFOLDSETTINGS")))
        XCTAssertFalse(SettingsFile.isSettingsFile(URL(fileURLWithPath: "/tmp/clip.mov")))
        XCTAssertFalse(SettingsFile.isSettingsFile(URL(fileURLWithPath: "/tmp/settings.json")))
        XCTAssertFalse(SettingsFile.isSettingsFile(URL(string: "https://example.invalid/a.manifoldsettings")!))
    }
}
