//
//  StreamBookmarkMigrationTests.swift
//  StreamBookmarkModelTests
//
//  The per-source audio offset's migration rule (docs/AUDIO_RESAMPLER_DESIGN.md §19.4, §19.8):
//  `StreamBookmark.audioOffsetMs` is Optional, nil = 0, and never written unless set. A stored
//  `streamBookmarks` blob from before the field existed must decode, and re-encode with every
//  existing field unchanged and no `audioOffsetMs` key at all.
//
//  The blob is SYNTHETIC, in the exact shape the pre-feature app wrote (`JSONEncoder` over
//  `[StreamBookmark]` with four fields). A real one would carry stream URLs, and a stream path can
//  carry its key, so none is committed.
//
//  The colorimetry override's field (docs/COLOR_MANAGEMENT_FINDINGS.md §6.9, Stage D) follows the
//  same rule, and is tested below against both earlier shapes: the four-field type and the five-field
//  type with `audioOffsetMs` (HEAD before Stage D).
//

import XCTest
import ColorimetryModel
@testable import StreamBookmarkModel

final class StreamBookmarkMigrationTests: XCTestCase {

    /// The pre-feature type, field for field, as App/Preferences.swift declared it at b35a810.
    private struct LegacyBookmark: Codable, Equatable {
        let id: UUID
        var name: String
        var urlString: String
        var type: StreamType
    }

    /// What the pre-feature app stored: one entry per transport, a name with non-ASCII and quotes,
    /// a URL with a query (passphrases are stripped before storage, so none appears).
    private let preFeatureBlob = Data("""
    [{"id":"0E5A2B6C-3B1F-4F7A-9C55-1D2E3F405162","name":"Apple HLS (Bipbop)","urlString":"https:\\/\\/example.com\\/bipbop\\/master.m3u8","type":"hls"},\
    {"id":"9B8A7C6D-5E4F-4321-8765-0123456789AB","name":"Local SRT","urlString":"srt:\\/\\/127.0.0.1:9000","type":"srt"},\
    {"id":"11111111-2222-4333-8444-555555555555","name":"Studio “A” — WHEP","urlString":"https:\\/\\/example.com\\/live\\/whep?x=1&y=2","type":"web"}]
    """.utf8)

    func testPreFeatureBlobDecodesAndReEncodesUnchanged() throws {
        let legacy = try JSONDecoder().decode([LegacyBookmark].self, from: preFeatureBlob)
        let decoded = try JSONDecoder().decode([StreamBookmark].self, from: preFeatureBlob)
        XCTAssertEqual(decoded.count, 3)
        // Every existing field, entry by entry; the new one is nil (= 0).
        for (old, new) in zip(legacy, decoded) {
            XCTAssertEqual(new.id, old.id)
            XCTAssertEqual(new.name, old.name)
            XCTAssertEqual(new.urlString, old.urlString)
            XCTAssertEqual(new.type, old.type)
            XCTAssertNil(new.audioOffsetMs, "a pre-feature entry has no offset: nil = 0")
        }
        // Re-encoded by the new type, the JSON is the old type's, byte for byte (sorted keys, so the
        // comparison does not depend on dictionary order), and nil stays absent.
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let newBytes = try enc.encode(decoded), oldBytes = try enc.encode(legacy)
        XCTAssertEqual(newBytes, oldBytes)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("audioOffsetMs"))
        // And as plain dictionaries, against the blob as stored: the same keys and values.
        let stored = try JSONSerialization.jsonObject(with: preFeatureBlob) as! [[String: String]]
        let again = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded)) as! [[String: String]]
        XCTAssertEqual(again, stored)
    }

    /// A value the user set is written, read back, and only that entry gains the key.
    func testASetOffsetRoundTripsAndOnlyThatEntryCarriesIt() throws {
        var list = try JSONDecoder().decode([StreamBookmark].self, from: preFeatureBlob)
        list[1].audioOffsetMs = 80
        list[2].audioOffsetMs = -40
        let data = try JSONEncoder().encode(list)
        let back = try JSONDecoder().decode([StreamBookmark].self, from: data)
        XCTAssertEqual(back, list)
        XCTAssertEqual(back.map(\.audioOffsetMs), [nil, 80, -40])
        let raw = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertNil(raw[0]["audioOffsetMs"], "an untouched entry stays without the key")
        XCTAssertEqual(raw[1]["audioOffsetMs"] as? Int, 80)
        XCTAssertEqual(raw[2]["audioOffsetMs"] as? Int, -40)
        // Cleared back to nil: the key goes again.
        list[1].audioOffsetMs = nil
        let cleared = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(list)) as! [[String: Any]]
        XCTAssertNil(cleared[1]["audioOffsetMs"])
    }

    /// A blob written by THIS build reads in a pre-feature build too (the extra key is ignored by
    /// synthesized Codable), so going back a version does not lose the list.
    func testANewBlobStillDecodesAsThePreFeatureType() throws {
        var list = try JSONDecoder().decode([StreamBookmark].self, from: preFeatureBlob)
        list[0].audioOffsetMs = 120
        let legacy = try JSONDecoder().decode([LegacyBookmark].self, from: try JSONEncoder().encode(list))
        XCTAssertEqual(legacy.map(\.id), list.map(\.id))
        XCTAssertEqual(legacy.map(\.urlString), list.map(\.urlString))
    }
    // MARK: - The colorimetry override (§6.9, Stage D)

    /// The type as Stage C (`631ad92`) declared it: the four fields plus `audioOffsetMs`. What a
    /// build before Stage D decodes with.
    private struct PreColorBookmark: Codable, Equatable {
        let id: UUID
        var name: String
        var urlString: String
        var type: StreamType
        var audioOffsetMs: Int?
    }

    /// A blob a pre-Stage D build wrote: one entry with an audio offset, two without.
    private let preColorBlob = Data("""
    [{"id":"0E5A2B6C-3B1F-4F7A-9C55-1D2E3F405162","name":"Apple HLS (Bipbop)","urlString":"https:\\/\\/example.com\\/bipbop\\/master.m3u8","type":"hls"},\
    {"id":"9B8A7C6D-5E4F-4321-8765-0123456789AB","name":"Local SRT","urlString":"srt:\\/\\/127.0.0.1:9000","type":"srt","audioOffsetMs":80},\
    {"id":"11111111-2222-4333-8444-555555555555","name":"Studio “A” — WHEP","urlString":"https:\\/\\/example.com\\/live\\/whep?x=1&y=2","type":"web"}]
    """.utf8)

    /// Any JSON, re-serialized with sorted keys: the stored form with key order taken out.
    private func sortedJSON(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: data),
                                   options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func transport(_ t: StreamType) -> ColorimetryTransport {
        switch t { case .web: return .whep; case .srt: return .srt; case .hls: return .hls }
    }

    /// Both earlier shapes read as Auto, and re-encode without the key, byte for byte.
    func testOldBlobsReadAutoAndReEncodeUnchanged() throws {
        for (blob, label) in [(preFeatureBlob, "four-field"), (preColorBlob, "with audioOffsetMs")] {
            let list = try JSONDecoder().decode([StreamBookmark].self, from: blob)
            XCTAssertEqual(list.count, 3, label)
            for b in list {
                XCTAssertNil(b.colorOverride, label)
                XCTAssertEqual(ColorimetryOverride(storageID: b.colorOverride, on: transport(b.type)), .auto, label)
            }
            // Re-encoded, the same entries as stored: equal as parsed objects, and equal byte for byte
            // once keys are sorted. Raw bytes cannot be compared here: a plain `JSONEncoder`'s key order
            // changes from one process to the next. The store writes sorted keys (`storeEncoding`,
            // tested below), so its raw bytes do round-trip.
            XCTAssertEqual(try sortedJSON(try JSONEncoder().encode(list)), try sortedJSON(blob), label)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(list), as: UTF8.self).contains("colorOverride"))
        }
        // And against the pre-Stage D type, sorted keys: identical.
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let old = try JSONDecoder().decode([PreColorBookmark].self, from: preColorBlob)
        let new = try JSONDecoder().decode([StreamBookmark].self, from: preColorBlob)
        XCTAssertEqual(try enc.encode(new), try enc.encode(old))
    }

    /// A saved preset round-trips; only the entries that were set carry the key; Auto removes it.
    func testASavedOverrideRoundTripsAndAutoRemovesTheKey() throws {
        var list = try JSONDecoder().decode([StreamBookmark].self, from: preColorBlob)
        list[1].colorOverride = ColorimetryOverride.rec2020PQ.storageID      // SRT
        list[2].colorOverride = ColorimetryOverride.p3d65PQ.storageID        // WHEP
        let data = try JSONEncoder().encode(list)
        let back = try JSONDecoder().decode([StreamBookmark].self, from: data)
        XCTAssertEqual(back, list)
        XCTAssertEqual(back.map { ColorimetryOverride(storageID: $0.colorOverride, on: transport($0.type)) },
                       [.auto, .rec2020PQ, .p3d65PQ])
        XCTAssertEqual(back[1].audioOffsetMs, 80, "the other new field is untouched")
        let raw = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertNil(raw[0]["colorOverride"], "an untouched entry stays without the key")
        XCTAssertEqual(raw[1]["colorOverride"] as? String, "rec2020-pq")
        XCTAssertEqual(raw[2]["colorOverride"] as? String, "p3d65-pq")
        // HLS stores and loads it too (applied from Stage E).
        list[0].colorOverride = ColorimetryOverride.rec2020HLG.storageID
        let hls = try JSONDecoder().decode([StreamBookmark].self, from: try JSONEncoder().encode(list))
        XCTAssertEqual(ColorimetryOverride(storageID: hls[0].colorOverride, on: .hls), .rec2020HLG)
        // Saving Auto stores nil, and every entry is back to the blob's bytes.
        for i in list.indices { list[i].colorOverride = ColorimetryOverride.auto.storageID }
        XCTAssertEqual(try sortedJSON(try JSONEncoder().encode(list)), try sortedJSON(preColorBlob))
    }

    /// A blob written by this build reads in a pre-Stage D build: the extra key is ignored and every
    /// other field is equal. (That build, saving, would drop the key: the override goes, the list stays.)
    func testANewBlobDecodesInAnOlderBuild() throws {
        var list = try JSONDecoder().decode([StreamBookmark].self, from: preColorBlob)
        list[1].colorOverride = "rec2020-pq"
        list[2].colorOverride = "rec709"
        let data = try JSONEncoder().encode(list)
        let pre = try JSONDecoder().decode([PreColorBookmark].self, from: data)
        XCTAssertEqual(pre, try JSONDecoder().decode([PreColorBookmark].self, from: preColorBlob))
        let four = try JSONDecoder().decode([LegacyBookmark].self, from: data)
        XCTAssertEqual(four.map(\.id), list.map(\.id))
        XCTAssertEqual(four.map(\.urlString), list.map(\.urlString))
    }

    // MARK: - The store's encoding (sorted keys, docs/BUGS.md key-order entry)

    /// A load and a save of an unchanged list give back the stored bytes, raw, every time.
    func testALoadSaveCycleIsByteIdentical() throws {
        var list = try JSONDecoder().decode([StreamBookmark].self, from: preColorBlob)
        list[1].colorOverride = "rec2020-pq"
        let stored = try StreamBookmark.storeEncoding(list)
        var bytes = stored
        for _ in 0..<20 {
            bytes = try StreamBookmark.storeEncoding(try JSONDecoder().decode([StreamBookmark].self, from: bytes))
            XCTAssertEqual(bytes, stored)
        }
        XCTAssertEqual(try StreamBookmark.storeEncoding(list), stored, "the same list encodes the same bytes")
    }

    /// A list an earlier build wrote (keys in any order) is re-ordered once, and that is all: the result
    /// is the stored bytes with each object's keys sorted, byte for byte, escaping included.
    func testTheFirstSaveOnlyReordersKeys() throws {
        for (blob, label) in [(preFeatureBlob, "four-field"), (preColorBlob, "with audioOffsetMs")] {
            let list = try JSONDecoder().decode([StreamBookmark].self, from: blob)
            let sortedAsStored = try JSONSerialization.data(
                withJSONObject: try JSONSerialization.jsonObject(with: blob), options: [.sortedKeys])
            XCTAssertEqual(try StreamBookmark.storeEncoding(list), sortedAsStored, label)
        }
        // A blob whose keys are out of order, as the unsorted encoder could write it.
        let shuffled = Data("""
        [{"type":"srt","urlString":"srt:\\/\\/127.0.0.1:9000","audioOffsetMs":80,"name":"Local SRT","id":"9B8A7C6D-5E4F-4321-8765-0123456789AB","colorOverride":"rec709"}]
        """.utf8)
        let list = try JSONDecoder().decode([StreamBookmark].self, from: shuffled)
        XCTAssertEqual(String(decoding: try StreamBookmark.storeEncoding(list), as: UTF8.self), """
        [{"audioOffsetMs":80,"colorOverride":"rec709","id":"9B8A7C6D-5E4F-4321-8765-0123456789AB","name":"Local SRT","type":"srt","urlString":"srt:\\/\\/127.0.0.1:9000"}]
        """)
    }

    /// Unknown, empty, null and non-string values read as Auto and never fail the list. A known preset
    /// beside them keeps its value; an unknown STRING is kept verbatim (a later build's preset survives
    /// a round trip through this one); a non-string one cannot be kept and is dropped.
    func testUnreadableValuesReadAutoWithoutFailingTheList() throws {
        let blob = Data("""
        [{"id":"0E5A2B6C-3B1F-4F7A-9C55-1D2E3F405162","name":"a","urlString":"srt:\\/\\/h:1","type":"srt","colorOverride":"aces-cct"},\
        {"id":"9B8A7C6D-5E4F-4321-8765-0123456789AB","name":"b","urlString":"srt:\\/\\/h:2","type":"srt","colorOverride":""},\
        {"id":"11111111-2222-4333-8444-555555555555","name":"c","urlString":"https:\\/\\/h\\/whep","type":"web","colorOverride":42},\
        {"id":"21111111-2222-4333-8444-555555555555","name":"d","urlString":"https:\\/\\/h\\/whep","type":"web","colorOverride":null},\
        {"id":"31111111-2222-4333-8444-555555555555","name":"e","urlString":"https:\\/\\/h\\/x.m3u8","type":"hls","colorOverride":{"p":9}},\
        {"id":"41111111-2222-4333-8444-555555555555","name":"f","urlString":"srt:\\/\\/h:3","type":"srt","colorOverride":"rec2020-sdr"},\
        {"id":"51111111-2222-4333-8444-555555555555","name":"g","urlString":"https:\\/\\/h\\/whep","type":"web","colorOverride":"rec2020-hlg"}]
        """.utf8)
        let list = try JSONDecoder().decode([StreamBookmark].self, from: blob)
        XCTAssertEqual(list.map(\.name), ["a", "b", "c", "d", "e", "f", "g"], "the whole list decodes")
        XCTAssertEqual(list.map { ColorimetryOverride(storageID: $0.colorOverride, on: transport($0.type)) },
                       [.auto, .auto, .auto, .auto, .auto, .auto, .rec2020HLG])
        XCTAssertEqual(list.map(\.colorOverride), ["aces-cct", "", nil, nil, nil, "rec2020-sdr", "rec2020-hlg"])
        let raw = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(list)) as! [[String: Any]]
        XCTAssertEqual(raw[0]["colorOverride"] as? String, "aces-cct", "an unknown string is kept")
        XCTAssertEqual(raw[1]["colorOverride"] as? String, "")
        XCTAssertNil(raw[2]["colorOverride"]); XCTAssertNil(raw[3]["colorOverride"]); XCTAssertNil(raw[4]["colorOverride"])
        // The other fields of the entries with an unreadable value are intact.
        XCTAssertEqual(list[2].urlString, "https://h/whep"); XCTAssertEqual(list[4].type, .hls)
    }
}
