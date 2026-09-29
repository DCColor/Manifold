#!/bin/zsh
# Mutes and dropouts in a soak's 20-min noise segment (criterion 1), via the device-output tracker.
#   zsh scripts/soak/analysis/mutes.sh <audio-hijack.wav> [start-seconds]
# Needs $AUDIBLE_EVENTS_DIR (default ~/Desktop/manifold-audible-events): reference_track.py, its
# venv, and ref-1200s.wav. Writes the cut, events JSON and track into $SOAK_OUT.
# Hits within ~1 s of either end of the segment are its edges, not mutes.
set -eu
A=${0:A:h}
W=${1:?capture.wav}
AE="${AUDIBLE_EVENTS_DIR:-$HOME/Desktop/manifold-audible-events}"
OUT="${SOAK_OUT:-$HOME/Desktop/manifold-soak}"; mkdir -p "$OUT"
PY="$AE/venv/bin/python"
START=${2:-$("$PY" "$A/noise_start.py" "$W")}
B=${W:t:r}
echo "noise segment starts at ${START} s in $W"
ffmpeg -hide_banner -loglevel error -y -ss $((START - 1)) -t 1202 -i "$W" -ac 1 -c:a pcm_f32le "$OUT/$B-noise.wav"
cd "$AE" && "$PY" reference_track.py --ref ref-1200s.wav --capture "$OUT/$B-noise.wav" --search 24000 \
  --json "$OUT/$B-events.json" --dump-track "$OUT/$B-track.txt" 2>&1 | grep -E "Hz|: |mute|dropout|splice|NO EVENTS"
