import XCTest
import CryptoKit
@testable import LicenseClient

/// The port of Graviton-Releases `tests/license.test.js`. Each test carries its number there (T1–T73,
/// in file order) so the parity table can be checked line for line. The Windows and Linux machine-ID
/// tests (T54–T58, T62, T63) have no macOS equivalent and are not ported.
///
/// As in the JS: the network is a scripted transport, the clock is a variable, and the keypair is
/// generated here, so keys are signed the way the worker signs them and no real key material is
/// involved. Nothing here touches the Keychain or the network.

// MARK: - Fixtures

let DAY: Double = 24 * 60 * 60 * 1000
let PREFIX = "TEST-"
let T0: Double = 1_790_812_800_000   // Date.UTC(2026, 9, 1)

let signingKey = Curve25519.Signing.PrivateKey()
let PUBLIC_RAW = signingKey.publicKey.rawRepresentation

func base64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// Mirrors the worker's generateLicenseKey: prefix + b64url(JSON) + '.' + b64url(sig).
func makeKey(_ fields: [String: Any] = [:], key: Curve25519.Signing.PrivateKey = signingKey,
             prefix: String = PREFIX) -> String {
    var payload: [String: Any] = ["email": "customer@example.test", "name": "", "product": "Test",
                                  "productSlug": "test", "licenseType": "standard", "orderId": "",
                                  "issued": T0, "expires": NSNull()]
    payload.merge(fields) { $1 }
    let bytes = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let sig = try! key.signature(for: bytes)
    return prefix + base64url(bytes) + "." + base64url(sig)
}

let KEY = makeKey()

/// A machine-ID provider that answers as getMachineId() does on a Mac.
func hw(_ id: String?) -> LicenseClient.MachineIdProvider { { MachineIdResult(id: id, source: "ioreg") } }

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

final class MemoryStorage: LicenseStorage, @unchecked Sendable {
    private let box: Locked<LicenseFields>
    init(_ initial: LicenseFields = [:]) { box = Locked(initial) }
    var data: LicenseFields { box.value }
    func read() async throws -> LicenseFields { box.value }
    func write(_ patch: LicenseFields) async throws { box.value.merge(patch) { $1 } }
}

struct DiskError: Error {}

final class ThrowingStorage: LicenseStorage, @unchecked Sendable {
    func read() async throws -> LicenseFields { throw DiskError() }
    func write(_ patch: LicenseFields) async throws {}
}

enum Responder {
    case reply(String, Int)        // a JSON body and a status
    case offline
    case html

    static func json(_ object: [String: Any], _ status: Int = 200) -> Responder {
        .reply(String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!, status)
    }
}

/// A transport that answers from a queue of responders (the last repeats) and records every request.
final class ScriptedTransport: @unchecked Sendable {
    struct Call { let url: String; let body: LicenseFields }
    private let state: Locked<(responders: [Responder], calls: [Call])>
    init(_ responders: Responder...) { state = Locked((responders, [])) }
    var calls: [Call] { state.value.calls }

    var transport: LicenseClient.Transport {
        { [state] request in
            let body = LicenseValue.parseObject(request.httpBody ?? Data()) ?? [:]
            var s = state.value
            s.calls.append(Call(url: request.url!.absoluteString, body: body))
            guard let next = s.responders.first else { state.value = s; throw URLError(.badServerResponse) }
            if s.responders.count > 1 { s.responders.removeFirst() }
            state.value = s
            switch next {
            case .offline:
                throw URLError(.notConnectedToInternet)
            case .html:
                return (Data("<html>portal</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .reply(let body, let status):
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }
}

let offline = Responder.offline
let htmlPage = Responder.html
func reply(_ object: [String: Any], _ status: Int = 200) -> Responder { .json(object, status) }

final class Clock: @unchecked Sendable {
    let t: Locked<Double>
    init(_ t: Double = T0) { self.t = Locked(t) }
}

struct Harness {
    let c: LicenseClient
    let storage: MemoryStorage
    let fetch: ScriptedTransport
    let clock: Clock
}

func client(storage: MemoryStorage = MemoryStorage(), fetch: ScriptedTransport = ScriptedTransport(),
            clock: Clock = Clock(), acceptOfflineActivation: Bool = true,
            machineId: @escaping LicenseClient.MachineIdProvider = hw(String(repeating: "m", count: 32)),
            platform: String = "darwin") -> Harness {
    let c = try! LicenseClient(product: "test", keyPrefix: PREFIX, publicKey: PUBLIC_RAW, appVersion: "1.2.3",
                               storage: storage, transport: fetch.transport,
                               acceptOfflineActivation: acceptOfflineActivation,
                               now: { clock.t.value }, machineId: machineId, platform: platform)
    return Harness(c: c, storage: storage, fetch: fetch, clock: clock)
}

/// Storage as left by a successful activation at `at`.
func activatedAt(_ at: Double?, _ extra: LicenseFields = [:]) -> MemoryStorage {
    var f: LicenseFields = [
        "licenseKey": .string(KEY), "licenseEmail": .string("customer@example.test"),
        "licenseType": .string("standard"), "licenseActivated": .bool(true),
        "licenseValidated": .bool(true), "licenseServerConfirmed": .bool(true),
    ]
    if let at { f["licenseLastValidatedAt"] = .number(at) }
    f.merge(extra) { $1 }
    return MemoryStorage(f)
}

func message(_ s: LicenseStatus) -> String? {
    if case .locked(_, let m) = s { return m }
    return nil
}
func reason(_ s: LicenseStatus) -> LockReason? {
    if case .locked(let r, _) = s { return r }
    return nil
}
func isPending(_ s: LicenseStatus) -> Bool {
    if case .active(let a) = s { return a.pending }
    return false
}
func refusal(_ r: ActivateResult) -> (error: String, message: String)? {
    if case .refused(let e, let m) = r { return (e, m) }
    return nil
}
func isOk(_ r: ActivateResult) -> Bool {
    if case .activated = r { return true }
    return false
}

let M32 = String(repeating: "m", count: 32)
let activateBody: LicenseFields = ["key": .string(KEY), "machineId": .string(M32), "version": .string("1.2.3"),
                                   "platform": .string("darwin")]

final class LicenseClientTests: XCTestCase {

    // MARK: Schedule: the 7-day interval

    func testT01IntervalIsSevenDays() {
        XCTAssertEqual(LicenseClient.validationIntervalMs, 7 * DAY)
    }

    func testT02InsideWindowNoNetwork() async {
        let fetch = ScriptedTransport()
        for elapsed in [0, 1, DAY, 3 * DAY, 7 * DAY - 1] {
            let h = client(storage: activatedAt(T0), fetch: fetch, clock: Clock(T0 + elapsed))
            let r = await h.c.checkIfDue()
            XCTAssertFalse(r.checked, "elapsed \(elapsed)")
            XCTAssertEqual(r.status.state, "active")
        }
        XCTAssertEqual(fetch.calls.count, 0)
    }

    func testT03DueAtSevenDaysAndRestarts() async {
        let fetch = ScriptedTransport(reply(["valid": true]))
        let clock = Clock(T0 + 7 * DAY)
        let h = client(storage: activatedAt(T0), fetch: fetch, clock: clock)
        let r = await h.c.checkIfDue()
        XCTAssertTrue(r.checked)
        XCTAssertEqual(r.outcome, .valid)
        XCTAssertEqual(r.status.state, "active")
        XCTAssertEqual(h.storage.data["licenseLastValidatedAt"], .number(T0 + 7 * DAY))
        clock.t.value += 6 * DAY
        let second = await h.c.checkIfDue()
        XCTAssertFalse(second.checked)
        XCTAssertEqual(fetch.calls.count, 1)
    }

    func testT04RepeatedLaunchesNeverValidate() async {
        let fetch = ScriptedTransport(reply(["valid": true]))
        let clock = Clock(T0)
        let h = client(storage: activatedAt(T0), fetch: fetch, clock: clock)
        for _ in 0..<20 {
            clock.t.value += 6 * 60 * 60 * 1000
            _ = await h.c.checkIfDue()
        }
        XCTAssertEqual(fetch.calls.count, 0)
    }

    func testT05NoLastValidatedIsDue() async {
        let h = client(storage: activatedAt(nil), fetch: ScriptedTransport(reply(["valid": true])))
        let r = await h.c.checkIfDue()
        XCTAssertTrue(r.checked)
        XCTAssertEqual(h.storage.data["licenseLastValidatedAt"], .number(T0))
    }

    func testT06ClockBackIsDue() async {
        let h = client(storage: activatedAt(T0), fetch: ScriptedTransport(reply(["valid": true])), clock: Clock(T0 - DAY))
        let checked = await h.c.checkIfDue().checked
        XCTAssertTrue(checked)
    }

    func testT07ValidateBodyKeyAndVersionOnly() async {
        let fetch = ScriptedTransport(reply(["valid": true]))
        let h = client(storage: activatedAt(T0 - 8 * DAY), fetch: fetch)
        _ = await h.c.checkIfDue()
        XCTAssertEqual(fetch.calls[0].url, "https://license.graviton.tools/test/validate")
        XCTAssertEqual(fetch.calls[0].body, ["key": .string(KEY), "version": .string("1.2.3")])
    }

    // MARK: Schedule: server unreachable

    func testT08UnreachableVariantsWriteNothing() async {
        let failures: [Responder] = [offline, htmlPage, reply(["error": "boom"], 502), .reply("null", 200),
                                     reply(["valid": false, "error": "missing_key"], 400),
                                     reply(["valid": false, "error": "expired"]),
                                     reply(["valid": false, "error": "something_new"])]
        for (i, failure) in failures.enumerated() {
            let fetch = ScriptedTransport(failure, reply(["valid": true]))
            let clock = Clock(T0 + 8 * DAY)
            let storage = activatedAt(T0)
            let h = client(storage: storage, fetch: fetch, clock: clock)
            let first = await h.c.checkIfDue()
            XCTAssertEqual(first.status.state, "active", "failure \(i)")
            XCTAssertEqual(first.outcome, .unreachable, "failure \(i)")
            XCTAssertEqual(storage.data["licenseLastValidatedAt"], .number(T0), "a failure must not move the interval")
            XCTAssertEqual(storage.data["licenseValidated"], .bool(true))
            clock.t.value += 60 * 1000
            let second = await h.c.checkIfDue()
            XCTAssertTrue(second.checked, "retried on the next launch, not 7 days later")
            XCTAssertEqual(second.outcome, .valid)
            XCTAssertEqual(storage.data["licenseLastValidatedAt"], .number(clock.t.value))
        }
    }

    func testT09NoGraceExpiryForAYear() async {
        let clock = Clock(T0)
        let h = client(storage: activatedAt(T0), fetch: ScriptedTransport(offline), clock: clock)
        for day in stride(from: 8.0, through: 365, by: 1) {
            clock.t.value = T0 + day * DAY
            let state = await h.c.checkIfDue().status.state
            XCTAssertEqual(state, "active")
        }
    }

    func testT10CheckNeverThrowsOnStorageError() async {
        let c = try! LicenseClient(product: "test", keyPrefix: PREFIX, publicKey: PUBLIC_RAW, appVersion: "1.2.3",
                                   storage: ThrowingStorage(), transport: ScriptedTransport().transport,
                                   machineId: hw(M32))
        let r = await c.checkIfDue()
        XCTAssertFalse(r.checked)
        XCTAssertEqual(r.outcome, .error)
    }

    func testT11ConcurrentChecksShareOneRequest() async {
        let fetch = ScriptedTransport(reply(["valid": true]))
        let h = client(storage: activatedAt(T0 - 8 * DAY), fetch: fetch)
        async let a = h.c.checkIfDue()
        async let b = h.c.checkIfDue()
        async let c = h.c.checkIfDue()
        _ = await (a, b, c)
        XCTAssertEqual(fetch.calls.count, 1)
    }

    // MARK: Schedule: revoked

    func testT12RevokedLocks() async throws {
        let fetch = ScriptedTransport(reply(["valid": false, "error": "revoked", "revokedAt": T0]))
        let h = client(storage: activatedAt(T0 - 8 * DAY), fetch: fetch)
        let r = await h.c.checkIfDue()
        XCTAssertEqual(r.status.state, "locked")
        XCTAssertEqual(r.outcome, .revoked)
        XCTAssertEqual(message(r.status), "This license is no longer valid. Contact support@graviton.tools.")
        XCTAssertEqual(message(r.status), LicenseMessages.locked)
        XCTAssertTrue(r.changed)
        let persisted = try await h.c.status().state
        XCTAssertEqual(persisted, "locked", "persisted, not just returned")
        XCTAssertEqual(h.storage.data["licenseKey"], .string(KEY))
        XCTAssertEqual(h.storage.data["licenseActivated"], .bool(true))
    }

    func testT13InvalidKeyNotLocked() async {
        let fetch = ScriptedTransport(reply(["valid": false, "error": "invalid_key"]), reply(["valid": true]))
        let clock = Clock(T0 + 8 * DAY)
        let storage = activatedAt(T0)
        let h = client(storage: storage, fetch: fetch, clock: clock)
        let first = await h.c.checkIfDue()
        XCTAssertEqual(first.status.state, "active")
        XCTAssertEqual(first.outcome, .unreachable)
        XCTAssertFalse(first.changed)
        XCTAssertEqual(storage.data["licenseValidated"], .bool(true), "nothing written")
        XCTAssertEqual(storage.data["licenseLastValidatedAt"], .number(T0), "interval not moved")
        clock.t.value += 60 * 1000
        let second = await h.c.checkIfDue()
        XCTAssertTrue(second.checked)
        XCTAssertEqual(second.outcome, .valid)
        XCTAssertEqual(storage.data["licenseLastValidatedAt"], .number(clock.t.value))
    }

    func testT14InvalidKeyForAYearNeverLocks() async {
        let clock = Clock(T0)
        let h = client(storage: activatedAt(T0), fetch: ScriptedTransport(reply(["valid": false, "error": "invalid_key"])), clock: clock)
        for day in stride(from: 8.0, through: 365, by: 1) {
            clock.t.value = T0 + day * DAY
            let state = await h.c.checkIfDue().status.state
            XCTAssertEqual(state, "active")
        }
    }

    func testT15RawValidateInvalidKeyUnreachable() async {
        let h = client(fetch: ScriptedTransport(reply(["valid": false, "error": "invalid_key"])))
        let outcome = await h.c.validate(KEY)
        XCTAssertEqual(outcome, .unreachable)
    }

    func testT16LockedStaysLockedOffline() async {
        let clock = Clock(T0 + 8 * DAY)
        let h = client(storage: activatedAt(T0), fetch: ScriptedTransport(reply(["valid": false, "error": "revoked"]), offline), clock: clock)
        _ = await h.c.checkIfDue()
        clock.t.value += DAY
        let r = await h.c.checkIfDue()
        XCTAssertTrue(r.checked)
        XCTAssertEqual(r.status.state, "locked")
    }

    func testT17LockedRecheckedAndRecovers() async {
        let clock = Clock(T0 + 8 * DAY)
        let h = client(storage: activatedAt(T0), fetch: ScriptedTransport(reply(["valid": false, "error": "revoked"]), reply(["valid": true])), clock: clock)
        _ = await h.c.checkIfDue()
        clock.t.value += 60 * 1000
        let r = await h.c.checkIfDue()
        XCTAssertEqual(r.status.state, "active")
        XCTAssertTrue(r.changed)
    }

    func testT18LockedDueInsideWindow() async {
        let h = client(storage: activatedAt(T0, ["licenseValidated": .bool(false)]),
                       fetch: ScriptedTransport(reply(["valid": true])), clock: Clock(T0 + DAY))
        let r = await h.c.checkIfDue()
        XCTAssertTrue(r.checked)
        XCTAssertEqual(r.status.state, "active")
    }

    func testT19ValidatedFalseReadsLocked() async throws {
        let h = client(storage: activatedAt(T0, ["licenseValidated": .bool(false)]))
        let state = try await h.c.status().state
        XCTAssertEqual(state, "locked")
    }

    func testT20ExpiredLockedOfflineNoRequest() async {
        let fetch = ScriptedTransport()
        let storage = activatedAt(T0, ["licenseKey": .string(makeKey(["expires": T0 + DAY]))])
        let h = client(storage: storage, fetch: fetch, clock: Clock(T0 + 30 * DAY))
        let r = await h.c.checkIfDue()
        XCTAssertEqual(r.status.state, "locked")
        XCTAssertEqual(reason(r.status), .expired)
        XCTAssertEqual(message(r.status), LicenseMessages.expired)
        XCTAssertEqual(fetch.calls.count, 0)
    }

    // MARK: Activation

    func testT21ActivateBodyAndStores() async throws {
        let fetch = ScriptedTransport(reply(["ok": true, "alreadyRegistered": false, "machinesUsed": 1, "machineLimit": 4]))
        let h = client(fetch: fetch)
        let r = try await h.c.activate("  \(KEY)\n")
        XCTAssertEqual(r, .activated(email: "customer@example.test", licenseType: "standard", serverConfirmed: true, pending: false))
        XCTAssertEqual(fetch.calls[0].url, "https://license.graviton.tools/test/activate")
        XCTAssertEqual(fetch.calls[0].body, activateBody)
        XCTAssertEqual(h.storage.data["licenseKey"], .string(KEY), "stored trimmed")
        XCTAssertEqual(h.storage.data["licenseLastValidatedAt"], .number(T0))
        let state = try await h.c.status().state
        XCTAssertEqual(state, "active")
    }

    func testT22RefusalsNotStored() async throws {
        for error in ["revoked", "invalid_key", "max_machines", "missing_fields"] {
            let h = client(fetch: ScriptedTransport(reply(["ok": false, "error": error, "machineLimit": 4])))
            let r = try await h.c.activate(KEY)
            XCTAssertEqual(refusal(r)?.error, error)
            XCTAssertNil(h.storage.data["licenseKey"])
        }
    }

    func testT23MaxMachinesRealNumbers() async throws {
        let h = client(fetch: ScriptedTransport(reply(["ok": false, "error": "max_machines", "machinesUsed": 4, "machineLimit": 4]),
                                                reply(["ok": false, "error": "max_machines", "machinesUsed": 7, "machineLimit": 6])))
        let r = try await h.c.activate(KEY)
        XCTAssertEqual(refusal(r)?.error, "max_machines")
        XCTAssertEqual(refusal(r)?.message, "This license is already active on 4 of 4 machines. Contact support@graviton.tools to free one.")
        let second = try await h.c.activate(KEY)
        XCTAssertEqual(refusal(second)?.message,
                       "This license is already active on 7 of 6 machines. Contact support@graviton.tools to free one.",
                       "whatever the worker reports, not a hardcoded 4")
        XCTAssertNil(h.storage.data["licenseKey"])
    }

    func testT24MaxMachinesFallbackWording() async throws {
        let bodies: [[String: Any]] = [[:], ["machinesUsed": 4], ["machinesUsed": "4", "machineLimit": 4],
                                       ["machinesUsed": -1, "machineLimit": 4],
                                       ["machinesUsed": true, "machineLimit": 4]]   // a boolean is not a count
        for body in bodies {
            var object: [String: Any] = ["ok": false, "error": "max_machines"]
            object.merge(body) { $1 }
            let h = client(fetch: ScriptedTransport(reply(object)))
            let r = try await h.c.activate(KEY)
            XCTAssertEqual(refusal(r)?.message, LicenseMessages.maxMachines)
        }
        XCTAssertNil(LicenseMessages.maxMachines.rangeOfCharacter(from: .decimalDigits))
    }

    func testT25FourXXRejected() async throws {
        for (error, status) in [("missing_fields", 400), ("invalid_request", 400), ("rate_limited", 429)] {
            let h = client(fetch: ScriptedTransport(reply(["ok": false, "error": error], status)))
            let r = try await h.c.activate(KEY)
            XCTAssertEqual(r, .refused(error: error, message: "The license server rejected this request (\(error))."))
            XCTAssertNil(h.storage.data["licenseKey"])
            XCTAssertNil(h.storage.data["licenseActivationPending"], "not accepted as offline either")
        }
        let h = client(fetch: ScriptedTransport(reply(["ok": false, "error": "missing_fields"])))
        let r = try await h.c.activate(KEY)
        XCTAssertEqual(refusal(r)?.message, "Activation failed (missing_fields). Contact support@graviton.tools.")
    }

    func testT26FourXXNoErrorIsUnreachable() async throws {
        let h = client(fetch: ScriptedTransport(reply(["ok": false], 404)))
        let r = try await h.c.activate(KEY)
        XCTAssertEqual(r, .activated(email: "customer@example.test", licenseType: "standard", serverConfirmed: false, pending: true))
        XCTAssertEqual(h.storage.data["licenseActivationPending"], .bool(true))
    }

    func testT27PlatformSentOrOmitted() async throws {
        for platform in ["darwin", "win32", "linux"] {
            let fetch = ScriptedTransport(reply(["ok": true]))
            _ = try await client(fetch: fetch, platform: platform).c.activate(KEY)
            XCTAssertEqual(fetch.calls[0].body["platform"], .string(platform))
        }
        for platform in ["freebsd", "aix", ""] {
            let fetch = ScriptedTransport(reply(["ok": true]))
            _ = try await client(fetch: fetch, platform: platform).c.activate(KEY)
            XCTAssertNil(fetch.calls[0].body["platform"], "omitted for \(platform)")
        }
    }

    func testT28FailedKeyNeverSent() async throws {
        let fetch = ScriptedTransport()
        let h = client(fetch: fetch)
        let other = Curve25519.Signing.PrivateKey()
        for bad in ["nonsense", "TEST-abc", makeKey(key: other), makeKey(prefix: "GSHR-")] {
            let r = try await h.c.activate(bad)
            XCTAssertFalse(isOk(r))
            XCTAssertEqual(r, .refused(error: "invalid_key", message: "This license key was not recognized. Check it and try again."))
        }
        XCTAssertEqual(fetch.calls.count, 0)
    }

    // MARK: Offline activation: pending until the server registers the machine

    let maxMachinesBody: [String: Any] = ["ok": false, "error": "max_machines", "machinesUsed": 4, "machineLimit": 4]

    func testT29OfflineActivationPending() async throws {
        let h = client(fetch: ScriptedTransport(offline))
        let r = try await h.c.activate(KEY)
        XCTAssertEqual(r, .activated(email: "customer@example.test", licenseType: "standard", serverConfirmed: false, pending: true))
        XCTAssertEqual(h.storage.data["licenseActivationPending"], .bool(true))
        XCTAssertEqual(h.storage.data["licenseValidated"], .bool(false))
        XCTAssertEqual(h.storage.data["licenseLastValidatedAt"], .null)
        XCTAssertEqual(h.storage.data["licenseMachineId"], .string(M32))
        let s = try await h.c.status()
        XCTAssertEqual(s.state, "active")
        XCTAssertTrue(isPending(s))
        if case .active(let a) = s { XCTAssertFalse(a.serverConfirmed) }
    }

    func testT30PendingDoesNotInheritValidation() async throws {
        let storage = activatedAt(T0)
        let h = client(storage: storage, fetch: ScriptedTransport(offline))
        _ = try await h.c.activate(makeKey(["email": "second@example.test"]))
        XCTAssertEqual(storage.data["licenseValidated"], .bool(false))
        XCTAssertEqual(storage.data["licenseLastValidatedAt"], .null)
    }

    func testT31PendingRegistersNextLaunch() async throws {
        let fetch = ScriptedTransport(offline, reply(["ok": true, "alreadyRegistered": false, "machinesUsed": 2, "machineLimit": 4]))
        let clock = Clock(T0)
        let h = client(fetch: fetch, clock: clock)
        _ = try await h.c.activate(KEY)
        clock.t.value += 60 * 1000
        let r = await h.c.checkIfDue()
        XCTAssertTrue(r.checked)
        XCTAssertEqual(r.outcome, .registered)
        XCTAssertEqual(r.status.state, "active")
        XCTAssertFalse(isPending(r.status))
        XCTAssertEqual(fetch.calls[1].url, "https://license.graviton.tools/test/activate")
        XCTAssertEqual(fetch.calls[1].body, activateBody)
        XCTAssertEqual(h.storage.data["licenseActivationPending"], .bool(false))
        XCTAssertEqual(h.storage.data["licenseValidated"], .bool(true))
        XCTAssertEqual(h.storage.data["licenseServerConfirmed"], .bool(true))
        XCTAssertEqual(h.storage.data["licenseLastValidatedAt"], .number(clock.t.value))
        clock.t.value += DAY
        let next = await h.c.checkIfDue()
        XCTAssertFalse(next.checked)
        XCTAssertEqual(fetch.calls.count, 2)
    }

    func testT32PendingAlreadyRegisteredCounts() async throws {
        let h = client(fetch: ScriptedTransport(offline, reply(["alreadyRegistered": true])))
        _ = try await h.c.activate(KEY)
        let outcome = await h.c.checkIfDue().outcome
        XCTAssertEqual(outcome, .registered)
        XCTAssertEqual(h.storage.data["licenseActivationPending"], .bool(false))
    }

    func testT33PendingRetriesEveryLaunch() async throws {
        let fetch = ScriptedTransport(offline, offline, htmlPage, reply(["error": "boom"], 502),
                                      reply(["ok": false, "error": "invalid_key"]),
                                      reply(["ok": false, "error": "missing_fields"], 400), reply(["ok": true]))
        let clock = Clock(T0)
        let h = client(fetch: fetch, clock: clock)
        _ = try await h.c.activate(KEY)
        for launch in 1...5 {
            clock.t.value += 60 * 1000
            let r = await h.c.checkIfDue()
            XCTAssertTrue(r.checked, "launch \(launch) asked the server")
            XCTAssertEqual(r.outcome, .unreachable)
            XCTAssertEqual(r.status.state, "active")
            XCTAssertTrue(isPending(r.status))
            XCTAssertEqual(h.storage.data["licenseLastValidatedAt"], .null)
        }
        clock.t.value += 60 * 1000
        let last = await h.c.checkIfDue().outcome
        XCTAssertEqual(last, .registered)
        XCTAssertEqual(fetch.calls.count, 7)
    }

    func testT34PendingMaxMachinesStoresNumbers() async throws {
        var body = maxMachinesBody
        body["machinesUsed"] = 5
        let h = client(fetch: ScriptedTransport(offline, reply(body)))
        _ = try await h.c.activate(KEY)
        let r = await h.c.checkIfDue()
        XCTAssertEqual(r.status.state, "locked")
        XCTAssertEqual(reason(r.status), .maxMachines)
        XCTAssertEqual(r.outcome, .maxMachines)
        XCTAssertEqual(message(r.status), "This license is already active on 5 of 4 machines. Contact support@graviton.tools to free one.")
        XCTAssertTrue(r.changed)
        XCTAssertEqual(h.storage.data["licenseActivationMachinesUsed"], .number(5))
        XCTAssertEqual(h.storage.data["licenseActivationMachineLimit"], .number(4))
        let persisted = try await h.c.status()
        XCTAssertEqual(message(persisted), message(r.status), "persisted: status() reads the stored numbers")
        XCTAssertEqual(h.storage.data["licenseActivationPending"], .bool(true), "still pending, so it keeps asking")
    }

    func testT35BothLimitPathsOneWording() async throws {
        let direct = try await client(fetch: ScriptedTransport(reply(maxMachinesBody))).c.activate(KEY)
        let h = client(fetch: ScriptedTransport(offline, reply(maxMachinesBody)))
        _ = try await h.c.activate(KEY)
        let pending = await h.c.checkIfDue()
        XCTAssertEqual(message(pending.status), refusal(direct)?.message)
        XCTAssertEqual(refusal(direct)?.message, "This license is already active on 4 of 4 machines. Contact support@graviton.tools to free one.")
    }

    func testT36OldMaxMachinesLockNoNumbers() async throws {
        let storage = MemoryStorage(["licenseKey": .string(KEY), "licenseActivated": .bool(true),
                                     "licenseActivationPending": .bool(true), "licenseActivationError": .string("max_machines"),
                                     "licenseMachineId": .string("x")])
        let s = try await client(storage: storage).c.status()
        XCTAssertEqual(s.state, "locked")
        XCTAssertEqual(message(s), LicenseMessages.maxMachines)
    }

    func testT37Pending4xxWritesNothing() async throws {
        let h = client(fetch: ScriptedTransport(offline, reply(["ok": false, "error": "missing_fields"], 400)))
        _ = try await h.c.activate(KEY)
        let before = h.storage.data
        let r = await h.c.checkIfDue()
        XCTAssertEqual(r.outcome, .unreachable)
        XCTAssertEqual(r.status.state, "active")
        XCTAssertEqual(h.storage.data, before)
    }

    func testT38MaxMachinesLockLiftsWhenSlotFreed() async throws {
        let fetch = ScriptedTransport(offline, reply(maxMachinesBody), offline, reply(maxMachinesBody), reply(["ok": true]))
        let clock = Clock(T0)
        let h = client(fetch: fetch, clock: clock)
        _ = try await h.c.activate(KEY)
        for expected in ["locked", "locked", "locked", "active"] {
            clock.t.value += 60 * 1000
            let state = await h.c.checkIfDue().status.state
            XCTAssertEqual(state, expected)
        }
        XCTAssertEqual(h.storage.data["licenseActivationError"], .null)
        XCTAssertEqual(h.storage.data["licenseActivationMachinesUsed"], .null, "the refusal numbers are cleared too")
        XCTAssertEqual(h.storage.data["licenseActivationMachineLimit"], .null)
        XCTAssertEqual(h.storage.data["licenseActivationPending"], .bool(false))
    }

    func testT39PendingRevokedLocks() async throws {
        let h = client(fetch: ScriptedTransport(offline, reply(["ok": false, "error": "revoked", "revokedAt": T0])))
        _ = try await h.c.activate(KEY)
        let r = await h.c.checkIfDue()
        XCTAssertEqual(r.status.state, "locked")
        XCTAssertEqual(message(r.status), LicenseMessages.locked)
    }

    func testT40PendingReusesStoredId() async throws {
        let fetch = ScriptedTransport(offline, reply(["ok": true]))
        let h = client(fetch: fetch, machineId: hw("hardware-id-changed"))
        _ = try await h.c.activate(KEY, machineId: "used-at-activation")
        _ = await h.c.checkIfDue()
        XCTAssertEqual(fetch.calls[1].body, ["key": .string(KEY), "machineId": .string("used-at-activation"),
                                             "version": .string("1.2.3"), "platform": .string("darwin")])
    }

    func testT41DeactivateClearsPending() async throws {
        let storage = MemoryStorage()
        let h = client(storage: storage)
        try await storage.write(["licenseKey": .string(KEY), "licenseActivated": .bool(true),
                                 "licenseActivationPending": .bool(true), "licenseActivationError": .string("max_machines"),
                                 "licenseMachineId": .string("x")])
        try await h.c.deactivate()
        XCTAssertEqual(storage.data["licenseActivationPending"], .bool(false))
        XCTAssertEqual(storage.data["licenseActivationError"], .null)
        XCTAssertEqual(storage.data["licenseMachineId"], .string("x"), "the machine ID identifies the install and is kept")
        let state = try await h.c.status().state
        XCTAssertEqual(state, "unlicensed")
    }

    // MARK: Machine ID resolution: never a silent second machine

    func testT42ExplicitIdWins() async throws {
        let fetch = ScriptedTransport(reply(["ok": true]))
        let storage = MemoryStorage(["licenseMachineId": .string("stored-id")])
        _ = try await client(storage: storage, fetch: fetch, machineId: hw("hardware-id")).c.activate(KEY, machineId: "explicit-id")
        XCTAssertEqual(fetch.calls[0].body["machineId"], .string("explicit-id"))
        XCTAssertEqual(storage.data["licenseMachineId"], .string("explicit-id"))
    }

    func testT43StoredIdUsedNoHardwareRead() async throws {
        let fetch = ScriptedTransport(reply(["ok": true]))
        let calls = Locked(0)
        let h = client(storage: MemoryStorage(["licenseMachineId": .string("stored-id")]), fetch: fetch,
                       machineId: { calls.value += 1; return MachineIdResult(id: "hardware-id", source: "ioreg") })
        _ = try await h.c.activate(KEY)
        XCTAssertEqual(fetch.calls[0].body["machineId"], .string("stored-id"))
        XCTAssertEqual(calls.value, 0, "getMachineId() not even consulted")
    }

    func testT44HardwareIdOnlyWhenNoneStored() async throws {
        for missing in [nil, LicenseValue.null, .string("")] {
            let fetch = ScriptedTransport(reply(["ok": true]))
            let storage = MemoryStorage(missing.map { ["licenseMachineId": $0] } ?? [:])
            _ = try await client(storage: storage, fetch: fetch, machineId: hw("hardware-id")).c.activate(KEY)
            XCTAssertEqual(fetch.calls[0].body["machineId"], .string("hardware-id"))
            XCTAssertEqual(storage.data["licenseMachineId"], .string("hardware-id"))
        }
    }

    func testT45IdPersistedBeforeRequest() async throws {
        let storage = MemoryStorage()
        let storedDuringRequest = Locked<LicenseValue?>(nil)
        let transport: LicenseClient.Transport = { _ in
            storedDuringRequest.value = storage.data["licenseMachineId"]
            throw URLError(.timedOut)
        }
        let c = try LicenseClient(product: "test", keyPrefix: PREFIX, publicKey: PUBLIC_RAW, appVersion: "1.2.3",
                                  storage: storage, transport: transport, acceptOfflineActivation: false,
                                  now: { T0 }, machineId: hw("hardware-id"))
        let r = try await c.activate(KEY)
        XCTAssertEqual(refusal(r)?.error, "unreachable")
        XCTAssertEqual(storedDuringRequest.value, .string("hardware-id"), "on record before the request left")
        XCTAssertEqual(storage.data["licenseMachineId"], .string("hardware-id"), "still on record after the timeout")
        XCTAssertNil(storage.data["licenseKey"], "nothing else stored on a refused activation")
    }

    func testT46DeactivateKeepsIdReentrySameId() async throws {
        let fetch = ScriptedTransport(reply(["ok": true]))
        let hardware = Locked("hardware-id-1")
        let h = client(fetch: fetch, machineId: { MachineIdResult(id: hardware.value, source: "ioreg") })
        _ = try await h.c.activate(KEY)
        try await h.c.deactivate()
        XCTAssertEqual(h.storage.data["licenseMachineId"], .string("hardware-id-1"))
        hardware.value = "hardware-id-2"
        _ = try await h.c.activate(KEY)
        XCTAssertEqual(fetch.calls[0].body["machineId"], .string("hardware-id-1"))
        XCTAssertEqual(fetch.calls[1].body["machineId"], .string("hardware-id-1"), "same slot, not a second machine")
    }

    func testT47PendingNoIdSendsNothing() async throws {
        for missing in [nil, LicenseValue.null, .string("")] {
            let fetch = ScriptedTransport(reply(["ok": true]))
            let calls = Locked(0)
            var initial: LicenseFields = ["licenseKey": .string(KEY), "licenseActivated": .bool(true),
                                          "licenseActivationPending": .bool(true), "licenseActivationError": .null,
                                          "licenseValidated": .bool(false)]
            if let missing { initial["licenseMachineId"] = missing }
            let storage = MemoryStorage(initial)
            let h = client(storage: storage, fetch: fetch,
                           machineId: { calls.value += 1; return MachineIdResult(id: "hardware-id", source: "ioreg") })
            try await Task.sleep(nanoseconds: 20_000_000)   // let the background read settle
            let atConstruction = calls.value
            for _ in 0..<3 {
                let r = await h.c.checkIfDue()
                XCTAssertEqual(r.outcome, .unreachable)
                XCTAssertEqual(r.status.state, "active", "keeps working")
                XCTAssertTrue(isPending(r.status))
            }
            XCTAssertEqual(fetch.calls.count, 0, "no /activate with a substituted ID")
            XCTAssertEqual(calls.value, atConstruction, "the retry never consults the hardware")
            XCTAssertEqual(storage.data["licenseMachineId"], missing, "and never stores it")
            XCTAssertEqual(storage.data["licenseActivationPending"], .bool(true))
        }
    }

    func testT48OfflineRefusedWhenNotAccepted() async throws {
        let h = client(fetch: ScriptedTransport(offline), acceptOfflineActivation: false)
        let r = try await h.c.activate(KEY)
        XCTAssertEqual(r, .refused(error: "unreachable", message: LicenseMessages.unreachable))
        XCTAssertNil(h.storage.data["licenseKey"])
    }

    // MARK: Deactivation

    func testT49DeactivateClearsFieldsNoRequest() async throws {
        let fetch = ScriptedTransport()
        let storage = activatedAt(T0, ["trialStartDate": .number(T0 - DAY), "machineId": .string("kept")])
        let h = client(storage: storage, fetch: fetch)
        try await h.c.deactivate()
        XCTAssertEqual(fetch.calls.count, 0)
        for (k, v) in LicenseClient.clearedFields { XCTAssertEqual(storage.data[k], v, k) }
        XCTAssertEqual(storage.data["trialStartDate"], .number(T0 - DAY), "unrelated fields untouched")
        let state = try await h.c.status().state
        XCTAssertEqual(state, "unlicensed")
    }

    // MARK: Logging

    /// Adapted: Swift cannot intercept NSLog the way the JS swaps console methods. The target has no
    /// logging call at all, which is the guarantee the JS test exists to keep.
    func testT50NothingIsLogged() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LicenseClient")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for call in ["NSLog(", "print(", "debugPrint(", "os_log(", "Logger(", "dump(", "FileHandle.standardError"] {
                XCTAssertFalse(text.contains(call), "\(file.lastPathComponent) contains \(call)")
            }
        }
    }

    // MARK: Machine ID

    let UUID_ = "ABCDEF01-2345-6789-ABCD-EF0123456789"
    var EXPECTED: String {
        SHA256.hash(data: Data(UUID_.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
    let OTHER_UUID = "11111111-2222-3333-4444-555555555555"
    func spOut(_ u: String) -> String { "Hardware:\n\n    Hardware Overview:\n\n      Hardware UUID: \(u)\n" }

    func testT51Sha256Prefix32Hex() {
        XCTAssertEqual(MachineID.sha256Prefix(UUID_), EXPECTED)
        XCTAssertNotNil(EXPECTED.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
    }

    func testT52NormalisationAcceptReject() {
        for raw in [UUID_, " \(UUID_)\r\n", "{\(UUID_)}", "{\(UUID_.lowercased())}", "  {\(UUID_.lowercased())}  "] {
            XCTAssertEqual(MachineID.normalizeUuid(raw), UUID_, raw)
        }
        let rejects: [String?] = [nil, "", "   ", "garbage", "To be filled by O.E.M.",
                                  "00000000-0000-0000-0000-000000000000", "{00000000-0000-0000-0000-000000000000}",
                                  "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", "ffffffff-ffff-ffff-ffff-ffffffffffff",
                                  String(UUID_.dropFirst()), "\(UUID_)0", UUID_.replacingOccurrences(of: "-", with: ""),
                                  "{{\(UUID_)}}}", "\(UUID_) extra"]
        for raw in rejects { XCTAssertNil(MachineID.normalizeUuid(raw), raw ?? "nil") }
    }

    /// darwin half: IOKit's raw property and system_profiler's output, in any formatting.
    func testT53OneIdAcrossDarwinSources() async {
        let lower = UUID_.lowercased()
        let sp = spOut(UUID_)
        let results = [
            await MachineID.compute(sources: [("ioreg", { self.UUID_ })]),
            await MachineID.compute(sources: [("ioreg", { "{\(lower)}" })]),
            await MachineID.compute(sources: [("ioreg", { throw DiskError() }),
                                              ("system_profiler", { MachineID.parseSystemProfiler(sp) })]),
        ]
        XCTAssertEqual(results.map(\.source), ["ioreg", "ioreg", "system_profiler"])
        for r in results { XCTAssertEqual(r.id, EXPECTED) }
    }

    func testT59DeterminismOnMac() async {
        let sp = spOut(UUID_)
        for _ in 0..<5 {
            let r = await MachineID.compute(sources: [("ioreg", { self.UUID_ }),
                                                      ("system_profiler", { MachineID.parseSystemProfiler(sp) })])
            XCTAssertEqual(r, MachineIdResult(id: EXPECTED, source: "ioreg"))
        }
    }

    func testT60IoKitAndSystemProfilerMatchPrevious() async {
        let previousIoreg = MachineID.sha256Prefix(UUID_.trimmingCharacters(in: .whitespaces))
        let line = spOut(UUID_).split(separator: "\n").first { $0.contains("Hardware UUID") }!
        let gradeShare = MachineID.sha256Prefix(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
        let sp = spOut(UUID_)
        let viaIoreg = await MachineID.compute(sources: [("ioreg", { self.UUID_ })])
        let viaSp = await MachineID.compute(sources: [("ioreg", { throw DiskError() }),
                                                      ("system_profiler", { MachineID.parseSystemProfiler(sp) })])
        XCTAssertEqual(viaIoreg, MachineIdResult(id: previousIoreg, source: "ioreg"))
        XCTAssertEqual(viaSp, MachineIdResult(id: gradeShare, source: "system_profiler"))
        XCTAssertEqual(previousIoreg, EXPECTED)
    }

    func testT61NoSourceNoIdNoHostname() async {
        let outputs: [@Sendable () async throws -> String?] = [
            { throw DiskError() }, { "" }, { "garbage" }, { "00000000-0000-0000-0000-000000000000" }, { nil },
        ]
        let hostnameHash = MachineID.sha256Prefix(ProcessInfo.processInfo.hostName + "darwin")
        for read in outputs {
            let r = await MachineID.compute(sources: [("ioreg", read), ("system_profiler", read)])
            XCTAssertEqual(r, .none)
            XCTAssertNotEqual(r.id, hostnameHash)
        }
    }

    // MARK: Machine ID: refusal, caching, storage

    func testT64NoHardwareIdRefusesThenRetries() async throws {
        let output = Locked("00000000-0000-0000-0000-000000000000")
        let cache = MachineID.Cache { await MachineID.compute(sources: [("system_profiler", { output.value })]) }
        let fetch = ScriptedTransport(reply(["ok": true]))
        let h = client(fetch: fetch, machineId: { await cache.get() })
        for bad in ["00000000-0000-0000-0000-000000000000", "garbage"] {
            output.value = bad
            let r = try await h.c.activate(KEY)
            XCTAssertEqual(r, .refused(error: "no_machine_id",
                                       message: "Couldn't read this computer's hardware ID. Contact support@graviton.tools."))
            XCTAssertEqual(refusal(r)?.message, LicenseMessages.noMachineId)
            XCTAssertEqual(h.storage.data, [:], "nothing written")
            XCTAssertEqual(fetch.calls.count, 0, "nothing sent")
        }
        output.value = UUID_
        let r = try await h.c.activate(KEY)
        XCTAssertTrue(isOk(r))
        XCTAssertEqual(fetch.calls[0].body["machineId"], .string(EXPECTED))
        XCTAssertEqual(h.storage.data["licenseMachineId"], .string(EXPECTED))
        XCTAssertEqual(h.storage.data["licenseMachineIdSource"], .string("system_profiler"))
    }

    func testT65CacheSuccessNotFailure() async {
        let computes = Locked(0)
        let answer = Locked(MachineIdResult.none)
        let cache = MachineID.Cache { computes.value += 1; return answer.value }
        _ = await cache.get()
        _ = await cache.get()
        XCTAssertEqual(computes.value, 2, "no ID: read again")
        answer.value = MachineIdResult(id: EXPECTED, source: "ioreg")
        _ = await cache.get()
        answer.value = MachineIdResult(id: "changed", source: "ioreg")
        let cached = await cache.get()
        XCTAssertEqual(cached, MachineIdResult(id: EXPECTED, source: "ioreg"))
        XCTAssertEqual(computes.value, 3)
        let throwing = MachineID.Cache { throw DiskError() }
        let none = await throwing.get()
        XCTAssertEqual(none, .none, "a throw is reported as no ID, never a rejection")
    }

    func testT66GetMachineIdThrowsThenRetries() async throws {
        let output = Locked("00000000-0000-0000-0000-000000000000")
        let cache = MachineID.Cache { await MachineID.compute(sources: [("ioreg", { output.value })]) }
        do {
            _ = try await MachineID.getMachineId(cache)
            XCTFail("should throw")
        } catch let e as MachineID.Unavailable {
            XCTAssertEqual(e.message, "Couldn't read this computer's hardware ID")
        }
        let none = MachineID.Cache { await MachineID.compute(sources: [("ioreg", { throw DiskError() })]) }
        do { _ = try await MachineID.getMachineId(none); XCTFail("rejects rather than a hostname hash") } catch {}
        output.value = UUID_
        let id = try await MachineID.getMachineId(cache)
        XCTAssertEqual(id, EXPECTED, "a plain 32-hex string")
    }

    /// The real IORegistry. The ID is checked for shape only and never printed: an assertion
    /// message here would put this Mac's machine ID into the test log.
    func testT67RealMachineId32Hex() async throws {
        let id = try await MachineID.getMachineId(MachineID.Cache { await MachineID.compute() })
        XCTAssertTrue(id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
        let direct = try MachineID.readIOPlatformUUID()
        XCTAssertTrue(MachineID.normalizeUuid(direct) != nil, "IOKit answers on this Mac")
    }

    actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    func testT68BackgroundReadAtCreation() async throws {
        let started = Locked(0)
        let gate = Gate()
        let expected = EXPECTED
        let cache = MachineID.Cache { started.value += 1; await gate.wait(); return MachineIdResult(id: expected, source: "ioreg") }
        let h = client(fetch: ScriptedTransport(reply(["ok": true])), machineId: { await cache.get() })
        for _ in 0..<200 where started.value == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(started.value, 1, "started by the client's construction")
        let pending = Task { try await h.c.activate(KEY) }
        await gate.open()
        let r = try await pending.value
        XCTAssertTrue(isOk(r))
        XCTAssertEqual(started.value, 1, "activate used the read already in flight")
    }

    func testT69NoBackgroundReadWithStoredId() async throws {
        let started = Locked(0)
        _ = client(storage: MemoryStorage(["licenseMachineId": .string("stored")]),
                   machineId: { started.value += 1; return MachineIdResult(id: "x", source: "ioreg") })
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(started.value, 0)
    }

    func testT70CreationSurvivesStorageThrow() {
        XCTAssertNoThrow(try LicenseClient(product: "test", keyPrefix: PREFIX, publicKey: PUBLIC_RAW, appVersion: "1.2.3",
                                           storage: ThrowingStorage(), transport: ScriptedTransport().transport,
                                           machineId: hw(M32)))
    }

    func testT71SourceStoredExplicitNull() async throws {
        let h = client(fetch: ScriptedTransport(reply(["ok": true])),
                       machineId: { MachineIdResult(id: "derived-id", source: "lastconfig") })
        _ = try await h.c.activate(KEY)
        XCTAssertEqual(h.storage.data["licenseMachineId"], .string("derived-id"))
        XCTAssertEqual(h.storage.data["licenseMachineIdSource"], .string("lastconfig"))
        let explicit = client(fetch: ScriptedTransport(reply(["ok": true])))
        _ = try await explicit.c.activate(KEY, machineId: "explicit-id")
        XCTAssertEqual(explicit.storage.data["licenseMachineIdSource"], .null)
    }

    func testT72StoredIdsNeverRecomputed() async throws {
        let stored = [MachineID.sha256Prefix("old-mac" + "darwin"), MachineID.sha256Prefix("OLD-PC" + "win32"),
                      "3f2b1c9e-legacy-random-uuid", "6F1C2B4A-0D3E-4C5F-9A8B-7E6D5C4B3A21"]   // the last: a Manifold 0.8.4 UUID
        for id in stored {
            let calls = Locked(0)
            let fetch = ScriptedTransport(reply(["ok": true]), reply(["ok": true]))
            let storage = MemoryStorage(["licenseMachineId": .string(id)])
            let h = client(storage: storage, fetch: fetch,
                           machineId: { calls.value += 1; return MachineIdResult(id: "hardware", source: "ioreg") })
            _ = try await h.c.activate(KEY)
            try await h.c.deactivate()
            _ = try await h.c.activate(KEY)
            XCTAssertEqual(calls.value, 0, "hardware never read")
            XCTAssertEqual(fetch.calls.map { $0.body["machineId"] }, [.string(id), .string(id)])
            XCTAssertEqual(storage.data["licenseMachineId"], .string(id))
            XCTAssertNil(storage.data["licenseMachineIdSource"], "no source invented for an existing ID")
        }
    }

    // MARK: Construction

    func testT73EmptyConfigThrowsAtInit() {
        func make(product: String = "test", prefix: String = PREFIX, key: Data = PUBLIC_RAW, version: String = "1.2.3") throws {
            _ = try LicenseClient(product: product, keyPrefix: prefix, publicKey: key, appVersion: version,
                                  storage: MemoryStorage(), transport: ScriptedTransport().transport, machineId: hw(M32))
        }
        XCTAssertThrowsError(try make(product: ""))
        XCTAssertThrowsError(try make(prefix: ""))
        XCTAssertThrowsError(try make(key: Data()))
        XCTAssertThrowsError(try make(version: ""))
        XCTAssertNoThrow(try make())
    }
}

/// Manifold-only checks that the JS suite has no need for.
final class LicenseClientSwiftOnlyTests: XCTestCase {

    /// CryptoKit wants the raw 32 bytes; license.js wants the PEM. Rebuilding the SPKI DER from the
    /// fixed prefix plus the raw key gives back the PEM body, so the two name the same key.
    func testSPKIPrefixPlusRawIsThePEM() {
        let pemBody = "MCowBQYDK2VwAyEATqFHmOnArbNaeJc+kYeo5eHnuEabp/1SX6NihE76Hy4="   // Manifold's PUBLIC key
        let raw = Data(base64Encoded: "TqFHmOnArbNaeJc+kYeo5eHnuEabp/1SX6NihE76Hy4=")!
        XCTAssertEqual((LicenseKey.ed25519SPKIPrefix + raw).base64EncodedString(), pemBody)
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw))
    }

    /// A key signed by Node's crypto.sign (throwaway keypair, generated for this fixture) verifies
    /// here: the two implementations agree on the format and the signature.
    func testNodeSignedFixtureVerifies() {
        let publicRaw = Data(base64Encoded: NodeFixture.publicRawBase64)!
        let r = LicenseKey.verify(NodeFixture.key, keyPrefix: "TEST-", publicKey: publicRaw, nowMs: T0)
        XCTAssertEqual(r.payload?["email"], .string("customer@example.test"))
        XCTAssertEqual(LicenseKey.verify(NodeFixture.key + "x", keyPrefix: "TEST-", publicKey: publicRaw, nowMs: T0),
                       .invalid(.signature))
    }

    /// `"ok": 1` is not `ok === true`, though NSNumber(1) bridges to Bool.
    func testJSONNumberOneIsNotTrue() async throws {
        let h = client(fetch: ScriptedTransport(.reply(#"{"ok":1}"#, 200)))
        _ = try await h.c.activate(KEY)
        let status = try await h.c.status()
        XCTAssertTrue(isPending(status), "unanswered, so accepted offline")
        XCTAssertEqual(LicenseValue(json: NSNumber(value: 1)), .number(1))
        XCTAssertEqual(LicenseValue(json: NSNumber(value: true)), .bool(true))
    }

    func testTotalDeadlineIsEnforced() async throws {
        // The transport never answers; the client gives up at its own deadline and reports unreachable.
        let transport: LicenseClient.Transport = { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw URLError(.timedOut)
        }
        let c = try LicenseClient(product: "test", keyPrefix: PREFIX, publicKey: PUBLIC_RAW, appVersion: "1.2.3",
                                  storage: MemoryStorage(), transport: transport, machineId: hw(M32))
        let started = Date()
        let outcome = await c.validate(KEY)
        XCTAssertEqual(outcome, .unreachable)
        XCTAssertLessThan(Date().timeIntervalSince(started), LicenseClient.validateTimeout + 2)
    }

    func testActivationStorageFailureSendsNothing() async throws {
        final class WriteFails: LicenseStorage, @unchecked Sendable {
            func read() async throws -> LicenseFields { [:] }
            func write(_ patch: LicenseFields) async throws { throw DiskError() }
        }
        let fetch = ScriptedTransport(reply(["ok": true]))
        let c = try LicenseClient(product: "test", keyPrefix: PREFIX, publicKey: PUBLIC_RAW, appVersion: "1.2.3",
                                  storage: WriteFails(), transport: fetch.transport, machineId: hw(M32))
        do {
            _ = try await c.activate(KEY)
            XCTFail("must not activate with an ID it could not persist")
        } catch let e as ActivationStorageError {
            XCTAssertFalse(e.afterRequest)
        }
        XCTAssertEqual(fetch.calls.count, 0, "nothing sent (D5)")
    }
}
