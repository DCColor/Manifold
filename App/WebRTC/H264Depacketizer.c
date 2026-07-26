//
//  H264Depacketizer.c
//  Manifold
//
//  RFC 6184 depacketization. See H264Depacketizer.h for the contract.
//
//  ── WHERE THE H.264 SEMANTICS WENT ─────────────────────────────────────────
//
//  This file stops at "here is one complete NAL unit". What happens next — NAL
//  type classification, SPS/PPS diversion out-of-band, AUD/filler dropping,
//  keyframe marking, AVCC length prefixing, and the emit — is
//  H264AccessUnitBuilder.c, which the SRT path shares. That includes the
//  reasoning for AVCC over Annex-B and for leaving emulation prevention bytes
//  alone; both live there now, next to the code they describe.
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
//

#include "H264Depacketizer.h"

#include <stdlib.h>
#include <string.h>

// Sanity cap. Exists to bound damage from a corrupt length field, not to express
// a real limit — a 4K IDR is comfortably under 4 MB. (The access-unit cap lives
// with the builder.)
#define MD_MAX_FRAGMENT_BYTES     (4u * 1024u * 1024u)

// RTP header, RFC 3550 §5.1
#define MD_RTP_HEADER_BYTES       12u

// RFC 6184 packet types
#define MD_PKT_STAP_A             24
#define MD_PKT_FU_A               28

// ── State ─────────────────────────────────────────────────────────────────────

struct ManifoldH264Depacketizer {
    int      payloadType;          // -1 = latch the first one seen
    uint32_t ssrc;
    bool     haveSSRC;

    bool     haveSeq;
    uint16_t highestSeq;           // highest sequence number seen (RFC 3550 s_max)

    // FU-A reassembly
    ManifoldH264Buffer fragment;
    bool               fragmentActive;

    // Access-unit assembly and every piece of H.264 state it needs (AU buffer,
    // keyframe flag, SPS/PPS slots, the handler) live here.
    ManifoldH264AccessUnitBuilder *builder;

    ManifoldH264DepacketizerStats stats;
};

static uint16_t MDReadBE16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] << 8 | (uint16_t)p[1]);
}

static uint32_t MDReadBE32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | (uint32_t)p[3];
}

/// One complete NAL unit (header byte first, no start code, no length prefix)
/// into the shared builder. The RTP layer's only remaining job for a NAL is to
/// hand it over with the timestamp that would open an access unit.
static void MDHandleNAL(ManifoldH264Depacketizer *dp, const uint8_t *nal, size_t size, uint32_t timestamp) {
    ManifoldH264AccessUnitBuilderAppendNAL(dp->builder, nal, size, timestamp);
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
        if (!ManifoldH264BufferAppend(&dp->fragment, &nalHeader, 1)) {
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
        !ManifoldH264BufferAppend(&dp->fragment, payload + 2, size - 2)) {
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
    dp->builder = ManifoldH264AccessUnitBuilderCreate();
    if (!dp->builder) { free(dp); return NULL; }
    dp->payloadType       = -1;
    dp->stats.payloadType = -1;
    return dp;
}

void ManifoldH264DepacketizerDestroy(ManifoldH264Depacketizer *dp) {
    if (!dp) return;
    ManifoldH264BufferFree(&dp->fragment);
    ManifoldH264AccessUnitBuilderDestroy(dp->builder);
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
    ManifoldH264AccessUnitBuilderSetHandler(dp->builder, handler, context);
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
    // NET for a lost marker bit; the marker below is the primary signal. Both
    // boundaries stay here in the RTP layer — the builder only closes when told.
    uint32_t openTimestamp = 0;
    if (ManifoldH264AccessUnitBuilderIsAccessUnitOpen(dp->builder, &openTimestamp) &&
        timestamp != openTimestamp) {
        dp->stats.accessUnitsByTimestamp++;
        ManifoldH264AccessUnitBuilderFlush(dp->builder);
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

    if (marker) ManifoldH264AccessUnitBuilderFlush(dp->builder);
}

void ManifoldH264DepacketizerFlush(ManifoldH264Depacketizer *dp) {
    if (!dp) return;
    MDAbandonFragment(dp);
    ManifoldH264AccessUnitBuilderFlush(dp->builder);
}

void ManifoldH264DepacketizerCopyStats(const ManifoldH264Depacketizer *dp,
                                       ManifoldH264DepacketizerStats *outStats) {
    if (!outStats) return;
    if (!dp) { memset(outStats, 0, sizeof(*outStats)); outStats->payloadType = -1; return; }
    *outStats = dp->stats;

    // Fold the H.264 layer's counters into the transport's, so every existing
    // reader (the 1 Hz [WHEP-RTP] line, -rtpStatsSummary) keeps seeing one
    // struct with the same fields and the same values.
    ManifoldH264AccessUnitBuilderStats au;
    ManifoldH264AccessUnitBuilderCopyStats(dp->builder, &au);
    outStats->nalSPS              = au.nalSPS;
    outStats->nalPPS              = au.nalPPS;
    outStats->nalIDR              = au.nalIDR;
    outStats->nalSlice            = au.nalSlice;
    outStats->nalSEI              = au.nalSEI;
    outStats->nalAUD              = au.nalAUD;
    outStats->nalOther            = au.nalOther;
    outStats->accessUnits         = au.accessUnits;
    outStats->keyframes           = au.keyframes;
    outStats->accessUnitsOversize = au.accessUnitsOversize;
    outStats->spsSize             = au.spsSize;
    outStats->ppsSize             = au.ppsSize;
    // A zero-length NAL used to be counted as packetsMalformed at the point the
    // builder rejected it. Same number, added a layer later.
    outStats->packetsMalformed   += au.nalEmpty;
}
