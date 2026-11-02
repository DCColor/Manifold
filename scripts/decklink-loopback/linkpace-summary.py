# linkpace-summary.py <marks> <app log>: frame identity on the SDI wire, and the card's own counts (linkpace.sh).
# Marks lines (capture --marks): "<rx index> <stream time> <top number|?> <bottom number|?> <dominance>". A progressive
# picture carries one number in both fields; a frame whose band does not read is "?" and counted as unread.
import re, sys
from statistics import median

def window(log):
    # linkpace-summary.py --window <app log>: the window alone (linkpace.sh window), between [DRV] BEGIN and END, split
    # at each [DRV] MOVE. Per segment: presented a second (each [PLAYBACK-STATS] line covers ≈1 s), dropped (superseded)
    # and late totals, and the tick interval from [RENDER-PERF] (median of the 1 s means, and the max).
    L = open(log, errors="replace").read().splitlines()
    b = next((i for i, l in enumerate(L) if l.startswith("[DRV] BEGIN")), 0)
    e = next((i for i, l in enumerate(L) if l.startswith("[DRV] END")), len(L))
    segs = [("start", [])]
    for l in L[b:e]:
        if l.startswith("[DRV] MOVE"): segs.append((l.split()[-1], [])); continue
        segs[-1][1].append(l)
    for name, ls in segs:
        st = [re.search(r"presented=(\d+) dropped=(\d+) late=(\d+)", l) for l in ls if l.startswith("[PLAYBACK-STATS] t=")]
        st = [m for m in st if m]
        tk = [re.search(r"tickMs=([\d.]+)/([\d.]+)", l) for l in ls if l.startswith("[RENDER-PERF]")]
        tk = [m for m in tk if m]
        pres = [int(m[1]) for m in st]
        print(f"window [{name}]: presented a second {' '.join(map(str, pres)) or '—'} · dropped {sum(int(m[2]) for m in st)} · "
              f"late {sum(int(m[3]) for m in st)} · tick median {median(float(m[1]) for m in tk) if tk else float('nan'):.2f} ms, "
              f"max {max((float(m[2]) for m in tk), default=float('nan')):.2f} ms")
    # [AV-LAG], once a second: medians over the run (ms) and the count. With MANIFOLD_AVLAG_FILE=1 a file's audio−now is 0
    # by construction (the clock is the synchronizer's audio timeline).
    av = [re.search(r"now−pts=([-+\d.]+) ms audio−now=([-+\d.]+) ms tick→glass=([-+\d.]+) ms av=([-+\d.]+) ms", l)
          for l in L[b:e] if l.startswith("[AV-LAG]")]
    av = [m for m in av if m]
    if av:
        med = [median(float(m[i]) for m in av) for i in range(1, 5)]
        print(f"av-lag: n={len(av)} · now−pts {med[0]:+.2f} · audio−now {med[1]:+.2f} · tick→glass {med[2]:+.2f} · "
              f"av {med[3]:+.2f} ms (median; av min {min(float(m[4]) for m in av):+.2f}, max {max(float(m[4]) for m in av):+.2f})")
    for l in L:
        if l.startswith("[LINK]") or l.startswith("[PACER] desktop"): print(l[:220])

if sys.argv[1] == "--window":
    window(sys.argv[2]); sys.exit(0)
marks, log = sys.argv[1], sys.argv[2]
nums, unread = [], 0
for line in open(marks):
    f = line.split()
    if len(f) < 4: continue
    top, bot = f[2], f[3]
    n = top if top != "?" else bot
    if n == "?": unread += 1; continue
    nums.append(int(n))
steps = [b - a for a, b in zip(nums, nums[1:])]
rep = sum(1 for s in steps if s == 0); skip = sum(1 for s in steps if s > 1); back = sum(1 for s in steps if s < 0)
skipped = sum(s - 1 for s in steps if s > 1)
print(f"wire: {len(nums)} frames read ({unread} unread) · pictures {nums[0] if nums else '?'}→{nums[-1] if nums else '?'} · "
      f"repeats {rep} · skips {skip} ({skipped} pictures missing) · backs {back}")
L = open(log, errors="replace").read().splitlines()
d3 = [l for l in L if "DeckLink D3: stopped" in l]
print("card:", d3[-1].split("— ", 1)[1] if d3 else "no D3 stop line")
b = next((i for i, l in enumerate(L) if l.startswith("[DRV] BEGIN")), 0)
e = next((i for i, l in enumerate(L) if l.startswith("[DRV] END")), len(L))
pts = [float(m[1]) for l in L[b:e] for m in [re.search(r"\[CADENCE\] #\d+ host \S+ pts (\S+)", l)] if m and m[1] != "nan"]
fps = [float(m[1]) for l in L for m in [re.search(r"FILE source format \S+ @ ([\d.]+) fps", l)] if m]
if pts and fps:
    fd = 1 / fps[-1]; s2 = [round((y - x) / fd, 2) for x, y in zip(pts, pts[1:])]
    print(f"card input: {len(pts)} pulls · repeats {sum(1 for s in s2 if abs(s) < 0.25)} · skips {sum(1 for s in s2 if s > 1.5)}")
for l in L:
    if l.startswith("[PACER]"): print(l[:220])
