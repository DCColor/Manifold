import XCTest
import ScopeCompute

/// The YRGB parade's trace build (docs/SCOPES_095_PLAN.md §1.3, §1.6). At equal column counts its Y column is byte-equal to
/// the Y waveform's image and its R, G, B columns to the RGB parade's. Y is normalized on its own; R, G and B share a max.
///
/// The histograms themselves are the waveform and parade kernels' own (YRGB dispatches `waveformKernel` and
/// `paradeKernel` at `colW`, `MetalVideoRenderer.computeYRGBGPU`), which `swift test` cannot reach; these tests cover
/// everything after the histogram.
final class YRGBTraceTests: XCTestCase {

    private func histogram(_ n: Int, seed: UInt64, scale: UInt32 = 1) -> [UInt32] {
        var state = seed
        return (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = UInt32(truncatingIfNeeded: state >> 33) % 400
            return (r < 150 ? 0 : r - 150) &* scale   // about 3/8 empty
        }
    }

    private struct Case { let colW: Int; let displayRows: Int; let gain: Float }

    /// colW at the clamp ends and in between; displayRows 512 (the 1024 → 512 downsample the scope uses) and 1024 (the
    /// no-downsample branch); three gains.
    private let cases: [Case] = [
        Case(colW: 128, displayRows: 512, gain: 2), Case(colW: 192, displayRows: 1024, gain: 0.5),
        Case(colW: 512, displayRows: 512, gain: 6), Case(colW: 128, displayRows: 1024, gain: 6),
        Case(colW: 192, displayRows: 512, gain: 2),
    ]
    private let bins = 1024
    private let yColor: (Float, Float, Float) = (0.902, 0.902, 0.902)   // E6E6E6

    private func build(_ c: Case, y: [UInt32], r: [UInt32], g: [UInt32], b: [UInt32]) -> [UInt8] {
        ScopeTrace.yrgbPixels(y: y, r: r, g: g, b: b, colW: c.colW, bins: bins, displayRows: c.displayRows,
                              gain: c.gain, yColorR: yColor.0, yColorG: yColor.1, yColorB: yColor.2)
    }

    /// Column `col` (0 = Y … 3 = B) of a YRGB image, as rows of `colW` RGBA pixels.
    private func column(_ px: [UInt8], _ col: Int, colW: Int, rows: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(colW * rows * 4)
        for row in 0..<rows {
            let o = (row * colW * 4 + col * colW) * 4
            out.append(contentsOf: px[o..<(o + colW * 4)])
        }
        return out
    }

    /// The RGB parade's three columns of one row band, as a YRGB image would hold them.
    private func paradeColumns(_ px: [UInt8], colW: Int, rows: Int) -> [UInt8] {
        var out: [UInt8] = []
        for row in 0..<rows { out.append(contentsOf: px[(row * colW * 12)..<((row + 1) * colW * 12)]) }
        return out
    }

    private func rgbColumns(_ px: [UInt8], colW: Int, rows: Int) -> [UInt8] {
        var out: [UInt8] = []
        for row in 0..<rows {
            let o = row * colW * 16 + colW * 4
            out.append(contentsOf: px[o..<(o + colW * 12)])
        }
        return out
    }

    func testImageSize() {
        for c in cases {
            let n = c.colW * bins
            let px = build(c, y: histogram(n, seed: 1), r: histogram(n, seed: 2), g: histogram(n, seed: 3),
                           b: histogram(n, seed: 4))
            XCTAssertEqual(px.count, c.colW * 4 * c.displayRows * 4)
        }
    }

    /// Y column == the Y waveform at scopeW = colW, byte for byte.
    func testYColumnEqualsTheWaveform() {
        for (i, c) in cases.enumerated() {
            let n = c.colW * bins
            let y = histogram(n, seed: 10 + UInt64(i))
            let px = build(c, y: y, r: histogram(n, seed: 20), g: histogram(n, seed: 21), b: histogram(n, seed: 22))
            let wf = ScopeTrace.waveformPixels(histogram: y, scopeW: c.colW, bins: bins, displayRows: c.displayRows,
                                               gain: c.gain, colorR: yColor.0, colorG: yColor.1, colorB: yColor.2)
            XCTAssertEqual(column(px, 0, colW: c.colW, rows: c.displayRows), wf, "case \(i)")
        }
    }

    /// R, G, B columns == the RGB parade (color mode) at the same colW, byte for byte.
    func testRGBColumnsEqualTheParade() {
        for (i, c) in cases.enumerated() {
            let n = c.colW * bins
            let r = histogram(n, seed: 30 + UInt64(i)), g = histogram(n, seed: 40 + UInt64(i))
            let b = histogram(n, seed: 50 + UInt64(i))
            let px = build(c, y: histogram(n, seed: 60), r: r, g: g, b: b)
            let parade = ScopeTrace.paradePixels(r: r, g: g, b: b, colW: c.colW, bins: bins,
                                                 displayRows: c.displayRows, gain: c.gain,
                                                 mono: false, monoR: 1, monoG: 1, monoB: 1)
            XCTAssertEqual(rgbColumns(px, colW: c.colW, rows: c.displayRows),
                           paradeColumns(parade, colW: c.colW, rows: c.displayRows), "case \(i)")
        }
    }

    /// Y is normalized on its own: R, G, B ten times denser leave the Y column unchanged, and Y ten times denser leaves
    /// R, G, B unchanged.
    func testYAndRGBNormalizeIndependently() {
        let c = Case(colW: 128, displayRows: 512, gain: 2)
        let n = c.colW * bins
        let y = histogram(n, seed: 70), r = histogram(n, seed: 71), g = histogram(n, seed: 72)
        let b = histogram(n, seed: 73)
        let base = build(c, y: y, r: r, g: g, b: b)
        let denseRGB = build(c, y: y, r: histogram(n, seed: 71, scale: 10), g: histogram(n, seed: 72, scale: 10),
                             b: histogram(n, seed: 73, scale: 10))
        let denseY = build(c, y: histogram(n, seed: 70, scale: 10), r: r, g: g, b: b)
        XCTAssertEqual(column(base, 0, colW: c.colW, rows: c.displayRows),
                       column(denseRGB, 0, colW: c.colW, rows: c.displayRows))
        XCTAssertEqual(rgbColumns(base, colW: c.colW, rows: c.displayRows),
                       rgbColumns(denseY, colW: c.colW, rows: c.displayRows))
    }

    /// The Y column from the brightness curve directly (not through `waveformPixels`): Y's own max, the Y color, alpha the
    /// brightest channel. A change to how YRGB normalizes Y fails here even if both builds changed together.
    func testYColumnFromTheCurve() {
        let colW = 8, rows = 16
        let y = histogram(colW * rows, seed: 80)
        let r = histogram(colW * rows, seed: 81, scale: 50)   // far denser than Y: must not dim it
        let px = ScopeTrace.yrgbPixels(y: y, r: r, g: r, b: r, colW: colW, bins: rows, displayRows: rows, gain: 2,
                                       yColorR: yColor.0, yColorG: yColor.1, yColorB: yColor.2)
        let maxY = max(1, y.max() ?? 1)
        for row in 0..<rows {
            for x in 0..<colW {
                let fv = Float(ScopeTrace.brightness(count: y[row * colW + x], maxCount: maxY, gain: 2))
                let v = UInt8(min(255, fv * yColor.0))
                let o = (row * colW * 4 + x) * 4
                XCTAssertEqual(Array(px[o..<(o + 4)]), [v, v, v, v], "row \(row) x \(x)")
            }
        }
    }

    /// Mono (the RGB Parade's own setting, which YRGB follows): R, G, B == the parade's MONO image and Y == the waveform's
    /// image in the same mono color, byte for byte, so all four columns are one hue. Several mono colors, including one
    /// with a zero channel.
    func testMonoFollowsTheParade() {
        let monos: [(Float, Float, Float)] = [(1, 1, 1), (0.2, 1, 0.3), (1, 0.5, 0)]
        for (i, c) in cases.enumerated() {
            let m = monos[i % monos.count]
            let n = c.colW * bins
            let y = histogram(n, seed: 90 + UInt64(i)), r = histogram(n, seed: 91), g = histogram(n, seed: 92)
            let b = histogram(n, seed: 93)
            let px = ScopeTrace.yrgbPixels(y: y, r: r, g: g, b: b, colW: c.colW, bins: bins, displayRows: c.displayRows,
                                           gain: c.gain, yColorR: yColor.0, yColorG: yColor.1, yColorB: yColor.2,
                                           mono: true, monoR: m.0, monoG: m.1, monoB: m.2)
            let parade = ScopeTrace.paradePixels(r: r, g: g, b: b, colW: c.colW, bins: bins,
                                                 displayRows: c.displayRows, gain: c.gain,
                                                 mono: true, monoR: m.0, monoG: m.1, monoB: m.2)
            let wf = ScopeTrace.waveformPixels(histogram: y, scopeW: c.colW, bins: bins, displayRows: c.displayRows,
                                               gain: c.gain, colorR: m.0, colorG: m.1, colorB: m.2)
            XCTAssertEqual(rgbColumns(px, colW: c.colW, rows: c.displayRows),
                           paradeColumns(parade, colW: c.colW, rows: c.displayRows), "case \(i)")
            XCTAssertEqual(column(px, 0, colW: c.colW, rows: c.displayRows), wf, "case \(i)")
        }
    }

    /// `mono: false` (the default) is the color image, whatever mono color is passed: the parade's reset turns YRGB back
    /// to color without touching the stored mono color.
    func testMonoOffIgnoresTheMonoColor() {
        let c = cases[0]
        let n = c.colW * bins
        let y = histogram(n, seed: 100), r = histogram(n, seed: 101), g = histogram(n, seed: 102)
        let b = histogram(n, seed: 103)
        let color = build(c, y: y, r: r, g: g, b: b)
        let off = ScopeTrace.yrgbPixels(y: y, r: r, g: g, b: b, colW: c.colW, bins: bins, displayRows: c.displayRows,
                                        gain: c.gain, yColorR: yColor.0, yColorG: yColor.1, yColorB: yColor.2,
                                        mono: false, monoR: 0.2, monoG: 1, monoB: 0.3)
        XCTAssertEqual(off, color)
    }

    /// No signal: a fully transparent image of the right size.
    func testAllZeroIsTransparent() {
        let c = Case(colW: 128, displayRows: 512, gain: 2)
        let z = [UInt32](repeating: 0, count: c.colW * bins)
        let px = build(c, y: z, r: z, g: z, b: z)
        XCTAssertEqual(px.count, c.colW * 16 * c.displayRows)
        XCTAssertTrue(px.allSatisfy { $0 == 0 })
    }

    /// A size the caller should never pass returns nothing rather than trapping.
    func testDegenerateSizes() {
        XCTAssertEqual(ScopeTrace.yrgbPixels(y: [], r: [], g: [], b: [], colW: 0, bins: 1024, displayRows: 512,
                                             gain: 2, yColorR: 1, yColorG: 1, yColorB: 1), [])
    }
}
