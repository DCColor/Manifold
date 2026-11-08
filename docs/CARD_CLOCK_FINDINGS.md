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
