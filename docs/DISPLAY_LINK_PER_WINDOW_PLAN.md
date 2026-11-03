# The display link follows the window's display: map, measurements and plan

Plan, 2026-10-31, at `26f7794` (Profile, `.build-cc`). No app code was changed. Source: the 0.9.1 entry in `docs/BUGS.md`
(*the window's display link follows the MAIN display*, `BUGS.md:3620`). Target: 0.9.1.

## Summary

- **One `CVDisplayLink` per window**, made with `CVDisplayLinkCreateWithActiveCGDisplays` and never retargeted. It ticks
  at the main display's rate (the LG, 120 Hz) wherever the window is. Measured again below: 8.33 ms ticks on the ASUS
  (59.936 Hz) at every rate. A move in mid-play changes nothing.
- **The fix for the window:** retarget the existing link with `CVDisplayLinkSetCurrentCGDisplay` when the window is bound
  and when it changes screen. Probed outside the app: this works on a running link and on a stopped one (§3.1). It keeps
  the thread, the callback, the idle stop and the −6660 recovery as they are. `CADisplayLink` stays the post-release
  project (`BUGS.md:2016`).
- **SDI cannot simply follow.** Every SDI frame is made by the owning window's render, so after the fix SDI would be
  paced by the window's display: by construction, 119.88 or 100 out of a window on a 60 Hz display fails, and 59.94
  gets supersede bursts (§4.3). **Proposal:** while a renderer feeds DeckLink output, its tick comes from an *output
  pacer*, a host-clock thread whose rate is set by the card's mode and the source's rate and never by a display. The
  pacer is the seam the 1.1 card-clock work plugs into (§4.5).

---

## 1. Map

### 1.1 The link: creation, binding, lifecycle

| What | Where |
|---|---|
| One renderer per window (`RendererStore`, "one store — and so one renderer — per ContentView, i.e. per WINDOW") | `App/ContentView.swift:257-262` |
| The link: one per renderer, created and released on `linkQueue` only | `App/MetalVideoRenderer.swift:620-621`, `:644` |
| `start()`: makes and starts the link | `App/MetalVideoRenderer.swift:3138-3147` |
| `makeDisplayLink()`: **`CVDisplayLinkCreateWithActiveCGDisplays`**, callback → `displayTick()` | `App/MetalVideoRenderer.swift:3151-3162` (create at `:3153`) |
| Never retargeted: no `CVDisplayLinkSetCurrentCGDisplay` and no `CVDisplayLinkCreateWithCGDisplay` anywhere in `App/` | grep, 2026-10-31 |
| `start()` caller: once per window, at the end of the deck's wiring | `App/WindowDeck.swift:1179` |
| `stop()`: stops and releases the link, then flushes; caller: the window's `onDisappear` | `App/MetalVideoRenderer.swift:3164-3173`; `App/ContentView.swift:733` |
| The window's screen, as the renderer already reads it (`hostView?.window?.screen`) | `App/MetalVideoRenderer.swift:1230-1233` |
| Bind: `MetalSurfaceView.viewDidMoveToWindow` → `hostViewDidMoveToWindow()` | `App/MetalSurfaceView.swift:38-44`; `App/MetalVideoRenderer.swift:1241-1246` |
| Existing per-window `didChangeScreen` observers, filtered to the renderer's own window (headroom; Reference plan) | `App/MetalVideoRenderer.swift:1290-1312`, `:1251-1265` |

The link is per window, not per app. Every window's link is on the active displays and reports the main display as
current. The probe below read `CVDisplayLinkGetCurrentCGDisplay` = 3 (the LG) for a fresh active-displays link.

### 1.2 The idle link and its recovery

| What | Where |
|---|---|
| Design note: a paused window stops its link; what wakes it; what never idles | `App/MetalVideoRenderer.swift:623-643` |
| `wakeDisplayLink()`: any thread; resumes an idle-stopped link and checks every 250 ms that a link meant to run is ticking | `:669-683` |
| `ensureRunningOnQueue`: start; if CoreVideo refuses (−6660), **recreate with `makeDisplayLink()`** and start; else mark stopped | `:693-722` (recreate at `:714`) |
| DEBUG watchdog (no tick 500 ms after a wake) and `MANIFOLD_IDLE_FAIL_START` | `:657-659`, `:727-736` |
| `setRunning`: the one start/stop | `:741-743` |
| `noteIdleTick`: after every tick; can idle only when no one-shot is armed, `onDisplayTick`, the hold floor and the calibration tap are nil, and paused | `:746-767` (condition `:757-758`) |
| `stopForIdle` | `:770-780` |

Wakes come from every one-shot setter and `enqueue` (`:847`, `:929`, `:1384`, `:2054`, `:2424`, `:2438`, `:2465`, `:3083`,
`:3110`), from installing the clock and pause providers, the pull hook and the hold floor (`:250`, `:257`, `:281`, `:381`),
from the calibration tap (`:329`), and from the engine's rate change (`App/WindowDeck.swift:1121`). Note `canIdle` does not look at
DeckLink: a paused window feeding SDI also stops its link, and the card holds the front frame
(`primeDeckLinkFrame`, `:4629-4639`, wakes it on a start).

### 1.3 Every consumer of the tick

`displayTick` (`:3179-3212`) → `performDisplayTick` (`:3218-…`), on the CVDisplayLink thread:

| Consumer | Where | What the tick rate does to it |
|---|---|---|
| DeckLink pull margin: tick intervals while output runs | `noteDeckLinkTick`, `:3180`, `:4694-4702`; margin = median tick + 10 ms, `:4707-4711` | margin 18.3 ms at 120 Hz, 26.7 ms at 60 Hz |
| DEBUG tick cadence for `[RENDER-PERF] tickMs` | `:3184-3191`, log `:4118` | the measurement in §2 |
| Layer installs: colour state, drawable size, geometry, field chroma, field view | `:3244-3344` | applied on the next tick, so one tick of latency |
| One-shot wipe (`pendingClear`) | `:3348-3357` | latency only |
| **Pull sources' frame pull** (`onDisplayTick`): NDI, HLS | `:3362`; `App/NDI/NDIService.swift:591`, `App/HLS/HLSClient.swift:1057`; cleared `App/Live/LiveDisplayRoute.swift:195` | **the pull rate is the tick rate** (NDI through FrameSync, `BUGS.md:14616-14622`) |
| Off-clock one-shot (`presentImmediate`, the scrub seam) | `:3387-3401` | latency only |
| Live hold floor (`presentationHoldFloor`, LiveClock's start-up window) | `:3410`, `:3417-3424` | sampled once per tick |
| **Frame selection**: newest queued frame with pts ≤ clock; older due frames dropped as superseded | `:3412-3439` | a frame due in the same tick as a newer one is never rendered |
| `onQueueRoom` (the 0.9.1 decode backpressure) | `:609-611` | the pump resumes when a tick consumes |
| `[PLAYBACK-STATS]`, `presentedFPS` / `[Play] presented` | `:1516-1560`, `:3538`, `:3597`, `:3614-3631` | the measurement in §2 |
| **Render**: offscreen pass, then `nextDrawable()` in the same command buffer | `renderPixelBuffer`, `:3686`; drawable `:3910` | a nil drawable drops the offscreen render and its SDI convert (pre-existing, `BUGS.md:2004`) |
| **Scopes** (waveform, parade, vectorscope, CIE): `onFrameRendered` from the render's completion | `:3979-4006`; wired `App/ContentView.swift:1642-1649`; triggers e.g. `App/WaveformScope.swift:665` | sample once per rendered frame |
| **SDI v210 convert**: `pushDeckLinkConvert` from the same completion | `:4009`, `:4768-…` | one converted frame per rendered frame |
| `[RENDER-PERF]` | `:4083-4132` | — |

Not tick-driven, but related:
- **SDI hand-off**: the card's `ScheduledFrameCompleted` (`App/DeckLink/DeckLinkBridge.mm:665`) refills and reschedules
  (`:698`) through the fill block (`App/DeckLink/DeckLinkService.swift:929-931`) → `copyLatestDeckLinkFrame`
  (`App/MetalVideoRenderer.swift:5043-5063`) → `deckLinkPullSlotLocked` (`:5066-5133`). Preroll at
  `DeckLinkBridge.mm:369-382`. Card clock.
- **The activity assertion**: `DeckLinkService.outputActivity`, begun and ended by `isOutputting`'s observer:
  `.userInitiated, .idleDisplaySleepDisabled, .latencyCritical` (`App/DeckLink/DeckLinkService.swift:83-102`). It keeps the
  displays awake and turns off timer coalescing while output runs. It does not touch the link.
- **Engine rate change → wake** (`App/WindowDeck.swift:1121`).

---

## 2. Measurements (current behaviour, `26f7794`)

**Method.** Launched by binary path after `manifold-proc.sh guard`, with `MANIFOLD_PLAYBACK_STATS=1`. Quit by PID through
`manifold-proc.sh quit`, and guard clean afterwards. Files were opened with `manifold-proc.sh open` and the window was moved with
`AXPosition`. Play and Pause were AX presses on named buttons. Always Show Controls and Close All were AX menu clicks. No
keystrokes and no screenshots. Clips: the 120 fps session's `hfr_23.976.mov`, `hfr_59.94.mov` and `hfr_120.mov` (1080p,
10 s). Each pass played 6 s. "Ticks per window" is `[RENDER-PERF]`'s count over its ≈1 s window. Presents are
`[PLAYBACK-STATS] presented` per ≈1 s window. The window's display is confirmed by the colour probe
(`CGDisplayCopyColorSpace(displayID=4)` for the ASUS) on every ASUS pass. The driver, analyser and log are in this
session's scratchpad.

### 2.1 Displays, as macOS reports them

| Display | ID | Main | `CGDisplayMode.refreshRate` | `NSScreen.maximumFramesPerSecond` | `CVDisplayLink` nominal |
|---|---|---|---|---|---|
| LG TV SSCR2 | 3 | yes | 120.0 | 120 | 120.000 Hz |
| ASUS PA147 | 4 | no | 60.0 | 60 | **59.936 Hz** (16.68 ms) |

Both have a fixed refresh (min = max refresh interval). Neither is variable-refresh.

### 2.2 Tick rate and presents, window on each display

| Clip | Display | Tick (mean / per ≈1 s) | Presented per ≈1 s | Superseded | Late |
|---|---|---|---|---|---|
| 23.976 | LG | 8.33 ms / 120–125 | 26 25 25 24 25 | 0 | 0 |
| 23.976 | ASUS | **8.33 ms / 120–125** | 25 24 25 24 24 | 0 | 0 |
| 59.94 | LG | 8.33 ms / 121–122 | 62 61 60 61 61 | 0 | 0 |
| 59.94 | ASUS | **8.33 ms / 120–122** | 62 60 61 60 60 | 0 | 0 |
| 120 | LG | 8.33 ms / 120–121 | 122 121 121 120 121 | 0 | 0 |
| 120 | ASUS | **8.33 ms / 120–122** | 118 119 115 115 119 | 5 2 5 6 3 | 0 |

- **The tick is the LG's on both displays.** On the ASUS the window makes 120 presents a second on a 60 Hz panel, and at
  least half of them can never reach the glass.
- **Drawable cost on the ASUS at 120 fps:** `drawMs` (the time spent in `nextDrawable()`) averages 0.09–0.13 ms, max 4.6 ms, against 0.01–0.02 ms (max ≤0.5) on the LG.
  This is the start of back-pressure from presenting faster than the panel.
- **The 120 fps / 120 Hz phase effect.** In the mid-play move pass (§2.3), 120 fps on the LG showed 107–118 presented and
  3–14 superseded a second, where the first LG pass had 120–122 and 0. Frame due times sitting on tick times means jitter
  splits them between ticks. This is a tick-phase effect, not a display effect; 119.88 behaved like this in the 120 fps work
  (`BUGS.md:3583-3584`).
- **Not measurable here:** a window on a faster display than the main one (the LG is both main and fastest, and
  changing the main display is a system setting this session did not touch).

### 2.3 A window moved between displays mid-play

LG → ASUS at 4 s (3 s for 120 fps) → LG 4 s (3 s) later, while playing:

| Clip | Before | On the ASUS | Back on the LG |
|---|---|---|---|
| 59.94 | 8.33 ms; 62 61 60 | 8.33 ms; 60 60 60 61 | 8.33 ms; 60 60 |
| 120 | 8.33 ms; 116 113 (6, 7 superseded) | 8.33 ms; 113 118 113 (7, 3, 9) | 8.33 ms; 109 107 113 (13, 14, 8) |

The move shows up only in the colour and headroom logs (`[EDR] headroom (display change — window moved)`, `[CSPROBE] …
displayID=4` then `=3`). The tick doesn't change and there's no gap. 0 late throughout.

### 2.4 Two windows

**Only one window plays at a time, by design** (`docs/MULTIWINDOW_FINDINGS.md:10-11`): Play in a second window pauses the
first. With `hfr_23.976.mov` on the ASUS and `hfr_59.94.mov` on the LG, both Play presses succeeded, but only the
LG window rendered (60–62 a second, 8.33 ms ticks). The ASUS window had idle-stopped its link. So "two windows on
different displays at once" means one playing window and one that is paused but rendering one-shots (step, seek, scrub, a
colour or LUT change, a resize), or an SDI owner beside a second window. §5 tests it that way.

### 2.5 The retarget mechanism, probed outside the app

A standalone Swift probe (no Manifold code; a fresh active-displays link with a counting callback):

| Step | rc | Current display | Ticks in 1 s, mean / max interval |
|---|---|---|---|
| Start (active displays) | 0 | 3 | 119, 8.33 / 9.30 ms |
| `CVDisplayLinkSetCurrentCGDisplay(4)` **while running** | 0 | 4 | 60, 16.76 / **21.25** ms |
| `SetCurrentCGDisplay(3)` while running | 0 | 3 | 120, 8.36 / **10.86** ms |
| Stop, `SetCurrentCGDisplay(4)`, start | 0, 0 | 4 | 60, 16.66 / 17.69 ms |
| `SetCurrentCGDisplay(999)` (no such display) | **−6670** | 4 (unchanged) | 59, 16.96 / 33.44 ms |

A running link can be retargeted in place. The switch costs about one long interval. An invalid ID is refused and the old
target is kept.

---

## 3. Plan: each window's link follows its window's display

### 3.1 Choice: retarget the existing `CVDisplayLink`, not `CADisplayLink`

`CVDisplayLinkSetCurrentCGDisplay` fits the existing code. The tick stays on CoreVideo's high-priority thread, and
`displayTick`, the per-tick autorelease pool (`:3194-3207`), the idle stop and the −6660 recovery stay as they are.
`NSView.displayLink(target:selector:)` / `CADisplayLink` changes the thread (main run loop by default), the timestamps and
every consumer in §1.3 at once. That's the post-release item `BUGS.md:2016-2035`, which already asks for a full re-measure.
Whether a `CADisplayLink` made from a view can be scheduled on a dedicated thread's run loop on macOS is **UNKNOWN** and not
needed here. The API is already deprecated in use; this adds one more deprecated call (a build warning), and that project
removes them together.

### 3.2 The change

1. **Target state.** `linkTargetDisplay: CGDirectDisplayID?`, read and written on `linkQueue` only, beside `displayLink`
   (`:621`).
2. **One retarget entry.** `retargetDisplayLink()` (MAIN): resolve `hostView?.window?.screen`'s `NSScreenNumber`, the same
   lookup as `:1321`. If the window has no screen (not yet on screen, or a transient state during a Space or full-screen
   change), keep the current target. Otherwise `linkQueue.async`: if the ID is unchanged, do nothing; else store it and, if a link
   exists, `CVDisplayLinkSetCurrentCGDisplay(link, id)` (running or idle-stopped: both work, §2.5). On a non-success rc,
   log and keep the old target (−6670 leaves the link as it was).
3. **Every new link gets the target.** `makeDisplayLink()` (`:3151`) applies `linkTargetDisplay` after creating, so the
   −6660 recreation (`:714`) and `start()` (`:3141`) both land on the window's display, not the main one.
4. **Triggers**, all MAIN:
   - bind: `hostViewDidMoveToWindow()` (`:1241`), already called from `MetalSurfaceView.viewDidMoveToWindow`;
   - `NSWindow.didChangeScreenNotification`, filtered to `hostView?.window`, the pattern at `:1297-1301`. Add it beside the
     headroom observers, not inside the Reference-only ones (`:1257-1258` return outside Reference);
   - `NSApplication.didChangeScreenParametersNotification` (a display connected, disconnected or re-moded). Re-resolve:
     the window may now be on a different screen, and a display ID can disappear.
5. **The silent-link check after a retarget.** A switch costs up to about 33 ms between ticks (§2.5), well under
   `silentLink` (250 ms, `:654`), so the check (`:675`, `:697`) should not fire. No change is needed; the test plan
   confirms it.
6. **Log.** One ungated line per retarget, like the `[EDR]` family: `[LINK] window <n> → display <id> "<name>" (<nominal>
   Hz) · rc <rc>`. It's the line the test plan reads off, and in a tester's diagnostics export it says what the window
   ticked at. Add the link's current display and nominal rate to `DiagnosticsExport` beside the screens it already lists
   (`App/DiagnosticsExport.swift:706`).
7. **Exception: a renderer feeding SDI.** That renderer's tick comes from the output pacer (§4.4), not this link.
   Retargets still update `linkTargetDisplay`, so when output stops the link restarts on the right display.

### 3.3 What changes for the consumers (no SDI)

| Consumer | Window on the ASUS, after |
|---|---|
| Frame selection | 59.936 ticks a second. A 120 fps file shows ≈60 a second, ≈60 superseded (correct for the panel). A 59.94 file has 0.004 more frames than ticks a second: one superseded about every 250 s, plus short bursts while its due times cross the tick phase (§4.3 a). A 23.976 file: 2.5 ticks a frame, none superseded. |
| Window presents | ≤ 60 a second; the wasted presents and the `drawMs` back-pressure in §2.2 go away |
| One-shots (colour state, resize, scrub seam, seek render) | up to 16.7 ms latency instead of 8.3 |
| NDI and HLS pull | pulled at 59.94 a second instead of 120. FrameSync is designed to be pulled at display rate. **This is a streaming behaviour change:** verify on NDI and on one non-Cloudflare server (CLAUDE.md) |
| Live hold floor; `onQueueRoom` | sampled or resumed half as often; no change in behaviour expected |
| Scopes | ≤ 60 samples a second for a 120 fps file (less work) |
| A/V sync | unaffected: selection is by clock (`BUGS.md:3633`) |

---

## 4. SDI

### 4.1 Paced by what today

| Step | Paced by |
|---|---|
| Which frames exist in the SDI ring | **the window's display tick**: only a frame that a tick selects is rendered (`:3412-3439`), and only a rendered frame is converted (`:4009`). A superseded frame never reaches the card. |
| Conversion timing | the render's GPU completion |
| Which ring frame each card slot gets | the card's clock, via `deckLinkPullSlotLocked` (`:5066-5133`), with a margin of median display tick + 10 ms (`:4707-4711`) |
| Scheduling, completions, audio | the card's clock (`DeckLinkBridge.mm:665-698`; `SDI_OUTPUT_TIMING.md` §1) |

So today SDI depends on the **main** display's refresh: that link is the one the window renderer ticks on.
Every SDI measurement to date ran on a 120 Hz tick, including the ASUS rows in `SDI_OUTPUT_TIMING.md` §2 (`:77`, "the link stays
on the LG"). `SDI_OUTPUT_TIMING.md:97-98` lists a 60 Hz main display as not run.

### 4.2 After §3 alone

SDI would be paced by **the display the window is on**. That breaks the rule (*SDI output must never depend on which
desktop display the window is on*). §3 must not ship without §4.4.

### 4.3 Worked cases: window on a 60 Hz display (the ASUS, 59.936 Hz), §3 alone

All of these follow from the code. None was measured: no SDI was run this round.

- **(a) 1080p59.94, 59.94 file.** Frames (59.940/s) outnumber ticks (59.936/s), so about every 250 s one frame is superseded,
  never converted, and the card gets a repeat and a skip. The due times also cross the tick phase every 250 s. With
  tick jitter of 1–5 ms (§2.5), each crossing gives a burst of supersede/repeat pairs. On a true 60.000 Hz display the
  counts favour the ticks, but the crossing comes every 16.7 s. **Not frame-perfect.** The margin becomes 26.7 ms
  (+8.3 ms latency).
- **(b) 2160p59.94.** As (a), plus a 4K render and convert inside one 16.7 ms tick. 4K timing at a 60 Hz tick: **UNKNOWN**.
- **(c) 1080p23.98, 23.976 file.** 2.5 ticks per frame, never two frames due in one tick. Expected 0 repeats / 0 skips,
  with +8.3 ms latency from the larger margin.
- **(d) 2160p119.88 or 2160p100 (modes exist: `DeckLinkBridge.mm:1082-1084`).** The window renders at most about 60
  frames a second, so at most about 60 distinct frames reach the ring, and half the card's slots repeat. **Broken by construction.**
  Today this case is fed by the LG's 120 Hz tick wherever the window is. That gives 100 fine, and 119.88 a 0.12 Hz beat against
  120 with supersede bursts like the on-screen 119.88 result (`BUGS.md:3583`). SDI at either rate has **never been
  measured**.

The same arithmetic applies **today** to any Mac whose main display is 60 Hz, whatever window it uses. (a) and (d) are a
pre-existing exposure for testers, not something §3 creates. §4.4 removes it.

### 4.4 Proposal: an output pacer for the renderer that feeds SDI (0.9.1)

**While a renderer feeds DeckLink output, its tick comes from an output pacer instead of its display link.** The pacer
calls the same `displayTick()`. Selection, render, convert, ring, pull and audio don't change. Only what drives the tick
changes, and its rate is set by the output and the source, never by a display.

- **Rate.** Let `f` be the shorter of the card's frame duration (`deckLinkCardFrame`, set in `beginDeckLinkOutput`,
  `:4600-4617`) and the source's frame duration (a live source with no stated rate uses the card's). The period is
  `P = f / k` with `k = max(2, ceil(f × 60 Hz))`, so there are always a whole number of ticks per frame (≥ 2), and at least
  60 ticks a second for one-shots and the window:

  | Output / source | f | k | P (rate) |
  |---|---|---|---|
  | 23.976 | 41.71 ms | 3 | 13.90 ms (71.9 Hz) |
  | 25 | 40.00 ms | 3 | 13.33 ms (75 Hz) |
  | 29.97 | 33.37 ms | 3 | 11.12 ms (89.9 Hz) |
  | 59.94 | 16.68 ms | 2 | 8.34 ms (119.88 Hz), the LG's cadence: every SDI measurement to date |
  | 100 | 10.00 ms | 2 | 5.00 ms (200 Hz) |
  | 119.88 | 8.34 ms | 2 | 4.17 ms (239.76 Hz) |

  With ≥ 2 ticks per frame on the same host clock as the source clock (the synchronizer runs on host time × rate), two frames
  can be due in one tick only if a tick is later than `P` (4–14 ms). Today's measured jitter is under 2 ms (max 10.3 ms against an 8.33 ms mean).
  There's no phase to tune and no beat: the period is derived from the frame, not from a display.
- **Thread.** One dedicated thread per pacer, with Mach time-constraint policy (CoreVideo's link thread is high priority
  too), sleeping with `mach_wait_until` to absolute deadlines (no drift accumulation). It skips a missed deadline rather
  than bursting. The activity assertion already held during output (`.latencyCritical`, `DeckLinkService.swift:94-96`)
  keeps timers uncoalesced. The per-tick autorelease pool is already inside `displayTick` (`:3207`).
- **One tick source at a time.** `performDisplayTick` is single-threaded by design ("one writer, one thread",
  `:3228-3243`). Switching happens on `linkQueue`: to the pacer, `CVDisplayLinkStop` (it waits for an in-flight
  callback) and then start the pacer; back, stop the pacer and join its in-flight tick, then start the link on
  `linkTargetDisplay`. The idle machinery (`wakeDisplayLink`, `noteIdleTick`, `stopForIdle`, `ensureRunningOnQueue`) acts on
  "the active tick source" through `setRunning` (`:741`). A paused output still idle-stops (as today), and
  `primeDeckLinkFrame` still wakes it.
- **Hooks.** Start the pacer in `beginDeckLinkOutput` (`:4600`) and stop it in `stopDeckLinkOutput` (`:4741`). Both are
  already the renderer's output edges, and `DeckLinkService` reaches the owning renderer only (`DeckLinkService.swift:930`).
  A mode change goes stop → start, so the pacer is rebuilt at the new rate. A source-rate change while output runs (a new file in
  the owning window) recomputes `P`.
- **Margin.** `noteDeckLinkTick` already measures whatever ticks. With the pacer, the margin is `P + 10 ms`: 18.3 ms at
  59.94, the value measured on the LG (`:4704-4706`). At 23.98 it's 23.9 ms (today 18.3).
- **The window that owns output.** It presents at the source rate (≤ the pacer rate) whatever its display. On a 60 Hz
  display with 119.88 output, that's today's ASUS behaviour (§2.2: 115–119 presented, `drawMs` max 4.6 ms), measured
  harmless for SDI. Other windows keep their own display-following links.
- **Logs.** `[PACER] started for 2160p59.94 · source 59.94 · P 8.34 ms (k 2)` and `[PACER] stopped — link back on
  display <id>`, ungated, beside `[POWER]`. DEBUG: the pacer's interval mean and max in `[RENDER-PERF] tickMs` (the
  cadence stamp is already source-agnostic, `:3184-3191`).

**Rejected:**
- *Pin the SDI owner's link to the fastest active display.* SDI would then depend on which displays the Mac has: a
  60 Hz-only Mac keeps (a) and (d) in §4.3.
- *Tick at the card rate from `ScheduledFrameCompleted`.* That's the 1.1 Stage 3. Without Stages 1–2 the window would show
  only the frames the card's slots pick (a 59.94 file into a 23.98 output would display at 23.98), and a nil drawable would
  still drop the SDI frame.

### 4.5 Relation to the card-clock work (1.1)

The 1.1 design (`SDI_OUTPUT_TIMING.md` §3, staged plan `:133-141`; `BUGS.md` *card-clock-driven DeckLink output*,
`:2000-2014`) moves the output render to the card's clock. The pacer is a smaller step in the same direction, and is
compatible with it:

| | 0.9.1 pacer | 1.1 card clock |
|---|---|---|
| What paces the output render | host-clock thread at `f / k` | the card asking for slot n's frame |
| Independent of the window's display | **yes** | yes |
| Independent of the window's drawable | no (nil `nextDrawable()` still drops the SDI frame, `:3910`) | yes (Stage 1 split) |
| Separate consumption cursor for SDI | no | yes (Stage 2) |
| Card-vs-host drift | absorbed by the ring and pull, as today (`:5107-5124`) | none by construction |
| GPU cost | one render per source frame (as today) | about two renders per frame while the window is visible |

The pacer adds the seam Stage 3 needs, a renderer whose tick source isn't its display link. Stage 3 then replaces the
pacer's timer with the card's request and splits the present from the offscreen pass.

---

## 5. Test plan for the implementation

All of these run on the implementation build, guard → launch by binary path → quit by PID, with no keystrokes and no
screenshots, and Robbie told before each launch. Logs used: `[LINK]`, `[PACER]`, `[RENDER-PERF] tickMs`, `[PLAYBACK-STATS]`,
`[IDLE]`, the DeckLink `D3 … completed/late/dropped` lines, and `[CADENCE]` (`MANIFOLD_DECKLINK_CADENCE_LOG=1`).

### 5.1 Repeat §2 (expected values)

| Case | Expected |
|---|---|
| Each window's `[LINK]` at bind | display 3 on the LG, 4 on the ASUS |
| 23.976 / 59.94 / 120 on the LG | 8.33 ms ticks; presents as in §2.2 |
| Same on the ASUS | **16.68 ms ticks (≈60 a second)**; 23.976 → 24–25, 59.94 → ≈60 (count superseded over a ≥ 60 s run), 120 → ≈60 presented, ≈60 superseded, 0 late; `drawMs` max back under 0.5 ms |
| Mid-play LG → ASUS → LG, 59.94 and 120 | `[LINK]` at each move; tick changes within one interval; no `[IDLE] ⚠️` silent-link line; 0 late |
| Paused on the ASUS, then step, seek, colour/LUT change, resize | each one-shot renders; `[IDLE]` stop and wake as before; no watchdog line |

### 5.2 SDI, window on each display (the rule)

For each output mode, the window on the LG, then on the ASUS, then moved between them mid-play. File source, Follow source,
≥ 30 s playing, then measured through the SDI loop as in `SDI_OUTPUT_TIMING.md` §2 (repeats/skips at the card's input,
changed/received on the wire).

| Mode | Expected, both displays and across the move |
|---|---|
| 1080p59.94 | `[PACER] P 8.34 ms`; **late 0, dropped 0**; 0 repeats / 0 skips; margin 18.3 ms; latency band as `SDI_OUTPUT_TIMING.md:81-84` |
| 1080p23.98 | `[PACER] P 13.90 ms`; **late 0, dropped 0**; 0 / 0; margin ≈23.9 ms |
| 2160p59.94 | as 1080p59.94; record `gpuMs` and the front's lateness at 4K |
| 2160p119.88 and 2160p100 (if the card and loop accept them) | `[PACER] P 4.17 / 5.00 ms`; 0 / 0, **including with the window on the ASUS** (the case §3 alone breaks) |
| Output stop | `[PACER] stopped — link back on display <the window's>`; the next playback ticks at that display's rate |
| Long run: 59.94 for 10 min, window on the ASUS | 0 repeats / 0 skips (the 250 s beat case in §4.3 a) |
| Paused with output; Play | prime still lands (`primeDeckLinkFrame` ms logged); pacer idle-stops and wakes |

### 5.3 The 120 fps clips

The nine files from the 120 fps work (`BUGS.md:3586-3589`), on the LG and the ASUS. LG: the verified numbers.
ASUS: ≈60 presented, the rest superseded, 0 late, **0 `[FRAMEQ]`, 0 `[FREEZE-GUARD]`**. The decode backpressure must
still never evict at a 60 Hz consume rate (`onQueueRoom` resumes on each tick's selection).

### 5.4 Idle-link recovery

- `MANIFOLD_IDLE_FAIL_START=1` (`:657-659`), window on the **ASUS**: every wake recreates the link; `[LINK]`/the tick
  shows the recreated link on display 4, not 3 (the `makeDisplayLink` target, §3.2 step 3).
- Idle-stopped on the ASUS → move to the LG while stopped → Play: the link restarts on display 3.
- With output running: the same flag must not touch the pacer; stopping output must bring the link back on the window's display.

### 5.5 Two windows on different displays

Only one window can play at a time (§2.4), so:
- A playing on the LG; B paused on the ASUS. Step, seek and resize B (its one-shots wake it): A's tick stays 8.33 ms and
  B's link wakes on display 4 (16.68 ms), each in its own `[LINK]` line. Then focus B and Play (A pauses): B ticks at 16.68 ms.
- A owns SDI output (pacer) on the ASUS; B on the LG is stepped, scrubbed and scoped: SDI stays at 0 late / 0 dropped and
  0 / 0 at the card; B ticks at 8.33 ms; A's window presents through the pacer.
- Close the SDI owner while it outputs: output stops (as today), the pacer is gone, nothing ticks for the closed window
  (`stop()`, `ContentView.swift:733`).

### 5.6 Regression

- Live: NDI (local sender) and one non-Cloudflare stream (OBS SRT or MediaMTX WHEP), window on each display, with and
  without SDI output. A/V sync per `docs/AV_SYNC_FINDINGS.md` (Audio Hijack + the OBS recorder only). The NDI pull rate
  changes from 120 to ≈60 a second on the ASUS.
- Colour byte-identity of the 20-file export set (unchanged: the offscreen pass is untouched).
- `swift test` (ManifoldCore).
- Build warnings: +1 expected (`CVDisplayLinkSetCurrentCGDisplay`, deprecated), listed with the four in `BUGS.md:2020-2022`.

---

## 6. Open and unknown

- 4K render and convert inside a 60 Hz tick (§4.3 b): **UNKNOWN**; with the pacer it is an 8.34 ms tick, as today.
- A variable-refresh (ProMotion or adaptive-sync) display: the link follows the nominal rate. Behaviour **UNKNOWN**: there
  isn't one here.
- A window on a faster display than the main one: not measurable on this Mac (§2.2).
- SDI at 100 and 119.88: never measured, today or after.

---

## 7. Implementation and results (2026-11-01, unattended; working tree, not committed)

Approved with three additions: A (the 60 Hz-main baseline: attended, prepared, not run), B (in pacer mode the desktop presents
are capped at the window's display and a slow drawable cannot delay the SDI convert), C (the pacer's interval spread in every SDI run).

### 7.1 What changed

| Where | What |
|---|---|
| `App/MetalVideoRenderer.swift` | `linkTargetDisplay`; `retargetDisplayLink(reason:)` (MAIN) → `retargetOnQueue` (`linkQueue`): `CVDisplayLinkSetCurrentCGDisplay` on the running or idle link, refusal keeps the old target; triggers: `hostViewDidMoveToWindow` ("window shown"), the window's `didChangeScreen` ("window moved"), `didChangeScreenParameters` ("display reconfiguration", re-reads the rate even for the same display); `makeDisplayLink` applies the target to every new link, the −6660 recreation included. One `[LINK]` line per retarget. |
| same | The pacer switch: `beginDeckLinkOutput` → `schedulePacer` → `startPacerOnQueue` (stop the link, which waits for its tick, then start the pacer in the link's idle state); `stopDeckLinkOutput` → `stopPacerOnQueue` (join the pacer, hand back to the link on the window's display); `setDeckLinkSourceFrameRate` re-rates a running pacer. The idle stop and wake (`stopForIdle`, `ensureRunningOnQueue`) act on whichever source is active; `MANIFOLD_IDLE_FAIL_START` touches only the link. `stop()` cancels a pacer. |
| same, `renderPixelBuffer` | B. In pacer mode the command buffer holding the offscreen pass is committed, with the completion that publishes the frame and pushes its v210 convert, BEFORE any drawable is asked for; the present is a separate command buffer through `servePacedPresent`: at most one present waiting for the glass (so `nextDrawable()` always finds one of the pool of three free) and none sooner than ¾ of the window's display period after the last. A frame the gate holds back waits in `deferredPresent` (cleared by the wipe; a paused window does not idle while one waits) and the next tick the gate allows shows it. The normal path is unchanged in order; the display-stage encode and the completion are shared helpers (`encodeDisplayStage`, `addFrameCompletion`, `reportCompareStamp`). |
| `App/OutputPacer.swift` (new) | The pacer: one thread, Mach time-constraint policy, absolute deadlines (`mach_wait_until`), missed deadlines skipped not burst; `setRunning(false)` waits for a tick in flight; `cancel()` joins. C: `[PACER] … intervals 10 s: n median p99 max · missed` every 10 s and `intervals over the run` at stop. |
| `Packages/ManifoldCore/Sources/OutputPacing` (new leaf target, 5 tests) | `OutputPacerTiming.period` (the §4.4 table) and `IntervalStats` (10 µs bins; median, p99, exact max). |
| `App/DeckLink/DeckLinkService.swift` | The source's rate to the renderer, for files (`sourceFormatChanged`) and live (`liveFormatChanged`, nil when unknown). |
| `project.yml`, `Package.swift` | The `OutputPacing` product. |
| `scripts/decklink-loopback/linkpace.sh`, `linkpace-summary.py` (new) | Addition A and the post-fix wire runs (§7.8). |

Build: Profile, clean; +4 warnings, the four newly used deprecated `CVDisplayLink` calls (`BUGS.md`, *`CVDisplayLink` →
`CADisplayLink`*). `swift test` (ManifoldCore): **784 tests, 0 failures** (779 before, +5).

### 7.2 Method

Each group was one launch by binary path after `manifold-proc.sh guard`, held by PID, quit by PID, then guarded again. **Every guard was clean, and no launch was refused.** Files were opened with
`manifold-proc.sh open`; windows were moved with `AXPosition` and resized with `AXSize`. Play and Pause were AX presses, and B was made main with `AXMain` + `AXRaise`. Always Show Controls,
New Window, Close All, Start/Stop DeckLink Output and Disconnect Live Source were AX menu clicks. No keystrokes, no screenshots, no settings or
display changes. Logs used: `MANIFOLD_PLAYBACK_STATS`, `MANIFOLD_DECKLINK_CADENCE_LOG`, and `[RENDER-PERF]`, `[LINK]`, `[PACER]` and `DeckLink D3`.
**SDI was measured by the card's own results only**: late and dropped (`D3`) and the card-input classification of every pull (`[CADENCE]`; a repeat is the
same pts as the pull before, a skip is ≥ 1.5 frames on; the first second after Play is excluded). The cable downstream of the card was not
trusted tonight, and the wire was not measured. **Today's code** is `26f7794`, built from a `git archive` export in the scratchpad
with its own derived data (the gitignored `ThirdParty/` libraries and the DeckLink SDK linked in read-only). Media: the 120 fps session's
`hfr_*.mov`; and, made for this with Homebrew ffmpeg into the scratchpad, `testsrc2` + 1 kHz tone: 1080p23.976 / 59.94 / 100 /
119.88 (30 s), 2160p59.94 / 100 / 119.88 HEVC (20 s), and 1080p59.94 at 660 s for the soak.

### 7.3 §5.1 and §5.3: the window (no SDI)

| Case | Tick (median of 1 s windows, max) | Presented a second | Superseded | Late |
|---|---|---|---|---|
| 23.976, LG / ASUS | 8.33 (10.33) / **16.68 (18.69)** | 24–25 / 24 | 0 / 0 | 0 |
| 59.94, LG / ASUS | 8.33 / **16.68** | 60–61 / 60 | 0 / 0 | 0 |
| 120, LG / ASUS | 8.33 / **16.68** | 120–121 / **60** | 0 / 241 in 4 s (the rest of each second, correct) | 0 |
| 59.94 moved LG → ASUS → LG | 122 → 60 → 121 ticks a second; one long interval (33 ms) at a move | 59–61 | 1 | 0 |
| 120 moved | 121 → 60 → 120 | 120 → 60 → 120 | 153 (on the ASUS) | 0 |
| §5.3 set, LG: 48 / 60 / 72 / 96 / 100 / 119.88 / 120 / `IMG_5070.MOV` / 2160p120 | 8.33 | 49 / 60 / 72 / 97 / 101 / 107–121 / 120 / 110–112 / 121 | 0 except 119.88 (12) and `IMG_5070` (18), the 120 Hz beat as before | 0 |
| §5.3 set, ASUS | 16.68 | 48 / 57–59 / 60 / 60 / 60 / 60 / 60 / 60 / 60 | 0 / 5 / 24 / 72 / 80 / 120 / 120 / 121 / 121 | 0 |

- **No `[FRAMEQ]`, no `[FREEZE-GUARD]`, and no `[IDLE] ⚠️` silent-link line in any run.** `drawMs` max on the ASUS at 120 fps was 0.03 ms, against
  4.6 ms before the fix (§2.2): the wasted presents are gone.
- Every window logged `[LINK] … window shown` on display 3, and then one line per move, with `rc 0` every time.
- **Paused one-shots on the ASUS:** three resizes of an idle-stopped window woke it on display 4 (16.66 ms ticks); no watchdog line.
- **One −6660** came at a Close All on an idle window with no display change, and was recovered (`BUGS.md`, 2026-11-01).

### 7.4 §5.4 idle-link recovery (`MANIFOLD_IDLE_FAIL_START=1`, window on the ASUS)

- Every wake took the forced failure and recreated the link (`[IDLE] … recreated and running on display N`). On the ASUS N = **4**
  each time, and after a move to the LG while stopped N = **3**. Play then ticked at 16.69 ms (ASUS) and 8.33 ms (LG).
- With SDI running and the flag set, the pacer ticked (8.34 ms, max 8.36) and the flag never touched it. Card: late 0 / dropped 0.
- After output stopped: `[PACER] stopped … link back on display 4`. The next wake recreated the link on display 4.

### 7.5 §5.2 SDI, B and C (new build; today's code with the window on the LG for comparison)

Card-input cells are repeats / skips; late / dropped are counted while playing.

| Mode (Follow source) | Today, LG | New, LG | New, ASUS | New, moved | Pacer intervals over the run (median / p99 / max, missed) |
|---|---|---|---|---|---|
| 1080p59.94 | 0/0 · 0/0 | 0/0 · 0/0 | 0/0 · 0/0 | 0/0 · 0/0 | 8.35 / 8.36 / 8.37–8.39 ms, 0 |
| 1080p23.98 | 0/0 · 0/0 | 0/0 · 0/0 | 0/0 · 0/0 | 0/0 · 0/0 | 13.91 / 13.92 / 13.93–13.95, 0 |
| 1080p100 | 0/0 · 0/0 | 0/0 · 0/0 | 0/0 · 0/0 | 0/0 · 0/0 | 5.00 / 5.02 / 5.04 (10.00 once), 0–1 |
| 1080p119.88 | **61/61** · 0/0 | **0/0** · 0/0 | **0/0** · 0/0 | **0/0** · 0/0 | 4.18 / 4.18 / 4.19 (8.34 once), 0–1 |
| 1080p120 (B, `hfr_120`) | — (ASUS: 3/3 · 0/0) | 0/0 · 0/0 | 0/0 · 0/0 | — | 4.17 / 4.18 / 4.18–8.33, 0–1 |
| 2160p59.94 | 0/0 · 0/0 | 0/0 · 0/0 | 0/0 · 0/0 | 0/0 · 0/0 | 8.35 / 8.36 / 8.38 (16.68 once in the move), 0–1 |
| 2160p59.94, scopes open (C) | — | 0/0 · 0/0 | 0/0 · 0/0 | — | 8.35 / 8.36 / 8.37, 0 |
| 2160p119.88 | 36–69 / 402–421 · **all late** | 0–7 / 400–434 · all late | 6 / 441 · all late | 0 / 436 · all late | 4.18 / 4.18 / 8.34, 1 |
| 2160p100 | 26–185 / 195–314 · **all late** | 0–168 / 168–300 · all late | 0 / 213 · all late | 0 / 194 · all late | 5.00 / 5.02 / 5.03–15.00, 0–3 |

- **Rule 3 check:** no SDI result is worse than today's code on the LG. Every mode the card can run is 0 late / 0 dropped / 0 / 0
  on every display and across every move. At 1080p119.88 the new build is exact where today's code was not. At 2160p100 and 2160p119.88 the card
  marks every frame late on both builds. A first single-run comparison there looked worse, so both builds were rerun three times each
  (measure only, nothing tuned). The new build's counts sit within today's spread or below it (`BUGS.md`, 2026-11-01).
- **B, presents capped at the window's display:** on the ASUS (59.94 Hz) the desktop presents ran 35.7–60.0 a second in every
  mode, never above the display. On the LG they were ≤ 103 a second. The 120 fps clip on the ASUS while SDI ran at 1080p120 gave 41.4 presents a second
  (971 held for a present in flight, 676 by the rate cap), with SDI 0/0 · 0/0. **A slow drawable cannot delay the SDI convert, by
  construction:** the frame's command buffer and its convert are committed before `nextDrawable()` is called, and the gate keeps
  `nextDrawable()` from blocking. Measured: `nextDrawable()` max 0.03–2.11 ms; nil drawables 0; gate timeouts 0. From the tick's start to the frame in the SDI
  ring: median 0.4–1.3 ms, p99 ≤ 2.4 ms, max ≤ 10.2 ms. With the 2160p scopes open: p99 7.1 / 8.9 ms, max 16.4 / 10.9 ms, inside the
  18.3 ms pull margin. **The cost** is that the 120 Hz LG shows 57–103 a second of a 100 or 119.88 fps file during output (`BUGS.md`, 2026-11-01).
- **C:** every SDI run logged its 10 s lines and the whole-run line. Across about 140 000 pacer ticks, p99 was within 0.02 ms of P. The longest interval
  was one or three skipped deadlines (2 × or 3 × P), with no effect on any frame.

### 7.6 Soak and live

- **Soak:** 1080p59.94 for 600 s, window on the ASUS. Card: **36 000 completed, late 0, dropped 0**. Card input: **35 911 pulls, 0 repeats, 0
  skips**. Picture age 25.1–36.7 ms. Pacer: 72 050 intervals, median 8.35, p99 8.36, max 16.68 ms (8 missed deadlines in 10 min).
  Desktop: 59.9–60.0 presents a second; `nextDrawable()` max 0.04 ms; tick → SDI ring max 6.90 ms.
- **SRT** (non-Cloudflare: a local ffmpeg listener, `srt://127.0.0.1:9000`, dialled through `MANIFOLD_DEBUG_DIAL_URL`; no bookmark read
  or written; 1080p59.94 H.264):

  | | Window, LG | Window, ASUS | SDI 1080p59.94, LG | SDI, ASUS |
  |---|---|---|---|---|
  | Today's code | 60–61 a second, 0 superseded | — | late 0 / dropped 0; **68 repeats / 68 skips** | — |
  | New | 60–61, 0 superseded | **46–51 a second, 85 superseded in 7 s** | late 0 / dropped 0; **0 / 0** | late 0 / dropped 0; **0 / 0** |

  On the ASUS the window shows the 59.94 beat (`BUGS.md`, 2026-11-01). SDI from a live source is better than today's code: the pacer ticks
  twice per frame. SRT jitter windows reported 0 underruns on both builds.
- **NDI: not run.** NDI discovery listed no source within 15 s, on either build, from a scratch 1080p59.94 sender or from the
  2026-10-29 session's sender ("Searching for NDI sources…"). The new sender may be held by a macOS Local Network permission
  prompt, but that is not confirmed (no screenshots, no settings). The same on today's code, so it is not a result.
- **A/V sync** (Audio Hijack + the OBS recorder): **not run**, because it needs attendance.

### 7.7 Two windows (§5.5)

A played 59.94 on the LG at 8.33 ms ticks (60–61 a second) while B, paused on the ASUS, was resized twice. B's link woke on display 4 for each
resize, and A was untouched. Then B was made main (`AXMain` + `AXRaise`) and played: 16.68 ms ticks, 24–25 a second, and A paused
(the one-window-plays rule). The first attempt without making B main did not start B: an AX Play press in a window that isn't main
does nothing. That was a driver fault, not an app fault. **Not run:** an SDI owner on one display beside a second window being scrubbed on the other.

### 7.8 For tomorrow (attended)

- **A, the baseline:** Robbie makes the ASUS the main display. Then `zsh scripts/decklink-loopback/linkpace.sh fixtures` (once), then
  `linkpace.sh run <today's build> build/linkpace/mark-1080p5994-660s.mov lg 600 base-asusmain`. With the ASUS main the
  LG is the secondary display; `lg` places the window on the LG by name. Repeat on the ASUS, and with the new build.
  Today's code is built from `26f7794` (a `git archive` into any folder, its own derived data).
- **The loop:** device 0's SDI output into device 0's own SDI input (profile `1dfd`, one full-duplex sub-device, as on 2026-10-23).
  The read-only probe tonight found device 0's SDI input **locked (`4k23`)**: a cable is already on its input, apparently the loop.
  **Correction (Robbie, 2026-11-02): it was not the loop.** That input carried the Omniscope system's feed. Every "card input"
  count in §7 is the frames Manifold handed the card (`[CADENCE]` pulls), never the SDI input connector.
  Which BNCs carry device 0's output and input on the 8K Pro in `1dfd` is **UNKNOWN** from software. Use the pair from last week; the
  probe's `InputSignalLocked YES` and a `capture` that reads the marker band confirm it.
- Wire counts come from the marker band's picture number (the I2 band, progressive) via `capture --marks`: repeats, skips and pictures
  missing, beside the card's own counts and `[PACER]`.

### 7.9 2026-11-02, unattended: the wire, the 60 Hz-main baseline, and the two window fixes

Setup by Robbie: device 0's SDI output looped into its own SDI input (the Omniscope feed unplugged); the ASUS (59.936 Hz) is the MAIN
display, the LG (120 Hz) secondary. A first attempt was stopped by the guard (the installed app was running); Robbie quit it and
the runs below were made after that. Every launch: `manifold-proc.sh guard` → launch by absolute path, held by PID → quit by PID →
guard. No guard tripped. One launch by a relative path was refused by `manifold-proc.sh check` (it requires an absolute path);
that build was quit by its PID through the same terminate call the helper sends. `linkpace.sh` now makes both paths absolute.

**Builds.** Pre-fix `26f7794` and HEAD `149fd25`: `git archive` exports in `build/linkpace-src/<commit>/`, Profile, own `.build-cc`.
HEAD + `[AV-LAG]` file hook: `build/linkpace-src/149fd25-avlag/` (HEAD plus only the `MANIFOLD_AVLAG_FILE` hook below, for the
before side of the A/V measurement; the SDI runs used plain HEAD). Fix: this tree, `./.build-cc`.

**Method.** `linkpace.sh run` (SDI, Follow source) and `linkpace.sh window` (no output, `MANIFOLD_PLAYBACK_STATS=1`). The wire is
counted by the picture number in the marker band of every received frame (`capture --marks`). It is counted only up to the file's
end, because `capture` runs past `--seconds` (650–685 s for 600, about 70 s for 25), so a run can read past the end of a 30 s file. Card:
late/dropped from DeckLink D3; card input: `[CADENCE]` pulls in the file, from 1 s after Play. **Drift** is clock − card in ppm: the
file clock's advance against the host, minus the card's slots (pulls × frame duration) against the host, over the run. Its
prediction (span × drift / frame) is the number of one-frame slips a run should show from that alone.

#### Step 1, the loop: confirmed by frame numbers

HEAD, `mark-1080p2398-60s.mov`, 10 s: the input read the fixture's own picture numbers **22 → 278 in order, 257 frames, 0 unread,
0 repeats, 0 skips**. The input is device 0's own output. The probe agreed (`1dfd`, locked, detected mode = output mode).

#### Steps 2–4 and the step-5 re-runs: SDI on the wire

| Run (window) | Build | Wire repeats / skips | Card late / dropped | Card input repeats / skips | Drift (ppm) → slips predicted | Desktop presents a second |
|---|---|---|---|---|---|---|
| 1080p59.94, 600 s, ASUS (**baseline A**) | pre-fix | **192 / 193** | 0 / 0 | 192 / 193 | +19.1 → 0.7 | — |
| same | HEAD | 0 / 1 | 0 / 0 | 0 / 1 | +19.0 → 0.7 | 59.9–60.0 |
| same | fix | 0 / 4 | 0 / 1 (frame 4, before Play) | 0 / 4 | **+101.4 → 4.0** | 59.9–60.0 |
| 1080p23.98, 50 s, ASUS | HEAD / fix | 0 / 0 · 0 / 0 | 0 / 0 · 0 / 0 | 0 / 0 · 0 / 0 | +88 / +12 → 0.1 / 0.0 | 24.0 |
| 1080p59.94, 120 s, LG | HEAD / fix | 0 / 1 · 0 / 1 | 0 / 0 · 0 / 0 | 0 / 1 · 0 / 1 | +121 / +90 → 0.9 / 0.7 | 59.9–60.0 |
| 1080p59.94, 120 s, ASUS → LG → ASUS | HEAD / fix | 1 / 0 · 1 / 0 | 0 / 0 · 0 / 0 | 1 / 0 · 1 / 0 | −64 / −49 → 0.5 / 0.4 | 59.9–60.0 |
| 2160p59.94, 25 s, ASUS | HEAD / fix | **not readable**: `capture` dropped 931 / 963 frames | 0 / 0 · 0 / 0 | 0 / 0 · 0 / 0 | +62 / +65 → 0.1 | 59.9–60.0 |
| 1080p119.88, 25 s, ASUS | HEAD / fix | 0 / 0 · 0 / 0 | 0 / 0 · 0 / 0 | 0 / 0 · 0 / 0 | +48 / +58 → 0.2 | 59.9–60.0 |
| 1080p119.88, 25 s, LG | HEAD / fix | 0 / 0 · 0 / 0 | 0 / 0 · 0 / 0 | 0 / 0 · 0 / 0 | +103 / +33 → 0.3 / 0.1 | **86–92 → 119.8–119.9** |
| 1080p100, 25 s, LG (new fixture `mark-1080p100-30s.mov`) | HEAD / fix | 0 / 0 · 0 / 0 | 0 / 0 · 0 / 0 | 0 / 0 · 0 / 0 | +102 / +90 → 0.3 | **82–93 → 100.0–100.1** |

Pacer over every run: median within 0.01 ms of P, p99 within 0.02 ms, missed deadlines 0 (one, at 1080p119.88 on the LG, HEAD).

- **Baseline A (the question of addition A): pre-fix code with the 60 Hz display main repeats and skips about one frame every 3.3 s on
  the wire** (192 / 193 in 646 s), and the card reports none of it (late 0, dropped 0). HEAD removes it.
- **The remaining single slips are clock slips, not pacing.** HEAD and the fix both show them. Each comes as a lone skip, or a lone
  repeat when the card runs fast (the move runs, negative drift), with no deadline missed. Their count matches the drift predicted
  in every run. The fix 600 s run's 4 skips were 164.6 s apart, where its +101.4 ppm predicts one every 164 s. **The card's rate
  against the host was different in every output session** (−64 to +121 ppm on the same build). The file clock was at 0.0 ppm in
  all of them. Why the card's rate moves between sessions is **UNKNOWN**. Pacing to the card's clock is the 1.1 card-clock work
  (§4.5). Neither window fix is active on the SDI path in these runs: pacer ticks carry no glass time, and the second waiting
  present applies above 61 Hz only.
- **Rule check:** no SDI result is worse on the fix build except in its clock slips, and those follow the session's drift.
  Reverting would not touch that path, so neither fix was reverted. The card's one `dropped` (fix 600 s run) was frame 4,
  scheduled at output start before Play; no other run of either build had one.
- **2160p59.94 on the wire cannot be counted with `capture`:** it hashes every frame and drops about a third at 4K60. The card's own
  counts are 0 / 0 on both builds.

#### Window tick rates, ASUS main (HEAD; the fix the same within one frame a second)

| File | ASUS: tick (median, max) · presented a second · superseded | LG: tick · presented · superseded |
|---|---|---|
| 1080p23.98 | 16.68, 17.70 · 24–25 · 0 | 8.33, 9.34 · 24–26 · 0 |
| 1080p59.94 | 16.68, 17.70 · 60–61 · 0 | 8.33, 9.33 · 60–62 · 0 |
| 1080p100 | 16.68, 17.70 · 60–61 · 562 (correct: 40 a second cannot be shown) | 8.33, 9.34 · 100–102 · 0 |
| 1080p119.88 | 16.68, 17.69 · 60–61 · 841 (correct) | 8.33, 9.34 · 115–122 · 10 (fix: 120–122 · 2) |

The link follows the display with the ASUS main as it did with the LG main (§7.3): 16.68 ms on the ASUS, 8.33 ms on the LG.

#### Fix (a): live 59.94 on the 59.936 Hz display, and the A/V shift

`window`, 30 s on the ASUS (20 s on the LG), SRT from a local ffmpeg listener (`srt://127.0.0.1:9000`, 1080p59.94 + 1 kHz, dialled
through `MANIFOLD_DEBUG_DIAL_URL`; no bookmark read or written), and the 59.94 file. Before: HEAD + hook; after: the fix.

| Case | Presented a second, superseded: before → after | `[AV-LAG]` `av` median (min–max), before → after | now − pts | tick → glass |
|---|---|---|---|---|
| SRT, ASUS | **48, 60 … 60, 57 46 54 47 · 49 superseded → 60–61 every second · 0** | +45.4 (+22.4 … +69.8) → **+13.0** (+5.5 … +38.2) ms | +16.0 → −17.5 | +24.0 → +24.0 |
| SRT, LG | 60–61 · 0 → 60–61 · 0 | +29.4 (+15.5 … +53.1) → +13.3 (+1.5 … +30.8) ms | +2.9 → −7.5 | +11.6 → +11.6 |
| File 59.94, ASUS | 60–61 · 0 → 60–61 · 1 | +30.8 (+29.9 … +31.7) → +11.5 (+10.6 … +12.4) ms | +6.7 → −12.5 | +24.0 → +24.0 |

- **The beat is gone** on the ASUS. HEAD showed it at the start and the end of the 30 s, the fix in no second.
- **The A/V shift, measured in-app:** `av` is the audio heard when the picture reaches the glass, minus that picture's pts. Positive
  means the picture is behind its sound. With the fix the picture is **16–32 ms earlier against its sound**, about the tick → glass lead less
  the frame-choice margin, and sits about +12 to +13 ms behind it in every case. For the file, `audio − now` is 0 by construction
  (`MANIFOLD_AVLAG_FILE=1`: a file's clock is the synchronizer's audio timeline), so the file row measures the picture against
  that timeline, not the audio device. **The device-level check (§7.10) measured a +26.3 ms shift, inside this range.**

#### Fix (b): pacer-mode presents above 60 Hz

With output running on the LG, 1080p119.88 presented **86–92 → 119.8–119.9 a second**, and 1080p100 **82–93 → 100.0–100.1**. `nextDrawable()`
max ≤ 0.09 ms on both builds, nil drawables 0, gate timeouts 0. SDI was 0 / 0 · 0 / 0 on the wire in both. On the ASUS nothing changes
(limit 1): 119.88 presented 59.9–60.0 a second on both builds.

**Not run:** NDI, two windows, and MediaMTX WHIP/WHEP for (a). (a) was verified against the local SRT listener and a file, both
non-Cloudflare.

### 7.10 2026-11-02, attended (Robbie): device-level A/V for fix (a), and a saved stream's calibration

Shortened plan, by Robbie: the ASUS only (HEAD 149fd25, then the fix), no LG runs, no duplicate collection; the saved stream on the
fix build only. Each build was launched by its binary after `manifold-proc.sh guard`, quit by PID, and guarded again; every guard was clean.

#### Picture against sound in the window (OBS Recorder profile, `OBS_TEST_PROFILES.md`)

**Method.** The 59.94 sync clip played from a file in a window on the ASUS. The OBS Recorder (Display Capture of the ASUS and
Manifold's app audio, one clock) recorded 60 s per build. Manifold was re-picked as the audio source after each launch. A
numpy-free analyser (the Desktop `avsync.py` needs numpy, which no Python on this Mac has) found flashes from `signalstats` YAVG and
beep onsets from `silencedetect` on a 1 kHz band at the capture's own peak − 12 dB, and paired each flash with its nearest beep within 0.4 s.
**Gate, on the clip itself and `adelay` copies:** 0 → +2.7, +250 → +252.7, −120 → −117.3 ms, sd 0.0. So +2.7 ms is a constant term
of the analyser. The recordings were deleted once read.

| Build | Beep − flash, median | sd | Pairs |
|---|---|---|---|
| HEAD 149fd25 | −2.7 ms | 5.8 | 66 |
| Fix | +23.6 ms | 6.2 | 64 |
| **Shift** | **+26.3 ms: the picture is earlier against its sound** | | |

- **Only the shift is a measurement.** Each absolute figure includes the recorder's capture-chain term (the compositor, Display
  Capture's own video/audio alignment), which is UNKNOWN. The in-app prediction for this case was +19.3 ms (`[AV-LAG]`, file on the
  ASUS, §7.9) within the 16–32 ms range. The device figure is in that range and agrees in direction.

#### A saved stream's calibration on the fix build ("Local SRT" bookmark, SRT Local profile)

OBS was relaunched fresh with SRT Local (its row checked before the run) streaming SYNC. A/V ▸ Calibrate… ▸ Start ran at about 1 min,
then was Cancelled; no `APPLIED` line was logged and nothing was saved.

- **Result:** `heard A/V −45.81 ms` (10/10 pairs, p10 −46.48, p90 −45.68 ms, frame 41.708 ms) · `O 0 ms → proposed +46 ms`.
- **Where the 46 ms is:** the clip's flash pts is **+46.3 ms after its beep's pts in the stream OBS sent** (e.g. 84.8370 − 84.7907,
  86.1300 − 86.0837 s). Manifold's own part, heard − clock, was **−0.49 to −0.89 ms**. That is OBS's offset, of the same kind as the
  77–78 ms on the HEVC profiles (`BUGS.md`, OBS offset re-check).
- **So the fix does not move a calibration**, as predicted: calibration pairs flash pts with heard − clock
  (`CalibrationMode.swift`, header) and does not include the display path, which is what the fix changed. Saved offsets need no
  re-run after the update. The bookmark had no saved offset (O = 0), so no earlier value exists to compare with. An earlier SRT
  Local calibration figure was not found in `docs/`: UNKNOWN.
