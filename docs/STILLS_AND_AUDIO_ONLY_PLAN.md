# Stills and audio-only files

Status: built through B4, see *Build status*. Written as a plan, 2026-11-03, at `884cce3` (release 0.9.1, build 23), decisions recorded the same day. **0.9.2 = B0–B4. B5 (audio on
SDI) = 0.9.3.** No Manifold build was made, launched or committed for this plan. Line references are to that commit. **By reading** means established from the code and not run. **Measured**
means run here as small standalone probes in the session scratchpad, on this Mac: macOS 26.7.1 (25G241), SDK 27.2.
**UNKNOWN** means not established. Companion: `docs/SETTINGS_EXPORT_PLAN.md`.

## Build status (2026-11-04)

**Built and run:** B0, B1, B2, B3 and B4 (2026-11-05 for B0, B2 and B3's still half). **Still to do for 0.9.2:** the attended pass: the
§6 tables by eye and on the SDI monitor. The privacy line for EXIF (§4.3) is in `docs/PRIVACY_AUDIT.md` §3.

**What changed from the plan while building:**

- `ContainerSlackRoute` gained `.noVideoDeclared`. Only "no video track declared" may become audio-only; a video track that exists and
  cannot be read stays refused. A movie type the scan cannot see into (.avi, .mts) with an audio track also stays refused.
- **The Mac plays an audio-only file even when the audio destination is SDI** (`applyAudioMute`). The card is silent, so otherwise it
  would be heard nowhere. Not in the plan; confirmed by Robbie, 2026-11-05.
- `audioFormatChanged` is ignored while held. Without that, a 44.1 kHz WAV would re-establish the output, and the monitor would re-lock.
- Both hold edges drop the renderer's staged frames (`dropDeckLinkFrames`).
- `displaySize` is 1280 × 720 for the sizer, so the raster, Color menu and hold-to-compare gates moved from `displaySize != nil` to
  `WindowDeck.colorControlsEnabled`.
- Home and End go to 0 and the duration on an audio-only file. `TimecodeContext` is nil there, and they would otherwise do nothing.
- Audio-only rows use "Time Reference" and "Timecode … @ rate" under a "Broadcast Wave" Inspector section.

**Measured 2026-11-04 (`scripts/make_audio_fixtures.sh`, AX, logs, SDI loopback `capture`):** all 15 fixtures open, show the card, play and
stop at the end. Loop wraps, a mid-file seek plays on (by `MANIFOLD_DEBUG_STEPS`; AX cannot set the scrubber), meters move, BWF rows
match the fixture's values. On the wire, after a playing video: one constant black hash for 134 frames, tagged Rec. 709 EOTF 0, then the
new file's first frame, with no frame of the old file; 0 late, 0 dropped, 0 input gaps, no re-establish, across a 44.1 kHz WAV. Output
started with a WAV already open gives the same black hash. The video afterwards restores PQ tags and Rec. 2020 Signal line (wedge file),
and a moving 48 kHz clip restores scopes, meters and real PCM on SDI.

**By reading only, not run:** the key gates (frame step, reverse-as-pause, timecode entry, frame readout): AX sends no keystrokes. A live
source committing over a hold. The card at the 720 × 569 minimum. A file rewritten on disk while open (`reinspect`). Desktop sound, by ear.

**B2 and B3's still half, what changed from the plan:**

- **The decode is in phase 1**, not after the commit, in the new leaf target `StillImageInfo`. A file with a good header and bad data is refused
  with the current file left alone. A JPEG cut short still opens, showing what macOS can decode.
- **`metadata` stays nil for a still.** `stillInfo` and `stillPicture` carry it, so nothing reaches the output's colour or mode. The file name
  overlay reads `stillInfo`.
- **Raster sizes stay on for a still** (§3.3) through a new `rasterControlsEnabled`. `colorControlsEnabled` is off, as for audio-only.
- **An extra Headroom row, "Mastering peak N nits (from file)"**, for a file with `mdcv` and no `clli`: there "macOS assumes 1,000 nits" would be
  false (B0 result). HLG with no `clli` says "Peak not stated", because what macOS assumes for HLG was not measured. A file reporting another
  number the scan cannot see says "Peak not stated" too.
- **The bar for a still** keeps Open, guides, Inspector, Refresh, scopes, DeckLink, Streaming, Color (face "Still", greyed), the display transform
  (greyed, its tooltip the still sentence) and the pin, on one row or two.

**Measured 2026-11-05 (AX, logs, SDI loopback `capture`, `.build-cc` Profile build):** nine of the 12 fixtures were opened in the app, one or more of each kind, with the
right format, size, HDR type and headroom row. Unit tests read six on real files. `IMG_0026` reads 4284 × 5712 (rotated). Refusals: DPX by name and with its banner, a truncated PNG, random bytes named
`.jpg`. A PNG named `.jpg` opens as a PNG. View ▸ 25% and 50% size the window ("50% — 2016×1512"). The chain readout shows the still sentence.
Colour menu items are off. The window's bar has no play, scrubber, mute or audio track. Opened over a playing video: the transport goes, meters
read no audio track.

On the wire, in one window, output 1080p24: PQ video reads Rec. 2020, HDR, ANC on every frame. The still reads Rec. 709, dynamic range 0, no ANC,
one hash across 78 frames, every sample Y 64, Cb/Cr 512, mode unchanged. Back on the video, Rec. 2020, HDR and ANC return, and the scope header
reads Rec. 2020. Video → still → audio-only → still → video each swap the DeckLink menu row, and no re-establish was logged.

**Scopes on a still, measured 2026-11-05 (`MANIFOLD_SCOPE_PROBE=1`, the bins the kernels wrote; DEBUG builds):** a generated 8-bit sRGB grey ramp reads bins 0
to 1023, and code 63, 127, 191, 255 land at 253, 509, 766, 1023 on the waveform, each the code × 1023 ÷ 255. The PQ AVIF's parade tops at bin 991, its
peak code, 7,429 nits, tagged CICP 9-16-9. The Ultra HDR JPEG tags 12-13-1 from its ICC colorants and `para` curve, and every header reads "SDR base image
(gain map not applied)", as does `IMG_0026`, upright. Unit tests hold every ramp code at 16 bits, a Display P3 file unmoved, and all 8 orientations
against ImageIO. In one window, ramp, gain map, video, rotated gain map and PQ each replace the trace and header, the ramp returning its exact bins and
the video its own trace, Rec. 2020 and no note. Output on under the PQ still, 2160p23.98: Rec. 709, dynamic range 0, no ANC, one hash across 78 frames,
menu row shown, scope still reading 991.

Not run for scopes: a LUT loaded with a still open, Adobe RGB and untagged headers in the app (unit tests only), a CMYK file, a still over 8192
pixels. The scope headers on this Mac read "HLG (%·nits)*" because the vertical scale is forced to HLG in the scope's own setting; on Auto, a PQ still
takes the PQ ruler by reading.

**By reading only, not run:** the keys on a still (Space, J/K/L, arrows: `positionControlsEnabled`; Export Frame and Loop: `canPerform` beeps). A
refused file with a file already in that window: `manifold-proc open` puts it in a new window. A drop. A file rewritten on disk (`reinspectStill`).
A LUT returning with the next video. The bar at the 720 × 569 minimum and a portrait still there. A `clli` row in the app (unit tests and the
scan cover it, on synthesized boxes). An HLG still, an Apple gain-map HEIC, a 100 MP file: no fixture.

**The card's silence log** now says `SILENCE · audio destination is Computer` when that is the reason (`isDestinationSilent`, asked for the label
only), measured playing and paused, and still `transport gate` when paused on SDI.

## Post-release checks, 0.9.2 build 24 (2026-11-05)

Robbie, attended, on the signed Developer ID build installed in `/Applications`.

- **Default app: PASSED.** Settings ▸ Files ▸ WAV, "Use Manifold" accepted, and double-clicking a WAV opened it in Manifold 0.9.2. While a local
  build and `/Applications` both exist, Launch Services opened the `/Applications` copy (expected; same bundle ID).
- **Update dialog and guide: PASSED.** The update dialog showed 0.9.2 build 24 with the chosen first six notes. Help ▸ Sync and Color Guide shows 0.9.2.

## B0 result (2026-11-05)

Standalone spike on macOS 26.7.1, LG in HDR mode (EDR 4.48, potential 8.97), each image beside Preview at the same size. Fixtures in
`$HOME/Code/Manifold/fixtures/stills/`, one subfolder per type. **Measured** unless stated.

**Verdict (Robbie, by eye, a sanity check and not a reference judgment):** route C matches Preview side by side on the LG. Route B is
brighter than Preview. **B2 uses route C.**

| Route | Decode | `NSImageView` range | Result |
|---|---|---|---|
| A | `NSImage(contentsOf:)` | `.high` | Loses HDR on an EXIF-rotated file: `IMG_0026` (orientation 6) comes back 8-bit, headroom 1.0. The unrotated `IMG_0014` keeps 10-bit, 4.15 |
| B | `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceDecodeToHDR`, `…WithTransform`, `…FromImageAlways`, max size = the larger side | `.high` | Keeps HDR and rotates. Brighter than Preview |
| **C** | As B | **`.constrainedHigh`** | **Matches Preview. Chosen** |

`NSImageView.imageDynamicRange` read `standard` on all three while HDR was visibly on, so it cannot be used to log what resolved.

**Decisions for B2 (Robbie, 2026-11-05):**

- Inspector headroom rows state their source: gain map **"HDR capacity N nits (from file)"**; PQ with `clli` **"MaxCLL N nits (from
  file)"**; PQ without **"Peak not stated; macOS assumes 1,000 nits"**.
- The gain-map type is labelled from the file (Adobe XMP or ISO 21496-1), not from ImageIO's ISO key alone.
- Read the file type **before** properties.
- The skin "banding" on the JPEGR looks like skin texture. The gain-map offset question goes to GradeShare, not Manifold.

**What the headroom numbers are.** macOS's scale: extended linear 1.0 = 203 nits for PQ (100 nits lands at 0.4925, 10,000 at 49.26).

| File | Number | Source | Peak at 203 nits |
|---|---|---|---|
| JPEGR | 19.70 | `hdrgm:HDRCapacityMax="4.30045"`, as 2^x; the `Headroom` property and `CIImage.contentHeadroom` report it | 4,000 nits |
| JPEGR | 35.54 | `hdrgm:GainMapMax="5.15148"`, as 2^x | 7,215 nits |
| JPEGR | 8.00 | `CGImage.contentHeadroom` after `kCGImageSourceDecodeToHDR` | 1,624 stated; pixels reach 12.06 = 2,449 nits |
| AVIF | 4.93 | `kCGDefaultHDRImageContentHeadroom` = 1000/203. A default, not file data | 1,000 nits |
| AVIF | ~35.09 | `CGImage.calculatedContentHeadroom`; DecodeToHDR returns the same when the file has no `clli` | 7,123 nits |
| AVIF | 36.60 | Scan of decoded pixels (max RGB; max luminance 35.44) | 7,429 nits |

- **ImageIO decodes a gain map for a target headroom of 2³.** Patching `HDRCapacityMax` in scratch copies: 2.5 gives 5.66 and peak 35.6; 3.0
  gives 8.00 and 35.6; 3.2 gives 8.00 and 28.5; 4.30045 gives 8.00 and 12.06; 5.15148 gives 8.00 and 7.98. Each peak fits weight 3 ÷ capacity.
  No public ImageIO option changes it (`kCGComputeHDRStats` and `kCGImageSourceGenerateImageSpecificLumaScaling` change nothing). Core
  Image is not limited: `.expandToHDR` reports 19.70 and renders to 38.89.
- **A gain map states no nits.** It is relative to SDR white, so the Inspector's N is capacity × 203, macOS's scale. At full weight the JPEG's
  top percentiles match the AVIF's (5.38 / 12.39 / 33.68 against 5.35 / 12.45 / 33.84), so JPEG 1.0 lines up with the AVIF's 203 nits.
- **The fixture AVIFs carry no `mdcv` or `clli`**, only `colr nclx 9/16/9`, full range. macOS reads them when present: on scratch copies `clli`
  4000 states 19.70 and DecodeToHDR agrees; `clli` 1000 states 4.93; `mdcv` 4000 alone states 19.70 while DecodeToHDR stays 35.09. That is
  why the Inspector also has a mastering-peak row: with `mdcv` alone, "macOS assumes 1,000 nits" would be false.
- **The JPEGR is Adobe `hdrgm` XMP with no ISO 21496-1 segment**, yet ImageIO answers its ISO auxiliary key. The iPhone JPEGs carry the ISO
  URN and Apple's aux URN.
- **`CGImageSourceGetType` flips** from `public.jpeg` to `public.heic` on the JPEGR files once properties have been read. Cause UNKNOWN. Their
  JFIF APP0 sits after APP1 and APP2, not straight after SOI, which may or may not be related.
- **DecodeToHDR changes shadows as well as highlights** on the JPEGR: median 0.0045 plain, 0.0056 at weight 0.698, 0.0062 at full weight.

**Fixtures against their folder names.** The `HEIC` files have no gain map: 8-bit sRGB, SDR, so no Apple HEIC gain map has been tried yet. The
`SDR JPEG` files are not SDR: both carry ISO and Apple gain maps. The real SDR files are `SDR PNG` and `SDR TIFF`.

**For GradeShare, not Manifold:**

1. `GainMapMax` (5.15) exceeds `HDRCapacityMax` (4.30), so the peak overshoots a display's headroom: 6.03× at the LG's 4.48. With capacity at
   5.15148 the decoded peak is 7.98, which fits the stated 8.00.
2. Peak pixels reach 7,429 nits against an implied 4,000 ceiling, about 0.01% above 6,870. Whether the grade goes there is UNKNOWN.
3. The AVIF writes no `clli`.
4. `GainMapMin` is -14.3 with offsets of 1e-07: 0.076 stops per code on an 8-bit map, against 0.025 in the 1080 file (`GainMapMin` -1.28).
5. JFIF APP0 is not straight after SOI.

## Decisions (Robbie, 2026-11-03)

- **Version:** 0.9.2 takes B0–B4. B5 moves to 0.9.3 with its setting, its clock and its 48 kHz conversion.
- **No Mac runs macOS 15.** Every finding here is as seen on macOS 26. The deployment target stays 15.0, and API availability comes
  from the SDK headers, so behavior on 15 itself is unverified.
- **D3:** convert on the reader, in 0.9.3. **D4:** video files at 44.1 kHz keep today's refusal. **D5:** the tray does not open
  itself. **D6:** black on output for a still. **D7:** DPX out for v1. **D8:** sample rate is added to the SDI card, so it is the
  same card plus the running time. **D9:** all ImageIO formats. **D10:** Edit in Flip hidden for stills and audio-only.

**What 0.9.2 does on the output with an audio-only file:** with no B5 there is no card and no clock, so the output sends the B3 black
with silent audio, and the DeckLink menu says so: "Audio-only files aren't sent to SDI or HDMI yet. Output is black." The setting
"Audio-only files on SDI" arrives with B5.

## 0. Read this first

1. **"Audio embedded through the existing path" does not work as it stands, for two reasons.**
   - **The SDI audio has no clock without video frames.** The card's audio is anchored to the source PTS of the video
     frame on the wire, and with none it schedules silence (`DeckLinkBridge.mm:550-557`). A card that changes once a
     second cannot be that clock. §5.3 gives it one.
   - **SDI audio is 48 kHz only.** Anything else disables it for the file (`DeckLinkService.swift:1045-1056`), and 44.1 kHz
     is the normal rate for MP3, AAC and CD-derived WAV. §5.4 converts on the reader. **Measured:** the reader does this.
2. **Without action, the card keeps sending the last video frame while a still is open.** `clearToBlack` does not touch
   the DeckLink staging ring, and `deckLinkFrameReady` is reset only at output start, output stop and a failed placed
   convert (`MetalVideoRenderer.swift:3168-3183`, `:4966`, `:5100`, `:5254-5256`). By reading. A neutral fill alone would also keep
   a previous PQ tag on black (`DeckLinkService.swift:922-923`). §3.4 fixes both with one mechanism.
3. **API confirmed, behavior not.** `NSImageView.preferredImageDynamicRange` is available from macOS 14 per the headers, so it
   builds for 15. What it does with a gain-map file has not been seen on any macOS yet: B0 checks that on macOS 26, the only
   system we have.
4. **The reasoning written in the code reverses.** The refusal says stills wait for the color pipeline
   (`FrameEngine.swift:1625-1647`). Robbie's direction removes that dependency, because Manifold's color path is not
   involved. That comment, `ContentView.swift:1150-1167`, `WindowDeck.swift:925-927` and `RecentFiles.swift:66` all need
   rewriting with the code.

---

# Stills

## 1. What happens today

| Route | Still | Audio-only `.wav`/`.mp3`/`.m4a` etc. | Audio-only `.mov` |
|---|---|---|---|
| Open panel | Greyed: `.movie` only (`WindowDeck.swift:928`) | Greyed, deliberately (`:925-927`) | Allowed |
| Drop on a window | Accepted, then refused by the engine (`ContentView.swift:1168-1171`) | **Declined silently** (`:1163-1167`). They conform to `public.audio`, not `.movie` or `.image` (measured) | Accepted |
| Finder Open With | Not claimed: only movies are (`project.yml:336-342`) | Not claimed | Claimed |
| Reaches the engine (all by reading) | Banner "Manifold plays video — still images aren't supported." (`FrameEngine.swift:1648-1654`) | Banner "…its video track is unreadable" (`:1708-1712`), which is the wrong sentence for a healthy file | Banner "…it has no video track." (`ContainerSlackRoute.swift:76`) |

All refusals are in phase 1, so the current file keeps playing (`FrameEngine.swift:1539-1570`, `:1575-1581`), and refused
files never reach Recent (`RecentFiles.swift:62-69`).

## 2. Display path

**One rule: Manifold's renderer never touches a still.** No Metal, no shader, no LUT, no display mode.

**Use `NSImageView` with `preferredImageDynamicRange = .constrainedHigh` (route C, B0 result)**, in an `NSViewRepresentable` placed in the same `ZStack` as
`MetalSurfaceView` (`ContentView.swift:1197-1204`). It inherits the aspect fit (`:1206`), the measured picture rect
(`:1210`) and the guide overlay (`:1218`). `imageScaling = .scaleProportionallyUpOrDown`, `animates = false`.

| API | Available | Use |
|---|---|---|
| `NSImageView.preferredImageDynamicRange` | macOS 14.0 (`NSImageView.h:74`) | **Yes**, at `.constrainedHigh`, stated rather than left to the default (`:70-71`) |
| `NSImageView.imageDynamicRange` | macOS 14.0 (`:77`) | **No.** Read `standard` with HDR on (B0) |
| SwiftUI `.allowedDynamicRange` | In SDK | No. Gives no readback, and the region is already representables |
| `CGImageGetContentHeadroom` (Swift `contentHeadroom`) | macOS 15.0 (`CGImage.h:270-271`) | Yes, for the HDR row |
| `kCGImageAuxiliaryDataTypeISOGainMap` | macOS 15.0 | Yes, detection only |
| `kCGImageAuxiliaryDataTypeHDRGainMap` | macOS 11.0 | Yes, detection only |
| `kCGImageSourceDecodeRequest`, `…DecodeToHDR` | macOS 14.0 (`CGImageSource.h:589-592`) | **Yes**, the decode for every still (B0) |
| `CALayer.preferredDynamicRange`, `contentsHeadroom` | **macOS 26 only** (`CALayer.h:469-481`) | **No.** Below our target |
| `CGImageCalculateContentHeadroom` | **macOS 26 only** (`CGImage.h:276-278`) | **No** |
| `wantsExtendedDynamicRangeContent` | Deprecated at 26 (`CALayer.h:455-456`) | No custom layer, so not needed |

**Measured (ImageIO only, not on screen):** a PQ-tagged image written and read back as PNG, TIFF, HEIC and AVIF keeps
`kCGColorSpaceITUR_2100_PQ`, reports the profile name, depth 16 (PNG, TIFF) or 10 (HEIC, AVIF), and headroom 4.926.

**Not established:**

- how Preview itself renders, so "match Preview" is judged by eye on the LG;
- an Apple gain-map HEIC: the fixture HEICs have no gain map (B0 result). The Apple and ISO gain maps were seen in iPhone JPEGs only.

B0 settled the route on macOS 26: see the B0 result at the top.

## 3. Behavior with a still open

### 3.1 Engine

Add `FrameEngine.mediaKind`: `.none`, `.video`, `.still`, `.audioOnly`. `hasMedia` stays true for all but `.none`, which keeps
the empty state, Inspector and file-name gates working, and each video-only gate moves to `mediaKind == .video`.

Phase 1, replacing the refusal at `FrameEngine.swift:1648`: the type must conform to `.image` **and** be in
`CGImageSourceCopyTypeIdentifiers()`, and the source must give properties at index 0 with a size. It writes nothing, as
phase 1 requires. Asking ImageIO at runtime means the list is right on every macOS with no hard-coded table. A failure
refuses with the current file left alone. Phase 2 runs the shared commit (`:1719-1749`), then `loadStill`:

- stop the readers, `asset = nil`, `videoTrack = nil`, `duration = 0`, rate 0;
- `onSourceColorTags?(nil, nil, nil, nil)`, the existing "no answer" path (`:1887`), so codes change only through
  `setSourceColorSpace`, per the CLAUDE.md rule;
- `renderer.clearToBlack()`;
- `audioPresence = .absent`;
- publish `displaySize` and `stillInfo`. Skip `HDR10MetadataReader` (`:1754`), and do not publish `metadata` through the
  path that drives the output (§3.4).

Autoplay does not apply. A file change is picked up by `SourceFileWatcher` as for any file.

### 3.2 Color controls and readout

- **Greyed:** display mode control, interpretation control, LUT load, the Color menu, and their keys (`displayOS` to
  `resetInterpretation`, `ShortcutCatalog.swift:56-64`), through one new `colorControlsEnabled` gate in
  `installShortcutHandlers` (`ContentView.swift:1671`).
- **Also off:** hold-to-compare, Bypass, Export Frame. `exportFrame` is gated only on the renderer existing
  (`ContentView.swift:1701-1704`) and would export black.
- **A loaded LUT stays loaded** and applies again with the next video. Nothing clears it. The LUT is simply not drawn.
- **Readout:** the chain readout shows one line, **"Still image: shown as macOS shows it"**, in place of the chain. It reads
  `hasSource` today (`DisplayChainModel.swift:209`).
- **Scopes on, showing the file (Robbie, 2026-11-05):** see §3.5.

### 3.3 Window, narrow layouts, transport

- **Size:** `displaySize` is pixel size with EXIF orientation applied, since orientations 5–8 swap width and height. Then
  the existing `sizeToSource` applies, and raster sizes work because they are window geometry
  (`ContentView.swift:1268-1274`). Size is by pixels, as video is. DPI is ignored.
- **Transport bar:** no scrubber, timecode, play, shuttle, loop, audio track or captions. The scrubber row (`:2788`) becomes
  one line, for example `Still image · 4032 × 3024 · HDR (gain map)`.
- **Buttons kept:** Open, Inspector, file name, guides, full screen, pin, DeckLink, Streaming.
- **Keys:** `position` gates off via `gate.positionControlsEnabled` (`WindowDeck.swift:159-175`), so Space, J/K/L and the
  arrows do nothing.
- **Narrow windows:** with fewer controls `adaptiveButtonRows` (`ContentView.swift:2971`) has less to fit. Check at the
  720 × 569 minimum and with a tall portrait still (`docs/NARROW_WINDOW_LAYOUT_PLAN.md` §1.1).

### 3.5 Scopes

**Decision (Robbie, 2026-11-05), replacing "scopes off":** principle as for video: scopes show the file, not the display. The window stays route C,
untouched by this.

- **Pixels.** The still is decoded once from disk with no colour conversion, and fed to the scopes as a single frame: ImageIO's plain decode, so no
  gain map and the stored encoding and profile, drawn at 16 bits into a context in the image's own colour space, EXIF orientation applied without
  filtering. `MetalVideoRenderer` holds it as an `rgba16Unorm` texture, and the four `computeXGPU` calls read that in place of the offscreen ring.
- **Tags, from the file.** The file's CICP first (`colr nclx`, PNG `cICP`), so PQ and HLG AVIF/HEIF by their CICP; then the profile, by name or from its
  ICC colorants and curve. A profile with no CICP code (Adobe RGB) and an untagged file resolve as Rec. 709 and say so on every header:
  "Adobe RGB (1998): no CICP code, read as Rec. 709", "Untagged: read as Rec. 709".
- **Gain-map files.** The SDR base image as stored, with the header "SDR base image (gain map not applied)".
- **The codes are not source or picture codes.** Those set the layer's colourspace and EDR behind the `NSImageView`, and a loaded LUT would restate them
  as its output. So the renderer keeps `stillScopeColor` beside the frame, the scope maths read it, and `ScopeColorFeed` stays the only writer of the
  scope models. Source and picture codes stay nil, the layer and the SDI tag are unchanged, and the chain readout keeps its one line.
- **Limits.** Above 8192 pixels on the longer side, every Nth pixel, never filtered, so the values stay the file's. CMYK and Lab have no RGB values, so
  no frame: the tray blanks and reads "no source". Alpha is not read; a transparent pixel reads as black.

### 3.4 SDI/HDMI: not sent in v1

**What the output does while a still is open, in the window that drives the card** (`deck.gate.drivesDevices`):

- It stays running and keeps its current mode. No re-mode, so a recorder or monitor does not re-lock.
- It sends **black, tagged Rec.709 SDR**, with silent audio.
- The DeckLink menu shows a disabled row in the existing idiom (`ContentView.swift:2200-2202`): **"Still images aren't sent
  to SDI or HDMI. Output is black."**
- Another window's output is untouched.

**Held picture (new, shared with audio-only).** `DeckLinkService` gets a lock-protected `heldPicture`: v210 bytes for the
current mode plus the signal. The fill block checks it first (`DeckLinkService.swift:929`), copies it and returns `.sdr709`,
and only otherwise asks the renderer. It bypasses the renderer completely, so no color code, LUT or display mode reaches
it, and it solves the stale frame and the stale tag at once. It is re-made on any mode change
(`startOutputOnQueue`, `:898`), skips the priming step (`:911-918`), and is cleared when a video or live source commits.

`ContentView.swift:821` must not call `sourceFormatChanged` for a still or audio file. There is no raster and rate to
follow, and a nil-rate guess is what `liveFormatChanged` already refuses (`DeckLinkService.swift:1195-1199`). Reuse
`followSourceUnavailableReason` for the menu wording.

## 4. Formats and Inspector

### 4.1 What ImageIO reads

**Measured on macOS 26.7.1** with `CGImageSourceCopyTypeIdentifiers()`: PNG, JPEG, TIFF, HEIC/HEIF, AVIF, JPEG XL, JPEG 2000,
WebP, GIF, BMP, TGA, PSD, OpenEXR, Radiance HDR, SGI, ICNS, ICO, DDS, PBM family, DICOM, KTX/ASTC, and camera RAW (DNG, CR2,
CR3, NEF, ARW, RAF, RW2, ORF and others).

**The list is as seen on macOS 26. No Mac here runs 15.** The design does not depend on it, since §3.1 asks at runtime, so an
older system simply opens fewer formats.

v1 opens whatever ImageIO reads. First frame only for GIF, multi-page TIFF and HEIC sequences. EXR is shown as macOS shows
it, which is not a grading view, and the readout line already says so.

### 4.2 DPX

**Confirmed not readable.** `org.smpte.dpx` exists and conforms to `public.image`, but it is not in the list (measured). Our
libav has no route either: the build is `--disable-everything` with no `dpx` decoder and no image demuxer
(`scripts/build_ffmpeg.sh:258-264`).

| Option | Work | Cost |
|---|---|---|
| **Out for v1 (recommended)** | Its own refusal: "DPX isn't supported yet." Otherwise "still images" would now be a false reason | Minutes |
| libav decode as a one-frame video source | Add decoder and demuxer, rebuild and re-pin FFmpeg, update notices. New one-frame route through the renderer. About 3–5 sessions | DPX has no ICC profile and no "as macOS shows it", so it **must** use Manifold's color path, with scopes and SDI. That is a different feature from this one, and it raises image sequences |

### 4.3 Inspector rows

From `CGImageSourceCopyPropertiesAtIndex`, in a new `stillInfo` branch of `InspectorPanel` (`InspectorPanel.swift:35`):

| Row | Source |
|---|---|
| File Name, Format | URL, `CGImageSourceGetType` |
| Dimensions | Pixel size, plus "(rotated)" when orientation swaps them |
| Color Profile | `kCGImagePropertyProfileName` (measured working), else "Untagged" |
| Bit Depth | `kCGImagePropertyDepth` (measured working) |
| HDR Type | Gain map (ISO 21496-1, Adobe XMP, Apple, as the file's own bytes say), PQ, HLG, or SDR. PQ/HLG by `CGColorSpaceIsPQBased` / `…IsHLGBased` |
| Headroom | The stated source, per the B0 decisions. Nothing for SDR |
| Capture Date | EXIF `DateTimeOriginal`, else TIFF `DateTime`, else absent. Never the file date |
| File | The existing Size and date rows (`:208-215`) |

GPS, camera serial and owner tags are **not** shown or logged. The privacy audit's "read into memory only" statement
(`PRIVACY_AUDIT.md:208`) gains EXIF.

---

# Audio-only

## 5. Design

Scope is WAV, AIFF, BWF, MP3, M4A/AAC. **Measured:** AVFoundation gives no video track and one audio track, with correct
rate and channels, for WAV 44.1 and 48 kHz, 6-channel WAV, AIFF, M4A, MP3, FLAC, an audio-only `.mov`, and a WAV with a
`bext` chunk. So no new decoder is needed.

### 5.1 Opening and engine

- Open panel: `[.movie, .image, .audio]`, message "Choose a file". Drop: `acceptsForLoad` adds `.audio`. Finder: new Image
  and Audio document entries, role Viewer, rank **Alternate** (`project.yml:376-380`).
- Phase 1, at the "no video track" branch (`FrameEngine.swift:1694`): `ContainerSlackRoute.vet` runs first, because a video
  track hidden by `stsd` slack must still win (`:1698-1702`). Then, if the asset has an audio track, the file is
  `.audioOnly`. This changes the `.mov` result in the §1 table.
- **Audio-only MXF is unchanged.** MXF commits to the libav path unvetted (`:1590-1594`). Its behavior with no video is
  UNKNOWN and out of scope.
- `beginReading` requires a video track (`:4256`). Add a branch that does the same audio steps without one: token, rate 0,
  `teardownAudioReading`, `synchronizer.setRate(0, time: start)`, `beginAudioReading`, then `play()`. `beginAudioReading` needs
  no video (`:4076-4134`), and an audio-only reader has been measured at 3–4 ms warm (`:1297-1298`). Seek and loop go through
  `beginReading`, so they follow.

### 5.2 Window

**Card:** file name, format (e.g. "WAV · 24-bit PCM"), channels (with layout when declared), sample rate, duration. Metal and
sample-buffer surfaces stay behind it, black.

- **Size:** a fixed 16:9 `displaySize` for the window sizer. Raster sizes are greyed, since a percentage of nothing is
  false, and `RasterReadout` stays silent. In overlay mode the card's content sits above the HUD area so controls never cover it.
- **Transport:** normal scrubber, play, loop, mute, audio track. Readouts use elapsed time, and source TC falls back as it
  does today (`ContentView.swift:3589-3591`).
- **Must be gated:** frame readout mode, because `frameRateOrDefault` invents 24 fps (`:3583-3586`); frame step; timecode
  entry (rate 0, `TimecodeEntry.swift:163-165`); and reverse shuttle, because reverse is a video pump (`FrameEngine.swift:927-930`).
  ⇧←/⇧→, forward shuttle and J-as-pause remain.
- **Meters:** the existing Audio Meters panel (`ContentView.swift:20-30`), fed by the same tap. Video scopes are off as for a
  still. The tray does not open itself (D5).
- **Color controls:** greyed. Readout line "Audio-only file".
- **A/V offset:** nothing to do. That control exists only for live sources (`LiveAudioOffset.swift:190-193`).
- **BWF timecode:** a small RIFF chunk scanner in a leaf target, handling `RF64`, reads `bext` `TimeReference`, plus iXML
  `TIMECODE_RATE` when present. Inspector rows: **Timecode** only when a rate is stated, otherwise **Time Reference** as
  `HH:MM:SS.mmm`, because `bext` carries no frame rate and one must not be assumed. Also Origination Date. Inspector only:
  it does not drive the transport readout. `MediaInspector.metadata` handles no video by reading (`MediaInspector.swift:22`
  is conditional), and the rows need checking on a real file.

### 5.3 SDI/HDMI picture and clock

This section and §5.4 are **0.9.3 (B5)**.

**Revisit in B5:** in 0.9.2 an audio-only file plays on the Mac even when the audio destination is SDI, because the card is silent
(`applyAudioMute`, the `deckLinkOwnsAudio && mediaKind != .audioOnly` term). Once the SDI card carries the sound, that exception
must be reconsidered, or the same program plays from the Mac and the card at once. Likely it goes, and the destination rules again.

**Setting:** Settings ▸ DeckLink Output ▸ Output (`SettingsView.swift:611`), **"Audio-only files on SDI: Show card / Black"**,
default Show card, key `manifold.decklink.audioOnlyPicture`. A caption says Black is for recording the SDI feed.

**Picture.** One drawing function, `AudioCardDrawing.draw(in: CGContext, size:, model:)` with Core Text, is used for the
window and the output, so the two cannot drift. Output fields (D8): file name, format, channels, sample rate, duration, running
time. Rendered at the output's size as BT.709 legal-range v210 into `heldPicture`.

- It re-renders only on a change: new file, mode change, or the running time's whole second (play or seek). Only the time
  band's rows are re-encoded. This runs on a background queue, never on the card's callback.
- The time comes from the engine's clock, once a second. Text stays inside title-safe, and heavy weight keeps interlaced modes
  clean. A long name is truncated in the middle.
- **Mode:** audio does not change it. A manual pick wins, otherwise the current mode stays (on a fresh session
  `default2160p2398`, `DeckLinkService.swift:558`). Mode changes re-render at the new size.
- Black mode uses the same `heldPicture`, with audio unchanged.

**Clock.** `makeAudioConfig`'s `sourceTime` (`DeckLinkService.swift:1072`) gets one branch: while audio-only is held, it
returns the engine's audio clock (`synchronizer.currentTime()`) rather than the frame's PTS. The bridge is **unchanged**. Its
anchor loop already smooths a stepped input, and it steers by at most 2 frames per callback
(`DeckLinkBridge.mm:575-596`). Pause, mute and off-speed already give silence through `isCardAudioSilent`
(`FrameEngine.swift:889-896`).

The risk is by reading only: `ideal` (`DeckLinkBridge.mm:567`) was built for a staged frame's PTS, and the ring must hold audio
at that time. The decoder runs ahead of the renderer, so it should. Underrun counters and `logAudioBranch` show it either way.

### 5.4 Non-48 kHz files

**Recommended:** when the window drives a running output and the file is not 48 kHz, ask the audio reader for 48 kHz
(`AVSampleRateKey`, added to the settings at `FrameEngine.swift:4235-4243`, audio-only files only). The tap then reports 48 kHz,
`isSupportedForSDI` passes, and nothing else changes. When output starts or stops, rebuild the audio reader at the same time.

**Measured:** on a 1 s 44.1 kHz WAV the reader delivered 48 kHz: 47,983 frames, ending 0.35 ms short. On a 44.1 kHz MP3 it
delivered 48 kHz: 49,511 frames (1.031 s), so MP3 start padding needs checking against the reported duration.

⚠️ **Measured trap:** `AVSampleRateConverterAudioQualityKey` in reader settings **throws an uncaught
`NSInvalidArgumentException`.** Do not add it. Converter quality is therefore Apple's default, and it is unmeasured.

Conversion happens only for the output, and is stated: Inspector row and DeckLink menu row "SDI: converted from 44.1 kHz to
48 kHz", following the chroma rule of once, at the output, never silently. The alternative is our `PolyphaseResampler`, which
was built with this in mind (`docs/AUDIO_RESAMPLER_DESIGN.md:1347-1352`) but costs more to place in the file path. Video files at
44.1 kHz keep today's refusal (D4).

---

# Both

## 6. Test plan

Rules for every launch: tell Robbie first, `manifold-proc.sh guard && <launch>`, run the binary directly, quit by PID, open
files with `manifold-proc.sh open <pid> <file>`. `/Volumes/DCCOLOR/TEST FLIP` is read-only and has no stills or audio at the top
three levels, so fixtures go elsewhere. Report name/tag mismatches as findings. Screenshots of the Manifold window only, by
window ID, deleted after use. That rule means Preview's window cannot be captured, so Manifold-versus-Preview is a by-eye check.

**Unit (`swift test`, no launch):** RIFF/`bext`/`RF64`/iXML parsing including truncated and absent chunks; orientation to
display size; HDR type classification; v210 card encoder (legal range, 709 matrix, known bytes, time-band-only update
matches a full render); card layout at every output size.

**B0, before any app work (standalone, not Manifold):** gain map, PQ and HLG in a test `NSImageView` against Preview on the LG in
HDR mode, on macOS 26.

**Stills, attended:**

| Check | Display | Pass |
|---|---|---|
| SDR sRGB, Display P3, Adobe RGB, untagged | **LG**, by eye, side by side with Preview | No visible difference |
| HDR: iPhone gain-map HEIC, Ultra HDR JPEG, PQ AVIF, HLG HEIC | **LG**, HDR mode | Highlights match Preview, and SDR parts do not shift. A sanity check, not a reference judgment |
| Pixel values, SDR | **ASUS** | Manifold window capture equals the value expected from ColorSync |
| Rotated EXIF, 16 × 16, 100 MP, portrait at the minimum window, corrupt file, DPX, extension mismatch | LG | Correct size and refusal, current file kept on refusal |
| Greyed controls, keys and Export Frame; LUT returns with the next video; scope headers | LG | As §3.2 |
| Output while a still is open, after an HDR video | SDI monitor | Black, tagged SDR, no stale frame, no re-lock. True reference monitoring is over SDI |

**Audio-only, attended, 0.9.2:**

| Check | Pass |
|---|---|
| Each format and 44.1, 48, 96 kHz; mono, stereo, 5.1 WAV; polywav | Plays, meters, loop, seek, end of file |
| Desktop sound | Audio Hijack dropout scan or headphones, per the machine-room note. Start Audio Hijack only after launch |
| Output on, after an HDR video | Black, tagged SDR, silent, menu row shown |
| BWF with and without iXML | Rows correct, no invented frame rate. `afinfo` does not show `bext` (measured), so cross-check with the fixture's known value |

**Audio-only on SDI, attended, 0.9.3 (B5):**

| Check | Pass |
|---|---|
| Card on SDI, 1080 and 2160, progressive and interlaced | Text correct, time ticks once a second, stops when paused, moves on seek |
| Black setting | Pure black, same audio |
| SDI audio continuity, 30 minutes | No `RESYNC`, no underrun lines, no audible steps. Pause, mute, seek, loop, shuttle |
| 44.1 kHz on SDI | Correct pitch, length within the MP3 tolerance, row shown, output start and stop mid-file |
| Output started before opening the file, and after | Both work, including the format re-establish (`DeckLinkService.swift:1095`) |

Regression: a video file after a still and after an audio file restores color, scopes, mode and audio on window and SDI.

## 7. Stages

Effort is in working sessions, and is a guess, not a measurement.

| Stage | Release | Content | Effort |
|---|---|---|---|
| B0 Spike | 0.9.2 | Standalone display check on macOS 26, fixtures | 0.5 |
| B1 Plumbing | 0.9.2 | `mediaKind`, gates, panel, drop, Finder types, comments rewritten | 1 |
| B2 Stills | 0.9.2 | Display, phase 1 and commit, readout, Inspector, transport line | 1.5 |
| B3 Held picture | 0.9.2 | `heldPicture`, black on output for stills and audio-only, menu rows | 0.5 |
| B4 Audio in the window | 0.9.2 | Engine branch, card, gates, BWF | 1.5 |
| Attended pass | 0.9.2 | Stills and audio tables above, privacy line | 0.5 |
| B5 Audio on SDI | **0.9.3** | Card to v210, clock, setting, 48 kHz, attended SDI table | 2 |

About 5.5 sessions for 0.9.2. B5 carries the most risk, because the clock change is by reading only.
