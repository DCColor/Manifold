#!/usr/bin/env python3
# SDI audio on the wire, Stage 1c measurement (docs/CARD_CLOCK_FINDINGS.md §10.16). One launch per run: the measurement build, a noise
# fixture (~/Code/_scratch/manifold-1c-wire/mkfixture.sh), destination SDI, DeckLink output on, `capture --audio --marks` open across the
# whole transport script, so every received picture and every received sample is kept. Analysis: w1c-wire.py.
#   w1c-run.py cont  <fixture.mov> <on|off> <label> <seconds>   one Play from 0, <seconds> of play, Pause
#   w1c-run.py plays <fixture.mov> <on|off> <label> <cycles>    per cycle: seek 0, Play 60 s, Pause, Play 60 s (mid-file), Pause
# on/off is the Stage 1b gate (MANIFOLD_CARDLOCK_1B=1 / unset). MANIFOLD_AUDIO_CORR_LOG=1 logs every PCM callback's correction.
# `capture` moves the card's output clock while it is open (§5); A/V offset and continuity are read on the same wire, so that is acceptable.
# Guarded before and after; launched by absolute path, held by PID, quit by PID through manifold-proc.sh. AX menu clicks on named items only,
# no keystrokes, no screenshots. The destination is a launch argument (argument domain): nothing is written to defaults.
import os, signal, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.dirname(os.path.dirname(HERE))
PROC = f"{REPO}/scripts/manifold-proc.sh"; AXT = f"{REPO}/build/linkpace/linkpace-ax"; DEV = f"{REPO}/build/decklink-loopback"
APP = f"{REPO}/.build-cc/Build/Products/Profile/Manifold.app/Contents/MacOS/Manifold"
OUT = os.environ.get("W1C_OUT", os.path.expanduser("~/Code/_scratch/manifold-1c-wire/runs"))

def sh(*a): return subprocess.run(a, capture_output=True, text=True)
def say(m): print(time.strftime("%H:%M:%S"), m, flush=True)
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

def run(fixture, gate, label, steps, budget):
    guard()
    if resolve_running(): say("Resolve is running: stopping"); sys.exit(4)
    os.makedirs(OUT, exist_ok=True); log = f"{OUT}/{label}.log"; title = os.path.basename(fixture)
    defp = subprocess.Popen([f"{DEV}/defout", "100000", f"{OUT}/{label}.defout"])
    env = dict(os.environ, MANIFOLD_CARDCLOCK_LOG="1", MANIFOLD_DECKLINK_CADENCE_LOG="1", MANIFOLD_PLAYBACK_STATS="1",
               MANIFOLD_AUDIO_CORR_LOG="1", MANIFOLD_DEBUG_TRANSPORT=steps)
    for k in ("MANIFOLD_CARDLOCK_1B", "MANIFOLD_RENDERER_RECOVER", "MANIFOLD_RENDERER_SELFTEST", "MANIFOLD_PUMPWATCH_SELFTEST"): env.pop(k, None)
    if gate: env["MANIFOLD_CARDLOCK_1B"] = "1"
    p = subprocess.Popen([APP, "-manifold.decklink.audioDestination", "sdi"], stdout=open(log, "w"), stderr=subprocess.STDOUT, env=env)
    pid = p.pid; say(f"{label}: pid {pid}, gate {'on' if gate else 'off'}, {title}")
    cap = None
    def quit_build():
        if cap and cap.poll() is None: cap.send_signal(signal.SIGINT); cap.wait()
        r = sh(PROC, "quit", str(pid), "--timeout", "60")
        if r.returncode: say(f"pid {pid} did not quit ({r.returncode}: {r.stderr.strip()}); left running, stopping"); defp.terminate(); sys.exit(5)
        p.wait(); defp.terminate(); defp.wait(); guard()
    time.sleep(7)
    if sh(PROC, "check", str(pid)).returncode: say("the build did not come up"); defp.terminate(); sys.exit(4)
    deny_licence_prompt()
    sh(PROC, "open", str(pid), fixture); t0 = time.monotonic(); time.sleep(3.5)
    sh(AXT, str(pid), "place", title, "ASUS"); time.sleep(1.5)
    menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(2.5)
    if "CARDCLOCK-REF] start" not in open(log, errors="replace").read(): say("output did not start"); quit_build(); sys.exit(4)
    cap = subprocess.Popen([f"{DEV}/capture", "--device", "0", "--seconds", "99999", "--label", label, "--marks", f"{OUT}/{label}.marks",
                            "--audio", f"{OUT}/{label}.raw"], stdout=open(f"{OUT}/{label}.cap", "w"), stderr=subprocess.STDOUT)
    with open(log, "a") as f: f.write(f"[DRV] CAP-OPEN mono {time.monotonic():.3f}\n")
    last = time.monotonic()
    while True:
        if p.poll() is not None: say(f"pid {pid} EXITED by itself, code {p.returncode}"); cap.send_signal(signal.SIGINT); cap.wait(); defp.terminate(); sys.exit(4)
        if cap.poll() is not None: say("capture ended by itself"); break
        if "[TRANSPORT] done" in open(log, errors="replace").read(): break
        if time.monotonic() - t0 > budget: say("transport did not finish in the budget"); break
        if time.monotonic() - last > 30: last = time.monotonic(); deny_licence_prompt()
        time.sleep(2)
    time.sleep(3)
    cap.send_signal(signal.SIGINT); cap.wait()
    menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(2.5)
    menu(pid, "File", "Close All"); time.sleep(1.5)
    quit_build(); say(f"{label}: done")

if __name__ == "__main__":
    mode, fixture, g, label, n = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])
    assert g in ("on", "off") and os.path.exists(fixture)
    if mode == "cont": steps = f"wait 16;play;wait {n};pause;wait 2"; budget = n + 120
    elif mode == "plays":
        steps = "wait 16;" + ";".join("seek 0;wait 3;play;wait 60;pause;wait 3;play;wait 60;pause;wait 3" for _ in range(n)); budget = n * 135 + 120
    else: sys.exit("mode: cont | plays")
    run(fixture, g == "on", label, steps, budget)
