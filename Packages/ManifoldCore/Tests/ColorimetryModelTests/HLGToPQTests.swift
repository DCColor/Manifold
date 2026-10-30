//
//  HLGToPQTests.swift
//  ColorimetryModelTests
//
//  Reference's HLG → PQ transcode (docs/HLG_MACOS_MODE_PLAN.md §6; 0.9.1): BT.2408 at a 1000-nit nominal peak.
//

import XCTest
@testable import ColorimetryModel

final class HLGToPQTests: XCTestCase {

    private let w2020 = HLGToPQ.luminanceWeights(primariesCode: 9)!

    /// BT.2020's luminance row, as BT.2100 states it to 4 places.
    func testRec2020LuminanceWeights() {
        XCTAssertEqual(w2020[0], 0.2627, accuracy: 0.00005)
        XCTAssertEqual(w2020[1], 0.6780, accuracy: 0.00005)
        XCTAssertEqual(w2020[2], 0.0593, accuracy: 0.00005)
    }

    /// The table in plan §6.2, neutral input: HLG E′ → nits → PQ E′.
    func testThePlanTable() {
        let rows: [(e: Double, nits: Double, pq: Double)] = [
            (0.5000, 50.7, 0.4416), (0.6296, 100.0, 0.5081), (0.7500, 203.2, 0.5808), (0.9000, 522.1, 0.6813), (1.0000, 1000.0, 0.7518),
        ]
        for r in rows {
            let lin = HLGToPQ.displayLight([r.e, r.e, r.e].map(HLGToPQ.inverseOETF), weights: w2020)
            XCTAssertEqual(lin[0], r.nits, accuracy: 0.1, "E′ \(r.e)")
            XCTAssertEqual(HLGToPQ.transcode([r.e, r.e, r.e], weights: w2020)[1], r.pq, accuracy: 0.0001, "E′ \(r.e)")
        }
    }

    /// BT.2408 reference white: HLG 75 % lands within half a nit of 203.
    func testReferenceWhiteIs203Nits() {
        let nits = HLGToPQ.displayLight([0.75, 0.75, 0.75].map(HLGToPQ.inverseOETF), weights: w2020)[0]
        XCTAssertEqual(nits, 203, accuracy: 0.5)
    }

    /// The headroom-1.0 clip point (1.0 = 100 nits) is HLG ≈ 63 %.
    func testHundredNitsIsSixtyThreePercent() {
        func nits(_ e: Double) -> Double { HLGToPQ.displayLight([e, e, e].map(HLGToPQ.inverseOETF), weights: w2020)[0] }
        XCTAssertLessThan(nits(0.629), 100)
        XCTAssertGreaterThan(nits(0.630), 100)
    }

    /// The OOTF is applied on luminance, so channel ratios in display light equal the scene-linear ratios (hue kept).
    func testOOTFKeepsChannelRatios() {
        let scene = [0.2, 0.05, 0.01]
        let out = HLGToPQ.displayLight(scene, weights: w2020)
        XCTAssertEqual(out[0] / out[1], scene[0] / scene[1], accuracy: 1e-9)
        XCTAssertEqual(out[2] / out[1], scene[2] / scene[1], accuracy: 1e-9)
    }

    /// Black and sub-black are 0, never NaN; PQ is clamped to [0, 1].
    func testBlackAndBounds() {
        XCTAssertEqual(HLGToPQ.transcode([0, 0, 0], weights: w2020), [0, 0, 0].map(HLGToPQ.pqEncode))
        XCTAssertFalse(HLGToPQ.transcode([-0.05, -0.05, -0.05], weights: w2020).contains { $0.isNaN })
        XCTAssertLessThanOrEqual(HLGToPQ.pqEncode(20_000), 1)
    }

    /// P3-D65 can be tagged PQ; Rec.709 primaries cannot (the layer would fall back to 709 SDR), so Reference must refuse.
    func testWeightsOnlyWhereALayerCanBeTaggedPQ() {
        XCTAssertNotNil(HLGToPQ.luminanceWeights(primariesCode: 12))
        XCTAssertNil(HLGToPQ.luminanceWeights(primariesCode: 1))
        XCTAssertNil(HLGToPQ.luminanceWeights(primariesCode: nil))
    }
}
