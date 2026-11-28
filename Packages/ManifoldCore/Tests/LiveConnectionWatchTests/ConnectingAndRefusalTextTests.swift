//
//  ConnectingAndRefusalTextTests.swift
//  LiveConnectionWatchTests — the connecting tooltip (0.9.6 UI polish item 30) and the web-stream refusal banner (item 28).
//

import XCTest
@testable import LiveConnectionWatch

final class ConnectingTextTests: XCTestCase {

    func testNamesWhatWasPicked() {
        XCTAssertEqual(ConnectingText.tooltip(name: "Studio B"), "Connecting to Studio B…")
    }

    /// NDI's quick connect has no name until discovery finds a source.
    func testNoNameIsTheFirstNDISource() {
        XCTAssertEqual(ConnectingText.tooltip(name: nil), "Connecting to the first NDI source…")
        XCTAssertEqual(ConnectingText.tooltip(name: ""), "Connecting to the first NDI source…")
    }
}

final class ServerRefusalTests: XCTestCase {

    private let nextStep = " Check the address and that the broadcast is live, then connect again."

    /// Manifold's sentence first, the server's plain text quoted, then the next step.
    func testPlainBodyIsQuotedAfterManifoldsSentence() {
        XCTAssertEqual(ServerRefusal.message(status: 409, body: "Live broadcast not started yet\n"),
                       "The stream server refused the connection (HTTP 409). It said: “Live broadcast not started yet.”" + nextStep)
        XCTAssertEqual(ServerRefusal.message(status: 403, body: "Forbidden!"),
                       "The stream server refused the connection (HTTP 403). It said: “Forbidden!”" + nextStep)
    }

    /// The same sentence whatever the server: with no body, only the status differs.
    func testNoBodyIsManifoldsSentenceAlone() {
        XCTAssertEqual(ServerRefusal.message(status: 404, body: nil),
                       "The stream server refused the connection (HTTP 404)." + nextStep)
        XCTAssertEqual(ServerRefusal.message(status: 500, body: "   \n "),
                       "The stream server refused the connection (HTTP 500)." + nextStep)
    }

    func testJSONHumanFieldIsQuotedAndRawJSONNever() {
        XCTAssertEqual(ServerRefusal.quote(fromBody: #"{"code": 7, "message": "Stream key not found"}"#), "Stream key not found")
        XCTAssertEqual(ServerRefusal.quote(fromBody: #"{"errorDescription": "No such stream", "error": "x"}"#), "No such stream")
        XCTAssertNil(ServerRefusal.quote(fromBody: #"{"code": 7}"#))
        XCTAssertNil(ServerRefusal.quote(fromBody: #"{"message": "   "}"#))
    }

    /// A proxy's error page is not a sentence.
    func testHTMLIsNotQuoted() {
        XCTAssertNil(ServerRefusal.quote(fromBody: "<html><body><h1>502 Bad Gateway</h1></body></html>"))
    }

    /// One line, whitespace runs collapsed.
    func testQuoteIsOneLine() {
        XCTAssertEqual(ServerRefusal.quote(fromBody: "Too many\n\n  viewers\tright now"), "Too many viewers right now")
    }

    /// Shortened at a word, with "…", never past the limit.
    func testLongQuoteIsCutAtAWord() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let quote = ServerRefusal.quote(fromBody: long)!
        XCTAssertTrue(quote.hasSuffix("word…"))
        XCTAssertLessThanOrEqual(quote.count, ServerRefusal.maxQuoteLength + 1)
        let oneWord = String(repeating: "x", count: 300)
        XCTAssertEqual(ServerRefusal.quote(fromBody: oneWord), String(repeating: "x", count: ServerRefusal.maxQuoteLength) + "…")
    }
}
