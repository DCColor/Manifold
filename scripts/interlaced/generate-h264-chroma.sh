#!/bin/bash
# 8-bit H.264 chroma (docs/BUGS.md, *8-bit H.264 files lose vertical chroma detail in the decode*): the 8-bit HEVC fixture
# the repo did not have → build/h264-chroma/fixtures/ (gitignored). I3's sharp picture (i3field.py, yuv420p), progressive,
# HEVC Main 8-bit, lossless, two seconds at 29.97. Usage: scripts/interlaced/generate-h264-chroma.sh  (ffmpeg on PATH)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../../build/h264-chroma/fixtures"
mkdir -p "$OUT"
cd "$OUT"
python3 -I "$HERE/i3field.py" yuv420p sharp-yuv420p.raw
ffmpeg -hide_banner -loglevel error -y -f rawvideo -video_size 1920x1080 -framerate 30000/1001 -stream_loop 59 \
    -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 -pix_fmt yuv420p -i sharp-yuv420p.raw \
    -c:v libx265 -x265-params lossless=1:log-level=error -tag:v hvc1 -pix_fmt yuv420p \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 probe-hevc-8bit-progressive.mov
ls -l "$OUT"
