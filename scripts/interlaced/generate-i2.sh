#!/bin/zsh
# Interlaced I2 fixtures (docs/INTERLACED_FINDINGS.md §11): pictures whose FIELDS carry a machine-readable picture
# number, so a capture of the SDI or HDMI input can say which source field each received field is. Every picture comes
# from ffmpeg's own `testsrc2`; no media goes in, none comes out into the repo.
#
#   zsh scripts/interlaced/generate-i2.sh
#
# Output (gitignored): build/interlaced-fixtures/i2/   (INTERLACED_FIXTURES_OUT overrides the parent)
#
# THE MARKER. §6's recipe — the source at the FIELD rate, then `interlace=scan=tff|bff:lowpass=0`, which weaves two
# consecutive progressive pictures into one frame — with a band over rows 0–63 of every progressive picture: 20 blocks
# across the width, blocks 0–15 the picture number N in binary (LSB first, luma 235 for 1, 16 for 0), blocks 16–19 the
# check pattern 1 0 1 0. After the weave the even rows (the top field) carry one picture's number and the odd rows the
# next one's (TFF: top N, bottom N+1; BFF: bottom N, top N+1). `build/decklink-loopback/fieldtool marks` reads it.
# The blocks are a twentieth of the PICTURE width, so the 1440 file's band reads the same after a desqueeze to 1920.
#
#   mark-prores-1080i5994-tff.mov / -bff.mov   ProRes 422 HQ, -flags +ildct, 10 s (600 fields)
#   mark-prores-1080i50-tff.mov                ProRes 422 HQ, 10 s (500 fields)
#   mark-prores-1080i60-tff.mov                ProRes 422 HQ at 60 fields (30 frames), 10 s
#   mark-dnxhd-1080i5994-tff.mxf               DNxHD 220x, 10 s, the libav path
#   mark-h264-mbaff-1080i5994-tff.mov          x264 MBAFF, 10 s
#   mark-prores-1440x1080i5994-tff.mov         1440×1080, pixel aspect 4:3 (`pasp` 4:3), 10 s
#   prores-1080i-5994frames-tff.mov            decision 3's case: the interlaced TFF weave (woven frames at 29.97)
#                                              with every frame shown twice, so the file states 59.94 frames a second
#                                              while every frame is interlaced. 4 s.
#
# Measured with ffmpeg 8.1.1 (the vendored version; FFmpeg is not bundled as a program, so this is the Homebrew build).
set -eu
HERE=${0:A:h}; REPO=${HERE:h:h}
OUT=${INTERLACED_FIXTURES_OUT:-$REPO/build/interlaced-fixtures}/i2; mkdir -p $OUT
cd $OUT
q=(-hide_banner -loglevel error -y)
FONT=/System/Library/Fonts/Menlo.ttc
D=10

# $1 rate, $2 tff|bff, $3 width (default 1920), $4 seconds. The progressive pictures at the field rate, counter and
# marker band in, then the weave.
src() {
  local r=$1 scan=$2 w=${3:-1920} d=${4:-$D} b=$(( ${3:-1920} / 20 ))
  local k="floor(X/$b)"
  print -r -- "testsrc2=s=${w}x1080:r=${r}:d=${d},drawtext=fontfile=${FONT}:text='%{n}':fontsize=300:fontcolor=white:box=1:boxcolor=black:x=160:y=160,format=yuv444p[bg];color=c=black:s=${w}x64:r=${r}:d=${d},format=yuv444p,geq=lum='16+219*if(lt($k\,16)\,bitand(floor(N/pow(2\,$k))\,1)\,eq(mod($k\,2)\,0))':cb=128:cr=128[band];[bg][band]overlay=0:0:shortest=1,interlace=scan=${scan}:lowpass=0,setfield=${scan}"
}
prores=(-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -flags +ildct)

ffmpeg $q -f lavfi -i "$(src 60000/1001 tff)" $prores mark-prores-1080i5994-tff.mov
ffmpeg $q -f lavfi -i "$(src 60000/1001 bff)" $prores mark-prores-1080i5994-bff.mov
ffmpeg $q -f lavfi -i "$(src 50 tff)"         $prores mark-prores-1080i50-tff.mov
ffmpeg $q -f lavfi -i "$(src 60 tff)"         $prores mark-prores-1080i60-tff.mov
ffmpeg $q -f lavfi -i "$(src 60000/1001 tff)" -c:v dnxhd -b:v 220M -pix_fmt yuv422p10le -flags +ildct -f mxf mark-dnxhd-1080i5994-tff.mxf
ffmpeg $q -f lavfi -i "$(src 60000/1001 tff)" -c:v libx264 -profile:v high -pix_fmt yuv420p -flags +ildct+ilme -g 30 \
       -x264-params tff=1 -crf 12 mark-h264-mbaff-1080i5994-tff.mov
ffmpeg $q -f lavfi -i "$(src 60000/1001 tff 1440),setsar=4/3" $prores mark-prores-1440x1080i5994-tff.mov
# Decision 3: woven 29.97 frames, each repeated, in a 59.94 file.
ffmpeg $q -f lavfi -i "$(src 60000/1001 tff 1920 4),fps=60000/1001" $prores -r 60000/1001 prores-1080i-5994frames-tff.mov

ls -l $OUT
