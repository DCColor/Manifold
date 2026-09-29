import sys
import os
sys.path.insert(0, os.environ.get('AVSYNC_DIR', os.path.expanduser('~/Desktop/manifold-avsync')))
import numpy as np
from avsync import frame_luma, flash_times, audio, beep_times, FIXTURE_OFFSET_MS
for p in sys.argv[1:]:
    t, y = frame_luma(p); ft = flash_times(t, y); x, fs = audio(p); bt, e, thr = beep_times(x, fs)
    fps = 1 / np.median(np.diff(t))
    # split at loop gaps
    cuts = np.where(np.abs(np.diff(bt) - 1.0) > 0.1)[0]
    segs = np.split(bt, cuts + 1)
    gaps = x[np.concatenate([np.arange(int((b+.1)*fs), int((b+.9)*fs)) for b in bt if (b+.9)*fs < len(x)])]
    lvl = 20*np.log10(np.sqrt(np.mean(gaps**2))+1e-12)
    print(f'== {p.split("/")[-1]}  {fps:.0f} fps  beeps {len(bt)} flashes {len(ft)}  loop gaps {[round(float(d),3) for d in np.diff(bt)[cuts]]}  level between beeps {lvl:.0f} dB')
    allp = []
    for s in segs:
        if len(s) < 5: continue
        res = ((s - s[0]) + 0.5) % 1.0 - 0.5
        d = []
        for b in s:
            j = np.argmin(np.abs(ft - b)); dd = b - ft[j]
            if abs(dd) < 0.45: d.append(dd*1000 - FIXTURE_OFFSET_MS)
        d = np.array(d); allp += list(d)
        print(f'   seg {s[0]:6.1f}-{s[-1]:6.1f}s  n={len(d):3d}  grid max|res| {np.abs(res).max()*1000:.2f} ms  median {np.median(d):+7.1f}  mean {d.mean():+7.1f}  sd {d.std():4.1f}  levels {sorted(set(np.round(d,0)))[:6]}')
    allp = np.array(allp); print(f'   ALL  median {np.median(allp):+.1f}  mean {allp.mean():+.1f}  sd {allp.std():.1f}')
