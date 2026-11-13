#!/usr/bin/env python3
# Stage 2, method S (docs/CARD_CLOCK_FINDINGS.md §10.27–§10.28): the Mac's sound against the SDI picture from the build's own timestamps.
#   w2-soft.py <run.log> [--events]
# Reads the [W2] lines (one per 100 ms tick: host h, content heard m, content on the wire w, e = m − (w + K), ρ, integrator, state), the
# card's rate against the host ([CARDLOCK] card … ppm), every start, coarse write, timeout, flush, integrator reset and renderer move, and
# each <run>.<n>.devclock beside the log (the output device's sample clock against the host, its latencies, gaps and overloads).
#   Steady segments: contiguous "steer" ticks; from 2 min into each segment of at least 3 min, e's p1–p99 spread, steps over 0.05 ms
#   between ticks, drift (least-squares slope × duration), and mean ρ − 1 against −(device − card) from devclock.
#   The tick-to-tick steps carry the synchronizer read's noise (m: 9–23 µs rms, w: 1–2 µs; §10.29), so steps are also counted between
#   1-s medians (10 ticks), which is the measure of the sound moving.
#   --events: for each [TRANSPORT] step and each [SLIP-TEST] injection, e at the first steering tick 2 s or more after it, the last tick before it, and that delay.
import glob, math, os, re, statistics, sys

def pct(xs, p):
    xs = sorted(xs); k = (len(xs) - 1) * p / 100; f = math.floor(k); c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)

def slope(xs, ys):
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx if sxx else float("nan")

def devclock(path):
    pts, lat, gaps, ovl, name = [], [], 0, 0, "?"
    for l in open(path, errors="replace"):
        if l.startswith("# device"): name = l[9:].split(" uid ")[0].strip()
        elif l.startswith("# latency"): lat.append(l.split(None, 3)[3].strip())
        elif l.startswith("# gap"):   # before the S0 fix, ±5-frame timestamp wobbles were logged as gaps too: only a half buffer counts
            off = float(l.rsplit("(", 1)[1].split()[0]); gaps += abs(off) >= 256
        elif l.startswith("# overload"): ovl += 1
        elif l[0].isdigit():
            h, st, _ = l.split(); pts.append((float(h), float(st)))
    if len(pts) < 10: return None
    xs = [h - pts[0][0] for h, _ in pts]; ys = [st - pts[0][1] for _, st in pts]
    ppm = (slope(xs, ys) / 48000 - 1) * 1e6
    return dict(name=name, ppm=ppm, span=xs[-1], lat=lat, gaps=gaps, ovl=ovl, t0=pts[0][0], t1=pts[-1][0])

def main(path, events):
    W = re.compile(r"\[W2\] h (\S+) m (\S+) w (\S+) e (\S+) ms rho (\S+) i (\S+) ef (\S+) ms pic (\S+) out (\S+) line (\d+) (.*)$")
    ticks, cards, lines, trans, slips = [], [], [], [], []
    for l in open(path, errors="replace"):
        m = W.match(l)
        if m:
            h, mm, w, e, rho, i, ef, pic, out, line, st = m.groups()
            ticks.append(dict(h=float(h), m=float(mm), w=float(w), e=float(e), rho=float(rho), i=float(i), pic=float(pic), line=int(line), st=st.strip()))
            continue
        c = re.match(r"\[CARDLOCK\] card ([+-]\S+) ppm", l)
        if c: cards.append(float(c[1])); continue
        t = re.match(r"\[TRANSPORT\] (.+?) host (\S+) clock", l)
        if t: trans.append((float(t[2]), t[1])); continue
        sl = re.match(r"\[SLIP-TEST\] .* at clock (\S+)", l)
        if sl: slips.append(l.rstrip())
        if any(k in l for k in ("[CARDLOCK] Stage 2", "[SLIP-TEST]", "picture line #", "re-anchored to the SDI picture", "[AUDIO-FLUSH]", "audio renderer on its own clock",
                                "audio renderer back on the picture clock", "[DRV] defout")):
            lines.append(l.rstrip())
    print(f"== {os.path.basename(path)}: {len(ticks)} [W2] ticks")
    states = {}
    for t in ticks: states[t["st"]] = states.get(t["st"], 0) + 1
    print("states: " + ", ".join(f"{k} {v}" for k, v in sorted(states.items(), key=lambda kv: -kv[1])))
    card = statistics.fmean(cards) if cards else float("nan")
    print(f"card against host: {card:+.3f} ppm (mean of {len(cards)} [CARDLOCK] card lines" + (f", {min(cards):+.2f} to {max(cards):+.2f})" if cards else ")"))
    devs = [d for d in (devclock(p) for p in sorted(glob.glob(path[:-4] + ".*.devclock"))) if d]
    for d in devs:
        print(f"devclock {d['name']}: {d['ppm']:+.3f} ppm against host over {d['span']:.0f} s → against the card {d['ppm'] - card:+.3f} ppm; "
              f"gaps {d['gaps']}, overloads {d['ovl']}; latency {' | '.join(dict.fromkeys(d['lat']))}")
    starts = [l for l in lines if "starts with the SDI picture" in l or "starts " in l and "into the SDI picture" in l]
    counts = {k: sum(k in l for l in lines) for k in ("starts with the SDI picture", "into the SDI picture's run", "stopped with the SDI picture", "no SDI picture line",
                                                       "re-anchored to the SDI picture:", "(a slip)", "[SLIP-TEST]", "picture line #", "integrator reset", "[AUDIO-FLUSH]",
                                                       "audio renderer on its own clock", "audio renderer back on the picture clock")}
    print("counts: " + ", ".join(f"{k}: {v}" for k, v in counts.items()))
    lags = [float(m[1]) for m in (re.search(r", ([\d.]+) ms after Play", l) for l in starts) if m]
    if lags: print(f"Play → Mac sound start (the wire's lag): n {len(lags)}, median {statistics.median(lags):.1f} ms, {min(lags):.1f} to {max(lags):.1f}")
    late = [float(m[1]) for m in (re.search(r"starts ([\d.]+) ms into", l) for l in starts) if m]
    if late: print(f"late starts: {', '.join(f'{x:.1f}' for x in late)} ms")
    stops = [float(m[1]) for m in (re.search(r"stopped with the SDI picture, ([\d.]+) ms after", l) for l in lines) if m]
    if stops: print(f"Pause → Mac sound stop: n {len(stops)}, {', '.join(f'{x:.1f}' for x in stops)} ms")
    # steady segments
    segs, cur = [], []
    for t in ticks:
        if t["st"] == "steer" and (not cur or t["h"] - cur[-1]["h"] < 0.5): cur.append(t)
        else:
            if cur: segs.append(cur)
            cur = [t] if t["st"] == "steer" else []
    if cur: segs.append(cur)
    for s in segs:
        dur = s[-1]["h"] - s[0]["h"]
        line = f"segment {s[0]['h']:.1f}–{s[-1]['h']:.1f} ({dur:.0f} s, {len(s)} ticks)"
        if dur < 180: print(line + ": under 3 min, first-2-s e " + ", ".join(f"{t['e']:+.3f}" for t in s[:3]) + " ms"); continue
        st = [t for t in s if t["h"] >= s[0]["h"] + 120]
        es = [t["e"] for t in st]; hs = [t["h"] for t in st]
        steps = [(b["h"], b["e"] - a["e"]) for a, b in zip(st, st[1:]) if abs(b["e"] - a["e"]) > 0.05]
        meds = [statistics.median(t["e"] for t in st[k:k + 10]) for k in range(0, len(st) - 9, 10)]
        msteps = [b - a for a, b in zip(meds, meds[1:])]
        dr = slope(hs, es) * (hs[-1] - hs[0])
        rho = statistics.fmean(t["rho"] for t in st) - 1
        lag = statistics.median(t["pic"] - t["w"] for t in st)
        print(line + f": after 2 min e median {statistics.median(es):+.4f} ms, p1–p99 {pct(es,1):+.4f}…{pct(es,99):+.4f} (spread {pct(es,99)-pct(es,1):.4f} ms), "
              f"max |e| {max(abs(x) for x in es):.4f}, steps > 0.05 ms {len(steps)}" + (f" (first at {steps[0][0]:.1f}: {steps[0][1]:+.3f})" if steps else "")
              + f"; 1-s medians: steps > 0.05 ms {sum(abs(x) > 0.05 for x in msteps)}, max |Δ| {max(abs(x) for x in msteps):.4f} ms"
              + f", drift {dr:+.4f} ms; ρ − 1 {rho * 1e6:+.3f} ppm" + "".join(f" (−(device − card) {-(d['ppm'] - card):+.3f})" for d in devs[:1])
              + f"; picture clock − wire {lag * 1e3:.1f} ms")
        # 1c baseline (no steering): the raw m − w
    raw = [t for t in ticks if t["st"] == "1c" and math.isfinite(t["w"])]
    if raw:
        d = [(t["h"], (t["m"] - t["w"]) * 1e3) for t in raw]
        jumps = [(h2, y2 - y1) for (h1, y1), (h2, y2) in zip(d, d[1:]) if abs(y2 - y1) > 5 and h2 - h1 < 0.5]
        runs = []; start = 0
        for k in range(1, len(d)):
            if abs(d[k][1] - d[k - 1][1]) > 5 or d[k][0] - d[k - 1][0] > 0.5: runs.append(d[start:k]); start = k
        runs.append(d[start:])
        longest = max(runs, key=len)
        print(f"1c m − w: median {statistics.median(y for _, y in d):+.2f} ms, range {min(y for _, y in d):+.2f}…{max(y for _, y in d):+.2f}; "
              f"ramp {slope([h for h, _ in longest], [y for _, y in longest]) * 60:+.3f} ms/min over the longest stretch ({longest[-1][0]-longest[0][0]:.0f} s); "
              f"steps over 5 ms {len(jumps)}: " + ", ".join(f"{h:.0f}: {j:+.2f}" for h, j in jumps[:10]))
    if events:
        steer = [t for t in ticks if t["st"] == "steer"]
        for h, what in trans:
            before = [t for t in ticks if t["h"] < h and t["st"] == "steer"][-1:]
            after = [t for t in steer if t["h"] >= h + 2.0][:1]
            first = [t for t in steer if t["h"] > h][:1]
            nxt = [t for t in trans if t[0] > h][:1]
            ok = after and (not nxt or after[0]["h"] < nxt[0][0])
            print(f"  {what:<14} at {h:.3f}: e before {before[0]['e']:+.3f}" if before else f"  {what:<14} at {h:.3f}: e before —", end="")
            print(f" · first steer tick +{first[0]['h'] - h:.2f} s" if first else " · no steer tick after", end="")
            print(f" · e at +2 s {after[0]['e']:+.3f} ms" if ok else " · (no steer tick 2 s after before the next step)")
    if events and slips:
        ph = re.compile(r"picture line #(\d+)")
        for l in lines:
            if "(a slip)" in l or "[SLIP-TEST]" in l or ("picture line #" in l and "#1:" not in l): print("  " + l[:200])
        steer = [t for t in ticks if t["st"] == "steer"]
        slipt = [t for t in ticks if t["st"] == "slip"]
        for t in slipt:
            after = [u for u in steer if u["h"] >= t["h"] + 2.0][:1]
            later = [u for u in steer if u["h"] >= t["h"] + 10.0][:1]
            print(f"  slip write at {t['h']:.3f}: e at the write {t['e']:+.3f} ms" + (f", +2 s {after[0]['e']:+.3f}" if after else "") + (f", +10 s {later[0]['e']:+.3f} ms" if later else ""))
    for l in lines:
        if "re-anchored" in l or "no SDI picture line" in l or "integrator reset" in l: print("  " + l)

if __name__ == "__main__":
    main(sys.argv[1], "--events" in sys.argv)
