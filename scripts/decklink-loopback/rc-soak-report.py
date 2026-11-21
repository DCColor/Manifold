#!/usr/bin/env python3
# Release soak report (rc-soak.py). For each block's log, and in total:
#   freezes            the pulled picture still for 2 s while playing (2 s after a Play), from [CADENCE]
#   holds / skips      while playing at a matched rate, each pull should hand the frame Δslot frames on from the last (Δslot = the
#                      difference of the pull's slot number #N; 1 in steady state). Fewer is a hold, more a skip. Not counted: pulls
#                      within EXCL s after a Play, a seek or a loop toggle (the transport's own jump), the loop's wrap at the end of the
#                      file, and the first STARTX s of the launch.
#   renderer           the picture-freeze watchdog (docs/PICTURE_FREEZE_AUDIT.md): stalls (an "attempt 1" line; one per episode however
#                      many re-arms), re-arm attempts, recovered ("picture moving again"), rebuilds, GAVE UP; [RENDERER-NEARMISS]. Each stall
#                      and near-miss is listed per block with its line, time in the state, silence, outcome and hold. Since 0.9.5 the
#                      watchdog recovers at WD_IN_STATE s in the state with no pump callback for WD_SILENCE s (was 0.5 s); a near-miss is a
#                      state over WD_NEARMISS s that cleared by itself. A stall taken with under WD_OLD_SILENCE s of silence is marked
#                      "sooner than the old 0.5 s wait": a recovery the old build would not yet have made, so the one to read if the
#                      shorter wait ever recovers a state that would have cleared. Any stall in a soak is unexpected (none in 15.7 h of
#                      release soaks); a GAVE UP is unrecovered. The last "[DIAG] playback counters" line's renderer counts are checked
#                      against the log's.
#   silent starts      "[SDI-AUDIO] !! output start" lines other than "started off its picture" (the §10.24 flush restart, counted on
#                      its own); recovered when the whole-output restart's start then logs "started with its picture". A "NOT restarted"
#                      line, or a restart that never starts with sound, is unrecovered. The frames held around the loop's wrap (a seek)
#                      are counted on their own and not as holds.
#   SDI (bridge)       every "[SDI-AUDIO] !!" line by kind, and the "[SDI-AUDIO] stopped" totals (late edges, missing samples, re-latches,
#                      edges appended by the card)
#   SDI sound          continuity (docs/SDI_AUDIO_NIGHT7.md), on a block whose log has "[SDI-AUDIO] runs path entered":
#                      1. callback stopped: "[SDI-AUDIO] !! no audio callback" (or, as a backstop, more than CB_BACKSTOP "DeckLink D3:
#                         frame" lines in a row with no "[SDI-AUDIO] runs:" line). Recovered when a "runs:" line, "the card's sound
#                         started with its picture" or "[SDI-AUDIO-RECOVER] sound back" follows within CB_RECOVER s (the watchdog's
#                         output restart, counted like a renderer recovery: reported, allowed); otherwise unrecovered.
#                      2. missing sound while playing: the "runs:" lines' cumulative missing count (one line per second of stream),
#                         not judged with the gate silent or within EXCL s after a Play, seek, loop or step. MISS_STREAK judged lines
#                         in a row at MISS_RUN samples or more, or one at MISS_BIG or more, is an event. Recovered when a judged line
#                         under MISS_RUN follows (Pause and Play do not end it); unrecovered when it ends at a seek, a loop, a step,
#                         an output stop or the end of the log.
#                      3. Stage 2: a start more than ST2_BOUND ms "into the SDI picture's run", or a re-anchor more than ST2_BOUND ms
#                         off. An event, unrecovered, unless check 2 found an event within ST2_MERGE s after it (the same incident,
#                         judged there). "[CARDLOCK] refused:" (the guard working) and "sound clock moved" re-reads are reported only.
#                      Unrecovered events of all three count in the gate's "unrecovered".
#   late / dropped     the card's "DeckLink D3: !!" lines; the window's [PLAYBACK-STATS] sums
#   markers (0.9.4)    per Regenerate Thumbnails while playing (rc-soak.py `markers <n>`): the app's count, thumbnails removed and
#                      remade, how many were made while playing (written before the next Pause: must be 0), in the pause, or finished
#                      after Play resumed; and holds / skips / late / dropped in two windows: ±WIN s around the press, and from the
#                      Pause to WIN s after the last thumbnail was made (the next Play included). Those are inside the totals above too.
#   0.9.5 GATE         the 0.9.5 release gate as written in Manifold-BUILD.md (Robbie, 2026-11-19, amended 2026-11-20), on its own line
#                      after the GATE line above (the 0.9.3 rule, unchanged: other tools parse it). Every block run:
#                      1. 0 freezes, 0 unrecovered events (as GATE: freezes, silent starts, renderer GAVE UP, silent-start recovery
#                         dropped, SDI sound continuity);
#                      2. 0 holds or skips for any cause except a renderer recovery: a hold or skip whose pull lies from the stall's start
#                         (the attempt line's [CADENCE] host less its "no pump callback" time, − 0.05 s) to 0.5 s after the first pull
#                         after "picture moving again" (night 7's rule, ab-check.py `causes`). A GAVE UP stall excuses nothing;
#                      3. card drops: only the frame #0 start drop (the first completion after StartScheduledPlayback is `result 2 stream 0`
#                         and it is the first Dropped line since that start; night 7's `card_drops`). Any other Dropped line fails. Card
#                         late lines are reported. This reads the gate's named exception as excluding every other drop (night 7's reading);
#                      4. B1, re-stated (Robbie, 2026-11-20): pacer missed deadlines ≤ 2, from the block's last "[PACER] stopped" line,
#                         less those whose overrunning step is the post-seek first-frame render: a "[PRESENT-TIMING] miss" that overran
#                         `perform`, a new-frame tick, a [TRANSPORT] seek ≤ 0.5 s before it and no [CADENCE-SWAP] between (night 7's
#                         `post_seek_perform`; its deadlines are the next interval in periods less one). Without [PRESENT-TIMING] lines
#                         (MANIFOLD_PRESENT_TIMING unset, as on a release soak) nothing can be subtracted: a block with ≤ 2 passes, a
#                         block with more is UNDETERMINED (it may be post-seek renders the log cannot name), and so is the gate;
#                      5. markers, on every block run with markers (the MARKERS line);
#                      and in all: 6. at least 6 h, judged on wall time (block start → finish, from <label>.json), as 0.9.3 and 0.9.4 were
#                         accepted (0.9.3: 6 h 07 min wall, 5.60 h playing); playing hours are printed beside it.
#                      Checked beside it, not part of the verdict: the last "[DIAG] playback counters" line against the log (pacer missed
#                      deadlines = [PACER] stopped; card holds while playing = the gate's holds; SDI audio stops = check 1's callback stops).
#   zoom.us            recorded only, in no verdict (Robbie, 2026-11-21): the soak harness's zoom.us watch writes each zoom.us process's
#                      appearance and disappearance (time, PID, process name) to <dir>/rig.log; listed per block (running at the block's
#                      start, and every event from its start to its finish) and in a ZOOM.US line. A rig.log with no watch lines reads
#                      "not recorded" (the harness before 2026-11-21 stopped the night instead).
#   rc-soak-report.py <dir> <label>...     (labels without .log)
import bisect, collections, datetime, json, re, sys
EXCL, STARTX, WRAP, WIN = 1.0, 20.0, 30, 10.0
# SDI sound continuity (docs/SDI_AUDIO_NIGHT7.md). Missing counts are at 48 kHz, the soak fixtures' rate. Since 0.9.3 no SDI block had
# more than ~5,100 missing in one second, more than 1 s in a row at MISS_RUN, or a run of over 2 "D3: frame" lines without "runs:".
CB_RECOVER, CB_BACKSTOP = 10.0, 5
MISS_RUN, MISS_BIG, MISS_STREAK = 4800, 24000, 3
ST2_BOUND, ST2_MERGE = 1000.0, 10.0
# The 0.9.5 gate's readings (night 7's ab-check.py, ~/Code/_scratch/manifold-pacerphase-ab6).
B1_MAX, PS_WINDOW, GATE_HOURS = 2, 0.5, 6.0
PTMISS = re.compile(r"\[PRESENT-TIMING\] miss · host (\S+) · tick (\S+) ms · next interval (\S+) ms \(P (\S+) ms\) · (\S+) tick · attempts: (.*?) · overran: (.+?) (\S+) ms")
PACER_STOP = re.compile(r"\[PACER\] stopped .*missed deadlines (\d+)")
COMPL = re.compile(r"\[CADENCE\] completion result (\d+) stream (\d+) ")
DROPPED = re.compile(r"DeckLink D3: !! Dropped at frame (\d+)")
DIAG_PC = re.compile(r"\[DIAG\] playback counters .*pacer missed deadlines (\d+) · card holds while playing (\d+) · .*SDI audio (\d+) stops?, (\d+) recovered")
# The renderer watchdog's thresholds as built (RendererWatchdog.Thresholds.shipping), for the report's header and marks.
WD_NEARMISS, WD_IN_STATE, WD_SILENCE, WD_OLD_SILENCE = 0.10, 0.15, 0.20, 0.5
FRAME = {"1080p59.94": 1001 / 60000, "1080p23.98": 1001 / 24000, "2160p59.94": 1001 / 60000, "2160p23.98": 1001 / 24000,
         "1080p25": 1 / 25, "2160p25": 1 / 25}

def analyse(path, mode, length):
    f = FRAME[mode]; r = collections.Counter(); kinds = collections.Counter(); ev = []; holds = []; stopped = []
    sdi_sound_tracker.f = f
    playing = False; play_host = None; events = []; prev = None; first_host = None; host = 0.0; played = 0.0
    pending_recover = 0; silent = []; last_wrap = -1e9
    stalls = []; nearmisses = []; diag = None
    seeks = []; swaps = []; ptmiss = []; pacer_stop = None; drops = []; comps = 0; first_comp = None; drops_since = 0; diag_pc = None
    snd = sdi_sound_tracker(); snd.f = f
    for ln, l in enumerate(open(path, errors="replace"), 1):
        snd.line(ln, l, host, events)
        m = re.match(r"\[CADENCE\] #(\d+) host (\S+) pts (\S+)", l)
        if m:
            n, host, pts = int(m[1]), float(m[2]), m[3]
            if first_host is None: first_host = host
            if pts == "nan": prev = None; continue
            pts = float(pts); cur = (n, host, pts)
            if playing and prev and host - first_host > STARTX and not any(0 <= host - e <= EXCL for e in events[-4:]):
                dslot = n - prev[0]; dn = round((pts - prev[2]) / f)
                if dslot > 0 and dn != dslot:
                    wrap = dn < -WRAP and prev[2] > length - 5
                    if wrap: r["wraps"] += 1; last_wrap = host
                    elif prev[2] > length - 0.5 or host - last_wrap <= EXCL:   # the loop's wrap is a seek: its frames held around it
                        r["holds at the loop's wrap (a seek, not counted)" if dn < dslot else "skips at the loop's wrap (a seek, not counted)"] += 1
                    elif dn < dslot: holds.append(("hold", host, prev[2], pts, dslot, dn))
                    else: holds.append(("skip", host, prev[2], pts, dslot, dn))
                if dslot > 1: r["missed slots"] += dslot - 1
                if dslot > 0: r["pulls while playing"] += 1
            if stalls and stalls[-1].get("moved_line") and "moved_host" not in stalls[-1]: stalls[-1]["moved_host"] = host
            prev = cur; continue
        if l.startswith("[TRANSPORT] "):
            m = re.search(r" host (\S+)", l); h = float(m[1]) if m else host
            w = l.split()[1]
            if w == "play": playing = True; play_host = h; events.append(h); r["plays"] += 1
            elif w == "pause":
                if playing and play_host: played += h - play_host
                playing = False; events.append(h)
            elif w in ("seek", "loop", "step", "shuttle"):
                events.append(h); r[w + "s"] += 1
                if w == "seek": seeks.append(h)
            elif w == "output":   # an output stop pauses through the arbiter, with no pause line: the run ends here
                if playing and play_host: played += h - play_host
                playing = False; events.append(h); r["output steps"] += 1
            continue
        if l.startswith("[RENDERER-RECOVER] attempt"):
            r["renderer recovery attempts"] += 1
            m = re.match(r"\[RENDERER-RECOVER\] attempt (\d+):.*?in the state ([\d.]+) s, no pump callback for ([\d.]+) s", l)
            if m and int(m[1]) == 1:
                r["renderer stalls"] += 1
                stalls.append(dict(line=ln, host=host, in_state=float(m[2]), silence=float(m[3]), attempts=1, rebuilt=False, outcome="open"))
            elif m and stalls: stalls[-1]["attempts"] = int(m[1])
        elif l.startswith("[RENDERER-RECOVER] picture moving again"):
            r["renderer recoveries"] += 1
            m = re.search(r"first frame in (\d+) ms after the \S+, ([\d.]+) s after the stall began", l)
            if stalls and stalls[-1]["outcome"] == "open":
                stalls[-1]["outcome"] = "recovered"; stalls[-1]["moved_line"] = ln
                if m: stalls[-1]["first_ms"] = int(m[1]); stalls[-1]["hold_s"] = float(m[2])
        elif l.startswith("[RENDERER-RECOVER] REBUILD"):
            r["renderer rebuilds"] += 1
            if stalls: stalls[-1]["rebuilt"] = True
        elif l.startswith("[RENDERER-RECOVER] GAVE UP"):
            r["renderer GAVE UP"] += 1
            if stalls: stalls[-1]["outcome"] = "GAVE UP"
        elif l.startswith("[RENDERER-RECOVER] DISABLED"): r["renderer would recover (recovery off)"] += 1
        elif l.startswith("[RENDERER-NEARMISS]"):
            r["renderer near-misses"] += 1
            m = re.search(r"for (\d+) ms, cleared by itself", l)
            nearmisses.append(dict(line=ln, host=host, ms=int(m[1]) if m else None, past="past the recovery point" in l))
        elif l.startswith("[DIAG] playback counters"):
            mp = DIAG_PC.search(l)
            diag_pc = dict(pacer=int(mp[1]), card_holds=int(mp[2]), sdi_stops=int(mp[3]), sdi_recovered=int(mp[4])) if mp else "old format"
            m = re.search(r"renderer (\d+) stalls? \((\d+) recovered, (\d+) GAVE UP\), (\d+) re-arms?, (\d+) rebuilds?, (\d+) near-miss", l)
            diag = dict(stalls=int(m[1]), recovered=int(m[2]), gave_up=int(m[3]), rearms=int(m[4]), rebuilds=int(m[5]),
                        nearmisses=int(m[6])) if m else "old format"
        elif l.startswith("DeckLink: output start —"): r["output starts"] += 1
        elif l.startswith("[SDI-AUDIO] output start: the card's sound started with its picture"):
            r["starts with sound"] += 1
            if pending_recover: pending_recover -= 1; silent[-1]["recovered"] = True
        elif l.startswith("[SDI-AUDIO] !! output start") and "started off its picture" in l:
            r["starts off the picture, flushed and restarted (§10.24)"] += 1   # not a silent start; one may follow
        elif l.startswith("[SDI-AUDIO] !! output start"):
            s = dict(line=l.strip()[:200], recovered=False); silent.append(s)
            if "restarting the whole output" in l: pending_recover += 1
        elif l.startswith("[SDI-AUDIO] the silent-start recovery's start dropped"): r["silent-start recovery dropped"] += 1
        if l.startswith("[SDI-AUDIO] !!"):
            k = "edge APPENDED by the card" if "APPENDED" in l else "output start" if "!! output start" in l else re.sub(r"[-+]?\d[\d.]*", "N", l[15:60]).strip()
            kinds[k] += 1
        elif l.startswith("[SDI-AUDIO] stopped"):
            g = lambda pat: int(re.search(pat, l)[1]) if re.search(pat, l) else 0
            stopped.append(dict(late_edges=g(r"late edges (\d+)"), missing=g(r"missing (-?\d+) samples"), relatches=g(r"re-latches (\d+)"),
                                appended=g(r"edges appended by the card (\d+)")))
        elif l.startswith("DeckLink D3: !! DisplayedLate"): r["card late"] += 1
        elif l.startswith("DeckLink D3: !! Dropped"):
            r["card dropped"] += 1
            m = DROPPED.match(l)
            drops.append(dict(line=ln, frame=int(m[1]) if m else None, start_drop=comps == 1 and first_comp == ("2", "0") and drops_since == 0))
            drops_since += 1
        elif "StartScheduledPlayback(" in l: comps = 0; first_comp = None; drops_since = 0
        elif l.startswith("[CADENCE] completion result"):
            m = COMPL.match(l)
            if m:
                comps += 1
                if comps == 1: first_comp = (m[1], m[2])
        elif l.startswith("[CADENCE-SWAP] host "):
            try: swaps.append(float(l.split()[2]))
            except (IndexError, ValueError): pass
        elif l.startswith("[PRESENT-TIMING] miss"):
            m = PTMISS.match(l)
            if m: ptmiss.append(dict(line=ln, host=float(m[1]), tick=float(m[2]), next=float(m[3]), P=float(m[4]), kind=m[5], step=m[7], ms=float(m[8])))
        elif l.startswith("[PACER] stopped"):
            m = PACER_STOP.search(l)
            if m: pacer_stop = int(m[1])
        else:
            m = re.match(r"\[PLAYBACK-STATS\] t=\S+ presented=(\d+) dropped=(\d+) late=(\d+)", l)
            if m: r["window presented"] += int(m[1]); r["window dropped"] += int(m[2]); r["window late"] += int(m[3])
    # freezes, offline: the same rule as the live detector
    fz = []; playing = False; ph = 0.0; moved = 0.0; last = None; open_fz = None
    for l in open(path, errors="replace"):
        m = re.match(r"\[CADENCE\] #\d+ host (\S+) pts (\S+)", l)
        if m:
            h = float(m[1])
            if m[2] != last: last = m[2]; moved = h
            if open_fz and moved > open_fz["host"]: open_fz["recovered_after_s"] = round(moved - open_fz["host"] + 2.0, 2); open_fz = None
            if playing and not open_fz and h - max(moved, ph + 2.0) >= 2.0: open_fz = dict(host=h, pts=last, recovered_after_s=None); fz.append(open_fz)
        elif l.startswith("[TRANSPORT] play"): playing = True; ph = float(re.search(r" host (\S+)", l)[1]); open_fz = None
        elif l.startswith("[TRANSPORT] pause") or l.startswith("[TRANSPORT] output"): playing = False; open_fz = None
    tot = {k: sum(s[k] for s in stopped) for k in ("late_edges", "missing", "relatches", "appended")}
    return dict(counts=dict(r), played_h=round(played / 3600, 3), freezes=fz, holds=holds, sdi_lines=dict(kinds), sdi_stopped=tot, silent=silent,
                sdi_sound=snd.finish(host), stalls=stalls, nearmisses=nearmisses, diag=diag,
                seeks=sorted(seeks), swaps=sorted(swaps), ptmiss=ptmiss, pacer_stop=pacer_stop, drops=drops, diag_pc=diag_pc)

def post_seek_perform(miss, seeks, swaps):
    """B1's re-statement (night 7's ab-check.py): overran `perform`, a new-frame tick, a seek ≤ PS_WINDOW s before, no swap between."""
    if miss["step"] != "perform" or miss["kind"] != "new-frame": return None
    j = bisect.bisect_left(seeks, miss["host"]) - 1
    if j < 0 or miss["host"] - seeks[j] > PS_WINDOW: return None
    k = bisect.bisect_right(swaps, seeks[j])
    if k < len(swaps) and swaps[k] < miss["host"]: return None
    return seeks[j]

def miss_deadlines(miss): return max(1, round(miss["next"] / miss["P"]) - 1)

def gate095_block(a, meta, unrec_block, markers_ok):
    """The 0.9.5 gate's rows for one block (header). Returns (verdict PASS/FAIL/UNDETERMINED, [detail strings])."""
    c = a["counts"]; out = []; v = "PASS"
    def fail(): nonlocal v; v = "FAIL"
    if a["freezes"] or unrec_block: fail()
    out.append(f"freezes {len(a['freezes'])}, unrecovered {unrec_block}")
    wins = [(st["host"] - st["silence"] - 0.05, st["moved_host"] + 0.5) for st in a["stalls"] if "moved_host" in st]
    exc = [h for h in a["holds"] if any(lo <= h[1] <= hi for lo, hi in wins)]
    bad = [h for h in a["holds"] if h not in exc]
    if bad: fail()
    out.append("holds/skips other than a renderer recovery " + (", ".join(f"{h[0]} at host {h[1]:.3f}" for h in bad) or "none")
               + f"; in a renderer recovery {len(exc)}")
    other = [d for d in a["drops"] if not d["start_drop"]]
    if other: fail()
    out.append(f"card dropped {len(a['drops'])} (frame #0 start drop: " + (", ".join(f"line {d['line']} frame {d['frame']}" for d in a["drops"] if d["start_drop"]) or "none")
               + "; other: " + (", ".join(f"line {d['line']} frame {d['frame']}" for d in other) or "none") + f"), card late {c.get('card late', 0)} (reported)")
    stop = a["pacer_stop"]
    if stop is None:
        out.append("B1: no [PACER] stopped line (UNDETERMINED)")
        if v == "PASS": v = "UNDETERMINED"
    else:
        ps = [(m, s) for m in a["ptmiss"] if (s := post_seek_perform(m, a["seeks"], a["swaps"])) is not None]
        sub = sum(miss_deadlines(m) for m, _ in ps); counted = stop - sub
        detail = f"B1: counted {counted} = [PACER] stopped {stop} − post-seek perform {sub}"
        if a["ptmiss"] or counted <= B1_MAX:
            if not a["ptmiss"] and stop: detail += " (no [PRESENT-TIMING] lines: nothing subtracted)"
            if counted > B1_MAX: fail()
        else:
            detail += f" — over {B1_MAX} with no [PRESENT-TIMING] lines: post-seek renders cannot be named (UNDETERMINED)"
            if v == "PASS": v = "UNDETERMINED"
        if ps: detail += "; post-seek perform misses (reported): " + ", ".join(f"line {m['line']} perform {m['ms']:.1f} ms, {miss_deadlines(m)} deadline(s), {1e3 * (m['host'] - s):.0f} ms after the seek" for m, s in ps)
        out.append(detail)
    if markers_ok is False: fail()
    out.append("markers " + ("n/a (no markers)" if markers_ok is None else "PASS" if markers_ok else "FAIL"))
    d = a["diag_pc"]; ss = a["sdi_sound"]
    nh = len(a["holds"])
    if d is None: out.append("[DIAG] check: no [DIAG] playback counters line")
    elif d == "old format": out.append("[DIAG] check: older format, not checked")
    else:
        cb = len(ss["cb"]) if ss["applies"] else 0
        same = d["pacer"] == stop and d["card_holds"] == nh and d["sdi_stops"] == cb
        out.append(f"[DIAG] check: pacer {d['pacer']} vs {stop}, card holds {d['card_holds']} vs the gate's holds/skips {nh}, SDI audio stops "
                   f"{d['sdi_stops']} vs callback stops {cb}: {'agree' if same else 'DIFFER'} (checked, not in the verdict)")
    return v, out

def wall_hours(meta):
    try: return (datetime.datetime.fromisoformat(meta["finished"]) - datetime.datetime.fromisoformat(meta["began"])).total_seconds() / 3600
    except (KeyError, ValueError, TypeError): return 0.0

def renderer_report(a):
    """The picture-freeze watchdog's lines for one block: counts, each stall and near-miss, and the [DIAG] cross-check."""
    c = a["counts"]
    print(f"   renderer: stalls {c.get('renderer stalls', 0)} (recovered {c.get('renderer recoveries', 0)}, GAVE UP {c.get('renderer GAVE UP', 0)}), "
          f"re-arm attempts {c.get('renderer recovery attempts', 0)}, rebuilds {c.get('renderer rebuilds', 0)}, near-misses "
          f"{c.get('renderer near-misses', 0)}" + (f", would recover (recovery off) {c['renderer would recover (recovery off)']}"
                                                   if c.get("renderer would recover (recovery off)") else ""))
    for st in a["stalls"]:
        sooner = st["silence"] < WD_OLD_SILENCE
        print(f"     stall at line {st['line']} (host {st['host']:.3f}): in the state {st['in_state']:.3f} s, no callback {st['silence']:.3f} s"
              f"{' (sooner than the old 0.5 s wait)' if sooner else ''}; {st['attempts']} re-arm(s){', rebuilt' if st['rebuilt'] else ''}; "
              f"{st['outcome']}" + (f", picture moving {st['hold_s']:.3f} s after the stall began, first frame {st['first_ms']} ms after the "
                                    f"last step" if "hold_s" in st else "") + "  !! UNEXPECTED")
    for nm in a["nearmisses"]:
        print(f"     near-miss at line {nm['line']} (host {nm['host']:.3f}): {nm['ms']} ms, cleared by itself"
              f"{' (past the recovery point; recovery off)' if nm['past'] else ''}")
    d = a["diag"]
    if d == "old format":
        print("   renderer [DIAG] line: older format (recoveries counted as attempts), not checked")
    elif d:
        log = dict(stalls=c.get("renderer stalls", 0), recovered=c.get("renderer recoveries", 0), gave_up=c.get("renderer GAVE UP", 0),
                   rearms=c.get("renderer recovery attempts", 0), rebuilds=c.get("renderer rebuilds", 0), nearmisses=c.get("renderer near-misses", 0))
        same = all(d[k] == log[k] for k in d)
        print(f"   renderer [DIAG] line (last one): {d}; {'matches the log' if same else 'DIFFERS from the log ' + str(log) + ' (a stall after the last output stop is not in it)'}")

class sdi_sound_tracker:
    """The three SDI sound continuity checks (header). Fed every line before analyse() reads it, with the newest [CADENCE] host and the
    transport events so far."""
    def __init__(self):
        self.runs_path = False; self.d3_since_runs = 0
        self.cb = None; self.cb_events = []
        self.miss_prev = None; self.cand = 0; self.miss = None; self.miss_events = []
        self.st2 = []; self.refused = 0; self.rereads = 0; self.restarts = 0; self.gave_up = 0; self.back = 0
        self.nev = 0

    def close_cb(self, recovered, host):
        c = self.cb; c["recovered"] = recovered; c["seconds"] = round(self.cb_elapsed(host), 1); self.cb_events.append(c); self.cb = None

    def cb_elapsed(self, host):
        c = self.cb
        return max(host - c["host"], c["d3"] * 48 * c["f"]) if c else 0.0

    def close_miss(self, recovered, why):
        m = self.miss; m["recovered"] = recovered; m["ended"] = why; self.miss_events.append(m); self.miss = None

    def line(self, ln, l, host, events):
        if l.startswith("[TRANSPORT] "):
            w = l.split()[1] if len(l.split()) > 1 else ""
            if w in ("seek", "loop", "step", "output"):
                if self.miss: self.close_miss(False, f"{w} at line {ln}")
                self.cand = 0
            return
        if l.startswith("[SDI-AUDIO] runs path entered"): self.runs_path = True
        elif l.startswith("[SDI-AUDIO-RECOVER] the card's audio callback stopped"): self.restarts += 1
        elif l.startswith("[SDI-AUDIO-RECOVER] GAVE UP"): self.gave_up += 1
        elif l.startswith("[CARDLOCK] refused:"): self.refused += 1
        elif l.startswith("[CARDLOCK] sound clock moved") and "reading the sound again" in l: self.rereads += 1
        recovery = (l.startswith("[SDI-AUDIO] runs:") or l.startswith("[SDI-AUDIO] output start: the card's sound started with its picture")
                    or l.startswith("[SDI-AUDIO-RECOVER] sound back"))
        if l.startswith("[SDI-AUDIO-RECOVER] sound back"): self.back += 1
        if self.cb and recovery: self.close_cb(self.cb_elapsed(host) <= CB_RECOVER, host)
        if l.startswith("[SDI-AUDIO] !! no audio callback"):
            if not self.cb:
                fm = re.search(r"\(frame (\d+)\)", l)
                self.cb = dict(line=ln, host=host, frame=int(fm[1]) if fm else None, d3=0, f=self.f, kind="no audio callback")
        elif l.startswith("DeckLink D3: frame"):
            self.d3_since_runs += 1
            if self.cb: self.cb["d3"] += 1
            elif self.runs_path and self.d3_since_runs > CB_BACKSTOP:
                self.cb = dict(line=ln, host=host, frame=None, d3=0, f=self.f, kind=f"over {CB_BACKSTOP} D3 lines with no runs line")
        elif l.startswith("[SDI-AUDIO] runs:"):
            self.d3_since_runs = 0
            m = re.search(r"missing (-?\d+) samples.*gate (\w+)", l)
            if not m: return
            v, gate = int(m[1]), m[2]
            prev, self.miss_prev = self.miss_prev, v
            judged = gate == "open" and not any(0 <= host - e <= EXCL for e in events[-4:])
            if prev is None or not judged: return
            d = v - prev
            if d >= MISS_RUN:
                if self.cand == 0: self.cand_from = (ln, host); self.cand_samples = 0
                self.cand += 1; self.cand_samples += d
                if self.miss is None and (self.cand >= MISS_STREAK or d >= MISS_BIG):   # from the streak's first line
                    self.miss = dict(line=self.cand_from[0], host=self.cand_from[1], lines=self.cand - 1, samples=self.cand_samples - d)
                if self.miss: self.miss["lines"] += 1; self.miss["samples"] += d
            else:
                if self.miss: self.close_miss(True, f"sound back at line {ln}")
                self.cand = 0
        elif l.startswith("[SDI-AUDIO] stopped") or l.startswith("DeckLink D3: stopped"):
            # An output stop. The callback check stays open across it: the watchdog's restart is a stop and a start, and its
            # recovery is judged by the time to the new output's sound.
            self.d3_since_runs = 0; self.miss_prev = None; self.cand = 0
            if self.miss: self.close_miss(False, f"output stop at line {ln}")
        else:
            m = re.match(r"\[CARDLOCK\] Stage 2: Mac sound starts ([\d.]+) ms into the SDI picture's run", l)
            if m and float(m[1]) > ST2_BOUND: self.st2.append(dict(line=ln, host=host, kind="late start", ms=float(m[1])))
            m = re.match(r"\[CARDLOCK\] Mac sound re-anchored.* it was ([-+][\d.]+) ms off", l)
            if m and abs(float(m[1])) > ST2_BOUND: self.st2.append(dict(line=ln, host=host, kind="re-anchor", ms=float(m[1])))

    def finish(self, host):
        if self.cb: self.close_cb(False, host)
        if self.miss: self.close_miss(False, "end of the log")
        for s in self.st2:
            s["merged"] = any(0 <= m["host"] - s["host"] <= ST2_MERGE for m in self.miss_events)
        unrec = (sum(not c["recovered"] for c in self.cb_events) + sum(not m["recovered"] for m in self.miss_events)
                 + sum(not s["merged"] for s in self.st2))
        return dict(applies=self.runs_path, cb=self.cb_events, miss=self.miss_events, st2=self.st2, refused=self.refused,
                    rereads=self.rereads, restarts=self.restarts, gave_up=self.gave_up, back=self.back, unrecovered=unrec,
                    recovered=sum(c["recovered"] for c in self.cb_events) + sum(m["recovered"] for m in self.miss_events))

def markers_report(meta, a, total):
    rg = meta["regens"]; ld = meta.get("latedrop", [])
    print(f"   markers: expected {meta['markers_expected']}, loaded {meta.get('markers_loaded')}, Markers slot "
          f"{'open' if meta.get('markers_slot') else 'NOT FOUND'}, thumbnails cached at start {meta.get('thumbs_at_start')}; "
          f"Regenerate while playing {len(rg)}")
    ok = meta.get("markers_loaded") == meta["markers_expected"] and meta.get("markers_slot")
    def window(lo, hi):
        hs = [h for h in a["holds"] if lo <= h[1] <= hi]
        lds = collections.Counter()
        for t, k, n in ld:
            if lo <= t <= hi: lds[k] += n
        return sum(1 for h in hs if h[0] == "hold"), sum(1 for h in hs if h[0] == "skip"), dict(lds)
    for r in rg:
        w1 = window(r["host"] - WIN, r["host"] + WIN)
        end = (max(r["made"]) if r.get("made") else (r["pause_host"] or r["host"])) + WIN
        w2 = window(r["pause_host"], end) if r.get("pause_host") is not None else (0, 0, {})
        good = r.get("ax_rc") == 0 and r.get("app_n") == meta["markers_expected"] and len(r.get("made", [])) == meta["markers_expected"] \
            and r.get("made_while_playing") == 0
        ok = ok and good
        print(f"     regen {r['n']} at {r['wall']}: {r.get('ax')}; app n={r.get('app_n')}, removed {r.get('removed')}, remade "
              f"{len(r.get('made', []))}: while playing {r.get('made_while_playing')}, in the pause {r.get('made_in_pause')}, finished after "
              f"Play {r.get('finished_after_play')}, first {r.get('first_after_pause_s')} s after Pause{'' if good else '  !!'}"
              + (f" ({r['note']})" if r.get("note") else ""))
        print(f"        around the press ±{WIN:.0f} s: holds {w1[0]}, skips {w1[1]}, late/dropped {w1[2] or 'none'}; "
              f"Pause → last thumbnail +{WIN:.0f} s: holds {w2[0]}, skips {w2[1]}, late/dropped {w2[2] or 'none'}")
        total["markers regenerates"] += 1; total["markers thumbnails remade"] += len(r.get("made", []))
        total["markers thumbnails made while playing"] += r.get("made_while_playing") or 0
        total["markers thumbnails finished after Play resumed"] += r.get("finished_after_play") or 0
        total["markers holds+skips near regenerate"] += w1[0] + w1[1] + w2[0] + w2[1]
        total["markers late/dropped near regenerate"] += sum(w1[2].values()) + sum(w2[2].values())
    if not ok: total["markers blocks failing"] += 1
    total["markers blocks"] += 1
    return bool(ok)

ZOOM_EV = re.compile(r"zoom\.us watch: (appeared|disappeared|present at start) pid (\d+) · (.+?) · at (\S+)\s*$")
def zoom_events(d):
    """The harness's zoom.us watch lines in <dir>/rig.log: (watched, [(time, kind, pid, name)]). Recorded only."""
    try: lines = open(f"{d}/rig.log", errors="replace").read().splitlines()
    except OSError: return False, []
    ev = []
    for l in lines:
        m = ZOOM_EV.search(l)
        if m:
            try: ev.append((datetime.datetime.fromisoformat(m[4]), m[1], int(m[2]), m[3]))
            except ValueError: pass
    return any("zoom.us watch started" in l for l in lines), ev

def zoom_block(meta, watched, ev):
    if not watched: return "   zoom.us: not recorded (no zoom.us watch in rig.log)"
    try: b, f = datetime.datetime.fromisoformat(meta["began"]), datetime.datetime.fromisoformat(meta["finished"])
    except (KeyError, TypeError, ValueError): return "   zoom.us: block start or finish unknown, not placed"
    alive = {}
    for t, k, pid, name in ev:
        if t >= b: break
        if k == "disappeared": alive.pop(pid, None)
        else: alive[pid] = (name, t)
    inside = [e for e in ev if b <= e[0] <= f]
    parts = [f"running at the start: " + (", ".join(f"pid {p} {n} (since {t:%H:%M:%S})" for p, (n, t) in alive.items()) or "none")]
    parts.append("events in the block: " + (", ".join(f"{t:%H:%M:%S} {k} pid {p} {n}" for t, k, p, n in inside) or "none"))
    return "   zoom.us (recorded only): " + " · ".join(parts)

def main(d, labels):
    total = collections.Counter(); allh = 0.0; gate = []; g95 = []; wall = 0.0
    zwatched, zev = zoom_events(d); zspans = []
    for lab in labels:
        try: meta = json.load(open(f"{d}/{lab}.json")); open(f"{d}/{lab}.log").close()
        except OSError: print(f"== {lab}: no record (the block stopped before its launch)"); continue
        a = analyse(f"{d}/{lab}.log", meta["mode"], meta["length"])
        c = a["counts"]; allh += a["played_h"]
        nh = sum(1 for h in a["holds"] if h[0] == "hold"); ns = sum(1 for h in a["holds"] if h[0] == "skip")
        unrec_fz = sum(1 for z in a["freezes"] if z["recovered_after_s"] is None)
        unrec_ss = sum(1 for s in a["silent"] if not s["recovered"])
        print(f"== {lab}: {meta['fixture'].split('/')[-1]}, {meta['mode']}, destination {meta['dest']}, ended {meta.get('ended')}, "
              f"{meta.get('began')} → {meta.get('finished')}")
        print(f"   played {a['played_h']:.2f} h, Plays {c.get('plays', 0)}, seeks {c.get('seeks', 0)}, loop wraps {c.get('wraps', 0)}, "
              f"pulls while playing {c.get('pulls while playing', 0)}, missed slots {c.get('missed slots', 0)}")
        print(f"   freezes {len(a['freezes'])} (unrecovered {unrec_fz}); holds {nh}, skips {ns}")
        for h in a["holds"][:20]: print(f"     {h[0]} at host {h[1]:.3f}: pts {h[2]:.6f} → {h[3]:.6f}, slots +{h[4]}, frames {h[5]:+d}")
        for z in a["freezes"]: print(f"     freeze at host {z['host']:.3f}, pts {z['pts']}, recovered after {z['recovered_after_s']} s")
        renderer_report(a)
        print(f"   output starts {c.get('output starts', 0)}, starts with sound {c.get('starts with sound', 0)}, silent starts {len(a['silent'])} "
              f"(recovered {sum(s['recovered'] for s in a['silent'])}, unrecovered {unrec_ss})")
        print(f"   SDI bridge: !! lines {a['sdi_lines'] or 'none'}; stopped totals {a['sdi_stopped']}")
        ss = a["sdi_sound"]
        if not ss["applies"]:
            print("   SDI sound continuity: n/a (no file sound on the card's timeline)")
        else:
            ucb = sum(not c["recovered"] for c in ss["cb"]); umi = sum(not m["recovered"] for m in ss["miss"])
            ust = sum(not s["merged"] for s in ss["st2"])
            print(f"   SDI sound continuity: callback stops {len(ss['cb'])} (unrecovered {ucb}), missing-sound events {len(ss['miss'])} "
                  f"(unrecovered {umi}), Stage 2 over {ST2_BOUND:.0f} ms {len(ss['st2'])} (counted alone {ust}); watchdog restarts "
                  f"{ss['restarts']}, sound back {ss['back']}, gave up {ss['gave_up']}; Stage 2 refused {ss['refused']}, re-reads {ss['rereads']}")
            for ev in ss["cb"]:
                print(f"     callback stop at line {ev['line']} ({ev['kind']}), {'recovered' if ev['recovered'] else 'UNRECOVERED'} after {ev['seconds']} s")
            for m in ss["miss"]:
                print(f"     missing sound from line {m['line']}: {m['lines']} s judged, {m['samples']} samples, "
                      f"{'recovered' if m['recovered'] else 'UNRECOVERED'} ({m['ended']})")
            for s2 in ss["st2"]:
                print(f"     Stage 2 {s2['kind']} {s2['ms']:+.1f} ms at line {s2['line']}"
                      f"{' (same incident as a missing-sound event)' if s2['merged'] else ' (UNRECOVERED event)'}")
        print(f"   late/dropped: card late {c.get('card late', 0)}, card dropped {c.get('card dropped', 0)}; window late {c.get('window late', 0)}, "
              f"dropped {c.get('window dropped', 0)} of {c.get('window presented', 0)} presented")
        print(zoom_block(meta, zwatched, zev))
        try: zspans.append((datetime.datetime.fromisoformat(meta["began"]), datetime.datetime.fromisoformat(meta["finished"])))
        except (KeyError, TypeError, ValueError): pass
        mk = markers_report(meta, a, total) if "regens" in meta else None
        ub = (unrec_fz + unrec_ss + c.get("renderer GAVE UP", 0) + c.get("silent-start recovery dropped", 0) + a["sdi_sound"]["unrecovered"])
        gv, gd = gate095_block(a, meta, ub, mk); g95.append((lab, gv)); wall += wall_hours(meta)
        print(f"   0.9.5 gate: {gv} — " + " · ".join(gd))
        for k, v in c.items(): total[k] += v
        total["renderer stalls sooner than 0.5 s"] += sum(1 for st in a["stalls"] if st["silence"] < WD_OLD_SILENCE)
        total["freezes"] += len(a["freezes"]); total["unrecovered freezes"] += unrec_fz; total["holds"] += nh; total["skips"] += ns
        total["silent starts"] += len(a["silent"]); total["unrecovered silent starts"] += unrec_ss
        for k, v in a["sdi_stopped"].items(): total["sdi " + k] += v
        total["sdi sound unrecovered"] += a["sdi_sound"]["unrecovered"]; total["sdi sound recovered"] += a["sdi_sound"]["recovered"]
        for k, v in a["sdi_lines"].items(): total["sdi !! " + k] += v
    print(f"== TOTAL: {allh:.2f} h played over {len(labels)} blocks")
    if not zwatched:
        print("== ZOOM.US (recorded only, in no verdict): not recorded (no zoom.us watch in rig.log)")
    else:
        app = [e for e in zev if e[1] != "disappeared"]
        inb = [e for e in app if any(b <= e[0] <= f for b, f in zspans)]
        print(f"== ZOOM.US (recorded only, in no verdict): appearances {len(app)} (in blocks {len(inb)}, outside {len(app) - len(inb)})"
              + ("; " + ", ".join(f"{t:%H:%M:%S} {k} pid {p} {n}" for t, k, p, n in zev) if zev else ""))
    print(f"== RENDERER WATCHDOG (recovers at {WD_IN_STATE * 1e3:.0f} ms in the state with no callback for {WD_SILENCE * 1e3:.0f} ms; "
          f"near-miss over {WD_NEARMISS * 1e3:.0f} ms): stalls {total['renderer stalls']} (recovered {total['renderer recoveries']}, "
          f"GAVE UP {total['renderer GAVE UP']}), sooner than the old 0.5 s wait {total['renderer stalls sooner than 0.5 s']}, "
          f"near-misses {total['renderer near-misses']}" + ("  !! UNEXPECTED: read each stall above" if total["renderer stalls"]
                                                            or total["renderer near-misses"] else ""))
    for k in sorted(total): print(f"   {k}: {total[k]}")
    unrec = (total["unrecovered freezes"] + total["unrecovered silent starts"] + total["renderer GAVE UP"] + total["silent-start recovery dropped"]
             + total["sdi sound unrecovered"])
    ok = total["freezes"] == 0 and unrec == 0 and total["holds"] + total["skips"] == 0
    if total["markers blocks"]:
        mk = total["markers blocks failing"] == 0 and total["markers thumbnails made while playing"] == 0
        print(f"== MARKERS (every Regenerate pressed and remade all thumbnails, none made while playing): {'PASS' if mk else 'FAIL'} — "
              f"regenerates {total['markers regenerates']}, made while playing {total['markers thumbnails made while playing']}, "
              f"blocks failing {total['markers blocks failing']}; near them: holds+skips {total['markers holds+skips near regenerate']}, "
              f"late/dropped {total['markers late/dropped near regenerate']}")
    print(f"== GATE (0 freezes, 0 unrecovered events, 0 holds/skips beyond expected cadence): {'PASS' if ok else 'FAIL'} — "
          f"freezes {total['freezes']}, unrecovered {unrec} (SDI sound {total['sdi sound unrecovered']}; recovered, allowed: "
          f"{total['sdi sound recovered']}), holds {total['holds']}, skips {total['skips']}")
    vs = [v for _, v in g95]
    hours_ok = wall >= GATE_HOURS
    g = "FAIL" if "FAIL" in vs or not hours_ok or not vs else "UNDETERMINED" if "UNDETERMINED" in vs else "PASS"
    print(f"== 0.9.5 GATE (Manifold-BUILD.md: 0 freezes, 0 unrecovered events, 0 holds for any cause except a renderer recovery, card drops "
          f"only the frame #0 start drop, B1 pacer missed deadlines ≤ {B1_MAX} per block less post-seek perform, markers, at least "
          f"{GATE_HOURS:.0f} h): {g} — blocks " + ", ".join(f"{lab} {v}" for lab, v in g95)
          + f" · wall {wall:.2f} h ({'≥' if hours_ok else '<'} {GATE_HOURS:.0f} h), playing {allh:.2f} h")

if __name__ == "__main__":
    if len(sys.argv) < 3: sys.exit("rc-soak-report.py <dir> <label>...")
    main(sys.argv[1], sys.argv[2:])
