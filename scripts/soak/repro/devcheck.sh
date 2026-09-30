#!/bin/zsh
# The device check of the starvation hold (AUDIO_RESAMPLER_DESIGN.md §18.19): one local SRT session
# with induced stalls, recorded at the device by the rig's recorders. run.sh does the session; this
# adds the operator's cues (spoken), the single-instance watch, and the analysis commands.
#   zsh scripts/soak/repro/devcheck.sh <label> [file.ts]
# Environment: MANIFOLD_APP (a DEBUG build; default the §18.19 build), STALLS (default below; the
# first leaves 90 s for the operator), SOAK_OUT as for run.sh.
#
# ⚠️ Start Audio Hijack only when told to ("Connected"): started earlier, it can quit or relaunch
# Manifold (§6.1), and a relaunched copy has no debug SRT URL. This script stops the run if
# Manifold quits or a second copy appears.
set -u
LABEL=${1:?label}; FILE=${2:-$HOME/Desktop/manifold-soak/repro/ref-nob.ts}
REPO=${0:A:h:h:h:h}
D="${SOAK_OUT:-$HOME/Desktop/manifold-soak}/repro"; mkdir -p "$D"
export STALLS="${STALLS:-90:300 130:400 180:1000 240:300}"
export MANIFOLD_APP="${MANIFOLD_APP:-$REPO/.build-cc/recut4-Profile/Build/Products/Profile/Manifold.app}"
OUT="$D/$LABEL.devcheck.out"
stop() { say "$1"; echo "$(date +%H:%M:%S) STOPPED: $1" | tee -a "$OUT"
         pkill -f "repro/run.sh $LABEL" 2>/dev/null; pkill -f "ffmpeg -hide_banner.*srt://127.0.0.1:9000" 2>/dev/null
         exit 1; }

# ── Preflight: nothing left over from an earlier attempt, and a fresh label ──
[[ -x "$MANIFOLD_APP/Contents/MacOS/Manifold" ]] || { echo "build missing: $MANIFOLD_APP"; say "Build missing"; exit 2; }
[[ -e "$D/$LABEL.manifold.log" ]] && { echo "label $LABEL already used — pick another"; say "Label already used. Pick another."; exit 2; }
pgrep -fq "repro/run.sh" && { echo "a run.sh is still running — stop it first"; say "An earlier run is still going."; exit 2; }
pgrep -xq Manifold && { echo "Manifold is running — quit it first"; say "Quit Manifold first."; exit 2; }

python3 -c 'import time; print(time.time()-time.monotonic())' > "$D/$LABEL.offset"
zsh "$REPO/scripts/soak/repro/run.sh" "$LABEL" "$FILE" > "$OUT" 2>&1 &
RUN=$!
# ── Wait for a REAL connect; anything else is a failure, said as one ──
while ! grep -q "connected$" "$OUT" 2>/dev/null; do
  kill -0 $RUN 2>/dev/null || { cat "$OUT"; stop "Run ended before connecting. See the output."; }
  sleep 1
done
say "Connected. Re-pick Manifold in the recorder, start the OBS recording, then start Audio Hijack. First stall in ninety seconds."
# ── Watch Manifold for the whole session: exactly one copy, until the file ends ──
t0=$SECONDS; warned=0
while kill -0 $RUN 2>/dev/null; do
  n=$(pgrep -x Manifold | wc -l | tr -d ' ')
  grep -q "ffmpeg ended" "$OUT" && break
  [[ $n == 0 ]] && stop "Manifold quit during the session. The capture is void."
  [[ $n -gt 1 ]] && stop "Two Manifold processes. Audio Hijack launched a copy. The capture is void."
  if (( SECONDS - t0 >= 75 && ! warned )); then
    warned=1; say "One Manifold. Stall in fifteen seconds. Hands off."
    echo "$(date +%H:%M:%S) Manifold processes before the first stall: $n" >> "$OUT"
  fi
  sleep 1
done
wait $RUN
say "File ended. Stop Audio Hijack and the OBS recording."
cat "$OUT"
cat <<EOT

Analyse (the tracker's venv has numpy):
  ~/Desktop/manifold-audible-events/venv/bin/python $REPO/scripts/soak/analysis/devicecheck.py <audio-hijack.wav> $D/$LABEL.manifold.log
  ffmpeg -i <obs-recording.mov> -vn -ac 2 -c:a pcm_f32le $D/$LABEL.obs.wav
  ~/Desktop/manifold-audible-events/venv/bin/python $REPO/scripts/soak/analysis/devicecheck.py $D/$LABEL.obs.wav $D/$LABEL.manifold.log
EOT
