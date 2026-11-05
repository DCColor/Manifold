# Stills and audio-only files — PLAN ONLY

Status: plan, 2026-11-03, at `884cce3` (release 0.9.1, build 23), decisions recorded the same day. **0.9.2 = B0–B4. B5 (audio on
SDI) = 0.9.3.** No Manifold build was made, launched or committed for this plan. Line references are to that commit. **By reading** means established from the code and not run. **Measured**
means run here as small standalone probes in the session scratchpad, on this Mac: macOS 26.7.1 (25G241), SDK 27.2.
**UNKNOWN** means not established. Companion: `docs/SETTINGS_EXPORT_PLAN.md`.

## Build status (2026-11-04)

**Built and run:** B1 (audio parts and the shared `mediaKind`), B4, and the held picture for audio-only (B3's audio half). **Still to
build:** B0, B2 and the still half of B3. Stills keep their refusal, which now goes through `mediaKind` in `loadAsset`: B2 replaces
that one block, adds `.image` to the open panel and an Image entry to `project.yml`, and calls `setHeldBlack` with the still sentence
from `updateHeldPicture`.

**What changed from the plan while building:**

- `ContainerSlackRoute` gained `.noVideoDeclared`. Only "no video track declared" may become audio-only; a video track that exists and
  cannot be read stays refused. A movie type the scan cannot see into (.avi, .mts) with an audio track also stays refused.
- **The Mac plays an audio-only file even when the audio destination is SDI** (`applyAudioMute`). The card is silent, so otherwise it
  would be heard nowhere. Not in the plan: Robbie to confirm.
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

## Decisions (Robbie, 2026-11-03)

- **Version:** 0.9.2 takes B0–B4. B5 moves to 0.9.3 with its setting, its clock and its 48 kHz conversion.
- **No Mac runs macOS 15.** Every finding here is as seen on macOS 26. The deployment target stays 15.0, and API availability comes
  from the SDK headers, so behavior on 15 itself is unverified, and stated as such in the user guide.
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

**Use `NSImageView` with `preferredImageDynamicRange = .high`**, in an `NSViewRepresentable` placed in the same `ZStack` as
`MetalSurfaceView` (`ContentView.swift:1197-1204`). It inherits the aspect fit (`:1206`), the measured picture rect
(`:1210`) and the guide overlay (`:1218`). `imageScaling = .scaleProportionallyUpOrDown`, `animates = false`.

| API | Available | Use |
|---|---|---|
| `NSImageView.preferredImageDynamicRange` | macOS 14.0 (`NSImageView.h:74`) | **Yes.** Must be set: the default is constrained, not high (`:70-71`) |
| `NSImageView.imageDynamicRange` | macOS 14.0 (`:77`) | Yes, read-only, for logging what resolved |
| SwiftUI `.allowedDynamicRange` | In SDK | No. Gives no readback, and the region is already representables |
| `CGImageGetContentHeadroom` (Swift `contentHeadroom`) | macOS 15.0 (`CGImage.h:270-271`) | Yes, for the HDR row |
| `kCGImageAuxiliaryDataTypeISOGainMap` | macOS 15.0 | Yes, detection only |
| `kCGImageAuxiliaryDataTypeHDRGainMap` | macOS 11.0 | Yes, detection only |
| `kCGImageSourceDecodeRequest`, `…DecodeToHDR` | macOS 14.0 (`CGImageSource.h:589-592`) | Fallback if `NSImage` proves not to apply gain maps |
| `CALayer.preferredDynamicRange`, `contentsHeadroom` | **macOS 26 only** (`CALayer.h:469-481`) | **No.** Below our target |
| `CGImageCalculateContentHeadroom` | **macOS 26 only** (`CGImage.h:276-278`) | **No** |
| `wantsExtendedDynamicRangeContent` | Deprecated at 26 (`CALayer.h:455-456`) | No custom layer, so not needed |

**Measured (ImageIO only, not on screen):** a PQ-tagged image written and read back as PNG, TIFF, HEIC and AVIF keeps
`kCGColorSpaceITUR_2100_PQ`, reports the profile name, depth 16 (PNG, TIFF) or 10 (HEIC, AVIF), and headroom 4.926.

**Not established:**

- how Preview itself renders, so "match Preview" is judged by eye on the LG;
- whether `NSImage` + `NSImageView` applies an ISO gain map, an Apple gain map or an Ultra HDR JPEG as Preview does;
- my attempt to make a gain-map fixture failed: the encode request wrote a plain PQ HEIC with no gain map, so a real
  iPhone HEIC and a real Ultra HDR JPEG are needed.

Stage B0 settles this on macOS 26 in a tiny test window before any app work. If `NSImage` is not enough, decode with
`kCGImageSourceDecodeToHDR` and give the view that image.

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
- **Scopes off:** `hasSource` is true for a still because `currentURL` is set (`WindowDeck.swift:484-487`). So
  `ScopeColorFeed.swift:115` must use a new "has a picture for the renderer" test, or the headers would describe nothing.
  No scope sampling runs. The tray stays closable. Headers read "no source", the existing wording (L3).

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
older system simply opens fewer formats. The user guide says formats are whatever the Mac's macOS can open.

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
| HDR Type | ISO gain map, Apple gain map, PQ, HLG, or SDR. Gain maps by auxiliary data, PQ/HLG by `CGColorSpaceUsesITUR_2100TF` plus the color space name. Headroom shown when non-zero |
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
| Attended pass | 0.9.2 | Stills and audio tables above, user guide, privacy line | 0.5 |
| B5 Audio on SDI | **0.9.3** | Card to v210, clock, setting, 48 kHz, attended SDI table | 2 |

About 5.5 sessions for 0.9.2. B5 carries the most risk, because the clock change is by reading only.
