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
struct KeychainStore {
    let service: String

    /// Licensing: the trial timestamps and the stored license key. `machineId` deliberately does
    /// NOT live here — it is not security-sensitive (see LicenseManager).
    static let license = KeychainStore(service: "tools.graviton.manifold.license")

    /// Stream secrets: one SRT passphrase per saved bookmark, keyed by the bookmark's UUID. See
    /// `StreamBookmarkStore`, which owns the write and the matching delete.
    static let streams = KeychainStore(service: "tools.graviton.manifold.streams")

    /// Upsert. Returns whether the value is now stored — CHECK IT when the caller is about to
    /// discard its own copy: `StreamBookmarkStore.migratePassphrasesToKeychain` gates the removal
    /// of the plaintext on exactly this result.
    @discardableResult
    func set(_ value: String, for account: String) -> Bool {
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

    func get(_ account: String) -> String? {
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

    func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
