import Foundation

/// Pure numeric scope trace-build: histogram (`[UInt32]`) → RGBA pixel buffer (`[UInt8]`).
///
/// This target is compiled with `-O` EVEN IN DEBUG (see Package.swift). The downsample /
/// max-scan / RGBA-fill loops here are ~100× slower under `-Onone` (a Debug-build artifact —
/// benchmarked ~100ms vs <1ms), which made the scopes lag during development. Compiling just
/// these hot loops optimized keeps the scopes fast in Debug while the rest of the app stays
/// `-Onone`/debuggable; Release is unaffected (already `-O`).
///
/// Deliberately no SwiftUI / CoreGraphics / model state — the callers wrap the returned RGBA
/// buffer in a CGImage. The loops use plain, readable Array subscripts (no unsafe pointers):
/// under `-O` the bounds checks are elided and the loops vectorize, so raw pointers add
/// nothing but complexity.
public enum ScopeTrace {

    // Brightness-curve constants (moved here from the App scope code). gamma > 1 pushes low
    // counts toward black so sparse areas stay dark and dense bins build to full white — a
    // Resolve-style readable trace. floor clamps pure haze to black.
    static let gamma: Float = 1.25
    static let floor: Float = 0.008

    /// Map an accumulated bin count to 0–255 trace brightness with a gain + gamma curve.
    /// `gain` is the effective gain (baseGain × perScopeIntensity × globalScopeIntensity).
    @inline(__always)
    public static func brightness(count: UInt32, maxCount: UInt32, gain: Float) -> UInt8 {
        guard count > 0, maxCount > 0 else { return 0 }
        let normalized = Float(count) / Float(maxCount)
        var b = powf(min(normalized * gain, 1.0), gamma)
        if b < floor { b = 0 }
        return UInt8(min(255.0, b * 255.0))
    }

    /// count → brightness (0–255) lookup table: one `powf` per DISTINCT count instead of per
    /// pixel. Sized to maxCount+1 (always far smaller than the pixel count), direct-indexed by
    /// the bin count — exact, no quantization.
    private static func brightnessLUT(maxCount: UInt32, gain: Float) -> [UInt8] {
        let n = Int(maxCount) + 1
        var lut = [UInt8](repeating: 0, count: n)
        for c in 0..<n { lut[c] = brightness(count: UInt32(c), maxCount: maxCount, gain: gain) }
        return lut
    }

    /// Luma waveform. `accum` layout `[row*scopeW + bucket]` (luma-max at row 0). Downsamples
    /// `bins` rows → `displayRows` (summed, no dropped rows), scans the per-frame max, then
    /// fills an RGBA buffer of `scopeW × displayRows` tinted by the trace color.
    public static func waveformPixels(histogram accum: [UInt32], scopeW: Int, bins: Int,
                                      displayRows: Int, gain: Float,
                                      colorR: Float, colorG: Float, colorB: Float) -> [UInt8] {
        let dispCount = scopeW * displayRows
        let display: [UInt32]
        if displayRows == bins {
            display = accum
        } else {
            var d = [UInt32](repeating: 0, count: dispCount)
            for srow in 0..<bins {
                let dBase = ((srow * displayRows) / bins) * scopeW
                let sBase = srow * scopeW
                for x in 0..<scopeW { d[dBase + x] &+= accum[sBase + x] }
            }
            display = d
        }

        var maxCount: UInt32 = 1
        for c in display where c > maxCount { maxCount = c }
        let lut = brightnessLUT(maxCount: maxCount, gain: gain)

        var pixels = [UInt8](repeating: 0, count: dispCount * 4)
        for i in 0..<dispCount {
            let fv = Float(lut[Int(display[i])])
            let o = i * 4
            pixels[o + 0] = UInt8(min(255, fv * colorR))
            pixels[o + 1] = UInt8(min(255, fv * colorG))
            pixels[o + 2] = UInt8(min(255, fv * colorB))
            pixels[o + 3] = 255
        }
        return pixels
    }

    /// RGB parade. Three per-channel histograms (each `colW*bins`, layout `[row*colW+bucket]`)
    /// composited into one RGBA buffer of `3*colW × displayRows`: column 0 = R, 1 = G, 2 = B.
    /// A SHARED max across channels keeps inter-channel density comparable. `mono` paints all
    /// three columns in one hue (brightness still per-channel); otherwise red/green/blue.
    public static func paradePixels(r accR: [UInt32], g accG: [UInt32], b accB: [UInt32],
                                    colW: Int, bins: Int, displayRows: Int, gain: Float,
                                    mono: Bool, monoR: Float, monoG: Float, monoB: Float) -> [UInt8] {
        let dispN = colW * displayRows

        func mapDown(_ acc: [UInt32]) -> [UInt32] {
            if displayRows == bins { return acc }
            var d = [UInt32](repeating: 0, count: dispN)
            for srow in 0..<bins {
                let dBase = ((srow * displayRows) / bins) * colW
                let sBase = srow * colW
                for x in 0..<colW { d[dBase + x] &+= acc[sBase + x] }
            }
            return d
        }
        let dR = mapDown(accR), dG = mapDown(accG), dB = mapDown(accB)

        var maxCount: UInt32 = 1
        for c in dR where c > maxCount { maxCount = c }
        for c in dG where c > maxCount { maxCount = c }
        for c in dB where c > maxCount { maxCount = c }
        let lut = brightnessLUT(maxCount: maxCount, gain: gain)

        let totalW = colW * 3
        var pixels = [UInt8](repeating: 0, count: totalW * displayRows * 4)
        for row in 0..<displayRows {
            let rowOut = row * totalW
            let rowBase = row * colW
            for bx in 0..<colW {
                let idx = rowBase + bx
                let vR = Float(lut[Int(dR[idx])])
                let vG = Float(lut[Int(dG[idx])])
                let vB = Float(lut[Int(dB[idx])])
                let oR = (rowOut + (0 * colW + bx)) * 4   // R column (left)
                let oG = (rowOut + (1 * colW + bx)) * 4   // G column (mid)
                let oB = (rowOut + (2 * colW + bx)) * 4   // B column (right)
                if mono {
                    pixels[oR + 0] = UInt8(min(255, vR * monoR)); pixels[oR + 1] = UInt8(min(255, vR * monoG)); pixels[oR + 2] = UInt8(min(255, vR * monoB)); pixels[oR + 3] = 255
                    pixels[oG + 0] = UInt8(min(255, vG * monoR)); pixels[oG + 1] = UInt8(min(255, vG * monoG)); pixels[oG + 2] = UInt8(min(255, vG * monoB)); pixels[oG + 3] = 255
                    pixels[oB + 0] = UInt8(min(255, vB * monoR)); pixels[oB + 1] = UInt8(min(255, vB * monoG)); pixels[oB + 2] = UInt8(min(255, vB * monoB)); pixels[oB + 3] = 255
                } else {
                    pixels[oR + 0] = UInt8(vR); pixels[oR + 1] = 0; pixels[oR + 2] = 0; pixels[oR + 3] = 255
                    pixels[oG + 0] = 0; pixels[oG + 1] = UInt8(vG); pixels[oG + 2] = 0; pixels[oG + 3] = 255
                    pixels[oB + 0] = 0; pixels[oB + 1] = 0; pixels[oB + 2] = UInt8(vB); pixels[oB + 3] = 255
                }
            }
        }
        return pixels
    }

    /// Vectorscope. Square `plane × plane` 2-D chroma histogram (layout `[py*plane + px]`) →
    /// RGBA buffer (NO downsample — it isn't a value histogram). Per-frame max + LUT fill.
    public static func vectorscopePixels(histogram accum: [UInt32], plane: Int, gain: Float,
                                         colorR: Float, colorG: Float, colorB: Float) -> [UInt8] {
        let count = plane * plane
        var maxCount: UInt32 = 1
        for c in accum where c > maxCount { maxCount = c }
        let lut = brightnessLUT(maxCount: maxCount, gain: gain)

        var pixels = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count {
            let fv = Float(lut[Int(accum[i])])
            let o = i * 4
            pixels[o + 0] = UInt8(min(255, fv * colorR))
            pixels[o + 1] = UInt8(min(255, fv * colorG))
            pixels[o + 2] = UInt8(min(255, fv * colorB))
            pixels[o + 3] = 255
        }
        return pixels
    }

    /// CIE chromaticity scatter. planeW×planeH 2-D histogram (layout `[row*planeW + col]`, the
    /// vertical axis already flipped in the kernel) → RGBA buffer (NO downsample). Overlays
    /// (spectral locus + gamut triangles) are drawn by the view's graticule Canvas, not here.
    ///
    /// DEDICATED brightness (NOT the shared value-scope LUT): the CIE scatter is FAR sparser
    /// than the value scopes — a frame's distinct chromaticities are few bins with small counts,
    /// so a linear count→brightness map reads nearly black. Instead each populated bin gets a
    /// LOG-COMPRESSED brightness (log1p(count)/log1p(max)) so a single-pixel bin still lights up,
    /// times a hardcoded `gain`, with a gentle implicit floor (log of count≥1 is already > 0).
    /// Computed inline per POPULATED bin (sparse → cheap; no giant maxCount-sized LUT).
    ///
    /// POINT-DILATION: each populated bin is splatted as a small dot (radius `dilation`, a
    /// (2r+1)² square with a soft edge falloff) via a MAX-blend, so sparse scatters read as
    /// visible points instead of lone pixels. CIE-only — the other scopes' builds are untouched.
    public static func ciePixels(histogram accum: [UInt32], planeW: Int, planeH: Int,
                                 gain: Float, dilation: Int,
                                 colorR: Float, colorG: Float, colorB: Float) -> [UInt8] {
        let count = planeW * planeH
        guard accum.count >= count, count > 0 else { return [UInt8](repeating: 0, count: max(0, count) * 4) }

        var maxCount: UInt32 = 1
        for c in accum where c > maxCount { maxCount = c }
        let logMax = log1p(Float(maxCount))   // > 0 (maxCount ≥ 1)

        var pixels = [UInt8](repeating: 0, count: count * 4)
        let rad = max(0, dilation)

        for by in 0..<planeH {
            let rowBase = by * planeW
            for bx in 0..<planeW {
                let cnt = accum[rowBase + bx]
                if cnt == 0 { continue }
                // Log-compressed, gained brightness for this bin.
                var norm = (log1p(Float(cnt)) / logMax) * gain
                if norm > 1 { norm = 1 }
                let fv = norm * 255.0
                if fv <= 0 { continue }

                // Splat a soft dot (center bright, edges dimmer) with a MAX-blend.
                let y0 = max(0, by - rad), y1 = min(planeH - 1, by + rad)
                let x0 = max(0, bx - rad), x1 = min(planeW - 1, bx + rad)
                for yy in y0...y1 {
                    let dy = yy >= by ? yy - by : by - yy
                    let outRow = yy * planeW
                    for xx in x0...x1 {
                        let dx = xx >= bx ? xx - bx : bx - xx
                        let dist = dy > dx ? dy : dx
                        let falloff: Float = dist == 0 ? 1.0 : (dist == 1 ? 0.6 : 0.3)
                        let val = fv * falloff
                        let o = (outRow + xx) * 4
                        let nr = UInt8(min(255, val * colorR))
                        let ng = UInt8(min(255, val * colorG))
                        let nb = UInt8(min(255, val * colorB))
                        if nr > pixels[o + 0] { pixels[o + 0] = nr }
                        if ng > pixels[o + 1] { pixels[o + 1] = ng }
                        if nb > pixels[o + 2] { pixels[o + 2] = nb }
                        pixels[o + 3] = 255
                    }
                }
            }
        }
        return pixels
    }
}
