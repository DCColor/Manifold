#!/usr/bin/env python3
# B5, audio-only files on SDI (docs/STILLS_AND_AUDIO_ONLY_PLAN.md §5.3, CARD_CLOCK_FINDINGS.md §10.31), from one w1c-run.py run with
# capture open. The picture is the file's card, with no frame markers, so the sound is checked against the card's own frame grid,
# which is the virtual picture timeline (`MetalVideoRenderer.noteDeckLinkVirtualPull`):
#   w1c-audioonly.py <runs dir> <label> <reference s32le stereo 48 kHz> <card rate 5994|2398|…> [--lossy]
# For every stretch of sound between digital silences of 5 ms or more ("segment"):
#   * located in the file's reference PCM: exactly (W1C_TOL as w1c-wire.py, for a 44.1 kHz file's offline-resampled reference), or with
#     --lossy (MP3, AAC) by cross-correlation;
#   * continuity: lossless, every sample of the segment against the reference at that place, and each place it stops following is a
#     discontinuity; lossy, the lag of every 0.5 s window, and each change is a discontinuity;
#   * grid: the content sample at the first sample of every wire frame inside the segment, less the nearest card-frame grid point
#     (k × 48000 / rate). A sound placed on the virtual frame timeline has one constant residue (the card's own constant, as a video
#     file's "first sample N into its frame"), within ±1 sample of rounding.
import os, re, statistics, sys
import numpy as np
d, label, refpath, rc = sys.argv[1:5]; lossy = "--lossy" in sys.argv
FPS = {"5994": 60000 / 1001, "2398": 24000 / 1001, "25": 25.0, "2997": 30000 / 1001}[rc]; SPF = 48000 / FPS
TOL = int(os.environ.get("W1C_TOL", "0"))
rx = np.fromfile(f"{d}/{label}.raw", dtype="<i4").reshape(-1, 2); x0 = np.ascontiguousarray(rx[:, 0])
ref = np.fromfile(refpath, dtype="<i4").reshape(-1, 2); r0 = np.ascontiguousarray(ref[:, 0])
N, M = len(x0), len(r0)
# wire frame starts, from the capture's marks (" a<n>": the audio samples that frame carried)
fstarts, off = [], 0
for l in open(f"{d}/{label}.marks"):
    f = l.split()
    if not f: continue
    if f[0] == "audio-only":
        if len(f) > 1 and f[1][1:].lstrip("-").isdigit(): off += max(int(f[1][1:]), 0)
        continue
    if len(f) < 5: continue
    a = next((int(x[1:]) for x in f[5:] if x[:1] == "a" and x[1:].lstrip("-").isdigit()), 0)
    fstarts.append(off); off += max(a, 0)
fstarts = np.array(fstarts)
# segments: sound between runs of >= 240 zero samples on both channels
z = (rx[:, 0] == 0) & (rx[:, 1] == 0)
segs, i = [], 0
while i < N:
    while i < N and z[i]: i += 1
    if i >= N: break
    j = i; zr = 0
    while j < N:
        if z[j]:
            zr += 1
            if zr >= 240: break
        else: zr = 0
        j += 1
    end = j - zr + 1 if j < N else N
    if end - i >= 4800: segs.append((i, end))
    i = j + 1

def same(a, b): return (a == b) if TOL == 0 else (np.abs(a.astype(np.int64) - b.astype(np.int64)) <= TOL)
if not lossy:
    k24 = (r0.astype(np.int64) >> 8) & 0xFFFFFF; keys = (k24[:-1] << 24) | k24[1:]
    order = np.argsort(keys, kind="stable"); skeys = keys[order]; del keys
def locate(s):
    if lossy:   # cross-correlate 16384 samples against the reference in 4M chunks
        L = 16384; seg = x0[s:s + L].astype(np.float64)
        best, bp = -1.0, -1
        n = 1 << 23
        Fs = np.conj(np.fft.rfft(seg, n))
        for c0 in range(0, M, n - L):
            chunk = r0[c0:c0 + n].astype(np.float64)
            if len(chunk) < L: break
            cc = np.fft.irfft(np.fft.rfft(chunk, n) * Fs, n)[:len(chunk) - L + 1]
            k = int(np.argmax(cc))
            if cc[k] > best: best, bp = cc[k], c0 + k
        return bp
    for k in range(s, min(s + 4096, N - 1)):
        if TOL: break
        if x0[k] == 0 or x0[k + 1] == 0: continue
        key = ((int(x0[k]) >> 8 & 0xFFFFFF) << 24) | (int(x0[k + 1]) >> 8 & 0xFFFFFF)
        lo = np.searchsorted(skeys, key); hi = np.searchsorted(skeys, key, "right")
        for j in order[lo:hi]:
            p = int(j) - (k - s)
            if 0 <= p and p + (k - s) + 64 <= M and bool(np.all(same(x0[k:k + 64], r0[int(j):int(j) + 64]))): return p
    if TOL:   # tolerance: correlate, then verify
        L = 16384; seg = x0[s:s + L].astype(np.float64); n = 1 << 23; Fs = np.conj(np.fft.rfft(seg, n)); best, bp = -1.0, -1
        for c0 in range(0, M, n - L):
            chunk = r0[c0:c0 + n].astype(np.float64)
            if len(chunk) < L: break
            cc = np.fft.irfft(np.fft.rfft(chunk, n) * Fs, n)[:len(chunk) - L + 1]; k = int(np.argmax(cc))
            if cc[k] > best: best, bp = cc[k], c0 + k
        return bp
    return -1

print(f"{label}: wire {N} samples ({N / 48000:.1f} s), {len(fstarts)} frames, {len(segs)} sound segments; {'lossy (correlation)' if lossy else 'exact' + (f', tolerance {TOL}' if TOL else '')}")
tot_disc = 0; all_res = []; all_spread = []; intos = []
for n_, (s, e) in enumerate(segs, 1):
    p = locate(s)
    if p < 0: print(f"  #{n_:2d} {s / 48000:8.3f} s: NOT LOCATED"); tot_disc += 1; continue
    L = min(e - s, M - p)
    disc = []; jumps = []
    if lossy:
        W = 4800; lags = []
        for k in range(0, L - W - 128, 24000):
            seg = x0[s + k:s + k + W].astype(np.float64); rr = r0[p + k - 64:p + k + W + 64].astype(np.float64)
            if len(rr) < W + 128: continue
            cc = np.correlate(rr, seg, "valid"); lags.append(int(np.argmax(cc)) - 64)
        disc = [(k, a, b) for k, (a, b) in enumerate(zip(lags, lags[1:])) if a != b]
        cont = f"lags {min(lags)}..{max(lags)} over {len(lags)} windows" if lags else "too short"
    elif not TOL:
        # walk the segment: where it stops following, relocate (a seek or a loop's wrap with no silence between is a JUMP, reported
        # with the samples off between the two runs and where the new run starts in its frame), else count the samples off
        i, q, jumps, offn, onset = s, p, [], 0, 0
        while i < e:
            n = min(e - i, M - q)
            if n <= 0: break
            bad = np.flatnonzero(~same(x0[i:i + n], r0[q:q + n]))
            if not len(bad): break
            b = i + int(bad[0])
            if b - s < 64: onset += 1
            nq = locate(b) if e - b > 128 else -1
            if nq >= 0 and nq != q + (b - i):
                fk = np.searchsorted(fstarts, b, "right") - 1
                jumps.append((b, (q + (b - i)) / 48000, nq / 48000, b - fstarts[fk] if fk >= 0 else None)); i, q = b, nq
            else:
                # off the reference here: skip to where it follows again
                k = b
                while k < e and not (k + 16 <= e and q + (k - i) + 16 <= M and bool(np.all(same(x0[k:k + 16], r0[q + (k - i):q + (k - i) + 16])))): k += 1
                offn += k - b; q += k - i; i = k
        if jumps or offn or onset:
            pass
        disc = [1] if offn > (64 if onset else 0) else []
        cont = (f"{offn} samples off the reference" + (f" (incl. ≤64 onset)" if onset else "")
                + "".join(f"; JUMP at wire {j[0] / 48000:.4f} s: src {j[1]:.4f} → {j[2]:.6f} s, new run {j[3]} samples into its frame" for j in jumps))
    else:
        ok = same(x0[s:s + L], r0[p:p + L]); bad = np.flatnonzero(~ok)
        onset = bad[bad < 64]; bad = bad[bad >= 64]   # C7: a run from the file's first sample starts with the resampler's window filling
        disc = [int(b) for k, b in enumerate(bad) if k == 0 or b - bad[k - 1] > 1]   # one per stretch off the reference
        cont = f"{len(bad)} samples off the reference" + (f" (first at +{bad[0]})" if len(bad) else "") + (f", {len(onset)} onset" if len(onset) else "")
    # the grid, on each run of the segment (a jump starts a new run at its own place)
    runs = [(s, p)] + [(j[0], int(round(j[2] * 48000))) for j in jumps]
    res = np.array([]); spreads = []
    for k_, (rs, rq) in enumerate(runs):
        re_ = runs[k_ + 1][0] if k_ + 1 < len(runs) else s + L
        fs = fstarts[(fstarts >= rs + 64) & (fstarts < re_)]
        c = rq + (fs - rs); r_ = c - np.round(c / SPF) * SPF
        if len(r_):
            rel = (r_ - r_[0] + SPF / 2) % SPF - SPF / 2   # against the run's own first frame: a run anchored off the 0 grid is still one line
            spreads.append(rel.max() - rel.min())
        res = np.concatenate([res, r_])
    all_spread.append(max(spreads) if spreads else 0.0)
    all_res += list(res)
    fk = np.searchsorted(fstarts, s, "right") - 1
    into = s - fstarts[fk] if fk >= 0 else None
    tot_disc += len(disc); intos.append(into)
    print(f"  #{n_:2d} {s / 48000:8.3f}–{e / 48000:8.3f} s ({(e - s) / 48000:6.1f} s) src {p / 48000:8.3f} s · {cont} · discontinuities {len(disc)}"
          f" · grid residue {res.min():+.2f}..{res.max():+.2f} (within each run: spread {all_spread[-1]:.2f}) samples over {len(res)} frames · first sample {into} into its frame")
if all_res:
    print(f"total: discontinuities {tot_disc}; largest spread within a run {max(all_spread):.2f} samples; first sample into its frame: {sorted(intos)}")
    print(f"       grid residue over all segments {min(all_res):+.2f}..{max(all_res):+.2f} samples "
          f"(spread {max(all_res) - min(all_res):.2f}); median {statistics.median(all_res):+.2f}")
