#!/usr/bin/env python3
"""`[AV-CONTENT]` lines (DEBUG builds): flash-beep CONTENT A/V on Manifold's own timestamps, which
`[AV-LAG]` (timestamps only) cannot see. Each flash is paired with the nearest beep within ±0.45 s.
  decoded    beep(in) − flash PTS: the content A/V as decoded, on the stream's own PTS (compare
             probe_av.py on the same file)
  out−in     beep(out) − beep(in): the resampler's OUTPUT axis against its input. Not a content
             shift: the output axis carries the ratio's integral by design, and `audio−now` is
             already on content time (FrameEngine.liveAudioDrift)
  choice     now − flash PTS at the first tick that shows the flash
  glass      beep heard − flash on glass, host time: beep(in) − (now + audio−now) − tick→glass,
             content time throughout; tick→glass is the median of the log's [AV-LAG] lines
Positive = the sound comes after the picture. Medians over pairs after the first 60 s.
Usage: avcontent.py <manifold.log> [skip seconds, default 60]"""
import re, sys, statistics as st
path = sys.argv[1]; skip = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
fl, bi, bo, glass = [], [], [], []
for l in open(path, errors='replace'):
    if '[AV-CONTENT] flash' in l:
        m = re.search(r'pts=([\d.]+) tick=([\d.]+) now=([\d.]+) audio−now=([+-][\d.]+) ms', l)
        fl.append(tuple(float(x) for x in m.groups()))
    elif '[AV-CONTENT] beep in' in l:
        bi.append(float(re.search(r'pts=([\d.]+)', l).group(1)))
    elif '[AV-CONTENT] beep out' in l:
        bo.append(float(re.search(r'pts=([\d.]+)', l).group(1)))
    elif '[AV-LAG]' in l:
        glass.append(float(re.search(r'tick→glass=([+-][\d.]+) ms', l).group(1)))
g = st.median(glass) / 1e3 if glass else 0.0
def near(xs, t):
    c = min(xs, key=lambda b: abs(b - t)) if xs else None
    return c if c is not None and abs(c - t) < 0.45 else None
t0 = fl[0][0] if fl else 0
rows = []
for pts, tick, now, a in fl:
    if pts - t0 < skip: continue
    i, o = near(bi, pts), near(bo, pts)
    if i is None or o is None: continue
    rows.append(((i - pts) * 1e3, (o - i) * 1e3, (now - pts) * 1e3, (i - (now + a / 1e3) - g) * 1e3))
print(f"{path.rsplit('/', 1)[-1]}: flashes {len(fl)}, beeps in {len(bi)} / out {len(bo)}, pairs used {len(rows)}; "
      f"tick→glass median {g*1e3:+.2f} ms over {len(glass)} [AV-LAG] lines")
if rows:
    for k, name in enumerate(('decoded', 'out−in', 'choice', 'glass')):
        v = [r[k] for r in rows]
        print(f"  {name:9s} mean {st.mean(v):+7.2f}  median {st.median(v):+7.2f} ms   p10 {sorted(v)[len(v)//10]:+7.2f}   p90 {sorted(v)[9*len(v)//10]:+7.2f}")
