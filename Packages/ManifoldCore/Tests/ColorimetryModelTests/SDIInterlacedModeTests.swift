//
//  SDIInterlacedModeTests.swift
//  ColorimetryModelTests
//
//  Interlaced I2 (docs/INTERLACED_FINDINGS.md §5, §8): the 1080i modes, the selector's interlaced branch, and the
//  fields-kept placement. The progressive table and its rules are covered, unchanged, by SDIOutputModeTests.
//

import XCTest
@testable import ColorimetryModel

final class SDIInterlacedModeTests: XCTestCase {

    private let ntsc = 30000.0 / 1001.0

    func testInterlacedTableIsThreeModesLabelledByFieldRate() {
        XCTAssertEqual(SDIOutputMode.interlacedTable.map(\.label), ["1080i50", "1080i59.94", "1080i60"])
        XCTAssertEqual(SDIOutputMode.interlacedTable.map(\.rate.token), ["25", "29.97", "30"])
        XCTAssertTrue(SDIOutputMode.interlacedTable.allSatisfy { $0.width == 1920 && $0.height == 1080 && $0.isInterlaced })
        // The progressive table does not change: no interlaced mode in it.
        XCTAssertFalse(SDIOutputMode.table.contains { $0.isInterlaced })
        XCTAssertEqual(SDIOutputMode.table.count, 3 + 4 * 15)
    }

    func testInterlaced1080GoesOutAt1080iWhateverItsWidthAndTheSettings() {
        for (fps, label) in [(25.0, "1080i50"), (ntsc, "1080i59.94"), (30.0, "1080i60"), (29.97, "1080i59.94")] {
            for w in [1920, 1440, 1280] {
                for set in SDIOutputModeSet.allCases { for scaling in SDIScaling.allCases {
                    let m = SDIOutputModeSelector.select(width: w, height: 1080, pixelAspect: w == 1920 ? nil : 1920.0 / Double(w),
                                                         frameRate: fps, set: set, scaling: scaling, interlaced: true)
                    XCTAssertEqual(m.label, label, "\(w) \(fps) \(set) \(scaling)")
                }}
            }
        }
    }

    func testInterlacedWithNoInterlacedModeFallsBackToProgressiveUnder1to1() {
        // 1080 at 23.98 (§5): progressive, logged by the caller.
        XCTAssertEqual(SDIOutputModeSelector.select(width: 1920, height: 1080, pixelAspect: nil, frameRate: 24000.0 / 1001.0,
                                                    set: .hdUHD, scaling: .fit, interlaced: true).label, "1080p23.98")
        // A 540-line field sequence at 59.94 and a 576-line picture at 25: the 1:1 choice, never Fit's (which would scale
        // the rows), so the picture can be placed unscaled.
        XCTAssertEqual(SDIOutputModeSelector.select(width: 1920, height: 540, pixelAspect: nil, frameRate: 2 * ntsc,
                                                    set: .hdUHD, scaling: .fit, interlaced: true).label, "1080p59.94")
        XCTAssertEqual(SDIOutputModeSelector.select(width: 720, height: 576, pixelAspect: nil, frameRate: 25,
                                                    set: .hdUHD, scaling: .fit, interlaced: true).label, "1080p25")
        XCTAssertEqual(SDIOutputModeSelector.select(width: 720, height: 576, pixelAspect: nil, frameRate: 25,
                                                    set: .hdUHD, scaling: .fit, interlaced: false).label, "1080p25")
    }

    func testProgressiveSelectionIsUnchangedByTheNewParameter() {
        for m in SDIOutputMode.table { for set in SDIOutputModeSet.allCases { for scaling in SDIScaling.allCases {
            for (w, h) in [(m.width, m.height), (1440, 1080), (1280, 720), (720, 576), (4096, 1716)] {
                XCTAssertEqual(SDIOutputModeSelector.select(width: w, height: h, pixelAspect: nil, frameRate: m.rate.fps,
                                                            set: set, scaling: scaling),
                               SDIOutputModeSelector.select(width: w, height: h, pixelAspect: nil, frameRate: m.rate.fps,
                                                            set: set, scaling: scaling, interlaced: false))
            }
        }}}
    }

    func testFieldsKeptPlacement() {
        // 1920×1080i into 1080i: native, the pre-existing kernel.
        let native = SDIPlacement.fit(sourceWidth: 1920, sourceHeight: 1080, pixelAspect: nil, outputWidth: 1920,
                                      outputHeight: 1080, scaling: .fit, interlaced: true)
        XCTAssertTrue(native.isNative)
        // 1440×1080i at 4:3 pixels: desqueezed horizontally to 1920, rows 1:1, under either setting.
        for scaling in SDIScaling.allCases {
            let p = SDIPlacement.fit(sourceWidth: 1440, sourceHeight: 1080, pixelAspect: 4.0 / 3.0, outputWidth: 1920,
                                     outputHeight: 1080, scaling: scaling, interlaced: true)
            XCTAssertEqual([p.x, p.y, p.width, p.height], [0, 0, 1920, 1080]); XCTAssertTrue(p.fieldsKept)
            XCTAssertFalse(p.isUnscaled); XCTAssertEqual(p.scale, 1)
        }
        // Square-pixel 1440×1080i: 1:1, pillarboxed, unscaled.
        let sq = SDIPlacement.fit(sourceWidth: 1440, sourceHeight: 1080, pixelAspect: nil, outputWidth: 1920,
                                  outputHeight: 1080, scaling: .fit, interlaced: true)
        XCTAssertTrue(sq.isUnscaled); XCTAssertEqual(sq.x, 240); XCTAssertEqual(sq.kind, .pillarbox)
        // A display width wider than the mode: capped at the mode, the rows still 1:1 (here back to the source's own
        // width, so nothing is resampled and the native kernel runs; the aspect is not kept, which the scale says).
        let wide = SDIPlacement.fit(sourceWidth: 1920, sourceHeight: 1080, pixelAspect: 1.2, outputWidth: 1920,
                                    outputHeight: 1080, scaling: .fit, interlaced: true)
        XCTAssertEqual([wide.width, wide.height, wide.y], [1920, 1080, 0]); XCTAssertEqual(wide.scale, 1 / 1.2, accuracy: 1e-12)
        XCTAssertTrue(wide.isNative)
        let hdv = SDIPlacement.fit(sourceWidth: 1440, sourceHeight: 1080, pixelAspect: 4.0 / 3.0, outputWidth: 1920,
                                   outputHeight: 1080, scaling: .fit, interlaced: true)
        // Fewer rows than the mode: on an EVEN row, unscaled even under Fit (a progressive 486 would centre on 297).
        let sd = SDIPlacement.fit(sourceWidth: 720, sourceHeight: 486, pixelAspect: nil, outputWidth: 1920, outputHeight: 1080,
                                  scaling: .fit, interlaced: true)
        XCTAssertEqual(sd.y % 2, 0); XCTAssertEqual(sd.height, 486); XCTAssertTrue(sd.isUnscaled)
        XCTAssertEqual(SDIPlacement.fit(sourceWidth: 720, sourceHeight: 486, pixelAspect: nil, outputWidth: 1920,
                                        outputHeight: 1080, scaling: .oneToOne).y, 297)
        // Taller than the mode (a manual pick): placed as progressive.
        let down = SDIPlacement.fit(sourceWidth: 1920, sourceHeight: 1080, pixelAspect: nil, outputWidth: 1280,
                                    outputHeight: 720, scaling: .fit, interlaced: true)
        XCTAssertFalse(down.fieldsKept); XCTAssertEqual(down.height, 720)
        XCTAssertTrue(hdv.summary.contains("fields kept"), hdv.summary)
    }

    func testIdentityTapsAreExact() {
        let t = SDIResampleTaps.identity(length: 1080)
        XCTAssertEqual(t.tapsPerOutput, 1); XCTAssertEqual(t.outputCount, 1080)
        XCTAssertEqual(t.indices, (0..<1080).map { Int32($0) }); XCTAssertTrue(t.weights.allSatisfy { $0 == 1 })
        // Why it exists: Lanczos-3 at ratio 1 reads the neighbouring rows with tiny non-zero weights.
        let l = SDIResampleTaps.lanczos3(sourceLength: 1080, pictureLength: 1080)
        XCTAssertGreaterThan(l.tapsPerOutput, 1)
    }

    func testFieldToken() {
        XCTAssertEqual(SDIStandardRate.nearest(to: 25).fieldToken, "50")
        XCTAssertEqual(SDIStandardRate.nearest(to: ntsc).fieldToken, "59.94")
        XCTAssertEqual(SDIStandardRate.nearest(to: 30).fieldToken, "60")
    }
}
