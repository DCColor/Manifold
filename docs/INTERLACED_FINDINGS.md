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
