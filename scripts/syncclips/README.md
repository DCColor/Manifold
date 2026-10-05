# Manifold sync clips

The free A/V sync clips of `docs/AUDIO_RESAMPLER_DESIGN.md` §19.3, results in §19.9: one clip per
frame rate, made by ffmpeg from committed recipes. No third-party media and no tools beyond ffmpeg.

| file | what it is |
|---|---|
| `recipes.tsv` | the recipes: one row per clip (label, exact rate, code unit) |
| `generate.sh` | builds every clip (or the labels named) into `build/syncclips/` (gitignored) |
| `verify.py` | reads every clip back: ffprobe tags, exact flash and beep times, the coded gates, the exact decoded length, c12.py; `--loop N` adds the loop test |
| `pairing_check.py` | the coded pattern's pairing, offline, on each clip's measured timeline (stdlib only) |
| `obs-scene-collection.json` | an OBS scene collection TEMPLATE: one scene per rate, the bundled clip on loop |

## Regenerate and check

```sh
zsh scripts/syncclips/generate.sh                    # all seven rates, ~1 min on an M-series Mac
zsh scripts/syncclips/generate.sh 23.976 59.94       # or some
SYNCCLIPS_FORMATS=h264 zsh scripts/syncclips/generate.sh  # the bundled clips only, ~6 s
FFPROBE=/path/to/ffprobe  <python-with-numpy> scripts/syncclips/verify.py --json /tmp/syncclips.json
FFPROBE=… <python-with-numpy> scripts/syncclips/verify.py build/syncclips/*-h264.mov --loop 20   # + the loop test
python3 scripts/syncclips/pairing_check.py /tmp/syncclips.json
```

- `verify.py` needs numpy (as `scripts/soak/analysis/c12.py` does). On this Mac that is the
  audible-events venv's python (`~/Desktop/manifold-audible-events/venv/bin/python`). Nothing is
  installed for it.
- `FFPROBE` defaults to `ffprobe` on PATH.
- `pairing_check.py` uses the MEDIAN score. The app's matcher uses the MEAN score (§19.9 Decisions 5);
  its port of these four checks is `swift test` (`SyncCalibrationTests/PairingCheckTests`), §19.10.

## In the app (calibration mode, `AUDIO_RESAMPLER_DESIGN.md` §19.10)

- **Bundled:** every build copies `build/syncclips/manifold-sync-<label>p-h264.mov` (labels from
  `recipes.tsv`) into `Contents/Resources/SyncClips` (project.yml, "Bundle sync clips"). Absent here,
  a dev build has none and says "Sync clips aren't included in this build".
- **Release:** `scripts/release-mac.sh` regenerates the bundled set (step 3b), fails if any clip does
  not decode to exactly its recipe's frames and samples with PCM audio (the loop gate), and fails if
  any clip is missing from the exported app or differs from what it generated (step 6c).
- **Download:** `…/manifold-sync-clips-v1.zip` (`SyncClipLibrary.downloadURL`). A change to the
  pattern — the code, the unit, the tone, the flash — is a NEW v2 zip and a new constant; v1 is never
  replaced. Keep `SyncClips` (Packages/ManifoldCore/Sources/SyncCalibration) in step with
  `recipes.tsv`.

## The pattern

- **Picture:** black, with a burned-in label (rate, code, frame counter). On each event frame, one
  full-white frame.
- **Sound:** a 1 kHz tone at −20 dBFS, one frame long, starting at phase 0 on that frame's exact
  boundary, with 5 ms raised-cosine edges. Under it, a −60 dBFS RMS noise floor.
- **The code:** the intervals between events cycle through 23 / 29 / 31 / 37 steps (one step = one
  frame; two at 50 and 59.94, see `recipes.tsv`), so a pairing that is off by one interval cannot fit.
  An offset is unambiguous within ±½ cycle (±2.0–2.5 s).
- **Two kinds of clip** (`AUDIO_RESAMPLER_DESIGN.md` §19.11). Both 1920×1080, Rec.709 tagged (bt709
  primaries, transfer and matrix; limited range), 48 kHz stereo.
  - **The bundled clip, `manifold-sync-<label>p-h264.mov`:** H.264 High 4:2:0 (no B-frames) + PCM
    16-bit, `cycles` whole code cycles (`recipes.tsv`: 4 → 16–20 s, 16 events). **It loops
    sample-exactly:** whole code cycles are whole frames AND whole samples at every rate, the audio is
    cut to exactly that many samples, and PCM has no codec padding for a player to trim. The code runs
    on unbroken across the seam. ~3.4–4.2 MB a clip, 27 MB the set. **This is the one to loop in an
    encoder.**
  - **The master, `manifold-sync-<label>p.mov`:** ProRes 422 (10-bit 4:2:2, PCM 24-bit), 60 s (60.06 s
    at the 1001 rates). A separate download. Its audio is exact too, but at 25 and 50 a 60 s master
    is 12.5 code cycles, so its loop seam breaks the code there.
  - **No `.mp4`.** The AAC MP4s (until 2026-10-05) gained one AAC pad of audio per loop in OBS
    (+14.667 ms at 23.976 / 29.97 / 59.94, +10.667 ms otherwise): OBS's Media Source ignores the edit
    list's end trim.

## The OBS scene collection

The template's media paths are placeholders. Make a filled COPY, then import the copy in OBS
(Scene Collection ▸ Import):

```sh
sed "s#__SYNCCLIPS_DIR__#$PWD/build/syncclips#g" scripts/syncclips/obs-scene-collection.json > ~/Desktop/manifold-sync-clips.obs.json
```

Set OBS's video frame rate to the clip's rate before streaming it.
