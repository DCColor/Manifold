//
//  SRTAccessUnitReader.h
//  Manifold
//
//  One demuxed video packet in, one access unit out. The SRT path's equivalent of
//  ManifoldH264Depacketizer: it owns the transport-shaped part, and delegates
//  every codec decision to a builder — H264AccessUnitBuilder, or HEVCAccessUnitBuilder for HEVC
//  (§6.10, Stage 3). The Annex-B scan is the same for both: start codes are codec-neutral.
//
//      libsrt → AVIOContext → mpegts demux → AVPacket → THIS → decoder
//
//  ── ONE PACKET IS ONE ACCESS UNIT ──────────────────────────────────────────
//
//  This is the single biggest structural difference from the RTP front end, and
//  it is what makes this file so much smaller than H264Depacketizer.c.
//  libavformat's mpegts demuxer has ALREADY done the framing — it assembles PES
//  packets and emits one AVPacket per access unit — so the access-unit boundary
//  arrives as a fact rather than something to infer. There is no marker bit to
//  watch, no timestamp-change safety net for a lost one, no sequence accounting,
//  and no fragment reassembly. Submit a packet, and the AU is closed at the end
//  of it. Every one of those mechanisms stays in the RTP front end where the
//  boundary genuinely has to be discovered.
//
//  ── WHY IT HAS ITS OWN ACCESS-UNIT TYPE ────────────────────────────────────
//
//  Because a demuxed stream carries timing RTP does not have: a 64-bit PTS the
//  demuxer has already unwrapped from MPEG-TS's 33-bit field, and a separate DTS
//  that is REQUIRED to get display order right on a stream with B-frames.
//  ManifoldH264AccessUnit's uint32 rtpTimestamp cannot express either, and
//  widening it would have put a permanently-invalid DTS and a misleadingly wide
//  PTS on the WHEP path — see the long note at that field. So the two transports
//  share the BUILDER, not the struct: this file reads the finished AU back with
//  ManifoldH264AccessUnitBuilderCopyAccessUnitContents and dispatches its own.
//
//  PURE C, NO DEPENDENCIES. This header pulls in NEITHER <srt/*> NOR <libav*/*>,
//  the same discipline DataChannelBridge.h / NDIBridge.h / SRTSession.h follow, and
//  neither does the implementation: timestamps arrive as plain int64_t, so the
//  caller does the one-line AVPacket unpacking (ManifoldSRTSession does it, in
//  SRTSession.m). Shipping code, with no libsrt or libav symbol in it.
//
//  THREADING. NOT thread-safe. One reader per stream, owned by the demux thread.
//

#ifndef MANIFOLD_SRT_ACCESS_UNIT_READER_H
#define MANIFOLD_SRT_ACCESS_UNIT_READER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "H264AccessUnitBuilder.h"
#include "HEVCAccessUnitBuilder.h"

#ifdef __cplusplus
extern "C" {
#endif

/// "No timestamp" — bit-identical to libavformat's AV_NOPTS_VALUE (INT64_MIN),
/// restated here so this header needs no libav include. The test harness asserts
/// the two are equal against the real <libavutil/avutil.h>.
#define MANIFOLD_SRT_NO_TIMESTAMP  INT64_MIN

/// Which builder a reader feeds. A plain int32_t with an anonymous enum, for the import reason
/// ManifoldSRTEndReason gives in SRTSession.h. Chosen once, at creation, from the demuxer's codec id:
/// a stream does not change codec mid-session.
typedef int32_t ManifoldSRTVideoCodec;
enum {
    ManifoldSRTVideoCodecUnsupported = -1,   ///< Neither; the gate refuses it. Never handed to a reader.
    ManifoldSRTVideoCodecH264 = 0,
    ManifoldSRTVideoCodecHEVC = 1,
};

/// One access unit from a demuxed stream.
typedef struct {
    ManifoldSRTVideoCodec codec;
    const uint8_t *data;            ///< AVCC bytes. Valid ONLY for the duration of the callback.
    size_t         size;

    /// Presentation and decode timestamps in AVStream.time_base — which for
    /// MPEG-TS is 1/90000, natively and always. DELIBERATELY NOT RESCALED: the
    /// WHEP path already lands on 90 kHz because RTP's H.264 payload format
    /// fixes the clock there, so both transports reach the decoder in the same
    /// units and CMTime(value:timescale: 90_000) is exact on either. Rescaling
    /// would introduce rounding for no gain.
    ///
    /// `dts` may be MANIFOLD_SRT_NO_TIMESTAMP; the decoder maps that to
    /// CMTime.invalid, which CoreMedia reads as "decode order == presentation
    /// order". `pts` may be too — see `accessUnitsWithoutPTS` for what that
    /// means and why this file emits such an AU rather than swallowing it.
    int64_t        pts;
    int64_t        dts;

    /// Where decoding may start. H.264: an IDR slice, NAL type 5 — never AV_PKT_FLAG_KEY. HEVC: any
    /// random-access picture, NAL types 16–23 (decision 5); `randomAccessType` says which.
    bool           keyframe;
    bool           parameterSetsChanged;   ///< Any parameter set below differs from the last AU's.
    const uint8_t *sps;
    size_t         spsSize;
    /// H.264: the PPS. HEVC: NULL — an HEVC stream may carry several, in `ppsList`.
    const uint8_t *pps;
    size_t         ppsSize;

    // ── HEVC only; zero / NULL on H.264 ────────────────────────────────────────────────────
    const uint8_t *vps;
    size_t         vpsSize;
    /// Every held PPS in id order, each with a 4-byte big-endian length in front; `ppsCount` of them.
    const uint8_t *ppsList;
    size_t         ppsListSize;
    uint32_t       ppsCount;
    uint8_t        randomAccessType;   ///< The IRAP picture's nal_unit_type, 16–23; 0 when none.
    bool           rasl;               ///< A RASL picture (8, 9). See ManifoldHEVCRandomAccessGate.
} ManifoldSRTAccessUnit;

/// Fires inline on the submitting thread, once per access unit. Copy what you keep.
typedef void (*ManifoldSRTAccessUnitHandler)(const ManifoldSRTAccessUnit *accessUnit, void *context);

typedef struct ManifoldSRTAccessUnitReader ManifoldSRTAccessUnitReader;

/// Counters for the reader's own diagnostics. The H.264-layer counts (NAL types,
/// oversize AUs, parameter-set sizes) come from
/// ManifoldSRTAccessUnitReaderCopyBuilderStats instead — same split as WHEP.
typedef struct {
    uint64_t packetsReceived;          ///< Everything handed to Submit.
    uint64_t packetsEmpty;             ///< Zero-length or NULL payloads.
    uint64_t packetsWithoutStartCode;  ///< Not Annex-B: AVCC extradata mode, or corruption.
    uint64_t packetsWithoutAccessUnit; ///< Scanned fine but produced no VCL NAL (parameter sets only).
    uint64_t nalsScanned;
    uint64_t emptyNALsScanned;         ///< Back-to-back start codes.
    uint64_t leadingGarbageBytes;      ///< Bytes discarded before a first start code.

    uint64_t accessUnits;              ///< Emitted to the handler.
    uint64_t keyframes;
    uint64_t accessUnitsPTSFromDTS;    ///< PTS was absent and DTS stood in for it.
    uint64_t accessUnitsWithoutDTS;    ///< Emitted with dts == MANIFOLD_SRT_NO_TIMESTAMP.
    uint64_t accessUnitsWithoutPTS;    ///< Emitted with NO usable presentation time at all.
} ManifoldSRTAccessUnitReaderStats;

/// The codec picks the builder: H.264's, or HEVC's. Anything else the gate refuses, and gets H.264's
/// builder as it always did, which reads nothing from it.
ManifoldSRTAccessUnitReader *ManifoldSRTAccessUnitReaderCreate(ManifoldSRTVideoCodec codec);
void ManifoldSRTAccessUnitReaderDestroy(ManifoldSRTAccessUnitReader *reader);

void ManifoldSRTAccessUnitReaderSetHandler(ManifoldSRTAccessUnitReader *reader,
                                           ManifoldSRTAccessUnitHandler handler,
                                           void *context);

/// Feeds ONE demuxed packet: the Annex-B payload (`pkt->data`, `pkt->size`) and
/// its timestamps (`pkt->pts`, `pkt->dts`, either possibly AV_NOPTS_VALUE),
/// verbatim and unrescaled. Emits at most one access unit, before returning.
///
/// The caller is expected to have filtered to the video stream already; this
/// function has no idea what a stream index is.
void ManifoldSRTAccessUnitReaderSubmitPacket(ManifoldSRTAccessUnitReader *reader,
                                             const uint8_t *annexB, size_t size,
                                             int64_t pts, int64_t dts);

void ManifoldSRTAccessUnitReaderCopyStats(const ManifoldSRTAccessUnitReader *reader,
                                          ManifoldSRTAccessUnitReaderStats *outStats);

/// The shared H.264 layer's counters — NAL types, oversize AUs, parameter-set sizes. Zeroed on an
/// HEVC reader.
void ManifoldSRTAccessUnitReaderCopyBuilderStats(const ManifoldSRTAccessUnitReader *reader,
                                                 ManifoldH264AccessUnitBuilderStats *outStats);

/// The HEVC layer's counters. Zeroed on an H.264 reader.
void ManifoldSRTAccessUnitReaderCopyHEVCBuilderStats(const ManifoldSRTAccessUnitReader *reader,
                                                     ManifoldHEVCAccessUnitBuilderStats *outStats);

#ifdef __cplusplus
}
#endif

#endif /* MANIFOLD_SRT_ACCESS_UNIT_READER_H */
