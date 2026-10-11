#!/bin/zsh
# Manifold chroma fixtures (COLOR_MANAGEMENT_FINDINGS.md §6.10, Stage 3b — "4:2:2 end to end"): every
# picture comes from ffmpeg's own sources (lavfi `nullsrc` + `geq`, `yuvtestsrc`, `testsrc2`). No media
# goes in, and none comes out into the repo.
#
#   zsh scripts/chroma/generate.sh [group ...]     # all groups, or the ones named: 422 444 420 4k ndi
#
# Output (gitignored): build/chroma-fixtures/   (CHROMA_FIXTURES_OUT overrides)
#
# THE TWO PATTERNS. Both have flat luma (Y 512) and exact chroma, so every chroma sample is a known value:
#   lines-422  Cb/Cr alternate by ROW: even rows 724/300, odd rows 300/724. Constant along each row, so a
#              4:2:2 source holds it exactly and only a vertical halving can lose it. Halved by averaging
#              (H.264, HEVC, libav's sws) every row reads 512/512, grey; halved by point-sampling (Apple's
#              ProRes decoder) every row reads the even row's colour.
#   checker-444 Cb/Cr alternate by (x + y): a one-pixel colour checker. Only 4:4:4 holds it; a horizontal
#              OR vertical halving loses it. On the DeckLink v210 output (4:2:2) the correct result is the
#              D3 halfband's DC, 512 ± 2: a point-sampled reduction would put 724/300 on the wire (alias).
#
# Lossless where the codec allows (x265 lossless=1, x264 -qp 0/1), so a decoder's output can be compared
# with the source codes. ProRes and DNx are lossy: libav decodes these fixtures to the exact source codes,
# but ⚠️ APPLE'S DNx PLUG-IN DOES NOT decode ffmpeg-made DNxHR HQX .mov correctly (774/250 where libav
# gives 724/300; measured 2026-10-10, docs/BUGS.md). Manifold sends DNx 4:2:2 to libav, so this is a
# fixture caveat: do not judge the plug-in with ffmpeg-made DNx files.
#
# Measured with ffmpeg 8.1.1 (the vendored version). Results: COLOR_MANAGEMENT_FINDINGS.md §6.10,
# *Stage 3b — 4:2:2 (and 4:4:4) end to end: audit*.
set -eu
HERE=${0:A:h}; REPO=${HERE:h:h}
OUT=${CHROMA_FIXTURES_OUT:-$REPO/build/chroma-fixtures}; mkdir -p $OUT
cd $OUT
groups=($@); (( $#groups )) || groups=(422 444 420 4k ndi)
q=(-hide_banner -loglevel error -y)

PAT_LINES="nullsrc=s=1920x1080:r=25:d=10,format=yuv422p10le,geq=lum=512:cb='if(mod(Y\,2)\,300\,724)':cr='if(mod(Y\,2)\,724\,300)'"
PAT_CHECK="nullsrc=s=1920x1080:r=25:d=10,format=yuv444p10le,geq=lum=512:cb='if(mod(X+Y\,2)\,300\,724)':cr='if(mod(X+Y\,2)\,724\,300)'"
PAT_STILL420="yuvtestsrc=s=1920x1080:r=25:d=10"

for g in $groups; do
  case $g in
  422)
    ffmpeg $q -f lavfi -i "$PAT_LINES" -frames:v 1 -f rawvideo -pix_fmt yuv422p10le lines-422.yuv
    ffmpeg $q -f lavfi -i "$PAT_LINES" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le lines-422-prores422hq.mov
    ffmpeg $q -f lavfi -i "$PAT_LINES" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -f mxf lines-422-prores422hq.mxf
    ffmpeg $q -f lavfi -i "$PAT_LINES" -c:v dnxhd -profile:v dnxhr_hqx -pix_fmt yuv422p10le lines-422-dnxhrhqx.mov
    ffmpeg $q -f lavfi -i "$PAT_LINES" -c:v dnxhd -profile:v dnxhr_hqx -pix_fmt yuv422p10le -f mxf lines-422-dnxhrhqx.mxf
    # XAVC-style: H.264 High 4:2:2 Intra 10 (every frame an IDR)
    ffmpeg $q -f lavfi -i "$PAT_LINES" -c:v libx264 -profile:v high422 -pix_fmt yuv422p10le -qp 1 -g 1 lines-422-h264-intra.mov
    ffmpeg $q -f lavfi -i "$PAT_LINES" -c:v libx264 -profile:v high422 -pix_fmt yuv422p10le -qp 1 lines-422-h264.ts
    ffmpeg $q -f lavfi -i "$PAT_LINES" -c:v libx265 -pix_fmt yuv422p10le -x265-params lossless=1:log-level=error -tag:v hvc1 lines-422-hevc.mov
    ffmpeg $q -f lavfi -i "$PAT_LINES" -c:v libx265 -pix_fmt yuv422p10le -x265-params lossless=1:log-level=error lines-422-hevc.ts
    ;;
  444)
    ffmpeg $q -f lavfi -i "$PAT_CHECK" -frames:v 1 -f rawvideo -pix_fmt yuv444p10le checker-444.yuv
    ffmpeg $q -f lavfi -i "$PAT_CHECK" -c:v prores_ks -profile:v 4 -pix_fmt yuv444p10le checker-444-prores4444.mov
    ffmpeg $q -f lavfi -i "$PAT_CHECK" -c:v prores_ks -profile:v 5 -pix_fmt yuv444p10le checker-444-prores4444xq.mov
    ffmpeg $q -f lavfi -i "$PAT_CHECK" -c:v prores_ks -profile:v 4 -pix_fmt yuv444p10le -f mxf checker-444-prores4444.mxf
    ffmpeg $q -f lavfi -i "$PAT_CHECK" -c:v dnxhd -profile:v dnxhr_444 -pix_fmt yuv444p10le checker-444-dnxhr444.mov
    ffmpeg $q -f lavfi -i "$PAT_CHECK" -c:v libx264 -profile:v high444 -pix_fmt yuv444p10le -qp 0 checker-444-h264.ts
    ffmpeg $q -f lavfi -i "$PAT_CHECK" -c:v libx265 -pix_fmt yuv444p10le -x265-params lossless=1:log-level=error -tag:v hvc1 checker-444-hevc.mov
    ffmpeg $q -f lavfi -i "$PAT_CHECK" -c:v libx265 -pix_fmt yuv444p10le -x265-params lossless=1:log-level=error checker-444-hevc.ts
    ;;
  420)
    # The 4:2:0 regression set (P1): STATIC pictures, so any frame of a live stream is the same frame.
    ffmpeg $q -f lavfi -i "$PAT_STILL420" -c:v libx264 -pix_fmt yuv420p -tune stillimage -g 25 still-420-h264.mov
    # The .ts are ALL-INTRA so every decoded frame is the same bytes: whichever frame ⌃⌥E catches on a
    # live stream, it is the same picture (an I/P mix of a still drifts by a code or two between them).
    ffmpeg $q -f lavfi -i "$PAT_STILL420" -c:v libx264 -pix_fmt yuv420p -tune stillimage -g 1 still-420-h264.ts
    ffmpeg $q -f lavfi -i "$PAT_STILL420" -c:v libx265 -pix_fmt yuv420p10le -x265-params keyint=25:log-level=error -tag:v hvc1 still-420-hevc10.mov
    # HEVC is LOSSLESS rather than all-intra, for the same reason: x265 signals an all-intra stream as
    # "Main 10 Intra", a Range Extensions profile (general_profile_idc 4), which Stage 3's gate refuses
    # (docs/BUGS.md). Lossless stays Main 10 and decodes every frame to the same bytes.
    ffmpeg $q -f lavfi -i "$PAT_STILL420" -c:v libx265 -pix_fmt yuv420p10le -x265-params lossless=1:keyint=25:log-level=error still-420-hevc10.ts
    ;;
  4k)
    ffmpeg $q -f lavfi -i "testsrc2=s=3840x2160:r=25:d=2" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le 4k-422-prores422hq.mov
    ffmpeg $q -f lavfi -i "testsrc2=s=3840x2160:r=25:d=2" -c:v libx265 -pix_fmt yuv422p10le -x265-params log-level=error -tag:v hvc1 4k-422-hevc.mov
    # OVER THE 8 MB ACCESS-UNIT CAP on purpose (~16 MB a frame): the negative test for
    # HEVCAccessUnitBuilder.c's MD_HEVC_MAX_ACCESS_UNIT_BYTES. No real SRT feed is near it.
    ffmpeg $q -f lavfi -i "testsrc2=s=3840x2160:r=25:d=1,noise=alls=40:allf=t" -c:v libx265 -pix_fmt yuv422p10le \
      -x265-params "keyint=1:qp=4:log-level=error" 4k-422-hevc-intra-overcap.ts
    ;;
  ndi)
    # P2 (S1, attended): 75 % RGB bars, 240 px wide, for an OBS Image source sent over NDI. The vertical
    # colour edges are what the co-sited 4:2:2 correction moves (half a pixel left in chroma; luma
    # unmoved). RGB, so OBS does the YCbCr conversion as for any real scene.
    ffmpeg $q -f lavfi -i "nullsrc=s=1920x1080:d=1,format=gbrp,geq=r='191*(lt(trunc(X/240)\,2)+eq(trunc(X/240)\,4)+eq(trunc(X/240)\,5))':g='191*lt(trunc(X/240)\,4)':b='191*eq(mod(trunc(X/240)\,2)\,0)*lt(trunc(X/240)\,7)'" \
      -frames:v 1 -pix_fmt rgb24 p2-bars.png
    ;;
  *) print -u2 "unknown group: $g (422 444 420 4k ndi)"; exit 2 ;;
  esac
done
ls -l $OUT
