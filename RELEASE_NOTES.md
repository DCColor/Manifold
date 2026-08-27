# Manifold — Release Notes

Published with each release. `scripts/release-mac.sh` hands this file to the shared uploader,
which parses the section matching the version being released and puts the entries into the R2
manifest as a `notes` array. Keep entries short — they render in an update dialog, not on a
changelog page. Format notes are at the bottom.

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
- Window titles now show the file or stream name. ⌘⇧I shows the full name in the HUD.
- Fixed: a menu rebuild that destroyed window-scoped menu items.
- Fixed: a duplicate About entry in the Window menu.

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
