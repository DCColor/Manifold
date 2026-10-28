//
//  LicenseValue.swift
//  LicenseClient — a JSON value with JavaScript's distinctions kept, for the stored licence fields
//  and the worker's replies.
//
//  The port has to answer the questions license.js asks of a plain object: is the field ABSENT or
//  `null`, is it `true` or merely truthy, is `4` a count. `[String: Any]` from JSONSerialization
//  cannot: an `NSNumber` of 1 casts to `Bool` true, and `"ok": 1` would read as `ok === true`.
//  So every value is classified once, here, and the client reads only this type.
//

import Foundation

public enum LicenseValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LicenseValue])
    case object([String: LicenseValue])
}

/// The stored licence fields, or a patch of them. A key that is absent is `undefined`; a key that
/// holds `.null` is `null`. Writing a patch merges it shallowly, as license.js's storage does.
public typealias LicenseFields = [String: LicenseValue]

extension LicenseValue {
    /// JavaScript truthiness: `null`, `false`, `0`, `NaN` and `''` are falsy; everything else,
    /// arrays and objects included, is truthy.
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// `=== true`. Not truthiness: `1` is not `true`.
    public var isTrue: Bool { self == .bool(true) }
}

/// Truthiness of a field that may be absent (`undefined`, falsy).
func truthy(_ value: LicenseValue?) -> Bool { value?.isTruthy ?? false }

/// The value as a non-empty string when it is truthy and a string, else nil. What license.js gets
/// from `s.field || …` when the field is a string.
func truthyString(_ value: LicenseValue?) -> String? {
    guard let s = value?.stringValue, !s.isEmpty else { return nil }
    return s
}

/// `Number.isInteger(n) && n >= 0`. A boolean is not a number, and neither is `"4"`.
func isCount(_ value: LicenseValue?) -> Bool {
    guard case .number(let n)? = value else { return false }
    return n.isFinite && n.rounded() == n && n >= 0
}

/// A count as JavaScript prints it in a template literal: `4`, not `4.0`.
func countText(_ value: LicenseValue?) -> String {
    guard case .number(let n)? = value else { return "" }
    if abs(n) < 9.0e15 { return String(Int64(n)) }
    return String(format: "%.0f", n)
}

// MARK: - JSON

extension LicenseValue {
    /// Classifies a JSONSerialization value. Booleans are told from numbers by their CFTypeID,
    /// because `NSNumber` bridges either way.
    public init?(json: Any) {
        switch json {
        case is NSNull:
            self = .null
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let a as [Any]:
            var out: [LicenseValue] = []
            for element in a {
                guard let v = LicenseValue(json: element) else { return nil }
                out.append(v)
            }
            self = .array(out)
        case let o as [String: Any]:
            guard let fields = LicenseValue.fields(from: o) else { return nil }
            self = .object(fields)
        default:
            return nil
        }
    }

    /// The value for JSONSerialization. Integral numbers are written as integers, so a stored
    /// millisecond timestamp reads `1790000000000`, not `1.79e12`.
    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .number(let n):
            if n.isFinite, n.rounded() == n, abs(n) < 9.0e15 { return NSNumber(value: Int64(n)) }
            return NSNumber(value: n)
        case .string(let s): return s
        case .array(let a): return a.map(\.jsonObject)
        case .object(let o): return o.mapValues(\.jsonObject)
        }
    }

    static func fields(from object: [String: Any]) -> LicenseFields? {
        var out: LicenseFields = [:]
        for (k, v) in object {
            guard let value = LicenseValue(json: v) else { return nil }
            out[k] = value
        }
        return out
    }

    /// Parses a JSON OBJECT. nil for anything else: not JSON, a fragment, an array, `null`.
    public static func parseObject(_ data: Data) -> LicenseFields? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let object = any as? [String: Any] else { return nil }
        return fields(from: object)
    }

    /// Encodes fields as a JSON object: sorted keys, slashes unescaped.
    public static func encodeObject(_ fields: LicenseFields) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields.mapValues(\.jsonObject),
                                   options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
