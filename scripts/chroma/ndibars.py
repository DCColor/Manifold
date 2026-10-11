# ndibars.py <stem>: the NDI p2 bars (8 bars, 240 px wide). At each bar centre (±60 px, rows 400-680) the export
# (rgba16f -> limited 10-bit Y'CbCr) as means, and the v210 wire as min..max, and whether each is a whole multiple
# of 4 (an 8-bit source mapped exactly x4): the export within ±0.25 (its readback reads an exact 512 as 511.84),
# the wire exactly. VideoToolbox's full-scale map puts most mid values 1-3 codes above one.
import json, struct, sys, statistics as st
stem = sys.argv[1]; m = json.load(open(stem + '.v210.json')); raw = open(stem + '.rgba16f', 'rb').read(); wire = open(stem + '.v210', 'rb').read()
kr, kb = m['kr'], m['kb']; kg = 1 - kr - kb; W = m['width']
def px(x, y):
    o = y * m['readbackBytesPerRow'] + x * 8; r, g, b, _ = struct.unpack('<4e', raw[o:o+8]); Y = kr*r + kg*g + kb*b
    return 64 + 876*Y, 512 + 896*(b - Y)/(2*(1-kb)), 512 + 896*(r - Y)/(2*(1-kr))
def wpx(x, y):
    g = x // 6; o = y * m['rowBytes'] + g * 16; w = struct.unpack('<4I', wire[o:o+16])
    v = [(t >> s) & 1023 for t in w for s in (0, 10, 20)]
    return [v[1], v[3], v[5], v[7], v[9], v[11]][x % 6], [v[0], v[4], v[8]][(x % 6)//2], [v[2], v[6], v[10]][(x % 6)//2]
bars = W // 240; allx4 = True
for k in range(bars):
    c = 120 + 240 * k
    E = [px(x, y) for x in range(c-60, c+60, 2) for y in range(400, 680, 4)]
    V = [wpx(x, y) for x in range(c-60, c+60, 2) for y in range(400, 680, 4)]
    e = [st.mean(t) for t in zip(*E)]; w = [(min(t), max(t)) for t in zip(*V)]
    ex4 = all(abs(v - 4*round(v/4)) <= 0.25 for v in e); wx4 = all(a == b and a % 4 == 0 for a, b in w)
    allx4 &= ex4 and wx4
    print(f"  bar {k}: export {e[0]:.2f}/{e[1]:.2f}/{e[2]:.2f} {'×4' if ex4 else 'NOT ×4'}   wire "
          + '/'.join(f"{a}" if a == b else f"{a}..{b}" for a, b in w) + f" {'×4' if wx4 else 'NOT ×4'}")
print("  ALL BARS ×4" if allx4 else "  NOT ALL ×4")
