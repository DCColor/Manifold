#!/usr/bin/env python3
"""Device check of the starvation hold (§18.16/§18.19) from a capture of Manifold's output.

Usage: devicecheck.py <capture.wav> <manifold.log>
       (an OBS recording: ffmpeg -i rec.mov -vn -ac 2 -c:a pcm_f32le rec.wav first)

Source: the noise-floor reference (ref-nob.ts): a 40 ms beep at 0.4 on every whole second over a
−60 dBFS floor, so the programme never contains digital zero and any exact-zero run is Manifold's.

Per gap between consecutive beeps the programme carries exactly 1000 ms of content, so
    content Δ = (beep interval) − (exact-zero time in it) − 1000 ms
is content skipped (−) or repeated (+) by Manifold in that gap. Per logged event:
- HOLD: zeros ≈ the time held and Δ ≈ −(the resume's logged skip) means the hold landed inside its
  margin and neither write zeroed programme. Zeros beyond the held time with Δ unchanged = the
  renderer idled longer than logged (dry before the hold landed, or a slow restart), nothing lost.
  Zeros beyond it with Δ more negative by the same = a write MUTE over programme (§11.11's ~50 ms).
  Zeros SHORT of the time held = the recorder dropped silence (Audio Hijack does on long gaps).
- CUT / RESIDUAL: Δ ≈ −cut (drop) or +x (insert), zeros 0 (a 10 ms fade, not a mute).
Capture ↔ host: both are real time, so capture = host + c; c is fitted on the first hold (its zero
run's start against the hold's host time) and checked on the others.
"""
import re, struct, sys
import numpy as np

# ── minimal WAV reader (PCM 16/24/32, float 32/64, extensible; RF64) — no scipy/soundfile ──


def read_wav(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:4] not in (b'RIFF', b'RF64') or data[8:12] != b'WAVE':
        raise ValueError(f'{path}: not a WAV file')
    pos, fmt, body = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack('<I', data[pos + 4:pos + 8])[0]
        if cid == b'data' and size == 0xFFFFFFFF:      # RF64 / streaming: data runs to EOF
            size = len(data) - pos - 8
        chunk = data[pos + 8:pos + 8 + size]
        if cid == b'fmt ':
            tag, ch, rate, _, _, bits = struct.unpack('<HHIIHH', chunk[:16])
            if tag == 0xFFFE:                              # extensible: subformat GUID's first 2 bytes
                tag = struct.unpack('<H', chunk[24:26])[0]
            fmt = (tag, ch, rate, bits)
        elif cid == b'data':
            body = chunk
        pos += 8 + size + (size & 1)
    if fmt is None or body is None:
        raise ValueError(f'{path}: no fmt or data chunk')
    tag, ch, rate, bits = fmt
    if tag == 3:
        x = np.frombuffer(body, dtype='<f4' if bits == 32 else '<f8').astype(np.float64)
    elif tag == 1 and bits == 16:
        x = np.frombuffer(body, dtype='<i2') / 32768.0
    elif tag == 1 and bits == 32:
        x = np.frombuffer(body, dtype='<i4') / 2147483648.0
    elif tag == 1 and bits == 24:
        b = np.frombuffer(body[:len(body) // 3 * 3], dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        x = np.where(v >= 1 << 23, v - (1 << 24), v) / 8388608.0
    else:
        raise ValueError(f'{path}: unsupported format tag {tag}, {bits} bit')
    n = len(x) // ch
    return rate, x[:n * ch].reshape(n, ch)


cap, log = sys.argv[1], sys.argv[2]
sr, x = read_wav(cap)
a = np.abs(x).max(axis=1)

# ── beep onsets: first sample ≥ ¼ of the capture's beep level after ≥ 0.3 s with none. Relative, not
# absolute: the OBS recorder's level is not guaranteed (AV_SYNC_FINDINGS.md §1.2: ~19 dB low once). ──
level = np.percentile(a, 99.99)
loud = np.flatnonzero(a >= 0.25 * level)
onsets = []
last = -10 ** 9
for i in loud:
    if i - last > 0.3 * sr: onsets.append(i)
    last = i
onsets = np.array(onsets)
# ── exact-zero runs ≥ 1 ms, all channels ──
z = (a == 0).astype(np.int8)
d = np.diff(np.concatenate(([0], z, [0])))
starts, ends = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
keep = (ends - starts) >= sr // 1000
zruns = list(zip(starts[keep], ends[keep]))
def zeros_in(lo, hi):
    return sum(max(0, min(e, hi) - max(s, lo)) for s, e in zruns) / sr

# ── the log's events ──
ev = []
for l in open(log, errors='replace'):
    if 'STARVATION HOLD #' in l:
        m = re.search(r'#(\d+) at host ([\d.]+) s', l); ev.append(('HOLD', float(m[2]), int(m[1]), l))
    elif 'STARVATION RESUME #' in l:
        m = re.search(r'at host ([\d.]+) s after (\d+) ms held.*?\(([+-][\d.]+) ms from the held point\)', l)
        ev.append(('RESUME', float(m[1]), (int(m[2]) / 1000, float(m[3]) / 1000), l))
    elif 'RECOVERY DROP #' in l:
        m = re.search(r'at host ([\d.]+) s: \d+ fr / ([\d.]+) ms forward.*?heard ≈ ([\d.]+) s', l)
        ev.append(('CUT', float(m[1]) + float(m[3]), float(m[2]) / 1000, l))
    elif 'RESIDUAL SPLICE at' in l:
        m = re.search(r'at host ([\d.]+) s: (DROP|INSERT) \d+ fr / ([\d.]+) ms.*?renderer queue ([\d.]+) ms', l)
        s = 1 if m[2] == 'DROP' else -1
        ev.append(('RESIDUAL', float(m[1]) + float(m[4]) / 1000, s * float(m[3]) / 1000, l))
holds = [e for e in ev if e[0] == 'HOLD']
resumes = [e for e in ev if e[0] == 'RESUME']
print(f"{cap.rsplit('/', 1)[-1]}: {len(x) / sr:.1f} s @ {sr} Hz · {len(onsets)} beeps · "
      f"{len(zruns)} exact-zero runs ≥ 1 ms · log: {len(holds)} holds, "
      f"{sum(e[0] == 'CUT' for e in ev)} cuts, {sum(e[0] == 'RESIDUAL' for e in ev)} residual")
if not holds or len(onsets) < 3:
    sys.exit("nothing to check (no hold in the log, or no beeps in the capture)")

# Every beep gap, with its zeros and content Δ.
gaps = []
for b0, b1 in zip(onsets[:-1], onsets[1:]):
    iv = (b1 - b0) / sr
    zz = zeros_in(b0, b1)
    gaps.append((b0 / sr, b1 / sr, iv, zz, iv - zz - 1.0))
odd = [g for g in gaps if abs(g[4]) > 0.002 or g[3] > 0]

# c from the first hold: the longest zero run near the first odd gap with zeros.
first = next((g for g in odd if g[3] > 0.02), None)
if first is None:
    sys.exit("no zero run ≥ 20 ms in the capture: the held silence was not recorded (see the header)")
s0 = max((r for r in zruns if first[0] * sr <= r[0] < first[1] * sr), key=lambda r: r[1] - r[0])
c = s0[0] / sr - holds[0][1]
print(f"capture = host {c:+.3f} s (first hold's zero run at {s0[0] / sr:.3f} s in the capture)\n")

print("event | host s | capture s | logged | beep gap: zeros ms | content Δ ms | reading")
for k, h in enumerate(holds):
    r = next((e for e in resumes if e[1] >= h[1]), None)
    held, skip = r[2] if r else (float('nan'), 0.0)
    t = h[1] + c
    g = next((g for g in gaps if g[0] - 0.05 <= t < g[1]), None)
    if g is None:
        print(f"HOLD #{h[2]} | {h[1]:.3f} | {t:.3f} | held {held * 1000:.0f} ms | no beep gap found"); continue
    # a hold longer than a beep gap spans several: sum them
    span = [x for x in gaps if x[0] < t + held + 0.2 and x[1] > t - 0.05]
    zz = sum(x[3] for x in span); dd = sum(x[4] for x in span)
    runs = [(s / sr, (e - s) / sr) for s, e in zruns if span[0][0] * sr <= s < span[-1][1] * sr]
    lost = dd - (-skip)                  # beyond the resume's logged skip
    extra = zz - held
    if extra < -0.010: reading = "recorder DROPPED silence: zeros short of the time held"
    elif abs(extra) <= 0.005 and abs(lost) <= 0.003: reading = "CLEAN: held silence only, no content lost, no write mute"
    elif abs(lost) <= 0.003: reading = f"idle {extra * 1000:.0f} ms beyond the held time, no content lost"
    elif abs(extra + lost) <= 0.005: reading = f"MUTE: {-lost * 1000:.0f} ms of programme zeroed (write mute)"
    else: reading = f"zeros +{extra * 1000:.0f} ms, content {lost * 1000:+.0f} ms: inspect"
    print(f"HOLD #{h[2]} | {h[1]:.3f} | {t:.3f} | held {held * 1000:.0f} ms, resume skip {skip * 1000:+.1f} | "
          f"{zz * 1000:.0f} ({' + '.join('%.0f@%.2f' % (l * 1000, s) for s, l in runs)}) | {dd * 1000:+.1f} | {reading}")
for kind, host, size, _ in [e for e in ev if e[0] in ('CUT', 'RESIDUAL')]:
    t = host + c
    g = next((g for g in gaps if g[0] - 0.3 <= t < g[1] + 0.3 and abs(g[4] + size) < 0.02), None)
    near = [g for g in gaps if abs(g[0] - t) < 1.5]
    if g:
        ok = abs(g[4] + size) <= 0.003 and g[3] == 0
        print(f"{kind} | {host:.3f} | {t:.3f} | {size * 1000:+.1f} ms | {g[3] * 1000:.0f} | {g[4] * 1000:+.1f} | "
              + ("as logged, no mute" if ok else "size or zeros differ: inspect"))
    else:
        print(f"{kind} | {host:.3f} | {t:.3f} | {size * 1000:+.1f} ms | — | "
              f"{', '.join('%+.1f' % (n[4] * 1000) for n in near) or '—'} | not found in the nearby gaps: inspect")
matched = set()
for e in ev:
    t = e[1] + c
    for i, g in enumerate(gaps):
        if g[0] - 0.3 <= t < g[1] + (e[2][0] if e[0] == 'RESUME' else 0) + 0.3: matched.add(i)
stray = [g for i, g in enumerate(gaps) if (g[3] > 0 or abs(g[4]) > 0.002) and i not in matched]
print(f"\nzeros or content steps with NO logged event near them: {len(stray)}")
for g in stray[:30]:
    print(f"  capture {g[0]:.3f}–{g[1]:.3f} s (host ≈ {g[0] - c:.3f}): zeros {g[3] * 1000:.0f} ms, content {g[4] * 1000:+.1f} ms")
