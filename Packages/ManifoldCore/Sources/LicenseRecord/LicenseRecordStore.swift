//
//  LicenseRecordStore.swift
//  LicenseRecord — the license client's storage: the Keychain activation record, extended.
//
//  `activationRecord` holds every field the license client writes (`licenseActivated`,
//  `licenseMachineId`, …) beside the five fields earlier releases wrote and read
//  (`activated`, `validated`, `email`, `type`, `machineId`, plus `v`). The key itself stays in its
//  own item, `storedLicenseKey`, where every release looks for it. (Robbie, 2026-10-28, D1.)
//
//  The rules, in the order they bind:
//
//   1. STORAGE THAT EXISTS BUT CANNOT BE READ IS NEVER OVERWRITTEN (Graviton adoption rule 6). A
//      refused read, or a record that does not decode, throws — from `read` and from `write`, which
//      reads before it merges. Nothing is ever written in its place.
//   2. FIELDS THIS CODE DOES NOT KNOW ARE KEPT (rule 7). A write merges its patch into the record as
//      read; it never rebuilds the record from a fixed list.
//   3. THE FIVE OLD FIELDS ARE ALWAYS WRITTEN, WITH THEIR OLD TYPES. 0.8.4's decoder needs all five
//      and `v`, and 0.8.4 OVERWRITES a record it cannot decode. They mirror the client's fields, in
//      0.8.4's spelling, so a downgraded 0.8.4 finds the record already current and leaves it alone.
//   4. EXISTING INSTALLS KEEP THEIR MACHINE ID (rule 1). Earlier releases registered a random UUID,
//      kept in the record's `machineId` and, before privacy P1, in the plist's `license.machineId`.
//      `read` maps it into `licenseMachineId` — record first, then plist — when the client has none.
//
//  Synchronous at its core (`readSync`, `writeSync`) so the launch gather can use it on the
//  Keychain queue it is already on; `read` and `write` hop to that queue.
//

import Foundation
import LicenseClient

/// One Keychain item read, three ways (`KeychainRead` in the app).
public enum ItemRead: Equatable, Sendable {
    case found(String)
    case absent
    case failed(Int32)
}

/// The generic-password items of the licence service, as closures, so tests can use a scratch
/// service. `write` is an upsert; both return an OSStatus.
public struct LicenseItemIO: Sendable {
    public var read: @Sendable (_ account: String) -> ItemRead
    public var write: @Sendable (_ value: String, _ account: String) -> Int32
    public var delete: @Sendable (_ account: String) -> Int32

    public init(read: @escaping @Sendable (String) -> ItemRead,
                write: @escaping @Sendable (String, String) -> Int32,
                delete: @escaping @Sendable (String) -> Int32) {
        self.read = read
        self.write = write
        self.delete = delete
    }
}

/// A Keychain failure. Carries the OSStatus and which step failed; never a value.
public struct LicenseStoreError: Error, Equatable, Sendable {
    public let status: Int32
    public let step: String

    public init(status: Int32, step: String) {
        self.status = status
        self.step = step
    }
}

public final class LicenseRecordStore: LicenseStorage, @unchecked Sendable {

    public static let keyAccount = "storedLicenseKey"
    public static let recordAccount = "activationRecord"
    public static let recordVersion: Double = 2

    private static let errSecItemNotFound: Int32 = -25300
    private static let errSecDecode: Int32 = -26275

    let items: LicenseItemIO
    /// The preferences plist, for the pre-P1 `license.machineId`. nil when the plist must not be
    /// consulted (the DEBUG live-test redirect).
    let legacy: LegacyLicenseStore?
    let queue: DispatchQueue

    private let lock = NSRecursiveLock()
    private var cache: LicenseFields?

    public init(items: LicenseItemIO, legacy: LegacyLicenseStore?, queue: DispatchQueue) {
        self.items = items
        self.legacy = legacy
        self.queue = queue
    }

    // MARK: LicenseStorage

    public func read() async throws -> LicenseFields {
        try await hop { try self.readSync() }
    }

    public func write(_ patch: LicenseFields) async throws {
        try await hop { try self.writeSync(patch) }
    }

    private func hop<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: Read

    /// The record as stored: nil when there is none. Throws when it cannot be read or decoded.
    public func readRecordFields() throws -> LicenseFields? {
        switch items.read(Self.recordAccount) {
        case .absent:
            return nil
        case .failed(let status):
            throw LicenseStoreError(status: status, step: "read the activation record")
        case .found(let json):
            guard let fields = LicenseValue.parseObject(Data(json.utf8)) else {
                throw LicenseStoreError(status: Self.errSecDecode, step: "decode the activation record")
            }
            return fields
        }
    }

    /// The client's view: the record, the key, and the legacy machine ID mapped in. Cached until
    /// the next write; a failed read is not cached.
    public func readSync() throws -> LicenseFields {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }

        var fields = try readRecordFields() ?? [:]
        switch items.read(Self.keyAccount) {
        case .absent:
            break
        case .failed(let status):
            throw LicenseStoreError(status: status, step: "read the license key")
        case .found(let key):
            fields["licenseKey"] = .string(key)
        }
        if Self.nonEmpty(fields["licenseMachineId"]) == nil {
            if let recorded = Self.nonEmpty(fields["machineId"]) {
                fields["licenseMachineId"] = .string(recorded)
            } else if let plist = legacy?.string(forKey: LicenseRecordSync.legacyMachineIdKey), !plist.isEmpty {
                fields["licenseMachineId"] = .string(plist)
            }
        }
        cache = fields
        return fields
    }

    // MARK: Write

    /// Merge `patch` into the record as read, mirror the old fields, write it, then write or delete
    /// the key. Throws, writing nothing, if the record cannot be read.
    public func writeSync(_ patch: LicenseFields) throws {
        lock.lock(); defer { lock.unlock() }
        cache = nil

        var record = try readRecordFields() ?? [:]
        var fields = patch
        let key = fields.removeValue(forKey: "licenseKey")
        record.merge(fields) { $1 }
        Self.mirrorLegacyFields(&record)

        let json: String
        do {
            json = String(decoding: try LicenseValue.encodeObject(record), as: UTF8.self)
        } catch {
            throw LicenseStoreError(status: Self.errSecDecode, step: "encode the activation record")
        }

        // ORDER, so that every partial failure leaves a state that reads correctly and keeps the
        // machine ID (the record's, which neither step clears):
        //   • removing the key (deactivation): the KEY FIRST. If the delete fails nothing has
        //     changed; if the record write then fails, no key reads as unlicensed.
        //   • storing a key (activation): the RECORD FIRST. A record that says activated with no
        //     key reads as unlicensed.
        // Measured 2026-10-28: with the record first, a refused key delete (-25244, an item another
        // app owned) left a cleared record beside a stored key, and the app said nothing changed.
        let storingKey = key?.stringValue.map { !$0.isEmpty } ?? false
        if key != nil, !storingKey {
            let s = items.delete(Self.keyAccount)
            guard s == 0 || s == Self.errSecItemNotFound else {
                throw LicenseStoreError(status: s, step: Self.deleteKeyStep)
            }
        }
        let status = items.write(json, Self.recordAccount)
        guard status == 0 else { throw LicenseStoreError(status: status, step: Self.writeRecordStep) }
        if storingKey, let value = key?.stringValue {
            let s = items.write(value, Self.keyAccount)
            guard s == 0 else { throw LicenseStoreError(status: s, step: "write the license key") }
        }
    }

    /// The `step` of a refused key delete: nothing was changed.
    public static let deleteKeyStep = "delete the license key"
    public static let writeRecordStep = "write the activation record"

    /// The five fields 0.8.4 decodes, from the client's, in 0.8.4's spelling; and `v`. A field the
    /// client has not written keeps its old value (or a typed default, which the decoder needs).
    /// `machineId` is only ever set to a non-empty ID: it is never cleared.
    static func mirrorLegacyFields(_ r: inout LicenseFields) {
        if let a = r["licenseActivated"] { r["activated"] = .bool(a.isTrue) }
        if let v = r["licenseValidated"] { r["validated"] = .bool(v.isTrue) }
        if let e = r["licenseEmail"] { r["email"] = .string(e.stringValue ?? "") }
        if let t = r["licenseType"] { r["type"] = .string(t.stringValue.map(legacyTypeSpelling) ?? "") }
        if let id = nonEmpty(r["licenseMachineId"]) { r["machineId"] = .string(id) }

        for name in ["activated", "validated"] where !isBool(r[name]) { r[name] = .bool(false) }
        for name in ["email", "type", "machineId"] where r[name]?.stringValue == nil { r[name] = .string("") }
        r["v"] = .number(recordVersion)
    }

    /// `LicenseType(rawValue:).rawValue` in 0.8.4: what it compares the record's `type` against.
    static func legacyTypeSpelling(_ type: String) -> String {
        let lower = type.lowercased()
        return ["standard", "beta", "nfr"].contains(lower) ? lower : "unknown"
    }

    // MARK: The one-time conversion of an existing activation

    /// For an install activated by an earlier release (a stored key that verifies, and a record the
    /// client has never written): add the client's fields, once, before the first `status()`.
    ///
    /// Every earlier release stored the key only after the server answered `ok`, so such a key is a
    /// server-confirmed activation and nothing maps to pending. `licenseLastValidatedAt` is NOT
    /// written, so the first launch validates; no `licenseMachineIdSource` is invented for an
    /// existing ID; nothing old is deleted, renamed or changed (rule 2). Returns whether it wrote.
    @discardableResult
    public func convertLegacyActivationIfNeeded(verify: (String) -> LicenseFields?) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let fields = try readSync()
        guard fields["licenseActivated"] == nil,
              let key = fields["licenseKey"]?.stringValue,
              let payload = verify(key) else { return false }
        var patch: LicenseFields = [
            "licenseActivated": .bool(true),
            "licenseValidated": .bool(true),
            "licenseServerConfirmed": .bool(true),
            "licenseActivationPending": .bool(false),
            "licenseActivationError": .null,
            "licenseEmail": .string(Self.nonEmpty(payload["email"]) ?? ""),
            "licenseType": .string(Self.nonEmpty(payload["licenseType"]) ?? "standard"),
        ]
        if let id = Self.nonEmpty(fields["licenseMachineId"]) { patch["licenseMachineId"] = .string(id) }
        try writeSync(patch)
        return true
    }

    // MARK: Helpers

    static func nonEmpty(_ v: LicenseValue?) -> String? {
        guard let s = v?.stringValue, !s.isEmpty else { return nil }
        return s
    }

    private static func isBool(_ v: LicenseValue?) -> Bool {
        if case .bool? = v { return true }
        return false
    }
}
