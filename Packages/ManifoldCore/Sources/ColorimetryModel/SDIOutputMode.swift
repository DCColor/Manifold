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
//  Follow-ups (Robbie, 2026-10-23, §6.11 *SDI scaling follow-ups*):
//    • F1 SDI scaling: Fit to mode (default) | 1:1 pixels. 1:1 is D1–D9 above, unchanged. Fit: a source whose raster IS
//      a mode is still native (D2); otherwise the tier (1080p, 2160p; 2K/4K DCI with DCI included) whose fit scale is
//      closest to 1, and the picture is scaled up or down to fill it, aspect kept, centred, video black around it.
//    • F2 every rate the card offers up to 120: 47.95, 48, 95.90, 96, 100, 119.88 and 120 join the eight.
//    • F4 a live source's mode is chosen once per session and held (`SDILiveModeHold`).
//
//  Interlaced I2 (docs/INTERLACED_FINDINGS.md §5, §8): 1080i50 / 1080i59.94 / 1080i60 (`SDIModeFamily.i1080`), at the
//  FRAME rates 25 / 29.97 / 30, labelled by the field rate. Kept out of `SDIOutputMode.table`, which stays the
//  progressive set D1–D9 choose from; Follow source reaches them only for an interlaced 1080-line source, and the
//  picker lists them. An interlaced source is never scaled vertically (`SDIPlacement.fieldsKept`).
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

/// How a source that is not a mode fills the mode (Settings ▸ DeckLink Output ▸ SDI scaling). Default Fit to mode.
public enum SDIScaling: String, CaseIterable, Sendable {
    case fit = "fitToMode"
    case oneToOne = "oneToOne"

    public static let defaultsKey = "manifold.decklink.sdiScaling"
    public static let `default`: SDIScaling = .fit

    /// The stored value, or the default when absent or unrecognised.
    public static func stored(_ raw: String?) -> SDIScaling { raw.flatMap(Self.init(rawValue:)) ?? .default }

    public var label: String { self == .fit ? "Fit to mode" : "1:1 pixels" }
}

/// A raster the card can output (8K excluded). The raw value is the label's family part.
public enum SDIModeFamily: String, CaseIterable, Sendable {
    case p720 = "720p"
    case p1080 = "1080p"
    case dci2K = "2K DCI p"
    case p2160 = "2160p"
    case dci4K = "4K DCI p"
    /// Interlaced I2. The rate is the frame rate; the label's token is the field rate.
    case i1080 = "1080i"

    public var width: Int {
        switch self {
        case .p720: return 1280
        case .p1080, .i1080: return 1920
        case .dci2K: return 2048
        case .p2160: return 3840
        case .dci4K: return 4096
        }
    }
    public var height: Int {
        switch self {
        case .p720: return 720
        case .p1080, .dci2K, .i1080: return 1080
        case .p2160, .dci4K: return 2160
        }
    }
    public var isDCI: Bool { self == .dci2K || self == .dci4K }
    public var isInterlaced: Bool { self == .i1080 }

    public func isAvailable(in set: SDIOutputModeSet) -> Bool { !isDCI || set == .includeDCI }

    /// The rates the card offers this raster at (SDK probe, 2026-10-23: 720p only at 50, 59.94 and 60; the others at
    /// all fifteen, 23.98 to 120).
    /// 1080i at the frame rates of its three field rates (DeckLinkAPIModes.h: HD1080i50, i5994, i6000).
    public func offers(_ rate: SDIStandardRate) -> Bool {
        switch self {
        case .p720: return rate.token == "50" || rate.token == "59.94" || rate.token == "60"
        case .i1080: return rate.token == "25" || rate.token == "29.97" || rate.token == "30"
        default: return true
        }
    }

    /// F1: the rasters Fit to mode chooses among. 720p is reached only natively (D2); 1080i only for interlaced sources.
    public var isFitTier: Bool { self != .p720 && self != .i1080 }
}

/// One of the card's progressive rates up to 120, as an exact fps and the label's token.
public struct SDIStandardRate: Equatable, Sendable {
    public let fps: Double
    public let token: String

    /// The rates Follow source snaps to, in ascending order: the eight of D4a, and (F2) 47.95, 48, 95.90, 96, 100,
    /// 119.88 and 120, every progressive rate the card offers up to 120 (SDK probe, 2026-10-23).
    public static let all: [SDIStandardRate] = [
        SDIStandardRate(fps: 24000.0 / 1001.0, token: "23.98"),
        SDIStandardRate(fps: 24.0, token: "24"),
        SDIStandardRate(fps: 25.0, token: "25"),
        SDIStandardRate(fps: 30000.0 / 1001.0, token: "29.97"),
        SDIStandardRate(fps: 30.0, token: "30"),
        SDIStandardRate(fps: 48000.0 / 1001.0, token: "47.95"),
        SDIStandardRate(fps: 48.0, token: "48"),
        SDIStandardRate(fps: 50.0, token: "50"),
        SDIStandardRate(fps: 60000.0 / 1001.0, token: "59.94"),
        SDIStandardRate(fps: 60.0, token: "60"),
        SDIStandardRate(fps: 96000.0 / 1001.0, token: "95.90"),
        SDIStandardRate(fps: 96.0, token: "96"),
        SDIStandardRate(fps: 100.0, token: "100"),
        SDIStandardRate(fps: 120000.0 / 1001.0, token: "119.88"),
        SDIStandardRate(fps: 120.0, token: "120"),
    ]

    /// Nearest by |Δfps|; an unknown rate (≤ 0) is 23.98, as before.
    public static func nearest(to fps: Double) -> SDIStandardRate {
        guard fps > 0 else { return all[0] }
        return all.min(by: { abs(fps - $0.fps) < abs(fps - $1.fps) })!
    }

    /// Whether `fps` is this rate, within 0.1 % (a measured or rounded rate); otherwise the card has no mode at it and
    /// snapping changes the cadence (12, 15, 72 fps), which the caller says.
    public func matches(_ fps: Double) -> Bool { fps > 0 && abs(fps - self.fps) <= self.fps * 0.001 }

    /// The field rate's token, for an interlaced mode's label: 29.97 → "59.94", 25 → "50", 30 → "60".
    public var fieldToken: String { Self.nearest(to: fps * 2).token }
}

/// An output mode: a raster and a rate.
public struct SDIOutputMode: Equatable, Sendable {
    public let family: SDIModeFamily
    public let rate: SDIStandardRate

    public init(family: SDIModeFamily, rate: SDIStandardRate) { self.family = family; self.rate = rate }

    public var width: Int { family.width }
    public var height: Int { family.height }
    public var isInterlaced: Bool { family.isInterlaced }
    /// "1080p23.98", "720p59.94", "2K DCI p23.98", "1080i59.94" (field rate). The bridge names an established mode the
    /// same way.
    public var label: String { family.rawValue + (isInterlaced ? rate.fieldToken : rate.token) }

    /// Every PROGRESSIVE mode in scope: each family at each rate the card offers it. What D1–D9 choose from.
    public static let table: [SDIOutputMode] = SDIModeFamily.allCases.filter { !$0.isInterlaced }.flatMap { f in
        SDIStandardRate.all.filter { f.offers($0) }.map { SDIOutputMode(family: f, rate: $0) }
    }

    /// I2: 1080i50, 1080i59.94, 1080i60.
    public static let interlacedTable: [SDIOutputMode] = SDIStandardRate.all.filter { SDIModeFamily.i1080.offers($0) }
        .map { SDIOutputMode(family: .i1080, rate: $0) }
}

public enum SDIOutputModeSelector {
    /// THE one function: the mode a source goes out at under Follow source (D1–D3; F1 under Fit to mode).
    /// `pixelAspect` is the declared h/v ratio, nil when undeclared (square assumed, D6). `frameRate` is the FRAME rate
    /// (an interlaced file's after `InterlacedRate`, decision 3).
    ///
    /// I2: an `interlaced` source (woven fields) of 1080 lines at 25 / 29.97 / 30 goes out at 1080i50 / 59.94 / 60,
    /// whatever its width (a 1440 or 1280 width is resampled horizontally only, `SDIPlacement.fieldsKept`). Any other
    /// interlaced source has no interlaced mode — 1080 at 23.98 or 24 (§5), or not 1080 lines (SD is out of scope,
    /// decision 8) — and is chosen for as progressive under the 1:1 rule, because its picture is never scaled
    /// vertically.
    public static func select(width: Int, height: Int, pixelAspect: Double?, frameRate: Double,
                              set: SDIOutputModeSet, scaling: SDIScaling = .oneToOne,
                              interlaced: Bool = false) -> SDIOutputMode {
        if interlaced {
            if let m = interlacedMode(height: height, frameRate: frameRate) { return m }
            return select(width: width, height: height, pixelAspect: pixelAspect, frameRate: frameRate, set: set,
                          scaling: .oneToOne)
        }
        let rate = SDIStandardRate.nearest(to: frameRate)
        let modes = SDIOutputMode.table.filter { $0.rate == rate && $0.family.isAvailable(in: set) }
        let par = SDIPlacement.effectiveAspect(pixelAspect)
        // D2: the raster is a mode, square pixels → that mode, native. Under either scaling.
        if par == 1, let native = modes.first(where: { $0.width == width && $0.height == height }) { return native }
        let dw = Double(width) * par, dh = Double(height)
        if scaling == .fit {
            // F1: the tier whose fit scale s is closest to 1 (smallest |ln s|); a tie goes to the larger s (an
            // upscale throws no source detail away), then to the smaller area (the 1:1 rule's tie, 2160p before 4K DCI).
            func scale(_ m: SDIOutputMode) -> Double { min(Double(m.width) / dw, Double(m.height) / dh) }
            func key(_ m: SDIOutputMode) -> (Double, Double, Int) { (abs(log(scale(m))), -scale(m), m.width * m.height) }
            let tiers = modes.filter { $0.family.isFitTier }
            return tiers.dropFirst().reduce(tiers[0]) { best, m in key(m) < key(best) ? m : best }
        }
        // D3: the smallest that holds the picture's display size unscaled.
        let holding = modes.filter { Double($0.width) >= dw && Double($0.height) >= dh }
        if let smallest = holding.min(by: { $0.width * $0.height < $1.width * $1.height }) { return smallest }
        // Too big for every mode: the largest, whichever scales least; the first listed (2160p) wins a tie.
        let largest = modes.filter { $0.height == 2160 }
        func scale(_ m: SDIOutputMode) -> Double { min(Double(m.width) / dw, Double(m.height) / dh) }
        return largest.reduce(largest[0]) { best, m in scale(m) > scale(best) ? m : best }
    }

    /// I2: the 1080i mode for an interlaced source, or nil when it has none (not 1080 lines, or a frame rate whose
    /// nearest standard rate is not 25 / 29.97 / 30). The rate snaps as D1 does.
    public static func interlacedMode(height: Int, frameRate: Double) -> SDIOutputMode? {
        guard height == 1080 else { return nil }
        let rate = SDIStandardRate.nearest(to: frameRate)
        return SDIOutputMode.interlacedTable.first { $0.rate == rate }
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
    /// I2: an interlaced picture placed with its fields intact: rows 1:1 (never scaled vertically), on an even row so
    /// each source line keeps its field's parity; only the width is resampled.
    public var fieldsKept: Bool = false

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

    /// Fit a source into an output raster. 1:1 pixels: unscaled when its display size fits (D4), otherwise scaled down.
    /// Fit to mode (F1): scaled up or down until it meets the mode's sides, unscaled only when it already does. Aspect
    /// kept, never cropped, either way. x on the 6-pixel group nearest the centre (ties to the smaller); y centred, the
    /// odd row to the bottom bar; a scaled width rounded to even, a scaled height to the nearest row.
    ///
    /// `interlaced` (I2): when the source's rows fit the mode, they are placed 1:1 on an even row (`fieldsKept`) and only
    /// the width is resampled, to the display width (`sourceWidth` × pixel aspect) capped at the mode's, whichever the
    /// scaling setting: Fit to mode's vertical fit would resample across the two fields. A source taller than the mode
    /// (a manual pick smaller than the source) is placed as progressive, its fields mixed by the vertical scale.
    public static func fit(sourceWidth: Int, sourceHeight: Int, pixelAspect: Double?,
                           outputWidth: Int, outputHeight: Int, scaling: SDIScaling = .oneToOne,
                           interlaced: Bool = false) -> SDIPlacement {
        let par = effectiveAspect(pixelAspect)
        if interlaced && sourceHeight <= outputHeight {
            let dw = Double(sourceWidth) * par
            let w = par == 1 && sourceWidth <= outputWidth ? sourceWidth
                  : max(2, min(outputWidth, Int((dw / 2).rounded(.toNearestOrAwayFromZero)) * 2))
            let y = ((outputHeight - sourceHeight) / 2) & ~1
            var p = SDIPlacement(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                 outputWidth: outputWidth, outputHeight: outputHeight,
                                 x: nearestMultipleOf6(Double(outputWidth - w) / 2), y: y, width: w, height: sourceHeight,
                                 scale: Double(w) / dw, pixelAspect: par, pixelAspectDeclared: pixelAspect != nil)
            p.fieldsKept = true
            return p
        }
        let dw = Double(sourceWidth) * par, dh = Double(sourceHeight)
        let toSides = min(Double(outputWidth) / dw, Double(outputHeight) / dh)
        let fits = scaling == .fit ? toSides == 1 : dw <= Double(outputWidth) && dh <= Double(outputHeight)
        let s = fits ? 1.0 : toSides
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
        if fieldsKept { s += ", fields kept (rows 1:1, horizontal only)" }
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

    /// I2: every output row is its own source row, weight exactly 1 — the vertical pass of a `fieldsKept` placement.
    /// (Lanczos-3 at ratio 1 is the identity in exact arithmetic, but its zero taps come out of `sin(πk)` as ~1e-16,
    /// not 0, so it would still read the neighbouring rows, which belong to the other field.)
    public static func identity(length: Int) -> SDIResampleTaps {
        SDIResampleTaps(outputCount: length, tapsPerOutput: 1, indices: (0..<length).map { Int32($0) },
                        weights: [Float](repeating: 1, count: length))
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

/// F4: a live source's output mode is chosen once per session and held. A session runs from the first format that
/// states a rate to the source going away (`end`). Later renditions, resolution or rate changes never move the mode:
/// the renderer places or scales each frame within it, and the caller logs the change as absorbed. The mode is chosen
/// from `sizingRaster` when the source states one (HLS: the largest rendition in the master playlist), else from the
/// frame's own raster. An operator action (the mode set, the scaling, a manual pick) re-resolves from the same basis.
public struct SDILiveModeHold: Sendable {
    public struct Format: Equatable, Sendable {
        public let width: Int, height: Int
        public let frameRate: Double
        /// The raster to choose the mode from instead of the frame's, when the source states one.
        public let sizingWidth: Int?, sizingHeight: Int?
        public init(width: Int, height: Int, frameRate: Double, sizingWidth: Int? = nil, sizingHeight: Int? = nil) {
            self.width = width; self.height = height; self.frameRate = frameRate
            self.sizingWidth = sizingWidth; self.sizingHeight = sizingHeight
        }
        var basisWidth: Int { sizingWidth ?? width }
        var basisHeight: Int { sizingHeight ?? height }
    }

    public enum Decision: Equatable, Sendable {
        /// The session's mode: apply it (the first format of a session, or an operator re-resolve).
        case apply(SDIOutputMode)
        /// A change after the mode was chosen. `resolved` is what a fresh choice would have been; the mode stays `held`.
        case absorbed(held: SDIOutputMode, resolved: SDIOutputMode)
    }

    /// The format the session's mode was chosen from, and the mode. nil between sessions.
    public private(set) var basis: Format?
    public private(set) var held: SDIOutputMode?

    public init() {}

    public static func resolve(_ f: Format, set: SDIOutputModeSet, scaling: SDIScaling) -> SDIOutputMode {
        SDIOutputModeSelector.select(width: f.basisWidth, height: f.basisHeight, pixelAspect: nil,
                                     frameRate: f.frameRate, set: set, scaling: scaling)
    }

    /// A format with a rate arrived. The first of a session chooses the mode; every later one is absorbed.
    public mutating func observe(_ f: Format, set: SDIOutputModeSet, scaling: SDIScaling) -> Decision {
        let resolved = Self.resolve(f, set: set, scaling: scaling)
        if let held { return .absorbed(held: held, resolved: resolved) }
        basis = f
        held = resolved
        return .apply(resolved)
    }

    /// An operator setting changed mid-session: choose again from the session's basis. nil outside a session.
    public mutating func reresolve(set: SDIOutputModeSet, scaling: SDIScaling) -> SDIOutputMode? {
        guard let basis else { return nil }
        let m = Self.resolve(basis, set: set, scaling: scaling)
        held = m
        return m
    }

    /// The source is gone: the next format starts a new session.
    public mutating func end() { basis = nil; held = nil }
}
