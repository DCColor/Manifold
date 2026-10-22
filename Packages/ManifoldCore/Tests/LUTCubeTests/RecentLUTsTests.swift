//
//  RecentLUTsTests.swift
//  LUTCubeTests
//
//  Colour S6, L3 (docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, *L3*): the Recent LUTs value and the LUT readout line.
//  The rule with teeth: a stored value this code cannot read decodes to nil, so the store never writes over it.
//

import XCTest
@testable import LUTCube

final class RecentLUTsTests: XCTestCase {

    private let a = RecentLUTEntry(path: "/luts/a.cube", bookmark: Data([1, 2, 3]), outputSpace: "rec2020PQ")
    private let b = RecentLUTEntry(path: "/luts/b.cube")

    // MARK: Round trip

    func testRoundTrip() {
        let stored = RecentLUTList.encode([a, b])
        XCTAssertEqual(RecentLUTList.decode(stored), [a, b])
        // Absent values are absent keys, never empty ones.
        XCTAssertEqual(Set(stored[1].keys), ["path"])
    }

    func testAbsentIsEmpty() {
        XCTAssertEqual(RecentLUTList.decode(nil), [])
    }

    // MARK: Never written over

    func testUnreadableValuesDecodeToNil() {
        let cases: [Any] = [
            "a string",
            ["path": "/x.cube"],                                   // a dictionary, not a list
            [["path": 7]],                                         // a path that is not a string
            [["path": ""]],                                        // an empty path
            [["bookmark": Data()]],                                // no path
            [["path": "/x.cube", "bookmark": "not data"]],
            [["path": "/x.cube", "outputSpace": 3]],
            [["path": "/x.cube", "futureKey": true]],              // a key this version does not know
            [["path": "/ok.cube"], "not a dictionary"],            // one bad entry spoils the list
        ]
        for c in cases { XCTAssertNil(RecentLUTList.decode(c), "\(c)") }
    }

    // MARK: Ordering and capacity

    func testInsertMovesToFrontWithoutDuplicates() {
        let list = RecentLUTList.inserting(b, into: [a, b])
        XCTAssertEqual(list.map(\.path), ["/luts/b.cube", "/luts/a.cube"])
        // The same file by another spelling is the same entry.
        let again = RecentLUTList.inserting(RecentLUTEntry(path: "/luts/./a.cube"), into: list)
        XCTAssertEqual(again.map(\.path), ["/luts/./a.cube", "/luts/b.cube"])
    }

    func testCapacity() {
        var list: [RecentLUTEntry] = []
        for i in 0..<(RecentLUTList.capacity + 3) {
            list = RecentLUTList.inserting(RecentLUTEntry(path: "/l/\(i).cube"), into: list)
        }
        XCTAssertEqual(list.count, RecentLUTList.capacity)
        XCTAssertEqual(list.first?.path, "/l/\(RecentLUTList.capacity + 2).cube")
    }

    func testSettingOutputSpace() {
        let list = RecentLUTList.settingOutputSpace(nil, forPath: "/luts/a.cube", in: [a, b])
        XCTAssertNil(list[0].outputSpace)
        XCTAssertEqual(list[0].bookmark, a.bookmark)
        XCTAssertEqual(list[1], b)
        XCTAssertEqual(RecentLUTList.settingOutputSpace("x", forPath: "/elsewhere.cube", in: [a, b]), [a, b])
        XCTAssertEqual(RecentLUTList.entry(forPath: "/luts/b.cube", in: [a, b]), b)
    }

    // MARK: The readout line

    private func lut(_ text: String) throws -> CubeLUT { try CubeLUT.parse(Data(text.utf8)) }

    private let cube2 = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"

    func testReadoutStates() throws {
        let l = try lut(cube2)
        XCTAssertEqual(LUTReadout.line(name: "x.cube", lut: l, interpolation: .tetrahedral,
                                       outputLabel: "Rec.2020 PQ (HDR10)", bypassed: false, sourcePresent: true),
                       "x.cube — 3D 2³ · tetrahedral · out Rec.2020 PQ (HDR10) (stated)")
        XCTAssertEqual(LUTReadout.line(name: "x.cube", lut: l, interpolation: .trilinear,
                                       outputLabel: nil, bypassed: false, sourcePresent: true),
                       "x.cube — 3D 2³ · trilinear · out same as source")
        XCTAssertEqual(LUTReadout.line(name: "x.cube", lut: l, interpolation: .tetrahedral,
                                       outputLabel: "Rec.2020 PQ (HDR10)", bypassed: true, sourcePresent: true),
                       "BYPASSED — x.cube — 3D 2³ · tetrahedral — not applied")
        // No source: the stated space is not named.
        XCTAssertEqual(LUTReadout.line(name: "x.cube", lut: l, interpolation: .tetrahedral,
                                       outputLabel: "Rec.2020 PQ (HDR10)", bypassed: false, sourcePresent: false),
                       "x.cube — 3D 2³ · tetrahedral · no source")
    }

    func testReadoutNamesIgnoredKeywordsAndOneDIsLinear() throws {
        let l = try lut("LUT_1D_SIZE 2\nFOO 1\nBAR\nBAZ\nQUX\nQUUX\n0 0 0\n1 1 1\n")
        XCTAssertEqual(LUTReadout.line(name: "c.cube", lut: l, interpolation: .tetrahedral,
                                       outputLabel: nil, bypassed: false, sourcePresent: true),
                       "c.cube — 1D 2 · linear · out same as source · ignored: FOO (line 2), BAR (line 3), "
                       + "BAZ (line 4), QUX (line 5), +1 more")
        // Bypassed: the word leads and the ignored keywords stay inside the line.
        XCTAssertEqual(LUTReadout.line(name: "c.cube", lut: l, interpolation: .tetrahedral,
                                       outputLabel: nil, bypassed: true, sourcePresent: true),
                       "BYPASSED — c.cube — 1D 2 · linear · ignored: FOO (line 2), BAR (line 3), "
                       + "BAZ (line 4), QUX (line 5), +1 more — not applied")
    }
}
