//
//  ActivationRecord.swift
//  LicenseRecord — the Keychain half of the licence state, and the move of the licence email and
//  machine id out of the preferences plist (privacy stage P1, docs/PRIVACY_AUDIT.md).
//
//  Moved here from App/LicenseManager.swift so `swift test` can run the migration against a
//  scratch Keychain service. The Keychain itself is reached through closures the caller supplies:
//  the app passes `KeychainStore.license`, the tests pass a scratch service.
//

import Foundation

/// Everything about an activation that is not the signed key: whether this install activated,
/// the licensee's email and licence type for display, and the machine id the server's machine
/// limit counts.
///
/// ⚠️ THE KEY REMAINS THE AUTHORITY, NOT THIS RECORD. This record is unsigned — it is our own
/// bookkeeping, and anyone who can write it can write `activated: true`. It is trusted for
/// `machineId` and for display fields only. Whether the user is LICENSED is decided by
/// `LicenseCrypto.verify` over the stored key, every launch.
///
/// ⚠️ SINCE P1 IT IS THE ONLY PLACE THE EMAIL AND THE MACHINE ID ARE KEPT. They used to be cached
/// in `~/Library/Preferences/com.graviton.manifold.plist` as `license.email` and
/// `license.machineId`, unencrypted. A record with `activated: false` is legitimate: it is how the
/// machine id survives a deactivation, or is kept for an install that has not activated yet, so
/// that activating later does not spend a second machine slot.
public struct ActivationRecord: Codable, Equatable {
    public var activated: Bool
    public var validated: Bool
    public var email: String
    public var type: String
    public var machineId: String

    /// Schema marker. Written but not enforced on read: an older app meeting a newer record should
    /// degrade to ignoring fields it does not know, never to discarding the record.
    public var v: Int = 1

    public init(activated: Bool, validated: Bool, email: String, type: String, machineId: String) {
        self.activated = activated
        self.validated = validated
        self.email = email
        self.type = type
        self.machineId = machineId
    }

    public func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String) -> ActivationRecord? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ActivationRecord.self, from: data)
    }

    /// The fields whose change warrants a rewrite. `validated` is deliberately not one: it moves
    /// with every revalidation and is not what this record is kept for.
    public func sameStoredFacts(as other: ActivationRecord) -> Bool {
        activated == other.activated && machineId == other.machineId
            && email == other.email && type == other.type
    }
}

/// What reading the record answered. Three cases, for the same reason `KeychainRead` has three:
/// "there is no record" and "I was refused it" must not collapse into one `nil`.
public enum RecordRead: Equatable {
    case found(ActivationRecord)
    /// The account is genuinely empty.
    case absent
    /// The Keychain refused, or the item was there and did not decode. Carries the OSStatus
    /// (`errSecDecode` for an undecodable item).
    case failed(Int32)

    public var record: ActivationRecord? {
        if case .found(let r) = self { return r }
        return nil
    }
}
