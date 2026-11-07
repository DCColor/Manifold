# cardlock-summary.py <dir> <label>: a Stage 1a run (docs/CARD_CLOCK_FINDINGS.md §10.8). The [CARDLOCK] lines, the file clock against the host
# in steady stretches, clock steps, and repeats and skips in [CADENCE] pulls between transport moves.
import re, statistics as st, sys
d, label = sys.argv[1], sys.argv[2]
L = open(f"{d}/{label}.log", errors="replace").read().splitlines()
def slope(xs, ys):
    n = len(xs); mx = sum(xs) / n; my = sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else float("nan")
ppm = lambda s: (s - 1) * 1e6
m = re.search(r"\(timescale (\d+), frame (\d+)\)", "\n".join(L)); frame = int(m[2]) / int(m[1]) if m else None
locks = [l for l in L if l.startswith("[CARDLOCK]")]
print("CARDLOCK lines:", len(locks))
for l in locks:
    if "latched" in l or "released" in l or "holding" in l: print("  ", l)
worst = [float(x[1]) for l in locks for x in [re.search(r"([\d.]+) µs worst", l)] if x]
now = [abs(float(x[1])) for l in locks for x in [re.search(r"error ([+-][\d.]+) µs now", l)] if x]
if worst: print(f"  error: median of 10 s readings {st.median(now):.1f} µs, worst {max(worst):.1f} µs, over {len(worst)} windows")
# the file clock: every paired reading there is, in host order
rows = []
for l in L:
    x = re.match(r"\[CARDCLOCK-FILE\] host (\S+) clock (\S+)", l) or re.match(r"\[CADENCE\] #\d+ host (\S+) pts \S+ swapAgo \S+ clock (\S+)", l)
    if x and x[2] != "nan": rows.append((float(x[1]), float(x[2])))
rows.sort()
edges = sorted(float(x[1]) for l in L for x in [re.match(r"\[TRANSPORT\] .* host (\S+) clock", l)] if x)
# steady stretches: the clock advancing 1:1, split wherever it leaves the running line by over 500 µs
segs, cur = [], []
for a, b in zip(rows, rows[1:]):
    dh, dc = b[0] - a[0], b[1] - a[1]
    if dh > 0 and abs(dc - dh) < 0.0005 + dh * 2e-4 and dh < 3: cur.append(b)
    else:
        if dc != 0 or dh > 3 or True:
            if len(cur) > 1: segs.append(cur)
            cur = []
if len(cur) > 1: segs.append(cur)
print("clock stretches (span ≥ 5 s):")
for s in segs:
    if s[-1][0] - s[0][0] >= 5:
        print(f"   host {s[0][0]:.1f} +{s[-1][0]-s[0][0]:.1f} s, clock {s[0][1]:.3f} → {s[-1][1]:.3f}, {ppm(slope([r[0] for r in s], [r[1] for r in s])):+.3f} ppm")
# steps of the clock against the host: a neighbouring pair off the 1:1 line, with the clock running 1:1 on both sides of it
gaps = [(b[0], b[1] - a[1] - (b[0] - a[0]), b[0] - a[0]) for a, b in zip(rows, rows[1:])]
big = [(g[0], g[1] * 1e3) for p_, g, n in zip(gaps, gaps[1:], gaps[2:]) if 0 < g[2] < 3 and abs(g[1]) > 0.001 and abs(p_[1]) < 0.0005 and abs(n[1]) < 0.0005]
print("clock steps over 1 ms, running either side:", len(big), [f"{t:.3f}: {v:+.2f} ms" for t, v in big[:24]])
# pulls at 1x: repeats and skips, ignoring 1.5 s after each transport move
if frame:
    cad = [(int(x[1]), float(x[2]), float(x[3]), float(x[4])) for l in L for x in [re.match(r"\[CADENCE\] #(\d+) host (\S+) pts (\S+) swapAgo \S+ clock (\S+)", l)] if x and x[3] != "nan" and x[4] != "nan"]
    rep = skip = counted = 0; events = []
    for p, q in zip(cad, cad[1:]):
        dh, dc = q[1] - p[1], q[3] - p[3]
        if dc <= 0 or abs(dc - dh) > 0.012: continue            # paused, shuttled or moved: not 1x (a pull's callback jitter is up to about 10 ms)
        if any(e - 0.1 <= q[1] <= e + 1.5 for e in edges): continue
        counted += 1
        step = (q[2] - p[2]) / frame
        if abs(step) < 0.25: rep += 1; events.append((round(q[1], 2), "r"))
        elif step > 1.5: skip += 1; events.append((round(q[1], 2), f"s{step:.1f}"))
    print(f"pulls at 1x: {counted} counted, repeats {rep}, skips {skip}", events[:24])
for l in L:
    if "DeckLink D3: stopped" in l: print("  ", l)
print("FRAMEQ evictions:", sum("[FRAMEQ]" in l for l in L))
for l in L:
    if l.startswith("[TRANSPORT]"): print("  ", l)
