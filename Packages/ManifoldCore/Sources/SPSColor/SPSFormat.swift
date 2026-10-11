//
//  SPSFormat.swift
//  SPSColor
//
//  What one SPS says about the SHAPE of its samples — chroma format and bit depths — for H.264 and
//  HEVC alike, and the SRT gate's rule on it (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b S3/S4;
//  decisions D6, D7). The colour is `SPSColor`'s; this is only what VideoToolbox will be asked to decode.
//
//  ── WHY THE PROFILE IS NOT THE TEST ────────────────────────────────────────────────────
//
//  Stage 3's HEVC gate asked for the Main or Main 10 profile. A profile is a family of tools, not a
//  sample format: x265's all-intra 4:2:0 10-bit stream signals "Main 10 Intra", a Range Extensions
//  profile (`general_profile_idc` 4), and was refused although it is exactly what Manifold plays
//  (docs/BUGS.md). The chroma format and the bit depths are in the SPS itself, so the gate reads those,
//  and whether VideoToolbox can decode the tools the profile allows is VideoToolbox's own answer, given
//  by its session (LiveVideoDecoder's "undecodable" report), not guessed from a name here.
//

/// Chroma format, bit depths and the profile (for the log and the banner) of one SPS.
public struct SPSFormat: Equatable, Sendable {

    public enum Codec: String, Sendable {
        case h264 = "H.264"
        case hevc = "HEVC"
    }

    public let codec: Codec
    /// `profile_idc` (H.264) or `general_profile_idc` (HEVC). For the log only.
    public let profileIdc: Int
    /// The profile by name, for the log and the banner. Never a decision.
    public let profileName: String
    /// 0 monochrome, 1 4:2:0, 2 4:2:2, 3 4:4:4.
    public let chromaFormatIdc: Int
    public let bitDepthLuma: Int
    public let bitDepthChroma: Int

    public init(codec: Codec, profileIdc: Int, profileName: String, chromaFormatIdc: Int,
                bitDepthLuma: Int, bitDepthChroma: Int) {
        self.codec = codec
        self.profileIdc = profileIdc
        self.profileName = profileName
        self.chromaFormatIdc = chromaFormatIdc
        self.bitDepthLuma = bitDepthLuma
        self.bitDepthChroma = bitDepthChroma
    }

    /// The deepest sample Manifold carries. The renderer's offscreen is `rgba16Float` and the DeckLink
    /// output v210, so 12-bit would be truncated on the way to both; D5 keeps it out until a float32
    /// offscreen is decided on its own.
    public static let maximumBitDepth = 10

    /// The SRT gate's rule (D6, D7): every chroma format Manifold carries natively, at up to 10 bits,
    /// whatever the profile is called. 4:0:0 is let through: VideoToolbox gives it neutral chroma in a
    /// 4:2:0 buffer, which is the picture, and nothing is lost.
    public enum Verdict: Equatable, Sendable {
        case accept
        /// More than `maximumBitDepth` on either plane (D5).
        case refuseBitDepth
    }

    public var verdict: Verdict {
        bitDepthLuma <= Self.maximumBitDepth && bitDepthChroma <= Self.maximumBitDepth ? .accept : .refuseBitDepth
    }

    /// "4:2:0", "4:2:2", "4:4:4", or "4:0:0" (monochrome).
    public var chromaName: String {
        switch chromaFormatIdc {
        case 0:  return "4:0:0"
        case 1:  return "4:2:0"
        case 2:  return "4:2:2"
        default: return "4:4:4"
        }
    }

    /// "10-bit", or "10/8-bit" when the planes differ.
    public var depthName: String {
        bitDepthLuma == bitDepthChroma ? "\(bitDepthLuma)-bit" : "\(bitDepthLuma)/\(bitDepthChroma)-bit"
    }

    /// The gate's log text: "Main 10 (general_profile_idc 2), 4:2:0, 10-bit luma / 10-bit chroma" —
    /// Stage 3's HEVC wording, unchanged, so a 4:2:0 HEVC log reads as it did.
    public var described: String {
        let idcName = codec == .hevc ? "general_profile_idc" : "profile_idc"
        return "\(profileName) (\(idcName) \(profileIdc)), \(chromaName), "
            + "\(bitDepthLuma)-bit luma / \(bitDepthChroma)-bit chroma"
    }
}

extension HEVCSPSFormat {
    /// The codec-neutral form the SRT gate judges.
    public var neutral: SPSFormat {
        SPSFormat(codec: .hevc, profileIdc: generalProfileIdc, profileName: profileName,
                  chromaFormatIdc: chromaFormatIdc, bitDepthLuma: bitDepthLuma, bitDepthChroma: bitDepthChroma)
    }
}

extension H264SPSColor {

    /// Chroma format, bit depths and profile of one H.264 SPS NAL (same framing as `parse`). nil when
    /// this is not an SPS or it ends, or is out of range, before the bit depths. Profiles without the
    /// high-profile block are 4:2:0 8-bit by definition (§7.4.2.1.1: absent `chroma_format_idc` is 1,
    /// absent bit depths are 8).
    public static func format<Bytes: Collection>(nal: Bytes) -> SPSFormat? where Bytes.Element == UInt8 {
        guard nal.count >= 5, let header = nal.first, header & 0x80 == 0, header & 0x1F == 7,
              nal.count <= SPSColor.maximumSPSBytes else { return nil }
        var r = BitReader(rbsp: SPSColor.unescape(nal.dropFirst()))
        let profileIdc = r.bits(8)
        let constraints = r.bits(8)
        _ = r.bits(8)                                   // level_idc
        guard r.ue() <= 31, !r.overrun else { return nil }   // seq_parameter_set_id
        var chromaFormatIdc = 1, lumaMinus8 = 0, chromaMinus8 = 0
        if highProfiles.contains(profileIdc) {
            chromaFormatIdc = r.ue()
            guard chromaFormatIdc <= 3 else { return nil }
            if chromaFormatIdc == 3 { _ = r.bit() }     // separate_colour_plane_flag
            lumaMinus8 = r.ue()                         // bit_depth_luma_minus8: 0…6
            chromaMinus8 = r.ue()                       // bit_depth_chroma_minus8: 0…6
            guard lumaMinus8 <= 6, chromaMinus8 <= 6, !r.overrun else { return nil }
        }
        return SPSFormat(codec: .h264, profileIdc: profileIdc,
                         profileName: profileName(profileIdc: profileIdc, constraintSet3: constraints & 0x10 != 0),
                         chromaFormatIdc: chromaFormatIdc,
                         bitDepthLuma: lumaMinus8 + 8, bitDepthChroma: chromaMinus8 + 8)
    }

    /// H.264 Annex A's profile names, for the log and the banner. `constraint_set3_flag` makes the
    /// High 10 / 4:2:2 / 4:4:4 profiles their Intra variants (A.2.8–A.2.11).
    static func profileName(profileIdc: Int, constraintSet3: Bool) -> String {
        let intra = constraintSet3 ? " Intra" : ""
        switch profileIdc {
        case 66:  return "Baseline"
        case 77:  return "Main"
        case 88:  return "Extended"
        case 100: return "High"
        case 110: return "High 10" + intra
        case 122: return "High 4:2:2" + intra
        case 244: return "High 4:4:4 Predictive" + (constraintSet3 ? " (Intra)" : "")
        case 44:  return "CAVLC 4:4:4 Intra"
        default:  return "profile \(profileIdc)"
        }
    }
}
