import XCTest
import CryptoKit
@testable import ContainerRepair

/// `SampleDescriptionSlackScanner` on synthetic movies, then on the real corpus where it is on this
/// machine. docs/BUGS.md, "A video `stsd` longer than its entries hides the video track".
final class SampleDescriptionSlackTests: XCTestCase {

    // MARK: - A synthetic movie

    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }
    /// A sample entry: the 86-byte visual entry with zeros where the fields would be.
    private func entry(_ type: String = "ap4h", extra: [UInt8] = []) -> [UInt8] {
        box(type, [UInt8](repeating: 0, count: 78) + extra)
    }
    private func stsd(_ entries: [[UInt8]], count: UInt32? = nil, slack: [UInt8] = []) -> [UInt8] {
        box("stsd", [0, 0, 0, 0] + be32(count ?? UInt32(entries.count)) + entries.flatMap { $0 } + slack)
    }
    private func trak(handler: String, stsd: [UInt8]) -> [UInt8] {
        let hdlr = box("hdlr", [0, 0, 0, 0] + Array("mhlr".utf8) + Array(handler.utf8) + [UInt8](repeating: 0, count: 13))
        let stbl = box("stbl", stsd + box("stts", [0, 0, 0, 0, 0, 0, 0, 0]))
        let minf = box("minf", box("vmhd", [UInt8](repeating: 0, count: 12)) + stbl)
        let mdia = box("mdia", box("mdhd", [UInt8](repeating: 0, count: 24)) + hdlr + minf)
        return box("trak", box("tkhd", [UInt8](repeating: 0, count: 84)) + mdia)
    }
    private func movie(_ traks: [[UInt8]], moovFirst: Bool = false, mdat: [UInt8]? = nil) -> [UInt8] {
        let ftyp = box("ftyp", Array("qt  ".utf8) + [0, 0, 2, 0] + Array("qt  ".utf8))
        let moov = box("moov", box("mvhd", [UInt8](repeating: 0, count: 100)) + traks.flatMap { $0 })
        let m = mdat ?? box("mdat", [UInt8](repeating: 0xAB, count: 4096))
        return moovFirst ? ftyp + moov + m : ftyp + m + moov
    }
    private func scan(_ bytes: [UInt8]) -> SampleDescriptionFinding {
        let d = Data(bytes)
        return SampleDescriptionSlackScanner.scan(fileSize: UInt64(d.count)) { off, n in
            guard off < UInt64(d.count) else { return Data() }
            return d.subdata(in: Int(off)..<min(d.count, Int(off) + n))
        }
    }
    /// Absolute offset of the first `stsd` size field in `bytes`.
    private func stsdOffset(in bytes: [UInt8], after start: Int = 0) -> UInt64 {
        let t = Array("stsd".utf8)
        for i in start..<(bytes.count - 4) where Array(bytes[i..<(i + 4)]) == t { return UInt64(i - 4) }
        return 0
    }

    // MARK: - Synthetic

    func testConsistentVideoTrack() {
        XCTAssertEqual(scan(movie([trak(handler: "vide", stsd: stsd([entry()]))])), .consistent)
        XCTAssertEqual(scan(movie([trak(handler: "vide", stsd: stsd([entry()]))], moovFirst: true)), .consistent)
        // Extension boxes inside the entry are the entry's own bytes, not slack.
        let withExt = entry(extra: box("colr", Array("nclc".utf8) + [0, 1, 0, 1, 0, 1]) + box("pasp", be32(1) + be32(1)))
        XCTAssertEqual(scan(movie([trak(handler: "vide", stsd: stsd([withExt]))])), .consistent)
    }

    /// The positive controls: every slack from 1 to 16 bytes, zeros and 0xFF, moov before and after mdat.
    func testPositiveControls1To16() {
        for n in 1...16 {
            for fill: UInt8 in [0x00, 0xFF] {
                for moovFirst in [false, true] {
                    let m = movie([trak(handler: "vide", stsd: stsd([entry()], slack: [UInt8](repeating: fill, count: n)))],
                                  moovFirst: moovFirst)
                    let off = stsdOffset(in: m)
                    guard case .slack(let s) = scan(m) else {
                        return XCTFail("slack \(n) fill \(fill) moovFirst \(moovFirst): \(scan(m))")
                    }
                    XCTAssertEqual(s.count, 1)
                    XCTAssertEqual(s[0].slackBytes, UInt64(n))
                    XCTAssertEqual(s[0].stsdOffset, off)
                    XCTAssertEqual(s[0].accountedSize, 16 + 86)
                    XCTAssertFalse(s[0].usesLargeSize)
                }
            }
        }
    }

    func testOnlyVideoTracksAreJudged() {
        // An audio track's slack is not this defect's business; the video track is consistent.
        let m = movie([trak(handler: "soun", stsd: stsd([entry("lpcm")], slack: [0, 0, 0, 0, 0, 0, 0, 0])),
                       trak(handler: "vide", stsd: stsd([entry()]))])
        XCTAssertEqual(scan(m), .consistent)
        // No video track at all.
        XCTAssertEqual(scan(movie([trak(handler: "soun", stsd: stsd([entry("lpcm")]))])), .noVideoTrack)
        XCTAssertEqual(scan(movie([trak(handler: "tmcd", stsd: stsd([entry("tmcd")]))])), .noVideoTrack)
    }

    func testSecondVideoTrackWithSlackIsReportedAtItsOwnOffset() {
        let t1 = trak(handler: "vide", stsd: stsd([entry()]))
        let t2 = trak(handler: "vide", stsd: stsd([entry("apch")], slack: [UInt8](repeating: 0, count: 8)))
        let m = movie([t1, t2])
        guard case .slack(let s) = scan(m) else { return XCTFail("\(scan(m))") }
        XCTAssertEqual(s.count, 1)
        let first = Int(stsdOffset(in: m))
        XCTAssertEqual(s[0].stsdOffset, stsdOffset(in: m, after: first + 8))
    }

    func testTwoEntriesAccountedTogether() {
        XCTAssertEqual(scan(movie([trak(handler: "vide", stsd: stsd([entry(), entry("apch")]))])), .consistent)
        guard case .slack(let s) = scan(movie([trak(handler: "vide", stsd: stsd([entry(), entry("apch")], slack: [0, 0, 0, 0]))]))
        else { return XCTFail() }
        XCTAssertEqual(s[0].slackBytes, 4)
        XCTAssertEqual(s[0].accountedSize, 16 + 86 + 86)
    }

    func testNoMovieBox() {
        let ftyp = box("ftyp", Array("qt  ".utf8))
        XCTAssertEqual(scan(ftyp + box("mdat", [1, 2, 3])), .noMovieBox)
        // mdat of size 0 runs to the end of the file, so nothing after it is a box.
        XCTAssertEqual(scan(ftyp + be32(0) + Array("mdat".utf8) + [UInt8](repeating: 0, count: 64)), .noMovieBox)
        XCTAssertEqual(scan([]), .noMovieBox)
    }

    func testLargeSizeTopLevelBoxIsWalked() {
        let payload = [UInt8](repeating: 0, count: 32)
        let big = be32(1) + Array("mdat".utf8) + be32(0) + be32(UInt32(16 + payload.count)) + payload
        let m = movie([trak(handler: "vide", stsd: stsd([entry()], slack: [0, 0, 0, 0, 0, 0, 0, 0]))], mdat: big)
        guard case .slack(let s) = scan(m) else { return XCTFail("\(scan(m))") }
        XCTAssertEqual(s[0].slackBytes, 8)
    }

    func testMalformedMoviesAreNamedNotRouted() {
        // An entry whose size runs past its table.
        var bad = entry(); bad.replaceSubrange(0..<4, with: be32(500))
        if case .malformed = scan(movie([trak(handler: "vide", stsd: stsd([bad]))])) {} else { XCTFail("entry overrun") }
        // More entries declared than held.
        if case .malformed = scan(movie([trak(handler: "vide", stsd: stsd([entry()], count: 3))])) {} else { XCTFail("count") }
        // An entry size below the header.
        var tiny = entry(); tiny.replaceSubrange(0..<4, with: be32(4))
        if case .malformed = scan(movie([trak(handler: "vide", stsd: stsd([tiny]))])) {} else { XCTFail("tiny entry") }
        // A trak that claims more than moov holds.
        var t = trak(handler: "vide", stsd: stsd([entry()])); t.replaceSubrange(0..<4, with: be32(UInt32(t.count + 100)))
        if case .malformed = scan(movie([t])) {} else { XCTFail("trak overrun") }
        // moov itself running past the end of the file.
        var m = movie([trak(handler: "vide", stsd: stsd([entry()]))])
        let moovAt = m.count - (m.count - 20 - 4104)    // ftyp 20 + mdat 4104
        m.replaceSubrange(moovAt..<(moovAt + 4), with: be32(UInt32(m.count)))
        if case .malformed = scan(m) {} else { XCTFail("moov overrun") }
    }

    // MARK: - The real files, where they are on this machine

    /// The two clips that prompted this. Skipped where the folder is absent.
    func testJoeyClipsReportEightBytes() throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/CLIPS FROM JOEY")
        let cases: [(String, UInt64)] = [("A026C001_171116_R022.mov", 38_457_869), ("A027C021_171116_R022.mov", 42_844_685)]
        var ran = 0
        for (name, offset) in cases {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            ran += 1
            XCTAssertEqual(SampleDescriptionSlackScanner.scan(url: url),
                           .slack([VideoSampleDescriptionSlack(stsdOffset: offset, declaredSize: 1744,
                                                               accountedSize: 1736, usesLargeSize: false)]), name)
        }
        if ran == 0 { throw XCTSkip("CLIPS FROM JOEY is not on this machine") }
    }

    /// No false positives: every movie in the fixture corpus scans clean, and the only files that report
    /// slack anywhere are byte-for-byte copies of the two known-defective clips. Read-only; skipped
    /// where none of the corpus is present.
    func testCorpusHasNoFalsePositives() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let roots = [repo.appendingPathComponent("build"), repo.appendingPathComponent("docs"),
                     URL(fileURLWithPath: "/Volumes/DCCOLOR/TEST FLIP"),
                     URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/CLIPS FROM JOEY")]
        // SHA-256 of the two defective originals (A026, A027).
        let knownDefective: Set<String> = [
            "3fb4c9b5545bb64fafbe8cf1f1b3163ef437df5300a117d0eac6f5af24513bcb",
            "a196765edb4ca8ed9b50883fd9866a3e6df72b8f6ae010825d6f17da4a6b15d6",
        ]
        let exts: Set<String> = ["mov", "mp4", "m4v", "m4a", "qt", "3gp"]
        let skipDirs: Set<String> = ["Debug", "Manifold.build", "XCBuildData", "EagerLinkingTBDs",
                                     "ExplicitPrecompiledModules", "SwiftExplicitPrecompiledModules"]
        var scanned = 0, clean = 0, positives: [String] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in e {
                if skipDirs.contains(url.lastPathComponent) { e.skipDescendants(); continue }
                guard exts.contains(url.pathExtension.lowercased()), !url.lastPathComponent.hasPrefix("._") else { continue }
                scanned += 1
                switch SampleDescriptionSlackScanner.scan(url: url) {
                case .slack:
                    positives.append(url.path)
                    XCTAssertTrue(knownDefective.contains(try sha256(url)),
                                  "slack reported on a file that is not a known-defective clip: \(url.path)")
                case .malformed(let why):
                    XCTFail("malformed on a corpus file: \(url.path): \(why)")
                default:
                    clean += 1
                }
            }
        }
        if scanned == 0 { throw XCTSkip("no corpus on this machine") }
        print("[CONTAINER-TEST] corpus: \(scanned) scanned, \(clean) without slack, \(positives.count) known-defective copies")
    }

    private func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
