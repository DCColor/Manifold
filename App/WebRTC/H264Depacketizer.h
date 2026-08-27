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

/// Where the round-trip figure driving retransmit attribution came from. REPORTED, ALWAYS —
/// two diagnostics exports from different testers are not comparable without it.
///
/// ── WHY THERE IS NO MEASURED-RTT MEMBER, WHICH IS THE ONE YOU WANT ──────────────────────────
///
/// Three routes were tried. All three are closed on this transport:
///
///   1. RTCP SR/DLSR. The arithmetic runs SENDER→RECEIVER and cannot be turned around. LSR and
///      DLSR live in a RECEPTION REPORT BLOCK, which describes a source the reporter RECEIVES
///      RTP FROM. We compute them and put them in the RR we send, and the SERVER learns OUR
///      round trip. A WHEP receiver sends no RTP, so no conforming sender will ever emit a
///      report block about us. This is the shape of the protocol, not a library gap.
///
///   2. RTCP XR (RFC 3611) RRTR + DLRR, which exists precisely for receive-only endpoints.
///      VERIFIED ABSENT from the vendored libdatachannel — rtp.hpp defines SR, RR, SDES, REMB,
///      PLI, FIR and NACK and no XR of any kind.
///
///   3. NACKing a packet WE ALREADY HOLD and timing the duplicate back. MEASURED IN THE FIELD:
///      73 probes sent, 73 timed out, 0 answered. SRTP replay protection (RFC 3711 §3.3.2)
///      rejects it — a retransmit of an already-received packet has the same SSRC and sequence
///      number, so it computes to the same SRTP packet index and `srtp_unprotect` drops it as a
///      replay before libdatachannel's callback, let alone ours. The vendored libsrtp2 exports
///      `srtp_rdbx_check`; libdatachannel carries the string "Incoming SRTP packet is a replay".
///      An SFU that believes the packet was delivered has no reason to resend it either, so the
///      idea was doubly dead. DO NOT REVIVE IT.
///
/// What WOULD work is RTX (RFC 4588): retransmissions on a separate SSRC with their own
/// sequence-number space, which sidesteps replay AND makes a retransmit self-identifying, so
/// attribution would need no floor at all. We do not offer it (see kManifoldWHEPVideoMSection).
/// Until we do, the honest position is that this app cannot measure a media round trip, and the
/// signalling POST — labelled COARSE wherever it appears — is the only figure available.
typedef enum {
    /// No measurement of any kind. ⚠️ ATTRIBUTION IS SUSPENDED — recoveries go to
    /// `recoveredUnattributed` rather than being guessed into a bucket.
    ManifoldRttSourceNone = 0,
    /// The WHEP signalling POST round trip, discounted. A real measurement of a DIFFERENT PATH:
    /// TCP+TLS to an HTTP endpoint including the server's SDP work. Always an overestimate of
    /// the UDP media path, and never to be reported without the word COARSE next to it.
    ManifoldRttSourceSignalling,
} ManifoldRttSource;

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

    // ── WHICH RECOVERIES OUR NACK CAN ACTUALLY TAKE CREDIT FOR ───────────────
    //
    // ⚠️ `packetsRecovered` ABOVE COUNTS ARRIVALS, NOT REPAIRS, AND THE TWO ARE NOT THE SAME
    // THING ONCE THE LINK IS CONGESTED. A retransmit arrives on the same SSRC bearing the same
    // sequence number as the original, so the packet itself carries NO evidence of which it is.
    // Under saturation — which is the condition the NACK work was measured under — packets are
    // delayed rather than dropped, so a sequence number we declared missing is frequently a
    // packet that was already in flight. It then arrives, and the old code counted it as a
    // recovery indistinguishable from a genuine retransmit.
    //
    // The tell was a 245 MICROSECOND recovery on a quiet wired run. Nothing makes a round trip
    // to an edge server in 245 µs; that arrival was a late original, and it was being folded
    // into the same mean and max that the latency presets are sized from.
    //
    // These three partition `packetsRecovered` exactly:
    //
    //   packetsRecovered == recoveredUnrequested + recoveredBeforeFloor
    //                       + recoveredAttributable + recoveredUnattributed
    //
    // and only the third can contain retransmits caused by us. The first two are LOWER BOUNDS on
    // late originals, not estimates: each is established by a fact, not by a threshold on the
    // aggregate. The third is an UPPER bound on genuine retransmits — it is what remains after
    // the arrivals we can prove were not retransmits have been removed, and it certainly still
    // contains late originals that happened to arrive slowly.
    uint64_t recoveredUnrequested;     ///< NO NACK WAS EVER SENT for this seq (`asks == 0`).
                                       ///< Cannot be a response to a request that does not exist.
                                       ///< Arises from gapsTooWide, the rate governor, firstAskDelay,
                                       ///< and arrival before the service loop's next pass.
    uint64_t recoveredBeforeFloor;     ///< Asked for, but arrived less than `attributionFloorUs`
                                       ///< after the FIRST ask went out — faster than any plausible
                                       ///< round trip, so the reply cannot have caused it.
    uint64_t recoveredAttributable;    ///< Asked for, and arrived at or after the floor. THE ONLY
                                       ///< ONES A RETRANSMIT EXPLANATION FITS. Size presets from
                                       ///< these, not from `recoveryLatencyUs*`.

    /// Asked for, arrived, AND WE HAD NO ROUND-TRIP MEASUREMENT AT THE TIME, so there was no
    /// floor to test against and no honest bucket to put it in.
    ///
    /// ⚠️ THIS COUNTER EXISTS SO THAT "WE DO NOT KNOW" HAS SOMEWHERE TO GO. The alternative —
    /// defaulting to attributable, or to below-floor, whenever RTT is unknown — would put a
    /// guess into a number whose entire purpose is to be a bound, and it would do it silently.
    /// A session that never gets an RTT reads `unattributed=N` and is instantly recognisable as
    /// uninterpretable, instead of quietly reporting a confident wrong answer. Expect a handful
    /// at the very start of every session, before the first probe lands.
    uint64_t recoveredUnattributed;

    /// Declaration→arrival latency for `recoveredAttributable` ONLY. Same clock and same origin as
    /// `recoveryLatencyUs*` above so the two are directly comparable — the difference between them
    /// is precisely the skew the late originals were contributing.
    uint64_t attributableLatencyUsTotal;
    uint64_t attributableLatencyUsMax;

    /// FIRST-ASK→arrival latency for the attributable ones. A different and better question than
    /// the one above: declaration→arrival includes `firstAskDelayMs` and the service-loop pass,
    /// which are our own scheduling and not the network's doing. This is the closest thing we have
    /// to a measured retransmit round trip.
    ///
    /// ⚠️ `sinceAskUsMin` IS THE MOST INFORMATIVE NUMBER HERE and the reason it is a min rather
    /// than a mean: it is an empirical CEILING on the true path RTT. Some attributable arrival is
    /// the fastest one, and whatever it is, the real round trip is no slower than that. If it ever
    /// comes back below `attributionFloorUs` the floor is set too high and is discarding genuine
    /// retransmits; if it sits far above, the floor is too permissive and late originals are still
    /// leaking into the attributable bucket. Either way it is the calibration signal.
    uint64_t sinceAskUsTotal;
    uint64_t sinceAskUsMax;
    uint64_t sinceAskUsMin;            ///< UINT64_MAX until the first attributable recovery.

    // ── THE CONTROLLED EXPERIMENT: DOES ASKING ACTUALLY HELP? ────────────────
    //
    // ⚠️ EVERYTHING ELSE IN THIS FILE MEASURES WHAT ARRIVED. ONLY THIS MEASURES WHETHER WE
    // CAUSED IT. That distinction is the entire reason these counters exist, and it went
    // unnoticed for the whole NACK arc: `packetsRecovered` rising after we started sending NACKs
    // is consistent with the server retransmitting, and equally consistent with it ignoring us
    // while a congested queue delivers late. A 245 MICROSECOND "recovery" on a quiet wired link
    // — far faster than any round trip — is direct evidence that at least some of them were
    // never retransmits at all.
    //
    // One declared-missing sequence number in ten is therefore NEVER REQUESTED. Its recoveries
    // are late originals BY CONSTRUCTION: nothing was sent that could have caused them. Compare
    // the two rates:
    //
    //     askedRecovered/askedDeclared  ≈  controlRecovered/controlDeclared
    //         → asking achieves NOTHING MEASURABLE. Say so plainly; do not go looking for a
    //           kinder reading. It would mean the NACK arc has produced no demonstrated benefit.
    //
    //     askedRecovered/askedDeclared  >  controlRecovered/controlDeclared
    //         → retransmission is real, and the DIFFERENCE is the measured benefit.
    //
    // Each arm's declarations are conserved:
    //     askedDeclared   == askedRecovered   + askedStillMissing   + (asked, still outstanding)
    //     controlDeclared == controlRecovered + controlStillMissing + (control, still outstanding)
    //
    // ⚠️ THE TWO ARMS DO NOT SUM TO `packetsLost`, AND EXPECTING THEM TO WILL SEND SOMEONE
    // HUNTING A BUG THAT IS NOT THERE. A gap wider than `maxGapToRequest` is written off whole
    // in the receive path and never reaches MDDeclareMissing, so it joins neither arm:
    //
    //     askedDeclared + controlDeclared == packetsLost - <packets inside too-wide gaps>
    //
    // That is correct, not a leak — an outage is not a loss event either arm could have been
    // asked about. `nackGapsTooLarge` counts the events; the top-level identity still balances
    // because both `packetsLost` and `packetsStillMissing` move together there.
    //
    // ⚠️ THE CONTROL ARM COSTS THE VIEWER SOMETHING REAL — a tenth of recoverable losses go
    // unrequested. That is the price of knowing whether the other nine tenths are doing
    // anything, and it is only worth paying while the question is open. Once the comparison has
    // an answer on enough links, set `controlGroupPerMille` to 0.
    uint64_t askedDeclared;
    uint64_t askedRecovered;
    uint64_t askedStillMissing;
    uint64_t controlDeclared;
    uint64_t controlRecovered;
    uint64_t controlStillMissing;

    /// Declaration→arrival latency, per arm, microseconds. The control arm's distribution IS the
    /// reordering-delay distribution of this link, measured rather than assumed — which is the
    /// other thing the NACK work needed and never had. `…Min` are UINT64_MAX until first use.
    uint64_t askedRecoveredUsTotal;
    uint64_t askedRecoveredUsMax;
    uint64_t askedRecoveredUsMin;
    uint64_t controlRecoveredUsTotal;
    uint64_t controlRecoveredUsMax;
    uint64_t controlRecoveredUsMin;

    // ── THE FULL ARRIVAL-LATENCY DISTRIBUTION, UNFILTERED BY ANY FLOOR ───────
    //
    // ⚠️ THE REASON THIS EXISTS IS THAT A MEAN OVER A FLOOR-FILTERED SET IS NOT A MEAN, IT IS A
    // TAIL, AND IT WAS ABOUT TO BE USED TO SIZE THE LATENCY PRESETS.
    //
    // `recoveredAttributable` counts only arrivals ABOVE the attribution floor. With the floor
    // derived from the signalling round trip it sat at ~89 ms, which is several times any
    // plausible round trip to a Cloudflare edge — so every arrival that looked like a real
    // retransmit (a few tens of ms) was binned `recoveredBeforeFloor`, and the "attributable"
    // average was computed over what was left: the slow tail. That produced 330 ms and it is an
    // artefact of the cut, not a measurement of retransmission.
    //
    // These histograms are taken BEFORE any floor is applied and cannot be distorted by one.
    // Read them as a pair, because the pair is the experiment:
    //
    //   * the CONTROL arm was never asked, so its histogram IS this link's reordering-delay
    //     distribution — what late originals look like here, measured rather than assumed;
    //   * the ASKED arm contains the same reordering plus any retransmits we caused.
    //
    // A mode in the asked arm that the control arm does not have is retransmission, and WHERE
    // that mode sits is the retransmit latency — the number the presets actually want. If the two
    // histograms have the same shape, asking changed nothing and no summary statistic will
    // rescue that.
    //
    // Bucket upper bounds in milliseconds, last bucket unbounded:
    //     [0] <2   [1] <5   [2] <10  [3] <20  [4] <40
    //     [5] <80  [6] <160 [7] <320 [8] >=320
    // Log-spaced with fine resolution at the bottom deliberately: a real retransmit on a
    // same-metro edge lands between 10 and 60 ms, and linear buckets would smear that flat.
    uint32_t askedLatencyHistogram[9];
    uint32_t controlLatencyHistogram[9];

    // ── Round trip ───────────────────────────────────────────────────────────
    //
    // ⚠️ NOT MEASURED ON THE MEDIA PATH, AND THE ONLY HONEST SOURCE IS COARSE. See
    // `ManifoldRttSource` for the three routes that are closed and why. `rttUsMin` is whatever
    // the discounted signalling POST gave us, or UINT64_MAX if even that is missing.
    //
    // ⚠️ THE PER-ARM LATENCIES ABOVE DELIBERATELY DO NOT FEED THIS, and must never be wired to.
    // The floor is derived from the round trip, and a late original arriving 245 µs after a
    // request would drag `rttUsMin` down to 245 µs, the floor to 122 µs, and then classify
    // essentially every subsequent late original as attributable. The instrument would eat
    // itself, and it would look like a sharpening rather than a collapse.
    uint64_t rttUsMin;
    uint64_t rttUsMax;
    uint64_t rttUsLast;
    uint64_t rttUsTotal;

    int      rttSource;                ///< A `ManifoldRttSource`. Int for C-ABI stability.
    uint64_t attributionFloorUsInUse;  ///< 0 when attribution is suspended.

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

    // ── INCOMPLETE ACCESS UNITS: FRAMES SKIPPED BEFORE THE DECODER SAW THEM ──
    //
    // ⚠️ THESE ARE NOT ERRORS AND MUST NOT BE READ AS ANY. Every one of them is a frame we
    // KNEW was short a packet and therefore never submitted. The alternative — which is what
    // this code used to do — is to submit it, have VideoToolbox reject it with
    // kVTVideoDecoderBadDataErr, and have the decoder's resync gate then drop every frame until
    // the next IDR: ONE lost packet cost roughly a SECOND of video. Now it costs one frame.
    //
    // The rule that decides completeness is a SEQUENCE rule and is stated in full in the
    // AU-COMPLETENESS block in the .c file. In one line: an access unit is complete only if the
    // RTP packets carrying it form an unbroken run of sequence numbers, and the run is closed
    // either by a marker bit or by a directly-adjacent packet bearing the next timestamp.
    //
    // The identity is exact — the three causes partition the total:
    //
    //     accessUnitsIncomplete == …Interior + …Head + …Tail
    //
    // and they say DIFFERENT things about the link, which is why they are three counters:
    //
    //   * INTERIOR — a hole between two packets we DID receive of the same frame. This is the
    //     defect's headline case: a slice arriving as a LONE unfragmented packet, lost, with
    //     nothing left behind to notice it by. It is also every mid-NAL FU-A loss.
    //   * HEAD — packets were lost across a frame boundary and could have been this frame's
    //     opening. See the over-drop note in AU COMPLETENESS: when a burst straddles a boundary
    //     BOTH frames are skipped, because the missing packets took their own timestamps with
    //     them and there is no way to tell which frame they belonged to.
    //   * TAIL — the frame's last packets, including the one carrying its marker bit, never
    //     arrived; it was closed by the arrival of a NON-ADJACENT packet bearing the next
    //     timestamp. Every one of these is also an `accessUnitsByTimestamp`, but the reverse is
    //     NOT true: a sender that omits marker bits entirely closes every AU by timestamp with a
    //     perfectly adjacent packet and produces ZERO tail losses. That distinction is the whole
    //     reason completeness is tested by ADJACENCY rather than by "did a marker arrive".
    //
    // ⚠️ ONE TAIL LOSS PER SESSION IS EXPECTED AND IS NOT THE NETWORK. Teardown flushes whatever
    // frame was mid-arrival, and a frame caught mid-arrival is genuinely incomplete. Subtract
    // one before reading these as a loss rate on a short session.
    uint64_t accessUnitsIncomplete;         ///< Frames SKIPPED, never submitted. See above.
    uint64_t accessUnitsIncompleteInterior; ///< …a packet BETWEEN two of its own was missing.
    uint64_t accessUnitsIncompleteHead;     ///< …its opening may have been in a boundary-straddling gap.
    uint64_t accessUnitsIncompleteTail;     ///< …its final packet(s) never arrived.
    // ── REFERENCE CENSUS ─────────────────────────────────────────────────────
    //
    // ⚠️ MEASUREMENT ONLY — NOTHING BRANCHES ON THESE, AND THE QUESTION THEY SETTLED IS CLOSED.
    // See docs/WHEP_LOADED_NETWORK_FINDINGS.md §13 before acting on them.
    //
    // A skipped REFERENCE picture poisons every later picture that references it — visible
    // tearing, and NO decode error, because nothing fails — while a skipped DISPOSABLE one costs
    // only itself. The remedy (hold the picture until a keyframe repairs the chain) was measured
    // and REJECTED: this platform's sender emits NO disposable pictures, so it degenerates into
    // "request a keyframe on every loss". Manifold ships the tearing on purpose.
    //
    // ⚠️ THE ANSWER IS A PROPERTY OF THE ENCODER, NOT THE NETWORK. A sender using temporal layers
    // or B-frames emits many disposable pictures; a plain low-latency WebRTC encoder emits none.
    // The emitted triple is here as well as the skipped one precisely so the encoder's structure
    // is measured over EVERY frame of the session rather than over the handful that were lost —
    // a few hundred skips is a thin sample to decide a behaviour change on.
    //
    // THESE ARE KEPT AS THE EVIDENCE FOR §13 AND AS ITS REOPEN TRIPWIRE. A non-zero
    // `accessUnitsDisposable` against a new endpoint — a different SFU, or Cloudflare's B-frame
    // handling changing — is what makes reference-skipping cheap again and puts the decision back
    // on the table. Nothing else does; reopen on the counter, not on the argument.
    //
    // Full definitions and the two exact identities: H264AccessUnitBuilder.h.
    uint64_t accessUnitsReference;            ///< Emitted; something can reference it.
    uint64_t accessUnitsDisposable;           ///< Emitted; nal_ref_idc == 0, nothing ever will.
    uint64_t accessUnitsRefUnknown;           ///< Emitted; no surviving slice to read it from.
    uint64_t accessUnitsIncompleteReference;  ///< SKIPPED, and something would have referenced it.
    uint64_t accessUnitsIncompleteDisposable; ///< SKIPPED, and nothing would have.
    uint64_t accessUnitsIncompleteRefUnknown; ///< SKIPPED with no surviving slice to ask.

    /// Of `accessUnitsIncomplete`, the ones that would have been KEYFRAMES. Its own counter
    /// because a skipped IDR is the one skip that costs more than a frame: everything after it
    /// references a picture the decoder never received, so the keyframe has to be re-requested.
    uint64_t keyframesIncomplete;

    // ── Latched state ────────────────────────────────────────────────────────
    int      payloadType;              ///< Negotiated (or latched) H.264 payload type; -1 if unknown.
    uint32_t ssrc;                     ///< The SSRC we locked onto.
    uint32_t lastRTPTimestamp;         ///< 90 kHz. Becomes the PTS basis in step 3b.
    size_t   spsSize;                  ///< Bytes of SPS held (0 = none yet).
    size_t   ppsSize;                  ///< Bytes of PPS held (0 = none yet).
} ManifoldH264DepacketizerStats;

/// Seed the round trip from the WHEP signalling POST, for the window before the first probe
/// lands. Recorded as `ManifoldRttSourceSignalling` and REPORTED AS SUCH; the first answered
/// probe supersedes it and the source never falls back.
///
/// ⚠️ PASS THE RAW MEASURED ROUND TRIP. The depacketizer applies its own discount for the fact
/// that an HTTPS POST overestimates a UDP media path — doing it at the call site too would
/// double-discount and put the floor under the truth.
void ManifoldH264DepacketizerSeedSignallingRttUs(ManifoldH264Depacketizer *depacketizer,
                                                 uint64_t roundTripUs);

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

    /// ── THE RETRANSMIT ATTRIBUTION FLOOR, AS A FRACTION OF THE MEASURED ROUND TRIP ────────
    ///
    /// The floor is `rttUsMin / attributionFloorRttDivisor` — with the default 2, half the round
    /// trip. An arrival sooner than that after our first request cannot be a reply to it, because
    /// the request had not finished travelling.
    ///
    /// ⚠️ A FIXED MILLISECOND THRESHOLD WAS TRIED FIRST AND IS WRONG AT BOTH ENDS. 5 ms would
    /// throw away genuine retransmits on a LAN or a same-metro edge, where the whole round trip
    /// is under that; the same 5 ms would wave through late originals on a transatlantic path
    /// where 5 ms is a rounding error against a 90 ms round trip. Only a fraction of the MEASURED
    /// round trip is right on both, which is the property that matters the moment a tester in
    /// another country runs this.
    ///
    /// ⚠️ DERIVED FROM `rttUsMin`, NOT THE MEAN, AND THAT IS DELIBERATE. The minimum observed
    /// round trip is the best available estimate of the path's floor. A mean rises under exactly
    /// the congestion this instrument is meant to see through, and a floor that rises with load
    /// would start reclassifying genuine retransmits as late originals precisely when the
    /// question is live. The minimum is stable and biases the test toward UNDER-claiming late
    /// originals, which is the safe direction for a bound.
    ///
    /// Half is a judgement, not a derivation: a reply cannot beat one full round trip, so any
    /// divisor above 1 is conservative, and 2 leaves room for the fact that `rttUsMin` is itself
    /// a sample. Zero is refused (see the .c).
    unsigned int attributionFloorRttDivisor;

    /// Per-mille of declared-missing sequence numbers withheld from the requester as a control
    /// arm. 0 disables the experiment entirely — which is the right setting ONCE THE QUESTION IS
    /// ANSWERED, and the wrong one while it is open. See the note on the counters above.
    unsigned int controlGroupPerMille;

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
