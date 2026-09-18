//
//  H264SPSTiming.h
//  Manifold
//
//  SPS → the EXACT frame rate the encoder declared, when it declared one.
//
//  ── WHY THIS EXISTS, AND WHY IT IS A SEPARATE FILE ─────────────────────────────────────
//
//  `H264AccessUnitBuilder` STORES the SPS (`ab->sps` / `ab->spsSize`) and hands it on to
//  `CMVideoFormatDescriptionCreateFromH264ParameterSets` without ever looking inside it. Nothing
//  in this codebase parses an H.264 bitstream — there was no exp-Golomb reader, no RBSP
//  unescaper, nothing. So this could not extend existing SPS handling; it had to bring its own.
//
//  It lives in App/H264 rather than in the WHEP transport because it is a property of H.264, not
//  of WebRTC. SRT reaches the same decoder with the same parameter sets and would want the same
//  answer; it simply does not need it today, because libavformat already tells it.
//
//  ── WHAT IT DOES NOT DO ────────────────────────────────────────────────────────────────
//
//  It answers ONE question and stops: what does `vui_parameters.timing_info` say. It is not a
//  general SPS parser and must not grow into one by accretion. Everything before the VUI is
//  SKIPPED, not interpreted — the skips exist only to reach the timing fields.
//
//  ⚠️ SAR / `aspect_ratio_idc` IS IN THIS SAME VUI, AND IS DELIBERATELY NOT READ HERE.
//  docs/BUGS.md records WHEP's square-pixel assumption as unfixable "because nothing parses the
//  VUI". That is no longer true — the parser reaches `aspect_ratio_info_present_flag` on its way
//  to the timing fields and steps over it at a named point (see `MDSkipAspectRatio` in the .c).
//  Wiring SAR through to `LiveDisplaySize` / the aspect handling is a SEPARATE change with its own
//  measurement, and is NOT part of this one. Do not add it here without doing that work.
//

#ifndef MANIFOLD_H264_SPS_TIMING_H
#define MANIFOLD_H264_SPS_TIMING_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// What the SPS says about cadence. `valid` is the only field worth testing first.
typedef struct {
    /// True only when the SPS carried a VUI, that VUI carried timing_info, and both fields were
    /// non-zero. Anything else is `false` and the caller must fall through to measurement —
    /// VUI is OPTIONAL in H.264 and `timing_info_present_flag` is very often 0.
    bool     valid;

    /// fps = time_scale / (2 * num_units_in_tick). Meaningful only when `valid`.
    double   framesPerSecond;

    /// The raw pair, carried so a log can state the encoder's own numbers rather than only the
    /// quotient — 24000/1001 and 23.976 are the same rate but not the same evidence.
    uint32_t numUnitsInTick;
    uint32_t timeScale;

    /// The encoder's claim that the cadence is CONSTANT. Not required for `valid` — a great many
    /// encoders emit correct timing with this flag clear — but the caller may treat a set flag as
    /// grounds for more confidence, and a clear one as grounds for none.
    bool     fixedFrameRate;
} ManifoldH264SPSTiming;

/// Parse `sps` (one SPS NAL, WITHOUT any start code or AVCC length prefix, INCLUDING its 1-byte
/// NAL header) and report its timing info.
///
/// Never fails loudly: a truncated, malformed or VUI-less SPS returns `.valid == false`. A
/// reference tool must not invent a cadence, and a parse error is indistinguishable from an
/// absent VUI as far as the caller's next move is concerned.
ManifoldH264SPSTiming ManifoldH264ParseSPSTiming(const uint8_t *sps, size_t spsSize);

#ifdef __cplusplus
}
#endif

#endif /* MANIFOLD_H264_SPS_TIMING_H */
