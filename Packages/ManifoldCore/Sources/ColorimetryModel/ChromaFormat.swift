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

    /// The 10-bit biplanar video-range format that carries this chroma: `x420`, `x422`, `x444` — the
    /// renderer's sample domain (stored codes; the shader does any range expansion).
    public var carrierPixelFormat: OSType {
        switch self {
        case .c420: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .c422: return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .c444: return kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        }
    }

    /// An SPS's `chroma_format_idc` (H.264 and HEVC agree): 1 4:2:0, 2 4:2:2, 3 4:4:4. nil for 0
    /// (monochrome: no chroma planes, and no format of ours names it) and anything else.
    public init?(chromaFormatIdc idc: Int) {
        switch idc {
        case 1: self = .c420
        case 2: self = .c422
        case 3: self = .c444
        default: return nil
        }
    }

    /// The chroma ANY YCbCr format carries — 8-bit, 10-bit, biplanar, packed, either range — for the
    /// live promote, which keeps the chroma a decoder delivered and changes only the layout and depth
    /// (Stage 3b S3). nil for a format whose chroma this table does not know.
    public init?(deliveredFormat pf: OSType) {
        if let carried = ChromaSubsampling(pixelFormat: pf) { self = carried; return }
        switch pf {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,             // 420v
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,              // 420f
             kCVPixelFormatType_420YpCbCr8Planar,                         // y420
             kCVPixelFormatType_420YpCbCr8PlanarFullRange,                // f420
             Self.p420:
            self = .c420
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,             // 422v
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,              // 422f
             kCVPixelFormatType_422YpCbCr8,                               // 2vuy
             kCVPixelFormatType_422YpCbCr8_yuvs,                          // yuvs
             kCVPixelFormatType_422YpCbCr10,                              // v210
             Self.p422,                                                   // VT's native HEVC 4:2:2
             kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:            // sv22
            self = .c422
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,             // 444v
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,              // 444f
             kCVPixelFormatType_444YpCbCr10,                              // v410
             Self.p444,
             kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:            // sv44
            self = .c444
        default:
            return nil
        }
    }

    /// VideoToolbox's native 10-bit hardware output: PACKED biplanar 4:2:0 / 4:2:2 / 4:4:4, which Metal
    /// cannot sample as r16/rg16 (audit). CoreVideo's header names no constant for them.
    static let p420: OSType = 0x7034_3230   // 'p420'
    static let p422: OSType = 0x7034_3232   // 'p422'
    static let p444: OSType = 0x7034_3434   // 'p444'

    /// What a live decoder asks VideoToolbox for (Stage 3b S3/S4): the SPS's own chroma, in its 10-bit
    /// biplanar carrier. `x420` when there is no SPS chroma to go by (none yet, unreadable, or 4:0:0) —
    /// which is what every live decode requested before S3, so a 4:2:0 stream (every WHEP stream) asks
    /// for exactly what it always did. `force420` is the DEBUG switch (`MANIFOLD_FORCE_CHROMA_420`).
    public static func liveDecodeRequest(chromaFormatIdc idc: Int?, force420: Bool) -> OSType {
        guard !force420, let idc, let chroma = ChromaSubsampling(chromaFormatIdc: idc) else {
            return ChromaSubsampling.c420.carrierPixelFormat
        }
        return chroma.carrierPixelFormat
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
    ///   - note: a fact about the decode that is not a chroma loss, appended as " · note" — today only
    ///     "software decode" (SRT, Stage 3b S3: VideoToolbox's session reports no hardware decoder).
    public static func text(carried: OSType?, source: SourceChroma, reason: String?,
                            note: String? = nil) -> String {
        guard let carried else { return "no picture" }
        guard let chroma = ChromaSubsampling(pixelFormat: carried) else {
            return "\(fourCC(carried)) — not a format the renderer samples" + (note.map { " · \($0)" } ?? "")
        }
        let head = "\(chroma.label) 10-bit (\(fourCC(carried)))"
        let tail = (chroma == .c444 ? " · DeckLink v210 output: reduced once to 4:2:2 (halfband)" : "")
            + (note.map { " · \($0)" } ?? "")
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
