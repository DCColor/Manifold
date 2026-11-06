import XCTest
import CoreGraphics
import ImageIO
@testable import StillImageInfo

final class StillTextTests: XCTestCase {
    func testGainMapRowStatesTheFilesCapacityInNits() {
        XCTAssertEqual(StillText.headroomRow(kind: .gainMap(.adobeXMP), gainMapHeadroom: 19.70445, light: .init(), reportedHeadroom: 19.70445),
                       "HDR capacity 4,000 nits (from file)")
        XCTAssertEqual(StillText.headroomRow(kind: .gainMap(.apple), gainMapHeadroom: 4.1489, light: .init(), reportedHeadroom: nil),
                       "HDR capacity 842 nits (from file)")
        XCTAssertEqual(StillText.headroomRow(kind: .gainMap([]), gainMapHeadroom: nil, light: .init(), reportedHeadroom: nil),
                       "HDR capacity not stated")
    }

    func testPQRows() {
        XCTAssertEqual(StillText.headroomRow(kind: .pq, gainMapHeadroom: nil, light: .init(maxCLL: 4000), reportedHeadroom: 19.7),
                       "MaxCLL 4,000 nits (from file)")
        XCTAssertEqual(StillText.headroomRow(kind: .pq, gainMapHeadroom: nil, light: .init(), reportedHeadroom: 4.926108),
                       "Peak not stated; macOS assumes 1,000 nits")
        XCTAssertEqual(StillText.headroomRow(kind: .pq, gainMapHeadroom: nil, light: .init(), reportedHeadroom: nil),
                       "Peak not stated; macOS assumes 1,000 nits")
    }

    /// With `mdcv` alone macOS uses it, so the 1,000-nit sentence would be false (measured, B0).
    func testMasteringPeakAloneIsNotTheDefault() {
        XCTAssertEqual(StillText.headroomRow(kind: .pq, gainMapHeadroom: nil, light: .init(masteringPeak: 4000), reportedHeadroom: 19.7),
                       "Mastering peak 4,000 nits (from file)")
    }

    /// A number macOS read from somewhere this scan cannot see must not be called its default.
    func testAReportedNumberOffTheDefaultIsNotCalledAnAssumption() {
        XCTAssertEqual(StillText.headroomRow(kind: .pq, gainMapHeadroom: nil, light: .init(), reportedHeadroom: 19.7), "Peak not stated")
    }

    func testHLGClaimsNoAssumption() {
        XCTAssertEqual(StillText.headroomRow(kind: .hlg, gainMapHeadroom: nil, light: .init(), reportedHeadroom: 4.926108), "Peak not stated")
    }

    func testSDRHasNoRow() {
        XCTAssertNil(StillText.headroomRow(kind: .sdr, gainMapHeadroom: nil, light: .init(), reportedHeadroom: 1))
    }

    func testTypeRows() {
        XCTAssertEqual(StillHDRKind.gainMap(.adobeXMP).typeRow, "Gain map (Adobe XMP)")
        XCTAssertEqual(StillHDRKind.gainMap(.iso21496).typeRow, "Gain map (ISO 21496-1)")
        XCTAssertEqual(StillHDRKind.gainMap([.apple, .iso21496]).typeRow, "Gain map (ISO 21496-1 + Apple)")
        XCTAssertEqual(StillHDRKind.gainMap([]).typeRow, "Gain map (format not identified)")
    }

    func testOrientationsThatSwapAxes() {
        XCTAssertEqual((1...8).filter(StillText.orientationSwapsAxes), [5, 6, 7, 8])
    }

    func testCaptureDate() {
        XCTAssertEqual(StillText.captureDate("2024:05:01 12:34:56"), "2024-05-01 12:34:56")
        XCTAssertEqual(StillText.captureDate("sometime"), "sometime")
    }

    func testGrouping() {
        XCTAssertEqual(StillText.grouped(842), "842")
        XCTAssertEqual(StillText.grouped(1000), "1,000")
        XCTAssertEqual(StillText.grouped(1234567), "1,234,567")
    }

    func testTransportLineAndRows() {
        let info = StillImageInfo(fileName: "a.jpg", format: "JPEG image", displayWidth: 4284, displayHeight: 5712, rotated: true,
                                  colorProfile: nil, bitDepth: 8, hdr: .gainMap(.apple), headroomRow: "HDR capacity 761 nits (from file)",
                                  captureDate: nil, fileCreated: nil, fileModified: nil)
        XCTAssertEqual(info.transportLine, "Still image · 4284 × 5712 · HDR (gain map)")
        XCTAssertEqual(info.inspectorRows.map(\.label), ["Format", "Dimensions", "Color Profile", "Bit Depth", "HDR Type", "Headroom"])
        XCTAssertEqual(info.dimensions, "4284 × 5712 (rotated)")
        XCTAssertEqual(info.inspectorRows[2].value, "Untagged")
    }
}

final class StillFileScanTests: XCTestCase {
    private func be32(_ v: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(UInt32(body.count + 8)) + Array(type.utf8) + body }
    private func full(_ type: String, version: UInt8 = 0, flags: UInt8 = 0, _ body: [UInt8]) -> [UInt8] {
        box(type, [version, 0, 0, flags] + body)
    }
    private func scan(_ bytes: [UInt8]) -> StillFileFacts { bytes.withUnsafeBytes { StillFileScan.scan(bytes: $0) } }

    private var ftyp: [UInt8] { box("ftyp", Array("avif".utf8) + [0, 0, 0, 0] + Array("mif1".utf8)) }

    private func clli(_ cll: UInt16) -> [UInt8] { box("clli", be16(cll) + be16(400)) }
    private func mdcv(_ nits: UInt32) -> [UInt8] { box("mdcv", [UInt8](repeating: 0, count: 16) + be32(nits * 10000) + be32(50)) }

    /// `ipco` then `ipma` for item `primary`, whose properties are `indices`.
    private func avif(properties: [[UInt8]], item: UInt16 = 1, primary: UInt16 = 1, indices: [UInt8], extra: [UInt8] = []) -> [UInt8] {
        let ipma = full("ipma", be32(1) + be16(item) + [UInt8(indices.count)] + indices)
        let iprp = box("iprp", box("ipco", properties.flatMap { $0 }) + ipma)
        return ftyp + full("meta", full("pitm", be16(primary)) + extra + iprp)
    }

    func testClliOfThePrimaryItem() {
        XCTAssertEqual(scan(avif(properties: [clli(4000)], indices: [1])).light.maxCLL, 4000)
    }

    func testClliBelongingToAnotherItemIsNotThePictures() {
        XCTAssertNil(scan(avif(properties: [clli(4000)], item: 2, primary: 1, indices: [1])).light.maxCLL)
    }

    func testAbsentClli() {
        XCTAssertEqual(scan(avif(properties: [box("ispe", [UInt8](repeating: 0, count: 12))], indices: [1])).light, StatedLight())
    }

    func testAZeroClliIsUnknown() {
        XCTAssertNil(scan(avif(properties: [clli(0)], indices: [1])).light.maxCLL)
    }

    func testMdcv() {
        XCTAssertEqual(scan(avif(properties: [mdcv(4000)], indices: [1])).light.masteringPeak, 4000)
    }

    func testTruncationAtEveryLengthDoesNotCrash() {
        let whole = avif(properties: [clli(4000), mdcv(1000)], indices: [1, 2])
        for length in 0..<whole.count { _ = scan(Array(whole[..<length])) }
    }

    func testAppleAuxTypeInHEIF() {
        let auxC = full("auxC", Array("urn:com:apple:photo:2020:aux:hdrgainmap".utf8) + [0])
        XCTAssertEqual(scan(avif(properties: [auxC], indices: [1])).gainMaps, .apple)
    }

    func testTmapItemIsISO() {
        let infe = full("infe", version: 2, be16(2) + be16(0) + Array("tmap".utf8) + [0])
        let iinf = full("iinf", be16(1) + infe)
        XCTAssertEqual(scan(avif(properties: [clli(1)], indices: [1], extra: iinf)).gainMaps, .iso21496)
    }

    private func jpeg(_ text: String) -> [UInt8] { [0xFF, 0xD8, 0xFF, 0xE1, 0, 0] + Array(text.utf8) + [0xFF, 0xD9] }

    func testJPEGFormatsComeFromTheBytes() {
        XCTAssertEqual(scan(jpeg("xmlns:hdrgm=\"http://ns.adobe.com/hdr-gain-map/1.0/\"")).gainMaps, .adobeXMP)
        XCTAssertEqual(scan(jpeg("urn:iso:std:iso:ts:21496:-1")).gainMaps, .iso21496)
        XCTAssertEqual(scan(jpeg("urn:iso:std:iso:ts:21496:-1 urn:com:apple:photo:2020:aux:hdrgainmap")).gainMaps, [.iso21496, .apple])
        XCTAssertEqual(scan(jpeg("nothing")).gainMaps, [])
    }

    private func pngChunk(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(UInt32(body.count)) + Array(type.utf8) + body + [0, 0, 0, 0] }

    func testPNGLightChunks() {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let file = signature + pngChunk("IHDR", [UInt8](repeating: 0, count: 13))
            + pngChunk("cLLI", be32(4000 * 10000) + be32(400 * 10000))
            + pngChunk("mDCV", [UInt8](repeating: 0, count: 16) + be32(1000 * 10000) + be32(1))
            + pngChunk("IDAT", [1, 2, 3])
        XCTAssertEqual(scan(file).light, StatedLight(maxCLL: 4000, masteringPeak: 1000))
    }

    func testStatedCICP() {
        let colr = box("colr", Array("nclx".utf8) + be16(9) + be16(16) + be16(9) + [0x80])
        XCTAssertEqual(scan(avif(properties: [colr], indices: [1])).cicp, StatedCICP(primaries: 9, transfer: 16, matrix: 9))
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(scan(signature + pngChunk("cICP", [9, 18, 0, 1])).cicp, StatedCICP(primaries: 9, transfer: 18, matrix: 0))
    }

    func testUnknownFileHasNoFacts() {
        XCTAssertEqual(scan([1, 2, 3, 4, 5, 6, 7, 8, 9]), StillFileFacts())
    }
}

/// The real fixtures, which live outside the repo (`$HOME/Code/Manifold/fixtures/stills`). Skipped where they are absent.
final class StillImageReaderTests: XCTestCase {
    private var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code/Manifold/fixtures/stills")
    }

    private func image(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> StillImage {
        let url = root.appendingPathComponent(path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "fixture not here")
        guard case .image(let still) = StillImageReader.read(url: url) else {
            XCTFail("refused", file: file, line: line)
            throw XCTSkip("refused")
        }
        return still
    }

    /// The `public.heic` flip: read after properties, this would say HEIF.
    func testUltraHDRJPEGIsAJPEGWithAnAdobeGainMap() throws {
        let still = try image("JPEGR/1.1_01_00_00_00.jpg")
        XCTAssertTrue(still.info.format.localizedCaseInsensitiveContains("JPEG"), still.info.format)
        XCTAssertEqual(still.info.hdr, .gainMap(.adobeXMP))
        XCTAssertEqual(still.info.headroomRow, "HDR capacity 4,000 nits (from file)")
        XCTAssertEqual(still.picture.contentHeadroom, 8, accuracy: 0.01)
    }

    func testPQAVIFWithNoLightMetadata() throws {
        let still = try image("AVIF/1.1_01_00_00_00.avif")
        XCTAssertEqual(still.info.hdr, .pq)
        XCTAssertEqual(still.info.headroomRow, "Peak not stated; macOS assumes 1,000 nits")
    }

    /// The route's reason: `NSImage` loses HDR on this file and this decode does not.
    func testRotatedGainMapKeepsItsHDRAndTurns() throws {
        let still = try image("SDR JPEG/IMG_0026.jpeg")
        XCTAssertEqual(still.info.hdr, .gainMap([.iso21496, .apple]))
        XCTAssertEqual(still.info.dimensions, "4284 × 5712 (rotated)")
        XCTAssertEqual(still.picture.width, 4284)
        XCTAssertGreaterThan(still.picture.contentHeadroom, 3)
    }

    func testSDRControls() throws {
        XCTAssertEqual(try image("SDR PNG/IMG_1611.png").info.hdr, .sdr)
        XCTAssertEqual(try image("HEIC/sample1.heic").info.hdr, .sdr)
        XCTAssertNil(try image("SDR TIFF/IMG_1520.tiff").info.headroomRow)
        XCTAssertEqual(try image("SDR TIFF/IMG_1520_16bit.tiff").info.bitDepth, 16)
    }

    private func refusal(_ name: String, contents: Data) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url)
        guard case .refused(let notice, _) = StillImageReader.read(url: url) else {
            XCTFail("opened")
            return ""
        }
        return notice
    }

    func testDPXHasItsOwnRefusal() throws {
        XCTAssertEqual(try refusal("a.dpx", contents: Data([1, 2, 3])), "DPX isn’t supported yet.")
    }

    func testAFileThatIsNotAnImageIsRefused() throws {
        XCTAssertFalse(try refusal("a.png", contents: Data(repeating: 7, count: 512)).isEmpty)
    }
}

/// Scopes show the file: the frame must hold the stored code values.
final class StillScopeFrameTests: XCTestCase {
    private var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code/Manifold/fixtures/stills") }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// An 8-bit RGBA image in `space` from `value(x, y)`.
    private func image(width: Int, height: Int, space: CGColorSpace, value: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let v = value(x, y), i = (y * width + x) * 4
            bytes[i] = v.0; bytes[i + 1] = v.1; bytes[i + 2] = v.2
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func write(_ image: CGImage, _ name: String, type: String = "public.png", properties: [CFString: Any] = [:]) throws -> URL {
        let url = try folder().appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func frame(_ url: URL) throws -> StillScopeFrame {
        guard case .image(let still) = StillImageReader.read(url: url), let frame = still.scopeFrame else {
            throw XCTSkip("no frame")
        }
        return frame
    }

    private func pixel(_ f: StillScopeFrame, _ x: Int, _ y: Int) -> [UInt16] {
        f.pixels.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt16.self)
            return (0..<3).map { p[(y * f.width + x) * 4 + $0] }
        }
    }

    func testAnSRGBRampKeepsEveryCode() throws {
        let ramp = image(width: 256, height: 2, space: CGColorSpace(name: CGColorSpace.sRGB)!) { x, _ in (UInt8(x), UInt8(x), UInt8(x)) }
        let f = try frame(write(ramp, "ramp.png"))
        for x in 0..<256 { XCTAssertEqual(pixel(f, x, 0), [UInt16](repeating: UInt16(x) * 257, count: 3), "code \(x)") }
        XCTAssertEqual(f.color, StillScopeColor(primaries: 1, transfer: 13, matrix: 1, note: nil))
    }

    /// The trap the principle exists for: a Display P3 file must not be moved to anything else.
    func testDisplayP3StaysItsOwnValues() throws {
        let red = image(width: 4, height: 4, space: CGColorSpace(name: CGColorSpace.displayP3)!) { _, _ in (250, 10, 20) }
        let f = try frame(write(red, "p3.png"))
        XCTAssertEqual(pixel(f, 1, 1), [250 * 257, 10 * 257, 20 * 257])
        XCTAssertEqual(f.color.primaries, 12)
        XCTAssertNil(f.color.note)
    }

    func testAdobeRGBSaysItHasNoCode() throws {
        let c = image(width: 2, height: 2, space: CGColorSpace(name: CGColorSpace.adobeRGB1998)!) { _, _ in (100, 150, 200) }
        let f = try frame(write(c, "adobe.png"))
        XCTAssertEqual(pixel(f, 0, 0), [100 * 257, 150 * 257, 200 * 257])
        XCTAssertNil(f.color.primaries)
        XCTAssertTrue(f.color.note?.contains("no CICP code") == true, f.color.note ?? "nil")
    }

    func testUntaggedSaysSo() {
        XCTAssertEqual(StillScopeTags.resolve(cicp: nil, profile: nil, spaceName: nil, profileName: nil, hasGainMap: false),
                       StillScopeColor(primaries: nil, transfer: nil, matrix: nil, note: "Untagged: read as Rec. 709"))
    }

    func testCICPWinsOverAProfile() {
        let c = StillScopeTags.resolve(cicp: StatedCICP(primaries: 9, transfer: 18, matrix: 0), profile: nil,
                                       spaceName: CGColorSpace.sRGB as String, profileName: "x", hasGainMap: false)
        XCTAssertEqual(c, StillScopeColor(primaries: 9, transfer: 18, matrix: 9, note: nil))
    }

    /// Every orientation must land as ImageIO's own transform does, or the scope would not line up with the picture.
    func testOrientationsMatchImageIO() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let source = image(width: 3, height: 2, space: space) { x, y in (UInt8(x * 80), UInt8(y * 200), 7) }
        for orientation in 1...8 {
            let url = try write(source, "o\(orientation).png", type: "public.tiff",
                                properties: [kCGImagePropertyOrientation: orientation])
            let f = try frame(url)
            let swapped = orientation >= 5
            XCTAssertEqual(f.width, swapped ? 2 : 3)
            let isrc = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let turned = CGImageSourceCreateThumbnailAtIndex(isrc, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 3] as CFDictionary)!
            var expected = [UInt8](repeating: 0, count: f.width * f.height * 4)
            let context = CGContext(data: &expected, width: f.width, height: f.height, bitsPerComponent: 8, bytesPerRow: f.width * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(turned, in: CGRect(x: 0, y: 0, width: f.width, height: f.height))
            for y in 0..<f.height { for x in 0..<f.width {
                let i = (y * f.width + x) * 4
                XCTAssertEqual(pixel(f, x, y), (0..<3).map { UInt16(expected[i + $0]) * 257 }, "orientation \(orientation) at \(x),\(y)")
            } }
        }
    }

    private func fixture(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "fixture not here")
        return url
    }

    /// The stated codes, and the peak: 36.597 × 203 nits is 10-bit PQ code 991 (measured, B0).
    func testPQAVIFKeepsItsPeakCode() throws {
        let f = try frame(fixture("AVIF/1.1_01_00_00_00.avif"))
        XCTAssertEqual(f.color, StillScopeColor(primaries: 9, transfer: 16, matrix: 9, note: nil))
        let peak = f.pixels.withUnsafeBytes { raw -> UInt16 in
            let p = raw.bindMemory(to: UInt16.self)
            var m: UInt16 = 0
            for i in 0..<(f.width * f.height) { m = max(m, p[i * 4], p[i * 4 + 1], p[i * 4 + 2]) }
            return m
        }
        XCTAssertEqual(Double(peak) / 65535 * 1023, 991, accuracy: 0.6)
    }

    /// The base and not the HDR rendition: SDR white is its top.
    func testGainMapScopesTheSDRBase() throws {
        let f = try frame(fixture("JPEGR/1.1_01_00_00_00.jpg"))
        XCTAssertEqual(f.color, StillScopeColor(primaries: 12, transfer: 13, matrix: 1, note: "SDR base image (gain map not applied)"))
        let url = try fixture("JPEGR/1.1_01_00_00_00.jpg")
        let plain = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        XCTAssertEqual(plain.bitsPerComponent, 8)
        XCTAssertEqual(f.width, plain.width)
    }

    func testRotatedIPhoneFrameIsUpright() throws {
        let f = try frame(fixture("SDR JPEG/IMG_0026.jpeg"))
        XCTAssertEqual([f.width, f.height], [4284, 5712])
        XCTAssertEqual(f.color.note, "SDR base image (gain map not applied)")
    }
}
