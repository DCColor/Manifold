import XCTest
import Markers

/// Stage 4 (docs/CHAPTER_MARKERS_PLAN.md §13): sources 3 and 4 read from real files. The fixtures are ffmpeg-made or carry
/// Stage 3's synthetic XMP, none with a QuickTime user-data or XMP start timecode, so each reads none; the W1 Premiere
/// files are read by the opt-in probe below.
final class StartTimecodeFileTests: XCTestCase {

    private func fixture(_ name: String) throws -> URL {
        let parts = name.split(separator: ".")
        return try XCTUnwrap(Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]),
                                               subdirectory: "Fixtures"))
    }

    func testFixturesWithoutStartTimecodeMetadataReadNone() throws {
        for name in ["r-both.mp4", "r-track.mov", "r-chpl.mp4", "r-chap0.mov", "x-uuid.mp4", "x-udta.mov"] {
            let r = StartTimecodeMetadata.read(url: try fixture(name))
            XCTAssertEqual(r, StartTimecodeMetadata.Result(), name)
        }
        XCTAssertEqual(StartTimecodeMetadata.read(url: URL(fileURLWithPath: "/nonexistent/x.mov")), StartTimecodeMetadata.Result())
    }

    /// `MANIFOLD_TC_PROBE_LIST=<file of paths, one per line> swift test --filter StartTimecodeFileTests/testStartTimecodeProbe`
    /// Prints, per file: whether QuickTime user data and XMP hold a start timecode, each one's label, rate and drop-frame,
    /// and which of the two the precedence picks (sources 3 and 4 only: a `tmcd` track or container timecode, read by
    /// ManifoldCore, would win over both). Skipped without the variable.
    func testStartTimecodeProbe() throws {
        guard let list = ProcessInfo.processInfo.environment["MANIFOLD_TC_PROBE_LIST"] else {
            throw XCTSkip("MANIFOLD_TC_PROBE_LIST not set")
        }
        let paths = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        func describe(_ t: StartTimecode?) -> String {
            t.map { "\($0.label) fps=\(String(format: "%.3f", $0.fps)) nfr=\($0.nfr) df=\($0.dropFrame)" } ?? "none"
        }
        for p in paths {
            let url = URL(fileURLWithPath: p)
            let t0 = Date()
            let m = StartTimecodeMetadata.read(url: url)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let pick = StartTimecodePrecedence.file(.init(userData: m.userData, xmp: m.xmp))
            print("[TC-PROBE] \(url.lastPathComponent) read=\(ms)ms\n"
                  + "    user-data present=\(m.userDataPresent) \(describe(m.userData))\n"
                  + "    xmp present=\(m.xmpPresent) \(describe(m.xmp))\n"
                  + "    pick=\(pick?.source.rawValue ?? "none") \(pick?.label ?? "")")
        }
    }
}
