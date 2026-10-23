//
//  SDIOutputMode.swift
//  ColorimetryModel
//
//  SDI scaling (COLOR_MANAGEMENT_FINDINGS.md §6.11, *SDI scaling*; BUGS.md, "any source raster that matches no output
//  mode carries BLACK"): which DeckLink output mode a source goes out at, where its picture sits in that mode, and the
//  resampling taps when it has to be scaled. Pure arithmetic, so the selector is tested against the whole mode table
//  and the renderer, the service and the tests all use the same rules.
//
//  The rules (Robbie, 2026-10-23, D1–D9):
//    • D1 the rate is never changed: the mode is at the source's (snapped) rate.
//    • D2 a source whose raster IS a mode of the active set goes out at it, 1:1.
//    • D3 otherwise the smallest mode (by area) that holds the picture unscaled; if none does, the largest mode
//      (2160p, or 4K DCI with DCI included, whichever needs less scaling; a tie goes to 2160p), fitted.
//    • D4 scaled only when it does not fit; D9 placed on the v210 6-pixel group.
//  8K is out of scope: no 4320p or 8K DCI mode is in the table.
//

import Foundation

/// Which modes Follow source may choose (Settings ▸ DeckLink Output). Default HD/UHD only.
public enum SDIOutputModeSet: String, CaseIterable, Sendable {
    case hdUHD = "hdUHD"
    case includeDCI = "includeDCI"

    public static let defaultsKey = "manifold.decklink.outputModeSet"
    public static let `default`: SDIOutputModeSet = .hdUHD

    /// The stored value, or the default when absent or unrecognised.
    public static func stored(_ raw: String?) -> SDIOutputModeSet { raw.flatMap(Self.init(rawValue:)) ?? .default }

    public var label: String { self == .hdUHD ? "HD/UHD only" : "Include DCI" }
}

/// A raster the card can output (8K excluded). The raw value is the label's family part.
public enum SDIModeFamily: String, CaseIterable, Sendable {
    case p720 = "720p"
    case p1080 = "1080p"
    case dci2K = "2K DCI p"
    case p2160 = "2160p"
    case dci4K = "4K DCI p"

    public var width: Int {
        switch self {
        case .p720: return 1280
        case .p1080: return 1920
        case .dci2K: return 2048
        case .p2160: return 3840
        case .dci4K: return 4096
        }
    }
    public var height: Int {
        switch self {
        case .p720: return 720
        case .p1080, .dci2K: return 1080
        case .p2160, .dci4K: return 2160
        }
    }
    public var isDCI: Bool { self == .dci2K || self == .dci4K }

    public func isAvailable(in set: SDIOutputModeSet) -> Bool { !isDCI || set == .includeDCI }

    /// The rates of the eight standard ones the card offers this raster at (SDK probe, 2026-10-23: 720p only at 50,
    /// 59.94 and 60; the others at all eight).
    public func offers(_ rate: SDIStandardRate) -> Bool {
        self != .p720 || rate.token == "50" || rate.token == "59.94" || rate.token == "60"
    }
}

/// One of the eight standard broadcast rates, as an exact fps and the label's token.
public struct SDIStandardRate: Equatable, Sendable {
    public let fps: Double
    public let token: String

    /// The rates Follow source snaps to, in order (the pre-existing D4a table, unchanged).
    public static let all: [SDIStandardRate] = [
        SDIStandardRate(fps: 24000.0 / 1001.0, token: "23.98"),
        SDIStandardRate(fps: 24.0, token: "24"),
        SDIStandardRate(fps: 25.0, token: "25"),
        SDIStandardRate(fps: 30000.0 / 1001.0, token: "29.97"),
        SDIStandardRate(fps: 30.0, token: "30"),
        SDIStandardRate(fps: 50.0, token: "50"),
        SDIStandardRate(fps: 60000.0 / 1001.0, token: "59.94"),
        SDIStandardRate(fps: 60.0, token: "60"),
    ]

    /// Nearest by |Δfps|; an unknown rate (≤ 0) is 23.98, as before.
    public static func nearest(to fps: Double) -> SDIStandardRate {
        guard fps > 0 else { return all[0] }
        return all.min(by: { abs(fps - $0.fps) < abs(fps - $1.fps) })!
    }
}

/// An output mode: a raster and a rate.
public struct SDIOutputMode: Equatable, Sendable {
    public let family: SDIModeFamily
    public let rate: SDIStandardRate

    public init(family: SDIModeFamily, rate: SDIStandardRate) { self.family = family; self.rate = rate }

    public var width: Int { family.width }
    public var height: Int { family.height }
    /// "1080p23.98", "720p59.94", "2K DCI p23.98". The bridge names an established mode the same way.
    public var label: String { family.rawValue + rate.token }

    /// Every mode in scope: each family at each rate the card offers it.
    public static let table: [SDIOutputMode] = SDIModeFamily.allCases.flatMap { f in
        SDIStandardRate.all.filter { f.offers($0) }.map { SDIOutputMode(family: f, rate: $0) }
    }
}

public enum SDIOutputModeSelector {
    /// THE one function: the mode a source goes out at under Follow source (D1–D3).
    /// `pixelAspect` is the declared h/v ratio, nil when undeclared (square assumed, D6).
    public static func select(width: Int, height: Int, pixelAspect: Double?, frameRate: Double,
                              set: SDIOutputModeSet) -> SDIOutputMode {
        let rate = SDIStandardRate.nearest(to: frameRate)
        let modes = SDIOutputMode.table.filter { $0.rate == rate && $0.family.isAvailable(in: set) }
        let par = SDIPlacement.effectiveAspect(pixelAspect)
        // D2: the raster is a mode, square pixels → that mode, native.
        if par == 1, let native = modes.first(where: { $0.width == width && $0.height == height }) { return native }
        // D3: the smallest that holds the picture's display size unscaled.
        let dw = Double(width) * par, dh = Double(height)
        let holding = modes.filter { Double($0.width) >= dw && Double($0.height) >= dh }
        if let smallest = holding.min(by: { $0.width * $0.height < $1.width * $1.height }) { return smallest }
        // Too big for every mode: the largest, whichever scales least; the first listed (2160p) wins a tie.
        let largest = modes.filter { $0.height == 2160 }
        func scale(_ m: SDIOutputMode) -> Double { min(Double(m.width) / dw, Double(m.height) / dh) }
        return largest.reduce(largest[0]) { best, m in scale(m) > scale(best) ? m : best }
    }
}

/// Where a source's picture sits in an output mode (D3, D4, D9).
public struct SDIPlacement: Equatable, Sendable {
    public enum Kind: String, Sendable { case native, letterbox, pillarbox, windowbox, fill }

    public let sourceWidth: Int, sourceHeight: Int
    public let outputWidth: Int, outputHeight: Int
    /// The picture's rectangle in the output.
    public let x: Int, y: Int, width: Int, height: Int
    /// The display scale (1 when the picture fits); the picture's size over the source's DISPLAY size.
    public let scale: Double
    /// The pixel aspect applied (1 when undeclared or square).
    public let pixelAspect: Double
    /// Whether the pixel aspect was declared (D6: undeclared is assumed square, and the log says so).
    public let pixelAspectDeclared: Bool

    /// The picture's pixels map 1:1 onto the output's: no resampling, only placement.
    public var isUnscaled: Bool { width == sourceWidth && height == sourceHeight }
    /// The source IS the mode: the pre-existing kernel runs, untouched.
    public var isNative: Bool { isUnscaled && x == 0 && y == 0 && width == outputWidth && height == outputHeight }

    public var kind: Kind {
        if isNative { return .native }
        let bars = (width < outputWidth, height < outputHeight)
        switch bars {
        case (true, true): return .windowbox
        case (true, false): return .pillarbox
        case (false, true): return .letterbox
        case (false, false): return .fill
        }
    }

    /// Undeclared or non-positive → 1 (square, D6).
    public static func effectiveAspect(_ pixelAspect: Double?) -> Double {
        guard let p = pixelAspect, p.isFinite, p > 0 else { return 1 }
        return p
    }

    /// The nearest multiple of 6 to `centre`, ties to the smaller (D9).
    static func nearestMultipleOf6(_ centre: Double) -> Int {
        let lo = Int((centre / 6).rounded(.down)) * 6
        return (centre - Double(lo) <= Double(lo + 6) - centre) ? lo : lo + 6
    }

    /// Fit a source into an output raster. Unscaled when its display size fits (D4); otherwise scaled down, aspect kept,
    /// never cropped. x on the 6-pixel group nearest the centre (ties to the smaller); y centred, the odd row to the
    /// bottom bar; a scaled width rounded to even, a scaled height to the nearest row.
    public static func fit(sourceWidth: Int, sourceHeight: Int, pixelAspect: Double?,
                           outputWidth: Int, outputHeight: Int) -> SDIPlacement {
        let par = effectiveAspect(pixelAspect)
        let dw = Double(sourceWidth) * par, dh = Double(sourceHeight)
        let fits = dw <= Double(outputWidth) && dh <= Double(outputHeight)
        let s = fits ? 1.0 : min(Double(outputWidth) / dw, Double(outputHeight) / dh)
        var w: Int, h: Int
        if fits && par == 1 {
            (w, h) = (sourceWidth, sourceHeight)
        } else {
            w = min(outputWidth, Int((dw * s / 2).rounded(.toNearestOrAwayFromZero)) * 2)
            h = min(outputHeight, Int((dh * s).rounded(.toNearestOrAwayFromZero)))
            w = max(w, 2); h = max(h, 1)
        }
        let x = nearestMultipleOf6(Double(outputWidth - w) / 2)
        let y = (outputHeight - h) / 2
        return SDIPlacement(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                            outputWidth: outputWidth, outputHeight: outputHeight,
                            x: x, y: y, width: w, height: h, scale: s, pixelAspect: par,
                            pixelAspectDeclared: pixelAspect != nil)
    }

    /// D8, the readout's half after the mode: "source 1280×720 1:1, windowboxed", "source 4096×2160 scaled ×0.9375,
    /// letterboxed", "native". Never silent about a picture that is not 1:1.
    public var summary: String {
        if isNative { return "source \(sourceWidth)×\(sourceHeight) native" }
        var s = "source \(sourceWidth)×\(sourceHeight)"
        if pixelAspect != 1 { s += " (pixel aspect \(Self.number(pixelAspect)))" }
        if isUnscaled { s += " 1:1" }
        else if pixelAspect != 1 && scale == 1 { s += " desqueezed to \(width)×\(height)" }
        else { s += " scaled ×\(Self.number(scale)) to \(width)×\(height)" }
        switch kind {
        case .letterbox: s += ", letterboxed"
        case .pillarbox: s += ", pillarboxed"
        case .windowbox: s += ", windowboxed"
        case .fill, .native: break
        }
        return s
    }

    static func number(_ v: Double) -> String {
        var t = String(format: "%.4f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}

/// One axis of a separable Lanczos-3 resample (D4): for each output sample, `tapsPerOutput` source indices and their
/// normalised weights (zero-padded). Computed in double, stored as float32 for the GPU.
///
/// Output sample `i` sits at picture position `i × stride` (stride 2 for 4:2:2 chroma, which is co-sited with the even
/// pixels), and maps to source position `u = (p + 0.5) × src / dst − 0.5`. The kernel is stretched by
/// `max(1, stride × src / dst)`, so a reduction is band-limited to the output's own Nyquist (luma) or half of it
/// (chroma). Indices past an edge are MIRRORED about the edge pixel (−1 → 1, n → n − 2), as the 4:4:4 halfband does.
public struct SDIResampleTaps: Equatable, Sendable {
    public let outputCount: Int
    public let tapsPerOutput: Int
    public let indices: [Int32]
    public let weights: [Float]

    public static func lanczos3(sourceLength: Int, pictureLength: Int, stride: Int = 1) -> SDIResampleTaps {
        let ratio = Double(sourceLength) / Double(pictureLength)
        let f = max(1.0, Double(stride) * ratio)
        let radius = 3.0 * f
        let count = (pictureLength + stride - 1) / stride
        let n = 2 * Int(radius.rounded(.up)) + 1
        var idx = [Int32](repeating: 0, count: count * n)
        var wts = [Float](repeating: 0, count: count * n)
        for i in 0..<count {
            let u = (Double(i * stride) + 0.5) * ratio - 0.5
            let first = Int((u - radius).rounded(.down)) + 1
            var raw = [Double](), at = [Int]()
            for j in first..<(first + n) {
                let w = lanczos3((u - Double(j)) / f)
                if w != 0 { raw.append(w); at.append(mirror(j, sourceLength)) }
            }
            let sum = raw.reduce(0, +)
            for k in 0..<raw.count {
                idx[i * n + k] = Int32(at[k])
                wts[i * n + k] = Float(raw[k] / sum)
            }
        }
        return SDIResampleTaps(outputCount: count, tapsPerOutput: n, indices: idx, weights: wts)
    }

    static func lanczos3(_ x: Double) -> Double {
        if x == 0 { return 1 }
        guard abs(x) < 3 else { return 0 }
        let px = Double.pi * x
        return 3 * sin(px) * sin(px / 3) / (px * px)
    }

    static func mirror(_ j: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        var k = j
        while k < 0 || k > n - 1 { k = k < 0 ? -k : 2 * (n - 1) - k }
        return k
    }
}
