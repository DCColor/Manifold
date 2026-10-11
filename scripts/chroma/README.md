# Chroma fixtures and probes

For HEVC Stage 3b, **"4:2:2 end to end"**, and the native-chroma rule in `CLAUDE.md`. The audit,
decisions, stages and predictions are in `docs/COLOR_MANAGEMENT_FINDINGS.md` §6.10, *Stage 3b — 4:2:2
(and 4:4:4) end to end: audit*. No media is committed.

| File | What |
|---|---|
| `generate.sh` | Makes the fixtures into `build/chroma-fixtures/` (gitignored; ~2.8 GB, ~50 s on an M4 Max). Groups `422 444 420 4k ndi`. |
| `vt.swift` | Raw `VTDecompressionSession` probe: hardware-only and software-only decode, native and requested pixel formats. **Run this on any Mac whose 4:2:2 / 4:4:4 decode is in question** (the M4 MacBook Air check). |
| `avf-formats.swift` | `AVAssetReader` probe: which of `x420 x422 x444 sv22 sv44` each file delivers, its cost, and whether the chroma pattern survives. |
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
