#!/usr/bin/env python3
# w1c-plays.py <runs dir> <label>: per-Play summary of a w1c-run.py `plays` run, from w1c-wire.py's <label>.summary.json and <label>.av.csv.
# Window: first sound to 59 s after it (the Pause at 60 s holds the picture while the card's queued sound runs on). Final = median of 49-59 s.
import csv, json, statistics as st, sys
d, label = sys.argv[1], sys.argv[2]
S = json.load(open(f"{d}/{label}.summary.json")); rows = [(float(r["wire_s"]), float(r["offset_ms"])) for r in csv.DictReader(open(f"{d}/{label}.av.csv")) if r["offset_ms"]]
import bisect; ts = [r[0] for r in rows]
out = {"from0": [], "mid": []}
for pl in S["plays"]:
    # the first sound's wire time: find the av row whose offset equals 'first' near... use src: plays carry no wire time, so take onsets from silences
    pass
sil = [s for s in S["silences"] if s[1] >= 240 * 4]
onsets = [s[0] + s[1] / 48000 for s in sil]
for pl, w0 in zip(S["plays"], onsets):
    i = bisect.bisect_left(ts, w0); win = [(t - w0, o) for t, o in rows[i:] if t - w0 < 59]
    fin = st.median([o for t, o in win if t >= 49])
    s2 = max([t for t, o in win if abs(o - fin) > 2] or [0])
    # settled: a 1 s running median of the offset (the bridge's ±2 ms staircase averaged out) within ±2 ms of the final value from then on (the steady state is itself a ±1.5 ms limit cycle)
    sm = [(win[k][0], st.median(o for _, o in win[max(0, k - 30):k + 30])) for k in range(len(win))]
    s1 = max([t for t, o in sm if abs(o - fin) > 2] or [0])
    band = [o for t, o in win if t >= 30]
    big = [j for j in pl["jumps"]]
    kind = "from0" if pl["from0"] else "mid"
    out[kind].append(dict(n=pl["n"], first=pl["first"], jumps=big, s2=s2, s1=s1, fin=fin, lo=min(band), hi=max(band), sil=pl["silences"],
                          pic=pl["picture_seq"][:4], pev=[e for e in pl["picture_events"] if e[0] < 59]))
for k, L in out.items():
    if not L: continue
    nj = sum(1 for p in L if p["jumps"]); js = [j[1] / 48 for p in L for j in p["jumps"] if j[1] is not None]; jt = [j[0] for p in L for j in p["jumps"]]
    print(f"{label} {k}: {len(L)} Plays · first sound {min(p['first'] for p in L):+.1f} to {max(p['first'] for p in L):+.1f} ms (median {st.median(p['first'] for p in L):+.1f})"
          f" · Plays with a jump ≥1 ms: {nj}" + (f" ({min(js):+.1f} to {max(js):+.1f} ms, at {min(jt):.2f}–{max(jt):.2f} s)" if js else "")
          + f" · settled ±2 ms at {min(p['s2'] for p in L):.1f}–{max(p['s2'] for p in L):.1f} s (median {st.median(p['s2'] for p in L):.1f}), settled (1 s median within ±2 ms of final) at median {st.median(p['s1'] for p in L):.1f} s, max {max(p['s1'] for p in L):.1f}"
          f" · final {min(p['fin'] for p in L):+.2f} to {max(p['fin'] for p in L):+.2f} ms · 30–59 s band {min(p['lo'] for p in L):+.2f} to {max(p['hi'] for p in L):+.2f}"
          f" · silences ≥5 ms after first sound: {sum(len(p['sil']) for p in L)} · picture events before 59 s: {sum(len(p['pev']) for p in L)}")
    print("   settled at (s, sorted): " + " ".join(f"{p['s1']:.1f}" for p in sorted(L, key=lambda p: p['s1'])))
    clean = sum(1 for p in L if all(b - a == 1 for a, b in zip(p["pic"], p["pic"][1:])))
    print(f"   picture's first 4 moving frames +1 each: {clean} of {len(L)}; " + "; ".join(f"#{p['n']} {p['pic']}" for p in L if not all(b - a == 1 for a, b in zip(p['pic'], p['pic'][1:])))[:600])
    for p in L:
        if p["pev"]: print(f"   #{p['n']} picture events {p['pev']}")
