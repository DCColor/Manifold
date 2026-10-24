#!/bin/zsh
# Manifold interlaced fixtures (docs/INTERLACED_FINDINGS.md §6 and §10, stage I1 — detection). Every picture comes
# from ffmpeg's own `testsrc2`, with a frame counter burnt in. No media goes in, and none comes out into the repo.
#
#   zsh scripts/interlaced/generate.sh
#
# Output (gitignored): build/interlaced-fixtures/   (INTERLACED_FIXTURES_OUT overrides)
#
# THE RECIPE (§6): `testsrc2` at the FIELD rate (60000/1001 or 50) with a `%{n}` counter, then
# `interlace=scan=tff|bff:lowpass=0`, which weaves two consecutive progressive pictures into one frame. Each field
# therefore carries its own source picture number: in a TFF frame the top field shows n, the bottom n+1.
#
# WHAT EACH FILE IS FOR. Tags are the truth (CLAUDE.md, test media); the names say what was asked for, and
# scripts/interlaced/verify.sh checks every one against FFmpeg's view and the app's own reader.
#   prores-*            ProRes 422 HQ, `-flags +ildct`: the frame header's interlace_mode, the `fiel` atom.
#   dnxhd-*             DNxHD (DNxHR has no interlaced profile, §6): header byte 5; MXF FrameLayout / FieldDominance.
#   h264-mbaff-*        x264 interlaced is MBAFF only. No free tool makes PAFF (§6), so there is no PAFF fixture.
#   hevc-fields-*       A TRUE field sequence: `separatefields` hands x265 1920x540 fields at 59.94, and x265's
#                       `interlace=tff` codes each as a picture (field_seq_flag 1, pic_struct 1 / 2). The container
#                       then says progressive (FFmpeg writes `fiel` 1 for the 540-line pictures), so the file is
#                       also a natural container / bitstream disagreement. ⚠️ Without `separatefields`, libx265's
#                       `interlace=tff` marks each WOVEN 1080-line frame as one field (pic_struct alternating 1 / 2)
#                       — the flags of a field sequence on frames that are not fields. Not made.
#   *.ts                Stream twins for I6. Manifold does not open `.ts` files; verify.sh reads them.
#   prores-1080p2997-control   progressive, no ildct.
#   prores-psf-*        PsF-style: a PROGRESSIVE picture at 29.97 coded and tagged as TFF. Tags alone cannot tell it.
#   prores-disagree-*   the TFF ProRes with only its `fiel` rewritten (to BFF, and to progressive): the bitstream
#                       still says TFF.
#
# SD (480i / 576i) is out of scope (§7 decision 8), so none is made.
#
# Measured with ffmpeg 8.1.1 (the vendored version; FFmpeg is not bundled as a program, so this is the Homebrew
# build of the same version).
set -eu
HERE=${0:A:h}; REPO=${HERE:h:h}
OUT=${INTERLACED_FIXTURES_OUT:-$REPO/build/interlaced-fixtures}; mkdir -p $OUT
cd $OUT
q=(-hide_banner -loglevel error -y)
FONT=/System/Library/Fonts/Menlo.ttc
D=2   # seconds

# The source at the field rate, counter burnt in. $1 = rate, $2 = tff|bff
src() { print -r -- "testsrc2=s=1920x1080:r=${1}:d=${D},drawtext=fontfile=${FONT}:text='%{n}':fontsize=300:fontcolor=white:box=1:boxcolor=black:x=160:y=160,interlace=scan=${2}:lowpass=0,setfield=${2}" }
# Progressive at the frame rate. $1 = rate
prog() { print -r -- "testsrc2=s=1920x1080:r=${1}:d=${D},drawtext=fontfile=${FONT}:text='%{n}':fontsize=300:fontcolor=white:box=1:boxcolor=black:x=160:y=160" }

prores=(-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le)
x264=(-c:v libx264 -profile:v high -pix_fmt yuv420p -flags +ildct+ilme -g 30)

# ── ProRes 422 HQ ─────────────────────────────────────────────────────────────────────────────────
ffmpeg $q -f lavfi -i "$(src 60000/1001 tff)" $prores -flags +ildct prores-1080i5994-tff.mov
ffmpeg $q -f lavfi -i "$(src 60000/1001 bff)" $prores -flags +ildct prores-1080i5994-bff.mov
ffmpeg $q -f lavfi -i "$(src 50 tff)"         $prores -flags +ildct prores-1080i50-tff.mov
ffmpeg $q -f lavfi -i "$(prog 30000/1001)"    $prores prores-1080p2997-control.mov
ffmpeg $q -f lavfi -i "$(prog 30000/1001),setfield=tff" $prores -flags +ildct prores-psf-1080i5994-tff.mov

# ── DNxHD (220x at 29.97, 185x at 25; 10-bit) ─────────────────────────────────────────────────────
ffmpeg $q -f lavfi -i "$(src 60000/1001 tff)" -c:v dnxhd -b:v 220M -pix_fmt yuv422p10le -flags +ildct -f mxf dnxhd-1080i5994-tff.mxf
ffmpeg $q -f lavfi -i "$(src 60000/1001 bff)" -c:v dnxhd -b:v 220M -pix_fmt yuv422p10le -flags +ildct -f mxf dnxhd-1080i5994-bff.mxf
ffmpeg $q -f lavfi -i "$(src 50 tff)"         -c:v dnxhd -b:v 185M -pix_fmt yuv422p10le -flags +ildct dnxhd-1080i50-tff.mov

# ── H.264 MBAFF ───────────────────────────────────────────────────────────────────────────────────
ffmpeg $q -f lavfi -i "$(src 60000/1001 tff)" $x264 -x264-params tff=1 h264-mbaff-1080i5994-tff.mov
ffmpeg $q -f lavfi -i "$(src 60000/1001 bff)" $x264 -x264-params bff=1 h264-mbaff-1080i5994-bff.mov
ffmpeg $q -f lavfi -i "$(src 60000/1001 tff)" $x264 -x264-params tff=1 h264-mbaff-1080i5994-tff.ts
ffmpeg $q -f lavfi -i "$(src 60000/1001 bff)" $x264 -x264-params bff=1 h264-mbaff-1080i5994-bff.ts

# ── HEVC, a true field sequence ───────────────────────────────────────────────────────────────────
ffmpeg $q -f lavfi -i "$(src 60000/1001 tff),separatefields" -c:v libx265 -pix_fmt yuv422p10le \
       -x265-params interlace=tff:log-level=error -tag:v hvc1 hevc-fields-1080i5994-tff.mov
ffmpeg $q -f lavfi -i "$(src 60000/1001 tff),separatefields" -c:v libx265 -pix_fmt yuv422p10le \
       -x265-params interlace=tff:log-level=error hevc-fields-1080i5994-tff.ts

# ── Container and bitstream disagreeing: the TFF ProRes with only its `fiel` rewritten ─────────────
# `fiel` is FieldCount (1 byte) then FieldDetail (1 byte). Exactly one `fiel` must exist; the copy is patched in
# place at that offset and nothing else changes.
fiel() {   # $1 in, $2 out, $3 count, $4 detail
  cp $1 $2
  python3 -I - $2 $3 $4 <<'PY'
import sys
path, count, detail = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = bytearray(open(path, "rb").read())
at = data.find(b"fiel")
assert at > 0 and data.find(b"fiel", at + 1) < 0, "expected exactly one fiel atom"
assert int.from_bytes(data[at - 4:at], "big") == 10, "fiel atom is not 10 bytes"
data[at + 4] = count; data[at + 5] = detail
open(path, "wb").write(data)
PY
}
fiel prores-1080i5994-tff.mov prores-disagree-fielbff-1080i5994.mov 2 14
fiel prores-1080i5994-tff.mov prores-disagree-fielprog-1080i5994.mov 1 0

ls -l $OUT
