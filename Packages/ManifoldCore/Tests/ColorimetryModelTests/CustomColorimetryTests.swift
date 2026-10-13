//
//  CustomColorimetryTests.swift
//  ColorimetryModelTests
//
//  Colour S5 (COLOR_MANAGEMENT_FINDINGS.md §6.11, decision 7): Custom — primaries, transfer and matrix chosen
//  separately — from the S3 table's supported values only, mapped to that table axis by axis, and stored
//  on a bookmark as `custom:p-t-m`, which a reader from before S5 sees as Auto.
//

import XCTest
@testable import ColorimetryModel

final class CustomColorimetryTests: XCTestCase {

    /// The axis lists ARE the S3 table's: every listed code resolves on its own axis, and the table has
    /// nothing the lists leave out (among the CICP codes 0…22).
    func testAxisValuesAreExactlyTheTablesSupportedCodes() {
        XCTAssertEqual(CustomColorimetry.primaries, (0...22).filter { ColorPrimaries(cicp: $0) != nil })
        XCTAssertEqual(CustomColorimetry.transfers, (0...22).filter { TransferCurve(cicp: $0) != nil })
        XCTAssertEqual(CustomColorimetry.matrices, [1, 5, 6, 9])
        // The matrix table resolves anything else to 709; the four listed are the ones it names.
        for m in CustomColorimetry.matrices {
            XCTAssertEqual(YCbCrMatrix(cicp: m), m == 9 ? .rec2020 : (m == 1 ? .rec709 : .rec601))
        }
    }

    /// P1: every supported combination maps to the S3 table, each axis from its own code, no fallback.
    func testEverySupportedCombinationMapsToTheTable() {
        let all = CustomColorimetry.allSupported
        XCTAssertEqual(all.count, 6 * 6 * 4 - 2 * 4 * 4)   // 144, less PQ / HLG on the four non-HDR primaries
        for t in all {
            guard let o = ColorimetryOverride.customIfSupported(t) else { return XCTFail("\(t) refused") }
            XCTAssertTrue(o.isCustom)
            let p = o.preset!
            XCTAssertTrue(p == t, "\(o): preset \(p) is not \(t)")
            let a = ColorimetryTable.layerAttachments(primaries: p.primaries, transfer: p.transfer, matrix: p.matrix)
            XCTAssertNil(a.hdrFallback, "\(t)")
            XCTAssertEqual(a.primaries, ColorPrimaries(cicp: t.primaries), "\(t)")
            XCTAssertEqual(a.curve, TransferCurve(cicp: t.transfer), "\(t)")
            XCTAssertEqual(a.matrix, YCbCrMatrix(cicp: t.matrix), "\(t)")
            // Offered on every transport and on files (decided 2026-10-13).
            for tr in ColorimetryTransport.allCases { XCTAssertTrue(ColorimetryOverride.isOffered(o, on: tr)) }
        }
    }

    /// The combinations the table would draw as 709 SDR (`hdrFallback`) are refused, with a reason; so are
    /// codes outside the lists.
    func testFallbackCombinationsAndForeignCodesAreRefused() {
        var refused = 0
        for p in CustomColorimetry.primaries { for t in [16, 18] { for m in CustomColorimetry.matrices {
            let a = ColorimetryTable.layerAttachments(primaries: p, transfer: t, matrix: m)
            XCTAssertEqual(CustomColorimetry.isSupported((p, t, m)), a.hdrFallback == nil, "\(p)-\(t)-\(m)")
            if a.hdrFallback != nil {
                refused += 1
                XCTAssertNotNil(CustomColorimetry.refusal((p, t, m)))
                XCTAssertNil(ColorimetryOverride.customIfSupported((p, t, m)))
            }
        } } }
        XCTAssertEqual(refused, 32)
        for bad in [(2, 1, 1), (1, 13, 1), (1, 1, 0), (1, 1, 2), (10, 1, 1), (9, 8, 9), (0, 0, 0)] {
            XCTAssertFalse(CustomColorimetry.isSupported(bad), "\(bad)")
        }
    }

    /// `custom:p-t-m` round-trips for every supported triple.
    func testStorageRoundTrip() {
        for t in CustomColorimetry.allSupported {
            let o = ColorimetryOverride.customIfSupported(t)!
            XCTAssertEqual(o.storageID, "custom:\(t.primaries)-\(t.transfer)-\(t.matrix)")
            XCTAssertEqual(ColorimetryOverride(storageID: o.storageID), o)
            XCTAssertEqual(ColorimetryOverride(storageID: o.storageID, on: .hls), o)
        }
    }

    /// Read tolerantly: anything malformed or unsupported is Auto, never a throw and never a guess.
    func testMalformedOrUnsupportedCustomIsAuto() {
        for s in ["custom:", "custom:9-1", "custom:9-1-9-1", "custom:9--9", "custom:a-b-c", "custom: 9-1-9",
                  "Custom:9-1-9", "custom:1-16-1", "custom:2-2-2", "custom:9-1-0", "custom:-9-1-9", "custom9-1-9"] {
            XCTAssertEqual(ColorimetryOverride(storageID: s), .auto, s)
        }
    }

    /// An older-format reader: HEAD's `init(storageID:)` matched whole strings against its presets and
    /// nothing else. Restated here verbatim (the six strings are a storage format), so a `custom:` string
    /// provably reads as Auto on a build from before S5.
    func testAReaderFromBeforeS5SeesAuto() {
        let headPresets: [String: ColorimetryOverride] = ["rec709": .rec709, "rec2020-pq": .rec2020PQ,
            "rec2020-hlg": .rec2020HLG, "p3d65-pq": .p3d65PQ, "rec2020-sdr": .rec2020SDR]
        func headRead(_ s: String?) -> ColorimetryOverride { s.flatMap { headPresets[$0] } ?? .auto }
        for t in CustomColorimetry.allSupported {
            XCTAssertEqual(headRead(ColorimetryOverride.customIfSupported(t)!.storageID), .auto)
        }
        // …and the presets still read the same on both.
        for p in ColorimetryOverride.allCases { XCTAssertEqual(headRead(p.storageID), p) }
    }

    /// The label the title, readout and control face print: "Custom 9·1·6", primaries · transfer · matrix.
    func testLabel() {
        let o = ColorimetryOverride.customIfSupported((9, 1, 6))!
        XCTAssertEqual(o.shortLabel, "Custom 9·1·6")
        XCTAssertEqual(o.label, "Custom 9·1·6")
        XCTAssertNotEqual(o.id, ColorimetryOverride.customIfSupported((9, 1, 9))!.id)
    }

    /// Custom never joins the presets: the picker rows and ⌃⌥C's cycle are unchanged.
    func testPresetsAreUnchanged() {
        XCTAssertEqual(ColorimetryOverride.allCases, [.auto, .rec709, .rec2020PQ, .rec2020HLG, .p3d65PQ, .rec2020SDR])
        XCTAssertFalse(ColorimetryOverride.allCases.contains { $0.isCustom })
    }

    /// Custom resolves like a preset: all three axes overridden.
    func testResolveTakesCustom() {
        let r = SourceColorimetry.resolve(declared: .assumedRec709,
                                          override: ColorimetryOverride.customIfSupported((9, 1, 6))!)
        XCTAssertEqual([r.primaries.code, r.transfer.code, r.matrix.code], [9, 1, 6])
        XCTAssertEqual(r.sourceProvenance, .overridden)
    }
}
