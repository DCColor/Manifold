# cardlock-jump.py <dir> <label>: each change of the system default output (defout) against what SDI audio and the picture did (docs/CARD_CLOCK_FINDINGS.md §10.13).
# Every log line takes the host time of the [CADENCE] pull before it, which is good to a frame. SDI audio: the bridge's branch lines (one a second of scheduled audio) and
# its underrun events. Picture: the card's pulls, and the window's [PLAYBACK-STATS]. Gaps of over 1.5 s between tap lines are the pump stopped.
import re, sys
d, label = sys.argv[1], sys.argv[2]
host = None; pulls = []; win = []; tap = []; br = []; ev = []; marks = []
for l in open(f"{d}/{label}.log", errors="replace"):
    x = re.match(r"\[CADENCE\] #\d+ host (\S+) pts (\S+) swapAgo \S+ clock (\S+)", l)
    if x:
        host = float(x[1])
        if x[2] != "nan": pulls.append((host, float(x[2])))
        continue
    if host is None: continue
    x = re.match(r"\[PLAYBACK-STATS\] t=\S+ presented=(\d+) dropped=(\d+) late=(\d+) pts=(\S+)", l)
    if x: win.append((host, int(x[1]), int(x[2]), int(x[3]), float(x[4]))); continue
    x = re.search(r"AudioTap\[\w+\]: int32 .* pts=([\d.]+)s", l)
    if x: tap.append((host, float(x[1]))); continue
    if "DeckLinkAudio: branch #" in l: br.append((host, "PCM" if "→ PCM" in l else "UNDERRUN" if "underrun" in l else "GATE")); continue
    if "UNDERRUN EVENT" in l: ev.append((host, l.split("!! ")[1].strip())); continue
    if l.startswith("[DRV]") or l.startswith("[CARDLOCK] audio"): marks.append((host, l.strip()))
try: sw = [(float(f[0]), f[1], " ".join(f[2:])) for f in (l.split() for l in open(f"{d}/{label}.defout")) if len(f) >= 3]
except FileNotFoundError: sw = []
print("default output changes:"); [print(f"   {h:.3f} {w} {n}") for h, w, n in sw]
print("underrun events:"); [print(f"   {h:.3f} {e}") for h, e in ev]
# silent runs in the branch lines
runs = []; s = None
for h, b in br:
    if b != "PCM" and s is None: s = h
    if b == "PCM" and s is not None: runs.append((s, h)); s = None
if s is not None: runs.append((s, None))
print("SDI silent runs, from the branch lines (includes the transport gate before Play):"); [print(f"   {a:.3f} to {'end' if b is None else f'{b:.3f}'}" + ("" if b is None else f": {b - a:.1f} s")) for a, b in runs]
gaps = [(a[0], b[0]) for a, b in zip(tap, tap[1:]) if b[0] - a[0] > 1.5]
print("pump gaps (tap lines over 1.5 s apart):"); [print(f"   {a:.3f} to {b:.3f}: {b - a:.1f} s") for a, b in gaps]
# pulls: runs where the picture number stopped; window: seconds with no new picture
stuck = []; i = 0
fps_gap = 0.5
last_move = pulls[0] if pulls else None
for h, p in pulls[1:]:
    if p != last_move[1]:
        if h - last_move[0] > fps_gap: stuck.append((last_move[0], h, last_move[1]))
        last_move = (h, p)
print("pull holds over 0.5 s (includes pause before Play):"); [print(f"   {a:.3f} to {b:.3f}: {b - a:.2f} s at pts {p:.3f}") for a, b, p in stuck]
print("window [PLAYBACK-STATS], worst around each change (±15 s):")
for h, w, n in sw:
    near = [x for x in win if abs(x[0] - h) < 15]
    if near: print(f"   {w} {n}: presented min {min(x[1] for x in near)}, max {max(x[1] for x in near)}, dropped {sum(x[2] for x in near)}, late {sum(x[3] for x in near)}, pts {near[0][4]:.2f} → {near[-1][4]:.2f} over {near[-1][0] - near[0][0]:.1f} s")
wg = [(a[0], b[0], a[4], b[4]) for a, b in zip(win, win[1:]) if b[0] - a[0] > 2]
print("window line gaps over 2 s:"); [print(f"   {a:.3f} to {b:.3f}: {b - a:.1f} s, pts {p:.2f} → {q:.2f}") for a, b, p, q in wg]
if pulls: print(f"last pull: host {pulls[-1][0]:.3f} pts {pulls[-1][1]:.3f}; last window line {win[-1] if win else None}")
for h, m in marks: print(f"   {h:.3f} {m}")
