# Scrub fixtures

Three harnesses, three questions. `scrubmeas.swift` asks whether the scrub preview and the release
seek agree; `avpvomeas.swift` asks whether the whole overlay can be replaced; `libavmeas.swift`
asks the same thing about the **half of the corpus `avpvomeas.swift` cannot reach at all**, because
AVFoundation has no MXF demuxer. They share a convention (single-file `swiftc` script, built on
demand, binary not committed) and nothing else.

---

## `scrubmeas.swift` — scrub-preview accuracy

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


---

## `avpvomeas.swift` — can `AVPlayerItemVideoOutput` replace the CGImage overlay?

The spike gate for [`../BUGS.md`](../BUGS.md) → *"⏸ BANKED: feed the scrub gesture from
`AVPlayerItemVideoOutput` — one decoder, one display path"*, which is banked on **two unmeasured
risks** and explicitly says an implementation started before they are answered is a bet. This
measures both and nothing else — it builds no app, links no app code and changes no app behaviour.

```bash
cd docs/scrub-fixtures
xcrun swiftc -O -o avpvomeas avpvomeas.swift

MODE=probe                  ./avpvomeas FILE...     # codec / raster / fps / bitrate
MODE=latency N=40 SHADER=1  ./avpvomeas FILE...     # RISK 1
MODE=memory  T=20           ./avpvomeas FILE...     # RISK 2
MODE=hls     T=25           ./avpvomeas URL         # the HLS entry's separate question
```

⚠️ Same trap as `scrubmeas.swift`: do **not** add `-parse-as-library`.

### What each mode measures

**`MODE=latency` — RISK 1.** Per file, `N` positions spread across the duration and jittered off
the frame grid by the same golden-ratio sub-frame offset `scrubmeas.swift` uses, seeked at
AVPlayer's own scrub tolerance (`.positiveInfinity` both sides — the seek already sitting unused in
`ManifoldCore/AVPlayerEngine.swift`). Reported as **mean / p50 / p90 / max**, the shape of the
`exactSeek` table in `../BUGS.md`, so the two can be read side by side. Also reported: the achieved
seek rate, the count over the 50 ms throttle budget, and how far the delivered frame is from the
one requested — the accuracy price of the tolerance.

Three separations that each turned out to matter:

- **COLD vs WARM**, because the entry's whole premise is that the decoder stays warm across a drag.
  Cold uses a **fresh `AVPlayer` per trial**; reusing one and timing its first seek would measure a
  decoder that is already up.
- **back-to-back vs paced at 20 Hz**, the harsh case and the shipping case.
- **`SHADER=1` adds a second pass** that carries the frame the rest of the way: two
  `CVMetalTextureCache` plane textures and a render into an `rgba16Float` offscreen, waited to GPU
  completion. That is the difference between the verdict for the PICTURE and the verdict for the
  SCOPES, which read the offscreen ring and not the copied buffer.

**`MODE=memory` — RISK 2.** Three phases in one process: playback alone, playback **plus** a live
scrub player dragging at 20 Hz, then playback again with the scrub player released. "Playback" is
an `AVAssetReader` decoding x420 in real time with each frame rendered through the shader — a model
of the app's playback, not the app, so its absolute footprint is a floor and the **delta** is the
measurement. Also reports whether playback lost frames while the scrub player was alive.

**`MODE=hls`** answers the prior question the file measurements cannot: whether
`AVPlayerItemVideoOutput` vends `CVPixelBuffer`s from an HLS item at all, at what pull cost, and
whether the display times arrive without repeats — a repeat is a frame the scopes would show twice.

### ⚠️ Four traps, three of which return plausible wrong numbers

They are documented at the sites where they bite. In short:

1. **A non-nil buffer is NOT the stop condition.** `copyPixelBuffer` hands back the **pre-seek
   frame** if you ask before the new one has decoded, and it is a perfectly valid buffer —
   accepting it reports ~0 ms for a picture that never changed. The acceptance test is a **changed
   `itemTimeForDisplay`**. Same class as `scrubmeas.swift`'s marker-buffer trap: a wrong number
   produced by a stop condition that was too easy to satisfy.
2. **A toleranced seek that lands back on the displayed frame has no changed display time to wait
   for.** Those are counted as `same-frame` using the seek completion handler as the stop signal,
   and reported separately rather than folded into the distribution or miscounted as timeouts. On
   long-GOP at 20 Hz this is not a corner case — it was **26 of 40** positions on the 4K H.264
   fixture.
3. **Blocking the main thread makes the route look broken.** AVPlayer delivers seek completions and
   item KVO on the **main queue**. All work runs on a worker thread and the main thread runs
   `CFRunLoopRun()`; a measurement loop that blocks main would time out on every position and
   report a harness bug as a result.
4. **`resident_size` and `phys_footprint` cannot see the pixel buffers.** A decoder's
   `CVPixelBufferPool` is IOSurface-backed and charged elsewhere — the first smoke run showed RSS
   34 MB for a pipeline decoding 4K ProRes. `vmmap --summary` on our own pid can see it, by region
   type (`CoreMedia memory pool`, `IOSurface`, `owned unmapped (graphics)`); it needs no privilege
   on a process we own. It **suspends the target task**, which is us, so it is called once per
   phase and never on the sampling loop.

⚠️ The shader in `avpvomeas.swift` is COPIED from `App/PassthroughShader.metal` (legal-range Rec.709
branch) and exists to cost the right amount of work, not to be colour-correct for every file. The
decode format is copied from `FrameEngine.videoPixelFormat` / `FileFrameSource.defaultPixelFormat`.
If those change, change these, or this measures a pipeline the app does not have.

### Fixtures used

Not committed. `/Volumes/DCCOLOR` is an SMB 3.1.1 share; the route to it on this machine is a
**25GBase-CR** link (`en8`), which is worth stating because the IO result is conditioned on it.

| file | codec | raster | bitrate | role |
|---|---|---|---|---|
| `TEST FLIP/MONO_STEREO_51.mov` | ProRes 422 HQ `apch` | 3840×2160 | 53 Mb/s | comparable to the `exactSeek` table |
| `TEST FLIP/SYNC CHECK.mov` | ProRes 4444 `ap4h` | 3840×2160 | 23 Mb/s | " |
| `TEST FLIP/H264.mp4` | `avc1` long-GOP | 3840×2160 | 31 Mb/s | " |
| `TEST FLIP/BPI_Instacart_…mov` | ProRes 422 HQ | 3840×2160 | **730 Mb/s** | full-bitrate 4K, copied local |
| `TEST FLIP/NEW HDR.mov` | ProRes 4444 PQ | 3840×2160 | **1085 Mb/s** | 8.1 GB, heaviest SMB case |
| `TEST FLIP/8 MONO ProRes.mov` | ProRes 4444 | 3840×2160 59.94p | 431 Mb/s | 7.5 GB, high frame rate |
| `TEST FLIP/New Corpus/Random Camera/A001C0006_…MOV` | HEVC `hvc1` 10-bit | **5760×3240** | 255 Mb/s | the largest raster in the corpus |

⚠️ **THERE IS NO 8K ProRes IN THE CORPUS.** The largest raster found is the 5760×3240 HEVC camera
original above. The `../BUGS.md` risk is stated for "8K ProRes off a network volume" and that case
is **NOT MEASURED** — the 6K HEVC is the closest available proxy and is a different codec with a
different decode cost. Do not read it as an 8K ProRes result.

---

## `libavmeas.swift` — can the LIBAV path reach `renderPixelBuffer` at drag rate?

The sibling of `avpvomeas.swift`, and it exists because that spike's route **cannot open half the
corpus**. `FrameEngine.loadMXF` states it plainly: *"AVFoundation has no MXF demuxer, so it can't
open the file at all — MXF routes DIRECTLY to libav."* So `AVPlayerItemVideoOutput` covers ProRes,
H.264 and HEVC, and covers **nothing** in MXF. For the overlay to stop existing — one picture path,
one HDR behaviour, no `CGImage` anywhere — MXF has to reach the same destination with a different
producer: **libav seeking, decoding one frame and handing over a `CVPixelBuffer`.**

That seam is not new. `MetalVideoRenderer.renderPixelBuffer` already takes frames from arbitrary
producers — it is how NDI, WHEP and SRT work — so the question is never whether the renderer accepts
the frame. It is only **how long libav takes**.

```bash
cd docs/scrub-fixtures
./build-libavmeas.sh            # NOT a one-liner: this harness has to LINK the vendored libav

MODE=probe                              ./libavmeas FILE...   # what libav sees; can AVF open it at all
MODE=latency N=40 SHADER=1 THREADTYPE=slice ./libavmeas FILE...   # THE QUESTION
MODE=threads N=30                       ./libavmeas FILE...   # thread_count × thread_type sweep
MODE=memory  T=25 THREADTYPE=slice      ./libavmeas FILE...   # second decode alongside playback
MODE=io      T=12 THREADTYPE=slice      ./libavmeas FILE...   # IO of the drag, measured DIRECTLY
MODE=hdr                                ./libavmeas FILE...   # what the decode produces; what x420 costs
```

⚠️ Same trap as the other two: do **not** add `-parse-as-library`.

### It links the app's own libav, and copies the app's own conversions

`build-libavmeas.sh` passes `-import-objc-header` pointing at
`Packages/ManifoldCore/Sources/CFFmpeg/include/shim.h` — the **app's** umbrella header — and links
the **same vendored dylibs**. `LibavScrubDecoder.convert` is copied from `LibavFrameSource.convert`
(same swscale destination, same "force src/dst range EQUAL", same three colour attachments);
`thumbnailPath` is copied from `LibavThumbnailSource.makeCGImage`. If those change, change these, or
this measures a pipeline the app does not have. The shader stage is byte-identical to
`avpvomeas.swift`'s, so the shader cost is directly comparable between the two producers.

⚠️ The `-rpath` in the build script is **required** — the dylibs' install names are `@rpath/…`
(`otool -D`), and without it the binary compiles and then fails to launch with a dyld error that
does not mention rpath.

### What each mode measures

**`MODE=latency`.** t0 is `av_seek_frame`; t1 is a `CVPixelBuffer` in the app's x420 contract in
hand — decoded, converted, attachments set. That is the same span `avpvomeas.swift` timed, with the
same positions (golden-ratio sub-frame jitter off the grid), the same distribution shape and the
same 50 ms budget, so the two tables read side by side. **COLD is a fresh `AVFormatContext` +
decoder per trial**; the install cost (`avformat_open_input` + `avformat_find_stream_info` +
`avcodec_open2`) is timed in **three separate stages** and reported outside the per-seek budget,
because `find_stream_info` is the only one that scales with the file and it is 95% of the total.
Four warm passes run per file — back-to-back, paced at 20 Hz, paced with a **fresh `sws` context
per frame** (what `LibavFrameSource` actually does), and paced through the **shipping 960×540 RGBA
`CGImage` path**, so the proposed route is priced against the one it would replace. `SHADER=1` adds
a fifth carrying the frame into an `rgba16Float` offscreen, waited to GPU completion.

**`MODE=threads`** sweeps `thread_count` **and** `thread_type`. It is not a tuning nicety; see the
first trap below.

**`MODE=memory`** is `avpvomeas.swift`'s three phases with a libav pump instead of an
`AVAssetReader` — playback alone, playback plus a live scrub decoder at 20 Hz, playback with the
scrub decoder released. It is the **only** place the "thumbnails deliberately open their own context
so seeks never touch the playback one" claim is actually tested. The pump pins `cores−1` threads and
libav's **default** `thread_type` — `LibavFrameSource`'s real choices — rather than inheriting
`THREADTYPE`, so the experiment's setting cannot leak into the thing it is contending with.

**`MODE=io`** measures the drag's IO **directly** rather than by the P2 − P1 subtraction, and it
exists because that subtraction is invalid at 4K on this corpus — see the third trap. It runs two
drag shapes, `scatter` and `sweep`, because they are not the same IO problem and only one of them is
a gesture anybody makes.

**`MODE=hdr`** reports the decoded pixel format, depth, range and colour tags; the attachments that
land on the buffer; and a **code-for-code luma comparison** of source against the x420 destination
over the whole raster, so "10-bit path" is a measurement and not a format name. It also prints what
the shipping `CGImage` path does with the same frame.

### ⚠️ Four traps, and the first one is the whole result

1. **`thread_type` is the measurement.** Neither `LibavFrameSource` nor `LibavThumbnailSource` sets
   it, so both get libav's default, which prefers `FF_THREAD_FRAME`. `avcodec.h:1577` states the
   consequence in one line: *"Use of FF_THREAD_FRAME will increase decoding delay by one frame per
   thread."* For continuous playback that delay is free — a pipeline that fills once. **For a
   single-frame seek it is not**: `avcodec_flush_buffers` empties the pipeline, so getting ONE frame
   out costs `thread_count` frames of decode. Measured on 4K DNxHR HQX, 40 positions at 20 Hz:
   **47.4 ms mean / 63.1 ms max** with the default, **19.2 / 22.7** with `FF_THREAD_SLICE` at the
   same thread count. A harness that measured only the shipping configuration would have reported
   that the libav path misses the budget, which is true of the configuration and false of the path.
   The give-away in the raw output is the `packets read per seek` column: **17 packets for one
   all-intra frame.**
2. **A latency number without `delivered frame − requested` cannot tell a fast seek from a short
   walk.** `av_seek_frame(…BACKWARD)` can land arbitrarily far before the target on a coarse index,
   and the decode-forward loop will happily walk there — cheap on all-intra, not cheap otherwise. So
   every position also reports how far the delivered frame is from the requested one and how many
   frames were decoded and thrown away to reach it. This is the mirror of `avpvomeas.swift`'s trap:
   that one had to guard against accepting **too early** (`copyPixelBuffer` returns the pre-seek
   frame, and it is a valid buffer); libav cannot do that, because every frame arrives with its own
   PTS. The risk here is accepting the **wrong** frame and not noticing.
3. **⚠️ EVERY 4K MXF IN THIS CORPUS IS SMALL ENOUGH THAT `MODE=memory`'s P1 CACHES THE FILE IT IS
   ABOUT TO MEASURE P2 AGAINST.** 1.4–4.3 GB on a 64 GB machine. The P2 − P1 subtraction is only
   valid while neither phase is served from cache; the long-form 1080p files (26 GB, 42 GB) are
   immune and give a clean delta, and at 4K there is no such file. `sudo purge` is not available to
   this harness. Both `MODE=memory` and `MODE=io` therefore **print an explicit warning on any phase
   that moved ~0 bytes** rather than letting a cached row be read as "the drag costs nothing", and
   `MODE=io` exists so the 4K number can be taken directly instead of by subtraction.
4. **`CoreMedia memory pool` is absent from `vmmap` on this path, and that is a finding rather than
   a failed read.** libav's decoder is not CoreMedia; frames live in libav's own buffers and then in
   our `CVPixelBufferPool`, which vmmap accounts under `IOSurface`. `avpvomeas.swift`'s table has a
   CoreMedia column because *its* decoder is VideoToolbox's. The two tables do not have the same
   rows; this one prints `—`, not `nan`.

### Fixtures used

Not committed. `/Volumes/DCCOLOR` is SMB 3.1.1 over a **25GBase-CR** link (`en8`) — the IO results
are conditioned on that.

| file | codec | raster | rate | role |
|---|---|---|---|---|
| `CS Validation Manifold/Lip Sync DNX.mxf` | DNxHR 10-bit 4:2:2 | 3840×2160 | 701 Mb/s, 4.27 GB | the 4K case |
| `MXF NCLc Matrix/cs2020_pq.mxf` | DNxHR 10-bit, **PQ / Rec.2020** | 3840×2160 | 701 Mb/s | the HDR case |
| `MXF NCLc Matrix/cs2020_hlg.mxf` | DNxHR 10-bit, **HLG / Rec.2020** | 3840×2160 | 701 Mb/s | " |
| `MXF NCLc Matrix/{cs709-g24,cs2020_g24,csdcip3_g26,ST_51}.mxf` | DNxHR 10-bit | 3840×2160 | 701 Mb/s | `MODE=io`, **untouched by any earlier phase** |
| `MXF TEST/269926_002_…mxf` | DNxHD 8-bit 4:2:2 | 1920×1080 | 131 Mb/s, **41.86 GB / 42 min** | too large to cache — the clean IO delta |
| `MXF TEST/House Hunters…Faith.mxf` | DNxHD 8-bit | 1920×1080 29.97 | 159 Mb/s, **26.42 GB** | " |
| `Joey Avid/test_12ch_OP1a_dnxHQX.mxf` | DNxHR **12-bit** 4:2:2, 13 streams | 1920×1080 | 191 Mb/s | the bit-depth edge |
| `CS Validation Manifold/TEST OMNISCOPE_LEGAL.mxf` | DNxHR 10-bit | 3840×2160 | 713 Mb/s | short 4K |

⚠️ **THERE IS NO DNx-IN-`.mov` IN THE CORPUS.** `MediaInspector.requiresLibavDecode` routes four
fourccs (`AVdh`, `AVdn`, `dnxh`, `dnxd`) in `.mov` to libav, and **all 109 `.mov` files on the share
were checked and none carries one**. So in this corpus the libav path is MXF and only MXF. The
`.mov` branch is untested by these numbers; nothing about it should be inferred from them, though it
is the same decoder on a cheaper demuxer.

⚠️ **`MXF TEST/The_Righteous_Gemstones_404.mxf` DOES NOT OPEN AT ALL, AND IT IS NOT A SCRUB
PROBLEM.** Its essence is **JPEG 2000** (confirmed with a system `ffmpeg`), and
`scripts/build_ffmpeg.sh` configures `--disable-everything` plus `--enable-decoder=dnxhd,prores` and
the PCM/AAC set. So `avcodec_find_decoder` returns NULL and the file has no route in Manifold by
either producer. Recorded here because the sweep found it; it belongs to whatever entry covers
supported essence, not to this one.
