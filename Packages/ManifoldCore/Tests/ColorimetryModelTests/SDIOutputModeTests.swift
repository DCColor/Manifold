//
//  SDIOutputModeTests.swift
//  ColorimetryModelTests
//
//  SDI scaling (docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, *SDI scaling*): the mode selector against the full mode
//  table, the fixture table written in §6.11 before any code, and the placement and resampling-tap rules.
//

import XCTest
@testable import ColorimetryModel

final class SDIOutputModeTests: XCTestCase {

    private let r2398 = 24000.0 / 1001.0

    /// The table is the card's progressive modes ≤ 4096×2160 at the eight rates: 720p at three, the others at eight.
    func testTableIsTheCardsModesInScope() {
        XCTAssertEqual(SDIOutputMode.table.count, 3 + 4 * 8)
        XCTAssertEqual(Set(SDIOutputMode.table.filter { $0.family == .p720 }.map(\.rate.token)), ["50", "59.94", "60"])
        XCTAssertTrue(SDIOutputMode.table.allSatisfy { $0.width <= 4096 && $0.height <= 2160 })
        XCTAssertEqual(Set(SDIOutputMode.table.map(\.label)).count, SDIOutputMode.table.count)
    }

    /// D2 over the whole table: every mode's own raster at its own rate goes out native, when the set includes it; a DCI
    /// raster under HD/UHD only never selects a DCI mode.
    func testEveryModeIsNativeAtItsOwnRasterAndRate() {
        for m in SDIOutputMode.table {
            for set in SDIOutputModeSet.allCases {
                let got = SDIOutputModeSelector.select(width: m.width, height: m.height, pixelAspect: nil,
                                                       frameRate: m.rate.fps, set: set)
                XCTAssertEqual(got.rate, m.rate, m.label)
                if m.family.isAvailable(in: set) {
                    XCTAssertEqual(got, m, "\(m.label) \(set)")
                    let p = SDIPlacement.fit(sourceWidth: m.width, sourceHeight: m.height, pixelAspect: 1,
                                             outputWidth: got.width, outputHeight: got.height)
                    XCTAssertTrue(p.isNative, m.label)
                } else {
                    XCTAssertFalse(got.family.isDCI, "\(m.label) under HD/UHD only chose \(got.label)")
                }
            }
        }
    }

    /// D1 and D3 as properties, over a grid of rasters at every rate and both sets: the mode is at the snapped rate, in
    /// the set; it holds the picture unless no mode does, and then it is a 2160-line mode; no smaller mode would hold it.
    func testSelectionPropertiesOverAGrid() {
        let sizes = stride(from: 64, through: 8192, by: 248).map { $0 }
        for rate in SDIStandardRate.all {
            for set in SDIOutputModeSet.allCases {
                let modes = SDIOutputMode.table.filter { $0.rate == rate && $0.family.isAvailable(in: set) }
                for w in sizes { for h in sizes {
                    let m = SDIOutputModeSelector.select(width: w, height: h, pixelAspect: nil, frameRate: rate.fps, set: set)
                    XCTAssertEqual(m.rate, rate)
                    XCTAssertTrue(m.family.isAvailable(in: set))
                    let holders = modes.filter { $0.width >= w && $0.height >= h }
                    if holders.isEmpty {
                        XCTAssertEqual(m.height, 2160)
                    } else {
                        XCTAssertTrue(m.width >= w && m.height >= h)
                        XCTAssertEqual(m.width * m.height, holders.map { $0.width * $0.height }.min())
                    }
                }}
            }
        }
    }

    /// The fixture table in §6.11, as written before the code: mode, picture rectangle and scale, both settings.
    func testFixtureTable() {
        typealias Row = (w: Int, h: Int, fps: Double, set: SDIOutputModeSet, mode: String, x: Int, y: Int, pw: Int, ph: Int, scale: Double)
        let r = r2398, hd = SDIOutputModeSet.hdUHD, dci = SDIOutputModeSet.includeDCI
        let rows: [Row] = [
            (1280, 720, r, hd, "1080p23.98", 318, 180, 1280, 720, 1),
            (1280, 720, r, dci, "1080p23.98", 318, 180, 1280, 720, 1),
            (1280, 720, 60000.0 / 1001.0, hd, "720p59.94", 0, 0, 1280, 720, 1),
            (1280, 720, 60000.0 / 1001.0, dci, "720p59.94", 0, 0, 1280, 720, 1),
            (1080, 1920, r, hd, "2160p23.98", 1380, 120, 1080, 1920, 1),
            (1080, 1920, r, dci, "2160p23.98", 1380, 120, 1080, 1920, 1),
            (1080, 1080, r, hd, "1080p23.98", 420, 0, 1080, 1080, 1),
            (2048, 858, r, hd, "2160p23.98", 894, 651, 2048, 858, 1),
            (2048, 858, r, dci, "2K DCI p23.98", 0, 111, 2048, 858, 1),
            (1440, 1080, r, hd, "1080p23.98", 240, 0, 1440, 1080, 1),
            (1920, 1080, r, hd, "1080p23.98", 0, 0, 1920, 1080, 1),
            (1920, 1080, r, dci, "1080p23.98", 0, 0, 1920, 1080, 1),
            (1920, 804, r, hd, "1080p23.98", 0, 138, 1920, 804, 1),
            (1920, 1038, r, dci, "1080p23.98", 0, 21, 1920, 1038, 1),
            (1998, 1080, r, hd, "2160p23.98", 918, 540, 1998, 1080, 1),
            (1998, 1080, r, dci, "2K DCI p23.98", 24, 0, 1998, 1080, 1),
            (3840, 1608, r, dci, "2160p23.98", 0, 276, 3840, 1608, 1),
            (4096, 1716, r, hd, "2160p23.98", 0, 275, 3840, 1609, 0.9375),
            (4096, 1716, r, dci, "4K DCI p23.98", 0, 222, 4096, 1716, 1),
            (2048, 1080, r, hd, "2160p23.98", 894, 540, 2048, 1080, 1),
            (2048, 1080, r, dci, "2K DCI p23.98", 0, 0, 2048, 1080, 1),
            (4096, 2160, r, hd, "2160p23.98", 0, 67, 3840, 2025, 0.9375),
            (4096, 2160, r, dci, "4K DCI p23.98", 0, 0, 4096, 2160, 1),
            (6144, 3240, r, hd, "2160p23.98", 0, 67, 3840, 2025, 0.625),
            (6144, 3240, r, dci, "4K DCI p23.98", 0, 0, 4096, 2160, 2.0 / 3.0),
            (1920, 817, r, hd, "1080p23.98", 0, 131, 1920, 817, 1),
        ]
        for row in rows {
            let m = SDIOutputModeSelector.select(width: row.w, height: row.h, pixelAspect: nil, frameRate: row.fps, set: row.set)
            let p = SDIPlacement.fit(sourceWidth: row.w, sourceHeight: row.h, pixelAspect: nil,
                                     outputWidth: m.width, outputHeight: m.height)
            let tag = "\(row.w)x\(row.h) \(row.set)"
            XCTAssertEqual(m.label, row.mode, tag)
            XCTAssertEqual([p.x, p.y, p.width, p.height], [row.x, row.y, row.pw, row.ph], tag)
            XCTAssertEqual(p.scale, row.scale, accuracy: 1e-12, tag)
        }
    }

    /// D9 and "never crop, never stretch": the rectangle is inside the output, on the 6-pixel group, centred within 3 px
    /// (x) and half a row (y), even when scaled, and its aspect is the source's display aspect within one pixel.
    func testPlacementProperties() {
        let outs = SDIModeFamily.allCases
        for w in stride(from: 2, through: 7000, by: 94) { for h in stride(from: 1, through: 4500, by: 61) {
            for o in outs {
                let p = SDIPlacement.fit(sourceWidth: w, sourceHeight: h, pixelAspect: nil,
                                         outputWidth: o.width, outputHeight: o.height)
                XCTAssertEqual(p.x % 6, 0)
                XCTAssertTrue(p.x >= 0 && p.y >= 0 && p.x + p.width <= o.width && p.y + p.height <= o.height,
                              "\(w)x\(h) in \(o)")
                XCTAssertLessThanOrEqual(abs(Double(p.x) - Double(o.width - p.width) / 2), 3)
                XCTAssertLessThanOrEqual(abs(Double(p.y) - Double(o.height - p.height) / 2), 0.5)
                if p.isUnscaled { XCTAssertEqual(p.scale, 1) } else {
                    XCTAssertEqual(p.width % 2, 0)
                    XCTAssertTrue(p.width == o.width || p.height == o.height, "a fit touches one side")
                    XCTAssertLessThanOrEqual(abs(Double(p.width) - Double(w) * p.scale), 2.0)
                    XCTAssertLessThanOrEqual(abs(Double(p.height) - Double(h) * p.scale), 1.0)
                }
            }
        }}
    }

    /// D6: a declared non-square pixel aspect is honoured (scaled horizontally even when it fits); undeclared is square.
    func testPixelAspect() {
        // HDV 1440×1080 at 4:3 → 1920×1080 display: native-size picture in 1080p, desqueezed, no bars.
        let m = SDIOutputModeSelector.select(width: 1440, height: 1080, pixelAspect: 4.0 / 3.0, frameRate: 25, set: .hdUHD)
        XCTAssertEqual(m.label, "1080p25")
        let p = SDIPlacement.fit(sourceWidth: 1440, sourceHeight: 1080, pixelAspect: 4.0 / 3.0, outputWidth: 1920, outputHeight: 1080)
        XCTAssertEqual([p.x, p.y, p.width, p.height], [0, 0, 1920, 1080])
        XCTAssertFalse(p.isUnscaled); XCTAssertFalse(p.isNative)
        XCTAssertTrue(p.summary.contains("desqueezed"), p.summary)
        // A 2:1 scope 2880×2160 → 5760 display → fitted into 2160p at 3840 wide.
        let a = SDIPlacement.fit(sourceWidth: 2880, sourceHeight: 2160, pixelAspect: 2, outputWidth: 3840, outputHeight: 2160)
        XCTAssertEqual([a.width, a.height], [3840, 1440])
        // 1920×1080 declared 1:1 is native; undeclared too.
        XCTAssertTrue(SDIPlacement.fit(sourceWidth: 1920, sourceHeight: 1080, pixelAspect: 1, outputWidth: 1920, outputHeight: 1080).isNative)
        XCTAssertFalse(SDIPlacement.fit(sourceWidth: 1920, sourceHeight: 1080, pixelAspect: nil, outputWidth: 1920, outputHeight: 1080).pixelAspectDeclared)
    }

    /// D8: the readout words.
    func testSummary() {
        XCTAssertEqual(SDIPlacement.fit(sourceWidth: 1080, sourceHeight: 1080, pixelAspect: nil, outputWidth: 1920, outputHeight: 1080).summary,
                       "source 1080×1080 1:1, pillarboxed")
        XCTAssertEqual(SDIPlacement.fit(sourceWidth: 4096, sourceHeight: 2160, pixelAspect: nil, outputWidth: 3840, outputHeight: 2160).summary,
                       "source 4096×2160 scaled ×0.9375 to 3840×2025, letterboxed")
        XCTAssertEqual(SDIPlacement.fit(sourceWidth: 1920, sourceHeight: 1080, pixelAspect: nil, outputWidth: 1920, outputHeight: 1080).summary,
                       "source 1920×1080 native")
    }

    /// The taps: normalised, in range, mirrored at the edges, symmetric for a symmetric mapping, stretched for chroma.
    func testLanczosTaps() {
        for (src, dst) in [(4096, 3840), (6144, 3840), (6144, 4096), (1716, 1609), (2160, 2025), (1440, 1920)] {
            for stride in [1, 2] {
                let t = SDIResampleTaps.lanczos3(sourceLength: src, pictureLength: dst, stride: stride)
                XCTAssertEqual(t.outputCount, (dst + stride - 1) / stride)
                for i in 0..<t.outputCount {
                    var sum = 0.0
                    for k in 0..<t.tapsPerOutput {
                        sum += Double(t.weights[i * t.tapsPerOutput + k])
                        XCTAssertTrue((0..<src).contains(Int(t.indices[i * t.tapsPerOutput + k])))
                    }
                    XCTAssertEqual(sum, 1, accuracy: 1e-5)
                }
            }
        }
        // 6144 → 4096 is ×2/3: the luma kernel spans 3 × 1.5 each side, chroma 3 × 3.
        XCTAssertEqual(SDIResampleTaps.lanczos3(sourceLength: 6144, pictureLength: 4096).tapsPerOutput, 11)
        XCTAssertEqual(SDIResampleTaps.lanczos3(sourceLength: 6144, pictureLength: 4096, stride: 2).tapsPerOutput, 19)
        // Mirroring: index −1 is 1, n is n − 2.
        XCTAssertEqual(SDIResampleTaps.mirror(-1, 10), 1)
        XCTAssertEqual(SDIResampleTaps.mirror(10, 10), 8)
        // A constant stays constant through the weights (DC gain 1), and a 1:1 mapping with stride 1 is the identity.
        let id = SDIResampleTaps.lanczos3(sourceLength: 100, pictureLength: 100)
        for i in 0..<100 {
            var v = 0.0
            for k in 0..<id.tapsPerOutput { v += Double(id.weights[i * id.tapsPerOutput + k]) * (Int(id.indices[i * id.tapsPerOutput + k]) == i ? 1 : 0) }
            XCTAssertEqual(v, 1, accuracy: 1e-6)
        }
    }

    /// D3's tie: a picture too tall for every mode scales by the same factor into 2160p and 4K DCI (height-bound), and
    /// then 2160p wins (decision taken unattended, §6.11).
    func testScaledFitTieGoesTo2160p() {
        let m = SDIOutputModeSelector.select(width: 3000, height: 4000, pixelAspect: nil, frameRate: 25, set: .includeDCI)
        XCTAssertEqual(m.label, "2160p25")
        let p = SDIPlacement.fit(sourceWidth: 3000, sourceHeight: 4000, pixelAspect: nil, outputWidth: 3840, outputHeight: 2160)
        XCTAssertEqual([p.width, p.height], [1620, 2160])
    }

    func testModeSetStorage() {
        XCTAssertEqual(SDIOutputModeSet.stored(nil), .hdUHD)
        XCTAssertEqual(SDIOutputModeSet.stored("includeDCI"), .includeDCI)
        XCTAssertEqual(SDIOutputModeSet.stored("garbage"), .hdUHD)
    }
}
