//
//  FileNameTextTests.swift
//  FileScanTests — a file name that wraps without a hyphen (docs/BUGS.md, 0.9.6 UI polish, batch 4 item 1).
//

import XCTest
@testable import FileScan

final class FileNameTextTests: XCTestCase {

    /// The Inspector's case: every pair of characters gets a break opportunity, so no run is long enough to hyphenate.
    func testEveryCharacterIsABreakOpportunity() {
        let shown = FileNameText.wrappable("Stereo_Textless.mov")
        XCTAssertEqual(shown.count, 2 * "Stereo_Textless.mov".count - 1)
        XCTAssertFalse(shown.split(separator: FileNameText.breakOpportunity).contains { $0.count > 1 })
        XCTAssertFalse(shown.contains("-"))
    }

    /// Display only: the plain name comes back exactly, so nothing else needs to change.
    func testPlainRoundTrips() {
        for name in ["Stereo_Textless.mov", "A001_C002_0101AB.mxf", "café – final ✅.mov", "x", ""] {
            XCTAssertEqual(FileNameText.plain(FileNameText.wrappable(name)), name)
        }
    }

    /// Grapheme clusters are kept whole: an accented letter or an emoji is never split by a join.
    func testGraphemeClustersStayWhole() {
        let name = "e\u{301}👍🏽"   // e + combining acute, thumbs up + skin tone
        let parts = FileNameText.wrappable(name).split(separator: FileNameText.breakOpportunity)
        XCTAssertEqual(parts.map(String.init), ["e\u{301}", "👍🏽"])
    }

    func testShortNamesUnchanged() {
        XCTAssertEqual(FileNameText.wrappable(""), "")
        XCTAssertEqual(FileNameText.wrappable("a"), "a")
    }
}
