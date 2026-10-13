//
//  CubeLUTEvaluator.swift
//  LUTCube
//
//  The CPU reference for applying a `CubeLUT` (docs/COLOR_MANAGEMENT_FINDINGS.md §6.11, *S6 — LUT*). It is the
//  CONTRACT the L1 shader is scored against, and `scripts/lut/make_synthetic_luts.py` computes the same thing
//  independently. In Double, from the Float table, so the reference carries no arithmetic error of its own.
//
//  Per table, per axis:
//    t = clamp((x − min) / (max − min), 0, 1)       D2: input outside the domain is clamped
//    p = t · (n − 1),  i = min(⌊p⌋, n − 2),  f = p − i
//
//  1D (a 1D LUT, or the shaper): per channel, linear between rows i and i+1 of that channel.
//  3D: trilinear (the eight corners) or tetrahedral (four, chosen by the order of fr, fg, fb, as FFmpeg's
//  `interp_tetrahedral` and the usual implementations do). Both are exact on an affine table; tetrahedral keeps
//  the neutral axis exact too. D1: both offered, tetrahedral the default.
//  Shaper + 3D: the shaper's output is the 3D table's input.
//

import Foundation

public enum CubeInterpolation: String, CaseIterable, Sendable {
    case trilinear, tetrahedral
    /// D1 (Robbie, 2026-10-13).
    public static let `default`: CubeInterpolation = .tetrahedral
}

extension CubeLUT {

    /// Apply the LUT to one R′G′B′ value.
    public func apply(_ rgb: SIMD3<Double>, interpolation: CubeInterpolation = .default) -> SIMD3<Double> {
        var v = rgb
        if let shaper { v = shaper.apply(v) }
        if let cube { v = cube.apply(v, interpolation: interpolation) }
        return v
    }
}

/// The lattice position of `x` on one axis of `size` nodes: the lower node and the fraction towards the next.
@inline(__always)
private func position(_ x: Double, min: Float, max: Float, size: Int) -> (i: Int, f: Double) {
    let lo = Double(min), hi = Double(max)
    var t = (x - lo) / (hi - lo)
    t = t.isNaN ? 0 : Swift.min(Swift.max(t, 0), 1)
    let p = t * Double(size - 1)
    let i = Swift.min(Int(p.rounded(.down)), size - 2)
    return (i, p - Double(i))
}

extension CubeTable1D {
    public func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        var out = SIMD3<Double>()
        for c in 0..<3 {
            let (i, f) = position(rgb[c], min: domain.min[c], max: domain.max[c], size: size)
            let a = Double(values[3 * i + c]), b = Double(values[3 * (i + 1) + c])
            out[c] = a + (b - a) * f
        }
        return out
    }
}

extension CubeTable3D {
    public func apply(_ rgb: SIMD3<Double>, interpolation: CubeInterpolation) -> SIMD3<Double> {
        let (r0, fr) = position(rgb.x, min: domain.min.x, max: domain.max.x, size: size)
        let (g0, fg) = position(rgb.y, min: domain.min.y, max: domain.max.y, size: size)
        let (b0, fb) = position(rgb.z, min: domain.min.z, max: domain.max.z, size: size)
        func c(_ dr: Int, _ dg: Int, _ db: Int) -> SIMD3<Double> {
            SIMD3<Double>(node(r: r0 + dr, g: g0 + dg, b: b0 + db))
        }
        switch interpolation {
        case .trilinear:
            let c00 = c(0, 0, 0) * (1 - fr) + c(1, 0, 0) * fr
            let c10 = c(0, 1, 0) * (1 - fr) + c(1, 1, 0) * fr
            let c01 = c(0, 0, 1) * (1 - fr) + c(1, 0, 1) * fr
            let c11 = c(0, 1, 1) * (1 - fr) + c(1, 1, 1) * fr
            let c0 = c00 * (1 - fg) + c10 * fg
            let c1 = c01 * (1 - fg) + c11 * fg
            return c0 * (1 - fb) + c1 * fb
        case .tetrahedral:
            let c000 = c(0, 0, 0), c111 = c(1, 1, 1)
            if fr > fg {
                if fg > fb {
                    return c000 * (1 - fr) + c(1, 0, 0) * (fr - fg) + c(1, 1, 0) * (fg - fb) + c111 * fb
                } else if fr > fb {
                    return c000 * (1 - fr) + c(1, 0, 0) * (fr - fb) + c(1, 0, 1) * (fb - fg) + c111 * fg
                } else {
                    return c000 * (1 - fb) + c(0, 0, 1) * (fb - fr) + c(1, 0, 1) * (fr - fg) + c111 * fg
                }
            } else {
                if fb > fg {
                    return c000 * (1 - fb) + c(0, 0, 1) * (fb - fg) + c(0, 1, 1) * (fg - fr) + c111 * fr
                } else if fb > fr {
                    return c000 * (1 - fg) + c(0, 1, 0) * (fg - fb) + c(0, 1, 1) * (fb - fr) + c111 * fr
                } else {
                    return c000 * (1 - fg) + c(0, 1, 0) * (fg - fr) + c(1, 1, 0) * (fr - fb) + c111 * fb
                }
            }
        }
    }
}
