#!/bin/bash
# Seamless chart streams for the unattended SRT / WHEP / HLS colour checks (COLOR_MANAGEMENT_FINDINGS.md §6.11).
#
#   bash docs/color-fixtures/make_stream_fixtures.sh [out_dir]      # default build/stream-fixtures (gitignored)
#
# Output, per colour variant V (919 = SPS VUI 9/1/9, undecl = colour description "unspecified", 666 = 6/6/6 with
# the picture encoded through the 601 matrix):
#   chart_V_aac.ts    H.264 + AAC-LC stereo, for the SRT listener and HLS
#   chart_V_opus.ts   the same H.264 + Opus stereo, for publishing into MediaMTX (WHEP)
#   hls_chart_V/      a 10-loop VOD HLS of chart_V_aac.ts
# plus patches.ppm / patches.json, the S0 6 × 3 chart (make_patches.py), scaled to 1280 × 720.
#
# ── WHY THESE LOOP WITHOUT A SEAM ───────────────────────────────────────────────────────────────────────
#
# S3's first stream fixtures (a 6 s still, a 1 kHz sine, `-stream_loop`) clicked every 6.04 s and started every
# SRT run with the rail episode (§6.11, *S3 — the audio heard during the runs*). Three causes, each removed here:
#   1. AAC priming and end padding. A 6 s AAC track decodes 37.3 ms long (1 024 priming + 768 padding samples),
#      so every loop carried an exact-zero run and cut the sine. Here the loop is L = 8.000 s = 384 000 samples
#      = 375 AAC frames = 400 Opus frames = 200 video frames = 8 000 sine cycles: whole frames on every stream
#      and periodic content. The audio is encoded 3 L long and only the MIDDLE L of packets is kept, so no
#      priming and no padding are in the file, and the packet before the seam carries the same content the
#      decoder would have had there. Each stream spans exactly L (checked below).
#   2. Coarse audio packing: ffmpeg's TS muxer packs ~8 AAC frames (170.67 ms) per PES, which makes a
#      re-sender's video bursty and the clock start late (§6.10, *The rail drain*). Here `-pes_payload_size 0`:
#      one AAC frame per PES (frames are > 170 bytes at 192 kb/s; smaller frames would still be grouped). The
#      SENDER must also pass `-pes_payload_size 0`, or its own muxer packs coarsely again.
#   3. No B-frames and a 25-frame GOP: 200 frames is 8 whole GOPs, so every loop starts on an IDR.
# HLS segments are muxed by the hls muxer with its default packing (it has no PES option); AVPlayer buffers
# whole segments, so packing does not reach the picture clock there.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
OUT=${1:-$REPO/build/stream-fixtures}; mkdir -p "$OUT"; cd "$OUT"
L_SAMPLES=384000; AAC_FRAMES=375; OPUS_FRAMES=400; VFRAMES=200
python3 "$HERE/make_patches.py" patches.ppm > /dev/null

# Audio: 1 kHz at −20 dBFS stereo, 3 L long, then the middle L of packets.
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i "aevalsrc=0.1*sin(2*PI*1000*t)|0.1*sin(2*PI*1000*t):s=48000:d=24" \
  -c:a aac -b:a 192k -f adts long.aac
python3 - "$AAC_FRAMES" <<'PY'
import sys
n = int(sys.argv[1]); d = open('long.aac', 'rb').read(); frames = []; i = 0
while i + 7 <= len(d):
    assert d[i] == 0xFF and d[i + 1] & 0xF6 == 0xF0, f"lost ADTS sync at {i}"
    ln = ((d[i + 3] & 3) << 11) | (d[i + 4] << 3) | (d[i + 5] >> 5); frames.append(d[i:i + ln]); i += ln
assert len(frames) >= 3 * n, f"only {len(frames)} AAC frames"
open('mid.aac', 'wb').write(b''.join(frames[n:2 * n]))
small = sum(1 for f in frames[n:2 * n] if len(f) <= 170)
print(f"AAC: kept frames {n}..{2 * n - 1} of {len(frames)}; {small} of them ≤ 170 bytes")
PY
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i "aevalsrc=0.1*sin(2*PI*1000*t)|0.1*sin(2*PI*1000*t):s=48000:d=24" \
  -c:a libopus -b:a 128k -frame_duration 20 long_opus.mka
ffmpeg -nostdin -hide_banner -loglevel error -y -i long_opus.mka -map 0:a -c:a copy \
  -bsf:a "noise=drop='lt(n\,$OPUS_FRAMES)+gte(n\,2*$OPUS_FRAMES)',setts=pts=PTS-STARTPTS:dts=DTS-STARTDTS" mid_opus.mka

video() {  # name scale-matrix x264-prim x264-trc x264-matrix
  ffmpeg -nostdin -hide_banner -loglevel error -y -loop 1 -framerate 25 -i patches.ppm -frames:v $VFRAMES \
    -vf "scale=1280:720,scale=out_color_matrix=$2:out_range=tv,format=yuv420p" \
    -c:v libx264 -profile:v high -crf 4 -preset veryfast -g 25 -keyint_min 25 -sc_threshold 0 -bf 0 \
    -x264-params "colorprim=$3:transfer=$4:colormatrix=$5" -f h264 "$1.h264"
}
mux() {  # video.h264 out-stem
  ffmpeg -nostdin -hide_banner -loglevel error -y -framerate 25 -i "$1" -i mid.aac -map 0:v -map 1:a -c copy \
    -pes_payload_size 0 -f mpegts "$2_aac.ts"
  # -copyts: the cut Opus track keeps its 7 ms start (pre-skip), and without it the muxer starts the video 7 ms
  # after the audio, so `-stream_loop` (which offsets each pass by end − start over all streams) leaves a 7 ms
  # gap at every seam. Measured; with it both start on the same PTS and three loops are gapless.
  ffmpeg -nostdin -hide_banner -loglevel error -y -framerate 25 -i "$1" -i mid_opus.mka -map 0:v -map 1:a -c copy \
    -copyts -pes_payload_size 0 -f mpegts "$2_opus.ts"
  mkdir -p "hls_$2"
  ffmpeg -nostdin -hide_banner -loglevel error -y -stream_loop 9 -i "$2_aac.ts" -c copy -f hls -hls_time 8 \
    -hls_list_size 0 -hls_playlist_type vod -hls_segment_filename "hls_$2/seg%03d.ts" "hls_$2/index.m3u8"
}
video v919 bt2020 bt2020 bt709 bt2020nc
video v666 smpte170m smpte170m smpte170m smpte170m
ffmpeg -nostdin -hide_banner -loglevel error -y -i v919.h264 -c copy \
  -bsf:v "h264_metadata=colour_primaries=2:transfer_characteristics=2:matrix_coefficients=2" -f h264 vundecl.h264
mux v919.h264 chart_919; mux vundecl.h264 chart_undecl; mux v666.h264 chart_666
rm -f long.aac long_opus.mka

# Check: each stream spans exactly L, AAC is one frame per PES, and a 3-loop copy has no seam gap or overlap.
for f in chart_919_aac chart_919_opus chart_666_aac; do
  ffmpeg -nostdin -hide_banner -loglevel error -y -stream_loop 2 -i "$f.ts" -c copy -pes_payload_size 0 -f mpegts "check_$f.ts"
done
python3 "$HERE/tspes.py" chart_919_aac.ts chart_919_opus.ts chart_666_aac.ts check_chart_919_aac.ts check_chart_919_opus.ts check_chart_666_aac.ts
rm -f check_*.ts
