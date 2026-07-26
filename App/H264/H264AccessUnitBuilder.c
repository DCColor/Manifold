//
//  H264AccessUnitBuilder.c
//  Manifold
//
//  NAL units in, access units out. See H264AccessUnitBuilder.h for the contract
//  and for why this is not part of the RTP depacketizer.
//
//  ── WHY AVCC (4-byte length prefix) AND NOT ANNEX-B ────────────────────────
//
//  The output format is chosen by whoever consumes it, and on macOS that is
//  VideoToolbox:
//
//    * VTDecompressionSession takes a CMSampleBuffer whose CMBlockBuffer holds
//      LENGTH-PREFIXED NALs, with the prefix width declared in the
//      CMVideoFormatDescription. Annex-B start codes are not accepted — Apple
//      has no "annex b" input mode for VTDecompressionSession at all.
//    * The format description itself is built by
//      CMVideoFormatDescriptionCreateFromH264ParameterSets(), which takes SPS
//      and PPS as SEPARATE raw buffers, NOT inline in the sample data. So
//      parameter sets must be split out of the bitstream, which is exactly what
//      this file does.
//    * 4 bytes rather than 3 or 2 because it is what every AVCC muxer emits,
//      it cannot be under-sized by a large slice, and it is the value we pass as
//      nalUnitHeaderLength.
//
//  Manifold's OTHER decode path is libav (LibavFrameSource), and libav's H.264
//  decoder wants Annex-B unless you hand it AVCC extradata. That does not change
//  the choice: converting AVCC → Annex-B is overwriting each 4-byte length with
//  00 00 00 01, in place, same size, no reallocation. Going the other way is the
//  expensive direction (you must scan for start codes and undo emulation
//  prevention), so producing AVCC keeps BOTH doors open at a cost of ~0.
//
//  ── EMULATION PREVENTION BYTES ARE NOT REMOVED. THIS IS DELIBERATE ─────────
//
//  RBSP unescaping is the decoder's job, not the bitstream plumbing's, and doing
//  it here would corrupt what we hand VideoToolbox. It also has a second payoff
//  that matters more now than it did under WHEP alone: because the escaping is
//  intact, an Annex-B start-code scan is trivially correct. The whole point of
//  emulation prevention is that 00 00 00/01/02/03 cannot occur inside a NAL
//  payload, so "find the next start code" is a plain byte search with no parsing
//  and no false positives. Strip the escaping upstream and that stops being true.
//

#include "H264AccessUnitBuilder.h"

#include <stdlib.h>
#include <string.h>

// Sanity caps. These exist to bound damage from a corrupt length field, not to
// express a real limit — a 4K IDR is comfortably under 4 MB.
//
// SIZED AGAINST WHEP, WHICH IS THE SOFT CASE: a browser/OBS WebRTC sender is
// congestion-controlled down to a few Mb/s, so 8 MB is orders of magnitude of
// headroom there. A real SRT contribution feed is not that — 100+ Mb/s I-frame
// intra, 10-bit 4:2:2, or an all-intra mezzanine codec can put a single access
// unit into the megabytes for real rather than only under corruption. RE-EXAMINE
// this against a measured high-bitrate feed before trusting it on the SRT path;
// blowing the cap silently discards the frame (accessUnitsOversize).
#define MD_MAX_ACCESS_UNIT_BYTES  (8u * 1024u * 1024u)
#define MD_MAX_PARAMETER_SET      512u

// NAL unit types (H.264 Table 7-1). One-byte NAL header, type in the low 5 bits
// — H.264 only; see the HEVC note in the header.
#define MD_NAL_SLICE               1
#define MD_NAL_IDR                 5
#define MD_NAL_SEI                 6
#define MD_NAL_SPS                 7
#define MD_NAL_PPS                 8
#define MD_NAL_AUD                 9
#define MD_NAL_FILLER             12

// ── A grow-once, reuse-forever byte buffer ────────────────────────────────────
// Steady state does zero allocation: capacity settles at the largest frame seen.

bool ManifoldH264BufferReserve(ManifoldH264Buffer *buffer, size_t needed) {
    if (needed <= buffer->capacity) return true;
    size_t capacity = buffer->capacity ? buffer->capacity : 64u * 1024u;
    while (capacity < needed) capacity *= 2;
    uint8_t *grown = realloc(buffer->data, capacity);
    if (!grown) return false;
    buffer->data = grown;
    buffer->capacity = capacity;
    return true;
}

bool ManifoldH264BufferAppend(ManifoldH264Buffer *buffer, const uint8_t *bytes, size_t count) {
    if (!ManifoldH264BufferReserve(buffer, buffer->size + count)) return false;
    memcpy(buffer->data + buffer->size, bytes, count);
    buffer->size += count;
    return true;
}

void ManifoldH264BufferFree(ManifoldH264Buffer *buffer) {
    free(buffer->data);
    buffer->data = NULL;
    buffer->size = buffer->capacity = 0;
}

// ── State ─────────────────────────────────────────────────────────────────────

struct ManifoldH264AccessUnitBuilder {
    // Access unit under construction
    ManifoldH264Buffer accessUnit;
    bool     accessUnitActive;
    uint32_t accessUnitTimestamp;
    bool     accessUnitKeyframe;
    bool     accessUnitOverflowed;
    bool     parameterSetsChanged; // sticky until the next AU is emitted

    uint8_t  sps[MD_MAX_PARAMETER_SET];
    size_t   spsSize;
    uint8_t  pps[MD_MAX_PARAMETER_SET];
    size_t   ppsSize;

    ManifoldH264AccessUnitHandler handler;
    void                         *handlerContext;

    ManifoldH264AccessUnitBuilderStats stats;
};

// ── Access unit assembly ──────────────────────────────────────────────────────

static void MDEmitAccessUnit(ManifoldH264AccessUnitBuilder *ab) {
    if (!ab->accessUnitActive) return;

    if (ab->accessUnitOverflowed) {
        ab->stats.accessUnitsOversize++;
    } else if (ab->accessUnit.size > 0) {
        ab->stats.accessUnits++;
        if (ab->accessUnitKeyframe) ab->stats.keyframes++;
        if (ab->handler) {
            ManifoldH264AccessUnit accessUnit = {
                .data                 = ab->accessUnit.data,
                .size                 = ab->accessUnit.size,
                .rtpTimestamp         = ab->accessUnitTimestamp,
                .keyframe             = ab->accessUnitKeyframe,
                .parameterSetsChanged = ab->parameterSetsChanged,
                .sps                  = ab->spsSize ? ab->sps : NULL,
                .spsSize              = ab->spsSize,
                .pps                  = ab->ppsSize ? ab->pps : NULL,
                .ppsSize              = ab->ppsSize,
            };
            ab->handler(&accessUnit, ab->handlerContext);
        }
    }

    ab->accessUnit.size        = 0;
    ab->accessUnitActive       = false;
    ab->accessUnitKeyframe     = false;
    ab->accessUnitOverflowed   = false;
    ab->parameterSetsChanged   = false;
}

/// Stores a parameter set, reporting whether it actually changed. Re-sent SPS/PPS
/// on every keyframe is normal WebRTC behaviour (and normal in-band MPEG-TS
/// behaviour too) and must NOT invalidate the format description each time —
/// only a genuine change should.
static bool MDStoreParameterSet(uint8_t *slot, size_t *slotSize,
                                const uint8_t *nal, size_t size) {
    if (size == 0 || size > MD_MAX_PARAMETER_SET) return false;
    if (*slotSize == size && memcmp(slot, nal, size) == 0) return false;
    memcpy(slot, nal, size);
    *slotSize = size;
    return true;
}

// ── Public API ────────────────────────────────────────────────────────────────

ManifoldH264AccessUnitBuilder *ManifoldH264AccessUnitBuilderCreate(void) {
    return calloc(1, sizeof(ManifoldH264AccessUnitBuilder));
}

void ManifoldH264AccessUnitBuilderDestroy(ManifoldH264AccessUnitBuilder *ab) {
    if (!ab) return;
    ManifoldH264BufferFree(&ab->accessUnit);
    free(ab);
}

void ManifoldH264AccessUnitBuilderSetHandler(ManifoldH264AccessUnitBuilder *ab,
                                             ManifoldH264AccessUnitHandler handler,
                                             void *context) {
    if (!ab) return;
    ab->handler        = handler;
    ab->handlerContext = context;
}

void ManifoldH264AccessUnitBuilderAppendNAL(ManifoldH264AccessUnitBuilder *ab,
                                            const uint8_t *nal, size_t size,
                                            uint32_t timestamp) {
    if (!ab || !nal) return;
    if (size == 0) { ab->stats.nalEmpty++; return; }

    const uint8_t type = nal[0] & 0x1Fu;

    switch (type) {
        case MD_NAL_SPS:   ab->stats.nalSPS++;   break;
        case MD_NAL_PPS:   ab->stats.nalPPS++;   break;
        case MD_NAL_IDR:   ab->stats.nalIDR++;   break;
        case MD_NAL_SLICE: ab->stats.nalSlice++; break;
        case MD_NAL_SEI:   ab->stats.nalSEI++;   break;
        case MD_NAL_AUD:   ab->stats.nalAUD++;   break;
        default:           ab->stats.nalOther++; break;
    }

    // Parameter sets go out-of-band (VideoToolbox wants them in the format
    // description, never in the sample data) and are NOT appended to the AU.
    if (type == MD_NAL_SPS) {
        if (MDStoreParameterSet(ab->sps, &ab->spsSize, nal, size)) ab->parameterSetsChanged = true;
        return;
    }
    if (type == MD_NAL_PPS) {
        if (MDStoreParameterSet(ab->pps, &ab->ppsSize, nal, size)) ab->parameterSetsChanged = true;
        return;
    }
    // AUD carries no picture data and filler is padding; both are noise to the
    // decoder and to the frame counting below.
    if (type == MD_NAL_AUD || type == MD_NAL_FILLER) return;

    if (!ab->accessUnitActive) {
        ab->accessUnitActive     = true;
        ab->accessUnitTimestamp  = timestamp;
        ab->accessUnitKeyframe   = false;
        ab->accessUnitOverflowed = false;
    }

    // KEYFRAME MEANS IDR — NAL TYPE 5, NOTHING ELSE. Do not "simplify" this to
    // whatever the container thought. libavformat's AV_PKT_FLAG_KEY is a LOOSER
    // signal: it also fires on a plain I-slice carrying a recovery-point SEI,
    // i.e. the start of an open GOP, whose leading pictures reference frames
    // from BEFORE the recovery point and decode to garbage if you start there.
    //
    // That distinction costs a frame of stutter on WHEP, where a bad start is
    // repairable — we send a PLI and the sender pushes a real IDR. SRT has NO
    // PLI and no back channel of any kind: start on the wrong picture and the
    // corruption persists until the encoder's next IDR comes around on its own
    // schedule, which on a contribution feed can be seconds. The strict test is
    // what makes "wait for a keyframe" mean something on that path.
    if (type == MD_NAL_IDR) ab->accessUnitKeyframe = true;

    if (ab->accessUnitOverflowed) return;
    if (ab->accessUnit.size + 4 + size > MD_MAX_ACCESS_UNIT_BYTES) {
        ab->accessUnitOverflowed = true;
        return;
    }

    const uint8_t lengthPrefix[4] = {
        (uint8_t)(size >> 24), (uint8_t)(size >> 16), (uint8_t)(size >> 8), (uint8_t)size
    };
    if (!ManifoldH264BufferAppend(&ab->accessUnit, lengthPrefix, sizeof(lengthPrefix)) ||
        !ManifoldH264BufferAppend(&ab->accessUnit, nal, size)) {
        ab->accessUnitOverflowed = true;   // allocation failure — discard the frame, keep running
    }
}

void ManifoldH264AccessUnitBuilderFlush(ManifoldH264AccessUnitBuilder *ab) {
    if (!ab) return;
    MDEmitAccessUnit(ab);
}

bool ManifoldH264AccessUnitBuilderIsAccessUnitOpen(const ManifoldH264AccessUnitBuilder *ab,
                                                   uint32_t *outTimestamp) {
    if (!ab || !ab->accessUnitActive) return false;
    if (outTimestamp) *outTimestamp = ab->accessUnitTimestamp;
    return true;
}

void ManifoldH264AccessUnitBuilderCopyStats(const ManifoldH264AccessUnitBuilder *ab,
                                            ManifoldH264AccessUnitBuilderStats *outStats) {
    if (!outStats) return;
    if (!ab) { memset(outStats, 0, sizeof(*outStats)); return; }
    *outStats = ab->stats;
    outStats->spsSize = ab->spsSize;
    outStats->ppsSize = ab->ppsSize;
}
