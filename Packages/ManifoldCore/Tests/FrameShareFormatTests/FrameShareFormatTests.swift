import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FrameShareFormat

final class FrameFileNameTests: XCTestCase {

    func testTimecodeFieldReplacesSeparators() {
        XCTAssertEqual(FrameFileName.timecodeField("01:02:14:05"), "01-02-14-05")
        XCTAssertEqual(FrameFileName.timecodeField("01:02:14;05"), "01-02-14-05")   // drop frame: not marked
    }

    /// Robbie's example, 2026-11-15.
    func testClipBaseMatchesTheDecidedExample() {
        let base = FrameFileName.clipBase(clipName: "MyClip", timecodeField: FrameFileName.timecodeField("01:02:14:05"))
        XCTAssertEqual(base, "MyClip 01-02-14-05")
        XCTAssertEqual(base + ".jpg", "MyClip 01-02-14-05.jpg")
    }

    func testElapsedTimecodeSplitsAtTheIntegerRate() {
        XCTAssertEqual(FrameFileName.elapsedTimecode(seconds: 0, rate: 25), "00-00-00-00")
        XCTAssertEqual(FrameFileName.elapsedTimecode(seconds: 3734.2, rate: 25), "01-02-14-05")
        // 23.976: frame index at the exact rate, fields at 24. 1001 s × 23.976… = 24 000 frames = 1000 TC seconds.
        XCTAssertEqual(FrameFileName.elapsedTimecode(seconds: 1001, rate: 24000.0 / 1001), "00-16-40-00")
        // The last frame of a second at 59.94: fields at 60.
        XCTAssertEqual(FrameFileName.elapsedTimecode(seconds: 59.0 * 1001 / 60000, rate: 60000.0 / 1001), "00-00-00-59")
        // No usable rate or time: 24 fps from 0, as the readout's frame mode.
        XCTAssertEqual(FrameFileName.elapsedTimecode(seconds: 1.5, rate: 0), "00-00-01-12")
        XCTAssertEqual(FrameFileName.elapsedTimecode(seconds: .nan, rate: 25), "00-00-00-00")
    }

    func testStreamBaseUsesLocalDateAndTimeWithoutColons() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_794_751_402)   // 2026-11-15 14:03:22 UTC
        XCTAssertEqual(FrameFileName.streamBase(streamName: "Studio Feed", date: date, timeZone: utc),
                       "Studio Feed 2026-11-15 14-03-22")
        XCTAssertEqual(FrameFileName.fallbackBase(date: date, timeZone: utc), "Manifold frame 2026-11-15 14-03-22")
    }

    func testSanitizedRemovesPathAndHiddenFileCharacters() {
        XCTAssertEqual(FrameFileName.sanitized("Cam A/B: wide", fallback: "x"), "Cam A-B- wide")
        XCTAssertEqual(FrameFileName.sanitized("..hidden", fallback: "x"), "hidden")
        XCTAssertEqual(FrameFileName.sanitized("two\nlines\t here", fallback: "x"), "two lines here")
        XCTAssertEqual(FrameFileName.sanitized("  ", fallback: "Stream"), "Stream")
        XCTAssertEqual(FrameFileName.sanitized("", fallback: "Frame"), "Frame")
        let long = String(repeating: "é", count: 300)   // 2 bytes each
        let cut = FrameFileName.sanitized(long, fallback: "x")
        XCTAssertLessThanOrEqual(cut.utf8.count, FrameFileName.maxBaseBytes)
        XCTAssertTrue(cut.allSatisfy { $0 == "é" })
    }

    func testUniqueURLNeverReplacesAnEarlierExport() {
        let folder = URL(fileURLWithPath: "/tmp/exports", isDirectory: true)
        var taken: Set<String> = []
        func url() -> URL {
            FrameFileName.uniqueURL(in: folder, base: "MyClip 01-02-14-05", suffix: "_par2-1", ext: "png",
                                    exists: { taken.contains($0.lastPathComponent) })
        }
        XCTAssertEqual(url().lastPathComponent, "MyClip 01-02-14-05_par2-1.png")
        taken.insert("MyClip 01-02-14-05_par2-1.png")
        XCTAssertEqual(url().lastPathComponent, "MyClip 01-02-14-05 2_par2-1.png")
        taken.insert("MyClip 01-02-14-05 2_par2-1.png")
        XCTAssertEqual(url().lastPathComponent, "MyClip 01-02-14-05 3_par2-1.png")
    }
}

final class ShareJPEGTests: XCTestCase {

    // MARK: Fixtures: a 16-bit RGBX grey ramp tagged with the picture's colour space, as Export Frame's CGImage is.

    private func ramp(_ values: [Double], _ name: CFString, height: Int = 8) -> CGImage {
        rgbImage(values.map { ($0, $0, $0) }, CGColorSpace(name: name)!, height: height)
    }

    private func rgbImage(_ values: [(Double, Double, Double)], _ cs: CGColorSpace, height: Int = 8) -> CGImage {
        var row = [UInt16]()
        for (r, g, b) in values {
            row += [r, g, b].map { UInt16(($0 * 65535).rounded()) } + [65535]
        }
        let px = Array([[UInt16]](repeating: row, count: height).joined())
        // Each patch 8 px wide so JPEG's 8 × 8 blocks hold one value each.
        var wide = [UInt16]()
        for y in 0..<height {
            for x in 0..<values.count { for _ in 0..<8 { wide += px[(y * values.count + x) * 4 ..< (y * values.count + x) * 4 + 4] } }
        }
        let w = values.count * 8
        return CGImage(width: w, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: CGDataProvider(data: wide.withUnsafeBytes { Data($0) } as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// The G channel at each 8-px patch's centre, read from `image` drawn into 8-bit sRGB with no further conversion.
    private func greens(_ image: CGImage, patches: Int) -> [Int] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: ShareJPEG.colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let y = image.height / 2
        return (0..<patches).map { Int(p[(y * image.width + $0 * 8 + 4) * 4 + 1]) }
    }

    private func pqEncode(_ nits: Double) -> Double {
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128, c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let y = pow(nits / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    private func decode(_ data: Data) throws -> (image: CGImage, props: [CFString: Any], type: String) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        return (image, props, (CGImageSourceGetType(src) as String?) ?? "")
    }

    private func assertClose(_ got: [Int], _ want: [Int], tolerance: Int, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, what, file: file, line: line)
        for (i, (g, w)) in zip(got, want).enumerated() where abs(g - w) > tolerance {
            XCTFail("\(what) patch \(i): \(g), expected \(w) ± \(tolerance) (all: \(got))", file: file, line: line)
        }
    }

    // MARK: The container

    func testIsAn8BitSRGBJPEGAtQuality09() throws {
        XCTAssertEqual(ShareJPEG.quality, 0.9)
        let data = try XCTUnwrap(ShareJPEG.encode(ramp([0, 0.5, 1], CGColorSpace.itur_709)))
        let (image, props, type) = try decode(data)
        XCTAssertEqual(type, "public.jpeg")
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 8)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB, "tagged sRGB")
        XCTAssertEqual(props[kCGImagePropertyProfileName] as? String, "sRGB IEC61966-2.1")
        XCTAssertEqual(image.width, 24)
    }

    /// The pixel-aspect DPI pair Export Frame computes reaches the JPEG (as JFIF density): 2:1 anamorphic.
    func testPassesThePixelAspectDensityThrough() throws {
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 1417.0 * 0.0254, kCGImagePropertyDPIHeight: 2834.0 * 0.0254]
        let data = try XCTUnwrap(ShareJPEG.encode(ramp([0.5], CGColorSpace.itur_709), properties: props))
        let (_, out, _) = try decode(data)
        let x = try XCTUnwrap(out[kCGImagePropertyDPIWidth] as? Double), y = try XCTUnwrap(out[kCGImagePropertyDPIHeight] as? Double)
        XCTAssertEqual(y / x, 2, accuracy: 0.02)
    }

    // MARK: The conversion

    /// sRGB in, sRGB out: no conversion beyond 16 → 8 bits.
    func testSRGBPictureIsUnchanged() throws {
        let v = [0.0, 0.25, 0.5, 0.75, 1.0]
        let data = try XCTUnwrap(ShareJPEG.encode(ramp(v, CGColorSpace.sRGB)))
        assertClose(greens(try decode(data).image, patches: v.count), v.map { Int(($0 * 255).rounded()) }, tolerance: 1, "sRGB")
    }

    /// A Rec. 709 picture comes out the same as ColorSync's own draw of it into sRGB (the compositor's conversion).
    func testRec709PictureIsColorSyncsConversion() throws {
        let v = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
        let img = ramp(v, CGColorSpace.itur_709)
        let data = try XCTUnwrap(ShareJPEG.encode(img))
        assertClose(greens(try decode(data).image, patches: v.count), greens(img, patches: v.count), tolerance: 1, "709")
        // Black and white stay black and white.
        let g = greens(try decode(data).image, patches: v.count)
        XCTAssertEqual(g.first, 0); XCTAssertEqual(g.last, 255)
    }

    /// HLG, every 5 %: As macOS Shows It on the ASUS at headroom 1.0 (docs/HLG_MACOS_MODE_PLAN.md §3.6a, T3).
    func testHLGMatchesAsMacOSShowsItOnAnSDRDisplay() throws {
        let v = (0...20).map { Double($0) * 0.05 }
        let t3 = [0, 2, 12, 24, 37, 47, 59, 72, 81, 94, 104, 117, 129, 147, 165, 187, 206, 220, 233, 244, 254]
        let data = try XCTUnwrap(ShareJPEG.encode(ramp(v, CGColorSpace.itur_2100_HLG)))
        assertClose(greens(try decode(data).image, patches: v.count), t3, tolerance: 2, "HLG")
    }

    /// PQ greys: the `.ifSupported` curve (§3.10b (c)), the one ColorSync's default draw gives. Pinned so an OS change
    /// that moves it is seen. The on-screen `.automatic` row (§3.10b (b)) is NOT matched: see the file header.
    func testPQIsColorSyncsDefaultToneMap() throws {
        let nits: [Double] = [0, 1, 10, 50, 100, 150, 203, 300, 400, 600, 1000, 4000]
        let ifSupported = [0, 12, 50, 104, 140, 166, 188, 211, 223, 238, 255, 255]
        let data = try XCTUnwrap(ShareJPEG.encode(ramp(nits.map(pqEncode), CGColorSpace.itur_2100_PQ)))
        assertClose(greens(try decode(data).image, patches: nits.count), ifSupported, tolerance: 2, "PQ")
    }

    /// A Rec. 2020 primary outside sRGB comes out as a legal sRGB colour, not wrapped or black.
    func testRec2020RedIsMappedIntoSRGB() throws {
        let data = try XCTUnwrap(ShareJPEG.encode(rgbImage([(0.5, 0, 0)], CGColorSpace(name: CGColorSpace.itur_2020)!)))
        let image = try decode(data).image
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: ShareJPEG.colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = ((image.height / 2) * image.width + 4) * 4
        XCTAssertGreaterThan(Int(p[i]), 100, "red")
        XCTAssertLessThan(Int(p[i + 1]), 20, "green")
        XCTAssertLessThan(Int(p[i + 2]), 20, "blue")
    }
}

final class ClipFolderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testFolderIsTheSameClipNameAsTheFileName() {
        let n = FrameName.clip(name: "MyClip", timecodeField: "01-02-14-05")
        XCTAssertEqual(n.base, "MyClip 01-02-14-05")
        XCTAssertEqual(n.folder, "MyClip")
        let s = FrameName.stream(name: "Studio Feed", date: Date(timeIntervalSince1970: 1_794_751_402),
                                 timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(s.base, "Studio Feed 2026-11-15 14-03-22")
        XCTAssertEqual(s.folder, "Studio Feed", "a stream's folder is its name, without the date")
    }

    func testFolderNameIsSafeTrimmedAndCapped() {
        XCTAssertEqual(FrameFileName.folderName("  Cam A/B: wide  ", fallback: "x"), "Cam A-B- wide")
        XCTAssertEqual(FrameFileName.folderName("...", fallback: "Frame"), "Frame")
        XCTAssertEqual(FrameFileName.folderName("name.", fallback: "x"), "name")
        XCTAssertEqual(FrameFileName.folderName("", fallback: "Stream"), "Stream")
        let long = FrameFileName.folderName(String(repeating: "ab ", count: 100), fallback: "x")
        XCTAssertLessThanOrEqual(long.utf8.count, FrameFileName.maxFolderBytes)
        XCTAssertFalse(long.hasSuffix(" "))
        let wide = FrameFileName.folderName(String(repeating: "é", count: 80), fallback: "x")   // 160 bytes
        XCTAssertEqual(wide, String(repeating: "é", count: 50))
    }

    func testCreatesTheFolderWhenMissingAndReusesIt() throws {
        let first = FrameFileName.clipFolder(in: root, name: "MyClip")
        XCTAssertEqual(first, .folder(root.appendingPathComponent("MyClip", isDirectory: true)))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("MyClip").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(FrameFileName.clipFolder(in: root, name: "MyClip"), first)
    }

    func testFileInTheWayFallsBackToTheRoot() throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("MyClip"))
        XCTAssertEqual(FrameFileName.clipFolder(in: root, name: "MyClip"), .root(root, reason: .fileInTheWay))
    }

    func testUncreatableFolderFallsBackToTheRoot() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)   // read-only root
        XCTAssertEqual(FrameFileName.clipFolder(in: root, name: "MyClip"), .root(root, reason: .couldNotCreate))
    }

    func testFallbackNoticeNamesTheFolderNotAPath() {
        let a = FrameFileName.fallbackNotice(folder: "MyClip", reason: .fileInTheWay)
        let b = FrameFileName.fallbackNotice(folder: "MyClip", reason: .couldNotCreate)
        for t in [a, b] { XCTAssertTrue(t.contains("“MyClip”")); XCTAssertFalse(t.contains("/")) }
    }
}

final class ShareLabelTests: XCTestCase {

    func testOnlyPQAndHLGAreHDR() {
        XCTAssertTrue(ShareLabel.isHDR(transfer: 16))
        XCTAssertTrue(ShareLabel.isHDR(transfer: 18))
        for t in [nil, 1, 13, 14, 15, 2] { XCTAssertFalse(ShareLabel.isHDR(transfer: t), "\(String(describing: t))") }
    }

    func testTitleSaysSDROnlyForAnHDRPicture() {
        XCTAssertEqual(ShareLabel.title(pictureIsHDR: true), "Share Frame (SDR)…")
        XCTAssertEqual(ShareLabel.title(pictureIsHDR: false), "Share Frame…")
    }

    /// Robbie's example, 2026-11-15.
    func testFileNameEndsInSDROnlyForAnHDRPicture() {
        XCTAssertEqual(ShareLabel.fileName(base: "MyClip 01-02-14-05", parTag: nil, pictureIsHDR: true), "MyClip 01-02-14-05 SDR.jpg")
        XCTAssertEqual(ShareLabel.fileName(base: "MyClip 01-02-14-05", parTag: nil, pictureIsHDR: false), "MyClip 01-02-14-05.jpg")
        XCTAssertEqual(ShareLabel.fileName(base: "MyClip 01-02-14-05", parTag: "par2-1", pictureIsHDR: true),
                       "MyClip 01-02-14-05_par2-1 SDR.jpg")
    }
}
