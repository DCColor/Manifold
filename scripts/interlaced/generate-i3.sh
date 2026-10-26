#!/bin/bash
# Interlaced I3 fixtures (docs/INTERLACED_FINDINGS.md §12) → build/interlaced-fixtures/i3/ (gitignored).
# The sharp field-chroma picture from i3field.py, two seconds at 29.97 frames/s (1080i59.94), in each family:
#   H.264 MBAFF 4:2:0 TFF and BFF (.mov), MPEG-2 4:2:0 TFF (.mov; whether AVFoundation decodes it is recorded),
#   ProRes 422 HQ TFF (.mov), ProRes 4444 TFF (.mov), DNxHD 185x 4:2:2 TFF (.mxf).
# Usage: scripts/interlaced/generate-i3.sh   (ffmpeg 8.1.1 on PATH)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../../build/interlaced-fixtures/i3"
mkdir -p "$OUT"
cd "$OUT"
for f in yuv420p yuv422p10le yuv444p10le; do python3 -I "$HERE/i3field.py" $f field-$f.raw; done
# The raw input is tagged as what it is (BT.709, limited), so FFmpeg converts nothing on the way to the encoder.
RAW=(-f rawvideo -video_size 1920x1080 -framerate 30000/1001 -stream_loop 59 -color_range tv -color_primaries bt709
     -color_trc bt709 -colorspace bt709)
FF=(ffmpeg -hide_banner -loglevel error -y)
"${FF[@]}" "${RAW[@]}" -pix_fmt yuv420p -i field-yuv420p.raw -vf setfield=tff -c:v libx264 -preset slow -crf 4 \
    -flags +ildct+ilme -x264-params tff=1 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -field_order tt h264-sharp-1080i5994-tff.mov
"${FF[@]}" "${RAW[@]}" -pix_fmt yuv420p -i field-yuv420p.raw -vf setfield=bff -c:v libx264 -preset slow -crf 4 \
    -flags +ildct+ilme -x264-params bff=1 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -field_order bb h264-sharp-1080i5994-bff.mov
"${FF[@]}" "${RAW[@]}" -pix_fmt yuv420p -i field-yuv420p.raw -vf setfield=tff -c:v mpeg2video -q:v 1 -qmin 1 \
    -flags +ildct+ilme -top 1 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -field_order tt mpeg2-sharp-1080i5994-tff.mov
"${FF[@]}" "${RAW[@]}" -pix_fmt yuv422p10le -i field-yuv422p10le.raw -vf setfield=tff -c:v prores_ks -profile:v 3 \
    -flags +ildct -pix_fmt yuv422p10le -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    prores422-sharp-1080i5994-tff.mov
"${FF[@]}" "${RAW[@]}" -pix_fmt yuv444p10le -i field-yuv444p10le.raw -vf setfield=tff -c:v prores_ks -profile:v 4 \
    -flags +ildct -pix_fmt yuv444p10le -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    prores4444-sharp-1080i5994-tff.mov
"${FF[@]}" "${RAW[@]}" -pix_fmt yuv422p10le -i field-yuv422p10le.raw -vf setfield=tff -c:v dnxhd -b:v 185M \
    -flags +ildct -pix_fmt yuv422p10le -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    dnxhd-sharp-1080i5994-tff.mxf
ls -l "$OUT"
