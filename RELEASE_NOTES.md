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
4. **macOS, Reference or Bypass, per window:** see the picture as macOS shows it, with the BT.1886
   curve a reference monitor uses, or with no color management, and read exactly what is happening
   between the source and your screen.
5. **SRT is much sturdier:** faster to start, no more break-ups or missing sound with common encoders.

### New

- Display transform, per window: OS (macOS color-manages the picture for your display) or Bypass (the picture's values go to the screen untouched). Choose it from the control bar or the Color menu. A window in Bypass says so in its title.
- Reference display transform, per window: the picture shown with the BT.1886 curve a reference monitor uses (gamma 2.4 on a display with a true black). Choose it from the control bar or the Color menu. In the transform chain readout you can tell Manifold, per display, that the display is calibrated to Rec. 709 / BT.1886 (then Reference sends the picture's values untouched), or enter the display's white and black so Reference follows BT.1886 for it. These settings apply in Reference only, and are greyed in the other modes ("Applies in Reference mode only."). Scopes, SDI output and exported frames are unaffected by the display transform.
- Keyboard Shortcuts… (in the Manifold menu below Settings, and in Help) lists every shortcut, with the keys your keyboard layout prints. Search by name, or press a key to see what it does. Click a shortcut to change it: Manifold warns before taking a key from another action, refuses keys macOS uses, and can reset one shortcut, a group, or all of them. A dot marks a shortcut you changed, and a line at the bottom says so.
- New transport keys: hold K and press J or L to step one frame; keep holding to play at half speed. Home and End (or Option-Left and Option-Right) go to the first and last frame. ⌘L turns looping on and off.
- ⌘F enters and leaves full screen, as do Control-⌘-F and fn-F.
- Volume keys: ⌘↑ and ⌘↓ turn the volume up and down by a tenth, and ⌥⌘↓ mutes and unmutes. They are in View ▸ Audio too.
- New keys: ⇧⌘D starts and stops the DeckLink output (File ▸ Start/Stop DeckLink Output), ⌥⌘⌫ disconnects the live source, and ⌥⌘4 shows and hides the transform chain (Color ▸ Show/Hide Transform Chain).
- Hold to compare: hold C to see the other of macOS and Reference while the key is down, or Shift-C to see Bypass. Let go and the window is back where it was. The window title and an amber badge say what you are comparing against. With a LUT on, hold Option-C to see the picture without it.
- A display chain readout shows the source's color and whether it was declared or assumed, the transform in use, your display and its curve, and for SRT and WHEP the amount of buffering.
- The display chain readout shows your display's HDR headroom: "display is in SDR mode" when macOS HDR is off for that display, or how much headroom it offers (for example "headroom 8.97 of 8.97"). It follows the window to another display and updates on its own when HDR is switched or the brightness changes. It only reports: Manifold does not cap or tone-map the picture.
- The display chain readout warns when an H.264 or HEVC file's container color tags disagree with what its own bitstream declares. The container's tags are still used; the color override can assert the other.
- HEVC now plays over SRT, including 10-bit HDR.
- Audio offset for live streams, in the A/V menu: ⌥] and ⌥[ move the sound 1 ms later or earlier (add ⇧ for 10 ms). Save the offset with a saved stream and it comes back every time. A badge and the window title show when an offset is on.
- Calibration (A/V ▸ Calibrate…): loop a Manifold sync clip on the sender and Manifold measures how far apart sound and picture are, then offers the correction. It never applies anything by itself. A/V ▸ Save Sync Clip… saves the clip that matches the stream's frame rate.
- SRT, WHEP and HLS streams can now have their color interpretation overridden, like NDI: pick Rec. 709, Rec. 2020 PQ, Rec. 2020 HLG, P3-D65 PQ or Rec. 2020 SDR from the Color control, or choose Color ▸ Next Tag Override. Auto goes back to what the stream declares. Save it with a saved stream from the Color menu and it comes back every time you connect; Revert to Saved returns to it.
- While a color override is on, on any stream, the window title says so (for example "— Color 2020 PQ").
- Files have the Color control too: override how a file's color is read (Rec. 709, Rec. 2020 PQ, Rec. 2020 HLG, P3-D65 PQ, Rec. 2020 SDR, or Override), or choose Color ▸ Next Tag Override. The override is for that window and goes back to Auto when you open another file. The picture, the scopes, the SDI output's color tag and the chain readout all change together, and the window title says so.
- Override the color tags, on files and on every stream type: choose the primaries, transfer and matrix separately from the Color control's Override section. Combinations Manifold can't display as stated (PQ or HLG on primaries other than Rec. 2020 or P3 D65) are greyed out with the reason. An override shows as, for example, "Color Override 9·1·6" in the title, and can be saved with a saved stream like the other overrides.
- "Reset to File's Tags" (or "Reset to Stream's Tags") at the top of the Color control undoes an override at once, without reopening. It is greyed out when nothing is overridden.
- LUTs: Load LUT… in the Color control applies a .cube LUT (1D, 3D, or shaper + 3D) to the window's picture, and the scopes, SDI output and exported frames see it too. It stays on when you open another source. Interpolation is tetrahedral by default, or trilinear. LUT Outputs says what the LUT outputs: Same as Source (no change), the default, a preset, or Custom. Change it only for a LUT that converts to another color space, such as Rec. 709 to PQ; display and calibration LUTs aren't supported there. The picture's color tags, HDR display, scopes, SDI color tag and exported frames follow it, while the readout's Source line still describes the source. Recent LUTs remembers each LUT with its output space. Bypass LUT turns a LUT off without unloading it. While a LUT is on, the Color control reads "+ LUT" in amber, the window title names it, and the readout shows its shape, interpolation and, when it isn't Same as Source, its output space, in amber. While it is bypassed, the Color control reads "+ LUT bypassed", crossed out, and the readout's LUT line starts with BYPASSED and names the LUT. A file that isn't a valid .cube is refused with a message saying why, and the LUT already applied stays applied. Checked against DaVinci Resolve on a vendor LUT and Resolve-generated 33- and 65-point LUTs: within 1.2 code values at 10-bit on every pixel.
- SDI and HDMI output now say when the picture is HDR. Each frame carries its color space and transfer (SDR, PQ or HLG), so a reference monitor that follows the signal can switch on its own. PQ also sends HDR10 static metadata over HDMI: the source's mastering display and light levels, or standard defaults (P3-D65, 1000 / 0.005 nits) when the source has none, and the DeckLink menu says which. MaxCLL and MaxFALL are sent as 0, meaning "unknown", when the source doesn't state them. HLG sends the transfer only.
- Line playhead: the timeline's playhead is now a bold yellow line with a grab tab, centred exactly on the current frame, so you can see and click precisely where you are. It follows the pointer as you drag. Prefer the round handle? Choose Settings ▸ Interface Options ▸ Playhead ▸ Ball. The line's color can be changed there too.
- Settings ▸ DeckLink Output ▸ SDI scaling: Fit to mode (the default) scales a picture that isn't an output mode's size up or down to fill the mode, keeping its shape, with black around it. 1:1 pixels sends it at its own size instead, scaling only a picture larger than every mode.
- Settings ▸ DeckLink Output ▸ SDI output modes: HD/UHD only (the default), or Include DCI to let the output follow a source into 2K DCI (2048×1080) and 4K DCI (4096×2160). With Include DCI, the DeckLink menu's output mode list offers them too.
- SDI and HDMI output follow sources at 47.95, 48, 95.90, 96, 100, 119.88 and 120 fps, in 1080p, 2160p and DCI. Before, those rates went out at the nearest of the standard eight (a 48 fps file at 50). The DeckLink menu's output mode list offers every rate, and 720p50, 59.94 and 60.
- The Inspector has a Scan row: whether a file is progressive or interlaced, which field comes first, and where that came from (the file's own picture data, or its container). If the container says something different from the picture data, the row says so.
- Interlaced files go out over SDI and HDMI as interlaced: a 1080i file at 25, 29.97 or 30 frames a second goes out as 1080i50, 1080i59.94 or 1080i60, with both fields exactly as they are in the file, in order. Follow source picks it, and the DeckLink menu's output mode list offers the three 1080i modes. Frame Rate in the Inspector gives the field rate too, for example "29.970 fps (59.94 fields/s)". A 1440×1080 or 1280×1080 interlaced file is stretched to the full width only, never vertically, so its fields stay apart. A bottom-field-first file is sent as it is, and the DeckLink menu warns that its fields will play out of order on the top-field-first 1080i signal. That judder is in the file. A file whose frame rate is given as its field rate (50, 59.94 or 60) is read at half that rate, and the Inspector says so; stepping through it moves one frame at that rate. The window shows and exports interlaced files as before.

### Improved

- Shortcuts are in the menus now, where you can see them, and some keys changed. Inspector: ⌘I (was I). Always Show Controls: ⌥⌘T (was Tab). Show/Hide Scopes: ⌥⌘S (was Control-Option-T). Export Frame: ⌥⌘E (was Control-Option-E). The display transforms are ⌥⌘1, ⌥⌘2 and ⌥⌘3. Every menu item shows its key, including N for Show/Hide File Name.
- Changed since the previous test build: hold to compare is C (was D), Shift-C for Bypass (was Shift-D); Show/Hide Scopes is ⌥⌘S (was ⌘7). D and ⌘7 do nothing now.
- These keys are gone: ⌃⌥C (now Color ▸ Next Tag Override, no key unless you set one in Keyboard Shortcuts…), ⌃⌥N and ⌃⌥⇧N (File ▸ Disconnect Live Source, now ⌥⌘⌫), ⌃⌥O and ⌃⌥⇧O (File ▸ Start/Stop DeckLink Output, now ⇧⌘D), and the scope keys ⌃⌥X, ⌃⌥G, ⌃⌥B and ⌃⌥1, 2 and 3 (each scope's settings menu, no key unless you set one). ⌃⌥R is gone. File ▸ Connect to First NDI Source is gone: pick an NDI source from the streaming menu.
- Export Frame writes the image only. It used to leave three measurement files beside it (.v210, .rgba16f, .v210.json); the image is unchanged.
- Help ▸ Export Frame for Support… saves the current frame with those three files, for when support asks: the .v210 is exactly what goes out over SDI, the .rgba16f the renderer's output, the .json the color state. It asks where to save them, and the files include the frame's picture.
- Color menu wording: "Next Color Interpretation" is now "Next Tag Override", "Reset Color Interpretation to Auto" is now "Reset Tags to Source", and the Color control's "Custom" section is now "Override". Saved streams and saved shortcuts load as before.
- The volume control no longer shakes when you hover or drag it, and the pin turns yellow when the controls are pinned.
- One yellow for "on": the playhead's yellow now also marks the pin when pinned, Loop when on (it was green), an override or an applied LUT on the Color control and in the transform chain readout, and the badge while you hold to compare. Captions on, the scopes tray open, the reload button when the file has changed, the monitored audio track and the selected framing guide use it too. Green now means live only: DeckLink output running, or a connected stream. Nothing in Manifold follows your Mac's accent color any more, except controls macOS draws itself, such as switches and menu highlights. Changing the playhead color in Settings changes the playhead only. In light appearance the transform chain readout's yellow words use a darker yellow so they stay readable.
- When you stop the DeckLink output, close the window that owns it, or quit, Manifold now sends a final black frame marked as standard dynamic range (Rec. 709) before letting go of the card, so the card and the display after it are left on black in SDR rather than on the last picture, or in HDR. Changing files or output modes is unchanged.

- SRT and WHEP now show the color the stream declares. A stream tagged HDR (PQ or HLG) is shown and scoped as HDR instead of as standard Rec. 709. A stream that declares nothing is still treated as Rec. 709.
- SRT streams start showing picture much sooner, especially at low bitrates. A static slate or bars feed used to take a minute or more to appear. It now takes a second or two.
- WHEP from Cloudflare Stream keeps sound and picture in sync for long sessions: verified over four and a half hours, including with picture and sound sent out over SDI.
- SRT buffering adapts to the sender. Encoders that send audio in large chunks, or use B-frames, get a slightly larger buffer automatically, and the chain readout says how much and why.
- SDI output follows an SRT stream's own frame rate. If a stream labels its frame rate wrongly, the output follows the rate the stream actually runs at.
- 4:2:2 and 4:4:4 files (ProRes, DNxHD/DNxHR, H.264/HEVC 4:2:2) now keep their full color resolution through playback, scopes, SDI and export.
- SRT now accepts HEVC and H.264 4:2:2 and 4:4:4 at full color resolution. A stream this Mac can't decode is refused with a message saying so, never quietly converted.
- ProRes MXF decodes through Apple's hardware-accelerated decoder: faster and identical to the same ProRes in .mov.
- Your license email and machine ID are kept only in the macOS Keychain, no longer in Manifold's preferences file. They move there by themselves the first time this version opens.
- Saved streams are now kept in the macOS Keychain in full: the address, with any stream key or token in it, and the passphrase. Manifold's preferences file keeps only each stream's name and server. Your saved streams move there by themselves the first time this version opens.
- When you edit a saved stream, its address stays hidden unless you click Show saved URL. Leave the field blank to keep the saved address.
- Manifold no longer saves its license, update-check and stream-connection requests in a disk cache, and removes the cache earlier versions left behind.
- NDI only starts looking for sources on your network when you open the NDI source list or connect to a source, not when Manifold opens.
- The display chain readout marks a color override, and a LUT that is on, in the same amber as the Color control.
- Diagnostics reports now leave out IP addresses, folder paths, computer and NDI sender names and display serial numbers. File names are left out unless you tick "Include file names".
- Manifold's log no longer records the network addresses of WebRTC connections or NDI sources, or SRT stream IDs.

### Fixed

- Fixed: while a file played out over SDI or HDMI, the output now and then showed one frame twice and then skipped the next, in short bursts. Each output frame is now the file's frame due at that moment, so playback out of the DeckLink card is smooth. Live streams are unchanged for now.

- Fixed: File ▸ Close and Window ▸ Minimize were greyed out whenever the controls had faded, so ⌘W and ⌘M closed or minimized a window only while the pointer was over it, and VoiceOver couldn't press the close button. They now work whenever a window is in front. A click where the hidden buttons sit still does nothing until the controls appear.
- Fixed: SDI and HDMI output were black for any source whose size isn't an output mode, such as 720p at 23.976, vertical and square video, scope and DCI sizes. The picture now fills the output mode at its frame rate whose size is closest to it, keeping its shape, with black around it. Set SDI scaling to 1:1 pixels to send it at its own size instead. The DeckLink menu says when the picture is placed or scaled, for example "SDI 1920×1080p23.98 · source 1280×720 scaled ×1.5 to 1920×1080". 720p50, 59.94 and 60 sources go out as 720p.
- Fixed: a live stream that changed size mid-session, such as an HLS stream stepping between renditions, could restart the SDI output at a new mode. The output mode is now chosen once when the stream starts (for HLS, from its largest rendition) and kept; later changes are fitted into it.
- Fixed: SRT sound played about 200 ms behind the picture.
- Fixed: stepping frame by frame (← / →) through 23.976, 29.97 and 59.94 fps files showed the previous frame: the first → didn't move the picture and the last frame couldn't be reached. Each step now lands on its frame.
- Fixed: a frame step (← / →) could occasionally come to rest one to three frames past the frame stepped to, most often with 50 and 60 fps material.
- Fixed: tapping → or ← quickly could skip a step, so five taps sometimes moved only two to four frames. Every press now moves exactly one frame, however fast you tap.
- Fixed: on MXF and DNx files, a typed timecode showed the frame after the one typed, the last frame couldn't be reached by typing, and releasing the scrubber could land one frame late. They now land on the exact frame.
- Fixed: some camera files rewrapped by older tools (for example ARRI ProRes clips) couldn't be opened because their container has a sample-description size error, which QuickTime Player and Quick Look can't open either. Manifold now reads around the error, says so, and leaves the file unchanged. Files with other container errors are refused with a message saying what is wrong.
- Fixed: during and after a live stream, the window's name in the Window menu and Mission Control still showed the file that was open before it. It now shows the stream's saved name (or its server's address if it has none) while streaming, and "Manifold" once the stream ends.
- Fixed: NDI sound played about a quarter of a second behind the picture.
- Fixed: WHEP sound and picture were out by a different amount every session, and drifted further apart over long sessions.
- Fixed: SRT sound from Cloudflare could sound distorted and gravelly.
- Fixed: SRT streams from some encoders (ffmpeg, and likely hardware encoders) had no sound at all.
- Fixed: SRT sound broke up on low-bitrate streams and with encoders that send audio in large chunks.
- Fixed: after reconnecting, an SRT stream could stop about 17 seconds in with "The stream stopped sending video" while it was still playing.
- Fixed: after an NDI or HLS stream ended, a file played next ran its picture about 0.2 s ahead of its sound.
- Fixed: SDI audio dropped out every few seconds during file playback.
- Fixed: P3-D65 and DCI-P3 sources went out over SDI labelled Rec. 2020 without being converted, so they looked oversaturated on a monitor following the label. They are now converted to Rec. 2020 for SDI, colors and color matrix both, so a monitor decoding Rec. 2020 shows them correctly. The window, scopes and exported frames are unchanged, and Rec. 2020 sources whose content stays within P3 pass through untouched.
- Fixed: when a live stream's color changed during SDI output, the output kept the old color label. Every color change, from a file, a stream, an override or a LUT, now reaches the very frame it changes.
- Fixed: SDI output could go back to an earlier source's color label when a file with sound was opened after output started.
- Fixed: an HDR10 file's first frames over SDI and HDMI could carry default HDR metadata instead of the file's own. The file's values are now sent from the first frame.
- Fixed: starting SDI output while the picture was paused sent black until you pressed Play. The paused frame now goes out as soon as output starts, including when the output mode changes and when output starts on launch.
- Fixed: when another application, such as DaVinci Resolve, was using the DeckLink output, starting output in Manifold failed with no explanation. Manifold now says the output is in use by another application, and output stays off until you start it again.
- Fixed: streams using the BT.470BG color matrix, common from European encoders, were decoded with Rec. 709 coefficients, giving a small color shift.
- Fixed: H.264 4:2:2 streams over SRT were shown at 4:2:0 color resolution without saying so.
- Fixed: all-intra HEVC 4:2:0 streams over SRT (x265's "Main 10 Intra") were refused.
- Fixed: DNxHR 444 files in a .mov could look slightly flat, with lifted blacks and weaker color. They now show at their true levels.
- Fixed: 8-bit sources read slightly high on scopes (mid-grey 514, white 943); they now map exactly.
- Fixed: HLS streams in P3 were shown with Rec. 709 colors while the scopes said P3.
- Fixed: sources using the Rec. 601 color matrix (SD material, some HLS renditions, streams that declare 601) were shown about 14 % too saturated, and so were their scopes, SDI output and exported frames.
- Fixed: MXF and DNx files whose container declares a color matrix different from the one inside the video stream were decoded with the stream's while the scopes, SDI output and readout used the container's. The container's color is now used for all of them, as for other files, and the readout says when the two disagree.
- Fixed: files tagged with the Rec. 601 or BT.470BG matrix were measured by the scopes and sent over SDI as Rec. 709, and the readout said the matrix was assumed. Picture, scopes, SDI and readout now all use the file's matrix.
- Fixed: Rec. 2020 SDR, DCI-P3, SMPTE-C and EBU sources were shown with Rec. 709 primaries, so they looked less saturated than they are. Each is now shown with its own primaries, and the CIE scope plots it the same way. DCI-P3 is shown with its white adapted to D65, and the readout says so.
- Fixed: the scopes could keep an earlier source's color settings (scale, gamut target and labels) after switching to a WHEP or HLS stream, after a stream ended, or when the scopes tray was opened or closed during a live stream. The scopes now always describe what is playing.
- Fixed: some files with PCM audio played silently because their audio track's channel layout was malformed, and a 6-channel file whose layout claimed a different number of channels could make Manifold quit. Both now play with their audio.
- Fixed: when a file's audio track can't be read, the meters said "No audio track" and the warning disappeared after a few seconds. The meters now say "Audio not read", and the inspector says why for as long as the file is open.
- Fixed: closing a window while its file was still opening could leave the sound playing with no window.
- Fixed: closed windows kept their memory and playback resources until Manifold quit. They are now released when the window closes.
- Fixed: a paused window with the scopes open kept using about a quarter of the processor, so with several windows open Manifold became slow to respond, and with seven or more VoiceOver and other accessibility tools could stop getting answers. A paused window now uses almost none.

### Known limitations

- Known limitation: a file's picture and sound reach SDI and HDMI about 11 ms later than before (the price of the smooth playback fix above). Picture and sound stay together on the card; if you line SDI up against another source, check the sync offset again.

- Known limitation: over HDMI, an HLG picture goes out without its HLG signal, so the display isn't told to switch to HLG. Seen with a display that doesn't list HLG among its HDR formats; a TV that does list it is still to be checked. SDI carries HLG.
- Known limitation: interlaced streams (SRT, WHEP, HLS, NDI) still go out over SDI as progressive, with both fields woven into each frame (a 1080i59.94 stream is sent as 1080p29.97). An interlaced NDI source arrives already deinterlaced by NDI. Interlaced files go out as 1080i.
- Known limitation: interlaced files that aren't 1080 lines (SD, or a file that stores each field as its own picture), and 1080 interlaced at 23.98 or 24, have no interlaced output mode. They go out progressive at their own size, not scaled, and the DeckLink menu says so.
- Known limitation: SDI audio goes silent for up to about a tenth of a second at each seek, scrub release and loop point during file playback.
- Known limitation: after a network stall of a second or more, live sound can stay 10–20 ms late for up to a minute before it settles.
- Known limitation: files at 95.90 fps and above don't yet play at full speed, so SDI repeats frames at those rates (at 119.88 and 120 the picture stalls). 47.95 and 48 fps play fully. On a DeckLink 8K Pro, 2160p above 60 fps doesn't run cleanly yet; 1080p and 2K DCI up to 120 do.
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
| HEVC and H.264 4:2:2 / 4:4:4 at native chroma (Stage 3b S3/S4): gate on the SPS's chroma and bit depth (RExt 4:2:0 "Main 10 Intra" accepted; H.264 gated), decode to `x422`/`x444`, refusal when VideoToolbox can't decode, fallback banner, software-decode note | `0b06de1` | Yes |
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
| P3-D65 read as CICP 12 (was 11, drawn as 709); the BT.2020 transfer constant as 14 (was 1; CoreMedia never sends it for H.264/HEVC, so no visible change) | `5ed306f` | Yes (P3 streams) |
| Color override on HLS, saved per bookmark; held across rendition changes; an HLS→HLS swap starts on the new stream's saved value | `5ed306f` | Yes |

#### DeckLink / SDI

| Change | Commits | Visible? |
|---|---|---|
| File playback feeds the SDI audio tap 250 ms ahead with a 4 s ring: no dropouts every few seconds | `109cfc3` | Yes. **Unsure on status**: the attended SDI check on the Resolve workstation is still pending (BUGS.md L1652) |
| Follow source uses SRT's declared, then measured, frame rate | `ce3d828` `a8b70fa` | Yes |
| HDR signalling (colour S7): per-frame colorspace + EOTF, PQ static metadata (HDMI), HDR10 from file MDCV/CLLI and SRT SEI, defaults stated; P3 → 2020 on SDI only; stream and audio re-establish tag defects fixed | `aec418e` |
| S7 follow-ups: P3 converted for SDI is also encoded with the BT.2020 matrix; an HDR10 file's metadata is read at load, so SDI frame #0 carries it | `982a73e` | Yes. **Unsure on status**: S7-5, the reference monitor over SDI and HDMI, is still to do |
| SDI scaling: Follow source picks the smallest mode at the source's rate that holds it unscaled (720p, and 2K / 4K DCI with Include DCI), places it 1:1 on the v210 group with video black around it, and scales only a picture larger than every mode (Lanczos-3, 4:2:2-sited chroma); the placement is stated in the menu, tooltip, diagnostics and log | `cb39182` | Yes. **Unsure on status**: measured on the bridge's read-back only; SDI on the wire and a reference monitor still to do |
| SDI scaling follow-ups: SDI scaling setting, Fit to mode (default; closest tier, scaled up or down) or 1:1 pixels (`cb39182` unchanged); every rate the card offers up to 120; 720p and DCI rows in the manual picker; a live session's mode chosen once and held (HLS from the largest rendition); the scaler freed at output stop | `56987a4` | Yes. **Unsure on status**: bridge read-back only, as above; the in-app HLS ladder held one mode through 12 rendition switches (a local throttled ladder, not a real CDN); at 95.90 fps and above file playback doesn't keep up (pre-existing), and 2160p above 60 runs late on the 8K Pro (cause unknown) |
| Interlaced I2: interlaced 1080-line files go out as 1080i50 / 59.94 / 60 (Follow source and the picker), fields untouched; BFF sent untouched with a warning (decision 2); an interlaced 50 / 59.94 / 60 rate halved (decision 3); no vertical scaling of interlaced pictures (1440×1080 resampled horizontally only); the established mode named from its field dominance. Loop: every interlaced fixture locks 1080i on SDI and HDMI, received fields byte-identical to the read-back and in temporal order (0 swapped over 374–456 fields per run); pictures byte-identical to HEAD (`INTERLACED_FINDINGS.md` §11) | `ca4d868` | Yes |
| DeckLink pull by time (BUGS.md 2026-10-26): a file's frames go to the card by their due time from a ring of 4, not the latest; 0 repeated/skipped frames over 45 Play starts (baseline 226 / 233), late = 0 dropped = 0, pictures byte-identical through the loop; SDI latency for files +11 ms (10.4–11.9 measured), A/V offset defaults unchanged; live sources unchanged | `<commit — to be filled in>` | Yes |
| Black on stop (Robbie, 2026-10-25): an output that ends (stop, the owning window closing, quit; a device switch for the old device) shows one frame of video black tagged Rec.709 · EOTF 0 · HDR flag clear and holds it two frames before disabling; quit now stops the output at all (a `willTerminate` observer). Mode changes and re-establishes unchanged. SDI loop: all six stop paths end on byte-exact black tagged SDR; adds 91–134 ms to a stop; pictures while running byte-identical to HEAD | `6a39299` | Yes |
| Output started while paused sends the current frame: one render primed before the preroll (paused only; playing starts unchanged), with a first-scheduled-frame log. A refused output mode is logged with the API's answer and retried once | not committed | Yes |

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
| 601 decode: the shader's 601 coefficients no longer expand chroma twice (×1.138); files carry the 601 and BT.470BG matrix codes; one reading of a matrix tag; `[MATRIX]` agreement log (colour S3 follow-up) | `500e58d` |
| MXF / DNx files take colour from the container, as AVFoundation files do; a container / decoder disagreement is logged and shown in the readout (`ContainerColorPolicy`) | `638b05c` | Yes | Yes |
| HDR headroom row in the display chain readout, from the window's own screen; `[EDR] headroom` logged once per display change (window moved, HDR switched, brightness), no reload (colour S4) | `6d85ef2` | Yes |
| The Color control for files: presets, Custom, Reset, ⌃⌥C; per window, back to Auto on a new file; one colour setter, so picture, scopes, SDI tag and readout move together (colour S5) | `6be1938` | Yes |
| Custom interpretation (primaries · transfer · matrix from the S3 table) on files and every transport; saved per bookmark as `custom:p-t-m`, read as Auto by older builds; Reset to File's / Stream's Tags (colour S5) | `6be1938` | Yes |
| One primaries / transfer / matrix table for the layer colorspace and the CIE scope: Rec.2020 SDR, DCI-P3, SMPTE-C and EBU get their own primaries; Rec.2020 SDR override on SRT, WHEP and HLS; container/bitstream colour disagreement in the readout (colour S3) | `94961b9` | Yes |
| LUT bypass reads "+ LUT bypassed" (struck through, dimmed) on the Color control, "LUT bypassed — name" in the menu and "BYPASSED — name … — not applied" in the readout; the readout draws an override's words and an applied LUT's line in the Color control's amber (darker in light appearance); `[EDR] headroom` names its window (LG session polish, §6.11) | `2343c1a` | Yes |
| Wording (Robbie, 2026-10-24): LUT Output Space → LUT Outputs, "Same as Source (no change)" first, two disabled rows on when to change it; the LUT readout names an output space only when one is stated; the chain readout's per-display calibration section enabled only in Reference ("Applies in Reference mode only."). Stored values and IDs unchanged | `72bb925` | Yes |
| L4: Manifold's LUT output matches DaVinci Resolve (vendor 33³, Resolve-generated 33³ and 65³, tetrahedral): max 1.20 code at 10-bit, P9 met; SDI and LG sanity looks done (§6.11) | — (test only) | No |

#### App, menus and diagnostics

| Change | Commits | Visible? |
|---|---|---|
| Debug menu hidden unless opted in | `4114995` | **Unsure**: 0.8.4 was build 18 and this landed 20 minutes later, bumping to build 19. If build 19 shipped as 0.8.4, users already have it; if not, 0.8.4 users lose a visible Debug menu |
| Diagnostics export reports EDR headroom from potential, not current | `cf18894` | **Unsure**: only visible in Export Diagnostics output |
| User-facing strings converted to American English ("Licenses" and others; BUGS.md, pre-ship checklist) | — | **Unsure**: verified 2026-09-21, but no commit or fix date is recorded |
| Privacy stage P1 (`docs/PRIVACY_AUDIT.md`): license email and machine id out of the preferences plist; no disk cache for the app's own requests; NDI discovery only on opening the source list; log and diagnostics redaction, with an "Include file names" option | uncommitted (2026-10-19) | **Yes** |
| Help ▸ Export Frame for Support… (Robbie, 2026-10-24): the frame's diagnostic set (`.png`, `.v210`, `.rgba16f`, `.v210.json`, byte-identical to File ▸ Export Frame (Diagnostic Set)) through a save panel, with a dated name and a note that it holds the picture; public, no longer `#if DEBUG` or behind `ShortcutDebugGate`; never in Export Diagnostics. DEBUG `MANIFOLD_FRAME_EXPORT_DIR` skips the panel for unattended runs (pre-ship removal) | `72bb925` | Yes |
| Privacy stage P2 (`docs/PRIVACY_AUDIT.md`): each saved stream's full URL and passphrase in one Keychain item (`tools.graviton.manifold.streams`, per bookmark id); the plist keeps name, host and a reference; migrated at launch with read-back, resumable; edit form shows the URL only on "Show saved URL"; a "Saved streams" count line in diagnostics | `3c5526d` | **Yes** |
| Idle windows (BUGS.md 2026-10-24): the audio meter publishes only on change, so a paused window with the scopes open no longer re-runs its whole view 30 times a second (26–30 % → 0.7 % of a core); a paused window stops its display link after 0.5 s with nothing to draw and any render input, or Play, wakes it. 12 paused windows 103 % → 3.5 %; Accessibility at 12 windows 0.2 s; pictures byte-identical, playback unchanged | `b418161` | Yes |
| Idle windows follow-up (BUGS.md 2026-10-25): a display-link restart that CoreVideo refuses (`kCVReturnError`) is now checked and the link recreated, so a paused window and its DeckLink output can no longer stay on their last or a neutral frame after idling. Fixes a regression from `b418161`, never released. 0 stuck in 107 mode changes; 12 paused windows 2.9 % | `0501067` | No |
| File ▸ Close and Window ▸ Minimize (BUGS.md 2026-10-24): enabled whenever a window is in front, not only while the controls show; the traffic lights' container fades instead of the buttons, so AppKit no longer treats them as disabled; ⌘W, ⌘M and an Accessibility press on the close button work in every state; a click on a hidden button is still ignored. 80/80 support exports byte-identical | `036b048` | Yes |

#### Keyboard shortcuts

| Change | Commits | Visible? |
|---|---|---|
| Shortcut registry: one source of truth for every shortcut, one key monitor, the scheme decided 2026-10-23 (moved and removed keys, D / ⇧D hold to compare, K+J/L, Home/End, ⌘L, ⌘F), and Help ▸ Keyboard Shortcuts… for rebinding (`SHORTCUTS_AUDIT.md`) | `9bedbe6` | Yes |
| Shortcut follow-ups from Robbie's checklist (2026-10-24): compare on C / ⇧C / ⌥C (LUT off), DeckLink ⇧⌘D, Disconnect ⌥⌘⌫, Scopes ⌥⌘S, chain ⌥⌘4, volume ⌘↑ / ⌘↓ and mute ⌥⌘↓ in View ▸ Audio, ⌃⌘F back, every menu item shows its key, ⌃⌥R removed, Connect to First NDI Source to a debug hook, Export Frame image-only with a debug Diagnostic Set, Override / Tag wording, Keyboard Shortcuts… in the app menu, the window's legend, pin colour, a steady volume control (`SHORTCUTS_AUDIT.md` §8–§10) | `0a938f7` | Yes |
| One app yellow (Robbie, 2026-10-25): #FFE600, the playhead's, defined once (`AppYellow`) for the pin, the playhead default, override and applied-LUT face and readout, the hold-to-compare badge, Loop on (was green), and the other on-states and every former accent-colour use; green kept for live (DeckLink output, connected stream). Halved-rate interlaced files step one frame of the halved rate (I2 decision); every other file steps as before. Pictures unchanged (metallib byte-identical, no render path touched); stepping identical to HEAD on 36 files (`BUGS.md` release scope) | `<commit — to be filled in>` | Yes |

#### Internal (build, telemetry, probes, test tooling)

| Change | Commits |
|---|---|
| Release configuration compiles again (`toneLock` declaration) | `d76bb21` |
| Release-archive telemetry assertion corrected | `f9880b3` |
| LiveClock telemetry no longer written to stderr in Release | `176ca03` |
| Audio-mirror rate pin removed | `8379c10` |
| DEBUG probes: destination color profile, paired timebase, A/V lag, A/V content, raw SR logging, WindowSizer deinit | `2db97b1` `61b9b69` `a90de72` `d3b0831` `c31ca83` `2c1da93` |
| Saved streams written with sorted JSON keys, so an unchanged list saves back byte for byte (each list is re-ordered once at its first save; content unchanged) | `f926f47` |
| Soak, replay and DeckLink test tooling; MediaMTX `useAbsoluteTimestamp` mode | `8389dd9` `5041fb8` `54750ad` `9b10b68` `73ef624` `b35a810` |
| Build hygiene: concurrency annotations, vendored-header warnings, ignore build folders | `f0969e4` `aa79682` `d055d07` |
| Interlaced I1: a file's scan and field order detected from its container and bitstream, shown in the Inspector and logged as `[SCAN]` (`INTERLACED_FINDINGS.md` §10) | `c9f0c97` |
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
