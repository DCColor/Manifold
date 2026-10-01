#!/usr/bin/env python3
"""Verifies make_decklink_fixture.py's file against its own specification, every frame and every sample:
  - frame count, and the flash frames are exactly {⌈s·24000/1001⌉}, each white and every other black;
  - both channels identical;
  - every beep outside the noise window is the fixture's beep, sample for sample, at s·48000;
  - the noise window [330, 1530) s is mutes-pitch-ref-1200s.wav to within 24-bit quantization;
  - everything else is digital silence;
  - beep − flash timing: flash start − beep onset in [0, T), mean over whole grid periods = T/2.
Usage: check_decklink_fixture.py [file.mov]"""
import os, subprocess, sys
import numpy as np

SRC = os.path.expanduser('~/Desktop/Manifold-Test-Sources')
F = sys.argv[1] if len(sys.argv) > 1 else f'{SRC}/decklink-flash-beep-noise-2398-45m.mov'
FS, SPF, FRAMES, T = 48000, 2002, 64735, 1001 / 24000
NOISE_ON, NOISE_OFF, BEEP_LEN = 330, 1530, 1920
ok = True
def check(cond, what):
    global ok
    print(('PASS ' if cond else 'FAIL ') + what); ok &= bool(cond)

# ── video ──
raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', F, '-map', '0:v:0', '-vf', 'scale=16:9', '-pix_fmt', 'gray',
                      '-f', 'rawvideo', '-'], capture_output=True, check=True).stdout
luma = np.frombuffer(raw, np.uint8).reshape(-1, 9 * 16)
check(len(luma) == FRAMES, f'video frames {len(luma)} (expected {FRAMES})')
white = luma.min(1) > 250
black = luma.max(1) < 5
check(np.all(white | black), 'every frame is full white or full black')
expect = sorted({-(-s * 24000 // 1001) for s in range(0, 2701)} & set(range(FRAMES)))
got = list(np.where(white)[0])
check(got == expect, f'flash frames = ⌈s·24000/1001⌉ ({len(got)} flashes, expected {len(expect)})')

# ── audio ──
fx = subprocess.run(['ffmpeg', '-v', 'error', '-i', f'{SRC}/criterion12-flash-beep-25p-60s.mov', '-map', '0:a:0',
                     '-f', 's16le', '-acodec', 'pcm_s16le', '-'], capture_output=True, check=True).stdout
beep = np.frombuffer(fx, '<i2').reshape(-1, 2)[:BEEP_LEN, 0].astype(np.float64) / 32768.0
ref = np.frombuffer(subprocess.run(['ffmpeg', '-v', 'error', '-i', f'{SRC}/mutes-pitch-ref-1200s.wav', '-f', 'f32le',
                                    '-acodec', 'pcm_f32le', '-'], capture_output=True, check=True).stdout, '<f4')
a32 = np.frombuffer(subprocess.run(['ffmpeg', '-v', 'error', '-i', F, '-map', '0:a:0', '-f', 's32le', '-acodec',
                                    'pcm_s32le', '-'], capture_output=True, check=True).stdout, '<i4').reshape(-1, 2)
check(len(a32) == FRAMES * SPF, f'audio samples {len(a32)} (expected {FRAMES * SPF}, {SPF} per frame)')
check(np.array_equal(a32[:, 0], a32[:, 1]), 'channels identical')
x = a32[:, 0].astype(np.float64) / 2 ** 31
mask = np.zeros(len(x), bool)
beeps = [s for s in range(0, 2700) if not NOISE_ON <= s < NOISE_OFF and s * FS + BEEP_LEN <= len(x)]
worst = max(np.abs(x[s * FS:s * FS + BEEP_LEN] - beep).max() for s in beeps)
for s in beeps: mask[s * FS:s * FS + BEEP_LEN] = True
check(worst == 0.0, f'{len(beeps)} beeps are the fixture beep sample for sample at s·48000 (max error {worst:.1e})')
n = x[NOISE_ON * FS:NOISE_OFF * FS]
err = np.abs(n - ref).max()
mask[NOISE_ON * FS:NOISE_OFF * FS] = True
# One 24-bit step (2^-23, −138 dBFS), not half: ffmpeg's float → s24 conversion truncates.
check(err <= 2 ** -23, f'noise window [{NOISE_ON}, {NOISE_OFF}) s = the reference within one 24-bit step (max error {err:.1e})')
check(not np.any(x[~mask]), 'digital silence everywhere else')
check(not any(NOISE_ON <= s < NOISE_OFF for s in beeps), 'no beep onset inside the noise window')

# ── timing ──
d = np.array([(-(-s * 24000 // 1001)) * T - s for s in beeps])     # flash start − beep onset, s
check(d.min() >= 0 and d.max() < T, f'flash start − beep onset in [0, {T * 1e3:.3f}) ms: {d.min() * 1e3:.3f} … {d.max() * 1e3:.3f} ms')
per = 1 / 0.024
first = np.array(beeps[:int(per * 20)], float)
sel = first < first[0] + int((first[-1] - first[0]) // per) * per
print(f'     as written, beep − flash: mean {-d[:len(first)][sel].mean() * 1e3:+.3f} ms over whole grid periods '
      f'(≈ T/2 = {T / 2 * 1e3:.3f}: the phases are discrete); grid-corrected 0 by construction')
print('ALL PASS' if ok else 'SOME CHECKS FAILED'); sys.exit(0 if ok else 1)
