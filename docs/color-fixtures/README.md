# Colour fixtures and the Experiment 3 harness

Everything needed to measure what transfer function a `CAMetalLayer` destination actually
applies, on any Mac. Moved here out of a session scratchpad, which does not survive.

The question these answer, and how to read the result, is in
[`../AIR-COLOUR-TEST.md`](../AIR-COLOUR-TEST.md). This file is the mechanics.

## Requirements

- A **Debug or Profile** build of Manifold. The Experiment 3 scaffold is inside `#if DEBUG`; a
  Release build compiles it out, the layer destination never changes, and all three captures
  come back identical — which looks like a finding and is not one. `sweep.sh` checks the binary
  and refuses to run on Release.
- Xcode command-line tools (`swiftc`) — two helpers are compiled on first run.
- `ffmpeg` only if you want to regenerate `wedge.mov`; it is committed, so normally not needed.

## Run it

```bash
docs/color-fixtures/sweep.sh ~/wedge-run          # capture all three destinations
python3 docs/color-fixtures/parse_icc.py ~/wedge-run/raw_0.icc    # what IS this display?
python3 docs/color-fixtures/analyze2.py ~/wedge-run               # fit the hypotheses
```

The Manifold window **must be exactly 1920×1080** so the capture is 1:1 with the fixture.
`sweep.sh` warns if it is not; a rescaled capture still produces plausible-looking numbers, so
do not ignore that warning.

## The pipeline

| Step | File | What it does |
|---|---|---|
| 1 | `make_wedge.py` | Generates `wedge.mov` + `wedge.mov.patches.json` — 48 flat grey patches, 32 of them below code 0.25, because the region of interest is the toe. Both are committed; regenerate only if the patch set changes. |
| 2 | `sweep.sh` | For destination 0/1/2: writes `/tmp/manifold_debug_cs`, launches the app on the wedge, finds the window, `screencapture`s it, extracts raw samples. |
| 3 | `getwin.swift` | Window id + bounds of the largest on-screen Manifold window. Compiled by `sweep.sh`. |
| 4 | `extract.swift` | PNG → `raw_N.raw` (straight from the data provider) + `raw_N.icc` (the display profile the capture was tagged with). Compiled by `sweep.sh`. |
| 5 | `parse_icc.py` | Full characterisation of any ICC's TRC — `para` vs `curv`, the gamma, and a fit against candidate transfer functions. |
| 6 | `analyze2.py` | Decodes each capture through the display's own TRC and fits the layer's decode curve against the candidates. |

## Two things that will silently give you a wrong answer

**Decoding the capture through CoreGraphics.** Experiment 1 established that the CG conversion
path introduces a 1/16 linear toe for pure-power TRCs. Decode a capture through that path and
you manufacture the very artefact the test is looking for. `extract.swift` therefore pulls bytes
straight from the PNG's data provider and dumps the profile for independent numeric evaluation;
`analyze2.py` does the arithmetic itself. Do not "simplify" either by using `NSImage` or
`CGColorSpace` conversion.

**Assuming the display's gamma.** `analyze2.py` used to hardcode `DISPLAY_GAMMA = 1.960999` —
the Studio's LG TV SSCR2 profile. That is a property of one monitor. Run unchanged elsewhere it
inverts with the wrong exponent and every candidate fit shifts together, so nothing looks
broken. It now reads the TRC out of `raw_0.icc` and prints what it found before using it.
`--display-gamma G` forces a power law if you need to override.

## The `/tmp/manifold_debug_cs` mechanism

`MetalVideoRenderer` reads that file **once**, when the renderer is constructed, and seeds
`debugDestination` from it — `0` = source-derived (today), `1` = `kCGColorSpaceITUR_709`,
`2` = synthesised `para` type-0 γ2.4. So the file is written *before* launch and the app is
relaunched per destination, which is what lets the sweep run with no keystroke injection and no
Accessibility permission.

⚠️ **This is independent of the ⌃⌥D shortcut**, which is contested — `ContentView` binds it
twice, to destination cycling and to the SRT debug connect, and which one wins is undefined. The
file path is unaffected, and that is why the harness uses it rather than the key.

## Reference profiles

`709-CoreMedia709.icc`, `P3-AppleP3.icc`, `PQ-ITUR2100PQ.icc`, `HLG-ITUR2100HLG.icc` were dumped
from `CVImageBufferCreateColorSpaceFromAttachments` by `dump_colorspaces.swift`. They are what
the app's own layer-colorspace derivation produces for each source tagging, kept so a change in
that derivation shows up as a diff against a known-good profile rather than as a subtle
on-screen difference nobody notices.

## Seamless chart streams (SRT, WHEP, HLS)

```bash
bash docs/color-fixtures/make_stream_fixtures.sh          # → build/stream-fixtures/ (gitignored)
```

The S0 6 × 3 chart (`make_patches.py`, greys and 100 % / 50 % R G B C M Y) as 1280 × 720 H.264 in three colour
variants: `919` (SPS VUI 9/1/9), `undecl` (the same slices with the colour description set to unspecified) and
`666` (6/6/6, encoded through the 601 matrix). Each comes as `chart_V_aac.ts` (SRT, HLS), `chart_V_opus.ts`
(publishing into MediaMTX for WHEP) and `hls_chart_V/` (10-loop VOD).

**They loop without a seam.** The loop is 8.000 s: whole frames on every stream (200 video, 375 AAC, 400
Opus) and whole cycles of the 1 kHz tone. The audio is encoded three loops long and only the middle loop's
packets are kept, so the file has no AAC priming or end padding. AAC is one frame per PES. The script ends by
copy-looping three passes and printing each stream's span and PTS steps (`tspes.py`): every step is nominal.
Decoded once after a copy loop, the tone has no larger step at a seam than anywhere else. (Decoding with
`ffmpeg -stream_loop` instead shows a click at each seam. That click is ffmpeg flushing its decoder on every
pass, not the file.)

**Send them the same way, or the packing is lost again:**

```bash
ffmpeg -re -stream_loop -1 -i chart_919_aac.ts -c copy -pes_payload_size 0 -f mpegts \
  "srt://127.0.0.1:9710?mode=listener&pkt_size=1316"
```

Why: S3's first stream fixtures (a 6 s AAC loop, eight AAC frames per PES) put an 11 ms run of exact zeros and
a cut in the tone at every loop. They also made every SRT harness run start with the resampler on its rail,
because coarse audio packing makes a re-sender's video bursty (`COLOR_MANAGEMENT_FINDINGS.md` §6.10, *The rail
drain*). The script's header has the details.

## The container / bitstream disagreement fixture (`cs709-g24.mxf`)

`/Volumes/DCCOLOR/TEST FLIP/MXF NCLc Matrix/cs709-g24.mxf` is **mistagged on purpose**. It is not in this repo, and it
must **not be retagged**. Its MXF descriptor says **9-16-9** (Rec. 2020 · PQ · Rec. 2020), carried over from a Flip demo.
Its content and its DNxHR header are **709**, gamma 2.4 (`[LIBAV-COLOR] container 9-16-9 · dnxhd decoder frame 9-16-1`).
It is the fixture for a container / bitstream disagreement on the MXF / DNx path (`COLOR_MANAGEMENT_FINDINGS.md` §6.11,
*MXF / DNx: the container drives the picture*).

**Expected result, which is correct behaviour and not a defect:**
- The picture decodes with the **container's matrix** (Rec. 2020), so it looks wrong: the container drives the picture,
  as decided on 2026-10-12.
- `[MATRIX] … — agree` on Rec. 2020: picture, scopes, SDI and readout agree.
- `[LIBAV-COLOR] … ⚠️ DISAGREE on matrix — container used`, logged once.
- The readout's Tags line shows `⚠️ container disagrees with the dnxhd decoder: matrix 9 vs 1 — …`.

The colour override is how a user asserts the true colour of a file like this one.

