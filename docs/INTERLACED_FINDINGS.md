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

---

## 11. I2 — SDI 1080i (files): scope, predictions, results

**Written 2026-10-25 22:39 EDT, before any code change, build or run, against `6a39299`** (`build/interlaced-i2/predictions.md`,
timestamped). Results follow. Nothing above this section was changed by I2.

### 11.1 Scope: where the I2 brief and this document differ (the document wins)

| Brief asked | This document says | I2 does |
|---|---|---|
| A BFF source's fields "handled correctly, not just woven" | **Decision 2:** BFF HD files are sent untouched, with a warning; the judder is the defect QC should see (§9 P5: "the BFF judder is the pass") | The woven frame goes out as decoded. On the top-field-first 1080i wire its later (top) field is shown first in every frame. The advisory (`sourceAdvisory`, DeckLink menu ▸ Signal) says so. Re-ordering the fields (a one-line shift, or a field-delay) would hide a faulty master and change the picture the scopes and export read |
| Manual picker: 1080i rows only if the doc includes them | §5, §8 I2: the three 1080i modes are in the picker | 1080i50 / 59.94 / 60 after the 1080p rows, under both mode sets |
| Rate: interlaced reports its frame rate correctly | Decision 3: an interlaced 50 / 59.94 / 60 is halved, logged | Halved for woven frames only (`InterlacedRate`). A field sequence (HEVC `field_seq_flag`: every picture one field) really delivers pictures at the field rate; it is I4 / I6, left as reported |
| Scaling: horizontal only within each field; other heights: refuse or place unscaled | Silent, except decision 8 (SD out of scope) | The brief applies. 1080 interlaced: rows 1:1, width to the display width (1440 at 4:3 → 1920). Any other interlaced height, and 1080 at 23.98 / 24 (§5: no 1080i mode): progressive mode chosen under the 1:1 rule, picture **placed unscaled** on an even row (field parity kept), with an advisory. Not refused: refusing would put black on the wire |
| Verification on the loops | §9 P5 asks for the reference monitor | The loops measure the wire (mode, field dominance, bytes, temporal order). The reference-monitor half of P5 is not done (attended) |
| — | §8 I2: "unit tests for `resolveOutputMode`" | The rule lives in `SDIOutputModeSelector` (ColorimetryModel), so it is tested there; `resolveOutputMode` passes `interlaced` through |
| Streams | I6 | Files only. Every live path places pictures as progressive (`setDeckLinkSourceInterlaced(false)`) and picks modes as before |

### 11.2 What changed

- **`SDIOutputMode.swift`:** `SDIModeFamily.i1080` (offered at the frame rates 25 / 29.97 / 30, labelled by the field rate
  through `SDIStandardRate.fieldToken`); `SDIOutputMode.interlacedTable`, kept out of `table` so D1–D9 are unchanged;
  `select(…, interlaced:)` and `interlacedMode(height:frameRate:)`; `SDIPlacement.fit(…, interlaced:)` and `fieldsKept`
  (rows 1:1, even row, width resampled only); `SDIResampleTaps.identity`.
- **`FileScan`:** `InterlacedRate` (decision 3) and `SourceScan.fieldRateSuffix`; `ScanReading.picturesAreFields` (set
  by the HEVC field-sequence reader). `VideoMetadata.applyInterlacedRate()`, called by both metadata producers;
  `frameRateString` gives the field rate and says when the rate was halved. The libav path's start timecode now parses
  at the halved rate (identical for every progressive file).
- **`DeckLinkService`:** `OutputMode.interlaced`; the 1080i picker rows; `sourceFormatChanged(…, scan:)`; the advisory
  (`interlacedAdvisory`), set or cleared on every file resolve; the bridge call passes `interlaced`.
- **`DeckLinkBridge.mm`:** `BMDModeForRasterRate(…, interlaced)` → `bmdModeHD1080i50 / i5994 / i6000` (never PsF);
  `ModeNameForResolved` takes the mode's `GetFieldDominance` (§2's label bug) and logs the dominance.
- **`MetalVideoRenderer`:** `setDeckLinkSourceInterlaced`; the placement passes it; a `fieldsKept` scaler's vertical pass
  uses identity taps. The v210 kernels are unchanged.
- **Stepping:** unchanged. One step is one coded frame, which for every interlaced file here is one woven frame (two
  fields). Both step grids come from the file's own samples (AVFoundation) or libav's rate, not from the metadata rate.
  (Since 2026-10-26 a halved file steps one frame of the halved rate: finding 3.)
- **Tools:** `scripts/interlaced/generate-i2.sh` (marker fixtures: each field carries its picture number as a 16-bit
  luma code with a check pattern), `scripts/decklink-loopback/fieldtool.cpp` (`marks`, per-field `cmp`), `capture
  --marks`. Tests: `SDIInterlacedModeTests` (7), `InterlacedRateTests` (4).

### 11.3 Results (built and run unattended on the SDI and HDMI loops 2026-10-25)

**Estimated** 6 h (band 4–8). **Actual** about 2 h 30 min from the predictions to this record. Loops: device 0, profile
`1dfd`, SDI out → SDI in, HDMI out → HDMI in. HDMI input switched per capture only (`capture --input hdmi`, never
persisted); the probe read `cfg VideoInputConnection SDI` after **every** capture (69 of 69, the smoke run included). No keystrokes, no
screenshots; every quit by a Quit event to the bundle path. Runs: `build/interlaced-i2/` (`tree-files`, `head-files`,
`marks`, `head-marks`, `export-head`, `export-tree`).

| # | Measured | Verdict |
|---|---|---|
| R1 | Unit tests: the three 1080i modes at every width / set / scaling; halving; 23.98 interlaced → 1080p23.98; 540- and 576-line interlaced → the 1:1 choice; progressive selection identical with and without the parameter over the whole table | **PASS** |
| R2 | Inspector Frame Rate: `29.970 fps (59.94 fields/s)` on every 59.94 fixture, `25.000 fps (50 fields/s)`, `30.000 fps (60 fields/s)`; the 59.94-frame interlaced file `29.970 fps (59.94 fields/s) · file says 59.940, halved` with `[SCAN] rate: interlaced, reported 59.940 fps — counting fields (decision 3)`; the progressive control `29.970 fps`; the HEVC field sequence `59.940 fps` (not halved) | **PASS** |
| M1 | Follow source and the bridge: ProRes TFF / BFF / PsF / both `fiel`-disagreeing files, DNxHD MXF TFF / BFF, H.264 MBAFF TFF / BFF, 1440×1080i, the halved file → **1080i59.94** (`30000/1001 …, interlaced, upper field first`); ProRes and DNxHD 1080i50 → **1080i50** (`25000/1000`); the 60-field marker → **1080i60**. The input detected `Hi59` / `Hi50` / `Hi60`, field dominance upper, on SDI **and** HDMI, every fixture. HEAD sent the same files as 1080p29.97 / 25 / 30 (`Hp…`, progressive) | **PASS** |
| M2 | Progressive control → 1080p29.97 on HEAD and tree, `Hp29` progressive on both inputs | **PASS** (the 20-file set ran exports only, see E; its modes are not re-measured) |
| M3 | `DoesSupportVideoMode` accepted 1080i50, 1080i59.94 and 1080i60 (reached through Follow source; no defaults write). Card `late=0` on every run; `dropped=0` on every run but one: the **progressive** control on the tree, `dropped=1` at output start, on a path I2 does not change (HEAD 0 on the same file) | **PASS** for 1080i; one sporadic drop on 1080p, recorded |
| F1 | Paused at frame 0, every received frame equal to Manifold's `[SDI-DUMP]` read-back: 16 fixtures × SDI and HDMI, 108–264 frames each, **0 different** | **PASS** |
| F2 | Received fields against FFmpeg's decode of frame 0 (`fieldtool cmp`): every fixture matches **the same field** and not the other (other field: luma mean \|Δ\| 13.6–15.5 codes; PsF and progressive 3.0, both fields one instant). Same field, luma: ProRes ≥ 99.9988 % within ±1, max 2 (as predicted); the 60-field marker and the halved file max 5; **DNxHD 99.83 %, max 9; H.264 4:2:0 99.66–99.71 %, max 76; chroma max 60 (4:2:2) and 361 (4:2:0)** — outside the band. But every first frame is **byte-identical to HEAD's** (16 / 16), so these are the decode and RGB round trip as they were, not I2 (the 4:2:0 chroma is I3) | **PASS** on field placement; the luma band was wrong for DNxHD and 4:2:0 (prediction, not I2) |
| T1 | TFF 1080i59.94 marker playing: SDI 450 fields, HDMI 452 — fields in temporal order, **0 swapped, 0 repeated, 0 skipped**. DNxHD MXF (452 / 456) and the 1440×1080i file (450 / 452) the same. H.264 MBAFF: SDI 454 fields clean; HDMI 448 fields, 0 swapped, **5 whole frames repeated and 5 skipped**, all in the first 0.8 s after Play | **PASS** on field order; one run's start-up repeats (below) |
| T2 | BFF marker: every frame arrives untouched, **top N+1, bottom N**, 0 frames broken (SDI 454, HDMI 450 fields); advisory up. SDI run: 2 whole frames repeated and 2 skipped | **PASS** (judder as decided); the repeats as T1 |
| T3 | 1080i50 marker (SDI 376, HDMI 374 fields) and 1080i60 (450 / 452): 0 swapped, 0 repeated, 0 skipped | **PASS** |
| S1 | 1440×1080i (pasp 4:3): `desqueezed to 1920×1080, fields kept`, scaler `taps V 1 · H 7 · C 11`; markers in order (T1). Its first frame is byte-identical to HEAD's 1080p29.97 one (HEAD's Lanczos-3 at ratio 1 read the neighbouring rows with ~1e-17 weights, which change no code) | **PASS** |
| S2 | HEVC field sequence (1920×540 at 59.94): 1080p59.94 (as HEAD), `source 1920×540 1:1, letterboxed, fields kept`, advisory; bytes as HEAD's | **PASS** |
| C1 | Frame-0 signal on all 16 files identical to HEAD's (`Rec.709 · EOTF 0 · HDR flag clear`); no signal line changed | **PASS** |
| E | 20-file control set (I1's), Export Frame for Support on HEAD and tree: `.rgba16f`, `.v210`, `.v210.json` **60 / 60 byte-identical**; PNG pixels and ICC equal 20 / 20 | **PASS** |
| G | `swift test` **623 / 623** (HEAD 612, plus 11). Profile warnings: the same 11 as HEAD's clean build (paths and lines normalised) | **PASS** |
| D | After the runs: 54 keys added, all `NSWindow Frame …`; each read, then deleted, stopping at the first failure. Final domain dictionary-equal to the snapshot; `streamBookmarks` hash unchanged; licence keys never in a snapshot (presence only, untouched) | **PASS** |

**Findings.**

1. **The file → card pull repeats one whole frame and skips the next, now and then** (pre-existing). 2 of 14 tree
   marker runs (H.264 HDMI: 5; ProRes BFF SDI: 2), and 1 of 5 HEAD runs (ProRes BFF HDMI: 9, at 1080p29.97). The card
   reports `late=0 dropped=0` throughout, so it is upstream of the card: the renderer's front buffer and the card's pull
   (`copyLatestDeckLinkFrame`, §2) disagreeing for a frame. Whole frames only: no received frame ever mixed two source
   frames' fields, so I2's field order holds. **Corrected 2026-10-26:** "all in the first 0.8 s after Play" was counted
   from the capture's start; from Play they come 2.3–2.9 s in (H.264 HDMI), and the bridge read-back shows the same
   repeats at the same gaps, so they are in what is handed to the card. **Fixed for files 2026-10-26** (commit `9aaff2d`):
   the card is handed the frame due at its slot; 0 repeats or skips over 45 Play starts, +11 ms SDI latency (`BUGS.md`,
   *the card is now and then handed the same frame twice*).
2. **The F2 luma band was set from ProRes.** DNxHD (max 9) and 4:2:0 H.264 (max 76) differ from FFmpeg's decode by more,
   identically on HEAD; 4:2:0 chroma is I3's job.
3. **On a file whose rate is halved, stepping follows the file's samples, not the halved rate.** The one such fixture
   repeats every woven frame, so its 59.94 samples are pairs of the same frame; a step moves one sample (half a frame),
   while the Frame Rate row, timecode and Follow source use 29.97. No real file here has this shape. Making the step grids
   follow the halving is a small change, left for a decision. **Decided and built 2026-10-26** (commit `9aaff2d`):
   a step is one frame of the halved rate (the track's samples in pairs, `FrameGrid.pairingSamples`); 0 of 5,921
   presses differ from HEAD on the 35 other files with a track grid (`BUGS.md` release scope).
4. **The 8K Pro sends 1080i on HDMI** at all three rates, detected as `Hi50 / Hi59 / Hi60`, upper field first.
5. The §2 mode-label bug is fixed: the established mode reads `1080i59.94` from the mode's own field dominance.

---

## 12. I3 — per-field 4:2:0 colour (files): scope, predictions, results

**Written 2026-10-26 15:36 EDT, before any code change or build, against `d8fc945`** (plus the uncommitted Stage 0 sleep
assertion, which touches no pixel path). Predictions with their timestamp and hash: `build/interlaced-i3/predictions.md`,
`predictions.timestamp`. Results follow. Nothing above this section was changed by I3.

### 12.1 Scope: where the I3 brief and this document differ (the document wins)

| Brief asked | This document says | I3 does |
|---|---|---|
| Per-field chroma in the window renderer, scopes, export **and** the SDI/HDMI v210 path | §8 I3: `passthroughFragment` reconstructs 4:2:0 chroma from the same field. §1: every consumer reads the one offscreen ring it writes | One change, in the fragment. The v210 kernels do horizontal chroma work only (pair average / co-sited / halfband) and read their own row (§2), so they are unchanged |
| H.264, HEVC, MPEG-2 4:2:0 | Streams are I6; HEVC interlaced files are field sequences (§10.6 finding 6) | Files only. A field sequence is one field per picture, already per field, and keeps the progressive upsample (`picturesAreFields`). MPEG-2: AVFoundation decodes it (measured), so it is included |
| Pass band "within a stated tolerance" | §9 P6: ≥ 99.9 % of rows within ±2 codes of their own field | P6's band, measured two ways (12.3) |

### 12.2 What changed

- **The filter** (`InterlacedChroma.taps`, FileScan; restated in `PassthroughShader.metal`, `sampleChromaOwnField`). 4:2:0
  chroma row c belongs to field c mod 2 (top field = even rows, whatever the temporal order) and sits at frame line
  2c + 0.5. That is MPEG-2's interlaced siting, and it is where the progressive sample already puts it, so only the
  neighbours change. Line y of field f interpolates the two nearest chroma rows of its own field: t = (y − 2f − 0.5) / 4,
  rows 2⌊t⌋+f and 2⌊t⌋+2+f, weight frac(t). The taps are 5/8·3/8 and 1/8·7/8 on the top field, 7/8·1/8 and 3/8·5/8 on
  the bottom, clamped within the field at the edges. Horizontally each row is sampled as before (8-bit-flagged buffers
  through the same quantised-texel filter).
- **The rule** (`InterlacedChroma.perField`): woven interlaced only (`isInterlaced && !picturesAreFields`). The renderer
  applies it per frame to **x420 buffers only** (`ColorParams.fieldChroma`); x422 and x444 have a chroma row per line.
- **Plumbing:** `FrameEngine.onSourceScan` is published on the geometry's edges (AVFoundation: same format description,
  before `beginReading`; libav: restated where the geometry is cleared, since the field structure survives the decode;
  false at unload and when there is no format description). `WindowDeck` passes it to
  `MetalVideoRenderer.setSourceInterlaced`, which parks it under `refreshLock` and installs it on the render thread
  beside the geometry, with a re-render. One `[SCAN] chroma:` line when a file turns it on, one when it goes off;
  progressive files log nothing new.
- **Tests:** `InterlacedChromaTests` (5): the rule; every line reads only its own field; the weights and edges; the siting
  equals the progressive siting; tiny planes stay in bounds.
- **Tools** (`scripts/interlaced/`): `i3field.py` + `generate-i3.sh` (the sharp fixture, below), `i3cmp.cpp` (the
  independent reference and comparison), `vtprobe.swift` / `vtdump.swift` (what VideoToolbox hands Manifold, read-only).

**The sharp fixture** (`build/interlaced-fixtures/i3/`). It is written directly as Y'CbCr, with the raw input tagged
BT.709 limited so FFmpeg converts nothing. (Untagged, FFmpeg read the input as 601 and rematrixed it on the way to the
encoder; the first encode was thrown away for that.) Luma is constant (128 / 512). Field 1 and field 2 always carry
opposite colours, A (Cb 352, Cr 672) and B (672, 352), in three regions: uniform (x < 960, y < 540), 64-line bands
(x < 960, y ≥ 540) and 64-pixel bars (x ≥ 960). It is made as H.264 MBAFF TFF and BFF, MPEG-2 TFF, ProRes 422 HQ TFF,
ProRes 4444 TFF and DNxHD 185x MXF TFF. FFmpeg's decode of each equals the written picture (H.264 exactly; the others
within 1 code).

### 12.3 Results (built and run unattended 2026-10-26, committed `afce63d`)

**Estimated** 5 h (band 3½–7). **Actual** about 1 h from the predictions to the last loop run, plus this record. No
attended steps, no screenshots, no keystrokes; every app quit by a Quit event to the bundle path. Runs, logs and exports:
`build/interlaced-i3/`.

**Two references.** The independent one is FFmpeg's decode of frame 0, split into fields and upsampled per field with
the filter above (8-bit widened ×4). The second is the same per-field filter applied to **VideoToolbox's own x420
delivery** of frame 0 (`vtdump`, read-only), i.e. the buffer Manifold's shader actually receives. The first measures the
whole chain against the file. The second measures I3's shader alone. They differ because the decode does not hand
Manifold the file's chroma (12.4). The model was validated first: HEAD's export against the *progressive* filter on the
VideoToolbox planes matches within 1 code on the v210 and 0.17 code in the offscreen (100 % of rows).

| # | Measured | Verdict |
|---|---|---|
| A1 | Sharp H.264 TFF and BFF, v210 and offscreen (`.rgba16f` back to Y'CbCr). **Against the VideoToolbox-plane per-field reference:** 1080 / 1080 rows within ±2, max 1 code (v210), 0.19 code (offscreen). **Against FFmpeg's per-field reference:** 1 / 1080 rows, chroma off by 80 codes, every row | Shader **PASS**; whole chain **FAIL** (the decode, 12.4) |
| A2 | Bleed on the uniform region, per row. HEAD: mean **50.0 %** (rows alternate 62.5 / 37.5 %, the two-field mix). Tree: **25.0 %** on every row, exactly VideoToolbox's 25 % (12.4). MPEG-2: 49.9 % on both (Apple's decoder mixes the fields) | **FAIL** against the ≤ 1 % band. I3 removed Manifold's share (50 → 25 %); the rest is in the decoded buffer |
| A3 | testsrc2 H.264 MBAFF TFF / BFF and the I2 H.264 marker. Against the VideoToolbox-plane per-field reference: ≥ 99.96 % within ±2, max 3, 1080 / 1080 rows. Against FFmpeg per-field: chroma max 581 → 232 (HEAD → tree), rows within ±2 34.8 % → 60.3 % | Shader **PASS**; whole chain **FAIL** (decode) |
| A4 | Not as predicted: Manifold's H.264 luma equals FFmpeg's ×4 exactly (max 0, every file). AVAssetReader's x420 gives luma 514 for 128 (full scale), so the app's luma path differs from that reader's; its chroma does not | prediction wrong; no offset in luma |
| B1 | 4:2:2 and 4:4:4 interlaced (ProRes HQ TFF / BFF / 50 / PsF / both disagreeing, DNxHD MXF TFF / BFF and `.mov`, the six 4:2:2 I2 markers, the halved file, sharp ProRes 422 / 4444 / DNxHD): `.rgba16f`, `.v210`, `.v210.json` **byte-identical to HEAD**, every file | **PASS** |
| B2 | Sharp ProRes 422 / DNxHD / ProRes 4444 on HEAD and tree: rows alternate exactly 352 / 672 (no vertical filter in the x422 / x444 path); bars edge as designed (4:4:4 shows the D3 halfband) | **PASS** |
| C1 | 20-file control set: 60 / 60 files byte-identical, PNG 20 / 20 byte-identical. The progressive ProRes control and three progressive probes (8-bit H.264, 8-bit MPEG-2, 10-bit HEVC of the same sharp picture): byte-identical | **PASS** |
| C2 | HEVC field sequence: byte-identical (no `[SCAN] chroma` line) | **PASS** |
| D1 | v210 luma on every changed file: 0 samples differ from HEAD | **PASS** |
| E1 | §11.3's gaps, attributed (12.4) | **PASS** (each part named) |
| F1 | Loop, SDI, tree and HEAD on sharp H.264 TFF / BFF, MPEG-2, ProRes 422 and testsrc H.264 TFF: `D4a … → mode 1080i59.94` and bridge `mode: 1080i59.94 (… interlaced, upper field first)` identical on both; input `Hi59`, field dominance upper | **PASS** (mode lines). Temporal field order was not re-measured: I3 touches no mode, placement or scheduling code; the I2 marker runs stand |
| F2 | Every received frame equal to the read-back: 131 / 131, 131, 131, 131, 130 (tree), the same on HEAD; **while playing**, sharp TFF 130 / 130 and BFF 130 / 130. The read-back equals the export `.v210` (tree 6 / 6, HEAD 4 / 4) | **PASS** |
| F3 | `late=0 dropped=0` on all 12 loop runs | **PASS** |
| G1 | `swift test` **631 / 631** (626 + 5) | **PASS** |
| G2 | Profile warnings: the same 11 on HEAD and tree (and as I2's set) | **PASS** |
| H1 | 21 keys added, all `NSWindow Frame …`; each read, then deleted. Final domain dictionary-equal to the snapshot; `streamBookmarks` hash unchanged; licence keys stripped from the snapshot (presence only), never written | **PASS** |

### 12.4 Where the rest of the bleed comes from: the decode (measured, read-only)

The same sharp picture, through `vtprobe` (AVAssetReader at Manifold's request, x420, and at 8-bit `420v`), and through
Manifold's export:

| Source | x420 chroma rows (Cb) | 420v | Manifold HEAD export |
|---|---|---|---|
| H.264 8-bit MBAFF TFF (rows 352 / 672 coded) | 432 / 592 alternating: each row 75 % own field, 25 % the other ([1 6 1]/8 vertically) | 88 / 168: the coded values | x420's rows, bilinear |
| H.264 8-bit **progressive**, same picture | 432 / 592, the same filter | 88 / 168 | the same |
| MPEG-2 8-bit interlaced | 433, 513, 513 …: the fields fully mixed | 108, 128, 128 …: mixed too | the same |
| MPEG-2 8-bit progressive | 353 / 674: the coded values (full-scale widening) | 88 / 168 | clean |
| HEVC Main 10 progressive | — | — | raw 352 / 672 through the bilinear: clean |

1. **8-bit H.264 → x420 (VideoToolbox's 8→10-bit delivery) filters chroma vertically by [1 6 1]/8**, interlaced or not.
   At `420v` the chroma is exact. So on an 8-bit interlaced H.264 file 25 % of the other field remains after I3, and every
   8-bit H.264 file (progressive too) loses vertical chroma detail to this filter. **Not changed here:** the remedy is to
   ask for `420v` on 8-bit 4:2:0 files and widen ×4 in the shader (the 8-bit path that exists for live sources). That
   changes the decode format, scrub and playback together, and the pictures of every 8-bit H.264 file, progressive ones
   included, which I3 must not. Recorded in BUGS.md as its own item. **Fixed for files 2026-10-26** (§13, commit
   `3c9d17a`): 8-bit 4:2:0 files decode to `420v`; bleed 25 % → 0.000 %.
2. **Apple's MPEG-2 decoder mixes the two fields' chroma on interlaced coding,** at either format. Manifold cannot undo
   it. A field-correct MPEG-2 needs another decoder (decision 7's libav question).
3. **§11.3's H.264 luma max 76 and DNxHD max 9 were not Manifold.** Against FFmpeg's frame 0 widened ×4, HEAD's H.264
   read-back luma is identical (max 0), and the DNxHD read-backs (MXF TFF / BFF, `.mov`) are identical in luma **and**
   chroma (max 0); ProRes is within 1. The 4:2:2 chroma max 60 is also gone. So those gaps came from I2's reference. How
   I2 built it was not kept, so which step introduced them is UNKNOWN. The luma can never have been cross-field chroma:
   the offscreen is float and unclamped, so luma survives the R'G'B' round trip whatever the chroma.
4. **§11.3's 4:2:0 chroma max 361** was Manifold's two-field mix plus the decode's filter, measured against a reference
   that itself upsampled progressively. With I3, testsrc H.264 against FFmpeg's per-field reference: max 581 → 232; the
   232 is item 1.
5. **Not measured:** a 4:2:2 file that falls back to 4:2:0 (`chromaFallback`, or the DEBUG force) would be reduced to
   4:2:0 by VideoToolbox or sws progressively, mixing fields, before I3's upsample. No fixture falls back.
6. **Not in I3:** the display copy's bilinear resample still blends lines of the two fields away from 100 % (§3; I4's
   job). It reads the corrected offscreen.

**Done for files, with the decode's limits:** Manifold no longer mixes the fields of a 4:2:0 picture anywhere (window,
scopes, export and SDI all read the corrected offscreen). P6 is met against what the decoder delivers. Against the file
it is not met for 8-bit H.264 (item 1, fixable) or MPEG-2 (item 2, the decoder). **Since §13:** met for 8-bit H.264
(and 8-bit HEVC) against the file; MPEG-2 unchanged.

## 13. 8-bit 4:2:0 files decoded to `420v` (§12.4 item 1): scope, predictions, results

**Written 2026-10-26 17:14 EDT, before any probe, code change or build, against `afce63d`.** Predictions with their
timestamp and hash: `build/h264-chroma/predictions.md`, `predictions.timestamp`. Run unattended; no attended steps, no
screenshots, no keystrokes; every app quit by a Quit event to the bundle path. Commit `3c9d17a`.
Runs, logs and exports: `build/h264-chroma/`. **Estimated** 4½ h (band 3–6½). **Actual** about 1¼ h (17:14–17:20, then
18:30–19:30), with a pause between (the Mac was needed) before the first probe or build.

### 13.1 Measured first (read-only)

`scripts/interlaced/vtplanes.swift` decodes frame 0 through the three routes Manifold uses (the playback reader
`AVAssetReaderTrackOutput`, the scrub output `AVPlayerItemVideoOutput`, and a `VTDecompressionSession` with
`LiveVideoDecoder`'s attributes, the SRT / WHEP decoder), each at x420 and `420v`, and compares every plane with FFmpeg's
decode ×4 (`build/h264-chroma/measure/step1.txt`). x420 is shown raw and as the shader takes a flagged 8-bit buffer (low
two bits cleared).

| Source (frame 0) | x420, low bits cleared | `420v` |
|---|---|---|
| 8-bit H.264: progressive sharp probe, sharp TFF / BFF | luma max 0; chroma max 80, mean 79.3 (rows 432 / 592 for coded 352 / 672) | luma and chroma max 0 |
| 8-bit H.264: testsrc MBAFF TFF / BFF, I2 marker, cadence file, `caseg`, `patches-9-14-9`, `still-420` | luma max 0; chroma max 100–240, 79–99 % exact | max 0, 100 % |
| 8-bit HEVC (generated: `scripts/interlaced/generate-h264-chroma.sh`; the repo had none) | as the H.264 sharp probe | max 0 |
| MPEG-2 8-bit progressive / interlaced | the same as `420v` | max 80 / 324 (Apple's decoder) |

The three routes agree to the code on every file: the filter is in VideoToolbox's 8→10-bit delivery, not in a route.
So the fix applies to every 8-bit 4:2:0 file with an SPS (H.264 and HEVC). MPEG-2 gains nothing from it. **Streams
carry the same filter** (route `vt`); they are not changed (BUGS.md, *8-bit H.264 / HEVC streams …*).

### 13.2 What changed

- `FileChromaResolver.carrier(for:eightBitSource:)`: 8-bit 4:2:0 by the SPS → `420v`
  (`ChromaSubsampling.eightBitCarrier420`); every other file keeps its 10-bit carrier. One answer for scrub and playback.
- The renderer samples `420v` as r8 / rg8 and always through the 8-bit path of `3c911fb`: `exactTimes4` of n/255 is
  floor(n·(1 + 1/256) + 1/1024) = n, so 4n exactly, for every n ≤ 255. The I3 per-field sample reads quantised texels
  the same way. No shader arithmetic changed.
- `ChromaSubsampling(sampledFormat:)` / `sampledBitDepth`: the renderer (I3's `fieldChroma`, the v210 mode, the 4:2:2
  shift), the chain readout (`4:2:0 8-bit (420v) — native`) and `[CHROMA-FILE]` name `420v`. `init?(pixelFormat:)`
  is unchanged, so the live promotes decide as before.
- `FrameEngine.chromaFallback`: a decoder that refuses `420v` falls back to x420 for both decoders, with a banner that
  says vertical colour detail is softer. Not seen in any run.
- Tests: `testEightBitFourTwoZeroDecodesToTheEightBitCarrier`, `testTheEightBitCarrierIsSampledAsFourTwoZero`.

### 13.3 Results

| # | Measured | Verdict |
|---|---|---|
| M1–M3 | Playback reader, scrub output, VT session: x420 filtered, `420v` exact (max 0), every 8-bit H.264 file | **PASS** |
| M4 | 8-bit HEVC: x420 filtered the same way, `420v` exact (the 50 % prediction held) | **PASS**; HEVC included |
| M5 | MPEG-2 8-bit: the same at both formats; not flagged, not changed | **PASS** |
| F1 | Progressive 8-bit H.264 / HEVC against FFmpeg ×4 (progressive filter): v210 luma max 0, chroma max 0 (sharp) / 1 (testsrc-like); 1080 / 1080 rows within ±2; offscreen within 0.42 code. HEAD: chroma max 80–175. `caseg` and `patches-9-14-9` carry a BT.2020 matrix, so only their v210 is compared (i3cmp converts the offscreen with 709): max 1, HEAD 78 | **PASS** (expected 0; band ≤ 1, the v210 pair average) |
| F2 | Sharp H.264 TFF and BFF, per-field reference: v210 chroma max **0**, 1080 / 1080 rows; bleed **25.000 % → 0.000 %** (v210), 0.005 % (offscreen) | **PASS** |
| F3 | testsrc MBAFF TFF / BFF and the I2 marker, per-field: chroma max 231–235 → **1**, 1080 / 1080 rows within ±2 (HEAD 645–684) | **PASS** |
| F4 | 43 / 54 exported files byte-identical to HEAD in `.rgba16f`, `.v210`, `.v210.json` and PNG pixels: the 20-file control set's non-H.264 files, the interlaced 4:2:2 / 4:4:4 set, the HEVC field sequence, HEVC Main 10, ProRes, DNx, MPEG-2 | **PASS** |
| F5 | The 11 that differ are exactly the 8-bit H.264 / HEVC files (one flat 8-bit H.264 clip, `manifold-sync-29.97p`, is identical). v210 luma identical to HEAD on every one (max 0 against FFmpeg on both builds) | **PASS** |
| F6 | SDI loop, tree, paused and playing, sharp TFF, progressive H.264 and HEVC: every received frame equals the read-back (131, 128, 129 paused; 127, 128, 130 playing; 0 different); every read-back equals the export `.v210`; modes `1080i59.94` / `1080p29.97` as before. The scopes read the same offscreen | **PASS** |
| F7 | 8-bit H.264 1080p29.97, output on, 2 × 30 s per build: CPU 20.1 / 18.2 % (HEAD), 19.4 / 19.8 % (tree); GPU 0.091 ms a frame on both; late = 0 dropped = 0 | **PASS** (within noise) |
| F8 | Readout `[CHROMA] 4:2:0 8-bit (420v) — native`, `[CHROMA-FILE] … → 420v 4:2:0 · 8-bit source (exact ×4)`, `[BITDEPTH] 8-bit source …`; no fallback | **PASS** |
| G1 | `swift test` 633 / 633 (631 + 2) | **PASS** |
| G2 | Profile warnings: the same 11 as HEAD (clean builds) | **PASS** |
| H1 | 14 keys added, all `NSWindow Frame …`; each read, then deleted. Final domain dictionary-equal to the snapshot; `streamBookmarks` hash unchanged; licence keys stripped from the snapshot (presence only), never written | **PASS** |
| S1 | Streams: measured (13.1), not changed | as predicted |

## 14. I4 — display options (files): scope, predictions, results

**Written 2026-10-27 14:19 EDT, before any code change or build, against `16b6a63`** (the only uncommitted change is the
three commit hashes filled into BUGS.md and RELEASE_NOTES.md). Predictions with their timestamp and hash:
`build/interlaced-i4/predictions.md`, `predictions.timestamp`. Results follow. Nothing above this section was changed by I4.

**Estimated run time: about 5½ h (band 4–8).** Model, renderer, shader and UI ~2 h; HEAD and tree Profile builds ~25 min
(the HEAD build runs while the code is written); driver changes ~30 min; unattended runs ~1 h 15 min (about 25 interlaced
files × 4 views and the 24-file progressive set on both builds, the SDI loop in each view, idle and playback cost); analysis
and this record ~1 h. No attended steps; the by-hand checklist (14.6) is for Robbie afterwards.

### 14.1 Scope: where the I4 brief and this document differ (the document wins)

| Brief asked | This document says | I4 does |
|---|---|---|
| "The chain readout row" | §4: "1080i59.94 TFF" on the **Source** row, **and** a "Fields" row after Transform | Both |
| Inspector shows scan, field order **and the active display option** | §4: the Inspector Scan row (I1); the mode is the chain readout's | The Scan row as I1 built it, plus a **Window View** row under it while a woven interlaced file is loaded (decision 9; the doc does not rule it out) |
| Export and scopes measure the file as stored "unless the doc says otherwise" | The header: **scopes, SDI and export always measure the woven frame, never the display view**. §3: never deinterlace into the offscreen ring | All three read the offscreen ring, unchanged. The view is drawn into a separate display-only texture |
| True bob unless the doc puts it in I4 | Decision 4 and §8: bob is **I5, after 1.0** | Not built. No conflict |
| PAFF / MBAFF where decodable | §6, §10.6 finding 5: no free tool makes PAFF | MBAFF H.264 only; no PAFF fixture exists |
| Window output by export or offscreen read-back | §3: the view goes into a separate texture between the offscreen pass and the display copy | That texture is read back (a DEBUG-only, launch-environment switch adds it to Export Frame for Support; decision 10). The drawable itself is not read back. The copy pass that scales the texture to the window is unchanged code |
| — | §3: "No shortcut until the shortcut registry" | The registry exists now; no default key is given (decision 8) |
| — | §3: a window-title suffix when not Weave | Built. The title bar is hidden, so in the window the label is a control-bar badge, as for Bypass (decision 7) |

### 14.2 Decisions for Robbie

Where the document leaves a choice open, the most conservative option was built (the picture as stored, fields woven,
nothing hidden). Each can be changed later without touching the output path.

**Robbie, 2026-10-27 (after `3f7daad`):** decisions 1–6 and 8–10 are **accepted, subject to his by-hand checklist tonight**
(14.6). Decision 7 is **changed**: a field view also shows a small marker on the picture that stays visible in full screen
and with the controls hidden (14.8).

1. **"Field 1" is the first field in time**, from the detected field order, and every label says which raster field that
   is ("Field 1 — bottom field, first in time" on a BFF file). The alternative is SMPTE numbering, where field 1 is
   always the top field. With no order stated, Field 1 is the top field and the label says the order is not stated.
2. **Field 1 / Field 2 repeat each line of the chosen field** (stored samples only, no interpolation). The two views sit
   half a field line apart vertically, as any line-doubled field does.
3. **Deinterlace keeps Field 1 (first in time)** and fills the other field's lines with the average of the lines above and
   below in the kept field (edges repeat the nearest line). It does not adapt to motion. Display only, one picture per frame.
4. **The options are offered only for woven interlaced files** (I3's rule, `InterlacedChroma.perField`). Progressive and
   unknown files, HEVC field sequences (each picture already one field) and live sources (I6) get no control. The Color
   menu items are there but disabled.
5. **Every source change resets the view to Weave** (a new file, an unload, a live takeover), so a field view never
   carries over to a file nobody chose it for. Same reasoning as the display transform's reset (`WindowChrome`).
6. **Not saved, per window, default Weave** (decision 5 of §7, as given).
7. **The labels:** a yellow control-bar badge ("FIELD 1 · DISPLAY ONLY"), a title suffix (" — Field 1 (display only)") for
   the Window menu and Mission Control, the chain readout's Fields row, the Inspector's Window View row, and a `[FIELDS]`
   log line. ~~**Nothing is drawn over the picture.** The badge hides with the overlay HUD, and full screen has no marker:
   Bypass's accepted limit (COLOR_MANAGEMENT_FINDINGS.md §6.8).~~ **Changed by Robbie, 2026-10-27:** a marker on the
   picture as well, visible in full screen and with the controls hidden (14.8).
8. **No default keyboard shortcut.** The menu items are plain menu items, not registry entries.
9. **The Inspector's Window View row** (above). Shown only while the options are offered.
10. **The measurement read-back:** `MANIFOLD_DISPLAY_READBACK=1` (DEBUG builds only, launch environment) makes Export Frame
    for Support also write `<name>.display.rgba16f` and `<name>.display.json`: the texture the display copy sampled. Unset,
    the export is unchanged. Listed for pre-ship removal beside `MANIFOLD_FRAME_EXPORT_DIR`.

### 14.3 Predictions

Fixtures: I1's 16 files (ProRes TFF / BFF / 50 / PsF / both disagreeing files; DNxHD MXF TFF / BFF and `.mov`; H.264 MBAFF TFF / BFF;
the HEVC field sequence), I2's 8 marker files (TFF, BFF, 50, 60, DNxHD MXF, H.264 MBAFF, 1440×1080, the halved file), I3's
6 sharp files. Progressive set: I1's 20 control files, the progressive ProRes control and I3's three progressive probes (24).
Every export is at frame 0, paused. "Per-field reference": computed from the same export's woven `.rgba16f` by 14.2's rules,
outside the app.

| # | Prediction | Pass | Fail |
|---|---|---|---|
| W1 | **Weave, the default**, every interlaced fixture: `.rgba16f`, `.v210`, `.v210.json` byte-identical to HEAD; PNG pixels and ICC equal; the display read-back equals the `.rgba16f` (the display copy samples the offscreen itself); no field pass runs (no `[FIELDS]` line at load) | every file, every byte | any byte |
| F1 | **Field 1 / Field 2**: the display read-back equals the per-field reference, byte for byte, every offered fixture | 100 % of bytes | any byte |
| F2 | **Which field, by the markers** (TFF, BFF, 50, 60, DNxHD, H.264, 1440): in Field 1 every row of the band reads picture N with a valid check pattern, in Field 2 N + 1; on the BFF file Field 1 comes from the odd (bottom) rows. Deinterlace reads N on every row | every row, every file | any row |
| F3 | **Deinterlace**: the kept field's rows byte-identical to the woven frame; the filled rows within 1 half-float ULP of the float32 mean of their two neighbours | max ≤ 1 ULP; ≥ 99.99 % exact | otherwise |
| F4 | **Labels**, per view, read by Accessibility and the log: badge, title suffix, Color menu check, chain `[CHAIN] Fields:` line, Inspector Window View row; Weave shows no badge and no suffix | exact words | any miss |
| R1 | **Chain Source row** begins "1080i59.94 TFF" / "1080i59.94 BFF" / "1080i50 TFF" / "1080i60 TFF"; the 1440 file reads "1080i59.94 TFF"; the halved file "1080i59.94 TFF"; the HEVC field sequence "field sequence, TFF". Inspector Scan rows as I1/I2 | exact | any miss |
| S1 | **Output untouched by the view**: in Field 1, Field 2 and Deinterlace, every fixture's `.rgba16f`, `.v210`, `.v210.json` and PNG byte-identical to its own Weave export and to HEAD's | every file, every view | any byte |
| S2 | **SDI loop, paused**, five fixtures (marker TFF, BFF, 1440, DNxHD MXF, sharp H.264 TFF) in each of the four views: every received frame equals HEAD's bridge read-back (`[SDI-DUMP]`) of the same file; mode `1080i59.94` | 0 different frames | any |
| S3 | **SDI loop, playing**, marker TFF and BFF in Field 1 and Deinterlace (15 s): fields in temporal order as I2's T1 / T2 (TFF: 0 swapped; BFF: untouched, top N+1 / bottom N); card `late=0 dropped=0` | as stated | any swap, late or drop |
| P7 | **Scopes** (§9 P7): waveform, parade, vectorscope and CIE images (`MANIFOLD_SCOPE_DUMP_DIR`) byte-identical across the four views and to HEAD's, paused at frame 0; a view change publishes no scope image | identical, no publish | any difference |
| C1 | **Progressive set**, 24 files: exports byte-identical to HEAD (`.rgba16f`, `.v210`, `.v210.json`, PNG pixels); no field control in the window (Accessibility), the Color menu's field items disabled; no `[FIELDS]` or `[CHAIN] Fields` line; `[CHAIN] Source` lines identical to HEAD's | 24 / 24 | any |
| C2 | **HEVC field sequence**: not offered (no control, items disabled); exports byte-identical to HEAD | as stated | otherwise |
| T | **Playback** (window, no output), marker TFF in each view, 10 s: Manifold's `[RENDER-PERF]` late and dropped counts 0, the same as Weave | 0 | any |
| I | **Cost**: paused and idle for 30 s in Field 1, the display link stops as in Weave; CPU within 0.5 points of Weave. Playing, the GPU time per frame rises by ≤ 0.05 ms (one 1080 compute pass); scope publishes per second equal to Weave's (±1). Weave: no change from HEAD | as stated | otherwise |
| L | **Logs**: on the progressive set every line identical to HEAD's, apart from launch and quit timing as in §10.6 L; on interlaced files the only additions are `[FIELDS]` lines, `[CHAIN] Fields` lines and the "1080i…" prefix on `[CHAIN] Source` | as stated | any other change |
| G | `swift test`: all pass, 633 plus the new tests. Profile warnings: the same 11 as HEAD (clean builds, paths and lines normalised) | as stated | any failure or new warning |
| D | Defaults: the domain dictionary-equal to the snapshot after the runs (window-frame keys read, then deleted, stopping at the first failure); `streamBookmarks` hash unchanged; licence keys stripped from the snapshot (presence only), never written | equal | any difference |

### 14.4 Results

Run unattended 2026-10-27, 14:19–16:33 EDT; committed as `3f7daad` (**about 2¼ h against the 5½ h estimate**, below the 4 h end of the band).
Every measured pixel number is from the export's `.rgba16f` / `.v210` and the DEBUG display read-back, never from the screen;
no screenshots. Analysis: `build/interlaced-i4/analyze.py` (`an-interlaced.txt`, `an-progressive.txt`, `an-cie.txt`,
`an-confirm.txt`); per-field reference `scripts/interlaced/i4cmp.cpp`.

| # | Result | Verdict |
|---|---|---|
| W1 | 26 interlaced files, Weave: `.rgba16f`, `.v210`, `.v210.json`, PNG byte-identical to HEAD; display read-back = the `.rgba16f` on all 26. **But** every interlaced load and unload logged `[FIELDS] window view → WEAVE` and queued one redundant redraw: the renderer's setter treated a field-order change as a view change. Fixed (`setFieldView` parks the order without a log, redraw or wake while the view stays Weave); the confirmation pass on the final build logs no `[FIELDS]` line at load and stays byte-identical to HEAD | **MISS, fixed** (pixels passed throughout) |
| F1 | Field 1 and Field 2 on all 25 offered files: display read-back = per-field reference, **100 % of halves, 0 ULP** (TFF, BFF, 50, 60, PsF, DNxHD MXF and `.mov`, H.264 MBAFF TFF / BFF, 1440×1080, both disagreeing files, the sharp set) | **PASS** |
| F2 | 7 marker files: Field 1 reads N and Field 2 N + 1 on every band row, check pattern intact on all; BFF Field 1 from the odd rows; Deinterlace N on every row | **PASS** |
| F3 | Deinterlace: kept rows byte-identical; filled rows max **1 ULP** from the round-to-nearest mean, 98.62–100 % of halves exact. **100 % exact against a round-toward-zero reference** on every file: the GPU's float → half store rounds toward zero | **MISS** on the ≥ 99.99 % band (the prediction assumed round-to-nearest); max ≤ 1 ULP held. No change |
| F4 | Per view, by Accessibility: badge "FIELD 1 · DISPLAY ONLY" etc., title suffix " — Field 1 (display only)", the Color ▸ Fields check, the control "Fields: Field 1", Inspector Window View "Field 1 — bottom field, first in time (display only)" on BFF; Weave none of them; `[CHAIN] Fields:` lines name the view, field and order and say DISPLAY ONLY | **PASS** |
| R1 | `[CHAIN] Source` prefixes: 1080i59.94 TFF / BFF, 1080i50 TFF, 1080i60 TFF, 1440 file "1080i59.94 TFF", HEVC "field sequence, TFF". **But** 22 transient lines read "0i TFF": the scan arrives before the metadata's height. Fixed (`chainPrefix` says "interlaced, TFF" until the height is known; unit-tested); confirmed on the final build | **MISS, fixed** |
| S1 | All 25 offered files in Field 1, Field 2, Deinterlace: `.rgba16f`, `.v210`, `.v210.json`, PNG byte-identical to the file's Weave export and to HEAD | **PASS** |
| S2 | SDI loop (8K Pro, device 0, SDI input locked; probe read SDI after every capture), paused, 5 fixtures × 4 views: every `[SDI-DUMP]` read-back byte-identical to HEAD's for the same file; every received frame = the read-back (126–131 per run, **0 different**); mode 1080i59.94 'Hi59', dominance upper; late = 0 dropped = 0 on all 29 output stops | **PASS** |
| S3 | SDI loop playing 15 s, marker TFF and BFF in Field 1 and Deinterlace (I2's `marks.py`): 0 swapped, 0 broken, 0 skipped; TFF top N / bottom N+1, BFF untouched top N+1 / bottom N; **no repeated frame while playing** (the ~200 repeats each run counts are the hold on the 10 s clip's last frame, fields 598/599); late = 0 dropped = 0 | **PASS** |
| P7 | Waveform, parade, vectorscope (and CIE, waveform, parade in a second pass) byte-identical across the four views and to HEAD on every file. **A view change does re-publish the scopes once** (sequence + 1): the redraw re-samples the unchanged offscreen frame | **MISS** on "no publish" (images identical). No change: one recompute per user action |
| C1 | 24 progressive files: exports and scopes byte-identical to HEAD; choosing a view changes nothing (display = woven, no badge, suffix or check); no `[FIELDS]` line except the DEBUG read-back's own; `[CHAIN] Source` lines identical to HEAD's (HEAD logs one more "no source" at quit, timing). The Fields **items** are disabled; the Fields submenu's own AXEnabled reads true (SwiftUI reports a submenu enabled while its items are disabled) | **PASS** |
| C2 | HEVC field sequence: not offered (items disabled, no control, badge or suffix, display = woven); exports = HEAD; chain "field sequence, TFF" and Fields "each picture is one field — shown as stored (no field views)" | **PASS** |
| T | Window playback, marker TFF, 10 s per view, one launch per view: 30–31 frames presented every second in all four (as Weave and HEAD), tick max ≤ 9.36 ms while playing. `[RENDER-PERF]` has no late / dropped counter on the window path, so the prediction's metric does not exist; judged on frames presented, and on the card's late = 0 dropped = 0 (S2, S3) | **PASS** (metric restated) |
| I | Paused: the display link stops ~62 ticks after a view change, as after a Weave redraw; CPU 0.03 / 0.04 / 0.13 / 0.04 % (Weave / Field 1 / Field 2 / Deinterlace; HEAD Weave 0.05 %). Playing: GPU 0.087 / 0.116 / 0.113 / 0.114 ms a frame (HEAD Weave 0.085): **+0.03 ms**; scope publishes 30 / 30 / 30 a second in every view (vectorscope 29 once in Deinterlace) | **PASS** |
| L | Logs, normalised for timing, window numbers and pids: no line other than `[FIELDS]`, `[CHAIN] Fields` and the Source prefix differs from HEAD's. The `CVDisplayLinkStart → -6660` recovery appears in both builds' runs (BUGS.md, known) | **PASS** |
| G | `swift test` **641 / 641** (633 + 8). Clean Profile builds: **12** warnings on HEAD and on the tree after normalising, identical sets (the prediction's "11" was taken from the I3 record; which line is new since then was not traced) | **PASS** (count restated) |
| D | Defaults: 46 `NSWindow Frame` keys added by the runs, each read then deleted (`set -e`); the domain is then dictionary-equal to the snapshot; `streamBookmarks` 18c6da5dbe73c5e4 unchanged; licence keys present before and after (3, values never read out), never written; `showTray` false throughout (launch argument only) | **PASS** |

### 14.5 Findings

1. **The multi-window driver trap.** `open -a` gives each file its own window, and Color / Help act on the key window; the first
   full run therefore exported the first file's window again and again. The driver now closes every window after each file
   (AX close button) and warns on a second window. The first run's results were discarded; I3's exports were checked and
   were not affected.
2. **The GPU rounds toward zero** storing float to half (F3). The deinterlace is exact against that rounding; nothing to fix.
3. **A view change re-publishes the scopes once** (P7), with identical images.
4. **The renderer logged Weave at every load** (W1) and **the chain said "0i TFF" for a moment** (R1); both fixed and re-run.
5. **SwiftUI's submenu AXEnabled** stays true while its items are disabled; the items are what grey out. The checklist asks
   Robbie to confirm it reads as disabled.
6. **`predictions.md` says "Written … 14:25"**; its hash and `predictions.timestamp` (14:19:26) were taken before any change,
   and this document's header was corrected to 14:19. The copy was left as hashed.
7. **The analysis scripts had three bugs of their own**, found and fixed before any result was taken from them: a two-space
   regex in the marker decode, "offered" read from the submenu flag (finding 5), and the field order read from the
   disagreement warning on `prores-disagree-fielbff` (whose resolved order is TFF, from the ProRes header).

### 14.6 By-hand checklist for Robbie

Unattended runs read the view's texture, not the screen. These checks need eyes. Do the HDR and by-eye checks on the
**LG**, and use the ASUS only for pixel values. Fixtures: `build/interlaced-fixtures/i2/` (markers) and `i3/` (sharp).

1. **Open `mark-prores-1080i5994-tff.mov`.** The control bar shows a second pulldown, **Weave**, beside the display-transform
   one. Open a progressive file: the pulldown is gone, and Color ▸ Fields' items are greyed. (Their submenu is not greyed;
   finding 5. Is that acceptable?)
2. **Field 1, then Field 2** (from the pulldown, or Color ▸ Fields). The yellow badge reads "FIELD 1 · DISPLAY ONLY". At 100 %
   the counter's edges show stair-steps two lines tall (line repeat), with no comb. Field 2 shows the next picture number
   and sits half a field line lower. The waveform does not move. In the Window menu, the window's name ends
   "— Field 1 (display only)".
3. **BFF** (`mark-prores-1080i5994-bff.mov`): Field 1 shows the *lower* of the two numbers, and the Inspector's Window View row
   says "bottom field, first in time". Step frames in Field 1: the counter goes up by 2 each step on both files.
4. **Deinterlace** on `h264-sharp-1080i5994-tff.mov` and the moving `prores-1080i5994-tff.mov`: no combing at any window size,
   and vertical detail softer than Weave (one field's lines). Judge whether this is the deinterlace you want for 1.0
   (decision 3).
5. **The chain readout** (pulldown ▸ Show Transform Chain…): Source begins "1080i59.94 TFF". A **Fields** row after Transform
   names the view and says DISPLAY ONLY, and the footnote says "these settings".
6. **Open another file** while in Field 1: the window returns to Weave (decision 5). Is that what you want?
7. **DeckLink output on** in each view: the reference monitor shows the same woven 1080i59.94 picture in all four. The TFF
   counter steps once per field. The BFF file judders, with the warning. Nothing on the monitor changes with the view.
8. ~~**Full screen and the auto-hiding HUD:** with the HUD hidden there is no field marker on screen (Bypass's limit). Decide
   whether a field view needs a marker drawn over the picture (decision 7).~~ Decided: a marker; check it with 14.8's
   items.
9. **Decisions 1–10** (14.2): especially 1 (Field 1 = first in time, not SMPTE's top field) and 8 (no default shortcut).

### 14.7 What changed

- `Packages/ManifoldCore/Sources/FileScan/FieldView.swift` (new): the four views, which field each shows, every label, the
  shader mode, and `SourceScan.chainPrefix`. Tests: `Tests/FileScanTests/FieldViewTests.swift` (8).
- `FrameEngine.onSourceScan` passes the resolved `SourceScan` (`.notRead` at unload) instead of a Bool; the deck forwards
  `perField` to the renderer as before (I3) and takes the scan for I4.
- `App/PassthroughShader.metal`: `fieldViewKernel` (line repeat / deinterlace) into a display-only texture.
- `App/MetalVideoRenderer.swift`: `setFieldView` (main → render under `refreshLock`), the field pass between the offscreen
  encode and the display copy / Reference pass (Weave dispatches nothing: HEAD's path), and the DEBUG display read-back
  (`MANIFOLD_DISPLAY_READBACK`). The offscreen ring, scopes, v210 convert and export are untouched.
- `App/WindowChrome.swift`, `WindowDeck.swift`: per-window view state (not saved), the reset to Weave on every source change,
  `DeckRegistry.setFieldView` (the one mutator), and the title suffix.
- `App/DisplayTransform.swift` (Color ▸ Fields), `App/FieldViewControl.swift` (new: badge and pulldown),
  `App/DisplayTransformControl.swift`, `App/DisplayChainModel.swift` (Source prefix, Fields row), `App/InspectorPanel.swift`
  (Window View row), `App/ContentView.swift`, `project.yml` (the app links FileScan).
- `scripts/interlaced/i4cmp.cpp` (new): the per-field reference and marker decode used for F1–F3.

### 14.8 Decision 7 changed: a marker on the picture

**Robbie, 2026-10-27:** while Field 1, Field 2 or Deinterlace is on, a small, unobtrusive marker on the picture ("FIELD 1"
in the app yellow, in a corner, readable but not distracting), visible in full screen and with the controls hidden. Never
in Weave or on a progressive file. Window only: SDI / HDMI, scopes and export unchanged.

**Written 2026-10-27 17:09 EDT, before any code change or build, against `3f7daad`** (the only uncommitted change is the
commit hash filled into BUGS.md, RELEASE_NOTES.md and 14.4). Predictions: `build/interlaced-i4/marker/predictions.md`,
hashed with this section.

**Design.** A SwiftUI overlay on the aspect-fitted picture surface, the layer the framing guides and captions use (its
bounds are the displayed picture rect, so it follows letterbox, pillarbox and scaling). It is not part of the auto-hiding
HUD, so hiding the controls does not hide it, and full screen keeps the same content view. It is drawn by SwiftUI, never by
Metal: nothing reaches the offscreen ring, the display texture, the drawable's sampled source, the v210 convert or the
export. **Top-trailing corner of the picture**, 12 pt in: top-leading is where the window buttons and the raster-size notice
sit, and the bottom is the HUD's and the captions'. The words are the view's name in capitals ("FIELD 1", "FIELD 2",
"DEINTERLACE"), heavy rounded 11 pt, in the app yellow on a translucent black capsule, 85 % opacity, not clickable.
**New decision for Robbie (11):** the corner, size and opacity; and an Inspector opened over the same corner covers the
marker (the Inspector's Window View row says the same thing).

**Estimated run time: about 2¼ h (band 1½–3½).** Code ~20 min; builds ~10 min; driver ~20 min; unattended runs ~55 min
(the 26 interlaced and 24 progressive files in all four views, the marker states, two SDI loop runs, idle cost); analysis
and this record ~30 min.

**Reference.** HEAD's (`3f7daad`) pixels: its outputs were shown byte-identical to `16b6a63`'s in every view (14.4 S1, W1),
so the tree is compared with the I4 run's HEAD exports (`head-interlaced`, `head-progressive`) and with the I4 run's own
display read-backs and scope images (`tree-views`, `tree-progressive`; the two fixes made after those runs changed no pixel,
confirmed in 14.4).

| # | Prediction | Pass | Fail |
|---|---|---|---|
| K1 | **Shown when it should be**, by Accessibility: in Field 1, Field 2 and Deinterlace on every offered fixture, one marker reading exactly "FIELD 1" / "FIELD 2" / "DEINTERLACE", inside the window, in its top-right quarter | every file, every view | any miss |
| K2 | **Never otherwise**: no marker in Weave (before and after the views), on any of the 24 progressive files in any view, on the HEVC field sequence, and after opening another file from a field view | 0 markers | any |
| K3 | **Controls hidden**: Field 1 with the HUD unpinned and hidden (HUD element count back to its hidden value): the marker is still there, same text and frame | present | absent |
| K4 | **Full screen** (View ▸ Enter Full Screen, AX click), Field 1: the marker is there, in the screen's top-right quarter; after leaving full screen, still there | present both | absent |
| K5 | **Output, scopes and export unchanged**: all 26 interlaced files × 4 views and the 24 progressive files: `.rgba16f`, `.v210`, `.v210.json`, PNG byte-identical to HEAD's export; the display read-back byte-identical to the I4 run's for the same file and view; waveform, parade and vectorscope images byte-identical to the I4 run's | every byte | any byte |
| K6 | **SDI loop**, marker TFF in Field 1 and BFF in Deinterlace, paused: read-back byte-identical to HEAD's (I4 run), every received frame = the read-back, late = 0 dropped = 0 | 0 different | any |
| K7 | **Cost**: paused in Field 1 for 30 s the display link stops and CPU stays within 0.1 point of the I4 run's (0.04 %); the marker adds no `[RENDER-PERF]` work (it is not Metal) | as stated | otherwise |
| K8 | **Logs**: one `[FIELDS] marker` line per marker shown or hidden, nothing else new | as stated | any other change |
| G | `swift test` 641 plus the new marker test, all pass; the same 12 Profile warnings | as stated | any failure or new warning |
| D | Defaults: dictionary-equal to the snapshot after the runs (frame keys read, then deleted, stopping at the first failure); `streamBookmarks` unchanged; licence keys stripped (presence only), never written | equal | any difference |

### 14.8 Results

Run unattended 2026-10-27, 17:09–18:14 EDT (**about 1 h against the 2¼ h estimate**, below the band). No screenshots: the
marker is read by Accessibility (its text and frame), the pixels from the exports and the display read-back. Analysis:
`build/interlaced-i4/marker/kan.py`, the states driver `marker/drv-marker.py`.

| # | Result | Verdict |
|---|---|---|
| K1 | 25 offered files × Field 1, Field 2, Deinterlace (75 states): one marker each, text exactly "FIELD 1" / "FIELD 2" / "DEINTERLACE", in the window's top-right quarter (windowed: 12 pt in from the picture's top-right corner, e.g. x 914–970 in a window ending at 982, y 162 against its top 150) | **PASS** |
| K2 | No marker in Weave (both before and after the views), on the 24 progressive files in any view (120 states), or on the HEVC field sequence. **Not run:** "after opening another file from a field view". Only a drop loads a file into an existing window, and the driver cannot drag; the reset itself is I4's (decision 5) and stays on the checklist (14.6 item 6) | **PASS** (one part not run) |
| K3 | Field 1, controls unpinned and hidden (HUD elements 50 → 22, badge gone): the marker is still there, same text and frame | **PASS** |
| K4 | Full screen (`AXFullScreen` true, window 3840 × 2160): the marker is 12 pt in from the picture's top-right corner (x 3607–3663; the scopes tray takes height, so the picture is pillarboxed), changes with the view, gone in Weave; after leaving full screen, still there. View ▸ Enter Full Screen clicked by Accessibility returned without effect; the window's own full-screen button worked (not investigated) | **PASS** |
| K5 | 26 interlaced files × 4 views and 24 progressive files × 4 views: 800 output files (`.rgba16f`, `.v210`, `.v210.json`, PNG) byte-identical to HEAD's export, 200 display read-backs and 600 scope images byte-identical to the I4 run's. One file (`dnxhd-1080i5994-tff.mxf`) was re-run alone: on the full run, an Open panel came up as a second window when the file opened, so its Weave export was empty and its scope images were taken with the panel in front; re-run, it is byte-identical everywhere | **PASS** (after the re-run) |
| K6 | SDI loop, paused: marker TFF in Field 1 and BFF in Deinterlace: read-backs byte-identical to HEAD's; 130 and 128 received frames = the read-back, 0 different; 1080i59.94 'Hi59', dominance upper; late = 0 dropped = 0; probe read SDI | **PASS** |
| K7 | Paused in Field 1: the display link stopped as before; CPU 0.04 % (I4 run 0.04 %). Playing: GPU 0.11–0.13 ms a frame steady, the same as the I4 run (the marker is not Metal) | **PASS** |
| K8 | `[FIELDS] marker shown — FIELD 1 (window only)` 75 times and `[FIELDS] marker hidden` 25 (one per change, Field 1 → Field 2 included); none on the progressive set; no other log line differs from the I4 run's apart from the two I4 fixes already in `3f7daad` | **PASS** |
| G | `swift test` **642 / 642** (641 + 1); clean Profile build: the same 12 warnings | **PASS** |
| D | 11 `NSWindow Frame` keys added, and **two keys changed** by the stray Open panel (K5): `NSNavPanelExpandedSizeForOpenMode` and `NSOSPLastRootDirectory`, the system open panel's own. Each was read and stashed (`marker/stash-*.txt`), then written back to the snapshot's value; the frame keys were read, then deleted; one `set -e` sequence. The domain is then dictionary-equal to the snapshot; `streamBookmarks` unchanged; licence keys present (3, values never read out), never written | **PASS** (after the restore) |

**Findings.**
1. **The Open panel during the run.** Where it came from was not established: it appeared as `open -a` handed the app its
   file and closed with the window loop. Not seen in the I4 runs. It is why D had two changed keys.
2. **An Inspector open over the top-right corner covers the marker** (the Inspector's Window View row says the same). In
   the driver's runs the Inspector was open; Accessibility still lists a covered element, so whether they overlapped was
   not measured. By eye: item 10 below.

**What changed.** `FieldView.marker` (FileScan, + 1 test); `FieldViewMarker` in `App/FieldViewControl.swift`; one overlay
line in `App/ContentView.swift`, on the picture surface beside the framing guides and captions. No Metal, renderer, output,
scope or export code changed.

**Added to the by-hand checklist (14.6):**

10. **The marker** on `mark-prores-1080i5994-tff.mov` (on the LG, by eye): Field 1 shows "FIELD 1" in the picture's top-right
    corner, small and in the app yellow. It stays when the controls hide and in full screen, and it's gone in Weave and on a
    progressive file. Is it readable but not distracting, at fit and at 100 %, over bright and dark picture? With the
    Inspector open, is it covered (decision 11)? Choose another corner, size or opacity if you want one.
11. **Decision 11:** the marker's corner (top-trailing), size (11 pt heavy), opacity (85 %, on a 55 % black capsule).
