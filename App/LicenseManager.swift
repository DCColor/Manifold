//
//  LicenseManager.swift
//  Manifold — App-layer licensing subsystem (NOT ManifoldCore; licensing is not an engine concern).
//
//  Wires Manifold into the Graviton.tools license system (Cloudflare Worker at
//  license.graviton.tools). First Swift integration of a pattern already proven in the Electron
//  products (Scaffold/GradeShare/Flip). Ed25519-signed keys, offline-verify + online-activate,
//  server-enforced 4-machine limit, three license types (standard / beta / nfr).
//
//  Design in one paragraph:
//   • Offline verify (CryptoKit Ed25519, embedded PUBLIC key) proves a key is well-formed, signed by
//     the worker, and untampered. It CANNOT see revocation — that is server-only, by design.
//   • Two flags: `licenseActivated` is STICKY (survives outages, only user-deactivation clears it);
//     `licenseValidated` is REFRESHABLE (offline-verify or /validate sets it, only a DEFINITE
//     invalid — e.g. revoked — clears it). "Licensed" = BOTH true. Ambiguity/offline never punishes.
//   • Trial is 7 days, client-side, tamper-resistant: first-launch + last-seen live in the KEYCHAIN
//     so a reinstall can't reset it and a clock rollback can't extend it.
//   • The app is USABLE when (licenseActivated && licenseValidated) || trialActive. Otherwise the
//     licensing gate blocks the app until a key activates.
//
//  SECURITY: only the PUBLIC key is embedded (see `LicenseCrypto.embeddedPublicKeyBase64`). The
//  private key must NEVER appear in Manifold source or binary.
//

import Foundation
import Security
import CryptoKit
import SwiftUI

// MARK: - Keychain (small generic-password wrapper)

/// Minimal Keychain access for the licensing subsystem. Used for values that must resist casual
/// tampering or survive app deletion: the trial timestamps and the stored license key. `machineId`
/// deliberately does NOT live here — it is not security-sensitive (see LicenseManager).
enum LicenseKeychain {
    private static let service = "tools.graviton.manifold.license"

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Upsert: try update first, add if absent.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Trial (7-day, Keychain-backed, tamper-resistant)

struct TrialStatus {
    var active: Bool
    var daysRemaining: Int
    /// True when the trial period has ended OR was voided by a detected clock rollback.
    var expired: Bool
}

/// Evaluates the client-side trial. First-launch and last-seen timestamps live in the Keychain so
/// they survive app deletion/reinstall (a tester can't reset the trial by reinstalling), and a
/// system-clock rollback is treated as tamper (voids the trial) rather than a way to extend it.
enum TrialManager {
    static let trialDuration: TimeInterval = 7 * 24 * 60 * 60   // 7 days
    /// Small backward drift is normal (NTP corrections, DST). Only a rollback beyond this voids.
    private static let rollbackTolerance: TimeInterval = 5 * 60

    private static let kFirstLaunch = "trial.firstLaunch"
    private static let kLastSeen    = "trial.lastSeen"
    private static let kVoided      = "trial.voided"

    /// Records this launch (advancing last-seen, detecting rollback) and returns the trial status.
    /// Call once at launch, before computing usability.
    static func recordLaunchAndEvaluate(now: Date = Date()) -> TrialStatus {
        let nowT = now.timeIntervalSince1970

        // First ever launch: stamp the trial start. Keychain persistence means a reinstall lands here
        // only if the item was truly removed (Keychain items outlive the app bundle).
        guard let firstStr = LicenseKeychain.get(kFirstLaunch), let firstT = Double(firstStr) else {
            LicenseKeychain.set(String(nowT), for: kFirstLaunch)
            LicenseKeychain.set(String(nowT), for: kLastSeen)
            return TrialStatus(active: true, daysRemaining: trialDays(elapsed: 0), expired: false)
        }

        var voided = (LicenseKeychain.get(kVoided) == "1")

        // Rollback check: the wall clock reading BEFORE last-seen (beyond tolerance) means someone
        // set the clock back to stretch the trial. Void it rather than reward the rollback.
        if let lastStr = LicenseKeychain.get(kLastSeen), let lastT = Double(lastStr) {
            if nowT < lastT - rollbackTolerance {
                voided = true
                LicenseKeychain.set("1", for: kVoided)
            }
            // Advance last-seen monotonically: never let it move backward.
            LicenseKeychain.set(String(max(nowT, lastT)), for: kLastSeen)
        } else {
            LicenseKeychain.set(String(nowT), for: kLastSeen)
        }

        let elapsed = max(0, nowT - firstT)
        let expired = voided || elapsed >= trialDuration
        return TrialStatus(active: !expired, daysRemaining: trialDays(elapsed: elapsed), expired: expired)
    }

    private static func trialDays(elapsed: TimeInterval) -> Int {
        let remaining = trialDuration - elapsed
        guard remaining > 0 else { return 0 }
        // Ceil so the final partial day reads "1 day left", not "0".
        return Int((remaining / (24 * 60 * 60)).rounded(.up))
    }

    /// Test/support hook — not wired to any UI. Clears trial state (a fresh install simulation).
    static func resetForTesting() {
        LicenseKeychain.delete(kFirstLaunch)
        LicenseKeychain.delete(kLastSeen)
        LicenseKeychain.delete(kVoided)
    }
}

// MARK: - Embedded public key + offline Ed25519 verify

enum LicenseVerifyError: Error, Equatable {
    case notEmbedded          // no public key compiled in (developer error — build with the key)
    case badFormat            // not MNFL-<payload>.<sig>
    case badSignature         // signature did not verify against the embedded public key
    case badPayload           // signature OK but payload JSON unreadable
}

/// The signed license payload (fields are informational once the signature checks out — the
/// signature, not the payload, is the trust boundary). Parsed leniently via JSONSerialization
/// because the worker owns the exact JSON and this is the first Swift consumer.
struct LicensePayload {
    var email: String
    var product: String
    var licenseType: LicenseType
    var issued: String?
    var expires: String?

    init?(json: [String: Any]) {
        guard let email = json["email"] as? String else { return nil }
        self.email = email
        self.product = (json["product"] as? String) ?? ""
        self.licenseType = LicenseType(rawValue: (json["licenseType"] as? String) ?? "")
        self.issued = LicensePayload.stringify(json["issued"])
        self.expires = LicensePayload.stringify(json["expires"])
    }

    private static func stringify(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let d as Double: return String(Int(d))
        case let i as Int:    return String(i)
        default:              return nil
        }
    }
}

enum LicenseType: String {
    case standard, beta, nfr, unknown
    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "standard": self = .standard
        case "beta":     self = .beta
        case "nfr":      self = .nfr
        default:         self = .unknown
        }
    }
    var display: String {
        switch self {
        case .standard: return "Standard"
        case .beta:     return "Beta"
        case .nfr:      return "NFR"
        case .unknown:  return "License"
        }
    }
}

enum LicenseCrypto {
    static let keyPrefix = "MNFL-"

    // ────────────────────────────────────────────────────────────────────────────────────────
    //  EMBEDDED Ed25519 PUBLIC KEY — RAW 32 bytes, base64.
    //
    //  CryptoKit's Curve25519.Signing.PublicKey wants the raw 32-byte key, NOT the PEM/DER that
    //  openssl emits. Convert the PEM to raw with:
    //
    //      openssl pkey -pubin -in keys/manifold-public.pem -outform DER | tail -c 32 | base64
    //
    //  (Ed25519 SPKI DER is a fixed 12-byte prefix + the 32-byte key; `tail -c 32` drops the prefix.)
    //  Paste the resulting base64 below. `runRoundTripSelfCheck()` confirms it re-encodes byte-for-byte.
    //
    //  ⚠️ PUBLIC KEY ONLY. Never embed the private key — a sibling product leaked its private key and
    //  had to rotate the whole keypair. Do not repeat that.
    //
    //  Real Manifold Ed25519 public key. Source PEM (SPKI):
    //      MCowBQYDK2VwAyEATqFHmOnArbNaeJc+kYeo5eHnuEabp/1SX6NihE76Hy4=
    //  Raw 32 bytes below verified to round-trip (Curve25519.Signing.PublicKey rebuilds + re-encodes
    //  byte-for-byte). See runRoundTripSelfCheck().
    // ────────────────────────────────────────────────────────────────────────────────────────
    static let embeddedPublicKeyBase64 = "TqFHmOnArbNaeJc+kYeo5eHnuEabp/1SX6NihE76Hy4="

    static var isKeyEmbedded: Bool { !embeddedPublicKeyBase64.isEmpty }

    /// The embedded verifying key, or nil if none is compiled in (or the constant is malformed).
    static var publicKey: Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: embeddedPublicKeyBase64), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// Confirms the embedded key round-trips: decodes to 32 bytes, builds a PublicKey, and the key's
    /// rawRepresentation re-encodes to the exact same base64 we embedded. Returns nil on success or a
    /// human-readable reason on failure. Called in DEBUG at launch (see LicenseManager.bootstrap).
    static func runRoundTripSelfCheck() -> String? {
        guard isKeyEmbedded else { return "no public key embedded (embeddedPublicKeyBase64 is empty)" }
        guard let raw = Data(base64Encoded: embeddedPublicKeyBase64) else { return "embedded base64 does not decode" }
        guard raw.count == 32 else { return "embedded key is \(raw.count) bytes, expected 32" }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return "CryptoKit rejected the 32-byte key" }
        guard key.rawRepresentation.base64EncodedString() == embeddedPublicKeyBase64 else { return "round-trip mismatch (re-encoded key ≠ embedded constant)" }
        return nil
    }

    /// Offline verify: MNFL-<base64url payload>.<base64url signature>. Verifies the Ed25519 signature
    /// over the payload BYTES with the embedded public key, then parses the payload JSON. Proves
    /// well-formed + signed + untampered; says nothing about revocation (server-only).
    static func verify(licenseKey rawKey: String) -> Result<LicensePayload, LicenseVerifyError> {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix(keyPrefix) else { return .failure(.badFormat) }
        let body = String(key.dropFirst(keyPrefix.count))
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadBytes = base64urlDecode(String(parts[0])),
              let sigBytes = base64urlDecode(String(parts[1])) else { return .failure(.badFormat) }

        guard let publicKey else { return .failure(.notEmbedded) }
        guard publicKey.isValidSignature(sigBytes, for: payloadBytes) else { return .failure(.badSignature) }

        guard let obj = try? JSONSerialization.jsonObject(with: payloadBytes) as? [String: Any],
              let payload = LicensePayload(json: obj) else { return .failure(.badPayload) }
        return .success(payload)
    }

    /// base64url (RFC 4648 §5) → Data: URL-safe alphabet, padding optional.
    static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: b64)
    }
}

// MARK: - Network service (/activate, /validate)

/// Server error codes, mapped to user-facing copy. `.unknown` covers anything the worker adds later.
enum LicenseErrorCode: String {
    case maxMachines      = "max_machines"
    case invalidKey       = "invalid_key"
    case invalidSignature = "invalid_signature"
    case revoked          = "revoked"
    case unknown

    init(serverValue: String?) {
        self = LicenseErrorCode(rawValue: serverValue ?? "") ?? .unknown
    }

    var message: String {
        switch self {
        case .maxMachines:      return "This license is already on the maximum of 4 machines. Deactivate another machine (or ask an admin to deregister one) and try again."
        case .invalidKey:       return "That license key wasn't recognized. Check for typos and try again."
        case .invalidSignature: return "That license key failed verification. Make sure you pasted the whole key."
        case .revoked:          return "This license has been revoked. Contact support if you believe this is a mistake."
        case .unknown:          return "The license server reported a problem with this key."
        }
    }
}

struct ActivateSuccess {
    var email: String
    var licenseType: LicenseType
    var machinesUsed: Int?
    var machineLimit: Int?
    var alreadyRegistered: Bool
}

enum ActivateOutcome {
    case success(ActivateSuccess)
    case failure(LicenseErrorCode)
    case networkError(String)   // could not reach/parse — NOT a rejection
}

enum ValidateOutcome {
    case valid
    case invalid(LicenseErrorCode)   // DEFINITE invalid (e.g. revoked)
    case networkError                // ambiguous — leave state alone
}

/// Thin async client. Never throws to callers — every path resolves to a typed outcome so the
/// manager can apply the sticky/refreshable rules without try/catch at the policy layer.
enum LicenseService {
    private static let base = URL(string: "https://license.graviton.tools")!
    private static let slug = "manifold"

    static func activate(key: String, machineId: String) async -> ActivateOutcome {
        guard let dict = await post(path: "/\(slug)/activate", body: ["key": key, "machineId": machineId]) else {
            return .networkError("Couldn't reach the license server.")
        }
        if (dict["ok"] as? Bool) == true {
            let email = (dict["email"] as? String) ?? ""
            let type = LicenseType(rawValue: (dict["licenseType"] as? String) ?? "")
            return .success(ActivateSuccess(
                email: email,
                licenseType: type,
                machinesUsed: dict["machinesUsed"] as? Int,
                machineLimit: dict["machineLimit"] as? Int,
                alreadyRegistered: (dict["alreadyRegistered"] as? Bool) ?? false))
        }
        return .failure(LicenseErrorCode(serverValue: dict["error"] as? String))
    }

    static func validate(key: String, machineId: String) async -> ValidateOutcome {
        guard let dict = await post(path: "/\(slug)/validate", body: ["key": key, "machineId": machineId]) else {
            return .networkError
        }
        if (dict["valid"] as? Bool) == true { return .valid }
        // Only a definite server "invalid" clears state. Treat a missing/ambiguous body as network-ish
        // (leave state alone) — never punish an offline or half-answered user.
        if dict["valid"] is Bool { return .invalid(LicenseErrorCode(serverValue: dict["error"] as? String)) }
        return .networkError
    }

    private static func post(path: String, body: [String: String]) async -> [String: Any]? {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}

// MARK: - LicenseManager (orchestrator + published state)

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    // Sticky: true after /activate succeeds; only user-deactivation clears it. Survives outages.
    @AppStorage("license.activated") private var activatedStore = false
    // Refreshable: offline-verify or /validate sets it; only a DEFINITE invalid clears it.
    @AppStorage("license.validated") private var validatedStore = false
    // Display cache (not trusted — the stored key + signature are authoritative).
    @AppStorage("license.email") private var emailStore = ""
    @AppStorage("license.type") private var typeStore = ""
    // Persistent per-install machine id. UserDefaults is fine — it is not security-sensitive; it just
    // needs to be stable for the install's lifetime. Generated once, lazily.
    @AppStorage("license.machineId") private var machineIdStore = ""

    // Published mirrors for SwiftUI (AppStorage in a class doesn't drive objectWillChange reliably
    // across all consumers, so the manager owns explicit @Published snapshots).
    @Published private(set) var licenseActivated = false
    @Published private(set) var licenseValidated = false
    @Published private(set) var email = ""
    @Published private(set) var licenseType: LicenseType = .unknown
    @Published private(set) var trial = TrialStatus(active: false, daysRemaining: 0, expired: true)
    @Published var isWorking = false          // an activate/validate call is in flight (drives UI)
    @Published var lastMessage: String?       // last user-facing error/status (drives UI)

    private let kStoredKey = "storedLicenseKey"   // Keychain account for the raw MNFL- key

    private init() {
        licenseActivated = activatedStore
        licenseValidated = validatedStore
        email = emailStore
        licenseType = LicenseType(rawValue: typeStore)
    }

    /// The stable per-install machine id (generated once on first access).
    var machineId: String {
        if machineIdStore.isEmpty { machineIdStore = UUID().uuidString }
        return machineIdStore
    }

    /// The one gate the app reads. Licensed (both flags) OR in an active trial.
    var isUsable: Bool { (licenseActivated && licenseValidated) || trial.active }

    /// Call once at launch. Evaluates the trial, re-verifies any stored key offline (so offline users
    /// stay licensed), then does a best-effort online revocation check.
    func bootstrap() async {
        #if DEBUG
        if let reason = LicenseCrypto.runRoundTripSelfCheck() {
            print("[LICENSE] public-key self-check: \(reason)")
        } else {
            print("[LICENSE] public-key self-check: OK (embedded key round-trips)")
        }
        #endif

        trial = TrialManager.recordLaunchAndEvaluate()

        // Offline path: a stored key that still verifies keeps the user licensed with NO network.
        if licenseActivated, let key = LicenseKeychain.get(kStoredKey) {
            if case .success(let payload) = LicenseCrypto.verify(licenseKey: key) {
                email = payload.email; emailStore = payload.email
                licenseType = payload.licenseType; typeStore = payload.licenseType.rawValue
                setValidated(true)
            }
            // Best-effort revocation check. Only a definite "revoked" clears validation.
            await refreshValidation()
        }
    }

    /// Activation is inherently ONLINE (the server claims a machine slot). Offline pre-check gives a
    /// fast, friendly rejection for a malformed/wrong-signature paste before we bother the network.
    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { lastMessage = "Enter a license key."; return }

        // Local pre-check (skipped if no key is embedded yet — then the server is authoritative).
        if LicenseCrypto.isKeyEmbedded {
            switch LicenseCrypto.verify(licenseKey: key) {
            case .failure(.badFormat):
                lastMessage = "That doesn't look like a Manifold key (should start with MNFL-)."; return
            case .failure(.badSignature):
                lastMessage = LicenseErrorCode.invalidSignature.message; return
            case .failure(.notEmbedded), .failure(.badPayload), .success:
                break   // proceed to the server
            }
        }

        isWorking = true; lastMessage = nil
        defer { isWorking = false }

        switch await LicenseService.activate(key: key, machineId: machineId) {
        case .success(let s):
            LicenseKeychain.set(key, for: kStoredKey)
            email = s.email; emailStore = s.email
            licenseType = s.licenseType; typeStore = s.licenseType.rawValue
            setActivated(true)
            // Confirm validation: trust the successful activation, and corroborate with offline verify
            // when a key is embedded (so validity doesn't hinge on the next /validate round-trip).
            if LicenseCrypto.isKeyEmbedded,
               case .failure(let e) = LicenseCrypto.verify(licenseKey: key), e == .badSignature {
                setValidated(false)
                lastMessage = "Activated, but the key failed local verification — please contact support."
            } else {
                setValidated(true)
                lastMessage = s.alreadyRegistered ? "This machine was already registered — you're all set."
                                                  : "Activated. Welcome!"
            }
        case .failure(let code):
            lastMessage = code.message
        case .networkError(let msg):
            lastMessage = msg + " Your internet connection may be down — try again."
        }
    }

    /// Periodic/at-launch revocation check. Network/ambiguous → leave state ALONE (offline users must
    /// not be punished). A definite `revoked` clears validation → the app gates on next usability read.
    func refreshValidation() async {
        guard licenseActivated, let key = LicenseKeychain.get(kStoredKey) else { return }
        switch await LicenseService.validate(key: key, machineId: machineId) {
        case .valid:
            setValidated(true)
        case .invalid(let code):
            if code == .revoked || code == .invalidKey {
                setValidated(false)
                lastMessage = code.message
            }
            // Other definite-invalids are conservative no-ops here (avoid false lockouts on odd codes).
        case .networkError:
            break   // ambiguous — do nothing
        }
    }

    /// Clears LOCAL activation only. Per the Graviton docs the server still counts this machine until
    /// an admin deregisters it — so we surface that, and we do NOT touch the trial.
    func deactivate() {
        LicenseKeychain.delete(kStoredKey)
        setActivated(false)
        setValidated(false)
        email = ""; emailStore = ""
        typeStore = ""; licenseType = .unknown
        lastMessage = "Deactivated on this machine. Note: the server still counts this machine until an admin deregisters it."
    }

    // MARK: state setters keep @Published mirrors and @AppStorage in lockstep

    private func setActivated(_ v: Bool) { licenseActivated = v; activatedStore = v }
    private func setValidated(_ v: Bool) { licenseValidated = v; validatedStore = v }
}

// MARK: - Views (Settings section + gate modal)

/// The License section for the Settings window (⌘,). Shows current state and hosts key entry,
/// activation, and local deactivation. Minimal by intent — polish later.
struct LicenseSettingsSection: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var keyField = ""

    var body: some View {
        Section("License") {
            statusRow
            if !(license.licenseActivated && license.licenseValidated) {
                keyEntry
            } else {
                Button("Deactivate on this machine", role: .destructive) { license.deactivate() }
            }
            if let msg = license.lastMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        if license.licenseActivated && license.licenseValidated {
            LabeledContent("Status") {
                Text("Licensed to \(license.email.isEmpty ? "you" : license.email) · \(license.licenseType.display)")
                    .foregroundStyle(.secondary)
            }
        } else if license.trial.active {
            LabeledContent("Status") {
                Text("Trial — \(license.trial.daysRemaining) day\(license.trial.daysRemaining == 1 ? "" : "s") left")
                    .foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Status") { Text("Trial expired").foregroundStyle(.orange) }
        }
    }

    @ViewBuilder private var keyEntry: some View {
        // Paste the COMPLETE key exactly as copied (MNFL-<payload>.<signature>). The 'MNFL-' is the
        // PREFIX, not a suffix — LicenseCrypto.verify parses it off itself, so the user never strips
        // it and the app never prepends it. The placeholder shows the full shape INSIDE the empty
        // field (via `prompt:` + labelsHidden so it can't render as a right-side label/suffix).
        VStack(alignment: .leading, spacing: 8) {
            TextField("License key", text: $keyField, prompt: Text("MNFL-…"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled()
                .onSubmit { Task { await license.activate(key: keyField) } }
            HStack(spacing: 8) {
                Button("Activate") { Task { await license.activate(key: keyField) } }
                    .disabled(license.isWorking || keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if license.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Text("Paste your whole key, including “MNFL-”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The blocking gate: shown over the app when it is NOT usable (trial expired and not licensed).
/// The app's features stay unreachable behind this until a key activates.
struct LicenseGateView: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var keyField = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.circle").font(.system(size: 46)).foregroundStyle(.secondary)
                Text("Your Manifold trial has ended").font(.title2).bold()
                Text("Enter a license key to continue using Manifold.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    TextField("MNFL-…", text: $keyField)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 300)
                        .onSubmit { Task { await license.activate(key: keyField) } }
                    Button("Activate") { Task { await license.activate(key: keyField) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(license.isWorking || keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if license.isWorking { ProgressView().controlSize(.small) }
                if let msg = license.lastMessage {
                    Text(msg).font(.callout).foregroundStyle(.orange)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Need a key? Visit graviton.tools")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(maxWidth: 460)
        }
    }
}

/// Gate modifier: overlays `LicenseGateView` (opaque, hit-capturing) whenever the app isn't usable,
/// so no Manifold feature is reachable until licensed. Offline users with a valid embedded-verified
/// key are `isUsable` and never see this — network is never the gate.
private struct LicenseGate: ViewModifier {
    @ObservedObject var license: LicenseManager
    func body(content: Content) -> some View {
        ZStack {
            // Disable the whole app subtree when gated so its controls AND hidden keyboard-shortcut
            // buttons stop responding — the gate isn't just a visual veil.
            content.disabled(!license.isUsable)
            // The gate is a ZStack SIBLING (not under the disabled subtree), so its own key field
            // and Activate button stay interactive — that's how the user gets out of the gate.
            if !license.isUsable {
                LicenseGateView().transition(.opacity)
            }
        }
    }
}

extension View {
    func licenseGate(_ license: LicenseManager) -> some View { modifier(LicenseGate(license: license)) }
}
