#!/usr/bin/env python3
# w1c-defout-report.py <runs dir> <label>: each default-output change of a w1c-defout.py run against SDI audio and the picture (§10.17).
# Every log line takes the host time of the [CADENCE] pull before it (good to a frame). SDI audio from the bridge's own samples: [AUDIO-CORR]
# logs every callback that schedules PCM with its card stream position, so a gap in the stream positions is silence the card was given,
# exact to the sample. Picture: the card's pulls ([CADENCE] pts). The pump: [AUDIOWATCH] and the tap lines.
import re, sys
d, label = sys.argv[1], sys.argv[2]
host = None; pcm = []; pulls = []; tr = []; aw = []; tap = []; und = []
for l in open(f"{d}/{label}.log", errors="replace"):
    m = re.match(r"\[CADENCE\] #\d+ host (\S+) pts (\S+)", l)
    if m:
        host = float(m[1])
        if m[2] != "nan": pulls.append((host, float(m[2])))
        continue
    m = re.match(r"\[TRANSPORT\] (\w+).* host (\S+)", l)
    if m: tr.append((float(m[2]), m[1])); continue
    if host is None: continue
    m = re.match(r"\[AUDIO-CORR\] s=(\d+) n=(\d+)", l)
    if m: pcm.append((host, int(m[1]), int(m[2]))); continue
    if l.startswith("[AUDIOWATCH]"): aw.append((host, l.strip())); continue
    m = re.search(r"AudioTap\[\w+\]: int32 .* pts=([\d.]+)s", l)
    if m: tap.append((host, float(m[1]))); continue
    if "UNDERRUN EVENT" in l: und.append((host, l.strip()))
sw = []
for l in open(f"{d}/{label}.defout"):
    f = l.split()
    if len(f) >= 3: sw.append((float(f[0]), " ".join(f[2:])))
SR = 48000
# silences between PCM callbacks
sil = []
for a, b in zip(pcm, pcm[1:]):
    g = b[1] - (a[1] + a[2])
    if g > 0: sil.append((a[0], b[0], g))
pauses = [(h, k) for h, k in tr if k in ("pause", "play")]
def transport_between(a, b): return [f"{k} at {h:.3f}" for h, k in pauses if a - 0.5 <= h <= b + 0.5]
print(f"{label}: PCM callbacks {len(pcm)}, pulls {len(pulls)}, silences between PCM callbacks {len(sil)}")
print("default output changes (host, device):"); [print(f"   {h:.3f} {n}") for h, n in sw]
print("transport:"); [print(f"   {h:.3f} {k}") for h, k in tr]
print("SDI silences over 5 ms (from the bridge's stream positions):")
for a, b, g in sil:
    if g < 240: continue
    near = [f"{n} {a - h:+.2f} s after it" for h, n in sw if 0 <= a - h < 60]
    print(f"   last PCM {a:.3f} → next PCM {b:.3f}: {g} samples = {g / SR:.3f} s · {', '.join(near) or 'no switch in the 60 s before'} · transport in it: {transport_between(a, b) or 'none'}")
print("pull steps other than one frame while playing (host, Δpts):")
fd = 1001 / 60000
mv = [(h, p) for h, p in pulls]
odd = []
for (h0, p0), (h1, p1) in zip(mv, mv[1:]):
    dp = p1 - p0
    if abs(dp - fd) > fd / 2 and dp != 0: odd.append((h1, dp))
for h, dp in odd[:40]: print(f"   {h:.3f} {dp / fd:+.2f} frames")
rep = 0
playing = False; ti = 0; trs = sorted(tr)
for (h0, p0), (h1, p1) in zip(mv, mv[1:]):
    while ti < len(trs) and trs[ti][0] <= h1:
        playing = trs[ti][1] == "play"; play_h = trs[ti][0]; ti += 1
    if playing and p1 == p0 and h1 - play_h > 0.5: rep += 1
print(f"pull repeats while playing (more than 0.5 s after a Play): {rep}")
print("tap gaps over 3 s (the pump's position stopped; the tap line is throttled to about 2 s):")
for (a, pa), (b, pb) in zip(tap, tap[1:]):
    if b - a > 3: print(f"   {a:.3f} (pts {pa:.2f}) → {b:.3f} (pts {pb:.2f}): {b - a:.1f} s")
print("[AUDIOWATCH] lines (ok lines summarised):")
oks = [x for x in aw if "] ok ·" in x[1]]
gaps = [float(re.search(r"longest gap (\S+) s", x[1])[1]) for x in oks]
if gaps: print(f"   ok windows {len(oks)}, longest gap in any: {max(gaps):.3f} s, median of the windows' longest: {sorted(gaps)[len(gaps) // 2]:.3f} s")
for h, l in aw:
    if "] ok ·" not in l: print(f"   {h:.3f} {l[:900]}")
print("underrun events:"); [print(f"   {h:.3f} {l[:200]}") for h, l in und]
