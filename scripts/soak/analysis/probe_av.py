#!/usr/bin/env python3
"""Flash/beep A/V of a whole recorded stream on its own timeline (AUDIO_RESAMPLER_DESIGN.md §18.10):
decode once, pair each beep with its flash as c12.py does, report 130 s windows at +180 s and
+1260 s (whole grid periods) and the trend over every whole 41.7 s period. Do NOT cut segments with
stream copy first: a copy cut starts video at a keyframe and audio anywhere, which scrambles the
offset. Needs avsync.py ($AVSYNC_DIR) and numpy (the audible-events venv).
Usage: probe_av.py <file.ts|.mov> [window start s …, default 180 1260]"""
import sys, os
sys.path.insert(0, os.environ.get('AVSYNC_DIR', os.path.expanduser('~/Desktop/manifold-avsync')))
import numpy as np
from avsync import frame_luma, flash_times, audio, beep_times, FIXTURE_OFFSET_MS
T = 1001 / 24000.0; PERIOD = 1.0 / abs(round(1.0 / T) - 1.0 / T)
p = sys.argv[1]
t, y = frame_luma(p); ft = flash_times(t, y)
x, fs = audio(p); bt, e, thr = beep_times(x, fs)
print(f"video frames {len(t)}, flashes {len(ft)}; audio {len(x)/fs:.1f} s, beeps {len(bt)}")
P = []
for b in bt:
    j = np.argmin(np.abs(ft - b)); d = b - ft[j]
    if abs(d) < 0.45: P.append((b, d * 1000.0 - FIXTURE_OFFSET_MS))
P = np.array(P); tb, d = P[:, 0], P[:, 1]
print(f"pairs {len(d)}")
def win(a, span=130):
    sel = (tb >= a) & (tb < a + span); tt = tb[sel]
    n = int((tt[-1] - tt[0]) // PERIOD); s2 = (tb >= tt[0]) & (tb < tt[0] + n * PERIOD)
    return d[s2].mean(), n
for a in (list(map(float, sys.argv[2:])) or [180, 1260]):
    m, n = win(a); print(f"window +{a:.0f}–{a+130:.0f} s: mean over {n} whole periods {m:+.2f} ms (grid-corrected {m+20:+.2f})")
# per-period means over the whole file, and their trend
k = np.floor((tb - tb[0]) / PERIOD).astype(int)
pm = np.array([(tb[k == i].mean(), d[k == i].mean()) for i in range(k.max()) if (k == i).sum() >= 35])
b1, b0 = np.polyfit(pm[:, 0], pm[:, 1], 1)
s = sorted((pm[j,1]-pm[i,1])/(pm[j,0]-pm[i,0]) for i in range(len(pm)) for j in range(i+1, len(pm)))
print(f"{len(pm)} whole periods; trend OLS {b1*1e3:+.2f} ppm, Theil–Sen {s[len(s)//2]*1e3:+.2f} ppm → {s[len(s)//2]*1e3*1380/1e3:+.1f} ms over 23 min")
print("period means (every 4th): " + "  ".join(f"{a:.0f}s:{v:+.1f}" for a, v in pm[::4]))
