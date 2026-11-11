#!/usr/bin/env python3
# SDI audio on the wire (docs/CARD_CLOCK_FINDINGS.md §10.16), from one w1c-run.py run. Needs numpy (a venv: ~/Code/_scratch/manifold-1c-wire/.venv).
#   w1c-wire.py <runs dir> <label> <fixture .ref.raw> <5994|2398> [cont|plays]
# Every received sample is located in the fixture's own PCM (seeded white noise, so a 2-sample key is all but unique and 16 samples
# verify it). Walking the capture, each place where the received samples stop following the source is classified:
#   step:    the source position moves by d samples (+ skipped, - repeated) and continues;
#   silence: a run of digital zero, with the source position moved by d across it.
# The picture: the 16-bit marker number on each received frame, unwrapped. The A/V offset at a frame is (source position of the frame's
# first received sample − that frame's picture × samples per picture) / 48 in ms: positive = the sound is ahead of the picture.
# [AUDIO-CORR] (the bridge's per-callback log, MANIFOLD_AUDIO_CORR_LOG=1) is matched to the wire: the card's audio stream position s of a
# callback's first sample is wire sample s − s0, s0 fixed from the first sound after each silence (the anchor callback).
import bisect, collections, json, re, sys
import numpy as np
d, label, refpath, ratecode = sys.argv[1:5]; mode = sys.argv[5] if len(sys.argv) > 5 else "cont"
FPS = {"5994": 60000 / 1001, "2398": 24000 / 1001}[ratecode]; SPF = 48000 / FPS; SR = 48000
rx = np.fromfile(f"{d}/{label}.raw", dtype="<i4").reshape(-1, 2)
ref = np.fromfile(refpath, dtype="<i4").reshape(-1, 2)
x0 = np.ascontiguousarray(rx[:, 0]); x1 = np.ascontiguousarray(rx[:, 1]); r0 = np.ascontiguousarray(ref[:, 0])
N, M = len(x0), len(r0)
chan_same = int(np.count_nonzero(x0 != x1))

# Global index: key = two consecutive 24-bit samples.
k24 = (r0.astype(np.int64) >> 8) & 0xFFFFFF
keys = (k24[:-1] << 24) | k24[1:]; order = np.argsort(keys, kind="stable"); skeys = keys[order]; del keys

def verify(i, p, n=16):
    if p < 0 or p + n > M or i + n > N: return False
    return bool(np.array_equal(x0[i:i + n], r0[p:p + n]))
def glocate(i):
    for k in range(i, min(i + 256, N - 1)):
        if x0[k] == 0 or x0[k + 1] == 0: continue
        key = ((int(x0[k]) >> 8 & 0xFFFFFF) << 24) | (int(x0[k + 1]) >> 8 & 0xFFFFFF)
        lo = np.searchsorted(skeys, key); hi = np.searchsorted(skeys, key, "right")
        for j in order[lo:hi]:
            p = int(j) - (k - i)
            if verify(i, p, 32): return p
    return -1
def local(i, exp, W=64, L=16):
    lo = max(0, exp - W); hi = min(M, exp + W + L)
    if hi - lo < L or i + L > N: return -1
    win = np.lib.stride_tricks.sliding_window_view(r0[lo:hi], L)
    hit = np.flatnonzero((win == x0[i:i + L]).all(axis=1))
    if not len(hit):
        # The bridge sometimes runs a callback of only 9-12 samples, with its own correction, so a second discontinuity can fall
        # inside 16 samples. Then 6 samples, within ±8 of where the source was expected (a single 2-sample key is all but unique).
        return local(i, exp, 8, 6) if L == 16 else -1
    c = hit + lo; return int(c[np.argmin(np.abs(c - exp))])
def zero_run(i):
    j = i
    while j < N:
        n = min(1 << 16, N - j); z = (x0[j:j + n] == 0) & (x1[j:j + n] == 0)
        if z.all(): j += n; continue
        return j + int(np.argmin(z))
    return N

segs = []; events = []   # segs: (wire start, source start, length); events: (wire index, kind, d, length)
i = zero_run(0)
if i < N: events.append((0, "silence", 0, i))
p = glocate(i) if i < N else -1
while i < N:
    if p < 0:   # not located: skip to the next silence or 4800 samples on, and try again
        events.append((i, "unlocated", 0, 0)); j = i + 4800
        if j >= N: break
        i = j; p = glocate(i); continue
    j = i
    while j < N:
        n = min(1 << 16, N - j, M - (p + (j - i)))
        if n <= 0: break
        eq = x0[j:j + n] == r0[p + (j - i):p + (j - i) + n]
        if eq.all(): j += n; continue
        j += int(np.argmin(eq)); break
    segs.append((i, p, j - i)); exp = p + (j - i)
    if j >= N or exp >= M: break
    z = zero_run(j)
    if z - j >= 4:   # digital silence
        if z >= N: events.append((j, "silence", 0, z - j)); break
        q = local(z, exp + (z - j), 64)
        if q < 0: q = local(z, exp, 64)
        if q < 0: q = glocate(z)
        events.append((j, "silence", (q - exp) if q >= 0 else None, z - j)); i, p = z, q; continue
    q = local(j, exp)
    if q < 0: q = glocate(j)
    events.append((j, "step", (q - exp) if q >= 0 else None, 0)); i, p = j, q
seg_starts = [s[0] for s in segs]
def src_at(w):
    k = bisect.bisect_right(seg_starts, w) - 1
    if k < 0: return None
    s0, p0, L = segs[k]
    return p0 + (w - s0) if w < s0 + L else None

# Pictures, and the audio each one carried. "audio-only" packets are in the raw stream too.
frames = []; off = 0; prev = None
for l in open(f"{d}/{label}.marks"):
    f = l.split()
    if not f: continue
    if f[0] == "audio-only":
        if len(f) > 1 and f[1][1:].lstrip("-").isdigit(): off += max(int(f[1][1:]), 0)
        continue
    if len(f) < 5: continue   # a line cut short when capture was stopped
    n = f[2] if f[2] != "?" else f[3]; a = next((int(x[1:]) for x in f[5:] if x[:1] == "a" and x[1:].lstrip("-").isdigit()), 0)   # " a<n>", before any " y<luma>"
    m = None
    if n != "?":
        m16 = int(n)
        if prev is None: m = m16
        else: m = prev + ((m16 - prev + 32768) % 65536 - 32768)
        prev = m
    frames.append((off, m)); off += max(a, 0)
fstarts = [f[0] for f in frames]
def offset_ms(w):
    k = bisect.bisect_right(fstarts, w) - 1
    if k < 0 or frames[k][1] is None: return None
    s = src_at(w)
    if s is None: return None
    return (s - (frames[k][1] * SPF + (w - frames[k][0]))) / SR * 1000
av = [(f[0], offset_ms(f[0])) for f in frames]

# Picture events: steps other than +1 between consecutive read frames
pic = []
mv = [(k, f[1]) for k, f in enumerate(frames) if f[1] is not None]
for (ka, a), (kb, b) in zip(mv, mv[1:]):
    if b - a != 1: pic.append((frames[kb][0], kb, a, b))
# grouped: a run of consecutive +0 steps is one hold (n extra wire frames of picture a), then what follows it
runs_ = []
for w, kb, a, b in pic:
    if runs_ and b == a and runs_[-1][4] == "hold" and runs_[-1][2] == a and runs_[-1][5] == kb - 1:
        r = runs_[-1]; runs_[-1] = (r[0], r[1], r[2], r[3], "hold", kb, r[6] + 1)
    else: runs_.append((w, kb, a, b, "hold" if b == a else "step", kb, 1))
pic = [(w, kb, a, b if kind == "step" else a, n) for w, kb, a, b, kind, last, n in runs_]   # (wire, frame, from, to, extra frames held / 1)

# The bridge's per-callback log
corr = []; resync_lines = []
log = open(f"{d}/{label}.log", errors="replace").read()
for x in re.finditer(r"\[AUDIO-CORR\] s=(\d+) n=(\d+) got=(-?\d+) c=(-?\d+) k=(\w) e=(\S+)", log):
    corr.append((int(x[1]), int(x[2]), int(x[4]), x[5], float(x[6])))
for x in re.finditer(r"RESYNC — smoothed error (\S+) ms exceeds \d+ ms; snapping source cursor (\S+)s → (\S+)s", log):
    resync_lines.append((float(x[1]), float(x[2]), float(x[3])))
# s0 from the anchors: the first PCM sample after a silence on the wire is an anchor callback's first sample
onsets = [e[0] + e[3] for e in events if e[1] == "silence" and e[3] >= 240 and e[0] + e[3] < N]
anchors = [c[0] for c in corr if c[3] == "a"]
cand = collections.Counter()
for w in onsets[:50]:
    for s in anchors:
        cand[s - w] += 1
s0 = cand.most_common(1)[0][0] if cand else None
steps = [e for e in events if e[1] == "step"]
wire_steps = {e[0]: e[2] for e in steps}
match = dict(corr_nonzero=0, exact=0, near=0, missing=0, wrong_size=0)
if s0 is not None:
    lo, hi = 0, N
    for s, n, c, k, e in corr:
        w = s - s0
        if w <= 0 or w >= N or k != "c" or c == 0: continue
        match["corr_nonzero"] += 1
        if w in wire_steps:
            if wire_steps[w] == c: match["exact"] += 1
            else: match["wrong_size"] += 1
        elif any((w + dd) in wire_steps for dd in (-2, -1, 1, 2)): match["near"] += 1
        else: match["missing"] += 1
    corr_at = {s - s0: (c, k) for s, n, c, k, e in corr}
    unexplained = [e for e in steps if not (e[0] in corr_at and (corr_at[e[0]][0] != 0 or corr_at[e[0]][1] != "c"))]
else: unexplained = None

# ---- report
T = lambda w: w / SR
print(f"{label}: wire {N} samples ({T(N):.1f} s), frames {len(frames)}, unread marks {sum(f[1] is None for f in frames)}, channels differ at {chan_same} samples")
print(f"  located segments {len(segs)}; events: steps {len(steps)}, silences {sum(e[1] == 'silence' for e in events)}, unlocated {sum(e[1] == 'unlocated' for e in events)}")
sz = collections.Counter(e[2] for e in steps)
print("  step sizes (samples: count): " + ", ".join(f"{k:+d}: {v}" for k, v in sorted(sz.items(), key=lambda kv: (kv[0] is None, kv[0] or 0)) if k is not None and abs(k) <= 8))
big = [e for e in steps if e[2] is None or abs(e[2]) > 8]
for e in big[:60]: print(f"  JUMP at {T(e[0]):.3f} s: {e[2]} samples ({(e[2] or 0) / 48:+.2f} ms)")
if len(big) > 60: print(f"  … {len(big) - 60} more jumps")
for e in [e for e in events if e[1] == "silence"][:80]: print(f"  SILENCE at {T(e[0]):.3f} s: {e[3]} samples ({e[3] / 48:.1f} ms), source moved {e[2]} across it")
for e in [e for e in events if e[1] == "unlocated"][:10]: print(f"  UNLOCATED at {T(e[0]):.3f} s")
print(f"  picture events (step ≠ +1): {len(pic)}")
for w, k, a, b, n in pic[:80]: print(f"    at {T(w):.3f} s (frame {k}): " + (f"{a} held {n} extra frame(s)" if a == b else f"{a} → {b} ({b - a:+d})"))
print(f"  [AUDIO-CORR] callbacks {len(corr)} (c: {sum(c[3] == 'c' for c in corr)}, a: {sum(c[3] == 'a' for c in corr)}, r: {sum(c[3] == 'r' for c in corr)}); "
      f"nonzero steering corrections {sum(1 for c in corr if c[3] == 'c' and c[2] != 0)} of {sum(c[3] == 'c' for c in corr)}; s0 {s0} (from {cand.most_common(1)[0][1] if cand else 0} onsets)")
print(f"  match, corrections inside the capture → wire: {match}; wire steps with no correction at that sample: {None if unexplained is None else len(unexplained)}")
if unexplained: [print(f"    unexplained step at {T(e[0]):.3f} s: {e[2]}") for e in unexplained[:20]]
for r in resync_lines: print(f"  bridge RESYNC: smoothed {r[0]:+.1f} ms, cursor {r[1]:.3f} → {r[2]:.3f} s ({(r[2] - r[1]) * 1000:+.1f} ms)")
out = dict(label=label, N=N, frames=len(frames), steps=len(steps), sizes={str(k): v for k, v in sz.items()}, big=[(T(e[0]), e[2]) for e in big],
           silences=[(T(e[0]), e[3], e[2]) for e in events if e[1] == "silence"], pic=[(T(w), a, b, n) for w, k, a, b, n in pic], match=match,
           unexplained=None if unexplained is None else len(unexplained), corr_callbacks=len(corr),
           corr_nonzero=sum(1 for c in corr if c[3] == "c" and c[2] != 0), corr_steer=sum(c[3] == "c" for c in corr), resyncs=resync_lines)
# Each discontinuity with its time, for the record
with open(f"{d}/{label}.events.csv", "w") as f:
    f.write("wire_s,kind,d_samples,len_samples\n")
    for e in events: f.write(f"{T(e[0]):.6f},{e[1]},{e[2]},{e[3]}\n")
with open(f"{d}/{label}.av.csv", "w") as f:
    f.write("wire_s,picture,offset_ms\n")
    for (w, o), fr in zip(av, frames): f.write(f"{T(w):.6f},{fr[1]},{'' if o is None else f'{o:.3f}'}\n")

def pct(v, q): return float(np.percentile(v, q)) if len(v) else float("nan")
if mode == "cont":
    on = onsets[0] if onsets else 0
    steady = [o for w, o in av if o is not None and w >= on + 60 * SR]
    print(f"  first sound at {T(on):.3f} s; A/V offset after 60 s: median {pct(steady, 50):+.2f} ms, p1 {pct(steady, 1):+.2f}, p99 {pct(steady, 99):+.2f}, min {min(steady, default=float('nan')):+.2f}, max {max(steady, default=float('nan')):+.2f}")
    play_end = max((e[0] for e in events if e[1] == "silence" and e[0] > on), default=N)
    st = [e for e in steps if on <= e[0] < play_end]; dur = T(play_end - on)
    print(f"  in play ({dur:.1f} s): steps {len(st)} = {len(st) / dur:.1f}/s, net {sum(e[2] or 0 for e in st):+d} samples (±8 or less: {sum(1 for e in st if e[2] is not None and abs(e[2]) <= 8)} steps, net {sum(e[2] for e in st if e[2] is not None and abs(e[2]) <= 8):+d}); per minute: "
          + " ".join(str(sum(1 for e in st if int(T(e[0] - on) // 60) == m)) for m in range(int(dur // 60) + 1)))
    out.update(first_sound=T(on), play_s=dur, steps_in_play=len(st), net=sum(e[2] or 0 for e in st), net_small=sum(e[2] for e in st if e[2] is not None and abs(e[2]) <= 8), av_median=pct(steady, 50), av_p1=pct(steady, 1), av_p99=pct(steady, 99),
               av_min=min(steady, default=None), av_max=max(steady, default=None))
    # around each picture event in play: the offset before, just after, and its return
    for w, k, a, b, n in [x for x in pic if on + 5 * SR <= x[0] < play_end][:20]:
        seq = [(T(ww - w), o) for ww, o in av if o is not None and w - 2 * SR <= ww < w + 20 * SR]
        bef = [o for t, o in seq if t < 0]; aft = [(t, o) for t, o in seq if t >= 0]
        base = np.median(bef) if bef else float("nan")
        back = next((t for t, o in aft if abs(o - base) < 1.0), None)
        print(f"    picture {a}→{b} (held {n if a == b else 0}) at {T(w):.1f} s: offset before {base:+.2f} ms, first after {aft[0][1] if aft else float('nan'):+.2f}, back within 1 ms after {back} s")
else:
    plays = []
    for k, w0 in enumerate(onsets):
        end = next((e[0] for e in events if e[1] == "silence" and e[0] > w0 and e[3] >= 240 * 4), N)
        win = [(T(w - w0), o) for w, o in av if o is not None and w0 <= w < min(end, w0 + 60 * SR)]
        if not win: continue
        s_first = src_at(w0); first = offset_ms(w0)
        ev = [e for e in events if w0 < e[0] < end]
        jumps = [(T(e[0] - w0), e[2]) for e in ev if e[1] == "step" and (e[2] is None or abs(e[2]) >= 48)]
        sil = [(T(e[0] - w0), e[3]) for e in ev if e[1] == "silence" and e[3] >= 240]
        small = sum(1 for e in ev if e[1] == "step" and e[2] is not None and abs(e[2]) < 48)
        last10 = [o for t, o in win if t >= 50]; final = float(np.median(last10)) if last10 else float("nan")
        out_t = [t for t, o in win if abs(o - final) > 1.0]; settle = out_t[-1] if out_t else 0.0
        out_h = [t for t, o in win if abs(o - final) > 0.5]; settle_h = out_h[-1] if out_h else 0.0
        out_2 = [t for t, o in win if abs(o - final) > 2.0]; settle_2 = out_2[-1] if out_2 else 0.0
        wob = [o for t, o in win if t >= 30]; wobble = (max(wob) - min(wob)) if wob else float("nan")
        # picture at the Play: frames around w0 until motion
        fk = bisect.bisect_right(fstarts, w0) - 1
        held = frames[fk][1] if fk >= 0 else None
        mo = next((kk for kk in range(max(fk, 0), min(len(frames), fk + 600)) if frames[kk][1] is not None and held is not None and frames[kk][1] != held), None)
        pseq = [frames[kk][1] for kk in range(mo, min(len(frames), mo + 8))] if mo is not None else []
        pev = [(round(T(w - w0), 3), a, b, n) for w, kk, a, b, n in pic if w0 < w < min(end, w0 + 60 * SR) and (mo is None or kk > mo)]
        # the offset trace: at first sound, 0.5 s, just before and after the largest jump, 5 s, 10 s, 30 s, 59 s
        def at(t): v = [o for tt, o in win if tt >= t]; return v[0] if v else float("nan")
        bigj = max(jumps, key=lambda j: abs(j[1] or 0)) if jumps else None
        pre = [o for t, o in win if bigj and t < bigj[0]]; post = [o for t, o in win if bigj and t >= bigj[0]]
        # a slew: the offset moving more than 20 ms within the window with no jump of 1 ms or more
        span = max(o for t, o in win) - min(o for t, o in win)
        plays.append(dict(n=k + 1, from0=bool(s_first is not None and s_first < SR), src=(s_first or 0) / SR, first=first, at05=at(0.5), at5=at(5), at10=at(10), at30=at(30), at59=at(59),
                          jumps=jumps, pre_jump=(pre[-1] if pre else None), post_jump=(post[0] if post else None), silences=sil, small_steps=small, final=final,
                          settle_1ms=settle, settle_05ms=settle_h, settle_2ms=settle_2, wobble_30_60=wobble, span=span, picture_motion_after=(T(frames[mo][0] - w0) if mo is not None else None),
                          picture_seq=pseq, picture_events=pev[:6], sound_s=T(min(end, N) - w0)))
    print(f"  Plays found on the wire: {len(plays)}")
    for pl in plays:
        j = "; ".join(f"{t:.3f} s {v:+d} ({v / 48:+.1f} ms)" if v is not None else f"{t:.3f} s ?" for t, v in pl["jumps"]) or "none"
        print(f"   #{pl['n']:2d} {'from 0' if pl['from0'] else 'mid   '} src {pl['src']:8.3f}: first {pl['first']:+7.2f} · 0.5 s {pl['at05']:+7.2f} · jumps {j} · 5 s {pl['at5']:+6.2f} · 10 s {pl['at10']:+6.2f} · "
              f"final {pl['final']:+6.2f} · settled ±2 ms at {pl['settle_2ms']:.1f} s, ±1 ms at {pl['settle_1ms']:.1f} s (30–60 s range {pl['wobble_30_60']:.2f}) · silences≥5ms {pl['silences']} · small {pl['small_steps']} · "
              f"picture moves {pl['picture_motion_after']} s after first sound {pl['picture_seq'][:6]} · later picture events {pl['picture_events']}")
    out["plays"] = plays
json.dump(out, open(f"{d}/{label}.summary.json", "w"), indent=1, default=str)
