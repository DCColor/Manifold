# Manifold — Release Notes

Published with each release. `scripts/release-mac.sh` hands this file to the shared uploader,
which parses the section matching the version being released and puts the entries into the R2
manifest as a `notes` array. Keep entries short — they render in an update dialog, not on a
changelog page. Format notes are at the bottom.

## Next release

Draft, covering everything since 0.8.4 (`dd3984b`). Only the `-` bullets under New, Improved, Fixed
and Known limitations reach the update dialog. The uploader ignores sub-headings, this paragraph,
the numbered Highlights and the changelog tables, so none of them are duplicated in the dialog. Keep
a blank line between the last bullet and anything that follows it, or that text is glued onto the
bullet.

### Highlights

1. **Sound and picture stay in sync on live streams.** SRT, WHEP and NDI were each out by a fixed or
   drifting amount in 0.8.4. They now hold sync, verified over sessions of several hours.
2. **Audio sync calibration and per-stream offsets**, in a new A/V menu: measure a stream's offset
   with a Manifold sync clip, nudge it by the millisecond, and save it with the stream.
3. **Live streams show the color they declare,** including PQ and HLG HDR over SRT and WHEP, and
   HEVC now plays over SRT, including 10-bit HDR.
4. **OS or Bypass, per window:** choose whether macOS color-manages the picture, and read exactly
   what is happening between the source and your screen.
5. **SRT is much sturdier:** faster to start, no more break-ups or missing sound with common encoders.

### New

- Display transform, per window: OS (macOS color-manages the picture for your display) or Bypass (the picture's values go to the screen untouched). Choose it from the control bar or the Color menu. A window in Bypass says so in its title.
- A display chain readout shows the source's color and whether it was declared or assumed, the transform in use, your display and its curve, and for SRT and WHEP the amount of buffering.
- HEVC (Main and Main 10, 4:2:0) now plays over SRT, including 10-bit HDR. HEVC 4:2:2 and 4:4:4 streams are refused with a message saying so, never quietly converted.
- Audio offset for live streams, in the A/V menu: ⌥] and ⌥[ move the sound 1 ms later or earlier (add ⇧ for 10 ms). Save the offset with a saved stream and it comes back every time. A badge and the window title show when an offset is on.
- Calibration (A/V ▸ Calibrate…): loop a Manifold sync clip on the sender and Manifold measures how far apart sound and picture are, then offers the correction. It never applies anything by itself. A/V ▸ Save Sync Clip… saves the clip that matches the stream's frame rate.

### Improved

- SRT and WHEP now show the color the stream declares. A stream tagged HDR (PQ or HLG) is shown and scoped as HDR instead of as standard Rec. 709. A stream that declares nothing is still treated as Rec. 709.
- SRT streams start showing picture much sooner, especially at low bitrates. A static slate or bars feed used to take a minute or more to appear. It now takes a second or two.
- WHEP from Cloudflare Stream keeps sound and picture in sync for long sessions: verified over four and a half hours, including with picture and sound sent out over SDI.
- SRT buffering adapts to the sender. Encoders that send audio in large chunks, or use B-frames, get a slightly larger buffer automatically, and the chain readout says how much and why.
- SDI output follows an SRT stream's own frame rate. If a stream labels its frame rate wrongly, the output follows the rate the stream actually runs at.

### Fixed

- Fixed: SRT sound played about 200 ms behind the picture.
- Fixed: NDI sound played about a quarter of a second behind the picture.
- Fixed: WHEP sound and picture were out by a different amount every session, and drifted further apart over long sessions.
- Fixed: SRT sound from Cloudflare could sound distorted and gravelly.
- Fixed: SRT streams from some encoders (ffmpeg, and likely hardware encoders) had no sound at all.
- Fixed: SRT sound broke up on low-bitrate streams and with encoders that send audio in large chunks.
- Fixed: after reconnecting, an SRT stream could stop about 17 seconds in with "The stream stopped sending video" while it was still playing.
- Fixed: after an NDI or HLS stream ended, a file played next ran its picture about 0.2 s ahead of its sound.
- Fixed: SDI audio dropped out every few seconds during file playback.
- Fixed: streams using the BT.470BG color matrix, common from European encoders, were decoded with Rec. 709 coefficients, giving a small color shift.
- Fixed: the scopes could keep an earlier source's color settings (scale, gamut target and labels) after switching to a WHEP or HLS stream, after a stream ended, or when the scopes tray was opened or closed during a live stream. The scopes now always describe what is playing.

### Known limitations

- Known limitation: interlaced sources go out over SDI as progressive: a 1080i59.94 source is sent as 1080p29.97, with both fields woven into each frame. An interlaced NDI source arrives already deinterlaced by NDI.
- Known limitation: SDI audio goes silent for up to about a tenth of a second at each seek, scrub release and loop point during file playback.
- Known limitation: HLS streams in P3 or Rec. 2020 SDR are not yet labeled correctly, and NDI's Rec. 2020 SDR setting is shown with Rec. 709 primaries.
- Known limitation: after a network stall of a second or more, live sound can stay 10–20 ms late for up to a minute before it settles.
- Known limitation: OBS stamps 23.976 fps WHIP video very slightly fast. MediaMTX on its default settings passes that through, so sound and picture drift apart by about a quarter of a second an hour over WHEP. Set `useAbsoluteTimestamp: true` on the MediaMTX path to fix it (passed in our tests with two different OBS sources). Cloudflare Stream corrects it automatically.

### Detailed changelog

Every commit since `dd3984b` (0.8.4), grouped by area. "Visible?" says whether a user would notice;
**Unsure** rows carry the reason and need a decision before release.

#### Live audio sync

| Change | Commits | Visible? |
|---|---|---|
| SRT live audio cushion set to 0: SRT sound no longer ~200 ms behind the picture | `e318aa6` | Yes |
| Live audio passes through a new sample-rate converter (polyphase, 64-tap) that steers sound onto the picture's clock, replacing the old clock-rate pushes that muted the renderer; removes periodic stutter on live audio | `a866e99` `b3d194d` `d8b8028` `b76dc3f` `e8f822e` | **Unsure**: the stutter removal is measured at the device output (resampler step 3), but it has no BUGS.md entry of its own |
| Timeline jumps in the picture are followed by a short splice in the sound instead of a re-sync | `4443ab7` | **Unsure**: designed to be inaudible |
| Stall recovery re-syncs with one cut or catch-up; residual splices repeated | `df2b493` | **Unsure**: no BUGS.md entry ties it to a symptom |
| SRT: sound held, not glitched, when the renderer starves on a delivery stall | `d3b0831` | **Unsure**: BUGS.md L2294 still says OPEN in its heading, though its body says the fix is in |
| LiveClock start-up realign: removes a ~100 ms burst on the first connect after launch | `46c75d4` | **Unsure**: affected settling, probably not audible |
| WHEP audio timestamps on the 48 kHz sample axis | `4ef1254` | No (only mattered to the new converter) |
| Dead rate and position constants removed | `be983a0` | No |

#### Calibration and audio offsets (new in this release)

| Change | Commits | Visible? |
|---|---|---|
| Per-source audio offset, applied by splice | `98d1f69` | Yes |
| Per-bookmark offset, ⌥[ / ⌥] nudges, A/V badge, title marker | `f645dec` | Yes |
| Offset advance limits judged on the queue's recent low point; range error shown under the field | `0694481` | Yes |
| A saved sound-earlier offset is checked against the queue at the first anchor | `6132970` | Yes |
| Sync clip generator and verification; bundled loop-exact H.264 + PCM clips; ProRes masters in whole code cycles | `dfe6463` `5a1eaf8` `a350dd8` | Yes |
| Calibration mode: coded sync-clip matcher, sheet, A/V menu items | `23e8223` | Yes |
| WHEP calibration measured on the video timeline | `dcfb702` | Yes (a fix inside the new feature; not listed under Fixed) |

#### SRT

| Change | Commits | Visible? |
|---|---|---|
| Audio timestamps counted in samples, not taken from the sender's millisecond grid: fixes gravelly Cloudflare audio | `3749918` | Yes |
| AAC decode experiment with libavcodec, reverted to AudioToolbox the same day (no net change) | `167f7fe` `8c71bd2` | No |
| Media-stall watchdog re-baselined at identification: no false "stopped sending video" after a reconnect | `f6c3d61` | Yes |
| Multi-frame AAC packets split: sound from ffmpeg-style senders | `d3b0831` | Yes |
| AAC probe no longer holds every packet at start: picture in about a second | `c32c074` | Yes |
| Audio packing logged per packet (Stage 0b-1) | `d20ff96` | No |
| Cushion sized to the sender's audio packing; Buffer row in the chain readout | `6132970` | Yes |
| Cushion covers B-frame reordering | `5d623af` | Yes |
| HEVC parser enabled in the FFmpeg build | `f4b6746` | No |
| HEVC SPS color reader, codec-neutral SPSColor target | `fd657f7` | No (enables the next row) |
| HEVC Main / Main 10 4:2:0 plays; 4:2:2 and 4:4:4 refused with a banner | `a2e5ce1` | Yes |
| Declared frame rate with a timestamp-measured fallback | `ce3d828` | Yes |
| Measured frame rate wins when it clearly disagrees with the declared one | `a8b70fa` | Yes |

#### WHEP

| Change | Commits | Visible? |
|---|---|---|
| Audio RTCP sender reports parsed (log only) | `af4ebe0` | No |
| Manifold sends its own video RTCP (keyframe requests, receiver reports); sender reports selected by SSRC | `637120b` | **Unsure**: keyframe requests may speed recovery after loss, but BUGS.md L2564 says two servers ignore them |
| Audio aligned to video with an RTCP sender-report line fit: per-session lip-sync offset and long-session drift fixed (verified on Cloudflare) | `76ae8a1` `14f4b89` | Yes |
| Level-based queue correction at session start, then made observe-only | `1c901e4` `9e1724f` | No (net effect is diagnostic) |

#### NDI

| Change | Commits | Visible? |
|---|---|---|
| Picture held by the audio lead: NDI sound no longer ~250 ms late | `48ae1e8` `afcce50` | Yes |
| Hold uses the sender's timecode skew (~27 ms early at 23.976 before) | `a159fd3` | Yes |
| Falls back to the depth term when a sender's audio and video timecodes are on different clocks | `79b38e2` | Yes (for senders like Omniscope) |

#### HLS

| Change | Commits | Visible? |
|---|---|---|
| Renderer's clock restored on disconnect (NDI too): a file played afterwards is no longer ~195 ms out | `48ae1e8` | Yes |

#### DeckLink / SDI

| Change | Commits | Visible? |
|---|---|---|
| File playback feeds the SDI audio tap 250 ms ahead with a 4 s ring: no dropouts every few seconds | `109cfc3` | Yes. **Unsure on status**: the attended SDI check on the Resolve workstation is still pending (BUGS.md L1652) |
| Follow source uses SRT's declared, then measured, frame rate | `ce3d828` `a8b70fa` | Yes |

#### Color, display and scopes

| Change | Commits | Visible? |
|---|---|---|
| Per-window display transform, OS and Bypass | `c34a17c` | Yes |
| Transform pulldown, Bypass indicator, display chain readout | `55f8096` | Yes |
| "— Bypass" in the window title; readout follows a macOS HDR profile change | `2443151` | Yes |
| Source provenance (tagged / assumed / partly assumed / overridden) and full CICP in the readout, updated live | `6cb5460` | Yes |
| Scope color driven by the renderer's source state: no stale scale, gamut or labels | `946417a` | Yes |
| Declared color read from the H.264 SPS for SRT and WHEP | `418fcef` | Yes |
| Matrix 5 (BT.470BG) treated as 601 | `95563f7` | Yes |
| Colorimetry presets and tiers moved into the ColorimetryModel package | `07368d0` | No |

#### App, menus and diagnostics

| Change | Commits | Visible? |
|---|---|---|
| Debug menu hidden unless opted in | `4114995` | **Unsure**: 0.8.4 was build 18 and this landed 20 minutes later, bumping to build 19. If build 19 shipped as 0.8.4, users already have it; if not, 0.8.4 users lose a visible Debug menu |
| Diagnostics export reports EDR headroom from potential, not current | `cf18894` | **Unsure**: only visible in Export Diagnostics output |
| User-facing strings converted to American English ("Licenses" and others; BUGS.md, pre-ship checklist) | — | **Unsure**: verified 2026-09-21, but no commit or fix date is recorded |

#### Internal (build, telemetry, probes, test tooling)

| Change | Commits |
|---|---|
| Release configuration compiles again (`toneLock` declaration) | `d76bb21` |
| Release-archive telemetry assertion corrected | `f9880b3` |
| LiveClock telemetry no longer written to stderr in Release | `176ca03` |
| Audio-mirror rate pin removed | `8379c10` |
| DEBUG probes: destination color profile, paired timebase, A/V lag, A/V content, raw SR logging, WindowSizer deinit | `2db97b1` `61b9b69` `a90de72` `d3b0831` `c31ca83` `2c1da93` |
| Soak, replay and DeckLink test tooling; MediaMTX `useAbsoluteTimestamp` mode | `8389dd9` `5041fb8` `54750ad` `9b10b68` `73ef624` `b35a810` |
| Build hygiene: concurrency annotations, vendored-header warnings, ignore build folders | `f0969e4` `aa79682` `d055d07` |
| Documentation only (findings, plans, BUGS.md, roadmap, user guide drafts) | the remaining 49 commits |

## 0.8.4

- Live streams now carry audio on SDI. SRT, HLS, WHEP and NDI were all silent on the card before this.
- NDI sources now play audio on the Mac.
- Fixed: NDI audio was being rebuilt by the receiver instead of passed through. You now hear what the sender is sending.
- SDI output follows the source's resolution and frame rate on its own — files and all four stream types.
- You can still choose the output mode by hand, and a source that doesn't state its frame rate now says so.
- When the output mode doesn't match the source, Manifold tells you the picture is black instead of just showing black.

## 0.8.3

- DNxHR 4:4:4 files now decode correctly. They previously came up green and magenta — Manifold's
  own decoder can't read that profile. With Apple's Pro Video Formats installed, those files now
  go to the system decoder instead. Without it the picture is still wrong, but Manifold now says
  why rather than leaving you wondering whether the file is broken.
- Fixed: some MXF files declare full range in a way Manifold wasn't reading, so they came up with
  lifted blacks and clipped highlights. The inspector now reports what the file actually declares.
- Open Recent in the File menu.
- The inspector reports display aspect ratio — 1.78, 2.39 and so on — alongside the raster and
  pixel aspect.
- Pro Video Formats is listed in Settings under I/O and Runtimes, alongside the NDI runtime and
  DeckLink. It's an optional Apple package that adds AVC-Intra, XAVC, IMX, DVCPRO HD, uncompressed
  and ProRes RAW to what Manifold can open.
- Caption rows in the inspector are simpler: they say whether a service carries data, and the
  detail has moved to Export Diagnostics.
- Fixed: the app could take a long time to show its window at launch while it read your license
  from the keychain.

## 0.8.2

- Fixed: ARRI open-gate files were drawn slightly narrow, and the scopes were reading about 32
  columns of black at each edge. Manifold now crops to the picture the file declares, so what you
  see and what the scopes measure are the actual image.
- HLS streams. Paste an .m3u8 link and it plays, with the scopes and SDI following as they do for
  any other source. Video only in this release; audio is next.
- The inspector now reports embedded closed captions — CEA-608 and CEA-708, which services are
  present, in what language, and whether they carry any data. Reading them is a later release.
- Known: DNxHR 444 files may show incorrect color. A fix is in progress.

## 0.8.1

- Reference markers on the waveform, parade and vectorscope, alongside the one already on the
  meters. Type a value — a code, a nit level, a percentage, a hex color — and a line or a ring
  marks it. Two per scope.
- A skintone axis on the vectorscope, off by default, in the scope's own options.
- Scope options now open in a panel rather than a menu, so you can change several things without
  it closing each time.
- Manifold can now be the default app for MXF, QuickTime and MP4 files. Set it per file type in
  Settings; the file types you don't set are left alone.
- Fixed: some text read "licence" where it should have read "license".

## 0.8.0

- SRT streams now carry audio, including multichannel. Channel order is read from the stream
  rather than assumed.
- MXF and DNx files with several audio tracks can now be switched between. 0.7.0 said any audio
  track could be selected — that was true for QuickTime and MP4 but not for MXF, which only ever
  played its first track. It does now.
- The inspector shows audio tracks for MXF files, which it never has. Codec, layout, sample rate
  and bit depth, one row per track.
- Surround channels are named the way delivery layouts name them. Some files declare their
  surrounds in a way that was reaching the meters as Lsd and Rsd; a 5.1 has one surround pair and
  it reads Ls and Rs, and a 7.1 reads Ls Rs Lss Rss.
- Fixed: seeking an MXF could briefly play a moment of audio from before the seek.
- Scrubbing now shows real decoded frames from the file, so the picture you see while dragging
  is the frame you land on.
- Scopes move while you scrub. They used to freeze for the whole gesture.
- Fixed: HDR files no longer dim to SDR while scrubbing.
- Scrubbing MXF and DNx is much faster, and HDR MXF previews are no longer flattened to SDR.
- SDI output now follows the scrub, matching the desktop and the scopes. It previously held the
  frame you started from — worth knowing if you monitor SDI in a suite.

## 0.7.0

- Streams now carry audio. WHEP streams have never had sound — it simply wasn't received. Audio
  now plays in sync with picture, feeds the meters, and goes out over SDI like any other source.
  SRT audio is next.
- Stream audio stays locked to picture for the length of a session, rather than drifting apart
  over several minutes.
- A lost packet no longer freezes the picture for around 22 frames. Incomplete frames are now
  skipped and the previous frame held, instead of being sent to the decoder and triggering a
  keyframe wait. Measured over 13 minutes on a real connection: 82 packets lost, 62 recovered,
  no decode errors.
- New audio meters, a fifth scope alongside waveform, RGB parade, vectorscope and CIE. Channels
  are labelled with their roles from the file — L, R, C, LFE, Ls, Rs — where the file declares
  them.
- Multi-track files: any audio track can now be selected. Previously only track 1 played.
  Switching tracks no longer disturbs video playback.
- Window titles now show the file or stream name. N shows the full name in the HUD.
- Fixed a bug in the Window menu that was preventing correct display.
- Removed a duplicate About entry in the Window menu

## 0.6.2

- Fixed: licence keys were not surviving app updates. The key itself was always safely stored —
  the app was checking a separate settings file first and giving up before it ever read the key.
  It now reads the key first, so your licence carries across this and every future update. You
  should not need to enter it again; if you were asked to re-enter it after the last update, this
  build restores it on its own the first time you open it.
- Play/pause, the scrubber, J/K/L, the arrow-key jog and timecode entry are now greyed out while a
  live stream is showing, with a tooltip saying why. They never did anything on a stream — a live
  source has no playback position to move to. Volume, mute, scopes, guides, framing, raster size,
  frame export and the inspector all stay available as before.
- Saved stream passphrases are handled more carefully: if one cannot be read, Manifold now says so
  and leaves it alone instead of connecting without it and reporting a confusing connection error.
- Diagnostics exports now lead with a network path section, so a report from a fast local
  connection and one from a loaded or distant link can actually be compared.

## 0.6.1

- Streams recover better on a lossy connection: lost packets are now re-requested rather than
  waiting for the next keyframe.
- Resizing a window from a corner now follows the pointer instead of fighting it.
- Fixed: the NDI runtime download link pointed at the Windows installer. It now gets the macOS one.
- Still images now say they are not supported, instead of quietly doing nothing.
- Dropping a file that can't be opened no longer replaces the one you were watching.

## 0.6.0

- Windows are now independent: each one has its own file, its own scopes, and its own transport.
- Only one window plays at a time — clicking into another window pauses the first.
- Scopes and the control bar no longer shrink the picture. The window grows instead.
- Drag the divider above the scopes to make them taller.
- New raster size control: 100%, 75%, 50%, 25% or fit to screen, where 100% is one source pixel.
- Type a timecode to go to it. Arrow keys step a frame, hold Shift for a second.
- Drop a file onto a window to replace what it is showing.
- The Refresh button now lights up when the file changes on disk.
- Fixed: streams no longer assume 16:9 — vertical and 4:3 sources are framed correctly.
- Autoplay is now off by default.

## 0.5.1

- Fixed: some files played as a black screen, depending on how their audio track was recorded.
- Files that can't be opened now say so, instead of loading into an empty player.
- Scope value labels now sit clear of the trace, so they stay readable on a bright picture.
- Scope traces are brighter by default.
- Check for Updates… in the Manifold menu, and Manifold now tells you when a new build is out.

## 0.5.0

- First tester release.
- Play files, and live streams over SRT, WHEP and NDI.
- SDI output via Blackmagic DeckLink.
- Scopes: waveform, vectorscope, parade and CIE.
- Export Diagnostics… in the Manifold menu, for sending us logs when something goes wrong.
- Saved streams can be edited in place, and passphrases are kept in your keychain.

---

# Format

A release section is a level-2 heading whose text is the version, followed by bullets:

> `## 0.5.0`
> `- One short line per entry.`
> `- Another entry.`

Rules the parser enforces:

- The heading must match `MARKETING_VERSION` from project.yml exactly. A `v` prefix is accepted.
- Entries are `-` or `*` bullets, collected until the next level-2 heading.
- Anything in the section that is not a bullet — prose, sub-headings — is ignored.
- Fenced code blocks are stripped before parsing, so an example section inside one cannot be
  mistaken for a real release. This section deliberately uses blockquotes rather than a fence
  anyway, so the real notes above are the first `## 0.5.0` in the file under either rule.

**Newest version first.** The parser takes the first matching heading, so ordering is a second
line of defence against a duplicated section.

If there is no section for the version being released, the release still goes out: the uploader
warns and publishes an empty notes array. It will not fail a build that is already signed,
notarized and verified.
