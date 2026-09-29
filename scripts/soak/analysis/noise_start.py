#!/usr/bin/env python3
"""Where the soak's 20-min noise segment starts in an Audio Hijack capture, in whole seconds.
The first second that opens a 1200 s span which is noise (≥ 95 % of samples non-silent) for at
least 90 % of its seconds — so a mute inside the segment does not split it, as the naive
"longest run" did on 2026-09-28 (a 4 s pause cut it to 1087 s).
Usage: noise_start.py <capture.wav>   (needs numpy and ffmpeg)"""
import subprocess, sys
import numpy as np
raw = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', sys.argv[1], '-ac', '1',
                      '-ar', '8000', '-f', 'f32le', '-'], capture_output=True, check=True).stdout
x = np.frombuffer(raw, dtype='<f4'); fs = 8000; n = len(x) // fs
noisy = (np.abs(x[:n * fs].reshape(n, fs)) > 1e-4).mean(1) > 0.95
for s in range(n - 1200):
    if noisy[s] and (s == 0 or not noisy[s - 1]) and noisy[s:s + 1200].mean() >= 0.9:
        print(s); break
else:
    sys.exit(f'no 1200 s noise segment found in {n} s')
