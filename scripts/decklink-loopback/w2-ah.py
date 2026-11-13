#!/usr/bin/env python3
# Stage 2, method A (docs/CARD_CLOCK_FINDINGS.md §10.27): one Audio Hijack recording, left = Manifold's output (Application source),
# right = the SDI loop's embedded audio (Input Device "DeckLink 8K Pro (1)", channel 1), both on Audio Hijack's one clock. The fixture is
# seeded noise, so each 100 ms window of the left channel is found in the right by cross-correlation, sample-exact.
#   w2-ah.py <recording.wav> [--sdi-offset-ms -0.567] [--mac-latency-frames N] [--sdi-in-latency-frames N]
# Prints, per the run: windows used, the lag of right against left (+ = the SDI sound later than the Mac's at the taps), median and
# p1–p99; then the Mac's sound less the SDI picture at the taps (− = the Mac's sound earlier), from the lag and the SDI sound's place
# against its picture (1c: −0.567 ms at 59.94), and the same carried to the connectors with the two reported latencies, which are stated,
# not measured.
# Needs numpy (the scratch venv: ~/Code/_scratch/manifold-1c-wire/.venv/bin/python).
import argparse, statistics, sys, wave
import numpy as np

def read(path):
    with wave.open(path, "rb") as w:
        ch, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if width == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        x = (b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16))
        x = np.where(x & 0x800000, x - (1 << 24), x).astype(np.float64)
    elif width == 2: x = np.frombuffer(raw, dtype=np.int16).astype(np.float64)
    elif width == 4: x = np.frombuffer(raw, dtype=np.int32).astype(np.float64)
    else: sys.exit(f"sample width {width} not handled")
    return rate, x.reshape(-1, ch)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav"); ap.add_argument("--sdi-offset-ms", type=float, default=-0.567)
    ap.add_argument("--mac-latency-frames", type=int); ap.add_argument("--sdi-in-latency-frames", type=int)
    ap.add_argument("--search-ms", type=float, default=400)
    a = ap.parse_args()
    rate, x = read(a.wav)
    if x.shape[1] < 2: sys.exit("needs two channels")
    L, R = x[:, 0], x[:, 1]
    for name, c in (("left (Mac)", L), ("right (SDI)", R)):
        rms = np.sqrt(np.mean(c ** 2)) / (1 << 23)
        print(f"{name}: {20 * np.log10(rms) if rms > 0 else -999:.1f} dBFS rms over {len(c) / rate:.1f} s")
    win, search = int(0.1 * rate), int(a.search_ms / 1000 * rate)
    lags, peaks = [], []
    for start in range(search, len(L) - win - search, win):
        seg = L[start:start + win]
        if np.std(seg) == 0: continue
        ref = R[start - search:start + win + search]
        n = 1 << int(np.ceil(np.log2(len(ref) + win)))
        cc = np.fft.irfft(np.fft.rfft(ref, n) * np.conj(np.fft.rfft(seg, n)), n)[:len(ref) - win + 1]
        k = int(np.argmax(cc)); norm = np.sqrt(np.sum(seg ** 2) * np.sum(ref[k:k + win] ** 2))
        if norm == 0: continue
        peaks.append(cc[k] / norm); lags.append(k - search)
    good = [l for l, p in zip(lags, peaks) if p > 0.9]
    print(f"windows {len(lags)}, correlation > 0.9 in {len(good)}")
    if not good: sys.exit("no window found: a silent or wrong channel")
    ms = [l / rate * 1e3 for l in good]
    srt = sorted(ms)
    print(f"right against left: median {statistics.median(ms):+.3f} ms ({statistics.median(good):+d} samples), "
          f"p1 {srt[len(srt) // 100]:+.3f}, p99 {srt[-1 - len(srt) // 100]:+.3f}, distinct lags {sorted(set(good))[:8]}")
    med = statistics.median(ms)
    # o = t(SDI sound) − t(SDI picture) on the wire (1c: −0.567 ms, the sound early). So t(picture) = t(right) − o, and the Mac's sound
    # against the SDI picture is t(left) − t(picture) = −lag + o. Negative: the Mac's sound comes before the SDI picture.
    at_taps = -med + a.sdi_offset_ms
    print(f"Mac's sound − SDI picture at the taps: {at_taps:+.3f} ms (− = the Mac's sound earlier), with the SDI sound at "
          f"{a.sdi_offset_ms:+.3f} ms against its picture")
    if a.mac_latency_frames is not None and a.sdi_in_latency_frames is not None:
        # The Mac's tap is before its device: at the connector the sound is later by the output latency (+). The SDI tap is after the
        # DeckLink input path: the picture was on the wire earlier than the tap by the input latency, so the difference grows by it (+).
        conn = at_taps + a.mac_latency_frames / rate * 1e3 + a.sdi_in_latency_frames / rate * 1e3
        print(f"at the connectors, with the REPORTED latencies (Mac output {a.mac_latency_frames}, DeckLink input {a.sdi_in_latency_frames} "
              f"frames): {conn:+.3f} ms; uncertainty: both latencies as reported, unmeasured")

if __name__ == "__main__":
    main()
