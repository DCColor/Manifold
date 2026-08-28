# Scrub-preview accuracy harness

Does the scrub PREVIEW and the release SEEK put the same frame on screen? `scrubmeas.swift`
answers that from outside the app, on any file, without a rebuild.

Written for the "scrub release jumps the picture once, backwards" report (0.6.2, Joey). The
question, the result, and what is still unexplained are in [`../BUGS.md`](../BUGS.md) →
*"⚠️ UNCONFIRMED: scrub release jumps the picture once, backwards, on ProRes"*. This file is the
mechanics.

Moved here out of a session scratchpad, which does not survive — the same reason
[`../color-fixtures/`](../color-fixtures/) exists.

## Requirements

- Xcode command-line tools (`swiftc`). Nothing else — no build of Manifold, no DeckLink, no
  network. It reads files through AVFoundation directly.
- **It is not part of the app target.** `project.yml`'s `sources:` is `App` plus one explicit
  DeckLink `.cpp`; nothing under `docs/` is globbed in. Adding or editing this file does **not**
  require running `xcodegen`, and it cannot affect a Debug, Profile or Release build.

## Build and run

```bash
cd docs/scrub-fixtures
xcrun swiftc -O -o scrubmeas scrubmeas.swift
N=40 ./scrubmeas "/path/to/clip.mov" ["/path/to/another.mp4" ...]
```

`N` is the number of scrub positions per file (default 40). The binary is built on demand and is
not committed, matching `../color-fixtures/`.

⚠️ Do **not** add `-parse-as-library`. This is a single-file script; top-level code is only legal
without it, and the failure message ("statements are not allowed at the top level") does not point
at the flag.

## What it reports

Per file, for `N` positions spread across the duration and jittered OFF frame boundaries by a
golden-ratio sub-frame offset:

- **`preview frame − frame containing request`** — is the generator returning the frame you asked
  for?
- **`RELEASE frame − PREVIEW frame`**, in frames, signed. **Negative = the picture moves BACKWARDS
  when the drag is released**, which is the reported symptom.
- The same, under three tolerance settings — the shipping `±0.5 s`, `after = .zero`, and both
  `.zero` — so a candidate change can be evaluated without touching the app.
- **Generator latency** per request, which is the cost side of any tolerance change.
- **Staleness**, from replaying `ContentView.requestScrubPreview`'s two gates against a synthetic
  drag at the measured latency. This is the *other* candidate mechanism and on all-intra it is the
  only one with a non-zero magnitude.

Positions that cannot be resolved to a grid frame are counted as `unresolved` and excluded rather
than guessed.

## `MODE=pixdiff` — did the GENERATOR or the COMPOSITOR introduce the difference?

A second mode, for the HDR half of the investigation. It answers what the side-by-side split
(`MANIFOLD_SCRUB_SPLIT=1`) cannot: the split shows that the overlay and the Metal layer *display*
the same frame differently, but not whether the difference was introduced when the image was
**created** or when it was **composited**.

```bash
MODE=pixdiff T=1.0 ./scrubmeas /path/to/clip.mov
```

`T` is the media time to compare (default: 1 s, or mid-duration on a short file).

It compares **PQ code values** — the one space in which the two paths are directly comparable,
because neither applies an EOTF: the Metal shader range-expands and matrixes into `rgba16Float` and
lets the *layer* carry PQ, and the generator returns a PQ-tagged CGImage. So it replicates
`PassthroughShader.metal`'s arithmetic on the decoder's `x420` buffer rather than asking CoreGraphics
to convert anything — a `CGBitmapContext` draw would apply a colour transform and measure *that*.

**Resolution is handled by removing it, not by correcting for it.** The shipping generator is capped
at 960×540 while the decoder delivers the full raster, and a resample difference and a colour
difference look alike in a summary statistic. So:

- **PASS 1** sets `maximumSize = .zero` — full encoded raster, 1:1 with the decoder, **nothing
  resampled on either side**. Any difference here cannot be a filter artefact.
- **PASS 2** runs the shipping 960×540 cap separately, for comparison.

Both passes also report a **resample-immune subset**: pairs whose decoder 3×3 luma neighbourhood is
uniform, where no filter can change the value.

Reported per pass: least-squares fit `gen = m·dec + b` with correlation, max absolute difference in
ten-bit codes, the mean difference **binned by decoder value** (which distinguishes an offset from a
scale from a curve from a ceiling), ceiling/floor counts, and the value ranges.

### ⚠️ The `superwhite` line decides whether the run means anything

Legal-range expansion maps code 940 → 1.0, so codes 941–1023 expand **above 1.0**. The Metal path
keeps those values (`rgba16Float`, explicitly unclamped); the generator **cannot** — CGImage.h,
PQ/HLG float case: *"16-bit or 32-bit float image components values will be clipped to [0.0, 1.0]
range."* That is a creation-side difference no layer property can undo.

A file that peaks at exactly 1.0 — **including `../color-fixtures/wedge-pq-24track.mov`** — cannot
exercise it. The tool prints `superwhite: NONE` in that case, and **a `NONE` result does not clear
the mechanism; it says the file could not test it.** Use content graded above legal white.

⚠️ `makeGenerator`, the shader constants and the matrix coefficients in `scrubmeas.swift` are all
COPIED from the app (`FrameEngine.makeScrubPreviewGenerator`, `PassthroughShader.metal`,
`MetalVideoRenderer.colorParams`). If those change, change these, or this measures a pipeline the
app does not have.

## ⚠️ Three traps, all of which return plausible wrong numbers

They are documented at the sites where they bite, in `scrubmeas.swift` — read those before
changing the reader logic. In short:

1. **The `numSamples == 0` marker buffer.** A trimmed `timeRange` emits one first. Counting it as
   a frame produced **−1 frame in 39 of 40 positions** — precisely the reported symptom,
   manufactured by the harness.
2. **The first real buffer's PTS is trimmed to the range start** in both output modes, so it
   cannot identify the frame. Nearest-matching it fabricated a **+1** that was only the sub-frame
   phase of the sample positions.
3. **Passthrough output returns the preceding keyframe on long-GOP**, because a compressed stream
   can only start at a sync sample. Correct for enumerating the grid, wrong for asking what a seek
   delivers.

The rule that survives all three: decode, skip the marker, and read the **second** real buffer —
it is untrimmed, so the delivered frame is one grid step before it.

## Fixtures used

Not committed (too large); these are the files the recorded numbers came from, on `/Volumes/DCCOLOR`:

| file | codec | notes |
|---|---|---|
| `TEST FLIP/MONO_STEREO_51.mov` | ProRes `apch` 23.976 | all-intra, 121 frames |
| `TEST FLIP/SYNC CHECK.mov` | ProRes `ap4h` 23.976 | all-intra, 243 frames |
| `TEST FLIP/H264.mp4` | `avc1` 23.976 | long-GOP, GOP ≈ 21 — the cost side |

Any ProRes and any long-GOP file will do. **Running it on Joey's actual file is the measurement
most likely to settle the direction**, which two in-house ProRes fixtures could not: they returned
exactly zero across 80 positions.
