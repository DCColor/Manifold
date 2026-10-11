//
//  FileChromaResolver.swift
//  FileChroma
//
//  Native chroma for FILES (CLAUDE.md; docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b S2): what a
//  file's chroma is, and the CoreVideo format that carries it. ONE answer per file, computed once at
//  load and handed to the scrub producer AND the playback source, so the two decode the same format
//  by construction (the "scrub frame = playback frame" property; docs/BUGS.md, the x420 TWO LOSSES
//  note). A leaf target so `swift test` reaches the tables and the box walks; ManifoldCore does the
//  CoreMedia and libav reads and calls in here.
//

import CoreVideo
import ColorimetryModel
import SPSColor

/// The resolver's answer for one file.
public struct ResolvedChroma: Equatable, Sendable {
    /// What both decoders are asked for: `x420`, `x422` or `x444` (10-bit biplanar, video range: the
    /// stored codes, unclipped; the shader does any range expansion, as it always has).
    public let pixelFormat: OSType
    /// What the file is. `.unknown` for a codec with no table (D8), never a guess.
    public let source: SourceChroma
    /// Why `pixelFormat` carries less than `source`, when it does. nil when native.
    public let reason: String?
    /// What the answer was read from, for the log: "ProRes apch", "avcC SPS chroma_format_idc 2",
    /// "libav yuv422p10le".
    public let basis: String

    public init(pixelFormat: OSType, source: SourceChroma, reason: String?, basis: String) {
        self.pixelFormat = pixelFormat
        self.source = source
        self.reason = reason
        self.basis = basis
    }

    /// Before any file, and for a file whose format could not be read at all.
    public static let undetermined = ResolvedChroma(
        pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, source: .notStated,
        reason: nil, basis: "no file")

    /// The `[CHROMA-FILE]` log line.
    public var logLine: String {
        let carried = ChromaSubsampling(pixelFormat: pixelFormat)?.label ?? "?"
        let src: String
        switch source {
        case .notStated: src = "not stated"
        case .unknown: src = "unknown"
        case .declared(let c): src = c.label
        }
        return "[CHROMA-FILE] source \(src) (\(basis)) → \(ChromaReadout.fourCC(pixelFormat)) \(carried)"
            + (reason.map { " — \($0)" } ?? "")
    }
}

public enum FileChromaResolver {

    /// The 10-bit biplanar video-range format for a chroma resolution.
    public static func pixelFormat(for chroma: ChromaSubsampling) -> OSType {
        switch chroma {
        case .c420: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .c422: return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .c444: return kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        }
    }

    /// The decision, from what the file is. Unknown carries 4:2:0 (D8): it is what every file got
    /// before S2, so a codec with no table behaves exactly as it did. `force420` is the DEBUG switch
    /// (`MANIFOLD_FORCE_CHROMA_420`), pushed in from the app with its reason.
    public static func resolve(_ source: SourceChroma, basis: String,
                               force420: Bool, forceReason: String) -> ResolvedChroma {
        guard case .declared(let chroma) = source else {
            return ResolvedChroma(pixelFormat: pixelFormat(for: .c420), source: source,
                                  reason: nil, basis: basis)
        }
        if force420, chroma > .c420 {
            return ResolvedChroma(pixelFormat: pixelFormat(for: .c420), source: source,
                                  reason: forceReason, basis: basis)
        }
        return ResolvedChroma(pixelFormat: pixelFormat(for: chroma), source: source,
                              reason: nil, basis: basis)
    }

    // MARK: - AVFoundation files: the codec type, and the SPS in avcC / hvcC

    /// What a file's codec type says, with the parameter-set atoms where the codec keeps its chroma
    /// in them. `atoms` is the format description's `SampleDescriptionExtensionAtoms`.
    public static func declared(codecType: FourCharCode, atoms: [String: [UInt8]])
        -> (source: SourceChroma, basis: String) {
        let name = fourCCName(codecType)
        if let proRes = proResChroma[name] {
            return (proRes.map { .declared($0) } ?? .unknown, "ProRes \(name)")
        }
        switch name {
        case "avc1", "avc3":
            guard let avcC = atoms["avcC"], let idc = h264ChromaFormatIdc(avcC: avcC) else {
                return (.unknown, "\(name), no readable SPS in avcC")
            }
            return (chroma(idc: idc), "avcC SPS chroma_format_idc \(idc)")
        case "hvc1", "hev1":
            guard let hvcC = atoms["hvcC"], let idc = hevcChromaFormatIdc(hvcC: hvcC) else {
                return (.unknown, "\(name), no readable SPS in hvcC")
            }
            return (chroma(idc: idc), "hvcC SPS chroma_format_idc \(idc)")
        default:
            // D8: AVC-Intra, XDCAM HD422, DVCPRO HD, MPEG-4 Part 2… no table, so no claim.
            return (.unknown, "no chroma table for \(name)")
        }
    }

    /// ProRes by fourCC. The 422 family is 4:2:2 and the 4444 family 4:4:4 by definition of the codec;
    /// ProRes RAW is Bayer (no chroma planes at all), so it is unknown rather than a guess.
    static let proResChroma: [String: ChromaSubsampling?] = [
        "apco": .c422, "apcs": .c422, "apcn": .c422, "apch": .c422,
        "ap4h": .c444, "ap4x": .c444,
        "aprn": nil, "aprh": nil,
    ]

    /// `chroma_format_idc` → chroma. 0 is monochrome: no chroma to keep, and no format of ours that
    /// names it, so it is unknown (carried as 4:2:0, which is what it always was).
    static func chroma(idc: Int) -> SourceChroma {
        switch idc {
        case 1: return .declared(.c420)
        case 2: return .declared(.c422)
        case 3: return .declared(.c444)
        default: return .unknown
        }
    }

    /// The first SPS in an `avcC` (ISO/IEC 14496-15 §5.3.3.1): version, profile, compatibility,
    /// level, lengthSizeMinusOne, then `numOfSequenceParameterSets` (low 5 bits), each a 16-bit
    /// length and the NAL.
    public static func h264ChromaFormatIdc(avcC: [UInt8]) -> Int? {
        guard avcC.count >= 8, avcC[0] == 1 else { return nil }
        let count = Int(avcC[5] & 0x1F)
        guard count > 0 else { return nil }
        let length = Int(avcC[6]) << 8 | Int(avcC[7])
        guard length > 0, 8 + length <= avcC.count else { return nil }
        return H264SPSColor.chromaFormatIdc(nal: avcC[8..<(8 + length)])
    }

    /// The first SPS (NAL type 33) in an `hvcC` (ISO/IEC 14496-15 §8.3.3.1): 22 bytes of
    /// configuration, `numOfArrays`, then per array a type byte, a 16-bit count, and per NAL a 16-bit
    /// length and the NAL.
    public static func hevcChromaFormatIdc(hvcC: [UInt8]) -> Int? {
        guard hvcC.count >= 23 else { return nil }
        var at = 23
        for _ in 0..<Int(hvcC[22]) {
            guard at + 3 <= hvcC.count else { return nil }
            let type = hvcC[at] & 0x3F
            let nalus = Int(hvcC[at + 1]) << 8 | Int(hvcC[at + 2])
            at += 3
            for _ in 0..<nalus {
                guard at + 2 <= hvcC.count else { return nil }
                let length = Int(hvcC[at]) << 8 | Int(hvcC[at + 1])
                at += 2
                guard at + length <= hvcC.count else { return nil }
                if type == 33, let format = HEVCSPSColor.format(nal: hvcC[at..<(at + length)]) {
                    return format.chromaFormatIdc
                }
                at += length
            }
        }
        return nil
    }

    // MARK: - libav files: the stream's pix_fmt

    /// From a libav pixel format's descriptor (`AVPixFmtDescriptor`): its chroma shifts and whether it
    /// is RGB. RGB (DNxHR 444's `gbrp1x`) has full-resolution colour: 4:4:4. A YUV format with fewer
    /// than three components (gray) is monochrome: unknown, like H.264's idc 0.
    public static func declared(pixFmtName name: String, log2ChromaW: Int, log2ChromaH: Int,
                                isRGB: Bool, components: Int) -> (source: SourceChroma, basis: String) {
        let basis = "libav \(name)"
        if isRGB { return (.declared(.c444), basis) }
        guard components >= 3 else { return (.unknown, basis) }
        switch (log2ChromaW, log2ChromaH) {
        case (0, 0): return (.declared(.c444), basis)
        case (1, 0): return (.declared(.c422), basis)
        case (1, 1): return (.declared(.c420), basis)
        default:     return (.unknown, basis)          // 4:1:1, 4:1:0: no format of ours names them
        }
    }

    static func fourCCName(_ code: FourCharCode) -> String {
        ChromaReadout.fourCC(code)
    }
}
