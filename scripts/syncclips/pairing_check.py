#!/usr/bin/env python3
"""The coded pattern's pairing, offline (AUDIO_RESAMPLER_DESIGN.md §19.3, §19.9). Standard library only.

    python3 scripts/syncclips/pairing_check.py <verify.json>      # from verify.py --json

For each clip, on its MEASURED event timeline (flash pts, beep onsets): shift the beeps by an injected
offset δ — dropping any that leave the clip, as a real capture would — and pair them back with the
matcher below. It must recover δ:
  1. across ±½ of the shortest interval (fine steps);
  2. at a deliberate one-interval mispair: δ = ± each coded interval, where nearest-neighbour pairing
     (shown alongside) pairs every flash with the wrong beep and reports δ − interval;
  3. across the whole ±½ cycle (no alias anywhere inside it);
  4. the same as 3 with ±10 ms of uniform jitter on every beep (a capture's display and audio grid).

THE MATCHER — what calibration mode (stage D) would do: for each index shift s between the flash and
beep sequences, the pairs (f_i, b_{i+s}) give offsets d_i; the coded intervals make every d_i equal
only at the right s. Score = median |d_i − median d| (the spread); keep candidates whose offset is
inside ±½ cycle and that pair at least half the flashes; choose the smallest spread. The MARGIN is the
smallest spread of any WRONG candidate: how far the code is from aliasing.
"""
import json, random, sys, statistics as st


def match(f, b, half_cycle, min_pairs):
    best, wrong = None, []
    for s in range(-(len(b)), len(b)):
        d = [b[i + s] - f[i] for i in range(len(f)) if 0 <= i + s < len(b)]
        if len(d) < min_pairs:
            continue
        m = st.median(d)
        if abs(m) > half_cycle:
            continue
        spread = st.median(abs(x - m) for x in d)
        cand = (spread, m, s, len(d))
        if best is None or cand < best:
            if best is not None:
                wrong.append(best)
            best = cand
        else:
            wrong.append(cand)
    return best, wrong


def nearest(f, b):
    return st.median(min(b, key=lambda x: abs(x - t)) - t for t in f)


def run(clip, jitter=0.0, seed=1):
    f = [e['flash'] for e in clip['events']]
    b0 = [e['beepL'] for e in clip['events']]
    dur = clip['probe']['format_duration']
    C, I = clip['cycle_s'], clip['shortest_s']
    rnd = random.Random(seed)
    worst_err, margin, fails, n = 0.0, float('inf'), [], 0

    def one(delta):
        nonlocal worst_err, margin, n
        b = [t + delta + (rnd.uniform(-jitter, jitter) if jitter else 0) for t in b0]
        b = [t for t in b if 0 <= t <= dur]
        best, wrong = match(f, b, C / 2, len(f) // 2)
        n += 1
        if best is None:
            fails.append((delta, 'no candidate')); return None
        err = best[1] - delta
        worst_err = max(worst_err, abs(err))
        if wrong:
            margin = min(margin, min(w[0] for w in wrong))
        if abs(err) > max(1e-6, jitter):
            fails.append((delta, err))
        return best

    steps = 50
    for k in range(-steps, steps + 1):                      # 1. ±½ shortest interval
        one(k / steps * I / 2)
    mis = []
    period = clip['shortest_s'] / 23                        # one code step, seconds
    for steps_ in (23, 29, 31, 37):                         # 2. one-interval mispairs
        for sign in (+1, -1):
            delta = sign * steps_ * period
            got = one(delta)
            b = [t + delta for t in b0 if 0 <= t + delta <= dur]
            mis.append((delta, got[1] if got else None, nearest(f, b)))
    for k in range(-199, 200):                              # 3. the whole ±½ cycle, inside
        one(k / 400 * C)
    return dict(n=n, worst_err=worst_err, margin=margin, fails=fails, mis=mis)


def main():
    clips = json.load(open(sys.argv[1]))
    ok = True
    for c in clips:
        r = run(c)
        rj = run(c, jitter=0.010)
        good = not r['fails'] and not rj['fails']
        ok &= good
        print(f"{'PASS' if good else 'FAIL'} {c['clip']}: cycle {c['cycle_s']*1e3:.1f} ms, shortest interval "
              f"{c['shortest_s']*1e3:.1f} ms · {r['n']} injected offsets: worst recovery error {r['worst_err']*1e6:.3f} µs, "
              f"wrong-pairing margin {r['margin']*1e3:.1f} ms · with ±10 ms jitter: worst {rj['worst_err']*1e3:.2f} ms, "
              f"margin {rj['margin']*1e3:.1f} ms · failures {len(r['fails'])} / {len(rj['fails'])}")
        print("     one-interval mispairs (injected → coded / nearest-neighbour): " + ' · '.join(
            f"{d*1e3:+.1f} → {g*1e3:+.1f} / {nn*1e3:+.1f} ms" for d, g, nn in r['mis']))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
