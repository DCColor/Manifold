//
//  LicenseRecordSync.swift
//  LicenseRecord — move the licence email and machine id out of the preferences plist, into the
//  Keychain activation record, and only then remove them from the plist.
//
//  Privacy stage P1 (docs/PRIVACY_AUDIT.md). Since the license client port it does only that move:
//  the record is the client's storage (`LicenseRecordStore`), every write goes through its merge,
//  and nothing here mints a machine id — the client derives one from the hardware, once, when an
//  install that never had one activates (Graviton adoption: apps stop minting). The rules:
//
//   1. A LICENSED USER MUST NEVER BE DE-ACTIVATED BY THIS. It writes only the record's `machineId`
//      and `email` (or the client's `licenseMachineId`), never the key or any licence state.
//   2. A plist value is removed ONLY after the record has been READ BACK from the Keychain and
//      holds the same value. Written-successfully is not enough; read-back-and-equal is.
//   3. If the Keychain read fails, the plist is left exactly as it is, and the outcome says so.
//

import Foundation
import LicenseClient

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

    /// The two plist keys P1 retires. Read by the migration and the store, removed by the
    /// migration, written by nothing.
    public static let legacyEmailKey = "license.email"
    public static let legacyMachineIdKey = "license.machineId"

    /// What a run did. `log` lines carry NO email and NO machine id — they say what happened to
    /// which key and why, which is all a diagnostics export needs.
    public struct Outcome: Equatable {
        public var removedKeys: [String] = []
        public var keptKeys: [String] = []
        public var log: [String] = []
        /// True when a Keychain read or write failed. Nothing was removed.
        public var keychainFailed = false
    }

    /// Reads the legacy plist values. Empty strings count as present: they are still keys in the
    /// plist, and removing them is part of the job.
    public static func legacyValues(in defaults: LegacyLicenseStore) -> (email: String?, machineId: String?) {
        (defaults.string(forKey: legacyEmailKey), defaults.string(forKey: legacyMachineIdKey))
    }

    /// One pass. Makes no Keychain round trip when the plist holds neither key.
    public static func run(defaults: LegacyLicenseStore, store: LicenseRecordStore) -> Outcome {
        var out = Outcome()
        let legacy = legacyValues(in: defaults)
        guard legacy.email != nil || legacy.machineId != nil else { return out }

        // ── 1. Read the record as stored. ──
        let existing: LicenseFields
        do {
            existing = try store.readRecordFields() ?? [:]
        } catch let error as LicenseStoreError {
            return kept(out, legacy, "activation record unreadable (OSStatus \(error.status))",
                        reason: "the Keychain could not be read")
        } catch {
            return kept(out, legacy, "activation record unreadable", reason: "the Keychain could not be read")
        }

        // ── 2. Carry each value the record lacks. The record's id wins over the plist's. ──
        var patch: LicenseFields = [:]
        let recordId = LicenseRecordStore.nonEmpty(existing["licenseMachineId"])
            ?? LicenseRecordStore.nonEmpty(existing["machineId"])
        if recordId == nil, let id = legacy.machineId, !id.isEmpty {
            patch["licenseMachineId"] = .string(id)
        } else if let recordId, let id = legacy.machineId, !id.isEmpty, id != recordId {
            out.log.append("the Keychain record and the preferences plist hold DIFFERENT machine ids — "
                           + "the Keychain's is used")
        }
        let recordEmail = LicenseRecordStore.nonEmpty(existing["licenseEmail"])
            ?? LicenseRecordStore.nonEmpty(existing["email"])
        if recordEmail == nil, existing["licenseEmail"] == nil, let email = legacy.email, !email.isEmpty {
            patch["email"] = .string(email)
        }

        if !patch.isEmpty {
            do {
                try store.writeSync(patch)
            } catch let error as LicenseStoreError {
                return kept(out, legacy, "activation record write failed (OSStatus \(error.status))",
                            reason: "nothing was written")
            } catch {
                return kept(out, legacy, "activation record write failed", reason: "nothing was written")
            }
            out.log.append("activation record \(existing.isEmpty ? "created" : "updated") in the Keychain")
        }

        // ── 3. Read it BACK. Only what is read back may justify removing a plist value. ──
        let back: LicenseFields
        do {
            guard let fields = try store.readRecordFields() else {
                out.keptKeys = presentKeys(legacy)
                out.log.append(keptLine(out.keptKeys, reason: "the read-back found no record"))
                return out
            }
            back = fields
        } catch let error as LicenseStoreError {
            return kept(out, legacy, nil, reason: "the read-back failed (OSStatus \(error.status))")
        } catch {
            return kept(out, legacy, nil, reason: "the read-back failed")
        }

        // ── 4. Remove each plist value the record now holds. ──
        if let email = legacy.email {
            if email.isEmpty || email == back["email"]?.stringValue || email == back["licenseEmail"]?.stringValue {
                defaults.removeObject(forKey: legacyEmailKey)
                out.removedKeys.append(legacyEmailKey)
            } else {
                out.keptKeys.append(legacyEmailKey)
                out.log.append("\(legacyEmailKey) kept in the preferences plist: it differs from the Keychain record")
            }
        }
        if let id = legacy.machineId {
            if id.isEmpty || id == back["machineId"]?.stringValue || id == back["licenseMachineId"]?.stringValue {
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

    private static func kept(_ base: Outcome, _ legacy: (email: String?, machineId: String?),
                             _ what: String?, reason: String) -> Outcome {
        var out = base
        out.keychainFailed = true
        out.keptKeys = presentKeys(legacy)
        let line = keptLine(out.keptKeys, reason: reason)
        out.log.append(what.map { "\($0) — \(line)" } ?? line)
        return out
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
