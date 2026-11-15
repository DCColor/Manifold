import XCTest
@testable import Markers

/// CSV, text, the fingerprint, the store, the colours and the log lines (docs/MARKERS_PLAN.md §8.1).
final class MarkerFilesTests: XCTestCase {

    let basis = TimecodeBasis(startFrame: 86_400, nfr: 24, rate: 24000.0 / 1001, dropFrame: false, hasTimecode: true)

    func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("markers-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    // MARK: Colours

    func testSixteenColoursInResolvesOrder() {
        XCTAssertEqual(MarkerColor.allCases.map(\.name),
                       ["Blue", "Cyan", "Green", "Yellow", "Red", "Pink", "Purple", "Fuchsia", "Rose", "Lavender", "Sky",
                        "Mint", "Lemon", "Sand", "Cocoa", "Cream"])
        XCTAssertEqual(MarkerColor.blue.hex, 0x078AE7)
        XCTAssertEqual(MarkerColor.cream.hex, 0xF6EEE5)
        XCTAssertEqual(MarkerColor(resolveToken: "ResolveColorLavender"), .lavender)
        XCTAssertEqual(MarkerColor(resolveToken: "resolvecolorsky"), .sky)
        XCTAssertEqual(MarkerColor(resolveToken: "Mint"), .mint)
        XCTAssertNil(MarkerColor(resolveToken: "ResolveColorTeal"))
    }

    // MARK: CSV and text

    func testCSV() throws {
        let m = Marker(frame: 40, duration: 24, name: "Face, left", notes: "He said \"no\"\nsecond line", keywords: ["a", "b"],
                       color: .red)
        let data = MarkerCSV.export(markers: [m], basis: basis)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = try XCTUnwrap(String(data: data.dropFirst(3), encoding: .utf8))
        XCTAssertEqual(text,
                       "Timecode In,Timecode Out,Duration,Duration Frames,Frame,Color,Name,Notes,Keywords\r\n"
                       + "01:00:01:16,01:00:02:15,00:00:01:00,24,40,Red,\"Face, left\",\"He said \"\"no\"\"\nsecond line\",a; b\r\n")
    }

    func testPlainText() {
        let ms = [Marker(frame: 286, name: "Title fix", notes: "Need to update\nthe title", keywords: ["titles"], color: .purple),
                  Marker(frame: 10, color: .blue)]
        let text = MarkerPlainText.export(markers: ms, fileName: "clip.mov", basis: basis,
                                          date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(text.hasPrefix("Markers: clip.mov\nStart timecode: 01:00:00:00\nRate: 23.976 NDF\nMarkers: 2\n"))
        XCTAssertTrue(text.contains("01:00:11:22  Purple    1 fr     Title fix\n    Need to update\n    the title\n    Keywords: titles\n"))
        XCTAssertLessThan(text.range(of: "01:00:00:10")!.lowerBound, text.range(of: "01:00:11:22")!.lowerBound)
    }

    func testRateLabels() {
        XCTAssertEqual(basis.rateLabel, "23.976")
        XCTAssertEqual(TimecodeBasis(startFrame: 0, nfr: 30, rate: 30000.0 / 1001, dropFrame: true, hasTimecode: true).rateLabel, "29.97")
        XCTAssertEqual(TimecodeBasis(startFrame: 0, nfr: 25, rate: 25, dropFrame: false, hasTimecode: false).rateLabel, "25")
    }

    func testOverrideAppliesOnlyWithoutTimecode() {
        let none = TimecodeBasis.forFile(rate: 25, timecodeStartFrame: nil, timecodeNFR: nil, dropFrame: false,
                                         overrideLabel: "01:00:00:00")
        XCTAssertEqual(none.label(0), "01:00:00:00")
        XCTAssertFalse(none.hasTimecode)
        let own = TimecodeBasis.forFile(rate: 25, timecodeStartFrame: 250, timecodeNFR: 25, dropFrame: false,
                                        overrideLabel: "01:00:00:00")
        XCTAssertEqual(own.label(0), "00:00:10:00")
        let plain = TimecodeBasis.forFile(rate: 29.97, timecodeStartFrame: nil, timecodeNFR: nil, dropFrame: true,
                                          overrideLabel: nil)
        XCTAssertEqual(plain.label(0), "00:00:00:00")
        XCTAssertFalse(plain.dropFrame)
    }

    // MARK: Fingerprint

    func testFingerprintFollowsContentNotPath() throws {
        let dir = try tempDir()
        let edge = 1024
        var bytes = (0..<(edge * 5)).map { UInt8($0 % 251) }
        let a = dir.appendingPathComponent("a.mov"), b = dir.appendingPathComponent("renamed.mov")
        try Data(bytes).write(to: a)
        try Data(bytes).write(to: b)
        let ka = try XCTUnwrap(FileFingerprint.compute(url: a, edgeBytes: edge))
        XCTAssertEqual(ka, FileFingerprint.compute(url: b, edgeBytes: edge))
        XCTAssertEqual(ka.count, 64)

        // A byte in the middle (outside both edges) does not change the key: documented, not wanted.
        bytes[edge * 2] ^= 0xFF
        try Data(bytes).write(to: b)
        XCTAssertEqual(ka, FileFingerprint.compute(url: b, edgeBytes: edge))
        // A byte in the head does.
        bytes[10] ^= 0xFF
        try Data(bytes).write(to: b)
        XCTAssertNotEqual(ka, FileFingerprint.compute(url: b, edgeBytes: edge))
        // So does the size.
        try Data(bytes + [0]).write(to: b)
        XCTAssertNotEqual(ka, FileFingerprint.compute(url: b, edgeBytes: edge))
        // A small file is hashed whole.
        let s = dir.appendingPathComponent("s.bin")
        try Data([1, 2, 3]).write(to: s)
        XCTAssertNotNil(FileFingerprint.compute(url: s, edgeBytes: edge))
        XCTAssertNil(FileFingerprint.compute(url: dir.appendingPathComponent("missing")))
    }

    // MARK: Store

    func testStoreRoundTripAndRemoval() throws {
        let store = MarkerStore(directory: try tempDir().appendingPathComponent("Markers"))
        let fp = String(repeating: "ab", count: 32)
        XCTAssertNil(try store.load(fingerprint: fp))
        var doc = MarkerDocument(fingerprint: fp, markers: [Marker(frame: 3, name: "n", notes: "a\nb", keywords: ["k"],
                                                                   color: .sand, created: Date(timeIntervalSince1970: 1000))],
                                 startOverride: nil, lastPath: "/x/y.mov", startTimecodeSeen: "01:00:00:00")
        try store.save(doc)
        XCTAssertEqual(try store.load(fingerprint: fp), doc)
        doc.markers = []
        try store.save(doc)
        XCTAssertNil(try store.load(fingerprint: fp))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(fp + ".json").path))
    }

    func testStoreRefusesPathsAndThrowsOnUnreadable() throws {
        let store = MarkerStore(directory: try tempDir())
        XCTAssertThrowsError(try store.load(fingerprint: "../etc"))
        XCTAssertThrowsError(try store.load(fingerprint: String(repeating: "AB", count: 32)))
        let fp = String(repeating: "cd", count: 32)
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent(fp + ".json"))
        XCTAssertThrowsError(try store.load(fingerprint: fp))
    }

    // MARK: Log lines carry counts only (§5.1)

    func testLogLinesHoldNoUserText() {
        let sentinel = "SENTINEL-NOTE-7f3a"
        let m = Marker(frame: 1, name: sentinel, notes: sentinel, keywords: [sentinel])
        let r = ResolveEDL.export(markers: [m], title: sentinel, basis: basis).report
        let lines = [MarkerLog.exported(.edl, report: r), MarkerLog.loaded(count: 1, fingerprintMs: 3),
                     MarkerLog.imported(added: 1, duplicates: 0, outside: 0, unknownColors: 0, shiftHours: 0,
                                        dropFrameMismatch: false),
                     MarkerLog.changed(count: 1, action: .add), MarkerLog.exported(.csv, count: 1)]
        for l in lines {
            XCTAssertFalse(l.contains(sentinel))
            XCTAssertTrue(l.hasPrefix("[MARKERS] "))
        }
    }
}
