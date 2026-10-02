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

import XCTest
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
}
