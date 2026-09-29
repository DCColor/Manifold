#!/usr/bin/env python3
"""Soak watcher (README.md). Read-only: never deletes, moves or writes outside its own log/CSV.
- a new, finished ~/Movies/*.mov  -> max_volume of its audio, as a notification
- a new, finished Audio Hijack WAV -> the same
- more than one Manifold PID       -> a warning notification
- every 10 s                        -> Manifold %CPU to cpu.csv"""
import glob, os, re, subprocess, time

HOME = os.path.expanduser('~')
OUT = os.environ.get('SOAK_OUT', os.path.join(HOME, 'Desktop', 'manifold-soak'))
os.makedirs(OUT, exist_ok=True)
WATCH = [os.path.join(HOME, 'Movies', '*.mov'), os.path.join(HOME, 'Music', 'Audio Hijack', '*.wav')]
LOG = os.path.join(OUT, 'watcher.log')

def note(title, msg):
    with open(LOG, 'a') as f:
        f.write(f'{time.strftime("%H:%M:%S")} {title}: {msg}\n')
    subprocess.run(['osascript', '-e', f'display notification "{msg}" with title "{title}" sound name "Glass"'])

def max_volume(path):
    r = subprocess.run(['ffmpeg', '-hide_banner', '-i', path, '-map', '0:a:0', '-af', 'volumedetect', '-f', 'null', '-'],
                       capture_output=True, text=True)
    m = re.search(r'max_volume: (-?[\d.]+|-inf) dB', r.stderr)
    return float(m.group(1)) if m and m.group(1) != '-inf' else float('-inf')

seen = {p for g in WATCH for p in glob.glob(g)}
pending = {}          # path -> (size, stable_since)
last_multi = 0
cpu = open(os.path.join(OUT, 'cpu.csv'), 'a')
next_cpu = 0
note('Step 8 watcher', 'running')
while True:
    now = time.time()
    for g in WATCH:
        for p in glob.glob(g):
            if p in seen: continue
            try: sz = os.path.getsize(p)
            except OSError: continue
            prev = pending.get(p)
            if prev is None or prev[0] != sz:
                pending[p] = (sz, now)
            elif now - prev[1] >= 4:
                seen.add(p); pending.pop(p, None)
                v = max_volume(p)
                name = os.path.basename(p)
                if v <= -80:
                    note('SILENT capture', f'{name}: max {v} dB. Re-pick Manifold in the recorder and redo it.')
                else:
                    note('Capture OK', f'{name}: max {v:.1f} dB')
    pids = subprocess.run(['pgrep', '-x', 'Manifold'], capture_output=True, text=True).stdout.split()
    if len(pids) > 1 and now - last_multi > 60:
        last_multi = now
        note('TWO MANIFOLDS', f'{len(pids)} Manifold processes running: {" ".join(pids)}. The run is void. Quit the extra one.')
    if now >= next_cpu:
        next_cpu = now + 10
        for pid in pids:
            r = subprocess.run(['ps', '-o', '%cpu=', '-p', pid], capture_output=True, text=True).stdout.strip()
            if r:
                cpu.write(f'{time.strftime("%Y-%m-%d %H:%M:%S")},{pid},{r}\n'); cpu.flush()
    time.sleep(2)
