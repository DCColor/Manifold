# SDI scaling fixtures

Test files for the planned DeckLink scaling stage (`docs/BUGS.md`, *DeckLink: any source raster that matches no
output mode carries BLACK*): one file per raster that matches no SDI output mode, plus a 1920×1080 control. Made by
ffmpeg from its own sources (`color`, `geq`, `drawtext`, `aevalsrc`), from committed recipes. No media goes in and
nothing is installed.

| file | what it is |
|---|---|
| `recipes.tsv` | one row per file: label, width, height, exact rate, colour strip (`yes` / `-`), why it is in the set |
| `make_fixtures.sh` | builds every file (or the labels named) into `build/sdi-scaling/` (gitignored, under `build/`) |
| `verify.py` | reads every file back: stream tags, sample entries, length, and the decoded picture; stdlib only |

```sh
zsh scripts/sdi-scaling/make_fixtures.sh                          # all twenty-six, ~70 s on an M-series Mac, ~2.2 GB
zsh scripts/sdi-scaling/make_fixtures.sh 1080x1920p23.976         # or some
python3 scripts/sdi-scaling/verify.py                             # exit 1 if any check fails
```

Needs `ffmpeg` (with `prores_ks`, `geq`, `drawtext`) and, for `verify.py`, `mediainfo`. **ffprobe is not needed and
was not used:** it is not installed on the build Mac, and `ffmpeg -i` prints the same libavformat stream description,
which is what `verify.py` reads. The font is Menlo (`SDISCALING_FONT` to change it).

## What every file carries

Format: ProRes 422 HQ (`apch`), 10-bit 4:2:2, square pixels (SAR 1:1), tagged Rec.709 1-1-1 (primaries, transfer,
matrix; `colr`), limited range. PCM 24-bit little-endian (`in24`), 48 kHz stereo: **L 1 kHz, R 2 kHz**, −20 dBFS, so
the two channels cannot be confused. At least 10 s, whole frames AND whole samples: 10.01 s (240 frames at 23.976,
600 at 59.94, 480 480 samples), audio and video the same length.

The picture is one frame, drawn with exact code values and looped (only the label's frame counter changes):

| element | how it is drawn | what it checks on SDI |
|---|---|---|
| background | Y 192 (10-bit; 48 at 8), dark grey | the picture's own edge is distinguishable from black bars |
| border | 1-px white (940) on the outermost row and column, all four edges | **crop**: every edge survives; a missing edge is a crop, a soft one is the filter |
| circle | 3-px white ring, radius 0.35 × the shorter side, centred on the raster's true centre ((W−1)/2, (H−1)/2) | **aspect**: a stretched picture draws an ellipse — measure it horizontally and vertically |
| crosshair | 2-px lines through that centre, arms 0.05 × the shorter side (rasters are even, so the centre falls between two rows and two columns and the 2-px line straddles it) | **placement**: centred in the output, bars equal on both sides |
| detail | two rows of 64 × 64 patches, bottom left and bottom right, 24 px in: 1-px vertical line pairs, 1-px horizontal, 2-px vertical, 2-px horizontal, 1-px checkerboard | **filter**: 1-px pairs alias or grey out under a poor filter; 2-px pairs should survive a 0.5–0.94 × downscale; the checkerboard shows chroma-siting and both axes at once |
| label | two lines, top centre: `<raster>p<rate>   frame NNNN`, then format and tags; each sized to fit the width | which file is on the monitor, and that frames are advancing |

## Verified (2026-10-21, `verify.py`, 7 / 7 pass)

Stream lines are `ffmpeg -i`'s, sample entries and counts are mediainfo's, picture values are frame 0's decoded Y
(10-bit codes, read from `yuv422p10le` without conversion).

| file | ffmpeg video stream | ffmpeg audio stream | length | MB |
|---|---|---|---|---|
| `sdi-1280x720p23.976.mov` | prores (HQ) apch, yuv422p10le(tv, bt709, progressive), 1280x720, SAR 1:1 DAR 16:9, 23.98 fps | pcm_s24le in24, 48000 Hz, stereo, 24 bit | 240 f = 480 480 s = 10.0100 s | 27.7 |
| `sdi-1280x720p59.94.mov` | prores (HQ) apch, yuv422p10le(tv, bt709, progressive), 1280x720, SAR 1:1 DAR 16:9, 59.94 fps | same | 600 f = 480 480 s = 10.0100 s | 64.9 |
| `sdi-1080x1920p23.976.mov` | prores (HQ) apch, yuv422p10le(tv, bt709, progressive), 1080x1920, SAR 1:1 DAR 9:16, 23.98 fps | same | 240 f = 480 480 s | 38.8 |
| `sdi-1080x1080p23.976.mov` | prores (HQ) apch, yuv422p10le(tv, bt709, progressive), 1080x1080, SAR 1:1 DAR 1:1, 23.98 fps | same | 240 f = 480 480 s | 35.3 |
| `sdi-2048x858p23.976.mov` | prores (HQ) apch, yuv422p10le(tv, bt709, progressive), 2048x858, SAR 1:1 DAR 1024:429, 23.98 fps | same | 240 f = 480 480 s | 36.5 |
| `sdi-1440x1080p23.976.mov` | prores (HQ) apch, yuv422p10le(tv, bt709, progressive), 1440x1080, SAR 1:1 DAR 4:3, 23.98 fps | same | 240 f = 480 480 s | 38.7 |
| `sdi-1920x1080p23.976.mov` (control) | prores (HQ) apch, yuv422p10le(tv, bt709, progressive), 1920x1080, SAR 1:1 DAR 16:9, 23.98 fps | same | 240 f = 480 480 s | 42.1 |

mediainfo, all seven: video `apch`, pixel aspect 1.000, primaries / transfer / matrix BT.709 / BT.709 / BT.709 read
from "Container / Stream", 4:2:2; audio `in24`, little-endian, 24-bit, 2 ch, 48000 Hz. mediainfo reports no range
and no bit depth for ProRes: a `.mov`'s `colr` is QuickTime `nclc`, which has no range field, and ProRes is limited
range by definition; ffmpeg's `tv` is the range check.

Decoded picture, all seven: background **192**; border **936–942** on all four edges; centre 2×2 **940–942**; ring
radius measured right / left / down / up from the centre equal within 1 px (e.g. 377.5 / 377.0 / 377.5 / 377.0 against
a recipe of 378.0 on the 1080-short rasters; 300.5 / 300.0 / 300.5 / 300.0 against 300.3 on 2048×858 — the half-pixel
split is the centre falling between pixels); 1-px line pairs **64–940**, full contrast after ProRes HQ.

## Added 2026-10-23: nine more, with a colour strip

`1920x804`, `1920x1038`, `1998x1080`, `3840x1608`, `4096x1716`, `2048x1080`, `4096x2160`, `6144x3240` and `1920x817`,
all at 23.976. Same format and picture, plus one element the first seven do not have:

- **Colour strip:** seven 64 × 64 patches centred on the bottom detail row. They are BT.709 75 % yellow, cyan, green,
  magenta, red and blue, then a 1-px Cr alternation. An achromatic picture cannot show chroma filtering or 4:2:2
  siting, and this can.
- **Odd height:** `1920x817` has one, so its letterbox cannot split evenly. Odd heights are allowed now; widths must
  stay even for 4:2:2. Its centre falls on a row, so the horizontal crosshair arm is 1 px tall there.

Extending the script left the first seven byte-identical. Regenerated into a scratch directory, they match the files on
disk (SHA-256). `verify.py`: **16 / 16 pass**, 2026-10-23.

## Added 2026-10-23 (SDI scaling follow-ups): ten at the new rates

`1920x1080` at 47.952, 48, 95.904, 96, 100, 119.88 and 120; `1280x720p119.88` (720p has no 119.88 mode);
`2048x1080` at 48 and 119.88 (2K DCI). Same format, picture and colour strip as the nine above, whole frames and whole
samples (1200 frames at 119.88 and 120, 10.01 s / 10.00 s). The script is unchanged; only `recipes.tsv` gained rows.
`verify.py`: **26 / 26 pass**, 2026-10-23. One reading to know about: mediainfo leaves the frame-rate fields of
`1920x1080p95.904` empty, while ffmpeg reads it as 95.90 fps and the length checks pass (960 frames = 480 480 samples).
About 1.3 GB for the ten.

## What SDI does with them (built and measured 2026-10-23)

Where each one goes, under both settings of *SDI output modes*, is the table in `docs/COLOR_MANAGEMENT_FINDINGS.md`
§6.11, *SDI scaling*, with the measured results below it:
- A source that fits a mode at its rate goes out **1:1**, with video black around it.
- Only a picture larger than every mode is scaled down.
- So 1280×720 p23.976 is windowboxed 1:1 in 1080p23.98, not scaled ×1.5 as the table this section replaces assumed.
