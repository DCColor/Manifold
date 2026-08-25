//
//  KeychainStore.swift
//  Manifold — the app's one wrapper over generic-password Keychain items.
//
//  Lived in LicenseManager.swift while licensing was its only caller. It moved here when stream
//  passphrases became the second, because a type two subsystems depend on should not be reachable
//  only by reading a third one's file.
//

import Foundation
import Security

/// The outcome of a Keychain read. THREE CASES, NOT TWO, AND THAT IS THE ENTIRE POINT OF THIS TYPE.
///
/// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────────────────
///
/// `get` used to return `String?` and collapsed every `OSStatus` that was not `errSecSuccess`
/// into `nil`. That made "there is no item" and "there is an item and I was refused it"
/// indistinguishable, and every caller then picked the reading that suited it — all of which
/// were the same reading, because `nil` only affords one:
///
///   • `TrialManager` read a missing `trial.firstLaunch` as FIRST EVER LAUNCH and stamped a new
///     7-day trial. Under a denial that silently RESTARTS the trial clock, which is precisely
///     what putting the timestamps in the Keychain was supposed to make impossible.
///   • `LicenseManager.bootstrap` read a missing `storedLicenseKey` as "no key", skipped the
///     offline verify, and let a plist boolean decide whether the user was licensed.
///   • `StreamBookmarkStore.connectURL` read a missing passphrase as "this stream needs no
///     passphrase" and dialled without one, turning a readable-but-refused secret into an
///     opaque SRT handshake rejection.
///
/// None of those are recoverable from a `nil`. All three are trivially recoverable from a
/// `.failed`, because the correct response to `.failed` is always the same: CHANGE NOTHING, SAY
/// SO, AND TRY AGAIN NEXT LAUNCH. A denial is transient — a locked keychain, a denied prompt, a
/// keychain not yet unlocked at login. Treating it as absence makes a temporary condition
/// permanent, because the "absence" handler WRITES: a new trial stamp, a cleared licence, a
/// re-entered passphrase. That write is what turns a five-minute problem into a support ticket.
///
/// ⚠️ `.absent` IS THE ONLY CASE A CALLER MAY TREAT AS "NOTHING IS STORED". `.failed` means
/// SOMETHING MAY WELL BE STORED and we could not see it. Never overwrite, never delete, and
/// never re-derive state on `.failed`.
enum KeychainRead {
    /// The item exists and its value decoded.
    case found(String)
    /// `errSecItemNotFound` — the keychain was reachable and there is genuinely nothing filed
    /// under this service+account. This is the ONLY case that means "nothing is stored".
    case absent
    /// Anything else: denied (`errSecAuthFailed`, -25293), no UI available to ask
    /// (`errSecInteractionNotAllowed`, -25308), keychain locked, user cancelled the prompt
    /// (`errSecUserCanceled`, -128), or the item was found but its bytes were not valid UTF-8.
    /// An item may or may not exist; we do not know and must not guess.
    case failed(OSStatus)

    /// The value when present, `nil` for BOTH other cases. Use only where the caller has already
    /// handled `.failed` explicitly — this getter re-collapses the distinction on purpose so that
    /// reaching for it reads as a deliberate choice at the call site.
    var value: String? {
        if case .found(let s) = self { return s }
        return nil
    }

    /// The OSStatus when the read failed, `nil` when it found or confirmed absence.
    var failureStatus: OSStatus? {
        if case .failed(let s) = self { return s }
        return nil
    }

    /// True only for `.failed`. Reads better than `failureStatus != nil` at branch sites.
    var didFail: Bool { failureStatus != nil }
}

/// Renders an OSStatus for a log line or a user-facing message: the numeric code plus the
/// Security framework's own wording, which is already written for humans ("User interaction is
/// not allowed.", "The user name or passphrase you entered is not correct.").
///
/// ⚠️ The NUMBER is not decoration — it is the one token a tester can paste back to us that
/// distinguishes a denial from a lock from a cancel. Always keep it alongside the wording.
func keychainStatusDescription(_ status: OSStatus) -> String {
    let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
    return "OSStatus \(status) — \(text)"
}

/// Minimal Keychain access for any part of the app that needs a value to resist casual tampering,
/// survive app deletion, or simply stay out of a plist.
///
/// ── THE SERVICE STRING IS A NAMESPACE, AND IT IS PER-SUBSYSTEM ──────────────────────────────
///
/// `service` is stored rather than hardcoded so unrelated secrets cannot collide in the account
/// space, and — more importantly — so they cannot be enumerated or deleted together. A stream
/// passphrase filed under the licensing service would be swept up by anything that ever decides to
/// clear "the license items", and would show up under the licence's name in Keychain Access, which
/// is simply untrue. Two callers, two namespaces: `.license` and `.streams` below.
///
/// ── WHAT EVERY ITEM THIS TYPE CREATES IS, AND IS NOT ────────────────────────────────────────
///
/// Values are `String`, class `kSecClassGenericPassword`.
///
/// ACCESSIBILITY IS `kSecAttrAccessibleAfterFirstUnlock`: readable after the user has unlocked the
/// device once since boot, including by a background relaunch, and never before that.
///
/// `kSecAttrSynchronizable` IS DELIBERATELY NEVER SET, on any of the three queries below. Absent
/// means `false` — the item is local to this Mac, is not copied into iCloud Keychain, and does not
/// propagate to the user's other devices. That is the right default for both callers and it matters
/// most for the stream passphrase: a broadcast credential belongs to the machine doing the
/// monitoring, and syncing it would widen the blast radius of the very secret we moved out of the
/// preferences plist to contain. Setting it to true here would also silently split the keyspace —
/// synchronizable and non-synchronizable items with the same service+account are DIFFERENT items —
/// so a future change to this line would orphan every value already stored.
///
/// ── WHICH KEYCHAIN THESE ITEMS ACTUALLY LIVE IN, AND WHY WE CANNOT MOVE THEM ────────────────
///
/// MEASURED, not assumed: these items are in the LEGACY FILE KEYCHAIN (login.keychain-db). Two
/// confirmations — `security find-generic-password -s tools.graviton.manifold.license` finds
/// them, and that CLI searches only the file-based keychains; and dumping their ACLs returns a
/// populated trusted-application list, which the data-protection keychain does not have.
///
/// `kSecAttrAccessible` above is therefore very nearly decorative: the file keychain gates on an
/// ACL and a partition list, not on an accessibility class. It is kept because it is correct and
/// costs nothing, and because it starts meaning something the moment the item class changes.
///
/// THE OBVIOUS FIX IS NOT AVAILABLE. Apple's answer to ACL-guarded items is
/// `kSecUseDataProtectionKeychain: true`, which has no ACLs and no authorization prompts. It was
/// TRIED AND MEASURED against this app's exact signing:
///
///     signed Developer ID + hardened runtime + App/Manifold.entitlements
///         SecItemAdd(kSecUseDataProtectionKeychain: true) -> -34018 errSecMissingEntitlement
///
///     the same binary with `keychain-access-groups` added to unlock it
///         SIGKILL on launch (exit 137) — the app does not start at all
///
/// The second result is the blocker, and it is not subtle: `keychain-access-groups` is a
/// provisioned entitlement, the shipped bundle carries no `embedded.provisionprofile`, and
/// release-mac.sh exports `developer-id` with `signingStyle: automatic`, which does not embed
/// one. Adopting the data-protection keychain therefore means changing a notarised release
/// pipeline, not changing this file. DO NOT set `kSecUseDataProtectionKeychain` here without
/// doing that work first — it fails closed, at launch, on every user's machine.
///
/// What makes the file keychain survivable meanwhile is the PARTITION LIST, also measured: these
/// items carry `teamid:8UQ7MDM87B`, so any build signed by that team reads them without a
/// prompt. That is what carries a licence across an app update, and it is why the licence bug
/// this file's `KeychainRead` was written for was never actually an ACL failure.
struct KeychainStore {
    let service: String

    /// Licensing: the trial timestamps, the stored license key, and the durable activation record.
    /// `machineId` used to live only in UserDefaults; it is mirrored here now — see
    /// `LicenseManager.ActivationRecord` for why that mattered.
    static let license = KeychainStore(service: "tools.graviton.manifold.license")

    /// Stream secrets: one SRT passphrase per saved bookmark, keyed by the bookmark's UUID. See
    /// `StreamBookmarkStore`, which owns the write and the matching delete.
    static let streams = KeychainStore(service: "tools.graviton.manifold.streams")

    // MARK: - Write

    /// Upsert, returning the raw `OSStatus` so a caller that needs to explain a failure can.
    /// `errSecSuccess` means the value is stored.
    @discardableResult
    func write(_ value: String, for account: String) -> OSStatus {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Upsert: try update first, add if absent.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return errSecSuccess }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil)
        }
        // NOTE: an ACL denial surfaces here as errSecAuthFailed from SecItemUpdate, NOT as
        // errSecItemNotFound, so we do not fall through to SecItemAdd and cannot create a
        // duplicate item shadowing one we were merely refused.
        return status
    }

    /// Upsert. Returns whether the value is now stored — CHECK IT when the caller is about to
    /// discard its own copy: `StreamBookmarkStore.migratePassphrasesToKeychain` gates the removal
    /// of the plaintext on exactly this result.
    @discardableResult
    func set(_ value: String, for account: String) -> Bool {
        write(value, for: account) == errSecSuccess
    }

    // MARK: - Read

    /// Read one item, preserving the difference between "not there" and "could not look".
    ///
    /// ⚠️ THERE IS DELIBERATELY NO `String?`-RETURNING VARIANT. Every caller must say what it
    /// intends to do about `.failed`, because for all three of this app's callers the answer is
    /// materially different from what it does about `.absent`. See `KeychainRead`.
    func read(_ account: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)

        switch status {
        case errSecSuccess:
            // Found, but still two ways to not have a usable value. A non-Data payload or bytes
            // that are not UTF-8 mean the item is THERE and unreadable — which is `.failed`, not
            // `.absent`: reporting absence would invite the caller to overwrite it.
            guard let data = out as? Data else { return .failed(errSecInternalComponent) }
            guard let s = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
            return .found(s)
        case errSecItemNotFound:
            return .absent
        default:
            return .failed(status)
        }
    }

    // MARK: - Delete

    func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
