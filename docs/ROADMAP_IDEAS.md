## HEVC 4:2:2 10-bit over SRT
Moved into the plan (2026-10-07): COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b.

## Export/Import Settings
Status: shipped in 0.9.2. Plan: docs/SETTINGS_EXPORT_PLAN.md
Version: 0.9.2

What: Export/Import Settings (shortcuts + streams) for moving between workstations. Decided 2026-11-03: streams export
complete, URLs and passphrases included, in a file encrypted with a password the user chooses (AES-GCM-256, PBKDF2-HMAC-SHA256).
A shortcuts-only file stays plain JSON. Stream import is add-only. The automatic backup covers shortcuts only.

Size guess: about 6 sessions

## Keyboard Shortcuts search: NSTableView reentrancy warning
Status: idea (2026-11-03)
Version: unscheduled

What: AppKit logged "Application performed a reentrant operation in its NSTableView delegate. This warning will become an assert in
the future." while Robbie typed "Loop" in the Keyboard Shortcuts search box (2026-11-03, confirmed by him). Typing filters the `List`,
which adds and removes whole `Section`s (`KeyboardShortcutsView.swift`). Seen once in seven days of logs and not on every search, so
it is intermittent. No visible effect today. The risk is that a future macOS turns it into a crash on typing in that box.

Next: reproduce it, then keep the sections' structure stable while filtering, or debounce the filter out of the delegate pass.
Check on each macOS beta.

## Reference HDR: SDR white and an optional tone map
Status: idea (2026-11-02)
Version: 0.9.3 or later

What: (1) use the display's White (Lw) as SDR white, so absolute PQ/HLG holds when SDR white isn't 100 nits;
(2) opt-in 'Tone map to display peak' in Reference: BT.2390 EETF from the file's mastering peak to a typed target
in nits; off = absolute with clipping; named in the readout; window only, never SDI/scopes/export.

Next: plan after 0.9.1.
Size guess: ?

## 4:4:4 SDI output
Status: idea (2026-10-10)
Version: ?

What: 10- and 12-bit RGB 4:4:4 output on the DeckLink 8K Pro; SDI link configuration (single, dual or
quad link); follow-source vs manual choice in the DeckLink menu.

Why: send 4:4:4 sources to reference monitors at full chroma. SDI itself carries 4:4:4 (3G HD 4:4:4;
6G/12G UHD 4:4:4 single-link; dual and quad link). Manifold's output is 4:2:2 only because DeckLink
output uses v210 today. For 1.0 it stays v210, and 4:4:4 sources are reduced once at that output with
the D3 halfband (COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b).

Depends on: native chroma decode (Stage 3b, S1–S2). 12-bit needs the float32 offscreen deferred in D5.
Size guess: ?

## SDI sound from live 44.1 kHz sources, and from 88.2/96 kHz files
Status: idea (Robbie, 2026-11-11)
Version: after 0.9.3

What: (1) a live source whose sound is 44.1 kHz (SRT, WHEP, NDI) reaches SDI resampled to 48 kHz, as a 44.1 kHz file
already does; (2) a file at 88.2 or 96 kHz reaches SDI resampled to 48 kHz.

Why: SDI embeds 48 kHz only (`DeckLinkService.isSupportedForSDI`). Today those sources play on SDI with no sound: the
output starts video-only and says so in the log. Since 1c follow-up C7 (CARD_CLOCK_FINDINGS.md §10.23) a 44.1 kHz
FILE is resampled once, in the tap (`AudioTapBuffer`, `PolyphaseResampler`, 64 taps), on the file's own time axis.

Open questions:
- Live: the tap's resampled stream is keyed on the file's time axis. A live source's axis is its own clock, re-anchored
  at joins and gaps, so where a resampled stream restarts, and how its group delay is kept out of the source's offset O
  (AUDIO_RESAMPLER_DESIGN.md §19.1), needs its own design. Verified against a non-Cloudflare server (CLAUDE.md).
- 88.2/96 kHz: 2:1 decimation for 96 kHz, a 147:160 ratio for 88.2; the prototype filter's band edge for each.

Depends on: Stage 1c (0.9.3).
Size guess: ?

## DeckLink 8K Pro: a sub-device mapping for output plus capture
Status: idea (Robbie, 2026-11-12)
Version: after 0.9.3

What: switch Robbie's DeckLink 8K Pro G2 to the "SDI 1 In or Out" connector mapping (4 sub-devices):
- SDI 1 = device (1), input from the M3 Ultra, for Omniscope;
- SDI 3 = device (2), output: Manifold to the FSI XMP551, input 2;
- SDI 4 = device (4), output for tests, looped to SDI 2 = device (3), input, for capture.

Then 100 output restarts while playing at 59.94 with an input open on a different sub-device (device (3)), to confirm the
silent start does not occur. If confirmed, recommend that mapping in the release notes to 8K Pro owners who also capture.

Why: the silent start at output start (no SDI sound for the session, recovered by a full output restart) has so far needed
the card's input open on the output's own sub-device at Start: 0 in 408 starts closed, 7 in 303 open (CARD_CLOCK_FINDINGS.md
§10.26, follow-ups 5 and 6). Classified as a test-rig condition; the recovery stays as the safety net.

Depends on: nothing in Manifold. The output-device menu item below makes the mapping easier to use.
Size guess: an afternoon (the mapping change, a guarded 30 min run).

## DeckLink output-device menu: grey out sub-devices the mapping makes inactive
Status: built 2026-11-15, not committed; unit-tested; attended check passed 2026-11-15 (decided Robbie, 2026-11-14; idea 2026-11-12)
Attended (Robbie, 2026-11-15): the lists match Blackmagic's table, 1, 1, 2 and 4 devices across the four mappings. A mapping
change during playback stopped output, with the banner.
Version: after 0.9.3

Built (2026-11-15): each device's `BMDDeckLinkDuplex` (IDeckLinkProfileAttributes, active profile) is read at enumeration;
`bmdDuplexInactive` rows are greyed in the DeckLink menu and in Settings ▸ DeckLink Output, with "Inactive in the card's current
connector mapping". An `IDeckLinkProfileCallback` is installed on every device with an `IDeckLinkProfileManager`; on
`ProfileActivated` the list is re-read. If the selected device is inactive (or the driver force-stopped its stream,
`streamsWillBeForcedToStop`), output stops and the refusal banner says why; Manifold never selects another device. A start on an
inactive device is refused with a message. SDK 16.0 manual: §2.4.11 (p.31–33), §2.5.48 (p.192–193), BMDDeckLinkDuplex (p.274),
§3.60 (p.299). Code: `DeckLinkConnectorMapping` (DeckLinkRefusal package, tests), `DeckLinkBridge.installProfileCallbacks`,
`DeckLinkService.connectorMappingChanged`.

Open question answered (2026-11-15): the attribute is `BMDDeckLinkDuplex`. Read on the 8K Pro by a read-only probe under
"SDI 1 & 2 In, SDI 3 & 4 Out" (one sub-device): (1) `dxfu`, (2)–(4) `dxin`; all four vend `IDeckLinkOutput` and a profile
manager. The second mapping is the attended step.

Limits: a card connected after the first device refresh gets no profile callback until relaunch. Whether a menu that is OPEN
while the mapping changes redraws is UNKNOWN; the next opening shows the new state.

What: the DeckLink output-device menu lists all four sub-devices of an 8K Pro even when the card's connector mapping makes
some of them inactive (input-only, or not mapped to a connector). **Decided:** grey them out, using the SDK's duplex / active
attribute for each sub-device, with a short note why (for example "Inactive in this card's connector mapping: change it in
Desktop Video Setup"). The menu **updates live** on the SDK's profile-change notification, so a mapping changed in Desktop Video
Setup while Manifold runs shows at once.

Why: with a mapping such as "SDI 1 In or Out" (item above), picking a sub-device that cannot output gives no picture and no
clue why.

Open question: the exact attribute (the profile's duplex mode, `BMDDeckLinkDuplex`, or the device's active/inactive status
under the current profile), to be confirmed against the SDK headers and on the 8K Pro in two mappings.

Depends on: the "Open Desktop Video Setup" button (below) for the note's way out.
Size guess: ?

## Settings ▸ DeckLink: an "Open Desktop Video Setup" button
Status: built 2026-11-15, not committed; attended check passed 2026-11-15 (decided Robbie, 2026-11-14)
Attended (Robbie, 2026-11-15): Desktop Video Setup opens from both places.
Version: after 0.9.3

Built (2026-11-15): "Open Desktop Video Setup…" in Settings ▸ DeckLink Output ▸ Device and in the DeckLink menu under the
device list. Bundle ID `com.blackmagic-design.desktopvideo.utility`, read from the installed app's Info.plist
(`/Applications/Blackmagic Desktop Video/Desktop Video Setup.app`); resolved through `NSWorkspace.urlForApplication(withBundleIdentifier:)`
and opened with `openApplication(at:)`; hidden when it does not resolve. `App/DeckLink/DesktopVideoSetup.swift`.

What: a button in Settings ▸ DeckLink Output that opens Blackmagic's Desktop Video Setup, **shown only if Desktop Video is
installed**. Opened by its bundle ID through Launch Services (`NSWorkspace` URL for the bundle ID), never by a hard-coded path;
hidden when the bundle ID does not resolve.

Why: the connector mapping, the input connection and the card's other settings live there, and the menu note above, the silent
start advice and the guide (below) all send the user to it.

Size guess: small.

## Share Frame…
Status: built 2026-11-15, not committed; first attended check passed 2026-11-15; follow-ups 1–5 and 7 attended 2026-11-15, all
six steps passed (Robbie). Second follow-ups (⇧⌘E, "(SDR)") built 2026-11-15, attended check outstanding.
Attended (Robbie, 2026-11-15, follow-ups): all six steps passed. A UHD Rec. 709 frame shared at 4.4 MB, a little above the
1.0–4.0 MB benchmark range.
Attended (Robbie, 2026-11-15): Share works from More and from the Full-layout button, and the layout switches to Compact cleanly. A PQ
frame (the PNG of the first build) shared to iPhone Messages arrived correctly tone-mapped to SDR, with cICP 9-16-9 honoured.
Version: after 0.9.3

What: "Share Frame…" directly under Export Frame in More (…) and in the File menu; a registry action, `file.shareFrame`,
default key **⇧⌘E** (Robbie, 2026-11-15; ⇧⌥⌘E earlier the same day). ⇧⌘E was checked free against Manifold's actions,
`ShortcutRegistry.reserved`, the system symbolic hotkeys and the Services' key equivalents on the build Mac.
**HDR clarity (2026-11-15):** while the picture (picture codes) is PQ or HLG, File ▸ Share Frame…, the More item and the Share
button's tooltip read "Share Frame (SDR)…", and the shared file's name ends in " SDR" ("MyClip 01-02-14-05 SDR.jpg"). An SDR
picture is unchanged. `ShareLabel`, tested; the File menu follows the key window (`SharePictureState`). In the Full layout, which has no More menu, a standalone Share button (`square.and.arrow.up`, tooltip
"Share Frame…") sits beside Export (Robbie, 2026-11-15). The sheet opens on More (…) in Compact and Narrow and on the Share button
in Full, from the menu item too.
The image (follow-up 1, decided Robbie, 2026-11-15) is an **8-bit SDR JPEG, quality 0.9, Rec. 709 primaries, tagged sRGB**:
Export Frame's capture drawn into an 8-bit sRGB context with `CGContext.draw` (ColorSync's default conversion, which tone-maps
HLG and PQ), then ImageIO (`ShareJPEG`, FrameShareFormat package). HLG matches As macOS Shows It on an SDR display within 1 code.
**PQ does not quite:** it gets the `.ifSupported` curve, up to 14 codes darker below 200 nits. No API reproduces As macOS Shows It's
PQ curve (`docs/HLG_MACOS_MODE_PLAN.md` §3.10e). Export Frame is unchanged (16-bit PNG). Typical size, measured 2026-11-15 on real
frames: 4K 1.0–4.0 MB (graded commercial frames 3.5–4.0 MB, a PQ HDR10 frame 1.05 MB), 1080p 0.13–0.97 MB (4K frames scaled down).
The file is written to
`~/Library/Caches/<bundle id>/Shared Frames/<uuid>/` and deleted when the service reports done or failed, or the sheet is
cancelled; leftovers are swept at the next share, at launch and at quit. One log line, "[SHARE] frame shared". `App/FrameShare.swift`.

File names (follow-up 2): for Export and Share, a file is named "<clip name> <HH-MM-SS-FF>". The timecode is the source timecode
when the file has a timecode track, otherwise the elapsed time, read at the playhead as the transport readout shows it. Example:
"MyClip 01-02-14-05.jpg". A stream is named "<stream name> <yyyy-MM-dd HH-mm-ss>"; with no name, "Manifold frame <date time>".
Export keeps .png and the `_par…` tag. An export never replaces an earlier one: the same frame twice gets " 2", " 3", as in Finder.
During playback the name is the playhead's, and the captured picture can be a frame or two behind it. `FrameFileName`, tested.

Focus (follow-up 4): when the sheet closes, sent or cancelled, the player view takes first responder, so the Open button no longer
gets a focus ring. Export Frame reads "Export Frame…" in the File menu, More and the button's tooltip (follow-up 5).

Folder per clip (follow-up 7): Settings ▸ Frame Export ▸ "Put exported frames in a folder per clip", default off. When on, Export
Frame saves to <export folder>/<clip or stream name>/, creating the folder if needed. The folder name is the same name the files
use, made safe (/ and : become -, trimmed, at most 100 bytes). If a file has that name, or the folder can't be created, the frame
goes in the export folder and the banner says so. Share is unaffected.

**HDR, decided 2026-11-15 (follow-up 1 above); the original question is kept for the record:** for a PQ or HLG picture, Export Frame
(and so, in the first build, Share) writes a 16-bit PNG of the **signal
values** (BT.2020 primaries, PQ or HLG code values), tagged with an ICC profile and a `cICP` chunk: 9,16,0,1 for PQ, 9,18,0,1 for
HLG (measured 2026-11-15 by writing a frame through the same ImageIO path). A viewer that reads `cICP` or the HDR ICC shows it as
HDR; one that reads neither shows the code values as SDR: PQ diffuse white near half grey, flat and desaturated; HLG closer but
still desaturated. What Messages and Mail do with it (convert, keep `cICP`, tone map) is UNKNOWN until the attended step; the
recipient's app matters as much. **Proposal, not built:** a Share-only "SDR (Rec. 709)" choice for HDR pictures: tone-mapped to
an 8-bit sRGB/Rec. 709 PNG or JPEG, named in the file name, with Export Frame unchanged.

Watch: whether Mail or AirDrop reads the file after reporting done. If an attachment arrives empty, delay the deletion.

## Share HDR stills as HDR
Status: idea (Robbie, 2026-11-15)
Version: after the Share Frame follow-ups build

What: share an HDR picture as HDR rather than tone-mapped SDR: a JPEG or HEIC with an ISO gain map written by ImageIO
(`kCGImageDestinationEncodeRequest` = `kCGImageDestinationEncodeToISOGainmap`, macOS 15), or AVIF. A viewer that does not read the
gain map shows the SDR base image. Open: which base image to use (the `ShareJPEG` SDR rendering, or ImageIO's own), how Messages and
Mail on iPhone and Mac handle each format, and the file size.

Size guess: small to a session, mostly attended checks.

## Share for stills
Status: idea (Robbie, 2026-11-15)
Version: after the Share Frame follow-ups build

What: Share Frame… for an open still image shares the still file itself, unconverted, rather than a rendered frame. Today Share
Frame, like Export Frame, is disabled for anything but video (`engine.mediaKind != .video`).

Size guess: small.

## Sync and Color Guide: "Setting up your DeckLink"
Status: decided (Robbie, 2026-11-14)
Version: after 0.9.3

What: a new section of the built-in Help ▸ Sync and Color Guide:
- **Connector mapping for cards that also capture:** use a mapping that gives output and capture separate sub-devices (on the
  8K Pro, for example "SDI 1 In or Out"), with why (the silent start, CARD_CLOCK_FINDINGS.md §10.26).
- **Which sub-device Manifold uses:** the one chosen in the DeckLink output-device menu; inactive ones are greyed (item above).
- **The 8K Pro's connector-to-device table** for its mappings, from Blackmagic's documentation, checked on the card.

Depends on: the sub-device mapping test (item above) for the recommendation; the menu item for the greyed entries.
Size guess: a session.

## HEVC over WHEP
Status: idea (2026-10-07)
Version: ?

What: Negotiate and decode HEVC on WHEP, alongside H.264.

Why: 10-bit HDR over WebRTC. WHEP is H.264-only today, and OBS's H.264 HDR is 8-bit, so it bands
(COLOR_MANAGEMENT_FINDINGS.md §6.9, *The OBS re-check*).

Open questions:
- Browser and server HEVC support is uneven (MediaMTX, Cloudflare).
- Negotiation, and falling back to H.264 when the server won't offer HEVC.

Depends on: HEVC over SRT (shared parser/decoder work).
Size guess: ?

## Timecoded markers with EDL export
Status: built in markers v1 (v1 complete, Robbie, 2026-11-15; idea 2026-10-06). Plan: docs/MARKERS_PLAN.md
Version: 0.9.4

Built: files only (live streams later, `docs/MARKERS_PLAN.md:7`). Markers carry source timecode. Resolve marker EDL
export and import, CSV and plain-text export (`docs/MARKERS_PLAN.md:567`); the Resolve round trip passed on 23.976 and
29.97 DF (M1/M4, §14.1). Stored per file, by content fingerprint, while Remember markers between sessions is on (§5.2).
The open questions below are answered in the plan's decisions (§9). Not in v1: Premiere/Avid/FCPXML, Send to Resolve,
live streams, audio-only (`docs/MARKERS_PLAN.md:792`).

What: Drop markers on the timeline at the current timecode, with a colour and a note, and export them as a marker EDL that Resolve (and others) can import.

Why: A reviewer watching in Manifold can flag shots ("sky too cyan at 01:02:14:05") and hand the colourist a file that lands as markers on their timeline, instead of a typed list of timecodes.

Must:
- Markers carry source timecode, not elapsed time.
- Export round-trips into Resolve without retyping.

Open questions:
- Which EDL flavour(s): Resolve's marker EDL, Avid locators, CSV?
- Files only, or live streams too (timecode on streams isn't always present)?
- Saved with the file, or per session?

Depends on: shortcut registry (marker keys), reliable timecode readout.
Size guess: medium.

## Markers: user guide section
Status: idea (Robbie, 2026-11-15)
Version: when the user guide is written

What: a "Markers" section in the user guide, featuring the start-timecode override (the Markers slot's gear menu): files
without timecode count from 00:00:00:00, and Resolve's default timeline starts at 01:00:00:00, so set the override before
exporting (`docs/MARKERS_PLAN.md` §14.5).

Size guess: small.

## Markers: thicker duration band
Status: idea (Robbie, 2026-11-15)
Version: only if testers ask

What: make the marker duration band on the timeline strip slightly thicker, if testers find it hard to see.

Size guess: small.

## Send markers to Flip
Status: idea (Robbie, 2026-11-17)
Version: later, after the Chapter list export (`docs/CHAPTER_MARKERS_PLAN.md` §15)

What: hand a file's markers to Flip, which writes them into the file as embedded chapters (Flip already writes chapters
by a stream-copy remux, `~/Code/Flip/Flip/electron/ffmpeg.js:493-519`), so a review's markers travel inside the media.
Manifold never rewrites media itself.

Open questions:
- how the two apps hand over: the ffmetadata list from §15, a file Flip opens, or a URL scheme;
- Flip's escaping gap on write (`CHAPTER_MARKERS_PLAN.md` §9.3) must be fixed first, or titles with `=`, `;`, `#`, `\` change;
- whether notes, colors and keywords should travel as XMP markers (Stage 3's reader, in reverse) rather than plain chapters.

Depends on: the Chapter list export; a Flip change.
Size guess: medium (both apps).

## Social Reframes with Export
Status: idea (2026-10-06)
Version: 1.5?

What: We already have ability to preview social framing but no way to  pan, zoom or move the image underneath that framing.  Once set we should also have the ability to export to Apple included export types like ProRes and h264/HEVC

Why: Literally everyone has asked me if we can export when they see the social previews

Must:
- pan/zoom/reframe within the dimensions of the social framing preset
- export as previewed to ProRes or h264/HEVC
- not touch the original file and when social preview is turned of or export done returns to the original loaded file

Open questions:
- How to pan/scan within the player window
- Can we export without needing 3rd party tools

Depends on: unsure
Size guess: large

## Load Audio Files Only
Status: shipped in the window in 0.9.2; SDI (B5) built 2026-11-14 for 0.9.3, on the card-clock path with the window's card (uncommitted; CARD_CLOCK_FINDINGS.md §10.31). Plan: docs/STILLS_AND_AUDIO_ONLY_PLAN.md
Version: 0.9.2 in the window (B4); 0.9.3 on SDI (B5)

What: Ability to load audio files with no video - stereo, mono, 5.1 etc

Why: QuickTime, Screen etc all do it and its expectation that many users will have

Must:
- open pcm, aac, mp3, m4a
- audio declarations/channel assignments just as with married audio to a video file
- clear thats audio only - via removing video frame, onscreen text or some other method
- still support DECKLINK by putting a black or template video image with the audio when sent via decklink

Open questions:
- Do we need anything else to support various codecs/containers that are audio only?
- Can we export without needing 3rd party tools

Depends on: unsure
Size guess: medium

## Audio-only files: output-mode menu wording and memory
Status: decided (Robbie, 2026-11-14)
Version: after 0.9.3

What: two small changes to the DeckLink output-mode menu while an audio-only file is open (B5,
CARD_CLOCK_FINDINGS.md §10.31):
- word the disabled item "Follow source — no video in this file", so it says why Follow source cannot apply;
- remember the last output mode chosen for audio-only files, if it does not already. Whether it does today is UNKNOWN: check
  first (D4a's manual pick, `DeckLinkService.swift`, and how an audio-only file resolves the mode).

Why: an audio-only file has no source rate to follow, so the item is disabled with no reason given, and the mode for its card is
picked again by hand.

Depends on: nothing.
Size guess: small.

## Load Still Images
Status: shipped in 0.9.2. Plan: docs/STILLS_AND_AUDIO_ONLY_PLAN.md
Version: 0.9.2. No Manifold color management: shown as macOS shows it. Not sent to SDI or HDMI in v1. DPX out for v1

What: Ability to load stills - png, jpeg, tiff and HDR image formats like AVIF, JPEGR

Why: QuickTime, Screen etc all do it and its expectation that many users will have

Must:
- open all standard SDR image formats.  HDR formats are a bonus
- read embeded color profiles and either display correctly or convert to standard space like sRGB/709

Open questions:
- Do we need anything else to support various codecs/containers for still images?

Depends on: unsure
Size guess: medium

## Scopes for a gain-map still's HDR rendition
Status: idea (2026-11-05)
Version: after 0.9.2

Stills scope the SDR base image today, with the header "SDR base image (gain map not applied)".

Idea: a scope-header toggle, "SDR base / HDR (file capacity)". The HDR version is decoded with Core Image `.expandToHDR`, not ImageIO's
DecodeToHDR, which decodes for a target headroom of 8 (docs/STILLS_AND_AUDIO_ONLY_PLAN.md, B0 result), and read on the nits scale with 1.0 = 203 nits.

Size guess: Small

## Load DCPs and IMFs for viewing
Status: idea (2026-10-06)
Version: 1.5?

What: Ability to load a DCP or IMF package to preview

Why: Resolve loads DCPs and IMFS just like they were any other single file but thats open resolve, start a project etc its a lot of steps

Must:
- parse the package and render audio/video just like another file
- Convert from XYZ to a chosen color space  - this probably needs a picker but Rec709/Display P3 etc would work
- Protect the DCP/IMF package from corruption or messing with XMLs.  Hash must not be modified 

Open questions:
- What are the licensing ramifications ?

Depends on: unsure
Size guess: Large

## Dolby Vision - Mezzanine + DV XML
Status: idea (2026-10-06)
Version: 1.5?

What: Ability to load a PQ encoded ProRes + marry a Dolby Vision XML

Why: Quickly preview Dolby Vision files 

Must:
- parse the XML trim metadata in real time and accurently to the mezzanine
- No XML editing
- Protect the XML and never modify it

Open questions:
- What are the licensing ramifications ?

Depends on: unsure
Size guess: Large

## Embed Chapter Markers
Status: idea (2026-10-06)
Version: 1.5?

What: Similar to timecoded markers - add chapter markers to the stream

Why: Social media, YouTube etc

Must:
- be timecode accurate
- Generous character length and support of special characters
- Be able to see a chohesive list of chapters once added

Open questions:
- none

Depends on: unsure
Size guess: medium

## Subtitle Generation
Status: idea (2026-10-06)
Version: 2.0

What: Add ability to generate subs directly from manifold

Why: Social media, YouTube etc

Must:
- accurate, and fast subtitle creation
- Ideally support not just english but multiple languages
- Be editable
- Be free to use

Open questions:
- Licensing 

Depends on: unsure
Size guess: Large

Research notes (2026-10-08, unverified, check before committing):
- License constraint: permissive only (MIT / Apache / CC-BY with attribution). No GPL.
- Candidates:
  - Apple SpeechAnalyzer / SpeechTranscriber (macOS 26): on-device, built into the OS, no model to ship or license to manage. Unknowns: accuracy on difficult material, language coverage; ties the feature to macOS 26+.
  - Whisper (MIT) via WhisperKit (Swift/Core ML, MIT) or whisper.cpp (Metal/Core ML, MIT). large-v3 for accuracy, large-v3-turbo for speed. Needs voice-activity detection to avoid hallucinated text in silence/music.
  - NVIDIA Parakeet (CC-BY-4.0): very accurate and fast, narrower language coverage, Mac ports less mature.
- Beyond transcription: subtitle line segmentation and timing (reading speed, line length, shot changes), export (SRT, WebVTT, possibly SCC/608), optional speaker labels (diarization model licenses need checking).
- Suggested first step: prototype with Apple's framework (no dependencies), benchmark against WhisperKit large-v3-turbo on real programme clips, decide from the accuracy gap.

## Scope preferences in settings export
Status: idea (2026-11-16)
Version: unscheduled

What: Export/Import Settings carries shortcuts and streams (with their saved A/V offsets). No scope preference is exported: not Master scope intensity
(`globalScopeIntensity`), not Graticule brightness (`scopeGraticuleBrightness`, 0.9.5), not the per-scope intensities, colors,
scales or overlays. `docs/SETTINGS_EXPORT_PLAN.md` §1 (line 105) lists "Look of scopes, guides, safe zones" as "Out, next": about 50 keys, each
needing a range check, best added as one reviewed "Preferences" section.

## Scopes: SIMD-aggregated histogram atomics
Status: idea (2026-11-16)
Version: unscheduled (not 0.9.5)

Performance. Measured on UHD 24p (DEBUG, `MANIFOLD_SCOPE_PERF=1`), with column counts cols.wf 640, cols.parade 192 and cols.yrgb 128:

| Layout | Clip | gpu.wf | gpu.parade | gpu.yrgb |
|---|---|---|---|---|
| Waveform \| YRGB \| Parade | `HDR TEST.mov`: UHD 23.976 ProRes 4444, PQ, tagged limited | ≈ 0.8 ms | ≈ 3.7 ms | ≈ 7.1 ms (7.4 before concurrent dispatch) |
| YRGB \| Meters \| Meters | BPI Instacart: UHD 23.976 SDR Rec. 709 | – | – | ≈ 1.8 ms |

- **Queue contention.** Most of the three-scope figure is contention: every scope commits to one shared scope queue,
  and `gpuEndTime − gpuStartTime` counts time spent sharing the GPU with the other scopes' buffers as the scope's own.
  **Indicative only (2026-11-18):** the two rows above are different clips, so the alone-versus-together ratio (about a
  quarter) mixes contention with content. The authoritative result is the single-file UHD 59.94 run on
  `perf_motion_2160p5994_100s.mov` (ProRes 422 HQ): no frame drops, gpu.yrgb ≈ 4.5–4.8 ms with three scopes
  (docs/SCOPES_095_PLAN.md, "Does window playback drop frames under heavy scopes?"). A fair re-measure uses that one
  file, YRGB alone and with three scopes.
- **Atomics.** The remaining per-scope cost is device atomics serializing at narrow columns. Each pixel ends in an
  `atomic_fetch_add` at `hist[row·cols + bucket]`. With few columns, neighboring pixels land on the same address
  (at 128 columns, 30 source pixels per bucket at UHD) (docs/SCOPES_095_PLAN.md, "As implemented: YRGB follow-up").

Proposal: in `waveformKernel` and `paradeKernel` (App/PassthroughShader.metal), lanes of a SIMD group that share an
address sum their increments, and one lane issues a single device atomic. Counts are integers, so every histogram
stays the same.

Conditions:
- The GPU self-check (docs/SCOPES_095_PLAN.md §1.6, item 2) is built first, and it shows identical histograms.
- Before and after readings are taken on every scope, alone and with the others open, all on one file
  (`perf_motion_2160p5994_100s.mov`). Wide columns on noisy content may cost more.

Also worth considering: whether all scopes need one shared queue, or whether each scope should get its own queue or
its own timing measure. One shared queue is what makes the three-scope readings overlap.

Size guess: Medium

## Card pull: sticky would-repeat band
Version: after 1.0 (deferred from 0.9.6, Robbie, 2026-11-27)

What: after a Play's first timed pull, the would-repeat test at a matched rate allows 0.5 ms past the half-frame band, so a Play that starts at the band's edge stops repeating a frame (`CARD_PULL_MARGIN.md` §21.4, §21.6); needs its own soak with `MANIFOLD_DECKLINK_CADENCE_LOG=2`.

Trigger: edge-start holds at 59.94 seen outside the rehearsal (a tester report, or a soak other than the release rehearsal). Until then it stays a known limitation: rarely, one repeated frame at the start of a 59.94 Play (`BUGS.md`, the LOW known-limitation entry). Design and the replays: `CARD_PULL_MARGIN.md` §21.6–§21.7.

## Window presents on its own display link (option A)
Version: after 1.0 (deferred from 0.9.6, Robbie, 2026-11-27)

What: with output on, the window presents on its own thread at its display's own refresh, from a newest-frame mailbox, so the SDI pacer never touches the `CAMetalLayer` and a WindowServer stall can't reach the SDI tick. Plain B (the 0.9.5 default) took the transaction off the pacer's presents; option A takes the present off the pacer altogether. Design, the nights behind it and the rollout (a DEBUG switch, off by default, first): `WINDOW_PRESENT_PATH.md` §4.2, with the night 4 and plain-B follow-ups later in that file.

Triggers, either one:
- testers report SDI repeats during playback;
- the window's frame drops at 100 or 119.88 fps on a 120 Hz display with output on start to matter (today a known limitation for 1.0; `BUGS.md`, the plain-B entry's residual costs).

## Markers scope: comment lines option (1 / 2 / 3)
Version: 0.9.6

What: today the comment is one line, truncated, with the full text in the hover tooltip. An option for 1, 2 or 3 lines; more lines change row height.

## Soak harness: stable accessibility identifiers for the controls it drives
Version: 0.9.6

What: give the controls the release soak drives stable accessibility identifiers (`.accessibilityIdentifier`, never shown, never translated), and have `scripts/decklink-loopback/rc-soak-ax.swift` find them by identifier, not by tooltip or title. Today the helper finds the Markers scope gear by its exact tooltip (`gearHelps`) and Regenerate Thumbnails by its title. 82e39bc added "text size" to the gear's tooltip, so the 0.9.5 final soak (2026-11-21) never found the gear: all 30 Regenerates went unpressed and the night failed on markers only (`Manifold-BUILD.md`, final-soak markers follow-up). This is the second break from tooltip text after the colours → colors change (4067abb). In scope: the Markers gear, Regenerate Thumbnails, and the other gear items the helper may press (Open Markers Editor, text size). Worth considering: the menu items `rc-soak.py` clicks by title (File ▸ Start/Stop DeckLink Output, File ▸ Close All, Mark ▸ Add Marker), and the window `linkpace-ax place` finds by title. Keep the tooltip match as a fallback for older binaries. A unit or UI test should pin the identifiers so a copy edit cannot break the soak again.
