#!/usr/bin/env python3
# Card drops and late frames against default-output changes (docs/CARD_CLOCK_FINDINGS.md §10.19), from one w1c-defout.py run.
#   w1c-drops.py <runs dir> <label>
# Each `DeckLink D3: !! Dropped|DisplayedLate at frame N` line is dated on the host clock from the run's [CARDCLOCK] lines
# (completed-frame count n → host, once a second; interpolated at the output's frame rate between them). N is the bridge's next index,
# a few frames past the completion that reported it, so a date is good to about 0.1 s. Runs of consecutive frames are grouped, and each
# group is set against the nearest default-output change (`set` lines of <label>.switches) and any `sample` window it falls in (the driver
# suspends the process for 10 s with `sample`).
import bisect, re, sys
d, label = sys.argv[1:3]
cc, drops = [], []
for l in open(f"{d}/{label}.log", errors="replace"):
    m = re.match(r"\[CARDCLOCK\] n (\d+) result \d+ host ([\d.]+)", l)
    if m: cc.append((int(m[1]), float(m[2]))); continue
    m = re.match(r"DeckLink D3: !! (Dropped|DisplayedLate) at frame (\d+)", l)
    if m: drops.append((int(m[2]), m[1]))
if len(cc) < 2: sys.exit("no [CARDCLOCK] lines")
rate = (cc[-1][0] - cc[0][0]) / (cc[-1][1] - cc[0][1])
ns = [n for n, _ in cc]
def host(f):
    i = max(0, min(bisect.bisect_right(ns, f) - 1, len(cc) - 1))
    return cc[i][1] + (f - cc[i][0]) / rate
sets, samples, start = [], [], {}
for l in open(f"{d}/{label}.switches"):
    f = l.split()
    if len(f) >= 4 and f[1] == "set": sets.append((float(f[0]), " ".join(f[3:]).split(" status")[0]))
    elif f[:1] == ["sample"] and f[2] == "start": start[f[1]] = float(f[3])
    elif f[:1] == ["sample"] and f[2] == "end": samples.append((f[1], start.get(f[1], float(f[3])), float(f[3])))
groups = []
for f, kind in sorted(drops):
    if groups and f <= groups[-1][1] + 2: groups[-1][1] = f; groups[-1][2][kind] = groups[-1][2].get(kind, 0) + 1
    else: groups.append([f, f, {kind: 1}])
print(f"{label}: {len(drops)} drops/late in {len(groups)} groups; output changes {len(sets)}; card {rate:.3f} frames/s")
for a, b, k in groups:
    t = host(a)
    near = min(sets, key=lambda s: abs(s[0] - t)) if sets else None
    inside = [n for n, s0, s1 in samples if s0 - 0.5 <= t <= s1 + 0.5]
    what = ", ".join(f"{v} {n.lower()}" for n, v in k.items())
    print(f"   frames {a}-{b} at host {t:.2f} ({what}) · nearest change {near[1] if near else '-'} {t - near[0]:+.2f} s"
          f"{' · inside sample ' + inside[0] if inside else ''}")
for t, dev in sets:
    hit = [g for g in groups if -0.5 <= host(g[0]) - t <= 3.0]
    print(f"   change at {t:.2f} → {dev}: {'drops ' + ', '.join(f'{g[0]}-{g[1]} at {host(g[0]) - t:+.2f} s' for g in hit) if hit else 'no drop within 3 s'}")
