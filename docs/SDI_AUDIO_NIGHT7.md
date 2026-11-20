# SDI sound faults on night 7 (2026-11-20): cause, history, gate gap

Read-only investigation, 2026-11-20. No build, no launch, no code change; git used read-only. The night is `CARD_PULL_MARGIN.md` §20.
Log paths are relative to `~/Code/_scratch/manifold-pacerphase-ab6/` unless another folder is named. The candidate binary is
`.build-pacerphase-5`, Profile, 0.9.4 (27), from `e80dc2b` (§20). "0.9.4" below means the release commit `fbb67a8`, and "0.9.3"
means `5d36795`. The unified log was read with `/usr/bin/log show` for 04:50–04:53, read only. Scripts written for this are in the
session scratchpad and are not kept. What they count is described where they are used.

## Verdicts

| | (a) Block 5 `bon-2`: the card's audio callbacks stop | (b) GOP block: 65 s missing after a seek while playing |
|---|---|---|
| **Cause** | The DeckLink SDK's audio callback thread stopped running `RenderAudioSamples`. Either the SDK stopped calling it, or one call never returned from a driver call. Which of the two is UNKNOWN. Not Manifold's AVFoundation path, not a default-output change, not System Events. | **Found.** Stage 2 started the Mac sound's clock on a picture line made of two *pre-seek* frames, so the clock jumped 186.6 s ahead. The pump fed the renderer up to the old position, then the slip correction put the clock back. The renderer, holding 186 s of future sound, never asked for more, so the tap stopped at 1166.805 s and the bridge read nothing for 978–1043 s. It was not a read limit. |
| **Matches a known fault?** | **No, it is new.** It is the opposite of the silent start, and it is not the default-output stall (comparison below). | **No, it is new as an outcome.** Its trigger, a stale provisional latch after a seek while playing, is routine since 0.9.3. |
| **Regression?** | No evidence of one. It is the first occurrence in every soak log since 0.9.3, and the audio paths are unchanged since 0.9.4. With 1 occurrence, a rare pre-existing fault cannot be told from a new one. | **No.** The code is unchanged since 0.9.3, and the trigger occurred at the same rate before C+. |
| **Related to B or C+?** | Not by any path found. 1 in 10 B-on SDI blocks, 0 in B-off blocks, so it cannot be excluded statistically. | No. The stale-slot pattern is the same with and without C+. |
| **Severity** | **High.** 55 min of SDI picture without sound, no recovery while the output ran, and nothing tells the user. It fails the gate's "0 unrecovered events" in substance. | **Medium.** 65 s of SDI silence after an ordinary seek, recovered by the next seek only. Rare, but it could recur at any seek while playing on a file whose seeks leave stale frames (GOP, audio-only seen). |
| **Proposed fix** | 1. Instrument the callback so the next occurrence names its side. 2. Add a watchdog that restarts the whole output, bounded, as the silent-start recovery does. 3. Put the question to Blackmagic. | 1. Stage 2 rejects a start line that puts the sound more than 1 s past its parked content, and waits for the next line. 2. Any jump of the sound's clock beyond the pump's look-ahead re-reads the sound from the new time, as the flush fix does. |

---

## (a) Block 5: the card's audio callbacks stopped at 04:51:38

### What the log shows

- The last `[SDI-AUDIO] runs:` line is `n7-5994-sdi-bon-2.log:78387`: in a run, 11 latches, missing 1,741 samples, gate open. From `:78876`
  (frame 20112) to `:865481` (frame 218736), the bridge logs `!! no audio callback in the last 48 frames … callbacks 16722, audio
  buffered 0, queue end 16052313` every 48 frames, 4,139 times. The count of callbacks, the queue end and the missing count never move
  again. The stop summary reads `audio callbacks 16722`, `missing 1741 samples` (`:865583` region).
- Over the same frames the video completion callback ran every frame: `DeckLink D3: frame 218736 — completed=218733 late=0 dropped=0`.
  The stop sequence completed normally: `ScheduledPlaybackHasStopped 0.8 ms after StopScheduledPlayback`, then the final black frame, then
  `DeckLinkAudio: stopped … underruns=3 … shortSchedules=0`.
- The bridge made 0 latches after the stall. Latches are made inside the audio callback (`processSlots`, called from `renderRuns`), so
  the Stage 2 starts that followed had no SDI picture line. That is why the block shows 10 `Stage 2: Mac sound starts` lines against
  105 on every other 59.94 block (counted with a scratch script).

### What the counter means

`m_audioCallbacks` is incremented on the first line of `RenderAudioSamples` (`App/DeckLink/DeckLinkBridge.mm:766-767`), before any
early return. A frozen count therefore means no call **entered** the callback. A call that took the early exits (not running, the
start's try-lock at `:771-772`, silence) would still have counted. That leaves two cases:

1. **The SDK stopped calling.** The DeckLink audio callback thread is serial, so a stopped thread is one stall for all later calls.
2. **One call entered and never returned.** Then the counter would read the last call's increment, and the serial thread is stuck
   inside it.

The log cannot tell these apart. What was checked, to see whether case 2 could be Manifold's own code:

- **Every lock the callback can take was taken by other threads after 04:51:38, so none was held forever:**
  - `cardAudioLock` (`FrameEngine.swift:2066-2069`, through the `isSilent` closure, `DeckLinkService.swift:1386-1395`): written on
    every Play and Pause, and there were 57 Plays after the stall.
  - `destinationLock` (`DeckLinkService.swift:505-508`).
  - The renderer's `deckLinkLock` (`MetalVideoRenderer.swift:6114-6141`, through `sourceTime` and `handed`): taken by the card pull
    every frame, and the pull ran to the end.
  - `m_handedLock` (`DeckLinkBridge.mm:1307`, `:1698`, `:1933`): taken by the video thread.
  - The tap's ring (the `read` closure): the tap went on writing (`AudioTap[AVF]` lines to the end of the block).
- **Every loop on the runs path is bounded:** the 1 ms coarse search and the one-sample back-step at `DeckLinkBridge.mm:1395-1410`
  (the `while` at `:1408` stops at `hit - 47`), and the prefetch-ring loop over `[lo, hi)`.
- **The remaining candidates are SDK calls** made from the callback: `GetBufferedAudioSampleFrameCount`, `GetScheduledStreamTime`,
  `ScheduleAudioSamples` (always non-blocking, with `sampleFramesWritten` set, `:1063-1065`), and `FlushBufferedAudioSamples` in
  `rewriteFrom`. The video thread's `GetBufferedAudioSampleFrameCount` in the diagnostic kept returning (0), so that call was not
  blocked for everyone.

So if it was case 2, it was blocked in the driver, not in our code (inference). Either way the stall is on the card's side of the API.

### Comparison with the two known faults (Robbie, 2026-11-20)

| | Default-output stall (`BUGS.md` 4242; `CARD_CLOCK_FINDINGS.md` §10.13, §10.17, §10.19) | Silent start (`BLACKMAGIC_SILENT_START.md`) | Night 7 (a) |
|---|---|---|---|
| Layer | AVFoundation: the renderer stops calling the pump's `requestMediaDataWhenReady` block | Card: the audio queue is accepted but never consumed | Card SDK: the audio callback stops |
| Card's audio callbacks | Keep coming (they serve zeros, and missing samples climb) | **Keep coming**, about 600 in 12 s | **Stop** (count frozen at 16,722) |
| Card's buffered audio | Kept topped up | **Frozen at the preroll's count** (nothing consumed) | **Drained to 0** (the card consumed it) |
| Missing samples (bridge) | Climb about 48,000/s | n/a (the queue is full) | Frozen at 1,741 (no callback to count them) |
| When | Within 0.6–1.4 s of a default-output change | At an output start only | Mid-session, about 6 s after a loop wrap's re-latch (`:77008-77049`) |
| Condition | A default-output change (`[AUDIO-FLUSH]` posted) | Same sub-device's SDI input open at the start | Capture closed (rig check, `soak.out:120`); default output Scarlett |
| Recovered by | A seek (before the fix); since `daa09cb`, the re-read on the flush | A full stop and start of the output | Nothing seen; 57 Plays and their seeks did not help |
| On night 7 | 0 `[AUDIO-FLUSH]` lines in the block; no device change in the unified log | Not possible as written: no output start at 04:51 and the input was closed | — |

**Verdict: new.** It shares only "card side, picture fine" with the silent start, and its two observable signatures, callbacks and
buffer, are the reverse. It is not the default-output stall:
- **The fix for the stall is committed** as `daa09cb` "fix(audio): resume feeding after an automatic renderer flush, so SDI audio
  survives a default-output change", 2026-11-10. It is in 0.9.3 and 0.9.4 (`git merge-base --is-ancestor`), and live at
  `FrameEngine.swift:704` (observer), `:1069` (`readSoundAgain`) and `:1123` (`[AUDIO-FLUSH]`). The heading of `BUGS.md` 4242 still reads
  "FIX BUILT …, UNCOMMITTED". That is stale and is a correction for a session in this repo. Not made here.
- **The block logged 0 `[AUDIO-FLUSH]` lines.** The fix logs one line at every automatic flush in every configuration.
- **Manifold's AVFoundation audio was alive after the stall.** coremedia `subaq_enqueueAQBufferIntoAudioQueue` lines from Manifold ran
  at 04:51:34–37 and at 198, 201 and 204 per 20 s at 04:55, 05:20 and 05:45 (unified log).

### The unified log at 04:51

- **No default-output or device change** between 04:50 and 04:53. No line names a default device, and none from Blackmagic, DeckLink or
  Desktop Video, apart from runningboardd's periodic process listings that name the Blackmagic camera extension and updater. coreaudiod
  logged only its periodic RTAID RMS report (04:51:28.651, 04:51:38.645), usbaudiod its microframe lines.
- **System Events** (pid 7550) ran `terminate:` at 04:51:37.158; launchd cleaned up at 37.162 and loginwindow logged `applicationQuit`
  at 37.166–37.168. FolderActionsDispatcher exited at 04:51:40.172. As §20.4 found, System Events exits about 6 min into every block
  (6 of 6), and the stall happened once.
- Manifold's own unified-log lines from 04:51:36 to 04:51:41 are coremedia only (video queue and audio queue statistics).
- **Is anything in our audio path woken by System Events or an AX client exiting?** No path found. Nothing in `App/` or
  `Packages/*/Sources` observes `NSWorkspace` launch or terminate notifications, or registers an `AXObserver` (grep for
  `didTerminateApplicationNotification`, `didLaunchApplicationNotification`, `AXObserver`, `AXIsProcessTrusted`: no hits). The card's
  audio callback runs on the SDK's thread and reads only the closures listed above. The callbacks stopped at about 04:51:38. The last
  `runs` line is about 04:51:37, it is written once per second of stream, and the `!!` line at frame 20112 says none came in the
  previous 48 frames (0.8 s). So the stop fell between about 04:51:37 and 04:51:38.5, within about 1 s after System Events exited. That
  is coincident to the second, but the same exit was harmless 5 times. **Coincidence cannot be excluded, and no mechanism is known.**

### Regression or pre-existing

- **Logs searched:** `manifold-rc-soak` (0.9.3), `manifold-rc094-soak` (0.9.4), `manifold-cardpull-s1`, `-s1r`, `manifold-pacerphase-ab`,
  `-ab3`, `-ab4`, `-ab5`, `-ab6`, `manifold-plainb-lg`, and the folders with no runs path (`manifold-1c-wire`, `-chapters`, `-run`,
  `-scopes095`, `-soak`).
  - `no audio callback`: **0 lines anywhere but night 7's block 5**, which has 4,139.
  - Every soak above has the runs path. Since the diagnostic may postdate some builds, a second signature was also checked: the longest
    run of `DeckLink D3: frame` lines (one per 48 frames) with no `[SDI-AUDIO] runs:` line inside one output session. Every SDI block
    since 0.9.3 has at most 2 (about 96 frames, at output start). Block 5 has 4,141.
- **Code diff from 0.9.4 to `e80dc2b`** (`git diff fbb67a8 e80dc2b`):
  - `App/DeckLink/DeckLinkBridge.mm`: 3 lines, moving `#include <os/lock.h>` out of `#if DEBUG` (the Release compile fix, `a6f541c`). No
    behaviour change.
  - `App/DeckLink/DeckLinkService.swift`: 3 lines, `MANIFOLD_DECKLINK_CADENCE_LOG=2` accepted as well as `1`. Log only.
  - `FrameEngine.swift`: 85 lines, all start timecode (`setFileTimecode`, `refreshTimecode`, the override), chapter-metadata removal and
    the `frameRouteDecided` subject. No audio, pump, flush, Stage 2 or tap line.
  - `AudioTapBuffer.swift`, `CardClock/*`, `LiveAudioResample/*`, `App/HLS/*`: unchanged.
  - `MetalVideoRenderer.swift` (721 lines; C+, B, present timing): adds C+ pacer-lead bookkeeping inside the pull's `deckLinkLock`
    (`notePacerLeadPullLocked`). The two functions the audio callback calls, `currentDeckLinkHanded` and `currentDeckLinkSourcePts`
    (`:6114`, `:6135`), are unchanged.
- **Verdict:** first occurrence. Nothing in the changed code reaches the card's audio thread. Regression: no evidence. With 1 event,
  that is all the data can say.

### Related to B or C+?

No path found. B changes the window's present path and C+ the pacer's phase (`CARD_PULL_MARGIN.md` §17-§19). Neither touches the SDK's
audio thread. C+'s only shared state with it is the `deckLinkLock`, and that was not held (above). Tally: 1 stall in the 10 B-on SDI
blocks of nights 5–7 against 0 in the B-off SDI blocks of nights 5–6 and in every C+-off soak. C+ ran in every block of nights 5–7, so
C+ is confounded with B-on there. One event cannot separate B, C+ or chance.

### Proposed fix (not built)

1. **Name the side next time.** Two counters around `RenderAudioSamples`, entered (`:767`, existing) and returned (new, at every return),
   plus a one-byte "stage" marker written before each SDK call in `renderRuns` (`GetBufferedAudioSampleFrameCount`,
   `GetScheduledStreamTime`, `ScheduleAudioSamples`, `FlushBufferedAudioSamples`). On the first `no audio callback` line of a session,
   print entered, returned, stage, `GetScheduledStreamTime` and `IsScheduledPlaybackRunning`, once. If entered ≠ returned, the call is
   stuck in the named SDK call. Optional, soak driver only: on that line, `sample <pid> 3` into the soak folder.
2. **Recover.** If no callback enters for 2 consecutive 48-frame checks (≈ 1.6 s at 59.94) while the output runs with audio enabled, restart
   the whole output through the existing silent-start restart (`[SDI-AUDIO] !! output start … restarting the whole output`, §10.24
   recovery), with its own log line, for example `[SDI-AUDIO] !! audio callback stopped … restarting the whole output`. A visible picture
   restart is better than 55 min of silence (the silent start's trade, `BLACKMAGIC_SILENT_START.md` "What we tried"). If the stuck call is
   inside the SDK, `stop()` may block in `SetAudioCallback(NULL)` or `DisableAudioOutput` (`DeckLinkBridge.mm:640-668`). Run the restart
   on the service queue with a bound, and log a stop that does not return.
3. **Ask Blackmagic,** as a seventh question to the open report: the audio callback stopping mid-session with video running, input
   closed, 16.4 driver. Wait for the instrumented occurrence first, so the question names entered/returned.
4. **Repeat with B off.** Re-run 59.94 SDI blocks with plain B off (C+ only) to separate B.

---

## (b) GOP block: 65 s of SDI sound missing after a seek while playing

### The sequence (`n7-gop25-sdi-bon.log`)

| Line | What |
|---|---|
| `:5674` | `[TRANSPORT] seek 978.16 … clock 1165.028234`, while playing |
| `:5675` | `[CARDLOCK-RESAMPLE] session END`: the seek moves the audio renderer (Stage 1b). On the move's end, `FrameEngine.swift:1003-1009` parks the sound's clock at the picture's time (978.16) and sets `stage2Pending = (slot: -1, …)` |
| `:5680` | `run end (untimed pull) at slot 1447 … source 1165.040000` |
| `:5687` | `latch #2 (first slot that moved, provisional): line from slot 1448 pts 1164.880000`: a **pre-seek** frame still being handed |
| `:5693` | `picture line #2: φ 1106.960000 s from slot 1448 (pts 1164.920000 at slot 1449)`: a **second** pre-seek frame moved, so a picture line is confirmed **on pre-seek content** |
| `:5694` | `[CARDLOCK] Stage 2: Mac sound starts 186606.2 ms into the SDI picture's run (its content was on the wire already; line #2)` |
| `:5692-5892` | The tap is filled from 979.008 s to **1166.805 s** within a few card slots (118 `AudioTap` lines; `held≈384000f`, an 8 s ring) |
| `:5744` | `latch #3 … pts 978.240000`: the seek's frame reaches slot 1450 |
| `:5904` | `[CARDLOCK] Mac sound re-anchored to the SDI picture at its new line #3 (a slip): it was +186718.57 ms off at content 978.330` |
| `:5892` → `:12970` | **No tap write**: the last is pts 1166.805 at `:5892`, the next is after the seek to 1895 (`:12973`) |
| `:5936-10658`, `:10787-12890` | Missing samples rise about 48,000 per second: 45 s to the Pause (`:10587`), then 20 s more after Play (`:10752`) to the Pause at `:12859` |
| `:12970` | `seek 1895.00`: the reader restarts, the tap and the bridge are back in step |

### The mechanism, in code

1. **Stage 2 takes the first matched line after the pending slot.** `stage2ResolvePending` (`FrameEngine.swift:1221-1273`) requires
   `line.matched, line.firstSlot > p.slot` (`:1242`). After a renderer move, `p.slot` is −1 (`:1009`), so **any** matched line
   qualifies, including one built from frames handed before the seek. (After a Play from a stop, `p.slot` is the newest card slot,
   `:1139`.)
2. **It then starts the sound at that line's wire time for the parked content.** `m0 = box.contentTime(atOutputTime: out0)` = 978.16
   (`:1252`); `stage2WireHost(content: m0)` on line #2 (φ 1106.96) puts 978.16 186.6 s in the past (`:1253`). The "late" branch then
   moves the clock forward by the whole lateness: `setRate(1, time: out0 + late, …)` (`:1265-1271`). Nothing bounds `late`. The
   sound's clock is now at ≈ 1164.8 s.
3. **The pump fills to the clock.** The renderer drops everything enqueued behind its clock and stays ready, so the file pump reads and
   enqueues as fast as it can (`isReadyForMoreMediaData` loop, `:1693`). Every buffer also goes into the tap, through 978 → 1166.8 s.
   The tap's ring keeps only the last 8 s (1158.8–1166.8). The pump stops at the clock plus its usual look-ahead: 1166.805 − 1165.03 ≈ 1.8 s.
4. **The slip correction moves the clock back but leaves the renderer's queue.** Line #3 arrives with a new serial, `slip` is true, and
   `|e|` = 186.7 s exceeds `slipBound` (1 ms, `CardClockStage2.swift:36`), so the sound's clock is set to line #3's time ≈ 978.3 s
   (`FrameEngine.swift:1323-1345`). This is `setRate` only: no flush, no re-read. The renderer now holds sound for ≈ 1163–1166.8 s
   against a clock at 978 s. It does not ask for more until its clock reaches that content, which would take about 185 s of play
   (inference). So the pump never runs and the tap never gets 978 s onward.
5. **The bridge reads the tap at the picture's time** (978–1043 s), which the ring does not hold, so every sample is missing.
   Pause/Play (`:10587`, `:10752`) only re-parks and restarts the clock (`setTransportRate`, `:1131-1142`; latch #4, Stage 2 at 1023.12 s):
   the renderer's queue is still ahead, so the pump stays idle. A seek flushes and re-reads, which is why `:12970` recovered.

So it was not a read limit. The reader was re-armed correctly at 978.16 (`FrameEngine: reading from 978.16s (audio reader: true)`,
`:5677`). The pump's pacing was driven by a clock moved 186.6 s forward on a stale line and then back.

**Whether the Mac's own sound was affected:** the renderer's clock sat 186 s ahead for about 0.6 s (`:5694` to `:5904`), and after the
slip the renderer held sound it would not play. With destination SDI the renderer is muted, so nothing was heard. With destination
Computer or "both", the Mac would have been silent or wrong (inference; Stage 2 runs only under card lock with SDI output).

### Why only once: two stale *moving* slots

A picture line needs two consecutive slots that moved. After a seek while playing, the queue still hands pre-seek frames for a few slots.
In earlier logs these stale slots include at most one *moving* frame before the seek's frame. Line #2 was then confirmed on new
content, and Stage 2 started correctly. Night 1's block (`manifold-pacerphase-ab/ab-gop25-sdi-on.log:5674-5700`, the same script
position) is an example: one stale slot at 1449, the seek's frame at 1450, line #2 at 1288.76, Stage 2 "20.8 ms from now". Night 7's
seek left two moving pre-seek frames (slots 1448, 1449).

- **Stale first latches after a seek while playing** (first latch more than 2 s from the target) occur on the GOP and audio-only blocks of
  every soak since 0.9.3. Per block: `rc-soak` ao48 4; `rc094` ao48 7, gop25 3; `cardpull-s1` gop25 7; `-s1r` gop25 6; `ab` gop25 8 and 6,
  identity gop25 4; `ab3` gop25 4; night 7 gop25 2. None on any 59.94 picture block.
- **A picture line confirmed on stale content after a seek:** **1 in all soaks**, at night 7's `:5674`. The 23.976 compare blocks are
  excluded because they are at a rate mismatch and have no matched line.
- **A Stage 2 start more than 1 s "into the SDI picture's run", or a slip larger than 1 s:** 1 each in all soaks, both this event
  (`:5694`, `:5904`).
- **Missing samples:** no other SDI block since 0.9.3 has more than about 5,100 missing in one second, or more than 1 s in a row at
  4,800/s or more (`runs` line deltas). This block has 49,034/s for a 45 s streak.

### Regression or pre-existing

**Pre-existing.** The code involved dates from `31bca732` (2026-11-13: the slot −1 pending, the late-start branch) and `537a3516`
(2026-11-14: the start guards). Both are in 0.9.3, and none of it changed from 0.9.4 to `e80dc2b` (the diff above). The trigger,
stale latches after a seek while playing, is present at a similar rate in the 0.9.3 and 0.9.4 soaks. Night 7 is the first time the
stale frames formed a line before the seek's frame arrived.

### Related to B or C+?

No. The number of slots between a seek's run end and its first latch on new content, on the GOP blocks, is the same before C+
(night 1 `ab-gop25-sdi-on`: 0:7, 1:9, 2:4, 3:1; `rc094` gop25: 0:5, 1:13, 2:3) and under C+ with B (night 7: 0:8, 1:10, 2:2, 3:1). B and C+
change when frames are pulled and presented, not which frames the queue holds at a seek (inference). GOP SDI was run under C+ only on
night 7, so 1 block is all the C+ evidence.

### Proposed fix (not built)

1. **Do not start on a line that contradicts the parked content.** In `stage2ResolvePending`, a start whose `late` exceeds a bound (1 s is
   far above any real late start: of the 44 late starts in every soak log, all but this one are at most 378.9 ms) is not a late start. It means the line belongs
   to other content. Leave `stage2Pending` set, log it once (for example `[CARDLOCK] Stage 2: line #N is not this content (… s late);
   waiting for the next line`), and let the next line or the existing `startTimeout` (`startWithPicture`) start it. Optionally, the
   bridge could also refuse to confirm a picture line from slots handed before the seek (by hand sequence). That is more invasive, and
   the bound alone covers it.
2. **Never leave the renderer's queue ahead of a moved clock.** Any jump of the sound's clock larger than the pump's look-ahead (≈ 2 s)
   should go through `readSoundAgain(from:)` (`FrameEngine.swift:1069`), as the default-output flush does. That covers a Stage 2 late start
   past the bound, a slip or coarse re-anchor (`:1323-1345`), and the mismatch re-anchor. The pump and tap then restart from the new
   time. This covers causes not yet seen too.
3. **A unit test** for item 1: a pending start after a renderer move (slot −1) given a matched line whose wire time for `m0` is 186 s
   past must not call `setRate`.

---

## Gate gap: an SDI-sound continuity check for `rc-soak-report.py` (specification, not built)

Today the script's unrecovered count is `unrecovered freezes + unrecovered silent starts + renderer GAVE UP + silent-start recovery
dropped` (`scripts/decklink-loopback/rc-soak-report.py:167`). Silent starts come only from `!! output start` lines (`:67-75`), and the
`no audio callback` line is only tallied by kind (`:76-78`). Neither night-7 fault reaches the gate.

**Scope:** blocks whose log contains `[SDI-AUDIO] runs path entered` (a file's sound on the card's timeline). A block without it (output
off, `noaudio`, a live source) is reported `n/a` and judged by nothing below.

**Check 1: audio callback stopped (catches (a)).**
- **Event:** an `[SDI-AUDIO] !! no audio callback in the last 48 frames` line while the output runs. Consecutive lines in one output
  session (no `DeckLink D3: stopped` between them) are one event.
- **Recovered:** if, within 10 s of wall time (by the nearest `[CADENCE] host`, or 600 D3 frames when no host is near), the same output
  session logs a new `[SDI-AUDIO] runs:` line, or an output restart logs `output start: the card's sound started with its picture`.
- **Duration:** the frames from the first `!!` line to recovery, or to the session's stop, with the frame index from the line itself.
- **Gate:** an unrecovered event adds 1 to `unrecovered`. A recovered event is reported with its duration and does not fail the gate
  (as recovered silent starts today).
- **Backstop for builds or paths without the diagnostic:** more than 5 consecutive `DeckLink D3: frame` lines with no `[SDI-AUDIO] runs:`
  line inside one output session is the same event. Since 0.9.3 the maximum is 2, at output start.

**Check 2: sustained missing sound while playing (catches (b), and the default-output stall if it ever returns).**
- **Input:** the cumulative `missing N samples` field of consecutive `[SDI-AUDIO] runs:` lines in one output session (reset at
  `[SDI-AUDIO] stopped`). Each line is about 1 s of stream. Delta = this line's minus the previous.
- **Exclusions:** lines with `gate silent`, and lines within `EXCL` (1.0 s) after a `[TRANSPORT] play`, `seek`, `loop` or `step` (the
  first ~100 ms of a seek decode late and are filled in later). Use the nearest preceding `[CADENCE] host` as each line's time.
- **Event:** 3 or more consecutive non-excluded lines with delta ≥ 4,800 at 48 kHz (≥ 0.1 s missing per second; scale with the rate), **or**
  any single line with delta ≥ 24,000 (0.5 s). Since 0.9.3 no block has exceeded 5,069 in one line or had 2 consecutive lines at ≥ 4,800.
  Night 7's GOP block has 49,034 with a 45-line streak.
- **Recovered:** the streak ends while the same Play continues (a delta under 4,800 with no seek, Pause or output stop in between).
  **Unrecovered:** it ends only at a seek, a Pause or an output stop, or runs to the end of the session. (b) is unrecovered under this
  rule: it outlived a Pause and Play and ended only at a seek.
- **Gate:** an unrecovered event adds 1 to `unrecovered`. Report every event with its start line, duration and total samples.

**Check 3: Stage 2 sanity (catches (b)'s cause directly, cheap).**
- `[CARDLOCK] Stage 2: Mac sound starts X ms into the SDI picture's run` with X > 1,000, or `re-anchored … it was ±Y ms off` with
  |Y| > 1,000. Report every one. Gate: count it as an event that does not fail on its own, since check 2 judges the outcome. A
  stricter `RIG.md` may fail on it.

**Output:** one line per block, for example `SDI sound continuity: callback stops 1 (unrecovered 1, 198,624 frames), missing-sound streaks 1
(unrecovered 1, 65 s, 3,060,000 samples), Stage 2 starts > 1 s 1`. The `== GATE` line adds `SDI sound unrecovered N` to its sum.
`ab-check.py` reads the same totals for G.

**Re-run on night 7, by hand (expected):** block 5 is check 1, unrecovered, and the GOP block is check 2, unrecovered. G becomes **FAIL**
with `unrecovered 2`. Every earlier soak stays as it was (0 events by the scans above). Confirm by running the built check over
`manifold-rc-soak` … `-ab6`.

---

## Corrections for a session in this repo (not made here)

**Status 2026-11-20 (later):** made. The `BUGS.md` heading is corrected, (a) and (b) have entries with their fixes (built, uncommitted,
not yet soaked), and the gate checks are in `rc-soak-report.py` and `Manifold-BUILD.md`. The fixes differ from the proposals above in two
ways. The watchdog restarts after 3 s, not 1.6 s. Stage 2 refuses a line more than 1 s off in either direction, and refuses corrections
too.

- `BUGS.md` 4242 heading: "FIX BUILT 2026-11-10, VERIFIED UNATTENDED, UNCOMMITTED" → committed as `daa09cb` (2026-11-10), in 0.9.3. The
  "still to do" item (an attended check that the Mac's own output follows the new default device) is separate and is not answered here.
- `CARD_PULL_MARGIN.md` §20.4, GOP paragraph: "Inference: after this seek, the tap kept its pre-seek read limit" → the cause is Stage 2
  starting on a stale picture line, then the slip leaving the renderer's queue ahead of its clock (this document, (b)).
- New `BUGS.md` entries for (a) and (b), with the fixes proposed above.
