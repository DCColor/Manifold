//
//  H264Depacketizer.c
//  Manifold
//
//  RFC 6184 depacketization. See H264Depacketizer.h for the contract.
//
//  ── WHY AVCC (4-byte length prefix) AND NOT ANNEX-B ────────────────────────
//
//  The output format is chosen by whoever consumes it in step 3b, and on macOS
//  that is VideoToolbox:
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
//  ── WHAT IS DELIBERATELY NOT IMPLEMENTED ───────────────────────────────────
//
//    * STAP-B (25), MTAP16 (26), MTAP24 (27), FU-B (29). These exist for
//      interleaved mode, which WebRTC never negotiates
//      (packetization-mode=1 is non-interleaved). Counted as nalUnsupported.
//    * A jitter buffer / reorder queue. Gaps and out-of-order arrivals are
//      DETECTED and counted; they are not repaired. On a LAN this is fine. If
//      seqGaps is routinely non-zero, that is the hardening item: a small
//      reorder window ahead of this stage, plus NACK
//      (rtcChainRtcpNackResponder is for the send side; inbound NACK generation
//      would have to be added).
//    * Emulation prevention byte removal. Correct — depacketization must NOT
//      touch RBSP escaping; the decoder does that.
//

#include "H264Depacketizer.h"

#include <stdlib.h>
#include <string.h>

// Sanity caps. These exist to bound damage from a corrupt length field, not to
// express a real limit — a 4K IDR is comfortably under 4 MB.
#define MD_MAX_ACCESS_UNIT_BYTES  (8u * 1024u * 1024u)
#define MD_MAX_FRAGMENT_BYTES     (4u * 1024u * 1024u)
#define MD_MAX_PARAMETER_SET      512u

// RTP header, RFC 3550 §5.1
#define MD_RTP_HEADER_BYTES       12u

// NAL unit types we care about (H.264 Table 7-1)
#define MD_NAL_SLICE               1
#define MD_NAL_IDR                 5
#define MD_NAL_SEI                 6
#define MD_NAL_SPS                 7
#define MD_NAL_PPS                 8
#define MD_NAL_AUD                 9
#define MD_NAL_FILLER             12
// RFC 6184 packet types
#define MD_PKT_STAP_A             24
#define MD_PKT_FU_A               28

// ── A grow-once, reuse-forever byte buffer ────────────────────────────────────
// Steady state does zero allocation: capacity settles at the largest frame seen.

typedef struct {
    uint8_t *data;
    size_t   size;
    size_t   capacity;
} MDBuffer;

static bool MDBufferReserve(MDBuffer *buffer, size_t needed) {
    if (needed <= buffer->capacity) return true;
    size_t capacity = buffer->capacity ? buffer->capacity : 64u * 1024u;
    while (capacity < needed) capacity *= 2;
    uint8_t *grown = realloc(buffer->data, capacity);
    if (!grown) return false;
    buffer->data = grown;
    buffer->capacity = capacity;
    return true;
}

static bool MDBufferAppend(MDBuffer *buffer, const uint8_t *bytes, size_t count) {
    if (!MDBufferReserve(buffer, buffer->size + count)) return false;
    memcpy(buffer->data + buffer->size, bytes, count);
    buffer->size += count;
    return true;
}

static void MDBufferFree(MDBuffer *buffer) {
    free(buffer->data);
    buffer->data = NULL;
    buffer->size = buffer->capacity = 0;
}

// ── State ─────────────────────────────────────────────────────────────────────

struct ManifoldH264Depacketizer {
    int      payloadType;          // -1 = latch the first one seen
    uint32_t ssrc;
    bool     haveSSRC;

    bool     haveSeq;
    uint16_t highestSeq;           // highest sequence number seen (RFC 3550 s_max)

    // FU-A reassembly
    MDBuffer fragment;
    bool     fragmentActive;

    // Access unit under construction
    MDBuffer accessUnit;
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

    ManifoldH264DepacketizerStats stats;
};

static uint16_t MDReadBE16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] << 8 | (uint16_t)p[1]);
}

static uint32_t MDReadBE32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | (uint32_t)p[3];
}

// ── Access unit assembly ──────────────────────────────────────────────────────

static void MDEmitAccessUnit(ManifoldH264Depacketizer *dp) {
    if (!dp->accessUnitActive) return;

    if (dp->accessUnitOverflowed) {
        dp->stats.accessUnitsOversize++;
    } else if (dp->accessUnit.size > 0) {
        dp->stats.accessUnits++;
        if (dp->accessUnitKeyframe) dp->stats.keyframes++;
        if (dp->handler) {
            ManifoldH264AccessUnit accessUnit = {
                .data                 = dp->accessUnit.data,
                .size                 = dp->accessUnit.size,
                .rtpTimestamp         = dp->accessUnitTimestamp,
                .keyframe             = dp->accessUnitKeyframe,
                .parameterSetsChanged = dp->parameterSetsChanged,
                .sps                  = dp->spsSize ? dp->sps : NULL,
                .spsSize              = dp->spsSize,
                .pps                  = dp->ppsSize ? dp->pps : NULL,
                .ppsSize              = dp->ppsSize,
            };
            dp->handler(&accessUnit, dp->handlerContext);
        }
    }

    dp->accessUnit.size        = 0;
    dp->accessUnitActive       = false;
    dp->accessUnitKeyframe     = false;
    dp->accessUnitOverflowed   = false;
    dp->parameterSetsChanged   = false;
}

/// Stores a parameter set, reporting whether it actually changed. Re-sent SPS/PPS
/// on every keyframe is normal WebRTC behaviour and must NOT invalidate the
/// format description each time — only a genuine change should.
static bool MDStoreParameterSet(uint8_t *slot, size_t *slotSize,
                                const uint8_t *nal, size_t size) {
    if (size == 0 || size > MD_MAX_PARAMETER_SET) return false;
    if (*slotSize == size && memcmp(slot, nal, size) == 0) return false;
    memcpy(slot, nal, size);
    *slotSize = size;
    return true;
}

/// One complete NAL unit (header byte first, no start code, no length prefix).
static void MDHandleNAL(ManifoldH264Depacketizer *dp, const uint8_t *nal, size_t size, uint32_t timestamp) {
    if (size == 0) { dp->stats.packetsMalformed++; return; }

    const uint8_t type = nal[0] & 0x1Fu;

    switch (type) {
        case MD_NAL_SPS:   dp->stats.nalSPS++;   break;
        case MD_NAL_PPS:   dp->stats.nalPPS++;   break;
        case MD_NAL_IDR:   dp->stats.nalIDR++;   break;
        case MD_NAL_SLICE: dp->stats.nalSlice++; break;
        case MD_NAL_SEI:   dp->stats.nalSEI++;   break;
        case MD_NAL_AUD:   dp->stats.nalAUD++;   break;
        default:           dp->stats.nalOther++; break;
    }

    // Parameter sets go out-of-band (VideoToolbox wants them in the format
    // description, never in the sample data) and are NOT appended to the AU.
    if (type == MD_NAL_SPS) {
        if (MDStoreParameterSet(dp->sps, &dp->spsSize, nal, size)) dp->parameterSetsChanged = true;
        return;
    }
    if (type == MD_NAL_PPS) {
        if (MDStoreParameterSet(dp->pps, &dp->ppsSize, nal, size)) dp->parameterSetsChanged = true;
        return;
    }
    // AUD carries no picture data and filler is padding; both are noise to the
    // decoder and to the frame counting below.
    if (type == MD_NAL_AUD || type == MD_NAL_FILLER) return;

    if (!dp->accessUnitActive) {
        dp->accessUnitActive     = true;
        dp->accessUnitTimestamp  = timestamp;
        dp->accessUnitKeyframe   = false;
        dp->accessUnitOverflowed = false;
    }
    if (type == MD_NAL_IDR) dp->accessUnitKeyframe = true;

    if (dp->accessUnitOverflowed) return;
    if (dp->accessUnit.size + 4 + size > MD_MAX_ACCESS_UNIT_BYTES) {
        dp->accessUnitOverflowed = true;
        return;
    }

    const uint8_t lengthPrefix[4] = {
        (uint8_t)(size >> 24), (uint8_t)(size >> 16), (uint8_t)(size >> 8), (uint8_t)size
    };
    if (!MDBufferAppend(&dp->accessUnit, lengthPrefix, sizeof(lengthPrefix)) ||
        !MDBufferAppend(&dp->accessUnit, nal, size)) {
        dp->accessUnitOverflowed = true;   // allocation failure — discard the frame, keep running
    }
}

// ── RFC 6184 packet forms ─────────────────────────────────────────────────────

/// STAP-A (type 24): [STAP-A hdr][len16][NAL]…[len16][NAL]. Used by every WebRTC
/// sender to ship SPS+PPS in a single packet ahead of the IDR.
static void MDHandleSTAPA(ManifoldH264Depacketizer *dp, const uint8_t *payload, size_t size, uint32_t timestamp) {
    size_t offset = 1;   // skip the STAP-A header byte
    while (offset + 2 <= size) {
        const size_t nalSize = MDReadBE16(payload + offset);
        offset += 2;
        if (nalSize == 0 || offset + nalSize > size) { dp->stats.packetsMalformed++; return; }
        MDHandleNAL(dp, payload + offset, nalSize, timestamp);
        offset += nalSize;
    }
    if (offset != size) dp->stats.packetsMalformed++;   // trailing byte: a truncated aggregate
}

/// FU-A (type 28): [FU indicator][FU header][fragment].
/// The original NAL header is rebuilt as (indicator & 0xE0) | (fu header & 0x1F)
/// — F and NRI come from the indicator, the type from the FU header.
static void MDHandleFUA(ManifoldH264Depacketizer *dp, const uint8_t *payload, size_t size, uint32_t timestamp) {
    if (size < 3) { dp->stats.packetsMalformed++; return; }   // indicator + header + >=1 byte

    dp->stats.fuaPackets++;

    const uint8_t fuHeader = payload[1];
    const bool    start    = (fuHeader & 0x80u) != 0;
    const bool    end      = (fuHeader & 0x40u) != 0;

    if (start) {
        if (dp->fragmentActive) dp->stats.fuaDropped++;   // previous NAL never finished
        dp->fragment.size    = 0;
        dp->fragmentActive   = true;
        const uint8_t nalHeader = (uint8_t)((payload[0] & 0xE0u) | (fuHeader & 0x1Fu));
        if (!MDBufferAppend(&dp->fragment, &nalHeader, 1)) {
            dp->fragmentActive = false;
            dp->stats.fuaDropped++;
            return;
        }
    } else if (!dp->fragmentActive) {
        // Middle/end fragment with no start: either we joined mid-NAL, or the
        // start packet was the one lost. Counted by the gap detector already.
        return;
    }

    if (dp->fragment.size + (size - 2) > MD_MAX_FRAGMENT_BYTES ||
        !MDBufferAppend(&dp->fragment, payload + 2, size - 2)) {
        dp->fragmentActive = false;
        dp->fragment.size  = 0;
        dp->stats.fuaDropped++;
        return;
    }

    if (end) {
        MDHandleNAL(dp, dp->fragment.data, dp->fragment.size, timestamp);
        dp->stats.fuaReassembled++;
        dp->fragmentActive = false;
        dp->fragment.size  = 0;
    }
}

static void MDAbandonFragment(ManifoldH264Depacketizer *dp) {
    if (!dp->fragmentActive) return;
    dp->fragmentActive = false;
    dp->fragment.size  = 0;
    dp->stats.fuaDropped++;
}

// ── Public API ────────────────────────────────────────────────────────────────

ManifoldH264Depacketizer *ManifoldH264DepacketizerCreate(void) {
    ManifoldH264Depacketizer *dp = calloc(1, sizeof(*dp));
    if (!dp) return NULL;
    dp->payloadType       = -1;
    dp->stats.payloadType = -1;
    return dp;
}

void ManifoldH264DepacketizerDestroy(ManifoldH264Depacketizer *dp) {
    if (!dp) return;
    MDBufferFree(&dp->fragment);
    MDBufferFree(&dp->accessUnit);
    free(dp);
}

void ManifoldH264DepacketizerSetPayloadType(ManifoldH264Depacketizer *dp, int payloadType) {
    if (!dp) return;
    dp->payloadType       = payloadType;
    dp->stats.payloadType = payloadType;
}

void ManifoldH264DepacketizerSetAccessUnitHandler(ManifoldH264Depacketizer *dp,
                                                  ManifoldH264AccessUnitHandler handler,
                                                  void *context) {
    if (!dp) return;
    dp->handler        = handler;
    dp->handlerContext = context;
}

void ManifoldH264DepacketizerSubmitRTP(ManifoldH264Depacketizer *dp, const uint8_t *packet, size_t size) {
    if (!dp || !packet) return;

    dp->stats.packetsReceived++;

    if (size < MD_RTP_HEADER_BYTES)  { dp->stats.packetsMalformed++; return; }
    if ((packet[0] >> 6) != 2)       { dp->stats.packetsMalformed++; return; }   // version must be 2

    const uint8_t payloadType = packet[1] & 0x7Fu;

    // RTCP multiplexed onto the same 5-tuple (RFC 5761 §4 reserves 64–95 for the
    // RTCP packet types 200–206 mapped down). We chain an RtcpReceivingSession,
    // which should consume these before we ever see them — so a non-zero count
    // here means that handler is not in the chain.
    if (payloadType >= 72 && payloadType <= 76) { dp->stats.packetsRTCP++; return; }

    if (dp->payloadType < 0) {
        dp->payloadType       = payloadType;
        dp->stats.payloadType = payloadType;
    }
    if (payloadType != dp->payloadType) { dp->stats.packetsWrongPayloadType++; return; }

    const bool     marker    = (packet[1] & 0x80u) != 0;
    const uint16_t seq       = MDReadBE16(packet + 2);
    const uint32_t timestamp = MDReadBE32(packet + 4);
    const uint32_t ssrc      = MDReadBE32(packet + 8);

    // First SSRC wins. A second one is RTX or a simulcast layer we did not ask
    // for; mixing it into the same reassembly state would corrupt every NAL.
    if (!dp->haveSSRC) {
        dp->haveSSRC   = true;
        dp->ssrc       = ssrc;
        dp->stats.ssrc = ssrc;
    } else if (ssrc != dp->ssrc) {
        dp->stats.packetsWrongSSRC++;
        return;
    }

    // ── Header geometry: CSRCs, then the optional extension, then padding ────
    size_t offset = MD_RTP_HEADER_BYTES + 4u * (size_t)(packet[0] & 0x0Fu);
    if (size < offset) { dp->stats.packetsMalformed++; return; }

    if (packet[0] & 0x10u) {                       // X bit: one extension header
        if (size < offset + 4) { dp->stats.packetsMalformed++; return; }
        const size_t words = MDReadBE16(packet + offset + 2);
        offset += 4 + 4 * words;
        if (size < offset) { dp->stats.packetsMalformed++; return; }
    }

    size_t end = size;
    if (packet[0] & 0x20u) {                       // P bit: last byte is the pad count
        const uint8_t padding = packet[size - 1];
        if (padding == 0 || (size_t)padding > size - offset) { dp->stats.packetsMalformed++; return; }
        end = size - padding;
    }
    if (end <= offset) { dp->stats.packetsMalformed++; return; }

    // ── Sequence accounting (detect only — no reordering, see the file header) ─
    if (!dp->haveSeq) {
        dp->haveSeq    = true;
        dp->highestSeq = seq;
    } else {
        const int16_t delta = (int16_t)(seq - dp->highestSeq);   // wraps correctly at 65535
        if (delta > 1) {
            dp->stats.seqGaps++;
            dp->stats.packetsLost += (uint64_t)(delta - 1);
            // A gap mid-NAL means the reassembled NAL would be silently corrupt.
            // Throwing it away is the only honest option without a jitter buffer.
            MDAbandonFragment(dp);
            dp->highestSeq = seq;
        } else if (delta <= 0) {
            dp->stats.packetsReordered++;
            // Deliberately NOT rewinding highestSeq: this packet is late or a
            // duplicate. We still depacketize it — for a single-NAL packet that
            // is a win, and for FU-A the start/end bits keep it self-consistent.
        } else {
            dp->highestSeq = seq;
        }
    }

    dp->stats.packetsAccepted++;
    dp->stats.lastRTPTimestamp = timestamp;

    // A new timestamp means the previous access unit is over. This is the SAFETY
    // NET for a lost marker bit; the marker below is the primary signal.
    if (dp->accessUnitActive && timestamp != dp->accessUnitTimestamp) {
        dp->stats.accessUnitsByTimestamp++;
        MDEmitAccessUnit(dp);
    }

    const uint8_t *payload     = packet + offset;
    const size_t   payloadSize = end - offset;
    const uint8_t  packetType  = payload[0] & 0x1Fu;

    if (packetType >= 1 && packetType <= 23) {
        MDHandleNAL(dp, payload, payloadSize, timestamp);       // single NAL unit packet
    } else if (packetType == MD_PKT_STAP_A) {
        MDHandleSTAPA(dp, payload, payloadSize, timestamp);
    } else if (packetType == MD_PKT_FU_A) {
        MDHandleFUA(dp, payload, payloadSize, timestamp);
    } else {
        dp->stats.nalUnsupported++;   // STAP-B / MTAP / FU-B / reserved 0, 30, 31
    }

    if (marker) MDEmitAccessUnit(dp);
}

void ManifoldH264DepacketizerFlush(ManifoldH264Depacketizer *dp) {
    if (!dp) return;
    MDAbandonFragment(dp);
    MDEmitAccessUnit(dp);
}

void ManifoldH264DepacketizerCopyStats(const ManifoldH264Depacketizer *dp,
                                       ManifoldH264DepacketizerStats *outStats) {
    if (!outStats) return;
    if (!dp) { memset(outStats, 0, sizeof(*outStats)); outStats->payloadType = -1; return; }
    *outStats = dp->stats;
    outStats->spsSize = dp->spsSize;
    outStats->ppsSize = dp->ppsSize;
}
