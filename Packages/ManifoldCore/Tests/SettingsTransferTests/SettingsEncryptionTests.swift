import CryptoKit
import XCTest
@testable import SettingsTransfer
import StreamBookmarkModel

/// docs/SETTINGS_EXPORT_PLAN.md §8, the encrypted file. Each `open` costs one real derivation.
final class SettingsEncryptionTests: XCTestCase {
    private let password = "a long enough password"
    private let provenance = SettingsFile.Provenance(appVersion: "0.9.2", appBuild: "24",
                                                     exportedAt: Date(timeIntervalSince1970: 1_793_000_000))
    private let overrides: [String: Any] = ["view.inspector": ["key": "i", "modifiers": ["command", "option"]]]
    private let wrong = SealedFile.OpenFailed()

    /// Made by Python's `hashlib` and `cryptography`, not by this code: a second implementation. The values are not secret.
    private enum Vector {
        static let password = "vector password not secret"
        static let salt = Data(0..<16)
        static let nonce = Data(0xa0..<0xac)
        static let key = "b645bd313173f0e892a5e9470f7e34e2c9be96d7b58985ab4ae85906b3d1fd6c"
        static let header = #"{"appBuild":"24","appVersion":"0.9.2","encryption":{"cipher":"AES-GCM-256","iterations":1000000,"kdf":"PBKDF2-HMAC-SHA256","nonce":"oKGio6Slpqeoqaqr","salt":"AAECAwQFBgcICQoLDA0ODw=="},"exportedAt":"2026-10-26T07:33:20Z","formatVersion":1,"kind":"com.graviton.manifold.settings","sections":{"shortcuts":{"count":1,"version":1},"streams":{"count":1,"version":1}}}"#
        static let payload = "N8Yk5VlBPrXko2g1jlzLBXVT0POA5bJF+uCC5LvaizSODea5muSeezCeRfxos2+ejBeNuvb1i20qwQlLZ8bypnQTi3V6DYoGSisz0gA1kqQYsiBvkOghmoMLj/KZs6guEbJd5PAVczwftRo1tbtD5MUA4++BDKKwDPWpL+E7Hd3B/YtYssxyTfe8ku/rIrxMeZnUAWQKc9JYmts0mBbPjVeFssVDXu1B3NMLVvLGMLw+VoO+EOUllEoXGRJOArNqkzjs/zLZDEvHLlXGy4VdNn1m8sutKRHdLv+iQxyJf/8ptPlWim6eAHTAOYFcSh9Er80shxh4y3c6j9bgvoeXe8jmFCwOp2/8Y0bPmm9r1428tVYYmBahD39OcighNlNM/sMeoWfSCarhPDAgSa+aIGt0UyIfiyqoP1eS9gJ+yow6sAETWZREyJXhO3kxRg=="
        static let file = #"{"appBuild":"24","appVersion":"0.9.2","encryption":{"cipher":"AES-GCM-256","iterations":1000000,"kdf":"PBKDF2-HMAC-SHA256","nonce":"oKGio6Slpqeoqaqr","salt":"AAECAwQFBgcICQoLDA0ODw=="},"exportedAt":"2026-10-26T07:33:20Z","formatVersion":1,"kind":"com.graviton.manifold.settings","payload":"N8Yk5VlBPrXko2g1jlzLBXVT0POA5bJF+uCC5LvaizSODea5muSeezCeRfxos2+ejBeNuvb1i20qwQlLZ8bypnQTi3V6DYoGSisz0gA1kqQYsiBvkOghmoMLj/KZs6guEbJd5PAVczwftRo1tbtD5MUA4++BDKKwDPWpL+E7Hd3B/YtYssxyTfe8ku/rIrxMeZnUAWQKc9JYmts0mBbPjVeFssVDXu1B3NMLVvLGMLw+VoO+EOUllEoXGRJOArNqkzjs/zLZDEvHLlXGy4VdNn1m8sutKRHdLv+iQxyJf/8ptPlWim6eAHTAOYFcSh9Er80shxh4y3c6j9bgvoeXe8jmFCwOp2/8Y0bPmm9r1428tVYYmBahD39OcighNlNM/sMeoWfSCarhPDAgSa+aIGt0UyIfiyqoP1eS9gJ+yow6sAETWZREyJXhO3kxRg==","sections":{"shortcuts":{"count":1,"version":1},"streams":{"count":1,"version":1}}}"#
    }

    private func entry(_ name: String = "Studio A") -> StreamExportEntry {
        StreamExportEntry(name: name, type: "srt", url: "srt://encoder.example.net:9000?streamid=abc/def",
                          passphrase: "vector-passphrase", audioOffsetMs: 80, colorOverride: "rec709")
    }

    private func encoded(_ streams: [StreamExportEntry]? = nil) throws -> Data {
        try SettingsFile.encodeEncrypted(shortcuts: overrides, streams: streams ?? [entry()], password: password,
                                         provenance: provenance)
    }

    private func sealed(_ data: Data) throws -> SealedFile {
        guard case .encrypted(let file) = try SettingsFile.inspect(data).get() else {
            throw XCTSkip("not an encrypted file")
        }
        return file
    }

    private func root(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private func assertOneMessage(_ data: Data, password: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try sealed(data).open(password: password ?? self.password)
        guard case .failure(let failure) = result else { return XCTFail("opened", file: file, line: line) }
        XCTAssertEqual(failure, wrong, file: file, line: line)
        XCTAssertEqual(failure.message, "Wrong password, or the file has been changed.", file: file, line: line)
    }

    // MARK: Round trip

    func testRoundTrip() throws {
        let document = try sealed(try encoded()).open(password: password).get()
        XCTAssertEqual(document.appVersion, "0.9.2")
        XCTAssertEqual(document.exportedAt, provenance.exportedAt)
        XCTAssertEqual(document.shortcuts?["view.inspector"] as? [String: AnyHashable],
                       overrides["view.inspector"] as? [String: AnyHashable])
        let stream = try XCTUnwrap(document.streams?.first as? [String: Any])
        XCTAssertEqual(stream["url"] as? String, entry().url)
        XCTAssertEqual(stream["passphrase"] as? String, "vector-passphrase")
        XCTAssertEqual(document.streams?.count, 1)
        XCTAssertTrue(document.left.isEmpty)
    }

    func testShortcutsCanBeLeftOut() throws {
        let data = try SettingsFile.encodeEncrypted(shortcuts: nil, streams: [entry()], password: password, provenance: provenance)
        let document = try sealed(data).open(password: password).get()
        XCTAssertNil(document.shortcuts)
        XCTAssertEqual(document.streams?.count, 1)
        XCTAssertNil((try root(data)["sections"] as? [String: Any])?["shortcuts"])
    }

    func testFreshSaltAndNonceEachExport() throws {
        let a = try root(try encoded())["encryption"] as? [String: Any]
        let b = try root(try encoded())["encryption"] as? [String: Any]
        XCTAssertNotEqual(a?["salt"] as? String, b?["salt"] as? String)
        XCTAssertNotEqual(a?["nonce"] as? String, b?["nonce"] as? String)
    }

    func testHeaderFields() throws {
        let r = try root(try encoded([entry(), entry("B")]))
        XCTAssertEqual(Set(r.keys), ["appBuild", "appVersion", "encryption", "exportedAt", "formatVersion", "kind", "payload", "sections"])
        let e = try XCTUnwrap(r["encryption"] as? [String: Any])
        XCTAssertEqual(Set(e.keys), ["cipher", "iterations", "kdf", "nonce", "salt"])
        XCTAssertEqual(e["iterations"] as? Int, 1_000_000)
        let s = try XCTUnwrap(r["sections"] as? [String: [String: Int]])
        XCTAssertEqual(s, ["shortcuts": ["count": 1, "version": 1], "streams": ["count": 2, "version": 1]])
    }

    // MARK: Frozen vector

    func testKeyMatchesTheVector() throws {
        let key = try XCTUnwrap(SettingsEncryption.deriveKey(password: Vector.password, salt: Vector.salt, iterations: 1_000_000))
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex, Vector.key)
    }

    func testEncodingMatchesTheVector() throws {
        let data = try SettingsFile.encodeEncrypted(shortcuts: overrides, streams: [entry()], password: Vector.password,
                                                    provenance: provenance, iterations: 1_000_000, salt: Vector.salt,
                                                    nonce: Vector.nonce)
        let r = try root(data)
        XCTAssertEqual(r["payload"] as? String, Vector.payload)
        XCTAssertEqual(SettingsEncryption.authenticatedHeader(r).map { String(decoding: $0, as: UTF8.self) }, Vector.header)
    }

    func testTheFrozenFileOpens() throws {
        let document = try sealed(Data(Vector.file.utf8)).open(password: Vector.password).get()
        XCTAssertEqual(document.streams?.count, 1)
        XCTAssertEqual(document.shortcuts?.count, 1)
    }

    // MARK: Failures

    func testWrongPasswordIsTheOneMessage() throws {
        try assertOneMessage(try encoded(), password: "another long password")
    }

    private func changing(_ data: Data, payload change: (inout Data) -> Void) throws -> Data {
        var r = try root(data)
        var bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(r["payload"] as? String)))
        change(&bytes)
        r["payload"] = bytes.base64EncodedString()
        return try json(r)
    }

    func testAFlippedBitInThePayloadOrTag() throws {
        let data = try encoded()
        try assertOneMessage(try changing(data) { $0[$0.startIndex] ^= 1 })
        try assertOneMessage(try changing(data) { $0[$0.startIndex + $0.count / 2] ^= 0x80 })
        try assertOneMessage(try changing(data) { $0[$0.endIndex - 17] ^= 1 })     // the last byte of ciphertext
        try assertOneMessage(try changing(data) { $0[$0.endIndex - 16] ^= 1 })     // the first of the tag
        try assertOneMessage(try changing(data) { $0[$0.endIndex - 1] ^= 1 })      // the last of the tag
    }

    func testAShortenedPayload() throws {
        let data = try encoded()
        try assertOneMessage(try changing(data) { $0 = $0.dropLast() })
        try assertOneMessage(try changing(data) { $0 = $0.prefix(10) })
        try assertOneMessage(try changing(data) { $0 = Data() })
    }

    func testAPayloadThatIsNotBase64() throws {
        var r = try root(try encoded())
        r["payload"] = "%%%"
        try assertOneMessage(try json(r))
    }

    func testAFileCutMidJSONIsRefusedBeforeThePrompt() throws {
        let data = try encoded()
        guard case .failure(let error) = SettingsFile.inspect(data.prefix(data.count / 2)) else { return XCTFail("read") }
        XCTAssertEqual(error, .damaged)
        XCTAssertEqual(error.message, "This file is damaged, or it isn’t a Manifold settings file.")
    }

    func testAFileWithoutAHeaderIsRefusedBeforeThePrompt() throws {
        for change: (inout [String: Any]) -> Void in [
            { $0["encryption"] = "AES" }, { $0["payload"] = nil }, { $0["payload"] = 7 }, { $0["sections"] = nil },
        ] {
            var r = try root(try encoded())
            change(&r)
            guard case .failure(let error) = SettingsFile.inspect(try json(r)) else { return XCTFail("read") }
            XCTAssertEqual(error, .damaged)
        }
    }

    func testEveryHeaderFieldIsAuthenticated() throws {
        let data = try encoded()
        func edited(_ change: (inout [String: Any], inout [String: Any]) -> Void) throws -> Data {
            var r = try root(data)
            var e = try XCTUnwrap(r["encryption"] as? [String: Any])
            change(&r, &e)
            r["encryption"] = e
            return try json(r)
        }
        try assertOneMessage(try edited { r, _ in r["appVersion"] = "9.9.9" })
        try assertOneMessage(try edited { r, _ in r["appBuild"] = "99" })
        try assertOneMessage(try edited { r, _ in r["exportedAt"] = "2020-01-01T00:00:00Z" })
        try assertOneMessage(try edited { r, _ in r["sections"] = ["streams": ["count": 99, "version": 1]] })
        try assertOneMessage(try edited { r, _ in r["extra"] = true })
        try assertOneMessage(try edited { _, e in e["salt"] = Data(repeating: 7, count: 16).base64EncodedString() })
        try assertOneMessage(try edited { _, e in e["nonce"] = Data(repeating: 7, count: 12).base64EncodedString() })
        try assertOneMessage(try edited { _, e in e["iterations"] = 1_000_001 })
        try assertOneMessage(try edited { _, e in e["cipher"] = "AES-GCM-128" })
        try assertOneMessage(try edited { _, e in e["kdf"] = "PBKDF2-HMAC-SHA1" })
        // The reader acts first on these two, and writes nothing.
        guard case .failure(.notSettings) = SettingsFile.inspect(try edited { r, _ in r["kind"] = "x" }) else { return XCTFail("kind") }
        guard case .failure(.newerFormat) = SettingsFile.inspect(try edited { r, _ in r["formatVersion"] = 2 }) else {
            return XCTFail("formatVersion")
        }
    }

    func testIterationsOutOfRangeDoNotRunTheKDF() throws {
        for iterations in [1, 599_999, 10_000_001, 4_000_000_000] {
            var r = try root(try encoded())
            var e = try XCTUnwrap(r["encryption"] as? [String: Any])
            e["iterations"] = iterations
            r["encryption"] = e
            let start = Date()
            try assertOneMessage(try json(r))
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "\(iterations) ran the KDF")
        }
    }

    // MARK: No plaintext

    func testNoStreamValueIsInAnEncryptedFile() throws {
        let canaries = ["CANARYPATH", "CANARYTOKEN", "CANARYSTREAMID", "CANARYUSER", "CANARYPASSWORD", "CANARYPASSPHRASE",
                        "CANARYNAME", "canaryhost"]
        let stream = StreamExportEntry(name: "CANARYNAME", type: "srt",
                                       url: "srt://CANARYUSER:CANARYPASSWORD@canaryhost.example.net:9000/CANARYPATH"
                                           + "?token=CANARYTOKEN&streamid=CANARYSTREAMID",
                                       passphrase: "CANARYPASSPHRASE", audioOffsetMs: nil, colorOverride: nil)
        let data = try encoded([stream])
        let text = String(decoding: data, as: UTF8.self)
        for canary in canaries { XCTAssertFalse(text.localizedCaseInsensitiveContains(canary), canary) }
        // Base64 hides nothing by itself, so look in the decoded bytes too.
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(try root(data)["payload"] as? String)))
        for canary in canaries { XCTAssertNil(payload.range(of: Data(canary.utf8)), canary) }
    }

    func testAPlainFileNeverReadsStreams() throws {
        let plain = try json(["kind": SettingsFile.kind, "formatVersion": 1,
                              "sections": ["streams": ["version": 1, "entries": [["name": "A", "url": "srt://a"]]]]])
        let document = try SettingsFile.read(plain).get()
        XCTAssertNil(document.streams)
        XCTAssertEqual(document.left, [.init(name: "streams", reason: .notEncrypted)])
    }

    func testAPlainReaderStillRefusesAnEncryptedFile() throws {
        guard case .failure(.encrypted) = SettingsFile.read(try encoded()) else { return XCTFail("read") }
    }

    // MARK: Sections inside

    func testANewerStreamsSectionCostsThatSection() throws {
        let parsed = SettingsFile.parseSections(["streams": ["version": 2, "entries": [Any]()],
                                                 "shortcuts": ["version": 1, "overrides": [String: Any]()]], encrypted: true)
        XCTAssertNil(parsed.streams)
        XCTAssertNotNil(parsed.shortcuts)
        XCTAssertEqual(parsed.left, [.init(name: "streams", reason: .newerVersion)])
    }

    func testADamagedStreamsSectionCostsThatSection() {
        for section: Any in ["x", ["version": 1], ["version": 1, "entries": "x"], ["entries": [Any]()]] {
            let parsed = SettingsFile.parseSections(["streams": section], encrypted: true)
            XCTAssertNil(parsed.streams)
            XCTAssertEqual(parsed.left, [.init(name: "streams", reason: .malformed)])
        }
    }

    // MARK: Password

    func testPasswordRules() {
        XCTAssertNotNil(SettingsEncryption.passwordProblem("elevenchars", confirmation: "elevenchars"))
        XCTAssertNil(SettingsEncryption.passwordProblem("twelve chars", confirmation: "twelve chars"))
        XCTAssertEqual(SettingsEncryption.passwordProblem("twelve chars", confirmation: "twelve charz"),
                       "The two passwords don’t match.")
        XCTAssertThrowsError(try SettingsFile.encodeEncrypted(shortcuts: nil, streams: [], password: "short", provenance: provenance)) {
            XCTAssertEqual($0 as? SettingsEncryption.EncodeError, .passwordTooShort)
        }
    }

    func testNFCAndNFDFormsOpenTheSameFile() throws {
        let composed = "caf\u{e9} caf\u{e9} caf\u{e9}"
        let decomposed = "cafe\u{301} cafe\u{301} cafe\u{301}"
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let data = try SettingsFile.encodeEncrypted(shortcuts: nil, streams: [entry()], password: composed, provenance: provenance)
        XCTAssertNotNil(try? sealed(data).open(password: decomposed).get())
    }

    func testAFileTooLargeToReadIsNotWritten() {
        let big = StreamExportEntry(name: "A", type: "web", url: "https://a.example/" + String(repeating: "x", count: 2_000_000),
                                    passphrase: nil, audioOffsetMs: nil, colorOverride: nil)
        XCTAssertThrowsError(try encoded([big])) { XCTAssertEqual($0 as? SettingsEncryption.EncodeError, .tooLarge) }
    }
}
