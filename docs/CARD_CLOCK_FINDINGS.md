# Card clock findings: what the SDI slip fix must be designed around

**Result in brief (2026-11-06).**

- **The slips are real, and rarer than §7.9 implied.** Left alone, this card runs at −11.67 ppm against the host, steady, and a file with
  sound follows the Mac's audio device at about +5.9 ppm. That is +17.6 ppm apart: one skip every 948 s at 59.94, measured 947 s.
- **§7.9's "the card's rate differs per session" was caused by the measurement.** `capture` opening the card's input on the loop moves
  the card's output clock, to a different value each time, up to about ±125 ppm. When it closes, the card returns to −11.7.
- **The file clock follows the audio device,** even with destination SDI, where that device is muted and nobody hears it.

**Step 2, the plan (2026-11-06): §10.** Stage 1a is built (§10.9); 1b is §10.11.

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
run. Logs and per-session JSON were in `build/cardclock/` (gitignored), deleted 2026-11-06 once §10.10 had read them; the numbers here are what remains. The installed app was running at the first guard check, so nothing launched
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
| T15 | every | **Output off:** §3's table on a file with sound, **measured over 20 minutes or more** | | File = device within 0.02 ppm over that span (decided, Robbie, 2026-11-06: the tolerance stays and the run grows, because over 300 s the fit's own noise is 0.006–0.021 ppm, §10.9 A6). No `[CARDLOCK]` line; no audio synchronizer created. `swift test` passes; export set byte-identical |
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

### 10.10 Repeats at Play: classification, 2026-11-06

**Answer: both kinds exist, and which you get depends on whether the audio renderer is on the clock.** With no audio track they are all start latency. With sound and an unlocked clock, a Play from a mid-file pause usually skips, and often repeats after motion has begun. That is new, and it is not 1a's "1–2 repeats at Play", which are the first kind: `BUGS.md`, *Play from a pause on a file with sound skips a frame, and can repeat one after motion begins*.

**Method.** No saved run could answer this on the wire: `capture` opened 1 s after Play in every one, so the first mark is picture 59. So four new runs (`cardlock.sh playwire`, `cardlock-playwire.py`, committed 1a build at `d7a4e93`, destination SDI): `capture` open before the first Play, then 16 Pause/Play pairs mid-file and 4 seeks to 0 with a Play, 21 Plays each. `capture` moves the card's rate (§5), which does not matter for picture order. Then the pulls in all saved logs, 64 Plays over 45 runs.

Wire, picture numbers read by `capture`:

| Run | Clock | Plays from 0: clean | Mid-file: clean | Mid-file: +2, no repeat | Mid-file: +1, then repeat | Mid-file: +2, then repeat |
|---|---|---|---|---|---|---|
| 59.94, no audio | locked | 5 of 5 | **16 of 16** | 0 | 0 | 0 |
| 23.976, no audio | locked | 5 of 5 | **16 of 16** | 0 | 0 | 0 |
| 59.94, sound | unlocked | 5 of 5 | 3 of 16 | 6 | 0 | **7** |
| 23.976, sound | unlocked | 5 of 5 | 9 of 16 | 1 | 4 | **2** |

The frame sequences, around the first new picture:

| Case | Sequence on the wire |
|---|---|
| Clean: start latency, every no-audio Play | `0, 0, 0, 1, 2, 3, 4` · `240, 240, 240, 241, 242, 243` |
| Sound, skip | `235, 235, 235, 237, 238, 239` |
| Sound, skip then repeat | `477, 477, 477, 479, 479, 480, 481` |
| Sound, 23.976, repeat | `95, 95, 95, 96, 96, 97, 98` |

- **Start latency, all no-audio Plays and every Play from 0.** The paused picture stays on the wire, then motion starts at +1 with no later repeat. The pulls show how long it stayed after the clock started: 0–2 pulls. These are 1a's repeats: in §10.9's runs, `0, 0, 0, 0, 1, 2, 3` with the clock already moving for the last two zeros. On the wire they cannot be told from the pause before them, so nothing there is a defect.
- **Skip, and repeat after motion, on a mid-file Play with sound.** 20 of 32 Plays were not clean. In 16 the first new picture jumps one frame, and in 13 a picture repeats straight after the first move.
- **The cause, as far as measured.** At the first running pull the clock has already risen 1.47–2.82 frames at 59.94 with sound, 0.64–1.44 at 23.976, against 0.03–0.98 with no audio. So the clock gets ahead of the pull at the start and the pull catches up in one step: that is the skip. If it overshot, the next pull has nothing new: that is the repeat. Why the clock rises that much with the renderer attached is UNKNOWN. Picture 0 escapes because the paused clock and picture agree there; that is an inference.
- **Saved pulls agree.** 62 of 64 Plays are the hold alone. The other two: `p6` is this fault (`13503, 13506, 13506, 13507`, a two-frame skip), and `q1-5994-noaudio`'s is a drift slip 8.3 s after Play, on that run's 175.5 s spacing, not a Play event. Mid-file skips with no repeat also show in the saved pulls (`3721, 3723`, `r-nocap`), and 1a's counters did not count them, because they ignored the step into motion.

The apparent repeats near 177 (59.94) and 71 (23.976) in `cardlock-playwire.py`'s output on the Plays from 0 are the script's own next `pause;seek 0`: the hold before a seek is under its 0.5 s rule, so it is read as motion. They are not counted above.

### 10.11 Stage 1b: predictions, written 2026-11-06 before any code

Scope: a file with sound, destination SDI, output on. Destination Computer stays as it is today, slips included. Files with no audio keep 1a's path, with the renderer left where it is. Verified with `capture` closed by `[CADENCE]` pulls, except where a row says otherwise. Plain Profile builds, guarded before and after every run, launched by absolute path, quit by PID. No commit.

**Length.** B1 and B2 are 2400 s on the 2450 s fixtures with sound, as Robbie's brief for 1b sets, not T2's 3700 s and T3's 7300 s. Unlocked, 17.6 ppm over 2400 s is 42 ms: 2.5 slips at 59.94 and 1.0 at 23.976. So as in 1a, a clean slip count at 23.976 is weak evidence on its own, and the position error carries it.

**What the design expects of the audio synchronizer.** It runs on the device, so against a card at −11.7 and a device at +5.9 it gains on the picture at 17.6 ppm: 20 ms in 1136 s. While it is ahead the tap's lead grows, so nothing is at risk on this Mac. Behind, the lead shrinks one for one, which is what the 20 ms bound is for. On a Mac where the device runs slow against the card, that direction is the real one.

| # | Run | Prediction |
|---|---|---|
| B1 | 59.94, sound, destination SDI, 2400 s, twice | **0 skips, and no repeat after motion begins.** File reads about −11.7 ppm against the host; file − card (b) within 0.05 ppm, while the Scarlett reads about +5.9, unchanged. The Play hold stays as §10.10 classifies it |
| B2 | 23.976, the same, twice | The same |
| B3 | All of B1, B2 | `[CARDLOCK]` error median under 20 µs, worst under 200 µs. One unbroken stretch of the clock, 0 steps over 1 ms. Card late 0, dropped at most the frame-4 case. No `[FRAMEQ]` evictions |
| B4 | Audio synchronizer in B1, B2 | **2 re-anchors in each 2400 s run** (1136 s apart), each from about +20 ms, with the audio ahead, and each leaving the picture clock untouched. 0 `synchronizer` writes from it. Parted by under 20 ms within 2 s of Play |
| B5 | Tap in B1, B2 (T6) | Tap lead over the card's cursor at least today's minimum less 20 ms; if the audio sits ahead as predicted it only grows. `underruns` 0. `short` and `resyncs` no worse than `a7-on-sound`'s rate |
| B6 | **Scarlett IO restart.** A second process opens the Scarlett's input for 20 s partway through a run, 59.94 and 23.976, sound, destination SDI, 600 s each, `capture` closed | `devclock` logs a sample-time discontinuity at the helper's start, and perhaps at its end. **File clock: 0 steps over 1 ms, one unbroken line. Lock error worst under 200 µs through it. 0 repeats, 0 skips, late 0, dropped 0.** The audio synchronizer may stall: my guess is under 100 ms. If it parts by over 20 ms it is re-anchored once. `underruns` 0, on the guess that a stall stays inside the 232 ms lead; a longer stall would break this one, and it would show as silence on SDI, not as a picture fault |
| B6c | Control: the same restart on the 1a build, file with sound, 300 s | **The picture is not protected:** the file clock is on the device, so it moves with the restart: a step or a stall in it over 1 ms. This is what makes B6 mean something. If it shows nothing, the helper did not reproduce the event and B6 proves nothing |
| B6w | The restart with `capture` open, 59.94, 300 s | 0 repeats, 0 skips on the wire, which is the direct reading of "nothing on the card" |
| B7 | Output started and stopped while playing, three times, file with sound | Locks within 3 s of output start. **One hold of about 48 ms at each start while playing** (accepted, §10.7). At a stop, none: the arbiter has already paused the deck (§10.9). After each stop the renderer is back: file = Scarlett again once Play is pressed. 0 slips after the lock |
| B8 | Output started with the deck paused, then Play | The renderer moves with the clock stopped, and the paused clock does not change |
| B9 | Pause, Play, seek, frame step, loop wrap, JKL, sound (T5) | Lock suspends and re-latches; a paused clock stays paused; the audio synchronizer follows every move and is under 20 ms from the picture within 2 s of each return to 1×. 0 slips in each steady stretch. End of file lands as today. Decode carries on through the 1 Hz writes |
| B10 | `capture` on and off in one session, and one 300 s session per rate, sound (T4) | 0 / 0 on the wire. Lock error under 200 µs. Re-anchors become frequent, about one every 200 s at 100 ppm, and the picture does not notice them |
| B11 | Destination flipped SDI → Computer → SDI while playing, five times | Interim behaviour, §10.7: each flip to Computer releases the lock and puts the renderer back (hold about 65 ms); each flip to SDI moves it off (about 48 ms) and locks within 3 s. No crash, no stuck mute, and the sound is on the right output after each flip |
| B12 | A file decoded by libav, with sound, destination SDI, 300 s | The same as B1. This is the other audio pump |
| B13 | **Destination Computer, output on, sound, 1250 s** | Not locked, 0 `[CARDLOCK]` lines, no audio synchronizer. File = Scarlett within 0.02 ppm, over 20 minutes as T15 now says |
| B14 | **Output off (T15),** sound, 1250 s; then no audio, 300 s | Sound: file = Scarlett within 0.02 ppm over the 20 minutes. No audio: 0.00. 0 `[CARDLOCK]` lines, no audio synchronizer |
| B15 | 1a's case, no audio, destination SDI, 300 s | Locked as 1a, and no renderer move |
| B16 | Live control (T16): output on, local SRT | Not locked, 0 `[CARDLOCK]` lines |
| B17 | `swift test`, Release compile, `strings` | Pass. `[CARDLOCK]` in Release, `[CARDCLOCK` absent |
| B18 | **Added after §10.10, before any 1b run.** The `playwire` run on a file with sound, destination SDI, under 1b, both rates | With the renderer off the clock it behaves as no audio does: **16 of 16 mid-file Plays clean at each rate**, on the wire. If it holds, §10.10's fault is gone for destination SDI and stays for Computer until Stage 2 |

**Unknown going in**, from §10.7, now to be answered: whether a renderer with real queued audio survives the move, or loses its queue. It is muted, so a lost queue costs nothing audible on the Mac, but the pump must keep running or the tap dries up. And what `AVSampleBufferRenderSynchronizer` does when its device restarts under it: nothing here has measured that.

### 10.12 Stage 1b: results, 2026-11-07

**Not ready to ship: the picture can freeze (below).** With that set aside, the design did what §10.11 said. The card rate holds the picture, destination SDI runs without a slip, and the Scarlett no longer matters to it.

Lengths: B1 and B2 ran 2400 s, as the brief set. T2's 3700 s and T3's 7300 s were not run. Capture closed unless a row says otherwise. Every run below used a Profile build carrying temporary `[PUMPWATCH]` diagnostics, since removed. The rows B1–B18 were run before the parked re-read fix; the re-test section says which were run again after it.

| # | Result | Against prediction |
|---|---|---|
| B1 | File −11.24, −11.05 ppm; file − card ≤ 0.001; Scarlett +6.96 to +7.40. r1: 0 repeats, 0 skips. **r2 froze at pts 1998.78** | **Missed**, on r2. Clock numbers held |
| B2 | File −10.93, −10.92. 0 repeats, 0 skips, both runs | Held. Weak at 23.976, as §10.11 says |
| B3 | Error median 3.1–4.8 µs, worst 84.3–119.7 µs. Late 0, dropped 0, 0 evictions, 0 running steps. One step of −15 to −31 ms per run, at Play itself | Held. The step at Play is also in unlocked and no-audio runs, so it is not 1b's |
| B4 | 2 re-anchors from +20.0 ms, 1090–1105 s apart, as predicted, plus **one at Play, −70 to −81 ms, 2–6 s after Play** | Partly missed: the Play one was not predicted. Device start-up; the picture does not notice |
| B5 | Lead over the cursor: floor well above today's. Underruns 0 at 59.94. At 23.976, 3–5 in one event at Play (about 78 ms, srcT ≈ −0.03) | Missed as written at 23.976, but today's q1-2398 had 9, so not worse. Median lead rose from 0.72–0.90 s to about 1.7 s. Cause UNKNOWN (see re-test) |
| B6 | 600 s at each rate. Restart logged (−218.6 s, −21.06 s off the device's sample time). 0 running steps, error worst 109–110 µs, 0 repeats, 0 skips, late and dropped 0, no extra re-anchor, audio part unbroken | Held |
| B6c | 1a file clock unbroken through the restart: +6.336, +6.273, +6.279 ppm before, during, after | **Missed.** Today's timebase absorbs the restart too, so B6 passing is not 1b's doing. It shows 1b did no harm, not that it protects |
| B6w | Wire 20689 frames, 0 repeats, 0 skips | Held |
| B7 | Holds −44 to −55 ms, moves 48–55 ms out, 46–71 ms back, locks in about 2 s | Held |
| B8 | Moves at rate 0, paused clock unchanged | Held |
| B9 | Re-latches correctly. Error median 1.8 µs, worst 52.8 µs. 5148 pulls, 7 repeats, all at the loop-wrap hold, which 1a also has (8). Dropped 1, one step of +9.23 ms at the return from shuttle | Held, bar the dropped frame and the step. Neither came back in the re-test |
| B10 | 0 / 0 on the wire. Fewer re-anchors than predicted: sessions were too short to reach 20 ms at 100 ppm | Held, with that note. The phases sessions also showed the start silence below |
| B11 | 5 flips each way release and re-lock. 0 pull repeats, 0 skips | Held. Mac audio right after a flip not measured (decision below) |
| B12 | 12 of 13 libav runs clean. **`b12-libav` froze at pts 47.01** | **Missed** |
| B13 | File +7.460, Scarlett +7.461, 0 `[CARDLOCK]`. 2 skips, as expected unlocked | Held |
| B14 | Sound: +7.626 against +7.624. No audio: −0.000. 0 `[CARDLOCK]` | Held |
| B15 | Locked as 1a, no renderer move | Held |
| B16 | 0 `[CARDLOCK]`. 2 repeats, 2 skips, live and unlocked | Held |
| B17 | Tests 0 failures. Release: `CARDLOCK]` 7, `[CARDCLOCK` 0, `[TRANSPORT]` 0, `[CADENCE]` 0. Run again on the final tree, diagnostics out | Held |
| B18 | 42 of 42 Plays clean on the wire, both rates | Held. The Play skip in `BUGS.md` is gone for destination SDI |

**§10.11's open question, answered: the renderer loses its queue at a move.** The pump keeps running, and refills from where it had reached.

**Fault 1, fixed: 0.2–0.9 s of SDI silence after Play, mid-file.** A regression in 1b. Outside the Jump stalls below, 6 of 10 sessions had it on 1b, against 0 of 12 on the 1a control (`c1a-ph1..3`, same script). Each move costs the renderer its queue, so the pump's position walks on about a second, and the tap keeps 4.0 s (`AudioTapBuffer.swift:108`). One session, parked at 191.37: tap at 193.49, then 194.45 at the move back, then 195.50 at the move out, and on. That pushed the frames at the cursor out of the ring, and SDI read nothing until the cursor reached the oldest frame left. A first session from 0 has only one move and never showed it. **Fix:** `rereadSoundAfterMove`, a move that ends with the clock stopped reads the sound again from the clock. Moves while running are unchanged.

**Re-test after the fix** (`f-` runs): 11 of 12 phases sessions at 59.94 have 0 underruns and the tap parked about 1.9 s ahead; the twelfth froze. 3 of 3 libav phases sessions clean. 23.976 phases sessions: 4–5 underruns at each Play, one event of 78–100 ms, as B5. Mid-file Play 0 underruns. `f-transport`: error worst 12.7 µs, 0 steps, dropped 0, 7 repeats at the same loop wrap. `f-flip`: 4466 pulls, 0 repeats, 0 skips, error worst 24.8 µs. Median lead stays about 1.7 s, so parked moves are not what raised it; that cause is UNKNOWN. It leaves 2 s of margin in the ring.

**Soak after the fix:** `s-fz4..8`, five runs of 2400 s at 59.94 with sound, capture closed. File −10.82 to −10.98, file − card 0.00, Scarlett +7.87 to +8.04. 0 pull repeats, 0 skips, late 0, dropped 0, underruns 0, resyncs 0. No freeze.

**Fault 2, open: a change of the system default output stalls the audio pump.** Jump Desktop switches the default output on connect and restores it on disconnect. Its log has four such events overnight, and the three that fell inside runs each cost SDI audio to the end of that session: 26 s, 90 s and 22 s (first written here as 27, 95 and about 28 s, and read as stall lengths; §10.13 corrects both). During the stall the renderer reads ready, its callback does not fire, and the audio clock stays right. Only a renderer move restarts it. **Today's path does the same: §10.13.**

**Fault 3, open and blocking: the picture freezes.** Three times in about 37,000 s of sound-locked running:

| Run | Path | Last picture | When | Then |
|---|---|---|---|---|
| `b12-libav` | libav | pts 47.01 | 47 s after Play | 256 s of SDI silence, 5 resyncs |
| `b1-5994-r2` | AVFoundation | pts 1998.78 | 1999 s after Play | 405 s of silence, 24108 pull repeats |
| `f-ph1` s4 | AVFoundation, capture open, with the fix | pts 330.05 | 43 s after Play, fourth session of the launch | to the end of the session, 3154 pull repeats, 4 resyncs |

The clock keeps running and stays on the card's line, so **every clock figure looks fine through a freeze**: check pulls and the SDI stop line. It does not recover. CoreMedia shows the video queue fed normally, then nothing, and the queue drains. The renderer then reads `isReadyForMoreMediaData` false with the queue empty, status 1, gate not parked. The libav pump's end line never printed. No error in any of the three system logs, no Jump event near them, and no shared phase against the 1 Hz write (the last frame came about 150 ms after one write, about 710 ms after another).

UNKNOWN: whether the pump is blocked or the renderer stopped asking; whether it needs the 1 Hz writes; whether it needs sound. 1a's 9600 s with no audio saw none, but at this rate that is no evidence: about a one in three chance of none anyway. Unlocked sound runs are too short to say either. None came in the eight watched 2400 s runs (`s-fz1..8`), so no stack sample exists. Unanswered licence Keychain prompts sat on screen through the night, freezes and clean runs alike, and the system logs around the freezes have no SecurityAgent line, so nothing ties them together. Measurement also disturbed one run: a `sample` of the build cost 26 frames (late 6, dropped 20) at 06:30:49 in `s-fz1`, so sampling is kept for a freeze already under way.

### 10.13 After the 1b report: Jump, the gate, and decisions, 2026-11-07

**Decisions (Robbie, 2026-11-07).**

- **Stage 1b is off by default.** All of it sits behind `MANIFOLD_CARDLOCK_1B=1`, read once at launch, until the freeze is understood.
- **The re-anchor of −70 to −81 ms after Play is not accepted.** B4's "the picture does not notice" stands as a measurement, not as an acceptance. It is filed under 1c, in the same family as the −84 ms post-Play settle (`BUGS.md`, *SDI audio is not sample-continuous*).
- **The doubled tap lead** (median 0.72–0.90 s up to about 1.7 s, B5): noted. Investigated only if the freeze stacks point at the audio pump.
- **Mac audio after a flip to Computer** is deferred to Stage 2.
- **T2 and T3 at full length** are deferred until the freeze is understood.
- **Genlock:** as §10.4 and §10.5 record.

**Jump, attended, with Robbie connecting and disconnecting.** A file with sound, destination SDI, 59.94, capture closed, Scarlett the default output. `j-today` is `d7a4e93` from a `git archive` export (`build/linkpace-src/d7a4e93`) (deleted 2026-11-08: gate off now reproduces `d7a4e93`, §10.13 "The gate"), `j-1b` the working tree. `defout.swift` logged the default output on the host clock, and Jump's own log agrees to the second.

| | `j-today` | `j-1b` |
|---|---|---|
| Connect, default output to Jump Desktop Audio | SDI silent 0.65 s later | SDI silent 2.7 s later |
| Last tap line (the pump's position) | pts 44.27 | pts 41.28 |
| Disconnect, default output back | 79 s after connect. No recovery | 138 s after connect. No recovery |
| Watched after the restore | 337 s, silent throughout | 337 s, silent throughout |
| Silence, from the underrun count | 423 s, one event, to the end of the session | 488 s, one event, to the end of the session |
| Window | Kept playing: 60 presented a second, dropped 0, late 0 | The same |
| SDI picture | Pulls: 0 repeats, 0 skips. Late 0, dropped 0 | The same |

**So Fault 2 is not 1b's. It is in today's path, and so in 0.9.2.** The switch stops the audio pump on both. The picture does not notice on either. Neither comes back by itself: the disconnect restarts nothing, and nothing else tried here did, though Pause and Play were not tried. 1b goes silent later because its tap holds more ahead of the cursor.

**The overnight figures, corrected.** All three silences ran to the end of their session, so they measured the time left, not a stall: `b10-phases-s3` 26.4 s, `s-ph1-s1` 90.0 s, `s-ph1-s4` 22.2 s. The next session of the launch was clean in the two that had one, under 1b, where a session's end moves the renderer. `s-ph1-s4` began at the restore (01:13:13), so a restore can stop a running pump too. In the attended runs the pump had already stopped at the connect, so they say nothing about that direction.

**The gate.** `CardClockAudio.stage1b` is read once. It is checked in `cardLockApplies`, so with it off that is never true with sound: the renderer never moves, `audioSynchronizer` stays nil, and the re-read, the anchor and the second rate write cannot run. It is checked again in `cardClockTick`, to keep 1a's release reason and leave the steering alone.

| | Gate off, `g-off` | `d7a4e93`, `g-ref` |
|---|---|---|
| 600 s pulls | 36327 | 36324 |
| Pull repeats, skips | 0, **1** | 0, 0 |
| File, Scarlett | +7.55, +7.55 ppm | +7.73, +7.73 ppm |
| Card (b) | −11.04 ppm | −10.88 ppm |
| `[CARDLOCK]` lines, renderer moves, re-anchors | 0, 0, 0 | 0, 0, 0 |
| SDI real, silence, underruns | 601.1 s, 5.1 s, 0 | 601.1 s, 5.1 s, 0 |
| Late, dropped | 0, 0 | 0, 0 |

Both run at 18.6 ppm of drift, which is 0.67 of a frame in 600 s, so 0 or 1 slip is what an unlocked 10 minutes gives. The one skip fits that; a single pair of runs cannot show the rates equal. `g-off-noaudio`, 90 s: 1a's lock still latches, 11 `[CARDLOCK]` lines, no renderer move, dropped 1 (the frame-4 case). Tests 0 failures. Release: `CARDLOCK]` 7, `[CARDCLOCK` 0, `[TRANSPORT]` 0, `[CADENCE]` 0, as B17, and `MANIFOLD_CARDLOCK_1B` 1.

**The three freezes, from the logs.** All three are 1b: the gate did not yet exist, and all had the renderer moved and the card lock on.

| Run | Since the last Play | Capture | Decode path | Build |
|---|---|---|---|---|
| `b12-libav` | 47.1 s, first Play of the launch | Closed | libav | Before the re-read fix |
| `b1-5994-r2` | 1998.9 s, first Play of the launch | Closed | AVFoundation | Before the re-read fix |
| `f-ph1` s4 | 43.2 s, fourth Play of the launch | **Open**, 12.1 s after it opened | AVFoundation | With the fix |

127 Plays in the 49 logs of sound-locked running. Counting running pulls gives 39,375 s, against §10.12's "about 37,000". **Two of the three came with capture closed, so capture is not needed for a freeze.**

**The freeze hunt, 2026-11-07 15:10–21:10.** `cardlock-hunt.py` (scripts README) runs Plays of 120 s each, from random points in `cc-5994-2450s.mov`: sound on, destination SDI, 59.94, capture closed. A freeze is detected from the pulls (frame number unchanged for 2 s). On detection it captures `sample <pid> 10`, the last 60 s of logs and whether the window picture is frozen, then quits by PID, runs the guard and relaunches. No spindump: it needs root, and the optional root watcher was not running. Captures are in `build/cardclock/hunt/`.

| Case | Gate | Hours | Plays | Freezes |
|---|---|---|---|---|
| (a) | On (`MANIFOLD_CARDLOCK_1B=1`) | 2.90 | 88 | **1**: Play 70, 17.7 s after Play, 8301 s into the launch (`hunt/a-1/`) |
| (b) | Off | 2.92 | 88 | 0 |
| (c) | — | not run: the plan ran it only if (a) and (b) were both clean | | |

Gate on, the launch that froze logged 966 `[CARDLOCK]` lines and 70 re-anchors. Gate off logged 0 and 0, with SDI audio flowing (10,383 PCM branch lines). Jump was never connected during the hunt: the default output stayed on the Scarlett throughout (`hunt/*.defout`).

**What the freeze is (`a-1`).** The video side stops while everything else runs on.
- **The pulls:** from host 249032.846 they return pts 1978.693383 indefinitely, while the picture clock in the same lines runs on (1979.9 → 1996.9 over the next 17 s).
- **The window:** last presents that frame and then presents nothing (`window_frozen` true).
- **The audio tap:** keeps reading at 1:1 (pts 1979.8 → 1998.8, `held≈192000f` steady).
- **SDI audio:** the bridge follows the picture, logs five `RESYNC`s snapping its cursor back to 1978.79 s, then underruns. SDI audio goes silent as a consequence of the stopped picture, not on its own.
- **The pacing renderer:** the system log shows its image queue empty at 17:32:44.285 ("iq unconsumed: 0"). It took 48 frames in that second instead of 60, so frames stopped arriving at about host 249032.75.
- **The video reader:** its decoder (VMC `R/UD.t1`), which logs 361 frames every 6 s, logs nothing after 17:32:42.584.
- **Errors:** none from AVFoundation, the reader or the renderer, before or after.
- **What the app was doing:** no transport command, rate write or re-anchor at that moment. The nearest steering writes are at host 249031.942 and 249032.943, 0.2 s either side.

**The stack.** Compared with `hunt/forced-1/`, a healthy gate-ON Play sampled the same way:
- **No thread is blocked.** Main sits in its run loop. CoreMedia's video threads (`videomediaconverter` ×3, `videomentor` ×2) wait on their condition variables, as they do in the healthy sample. The audio pump ran in 4 of the 10 s samples.
- **What is missing:**
  - `com.graviton.manifold.pump.video`: 34 samples healthy, **0** frozen.
  - `AVSampleBufferVideoRenderer videoQueue`: 3 healthy, 0 frozen.
  - `com.apple.coremedia.videoqueue.notification`: 4 healthy, 0 frozen.
  - `videomediaconverter.inbound`: 6 healthy, 0 frozen.
  - `com.Metal.CommandQueueDispatch`: 759 healthy, 0 frozen.
- **So it is a pump that is never called, not a deadlock.** The video pump (`FileFrameSource.start`, `FileFrameSource.swift:110-136`; the libav one at `LibavFrameSource.swift:472-488` has the same shape) runs only from the pacing renderer's `requestMediaDataWhenReady` block, or from a `VideoSinkGate` resume. It has three ways to go quiet, none of which logs:
  1. **The pacing renderer stops calling back.** Nothing on the pump's path reads its `status`, its `error` or `requiresFlushToResumeDecoding`. The engine enqueues to it directly (`FrameEngine.swift:2935`, `:4812`). The app's one `status` check, `SampleBufferSurfaceView.swift:45`, is in the view's own `enqueue`, which the pump does not use.
  2. **The pump parks on the gate and is never resumed.** Unlikely: `park` re-checks for room after parking (`VideoSinkGate.swift`). The window queue must have been empty, since it presented nothing as the clock ran past, so the gate had room.
  3. **The pump takes its end-of-stream branch** (`rdr.status != .reading` or a nil frame) and calls `stopRequestingMediaData`. Mid-file, with no reader error logged.

  The stack cannot tell these apart, because all three leave the same idle threads.

**All four freezes have the same signature.** Tonight's plus the three from the logs: pts stuck while the clock runs on.

| Run | Stuck | Clock ran on | Audio tap |
|---|---|---|---|
| `b12-libav` | 255.9 s at pts 47.014 | 254.0 s | (libav, no AVF tap line) |
| `b1-5994-r2` | 404.2 s at 1998.780 | 402.2 s | 2001.8 → 2403.8, running |
| `f-ph1` | 54.4 s at 330.046 | 52.7 s | 332.7 → 383.7, running |
| `hunt/a-1` | to detection at pts 1978.693 | yes | 1979.8 → 1998.8, running |

One freeze on libav rules out the AVAssetReader as the cause. What the two decode paths share is the pacing renderer's ready callback, the gate, and the synchronizer the card steering writes.

**Against the Jump stall (step 1).** No stack was taken during a Jump stall, so the stack comparison was NOT done. From the logs the two are opposites:
- **Jump:** the audio pump stops (tap pts frozen at 44.27 and 41.28) while the picture plays on at 60 fps with pulls normal.
- **Freeze:** the video pump stops while the audio tap reads on.

A freeze is not a permanent version of the Jump stall. The freeze stack does not point at the audio pump, so the tap-lead doubling stays uninvestigated, as decided above.

⚠️ **Superseded 2026-11-08: the freeze is not 1b's.** The first gate-off block of the interleaved hunt froze (§10.14), with no steering write and no renderer move. It is now the top 1.0 bug (`BUGS.md`). The reading below is kept as written.

**The reading.** By the brief's rule, (a) froze and (b) did not, so the freeze is 1b's. The evidence is thin, though:
- **Counts:** one freeze in (a) against none in (b). If the two had the same rate, 0 in (b) would happen 37% of the time (Poisson, mean 1).
- **The four freezes together:** all four came with the renderer moved and the lock on. That is about 49,800 s of 1b running, one freeze per 3.5 h.
- **Without 1b:** 2.92 h of gate-off running here, plus §10.13's two 10-minute gate runs, all clean.
- **The only mechanism difference in the data:**
  - Gate on, the steering writes `setRate(1, time:, atHostTime:)` to the picture's synchronizer once a second. CoreMedia carries out each write by setting the timebase to rate 0 and then back to 1. The system log shows the video queue's "Effective Timebase Rate … changed to: 0.000" then "1.000" every second (`hunt/a-1/system-process.log`).
  - Gate off, there are no such writes.
  - This freeze began 0.2 s away from a write, so the timing does not tie it to one, and the link is a correlation, not a shown cause.

**To confirm:**
- **(i) Gate-off hours.** About 10.5 h of gate-off cycling, three times the 1b mean interval, gives a 95% chance of at least one freeze if gate off freezes at 1b's rate.
- **(ii) Instrumentation, so the next freeze names its branch.** Log when the pump parks and resumes, when it takes the end-of-stream branch, and, once pts has been stuck 2 s, the pacing renderer's `isReadyForMoreMediaData`, `status`, `error` and `requiresFlushToResumeDecoding`.

### 10.14 Freeze: instrumentation and the re-anchor stress, 2026-11-07/08

Measure only, no fix (Robbie, 2026-11-07). Guarded Profile measurement builds (`-DMANIFOLD_CARDCLOCK`), launched by absolute path, quit by PID, no keystrokes. Nothing committed at the time of the runs.

**Instrumentation (ii above), built.** `PumpWatch.swift`, the two video pumps (`FileFrameSource.start`, `LibavFrameSource.arm`) and `FrameEngine`'s freeze watch, all behind `#if MANIFOLD_CARDCLOCK`. DEBUG never reaches ManifoldCore in Profile (`project.yml`, the `configs:` note), so that flag is the package's measurement-only switch. On the pre-ship removal list (`BUGS.md`).
- **Logged as it happens:** the end-of-stream branch, with the reader's status and error (branch 3). A park on a full window queue that lasts 1 s or more (branch 2). The pacing renderer reading `.failed` at a pump exit, and its `didFailToDecode` and `requiresFlushToResumeDecodingDidChange` notifications (branch 1).
- **Counted:** the two exits meant to be quiet, a superseded session and a released libav source, so a freeze that takes one is not missed.
- **Once the picture has been stuck 2 s** (no frame out of the pump, or the newest frame 2 s behind the clock), and again at 10 s: `[PUMPWATCH] PICTURE STUCK`, with the branch it names, the pacing renderer's status, error, `isReadyForMoreMediaData`, `requiresFlushToResumeDecoding`, and its timebase's rate and time; the synchronizer's rate; the audio clock; the pump's callback count, last callback, last exit, parks; the reader; and the time since the last steering write.
- **Checked against a known answer:** `MANIFOLD_PUMPWATCH_SELFTEST=20` stops the renderer's request 20 s into play. The report came at 2.00 s and 10.01 s and named branch 1, "stopped calling back (ready, no callback for 2.000 s)", with status 1, no error, ready true, timebase rate 0.999989 (`hunt/selftest-1/`, `hunt/selftest-L1.log`). The hunt detected the same freeze from the pulls at 2.2 s. The steering was at 10 Hz: 219 writes in the 22 s.
- **The normal Profile build** (no flag) compiles and holds none of the strings.

**The stress (step 3).** `MANIFOLD_CARDLOCK_STEER_HZ` (measurement build; 1–60, default 1) sets the steering timer, leeway scaled with it. The steering itself is cadence-free (`CardClockSteering.tick`), so nothing else changed. `cardlock-hunt.py cycle on`, `HUNT_STOP_FIRST=1`: gate on, `cc-5994-2450s.mov` (sound), destination SDI, 59.94, capture closed, Plays of 120 s from random points, freeze from the pulls, as §10.13.

| Rate | Hours run | Plays | Rate-0 dips of the video queue | Freezes | `[PUMPWATCH]` | Lock |
|---|---|---|---|---|---|---|
| 10 Hz (`hz10`) | 0.97 (3477 s) | 29 | 34,783, 10 a second (median) | **0** | 0 lines | 29 latches, error worst 136.6 µs in a 10 s window, 0 evictions, SDI audio on PCM throughout |
| 20 Hz (`hz20`) | 0.97 (3480 s) | 29 | 69,604, 20 a second (median) | **0** | 0 lines | 29 latches, error worst 125.0 µs, 0 evictions, SDI audio on PCM throughout |
| 1 Hz, for comparison (§10.13 (a)) | 2.90 | 88 | about 10,400 | 1 | — | |

- **The suspect was really driven.** The dips are CoreMedia's own "Effective Timebase Rate of videoqueue changed to: 0.000" lines for each build's PID, from `/usr/bin/log show` (`hunt/tb-28175.log.gz`, `tb-61684.log.gz`; a 74 s 20 Hz check, `tb-95691.log.gz`, the same). Each write is still one trip through rate 0 at 20 Hz: CoreMedia does not merge them.
- **Against the hypothesis that each trip through 0 is a trigger:** the 1 Hz freezes give about one per 49,800 dips (four freezes in about 49,800 s). That predicts 0.70 freezes at 10 Hz and 1.40 at 20 Hz, 2.1 together. None came. If the hypothesis held, that would happen 12% of the time (Poisson). Against "one per 3.5 h of running", whatever the rate, 1.93 h expects 0.55, and none happens 58% of the time.
- **So by the brief's rule: not much faster than one per 3.5 h.** No freeze at 10 or 20 Hz in an hour each. The trip through rate 0 is not shown to be the trigger, and a strong per-write trigger is unlikely (12%). A weak or rate-independent dependence on the writes is not ruled out. No exit was taken, so no steering change is proposed.
- **Next, per the brief, not started:** the 10.5 h of gate-off cycling (i above), now with the freeze watch in the build, so a freeze on either gate names its branch.

⚠️ **A measuring note.** In zsh, `log` is a shell builtin, so `log show …` typed in a zsh command fails ("too many arguments"), and with stderr discarded it reads as "no lines". Use `/usr/bin/log`. `cardlock-hunt.py` runs it from Python, which finds `/usr/bin/log`, so its captures were never affected.

**A candidate to check at any freeze: the 0.9.1 decode backpressure (`VideoSinkGate`)** (Robbie, 2026-11-08). The pump parks waiting for window-queue space and is never woken, perhaps because a wake-up is lost when a queue is flushed at Play. Checked two ways.
- **In the code, before the hunt.** `park` checks for room again after it parks (`VideoSinkGate.swift`), so room freed between the pump's check and the park is not missed. Every path that takes a file's frames out of the window queue signals the gate: the flush (`App/MetalVideoRenderer.swift:3168`), a tick that takes a frame (`:3678`) and the paused relaxed render (`:3783`). The two that do not signal are the live hold floor (`:3621`, never a file) and the overflow trim inside `enqueue` (`:3124`, `:3129`), which runs only from the pump's own call. 1b never flushes the video queues. The flush at Play comes from the seek before it (`FrameEngine.swift:2952`), with the gate on or off. No lost wake-up was found.
- **In the build.** The freeze watch's 2 s and 10 s reports now carry the gate's state: waiters, the window queue's depth and bound, has room, parks (and the re-check resumes among them), signals with the time of the last, and resumes by signal. Branch 2 is now named `VIDEOSINKGATE`. 1b's renderer moves and `rereadSoundAfterMove` (whether it read again or was skipped) now log with host times. All behind `#if MANIFOLD_CARDCLOCK`. Checked against the self-test (`hunt/il-selftest-1/`, `il-selftest-L1.log`): reports at 2.01 s and 10.01 s naming branch 1, gate waiters 0, depth 0/12, 1212 signals, 0 parks in 20 s of 59.94 play.
- **At the freeze below: not the gate.** Waiters 0, depth 0/12, has room yes. The last park was 1043.6 s before the report, which is 0.3 s after the launch's first Play. The last signal was 2.05 s before it, at 2 s; at 10 s, 10.05 s.

**The interleaved hunt, 2026-11-08 06:03–06:21: the first block, gate OFF, froze.** `cardlock-interleave.sh off 14:00 il`: one-hour `cardlock-hunt.py` blocks alternating the gate, starting OFF because OFF had the fewer hours. Plays of 60 s (`HUNT_CYCLE=60`, shortened from 120 s because three of the four freezes came 17–47 s after a Play), from random points in `cc-5994-2450s.mov`. Sound on, destination SDI, 59.94, capture closed, steering timer at 1 Hz. The rule was to stop at the first freeze on either side, so no gate-on block ran.

| Block | Gate | Hours | Plays | Freezes |
|---|---|---|---|---|
| `il-off1` | Off | 0.28 (994 s) | 17 | **1**: Play 17, 31.9 s after Play (`hunt/il-off1-1/`) |

**What it took: branch 1, the pacing renderer not ready and never draining.** Both reports, 2.18 s and 10.18 s, read the same:
- **The pacing renderer:** status 1, error none, `isReadyForMoreMediaData` **false**, `requiresFlushToResumeDecoding` false, timebase rate 1.000000 and running (1696.27, then 1704.27).
- **Its own queues were empty while it said not ready:** CoreMedia logs its video queue at "sbuf queue contains 0 frames … LWM: 1.000 HWM: 2.000" (06:21:04.205, 06:21:10.206) and its image queue at "iq unconsumed: 0" (06:21:04.363). Before the stop the queue held 1 frame and the image queue 5–6, every 6 s.
- **The pump:** last exit "renderer not ready (waiting for its callback)", 2.183 s before the report. No callback since. 18 arms, 69,369 callbacks, 59,561 frames emitted, 0 ends of stream, 0 quiet exits. The reader: AVF status 1, no error.
- **The last frame out:** pts 1694.209183, about 0.13 s ahead of the clock (the renderer's normal lead). So the pump stopped because the renderer said not ready with a normal lead, and the renderer then played out what it held and never asked again.
- **The steering:** "last write never (0 writes), steered no". With the gate off and sound, `cardLockApplies` is false, so nothing writes the synchronizer.
- **1b at that Play:** nothing. The log has 0 `1b move` and 0 `1b re-read` lines, and its only `[CARDLOCK]` line is the steering-rate banner.
- **The stack (`sample`):** as `a-1`. No `com.graviton.manifold.pump.video` thread, no `AVSampleBufferVideoRenderer videoQueue`, no `videomediaconverter.inbound`, no `com.Metal.CommandQueueDispatch`. The CoreMedia video threads wait on their condition variables. Nothing is blocked.
- **The rest:** the window froze (`window_frozen` true). The audio tap read on, the bridge logged six `RESYNC`s back to 1694.30 s, and the default output stayed on the Scarlett (`il-off1-L1.defout`). No error from AVFoundation, the reader or the renderer. Play 17 itself was a normal start: CoreMedia's image queue flushed 7 frames at the Play, as at every Play.

**So the freeze is not 1b's.** Today's path, with no steering write, no renderer move and no 1b re-read, freezes the same way: the same pts-stuck-while-the-clock-runs signature as all four earlier freezes, and the same stack as `a-1`. This overturns §10.13's reading ("by the brief's rule, the freeze is 1b's"). That reading rested on 1 freeze against 0, a split that equal rates give 37% of the time. The steering write's trip through rate 0, the stress suspect, is ruled out as a cause, since this freeze had no writes at all. `a-1` never named its branch, so whether `a-1` was also "not ready and not draining" is UNKNOWN; its renderer read the same way in §10.12 (`isReadyForMoreMediaData` false, queue empty, status 1). Whether shipped 0.9.2 freezes is UNKNOWN: gate off matches `d7a4e93` (§10.13 "The gate"), not a 0.9.2 build.

**Totals, every sound-locked hunt and log, at 59.94 unless the source says not:**

| | Running | Plays | Freezes | One per |
|---|---|---|---|---|
| Gate on / 1b: §10.13's logs (39,375 s, 127 Plays, 3), hunt (a) (2.90 h, 88, 1), `hz10` (0.97 h, 29, 0), `hz20` (0.97 h, 29, 0) | 15.77 h | 273 | 4 | 3.9 h, 68 Plays |
| Gate off / today's path: hunt (b) (2.92 h, 88, 0), `g-off` (600 s, 1 Play), `il-off1` (0.28 h, 17, 1) | 3.36 h | 106 | 1 | 3.4 h, 106 Plays |

If the two run at the same rate, 3.36 h of 19.13 h would hold at least one of the five freezes 62% of the time. The data cannot tell the rates apart.

**An aside, not the freeze: parks before the first Play.** The pump parked 9836 times and was woken by a signal once. All of the parks came before the launch's first Play was 0.3 s old, and none in the 17 Plays after. Each park overwrites the gate's single slot, so this reads as the renderer calling back repeatedly while the paused window queue is full, but how long it lasted and what it costs is UNKNOWN (PumpWatch logs only parks of 1 s or more, and none was).

**Next, not started (measure only):** the branch is now named. What is still UNKNOWN is why AVSampleBufferVideoRenderer reads not ready with empty queues and never calls back. In the logs that freeze is not tied to the gate, steering, a renderer move, a decoder error, an output change or Jump.

**Decided (Robbie, 2026-11-08):** the freeze is pre-existing (gate off, `d7a4e93`; almost certainly in 0.9.2), and is now the top 1.0 bug, above the card-clock slips (`BUGS.md`). 1b is cleared of it.

### 10.15 The picture freeze: reading for the cause, the watchdog, before and after, 2026-11-08

**The reading: every call on the pacing renderer.** The pacing renderer is the `AVSampleBufferDisplayLayer`'s `sampleBufferRenderer` in each window (`App/ContentView.swift:1209-1212`), under the Metal surface, attached to the engine's synchronizer (`FrameEngine.attach(renderer:)`). The live routes' `renderer.flush()` calls (`App/Live/LiveDisplayRoute.swift:229`, `SyntheticLiveSource.swift:224`) are the Metal renderer's, not this one. What touches it:

| Call | Where | Thread |
|---|---|---|
| `requestMediaDataWhenReady` | `FileFrameSource.start` (AVF), `LibavFrameSource.arm` (libav) | main (the block runs on `videoPumpQueue`) |
| `stopRequestingMediaData` | `FileFrameSource.stop`; `beginLibavReading`; the pump's end-of-stream branch | main; the pump queue for end-of-stream |
| `flush` | `beginReading` (every seek, step, loop, load), `beginLibavReading`, `stop()`, `retirePreviousPicture` | main |
| `enqueue` | the session's `onVideoFrame` closure, from the pump | `videoPumpQueue` |
| `isReadyForMoreMediaData` | the pump's `while` loop | `videoPumpQueue` |

Play, pause and shuttle only set the synchronizer's rate (`setShuttleRate` → `setTransportRate`). Scrub runs its own producer and does not touch this renderer. Output start and stop touch only the card-clock state, and with sound and the gate off they change nothing here. Loop and step go through `beginReading`.

**The order at a seek, then Play** (the hunt's `seek X; wait 2; play`): `seek(to:)` → `Task { beginReading }` on main: (1) the session token is bumped; (2) rate 0; (3) the old source's `stop()`, i.e. `stopRequestingMediaData`; (4) the audio teardown; (5) the old reader's cancel queued behind both pump queues; (6) `flush()` and the window's `onFlush`; (7) the new reader is built and started; (8) `parkTransport(at: start)`; (9) the new source's `start()`, i.e. `requestMediaDataWhenReady` on `videoPumpQueue`; (10) `await beginAudioReading`. The pump fills the renderer while paused. Two seconds later `play()` sets the rate to 1. Nothing else touches the renderer until the next seek.

**The four things looked for:**
- **A request not re-armed after a flush or a stop:** none. Every flush on a live session is followed by an arm in the same main-actor function (`beginReading`, `beginLibavReading`). `stop()` and `retirePreviousPicture` end the session on purpose.
- **A re-arm racing a flush on another queue:** arm, stop and flush all run on main, in order. The one cross-queue race found: the old session's pump can pass its post-decode `guard current()` (`FileFrameSource.swift`, before `emit`) just before main bumps the token and flushes, and then enqueue one frame from the old position into the flushed renderer and the window queue. That frame's pts is from the old position. Seeking backwards it waits in the queue until the clock reaches it; seeking forwards it is late at once. Either way it is gone within the seek distance, the queues are not empty while it waits, and it happens at a seek, not 17–2000 s into play. **It cannot produce the freeze's state or its timing.** A real defect, recorded, not fixed here.
- **A callback that returns early without re-arming:** the superseded exits (a newer session has armed) and the end-of-stream exit (stops on purpose) are correct. The gate's park returns while the renderer is ready and relies on the gate or on AVFoundation calling again. `il-off1` shows the second happens: 9,836 parks before the first Play, the renderer calling back each time. The freeze did not take this exit.
- **Relying on `isReadyForMoreMediaData` without a callback:** the gate's resume runs the pump body, which tests readiness and, if not ready, returns to wait for the renderer's callback, which is still armed. Correct by AVFoundation's contract.

**So no cause was found by reading.** In steady play the only actors on the renderer are our pump (enqueue, readiness) and AVFoundation/CoreMedia. At the freeze the pump's last exit was "not ready", which is the contract working, and the renderer then never called back while CoreMedia logged both its queues empty. That is the renderer's state, not something our ordering left behind. Why it gets there is UNKNOWN.

**The watchdog (production code, every build).** `PacingRendererWatchdog.swift` (`RendererActivity`, `RendererRecoveryStats`) and `FrameEngine.rendererWatchdogTick`. Both pumps record their arms and callbacks, and both emit closures record each enqueue.
- **Polling:** every 50 ms on main, only while a file plays.
- **The state:** the renderer not ready, and nothing of ours pending in it, meaning its timebase is a frame past the last frame we enqueued (or nothing has been enqueued 0.25 s after an arm), and the pump has not ended. Healthy play keeps the renderer 0.1–0.2 s ahead, and a renderer with nothing ahead is ready, so the state should not occur there.
- **Near-miss:** the state lasts over 100 ms and clears by itself. One `[RENDERER-NEARMISS]` line and a count.
- **Recovery:** the state holds and no pump callback has come for 500 ms. One `[RENDERER-RECOVER]` line with the state, and a count. Then the renderer is flushed and its request re-armed on the same session: `FileFrameSource.stop`/`start` or `LibavFrameSource.rearm`, which re-arms without a seek. The reader carries on where it was, and the sound is not touched. If a re-arm brings no frame within 1 s it is tried again. After three, the session is rebuilt at the clock (`beginReading`), once, and then it gives up, so a renderer that will not drain cannot make it loop. Each step logs.
- **Export Diagnostics:** a *PICTURE RECOVERY* section with the counts and the last recovery line. Both tags are in `LogPartitioner`.
- **Measurement build only:** `MANIFOLD_RENDERER_RECOVER=0` detects but does not recover, for the before-rate. `MANIFOLD_RENDERER_SELFTEST=recover:<s>|nearmiss:<s>` stops the request and forces the watchdog to read not-ready, so it can be checked against a known answer.
- **Builds:** Release without the flag compiles. It has the `RENDERER-RECOVER`/`NEARMISS` strings and none of `RENDERER-SELFTEST`, `MANIFOLD_RENDERER_RECOVER` or `PUMPWATCH`. `swift test`: all tests passed.

**Self-tests (`build/cardclock/hunt/wd-st-*`):**

| Test | Result |
|---|---|
| `recover:20`, output on | Recovery fired 0.510 s after the last callback (in the state 0.345 s). First frame 37 ms after the re-arm. Picture moving 0.400 s after the stall began |
| `nearmiss:20`, output on | `[RENDERER-NEARMISS]` 196 ms, cleared by itself. No recovery |
| `recover:20`, `MANIFOLD_RENDERER_RECOVER=0`, output off | One "DISABLED … would recover now" line at 0.515 s, no recovery. `[PUMPWATCH] PICTURE STUCK` at 2.05 s and 10.05 s, and the hunt's no-output mode detected it as a freeze |

The self-test forces only the watchdog's reading of readiness. The renderer was never really in the freeze's state, so a real stall's recovery is first seen in the runs below.

**Before and after** (`cardlock-hunt.py cycle`, 60 s Plays from random points, seeks between, `cc-5994-2450s.mov` with sound, destination SDI, 59.94, capture closed; 2026-11-08 13:47 → 2026-11-09 07:00; logs `build/cardclock/hunt/wd-*`). No separate fix exists, so "fix and watchdog off/on" is watchdog off/on (`MANIFOLD_RENDERER_RECOVER=0` / unset); near-miss logging on throughout.

| Stage | Watchdog | Gate | DeckLink out | Played | Plays | Near-misses | Recoveries | Freezes |
|---|---|---|---|---|---|---|---|---|
| Before A (`wd-before-out`) | off | off | on | 1.88 h | 113 | 0 | — (0 would-recover) | 0 |
| Before B (`wd-before-noout`) | off | off | **off** | 0.93 h | 57 | 0 | — (0 would-recover) | 0 |
| After (`wd-after`) | on | off | on | 1.88 h | 113 | 0 | 0 | 0 |
| Overnight, gate ON (`wd-night-on1…7`) | on | on | on | 5.75 h | 353 | 0 | 1, recovered | 0 |
| Overnight, gate OFF (`wd-night-off1…6`) | on | off | on | 5.58 h | 342 | 0 | 1, recovered | 0 |

Totals: watchdog off 2.81 h / 170 Plays, nothing seen. Watchdog on 13.21 h / 808 Plays: 2 recoveries, both first-attempt, 0 rebuilds, 0 gave-ups, 0 PICTURE STUCK, 0 freezes. 0 near-misses in 16.0 h.

The two recoveries (the first real stalls the watchdog has met):

| Block | Gate | When | State at recovery | Result |
|---|---|---|---|---|
| `wd-night-on2` | on | at Play: clock 866.71, 5 preroll frames enqueued since the arm, last callback 2.22 s before (during the paused preroll); the timebase ran past all 5 with no callback | not ready, status 1, error none, requiresFlush false, rate 1 | first frame 39 ms after the re-arm, picture moving 0.150 s after the stall began (≈0.2 s after Play) |
| `wd-night-off4` | off | mid-play, ≈17.8 s in (1,069 frames since the arm), pts 1622.04 | the same, in state 0.346 s, no callback 0.524 s | first frame 47 ms after the re-arm, moving 0.394 s after the stall began; `[PLAYBACK-STATS]` shows 7 + 16 dropped over the two seconds around it |

The reading:
- Both are the freeze's state (§10.14, il-off1 and hunt/a-1): not ready with nothing of ours ahead of the timebase, no error, no flush requested. One at Play (as hunt/a-1), one mid-play (as il-off1). One with the gate on, one with it off: no gate dependence, consistent with "not 1b's".
- Near-misses: 0 in 16 h. The state does not clear by itself; when the renderer reaches it, it stays. So the near-miss rate cannot be compared output on vs off: 0 in both (1.88 h and 0.93 h). Nor did a stall occur in either "before" stage (2.81 h, at a rate of about 1 per 6–7 h seen overnight, 0 was the likely outcome). Whether the card or chassis is involved is UNKNOWN from these runs.
- Rate: 2 stalls in 13.2 watchdog-on hours (≈1 per 6.6 h, ≈1 per 400 Plays), every one recovered on the first re-arm. Without the watchdog each would have been a permanent freeze. The visible cost is a hitch of 0.2–0.5 s.
- Disturbances, for reading the logs: Discord ran 18:01:06–18:04:45 on 2026-11-08 (one dropped frame at its launch) and a browser played audio about 18:10–18:18, both in `wd-after`; nothing reacted. No SDI audio underrun in any stage.

### 10.16 Stage 1c, measure only: SDI audio on the wire, 2026-11-10

Overnight, unattended, measure only (Robbie, 2026-11-10). No fix, no shipped-code change, nothing committed. Guarded Profile measurement builds, launched by absolute path, held by PID, quit by PID, no keystrokes.

**Results in brief (§10.16–§10.18).**
- **SDI audio is not sample-continuous, on the wire.** Every anchor-loop correction reaches SDI one for one (310,846 of 310,847 matched to the sample): 43 skips or repeats of 1–2 samples a second, at 59.94 and 23.976, gate off and on. Nothing else breaks it in steady play.
- **SDI sound is 2.5 frames late against its own picture**, steadily: −42.4 ms at 59.94, −104.6 ms at 23.976. New.
- **After Play:** gate off, every Play from 0 jumps −106 to −146 ms on the wire 1.2–2.2 s in (the logged RESYNC); mid-file Plays and all gate-on Plays have no jump, and gate on slews in for up to 33 s instead.
- **The default-output stall is any default-output change, not Jump** (5 of 5): the renderer is flushed automatically and never calls the pump again; a seek restarts it, Pause and Play do not.
- **Renderer stalls:** 1 recovery in 1.57 h with output on, 0 in 1.57 h with it off. Too few to say whether the card matters.

**Baseline going in.** The build-25 recovery runs of 2026-11-09 read SDI audio off the wire but were never written up here (`capture.cpp`'s pointer to §10.16 means them; their logs are in `~/Code/_scratch/manifold-recovery-audio/runs/`). Five runs at 59.94, gate off, about 40 s of play each, read again tonight with this section's analyser (`sdi-1`): 1683 discontinuities in 40 s of play, every one ±1 or ±2 samples (42 a second) except **one jump of −6490 samples (−135.2 ms) 1.44 s after the first sound**, which is the bridge's logged RESYNC (−135.0 ms). Offset at the first sound +93.4 ms (sound ahead of the picture), settled at about −42 ms by 5 s.

**Method.**
- **Fixtures** (`~/Code/_scratch/manifold-1c-wire/mkfixture.sh`): the linkpace marker band and the picture number on flat grey, ProRes 422 Proxy, 1920 s, at 59.94 and 23.976, 48 kHz 24-bit stereo carrying **seeded white noise** (−26 dBFS peak, the same in both channels). Any 2 samples of it are all but unique, so every received sample is located in the source.
- **Runs** (`scripts/decklink-loopback/w1c-run.py`): destination SDI, output on, `capture --audio --marks` open from before Play to after Pause, so every received picture and sample is kept. `cont`: one Play from 0, 1800 s, Pause. `plays`: 20 cycles of seek 0, Play 60 s, Pause, Play 60 s from where it paused, Pause: 20 Plays from 0 and 20 mid-file. Gate off is `MANIFOLD_CARDLOCK_1B` unset (as build 25 ships); gate on is `=1`.
- **Analysis** (`w1c-wire.py`): walks the capture sample by sample against the source. A **discontinuity** is any place where the next received sample is not the next source sample: a step of d samples (+ skipped, − repeated), or digital silence. **A/V offset** at a frame: the source position of that frame's first received sample minus the frame's picture × samples per picture, in ms; positive means the sound is ahead of its picture.
- **The bridge's own log, one line per callback.** The once-a-second `DeckLinkAudio:` line shows one callback in about 50, which is what the 84–87 % figure (§10.3) samples. New measurement hook `[AUDIO-CORR]` (`DeckLinkBridge.mm`, `#ifdef DEBUG`, `MANIFOLD_AUDIO_CORR_LOG=1`; on the pre-ship list): every callback that schedules PCM logs the card stream position of its first sample, the samples taken, its correction and its kind (steering, anchor snap, resync). Each correction then has an exact place on the wire to be looked for.
- **`capture` moves the card's output clock while its input is open (§5).** That is acceptable here: continuity and A/V offset are both read on the same wire, from the same received samples and pictures. It makes the card's rate, and so the gate-off slip count, a capture value, not a customer's.

**Predictions, written 2026-11-10 00:50, before any run.**

| # | Run | Prediction |
|---|---|---|
| W1 | `cont`, 1800 s, each of 59.94 and 23.976, gate off and on | **Every bridge correction reaches the wire, one for one:** a step of exactly its size at exactly its sample, in at least 99 % of nonzero corrections. No wire step without a correction at that sample. About 42 steps a second at both rates (the callback runs on the card's audio, not the frame rate): 70,000–80,000 per run, all ±1 or ±2 samples (21–42 µs each) |
| W2 | The same | After the first 5 s: **0 jumps over 8 samples, 0 silences, 0 resyncs, 0 underruns** until Pause |
| W3 | The same, gate off | Picture slips on the wire at the rate the card's capture-set rate gives against the file clock: 0 to about 14 per run at 59.94, 0 to about 6 at 23.976. **Each slip moves the A/V offset by one frame** (16.7 ms, 41.7 ms) at the slip, and the ±2 steps walk it back at about 2 ms/s: back within 1 ms in about 8 s at 59.94 and 20 s at 23.976, with no jump and no resync. Net of the small steps over the run equals the picture's own drift against the card, slips included, to within one frame of samples |
| W4 | The same, gate on | **0 picture slips** (card lock, B10). Net of the small steps within ±100 samples of 0 |
| W5 | Steady A/V offset, after 60 s | 59.94: median −42 ± 3 ms, both gates. 23.976: **about −104 ms** (−90 to −120), on the guess that the bridge's model misses by about 2.5 frames of video queue, not by a fixed time. If it is a fixed time, −42 |
| W6 | `plays`, 59.94, 40 Plays per gate | **At least 36 of 40 Plays per gate show the resync as one jump on the wire** of −125 to −146 ms, 1.2–2.0 s after the first sound, each a logged RESYNC. A Play without one slews instead (smoothed error peaking under 100 ms), at the loop's 2 ms/s, for up to about 45 s (`p7`, §10.3) |
| W7 | The same | First-sound offset +85 to +100 ms. After the jump −45 to −62 ms, then a walk to the final value: within ±1 ms of it by 15 s after the first sound. Final −40 to −46 ms |
| W8 | The same | Audible-class events, per Play: the jump only. **Silence over 5 ms after the first sound: 0.** Jumps over 1 ms other than the resync: 0 |
| W9 | Gate on against off | The same on the wire. 1b's audio-clock re-anchor (−70 to −81 ms, 2–6 s after Play, B4) does **not** reach SDI: the bridge anchors to the staged picture, not to the Mac renderer. Picture at Play: gate on, 40 of 40 clean (B18); gate off, mid-file Plays skip or repeat as §10.10 (about 13 of 20 not clean), Plays from 0 clean |
| W10 | From 0 against mid-file | Same first-sound offset and same jump |

**Runs.** 2026-11-10 00:47–04:20, 7 launches (a 45 s smoke run, then the six below), all guarded before and after, no guard tripped, `/Applications/Manifold.app` not run, Resolve not running, the default output the Scarlett throughout (`defout` logs). One measurement build for all of them: `-DMANIFOLD_CARDCLOCK`, `.build-cc`, the tree at `452f697` plus the `[AUDIO-CORR]` hook. Capture dropped nothing; every picture mark read, except one line cut short when `capture` was stopped.

#### Continuity: 1800 s of play each (`c5994-off`, `c2398-off`, `c5994-on`, `c2398-on`)

| Run | Wire steps in play | Per second | −2 / −1 / +1 / +2 | Bridge: nonzero corrections of its callbacks | Found on the wire at their sample and size | Wire steps with no correction | Jumps over 8 samples | Silence in play | Picture slips | Steady offset after 60 s, median (p1 / p99) |
|---|---|---|---|---|---|---|---|---|---|---|
| 59.94, gate off | 78,113 | 43.4 | 26,340 / 10,697 / 13,714 / 27,361 | 78,112 of 89,999 (86.8 %) | **78,112 (100 %)** | 0 | 1, the RESYNC at Play | 0 | 6 skips | −42.38 ms (−52.85 / −40.53) |
| 23.976, gate off | 77,779 | 43.2 | 25,018 / 12,357 / 11,032 / 29,372 | 77,779 of 89,995 (86.4 %) | **77,779 (100 %)** | 0 | 0 | 0 | 4 skips | −104.65 ms (−136.83 / −103.31) |
| 59.94, gate on | 77,790 | 43.2 | 27,704 / 10,843 / 14,132 / 25,111 | 77,790 of 89,999 (86.4 %) | **77,789**, and 1 one sample later at the same size | 0 | 0 | 0 | **0** | −42.35 ms (−43.68 / −40.57) |
| 23.976, gate on | 77,166 | 42.9 | 26,254 / 12,665 / 11,561 / 26,686 | 77,166 of 89,995 (85.7 %) | **77,166 (100 %)** | 0 | 0 | 0 | **0** | −104.62 ms (−106.21 / −103.33) |

- **Every correction the anchor loop makes reaches the wire, one for one: 310,846 of 310,847 at exactly the logged sample and size, the last one sample later.** No discontinuity on the wire came from anywhere else. So SDI audio is not sample-continuous: in steady play it skips or repeats 1 or 2 samples **43 times a second, about 78,000 times in 30 minutes, at both rates and both gates.** Each step is 21 or 42 µs of content. Whether that is audible is UNKNOWN: nobody listened, and in white noise it cannot be heard by construction. On a pure tone it is a phase step of up to 2 samples.
- **The 84–87 % of §10.3 was a fair sample.** Counting every callback, 85.7–86.8 % carry a correction.
- **Two corrections can sit 9–12 samples apart.** The bridge sometimes runs a callback of only 9–12 samples (5 in the four runs, e.g. `n=12` at stream 555784), and it applies its own ±2 to that one as well. Seen first as three unlocated places in `c2398-off`; the analyser now verifies on 6 samples there, and all three are logged corrections.
- **In steady play: 0 jumps over 8 samples, 0 silences, 0 resyncs, 0 underruns, in all four.** The underruns in the bridge's own totals (9 in `c2398-off`, 4 in `c2398-on`, one event each) are all at Play, before the first sound: the cursor starts at source −0.03 s, where the ring has nothing, and the card is given 180 ms and 79 ms of silence. On the wire this only delays the first sound.
- **Picture slips, gate off** (capture sets the card's rate, §5): 59.94, 6 skips 266.8 s apart (62.5 ppm card against file); 23.976, 4 skips 433.6 s apart (96 ppm). **Each slip moves the offset by a frame and the ordinary ±2 steps walk it back:** at 59.94 from −42 to −58 ms and back within 1 ms in 6.7–8.5 s; at 23.976 from −104 to −146 ms and back in 19.6 s. No jump, no resync. The net of the small steps after the first minute is +4797 samples at 59.94 (6 × 800.8 = 4805) and +8029 at 23.976 (4 × 2002 = 8008): the audio follows the picture's slips and nothing else.
- **Gate on: no slip, and the net after the first minute is +66 and +2 samples.** The offset's whole p1–p99 range is 3.1 ms at 59.94 and 2.9 ms at 23.976; gate off it is 12–33 ms, because the slips are in it.
- **The steady offset: the sound is late on SDI by 2.5 frames, at both rates.** −42.4 ms is 2.54 frames at 59.94; −104.6 ms is 2.51 frames at 23.976. The bridge aims `ideal = stagedPts + audioDepth − videoDepth` at 0 and misses by two and a half frames of video. **This is new: the SDI sound has never been measured against its own picture before tonight.** Why the miss is 2.5 frames is UNKNOWN; that `videoDepth` counts `bufferedVideo + 1` frames where the frame actually waits longer is the obvious place to look, an inference. Around it the loop holds a limit cycle of about ±1.5 ms with a 3–4 s period (1 s medians), the staircase it chases.
- **The start of play differs by rate and gate** (one Play each here, from 0; the Play runs below have 40):

| Run | Offset at the first sound | Then |
|---|---|---|
| 59.94, gate off | +85.5 ms | **Jump −131.8 ms at 1.62 s** (logged RESYNC −131.0), then −48.9 → −42 by 5 s |
| 23.976, gate off | −91.7 ms | **Slew**, −2.08 ms/s, to −104 by about 6 s. No resync |
| 59.94, gate on | −3.2 ms | **Slew**, −2.08 ms/s, to −43.5 by 19 s. No resync |
| 23.976, gate on | −100.3 ms | Slew to −104.5 by 2 s |

#### After Play: 40 Plays per gate at 59.94 (`p5994-off`, `p5994-on`)

Each cycle: seek 0, Play 60 s, Pause, Play 60 s from there (mid-file, about 60 s in), Pause; 20 cycles per launch. **Settled** means the 1 s running median of the offset stays within ±2 ms of the Play's final value (the median of 49–59 s) from then on: the steady state is itself a limit cycle of about ±1.5 ms with a 3–4 s period, so a tighter test reads the cycle, not the settle.

| | Gate off, from 0 | Gate off, mid-file | Gate on, from 0 | Gate on, mid-file |
|---|---|---|---|---|
| Offset at the first sound | +74.2 to +95.5 ms (median +90.3) | −60.1 to −35.9 (median −42.7) | −33.3 to −6.7 (median −17.7) | −37.4 to −16.9 (median −26.7) |
| Resync jump on the wire | **20 of 20**: −105.9 to −146.3 ms, 1.20–2.18 s after the first sound, each one discontinuity and each a logged RESYNC | **0 of 20** | **0 of 20** | **0 of 20** |
| How it gets to the final value | the jump, then −49 to −42 by about 5 s | already there, or a short walk | **slew** at the loop's 2 ms/s | **slew** at 2 ms/s |
| Settled (median; range) | 2.1 s; 17 of 20 by 4.6 s, 3 more only cross ±2 ms later with the limit cycle (worst 2.4 ms) | 1.2 s; all by 7.5 s | 10.9 s; 3.4–32.6 s | 7.1 s; 1.6–11.3 s, 2 more at 31.9 and 41.9 s |
| Final value | −42.59 to −42.11 ms | −42.54 to −42.00 | −42.74 to −42.02 | −42.63 to −42.08 |
| Silence over 5 ms after the first sound | 0 | 0 | 0 | 0 |
| Picture at Play on the wire | 20 of 20 clean | **20 of 20 clean** | 20 of 20 clean | 20 of 20 clean |

- **Audible-class events (silence over 5 ms, or a jump over 1 ms): exactly the 20 resync jumps, one on every gate-off Play from 0, and nothing else in 80 Plays.** Between Plays, all of 103,431 (off) and 105,915 of 105,921 (on) nonzero corrections were on the wire at their sample and size, and no other step; the 6 unmatched are one place where a 5-sample callback put two corrections 5 samples apart, below the analyser's 6-sample check.
- **The jump is a jump, not a slew:** one discontinuity of 5084–7024 samples, within one callback, logged by the bridge as RESYNC (`smoothed error −100.1 to −100.8 ms exceeds 100 ms`). The bridge snaps its cursor by the same amount it logs (−106 to −146 ms).
- **Why only from 0, gate off:** at a Play from 0 the sound starts 74–96 ms *ahead* of its picture, and the anchor loop's error grows past 100 ms in 1.2–2.2 s. Mid-file the sound starts within 18 ms of its final offset and never comes near 100. Under gate on the first sound is never more than 34 ms off. What sets the +90 ms at a Play from 0 with gate off is UNKNOWN; it agrees with the build-25 runs (+93).
- **1b's audio-clock re-anchor** (logged 40 times under gate on, once per Play) **does not reach SDI:** no jump in any gate-on Play.
- **Gate on is quieter but slower.** No jump in 40 Plays, but the sound reaches its final offset by a 2 ms/s slew lasting up to 33 s, during which it is 5–36 ms less late than its final value, so nearer its picture than the steady −42 ms.
- **The picture:** 80 of 80 Plays moved +1 a frame from the first new picture. §10.10's mid-file skip and repeat on a file with sound and gate off did not appear in 20 tries here. That fixture is the noise file, seeked to 0 and paused at 60 s; §10.10 used `cc-*` with tone and Pause/Play pairs at other positions. Why it is gone here is UNKNOWN.

#### §10.16 predictions against results

| # | Result | |
|---|---|---|
| W1 | 310,846 of 310,847 corrections exact; 0 wire steps without one; 42.9–43.4 a second; 77,166–78,113 per run, all ±1 or ±2 | **Held** |
| W2 | After the first 5 s: 0 jumps, 0 silences, 0 resyncs, 0 underruns, in all four | **Held** |
| W3 | 6 and 4 slips; offset moved one frame, back in 6.7–8.5 s and 19.6 s by ±2 steps; net after the first minute equal to slips × samples per frame within 8 and 21 samples | **Held** |
| W4 | 0 slips; net +66 and +2 samples after the first minute (the run's whole net, −1897 at 59.94, is the 19 s Play slew) | **Held** |
| W5 | −42.4 ms at 59.94 and −104.6 at 23.976: 2.5 frames at both | **Held**, on the frames guess |
| W6 | Jumps in 20 of 40 Plays gate off (all 20 from 0, no mid-file one) and 0 of 40 gate on. The Plays without one do not crawl for 45 s: mid-file they start near the final value, gate on they slew for up to 33 s | **Missed** |
| W7 | From 0, gate off: first sound +74 to +96 (predicted +85 to +100, mostly held); after the jump about −49; settled well inside 15 s; final −42.0 to −42.7 | **Held for gate off from 0.** Not for mid-file or gate on, whose first sound is −7 to −60 |
| W8 | 0 silences over 5 ms; no jump over 1 ms but the resyncs | **Held** |
| W9 | Re-anchor not on SDI: held. Gate on the same as off: **missed** (no jump at all). Gate off mid-file picture: **missed**, 20 of 20 clean, where about 13 skips or repeats were predicted | **Half** |
| W10 | From 0 and mid-file differ completely with gate off | **Missed** |

### 10.17 The default-output stall without Jump, 2026-11-10

Same night and rules as §10.16. `BUGS.md`, *a change of the system default output silences SDI audio until the session ends*: until now seen only with Jump Desktop, which switches the default output to its own device.

**Method** (`w1c-defout.py`, `w1c-defout-report.py`). One launch, gate off, `cc-5994-2450s.mov` (sound), destination SDI, output on, **capture closed**. One Play from 0. `defout set` (new mode of `defout.swift`; it reads the current default first, refuses unless exactly one device matches, reads back after, and touches nothing else) makes **Mac Studio Speakers** the default output 60 s after Play, the Scarlett again 30 s later; five times, 120 s apart. At +75 s a Pause and Play (does a rate change restart a stalled pump?), at +95 s a Pause, a seek and a Play (re-arms the request, so each switch starts from a running pump). The driver restores the Scarlett in a `finally` and reads it back. **SDI silence from the bridge's own samples:** `[AUDIO-CORR]` gives each PCM callback's card stream position, so a gap between two is the silence the card was given, to the sample. **Pulls** for the picture. **`sample <pid> 10`** when SDI has gone silent, plus one healthy sample as a control. **New measurement hook `[AUDIOWATCH]`** (`FrameEngine`, `#if MANIFOLD_CARDCLOCK`, pre-ship list): the AVFoundation audio pump's callbacks and enqueues, the audio renderer's *was flushed automatically* and *output configuration changed* notifications, and, once the pump has had no callback for 2 s while playing, the renderer's `isReadyForMoreMediaData`, status, error and the last enqueued pts against the clock. Built after §10.16's runs, so they used one binary throughout.

**Predictions, written 2026-11-10 00:55, before the run.**

| # | Prediction |
|---|---|
| D1 | **Each of the 5 switches to the built-in silences SDI**, 0.5–2 s after the switch (the tap's look-ahead runs out; `j-today` 0.65 s). The picture does not notice: 0 pull repeats or skips beyond Play's own |
| D2 | **No recovery by itself:** silent through the restore to the Scarlett and the 45 s after it, 5 of 5 (§10.13: 337 s) |
| D3 | **Pause and Play do not restart it:** Play only writes the synchronizer's rate and re-arms nothing. Silent after it, 5 of 5 |
| D4 | **The seek does:** `beginReading` re-arms the request. PCM back within 1 s of the Play that follows it, 5 of 5 |
| D5 | **The stack:** nothing blocked. `com.graviton.manifold.pump.audio` busy in the control sample, absent from every stall sample. So the pump is waiting for the renderer's `requestMediaDataWhenReady` callback |
| D6 | **The renderer, from `[AUDIOWATCH]`:** an *output configuration changed* notification and a *was flushed automatically* notification within 1 s of each switch. At 2 s quiet: ready **true**, status rendering, no error, and the last enqueued pts behind the clock (a flushed queue). So it waits on a callback the renderer never makes after its automatic flush. That last part is a guess: whether AVFoundation should call again, or our pump should have acted on the flush, is what this run cannot say |
| D7 | The restore to the Scarlett also stops a running pump (§10.13, `s-ph1-s4`). Not testable as built: the pump is already stalled at each restore. It shows only if D1 fails |

At the end the default output must read Scarlett 18i20 USB.

**Run** `d-defout`, 2026-11-10 04:21–04:33. Guarded before and after; default output read as the Scarlett before (04:21:34), set back by the driver after each switch, and **read back as Scarlett 18i20 USB at the end (04:33:14) and again at 04:33:19.** Five switches to Mac Studio Speakers, each set and read back within 0.3 s. Built with `[AUDIOWATCH]` (the §10.16 binary plus that hook).

**Answer: it is the default output, not Jump. All 5 switches stopped SDI audio; none recovered by itself or by Pause and Play; a seek restarted it every time.** The cause, as far as one run shows it: at the switch AVFoundation flushes the audio renderer automatically, and after that flush the renderer never calls the pump's request block again, while reading ready.

| Switch | Renderer *was flushed automatically* | SDI silent (last PCM) after the switch | Silence, from the bridge's stream positions | Back on PCM |
|---|---|---|---|---|
| 1 | at the switch (host 47011.702; flush time 60.107 s, 0.14 s behind the last enqueued pts) | 0.61 s | 96.21 s | 10 ms after the Play that follows the seek |
| 2 | at the switch (flush time 173.030 s) | 1.37 s | 95.48 s | the same |
| 3 | at the switch (flush time 289.989 s) | 0.97 s | 95.98 s | the same |
| 4 | at the switch (flush time 407.009 s) | 0.96 s | 96.06 s | the same |
| 5 | at the switch (flush time 523.838 s) | 0.65 s | 96.40 s | the same |

- **D1 held:** silent 0.61–1.37 s after each switch: the tap's look-ahead running out, as `j-today`'s 0.65 s. The bridge logs one underrun event per switch (92.4–93.3 s each by its own count, from the moment the ring ran dry). **The picture did not notice:** no pull repeat or skip at any switch or restore.
- **D2 held:** silent through each restore to the Scarlett and the 45 s after it. A restore posted no renderer notification.
- **D3 held:** the Pause and Play at +75 s restarted nothing, 5 of 5. Play only writes the rate.
- **D4 held:** the seek's `beginReading` re-arms the request; the first PCM came within one frame of the next Play (log host stamps are good to a frame), 5 of 5.
- **D5 held, and more:** no thread blocked in any of the 10 stall samples. `com.graviton.manifold.pump.audio` was in the control sample and in none of the stall samples. **Also gone after each switch: the renderer's own device I/O, `com.apple.audio.IOThread.client` and `AQConverterThread`**, both present in the control. So after the automatic flush the renderer's audio queue is not running on any device, the Scarlett included after the restore. Its CoreMedia threads (`audioqueue.source`, `audiomentor`) sit idle on their condition variables.
- **D6 half held.** Within 0.12 s of every switch as `defout` logged it (it polls at 5 Hz) the renderer posted *was flushed automatically*; **no *output configuration changed* notification came, at the switch or the restore.** From then on, at 2 s, 10 s and 76 s: `isReadyForMoreMediaData` **true**, status 1 (rendering), error none, `hasSufficientMediaDataForReliablePlaybackStart` **false**, the reader reading with no error, and the last enqueued pts falling behind the clock (−1.2 to −1.96 s at 2 s, −75 s at 76 s). The pump's last outcome was `waiting`: it returned with the request armed, as the contract says, and the renderer never called it again. **So the pump stops in AVFoundation's hands, waiting for a `requestMediaDataWhenReady` callback that does not come after an automatic flush, with the renderer ready and starved.** Nothing in the pump reacts to the flush notification (the file path observes none of the renderer's notifications; only the live path's `LiveAudioRendererProbe` does). Whether AVFoundation should call again, or a client is expected to re-arm on that notification, is not settled by this run; the second is what Apple's notification is for, an inference from its name and documentation, not a measurement.
- **D7:** not testable as built, as written.
- **Healthy, for the comparison:** with the pump running, the longest gap between its callbacks in a 30 s window was 1.02 s.

**Measurement disturbed one stretch, recorded so it is not misread.** The control `sample` (host 46976.6–46987.5, 25 s after Play) cost 19 frames of picture (pulls +9, +7, +3 frames at 46977.1) and was followed by **7 short SDI underruns, 23–153 ms each, from 46979 to 47006**, before the first switch. Each fell exactly at the tap's newest pts (srcT 27.456 against tap 27.477; 28.587 against 28.629; 31.957 against 31.957): the tap had no lead over the card's cursor for that minute. The four 30-minute runs of §10.16, with no `sample`, had none in 7200 s of play. So the sample is the likely trigger; why the lead did not rebuild for 20 s after it is UNKNOWN. Not the stall: the pump was being called throughout.

### 10.18 Renderer stalls, output off and on, 2026-11-10

`BUGS.md`, the top 1.0 entry (*a playing file's picture freezes for good*): the watchdog recovers it; §10.15 measured 2 recoveries in 13.2 h, all with DeckLink output on, and 0.93 h with output off, too short to compare.

**Method.** `cardlock-hunt.py cycle off` (gate off, watchdog on as shipped, 60 s Plays from random points with a seek before each, `cc-5994-2450s.mov` with sound, destination SDI, capture closed), `HUNT_STOP_FIRST=0`. One-hour blocks alternating output off (`HUNT_NO_OUTPUT=1`) and on, starting with off, until 08:00, so the two get matching hours and the same part of the night. Counted per block from each launch's log: `[RENDERER-RECOVER]` attempts and `[RENDERER-NEARMISS]`, and the hunt's own freeze and audio-silence detections.

**Predictions, written 2026-11-10 00:55, before any block.**
- R1. Recoveries at about §10.15's rate, one per 6–7 h, the same with output off and on. In about 1.5 h each, the expected count is about 0.2 each: **most likely 0 and 0**, which would not tell off from on. Only a rate several times higher on one side would show in one night.
- R2. Near-misses: 0 on both sides (0 in §10.15's 16 h: the state does not clear by itself).
- R3. Freezes that last (PICTURE STUCK, or a hunt freeze detection): 0. Every stall that comes recovers on its first re-arm.

**Blocks**, 2026-11-10 04:33–07:55, `build/cardclock/hunt/s3-*`, one launch each, guarded, quit by PID, the §10.17 binary (with `[AUDIOWATCH]`). Default output the Scarlett throughout (`defout` logs) and at the end (07:55, read back).

| Block | Output | Played | Plays | Near-misses | Recoveries | PICTURE STUCK | Hunt detections |
|---|---|---|---|---|---|---|---|
| `s3-off1` 04:33–05:24 | off | 0.78 h | 48 | 0 | 0 | 0 | 0 |
| `s3-on1` 05:24–06:14 | on | 0.78 h | 48 | 0 | 0 | 0 | 0 |
| `s3-off2` 06:14–07:05 | off | 0.78 h | 48 | 0 | 0 | 0 | 0 |
| `s3-on2` 07:05–07:55 | on | 0.78 h | 48 | 0 | **1** | 0 | 0 |
| **Output off** | | **1.57 h** | **96** | **0 (0 / h)** | **0 (0 / h)** | 0 | 0 |
| **Output on** | | **1.57 h** | **96** | **0 (0 / h)** | **1 (0.64 / h)** | 0 | 0 |

- **The one recovery** (`s3-on2`, Play 4, 16.9 s after Play, pts 341.32): the known state, renderer not ready with nothing of ours pending, status 1, no error, no flush requested, timebase at rate 1; in it 0.357 s, no callback for 0.518 s. First frame 28 ms after the re-arm; picture moving 0.400 s after the stall began. The same as §10.15's two.
- **R1 held, and as predicted it cannot separate off from on:** 0 against 1 in 1.57 h each. If the rates were equal, a 0–1 split happens half the time. Together with §10.15: output on, 3 recoveries in 14.8 h (one per 4.9 h); output off, 0 in 2.5 h (1.57 h here plus 0.93 h of `wd-before-noout`). At the output-on rate, 2.5 h with none happens 60 % of the time. **Whether the stall needs the card is still UNKNOWN**; ruling out an equal rate at 95 % would take about 15 h of output-off running with none.
- **R2 held:** 0 near-misses in 3.1 h, 0 now in 19.1 h of watchdog-on running.
- **R3 held:** no stuck picture, no detection.
- **The audio watch, as a side reading:** 0 *was flushed automatically* and 0 SDI underrun events in the 1.57 h with output on. Its only reports were a 2.0–2.2 s "quiet" at the start of some Plays: the last callback was during the paused preroll before the Play, with 0.8–1.0 s still queued, and the pump was called again 0.25–0.6 s into play. That is the watch's threshold counting from the preroll, not a stall.
