# cardlock-1b.py <dir> <label>: what Stage 1b adds to cardlock-summary.py and cardclock-summary.py (docs/CARD_CLOCK_FINDINGS.md §10.11): renderer moves, the audio clock's
# parting and re-anchors, the tap's lead over the card's cursor, SDI audio's counters, the clock's steps, and every discontinuity in the device's sample time.
import re, statistics as st, sys
d, label = sys.argv[1], sys.argv[2]
L = open(f"{d}/{label}.log", errors="replace").read().splitlines()
print("renderer moves:"); [print("  ", l) for l in L if l.startswith("[CARDLOCK] audio renderer")]
rea = [l for l in L if "re-anchored" in l]
print(f"re-anchors: {len(rea)}"); [print("  ", l) for l in rea[:40]]
aw = [(float(x[1]), float(x[2])) for l in L for x in [re.search(r"audio ([+-][\d.]+) ms now, ([\d.]+) ms worst", l)] if x]
if aw: print(f"audio part, 10 s lines: {len(aw)}, first {aw[0][0]:+.2f}, last {aw[-1][0]:+.2f}, min {min(a for a, _ in aw):+.2f}, max {max(a for a, _ in aw):+.2f}, worst {max(w for _, w in aw):.2f} ms")
# the tap's lead over the cursor, each read against the file clock of the pull before it. One reading a second, so a floor, not a minimum of every instant.
clock = None; tap = []; cur = []; last = {}
for l in L:
    x = re.match(r"\[CADENCE\] #\d+ host \S+ pts \S+ swapAgo \S+ clock (\S+)", l)
    if x and x[1] != "nan": clock = float(x[1]); continue
    x = re.search(r"AudioTap\[\w+\]: int32 .* pts=([\d.]+)s", l)
    if x and clock is not None: tap.append((clock, float(x[1]) - clock)); continue
    x = re.match(r"DeckLinkAudio: buffered=(\d+)f .* srcT=([\d.]+)s .* vq=(\d+)f · drift=([+-][\d.]+)ms · corr=([+-]\d+)f · underruns=(\d+) events=(\d+) short=(\d+) resyncs=(\d+)", l)
    if x:
        last = dict(underruns=int(x[6]), events=int(x[7]), short=int(x[8]), resyncs=int(x[9]))
        if clock is not None: cur.append((clock, float(x[2]) - clock, float(x[4])))
if tap and cur:
    # steady only: past the first 20 s of the run, and with the clock moving between neighbours
    t0 = cur[0][0] + 20
    off = [c[1] for c in cur if c[0] > t0]; tp = [t[1] for t in tap if t[0] > t0]
    if off and tp:
        o = st.median(off)
        print(f"tap ahead of clock: median {st.median(tp)*1e3:.0f} ms, floor {min(tp)*1e3:.0f} ms · cursor from clock: median {o*1e3:.0f} ms · lead over the cursor: median {(st.median(tp)-o)*1e3:.0f} ms, floor {(min(tp)-o)*1e3:.0f} ms ({len(tp)} tap readings)")
print("SDI audio, last line:", last)
# The 1 Hz line stops when the card's source time does, so the card's own totals at each stop are the count to trust.
for l in open(f"{d}/{label}.log", errors="replace"):
    x = re.search(r"DeckLinkAudio: stopped .*real=(\d+)f.*silence=(\d+)f.*underruns=(\d+) underrunEvents=(\d+)", l)
    if x:
        print(f"   SDI audio at stop: real {int(x[1])/48000:.1f} s, silence {int(x[2])/48000:.1f} s, underruns {x[3]}, events {x[4]}")
# file clock: steps off 1:1 between neighbouring pulls while running
rows = sorted((float(x[1]), float(x[2])) for l in L for x in [re.match(r"\[CADENCE\] #\d+ host (\S+) pts \S+ swapAgo \S+ clock (\S+)", l)] if x and x[2] != "nan")
steps = []
for a, b, c in zip(rows, rows[1:], rows[2:]):
    if a[1] < b[1] < c[1] and 0 < b[0] - a[0] < 1 and abs((c[1] - b[1]) - (c[0] - b[0])) < 0.0005:
        e = (b[1] - a[1]) - (b[0] - a[0])
        if abs(e) > 0.001: steps.append((round(b[0], 3), round(e * 1e3, 2)))
print("clock steps over 1 ms, while running:", len(steps), steps[:12])
# device: sample time against host, once a second. Any second off 48000 by over 1 ms of samples is a discontinuity.
dev = []
try:
    for l in open(f"{d}/{label}.dev"):
        f = l.split()
        if len(f) == 3: dev.append((float(f[0]), float(f[1])))
except FileNotFoundError: pass
disc = []
for a, b in zip(dev, dev[1:]):
    dh = b[0] - a[0]; ds = b[1] - a[1]
    if dh > 0 and abs(ds - dh * 48000) > 48: disc.append((round(b[0], 3), f"host gap {dh:.3f} s, samples {ds:+.0f}, off by {(ds / 48000 - dh) * 1e3:+.1f} ms"))
print("device sample-time discontinuities:", len(disc)); [print("  ", x) for x in disc[:12]]
for l in L:
    if l.startswith("[DEVINPUT]") or l.startswith("[DRV] INPUT"): print("  ", l)
