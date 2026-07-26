//
//  SRTAccessUnitReader.c
//  Manifold
//
//  See SRTAccessUnitReader.h for the contract. The short version: scan, append,
//  read back, dispatch, flush — and let the shared builder make every decision
//  that is about H.264 rather than about the transport.
//

#include "SRTAccessUnitReader.h"

#include "H264AnnexBScanner.h"

#include <stdlib.h>
#include <string.h>

struct ManifoldSRTAccessUnitReader {
    ManifoldH264AccessUnitBuilder *builder;
    ManifoldSRTAccessUnitHandler   handler;
    void                          *handlerContext;
    ManifoldSRTAccessUnitReaderStats stats;
};

/// The scanner's per-NAL callback. Everything interesting — type classification,
/// SPS/PPS diversion, AUD and filler dropping, IDR → keyframe, the 4-byte length
/// prefix — happens inside AppendNAL, identically to the WHEP path.
///
/// The builder's `timestamp` argument is passed 0 and never read back. It exists
/// so the RTP front end can stamp an access unit at the moment a NAL opens it,
/// which is how RTP discovers a boundary it cannot see directly. Here the
/// boundary is the packet, so the real pts/dts stay in this file and go onto the
/// AU at dispatch — see the one-packet-is-one-access-unit note in the header.
static void MDAppendScannedNAL(const uint8_t *nal, size_t size, void *context) {
    ManifoldSRTAccessUnitReader *reader = (ManifoldSRTAccessUnitReader *)context;
    ManifoldH264AccessUnitBuilderAppendNAL(reader->builder, nal, size, 0);
}

ManifoldSRTAccessUnitReader *ManifoldSRTAccessUnitReaderCreate(void) {
    ManifoldSRTAccessUnitReader *reader = calloc(1, sizeof(*reader));
    if (!reader) return NULL;
    reader->builder = ManifoldH264AccessUnitBuilderCreate();
    if (!reader->builder) { free(reader); return NULL; }
    return reader;
}

void ManifoldSRTAccessUnitReaderDestroy(ManifoldSRTAccessUnitReader *reader) {
    if (!reader) return;
    ManifoldH264AccessUnitBuilderDestroy(reader->builder);
    free(reader);
}

void ManifoldSRTAccessUnitReaderSetHandler(ManifoldSRTAccessUnitReader *reader,
                                           ManifoldSRTAccessUnitHandler handler,
                                           void *context) {
    if (!reader) return;
    reader->handler        = handler;
    reader->handlerContext = context;
}

void ManifoldSRTAccessUnitReaderSubmitPacket(ManifoldSRTAccessUnitReader *reader,
                                             const uint8_t *annexB, size_t size,
                                             int64_t pts, int64_t dts) {
    if (!reader) return;

    reader->stats.packetsReceived++;
    if (!annexB || size == 0) { reader->stats.packetsEmpty++; return; }

    const ManifoldH264AnnexBScanResult scan =
        ManifoldH264AnnexBScan(annexB, size, MDAppendScannedNAL, reader);

    reader->stats.nalsScanned         += scan.nalCount;
    reader->stats.emptyNALsScanned    += scan.emptyNALs;
    reader->stats.leadingGarbageBytes += scan.bytesBeforeFirstStartCode;
    if (!scan.foundStartCode) {
        // No start code at all. The likeliest cause is not corruption but a
        // stream libavformat handed over in AVCC (length-prefixed) form, which
        // this scanner cannot read and which would need the extradata path
        // instead. Counted loudly rather than silently producing nothing.
        reader->stats.packetsWithoutStartCode++;
        return;
    }

    // ── The access unit is closed HERE, at the packet boundary ───────────────
    // Not on a marker bit, not on a timestamp change. See the header.
    ManifoldH264AccessUnitContents contents;
    if (!ManifoldH264AccessUnitBuilderCopyAccessUnitContents(reader->builder, &contents)) {
        // The packet held no VCL NAL: parameter sets only, or an AUD-and-filler
        // packet. Both are normal — the parameter sets have been absorbed into
        // the builder, and because Flush is a no-op when no AU ever opened, the
        // sticky parameterSetsChanged flag survives to ride out with the next
        // real frame instead of being lost here.
        //
        // An access unit that blew MD_MAX_ACCESS_UNIT_BYTES also lands in this
        // branch. The two are told apart by the builder's accessUnitsOversize,
        // which the Flush below is what increments. That 8 MB ceiling was sized
        // against WHEP, where congestion control keeps frames small; a
        // high-bitrate contribution feed — all-intra, 10-bit 4:2:2 — can put a
        // single access unit into the megabytes legitimately, so treat a
        // non-zero accessUnitsOversize on this path as a cap to raise rather
        // than as corruption.
        reader->stats.packetsWithoutAccessUnit++;
        ManifoldH264AccessUnitBuilderFlush(reader->builder);
        return;
    }

    // ── AV_NOPTS_VALUE POLICY ────────────────────────────────────────────────
    //
    // PTS ABSENT, DTS PRESENT → DTS stands in for PTS. MPEG-TS PES cannot carry
    // a DTS without a PTS (PTS_DTS_flags '01' is forbidden), so this only arises
    // from libavformat's own bookkeeping, and when it does the honest reading is
    // that nothing has declared any reordering — which is exactly PTS == DTS. A
    // frame with a usable time is worth far more than a dropped one.
    //
    // DTS ABSENT, PTS PRESENT → propagated as absent, NOT synthesised. The
    // decoder turns it into CMTime.invalid and CoreMedia reads that as "decode
    // order == presentation order" — the same assertion WHEP makes on every
    // frame. Writing pts into dts would say the same thing less honestly.
    //
    // BOTH ABSENT → emitted anyway, with both absent, and counted. This file
    // will not invent a timeline; but it will not silently swallow a decodable
    // picture either. The caller decides, and Stage 3d must: an AU with no PTS
    // cannot be scheduled against LiveClock, so it should be dropped there — or
    // held until a timed frame arrives — with the count above as the evidence.
    int64_t effectivePTS = pts;
    if (effectivePTS == MANIFOLD_SRT_NO_TIMESTAMP && dts != MANIFOLD_SRT_NO_TIMESTAMP) {
        effectivePTS = dts;
        reader->stats.accessUnitsPTSFromDTS++;
    }
    if (dts == MANIFOLD_SRT_NO_TIMESTAMP)          reader->stats.accessUnitsWithoutDTS++;
    if (effectivePTS == MANIFOLD_SRT_NO_TIMESTAMP) reader->stats.accessUnitsWithoutPTS++;

    reader->stats.accessUnits++;
    if (contents.keyframe) reader->stats.keyframes++;

    if (reader->handler) {
        ManifoldSRTAccessUnit accessUnit = {
            .data                 = contents.data,
            .size                 = contents.size,
            .pts                  = effectivePTS,
            .dts                  = dts,
            .keyframe             = contents.keyframe,
            .parameterSetsChanged = contents.parameterSetsChanged,
            .sps                  = contents.sps,
            .spsSize              = contents.spsSize,
            .pps                  = contents.pps,
            .ppsSize              = contents.ppsSize,
        };
        reader->handler(&accessUnit, reader->handlerContext);
    }

    // Flush AFTER dispatch: it advances the builder's own counters and resets the
    // buffer the contents above point into.
    ManifoldH264AccessUnitBuilderFlush(reader->builder);
}

void ManifoldSRTAccessUnitReaderCopyStats(const ManifoldSRTAccessUnitReader *reader,
                                          ManifoldSRTAccessUnitReaderStats *outStats) {
    if (!outStats) return;
    if (!reader) { memset(outStats, 0, sizeof(*outStats)); return; }
    *outStats = reader->stats;
}

void ManifoldSRTAccessUnitReaderCopyBuilderStats(const ManifoldSRTAccessUnitReader *reader,
                                                 ManifoldH264AccessUnitBuilderStats *outStats) {
    if (!outStats) return;
    ManifoldH264AccessUnitBuilderCopyStats(reader ? reader->builder : NULL, outStats);
}
