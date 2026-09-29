#!/bin/zsh
# Restamp a received MPEG-TS's video PTS/DTS onto the exact frame grid (AUDIO_RESAMPLER_DESIGN.md
# §18.11): each timestamp snapped to the nearest origin + k·(90000·den/num) ticks, the origin fitted
# by probe_ts.py. Audio untouched; no re-encode. The muxer adds its constant start delay to both.
#   zsh scripts/soak/repro/restamp.sh <in.ts> <out.ts> [fps num/den, default 24000/1001]
set -eu
IN=$1; OUT=$2; FPS=${3:-24000/1001}
A=${0:A:h:h}/analysis
S=$(python3 -c "n,d=map(int,'$FPS'.split('/'));print(90000*d/n)")
O=$(python3 "$A/probe_ts.py" "$IN" "$FPS" | sed -nE 's/^video grid phase: origin ([0-9.]+).*/\1/p')
echo "step $S ticks, origin $O"
ffmpeg -hide_banner -loglevel error -y -copyts -i "$IN" -map 0:v -map 0:a -c copy \
  -bsf:v "setts=pts=round((PTS-$O)/$S)*$S+$O:dts=round((DTS-$O)/$S)*$S+$O" -f mpegts "$OUT"
python3 "$A/probe_ts.py" "$OUT" "$FPS"
