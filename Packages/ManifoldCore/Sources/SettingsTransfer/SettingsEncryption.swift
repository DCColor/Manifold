//
//  SettingsEncryption.swift — a file with streams (docs/SETTINGS_EXPORT_PLAN.md §2.4, §2.5).
//
//  AES-GCM-256 with a key from PBKDF2-HMAC-SHA256. Every top-level field except `payload` is authenticated, so changing
//  the salt, a count or the iterations fails the open just as changing the payload does. `AES.GCM.open` cannot tell a
//  wrong password from a changed file, which is why there is one message.
//
//  ⚠️ NOTHING HERE LOGS, and no error says which check failed. The password is never stored. Swift strings cannot be
//  wiped, so it and the decrypted values live in ordinary memory until released, the same exposure a connect has.
//

import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum SettingsEncryption {
    public static let cipher = "AES-GCM-256"
    public static let kdf = "PBKDF2-HMAC-SHA256"
    /// R4. Stated in the header, so raising it later needs no format change. Frozen once the Air is measured (A6).
    public static let iterations = 1_000_000
    /// What an import will run. The ceiling stops a changed header from hanging the app.
    public static let acceptedIterations = 600_000...10_000_000
    /// R4. Characters, with no composition rules.
    public static let minimumPasswordLength = 12
    public static let wrongPasswordMessage = "Wrong password, or the file has been changed."

    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16

    public enum EncodeError: Error, Equatable {
        case passwordTooShort
        case tooLarge
        case failed
    }

    /// What is wrong with a new password, or nil. Lengths are of the NFC form, the bytes the key comes from.
    public static func passwordProblem(_ password: String, confirmation: String) -> String? {
        if normalized(password).count < minimumPasswordLength {
            return "Use at least \(minimumPasswordLength) characters."
        }
        if normalized(password) != normalized(confirmation) { return "The two passwords don’t match." }
        return nil
    }

    /// NFC, so the same password typed on two Macs gives the same bytes.
    static func normalized(_ password: String) -> String { password.precomposedStringWithCanonicalMapping }

    static func deriveKey(password: String, salt: Data, iterations: Int) -> SymmetricKey? {
        let bytes = Array(normalized(password).utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { raw -> Int32 in
            bytes.withUnsafeBufferPointer { pw in
                pw.baseAddress.map { base in
                    base.withMemoryRebound(to: Int8.self, capacity: bytes.count) { signed in
                        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), signed, bytes.count,
                                             raw.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                             &key, key.count)
                    }
                } ?? -1
            }
        }
        return status == 0 ? SymmetricKey(data: key) : nil
    }

    /// The authenticated data: `root` without `payload`, as sorted-keys JSON. A frozen vector pins these bytes.
    static func authenticatedHeader(_ root: [String: Any]) -> Data? {
        var header = root
        header.removeValue(forKey: "payload")
        return try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func random(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        return SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess ? Data(bytes) : nil
    }
}

extension SettingsFile {
    /// A file with streams. `shortcuts` is the `overrides` object, or nil to leave the section out. One payload holds
    /// every section, and the header says only how many of each. Slow by design: keep it off the main thread.
    public static func encodeEncrypted(shortcuts: [String: Any]?, streams: [StreamExportEntry], password: String,
                                       provenance: Provenance) throws -> Data {
        guard let salt = SettingsEncryption.random(SettingsEncryption.saltLength),
              let nonce = SettingsEncryption.random(SettingsEncryption.nonceLength) else {
            throw SettingsEncryption.EncodeError.failed
        }
        return try encodeEncrypted(shortcuts: shortcuts, streams: streams, password: password, provenance: provenance,
                                   iterations: SettingsEncryption.iterations, salt: salt, nonce: nonce)
    }

    /// With fixed salt and nonce, for the frozen vector. Never reuse a nonce: the public form draws fresh ones.
    static func encodeEncrypted(shortcuts: [String: Any]?, streams: [StreamExportEntry], password: String,
                                provenance: Provenance, iterations: Int, salt: Data, nonce: Data) throws -> Data {
        guard SettingsEncryption.normalized(password).count >= SettingsEncryption.minimumPasswordLength else {
            throw SettingsEncryption.EncodeError.passwordTooShort
        }
        var inner: [String: Any] = [:]
        var counts: [String: Any] = [:]
        if let shortcuts {
            inner["shortcuts"] = ["version": shortcutsVersion, "overrides": shortcuts] as [String: Any]
            counts["shortcuts"] = ["version": shortcutsVersion, "count": shortcuts.count]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entries = try JSONSerialization.jsonObject(with: encoder.encode(streams))
        inner["streams"] = ["version": streamsVersion, "entries": entries] as [String: Any]
        counts["streams"] = ["version": streamsVersion, "count": streams.count]

        let plaintext = try JSONSerialization.data(withJSONObject: ["sections": inner],
                                                   options: [.sortedKeys, .withoutEscapingSlashes])
        var root: [String: Any] = [
            "kind": kind,
            "formatVersion": formatVersion,
            "appVersion": provenance.appVersion,
            "appBuild": provenance.appBuild,
            "exportedAt": dateFormatter().string(from: provenance.exportedAt),
            "encryption": ["cipher": SettingsEncryption.cipher, "kdf": SettingsEncryption.kdf, "iterations": iterations,
                           "salt": salt.base64EncodedString(), "nonce": nonce.base64EncodedString()] as [String: Any],
            "sections": counts,
        ]
        guard let aad = SettingsEncryption.authenticatedHeader(root),
              let key = SettingsEncryption.deriveKey(password: password, salt: salt, iterations: iterations) else {
            throw SettingsEncryption.EncodeError.failed
        }
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        root["payload"] = (box.ciphertext + box.tag).base64EncodedString()
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        // A file the reader would refuse is no file at all.
        guard data.count <= maxBytes else { throw SettingsEncryption.EncodeError.tooLarge }
        return data
    }
}

/// An encrypted file that reads as a header. Holds nothing secret until `open` succeeds.
public struct SealedFile: Sendable {
    public struct OpenFailed: Error, Equatable {
        public let message = SettingsEncryption.wrongPasswordMessage
    }

    public let appVersion: String?
    public let exportedAt: Date?
    private let header: Data
    private let cipher: String?
    private let kdf: String?
    private let iterations: Int?
    private let salt: String?
    private let nonce: String?
    private let payload: String

    /// nil when the file cannot be read as a header (R6). Values are judged in `open`, past the prompt.
    init?(root: [String: Any]) {
        guard let encryption = root["encryption"] as? [String: Any], let payload = root["payload"] as? String,
              root["sections"] is [String: Any], let header = SettingsEncryption.authenticatedHeader(root) else {
            return nil
        }
        self.header = header
        self.payload = payload
        appVersion = root["appVersion"] as? String
        exportedAt = SettingsFile.exportDate(root)
        cipher = encryption["cipher"] as? String
        kdf = encryption["kdf"] as? String
        iterations = SettingsFile.wholeNumber(encryption["iterations"])
        salt = encryption["salt"] as? String
        nonce = encryption["nonce"] as? String
    }

    /// Slow by design: keep it off the main thread. Every failure is the same failure.
    public func open(password: String) -> Result<SettingsFile.Document, OpenFailed> {
        guard cipher == SettingsEncryption.cipher, kdf == SettingsEncryption.kdf,
              let iterations, SettingsEncryption.acceptedIterations.contains(iterations),
              let salt = salt.flatMap({ Data(base64Encoded: $0) }), salt.count == SettingsEncryption.saltLength,
              let nonce = nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == SettingsEncryption.nonceLength,
              let sealed = Data(base64Encoded: payload), sealed.count >= SettingsEncryption.tagLength,
              let key = SettingsEncryption.deriveKey(password: password, salt: salt, iterations: iterations),
              let gcmNonce = try? AES.GCM.Nonce(data: nonce),
              let box = try? AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: sealed.dropLast(SettingsEncryption.tagLength),
                                               tag: sealed.suffix(SettingsEncryption.tagLength)),
              let plaintext = try? AES.GCM.open(box, using: key, authenticating: header),
              let inner = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
              let sections = inner["sections"] as? [String: Any] else {
            return .failure(OpenFailed())
        }
        let parsed = SettingsFile.parseSections(sections, encrypted: true)
        return .success(SettingsFile.Document(appVersion: appVersion, exportedAt: exportedAt, shortcuts: parsed.shortcuts,
                                              streams: parsed.streams, left: parsed.left))
    }
}
