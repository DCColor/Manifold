//
//  CubeLUTEvaluatorTests.swift
//  LUTCubeTests
//
//  Colour S6, L0-P6 (docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, *S6 — LUT*): the CPU reference against the Python
//  generator's independent expected values (Fixtures/synthetic, written by scripts/lut/make_synthetic_luts.py),
//  the affine LUTs against their analytic functions, the trilinear/tetrahedral discriminator, the clamp (D2) and
//  the levels guard.
//

import XCTest
@testable import LUTCube

final class CubeLUTEvaluatorTests: XCTestCase {

    private struct Expected: Decodable {
        struct Probe: Decodable {
            let `in`: [Double]
            let trilinear: [Double]
            let tetrahedral: [Double]
            let analytic: [Double]?
        }
        struct Entry: Decodable { let name: String; let file: String; let affine: Bool; let probes: [Probe] }
        let luts: [Entry]
    }

    private func synthetic() throws -> (URL, Expected) {
        let dir = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/synthetic")
        let data = try Data(contentsOf: dir.appendingPathComponent("expected.json"))
        return (dir, try JSONDecoder().decode(Expected.self, from: data))
    }

    private func lut(_ name: String) throws -> CubeLUT {
        let (dir, _) = try synthetic()
        return try CubeLUT.load(contentsOf: dir.appendingPathComponent(name + ".cube"))
    }

    private static func v(_ a: [Double]) -> SIMD3<Double> { SIMD3(a[0], a[1], a[2]) }
    private static func maxAbs(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b; return max(Swift.abs(d.x), Swift.abs(d.y), Swift.abs(d.z))
    }

    // MARK: L0-P6 — against the generator, every LUT, both interpolations

    func testEverySyntheticLUTMatchesTheGenerator() throws {
        let (dir, expected) = try synthetic()
        XCTAssertEqual(expected.luts.count, 15)
        var worst = 0.0, worstAnalytic = 0.0, probes = 0
        for entry in expected.luts {
            let l = try CubeLUT.load(contentsOf: dir.appendingPathComponent(entry.file))
            XCTAssertEqual(entry.affine, entry.probes.first?.analytic != nil, entry.name)
            for p in entry.probes {
                let x = Self.v(p.in)
                for (mode, want) in [(CubeInterpolation.trilinear, p.trilinear), (.tetrahedral, p.tetrahedral)] {
                    let got = l.apply(x, interpolation: mode)
                    let d = Self.maxAbs(got, Self.v(want))
                    worst = max(worst, d)
                    XCTAssertLessThanOrEqual(d, 1e-6, "\(entry.name) \(mode) at \(p.in)")
                    // Affine: both interpolations reproduce the function exactly (to the table's float32).
                    if let a = p.analytic {
                        let da = Self.maxAbs(got, Self.v(a))
                        worstAnalytic = max(worstAnalytic, da)
                        XCTAssertLessThanOrEqual(da, 1e-6, "\(entry.name) \(mode) analytic at \(p.in)")
                    }
                }
                probes += 1
            }
        }
        print("[L0-P6] \(probes) probes × 2 modes: max |Swift − Python| = \(worst); affine max |Swift − analytic| = \(worstAnalytic)")
    }

    // MARK: L0-P6 — the discriminator

    /// r·g·b is multilinear, so trilinear reproduces it exactly; tetrahedral does not. At the cube's centre the
    /// two differ by 0.375 — what L1's P5 measures on the GPU.
    func testTheDiscriminatorSeparatesTheTwoModes() throws {
        let l = try lut("product_3d_2")
        let centre = SIMD3<Double>(repeating: 0.5)
        let tri = l.apply(centre, interpolation: .trilinear)
        let tet = l.apply(centre, interpolation: .tetrahedral)
        XCTAssertEqual(tri.x, 0.125, accuracy: 1e-9)
        XCTAssertEqual(tet.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(tet.x - tri.x, 0.375, accuracy: 1e-9)
        XCTAssertEqual(CubeInterpolation.default, .tetrahedral)   // D1
    }

    /// On the neutral axis tetrahedral uses only the two diagonal nodes (c000, c111), so it interpolates the
    /// greys linearly between them: for (r·g, g·b, b·r) on 9³ at 0.3, between 0.25 → 0.0625 and 0.375 → 0.140625,
    /// that is 0.09375. Trilinear is exact there (r·g is multilinear): 0.09. Off the axis the two differ.
    func testNeutralAxisAndOffAxis() throws {
        let l = try lut("cross_3d_9")
        let grey = SIMD3<Double>(repeating: 0.3)
        let off = SIMD3<Double>(0.31, 0.77, 0.12)
        XCTAssertEqual(Self.maxAbs(l.apply(grey, interpolation: .tetrahedral), SIMD3(repeating: 0.09375)), 0, accuracy: 1e-7)
        XCTAssertEqual(Self.maxAbs(l.apply(grey, interpolation: .trilinear), SIMD3(repeating: 0.09)), 0, accuracy: 1e-7)
        XCTAssertGreaterThan(Self.maxAbs(l.apply(off, interpolation: .trilinear),
                                         l.apply(off, interpolation: .tetrahedral)), 1e-5)
    }

    // MARK: D2 — the clamp

    func testInputOutsideTheDomainIsClamped() throws {
        let l = try lut("domain_identity_3d_5")   // identity on −0.25…1.25
        for mode in CubeInterpolation.allCases {
            XCTAssertEqual(Self.maxAbs(l.apply(SIMD3(-1, 0.5, 9), interpolation: mode), SIMD3(-0.25, 0.5, 1.25)), 0, accuracy: 1e-6)
            XCTAssertEqual(Self.maxAbs(l.apply(SIMD3(1.1, -0.2, 0.0), interpolation: mode), SIMD3(1.1, -0.2, 0.0)), 0, accuracy: 1e-6)
        }
        // A 0–1 identity clamps superwhite: why P2 excludes out-of-domain pixels.
        let unit = try lut("identity_3d_17")
        XCTAssertEqual(unit.apply(SIMD3(repeating: 1.000977)).x, 1, accuracy: 1e-7)
        XCTAssertEqual(unit.apply(SIMD3(repeating: -0.01)).x, 0, accuracy: 1e-7)
        // NaN in is not NaN out.
        XCTAssertFalse(unit.apply(SIMD3(.nan, 0.5, 0.5)).x.isNaN)
    }

    // MARK: The levels guard (L1's P4)

    func testLevelsGuardSeparatesTheCorrectDomainFromTheLiftedOne() throws {
        let l = try lut("levels_guard_1d_1024")
        XCTAssertEqual(l.apply(SIMD3(repeating: 0)).x, 0, "legal black, expanded: 64 → 0.0")
        XCTAssertEqual(l.apply(SIMD3(repeating: 64.0 / 1023.0)).x, 1, "the pitfall: legal black as code/1023")
        XCTAssertEqual(l.apply(SIMD3(repeating: 1)).x, 1)
    }

    // MARK: The shaper feeds the 3D

    func testShaperOutputIsTheCubeInput() throws {
        let l = try lut("shaper_log_3d_9")
        let s = try XCTUnwrap(l.shaper), c = try XCTUnwrap(l.cube)
        let x = SIMD3<Double>(0.18, -0.05, 1.1)
        for mode in CubeInterpolation.allCases {
            XCTAssertEqual(Self.maxAbs(l.apply(x, interpolation: mode), c.apply(s.apply(x), interpolation: mode)), 0)
        }
    }
}
