#!/usr/bin/env python3
# A change of the system default output against SDI audio, without Jump (docs/CARD_CLOCK_FINDINGS.md §10.17). One launch of the measurement build:
# a file with sound, destination SDI, output on, capture CLOSED, gate off. One Play; `defout set` makes the built-in output the default 60 s
# after Play, the Scarlett again 30 s later, five times, 120 s apart. 75 s after each switch a Pause and Play (does a rate change restart a
# stalled pump?); 95 s after it a Pause, a seek and a Play (re-arms the request, so the next switch starts from a running pump). During each
# stall, `sample <pid> 10`.
#   w1c-defout.py <fixture.mov> <label>
# The default output is read before anything changes, must be the Scarlett, and is set back to it in a `finally` and read back, whatever happens.
# Guarded before and after; launched by absolute path, held by PID, quit by PID. AX menu clicks on named items only, no keystrokes, no screenshots.
import os, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.dirname(os.path.dirname(HERE))
PROC = f"{REPO}/scripts/manifold-proc.sh"; AXT = f"{REPO}/build/linkpace/linkpace-ax"; DEV = f"{REPO}/build/decklink-loopback"
APP = f"{REPO}/.build-cc/Build/Products/Profile/Manifold.app/Contents/MacOS/Manifold"
OUT = os.environ.get("W1C_OUT", os.path.expanduser("~/Code/_scratch/manifold-1c-wire/runs"))
HOME_DEV, OTHER_DEV = "Scarlett 18i20", "Mac Studio Speakers"
FIRST, EVERY, HOLD, N = 60, 120, 30, 5

def sh(*a): return subprocess.run(a, capture_output=True, text=True)
def say(m): print(time.strftime("%H:%M:%S"), m, flush=True)
def guard():
    r = sh(PROC, "guard")
    if r.returncode: say(f"GUARD TRIPPED, stopping: {r.stderr.strip()}"); sys.exit(2)
def menu(pid, bar, item):
    sh("osascript", "-e", f'tell application "System Events" to tell (first process whose unix id is {pid}) to click menu item "{item}" of menu 1 of menu bar item "{bar}" of menu bar 1')
def deny_licence_prompt():
    if sh("pgrep", "-x", "SecurityAgent").returncode: return
    t = sh("osascript", "-e", 'tell application "System Events" to tell process "SecurityAgent" to get value of static texts of window 1').stdout
    if "manifold" in t.lower(): sh("osascript", "-e", 'tell application "System Events" to tell process "SecurityAgent" to click button "Deny" of window 1')
def default_output(): return sh(f"{DEV}/defout", "get").stdout.strip()
def set_output(name, logf):
    r = sh(f"{DEV}/defout", "set", name); logf.write(r.stdout); logf.flush(); say(f"default output → {name}: {r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr.strip()} (exit {r.returncode})")
    return r.returncode == 0
def pcm_in_last(log, seconds):
    """PCM callbacks the bridge logged in the last `seconds` of host time (by the [CADENCE] host stamps)."""
    txt = open(log, errors="replace").read().splitlines()[-6000:]; host = None; last_pcm = None
    for l in txt:
        m = re.match(r"\[CADENCE\] #\d+ host (\S+)", l)
        if m: host = float(m[1]); continue
        if l.startswith("[AUDIO-CORR]") and host is not None: last_pcm = host
    return host is not None and last_pcm is not None and host - last_pcm < seconds

def main(fixture, label):
    guard(); os.makedirs(OUT, exist_ok=True); log = f"{OUT}/{label}.log"; title = os.path.basename(fixture)
    before = default_output(); say(f"default output before: {before}")
    if HOME_DEV not in before: say("the default output is not the Scarlett: stopping, nothing changed"); sys.exit(4)
    sw = open(f"{OUT}/{label}.switches", "w"); sw.write(f"before {before}\n")
    defp = subprocess.Popen([f"{DEV}/defout", "100000", f"{OUT}/{label}.defout"])
    steps = ["wait 16", "play", f"wait {FIRST + 75}"]
    for k in range(N):   # at switch + 75: Pause, Play; at + 95: Pause, seek, Play at + 97; then to the next switch + 75
        steps += ["pause", "wait 1", "play", "wait 19", "pause", f"seek {150 + 117 * k}", "wait 2", "play", "wait 98" if k < N - 1 else "wait 30"]
    steps += ["pause", "wait 2"]
    env = dict(os.environ, MANIFOLD_CARDCLOCK_LOG="1", MANIFOLD_DECKLINK_CADENCE_LOG="1", MANIFOLD_PLAYBACK_STATS="1", MANIFOLD_AUDIO_CORR_LOG="1",
               MANIFOLD_DEBUG_TRANSPORT=";".join(steps))
    for k in ("MANIFOLD_CARDLOCK_1B", "MANIFOLD_RENDERER_RECOVER", "MANIFOLD_RENDERER_SELFTEST", "MANIFOLD_PUMPWATCH_SELFTEST"): env.pop(k, None)
    p = subprocess.Popen([APP, "-manifold.decklink.audioDestination", "sdi"], stdout=open(log, "w"), stderr=subprocess.STDOUT, env=env)
    pid = p.pid; say(f"{label}: pid {pid}, gate off, {title}")
    try:
        time.sleep(7)
        if sh(PROC, "check", str(pid)).returncode: say("the build did not come up"); return
        deny_licence_prompt()
        sh(PROC, "open", str(pid), fixture); time.sleep(3.5)
        sh(AXT, str(pid), "place", title, "ASUS"); time.sleep(1.5)
        menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(2.5)
        if "CARDCLOCK-REF] start" not in open(log, errors="replace").read(): say("output did not start"); return
        t0 = time.monotonic()
        while "[TRANSPORT] play" not in open(log, errors="replace").read():
            if time.monotonic() - t0 > 60 or p.poll() is not None: say("no Play"); return
            time.sleep(0.1)
        P = time.monotonic(); say("Play")
        def at(t):
            while time.monotonic() < P + t:
                if p.poll() is not None: raise RuntimeError("the build exited")
                time.sleep(0.05)
        def smp(name):
            sw.write(f"sample {name} start {sh(f'{DEV}/defout', 'get').stdout.split()[0]}\n"); sw.flush()
            subprocess.run(["sample", str(pid), "10", "-file", f"{OUT}/{label}-{name}.sample.txt"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            sw.write(f"sample {name} end {sh(f'{DEV}/defout', 'get').stdout.split()[0]}\n"); sw.flush(); say(f"sampled {name}")
        at(25); smp("control")
        for k in range(N):
            s = FIRST + EVERY * k
            at(s); sw.write(f"switch {k + 1} to {OTHER_DEV}\n"); set_output(OTHER_DEV, sw)
            sampled = False
            for chk in (5, 12, 20):
                at(s + chk)
                if not pcm_in_last(log, 1.0): say(f"switch {k + 1}: SDI silent at +{chk} s"); smp(f"s{k + 1}-stall"); sampled = True; break
            if not sampled: say(f"switch {k + 1}: SDI still on PCM at +20 s")
            at(s + HOLD); sw.write(f"switch {k + 1} back to {HOME_DEV}\n"); set_output(HOME_DEV, sw)
            at(s + HOLD + 8)
            if not pcm_in_last(log, 1.0): say(f"switch {k + 1}: SDI silent 8 s after the restore"); smp(f"s{k + 1}-after-restore")
        while "[TRANSPORT] done" not in open(log, errors="replace").read():
            if p.poll() is not None or time.monotonic() - P > 800: break
            time.sleep(0.5)
        time.sleep(2)
        menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(2.5)
        menu(pid, "File", "Close All"); time.sleep(1.5)
    finally:
        now = default_output()
        if HOME_DEV not in now: say(f"restoring the default output (was {now})"); set_output(HOME_DEV, sw)
        final = default_output(); sw.write(f"final {final}\n"); sw.close(); say(f"default output at the end: {final}")
        if sh(PROC, "check", str(pid)).returncode == 0:
            r = sh(PROC, "quit", str(pid), "--timeout", "60")
            if r.returncode: say(f"pid {pid} did not quit ({r.returncode}: {r.stderr.strip()}); left running")
            else: p.wait()
        defp.terminate(); defp.wait(); guard(); say(f"{label}: done")

if __name__ == "__main__":
    main(os.path.abspath(sys.argv[1]), sys.argv[2])
