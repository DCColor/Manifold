#!/usr/bin/env python3
"""Criterion 12 for step 8. Uses avsync.py's own detectors (gated) and adds:
  - the two gates avsync does not print: one burst per beep (300 ms), level between beeps;
  - 'as written': mean over the largest whole number of 23.976 frame-grid periods (41.708 s),
    plus the plain median;
  - 'grid-corrected': fit d_k = m - u_k, u_k = (phi - s*t_k) mod T, T = 1001/24000 s, the
    sender's render-grid delay of the whole-second flash; m is the offset with zero grid delay.
Usage: c12.py <capture.mov> [--file]   (--file: a disk-playback control, no sender grid)"""
import sys
import os
sys.path.insert(0, os.environ.get('AVSYNC_DIR', os.path.expanduser('~/Desktop/manifold-avsync')))
import numpy as np
from avsync import frame_luma, flash_times, audio, beep_times, FIXTURE_OFFSET_MS

T = 1001 / 24000.0
PERIOD = 1.0 / abs(round(1.0 / T) - 1.0 / T)   # 1 / 0.024 = 41.67 s

def analyse(path, is_file):
    t, y = frame_luma(path)
    ft = flash_times(t, y)
    x, fs = audio(path)
    bt, e, thr = beep_times(x, fs)
    dur = len(x) / fs
    # gates as avsync
    frac = (bt - bt[0]) % 1.0
    ph = np.median(np.where(frac > 0.5, frac - 1.0, frac))
    res = ((bt - bt[0] - ph + 0.5) % 1.0) - 0.5
    g_count = (len(bt) - dur) < 0.10 * dur
    g_grid = np.median(np.abs(res)) < 0.015 and np.abs(res).max() < 0.060
    # one burst per beep: any 1 kHz energy crossing a lower threshold 60-300 ms after an onset
    hop = int(0.002 * fs)
    doubled = 0
    for b in bt:
        i0, i1 = int((b + 0.060) * fs / hop), int((b + 0.300) * fs / hop)
        if i1 < len(e) and np.any(e[i0:i1] > 0.5 * thr):
            doubled += 1
    # level between beeps: 100-900 ms after each onset
    gaps = np.concatenate([x[int((b + 0.1) * fs):int((b + 0.9) * fs)] for b in bt if (b + 0.9) * fs < len(x)])
    rms_db = 20 * np.log10(np.sqrt(np.mean(gaps ** 2)) + 1e-12)
    pk_db = 20 * np.log10(np.max(np.abs(gaps)) + 1e-12)
    # pairs, keeping the beep time
    P = []
    for b in bt:
        j = np.argmin(np.abs(ft - b))
        d = b - ft[j]
        if abs(d) < 0.45:
            P.append((b, d * 1000.0 - FIXTURE_OFFSET_MS))
    P = np.array(P)
    tb, d = P[:, 0], P[:, 1]
    out = dict(dur=dur, beeps=len(bt), flashes=len(ft), pairs=len(d), g_count=g_count, g_grid=g_grid,
               grid_med_res_ms=np.median(np.abs(res)) * 1000, doubled=doubled, gap_rms_db=rms_db, gap_pk_db=pk_db,
               median=np.median(d), sd=d.std())
    nper = int((tb[-1] - tb[0]) // PERIOD)
    if nper >= 1:
        sel = (tb >= tb[0]) & (tb < tb[0] + nper * PERIOD)
        out.update(mean_whole=d[sel].mean(), nper=nper, n_whole=int(sel.sum()))
    else:
        out.update(mean_whole=d.mean(), nper=0, n_whole=len(d))
    # flash run length in captured frames (display phase bracket, file control)
    hi = y > np.median(y) + 0.25 * (y.max() - np.median(y))
    runs, n = [], 0
    for v in hi:
        if v: n += 1
        elif n: runs.append(n); n = 0
    out.update(runs={k: runs.count(k) for k in sorted(set(runs))})
    if not is_file:
        # sender grid: mean delay of a CAUGHT flash over whole periods = 40/2 ms exactly
        out.update(gridfree=out['mean_whole'] + 20.0)
        # sensitivity: every whole-period window start
        if nper >= 1:
            ms = []
            for t0 in tb[tb <= tb[-1] - nper * PERIOD]:
                sel = (tb >= t0) & (tb < t0 + nper * PERIOD)
                ms.append(d[sel].mean())
            out.update(window_range=f'{min(ms):+.1f} .. {max(ms):+.1f}')
    return out

if __name__ == '__main__':
    r = analyse(sys.argv[1], '--file' in sys.argv)
    for k, v in r.items():
        print(f'{k:16s} {v:.2f}' if isinstance(v, float) else f'{k:16s} {v}')
