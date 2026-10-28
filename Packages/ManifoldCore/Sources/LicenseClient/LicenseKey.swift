//
//  LicenseKey.swift
//  LicenseClient — offline key verification and the user-facing messages.
//
//  A port of Graviton-Releases `shared/license.js` (verifyKey, the message constants). The
//  strings are copied verbatim: every Graviton app shows the customer the same sentence.
//

import Foundation
import CryptoKit

public enum LicenseMessages {
    public static let supportEmail = "support@graviton.tools"
    public static let locked = "This license is no longer valid. Contact support@graviton.tools."
    public static let expired = "This license has expired. Contact support@graviton.tools."
    public static let noMachineId = "Couldn't read this computer's hardware ID. Contact support@graviton.tools."
    /// Only when the worker's numbers are missing: a refusal stored by an earlier release, or a
    /// reply without them.
    public static let maxMachines =
        "This license is already active on the maximum number of machines. Contact support@graviton.tools to free one."
    public static let notRecognized = "This license key was not recognized. Check it and try again."
    public static let unreachable = "Could not reach the license server. Check your connection and try again."

    /// The machine-limit message, for both paths: a refused activation and a pending one that the
    /// server later refused. The numbers are the worker's, for this key's pool. Never a hardcoded 4.
    public static func maxMachines(used: LicenseValue?, limit: LicenseValue?) -> String {
        guard isCount(used), isCount(limit) else { return maxMachines }
        return "This license is already active on \(countText(used)) of \(countText(limit)) machines. "
            + "Contact support@graviton.tools to free one."
    }

    /// A worker code with a 4xx: the worker refused the REQUEST, not the license.
    public static func rejected(_ code: String) -> String {
        "The license server rejected this request (\(code))."
    }

    /// license.js `activationMessage`.
    static func activation(_ code: String, _ data: LicenseFields) -> String {
        switch code {
        case "max_machines": return maxMachines(used: data["machinesUsed"], limit: data["machineLimit"])
        case "revoked", "invalid_key": return locked
        case "unreachable": return unreachable
        default: return "Activation failed (\(code)). Contact support@graviton.tools."
        }
    }
}

public enum KeyVerification: Equatable, Sendable {
    case valid(payload: LicenseFields)
    case invalid(KeyError)

    public enum KeyError: String, Sendable { case format, signature, expired }

    public var payload: LicenseFields? {
        if case .valid(let p) = self { return p }
        return nil
    }
}

public enum LicenseKey {
    /// Ed25519 SPKI DER is this fixed prefix followed by the raw 32-byte key. license.js takes the
    /// PEM; CryptoKit takes the raw bytes. Tests rebuild the SPKI from the two to prove they agree.
    public static let ed25519SPKIPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65,
                                                0x70, 0x03, 0x21, 0x00])

    /// Verify a key's Ed25519 signature against the product's public key (raw 32 bytes), and its
    /// expiry. Key format: <PREFIX><base64url payload>.<base64url sig>, signed over the payload
    /// BYTES, split at the LAST '.'. Never throws.
    ///
    /// Node's base64url decoder skips characters outside the alphabet; Foundation's refuses
    /// them. Either way the bytes do not verify, so both answer 'signature'.
    public static func verify(_ key: String, keyPrefix: String, publicKey: Data, nowMs: Double) -> KeyVerification {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(keyPrefix) else { return .invalid(.format) }
        let rest = String(trimmed.dropFirst(keyPrefix.count))
        guard let dot = rest.lastIndex(of: "."), dot != rest.startIndex,
              rest.index(after: dot) != rest.endIndex else { return .invalid(.format) }

        guard let payloadBytes = base64urlDecode(String(rest[..<dot])),
              let signature = base64urlDecode(String(rest[rest.index(after: dot)...])),
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              verifier.isValidSignature(signature, for: payloadBytes),
              let parsed = try? JSONSerialization.jsonObject(with: payloadBytes, options: [.fragmentsAllowed])
        else { return .invalid(.signature) }

        // `typeof payload !== 'object' || payload === null`: an array passes, as in JavaScript,
        // with no fields.
        let payload: LicenseFields
        if let object = parsed as? [String: Any], let fields = LicenseValue.fields(from: object) {
            payload = fields
        } else if parsed is [Any] {
            payload = [:]
        } else {
            return .invalid(.signature)
        }

        // `payload.expires && now > payload.expires`
        if truthy(payload["expires"]), let expires = jsNumber(payload["expires"]), nowMs > expires {
            return .invalid(.expired)
        }
        return .valid(payload: payload)
    }

    /// base64url (RFC 4648 §5) → Data: URL-safe alphabet, padding optional.
    public static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: b64)
    }

    /// The number JavaScript's `>` compares against. nil is NaN (every comparison false).
    private static func jsNumber(_ value: LicenseValue?) -> Double? {
        switch value {
        case .number(let n)?: return n.isNaN ? nil : n
        case .bool(let b)?: return b ? 1 : 0
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? 0 : Double(t)
        default: return nil
        }
    }
}
