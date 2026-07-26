//
//  H264AccessUnitBuilder.h
//  Manifold
//
//  Complete NAL units in, complete ACCESS UNITS out. The H.264 semantics half of
//  what used to be H264Depacketizer.c, extracted so more than one transport can
//  use it.
//
//  ── WHY IT IS SEPARATE ─────────────────────────────────────────────────────
//
//  Two ingest paths need the SAME work done to a NAL unit:
//
//    * WHEP (H264Depacketizer.c) — RFC 6184 reassembly produces NALs from RTP
//      single-NAL, STAP-A and FU-A packets.
//    * SRT (planned) — libavformat demuxes MPEG-TS and hands back Annex-B byte
//      runs; a start-code scanner splits them into NALs.
//
//  Everything AFTER "here is one complete NAL unit" is identical between them:
//  classify by type, divert SPS/PPS out-of-band with change detection, drop AUD
//  and filler, mark the AU as a keyframe on IDR, and append with a 4-byte
//  big-endian length prefix. That is this file. Everything BEFORE it — RTP
//  header geometry, sequence accounting, fragment reassembly, TS demuxing — is
//  the transport's problem and stays with the transport.
//
//  THIS FILE IS H.264 ONLY, AND THE ASSUMPTION IS LOAD-BEARING. Every NAL here
//  is assumed to begin with a ONE-byte NAL header whose type is the low 5 bits
//  (`nal[0] & 0x1F`, H.264 §7.3.1). HEVC breaks all of it: a TWO-byte header,
//  the type in bits 1–6 of the first byte (`(nal[0] >> 1) & 0x3F`), VPS/SPS/PPS
//  at 32/33/34, and IDR split across types 19 and 20 with no single "type 5"
//  equivalent. Adding HEVC means a second builder, not a flag in this one.
//
//  PURE C, NO DEPENDENCIES. No libdatachannel, no libavformat, no Foundation,
//  no VideoToolbox — a byte-in/byte-out state machine, which is what keeps the
//  linkage discipline of DataChannelBridge.m (a `.m`, never a `.mm`) intact and
//  what lets the SRT path reuse it without dragging WebRTC in.
//
//  THREADING. NOT thread-safe, by design. One builder is owned by exactly one
//  producer thread. Any other thread reading stats must serialize externally.
//

#ifndef MANIFOLD_H264_ACCESS_UNIT_BUILDER_H
#define MANIFOLD_H264_ACCESS_UNIT_BUILDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── The access unit: the shared contract between every transport and the decoder ──

/// One complete access unit: every VCL NAL sharing a presentation time, concatenated.
///
/// FORMAT IS AVCC (length-prefixed), NOT Annex-B: each NAL is preceded by its
/// length as a 4-byte big-endian integer. See the header comment in the .c file
/// for why. Parameter sets are NOT in here — they are carried out-of-band in
/// `sps`/`pps`, which is what CMVideoFormatDescriptionCreateFromH264ParameterSets
/// wants and what VTDecompressionSession requires.
typedef struct {
    const uint8_t *data;            ///< AVCC bytes. Valid ONLY for the duration of the callback.
    size_t         size;

    /// The RTP timestamp of the packets that carried this access unit: 32-bit,
    /// random origin, wraps every ~13.25 hours at 90 kHz. Raw — unwrapping is
    /// RTPTimestampUnwrapper's job, on the Swift side.
    ///
    /// STAGE 3b CONSIDERED WIDENING THIS TO int64 pts + dts AND DECIDED NOT TO.
    /// The transports converge at the DECODER, whose signature is now
    /// `decode(… pts: CMTime, dts: CMTime)` — CMTime because it carries its own
    /// timescale and its own validity, so one signature serves both with no
    /// branch. They do NOT converge here: this struct is produced by RTP
    /// reassembly and consumed by WHEP's bridge, and SRT reaches the same
    /// decoder through libavformat and its own bridge without passing through
    /// this type at all.
    ///
    /// Widening it would have made things worse, not better. The unwrap lives
    /// downstream in Swift, so an int64 field here would hold a still-wrapped
    /// 32-bit value while its type promised a monotonic one — and the next
    /// person to read it would reasonably stop unwrapping. A `dts` field would
    /// be permanently invalid, because RTP carries no decode timestamp for
    /// H.264. `uint32_t` is load-bearing documentation: it says "this wraps".
    ///
    /// WHAT IT COSTS SRT: its own access-unit struct and handler typedef, and a
    /// builder that can emit through both. The cheap version is an accessor on
    /// the builder that hands back the finished AU (bytes, keyframe,
    /// parameterSetsChanged, parameter sets) and lets each transport dispatch
    /// its own type — the builder's H.264 logic, which is the part worth
    /// sharing, stays single-copy either way.
    uint32_t       rtpTimestamp;    ///< 90 kHz sender clock.

    bool           keyframe;        ///< Contains an IDR slice.
    bool           parameterSetsChanged; ///< SPS or PPS differed from the last ones; rebuild the format description.
    const uint8_t *sps;             ///< Latest SPS (no start code, no length prefix), or NULL.
    size_t         spsSize;
    const uint8_t *pps;
    size_t         ppsSize;
} ManifoldH264AccessUnit;

/// Fires on the PRODUCER thread, inline, once per access unit. Copy anything you keep.
typedef void (*ManifoldH264AccessUnitHandler)(const ManifoldH264AccessUnit *accessUnit, void *context);

/// A finished access unit MINUS any transport timestamp — everything the builder
/// actually knows, and nothing it doesn't.
///
/// This is the seam promised in the `rtpTimestamp` note above: a transport reads
/// the finished AU through `CopyAccessUnitContents` and dispatches its OWN type,
/// so SRT can carry int64 pts/dts without RTP's uint32 field following it around
/// and without a second copy of the H.264 logic. WHEP does not use it — it keeps
/// the handler, which builds ManifoldH264AccessUnit from these same fields.
typedef struct {
    const uint8_t *data;            ///< AVCC bytes. Valid until the next Append or Flush.
    size_t         size;
    bool           keyframe;
    bool           parameterSetsChanged;
    const uint8_t *sps;
    size_t         spsSize;
    const uint8_t *pps;
    size_t         ppsSize;
} ManifoldH264AccessUnitContents;

// ── Builder ───────────────────────────────────────────────────────────────────

/// Opaque builder state. One per inbound video stream.
typedef struct ManifoldH264AccessUnitBuilder ManifoldH264AccessUnitBuilder;

/// Counters owned by the H.264 layer. The transport folds these into its own
/// stats struct — see ManifoldH264DepacketizerCopyStats — so callers keep seeing
/// one set of numbers. Monotonic; snapshot and diff for rates.
typedef struct {
    // ── NAL units seen, by nal_unit_type (H.264 Table 7-1) ───────────────────
    uint64_t nalSPS;                   ///< 7
    uint64_t nalPPS;                   ///< 8
    uint64_t nalIDR;                   ///< 5  — coded slice of an IDR picture
    uint64_t nalSlice;                 ///< 1  — coded slice, non-IDR
    uint64_t nalSEI;                   ///< 6
    uint64_t nalAUD;                   ///< 9  — access unit delimiter (dropped from output)
    uint64_t nalOther;                 ///< Any other type we understood but do not classify.
    uint64_t nalEmpty;                 ///< Zero-length NALs handed in — a caller bug or a corrupt stream.

    // ── Access units ─────────────────────────────────────────────────────────
    uint64_t accessUnits;              ///< Frames emitted (non-empty AUs).
    uint64_t keyframes;                ///< AUs containing an IDR slice.
    uint64_t accessUnitsOversize;      ///< AUs that blew the sanity cap and were discarded.

    // ── Parameter sets held ──────────────────────────────────────────────────
    size_t   spsSize;                  ///< Bytes of SPS held (0 = none yet).
    size_t   ppsSize;                  ///< Bytes of PPS held (0 = none yet).
} ManifoldH264AccessUnitBuilderStats;

/// Allocates a builder. Returns NULL only on allocation failure.
ManifoldH264AccessUnitBuilder *ManifoldH264AccessUnitBuilderCreate(void);

void ManifoldH264AccessUnitBuilderDestroy(ManifoldH264AccessUnitBuilder *builder);

/// Installs the access-unit sink. Counters advance whether or not one is set.
void ManifoldH264AccessUnitBuilderSetHandler(ManifoldH264AccessUnitBuilder *builder,
                                             ManifoldH264AccessUnitHandler handler,
                                             void *context);

/// Feeds ONE complete NAL unit: header byte first, NO start code, NO length
/// prefix, emulation prevention bytes STILL PRESENT (see the .c file).
///
/// `timestamp` is stamped onto the access unit when this NAL OPENS it, and is
/// ignored for every NAL that joins an already-open one — so the transport, not
/// the builder, decides where access units begin and end. Call Flush at that
/// boundary. Never blocks, never logs, and allocates only while the internal
/// buffer is still growing to the largest frame seen.
void ManifoldH264AccessUnitBuilderAppendNAL(ManifoldH264AccessUnitBuilder *builder,
                                            const uint8_t *nal, size_t size,
                                            uint32_t timestamp);

/// Closes and emits the open access unit, if any. No-op when none is open, so it
/// is safe to call on every possible boundary signal. Also the end-of-stream call.
void ManifoldH264AccessUnitBuilderFlush(ManifoldH264AccessUnitBuilder *builder);

/// True when an access unit is under construction; writes its timestamp to
/// `outTimestamp` (may be NULL) when so. This is what lets a transport implement
/// a "the timestamp changed, so the previous frame is over" boundary — the AU
/// opens lazily, on the first non-parameter-set NAL, so the transport cannot
/// track that state itself without duplicating the classification rules.
bool ManifoldH264AccessUnitBuilderIsAccessUnitOpen(const ManifoldH264AccessUnitBuilder *builder,
                                                   uint32_t *outTimestamp);

/// Reads the OPEN access unit without emitting or resetting it. True when there is
/// one worth having; false when none is open, it is still empty, or it blew the
/// size cap — i.e. exactly the cases the handler would not fire for either.
///
/// FOR TRANSPORTS THAT DISPATCH THEIR OWN AU TYPE. The sequence is: append every
/// NAL, call this, build and dispatch your own struct, then Flush to advance the
/// counters and reset. Flush is still what closes the AU, so the stats are the
/// same whichever route a transport takes. The pointers alias builder-owned
/// storage and die at the next Append or Flush — copy anything you keep.
bool ManifoldH264AccessUnitBuilderCopyAccessUnitContents(const ManifoldH264AccessUnitBuilder *builder,
                                                         ManifoldH264AccessUnitContents *outContents);

/// Copies the counters out. Caller must serialize against the producer thread.
void ManifoldH264AccessUnitBuilderCopyStats(const ManifoldH264AccessUnitBuilder *builder,
                                            ManifoldH264AccessUnitBuilderStats *outStats);

// ── Shared byte buffer ────────────────────────────────────────────────────────
//
// NOT part of the access-unit contract — exported only so the transports can
// share one implementation instead of each carrying a copy. The WHEP
// depacketizer uses it for FU-A fragment reassembly; the SRT Annex-B scanner
// will want it too. Grow-once, reuse-forever: capacity settles at the largest
// payload seen and the steady state does zero allocation.

typedef struct {
    uint8_t *data;
    size_t   size;
    size_t   capacity;
} ManifoldH264Buffer;

/// Ensures `needed` bytes of capacity. False on allocation failure, buffer unchanged.
bool ManifoldH264BufferReserve(ManifoldH264Buffer *buffer, size_t needed);

/// Appends `count` bytes. False on allocation failure, buffer unchanged.
bool ManifoldH264BufferAppend(ManifoldH264Buffer *buffer, const uint8_t *bytes, size_t count);

/// Releases the allocation and zeroes the buffer.
void ManifoldH264BufferFree(ManifoldH264Buffer *buffer);

#ifdef __cplusplus
}
#endif

#endif /* MANIFOLD_H264_ACCESS_UNIT_BUILDER_H */
