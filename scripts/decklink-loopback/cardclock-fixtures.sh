#!/bin/zsh
# Marked fixtures WITH sound for the card-clock runs (docs/CARD_CLOCK_FINDINGS.md): the linkpace marker band (16-bit picture number,
# rows 0–63), ProRes 422 Proxy, 48 kHz 24-bit PCM stereo tone at −30 dBFS, Rec.709 tags. The picture number wraps at 65536.
#   cardclock-fixtures.sh [seconds rate name]   one fixture; with no arguments, the full set into build/cardclock/
set -eu
HERE=${0:A:h}; REPO=${HERE:h:h}; OUT=$REPO/build/cardclock; mkdir -p $OUT
band() {   # the same picture as linkpace.sh band(), to 4:2:2 10-bit
  local w=${1%x*} k="floor(X/$(( ${1%x*} / 20 )))"
  print -r -- "testsrc2=s=${1}:r=${2}:d=${3},drawtext=fontfile=/System/Library/Fonts/Menlo.ttc:text='%{n}':fontsize=200:fontcolor=white:box=1:boxcolor=black:x=160:y=160,format=yuv420p[bg];color=c=black:s=${w}x64:r=${2}:d=${3},format=yuv420p,geq=lum='16+219*if(lt($k\,16)\,bitand(floor(N/pow(2\,$k))\,1)\,eq(mod($k\,2)\,0))':cb=128:cr=128[band];[bg][band]overlay=0:0:shortest=1,format=yuv422p10le"
}
make() {   # seconds rate name
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$(band 1920x1080 $2 $1)" -f lavfi -i "sine=f=1000:r=48000:d=$1" \
    -filter:a "volume=0.0316,pan=stereo|c0=c0|c1=c0" -c:v prores_videotoolbox -profile:v proxy \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a pcm_s24le -t $1 $OUT/$3.mov
}
if (( $# == 3 )); then make $1 $2 $3; exit; fi
make 720 60000/1001 cc-5994-720s
make 720 24000/1001 cc-2398-720s
make 2000 60000/1001 cc-5994-2000s
for n in cc-5994-720s cc-2398-720s; do ffmpeg -hide_banner -loglevel error -y -i $OUT/$n.mov -map 0:v -c copy $OUT/$n-noaudio.mov; done
ls -l $OUT
