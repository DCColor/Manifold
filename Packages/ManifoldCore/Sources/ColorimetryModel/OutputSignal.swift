//
//  OutputSignal.swift
//  ColorimetryModel
//
//  Colour S7 (COLOR_MANAGEMENT_FINDINGS.md §6.11, *S7 — output HDR signalling*): what the DeckLink output
//  signals with each frame. The colorimetry and EOTF the SDI VPID carries, the static metadata the HDMI
//  InfoFrame carries, and whether the v210 encode converts the picture's primaries to Rec.2020 first (D4).
//
//  Resolved from the PICTURE codes (S6 D3: the wire carries the post-LUT picture) and the source's HDR10
//  metadata. The renderer resolves it on every colour change and carries it with each rendered frame, so the
//  bridge tags a frame with the signal it was rendered under (D1).
//
//  ⚠️ TWO FIELDS, NEVER DERIVED FROM EACH OTHER (D10, clarified 2026-10-13). The signal colorimetry follows the
//  picture's primaries. The mastering primaries come from the source's metadata, else the P3-D65 default. A 2020
//  signal does not imply 2020 mastering primaries, and P3 mastering primaries do not make the signal P3.
//

import Foundation

/// The colorimetry the output signals (the bridge's `BMDColorspace`).
public enum OutputColorimetry: Equatable, Sendable {
    case rec709
    case rec2020

    public var name: String { self == .rec709 ? "Rec. 709" : "Rec. 2020" }
}

/// CTA-861.3's EOTF codes, which the SDK's EOTF key takes (`SignalGenHDR.h`: SDR 0, PQ 2, HLG 3).
public enum OutputEOTF: Int, Equatable, Sendable {
    case sdr = 0
    case pq = 2
    case hlg = 3

    public var name: String {
        switch self {
        case .sdr: return "SDR"
        case .pq:  return "PQ"
        case .hlg: return "HLG"
        }
    }
}

/// A mastering display's colour volume (SMPTE ST 2086), as the output sends it.
public struct MasteringDisplay: Equatable, Sendable {
    public var red: Chromaticity
    public var green: Chromaticity
    public var blue: Chromaticity
    public var white: Chromaticity
    /// cd/m².
    public var maxLuminance: Double
    public var minLuminance: Double

    public init(red: Chromaticity, green: Chromaticity, blue: Chromaticity, white: Chromaticity,
                maxLuminance: Double, minLuminance: Double) {
        self.red = red; self.green = green; self.blue = blue; self.white = white
        self.maxLuminance = maxLuminance; self.minLuminance = minLuminance
    }
}

/// A mastering display's primaries and white, from a source's MDCV.
public struct MasteringPrimaries: Equatable, Sendable {
    public var red: Chromaticity
    public var green: Chromaticity
    public var blue: Chromaticity
    public var white: Chromaticity

    public init(red: Chromaticity, green: Chromaticity, blue: Chromaticity, white: Chromaticity) {
        self.red = red; self.green = green; self.blue = blue; self.white = white
    }
}

/// What a source states about its HDR10 static metadata. Each half on its own; nil = not stated.
public struct SourceHDRMetadata: Equatable, Sendable {
    /// From MDCV.
    public var primaries: MasteringPrimaries?
    /// From MDCV: max and min luminance, cd/m².
    public var maxLuminance: Double?
    public var minLuminance: Double?
    /// From CLLI. nil = no CLLI block; 0 = the block says "unknown" (CTA-861.3).
    public var maxCLL: Int?
    public var maxFALL: Int?

    public init(primaries: MasteringPrimaries? = nil, maxLuminance: Double? = nil, minLuminance: Double? = nil,
                maxCLL: Int? = nil, maxFALL: Int? = nil) {
        self.primaries = primaries; self.maxLuminance = maxLuminance; self.minLuminance = minLuminance
        self.maxCLL = maxCLL; self.maxFALL = maxFALL
    }
}

/// The static metadata a PQ signal carries (HDMI's InfoFrame; D6: SDI carries none of it).
public struct OutputStaticMetadata: Equatable, Sendable {
    public var mastering: MasteringDisplay
    /// cd/m². 0 = CTA-861.3's "unknown" (D2: sent as 0 when the source states none; S7-0 showed the SDK takes 0).
    public var maxCLL: Int
    public var maxFALL: Int
    /// Which halves came from the defaults rather than the source (the readout and the log say so).
    public var primariesDefaulted: Bool
    public var luminanceDefaulted: Bool

    public init(mastering: MasteringDisplay, maxCLL: Int, maxFALL: Int,
                primariesDefaulted: Bool, luminanceDefaulted: Bool) {
        self.mastering = mastering; self.maxCLL = maxCLL; self.maxFALL = maxFALL
        self.primariesDefaulted = primariesDefaulted; self.luminanceDefaulted = luminanceDefaulted
    }

    /// The defaults for a PQ picture whose source states none (D10's table): P3-D65 primaries (content limited to
    /// P3 inside the 2020 container), D65 white, 1000 / 0.0050 cd/m². MaxCLL and MaxFALL are never invented: 0.
    public static let defaultMastering = MasteringDisplay(
        red: ColorPrimaries.p3D65.published.red, green: ColorPrimaries.p3D65.published.green,
        blue: ColorPrimaries.p3D65.published.blue, white: PrimariesSet.d65,
        maxLuminance: 1000, minLuminance: 0.005)
}

/// D4: the v210 encode converts the picture to Rec.2020 primaries, for SDI only, when the picture's primaries
/// TAG is P3 (12 P3-D65, 11 DCI-P3). A picture tagged 2020 whose content is limited to P3 is not converted: its
/// P3 limit is stated only in the mastering metadata (clarified, Robbie, 2026-10-22).
public struct SDIPrimariesConversion: Equatable, Sendable {
    /// The picture's primaries (`.p3D65` or `.dciP3`).
    public let from: ColorPrimaries
    /// Linear RGB in the RENDERED primaries (DCI-P3 Bradford-adapted to D65, as the window draws it) → linear
    /// Rec.2020, row-major.
    public let matrix: ColorMatrix3
    /// The curve the picture is encoded with: decoded before the matrix, re-encoded after.
    public let curve: ScopeCurve

    public init?(picturePrimaries: Int?, pictureTransfer: Int?) {
        guard let p = ColorPrimaries(cicp: picturePrimaries), p == .p3D65 || p == .dciP3 else { return nil }
        from = p
        matrix = ColorMatrix.conversion(from: p.rendered, to: ColorPrimaries.rec2020.rendered)
        curve = ScopeCurve(transferCode: pictureTransfer)
    }

    /// The shader's arithmetic, in double (the reference P2 and P7 measure against). Power curves are applied to
    /// the magnitude with the sign kept, so sub-black and superwhite survive; PQ and HLG are defined from 0.
    public func apply(_ rgb: [Double]) -> [Double] {
        let lin = rgb.map { Self.linearize($0, curve) }
        return ColorMatrix.apply(matrix, lin).map { Self.encode($0, curve) }
    }

    public static func linearize(_ e: Double, _ curve: ScopeCurve) -> Double {
        switch curve {
        case .power24:
            return e < 0 ? -pow(-e, 2.4) : pow(e, 2.4)
        case .srgb:
            let a = abs(e)
            let l = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
            return e < 0 ? -l : l
        case .pq:
            let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
            let ep = pow(max(e, 0), 1 / m2)
            return pow(max(ep - c1, 0) / (c2 - c3 * ep), 1 / m1)
        case .hlg:
            let a = 0.17883277, b = 0.28466892, c = 0.55991073
            let x = max(e, 0)
            return x <= 0.5 ? x * x / 3 : (exp((x - c) / a) + b) / 12
        }
    }

    public static func encode(_ l: Double, _ curve: ScopeCurve) -> Double {
        switch curve {
        case .power24:
            return l < 0 ? -pow(-l, 1 / 2.4) : pow(l, 1 / 2.4)
        case .srgb:
            let a = abs(l)
            let e = a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1 / 2.4) - 0.055
            return l < 0 ? -e : e
        case .pq:
            let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
            let y = pow(max(l, 0), m1)
            return pow((c1 + c2 * y) / (1 + c3 * y), m2)
        case .hlg:
            let a = 0.17883277, b = 0.28466892, c = 0.55991073
            let x = max(l, 0)
            return x <= 1.0 / 12 ? (3 * x).squareRoot() : a * log(12 * x - b) + c
        }
    }
}

/// One frame's output signal.
public struct OutputSignal: Equatable, Sendable {
    public let colorimetry: OutputColorimetry
    public let eotf: OutputEOTF
    /// PQ only (D3: HLG sends the EOTF alone, as the SDK sample does; SDR sends none).
    public let staticMetadata: OutputStaticMetadata?
    /// D4. nil = the picture goes out in its own primaries.
    public let primariesConversion: SDIPrimariesConversion?

    public init(colorimetry: OutputColorimetry, eotf: OutputEOTF, staticMetadata: OutputStaticMetadata?,
                primariesConversion: SDIPrimariesConversion?) {
        self.colorimetry = colorimetry; self.eotf = eotf
        self.staticMetadata = staticMetadata; self.primariesConversion = primariesConversion
    }

    /// What a renderer with no picture signals, as the output did before any source (Rec.709, SDR).
    public static let sdr709 = OutputSignal(colorimetry: .rec709, eotf: .sdr, staticMetadata: nil, primariesConversion: nil)

    /// The colorimetry for a picture primaries code: 9, 11 and 12 → Rec.2020 (P3 is converted into 2020 by D4),
    /// everything else, absent and unknown included → Rec.709. The table the bridge used before S7.
    public static func colorimetry(forPrimaries code: Int?) -> OutputColorimetry {
        switch code {
        case 9, 11, 12: return .rec2020
        default:        return .rec709
        }
    }

    /// The EOTF for a picture transfer code: 16 → PQ, 18 → HLG, everything else → SDR.
    public static func eotf(forTransfer code: Int?) -> OutputEOTF {
        switch code {
        case 16: return .pq
        case 18: return .hlg
        default: return .sdr
        }
    }

    /// The signal for a picture. `source` is the source's HDR10 metadata when it describes this picture (nil when
    /// a LUT states the output space: the source's grade does not describe the LUT's output).
    public static func resolve(picturePrimaries: Int?, pictureTransfer: Int?,
                               source: SourceHDRMetadata?) -> OutputSignal {
        let eotf = eotf(forTransfer: pictureTransfer)
        var meta: OutputStaticMetadata?
        if eotf == .pq {
            let d = OutputStaticMetadata.defaultMastering
            let p = source?.primaries
            let maxL = source?.maxLuminance, minL = source?.minLuminance
            meta = OutputStaticMetadata(
                mastering: MasteringDisplay(red: p?.red ?? d.red, green: p?.green ?? d.green, blue: p?.blue ?? d.blue,
                                            white: p?.white ?? d.white,
                                            maxLuminance: maxL ?? d.maxLuminance, minLuminance: minL ?? d.minLuminance),
                maxCLL: source?.maxCLL ?? 0, maxFALL: source?.maxFALL ?? 0,
                primariesDefaulted: p == nil, luminanceDefaulted: maxL == nil || minL == nil)
        }
        return OutputSignal(colorimetry: colorimetry(forPrimaries: picturePrimaries), eotf: eotf, staticMetadata: meta,
                            primariesConversion: SDIPrimariesConversion(picturePrimaries: picturePrimaries,
                                                                        pictureTransfer: pictureTransfer))
    }

    /// The YCbCr matrix code SDI's v210 is encoded with: the picture's own (S6 L2), EXCEPT when D4 converts a
    /// P3-tagged picture to Rec.2020 primaries. That frame is signalled Rec.2020 and receivers decode it with the
    /// BT.2020 NCL matrix, so it is encoded with that matrix (CICP 9), whatever the source's matrix code (S7 follow-up
    /// 1, Robbie, 2026-10-22). A picture already tagged 2020 is not converted and keeps its own matrix code.
    public func sdiMatrixCode(pictureMatrix: Int?) -> Int? {
        primariesConversion != nil ? 9 : pictureMatrix
    }

    // MARK: Words (S7-3)

    /// The colorimetry as the Signal line says it: "Rec. 2020 (converted from P3 D65)" when D4 converts.
    public var colorimetryLabel: String {
        primariesConversion.map { "\(colorimetry.name) (converted from \($0.from.name))" } ?? colorimetry.name
    }

    /// The static metadata in words, or nil when none is sent:
    /// "mastering P3 D65 · 1000 / 0.0050 cd/m² (defaults) · MaxCLL 0 · MaxFALL 0 (unknown)".
    public var staticMetadataLabel: String? {
        guard let m = staticMetadata else { return nil }
        let k = m.mastering
        let gamut = Self.gamutName(k) ?? String(format: "R %.4f,%.4f G %.4f,%.4f B %.4f,%.4f W %.4f,%.4f",
                                                k.red.x, k.red.y, k.green.x, k.green.y, k.blue.x, k.blue.y,
                                                k.white.x, k.white.y)
        let lum = String(format: "%g / %.4f cd/m²", k.maxLuminance, k.minLuminance)
        let defaulted: String
        switch (m.primariesDefaulted, m.luminanceDefaulted) {
        case (true, true):   defaulted = " (defaults)"
        case (true, false):  defaulted = " (primaries: defaults)"
        case (false, true):  defaulted = " (luminance: defaults)"
        case (false, false): defaulted = ""
        }
        let unknown = (m.maxCLL == 0 || m.maxFALL == 0) ? " (0 = unknown)" : ""
        return "mastering \(gamut) · \(lum)\(defaulted) · MaxCLL \(m.maxCLL) · MaxFALL \(m.maxFALL)\(unknown)"
    }

    /// One line for the log: "PQ · Rec. 2020 · mastering P3 D65 · 1000 / 0.0050 cd/m² (defaults) · MaxCLL 0 · …".
    public var logLine: String {
        "\(eotf.name) · \(colorimetryLabel)" + (staticMetadataLabel.map { " · " + $0 } ?? "")
    }

    /// The named gamut whose primaries and white these are (to 4 decimals), else nil.
    static func gamutName(_ k: MasteringDisplay) -> String? {
        func near(_ a: Chromaticity, _ b: Chromaticity) -> Bool { abs(a.x - b.x) < 5e-5 && abs(a.y - b.y) < 5e-5 }
        for p in [ColorPrimaries.p3D65, .rec2020, .rec709, .dciP3] {
            let s = p.published
            if near(k.red, s.red), near(k.green, s.green), near(k.blue, s.blue), near(k.white, s.white) { return p.name }
        }
        return nil
    }
}
