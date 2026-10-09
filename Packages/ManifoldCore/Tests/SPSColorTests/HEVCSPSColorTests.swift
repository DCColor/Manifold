//
//  HEVCSPSColorTests.swift
//  SPSColorTests
//
//  The HEVC SPS colour reader against SPS bytes from real encoders, and synthetic ones where no
//  encoder here writes the syntax (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 2).
//
//  Real: x265 4.2 and hevc_videotoolbox through the system ffmpeg 8.1.1, and ffmpeg's hevc_metadata
//  bitstream filter rewriting their VUI. SYNTHETIC (marked below): x265 4.2 writes no SPS reference
//  picture sets, and no encoder here writes PCM, long-term references, scaling-list data, sub-layer
//  profile/level bodies, or an SPS without a VUI or a video_signal_type. Those SPS were written field
//  by field to H.265 §7.3.2.2.1 from x265 PQ's values, and each is accepted by two independent FFmpeg
//  parsers: CBS (`trace_headers`) and the hevc decoder's own SPS parser, which reports an overread
//  on a desynchronised SPS (checked with a deliberately broken one).
//
//  EVERY EXPECTED VALUE IS FFMPEG'S READING, NOT THIS READER'S: generated from
//  `ffmpeg -f hevc -i x.hevc -c copy -bsf:v trace_headers -f null -`, including every structural
//  field in `walk` (NumDeltaPocs from FFmpeg's own num_negative/positive_pics, used_by_curr_pic_flag
//  and use_delta_flag values).
//

import XCTest
@testable import SPSColor

final class HEVCSPSColorTests: XCTestCase {

    private typealias Walk = HEVCSPSColor.Walk

    private struct Fixture {
        let name: String
        let sps: [UInt8]
        let reach: SPSColor.Reach
        let primaries: Int?
        let transfer: Int?
        let matrix: Int?
        let fullRange: Bool?
        let walk: Walk

        init(_ name: String, _ hex: String, reach: SPSColor.Reach,
             primaries: Int?, transfer: Int?, matrix: Int?, fullRange: Bool?, walk: Walk) {
            self.name = name
            var bytes: [UInt8] = []
            var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                bytes.append(UInt8(hex[i..<j], radix: 16)!)
                i = j
            }
            sps = bytes
            self.reach = reach
            self.primaries = primaries; self.transfer = transfer; self.matrix = matrix
            self.fullRange = fullRange
            self.walk = walk
        }

        var expected: SPSColor {
            SPSColor(reach: reach, colourPrimaries: primaries, transferCharacteristics: transfer,
                     matrixCoefficients: matrix, videoFullRangeFlag: fullRange)
        }
    }

    private let fixtures: [Fixture] = [
        // x265 4.2 Main, bt709 ×3
        Fixture("x265_709", "42010101600000030090000003000003003ca00a080b9f796566924caf016a02020208000003000800000300c840",
                reach: .colourDescription, primaries: 1, transfer: 1, matrix: 1, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main 10, bt2020 / smpte2084 / bt2020nc, hdr10=1 (MDCV and CLL SEI)
        Fixture("x265_pq", "42010102200000030090000003000003003ca00a080b9f6d96566924caf016a122012080000003008000000c84",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main 10, bt2020 / arib-std-b67 / bt2020nc
        Fixture("x265_hlg", "42010102200000030090000003000003003ca00a080b9f6d96566924caf016a122412080000003008000000c84",
                reach: .colourDescription, primaries: 9, transfer: 18, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main, smpte170m ×3
        Fixture("x265_601", "42010101600000030090000003000003003ca00a080b9f796566924caf016a0c0c0c08000003000800000300c840",
                reach: .colourDescription, primaries: 6, transfer: 6, matrix: 6, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main, bt470bg / smpte170m / bt470bg (matrix 5)
        Fixture("x265_m5", "42010101600000030090000003000003003ca00a080b9f796566924caf016a0a0c0a08000003000800000300c840",
                reach: .colourDescription, primaries: 5, transfer: 6, matrix: 5, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main, no colour flags: video_signal_type present, no colour description
        Fixture("x265_plain", "42010101600000030090000003000003003ca00a080b9f796566924caf016808000003000800000300c840",
                reach: .noColourDescription, primaries: nil, transfer: nil, matrix: nil, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main, range=full, no colour flags
        Fixture("x265_full", "42010101600000030090000003000003003ca00a080b9f796566924caf016c08000003000800000300c840",
                reach: .noColourDescription, primaries: nil, transfer: nil, matrix: nil, fullRange: true,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main 10 PQ, temporal-layers=3: 3 sub-layers, sub-layer profile/level flags 0 (the reserved_zero_2bits padding)
        Fixture("x265_tl", "42010402200000030090000003000003003c0000a00a080b9f6d965652b295964932bc05a84880482000000300200000030321",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 2, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main 10 PQ, scaling-list=default: scaling_list_enabled 1, no list data
        Fixture("x265_sldef", "42010102200000030090000003000003003ca00a080b9f6d96566924e5780b5091009040000003004000000642",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: true, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main 4:2:2 10 (profile 4, chroma_format_idc 2), PQ
        Fixture("x265_422", "4201010408000003009d0800000300003cb00a080b9f2b65959a4932bc05a84880482000000300200000030321",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 2, width: 320, height: 184, confWin: [0, 0, 0, 4], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main 4:4:4 10 (chroma_format_idc 3, separate_colour_plane_flag 0), bt709 ×3
        Fixture("x265_444", "4201010408000003009c0800000300003c9001410173e56cb2b349265780b5010101040000030004000003006420",
                reach: .colourDescription, primaries: 1, transfer: 1, matrix: 1, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 3, width: 320, height: 184, confWin: [0, 0, 0, 4], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265 Main 10 HLG, preset slower
        Fixture("x265_slow", "42010102200000030090000003000003003ca00a080b9f6d96662a491b6bc05a848904820000030002000003003210",
                reach: .colourDescription, primaries: 9, transfer: 18, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // hevc_videotoolbox Main, 1920×1088 with a 4-row conformance window, 4 explicit RPS; writes 2/2/2
        Fixture("vt_plain", "420101016000000300b00000030000030078a003c0801107cb881bb916452ffcb9fc4feb016a04040401",
                reach: .colourDescription, primaries: 2, transfer: 2, matrix: 2, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 1920, height: 1088, confWin: [0, 0, 0, 4], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 7, scalingListEnabled: true, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [4, 1, 2, 3], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // hevc_videotoolbox Main 10 asked for bt2020/smpte2084/bt2020nc: it writes only the matrix (2/2/9)
        Fixture("vt_pq", "420101022000000300b00000030000030078a003c0801107cad881bb916452ffcb9fc4feb016a040412010",
                reach: .colourDescription, primaries: 2, transfer: 2, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 1920, height: 1088, confWin: [0, 0, 0, 4], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 7, scalingListEnabled: true, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [4, 1, 2, 3], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // vt_pq through hevc_metadata 9/16/9
        Fixture("vt_pq_meta", "420101022000000300b00000030000030078a003c0801107cad881bb916452ffcb9fc4feb016a122012010",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 1920, height: 1088, confWin: [0, 0, 0, 4], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 7, scalingListEnabled: true, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [4, 1, 2, 3], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265_709 + hevc_metadata 2/2/2: colour description present, every axis unspecified
        Fixture("meta_222", "42010101600000030090000003000003003ca00a080b9f796566924caf016a04040408000003000800000300c840",
                reach: .colourDescription, primaries: 2, transfer: 2, matrix: 2, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265_709 + hevc_metadata 9/2/9: transfer unspecified
        Fixture("meta_929", "42010101600000030090000003000003003ca00a080b9f796566924caf016a12041208000003000800000300c840",
                reach: .colourDescription, primaries: 9, transfer: 2, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265_709 + hevc_metadata 3/0/3: reserved on every axis
        Fixture("meta_303", "42010101600000030090000003000003003ca00a080b9f796566924caf016a06000608000003000800000300c840",
                reach: .colourDescription, primaries: 3, transfer: 0, matrix: 3, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265_709 + hevc_metadata 200/100/99: reserved on every axis
        Fixture("meta_high", "42010101600000030090000003000003003ca00a080b9f796566924caf016b90c8c608000003000800000300c840",
                reach: .colourDescription, primaries: 200, transfer: 100, matrix: 99, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265_709 + hevc_metadata 12/13/0: matrix 0 (identity) is a declaration
        Fixture("meta_identity", "42010101600000030090000003000003003ca00a080b9f796566924caf016a181a0008000003000800000300c840",
                reach: .colourDescription, primaries: 12, transfer: 13, matrix: 0, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 0, bitDepthChromaMinus8: 0, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // x265_pq + hevc_metadata sample_aspect_ratio=256/1: Extended_SAR before the colour fields
        Fixture("meta_sar256", "42010102200000030090000003000003003ca00a080b9f6d96566924cafff010000016a122012080000003008000000c84",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 255, sarWidth: 256, sarHeight: 1)),
        // SYNTHETIC. HM random-access GOP-8: set 0 explicit, sets 1–7 inter-predicted from the set before; two entries not used by the current picture
        Fixture("synth_interRPS", "42010102200000030090000003000003003ca00a080b9f6d96662a491b612588aa93130cbecfaf3772cbd78f016a12201201",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [4, 3, 4, 4, 4, 4, 4, 4], numInterPredicted: 7, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // SYNTHETIC. The same 8 sets, all explicit
        Fixture("synth_explicitRPS", "42010102200000030090000003000003003ca00a080b9f6d96662a491b612588aa92689524daaa9244f524deb922255453793a08b527780b5091009008",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [4, 3, 4, 4, 4, 4, 4, 4], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // SYNTHETIC. 3 sub-layers: sub-layer 0 profile + level, sub-layer 1 level only (88- and 8-bit bodies)
        Fixture("synth_subLayers", "42010502200000030090000003000003003cd00002200000030090000003000003003c3ca00a080b9f6d966628cc5198a9246daf016a12201201",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 2, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // SYNTHETIC. scaling_list_data(): coded, predicted and default matrices; DC terms at 16×16 and 32×32
        Fixture("synth_scalingLists", "42010102200000030090000003000003003ca00a080b9f6d96662a491be10318c6318c6318c63012cc4c2c6318c6318c6318c04b3189870c6318c6318c63012cc6318c6318c63180966318c6318c6318c04b318c6318c6318c63012cc6318c6318c63130446318c6318c63012cc6318c6318c63180966318c6318c6318c04b318c6318c6318c63012cc6318c6318c63189850286318c6318c602598c6318c6318c63012cc6318c6318c63180966318c6318c6318c602598c6318c6318c63012c9850346318c6318c04b318c6318c6318c602598c6318c6318c63012cc6318c6318c6318c04b318c6318c6318c60259898583c6318c63180966318c6318c6318c04b318c6318c6318c602598c6318c6318c63180966318c6318c6318c04b31a160486318c63012cc6318c6318c63180966318c6318c6318c04b318c6318c6318c63012cc6318c6318c6318096631b5e02d424402402",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: true, scalingListDataPresent: true, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // SYNTHETIC. pcm_enabled_flag 1 with its five fields
        Fixture("synth_pcm", "42010102200000030090000003000003003ca00a080b9f6d96662a491b777b5e02d424402402",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: true, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // SYNTHETIC. 3 long-term reference pictures (lt_ref_pic_poc_lsb_sps at 8 bits)
        Fixture("synth_longTerm", "42010102200000030090000003000003003ca00a080b9f6d96662a491b6c80b827ffc05a8488048040",
                reach: .colourDescription, primaries: 9, transfer: 16, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 3, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // SYNTHETIC. vui_parameters_present_flag 0
        Fixture("synth_noVUI", "42010102200000030090000003000003003ca00a080b9f6d96662a491b6b20",
                reach: .noVUI, primaries: nil, transfer: nil, matrix: nil, fullRange: nil,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: nil, sarWidth: nil, sarHeight: nil)),
        // SYNTHETIC. VUI present, video_signal_type_present_flag 0
        Fixture("synth_noVST", "42010102200000030090000003000003003ca00a080b9f6d96662a491b6bc04008",
                reach: .noVideoSignalType, primaries: nil, transfer: nil, matrix: nil, fullRange: nil,
                walk: Walk(maxSubLayersMinus1: 0, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: false, scalingListDataPresent: false, pcmEnabled: false, numDeltaPocs: [], numInterPredicted: 0, numLongTermRefPicsSps: 0, aspectRatioIdc: 1, sarWidth: nil, sarHeight: nil)),
        // SYNTHETIC. All of the above at once, with Extended_SAR 256/1 and HLG
        Fixture("synth_all", "42010502200000030090000003000003003c60003c0220000003009000000300000300a00a080b9f6d966628cc5198a9246f840c6318c6318c6318c04b3130b18c6318c6318c63012cc6261c318c6318c6318c04b318c6318c6318c602598c6318c6318c63012cc6318c6318c6318c04b318c6318c6318c4c1118c6318c6318c04b318c6318c6318c602598c6318c6318c63012cc6318c6318c6318c04b318c6318c6318c626140a18c6318c63180966318c6318c6318c04b318c6318c6318c602598c6318c6318c63180966318c6318c6318c04b26140d18c6318c63012cc6318c6318c63180966318c6318c6318c04b318c6318c6318c63012cc6318c6318c6318096626160f18c6318c602598c6318c6318c63012cc6318c6318c63180966318c6318c6318c602598c6318c6318c63012cc68581218c6318c04b318c6318c6318c602598c6318c6318c63012cc6318c6318c6318c04b318c6318c6318c602598c6eef612588aa93130cbecfaf3772cbd7960b827ff80800000b5091209008",
                reach: .colourDescription, primaries: 9, transfer: 18, matrix: 9, fullRange: false,
                walk: Walk(maxSubLayersMinus1: 2, chromaFormatIdc: 1, width: 320, height: 184, confWin: [0, 0, 0, 2], bitDepthLumaMinus8: 2, bitDepthChromaMinus8: 2, log2MaxPocLsbMinus4: 4, scalingListEnabled: true, scalingListDataPresent: true, pcmEnabled: true, numDeltaPocs: [4, 3, 4, 4, 4, 4, 4, 4], numInterPredicted: 7, numLongTermRefPicsSps: 2, aspectRatioIdc: 255, sarWidth: 256, sarHeight: 1)),
    ]

    private func fixture(_ name: String) -> Fixture { fixtures.first { $0.name == name }! }

    // MARK: Prediction 1 — every field of every fixture against FFmpeg's reading

    func testEveryFixtureMatchesFFmpegsReading() {
        XCTAssertEqual(fixtures.count, 30)
        for f in fixtures {
            let (color, walk) = HEVCSPSColor.walk(nal: f.sps)
            XCTAssertEqual(color, f.expected, f.name)
            XCTAssertEqual(walk, f.walk, f.name)
            XCTAssertEqual(HEVCSPSColor.parse(nal: f.sps), color, f.name)
        }
    }

    // MARK: Per-axis verdict — absent, unspecified (2) and reserved are undeclared

    private func verdict(_ name: String) -> [Int?] {
        let r = HEVCSPSColor.parse(nal: fixture(name).sps)
        return [r.primaries, r.transfer, r.matrix]
    }

    func testDeclaredFixtures() {
        XCTAssertEqual(verdict("x265_709"), [1, 1, 1])
        XCTAssertEqual(verdict("x265_pq"), [9, 16, 9])
        XCTAssertEqual(verdict("x265_hlg"), [9, 18, 9])
        XCTAssertEqual(verdict("x265_601"), [6, 6, 6])
        XCTAssertEqual(verdict("x265_m5"), [5, 6, 5])
        XCTAssertEqual(verdict("x265_422"), [9, 16, 9])
        XCTAssertEqual(verdict("vt_pq_meta"), [9, 16, 9])
        XCTAssertEqual(verdict("synth_all"), [9, 18, 9])
    }

    func testUndeclaredAndPartial() {
        XCTAssertEqual(verdict("vt_plain"), [nil, nil, nil])     // VideoToolbox writes 2/2/2
        XCTAssertEqual(verdict("vt_pq"), [nil, nil, 9])          // …and only the matrix when asked for PQ
        XCTAssertEqual(verdict("meta_222"), [nil, nil, nil])
        XCTAssertEqual(verdict("meta_929"), [9, nil, 9])         // judged per axis, not as a triple
        XCTAssertEqual(verdict("meta_303"), [nil, nil, nil])     // 3 / 0 / 3
        XCTAssertEqual(verdict("meta_high"), [nil, nil, nil])    // 200 / 100 / 99
        XCTAssertEqual(verdict("meta_identity"), [12, 13, 0])    // matrix 0 is Identity, declared
        for name in ["x265_plain", "x265_full", "synth_noVUI", "synth_noVST"] {
            XCTAssertEqual(verdict(name), [nil, nil, nil], name)
        }
        XCTAssertEqual(HEVCSPSColor.parse(nal: fixture("x265_full").sps).videoFullRangeFlag, true)
    }

    // MARK: Prediction 2 — every prefix: exact, or malformed; never a different colour

    func testEveryTruncationIsMalformedOrExact() {
        for f in fixtures {
            for n in 0..<f.sps.count {
                let r = HEVCSPSColor.parse(nal: f.sps.prefix(n))
                let axes = [r.primaries, r.transfer, r.matrix]
                XCTAssertTrue(axes == [nil, nil, nil] || axes == [f.expected.primaries, f.expected.transfer, f.expected.matrix],
                              "\(f.name) cut at \(n): \(axes)")
                XCTAssertTrue(r == f.expected || r.reach == .malformed || r.reach == .notAnSPS,
                              "\(f.name) cut at \(n): \(r)")
            }
        }
    }

    // MARK: Prediction 3 — broken readers fail closed

    private func assertFailsClosed(_ mutant: HEVCSPSColor.Mutant, touches: (Fixture) -> Bool,
                                   file: StaticString = #filePath, line: UInt = #line) {
        var touched = 0
        for f in fixtures {
            let r = HEVCSPSColor.walk(nal: f.sps, mutant: mutant).color
            let truth = [f.expected.primaries, f.expected.transfer, f.expected.matrix]
            let axes = [r.primaries, r.transfer, r.matrix]
            if touches(f) {
                touched += 1
                // The defect must show, and must show as undeclared: never a colour.
                XCTAssertEqual(axes, [nil, nil, nil], "\(mutant) on \(f.name): \(r)", file: file, line: line)
                XCTAssertNotEqual(r, f.expected, "\(mutant) went unnoticed on \(f.name)", file: file, line: line)
            } else {
                XCTAssertEqual(axes, truth, "\(mutant) on untouched \(f.name): \(r)", file: file, line: line)
            }
        }
        XCTAssertGreaterThan(touched, 0, file: file, line: line)
    }

    func testMutantWithoutEmulationPreventionRemovalFailsClosed() {
        // Every fixture has 00 00 03 inside profile_tier_level.
        assertFailsClosed(.keepEmulationPrevention) { _ in true }
    }

    func testMutantThatSkipsTheReferencePictureSetsFailsClosed() {
        assertFailsClosed(.skipShortTermRefPicSets) { !$0.walk.numDeltaPocs.isEmpty }
    }

    func testMutantThatReadsInterPredictionAsExplicitFailsClosed() {
        assertFailsClosed(.interPredictionReadAsExplicit) { $0.walk.numInterPredicted > 0 }
    }

    // MARK: Not an SPS, or not ours

    func testNotAnSPS() {
        let pq = fixture("x265_pq").sps
        XCTAssertEqual(HEVCSPSColor.parse(nal: [UInt8]()).reach, .notAnSPS)
        XCTAssertEqual(HEVCSPSColor.parse(nal: Array(pq.prefix(3))).reach, .notAnSPS)
        // A VPS (32) or a PPS (34) must not parse as an SPS, however plausible its bytes.
        for type: UInt8 in [32, 34] {
            var other = pq
            other[0] = type << 1
            XCTAssertEqual(HEVCSPSColor.parse(nal: other).reach, .notAnSPS)
        }
        // An H.264 SPS is not an HEVC one.
        XCTAssertEqual(HEVCSPSColor.parse(nal: [0x67, 0x64, 0x00, 0x0c, 0xac, 0xb2]).reach, .notAnSPS)
        // forbidden_zero_bit set.
        var forbidden = pq
        forbidden[0] |= 0x80
        XCTAssertEqual(HEVCSPSColor.parse(nal: forbidden).reach, .notAnSPS)
        // nuh_layer_id 1 and 32: an enhancement layer's SPS has a different syntax (decision 8).
        var layer1 = pq
        layer1[1] |= 0x08
        XCTAssertEqual(HEVCSPSColor.parse(nal: layer1).reach, .notAnSPS)
        var layer32 = pq
        layer32[0] |= 0x01
        XCTAssertEqual(HEVCSPSColor.parse(nal: layer32).reach, .notAnSPS)
        // nuh_temporal_id_plus1 0 is forbidden.
        var tid0 = pq
        tid0[1] &= 0xF8
        XCTAssertEqual(HEVCSPSColor.parse(nal: tid0).reach, .notAnSPS)
    }

    func testGarbageNeverTrapsAndNeverDeclaresByAccident() {
        // Deterministic pseudo-random SPS-typed garbage. The reader must return for every one; the
        // bounds are what keep a desynchronised parse from walking into the colour fields.
        var state: UInt32 = 0x2545F491
        func next() -> UInt8 { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return UInt8(state & 0xFF) }
        var malformed = 0, declared = 0
        for length in 4..<96 {
            for _ in 0..<200 {
                var bytes: [UInt8] = [0x42, 0x01]
                for _ in 2..<length { bytes.append(next()) }
                let r = HEVCSPSColor.parse(nal: bytes)
                if r.reach == .malformed { malformed += 1 }
                if r.primaries != nil || r.transfer != nil || r.matrix != nil { declared += 1 }
            }
        }
        XCTAssertGreaterThan(malformed, 0)
        // Random bytes almost never get through every bound. Recorded, not a threshold: printed so
        // the rate is visible in the test log.
        print("HEVC garbage: \(malformed) malformed, \(declared) with any declared axis, of \(92 * 200)")
        // All zeros: an unbounded ue() would spin here.
        XCTAssertEqual(HEVCSPSColor.parse(nal: [0x42, 0x01] + [UInt8](repeating: 0, count: 200)).reach, .malformed)
        // Oversized.
        XCTAssertEqual(HEVCSPSColor.parse(nal: [0x42, 0x01] + [UInt8](repeating: 0xFF, count: 2000)).reach, .malformed)
    }

    func testArraySliceInputMatchesArrayInput() {
        // The transports hand over Data; slices and arrays must read identically.
        let f = fixture("synth_all")
        let padded = [UInt8(0xAA)] + f.sps + [0xBB]
        XCTAssertEqual(HEVCSPSColor.parse(nal: padded[1..<(padded.count - 1)]), HEVCSPSColor.parse(nal: f.sps))
    }

    // MARK: The format — what the SRT gate decides on (§6.10, Stage 3; decision 7)

    func testFormatAgreesWithTheVerifiedWalkOnEveryFixture() {
        // Chroma format and bit depths come from the same walk Stage 2 checked against trace_headers,
        // so they must agree with it on all thirty. The profile is checked against the bitstream's own
        // byte: header (2), then vps_id/max_sub_layers/nesting (1), then space(2) tier(1) idc(5).
        for f in fixtures {
            guard let format = HEVCSPSColor.format(nal: f.sps) else { XCTFail("\(f.name): no format"); continue }
            XCTAssertEqual(format.chromaFormatIdc, f.walk.chromaFormatIdc, f.name)
            XCTAssertEqual(format.bitDepthLuma, f.walk.bitDepthLumaMinus8 + 8, f.name)
            XCTAssertEqual(format.bitDepthChroma, f.walk.bitDepthChromaMinus8 + 8, f.name)
            XCTAssertEqual(format.generalProfileIdc, Int(f.sps[3] & 0x1F), f.name)
        }
    }

    func testFormatVerdicts() {
        func format(_ name: String) -> HEVCSPSFormat { HEVCSPSColor.format(nal: fixture(name).sps)! }
        // Main 10, 4:2:0: x265 and VideoToolbox alike.
        for name in ["x265_pq", "x265_hlg", "vt_pq", "vt_pq_meta", "synth_all"] {
            let f = format(name)
            XCTAssertEqual(f.profileName, "Main 10", name)
            XCTAssertEqual(f.chromaName, "4:2:0", name)
            XCTAssertTrue(f.isSupported420, name)
        }
        // Main (8-bit), 4:2:0.
        XCTAssertEqual(format("vt_plain").profileName, "Main")
        XCTAssertTrue(format("vt_plain").isSupported420)
        XCTAssertEqual(format("vt_plain").bitDepthLuma, 8)
        // Format Range Extensions: 4:2:2 and 4:4:4 are refused, and named.
        let f422 = format("x265_422"), f444 = format("x265_444")
        XCTAssertEqual([f422.generalProfileIdc, f422.chromaFormatIdc, f422.bitDepthLuma], [4, 2, 10])
        XCTAssertEqual([f444.generalProfileIdc, f444.chromaFormatIdc, f444.bitDepthLuma], [4, 3, 10])
        XCTAssertEqual(f422.chromaName, "4:2:2")
        XCTAssertEqual(f444.chromaName, "4:4:4")
        XCTAssertFalse(f422.isSupported420)
        XCTAssertFalse(f444.isSupported420)
        // The rule, on its own terms: a RExt 4:2:0 stream is refused, a Main Still Picture stream that
        // signals Main compatibility is not, and 12-bit is refused whatever the profile says.
        XCTAssertFalse(HEVCSPSFormat(generalProfileIdc: 4, generalProfileCompatibility: 1 << 27,
                                     chromaFormatIdc: 1, bitDepthLuma: 12, bitDepthChroma: 12).isSupported420)
        XCTAssertFalse(HEVCSPSFormat(generalProfileIdc: 4, generalProfileCompatibility: 1 << 27,
                                     chromaFormatIdc: 1, bitDepthLuma: 10, bitDepthChroma: 10).isSupported420)
        XCTAssertTrue(HEVCSPSFormat(generalProfileIdc: 3, generalProfileCompatibility: (1 << 30) | (1 << 28),
                                    chromaFormatIdc: 1, bitDepthLuma: 8, bitDepthChroma: 8).isSupported420)
        XCTAssertFalse(HEVCSPSFormat(generalProfileIdc: 2, generalProfileCompatibility: 1 << 29,
                                     chromaFormatIdc: 1, bitDepthLuma: 12, bitDepthChroma: 10).isSupported420)
        XCTAssertFalse(HEVCSPSFormat(generalProfileIdc: 1, generalProfileCompatibility: 1 << 30,
                                     chromaFormatIdc: 0, bitDepthLuma: 8, bitDepthChroma: 8).isSupported420)
    }

    func testFormatOfATruncatedSPSIsAbsentOrExact() {
        // A prefix that ends before the bit depths has no format; one that reaches them has the true
        // one. Never a different chroma format or depth.
        for f in fixtures {
            let full = HEVCSPSColor.format(nal: f.sps)
            var sawNil = false
            for n in 0..<f.sps.count {
                let cut = HEVCSPSColor.format(nal: f.sps.prefix(n))
                if cut == nil { sawNil = true } else { XCTAssertEqual(cut, full, "\(f.name) cut at \(n)") }
            }
            XCTAssertTrue(sawNil, f.name)
            XCTAssertNil(HEVCSPSColor.format(nal: f.sps.prefix(4)), f.name)
        }
        // Not an SPS: a VPS or PPS header has no format.
        XCTAssertNil(HEVCSPSColor.format(nal: [0x40, 0x01] + fixture("x265_pq").sps.dropFirst(2)))
        XCTAssertNil(HEVCSPSColor.format(nal: [0x44, 0x01] + fixture("x265_pq").sps.dropFirst(2)))
    }

    func testBothReadersReturnTheSameType() {
        // An H.264 SPS and an HEVC SPS declaring the same colour read as equal values.
        let h264 = H264SPSColor.parse(nal: [UInt8]([0x67, 0x64, 0x00, 0x0c, 0xac, 0xb2, 0x02, 0x83, 0x3f, 0x3e, 0x02, 0xd4, 0x24, 0x40, 0x25,
                                                    0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x32, 0x0f, 0x14, 0x2a, 0x48]))
        XCTAssertEqual(h264, HEVCSPSColor.parse(nal: fixture("x265_pq").sps))
    }
}
