#!/usr/bin/env python3
# Release soak (0.9.3 gate, docs/Manifold-BUILD.md "Pre-release checklist"). One block = one launch of the release candidate, play cycles
# with seeks and loop wraps for <minutes>, DeckLink output on, capture never opened (the card's input stays closed).
#   rc-soak.py block <app binary> <fixture> <length s> <mode> <sdi|computer> <label> <minutes>
#   rc-soak.py report <out dir> <label>...           the counts per block and in total (rc-soak-report.py does the work)
# The build runs the shipping configuration: every MANIFOLD_* variable is removed from the environment, and only observation and the
# scripted transport are set: MANIFOLD_DEBUG_TRANSPORT (seeks are key-only, and no keystroke is ever sent), MANIFOLD_DECKLINK_CADENCE_LOG
# (one [CADENCE] line per card pull: holds, skips and freezes are read from it), MANIFOLD_PLAYBACK_STATS (the window's late and dropped
# counts). None of them changes the card lock, Stage 2, the recovery paths or the audio routing. The output mode and the audio destination
# are launch arguments (argument domain): nothing is written to defaults.
# Guarded before and after; launched by absolute path, held by PID, quit by PID through manifold-proc.sh. AX menu clicks on named items
# only, no keystrokes, no screenshots. A freeze (the pulled picture still for 2 s while playing) is logged with a `sample` of the process;
# if the picture has not moved again 20 s later the block ends there (quit by PID). `touch <out dir>/STOP` ends a block cleanly.
import datetime, json, os, random, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.dirname(os.path.dirname(HERE))
PROC = f"{REPO}/scripts/manifold-proc.sh"; AXT = f"{REPO}/build/linkpace/linkpace-ax"; DEV = f"{REPO}/build/decklink-loopback"
OUT = os.environ.get("RC_OUT", os.path.expanduser("~/Code/_scratch/manifold-rc-soak"))
STILL, GRACE, UNRECOVERED = 2.0, 2.0, 20.0

def sh(*a): return subprocess.run(a, capture_output=True, text=True)
def say(m): print(f"{datetime.datetime.now():%H:%M:%S} {m}", flush=True)
def guard():
    r = sh(PROC, "guard")
    if r.returncode: say(f"GUARD TRIPPED, stopping: {r.stderr.strip()}"); sys.exit(2)
def menu(pid, bar, item):
    sh("osascript", "-e", f'tell application "System Events" to tell (first process whose unix id is {pid}) to click menu item "{item}" of menu 1 of menu bar item "{bar}" of menu bar 1')
def deny_licence_prompt():
    """An unsigned build's licence prompt, and only that: Deny writes nothing. Anything else on SecurityAgent is left alone."""
    if sh("pgrep", "-x", "SecurityAgent").returncode: return
    t = sh("osascript", "-e", 'tell application "System Events" to tell process "SecurityAgent" to get value of static texts of window 1').stdout
    if "manifold" in t.lower(): sh("osascript", "-e", 'tell application "System Events" to tell process "SecurityAgent" to click button "Deny" of window 1')
def resolve_running():
    return any("/DaVinci Resolve.app/Contents/MacOS/" in l for l in sh("ps", "-axo", "comm=").stdout.splitlines())

def cycle(rng, length):
    """~175 s: Play from a random point, a seek while playing, Pause, Play, Pause, then through the loop's wrap at the end of the file."""
    a, b = rng.uniform(0, length - 120), rng.uniform(0, length - 120)
    return (f"seek {a:.2f};wait 2;play;wait 45;seek {b:.2f};wait 45;pause;wait 3;play;wait 20;pause;wait 2;"
            f"seek {length - 25:.2f};wait 2;loop;play;wait 50;pause;wait 2;loop;wait 2")
CYCLE_S = 175

class Freeze:
    """The pulled picture while playing: [CADENCE] pts unchanged for STILL s, GRACE s after a Play."""
    def __init__(s): s.playing = False; s.play = 0.0; s.host = 0.0; s.pts = None; s.moved = 0.0; s.done = False
    def line(s, l):
        m = re.match(r"\[CADENCE\] #\d+ host (\S+) pts (\S+)", l)
        if m:
            s.host = float(m[1])
            if m[2] != s.pts: s.pts = m[2]; s.moved = s.host
        elif l.startswith("[TRANSPORT] play"): s.playing = True; s.play = s.host
        elif l.startswith("[TRANSPORT] pause"): s.playing = False
        elif l.startswith("[TRANSPORT] done"): s.done = True
    def still(s): return s.playing and s.host and s.host - max(s.moved, s.play + GRACE) >= STILL

def block(app, fixture, length, mode, dest, label, minutes):
    guard()
    if resolve_running(): say("Resolve is running: stopping"); sys.exit(4)
    os.makedirs(OUT, exist_ok=True); log = f"{OUT}/{label}.log"; title = os.path.basename(fixture)
    rng = random.Random(); seed = rng.randrange(1 << 30); rng.seed(seed)
    k = -(-int(minutes * 60) // CYCLE_S)
    steps = "wait 16;" + ";".join(cycle(rng, length) for _ in range(k))
    env = {k2: v for k2, v in os.environ.items() if not k2.startswith("MANIFOLD_")}
    env.update(MANIFOLD_DEBUG_TRANSPORT=steps, MANIFOLD_DECKLINK_CADENCE_LOG="1", MANIFOLD_PLAYBACK_STATS="1")
    meta = dict(label=label, app=app, fixture=fixture, length=length, mode=mode, dest=dest, minutes=minutes, cycles=k, seed=seed,
                env=sorted(x for x in env if x.startswith("MANIFOLD_")), began=datetime.datetime.now().isoformat(timespec="seconds"), freezes=[])
    defp = subprocess.Popen([f"{DEV}/defout", "100000", f"{OUT}/{label}.defout"])
    p = subprocess.Popen([app, "-manifold.decklink.audioDestination", dest, "-manifold.decklink.manualOutputMode", mode],
                         stdout=open(log, "w"), stderr=subprocess.STDOUT, env=env)
    pid = p.pid; meta["pid"] = pid; say(f"{label}: pid {pid}, {title}, {mode}, destination {dest}, {k} cycles, seed {seed}")
    def save(**kw): meta.update(kw); json.dump(meta, open(f"{OUT}/{label}.json", "w"), indent=1)
    def quit_build(why):
        r = sh(PROC, "quit", str(pid), "--timeout", "60")
        if r.returncode: say(f"pid {pid} did not quit ({r.returncode}: {r.stderr.strip()}); left running, stopping"); save(ended=why, quit="FAILED"); defp.terminate(); sys.exit(5)
        p.wait(); defp.terminate(); defp.wait(); guard(); save(ended=why, finished=datetime.datetime.now().isoformat(timespec="seconds"))
    save()
    time.sleep(7)
    if sh(PROC, "check", str(pid)).returncode: say("the build did not come up"); defp.terminate(); save(ended="no-launch"); sys.exit(4)
    deny_licence_prompt()
    sh(PROC, "open", str(pid), fixture); time.sleep(3.5)
    sh(AXT, str(pid), "place", title, "ASUS"); time.sleep(1.5)
    menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(2.5)
    txt = open(log, errors="replace").read()
    if "DeckLink: output start —" not in txt: say("output did not start"); quit_build("no-output"); sys.exit(4)
    if f"restored manual output mode {mode}" not in txt: say(f"the output mode {mode} was not applied"); quit_build("no-mode"); sys.exit(4)
    d = Freeze(); f = open(log, errors="replace"); buf = ""; last = time.monotonic(); t0 = time.monotonic(); fz = None
    budget = k * CYCLE_S + 16 + 600
    while True:
        chunk = f.read()
        if chunk:
            buf += chunk; lines = buf.split("\n"); buf = lines.pop()
            for l in lines: d.line(l)
        if p.poll() is not None:
            say(f"pid {pid} EXITED by itself, code {p.returncode}"); defp.terminate(); save(ended=f"exited {p.returncode}"); sys.exit(6)
        if fz is None and d.still():
            fz = dict(host=d.host, pts=d.pts, since_play=round(d.host - d.play, 2), wall=datetime.datetime.now().isoformat(timespec="seconds"))
            n = len(meta["freezes"]) + 1; say(f"FREEZE {n}: pts {d.pts}, {fz['since_play']} s after Play")
            sh("sample", str(pid), "5", "-file", f"{OUT}/{label}-freeze{n}.sample.txt"); fz["mono"] = time.monotonic()
        if fz is not None:
            if d.moved > fz["host"]:
                fz["recovered_after_s"] = round(d.moved - fz["host"] + STILL, 2); meta["freezes"].append({k2: v for k2, v in fz.items() if k2 != "mono"})
                say(f"picture moving again after {fz['recovered_after_s']} s"); save(); fz = None
            elif not d.playing:
                fz["recovered_after_s"] = None; fz["note"] = "paused while still"; meta["freezes"].append({k2: v for k2, v in fz.items() if k2 != "mono"}); save(); fz = None
            elif time.monotonic() - fz["mono"] > UNRECOVERED:
                fz["recovered_after_s"] = None; fz["note"] = f"still after {UNRECOVERED:.0f} s: block ended"; meta["freezes"].append({k2: v for k2, v in fz.items() if k2 != "mono"})
                say("UNRECOVERED freeze: ending the block"); quit_build("unrecovered freeze"); return
        if d.done: break
        if os.path.exists(f"{OUT}/STOP"): say("STOP file"); break
        if time.monotonic() - t0 > budget: say("transport did not finish in the budget"); break
        if time.monotonic() - last > 30: last = time.monotonic(); deny_licence_prompt()
        time.sleep(0.25)
    time.sleep(3)
    menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(2.5)
    menu(pid, "File", "Close All"); time.sleep(1.5)
    quit_build("STOP" if os.path.exists(f"{OUT}/STOP") else "done" if d.done else "budget"); say(f"{label}: done")

if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "block" and len(a) == 8:
        assert os.path.isfile(a[1]) and os.path.isfile(a[2]) and a[5] in ("sdi", "computer")
        block(a[1], a[2], float(a[3]), a[4], a[5], a[6], float(a[7]))
    elif a and a[0] == "report":
        os.execvp(sys.executable, [sys.executable, f"{HERE}/rc-soak-report.py"] + a[1:])
    else: sys.exit("rc-soak.py block <app> <fixture> <length s> <mode> <sdi|computer> <label> <minutes> | report <dir> <label>...")
