//
//  RTCPWire.c
//  RTCPWire
//
//  Encoders and the one parser for the video track's own RTCP. See RTCPWire.h for why this exists
//  and why it is a leaf target.
//

#include "RTCPWire.h"

#include <string.h>

static void MRPutBE16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void MRPutBE32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

static uint32_t MRGetBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

// ── PLI ─────────────────────────────────────────────────────────────────────────────────────────
//
//  RFC 4585 §6.1 common feedback format, §6.3.1 PLI (FMT=1, no FCI):
//
//      |V=2|P| FMT=1 |    PT=206     |          length=2             |
//      |                  SSRC of packet sender                      |
//      |                  SSRC of media source                       |

size_t ManifoldRTCPBuildPli(uint8_t *out, size_t capacity,
                            uint32_t senderSSRC, uint32_t mediaSSRC) {
    if (!out || capacity < MANIFOLD_RTCP_PLI_BYTES) return 0;
    out[0] = (uint8_t)(0x80u | 1u);                        // V=2, P=0, FMT=1 (PLI)
    out[1] = 206u;                                         // PT = PSFB
    MRPutBE16(out + 2, MANIFOLD_RTCP_PLI_BYTES / 4u - 1u); // 32-bit words MINUS ONE
    MRPutBE32(out + 4, senderSSRC);
    MRPutBE32(out + 8, mediaSSRC);
    return MANIFOLD_RTCP_PLI_BYTES;
}

// ── RECEIVER REPORT ─────────────────────────────────────────────────────────────────────────────
//
//  RFC 3550 §6.4.2, RC=1:
//
//      |V=2|P|  RC=1   |    PT=201     |          length=7             |
//      |                     SSRC of packet sender                     |
//      |                 SSRC_1 (SSRC of first source)                 |
//      | fraction lost |       cumulative number of packets lost       |
//      |           extended highest sequence number received           |
//      |                      interarrival jitter                      |
//      |                         last SR (LSR)                         |
//      |                   delay since last SR (DLSR)                  |

size_t ManifoldRTCPBuildReceiverReport(uint8_t *out, size_t capacity, uint32_t senderSSRC,
                                       const ManifoldRTCPReportBlock *block) {
    if (!out || !block || capacity < MANIFOLD_RTCP_RR_ONE_BLOCK_BYTES) return 0;
    out[0] = (uint8_t)(0x80u | 1u);                        // V=2, P=0, RC=1
    out[1] = 201u;                                         // PT = RR
    MRPutBE16(out + 2, MANIFOLD_RTCP_RR_ONE_BLOCK_BYTES / 4u - 1u);
    MRPutBE32(out + 4, senderSSRC);

    uint8_t *b = out + 8;
    MRPutBE32(b, block->ssrc);

    // Cumulative lost is a SIGNED 24-bit field (§6.4.1: "may be negative if there are duplicates"),
    // clamped rather than wrapped — a wrapped value would read as the opposite sign.
    int32_t lost = block->cumulativeLost;
    if (lost >  0x7FFFFF) lost =  0x7FFFFF;
    if (lost < -0x800000) lost = -0x800000;
    const uint32_t lost24 = (uint32_t)lost & 0xFFFFFFu;
    MRPutBE32(b + 4, ((uint32_t)block->fractionLost << 24) | lost24);

    MRPutBE32(b + 8,  block->extendedHighestSeq);
    MRPutBE32(b + 12, block->jitter);
    MRPutBE32(b + 16, block->lastSR);
    MRPutBE32(b + 20, block->delaySinceLastSR);
    return MANIFOLD_RTCP_RR_ONE_BLOCK_BYTES;
}

uint8_t ManifoldRTCPFractionLost(uint32_t expectedInterval, int64_t lostInterval) {
    if (expectedInterval == 0 || lostInterval <= 0) return 0;
    const uint64_t f = ((uint64_t)lostInterval << 8) / expectedInterval;
    return f > 255u ? 255u : (uint8_t)f;
}

uint32_t ManifoldRTCPDelaySinceSR(uint64_t elapsedNs) {
    // Split to avoid overflowing `elapsedNs << 16` for long delays: whole seconds, then the rest.
    const uint64_t secs  = elapsedNs / 1000000000ull;
    const uint64_t rest  = elapsedNs % 1000000000ull;
    const uint64_t units = (secs << 16) + ((rest << 16) / 1000000000ull);
    return units > UINT32_MAX ? UINT32_MAX : (uint32_t)units;
}

// ── INTERARRIVAL JITTER ─────────────────────────────────────────────────────────────────────────
//
//  RFC 3550 A.8, verbatim in integer form:
//
//      transit = arrival - rtp_ts;  d = |transit - last_transit|;  J += d - ((J + 8) >> 4)
//
//  with J held scaled by 16. The first packet only seeds `lastTransit`: A.8 leaves the initial
//  transit implicit, and a D taken against zero would be the whole transit time, not a jitter.

void ManifoldRTCPJitterUpdate(ManifoldRTCPJitter *state, uint32_t arrivalInRtpUnits,
                              uint32_t rtpTimestamp) {
    if (!state) return;
    const uint32_t transit = arrivalInRtpUnits - rtpTimestamp;
    if (!state->haveTransit) {
        state->haveTransit = true;
        state->lastTransit = transit;
        return;
    }
    int64_t d = (int64_t)(int32_t)(transit - state->lastTransit);
    state->lastTransit = transit;
    if (d < 0) d = -d;
    const int64_t j = (int64_t)state->jitterQ4 + d - (((int64_t)state->jitterQ4 + 8) >> 4);
    state->jitterQ4 = j < 0 ? 0 : (j > UINT32_MAX ? UINT32_MAX : (uint32_t)j);
}

// ── SENDER REPORT SELECTION ─────────────────────────────────────────────────────────────────────

bool ManifoldRTCPFindSenderReport(const uint8_t *p, size_t len, uint32_t ssrc,
                                  ManifoldRTCPSenderReport *out) {
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    if (!p) return false;

    size_t offset = 0;
    while (offset + 4 <= len) {
        if ((p[offset] >> 6) != 2) break;                       // version must be 2
        const uint8_t rc     = p[offset] & 0x1Fu;               // report/chunk count
        const uint8_t pt     = p[offset + 1];
        const size_t  words  = (size_t)((p[offset + 2] << 8) | p[offset + 3]);
        const size_t  pktLen = (words + 1u) * 4u;               // header included
        if (offset + pktLen > len) break;

        if (pt == 200 && pktLen >= 28) {                        // SR: 4 hdr + 24 sender info
            const uint8_t *b = p + offset + 4;
            out->senderReportsSeen++;
            if (!out->haveSR && MRGetBE32(b) == ssrc) {
                out->ssrc = ssrc;
                out->ntp  = ((uint64_t)MRGetBE32(b + 4) << 32) | (uint64_t)MRGetBE32(b + 8);
                out->rtp  = MRGetBE32(b + 12);
                out->senderPacketCount = MRGetBE32(b + 16);
                out->senderOctetCount  = MRGetBE32(b + 20);
                out->haveSR = true;
            }
        } else if (pt == 202 && !out->haveCNAME) {              // SDES
            const size_t end = offset + pktLen;
            size_t c = offset + 4;
            for (uint8_t chunk = 0; chunk < rc && c + 4 <= end; chunk++) {
                const bool ours = MRGetBE32(p + c) == ssrc;
                size_t item = c + 4;                            // past the chunk SSRC
                while (item < end) {
                    const uint8_t type = p[item];
                    if (type == 0) { item++; break; }           // end of this chunk's items
                    if (item + 2 > end) { item = end; break; }
                    const uint8_t itemLen = p[item + 1];
                    if (item + 2 + itemLen > end) { item = end; break; }
                    if (type == 1 && ours && !out->haveCNAME) { // CNAME
                        const size_t n = itemLen < sizeof(out->cname) - 1
                                       ? itemLen : sizeof(out->cname) - 1;
                        memcpy(out->cname, p + item + 2, n);
                        out->cname[n] = '\0';
                        out->haveCNAME = true;
                    }
                    item += 2u + itemLen;
                }
                c = (item + 3) & ~(size_t)3;                    // chunks are 32-bit aligned
            }
        }
        offset += pktLen;
    }
    return out->haveSR;
}
