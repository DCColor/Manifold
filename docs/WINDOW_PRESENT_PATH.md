# The window present path under the output pacer

Read-only audit, 2026-11-18. No code was changed, built or launched, and no git command was run. Line numbers are the working tree at
`a6f541c`, whose only uncommitted change is `docs/CARD_PULL_MARGIN.md` (from the session's git-status snapshot). The logs are read in
place under `~/Code/_scratch/`: night 1 `manifold-cardpull-s1/` (§12 of `CARD_PULL_MARGIN.md`), night 2 `manifold-cardpull-s1r/` (§13),
night 3 `manifold-pacerphase-ab/` (§15) and 0.9.4 `manifold-rc094-soak/`. The throwaway scripts are in the session scratchpad and are
not kept.

**Labels.** **CONFIRMED** means read in the code (file:line), in a log line, or counted over the logs by the method given.
**UNKNOWN** means not established. Where an answer is likely, it is written "UNKNOWN (inference: …)". §3 and §4 are proposals.

## Summary

1. With output on, the CVDisplayLink is stopped and the 119.88 Hz pacer is the window's only tick. Every window present runs on the
   pacer thread, in `servePacedPresent`, after that tick's SDI frame is committed. CONFIRMED.
2. The gate allows at most one present per two pacer ticks (≥ 12.5 ms apart, so 16.68 ms at k = 2). Once two presents are waiting
   for the glass, it holds the new frame. CONFIRMED.
3. When presented handlers come back ≥ 2 refreshes late, every new-frame tick is held, and its frame is presented on the next tick,
   the repeat tick. These are the "holding" windows. CONFIRMED by counts.
4. On those repeat ticks, the present itself occasionally blocks for 8–16 ms. That carries the pacer past the next new-frame
   deadline: a missed deadline, a `pacer` late swap, and sometimes a card hold. CONFIRMED.
5. Which call blocks is UNKNOWN. `nextDrawable` is timed and fast (max 0.46 ms). `waitUntilScheduled`, `CATransaction.commit` and
   the encode/commit are not timed. In pacer mode `[RENDER-PERF] presMs` is a hard-coded 0.
6. Nights 1 and 3 differ from night 2 in two ways: more holding windows (77–86 % against 20–28 %), and a long-present tail about
   14× heavier per present. No logged factor separates the nights; the table in §2 lists each. Uptime, slots, Zoom, time of
   night, the display mode and option C are each ruled out as the sole cause.
7. Not on any rig list: night 3's binary makes WindowServer log a 569×320 `ASEProcessing` surface at about the frame rate. Nights
   1 and 2 do not. This is a difference between the nights, but not the shared cause.
8. Root fault: a WindowServer back-pressure can stall the SDI pacer, because the SDI tick and the desktop present share one
   thread. No gate setting can remove that.
9. **Recommendation:** a logging-only measurement first (§4.1). Then **option A**: the window presents on its own thread, at
   the window display's own refresh, from a newest-frame mailbox. The pacer never touches the `CAMetalLayer`.
10. Option B (transaction off for pacer presents) is a smaller one-night experiment. Option C (skip rather than block) gives
    only part of the fix, at a visible cost to the window.

---

## 1. When the pacer presents, and what blocks

### 1.1 Who ticks while output runs

- `startPacerOnQueue` stops the link (`App/MetalVideoRenderer.swift:3437`), turns pacer presents on (`:3438`) and makes a pacer whose
  tick is `displayTick()` with no glass time (`:3446`). CONFIRMED.
- The pacer thread waits with `mach_wait_until(deadline)` (`App/OutputPacer.swift:149`) and runs the tick synchronously (`:156`).
  Then `deadline += step` (`:162`). If the tick ended past the new deadline, the missed deadlines are skipped, not made up
  (`:164-169`). So a tick that overruns pushes the next tick a whole period later, and that interval reads 2 P (16.68 ms at
  59.94). CONFIRMED.
- Thread policy: time-constraint, period P, computation P/2, constraint P (`OutputPacer.swift:116-130`).
- The window's display period reaches the gate only from the link retarget: `setWindowDisplayPeriod(1/hz)` (`MetalVideoRenderer.swift:3383`).
  On every night that was the ASUS at 59.936 Hz (`[LINK] … "ASUS PA147" (59.936 Hz)`, §12.1). CONFIRMED.

### 1.2 What one pacer tick does

`displayTick` (`MetalVideoRenderer.swift:3509-3555`):

1. `noteDeckLinkTick` (`:3511`): the pull margin's tick interval.
2. `performDisplayTick()`. Its top installs any pending colour state, drawable size and geometry (`:3567-3660`). The colour state
   opens a `CATransaction` that stays open until the tick's present (`:3620-3629`; closed by `closeColorStateTransaction`, `:4752`).
   - **A new-frame tick** goes into `renderPixelBuffer`, pacer branch (`:4341-4364`): it commits the offscreen and SDI command
     buffer (`:4350`), sets `deferredPresent` (`:4356`), then calls `servePacedPresent()` (`:4357`).
   - **A repeat tick** (k = 2: every other tick) selects no new frame and renders nothing.
3. `if deferredPresent != nil { servePacedPresent() }` (`:3546`). On a new-frame tick whose present was held, this is a second
   attempt in the same tick. On a repeat tick, this is where a held frame gets presented.
4. `flushPacerPresentStats` (`:3547`; the `[PACER] desktop 10 s` line, printed from this thread every 10 s) and `noteIdleTick`.

### 1.3 The gate and the present (`servePacedPresent`, `:4528-4562`)

| Step | Line | Blocks? | Timed? |
|---|---|---|---|
| Gate timeout: in flight > 0 and no present for 0.5 s → count reset | `:4532-4535` | no | counted (`gate timeouts`, 0 on every night) |
| **In-flight hold:** `inFlight > presentsWaitingLimit` (1 at 59.936 Hz: `OutputPacing.swift:92-95`, threshold 61 Hz `:84`) | `:4539-4541` | no | counted per attempt (`held back: in flight`) |
| **Rate hold:** less than 0.75 × display period since the last present (12.51 ms) | `:4542` | no | counted (`rate`) |
| `makeCommandBuffer` | `:4543` | UNKNOWN (inference: no) | no |
| `nextDrawable()` | `:4545` | yes, if the pool of 3 is empty | **yes** (`nextDrawable` in the 10 s line) |
| `encodeDisplayStage` | `:4548` | no (CPU encode) | no |
| in-flight +1. The presented handler decrements it | `:4549-4553` | no | — |
| `cb.commit()` | `:4554` | UNKNOWN (inference: no) | no |
| `presentDrawable` → `waitUntilScheduled()` | `:4727` | **yes, by design**: waits for the GPU to schedule the buffer (comment `:4719-4723`) | no |
| `CATransaction.begin` / `drawable.present()` / `CATransaction.commit()` | `:4747-4750` | UNKNOWN (inference: a commit to the render server can wait on it) | no |
| `closeColorStateTransaction()`: commits the colour transaction if one is open | `:4752`, `:4759-4763` | as above | no |

`presentsWithTransaction = true` is set once, at init (`:1252-1261`). In pacer mode `recordRenderPerf` is passed `present: 0`
(`:4359-4361`), so **`[RENDER-PERF] presMs=0.00` in every pacer log is a constant, not a measurement**. Its `drawMs` is the new-frame
tick's own `nextDrawable` wait, or 0 when that attempt was held. The present that a repeat tick serves records nothing in `[RENDER-PERF]`.
CONFIRMED.

### 1.4 How many presents per display refresh

- **At most one per two pacer ticks.** The rate hold needs 12.51 ms. One tick is 8.34 ms, so the shortest spacing is two ticks,
  16.683 ms. That is just under the ASUS period of 16.684 ms. CONFIRMED by the arithmetic of `:4542` and the pacer's P.
- **So presents arrive about 0.007 % faster than the display takes them**: 59.940 against 59.936 per second, one surplus about every
  4 min. The display's true scan rate is UNKNOWN (CVDisplayLink nominal 59.936; `system_profiler` says 60.00 Hz, `RIG.md`). Once the
  queue holds two presents, nothing in steady play drains it. It drains only when a held frame is replaced before it is shown
  (presented/s < rendered/s) or when playback stops.
- **The in-flight count is presents whose presented handler has not yet come in.** Allowed at 0 or 1, so after the present up to two
  are waiting, plus one on the glass: the layer's three drawables (comment `:4335-4340`; `OutputPacing.swift:86-91`). If handlers come
  back within two refreshes, the count at the next new-frame tick is ≤ 1 and the frame is presented on its own tick. If they come
  back later, the count is 2: the new-frame tick is held, twice (steps 2 and 3 above), and the repeat tick presents it once a handler
  has come in, which is just after a vsync. CONFIRMED by the code. The counts match: in holding windows `held back: in flight` runs at
  1,000–1,200 per 10 s against 600 presents, about 2 held attempts per frame. One example is `pp-5994-sdi-lst.log:240172`
  (`in flight 1050 … presented 600`).
- At 23.976 and 25, presents are 40–42 ms apart, more than two refreshes, so the count never reaches 2. There were 0 holding windows on
  every night (`CARD_PULL_MARGIN.md` §15.2; `id-gop25-at-5994-on`: 1 of 119). CONFIRMED.

### 1.5 Which part of the tick overran

**Where.** Night 1: 72 of 73 pinned 59.94 misses were repeat ticks (§12.2). Joined to the 10 s windows (script `rep.py`: each
`[TICKPHASE]` line's `prev-tick` is the repeat tick before it; assigned to the `[PACER] desktop` window that follows):

| Block | Repeat ticks > 8.3 ms in holding windows / in clean windows | Repeat tick > 5 ms, per 1,000 in holding windows | p50 / p99 of a repeat tick in holding windows (ms) |
|---|---|---|---|
| N1 `pp-5994-sdi-lst` | 45 / 2 | 0.92 | 0.008 / 2.58 |
| N1 `pp-5994-sdi-ms6` | 25 / 1 | 1.40 | 0.191 / 2.77 |
| **N2 `pp-5994-sdi`** | **1 / 1** | **0.07** | 0.192 / 2.40 |
| N3 `ab-5994-sdi-off` | 87 / 6 | 0.98 | 0.144 / 2.27 |
| N3 `ab-5994-sdi-on` | 96 / 3 | 0.97 | 0.010 / 2.22 |

- **The tick that overran is the repeat tick that serves a held present.** In clean windows a repeat tick takes 5 µs at p50, and
  only 1–6 per block exceed 8.3 ms. CONFIRMED.
- **How long it took: 8.3–16.2 ms, median 10.3–11.1 ms** (one at 18.6 ms in `ab-5994-sdi-on`; script `win.py`). That is never more
  than about one ASUS refresh (16.68 ms). Examples:
  - `pp-5994-sdi-lst.log:17178`: interval 16.682, prev-tick 12.008 ms, in window `:16011` (in flight 174, presented 54.1/s).
  - `pp-5994-sdi.log:65390` (night 2): prev-tick 9.156 ms, window `:64508` (in flight 1172).
  - `ab-5994-sdi-off.log:441628`: prev-tick 10.842 ms, `ring none`, the §15.3 hold.
- **`nextDrawable` was not it**: max 0.46 ms in any 10 s window of any 59.94 block (`win.py`, `nextDrawable … max`). CONFIRMED.
- **Not the tick thread's own prints**: the 7 lines before each miss are `[PULLPHASE]`, `[TICKPHASE]` and `[CADENCE]` lines. They come
  from the drain and the fill callback, not the 10 s print. Misses are irregular, 1–56 s apart (`per.py`). CONFIRMED.
- **Which call took the time: UNKNOWN.** The candidates are the untimed calls in §1.3. Inference: `waitUntilScheduled()` (`:4727`)
  or `CATransaction.commit()` (`:4750`). Two things point there: the blocks are bounded by one display refresh, and they occur only
  on a present made just after a presented handler came in, when the compositor has just latched. So the wait would be for a
  WindowServer resource released at the next vsync (a drawable still being read, or the commit throttle). Only a run with these
  calls timed can say which (§4.1).

**How it reaches the card.** The overrun repeat tick ends past the next deadline, so the new-frame tick runs one tick late
(`OutputPacer.swift:164-169`). Its frame renders, converts and reaches the ring 8.34 ms late: a `[LATE-SWAP] class pacer`. If the pull
before had handed the newest frame with lead < P, the card repeats one frame (§12.3, §15.3: 2 holds on night 1, 5 on the night 3
on-block, 1 on the off-block). The SDI frame of the overrunning tick itself is not delayed. It was committed before the present
(`:4330-4340`). The damage is to the *next* tick.

---

## 2. Why night 2 differs from nights 1 and 3

### 2.1 Outcome per 59.94 block

From `win.py` over the `[PACER] desktop` lines with rendered > 0. Misses are from `[PACER]` (§12–§15).

| Night | Block | Holding windows | Holding %, by sixth of the block | Presented/s, holding windows (median) | Misses |
|---|---|---|---|---|---|
| 0.9.4 | `rc-5994-sdi-1` | 120 / 357 (34 %) | 19 39 19 54 32 37 | 59.9 | 0 |
| 0.9.4 | `rc-5994-sdi-2` | 89 / 357 (25 %) | 42 29 12 17 17 31 | 59.9 | 2 |
| N1 | `pp-5994-sdi-lst` | 154 / 187 (82 %) | 77 87 90 74 94 71 | 50.8 | 47 |
| N1 | `pp-5994-sdi-ms6` | 87 / 102 (85 %) | 82 71 100 94 88 76 | 59.4 | 26 |
| N2 | `ctl-5994-sdi` | 37 / 187 (20 %) | 32 19 19 13 26 10 | 59.9 | 0 |
| N2 | `pp-5994-sdi` | 101 / 357 (28 %) | 44 32 29 7 32 24 | 59.9 | 2 |
| N3 | `ab-5994-sdi-off` | 275 / 357 (77 %) | 54 81 76 83 73 93 | 55.6 | 91 |
| N3 | `ab-5994-sdi-on` | 270 / 357 (76 %) | 73 86 83 68 69 75 | 49.0 | 100 |

- **Two things differ on the bad nights, not one:** (a) the share of holding windows, and (b) the cost of a present in a holding
  window (§1.5: >5 ms about 14× as often). 0.9.4 had holding windows (25–34 %) but 0 and 2 misses: holding alone is harmless. CONFIRMED.
- **The bad state is there from the first sixth of each bad block, and does not develop during it.** CONFIRMED.
- **Option C is not a factor:** off 77 %, on 76 % on the same night. CONFIRMED.

### 2.2 Everything logged, compared

| Factor | N1 (bad) | N2 (good) | N3 (bad) | 0.9.4 (good) | Separates N2? |
|---|---|---|---|---|---|
| 59.94 block start | 22:20, 22:52 (`soak.out`) | 00:09, 00:42 (`soak.out`) | 00:54, 01:55 (`rig.log`) | 23:00, 03:04 (`soak.out`) | **No.** N3 ran at the same hours as N2 |
| Position in the night | 4th, 5th | 1st, 2nd | 5th, 6th | 1st, 5th | Partly. 0.9.4's 5th block was good |
| Earlier launches of an ad-hoc build that night | 3, 4 | 0, 1 | 4, 5 | 0 (signed build) | **Fits all four nights.** A hypothesis only (§2.3) |
| HID idle at block start | 9,870 / 11,806 s | 607 / 2,545 s | UNKNOWN (`soak.out` not kept, §15.1; ≥ 600 by the gate) | 1,632 / 16,303 s | No. 0.9.4's 16,303 s block was good |
| Uptime (boot 2026-11-13 21:52:32, `sysctl kern.boottime` read today; no reboot since) | 3 d 0 h | 3 d 3 h | 4 d 3 h | ~2 d 1 h / 2 d 5 h | No: N1 < N2 < N3, not monotonic with the outcome |
| Window display and mode | ASUS 59.936 Hz (`[LINK]`); resolution not logged | ASUS 1920 × 550 @ 60.00, `[LINK]` 59.936 (`RIG.md`) | the same (`rig.log`, every block) | ASUS 59.936 (`[LINK]`) | No |
| LG (main display) | 120 Hz at `window shown` (`[LINK]`) | 3840 × 2160 @ 120 | the same | 120 Hz (`[LINK]`) | No |
| Display sleep | UNKNOWN for the nights. `pmset -g` today: `displaysleep 0`. No display-off event in `pmset -g log` for any of the nights (assertions only) | the same | the same | — | No evidence |
| Slots | yrgb→Waveform \| Meters \| Meters | Waveform \| Parade \| Markers | Waveform \| Parade \| Markers | Markers + 2 UNKNOWN | **No.** N2 and N3 are the same |
| Zoom | running, no windows | closed | closed | UNKNOWN | **No.** N3 was closed and bad |
| Signing | ad-hoc, licence prompt denied | the same | the same | Developer ID | No (N1–N3 the same) |
| Binary | `.build-pullphase` (3f05914) | the same | `.build-pacerphase` (fb553d3 + C) | `.build-rc094` | No (N1 = N2) |
| WindowServer `ASEProcessing` lines (unified log, read today) | 0 in 22:20–23:10 | 0 in 00:09–01:43 | about 2,400–3,600 a minute through every video block, 0 in the audio-only block (02:56–03:17) | not read | No (N1 = N2), but see §2.4 |
| `pmset -g log` assertions in the 59.94 hours | coreaudiod contexts 357 released; otherwise Manifold, AirPlay, Claude, cloudd | 54; the same others | 75; the same others | not read | No (inference: N1's coreaudiod churn is Zoom) |
| Manifold footprint (`[RENDER-PERF] footprintMB`) | 420–719 MB | 420–749 | 429–763 | 421–731 | No |
| Render GPU, render latency | unchanged (§12.2), lat p50-of-max 0.70–0.71 ms | 0.69–0.70 | 0.72 | 0.69–0.70 | No |
| Thermal | not logged. `pmset -g therm` today: "No thermal warning level has been recorded" | the same | the same | — | UNKNOWN |
| System memory pressure, swap | **not logged: UNKNOWN** | | | | |
| WindowServer CPU, GPU utilisation, compositor latency | **not logged: UNKNOWN** | | | | |
| Presented-handler latency (the quantity the gate counts) | **not logged: UNKNOWN**; only its effect, the hold counts | | | | |
| Other processes' windows on either display | **not logged: UNKNOWN** | | | | |

### 2.3 What can be said

- **No logged factor separates night 2 from nights 1 and 3.** The cause is UNKNOWN.
- Ruled out as the sole cause: time of night, uptime, slots, Zoom, signing, the display mode, the binary, option C. CONFIRMED by the
  table.
- **One pattern fits all four nights: how many ad-hoc launches came before the 59.94 block that night.** Each such launch raises the
  licence keychain prompt twice, and `rc-soak.py` denies it by accessibility clicks (§12.1). The signed 0.9.4 build had none, and
  its 5th block was good. This is a hypothesis with no mechanism shown. UNKNOWN (inference: state left in WindowServer by
  SecurityAgent windows, or by the earlier processes, which raises compositor latency). The test is in §4.4.
- Whatever the state is, the gate turns it into SDI damage through one path: handlers that return late make every present run on a
  repeat tick, where a block of over 8.3 ms misses the next new-frame tick. The fix in §3 is designed to work whatever the state is.

### 2.4 Found on the way: night 3's window had a per-frame scope surface that nights 1 and 2 did not

- WindowServer logged `+[ASEProcessing shouldEnhanceWidth:…]: src={ 569w x 320h }, dest={ 569w x 320h }, aseFunctionOnYesOffNo=1`
  1,153,243 times between 2026-11-17 03:45 and 2026-11-18 04:00. That is about 43/s in the 23.976 blocks and about 55/s in the 59.94
  blocks. There were none in the audio-only block. The first burst is 2026-11-17 13:49. The 569 × 320 size fits one of the three tray
  slots (the tray surface is logged as `1760w x 152h`). CONFIRMED (`/usr/bin/log show … process == "WindowServer"`).
- The scope sources changed between the two binaries. `WaveformScope.swift`, `ParadeScope.swift`, `ScopeColorFeed.swift` and
  `WindowChrome.swift` are dated 2026-11-16 13:05–15:20, after `.build-pullphase` (11-16 12:19) and before `.build-pacerphase`
  (11-17 11:52). Both scopes publish a `CGImage` per frame into a SwiftUI `Image` (`ParadeScope.swift:293`). Which slot is the 569 × 320
  surface is UNKNOWN.
- **What this means:** night 3 was not night 2's WindowServer workload, although every rig item checked was the same. It is not the
  shared cause, because night 1 was bad without it. Add "WindowServer `ASEProcessing` rate" to the rig record (see
  `soak-rig-state-must-be-recorded`).

---

## 3. Design options: SDI timing independent of the desktop display

Invariants any option must keep (from `CARD_PULL_MARGIN.md` §6 and the code):
- the SDI frame is the window's offscreen render, published to the ring from that command buffer's completion (`:4341-4350`, `:4326`);
- `noteDeckLinkTick` sees pacer ticks only (`:3511`, `:5486-5494`). Its median interval sets the pull margin;
- the colour state, drawable size and geometry have one writer, on the thread that calls `nextDrawable`/`present` (`:3567-3617`). The
  colour transaction lands in the same commit as the frame that shows it (`:3620-3625`; BUGS mode-change entry);
- the idle machinery's contract (`OutputPacer.swift:13-17`; `noteIdleTick` `:846-870`, which waits for `deferredPresent == nil`);
- the renderer watchdog reads `watchTickBegan`/`watchTickEnded` (`:3540`, `:3551`).

### A. The window presents on its own thread, at its display's refresh (recommended)

**What changes**
- While the pacer runs, its tick renders the offscreen, commits the SDI buffer, and posts "newest rendered frame" into a one-slot
  mailbox, with the latest write winning. It never calls `nextDrawable`, `present` or `CATransaction`.
- The window's CVDisplayLink, today stopped in pacer mode (`:3437`), runs on the window's display with a *present-only* callback. That
  callback is not `displayTick`, so it does not touch `noteDeckLinkTick`, the selection, the idle stamp or the watchdog clocks. Each
  vsync, if the mailbox holds a frame not yet shown, the callback presents it, keeping today's gate on in-flight presents. If no
  drawable is free, it skips that vsync.
- Every layer-property writer moves to the present thread for the pacer's duration: the colour state, `drawableSize`, the colour
  transaction and the field view. The link's thread becomes the "one thread" that the comments at `:3570-3617` require.
- The offscreen ring goes from 2 to 3 (`:618`). The present can read slot N while the pacer writes N+1, and N+2 cannot overwrite a
  slot still being read unless the present falls two frames behind. Today a deferred present always runs before the next render
  (§1.2), so 2 has been enough.
- Result: at most one present per display refresh, on the display's own grid. A block in WindowServer stalls only the link thread.
  The 59.94/59.936 beat appears on the window as one repeated or skipped desktop frame about every 4 min, not as a full queue.

**Risk to the card-lock paths**
- Pull, ring, convert, card lock, Stage 2, slips: no code change. The ring is still fed from the offscreen completion.
- **Margin:** low, provided the present callback cannot reach `noteDeckLinkTick`. Test it.
- **Idle:** medium. There would be two tick sources. The link must stop with the pacer at idle, honouring `setRunning(false)`
  waiting for a tick in flight. `canIdle` must look at the mailbox, not `deferredPresent`.
- **Colour:** medium. Moving the colour install off the tick thread changes ordering that is protected by measurement (84 switches,
  BUGS mode-change entry). This is window-only. SDI colour is in the offscreen.
- **GPU:** two command buffers per frame on one queue, as today. Unchanged.
- **Scopes:** one more offscreen texture (memory). Scopes read through `offscreenReadableIndex`, which is unchanged.
- **Size:** the largest change of the three, in a non-protected file. `OutputPacer.swift`, `FrameEngine.swift` and the pull are
  untouched.

**Test that would prove it**
1. **Forced stall** (DEBUG `MANIFOLD_PRESENT_STALL_MS=12` at random presents): sleep inside the present path, so the bad state can be
   made on demand instead of waited for.
   - Today's code predicts one pacer miss per stall that lands on a repeat tick, and `pacer` late swaps.
   - Under A: pacer missed deadlines ≤ 2 per hour (0.9.4 and night 2 level), 0 `pacer` late swaps, and the stalls show only in the
     present thread's counters.
2. Natural run: the 59.94 SDI block run 5th in the night (the bad placement), A off against A on, Waveform | Parade | Markers.
   - Criteria: misses ≤ 2 per hour on A-on whatever the holding share; window presented/s median ≥ 59; the 0.9.4 gate (holds only
     crossings, 0 skips, 0 freezes).
3. Identity: 23.976 Computer, 25p SDI, output off. The output-off path must be byte-identical (the link drives `displayTick` as today).

### B. `presentsWithTransaction = false` for pacer presents

**What changes**
- At the pacer switch, the render thread clears `presentsWithTransaction` and restores it at stop.
- `servePacedPresent` encodes and calls `cb.present(drawable)` before `cb.commit()`. It has no `waitUntilScheduled` and no
  `CATransaction` (`:4554-4559`; the warning at `:4711-4715` applies only while the flag is true).
- The colour transaction is committed at the end of the tick on its own, as on a tick that presents nothing (`:3625`).

**Risk to the card-lock paths**
- None directly: it removes work from the pacer thread.
- Window-only costs:
  - during a live resize, a frame can land at the wrong geometry, which is the reason for the flag (`:1252-1257`);
  - a colour-state change can show one window frame under the old state for 3–7.5 ms (the measured gap, `:3621-3623`).
- It does not make SDI independent. `nextDrawable` still runs on the pacer thread and still blocks when the pool is empty. It removes
  only the two calls this audit suspects, and if §4.1 shows the block is elsewhere, B does nothing.

**Test that would prove it:** first §4.1 must show the block is in `waitUntilScheduled` or `CATransaction.commit`. Then the same
natural A/B as A-2 (B off against on, 59.94 run late in the night): misses ≤ 2 per hour and repeat-tick > 5 ms at night 2's rate
(≤ 0.1 per 1,000). Add a resize-under-output check on the LG for the geometry cost.

### C. Skip a window present rather than block

**What changes.** Present only on the new-frame tick, right after its SDI commit. A frame the gate holds there is dropped for the
window, not served on the repeat tick: remove the second attempt at `:3546` while the pacer runs.

**Why only part of the fix.**
- None of the blocking calls can time out: `waitUntilScheduled` and `CATransaction.commit` have no deadline, and `nextDrawable`,
  the only one that has (`allowsNextDrawableTimeout`, 1 s), is not the slow one. So "skip rather than block" can be decided only
  before calling.
- What C does is move every present to the slot with the most slack: about 15.7 ms before the next new-frame deadline at k = 2,
  against about 8.3 ms on the repeat tick. The night 3 blocks (8.3–16.2 ms, median ~10.5) would then mostly fit. Inference from
  §1.5: those over ~15.7 ms would still miss.
- At k = 3 (23.976, 25) the slack is larger again.

**Risk to the card-lock paths:** none, since it removes work from the pacer. Window cost: in a holding state the window drops about
every other frame, so it shows about 30 fps judder exactly when WindowServer is slow.

**Test:** the forced stall at 12 ms, then at 16 ms. Prediction: 0 misses at 12 ms and misses at 16 ms. That shows C only moves
the threshold. Plus a presented/s count in the holding windows.

### Not recommended

- **Tightening `presentsWaitingLimit` to 0.** It keeps the queue shallow, but every present still runs on the pacer thread.
- **Raising `maximumDrawableCount`.** `nextDrawable` is not the blocker.

---

## 4. Recommendation

### 4.1 First: measurement only (DEBUG, no behaviour change)

In `servePacedPresent` and `presentDrawable`, time `makeCommandBuffer`, `encodeDisplayStage`, `commit`, `waitUntilScheduled`,
`CATransaction.commit` and `closeColorStateTransaction` separately, into the existing 10 s line. Record per present:
- present call → `presentedTime` (the handler latency the gate is counting);
- the in-flight count at the attempt;
- whether it ran on a new-frame or a repeat tick.

Also record in each block's rig file:
- the WindowServer `ASEProcessing` count per minute;
- `memory_pressure -Q`;
- `pmset -g therm`;
- `ps -axo comm=` for SecurityAgent.

This replaces §1.5's UNKNOWN with the name of the call, and gives the handler latency on good and bad nights.

### 4.2 Then: option A behind a DEBUG switch, off by default

Option A is the only option that makes the SDI tick independent of WindowServer by construction. It also ends the
59.94-on-59.936 queue build-up, because the window is paced by its own display. Option B may be used as a one-night experiment
if §4.1 names `waitUntilScheduled` or `CATransaction.commit`. Do not ship it as the fix: it leaves the pacer exposed to every
other present-path call.

### 4.3 What A does not fix

Crossings: option C of `CARD_PULL_MARGIN.md` and the reference-window gap in §15.3. The pacing-renderer stall (§15.3). The 1–6 misses
per block in clean windows, whose tick did not serve a present (§1.5). Their cause is UNKNOWN.

### 4.4 The rig question (§2.3), separately

Run one night with the same binary and a fixed layout:
1. 59.94 first;
2. the 23.976 and 25 blocks;
3. 59.94 again.

If block 3 degrades and block 1 does not, the state builds up over the night. Repeat the night with a signed build. If the signed
night stays clean, the keychain prompt is implicated. Record the §4.1 rig items before each block.
