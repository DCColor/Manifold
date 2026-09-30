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
| `obsws.mjs` | minimal obs-websocket client; also a CLI: `node obsws.mjs 4455 GetStreamStatus` |
| `control2.mjs` | a later control 2: waits for the fixture to play, records 300 s, appends to the timeline |
| `watcher.py` | read-only: Manifold %CPU every 10 s (`cpu.csv`), volume of each new capture, a warning on more than one Manifold PID |
| `srfit-live.sh` | the SR fit's state in a running or finished log: events, window, cross-check, depth, END |
| `mediamtx-soak.yml` | the plain MediaMTX config plus RTSP (127.0.0.1:8554, for the sender probe) and HLS |

**What the orchestrator does** (`soak.mjs`):
- **Setup:** switches and verifies the sender profile.
- **Control 1:** a preflight until the recorder hears Manifold, then a 300 s file control.
- **Live:** starts the stream, waits for the connect, then:
  - capture A at +3 min;
  - the noise segment +5:30 → +25:30;
  - capture B at +26 min (or at +4 h 30 on `whep-cf-long`, which then stops the stream and checks
    that Manifold's media-stall watchdog ended the session).
- **Control 2.**

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
```

- **Open loop** (`replay-before`, `replay-after`): the fit alone, fed the logged pairs; x is log time.
- **Closed loop** (`replay-closed`): fit, cross-check and depth-slope fallback. At each logged window
  the depth the new line would have produced is rebuilt from the invariant
  `depth_new = offset_new − (offset_old − depth_old)` and fed back.
  - Lip-sync walk ∝ depth change.
  - `synth` extends a flat-SR session with a stated media slope, for sessions too short to replay.
