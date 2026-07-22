//
//  H264Depacketizer.h
//  Manifold
//
//  RFC 6184 H.264 RTP depacketizer — RTP packets in, complete NAL units out,
//  grouped into access units.
//
//  WHY THIS EXISTS. libdatachannel does NOT depacketize INBOUND media. Its
//  media handlers are packetizers (rtcSetH264Packetizer & co.) for the send
//  direction; on a recvonly track the message callback hands us RAW RTP, one
//  packet per callback, exactly as it came off the wire (post-SRTP-decrypt).
//  Turning that back into NAL units is our job, and this is it.
//
//  PURE C, NO DEPENDENCIES. Nothing here knows about libdatachannel,
//  Foundation, or VideoToolbox. It is a byte-in/byte-out state machine, which
//  keeps it trivially testable and keeps the linkage discipline of
//  DataChannelBridge.m (a `.m`, never a `.mm`) intact.
//
//  THREADING. NOT thread-safe, by design. One instance is owned by exactly one
//  producer — libdatachannel's per-track Processor thread, which is serialized
//  per track — so it needs no internal locking. Any OTHER thread reading stats
//  (the 1 Hz logger) must serialize against the producer externally; see
//  ManifoldWHEPSession, which holds an os_unfair_lock over both.
//
//  STEP 3a OF 4 (WHEP): NALs arriving, correctly typed and counted. NO DECODE.
//

#ifndef MANIFOLD_H264_DEPACKETIZER_H
#define MANIFOLD_H264_DEPACKETIZER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque depacketizer state. One per inbound video track.
typedef struct ManifoldH264Depacketizer ManifoldH264Depacketizer;

/// Everything the step-3a checkpoint needs to prove depacketization works, plus
/// the loss counters that say whether the NETWORK (rather than this code) is the
/// reason a NAL came out malformed. Monotonic; snapshot and diff for rates.
typedef struct {
    // ── Packets ──────────────────────────────────────────────────────────────
    uint64_t packetsReceived;          ///< Everything handed to Submit, including rejects below.
    uint64_t packetsAccepted;          ///< Passed PT/SSRC/header validation and was depacketized.
    uint64_t packetsRTCP;              ///< PT 72–76: RTCP that leaked through rtcp-mux. Expected to be 0.
    uint64_t packetsWrongPayloadType;  ///< Not the negotiated H.264 PT — RTX, audio, a second codec.
    uint64_t packetsWrongSSRC;         ///< A different source than the one we latched (RTX/simulcast).
    uint64_t packetsMalformed;         ///< Truncated, bad version, or a header that overruns the packet.

    // ── Sequence numbers (RFC 3550 §5.1) ─────────────────────────────────────
    uint64_t seqGaps;                  ///< Discontinuity EVENTS (one per gap, not per lost packet).
    uint64_t packetsLost;              ///< Packets implied missing by those gaps.
    uint64_t packetsReordered;         ///< Arrived with seq <= the highest seen: late or duplicate.

    // ── NAL units emitted, by nal_unit_type (RFC 6184 §1.3 / H.264 Table 7-1) ─
    uint64_t nalSPS;                   ///< 7
    uint64_t nalPPS;                   ///< 8
    uint64_t nalIDR;                   ///< 5  — coded slice of an IDR picture
    uint64_t nalSlice;                 ///< 1  — coded slice, non-IDR
    uint64_t nalSEI;                   ///< 6
    uint64_t nalAUD;                   ///< 9  — access unit delimiter (dropped from output)
    uint64_t nalOther;                 ///< Any other single-NAL type we understood but do not classify.
    uint64_t nalUnsupported;           ///< Packet types we deliberately do not implement (see .c).

    // ── Fragmentation (FU-A, type 28) ────────────────────────────────────────
    uint64_t fuaPackets;               ///< FU-A packets seen (all fragments).
    uint64_t fuaReassembled;           ///< Complete NALs rebuilt from fragments (start…end).
    uint64_t fuaDropped;               ///< Fragments abandoned: loss mid-NAL, missing start, or oversize.

    // ── Access units ─────────────────────────────────────────────────────────
    uint64_t accessUnits;              ///< Frames emitted (non-empty AUs).
    uint64_t keyframes;                ///< AUs containing an IDR slice.
    uint64_t accessUnitsByTimestamp;   ///< AUs closed by an RTP-timestamp change, i.e. a LOST marker bit.
    uint64_t accessUnitsOversize;      ///< AUs that blew the sanity cap and were discarded.

    // ── Latched state ────────────────────────────────────────────────────────
    int      payloadType;              ///< Negotiated (or latched) H.264 payload type; -1 if unknown.
    uint32_t ssrc;                     ///< The SSRC we locked onto.
    uint32_t lastRTPTimestamp;         ///< 90 kHz. Becomes the PTS basis in step 3b.
    size_t   spsSize;                  ///< Bytes of SPS held (0 = none yet).
    size_t   ppsSize;                  ///< Bytes of PPS held (0 = none yet).
} ManifoldH264DepacketizerStats;

/// One complete access unit: every VCL NAL sharing an RTP timestamp, concatenated.
///
/// FORMAT IS AVCC (length-prefixed), NOT Annex-B: each NAL is preceded by its
/// length as a 4-byte big-endian integer. See the header comment in the .c file
/// for why. Parameter sets are NOT in here — they are carried out-of-band in
/// `sps`/`pps`, which is what CMVideoFormatDescriptionCreateFromH264ParameterSets
/// wants and what VTDecompressionSession requires.
typedef struct {
    const uint8_t *data;            ///< AVCC bytes. Valid ONLY for the duration of the callback.
    size_t         size;
    uint32_t       rtpTimestamp;    ///< 90 kHz sender clock.
    bool           keyframe;        ///< Contains an IDR slice.
    bool           parameterSetsChanged; ///< SPS or PPS differed from the last ones; rebuild the format description.
    const uint8_t *sps;             ///< Latest SPS (no start code, no length prefix), or NULL.
    size_t         spsSize;
    const uint8_t *pps;
    size_t         ppsSize;
} ManifoldH264AccessUnit;

/// Fires on the PRODUCER thread (libdatachannel's), inline, once per access unit.
/// Copy anything you keep. Step 3a leaves this NULL — counting is the checkpoint.
typedef void (*ManifoldH264AccessUnitHandler)(const ManifoldH264AccessUnit *accessUnit, void *context);

/// Allocates a depacketizer. Returns NULL only on allocation failure.
ManifoldH264Depacketizer *ManifoldH264DepacketizerCreate(void);

void ManifoldH264DepacketizerDestroy(ManifoldH264Depacketizer *depacketizer);

/// Sets the negotiated H.264 payload type; packets with any other PT are counted
/// and ignored. Pass -1 (the default) to latch onto the first non-RTCP PT seen —
/// a fallback, not a plan: it will happily latch onto RTX if RTX arrives first.
void ManifoldH264DepacketizerSetPayloadType(ManifoldH264Depacketizer *depacketizer, int payloadType);

/// Installs the access-unit sink. Step 3b's decoder hangs here.
void ManifoldH264DepacketizerSetAccessUnitHandler(ManifoldH264Depacketizer *depacketizer,
                                                  ManifoldH264AccessUnitHandler handler,
                                                  void *context);

/// Feeds ONE RTP packet — the complete packet including its 12-byte header, as
/// libdatachannel delivers it. Never blocks, never allocates in the steady state
/// (buffers grow once and are reused), never logs.
void ManifoldH264DepacketizerSubmitRTP(ManifoldH264Depacketizer *depacketizer,
                                       const uint8_t *packet, size_t size);

/// Emits any access unit still open (i.e. whose marker bit never arrived).
/// Call at end of stream. Producer thread only.
void ManifoldH264DepacketizerFlush(ManifoldH264Depacketizer *depacketizer);

/// Copies the counters out. Caller must serialize against the producer thread.
void ManifoldH264DepacketizerCopyStats(const ManifoldH264Depacketizer *depacketizer,
                                       ManifoldH264DepacketizerStats *outStats);

#ifdef __cplusplus
}
#endif

#endif /* MANIFOLD_H264_DEPACKETIZER_H */
