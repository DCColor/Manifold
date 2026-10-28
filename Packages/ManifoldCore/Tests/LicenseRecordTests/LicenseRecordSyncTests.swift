import XCTest
import Security
import CryptoKit
@testable import LicenseRecord
@testable import LicenseClient

/// The license client's Keychain storage (`LicenseRecordStore`), the one-time conversion of an
/// existing activation, and privacy stage P1's move of the email and machine id out of the plist.
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
}

/// 0.8.4's `ActivationRecord`, verbatim (dd3984b App/LicenseManager.swift:400-420). What a user who
/// downgrades runs. It must decode every record this release writes, or 0.8.4 overwrites it.
struct ActivationRecord084: Codable {
    var activated: Bool
    var validated: Bool
    var email: String
    var type: String
    var machineId: String
    var v: Int = 1

    static func decode(_ json: String) -> ActivationRecord084? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ActivationRecord084.self, from: data)
    }
}

// A test keypair and key, signed the way the worker signs (see LicenseClientTests).
private let signer = Curve25519.Signing.PrivateKey()
private func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
private func makeKey(type: String = "standard") -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["email": "a@example.com", "licenseType": type,
                                                              "expires": NSNull()], options: [.sortedKeys])
    return "MNFL-" + b64url(payload) + "." + b64url(try! signer.signature(for: payload))
}
private let KEY = makeKey()
private func verify(_ key: String) -> LicenseFields? {
    LicenseKey.verify(key, keyPrefix: "MNFL-", publicKey: signer.publicKey.rawRepresentation, nowMs: 0).payload
}

final class LicenseRecordSyncTests: XCTestCase {

    private var service = ""
    private var defaults: MemoryStore!

    override func setUp() {
        service = "tools.graviton.manifold.p1test.\(UUID().uuidString)"
        defaults = MemoryStore()
        XCTAssertFalse(service.hasPrefix("tools.graviton.manifold.license"))
    }

    override func tearDown() {
        for account in ["activationRecord", "storedLicenseKey"] { _ = delete(account) }
    }

    // MARK: A minimal scratch Keychain (generic passwords, the same class the app uses)

    private func write(_ value: String, _ account: String) -> Int32 {
        Self.write(service, value, account)
    }
    private func readString(_ account: String) -> String? {
        if case .found(let s) = Self.read(service, account) { return s }
        return nil
    }
    private func delete(_ account: String) -> Int32 { Self.delete(service, account) }

    static func write(_ service: String, _ value: String, _ account: String) -> Int32 {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        let s = SecItemUpdate(q as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if s == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = Data(value.utf8)
            return SecItemAdd(add as CFDictionary, nil)
        }
        return s
    }
    static func read(_ service: String, _ account: String) -> ItemRead {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return .absent }
        guard s == errSecSuccess, let d = out as? Data, let str = String(data: d, encoding: .utf8) else { return .failed(s) }
        return .found(str)
    }
    static func delete(_ service: String, _ account: String) -> Int32 {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        return SecItemDelete(q as CFDictionary)
    }

    private func io(failRecordRead: Int32? = nil, failRecordWrite: Int32? = nil, failKeyWrite: Int32? = nil,
                    failKeyDelete: Int32? = nil, writes: Locked<[String]>? = nil) -> LicenseItemIO {
        let service = self.service
        return LicenseItemIO(
            read: { account in
                if account == "activationRecord", let s = failRecordRead { return .failed(s) }
                return Self.read(service, account)
            },
            write: { value, account in
                writes?.value.append(account)
                if account == "activationRecord", let s = failRecordWrite { return s }
                if account == "storedLicenseKey", let s = failKeyWrite { return s }
                return Self.write(service, value, account)
            },
            delete: { account in
                writes?.value.append("delete:" + account)
                if account == "storedLicenseKey", let s = failKeyDelete { return s }
                return Self.delete(service, account)
            })
    }

    private func store(_ io: LicenseItemIO? = nil, legacy: Bool = true) -> LicenseRecordStore {
        LicenseRecordStore(items: io ?? self.io(), legacy: legacy ? defaults : nil,
                           queue: DispatchQueue(label: "test.keychain"))
    }

    private func record() -> [String: Any]? {
        guard let s = readString("activationRecord"), let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    private func record084() -> ActivationRecord084? { readString("activationRecord").flatMap(ActivationRecord084.decode) }

    /// An install as 0.8.4 left it: key, record, and (pre-P1) the plist copies.
    private func seed084Install(recordMachineId: String = "MID-1", plist: Bool = true) {
        XCTAssertEqual(write(KEY, "storedLicenseKey"), errSecSuccess)
        let rec = ActivationRecord084(activated: true, validated: true, email: "a@example.com",
                                      type: "standard", machineId: recordMachineId)
        XCTAssertEqual(write(String(data: try! JSONEncoder().encode(rec), encoding: .utf8)!, "activationRecord"), errSecSuccess)
        if plist {
            defaults.set(true, forKey: "license.activated")
            defaults.set(true, forKey: "license.validated")
            defaults.set("standard", forKey: "license.type")
            defaults.set("a@example.com", forKey: "license.email")
            defaults.set("MID-1", forKey: "license.machineId")
        }
    }

    // MARK: Store — read

    func testReadMapsTheRecordIdThenThePlistId() throws {
        seed084Install(recordMachineId: "MID-REC")
        XCTAssertEqual(try store().readSync()["licenseMachineId"], .string("MID-REC"), "the record's id first")

        _ = delete("activationRecord")
        defaults.set("MID-PLIST", forKey: "license.machineId")
        XCTAssertEqual(try store().readSync()["licenseMachineId"], .string("MID-PLIST"), "then the plist's")
        XCTAssertNil(try store(legacy: false).readSync()["licenseMachineId"], "the redirect never reads the plist")
    }

    func testReadPrefersTheClientIdOverTheLegacyOne() throws {
        XCTAssertEqual(write(#"{"licenseMachineId":"NEW","machineId":"OLD","activated":false,"validated":false,"email":"","type":"","v":2}"#,
                             "activationRecord"), errSecSuccess)
        XCTAssertEqual(try store().readSync()["licenseMachineId"], .string("NEW"))
    }

    func testFailedReadThrowsAndIsNotCached() throws {
        let failing = Locked(true)
        let service = self.service
        let s = store(LicenseItemIO(read: { failing.value && $0 == "activationRecord" ? .failed(-25293) : Self.read(service, $0) },
                                    write: { Self.write(service, $0, $1) }, delete: { Self.delete(service, $0) }))
        XCTAssertThrowsError(try s.readSync()) { XCTAssertEqual(($0 as? LicenseStoreError)?.status, -25293) }
        failing.value = false
        XCTAssertNoThrow(try s.readSync(), "the next read tries again")
    }

    // MARK: Store — write (rules 6 and 7)

    func testWriteRefusesWhenTheRecordCannotBeRead() {
        seed084Install()
        let before = readString("activationRecord")
        let writes = Locked<[String]>([])
        XCTAssertThrowsError(try store(io(failRecordRead: -25293, writes: writes)).writeSync(["licenseValidated": .bool(false)]))
        XCTAssertEqual(writes.value, [], "nothing written over what could not be read")
        XCTAssertEqual(readString("activationRecord"), before)
    }

    func testWriteRefusesWhenTheRecordDoesNotDecode() {
        XCTAssertEqual(write("not json", "activationRecord"), errSecSuccess)
        XCTAssertThrowsError(try store().writeSync(LicenseClient.clearedFields))
        XCTAssertEqual(readString("activationRecord"), "not json")
    }

    func testWriteMergesAndKeepsUnknownFields() throws {
        XCTAssertEqual(write(#"{"activated":true,"validated":true,"email":"a@example.com","type":"standard","machineId":"MID-1","v":1,"fromTheFuture":{"x":1}}"#,
                             "activationRecord"), errSecSuccess)
        try store().writeSync(["licenseLastValidatedAt": .number(1_790_812_800_000)])
        let r = record()
        XCTAssertEqual((r?["fromTheFuture"] as? [String: Any])?["x"] as? Int, 1, "a field nobody here knows survives")
        XCTAssertEqual(r?["machineId"] as? String, "MID-1")
        XCTAssertEqual(r?["licenseLastValidatedAt"] as? Int64, 1_790_812_800_000, "written as an integer")
    }

    func testEveryWrittenRecordDecodesIn084WithItsSpelling() throws {
        try store().writeSync(["licenseKey": .string(KEY), "licenseEmail": .string("a@example.com"),
                               "licenseType": .string("Beta"), "licenseActivated": .bool(true),
                               "licenseValidated": .bool(true), "licenseMachineId": .string("HW-ID"),
                               "licenseActivationPending": .bool(true)])
        let old = try XCTUnwrap(record084(), "0.8.4 must decode it, or it overwrites it")
        XCTAssertEqual(old.activated, true)
        XCTAssertEqual(old.email, "a@example.com")
        XCTAssertEqual(old.type, "beta", "LicenseType(rawValue:).rawValue, so 0.8.4 sees no change to rewrite")
        XCTAssertEqual(old.machineId, "HW-ID")
        XCTAssertEqual(old.v, 2)
        XCTAssertEqual(LicenseRecordStore.legacyTypeSpelling("trial"), "unknown")
    }

    func testAPatchOnAnEmptyRecordStillWritesTheOldFields() throws {
        try store().writeSync(["licenseMachineId": .string("HW-ID"), "licenseMachineIdSource": .string("ioreg")])
        let old = try XCTUnwrap(record084())
        XCTAssertEqual(old.activated, false)
        XCTAssertEqual(old.machineId, "HW-ID")
    }

    func testTheKeyIsWrittenAfterTheRecordAndDeletedOnNull() throws {
        let writes = Locked<[String]>([])
        let s = store(io(writes: writes))
        try s.writeSync(["licenseKey": .string(KEY), "licenseActivated": .bool(true)])
        XCTAssertEqual(writes.value, ["activationRecord", "storedLicenseKey"])
        XCTAssertEqual(readString("storedLicenseKey"), KEY)
        XCTAssertNil(record()?["licenseKey"], "the key never goes into the record")
        writes.value = []
        try s.writeSync(["licenseKey": .null])
        XCTAssertEqual(writes.value, ["delete:storedLicenseKey", "activationRecord"], "removing: the key first")
        XCTAssertNil(readString("storedLicenseKey"))
    }

    /// The live test, 2026-10-28: a key item another app owned refused its delete (-25244). With the
    /// record written first, deactivation left a cleared record beside a stored key and said nothing
    /// had changed. The key now goes first, so a refused delete really changes nothing.
    func testARefusedKeyDeleteChangesNothing() throws {
        seed084Install()
        let s = store()
        try s.convertLegacyActivationIfNeeded(verify: verify)
        let before = readString("activationRecord")
        let writes = Locked<[String]>([])
        XCTAssertThrowsError(try store(io(failKeyDelete: -25244, writes: writes)).writeSync(LicenseClient.clearedFields)) {
            XCTAssertEqual(($0 as? LicenseStoreError)?.step, LicenseRecordStore.deleteKeyStep)
        }
        XCTAssertEqual(writes.value, ["delete:storedLicenseKey"], "the record is not written")
        XCTAssertEqual(readString("activationRecord"), before)
        XCTAssertEqual(readString("storedLicenseKey"), KEY)
    }

    func testARecordWriteFailureAfterTheKeyDeleteKeepsTheMachineId() throws {
        seed084Install()
        try store().convertLegacyActivationIfNeeded(verify: verify)
        XCTAssertThrowsError(try store(io(failRecordWrite: -25299)).writeSync(LicenseClient.clearedFields))
        XCTAssertNil(readString("storedLicenseKey"), "the key is gone, so the install reads as unlicensed")
        XCTAssertEqual(record()?["licenseMachineId"] as? String, "MID-1", "and the machine ID is kept")
    }

    func testARecordWriteFailureLeavesTheKeyAlone() {
        let writes = Locked<[String]>([])
        XCTAssertThrowsError(try store(io(failRecordWrite: -25299, writes: writes)).writeSync(["licenseKey": .string(KEY)]))
        XCTAssertEqual(writes.value, ["activationRecord"])
        XCTAssertNil(readString("storedLicenseKey"))
    }

    func testDeactivationKeepsTheMachineIdAndClearsTheEmail() throws {
        seed084Install()
        let s = store()
        try s.convertLegacyActivationIfNeeded(verify: verify)
        try s.writeSync(LicenseClient.clearedFields)
        XCTAssertNil(readString("storedLicenseKey"))
        let old = try XCTUnwrap(record084())
        XCTAssertEqual(old.activated, false)
        XCTAssertEqual(old.email, "")
        XCTAssertEqual(old.type, "")
        XCTAssertEqual(old.machineId, "MID-1", "kept: it identifies the install")
        XCTAssertEqual(record()?["licenseMachineId"] as? String, "MID-1")
    }

    // MARK: The one-time conversion

    func testA084InstallIsConvertedOnceAndKeepsItsId() throws {
        seed084Install(recordMachineId: "MID-1")
        let before = try XCTUnwrap(record084())
        let s = store()
        XCTAssertTrue(try s.convertLegacyActivationIfNeeded(verify: verify))
        let r = try XCTUnwrap(record())
        XCTAssertEqual(r["licenseActivated"] as? Bool, true)
        XCTAssertEqual(r["licenseValidated"] as? Bool, true)
        XCTAssertEqual(r["licenseServerConfirmed"] as? Bool, true)
        XCTAssertEqual(r["licenseActivationPending"] as? Bool, false)
        XCTAssertEqual(r["licenseEmail"] as? String, "a@example.com")
        XCTAssertEqual(r["licenseType"] as? String, "standard")
        XCTAssertEqual(r["licenseMachineId"] as? String, "MID-1")
        XCTAssertNil(r["licenseLastValidatedAt"], "so the first launch validates")
        XCTAssertNil(r["licenseMachineIdSource"], "no source invented for an existing ID")
        let after = try XCTUnwrap(record084())
        XCTAssertEqual([after.activated, after.validated], [before.activated, before.validated])
        XCTAssertEqual([after.email, after.type, after.machineId], [before.email, before.type, before.machineId],
                       "nothing old changed (rule 2)")
        XCTAssertEqual(readString("storedLicenseKey"), KEY, "the key is untouched")
        XCTAssertFalse(try s.convertLegacyActivationIfNeeded(verify: verify), "runs once")
    }

    func testConversionTakesThePlistIdWhenTheRecordHasNone() throws {
        seed084Install(recordMachineId: "")
        try store().convertLegacyActivationIfNeeded(verify: verify)
        XCTAssertEqual(record()?["licenseMachineId"] as? String, "MID-1")
    }

    func testNoConversionWithoutAVerifyingKey() throws {
        XCTAssertFalse(try store().convertLegacyActivationIfNeeded(verify: verify), "no key")
        XCTAssertEqual(write("MNFL-garbage.sig", "storedLicenseKey"), errSecSuccess)
        XCTAssertFalse(try store().convertLegacyActivationIfNeeded(verify: verify), "a key that fails offline")
        XCTAssertNil(record())
    }

    func testAConverted084InstallReactivatesWithItsOriginalId() async throws {
        seed084Install(recordMachineId: "6F1C2B4A-0D3E-4C5F-9A8B-7E6D5C4B3A21", plist: false)
        let s = store()
        try s.convertLegacyActivationIfNeeded(verify: verify)
        let sent = Locked<[LicenseValue?]>([])
        let hardwareReads = Locked(0)
        let c = try LicenseClient(
            product: "manifold", keyPrefix: "MNFL-", publicKey: signer.publicKey.rawRepresentation, appVersion: "0.9.0",
            storage: s,
            transport: { request in
                sent.value.append(LicenseValue.parseObject(request.httpBody!)?["machineId"])
                return (Data(#"{"ok":true,"alreadyRegistered":true}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            machineId: { hardwareReads.value += 1; return MachineIdResult(id: "HARDWARE", source: "ioreg") })
        try await c.deactivate()
        _ = try await c.activate(KEY)
        XCTAssertEqual(sent.value, [.string("6F1C2B4A-0D3E-4C5F-9A8B-7E6D5C4B3A21")], "the ID 0.8.4 registered")
        XCTAssertEqual(hardwareReads.value, 0)
        let status = try await c.status()
        XCTAssertEqual(status.state, "active")
    }

    // MARK: P1 — the move out of the plist

    func testLicensedInstallLosesOnlyTheTwoPlistKeys() throws {
        seed084Install()
        let out = LicenseRecordSync.run(defaults: defaults, store: store())
        XCTAssertFalse(out.keychainFailed)
        XCTAssertEqual(Set(out.removedKeys), ["license.email", "license.machineId"])
        XCTAssertNil(defaults.object(forKey: "license.email"))
        XCTAssertNil(defaults.object(forKey: "license.machineId"))
        XCTAssertEqual(readString("storedLicenseKey"), KEY)
        XCTAssertEqual(defaults.object(forKey: "license.activated") as? Bool, true)
        XCTAssertEqual(record084()?.machineId, "MID-1")
        XCTAssertFalse(out.log.joined().contains("a@example.com"), "the log names keys, never values")
        XCTAssertFalse(out.log.joined().contains("MID-1"))
    }

    func testSecondRunIsANoOp() {
        seed084Install()
        _ = LicenseRecordSync.run(defaults: defaults, store: store())
        let writes = Locked<[String]>([])
        let out = LicenseRecordSync.run(defaults: defaults, store: store(io(writes: writes)))
        XCTAssertEqual(writes.value, [])
        XCTAssertTrue(out.removedKeys.isEmpty)
    }

    func testFailedReadLeavesThePlistExactlyAsItWas() {
        seed084Install()
        let before = NSDictionary(dictionary: defaults.values)
        let writes = Locked<[String]>([])
        let out = LicenseRecordSync.run(defaults: defaults, store: store(io(failRecordRead: -25293, writes: writes)))
        XCTAssertTrue(out.keychainFailed)
        XCTAssertEqual(writes.value, [])
        XCTAssertEqual(Set(out.keptKeys), ["license.email", "license.machineId"])
        XCTAssertEqual(before, NSDictionary(dictionary: defaults.values))
        XCTAssertTrue(out.log.contains { $0.contains("left in place") })
    }

    func testFailedWriteLeavesThePlist() {
        defaults.set("MID-1", forKey: "license.machineId")
        let out = LicenseRecordSync.run(defaults: defaults, store: store(io(failRecordWrite: -25299)))
        XCTAssertTrue(out.keychainFailed)
        XCTAssertEqual(defaults.string(forKey: "license.machineId"), "MID-1")
    }

    func testMismatchedMachineIdIsKept() {
        seed084Install(recordMachineId: "MID-KEYCHAIN")
        let out = LicenseRecordSync.run(defaults: defaults, store: store())
        XCTAssertEqual(record084()?.machineId, "MID-KEYCHAIN", "the Keychain's id wins")
        XCTAssertEqual(defaults.string(forKey: "license.machineId"), "MID-1")
        XCTAssertNil(defaults.object(forKey: "license.email"))
        XCTAssertEqual(out.keptKeys, ["license.machineId"])
    }

    func testTrialInstallWithALegacyIdKeepsItInTheKeychain() throws {
        defaults.set("MID-TRIAL", forKey: "license.machineId")
        _ = LicenseRecordSync.run(defaults: defaults, store: store())
        XCTAssertNil(defaults.object(forKey: "license.machineId"))
        XCTAssertEqual(record084()?.activated, false)
        XCTAssertEqual(record084()?.machineId, "MID-TRIAL")
        XCTAssertEqual(try store(legacy: false).readSync()["licenseMachineId"], .string("MID-TRIAL"),
                       "and the client will send it")
    }

    func testCleanUnlicensedInstallTouchesNothing() {
        let writes = Locked<[String]>([])
        let reads = Locked(0)
        let service = self.service
        let s = store(LicenseItemIO(read: { reads.value += 1; return Self.read(service, $0) },
                                    write: { writes.value.append($1); return Self.write(service, $0, $1) },
                                    delete: { Self.delete(service, $0) }))
        _ = LicenseRecordSync.run(defaults: defaults, store: s)
        XCTAssertEqual(reads.value, 0, "no Keychain round trip for a clean, unlicensed install")
        XCTAssertEqual(writes.value, [])
    }

    func testEmptyLegacyValuesAreRemovedOnceTheRecordReadsBack() {
        seed084Install()
        defaults.set("", forKey: "license.email")
        _ = LicenseRecordSync.run(defaults: defaults, store: store())
        XCTAssertNil(defaults.object(forKey: "license.email"))
    }

    func testRecordRoundTripsAndToleratesUnknownFields() {
        let rec = ActivationRecord(activated: true, validated: false, email: "e", type: "beta", machineId: "m")
        XCTAssertEqual(ActivationRecord.decode(rec.encoded()!), rec)
        let newer = #"{"activated":true,"validated":true,"email":"e","type":"beta","machineId":"m","v":2,"x":1}"#
        XCTAssertEqual(ActivationRecord.decode(newer)?.machineId, "m")
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
