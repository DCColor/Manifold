#!/usr/bin/env python3
# A/V offset of a sync clip on the wire (docs/CARD_CLOCK_FINDINGS.md §10.16), from a capture with --audio --marks --luma (w1c-run.py with
# W1C_LUMA=1, or w1c-control.sh). Needs numpy. The clip: scripts/syncclips (59.94: events every 23/29/31/37 × 2 frames from frame 60).
#   w1c-syncclip.py <runs dir> <label> <clip PCM, s32le stereo> [from seconds]
# Each flash frame (row 540 mean Y over 500) is matched to its event frame k; the audio that arrived with that frame is located in the
# clip's own PCM (its −60 dB noise floor is seeded, so 2 samples locate and 32 verify). Offset = (source sample of the frame's first
# received sample − k × 800.8) / 48 ms: positive = the sound is ahead of the picture. As a cross-check independent of the locating, the
# beep's onset on the wire: the first sample over 0.02 full scale, against the flash frame's first sample (the tone's 5 ms raised-cosine
# edge crosses 0.02 about 1.5 ms after the true onset, so this reads about 1.5 ms later than the true offset, never earlier).
import sys
import numpy as np
d, label, refpath = sys.argv[1:4]; t_from = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
SR = 48000; SPF = 48000 * 1001 / 60000; F0, UNIT, C = 60, 2, 240
EV = sorted(F0 + UNIT * a + C * c for c in range(20) for a in (0, 23, 52, 83))
rx = np.fromfile(f"{d}/{label}.raw", dtype="<i4").reshape(-1, 2)[:, 0].copy(); ref = np.fromfile(refpath, dtype="<i4").reshape(-1, 2)[:, 0].copy()
N, M = len(rx), len(ref)
k24 = (ref.astype(np.int64) >> 8) & 0xFFFFFF; keys = (k24[:-1] << 24) | k24[1:]; order = np.argsort(keys, kind="stable"); skeys = keys[order]
def locate(i):
    for k in range(i, min(i + 64, N - 33)):
        key = ((int(rx[k]) >> 8 & 0xFFFFFF) << 24) | (int(rx[k + 1]) >> 8 & 0xFFFFFF)
        lo, hi = np.searchsorted(skeys, key), np.searchsorted(skeys, key, "right")
        for j in order[lo:hi]:
            p = int(j) - (k - i)
            if 0 <= p and p + 32 <= M and np.array_equal(rx[i:i + 32], ref[p:p + 32]): return p
    return None
frames = []; off = 0
for l in open(f"{d}/{label}.marks"):
    f = l.split()
    if not f: continue
    if f[0] == "audio-only":
        if len(f) > 1 and f[1][1:].lstrip("-").isdigit(): off += max(int(f[1][1:]), 0)
        continue
    a = next((int(x[1:]) for x in f if x.startswith("a") and x[1:].lstrip("-").isdigit()), 0)
    y = next((float(x[1:]) for x in f if x.startswith("y")), None)
    frames.append((off, y)); off += max(a, 0)
flashes = [(k, w) for k, (w, y) in enumerate(frames) if y is not None and y > 500 and w >= t_from * SR and (k == 0 or (frames[k - 1][1] or 0) <= 500)]
rows = []
for k, w in flashes:
    s = locate(w)
    if s is None: rows.append((w, None, None, None)); continue
    ev = min(EV, key=lambda e: abs(e * SPF - s))
    seg = np.abs(rx[max(0, w - 2400):w + 2400].astype(np.float64)) / 2**31
    hit = np.flatnonzero(seg > 0.02); onset = (hit[0] + max(0, w - 2400) - w) / 48 if len(hit) else None
    rows.append((w, ev, (s - ev * SPF) / 48, onset))
good = [r for r in rows if r[2] is not None]
print(f"{label}: wire {N / SR:.1f} s, frames {len(frames)}, flash frames from {t_from:.0f} s: {len(flashes)}, located {len(good)}")
for w, ev, o, on in rows:
    print(f"   wire {w / SR:8.3f} s: event frame {ev}, offset {'?' if o is None else f'{o:+.2f}'} ms, beep onset vs the flash frame {'?' if on is None else f'{-on:+.2f}'} ms")
if good:
    o = np.array([r[2] for r in good]); on = np.array([-r[3] for r in good if r[3] is not None])
    print(f"   offset: median {np.median(o):+.2f} ms, min {o.min():+.2f}, max {o.max():+.2f} ({len(o)} flashes); beep onset vs flash: median {np.median(on):+.2f} ms")
