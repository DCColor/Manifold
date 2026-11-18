# Picture freeze audit

Read-only audit of the top 1.0 bug: *a playing file's picture freezes for good while the clock and sound run on*
(`docs/BUGS.md:2412`; `docs/CARD_CLOCK_FINDINGS.md` §10.12–§10.18). Written 2026-11-17. No code changed, nothing built
or launched, no git operation. Soak folders were read in place.

Every claim is marked **CONFIRMED** (with a file:line, log line or report line) or **UNKNOWN**. "Stall" means the
renderer state the watchdog detects. "Freeze" means that state with no recovery (before the watchdog existed, or with
recovery switched off).

---

## 1. Current state

### 1.1 What the watchdog does today

All of it is in shipping code, outside any measurement flag (`Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift:1626-1633`:
`recoveryEnabled` is `true` unless the build has `MANIFOLD_CARDCLOCK` and `MANIFOLD_RENDERER_RECOVER=0`). It was committed
in `f3271a6` (2026-11-09 10:51) and first shipped in 0.9.2 build 25 (`452f697`, 2026-11-09 11:34). **CONFIRMED** (`git log`).

| Part | What it does | Where |
|---|---|---|
| Activity record | Both pumps record their arm, each callback and end of stream. Both emit closures record each enqueue (pts, host time, frame duration). All under one `NSLock`. | `PacingRendererWatchdog.swift:29-66`; AVF pump `FileFrameSource.swift:119,126,162`; libav pump `LibavFrameSource.swift:494,501,534`; emit closures `FrameEngine.swift:3819-3823`, `:5722` |
| Timer | `DispatchSource` on main, every 50 ms (10 ms leeway), started 1 s after engine init | `FrameEngine.swift:657`, `:1635-1639` |
| Gate | Runs only while a video file plays: `isPlaying`, synchronizer rate > 0, media kind video, a renderer and a source. Otherwise it resets to idle. | `FrameEngine.swift:1641-1650` |
| The state | Renderer `isReadyForMoreMediaData` false, the pump not ended, and nothing of ours pending. "Nothing pending" means the renderer's timebase is a frame past the last pts we enqueued, or nothing has been enqueued 0.25 s after an arm. | `FrameEngine.swift:1676-1681` |
| Near-miss | The state lasts over 100 ms, then clears by itself: one `[RENDERER-NEARMISS]` line and a count | `FrameEngine.swift:1621`, `:1686-1697` |
| Recovery | The state for at least 100 ms, and no pump callback for 500 ms: one `[RENDERER-RECOVER] attempt N` line and a count. Then `stop()` (or `stopRequestingMediaData`), `flush()`, re-arm on the **same** session. No seek, and the audio is not touched. | `FrameEngine.swift:1622`, `:1698-1707`, `:1733-1752` |
| Retry | No frame within 1 s of a re-arm: try again, up to 3 attempts. Then rebuild once at the clock (`beginReading(from: clock, resumePlaying: true)`, `[RENDERER-RECOVER] REBUILD`). Then `GAVE UP`, which does not loop. | `FrameEngine.swift:1623-1624`, `:1707-1729` |
| Success line | `[RENDERER-RECOVER] picture moving again: first frame in N ms after the re-arm, X s after the stall began` | `FrameEngine.swift:1709-1713` |

Limits of the detector:
- It sees only the "not ready, nothing pending" stall. A renderer that holds frames but stops presenting them is outside its test.
- It judges nothing while paused (`FrameEngine.swift:1643-1648`). A stall that begins during a paused preroll is acted on only after Play. `wd-night-on2` was that case: last callback 2.22 s before the recovery (§2).

All of the above is **CONFIRMED** from the code.

### 1.2 What it logs

- `[RENDERER-RECOVER] attempt N: flushing and re-arming the pacing renderer · <state>`. The state string (`FrameEngine.swift:1754-1760`) carries:
  - time in the state, time since the last pump callback, time since the last enqueue, and the last pts with the count since the arm;
  - the renderer's status, error, `isReadyForMoreMediaData` and `requiresFlushToResumeDecoding`;
  - the timebase's rate and time, the synchronizer's rate, and the decode path.
- `[RENDERER-RECOVER] picture moving again: …`, `… REBUILD: …`, `… GAVE UP: …`, and in measurement builds `… DISABLED … would recover now`.
- `[RENDERER-NEARMISS] …` with the same fields, briefly.

**Not logged (CONFIRMED by reading the format strings):**
- time since the last Play, seek or arm;
- the display layer's own status;
- window, screen or occlusion state;
- `hasSufficientMediaDataForReliablePlaybackStart`;
- timebase notifications.

### 1.3 What Export Diagnostics shows

The *PICTURE RECOVERY* section (`App/DiagnosticsExport.swift:910-914`) prints:
- `Pacing renderer  : N recoveries (M needing a rebuild), K near-misses since launch`
- `Last recovery    : <the last attempt line>`

Both tags are in the log partitioner (`App/DiagnosticsExport.swift:426`), so the lines also appear in the captured log. **CONFIRMED.**

Two reporting defects, **CONFIRMED** by reading:
- **The "recoveries" count is attempts.** `noteRecovery` runs on every attempt (`FrameEngine.swift:1739`; `PacingRendererWatchdog.swift:76`), so one stall that needs 3 re-arms reads "3 recoveries". "Last recovery" is the attempt line, not the outcome.
- **A GAVE UP has no counter.** Only its log line exists (`FrameEngine.swift:1718`; `RendererRecoveryStats` has recoveries, rebuilds and near-misses only, `PacingRendererWatchdog.swift:71-74`). A permanent freeze in the field would show in diagnostics only as "1 recovery (1 needing a rebuild)".

**Field data: UNKNOWN.** No tester diagnostics with a PICTURE RECOVERY section were found in the repo. The three diagnostics files in `docs/` are from 0.5.1 and 0.7.0.

---

## 2. Every occurrence since the watchdog existed

### 2.1 How the logs were searched

- Every `*.log`, `*.out`, `*.txt`, `*.report` and `*.md` under 500 MB in `~/Code/_scratch/manifold-*` was grepped for `RENDERER-RECOVER|RENDERER-NEARMISS` (scratchpad `hits.txt`, 9 files). So were all of `build/` in the repo (8 files).
- Exposure per log was counted the same way everywhere:
  - **Play time:** `[PLAYBACK-STATS] t=` lines. One prints about every second, only while unpaused and presenting (`App/MetalVideoRenderer.swift:1672-1689`). Checked against `rc094-soak/rc-5994-sdi-1`: 3,359 lines against the report's 0.93 h.
  - **Plays:** `[TRANSPORT] play` lines.
  - **Gate:** a `1b move` or `[CARDLOCK] latched` line.
  - **Output:** `[TRANSPORT] output start` or `DeckLink: output start`.
- The soak reports' own tallies (`renderer: attempts …, near-misses …`) were used where they exist. Audio-only blocks are excluded: they have no video pump.
- Three `s3` blocks have no app log left, only their JSON summaries (`build/cardclock/hunt/s3-off1.json`, `s3-on1.json`, `s3-off2.json`). Their figures come from those summaries.

### 2.2 The real stalls: 4 found, all recovered on the first re-arm

| # | Run (log) | Date | Gate | Output | Capture | Fixture | Since Play | In state / no callback | Recovered on | Picture moving after stall began | First frame after re-arm |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `wd-night-on2` (`build/cardclock/hunt/wd-night-on2-L1.log`, attempt line found by grep) | 2026-11-08 | on | on | closed | `cc-5994-2450s.mov` | **at Play** (5 preroll frames, last callback during the paused preroll) | 0.101 s / 2.220 s | attempt 1 | 0.150 s | 39 ms |
| 2 | `wd-night-off4` (`…/wd-night-off4-L1.log:67517`) | 2026-11-09 | off | on | closed | `cc-5994-2450s.mov` | ≈17.8 s (1,069 frames since the arm) | 0.346 / 0.524 s | attempt 1 | 0.394 s | 47 ms |
| 3 | `s3-on2` (`…/s3-on2-L1.log:27560`) | 2026-11-10 | off | on | closed | `cc-5994-2450s.mov` | 16.9 s (`CARD_CLOCK_FINDINGS.md:1107`) | 0.357 / 0.518 s | attempt 1 | 0.400 s | 28 ms |
| 4 | **`c7-c-441`** (`~/Code/_scratch/manifold-1c-wire/runs/c7-c-441.log:28790`) | 2026-11-11 | **on** | on | **open** (wire run) | `w1c-5994-441-1920s.mov` | **156.6 s** (the wire's sound segment 8.545 → 165.182 s, `c7-c-441.segs.report`; renderer clock 157.05 from Play at 0) | 0.393 / 0.542 s | attempt 1 | 0.443 s | 38 ms |

All four are **CONFIRMED** from their log lines. All four read the same:
- `renderer status 1, error none, ready false, requiresFlushToResumeDecoding false`;
- timebase rate 1.000000 (1.000008 in #4), synchronizer rate 1.000;
- the AVFoundation decode path.

Rebuilds: 0. GAVE UP: 0. Real near-misses: 0. The one `[RENDERER-NEARMISS]` in any log is the forced self-test `wd-st-nearmiss`.

**#4 was never written up. CONFIRMED:**
- `grep c7-c-441 docs/*.md` finds nothing.
- §10.23's C7 row (`CARD_CLOCK_FINDINGS.md:1482`) reports the run's continuity and offset, not the stall.
- `BUGS.md:2432` still gives the §10.15 + §10.18 counts.

**Excluded as forced self-tests, not stalls:**
- the 8 `[RENDERER-RECOVER]` hits in `~/Code/_scratch/manifold-recovery-audio/runs/` (`sdi-1..5`, `comp-1..2`, `trial-1`): `MANIFOLD_RENDERER_SELFTEST=recover:20` (`recovery-wire.py:3,12`). Every one is at pts ≈20.05 and reads `ready true`, because only the watchdog's reading was forced;
- `wd-st-recover`, `wd-st-nearmiss` and `wd-st-off2` in `build/cardclock/hunt/`.

**Soaks with nothing (CONFIRMED, each `soak.report` reads `renderer: attempts 0, recovered 0, rebuilds 0, GAVE UP 0, near-misses 0` for every block, and their logs have no hit):**
- `manifold-rc-soak` (0.9.3 RC)
- `manifold-rc094-soak` (0.9.4 RC)
- `manifold-cardpull-s1`
- `manifold-cardpull-s1r`

`manifold-pacerphase-ab` has no run yet (`RIG.md:1`, "NOT RUN"). `manifold-soak` (September) predates the watchdog.

### 2.3 Exposure, by block group

| Group | Build | Gate | Output | Fixture | Played | Plays | Stalls | Source |
|---|---|---|---|---|---|---|---|---|
| §10.15 `wd-before-out` (recovery off, detector on) | measurement, pre-commit watchdog | off | on | cc | 1.88 h | 113 | 0 (0 would-recover) | `wd-verify.driver.log`; tally |
| §10.15 `wd-before-noout` | the same | off | **off** | cc | 0.94 h | 57 | 0 | the same |
| §10.15 `wd-after` | the same | off | on | cc | 1.88 h | 113 | 0 | the same |
| §10.15 `wd-night-on1..7` | the same | on | on | cc | 5.82 h | 353 | **1** (#1) | the same |
| §10.15 `wd-night-off1..6` | the same | off | on | cc | 5.65 h | 342 | **1** (#2) | the same |
| §10.18 `s3-off1`, `s3-off2` | build-25 watchdog + `[AUDIOWATCH]` | off | **off** | cc | 1.57 h | 96 | 0 | `s3-*.json` |
| §10.18 `s3-on1`, `s3-on2` | the same | off | on | cc | 1.57 h | 96 | **1** (#3) | `s3-*.json`, log |
| 1c-wire, 2026-11-10 → 14 (161 logs) | measurement (`MANIFOLD_CARDCLOCK`) | on | on | mostly `w1c-*`, some cc | 14.77 h | 348 | **1** (#4) | tally |
| 1c-wire, the same | the same | off | on | the same | 4.14 h | 111 | 0 | tally |
| Release soaks: rc (0.9.3), rc094, cardpull s1, s1r | plain Profile, card lock on by default (`CardClockAudio.swift:14-17`) | on | on | `w1c-*`, `gop25`, cc-noaudio | 15.69 h | 1,062 | 0 | `soak.report` ×4 |

The 1c-wire runs also made **1,581 scripted output starts and stops** (`[TRANSPORT] output start` count), mostly while playing (`rs*`, `nc*`, `mid21`, `h27`). None brought a stall. **CONFIRMED.**

### 2.4 Rate per condition

| Condition | Played | Plays | Stalls | One per | 
|---|---|---|---|---|
| Gate on, output on | 36.28 h | 1,763 | 2 | 18.1 h, 882 Plays |
| Gate off, output on | 15.12 h | 775 | 2 | 7.6 h, 388 Plays |
| Gate off, output off | 2.51 h | 153 | 0 | — |
| **All** | **53.91 h** | **2,691** | **4** | **13.5 h, 673 Plays** (95% interval for the rate: 1 per 5.3 h to 1 per 49 h) |
| Since build 25 only (`s3`, 1c-wire, soaks) | 37.74 h | 1,617 | 2 | 18.9 h |

None of the splits is distinguishable from equal rates. For each split, the chance under equal rates of a result at least as lopsided as the one seen:

| Split | Share of hours | Stalls in it | Chance under equal rates |
|---|---|---|---|
| Gate on vs off, output on | gate on 71 % | 2 of 4 | 34 % |
| Output off | 4.7 % | 0 of 4 | 83 % |
| Fixture `cc-5994-2450s.mov` (≈61 Mb/s ProRes Proxy, 18.8 GB) vs the `w1c` fixtures (≈18 Mb/s, flat grey) (`mdls`) | cc 39 % (20.87 h) | 3 of 4 | 17 % |
| The hunt driver (60 s Plays from random points, `cardlock-hunt.py:163`) | hunt 36 % (19.25 h) | 3 of 4 | 13 % |
| Release soaks | 29 % (15.69 h) | 0 of 4 | 25 % |

Reading:
- On present data the rate is **one stall per about 13.5 h of playback**, or one per about 670 Plays.
- The §10.15 figure of "one per 6.6 h" was the early, high end.
- The hunt recipe on the cc fixture is still the most productive setup seen: 3 in 19.25 h, **one per 6.4 h**. That is a lead, not a result.

**Pre-watchdog freezes, for the time-since-Play pattern.** From `CARD_CLOCK_FINDINGS.md:700-706,806-822`: 47.1 s, 1,998.9 s, 43.2 s, 17.7 s (`a-1`) and 31.9 s (`il-off1`).

**An observation, not a result:** three of the nine events with a known time since Play fall at 16.9–17.8 s (`s3-on2`, `wd-night-off4`, `a-1`).
- The hunt driver does nothing during a Play: it polls the log every 0.2 s (`cardlock-hunt.py:152`).
- No in-app periodic task is known at ≈17 s.
- Its significance is **UNKNOWN**: the pattern was found after looking.

---

## 3. What is known about the stalled state

**The state, CONFIRMED twice by full reports** (`il-off1`, `CARD_CLOCK_FINDINGS.md:813-816`) **and by four watchdog lines** (§2.2):
- `isReadyForMoreMediaData` false, status 1 (rendering), no error, `requiresFlushToResumeDecoding` false;
- the timebase running at rate 1;
- CoreMedia logging the video queue at "0 frames … LWM 1.000 HWM 2.000" and the image queue at "iq unconsumed: 0";
- the pump's last exit "renderer not ready (waiting for its callback)", with a normal lead of about 0.13 s, and no callback after it;
- no thread blocked. The pump, renderer `videoQueue`, `videoqueue.notification`, `videomediaconverter.inbound` and Metal dispatch threads are absent from the stack (`:728-741`, `:819`).

**The state does not clear by itself:** 0 real near-misses in 53.9 h.

**A flush and re-arm on the same session clears it every time:** 4 of 4, first frame 28–47 ms after the re-arm.

### Hypotheses recorded so far

| # | Hypothesis | Status | What decided it |
|---|---|---|---|
| H0.1 | Stage 1b (the gate) causes it | **Ruled out** | `il-off1` froze gate off, with 0 steering writes, no renderer move and no re-read (`CARD_CLOCK_FINDINGS.md:817-822`). Stalls #2 and #3 were gate off |
| H0.2 | The steering write's trip of the timebase through rate 0 | **Ruled out as the cause** | 10 Hz and 20 Hz stress, 1.93 h, 0 freezes where 2.1 were predicted (12 % chance, `:788-796`); `il-off1` had no writes (`:817`) |
| H0.3 | AVAssetReader or decoder | **Ruled out as the only cause** | The libav path froze too (`b12-libav`, `:747`, `:752`) |
| H0.4 | The pump blocked or deadlocked | **Ruled out** | Stacks: nothing blocked, the pump never called (`:728-741`; `il-off1` sample, `:819`) |
| H0.5 | Branch 2: `VideoSinkGate` park with a lost wake-up | **Ruled out** at `il-off1` (waiters 0, depth 0/12, room yes, `:801-804`) and by reading every signal path | |
| H0.6 | Branch 3: end of stream taken mid-file | **Ruled out** at `il-off1`: 0 ends of stream, reader status 1 (`:815`) | |
| H0.7 | Our ordering: request not re-armed after a flush, an arm racing a flush, an early return without re-arm, reliance on readiness | **None found by reading** (`:855-861`). One real race was found: an old session's frame can land after a seek's flush. It was judged unable to make this state mid-play | |
| H0.8 | Renderer failure, decode error or flush requested | **Ruled out**: status 1, error none, `requiresFlush` false, every time | |
| H0.9 | Capture open | **Not needed**: 2 of 3 1b freezes had capture closed (`:706`), and #1–#3 had capture closed | |
| H0.10 | Jump Desktop or a default-output change | **Ruled out for the freeze**: none near any freeze (`:653`, `:820`). That stall stops the *audio* pump, the opposite case (`:754-758`) | |
| H0.11 | Phase against the 1 Hz write | **No shared phase** (`:653`) | |
| H0.12 | Needs sound | **UNKNOWN**: only 0.93 h of video without sound since the watchdog (`rc-noaudio-sdi-1`), 0 stalls | |
| H0.13 | Needs the DeckLink output | **UNKNOWN**: 0 in 2.51 h output off; about 15 h output off with none would be needed (`:1108`) | |
| H0.14 | Licence Keychain prompts | **Nothing ties them**: no SecurityAgent line near the freezes (`:655`) | |
| H0.15 | A transient that clears by itself | **Ruled out**: 0 near-misses in 53.9 h | |

---

## 4. New hypotheses worth testing

| # | Hypothesis | Confirms it | Refutes it | Evidence so far |
|---|---|---|---|---|
| **N1** | **A lost readiness transition inside CoreMedia.** The video queue drains below its low-water mark, but the "ready" edge (and so the callback) is never delivered. `isReadyForMoreMediaData` stays a stale false. | At a stall, a **bare re-arm** (`requestMediaDataWhenReady` again, no stop, no flush) brings no callback, while **enqueueing one frame anyway** makes the renderer ready or call back. The header says enqueueing while not ready is safe (SDK `AVSampleBufferVideoRenderer.h`, `readyForMoreMediaData` comment). | Only a flush clears it, every time | Fits everything recorded: queues at 0 while "not ready", the notification thread absent from the stack. UNKNOWN |
| **N2** | **The request itself is dropped.** The renderer's stored block is lost, for example coalesced away while our block was returning. | A bare re-arm brings a callback within a frame or two | Bare re-arm does nothing | UNKNOWN |
| **N3** | **A stall after a timebase or rate change** (display layer or AVSampleBufferVideoRenderer) | Every stall has a timebase notification (rate changed, time jumped) on `renderer.timebase` within a few seconds before it | Mid-play stalls show no timebase event in the preceding 5 s | Weak: #2, #3 and `il-off1` were mid-play, gate off, with no rate write (`:817`). Only #1 is at a rate change (Play) |
| **N4** | **Enqueue racing a flush**: the known old-session race (`:857`), or a frame emitted across the seek's token bump | The at-Play stall (#1) shows an old-session emit after the seek's flush | No old-session emit before stalls | Live only for #1: the stall began during the paused preroll after a seek (5 frames, then no callback). Mid-play stalls had no seek nearby |
| **N5** | **A CoreMedia bug on this macOS** | A minimal harness with no Manifold code stalls the same way, then filed with Apple | Hours of the harness at the hunt cadence with no stall (see §5.3) | **No public report found** (searches of Apple Developer Forums, WebKit Bugzilla and webkit-changes; sources at the end). The machine now runs macOS 26.7.1 (25G241, `sw_vers`); the version during the 2026-11-08 → 11-11 runs is UNKNOWN. The 27.2 SDK deprecates `isReadyForMoreMediaData` and `requestMediaDataWhenReady` in Swift (from macOS 27) for a `sampleBufferReceiver` async-enqueue API (`AVSampleBufferVideoRenderer.h`, the `API_DEPRECATED` lines). That says nothing about a bug, but the replacement is not available on macOS 26. UNKNOWN |
| **N6** | **Card-clock timebase steering** | — | Already refuted as necessary: stalls #2 and #3 and `il-off1` had 0 writes | Ruled out as necessary. Whether the card's presence matters is H0.13 |
| **N7** | **Display sleep or wake, or a display reconfiguration** | A stall within 1 s of a screens sleep/wake, a reconfiguration callback or a window occlusion change | Stalls with none | For #4: **ruled out.** `pmset -g log` shows Manifold PID 11142 holding `PreventUserIdleDisplaySleep` from 17:01:24 to 17:06:41 on 2026-11-11, with no display event. For #1–#3: UNKNOWN; the power log starts 2026-11-10 18:42. Output was on, so the same assertion was likely held. Every stall run and every clean soak moved the window LG → ASUS at launch (`[CHAIN] Headroom` lines), so placement does not separate them |
| **N8** | **GPU or render-load contention** | Raised `gpuMs`, `latMs` or `tickMs` just before stalls | Normal figures | Our own render load was normal before #2, #3 and #4: `[RENDER-PERF]` gpuMs 0.05–0.14 average, tickMs 8.34 (log excerpts). System-wide GPU load: UNKNOWN |
| **N9** | **Decode or I/O load** (the 61 Mb/s, 18.8 GB cc fixture) | The stall rate on cc ≥ about 3× that on `w1c` in an interleaved A/B | Equal rates | 3 of 4 on cc in 39 % of the hours: 17 % under equal rates. A lead |
| **N10** | **Pixel-buffer lifetime.** `alwaysCopiesSampleData = false` (`FileFrameSource.swift:90`, `FrameEngine.swift:5450`): the same decoder-owned buffer goes to the renderer, the Metal window queue and SDI. | Stalls disappear with copies on (A/B) | No change | Speculative. Changes timing, so stress only. UNKNOWN |
| **N11** | **Something about 17 s after Play** | Stalls cluster in a window of time since Play across many events | A flat distribution | 3 of 9 at 16.9–17.8 s, found after looking (§2.4). UNKNOWN |

---

## 5. Next step

### 5.1 A targeted measurement build (`#if MANIFOLD_CARDCLOCK` only, pre-ship removal list)

The goal is to name which of N1–N4 and N7 holds at the next stall, without changing healthy-play timing.

1. **A probe before the recovery, round-robin by stall number.** At the moment the watchdog would recover (`FrameEngine.swift:1707`):
   - **P-A, bare re-arm:** the source's `requestMediaDataWhenReady` again, with no stop and no flush. Watch 250 ms for a callback (N2).
   - **P-B, one enqueue:** run the pump body once on `videoPumpQueue`, skipping the readiness test, so one frame goes in. Watch 250 ms for `ready` flipping or a callback (N1).
   - **P-C, control:** today's flush and re-arm at once.

   Each falls back to today's recovery after 250 ms. Cost: up to 0.25 s longer hold, in the measurement build only, and only during a stall. Healthy play is untouched.
2. **A snapshot at detection** (main thread, once per stall; healthy play is untouched):
   - `hasSufficientMediaDataForReliablePlaybackStart`;
   - the display layer's `status` and `error`;
   - the window's `occlusionState`, screen and refresh;
   - `ProcessInfo.thermalState`;
   - time since the last Play, seek, arm and flush;
   - the window queue's depth and the SDI queue's depth (N10).
3. **An in-memory event ring** (64 entries, host time and kind). It is printed only at a detection, never during healthy play. Entries:
   - pump callbacks, and pump exits with `ready` and the lead;
   - session-token bumps and flushes;
   - **any emit whose session token is no longer current** (N4): one atomic compare in the emit closure, written only on a mismatch;
   - timebase notifications on `renderer.timebase` (effective rate changed, time jumped; N3);
   - display reconfiguration callbacks, screens sleep and wake, and occlusion changes (N7).

   Pump-side writes reuse the existing `RendererActivity` lock pattern: one store per callback, no print. That is the only hot-path cost, and it matches what the watchdog already does on every callback.
4. **Driver side, no app change:** on a `[RENDERER-RECOVER]` line, `/usr/bin/log show --last 60s` for the PID (CoreMedia's queue lines), as `cardlock-hunt.py`'s capture does. No `sample`: the stall is gone in 0.5 s.
5. **Fix the two diagnostics defects (§1.3)** in production code, separately: count stalls, not attempts, and count GAVE UP.

Build cost: small. All the hooks sit at existing call sites. It needs a `swift test` and a Release `strings` check that no probe strings reach Release, as in §10.14 and §10.15.

### 5.2 A stress soak to raise the rate

Predictions, written before any run (2026-11-17). Baseline is the hunt recipe on cc: one per 6.4 h. Every arm is interleaved hourly against that baseline on the same night, with gate default, output on and capture closed.

| Arm | What it stresses | Prediction if the stress is the trigger | Prediction if not |
|---|---|---|---|
| S1 Play-dense | 25 s Plays from random points, so about 2.3× the Plays per hour (kept above 17.8 s for N11) | Per-Play risk: about 2.3× the per-hour rate, ≈ one per 2.8 h | One per 6.4 h |
| S2 Seek while playing | A seek (flush and arm at rate 1) every 5 s | Several times the rate, stalls within 1 s of a seek | Baseline; no link to seeks |
| S3 Rate toggles | Pause and Play every 3 s, no seek | Raised, at Play (like #1) | Baseline. The steering stress already pushed 10–20 rate-0 trips a second for 1.93 h with none (`:788-796`), so **predicted: not raised** |
| S4 Forced timebase step | Measurement switch: `setRate(1, time: t ± 1 frame)` every 10 s while playing | Raised, stalls within 1 s of a step | Baseline |
| S5 Fixture A/B (N9) | cc against `w1c-5994` hourly, otherwise identical | cc ≥ 3× `w1c` | Equal |
| S6 Output off (H0.13) | `HUNT_NO_OUTPUT=1` | Raised or equal | 0 in about 15 h needed to rule out equal rates at 95 % (`:1108`) |

Output restarts are left out. 1,581 starts in the 1c-wire runs brought none.

**Hours needed at the current rate** (95 % chance of seeing at least one stall is 3 ÷ rate):

| Setup | Rate | Hours |
|---|---|---|
| Pooled rate | one per 13.5 h | about 40 h |
| Hunt recipe on cc | one per 6.4 h | about 19 h |

- **For the probe build:** at least two stalls per probe arm (six in all) is about 38 h on the hunt recipe: 4 nights of 10 h.
- **For a stress arm:** 15 h of the arm against 15 h of baseline, interleaved (3 nights). At baseline that expects 2.3 in each. A real 3× effect expects ≈7 against 2.3. Call it raised at 6 or more (≈3 % by chance at baseline). Fewer than 3 in the arm rules out a 3× effect at about 97 %.

**Recommended order:**
1. Build §5.1.
2. Run S1 and S5 interleaved with the baseline for 3 nights. Both can also feed the probe.
3. Run S2–S4 only if S1 and S5 are flat.
4. In parallel, at no cost to the rig: the N5 harness in `~/Code/_scratch/manifold-freeze-repro`. A small `swiftc` program (AVAssetReader → `AVSampleBufferDisplayLayer` + synchronizer, the cc fixture, 60 s Plays from random points, detection only) on another night. If it stalls, the bug is Apple's: file Feedback with the CoreMedia log lines.

---

## 6. How visible the recovery is

| Where | What happens at a stall that the watchdog recovers | Evidence |
|---|---|---|
| **Window** | The picture holds 0.15–0.44 s (stall began to picture moving), then catches up by dropping frames. In that second: 25 dropped and 3 late (#4), 22 dropped and 4 late (#3), 7 + 16 dropped over two seconds (#2) | CONFIRMED: `[RENDERER-RECOVER]` and `[PLAYBACK-STATS]` lines (`c7-c-441.log:28829`; `s3-on2-L1.log` near line 27560; `CARD_CLOCK_FINDINGS.md:899`) |
| **SDI picture** | #4 on the wire: picture 9388 repeated for **24 extra frames (0.40 s)**, then four frames jumped +8, +7, +7, +7 source frames and one repeated once; back on +1 by frame 9929. Position was never lost: 29 source frames across 28 wire frames | CONFIRMED: `c7-c-441.segs.report` (picture events at 165.182–165.649 s). The forced self-test on the wire (`recovery-audio/runs/sdi-1.summary.json`, gate off) shows the same shape: 21 held, then +8, +6, +7, a repeat, +5 |
| **SDI audio, gate on** (the default since 0.9.3 with output on) | **467.1 ms of digital silence** (22,422 samples). The sound resumes in step: the source moved exactly 22,422 samples across the gap, so there is no slip, and A/V is back within 1 ms 0.48 s later. The bridge ends its run when the picture goes off its line, and re-latches to the picture after recovery | CONFIRMED: `c7-c-441.segs.report`, `SILENCE at 165.182 s: 22422 samples (467.1 ms), source moved 22422`; `c7-c-441.log` `[SDI-AUDIO] run end (off the line on a timed pull) at slot 10050`, then `latch #2` |
| **SDI audio, gate off** (`MANIFOLD_CARDLOCK_1B=0`, or output stopped and restarted under 0.9.2) | No silence logged. Two `RESYNC` snaps: back ≈0.33–0.35 s, then forward ≈0.27–0.29 s. That would be an audible repeat followed by a skip | CONFIRMED in logs: `s3-on2` (341.770 → 341.420, then 341.982 → 342.273) and `wd-night-off4` (1622.467 → 1622.133, then 1622.734 → 1623.003). On the wire: UNKNOWN for a real stall (the self-test shows only the Play-time RESYNC, `sdi-1.summary.json` `resyncs`) |
| **Mac audio** (destination Computer, or output off) | The recovery does not touch the audio renderer or the tap: it stops, flushes and re-arms the video source only | CONFIRMED in code (`FrameEngine.swift:1729-1731`, `:1741-1749`). Audible effect: UNKNOWN, never measured (Audio Hijack not run over a real or forced stall; the `comp-1`/`comp-2` self-tests captured the wire only) |
| **Without the watchdog** | A permanent freeze: the picture holds to the end of the session, and with gate on SDI audio follows it into silence | CONFIRMED: 5 freezes (`BUGS.md` table, `CARD_CLOCK_FINDINGS.md:645-655`) |

**How bad it is if the root cause is still unknown at 1.0:**
- **Frequency:** about one hitch per 13.5 h of file playback (interval 5–49 h). None in 15.7 h of release-candidate soaks.
- **What the hitch is:** a 0.15–0.45 s held picture with a short fast-forward, in the window and on SDI. With output on (gate on), a 0.47 s SDI audio mute.
- **On a reference output** in front of a client it is visible, and with SDI audio audible. It heals itself, and position and sync come back exactly.
- **A cheap reduction:** the recovery waits 500 ms with no callback (`FrameEngine.swift:1622`). The state was never seen in healthy play (0 real near-misses in 53.9 h). So a shorter wait would shorten the hold, at the cost of more false recoveries if a slow-but-healthy renderer ever reads that way.
  - **Not measured.** Its effect on the hold is UNKNOWN.
  - It is a decision for Robbie, not a finding.

---

## 7. Summary

1. The watchdog (20 Hz on main, `FrameEngine.swift:1641-1729`) has been in every build since 0.9.2 build 25. It flushes and re-arms the stalled pacing renderer after 500 ms with no callback.
2. Since it existed: **4 real stalls in 53.9 h and 2,691 Plays** (one per 13.5 h). All recovered on the first re-arm in 0.15–0.44 s. 0 rebuilds, 0 gave-ups, 0 real near-misses.
3. **One stall was never recorded**: `c7-c-441` (2026-11-11, gate on, capture open, 156.6 s after Play). It is the only one caught on the wire.
4. The four release-candidate and card-pull soaks (15.7 h, 1,062 Plays) had none. Chance of that at equal rates: 25 %.
5. No split separates the rates: gate, output, fixture, harness or display. Leads only: 3 of 4 on the cc fixture, and 3 of 9 events 16.9–17.8 s after Play.
6. The stalled state is unchanged and does not clear by itself: not ready, status 1, no error, timebase at rate 1, CoreMedia's queues empty, no callback. Fifteen recorded hypotheses are ruled out or unknown, and no fault on our side was found.
7. The best new candidates are inside CoreMedia: a lost readiness edge (N1) or a dropped request (N2). One probe at detection separates them: a bare re-arm, against one enqueue while not ready, against today's flush.
8. Next: a measurement build with that probe, a detection snapshot and an event ring, nothing printed in healthy play. Then 3 nights of interleaved stress (Play-dense, cc against `w1c`), plus a no-Manifold reproduction harness.
9. Hours: about 19 h on the hunt recipe (about 40 h at the pooled rate) for a 95 % chance of one stall. About 38 h for two per probe arm.
10. User-visible today:
    - a 0.15–0.45 s picture hold with a catch-up, in the window and on SDI (24 frames held on the wire);
    - gate on, a 0.47 s SDI audio mute, back in sync;
    - gate off, an audible repeat and skip;
    - the Mac audio path is not touched.

    Export Diagnostics counts attempts as recoveries and has no gave-up count.

### Sources (web searches for N5)

- [AVSampleBufferDisplayLayer enqueue… (Apple Developer Forums)](https://developer.apple.com/forums/thread/64406)
- [Direct Access to Video Encoding and Decoding, WWDC14](https://developer.apple.com/videos/play/wwdc2014/513/)
- [WebKit Bugzilla 303001](https://bugs.webkit.org/show_bug.cgi?id=303001)
- [webkit-changes, 2024-11](https://lists.webkit.org/pipermail/webkit-changes/2024-November/310094.html)
- [webkit-changes, 2024-02](https://lists.webkit.org/pipermail/webkit-changes/2024-February/298448.html)
- [AVPictureInPictureController with AVSampleBufferDisplayLayer on macOS (Apple Developer Forums)](https://developer.apple.com/forums/thread/821582)
- [isReadyForMoreMediaData (Apple documentation)](https://developer.apple.com/documentation/avfoundation/avqueuedsamplebufferrendering/isreadyformoremediadata.md)

None of these describes this stall. They are listed because they were searched; N5 stays UNKNOWN.
