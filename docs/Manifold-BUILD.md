# Manifold — Build

Stack: Swift / SwiftUI, native macOS. arm64 only, macOS 15.0+
Product slug: `manifold`

---

## Process documentation lives elsewhere

Build, signing, release, and distribution **procedure is not documented here.** It lives in
the Graviton-Releases repo (github.com/DCColor/Graviton-Releases, private), checked out in
some directory ABOVE this repo — `release-mac.sh` locates it by walking up the tree, so no
fixed depth is assumed. On the current build Mac it sits at
`~/Code/Graviton-Releases`, with this repo at
`~/Code/Manifold/Manifold`:

| Document | Covers |
|---|---|
| `docs/stacks/swift.md` | xcodegen/xcodebuild, direct `codesign`, notarytool, this app's pipeline shape |
| `docs/DISTRIBUTION.md` | R2 layout, `manifest.json` schema, Worker routing, public URLs, `upload-release.sh` |
| `docs/IDENTITY.md` | Apple accounts, certificates, renewal dates |
| `docs/MACHINE-STATE.md` | build Mac state, keychain, what is not backed up |

**Those documents are canonical.** If anything in this file contradicts them, they are
correct and this file is stale.

⚠️ **The signing identity string here includes the `Developer ID Application: ` prefix**,
because this app calls `codesign` directly. The Electron products must omit it or
electron-builder rejects the config. Same certificate, two required spellings. Do not
"fix" one to match the other.

Everything below is specific to Manifold.

---

## One entry point

```
scripts/release-mac.sh [Profile|Release] [--no-upload]
```

- `Profile` — tester build, telemetry compiled in. **This is the default.**
- `Release` — public build, per-second telemetry compiled out
- `--no-upload` — build, sign, notarize, staple, and verify, but do not publish

`MANIFOLD_DIST_DIR` overrides the output directory (default `~/Code/Manifold/Builds/Manifold/`).
`GRAVITON_RELEASES_DIR` overrides where the shared uploader is found (default: searched
for by walking up from the repo root — see **Fragilities**).

The script runs: preflight → version read → build-number bump → `xcodegen generate` →
`xcodebuild archive` → `-exportArchive` → verify app and nested dylibs → build DMG → sign
DMG → notarize → staple → validate → publish → verify the published manifest. Every stage
is a hard failure.

**No CI.** Every release is cut by hand from the build Mac. Mac-only, so there is no
Windows runner and no GitHub Actions workflow in this repo at all.

**Output goes outside the repo** — `~/Code/Manifold/Builds/Manifold/<version>-<build>-<config>-<stamp>/`
— so build artifacts stay out of the repo. The repo lives in `~/Code`, outside any sync
folder; Nextcloud's chunked upload has corrupted large artifacts on sibling products, so
build output must never land in a sync folder. This is the pattern the Electron apps should copy.

---

## Prerequisites

Asserted by preflight; none are version-pinned anywhere.

**Tools:** `xcodegen`, `xcodebuild`, `create-dmg`, `codesign`, `hdiutil`, `python3`, and —
when publishing — `wrangler` and `curl`. `notarytool` and `stapler` must be findable in the
active Xcode.

**Machine state:** the Developer ID identity in the login keychain, and a working
`graviton-notarytool` profile. Preflight tests the notarization profile *before* building
rather than discovering it is broken after a 20-minute archive.

**SDKs, copied in by hand, both gitignored:**

- DeckLink SDK 16.0 → `docs/BlackmagicDeckLinkSDK16.0/Mac/include/`. `DeckLinkAPIDispatch.cpp`
  from it is compiled directly into the app target. The runtime is the user's own installed
  `/Library/Frameworks/DeckLinkAPI.framework`.
- NDI SDK for Apple → installed system-wide at `/Library/NDI SDK for Apple/include`.
  **Never vendored** — the license does not permit it. The runtime `libndi.dylib` is
  `dlopen`'d at `/usr/local/lib/`, so nothing NDI-derived ships. If the user does not have
  it, the app still launches.

**Vendored libraries**, all gitignored, all built by scripts in this repo:

| Thing | Staged to | Built by | Source |
|---|---|---|---|
| FFmpeg — 5 shared dylibs + headers | `ThirdParty/ffmpeg/` | `scripts/build_ffmpeg.sh` | n8.1.1, commit `239f2c733de417201d7ad3b3b8b0d9b63285b2b1` |
| libdatachannel + juice + srtp2 + usrsctp + Mbed TLS | `ThirdParty/libdatachannel/` | `build_mbedtls.sh` → `build_libdatachannel.sh` | v0.24.5 / v3.6.7 |
| libsrt | `ThirdParty/libsrt/` | `scripts/build_libsrt.sh` | v1.5.6 |

Scratch trees live under `$CODE_ROOT/Manifold/` (`manifold-ffmpeg-build`, `manifold-webrtc-build`,
`manifold-srt-build`), and `CODE_ROOT` defaults to `~/Code`. **None are in git.** Whether TrueNAS
covers them is tracked in Graviton-Releases `docs/MACHINE-STATE.md`. They are reproducible from
the pins, but reproducing them takes real time.

---

## Pre-release checklist

- [ ] `MARKETING_VERSION` in `project.yml` is the version you intend to ship
- [ ] `RELEASE_NOTES.md` has a `## <version>` section, heading matching `MARKETING_VERSION`
      exactly — the uploader's parser requires it or the manifest ships `"notes": []`
- [ ] All three `ThirdParty/` trees present and built
- [ ] DeckLink SDK in `docs/`, NDI SDK installed
- [ ] Decide `Profile` or `Release` — see the warning below
- [ ] A release that legitimately grows the DMG past 150% of the previous one is published with
      `RELEASE_ALLOW_SIZE_JUMP="<reason>"` (Graviton-Releases `DISTRIBUTION.md`, *Size check, and its
      override*); 0.9.0 used it for the bundled sync clips (25.9 MB)
- [ ] Review the bundled guide's content for this release: `docs/guides/manifold-0.9-sync-and-color-guide.md`
      (Help ▸ Sync and Color Guide; every build converts it). Its date line is not filled in by the app: the
      version is (`{{VERSION}}`). The build log's "Guide shot list" names the screenshots still to take
- [ ] A long soak of the release candidate (Play cycles, overnight or at least 3 hours, counting freezes,
      recoveries and slips) (Robbie, 2026-11-09)
      - **0.9.2 build 25:** met by the 2026-11-08/09 overnight run (`docs/CARD_CLOCK_FINDINGS.md` §10.15: 13.2 h
        with the watchdog on, 0 freezes, 2 recoveries, both on the first re-arm) and Stage 1a's 6 × 40 min runs
        (§10.9: 0 skips, file clock on the card to 0.00 ppm) (Robbie, 2026-11-09). These ran on measurement
        builds (`-DMANIFOLD_CARDCLOCK`), not on the build 25 binary. 5.75 h of the 13.2 h had Stage 1b on
        (`MANIFOLD_CARDLOCK_1B=1`), which build 25 ships off. With the gate off as shipped: 7.46 h, 1 recovery.
      - **0.9.3 release gate (Robbie, 2026-11-14): 0 freezes, 0 unrecovered events, 0 holds or skips beyond the expected
        cadence, over at least 6 h.** Candidate: a plain Profile build of `537a351` (no `-DMANIFOLD_CARDCLOCK`), `.build-rc`,
        unsigned. Card lock on by default, no behaviour variable, capture closed. Only the scripted transport and two logging
        variables are set (`MANIFOLD_DEBUG_TRANSPORT`, `MANIFOLD_DECKLINK_CADENCE_LOG`, `MANIFOLD_PLAYBACK_STATS`): seeks
        are key-only and an unattended run sends no keystrokes, and holds are read from the pull lines. Six one-hour blocks of
        play cycles with seeks and loop wraps, one launch each, alternating: a 59.94 file with sound to SDI (1080p59.94); a
        23.976 file with sound to Computer (1080p23.98); an audio-only 48 kHz WAV to SDI (1080p59.94); a file without sound
        (1080p59.94); then the first two again. Tools: `scripts/decklink-loopback/rc-soak.py`, `rc-soak-report.py`; chain
        and logs in `~/Code/_scratch/manifold-rc-soak/`. Started early on Robbie's go: 2026-11-14 15:37–21:43, sha256
        `250c0b5237466292…`, every block exit 0. **Result: met, with two named exceptions (Robbie, 2026-11-14): 0 freezes, 0
        unrecovered events, 0 holds or skips beyond the expected cadence except (1) 1 hold, the known W7-5994 slip at
        Computer, recovered; sound followed picture, and (2) 1 card drop of frame #0 at an output start, the known
        start-time drop (both below).** The gate itself stays at 0 holds: any other kind of hold fails it. **Duration
        (accepted, Robbie):** 6 h 07 min wall time, 5.60 h actual playing time, with the standard pause cycle (each
        ~175 s cycle has its Pauses and seeks). 378 Plays, 378 seeks, 126 loop wraps, 941,043 card pulls while playing, 0
        missed slots.
        | Block | Freezes | Holds / skips | Renderer recoveries | Output starts; silent starts | SDI !! lines | Card late / dropped | Window late / dropped |
        |---|---|---|---|---|---|---|---|
        | 59.94 + sound, SDI (1) | 0 | 0 / 0 | 0 | 1 with sound; 0 | 12 appended edges | 0 / 0 | 17 / 7 of 201,069 |
        | 23.976 + sound, Computer (1) | 0 | 0 / 0 | 0 | 1 with sound; 0 | none | 0 / 0 | 14 / 4 of 80,443 |
        | WAV 48 kHz, SDI | 0 | 0 / 0 | 0 | 1 with sound; 0 | 9 appended edges | 0 / 0 | (no window picture) |
        | No sound, SDI | 0 | 0 / 0 | 0 | 1; 0 | none | 0 / 0 | 16 / 6 of 201,312 |
        | 59.94 + sound, SDI (2) | 0 | 0 / 0 | 0 | 1 with sound; 0 | 12 appended edges | 0 / 1 (frame 4, at output start) | 14 / 7 of 201,091 |
        | 23.976 + sound, Computer (2) | 0 | **1** / 0 | 0 | 1 with sound; 0 | none | 0 / 0 | 9 / 3 of 80,447 |
        | **Total** | **0** | **1 / 0** | **0** (0 attempts, 0 GAVE UP) | 6; **0** | 33 appended edges | 0 / 1 | 70 / 27 of 764,362 |
        - **Exception 1, the hold: 1 hold, the known W7-5994 slip at Computer, recovered; sound followed picture**
          (`rc-2398-cmp-2.log` line 112669, content 933.06 s). The card was handed pts 933.057125 twice
          (slots 52149, 52150). Until then each frame was swapped in about 9 ms before its pull. The swap of 933.098833 came
          55.9 ms after the one before, instead of 41.7 (about one 13.9 ms display tick late), 5 ms after the pull. The
          picture took a new line (#63), and card lock moved the Mac's sound with it: `re-anchored to the SDI picture at its new
          line #63 (a slip): it was +41.70 ms off` (1 in the run). Card late 0, dropped 0. This is the Computer slip of
          `CARD_CLOCK_FINDINGS.md` §10.29 W7-5994 ("Stage 2 showed once in 2.5 h"), recovered by the slip write. It is the only
          slip in the 6 blocks. Why the swap was late: UNKNOWN. (From 0.9.4 this exception is named "a late window frame
          repeated once (either destination), recovered, sound followed"; see the 0.9.4 gate below.)
        - **Exception 2, the card drop: frame #0 of an output start reported Dropped, the known start-time drop**
          (`rc-5994-sdi-2.log`, the first completion after `StartScheduledPlayback`: `completion result 2 stream 0 done 0`,
          then `DeckLink D3: !! Dropped at frame 4`, the index being refilled). A paused start: 4 preroll frames (#0–#3)
          of the same paused picture, 3,840 audio samples prerolled, buffered 5; frames #1 onward completed (result 0), late
          0 and no other drop in the block. Effect: the paused picture shows one frame later. Documented in `BUGS.md` "☐
          OPEN — PRE-EXISTING … the first scheduled frame of an output start is now and then reported Dropped" (0.4 % of
          532 starts, cause UNKNOWN, not fixed), `CARD_CLOCK_FINDINGS.md` §10.26 (`mid21`: "the known start-time drop of
          frame 4") and §6 (3 of 48 sessions, "each frame 4, scheduled before Play"), `DISPLAY_LINK_PER_WINDOW_PLAN.md` §7.9 ("0 / 1 (frame 4, before
          Play)"). The other three SDI blocks: frame #0 completed, 0 late and 0 dropped in their first 8 completions
          and in their first card count at frame 48.
        - Not counted as holds: 637 frames held around the loop's wrap (a seek).
        - SDI bridge totals: 0 late edges, 9 re-latches, 100,492 missing samples. In every block the missing count rises
          only in the Play from 1,895 s through the loop's wrap, once per cycle: positions past the end of the file's sound
          (§10.24's reading, an inference from the lengths).
      - **0.9.4 release gate (Robbie, 2026-11-15): the 0.9.3 gate (0 freezes, 0 unrecovered events, 0 holds or skips
        beyond the expected cadence, at least 6 h) plus markers.** Named exceptions: (1) **a late window frame repeated
        once (either destination), recovered, sound followed**, renamed from 0.9.3's "the W7-5994 slip at Computer" and
        widened to SDI (Robbie, 2026-11-16, after this run's hold 2); (2) the frame #0 start drop. The gate stays at 0 holds
        for any other cause. Candidate: a plain Profile build of `7b99b09` (no `-DMANIFOLD_CARDCLOCK`),
        `.build-rc094`, unsigned, sha256 `73aac1313696e52d…`. Rules and variables as for 0.9.3. Seven one-hour blocks,
        alternating: 59.94 with sound to SDI (1080p59.94); 23.976 with sound to Computer (1080p23.98); the 48 kHz WAV to
        SDI (1080p59.94); a long-GOP H.264 file to SDI (`fixtures/soak/gop25-h264-1920s.mp4`: 1080p25, keyframe every 250
        frames, 3 B-frames, AAC; 1080p25 output); then the first three again. **Markers:** each video file had 5 stored
        markers, loaded at launch, the Markers slot open and thumbnails on. Every 600 s, while playing, the run pressed
        Regenerate Thumbnails (Markers gear, by accessibility click) and read the thumbnail disk cache's file times against
        the transport's Pause and Play. Setup (2026-11-15 22:30–22:44) confirmed on this build that the 5 stored markers'
        thumbnails reach the disk cache at load on all three files: the `7b99b09` fix (`BUGS.md`, stored markers get no
        thumbnails). Tools: `scripts/decklink-loopback/rc-soak.py`, `rc-soak-report.py`, `rc-soak-ax`; chain and logs in
        `~/Code/_scratch/manifold-rc094-soak/`. 2026-11-15 23:00 – 2026-11-16 06:08, every block exit 0. **Result: met, with
        one named exception (Robbie, 2026-11-16): 0 freezes, 0 unrecovered events, 0 skips, 0 holds beyond the expected
        cadence except 2 holds, each a late window frame repeated once, recovered, sound followed** (one at Computer, one at
        SDI on the 25p file; below). The frame #0 start drop did not occur. Markers: met. As first reported, before the
        exception was widened, hold 2 failed the gate as written (it was at SDI); Robbie accepted it as the same mechanism.
        Follow-up after 0.9.4: `BUGS.md`, "the card pull's margin over the window swap is under one refresh". **Duration:** 7 h 08 min wall time, 6.54 h playing time. 441 Plays, 441 seeks, 147 loop wraps,
        1,022,905 card pulls while playing, 0 missed slots.
        | Block | Freezes | Holds / skips | Renderer recoveries | Output starts; silent starts | SDI !! lines | Card late / dropped | Window late / dropped |
        |---|---|---|---|---|---|---|---|
        | 59.94 + sound, SDI (1) | 0 | 0 / 0 | 0 | 1 with sound; 0 | 10 appended edges | 0 / 0 | 11 / 12 of 201,082 |
        | 23.976 + sound, Computer (1) | 0 | **1** / 0 | 0 | 1 with sound; 0 | none | 0 / 0 | 13 / 3 of 80,448 |
        | WAV 48 kHz, SDI (1) | 0 | 0 / 0 | 0 | 1 with sound; 0 | 14 appended edges | 0 / 0 | (no window picture) |
        | Long-GOP H.264 25p, SDI | 0 | **1** / 0 | 0 | 1 with sound; 0 | none | 0 / 0 | 25 / 22 of 83,898 |
        | 59.94 + sound, SDI (2) | 0 | 0 / 0 | 0 | 1 with sound; 0 | 17 appended edges | 0 / 0 | 10 / 11 of 201,083 |
        | 23.976 + sound, Computer (2) | 0 | 0 / 0 | 0 | 1 with sound; 0 | none | 0 / 0 | 9 / 3 of 80,446 |
        | WAV 48 kHz, SDI (2) | 0 | 0 / 0 | 0 | 1 with sound; 0 | 11 appended edges | 0 / 0 | (no window picture) |
        | **Total** | **0** | **2 / 0** | **0** (0 attempts, 0 GAVE UP) | 7; **0** | 52 appended edges | 0 / 0 | 68 / 51 of 646,957 |
        - **Hold 1, the named exception (a late window frame repeated once), at Computer: recovered; sound followed picture**
          (`rc-2398-cmp-1.log` line 181796, content 986.40 s). The card was handed pts 986.402083 twice (pulls #84157,
          #84158). Until then each frame was swapped in about 10.7 ms before its pull, at a 13.90 ms display tick. The swap
          of 986.443792 came 55.7 ms after the one before, instead of 41.7 (one tick late), 3.3 ms after the pull. New
          picture line #103; `re-anchored to the SDI picture at its new line #103 (a slip): it was +41.71 ms off` (line
          181815). Card late 0, dropped 0. Why the swap was late: UNKNOWN, as in 0.9.3.
        - **Hold 2, the named exception (a late window frame repeated once), at SDI on the 25p file: recovered; sound
          followed picture. Accepted by Robbie, 2026-11-16, as the same mechanism as hold 1**
          (`rc-gop25-sdi-1.log` line 58250, content 261.48 s). The card was handed pts 261.480000 twice (pulls #27074,
          #27075). Each frame had been swapped in about 12.9 ms before its pull, at a 13.33 ms display tick. The swap of
          261.520000 came 53.4 ms after the one before, instead of 40.0 (one tick late), 0.4 ms after the pull. The SDI
          sound ended its run (`off the line on a timed pull`) and re-latched from the held frame's last showing (latch #33).
          The Mac sound was re-anchored to new picture line #32, +40.00 ms off (line 58266). Card late 0, dropped 0. Not near
          a transport step (the next, a seek, came 14 s later) nor a Regenerate (480 s after one, 120 s before the next).
          Why the swap was late: UNKNOWN. In both holds the swap led its pull by less than one display tick, so any swap
          one tick late is a hold. Under the 0.9.3 wording (the exception named Computer only) it failed the gate; the
          exception was renamed to cover either destination.
        - **The frame #0 start drop did not occur:** card late 0 and dropped 0 in all 7 blocks.
        - **Slip writes:** 5 in all. Two are the holds above. One is at a loop wrap (`rc-2398-cmp-1`, content 0.705 s).
          Two are in the second WAV block (content 1152.2 and 1895.3 s), which has no window picture to hold.
        - Not counted as holds: 705 frames held around the loop's wrap (a seek).
        - SDI bridge totals: 0 late edges, 23 re-latches, 179,583 missing samples.
        - **Markers: met.** 5 of 5 stored markers loaded, the Markers slot open, and 5 thumbnails cached at the start of
          each of the 5 video blocks. 30 Regenerates, each pressed while playing: every one removed 5 and remade 5
          (150 in all). **0 made while playing:** every thumbnail was written in the next Pause, the first 0.028–0.060 s
          after it, and none was still being made after Play resumed. Around each press (±10 s): 0 holds, 0 skips,
          6 window late/dropped frames in all (1 at 2398-1 regen 2, 1 at 2398-1 regen 4, 3 at GOP25 regen 5, 1 at 5994-2
          regen 5). That is in line with each block's own background rate (119 late/dropped frames in 4.65 h of video blocks,
          about 4.3 expected in 30 × 20 s). From each Pause to its last thumbnail + 10 s: 0 holds, 0 skips, 0 late/dropped.
      - **0.9.5 release gate (Robbie, 2026-11-19, after `CARD_PULL_MARGIN.md` §18 and two attended checks on the LG; amended
        2026-11-20 after nights 6 and 7, §19–§20; amended 2026-11-21, the edge-start exception below): 0 holds for any cause, except a
        renderer recovery and at most one edge-start hold per night. Crossing-caused holds: 0,
        with no exception.** The 0.9.4 exception "a late window frame repeated once (either destination)" is retired: its mechanism,
        the crossing, is fixed by C+ (`BUGS.md`, the card pull's margin, FIXED 2026-11-19). The scaled-display exception ("pacer-caused
        hold from a present overrun on a scaled display, recovered") is removed (2026-11-20): plain B fixes it (`BUGS.md`, "on a scaled
        60 Hz desktop display … a window present could overrun two periods", FIXED 2026-11-20). Otherwise the 0.9.4 gate stands: 0
        freezes, 0 unrecovered events, at least 6 h, and markers.
        - **The candidate runs the 0.9.5 defaults:** `MANIFOLD_PACER_PHASE` and `MANIFOLD_PACER_PRESENT_TX` unset, so C+ is on and
          the window's pacer present is plain B. Since 2026-11-19 Release runs the same C+ code as Profile, and since 2026-11-20 the
          same plain-B present path; both switches are diagnostic off-switches in both configurations (`MANIFOLD_PACER_PHASE=0`,
          `MANIFOLD_PACER_PRESENT_TX=1`), so the gate holds for either configuration.
        - **B1, re-stated as on night 7 (Robbie, 2026-11-20; `CARD_PULL_MARGIN.md` §20):** pacer missed deadlines ≤ 2 per block, not
          counting those whose overrunning step is the post-seek first-frame render (`perform`); those are reported, not counted. A miss
          is post-seek first-frame when it overran `perform`, it is a new-frame tick, a `[TRANSPORT] seek` is at most 0.5 s before it,
          and no `[CADENCE-SWAP]` lies between that seek and it (`BUGS.md`, "the first frame after a seek can take ~22 ms to render",
          LOW, not for 0.9.5).
        - **Export Diagnostics' "card holds while playing"** now leaves out the first 1 s after Play, a seek, a step or a loop wrap,
          the end of the file, and a rate mismatch's cadence (`CardHoldFilter`). On nights 4 and 5's logs this rule gives exactly
          the gate's holds (night 5: 1, 0, 0, 0, 0, 0; night 4: 2, 1, 0, 0, 0), where the old counter read 40–165 per block. So
          on the soak, the `[DIAG] playback counters` line should equal the gate's hold count.
        - **SDI sound continuity (Robbie, 2026-11-20, after night 7; `SDI_AUDIO_NIGHT7.md`; `BUGS.md`, the two SDI sound entries
          of 2026-11-20):** `rc-soak-report.py` counts three more kinds of unrecovered event, on every block whose log has
          `[SDI-AUDIO] runs path entered` (a file's sound on the card's timeline; other blocks read "n/a"):
          1. **The card's audio callback stopped**, with no recovery within 10 s (`[SDI-AUDIO] !! no audio callback`, or more than 5
             `DeckLink D3: frame` lines in a row with no `[SDI-AUDIO] runs:` line). A stop the SDI audio watchdog's output restart
             recovered within 10 s is reported and allowed, like a renderer recovery. A watchdog give-up (`[SDI-AUDIO-RECOVER] GAVE
             UP`) is unrecovered.
          2. **Sustained missing sound while playing:** 3 judged `runs:` lines (one per second of stream) in a row each 4,800 missing
             samples or more, or one of 24,000 or more; not judged with the gate silent or within 1 s after a Play, seek, loop or
             step. Unrecovered if it ends only at a seek, a loop, a step, an output stop or the end of the log.
          3. **A Stage 2 start more than 1 s into the SDI picture's run, or a re-anchor more than 1 s off**, unless check 2 found an
             event within 10 s after it (the same incident, counted once).
          On night 7's logs the gate is **FAIL, unrecovered 2** (block 5's callback stop, the GOP block's 62 s of missing sound); on
          nights 5 and 6, and every earlier soak, the checks find nothing and the verdicts are unchanged. Since 0.9.3 no SDI block
          had more than ~5,100 missing samples in one second, more than 1 s in a row at 4,800, or a run of more than 2 `D3: frame`
          lines without a `runs:` line. Export Diagnostics' PLAYBACK COUNTERS and the `[DIAG] playback counters` line add "SDI audio
          stops" (stops, recovered by an output restart, given up): on the soak these should match check 1.
        - **Kept from 0.9.4 (Robbie, 2026-11-19): the frame #0 start-drop exception.** Frame #0 of an output start reported
          Dropped, the known start-time drop (a card drop, not a hold; `BUGS.md`, "the first scheduled frame of an output start is
          now and then reported Dropped").
        - **Added 2026-11-21 (Robbie): the edge-start exception, at most one per night.** 0.9.5 ships today's pull code; the fix,
          the sticky would-repeat band, was for 0.9.6 and is now deferred past 1.0 (Robbie, 2026-11-27; `CARD_PULL_MARGIN.md` §21.6),
          and the 1.0 gate keeps this exception unchanged (Robbie, 2026-11-27). As `rc-soak-report.py` implements it
          (`edge_start`, `gate095_block`):
          - **It passes** a hold (a pull that hands the frame handed last; not a skip) when all of these are true:
            1. the block's output mode is 59.94 (`1080p59.94` or `2160p59.94`, k = 2: the lead-guard line's P is half the card frame,
               within 0.05 ms);
            2. it is in a Play whose C+ lead guard stopped at its band edge. The Play is the one whose `[PACER-PHASE] reference set`
               line is the last before the hold; every Play, seek and wrap sets a new one. The first `[PACER-PHASE] lead guard` line
               after that reference (the establishment) says "at the guard band's edge", and its lead after the move is < P + 0.5 ms;
            3. it is the night's first such hold, in block order.
          - **It fails**, as before the exception: any other hold or skip not in a renderer recovery, and a second edge-start hold
            in the same night.
          - **Reported for every hold and skip, never judged:** its class, its Play's lead-guard lead and P (or that the Play had no
            lead-guard line, i.e. lead already ≥ P + 0.5 ms), and its position, in seconds since the last Play, seek or wrap.
          - **Measured rate (nights 5–7, `CARD_PULL_MARGIN.md` §21.2):** 1 of 379 Plays at 59.94 in the next-by-band state started
            within 0.1 ms of the would-repeat edge. 1 hold of this kind is known: the rehearsal's (above), which is classified
            edge-start (lead 8.547 ms, P 8.34 ms, 11.6 s after the wrap; its block reads PASS under the exception, and the night
            still FAILS on 4.08 h wall time).
          - **Self-test** (`~/Code/_scratch/manifold-rc095-rehearsal/tests/run-tests.sh`, outside the repo): the rehearsal hold is
            the edge-start exception; the same hold moved to a full-lead Play fails; a second edge-start hold in a night fails; and
            nights 5–7 keep every per-block 0.9.5 verdict.
        - **The renderer watchdog's detection wait is 200 ms, was 500 ms (decided Robbie, 2026-11-20; `BUGS.md`, the picture
          freeze; `PICTURE_FREEZE_AUDIT.md` §6).** It recovers once the state has lasted 150 ms with no pump callback for 200 ms. A
          state over 100 ms that clears by itself is still a near-miss, not a recovery: the 100–150 ms band is kept for it. Basis:
          54 h of soak data, the state never appeared in healthy play and no state over 100 ms cleared by itself. A renderer
          recovery stays allowed by the gate (it is not a freeze); a GAVE UP is unrecovered. `rc-soak-report.py` lists every stall and
          near-miss per block, with its time in the state, its silence and its outcome, marks a stall taken with under 0.5 s of silence
          "sooner than the old 0.5 s wait", and prints a `RENDERER WATCHDOG` line. Any stall or near-miss in a soak is unexpected
          (none in 15.7 h of release soaks): read each one before calling the gate. Export Diagnostics and the `[DIAG] playback
          counters` line now count stalls, not re-arm attempts ("1 stall (1 recovered, 0 GAVE UP), 3 re-arms, 0 rebuilds, 0
          near-misses"), and count GAVE UP; the report checks the last `[DIAG]` line against the log's counts.
        - **0.9.5 rehearsal result (2026-11-20 18:50 – 23:08): `rc-soak-report.py` 0.9.5 GATE: FAIL.** Block 1 failed on one hold,
          and the night stopped after 4 of 7 blocks, so the wall time is 4.08 h (under 6 h). Candidate: `.build-rc095-rehearsal`, a Profile
          build of `fb9b1e6`, bundle 0.9.4 (27) (not bumped), ad-hoc linker-signed, sha256 `ed2ee35d2e65e5e6…`. The report came from the
          working-tree `rc-soak-report.py` (modified 12:58, uncommitted). Chain, logs, `soak.out`, `soak.report`, `RIG.md`: 
          `~/Code/_scratch/manifold-rc095-rehearsal/`. Every block exited 0 and was followed by a clean guard. **Why it stopped:** at
          23:07:58, before block 5 (`r95-5994-sdi-2`), `soak.sh` found a zoom.us process and exited (`soak.out`: "!! a zoom.us process is
          running: stopping"). Blocks `r95-5994-sdi-2`, `r95-2398-cmp-2` and `r95-ao48-sdi-2` did not run. 3.74 h playing, 252 Plays,
          252 seeks, 84 loop wraps, 552,344 card pulls while playing, 0 missed slots.
          | Block | 0.9.5 gate | Freezes | Holds / skips | Renderer stalls / near-misses | Output starts; silent starts | SDI !! lines | Card late / dropped | B1 (pacer missed − post-seek) | Window late / dropped |
          |---|---|---|---|---|---|---|---|---|---|
          | `r95-5994-sdi-1` 59.94 + sound, SDI | **FAIL** | 0 | **1** / 0 | 0 / 0 | 1 with sound; 0 | 8 appended edges | 0 / 0 | 0 − 0 = 0 | 18 / 6 of 201,091 |
          | `r95-2398-cmp-1` 23.976 + sound, Computer | PASS | 0 | 0 / 0 | 0 / 0 | 1 with sound; 0 | none | 0 / 0 | 0 − 0 = 0 | 15 / 6 of 80,442 |
          | `r95-ao48-sdi-1` WAV 48 kHz, SDI | PASS | 0 | 0 / 0 | 0 / 0 | 1 with sound; 0 | 14 appended edges | 0 / 0 | 0 − 0 = 0 | (no window picture) |
          | `r95-gop25-sdi-1` long-GOP H.264 25p, SDI | PASS | 0 | 0 / 0 | 0 / 0 | 1 with sound; 0 | 3 appended edges | 0 / 0 | 1 − 0 = 1 (nothing subtractable) | 22 / 27 of 83,887 |
          | **Total** | **FAIL** | **0** | **1 / 0** | **0 / 0** (0 re-arms, 0 GAVE UP) | 4; **0** | 25 appended edges | 0 / 0 | max 1 | 55 / 39 of 365,420 |
          - **The hold (block 1, no renderer recovery, so it fails the gate):** `r95-5994-sdi-1.log` line 231206, `[CADENCE] #113767`
            at host 596560.844 (about 19:35:09), content 11.61 s, 13 s after a loop and Play at 1,895 s. The card was handed pts
            11.611600 twice (slots #113766, #113767). The next frame, 11.628283, was published to the card's ring
            (`[CADENCE-SWAP]`, the ring publish, not the window's swap; corrected 2026-11-21) 9.35 ms before pull #113767's
            `[CADENCE]` line, the same lead as the pulls before it. From pull #113768 on, each pull took the frame swapped one period earlier (about
            27 ms behind the clock instead of about 10 ms). The SDI sound ended its run (`off the line on a timed pull`) and
            re-latched from the held frame's last showing (latch #56). The Mac sound was re-anchored to new picture line #56, +16.67
            ms off ("a slip", 1 so far). Card late 0, dropped 0. It was not in a Regenerate window: it came 95 s after Regenerate 3's
            press and 64 s after its last thumbnail. It came 4 min after the CCC run ended. This is not the 0.9.4 "late window frame"
            pattern, because the swap was not late. Why the pull handed the earlier frame: UNKNOWN. The `[DIAG]` card-holds counter
            reads 1, which agrees with the gate.
          - **Skips 0. Card drops 0:** the frame #0 start drop did not occur, and there are no other drops. Card late 0 in all blocks.
          - **Renderer watchdog:** 0 stalls, 0 re-arms, 0 rebuilds, 0 GAVE UP, 0 near-misses, 0 "sooner than the old 0.5 s wait". The
            last `[DIAG]` line matches the log in every block.
          - **SDI sound** (on the three SDI blocks): 0 callback stops, 0 missing-sound events, 0 Stage 2 over 1 s, 0 Stage 2 refusals,
            0 re-reads. Watchdog restarts 0, sound back 0, gave up 0. Unrecovered 0. Bridge totals: 0 late edges, 5 re-latches (2 / 0 / 0 /
            3), 84,398 missing samples (18,669 / 0 / 61,889 / 3,840), and 25 edges appended by the card. Not counted as holds: 374
            frames held around the loop's wrap.
          - **B1:** pacer missed deadlines were 0, 0, 0 and 1 (`r95-gop25-sdi-1.log` line 196983, max interval 26.67 ms). No block had
            `[PRESENT-TIMING]` lines, so nothing could be subtracted. Every block is ≤ 2, so **no block is UNDETERMINED**.
          - **Markers: PASS.** On the 3 video blocks, 5 of 5 markers were loaded, the slot was open and 5 thumbnails were cached at the
            start. There were 18 Regenerates; each removed 5 and remade 5 (90 in all). **0 were made while playing**: the first came
            0.028–0.059 s after each Pause, and 0 were finished after Play. Around each press (±10 s): 0 holds, 0 skips, and 5 window
            late/dropped in all (5994 regen 5; gop25 regen 2, 4, and 5 ×2). From each Pause to the last thumbnail + 10 s: 0 holds, 0
            skips, 0 late/dropped. Setup at 19:00–19:03 confirmed 5 markers and 5 cached thumbnails on all three files.
          - **CCC overlap:** 1 run, 19:30:00–19:31:07 (68 s, exit 0, `ccc.log`), inside block 1 (19:03:18–20:04:25). 0 holds, skips or
            stalls during it. The block's one hold came 4 min later.
          - **Rig checks** (`rig.log`), before setup and before each block: no zoom.us, capture closed, Scarlett the default output, no
            `MANIFOLD_*` and no env, sha256 ok, slots `waveform | parade | markers`, window on the ASUS PA147 at 59.936 Hz, ad-hoc signing,
            memory 84–85 % free, no thermal warnings. The LG ran at 3840×2160 @ 120 Hz. Each block ran with the standard environment only
            (`MANIFOLD_DEBUG_TRANSPORT MANIFOLD_DECKLINK_CADENCE_LOG MANIFOLD_PLAYBACK_STATS`). Keychain prompts denied "tonight 0", but
            the setup log has "licence prompt denied (1 this block)" for setup-5994 and setup-2398 (`soak.out` 19:00:54, 19:01:43), and
            the per-setup counts read UNKNOWN. These do not agree. "SecurityAgent processes now" was 0 before setup and 1 before every
            block. WindowServer ASEProcessing after each block: 3,280, 2,467, 0 and 2,548 per minute (6 per minute after setup).
          - **Slot restore:** the slots were set to `waveform | parade | markers` (were `yrgb | meters | markers`; stash
            `prefs-stash-20261120-185044.txt`). They were still that at the end and were restored to `yrgb | meters | markers` at 23:08:00.
            A read of `com.graviton.manifold` on 2026-11-21 confirms `yrgb | meters | markers`.
        - **Rehearsal follow-up (2026-11-21, read-only; no build, no launch, no git).** Three questions: the hold, zoom.us, and the
          prompt tally. Paths are relative to `~/Code/_scratch/manifold-rc095-rehearsal/` unless named.
          - **Logging the block had.** Standard soak logging includes `MANIFOLD_DECKLINK_CADENCE_LOG=1`, so the log has `[CADENCE]` (one
            per pull) and `[CADENCE-SWAP]` (one per ring publish, `MetalVideoRenderer.swift:5957`). It has no `[PULLPHASE]` or
            `[TICKPHASE]` (`=2` only) and no `[PRESENT-TIMING]`. The `[CADENCE]` host and clock are read after the fill's copy
            (`DeckLinkService.swift:1227`, `MetalVideoRenderer.swift:508-513`), not at the pull itself.
          - **The hold, reconstructed** (`r95-5994-sdi-1.log`):
            - **Context.** The Play started at clock 1895.0 (line 226541) and wrapped at the file's end at host 596549.2: pulls
              #113061–#113069 held the last frame, 1919.984733, which is the expected end-of-file wrap and not counted. Pull #113070
              handed pts 0. The pacer re-set its reference at line 229750 (x_ref 3.913 ms). The C+ lead guard at line 229753
              measured a pull phase of 9.047 ms and a lead of 5.134 ms, under P + 0.5 ms. It moved x_ref 3.913 → 0.500 ms (lead 8.547
              ms) "at the guard band's edge", short of P + 0.5 = 8.84 ms. The 7 lead moves (net −3.413 ms, line 230473) are that move,
              done in steps in the first ~0.1 s, and leave x_ref at 0.5 ms. After that: 0 lead moves, 0 establishment nudges, 0
              outliers, 0 clamp hits; |x − x_ref| max 0.025 ms (line 231745). There was no transport event between the wrap and the
              hold (11.6 s later) or until the Pause 13.2 s after it (line 232880).
            - **The pull.** Slot #113767, clock 11.638513 (post-copy), handed 11.611600 a second time. 11.628283 was published at
              596560.835049, 9.354 ms before the `[CADENCE]` line. Before the hold, every pull handed the newest published frame with
              the clock 10.20–10.25 ms past it. From #113768 on, every pull handed the frame published one period earlier (26.84–26.94
              ms behind the clock) until the Pause, with no further change. Card: late 0, dropped 0, buffered 5 in every count
              (`DeckLink D3: frame 113760 — completed=113757 late=0 dropped=0 buffered=5`). Pacer: missed 0 (line 231743). Ring:
              `tick → SDI ring` max 2.53 ms in the 10 s window around the hold (line 231744). The SDI sound re-latched (latch #56), and
              card lock re-anchored the Mac sound +16.67 ms "(a slip)".
            - **The would-repeat test, reconstructed from the code** (`MetalVideoRenderer.swift:6293-6380`). The target is clock −
              (host − slotHost) − margin (`:6337`). slotHost is the minimum of the last 64 paced pulls' slot offsets (`:6314`). The
              margin is the median of 32 pacer ticks + 10 ms = 18.34 ms. The band is half a card frame, 8.342 ms, at a matched rate
              (`:6347`). Once the handed frame is the last one handed, the next frame is taken if `pts[next] ≤ target + band`
              (`:6366`); otherwise the last frame is held (`:6373`). From the logged clock, host and slot offsets, next − target was
              8.210 ms at #113766 and 8.212 ms at #113767: about 0.13 ms inside the band at both. Across the whole segment, the target
              moved within ±0.015 ms of the frame grid. Earlier pulls with less headroom took the next frame. **So by what the log
              records, #113767 should have taken 11.628283.** The repeat came from an input the log does not have: the pull's own host
              and clock (the logged ones are after the copy), the margin's median tick at that pull, or whether 11.628283's ring
              slot was visible to the pull when the pull read the ring. Which one: UNKNOWN.
              **Superseded 2026-11-21 (`CARD_PULL_MARGIN.md` §21.2):** calibrated on nights 5–7's `[PULLPHASE]`, the lead guard's
              pull phase (9.047 ms) puts this Play's headroom at about −0.07…+0.09 ms, on the edge. Within-Play wobble reaches
              0.12 ms, so an edge hold of the half-frame band needs no unlogged trigger. The 0.13 ms above came from `[CADENCE]`
              stamps taken after the copy (bias inferred, not measured).
            - **Against the known mechanisms.**
              - Crossing (a late window frame): not seen. The publish was on time, and the 10 s `tick → SDI ring` max was 2.53 ms.
              - Pacer miss: no (missed 0).
              - Renderer stall or near-miss: no.
              - C+ lead move: not at the hold; the moves ended 11.5 s before it.
              - Establishment nudge: none.
              - Loop wrap: the wrap set this Play's phase 11.6 s earlier, but the hold was not at a wrap.
              - The half-frame band: the closest known shape. The phase after the wrap sat near the band's edge, and the hold
                moved the card one frame back for the rest of the Play. This is §10.30's edge hold (`CARD_PULL_MARGIN.md` §1.1), at
                an 8.34 ms band. It is not proven: the reconstructed headroom, 0.13 ms, does not explain a repeat by itself.
              - **Verdict: an edge hold of the half-frame band, with the trigger UNKNOWN. Not a new mechanism if the trigger turns
                out to be one of the three unlogged inputs; otherwise new.**
            - **Nights 6–7 (C+ and B on; `[PULLPHASE]` logged; 0 holds).** At 59.94, C+'s lead guard stopped "at the guard band's
              edge" 4 times: `n6-5994-sdi-bon-2.log` lines 289492 and 506115, `n7-5994-sdi-bon-1.log` lines 364799 and 506097, with
              leads 8.663, 8.658, 8.730 and 8.830 ms. Tonight's 8.547 ms (pull phase 9.047) is the lowest at 59.94 in the three nights.
              In those 4 Plays every pull took the next frame through the band (`next-by-band`). Band headroom was 0.105–0.255 ms;
              publish lead was never under 7.0 ms. Across all 237 night 6–7 segments at 59.94, no segment was under 0.1 ms, and 4 were
              under 0.2 ms; 3 of those 4 are these lead-guard-edge Plays. Measured by `[PULLPHASE]` target, next and band per pull; scratch scripts
              `segd.py`, `slack.py`, `edgeleads.py` and `headroom.py`, in this session's scratchpad. So tonight's Play matches nights
              6–7's closest-to-edge Plays, which held 0 times. Lead-guard edges in general are common: 57 in the three nights' logs,
              most at 23.976 and 25p.
            - **This week's changes.**
              - C+ default: plausibly involved. 3 of the 4 closest-to-edge Plays on nights 6–7, and this one, are Plays where C+'s
                lead guard stopped at the guard band's edge. That is a correlation; the mechanism is not shown.
              - Plain B: no sign (it changes the window's present, not the ring), and night 7 ran it in every block.
              - The 200 ms watchdog: no stall or near-miss.
              - The SDI audio watchdog: no restart.
              - The Stage 2 guard: 0 refusals. The re-anchor followed the hold.
              - Whether `deckLinkPullSlotLocked` changed between night 7's `e80dc2b` and `fb9b1e6`: UNKNOWN without git. The
                check is `git diff e80dc2b fb9b1e6 -- App/MetalVideoRenderer.swift`.
              - Nights 6–7 also ran heavier logging (`CADENCE_LOG=2`, `PRESENT_TIMING=1`), so the conditions were not identical.
            - **What would have settled it:** `MANIFOLD_DECKLINK_CADENCE_LOG=2`. Its `[PULLPHASE] pull` record holds the pull's own
              host and clock, the target, band, margin, handed frame, branch (`held` vs `next-by-band`), the next frame and whether it
              was queued or converted, and the lead. One such line at #113767 names the branch and the input. `MANIFOLD_PRESENT_TIMING=1`
              would add the tick's own timing. The release soak runs neither, by the gate's rules.
          - **zoom.us at 23:07** (unified log, `launchd`):
            - **What launched it:** `gui/501/us.zoom.updater` spawned `ZoomUpdater` (PID 30786) at 23:07:33.731 "because interval".
              The source is `/Library/LaunchAgents/us.zoom.updater.plist`: `ZoomUpdater --update`, `StartInterval` 3600,
              `RunAtLoad` false. Its executable is inside `/Applications/zoom.us.app/`, so `zoom_running` (`ps -axo comm= | grep -iF
              zoom.us`, `common.sh:23`) matched it. The Zoom app itself did not launch.
            - **It ran 5 times that night,** about 31 s each, about 31 s later each hour: 19:05:29 (PID 28275), 20:06:00 (28928),
              21:06:31 (29555), 22:07:02 (30275) and 23:07:33 (30786). **All five were inside blocks:** 2–4 min into blocks 1–3, 13 s
              into block 4, and the fifth in block 4's last 24 s. The harness checked only before each block, so it missed four and
              stopped at the fifth (23:07:58). Every "zoom.us none" in `rig.log` was true only at the moment of the check.
            - **Other Zoom items:**
              - `/Library/LaunchAgents/us.zoom.updater.login.check.plist`: `--login-check`, `RunAtLoad`, so at login only.
              - `/Library/LaunchDaemons/us.zoom.ZoomDaemon.plist`: an on-demand Mach service.
              - Background items: the Zoom app's login item is "disabled".
              - Nothing in `~/Library/LaunchAgents`, and not among the login items.
              - Zoom's preferences (read-only): `us.zoom.updater.config.plist` `AU2_BackgroundUpdateTimeInterval` "12";
                `us.zoom.xos.plist` `ZoomAutoUpdateState` "ZoomAutoUpdateStateReady".
              - Whether Zoom's in-app auto-update setting stops the hourly launchd spawn: UNKNOWN. The plist schedules it regardless.
            - **To prevent it for a soak without uninstalling** (Robbie runs these; not done here):
              - Before the night: `launchctl bootout gui/$(id -u)/us.zoom.updater`. This unloads it until the next login and changes
                no file.
              - After the night: `launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/us.zoom.updater.plist`.
              - Or, persistently until undone: `launchctl disable gui/$(id -u)/us.zoom.updater`, later `launchctl enable …`.
              - Either way, the harness now records zoom.us instead of stopping (below).
          - **The prompt tally and SecurityAgent: a harness gap, and the prompts were real.**
            - **Why the tally read 0:** `markers_setup` saves no `licence_prompts_denied` (`rc-soak.py:248`), so `afterblock` reads
              UNKNOWN for each setup and adds nothing (`soak.sh:95-96`). The two "licence prompt denied" lines are real clicks on Deny
              (`rc-soak.py:61`).
            - **There were three dialogs, not two.** SecurityAgent logged "SC confirmation dialog detected" at 19:00:48 and 19:00:55
              (setup-5994) and at 19:01:43 (setup-2398). `markers_setup` calls `deny_licence_prompt()` once, 7 s after launch
              (`rc-soak.py:259`), so it never saw the second setup-5994 dialog. What closed it: UNKNOWN. Probably that launch's quit at
              19:01:36; an inference.
            - **No dialog in any block.** At each block launch, securityd connected to SecurityAgent (19:03:19, 20:04:28, 21:05:38,
              22:06:50), but no dialog was logged, matching the 0 denials per block.
            - **"SecurityAgent processes now: 1" is one resident process,** PID 27921, started on demand for the first setup prompt at
              19:00:48. Its last log line was at 22:06:50, and it is not running now. `secagent` counts processes, not open windows
              (`common.sh:24`), so the "1" does not mean a prompt was left open.
          - **Harness change (Robbie, 2026-11-21): zoom.us is now recorded only, and the night continues.**
            - `soak.sh` (rehearsal folder): `zoomcheck`, which stopped the night, is replaced by `zoomwatch`. It runs in the
              background for the whole night, polls every 2 s, and writes `zoom.us watch: appeared` / `disappeared` / `present at
              start` lines (time, PID, executable) to `rig.log` and `soak.out`. It stops in the EXIT trap, or by itself when
              `soak.sh` is gone.
            - The before-launch rig line now records the zoom.us processes found instead of asserting none.
            - `common.sh`: adds `zoom_procs`.
            - `RIG.md`: the two lines that described the old zoom.us check now describe this one.
            - `rc-soak.py` had no zoom.us check, so it is unchanged.
            - `rc-soak-report.py` (repo, uncommitted): a per-block `zoom.us (recorded only)` line (running at the block's start, and
              every event in the block) and a `== ZOOM.US` line after TOTAL, in no verdict. A `rig.log` with no watch lines reads "not
              recorded".
            - **Checks:**
              - `zsh -n` is clean.
              - A dry run of the watch against a fake process list logged present-at-start, appear and disappear lines correctly.
              - The report on the rehearsal folder is unchanged apart from the new "not recorded" lines.
              - On a synthetic `rig.log` with the five runs above, all 5 were placed in blocks.
        - **0.9.5 final soak result (2026-11-21 23:26 – 2026-11-22 06:46): `rc-soak-report.py` 0.9.5 GATE: FAIL, on markers only.**
          Candidate: `.build-rc095`, a Profile build of `7b909e3`, bundle 0.9.5 (27), ad-hoc linker-signed, sha256 `e21902114072e34d…`
          (`RIG.md`). Chain, logs, `soak.out`, `soak.report`: `~/Code/_scratch/manifold-rc095-final/`. All 7 blocks ran. Wall time 7.13 h,
          6.53 h playing. GATE (0.9.3 rule): PASS, with 0 freezes, 0 unrecovered, 0 holds, 0 skips. Card late 0, dropped 0. Renderer: 0 stalls,
          0 near-misses. B1: 0 in every block. The two ao48 blocks pass the 0.9.5 gate. The five video blocks fail it only on `markers FAIL`
          (`soak.report:24, 48, 83, 107, 131`). MARKERS line: regenerates 30, made while playing 0, blocks failing 5, and near them
          holds+skips 0, late/dropped 9 (`soak.report:179`).
        - **Final-soak markers follow-up (2026-11-22, read-only; no build, no launch, no git beyond log/diff).** Paths are relative to
          `~/Code/_scratch/manifold-rc095-final/` unless named.
          - **What failed: Regenerate was never pressed. The 9 late/dropped are not why the check failed.** The MARKERS verdict is
            `blocks failing == 0 and made while playing == 0` (`rc-soak-report.py:568`). A block fails when the slot was not found or a
            Regenerate was not good (pressed with `ax_rc` 0, the app's n = 5, 5 remade, 0 while playing; `:437`, `:448-449`). Late/dropped is
            only printed (`:571-572`). Every block reads `Markers slot NOT FOUND`, and all 30 Regenerates read `no-gear`: app n = None,
            removed 0, remade 0 (`soak.report:11-22` and the same in each video block). Setup had already failed on all three files
            (`soak.out:13-27`: "no-markers-slot", then "!! marker setup NOT ok: the blocks run, markers recorded as failing").
          - **Cause: 82e39bc changed the gear's tooltip, and the soak's AX helper matches that tooltip exactly.** `rc-soak-ax` finds the
            gear by AXHelp in a fixed set: "Thumbnails, colors shown, start timecode" or "… colours shown …"
            (`scripts/decklink-loopback/rc-soak-ax.swift:12, 26`). 82e39bc changed it to "Thumbnails, text size, colors shown, start timecode"
            (`App/Markers/MarkersScopeView.swift:42`; it was `:39` at `5bad8d3`). This is the same failure 4067abb fixed for the colours →
            colors change ("soak driver accepts new tooltip"). The installed helper `build/decklink-loopback/rc-soak-ax` was built 2026-11-15.
          - **1. What late/dropped counts.** `rc-soak.py` stamps each line on the host clock when it reads it (0.25 s poll;
            `rc-soak.py:182-186`). It counts three things: `DeckLink D3: !! DisplayedLate` (card late), `DeckLink D3: !! Dropped` (card dropped),
            and every `[PLAYBACK-STATS]` line with dropped + late > 0 (the window, summed as one "window dropped/late" count). Pacer missed
            deadlines are not counted. "Near" is the sum of two windows per Regenerate: ±10 s around the press (`WIN = 10.0`,
            `rc-soak-report.py:75, 445`), and from the next Pause to the last thumbnail + 10 s (`:446-447`). Here the second window is empty
            because no Pause was tracked: `ax_rc` 3 ends tracking at once (`rc-soak.py:214`).
          - **2. The 9 (8 log lines, one with n = 2).** All are window counts. None is a card line, so none is on SDI. All 8 came while
            playing; none came while paused. Each lands at a transport jump that the hold counter already excludes:

            | Block | Regenerate | Log line | Kind | ms from press | Transport |
            |---|---|---|---|---|---|
            | `f95-5994-sdi-1` | 4 | 569898 | window late 1 | +1862 | playing; loop wrap (pts 0.000) |
            | `f95-2398-cmp-1` | 2 | 116843 | window late 1 | −9281 | playing; loop wrap (pts 0.000) |
            | `f95-2398-cmp-1` | 5 | 294173 | window dropped 1 | −3110 | playing; 0.1 s after a seek |
            | `f95-gop25-sdi-1` | 2 | 121767 | window late 1 | −8777 | playing; loop wrap (pts 0.480) |
            | `f95-gop25-sdi-1` | 5 | 306347 | window dropped 1 + late 1 | −2061 | playing; 1.0 s after a seek |
            | `f95-5994-sdi-2` | 5 | 711143 | window dropped 1 | −3095 | playing; 0.1 s after a seek |
            | `f95-2398-cmp-2` | 2 | 116849 | window late 1 | −9027 | playing; loop wrap (pts 0.000) |
            | `f95-2398-cmp-2` | 4 | 235775 | window late 1 | +2122 | playing; loop wrap (pts 0.000) |

            Six of the eight came before the press, and nothing was pressed in any case. They are possibly visible on the desktop viewer
            (the ASUS) as one dropped or late frame at a seek or a wrap. They are not on SDI: card late 0 and card dropped 0 all night.
          - **3. Earlier nights, same rule.** The check and its windows are unchanged since 4067abb (2026-11-15). 2c09586 changed only the
            gate line, and 5bad8d3..7b909e3 touches only the gate and edge-start code (`git diff`). The current script over each folder gives:
            rehearsal (`manifold-rc095-rehearsal`) PASS, 18 Regenerates, late/dropped 5. Night 5 (`manifold-pacerphase-ab4`) PASS, 24, 6.
            Night 6 (`ab5`) PASS, 24, 4. Night 7 (`ab6`) PASS, 30, 7. 0.9.4 soak (`manifold-rc094-soak`) PASS, 30, 6. On those nights the
            slot was open and every Regenerate was pressed. Per window that is 0.17–0.28, against 0.30 tonight, with no Regenerate at all.
          - **4. 82e39bc and Regenerate.** `git diff 5bad8d3..7b909e3 -- App/Markers/MarkersScopeView.swift` changes no line about
            regenerate or the thumbnailer. The button is unchanged (`MarkersScopeView.swift:100`). Thumbnail height now comes from
            `metrics.thumbnail`, which is only the view's `.frame(height:)` on an image already made (`MarkerThumb`, `:546-565`). Medium is
            exactly 32 (`Packages/ManifoldCore/Sources/Markers/MarkerTextSize.swift:60`), the old literal. 82e39bc cannot change Regenerate's
            timing. Its only effect on the soak is the tooltip.
          - **5. Background rate.** Every window late/dropped of the night (124 frames) falls in one of two places: 0–1 s after a seek
            (87), or 25 s after Play in the 50 s play step, the loop wrap (37). Seeks made while playing give one 63 % of the time (66/105);
            seeks made while paused never do (0/210). Each press waits until 3 s after a transport step while playing (`REGEN_CLEAR`,
            `rc-soak.py:28, 203`), so its ±10 s window takes in a seek made while playing or a wrap almost every time. Per hot spot, the
            rate inside the windows (seeks 4/5, wraps 3/6) is in line with the rate outside them (seeks made while playing 66/105, wraps
            34/99). A naive per-hour comparison (48/h near against 19/h background) overstates the effect, because the windows are
            phase-locked to those jumps. No Regenerate ran, so the night is itself the control.
          - **6. Verdict: (c), as a harness break, not a product or timing defect.** 82e39bc's tooltip change hid the gear from
            `rc-soak-ax`, so Regenerate was not tested on 7b909e3. It is not (a): no Regenerate ran, and the 9 match nights with real ones. The
            9 are also a small (b): the "near" count includes window frames at seeks and wraps, which the hold counter excludes. It is in
            no verdict.
            **Recommendation for 0.9.5** (Robbie's call; to be done in a session in this repo):
            1. Add the new tooltip to `gearHelps`, or better, find the gear by a stable accessibility identifier, and rebuild `rc-soak-ax`.
            2. Check `rc-soak-ax <pid> gear` returns 0 against the 7b909e3 candidate, then run `markers-setup` on the three files.
            3. Re-run the markers part of the gate on the same binary. The other gate items passed tonight on the unchanged sha256. Whether a
               markers-only run (the five video blocks with markers) is enough, or the full 6 h night is needed, is Robbie's decision.
            4. Make a failed marker setup stop the night (`soak.sh`), rather than "the blocks run, markers recorded as failing". That
               cost this night.
            5. Optional: report the near-Regenerate late/dropped against matched seek and wrap hot spots, or exclude the EXCL s after a
               transport step, as holds already do.
        - **0.9.5 baseline 2 (2026-11-25 11:09 – 18:17): GATE PASS; 0.9.5 GATE UNDETERMINED, on B1 in one block only.** The shipped 0.9.5 (28),
          Developer ID, the same bytes as `/Applications/Manifold.app` (sha256 `2ca349fbeb04853d…`), run from `.build-r095-28/`. Chain, logs,
          `RIG.md`, `soak.report`: `~/Code/_scratch/manifold-095-baseline2/`. (The first baseline night froze behind the launch update alert,
          `BUGS.md`.)
          - **Night:** all 7 blocks ran, each exit 0 with a clean guard. Wall 7.13 h, 6.53 h playing. 0 freezes, holds, skips, renderer stalls,
            card late and card drops. Markers PASS (30 Regenerates, 0 made while playing). 0 update alerts, 0 license prompts (`rig.log`).
          - **Not PASS: `b95b-5994-sdi-1` B1,** with `[PACER] stopped` 4 > 2 and no `[PRESENT-TIMING]` lines, so the rule cannot subtract (`soak.report:24`).
            The 4 are two 25.0 ms intervals of 2 deadlines each (10 s windows at lines 126913, 358599). Each fell in the display link's run after
            a seek made while paused (seek lines 124680, 358078; `[RENDER-PERF]` 124939, 358334).
          - **They are inferred to be post-seek first-frame renders, but not named.** Night 7's subtracted miss (`CARD_PULL_MARGIN.md` §20.3) has the
            same sequence: a seek from pause, a 62-tick run, 25.02 ms, and the new frame's `[TICKPHASE]` 43–51 ms after the seek. `rc-soak-report.py`
            now prints this placement (uncommitted). The verdict is unchanged. Open, for Robbie: accept B1 on this evidence, or re-run the
            block with `MANIFOLD_PRESENT_TIMING=1`.
          - **`[PULLPHASE]`, both 59.94 blocks:** 126 Plays, 74 next-by-band establishments, 0 within 0.1 ms of the would-repeat edge, 0 held pulls in
            steady state while playing (`CARD_PULL_MARGIN.md` §21.7). All 10 launches ran license startup twice (2 × `[LICENSE] state: LICENSED
            (Standard)`; `BUGS.md`, the launch update alert entry, C).
- [ ] After the release: commit the `CURRENT_PROJECT_VERSION` bump the script wrote

---

## ⚠️ Profile is the default, and Profile ships

`Profile` is a fully optimized build **with `DEBUG=1`**. Every `#if DEBUG` block is live:

- ⌃⌥D SRT connect and ⌃⌥H WHEP connect
- the Experiment 3 colourspace-destination cycling (`[CSDEBUG]` / `[CSPROBE]`), which fires
  on every source load
- `SyntheticLiveSource`
- the `/tmp/manifold_debug_cs` file hook
- per-second `[SRT-FLOW]` / `[WHEP-FLOW]` telemetry that `Export Diagnostics…` depends on

**Unless someone types `Release`, Profile is what gets published to the public
`releases.graviton.tools/manifold/mac-arm64` URL.** Every build cut to date has been
Profile — confirmed from `~/Code/Manifold/Builds/Manifold/`, which holds 0.5.0 builds 2–4 and 0.5.1
builds 5–6, all Profile.

That is currently fine — everyone downloading is a tester — and stops being fine the moment
a stranger has the link.

`Release` compiles those out and loses the diagnostics that make "judders on my machine"
reportable, which is why Profile was chosen. Nothing is transmitted anywhere; diagnostics
are user-initiated and redacted. The objection is unaudited dev affordances in a public
build, not privacy.

**Before switching the public download to Release you need:** the dev-path audit done, the
Core telemetry leak fixed (below), and a decision about whether some telemetry should
survive into Release so a shipped user can report a stutter at all.

**The DMG filename is the only thing distinguishing the two once published** —
`Manifold-0.5.1-6-Profile.dmg`. The Graviton convention is `<App>-<version>-<arch>.<ext>`;
this deviation is deliberate and load-bearing. It stays until the tester and public
channels are separated — a distinct R2 prefix for testers, with the script refusing
`Profile` → `current/`. Removing it before then removes the last signal.

---

## Versioning

Version and build number live in `project.yml`:

```yaml
MARKETING_VERSION: "0.5.1"
CURRENT_PROJECT_VERSION: "6"
```

The release script reads `MARKETING_VERSION`, increments `CURRENT_PROJECT_VERSION` by one,
and writes it back with `sed`. **The operator commits the bump afterwards** — the script
does not.

`App/Info.generated.plist` carries different values (1.0 / 1). That is intentional:
`GENERATE_INFOPLIST_FILE: YES` makes the build settings win, and the script asserts the
built plist against `project.yml` after archiving.

**Manifold is the only Graviton product with a build number**, which is why the manifest's
optional `build` field exists. `UpdateChecker` uses it as a tie-break when versions match.

Because the build number auto-increments on every run, re-releasing the same version
overwrites its archived artifact in `archive/<version>/`. **A published artifact should
mean a new version number.**

---

## Signing specifics

Signing settings live in `project.yml`, not in a separate config file:

```yaml
CODE_SIGN_STYLE: Automatic
ENABLE_HARDENED_RUNTIME: YES
DEVELOPMENT_TEAM: 8UQ7MDM87B
CODE_SIGN_ENTITLEMENTS: App/Manifold.entitlements
ARCHS: arm64
```

`build/ExportOptions.plist` is gitignored and regenerated by the script if absent, so a
fresh clone is unaffected.

**Entitlements are one key**, because the app loads unsigned third-party dylibs:

```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

**Nested dylibs.** The five FFmpeg dylibs are `embed: true, link: false, codeSign: true`
in `project.yml`, re-signed by `-exportArchive`, then asserted per dylib for install name
(`@rpath/…`), authority, hardened runtime flag, and timestamp — all four, all fatal. This
is the reference implementation for nested-binary verification across Graviton; the
Electron stack was built to match it.

**Unlike Electron, the DMG itself is signed here**, and stapling is explicit rather than
handled by a packaging tool.

---

## LGPL corresponding source

FFmpeg ships as **shared dylibs, not static archives**, to satisfy LGPL 2.1 §6. Preflight
fails if a `.a` reappears in `ThirdParty/ffmpeg/lib`, which would silently undo the
migration. Do not "optimize" this back to static linking.

The release script publishes the corresponding source itself, keyed by the FFmpeg pin and a
build revision (`-rN`, bumped for any change to the configure line) rather than the app version:

```
graviton/manifold/source/ffmpeg-n8.1.1-239f2c733de4-r2.tar.xz
```

A HEAD against the public URL guards it, so a normal release uploads nothing, and a published
tarball is never overwritten: the upload runs only on a 404 `Not found`. See
`ThirdParty/ffmpeg/README.md` for the revision rule. Two preflight
assertions block a release if the license posture breaks: `ffmpegSourceURL` in
`App/AboutWindow.swift` must equal the URL derived from the pin, and `licensingContact`
must be a real address.

**This is the mechanism GradeShare needs and does not have** — its About panel offers five
source tarballs that nothing publishes.

---

## Fragilities

**The five dylib soname majors (62 / 62 / 60 / 9 / 6) are stated in three places** —
`project.yml` dependencies, `EXPECTED_DYLIBS` in `release-mac.sh`, and `major_for()` in
`build_ffmpeg.sh`. Bumping the FFmpeg pin means changing all three or the build breaks in
a confusing way.

**Absolute-path `.a` entries in `OTHER_LDFLAGS`** are wrapped as `'"$(SRCROOT)/…"'` because
the repo path contains spaces. Brittle if quoting behaviour changes.

**Hardcoded paths:** `~/Code/Manifold/Builds/Manifold`, the three `$HOME` scratch trees, the legacy
`~/Code/Manifold/manifold-ffmpeg-srt/FFmpeg-n8.1.1` provenance tree, `/Library/NDI SDK for Apple/include`,
`/usr/local/lib/libndi.dylib`, `/Library/Frameworks/DeckLinkAPI.framework`, and
`docs/BlackmagicDeckLinkSDK16.0/Mac/include`.

**`UPLOAD_SCRIPT` is resolved, not hardcoded.** `GRAVITON_RELEASES_DIR` wins if set;
otherwise `release-mac.sh` walks up from the repo root looking for
`<dir>/Graviton-Releases/upload-release.sh` and stops at the first hit. It used to be a
fixed `${REPO_ROOT}/../..`, which encoded how deep the repo happened to sit and broke
silently on any move. A wrong `GRAVITON_RELEASES_DIR` does NOT fall back to the search —
it fails, rather than publishing through an unintended checkout. Preflight fails before
any compilation and prints every path it tried; `--no-upload` skips the check entirely.

**`|| true`-style guarded greps appear throughout** and the reason is documented at length:
`producer | grep -q` SIGPIPEs its producer under `set -o pipefail` and reports a successful
match as a failure. The `contains` / `has_line` / `find_lines` helpers exist for that.

**`create-dmg` non-zero exit is tolerated** only if the image exists and `hdiutil verify`
passes — deliberately not a blanket `|| true`. The cause is Finder AppleScript styling
failing over SSH or with a locked screen.

---

## Known gaps

**Core telemetry ships in Release builds.** `MANIFOLD_TELEMETRY` is defined
unconditionally in `Packages/ManifoldCore/Package.swift`, so Core-layer strings like
`[LIVECLOCK]` and two tuning setters are present in a Release archive. The release
script's telemetry assertion greps for `[SRT-FLOW]`, which is an App-layer string gated on
`DEBUG` — so the check is **true but incomplete**. Hygiene rather than behaviour. Fix is to
move emission to the App layer plus an archive build-phase tripwire.

**The dev-path audit is outstanding.** The `#if DEBUG` blocks listed above are the ones we
know about. "Most are gated" is not an audit, and a public Release build should not ship
until one has been done.

**`project.yml` and `release-mac.sh` disagree about the scheme's archive configuration.**
The script's header comment says the archive action is pinned to `Release`; `project.yml`
sets `archive: config: Profile` and its own comment says so deliberately. `project.yml` is
what takes effect. The script's own `-configuration` override means its behaviour is
unaffected, but the comment is wrong and should be corrected.

**Toolchain versions are recorded nowhere.** Nothing pins Xcode, xcodegen, create-dmg, or
wrangler. The archive logs live outside the checkout in `~/Code/Manifold/Builds/Manifold/*/logs/`.

**No git tags.** Release state lives in the `CURRENT_PROJECT_VERSION` bump commit and the
R2 archive path. Consistent with the rest of the estate.

**`.gitignore` has duplicated stanzas** — `*.xcodeproj/` at two lines,
`docs/Blackmagic Advanced Video Capture and Playback/` at two, `.DS_Store` at two.
Harmless; looks like merge residue.

**Step numbering in `release-mac.sh` is non-monotonic** — headings run 0–11 then
"13. Publish", with a "12b. Corresponding source" block nested inside the publish branch
and executing before it. There is no step 12. Cosmetic.

**Licensing is wired and active.** Setup, key generation, and the activation and validation
endpoints live in the licensing repo, not here. `ROSTER.md` in Graviton-Releases is the
join point between the two.

**TO CONFIRM — `docs/Iris-Scaffold-Step1.md`.** Present in this repo's `docs/`, but the
name suggests it belongs to Scaffold. Confirm whether it is Manifold's or should move.

---

## Troubleshooting

Signing and notarization problems common to every Graviton product are in
`stacks/swift.md` and `IDENTITY.md`. Manifold-specific:

**Preflight fails: "vendored libs missing"**
→ One of the three `ThirdParty/` trees has not been built. Rebuild with the corresponding
`scripts/build_*.sh` and see that library's `ThirdParty/*/README.md`.

**Preflight fails: "STALE STATIC ARCHIVES in ThirdParty/ffmpeg/lib"**
→ A `.a` has reappeared where shared dylibs belong. This guard exists to stop a silent
regression of the LGPL §6 shared-library migration. Rebuild FFmpeg with
`scripts/build_ffmpeg.sh`; do not delete the guard.

**Preflight fails on the notarization profile**
→ `xcrun notarytool history --keychain-profile graviton-notarytool` to test it directly.
Recreate with `store-credentials` if invalid — see `IDENTITY.md`.

**Preflight fails on DeckLink or NDI headers**
→ DeckLink SDK 16.0 must be copied into `docs/BlackmagicDeckLinkSDK16.0/Mac/include`; the
NDI SDK must be installed at `/Library/NDI SDK for Apple`. Both are gitignored and neither
is vendored.

**Xcode's Run button: "The executable is not codesigned"** (recorded 2026-08-27)

→ An agent or terminal `xcodebuild` wrote into the SAME derived data Xcode reads from, and a
Run landed while a build was in flight. **Fix: every command-line `xcodebuild` in this repo
must pass `-derivedDataPath ./.build-cc`** (gitignored). Read built artifacts back from
`./.build-cc/Build/Products/<Config>/`, not from `~/Library/Developer/Xcode/DerivedData/`.

⚠️ **THE FIRST EXPLANATION WAS WRONG, AND IT IS THE MORE TEMPTING ONE.** The hypothesis was
that headless builds pass signing overrides — `CODE_SIGNING_ALLOWED=NO`,
`CODE_SIGNING_REQUIRED=NO`, or an empty `CODE_SIGN_IDENTITY` — and so deposit an unsigned
product. **Measured against the actual command lines: no such flag was passed.** The full
invocation was

```
xcodebuild -project Manifold.xcodeproj -scheme Manifold -configuration <Config> \
           -destination 'platform=macOS,arch=arm64' build
```

and nothing else — no signing variables, no `-allowProvisioningUpdates`, and (the actual
defect) no `-derivedDataPath`.

The mechanism is a **write race**, not a signing configuration. A both-configurations check
loop invoked `xcodebuild` twice per configuration — four builds — into the shared derived
data, and a Run landed on a product that existed but had not yet reached its CodeSign phase.
Two observations pin it: the artifact left behind afterwards verifies clean
(`codesign --verify --strict` exit 0, `TeamIdentifier=8UQ7MDM87B`, hardened-runtime flag
set), so nothing about the signing configuration was wrong; and the failure is not
reproducible from the resting state, which a bad override would be.

Chasing the override theory means auditing signing settings that were never at fault. The
directory is the variable — isolate it.

**A dylib assertion fails after export**
→ Install name, authority, hardened runtime flag, or timestamp is wrong on one of the five
FFmpeg dylibs. Usually means `codeSign: true` was dropped from that dependency in
`project.yml`, or the dylib was rebuilt without `--install-name-dir=@rpath`.

**Manifest verification fails after publishing**
→ The uploader wrote a manifest naming a version, build, or filename that does not match
what was just built. Five attempts three seconds apart with cachebusting are already tried,
so this is not edge propagation. Check what actually landed in
`graviton/manifold/current/`.

**Xcode's Product ▸ Archive gives an unexpected configuration**
→ The GUI uses `project.yml`'s `archive: config:`, currently `Profile`. The release script
overrides it explicitly with `-configuration`, so the two can differ. Always release
through the script.
