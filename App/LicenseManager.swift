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

// MARK: - Trial (7-day, Keychain-backed, tamper-resistant)

struct TrialStatus {
    var active: Bool
    var daysRemaining: Int
    /// True when the trial period has ended OR was voided by a detected clock rollback.
    var expired: Bool
    /// True when the trial clock COULD NOT BE READ — the Keychain refused us, so we do not know
    /// whether a trial was ever started or how much of it is left.
    ///
    /// ⚠️ THIS IS NOT `expired`, AND IT IS NOT `active` EITHER. It is the third answer, and the
    /// caller must not fold it into either of the other two: folding it into `expired` locks out a
    /// user whose trial is fine, and folding it into `active` hands a fresh trial to anyone who can
    /// make a Keychain read fail. See `LicenseManager.bootstrap`, which holds instead of deciding.
    var unreadable: Bool = false

    static let unknown = TrialStatus(active: false, daysRemaining: 0, expired: false, unreadable: true)
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
    ///
    /// ── THE FIRST READ IS THE DANGEROUS ONE ─────────────────────────────────────────────────
    ///
    /// This function's "first ever launch" branch WRITES a new trial start. That is correct when
    /// the item is genuinely absent and catastrophic when it merely could not be read: a refused
    /// read would silently restart the 7-day clock, which is the exact tamper the Keychain
    /// placement was chosen to prevent, and it would do it on the honest user's machine rather
    /// than the dishonest one's. So `.failed` returns `.unknown` and writes NOTHING — no stamp, no
    /// advance, no void. The next launch tries again against a keychain that may well be unlocked
    /// by then.
    static func recordLaunchAndEvaluate(now: Date = Date()) -> TrialStatus {
        let nowT = now.timeIntervalSince1970

        let first = KeychainStore.license.read(kFirstLaunch)
        if let status = first.failureStatus {
            NSLog("[LICENSE] trial clock unreadable (%@) — holding, no trial stamped",
                  keychainStatusDescription(status))
            return .unknown
        }

        // First ever launch: stamp the trial start. Reached ONLY on a confirmed `.absent` — see
        // above. Keychain persistence means a reinstall lands here only if the item was truly
        // removed (Keychain items outlive the app bundle).
        guard let firstStr = first.value, let firstT = Double(firstStr) else {
            KeychainStore.license.set(String(nowT), for: kFirstLaunch)
            KeychainStore.license.set(String(nowT), for: kLastSeen)
            return TrialStatus(active: true, daysRemaining: trialDays(elapsed: 0), expired: false)
        }

        // A refused read of the void flag must not be read as "not voided" — that would be a way
        // to un-void a trial by breaking a read. Unknown means hold, same as above.
        let voidedRead = KeychainStore.license.read(kVoided)
        if let status = voidedRead.failureStatus {
            NSLog("[LICENSE] trial void flag unreadable (%@) — holding", keychainStatusDescription(status))
            return .unknown
        }
        var voided = (voidedRead.value == "1")

        // Rollback check: the wall clock reading BEFORE last-seen (beyond tolerance) means someone
        // set the clock back to stretch the trial. Void it rather than reward the rollback.
        let lastRead = KeychainStore.license.read(kLastSeen)
        if let status = lastRead.failureStatus {
            NSLog("[LICENSE] trial last-seen unreadable (%@) — holding", keychainStatusDescription(status))
            return .unknown
        }
        if let lastStr = lastRead.value, let lastT = Double(lastStr) {
            if nowT < lastT - rollbackTolerance {
                voided = true
                KeychainStore.license.set("1", for: kVoided)
            }
            // Advance last-seen monotonically: never let it move backward.
            KeychainStore.license.set(String(max(nowT, lastT)), for: kLastSeen)
        } else {
            KeychainStore.license.set(String(nowT), for: kLastSeen)
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
        KeychainStore.license.delete(kFirstLaunch)
        KeychainStore.license.delete(kLastSeen)
        KeychainStore.license.delete(kVoided)
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

// MARK: - Durable activation record (the Keychain half of the licence state)

/// Everything about an activation that used to exist ONLY as `@AppStorage` booleans in
/// `~/Library/Preferences/com.graviton.manifold.plist`.
///
/// ── WHY THIS TYPE EXISTS: THE STATE WAS SPLIT ACROSS TWO STORES OF DIFFERENT DURABILITY ─────
///
/// The signed licence key was in the Keychain — tamper-resistant, survives app deletion, survives
/// reinstall. The three facts that DECIDED whether the app was licensed were in a preferences
/// plist:
///
///     license.activated   ← the gate
///     license.validated   ← the gate
///     license.machineId   ← the thing the server's 4-machine limit counts
///
/// and `bootstrap` read them FIRST:
///
///     if licenseActivated, let key = KeychainStore.license.get(kStoredKey) {
///
/// so if the plist boolean was false the signed key was never even looked at. A cryptographically
/// verifiable artifact was subordinate to a `Bool` in a file with none of its guarantees. Lose the
/// plist and a fully licensed user is shown the trial-expired gate while their valid key sits
/// unread in the Keychain a function call away.
///
/// `machineId` made it worse rather than merely equally bad: it is a random UUID minted on first
/// access, so a lost plist did not just hide the licence, it minted a NEW machine id. Re-entering
/// the key then claimed a SECOND of the four machine slots — the licence appeared to recover while
/// quietly spending a slot that no amount of re-entering gets back.
///
/// So this record goes in the Keychain beside the key, and the plist keys become a cache.
///
/// ⚠️ THE KEY REMAINS THE AUTHORITY, NOT THIS RECORD. This record is unsigned — it is our own
/// bookkeeping, and anyone who can write it can write `activated: true`. It is trusted for
/// `machineId` and for display fields only. Whether the user is LICENSED is decided by
/// `LicenseCrypto.verify` over the stored key, every launch. That is why restoring from this
/// record is gated on the key verifying first (see `LicenseManager.bootstrap`).
struct ActivationRecord: Codable {
    var activated: Bool
    var validated: Bool
    var email: String
    var type: String
    var machineId: String

    /// Schema marker. Written but not enforced on read: an older app meeting a newer record should
    /// degrade to ignoring fields it does not know, never to discarding the record.
    var v: Int = 1

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> ActivationRecord? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ActivationRecord.self, from: data)
    }
}

/// What the licence subsystem resolved to on this launch. ONE VALUE, LOGGED EVERY LAUNCH AND
/// EXPORTED IN DIAGNOSTICS, because the previous version's entire observable output on the subject
/// was a DEBUG print about the public key round-tripping — which says nothing about the user.
///
/// A tester who cannot tell whether they are licensed, on trial, or failed-to-read produces a bug
/// report that we cannot tell apart either. That is what made the 0.6.0 → 0.6.1 report take a
/// signature audit to answer.
enum LicenseState: Equatable {
    case licensed(type: String)
    case trial(daysRemaining: Int)
    case trialExpired
    /// The licence exists as far as we know, and the Keychain would not let us read it.
    /// ⚠️ NEVER RENDERED AS "unlicensed" — see `LicenseManager.userFacingKeychainFault`.
    case keychainUnreadable(OSStatus)
    case unlicensed

    /// One-line rendering for the log and the diagnostics export. Deliberately terse and stable —
    /// it is meant to be greppable across testers' reports.
    var summary: String {
        switch self {
        case .licensed(let t):          return "LICENSED (\(t))"
        case .trial(let d):             return "TRIAL (\(d) day\(d == 1 ? "" : "s") remaining)"
        case .trialExpired:             return "TRIAL EXPIRED"
        case .keychainUnreadable(let s): return "KEYCHAIN UNREADABLE (\(keychainStatusDescription(s)))"
        case .unlicensed:               return "UNLICENSED (no key stored)"
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

    /// What this launch resolved to. Logged once at bootstrap and read by `DiagnosticsExport`.
    @Published private(set) var state: LicenseState = .unlicensed

    /// Set when the Keychain REFUSED a licence read (never when it merely had nothing).
    ///
    /// ⚠️ THIS IS THE FLAG THAT MUST REACH THE USER, and it is the whole point of the change: the
    /// person whose licence exists but cannot be read has to be told THAT, not told they are
    /// unlicensed. `isUsable` returns true while it is set, so they keep working; the UI explains
    /// rather than gates. See `userFacingKeychainFault`.
    @Published private(set) var keychainFaultStatus: OSStatus?

    private let kStoredKey = "storedLicenseKey"       // Keychain account for the raw MNFL- key
    private let kActivationRecord = "activationRecord" // Keychain account for the ActivationRecord JSON

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

    /// The one gate the app reads. Licensed (both flags) OR in an active trial OR we could not
    /// read the Keychain and therefore have no standing to lock anyone out.
    ///
    /// ⚠️ THE THIRD CLAUSE FAILS OPEN, DELIBERATELY. A Keychain read can fail for reasons that are
    /// entirely the user's machine's business — a keychain not yet unlocked, a denied prompt, a
    /// login keychain in a bad state — and every one of them is transient. Gating on an unknown
    /// would take a paying, licensed user and show them a wall, which is both wrong and unfixable
    /// from their side. Failing open costs us, at worst, an unlicensed user with a broken keychain
    /// getting an extra session; the banner tells them what happened either way.
    var isUsable: Bool {
        (licenseActivated && licenseValidated) || trial.active || keychainFaultStatus != nil
    }

    /// The user-facing explanation for a refused read, or nil when there is nothing to say.
    ///
    /// Says three things in order, because a message that only said the first would read as an
    /// accusation: it is not their fault, they have not lost anything, and they are not blocked.
    var userFacingKeychainFault: String? {
        guard let status = keychainFaultStatus else { return nil }
        return """
               Manifold couldn't read your license from the Keychain (\(keychainStatusDescription(status))).                This does not mean your license is gone — it is still stored, and nothing has been                changed or removed. Manifold is running normally in the meantime. Quitting and                reopening usually clears it; if it keeps happening, send a diagnostics report                (Help ▸ Export Diagnostics…) rather than re-entering your key.
               """
    }

    /// Call once at launch. Evaluates the trial, re-verifies any stored key offline (so offline
    /// users stay licensed), reconciles the Keychain and the preferences cache, then does a
    /// best-effort online revocation check.
    ///
    /// ── THE ORDER OF THIS FUNCTION IS THE FIX, NOT AN INCIDENTAL DETAIL ─────────────────────
    ///
    /// It used to open with `if licenseActivated, let key = …` — a preferences boolean guarding
    /// the read of a signed artifact. It now reads the KEY FIRST and lets the signature decide,
    /// because the signature is the stronger evidence and always was. A licensed user who loses
    /// their preferences plist is now recovered silently and completely on the next launch
    /// instead of being shown the trial-expired gate.
    func bootstrap() async {
        #if DEBUG
        if let reason = LicenseCrypto.runRoundTripSelfCheck() {
            print("[LICENSE] public-key self-check: \(reason)")
        } else {
            print("[LICENSE] public-key self-check: OK (embedded key round-trips)")
        }
        #endif

        // ── 1. Read the stored key. UNCONDITIONALLY — no plist boolean gates this any more. ──
        let keyRead = KeychainStore.license.read(kStoredKey)

        if let status = keyRead.failureStatus {
            // ── HOLD. Change nothing, decide nothing, gate nobody. ──
            //
            // We do not know whether a licence is stored, so every available action is wrong:
            // clearing activation punishes a licensed user, starting a trial rewards a broken
            // read, and gating locks out someone who may well be paid up. The published state
            // keeps whatever the cache said, `isUsable` returns true on the fault alone, and the
            // banner explains it. The trial is not even evaluated — its clock lives in the same
            // keychain that just refused us, so it would only produce a second unknown.
            keychainFaultStatus = status
            state = .keychainUnreadable(status)
            lastMessage = userFacingKeychainFault
            NSLog("[LICENSE] state: %@", state.summary)
            NSLog("[LICENSE] ⚠️ license read refused — holding all state; nothing written, nothing cleared")
            return
        }
        keychainFaultStatus = nil

        // ── 2. Trial. Safe to evaluate now: the keychain answered us once already. ──
        trial = TrialManager.recordLaunchAndEvaluate()
        if trial.unreadable {
            // The key read succeeded and the trial clock did not — a narrow window, but it means
            // the same thing and gets the same treatment.
            keychainFaultStatus = errSecAuthFailed
            state = .keychainUnreadable(errSecAuthFailed)
            lastMessage = userFacingKeychainFault
            NSLog("[LICENSE] state: %@", state.summary)
            return
        }

        // ── 3. The key is the authority. Verify it offline and let it restore the rest. ──
        if let key = keyRead.value, case .success(let payload) = LicenseCrypto.verify(licenseKey: key) {
            let record = readActivationRecord()

            // A stored key that verifies means this install activated at some point: nothing else
            // can put a correctly signed key in this account. So activation is restored from the
            // signature, NOT from the plist — which is exactly the recovery the old order missed.
            email = payload.email; emailStore = payload.email
            licenseType = payload.licenseType; typeStore = payload.licenseType.rawValue
            setActivated(true)
            setValidated(true)

            // Machine id: the Keychain copy wins when there is one, so a lost plist stops minting
            // a new id and burning a second machine slot.
            if let stored = record?.machineId, !stored.isEmpty, stored != machineIdStore {
                NSLog("[LICENSE] restored machine id from the Keychain (preferences copy was %@)",
                      machineIdStore.isEmpty ? "missing" : "different")
                machineIdStore = stored
            }

            migrateActivationRecordIfNeeded(existing: record)

            state = .licensed(type: licenseType.display)
            NSLog("[LICENSE] state: %@", state.summary)

            // Best-effort revocation check. Only a definite "revoked" clears validation.
            await refreshValidation()
            return
        }

        // ── 4. No usable key. Report the trial honestly. ──
        if keyRead.value != nil {
            // Present but did not verify: corrupt or tampered. Say so rather than pretending the
            // account is empty — "your key is unreadable" and "you never had one" are different
            // sentences and the user can act on only one of them.
            NSLog("[LICENSE] ⚠️ a stored key is present but failed offline verification")
            lastMessage = "Your stored license key could not be verified. Please re-enter it, or contact support."
        }
        setValidated(false)
        state = trial.active ? .trial(daysRemaining: trial.daysRemaining)
                             : (trial.expired ? .trialExpired : .unlicensed)
        NSLog("[LICENSE] state: %@", state.summary)
    }

    // MARK: - Activation record: read, and the one-way migration into it

    private func readActivationRecord() -> ActivationRecord? {
        let read = KeychainStore.license.read(kActivationRecord)
        if let status = read.failureStatus {
            // Not fatal and not a hold: the key already verified, so we are licensed either way.
            // The record only carries machineId and display fields.
            NSLog("[LICENSE] activation record unreadable (%@) — continuing on the key alone",
                  keychainStatusDescription(status))
            return nil
        }
        guard let json = read.value else { return nil }
        return ActivationRecord.decode(json)
    }

    /// Writes the durable activation record when it is missing or stale.
    ///
    /// ── ORDERING: THIS MIGRATION IS ADDITIVE, SO THERE IS NO DESTRUCTIVE STEP TO GET WRONG ──
    ///
    /// `StreamBookmarkStore.migratePassphrasesToKeychain` had to move a secret that existed in
    /// exactly one place, so it is written write-then-verify-then-strip and leaves the original
    /// byte-for-byte alone on any failure. The same discipline applies here, and this migration
    /// takes its strongest possible form: IT NEVER DELETES THE OLD COPY AT ALL.
    ///
    ///   1. Read the existing record (already done by the caller).
    ///   2. Write the new one. If the write fails — locked keychain, denied ACL, full disk —
    ///      return. Nothing has changed.
    ///   3. READ IT BACK and confirm it decodes to what we just wrote. A write that reports
    ///      success and does not read back is the failure the stream migration exists to guard
    ///      against, and it is cheap to rule out.
    ///   4. Do nothing else. The `@AppStorage` keys stay exactly where they are, forever.
    ///
    /// Step 4 is the deliberate part. The plist keys cost nothing to keep, they remain a useful
    /// redundant cache, and keeping them means a user who DOWNGRADES to 0.6.1 still launches
    /// licensed — a build that has never heard of the activation record still finds the booleans
    /// it expects. There is no window, at any point in this function, in which a licence exists in
    /// neither store. A partial failure leaves the user exactly as they were.
    private func migrateActivationRecordIfNeeded(existing: ActivationRecord?) {
        let desired = ActivationRecord(activated: true,
                                       validated: licenseValidated,
                                       email: email,
                                       type: licenseType.rawValue,
                                       machineId: machineId)

        if let existing,
           existing.activated == desired.activated,
           existing.machineId == desired.machineId,
           existing.email == desired.email,
           existing.type == desired.type {
            return   // already current
        }

        guard let json = desired.encoded() else {
            NSLog("[LICENSE] ⚠️ could not encode the activation record — preferences copy retained")
            return
        }

        let status = KeychainStore.license.write(json, for: kActivationRecord)
        guard status == errSecSuccess else {
            NSLog("[LICENSE] ⚠️ activation record write failed (%@) — nothing removed, will retry next launch",
                  keychainStatusDescription(status))
            return
        }

        // Confirm it reads back before calling this migrated.
        guard let echo = KeychainStore.license.read(kActivationRecord).value,
              let decoded = ActivationRecord.decode(echo),
              decoded.machineId == desired.machineId else {
            NSLog("[LICENSE] ⚠️ activation record did not read back after a successful write — "
                  + "treating as not migrated; preferences copy retained")
            return
        }

        NSLog("[LICENSE] activation record %@ in the Keychain (machine id now durable)",
              existing == nil ? "created" : "updated")
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
            // ⚠️ THE WRITE IS CHECKED. It used to be a bare `set(...)` whose @discardableResult was
            // dropped: a failed write left the app reporting "Activated. Welcome!" with the flags
            // set and NO key stored anywhere — licensed on the strength of a plist boolean, with
            // nothing to re-verify on the next launch and a machine slot already spent server-side.
            let writeStatus = KeychainStore.license.write(key, for: kStoredKey)
            guard writeStatus == errSecSuccess else {
                NSLog("[LICENSE] ⚠️ activation succeeded on the server but the key could not be stored (%@)",
                      keychainStatusDescription(writeStatus))
                lastMessage = """
                              Your license was accepted, but Manifold couldn't save it to the Keychain                               (\(keychainStatusDescription(writeStatus))). This machine has been                               registered, so don't re-activate — quit, reopen, and enter the key once                               more. If that fails, send a diagnostics report.
                              """
                return
            }
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
            keychainFaultStatus = nil
            state = .licensed(type: licenseType.display)
            // Write the durable record now rather than waiting for the next bootstrap, so a crash
            // between activating and relaunching cannot leave the machine id living only in the plist.
            migrateActivationRecordIfNeeded(existing: readActivationRecord())
            NSLog("[LICENSE] state: %@", state.summary)
        case .failure(let code):
            lastMessage = code.message
        case .networkError(let msg):
            lastMessage = msg + " Your internet connection may be down — try again."
        }
    }

    /// Periodic/at-launch revocation check. Network/ambiguous → leave state ALONE (offline users must
    /// not be punished). A definite `revoked` clears validation → the app gates on next usability read.
    func refreshValidation() async {
        // A refused read here is a no-op by design: we cannot revalidate what we cannot read, and
        // the one thing we must not do is treat that as grounds to clear anything.
        guard licenseActivated, let key = KeychainStore.license.read(kStoredKey).value else { return }
        switch await LicenseService.validate(key: key, machineId: machineId) {
        case .valid:
            setValidated(true)
        case .invalid(let code):
            if code == .revoked || code == .invalidKey {
                setValidated(false)
                lastMessage = code.message
                state = trial.active ? .trial(daysRemaining: trial.daysRemaining) : .trialExpired
                NSLog("[LICENSE] validation cleared by the server (%@) — state: %@",
                      code.rawValue, state.summary)
            }
            // Other definite-invalids are conservative no-ops here (avoid false lockouts on odd codes).
        case .networkError:
            break   // ambiguous — do nothing
        }
    }

    /// Clears LOCAL activation only. Per the Graviton docs the server still counts this machine until
    /// an admin deregisters it — so we surface that, and we do NOT touch the trial.
    func deactivate() {
        // BOTH stores, or bootstrap's key-first order would restore from whichever survived.
        KeychainStore.license.delete(kStoredKey)
        KeychainStore.license.delete(kActivationRecord)
        setActivated(false)
        setValidated(false)
        keychainFaultStatus = nil
        state = trial.active ? .trial(daysRemaining: trial.daysRemaining)
                             : (trial.expired ? .trialExpired : .unlicensed)
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
            // ⚠️ BEFORE the status row and before key entry. Someone whose licence could not be
            // read must be told that FIRST — otherwise the next thing they see is a key field,
            // which is the app telling them they are unlicensed when it does not know that.
            if let fault = license.userFacingKeychainFault {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Your license couldn’t be read", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(fault)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            statusRow
            // The `keychainFaultStatus == nil` clause is the point: no key entry while the read is
            // merely refused. Offering the field would invite a re-activation that spends a second
            // machine slot to fix a problem that is not a licensing problem at all.
            if !(license.licenseActivated && license.licenseValidated), license.keychainFaultStatus == nil {
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
        if license.keychainFaultStatus != nil {
            LabeledContent("Status") {
                Text("Couldn’t read the Keychain — status unknown").foregroundStyle(.orange)
            }
        } else if license.licenseActivated && license.licenseValidated {
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
                // Belt and braces: `isUsable` already returns true on a fault, so this view should
                // be unreachable in that state. If a future edit to `isUsable` breaks that, the
                // gate says the true thing rather than the accusatory one.
                if let fault = license.userFacingKeychainFault {
                    Text(fault)
                        .font(.callout).foregroundStyle(.orange)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
