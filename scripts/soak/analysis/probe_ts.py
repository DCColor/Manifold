#!/usr/bin/env python3
"""A received MPEG-TS on its own timestamps (AUDIO_RESAMPLER_DESIGN.md §18.10): audio PTS against the
sample count, video PTS against the frame count, the video step histogram (a 1 ms grid shows as
3780 / 3690 / 3870 ticks instead of 3753.75), and the fitted grid phase `restamp.sh` uses.
Usage: probe_ts.py <file.ts> [fps num/den, default 24000/1001] [samples per AAC frame, default 1024]"""
import sys, subprocess
from collections import Counter
path = sys.argv[1]
num, den = map(int, (sys.argv[2] if len(sys.argv) > 2 else '24000/1001').split('/'))
spf = int(sys.argv[3]) if len(sys.argv) > 3 else 1024
crc = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-copyts', '-i', path, '-map', '0:v:0',
                      '-map', '0:a:0', '-c', 'copy', '-f', 'framecrc', '-'], capture_output=True, text=True, check=True).stdout
a, v = [], []
for l in crc.splitlines():
    if l.startswith('#'): continue
    q = [x.strip() for x in l.split(',')]
    (v if q[0] == '0' else a).append(int(q[2]))
v.sort()
step = 90000 * den / num
ad = [a[i] - a[0] - i * spf * 90000 / 48000 for i in range(len(a))]
vd = [v[i] - v[0] - i * step for i in range(len(v))]
steps = Counter(v[i] - v[i - 1] for i in range(1, len(v)))
print(f"audio: {len(a)} frames over {(a[-1]-a[0])/90000:.1f} s; PTS − sample count: min {min(ad)/90:+.3f} max {max(ad)/90:+.3f} ms")
print(f"video: {len(v)} frames; PTS − frame count: min {min(vd)/90:+.3f} max {max(vd)/90:+.3f} ms, end {vd[-1]/90:+.3f} ms")
print(f"video steps (ticks, nominal {step:.2f}): {steps.most_common(6)}")
res = [(p - v[0]) - round((p - v[0]) / step) * step for p in v]
print(f"video grid phase: origin {v[0] + sum(res)/len(res):.2f} ticks (residual {min(res):+.0f}…{max(res):+.0f})")
