# Chroma fixtures and probes

For HEVC Stage 3b, **"4:2:2 end to end"**, and the native-chroma rule in `CLAUDE.md`. The audit,
decisions, stages and predictions are in `docs/COLOR_MANAGEMENT_FINDINGS.md` §6.10, *Stage 3b — 4:2:2
(and 4:4:4) end to end: audit*. No media is committed.

| File | What |
|---|---|
| `generate.sh` | Makes the fixtures into `build/chroma-fixtures/` (gitignored; ~2.8 GB, ~50 s on an M4 Max, plus ~8 GB and ~2 min for `s2`). Groups `422 444 420 4k ndi s2 s3`. |
| `vt.swift` | Raw `VTDecompressionSession` probe: hardware-only and software-only decode, native and requested pixel formats. **Run this on any Mac whose 4:2:2 / 4:4:4 decode is in question** (the M4 MacBook Air check). |
| `avf-formats.swift` | `AVAssetReader` probe: which of `x420 x422 x444 sv22 sv44` each file delivers, its cost, and whether the chroma pattern survives. |
| `measure.swift` | S2's numbers from one ⌃⌥E dump: the readback as 10-bit Y′CbCr (the dump's own kr/kb, limited range) and the v210 words, against `lines` (P3: rows within ±2 of their own line) or `checker` (P4 on the export, P5 512 ± tol on the wire). |
| `bands.py` | The 8-bit ×4 check (§6.10, *8-bit sources mapped exactly ×4*): `bands8` / `bands10` band means from one ⌃⌥E dump (export) and the v210 wire's min..max; with a second (control) stem, the fraction of `.rgba16f` pixels identical to it. `python3 -I bands.py <stem> [control-stem]` |
| `ndibars.py` | The same check on NDI's `p2-bars`: every flat bar's export and wire codes should be whole multiples of 4 (an 8-bit source mapped exactly ×4). `python3 -I ndibars.py <stem>` |
| `v210ref.swift` | Re-runs a revision's `rgbToV210` on the GPU against a DEBUG v210 dump's readback (⌃⌥E in a Profile build writes `.v210`, `.rgba16f`, `.v210.json` beside the PNG) and compares. How P1 checks that the 4:2:0 wire did not change. |

## The patterns

- **lines-422**: 1-pixel-high colour lines (Cb/Cr 724/300 on even rows, 300/724 on odd rows), flat luma.
  The vertical halving shows directly: averaged to `x420` every row is grey (512/512); point-sampled
  (Apple's ProRes decoder) every row takes the even row's colour.
- **checker-444**: a 1-pixel colour checker. Only 4:4:4 keeps it. On the DeckLink v210 output (4:2:2,
  because Manifold's DeckLink output uses v210, not because SDI is limited to it) the correct result is
  512 ± 2, the D3 halfband's DC. 724/300 on the wire means an aliased reduction.
- **still-420**: static `yuvtestsrc`, H.264 8-bit and HEVC Main 10. The 4:2:0 regression set (P1). Static,
  so any frame of a live stream is the same picture.
- **ndi**: `p2-bars.png`, 75 % RGB bars 240 px wide, for an OBS Image source sent over NDI (S1's P2).
- **4k**: 4K ProRes 422 HQ and HEVC 4:2:2 for cost; `4k-422-hevc-intra-overcap.ts` is ~16 MB a frame, over
  the 8 MB access-unit cap on purpose.
- **s2**: 62 s 4K DNxHR HQX MXF and 4K ProRes 4444 `.mov` (S2's P8: memory and 60 s of play), and an
  MPEG-4 Part 2 `.mov`, a codec with no chroma table (D8: carried 4:2:0, "source chroma unknown").
- **s3**: SRT at native chroma (S3/S4). `lines-422-h264-8bit.ts` (x264 High 4:2:2 8-bit; the lines' codes
  are 8-bit ×4, so they survive exactly) and `still-420-hevc10-intra.ts` (x265 `keyint=1`, which signals
  "Main 10 Intra", a Range Extensions profile, at 4:2:0 10-bit: Stage 3's gate refused it).
  The `.ts` fixtures of `422` and `444` (`lines-422-h264.ts`, `lines-422-hevc.ts`, `checker-444-h264.ts`,
  `checker-444-hevc.ts`) are the S3/S4 stream set; each has one keyframe in 10 s, so a reader that joins
  mid-stream (MediaMTX) needs a short-GOP twin (`-g 25` / `keyint=25`, same pattern and quantiser).

## The S2 instruments (in the app, DEBUG; pre-ship list in `docs/BUGS.md`)

- **Debug ▸ Chroma Scrub Bench** (⌃⌥⇧B; launch with `MANIFOLD_DEBUG_MENU=1 MANIFOLD_SCRUB_STATS=1`): on a
  paused file, exports the playback frame, scrubs 60 positions at 20 Hz, scrubs back and exports the
  scrub frame, then prints `[SCRUB]`. P6 compares the two exports' `.rgba16f`; P7 reads `[SCRUB]`.
- **`MANIFOLD_PLAYBACK_STATS=1`**: `[PLAYBACK-STATS] presented= dropped= late=` once a second of play.

## The S3 instruments (DEBUG launch environment, never `defaults`; pre-ship list in `docs/BUGS.md`)

- **`MANIFOLD_FORCE_CHROMA_420=1`** on SRT: the decoder requests `x420` for a 4:2:2 / 4:4:4 stream, so the
  router's "carried less than declared" path runs: `[CHROMA] 4:2:0 10-bit (x420) — 4:2:2 source, forced …`,
  `[SRT] CHROMA FALLBACK — …` with the banner's words, and the stream stays connected (P10).
- **`MANIFOLD_FORCE_SOFTWARE_DECODE=1`**: every live decode session is built with the hardware decoder
  disabled. HEVC 4:2:2 then decodes in software (`hardware decode: no`, `· software decode` on the Chroma
  line); H.264 4:2:2 / 4:4:4 has no software decoder, so it is refused with a banner (P10b).

## Running

```sh
zsh scripts/chroma/generate.sh                 # everything
zsh scripts/chroma/generate.sh 422 444         # some groups
swiftc -O -o /tmp/vt scripts/chroma/vt.swift
/tmp/vt build/chroma-fixtures/lines-422-hevc.mov build/chroma-fixtures/lines-422-h264-intra.mov \
        build/chroma-fixtures/checker-444-hevc.mov
```

## Traps

- **Apple's DNx plug-in misdecodes ffmpeg-made DNxHR HQX `.mov`** (774/250 where libav and the source
  are 724/300). Manifold sends DNx 4:2:2 to libav, so this is not user-visible. Do not use ffmpeg-made
  DNx to judge the plug-in.
- **A probe outside the app must call `VTRegisterProfessionalVideoWorkflowVideoDecoders()`** or DNx in
  `.mov` fails with −12906 ("decoder not found"). `avf-formats.swift` does; `vt.swift` does not need to,
  since it only takes H.264 and HEVC.
- **zsh does not word-split** a variable holding ffmpeg options. `generate.sh` uses arrays.
- **The "own pattern" count in `avf-formats.swift`** is only meaningful at the source's own chroma
  resolution. Read the printed sample values too.
