//
//  OutputSignalTests.swift
//  ColorimetryModelTests
//
//  Colour S7 (docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, *S7*): what the DeckLink output signals per frame.
//  P1 — the colorimetry and EOTF table over every pair. P2 — the signal colorimetry and the mastering primaries are
//  independent, and D4's conversion applies to a P3 TAG only (the clarification's pair). The reference values were
//  computed by a separate Python model (its own RP 177 and Bradford), not by this module.
//

import XCTest
@testable import ColorimetryModel

final class OutputSignalTests: XCTestCase {

    private let primariesCodes: [Int?] = [1, 5, 6, 9, 11, 12, 2, nil]
    private let transferCodes: [Int?] = [1, 6, 13, 14, 15, 16, 18, 2, nil]

    /// P1: every pair gives the colorimetry the bridge's pre-S7 table gave (9, 11, 12 → 2020, else 709) and the
    /// EOTF of its transfer (16 → PQ 2, 18 → HLG 3, else SDR 0).
    func testEveryPairGivesItsColorimetryAndEOTF() {
        var mismatches: [String] = []
        for p in primariesCodes {
            for t in transferCodes {
                let s = OutputSignal.resolve(picturePrimaries: p, pictureTransfer: t, source: nil)
                let wantC: OutputColorimetry = [9, 11, 12].contains(p) ? .rec2020 : .rec709
                let wantE: Int = t == 16 ? 2 : (t == 18 ? 3 : 0)
                if s.colorimetry != wantC || s.eotf.rawValue != wantE {
                    mismatches.append("\(String(describing: p))-\(String(describing: t)): \(s.colorimetry) \(s.eotf)")
                }
                // D3: static metadata on PQ only.
                if (s.staticMetadata != nil) != (t == 16) { mismatches.append("\(String(describing: p))-\(String(describing: t)) metadata") }
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// The CTA-861.3 numbers the SDK's EOTF key takes.
    func testEOTFCodes() {
        XCTAssertEqual(OutputEOTF.sdr.rawValue, 0)
        XCTAssertEqual(OutputEOTF.pq.rawValue, 2)
        XCTAssertEqual(OutputEOTF.hlg.rawValue, 3)
    }

    /// P4's model half: PQ with nothing stated sends the D10 defaults, and MaxCLL / MaxFALL 0 (D2, never invented).
    func testPQWithNoMetadataSendsTheDefaults() {
        let s = OutputSignal.resolve(picturePrimaries: 9, pictureTransfer: 16, source: nil)
        let m = try! XCTUnwrap(s.staticMetadata)
        XCTAssertEqual(m.mastering.red, Chromaticity(0.680, 0.320))
        XCTAssertEqual(m.mastering.green, Chromaticity(0.265, 0.690))
        XCTAssertEqual(m.mastering.blue, Chromaticity(0.150, 0.060))
        XCTAssertEqual(m.mastering.white, Chromaticity(0.3127, 0.3290))
        XCTAssertEqual(m.mastering.maxLuminance, 1000)
        XCTAssertEqual(m.mastering.minLuminance, 0.005)
        XCTAssertEqual(m.maxCLL, 0)
        XCTAssertEqual(m.maxFALL, 0)
        XCTAssertTrue(m.primariesDefaulted)
        XCTAssertTrue(m.luminanceDefaulted)
        XCTAssertEqual(s.staticMetadataLabel,
                       "mastering P3 D65 · 1000 / 0.0050 cd/m² (defaults) · MaxCLL 0 · MaxFALL 0 (0 = unknown)")
    }

    /// The source's values are sent as stated, and a half it leaves out takes the default for that half only.
    func testStatedMetadataIsSentAsStated() {
        let p2020 = ColorPrimaries.rec2020.published
        let src = SourceHDRMetadata(primaries: MasteringPrimaries(red: p2020.red, green: p2020.green, blue: p2020.blue,
                                                                  white: p2020.white),
                                    maxLuminance: 4000, minLuminance: 0.0001, maxCLL: 800, maxFALL: 400)
        let m = try! XCTUnwrap(OutputSignal.resolve(picturePrimaries: 9, pictureTransfer: 16, source: src).staticMetadata)
        XCTAssertEqual(m.mastering.red, p2020.red)
        XCTAssertEqual(m.mastering.maxLuminance, 4000)
        XCTAssertEqual(m.mastering.minLuminance, 0.0001)
        XCTAssertEqual(m.maxCLL, 800)
        XCTAssertEqual(m.maxFALL, 400)
        XCTAssertFalse(m.primariesDefaulted || m.luminanceDefaulted)

        let half = SourceHDRMetadata(maxLuminance: 4000, minLuminance: 0.0001)
        let h = try! XCTUnwrap(OutputSignal.resolve(picturePrimaries: 9, pictureTransfer: 16, source: half).staticMetadata)
        XCTAssertTrue(h.primariesDefaulted)
        XCTAssertFalse(h.luminanceDefaulted)
        XCTAssertEqual(h.mastering.red, Chromaticity(0.680, 0.320))
        XCTAssertEqual(h.mastering.maxLuminance, 4000)
    }

    /// D3: HLG and SDR send no static metadata, whatever the source states.
    func testHLGAndSDRCarryNoStaticMetadata() {
        let src = SourceHDRMetadata(maxLuminance: 1000, minLuminance: 0.005, maxCLL: 800, maxFALL: 400)
        XCTAssertNil(OutputSignal.resolve(picturePrimaries: 9, pictureTransfer: 18, source: src).staticMetadata)
        XCTAssertNil(OutputSignal.resolve(picturePrimaries: 9, pictureTransfer: 14, source: src).staticMetadata)
    }

    // MARK: P2 — two fields, never derived from each other

    /// A 2020 signal carries P3 mastering primaries; the mastering primaries never move the signal.
    func testSignalColorimetryAndMasteringPrimariesAreIndependent() {
        let p3 = ColorPrimaries.p3D65.published
        let p3Mastering = SourceHDRMetadata(primaries: MasteringPrimaries(red: p3.red, green: p3.green, blue: p3.blue,
                                                                          white: p3.white),
                                            maxLuminance: 1000, minLuminance: 0.005)
        let p2020 = ColorPrimaries.rec2020.published
        let r2020Mastering = SourceHDRMetadata(primaries: MasteringPrimaries(red: p2020.red, green: p2020.green,
                                                                             blue: p2020.blue, white: p2020.white),
                                               maxLuminance: 1000, minLuminance: 0.005)
        let a = OutputSignal.resolve(picturePrimaries: 9, pictureTransfer: 16, source: p3Mastering)
        XCTAssertEqual(a.colorimetry, .rec2020)
        XCTAssertEqual(a.staticMetadata?.mastering.red, p3.red)
        // The same source with 2020 mastering: the signal does not move.
        let b = OutputSignal.resolve(picturePrimaries: 9, pictureTransfer: 16, source: r2020Mastering)
        XCTAssertEqual(b.colorimetry, a.colorimetry)
        XCTAssertEqual(b.primariesConversion, a.primariesConversion)
        // A 709 picture with P3 mastering metadata stays a 709 signal.
        XCTAssertEqual(OutputSignal.resolve(picturePrimaries: 1, pictureTransfer: 16, source: p3Mastering).colorimetry,
                       .rec709)
        // A P3-D65 picture's default mastering primaries are P3 because they are the default, not because of the tag:
        // a 709 picture gets the same default.
        XCTAssertEqual(OutputSignal.resolve(picturePrimaries: 1, pictureTransfer: 16, source: nil).staticMetadata?.mastering,
                       OutputSignal.resolve(picturePrimaries: 12, pictureTransfer: 16, source: nil).staticMetadata?.mastering)
    }

    // MARK: P2 — the clarification's pair (Robbie, 2026-10-22): D4 converts a P3 TAG only

    /// Tagged Rec.2020, content limited to P3, P3 mastering metadata: no conversion. The pixel goes out as it is.
    func testRec2020TaggedP3LimitedContentPassesThroughUntouched() {
        let p3 = ColorPrimaries.p3D65.published
        let src = SourceHDRMetadata(primaries: MasteringPrimaries(red: p3.red, green: p3.green, blue: p3.blue,
                                                                  white: p3.white),
                                    maxLuminance: 1000, minLuminance: 0.005, maxCLL: 800, maxFALL: 400)
        let s = OutputSignal.resolve(picturePrimaries: 9, pictureTransfer: 16, source: src)
        XCTAssertNil(s.primariesConversion)
        XCTAssertEqual(s.colorimetry, .rec2020)
        XCTAssertEqual(s.colorimetryLabel, "Rec. 2020")
        XCTAssertEqual(s.staticMetadata?.mastering.green, p3.green)
        XCTAssertNil(SDIPrimariesConversion(picturePrimaries: 9, pictureTransfer: 16))
    }

    /// Tagged P3-D65 (12) and DCI-P3 (11): converted, and signalled 2020. P3 red goes to the 2020 value.
    func testP3TaggedSourcesAreConvertedToRec2020() throws {
        let d65 = try XCTUnwrap(OutputSignal.resolve(picturePrimaries: 12, pictureTransfer: 16, source: nil).primariesConversion)
        XCTAssertEqual(d65.from, .p3D65)
        XCTAssertEqual(d65.curve, .pq)
        let dci = try XCTUnwrap(OutputSignal.resolve(picturePrimaries: 11, pictureTransfer: 1, source: nil).primariesConversion)
        XCTAssertEqual(dci.from, .dciP3)
        XCTAssertEqual(dci.curve, .power24)
        XCTAssertEqual(OutputSignal.resolve(picturePrimaries: 12, pictureTransfer: 16, source: nil).colorimetryLabel,
                       "Rec. 2020 (converted from P3 D65)")

        // The Python model's values.
        let refD65: ColorMatrix3 = [[0.7538330343617216, 0.1985973690526164, 0.04756959658566186],
                                    [0.045743848965358214, 0.9417772198116937, 0.012478931222948113],
                                    [-0.0012103403545183939, 0.017601717301089982, 0.9836086230534284]]
        let refDCI: ColorMatrix3 = [[0.7117832306885641, 0.24366031693026807, 0.044556452381167955],
                                    [0.04161516364649372, 0.9498416296589852, 0.008543206694521108],
                                    [-0.0008447283635060429, 0.019109507175969143, 0.9817352211875369]]
        for r in 0..<3 { for c in 0..<3 {
            XCTAssertEqual(d65.matrix[r][c], refD65[r][c], accuracy: 1e-4)
            XCTAssertEqual(dci.matrix[r][c], refDCI[r][c], accuracy: 1e-4)
        } }
        assertClose(d65.apply([0.5, 0, 0]), [0.47208486820077217, 0.23602773306987898, 7.309559025783966e-07])
        let g24 = try XCTUnwrap(SDIPrimariesConversion(picturePrimaries: 12, pictureTransfer: 1))
        assertClose(g24.apply([1, 0, 0]), [0.8889240415251238, 0.27657014244098105, -0.06088983501540172])
        assertClose(g24.apply([0.2, 0.6, 0.9]), [0.40024042217291067, 0.5944830135382043, 0.8963248601679811])
        assertClose(dci.apply([1, 0, 0]), [0.8679170698774057, 0.2658815301594478, -0.05241618983820396])
        // Neutral stays neutral (both whites are D65 once rendered).
        assertClose(g24.apply([0.7, 0.7, 0.7]), [0.7, 0.7, 0.7])
    }

    /// S7 follow-up 1: a converted (P3-tagged) picture is encoded with the 2020 matrix, whatever its own matrix
    /// code; every other picture keeps its own, a 2020-tagged one included.
    func testConvertedPicturesUseThe2020Matrix() {
        for (p, t, m) in [(12, 1, 1), (12, 16, 1), (11, 1, 1), (12, 1, 6), (11, 16, 9)] {
            let s = OutputSignal.resolve(picturePrimaries: p, pictureTransfer: t, source: nil)
            XCTAssertEqual(s.sdiMatrixCode(pictureMatrix: m), 9, "\(p)-\(t)-\(m)")
        }
        for (p, t, m): (Int?, Int?, Int?) in [(9, 16, 9), (9, 1, 9), (9, 16, 1), (1, 1, 1), (6, 6, 6), (5, 6, 5), (nil, nil, nil)] {
            let s = OutputSignal.resolve(picturePrimaries: p, pictureTransfer: t, source: nil)
            XCTAssertEqual(s.sdiMatrixCode(pictureMatrix: m), m, "\(String(describing: p))-\(String(describing: m))")
        }
    }

    /// Only 11 and 12 convert.
    func testOnlyP3PrimariesConvert() {
        for p in primariesCodes {
            let converts = SDIPrimariesConversion(picturePrimaries: p, pictureTransfer: 1) != nil
            XCTAssertEqual(converts, p == 11 || p == 12, "primaries \(String(describing: p))")
        }
    }

    /// Each curve's encode undoes its linearise (the round trip the shader relies on). PQ's inverse at 0 is
    /// c1^m2 = 7.3e-7, not 0 (ST 2084's own constants): a thousandth of a 10-bit code, hence its tolerance.
    func testCurvesRoundTrip() {
        for curve in [ScopeCurve.power24, .srgb, .pq, .hlg] {
            for e in stride(from: 0.0, through: 1.0, by: 0.05) {
                let back = SDIPrimariesConversion.encode(SDIPrimariesConversion.linearize(e, curve), curve)
                XCTAssertEqual(back, e, accuracy: curve == .pq ? 1e-6 : 1e-9, "\(curve) \(e)")
            }
        }
        // Power curves keep the sign, so sub-black survives.
        XCTAssertEqual(SDIPrimariesConversion.encode(SDIPrimariesConversion.linearize(-0.1, .power24), .power24), -0.1,
                       accuracy: 1e-12)
    }

    private func assertClose(_ a: [Double], _ b: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-6, file: file, line: line) }
    }
}
