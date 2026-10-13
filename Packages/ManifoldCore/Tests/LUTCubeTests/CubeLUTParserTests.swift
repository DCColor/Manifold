//
//  CubeLUTParserTests.swift
//  LUTCubeTests
//
//  Colour S6, L0 (docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, *S6 — LUT*, L0-P1 to L0-P5 and L0-P7): the good
//  corpus, every refusal case, line endings, unknown keywords, the caps, the whole-or-nothing slot, parse time.
//
//  The corpus is under Fixtures/good and Fixtures/bad. The "shaped like" files are hand-written to each writer's
//  layout, not files those tools wrote; real vendor and Resolve files come in at L4.
//

import XCTest
@testable import LUTCube

final class CubeLUTParserTests: XCTestCase {

    // MARK: Fixtures

    private func url(_ dir: String, _ name: String) throws -> URL {
        let base = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
        return base.appendingPathComponent(dir).appendingPathComponent(name)
    }

    private func good(_ name: String) throws -> CubeLUT {
        try CubeLUT.load(contentsOf: url("good", name))
    }

    private func refusal(_ name: String) throws -> CubeLUTError? {
        do { _ = try CubeLUT.load(contentsOf: url("bad", name)); return nil } catch let e as CubeLUTError { return e }
    }

    private static let identity2: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1]

    // MARK: L0-P1 — the good corpus

    func testResolve3D() throws {
        let l = try good("resolve_3d_2.cube")
        XCTAssertEqual(l.kind, .threeD)
        XCTAssertNil(l.title)
        XCTAssertEqual(l.cube?.size, 2)
        XCTAssertEqual(l.cube?.domain, .unit)
        XCTAssertEqual(l.cube?.values, Self.identity2)
        XCTAssertEqual(l.ignored, [])
        XCTAssertEqual(l.shapeDescription, "3D 2³")
    }

    func testResolveShaperThen3D() throws {
        let l = try good("resolve_shaper_3d.cube")
        XCTAssertEqual(l.kind, .shaperAnd3D)
        XCTAssertEqual(l.shaper?.size, 4)
        XCTAssertEqual(l.shaper?.domain, CubeDomain(min: SIMD3(repeating: Float("-0.1")!), max: SIMD3(repeating: Float("1.2")!)))
        XCTAssertEqual(l.shaper?.values, [0, 0, 0, 0.25, 0.25, 0.25, 0.75, 0.75, 0.75, 1, 1, 1])
        XCTAssertEqual(l.cube?.size, 2)
        XCTAssertEqual(l.cube?.domain, .unit)
        XCTAssertEqual(l.cube?.values, Self.identity2, "the 1D rows come first, then the 3D rows")
        XCTAssertEqual(l.shapeDescription, "3D 2³ + 1D 4 shaper")
    }

    func testResolve1D() throws {
        let l = try good("resolve_1d.cube")
        XCTAssertEqual(l.kind, .oneD)
        XCTAssertNil(l.cube)
        XCTAssertEqual(l.shaper?.size, 5)
        XCTAssertEqual(l.shaper?.row(1), SIMD3(repeating: 0.0625))
        XCTAssertEqual(l.shaper?.row(4), SIMD3(repeating: 1))
    }

    func testAdobePerChannelDomain() throws {
        let l = try good("adobe_3d_domain.cube")
        XCTAssertEqual(l.title, "Adobe domain")
        XCTAssertEqual(l.cube?.domain, CubeDomain(min: SIMD3(0, -0.5, Float("0.1")!), max: SIMD3(1, 2, Float("0.9")!)))
    }

    func testAdobe1DWithDomain() throws {
        let l = try good("adobe_1d.cube")
        XCTAssertEqual(l.kind, .oneD)
        XCTAssertEqual(l.title, "Adobe 1D")
        XCTAssertEqual(l.shaper?.domain, CubeDomain(min: SIMD3(repeating: -0.25), max: SIMD3(repeating: 1.25)))
        XCTAssertEqual(l.shaper?.row(0), SIMD3(repeating: -0.25))
    }

    /// Tabs, exponents, trailing comments, blank lines, a `#` inside the quoted title, negative and > 1 outputs.
    func testVendorStyleFile() throws {
        let l = try good("vendor_style_3d.cube")
        XCTAssertEqual(l.title, "Vendor LogX to Rec709 # v1")
        let c = try XCTUnwrap(l.cube)
        XCTAssertEqual(c.size, 3)
        XCTAssertEqual(c.values.count, 27 * 3)
        XCTAssertEqual(c.node(r: 0, g: 0, b: 0), SIMD3(Float("-1.0e-02")!, 0, 0))   // first row, trailing comment
        XCTAssertEqual(c.node(r: 2, g: 1, b: 1), SIMD3(Float("1.05")!, 0.5, 0.5))   // a middle row
        XCTAssertEqual(c.node(r: 2, g: 2, b: 2), SIMD3(Float("1.05")!, 1, 1))       // last row
    }

    func testOCIOIridasStyle() throws {
        let l = try good("ocio_iridas_3d.cube")
        XCTAssertEqual(l.cube?.domain, .unit)
        XCTAssertEqual(l.cube?.values, Self.identity2)
    }

    func testLowercaseKeywordsAreRead() throws {
        let l = try good("lowercase_keywords.cube")
        XCTAssertEqual(l.title, "lower")
        XCTAssertEqual(l.cube?.values, Self.identity2)
    }

    func testNoTrailingNewline() throws {
        XCTAssertEqual(try good("no_trailing_newline.cube").cube?.values, Self.identity2)
    }

    func testHexAndSignedNumbers() throws {
        XCTAssertEqual(try good("hex_and_signs.cube").cube?.values, Self.identity2)
    }

    // MARK: L0-P4 — unknown keywords: ignored, named, table unchanged

    func testUnknownKeywordsAreIgnoredAndNamed() throws {
        let l = try good("unknown_keywords.cube")
        let twin = try good("unknown_keywords_twin.cube")
        XCTAssertEqual(l.ignored, [CubeIgnoredLine(line: 2, keyword: "LUT_IN_VIDEO_RANGE"),
                                   CubeIgnoredLine(line: 3, keyword: "FOO_BAR")])
        XCTAssertTrue(l.sameTable(as: twin))
        XCTAssertEqual(twin.ignored, [])
    }

    // MARK: L0-P2 — every refusal, by name and line

    func testEveryMalformedFileIsRefusedWithItsOwnError() throws {
        let cases: [(String, CubeLUTError)] = [
            ("empty.cube", .noTable),
            ("comments_only.cube", .noTable),
            ("data_before_size.cube", .dataBeforeSize(line: 1)),
            ("size_66_3d.cube", .sizeOutOfRange(keyword: "LUT_3D_SIZE", value: 66, line: 1)),
            ("size_1_3d.cube", .sizeOutOfRange(keyword: "LUT_3D_SIZE", value: 1, line: 1)),
            ("size_65537_1d.cube", .sizeOutOfRange(keyword: "LUT_1D_SIZE", value: 65_537, line: 1)),
            ("size_1_1d.cube", .sizeOutOfRange(keyword: "LUT_1D_SIZE", value: 1, line: 1)),
            ("size_not_integer.cube", .malformedKeyword(keyword: "LUT_3D_SIZE", line: 1)),
            ("size_missing_value.cube", .malformedKeyword(keyword: "LUT_3D_SIZE", line: 1)),
            ("size_two_values.cube", .malformedKeyword(keyword: "LUT_3D_SIZE", line: 1)),
            ("duplicate_size.cube", .duplicateKeyword(keyword: "LUT_3D_SIZE", line: 2)),
            ("duplicate_title.cube", .duplicateKeyword(keyword: "TITLE", line: 2)),
            ("keyword_after_data.cube", .keywordAfterData(keyword: "DOMAIN_MAX", line: 6)),
            ("row_two_values.cube", .wrongValueCount(line: 3, found: 2)),
            ("row_four_values.cube", .wrongValueCount(line: 3, found: 4)),
            ("row_not_a_number.cube", .notANumber(line: 3, token: "abc")),
            ("row_nan.cube", .nonFinite(line: 3)),
            ("row_nan_first.cube", .nonFinite(line: 2)),
            ("row_inf.cube", .nonFinite(line: 3)),
            ("row_overflow.cube", .nonFinite(line: 3)),
            ("too_few_rows.cube", .tooFewRows(expected: 8, found: 7)),
            ("too_many_rows.cube", .tooManyRows(expected: 8, line: 10)),
            ("size_but_no_rows.cube", .tooFewRows(expected: 8, found: 0)),
            ("shaper_rows_short.cube", .tooFewRows(expected: 11, found: 10)),
            ("domain_inverted.cube", .domainInverted(keyword: "DOMAIN_MIN / DOMAIN_MAX", line: 3)),
            ("domain_equal_channel.cube", .domainInverted(keyword: "DOMAIN_MIN / DOMAIN_MAX", line: 3)),
            ("domain_two_values.cube", .malformedKeyword(keyword: "DOMAIN_MIN", line: 2)),
            ("domain_nan.cube", .nonFinite(line: 2)),
            ("input_range_inverted.cube", .domainInverted(keyword: "LUT_3D_INPUT_RANGE", line: 2)),
            ("domain_and_input_range.cube", .domainConflict(line: 3)),
            ("domain_with_both_tables.cube", .domainConflict(line: 3)),
            ("input_range_without_table.cube", .rangeWithoutTable(keyword: "LUT_1D_INPUT_RANGE", line: 2)),
            ("not_utf8.cube", .notText),
        ]
        // Every file in bad/ has a row here, so a new malformed file cannot go unchecked.
        let dir = try url("bad", "")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".cube") }
        XCTAssertEqual(Set(files), Set(cases.map(\.0)))
        for (name, expected) in cases {
            XCTAssertEqual(try refusal(name), expected, name)
            XCTAssertFalse(expected.message.isEmpty)
        }
    }

    func testOversizedFileIsRefusedBeforeParsing() throws {
        let u = try url("good", "resolve_3d_2.cube")
        let bytes = try Data(contentsOf: u).count
        XCTAssertThrowsError(try CubeLUT.load(contentsOf: u, maxBytes: bytes - 1)) {
            XCTAssertEqual($0 as? CubeLUTError, .fileTooLarge(bytes: bytes))
        }
        XCTAssertThrowsError(try CubeLUT.parse(Data(count: 100), maxBytes: 99)) {
            XCTAssertEqual($0 as? CubeLUTError, .fileTooLarge(bytes: 100))
        }
    }

    func testMissingFileIsUnreadable() throws {
        XCTAssertThrowsError(try CubeLUT.load(contentsOf: url("bad", "no_such_file.cube"))) {
            guard case .unreadable = $0 as? CubeLUTError else { return XCTFail("\($0)") }
        }
    }

    // MARK: L0-P2 — whole file or nothing

    func testAFailedLoadLeavesTheSlotExactlyAsItWas() throws {
        var slot = CubeLUTSlot()
        let goodData = try Data(contentsOf: url("good", "vendor_style_3d.cube"))
        guard case .success = slot.load(goodData, name: "vendor_style_3d.cube") else { return XCTFail() }
        let before = slot

        let dir = try url("bad", "")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".cube") {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            guard case .failure = slot.load(data, name: name) else { return XCTFail("\(name) was accepted") }
            XCTAssertEqual(slot, before, name)
        }
        // A file that fails on its LAST row: everything before it parsed, and still nothing reaches the slot.
        var text = try String(contentsOf: url("good", "resolve_3d_2.cube"), encoding: .utf8)
        text = text.replacingOccurrences(of: "1.000000 1.000000 1.000000\n", with: "1.000000 1.000000 nan\n")
        guard case .failure(.nonFinite) = slot.load(Data(text.utf8), name: "late.cube") else { return XCTFail() }
        XCTAssertEqual(slot, before)

        slot.remove()
        XCTAssertNil(slot.lut)
        XCTAssertNil(slot.name)
    }

    // MARK: L0-P3 — line endings and the BOM

    func testLineEndingsAndBOMGiveTheSameTable() throws {
        let lf = try String(contentsOf: url("good", "vendor_style_3d.cube"), encoding: .utf8)
        XCTAssertFalse(lf.contains("\r"))
        let reference = try CubeLUT.parse(Data(lf.utf8))
        let variants: [(String, Data)] = [
            ("CRLF", Data(lf.replacingOccurrences(of: "\n", with: "\r\n").utf8)),
            ("CR", Data(lf.replacingOccurrences(of: "\n", with: "\r").utf8)),
            ("BOM + LF", Data([0xEF, 0xBB, 0xBF]) + Data(lf.utf8)),
            ("BOM + CRLF", Data([0xEF, 0xBB, 0xBF]) + Data(lf.replacingOccurrences(of: "\n", with: "\r\n").utf8)),
        ]
        for (label, data) in variants {
            XCTAssertEqual(try CubeLUT.parse(data), reference, label)
        }
        // Line numbers count CRLF as one line break, not two.
        let bad = "LUT_3D_SIZE 2\r\n0 0 0\r\n1 0\r\n"
        XCTAssertThrowsError(try CubeLUT.parse(Data(bad.utf8))) {
            XCTAssertEqual($0 as? CubeLUTError, .wrongValueCount(line: 3, found: 2))
        }
    }

    // MARK: L0-P5 — the caps

    private func identityText(size n: Int) -> String {
        var s = "LUT_3D_SIZE \(n)\n"
        s.reserveCapacity(n * n * n * 30 + 20)
        let d = Double(n - 1)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            s += "\(Double(r) / d) \(Double(g) / d) \(Double(b) / d)\n"
        } } }
        return s
    }

    private func oneDText(size n: Int) -> String {
        var s = "LUT_1D_SIZE \(n)\n"
        for i in 0..<n { let v = Double(i) / Double(n - 1); s += "\(v) \(v) \(v)\n" }
        return s
    }

    func testCaps() throws {
        XCTAssertEqual(try CubeLUT.parse(Data(identityText(size: 65).utf8)).cube?.size, 65)
        XCTAssertEqual(try CubeLUT.parse(Data(identityText(size: 2).utf8)).cube?.size, 2)
        XCTAssertThrowsError(try CubeLUT.parse(Data(identityText(size: 66).utf8))) {
            XCTAssertEqual($0 as? CubeLUTError, .sizeOutOfRange(keyword: "LUT_3D_SIZE", value: 66, line: 1))
        }
        XCTAssertEqual(try CubeLUT.parse(Data(oneDText(size: 65_536).utf8)).shaper?.size, 65_536)
        XCTAssertEqual(try CubeLUT.parse(Data(oneDText(size: 2).utf8)).shaper?.size, 2)
        XCTAssertThrowsError(try CubeLUT.parse(Data(oneDText(size: 65_537).utf8))) {
            XCTAssertEqual($0 as? CubeLUTError, .sizeOutOfRange(keyword: "LUT_1D_SIZE", value: 65_537, line: 1))
        }
    }

    // MARK: L0-P7 — parse time

    func testA65CubeParsesWithinHalfASecond() throws {
        let data = Data(identityText(size: 65).utf8)
        var best = Double.infinity
        for _ in 0..<3 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let l = try CubeLUT.parse(data)
            best = min(best, CFAbsoluteTimeGetCurrent() - t0)
            XCTAssertEqual(l.cube?.values.count, 65 * 65 * 65 * 3)
        }
        print("[L0-P7] 65³ (\(data.count) bytes): best of 3 = \(String(format: "%.3f", best)) s")
        XCTAssertLessThanOrEqual(best, 0.5)
    }
}
