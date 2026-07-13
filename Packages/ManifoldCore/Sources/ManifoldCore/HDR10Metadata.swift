import Foundation
import CFFmpeg

/// HDR10 STATIC metadata — read-only.
///
/// Two INDEPENDENT blocks that travel together but are NOT one thing, and are not
/// unified here:
///
///  * MDCV — Mastering Display Color Volume (SMPTE ST 2086). Describes the DISPLAY
///    the content was graded on: RGB primary chromaticities, white point, and the
///    display's max/min luminance. Units: CIE 1931 xy, and cd/m² (nits).
///  * CLLI — Content Light Level Information (CTA-861.3). Describes the CONTENT:
///    MaxCLL (brightest pixel) and MaxFALL (brightest frame average). Units: plain
///    integer nits.
///
/// A file may carry either, both, or neither. Absence of one says nothing about the
/// other, so each carries its own present flag and neither borrows the other's values.
///
/// Manifold is a VIEWER: this is parsed and displayed, never written, and (as of EDR
/// stage 3) never fed to tone-mapping or headroom mapping. It is a readout of what the
/// file DECLARES, not an input to how the file is rendered.

// MARK: - Values

/// A CIE 1931 xy chromaticity coordinate.
public struct CIExy: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// "0.1700, 0.7970" — four decimals, which is the resolution ST 2086's 0.00002
    /// chromaticity quantum actually supports.
    public var string: String {
        String(format: "%.4f, %.4f", x, y)
    }

    func isClose(to other: CIExy, tolerance: Double) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
    }
}

/// Mastering display color volume (ST 2086), as libav hands it to us.
///
/// `hasPrimaries` / `hasLuminance` are libav's own per-half present flags: an MDCV box
/// can declare primaries without usable luminance (or vice versa). They are kept
/// SEPARATE rather than collapsed into one "valid" bool so a half-declared box reads
/// as half-declared instead of silently absent.
public struct MasteringDisplayInfo: Equatable, Sendable {
    public var hasPrimaries: Bool
    public var hasLuminance: Bool

    /// Primary chromaticities in RGB order (libav's `display_primaries` index order:
    /// [0]=R, [1]=G, [2]=B). NOTE: the ST 2086 BITSTREAM stores these Green-Blue-Red;
    /// libav's demuxer performs the GBR→RGB reorder, so by the time they reach us the
    /// index IS the channel. See `HDR10MetadataReader` for the verification of this.
    public var red: CIExy
    public var green: CIExy
    public var blue: CIExy
    public var whitePoint: CIExy

    /// Mastering display luminance in cd/m² (nits). Only meaningful when `hasLuminance`.
    public var maxLuminance: Double
    public var minLuminance: Double

    public init(hasPrimaries: Bool, hasLuminance: Bool,
                red: CIExy, green: CIExy, blue: CIExy, whitePoint: CIExy,
                maxLuminance: Double, minLuminance: Double) {
        self.hasPrimaries = hasPrimaries
        self.hasLuminance = hasLuminance
        self.red = red
        self.green = green
        self.blue = blue
        self.whitePoint = whitePoint
        self.maxLuminance = maxLuminance
        self.minLuminance = minLuminance
    }

    /// The name of the gamut these primaries describe, or "Custom".
    ///
    /// A match requires ALL THREE primaries within tolerance — this NEVER snaps to the
    /// nearest known set. A mastering display that is genuinely a little off BT.2020 is
    /// reported as Custom (with its coordinates shown), because calling it BT.2020 would
    /// be inventing a fact the file does not state.
    public var primariesName: String {
        HDR10Gamut.name(red: red, green: green, blue: blue) ?? "Custom"
    }

    /// The name of the white point ("D65", "DCI"), or nil if it matches no known one.
    public var whitePointName: String? {
        HDR10Gamut.whitePointName(whitePoint)
    }
}

/// Content light level (CTA-861.3). Plain nits — NOT the same units or the same
/// subject as the mastering display's luminance.
public struct ContentLightInfo: Equatable, Sendable {
    public var maxCLL: Int      // brightest single pixel, nits
    public var maxFALL: Int     // brightest frame-average, nits

    public init(maxCLL: Int, maxFALL: Int) {
        self.maxCLL = maxCLL
        self.maxFALL = maxFALL
    }

    /// CTA-861.3 defines 0 as "unknown / not indicated", not as "zero nits". A file can
    /// therefore carry a CLLI block whose values declare nothing — reported as such
    /// rather than displayed as a literal 0-nit measurement.
    public var maxCLLIsUnspecified: Bool { maxCLL == 0 }
    public var maxFALLIsUnspecified: Bool { maxFALL == 0 }
}

// MARK: - Presence

/// The honest state of one metadata block. Deliberately FOUR states, not two: a
/// half-declared block is not the same fact as an undeclared one, and an undeclared
/// block on HLG is not the same fact as an undeclared one on PQ.
///
/// This mirrors the source-range tag pattern (full / videoLegal / untagged): the
/// absence of a declaration is itself reported, never silently defaulted.
public enum HDR10Presence: Equatable, Sendable {
    /// Declared and complete — show the values.
    case declared
    /// Declared but incomplete (e.g. an MDCV box with has_luminance == 0). The reason
    /// is carried so the UI can say WHAT is missing. Not collapsed into `.notDeclared`.
    case declaredIncomplete(String)
    /// Not declared, and its absence is worth noting (e.g. PQ without MDCV).
    case notDeclared
    /// Not declared, and that is EXPECTED for this transfer function — HLG is
    /// scene-referred and normally carries no static mastering metadata. Absence here
    /// is correct authoring, not a gap, and is labeled so it doesn't read as a defect.
    case notApplicable(String)

    /// Whether this state should render as a fact (full opacity) or as a non-value
    /// (muted + italic, the same convention the audio layout rows use for non-facts).
    public var isFact: Bool {
        if case .declared = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .declared:                    return "Declared"
        case .declaredIncomplete(let why): return "Declared, \(why)"
        case .notDeclared:                 return "Not declared"
        case .notApplicable(let why):      return "Not applicable (\(why))"
        }
    }
}

// MARK: - The parsed metadata

public struct HDR10StaticMetadata: Equatable, Sendable {
    /// nil == the file declares no MDCV block. The Optional IS the present flag; absence
    /// is never sentinel-encoded into the values (no 0-nit "default" masquerading as a
    /// declaration).
    public var mastering: MasteringDisplayInfo?
    /// nil == the file declares no CLLI block.
    public var contentLight: ContentLightInfo?

    public var hasMDCV: Bool { mastering != nil }
    public var hasCLLI: Bool { contentLight != nil }
    public var hasAny: Bool { hasMDCV || hasCLLI }

    public init(mastering: MasteringDisplayInfo? = nil, contentLight: ContentLightInfo? = nil) {
        self.mastering = mastering
        self.contentLight = contentLight
    }

    /// CICP transfer code for HLG (ITU-R BT.2100). The inspector already reads this code.
    private static let transferHLG = 18

    /// The MDCV block's honest state, aware of the transfer function.
    ///
    /// HLG is scene-referred: it has no mastering-display-referred static metadata by
    /// design, so a missing MDCV on an HLG file is EXPECTED and is reported as "not
    /// applicable", not as a missing declaration. On PQ (or anything else) a missing
    /// MDCV is a real absence and says so.
    public func mdcvPresence(transferCode: Int?) -> HDR10Presence {
        guard let m = mastering else {
            return transferCode == Self.transferHLG
                ? .notApplicable("HLG")
                : .notDeclared
        }
        switch (m.hasPrimaries, m.hasLuminance) {
        case (true, true):   return .declared
        case (true, false):  return .declaredIncomplete("luminance missing")
        case (false, true):  return .declaredIncomplete("primaries missing")
        case (false, false): return .declaredIncomplete("no values")
        }
    }

    /// The CLLI block's honest state, aware of the transfer function (same reasoning).
    public func clliPresence(transferCode: Int?) -> HDR10Presence {
        guard let c = contentLight else {
            return transferCode == Self.transferHLG
                ? .notApplicable("HLG")
                : .notDeclared
        }
        // A present block whose values are both the spec's "unknown" sentinel declares
        // nothing — that is a partial declaration, not a measurement of zero.
        if c.maxCLLIsUnspecified && c.maxFALLIsUnspecified {
            return .declaredIncomplete("values unspecified")
        }
        return .declared
    }

    /// Format a luminance in nits. Mastering-display min luminance is routinely a tiny
    /// fraction (0.0001), max is a large round number (1000/4000/10000) — one formatter
    /// has to read honestly across five orders of magnitude.
    public static func nitsString(_ v: Double) -> String {
        guard v.isFinite, v > 0 else { return "0 nits" }
        if v >= 1 {
            return v == v.rounded()
                ? String(format: "%.0f nits", v)
                : String(format: "%.2f nits", v)
        }
        return String(format: "%g nits", v)
    }
}

// MARK: - Known gamuts

/// Named primary sets, for LABELING declared values — never for supplying them.
public enum HDR10Gamut {

    /// Tolerance for calling a declared primary set by a known name.
    ///
    /// ST 2086 quantizes chromaticity to 0.00002 steps, so an exactly-authored BT.2020
    /// round-trips essentially exact. 0.001 absorbs that quantization and ordinary
    /// authoring rounding (e.g. 0.708 vs 0.70800) while remaining far tighter than the
    /// gap between any two real gamuts (BT.709 green 0.300,0.600 vs Display P3 green
    /// 0.265,0.690 — two orders of magnitude wider than this). It is a spelling
    /// tolerance, not a snapping radius.
    public static let tolerance = 0.001

    struct Gamut {
        let name: String
        let red: CIExy
        let green: CIExy
        let blue: CIExy
    }

    static let known: [Gamut] = [
        Gamut(name: "BT.2020",
              red:   CIExy(x: 0.708, y: 0.292),
              green: CIExy(x: 0.170, y: 0.797),
              blue:  CIExy(x: 0.131, y: 0.046)),
        Gamut(name: "Display P3",
              red:   CIExy(x: 0.680, y: 0.320),
              green: CIExy(x: 0.265, y: 0.690),
              blue:  CIExy(x: 0.150, y: 0.060)),
        Gamut(name: "BT.709",
              red:   CIExy(x: 0.640, y: 0.330),
              green: CIExy(x: 0.300, y: 0.600),
              blue:  CIExy(x: 0.150, y: 0.060))
    ]

    /// The known gamut whose R, G AND B all match, or nil for "Custom".
    ///
    /// Note P3's and BT.709's blue primaries are identical (0.150, 0.060) — which is
    /// exactly why all three primaries must match. A nearest-match would happily call a
    /// custom display "close enough" to a standard; this refuses to.
    public static func name(red: CIExy, green: CIExy, blue: CIExy) -> String? {
        for g in known {
            if red.isClose(to: g.red, tolerance: tolerance),
               green.isClose(to: g.green, tolerance: tolerance),
               blue.isClose(to: g.blue, tolerance: tolerance) {
                return g.name
            }
        }
        return nil
    }

    static let whitePoints: [(name: String, xy: CIExy)] = [
        ("D65", CIExy(x: 0.3127, y: 0.3290)),
        ("DCI", CIExy(x: 0.314,  y: 0.351)),
        ("D60", CIExy(x: 0.32168, y: 0.33767))
    ]

    public static func whitePointName(_ wp: CIExy) -> String? {
        whitePoints.first { wp.isClose(to: $0.xy, tolerance: tolerance) }?.name
    }
}

// MARK: - Reader

/// Reads HDR10 static metadata from a container via libav's side-data API.
///
/// We ask libav for the parsed structs rather than hand-walking `mdcv`/`clli` boxes:
/// libav's demuxers already handle the container-specific layout AND the ST 2086
/// Green-Blue-Red primary ordering (the bitstream stores GBR; libav reorders to RGB and
/// documents `display_primaries` as "(r, g, b) order"). Hand-parsing would mean
/// re-implementing — and re-fumbling — both.
///
/// The GBR→RGB reorder claim is VERIFIED, not assumed: two identically-authored test
/// files that differ ONLY in mastering primaries (BT.2020 vs Display P3) must name their
/// gamuts correctly and distinctly. A wrong index order would scramble both into
/// "Custom" with permuted coordinates rather than producing two correct, different names.
///
/// Read-only, and completely off the render path: this opens the container, reads the
/// stream's metadata, and closes it. It never decodes a frame and never touches the
/// player's libav contexts.
public enum HDR10MetadataReader {

    /// Parse the video stream's HDR10 static metadata. Returns an all-absent value
    /// (NOT an error) when the file simply declares none — which is the correct,
    /// common case for SDR and for HLG.
    public static func read(url: URL) -> HDR10StaticMetadata {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, url.path, nil, nil) == 0, ctx != nil else {
            return HDR10StaticMetadata()
        }
        defer { avformat_close_input(&ctx) }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return HDR10StaticMetadata() }

        let idx = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard idx >= 0, let streams = ctx!.pointee.streams,
              let stream = streams[Int(idx)] else { return HDR10StaticMetadata() }

        // HDR10 static metadata is STREAM-level (it describes the whole clip, not a
        // frame), so it is read from the stream's codec parameters — NOT from decoded
        // frames. In FFmpeg 8 `AVStream.side_data` no longer exists; the demuxer's only
        // stream-level attachment point is `codecpar->coded_side_data` (verified against
        // the vendored 8.1.1 headers, not assumed).
        guard let par = stream.pointee.codecpar else { return HDR10StaticMetadata() }
        let sideData = { (type: AVPacketSideDataType) -> UnsafePointer<AVPacketSideData>? in
            av_packet_side_data_get(par.pointee.coded_side_data,
                                    par.pointee.nb_coded_side_data, type)
        }

        var result = HDR10StaticMetadata()
        let file = url.lastPathComponent

        // --- MDCV (ST 2086) ---
        if let sd = sideData(AV_PKT_DATA_MASTERING_DISPLAY_METADATA), let raw = sd.pointee.data,
           Int(sd.pointee.size) >= MemoryLayout<AVMasteringDisplayMetadata>.size {
            let m = UnsafeRawPointer(raw).loadUnaligned(as: AVMasteringDisplayMetadata.self)

            // libav's display_primaries is [3][2] — imported into Swift as a nested
            // tuple. Index [0]=R, [1]=G, [2]=B per libav's documented "(r, g, b) order";
            // the demuxer has already undone the bitstream's GBR ordering.
            let p = m.display_primaries
            let red   = xy(p.0.0, p.0.1)
            let green = xy(p.1.0, p.1.1)
            let blue  = xy(p.2.0, p.2.1)
            let wp    = xy(m.white_point.0, m.white_point.1)

            let info = MasteringDisplayInfo(
                hasPrimaries: m.has_primaries != 0,
                hasLuminance: m.has_luminance != 0,
                red: red, green: green, blue: blue, whitePoint: wp,
                maxLuminance: q2d(m.max_luminance),
                minLuminance: q2d(m.min_luminance)
            )
            result.mastering = info

            // Log the RAW AVRationals beside the converted values. libav hands us actual
            // chromaticities and actual nits (already scaled — it has applied ST 2086's
            // 0.00002 / 0.0001 raw-integer quanta as the rational denominators). Logging
            // both means the units we are trusting are observed, not assumed.
            print("""
            HDR10 [\(file)] MDCV via codecpar.coded_side_data \
            (has_primaries=\(m.has_primaries) has_luminance=\(m.has_luminance)):
              display_primaries[0] (R): \(rq(p.0.0))=\(f(red.x)), \(rq(p.0.1))=\(f(red.y))
              display_primaries[1] (G): \(rq(p.1.0))=\(f(green.x)), \(rq(p.1.1))=\(f(green.y))
              display_primaries[2] (B): \(rq(p.2.0))=\(f(blue.x)), \(rq(p.2.1))=\(f(blue.y))
              white_point:             \(rq(m.white_point.0))=\(f(wp.x)), \(rq(m.white_point.1))=\(f(wp.y))
              max_luminance:           \(rq(m.max_luminance)) = \(info.maxLuminance) nits
              min_luminance:           \(rq(m.min_luminance)) = \(info.minLuminance) nits
              → primaries read as: \(info.primariesName), white point: \(info.whitePointName ?? "Custom")
            """)
        }

        // --- CLLI (CTA-861.3) ---
        if let sd = sideData(AV_PKT_DATA_CONTENT_LIGHT_LEVEL), let raw = sd.pointee.data,
           Int(sd.pointee.size) >= MemoryLayout<AVContentLightMetadata>.size {
            let c = UnsafeRawPointer(raw).loadUnaligned(as: AVContentLightMetadata.self)
            result.contentLight = ContentLightInfo(maxCLL: Int(c.MaxCLL), maxFALL: Int(c.MaxFALL))
            // Plain integer nits — no rational, no scaling. Deliberately NOT unified with
            // the MDCV luminances above, which are a different subject in different units.
            print("HDR10 [\(file)] CLLI via codecpar.coded_side_data: MaxCLL=\(c.MaxCLL) nits, MaxFALL=\(c.MaxFALL) nits")
        }

        if !result.hasAny {
            print("HDR10 [\(file)] no MDCV and no CLLI side data on the video stream")
        }
        return result
    }

    /// AVRational → Double. den == 0 is libav's "unset" rational; it is NOT 0.0 nits or
    /// a 0.0 chromaticity, so it converts to 0 only as a last resort and the caller's
    /// has_* flag is what decides whether the value means anything.
    private static func q2d(_ r: AVRational) -> Double {
        r.den != 0 ? Double(r.num) / Double(r.den) : 0
    }

    private static func xy(_ x: AVRational, _ y: AVRational) -> CIExy {
        CIExy(x: q2d(x), y: q2d(y))
    }

    /// "8500/50000" — the raw rational, for the diagnostic log.
    private static func rq(_ r: AVRational) -> String { "\(r.num)/\(r.den)" }
    private static func f(_ v: Double) -> String { String(format: "%.5f", v) }
}
