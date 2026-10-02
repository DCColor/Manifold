#!/bin/zsh
# Manifold sync clips (AUDIO_RESAMPLER_DESIGN.md §19.3, §19.9): one clip per row of recipes.tsv, from
# ffmpeg's own sources (lavfi `color`, `drawbox`, `drawtext`, `aevalsrc`). No media goes in.
#
#   zsh scripts/syncclips/generate.sh [label ...]     # all rows, or the labels named (e.g. 23.976 59.94)
#
# Output (gitignored): build/syncclips/manifold-sync-<label>p.mov  ProRes 422, 10-bit 4:2:2, PCM 24-bit
#                      build/syncclips/manifold-sync-<label>p.mp4  H.264 High 4:2:0, AAC-LC 256k
# Both 1920×1080, Rec.709 tagged (primaries, transfer, matrix; limited range), 48 kHz stereo.
#
# THE PATTERN, PER EVENT (event frame k):
#   picture  frame k is full-frame white (Y 235 / 940), every other frame black (16 / 64), with a
#            burned-in label: the rate and the frame counter.
#   sound    a 1 kHz tone at −20 dBFS peak, exactly one frame period long, starting at phase 0 ON
#            frame k's boundary, with 5 ms raised-cosine edges. Under everything, a −60 dBFS RMS
#            white-noise floor (digital silence packs AAC frames together and hides mutes, §18.15).
#   timing   computed from the exact boundary time k / rate, never rounded to a sample: at rates
#            whose boundaries are not samples (29.97, 59.94: k × 1601.6 / 800.8 samples) the tone is
#            the exact boundary-anchored waveform, sampled.
#   code     events at frame F0 + unit × {0, 23, 52, 83} + unit × 120 × c (intervals 23/29/31/37
#            steps): a pairing off by one interval cannot fit the sequence (§19.3).
# Each clip is 60 × round(rate) frames (60.06 s at the 1001 rates), which is a whole number of samples.
set -eu
HERE=${0:A:h}; REPO=${HERE:h:h}
OUT=${SYNCCLIPS_OUT:-$REPO/build/syncclips}; mkdir -p $OUT
FONT=${SYNCCLIPS_FONT:-/System/Library/Fonts/Menlo.ttc}
[[ -f $FONT ]] || { echo "no font at $FONT (set SYNCCLIPS_FONT)"; exit 2; }
want=("$@")
while IFS=$'\t' read -r label rate unit; do
  [[ -z $label || $label == \#* ]] && continue
  (( ${#want} )) && [[ ${want[(Ie)$label]} -eq 0 ]] && continue
  num=${rate%/*}; den=${rate#*/}
  F="($num/$den)"
  nominal=$(( (num + den / 2) / den ))           # round(rate): 24, 25, 30, 50, 60
  frames=$(( 60 * nominal ))
  dur=$(perl -e "printf '%.6f', $frames*$den/$num")
  F0=$nominal                                     # first event ≈ 1 s in
  C=$(( 120 * unit )); A1=$(( 23 * unit )); A2=$(( 52 * unit )); A3=$(( 83 * unit ))
  # Event test on a frame index x (video: n; audio: the frame the sample falls in).
  ev() { echo "gte($1-$F0,0)*(eq(mod($1-$F0,$C),0)+eq(mod($1-$F0,$C),$A1)+eq(mod($1-$F0,$C),$A2)+eq(mod($1-$F0,$C),$A3))"; }
  # Audio, per sample: 0 = frame index (1e-6 frame guards an exact boundary against float error),
  # 1 = seconds since that frame's boundary; the tone envelope; the noise floor (seeded per channel).
  tone="st(0,floor(t*$F+1e-6));st(1,t-ld(0)/$F);0.1*$(ev 'ld(0)')*if(lt(ld(1),0.005),0.5-0.5*cos(PI*ld(1)/0.005),if(gt(ld(1),1/$F-0.005),0.5-0.5*cos(PI*(1/$F-ld(1))/0.005),1))*sin(2*PI*1000*ld(1))"
  aexpr="$tone+0.0017320508*(2*random(4)-1)|$tone+0.0017320508*(2*random(5)-1)"
  text="Manifold sync clip   ${label}p   code 23-29-31-37 x${unit}   frame %{eif\\:n\\:d\\:6}"
  vchain="color=c=black:s=1920x1080:r=$rate,format=yuv420p,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='$(ev n)',drawtext=fontfile=${FONT}:text='$text':fontcolor=0x808080:fontsize=36:x=64:y=h-96,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"
  tags=(-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv)
  base=$OUT/manifold-sync-${label}p
  echo "── ${label}p: $rate, $frames frames ($dur s), first event frame $F0, code ×$unit"
  ffmpeg -nostdin -hide_banner -loglevel error -y -filter_complex "${vchain}[v];aevalsrc=exprs='${aexpr}':s=48000:c=stereo:d=${dur}[a]" \
    -map '[v]' -map '[a]' -frames:v $frames \
    -c:v prores_ks -profile:v 2 -vendor apl0 -pix_fmt yuv422p10le $tags \
    -c:a pcm_s24le -movflags +write_colr -metadata comment="Manifold sync clip ${label}p (scripts/syncclips)" $base.mov
  ffmpeg -nostdin -hide_banner -loglevel error -y -filter_complex "${vchain}[v];aevalsrc=exprs='${aexpr}':s=48000:c=stereo:d=${dur}[a]" \
    -map '[v]' -map '[a]' -frames:v $frames \
    -c:v libx264 -preset slow -crf 16 -profile:v high -pix_fmt yuv420p -g $(( 2 * nominal )) $tags \
    -c:a aac -b:a 256k -ar 48000 -movflags +faststart+write_colr \
    -metadata comment="Manifold sync clip ${label}p (scripts/syncclips)" $base.mp4
done < $HERE/recipes.tsv
ls -l $OUT
