//
//  H264SPSTiming.c
//  Manifold
//
//  See the header for why this exists and what it deliberately does not do.
//
//  ── THE TWO THINGS THAT MAKE SPS PARSING FIDDLY, BOTH HANDLED AT THE DOOR ──────────────
//
//  1. EMULATION PREVENTION. The byte sequence 00 00 03 inside a NAL is an escape: the 03 is an
//     inserted byte that is NOT part of the payload. Parsing without removing it silently shifts
//     every subsequent bit and produces plausible-looking garbage — which is far worse than a
//     failure, because the result is a NUMBER. `MDUnescapeRBSP` strips it up front.
//
//  2. EVERYTHING IS EXP-GOLOMB AND VARIABLE WIDTH, so the VUI cannot be seeked to. Reaching it
//     means stepping over the profile block, the optional chroma/scaling-list block, the frame
//     numbering, the cropping window — in order, correctly — with no ability to resynchronise.
//     One wrong skip and the timing fields read as noise. Hence: every skip below cites its
//     clause from ITU-T H.264 §7.3.2.1.1 and §E.1.1, and the reader refuses past the end rather
//     than returning zeros.
//
//  The bit reader FAILS CLOSED. Once `overrun` is set every subsequent read returns 0 and the
//  flag stays set, so the caller tests it ONCE at the end instead of after every field.
//

#include "H264SPSTiming.h"

#include <string.h>

// ── Bit reader over unescaped RBSP ────────────────────────────────────────────────────────

typedef struct {
    const uint8_t *data;
    size_t         size;      // bytes
    size_t         bitPos;    // absolute bit cursor
    bool           overrun;   // sticky: set once, never cleared
} MDBitReader;

static uint32_t MDReadBit(MDBitReader *r) {
    if (r->overrun || (r->bitPos >> 3) >= r->size) { r->overrun = true; return 0; }
    const uint8_t byte = r->data[r->bitPos >> 3];
    const uint32_t bit = (byte >> (7u - (r->bitPos & 7u))) & 1u;
    r->bitPos++;
    return bit;
}

static uint32_t MDReadBits(MDBitReader *r, int count) {
    uint32_t v = 0;
    for (int i = 0; i < count; i++) v = (v << 1) | MDReadBit(r);
    return v;
}

/// Unsigned exp-Golomb, ue(v). The leading-zero count is BOUNDED at 32: an unbounded loop over a
/// corrupt or truncated buffer is how a parser hangs, and no legal SPS field needs more.
static uint32_t MDReadUE(MDBitReader *r) {
    int leadingZeros = 0;
    while (!r->overrun && MDReadBit(r) == 0) {
        if (++leadingZeros >= 32) { r->overrun = true; return 0; }
    }
    if (r->overrun) return 0;
    if (leadingZeros == 0) return 0;
    return (1u << leadingZeros) - 1u + MDReadBits(r, leadingZeros);
}

/// Signed exp-Golomb, se(v). Read and discarded in every case here, but it must be read with the
/// right WIDTH or the cursor desynchronises.
static int32_t MDReadSE(MDBitReader *r) {
    const uint32_t k = MDReadUE(r);
    const int32_t mag = (int32_t)((k + 1u) / 2u);
    return (k & 1u) ? mag : -mag;
}

// ── Emulation prevention ──────────────────────────────────────────────────────────────────

/// Copy `src` into `dst`, dropping the 0x03 of every 00 00 03 sequence. Returns the byte count
/// written. `dst` must have room for `srcSize` bytes.
static size_t MDUnescapeRBSP(const uint8_t *src, size_t srcSize, uint8_t *dst) {
    size_t out = 0;
    size_t zeros = 0;
    for (size_t i = 0; i < srcSize; i++) {
        const uint8_t b = src[i];
        if (zeros >= 2 && b == 0x03) {
            // The escape byte itself. Drop it and reset — a 00 00 03 03 carries a literal 03.
            zeros = 0;
            continue;
        }
        dst[out++] = b;
        zeros = (b == 0x00) ? zeros + 1 : 0;
    }
    return out;
}

// ── The skips, each named for the clause it implements ────────────────────────────────────

/// H.264 §7.3.2.1.1.1 — scaling_list(). Present only when a scaling matrix is signalled; its
/// length depends on its own contents, so it must be walked, not skipped by a constant.
static void MDSkipScalingList(MDBitReader *r, int sizeOfScalingList) {
    int lastScale = 8, nextScale = 8;
    for (int j = 0; j < sizeOfScalingList && !r->overrun; j++) {
        if (nextScale != 0) {
            const int32_t delta = MDReadSE(r);
            nextScale = (lastScale + delta + 256) % 256;
        }
        lastScale = (nextScale == 0) ? lastScale : nextScale;
    }
}

/// H.264 §E.1.1 — the aspect-ratio block at the very top of the VUI.
///
/// ⚠️ SAR LIVES HERE AND IS DELIBERATELY STEPPED OVER. `aspect_ratio_idc` (and, for the
/// Extended_SAR value 255, the explicit 16-bit width/height pair) is exactly the signal
/// docs/BUGS.md records WHEP as lacking, and it is three lines from being available. It is NOT
/// read out because applying it is a change to aspect handling — `LiveDisplaySize`, the window
/// aspect lock, the framing guides — that needs its own measurement and its own commit. This
/// function is where to start when that is done.
static void MDSkipAspectRatio(MDBitReader *r) {
    const uint32_t aspectRatioInfoPresent = MDReadBit(r);
    if (aspectRatioInfoPresent) {
        const uint32_t aspectRatioIdc = MDReadBits(r, 8);
        if (aspectRatioIdc == 255) {          // Extended_SAR
            (void)MDReadBits(r, 16);          // sar_width
            (void)MDReadBits(r, 16);          // sar_height
        }
    }
}

// ── The one public entry point ────────────────────────────────────────────────────────────

ManifoldH264SPSTiming ManifoldH264ParseSPSTiming(const uint8_t *sps, size_t spsSize) {
    ManifoldH264SPSTiming out;
    memset(&out, 0, sizeof(out));

    // 1 byte of NAL header + at least profile/constraint/level/id. Anything shorter is not an SPS.
    if (sps == NULL || spsSize < 5) return out;

    // The NAL header byte must actually say SPS (type 7 in the low 5 bits). A caller handing us a
    // PPS would otherwise parse it happily and report a confident wrong rate.
    if ((sps[0] & 0x1Fu) != 7) return out;

    // Unescape everything after the NAL header. A stack buffer bounded by the builder's own
    // parameter-set ceiling: SPS NALs are tens of bytes, never kilobytes.
    enum { kMaxSPS = 1024 };
    const size_t payloadSize = spsSize - 1;
    if (payloadSize > kMaxSPS) return out;
    uint8_t rbsp[kMaxSPS];
    const size_t rbspSize = MDUnescapeRBSP(sps + 1, payloadSize, rbsp);

    MDBitReader r = { .data = rbsp, .size = rbspSize, .bitPos = 0, .overrun = false };

    // ── seq_parameter_set_data(), H.264 §7.3.2.1.1 ────────────────────────────────────────
    const uint32_t profileIdc = MDReadBits(&r, 8);
    (void)MDReadBits(&r, 8);            // constraint_set flags + reserved_zero_2bits
    (void)MDReadBits(&r, 8);            // level_idc
    (void)MDReadUE(&r);                 // seq_parameter_set_id

    // The high-profile block. Present ONLY for these profile_idc values — this is the single most
    // commonly botched part of SPS parsing, and getting it wrong shifts everything after it.
    if (profileIdc == 100 || profileIdc == 110 || profileIdc == 122 || profileIdc == 244 ||
        profileIdc == 44  || profileIdc == 83  || profileIdc == 86  || profileIdc == 118 ||
        profileIdc == 128 || profileIdc == 138 || profileIdc == 139 || profileIdc == 134 ||
        profileIdc == 135) {
        const uint32_t chromaFormatIdc = MDReadUE(&r);
        if (chromaFormatIdc == 3) (void)MDReadBit(&r);      // separate_colour_plane_flag
        (void)MDReadUE(&r);                                 // bit_depth_luma_minus8
        (void)MDReadUE(&r);                                 // bit_depth_chroma_minus8
        (void)MDReadBit(&r);                                // qpprime_y_zero_transform_bypass_flag
        if (MDReadBit(&r)) {                                // seq_scaling_matrix_present_flag
            const int listCount = (chromaFormatIdc != 3) ? 8 : 12;
            for (int i = 0; i < listCount && !r.overrun; i++) {
                if (MDReadBit(&r)) {                        // seq_scaling_list_present_flag[i]
                    MDSkipScalingList(&r, (i < 6) ? 16 : 64);
                }
            }
        }
    }

    (void)MDReadUE(&r);                                     // log2_max_frame_num_minus4
    const uint32_t picOrderCntType = MDReadUE(&r);
    if (picOrderCntType == 0) {
        (void)MDReadUE(&r);                                 // log2_max_pic_order_cnt_lsb_minus4
    } else if (picOrderCntType == 1) {
        (void)MDReadBit(&r);                                // delta_pic_order_always_zero_flag
        (void)MDReadSE(&r);                                 // offset_for_non_ref_pic
        (void)MDReadSE(&r);                                 // offset_for_top_to_bottom_field
        const uint32_t cycleLength = MDReadUE(&r);          // num_ref_frames_in_pic_order_cnt_cycle
        // Bounded for the same reason MDReadUE bounds its zero run: a corrupt length must not
        // become a long loop. 256 is the spec's own ceiling for this field.
        if (cycleLength > 256) { return out; }
        for (uint32_t i = 0; i < cycleLength && !r.overrun; i++) (void)MDReadSE(&r);
    }

    (void)MDReadUE(&r);                                     // max_num_ref_frames
    (void)MDReadBit(&r);                                    // gaps_in_frame_num_value_allowed_flag
    (void)MDReadUE(&r);                                     // pic_width_in_mbs_minus1
    (void)MDReadUE(&r);                                     // pic_height_in_map_units_minus1
    const uint32_t frameMbsOnly = MDReadBit(&r);            // frame_mbs_only_flag
    if (!frameMbsOnly) (void)MDReadBit(&r);                 // mb_adaptive_frame_field_flag
    (void)MDReadBit(&r);                                    // direct_8x8_inference_flag
    if (MDReadBit(&r)) {                                    // frame_cropping_flag
        (void)MDReadUE(&r);                                 // frame_crop_left_offset
        (void)MDReadUE(&r);                                 // frame_crop_right_offset
        (void)MDReadUE(&r);                                 // frame_crop_top_offset
        (void)MDReadUE(&r);                                 // frame_crop_bottom_offset
    }

    // ── vui_parameters(), H.264 §E.1.1 — OPTIONAL, and absence is the common case ─────────
    const uint32_t vuiPresent = MDReadBit(&r);              // vui_parameters_present_flag
    if (!vuiPresent || r.overrun) return out;

    MDSkipAspectRatio(&r);                                  // ⚠️ SAR is in here — see that function
    if (MDReadBit(&r)) (void)MDReadBit(&r);                 // overscan_info_present → overscan_appropriate
    if (MDReadBit(&r)) {                                    // video_signal_type_present_flag
        (void)MDReadBits(&r, 3);                            // video_format
        (void)MDReadBit(&r);                                // video_full_range_flag
        if (MDReadBit(&r)) {                                // colour_description_present_flag
            (void)MDReadBits(&r, 8);                        // colour_primaries
            (void)MDReadBits(&r, 8);                        // transfer_characteristics
            (void)MDReadBits(&r, 8);                        // matrix_coefficients
        }
    }
    if (MDReadBit(&r)) {                                    // chroma_loc_info_present_flag
        (void)MDReadUE(&r);                                 // chroma_sample_loc_type_top_field
        (void)MDReadUE(&r);                                 // chroma_sample_loc_type_bottom_field
    }

    // THE FIELDS THIS WHOLE FILE EXISTS FOR.
    const uint32_t timingInfoPresent = MDReadBit(&r);       // timing_info_present_flag
    if (!timingInfoPresent) return out;                     // absent means absent — do not guess

    const uint32_t numUnitsInTick = MDReadBits(&r, 32);
    const uint32_t timeScale      = MDReadBits(&r, 32);
    const uint32_t fixedFrameRate = MDReadBit(&r);

    // One test, at the end, for every failure the reader accumulated.
    if (r.overrun) return out;
    // Both are required to be > 0 by §E.2.1. A zero here is a broken encoder, and dividing by it
    // would produce inf rather than an honest "we do not know".
    if (numUnitsInTick == 0 || timeScale == 0) return out;

    // fps = time_scale / (2 * num_units_in_tick). The factor of 2 is because the tick is a FIELD
    // interval, not a frame interval (§E.2.1) — omitting it reports 2x the true rate, which is a
    // plausible-looking wrong answer (60 for a 30p stream).
    const double fps = (double)timeScale / (2.0 * (double)numUnitsInTick);
    // A rate outside anything a video signal plausibly is means the parse desynchronised somewhere
    // and produced a number anyway. Refuse rather than publish it.
    if (!(fps > 1.0 && fps < 1000.0)) return out;

    out.valid           = true;
    out.framesPerSecond = fps;
    out.numUnitsInTick  = numUnitsInTick;
    out.timeScale       = timeScale;
    out.fixedFrameRate  = (fixedFrameRate != 0);
    return out;
}
