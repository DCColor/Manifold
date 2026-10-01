#!/usr/bin/env python3
"""The DeckLink-sender soak fixture (README.md, "A realistic sender"): one self-contained file that a
Resolve workstation plays out over SDI. It carries on its own timeline what the sender scene
BLIPS_NOISE produces today, with go.sh's noise schedule baked in.

  video  1920x1080 at 24000/1001, black, with one full-white frame per whole second: the first frame
         whose start is at or after the second. That is the frame BLIPS_NOISE's 23.976 canvas shows the
         25p fixture's flash on today, so c12.py's render-grid model still applies (see "Timing").
  audio  48 kHz stereo, pcm_s24le, summed as OBS sums the two sources at 0 dB:
         - the fixture's beep (1 kHz, 1920 samples, peak 0.4, both channels), taken sample for sample
           from criterion12-flash-beep-25p-60s.mov, with its onset on every whole second;
         - mutes-pitch-ref-1200s.wav (mono) once, copied to both channels at unity gain, as OBS
           upmixes a mono source. The capture of 2026-09-30 reads it at the same −20.8 dBFS RMS on both
           channels as the file;
         - go.sh's schedule: noise from 330 s to 1530 s (all 1200 s), beeps muted while it plays
           (a beep whose onset falls in [330, 1530) is left out); the flashes carry on throughout.
  length 64735 frames = 129,599,470 samples (2002 per frame, exact) ≈ 44:59.99, so a loop joins on a
         frame and a sample boundary.

Timing: each beep is sample-exact on its whole second; each flash is frame-exact on the first frame
boundary at or after it. Grid-corrected, beep − flash is 0. As written it is −(delay of that frame),
0…41.7 ms, mean T/2 = 20.854 ms over whole 41.7 s grid periods.

Usage: make_decklink_fixture.py [out.mov]   (needs numpy and ffmpeg; the audible-events venv has numpy)
Writes ~/Desktop/Manifold-Test-Sources/decklink-flash-beep-noise-2398-45m.mov by default."""
import os, subprocess, sys
import numpy as np

SRC = os.path.expanduser('~/Desktop/Manifold-Test-Sources')
OUT = sys.argv[1] if len(sys.argv) > 1 else f'{SRC}/decklink-flash-beep-noise-2398-45m.mov'
FIXTURE = f'{SRC}/criterion12-flash-beep-25p-60s.mov'
NOISE = f'{SRC}/mutes-pitch-ref-1200s.wav'
FS, SPF = 48000, 2002                 # 48000 × 1001 / 24000 samples per frame, an integer
FRAMES = 64735                        # ⌊2700 s × 24000/1001⌋
SAMPLES = FRAMES * SPF
NOISE_ON, NOISE_OFF = 330, 1530       # soak.mjs T.noiseOn / T.noiseOff
BEEP_LEN = 1920

def pcm(path, ch, fmt):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:a:0', '-ac', str(ch), '-f', fmt,
                          '-acodec', {'s16le': 'pcm_s16le', 'f32le': 'pcm_f32le'}[fmt], '-'],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, {'s16le': '<i2', 'f32le': '<f4'}[fmt]).reshape(-1, ch)

fx = pcm(FIXTURE, 2, 's16le')
assert np.array_equal(fx[:, 0], fx[:, 1]), 'fixture channels differ'
beep = fx[:BEEP_LEN, 0].astype(np.float32) / 32768.0
assert fx[BEEP_LEN:48000, 0].any() == False and fx[:BEEP_LEN, 0].any(), 'fixture beep is not samples 0…1919'
noise = pcm(NOISE, 1, 'f32le')[:, 0]
assert len(noise) == 1200 * FS, f'noise reference is {len(noise)} samples, not {1200 * FS}'

# A frame n is a flash frame when a whole second falls in (start of n−1, start of n]: n = ⌈s·24000/1001⌉.
flash = ('eq(n\\,0)+gt(floor(n*1001/24000)\\,floor((n-1)*1001/24000))')
# Drawn at 8-bit 4:4:4 (drawbox's safe ground on every ffmpeg build), then 10-bit 4:2:2 for ProRes:
# limited-range black 16 → 64 and white 235 → 940 exactly.
video = (f'color=c=black:s=1920x1080:r=24000/1001,format=yuv444p,'
         f"drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='{flash}',format=yuv422p10le,"
         f'setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv')
# (setparams: without it the output options alone left primaries and transfer "unknown" on ffmpeg 8;
#  the first file was fixed by a stream-copy remux, bit-identical streams, 2026-09-30.)
cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
       '-f', 'lavfi', '-i', video,
       '-f', 'f32le', '-ar', str(FS), '-ac', '2', '-i', 'pipe:0',
       '-map', '0:v', '-map', '1:a', '-frames:v', str(FRAMES),
       '-c:v', 'prores_ks', '-profile:v', '0', '-vendor', 'apl0', '-pix_fmt', 'yuv422p10le',
       '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv',
       '-c:a', 'pcm_s24le', '-movflags', '+write_colr', OUT]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
CHUNK = 10 * FS
beeps = [s for s in range(0, SAMPLES // FS + 1) if not NOISE_ON <= s < NOISE_OFF and s * FS + BEEP_LEN <= SAMPLES]
for c0 in range(0, SAMPLES, CHUNK):
    c1 = min(SAMPLES, c0 + CHUNK)
    buf = np.zeros(c1 - c0, np.float32)
    for s in beeps:
        o = s * FS
        if o + BEEP_LEN <= c0 or o >= c1: continue
        a, b = max(o, c0), min(o + BEEP_LEN, c1)
        buf[a - c0:b - c0] += beep[a - o:b - o]
    n0, n1 = max(c0, NOISE_ON * FS), min(c1, NOISE_OFF * FS)
    if n0 < n1: buf[n0 - c0:n1 - c0] += noise[n0 - NOISE_ON * FS:n1 - NOISE_ON * FS]
    p.stdin.write(np.repeat(buf[:, None], 2, axis=1).tobytes())
p.stdin.close()
if p.wait() != 0: sys.exit('ffmpeg failed')
print(f'{OUT}: {FRAMES} frames, {SAMPLES} samples, {len(beeps)} beeps, {os.path.getsize(OUT) / 1e9:.2f} GB')
