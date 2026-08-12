# Manifold — Release Notes

Published with each release. `scripts/release-mac.sh` hands this file to the shared uploader,
which parses the section matching the version being released and puts the entries into the R2
manifest as a `notes` array. Keep entries short — they render in an update dialog, not on a
changelog page. Format notes are at the bottom.

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
