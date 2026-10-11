//
//  ChromaFormat.swift
//  ColorimetryModel
//
//  Native chroma, end to end (CLAUDE.md; docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b). The
//  chroma resolution a decoded buffer carries, what its source declared, how the DeckLink v210
//  output reduces it, and the chain readout's Chroma line. In the package so `swift test` reaches it;
//  the renderer and the readout only read it.
//

import CoreVideo

/// Chroma resolution relative to luma. Ordered: a 4:4:4 source carried as 4:2:0 has LOST chroma,
/// which is what the readout's "converted" wording keys on.
public enum ChromaSubsampling: Int, Comparable, Sendable, CaseIterable {
    case c420 = 0
    case c422 = 1
    case c444 = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .c420: return "4:2:0"
        case .c422: return "4:2:2"
        case .c444: return "4:4:4"
        }
    }

    /// The chroma a CoreVideo format carries. nil for anything the renderer does not sample (packed,
    /// single-plane and 16-bit formats). Only the 10-bit biplanar family is listed: those are the
    /// formats whose samples sit in the shader's MSB-aligned 10-bit domain.
    public init?(pixelFormat pf: OSType) {
        switch pf {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: self = .c420
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: self = .c422
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: self = .c444
        default: return nil
        }
    }
}

/// What a source has said about its chroma. Three states, for the same reason colour has its
/// provenance tiers: "the source said nothing" and "we could not tell" are different statements,
/// and neither may be shown as a fact.
public enum SourceChroma: Equatable, Sendable {
    /// No source has stated its chroma (S1: files and SRT, until S2/S3 resolve it).
    case notStated
    /// The source was looked at and its chroma could not be determined (D8: unknown AVF codecs).
    case unknown
    /// The source's own chroma.
    case declared(ChromaSubsampling)
}

/// How the DeckLink v210 output (4:2:2) takes chroma from the offscreen. Raw values are the
/// `chromaMode` uniform of `rgbToV210` in PassthroughShader.metal.
///
/// ⚠️ THE MODE FOLLOWS THE BUFFER THAT WAS RENDERED, NOT THE FILE. The offscreen is RGB, so the
/// kernel cannot see how much chroma the picture had; the renderer records it per ring slot.
public enum V210ChromaMode: UInt32, Sendable {
    /// Today's pair average of pixels 2k and 2k+1. For 4:2:0, and for anything not 4:2:2 / 4:4:4,
    /// so the 4:2:0 wire is byte-for-byte what it was (the 4:2:0 siting stage is separate, D4).
    case pairAverage = 0
    /// 4:2:2 source: the even pixel's own chroma. With the shader's cosited upsample that pixel
    /// holds chroma sample k exactly, so nothing is reduced: the wire carries the source's chroma.
    case cosited = 1
    /// 4:4:4 source: the one reduction, with a proper filter. D3's 7-tap cosited halfband,
    /// [−1, 0, 9, 16, 9, 0, −1] / 32, centred on the even pixel.
    case halfband = 2

    public init(carrying chroma: ChromaSubsampling?) {
        switch chroma {
        case .c422?: self = .cosited
        case .c444?: self = .halfband
        default:     self = .pairAverage
        }
    }

    /// D3's taps, offset −3…+3. Restated in the kernel; the test pins the two properties that make
    /// it a halfband: unity DC gain, and zero response at Nyquist (a one-pixel chroma alternation
    /// reduces to its mean instead of aliasing onto the wire).
    public static let halfbandTaps: [Int] = [-1, 0, 9, 16, 9, 0, -1]
    public static let halfbandDivisor = 32
}

/// The chain readout's Chroma line.
public enum ChromaReadout {

    /// - Parameters:
    ///   - carried: the pixel format of the last buffer the renderer drew; nil before the first.
    ///   - source: what the source declared.
    ///   - reason: why the carried chroma is lower than the source's, when a path said so.
    public static func text(carried: OSType?, source: SourceChroma, reason: String?) -> String {
        guard let carried else { return "no picture" }
        guard let chroma = ChromaSubsampling(pixelFormat: carried) else {
            return "\(fourCC(carried)) — not a format the renderer samples"
        }
        let head = "\(chroma.label) 10-bit (\(fourCC(carried)))"
        let tail = chroma == .c444 ? " · DeckLink v210 output: reduced once to 4:2:2 (halfband)" : ""
        switch source {
        case .notStated:
            return head + " — source chroma not stated" + tail
        case .unknown:
            return head + " — source chroma unknown" + tail
        case .declared(let declared) where declared == chroma:
            return head + " — native" + tail
        case .declared(let declared) where declared > chroma:
            // NEVER SILENT: a loss is stated with its reason, or as a conversion with none given.
            return head + " — \(declared.label) source, " + (reason ?? "converted at decode") + tail
        case .declared(let declared):
            return head + " — from a \(declared.label) source (upsampled at decode)" + tail
        }
    }

    public static func fourCC(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes.map { (32..<127).contains($0) ? $0 : UInt8(ascii: "?") },
                      encoding: .ascii) ?? "????"
    }
}
