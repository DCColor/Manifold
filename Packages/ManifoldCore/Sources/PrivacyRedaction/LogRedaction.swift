//
//  LogRedaction.swift
//  PrivacyRedaction — what Manifold withholds from its OWN log lines, at the source.
//
//  Privacy stage P1 (docs/PRIVACY_AUDIT.md). The log is NSLog, and NSLog reaches the unified log,
//  which macOS keeps on disk; it is also captured whole into a diagnostics export. So a value that
//  must not leave the machine is withheld where the line is composed, not later. The diagnostics
//  redactor (`DiagnosticsRedaction`) is the second net, for lines composed by code that does not
//  know to call these.
//
//  ⚠️ EVERY REPLACEMENT IS A FIXED TOKEN. A replacement that kept the value's length, or its first
//  octet, would narrow what it hides — the same rule `DiagnosticsRedaction` follows.
//

import Foundation

public enum LogRedaction {

    public static let ipWithheld = "(ip withheld)"
    public static let hostWithheld = "(host withheld)"
    public static let addressWithheld = "(address withheld)"
    public static let valueWithheld = "(withheld)"

    // MARK: - IP addresses

    /// One IPv4 octet, 0…255, with no leading zeros beyond a single digit.
    static let octet = #"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"#

    /// IPv4, optionally with `:port`. Not preceded by a digit or dot (so it is not the tail of a
    /// longer dotted run) and not followed by a digit, `.digit` or a letter — but a sentence-ending
    /// full stop is allowed, because "connected to 10.0.0.2." must not leak.
    static let ipv4Pattern = #"(?<![\d.])(?:"# + octet + #"\.){3}"# + octet + #"(?::\d{1,5})?(?!\d|\.\d|[A-Za-z_])"#

    /// IPv6: the full eight-group form, or a `::`-compressed form with at least one group, with an
    /// optional zone (`%en0`) and an optional embedded IPv4 tail (`::ffff:192.0.2.1`).
    ///
    /// ⚠️ THE LOOKAROUNDS ARE WHAT KEEP THIS OFF C++ AND TIMECODE. `rtc::impl::PeerConnection`
    /// (libdatachannel's own log) has `::` between hex-looking letters, and is excluded only
    /// because the match may not start or end against a word character. `01:00:00:00` (timecode)
    /// and `12:30:44` (clock time) have neither eight groups nor a `::`, so neither form fits.
    static let ipv6Pattern: String = {
        let g = "[0-9A-Fa-f]{1,4}"
        let v4 = "(?:" + octet + #"\.){3}"# + octet
        let full = "(?:\(g):){7}\(g)"
        let left = "\(g)(?::\(g)){0,6}::(?:(?:\(g):){0,5}\(v4)|\(g)(?::\(g)){0,6})?"
        let right = "::(?:(?:\(g):){0,5}\(v4)|\(g)(?::\(g)){0,6})"
        return #"(?<![\w:.])(?:"# + full + "|" + left + "|" + right + #")(?:%[\w.]+)?(?![\w:]|\.\d)"#
    }()

    private static let ipv4 = try! NSRegularExpression(pattern: ipv4Pattern)
    private static let ipv6 = try! NSRegularExpression(pattern: ipv6Pattern)

    /// Every IPv4 and IPv6 address in `text` replaced by `(ip withheld)`. Ports go with an IPv4
    /// address; an IPv6 address in brackets keeps its brackets and port (`[(ip withheld)]:5000`),
    /// which says nothing.
    public static func withholdingIPAddresses(_ text: String) -> String {
        withholdingIPAddresses(text, count: nil)
    }

    /// As above, adding the number of addresses replaced to `count`.
    static func withholdingIPAddresses(_ text: String, count: UnsafeMutablePointer<Int>?) -> String {
        var out = text
        // IPv6 FIRST: an embedded IPv4 tail belongs to the IPv6 address, and removing it first
        // would leave `::ffff:` standing.
        for re in [ipv6, ipv4] {
            let range = NSRange(out.startIndex..., in: out)
            let n = re.numberOfMatches(in: out, range: range)
            guard n > 0 else { continue }
            count?.pointee += n
            out = re.stringByReplacingMatches(in: out, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: ipWithheld))
        }
        return out
    }

    // MARK: - SRT stream ids

    /// An SRT stream id as it may appear in the log.
    ///
    /// ⚠️ A PLAIN STREAM ID IS WITHHELD WHOLE. Many hosted ingests use the publish key itself as
    /// the stream id, and `abc123` cannot be told apart from a channel name — so the only safe
    /// reading of a freeform id is "this may be a key". (This used to be returned unchanged, with a
    /// comment saying so; that was the bypass.)
    ///
    /// The access-control syntax (`#!::k=v,…`) keeps its KEYS and the two values that are
    /// enumerations, `m` (request / publish / bidirectional) and `t` (stream / file / auth), and
    /// withholds every other value: `s` is a session token, and `r` and `u` are, on some servers,
    /// the key and the account.
    public static func srtStreamId(_ streamId: String) -> String {
        guard !streamId.isEmpty else { return "(none)" }
        let prefix = "#!::"
        guard streamId.hasPrefix(prefix) else { return valueWithheld }
        let body = String(streamId.dropFirst(prefix.count))
        let pairs = body.split(separator: ",", omittingEmptySubsequences: false).map { pair -> String in
            // Split on the FIRST "=" only: a value may legitimately contain one.
            guard let eq = pair.firstIndex(of: "=") else { return valueWithheld }
            let key = pair[pair.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            switch key.lowercased() {
            case "m", "t": return String(pair)
            default:       return "\(key)=\(valueWithheld)"
            }
        }
        return prefix + pairs.joined(separator: ",")
    }

    // MARK: - NDI

    /// An NDI source name for the log.
    ///
    /// NDI names a source `MACHINE (Source)`, and MACHINE is the SENDING computer's host name —
    /// so by convention every NDI name embeds a host. The host is withheld; the part in brackets,
    /// which is what the sender called the stream, is kept (with any IP address in it withheld),
    /// because a log that cannot say which stream it connected to is no use to anyone. A name
    /// that does not have that shape is kept, again with any IP address withheld.
    public static func ndiSourceName(_ name: String) -> String {
        // The FIRST " (": a host name cannot contain one, and a stream name may.
        guard let open = name.range(of: " ("),
              name.hasSuffix(")"),
              open.lowerBound > name.startIndex else {
            return withholdingIPAddresses(name)
        }
        let inner = name[open.upperBound..<name.index(before: name.endIndex)]
        return "\(hostWithheld) (\(withholdingIPAddresses(String(inner))))"
    }
}
