# bands.py <stem> [control-stem]: at the four band centres (x 240/720/1200/1680, ±40 px, rows 500-580), the export
# (rgba16f readback -> limited 10-bit Y'CbCr with the dump's kr/kb) as means, and the v210 wire as min..max. With a
# control stem: the fraction of rgba16f pixels byte-identical to the control's, and the largest band-mean difference.
import json, struct, sys, statistics as st
def load(stem):
    m = json.load(open(stem + '.v210.json')); return m, open(stem + '.rgba16f', 'rb').read(), open(stem + '.v210', 'rb').read()
def px(m, raw, x, y):
    kr, kb = m['kr'], m['kb']; kg = 1 - kr - kb
    o = y * m['readbackBytesPerRow'] + x * 8; r, g, b, _ = struct.unpack('<4e', raw[o:o+8]); Y = kr*r + kg*g + kb*b
    return 64 + 876*Y, 512 + 896*(b - Y)/(2*(1-kb)), 512 + 896*(r - Y)/(2*(1-kr))
def wpx(m, wire, x, y):
    g = x // 6; o = y * m['rowBytes'] + g * 16; w = struct.unpack('<4I', wire[o:o+16])
    v = [(t >> s) & 1023 for t in w for s in (0, 10, 20)]
    ys = [v[1], v[3], v[5], v[7], v[9], v[11]]; k = (x % 6) // 2
    return ys[x % 6], [v[0], v[4], v[8]][k], [v[2], v[6], v[10]][k]
def bands(stem):
    m, raw, wire = load(stem); res = {}
    for x in (240, 720, 1200, 1680):
        E = [px(m, raw, xx, yy) for xx in range(x-40, x+40, 2) for yy in range(500, 580, 2)]
        W = [wpx(m, wire, xx, yy) for xx in range(x-40, x+40, 2) for yy in range(500, 580, 2)]
        res[x] = ([st.mean(c) for c in zip(*E)], [(min(c), max(c)) for c in zip(*W)])
    return m, raw, res
m, raw, r = bands(sys.argv[1])
for x, (e, w) in r.items():
    ws = '/'.join(f"{a}" if a == b else f"{a}..{b}" for a, b in w)
    print(f"  x{x}: export {e[0]:.2f}/{e[1]:.2f}/{e[2]:.2f}  wire {ws}")
if len(sys.argv) > 2:
    mc, rawc, rc = bands(sys.argv[2])
    W, H, bpr = m['width'], m['height'], m['readbackBytesPerRow']
    same = sum(raw[y*bpr + x*8: y*bpr + x*8 + 8] == rawc[y*bpr + x*8: y*bpr + x*8 + 8] for y in range(0, H, 2) for x in range(W))
    total = (H // 2) * W
    d = max(abs(a - b) for x in r for a, b in zip(r[x][0], rc[x][0]))
    wd = max(abs(a[i] - b[i]) for x in r for a, b in zip(r[x][1], rc[x][1]) for i in (0, 1))
    print(f"  vs control: rgba16f pixels identical {same}/{total} = {100*same/total:.3f} % (even rows); max band-mean diff {d:.3f}; max wire diff {wd}")
