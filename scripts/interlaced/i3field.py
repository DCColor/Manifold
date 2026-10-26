# Interlaced I3 (docs/INTERLACED_FINDINGS.md §12): one raw 1920×1080 frame whose two fields carry different, sharp chroma,
# written directly as Y'CbCr so no RGB conversion stands between the numbers below and the encoder.
#
#   Luma: one value everywhere (8-bit 128 / 10-bit 512), so any change in luma is the chain's, not the picture's.
#   Colour A (reddish): Cb 88 Cr 168 (8-bit) / 352 672 (10-bit). Colour B (bluish): Cb 168 Cr 88 / 672 352.
#   Field 1 (top, even rows) and field 2 (bottom, odd rows) always carry opposite colours:
#     U  x < 960,  y < 540   uniform: field 1 A, field 2 B
#     V  x < 960,  y ≥ 540   64-line bands: band k = (y − 540) / 64; field 1 A on even k, B on odd; field 2 the opposite
#     H  x ≥ 960             64-pixel bars: bar m = (x − 960) / 64; field 1 A on even m, B on odd; field 2 the opposite
#   Every boundary is on the 4-line / 2-pixel grid, so each 4:2:0 chroma sample lies inside one region of one field.
#
# Usage: python3 -I i3field.py <yuv420p|yuv422p10le|yuv444p10le> <out.raw>
import sys, struct

W, H = 1920, 1080
fmt, out = sys.argv[1], sys.argv[2]
ten = fmt.endswith("10le")
Y = 512 if ten else 128
A = (352, 672) if ten else (88, 168)
B = (672, 352) if ten else (168, 88)


def colour(x, y, field):
    """Field `field` (0 top, 1 bottom)'s colour at frame position (x, y)."""
    if x >= 960:
        first = ((x - 960) // 64) % 2 == 0
    elif y < 540:
        first = True
    else:
        first = ((y - 540) // 64) % 2 == 0
    if field == 1:
        first = not first
    return A if first else B


def plane_rows(cw, ch, xstep, row_of):
    """Cb and Cr planes; chroma row r covers frame row row_of(r), chroma column k frame column k·xstep."""
    cb, cr = [], []
    for r in range(ch):
        y = row_of(r)
        vals = [colour(k * xstep, y, y & 1) for k in range(cw)]
        cb.append([v[0] for v in vals]); cr.append([v[1] for v in vals])
    return cb, cr


if fmt == "yuv420p":
    # 4:2:0 chroma row c belongs to field c & 1 and covers that field's frame rows 4·(c >> 1) + (c & 1) and +2.
    cb, cr = plane_rows(W // 2, H // 2, 2, lambda c: 4 * (c >> 1) + (c & 1))
elif fmt == "yuv422p10le":
    cb, cr = plane_rows(W // 2, H, 2, lambda r: r)
elif fmt == "yuv444p10le":
    cb, cr = plane_rows(W, H, 1, lambda r: r)
else:
    sys.exit("unknown format " + fmt)

pack = (lambda row: struct.pack("<%dH" % len(row), *row)) if ten else bytes
with open(out, "wb") as f:
    f.write(pack([Y] * W) * H)
    for plane in (cb, cr):
        for row in plane:
            f.write(pack(row))
