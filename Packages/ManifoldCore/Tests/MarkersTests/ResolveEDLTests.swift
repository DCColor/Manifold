import XCTest
@testable import Markers
import SMPTETimecode

/// docs/MARKERS_PLAN.md §8.1. The two Resolve-written EDLs (R1) and Frame.io's (§0.1) are fixtures.
final class ResolveEDLTests: XCTestCase {

    static let r2398 = 24000.0 / 1001
    static let r2997 = 30000.0 / 1001

    /// A file starting at 01:00:00:00, 23.976.
    let basis2398 = TimecodeBasis(startFrame: 86_400, nfr: 24, rate: r2398, dropFrame: false, hasTimecode: true)
    /// A file starting at 01:00:00;00, 29.97 DF.
    let basis2997DF = TimecodeBasis(startFrame: 107_892, nfr: 30, rate: r2997, dropFrame: true, hasTimecode: true)

    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "edl", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: Resolve's own EDLs: read, and written back byte for byte

    func testReadsResolve2398() throws {
        let parsed = try ResolveEDL.parse(fixture("resolve-reference-2398"))
        XCTAssertEqual(parsed.title, "resolve-reference-2398")
        XCTAssertEqual(parsed.dropFrame, false)
        XCTAssertEqual(parsed.entries.count, 5)
        let e = parsed.entries
        XCTAssertEqual(e[0].recordIn, "01:00:01:16")
        XCTAssertEqual(e[0].name, "Face")
        XCTAssertEqual(e[0].notes, "There is to much higlight on her frace")
        XCTAssertEqual(e[1].color, .red)
        XCTAssertEqual(e[1].duration, 24)
        XCTAssertEqual(e[3].notes, "")
        XCTAssertEqual(e[3].color, .lemon)
        XCTAssertEqual(e[4].name, "Marker 5")

        let placed = ResolveEDL.place(parsed, basis: basis2398, lastFrame: 10_000)
        XCTAssertEqual(placed.markers.map(\.frame), [40, 62, 109, 141, 188])
        XCTAssertTrue(placed.outside.isEmpty)
        XCTAssertNil(placed.suggestedShiftHours)
        XCTAssertFalse(placed.dropFrameMismatch)
    }

    func testWritesResolve2398ByteForByte() throws {
        let data = try fixture("resolve-reference-2398")
        let parsed = try ResolveEDL.parse(data)
        let placed = ResolveEDL.place(parsed, basis: basis2398, lastFrame: 10_000)
        let out = ResolveEDL.export(markers: placed.markers, title: "resolve-reference-2398", basis: basis2398)
        XCTAssertEqual(Data(out.text.utf8), data)
    }

    func testReadsAndWritesResolve2997DFByteForByte() throws {
        let data = try fixture("resolve-reference-2997DF")
        let parsed = try ResolveEDL.parse(data)
        XCTAssertEqual(parsed.dropFrame, true)
        XCTAssertEqual(parsed.entries.map(\.duration), [1, 60, 1])
        let placed = ResolveEDL.place(parsed, basis: basis2997DF, lastFrame: 10_000)
        // 01:00:03:07 → 97 frames in; 01:00:04:20 → 140; 01:00:08:10 → 250.
        XCTAssertEqual(placed.markers.map(\.frame), [97, 140, 250])
        let out = ResolveEDL.export(markers: placed.markers, title: "resolve-reference-2997DF", basis: basis2997DF)
        XCTAssertEqual(Data(out.text.utf8), data)
    }

    // MARK: Frame.io's EDL

    func testReadsFrameIOEDL() throws {
        let parsed = try ResolveEDL.parse(fixture("frameio-reference"))
        XCTAssertEqual(parsed.dropFrame, false)   // "NON DROP FRAME", no hyphen
        XCTAssertEqual(parsed.entries.count, 11)
        XCTAssertTrue(parsed.entries.allSatisfy { $0.color == .purple && $0.duration == 1 && $0.name == "Robbie Carman" })
        // The "@" author line is not part of the note (D10).
        XCTAssertEqual(parsed.entries[0].notes,
                       "Need to update title - should be: Reverse Engineering In The Age Of A.I.")
        XCTAssertFalse(parsed.entries.contains { $0.notes.contains("@") })
    }

    func testFrameIOEDLOnAFileWithoutTimecodeOffersTheHourShift() throws {
        let parsed = try ResolveEDL.parse(fixture("frameio-reference"))
        let noTC = TimecodeBasis(startFrame: 0, nfr: 24, rate: Self.r2398, dropFrame: false, hasTimecode: false)
        let asIs = ResolveEDL.place(parsed, basis: noTC, lastFrame: 87_903)
        XCTAssertFalse(asIs.outside.isEmpty)
        XCTAssertEqual(asIs.suggestedShiftHours, -1)
        let shifted = ResolveEDL.place(parsed, basis: noTC, lastFrame: 87_903, shiftHours: -1)
        // The EDL's own labels. Five are one frame EARLIER than the same comments' `frame` in Frame.io's .fiojson, Avid
        // and Premiere exports (17030, 43018, 44338, 58750, 84449): Frame.io's EDL is inconsistent with itself
        // (docs/MARKERS_PLAN.md §0.1). Manifold reads what the EDL says.
        XCTAssertEqual(shifted.markers.map(\.frame),
                       [286, 970, 11466, 17029, 19926, 26634, 43017, 44337, 58749, 67452, 84448])
        XCTAssertTrue(shifted.outside.isEmpty)
        XCTAssertNil(shifted.suggestedShiftHours)
    }

    // MARK: Writing rules

    func testNotesKeywordsBarsAndDuration() {
        let m = Marker(frame: 0, duration: 0, name: "a|b", notes: "line one\n\nline two | three\n", keywords: ["sky", "grade"],
                       color: .cocoa)
        XCTAssertEqual(m.duration, 1)
        // D13 (revised): each note line on its own line, the last carrying |C:. The blank line between is left out.
        let dropped = ResolveEDL.export(markers: [m], title: "t", basis: basis2398)
        XCTAssertTrue(dropped.text.contains("  \r\nline one\r\nline two / three |C:ResolveColorCocoa |M:a/b |D:1\r\n\r\n"))
        XCTAssertEqual(dropped.report.multiLineNotes, 1)
        XCTAssertEqual(dropped.report.droppedBlankLines, 1)
        XCTAssertEqual(dropped.report.replacedBars, 1)
        XCTAssertEqual(dropped.report.droppedKeywords, 1)
        let kept = ResolveEDL.export(markers: [m], title: "t", basis: basis2398,
                                     options: .init(appendKeywordsToNotes: true))
        XCTAssertTrue(kept.text.contains("line one\r\nline two / three [sky, grade] |C:"))
        XCTAssertEqual(kept.report.appendedKeywords, 1)
        let onlyKeywords = ResolveEDL.export(markers: [Marker(frame: 0, keywords: ["k"])], title: "t", basis: basis2398,
                                             options: .init(appendKeywordsToNotes: true)).text
        XCTAssertTrue(onlyKeywords.contains("\r\n[k] |C:ResolveColorBlue"))
    }

    func testMultiLineNotesRoundTrip() throws {
        let notes = ["first line\nsecond line\nthird", "@mention at the start\nthen more", "TITLE: not a header\nFCM: nor this",
                     "He said \"pull\" it out", "Café, naïve — 😀 ok"]
        let markers = notes.enumerated().map { Marker(frame: 10 * $0.offset, name: "n\($0.offset)", notes: $0.element) }
        let text = ResolveEDL.export(markers: markers, title: "rt", basis: basis2398).text
        XCTAssertTrue(text.contains("\r\n @mention at the start\r\nthen more |C:"))
        let parsed = try ResolveEDL.parse(Data(text.utf8))
        XCTAssertEqual(parsed.title, "rt")
        XCTAssertEqual(parsed.dropFrame, false)
        let placed = ResolveEDL.place(parsed, basis: basis2398, lastFrame: 1_000)
        XCTAssertEqual(placed.markers.map(\.notes), notes)
        XCTAssertEqual(placed.markers.map(\.name), (0..<5).map { "n\($0)" })
    }

    func testEmptyNameAndNotes() {
        let out = ResolveEDL.export(markers: [Marker(frame: 5)], title: "t", basis: basis2398).text
        XCTAssertTrue(out.contains("\r\n |C:ResolveColorBlue |M: |D:1\r\n"))
        let back = try! ResolveEDL.parse(Data(out.utf8))
        XCTAssertEqual(back.entries[0].name, "")
        XCTAssertEqual(back.entries[0].notes, "")
    }

    func testDropFrameMinuteBoundaryIsWrittenWithColons() {
        // 01:01:00;02 is the first label of minute 1 after 01:00:00;00.
        let f = basis2997DF.frame(label: "01:01:00;02")!
        XCTAssertEqual(f, 1800)
        let out = ResolveEDL.export(markers: [Marker(frame: f)], title: "t", basis: basis2997DF).text
        XCTAssertTrue(out.contains("FCM: DROP FRAME\r\n"))
        XCTAssertTrue(out.contains("01:01:00:02 01:01:00:03 01:01:00:02 01:01:00:03  \r\n"))
        XCTAssertNil(basis2997DF.frame(label: "01:01:00;00"))
        XCTAssertEqual(basis2997DF.frame(label: "01:10:00;00"), 17_982)
    }

    func testRoundTripIsLosslessForSingleLineNotes() throws {
        let colors = MarkerColor.allCases
        let markers = (0..<16).map { i in
            Marker(frame: i * 100 + 3, duration: i + 1, name: "Name \(i) é", notes: i % 3 == 0 ? "" : "Note, \(i) “quoted”",
                   color: colors[i])
        }
        for basis in [basis2398, basis2997DF] {
            let text = ResolveEDL.export(markers: markers, title: "rt", basis: basis).text
            let placed = ResolveEDL.place(try ResolveEDL.parse(Data(text.utf8)), basis: basis, lastFrame: 100_000)
            XCTAssertEqual(placed.markers.count, 16)
            for (a, b) in zip(markers, placed.markers) {
                XCTAssertEqual([a.frame, a.duration], [b.frame, b.duration])
                XCTAssertEqual([a.name, a.notes, a.color.name], [b.name, b.notes, b.color.name])
            }
        }
    }

    func testFCMMismatchCountsLabelsInTheEDLsOwnFCM() throws {
        // A Resolve timeline set to NON-DROP at 01:00:00:00, holding a drop-frame file that starts at 01:00:00;00.
        let edl = "TITLE: x\r\nFCM: NON-DROP FRAME\r\n\r\n001  001      V     C        01:00:10:00 01:00:10:01 01:00:10:00 01:00:10:01  \r\n |C:ResolveColorBlue |M:m |D:1\r\n\r\n"
        let placed = ResolveEDL.place(try ResolveEDL.parse(Data(edl.utf8)), basis: basis2997DF, lastFrame: 10_000)
        XCTAssertEqual(placed.markers.map(\.frame), [300])
        XCTAssertTrue(placed.dropFrameMismatch)
    }

    func testAcrossMidnight() throws {
        let basis = TimecodeBasis(startFrame: SMPTETimecode.frameCount(label: "23:59:50:00", nfr: 25, fps: 25, dropFrame: false)!,
                                  nfr: 25, rate: 25, dropFrame: false, hasTimecode: true)
        XCTAssertEqual(basis.label(375), "00:00:05:00")
        let text = ResolveEDL.export(markers: [Marker(frame: 375)], title: "x", basis: basis).text
        let placed = ResolveEDL.place(try ResolveEDL.parse(Data(text.utf8)), basis: basis, lastFrame: 1_000)
        XCTAssertEqual(placed.markers.map(\.frame), [375])
    }

    func testUnknownColourAndMissingFields() throws {
        let edl = "001  001      V     C        00:00:01:00 00:00:01:01 00:00:01:00 00:00:01:01  \nnote |C:ResolveColorTeal\n\n"
        let parsed = try ResolveEDL.parse(Data(edl.utf8))
        XCTAssertNil(parsed.dropFrame)
        XCTAssertEqual(parsed.entries[0].color, .blue)
        XCTAssertTrue(parsed.entries[0].unknownColor)
        XCTAssertEqual(parsed.entries[0].notes, "note")
        XCTAssertEqual(parsed.entries[0].duration, 1)
    }

    func testCommentLinesAboveTheColourLineAreNoteLines() throws {
        let edl = "001  001      V     C        00:00:01:00 00:00:01:01 00:00:01:00 00:00:01:01  \n@Someone, date\nfirst line\nsecond |C:ResolveColorRed |M:n |D:3\n\n"
        let e = try ResolveEDL.parse(Data(edl.utf8)).entries[0]
        XCTAssertEqual(e.notes, "first line\nsecond")
    }

    func testNotAMarkerEDL() {
        let edl = "TITLE: cut\nFCM: NON-DROP FRAME\n\n001  AX       V     C        00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n* FROM CLIP NAME: a.mov\n\n"
        XCTAssertThrowsError(try ResolveEDL.parse(Data(edl.utf8))) { XCTAssertEqual($0 as? ResolveEDL.ParseError, .noMarkers) }
    }

    func testMergeSkipsDuplicates() {
        let a = Marker(frame: 10, name: "x", notes: "n")
        let b = Marker(frame: 10, name: "x", notes: "n")
        let c = Marker(frame: 11, name: "x", notes: "n")
        let r = ResolveEDL.merge([b, c, c], into: [a])
        XCTAssertEqual(r.added.map(\.frame), [11])
        XCTAssertEqual(r.identical, 2)   // b is a's twin; the second c is the first c's
        XCTAssertEqual(r.occupied, 0)
    }
}
