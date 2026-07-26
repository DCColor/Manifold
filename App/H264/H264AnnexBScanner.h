//
//  H264AnnexBScanner.h
//  Manifold
//
//  Annex-B byte run in, complete NAL units out. The other front end for
//  H264AccessUnitBuilder: where the WHEP depacketizer reassembles NALs from RTP
//  packets, this one splits them out of the byte-stream format that every
//  container and file hands you.
//
//  ── WHY THIS IS A PURE FUNCTION ────────────────────────────────────────────
//
//  It holds NO state between calls, and that is a property of H.264 rather than
//  a design preference. Emulation prevention guarantees that the three-byte
//  sequence 00 00 01 cannot occur inside a NAL payload — the encoder is required
//  to break it up by inserting a 0x03 — so a start code is unambiguous wherever
//  it is found. There is nothing to remember and nothing to resynchronise: hand
//  it any byte run and it tells you the truth about that run. It follows that
//  this scanner MUST NOT be given a bitstream whose emulation prevention has
//  already been undone, and that nothing upstream may strip it.
//
//  It also means a NAL cannot be split across two calls. That is fine for the
//  SRT path, where libavformat has already reassembled a complete access unit
//  before handing it over, but it is NOT a general Annex-B stream parser: a
//  caller with arbitrary byte-run boundaries would have to buffer first.
//
//  H.264 ONLY. The scan itself is codec-neutral — start codes work the same way
//  in HEVC — but everything downstream of it is not: HEVC has a TWO-byte NAL
//  header with the type in bits 1–6 of the first byte, adds VPS (32) alongside
//  SPS/PPS at 33/34, and splits IDR across types 19 and 20. Pointing this at an
//  HEVC stream would produce correctly-delimited NALs that the builder then
//  classifies as nonsense. See the HEVC note in H264AccessUnitBuilder.h.
//
//  PURE C, NO DEPENDENCIES — no libavformat, no libsrt, no Foundation.
//

#ifndef MANIFOLD_H264_ANNEXB_SCANNER_H
#define MANIFOLD_H264_ANNEXB_SCANNER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One complete NAL unit: header byte first, NO start code, NO trailing zero
/// bytes, emulation prevention still present. Exactly what
/// ManifoldH264AccessUnitBuilderAppendNAL wants.
typedef void (*ManifoldH264NALHandler)(const uint8_t *nal, size_t size, void *context);

/// What a scan found. Returned by value; every field is per-call, not cumulative.
typedef struct {
    size_t nalCount;              ///< NAL units handed to the callback.
    size_t bytesBeforeFirstStartCode; ///< Leading bytes discarded: a mid-stream join, or junk.
    size_t emptyNALs;             ///< Start codes with nothing between them. Malformed, but survivable.
    bool   foundStartCode;        ///< False means the run contained no start code at all.
} ManifoldH264AnnexBScanResult;

/// Splits an Annex-B byte run into NAL units, calling `handler` once per NAL in
/// stream order. Never allocates, never logs, and never retains `data`.
///
/// Tolerates, because real streams contain all of it: 3-byte (00 00 01) and
/// 4-byte (00 00 00 01) start codes mixed freely, leading bytes before the first
/// start code, trailing zero padding, empty runs, and runs that are start codes
/// and nothing else. A NULL handler is legal — the result counts are still valid,
/// which makes a dry-run scan possible.
ManifoldH264AnnexBScanResult ManifoldH264AnnexBScan(const uint8_t *data, size_t size,
                                                    ManifoldH264NALHandler handler,
                                                    void *context);

#ifdef __cplusplus
}
#endif

#endif /* MANIFOLD_H264_ANNEXB_SCANNER_H */
