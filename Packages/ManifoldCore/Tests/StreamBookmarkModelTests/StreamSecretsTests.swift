//
//  StreamSecretsTests.swift
//  StreamBookmarkModelTests
//
//  Privacy P2 (docs/PRIVACY_AUDIT.md): the migration of stream secrets out of the plist, against an
//  in-memory store. Every secret below is SYNTHETIC and carries the token `P2SEED`, so "no secret in
//  the plist" is one search; hosts are under `example.invalid` and carry no token.
//
//  "Same target as before" is checked against `PreP2`, a verbatim port of the pre-P2 app code
//  (App/Preferences.swift at 9bedbe6: `migratePassphrasesToKeychain` at launch, then `connectURL`).
//

import XCTest
@testable import StreamBookmarkModel

/// A Keychain in a dictionary, with a write log and a fault switch per operation.
private final class MemoryStore: StreamSecretStore {
    var items: [String: String] = [:]
    var reads = 0, writes = 0, deletes = 0
    var failRead: Int32?
    var failWrite: Int32?
    /// Corrupts what a write stores, for the read-back checks.
    var corruptWrites = false
    /// Drops what a write stores (reports success), for the read-back checks.
    var loseWrites = false
    /// Failing reads only after this many successful ones (the read-back after a good first read).
    var failReadAfter: Int?
    var onWrite: ((MemoryStore) -> Void)?

    func read(_ account: String) -> StreamSecretRead {
        reads += 1
        if let after = failReadAfter, reads > after { return .failed(-25293) }
        if let s = failRead { return .failed(s) }
        return items[account].map(StreamSecretRead.found) ?? .absent
    }
    func write(_ value: String, for account: String) -> Int32 {
        writes += 1
        if let s = failWrite { return s }
        // Only a secret item is corrupted, so the restore of a pre-P2 passphrase lands intact.
        if !loseWrites { items[account] = corruptWrites && value.hasPrefix("{") ? value + "x" : value }
        onWrite?(self)
        return 0
    }
    func delete(_ account: String) { deletes += 1; items[account] = nil }
}

/// The pre-P2 code, ported verbatim (the store's two functions), over the same in-memory items.
private enum PreP2 {
    /// `migratePassphrasesToKeychain`: an inline passphrase moves to the item, the URL is stripped.
    static func launch(_ list: [StreamBookmark], _ items: inout [String: String]) -> [StreamBookmark] {
        list.map { bookmark in
            guard let url = bookmark.url,
                  let split = StreamSecrets.strippingPassphrase(from: url),
                  let passphrase = split.passphrase else { return bookmark }
            items[bookmark.id.uuidString] = passphrase
            var moved = bookmark
            moved.urlString = split.url.absoluteString
            return moved
        }
    }
    /// `connectURL`.
    static func dial(_ bookmark: StreamBookmark, _ items: [String: String]) -> URL? {
        guard let url = bookmark.url else { return nil }
        guard let secret = items[bookmark.id.uuidString], !secret.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var q = components.queryItems ?? []
        q.removeAll { $0.name.lowercased() == "passphrase" }
        q.append(URLQueryItem(name: "passphrase", value: secret))
        components.queryItems = q
        return components.url ?? url
    }
}

final class StreamSecretsTests: XCTestCase {

    // MARK: - Fixtures: every transport and every kind of secret

    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    /// (entry as a pre-P2 build stored it, the pre-P2 item's value if any)
    private let fixtures: [(StreamBookmark, String?)] = [
        // SRT, passphrase in the Keychain (the normal pre-P2 shape), plain streamid in the URL.
        (StreamBookmark(id: id(1), name: "SRT keychain pass", urlString: "srt://srt-a.example.invalid:9000?streamid=P2SEED-SID-0001&latency=120",
                        type: .srt), "P2SEED-PASS-0001"),
        // SRT, an inline passphrase from before the Keychain (pre-3e), and an access-control streamid.
        (StreamBookmark(id: id(2), name: "SRT inline pass", urlString: "srt://srt-b.example.invalid:9001?streamid=%23!::r=live/P2SEED-SID-0002,m=request&passphrase=P2SEED-PASS-0002",
                        type: .srt), nil),
        // SRT, an inline passphrase AND a stale item: the pre-P2 launch moved the inline one over it.
        (StreamBookmark(id: id(3), name: "SRT both", urlString: "srt://srt-c.example.invalid:9002?passphrase=P2SEED-PASS-0003&streamid=P2SEED-SID-0003",
                        type: .srt, audioOffsetMs: 80), "P2SEED-STALE-0003"),
        // SRT, no passphrase, streamid only; IPv6 host.
        (StreamBookmark(id: id(4), name: "SRT v6", urlString: "srt://[fd00::1]:9003?streamid=P2SEED-SID-0004",
                        type: .srt, colorOverride: "rec709"), nil),
        // WHEP, the stream key is the path (the Cloudflare shape, on a fake host).
        (StreamBookmark(id: id(5), name: "WHEP path key", urlString: "https://customer-fake.example.invalid/P2SEED-KEY-0005/webRTC/play",
                        type: .web), nil),
        // WHEP, a query token with escaped characters, and a fragment.
        (StreamBookmark(id: id(6), name: "WHEP token", urlString: "https://whep.example.invalid:8443/live/whep?token=P2SEED-TOK-0006%2Fx%3D&x=1#P2SEED-FRAG-0006",
                        type: .web), nil),
        // HLS, a signed URL: path key and query signature.
        (StreamBookmark(id: id(7), name: "HLS signed", urlString: "https://hls.example.invalid/P2SEED-KEY-0007/master.m3u8?Expires=1&Signature=P2SEED-SIG-0007&Key-Pair-Id=P2SEED-KPI-0007",
                        type: .hls), nil),
        // HLS, credentials in the user part.
        (StreamBookmark(id: id(8), name: "HLS userinfo", urlString: "https://viewer:P2SEED-UPW-0008@hls2.example.invalid/live/index.m3u8",
                        type: .hls), nil),
        // HLS with nothing secret in it: moves all the same (no rule can tell).
        (StreamBookmark(id: id(9), name: "HLS public", urlString: "https://hls3.example.invalid/bipbop/master.m3u8",
                        type: .hls), nil),
        // A web entry with an item: `add` strips a pasted passphrase from ANY URL, so this exists.
        (StreamBookmark(id: id(10), name: "Web with item", urlString: "https://web.example.invalid/whep/P2SEED-KEY-0010",
                        type: .web), "P2SEED-PASS-0010"),
        // An empty item (a pre-P2 write of ""): the pre-P2 dial ignored it.
        (StreamBookmark(id: id(11), name: "SRT empty item", urlString: "srt://srt-d.example.invalid:9004?streamid=P2SEED-SID-0011",
                        type: .srt), ""),
    ]

    private var seededList: [StreamBookmark] { fixtures.map(\.0) }

    private func seededStore() -> MemoryStore {
        let s = MemoryStore()
        for (b, item) in fixtures { if let item { s.items[b.id.uuidString] = item } }
        return s
    }

    /// What the pre-P2 build dialled for each entry, after its own launch migration.
    private func preP2Dials() -> [URL?] {
        var items = seededStore().items
        let launched = PreP2.launch(seededList, &items)
        return launched.map { PreP2.dial($0, items) }
    }

    private func dials(_ list: [StreamBookmark], _ store: MemoryStore) -> [URL?] {
        list.map { b -> URL? in
            guard case .secret(let s) = StreamSecrets.resolve(b, read: store.read(b.secretRef ?? b.id.uuidString))
            else { return nil }
            return StreamSecrets.dialURL(s)
        }
    }

    private func plistText(_ list: [StreamBookmark]) throws -> String {
        String(decoding: try StreamBookmark.storeEncoding(list), as: UTF8.self)
    }

    // MARK: - The migration

    func testMigrationLeavesNoSecretInThePlistAndEveryEntryDialsItsPreP2Target() throws {
        // The control: the seeded plist carries secrets, so the search below can find them.
        XCTAssertTrue(try plistText(seededList).contains("P2SEED"))

        let store = seededStore()
        let out = StreamSecrets.migrate(seededList, store: store)
        XCTAssertEqual(out.moved, fixtures.count)
        XCTAssertEqual(out.kept, 0)
        XCTAssertTrue(out.changed)

        let text = try plistText(out.bookmarks)
        XCTAssertFalse(text.contains("P2SEED"), "no seeded secret in the stored list")
        XCTAssertFalse(text.contains("viewer"), "no user part")
        XCTAssertEqual(out.bookmarks.map(\.urlString), Array(repeating: "", count: fixtures.count))
        XCTAssertEqual(out.bookmarks.map(\.secretRef), seededList.map { $0.id.uuidString })
        XCTAssertEqual(out.bookmarks.map(\.address), [
            "srt://srt-a.example.invalid:9000", "srt://srt-b.example.invalid:9001",
            "srt://srt-c.example.invalid:9002", "srt://[fd00::1]:9003",
            "https://customer-fake.example.invalid", "https://whep.example.invalid:8443",
            "https://hls.example.invalid", "https://hls2.example.invalid", "https://hls3.example.invalid",
            "https://web.example.invalid", "srt://srt-d.example.invalid:9004",
        ])
        XCTAssertEqual(out.bookmarks.map(\.displayHost), seededList.map(\.displayHost), "the list shows the same host")

        // Every field but the three is the entry's own.
        for (a, b) in zip(seededList, out.bookmarks) {
            XCTAssertEqual([a.id.uuidString, a.name, a.type.rawValue], [b.id.uuidString, b.name, b.type.rawValue])
            XCTAssertEqual(a.audioOffsetMs, b.audioOffsetMs); XCTAssertEqual(a.colorOverride, b.colorOverride)
        }

        // The same target, byte for byte, as the pre-P2 build — and as the P2 build before migrating.
        let expected = preP2Dials()
        XCTAssertEqual(dials(out.bookmarks, store), expected)
        XCTAssertEqual(dials(seededList, seededStore()), expected)
        XCTAssertFalse(expected.contains(nil))

        // The item holds the whole secret, the passphrase as its own field.
        let three = StreamSecret.decode(store.items[Self.id(3).uuidString]!)
        XCTAssertEqual(three, StreamSecret(url: "srt://srt-c.example.invalid:9002?streamid=P2SEED-SID-0003",
                                           passphrase: "P2SEED-PASS-0003"), "the inline passphrase wins, as at a pre-P2 launch")
        XCTAssertEqual(StreamSecret.decode(store.items[Self.id(11).uuidString]!)?.passphrase, nil)
    }

    func testASecondRunReadsNothingWritesNothingAndChangesNothing() throws {
        let store = seededStore()
        let first = StreamSecrets.migrate(seededList, store: store)
        let items = store.items, reads = store.reads, writes = store.writes
        let second = StreamSecrets.migrate(first.bookmarks, store: store)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.already, fixtures.count)
        XCTAssertEqual(second.keychainWrites, 0)
        XCTAssertEqual(store.reads, reads, "a migrated entry is not read at launch")
        XCTAssertEqual(store.writes, writes)
        XCTAssertEqual(store.items, items)
        XCTAssertEqual(try StreamBookmark.storeEncoding(second.bookmarks), try StreamBookmark.storeEncoding(first.bookmarks))
        XCTAssertTrue(second.log.isEmpty)
    }

    /// The process dies after k Keychain writes, before the plist is written: the plist is the
    /// original, the Keychain has k new items. The next launch converges on the uninterrupted result.
    func testAnInterruptedRunResumesToTheSameResult() throws {
        let reference = seededStore()
        let whole = StreamSecrets.migrate(seededList, store: reference)
        for k in 1..<fixtures.count {
            let store = seededStore()
            var atDeath: [String: String]?
            store.onWrite = { s in if s.writes == k { atDeath = s.items } }
            _ = StreamSecrets.migrate(seededList, store: store)   // its outcome is never persisted
            let died = MemoryStore(); died.items = try XCTUnwrap(atDeath)

            let resumed = StreamSecrets.migrate(seededList, store: died)
            XCTAssertEqual(resumed.relinked, k, "k=\(k): the items already written are linked, not rewritten")
            XCTAssertEqual(resumed.moved, fixtures.count - k)
            XCTAssertEqual(resumed.kept, 0)
            XCTAssertEqual(try StreamBookmark.storeEncoding(resumed.bookmarks),
                           try StreamBookmark.storeEncoding(whole.bookmarks), "k=\(k)")
            XCTAssertEqual(died.items, reference.items, "k=\(k)")
            XCTAssertEqual(dials(resumed.bookmarks, died), preP2Dials(), "k=\(k)")
        }
    }

    func testARefusedReadLeavesEveryEntryAndItemAlone() throws {
        let store = seededStore(); store.failRead = -25293
        let before = store.items
        let out = StreamSecrets.migrate(seededList, store: store)
        XCTAssertFalse(out.changed)
        XCTAssertEqual(out.kept, fixtures.count)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.items, before)
        XCTAssertEqual(try StreamBookmark.storeEncoding(out.bookmarks), try StreamBookmark.storeEncoding(seededList))
        XCTAssertTrue(out.log.first?.contains("OSStatus -25293") == true)
        assertNoSecretIn(out.log)
    }

    func testAFailedWriteLeavesTheEntryAndThePreP2PassphraseAlone() throws {
        let store = seededStore(); store.failWrite = -25308
        let before = store.items
        let out = StreamSecrets.migrate(seededList, store: store)
        XCTAssertFalse(out.changed)
        XCTAssertEqual(out.kept, fixtures.count)
        XCTAssertEqual(store.items, before)
        XCTAssertEqual(try StreamBookmark.storeEncoding(out.bookmarks), try StreamBookmark.storeEncoding(seededList))
        assertNoSecretIn(out.log)
    }

    /// Written, but the read-back does not confirm it: the entry stays, and the item is put back as
    /// it was — the pre-P2 passphrase rewritten, a new item deleted.
    func testAnUnconfirmedWriteIsUndoneAndTheEntryKept() throws {
        for mode in ["differs", "missing", "refused"] {
            let store = seededStore()
            switch mode {
            case "differs": store.corruptWrites = true
            case "missing": store.loseWrites = true
            default:        store.failReadAfter = 1   // the first read works, every later one is refused
            }
            let before = store.items
            let out = StreamSecrets.migrate([seededList[0], seededList[4]], store: store)
            XCTAssertEqual(out.kept, 2, mode)
            XCTAssertEqual(store.items, before, "\(mode): the pre-P2 item restored, the new one removed")
            XCTAssertFalse(out.changed, mode)
            XCTAssertEqual(out.bookmarks, [seededList[0], seededList[4]], mode)
            assertNoSecretIn(out.log)
        }
    }

    /// One bad entry does not stop the others.
    func testEntriesAreIndependent() throws {
        let store = seededStore()
        var list = seededList
        list.insert(StreamBookmark(id: Self.id(99), name: "broken", urlString: "", type: .web), at: 2)
        let out = StreamSecrets.migrate(list, store: store)
        XCTAssertEqual(out.kept, 1)
        XCTAssertEqual(out.moved, fixtures.count)
        XCTAssertEqual(out.bookmarks[2], list[2])
        XCTAssertTrue(out.log.contains { $0.hasPrefix("entry 3 of 12:") })
    }

    func testAMachineThatNeverHadASecret() throws {
        let store = MemoryStore()
        let empty = StreamSecrets.migrate([], store: store)
        XCTAssertFalse(empty.changed); XCTAssertEqual(store.reads + store.writes, 0); XCTAssertTrue(empty.log.isEmpty)
        // A pre-P2 entry with no item at all (no passphrase, ever).
        let one = StreamSecrets.migrate([seededList[8]], store: store)
        XCTAssertEqual(one.moved, 1)
        XCTAssertEqual(StreamSecret.decode(store.items[Self.id(9).uuidString]!),
                       StreamSecret(url: "https://hls3.example.invalid/bipbop/master.m3u8", passphrase: nil))
    }

    // MARK: - Older builds

    /// An older build that re-saves a migrated list writes only the keys it knows: `address` and
    /// `secretRef` go, `urlString` stays empty. It cannot dial the entry (fail closed, never a wrong
    /// target), and the next P2 launch links it back with no write.
    func testAnOlderBuildsReSaveIsLinkedBackWithoutAWrite() throws {
        struct OlderBookmark: Codable { let id: UUID; var name: String; var urlString: String; var type: StreamType
                                        var audioOffsetMs: Int?; var colorOverride: String? }
        let store = seededStore()
        let migrated = StreamSecrets.migrate(seededList, store: store).bookmarks
        let older = try JSONDecoder().decode([OlderBookmark].self, from: try StreamBookmark.storeEncoding(migrated))
        XCTAssertTrue(older.allSatisfy { URL(string: $0.urlString) == nil }, "an older build has no URL to dial")
        let reSaved = try JSONDecoder().decode([StreamBookmark].self, from: try JSONEncoder().encode(older))
        XCTAssertTrue(reSaved.allSatisfy { !$0.secretInKeychain })

        let writes = store.writes
        let out = StreamSecrets.migrate(reSaved, store: store)
        XCTAssertEqual(out.relinked, fixtures.count)
        XCTAssertEqual(store.writes, writes)
        XCTAssertEqual(try StreamBookmark.storeEncoding(out.bookmarks), try StreamBookmark.storeEncoding(migrated))
    }

    /// An older build that edits a migrated entry's URL (typed in full) keeps the item untouched; P2
    /// takes the plist's URL and keeps the item's passphrase.
    func testAnOlderBuildsEditedURLWinsAndKeepsThePassphrase() throws {
        let store = seededStore()
        var migrated = StreamSecrets.migrate([seededList[0]], store: store).bookmarks[0]
        migrated.urlString = "srt://srt-a.example.invalid:9100?streamid=P2SEED-SID-NEW"
        migrated.address = nil; migrated.secretRef = nil
        let out = StreamSecrets.migrate([migrated], store: store)
        XCTAssertEqual(out.moved, 1)
        XCTAssertEqual(StreamSecret.decode(store.items[Self.id(1).uuidString]!),
                       StreamSecret(url: "srt://srt-a.example.invalid:9100?streamid=P2SEED-SID-NEW", passphrase: "P2SEED-PASS-0001"))
    }

    // MARK: - Resolve after migration

    func testAMigratedEntryWithoutItsItemIsMissingNotDialledBare() throws {
        let store = seededStore()
        let migrated = StreamSecrets.migrate([seededList[0]], store: store).bookmarks[0]
        XCTAssertEqual(StreamSecrets.resolve(migrated, read: .absent), .missing)
        XCTAssertEqual(StreamSecrets.resolve(migrated, read: .failed(-128)), .failed(-128))
        XCTAssertEqual(StreamSecrets.resolve(migrated, read: .found("P2SEED-PASS-0001")), .unusable,
                       "a bare passphrase where the URL should be is not dialled")
        // A migrated entry is never re-migrated, even when its item is gone: nothing to move it from.
        let again = StreamSecrets.migrate([migrated], store: MemoryStore())
        XCTAssertEqual(again.already, 1); XCTAssertFalse(again.changed)
    }

    // MARK: - The parts

    func testTheSecretsItemFormat() throws {
        let s = StreamSecret(url: "srt://h.example.invalid:1?streamid=P2SEED-SID", passphrase: "P2SEED-PASS")
        let value = try XCTUnwrap(s.encoded())
        XCTAssertEqual(StreamSecret.decode(value), s)
        XCTAssertEqual(s.encoded(), value, "deterministic bytes")
        XCTAssertNil(StreamSecret.decode("P2SEED-PASS-0001"), "a pre-P2 passphrase is not a secret item")
        XCTAssertNil(StreamSecret.decode(#"{"url":"x","v":1}"#), "no marker, not ours")
        XCTAssertNil(StreamSecret.decode(#"{"kind":"manifold.stream-secret","url":"x","v":2}"#), "a later version is not guessed at")
        XCTAssertNil(StreamSecret(url: "x", passphrase: "").passphrase)
    }

    func testTheAddressKeepsSchemeHostAndPortOnly() {
        let cases: [(String, String?)] = [
            ("srt://h.example.invalid:9000?streamid=P2SEED&passphrase=P2SEED", "srt://h.example.invalid:9000"),
            ("https://u:P2SEED@h.example.invalid/P2SEED/x.m3u8?t=P2SEED#P2SEED", "https://h.example.invalid"),
            ("https://h.example.invalid:8443/P2SEED", "https://h.example.invalid:8443"),
            ("srt://[fd00::1]:9000?streamid=P2SEED", "srt://[fd00::1]:9000"),
            ("SRT://H.example.invalid:1", "SRT://H.example.invalid:1"),
            ("srt:/no-host", nil),
        ]
        for (raw, want) in cases {
            XCTAssertEqual(URL(string: raw).flatMap(StreamSecrets.address(of:)), want, raw)
        }
    }

    func testJoiningIsThePreP2Join() {
        let u = URL(string: "srt://h.example.invalid:1?passphrase=OLD&streamid=a%2Fb")!
        XCTAssertEqual(StreamSecrets.joining(u, passphrase: nil), u)
        XCTAssertEqual(StreamSecrets.joining(u, passphrase: ""), u)
        let joined = StreamSecrets.joining(u, passphrase: "P2SEED-NEW")
        XCTAssertEqual(URLComponents(url: joined, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name),
                       ["streamid", "passphrase"])
        XCTAssertEqual(joined, PreP2.dial(StreamBookmark(id: Self.id(1), name: "", urlString: u.absoluteString, type: .srt),
                                          [Self.id(1).uuidString: "P2SEED-NEW"]))
    }

    // MARK: - Helpers

    private func assertNoSecretIn(_ log: [String], file: StaticString = #filePath, line: UInt = #line) {
        for l in log {
            XCTAssertFalse(l.contains("P2SEED"), "a secret in a log line", file: file, line: line)
            XCTAssertFalse(l.contains("example.invalid"), "a host in a log line", file: file, line: line)
            XCTAssertFalse(fixtures.contains { l.contains($0.0.name) }, "a name in a log line", file: file, line: line)
        }
    }
}
