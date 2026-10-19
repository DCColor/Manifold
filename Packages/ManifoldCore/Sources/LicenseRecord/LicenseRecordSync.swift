//
//  LicenseRecordSync.swift
//  LicenseRecord — bring the Keychain activation record up to date, then (and only then) remove
//  the licence email and machine id from the preferences plist.
//
//  Privacy stage P1 (docs/PRIVACY_AUDIT.md). The rules, in the order they bind:
//
//   1. A LICENSED USER MUST NEVER BE DE-ACTIVATED BY THIS. Nothing here touches the stored key,
//      `license.activated`, `license.validated` or `license.type`, and nothing here deletes a
//      Keychain item. Licensing is decided by the signed key every launch; this only moves two
//      display/bookkeeping values from one store to another.
//   2. A plist value is removed ONLY after the record has been READ BACK from the Keychain and
//      holds the same value. Written-successfully is not enough; read-back-and-equal is.
//   3. If the Keychain read fails, the plist is left exactly as it is, and the outcome says so.
//
//  Synchronous on purpose: the app runs it on its dedicated Keychain queue (`LicenseKeychain`),
//  where blocking on `securityd` harms nobody, and the tests run it inline.
//

import Foundation

/// The two things the migration does to the preferences plist: read a string, remove a key.
/// `UserDefaults` is the real one; the tests use an in-memory store, because a scratch
/// `UserDefaults` suite leaves an empty plist in ~/Library/Preferences that cfprefsd writes after
/// the test process has exited (measured, P1) — so it cannot be cleaned up from the test.
public protocol LegacyLicenseStore {
    func string(forKey key: String) -> String?
    func removeObject(forKey key: String)
}

extension UserDefaults: LegacyLicenseStore {}

public enum LicenseRecordSync {

    /// The two plist keys this stage retires. Read by the migration, removed by the migration,
    /// and written by nothing.
    public static let legacyEmailKey = "license.email"
    public static let legacyMachineIdKey = "license.machineId"

    /// What a run did. `log` lines carry NO email and NO machine id — they say what happened to
    /// which key and why, which is all a diagnostics export needs.
    public struct Outcome: Equatable {
        /// The machine id to use from now on: the record's, else the legacy plist value, else
        /// nil (the caller mints one when it needs one). Never minted here unless `licensed`.
        public var machineId: String?
        /// The record as read back after any write — the display source for the email.
        public var record: ActivationRecord?
        public var removedKeys: [String] = []
        public var keptKeys: [String] = []
        public var log: [String] = []
        /// True when a Keychain read or write failed. Nothing was removed.
        public var keychainFailed = false
    }

    /// What the licence manager knows when it calls this.
    public struct Current {
        /// The stored key verified this launch (or activation just succeeded).
        public var licensed: Bool
        public var validated: Bool
        /// From the verified key's payload. Ignored unless `licensed`.
        public var email: String
        public var type: String
        /// Activation is about to send the machine id to the server: make sure there IS one, and
        /// that it is in the Keychain BEFORE the request goes out. If the server registers this
        /// machine and the reply is lost, the retry must present the same id, or it spends a
        /// second machine slot. (The plist used to do this job, by accident, from first access.)
        public var reserveMachineId: Bool

        public init(licensed: Bool, validated: Bool = false, email: String = "", type: String = "",
                    reserveMachineId: Bool = false) {
            self.licensed = licensed
            self.validated = validated
            self.email = email
            self.type = type
            self.reserveMachineId = reserveMachineId
        }
    }

    /// Reads the legacy plist values. Empty strings count as present: they are still keys in the
    /// plist, and removing them is part of the job.
    public static func legacyValues(in defaults: LegacyLicenseStore) -> (email: String?, machineId: String?) {
        (defaults.string(forKey: legacyEmailKey), defaults.string(forKey: legacyMachineIdKey))
    }

    /// One pass. `read` and `write` reach the `activationRecord` account of the licence Keychain
    /// service; `write` returns an OSStatus (0 = errSecSuccess). `mint` makes a new machine id,
    /// used only for a licensed install that has none anywhere (what the app always did).
    public static func run(defaults: LegacyLicenseStore,
                           current: Current,
                           read: () -> RecordRead,
                           write: (String) -> Int32,
                           mint: () -> String = { UUID().uuidString }) -> Outcome {
        var out = Outcome()
        let legacy = legacyValues(in: defaults)
        let legacyPresent = legacy.email != nil || legacy.machineId != nil

        // Nothing to move and nothing to keep current: an unlicensed install with a clean plist
        // makes no Keychain round trip at all, as before.
        guard current.licensed || current.reserveMachineId || legacyPresent else { return out }

        // ── 1. Read what is there. ──
        let existingRead = read()
        if case .failed(let status) = existingRead {
            out.keychainFailed = true
            out.machineId = nonEmpty(legacy.machineId)
            out.keptKeys = presentKeys(legacy)
            out.log.append("activation record unreadable (OSStatus \(status)) — "
                           + keptLine(out.keptKeys, reason: "the Keychain could not be read"))
            return out
        }
        let existing = existingRead.record

        // ── 2. The machine id: the record wins, then the legacy plist value. ──
        var machineId = nonEmpty(existing?.machineId) ?? nonEmpty(legacy.machineId)
        if machineId == nil && (current.licensed || current.reserveMachineId) { machineId = mint() }
        out.machineId = machineId
        if let recordId = nonEmpty(existing?.machineId), let plistId = nonEmpty(legacy.machineId),
           recordId != plistId {
            out.log.append("the Keychain record and the preferences plist hold DIFFERENT machine ids — "
                           + "the Keychain's is used")
        }

        // ── 3. What the record should say. ──
        let desired: ActivationRecord?
        if current.licensed {
            desired = ActivationRecord(activated: true, validated: current.validated,
                                       email: current.email, type: current.type,
                                       machineId: machineId ?? "")
        } else if existing == nil || nonEmpty(existing?.machineId) == nil {
            // Not licensed, and no usable record: carry the legacy values into one, unactivated,
            // so the machine id outlives the plist key and a later activation reuses its slot.
            desired = ActivationRecord(activated: false, validated: false,
                                       email: existing?.email ?? legacy.email ?? "",
                                       type: existing?.type ?? "",
                                       machineId: machineId ?? "")
        } else {
            desired = nil   // not licensed, record already holds a machine id: leave it alone
        }

        // ── 4. Write if it differs. ──
        if let desired, !(existing.map { $0.sameStoredFacts(as: desired) } ?? false) {
            guard let json = desired.encoded() else {
                out.keychainFailed = true
                out.keptKeys = presentKeys(legacy)
                out.log.append("could not encode the activation record — "
                               + keptLine(out.keptKeys, reason: "nothing was written"))
                return out
            }
            let status = write(json)
            guard status == 0 else {
                out.keychainFailed = true
                out.keptKeys = presentKeys(legacy)
                out.log.append("activation record write failed (OSStatus \(status)) — "
                               + keptLine(out.keptKeys, reason: "nothing was written"))
                return out
            }
            out.log.append("activation record \(existing == nil ? "created" : "updated") in the Keychain")
        }

        // ── 5. Read it BACK. Only what is read back may justify removing a plist value. ──
        let back = read()
        guard case .found(let record) = back else {
            out.keychainFailed = { if case .failed = back { return true }; return false }()
            out.keptKeys = presentKeys(legacy)
            if legacyPresent {
                let why: String
                if case .failed(let s) = back { why = "the read-back failed (OSStatus \(s))" }
                else { why = "the read-back found no record" }
                out.log.append(keptLine(out.keptKeys, reason: why))
            }
            return out
        }
        out.record = record

        // ── 6. Remove each plist value the record now holds. ──
        if let email = legacy.email {
            if email.isEmpty || email == record.email {
                defaults.removeObject(forKey: legacyEmailKey)
                out.removedKeys.append(legacyEmailKey)
            } else {
                out.keptKeys.append(legacyEmailKey)
                out.log.append("\(legacyEmailKey) kept in the preferences plist: it differs from the Keychain record")
            }
        }
        if let id = legacy.machineId {
            if id.isEmpty || id == record.machineId {
                defaults.removeObject(forKey: legacyMachineIdKey)
                out.removedKeys.append(legacyMachineIdKey)
            } else {
                out.keptKeys.append(legacyMachineIdKey)
                out.log.append("\(legacyMachineIdKey) kept in the preferences plist: it differs from the Keychain record")
            }
        }
        if !out.removedKeys.isEmpty {
            out.log.append("removed \(out.removedKeys.joined(separator: " and ")) from the preferences plist "
                           + "(the Keychain record was read back and matches)")
        }
        return out
    }

    // MARK: - Helpers

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func presentKeys(_ legacy: (email: String?, machineId: String?)) -> [String] {
        var keys: [String] = []
        if legacy.email != nil { keys.append(legacyEmailKey) }
        if legacy.machineId != nil { keys.append(legacyMachineIdKey) }
        return keys
    }

    private static func keptLine(_ keys: [String], reason: String) -> String {
        keys.isEmpty ? "no legacy licence values in the preferences plist"
                     : "legacy licence values left in place in the preferences plist "
                       + "(\(keys.joined(separator: ", "))): \(reason)"
    }
}
