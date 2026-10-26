# SDI / HDMI output timing and the window's display

Audit, 2026-10-26, measured at `9aaff2d` (the frame-due pull); committed as `d8fc945`. Question (Robbie): does DeckLink output timing depend on the
window's display, and does it matter in practice? No app code was changed for this audit. The measurement used the
DEBUG `[CADENCE]` log that ships in `9aaff2d` (pre-ship removal list) and the SDI loop.

## Verdict

**Fine except for these cases.** In every window state measured (on the 120 Hz LG, on the 60 Hz ASUS, minimised,
fully covered, on another Space, paused), at 23.98, 25 and 29.97, the card got every frame exactly once. There were
0 repeats and 0 skips at the card's input, every received picture was new on the wire, and late = 0, dropped = 0.

The exceptions are untested, not measured failures:
- **Display or system sleep during an unattended playout.** Manifold holds no power assertion, and every SDI frame
  is still produced by a render that needs the window's display link and a drawable.
- **A future or power-saving macOS** that stops giving hidden windows drawables or display-link ticks.

The cheap guard (a power and activity assertion while output runs) is worth doing before 1.0: **built 2026-10-26,
commit `<commit — to be filled in>`** (§3, Stage 0). The full decoupling (§3) is not needed for 1.0 on this evidence;
it is a 1.1 item in `BUGS.md` (*card-clock-driven DeckLink output*).

## 0. History

- **The tie dates from `1b43979` (2026-07-06)**, "DeckLink D-real: real video output — GPU RGB->2vuy convert,
  pull-latest to the card". The v210 convert was put on the render-completion push path (`onFrameRendered`): the window's
  render of a frame, on completion, converts that frame for the card. Today that call is
  `App/MetalVideoRenderer.swift:3645` (`self.pushDeckLinkConvert(sourcePts: pts)`, inside the render's
  `cmdBuffer.addCompletedHandler` at `:3621`). `git blame` gives that line to `1cce620` (2026-07-12, SDI audio, which
  added the pts argument).
- **`c9f0c97` (interlaced I1) did not touch this path.** It changed neither `App/MetalVideoRenderer.swift` nor anything
  under `App/DeckLink/`.
- **`ca4d868` (interlaced I2) touched what the convert does, not what drives it**: `setDeckLinkSourceInterlaced`, the
  `interlaced:` argument to `SDIPlacement.fit` inside `pushDeckLinkConvert`, and identity vertical taps in the scaler for
  a fields-kept placement. The trigger (render completion) and the hand-off are unchanged.
- **`9aaff2d`** changed the hand-off: a ring of 4 converted frames and the frame-due pull (§1). The convert is still
  driven by the render.

## 1. The path today

| Step | Where | Driven by |
|---|---|---|
| Decode | `FrameEngine` reader pumps → `onVideoFrame` (`App/WindowDeck.swift:1054`) → `MetalVideoRenderer.enqueue` (`:2745`), a pts-sorted queue | the decode pumps (background queues), paced by the renderer's readiness |
| Source clock | `AVSampleBufferRenderSynchronizer` (`FrameEngine.swift:284`); the renderer's `clock` is `engine.currentSyncTime()` (`WindowDeck.swift:1048`) | host clock × rate |
| Frame choice | `displayTick` (`MetalVideoRenderer.swift:2910`): newest queued frame with pts ≤ `clock()` (`:3097`, `:3107`) | **the window's `CVDisplayLink`**, created on the active displays (`:2884`) and never moved: it ticks at the main display's rate (the LG, 120 Hz) even with the window on the ASUS. Stopped while paused and idle (`:737`), woken by `wakeDisplayLink` (`:630`) |
| Render | `renderPixelBuffer` (`:3357`): offscreen render, then `metalLayer.nextDrawable()` (`:3552`) in the SAME command buffer | display tick. **If `nextDrawable()` returns nil, the whole command buffer is dropped, offscreen render included** |
| v210 convert | render completion (`:3621`) → `pushDeckLinkConvert` (`:4357`) into a free ring slot (`:4373`), published with its pts and signal (`:4457`, `:4581`); one convert in flight | the render's GPU completion, so the display tick |
| Hand-off | the card's `ScheduledFrameCompleted` (`DeckLinkBridge.mm:665`) refills the completed frame through the fill block (`DeckLinkService.swift:908`) → `copyLatestDeckLinkFrame` (`:4632`) → `deckLinkPullSlotLocked` (`:4655`), and schedules it 4 frames ahead (`DeckLinkBridge.mm:696`; preroll of 4, `:369`, `StartScheduledPlayback`, `:382`) | **the card's clock** |
| Which frame (`9aaff2d`) | a file playing at rate 1: the newest ring frame due at least the margin (median display tick + 10 ms) before the slot's time on the source clock, from a slot timeline; never older than the frame handed last; ±2 ms hysteresis. Paused, stepping, seeking, shuttle, live: the newest frame. Pause catches up one frame per pull | card clock + source clock; the margin from the display tick (`noteDeckLinkTick`, `:2911`) |
| SDI audio | `RenderAudioSamples` (`DeckLinkBridge.mm:513`), the card's audio callback, keeps 200 ms queued (`:273`) and schedules with `ScheduleAudioSamples` (`:733`). It anchors to the source pts of the frame handed to the card (`currentDeckLinkSourcePts`, `MetalVideoRenderer.swift:4603`, via `DeckLinkService.swift:1051`), corrected for the audio and video queue depths, steering by ≤ 2 samples per callback | the card's audio clock, anchored to the handed frame |

So **the card's timing is the card's**: scheduling, completions and audio never wait on the window. **What the card
is fed depends on the window's render loop**: every frame reaches the ring only if the window's display link ticks and
`nextDrawable()` returns a drawable. The `9aaff2d` frame-due queue removes the phase dependence between the render loop
and the card (the repeat-then-skip). It does not remove the dependence on the render loop happening at all.

## 2. Measurements

Build: `9aaff2d`, Profile. Files: ProRes HQ `testsrc2`, 1080p at 24000/1001, 25 and 30000/1001 (fresh, no audio).
Output: Follow source (1080p23.98 / 25 / 29.97). For each condition: open, place, start output, Play, apply the
condition, wait 3 s, then 12 s measured through the SDI loop (`capture`, full-frame FNV per received frame) and the
`[CADENCE]` log. The window's on-screen state came from the window server's flag (no image). The SDI loop was still
connected (both inputs detected the output); the probe read SDI after every run. Driver and summaries:
`build/token-step/timing.py`, `tim.py`, `build/token-step/timing/summary.txt`.

| Condition | Window on screen | 23.98 | 25 | 29.97 |
|---|---|---|---|---|
| LG 120 Hz | yes | 0 rep / 0 skip; 310 / 310 new | 0 / 0; 322 / 322 | 0 / 0; 386 / 386 |
| ASUS 60 Hz | yes | 0 / 0; 310 / 310 | 0 / 0; 322 / 322 | 0 / 0; 387 / 387 |
| Minimised | **no** | 0 / 0; 310 / 310 | 0 / 0; 322 / 322 | 0 / 0; 387 / 387 (and 388 / 388 in a rerun) |
| Covered by a Finder window | listed, fully hidden | 0 / 0; 309 / 309 | 0 / 0; 322 / 322 | 0 / 0; 387 / 387 |
| Another Space (full screen, Finder active) | **no** | 0 / 0; 311 / 311 | 0 / 0; 322 / 322 | 0 / 0; 386 / 386 |
| Paused | yes | one picture, held: 1 / 310 changed | 1 / 324 | 1 / 388 |

Cells: repeats / skips at the card's input (every pull classified), then pictures that changed / frames received on the
wire. **late = 0, dropped = 0 in all 20 runs.** The window's renderer presented 24.0 / 25.0 / 30.0 fps in every
playing case, minimised and other-Space included. The display link ticked every 8.33 ms (max 9.65) in every case,
**on the ASUS too**: the link stays on the LG.

- **Long minimised run**, 29.97, 162 s: 54.8 s of playback, 0 repeats and 0 skips, then the file ended (Loop off) and
  its last frame held. The window renderer stayed at 30 fps throughout.
- **Latency** (picture age at the card's pull: source clock − handed pts; the card shows a pulled frame 4 slots later):
  between 18.1 and 53.8 ms across runs. Each run is one Play start, and the age is set by the phase at Play, within
  [margin, margin + one frame]: 18.3–60 ms at 23.98, 18.3–51.7 at 29.97. No condition moved it outside that band;
  there are too few starts per condition to compare means.
- **Live source:** none available locally (no NDI or SRT sender running; OBS is an attended step, CLAUDE.md). Not
  measured. Live sources use the newest-frame pull, the same render-driven feed.

**Not measured, and why it matters:**
- **Display sleep.** Here `displaysleep` is 0 (never), so it cannot happen on this Mac. With macOS defaults (10 min) a
  long unattended playout would reach it. Manifold holds no `PreventUserIdleDisplaySleep`: `pmset -g assertions` during
  playback showed none from Manifold. Whether the display link and `nextDrawable()` keep going with the displays asleep is
  **UNKNOWN**. If they stop, SDI freezes on the last frame while the card keeps running.
- **System sleep.** `sleep 1` here, prevented only incidentally by coreaudiod (the Scarlett's audio context). On a Mac
  without that, idle sleep would stop output. Manifold holds no `PreventUserIdleSystemSleep` either.
- **App Nap.** Manifold does not opt out (no `beginActivity`, no `NSAppSleepDisabled`). These test files have no audio,
  and the minimised run showed no throttling over 162 s. Longer hidden runs were not tried.
- **A 60 Hz main display.** The margin follows the display tick: 26.7 ms at 60 Hz, so +8.3 ms more SDI latency than on
  the LG. Not run, because the LG is main.

## 3. If a case fails: the decoupled design, and a cheap guard first

**Stage 0, cheap guard (recommended before 1.0):** while DeckLink output runs, hold
`ProcessInfo.beginActivity([.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason:)`. That keeps the
displays and the Mac awake and opts out of App Nap and timer coalescing for the output's duration. End it when output
stops. It touches `DeckLinkService` only. Risk: low (the displays stay on during output, which is the intent). Verify
with `pmset -g assertions` and a playout past the display-sleep timeout on a Mac with defaults.

**Stage 0, built 2026-10-26** (commit `<commit — to be filled in>`; predictions `build/token-step/predictions-stage0.md`):
`DeckLinkService.outputActivity`, owned by `isOutputting`'s observer, which every start and end of output already moves on
main. `pmset -g assertions` (`build/token-step/power/`): none at launch or with a file open; two while output runs
(`PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep`, named "Manifold is sending video to a DeckLink output");
none after the Stop button, closing the owning window, a device switch to DeckLink 8K Pro (2) (which refused the mode, so
the restart failed and released it), a forced failed start (`MANIFOLD_DECKLINK_ENABLE_HR`), and Quit (process gone). A
device switch that stays running could not be made on this card (only (1) outputs in its profile). A `[POWER]` line logs
each begin and end. The 20-file export set is byte-identical to `d8fc945`; `swift test` 626 / 626; warnings the same 11.
**Not yet tested:** a playout past a display-sleep timeout (this Mac's is "never").

**The full fix (only if a case above is shown to fail, or for 1.1):** the card's clock requests the frame due for each
slot, and the same conversion code runs off-screen, independent of the window.
- **What it touches.** A render-for-output path in `MetalVideoRenderer` that encodes the existing offscreen pass and the
  existing v210 kernels into a command buffer with no drawable. The colour state, placement, scaler and kernels stay as
  they are. It is driven from the card's completion callback (or a card-clock timer) with "the frame due at slot n",
  chosen from the decode queue by the same rule `9aaff2d` applies to the ring. The window keeps its own render for
  display only.
- **Risks:**
  - **GPU work doubles while the window is visible** (two renders per frame); at 4K this needs measuring.
  - **Paused-frame priming** (`primeDeckLinkFrame`) and **seek renders** need the same off-screen entry.
  - **Live sources' clocks** (`LiveClock`, NDI's `pictureDelay`) must be readable on the card's thread.
  - **The scopes** read the window's offscreen ring and must not start reading the output's.
  - **SDI audio's anchor** becomes the output render's pts (it is already the handed pts).
  - **The frame-queue consumption** is shared: the window's tick removes frames as it consumes them (`:3132`), so the
    output path needs its own cursor or a non-consuming read.
- **Staged plan:**
  1. Split `renderPixelBuffer` into an offscreen pass and a present pass, with the drawable acquired only for the
     present. A nil drawable then no longer drops the offscreen render or the SDI convert. This alone removes the
     drawable dependence, with no new thread. Verify that exports and v210 stay byte-identical and the window is
     unchanged.
  2. A non-consuming frame read for the output (the queue keeps frames until both consumers pass them).
  3. Drive the output render from the card's clock for files (frame due at slot n), keeping the `9aaff2d` ring as the
     fallback. Measure every condition in §2, plus display sleep, 4K and 60 Hz main.
  4. Live sources, verified on a non-Cloudflare server (CLAUDE.md).
