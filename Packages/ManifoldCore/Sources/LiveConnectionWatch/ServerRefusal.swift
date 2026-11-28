//
//  ServerRefusal.swift
//  Manifold — a web-stream server's refusal, in Manifold's words first (docs/BUGS.md, 0.9.6 UI polish item 28, batch 4).
//
//  A WHEP server that refuses the offer (any non-2xx) often says why in its response body. Until 0.9.6 that body WAS the
//  banner, so the message's wording, language and length changed with the server: one server's plain sentence, another's
//  JSON field, another's HTML page cut at 200 characters. Manifold is server-agnostic (CLAUDE.md), so the banner now
//  always starts with the same sentence of Manifold's own, names the status, and only then quotes what the server said,
//  on one line and shortened. A body with nothing usable in it (empty, binary, HTML, JSON with no human field) is not
//  quoted at all.
//
//  The body is the server's own text; it does not carry the endpoint URL and is never joined with it.
//

import Foundation

public enum ServerRefusal {

    /// The longest quote the banner carries, in characters, before it is cut at a word and given "…".
    public static let maxQuoteLength = 120

    /// JSON fields that hold a human sentence, in the order they are tried.
    static let humanFields = ["errorDescription", "error", "message", "detail", "reason"]

    /// The banner text for a refused offer: Manifold's sentence, the server's words quoted (when it gave any), and what to do.
    public static func message(status: Int, body: String?) -> String {
        var text = "The stream server refused the connection (HTTP \(status))."
        if let quote = body.flatMap(quote(fromBody:)) {
            // A quote that doesn't end a sentence gets the period, inside the quotation marks (American usage).
            let ends = quote.last.map { ".!?…".contains($0) } ?? false
            text += " It said: “\(quote)\(ends ? "" : ".")”"
        }
        return text + " Check the address and that the broadcast is live, then connect again."
    }

    /// What the server said, on one line and at most `maxQuoteLength` characters, or nil when the body has nothing to quote.
    public static func quote(fromBody body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var said: String
        if trimmed.hasPrefix("{") {
            // JSON: a known human field, or nothing. Raw JSON is never shown.
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let field = humanFields.lazy.compactMap({ obj[$0] as? String }).first(where: { !oneLine($0).isEmpty })
            else { return nil }
            said = field
        } else if trimmed.hasPrefix("<") {
            // An HTML (or XML) page: a proxy's or a web server's error page, not a sentence.
            return nil
        } else {
            said = trimmed
        }
        said = oneLine(said)
        guard !said.isEmpty else { return nil }
        return shortened(said)
    }

    /// Runs of whitespace, newlines included, become one space.
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// At most `maxQuoteLength` characters: cut at the last space inside the limit (or at the limit, for one long word),
    /// with "…" after it.
    static func shortened(_ s: String) -> String {
        guard s.count > maxQuoteLength else { return s }
        let head = String(s.prefix(maxQuoteLength))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }
}
