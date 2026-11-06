# cardclock-summary.py <dir> <launch label>: every clock against the host, per output session (docs/CARD_CLOCK_FINDINGS.md).
# Rates are least-squares slopes, in ppm, positive = fast. file: [CADENCE] clock while it advances. card (a): pulls × frame
# duration. card (b): completed frames × frame duration over the completion timestamps. card (c): hardware reference clock.
# device: sample time / 48000 from devclock. All over the same host span. Writes <label>-sN.json beside the text output.
import json, re, sys
d, label = sys.argv[1], sys.argv[2]

def slope(xs, ys):
    n = len(xs)
    if n < 3: return float("nan")
    mx, my = sum(xs) / n, sum(ys) / n
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
ppm = lambda s: (s - 1) * 1e6

L = open(f"{d}/{label}.log", errors="replace").read().splitlines()
fps = [float(m[1]) for l in L for m in [re.search(r"FILE source format \S+ @ ([\d.]+) fps", l)] if m]
cad_re = re.compile(r"\[CADENCE\] #(\d+) host (\S+) pts (\S+) swapAgo \S+ clock (\S+)")
cc_re = re.compile(r"\[CARDCLOCK\] n (\d+) result (\d+) host (\S+) hostAfter (\S+) done (\S+) hw (\S+) inFrame (\S+) ticks (\S+)")
dev = []
try:
    for l in open(f"{d}/{label}.dev"):
        f = l.split()
        if len(f) == 3: dev.append((float(f[0]), float(f[1]), float(f[2])))
except FileNotFoundError: pass
begins = [(i, l.split()[-1]) for i, l in enumerate(L) if l.startswith("[DRV] BEGIN")]
ends = [i for i, l in enumerate(L) if l.startswith("[DRV] END")]
print("destination lines:", sum("audio destination is Computer" in l for l in L), "computer ·", sum("PCM · read from the ring" in l for l in L), "PCM to card")
for (b, name), e in zip(begins, ends):
    seg = L[b:e]
    start = [l for l in L[:b] if l.startswith("[CARDCLOCK-REF] start")][-1]
    refs = [l for l in seg if l.startswith("[CARDCLOCK-REF]")]
    frame = None
    m = re.search(r"\(timescale (\d+), frame (\d+)\)", "\n".join(L[:e]))
    if m: frame = int(m[2]) / int(m[1])
    cad = [tuple(map(float, m.groups())) for l in seg for m in [cad_re.match(l)] if m and m[4] != "nan"]
    # playing: the clock advances; drop the first second and everything from where it stops
    pl = [r for p, r in zip(cad, cad[1:]) if r[3] > p[3]]
    if not pl: print(name, "no playing rows"); continue
    t0, t1 = pl[0][1] + 1, pl[-1][1]
    cad = [r for r in cad if t0 <= r[1] <= t1]
    h = [r[1] for r in cad]
    file_ppm = ppm(slope(h, [r[3] for r in cad]))
    a = ppm(slope(h, [r[0] * frame for r in cad]))
    cc = [tuple(map(float, m.groups())) for l in seg for m in [cc_re.match(l)] if m]
    cc = [r for r in cc if t0 <= r[2] <= t1]
    ch = [r[2] for r in cc]
    b_ = ppm(slope([r[4] / 1e9 for r in cc], [r[0] * frame for r in cc])) if cc else float("nan")
    c_ = ppm(slope(ch, [r[5] / 1e9 for r in cc])) if cc else float("nan")
    done_host = ppm(slope(ch, [r[4] / 1e9 for r in cc])) if cc else float("nan")
    dv = [r for r in dev if t0 <= r[0] <= t1]
    dev_ppm = ppm(slope([r[0] for r in dv], [r[1] / 48000 for r in dv])) if len(dv) > 2 else float("nan")
    rs = sum(r[2] for r in dv) / len(dv) if dv else float("nan")
    # wire: picture numbers, unwrapped at 65536
    nums, unread = [], 0
    try:
        for l in open(f"{d}/{name}.marks"):
            f = l.split()
            if len(f) < 4: continue
            n = f[2] if f[2] != "?" else f[3]
            if n == "?": unread += 1; continue
            nums.append(int(n))
    except FileNotFoundError: pass
    while len(nums) > 1 and nums[-1] == nums[-2]: nums.pop()   # capture runs past the file's end: the frozen last picture is not a repeat
    rep = skip = back = missing = 0; slips = []
    for i, (x, y) in enumerate(zip(nums, nums[1:])):
        s = (y - x) % 65536
        if s == 0: rep += 1; slips.append((i, "r"))
        elif s == 1: pass
        elif s > 32768: back += 1
        else: skip += 1; missing += s - 1; slips.append((i, "s"))
    # card input: the source picture handed to each pull ([CADENCE] pts), for runs with no capture to count the wire
    steps = [round((y[2] - x[2]) / frame, 2) for x, y in zip(cad, cad[1:])]
    pull_rep = sum(1 for s_ in steps if abs(s_) < 0.25); pull_skip = sum(1 for s_ in steps if s_ > 1.5)
    span = t1 - t0; f_ = 1 / frame
    wspan = len(nums) * frame
    drift = file_ppm - a
    pred = (wspan or span) * abs(drift) / 1e6 * f_
    late = [l for l in L[b:] if "DeckLink D3: stopped" in l][:1]
    minutes = []
    w = 60.0; t = t0
    while t + w <= t1 + 1:
        r = [x for x in cad if t <= x[1] < t + w]
        q = [x for x in cc if t <= x[2] < t + w]
        if len(r) > 10:
            minutes.append({"t": round(t - t0), "a": ppm(slope([x[1] for x in r], [x[0] * frame for x in r])),
                            "b": ppm(slope([x[4] / 1e9 for x in q], [x[0] * frame for x in q])) if len(q) > 2 else None,
                            "c": ppm(slope([x[2] for x in q], [x[5] / 1e9 for x in q])) if len(q) > 2 else None})
        t += w
    temps = [int(m[1]) for l in refs + [start] for m in [re.search(r" temp (-?\d+) \(hr 0x00000000\)", l)] if m]
    out = dict(session=name, fps=f_, span=span, file=file_ppm, card_a=a, card_b=b_, card_c=c_, done_vs_host=done_host, device=dev_ppm,
               rate_scalar=rs, drift=drift, wire_frames=len(nums), unread=unread, repeats=rep, skips=skip, missing=missing, backs=back,
               predicted=pred, slip_frames=slips[:50], card_counts=late[0].split("— ", 1)[-1] if late else None, ref_start=start,
               minutes=minutes, temps=temps, pull_repeats=pull_rep, pull_skips=pull_skip)
    json.dump(out, open(f"{d}/{name}.json", "w"), indent=0)
    print(f"{name}: span {span:.0f}s · file {file_ppm:+.2f} · card a {a:+.2f} b {b_:+.2f} c {c_:+.2f} · done/host {done_host:+.3f} · device {dev_ppm:+.2f} "
          f"(scalar {rs:.7f}) · wire {len(nums)} read {unread} unread · rep {rep} skip {skip} back {back} · pulls rep {pull_rep} skip {pull_skip} · drift {drift:+.1f} → {pred:.1f}")
    print("  ", start[:260])
    if late: print("  ", late[0][:160])
