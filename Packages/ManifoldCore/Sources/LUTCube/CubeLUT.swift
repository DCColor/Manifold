//
//  CubeLUT.swift
//  LUTCube
//
//  A `.cube` LUT: 1D, 3D, or a 1D shaper followed by a 3D table (docs/COLOR_MANAGEMENT_FINDINGS.md §6.11,
//  *S6 — LUT: audit, decisions and plan*). Both dialects in use are read:
//
//    - Adobe / Iridas (Cube LUT Specification 1.0): `TITLE`, `LUT_1D_SIZE` or `LUT_3D_SIZE`,
//      `DOMAIN_MIN r g b`, `DOMAIN_MAX r g b`. What Nuke, OCIO's `iridas_cube` and most camera vendors write.
//    - Resolve: `LUT_1D_INPUT_RANGE lo hi`, `LUT_3D_INPUT_RANGE lo hi`, and BOTH sizes in one file, the 1D rows
//      first. The 1D table is then a shaper whose output feeds the 3D. What Resolve and OCIO's `resolve_cube` write.
//
//  ⚠️ THE WHOLE FILE OR NOTHING. `parse` builds every table before it returns, and throws on the first defect
//  with the line it is on. There is no partially built LUT to leak: a caller swaps in the returned value whole
//  (`CubeLUTSlot`), or keeps what it had.
//
//  Decisions it implements (Robbie, 2026-10-13): caps 65³ and 65 536 (D5); unknown keywords ignored and NAMED,
//  never silently (D7). The input clamp (D2) and the interpolation (D1) are the evaluator's (CubeLUTEvaluator.swift).
//

import Foundation

/// Limits on what is accepted (D5).
public enum CubeLUTLimits {
    public static let max3DSize = 65
    public static let max1DSize = 65_536
    /// The spec's floor: an interpolated table needs two nodes per axis.
    public static let minSize = 2
    /// A 65³ file is about 8 MB, and a 65 536-row 1D under 2 MB; anything near this is not a LUT.
    public static let maxFileBytes = 64 * 1024 * 1024
}

/// One table's input domain, per channel. Values outside it are clamped by the evaluator (D2).
public struct CubeDomain: Equatable, Sendable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>
    public static let unit = CubeDomain(min: SIMD3(repeating: 0), max: SIMD3(repeating: 1))
    public init(min: SIMD3<Float>, max: SIMD3<Float>) { self.min = min; self.max = max }
}

/// A 1D table: a 1D LUT's whole transform, or the shaper in front of a 3D table.
public struct CubeTable1D: Equatable, Sendable {
    public let size: Int
    public let domain: CubeDomain
    /// `size` rows of (r, g, b), flattened: row i is `values[3i ..< 3i+3]`.
    public let values: [Float]

    public func row(_ i: Int) -> SIMD3<Float> {
        SIMD3(values[3 * i], values[3 * i + 1], values[3 * i + 2])
    }
}

/// A 3D table. **Red changes fastest**, then green, then blue: node (r, g, b) is row `r + n·g + n²·b`.
public struct CubeTable3D: Equatable, Sendable {
    public let size: Int
    public let domain: CubeDomain
    /// `size³` rows of (r, g, b), flattened.
    public let values: [Float]

    public func node(r: Int, g: Int, b: Int) -> SIMD3<Float> {
        let i = 3 * (r + size * (g + size * b))
        return SIMD3(values[i], values[i + 1], values[i + 2])
    }
}

/// A line whose keyword was not recognised, ignored and named (D7).
public struct CubeIgnoredLine: Equatable, Sendable {
    public let line: Int
    public let keyword: String
}

public struct CubeLUT: Equatable, Sendable {
    public enum Kind: String, Sendable { case oneD = "1D", threeD = "3D", shaperAnd3D = "1D shaper + 3D" }

    public let title: String?
    /// The 1D table: the whole transform of a 1D LUT, or the shaper applied before `cube`.
    public let shaper: CubeTable1D?
    public let cube: CubeTable3D?
    /// Keyword lines that were not recognised, in file order.
    public let ignored: [CubeIgnoredLine]

    public var kind: Kind {
        switch (shaper, cube) {
        case (_?, _?): return .shaperAnd3D
        case (_?, nil): return .oneD
        default: return .threeD
        }
    }

    /// The transform alone, for comparing two files that differ only in comments, keywords or line endings.
    public func sameTable(as other: CubeLUT) -> Bool {
        title == other.title && shaper == other.shaper && cube == other.cube
    }

    /// How the readout and the log name the LUT's shape: `3D 33³`, `1D 4096`, `3D 33³ + 1D 4096 shaper`.
    public var shapeDescription: String {
        switch kind {
        case .oneD: return "1D \(shaper!.size)"
        case .threeD: return "3D \(cube!.size)³"
        case .shaperAnd3D: return "3D \(cube!.size)³ + 1D \(shaper!.size) shaper"
        }
    }
}

/// Why a file was refused. Every case names what is wrong and, where there is one, the line.
public enum CubeLUTError: Error, Equatable, Sendable {
    case unreadable(reason: String)
    case fileTooLarge(bytes: Int)
    case notText
    /// No size keyword: an empty file, or comments only.
    case noTable
    case dataBeforeSize(line: Int)
    case sizeOutOfRange(keyword: String, value: Int, line: Int)
    /// A keyword with the wrong number of values, or values that are not numbers.
    case malformedKeyword(keyword: String, line: Int)
    case duplicateKeyword(keyword: String, line: Int)
    case keywordAfterData(keyword: String, line: Int)
    case wrongValueCount(line: Int, found: Int)
    case notANumber(line: Int, token: String)
    case nonFinite(line: Int)
    case tooFewRows(expected: Int, found: Int)
    case tooManyRows(expected: Int, line: Int)
    /// A channel's minimum is not below its maximum.
    case domainInverted(keyword: String, line: Int)
    /// `DOMAIN_*` mixed with `*_INPUT_RANGE`, or `DOMAIN_*` in a file holding both a 1D and a 3D table, which
    /// does not say which table it bounds.
    case domainConflict(line: Int)
    /// `LUT_1D_INPUT_RANGE` without a 1D table, or `LUT_3D_INPUT_RANGE` without a 3D one.
    case rangeWithoutTable(keyword: String, line: Int)

    /// The banner's words. Nothing was loaded, and the caller says what is still applied.
    public var message: String {
        switch self {
        case .unreadable(let reason): return "The file could not be read: \(reason)."
        case .fileTooLarge(let bytes): return "The file is \(bytes / (1024 * 1024)) MB, larger than any LUT Manifold loads (64 MB)."
        case .notText: return "The file is not text."
        case .noTable: return "The file has no LUT_1D_SIZE or LUT_3D_SIZE line."
        case .dataBeforeSize(let line): return "Line \(line) has values before any LUT_1D_SIZE or LUT_3D_SIZE line."
        case .sizeOutOfRange(let keyword, let value, let line):
            let cap = keyword == "LUT_3D_SIZE" ? CubeLUTLimits.max3DSize : CubeLUTLimits.max1DSize
            return "Line \(line): \(keyword) \(value) is outside \(CubeLUTLimits.minSize)–\(cap)."
        case .malformedKeyword(let keyword, let line): return "Line \(line): \(keyword) does not have the values it needs."
        case .duplicateKeyword(let keyword, let line): return "Line \(line): \(keyword) appears a second time."
        case .keywordAfterData(let keyword, let line): return "Line \(line): \(keyword) comes after the table has started."
        case .wrongValueCount(let line, let found): return "Line \(line) has \(found) values; every row needs 3."
        case .notANumber(let line, let token): return "Line \(line): “\(token.prefix(24))” is not a number."
        case .nonFinite(let line): return "Line \(line) holds an infinite or not-a-number value."
        case .tooFewRows(let expected, let found): return "The table has \(found) rows; its size needs \(expected)."
        case .tooManyRows(let expected, let line): return "Line \(line) is past the \(expected) rows the size calls for."
        case .domainInverted(let keyword, let line): return "Line \(line): \(keyword) leaves a channel with its minimum not below its maximum."
        case .domainConflict(let line): return "Line \(line): the file's domain keywords contradict each other."
        case .rangeWithoutTable(let keyword, let line): return "Line \(line): \(keyword) has no table of its kind to apply to."
        }
    }
}

extension CubeLUT {

    /// Read and parse a file. The size is checked before the file is read.
    public static func load(contentsOf url: URL, maxBytes: Int = CubeLUTLimits.maxFileBytes) throws -> CubeLUT {
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > maxBytes { throw CubeLUTError.fileTooLarge(bytes: size) }
        } catch let e as CubeLUTError {
            throw e
        } catch {
            throw CubeLUTError.unreadable(reason: error.localizedDescription)
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw CubeLUTError.unreadable(reason: error.localizedDescription)
        }
        return try parse(data, maxBytes: maxBytes)
    }

    /// Parse a whole file, or throw a `CubeLUTError`. Never returns a partial table.
    public static func parse(_ data: Data, maxBytes: Int = CubeLUTLimits.maxFileBytes) throws -> CubeLUT {
        if data.count > maxBytes { throw CubeLUTError.fileTooLarge(bytes: data.count) }
        guard String(data: data, encoding: .utf8) != nil else { throw CubeLUTError.notText }
        var p = Parser(bytes: [UInt8](data))
        return try p.run()
    }
}

// MARK: - The parser

private struct Parser {
    let bytes: [UInt8]

    // Header state.
    var title: String?
    var size1D: Int?, size3D: Int?
    var domainMin: (SIMD3<Float>, Int)?, domainMax: (SIMD3<Float>, Int)?
    var range1D: ((Float, Float), Int)?, range3D: ((Float, Float), Int)?
    var seen: [String: Int] = [:]
    var ignored: [CubeIgnoredLine] = []

    // Data state.
    var values: [Float] = []
    var rows = 0
    var expectedRows = 0
    var firstDataLine: Int?

    init(bytes: [UInt8]) { self.bytes = bytes }

    static let known: Set<String> = ["TITLE", "LUT_1D_SIZE", "LUT_3D_SIZE", "DOMAIN_MIN", "DOMAIN_MAX",
                                     "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE"]

    mutating func run() throws -> CubeLUT {
        var i = 0
        let n = bytes.count
        // A UTF-8 byte-order mark is not part of the first line.
        if n >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        var lineNo = 0
        while i < n {
            // One line: up to LF, CRLF or a bare CR.
            var e = i
            while e < n, bytes[e] != 0x0A, bytes[e] != 0x0D { e += 1 }
            lineNo += 1
            try line(i, e, lineNo)
            if e < n, bytes[e] == 0x0D, e + 1 < n, bytes[e + 1] == 0x0A { i = e + 2 } else { i = e + 1 }
        }
        return try finish()
    }

    // MARK: Lines

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }

    /// The tokens of bytes[s..<e], whitespace-separated, stopping at a `#`.
    private func tokens(_ s: Int, _ e: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var j = s
        while j < e {
            while j < e, Self.isSpace(bytes[j]) { j += 1 }
            if j >= e || bytes[j] == 0x23 { break }   // '#': the rest is a comment
            let t = j
            while j < e, !Self.isSpace(bytes[j]), bytes[j] != 0x23 { j += 1 }
            out.append(t..<j)
        }
        return out
    }

    private func text(_ r: Range<Int>) -> String { String(decoding: bytes[r], as: UTF8.self) }

    private mutating func line(_ s: Int, _ e: Int, _ lineNo: Int) throws {
        let toks = tokens(s, e)
        guard let first = toks.first else { return }   // blank, or a comment

        // A data row starts with a number. `Float` also reads nan and inf, which start with letters: a row of them
        // is a data row holding a non-finite value, not an unknown keyword.
        let c = bytes[first.lowerBound]
        let startsNumeric = (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E
        if startsNumeric || Float(text(first)) != nil {
            try dataRow(toks, lineNo)
            return
        }

        let keyword = text(first).uppercased()
        guard Self.known.contains(keyword) else {
            // D7: ignored, and named.
            ignored.append(CubeIgnoredLine(line: lineNo, keyword: text(first)))
            return
        }
        if firstDataLine != nil { throw CubeLUTError.keywordAfterData(keyword: keyword, line: lineNo) }
        if seen[keyword] != nil { throw CubeLUTError.duplicateKeyword(keyword: keyword, line: lineNo) }
        seen[keyword] = lineNo
        let args = Array(toks.dropFirst())

        switch keyword {
        case "TITLE":
            title = titleText(s, e, after: first.upperBound)
        case "LUT_1D_SIZE", "LUT_3D_SIZE":
            guard args.count == 1, let v = Int(text(args[0])) else {
                throw CubeLUTError.malformedKeyword(keyword: keyword, line: lineNo)
            }
            let cap = keyword == "LUT_3D_SIZE" ? CubeLUTLimits.max3DSize : CubeLUTLimits.max1DSize
            guard v >= CubeLUTLimits.minSize, v <= cap else {
                throw CubeLUTError.sizeOutOfRange(keyword: keyword, value: v, line: lineNo)
            }
            if keyword == "LUT_1D_SIZE" { size1D = v } else { size3D = v }
        case "DOMAIN_MIN", "DOMAIN_MAX":
            let v = try floats(args, count: 3, keyword: keyword, lineNo)
            let triple = (SIMD3(v[0], v[1], v[2]), lineNo)
            if keyword == "DOMAIN_MIN" { domainMin = triple } else { domainMax = triple }
        default:   // LUT_1D_INPUT_RANGE, LUT_3D_INPUT_RANGE
            let v = try floats(args, count: 2, keyword: keyword, lineNo)
            if keyword == "LUT_1D_INPUT_RANGE" { range1D = ((v[0], v[1]), lineNo) } else { range3D = ((v[0], v[1]), lineNo) }
        }
    }

    /// `TITLE "text"`: the text between the quotes, which may hold a `#`. Lenient: an unquoted title, or an
    /// unterminated quote, gives the rest of the line, trimmed.
    private func titleText(_ s: Int, _ e: Int, after: Int) -> String {
        var j = after
        while j < e, Self.isSpace(bytes[j]) { j += 1 }
        if j < e, bytes[j] == 0x22 {
            var k = j + 1
            while k < e, bytes[k] != 0x22 { k += 1 }
            return text((j + 1)..<k)
        }
        var k = j
        while k < e, bytes[k] != 0x23 { k += 1 }
        return text(j..<k).trimmingCharacters(in: .whitespaces)
    }

    private func floats(_ args: [Range<Int>], count: Int, keyword: String, _ lineNo: Int) throws -> [Float] {
        guard args.count == count else { throw CubeLUTError.malformedKeyword(keyword: keyword, line: lineNo) }
        return try args.map {
            guard let v = Float(text($0)) else { throw CubeLUTError.malformedKeyword(keyword: keyword, line: lineNo) }
            guard v.isFinite else { throw CubeLUTError.nonFinite(line: lineNo) }
            return v
        }
    }

    private mutating func dataRow(_ toks: [Range<Int>], _ lineNo: Int) throws {
        if firstDataLine == nil {
            guard size1D != nil || size3D != nil else { throw CubeLUTError.dataBeforeSize(line: lineNo) }
            firstDataLine = lineNo
            let n3 = size3D.map { $0 * $0 * $0 } ?? 0
            expectedRows = (size1D ?? 0) + n3
            values.reserveCapacity(expectedRows * 3)
        }
        guard toks.count == 3 else { throw CubeLUTError.wrongValueCount(line: lineNo, found: toks.count) }
        guard rows < expectedRows else { throw CubeLUTError.tooManyRows(expected: expectedRows, line: lineNo) }
        for t in toks {
            let s = text(t)
            guard let v = Float(s) else { throw CubeLUTError.notANumber(line: lineNo, token: s) }
            guard v.isFinite else { throw CubeLUTError.nonFinite(line: lineNo) }
            values.append(v)
        }
        rows += 1
    }

    // MARK: The whole file

    private func checked(_ d: CubeDomain, keyword: String, line: Int) throws -> CubeDomain {
        for c in 0..<3 where !(d.min[c] < d.max[c]) {
            throw CubeLUTError.domainInverted(keyword: keyword, line: line)
        }
        return d
    }

    private mutating func finish() throws -> CubeLUT {
        guard size1D != nil || size3D != nil else { throw CubeLUTError.noTable }
        guard rows == expectedRows, firstDataLine != nil else {
            throw CubeLUTError.tooFewRows(expected: expectedRows == 0
                ? (size1D ?? 0) + (size3D.map { $0 * $0 * $0 } ?? 0) : expectedRows, found: rows)
        }

        // Domains. Adobe's DOMAIN_* and Resolve's *_INPUT_RANGE do not mix, and DOMAIN_* cannot say which of two
        // tables it bounds.
        let domainLine = domainMin?.1 ?? domainMax?.1
        if let dl = domainLine {
            if let r = range1D ?? range3D { throw CubeLUTError.domainConflict(line: max(dl, r.1)) }
            if size1D != nil, size3D != nil { throw CubeLUTError.domainConflict(line: dl) }
        }
        if let r = range1D, size1D == nil { throw CubeLUTError.rangeWithoutTable(keyword: "LUT_1D_INPUT_RANGE", line: r.1) }
        if let r = range3D, size3D == nil { throw CubeLUTError.rangeWithoutTable(keyword: "LUT_3D_INPUT_RANGE", line: r.1) }

        var adobe = CubeDomain.unit
        if let m = domainMin { adobe.min = m.0 }
        if let m = domainMax { adobe.max = m.0 }
        // An inverted Adobe domain is the PAIR's defect; it is reported at the later of the two lines.
        let adobeKeyword = "DOMAIN_MIN / DOMAIN_MAX"
        let adobeLine = max(domainMin?.1 ?? 0, domainMax?.1 ?? 0)

        func resolveDomain(_ r: ((Float, Float), Int)?, keyword: String) throws -> CubeDomain? {
            guard let r else { return nil }
            return try checked(CubeDomain(min: SIMD3(repeating: r.0.0), max: SIMD3(repeating: r.0.1)),
                               keyword: keyword, line: r.1)
        }

        var shaper: CubeTable1D?
        var cube: CubeTable3D?
        let n1 = size1D ?? 0
        if let s1 = size1D {
            let d = try resolveDomain(range1D, keyword: "LUT_1D_INPUT_RANGE")
                ?? (domainLine != nil ? checked(adobe, keyword: adobeKeyword, line: adobeLine) : .unit)
            shaper = CubeTable1D(size: s1, domain: d, values: Array(values[0 ..< 3 * s1]))
        }
        if let s3 = size3D {
            let d = try resolveDomain(range3D, keyword: "LUT_3D_INPUT_RANGE")
                ?? (domainLine != nil ? checked(adobe, keyword: adobeKeyword, line: adobeLine) : .unit)
            cube = CubeTable3D(size: s3, domain: d, values: Array(values[(3 * n1)...]))
        }
        return CubeLUT(title: title, shaper: shaper, cube: cube, ignored: ignored)
    }
}

// MARK: - The slot

/// One window's LUT slot, as L1–L3 hold it. A load either replaces the whole LUT or leaves the slot exactly as it
/// was: the parse completes before the single assignment, so there is no state in between.
public struct CubeLUTSlot: Equatable, Sendable {
    public private(set) var lut: CubeLUT?
    public private(set) var name: String?

    public init() {}

    /// Parse `data` and, only if the whole file is valid, put it in the slot. On failure the slot is unchanged
    /// and the error carries the banner's words.
    @discardableResult
    public mutating func load(_ data: Data, name: String) -> Result<CubeLUT, CubeLUTError> {
        do {
            let parsed = try CubeLUT.parse(data)
            (lut, self.name) = (parsed, name)
            return .success(parsed)
        } catch let e as CubeLUTError {
            return .failure(e)
        } catch {
            return .failure(.unreadable(reason: "\(error)"))
        }
    }

    public mutating func remove() { (lut, name) = (nil, nil) }
}
