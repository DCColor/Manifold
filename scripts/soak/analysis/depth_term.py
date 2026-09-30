#!/usr/bin/env python3
"""The log term of the restated start → end criterion (AUDIO_RESAMPLER_DESIGN.md §6.3, §18.9, §18.21):
median renderer depth over capture A's windows minus its median over the session START, from the last
session's steering windows (any transport). Add it to (capture B − capture A).
The start is the settled span the log's "LEVEL REFERENCE set … span a–b s" line names (§18.21: loop
unsaturated, integrator < 10 ppm, SR slope in use, LiveClock within ±10 ms, no hold/splice/write);
a log without that line (older builds, non-RTP transports) falls back to 60–120 s, and says so.
Usage: depth_term.py <manifold-log> [capture-A start s, default 180] [capture-A end s, default 310]"""
import re, sys, statistics
W = re.compile(r'\[\w+-RESAMPLE\] steering window \+(\d+)s .*renderer depth ms min [\d.]+ med ([\d.]+)')
a0 = float(sys.argv[2]) if len(sys.argv) > 2 else 180
a1 = float(sys.argv[3]) if len(sys.argv) > 3 else 310
REF = re.compile(r'LEVEL REFERENCE set at t=\d+ s: queue [\d.]+ ms, the median over the settled span (\d+)–(\d+) s')
wins = []; span = None
for line in open(sys.argv[1], errors='replace'):
    m = W.search(line)
    if m:
        t = int(m[1])
        if wins and t < wins[-1][0]: wins = []; span = None   # a new session: keep the last
        wins.append((t, float(m[2])))
        continue
    r = REF.search(line)
    if r: span = (float(r[1]), float(r[2]))
s0, s1, how = (span[0], span[1], 'the settled span') if span else (60, 120, 'fallback: NO "LEVEL REFERENCE" line in this log (older build or non-RTP transport)')
start = [d for t, d in wins if s0 <= t <= s1]
capA = [d for t, d in wins if a0 <= t <= a1]
if not start or not capA: sys.exit(f'not enough steering windows ({len(wins)} in the last session)')
s, a = statistics.median(start), statistics.median(capA)
print(f'depth at the start ({s0:.0f}–{s1:.0f} s, {how}) {s:.1f} ms, at capture A ({a0:.0f}–{a1:.0f} s) {a:.1f} ms → term {a - s:+.1f} ms')
