#!/usr/bin/env python3
# Release soak (0.9.3 gate, docs/Manifold-BUILD.md "Pre-release checklist"). One block = one launch of the release candidate, play cycles
# with seeks and loop wraps for <minutes>, DeckLink output on, capture never opened (the card's input stays closed).
#   rc-soak.py block <app binary> <fixture> <length s> <mode> <sdi|computer> <label> <minutes> [markers <n>]
#   rc-soak.py markers-setup <app binary> <fixture> <length s> <label> <n>      before a soak: give the file n markers (0.9.4)
#   rc-soak.py report <out dir> <label>...           the counts per block and in total (rc-soak-report.py does the work)
# The build runs the shipping configuration: every MANIFOLD_* variable is removed from the environment, and only observation and the
# scripted transport are set: MANIFOLD_DEBUG_TRANSPORT (seeks are key-only, and no keystroke is ever sent), MANIFOLD_DECKLINK_CADENCE_LOG
# (one [CADENCE] line per card pull: holds, skips and freezes are read from it), MANIFOLD_PLAYBACK_STATS (the window's late and dropped
# counts). None of them changes the card lock, Stage 2, the recovery paths or the audio routing. The output mode and the audio destination
# are launch arguments (argument domain): nothing is written to defaults.
# Guarded before and after; launched by absolute path, held by PID, quit by PID through manifold-proc.sh. AX menu clicks on named items
# only, no keystrokes, no screenshots. A freeze (the pulled picture still for 2 s while playing) is logged with a `sample` of the process;
# if the picture has not moved again 20 s later the block ends there (quit by PID). `touch <out dir>/STOP` ends a block cleanly.
# Markers (0.9.4 gate, `markers <n>`): the file carries n stored markers (Remember markers between sessions, set by markers-setup),
# the Markers slot is open with thumbnails on (defaults as they are; nothing is written). Every REGEN_EVERY s, while playing and
# 3 s clear of a transport step, gear ▸ Regenerate Thumbnails (rc-soak-ax, AX only). The thumbnails are not logged by the app; the
# disk cache is (MarkerThumbnails/v<N>/<fingerprint>/<frame>.jpg), so each remade JPEG's write time is read and put on the host
# clock (CLOCK_UPTIME_RAW = CACurrentMediaTime): one written before the next Pause is a thumbnail made while playing. That reads
# completion, not start (an in-flight one started in a pause may finish after Play; those are listed on their own). Card late /
# dropped and the window's late / dropped are stamped on the host clock as they are read (0.25 s), for rc-soak-report.py's windows.
import datetime, glob, hashlib, json, os, random, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.dirname(os.path.dirname(HERE))
PROC = f"{REPO}/scripts/manifold-proc.sh"; AXT = f"{REPO}/build/linkpace/linkpace-ax"; DEV = f"{REPO}/build/decklink-loopback"
OUT = os.environ.get("RC_OUT", os.path.expanduser("~/Code/_scratch/manifold-rc-soak"))
STILL, GRACE, UNRECOVERED = 2.0, 2.0, 20.0
AXS = f"{DEV}/rc-soak-ax"; THUMBS = os.path.expanduser("~/Library/Caches/com.graviton.manifold/MarkerThumbnails")
REGEN_EVERY, REGEN_CLEAR, REGEN_TRACK = 600.0, 3.0, 150.0

def uptime(): return time.clock_gettime(time.CLOCK_UPTIME_RAW)
def fingerprint(path, edge=4 * 1024 * 1024):
    """FileFingerprint.compute (Packages/ManifoldCore/Sources/Markers/FileFingerprint.swift): the thumbnail cache's folder name."""
    h = hashlib.sha256(b"manifold.markers.fingerprint.v1"); size = os.path.getsize(path); h.update(size.to_bytes(8, "little"))
    with open(path, "rb") as f:
        if size <= 2 * edge: h.update(f.read())
        else: h.update(f.read(edge)); f.seek(size - edge); h.update(f.read(edge))
    return h.hexdigest()
def thumbs(fp):
    """{frame jpg: write time (wall)} for this file, every cache version (the launch purges the others)."""
    out = {}
    for p in glob.glob(f"{THUMBS}/v*/{fp}/*.jpg"):
        try: out[os.path.basename(p)] = os.stat(p).st_mtime
        except OSError: pass
    return out

def sh(*a): return subprocess.run(a, capture_output=True, text=True)
def say(m): print(f"{datetime.datetime.now():%H:%M:%S} {m}", flush=True)
def guard():
    r = sh(PROC, "guard")
    if r.returncode: say(f"GUARD TRIPPED, stopping: {r.stderr.strip()}"); sys.exit(2)
def menu(pid, bar, item):
    sh("osascript", "-e", f'tell application "System Events" to tell (first process whose unix id is {pid}) to click menu item "{item}" of menu 1 of menu bar item "{bar}" of menu bar 1')
DENIED = 0   # licence prompts denied by this process (a click on Deny that osascript reported done); saved per block
def deny_licence_prompt():
    """An unsigned build's licence prompt, and only that: Deny writes nothing. Anything else on SecurityAgent is left alone."""
    global DENIED
    if sh("pgrep", "-x", "SecurityAgent").returncode: return
    t = sh("osascript", "-e", 'tell application "System Events" to tell process "SecurityAgent" to get value of static texts of window 1').stdout
    if "manifold" in t.lower():
        if sh("osascript", "-e", 'tell application "System Events" to tell process "SecurityAgent" to click button "Deny" of window 1').returncode == 0:
            DENIED += 1; say(f"licence prompt denied ({DENIED} this block)")
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

# The card-pull measurement build (docs/CARD_PULL_MARGIN.md, *Measurement build*) and option C's A/B (§7 C, MANIFOLD_PACER_PHASE):
# the only variables `env NAME=VALUE` may add. None changes the card lock, Stage 2, the recovery paths or the audio routing (option C
# moves the output pacer's deadlines by at most 20 µs a tick, and only while it is on); without `env` nothing here changes.
# The present-path measurement (docs/WINDOW_PRESENT_PATH.md §4.1, MANIFOLD_PRESENT_TIMING) only reads clocks and logs.
# C+ (docs/CARD_PULL_MARGIN.md §17.3, MANIFOLD_PACER_PHASE=2) moves the pacer's phase earlier inside option C's guard band, in steps of
# at most 0.5 ms; option B (docs/WINDOW_PRESENT_PATH.md §4.5, MANIFOLD_PACER_PRESENT_TX=0) changes only how the window's pacer
# presents reach the screen. Neither touches the pull, the card lock, Stage 2, the recovery paths or the audio routing.
# Since 0.9.5 C+ is the default with MANIFOLD_PACER_PHASE unset; a block without the phase hold sets MANIFOLD_PACER_PHASE=0.
EXTRA_ENV_ALLOWED = {"MANIFOLD_DECKLINK_CADENCE_LOG": {"1", "2"}, "MANIFOLD_DECKLINK_LATE_SWAP_AT": None, "MANIFOLD_PACER_PHASE": {"0", "1", "2"},
                     "MANIFOLD_PRESENT_TIMING": {"1"}, "MANIFOLD_PACER_PRESENT_TX": {"0"}}

def parse_extra_env(items):
    out = {}
    for it in items:
        name, eq, value = it.partition("=")
        allowed = EXTRA_ENV_ALLOWED.get(name, False)
        if not eq or allowed is False or (allowed is not None and value not in allowed):
            sys.exit(f"rc-soak.py: env {it!r} is not allowed (only {', '.join(sorted(EXTRA_ENV_ALLOWED))})")
        out[name] = value
    return out

def block(app, fixture, length, mode, dest, label, minutes, markers=0, extra_env=None, output=True):
    guard()
    if resolve_running(): say("Resolve is running: stopping"); sys.exit(4)
    os.makedirs(OUT, exist_ok=True); log = f"{OUT}/{label}.log"; title = os.path.basename(fixture)
    rng = random.Random(); seed = rng.randrange(1 << 30); rng.seed(seed)
    k = -(-int(minutes * 60) // CYCLE_S)
    steps = "wait 16;" + ";".join(cycle(rng, length) for _ in range(k))
    env = {k2: v for k2, v in os.environ.items() if not k2.startswith("MANIFOLD_")}
    env.update(MANIFOLD_DEBUG_TRANSPORT=steps, MANIFOLD_DECKLINK_CADENCE_LOG="1", MANIFOLD_PLAYBACK_STATS="1")
    if extra_env: env.update(extra_env)
    meta = dict(label=label, output=output, app=app, fixture=fixture, length=length, mode=mode, dest=dest, minutes=minutes, cycles=k, seed=seed,
                env=sorted(x for x in env if x.startswith("MANIFOLD_")), began=datetime.datetime.now().isoformat(timespec="seconds"), freezes=[])
    if extra_env: meta["extra_env"] = {k2: (f"{len(v.split(','))} entries" if k2 == "MANIFOLD_DECKLINK_LATE_SWAP_AT" else v) for k2, v in extra_env.items()}
    if markers: fp = fingerprint(fixture); meta.update(markers_expected=markers, fingerprint=fp[:16], regens=[], latedrop=[])
    defp = subprocess.Popen([f"{DEV}/defout", "100000", f"{OUT}/{label}.defout"])
    p = subprocess.Popen([app, "-manifold.decklink.audioDestination", dest, "-manifold.decklink.manualOutputMode", mode],
                         stdout=open(log, "w"), stderr=subprocess.STDOUT, env=env)
    pid = p.pid; meta["pid"] = pid; say(f"{label}: pid {pid}, {title}, {mode}, destination {dest}, {k} cycles, seed {seed}")
    def save(**kw): meta.update(kw, licence_prompts_denied=DENIED); json.dump(meta, open(f"{OUT}/{label}.json", "w"), indent=1)
    def quit_build(why):
        r = sh(PROC, "quit", str(pid), "--timeout", "60")
        if r.returncode: say(f"pid {pid} did not quit ({r.returncode}: {r.stderr.strip()}); left running, stopping"); save(ended=why, quit="FAILED"); defp.terminate(); sys.exit(5)
        p.wait(); defp.terminate(); defp.wait(); guard(); save(ended=why, finished=datetime.datetime.now().isoformat(timespec="seconds"))
    save()
    time.sleep(7)
    if sh(PROC, "check", str(pid)).returncode: say("the build did not come up"); defp.terminate(); save(ended="no-launch"); sys.exit(4)
    deny_licence_prompt()
    sh(PROC, "open", str(pid), fixture); time.sleep(3.5)
    # RC_PLACE=<display name substring> (optional, default "ASUS"): the display the window is placed on (linkpace-ax, AX only).
    place = os.environ.get("RC_PLACE", "ASUS"); save(window_place=place)
    sh(AXT, str(pid), "place", title, place); time.sleep(1.5)
    # Optional (RC_EXPECT_DISPLAY=<name>): the window's display before output starts, from the app's last [LINK] line. Logged and
    # saved; on any other display the block is skipped (quit by PID, exit 8) and the night goes on. Unset: nothing here runs.
    # Optional RC_EXPECT_HZ=<Hz>: that display's refresh too, within 0.5 Hz, or the block is skipped the same way.
    want = os.environ.get("RC_EXPECT_DISPLAY")
    if want:
        links = re.findall(r'^\[LINK\] window \d+ → display \d+ "([^"]+)" \(([\d.]+) Hz\) · ([^·]+)', open(log, errors="replace").read(), re.M)
        name, hz, how = links[-1] if links else (None, None, None)
        save(window_display=name, window_display_hz=hz, window_display_how=how and how.strip())
        say(f"window display: {name} at {hz} Hz ({how and how.strip()})")
        if name != want:
            say(f"window is not on {want}: block skipped"); quit_build("wrong-display"); sys.exit(8)
        want_hz = os.environ.get("RC_EXPECT_HZ")
        if want_hz and not (hz and abs(float(hz) - float(want_hz)) <= 0.5):
            say(f"window display is at {hz} Hz, not {want_hz}: block skipped"); quit_build("wrong-refresh"); sys.exit(8)
    # `nooutput` (option C's identity block): DeckLink output is never started, so the window's display link ticks, not the pacer.
    if output: menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(2.5)
    txt = open(log, errors="replace").read()
    if not output:
        if "DeckLink: output start —" in txt: say("output started in a nooutput block"); quit_build("output-on"); sys.exit(4)
    elif "DeckLink: output start —" not in txt: say("output did not start"); quit_build("no-output"); sys.exit(4)
    elif f"restored manual output mode {mode}" not in txt: say(f"the output mode {mode} was not applied"); quit_build("no-mode"); sys.exit(4)
    if markers:
        m = re.findall(r"\[MARKERS\] loaded n=(\d+)", txt); slot = sh(AXS, str(pid), "gear")
        save(markers_loaded=int(m[-1]) if m else None, markers_slot=slot.returncode == 0, thumbs_at_start=len(thumbs(fp)))
        say(f"markers: loaded {meta['markers_loaded']}, Markers slot {'open' if meta['markers_slot'] else 'NOT FOUND'}, "
            f"{meta['thumbs_at_start']} thumbnails cached")
    regen = None; next_regen = time.monotonic() + REGEN_EVERY; last_ev = 0.0; stats_late = stats_drop = 0
    d = Freeze(); f = open(log, errors="replace"); buf = ""; last = time.monotonic(); t0 = time.monotonic(); fz = None
    budget = k * CYCLE_S + 16 + 600
    while True:
        chunk = f.read()
        if chunk:
            buf += chunk; lines = buf.split("\n"); buf = lines.pop()
            for l in lines:
                d.line(l)
                if not markers: continue
                now = uptime()
                if l.startswith("[TRANSPORT] "):
                    hm = re.search(r" host (\S+)", l); hh = float(hm[1]) if hm else now; last_ev = hh; w = l.split()[1]
                    if regen and w == "pause" and regen.get("pause_host") is None: regen["pause_host"] = hh
                    elif regen and w == "play" and regen.get("pause_host") is not None and regen.get("next_play_host") is None: regen["next_play_host"] = hh
                elif "[MARKERS] regenerate thumbnails n=" in l and regen and regen.get("app_n") is None:
                    regen["app_n"] = int(re.search(r"n=(\d+)", l)[1])
                elif l.startswith("DeckLink D3: !! DisplayedLate"): meta["latedrop"].append([round(now, 3), "card late", 1])
                elif l.startswith("DeckLink D3: !! Dropped"): meta["latedrop"].append([round(now, 3), "card dropped", 1])
                else:
                    sm = re.match(r"\[PLAYBACK-STATS\] t=\S+ presented=\d+ dropped=(\d+) late=(\d+)", l)
                    if sm and (int(sm[1]) or int(sm[2])): meta["latedrop"].append([round(now, 3), "window dropped/late", int(sm[1]) + int(sm[2])])
                if len(meta["latedrop"]) > 5000: del meta["latedrop"][:1000]
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
        if markers and regen is None and time.monotonic() >= next_regen and d.playing and uptime() - last_ev >= REGEN_CLEAR:
            before = thumbs(fp); h0 = uptime(); w0 = time.time(); r = sh(AXS, str(pid), "regen")
            regen = dict(n=len(meta["regens"]) + 1, host=round(h0, 3), wall=datetime.datetime.now().isoformat(timespec="seconds"),
                         offset=w0 - h0, ax=r.stdout.strip(), ax_rc=r.returncode, cached_before=len(before), w0=w0,
                         pause_host=None, next_play_host=None, app_n=None, removed=0, mono=time.monotonic())
            next_regen += REGEN_EVERY
            say(f"regenerate {regen['n']} while playing: {regen['ax']} (rc {r.returncode})")
        if regen is not None:
            cur = thumbs(fp)
            regen["removed"] = max(regen["removed"], regen["cached_before"] - sum(1 for t in cur.values() if t <= regen["w0"]))
            new = sorted(t - regen["offset"] for t in cur.values() if t > regen["w0"])
            if len(new) >= markers or time.monotonic() - regen["mono"] > REGEN_TRACK or regen["ax_rc"]:
                ph, nh = regen["pause_host"], regen["next_play_host"]
                regen.update(made=[round(x, 3) for x in new],
                             made_while_playing=sum(1 for x in new if ph is None or x < ph),
                             made_in_pause=sum(1 for x in new if ph is not None and x >= ph and (nh is None or x < nh)),
                             finished_after_play=sum(1 for x in new if nh is not None and x >= nh),
                             first_after_pause_s=round(new[0] - ph, 3) if new and ph is not None and new[0] >= ph else None)
                say(f"regenerate {regen['n']}: app n={regen['app_n']}, removed {regen['removed']}, remade {len(new)}; while playing "
                    f"{regen['made_while_playing']}, in the pause {regen['made_in_pause']}, finished after Play {regen['finished_after_play']}"
                    + ("  !! A THUMBNAIL WAS MADE WHILE PLAYING" if regen["made_while_playing"] else ""))
                meta["regens"].append({k2: v for k2, v in regen.items() if k2 not in ("mono", "w0", "offset")}); save(); regen = None
        if d.done: break
        if os.path.exists(f"{OUT}/STOP"): say("STOP file"); break
        if time.monotonic() - t0 > budget: say("transport did not finish in the budget"); break
        if time.monotonic() - last > 30: last = time.monotonic(); deny_licence_prompt()
        time.sleep(0.25)
    if regen is not None:   # ended while tracking: keep what was seen
        meta["regens"].append({k2: v for k2, v in regen.items() if k2 not in ("mono", "w0", "offset")} | dict(note="block ended while tracking"))
    time.sleep(3)
    if output: menu(pid, "File", "Start/Stop DeckLink Output"); time.sleep(2.5)
    menu(pid, "File", "Close All"); time.sleep(1.5)
    quit_build("STOP" if os.path.exists(f"{OUT}/STOP") else "done" if d.done else "budget"); say(f"{label}: done")

def markers_setup(app, fixture, length, label, n):
    """Give the file n markers before a soak, through the menus (Mark ▸ Add Marker, paused, at n evenly spaced seeks), and check
    the thumbnail path the soak relies on: the n thumbnails reach the disk cache, and gear ▸ Regenerate Thumbnails (AX) remakes
    them while paused. Stored by Remember markers between sessions, so the soak's launches load them. A file that already has n
    markers gets none added; one with some other number is left alone (exit 7: nothing of the user's is deleted). No output."""
    guard()
    if resolve_running(): say("Resolve is running: stopping"); sys.exit(4)
    os.makedirs(OUT, exist_ok=True); log = f"{OUT}/{label}.log"; title = os.path.basename(fixture); fp = fingerprint(fixture)
    at = [round(length * (i + 0.5) / n, 2) for i in range(n)]
    steps = "wait 4;" + ";".join(f"seek {x:.2f};wait 6" for x in at) + ";wait 4"
    env = {k: v for k, v in os.environ.items() if not k.startswith("MANIFOLD_")}; env.update(MANIFOLD_DEBUG_TRANSPORT=steps)
    meta = dict(label=label, app=app, fixture=fixture, setup=True, at=at, fingerprint=fp[:16], began=datetime.datetime.now().isoformat(timespec="seconds"))
    p = subprocess.Popen([app], stdout=open(log, "w"), stderr=subprocess.STDOUT, env=env); pid = p.pid; meta["pid"] = pid
    def save(**kw): meta.update(kw); json.dump(meta, open(f"{OUT}/{label}.json", "w"), indent=1)
    def text(): return open(log, errors="replace").read()
    def done(why, code):
        r = sh(PROC, "quit", str(pid), "--timeout", "60")
        if r.returncode: say(f"pid {pid} did not quit ({r.returncode}: {r.stderr.strip()}); left running"); save(ended=why, quit="FAILED"); sys.exit(5)
        p.wait(); guard(); save(ended=why, finished=datetime.datetime.now().isoformat(timespec="seconds")); say(f"{label}: {why}"); sys.exit(code)
    say(f"{label}: pid {pid}, {title}, markers at {at} s"); save()
    time.sleep(7)
    if sh(PROC, "check", str(pid)).returncode: say("the build did not come up"); save(ended="no-launch"); sys.exit(4)
    deny_licence_prompt()
    sh(PROC, "open", str(pid), fixture); time.sleep(3.5)
    sh(AXT, str(pid), "place", title, "ASUS")
    t0 = time.monotonic()
    while "[MARKERS] loaded n=" not in text():
        if time.monotonic() - t0 > 30: say("no [MARKERS] loaded line"); menu(pid, "File", "Close All"); time.sleep(1.5); done("no-markers-line", 7)
        time.sleep(0.25)
    k = int(re.findall(r"\[MARKERS\] loaded n=(\d+)", text())[-1]); slot = sh(AXS, str(pid), "gear").returncode == 0
    save(loaded=k, markers_slot=slot); say(f"loaded {k} markers; Markers slot {'open' if slot else 'NOT FOUND'}")
    if not slot: menu(pid, "File", "Close All"); time.sleep(1.5); done("no-markers-slot", 7)
    if k not in (0, n): say(f"the file already has {k} markers, not {n}: left alone"); menu(pid, "File", "Close All"); time.sleep(1.5); done("other-markers", 7)
    seen = 0
    while k == 0 and seen < n:
        if time.monotonic() - t0 > 30 + 8 * n: say("the seeks did not arrive"); break
        seeks = text().count("[TRANSPORT] seek ")
        if seeks > seen:
            seen = seeks; time.sleep(2.5); menu(pid, "Mark", "Add Marker"); time.sleep(1.0)
        time.sleep(0.25)
    adds = re.findall(r"\[MARKERS\] add n=(\d+)", text()); have = int(adds[-1]) if adds else k
    save(added=len(adds), have=have); say(f"markers now {have} ({len(adds)} added)")
    t1 = time.monotonic()
    while len(thumbs(fp)) < have and time.monotonic() - t1 < 60: time.sleep(0.5)
    cached = len(thumbs(fp)); save(thumbs_cached=cached); say(f"{cached} thumbnails in the disk cache")
    # The paused Regenerate comes after the scripted seeks have all run ([TRANSPORT] done), on a file at rest: a file that already
    # had its markers skips the adds and would otherwise press it mid-seek. (On 4067abb nothing was remade either way: stored
    # markers that load before the file's rate get no thumbnails, docs/BUGS.md 2026-11-15. Thumbnails cached is checked above.)
    while "[TRANSPORT] done" not in text() and time.monotonic() - t0 < 40 + 8 * n: time.sleep(0.25)
    save(transport_done_before_regen="[TRANSPORT] done" in text())
    w0 = time.time(); r = sh(AXS, str(pid), "regen"); t2 = time.monotonic()
    while time.monotonic() - t2 < 60 and sum(1 for t in thumbs(fp).values() if t > w0) < have: time.sleep(0.5)
    regen_line = re.findall(r"\[MARKERS\] regenerate thumbnails n=(\d+)", text()); remade = sum(1 for t in thumbs(fp).values() if t > w0)
    save(regen_ax=r.stdout.strip(), regen_rc=r.returncode, regen_app_n=int(regen_line[-1]) if regen_line else None, regen_remade=remade)
    say(f"paused Regenerate: {r.stdout.strip()}, app n={meta['regen_app_n']}, remade {remade}")
    ok = have == n and cached == n and r.returncode == 0 and meta["regen_app_n"] == n and remade == n
    menu(pid, "File", "Close All"); time.sleep(1.5)
    done("ready" if ok else "NOT ready", 0 if ok else 7)

if __name__ == "__main__":
    a = sys.argv[1:]
    extra = {}
    if a and a[0] == "block" and "env" in a:   # rc-soak.py block … [markers <n>] [nooutput] env NAME=VALUE …
        i = a.index("env"); extra = parse_extra_env(a[i + 1:]); a = a[:i]
    output = not (a and a[0] == "block" and a[-1] == "nooutput")
    if not output: a = a[:-1]
    if a and a[0] == "block" and len(a) in (8, 10):
        assert os.path.isfile(a[1]) and os.path.isfile(a[2]) and a[5] in ("sdi", "computer") and (len(a) == 8 or a[8] == "markers")
        block(a[1], a[2], float(a[3]), a[4], a[5], a[6], float(a[7]), int(a[9]) if len(a) == 10 else 0, extra, output)
    elif a and a[0] == "markers-setup" and len(a) == 6:
        assert os.path.isfile(a[1]) and os.path.isfile(a[2])
        markers_setup(a[1], a[2], float(a[3]), a[4], int(a[5]))
    elif a and a[0] == "report":
        os.execvp(sys.executable, [sys.executable, f"{HERE}/rc-soak-report.py"] + a[1:])
    else: sys.exit("rc-soak.py block <app> <fixture> <length s> <mode> <sdi|computer> <label> <minutes> [markers <n>] [nooutput] [env NAME=VALUE …] | "
                  "markers-setup <app> <fixture> <length s> <label> <n> | report <dir> <label>...")
