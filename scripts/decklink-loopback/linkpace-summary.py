# linkpace-summary.py <marks> <app log>: frame identity on the SDI wire, and the card's own counts (linkpace.sh).
# Marks lines (capture --marks): "<rx index> <stream time> <top number|?> <bottom number|?> <dominance>". A progressive
# picture carries one number in both fields; a frame whose band does not read is "?" and counted as unread.
import re, sys
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
