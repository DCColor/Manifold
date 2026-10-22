#!/bin/zsh
# SDI scaling fixtures (docs/BUGS.md, "DeckLink: any source raster that matches no output mode carries BLACK"):
# one file per row of recipes.tsv, from ffmpeg's own sources (lavfi `color`, `geq`, `drawtext`, `aevalsrc`).
# No media goes in.
#
#   zsh scripts/sdi-scaling/make_fixtures.sh [label ...]     # all rows, or the labels named
#
# Output (gitignored): build/sdi-scaling/sdi-<label>.mov
#   ProRes 422 HQ (apch), 10-bit 4:2:2, square pixels (SAR 1:1), tagged Rec.709 1-1-1, limited range;
#   at least 10 s, whole frames and whole samples (10.01 s at 23.976 and 59.94), the audio cut to the same length;
#   PCM 24-bit little-endian (in24), 48 kHz stereo: L = 1 kHz, R = 2 kHz, −20 dBFS.
#
# THE PICTURE, IDENTICAL IN LAYOUT ON EVERY RASTER (the README says what each element checks):
#   background  Y 48, a dark grey, so the picture's own edge is distinguishable from black bars
#   border      a 1-px white (Y 235) line on all four edges: the outermost row and column
#   circle      a 3-px white ring, radius 0.35 × the shorter side, centred on the raster's TRUE centre
#               ((W−1)/2, (H−1)/2): a stretched picture draws an ellipse
#   crosshair   2-px lines through that centre (every raster is even, so the centre falls between two rows
#               and two columns, and the 2-px line straddles it exactly), arms 0.05 × the shorter side
#   detail      two rows of 64 × 64 patches, bottom left and bottom right, 24 px in from the border:
#               1-px vertical line pairs, 1-px horizontal, 2-px vertical, 2-px horizontal, 1-px checkerboard
#   label       two lines, top centre: raster + rate + frame counter, then format and tags; each line sized to
#               fit 90 % of the width
# All geometric values are EXACT code values (white 235, black 16, background 48; 940 / 64 / 192 at 10 bits),
# written by one `geq` expression on one frame that is then looped — so every frame is the same picture,
# the label's frame counter aside.
set -eu
HERE=${0:A:h}; REPO=${HERE:h:h}
OUT=${SDISCALING_OUT:-$REPO/build/sdi-scaling}; mkdir -p $OUT
FONT=${SDISCALING_FONT:-/System/Library/Fonts/Menlo.ttc}
[[ -f $FONT ]] || { echo "no font at $FONT (set SDISCALING_FONT)"; exit 2; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not on PATH"; exit 2; }
want=("$@")
SECONDS_LONG=10

# One 64 × 64 patch at (x0, y0): pattern expression `pat` where it is 1 → white, 0 → black.
patch() { echo "between(X,$1,$1+63)*between(Y,$2,$2+63)*(1+$3)"; }   # 0 outside; 1 (black) or 2 (white) inside

while IFS=$'\t' read -r label w h rate why; do
  [[ -z $label || $label == \#* ]] && continue
  (( ${#want} )) && [[ ${want[(Ie)$label]} -eq 0 ]] && continue
  (( w % 2 == 0 && h % 2 == 0 )) || { echo "$label: odd raster — the 2-px centre lines assume an even one"; exit 2; }
  num=${rate%/*}; den=${rate#*/}
  # The shortest length of at least 10 s that is whole frames AND whole samples (59.94: 600 frames, not 599).
  frames=$(( (SECONDS_LONG * num + den - 1) / den ))
  while (( frames * 48000 * den % num != 0 )); do frames=$(( frames + 1 )); done
  samples=$(( frames * 48000 * den / num ))
  short=$(( w < h ? w : h ))
  R=$(perl -e "printf '%.3f', 0.35*$short")
  arm=$(( short / 20 ))
  # The detail rows: five patches each, 64 px + 16 px gap, 24 px in from the border, bottom left and right.
  y0=$(( h - 24 - 64 )); y1=$(( y0 - 16 - 64 ))
  pats=("mod(X,2)" "mod(Y,2)" "mod(floor(X/2),2)" "mod(floor(Y/2),2)" "mod(X+Y,2)")
  detail=""
  for i in 1 2 3 4 5; do
    xl=$(( 24 + (i - 1) * 80 )); xr=$(( w - 24 - 64 - (5 - i) * 80 ))
    detail="$detail+$(patch $xl $y0 ${pats[$i]})+$(patch $xr $y1 ${pats[$i]})"
  done
  cx="($w-1)/2"; cy="($h-1)/2"
  border="(eq(X,0)+eq(Y,0)+eq(X,W-1)+eq(Y,H-1))"
  cross="(lte(abs(Y-$cy),0.5)*lte(abs(X-$cx),$arm)+lte(abs(X-$cx),0.5)*lte(abs(Y-$cy),$arm))"
  ring="lte(abs(hypot(X-$cx,Y-$cy)-$R),1.5)"
  # Precedence: detail (0 none, 1 black, 2 white) wins inside its patches; then border, crosshair, ring; else grey.
  lum="st(0,0$detail);if(ld(0),if(eq(ld(0),2),235,16),if(gt($border+$cross+$ring,0),235,48))"
  # The label, two lines, each sized to fit 90 % of the width (Menlo's advance is 0.6 em) and never above
  # short/24: a single line ran off both sides of the narrow rasters and cut the raster name off.
  line1="$label   frame %{eif\\:n\\:d\\:4}"; len1=$(( ${#label} + 14 ))
  line2="ProRes 422 HQ   Rec.709 1-1-1 legal   SAR 1\\:1"; len2=44
  fit() { perl -e "my \$f = int(0.9*$w/($1*0.6)); my \$c = int($short/24); print \$f < \$c ? \$f : \$c"; }
  fs1=$(fit $len1); fs2=$(fit $len2)
  ty=$(( short / 32 ))                                  # the second line clears the circle on every raster
  vchain="color=c=black:s=${w}x${h}:r=$rate:d=1,format=yuv444p,geq=lum='$lum':cb=128:cr=128,trim=end_frame=1,loop=loop=$((frames - 1)):size=1:start=0,setpts=N/($rate)/TB,setsar=1,drawtext=fontfile=${FONT}:text='$line1':fontcolor=white:fontsize=$fs1:x=(w-tw)/2:y=$ty,drawtext=fontfile=${FONT}:text='$line2':fontcolor=white:fontsize=$fs2:x=(w-tw)/2:y=$(( ty + fs1 * 5 / 4 )),format=yuv422p10le,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"
  aexpr="0.1*sin(2*PI*1000*t)|0.1*sin(2*PI*2000*t)"
  dest=$OUT/sdi-$label.mov
  echo "── $label: ${w}×${h} @ $rate, $frames frames, $samples samples — $why"
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -filter_complex "${vchain}[v];aevalsrc=exprs='${aexpr}':s=48000:c=stereo:d=$(( SECONDS_LONG + 1 )),atrim=end_sample=${samples}[a]" \
    -map '[v]' -map '[a]' -frames:v $frames \
    -c:v prores_ks -profile:v 3 -vendor apl0 -pix_fmt yuv422p10le \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
    -c:a pcm_s24le -movflags +write_colr \
    -metadata comment="Manifold SDI scaling fixture $label (scripts/sdi-scaling)" $dest
done < $HERE/recipes.tsv
ls -l $OUT
