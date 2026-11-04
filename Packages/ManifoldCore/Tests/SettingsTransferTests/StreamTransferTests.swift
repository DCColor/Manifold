import XCTest
@testable import SettingsTransfer
import StreamBookmarkModel

/// docs/SETTINGS_EXPORT_PLAN.md §8, the stream stages: export pass, add-only plan, apply and undo.
final class StreamTransferTests: XCTestCase {
    private final class MemoryStore: StreamSecretStore {
        var items: [String: String] = [:]
        var refused: Set<String> = []
        var reads: [String] = []
        func read(_ account: String) -> StreamSecretRead {
            reads.append(account)
            if refused.contains(account) { return .failed(-128) }
            return items[account].map(StreamSecretRead.found) ?? .absent
        }
        func write(_ value: String, for account: String) -> Int32 { items[account] = value; return 0 }
        func delete(_ account: String) { items[account] = nil }
    }

    private let store = MemoryStore()
    private let rules = StreamImportRules(
        urlProblem: { raw in
            let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let scheme = url?.scheme?.lowercased(), url?.host != nil, ["http", "https", "srt"].contains(scheme) else {
                return "Not a stream URL."
            }
            return nil
        },
        passphraseLength: 10...79, audioOffsetMs: -250...500)

    private let urlA = "srt://a.example:9000?streamid=one"
    private let urlB = "srt://b.example:9000?streamid=two"
    private let pass1 = "first-passphrase"
    private let pass2 = "second-passphrase"

    /// A saved stream: the entry, and its item in `store`.
    private func saved(_ name: String, _ url: String, _ passphrase: String? = nil) -> StreamBookmark {
        let id = UUID()
        let secret = StreamSecret(url: url, passphrase: passphrase)
        store.items[id.uuidString] = secret.encoded()
        return StreamBookmark(id: id, name: name, urlString: "", type: .srt, address: "srt://host", secretRef: id.uuidString)
    }

    private func entry(_ name: Any?, _ url: Any?, _ passphrase: Any? = nil, offset: Any? = nil, color: Any? = nil) -> [String: Any] {
        var e: [String: Any] = ["type": "srt"]
        e["name"] = name
        e["url"] = url
        e["passphrase"] = passphrase
        e["audioOffsetMs"] = offset
        e["colorOverride"] = color
        return e
    }

    private func plan(_ entries: [Any], _ existing: [StreamBookmark]) -> StreamImportPlan {
        StreamImportPlan.make(entries: entries, existing: existing, rules: rules) {
            StreamSecrets.resolve($0, read: store.read(StreamExportPass.account(of: $0)))
        }
    }

    private func outcome(_ row: StreamImportPlan.Row?) -> String {
        switch row?.outcome {
        case .added(let a)?: return "added \(a.name)"
        case .renamed(let a, let r)?: return "renamed \(a.name) \(r)"
        case .alreadyHere?: return "here"
        case .notImported?: return "no"
        case nil: return "nothing"
        }
    }

    // MARK: §4.2, row by row

    func testNoStreamOfThisNameIsAdded() {
        XCTAssertEqual(outcome(plan([entry("A", urlA)], [saved("B", urlB)]).rows.first), "added A")
    }

    func testAFreshMacRaisesNoKeychainRead() {
        _ = plan([entry("A", urlA), entry("B", urlB)], [])
        XCTAssertTrue(store.reads.isEmpty)
    }

    func testOnlyStreamsOfTheSameFamilyAreRead() {
        let other = saved("Other", urlB)
        let same = saved("A", urlB)
        _ = plan([entry("A", urlA)], [other, same])
        XCTAssertEqual(store.reads, [same.id.uuidString])
    }

    func testEachStreamIsReadOnceHoweverManyEntriesAsk() {
        let same = saved("A", urlB)
        _ = plan([entry("A", urlA), entry("A", "srt://c.example:1")], [same])
        XCTAssertEqual(store.reads, [same.id.uuidString])
    }

    func testSameNameDifferentURLIsRenamed() {
        XCTAssertEqual(outcome(plan([entry("A", urlA)], [saved("A", urlB)]).rows.first), "renamed A (copy) differentURL")
    }

    func testSameNameURLAndPassphraseIsSkipped() {
        let p = plan([entry("A", urlA, pass1)], [saved("A", urlA, pass1)])
        XCTAssertEqual(outcome(p.rows.first), "here")
        XCTAssertTrue(p.additions.isEmpty)
    }

    func testADifferentPassphraseIsAddedAndKept() {
        let p = plan([entry("A", urlA, pass2)], [saved("A", urlA, pass1)])
        XCTAssertEqual(outcome(p.rows.first), "renamed A (copy) passphraseDiffers")
        XCTAssertEqual(p.additions.first?.passphrase, pass2)
        XCTAssertEqual(StreamImportPlan.RenameReason.passphraseDiffers.message, "Passphrase differs.")
    }

    func testAPassphraseOnOneSideOnlyDiffers() {
        XCTAssertEqual(outcome(plan([entry("A", urlA)], [saved("A", urlA, pass1)]).rows.first), "renamed A (copy) passphraseDiffers")
        XCTAssertEqual(outcome(plan([entry("A", urlA, pass1)], [saved("A", urlA)]).rows.first), "renamed A (copy) passphraseDiffers")
    }

    func testAnInvalidEntryCostsThatEntry() {
        let p = plan([entry("A", "ftp://a.example"), entry("B", urlB)], [])
        XCTAssertEqual(outcome(p.rows[0]), "no")
        XCTAssertEqual(outcome(p.rows[1]), "added B")
    }

    // MARK: Naming, R1 and R2

    func testCopyNamesPastTheSecond() {
        let list = [saved("A", urlB), saved("A (copy)", "srt://c.example:1"), saved("A (copy 2)", "srt://d.example:1")]
        XCTAssertEqual(plan([entry("A", urlA)], list).additions.first?.name, "A (copy 3)")
    }

    func testTheFirstFreeNameIsTaken() {
        let list = [saved("A", urlB), saved("A (copy 2)", "srt://c.example:1")]
        XCTAssertEqual(plan([entry("A", urlA)], list).additions.first?.name, "A (copy)")
    }

    func testAFreeNameIsUsedEvenWhenACopyExists() {
        XCTAssertEqual(outcome(plan([entry("A", urlA)], [saved("A (copy)", urlB)]).rows.first), "added A")
    }

    func testTheFamilyIsItsCopiesAndNothingElse() {
        XCTAssertTrue(StreamImportPlan.isFamily("A", of: "A"))
        XCTAssertTrue(StreamImportPlan.isFamily("A (copy)", of: "A"))
        XCTAssertTrue(StreamImportPlan.isFamily("A (copy 12)", of: "A"))
        XCTAssertFalse(StreamImportPlan.isFamily("A (copy x)", of: "A"))
        XCTAssertFalse(StreamImportPlan.isFamily("A (copy )", of: "A"))
        XCTAssertFalse(StreamImportPlan.isFamily("A copy", of: "A"))
        XCTAssertFalse(StreamImportPlan.isFamily("AB", of: "A"))
    }

    /// Applies a plan to `list` and `store` the way the app's `add` does.
    private func applied(_ p: StreamImportPlan, to list: inout [StreamBookmark]) {
        for a in p.additions { list.append(saved(a.name, a.url, a.passphrase)) }
    }

    func testARepeatImportAddsNothing() {
        let file = [entry("A", urlA), entry("B", urlB)]
        var list = [saved("A", urlB)]
        applied(plan(file, list), to: &list)
        XCTAssertEqual(list.map(\.name), ["A", "A (copy)", "B"])
        let again = plan(file, list)
        XCTAssertEqual(again.rows.map(outcome), ["here", "here"])
    }

    func testARepeatOfADifferentPassphraseAddsNothing() {
        let file = [entry("A", urlA, pass2)]
        var list = [saved("A", urlA, pass1)]
        applied(plan(file, list), to: &list)
        XCTAssertEqual(plan(file, list).rows.map(outcome), ["here"])
    }

    func testAMatchOnACopyIsAlreadyHere() {
        XCTAssertEqual(outcome(plan([entry("A", urlA, pass1)], [saved("A", urlA, pass2), saved("A (copy)", urlA, pass1)]).rows.first), "here")
    }

    // MARK: R3

    func testARefusedReadCountsAsDifferentAndSaysSo() {
        let a = saved("A", urlA, pass1)
        store.refused = [a.id.uuidString]
        let p = plan([entry("A", urlA, pass1)], [a])
        XCTAssertEqual(outcome(p.rows.first), "renamed A (copy) couldNotCompare")
        XCTAssertEqual(StreamImportPlan.RenameReason.couldNotCompare.message, "Couldn’t compare with the existing stream.")
    }

    func testAMissingItemCountsAsDifferent() {
        let a = saved("A", urlA)
        store.items[a.id.uuidString] = nil
        XCTAssertEqual(outcome(plan([entry("A", urlA)], [a]).rows.first), "renamed A (copy) couldNotCompare")
    }

    func testAMatchElsewhereInTheFamilyBeatsARefusedRead() {
        let a = saved("A", urlB)
        store.refused = [a.id.uuidString]
        XCTAssertEqual(outcome(plan([entry("A", urlA)], [a, saved("A (copy)", urlA)]).rows.first), "here")
    }

    // MARK: Inside one file

    func testTwoEntriesInOneFileFollowTheSameRules() {
        let p = plan([entry("A", urlA), entry("A", urlA), entry("A", urlB), entry("A", urlA, pass1)], [])
        XCTAssertEqual(p.rows.map(outcome), ["added A", "here", "renamed A (copy) differentURL",
                                             "renamed A (copy 2) passphraseDiffers"])
    }

    // MARK: Validation

    func testEntryValidation() {
        let long = String(repeating: "x", count: 201)
        let bad: [Any] = [
            "not an object",
            entry(7, urlA),
            entry("A", nil),
            entry("A", 7),
            entry("A", "not a url"),
            entry(long, urlA),
            entry("line\nbreak", urlA),
            entry("A", urlA, "short"),
            entry("A", urlA, String(repeating: "p", count: 80)),
            entry("A", urlA, 7),
            entry("A", "https://a.example/x", pass1),
            entry("A", urlA, offset: 501),
            entry("A", urlA, offset: -251),
            entry("A", urlA, offset: 1.5),
            entry("A", urlA, offset: true),
            entry("A", urlA, color: 7),
            entry("A", urlA, color: String(repeating: "c", count: 65)),
        ]
        for (i, raw) in bad.enumerated() {
            XCTAssertEqual(outcome(plan([raw], []).rows.first), "no", "entry \(i)")
        }
    }

    func testARefusedEntryWithNoUsableNameIsNumbered() {
        XCTAssertEqual(plan([entry("A", urlA), "x"], []).rows[1].name, "Stream 2")
        XCTAssertEqual(plan([entry("a\u{7}b", urlA)], []).rows[0].name, "Stream 1")
    }

    func testABlankNameFallsBackToTheHost() {
        XCTAssertEqual(plan([entry("   ", urlA)], []).additions.first?.name, "a.example")
        XCTAssertEqual(plan([entry(nil, urlA)], []).additions.first?.name, "a.example")
    }

    func testAnEntryIsCarriedAsAddWouldStoreIt() throws {
        let a = try XCTUnwrap(plan([entry("  A  ", "  \(urlA)  ", pass1, offset: 80, color: "future-preset")], []).additions.first)
        XCTAssertEqual(a.name, "A")
        XCTAssertEqual(a.url, urlA)
        XCTAssertEqual(a.passphrase, pass1)
        XCTAssertEqual(a.audioOffsetMs, 80)
        XCTAssertEqual(a.colorOverride, "future-preset")
    }

    func testAZeroOffsetIsStoredAsNone() {
        XCTAssertNil(plan([entry("A", urlA, offset: 0)], []).additions.first?.audioOffsetMs)
    }

    func testAPassphraseInTheURLComparesAsAStoredOne() {
        let inline = "\(urlA)&passphrase=\(pass1)"
        XCTAssertEqual(outcome(plan([entry("A", inline)], [saved("A", urlA, pass1)]).rows.first), "here")
        XCTAssertEqual(plan([entry("A", inline)], []).additions.first?.passphrase, pass1)
        XCTAssertEqual(plan([entry("A", inline)], []).additions.first?.url, urlA)
    }

    func testTheFieldWinsOverAPassphraseInTheURL() {
        XCTAssertEqual(plan([entry("A", "\(urlA)&passphrase=\(pass1)", pass2)], []).additions.first?.passphrase, pass2)
    }

    func testUnknownFieldsInAnEntryAreIgnored() {
        var e = entry("A", urlA)
        e["id"] = "x"
        e["secretRef"] = "x"
        XCTAssertEqual(outcome(plan([e], []).rows.first), "added A")
    }

    func testAnUnknownTypeIsJudgedFromItsURL() {
        var e = entry("A", urlA)
        e["type"] = "from the future"
        XCTAssertEqual(outcome(plan([e], []).rows.first), "added A")
    }

    func testPlanningChangesNothing() {
        let list = [saved("A", urlB, pass1), saved("B", urlA)]
        let before = store.items
        _ = plan([entry("A", urlA), entry("B", urlA)], list)
        XCTAssertEqual(store.items, before)
    }

    // MARK: Fixed fields

    func testAnEntryHasExactlyTheseFields() throws {
        let full = StreamExportEntry(name: "A", type: "srt", url: urlA, passphrase: pass1, audioOffsetMs: 80, colorOverride: "rec709")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(object).keys), ["audioOffsetMs", "colorOverride", "name", "passphrase", "type", "url"])
    }

    func testAnEntryLeavesOutWhatItDoesNotHave() throws {
        let bare = StreamExportEntry(name: "A", type: "web", url: "https://a.example", passphrase: nil, audioOffsetMs: nil, colorOverride: nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(object).keys), ["name", "type", "url"])
    }

    // MARK: Export pass

    func testKeychainReadsAtExport() throws {
        let found = saved("Found", urlA, pass1)
        let refused = saved("Refused", urlB)
        store.refused = [refused.id.uuidString]
        let absent = saved("Absent", urlB)
        store.items[absent.id.uuidString] = nil
        let unusable = saved("Unusable", urlB)
        store.items[unusable.id.uuidString] = "not a secret"
        let after = saved("After", urlB)
        let out = try XCTUnwrap(StreamExportPass.collect([found, refused, absent, unusable, after], from: store))
        XCTAssertEqual(out.entries.map(\.name), ["Found", "After"])
        XCTAssertEqual(out.entries.first?.url, urlA)
        XCTAssertEqual(out.entries.first?.passphrase, pass1)
        XCTAssertEqual(out.leftOut.map(\.name), ["Refused", "Absent", "Unusable"])
        XCTAssertEqual(out.leftOut.first?.reason, "Couldn’t read this stream’s URL.")
        XCTAssertEqual(out.leftOut.last?.reason, "This stream has no saved URL.")
    }

    func testAPreP2EntryExportsItsURLThroughResolve() throws {
        let old = StreamBookmark(name: "Old", urlString: "\(urlA)&passphrase=\(pass1)", type: .srt)
        let out = try XCTUnwrap(StreamExportPass.collect([old], from: store))
        XCTAssertEqual(out.entries.first?.url, urlA)
        XCTAssertEqual(out.entries.first?.passphrase, pass1)
    }

    func testTheEntryCarriesTheBookmarksOtherFields() throws {
        var b = saved("A", urlA)
        b.audioOffsetMs = 80
        b.colorOverride = "rec709"
        let e = try XCTUnwrap(StreamExportPass.collect([b], from: store)?.entries.first)
        XCTAssertEqual(e.type, "srt")
        XCTAssertEqual(e.audioOffsetMs, 80)
        XCTAssertEqual(e.colorOverride, "rec709")
    }

    func testProgressAndCancelling() {
        let list = [saved("A", urlA), saved("B", urlB)]
        var seen: [Int] = []
        _ = StreamExportPass.collect(list, from: store, progress: { seen.append($0) })
        XCTAssertEqual(seen, [1, 2])
        var calls = 0
        XCTAssertNil(StreamExportPass.collect(list, from: store, cancelled: { calls += 1; return calls > 1 }))
    }

    // MARK: Apply and undo

    func testApplyAddsAndAFailureCostsThatEntry() {
        let p = plan([entry("A", urlA, offset: 80), entry("B", urlB), entry("C", "srt://c.example:1")], [])
        var ids: [String: UUID] = [:]
        let out = StreamImport.apply(p) { a in
            if a.name == "B" { return .failure(.init(reason: "No Keychain.")) }
            let id = UUID()
            ids[a.name] = id
            return .success(id)
        }
        XCTAssertEqual(Set(out.added), Set(ids.values))
        XCTAssertEqual(out.failed, [.init(name: "B", reason: "No Keychain.")])
        XCTAssertEqual(out.withOffset, 1)
    }

    func testUndoRemovesExactlyWhatWasAdded() {
        var list = [saved("A", urlB, pass1)]
        let original = list
        let items = store.items
        let p = plan([entry("A", urlA), entry("B", urlB)], list)
        let out = StreamImport.apply(p) { a in
            let b = saved(a.name, a.url, a.passphrase)
            list.append(b)
            return .success(b.id)
        }
        XCTAssertEqual(list.count, 3)
        StreamImport.undo(out) { id in
            list.removeAll { $0.id == id }
            store.delete(id.uuidString)
        }
        XCTAssertEqual(list, original)
        XCTAssertEqual(store.items, items)
    }
}
