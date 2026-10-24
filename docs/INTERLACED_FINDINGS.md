# Interlaced video — audit, decisions and staged plan

**Audited 2026-10-09 (read-only; no app code changed). Decisions: Robbie, 2026-10-09.**

*Measured fact, inference and prediction are labelled separately. Line references were checked on
2026-10-09 against `b1602a9`; they rot, so re-read the source before acting on one.*

Interlaced (1080i59.94 US, 1080i50 Europe) is a standard broadcast deliverable, and checking an
interlaced master on a reference monitor over SDI at its native format is a core QC job. Two jobs,
with opposite needs:

- **SDI output:** pass the fields through untouched, in the native interlaced mode. No deinterlacing.
- **The window on the Mac screen:** a display choice, like OS/Bypass.

**Scopes, SDI and export always measure the original woven frame, never the display view.**

---

## TL;DR

- **Nothing in Manifold knows interlacing exists.** No path detects scan type or field order. Every
  frame travels woven (both fields in one buffer), except NDI, which asks the NDI SDK to deinterlace.
- **DeckLink can only pick progressive modes,** so a 1080i59.94 file or stream goes out as 1080p29.97
  (or 1080p59.94 when a field rate is read as the frame rate). This was deliberate, but on a wrong
  premise ("the decode path is progressive"): the decode path is scan-agnostic.
- **The pipeline already keeps fields apart in luma,** all the way to the wire. The SDK schedules
  interlaced modes per woven frame, so the scheduler, audio and the A/V anchor need no change.
- **The real fidelity gap is colour.** Every decode is forced to 10-bit 4:2:0 (`x420`). On interlaced
  4:2:2 masters that blends field 1's chroma into field 2's, in the frame the scopes and SDI read.

---

## 1. Current state, per path (measured from the source)

| Path | Detects interlacing / field order? | Frames delivered | What scopes see |
|---|---|---|---|
| AVFoundation files | No. `MediaInspector.metadata` (`MediaInspector.swift:21-38`) never reads `kCMFormatDescriptionExtension_FieldCount` / `FieldDetail`. | Woven. No deinterlace requested (`FileFrameSource.swift:74-77`, `AVPlayerScrubProducer.swift:92-96`). | Woven frame |
| libav files (MXF, DNx in .mov) | No. `field_order` and `AV_FRAME_FLAG_INTERLACED` / `TOP_FIELD_FIRST` are never read (`LibavFrameSource.swift:255-350`). The DNx VT decoder omits the field-count key on purpose (`DNxHRVideoToolboxDecoder.swift:110-116`). `MXFDeclaredRange` reads no FrameLayout / VideoLineMap. | Woven. sws converts 4:2:2 → 4:2:0 progressively (`LibavPixelConversion.swift:100-127`). | Woven, mixed-field chroma |
| SRT / WHEP, H.264 | No. `frame_mbs_only_flag` is read and discarded (`H264SPSTiming.c:195`); the VUI rate always divides by 2 (`:239-242`). Slice `field_pic_flag` and SEI `pic_struct` are never parsed. | MBAFF arrives as frames, woven. PAFF would arrive one field per access unit — **not measured** (x264 cannot make PAFF). | Woven |
| SRT, HEVC | Partly. `field_seq_flag` suppresses the declared rate (`HEVCSPSColor.swift:115`, `SPSTiming.swift:55-57`), so the PTS measurement decides. `general_interlaced_source_flag` is skipped (`HEVCSPSColor.swift:315`). | As H.264 | Woven |
| NDI | No. `allow_video_fields = false` (`NDIBridge.mm:317-319`) and progressive framesync capture (`:492-493`); `frame_format_type` is never read. | **Deinterlaced by the NDI SDK** | **The deinterlaced frame** — breaks the scopes rule |
| HLS | No. AVPlayer as-is (`HLSClient.swift:79`). Apple's HLS authoring spec asks for progressive. | As AVFoundation delivers | As delivered |

**The renderer.** Every consumer — the four scope kernels, the DeckLink v210 convert, ⌃⌥E export, the
display copy — reads the same offscreen ring (`MetalVideoRenderer.swift:158-160`, ring `:389-404`). It
holds the woven frame at source raster. The luma path into it is 1:1, and the clean-aperture crop is on
an even grid, so line parity survives (`PassthroughShader.metal:62-76`).

**The colour gap.** The decode contract is `x420` throughout (`FrameEngine.swift:435`,
`FileFrameSource.swift:40`), and `passthroughFragment` upsamples chroma bilinearly as if progressive
(`PassthroughShader.metal:122-125`). Progressive 4:2:2 loses vertical chroma detail — already recorded
(BUGS.md, *feed the scrub gesture from `AVPlayerItemVideoOutput`*, "TWO LOSSES ARE REAL"). On interlaced
material it also mixes the two fields' chroma. The renderer already accepts `x422`
(`MetalVideoRenderer.swift:3688-3692`), and chroma plane sizes come from the buffer (`:2533-2534`).

## 2. SDI output

- **SDK:** `bmdModeHD1080i50`, `bmdModeHD1080i5994`, `bmdModeHD1080i6000` exist; each mode reports its
  `BMDFieldDominance` (`DeckLinkAPIModes.h:86-88, 203-211, 274`). No interlaced 2160 mode exists.
- **8K Pro:** Blackmagic's spec lists all three 1080i modes. **Not checked on the card** — confirmed at
  start by the existing `DoesSupportVideoMode` (`DeckLinkBridge.mm:296`).
- **Scheduler: no change.** The SDK's SignalGenerator sample schedules one woven frame per frame period,
  from the mode's `GetFrameRate` (`SyncController.mm:509-513, 743`): 1001/30000 for 1080i59.94, the same
  as 1080p29.97. The card splits the fields.
- **Fields survive the SDI convert.** `rgbToV210` reads only its own row (`PassthroughShader.metal:554-567`).
  The pull model (`copyLatestDeckLinkFrame`) repeats or drops whole frames, never single fields.
- **Field dominance.** HD 1080i is always upper field first, so a TFF file goes straight through. A
  BFF HD file is sent untouched, with a warning (decision 2).
- **Audio:** unchanged (own sample clock; 1601.6 samples per frame, as 1080p29.97).
- **Timecode:** Manifold sends none, so the VITC1/VITC2 interlaced rule does not apply.
- **The 2 s mode settle is live-only;** a file's mode change is immediate (`DeckLinkService.swift:892-896`).
- **Mode label bug:** `ModeNameForResolved` (`DeckLinkBridge.mm:905-906`) hardcodes "p", so the 1080i59.94
  mode would read "1080p29.97". It must take the scan from the mode's field dominance.

## 3. On-screen display

- **Insert point:** the display-only stage between the offscreen pass and the display copy
  (`MetalVideoRenderer.swift:2649` → `:2676`), writing a separate texture. **Never deinterlace into the
  offscreen ring** — SDI and export would pick it up.
- **Weave:** today's picture. The display copy is bilinear (`PassthroughShader.metal:228`), so away from
  100% it blends lines of opposite fields; a true weave is only seen at 100%.
- **Field 1 / Field 2:** one field, line-doubled to full height in the display stage. `engine.displaySize`,
  the offscreen size, the raster readout and `LiveDisplaySize` must not change.
- **Deinterlace (frame rate):** intra-field interpolation of one field, in a Metal shader. VideoToolbox's
  deinterlace lives inside the decoder and would change the frame the scopes read, so it cannot be used.
- **True bob (field rate), after 1.0:** two presents per source frame; `performDisplayTick`
  (`MetalVideoRenderer.swift:2125`) renders each frame once, so it needs new scheduling. The ring's other
  entry holds the previous frame for a motion-adaptive variant.
- **The control:** modelled on OS/Bypass — per window, not saved (`WindowChrome.swift:173`), one mutator
  (`WindowDeck.swift:716-730`), a pulldown beside `DisplayTransformControl`, a Color-menu entry, a
  window-title suffix when not Weave. No shortcut until the shortcut registry.

## 4. Readouts

Interlacing is shown nowhere: `VideoMetadata` has no scan field and `frameRateString` prints "%.3f fps"
(`VideoMetadata.swift:452`). Slots: an Inspector Scan row beside Frame Rate (`InspectorPanel.swift:99`);
"1080i59.94 TFF" on the chain readout's Source row; a "Fields: Weave" row after Transform
(`DisplayChainModel.swift:186-190`); the "Scopes are unaffected" footnote covers both.

## 5. Frame-rate rule (decision 3)

- Internally, **frame rate** (29.97) plus a scan flag. Labels use the **field rate**, as Blackmagic does:
  "1080i59.94".
- Interlaced, 1080 family, frame rate nearest 25 / 29.97 / 30 → **1080i50 / 1080i59.94 / 1080i60**.
- **An interlaced source reporting 50 / 59.94 / 60 is counting fields:** halve to 25 / 29.97 / 30 and log
  the deviation. No 1080i standard has 50+ frames per second. This also covers PAFF and HEVC field
  sequences in I6.
- Measured-wins (SRT, `settlePublishedRate`) is unchanged; it compares frames to frames after the halving.
- Interlaced at 23.98 / 24 has no 1080i mode: progressive fallback, logged.
- The manual picker gains the three 1080i modes, which covers mis-flagged files in either direction.

## 6. Fixtures (measured 2026-10-09, ffmpeg 8.1.1 — the vendored version)

Source: `testsrc2` at 60000/1001 (or 50) with a moving `drawtext` counter of `%{n}`, then
`interlace=scan=tff|bff:lowpass=0,setfield=…`. Each field carries its own source picture number.

| Fixture | Encode | Decoder reports | Picture check |
|---|---|---|---|
| ProRes HQ 1080i59.94 TFF | `prores_ks -profile:v 3 -flags +ildct -pix_fmt yuv422p10le` | 29.97 fps, `i:T` | top field "30", bottom "31" |
| ProRes HQ 1080i59.94 BFF | as above, `scan=bff` | 29.97 fps, `i:B` | bottom "30", top "31" |
| ProRes HQ 1080i50 TFF | as above at 50 | 25 fps | — |
| H.264 1080i59.94 TFF, .mp4 and .ts | `libx264 -flags +ildct+ilme -x264-params tff=1` | 29.97 fps, `i:T` | — |
| DNxHD 185x 1080i50 TFF, MXF | `dnxhd -b:v 185M -flags +ildct -pix_fmt yuv422p10le` | 25 fps, `i:T` | — |

- ⚠️ **ffmpeg's container label is a trap.** It prints "(swapped)" for the ProRes files because of how it
  maps the `fiel` atom (09 for TFF, 0e for BFF). The decoder flag and the picture are right. Read field
  order from the bitstream and check it against the picture.
- DNxHR has no interlaced profile: interlaced DNx is classic DNxHD.
- Field-rate-labelled H.264 timing already exists as SRT fixtures (`i5994_field`, §6.10 Stage 4).
- **No free tool makes PAFF.** OBS cannot send real interlaced: its canvas is progressive, so x264's
  interlaced option yields two fields from the same instant.
- Still to make: a static "field 1 solid red, field 2 solid blue" fixture for P6.

## 7. Decisions (Robbie, 2026-10-09)

1. **Field-correct colour is in 1.0.** The 4:2:2 file half merges with HEVC Stage 3b into one
   **"4:2:2 end to end"** stage in the HEVC 3b slot (`COLOR_MANAGEMENT_FINDINGS.md` §6.10), so the renderer
   and scope work is done and measured once. Per-field 4:2:0 colour stays here, as I3.
2. **BFF HD files: sent untouched, with a warning.** The judder on the monitor is the defect QC should see.
3. **An interlaced 50 / 59.94 / 60 frame rate is halved** to 25 / 29.97 / 30, logged.
4. **On-screen deinterlace for 1.0 is I4 only** (Weave, Field 1 / 2, frame-rate deinterlace). True bob
   after 1.0.
5. **The display setting is per window, not saved, default Weave.**
6. **NDI's built-in deinterlace is fixed with streams (I6).** For 1.0, a user-guide note.
7. **XDCAM HD422 (MPEG-2) and AVC-Intra in MXF:** first a read-only check of whether they already play
   through AVFoundation with the Pro Video Formats registered (later). Adding libav decoders is decided
   after that. Today the libav build has neither decoder (`scripts/build_ffmpeg.sh:259-266`).
8. **SD interlaced (480i / 576i) is out of scope.**

## 8. Staged plan

Named I1–I6 so they cannot be confused with the HEVC stages in §6.10.

| Stage | What | Size | 1.0? |
|---|---|---|---|
| **HEVC 3b — 4:2:2 end to end** (§6.10) | HEVC Main 4:2:2 10 over SRT, **and** 4:2:2 file sources decoded to `x422` (AVFoundation via VT; libav via sws to P210; the DNx VT decoder), scrub and playback changed together so they stay byte-identical. Renderer, scopes, DeckLink measured once. | M | Yes |
| **I1 — detect (files)** | `scan` (progressive / TFF / BFF / unknown) in `VideoMetadata`. libav: `field_order`, confirmed by the first frame's flags; the bitstream wins, disagreements logged. AVFoundation: FieldCount / FieldDetail. Inspector Scan row. | S, ~1 day | Yes |
| **I2 — SDI 1080i (files)** | 1080i rows in `standardRates` and `BMDModeForFamilyRate`; the halving rule; the label from field dominance; three 1080i modes in the picker; the BFF warning through `sourceAdvisory`; unit tests for `resolveOutputMode`. | S–M, 1–2 days | Yes |
| **I3 — per-field 4:2:0 colour** | `passthroughFragment` reconstructs 4:2:0 chroma from the same field when the source is interlaced. | S | Yes |
| **I4 — display options** | The control, readout rows, Weave, Field 1 / Field 2, deinterlace at frame rate. | M, 2–3 days | Yes |
| **I5 — true bob** | Field-rate presents; optionally motion-adaptive. | M–L, 3–5 days | After 1.0 |
| **I6 — streams** | H.264 `pic_struct` and slice field flags, PAFF field pairing, HEVC `general_interlaced_source_flag`, NDI `allow_video_fields` + `frame_format_type`; scan into `LiveVideoFormat`. Needs a PAFF fixture. | L | After 1.0 |

Order in the release scope: the colour work (which now includes HEVC 3b — 4:2:2 end to end), then
I1 → I2 → I3 → I4, then the shortcut registry.

## 9. Predictions (pass / fail bands)

| # | Stage | Prediction | Pass | Fail |
|---|---|---|---|---|
| P1 | I1 | Each of the five fixtures reads interlaced with its field order; the existing progressive fixtures read progressive | every one matches | any miss |
| P2 | I1 | Frame rate 29.970 / 25.000 | within ±0.001 fps | outside |
| P3 | I2 | Follow source → 1080i59.94 (TFF and BFF files), 1080i50; the bridge logs `30000/1001 duration/timescale` and a 1080i label | exactly that | any `1080p` mode |
| P4 | I2 | `DoesSupportVideoMode` passes for all three 1080i modes on the 8K Pro; 0 late, 0 dropped over 60 s | as stated | any refusal; late/dropped above the 1080p baseline |
| P5 | I2 | Reference monitor reads 1080i59.94; the TFF counter steps once per field. The BFF fixture **judders**, with the warning up | as stated (the BFF judder is the pass) | TFF judders; BFF smooth (we altered it); no warning |
| P6 | HEVC 3b + I3 | Red/blue field fixture through ⌃⌥E export (same texture as SDI). Today every row's chroma sits near the two-field mix; after, each row matches its own field | ≥ 99.9 % of rows within ±2 codes of their own field | otherwise |
| P7 | I4 | Waveform histogram byte-identical across Weave / Field 1 / Field 2 / deinterlace | identical | any difference |
| P8 | I1–I4 | Progressive regression set picks the same modes as today | unchanged | any change |

---

## 10. I1 — detection (files): scope, predictions, results

**Written 2026-10-23, before any build, against `57e7569`.** Results follow the predictions; nothing above
this section was changed by I1.

### 10.1 Scope: where the I1 brief and this document differ (the document wins)

| Brief asked | This document says | I1 does |
|---|---|---|
| Streams detected from the same bitstream fields | Streams are **I6** (§8) | Files only. The `.ts` fixtures are made (I6 needs them) and checked by FFmpeg and the parser outside the app; no live path changes. `.ts` is not a file source in Manifold (AVFoundation cannot open it; only MXF routes to libav, `FrameEngine.swift:1713-1718`). |
| When sources disagree, container wins per axis | **The bitstream wins**, disagreements logged (§8, I1) | Bitstream wins per axis; the container fills only an axis the bitstream leaves unstated. |
| NTSC 525i BFF and PAL 625i fixtures | **SD interlaced is out of scope** (decision 8) | Not made. |
| Chain readout row ("Scan: interlaced, top field first (fiel)") | I1 adds the **Inspector Scan row**; the chain readout's rows belong to I4 (§4, §8) | Inspector Scan row, plus a `[SCAN]` log line (which is what a diagnostics export carries). The chain readout is untouched. |
| — | libav: `field_order`, confirmed by the first decoded frame's flags | The container is read directly (the `fiel` atom through CoreMedia's FieldCount / FieldDetail, and the MXF descriptor's FrameLayout / FieldDominance), because libav's `.mov` `field_order` is the §6 trap. The bitstream is read from the first video packet's own header at load, on both paths, before any decode: the same bits libav's decoder turns into its frame flags. FFmpeg's decoder flags (`showinfo`, same 8.1.1) confirm the reader per fixture, outside the app. |
| Frame rate | Rate halving is **I2** (decision 3) | The Frame Rate row is unchanged. |

### 10.2 What is read, per source

- **Container.** `.mov`: `fiel` as CoreMedia exposes it (`FieldCount` 1 → progressive; 2 with `FieldDetail`
  1 or 9 → TFF, 6 or 14 → BFF, per §6). MXF: the picture descriptor's FrameLayout (0 full frame → progressive,
  1 separate fields / 3 mixed fields → interlaced, 4 segmented frame → progressive, PsF) and FieldDominance
  (1, the default, → field 1 first; field 1 is the top field in 1080i).
- **Bitstream** (the first video packet, plus `avcC` / `hvcC`):
  - ProRes: the frame header's `interlace_mode` (0 progressive, 1 TFF, 2 BFF).
  - DNxHD / DNxHR: header byte 5 (bit 1 interlaced; bit 0 the first coded field, 0 = top).
  - H.264: SPS `frame_mbs_only_flag` = 1 → progressive. Otherwise the first slice: a field slice
    (`field_pic_flag`) → interlaced, first field from `bottom_field_flag`; a frame slice → `pic_struct` from
    the picture timing SEI when the SPS says it is present (3 / 5 TFF, 4 / 6 BFF, 0 / 7 / 8 progressive),
    else the sign of `delta_pic_order_cnt_bottom` (> 0 TFF, < 0 BFF) for MBAFF frames.
  - HEVC: `field_seq_flag` = 1 → interlaced, field order from the first `pic_struct` (1, 10 or 11 top first;
    2, 9 or 12 bottom first: 9 / 10 pair with the previous field, 11 / 12 with the next); otherwise `general_progressive_source_flag` / `general_interlaced_source_flag`
    (1 / 0 progressive, 0 / 1 interlaced).
- **One place in the model:** `VideoMetadata.scan` (scan type, field order, the source that decided each,
  both readings, disagreements). Both metadata producers fill it. Nothing reads it except the Inspector row.

### 10.3 Estimated run time

**About 5 hours** (band 3½–6½): reader, resolver and tests ~2½ h; fixtures and their checks ~30 min; HEAD
and tree Profile builds ~20 min; unattended app runs ~30 min (20 control files on each build, ~15 interlaced
fixtures on the tree); this record ~30 min. No attended steps.

### 10.4 Fixtures (`scripts/interlaced/generate.sh` → `build/interlaced-fixtures/`, gitignored)

§6's recipe: `testsrc2` at 60000/1001 (or 50) with a `%{n}` counter, then `interlace=scan=tff|bff:lowpass=0`.
ProRes 422 HQ 1080i59.94 TFF and BFF; ProRes HQ 1080i50 TFF; DNxHD 1080i59.94 TFF and BFF in MXF; DNxHD 1080i50
TFF in `.mov` (the libav route with a `fiel`); H.264 MBAFF 1080i59.94 TFF and BFF in `.mov` and `.ts`; H.264
PAFF if any tool can make it (§6 says none can); HEVC field-coded (x265 `interlace`) if FFmpeg can make it, `.mov`
and `.ts`; a progressive ProRes control; a PsF-style ProRes (progressive picture, coded and tagged TFF); two
disagreeing ProRes files made from the TFF one by rewriting only its `fiel` (to BFF, and to progressive).

### 10.5 Predictions

| # | Prediction | Pass | Fail |
|---|---|---|---|
| Q1 | ProRes TFF / BFF / 1080i50: interlaced TFF / BFF / TFF, source **ProRes frame header**; container `fiel` agrees | all three exactly | any miss or wrong source |
| Q2 | DNxHD MXF TFF and BFF: interlaced TFF / BFF, **DNx frame header**; MXF FrameLayout agrees (if FFmpeg's muxer writes FieldDominance 2 for BFF; if it writes no dominance, the BFF file's container reads TFF and a disagreement is logged, which also passes as long as the bitstream decides) | both exactly | any miss |
| Q3 | DNxHD `.mov` 1080i50 TFF: TFF, DNx frame header, `fiel` agrees | exact | miss |
| Q4 | H.264 MBAFF `.mov` TFF / BFF: interlaced TFF / BFF; scan from the first slice (MBAFF frame), order from `pic_struct` SEI if x264 writes one, else from the slice POC. The named source must be the one `trace_headers` shows the stream carrying | both exactly | any miss |
| Q5 | `.ts` twins (H.264, HEVC): the stand-alone reader agrees with `trace_headers` and `showinfo` | exact | miss |
| Q6 | HEVC field-coded `.mov`: interlaced, order from `pic_struct`, source **HEVC field_seq_flag + pic_struct SEI**. Whether AVFoundation plays it is recorded, not judged | exact (if made) | miss |
| Q7 | Progressive ProRes control: progressive, ProRes frame header; `fiel` 1 field agrees | exact | miss |
| Q8 | PsF-style ProRes: **interlaced TFF** (it is coded and tagged so; tags are the truth). Recorded as a finding: tags alone cannot tell PsF content | exact | progressive |
| Q9 | Disagreement files: order and scan from the ProRes header (TFF), and one `⚠️ DISAGREE` in the `[SCAN]` line naming the axis (field order for the BFF `fiel`; scan for the progressive `fiel`). The Inspector row shows the bitstream's answer and the container's dissent | both exactly | container used, or no log |
| Q10 | The 20 control files (S7's set): all progressive, each with its codec's source (ProRes frame header; H.264 SPS; HEVC SPS, or the `fiel` when the HEVC SPS sets neither source flag; DNx frame header with MXF FrameLayout) | 20 / 20 | any interlaced or unknown |
| Q11 | Every fixture: the reader matches `showinfo`'s decoder flags (`i:T` / `i:B` / `i:P`) on the first frame, and `ffmpeg -i` / `mediainfo` on the container (reading `fiel` 09 as TFF despite "(swapped)") | all | any difference not explained by §6's trap |
| E | Control set exports (⌃⌥E through the Export frame button): `.rgba16f`, `.v210`, `.v210.json` byte-identical to HEAD; PNG pixels and ICC equal. The window is not measured (no screenshots this session); no file in the display, export or SDI path changes, which `git diff --stat` shows | 20 / 20 | any byte |
| L | Log lines: every existing tag's lines identical to HEAD's on the control set; the only addition is one `[SCAN]` line per file, plus its probe time ≤ 20 ms | as stated | any other change |
| G | `swift test`: all pass, HEAD's count plus the new tests. Profile build with HEAD's warning set (sorted, paths normalised) | as stated | any failure or new warning |
| D | `com.graviton.manifold` defaults dictionary-equal to the snapshot after the runs (restored first if a run wrote window state), `streamBookmarks` hash unchanged | equal | any difference |

### 10.6 Results (built and run unattended 2026-10-23, committed `c9f0c97`)

**Estimated** 5 h (band 3½–6½). **Actual** about 1 h 20 min, from the predictions to this record. No attended
steps, no screenshots, no keystrokes; every app quit by a Quit event to the bundle path. Runs, logs, exports and
the driver: `build/interlaced-i1/`. Fixture check: `build/interlaced-fixtures/verify.out`.

Four tree builds were made. Build 1 was the first; build 2 and 3 fixed the MXF header read (below); build 4 fixed
the wording of a field-order dissent (it named the container's scan field, "MXF FrameLayout", instead of its order
field, "MXF FieldDominance"). E and L were measured on build 3. Build 4 differs from it only in
`SourceScan.readout`'s disagreement suffix, re-checked on build 4 with the three disagreeing files.

| # | Measured | Verdict |
|---|---|---|
| Q1 | ProRes TFF / BFF / 1080i50: interlaced TFF / BFF / TFF, **ProRes frame header** (`interlace_mode` 1 / 2 / 1); `fiel` 2 / SpatialFirstLineEarly, Late, Early: agree | **PASS** |
| Q2 | DNxHD MXF TFF: TFF, **DNx frame header** (byte 5 = `02`), MXF agrees. BFF: BFF (byte 5 = `03`); the MXF says TFF, because FFmpeg's muxer writes **no FieldDominance** and the standard's default is 1. One `⚠️ DISAGREE on field order`, the bitstream used; Inspector: "Interlaced, bottom field first (DNx frame header) · ⚠️ MXF FieldDominance says top field first" | **PASS** (the band's second case) |
| Q3 | DNxHD `.mov` 1080i50: TFF, DNx frame header. ⚠️ The prediction's "`fiel` agrees" was wrong: FFmpeg writes **no `fiel`** in a DNxHD `.mov` (nor in an H.264 one; CoreMedia then reports no FieldCount), so the container states nothing and the line says "one source" | detection **PASS**; the "`fiel` agrees" clause **FAIL** (prediction wrong, not the reader) |
| Q4 | H.264 MBAFF `.mov` TFF / BFF: TFF / BFF, **H.264 pic_struct SEI** (`pic_struct` 3 / 4); `trace_headers` shows x264 carrying exactly those, with `delta_pic_order_cnt_bottom` +1 / −1 (which the slice-POC fallback reads, unit-tested on these slices) | **PASS** |
| Q5 | `.ts` twins: the stand-alone reader gives H.264 TFF / BFF (`pic_struct` 3 / 4) and HEVC TFF (`field_seq_flag` 1, `pic_struct` 1); `showinfo` `i:T…` / `i:B…` / `i:T i:B i:T` | **PASS** |
| Q6 | HEVC field sequence `.mov` (1920×540 pictures at 59.94): interlaced (**HEVC field_seq_flag**), top field first (**HEVC pic_struct SEI**). Not predicted: FFmpeg writes `fiel` 1 for the 540-line pictures, so the container says progressive and a scan disagreement is logged (the bitstream used). AVFoundation opens it as 1920×540 at 59.94; playback not judged | **PASS** |
| Q7 | Progressive control: Progressive (ProRes frame header), `fiel` 1 agrees | **PASS** |
| Q8 | PsF-style ProRes: Interlaced, top field first (ProRes frame header), `fiel` agrees. Tags alone cannot tell PsF content (finding 4) | **PASS** |
| Q9 | `fiel` rewritten to BFF: TFF from the header, `⚠️ DISAGREE on field order`; Inspector "… · ⚠️ fiel says bottom field first". `fiel` rewritten to progressive: TFF, `⚠️ DISAGREE on scan`; Inspector "… · ⚠️ fiel says progressive" | **PASS** |
| Q10 | The 20 control files: all progressive. ProRes frame header ×15 (`interlace_mode` 0), H.264 SPS ×2 (`frame_mbs_only_flag` 1), HEVC SPS ×1 (progressive_source 1, interlaced_source 0), DNx frame header ×2 (byte 5 = `01`, with MXF FrameLayout 0). Every one "agree" | **PASS** 20 / 20 |
| Q11 | All 16 fixtures: the reader equals `showinfo`'s first-frame flag. Container labels differ from FFmpeg / mediainfo only where explained: the §6 "(swapped)" label on `fiel` 9 / 14; the BFF MXF (no FieldDominance; both tools say TFF, the decoder `i:B`); the HEVC fields (both tools say progressive from `fiel` 1, the decoder alternates T / B); the two rewritten `fiel` files (mediainfo follows the container) | **PASS** |
| E | Control set on build 3 against HEAD (two HEAD runs, three tree runs in all): `.rgba16f`, `.v210`, `.v210.json` byte-identical, PNG pixels and ICC equal, **20 / 20 every time**. Window not measured (no screenshots); `git diff` touches no renderer, shader, export or DeckLink file | **PASS** |
| L | The only added lines: one `[SCAN]` per file (20), probe **0.1–0.4 ms**. Every other difference also occurs between HEAD's two runs, or is launch or quit timing: the startup `[CHAIN] Source: no source` / headroom pair landing before or after the first file (seen between HEAD runs); one `[RENDER-PERF]` more or less (periodic); and the quit-time late frame (finding 7), seen once in HEAD's first run and once on tree build 3 | **PASS** |
| G | `swift test` **540 / 540** (HEAD 525, plus 15 in `FileScanTests`), on the final source. Profile warnings: HEAD 15, build 3 15, the same 15; build 4 recompiled only `SourceScan.swift`, with none | **PASS** |
| D | After the runs: `streamBookmarks` hash unchanged; 12 keys added, all `NSWindow Frame …` (one per launch); no key removed or changed. Each was read, then deleted, stopping at the first failure. Final export dictionary-equal to the snapshot (1528 keys) | **PASS** |

**Real files (read-only, `/Volumes/DCCOLOR/TEST FLIP`), beyond the predictions.** Of 122 MXF there, 6 declare
FrameLayout 1. Five are DNxHD 1080i29.97 (`MXF TEST/10152502.999*.mxf`, `10152507.999*.mxf`): all read interlaced
TFF from the DNx frame header with the MXF agreeing (FieldDominance 1 on four, absent on one; one has
VideoLineMap 0 / 0), matching `showinfo` `i:T`. The sixth (`New Corpus/Premiere Pro /MONO_STEREO_51_PrPro_AS11_16Channel.mxf`,
H.264 High 4:2:2 Intra) does not open: `libav open failed … noDecoder`, the known gap of decision 7. No row, no
`[SCAN]` line.

**Findings.**

1. **`MXFDeclaredRange.headerBytes` stops short of the header metadata** (pre-existing; `MXFDeclaredRange.swift:67-83`).
   It reads to the partition pack's value offset plus `HeaderByteCount`, but SMPTE 377-1 counts `HeaderByteCount`
   from the primer pack, after the partition pack and any KLV fill padding it to the KAG. On every FFmpeg-made MXF
   here (8 files; FFmpeg pads to 512 and writes the picture descriptor last) the descriptor runs past the cut, so
   that reader returns `.untagged`. On all 110 real MXF with a descriptor on TEST FLIP (14 of them RGBA, the case it
   exists for) the descriptor is inside the cut. It only runs when libav reports no range, and FFmpeg writes CDCI
   descriptors, whose range libav does report, so no wrong picture is known. Left unchanged here: I1 changes no
   picture. I1's own read (`FileScanProbe.mxfHeader`) skips the fill and covers 118 / 118. BUGS.md, new entry.
2. **FFmpeg's MXF muxer writes no FieldDominance.** A BFF DNxHD MXF made by FFmpeg therefore declares, by the
   standard's default, top field first. A fixture caveat, not a Manifold defect: Manifold uses the bitstream and
   says the container disagrees.
3. **FFmpeg's `.mov` muxer writes `fiel` for ProRes only** of the codecs here: none for H.264 or DNxHD, and `fiel` 1
   for a 540-line HEVC field sequence. ⚠️ And without `separatefields`, libx265's `interlace=tff` codes each woven
   1080-line frame as one "field" (`field_seq_flag` 1, `pic_struct` alternating 1 / 2): the flags of a field
   sequence on pictures that are not fields. Not used as a fixture.
4. **PsF content is invisible to tags.** A progressive picture coded and tagged TFF reads TFF, as it should: tags are
   the truth. Telling PsF from true interlace needs picture analysis, which no stage plans.
5. **PAFF is still unmeasured on real bytes.** No free encoder makes it (§6). The field-slice branch is unit-tested
   on hand-written SPS / PPS / slices only.
6. **HEVC field sequences reach AVFoundation as half-height pictures** (CoreMedia 1920×540, 59.94). How they should
   be shown and sent is for I4 / I2 (and I6 for streams); I1 only says what they are.
7. **A frame of the previous file is presented after the source is cleared at quit** (pre-existing; HEAD shows it
   too): `[EDR] colour state installed … AFTER a frame was already on screen`, then a `[MATRIX]` line describing that
   frame against the cleared state (`⚠️ DISAGREE` when the last file was not 709). Seen in 2 of 5 runs, at quit
   only. The late-colour-state diagnostic is already described in BUGS.md (*two producers, one destination*); this
   quit-time case is recorded in the I1 entry there.
8. **Two misses of mine, fixed before the final build:** I1's MXF header read first copied the short span (finding 1),
   then omitted the fill, so build 1 and 2 read no container on FFmpeg MXF (the real ones were fine); and the
   disagreement wording of build 1–3 (above). §10.2's HEVC `pic_struct` 9 / 10 text was also corrected after
   writing; the code had it right.

**What changed.** `Packages/ManifoldCore/Sources/FileScan/` (new leaf target: `SourceScan.swift`, the model and
rule; `ScanReaders.swift`, `fiel`, MXF, ProRes, DNx, H.264, HEVC); `SPSColor/SPSScan.swift` (H.264 SPS-to-VUI-HRD,
PPS, slice header and picture-timing SEI readers; the HEVC SEI reader); `H264SPSColor.swift` (the walk records the
fields a slice header needs; colour results unchanged); `HEVCSPSColor.swift` (the PTL source flags; `scan(nal:)`);
`ManifoldCore/FileScanProbe.swift` (the CoreMedia / MXF / libav glue); `VideoMetadata.scan`, filled by
`MediaInspector.metadata` and `FrameEngine.applyLibavMetadata`; the Inspector's Scan row; `SCAN` in the
diagnostics tag list; `Package.swift`; `Tests/FileScanTests/` (15 tests). Scripts: `scripts/interlaced/generate.sh`,
`verify.sh`, `scanprobe.swift`.

**Not in I1, as §10.1 says:** the chain readout (I4), the rate halving and 1080i modes (I2), streams (I6), SD.
