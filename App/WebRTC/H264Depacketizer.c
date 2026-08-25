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
//    * A jitter buffer / reorder queue. Out-of-order arrivals are DETECTED and
//      counted; they are not held and re-sequenced. A recovered packet is
//      therefore depacketized where it lands, not where it belongs.
//
//      NACK, however, now lives here. libdatachannel has no receive-side NACK
//      generator in any version — rtcpnackresponder.hpp is the SEND side, and
//      there is no rtcpnackrequester.hpp on master either — so the decision of
//      WHICH sequence numbers to ask for, WHEN, and when to stop is made in
//      this file, against the outstanding table below. The RFC 4585 encoding
//      and the sending are the caller's: see the sink typedef in the header,
//      which is what keeps this file pure C with no libdatachannel in it.
//
//      NO RTX UNWRAPPING, deliberately. The server retransmits on the ORIGINAL
//      SSRC with the ORIGINAL sequence number, so a recovered packet arrives as
//      an ordinary out-of-order packet and is claimed by the `delta <= 0` branch
//      like any other late arrival. Nothing on the receive side needed changing
//      to accept one.
//

#include "H264Depacketizer.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

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

// ── LOSS ACCOUNTING ──────────────────────────────────────────────────────────────────
//
// `packetsLost` is incremented at gap-detection time with zero lookahead and is NEVER
// revisited. That was already true before this table existed, and it is deliberately still
// true — but on its own it is not a count of genuine loss, and the previous generation of
// counters got into trouble by letting people read it as one.
//
// So a declared-missing sequence number is now TRACKED until one of two things happens:
//
//     it arrives   → packetsRecovered++      (and its delay is accumulated)
//     it ages out  → packetsStillMissing++   ← THIS is genuine loss
//
// and until either happens it is counted in `packetsOutstanding`. The identity
//
//     packetsLost == packetsRecovered + packetsStillMissing + packetsOutstanding
//
// therefore holds at EVERY snapshot, which is what makes the totals line self-checking: if it
// does not balance, this file is wrong, and nobody has to audit the source to find out what a
// counter meant.
//
// ⚠️ WHY `packetsLost` KEEPS ITS OLD MEANING RATHER THAN BECOMING "STILL LOST".
// Two reasons, and the second is the load-bearing one:
//   1. It is knowable at the instant it is observed. "Still lost" is only knowable once the
//      window closes, so a counter with that meaning necessarily LAGS — a 1 Hz window line
//      would report a value for a second that has not finished being decided, and a session
//      total would be wrong by whatever was still outstanding at teardown.
//   2. Runs A–D are baselines. Run C's `lost=203` is the number the NACK work is measured
//      against. Silently redefining the counter that produced it would make every historical
//      figure in docs/WHEP_LOADED_NETWORK_FINDINGS.md incomparable with anything measured
//      afterwards — the numbers would still print, and would quietly mean something else.
//
// The old "lost − reorder is the closer estimate of genuine loss" relationship is now
// OBSOLETE and should not be used: it was an estimate built by subtracting two independently
// kept tallies, and it silently included duplicates. `packetsStillMissing` measures the same
// thing directly. `packetsReordered` is unchanged and still counts every `seq <= highestSeq`
// arrival, so `packetsRecovered` is a SUBSET of it — the remainder being duplicates and
// stragglers we were no longer waiting for.

// ── BURSTS AND STORMS ────────────────────────────────────────────────────────────────
//
// The measured worst seconds on the Wi-Fi path were `lost=43` and `lost=48` (Run C; see
// docs/WHEP_LOADED_NETWORK_FINDINGS.md §8). Forty-eight missing sequence numbers at once is the
// case that decides the shape of a requester, because the naive answer — one request per missing
// packet, retried — puts a burst of new traffic onto a link that has just demonstrated it cannot
// carry the traffic it already had. What follows is DELIBERATE, not emergent.
//
// THREE MECHANISMS, IN INCREASING ORDER OF SEVERITY.
//
// 1. COALESCE, ALWAYS. A request carries a LIST, not a packet. RFC 4585's Generic NACK encodes a
//    16-bit PID plus a 16-bit bitmask of the sixteen sequence numbers after it, so seventeen
//    consecutive missing packets cost ONE four-byte field. A contiguous burst of 48 is three
//    fields — one small RTCP packet, not 48 packets. The encoding itself belongs to the caller
//    (see the sink typedef in the header); what this file guarantees is that everything due at
//    the same instant is handed over in ONE call, in ascending sequence order, so that it CAN be
//    packed that way. MD_NACK_SEQS_PER_SERVICE bounds a single call; the remainder goes out on
//    the next packet, which at a few hundred packets a second is microseconds later.
//
// 2. A RATE CEILING, for the pathological case. `budgetSeqsPerSecond` is a token bucket over
//    sequence numbers requested, retries included. The default of 200/s sits deliberately ABOVE
//    the measured worst case — 48 lost in a second, asked at most three times each, is 144 — so
//    it does not shape an ordinary loss event. It exists to bound an unbounded feedback loop on
//    a link that is failing. Refusals are counted in `nackSeqsSuppressedByRate`, never silent.
//
// 3. A WIDTH CEILING, above which retransmission is simply the WRONG TOOL. A single gap wider
//    than `maxGapToRequest` (default 64 — roughly four frames at the measured packet rate) is
//    not a loss event, it is an OUTAGE. Asking for three hundred packets back from a link that
//    has just failed to deliver three hundred packets is precisely the storm this policy exists
//    to prevent, and the access units they belong to are unreconstructable either way. Such a
//    gap is counted (`nackGapsTooLarge`), written off immediately, and left to the keyframe
//    path: a PLI costs one request and one intra frame, whatever the width of the hole.
//
//    That ceiling also bounds the WORK done here. Without it, a 30 000-wide gap would walk the
//    declare loop 30 000 times, each iteration scanning a full table for a victim to evict —
//    tens of millions of operations on libdatachannel's receive thread, for a frame that cannot
//    be rebuilt. The gap is now recognised for what it is BEFORE the loop, not survived by it.

// ── TOMBSTONES: TELLING A SHORT WINDOW FROM A LOSSY LINK ──────────────────────────────
//
// A slot is not freed the moment its packet is written off. It is kept, marked, for one further
// window, so that if the packet does turn up after all we can say so — `packetsLateAfterGiveUp`.
//
// That distinction is not cosmetic and it is not for us. A packet that arrives 420 ms after it
// was declared missing, against a 400 ms window, was never lost: we asked for it, it came, and
// we had stopped listening. The remedy is a larger cushion, which is a SETTING, and the user is
// the one who chose it. Without this counter that user sees a picture breaking up with loss
// numbers indistinguishable from a genuinely lossy link, and no reason to suspect the preset.
//
// A tombstone does NOT revise `packetsStillMissing` back down — see the header for why.

#define MD_OUTSTANDING_CAP        512u   // fixed; the receive path never allocates
#define MD_OUTSTANDING_SWEEP      8u     // slots aged per packet — bounds the per-packet cost
#define MD_NACK_SEQS_PER_SERVICE  64u    // sequence numbers handed to the sink in one call

// Policy defaults. Stated here once and nowhere else; the header documents what each one means
// and why it is a parameter rather than a constant.
#define MD_DEFAULT_RECOVERY_MS    400u
#define MD_DEFAULT_FIRST_ASK_MS   0u
#define MD_DEFAULT_RETRY_MS       40u
#define MD_DEFAULT_MAX_RETRIES    2u
#define MD_DEFAULT_MAX_GAP        64u
#define MD_DEFAULT_BUDGET_PER_SEC 200u

/// Attribution floor = rttUsMin / 2. See the note on `attributionFloorRttDivisor` in the header
/// for why a fraction of a MEASURED round trip rather than a fixed millisecond threshold, and
/// why the minimum rather than the mean.
#define MD_DEFAULT_FLOOR_RTT_DIVISOR 2u

/// One declared-missing sequence number in ten is deliberately NOT requested, forming a control
/// group. See MDDeclareMissing for the experiment and why it has to exist.
///
/// A tenth is a compromise: large enough that a few hundred loss events produce a usable control
/// sample, small enough that withholding the request costs the viewer almost nothing even if
/// retransmission turns out to work perfectly.
#define MD_DEFAULT_CONTROL_PER_MILLE 100u

/// The signalling POST is TCP+TLS to an HTTP endpoint including the server's SDP work, so it
/// OVERSTATES the UDP media round trip. Quartered before use: still far above any real floor,
/// still well under a plausible media RTT, and biased the safe way (a floor that is too low
/// admits late originals; one that is too high discards genuine retransmits).
#define MD_SIGNALLING_RTT_DISCOUNT 4u

/// `nextAskNs` sentinel: this sequence number will never be asked for again.
#define MD_NEVER_ASK              UINT64_MAX

enum {
    MD_SLOT_FREE = 0,        ///< calloc leaves every slot here, which is why FREE must be zero
    MD_SLOT_OUTSTANDING,     ///< declared missing, window open — the identity's third term
    MD_SLOT_WRITTEN_OFF,     ///< window closed; kept as a tombstone so a late arrival is visible
};

typedef struct {
    uint64_t declaredNs;     ///< When the gap that implied this sequence number was detected.
    uint64_t nextAskNs;      ///< Earliest time it may be requested again; MD_NEVER_ASK when done.
    /// When the FIRST request for this sequence number was handed to the sink; 0 = never asked.
    ///
    /// ⚠️ NOT DERIVABLE FROM `nextAskNs`, which is why it is stored separately at the cost of
    /// eight bytes a slot: `nextAskNs` is overwritten by every retry and by MD_NEVER_ASK, so by
    /// the time an arrival is classified the moment of the first ask is long gone. Without it
    /// the only available origin is `declaredNs`, which includes `firstAskDelayMs` and the
    /// service-loop pass — our own scheduling, charged to the network.
    uint64_t firstAskNs;
    uint16_t seq;
    uint8_t  asks;           ///< Requests sent for it so far.
    uint8_t  state;          ///< MD_SLOT_*
    /// Deliberately withheld from the requester as a control observation. DISTINCT FROM
    /// `asks == 0`, which also covers a request the rate governor swallowed or one the hold-off
    /// has not reached yet — those are accidents, this is the experiment.
    uint8_t  control;
} MDOutstanding;

struct ManifoldH264Depacketizer {
    int      payloadType;          // -1 = latch the first one seen
    uint32_t ssrc;
    bool     haveSSRC;

    bool     haveSeq;
    uint16_t highestSeq;           // highest sequence number seen (RFC 3550 s_max)

    // Declared-missing sequence numbers awaiting a verdict. See LOSS ACCOUNTING above.
    MDOutstanding outstanding[MD_OUTSTANDING_CAP];
    unsigned int  outstandingCount;   // MD_SLOT_OUTSTANDING only
    unsigned int  tombstoneCount;     // MD_SLOT_WRITTEN_OFF only
    unsigned int  sweepCursor;
    uint64_t      nextServiceNs;      // earliest nextAskNs in the table; MD_NEVER_ASK = nothing due

    // Anti-storm token bucket. See BURSTS AND STORMS, mechanism 2.
    uint64_t      budgetTokens;
    uint64_t      budgetRefilledNs;

    /// Counts declarations so every Nth can be withheld as a control. See MDDeclareMissing.
    uint64_t      declareCounter;

    // The policy, plus the three durations pre-multiplied into nanoseconds so the receive path
    // never divides or multiplies to compare a deadline.
    ManifoldH264LossPolicy policy;
    uint64_t      recoveryWindowNs;
    uint64_t      firstAskDelayNs;
    uint64_t      retryIntervalNs;

    ManifoldH264NackRequestHandler nackHandler;
    void                          *nackContext;


    // FU-A reassembly
    ManifoldH264Buffer fragment;
    bool               fragmentActive;

    // Access-unit assembly and every piece of H.264 state it needs (AU buffer,
    // keyframe flag, SPS/PPS slots, the handler) live here.
    ManifoldH264AccessUnitBuilder *builder;

    ManifoldH264DepacketizerStats stats;
};

/// Monotonic nanoseconds. Never allocates, never blocks — safe on the receive path.
static uint64_t MDNowNs(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}

/// Release a slot outright, keeping the two censuses correct whatever state it was in.
static void MDFreeSlot(ManifoldH264Depacketizer *dp, unsigned int i) {
    if (dp->outstanding[i].state == MD_SLOT_OUTSTANDING)      dp->outstandingCount--;
    else if (dp->outstanding[i].state == MD_SLOT_WRITTEN_OFF) dp->tombstoneCount--;
    dp->outstanding[i].state = MD_SLOT_FREE;
}

/// The window closed with no arrival: GENUINE LOSS. The slot becomes a tombstone rather than
/// being freed, so that an arrival after this moment can still be told apart from one that never
/// came at all. See TOMBSTONES above.
static void MDWriteOffSlot(ManifoldH264Depacketizer *dp, unsigned int i) {
    dp->outstanding[i].state     = MD_SLOT_WRITTEN_OFF;
    dp->outstanding[i].nextAskNs = MD_NEVER_ASK;
    dp->outstandingCount--;
    dp->tombstoneCount++;
    dp->stats.packetsStillMissing++;
    // Charged to whichever arm declared it, so each arm's recovery RATE is computable:
    //   rate = <arm>Recovered / <arm>Declared, with the remainder written off here.
    if (dp->outstanding[i].control) dp->stats.controlStillMissing++;
    else                            dp->stats.askedStillMissing++;
}

/// Age a bounded number of slots. Called once per packet, so the cost per packet is O(SWEEP)
/// rather than O(CAP) — the whole table is still swept every CAP/SWEEP packets, which at any
/// realistic packet rate is far inside the recovery window.
static void MDSweepOutstanding(ManifoldH264Depacketizer *dp, uint64_t now) {
    if (dp->outstandingCount == 0 && dp->tombstoneCount == 0) return;
    for (unsigned int n = 0; n < MD_OUTSTANDING_SWEEP; n++) {
        const unsigned int i = dp->sweepCursor;
        dp->sweepCursor = (dp->sweepCursor + 1u) % MD_OUTSTANDING_CAP;
        MDOutstanding *slot = &dp->outstanding[i];
        const uint64_t age = now - slot->declaredNs;
        if (slot->state == MD_SLOT_OUTSTANDING) {
            if (age >= dp->recoveryWindowNs) MDWriteOffSlot(dp, i);
        } else if (slot->state == MD_SLOT_WRITTEN_OFF) {
            // A tombstone lives one FURTHER window: long enough that a retransmit which merely
            // missed the deadline is still recognised, short enough that the table stays mostly
            // free for the live entries that need the slots.
            if (age >= 2u * dp->recoveryWindowNs) MDFreeSlot(dp, i);
        }
    }
}

/// Record `seq` as declared missing. `ask` is false when the gap was too wide to be worth
/// requesting — the sequence number is still tracked to a verdict, it is simply never asked for.
static void MDDeclareMissing(ManifoldH264Depacketizer *dp, uint16_t seq, uint64_t now, bool ask) {
    if (dp->outstandingCount + dp->tombstoneCount >= MD_OUTSTANDING_CAP) {
        // Evict the oldest TOMBSTONE by preference: it has already reached a verdict, so losing
        // it costs only the ability to notice a very late arrival. Only when there are none does
        // a live entry get written off early — that is what `outstandingOverflow` counts.
        const uint8_t wanted = dp->tombstoneCount > 0 ? MD_SLOT_WRITTEN_OFF : MD_SLOT_OUTSTANDING;
        unsigned int victim = MD_OUTSTANDING_CAP;
        uint64_t oldest = UINT64_MAX;
        for (unsigned int i = 0; i < MD_OUTSTANDING_CAP; i++) {
            if (dp->outstanding[i].state != wanted) continue;
            if (dp->outstanding[i].declaredNs < oldest) { oldest = dp->outstanding[i].declaredNs; victim = i; }
        }
        if (victim == MD_OUTSTANDING_CAP) return;    // unreachable while the counts are correct
        if (wanted == MD_SLOT_OUTSTANDING) {
            MDWriteOffSlot(dp, victim);
            dp->stats.outstandingOverflow++;
        }
        MDFreeSlot(dp, victim);
    }
    for (unsigned int n = 0; n < MD_OUTSTANDING_CAP; n++) {
        const unsigned int i = (seq + n) % MD_OUTSTANDING_CAP;   // seq-keyed, linear probe
        MDOutstanding *slot = &dp->outstanding[i];
        if (slot->state != MD_SLOT_FREE) continue;
        // ── THE CONTROL GROUP ───────────────────────────────────────────────────────────────
        //
        // ⚠️ WITHOUT THIS, "THE PACKET CAME BACK AFTER WE ASKED" IS NOT EVIDENCE OF ANYTHING.
        // A retransmit and a late original arrive identically — same SSRC, same sequence number,
        // no marker of any kind — so a recovery rate measured only on packets we asked for is
        // consistent with the server retransmitting everything and equally consistent with it
        // ignoring us entirely while a congested queue delivers late.
        //
        // So one in ten declared-missing sequence numbers is NEVER REQUESTED. Those recoveries
        // are late originals BY CONSTRUCTION — nothing was sent that could have caused them. The
        // comparison is then a controlled one:
        //
        //     recovery rate(asked) ≈ recovery rate(control)  →  our NACKs are achieving nothing
        //     recovery rate(asked) >  recovery rate(control)  →  retransmission is real, and the
        //                                                        excess IS the measured benefit
        //
        // DETERMINISTIC, NOT RANDOM: every tenth declaration, counted. A receive path has no
        // business holding an RNG, and a fixed stride makes a session reproducible and the
        // arithmetic checkable by hand. The stride is uncorrelated with anything about the
        // network — loss events do not arrive in tens — so it does not bias the sample.
        bool control = false;
        if (dp->policy.controlGroupPerMille > 0) {
            dp->declareCounter++;
            control = (dp->declareCounter * dp->policy.controlGroupPerMille) / 1000u
                    != ((dp->declareCounter - 1) * dp->policy.controlGroupPerMille) / 1000u;
        }

        slot->declaredNs = now;
        slot->seq        = seq;
        slot->asks       = 0;
        slot->firstAskNs = 0;
        slot->control    = control ? 1u : 0u;
        if (control) {
            dp->stats.controlDeclared++;
            ask = false;                 // the whole point: it is never requested
        } else {
            dp->stats.askedDeclared++;
        }
        slot->state      = MD_SLOT_OUTSTANDING;
        slot->nextAskNs  = ask ? now + dp->firstAskDelayNs : MD_NEVER_ASK;
        dp->outstandingCount++;
        if (slot->nextAskNs < dp->nextServiceNs) dp->nextServiceNs = slot->nextAskNs;
        return;
    }
}

// Round-trip probe and attribution floor. Defined below, beside MDServiceNacks where the rest of
// the request machinery lives, but used by MDClaimLate above it — declared here rather than moved
// so the probe reads next to the requester it borrows.
static uint64_t MDAttributionFloorUs(const ManifoldH264Depacketizer *dp);

/// A packet arrived with a sequence number at or below the highest seen. If it is one we had
/// declared missing, reach a verdict on it — and distinguish the two ways it can be too late.
static void MDClaimLate(ManifoldH264Depacketizer *dp, uint16_t seq, uint64_t now) {
    for (unsigned int n = 0; n < MD_OUTSTANDING_CAP; n++) {
        const unsigned int i = (seq + n) % MD_OUTSTANDING_CAP;
        MDOutstanding *slot = &dp->outstanding[i];
        if (slot->state == MD_SLOT_FREE) return;         // a free slot ends the probe run
        if (slot->seq != seq) continue;

        const uint64_t delay = now - slot->declaredNs;
        const uint64_t us    = delay / 1000u;
        if (slot->state == MD_SLOT_WRITTEN_OFF || delay >= dp->recoveryWindowNs) {
            // ARRIVED, BUT AFTER WE STOPPED WAITING — the WINDOW was the limit, not the network.
            // A slot still marked outstanding here only means the lazy sweep had not reached it
            // yet; the verdict is identical, and `packetsStillMissing` takes it here instead.
            if (slot->state == MD_SLOT_OUTSTANDING) dp->stats.packetsStillMissing++;
            dp->stats.packetsLateAfterGiveUp++;
            dp->stats.lateAfterGiveUpUsTotal += us;
            if (us > dp->stats.lateAfterGiveUpUsMax) dp->stats.lateAfterGiveUpUsMax = us;
        } else {
            dp->stats.packetsRecovered++;
            dp->stats.recoveryLatencyUsTotal += us;
            if (us > dp->stats.recoveryLatencyUsMax) dp->stats.recoveryLatencyUsMax = us;

            // ── THE CONTROLLED COMPARISON ──
            //
            // Recorded before the attribution below and independently of it. This pair of
            // distributions is the ONLY thing in this file that can answer "does asking help?",
            // because the control arm's recoveries are late originals by construction. The
            // attribution buckets below are a finer question asked of the treated arm alone.
            if (slot->control) {
                dp->stats.controlRecovered++;
                dp->stats.controlRecoveredUsTotal += us;
                if (us > dp->stats.controlRecoveredUsMax) dp->stats.controlRecoveredUsMax = us;
                if (us < dp->stats.controlRecoveredUsMin) dp->stats.controlRecoveredUsMin = us;
            } else {
                dp->stats.askedRecovered++;
                dp->stats.askedRecoveredUsTotal += us;
                if (us > dp->stats.askedRecoveredUsMax) dp->stats.askedRecoveredUsMax = us;
                if (us < dp->stats.askedRecoveredUsMin) dp->stats.askedRecoveredUsMin = us;
            }

            // ── ATTRIBUTION: could OUR request have caused this arrival? ──
            //
            // Three outcomes, and the first two are settled by fact rather than by threshold.
            // See the note on these counters in the header before changing the order: the
            // `asks == 0` test MUST come first, because a packet never asked for has no
            // first-ask time to measure against and would otherwise divide by a zero origin.
            if (slot->control) {
                // Withheld on purpose. It is a late original by construction, and saying so is
                // the point of the arm — it is not an accident of the requester's scheduling.
                dp->stats.recoveredUnrequested++;
            } else if (slot->asks == 0) {
                // Never requested — nothing was sent that this could be a reply to. The commonest
                // sources are a gap too wide to ask about, the rate governor, and simple speed:
                // with firstAskDelayMs at 0 the service loop still runs on the NEXT packet, so a
                // reordered packet arriving in the same breath is recovered before we ask.
                dp->stats.recoveredUnrequested++;
            } else {
                const uint64_t sinceAsk   = now - slot->firstAskNs;
                const uint64_t sinceAskUs = sinceAsk / 1000u;
                const uint64_t floorUs    = MDAttributionFloorUs(dp);
                if (floorUs == 0) {
                    // No round trip measured yet — no floor, so no verdict. Parking it here is
                    // the whole point: see `recoveredUnattributed` in the header.
                    dp->stats.recoveredUnattributed++;
                } else if (sinceAskUs < floorUs) {
                    // Arrived faster than the request could have reached the server. Physically
                    // cannot be a retransmit of it; it was already in flight.
                    dp->stats.recoveredBeforeFloor++;
                } else {
                    dp->stats.recoveredAttributable++;
                    dp->stats.attributableLatencyUsTotal += us;
                    if (us > dp->stats.attributableLatencyUsMax) dp->stats.attributableLatencyUsMax = us;
                    dp->stats.sinceAskUsTotal += sinceAskUs;
                    if (sinceAskUs > dp->stats.sinceAskUsMax) dp->stats.sinceAskUsMax = sinceAskUs;
                    if (sinceAskUs < dp->stats.sinceAskUsMin) dp->stats.sinceAskUsMin = sinceAskUs;
                }
            }
        }
        MDFreeSlot(dp, i);
        return;
    }
}

/// Token bucket over sequence numbers requested per second. Burst capacity is one second's
/// worth, and the sub-token remainder is carried rather than discarded.
static void MDRefillBudget(ManifoldH264Depacketizer *dp, uint64_t now) {
    const uint64_t rate = dp->policy.budgetSeqsPerSecond;
    if (rate == 0) { dp->budgetTokens = 0; return; }
    if (dp->budgetRefilledNs == 0) { dp->budgetRefilledNs = now; dp->budgetTokens = rate; return; }
    const uint64_t gained = (now - dp->budgetRefilledNs) * rate / 1000000000ull;
    if (gained == 0) return;
    dp->budgetTokens += gained;
    if (dp->budgetTokens > rate) dp->budgetTokens = rate;
    dp->budgetRefilledNs += gained * 1000000000ull / rate;
}

/// Ascending sequence order, wrap-aware, so the caller can pack the list into RFC 4585 bitmask
/// fields. Every outstanding sequence number is at or behind `highestSeq`, so
/// `age = highestSeq - seq` is a small unsigned value that orders them correctly ACROSS the
/// 16-bit wrap, where a plain numeric compare would not. Descending age is ascending sequence.
/// Insertion sort: `count` is bounded by MD_NACK_SEQS_PER_SERVICE and the input is nearly sorted.
static void MDSortBySeqAscending(uint16_t *seqs, unsigned int count, uint16_t highestSeq) {
    for (unsigned int i = 1; i < count; i++) {
        const uint16_t v    = seqs[i];
        const uint16_t vAge = (uint16_t)(highestSeq - v);
        unsigned int j = i;
        while (j > 0 && (uint16_t)(highestSeq - seqs[j - 1]) < vAge) { seqs[j] = seqs[j - 1]; j--; }
        seqs[j] = v;
    }
}

/// The floor currently in force, or 0 when there is no round-trip measurement and attribution is
/// therefore SUSPENDED. Zero is the "we do not know" signal and callers must branch on it.
static uint64_t MDAttributionFloorUs(const ManifoldH264Depacketizer *dp) {
    if (dp->stats.rttSource == ManifoldRttSourceNone) return 0;
    if (dp->stats.rttUsMin == UINT64_MAX) return 0;
    const unsigned int div = dp->policy.attributionFloorRttDivisor;
    return div ? dp->stats.rttUsMin / div : dp->stats.rttUsMin / MD_DEFAULT_FLOOR_RTT_DIVISOR;
}

/// Fold one measured round trip in and promote the source if this is a better one.
///
/// ⚠️ THE SOURCE ONLY EVER IMPROVES. A probe supersedes the signalling seed and nothing demotes
/// it back — a later timeout means we failed to measure, not that the path became unmeasurable,
/// and dropping to a coarser source would silently move the floor and with it the classification
/// of every subsequent arrival.
static void MDRecordRtt(ManifoldH264Depacketizer *dp, uint64_t rttUs, int source) {
    if (rttUs == 0) return;
    if (source < dp->stats.rttSource) return;
    dp->stats.rttSource = source;
    dp->stats.rttUsLast = rttUs;
    if (rttUs < dp->stats.rttUsMin) dp->stats.rttUsMin = rttUs;
    dp->stats.attributionFloorUsInUse = MDAttributionFloorUs(dp);
}

/// Decide which outstanding sequence numbers are due to be asked for, and hand them over in one
/// call. Runs on the receive path, once per packet, and returns immediately in the common case
/// where nothing is outstanding — `nextServiceNs` is the gate that makes the O(CAP) scan below
/// cost nothing on a clean link.
static void MDServiceNacks(ManifoldH264Depacketizer *dp, uint64_t now) {
    if (!dp->nackHandler || dp->outstandingCount == 0) return;
    if (now < dp->nextServiceNs) return;

    MDRefillBudget(dp, now);

    uint16_t due[MD_NACK_SEQS_PER_SERVICE];
    unsigned int count = 0;
    uint64_t nextService = MD_NEVER_ASK;

    for (unsigned int i = 0; i < MD_OUTSTANDING_CAP; i++) {
        MDOutstanding *slot = &dp->outstanding[i];
        if (slot->state != MD_SLOT_OUTSTANDING || slot->nextAskNs == MD_NEVER_ASK) continue;

        if (now < slot->nextAskNs) {
            if (slot->nextAskNs < nextService) nextService = slot->nextAskNs;
            continue;
        }

        // ⚠️ STOP ASKING FOR WHAT COULD NO LONGER ARRIVE IN TIME.
        //
        // One retry interval stands in for the round trip, because a receiver cannot derive an
        // RTT from sender reports alone — the DLSR arithmetic in RFC 3550 §6.4.1 runs the other
        // way. If even that optimistic estimate lands past the window, the reply would arrive
        // after the frame's display deadline: the request would be pure added traffic on a link
        // that is already losing packets, in exchange for a packet nobody can use.
        if (now + dp->retryIntervalNs > slot->declaredNs + dp->recoveryWindowNs) {
            slot->nextAskNs = MD_NEVER_ASK;
            continue;
        }

        if (dp->budgetTokens == 0) {
            dp->stats.nackSeqsSuppressedByRate++;
            slot->nextAskNs = MD_NEVER_ASK;
            continue;
        }
        if (count == MD_NACK_SEQS_PER_SERVICE) {
            nextService = now;               // the remainder goes out on the next packet
            continue;
        }

        dp->budgetTokens--;
        due[count++] = slot->seq;
        if (slot->asks == 0) slot->firstAskNs = now;   // stamped once; retries do not move it
        slot->asks++;
        if (slot->asks >= 1u + dp->policy.maxRetries) {
            slot->nextAskNs = MD_NEVER_ASK;
        } else {
            slot->nextAskNs = now + dp->retryIntervalNs;
            if (slot->nextAskNs < nextService) nextService = slot->nextAskNs;
        }
    }

    dp->nextServiceNs = nextService;
    if (count == 0) return;

    MDSortBySeqAscending(due, count, dp->highestSeq);
    dp->stats.nacksSent++;
    dp->stats.nackSeqsRequested += count;
    dp->nackHandler(due, count, dp->ssrc, dp->nackContext);
}

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

/// Pre-multiplies the three durations the receive path compares against, so that a deadline
/// test is a subtraction and never a multiply.
static void MDApplyPolicy(ManifoldH264Depacketizer *dp) {
    dp->recoveryWindowNs = (uint64_t)dp->policy.recoveryWindowMs * 1000000ull;
    dp->firstAskDelayNs  = (uint64_t)dp->policy.firstAskDelayMs  * 1000000ull;
    dp->retryIntervalNs  = (uint64_t)dp->policy.retryIntervalMs  * 1000000ull;
    dp->stats.attributionFloorUsInUse = MDAttributionFloorUs(dp);
}

// ── Public API ────────────────────────────────────────────────────────────────

ManifoldH264Depacketizer *ManifoldH264DepacketizerCreate(void) {
    ManifoldH264Depacketizer *dp = calloc(1, sizeof(*dp));
    if (!dp) return NULL;
    dp->builder = ManifoldH264AccessUnitBuilderCreate();
    if (!dp->builder) { free(dp); return NULL; }
    dp->payloadType       = -1;
    dp->stats.payloadType = -1;
    dp->nextServiceNs     = MD_NEVER_ASK;
    // ⚠️ calloc leaves this ZERO, and zero is the identity for a MINIMUM — every comparison
    // would fail and the field would read 0 forever, which looks exactly like "we measured a
    // 0 µs round trip". The sentinel has to be the maximum, and the reader has to know that a
    // UINT64_MAX here means "no attributable recovery yet", not "infinitely slow".
    dp->stats.sinceAskUsMin = UINT64_MAX;
    dp->stats.rttUsMin        = UINT64_MAX;   // same sentinel argument as sinceAskUsMin above
    dp->stats.rttSource       = ManifoldRttSourceNone;
    dp->stats.askedRecoveredUsMin   = UINT64_MAX;
    dp->stats.controlRecoveredUsMin = UINT64_MAX;
    dp->policy            = ManifoldH264DefaultLossPolicy();
    MDApplyPolicy(dp);
    return dp;
}

void ManifoldH264DepacketizerDestroy(ManifoldH264Depacketizer *dp) {
    if (!dp) return;
    ManifoldH264BufferFree(&dp->fragment);
    ManifoldH264AccessUnitBuilderDestroy(dp->builder);
    free(dp);
}

void ManifoldH264DepacketizerSeedSignallingRttUs(ManifoldH264Depacketizer *dp, uint64_t roundTripUs) {
    if (!dp || roundTripUs == 0) return;
    const uint64_t discounted = roundTripUs / MD_SIGNALLING_RTT_DISCOUNT;
    if (discounted == 0) return;
    MDRecordRtt(dp, discounted, ManifoldRttSourceSignalling);
}

void ManifoldH264DepacketizerSetPayloadType(ManifoldH264Depacketizer *dp, int payloadType) {
    if (!dp) return;
    dp->payloadType       = payloadType;
    dp->stats.payloadType = payloadType;
}

ManifoldH264LossPolicy ManifoldH264DefaultLossPolicy(void) {
    ManifoldH264LossPolicy policy;
    policy.recoveryWindowMs    = MD_DEFAULT_RECOVERY_MS;
    policy.attributionFloorRttDivisor = MD_DEFAULT_FLOOR_RTT_DIVISOR;
    policy.controlGroupPerMille = MD_DEFAULT_CONTROL_PER_MILLE;
    policy.firstAskDelayMs     = MD_DEFAULT_FIRST_ASK_MS;
    policy.retryIntervalMs     = MD_DEFAULT_RETRY_MS;
    policy.maxRetries          = MD_DEFAULT_MAX_RETRIES;
    policy.maxGapToRequest     = MD_DEFAULT_MAX_GAP;
    policy.budgetSeqsPerSecond = MD_DEFAULT_BUDGET_PER_SEC;
    return policy;
}

void ManifoldH264DepacketizerSetLossPolicy(ManifoldH264Depacketizer *dp,
                                           const ManifoldH264LossPolicy *policy) {
    if (!dp || !policy) return;
    ManifoldH264LossPolicy applied = *policy;

    // Two fields are refused at zero rather than honoured, because zero DISABLES the instrument
    // instead of tuning it and the symptom is indistinguishable from a broken requester:
    //
    //   * a zero window writes every gap off on the next sweep, making `packetsRecovered`
    //     structurally zero — which reads exactly like "retransmission is not working";
    //   * a zero retry interval puts every retry on the very next packet, which is a storm by
    //     construction and would also make the can-it-still-arrive test above always true.
    //
    // There is no UPPER clamp on anything here. A preset asking for a long window is stating a
    // latency budget, and this file is not the place to overrule it.
    if (applied.recoveryWindowMs == 0) applied.recoveryWindowMs = dp->policy.recoveryWindowMs;
    if (applied.retryIntervalMs  == 0) applied.retryIntervalMs  = dp->policy.retryIntervalMs;
    // A zero floor is refused for the same class of reason: it does not tune the attribution
    // test, it DELETES it — every arrival becomes attributable and `recoveredBeforeFloor` goes
    // structurally to zero, which reads as "no late originals" when it means "not looking".
    // A zero divisor would divide by zero; a zero timeout would time every probe out before it
    // could be answered and strand us on `ManifoldRttSourceNone` forever. Both are refused for
    // the same reason as the two above: they disable the instrument rather than tune it.
    // `rttProbeIntervalSec == 0` IS honoured — that one legitimately means "do not probe", and
    // its consequence (attribution suspends) is visible in `recoveredUnattributed`.
    if (applied.attributionFloorRttDivisor == 0)
        applied.attributionFloorRttDivisor = dp->policy.attributionFloorRttDivisor;


    dp->policy = applied;
    MDApplyPolicy(dp);
}

void ManifoldH264DepacketizerSetNackRequestHandler(ManifoldH264Depacketizer *dp,
                                                   ManifoldH264NackRequestHandler handler,
                                                   void *context) {
    if (!dp) return;
    dp->nackHandler = handler;
    dp->nackContext = context;
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
    const uint64_t nowNs = MDNowNs();
    MDSweepOutstanding(dp, nowNs);
    if (!dp->haveSeq) {
        dp->haveSeq    = true;
        dp->highestSeq = seq;
    } else {
        const int16_t delta = (int16_t)(seq - dp->highestSeq);   // wraps correctly at 65535
        if (delta > 1) {
            const unsigned int missing = (unsigned int)(delta - 1);
            dp->stats.seqGaps++;
            dp->stats.packetsLost += missing;
            if (missing > dp->policy.maxGapToRequest) {
                // AN OUTAGE, NOT A LOSS EVENT. Written off whole, never tracked and never asked
                // for; the keyframe path is the recovery mechanism for a hole this wide. See
                // BURSTS AND STORMS, mechanism 3 — this branch is also what keeps the declare
                // loop below from walking a gap of tens of thousands of sequence numbers.
                //
                // The identity still balances: both terms move by the same `missing`.
                dp->stats.nackGapsTooLarge++;
                dp->stats.packetsStillMissing += missing;
            } else {
                // Each implied-missing seq is tracked until it arrives or ages out — see the
                // LOSS ACCOUNTING note — and requested in the meantime if a sink is installed.
                for (int16_t k = 1; k < delta; k++) {
                    MDDeclareMissing(dp, (uint16_t)(dp->highestSeq + (uint16_t)k), nowNs, true);
                }
            }
            // A gap mid-NAL means the reassembled NAL would be silently corrupt.
            // Throwing it away is the only honest option without a jitter buffer.
            MDAbandonFragment(dp);
            dp->highestSeq = seq;
        } else if (delta <= 0) {
            dp->stats.packetsReordered++;
            // Was this one we had given up on? `packetsRecovered` is derived HERE — from the
            // outstanding table — and not from `packetsReordered`, which also counts
            // duplicates and stragglers we were never waiting for.
            MDClaimLate(dp, seq, nowNs);
            // Deliberately NOT rewinding highestSeq: this packet is late or a
            // duplicate. We still depacketize it — for a single-NAL packet that
            // is a win, and for FU-A the start/end bits keep it self-consistent.
        } else {
            dp->highestSeq = seq;
        }
    }

    // AFTER the sequence accounting, never before: servicing sorts by distance behind
    // `highestSeq`, and a request built from a stale highest would order the list wrongly across
    // the 16-bit wrap. Costs one comparison per packet when nothing is outstanding.
    MDServiceNacks(dp, nowNs);

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
    // Snapshot-time value, not a running tally: how many declared-missing seqs are still inside
    // the recovery window and so have no verdict yet. This is the term that makes
    //     packetsLost == packetsRecovered + packetsStillMissing + packetsOutstanding
    // balance at any instant. In a session total it should be small; a large value means the
    // session ended with a burst still in flight.
    outStats->packetsOutstanding = dp->outstandingCount;

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
