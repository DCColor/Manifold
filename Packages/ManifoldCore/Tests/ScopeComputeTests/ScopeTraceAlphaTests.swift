import XCTest
import ScopeCompute

/// The trace images' alpha (docs/SCOPES_095_PLAN.md §2.4 A). Since 0.9.5 alpha is the pixel's brightest channel, so
/// empty trace is transparent and the graticule drawn under it shows through. The RGB bytes must be exactly what they
/// were: composited over black, the picture is unchanged. Expected RGB here is rebuilt from the public `brightness`
/// curve, the same formula the builds use, so a change to the RGB arithmetic fails these tests.
final class ScopeTraceAlphaTests: XCTestCase {

    /// A histogram with a spread of counts, including zeros. displayRows == bins so no downsample is involved.
    private func histogram(_ n: Int, seed: UInt64) -> [UInt32] {
        var state = seed
        return (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = UInt32(truncatingIfNeeded: state >> 33) % 400
            return r < 150 ? 0 : r - 150   // about 3/8 empty
        }
    }

    private func maxCount(_ h: [UInt32]...) -> UInt32 {
        max(1, h.flatMap { $0 }.max() ?? 1)
    }

    // MARK: Waveform

    func testWaveformAlphaIsTheBrightestChannelAndRGBIsUnchanged() {
        let w = 16, bins = 32
        let h = histogram(w * bins, seed: 1)
        let gain: Float = 2.0
        let color: (Float, Float, Float) = (0.2, 1.0, 0.4)
        let px = ScopeTrace.waveformPixels(histogram: h, scopeW: w, bins: bins, displayRows: bins, gain: gain,
                                           colorR: color.0, colorG: color.1, colorB: color.2)
        let m = maxCount(h)
        for i in 0..<(w * bins) {
            let fv = Float(ScopeTrace.brightness(count: h[i], maxCount: m, gain: gain))
            let r = UInt8(min(255, fv * color.0)), g = UInt8(min(255, fv * color.1)), b = UInt8(min(255, fv * color.2))
            XCTAssertEqual(px[i * 4 + 0], r, "R at \(i)")
            XCTAssertEqual(px[i * 4 + 1], g, "G at \(i)")
            XCTAssertEqual(px[i * 4 + 2], b, "B at \(i)")
            XCTAssertEqual(px[i * 4 + 3], max(r, g, b), "A at \(i)")
            if h[i] == 0 { XCTAssertEqual(px[i * 4 + 3], 0, "an empty bin is fully transparent") }
        }
    }

    func testWaveformChannelsNeverExceedAlpha() {
        // The image is premultiplied: every channel must be ≤ alpha.
        let h = histogram(64 * 64, seed: 7)
        let px = ScopeTrace.waveformPixels(histogram: h, scopeW: 64, bins: 64, displayRows: 32, gain: 6,
                                           colorR: 1, colorG: 1, colorB: 1)
        for i in stride(from: 0, to: px.count, by: 4) {
            XCTAssertLessThanOrEqual(max(px[i], px[i + 1], px[i + 2]), px[i + 3])
        }
    }

    // MARK: Parade

    func testParadeColorColumnsTakeTheirOwnChannelAsAlpha() {
        let colW = 8, bins = 16
        let r = histogram(colW * bins, seed: 2), g = histogram(colW * bins, seed: 3), b = histogram(colW * bins, seed: 4)
        let gain: Float = 2.0
        let px = ScopeTrace.paradePixels(r: r, g: g, b: b, colW: colW, bins: bins, displayRows: bins, gain: gain,
                                         mono: false, monoR: 1, monoG: 1, monoB: 1)
        let m = maxCount(r, g, b)   // shared across channels
        let totalW = colW * 3
        for row in 0..<bins {
            for bx in 0..<colW {
                let idx = row * colW + bx
                for (c, hist) in [r, g, b].enumerated() {
                    let v = ScopeTrace.brightness(count: hist[idx], maxCount: m, gain: gain)
                    let o = (row * totalW + c * colW + bx) * 4
                    for ch in 0..<3 { XCTAssertEqual(px[o + ch], ch == c ? v : 0) }
                    XCTAssertEqual(px[o + 3], v, "alpha of column \(c)")
                }
            }
        }
    }

    func testParadeMonoAlphaIsTheBrightestChannel() {
        let colW = 8, bins = 16
        let r = histogram(colW * bins, seed: 5), g = histogram(colW * bins, seed: 6), b = histogram(colW * bins, seed: 8)
        let mono: (Float, Float, Float) = (1.0, 0.6, 0.1)
        let px = ScopeTrace.paradePixels(r: r, g: g, b: b, colW: colW, bins: bins, displayRows: bins, gain: 2,
                                         mono: true, monoR: mono.0, monoG: mono.1, monoB: mono.2)
        let m = maxCount(r, g, b)
        let totalW = colW * 3
        for row in 0..<bins {
            for bx in 0..<colW {
                let idx = row * colW + bx
                for (c, hist) in [r, g, b].enumerated() {
                    let fv = Float(ScopeTrace.brightness(count: hist[idx], maxCount: m, gain: 2))
                    let exp = [UInt8(min(255, fv * mono.0)), UInt8(min(255, fv * mono.1)), UInt8(min(255, fv * mono.2))]
                    let o = (row * totalW + c * colW + bx) * 4
                    XCTAssertEqual(Array(px[o..<(o + 3)]), exp)
                    XCTAssertEqual(px[o + 3], exp.max()!)
                }
            }
        }
    }

    // MARK: Sparse scatter (vectorscope and CIE)

    func testVectorscopeAlphaIsTheBrightestChannelAndEmptyIsTransparent() {
        let plane = 24
        var h = [UInt32](repeating: 0, count: plane * plane)
        h[5 * plane + 5] = 1        // a lone, faint bin
        h[12 * plane + 12] = 5000   // the central pile
        h[12 * plane + 13] = 40
        let px = ScopeTrace.vectorscopePixels(histogram: h, plane: plane, gain: 2,
                                              colorR: 1.0, colorG: 0.8, colorB: 0.5)
        var touched = 0
        for i in 0..<(plane * plane) {
            let o = i * 4
            let brightest = max(px[o], px[o + 1], px[o + 2])
            XCTAssertEqual(px[o + 3], brightest, "alpha at \(i)")
            if brightest > 0 { touched += 1 }
        }
        XCTAssertGreaterThan(touched, 3, "the dilation still blooms single bins")
        XCTAssertEqual(px[0 * 4 + 3], 0, "a far corner is untouched and transparent")
    }

    func testCIEUsesTheSameAlphaRule() {
        let w = 20, hgt = 10
        var h = [UInt32](repeating: 0, count: w * hgt)
        h[3 * w + 4] = 9
        h[6 * w + 15] = 900
        let px = ScopeTrace.ciePixels(histogram: h, planeW: w, planeH: hgt, gain: 6.25, dilation: 1,
                                      colorR: 1, colorG: 1, colorB: 1)
        for i in stride(from: 0, to: px.count, by: 4) {
            XCTAssertEqual(px[i + 3], max(px[i], px[i + 1], px[i + 2]))
        }
    }
}
