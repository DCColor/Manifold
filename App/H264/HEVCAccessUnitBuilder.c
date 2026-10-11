//
//  HEVCAccessUnitBuilder.c
//  Manifold
//
//  NAL units in, access units out, for HEVC. See HEVCAccessUnitBuilder.h for the contract, and
//  H264AccessUnitBuilder.c for why the output is length-prefixed and why emulation prevention stays.
//

#include "HEVCAccessUnitBuilder.h"

#include <stdlib.h>
#include <string.h>

// The same 8 MB sanity cap as H.264's, and the same caveat (SRTAccessUnitReader.c): it bounds a
// corrupt length, it is not a real limit, and an all-intra 4:2:2 10-bit frame can approach it
// (Stage 3b's open question). Parameter sets get 1 KB, matching SPSColor's SPS bound: an HEVC SPS
// with explicit scaling lists runs to a few hundred bytes.
#define MD_HEVC_MAX_ACCESS_UNIT_BYTES  (8u * 1024u * 1024u)
#define MD_HEVC_MAX_PARAMETER_SET      1024u

// nal_unit_type (H.265 Table 7-1). Two-byte header: forbidden_zero_bit, type in bits 1–6 of the
// first byte, nuh_layer_id across the two, nuh_temporal_id_plus1 in the low 3 bits of the second.
#define MD_HEVC_RADL_N        6
#define MD_HEVC_RADL_R        7
#define MD_HEVC_RASL_N        8
#define MD_HEVC_RASL_R        9
#define MD_HEVC_BLA_W_LP     16
#define MD_HEVC_BLA_N_LP     18
#define MD_HEVC_IDR_W_RADL   19
#define MD_HEVC_IDR_N_LP     20
#define MD_HEVC_CRA          21
#define MD_HEVC_RSV_IRAP_23  23
#define MD_HEVC_VPS          32
#define MD_HEVC_SPS          33
#define MD_HEVC_PPS          34
#define MD_HEVC_AUD          35
#define MD_HEVC_EOS          36
#define MD_HEVC_EOB          37
#define MD_HEVC_FD           38
#define MD_HEVC_SEI_PREFIX   39
#define MD_HEVC_SEI_SUFFIX   40

// SEI payloadType (H.265 Table D.1, Annex D.2) and their fixed payload sizes in bytes.
#define MD_HEVC_SEI_MASTERING_DISPLAY        137
#define MD_HEVC_SEI_MASTERING_DISPLAY_BYTES   24
#define MD_HEVC_SEI_CONTENT_LIGHT_LEVEL      144
#define MD_HEVC_SEI_CONTENT_LIGHT_LEVEL_BYTES  4

typedef struct {
    uint8_t bytes[MD_HEVC_MAX_PARAMETER_SET];
    size_t  size;      // 0 = empty slot
} MDHEVCParameterSet;

struct ManifoldHEVCAccessUnitBuilder {
    ManifoldH264Buffer accessUnit;
    bool    accessUnitActive;
    bool    accessUnitHasVCL;
    bool    accessUnitOverflowed;
    uint8_t accessUnitRandomAccessType;
    bool    accessUnitRASL;
    bool    parameterSetsChanged;     // sticky until an access unit is EMITTED

    MDHEVCParameterSet vps;
    MDHEVCParameterSet sps;
    MDHEVCParameterSet pps[MANIFOLD_HEVC_MAX_PPS_COUNT];

    /// The held PPS, packed in id order with 4-byte lengths. Rebuilt only when a PPS changes.
    ManifoldH264Buffer ppsPacked;
    uint32_t ppsPackedCount;
    bool     ppsPackedStale;

    /// The latest HDR10 SEI read (Stage 5). Persists across access units: x265 repeats it at every
    /// random-access picture, and a reader asks "what does the stream say now".
    ManifoldHEVCHDR10SEI hdr10;

    ManifoldHEVCAccessUnitBuilderStats stats;
};

// ── Parameter sets ─────────────────────────────────────────────────────────────────────────

/// Stores a parameter set, reporting whether it changed. Re-sent identical parameter sets at every
/// random-access picture are normal and must not invalidate the format description.
static bool MDHEVCStore(MDHEVCParameterSet *slot, const uint8_t *nal, size_t size) {
    if (size == 0 || size > MD_HEVC_MAX_PARAMETER_SET) return false;
    if (slot->size == size && memcmp(slot->bytes, nal, size) == 0) return false;
    memcpy(slot->bytes, nal, size);
    slot->size = size;
    return true;
}

/// pps_pic_parameter_set_id: the first ue(v) after the 2-byte header. At most 13 bits for a legal
/// id, so it never reaches an emulation-prevention byte (that needs two zero bytes first, which
/// would be a ue of more than 16 leading zeros). -1 when it does not parse or is out of range.
static int MDHEVCReadPPSId(const uint8_t *nal, size_t size) {
    size_t bit = 16;                                   // past the header
    const size_t limit = size * 8;
    int zeros = 0;
    while (bit < limit && !((nal[bit >> 3] >> (7 - (bit & 7))) & 1)) {
        if (++zeros > 6) return -1;                    // 2^7 - 1 > 63: out of range already
        bit++;
    }
    if (bit >= limit) return -1;
    bit++;                                             // the terminating 1
    if (bit + (size_t)zeros > limit) return -1;
    int value = 0;
    for (int i = 0; i < zeros; i++, bit++) value = (value << 1) | ((nal[bit >> 3] >> (7 - (bit & 7))) & 1);
    const int id = (1 << zeros) - 1 + value;
    return id < MANIFOLD_HEVC_MAX_PPS_COUNT ? id : -1;
}

static void MDHEVCCountHeldPPS(ManifoldHEVCAccessUnitBuilder *ab) {
    uint32_t held = 0;
    for (int i = 0; i < MANIFOLD_HEVC_MAX_PPS_COUNT; i++) if (ab->pps[i].size) held++;
    ab->stats.ppsIdsHeld = held;
    if (held > ab->stats.ppsIdsMax) ab->stats.ppsIdsMax = held;
}

/// Packs the held PPS into one length-prefixed run, in id order. Called only when one changed.
static void MDHEVCRepackPPS(ManifoldHEVCAccessUnitBuilder *ab) {
    ab->ppsPacked.size = 0;
    ab->ppsPackedCount = 0;
    for (int i = 0; i < MANIFOLD_HEVC_MAX_PPS_COUNT; i++) {
        const size_t n = ab->pps[i].size;
        if (!n) continue;
        const uint8_t prefix[4] = { (uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n };
        if (!ManifoldH264BufferAppend(&ab->ppsPacked, prefix, 4) ||
            !ManifoldH264BufferAppend(&ab->ppsPacked, ab->pps[i].bytes, n)) {
            ab->ppsPacked.size = 0;
            ab->ppsPackedCount = 0;
            return;   // allocation failure: no PPS, so no format description, so nothing decodes
        }
        ab->ppsPackedCount++;
    }
    ab->ppsPackedStale = false;
}

// ── Prefix SEI: HDR10 static metadata (Stage 5, decision 6: log only) ─────────────────────────
//
// The sei_rbsp is read IN PLACE, with emulation prevention removed on the fly by the byte reader below
// (a 0x03 after two zero bytes is dropped): the NAL appended to the access unit is never touched, and
// no copy is made. payloadType and payloadSize are 0xFF-extended (H.265 §7.3.5); both count RBSP bytes,
// which is what the reader yields. Every read is bounds-checked. On any problem — a type or size
// running off the end, a payload past the end, a 137 or 144 of the wrong size — the rest of THIS NAL is
// abandoned and counted; nothing partial is ever kept, because a value is only committed once its
// whole payload has been read.

typedef struct {
    const uint8_t *p;
    size_t size;
    size_t at;
    int zeros;     // consecutive zero bytes just yielded
} MDSEIReader;

/// The next RBSP byte, skipping an emulation-prevention byte. False at the end.
static bool MDSEINextByte(MDSEIReader *r, uint8_t *out) {
    if (r->at < r->size && r->zeros >= 2 && r->p[r->at] == 0x03) {
        r->at++;
        r->zeros = 0;
    }
    if (r->at >= r->size) return false;
    const uint8_t b = r->p[r->at++];
    r->zeros = b == 0 ? r->zeros + 1 : 0;
    *out = b;
    return true;
}

/// more_rbsp_data(): false at the end, or when all that is left is the rbsp_trailing_bits byte.
static bool MDSEIMoreData(const MDSEIReader *r) {
    size_t at = r->at;
    if (at < r->size && r->zeros >= 2 && r->p[at] == 0x03) at++;
    if (at >= r->size) return false;
    return !(at + 1 == r->size && r->p[at] == 0x80);
}

/// A 0xFF-extended value (payloadType, payloadSize). False if it runs off the end.
static bool MDSEIReadExtended(MDSEIReader *r, uint32_t *out) {
    uint32_t v = 0;
    uint8_t b;
    do {
        if (!MDSEINextByte(r, &b)) return false;
        v += b;
        if (v > 0x00FFFFFFu) return false;   // an absurd run of 0xFF: not a real SEI
    } while (b == 0xFF);
    *out = v;
    return true;
}

static bool MDSEIReadBytes(MDSEIReader *r, uint8_t *out, size_t n) {
    for (size_t i = 0; i < n; i++) if (!MDSEINextByte(r, &out[i])) return false;
    return true;
}

static uint16_t MDBE16(const uint8_t *b) { return (uint16_t)(((uint16_t)b[0] << 8) | b[1]); }
static uint32_t MDBE32(const uint8_t *b) {
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}

/// Reads one prefix SEI NAL (header included) for payloads 137 and 144. Never fails the NAL itself.
static void MDHEVCReadPrefixSEI(ManifoldHEVCAccessUnitBuilder *ab, const uint8_t *nal, size_t size) {
    MDSEIReader r = { nal, size, 2, 0 };          // past the 2-byte NAL header
    while (MDSEIMoreData(&r)) {
        uint32_t type, payloadSize;
        if (!MDSEIReadExtended(&r, &type) || !MDSEIReadExtended(&r, &payloadSize)) goto malformed;
        if (type == MD_HEVC_SEI_MASTERING_DISPLAY) {
            uint8_t b[MD_HEVC_SEI_MASTERING_DISPLAY_BYTES];
            if (payloadSize != sizeof b || !MDSEIReadBytes(&r, b, sizeof b)) goto malformed;
            ManifoldHEVCHDR10SEI *h = &ab->hdr10;
            for (int c = 0; c < 3; c++) {         // G, B, R, as coded: kept in that order
                h->displayPrimariesX[c] = MDBE16(b + 4 * c);
                h->displayPrimariesY[c] = MDBE16(b + 4 * c + 2);
            }
            h->whitePointX = MDBE16(b + 12);
            h->whitePointY = MDBE16(b + 14);
            h->maxDisplayMasteringLuminance = MDBE32(b + 16);
            h->minDisplayMasteringLuminance = MDBE32(b + 20);
            h->hasMDCV = true;
            ab->stats.seiMDCV++;
        } else if (type == MD_HEVC_SEI_CONTENT_LIGHT_LEVEL) {
            uint8_t b[MD_HEVC_SEI_CONTENT_LIGHT_LEVEL_BYTES];
            if (payloadSize != sizeof b || !MDSEIReadBytes(&r, b, sizeof b)) goto malformed;
            ab->hdr10.maxContentLightLevel = MDBE16(b);
            ab->hdr10.maxPicAverageLightLevel = MDBE16(b + 2);
            ab->hdr10.hasCLL = true;
            ab->stats.seiCLL++;
        } else {
            uint8_t skipped;
            for (uint32_t i = 0; i < payloadSize; i++) if (!MDSEINextByte(&r, &skipped)) goto malformed;
        }
    }
    return;
malformed:
    ab->stats.seiMalformed++;
}

// ── Access unit assembly ───────────────────────────────────────────────────────────────────

static void MDHEVCOpenIfNeeded(ManifoldHEVCAccessUnitBuilder *ab) {
    if (ab->accessUnitActive) return;
    ab->accessUnitActive = true;
    ab->accessUnitHasVCL = false;
    ab->accessUnitOverflowed = false;
    ab->accessUnitRandomAccessType = 0;
    ab->accessUnitRASL = false;
}

static void MDHEVCAppendToAccessUnit(ManifoldHEVCAccessUnitBuilder *ab, const uint8_t *nal, size_t size) {
    if (ab->accessUnitOverflowed) return;
    if (ab->accessUnit.size + 4 + size > MD_HEVC_MAX_ACCESS_UNIT_BYTES) {
        ab->accessUnitOverflowed = true;
        return;
    }
    const uint8_t prefix[4] = { (uint8_t)(size >> 24), (uint8_t)(size >> 16), (uint8_t)(size >> 8), (uint8_t)size };
    if (!ManifoldH264BufferAppend(&ab->accessUnit, prefix, 4) ||
        !ManifoldH264BufferAppend(&ab->accessUnit, nal, size)) {
        ab->accessUnitOverflowed = true;   // allocation failure — discard the frame, keep running
    }
}

// ── Public API ─────────────────────────────────────────────────────────────────────────────

ManifoldHEVCAccessUnitBuilder *ManifoldHEVCAccessUnitBuilderCreate(void) {
    return calloc(1, sizeof(ManifoldHEVCAccessUnitBuilder));
}

void ManifoldHEVCAccessUnitBuilderDestroy(ManifoldHEVCAccessUnitBuilder *ab) {
    if (!ab) return;
    ManifoldH264BufferFree(&ab->accessUnit);
    ManifoldH264BufferFree(&ab->ppsPacked);
    free(ab);
}

void ManifoldHEVCAccessUnitBuilderAppendNAL(ManifoldHEVCAccessUnitBuilder *ab,
                                            const uint8_t *nal, size_t size) {
    if (!ab || !nal) return;
    if (size == 0) { ab->stats.nalEmpty++; return; }
    // The header is two bytes, and a NAL with forbidden_zero_bit set is not a NAL (§7.4.2.2).
    if (size < 2 || (nal[0] & 0x80u)) { ab->stats.nalMalformed++; return; }

    const uint8_t type  = (uint8_t)((nal[0] >> 1) & 0x3Fu);
    const uint8_t layer = (uint8_t)(((nal[0] & 0x01u) << 5) | (nal[1] >> 3));

    // DECISION 8 — THE BASE LAYER ONLY, AND BEFORE ANYTHING ELSE LOOKS AT THE TYPE. An enhancement
    // layer's SPS has a different syntax and must never replace the base layer's; its slices are
    // not for this decoder.
    if (layer != 0) { ab->stats.nalHigherLayer++; return; }

    switch (type) {
        case MD_HEVC_VPS: {
            ab->stats.nalVPS++;
            if (MDHEVCStore(&ab->vps, nal, size)) ab->parameterSetsChanged = true;
            ab->stats.vpsSize = ab->vps.size;
            return;
        }
        case MD_HEVC_SPS: {
            ab->stats.nalSPS++;
            const bool hadSPS = ab->sps.size != 0;
            if (MDHEVCStore(&ab->sps, nal, size)) {
                ab->parameterSetsChanged = true;
                if (hadSPS) ab->stats.spsChanges++;
                // A new SPS invalidates every PPS built against the old one; the encoder re-sends
                // the ones it means right after it. Keeping stale ones could hand VideoToolbox a PPS
                // that names a different SPS's geometry.
                for (int i = 0; i < MANIFOLD_HEVC_MAX_PPS_COUNT; i++) ab->pps[i].size = 0;
                ab->ppsPackedStale = true;
                MDHEVCCountHeldPPS(ab);
            }
            ab->stats.spsSize = ab->sps.size;
            return;
        }
        case MD_HEVC_PPS: {
            ab->stats.nalPPS++;
            const int id = MDHEVCReadPPSId(nal, size);
            if (id < 0) { ab->stats.ppsIdUnreadable++; return; }
            if (MDHEVCStore(&ab->pps[id], nal, size)) {
                ab->parameterSetsChanged = true;
                ab->ppsPackedStale = true;
                MDHEVCCountHeldPPS(ab);
            }
            return;
        }
        case MD_HEVC_AUD:
            ab->stats.nalAUD++;
            return;
        case MD_HEVC_FD:
            ab->stats.nalOther++;
            return;
        case MD_HEVC_EOS:
        case MD_HEVC_EOB:
            ab->stats.nalOther++;
            MDHEVCOpenIfNeeded(ab);
            MDHEVCAppendToAccessUnit(ab, nal, size);
            return;
        case MD_HEVC_SEI_PREFIX:
            // Read on the way past for HDR10 (Stage 5), then passed through unchanged like every SEI.
            // VideoToolbox drops MDCV and CLL anyway (§6.10, the audit).
            MDHEVCReadPrefixSEI(ab, nal, size);
            ab->stats.nalSEI++;
            MDHEVCOpenIfNeeded(ab);
            MDHEVCAppendToAccessUnit(ab, nal, size);
            return;
        case MD_HEVC_SEI_SUFFIX:
            // Passed through unchanged. 137 and 144 are prefix SEI (H.265 D.2.1), so it is not read.
            ab->stats.nalSEI++;
            MDHEVCOpenIfNeeded(ab);
            MDHEVCAppendToAccessUnit(ab, nal, size);
            return;
        default:
            break;
    }

    if (type >= 41) {   // reserved (41–47) and unspecified (48–63) non-VCL: ignored by any decoder
        ab->stats.nalDroppedReserved++;
        return;
    }

    // ── VCL, 0–31 ──────────────────────────────────────────────────────────────────────────
    if (type >= MD_HEVC_BLA_W_LP && type <= MD_HEVC_RSV_IRAP_23) {
        if (type <= MD_HEVC_BLA_N_LP)                          ab->stats.nalBLA++;
        else if (type <= MD_HEVC_IDR_N_LP)                     ab->stats.nalIDR++;
        else if (type == MD_HEVC_CRA)                          ab->stats.nalCRA++;
        else                                                   ab->stats.nalReservedIRAP++;
    } else if (type == MD_HEVC_RASL_N || type == MD_HEVC_RASL_R) {
        ab->stats.nalRASL++;
    } else if (type == MD_HEVC_RADL_N || type == MD_HEVC_RADL_R) {
        ab->stats.nalRADL++;
    } else {
        ab->stats.nalTrailing++;
    }

    MDHEVCOpenIfNeeded(ab);
    ab->accessUnitHasVCL = true;
    // Every slice of a picture has the same type (§7.4.2.2), so the first one decides; the first
    // random-access one is kept in case a non-conforming stream disagrees with itself.
    if (type >= MD_HEVC_BLA_W_LP && type <= MD_HEVC_RSV_IRAP_23 && !ab->accessUnitRandomAccessType) {
        ab->accessUnitRandomAccessType = type;
    }
    if (type == MD_HEVC_RASL_N || type == MD_HEVC_RASL_R) ab->accessUnitRASL = true;
    MDHEVCAppendToAccessUnit(ab, nal, size);
}

bool ManifoldHEVCAccessUnitBuilderCopyAccessUnitContents(const ManifoldHEVCAccessUnitBuilder *cab,
                                                         ManifoldHEVCAccessUnitContents *out) {
    if (!cab || !out) return false;
    // NO PICTURE, NO ACCESS UNIT. A packet of SEI alone is not something to decode.
    if (!cab->accessUnitActive || !cab->accessUnitHasVCL || cab->accessUnitOverflowed ||
        cab->accessUnit.size == 0) return false;

    // The packed PPS list is a cache of the table; refreshing it does not change what the builder
    // holds, so the accessor stays logically const.
    ManifoldHEVCAccessUnitBuilder *ab = (ManifoldHEVCAccessUnitBuilder *)cab;
    if (ab->ppsPackedStale) MDHEVCRepackPPS(ab);

    out->data                 = ab->accessUnit.data;
    out->size                 = ab->accessUnit.size;
    out->randomAccessType     = ab->accessUnitRandomAccessType;
    out->rasl                 = ab->accessUnitRASL;
    out->parameterSetsChanged = ab->parameterSetsChanged;
    out->vps                  = ab->vps.size ? ab->vps.bytes : NULL;
    out->vpsSize              = ab->vps.size;
    out->sps                  = ab->sps.size ? ab->sps.bytes : NULL;
    out->spsSize              = ab->sps.size;
    out->ppsList              = ab->ppsPackedCount ? ab->ppsPacked.data : NULL;
    out->ppsListSize          = ab->ppsPackedCount ? ab->ppsPacked.size : 0;
    out->ppsCount             = ab->ppsPackedCount;
    out->hdr10SEI             = (ab->hdr10.hasMDCV || ab->hdr10.hasCLL) ? &ab->hdr10 : NULL;
    return true;
}

void ManifoldHEVCAccessUnitBuilderFlush(ManifoldHEVCAccessUnitBuilder *ab) {
    if (!ab || !ab->accessUnitActive) return;
    if (ab->accessUnitOverflowed) {
        ab->stats.accessUnitsOversize++;
    } else if (ab->accessUnitHasVCL && ab->accessUnit.size) {
        ab->stats.accessUnits++;
        if (ab->accessUnitRandomAccessType) ab->stats.randomAccessUnits++;
        if (ab->accessUnitRASL) ab->stats.raslAccessUnits++;
        // Delivered: the decoder has now seen these parameter sets. NOT cleared on the discard
        // paths, for the reason H264AccessUnitBuilder.c gives at the same line.
        ab->parameterSetsChanged = false;
    }
    ab->accessUnit.size = 0;
    ab->accessUnitActive = false;
    ab->accessUnitHasVCL = false;
    ab->accessUnitOverflowed = false;
    ab->accessUnitRandomAccessType = 0;
    ab->accessUnitRASL = false;
}

void ManifoldHEVCAccessUnitBuilderCopyStats(const ManifoldHEVCAccessUnitBuilder *ab,
                                            ManifoldHEVCAccessUnitBuilderStats *outStats) {
    if (!outStats) return;
    if (!ab) { memset(outStats, 0, sizeof(*outStats)); return; }
    *outStats = ab->stats;
}

// ── The random-access gate ─────────────────────────────────────────────────────────────────

ManifoldHEVCGateVerdict ManifoldHEVCRandomAccessGateAdmit(ManifoldHEVCRandomAccessGate *gate,
                                                          uint8_t randomAccessType, bool rasl) {
    if (!gate) return ManifoldHEVCGateDecode;
    if (randomAccessType >= MD_HEVC_BLA_W_LP && randomAccessType <= MD_HEVC_RSV_IRAP_23) {
        const bool wasOpen = gate->open;
        gate->open = true;
        if (randomAccessType <= MD_HEVC_BLA_N_LP) {
            gate->skippingRASL = true;                 // BLA: its RASL are never decodable
        } else if (randomAccessType <= MD_HEVC_IDR_N_LP) {
            gate->skippingRASL = false;                // IDR: no RASL follow it
        } else {
            gate->skippingRASL = !wasOpen;             // CRA (or reserved IRAP): only when we start here
        }
        return ManifoldHEVCGateDecode;
    }
    if (!gate->open) return ManifoldHEVCGateDropAwaitingRandomAccess;
    if (rasl && gate->skippingRASL) return ManifoldHEVCGateDropRASL;
    return ManifoldHEVCGateDecode;
}

void ManifoldHEVCRandomAccessGateClose(ManifoldHEVCRandomAccessGate *gate) {
    if (!gate) return;
    gate->open = false;
    gate->skippingRASL = false;
}

const char *ManifoldHEVCRandomAccessName(uint8_t type) {
    if (type >= MD_HEVC_BLA_W_LP && type <= MD_HEVC_BLA_N_LP) return "BLA";
    if (type == MD_HEVC_IDR_W_RADL || type == MD_HEVC_IDR_N_LP) return "IDR";
    if (type == MD_HEVC_CRA) return "CRA";
    if (type > MD_HEVC_CRA && type <= MD_HEVC_RSV_IRAP_23) return "reserved IRAP";
    return "none";
}
