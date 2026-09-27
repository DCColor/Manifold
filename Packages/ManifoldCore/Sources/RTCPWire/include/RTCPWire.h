//
//  RTCPWire.h
//  RTCPWire
//
//  The RTCP a WHEP receiver sends and reads on its VIDEO track, now that Manifold owns that track's
//  RTCP instead of libdatachannel's RtcpReceivingSession (step 4e-1, docs/AV_SYNC_FINDINGS.md):
//
//    * PLI                — RFC 4585 §6.3.1, the keyframe request
//    * Receiver Report    — RFC 3550 §6.4.2, one report block
//    * interarrival jitter — RFC 3550 §6.4.1 / A.8, the estimator the RR carries
//    * SR selection       — RFC 3550 §6.4.1, the SR for ONE SSRC out of a compound packet
//
//  PURE C, NO DEPENDENCIES, AND A LEAF PACKAGE TARGET, for the same reason RTCPNack.c is split out
//  of DataChannelBridge.m: a wrong bit here is a SILENT failure. A server ignores a malformed RR or
//  PLI, or reads a wrong LSR as a wild RTT, and nothing in this app would notice. Byte-laying that
//  cannot be observed at runtime has to be observable at test time instead. It lives in the package
//  rather than App/WebRTC so `swift test` can link it (see RTCPWireTests).
//
//  ⚠️ SSRC FIELDS. A recvonly receiver has no SSRC of its own — Manifold's offer advertises none,
//  deliberately (kManifoldWHEPVideoMSection). The builders take the packet-sender SSRC as a parameter
//  rather than deciding it; the bridge passes the MEDIA source's SSRC, which is what libdatachannel's
//  RtcpReceivingSession put there for RR and PLI and what RTCPNack.c puts there for NACK. Changing it
//  is one argument at the call site.
//

#ifndef MANIFOLD_RTCP_WIRE_H
#define MANIFOLD_RTCP_WIRE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── PLI ─────────────────────────────────────────────────────────────────────────────────────────

/// A PLI is the RTCP header plus the two SSRCs and no FCI: 12 bytes, length field 2.
#define MANIFOLD_RTCP_PLI_BYTES 12u

/// Encodes a Picture Loss Indication (PT=206 PSFB, FMT=1). Returns 12, or 0 if it does not fit.
size_t ManifoldRTCPBuildPli(uint8_t *out, size_t capacity,
                            uint32_t senderSSRC, uint32_t mediaSSRC);

// ── RECEIVER REPORT ─────────────────────────────────────────────────────────────────────────────

/// One RFC 3550 §6.4.1 report block, in host units. The encoder does the field packing.
typedef struct {
    uint32_t ssrc;                 ///< SSRC_n — the source this block reports on.
    uint8_t  fractionLost;         ///< 8-bit fixed point, lost/expected since the previous report.
    int32_t  cumulativeLost;       ///< Clamped to the 24-bit signed field on encode.
    uint32_t extendedHighestSeq;   ///< Cycles in the high 16 bits, highest seq in the low 16.
    uint32_t jitter;               ///< Timestamp units — ManifoldRTCPJitterValue, not the Q4 state.
    uint32_t lastSR;               ///< LSR: middle 32 bits of the last SR's NTP. 0 = no SR yet.
    uint32_t delaySinceLastSR;     ///< DLSR: 1/65536 s since that SR arrived. 0 = no SR yet.
} ManifoldRTCPReportBlock;

/// Header (4) + sender SSRC (4) + one 24-byte report block.
#define MANIFOLD_RTCP_RR_ONE_BLOCK_BYTES 32u

/// Encodes a Receiver Report (PT=201) carrying exactly ONE report block. Returns 32, or 0.
size_t ManifoldRTCPBuildReceiverReport(uint8_t *out, size_t capacity, uint32_t senderSSRC,
                                       const ManifoldRTCPReportBlock *block);

/// RFC 3550 A.3's fraction-lost for one reporting interval. `lostInterval` may be negative
/// (duplicates, late arrivals); anything <= 0, or an empty interval, is 0.
uint8_t ManifoldRTCPFractionLost(uint32_t expectedInterval, int64_t lostInterval);

/// LSR from a 64-bit 32.32 NTP timestamp as it appears in the SR.
static inline uint32_t ManifoldRTCPCompactNTP(uint64_t ntp) { return (uint32_t)(ntp >> 16); }

/// DLSR from an elapsed interval in nanoseconds, in 1/65536 s units. Saturates rather than wraps.
uint32_t ManifoldRTCPDelaySinceSR(uint64_t elapsedNs);

// ── INTERARRIVAL JITTER (RFC 3550 A.8) ──────────────────────────────────────────────────────────

/// Estimator state. Zero-initialise. `jitterQ4` is J scaled by 16, which is A.8's integer form.
typedef struct {
    uint32_t jitterQ4;
    uint32_t lastTransit;
    bool     haveTransit;
} ManifoldRTCPJitter;

/// Feed one received packet: its arrival time and its RTP timestamp, BOTH in the stream's RTP clock
/// units (90 kHz for video). Wrapping arithmetic throughout, so neither needs unwrapping.
void ManifoldRTCPJitterUpdate(ManifoldRTCPJitter *state, uint32_t arrivalInRtpUnits,
                              uint32_t rtpTimestamp);

static inline uint32_t ManifoldRTCPJitterValue(const ManifoldRTCPJitter *state) {
    return state->jitterQ4 >> 4;
}

// ── SENDER REPORT SELECTION ─────────────────────────────────────────────────────────────────────

/// What one compound RTCP packet said about ONE SSRC. `ntp` stays in the WIRE format — 32.32 fixed
/// point seconds since 1900: two NTP values subtracted as int64 are exact, while converting each to
/// a double first throws away ~1 us at that magnitude.
typedef struct {
    bool     haveSR;
    uint32_t ssrc;
    uint64_t ntp;
    uint32_t rtp;
    uint32_t senderPacketCount;
    uint32_t senderOctetCount;
    uint32_t senderReportsSeen;    ///< SRs in the packet for ANY SSRC — context for a non-match.
    bool     haveCNAME;
    char     cname[256];
} ManifoldRTCPSenderReport;

/// Walks a compound RTCP packet (RFC 3550 §6.1) and records the SR whose sender SSRC is `ssrc`, and
/// the SDES CNAME of the chunk for that same SSRC. Returns true if that SR was present.
///
/// ⚠️ MATCHED BY SSRC, NEVER "THE FIRST SR". Under BUNDLE libdatachannel hands a compound packet to
/// EVERY track whose SSRC appears anywhere in it (PeerConnection::dispatchMedia), so a packet that
/// carries both streams' SRs reaches the audio AND the video callback whole. Taking the first SR
/// would hand one track the other's clock mapping.
///
/// ⚠️ SDES IS OFTEN ABSENT AND THAT IS LEGAL. Servers answering `a=rtcp-rsize` (RFC 5506) may send
/// the SR alone, so `haveCNAME` is reported, never assumed.
bool ManifoldRTCPFindSenderReport(const uint8_t *packet, size_t length, uint32_t ssrc,
                                  ManifoldRTCPSenderReport *out);

#ifdef __cplusplus
}
#endif

#endif /* MANIFOLD_RTCP_WIRE_H */
