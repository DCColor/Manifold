//
//  LicenseClient.swift
//  LicenseClient — the Graviton license client, ported from Graviton-Releases `shared/license.js`.
//
//  Manifold is Swift and cannot `require` the module the Electron apps share, so this is the same
//  behaviour written natively. The policy is Graviton-Releases CLAUDE.md § "Shared license client —
//  decisions"; the behavioural spec is `tests/license.test.js`, ported test for test in
//  Tests/LicenseClientTests. Where this file and license.js differ in behaviour, this file is wrong.
//
//   • Validate at most every 7 days, counted from the last success. Unreachable changes nothing.
//   • Lock only on `revoked` (or a signed expiry, decided offline). `invalid_key` is unreachable.
//   • Offline activation is PENDING: /activate is retried every launch until the server answers.
//   • The machine ID is the explicit one, then the stored one, then the hardware ID — persisted
//     before the request, never cleared, never substituted on a pending retry.
//   • Deactivation is local only and keeps the machine ID.
//
//  ⚠️ NOTHING IN THIS TARGET LOGS. The license key, the customer email and the machine ID are
//  credentials or identifiers, and the simplest guarantee that none reaches a log is no logging
//  call at all (a test scans the sources). Callers decide what to say about an outcome — and must
//  not log `status()` or `activate()` results wholesale, because they carry the email.
//
//  Two departures that Swift forces, neither a change of behaviour:
//   • Storage is `async throws`, so the app can keep `securityd` off the cooperative pool. A write
//     that throws during `activate` surfaces as `ActivationStorageError`, saying whether the
//     request had been sent; license.js simply rejects.
//   • `status()` reads storage, so it is `async`. `status(from:)` is the pure form.
//

import Foundation

/// Where the client keeps its fields. `write` shallow-merges a patch, as license.js expects.
/// A read that fails must THROW — never answer with defaults.
public protocol LicenseStorage: Sendable {
    func read() async throws -> LicenseFields
    func write(_ patch: LicenseFields) async throws
}

public struct ActiveLicense: Equatable, Sendable {
    public var email: String?
    public var licenseType: String
    public var serverConfirmed: Bool
    public var lastValidatedAt: Double?
    public var pending: Bool
}

public enum LockReason: String, Sendable {
    /// The server said revoked (or refused a pending registration as revoked).
    case rejected
    /// A pending activation was refused at the machine limit.
    case maxMachines = "max_machines"
    /// The key's signed expiry has passed.
    case expired
    /// The stored key no longer verifies against this build's public key.
    case invalid
}

public enum LicenseStatus: Equatable, Sendable {
    case unlicensed
    case active(ActiveLicense)
    case locked(reason: LockReason, message: String)

    /// license.js `state`. `changed` compares this, not the whole status.
    public var state: String {
        switch self {
        case .unlicensed: return "unlicensed"
        case .active: return "active"
        case .locked: return "locked"
        }
    }
}

public enum CheckOutcome: String, Sendable {
    case valid, revoked, unreachable, registered, error
    case maxMachines = "max_machines"
}

public struct CheckResult: Equatable, Sendable {
    public var status: LicenseStatus
    public var checked: Bool
    public var changed: Bool
    public var outcome: CheckOutcome?
}

public enum ValidateOutcome: String, Sendable { case valid, revoked, unreachable }

public enum ActivateResult: Equatable, Sendable {
    case activated(email: String, licenseType: String, serverConfirmed: Bool, pending: Bool)
    case refused(error: String, message: String)
}

/// Storage failed during `activate`. `afterRequest` false: nothing was sent (the machine ID could
/// not be persisted first, Robbie D5). true: the server answered, and the result could not be saved.
public struct ActivationStorageError: Error {
    public let afterRequest: Bool
    public let underlying: Error
}

public enum LicenseClientError: Error, Equatable {
    case configuration(String)
}

public actor LicenseClient {

    public static let baseURL = "https://license.graviton.tools"
    /// Validate at most once per this interval, counted from the last SUCCESSFUL validation.
    public static let validationIntervalMs: Double = 7 * 24 * 60 * 60 * 1000
    /// A user pressed Activate and is watching, so it is worth waiting. The launch check is a
    /// background call nobody is waiting on; past 8 s the honest answer is "unreachable".
    public static let activateTimeout: TimeInterval = 15
    public static let validateTimeout: TimeInterval = 8
    /// The platforms the worker records on a machine entry. Anything else is not sent.
    public static let reportedPlatforms = ["darwin", "win32", "linux"]

    /// What `deactivate()` writes. `licenseMachineId` is deliberately absent: clearing it would let
    /// deactivate-then-re-enter register a second slot.
    public static let clearedFields: LicenseFields = [
        "licenseKey": .null,
        "licenseEmail": .null,
        "licenseType": .null,
        "licenseActivated": .bool(false),
        "licenseValidated": .bool(false),
        "licenseServerConfirmed": .bool(false),
        "licenseLastValidatedAt": .null,
        "licenseActivationPending": .bool(false),
        "licenseActivationError": .null,
        "licenseActivationMachinesUsed": .null,
        "licenseActivationMachineLimit": .null,
    ]

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias MachineIdProvider = @Sendable () async -> MachineIdResult

    public nonisolated let product: String
    public nonisolated let keyPrefix: String
    public nonisolated let publicKey: Data
    public nonisolated let appVersion: String
    nonisolated let storage: LicenseStorage
    let acceptOfflineActivation: Bool
    let transport: Transport
    nonisolated let now: @Sendable () -> Double
    nonisolated let machineIdProvider: MachineIdProvider
    let platform: String
    private var inFlightCheck: Task<CheckResult, Never>?

    /// Throws for empty configuration, at construction rather than first use. Starts the hardware
    /// read in the background on an install with no stored ID, so a first activation does not
    /// wait on it — unless `prefetchMachineId` is false, for an app whose launch must not read
    /// storage before it has decided anything; it then calls `prefetchMachineIdIfNeeded()` itself.
    public init(product: String,
                keyPrefix: String,
                publicKey: Data,
                appVersion: String,
                storage: LicenseStorage,
                transport: @escaping Transport,
                acceptOfflineActivation: Bool = true,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                machineId: @escaping MachineIdProvider = { await MachineID.shared.get() },
                platform: String = "darwin",
                prefetchMachineId: Bool = true) throws {
        for (name, empty) in [("product", product.isEmpty), ("keyPrefix", keyPrefix.isEmpty),
                              ("publicKey", publicKey.isEmpty), ("appVersion", appVersion.isEmpty)] where empty {
            throw LicenseClientError.configuration("\(name) must be non-empty")
        }
        self.product = product
        self.keyPrefix = keyPrefix
        self.publicKey = publicKey
        self.appVersion = appVersion
        self.storage = storage
        self.transport = transport
        self.acceptOfflineActivation = acceptOfflineActivation
        self.now = now
        self.machineIdProvider = machineId
        self.platform = platform

        if prefetchMachineId { Task { await Self.prefetch(storage, machineId) } }
    }

    /// The background hardware read, on an install with no stored ID. Not awaited for its result.
    public nonisolated func prefetchMachineIdIfNeeded() {
        let storage = self.storage, provider = self.machineIdProvider
        Task { await Self.prefetch(storage, provider) }
    }

    private static func prefetch(_ storage: LicenseStorage, _ provider: MachineIdProvider) async {
        // Unreadable storage: activate() will find out, and compute the ID then.
        guard let stored = try? await storage.read() else { return }
        if !truthy(stored["licenseMachineId"]) { _ = await provider() }
    }

    var endpoint: String { "\(Self.baseURL)/\(product)" }

    public nonisolated func verifyKey(_ key: String) -> KeyVerification {
        LicenseKey.verify(key, keyPrefix: keyPrefix, publicKey: publicKey, nowMs: now())
    }

    // MARK: - Status

    /// What to gate on. No network. Throws when storage cannot be read.
    public func status() async throws -> LicenseStatus {
        status(from: try await storage.read())
    }

    /// The pure form of `status()`, over fields already read.
    public nonisolated func status(from s: LicenseFields) -> LicenseStatus {
        guard truthy(s["licenseKey"]), truthy(s["licenseActivated"]) else { return .unlicensed }
        let offline: KeyVerification = s["licenseKey"]?.stringValue.map(verifyKey) ?? .invalid(.format)
        guard case .valid(let payload) = offline else {
            if case .invalid(.expired) = offline {
                return .locked(reason: .expired, message: LicenseMessages.expired)
            }
            return .locked(reason: .invalid, message: LicenseMessages.locked)
        }
        let lastValidated = s["licenseLastValidatedAt"]?.numberValue.flatMap { $0.isFinite ? $0 : nil }
        let active = ActiveLicense(
            email: truthyString(s["licenseEmail"]) ?? payload["email"]?.stringValue,
            licenseType: truthyString(s["licenseType"]) ?? truthyString(payload["licenseType"]) ?? "standard",
            serverConfirmed: s["licenseServerConfirmed"]?.isTrue == true,
            lastValidatedAt: lastValidated,
            pending: false)
        // Pending is checked before licenseValidated, which a pending install holds false.
        if s["licenseActivationPending"]?.isTrue == true {
            switch s["licenseActivationError"]?.stringValue {
            case "max_machines":
                return .locked(reason: .maxMachines,
                               message: LicenseMessages.maxMachines(used: s["licenseActivationMachinesUsed"],
                                                                    limit: s["licenseActivationMachineLimit"]))
            case "revoked":
                return .locked(reason: .rejected, message: LicenseMessages.locked)
            default:
                var pending = active
                pending.pending = true
                return .active(pending)
            }
        }
        if s["licenseValidated"] == .bool(false) {
            return .locked(reason: .rejected, message: LicenseMessages.locked)
        }
        return .active(active)
    }

    /// Whether the schedule calls for a server check right now. A locked license is re-checked
    /// every launch; a clock set back before the last success counts as due.
    nonisolated func isDue(_ s: LicenseFields, _ t: Double) -> Bool {
        if s["licenseValidated"] == .bool(false) { return true }
        guard let last = s["licenseLastValidatedAt"]?.numberValue, last.isFinite else { return true }
        let elapsed = t - last
        return elapsed < 0 || elapsed >= Self.validationIntervalMs
    }

    // MARK: - The launch check

    /// Validates against the server only when due; every launch while pending. Never throws.
    /// Concurrent calls share one request.
    public func checkIfDue() async -> CheckResult {
        if let inFlightCheck { return await inFlightCheck.value }
        let task = Task { await self.runCheckSafely() }
        inFlightCheck = task
        let result = await task.value
        if inFlightCheck == task { inFlightCheck = nil }
        return result
    }

    private func runCheckSafely() async -> CheckResult {
        do {
            return try await runCheck()
        } catch {
            let status = (try? await status()) ?? .unlicensed
            return CheckResult(status: status, checked: false, changed: false, outcome: .error)
        }
    }

    private func runCheck() async throws -> CheckResult {
        let before = try await status()
        let s = try await storage.read()

        // Nothing activated, or the stored key fails offline. Neither is something the server
        // can change, so there is nothing to ask it.
        switch before {
        case .unlicensed, .locked(reason: .expired, _), .locked(reason: .invalid, _):
            return CheckResult(status: before, checked: false, changed: false, outcome: nil)
        default:
            break
        }
        let t = now()

        // ── Pending registration: every launch, not every 7 days ──
        if s["licenseActivationPending"]?.isTrue == true {
            // ⚠️ NO FALLBACK TO THE HARDWARE ID HERE. A pending install with no stored ID can only
            // come from a legacy conversion, and an earlier attempt may have registered some other
            // ID — sending a fresh one could take a second slot only an admin can free.
            guard let machineId = s["licenseMachineId"], machineId.isTruthy else {
                return CheckResult(status: before, checked: false, changed: false, outcome: .unreachable)
            }
            let reply = await postActivate(key: s["licenseKey"] ?? .null, machineId: machineId)
            var outcome = CheckOutcome.unreachable
            switch reply.result {
            case .ok:
                try await storage.write([
                    "licenseActivationPending": .bool(false),
                    "licenseActivationError": .null,
                    "licenseActivationMachinesUsed": .null,
                    "licenseActivationMachineLimit": .null,
                    "licenseValidated": .bool(true),
                    "licenseServerConfirmed": .bool(true),
                    "licenseLastValidatedAt": .number(t),
                ])
                outcome = .registered
            case .maxMachines, .revoked:
                // Pending stays true, so the next launch asks again: a freed slot or an Unrevoke
                // unlocks it without the customer retyping anything.
                let counts = reply.result == .maxMachines ? reply.data : [:]
                try await storage.write([
                    "licenseActivationError": .string(reply.result.rawValue),
                    "licenseActivationMachinesUsed": isCount(counts["machinesUsed"]) ? counts["machinesUsed"]! : .null,
                    "licenseActivationMachineLimit": isCount(counts["machineLimit"]) ? counts["machineLimit"]! : .null,
                ])
                outcome = reply.result == .maxMachines ? .maxMachines : .revoked
            default:
                // No answer, invalid_key, a 4xx: write nothing, keep working, retry next launch.
                break
            }
            let after = try await status()
            return CheckResult(status: after, checked: true, changed: after.state != before.state, outcome: outcome)
        }

        guard isDue(s, t), let key = s["licenseKey"]?.stringValue else {
            return CheckResult(status: before, checked: false, changed: false, outcome: nil)
        }

        let outcome = await validate(key)
        switch outcome {
        case .valid:
            try await storage.write(["licenseValidated": .bool(true), "licenseLastValidatedAt": .number(t)])
        case .revoked:
            // licenseActivated and the key are kept: the next launch re-checks, and recovers if
            // the revocation is reversed.
            try await storage.write(["licenseValidated": .bool(false)])
        case .unreachable:
            // invalid_key included: nothing written, no lockout, and the check stays due.
            break
        }
        let after = try await status()
        let mapped: CheckOutcome = outcome == .valid ? .valid : outcome == .revoked ? .revoked : .unreachable
        return CheckResult(status: after, checked: true, changed: after.state != before.state, outcome: mapped)
    }

    // MARK: - Server calls

    /// One POST to /validate, no state read or written. Only `{valid: false, error: 'revoked'}`
    /// in a 2xx locks; everything else — 400s, `expired`, and `invalid_key` ON PURPOSE (the key
    /// verified locally, so the worker disagreeing is a worker-side key problem) — is unreachable.
    public func validate(_ key: String) async -> ValidateOutcome {
        let body: [String: Any] = ["key": key.trimmingCharacters(in: .whitespacesAndNewlines), "version": appVersion]
        guard let res = await postJson("validate", body, timeout: Self.validateTimeout),
              (200..<300).contains(res.status) else { return .unreachable }
        if res.data["valid"]?.isTrue == true { return .valid }
        if res.data["valid"] == .bool(false), res.data["error"]?.stringValue == "revoked" { return .revoked }
        return .unreachable
    }

    enum ActivateReplyResult: String { case ok, maxMachines = "max_machines", revoked, rejected, refused, unreachable }

    struct ActivateReply {
        var result: ActivateReplyResult
        var error: String? = nil
        var data: LicenseFields = [:]
    }

    /// One POST to /activate, no state read or written. `ok` (or `alreadyRegistered` alone) at any
    /// status; `max_machines`/`revoked` in a 2xx; any other error string is `rejected` with a 4xx,
    /// else `refused`; no usable answer is `unreachable`.
    func postActivate(key: LicenseValue, machineId: LicenseValue) async -> ActivateReply {
        var body: [String: Any] = ["key": key.jsonObject, "machineId": machineId.jsonObject, "version": appVersion]
        if Self.reportedPlatforms.contains(platform) { body["platform"] = platform }
        guard let res = await postJson("activate", body, timeout: Self.activateTimeout) else {
            return ActivateReply(result: .unreachable)
        }
        if res.data["ok"]?.isTrue == true || res.data["alreadyRegistered"]?.isTrue == true {
            return ActivateReply(result: .ok, data: res.data)
        }
        let error = res.data["error"]?.stringValue
        if (200..<300).contains(res.status), let error, error == "max_machines" || error == "revoked" {
            return ActivateReply(result: error == "revoked" ? .revoked : .maxMachines, error: error, data: res.data)
        }
        if let error, !error.isEmpty {
            let result: ActivateReplyResult = (400..<500).contains(res.status) ? .rejected : .refused
            return ActivateReply(result: result, error: error, data: res.data)
        }
        return ActivateReply(result: .unreachable)
    }

    /// POST a JSON body and return the status and the parsed object, or nil for every way of
    /// getting no usable answer: no network, the deadline, non-JSON (the worker 404s with plain
    /// "Not found"; a captive portal answers 200 with HTML), or JSON that is not an object.
    func postJson(_ path: String, _ body: [String: Any], timeout: TimeInterval) async -> (status: Int, data: LicenseFields)? {
        guard let url = URL(string: "\(endpoint)/\(path)"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = timeout
        let transport = self.transport
        let sendable = request
        do {
            // A TOTAL deadline, like AbortSignal.timeout. URLRequest's interval is an idle timeout.
            let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { try await transport(sendable) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            guard let http = response as? HTTPURLResponse,
                  let parsed = LicenseValue.parseObject(data) else { return nil }
            return (http.statusCode, parsed)
        } catch {
            return nil
        }
    }

    // MARK: - Activation

    /// Activate this machine. Verifies the key offline first — a typo never reaches the network.
    ///
    /// The machine ID is the explicit `machineId`, then the stored `licenseMachineId`, then the
    /// hardware ID. Whichever is chosen is persisted BEFORE the request, so a reply lost to a
    /// timeout still leaves it on record; if it cannot be persisted, nothing is sent (throws
    /// `ActivationStorageError(afterRequest: false)`). No hardware ID: refused, nothing written.
    public func activate(_ key: String, machineId explicitId: String? = nil) async throws -> ActivateResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let offline = verifyKey(trimmed)
        guard case .valid(let payload) = offline else {
            if case .invalid(.expired) = offline {
                return .refused(error: "expired", message: LicenseMessages.expired)
            }
            return .refused(error: "invalid_key", message: LicenseMessages.notRecognized)
        }

        let stored: LicenseValue?
        do {
            stored = try await storage.read()["licenseMachineId"]
        } catch {
            throw ActivationStorageError(afterRequest: false, underlying: error)
        }
        var id: LicenseValue
        var source: LicenseValue = .null
        if let explicitId, !explicitId.isEmpty {
            id = .string(explicitId)
        } else if let stored, stored.isTruthy {
            id = stored
        } else {
            let derived = await machineIdProvider()
            guard let derivedId = derived.id, !derivedId.isEmpty else {
                return .refused(error: "no_machine_id", message: LicenseMessages.noMachineId)
            }
            id = .string(derivedId)
            source = derived.source.map(LicenseValue.string) ?? .null
        }
        if id != stored {
            do {
                try await storage.write(["licenseMachineId": id, "licenseMachineIdSource": source])
            } catch {
                throw ActivationStorageError(afterRequest: false, underlying: error)
            }
        }

        let reply = await postActivate(key: .string(trimmed), machineId: id)
        let email = truthyString(payload["email"]) ?? ""
        let licenseType = truthyString(payload["licenseType"]) ?? "standard"
        let t = now()
        let identity: LicenseFields = [
            "licenseKey": .string(trimmed),
            "licenseEmail": .string(email),
            "licenseType": .string(licenseType),
            "licenseActivated": .bool(true),
            "licenseMachineId": id,
        ]

        switch reply.result {
        case .ok:
            var patch = identity
            patch.merge([
                "licenseValidated": .bool(true),
                "licenseServerConfirmed": .bool(true),
                // Activation checks signature and revocation, so it counts as a successful
                // validation and starts the 7-day interval.
                "licenseLastValidatedAt": .number(t),
                "licenseActivationPending": .bool(false),
                "licenseActivationError": .null,
                "licenseActivationMachinesUsed": .null,
                "licenseActivationMachineLimit": .null,
            ]) { $1 }
            do { try await storage.write(patch) } catch {
                throw ActivationStorageError(afterRequest: true, underlying: error)
            }
            return .activated(email: email, licenseType: licenseType, serverConfirmed: true, pending: false)
        case .rejected:
            let code = reply.error ?? ""
            return .refused(error: code, message: LicenseMessages.rejected(code))
        case .maxMachines, .revoked, .refused:
            let code = reply.error ?? ""
            return .refused(error: code, message: LicenseMessages.activation(code, reply.data))
        case .unreachable:
            break
        }

        guard acceptOfflineActivation else {
            return .refused(error: "unreachable", message: LicenseMessages.activation("unreachable", [:]))
        }
        // PENDING: the app works, but this machine is not in the key's pool and has not counted
        // against its limit. checkIfDue() retries /activate every launch until the server answers.
        var patch = identity
        patch.merge([
            "licenseActivationPending": .bool(true),
            "licenseActivationError": .null,
            "licenseActivationMachinesUsed": .null,
            "licenseActivationMachineLimit": .null,
            "licenseValidated": .bool(false),
            "licenseServerConfirmed": .bool(false),
            "licenseLastValidatedAt": .null,
        ]) { $1 }
        do { try await storage.write(patch) } catch {
            throw ActivationStorageError(afterRequest: true, underlying: error)
        }
        return .activated(email: email, licenseType: licenseType, serverConfirmed: false, pending: true)
    }

    /// Local only. Clears the license fields but keeps `licenseMachineId`, so re-entering a key
    /// reuses the same slot. The worker has no deactivate endpoint by design.
    public func deactivate() async throws {
        try await storage.write(Self.clearedFields)
    }
}
