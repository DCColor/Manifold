//
//  ColorimetryModelTests.swift
//  ColorimetryModelTests
//
//  The colorimetry override's presets, `resolve`, the provenance tiers and the Stage D storage
//  strings (docs/COLOR_MANAGEMENT_FINDINGS.md §6.9, Stage A). Until this target existed all of it
//  lived in App/ and was verified by measurement only (§6.9 finding 9; §6.8 2c part 2).
//

import XCTest
@testable import ColorimetryModel

final class ColorimetryModelTests: XCTestCase {

    // MARK: Fixtures

    /// A fully declared 2020 PQ source, in NDI's words.
    private let declared2020PQ = SourceColorimetry(primaries: .declaredValue(9, "bt_2020"),
                                                   transfer: .declaredValue(16, "bt_2100_pq"),
                                                   matrix: .declaredValue(9, "bt_2020"))

    /// Primaries and matrix declared, transfer absent (assumed 709).
    private let partlyDeclared = SourceColorimetry(primaries: .declaredValue(9, "bt_2020"),
                                                   transfer: .assumed(1),
                                                   matrix: .declaredValue(9, "bt_2020"))

    private func axes(_ c: SourceColorimetry) -> [ColorimetryAxis] { [c.primaries, c.transfer, c.matrix] }

    // MARK: Presets

    func testEachPresetsCICPTriple() {
        let expected: [(ColorimetryOverride, (Int, Int, Int)?)] = [
            (.auto, nil),
            (.rec709, (1, 1, 1)),
            (.rec2020PQ, (9, 16, 9)),
            (.rec2020HLG, (9, 18, 9)),
            (.p3d65PQ, (12, 16, 1)),        // P3-D65 primaries with a 709-class matrix, not a P3 one
            (.rec2020SDR, (9, 14, 9)),
        ]
        XCTAssertEqual(expected.map(\.0), ColorimetryOverride.allCases, "every preset is covered, in order")
        for (preset, triple) in expected {
            let got = preset.preset.map { ($0.primaries, $0.transfer, $0.matrix) }
            XCTAssertEqual(got.map { [$0.0, $0.1, $0.2] }, triple.map { [$0.0, $0.1, $0.2] }, "\(preset)")
        }
    }

    /// The labels the picker, the face and the `[NDI] colorimetry override →` log line print.
    /// Pinned because Stage A must not change a word of them.
    func testLabelsAreUnchanged() {
        XCTAssertEqual(ColorimetryOverride.allCases.map(\.label),
                       ["Auto", "Rec.709 (SDR)", "Rec.2020 PQ (HDR10)", "Rec.2020 HLG", "P3-D65 PQ", "Rec.2020 SDR"])
        XCTAssertEqual(ColorimetryOverride.allCases.map(\.shortLabel),
                       ["Auto", "709", "2020 PQ", "2020 HLG", "P3 PQ", "2020 SDR"])
    }

    // MARK: Resolve

    func testAutoPassesDeclaredValuesThroughPerAxis() {
        for source in [declared2020PQ, partlyDeclared, .assumedRec709] {
            let r = SourceColorimetry.resolve(declared: source, override: .auto)
            XCTAssertEqual(r, source)
            // Per axis: code, provenance and the raw word all survive.
            for (out, in_) in zip(axes(r), axes(source)) {
                XCTAssertEqual(out.code, in_.code)
                XCTAssertEqual(out.provenance, in_.provenance)
                XCTAssertEqual(out.declared, in_.declared)
            }
        }
    }

    func testOverrideBeatsDeclaredOnEveryAxis() {
        for preset in ColorimetryOverride.allCases where preset != .auto {
            let p = preset.preset!
            for source in [declared2020PQ, partlyDeclared, .assumedRec709] {
                let r = SourceColorimetry.resolve(declared: source, override: preset)
                XCTAssertEqual(axes(r).map(\.code), [p.primaries, p.transfer, p.matrix], "\(preset)")
                XCTAssertTrue(axes(r).allSatisfy { $0.provenance == .overridden }, "\(preset)")
                XCTAssertTrue(axes(r).allSatisfy { $0.declared == nil }, "an override carries no source word")
                XCTAssertTrue(r.isOverridden)
            }
        }
    }

    /// An override to the very triple the stream already declared is still an override: the codes
    /// match, the tier must not.
    func testOverrideMatchingTheDeclarationStillReadsOverridden() {
        let r = SourceColorimetry.resolve(declared: declared2020PQ, override: .rec2020PQ)
        XCTAssertEqual(axes(r).map(\.code), axes(declared2020PQ).map(\.code))
        XCTAssertEqual(r.sourceProvenance, .overridden)
        XCTAssertEqual(r.tier, "Overridden")
    }

    // MARK: Provenance and tier

    func testProvenanceAndTier() {
        let overridden = SourceColorimetry.resolve(declared: .assumedRec709, override: .rec709)
        let cases: [(String, SourceColorimetry, SourceColorProvenance, String, String)] = [
            ("declared",   declared2020PQ,  .tagged,        "Declared",   "tagged"),
            ("partly",     partlyDeclared,  .partlyAssumed, "Declared",   "partly assumed"),
            ("undeclared", .assumedRec709,  .assumed,       "Assumed",    "assumed"),
            ("overridden", overridden,      .overridden,    "Overridden", "overridden"),
        ]
        for (name, c, provenance, tier, label) in cases {
            XCTAssertEqual(c.sourceProvenance, provenance, name)
            XCTAssertEqual(c.tier, tier, name)
            XCTAssertEqual(c.sourceProvenance.label, label, name)
        }
        XCTAssertTrue(declared2020PQ.isDeclared)
        XCTAssertTrue(partlyDeclared.isDeclared)
        XCTAssertFalse(SourceColorimetry.assumedRec709.isDeclared)
        XCTAssertFalse(declared2020PQ.isOverridden)
    }

    /// Each single declared axis on its own is "partly assumed", whichever axis it is.
    func testOneDeclaredAxisIsPartlyAssumedWhicheverAxis() {
        let d = ColorimetryAxis.declaredValue(9, "bt_2020"), a = ColorimetryAxis.assumed(1)
        for c in [SourceColorimetry(primaries: d, transfer: a, matrix: a),
                  SourceColorimetry(primaries: a, transfer: d, matrix: a),
                  SourceColorimetry(primaries: a, transfer: a, matrix: d)] {
            XCTAssertEqual(c.sourceProvenance, .partlyAssumed)
        }
    }

    /// The renderer's code-based reading, for sources whose undeclared axes arrive as nil.
    func testProvenanceFromCodes() {
        XCTAssertEqual(SourceColorProvenance.fromCodes(primaries: nil, transfer: nil, matrix: nil), .assumed)
        XCTAssertEqual(SourceColorProvenance.fromCodes(primaries: 1, transfer: 1, matrix: 1), .tagged)
        XCTAssertEqual(SourceColorProvenance.fromCodes(primaries: 9, transfer: nil, matrix: 9), .partlyAssumed)
        XCTAssertEqual(SourceColorProvenance.fromCodes(primaries: nil, transfer: 16, matrix: nil), .partlyAssumed)
    }

    // MARK: Storage strings (Stage D)

    func testStorageIDs() {
        XCTAssertEqual(ColorimetryOverride.allCases.map(\.storageID),
                       [nil, "rec709", "rec2020-pq", "rec2020-hlg", "p3d65-pq", "rec2020-sdr"])
    }

    func testStorageIDRoundTripForEveryPreset() {
        for preset in ColorimetryOverride.allCases {
            XCTAssertEqual(ColorimetryOverride(storageID: preset.storageID), preset, "\(preset)")
        }
    }

    func testUnknownOrEmptyStorageIDIsAuto() {
        for s: String? in [nil, "", "auto", "Rec709", "rec2020PQ", "rec2020-pq ", "custom", "😀"] {
            XCTAssertEqual(ColorimetryOverride(storageID: s), .auto, String(describing: s))
        }
    }

    func testIdentifiersAreUnique() {
        let ids = ColorimetryOverride.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: Availability

    func testAvailabilityPerTransport() {
        // NDI: exactly today's list, in today's order — the picker and the ⌃⌥C cycle.
        XCTAssertEqual(ColorimetryOverride.available(on: .ndi),
                       [.auto, .rec709, .rec2020PQ, .rec2020HLG, .p3d65PQ, .rec2020SDR])
        // Rec.2020 SDR hidden until §7.3 is fixed (decision 3).
        for t in [ColorimetryTransport.srt, .whep, .hls] {
            XCTAssertEqual(ColorimetryOverride.available(on: t),
                           [.auto, .rec709, .rec2020PQ, .rec2020HLG, .p3d65PQ], "\(t)")
        }
        // Every transport offers Auto first, so a fresh connection's value is always selectable.
        for t in ColorimetryTransport.allCases {
            XCTAssertEqual(ColorimetryOverride.available(on: t).first, .auto)
        }
    }
}
