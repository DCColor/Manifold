#!/usr/bin/env python3
"""[AV-LAG] analysis (the DEBUG-only line; docs/BUGS.md, PRE-SHIP): av = audio heard at the moment
the picture reached the glass − the picture's PTS, and its parts (frame choice, audio against the
clock, tick → glass), per 3-min block, with Theil–Sen slopes after 180 s; plus LiveClock's rail share.
Usage: avlag.py <manifold.log> [label]"""
import re, sys, statistics as st, random
R = re.compile(r'\[AV-LAG\] tick=([\d.]+) pts=([-\d.]+) now−pts=([+-][\d.]+) ms audio−now=([+-][\d.]+) ms '
               r'tick→glass=([+-][\d.]+) ms av=([+-][\d.]+) ms')
rows = [tuple(map(float, m.groups())) for m in map(R.search, open(sys.argv[1], errors='replace')) if m]
lc = [l for l in open(sys.argv[1], errors='replace') if '[LIVECLOCK] depth=' in l]
rail = sum(('rate=1.0050' in l) or ('rate=0.9950' in l) for l in lc)
t0 = rows[0][0]
rows = [(r[0] - t0,) + r[1:] for r in rows]
def theil(x, y, cap=900):
    idx = list(range(len(x)))
    if len(idx) > cap: random.seed(1); idx = sorted(random.sample(idx, cap))
    s = sorted((y[j] - y[i]) / (x[j] - x[i]) for a, i in enumerate(idx) for j in idx[a + 1:] if x[j] > x[i])
    return s[len(s) // 2]
late = [r for r in rows if r[0] >= 180]
x = [r[0] for r in late]
names = ['now−pts', 'audio−now', 'tick→glass', 'av']
label = sys.argv[2] if len(sys.argv) > 2 else sys.argv[1]
print(f"== {label}: {len(rows)} samples over {rows[-1][0]:.0f} s · LiveClock at ±0.5 %: {rail} of {len(lc)} lines ({100*rail/max(1,len(lc)):.0f} %)")
print("block (s)   " + "  ".join(f"{n:>11s}" for n in names) + "   (medians, ms)")
for b in range(0, int(rows[-1][0]) + 1, 180):
    blk = [r for r in rows if b <= r[0] < b + 180]
    if blk: print(f"{b:5d}–{b+180:<5d} " + "  ".join(f"{st.median(r[k] for r in blk):+11.2f}" for k in (2, 3, 4, 5)))
if len(late) < 10:
    sys.exit("slopes: fewer than 10 samples after 180 s — log too short")
print("slope after 180 s (ppm; ms per 20 min):")
for k, n in zip((2, 3, 4, 5), names):
    s = theil(x, [r[k] / 1e3 for r in late])
    print(f"  {n:>11s} {s*1e6:+7.1f} ppm  {s*1200*1e3:+7.1f} ms/20 min")
