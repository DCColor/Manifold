# Card clock findings: what the SDI slip fix must be designed around

**Result in brief (2026-11-06).**

- **The slips are real, and rarer than §7.9 implied.** Left alone, this card runs at −11.67 ppm against the host, steady, and a file with
  sound follows the Mac's audio device at about +5.9 ppm. That is +17.6 ppm apart: one skip every 948 s at 59.94, measured 947 s.
- **§7.9's "the card's rate differs per session" was caused by the measurement.** `capture` opening the card's input on the loop moves
  the card's output clock, to a different value each time, up to about ±125 ppm. When it closes, the card returns to −11.7.
- **The file clock follows the audio device,** even with destination SDI, where that device is muted and nobody hears it.

**Step 2, the plan (2026-11-06): §10.** Nothing in it is built.

Sections 1–9 are step 1 of the card-clock investigation: **measure only**. No fix and no design there. The bug is `BUGS.md`, *SDI from a file slips
one frame whenever the card's clock and the file clock drift a frame apart*, moved into 1.0 as the top priority (Robbie,
2026-11-05). Earlier work: `DISPLAY_LINK_PER_WINDOW_PLAN.md` §7.9 (the method and the first numbers) and §4.5 (the card-clock
direction).

**Sign convention.** §7.9 reports drift as clock − card. Here each clock is reported against the host, in ppm, positive when it
runs fast. So §7.9's "+101.4" is card −101.4 ppm with the file clock at 0.0.

## 1. Predictions, written 2026-11-05 before any run

From reading the code and the §7.9 logs only. Nothing below was measured when it was written.

What the code says going in:

- `audioRenderer` is added to the synchronizer in `FrameEngine.init` (`FrameEngine.swift:629` at `8411699`) and never removed. The SDI
  destination only mutes it (`applyAudioMute`, `FrameEngine.swift:881` at `8411699`). So an audio renderer **is attached with destination SDI**.
- Nothing sets `audioOutputDeviceUniqueID`, so the renderer plays to the system default output: the Scarlett on this Mac.
- The linkpace fixtures have no audio track, but the same renderer was attached to their synchronizer too.
- `[CADENCE] completion … done 1321503832 (timescale 60000)` in `build/linkpace/fix-asus.log` is 22025.06 s, which is the host
  uptime at that line. So the "card's own" completion timestamp looks like a value on the **host** timebase.

**Q1. Which clock does the file clock follow?**

- P1a. With an audio track and destination Computer on the Scarlett, the file clock follows the Scarlett: file vs host within 2 ppm
  of the device's own sample clock vs host, and not 0.0.
- P1b. On the built-in output, the file clock also follows the device, but the built-in's clock reads about 0 ppm against the host
  (same crystal, assumed), so that run alone cannot separate "host" from "device".
- P1c. With destination SDI, the muted renderer still drives the timebase: file vs host reads the default device (Scarlett), the
  same as P1a.
- P1d. The no-audio fixtures read 0.0 ppm, as in §7.9, whichever device is the default.
- P1e. The card's rate does not depend on the destination.

**Q2. Is the card's rate stable within a session?** P2: yes. Per-minute values within ±3 ppm of the session mean after the first
minutes, with at most a slow warm-up trend. Basis: the 4 skips of §7.9's 600 s run were evenly spaced (164.6 s).

**Q3. Why does the card's rate vary between sessions?**

- P3a. No reference is connected: reference not locked in every session, so reference does not explain the spread.
- P3b. The spread is real and not a short-run artefact, because the 600 s runs' slips matched it.
- P3c. The rate changes at an output start, so it changes across a stop/start within one launch as much as across a fresh launch.
  A free-running crystal does not move 185 ppm, so the cause would be how the output clock is set up at enable. That mechanism is
  a guess.

**Q4. Is the measurement sound?** P4: (a) pulls × frame duration over host time and (b) completion timestamps over host time agree
within 2 ppm on runs of 5 minutes or more. If `done` is a host-timebase stamp of each frame, they are close to the same measurement,
so agreement would prove less than it appears to. The hardware reference clock is logged as a third reading.

**Wire.** P5: each run's repeats and skips match span × (file − card) / frame to within one slip, repeats when the card runs fast
against the file clock and skips when it runs slow.

**Added 2026-11-06, after the first runs and before the runs they predict.** In 24 output starts with no `capture` running the card read
−11.5 to −11.9 ppm; with `capture` it had read −125 to +95. Those runs also differed in length, so the cause was not yet shown.

- P6. Within one output session, the card reads about −11.7 ppm before `capture` opens the input, moves to another value while it is
  open, and returns to about −11.7 ppm after it closes.
- P7. A 1900 s session with no `capture` holds about −11.7 ppm, and the slips still happen, at the true drift: destination SDI on the
  Scarlett gives file +5.8 − card −11.7 = +17.5 ppm, about 2 skips at the card's input over 1900 s.

## 2. Method

**Build.** This tree at `8411699` plus the hooks below, Profile, `./.build-cc`, with `OTHER_SWIFT_FLAGS='$(inherited) -DMANIFOLD_CARDCLOCK'`.
Every launch: `manifold-proc.sh guard` → launch by absolute path, held by PID → quit by PID → guard. AX clicks on named items only.

**Hardware.** DeckLink 8K Pro, profile `1dfd`, device 0's SDI output looped to its SDI input as in §7.9. Scarlett 18i20 connected and the
system default output; built-in is Mac Studio Speakers. All Mac devices at 48 kHz. Window on the ASUS.

**Fixtures** (`cardclock-fixtures.sh`, `build/cardclock/`). The linkpace marker band, ProRes 422 Proxy, 48 kHz 24-bit PCM stereo tone at
−30 dBFS: 1080p59.94 and 1080p23.976 at 720 s, 1080p59.94 at 2000 s for Q2, and video-only copies of the 720 s pair. The band was
read back from a ProRes sample before use (pictures 5 and 300 exact). It is 16 bits, so it wraps at 65536; the summary unwraps it.

**Readings** (`cardclock.sh`, `cardclock-summary.py`). Each rate is a least-squares slope against the host over the session's playing span,
in ppm:

| Reading | Source |
|---|---|
| file | `[CADENCE]` `clock` |
| card (a) | pulls × frame duration, `[CADENCE]` index: §7.9's method |
| card (b) | completed frames × frame duration over `GetFrameCompletionReferenceTimestamp`, once a second. The SDK manual (§2.5.3.30): "locked to the system clock" |
| card (c) | `GetHardwareReferenceClock`, once a second. The SDK manual (§2.5.3.29): "locked to the rate at which the DeckLink hardware is outputting frames" |
| device | `devclock`: an IOProc on the device that writes nothing, sample time ÷ 48000 from its `inNow` timestamp |
| reference | `[CARDCLOCK-REF]` at each output start and once a minute: `GetReferenceStatus`, has-input, locked, mode, flags, input lock, clock adjustment, temperature |
| wire | `capture --marks`: repeats and skips by picture number, as §7.9 |

**Audio routing, without touching system state.** The destination is a launch argument (`-manifold.decklink.audioDestination`, argument
domain), so no defaults key is written. The built-in is named to the renderer by `MANIFOLD_CARDCLOCK_AUDIO_DEVICE_UID`, so the system
default output stays the Scarlett; the driver refuses the run unless the app logs the device read-back.

**Check of the method on saved logs, before any run.** §7.9's `fix-asus` reproduced from its log: card −101.2 ppm, file 0.0 (§7.9: +101.4).

**Runs.** 2026-11-05 22:48 to 2026-11-06 02:55, 34 launches, 48 output sessions, all guarded, no guard tripped, `/Applications/Manifold.app` not
run. Logs and per-session JSON: `build/cardclock/` (gitignored). The installed app was running at the first guard check, so nothing launched
until Robbie had quit it. One stop: Q2's `capture` overran past the file's end, so there was no Pause button. Its data was complete and the driver now
allows for it. `.build-cc` still holds the measurement build.

## 3. Q1: which clock does the file clock follow?

**Answer: the audio renderer's output device. With no audio track, the host.** Ten-minute runs, ppm against the host, with `capture` running, so
the card column is a capture value (§6):

| Run | File | Device | Card (c) | Drift → slips predicted | Wire repeats / skips |
|---|---|---|---|---|---|
| 59.94, no audio track | +0.00 | +5.51 | +95.06 | -95.1 → 3.9 | 4 / 0 |
| 59.94, Computer, built-in | +4.79 | +4.79 | +58.24 | -53.4 → 2.2 | 2 / 0 |
| 59.94, Computer, Scarlett | +5.54 | +5.54 | +86.92 | -81.4 → 3.4 | 3 / 0 |
| 59.94, SDI (default device Scarlett) | +5.62 | +5.62 | +40.82 | -35.2 → 1.5 | 1 / 0 |
| 59.94, SDI, renderer named to built-in (300 s) | +5.15 | +5.15 | -20.95 | +26.0 → 0.5 | 0 / 1 |
| 23.976, no audio track | -0.00 | +5.77 | +3.08 | -3.1 → 0.1 | 0 / 0 |
| 23.976, Computer, built-in | +5.25 | +5.25 | -86.71 | +92.0 → 1.5 | 0 / 2 |
| 23.976, Computer, Scarlett | +6.01 | +6.01 | -0.98 | +7.0 → 0.1 | 0 / 0 |
| 23.976, SDI (default device Scarlett) | +5.92 | +5.92 | -124.52 | +130.4 → 2.2 | 0 / 3 |

- **With sound, file = device** to within 0.02 ppm in every run of 5 minutes or more (except `q3-l1`, below), on both devices and both rates. Over the 30 s runs, within 0.26 ppm.
- **The device is the one the renderer is told to use, even muted.** The 300 s SDI run with the renderer named to the built-in followed the built-in.
- **Audio renderer with destination SDI: yes, attached.** `audioRenderer` joins the synchronizer in `FrameEngine.init` and is never removed; SDI
  only mutes it (`applyAudioMute`). So in the default destination the picture is timed by a Mac device playing nothing audible.
- **Without an audio track:** 0.00 ppm, on the host, while the Scarlett read +5.5 and +5.8 in the same runs.

**The exception: one launch in 32 with sound sat on the host.** `q3-l1` read file +0.00 in both its sessions while the Scarlett read +5.6, with the same
fixture, destination and device as its neighbours. The 16 fresh launches run to look for it (8 SDI, 8 Computer) all followed the device. The app's
log shows no difference. Its cause is UNKNOWN. That launch started about 14 s after Q2's stopped run; nothing shows that is related.

## 4. Q2: is the card's rate stable within a session?

**Answer: yes.** Measured two ways. Left alone (`p7`, 1900 s, no `capture`): per-minute card (c) −11.81 to −11.35 ppm, sd 0.09, temperature 63–64 °C.
With `capture` open (`q2`, 2000 s at 59.94; this is the run the question asked for, and its level of −67 is a capture value, §6):

| Minute | Card (a) | Card (b) | Card (c) |
|---|---|---|---|
| 0 | -66.96 | -67.67 | -67.67 |
| 1 | -67.86 | -67.75 | -67.74 |
| 2 | -67.04 | -67.41 | -67.42 |
| 3 | -67.46 | -67.35 | -67.35 |
| 5 | -67.51 | -67.28 | -67.28 |
| 10 | -67.17 | -67.06 | -67.06 |
| 15 | -67.20 | -67.26 | -67.25 |
| 20 | -67.06 | -67.04 | -67.04 |
| 25 | -67.35 | -67.28 | -67.28 |
| 30 | -67.35 | -67.12 | -67.12 |
| 32 | -67.30 | -67.06 | -67.06 |

After the first two minutes, card (c) stayed within −67.43 to −66.96 ppm (sd 0.12), with the card at 63–65 °C. Eight skips against 8.7 predicted, 13,744–13,792 frames
apart, where +72.7 ppm predicts about 13,760. No drift with time. Temperature hardly moved in any run (61–65 °C), so a temperature effect is not excluded, only not seen.

## 5. Q3: why does the card's rate vary between sessions?

**Answer: because of `capture`, not reference, temperature or the session itself.** Reference state was identical in all 299 reads across every run: `GetReferenceStatus` 0x0
(unlocked), has a reference input, not locked, mode unknown (`iunk`), clock adjustment 0. No reference is connected. `bmdDeckLinkConfigReferenceOutputMode` returned
0x80000001, so it is not read on this card: **which reference mode the output uses is UNKNOWN** beyond "not locked to any".

59.94, 5 minutes each, destination SDI, with `capture`:

| Launch | Session | Reference status | Locked | Card (c) | File | Wire repeats / skips | Predicted |
|---|---|---|---|---|---|---|---|
| 1 | fresh launch | 0x0 | no | -102.13 | +0.00 | 0 / 1 | 2.0 |
| 1 | stop/start | 0x0 | no | +84.16 | +0.00 | 2 / 0 | 1.7 |
| 2 | fresh launch | 0x0 | no | +6.72 | +5.61 | 0 / 0 | 0.0 |
| 2 | stop/start | 0x0 | no | +88.22 | +5.61 | 2 / 0 | 1.7 |
| 3 | fresh launch | 0x0 | no | +13.21 | +5.58 | 0 / 0 | 0.2 |
| 3 | stop/start | 0x0 | no | +79.29 | +5.57 | 1 / 0 | 1.5 |
| 4 | fresh launch | 0x0 | no | +52.62 | +5.63 | 1 / 0 | 1.0 |
| 4 | stop/start | 0x0 | no | +47.35 | +5.46 | 1 / 0 | 0.9 |

These swing by up to 186 ppm inside one launch. Then, with no `capture`:

| Sessions, no `capture` | n | Card (c), ppm |
|---|---|---|
| Fresh launch, destination SDI, 30 s | 8 | −11.71 to −11.45 |
| Fresh launch, destination Computer, 30 s | 8 | −11.80 to −11.59 |
| Stop/start in one launch, 30 s | 8 | −11.87 to −11.51 |
| 1900 s | 1 | −11.67 |

**Direct test (P6).** One output session, 30 s without `capture`, then with, then without, four times:

| Session | Before | `capture` open | After |
|---|---|---|---|
| 1 | −11.96 | +74.31 | −11.61 |
| 2 | −11.57 | −75.90 | −11.57 |
| 3 | −11.82 | −38.53 | −12.09 |
| 4 | −11.89 | −44.29 | −11.96 |

The saved Q1–Q3 logs show the same: about −11.7 for the first 3–4 s of every session, then a step within 1–2 s of `capture` starting.

## 6. Q4: is the measurement sound?

**Answer: the arithmetic is sound; the setup was not.** All sessions carried all three readings:

| Session | Span (s) | (a) pulls | (b) completion | (c) hardware clock | (a) − (c) |
|---|---|---|---|---|---|
| p7-s1 | 1900 | -11.66 | -11.67 | -11.67 | +0.01 |
| q1-2398-sdi-s1 | 692 | -124.52 | -124.52 | -124.52 | -0.00 |
| q1-5994-sdi-s1 | 689 | +40.80 | +40.82 | +40.82 | -0.02 |
| q2-s1 | 1999 | -67.18 | -67.18 | -67.18 | -0.00 |
| q3-l1-s2 | 343 | +84.06 | +84.16 | +84.16 | -0.10 |
| q3-l4-s1 | 344 | +52.64 | +52.62 | +52.62 | +0.02 |

- (a) and (c) agree within 0.10 ppm on every session of 5 minutes or more. (b) and (c) within 0.03 ppm on all 48. At 30 s (a) reads up to 1.9 ppm off, from callback jitter.
- **Which to trust:** (c) or (b) for anything short; (a) is good from about 5 minutes. All three are against the host, so they share any host error.
  The independent check is the slip count, and that agrees.
- **What failed is §7.9's assumption that `capture` is a passive observer.** It changes the rate it was there to measure. Wire counts are still correct as frame
  identity, but a run with `capture` does not show the rate a customer's output runs at.
- **Use pulls when the rate matters.** Wire and card-input counts were identical in all 23 sessions with both, so `[CADENCE]` pulls count slips with the input closed.

**Wire check (P5).** All 23 sessions with `capture`: repeats plus skips within one of the prediction, and always the predicted direction. With no `capture`, `p7`: 2 skips at the card's input
at 575 s and 1522 s, 947 s apart, against 2.0 predicted and 948 s. Card late 0 in all 48 sessions; dropped 1 in three of them, each frame 4, scheduled before Play, as in §7.9.

## 7. What held and what did not

| Prediction | Result |
|---|---|
| P1a Scarlett: file follows device | **Held** |
| P1b built-in: file follows device, device about 0 ppm | **Half.** Follows it, but the built-in read +4.8 to +5.3 (and +1.9 in the 69 s smoke run), not 0, so it did separate host from device |
| P1c SDI: muted renderer still drives the clock | **Held**, in 31 of 32 launches with sound counting all destinations (§3) |
| P1d no audio: 0.0 ppm | **Held** |
| P1e card rate does not depend on destination | **Held** |
| P2 stable within ±3 ppm | **Held**, ±0.3 |
| P3a reference not locked, not the cause | **Held** |
| P3b the spread is real, not an artefact | **Did not hold.** The card really did run at those rates, but `capture` caused them |
| P3c the rate changes at output start | **Did not hold.** It changes when the input opens |
| P4 (a) and (b) within 2 ppm | **Held**, 0.10 |
| P5 slips match drift | **Held** |
| P6, P7 | **Held** |

## 8. What this means for the design

This is what the design has to answer, not the design.

- **Make the card the master while output runs.** It is the one clock the wire cannot disagree with, and left alone it holds to about ±0.2 ppm. Pacing from it removes the drift whatever the rate is.
- **Destination SDI: nothing is lost.** The sound on the wire is already anchored to the staged video on the card. The Mac device only times the picture while muted, and that is the whole cause of the +5.9 ppm part of the drift here.
- **Destination Computer is the real decision.** Two hardware clocks run about 17.6 ppm apart here, about 1 ms a minute. With the card as master, either Mac audio is pulled to the card (`AUDIO_RESAMPLER_DESIGN.md` is the place to start) or sound and picture part slowly. Keeping the Mac device as master means slips stay. Robbie's decision.
- **No constants.** −11.67 and +5.9 are this card, this Mac and one night. They must be read at run time, and the design must also survive the rate stepping: this card moved by up to about 115 ppm within 2 s.
- **Removing the audio device from the timing alone is not a fix.** With no audio track the file clock is on the host and the card still drifts, 11.7 ppm here: one slip every 1430 s at 59.94.
- **How to verify the fix:** count pulls with the input closed for the true rate. Run `capture` as well, as a stress test: it gives ±125 ppm on demand.

How often a customer sees this today, at these rates: 59.94 with sound, every 16 minutes; 23.976 with sound, every 39 minutes; 59.94 with no sound, every 24 minutes. On a
different card or Mac the figures will differ. The direction here is a skip, as the card runs slow against the file.

## 9. Unknown

- **How `capture` moves the output clock.** Whether it needs the loop, or any open input does it, is UNKNOWN. Needs the loop cable out, or a second signal: attended.
- **Whether Manifold or a customer can trigger it.** A card with its input in use by another app, on or off the loop, was not tested.
- **Why `q3-l1`'s file clock sat on the host,** and how often that happens beyond 1 in 32.
- **A genlocked card.** No reference is connected, so a locked card's rate and behaviour were not measured.
- **Absolute rates.** Everything is against the host, whose own error is unknown. The Scarlett and the built-in both near +5 could partly be the host.
- **The built-in at +1.9 ppm** in the 69 s smoke run against +4.8 to +5.3 later. One short run; not explained.
- **Rate across days, cold starts, other modes, other cards.** One night, 1080p59.94 and 1080p23.976 only, card at 61–65 °C.
- **Why `capture` overruns `--seconds`** (300 → about 345, 1800 → 2069). Harmless here, not investigated.

## 10. The plan: the card as master clock during file playback

Step 2, written 2026-11-06. **Plan only: nothing here is built.** Line numbers are this working tree (HEAD `b2b765b` plus the uncommitted measurement hooks).

Decided (Robbie, 2026-11-06): while DeckLink output runs during file playback, the card is the master clock. Destination SDI: the muted Mac renderer stops timing the picture.
Destination Computer: option A, the Mac audio follows the card, resampled. No constants tuned to this card or Mac; the rate is measured continuously; a step within about 2 s and a genlocked
card must work the same way. Output off: file playback unchanged.

**The plan in brief.**

- **Picture.** While output runs, the audio renderer leaves the engine's `synchronizer`, which then runs on the host clock with nothing else attached. Once a second that synchronizer is
  written onto the card's line with `setRate(_:time:atHostTime:)`, using a card completion stamp as the host time. Every reader of the file clock stays as it is. I call this state **card lock**.
- **Mac audio.** The audio renderer moves to a second synchronizer that runs at rate 1 on its device, and the live resampler bends the audio to the picture clock, as it does for a stream.
- **SDI audio.** Still original samples from the tap. It needs one fix of its own, because today it is not sample-continuous (§10.3).
- **Output off:** none of this exists. The second synchronizer is not created and the pump closures are today's.

### 10.1 Driving the file clock from the card

**What AVFoundation allows.** The header settles the first two rows; the rest come from two standalone probes run today (the real `AVSampleBufferRenderSynchronizer`,
`AVSampleBufferAudioRenderer` and a display layer's video renderer; renderer muted, video renderer unfed, Scarlett the default device, no Manifold, no card). Sources in
`~/Code/_scratch/manifold-cardclock-probe/`, kept until Stage 1 is built.

| Question | Answer |
|---|---|
| Can the synchronizer be given a custom clock or timebase? | **No.** `timebase` is read-only (`AVSampleBufferRenderSynchronizer.h`). `AVSampleBufferDisplayLayer.controlTimebase` is settable, but the audio renderer has no equivalent |
| Which clock does it use with no audio renderer? | The host clock (header) |
| Can the audio renderer leave a running synchronizer? | **Yes**, completion after 48 ms. Clock +6.41 → −0.01 ppm. **The clock loses 47.8 ms** at the removal |
| Can it come back? | **Yes**, the clock returns to the device (+6.2 ppm). The clock loses 64.6 ms |
| Can a second synchronizer hold it? | **Yes.** At the same time: audio's +6.24 ppm, picture's −0.00 ppm. Writes to the picture's do not reach it (+6.01 ppm) |
| Does a renderer on no synchronizer consume? | **No.** 0 buffers taken in 50 s, so the pump stalls |
| Bare `synchronizer.rate = r`, no audio attached | **Loses time:** 80–145 µs per write |
| `setRate(r, time:atHostTime:)`, host time ahead by L | **The clock stops for about L on every write:** 18 ms at a 20 ms lead, 5.05 ms at 5 ms. Not what the header describes |
| Same, host time now | On the line, median 0.2 µs, one excursion of −513 µs in 20 writes |
| **Same, host time 5 ms or 50 ms in the past** | **On the line:** median 0.2 µs, all within ±65 µs including sampling jitter, no stop |
| `setRate(r, time:)` | About 170 µs behind the line, no stop |
| Both synchronizers paused and resumed at one host time | Their relation held to about 10 µs |

`rate` is a `Float`, so its step is 0.06 ppm below 1.0 and 0.12 ppm above. The position written every second makes that irrelevant.

**The options.**

| Option | What it costs | Verdict |
|---|---|---|
| A. Steer the rate with the audio renderer attached | Every write mutes for 50–60 ms (`LIVECLOCK_AUDIO_MIRROR_FINDINGS.md` §11.11), so it cannot serve destination Computer. On SDI the mute is inaudible, but the device stays under the picture, which the decision rules out | No |
| **B. Audio renderer off; steer the picture's synchronizer, now on the host clock** | Costs a second synchronizer, and the 48/65 ms clock loss when the renderer moves (§10.2). Writes are free: no renderer to mute. All readers unchanged: `renderer.clock`, `isPausedNow`, the end-of-file observer, decode pacing, the pull | **Recommended** |
| C. A card clock object in place of `renderer.clock`, as `LiveClock` does, with the synchronizer left on the device | The synchronizer still paces decode through the video renderer's readiness (`FileFrameSource.swift:114`, `LibavFrameSource.swift:476`) and still drives end of file. The picture and the decode pace would part by 1 ms a minute with no bound. Two sources of truth in 20 file-side rate sites | No |
| D. A timebase steered from completions, handed to the synchronizer | Not available: read-only | No |
| E. Address frames by slot (`SDI_OUTPUT_TIMING.md` §3, stages 1–3) | Fixes the wire but still needs a clock for decode, audio and the window. Large: split render, second cursor, up to twice the GPU work at 4K | Stays 1.1; compatible with B |

**How B works.**

- **Reading.** `ScheduledFrameCompleted` (`DeckLinkBridge.mm:729`) publishes one sample per frame: the slot count `n` and `GetFrameCompletionReferenceTimestamp`, a host-axis stamp. This is reading (b) of §6: a
  stamped pair with no read jitter, 0.03 ppm from the hardware clock on all 48 sessions. Card time is `n` × the mode's frame duration, as an exact rational.
- **Latch.** At the first sample after the clock starts at 1×, `φ = clock − card time`, held constant. Any transport move ends the run and the next run re-latches. So the loop needs no pts and no knowledge of the file.
- **Write, once a second.** Rate from a least-squares fit over the last 2 s of samples; then `setRate(rate, time: cardTime(n) + φ, atHostTime: stamp(n))`, with `n` the newest sample at least 5 ms old.
  The host time is always in the past, which is the one form the probe found exact.
- **No constants from this card.** The 2 s window and the 1 s tick come from the stated step requirement. Nothing holds a ppm value. A genlocked card is the same code: it reports a different line.
- **The pull does not change.** `deckLinkPullSlotLocked` (`MetalVideoRenderer.swift:5521`) reads the clock. With the clock on the card, `target` advances one card frame per slot, so it can no longer cross a frame's due
  time. The 2 ms hysteresis only ever sees wobble.

**Replay on saved data.** This law run over all 48 sessions' stamps (1 Hz, so a coarser fit than the real one), capture's rate steps included, rate rounded to `Float`: error at the next tick median 4.4 µs, p99 45 µs,
**max 169 µs**, against 2 ms of hysteresis and an 8.34 ms frame at 119.88. This is arithmetic on real stamps, not a run of the code.

### 10.2 Mac audio under option A

**Does the live resampler fit? Most of it, unchanged.**

| Piece | Fits? |
|---|---|
| `PolyphaseResampler` | **Yes, as is.** Ratio changes are free by construction; 1.84 % of a core at 16 channels |
| `LiveAudioResampleStage` | **Yes, as is**, one per audio arm. Same contract: CMSampleBuffer in, contiguous output axis out, `inputTime(atOutputTime:)` for the content heard now |
| `LiveAudioResampleController` | **Yes, as is**, `.adopted` gains. Pure function, so its state outlives an arm |
| `LiveAudioResampleSteering` (1747 lines) | **No.** Its bulk serves things a file does not have: first-anchor gates, Sender Reports, splices for LiveClock's position moves, the starvation hold, user offset. A file's position moves already rebuild the arm. A small new class in the same module reads the pair and calls the controller. Its pure core is what is reused |
| `LiveAudioSink` | **No.** It pushes; file pumps are pulled. The stage goes in the pump's `enqueue` closure instead |

**Where it sits.** After the tap, before the renderer, as in live: the AVFoundation pump's `enqueue:` closure (`FrameEngine.swift:4362-4366`) and libav's `onAudioFrame` (`FrameEngine.swift:2718`). `TapLookaheadPump` already ingests at decode time and enqueues
separately, so the tap sees original samples on the content axis with no change. The closure is chosen when the arm is built, so output off runs today's closures and no shared path gains a branch. `AUDIO_RESAMPLER_DESIGN.md` §1.3 ("a file cannot reach it") and
the "Mac audio device ↔ DeckLink card: nothing" row of §4.2 are superseded for this one case and get amended at Stage 2.

**How it is steered.** As live (§2.1): `e = stage.inputTime(atOutputTime: audioSynchronizer.currentTime()) − synchronizer.currentTime()`, a paired read, discarded if the pair takes over 200 µs. `ρ` from the controller, per input buffer. The target is
the picture clock, so the audio inherits the card through it and has no second measurement of the card.

**The one difference from live is the delay.** An unmuted file renderer sits 1.2–1.6 s ahead of the playhead (§19.12), against 0.25 s live, so a change of `ρ` is heard later. Simulated with the adopted law, 1.6 s of delay, one update per 171 ms buffer, even or in the
muted renderer's bursts: start-up drift nulled to under 0.2 ms; a 115 ppm step peaks at 1.0 ms and is back within 0.2 ms in 69 s; a 250 ppm step peaks at 2.2 ms. That is a simulation, and those steps come only from `capture`. At the true +17.6 ppm the ratio is 0.03 cents.

**The audio synchronizer.** Rate 1 on the device clock, on the resampler's output axis, created at card lock and released after it. In steady play nothing writes to it, so nothing mutes. Both destinations use this path while card lock is on, and the renderer
stays muted for SDI as today. So a destination flip stays a mute flip, with no move and no rate write (§4.5 measured that a muted renderer keeps advancing).

Today's 20 file-side `synchronizer.rate` / `setRate` sites go through one transport setter, which also moves the audio synchronizer while card lock is on. `delaysRateChangeUntilHasSufficientMediaData` is set false on the audio synchronizer, or the two could start apart.

| Event | Picture clock | Audio synchronizer | Stage and controller |
|---|---|---|---|
| Play | Starts as today; lock latches at the first sample | Starts at the same host time, future-dated, which is harmless from a stop. One position write in the first second, inside the start mute today already has | Run |
| Pause | Rate 0, no lock writes | Rate 0 at the same host time | Held, queue kept |
| Seek, frame step, scrub release, loop wrap | `beginReading` as today, lock re-latches | Re-anchored for the new arm | Stage retired with the arm (`teardownAudioReading`, `FrameEngine.swift:4264`); `coarseEvent`: filter reset, **integrator held**, so no re-acquisition |
| Scrub drag | As today, no lock writes | Rate 0 | Held |
| Shuttle ≠ 1× | Rate as today, no lock writes | Same rate; muted as today | `ρ` held, loop paused |
| Reverse jog | Rate 0, as today | Rate 0 | Held |
| Track switch | Untouched, as today | One position write: the new stage's axis starts on content time | New stage, integrator held |
| Output start | Renderer moves off. **Clock loses about 48 ms** if playing | Created, renderer added, audio rebuilt by the track-switch route | Built |
| Output stop | Renderer moves back. **Clock loses about 65 ms** if playing; back on the device | Released | Destroyed |
| Audio device change | Unaffected | Clock changes under it | `outputConfigurationDidChange` rebuilds the arm; the loop absorbs the new rate |

The output start and stop losses are a one-off hold in the window of 3–4 frames at 59.94. At a start the wire has no programme yet; at a stop it has ended. Paused, nothing shows. No correction is written, because jumping forward would be a skip.

### 10.3 SDI audio

**What stays.** The tap keeps source samples on the source axis; nothing resampled reaches the card (`AUDIO_RESAMPLER_DESIGN.md` §4.2 still holds). The card callback (`RenderAudioSamples`, `DeckLinkBridge.mm:575`) tops up its buffer by the card's own consumption, and audio and video are
scheduled on one stream clock from one `StartScheduledPlayback`. So picture and sound leave on the same oscillator: at 59.94, exactly 800.8 samples per frame.

**That holds only if the read cursor advances one sample per sample scheduled. Today it does not, and this is a new finding.** The anchor loop (`DeckLinkBridge.mm:633-660`) steers the cursor toward the staged frame's pts with skips and repeats of up to 2 samples per callback, about 50 times a second. The comment
says a settled loop applies nothing, but its dead band is 104 µs and the pts staircase leaves about ±1 ms in the smoothed error, so it never settles. From the saved logs, once-a-second reads after the first 20 s:

| Run | Reads | Correction not zero | Smoothed error after 100 s |
|---|---|---|---|
| `p7`, 59.94, 1900 s | 1860 | 84 % (±1 or ±2 samples) | sd 1.0 ms |
| `q1-5994-sdi` | 665 | 87 % | |
| `q1-2398-sdi` | 664 | 85 % | |

The clocks need 0.84 samples a second; the loop moves tens. **Also at Play:** `p7` reads −84 ms 4 s after Play and takes 44 s to come inside 1 ms, crawling at the loop's 2 ms/s. Five card frames of queue at 59.94 is 83 ms, so the likely cause is that `ideal` subtracts a video depth full of the paused frame
(an inference). Whether either reaches a listener is UNKNOWN: both are the bridge's own numbers, and no tool here reads audio off the wire.

**The change, under card lock only.** The anchor reads a continuous source time for the slot, not the quantised staged pts: the pull's `target`, which has no staircase once the clock is on the card. The cursor is set once per run, after the first timed pull, and then advances only by samples
scheduled, with no correction. The loop stays as a monitor: if the smoothed error passes half a source frame it snaps, logged and counted, as a resync does today. Live sources and every state outside card lock keep today's loop.

Result: at 1× the card plays the file's samples in order, with none skipped or repeated, on the clock that plays the frames.

### 10.4 Edge cases

| Case | What happens |
|---|---|
| **No audio track** | Same picture path, the renderer moved the same way. No arm, nothing resampled; SDI carries silence as today. Removes today's 11.7 ppm, one slip per 24 minutes at 59.94 |
| **Output started or stopped mid-playback** | §10.2. The clock holds once, the wire is not on air at that moment, the audio is rebuilt |
| **Window on another display, or moved** | No effect: the pacer ticks the owner and no display is read (§7.9 runs). Other windows keep their own engines and clocks, unlocked |
| **Ownership passes to another window** | Outgoing engine unlocks, incoming locks, from `DeckRegistry.attachDeviceHooks`, the hook that already moves `deckLinkOwnsAudio` |
| **High frame rates** | The tick and window are in seconds, not frames, so 1080p100 and 119.88 need nothing extra. Samples are thinned by time. Budget 169 µs against an 8.34 ms frame. 2160p100/119.88 stays its own bug (every frame late): **not fixed here**. 2160p59.94 cannot be counted by `capture`; pulls can |
| **File rate ≠ output rate** | The clock runs in card seconds at 1×, so sound and duration stay true and the rate difference shows as cadence, not drift: exact and predictable. 25p on 59.94 repeats in a fixed pattern; 23.976 on a 24.000 mode repeats one frame every 1000 slots (41.7 s). Follow source only gets here for rates with no mode, and `rateWarning` already says so. Slip counters must subtract this cadence. Conforming the file to the mode is not proposed |
| **Genlocked card** | Same code. Reference locking mid-play may step the line: a stamp more than half a card frame off the fit is a position step, so `φ` re-latches and it is logged. It may cost one frame, once, in the moment the card itself re-times. Measured: **no**, no reference here |
| **`capture` or anything else steps the rate** | Covered: 169 µs in the replay |
| **Stamps stop (driver stall, late frames)** | No sample for 0.5 s: hold the last rate, write nothing, log. Output failure unlocks through `isOutputting` |
| **A stamp that is not credible** | Skipped; it costs a held rate, never a step (the controller's rule) |
| **The `q3-l1` host-clock launch** | The picture no longer depends on it. The audio synchronizer logs its slope against the host so a repeat is visible; the loop would absorb it |
| **Stills, audio-only, live sources** | No card lock. Audio-only stays silent on the card until B5, which could use this clock |

### 10.5 Predictions and test plan

Written 2026-11-06 before anything is built. **Rate and slips are measured with `capture` closed:** `[CADENCE]` pulls, as §6 established. `capture` runs only where a row says so, as a stress test. Every run uses `cardclock.sh` (`NOCAP=1`), guard before and after, launch by absolute path, quit by PID, with Robbie told first.
Needs one new fixture pair of about 3700 s and 7300 s.

| # | Stage | Run | Today | Prediction |
|---|---|---|---|---|
| T1 | 1a | 59.94, no audio track, 3700 s | 2.6 slips | **0 repeats, 0 skips.** File − card within 0.05 ppm over the run |
| T2 | 1b | 59.94, sound, destination SDI, 3700 s | 3.9 | **0 / 0.** File − card within 0.05 ppm, while the Scarlett reads about +5.9 unchanged |
| T3 | 1b | 23.976, sound, destination SDI, 7300 s | 3.1 | **0 / 0** |
| T4 | 1b | `capture` on and off in one session, as P6, and four 300 s sessions | 1–3 per 300 s | **0 / 0 on the wire**, through the steps. Worst position error under 0.2 ms |
| T5 | 1b | Pause, seek, step, loop, JKL, scrub with output on | | Each resumes with 0 slips beyond the transport's own frame moves; lock re-latches, logged. Decode continues under 1 Hz writes (the probes' video renderer was unfed); end of file lands as today |
| T6 | 1b | Tap over a T2-length run | Lead ≥ 232 ms | Lead stays within 20 ms of today's. Underruns 0 |
| T7 | 1c | SDI audio, T2 and T3 runs | 84–87 % of reads corrected | **`corr=+0f` in every read after lock.** Anchor within half a source frame in the first second. Resyncs 0, underruns 0 |
| T8 | 2 | 59.94, destination Computer, Scarlett, 3700 s | 3.9 | **0 / 0.** `ρ − 1` settles at card − device, about −17.6 ppm, within 0.5. `|e|` under 0.2 ms after 2 minutes. Zero rate writes on the audio synchronizer between Play and Pause |
| T9 | 2 | Same, renderer named to the built-in | | Same, with `ρ` at that device's own difference |
| T10 | 2 | `capture` on and off, Computer | | 0 / 0 on the wire. `e` peak under 1.5 ms (simulated 1.0) |
| T11 | 2 | SDI ↔ Computer flip while playing, 10 times | | 0 / 0, no rate write, no renderer move |
| T12 | 2 | **Attended.** Audio Hijack + OBS recorder, 30 min, Computer: A/V at start against end, and a dropout scan | | No slope between start and end. No dropouts in steady play. Also gives the Mac-to-wire offset, today UNKNOWN |
| T13 | 2 | Window on the LG, the ASUS, and moved; 1080p100 and 119.88; 2160p59.94 by pulls | | 0 / 0 |
| T14 | 2 | 23.976 file on a manual 24.000 mode, 600 s | | One repeat every 1000 slots, evenly spaced, no others |
| T15 | every | **Output off:** §3's table on a file with sound | | File = device within 0.02 ppm. No `[CARDLOCK]` line; no audio synchronizer created. `swift test` passes; export set byte-identical |
| T16 | every | **Live control:** output on with local SRT or NDI | | No card lock. Behaviour unchanged, so CLAUDE.md's non-Cloudflare rule is met |

Genlock has no row: it needs a reference signal. It stays UNKNOWN until one is connected, with T2 and T7 as the run to repeat.

**Attended check: how `capture` moves the clock.** Robbie's only job is the cable. Each state is one output session, `PHASES=30`, 30 s closed / 30 s `capture` open / 30 s closed, four times, reading card (c), file playing:

1. **Loop in** (control). Predicted: as P6, about −11.7, a different value per open, back to −11.7.
2. **Loop out, input with no signal.** Predicted: **no step**, −11.7 throughout. My guess at the mechanism: the output follows the input's signal, and on the loop that signal is the output itself, so it settles anywhere. That is a guess.
3. **Loop out, a signal from something else, if one is to hand.** Predicted: the card moves toward that signal's rate, the same value on every open.

If 2 holds, only a loop triggers it, and a customer with an unrelated input in use is probably safe. If 2 fails, any open input moves the output clock, which is worth a line in the manual. Card lock handles either.

### 10.6 Hooks and telemetry

| Hook, today | Fate |
|---|---|
| Completion stamp read, `[CARDCLOCK]` block in `ScheduledFrameCompleted` | The read becomes **permanent, ungated code**: it is the input to card lock. The 1 Hz log line is **removed** |
| `cardClockLogReference("start")` | **Permanent**, one ungated line at each output start, plus one when the locked state changes. Genlock needs this evidence |
| `cardClockLogReference("minute")` | **Removed** |
| `CardClockProbe`, `gCardClock`, `cardClockAdopt`, `cardClockHostNow`, `kCardClockLog` | **Removed.** The player owns its output; no global is needed |
| `MANIFOLD_CARDCLOCK_AUDIO_DEVICE_UID`, `#if MANIFOLD_CARDCLOCK`, the `-DMANIFOLD_CARDCLOCK` build | **Kept until T9 passes, then removed**, with its line in `cardclock.sh` |
| `[CADENCE]` (existing, DEBUG, env) | Stays: it is the test instrument |
| `scripts/decklink-loopback/cardclock*`, `devclock.swift` | Stay in the repo, not shipped. The probes join them at Stage 1 so a macOS update can be re-checked |

**New permanent telemetry.** `[CARDLOCK]` on each lock, unlock and re-latch, ungated, like `[PACER]`. A 10 s line, card rate, position error, audio `ρ` and `e`, under `MANIFOLD_TELEMETRY`. And a **slip counter** in the output-stopped summary: pulls whose frame was not the next one due, net of cadence. A reference player should be able to say how many it made.

**Gating.** Card lock is shipped behaviour, so none of it may sit behind `DEBUG` in the bridge or behind `MANIFOLD_CARDCLOCK`. `ManifoldCore` never sees `DEBUG` in Profile, and `MANIFOLD_TELEMETRY` is on in Release too.

**Release compile check.** Run today on the tree with the hooks: `xcodebuild … -configuration Release -derivedDataPath ./.build-cc CODE_SIGNING_ALLOWED=NO build`, **succeeded**. `strings -a` on that binary: `[CARDCLOCK` 0, `MANIFOLD_CARDCLOCK_AUDIO_DEVICE_UID` 0, `[CADENCE]` 0, `[PACER]` 8 (the control). At the end of each stage, the same compile and the same check, with
`[CARDLOCK]` required present. At the end of Stage 3 `MANIFOLD_CARDCLOCK` must be gone from the tree. No Release build has ever been run for this path; every build cut to date is Profile, so a compile plus `strings` is the honest limit of this check.

### 10.7 Stages

Each stage ends with its T rows, T15, T16 and the Release check, and is committed on its own.

| Stage | What | Result |
|---|---|---|
| **1a. Picture on the card** | `CardClock` target in ManifoldCore: fit, latch and write as pure functions, with tests replaying saved stamps and a synthetic step. Bridge publishes the sample. Lock engages for a file with **no audio track** only. No audio code is touched | Removes the slip for files with no sound. Proves the writes against the real decode path |
| **1b. Destination SDI** | The audio synchronizer; the renderer moves at lock, unchanged and unresampled; pump, tap and mute as today. While muted, the audio synchronizer is re-anchored to the picture when they part by 20 ms, a bound from the tap's 250 ms look-ahead. That keeps the tap's lead bounded, about every 19 minutes here, and inaudibly, because it is muted | **Removes the SDI-destination slip, on its own.** Destination Computer stays as today, slips included. A destination flip on air drops or takes lock, with its 48/65 ms hold, until Stage 2 |
| **1c. SDI audio** | §10.3 | SDI audio sample-continuous, and the Play crawl gone |
| **2. Option A** | Stage and small steering class in the pump closures; the transport setter; lock for both destinations; 1b's re-anchor retired; flip back to a mute flip. Amend `AUDIO_RESAMPLER_DESIGN.md` §1.3 and §4.2 | Slips gone in both destinations. Sound and picture locked on the Mac |
| **3. Finish** | Remove hooks per §10.6, soak, close the `BUGS.md` entry, retire the pre-ship item. The 1.1 card-clock entry shrinks to what §10.1 option E still offers | Ready for 1.0 |

**Decided (Robbie, 2026-11-06).**

1. **1c is in 1.0 scope.** `BUGS.md`, *SDI audio is not sample-continuous, and takes about 44 s to settle after Play*. The figures in §10.3 are the bridge's own and have not been seen on the wire. So 1c starts by measuring the wire: SDI
   audio on the loop with a click fixture, counting discontinuities and the A/V offset from Play through the first 60 s.
2. **Destination Computer, output on: Mac sound lines up with the SDI picture, not the window.** This changes §10.2, where the target is the picture clock: Stage 2's target carries the wire's offset from it. That offset (by code reading about 100 ms at 59.94, 230 ms at 23.976) is a **known item to
   measure, not yet acted on**.
3. **The one-off hold at output start and stop while playing is accepted.**
4. **1b and Stage 2 ship together in one release.** Stages are built and verified separately. So the interim state in 1b's row, with Computer still slipping and a flip on air holding, never reaches a user.
5. **Genlock is not tested for 1.0:** no reference signal is available. Free-running is the expected case for Manifold's users. The design must not assume free-running: a locked card is still the master. The release notes say a genlocked card is untested. Re-test if a tester with house sync reports a problem.

**Unknown going in.** Whether the decode path is untroubled by 1 Hz writes (T5). Whether a move of the audio renderer behaves the same with real queued audio and picture (the probes used silence and no frames). The Mac-to-wire offset in destination Computer: by reading the code about 100 ms at 59.94 and 230 ms at 23.976, five card frames plus the pull
margin, never measured at a device. Genlock. Whether §10.3's corrections or the Play crawl are audible or even present on the wire.

### 10.8 Stage 1a: predictions, written 2026-11-06 before any code

Scope: files with no audio track. Picture on the card's clock; no audio code touched. Probed first: with an audio renderer attached and never fed, which is what this case has, past-host writes stay on the line (median 0.2 µs, −129 to +47 µs over 30 writes), so the renderer stays where it is.
No renderer moves, so the accepted hold at output start and stop does not arise in 1a.

Verified with `capture` closed, by `[CADENCE]` pulls. New fixtures of 2450 s. A 2400 s run today would slip 1.7 times at 59.94 and 0.7 times at 23.976 (11.7 ppm, card against host), so **the 23.976 runs are weak evidence on their own**: two of them have about a 25 % chance of showing nothing even with no fix. The clock readings below carry that weight.

| # | Run | Prediction |
|---|---|---|
| A1 | 59.94, no audio, 2450 s, twice | **0 repeats, 0 skips in pulls.** File reads about −11.7 ppm against the host; file − card (b) within 0.05 ppm |
| A2 | 23.976, no audio, 2450 s, twice | The same |
| A3 | All of A1, A2 | `[CARDLOCK]` position error median under 20 µs, worst under 200 µs (replay: 169 µs). Card late 0, dropped at most the frame-4 case before Play. No `[FRAMEQ]` evictions |
| A4 | Output started and stopped mid-playback, three times in one play | Output off: file 0.00 ppm. Locks within 3 s of output start. **No clock step over 1 ms at lock or unlock.** Back to 0.00 ppm after each stop. 0 slips while on, beyond what output start itself gives before the lock (the pull's first frames) |
| A5 | Pause, Play, seek, frame step, loop wrap, JKL with output on | Lock suspends and re-latches; **a paused clock stays paused**: no write ever restarts it. 0 slips in each steady stretch |
| A6 | **Output off,** file with sound, then no audio, 300 s each | Sound: file = Scarlett within 0.02 ppm. No audio: 0.00 ppm. No `[CARDLOCK]` line in either |
| A7 | **Output on, file with sound,** 300 s | Not locked, no `[CARDLOCK]` line: file = Scarlett within 0.02 ppm, as today |
| A8 | Live control: output on, local SRT | Not locked, no `[CARDLOCK]` line |
| A9 | `swift test`, Release compile, `strings` | Pass. `[CARDLOCK]` present in Release, `[CARDCLOCK` absent |

**Added stress, not a substitute for A1 and A2:** one `capture`-open run per rate, 300 s, where the card sits tens of ppm off and today slips 1–3 times. Predicted 0 on the wire. This is the strong test at 23.976.

### 10.9 Stage 1a: results, 2026-11-06

Built and verified, not committed. The lock did what §10.8 predicted on every point that matters: **0 skips and no slip in six 40-minute runs, and the file clock on the card to 0.00 ppm.** Three predictions missed as written, listed below; none of them is the lock failing. Profile builds, guarded before and after every run, `capture` closed unless stated, 1001-based fixtures.

**Conditions.** Robbie was on a browser video call during part of the run. coreaudiod's log shows one client with 40 start/stop events from 17:21:51 to 18:25:17, the likely match by timing; the process has gone, so which process it was is UNKNOWN. It overlaps the last 26 minutes of `a1-5994-r2` and nearly all of `a2-2398-r2`. Both runs were kept as a load check, and `a1-5994-r3` and `a2-2398-r3` were added on a quiet machine: no recording client but the harness's own `devclock`, no device restart. So there are two runs per rate outside the call.

| Run | Conditions | File, ppm vs host | Card (b) | File − card | Lock error median / worst, µs | Pulls counted | Repeats | Skips | Late / dropped | FRAMEQ |
|---|---|---|---|---|---|---|---|---|---|---|
| a1-5994-r1 | quiet | −11.67 | −11.67 | 0.00 | 2.9 / 73.9 | 143919 | 2, at Play | 0 | 0 / 0 | 0 |
| a1-5994-r3 | quiet | −11.90 | −11.90 | 0.00 | 4.1 / 74.2 | 143919 | 2, at Play | 0 | 0 / 0 | 0 |
| a1-5994-r2 | last 26 min in call | −11.97 | −11.97 | 0.00 | 2.9 / 83.9 | 143919 | 2, at Play | 0 | 0 / 0 | 0 |
| a2-2398-r1 | quiet; Scarlett restart, below | −11.53 | −11.53 | 0.00 | 3.4 / 66.6 | 57567 | 1, at Play | 0 | 0 / 0 | 0 |
| a2-2398-r3 | quiet | −11.55 | −11.55 | 0.00 | 3.1 / 93.2 | 57567 | 1, at Play | 0 | 0 / 0 | 0 |
| a2-2398-r2 | in call | −11.83 | −11.83 | 0.00 | 2.7 / 64.0 | 57567 | 1, at Play | 0 | 0 / 0 | 0 |

Each of those runs is one unbroken 2401 s stretch of the clock, with 0 steps over 1 ms. At 11.7 ppm the unlocked file drifts 28 ms from the card in 2400 s, 1.7 frames at 59.94 and 0.67 at 23.976; the lock held it within 93 µs. That position error, not the slip count, is what carries the 23.976 result, as §10.8 said it would have to.

| # | Predicted | Result | |
|---|---|---|---|
| A1, A2 | 0 repeats, 0 skips; file about −11.7; file − card within 0.05 | Skips 0. File − card 0.00. File −11.53 to −11.97. Repeats 2 per run at 59.94, 1 at 23.976 | **Repeats missed as written.** All are the first pulls after Play, at clock about 0.03 s, nearly 2 s before the lock latches. The same 2 appear with no lock at all (`a7-on-sound`), so they are not the lock's. 0 repeats after the lock in any run |
| A3 | Error median under 20 µs, worst under 200 µs; late 0; no evictions | Median 2.7–4.1 µs, worst 93.2 µs, late 0, dropped 0, FRAMEQ 0 | Held |
| A4 | Output off 0.00; locks within 3 s; no step over 1 ms; back to 0.00 after each stop; 0 slips beyond output start | Off: −0.005, −0.007, −0.023, −0.001 ppm. Locked: −11.79, −11.87, −11.80. Lock about 2.3 s after output start. 0 steps over 1 ms. 3 repeats, the first pulls of each new output before the lock; 0 skips. Worst error 16.2 µs | Held, with **one prediction wrong:** stopping output pauses every deck (`[ARBITER] exclusive device released`, existing behaviour), so the clock does not carry on at 0.00 after a stop. It reads 0.00 once Play is pressed again |
| A5 | Lock suspends and re-latches; paused clock stays paused; 0 slips in steady stretches | All re-latches correct; paused clock stayed paused; error median 1.9 µs, worst 15.7 µs. 8 repeats in 7723 pulls, all the end-of-file hold at the loop wrap, which is existing behaviour; 0 otherwise | Held |
| A6 | Sound: file = Scarlett within 0.02. No audio: 0.00. No `[CARDLOCK]` | No audio −0.001. Sound, three runs: +0.041, −0.009, −0.023. 0 `[CARDLOCK]` lines and 0 clock steps in all four | **Sound missed 0.02 in two of three runs.** Mixed sign, mean +0.003, no sign of an offset. The fit's noise on 1 Hz readings is 0.006–0.021 ppm, so 0.02 was tighter than this measurement resolves. The first run predates the call |
| A7 | Not locked; file = Scarlett within 0.02 | File +5.69, Scarlett +5.68, card −11.91, 0 `[CARDLOCK]` lines | Held |
| A8 | Live, not locked | 0 `[CARDLOCK]` lines; 2405 pulls, 0 repeats, 0 skips | Held |
| A9 | Tests pass; `[CARDLOCK]` in Release, `[CARDCLOCK` absent | `swift test` 0 failures. Release compiled. `strings`: `[CARDLOCK]` 4, `[CARDCLOCK` 0, `MANIFOLD_CARDCLOCK_AUDIO_DEVICE_UID` 0, `[TRANSPORT]` 0, `[CADENCE]` 0 | Held |
| Stress | `capture` open, 0 on the wire | 59.94: card −101.00, file −101.01, 19407 wire frames, 0 repeats, 0 skips. 23.976: card −84.55, file −84.55, 7992 wire frames, 0 repeats, 0 skips | Held, but at 23.976 weaker than §10.8 claimed: 84.55 ppm over 333 s is 0.68 of a frame, not 1–3 slips |

**A1's −11.7.** It held over 40 minutes. Short runs read differently because the host wanders: the 60 s smoke run read −14.5, and card − device stayed about 17.5 there. The figure is the host's, not the lock's.

**The Scarlett restart in `a2-2398-r1`.** Its summary shows device −15530.98 ppm. That is not a clock reading: the device's sample counter restarted at 16:29:53, with coreaudiod stopping IO after 6445568 frames as another recording client ran for 18 s (16:29:54–16:30:12; which client is UNKNOWN). It is not the call. The file has no audio, and its clock ran straight through.

**The call as a load check.** Worst lock error in the runs it touched was 83.9 and 64.0 µs, against 93.2 µs on a quiet machine. No load effect shows in the lock. This is one call, not a load test.

**What this means for 1b.** The arbiter's pause means the hold §10 accepted at output stop should not arise: the clock is already pausing. The hold at output start remains. §10.8's slip counter (§10.6) was not part of 1a and is not built. The export set was not byte-checked; render code was not touched.
