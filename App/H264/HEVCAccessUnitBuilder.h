//
//  HEVCAccessUnitBuilder.h
//  Manifold
//
//  Complete HEVC NAL units in, complete ACCESS UNITS out. The H.265 sibling of
//  H264AccessUnitBuilder, which says why it had to be a second builder rather than a flag in that
//  one: a TWO-byte NAL header with the type in bits 1–6 of the first byte, VPS/SPS/PPS at 32/33/34,
//  and random access spread across eight types (16–23) instead of H.264's one IDR.
//
//  SRT ONLY TODAY. WHEP's HEVC is out of scope (ROADMAP_IDEAS.md), so nothing reassembles HEVC from
//  RTP and this builder has only the accessor path: a transport appends one demuxed packet's NAL
//  units, reads the access unit back with CopyAccessUnitContents, dispatches its own type, then
//  flushes. See SRTAccessUnitReader.c, which is that transport.
//
//  ── WHAT IT DOES TO EACH NAL (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3) ──────────
//
//    * nuh_layer_id > 0 → DROPPED, counted (decision 8: the base layer only). A layer-1 SPS must
//      not replace the base layer's, and VideoToolbox decodes the base layer.
//    * VPS (32), SPS (33) → out of band, the latest of each held. The PPS table is cleared when the
//      SPS bytes change: a PPS refers to an SPS by id, and the encoder re-sends its PPS right after.
//    * PPS (34) → out of band, held BY ID, all 64 (pps_pic_parameter_set_id is 0…63). A stream with
//      more than one PPS id needs every one of them in the format description, or the slices that
//      name the others fail to decode. 64 slots of 1 KB is cheap.
//    * AUD (35), filler (38) → dropped, as on H.264.
//    * prefix (39) and suffix (40) SEI → passed through UNPARSED. Stage 5 reads HDR10 SEI from here.
//    * reserved and unspecified non-VCL types (41–63) → dropped, counted. A decoder ignores them by
//      the standard's own rule, so dropping them cannot change a picture.
//    * every VCL type (0–31), and EOS/EOB (36, 37) → appended with a 4-byte big-endian length.
//
//  EMULATION PREVENTION IS LEFT IN, for the reason H264AccessUnitBuilder.c gives: it is the
//  decoder's job, and it is what keeps the Annex-B start-code scan exact.
//
//  ── RANDOM ACCESS (decision 5) ──────────────────────────────────────────────────────────
//
//  The access unit reports the type of its random-access picture (16–23, or 0) and whether it is
//  RASL (8, 9). The RULE that acts on those — open on any random-access picture, skip the RASL
//  pictures that cannot be decoded — is ManifoldHEVCRandomAccessGate below, in this file so the C
//  harness tests the same code the decoder runs.
//
//  PURE C, NO DEPENDENCIES, NOT THREAD-SAFE: one builder per stream, owned by one producer thread.
//  Same discipline as the H.264 builder, whose ManifoldH264Buffer it shares.
//

#ifndef MANIFOLD_HEVC_ACCESS_UNIT_BUILDER_H
#define MANIFOLD_HEVC_ACCESS_UNIT_BUILDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "H264AccessUnitBuilder.h"   // ManifoldH264Buffer, the shared grow-once byte buffer

#ifdef __cplusplus
extern "C" {
#endif

/// pps_pic_parameter_set_id is ue(v) in 0…63 (H.265 §7.4.3.3.1).
#define MANIFOLD_HEVC_MAX_PPS_COUNT 64

/// A finished HEVC access unit. Every pointer aliases builder-owned storage and is valid until the
/// next Append or Flush.
typedef struct {
    const uint8_t *data;              ///< Length-prefixed (4-byte big-endian) NAL units.
    size_t         size;
    /// The nal_unit_type of the access unit's random-access (IRAP) picture, 16–23: BLA 16–18, IDR
    /// 19–20, CRA 21, reserved IRAP 22–23. 0 when it holds none.
    uint8_t        randomAccessType;
    /// A RASL picture (8, 9): it references pictures BEFORE its associated CRA or BLA in decode
    /// order, so it cannot be decoded when decoding started at that CRA, or after any BLA.
    bool           rasl;
    bool           parameterSetsChanged;  ///< VPS, SPS or any PPS differ from the last emitted AU's.
    const uint8_t *vps;
    size_t         vpsSize;
    const uint8_t *sps;
    size_t         spsSize;
    /// Every held PPS, in id order, EACH WITH A 4-BYTE BIG-ENDIAN LENGTH IN FRONT — the same framing
    /// as `data`, so a reader walks it the same way. `ppsCount` of them.
    const uint8_t *ppsList;
    size_t         ppsListSize;
    uint32_t       ppsCount;
} ManifoldHEVCAccessUnitContents;

typedef struct ManifoldHEVCAccessUnitBuilder ManifoldHEVCAccessUnitBuilder;

/// Counters. Monotonic; snapshot and diff for rates.
typedef struct {
    // ── Base-layer NAL units, by nal_unit_type (H.265 Table 7-1) ─────────────
    uint64_t nalVPS;                   ///< 32
    uint64_t nalSPS;                   ///< 33
    uint64_t nalPPS;                   ///< 34
    uint64_t nalIDR;                   ///< 19, 20
    uint64_t nalCRA;                   ///< 21
    uint64_t nalBLA;                   ///< 16, 17, 18
    uint64_t nalReservedIRAP;          ///< 22, 23
    uint64_t nalRASL;                  ///< 8, 9
    uint64_t nalRADL;                  ///< 6, 7
    uint64_t nalTrailing;              ///< 0–5 (TRAIL, TSA, STSA), and the reserved VCL types 10–15, 24–31
    uint64_t nalSEI;                   ///< 39, 40
    uint64_t nalAUD;                   ///< 35 (dropped from output)
    uint64_t nalOther;                 ///< 36–38 (EOS, EOB, filler)
    uint64_t nalDroppedReserved;       ///< 41–63, dropped
    uint64_t nalHigherLayer;           ///< nuh_layer_id > 0, any type, dropped (decision 8)
    uint64_t nalMalformed;             ///< Shorter than the 2-byte header, or forbidden_zero_bit set
    uint64_t nalEmpty;
    uint64_t ppsIdUnreadable;          ///< A PPS whose id did not parse or exceeds 63, ignored

    // ── Access units ─────────────────────────────────────────────────────────
    uint64_t accessUnits;              ///< Emitted (non-empty AUs).
    uint64_t randomAccessUnits;        ///< AUs holding an IRAP picture.
    uint64_t raslAccessUnits;          ///< AUs holding a RASL picture.
    uint64_t accessUnitsOversize;      ///< Blew the 8 MB cap; discarded.

    // ── Parameter sets held ──────────────────────────────────────────────────
    uint64_t spsChanges;               ///< SPS byte changes after the first (a format change, or a second SPS)
    uint32_t ppsIdsHeld;               ///< Distinct PPS ids held now
    uint32_t ppsIdsMax;                ///< The most ever held at once
    size_t   vpsSize;
    size_t   spsSize;
} ManifoldHEVCAccessUnitBuilderStats;

ManifoldHEVCAccessUnitBuilder *ManifoldHEVCAccessUnitBuilderCreate(void);
void ManifoldHEVCAccessUnitBuilderDestroy(ManifoldHEVCAccessUnitBuilder *builder);

/// Feeds ONE complete NAL unit: the 2-byte header first, NO start code, NO length prefix,
/// emulation prevention still present. Never blocks, never logs.
void ManifoldHEVCAccessUnitBuilderAppendNAL(ManifoldHEVCAccessUnitBuilder *builder,
                                            const uint8_t *nal, size_t size);

/// Reads the OPEN access unit without closing it. False when none is open, it is empty, or it blew
/// the size cap — the cases there is nothing to decode.
bool ManifoldHEVCAccessUnitBuilderCopyAccessUnitContents(const ManifoldHEVCAccessUnitBuilder *builder,
                                                         ManifoldHEVCAccessUnitContents *outContents);

/// Closes the open access unit: counts it, resets the buffer. A no-op when none is open, so the
/// sticky parameterSetsChanged survives a packet of parameter sets alone. Clears
/// parameterSetsChanged only when an access unit was actually emitted.
void ManifoldHEVCAccessUnitBuilderFlush(ManifoldHEVCAccessUnitBuilder *builder);

void ManifoldHEVCAccessUnitBuilderCopyStats(const ManifoldHEVCAccessUnitBuilder *builder,
                                            ManifoldHEVCAccessUnitBuilderStats *outStats);

// ── The random-access gate (decision 5) ───────────────────────────────────────────────────
//
// Where decoding may begin, and which pictures after that beginning cannot be decoded.
//
//   * CLOSED until ANY random-access picture (16–23). An IDR-only rule would never open on x265's
//     default stream, which has one IDR and then CRAs (§6.10, the audit).
//   * OPENED ON A CRA (or a reserved IRAP, read the same way): the RASL pictures associated with it
//     reference pictures this decoder never had. They are dropped until the next random-access
//     picture. A CRA met while ALREADY open is an ordinary picture: its RASL are decodable.
//   * A BLA: its RASL are dropped whether or not the gate was open — a broken link by definition.
//   * An IDR: has no RASL.
//   * Closed again after loss (a decode error) or a format change, and the rule starts over.
//
// RADL pictures are decodable from their IRAP and are never dropped.

typedef struct {
    bool open;
    bool skippingRASL;
} ManifoldHEVCRandomAccessGate;

typedef int32_t ManifoldHEVCGateVerdict;
enum {
    ManifoldHEVCGateDecode = 0,
    ManifoldHEVCGateDropAwaitingRandomAccess,   ///< Closed, and this is not a random-access picture.
    ManifoldHEVCGateDropRASL,                   ///< Open, but a RASL picture of the CRA/BLA it opened on.
};

/// Judges one access unit and advances the gate. `randomAccessType` and `rasl` as in
/// ManifoldHEVCAccessUnitContents.
ManifoldHEVCGateVerdict ManifoldHEVCRandomAccessGateAdmit(ManifoldHEVCRandomAccessGate *gate,
                                                          uint8_t randomAccessType, bool rasl);

/// Closes the gate: the next random-access picture opens it as if the stream had just begun.
void ManifoldHEVCRandomAccessGateClose(ManifoldHEVCRandomAccessGate *gate);

/// Human-readable IRAP name for logs: "IDR", "CRA", "BLA", "reserved IRAP", or "none".
const char *ManifoldHEVCRandomAccessName(uint8_t randomAccessType);

#ifdef __cplusplus
}
#endif

#endif /* MANIFOLD_HEVC_ACCESS_UNIT_BUILDER_H */
