//
//  H264Depacketizer.h
//  Manifold
//
//  RFC 6184 H.264 RTP depacketizer — RTP packets in, complete NAL units out,
//  grouped into access units.
//
//  SCOPE. This file is the RTP half only: header geometry, PT/SSRC latching,
//  sequence accounting, STAP-A and FU-A reassembly, and the two access-unit
//  boundary signals (marker bit, and an RTP-timestamp change as the safety net
//  for a lost one). Everything downstream of "here is one complete NAL unit" —
//  type classification, SPS/PPS extraction, AVCC assembly — lives in
//  H264AccessUnitBuilder.h, which the SRT path shares. ManifoldH264AccessUnit
//  and its handler typedef are defined there and re-exported through this header.
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

// ManifoldH264AccessUnit + ManifoldH264AccessUnitHandler: the output contract,
// shared with every other transport. Included rather than redeclared so existing
// consumers (DataChannelBridge.m) need no change.
#include "H264AccessUnitBuilder.h"

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

    // ── Loss reconciliation ──────────────────────────────────────────────────
    //
    // ⚠️ `packetsLost` ABOVE MEANS "DECLARED MISSING AT GAP-DETECTION TIME", and it keeps that
    // meaning. It is a zero-lookahead observation made at a well-defined instant and never
    // revisited. It is NOT a count of genuine loss — `packetsStillMissing` is.
    //
    // These four reconcile it, and the identity below is exact at every snapshot:
    //
    //       packetsLost == packetsRecovered + packetsStillMissing + packetsOutstanding
    //
    // Read the LOSS ACCOUNTING note in H264Depacketizer.c before changing any of them; the
    // reason the identity is stated as an identity, rather than left to the reader, is that the
    // previous generation of these counters (`lost` vs `reorder`) had to be audited against the
    // source before anyone could tell what they meant.
    uint64_t packetsRecovered;         ///< Declared missing, then ARRIVED inside the recovery window.
    uint64_t packetsStillMissing;      ///< Declared missing, window closed, never arrived. GENUINE LOSS.
    uint64_t packetsOutstanding;       ///< Declared missing, window still open at snapshot time.
    uint64_t outstandingOverflow;      ///< Missing seqs never tracked (table full). Counted in StillMissing.

    // Declaration→arrival delay for recovered packets. With no retransmission in the stack these
    // measure ORDINARY REORDERING; once something retransmits they measure retransmit latency,
    // which is the number that says whether a recovered packet beat its display deadline.
    uint64_t recoveryLatencyUsTotal;   ///< Sum of delays, microseconds. Divide by packetsRecovered.
    uint64_t recoveryLatencyUsMax;     ///< Worst single delay, microseconds.

    // ── WHEN THE WINDOW IS THE LIMIT, RATHER THAN THE NETWORK ────────────────
    //
    // A packet that arrives after we have already written it off is not the network failing to
    // deliver it. It is `recoveryWindowMs` being set tighter than this path's round trip — we
    // asked, the answer came, and we had already stopped listening. That distinction is the
    // entire reason the latency presets exist, and without a counter for it a user on the
    // shortest cushion sees a picture breaking up with loss counters identical to a genuinely
    // lossy link.
    //
    // ⚠️ A SUBSET OF `packetsStillMissing`, NOT A NEW TERM IN THE IDENTITY. These were counted
    // as still-missing when the window closed, and they are NOT subtracted back out when they
    // turn up. Two reasons, both the same ones the identity note above gives: the verdict must
    // be knowable at the instant it is made, and a counter that revises itself later cannot be
    // compared against the Run A–D baselines.
    uint64_t packetsLateAfterGiveUp;   ///< Written off, then arrived anyway. The WINDOW was short.
    uint64_t lateAfterGiveUpUsTotal;   ///< Sum of their declaration→arrival delays, microseconds.
    uint64_t lateAfterGiveUpUsMax;     ///< The worst one: `recoveryWindowMs` had to exceed this.

    // ── NACK requester ───────────────────────────────────────────────────────
    //
    // `nacksSent` is the INDEPENDENT evidence that the requester works. `packetsRecovered` and
    // `packetsReordered` are the same arrival counted twice from two sides — they cross-check
    // each other and neither can confirm that anything left this machine. This one can.
    uint64_t nacksSent;                ///< RTCP feedback packets handed to the sink (one per call).
    uint64_t nackSeqsRequested;        ///< Sequence numbers asked for, retries included.
    uint64_t nackSeqsSuppressedByRate; ///< Due to be asked for; the rate governor was empty. Never asked.
    uint64_t nackGapsTooLarge;         ///< Gap EVENTS too wide to be worth asking for. See BURSTS in the .c.

    // ── NAL units emitted, by nal_unit_type (RFC 6184 §1.3 / H.264 Table 7-1) ─
    // Counted by the access-unit builder and folded in by CopyStats; the values
    // and their meanings are unchanged.
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

/// Allocates a depacketizer. Returns NULL only on allocation failure.
ManifoldH264Depacketizer *ManifoldH264DepacketizerCreate(void);

void ManifoldH264DepacketizerDestroy(ManifoldH264Depacketizer *depacketizer);

/// Sets the negotiated H.264 payload type; packets with any other PT are counted
/// and ignored. Pass -1 (the default) to latch onto the first non-RTCP PT seen —
/// a fallback, not a plan: it will happily latch onto RTX if RTX arrives first.
void ManifoldH264DepacketizerSetPayloadType(ManifoldH264Depacketizer *depacketizer, int payloadType);

/// ── THE LOSS-RECOVERY POLICY, IN ONE STRUCT ──────────────────────────────────────────
///
/// ⚠️ THIS IS THE LEVER THE LATENCY PRESETS OWN. Every one of these is a parameter rather than
/// a constant on purpose, and they are gathered into one struct rather than left as six setters
/// so that a preset is a single assignment that can be read, logged, and diffed as a unit.
///
/// They are not independent of the render cushion. `recoveryWindowMs` is the time a missing
/// packet is worth waiting for, and waiting is only free while the frame it belongs to has not
/// been displayed — so the window must be sized against WHEPFrameRouter.targetDepth, not chosen
/// beside it. Today both are 400 ms and they agree by coincidence rather than by construction;
/// the preset work is what should make one derive from the other.
typedef struct {
    /// How long a declared-missing sequence number stays outstanding before it is written off as
    /// genuine loss. A packet arriving after its frame's display deadline is not a recovery in
    /// any useful sense. Zero is refused, not honoured (see the .c).
    unsigned int recoveryWindowMs;

    /// Delay between declaring a sequence number missing and the FIRST request for it.
    ///
    /// Default 0 — ask at once — and that default is provisional. Run C (`reorder=0`) is a
    /// regime where a hold-off buys nothing; Run B (`lost=95 reorder=94`) is one where asking
    /// immediately wastes almost every request on packets already on their way. The number that
    /// settles it is the reordering delay distribution, which `recoveryLatencyUs avg/max`
    /// measures directly whenever this is 0. SET IT FROM A MEASUREMENT, not from a guess.
    unsigned int firstAskDelayMs;

    /// Gap between repeat requests for a sequence number still outstanding.
    unsigned int retryIntervalMs;

    /// Repeats after the first request. 2 → up to three asks per missing packet.
    /// Asking stops early when a reply could no longer arrive inside the window.
    unsigned int maxRetries;

    /// A single gap wider than this is treated as an OUTAGE rather than as loss: it is counted,
    /// but it is neither tracked nor requested. See BURSTS AND STORMS in the .c for why
    /// retransmission is the wrong tool above this width, and what happens instead.
    unsigned int maxGapToRequest;

    /// Ceiling on sequence numbers requested per second, retries included — the anti-storm
    /// governor. Sized ABOVE the measured worst case so that it never shapes an ordinary loss
    /// event and only bites on pathology. Requests refused by it are counted, never silently
    /// dropped.
    unsigned int budgetSeqsPerSecond;
} ManifoldH264LossPolicy;

/// The defaults, as documented above. Take this and modify what a preset needs.
ManifoldH264LossPolicy ManifoldH264DefaultLossPolicy(void);

/// Applies a policy. Fields that would disable the instrument rather than tune it (a zero
/// window) are refused individually; the rest are taken as given.
void ManifoldH264DepacketizerSetLossPolicy(ManifoldH264Depacketizer *depacketizer,
                                           const ManifoldH264LossPolicy *policy);

/// Where a NACK request goes. `seqs` holds `count` sequence numbers in ASCENDING order and is
/// BORROWED — valid only for the duration of the call.
///
/// Called from inside ManifoldH264DepacketizerSubmitRTP, on the producer thread, exactly once
/// per RTCP feedback packet that should go out. The implementation owns the RFC 4585 encoding
/// and the sending; this file deliberately knows nothing about RTCP, which is what keeps it
/// pure C with no libdatachannel in it. MUST NOT BLOCK.
typedef void (*ManifoldH264NackRequestHandler)(const uint16_t *seqs, unsigned int count,
                                               uint32_t ssrc, void *context);

/// Installs the NACK sink. With no sink installed the outstanding table still runs and every
/// counter above still means what it says — the requester is what is switched on here, not the
/// measurement. Leave it unset when the server did not agree to `a=rtcp-fb:<pt> nack`.
void ManifoldH264DepacketizerSetNackRequestHandler(ManifoldH264Depacketizer *depacketizer,
                                                   ManifoldH264NackRequestHandler handler,
                                                   void *context);

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
