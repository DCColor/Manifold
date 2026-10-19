import XCTest
import Security
@testable import LicenseRecord

/// Privacy stage P1: the licence email and machine id leave the preferences plist.
///
/// ⚠️ EVERY TEST HERE USES A SCRATCH KEYCHAIN SERVICE, named with a fresh UUID and emptied in
/// tearDown, and an IN-MEMORY plist (`MemoryStore`). The real licence service
/// (`tools.graviton.manifold.license`) and the real domain (`com.graviton.manifold`) are never named.
/// The preferences plist, in memory. See `LegacyLicenseStore` for why not a scratch suite.
final class MemoryStore: LegacyLicenseStore {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func removeObject(forKey key: String) { values[key] = nil }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func object(forKey key: String) -> Any? { values[key] }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
}

final class LicenseRecordSyncTests: XCTestCase {

    private var service = ""
    private var defaults: MemoryStore!

    override func setUp() {
        let tag = UUID().uuidString
        service = "tools.graviton.manifold.p1test.\(tag)"
        defaults = MemoryStore()
        XCTAssertFalse(service.hasPrefix("tools.graviton.manifold.license"))
    }

    override func tearDown() {
        for account in ["activationRecord", "storedLicenseKey"] { delete(account) }
    }

    // MARK: A minimal scratch Keychain (generic passwords, the same class the app uses)

    private func write(_ value: String, _ account: String) -> Int32 {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        let s = SecItemUpdate(q as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if s == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = Data(value.utf8)
            return SecItemAdd(add as CFDictionary, nil)
        }
        return s
    }

    private func readString(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    private func readRecord() -> RecordRead {
        guard let s = readString("activationRecord") else { return .absent }
        return ActivationRecord.decode(s).map(RecordRead.found) ?? .failed(errSecDecode)
    }

    private func run(_ current: LicenseRecordSync.Current,
                     read: (() -> RecordRead)? = nil,
                     write w: ((String) -> Int32)? = nil) -> LicenseRecordSync.Outcome {
        LicenseRecordSync.run(defaults: defaults, current: current,
                              read: read ?? { self.readRecord() },
                              write: w ?? { self.write($0, "activationRecord") },
                              mint: { "MINTED-ID" })
    }

    private func seedLicensedInstall(recordMachineId: String = "MID-1") {
        XCTAssertEqual(write("MNFL-scratch.key", "storedLicenseKey"), errSecSuccess)
        let rec = ActivationRecord(activated: true, validated: true, email: "a@example.com",
                                   type: "standard", machineId: recordMachineId)
        XCTAssertEqual(write(rec.encoded()!, "activationRecord"), errSecSuccess)
        defaults.set(true, forKey: "license.activated")
        defaults.set(true, forKey: "license.validated")
        defaults.set("standard", forKey: "license.type")
        defaults.set("a@example.com", forKey: "license.email")
        defaults.set("MID-1", forKey: "license.machineId")
    }

    // MARK: P1 — a licensed install stays licensed

    func testLicensedInstallStaysLicensedAndLosesOnlyTheTwoPlistKeys() {
        seedLicensedInstall()
        let keyBefore = readString("storedLicenseKey")

        let out = run(.init(licensed: true, validated: true, email: "a@example.com", type: "standard"))

        XCTAssertFalse(out.keychainFailed)
        XCTAssertEqual(out.machineId, "MID-1")
        XCTAssertEqual(Set(out.removedKeys), ["license.email", "license.machineId"])
        // The plist no longer holds them…
        XCTAssertNil(defaults.object(forKey: "license.email"))
        XCTAssertNil(defaults.object(forKey: "license.machineId"))
        // …and nothing that decides licensing moved.
        XCTAssertEqual(readString("storedLicenseKey"), keyBefore)
        XCTAssertEqual(defaults.bool(forKey: "license.activated"), true)
        XCTAssertEqual(defaults.bool(forKey: "license.validated"), true)
        XCTAssertEqual(defaults.string(forKey: "license.type"), "standard")
        let rec = readRecord().record
        XCTAssertEqual(rec?.activated, true)
        XCTAssertEqual(rec?.machineId, "MID-1")
        XCTAssertEqual(rec?.email, "a@example.com")
        // The log names keys, never values.
        XCTAssertFalse(out.log.joined().contains("a@example.com"))
        XCTAssertFalse(out.log.joined().contains("MID-1"))
    }

    func testSecondRunIsANoOp() {
        seedLicensedInstall()
        _ = run(.init(licensed: true, validated: true, email: "a@example.com", type: "standard"))
        var writes = 0
        let out = run(.init(licensed: true, validated: true, email: "a@example.com", type: "standard"),
                      write: { writes += 1; return self.write($0, "activationRecord") })
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(out.removedKeys.isEmpty)
        XCTAssertEqual(out.machineId, "MID-1")
    }

    // MARK: Keychain failure — leave the plist alone

    func testFailedReadLeavesThePlistExactlyAsItWas() {
        seedLicensedInstall()
        let before = defaults.values
        var writes = 0
        let out = run(.init(licensed: true, validated: true, email: "a@example.com", type: "standard"),
                      read: { .failed(-25293) },              // errSecAuthFailed
                      write: { _ in writes += 1; return 0 })
        XCTAssertTrue(out.keychainFailed)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(Set(out.keptKeys), ["license.email", "license.machineId"])
        XCTAssertEqual(out.machineId, "MID-1", "the legacy id is still used in memory")
        XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: defaults.values))
        XCTAssertTrue(out.log.contains { $0.contains("left in place") })
    }

    func testFailedReadBackLeavesThePlist() {
        defaults.set("a@example.com", forKey: "license.email")
        defaults.set("MID-1", forKey: "license.machineId")
        var reads = 0
        let out = run(.init(licensed: true, validated: true, email: "a@example.com", type: "standard"),
                      read: { reads += 1; return reads == 1 ? .absent : .failed(-25293) })
        XCTAssertTrue(out.keychainFailed)
        XCTAssertNotNil(defaults.object(forKey: "license.email"))
        XCTAssertNotNil(defaults.object(forKey: "license.machineId"))
    }

    func testFailedWriteLeavesThePlist() {
        defaults.set("MID-1", forKey: "license.machineId")
        let out = run(.init(licensed: true, validated: true, email: "a@example.com", type: "standard"),
                      read: { .absent }, write: { _ in -25299 })
        XCTAssertTrue(out.keychainFailed)
        XCTAssertEqual(defaults.string(forKey: "license.machineId"), "MID-1")
    }

    // MARK: Mismatch — keep the mismatched key, remove the matching one

    func testMismatchedMachineIdIsKept() {
        seedLicensedInstall(recordMachineId: "MID-KEYCHAIN")
        let out = run(.init(licensed: true, validated: true, email: "a@example.com", type: "standard"))
        XCTAssertEqual(out.machineId, "MID-KEYCHAIN", "the Keychain's id wins, as before P1")
        XCTAssertEqual(defaults.string(forKey: "license.machineId"), "MID-1")
        XCTAssertNil(defaults.object(forKey: "license.email"))
        XCTAssertEqual(out.keptKeys, ["license.machineId"])
    }

    // MARK: Unlicensed installs keep their machine id, in the Keychain

    func testTrialInstallWithALegacyIdGetsAnUnactivatedRecord() {
        defaults.set("MID-TRIAL", forKey: "license.machineId")
        let out = run(.init(licensed: false))
        XCTAssertEqual(out.machineId, "MID-TRIAL")
        XCTAssertNil(defaults.object(forKey: "license.machineId"))
        let rec = readRecord().record
        XCTAssertEqual(rec?.activated, false)
        XCTAssertEqual(rec?.machineId, "MID-TRIAL")
    }

    func testCleanUnlicensedInstallTouchesNothing() {
        var reads = 0
        let out = run(.init(licensed: false), read: { reads += 1; return .absent })
        XCTAssertEqual(reads, 0, "no Keychain round trip for a clean, unlicensed install")
        XCTAssertNil(out.machineId)
        XCTAssertEqual(readRecord(), .absent)
    }

    func testLicensedWithNoIdAnywhereMintsOne() {
        let out = run(.init(licensed: true, validated: true, email: "a@example.com", type: "standard"))
        XCTAssertEqual(out.machineId, "MINTED-ID")
        XCTAssertEqual(readRecord().record?.machineId, "MINTED-ID")
    }

    func testReservingBeforeActivationPersistsTheIdAndReusesIt() {
        let first = run(.init(licensed: false, reserveMachineId: true))
        XCTAssertEqual(first.machineId, "MINTED-ID")
        XCTAssertEqual(readRecord().record?.activated, false)
        // The next attempt (say, after a lost reply) reads the SAME id back, and mints nothing.
        let second = LicenseRecordSync.run(defaults: defaults, current: .init(licensed: false, reserveMachineId: true),
                                           read: { self.readRecord() }, write: { self.write($0, "activationRecord") },
                                           mint: { "SECOND-MINT" })
        XCTAssertEqual(second.machineId, "MINTED-ID")
    }

    func testEmptyLegacyValuesAreRemovedOnceTheRecordReadsBack() {
        seedLicensedInstall()
        defaults.set("", forKey: "license.email")   // what a deactivation left behind
        _ = run(.init(licensed: true, validated: true, email: "a@example.com", type: "standard"))
        XCTAssertNil(defaults.object(forKey: "license.email"))
    }

    func testRecordRoundTripsAndToleratesUnknownFields() {
        let rec = ActivationRecord(activated: true, validated: false, email: "e", type: "beta", machineId: "m")
        XCTAssertEqual(ActivationRecord.decode(rec.encoded()!), rec)
        let newer = #"{"activated":true,"validated":true,"email":"e","type":"beta","machineId":"m","v":2,"x":1}"#
        XCTAssertEqual(ActivationRecord.decode(newer)?.machineId, "m")
    }
}
