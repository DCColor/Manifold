# Soak tooling

The unattended A/V soaks of `docs/AUDIO_RESAMPLER_DESIGN.md` §18 and the offline replays of the WHEP
SR fit (§18.7). Nothing here is part of the app build.

## Prerequisites

- **Two OBS instances with obs-websocket v5.** The password is read from OBS's own
  `plugin_config/obs-websocket/config.json` and never printed.
  - **Sender**, websocket **4455**: scene `BLIPS_NOISE` holding the sources `BEEPS` (the flash-beep
    fixture, looping) and `NOISE` (the 1200 s reference noise). Video at 23.976.
    - Profiles `MediaMTX Local` (WHIP to MediaMTX), `WHIP Cloudflare` and `SRT Cloudflare`.
    - All in **Advanced** output mode with a **1 s keyframe**. The orchestrator checks both
      settings and refuses to start otherwise.
  - **Recorder**, websocket **4456**, 60 fps:
    `open -n -a OBS --args --multi --profile Recorder --collection "AV Capture" --websocket_port 4456`.
    It captures the display and, through a `macOS Audio Capture` source, Manifold's audio. That
    source must be re-picked by hand after every Manifold launch; the orchestrator's voice asks.
- **`~/Desktop/Manifold-Test-Sources/`**: `criterion12-flash-beep-25p-60s.mov`, the file control
  played in Manifold.
- **Audio Hijack** recording Manifold's output, for the mute count.
- **A Manifold build.**
  `xcodebuild -project Manifold.xcodeproj -scheme Manifold -configuration Profile -derivedDataPath ./.build-cc/soak-Profile CODE_SIGNING_ALLOWED=NO build`,
  or point `MANIFOLD_APP` at any `Manifold.app`.
- **For MediaMTX runs:** the `mediamtx` binary in `$MEDIAMTX_DIR` (default `~/Desktop/mediamtx`).
- `node` (≥ 22, for its built-in WebSocket), `python3`, `ffmpeg`, `swiftc`.
- **Analysis dependencies kept outside the repo on purpose** (BUGS.md, "Sync calibration mode"):
  - `avsync.py`, the flash/beep detector, in `$AVSYNC_DIR` (default `~/Desktop/manifold-avsync`);
  - the device-output mute tracker `reference_track.py`, its venv and `ref-1200s.wav`, in
    `$AUDIBLE_EVENTS_DIR` (default `~/Desktop/manifold-audible-events`).

Outputs (timelines, stdout captures, the RTSP sender probe, the watcher's CPU log, analysis cuts,
replay binaries) go to `$SOAK_OUT` (default `~/Desktop/manifold-soak`), never into the repo.
Manifold's log goes to `$SOAK_LOG_DIR/<label>.log` (default `~/Desktop`).

## Running a soak

```sh
zsh scripts/soak/go.sh mediamtx          # ~40 min: control, 28 min live, control
zsh scripts/soak/go.sh cloudflare        # the same on Cloudflare WHEP
zsh scripts/soak/go.sh cloudflare-long   # self-ending: live to +4 h 30, then OBS stops
zsh scripts/soak/go.sh cloudflare-srt    # ~40 min on Cloudflare SRT (OBS and Manifold both callers)
zsh scripts/soak/go.sh mediamtx --diag   # + a 135 s sender probe at capture A and at capture B, aligned
                                         #   with them, analysed into $SOAK_OUT/soak-<label>-diag/ (§18.21)
zsh scripts/soak/go.sh mediamtx --abs    # MediaMTX with useAbsoluteTimestamp: true (mediamtx-soak-abs.yml):
                                         #   the publisher's own SRs kept; label <prefix>-abs-whep-mediamtx (§18.23)
node scripts/soak/control2.mjs <manifold-log>   # control 2 of a cloudflare-long run, later
```

`go.sh` starts the orchestrator and the watcher, then Manifold under `caffeinate`. `SOAK_PREFIX`
names the run (`<prefix>-whep-mediamtx`, …).

The operator's part is spoken by the orchestrator:
1. deny the licence prompt;
2. start Audio Hijack;
3. open the fixture, looping on, and press play;
4. re-pick Manifold in the recorder;
5. connect the WHEP bookmark when asked;
6. at the end, disconnect and play the fixture again for control 2.

| file | what it does |
|---|---|
| `go.sh` | one run: preflight checks, MediaMTX with RTSP (MediaMTX runs only), watcher, orchestrator, Manifold |
| `soak.mjs` | the orchestrator; see "What the orchestrator does" below |
| `soaklog.mjs` | pure scans of Manifold's log for the orchestrator (the session end and deck release, in either order); tested by `node --test scripts/soak/soaklog.test.mjs` |
| `obsws.mjs` | minimal obs-websocket client; also a CLI: `node obsws.mjs 4455 GetStreamStatus` |
| `control2.mjs` | a later control 2: waits for the fixture to play, records 300 s, appends to the timeline |
| `watcher.py` | read-only: Manifold %CPU every 10 s (`cpu.csv`), volume of each new capture, a warning on more than one Manifold PID |
| `srfit-live.sh` | the SR fit's state in a running or finished log: events, window, cross-check, depth, END |
| `mediamtx-soak.yml` | the plain MediaMTX config plus RTSP (127.0.0.1:8554, for the sender probe) and HLS |
| `fixtures/make_decklink_fixture.py` | builds the DeckLink-sender fixture file (see "A realistic sender") |
| `mediamtx-soak-abs.yml` | the same with `useAbsoluteTimestamp: true` on `live` (`go.sh --abs`); keep the two in step |

**What the orchestrator does** (`soak.mjs`):
- **Setup:** switches and verifies the sender profile.
- **Control 1:** a preflight until the recorder hears Manifold, then a 300 s file control.
- **Live:** starts the stream, waits for the connect, then:
  - capture A at +3 min;
  - the noise segment +5:30 → +25:30;
  - capture B at +26 min (or at +4 h 30 on `whep-cf-long`, which then stops the stream and checks
    that Manifold's media-stall watchdog ended the session).
- **Control 2.**

## A realistic sender: Resolve → SDI → DeckLink (`--sender decklink`)

Picture and sound come from one card, as from a real facility, instead of from two OBS media sources.
A Resolve workstation plays a fixture file out through its Blackmagic output, over SDI, into this
Mac's DeckLink input; the sender OBS streams scene `DECKLINK_BEEPS` as usual.

```sh
zsh scripts/soak/go.sh cloudflare --sender decklink   # label <prefix>-decklink-whep-cloudflare
zsh scripts/soak/go.sh mediamtx --sender decklink     # label <prefix>-decklink-whep-mediamtx
```

**The fixture** is made once by `fixtures/make_decklink_fixture.py` (the audible-events venv's python):
`~/Desktop/Manifold-Test-Sources/decklink-flash-beep-noise-2398-45m.mov`.
- **Video:** ProRes 422 Proxy, 1920×1080 at 24000/1001, 64 735 frames (≈ 45 min). Black, with one
  white frame per whole second (the first frame at or after it).
- **Audio:** pcm_s24le 48 kHz stereo.
  - The fixture's beep, sample-exact on every whole second.
  - `mutes-pitch-ref-1200s.wav` once, from 330 s to 1530 s, with the beeps muted meanwhile: go.sh's
    noise schedule, baked in.
  - Both at 0 dB, the noise copied to both channels, as BLIPS_NOISE's OBS mix.
- **Timing:** beep − flash is 0 grid-corrected, and as written 0…41.7 ms (mean T/2 = 20.854 ms), as
  BLIPS_NOISE's render grid gives today.
  - c12.py's grid-corrected figure adds +20.0 (the 25p fixture's 40 ms flash). On this file the right
    constant is +20.854, so it reads −0.85 ms off. Constant, so B − A is unaffected.
  - The sender adds its own terms: OBS re-renders the card's frames on its own 23.976 clock (up to one
    frame, slowly walking), and the Resolve and DeckLink paths.

**What the orchestrator does differently:**
- **Touches no media source and no scene.**
  - It checks that `DECKLINK_BEEPS` is the program scene, holding an enabled DeckLink input,
    unmuted at 0 dB. Otherwise it stops.
  - It never plays, restarts, seeks or mutes anything in OBS.
- **Anchors the schedule on the file, not the connect.**
  - After the connect it asks you to start Resolve (stopped at the start of the timeline, loop on).
    If beeps were already arriving it asks you to stop and park Resolve first.
  - It takes the first `[AV-CONTENT] beep in` line in Manifold's log as the file's 0 s. That is a
    DEBUG line, so a Profile build is needed.
  - The anchor is that line's own `host=` time (CACurrentMediaTime, the clock Node's `process.hrtime`
    reads) converted to wall time, not the moment the script noticed it. Before 2026-09-30 21:51 it
    was the noticing time, up to the spoken prompt's length late (5 s on that run). The prompt is
    now spoken in the background.
  - Captures A / B and the end are timed from that anchor (+180 / +1560 / +1710 s). The noise segment
    is in the file, so the timeline marks it rather than toggling it.
- **Records the sender's own output** (StartRecord on 4455 at the anchor, StopRecord at the end).
  WHIP Cloudflare records with the stream encoder, so there is no second encode. Read it afterwards
  with `probe_av.py <recording> 180 1560`: the sender's A/V at the capture windows, independent of
  the relay and of Manifold.
- **Unchanged:** the controls (Manifold plays the 25p fixture from disk), the recorder captures, the
  voice prompts, and the Audio Hijack noise-segment analysis. `noise_start.py` finds the segment by
  its content, so it does not depend on when Resolve started.
  - Check its result against the timeline: the noise should start ~330 s after "file start" in the
    Audio Hijack capture. A mismatch means Resolve was not at the start when play was pressed.

## Analysis

| file | what it does |
|---|---|
| `analysis/c12.py` | criterion 12 on a capture: avsync's gates plus one burst per beep and level between beeps; as-written and grid-corrected offsets |
| `analysis/fc.py` | a looped file control, per loop, with loop gaps split out |
| `analysis/mutes.sh` | criterion 1: finds the noise segment in an Audio Hijack WAV (`noise_start.py`) and runs the tracker on it |
| `analysis/extract.py` | `<log>` → `<name>.pairs.tsv` (SR pairs, formed as the fit forms them; last session) and `<name>.windows.tsv` (steering depth + fit offset per window) |
| `analysis/shape.py` | a Δ series' shape: slope, residual sd, jumps; depth and depth-implied slopes |
| `analysis/depth_term.py` | the log term of the restated start → end (§6.3): queue depth at capture A − at 60–120 s, any transport |
| `analysis/net.py` | rolling 600 s depth-implied slope against the applied slope |
| `analysis/avlag.py` | `[AV-LAG]` lines (DEBUG builds): A/V at the glass and its parts per 3-min block, Theil–Sen slopes, LiveClock's rail share |
| `analysis/probe_ts.py` | a received `.ts` on its own timestamps: audio PTS vs sample count, video PTS vs frame count, video step histogram, grid phase |
| `analysis/avcontent.py` | `[AV-CONTENT]` lines (DEBUG builds): flash-beep content A/V on Manifold's own PTS (decoded), through the resampler, and at the glass (§18.13) |
| `analysis/probe_av.py` | flash/beep A/V of a whole recorded stream on its own timeline, windows at +180 / +1260 s and the trend over whole grid periods |

Criterion 12 is `mean_whole − zero` as written and `gridfree − zero` grid-corrected, where zero is the
mean of the two file controls (§18.3).
Start → end (from 2026-09-29, §6.3) is (B − A, grid-corrected) + `depth_term.py <log>`, ±10 ms.

## Probing a server without Manifold

To test whether a server's output carries an A/V drift, record its playback with no player in
the path, no re-encode, and the original timestamps (`-copyts`), while the sender streams the
fixture (§18.10). For Cloudflare SRT, with the passphrase in `$CF_SRT_PASS` and the playback URL in
`$CF_SRT_URL`:

```sh
node scripts/soak/obsws.mjs 4455 StartStream
ffmpeg -hide_banner -loglevel warning -i "${CF_SRT_URL}&passphrase=${CF_SRT_PASS}" -map 0:v -map 0:a \
  -c copy -copyts -t 1500 -f mpegts ~/Desktop/manifold-soak/cfsrt-probe.ts
node scripts/soak/obsws.mjs 4455 StopStream
```

- With `-copyts`, `-t` counts from timestamp 0, not from the stream's start. Add the start time
  to get the full length.
- The passphrase is visible in the process list while ffmpeg runs.
- Then `probe_ts.py` (the timestamps) and `probe_av.py` (the content), with the audible-events venv's
  python for the latter.

## Local SRT repro (unattended)

Serves a recorded `.ts` to Manifold as a local SRT listener and logs `[AV-LAG]` (§18.11), with no
operator:

```sh
zsh scripts/soak/repro/run.sh <label> <file.ts>                        # real time
READRATE=0.99997 zsh scripts/soak/repro/run.sh <label> <file.ts>       # content arriving 30 ppm slow
STALLS="60:200 120:400" zsh scripts/soak/repro/run.sh <label> <file.ts>  # sender SIGSTOPped 200 ms at +60 s, …
PES_PAYLOAD=default zsh scripts/soak/repro/run.sh <label> <file.ts>    # ffmpeg's own PES packing (several AAC frames)
LOSS="20:300 60:1000" zsh scripts/soak/repro/run.sh <label> <file.ts>  # every packet dropped both ways for 300 ms at +20 s, … (lossrelay.py)
zsh scripts/soak/repro/restamp.sh <in.ts> <out.ts>                     # video onto the exact frame grid
python3 scripts/soak/analysis/avlag.py ~/Desktop/manifold-soak/repro/<label>.manifold.log
```

- **Needs a DEBUG (Profile) build:** the `MANIFOLD_SRT_DEBUG_URL` override and `[AV-LAG]` are
  `#if DEBUG`. `MANIFOLD_APP` selects it.
- **Needs UI scripting (Accessibility) for the process running it.** It denies the unsigned
  build's licence prompt, opens a window if the launch restored none, and presses ⌃⌥D.
- **Serves with `-pes_payload_size 0` by default:** one AAC frame per PES, but only for frames over
  170 bytes. ffmpeg groups smaller ones (digital silence) regardless, so a replayed file whose audio
  has digital silence needs a noise floor (§18.13, §18.15). Builds before the multi-frame fix
  (§18.15) decode only the first frame of each PES.
- **Do not touch Manifold while it runs.** The script quits it at the end. A forced quit can make
  the next launch restore with no window, which the script handles.

## Replay

```sh
zsh scripts/soak/replay/build.sh [revision]   # before-fit from git (default 61d6f28)
cd "$SOAK_OUT" && python3 <repo>/scripts/soak/analysis/extract.py ~/Desktop/<log>.log <name>
replay-bin/replay-before <name>; replay-bin/replay-after <name>
replay-bin/replay-closed <name> [logonly]
replay-bin/replay-closed synth <label> <media ppm> <depth noise ms> <seconds> [logonly]
replay-bin/replay-level <name> [logonly]      # the level hold (§18.20): start → +26, worst, end
replay-bin/replay-level synth <label> <media ppm> <depth noise ms> <seconds> [logonly]
replay-bin/replay-level sweep <name>          # §18.9's forced-engagement sweep, one per minute
[LOCK_MODE=integrate|gated|anchored|stepfree] replay-bin/replay-offset-lock <name> [refStart refEnd]
                                              # the fit's applied offset against the offset lock (§18.22)
```

- **Open loop** (`replay-before`, `replay-after`): the fit alone, fed the logged pairs; x is log time.
- **Closed loop** (`replay-closed`): fit, cross-check and depth-slope fallback. At each logged window
  the depth the new line would have produced is rebuilt from the invariant
  `depth_new = offset_new − (offset_old − depth_old)` and fed back.
  - Lip-sync walk ∝ depth change.
  - `synth` extends a flat-SR session with a stated media slope, for sessions too short to replay.
