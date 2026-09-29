#!/usr/bin/env python3
"""The log term of the restated start → end criterion (AUDIO_RESAMPLER_DESIGN.md §6.3, §18.9):
median renderer depth over capture A's windows minus its median at 60–120 s after the connect, from
the last session's steering windows (any transport). Add it to (capture B − capture A).
Usage: depth_term.py <manifold-log> [capture-A start s, default 180] [capture-A end s, default 310]"""
import re, sys, statistics
W = re.compile(r'\[\w+-RESAMPLE\] steering window \+(\d+)s .*renderer depth ms min [\d.]+ med ([\d.]+)')
a0 = float(sys.argv[2]) if len(sys.argv) > 2 else 180
a1 = float(sys.argv[3]) if len(sys.argv) > 3 else 310
wins = []
for line in open(sys.argv[1], errors='replace'):
    m = W.search(line)
    if m:
        t = int(m[1])
        if wins and t < wins[-1][0]: wins = []   # a new session: keep the last
        wins.append((t, float(m[2])))
start = [d for t, d in wins if 60 <= t <= 120]
capA = [d for t, d in wins if a0 <= t <= a1]
if not start or not capA: sys.exit(f'not enough steering windows ({len(wins)} in the last session)')
s, a = statistics.median(start), statistics.median(capA)
print(f'depth at 60–120 s {s:.1f} ms, at capture A ({a0:.0f}–{a1:.0f} s) {a:.1f} ms → term {a - s:+.1f} ms')
