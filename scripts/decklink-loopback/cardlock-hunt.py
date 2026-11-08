#!/usr/bin/env python3
# Freeze hunt (docs/CARD_CLOCK_FINDINGS.md §10.13). Capture stays closed: pulls match the wire (§6), so a freeze is the card's pulls stopping and a loss of SDI audio is the
# bridge's branch lines going off PCM. Guarded, launched by absolute path and held by PID, quit by PID. AX clicks on named items only; no keystrokes, no screenshots.
#   cardlock-hunt.py cycle <on|off> <label> <hours>       Play from a random point, 120 s, pause, repeat. On: MANIFOLD_CARDLOCK_1B=1
#   cardlock-hunt.py long  <on|off> <label> <HH:MM>       one Play, looped, until that time tomorrow or today
#   cardlock-hunt.py replay <log>                         the detector alone over an existing log
# On detection, before anything else: sample, a spindump (only if spindump-watch.sh is running as root), the last 60 s of logs, and whether the window is frozen, saved in
# build/cardclock/hunt/<label>-<n>/. Then quit by PID, guard, relaunch, carry on until the deadline. A guard trip, or a build that will not quit, stops everything.
# `touch build/cardclock/hunt/STOP` ends a case cleanly. HUNT_STOP_FIRST=1 ends it at the first picture freeze (or a stopped log), exit 3; an
# audio-only silence (the Jump stall, §10.12 Fault 2) is captured and the hunt carries on. HUNT_CYCLE sets the Play length (default 120 s).
# MANIFOLD_CARDLOCK_STEER_HZ (measurement build) and MANIFOLD_PUMPWATCH_SELFTEST pass through to the build; the rate is kept in <label>.json (§10.14).
import datetime, json, os, random, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.dirname(os.path.dirname(HERE))
OUT = f"{REPO}/build/cardclock/hunt"; PROC = f"{REPO}/scripts/manifold-proc.sh"; AXT = f"{REPO}/build/linkpace/linkpace-ax"
DEV = f"{REPO}/build/decklink-loopback"; APP = f"{REPO}/.build-cc/Build/Products/Profile/Manifold.app/Contents/MacOS/Manifold"
FIXTURE = f"{REPO}/build/cardclock/cc-5994-2450s.mov"; TITLE = os.path.basename(FIXTURE)
SCARLETT = "AppleUSBAudioEngine:Focusrite:Scarlett 18i20 USB:00011706:1,2"
STILL = 2.0   # seconds without a new picture, or without PCM
GRACE = 2.0   # after Play, for the picture and the sound to start
CYCLE = int(os.environ.get("HUNT_CYCLE", "120"))   # seconds of each Play; HUNT_CYCLE=60 for the interleaved hunt (§10.14)

class Detector:
    """Reads the log a line at a time. `check()` names what it sees: 'freeze', 'audio' or None."""
    def __init__(s): s.playing = False; s.play = 0.0; s.plays = 0; s.pts = None; s.moved = 0.0; s.pcm = 0.0; s.host = 0.0; s.ran = 0.0; s.done = False; s.since = None
    def line(s, l):
        if l.startswith("[CADENCE] #"):
            f = l.split()
            if len(f) < 6: return
            h = float(f[3])
            if s.playing and s.host: s.ran += max(0.0, min(h - s.host, 1.0))
            s.host = h
            if f[5] != "nan" and f[5] != s.pts: s.pts = f[5]; s.moved = h
        elif l.startswith("DeckLinkAudio: branch #"):
            if "→ PCM" in l: s.pcm = s.host
        elif l.startswith("[TRANSPORT] play") or l.startswith("[DRV] BEGIN"): s.playing = True; s.play = s.host; s.plays += 1
        elif l.startswith("[TRANSPORT] pause") or l.startswith("[DRV] END"): s.playing = False
        elif l.startswith("[TRANSPORT] done"): s.done = True
    def check(s):
        if not s.playing or not s.host: return None
        if s.host - max(s.moved, s.play + GRACE) >= STILL: return "freeze"
        if s.host - max(s.pcm, s.play + GRACE) >= STILL: return "audio"
        return None

def replay(path):
    d = Detector(); seen = None
    for l in open(path, errors="replace"):
        d.line(l); k = d.check()
        if k != seen:
            if k: print(f"{k} at host {d.host:.3f}, pts {d.pts}, {d.host - d.play:.1f} s after Play, Play {d.plays}, last new picture {d.moved:.3f}, last PCM {d.pcm:.3f}")
            seen = k
    print(f"end: Plays {d.plays}, ran {d.ran:.0f} s")

def sh(*a): return subprocess.run(a, capture_output=True, text=True)
def say(m): print(f"{datetime.datetime.now():%H:%M:%S} {m}", flush=True)
def guard():
    r = sh(PROC, "guard")
    if r.returncode: say(f"GUARD TRIPPED, stopping: {r.stderr.strip()}"); sys.exit(2)
def menu(pid, bar, item):
    sh("osascript", "-e", f'tell application "System Events" to tell (first process whose unix id is {pid}) to click menu item "{item}" of menu 1 of menu bar item "{bar}" of menu bar 1')
def deny_licence_prompt():
    """An unsigned build's licence prompt, and only that: Deny writes nothing and clears nothing. Anything else on SecurityAgent is left alone."""
    if sh("pgrep", "-x", "SecurityAgent").returncode: return False
    t = sh("osascript", "-e", 'tell application "System Events" to tell process "SecurityAgent" to get value of static texts of window 1').stdout
    if "manifold" not in t.lower(): return False
    sh("osascript", "-e", 'tell application "System Events" to tell process "SecurityAgent" to click button "Deny" of window 1')
    return True

def capture(pid, kind, d, label, n, log, defout):
    """Before anything else. The app keeps logging meanwhile, which is how the window is read afterwards."""
    dirn = f"{OUT}/{label}-{n}"; os.makedirs(dirn, exist_ok=True)
    open(f"{dirn}/spindump.request", "w").write(str(pid))    # spindump-watch.sh picks this up, if it is running
    smp = subprocess.Popen(["sample", str(pid), "10", "-file", f"{dirn}/sample.txt"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    smp.wait(); time.sleep(3)
    for name, pred in (("system-process", f"processID == {pid}"), ("system-audio", 'process == "coreaudiod" OR process == "audiomxd"')):
        with open(f"{dirn}/{name}.log", "w") as f: subprocess.run(["log", "show", "--last", "90s", "--style", "compact", "--predicate", pred], stdout=f, stderr=subprocess.DEVNULL)
    start = d.host - 60; host = 0.0; win = []; keep = []
    for l in open(log, errors="replace"):
        x = re.match(r"\[CADENCE\] #\d+ host (\S+)", l)
        if x: host = float(x[1])
        if host >= start: keep.append(l)
        x = re.match(r"\[PLAYBACK-STATS\] t=\S+ presented=(\d+) dropped=\d+ late=\d+ pts=(\S+)", l)
        if x: win.append((host, int(x[1]), float(x[2])))
    open(f"{dirn}/app-last60.log", "w").writelines(keep)
    after = [w for w in win if w[0] > d.moved + 1.5]
    pre = [w for w in win if w[0] <= d.moved + 1.5]
    rec = dict(kind=kind, pid=pid, wall=datetime.datetime.now().isoformat(timespec="seconds"), host=d.host, pts=d.pts, last_new_picture_host=d.moved, last_pcm_host=d.pcm,
               seconds_since_play=round(d.moved - d.play, 2), play_number=d.plays, seconds_run_this_launch=round(d.ran),
               window_lines_after_last_picture=len(after), window_presented_after=sum(w[1] for w in after), window_last_pts=(win[-1][2] if win else None),
               window_frozen=(len(after) == 0), spindump=os.path.exists(f"{dirn}/spindump.txt"), default_output=open(defout).read().splitlines() if os.path.exists(defout) else [])
    json.dump(rec, open(f"{dirn}/summary.json", "w"), indent=1); return rec

def launch_once(label, n, gate, steps, deadline, state):
    guard(); os.makedirs(OUT, exist_ok=True)
    log = f"{OUT}/{label}-L{n}.log"; defout = f"{OUT}/{label}-L{n}.defout"
    devp = subprocess.Popen([f"{DEV}/devclock", SCARLETT, "100000", f"{OUT}/{label}-L{n}.dev"], stdout=subprocess.DEVNULL)
    defp = subprocess.Popen([f"{DEV}/defout", "100000", defout])
    env = dict(os.environ, MANIFOLD_CARDCLOCK_LOG="1", MANIFOLD_DECKLINK_CADENCE_LOG="1", MANIFOLD_PLAYBACK_STATS="1", MANIFOLD_DEBUG_TRANSPORT=steps)
    env.pop("MANIFOLD_CARDLOCK_1B", None)
    if gate: env["MANIFOLD_CARDLOCK_1B"] = "1"
    out = open(log, "w")
    p = subprocess.Popen([APP, "-manifold.decklink.audioDestination", "sdi"], stdout=out, stderr=subprocess.STDOUT, env=env)
    pid = p.pid; say(f"{label} launch {n}: pid {pid}, gate {'on' if gate else 'off'}")
    def stop_helpers():
        for h in (devp, defp): h.terminate(); h.wait()
    def quit_build():
        r = sh(PROC, "quit", str(pid), "--timeout", "60")
        if r.returncode:
            say(f"pid {pid} did not quit ({r.returncode}: {r.stderr.strip()}). Left running, stopping the hunt: not killed"); stop_helpers(); sys.exit(5)
        p.wait(); stop_helpers(); guard()
    time.sleep(7)
    if sh(PROC, "check", str(pid)).returncode: say("the build did not come up"); stop_helpers(); return "no-launch"
    deny_licence_prompt()
    sh(PROC, "open", str(pid), FIXTURE); time.sleep(3.5)
    sh(AXT, str(pid), "place", TITLE, "ASUS"); time.sleep(1.5)
    menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(3)
    if "CARDCLOCK-REF] start" not in open(log, errors="replace").read():
        say("output did not start"); quit_build(); return "no-output"
    d = Detector(); f = open(log, errors="replace"); buf = ""; grew = time.monotonic(); checked = time.monotonic(); seen = None
    while True:
        chunk = f.read()
        if chunk:
            grew = time.monotonic(); buf += chunk; lines = buf.split("\n"); buf = lines.pop()
            for l in lines:
                d.line(l)
                if seen is None: seen = d.check()
        if p.poll() is not None:
            say(f"pid {pid} EXITED by itself, code {p.returncode}"); state["events"].append(dict(kind="exit", code=p.returncode, label=label, launch=n)); stop_helpers(); state["plays"] += d.plays; state["ran"] += d.ran; return "exit"
        stalled = time.monotonic() - grew > 5
        if seen or stalled:
            kind = seen or "log-stopped"; say(f"DETECTED {kind}: pts {d.pts}, Play {d.plays}, {d.host - d.play:.1f} s after Play")
            state["fz"] += 1; rec = capture(pid, kind, d, label, state["fz"], log, defout); rec["launch"] = n; state["events"].append(rec)
            say(f"captured {label}-{state['fz']}: window_frozen {rec['window_frozen']}, last new picture {rec['seconds_since_play']} s after Play")
            state["plays"] += d.plays; state["ran"] += d.ran; quit_build(); return "detected-audio" if kind == "audio" else "detected"
        if d.done or time.time() >= deadline or os.path.exists(f"{OUT}/STOP"):
            menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(3); menu(pid, "File", "Close All"); time.sleep(1.5)
            state["plays"] += d.plays; state["ran"] += d.ran; quit_build(); say(f"{label} launch {n} ended: Plays {d.plays}, ran {d.ran:.0f} s"); return "ended"
        if time.monotonic() - checked > 15: checked = time.monotonic(); deny_licence_prompt()
        time.sleep(0.2)

def hunt(mode, gate, label, deadline):
    rng = random.Random(); seed = rng.randrange(1 << 30); rng.seed(seed)
    state = dict(plays=0, ran=0.0, fz=0, events=[], seed=seed, gate=gate, mode=mode, steer_hz=os.environ.get("MANIFOLD_CARDLOCK_STEER_HZ", "1"), cycle=CYCLE,
                 began=datetime.datetime.now().isoformat(timespec="seconds")); n = 0
    while time.time() < deadline and not os.path.exists(f"{OUT}/STOP"):
        n += 1
        if mode == "cycle":
            k = int((deadline - time.time()) / (CYCLE + 4)) + 1
            steps = "wait 25;" + ";".join(f"seek {rng.uniform(0, 2300):.2f};wait 2;play;wait {CYCLE};pause;wait 1" for _ in range(k))
        else: steps = "wait 25;loop;play"
        r = launch_once(label, n, gate, steps, deadline, state)
        json.dump(dict(state, launches=n, ended=datetime.datetime.now().isoformat(timespec="seconds")), open(f"{OUT}/{label}.json", "w"), indent=1)
        if r in ("no-launch", "no-output"): say(f"stopping {label}: {r}"); sys.exit(4)
        if r == "detected" and os.environ.get("HUNT_STOP_FIRST") == "1":
            say(f"stopping {label}: first freeze (HUNT_STOP_FIRST)"); say(f"{label} DONE: {state['ran'] / 3600:.2f} h, Plays {state['plays']}, detections {state['fz']}"); sys.exit(3)
    say(f"{label} DONE: {state['ran'] / 3600:.2f} h, Plays {state['plays']}, detections {state['fz']}")

if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "replay": replay(a[1]); sys.exit()
    gate = a[1] == "on"
    if a[0] == "cycle": dl = time.time() + float(a[3]) * 3600
    else:
        h, m = map(int, a[3].split(":")); t = datetime.datetime.now().replace(hour=h, minute=m, second=0, microsecond=0)
        if t <= datetime.datetime.now(): t += datetime.timedelta(days=1)
        dl = t.timestamp()
    hunt(a[0], gate, a[2], dl)
