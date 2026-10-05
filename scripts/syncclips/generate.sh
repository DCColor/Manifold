#!/bin/zsh
# Manifold sync clips (AUDIO_RESAMPLER_DESIGN.md §19.3, §19.9): one clip per row of recipes.tsv, from
# ffmpeg's own sources (lavfi `color`, `drawbox`, `drawtext`, `aevalsrc`). No media goes in.
#
#   zsh scripts/syncclips/generate.sh [label ...]     # all rows, or the labels named (e.g. 23.976 59.94)
#   SYNCCLIPS_FORMATS=h264 zsh scripts/syncclips/generate.sh  # the bundled clips only (what the app
#                                                            # bundles; scripts/release-mac.sh runs this)
#
# Output (gitignored):
#   build/syncclips/manifold-sync-<label>p.mov       THE MASTER: ProRes 422, 10-bit 4:2:2, PCM 24-bit,
#                                                    `master_cycles` whole code cycles, ≥ 60 s (a separate download)
#   build/syncclips/manifold-sync-<label>p-h264.mov  THE BUNDLED CLIP: H.264 High 4:2:0 (no B-frames),
#                                                    PCM 16-bit, `cycles` whole code cycles (recipes.tsv)
# Both 1920×1080, Rec.709 tagged (primaries, transfer, matrix; limited range), 48 kHz stereo.
#
# THE BUNDLED CLIP LOOPS SAMPLE-EXACTLY (AUDIO_RESAMPLER_DESIGN.md §19.11). Its audio is PCM, so the
# decoded audio is exactly the samples written: no AAC priming or last-frame padding for a player to
# trim (an ffmpeg-based player such as OBS's Media Source ignores an edit list's END trim, so an AAC
# track ran one padded frame long — +10.667 / +14.667 ms of A/V drift per loop). Its length is whole
# code cycles, which is whole frames AND whole samples at every rate, and the audio is cut to that
# exact sample count (`atrim=end_sample`), so audio and video end together and the code continues
# across the seam. No B-frames: no composition offset, so no edit list shifts the video either.
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
# A master is master_cycles × 120 × unit frames: 60.0 / 60.06 s, 62.4 s at 25 and 50. A bundled clip is
# cycles × 120 × unit frames: 16–20 s at cycles = 4. Both are whole frames AND whole samples, and both
# loop with the code unbroken across the seam.
set -eu
HERE=${0:A:h}; REPO=${HERE:h:h}
OUT=${SYNCCLIPS_OUT:-$REPO/build/syncclips}; mkdir -p $OUT
FONT=${SYNCCLIPS_FONT:-/System/Library/Fonts/Menlo.ttc}
[[ -f $FONT ]] || { echo "no font at $FONT (set SYNCCLIPS_FONT)"; exit 2; }
want=("$@")
formats=(${=SYNCCLIPS_FORMATS:-mov h264})
for f in $formats; do [[ $f == mov || $f == h264 ]] || { echo "SYNCCLIPS_FORMATS: unknown format '$f' (mov, h264)"; exit 2; }; done
while IFS=$'\t' read -r label rate unit cycles master_cycles; do
  [[ -z $label || $label == \#* ]] && continue
  (( ${#want} )) && [[ ${want[(Ie)$label]} -eq 0 ]] && continue
  num=${rate%/*}; den=${rate#*/}
  F="($num/$den)"
  nominal=$(( (num + den / 2) / den ))           # round(rate): 24, 25, 30, 50, 60
  frames=$(( master_cycles * 120 * unit ))          # the master: whole code cycles, ≥ 60 s (recipes.tsv)
  (( frames * 48000 * den % num == 0 )) || { echo "${label}p: master $frames frames is not a whole number of samples"; exit 2; }
  dur=$(perl -e "printf '%.6f', $frames*$den/$num")
  # The bundled clip: whole code cycles, whole frames, whole samples (checked, not assumed).
  lframes=$(( cycles * 120 * unit ))
  (( lframes * 48000 * den % num == 0 )) || { echo "${label}p: $lframes frames is not a whole number of samples"; exit 2; }
  lsamples=$(( lframes * 48000 * den / num ))
  ldur=$(perl -e "printf '%.6f', $lframes*$den/$num")
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
  echo "── ${label}p: $rate, master $frames frames ($dur s), bundled $lframes frames / $lsamples samples ($ldur s), first event frame $F0, code ×$unit"
  if (( ${formats[(Ie)mov]} )); then
  ffmpeg -nostdin -hide_banner -loglevel error -y -filter_complex "${vchain}[v];aevalsrc=exprs='${aexpr}':s=48000:c=stereo:d=${dur}[a]" \
    -map '[v]' -map '[a]' -frames:v $frames \
    -c:v prores_ks -profile:v 2 -vendor apl0 -pix_fmt yuv422p10le $tags \
    -c:a pcm_s24le -movflags +write_colr -metadata comment="Manifold sync clip ${label}p (scripts/syncclips)" $base.mov
  fi
  if (( ${formats[(Ie)h264]} )); then
  # aevalsrc runs 0.1 s long and atrim cuts it to the exact sample count (d is a decimal in seconds).
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -filter_complex "${vchain}[v];aevalsrc=exprs='${aexpr}':s=48000:c=stereo:d=$(perl -e "printf '%.6f', $ldur+0.1"),atrim=end_sample=${lsamples}[a]" \
    -map '[v]' -map '[a]' -frames:v $lframes \
    -c:v libx264 -preset slow -crf 16 -profile:v high -bf 0 -pix_fmt yuv420p -g $(( 2 * nominal )) $tags \
    -c:a pcm_s16le -movflags +faststart+write_colr \
    -metadata comment="Manifold sync clip ${label}p, loops sample-exactly (scripts/syncclips)" $base-h264.mov
  fi
done < $HERE/recipes.tsv
ls -l $OUT
