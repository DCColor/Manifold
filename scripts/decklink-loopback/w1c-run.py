#!/usr/bin/env python3
# SDI audio on the wire, Stage 1c measurement (docs/CARD_CLOCK_FINDINGS.md §10.16). One launch per run: the measurement build, a noise
# fixture (~/Code/_scratch/manifold-1c-wire/mkfixture.sh), destination SDI, DeckLink output on, `capture --audio --marks` open across the
# whole transport script, so every received picture and every received sample is kept. Analysis: w1c-wire.py.
#   w1c-run.py cont  <fixture.mov> <on|off> <label> <seconds>   one Play from 0, <seconds> of play, Pause
#   w1c-run.py plays <fixture.mov> <on|off> <label> <cycles>    per cycle: seek 0, Play 60 s, Pause, Play 60 s (mid-file), Pause
#   w1c-run.py transport <fixture.mov> <on|off> <label> <cycles>  per cycle (Stage 1c, §10.22): Play from 0, Pause, Play mid-file, seek
#       twice while playing, Pause, step 1 twice, Play, output stop and start while playing, Pause, seek 1905, loop on, play through the
#       wrap at 1920 s, Pause, loop off. Needs a 1920 s fixture.
#   w1c-run.py restarts <fixture.mov> <on|off> <label> <n>  Play, output stop and start (the arbiter pauses), Play, then n output
#       stops and starts while playing (the debug step does not go through the arbiter, as ⌃⌥O and a device switch do not), Pause.
# W1C_MODE=<label> (e.g. 1080p59.94) pins the output mode for the launch, a launch argument like the destination (argument domain, nothing
# written), for a fixture whose rate differs from the output's (Stage 1c follow-up C6, §10.23).
# W1C_NOCAP=1 runs the same script with `capture` never opened (§10.26): device 0's input stays closed for the whole launch, so its output
# clock is not moved. Nothing on the wire is recorded; read the bridge's own lines (the start check's consumption point, silent starts).
# W1C_CAP_MID=1 (follow-up 5, §10.26): every output start with the input closed, as W1C_NOCAP, then `capture --audio --marks` opened
# CAP_MID_OPEN s after each start the bridge logs (its `audio preroll:` line) and closed CAP_MID_CLOSE s after it, before the script's next
# stop (restarts: 12 s apart). Each open writes <label>.mid/cNNN.{raw,marks}; <label>.drv lists every start, open and close with the log's
# byte offset then (the app's lines carry no clock).
# Stage 2 (§10.27–§10.28): W1C_DEST=computer launches at destination Computer (default sdi; a launch argument, nothing written).
# W1C_DEVCLOCK=<uid>[|<uid>…] (a UID can hold a comma) runs `devclock` on each output device for the whole launch (<label>.<n>.devclock). W1C_SWITCHES=
# "<s>:<name part>,…" makes that output device the system default <s> seconds after the first Play (`defout set`); the default is read
# first, must be the Scarlett, and is set back to it at the end whatever happens. Environment such as MANIFOLD_CARDLOCK_STAGE2 and
# MANIFOLD_CARDCLOCK_AUDIO_DEVICE_UID reaches the build unchanged.
#   w1c-run.py flips <fixture.mov> <on|off> <label> <n>   Play, then n pairs of destination flips while playing (to SDI, 15 s, to
#       Computer, 15 s), Pause.
# W1C_LUMA=1 adds capture's --luma, for a sync clip (w1c-syncclip.py). on/off is the Stage 1b gate (MANIFOLD_CARDLOCK_1B=1 / unset). MANIFOLD_AUDIO_CORR_LOG=1 logs every PCM callback's correction.
# `capture` moves the card's output clock while it is open (§5); A/V offset and continuity are read on the same wire, so that is acceptable.
# Guarded before and after; launched by absolute path, held by PID, quit by PID through manifold-proc.sh. AX menu clicks on named items only,
# no keystrokes, no screenshots. The destination is a launch argument (argument domain): nothing is written to defaults.
import os, signal, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.dirname(os.path.dirname(HERE))
PROC = f"{REPO}/scripts/manifold-proc.sh"; AXT = f"{REPO}/build/linkpace/linkpace-ax"; DEV = f"{REPO}/build/decklink-loopback"
MID = os.environ.get("W1C_CAP_MID") == "1"   # capture opened mid-session only, never across a start
CAP_MID_OPEN, CAP_MID_CLOSE = 4.0, 10.0
NOCAP = os.environ.get("W1C_NOCAP") == "1" or MID   # no `capture` at all: the card's input stays closed (its output clock unmoved); nothing on the wire is kept
APP = os.environ.get("W1C_APP") or f"{REPO}/.build-cc/Build/Products/Profile/Manifold.app/Contents/MacOS/Manifold"   # W1C_APP: another build of this tree
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
    switches = [(float(a), b) for a, b in (x.split(":", 1) for x in os.environ.get("W1C_SWITCHES", "").split(",") if x)]
    if switches:
        before = sh(f"{DEV}/defout", "get").stdout.strip(); say(f"default output before: {before}")
        if "Scarlett 18i20" not in before: say("the default output is not the Scarlett: stopping, nothing changed"); sys.exit(4)
    defp = subprocess.Popen([f"{DEV}/defout", "100000", f"{OUT}/{label}.defout"])
    devc = [subprocess.Popen([f"{DEV}/devclock", u, "99999", f"{OUT}/{label}.{k}.devclock"]) for k, u in enumerate(x for x in os.environ.get("W1C_DEVCLOCK", "").split("|") if x)]
    env = dict(os.environ, MANIFOLD_CARDCLOCK_LOG="1", MANIFOLD_DECKLINK_CADENCE_LOG="1", MANIFOLD_PLAYBACK_STATS="1",
               MANIFOLD_AUDIO_CORR_LOG="1", MANIFOLD_DEBUG_TRANSPORT=steps)
    for k in ("MANIFOLD_CARDLOCK_1B", "MANIFOLD_RENDERER_RECOVER", "MANIFOLD_RENDERER_SELFTEST", "MANIFOLD_PUMPWATCH_SELFTEST"): env.pop(k, None)
    if gate: env["MANIFOLD_CARDLOCK_1B"] = "1"
    mode_args = ["-manifold.decklink.manualOutputMode", os.environ["W1C_MODE"]] if os.environ.get("W1C_MODE") else []
    dest = os.environ.get("W1C_DEST", "sdi"); assert dest in ("sdi", "computer")
    p = subprocess.Popen([APP, "-manifold.decklink.audioDestination", dest] + mode_args, stdout=open(log, "w"), stderr=subprocess.STDOUT, env=env)
    pid = p.pid; say(f"{label}: pid {pid}, gate {'on' if gate else 'off'}, {title}")
    cap = None; mid = {"cap": None, "n": 0, "open_at": None, "close_at": None, "off": 0, "drv": None}
    def mid_close(why):
        c = mid["cap"]
        if c and c.poll() is None: c.send_signal(signal.SIGINT); c.wait()
        if c: mid["drv"].write(f"close c{mid['n']:03d} mono {time.monotonic():.3f} logoff {os.path.getsize(log)} {why} rc {c.returncode}\n"); mid["drv"].flush()
        mid["cap"] = None; mid["close_at"] = None
    def restore_output():
        if not switches: return
        r = sh(f"{DEV}/defout", "set", "Scarlett 18i20"); after = sh(f"{DEV}/defout", "get").stdout.strip()
        with open(log, "a") as f: f.write(f"[DRV] default output restored: {after}\n")
        if "Scarlett 18i20" not in after: say(f"!! default output NOT restored: {after}")
    def quit_build():
        restore_output()
        for d in devc: d.terminate(); d.wait()
        if cap and cap.poll() is None: cap.send_signal(signal.SIGINT); cap.wait()
        if MID and mid["cap"]: mid_close("quit")
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
    if os.environ.get("W1C_MODE") and f"restored manual output mode {os.environ['W1C_MODE']}" not in open(log, errors="replace").read():
        say(f"the output mode {os.environ['W1C_MODE']} was not applied"); quit_build(); sys.exit(4)
    if MID:
        os.makedirs(f"{OUT}/{label}.mid", exist_ok=True); mid["drv"] = open(f"{OUT}/{label}.drv", "w")
        mid["drv"].write(f"# {label}: capture opened {CAP_MID_OPEN} s after each start's preroll line, closed at {CAP_MID_CLOSE} s\n")
    elif NOCAP:
        with open(log, "a") as f: f.write(f"[DRV] CAPTURE CLOSED for the whole run (W1C_NOCAP=1) mono {time.monotonic():.3f}\n")
    else:
        cap = subprocess.Popen([f"{DEV}/capture", "--device", "0", "--seconds", "99999", "--label", label, "--marks", f"{OUT}/{label}.marks",
                                "--audio", f"{OUT}/{label}.raw"] + (["--luma"] if os.environ.get("W1C_LUMA") == "1" else []), stdout=open(f"{OUT}/{label}.cap", "w"), stderr=subprocess.STDOUT)
        with open(log, "a") as f: f.write(f"[DRV] CAP-OPEN mono {time.monotonic():.3f}\n")
    last = time.monotonic(); play_at = None; sw_next = 0
    while True:
        if switches and sw_next < len(switches):
            if play_at is None and "[TRANSPORT] play" in open(log, errors="replace").read(): play_at = time.monotonic()
            if play_at is not None and time.monotonic() - play_at >= switches[sw_next][0]:
                r = sh(f"{DEV}/defout", "set", switches[sw_next][1])
                with open(log, "a") as f: f.write(f"[DRV] defout set {switches[sw_next][1]} mono {time.monotonic():.3f}: {r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr.strip()}\n")
                say(f"default output → {switches[sw_next][1]} (exit {r.returncode})"); sw_next += 1
        if p.poll() is not None:
            say(f"pid {pid} EXITED by itself, code {p.returncode}")
            if cap: cap.send_signal(signal.SIGINT); cap.wait()
            restore_output()
            for d in devc: d.terminate()
            defp.terminate(); sys.exit(4)
        if cap and cap.poll() is not None: say("capture ended by itself"); break
        if MID:   # the log read incrementally: a start schedules the next open; a stop line closes early
            with open(log, "rb") as f: f.seek(mid["off"]); chunk = f.read()
            nl = chunk.rfind(b"\n"); done = False
            if nl >= 0:
                text = chunk[:nl + 1].decode(errors="replace"); mid["off"] += nl + 1; now = time.monotonic()
                if "[SDI-AUDIO] stopped" in text and mid["cap"]: mid_close("stop seen")
                if "[SDI-AUDIO] audio preroll:" in text:
                    if mid["cap"]: mid_close("start seen")
                    mid["open_at"] = now + CAP_MID_OPEN; mid["close_at"] = None
                    mid["drv"].write(f"start seen mono {now:.3f} logoff {mid['off']}\n"); mid["drv"].flush()
                done = "[TRANSPORT] done" in text
            if done: break
            now = time.monotonic()
            if mid["open_at"] and now >= mid["open_at"]:
                mid["n"] += 1; b = f"{OUT}/{label}.mid/c{mid['n']:03d}"
                mid["cap"] = subprocess.Popen([f"{DEV}/capture", "--device", "0", "--seconds", "99999", "--label", f"{label}-c{mid['n']:03d}",
                                               "--marks", f"{b}.marks", "--audio", f"{b}.raw"], stdout=open(f"{OUT}/{label}.cap", "a"), stderr=subprocess.STDOUT)
                mid["drv"].write(f"open c{mid['n']:03d} mono {now:.3f} logoff {os.path.getsize(log)}\n"); mid["drv"].flush()
                mid["open_at"] = None; mid["close_at"] = now + (CAP_MID_CLOSE - CAP_MID_OPEN)
            if mid["close_at"] and now >= mid["close_at"]: mid_close("timed")
        elif "[TRANSPORT] done" in open(log, errors="replace").read(): break
        if time.monotonic() - t0 > budget: say("transport did not finish in the budget"); break
        if time.monotonic() - last > 30: last = time.monotonic(); deny_licence_prompt()
        time.sleep(0.25 if MID or switches else 2)
    if MID and mid["cap"]: mid_close("end")
    time.sleep(3)
    if cap: cap.send_signal(signal.SIGINT); cap.wait()
    menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(2.5)
    menu(pid, "File", "Close All"); time.sleep(1.5)
    quit_build(); say(f"{label}: done")

if __name__ == "__main__":
    mode, fixture, g, label, n = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])
    assert g in ("on", "off") and os.path.exists(fixture)
    if mode == "cont": steps = f"wait 16;play;wait {n};pause;wait 2"; budget = n + 120
    elif mode == "plays":
        steps = "wait 16;" + ";".join("seek 0;wait 3;play;wait 60;pause;wait 3;play;wait 60;pause;wait 3" for _ in range(n)); budget = n * 135 + 120
    elif mode == "transport":   # Stage 1c (§10.22): every run edge, per cycle; the file must be 1920 s (the loop wraps at its end)
        cyc = ("seek 0;wait 3;play;wait 20;pause;wait 4;play;wait 15;seek 600;wait 15;seek 300;wait 10;pause;wait 3;step 1;wait 2;step 1;wait 2;"
               "play;wait 15;output stop;wait 5;output start;wait 20;pause;wait 3;seek 1905;wait 3;loop;play;wait 30;pause;wait 3;loop;wait 2")
        steps = "wait 16;" + ";".join(cyc for _ in range(n)); budget = n * 230 + 120
    elif mode == "restarts":   # §10.22 follow-up: output stop and start while playing, n times (the first stop pauses: the arbiter)
        steps = ("wait 16;seek 0;wait 3;play;wait 10;output stop;wait 3;output start;wait 5;play;wait 12;"
                 + "".join("output stop;wait 3;output start;wait 12;" for _ in range(n)) + "pause;wait 3")
        budget = n * 15 + 170
    elif mode == "flips":   # Stage 2 W4 (§10.28): n pairs of destination flips while playing
        steps = "wait 16;seek 0;wait 3;play;wait 30;" + "".join("dest sdi;wait 15;dest computer;wait 15;" for _ in range(n)) + "pause;wait 3"
        budget = n * 30 + 170
    else: sys.exit("mode: cont | plays | transport | restarts | flips")
    run(fixture, g == "on", label, steps, budget)
