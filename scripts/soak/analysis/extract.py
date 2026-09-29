#!/usr/bin/env python3
"""Extract the fit's (x, Δ) pairs and the steering/fit window series from a Manifold WHEP log.
Pairs: each SR used once, as SenderReportLineFit pairs them (both streams fresh). x = log time since
the first pair (host ≈ video content time to ppm). Writes <name>.pairs.tsv and <name>.windows.tsv."""
import re, sys, datetime, os
PAIR = re.compile(r'^(\S+ \S+) .*\[WHEP-SR\] a#(\d+) v#(\d+)\s+Δ = ([+-][\d.]+) ms')
STEER = re.compile(r'^(\S+ \S+) .*\[WHEP-RESAMPLE\] steering window \+(\d+)s .*renderer depth ms min [\d.]+ med ([\d.]+)')
FIT = re.compile(r'^(\S+ \S+) .*\[WHEP-SRFIT\] window video t=(-?\d+) s · offset ([+-][\d.]+) ms · slope ([+-][\d.]+) ppm .*?\) (IN USE|not in use|HELD)')
APPLIED = re.compile(r'applied slope ([+-][\d.]+) ppm')
def ts(s): return datetime.datetime.strptime(s, '%Y-%m-%d %H:%M:%S.%f').timestamp()
path, out = sys.argv[1], sys.argv[2]
seenA = seenV = 0; freshA = freshV = False; pairs = []; t0 = None
steer = None; wins = []
FIRST = re.compile(r'\[WHEP-SR\] ✅ FIRST PAIR')
session = 0
for line in open(path, errors='replace'):
    if FIRST.search(line):
        # A new WHEP session: its SR pairing starts afresh, like the fit's. Keep the last session.
        session += 1
        seenA = seenV = 0; freshA = freshV = False; pairs = []; t0 = None; steer = None; wins = []
    m = PAIR.match(line)
    if m:
        t, a, v, d = ts(m[1]), int(m[2]), int(m[3]), float(m[4]) / 1e3
        if a > seenA: seenA = a; freshA = True
        if v > seenV: seenV = v; freshV = True
        if freshA and freshV:
            freshA = freshV = False
            if t0 is None: t0 = t
            pairs.append((t - t0, d))
        continue
    m = STEER.match(line)
    if m: steer = (ts(m[1]), float(m[3]) / 1e3); continue
    m = FIT.match(line)
    if m and steer and t0 is not None:
        # Builds from 14f4b89 on log the applied slope explicitly (it can be HELD); older builds apply the
        # fitted slope only when IN USE.
        ap = APPLIED.search(line)
        applied = float(ap[1]) * 1e-6 if ap else (float(m[4]) * 1e-6 if m[5] == 'IN USE' else 0.0)
        wins.append((steer[0] - t0, steer[1], float(m[3]) / 1e3, applied))
        steer = None
with open(out + '.pairs.tsv', 'w') as f:
    for x, d in pairs: f.write(f'{x:.6f}\t{d:.9f}\n')
with open(out + '.windows.tsv', 'w') as f:
    for w in wins: f.write('%.3f\t%.6f\t%.6f\t%.9f\n' % w)
print(f'{os.path.basename(path)}: session {session}, {len(pairs)} pairs over {pairs[-1][0] if pairs else 0:.0f} s, {len(wins)} windows')
