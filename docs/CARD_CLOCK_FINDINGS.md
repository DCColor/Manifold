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

**Superseded 2026-11-10 by §10.20**, which keeps this aim and replaces the mechanism: one mapping per run from card stream time to source samples, latched at the first timed pull, with the card's audio flushed at run edges.

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

#### Why 2.5 frames: the anchor read, and a control without it, 2026-11-10 (afternoon)

**Cause, from the code: the bridge counts the handed frame's wait as 5 frames; it is 3 less the phase within the frame on air, so on average 2.5.** No fix yet (Robbie, 2026-11-10). `BUGS.md`, *SDI audio lags its picture by 2.5 frames, in shipped builds*.

The anchor (`DeckLinkBridge.mm:638`) is `ideal = stagedPts + audioDepth − videoDepth`, the source time the picture on the wire should carry when this callback's samples reach it. Each term, read:
- **`stagedPts`** is `currentDeckLinkSourcePts()` (`MetalVideoRenderer.swift:5480`), which returns `deckLinkHandedPts` (`:5484`): the frame the fill block copied into the card's frame at the most recent completion (`:5527`, from `copyLatestDeckLinkFrame`, called in `fillFrame` at `DeckLinkBridge.mm:802`). That frame was scheduled straight after, at stream time `idx × frame` (`:804`), **at the back of the card's queue**. Since `9aaff2d` (2026-10-26) the doc comment there says this frame "is the one on the wire"; it is the newest one queued.
- **The queue.** The pool is 4 frames (`DeckLinkBridge.mm:1800`), each rescheduled the moment it completes, so between completions all 4 are scheduled: the one on air and 3 waiting, the handed frame last. `GetBufferedVideoFrameCount` (`:634`) read **4 in every logged callback**: 7,114 of 7,114 `vq=` values across the four 1800 s runs.
- **The handed frame's real wait,** at a callback a fraction φ (0 ≤ φ < 1) into the frame on air: the rest of that frame, 1 − φ, then the 2 frames ahead of it: **3 − φ frames**.
- **What the bridge subtracts:** `videoDepth = (bufferedVideo + 1) × frame` (`:637`) = **5 frames**. The comment (`:630-633`) says the staged frame "is picked up by the next frame-completion callback and then sits behind the frames already queued — hence the +1": that describes a frame not yet in the queue, and the handed frame is already in it and counted in `bufferedVideo`. And the frame on air is counted whole, when only 1 − φ of it is left.
- **The miss: 5 − (3 − φ) = 2 + φ frames.** The audio callback runs on the card's audio, about 50 times a second, unrelated to the frame, so φ is spread evenly and the smoothed error settles at **2.5 frames**. `ideal` is that much too early in the source, so the samples scheduled are older than the picture they meet: the sound is late. The ±0.5 frame swing of φ is what the EMA reduces to the ±1.5 ms limit cycle.
- `audioDepth` (`:636`) is right: the card's buffered audio is exactly what stands between a new sample and the wire, and audio and video share one stream clock (`:832-835`). The control below shows the card keeps that promise.
- **Before `9aaff2d`, by the same reading (an inference, never measured):** `sourceTime` returned the front buffer, the frame the *next* completion would hand over and schedule a frame later, so its wait was 4 − φ and the miss 1 + φ, **1.5 frames**. The change to the handed frame added the extra frame without touching `+1`.

**The arithmetic without the depths.** The bridge knows both stream positions exactly: the next audio sample goes out at `m_audioStreamFrames / 48000`, the handed frame at `idx × frame`. So `ideal = stagedPts + m_audioStreamFrames / 48000 − idx × frame` has neither φ nor a staircase, provided the handed pts and its `idx` are published together (today `idx` is taken at `:801` before the fill sets the pts). That is §10.20's anchor.

**Control: the card and the capture by themselves.** `syncout.cpp` (new, `scripts/decklink-loopback/`) plays a file to device 0 with no anchor loop: ffmpeg decodes the ProRes to v210 on a pipe, frame n is scheduled at `n × frame`, the file's own PCM sample m at stream time m / 48000 (`bmdAudioOutputStreamTimestamped`), on one `StartScheduledPlayback(0)`. So each picture and its samples are handed over for the same instant, and the wire shows what the card and `capture` add. `w1c-control.sh` captures it exactly as `w1c-run.py` captures Manifold (`capture --audio --marks --luma`), and the same analysers read both. No Manifold build is involved. Fixtures: the §10.16 noise files, and the **59.94 sync clip master** generated today as ProRes 422 + PCM 24-bit (`scripts/syncclips/generate.sh 59.94`, 60.06 s, into `~/Code/_scratch/manifold-1c-wire/fixtures/`). For the sync clip, `w1c-syncclip.py` (new) finds each flash frame by its luma and locates the audio that arrived with it in the clip's own PCM (its −60 dB noise floor is seeded too).

Predictions, written 15:20 before the control ran: the control reads **0 ± 1 sample** (median within ±0.05 ms) on both the noise file and the sync clip, with 0 discontinuities; Manifold on the sync clip reads −42.4 ± 2 ms after its start. If the control is not 0, the card and `capture` contribute that much and Manifold's own share is the difference.

Runs 2026-11-10 15:19–15:32. Manifold not running; guard before and after each. **DaVinci Resolve was open throughout** (since 15:10, Robbie at the Mac) but did not hold the card: every `EnableVideoOutput` and `EnableAudioOutput` returned S_OK, and nothing was late or dropped.

| Run | What | Played | Frames late / dropped | Discontinuities in play | A/V offset, every read frame |
|---|---|---|---|---|---|
| `ctl-5994` | noise fixture, 59.94 | 150 s, 8991 frames | 0 / 0 | **0** (one segment, 7.2 M samples) | **−0.58 ms**, constant from the first frame: 8998 frames at −0.575 to −0.592 (the 800.8-sample cadence) |
| `ctl-2398` | noise fixture, 23.976 | 150 s, 3596 frames | 0 / 0 | **0** after the first readable picture | **−0.17 ms**, constant: 3543 frames all at −0.167 |
| `ctl-sync` | sync clip master, 59.94 | 60 s, 3596 frames | 0 / 0 | | **−0.58 ms** at all 60 flashes (−0.59 to −0.58); beep onset −2.23 ms by threshold (the tone's 5 ms raised-cosine edge reads about 1.5 ms late by construction) |

- **The card and `capture` together put the sound 28 samples late at 59.94 and 8 at 23.976, constant.** That is the whole of the path outside Manifold. Where in the card or the capture those few samples come from is UNKNOWN and does not matter here: they are 1/70 and 1/250 of the offset measured.
- `ctl-2398`: one +4091-sample step at the first picture whose marker reads (picture 6, 2.24 s): the input relocking from the idle 59.94 to 23.976. Before it no picture reads, after it the offset is constant. Not a playout event.
- **Manifold's own share: −42.38 + 0.58 = −41.80 ms = 2.505 frames at 59.94; −104.62 + 0.17 = −104.45 ms = 2.504 frames at 23.976.** The code reading predicts 2.5 at both, the offset of a frame count and not of a time.

| # | Prediction | Result | |
|---|---|---|---|
| X1 | Control, noise, 59.94: 0 ± 1 sample, 0 discontinuities | −28 samples (−0.58 ms), constant; 0 discontinuities | **Missed** on the value by 27 samples; held on constancy and continuity |
| X2 | Control, sync clip: 0 ± 1 sample | −0.58 ms at 60 of 60 flashes, the same as X1 | **Missed** as X1; the two fixtures agree to 0.01 ms |
| X3 | Manifold, sync clip: −42.4 ± 2 ms | `m-sync` (18:02, gate off, the old anchor): **−42.72 ms**, median of 53 flashes after 10 s (−43.54 to −40.75); beep onset by threshold −44.29 | **Held**. Manifold's own share on beep-and-flash content: −42.14 ms = 2.53 frames |

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

### 10.19 The default-output stall: the fix, 2026-11-10

**Decided (Robbie, 2026-11-10):** independent of the card-clock work, for the next release. Handle the renderer's automatic flush by resuming the feed from the time it reports, per Apple's documented pattern. Production code, one log line per occurrence. `BUGS.md`, *a change of the system default output silences SDI audio until the session ends*.

**The change** (`FrameEngine.swift`, uncommitted). An observer of `AVSampleBufferAudioRendererWasFlushedAutomatically` on the engine's audio renderer, registered in `init` and removed in `deinit` like the rate observer, ungated. On the posting thread it notes the flush time (`AVSampleBufferAudioRendererFlushTimeKey`) and the current audio session (`SessionToken.peek()`, new). On main, `audioRendererFlushedAutomatically` logs one `[AUDIO-FLUSH]` line and, if that session is still current and a file audio arm exists, calls `readSoundAgain(from: flushTime)`: the previous arm retired, the renderer flushed behind a token bump (the serialized flush the header asks for), the tap emptied, a new reader and pump from the flush time. That is `rereadSoundAfterMove`'s route, now one helper for both, on both file paths (AVFoundation and libav, whose pump stalls the same way). **The clock is not stopped:** Apple's flush-time variant stops the synchronizer, which would hold the picture. With the clock running the renderer drops what is already past, which is Apple's "short mute" variant, positioned at the flush time. Skipped and logged: a seek or switch already re-armed, no file arm (live sources push and resume by themselves), or a 1b renderer move in flight.

**Predictions, written 2026-11-10 15:45, before the run.** `w1c-defout.py <cc-5994-2450s.mov> fx-off fix off`, then `fx-on fix on`: one Play, five switches to Mac Studio Speakers and back 30 s later, 120 s apart, **no transport at all**, capture closed, destination SDI.

| # | Prediction |
|---|---|
| F1 | An `[AUDIO-FLUSH] … reading the sound again` line within 0.2 s of every switch: 5 of 5. Also at most restores, now that the pump is running when they come (§10.13 saw a restore stop a running pump): 3–5 of 5 |
| F2 | **SDI recovers every time, with no seek:** after each change, PCM again within 0.5 s. The gap: from the re-read (the tap is emptied) until the new reader's samples reach the bridge's cursor, which sits a few frames behind the clock: **0.1–0.4 s per change** |
| F3 | The picture does not notice: no pull repeat or skip at any change |
| F4 | Gate on: the same. No `[AUDIO-FLUSH]` at the renderer moves of output start (a move flushes by its own call, not automatically) |
| F5 | No stall: 0 `AUDIO PUMP QUIET` reports after any change. The default output reads the Scarlett at the end |

**Results.** 2026-11-10 18:03–18:25 (`chain4.sh`), after a first attempt at 17:45 that Robbie, at the Mac, closed by hand. Each launch now waits until Resolve is closed and nobody has touched the Mac for 10 minutes. The same measurement build as §10.16's control evening (`.build-cc`, `-DMANIFOLD_CARDCLOCK`, the fix and the old anchor). Guard before and after each, `/Applications/Manifold.app` not run, Resolve not running. Capture closed, so the gap is read from the bridge's own stream positions (`w1c-defout-report.py`), not the wire. Reports: `runs/fx-off.report`, `runs/fx-on.report`.

| Change | Gate off: SDI silence | Gate on: SDI silence |
|---|---|---|
| 1 → Speakers | 20.1 ms (964 samples) | none over 5 ms |
| 1 → Scarlett | none | 19.0 ms (910) |
| 2 → Speakers | 20.5 ms (985) | 20.0 ms (960) |
| 2 → Scarlett | none | none |
| 3 → Speakers | none | none |
| 3 → Scarlett | none | none |
| 4 → Speakers | none | none |
| 4 → Scarlett | none | 21.4 ms (1027) |
| 5 → Speakers | none | none |
| 5 → Scarlett | none | 20.8 ms (999) |

- **Every change, switch and restore alike, posted an automatic flush, and each got one `[AUDIO-FLUSH] … reading the sound again` line: 10 of 10 per run.** The flush time was 0–38 ms behind the clock. No `[AUDIO-FLUSH]` line came at any other time, so none came at output start, gate on.
- **SDI recovered every time, with no seek and no transport:** 20 of 20 changes. The driver's check 20 s after each switch read PCM 10 of 10.
- **The gap is one bridge callback of silence or nothing.** 6 of 20 changes left one underrun callback of 19–21 ms (`UNDERRUN EVENT`, 1 callback each). The other 14 left no silence over 5 ms. The tap is emptied at the re-read, and the new reader nearly always refills it before the bridge's cursor reaches the empty part.
- **The picture:** gate on, no pull step and no pull repeat in the run. Gate off:
  - The card dropped 3 frames at the first switch (frames 4272–4274, a +5-frame pull step at 96341.33).
  - It dropped 25 frames during the driver's own `sample` of the process (96306.2–96317.1), which suspends it. That was the measurement, not a switch.
  - 23 pull repeats over the run, not located against the changes.
  - The pre-fix gate-off run (`d-defout`, §10.17) logged 20 card drops of its own. Whether a switch drops frames gate off without the fix is UNKNOWN: its drops were not located against its switches either.
- **No stall:** no `AUDIO PUMP QUIET` after any change. The two reported in each run are the pump idle in the 16 s before Play (clock 0.0). The default output read the Scarlett at the end of both runs.

| # | Result | |
|---|---|---|
| F1 | 5 of 5 switches and 5 of 5 restores, each run | **Held** |
| F2 | 20 of 20 recovered with no seek; the gap 0 or one 19–21 ms callback, not 0.1–0.4 s | **Held** on recovery; **missed** on the gap, by being shorter |
| F3 | Gate on: no step or repeat. Gate off: 3 frames dropped at 1 of 10 changes; **the repeat (below): none at 10 of 10** | **Held gate on; gate off 1 of 20 changes** |
| F4 | Gate on the same; no flush line at output start | **Held** |
| F5 | 0 QUIET after any change; the Scarlett at the end | **Held** |

**The gate-off drops, located (Robbie, 2026-11-10 evening).** `w1c-drops.py` (new) dates each `DeckLink D3: !! Dropped|DisplayedLate` line from the run's `[CARDCLOCK]` lines (completed count → host, good to about 0.1 s) and sets each group against the output changes and the driver's `sample` windows.
- **Pre-fix (`d-defout`, §10.17), gate off: no drop at any of its 10 changes.** Its 20 drops are frame 4 at start and 19 inside `sample control`.
- **`fx-off`:** frame 4, 25 inside `sample control`, and **frames 4272–4274, 0.14 s after the first switch**, the only drops at a change. The desktop lost 4 frames in the same second (`[PLAYBACK-STATS] t=60.150 dropped=4`). That was between the switch (`set` at 96341.235) and the automatic-flush notice (96341.376), before which the fix does nothing. So it came before the handler ran.
- **Repeat, `fx2-off` (19:24–19:35, the same build, gate off, 5 switches and 5 restores):**
  - **0 card drops in the whole run**, none at any of the 10 changes. None inside `sample` either, this time.
  - No desktop drop.
  - 10 of 10 `[AUDIO-FLUSH]` re-reads; SDI on PCM 20 s after every switch.
  - **No SDI silence over 5 ms at any change**, and no pump stall.
- **So the drops do not line up with switches:** 1 of 30 changes across the three gate-off runs, 1 of 20 with the fix, 0 of 10 without. That one came before the fix's handler. It reads as an occasional cost of the system's device switch, not the fix's, though one event cannot settle that.

### 10.20 Stage 1c, the plan: SDI audio on the card's own timeline, 2026-11-10

**Plan only: nothing here is built.** Written after §10.16's wire results and the 2.5-frame reading. It replaces §10.3's *The change, under card lock only*, and keeps its aim.

**Decided (Robbie, 2026-11-10).** With the card as master, SDI audio is scheduled on the card's own timeline: each frame's audio at that frame's stream time, so picture and sound are locked by construction. No steering corrections, no start jump, no slew, no constant offset.

**The idea in one line.** Under card lock the source time on the wire is a fixed function of the card's stream time for the whole of a run: picture slot `idx` carries source time `Φ + idx × frame`, with `Φ` fixed from the latch to the next transport move (§10.1). So card audio sample `s` carries source sample `s + D`, with `D` an integer fixed once per run. The bridge then plays the file's samples in order, one per sample scheduled, and never reads the picture again to decide where it is.

**The cadence comes free.** Each frame's audio starts at stream sample `A(idx) = ⌊idx × 48000 × frame⌋`, exact integer arithmetic in the mode's own timescale: at 59.94 that is 800, 801, 801, 801, 801 samples (4004 per 5 frames; the order depends only on where the run starts), 2002 at 23.976, 1601/1602 at 29.97, exact at 24, 25, 30, 50 and 60. With one mapping per run, every frame gets exactly its share and nothing has to count it.

**What changes.**

| Piece | Today | 1c |
|---|---|---|
| What the pull publishes | `deckLinkHandedPts`, a pts with no slot (`MetalVideoRenderer.swift:5527`); `idx` taken before the fill (`DeckLinkBridge.mm:801`) | The pair (slot `idx`, pts), whether the pull was timed, and a run number that changes at every transport move, written together under `deckLinkLock` |
| Anchor | `stagedPts + audioDepth − (bufferedVideo + 1) × frame`, steered ±2 samples per callback toward its smoothed error (§10.16) | **Latch** at the first timed pull of a run whose picture has moved: `D = round(pts × 48000) − A(idx)`. Then the cursor is `s + D` for every sample scheduled. No error, no correction |
| Depth loop | Tops the card up to 200 ms | Unchanged: it says how many, the mapping says which |
| Monitor | The loop | The exact error, `pts − (idx × frame + D / 48000)`, at each new pair: 0 in a run under lock. Over half a source frame, a re-latch, logged and counted (`[SDI-AUDIO] re-latch`). Expected never in steady play |
| Run edges | Silence while paused or shuttling; by reading, the PCM already queued (up to 200 ms) plays on past a Pause; the first callback after Play snaps to `ideal` | `FlushBufferedAudioSamples` at each run edge, then reschedule from the card's current stream time (below) |

**Why a flush at the edges.** Audio is queued about 200 ms ahead; a picture is decided 3 frames ahead (§10.16). At a Play the 150 ms or so of audio already queued after the first new picture is silence, scheduled before anyone knew. Kept, the sound would start 150 ms after the picture, with those samples skipped. So at the latch the bridge flushes the card's audio and schedules again from the card's current stream position: silence up to `A(idx₀)`, the file from there. At a Pause it flushes and schedules the file only up to the end of the last moving frame, then silence. **What `FlushBufferedAudioSamples` does to a running stream (the samples on the wire now, the stream position after) is UNKNOWN.** The SDK header declares it and no more. First step: a `syncout --flush-at T` probe on the loop, no Manifold, before any app code.

**Events.**

| Event | Picture (card lock, §10.1) | SDI audio, 1c |
|---|---|---|
| Play from 0 or mid-file | Starts; lock latches | Silence until the first moving slot, then the file from exactly that frame's first sample: no jump, no slew |
| Seek, frame step, loop wrap | `beginReading`; a new run | Run ends: flush, silence until the new run's first timed pull, then latch again. Across a loop's wrap the sound has whatever gap the picture holds, and no stale end-of-file samples |
| Scrub drag, shuttle ≠ 1×, reverse jog | No lock writes | Silence, as today (the decode pump runs only at 1×) |
| Pause | Rate 0 | Flush; the file to the end of the last moving frame, then silence. The sound stops with the picture, not 200 ms after |
| Output start | Renderer moves (1b) | No audio until the first timed pull after the start, then latched as at Play |
| Output stop | Ends | Nothing to do |
| File rate ≠ mode rate (25p on 59.94, 23.976 on 24.000) | The clock runs in card seconds, so the cadence shows in the picture (§10.4) | Unchanged: the mapping is in time, not in frames, so the sound keeps its true duration and stays continuous. The A/V offset per frame follows the cadence, a sawtooth inside one source frame (23.976 on 24.000: 0 to 41.7 ms over each 41.7 s), and no slip |
| Underrun (tap behind the cursor) | — | Silence for what is missing; the cursor still advances with the stream, so the sound comes back in place, never late. Counted, as today |
| **44.1 kHz source** | — | Today SDI audio is **disabled** for any rate but 48 kHz (`DeckLinkService.swift:1176-1182`). 1c resamples once, at the tap's ingest, with `PolyphaseResampler` at the fixed ratio 160/147, onto the source axis at 48 kHz, and compensates its fixed group delay in `D`. Everything after is unchanged. The Mac renderer is untouched (AVFoundation plays 44.1 itself). 88.2 and 96 kHz take the same route; 32 kHz too |

**Gate off (today's path) until 1b ships.** Card lock does not exist, the picture still slips a frame each time the card and the file drift apart, and a run-wide mapping would have to re-latch at every slip: a jump of a frame of audio, worse than today's walk. So the gate-off path keeps the anchor loop. **One separable change is available for it, not decided:** compute `ideal` from exact stream positions, `stagedPts + s_next / 48000 − idx × frame` (§10.16), with the pair published together. By reading, that removes the 2.5-frame lag and the staircase, so the loop corrects only after a slip (a frame's worth of samples, walked back at 2 ms/s, as now) and applies nothing in between. It could go into the next release on its own. Whether it also removes the +90 ms start error behind the gate-off RESYNC at a Play from 0 is UNKNOWN: that start error's cause is not explained. Snapping only after the first timed pull, as 1c does, is the likely cure.

**Predictions, written 2026-11-10 before any code.** All against the control: the card and `capture` alone read −28 samples at 59.94 and −8 at 23.976 (§10.16). So "offset 0" on the wire means **Manifold − control = 0 ± 1 sample**.

| # | Run | Prediction |
|---|---|---|
| C0 | `syncout --flush-at` probe, no Manifold | A flush mid-run leaves the stream position where it was, and samples scheduled after it at their stream times land as scheduled. If not, the edge design changes before any app code |
| C1 | `cont`, gate on, 1800 s, 59.94 and 23.976 | **0 discontinuities in steady play** (today 77,000–78,000 per run). `[AUDIO-CORR]` shows `c=0` in every callback after the latch. Re-latches 0, underruns 0 |
| C2 | The same | **Offset 0 ± 1 sample from the first audio block**, every frame to the end. Its whole range in the run is under 2 samples (today p1–p99 3.1 ms, gate on) |
| C3 | `plays`, gate on, 20 cycles, 59.94 and 23.976 | **No jump at Play** in 80 Plays, from 0 or mid-file: the first sound arrives with the first moving picture, at offset 0 ± 1 sample, and stays there. No slew. No silence over 5 ms after the first sound |
| C4 | Pause in the same runs | The sound ends within 1 sample of the end of the last moving picture (today, by reading and never measured, up to the 200 ms already queued, less the 3 frames of picture still queued) |
| C5 | New `transport` mode: seek, step, loop on a 20 s file, shuttle 2× and back, output stop and start mid-Play | Each run is clean as C3. Loop: the gap equals the picture's hold at the wrap, if any, and no end-of-file sample after it. 0 discontinuities inside any run |
| C6 | 25p fixture on a fixed 59.94 mode; 23.976 on 24.000, 600 s each | 0 discontinuities. The offset follows the cadence's sawtooth within one source frame and never steps |
| C7 | 44.1 kHz noise fixture, 59.94, 600 s | SDI carries sound (today none). 0 discontinuities; offset 0 ± 1 sample of 48 kHz after the delay. Located against a 48 kHz reference made by the same resampler offline |
| C8 | Gate off, `cont` and `plays`, unchanged code | Today's figures (§10.16) exactly: nothing on the gate-off path moved |
| C9 | T15 and T16 (§10.5) | Output off and live sources unchanged |

**The wire tests.** All with `w1c-run.py` and `w1c-wire.py` as in §10.16, plus a control run (`w1c-control.sh`) in the same session for the card's own constant. New: a `transport` mode in `w1c-run.py` (the debug transport has play, pause, seek, step, shuttle and loop; no scrub verb, so scrub stays attended), a 25p and a 44.1 kHz fixture from `mkfixture.sh`, and the `--flush-at` option in `syncout.cpp`. `w1c-wire.py` gains the offset relative to the control and a per-Play first-sound check against the first moving picture.

**Out of scope.** Destination Computer (Stage 2). The card's own 28 / 8 samples are left alone: they are the card's and the capture's together, and which part is the output's is not known.

### 10.21 The anchor fix, ahead of 1c: the handed frame's own slot, 2026-11-10 (evening)

Robbie, 2026-11-10 evening: fix the anchor term in production code, independent of the 1c redesign; verify on the loop, gate off and on, at 23.976 and 59.94, against the `syncout` control (§10.16); and say whether live streams share it. Uncommitted.

**Live streams share the anchor, and the 2.5 frames, from the code.**
- SDI audio has one path for every source. The bridge reads `engine.audioTap` (`DeckLinkService.swift:1185-1214`, `WindowDeck.swift:1551`) at the source time the anchor gives. Sound reaches that tap from:
  - every live sink, through `LiveAudioSink.enqueue`, which tees into the tap before the renderer (`FrameEngine.swift:3625`): WHEP, SRT and NDI;
  - SRT's and NDI's fallback routes (`SRTFrameRouter.swift:2071`, `NDIService.swift:2392`);
  - HLS through `HLSAudioTap` (`WindowDeck.swift:1609`);
  - files (`FrameEngine.swift:3407`, `:5062`).
- The anchor's pts is `currentDeckLinkSourcePts()`, the handed frame, which `copyLatestDeckLinkFrame` sets on every fill whatever the source (`MetalVideoRenderer.swift:5526-5527`). A live source takes the newest frame (`:5551-5554`), still scheduled at the back of the queue. So a stream to SDI was late by the same 2 + φ **card** frames: 41.7 ms at 59.94, 104.3 ms at 23.976. The miss counts frames of the output's queue, not of the source.
- **A source slower than the output was later still (inference, from the code; not measured).** The old term took the newest handed pts as if that frame had just gone to the back of the queue. A frame repeated in several slots (a 30p stream on a 59.94 output, 24p on 59.94) went out from its first slot, so on its repeats the term read later again, by 0 to 2 slots. On average that is +0.5 card frame at 2 slots a frame and +0.8 at a 2-3 cadence. The new term counts such a frame from its first slot.
- **Calibration (`AUDIO_RESAMPLER_DESIGN.md` §19.1-§19.2):** the per-source offset O is measured on the stream's own timestamps (beep against flash, decoded axis), not on SDI. SDI applies the same O as a read offset (`AudioTapBuffer.setLiveReadOffset`, `FrameEngine.swift:4851`), so SDI and the desktop move together. O never contained the bridge's lag. **With the fix, a calibrated stream on SDI is in sync with its picture where it was 2.5 card frames late, and a saved O needs no change.** The exception is an O set by ear while watching SDI: it would have absorbed the lag, and it now reads about 2.5 card frames early. The desktop path is unchanged. §19.10's by-ear note ("a bit tighter sync" on the Mac than on SDI, at the same O) is consistent with SDI having been the late one.

**The change** (`App/DeckLink/DeckLinkBridge.mm`):
- `fillFrame` publishes, after each fill, the pts it handed and the slot it went out in (`noteHandedFrame`, `:993`, `:1000`), under a lock: fills run on the start thread during preroll and on the SDK's video thread after, and the audio callback reads (`handedFrame`, `:1011`).
- The anchor is `ideal = handedPts + (m_audioStreamFrames / rate − handedIdx × frame) + trim` (`:658`). Both streams share the t = 0 of `StartScheduledPlayback(0)`, so neither queue depth is sampled and no callback phase enters. `bufferedVideo` stays only for the periodic log's `vq=`.
- A frame handed in consecutive slots counts from its first, for up to `kAudioMaxRepeatSlots` = 3 slots after it (`:370`). That covers 24p and 30p in 59.94 and 15p. Held longer (pause, a held picture), it counts from its newest slot, as the old term did.
- No handed frame yet: silence and no anchor (`:649`), as for a NaN pts before.
- The hidden trim key (`manifold.decklink.audioTrimSeconds`) still adds to the target.

**Predictions, written 2026-11-10 evening, before any run of the fixed build** (`.build-anchor`, the same flags as `.build-cc`; runs `chain5.sh`, after chain4):

| # | Run | Prediction |
|---|---|---|
| A1 | `a5994-off`, `a5994-on`: cont, 300 s, noise fixture | Steady offset after 60 s, median **−0.58 ± 1 ms** (the control's), both gates. Before: −42.38 / −42.35 |
| A2 | `a2398-off`, `a2398-on` | Median **−0.17 ± 1 ms**, both gates. Before: −104.65 / −104.62 |
| A3 | `a-sync`: the sync clip, 59.94, gate off | −0.58 ± 1 ms at every flash after 10 s (`ctl-sync`: −0.58) |
| A4 | Corrections, A1-A2 | At matched rates the handed pts advance exactly a frame a slot, so the target has no staircase and no φ. **Gate on: under 1 nonzero correction a second after 60 s** (before: 43 a second). Gate off: corrections only in the walk back after each picture slip, about 400 per slip (801 samples at ±2), and none between. The ±1.5 ms limit cycle goes; p1-p99 of the offset under 1 ms gate on |
| A5 | `ap5994-off`/`-on`: 5 Plays from 0 and 5 mid-file per gate | **The start is the same shape, shifted by the 42 ms** (inference: what sets the first-sound offset is UNKNOWN, §10.16). Gate off from 0: first sound about +115 to +140 ms, and **one RESYNC jump in each of 5, of −106 to −146 ms, 1.2-2.2 s in, no worse than before**. Mid-file and gate on: no jump, first sound within ±40 ms of the final value, final −0.6 ± 1 ms. Silence over 5 ms after the first sound: 0 |
| A6 | Starts in A1-A2 | Before plus the shift: 59.94 off, about +128 then the jump; 23.976 off, about +13 then a slew; 59.94 on, about +39 then a slew; 23.976 on, about +4 |

If A1-A3 hold, Manifold's own share of the SDI offset is under a millisecond, and the 28 and 8 samples are the card's and the capture's. §10.20's 1c anchor keeps this term and replaces the loop around it.

**Results.** 2026-11-10 18:25–19:23 (`chain5.sh`), 7 launches of `.build-anchor`, each guarded before and after. Each launch waited for Resolve to be closed and the Mac to be idle 10 minutes. Capture open throughout; analysers as §10.16. Before = §10.16's runs on `.build-cc` (old anchor); the cont runs then were 1800 s, now 300 s.

| | 59.94 gate off | 59.94 gate on | 23.976 gate off | 23.976 gate on |
|---|---|---|---|---|
| Control (`syncout`) | −0.58 | −0.58 | −0.17 | −0.17 |
| **Steady offset after 60 s, before** | −42.38 ms | −42.35 | −104.65 | −104.62 |
| **Steady offset after 60 s, after** | **−0.49 ms** | **−0.49** | **−0.17** | **−0.10** |
| After − control | +0.09 ms | +0.09 | 0.00 | +0.07 |
| p1 / p99 after (before) | −0.88 / +11.75, the slips (−52.85 / −40.53) | **−0.50 / −0.48** (−43.68 / −40.57) | −0.47 / +36.75, a slip (−136.83 / −103.31) | **−0.10 / −0.10** (−106.21 / −103.33) |
| Nonzero corrections a second in play, before | 43.4 | 43.2 | 43.2 | 42.9 |
| … after, whole run; per minute | 4.3; 685 0 0 574 39 | 2.0; 611 0 0 0 0 | 4.2; 49 0 0 0 1215 | 4.0; 1215 0 0 0 0 |
| Corrections matched on the wire | 1297 of 1297 | 611 of 611 | 1263 of 1263 | 1215 of 1215 |
| Offset at the first sound, then (before) | +132.9, RESYNC jump −130.4 ms at +1.48 s (+85.5, jump −131.8) | +16.1, slew to −0.6 by 10 s (−3.2, slew 19 s) | **+83.2, RESYNC jump −164.8 ms at +1.0 s** (−91.7, slew, no jump) | **+41.5, slew to −0.1 by 20 s** (−100.3, settled in 2 s) |

- **The sync clip** (`a-sync`, gate off): median **−0.58 ms** over 53 flashes, the control's figure exactly (`m-sync`, old anchor: −42.72). 42 flashes read −0.58 to −0.59. The rest are one picture slip at 52.4 s, read −16.2 ms and walked back at about 2 ms/s.
- **Steady state:** within 0.1 ms of the control at both rates and both gates. **A1, A2, A3 held.** Gate on, the offset's whole p1-p99 range is 0.02 ms and 0.00 ms; before, it was 3.1 and 2.9 ms. The ±1.5 ms limit cycle is gone.
- **Corrections: none at all in steady play** at both rates, gate on, after the first minute. Before, there were 43 a second. Gate off, they come only in the first minute and in the walk back after a picture slip: 574 at 59.94 and 1215 at 23.976 for one slip each. That is more than A4's "about 400", because the walk is mostly 2-sample steps with some single ones. The walk takes 7.7 s and 19.7 s, as before (§10.16). **A4 held**, except the per-slip count.
- **Every correction the bridge made reached the wire one for one** (4386 of 4386). Nothing else broke the sound.

**After Play, 59.94** (`ap5994-off/on`, 5 cycles each: 5 Plays from 0 and 5 mid-file per gate):

| | Gate off, from 0 | Gate off, mid-file | Gate on, from 0 | Gate on, mid-file |
|---|---|---|---|---|
| First sound, after (before, §10.16) | +116.2 to +132.9 ms (+74 to +96) | 3 of 5 at −0.55; 2 at −17.2, one frame late (−60 to −36) | +16.1 (3), +32.8 (2) (−33 to −7) | 3 of 5 at −0.55; 2 at +16.1 (−37 to −17) |
| Jump on the wire | **5 of 5**, −130.4 to −147.7 ms, 1.18–1.48 s in, each a logged RESYNC (20 of 20, −106 to −146) | 0 (0) | 0 (0) | 0 (0) |
| Final | −0.55 to −0.57 | −0.55 to −0.65 | −0.47 to −0.50 | −0.48 to −0.55 |
| Silence over 5 ms after the first sound | 0 | 0 | 0 | 0 |

- **At 59.94 the start is no worse, and closer:** the same single RESYNC jump on every gate-off Play from 0, of the same size. Mid-file and gate-on Plays start at most 2 frames off, and 9 of 20 start on it. The gate-on slew lasts at most about 20 s; before, it was up to 33 s.
- **At 23.976 the start is worse, on one Play each:** a new −165 ms jump gate off, and a 42 ms, 20 s slew gate on, where before there was a 13 ms slew and a 4 ms one. **A6 missed** at 23.976 (predicted about +13 and +4).
- **Why (from these numbers; the mechanism is an inference):** every first-sound error is a whole number of frames, with the sound ahead. 59.94: +1, +2 and 7–8 frames; 23.976: +1 and +2 frames, which became +4 by 0.5 s. The anchor snaps at the first unmuted callback to the frame on the wire. At a Play the picture stays on the paused frame for some slots after that callback, so the sound starts ahead by as many frames as the picture holds, and comes back when the picture moves. Before the fix, the −2.5-frame bias cancelled about 2.5 frames of that hold. At 23.976 that left a small error. At 59.94 it did not: a 2.5-frame bias is 42 ms there, against holds of up to 133 ms. What sets the length of the hold is UNKNOWN; it is the "+90 ms at a Play from 0" of §10.16, which the bias had shifted.
- **Not fixed here.** One direction, not built: keep the anchor unset, sending silence, until the first handed frame whose pts differs from the paused one. The first sound would then start with the moving picture, with no jump and no slew, and up to the hold's length later than now. That is a change of behaviour at Play, so it is Robbie's call. §10.20's 1c anchors at the first timed pull instead, which removes the question.
**After Play, 23.976** (`ap2398-off/on`, `chain7.sh`, 19:35–19:50: 3 Plays from 0 and 3 mid-file per gate):

| | Gate off, from 0 | Gate off, mid-file | Gate on, from 0 | Gate on, mid-file |
|---|---|---|---|---|
| First sound | +41.52 ms, 3 of 3 (exactly one frame); +165.6 at 0.5 s | −0.19 (1), +41.52 (2) | +41.52, 3 of 3 | +41.52, 3 of 3 |
| Jump on the wire | **3 of 3: −164.83 ms at 0.98–1.00 s**, each a logged RESYNC (−165.0) | 0 | 0 | 0 |
| Then | settled at once | slew to the final value in 19–22 s | slew, 19–22 s | slew, 19–22 s |
| Final | −0.19 | −0.12 | −0.12 | −0.12 to −0.15 |
| Silence over 5 ms after the first sound | 0 | 0 | 0 | 0 |

- **Every 23.976 Play starts one frame ahead (11 of 12),** and only Plays from 0 with the gate off then go to four frames ahead and jump. The Play-from-0 hold is longer than the others at both rates: 59.94 gate off gave 7–8 frames.
- **No earlier measurement of 23.976 Plays exists** (§10.16 measured Plays at 59.94 only). The 1800 s runs' single Play from 0 started 13 ms (gate off) and 4 ms (gate on) from its final value. So against that, the fix makes the 23.976 start worse on every Play: a jump gate off from 0, and a one-frame, 20 s slew everywhere else.
- **For Robbie:** the fix is right in steady state and at 59.94, and makes the 23.976 start worse. Commit it with the start-of-play change above (hold silence until the first moving frame), or without it and accept the 23.976 start, or keep it out until 1c. Raw captures of every §10.21 run are deleted; the reports, `.av.csv` and `.summary.json` are kept in `~/Code/_scratch/manifold-1c-wire/runs/`.

### 10.22 Stage 1c, built: SDI audio on the card's own timeline, 2026-11-10 (night)

**Decided (Robbie, 2026-11-10 night):** no interim release; 1b, 1c, Stage 2, the output-change stall fix (§10.19) and the anchor fix (§10.21) ship together as 0.9.3. The anchor fix stays as it is; the interim start-of-play change (§10.21) is not built. Build 1c as §10.20 plans, keeping the new anchor. Verify at 23.976 and 59.94, gate off and on: steady state within 0.1 ms of the `syncout` control, no per-callback corrections, the offset at the first sound within ±1 ms, no jump, the silence at Play measured; Play from 0 and mid-file, seek, loop, pause, output stop and start. Uncommitted.

#### C0: what a mid-run flush does (`syncout --flush-at`, no Manifold), 2026-11-10 20:04–20:07

`syncout` (new options `--flush-at T --flush-every P --flush-lead MS`): at each flush, `FlushBufferedAudioSamples`, then read the buffered count and `GetScheduledStreamTime(48000)`, then schedule the file again from its own sample at that stream time + the lead. 5 flushes per run, `c0-5994-l10` (10 ms lead, 60 s) and `c0-2398-l1` (1 ms lead).
- **The flush does not empty the card's audio.** 4715–5976 samples (98–125 ms) stay buffered after it, at both rates. They are committed: they play.
- **Anything scheduled into that committed window is added to what is there.** Rescheduling the same file samples there put exactly twice the source on the wire, sample for sample (`rx == 2 × ref` on every sample), from the restart to the window's end. After the window, only the new samples play.
- **The window's end is the stream time read after the flush plus the buffered count then, +0 to +2 samples:** 10 of 10 flushes. The stream position is unchanged by the flush, and samples scheduled at a stream time after it, 1 ms ahead included, land exactly there: the offset is −0.55 ms before and after every flush.
- **C0 (§10.20): half held.** The stream position held, and samples after the flush land as scheduled. But a flush cannot remove the last ~110 ms.

**What that means for the edges.** The committed window can still be rewritten exactly. Scheduling *(what it should carry − what was scheduled there)* into it leaves exactly what it should carry, because the card adds. At a Play the window holds silence, so the new sound simply goes in. At a Pause it holds the sound queued past the picture's end, so its negative cancels it to digital zero. The bridge therefore keeps a history of what it scheduled at each stream position (the last 65,536 samples).

#### The design, as built

- **Per slot, from the fill:** the frame's pts, its slot `idx`, whether the pull was timed (`MetalVideoRenderer`, now recorded per pull), and whether the source pulls by time (files) or takes the newest frame (live). Written to a 32-entry ring under a lock by `fillFrame`, read in order by the audio callback, which keeps all audio state on its own thread.
- **Live sources** (no pull by time): the §10.21 anchor and its loop, unchanged.
- **Files, a run:** the bridge latches at the first **timed** slot whose pts differs from the slot before, with the gate open: `Φ = pts − idx × frame`, `D = round(Φ × 48000)`; card sample `s` carries source sample `s + D` from then on. **The sound starts at `A(idx − 1)`**, the last showing of the frame the picture held, when that slot carried the frame just before (it does at a Play: the paused frame), so that frame's own sound plays with it; otherwise at `A(idx)`. `A(n) = ⌊n × 48000 × frame⌋`.
- **Edges by rewrite:** flush, read the window's end, schedule *desired − history* over `[max(edge, now + 1 ms), end + 2)`, then schedule normally from there. At a latch the desired sound is the file; at a run end it is zero.
- **A run ends** at the first slot whose pts is not `Φ + idx × frame` (within half a frame) and whose pull was not timed: Pause (and its landing), seek, step, loop wrap, shuttle. The sound is cut at `A(idx)`, the end of the last frame that moved with the run.
- **Inside a run:** the cursor is `s + D` for every sample; an underrun is zeros for what is missing and the cursor still advances. **Gate on:** no steering at all; a timed slot off the mapping by more than half a frame is a re-latch, logged `[SDI-AUDIO] re-latch` and counted (expected never). **Gate off:** the picture can slip, so a timed slot off the mapping is not an edge: the §10.21 loop steers `D` toward it, ≤ 2 samples per callback, from the exact error. Between slips that error is under half a sample, so it corrects nothing.
- **The gate** (pause, shuttle, mute, destination Computer): zeros for new positions, the run kept; it is the slots that end it. A mute and unmute resumes in place.
- **Output start:** no run until the first timed moving slot. **Output stop:** nothing to do.
- Not built here: §10.20's 44.1 kHz resample (C7) and the rate-mismatch window (C6): the brief's tests are 48 kHz at matched rates. The in-run check uses half a card frame, which is right only at matched rates. A 25p file on a 59.94 output would end and relatch its run at every cadence step under gate on: UNKNOWN until measured, and a decision below.

#### Revised after the first smoke run: no flush, an 80 ms queue, 2026-11-10 night

**Smoke run `t1-smoke`** (20:27, one `transport` cycle, 59.94, gate on, the design above). Inside each run the offset was constant (spread 0.01 ms), and each run's sound ended 26 samples into the frame after its last moving one, which is the card's own constant. But two faults:
- **One stray sample after the first Pause:** −0.039 FS, in digital silence, 87.5 ms after the edge. That is the committed window's end, which is known only to ±2 samples, so the rewrite wrote 1 sample on the wrong side of it.
- **The first ~100 ms of sound was missing after a seek or a step.** The tap is filled only once play starts, so those positions went out as zeros. The run was still on its line once the sound came.

**C0b, the queue without a flush** (`syncout --overlay-at`, `--audio-depth`, no Manifold, 20:33–20:37):
- With the usual 200–430 ms queue, the negative of everything queued, scheduled 1 ms past the card's position, gives three zones on the wire, 4 of 4:
  - the first 123–898 samples **ignored** (in flight);
  - then about 4,950 samples **added** (digital zero: the committed window);
  - then the rest **replaced** (the inverted sound plays).
- **With the queue held at 80 ms** (`--audio-depth 80`), the same overlay gives digital zero over the whole range, from 1 ms past the card's position to the queue's end, and the source again sample-exact right after it. That held 12 of 12, at 59.94 and 23.976. Everything queued is committed, and the card adds.

**So the edges changed:**
- A file's queue is held at 80 ms (live sources keep 200 ms).
- An edge never flushes. It schedules *desired − history* from `max(edge, now + 1 ms)` to the queue's end, which is exact.
- A latch waits until the queue is within 4,400 samples, which matters only after output start or a switch from a live source.
- **Sound not yet decoded** when its positions were scheduled is written in on later callbacks, the same way, while it is still ahead of the card.
- The read finds where the ring's data starts inside a chunk, 1 ms at a time, instead of reading a whole chunk as empty.

**Smoke runs 2 and 3** (20:40, 20:47, 20:51; one `transport` cycle each: 59.94 gate on twice, then 23.976 gate off):
- **Smoke 2: no discontinuities, nothing unlocated, every run starting at −0.53 to −0.56 ms** (control −0.55). 11,620 late-decoded samples were written in afterwards, with none missing on the wire. Three faults remained:
  - **Pause cut the last 375 samples of the last frame.** The gate goes silent at Pause, and with an 80 ms queue its zeros began before the picture's last handed frame had finished, about 3 frames ahead.
  - **A seek while playing latched 29 samples off.** The first frame after the seek carried the seek's time, 600.000000, where its own is 599.999400, so the line was taken off the frame grid.
  - **Two "re-latches"** were the picture stepping back a frame on a timed pull, just before a seek and at the loop's wrap: run ends, not re-latches.
- **Fixed:**
  - The gate no longer cuts a run. A run ends where its picture leaves the line, and after 8 slots of gate silence with the picture still on the line (a mute, or destination Computer).
  - A latch is confirmed on the next slot: the line comes from a frame whose step from the one before is exactly one frame; the sound still starts at the first slot that moved.
  - Re-latches are counted only when a new run latches at that same slot. Timed run ends are counted apart.
- **Smoke 3:**
  - **59.94 gate on: every run starts at −0.54 to −0.56 ms and holds it to 0.01 ms, with 0 steps.** Every Pause and seek end falls 26 samples into the next frame, which is the card's constant.
  - **23.976 gate off: every run at −0.19 ms** (control −0.19), and Pause ends exact. But two seek-while-playing ends were 32 and about 1,800 samples short. At 23.976 the picture is handed up to 125 ms ahead, beyond the 80 ms queue, and the seek empties the tap before the old run's last frames are read. Also 3 corrections of −2 samples in the last 60 ms before the loop's wrap: the picture holds the file's last frame on timed pulls, which gate off reads as a slip.
- **Fixed:** a prefetch ring. Each callback copies the current run's sound from the tap up to 133 ms past the queue, keyed by stream position and run. What the tap has lost by the time a position is scheduled comes from there.

The predictions below were written before any code and are unchanged.

#### Predictions, written 2026-11-10 night, before any 1c code

Against the control, which reads −0.58 ms at 59.94 and −0.17 ms at 23.976 (§10.16). "First sound" means the first sample of a run on the wire.

| # | Run | Prediction |
|---|---|---|
| D1 | `cont` 300 s, 59.94 and 23.976, gate on | Steady offset = control ± 0.1 ms; its whole p1–p99 range ≤ 0.05 ms. **0 discontinuities in the run, 0 nonzero corrections** (`[AUDIO-CORR] c=0` in every callback). 0 re-latches, 0 underruns after the first sound |
| D2 | The same, gate off | Steady offset = control ± 0.1 ms. Corrections only in the walk after a picture slip (§10.21: about 600 at 59.94, 1200 at 23.976 per slip); none between slips, none in the first minute |
| D3 | First sound, every run, both gates and rates | **Offset = control ± 1 ms at the first sample; no jump and no slew:** the offset at 0.5, 1, 5 s and at the end of the run within ±0.1 ms of it. The first sample is the first sample of the frame the picture held, ±1 sample (it falls in that frame's last showing). In at most 1 in 10 runs it is later, by the callback's lateness (≤ 20 ms), never earlier |
| D4 | Silence at Play | Measured by the bridge (`[SDI-AUDIO] latch` logs the gate's opening and the run's start, in stream samples) and on the wire (the held picture's frames before the first sound). Prediction: **the silence equals the picture's hold at Play, less one frame**, the frame whose own sound starts it. No sound before the picture moves |
| D5 | Pause | The sound ends within 2 samples of the end of the last frame that moved, then digital zero: no sample of the queued sound after it, and no inverted sound. Today (§10.21 build): about 150 ms of sound past the picture (by reading) |
| D6 | Seek while playing, loop wrap, frame step while paused, then Play | Each a run end and a new run: the old sound ends with its last frame as D5, the new one starts as D3. No sample from the wrong side of the edge |
| D7 | Output stop, then start, while playing | After the start, the first sound as D3. No stale sound from before the stop |
| D8 | Inside every run, both gates | 0 discontinuities other than gate-off slip walks. Every wire step matched to a logged correction |
| D9 | Live sources | Not run here: their path is unchanged code |

#### Verification, chain11 (2026-11-10, 21:05–22:51): results against D1–D8

Build: `.build-cc`, 1c with the prefetch ring, `-DMANIFOLD_CARDCLOCK`. Each run is one launch, with the wire captured throughout. Each launch waited for 10 minutes of HID idle with Resolve closed.
- `transport`: 2 cycles.
- `cont`: 300 s.
- `plays`: 5 cycles, 10 Plays.

Each ran at 59.94 and 23.976, gate on and off. Reports are `runs/v-{tr,c,p}-<rate>-<gate>.{segs,cont,plays}.report` in `~/Code/_scratch/manifold-1c-wire`. Session controls: −0.55 ms at 59.94 and −0.19 ms at 23.976.

**Analyser fix.** `w1c-wire.py` stopped locating at the fixture's end, so it read nothing after the loop's wrap. It now relocates there as a step. The transport `segs` reports were re-run (`*.segs2.report`), and the figures below come from those.

**Gate on: every prediction holds except D7, one session in four.**

| # | Gate on, 59.94 | Gate on, 23.976 |
|---|---|---|
| D1 `cont` | median −0.56 ms, p1–p99 −0.57 to −0.55 (0.02 ms). 0 steps, 0 nonzero corrections in 15,000 callbacks, 0 underruns | −0.19 ms at p1, median and p99. 0 steps, 0 corrections, 0 underruns |
| D3 first sound | 23 runs: −0.54 to −0.58 ms. At 0.5, 1 and 5 s and at the run's end: within 0.02 ms of the first. 0 slews | 24 runs: all −0.17 or −0.19 ms (the session's control), constant to 0.00 ms |
| D3 first sample's place | 26 samples into its frame (the card's constant, as the control) in 15 of 23. Later by 48–209 samples (1–4.4 ms) in 8: 3 seeks while playing lost exactly 48 samples (below), and 5 latches were late edges (the callback came after the run's start; 48–209 samples) | 8–9 samples into its frame (the card's constant) in 23 of 24. One output-start latch 1,124 samples late (below) |
| D4 silence at Play (gate opening → first sound, bridge) | 55–77 ms (10 Plays and `cont`) | 138–182 ms |
| D4 on the wire | The sound starts one frame before the picture moves, with the held frame's last showing, in every Play. No sound before | as 59.94 |
| D5 Pause | Every Pause ends 26 samples into the frame after the last that moved, then digital zero. The control ends there too | 8 samples into it (control ≈ 9), then digital zero |
| D6 seek while playing | The old run ends at its frame boundary (picture moving after). A 34–67 ms silence, then the new run at the control offset | Seek 600: one frame (41.7 ms) of silence. Seek 300: a clean cut with no silence, the offset −0.167 ms on both sides of the picture's change |
| D6 loop wrap | The sound runs to the file's last sample (the fixture's sound ends 42 samples before its last frame does), then silence over the 9 held frames, then the new run from 0 at the control | the same; the sound ends 60 samples before the last frame does, then 4 held frames |
| D6 step while paused, then Play | no sound on the steps; Play as D3 | as 59.94 |
| D7 output stop, start | Cycle 1: the stop pauses playback (`[ARBITER] exclusive device released — every deck paused`), and the Play after it is as D3. **Cycle 2, restarted while playing: no SDI sound at all for the rest of that output session** (below) | Both cycles as D3. The restart while playing latched 23 ms late: the live path's 200 ms preroll queue has to drain under 4,400 samples first |
| D8 | 0 steps, 0 unlocated samples, every sample on the wire exact against the source in all four gate-on runs | the same |

**D7 failure: no sound after an output restart while playing** (`v-tr-5994-on`, its third output session, 258–322 s).
- What happened:
  - The audio stop line reads `scheduled=9600f … real=0f`: the 200 ms preroll the live path writes, and nothing after it.
  - The runs path logged nothing in that session: no latch and no `runs` line. That line prints once per second of scheduled audio, so nothing at all was scheduled after the preroll.
  - Video ran normally: 3,876 frames completed, none late.
- Its preroll is the only difference from the sessions that worked: playing at the start (`silent=false → no handed frame to anchor to`).
- The same restart while playing worked in the other three runs (23.976 on, both rates off).
- The log cannot tell whether the audio callback stopped coming, or kept coming while the card stopped taking samples. **Cause UNKNOWN.**
- The test reached this state through the debug `output start` step, which skips the arbiter. ⌃⌥O and a device switch (`DeckLinkService.toggleOutput`, `selectDevice`) skip it too, so a user can reach it.
- Diagnostics added for the follow-up:
  - `[SDI-AUDIO] runs path entered`;
  - `!! holding over 1 s` (the queue not draining);
  - `!! no audio callback in the last 48 frames`, checked from the video callback;
  - the callback count in the stop line.

**The first 48 samples after a seek while playing are lost.** The tap's data after a seek begins inside a chunk. The read finds where it starts in 1 ms (48-sample) steps, so up to 47 samples of the new run go out as zeros. They are not filled in later, because the card has passed them. On the wire it shows as 48 samples (1 ms) at 59.94: the first sample lands 74 samples into the frame instead of 26. Fix, not made: after the 48-sample step that finds data, search back within those 48 samples one sample at a time.

**Gate off (the runs, steered after a picture slip, which §10.20 did not plan): faults, so it is dropped.**
- **D2:** `v-c-2398-off` had one picture slip, at 72.7 s (frame 1533 → 1535). The sound sat one frame (−41.8 ms) out and walked back in 1,004 corrections of 2 samples, taking 19.5 s, as §10.21's loop does. `v-tr-2398-off` did the same after an output start: 864 corrections.
- **D3:** `v-tr-5994-off`, first output session: all 5 runs at **+7.45 ms**, against a control of −0.55. The first sample landed 442–490 samples into its frame instead of 26. The second and third sessions in the same launch, `v-c-5994-off` and all 10 Plays of `v-p-5994-off` were right (−0.55 to −0.58). Cause UNKNOWN.
- **D6 loop wrap:** the held last frame is a timed pull off the line. Gate off reads it as a slip, so the run kept going past the file's end. The wire carries samples not in the source there, instead of silence.
- **D8:** `v-tr-5994-off`, before the cycle 2 Pause: 430 samples on the wire match no part of the source. A rewrite whose history no longer matched what the card held puts a sum of two sounds on the wire. 98 logged corrections were not found on the wire.
- §10.20 kept gate off on today's path (the §10.21 loop), with C8 "nothing on the gate-off path moved". **Changed after chain11:** the runs are used only under card lock (`cardTimeline`). With the gate off, a file goes back to the §10.21 loop, as a live source does. That path's figures are the anchor fix's (§10.21).

**D9** (live sources): not run. Their path is unchanged code.

#### Follow-up, chain12 (2026-11-10, 23:00–23:29): restarts while playing, and gate off back on the §10.21 loop

Build: the chain11 build, with two changes. Runs are used only with `cardTimeline` set, so a file with the gate off is back on the §10.21 loop. The callback diagnostics above are added. Mode `restarts`: Play, output stop and start (the arbiter pauses), Play, then 10 output stops and starts while playing, Pause.

**Gate on, `restarts` at 59.94 and 23.976 (`v2-rs-*-on`): 22 restarts while playing, the sound back after every one.** The chain11 failure did not recur, and none of the new diagnostics fired: no `!! holding`, no `!! no audio callback`. Each session entered the runs path on its 3rd callback with the 200 ms preroll queued, as in chain11. **The chain11 failure stays UNKNOWN:** it happened 1 time in 23 restarts while playing. The diagnostics stay in, so that the next occurrence names its cause.
- Every session's first sound is at the control: −0.55 to −0.58 ms at 59.94, and −0.19 at 23.976. It is constant to 0.02 ms through the session, with 0 corrections, 0 unlocated samples and no silences inside a session.
- After a restart while playing, the first sound is late into its frame: 24–1,263 samples (up to 26 ms). The latch waits for the live path's 200 ms preroll to drain under 4,400 samples, then starts at the next slot that moves. The offset is exact from that first sample. The picture runs on without sound for those milliseconds.
- **23.976 only: in 5 of 11 restarts the picture skipped one frame on slot 67, about 2.8 s after output start** (e.g. 1024 → 1026). The run ended on that timed pull (`off the line on a timed pull: … +2002.0 samples off`). The next run latched at the new frame, so the sound cut forward one frame with the picture: the offset was −0.187 ms before and after it, with one frame read at −41.9 ms at the cut. The skip is the picture's, under card lock (1b), not 1c's. Its cause is UNKNOWN; the 1b card-lock latch (`[CARDLOCK] latched (run)`) is the likely moment.

**Gate off on the §10.21 loop (`v2-tr-{5994,2398}-off`, `v2-c-2398-off`): today's behaviour, as C8 expects.**
- Play from 0, and Play after a step: the first sound is +42 to +147 ms off, then a RESYNC (7 per transport run, 1 in `cont`).
- Seeks while playing: 6–17 ms off, walked back over seconds.
- Corrections: 1,264 in the 300 s `cont`, and 3,400–4,900 per transport run.
- Steady state: −0.17 ms (23.976) and −0.54 ms (59.94) once settled.

**Raw captures** (`.raw`, `.cap`, `.marks`) of chain11, chain12, the smoke runs, the C0 probes and `ctl2` are deleted. Reports, logs, `av.csv` and `summary.json` are kept in `~/Code/_scratch/manifold-1c-wire/runs`.

#### Decided after chain12 (Robbie, 2026-11-10)

- **Gate off keeps today's loop (§10.21); it is not fixed.** When 1b, 1c and Stage 2 ship together in 0.9.3, the card lock becomes the default for all file playback with output on. `MANIFOLD_CARDLOCK_1B` stays only as a diagnostic switch. The gate-off faults above are therefore not 0.9.3 defects: no user reaches gate off.
- **Output restart: sound joining up to 26 ms after the picture is accepted** (the live path's 200 ms preroll draining under 4,400 samples, chain12). The 80 ms file audio queue (`kRunsDepthFrames` 3,840, `kRunsCommittedFrames` 4,400) and the 8-frame gate-silence timeout are confirmed.
- Next (§10.23): the seek loss, C6 (rate mismatch), C7 (44.1 kHz), 100 output restarts per rate, and the 23.976 picture skip at output start. Gate on throughout.

### 10.23 Stage 1c follow-up: the seek loss, C6, C7, restart stress, the 23.976 skip, 2026-11-11

Follow-up 2 (Robbie's decisions on these results, the SDK start sequence, start detect-and-recover): §10.24.

Gate on throughout. Build: `.build-cc`, `-DMANIFOLD_CARDCLOCK`, Profile, uncommitted. Chain `chain13` (smoke 15:39–15:46, main 15:55–18:06), each launch gated on Resolve closed and 10 min HID idle, guarded before and after. Reports, logs, `av.csv`, `events.csv` and `summary.json` in `~/Code/_scratch/manifold-1c-wire/runs` (`s13-*`, `ctl13-*`, `f-tr-*`, `c6-*`, `c7-*`, `rs-*`). Session controls (`syncout`): **−0.571 ms at 59.94, −0.187 ms at 23.976** (per-frame medians; the `cont` report's "after 60 s" line reads only the held frames at a 60 s control's end, so it shows +91 ms and NaN there).

#### What was built

- **1, the seek loss** (`DeckLinkBridge.mm`, `fillDesired`): after the 48-sample step that first finds data, search back one sample at a time to the first sample the tap holds. Counted as "seek starts found by the fine search" in the stop line.
- **2, C6, rate mismatch:** the renderer publishes each timed pull's due time (target + the 2 ms hysteresis) and the source frame duration with the handed frame (`MetalVideoRenderer.currentDeckLinkHanded`). At a mismatch (`|source frame / card frame − 1| > 5e-4`) a run latches at once on the first timed slot that moved. The picture's line is `phi = due − idx × card frame`. The sound's D is the lower envelope over the 2002-frame lattice, so no frame is shown before its sound starts: it equals the frame grid at matched rates, 2:1 and 5:2, and the due line at 25p on 59.94. The frame grid is confirmed on the next frame that moved, which fixes a latch frame carrying the seek's time. In a run, each slot is checked against the frame the line predicts there, not against half a card frame.
- **3, C7, 44.1 kHz files** (`AudioTapBuffer.swift`): the AVFoundation and libav paths' 44.1 kHz sound is resampled once, in the tap, by the existing `PolyphaseResampler` (64 taps, 1024 phases), on the file's own 48 kHz grid with the group delay taken out (`setStartPhase`, new). A stream started at any input sample has the same phase bits as one from 0. Rounded to 24 bits. Everything after the tap is the 48 kHz path. Live 44.1 kHz sources stay refused on SDI. Off-line check (`resample-ref --selftest`): chunk sizes 1024/4096/777 give identical output; a restart at any input sample differs from the stream from 0 only in its first 33 outputs (the window filling), 0 after.

#### Results

| Item | Result |
|---|---|
| 1, seek loss | **The bridge's 48-sample loss is gone.** Play, step-then-Play and loop starts land 25–27 samples into their frame at 59.94 (control 26), 9 at 23.976. **Seeks while playing still start late, by 29 samples (seek 600) and 15 (seek 300) at 59.94:** the first frame after a seek is the frame at or before the target (599.999396, 299.999687), its sound starts before the target, and the audio reader starts at the target. Those samples are never decoded; no search in the bridge can find them. Fix direction (decode path, not built): start the audio read at the landing frame's pts. |
| 2, C6 `cont` 600 s, on 1080p59.94 | **Sound continuous across every cadence step at 25, 23.976 and 29.97:** one segment each, 0 steps, 0 corrections, 0 unlocated, 1 latch, no run end in play. First showings: 29.97 −0.567 to −0.550 ms (span 0.02); 23.976 min/p1 −0.583, max +7.77 (the 2:3 cadence's half slot); 25 p1 −0.54, **min −0.75**, max +16.0 (a card frame's span, inherent). At 25p the bridge counted 90 of 14,949 first showings up to 8.8 samples (0.18 ms) before their sound: the picture's due line wanders by that much under 1 Hz steering, and the run's line is fixed at the latch. |
| 2, C6 transport | 25p: every run at the control's lower edge. 29.97: the seek-300 run is exact (−0.575 to −0.558; the analyser lost it after an 802-sample gap, recomputed directly). **Two faults:** (a) **c6-tr-2997, the run after the loop seek (1905): the whole run a card frame late (−17.26 ms).** Every frame after that seek carries a pts on a grid shifted by the seek time (1905.0031 + k × frame), so the grid check passed; but the latch slot's due time was one card frame past its pts, and the frames after it were shown a slot earlier than that line says. The bridge saw it: 445 frames "shown 801.2 samples before their sound starts". Fix direction: take the line from the first showings, not from one slot's due time (each first showing bounds phi to one card frame; intersect them over the first few frames, and re-derive D on an envelope miss). (b) **c6-tr-2398, the first Pause: the card appended the edge's rewrite instead of adding it.** The 474 cancelling samples played *after* the queue's end, so the sound ran 474 samples (9.9 ms) past its end, then 474 samples of its exact inverse, then zero (verified sample for sample). Every other edge in chain13 is clean. Why the card appended is UNKNOWN; the bridge could detect it (the buffered count grows by the rewrite's length). Same family as chain11's D8 (430 samples matching nothing). |
| 3, C7, 44.1 kHz at 59.94 | **`cont` 300 s and transport: every run −0.55 to −0.58 ms (control −0.571), 0 steps, 0 corrections, sample-exact against the resampled reference.** One difference: a run that starts on the stream's very first sample (Play after frame steps: the tap is reset and decoding starts at the play position) opens with **34 samples of the resampler's window filling** (error decaying from 96,145 LSB to 0), the band-limited start of a cut. Not counted as a defect. `w1c-wire.py` needs `W1C_ONSET=48` to locate past it. |
| 4, restarts, 100 per rate while playing | **23.976: sound back after 100 of 100. 59.94: 5 of 100 sessions had no SDI sound at all**, back at the next restart each time (chain11's D7, 1 in 23). **The audio callback did not stop** (~601 callbacks per failed session). **The card did not consume what was queued:** `!! holding over 1 s: buffered 9600, now ≈48,600, queue end 9600` in all 5. The card's stream clock ran a second past the end of the queue while its buffered count stayed at the 9,600-sample preroll. The latch waits for the queue to drain under 4,400 samples, so it never latched. Start logs are line for line the same as good sessions. Cause UNKNOWN. |
| 4, same mechanism, partial | The bridge's own edge lines measure where the card's audio consumption point sits against video stream time (`queue end − queued − now`): **2–4 samples in every normal session** (all 199 restart sessions). **+989 in f-tr-2398's first session**, whose sound sat +20.35 ms (986 samples) off the control for the whole session, and **+386 in chain11's `v-tr-5994-off`**, the unexplained +7.45 ms (384 samples). So the card's audio sometimes starts at a different point than its video at output start; the 5 silent sessions are the extreme, where it never starts. Both are first or restarted output sessions. |
| 5, the 23.976 skip | **Confirmed on the new runs: every skip is on slot 67** (the slot-timeline window's 64 + the 3 preroll slots): 61 of 100 restarts at 23.976, **20 of 100 at 59.94**. The sound follows the picture forward one frame (+2002 / +801 samples) with the offset unchanged on both sides. Not the 1b latch. Mechanism and proposed fix below. |

#### Item 5: the slot-67 skip (read-only analysis, not built)

`MetalVideoRenderer.swift` ~5571–5574: the pull's slot timeline is the minimum of the last 64 `host − slot × frame` offsets. The 4 preroll pulls (slots 0–3) come within ~1.5 ms of each other, so slot 3's offset is about 3 frames' worth minus 1.5 ms lower than the paced ones: ~32 ms at 23.976 (5.6–11.4 ms at 59.94). At slot 67 it leaves the window; `target` jumps that much later at once, and the pull skips (+2) when `target − handed + jump ≥ frame + 2 ms`. That matched all 8 chain12 runs with a jump; restarts whose preroll happened to be neutral had none, and gate-off runs skip at 67 too. The clock does not step at the 1b latch (±0.01 ms); the latch at ~2.1 s is the 1 Hz steering's timing, a coincidence. **Proposed fix:** record a slot offset only for a paced pull (`host − lastPull.host > card frame / 2`), so the preroll and catch-up bursts never enter the window. Predicted: no +2 skip at either rate, no audio run end or re-latch at slot 67, the target ~32 ms later (23.976) from slot 4 on. No effect on 1b's latches.

#### Analyser and harness changes

`w1c-wire.py`: `W1C_CARD` (first-showing statistics at an output rate other than the file's), `W1C_TOL`, `W1C_ONSET`, ratecodes `25` and `2997`. `w1c-run.py`: `W1C_MODE=<label>` passes the output mode as a launch argument (argument domain; nothing written to defaults) and fails unless the log confirms it. Known analyser limit: after an unlocated window it walks on in 0.1 s steps without checking for silence, and it can lose a run after a short gap (c6-tr-2997, recomputed by hand).

**Package tests:** `AudioResampleTests` and `PolyphaseResamplerTests` pass. `SenderReportSlopeCrossCheckTests.testSteeringCallsItsCompanionWithoutReportingWindows` (live steering, not touched) failed once in a full `swift test` run (20.04 vs 10.0 ± 0.1) and passed 3 of 3 run alone: order- or timing-dependent.

### 10.24 Stage 1c follow-up 2: the SDK start sequence, start detect-and-recover, C6 from first showings, slot 67, seek audio, 2026-11-11

Decisions (Robbie, 2026-11-11) on §10.23's results. Gate on unless noted. Build: `.build-cc`, `-DMANIFOLD_CARDCLOCK`, Profile, uncommitted. Chain `chain14`: smoke 18:2x (`s14-*`), main 18:55–21:06 (`ctl14-*`, `rs14-*`, `f14-tr-*`, `c614-*`), C6 re-run 21:10–21:56 on a rebuild (`c614b-*`). Each launch gated on Resolve closed and 10 min HID idle, guarded before and after. Everything is in `~/Code/_scratch/manifold-1c-wire/runs`; fixtures kept. Session controls (`syncout`, per-frame medians): **−0.550 ms at 59.94, −0.187 ms at 23.976**.

#### The SDK's start sequence against ours

Source: `docs/DesktopVideoSDKManual.pdf` §2.4.2 (scheduled playback), §2.5.3.16–2.5.3.23, and the SDK samples FilePlayback, SignalGenerator and InputLoopThrough. The manual's order: EnableVideoOutput, EnableAudioOutput, SetScheduledFrameCompletionCallback, SetAudioCallback, BeginAudioPreroll, ScheduleVideoFrame with RenderAudioSamples filling, EndAudioPreroll "when audio preroll is complete", StartScheduledPlayback. **Ours matches that order.** Differences, call by call:

1. **EndAudioPreroll** was called on the start thread straight after the video preroll, whether the audio preroll was complete or not (as FilePlayback does; the manual, SignalGenerator and InputLoopThrough wait for the audio level). **Fixed:** `finishAudioPreroll` waits up to 500 ms for the callback to finish the preroll, then ends it under the callback lock and logs which. In all 254 chain14 starts the preroll was already complete (0.0 ms, 2 callbacks, 9,600 samples), so this changed nothing measurable here.
2. **StartScheduledPlayback ran unserialised with RenderAudioSamples:** in 184 of 204 chain13 starts the third callback ran before Start returned. **Fixed:** a recursive mutex held across Start; the callback try-locks and skips one call if it is held (1 skipped per start in 202 of 203 gate-on starts).
3. **The stop never waited for ScheduledPlaybackHasStopped** (0 in 200 chain13 restarts; the callback was unset at once). FilePlayback waits. **Fixed:** `stop()` waits up to 500 ms; it arrived 0.6–0.8 ms after StopScheduledPlayback in all 204 gate-on stops.
4. **Audio preroll depth:** 200 ms of sound against 4 video frames (67 ms at 59.94). The manual asks for preroll "sufficient for the video frames scheduled"; more is not forbidden. **Not changed; decision below.**
- Minor, not changed: FlushBufferedAudioSamples after StopScheduledPlayback is redundant (Stop flushes, §2.5.3.23). We disable audio before video; FilePlayback disables video first.

All three fixes have a DEBUG switch back to the old sequence, `MANIFOLD_SDI_AUDIO_START=legacy` (used for the gate-off run below).

#### What was built

- **1, detect-and-recover at output start** (`DeckLinkBridge.mm`, `checkStart`, `restartStartAudio`). From each callback after Start: the card's consumption point (`stream frames scheduled − queued`) against its video stream time. Once 480 samples (10 ms) have been consumed: within 12 samples logs `[SDI-AUDIO] output start: the card's sound started with its picture, ±N samples`. Off by more, or nothing consumed by 12,000 samples (250 ms), flushes, reschedules from 960 samples past the card and logs one `!!` line. At most 3 restarts. DEBUG switches: `MANIFOLD_SDI_AUDIO_RECOVER=0` (measure only), `MANIFOLD_SDI_AUDIO_START_FAULT=stall|gap:<n>` (inject).
- **2, C6 from the first showings** (`latchCad`, `observeCad`). Each first showing at slot i bounds the picture's line: `phi ≥ pts − i × card frame`, and `< that + a card frame` when the slot before showed an earlier frame. The run keeps the intersection. A frame shown before its sound (phi under the lower bound by more than 2 samples) moves the line up at once. Frames shown a slot later than the line says (at or past the upper bound) move it down on the second in a row. **Rebuilt after the main chain** with two changes (below): a frame more than a card frame off the line is ignored, and the queue is rewritten only when D moves by more than 4 samples (0.083 ms).
- **3, slot 67** (`MetalVideoRenderer.swift`, `deckLinkPullSlotLocked`): a slot offset enters the 64-slot timeline only from a paced pull (`host − last pull > card frame / 2`). §10.23's proposed fix as written.
- **4, seek audio** (`FrameEngine.swift`, `beginReading`, AVFoundation path): the audio read starts at the landing frame's time (`min(start, that frame's pts)`); the clock stays at the target. The libav path already armed at the frame's time.
- **5, an edge appended by the card** (`rewriteFrom`): the queued count after a rewrite is compared with before; grown by more than half the rewrite logs `!! edge (…) APPENDED by the card` and counts it. No correction. The rewrite's lower limit is now also the stream's first scheduled sample (needed after a start restart: an edge below it gave a false APPENDED in the smoke).
- **6, the flaky test** (`SenderReportSlopeCrossCheckTests`): `emitWindow` (`LiveAudioResampleSteering.swift:1703-1712`) hands each window to the concurrent global utility queue, so windows can arrive out of order. The test now waits for every companion line (5 s deadline) and checks the earliest by elapsed time. Before: 5 of 40 failed under 32 busy loops. After: 40 of 40 under load, the class 21 of 21, the full suite 975 of 975 twice.

#### Results

| Item | Result |
|---|---|
| 1, start gap, 254 starts | **Every start within −2 to +4 samples:** 59.94 gate on 100 (+1/+2 in 96), 23.976 gate on 102, 59.94 gate off on the old sequence 51. **No offset start** like chain13's +989 or chain11's +386. Injected faults: `stall` detected at ~12,300 samples and `gap:500` at +501, each restarted once and then +2/+3 (smoke). |
| 1, silent starts | **59.94 gate on: 1 of 101. 23.976: 0 of 102. 59.94 gate off, old sequence (today's shipped path): 1 of 51.** Same signature as chain13's 5: the queue sat at 9,600, nothing consumed, the stream clock ran on. **Detected in the gate-on session, not recovered:** FlushBufferedAudioSamples left 5,999 samples queued, and the queue then stayed at 5,999 through 3 restarts (`!! … giving up`); the session stayed silent on the wire (18.2 s gap). The next output start was normal (+2). **Only a full output stop and start has revived the card.** Not tied to the card frame phase at Start. Chain13 had 5 of 100 at 59.94; 1 of 101 is too few starts to credit the sequence fixes. |
| 3, slot 67 | **Gone:** off-the-line run ends at slot 67 went from 21 of 98 (59.94) and 61 of 100 (23.976) restarts to **0 and 0**. 0 picture skips in all 101 and 102 sessions on the wire. Left: **6 one-frame holds at 59.94 gate on** (slots 17, 38, 94, 115, 133, 720; chain13: 1, at slot 13), none at 23.976 or gate off. The sound followed each hold (one −800 sample step) with the session's offset unchanged. Cause not established (the pull at slot 38 took the frame before one the clock had passed). |
| 4, seeks while playing | **The decode-path loss is gone:** seek 600 starts 27 samples into its frame (was 55), seek 300 27 (was 41) at 59.94, against the card's 26; 23.976: 9 in all 14 runs. **Three runs at 59.94 still start late by 101, 78 and 126 samples:** the two loop wraps (end of file → 0) and one seek to 310. In each the bridge logged `edge (latch) … late 125 / 78 / 100 samples`: the run's latch, confirmed on the next frame that moved, reached the card after it had played past the run's start. Not the decode path. |
| 5, appended edges | **5 in chain14, all `fill` edges at the end of the file** (stream ~1.97 M, queue grown by 61–448 samples). 0 on any latch, run-end or re-derive edge, 0 in 203 restart sessions. |
| 2, C6, first build | Fixed what it was for, but **two defects:** (a) **c614-c-25: 11 sound steps in 600 s**, each a re-derive of 1–3 samples as the due line wandered under steering; (b) **c614-tr-25: the seek to 600 landed on the old run's 0.04 s grid**, was taken as a frame of the run, and moved D by 27 million samples instead of ending the run. The "late" count on those rewrites was measured from the run's start (138 M samples); now 0 for a re-derive. |
| 2, C6, rebuild (`c614b-*`) | **25p: 1 step in 600 s** (one re-derive of +5 samples); **0 re-derives at 23.976 and 29.97.** First showings against the control (−0.550): continuous min/p1 25p −0.417 p1, 23.976 −0.562, 29.97 −0.579; every seek run's p1 −0.58 to −0.27. **The 29.97 run after the loop seek is exact** (chain13: −17.26 ms for the whole run). The bridge counted 5 frames shown before their sound across the three continuous runs (chain13: 90 at 25p alone, up to 0.18 ms). |
| 2, the one frame per run | Each continuous run, and some seek runs, has **one frame 9–17 ms early: always the last frame before a Pause or a seek.** That frame's first showing was the untimed (paused) pull, after the run had ended, so it has no sound under it; the analyser scores it against the previous sound. 25p: Pause at clock 599.963, run end at source 599.949, frame 14999 (599.960) first shown paused. Whether it happens depends on where the Pause lands within the frame; chain14's first build happened to have none. A property of the end of a run, not of the C6 line. |
| Gate off, start of play | The old sequence's sessions start +37 to +133 ms off and walk back in −2 sample steps: the known §10.21 gate-off loop, not the card (the bridge's start gap read +1/+2 in the same sessions). |

Smoke note: two smoke runs showed picture holds and multi-frame skips with 0 dropped or late frames on the card. They overlapped the test agent's 32-loop CPU load; the two later smoke runs and the whole main chain had none.

#### Decisions needed (Robbie)

1. **Silent start recovery.** Flushing and rescheduling does not revive a card that has not started consuming. Options: (a) restart the whole output (stop, preroll, start: a visible picture interruption of a few hundred ms); (b) try DisableAudioOutput/EnableAudioOutput during playback (the manual neither allows nor forbids it; untestable without the real fault, ~1 in 100 starts at 59.94); (c) leave detection and the log line only. Present in shipped builds (1 of 51 gate off).
2. **Audio preroll depth** (difference 4): keep 200 ms, or prerolling only what covers the scheduled video.
3. **Late latch at a loop wrap or seek at 59.94** (78–126 samples lost): latch on the first moved frame as C6 does, or accept.
4. **The 59.94 one-frame holds** (6 of 101 gate-on restarts): investigate now or after 0.9.3.
5. **Appended fill edges at end of file:** a correction rule, or log only.
6. **Production steering order:** `FrameEngine.swift:3838`'s companion receives windows through the same concurrent queue as the test. Its ordering is UNKNOWN; a serial queue would guarantee it.

Robbie's decisions on these (2026-11-11), what was built and the results: §10.25.

### 10.25 Stage 1c follow-up 3: silent-start recovery, preroll depth, the 16.4 SDK, seek re-sync, holds gate off, the steering queue, 2026-11-11

Decisions (Robbie, 2026-11-11) on §10.24's "Decisions needed". Build: `.build-cc`, `-DMANIFOLD_CARDCLOCK`, Profile, uncommitted (`fu4-build.log`; item 4's follow-up `fu5-build.log`). Chain `chain15`: smoke 22:25–22:28 (`s15-stall`), main 22:28–23:29 (`rs15-*`, `f15-tr-*`); `chain16` (item 4 follow-up, `f16-tr-*`). Each launch gated on Resolve closed and 10 min HID idle, guarded before and after. Runs are in `~/Code/_scratch/manifold-1c-wire/runs`. Session control as §10.24: −0.550 ms at 59.94, −0.187 ms at 23.976.

#### What was built

- **1, silent-start recovery: restart the whole output, at most once per output start** (production).
  - `DeckLinkBridge.mm` `checkStart` → `silentStart`: once 12,000 samples pass with nothing consumed, the bridge stops checking and hands one line to the service's `silentStart` block (`DeckLinkBridge.h`), with `restart` set unless this start is itself the recovery's (`outputRestart`) or recovery is switched off.
  - `DeckLinkService.swift` `recoverSilentStart`, on the service queue: stops the bridge and the renderer's DeckLink output, then `startOutputOnQueue(…, recovery: true)`. It logs one line, `[SDI-AUDIO] !! output start: the card's sound did not start: … restarting the whole output (once per output start)`. A start generation counter makes a late callback from a start that has since been stopped or replaced do nothing (and logs that). The recovery's own start logs `started with its picture, ±N samples (the silent-start recovery's output restart)`. If it too is silent, it logs `NOT restarted` and stays silent: there is no second restart.
  - A start that began consuming off its picture still gets the §10.24 flush restarts first. If those time out with nothing consumed, the silent-start path takes over (seen once, below).
  - Counted in `SDIStartRecoveryStats` (`DeckLinkService.swift`). Export Diagnostics' PICTURE RECOVERY section gains `SDI output start : N silent start(s) (X recovered by an output restart, Y not restarted) since launch` and `Last silent start:` (`DiagnosticsExport.swift:915-917`). `SDI-AUDIO` is added to the log tags the export collects.
  - The DEBUG fault switches (`stall`, `gap:`) do not apply to the recovery's own start, so each injected fault can be seen recovered.
- **2, preroll depth** (DEBUG switch `MANIFOLD_SDI_AUDIO_PREROLL=video|200`): `beginAudioPreroll` prerolls `rate × pool frames × frame duration` (3,203 samples at 59.94) instead of 200 ms, in both the anchor and the runs paths. **Not kept** (results): the default stays 200 ms and the switch stays DEBUG-only.
- **4, seek re-sync on the first frame that moves** (`latchRun`, `confirmRun`, `processSlots`). A matched-rate run latches at once on the first timed slot that moved, provisionally. The next timed slot settles it:
  - one frame on: confirmed;
  - the same frame (the first frame held): the start moves to this slot, the held frame's last showing, and the queue is rewritten. Lateness is measured against the new start;
  - a step off by between 2 samples and half a frame: the line is re-derived from this slot and the start kept (`latch: line from the next frame`);
  - anything else: confirmed, then checked against the line as any other slot.
  
  The candidate (`m_cand`) that waited for the next slot is gone. Run starts emit `[AUDIO-CORR] k=a` (`noteRunStart`). The stop summary counts `provisional latches moved to a held first frame` and `re-derived from the next frame`.
  - **Follow-up after chain15** (`fu5`): the "held frame's last showing" test now accepts any step forward under 1.5 frames instead of one frame ±2 samples, because a seek's landing frame carries the seek's time (below).
- **6, live steering's window queue is serial**: `LiveAudioResampleSteering.swift:331` `emitQueue`, a serial utility queue, now carries both `emit` and `emitWindow` (they used the concurrent global utility queue). So the companion at `FrameEngine.swift:3838` receives windows in order. The test `SenderReportSlopeCrossCheckTests` now also asserts that order (`box.facts.map(\.elapsed) == sorted`): class 21 of 21.
- **7, `docs/BLACKMAGIC_SILENT_START.md`**: the report for Blackmagic developer support.

#### Results

| Item | Run | Result |
|---|---|---|
| 1, injected silent starts | `s15-stall` (2 restarts), `rs15-stall` (20 restarts) | **Every injected silent start recovered: 4 of 4 and 22 of 22.** One `restarting the whole output` per silent start, 0 `NOT restarted`. Each recovery's start read +1 to +3 samples. On the wire: 22 sound segments for 22 recovered sessions, every one starting at −0.54 to −0.58 ms (the control) with 0 steps. The recovery costs a visible picture restart about 0.3 s into the session (the analyser counts it as picture events). |
| 1, natural silent start | `rs15-5994-pv` | **1 in 102 starts, recovered.** The card consumed 1 sample of 3,841 and then nothing. So it was first read as off its picture (−1,056 samples) and flushed once (3,840 left). It then timed out with nothing consumed and **the output restart recovered it: +3 samples, sound on the wire**. |
| 2, preroll depth, 100 restarts at 59.94 gate on | `rs15-5994-pv` against `rs14-5994` (§10.24) | **Silent starts: 1 of 102 (chain14: 1 of 101; chain13: 5 of 100): unchanged.** **Start gaps moved one sample later:** +2/+3 in 97 (chain14 +1/+2 in 96), range +1 to +4. **The first picture frame was held 1–6 extra slots before the sound and the picture's first move at 69 of 100 starts (chain14: 0 of 99; each run's first session excluded).** The sound started on that frame's last showing, as designed, but the picture stalls 17–100 ms at most starts. Mid-session one-frame holds: 3 (chain14: 5). Late latch edges 1 (the silent session), chain14 28. **Verdict: not kept.** Silent starts did not drop, and the start picture got worse. |
| 4, seeks and loop wraps at 59.94 | `f15-tr-5994` against `f14-tr-5994` | **Fixed:** both loop wraps (end of file → 0) now start 26 and 25 samples into frame 0 (chain14: 152 and 127, the late latch). The cycle-2 seek to 600 starts on −29572 at 599.999 (chain14 lost that frame: −29571 at 600.016). The cycle-2 seek to 300 starts on −47554 at 300.000 (chain14: −47553). The seek to 310 starts 25 into its frame (chain14 105). **Late latch edges: 0 (chain14: 3, 303 samples).** Provisional latches re-derived from the next frame: 3. **Still losing a frame, in chain14 too:** (a) the cycle-1 seek to 300, whose landing frame (stamped 300.000000) was shown twice and the sound began on the next frame (−47553); (b) both Plays after a paused seek to 1905, where the paused frame (stamped 1905.000000) got no sound and the sound began on the next frame (1905.003). In both, the landing frame carries the seek's time, not its own pts, so its step to the next frame (786 and 149 samples) failed the one-frame ±2 test for "the held frame's last showing". Fixed in `fu5`; chain16 below. |
| 4, after the `fu5` fix, 59.94 and 23.976 | `f16-tr-5994`, `f16-tr-2398` | **Every seek and loop wrap now starts its sound on the landing frame, with 0 steps and 0 late edges.** 59.94: the seek to 300 starts on −47554 at 300.000 in both cycles. Both Plays after the paused seek to 1905 start on the paused frame −16887 at 1904.986, from its last showing. Loop wraps start 27 samples into frame 0, and the seeks to 600 on −29572 at 599.999. 23.976: Play after the paused seek starts on −19862 at 1904.986 (chain15: −19861); every other seek and wrap 9 samples into its frame. Every segment's offset −0.54 to −0.58 ms (59.94) and −0.19 ms (23.976), the controls. **Not seek or loop:** the output restart during play again lost sound at 23.976 (7,248 samples missing, first sample 1,183 into its frame; the tap race above), and at 59.94 started 3 frames after the restarted picture (−45750 after −45753, as in chain14). |
| 4, seeks and loop wraps at 23.976 | `f15-tr-2398` | Every seek and loop wrap starts 8 samples into its frame (the control). Unchanged from chain14 except the output restart below. |
| 4, output restart during play (the transport loop's `output stop/start` step) | `f15-tr-2398` session 3 | **18,582 samples missing at the restart, 387 ms of silence on the wire** after the latch (sound from source 330.592 instead of 330.205). chain14: 68 samples. The latch read the tap at 330.205 while the tap, refilling after the restart (pts 333.0 → 334.1 in 50 ms), evicted its oldest samples past its 4 s cap. The rewrite found nothing to read until source 330.58. A race between the tap's refill and the run's first read, not a seek. Not fixed, not in scope. The same step at 59.94 (`f15-tr-5994`) missed 954 samples (chain14: 941). |
| 5, one-frame holds, 50 restarts at 59.94 gate OFF | `rs15-5994-off` (today's start sequence) | **1 one-frame hold** (69.05 s, frame 2959, 9.4 s into its session), plus the +2 skip at 29.6 s that every gate-off run shows at its first session. chain14's gate-off run (old sequence, 51 restarts): 0. Gate on: 5 in 100 (chain14), 3 in 101 (`rs15-5994-pv`). **So the holds occur gate off too.** At 1 in 50 against 3–5 in 100, the rates cannot be told apart at these counts. Measure only (`an/holds.py`). The same run had 0 silent starts in 52 and 0 late edges. |
| 6 | unit tests | `LiveAudioResampleTests.SenderReportSlopeCrossCheckTests` 21 of 21, with the new order assertion. |

#### Item 3: the 16.4 SDK

**The 16.4 SDK headers are not on this Mac.** What is present: `docs/BlackmagicDeckLinkSDK16.0` (what we compile against, `BLACKMAGIC_DECKLINK_API_VERSION` 0x10000000), an old 10.11.2 SDK inside the NDI SDK examples, and `/Library/Frameworks/DeckLinkAPI.framework` 16.4, which ships no headers. Blackmagic's public 16.4 release notes list DeckLink IP HD (NMOS registry) support and a Cintel fix; nothing on scheduled playback or audio. Sources: [Blackmagic SDK page](https://www.blackmagicdesign.com/es/developer/products/capture-and-playback/sdk-and-software), [Newsshooter](https://www.newsshooter.com/2026/08/24/blackmagic-design-desktop-video-16-4-update/), [No Film School](https://nofilmschool.com/desktop-video-update-16-4).

**To download:** "Desktop Video SDK 16.4" from the Blackmagic developer page (Capture and Playback → SDK and software). Suggested place: next to 16.0, as `docs/BlackmagicDeckLinkSDK16.4`. Then diff, for scheduled playback and audio:
- `Mac/include/DeckLinkAPI.h`: IDeckLinkOutput, IDeckLinkVideoOutputCallback, IDeckLinkAudioOutputCallback, their IIDs;
- `DeckLinkAPITypes.h`, `DeckLinkAPIModes.h`;
- `DeckLinkAPIVersion.h`;
- any new `DeckLinkAPI_v16_0.h`-style compatibility header (one would mean an interface IID changed);
- the SDK ReadMe's release notes.

Not updated, as decided.

**Superseded 2026-11-12 (§10.26, item 2):** 16.0 is the current SDK; there is no 16.4 SDK to download. Driver updates ship without new headers.

#### Status

- Silent start: **recovered in production code** (verified: 26 of 26 injected, 1 of 1 natural). Cause still UNKNOWN; asked of Blackmagic (`docs/BLACKMAGIC_SILENT_START.md`).
- Preroll depth: 200 ms stays.
- Seek re-sync: **every seek, loop wrap and Play after a seek starts on its landing frame at 59.94 and 23.976 (chain16), 0 late edges.**
- Holds: present gate off as well; cause UNKNOWN.
- Output restart during play: the first frames' sound can be lost (tap race at 23.976, 387 ms and 151 ms in two runs; 3 frames at 59.94). New finding, open (`BUGS.md`).

**Follow-up 4 (§10.26, 2026-11-12):** the output restart during play is fixed (preroll depth for a file on the card's timeline, an 8 s tap). Two items above are corrected there: the shallow preroll did not make the start picture worse (the analyser counted the renderer's own start hold), and the ~950 samples "missed" at 59.94 were past the end of the file at the loop's wrap, not at the restart. The silent-start recovery now waits 500 ms between stop and start. Preroll depth: no longer 200 ms for a file on the card's timeline.

### 10.26 Stage 1c follow-up 4: sound with the first moving frame after an output restart, the SDK, silent starts with capture closed, 2026-11-12

Decisions (Robbie, 2026-11-12) on §10.25. Gate on throughout. Build: `.build-cc`, `-DMANIFOLD_CARDCLOCK`, Profile, uncommitted. Builds in order: `fu6` (preroll 80 ms, tap 8 s), `fu6b` (preroll at least the video preroll's, the parked re-read), `fu6c` (DEBUG `recover` fault), `fu6d` (DEBUG recovery gap switch), **`fu6e` (the 500 ms recovery wait in production: the final build)**. Chains: `chain17` smoke and smoke2 (`s17-*`, `s17b-*`), then by a script edit made while it ran, `f17-tr-2398` and `nc17-5994` on `fu6b`; `chain18` (`s18-recover-*`, `fu6c`); `chain19` (`s19-*`, `fu6d`); `chain20` (the verification, `fu6e`). `fu6b` to `fu6e` differ only in the silent-start recovery, which neither `f17-tr-2398` nor `nc17-5994` reached. Each launch gated on Resolve closed and 10 min HID idle, guarded before and after, launched by absolute path, quit by PID. Runs in `~/Code/_scratch/manifold-1c-wire/runs`.

#### Item 1: why the sound came late after an output restart

Two causes, read from §10.24–§10.25's runs before any change (`an/starthold.py`, `an/taplead.py`, `an/restarts.py`, new):

- **The 200 ms preroll held the latch back.** After an output start the picture is held while the renderer's clock settles (~50 ms, the 1b renderer move): slots 0–3 are the preroll, 4–6 untimed, and the picture moves at play rate from slot 7 or 8 (`rs14-5994`: 41 and 45 of 92 starts). A run latches only once the queue is inside the committed window (4,400 samples), and the preroll left 9,600. So the run latched at slot 9–10, 1–3 slots after the frame before the first move (`rs14-5994`: 0 of 99 restart segments on that frame on the wire). That is the "3 frames".
- **The tap had already dropped the samples.** In steady play the tap leads the picture by ~2.5 s; just after an output start it led by up to **4.87 s** (`rs14-2398`; 4.56 at 59.94), past its 4 s window. Each running renderer move pushes it about a second on (`FrameEngine.rereadSoundAfterMove`, §10.12). So the run's first samples were gone: 58 of 99 restart segments at 59.94 started 109–794 samples into their frame (`rs14-5994`), and at 23.976 the sound came back up to 387 ms late (§10.25).
- **§10.25's preroll verdict was the analyser, not the picture.** With the shallow preroll (`rs15-5994-pv`) the picture started moving at the same slots as with 200 ms (7–8), and the sound started on the held frame's last showing in 69 of 100 restarts (the other 31 lost samples to the tap). The "first picture frame held 1–6 extra slots" counted the renderer's own start hold, which is there at 200 ms too, against a sound that now began before it. The picture did not get worse.

#### What was built

- **Preroll depth** (`DeckLinkBridge.mm`, `beginAudioPreroll`): a file whose sound goes on the card's timeline (gate on, a source that pulls by time; read from the renderer at preroll) prerolls the runs' 80 ms (3,840 samples), **or the video preroll's duration if longer** (8,008 samples at 23.976, 7,680 at 25p, 6,406 at 29.97; 3,840 from 50p up). The queue is then inside the committed window by the first timed move, and the run latches there, as at Play and seek. Everything else (live sources, gate off) keeps 200 ms. One line per start: `[SDI-AUDIO] audio preroll: N samples`. DEBUG: `MANIFOLD_SDI_AUDIO_PREROLL=200` forces the old depth, `video` the video preroll's alone.
- **Tap window 4 s → 8 s** (`AudioTapBuffer.swift`, `windowSeconds`): 3.1 MB stereo at 48 kHz, 24.6 MB at 16 channels.
- **The silent-start recovery waits 500 ms between its stop and its start** (`DeckLinkService.swift`, `recoverSilentStart`, `silentStartRestartGap`; production). Found in the first smoke: §10.25's recovery had been tested at 59.94 only. At 23.976, back to back while playing, the recovery's own start often lost its whole audio queue within ~20 ms of Start, its start check read "off its picture" and gave up after 3 flushes, and the sound ran off its picture on the wire for the session, **mostly 0.85–0.99 s late**: 2 of 2 injected stalls on `fu6` (`s17-stall-2398`), 2 of 2 on `fu6b` (167 ms preroll, `s17b-stall-2398`), **1 of 2 with the old 200 ms preroll** (`s17b-stall-2398-200`: −3.9 ms after a 903-sample gap; so not this round's change), and 3 of 5 forced on clean starts (`s18-recover-2398`, below: not the stall's queue 10 s ahead either). At 59.94, 1 of 5 forced recoveries while playing (`s18-recover-5994`, +219 ms on the wire). Paused recoveries were good in every run (2 per run). **With 500 ms between stop and start: 12 of 12 at 23.976 started with their picture, 8 of them while playing, every session's sound exact on the wire** (`s19-recover-2398-g500` 7 of 7, `s19-stall-2398-g500` 5 of 5). Why back to back fails is UNKNOWN. The cost: the picture is off the wire 0.5 s longer at a recovery. Dropped, and logged, if the output stops or restarts during the wait. DEBUG: `MANIFOLD_SDI_RECOVERY_GAP_MS` overrides it (0: back to back).
- **DEBUG fault `MANIFOLD_SDI_AUDIO_START_FAULT=recover`** (`DeckLinkBridge.mm`, `checkStart`): a start that consumed normally is handed to the silent-start recovery anyway, so the recovery can be exercised without `stall`'s preroll 10 s ahead. Logged `[SDI-AUDIO] test: this start consumed normally …`.
- **Play after an output restart made while paused** (`FrameEngine.swift`, `rereadSoundAfterMove`): a parked renderer move now reads the sound again from the frame on screen (the frame whose interval holds the clock), not from the clock, the seek's rule (§10.23 item 1). Found in the first smoke: the paused frame's samples before the clock were never in the tap (686 samples at 59.94, 1,260 at 23.976; in `rs14-5994` and `rs15-5994-pv` too).

#### Item 1: results

Session controls (`syncout`, per-frame medians, `ctl20-*`): **−0.567 ms at 59.94, −0.208 ms at 23.976** (chain14: −0.550, −0.187). Wire checks per sound segment (`an/restarts.py`): the first offset, where the first sample falls in its frame (the card's constant: 26–27 samples at 59.94, 9–10 at 23.976; later means samples lost), steps. Bridge: `missing` samples per output session (scheduled as zeros, never filled) and each latch's sound slot. Final build `fu6e` unless noted.

| Run | What | Result |
|---|---|---|
| `rs20-5994` | 50 output restarts while playing, 59.94 | **50 of 50 restart segments start 26–28 samples into their frame, first offset −0.588 to −0.546 ms, 0 samples missing in all 55 sessions.** Every latch: sound from the slot before the first timed move, the held frame's last showing (slot 7/8 → 6/7 mostly). 1 step: a one-frame picture hold 1.6 s into one session, the sound following it (the known holds, §10.24–§10.25; 1 in 50). **3 natural silent starts in 55, each recovered** by the output restart with its 500 ms wait, sound exact on the wire after it. Before (`rs14-5994`, 200 ms, 4 s tap): 58 of 99 segments started 109–794 samples late, 0 of 99 on the held frame |
| `rs20-2398` | 50 restarts while playing, 23.976 | **50 of 50 start 9 samples into their frame at −0.187 ms, 0 steps, 0 missing in 52 sessions, 52 of 52 starts with their picture.** 49 located by the analyser; the 50th by hand (`an/session.py`): the analyser lost it after an output-stop gap that was not digital zero (below). It is 11.783 s of sound, 0 samples off one mapping, its first sample 9 samples into the last showing of the held frame 13506, at that frame's source time to the sample |
| `rs20-stall-5994` | 10 injected silent starts while playing (`stall`), 59.94 | **10 of 10 recovered (12 of 12 with the 2 paused)**, 0 `NOT restarted`, 0 missing; each restart segment 25–27 samples into its frame, −0.563 to −0.513 ms (the card's start gap, +1 to +4 samples, spreads the first offset by that much), 0 steps |
| `rs20-stall-2398` | 10 injected silent starts while playing, 23.976 | **10 of 10 recovered (12 of 12)**, 0 missing. 8 of 10 segments exact (10 samples in, −0.208 ms). **The last 2 (sessions 11 and 12): the sound sits 29 samples (0.60 ms) early against its picture on the wire**, constant for each whole session and sample-exact on one mapping; the first sample is frame N's own sound, 19 samples before frame N's first showing. The bridge saw a normal start in both (+2 and +1 samples, latch on the held frame's last showing), so the start check cannot see this. Capture's frames all carried 2,002 samples. Cause UNKNOWN (open) |
| `rs20-recover-5994` | 5 recoveries forced on clean starts while playing, 59.94 | 7 of 7 started with their picture; 5 of 5 restart segments 25–26 samples in. Back to back (`s18-recover-5994`): 1 of 5 failed, +219 ms |
| `f20-tr-5994`, `f17-tr-2398` | Every run edge (Play, Pause, seeks, steps, the transport's output restart while playing, loop wrap) | Every segment starts 25–27 (59.94) and 8 (23.976) samples into its frame at the control offset, 0 late edges. **The transport's output restart while playing:** 59.94 starts 25 samples into its frame (chain14–16: 3 frames late); **23.976 starts 8 samples into its frame, nothing missing (chain15: 18,582 samples, 387 ms; chain16: 7,248)**. Seek to 600 at 23.976 starts on whichever frame the picture showed first (14385 in cycle 2, 14386 in cycle 1, where 14385 was never shown) |
| `s17b-*` (smoke) | Play after an output restart made while paused | 59.94: 24 samples into its frame, 23.976: 9 (`s17-5994` before the fix: 712; `s17-stall-2398`: 1,269; `rs14-5994`: 226) |

**Pass criteria (Robbie): 0 lost samples, sound on the first moving frame, normal offset.**
- **0 lost samples: met** in every restart while playing, at both rates, natural and injected silent starts included (bridge: 0 missing in all 169 output sessions of `rs20-*`; wire: every segment's first sample at the card's constant).
- **Sound on the first moving frame: met, as at Play.** The run latches on the first timed slot whose picture moved, and the sound starts with the frame before it, the held frame's last showing. One qualification: while the renderer's clock settles after the 1b renderer move (~50 ms), the picture can step once or twice on untimed pulls before it moves at play rate (`an/starthold.py`: 10 of 47 starts at 59.94; slots 0–3 are the preroll). Those frames get no sound; the sound begins with the frame shown just before the first timed move.
- **Normal offset: met** at 59.94 (−0.59 to −0.51 ms against −0.567) and at 23.976 (−0.187 / −0.208 against −0.208), **except 2 of 10 injected recoveries at 23.976, 0.60 ms early** (above, open).

**Corrections to §10.25.**
- The preroll verdict (above): the start picture did not get worse.
- "The same step at 59.94 missed 954 samples (chain14: 941)": **not at the output restart.** In every 59.94 transport run (chain14 to chain20) the bridge's `missing` count rises during the Play from 1905 s through the loop's wrap at the end of the file: the fixture's sound is exactly 1,920.000 s and the last frame runs to 1,920.003 s and is held into the wrap. So those are positions past the end of the file's sound, an inference from the lengths, not a loss. At 59.94 the restart's fault was the 3 frames.

**Found on the way, open:**
- **The output-stop gap is sometimes not digital zero.** In `rs20-2398` and `rs14-2398`, at the same wire time (584.0 s) in both, the 3 s gap after one output stop carried about 15 non-zero samples per frame for 2.75–3 s, with no Manifold audio scheduled. Every other gap in every run is exact zero. It made the analyser lose the next session. Cause UNKNOWN (the card idles between sessions with its input looped back; capture open).
- The 29-sample early sessions above.



#### Item 2: the SDK

**Desktop Video SDK 16.0 (released 2026-04-08) is the current SDK. There is no 16.4 SDK: driver updates (16.4, 16.5) ship without new headers** (Robbie, 2026-11-12). We compile against 16.0 (`docs/BlackmagicDeckLinkSDK16.0`), so "compiled against 16.0 against the 16.4 driver" is **not a suspect** and is struck from the open list: §10.25's "Item 3" (no download, no diff), question 5 of `docs/BLACKMAGIC_SILENT_START.md` (removed), and the "SDK updated to the 16.4 driver" retest condition of the parked HDMI entries in `BUGS.md`. Next (Robbie): install Desktop Video 16.5 and run 100 restarts at 59.94 for a driver before/after; not done in this round.

#### Item 3: silent starts with capture closed

**Every earlier restart-stress run had capture open.** `w1c-run.py` opens `capture --audio --marks` on device 0's input for the whole launch (each run has its `.raw`, `.marks`, `.cap` and a `segs` report): `rs-*` (chain13), `rs14-*`, `rs15-*`. So every silent start counted so far happened with the card's input open, which moves its output clock (§5).

**`nc17-5994`, capture CLOSED** (`W1C_NOCAP=1`, new; device 0's input never opened; 13:43–14:09; build `fu6b`): 100 output stops and starts while playing at 59.94, gate on, plus the launch's start and the paused restart. Silent starts read from the bridge's start check alone (`an/starts.py`, new).

| Run | Capture | Starts | Silent |
|---|---|---|---|
| `rs-5994` (chain13, old sequence) | open | 100 | 5 |
| `rs14-5994` | open | 101 | 1 |
| `rs15-5994-pv` | open | 102 | 1 |
| **`nc17-5994`** | **closed** | **102** | **0** |

All 102 started with their picture, at +1 to +4 samples (+2/+3 in 98), the same gaps as capture open. **Capture open: 7 in 303 at 59.94 gate on (2.3 %); closed: 0 in 102.** That points at the open input, but does not settle it: at 1 in 100, no silent start in 102 happens 36 % of the time (at 2.3 %, 9 %). A second capture-closed run of 100, or the other system's (below), would make it 0 in 200+.

#### Item 3: the 100-restart stress on another DeckLink system

**What to copy.** One folder, made here by `zsh scripts/decklink-loopback/w1c-kit.sh ~/Code/_scratch/manifold-1c-kit ~/Code/_scratch/manifold-1c-wire/fixtures/w1c-5994-1920s.mov` (4.1 GB, almost all of it the fixture; made 2026-11-12 from the final build `fu6e` and ready there now). It mirrors this tree: the measurement build exactly as run in chain20 (`.build-cc/…/Profile/Manifold.app`, 49 MB, `-DMANIFOLD_CARDCLOCK`, gate switch read from the launch environment), `scripts/manifold-proc.sh`, `scripts/decklink-loopback/w1c-run.py`, `defout`, `probe`, `linkpace-ax`, the fixture, and `run-other.sh`. Copy it with `rsync -a` or a disk to `~/Code/_scratch/manifold-1c-kit` on the other Mac (not AirDrop: it quarantines the app).

**What to build there: nothing**, provided that Mac is Apple silicon (Manifold is arm64 only; on an Intel Mac this kit cannot run). The app carries its FFmpeg dylibs. The other Mac needs Desktop Video installed with the card on 1080p59.94-capable output, `python3` (Xcode Command Line Tools), and Terminal allowed under Privacy & Security → Accessibility and → Automation (System Events), which `w1c-run.py` uses to click the File menu by name. **No loop cable is needed:** capture stays closed.

**Before the run.** Quit DaVinci Resolve, Media Express, and anything else that can hold the card; `/Applications/Manifold.app` not running. If that Mac's Manifold trial has ended and it has no licence, the build opens on the licence window and the run stops at "output did not start"; it needs a licence or a trial there.

**The command** (about 30 minutes; do not touch the Mac while it runs, a launched build takes focus):

```sh
zsh ~/Code/_scratch/manifold-1c-kit/run-other.sh
```

It guards, records the card (`probe`) and the Mac (`sw_vers`, model), then runs `W1C_NOCAP=1 w1c-run.py restarts … on other-nc-5994 100`: launch by absolute path, destination SDI as a launch argument (nothing written to defaults), output on, Play, a paused restart, then 100 output stops and starts while playing, Pause, quit by PID, guard. It prints one line of counts: output starts, sound started with its picture, silent starts, recovered, not restarted, started off its picture.

**What to send back:** `runs/other-nc-5994.log` (the whole run; the counts are read from its `[SDI-AUDIO]` lines), `.defout`, `.probe.txt`, `.host.txt`. Nothing in them is a key or a credential.



#### Item 5: cleanup

`~/Code/_scratch/manifold-1c-wire/runs`: every run whose label no document cites, by name or by a glob such as `rs15-*`, deleted (`an/cited.py`, which lists both). Files of a cited run with an extra suffix (`.segs2`, `d-defout-*.sample`, `fx*-control.sample`) kept with their run. Deleted 2026-11-12: 22 runs, 114 files, 52 MB (`ap2398-on`, `ap5994-on`, `c0-d80-*`, `c0-ovl`, `ctl2-*`, `smoke-1`, `t2-smoke`, `t3-*`, `v-c-*-on`, `v-p-*` but `v-p-5994-off`, `v-tr-2398-on`, `v2-*`). None held a wire recording; §10.22's C0b and smoke runs, described there without labels, were among them. Left: 98 cited runs (7.2 GB with this round's). The fixtures kept (13 files).

#### Status

- **Output restart while playing:** the sound starts with the first timed moving frame, as at Play, with nothing lost, at 59.94 and 23.976, through natural and injected silent starts (`rs20-*`). Fixed by the preroll depth and the 8 s tap; Play after a restart made while paused, by the parked re-read.
- **Silent-start recovery:** now waits 500 ms between its stop and start (back to back it could leave the sound up to a second late, mostly at 23.976). 2 of 10 recovered sessions at 23.976 still sat 0.60 ms early: open.
- **SDK:** 16.0 is current; struck as a suspect.
- **Silent starts, capture closed:** 0 of 102 against 7 of 303 open. Not settled; the other system's run and a second closed run would. (Follow-up 5, below: 0 of 408 closed; 3 of 52 open on the same build.)
- **Stage 2:** planned, §10.27. Nothing built.
- ~~Next (Robbie): Desktop Video 16.5, then 100 restarts at 59.94 for a driver before/after.~~ Dropped (Robbie, 2026-11-12; follow-up 6 below).

#### Follow-up 5: decisions and silent starts with capture closed, 2026-11-12 (evening)

**Decisions (Robbie, 2026-11-12):**
- **The 500 ms wait between stop and start in the silent-start recovery is accepted.**
- **Recorded as low-priority open findings, not pursued now:** the two recovered sessions at 23.976 that sat 0.60 ms early (`rs20-stall-2398`, sessions 11–12), and the non-zero samples in one output-stop gap (`rs14-2398`, `rs20-2398`, 584.0 s).
- **No hardware loopback:** the 2026-09-30 rule stands. Stage 2's verification uses no cable; §10.27's verification is revised (software timestamps plus one attended Audio Hijack check). Stage 2 waits for Robbie's go on the revised plan.

**`chain21`** (build `fu6e`, HEAD `062e305`, Desktop Video 16.4, gate on, 59.94; each launch gated on Resolve closed and 10 min HID idle, guarded before and after, launched by absolute path, quit by PID; 19:24–21:09). Three capture-closed launches of 100 restarts while playing (`W1C_NOCAP=1`; the 1,920 s fixture holds 100), then one launch with capture opened mid-session only (`W1C_CAP_MID=1`, new in `w1c-run.py`: the input closed at every start, opened 4 s after each start's preroll line and closed 6 s later, 2 s before the next stop; each open's wire in `mid21-5994.mid/`, every start, open and close in `mid21-5994.drv`).

| Run | Input | Starts | Silent | Start gaps (samples) |
|---|---|---|---|---|
| `nc21a-5994` | closed | 102 | 0 | 0–3 (+2/+3 in 99) |
| `nc21b-5994` | closed | 102 | 0 | 1–6 (+2/+3 in 95) |
| `nc21c-5994` | closed | 102 | 0 | 1–4 (+2/+3 in 99) |
| `nc17-5994` (follow-up 4, `fu6b`) | closed | 102 | 0 | 1–4 |
| `mid21-5994` | opened mid-session, closed at every start | 102 | 0 | 0–4 (+2/+3 in 96) |
| `rs20-5994` (follow-up 4, **`fu6e`, the same build**) | open | 52 | **3** | — |

**Capture closed: 0 in 306 here, 0 in 408 with `nc17`, against 7 in 303 with capture open.** The odds each way:
- **If closed had open's rate** (2.3 %), 0 in 306 happens 0.08 % of the time (0 in 408: 0.007 %). Fisher exact, one-sided: 7/303 against 0/306, p = 0.007.
- **The build is not the difference.** The 7/303 came from older start sequences (200 ms and 3,203-sample prerolls). On the same build, `fu6e`, `rs20-5994` (capture open) had 3 natural silent starts in 52, against 0 in 306 closed: p = 0.003. With `nc17` (`fu6b`, the same start code): 0 in 408, p = 0.0014. Over all 59.94 runs, open 10 in 355 against closed 0 in 408: p = 0.0004.
- **The other way:** the closed rate is not shown to be 0. Its 95 % upper bound is 0.97 % (306 starts) or 0.73 % (408). At a true 1 % closed, 0 in 306 happens 4.6 % of the time; at 0.5 %, 22 %. Open's 7/303 has a 95 % lower bound of 0.94 %. So the closed rate is at least ~3× below open's, and could be anywhere from 0 to ~0.7 %.

**Opening capture during a session triggered nothing.**
- Of the 102 opens, 100 were made while playing. The other two, `c001` (closed before the first Play) and `c002` (opened 0.76 s before its Play, sound from sample 36,062, which is that Play), are expected.
- **All 100 carried sound from the first received sample, with no zero run of 1 ms or more**, so the embedded audio already playing was not interrupted by the input opening or closing.
- **The bridge saw no stall:** 0 `holding over 1 s`. Its runs, latches and off-the-line ends were at the closed runs' counts.
- Every start after such a session was normal: 0 in 102. At open's 2.3 %, 0 in 102 happens 9 % of the time, so a smaller after-effect of an earlier open is not ruled out.
- `mid21` had 7 `DeckLink D3: !! Dropped at frame 4` lines against 3–4 in each closed run (`nc17`: 9). All 7 are in a start sequence, after that session's capture had closed, which is the known start-time drop of frame 4, scheduled before the picture moves (§6 here; `DISPLAY_LINK_PER_WINDOW_PLAN.md` §7.9), not the opens.

**Reading.** On this card, profile `1dfd` (full duplex), driver 16.4, the silent start has so far needed **the same sub-device's input open at the moment the output starts**. Whether it is the open input itself or the clock movement an open input causes (§5) is UNKNOWN; the two cannot be separated with this rig. Manifold never opens a DeckLink input (no `IDeckLinkInput` use in `App/` or `Packages/`), but a user's other application (Resolve, Media Express, a capture tool) could. `BLACKMAGIC_SILENT_START.md` is rewritten around this question. The recovery stays: it costs nothing when no start is silent. Desktop Video 16.5 and the other system's run (capture closed by design) are still to come; a 16.5 before/after now needs capture open to have anything to compare. (Follow-up 6: the 16.5 before/after is dropped.)

#### Follow-up 6: decision on the silent start, 2026-11-12

**Decided (Robbie, 2026-11-12):**
- **The silent start needs the card's input open at output start:** 0 in 408 starts with the input closed (`nc17-5994`, `nc21a/b/c-5994`) against 7 in 303 with it open (`rs-5994`, `rs14-5994`, `rs15-5994-pv`), 3 in 52 on the same build (`rs20-5994`).
- **Classified as a test-rig condition.** Manifold never opens a DeckLink input; on this rig the input is open because the capture tool listens on the SDI loop of the same sub-device.
- **The automatic recovery stays as the safety net** (`DeckLinkService.swift`, `recoverSilentStart`, with its 500 ms wait), for a user whose other application holds the card's input.
- **Not pursued further.** The Desktop Video 16.5 before/after (follow-up 4, item 2) is dropped.
- A sub-device mapping that keeps the test input off the output's sub-device, and a 100-restart check on it, are in `docs/ROADMAP_IDEAS.md` ("DeckLink 8K Pro: a sub-device mapping for output plus capture"), after 0.9.3.

### 10.27 Stage 2, the plan: destination Computer with output on, the card as master, 2026-11-12

**Plan only: nothing here is built.** Asked by Robbie, 2026-11-12 (follow-up 4, item 4); its verification revised in follow-up 5 (no cable). Waits for Robbie's go. It replaces §10.2's target and §10.5's T8–T12 where they differ; everything else in §10.1–§10.7 stands. Line numbers are this working tree (HEAD `1ee7b5a` plus §10.26's uncommitted changes).

**Aim.** Output on, destination Computer, a file playing: the card is the master clock (as at destination SDI today), the Mac's sound is resampled to follow the card (§10.2 option A), and it lines up with **the SDI picture**, not the window (§10.7 decision 2). A flip between SDI and Computer is a mute flip: no renderer move, no rate write, no hold.

#### What exists after 1b and 1c

- The picture's synchronizer is steered onto the card's line once a second (`cardClockTick`, `FrameEngine.swift:955`), with the audio renderer on its own synchronizer, `audioSynchronizer` (`moveAudioToOwnClock`, `:819`), at rate 1 on the Mac's device. Every transport move goes to both (`setTransportRate`, `parkTransport`, `:925`).
- That applies only while the card owns the sound: `cardLockApplies` (`:808`) needs `deckLinkOwnsAudio`. At destination Computer the renderer is back on the picture's synchronizer, card lock is released, and the SDI picture slips as before Stage 1. A flip on air moves the renderer (48 / 65 ms clock loss, §10.1).
- While muted, the sound's clock is put back on the picture when they part by 20 ms (`holdCardAudioNearPicture`, `:938`; `CardClockAudio.partBound`). That position write mutes the renderer for 50–60 ms, which is why it is allowed only while muted.
- The SDI bridge knows, per run, the exact line between the card's stream and the file: card sample `s` carries source sample `s + D` (§10.22), latched on the first moving frame (§10.25, §10.26). With the completion stamps (`CardClockSampleRing`) that gives **the content time on the SDI wire at any host time**, continuous, with no pts staircase.

#### The design

1. **The second synchronizer, for both destinations.** `cardLockApplies` drops the `deckLinkOwnsAudio` term: while output runs and a file with sound plays, the renderer lives on `audioSynchronizer` whatever the destination. The destination only sets `audioRenderer.isMuted` and the bridge's gate (`isSilent`), as today. Output off: unchanged, no second synchronizer (T15).
2. **The resampler.** One `LiveAudioResampleStage` (`LiveAudioResample/LiveAudioResampleStage.swift:105`) per audio arm, in the pump's enqueue closure **after the tap**, so the tap and SDI keep original samples (§10.2's "Where it sits"). Built only while card lock holds; output off runs today's closures. Its output axis is `audioSynchronizer`'s timeline.
3. **The steering.** A small class beside the live one (§10.2: the live steering's bulk serves things a file does not have), using `LiveAudioResampleController` with its adopted gains. Per input buffer:
   - **Mac:** `m = stage.inputTime(atOutputTime: audioSynchronizer.currentTime())`, the content heard now;
   - **SDI picture:** `w = Φ + cardTime(host)`, the content on the wire at the same host instant: `Φ` from the bridge's current run (published by the bridge with its serial; new, below), `cardTime(host)` from the stamp line card lock already fits. One paired read, discarded over 200 µs (`pairedReadLimit`);
   - **Error:** `e = m − (w + K)`. `K` is the one constant: the difference between the synchronizer's idea of "heard" and the Scarlett's connector, and the card's completion stamp and its SDI connector. It is **measured, not assumed** (the test below), and stored per output device only if the measurement says it differs by device.
   - No run (paused, between a seek and its latch, gate silent): `ρ` held, integrator held, no error read.
   - **The bridge publishes** one record per run change: `{serial, Φ (source s at card sample 0), rate mismatch line if C6, active}`, under the handed lock, read by the engine on main. It already holds all of it (`m_run`).
4. **Coarse alignment, once per run.** The SDI wire starts a run `L` after the picture clock (the pull margin plus the frames between pull and wire, about 100 ms at 59.94 by reading, §10.7; the bridge measures it exactly at each latch). At Play, `audioSynchronizer` starts at the paused time `T` at host `H + L` (a future-dated start from a stop is harmless, §10.2), so its first sample is heard with the wire's first moving frame. `L` is the last run's measured value, else the prediction from the slot timeline. After the run latches, `e` is read; above 20 ms it is a coarse miss: one position write (mutes 50–60 ms), logged `[CARDLOCK] Mac sound re-anchored to the SDI picture`, counted. Expected 0 in steady play.
5. **1b's 20 ms re-anchor retires.** The steering holds the sound within a millisecond in both destinations, muted or not, so `holdCardAudioNearPicture` has nothing to do and would mute an audible renderer.

#### Transport events

| Event | Picture clock | `audioSynchronizer` | Stage, steering |
|---|---|---|---|
| Play | As today; lock latches | Rate 1 at `T`, host `H + L` | Runs from the first latched run; integrator kept from the last run |
| Pause | Rate 0 | Rate 0 at the same host time (`parkTransport`) | Held |
| Seek, step, loop wrap, scrub release | `beginReading`, lock re-latches | Re-anchored to the new run as at Play, once the bridge latches the landing frame | New stage with the arm; integrator held (no re-acquisition); filter reset (`coarseEvent`) |
| Shuttle ≠ 1×, scrub drag, reverse | As today | Same rate, muted as today | Held |
| Track switch | Untouched | One position write: the new stage's axis starts on content time | New stage, integrator held |
| Output start while playing | Renderer moves off (clock loses ~48 ms, §10.1); **at destination Computer that is an audible gap; method S sees it only as a step in the log, so its audibility is judged by ear (W6)** | Created | Built at the first run |
| Output stop while playing | Renderer moves back (~65 ms) | Released | Destroyed; the Mac sound is on its device again, as today |
| SDI → Computer | Nothing | Nothing | Nothing: **unmute only**. The bridge's run ends after 8 silent slots (§10.22) |
| Computer → SDI | Nothing | Nothing | Nothing: mute; the bridge latches a new run on the next moving frame |
| Audio device change (incl. §10.19's automatic flush) | Unaffected | Its clock changes under it | `readSoundAgain(from: flushTime)` (`:885`, `:910`) builds a new stage at the flush time on the same axis, so the alignment carries over. **Integrator reset** if the default output's UID changed (a new device has its own rate against the card), held otherwise. The flush handler keeps its skip during a renderer move |

**The output-change stall fix (§10.19) and Stage 2.** The fix re-reads from the flush time with the clock running. Under Stage 2 that clock is `audioSynchronizer`, which the flush does not stop, so the new stage's first sample lands on the aligned axis; what changes is the device's rate (the integrator above) and possibly `K` (if `K` is per device). The re-read empties the tap; at destination SDI §10.19 measured 0 or one 19–21 ms callback of SDI silence per change. Not changed here.

#### Verifying the Mac's sound against the SDI picture (revised, follow-up 5, 2026-11-12)

**No cable.** Robbie, 2026-11-12: the 2026-09-30 rule stands (`AV_SYNC_FINDINGS.md` §1.2, `CLAUDE.md` Test environment): no Scarlett loopback, and Stage 2's verification must not use a cable. Follow-up 4's proposal (Line Output 3 into Input 8, `devrec`, `capture --host`, `w2-mac.py`) is withdrawn. Two methods replace it. The SDI loop already on device 0 is the existing rig, not a new cable, and neither method below needs it.

**Method S: software timestamps, unattended, 30 min per run.** Everything is on the host clock, from the same build (`-DMANIFOLD_CARDCLOCK`):
- **The SDI picture:** `w(h) = Φ + cardTime(h)`, the content on the wire at host time `h`, from the bridge's run record and the completion-stamp line, plus the card's constant from stamp to wire. 1c checked this leg against the wire (`cont` D1, `rs20-*`, §10.22–§10.26), so it is the trusted side.
- **The Mac's sound:** `m(h)`, the content `audioSynchronizer` says is playing at `h`, through the stage's output→input map. The `[W2]` line, new, is one paired read every 100 ms (`h`, `m`, `w`, `ρ`, the integrator, the run serial), discarded over 200 µs.
- **The output device, measured independently:** `devclock` (exists), an IOProc on the same device that writes nothing, logs `mSampleTime` against `mHostTime` every cycle. It gains a log of the reported output latency (device, stream, safety offset, buffer size) at the start and on every change (new, small), and of every gap in `mSampleTime` and every overload.
- **Analysis, `w2-soft.py`, new:** the series `m(h) − w(h)` and, separately, the device's rate against the card's (from `devclock` and the stamps, neither of which the steering reads), set against `ρ`.

What S **can** prove, to the timestamps' precision (tens of µs):
- **Drift, steps and spread:** the slope of `m − w` over 30 min, every step over 0.05 ms with its host time, and the p1–p99 spread after the first 2 min.
- **That `ρ` follows the real rate difference:** the device-against-card rate measured by `devclock` and the stamps, not the steering's own error.
- **0 position writes** between Play and Pause (from the log), and **no device dropouts** (`mSampleTime` gaps, overloads).

What S **cannot** prove:
- **The absolute offset at the connectors.** That needs whether `audioSynchronizer` time already includes the output latency (UNKNOWN), whether the Scarlett reports its latency truly (USB interfaces can leave converter and driver delay out), and the DAC.
- **Anything inside the renderer that its timeline does not show.** If `AVSampleBufferAudioRenderer` dropped or repeated samples while its timeline ran on, S would not see it.
- **That the error is truly zero.** `m` and `w` are the same quantities the steering reads, so a flat `m − w` shows the loop holds its own error at zero, not that the sound is right. The independent legs are the `devclock` rate and the attended check below.

**Method A: one attended Audio Hijack check, for the absolute offset.** Audio Hijack records sound only, so the SDI picture reaches it through the SDI embedded audio, whose place against its picture 1c measured on the wire: **−0.567 ms at 59.94** (`ctl20-5994`, sample-exact). The check needs one DEBUG launch switch, `MANIFOLD_SDI_AUDIO_BOTH=1` (new; built with Stage 2; DEBUG builds only): at destination Computer the bridge's gate stays open, so the card carries the same sound the Mac plays. Audio Hijack then records two things on its one clock:
- left: Manifold's output (its Application source, the sound Manifold hands to Core Audio);
- right: the SDI loop's embedded audio (the Input Device source "DeckLink 8K Pro (1)", channel 1).

The fixture is the seeded-noise file (`w1c-5994-1920s.mov`), so cross-correlation over 100 ms windows locates one channel against the other sample-exact.

What A **can** prove:
- **The absolute offset at Audio Hijack's two taps:** the Mac's sound as Manifold renders it, against the SDI picture (the right channel's offset plus 0.567 ms).
- **Whether `audioSynchronizer` time includes the output latency.** A's figure set against S's constant from the same launch differs by about the Scarlett's reported output latency if it does not, and by about 0 if it does. That decides `K`.

What A **cannot** prove:
- **The offset at the Scarlett's connector.** Audio Hijack taps the application before the device, so the Scarlett's output latency is added from its reported value, not measured.
- **The DeckLink input path's own delay.** How long Core Audio takes to deliver the SDI audio to Audio Hijack is taken from the input's reported latency (UNKNOWN until read). Both reported latencies are stated as the result's uncertainty.
- **Rate.** The open input moves the card's output clock (§5).
- **Transport events.** Audio Hijack loses 35–59 ms around a timebase pause (§1.2).
- **More than one session, one device and one rate.**

**Method A, the steps (attended; Robbie at the Mac, Claude driving Manifold):**
1. **Claude, before you sit down:** check that Resolve is closed and that no `/Applications/Manifold.app` is running, and run `manifold-proc.sh guard`. Claude tells you before the launch, then launches the Stage 2 measurement build by its absolute path with destination Computer, 1080p59.94 and `MANIFOLD_SDI_AUDIO_BOTH=1` (launch arguments, nothing written to defaults). Claude opens the noise fixture, starts the DeckLink output and checks the log for output started and the bridge's gate open. The card's input is opened only after this point (it is mid-session, see `BLACKMAGIC_SILENT_START.md`).
2. **You:** only now launch Audio Hijack (started before Manifold has connected, it can quit or relaunch Manifold). Make a **new** session, "Stage 2 offset"; do not change an existing one:
   - Application source → Manifold → Channels block set to **Left only** (source channel 1 to Left).
   - Input Device source → **DeckLink 8K Pro (1)** → Channels block set to **Right only** (channel 1 to Right).
   - Both into one Recorder: WAV, 48 kHz, 24-bit, stereo, no effects, no volume block.
   - In Manifold, volume at full and not muted. In macOS Sound, the output stays the Scarlett.
3. **You, a 5 s preflight:** Record, wait 5 s, Stop, and tell Claude the file's name. Claude reads each channel's level (`volumedetect` per channel). Both must carry noise; −91 dB on either channel means a dead source. If so, re-pick the source and repeat. Do not go on with a silent channel.
4. **Claude:** seeks to 0 and presses Play through accessibility.
5. **You:** wait 10 s, then Record. Do not touch the Mac for 3 min: no transport, no device change.
6. **You:** Stop, and give Claude the file's name.
7. **Claude:** pauses, stops the output, quits the build by its PID and guards. Quit Audio Hijack whenever you like after that. The run's numbers come from `w2-ah.py` (new): the window-by-window offset, its median and spread, then the conversion to the connector with the two reported latencies stated.

#### Predictions and pass criteria, revised 2026-11-12 (follow-up 5) before any code

| # | Run | Prediction | Pass |
|---|---|---|---|
| S0 | `devclock` on the Scarlett, 30 min, no Manifold | Its rate against the card's stamps about −17.6 ppm (§10.5); no `mSampleTime` gap; latencies as reported, unchanged | 0 gaps; rate stated |
| W1 | **Today's build (1c)**, destination Computer, output on, 59.94, 30 min Play, method S | Card lock off at Computer, so `m − w` ramps about 1.06 ms/min, with a 16.7 ms step back each time the picture slips (about every 16 min). The constant: the Mac **ahead** of the SDI picture by about 100 ms (§10.7, by reading) | Baseline only: the constant and the ramp |
| W2 | Stage 2, same, 59.94 and 23.976, 30 min each, method S | `m − w` constant: **spread ≤ 0.2 ms after the first 2 min, 0 steps over 0.05 ms, drift under 0.01 ms over 30 min**. `ρ − 1` within 0.5 ppm of S0's independent rate. 0 position writes between Play and Pause, 0 device gaps | All of these |
| A1 | Method A, 59.94, 3 min, attended | At the taps, offset = S's constant for the same launch, plus 0 or the Scarlett's reported output latency (deciding `K`) | Offset stated with its two reported latencies; `K` decided; Robbie's go on the figure |
| W3 | Stage 2, the transport loop (`w1c-run.py transport`), destination Computer, method S | Each run's `m − w` within ±0.5 ms of W2's constant within 2 s of its start | All runs |
| W4 | 10 SDI ↔ Computer flips while playing, method S | No renderer move, no rate write (log); `m − w` unchanged across each flip (the synchronizer never stops); the SDI run ends and re-latches as today | 10 of 10 |
| W5 | §10.19 interaction: 5 default-output switches to the built-in and back, Computer, method S plus `devclock` on each device | One `[AUDIO-FLUSH]` re-read per change; back on the Scarlett, `m − w` within ±1 ms of W2 within 2 s; integrator reset logged per UID change | 10 of 10 |
| W6 | Output stop and start while playing, Computer, 20 times, method S | The renderer moves (48–65 ms, §10.1) show as a step in `m − w` from the log, **not as an audible gap: S cannot hear a gap**. After the start, `m − w` back at W2's within 2 s of the first run | Offset as W2. The gap's audibility goes to Robbie by ear, or to an Audio Hijack pass, which loses 35–59 ms around a pause and so can only bound it |
| W7 | T9: the built-in output, method S with `devclock` on the built-in | As W2, with `ρ` at the built-in's own rate difference. `K` per device decided by A1 and the reported latencies | Spread ≤ 0.2 ms |
| — | T15 (output off) and T16 (live control) | Unchanged | As §10.5 |

**Unknown going in.** Whether `audioSynchronizer.currentTime()` already includes the device's output latency (if not, `K` is per device and Stage 2 reads the latency from Core Audio; A1 decides it). Whether the reported output and DeckLink input latencies are true: no method here can check them without a cable, so they stay stated uncertainties. How soon an unmute is heard (§4.5 measured that a muted renderer keeps advancing, not how unmuting lands). Whether the 48 / 65 ms move at output start or stop can be made inaudible at destination Computer; accepted for the picture (§10.7 decision 3), not yet decided for sound.

### 10.28 Stage 2, built: the build, one correction to the plan, and the predictions, 2026-11-12

Go: Robbie, 2026-11-12 (follow-up 6's message). Same rules as 1c, no commit. Build **`fu7`**: `.build-cc`, Profile, `-DMANIFOLD_CARDCLOCK`, on HEAD `95093fc` plus this round's uncommitted changes. Gate on (`MANIFOLD_CARDLOCK_1B=1`) for every run; `MANIFOLD_CARDLOCK_STAGE2=0` (new) returns the same build to 1c, for W1. Package tests: every suite passes, including two new ones (`CardClockLineTests`, `CardAudioResampleTests`).

#### One correction to §10.27 before any run: the SDI picture's line is not the bridge's run

§10.27 item 3 reads Φ from the bridge's current run. **A run latches only while the bridge's gate is open** (`processSlots`, `eligible = !silent && …`), and at destination Computer the gate is shut for the whole session (`isSilent` returns true when the destination is not SDI). So at the destination Stage 2 is for, there is no run and no Φ. Found by reading `DeckLinkBridge.mm` before writing the steering.

Built instead: **the bridge publishes the picture's line**, at both destinations, from the same slots its runs latch on. For every timed slot that moved, φ = pts − slot × card frame (content seconds at card time 0); a new line once two moved slots in a row agree to half a sample (a seek's first frame can carry the seek's time, §10.22), and every moved slot after advances its newest slot (`publishPictureLine`, logged `[SDI-AUDIO] picture line #n`). At a matched rate φ equals the run's D / sample rate. **A rate mismatch (C6) has a staircase, not a line: it is published as such and Stage 2 holds there (not covered by this round).** The engine fits the card's slot against the host from the completion stamps (`CardClockLine`, least squares over 2 s), so the content on the wire at host h is `w(h) = φ + cardTime(h)` (plus the card's constant from stamp to wire, which goes into K).

#### What was built

- **Routing** (`FrameEngine.swift`, `cardLockApplies`): a file with sound is on the card's clock at either destination, on the AVFoundation arm. The libav arm (float PCM, which the resampler does not take) keeps 1c's rule. Output off: unchanged; no second synchronizer, no resampler, no timer.
- **The resampler** (`LiveAudioResample/CardAudioResample.swift`, new): one per AVFoundation audio arm, in the pump's enqueue after the tap (the tap and SDI keep the original samples), wrapping the live sources' `LiveAudioResampleStage`. Passes buffers through untouched until activated; activated and deactivated at the start of a renderer move (which flushes the renderer). An axis offset keeps a re-read on the old output axis (the automatic flush after a device change, a track switch); a seek writes both clocks to content time and starts at offset 0.
- **The steering** (`CardAudioSteering`, same file; `stage2Tick` in the engine, 10 Hz on main): one paired read (`audioSynchronizer`, the picture's synchronizer; discarded over 200 µs), `m` = content heard (`contentTime(atOutputTime:)`), `w` from the picture line and the card line, `e = m − (w + K)`, one step of `LiveAudioResampleController` with the adopted gains, ρ onto the stage. Held while paused, while waiting for a Play's picture, without a current line, and at a rate mismatch. Over 20 ms: one position write, logged `[CARDLOCK] Mac sound re-anchored to the SDI picture`, counted. K = 0 (`MANIFOLD_STAGE2_K_MS`, measurement build only) until A1.
- **Play** (`setTransportRate`, `stage2ResolvePending`): from a stop, the sound's clock stays parked and is started, by a future-dated `setRate`, at the host time the paused content reaches the wire, from the first picture line that starts after the Play. No line within 1 s: started with the picture clock, logged, counted. A renderer move made while playing (output start) parks the sound's clock the same way.
- **Pause** (`setTransportRate`, found while reading the Play path, before any run): the window's picture stops at once, but the frames already handed to the card keep the SDI picture moving for the wire's lag. The sound follows the SDI picture, so its clock is stopped when the wire reaches the paused frame (a timer to that host time, cancelled by any later transport write or renderer move; logged `Mac sound stopped with the SDI picture`). Stopped at once, the sound would stop that much content short of the SDI picture, and the next Play would have had to skip it to rejoin the wire.
- **1b's 20 ms re-anchor** (`holdCardAudioNearPicture`) does nothing while Stage 2 steers.
- **Device change**: the automatic flush's time is converted from the renderer's timeline to content before the re-read; the integrator is reset when the output device's UID changes (`[CARDLOCK] Stage 2: output device … integrator reset`).
- **`MANIFOLD_SDI_AUDIO_BOTH=1`** (DEBUG, `DeckLinkService.swift`): at destination Computer the SDI gate stays open, for method A.
- **Measurement**: one `[W2]` line per tick (host, m, w, e, ρ, integrator, filtered error, picture clock, renderer time, line serial, state), with Stage 2 off too (W1). `devclock` logs the device's reported latencies at start and on change, sample-time gaps over 4 frames (the Scarlett's USB timestamps wobble ±1 frame a cycle), and overloads. `w1c-run.py` gains the destination, `devclock` beside the build, default-output switches and destination flips (below).

#### Predictions, written before any run

Rates: the device's rate against the card is `devclock` (device against host) less the card's rate against the host (the `[CARDLOCK] card … ppm` lines). Sign: a device slow against the card makes `e` fall, so ρ − 1 = −(device against card).

| # | Run | Prediction | Pass (§10.27) |
|---|---|---|---|
| S0 | `devclock`, Scarlett and built-in, 30 min, no Manifold | 0 gaps, 0 overloads; latencies constant. Scarlett as reported at the smoke: device 14, stream 0, safety 14 frames, buffer 512; built-in: device 60, stream 169, safety 48 | 0 gaps; rates stated |
| W1 | Stage 2 off (1c), Computer, 59.94, 30 min | Renderer on the picture clock (`[W2] … 1c`). `m − w` ramps at the Scarlett's rate against the card (≈ 1 ms/min at 17.6 ppm) and steps back one frame (16.7 ms) at each slip, ≈ every 16 min. Constant: the Mac **ahead** of the SDI picture by 90–140 ms | Baseline only |
| W2 | Stage 2, Computer, Scarlett, 59.94 and 23.976, 30 min each | After the first 2 min: `e` p1–p99 spread ≤ 0.2 ms, 0 steps over 0.05 ms, drift under 0.01 ms over the run. ρ − 1 within 0.5 ppm of −(Scarlett against card). 0 position writes and 0 start timeouts between Play and Pause. The Play's sound starts 90–140 ms after the Play at 59.94, 130–220 ms at 23.976 (the wire's lag behind the picture clock, read from the start line) | All |
| W7 | Same, built-in output (`MANIFOLD_CARDCLOCK_AUDIO_DEVICE_UID`), 59.94 and 23.976 | As W2, ρ − 1 at the built-in's own rate against the card | Spread ≤ 0.2 ms |
| W3 | Stage 2, the transport cycle (`w1c-run.py transport`), Computer, 59.94 and 23.976 | Every Play, seek, loop wrap and the output restart: one `starts with the SDI picture` line (or a late start under 1 frame), `e` within ±0.5 ms within 2 s, 0 coarse writes, 0 timeouts. Every Pause from play: one `stopped with the SDI picture` line, the wire's lag after the Pause (as the Play's) | All runs |
| W4 | 10 SDI ↔ Computer flips while playing, 59.94 | No renderer move, no position write, no `[AUDIO-FLUSH]`; `e` unchanged across each flip (the tick before against 1 s after, under 0.05 ms) | 10 of 10 |
| W5 | 5 default-output switches to the built-in and back, Computer, 59.94 | One `[AUDIO-FLUSH]` re-read and one integrator reset per change (10 of 10); `e` within ±1 ms within 2 s of each; ρ settles to each device's own rate | 10 of 10 |
| W6 | 20 output stops and starts while playing, Computer, 59.94 | Each start: one `starts with the SDI picture` line; `e` within ±0.5 ms within 2 s. The Mac's sound is silent from the renderer move until the wire's first moving frame (read from the log; how long is not predicted). At each stop the sound returns to the picture clock, about the wire's lag ahead | Offset as W2; audibility by ear (A) |
| D | Destination SDI on the wire, one transport cycle, 59.94, capture open (as `f20-tr-5994`) | Unchanged from 1c: every segment starts 25–27 samples into its frame, at the control offset (−0.567 ms), 0 late edges, 0 missing | As 1c |

**Not predicted, measured:** the wire's lag behind the picture clock per rate (the Play start lines); how long the Mac is silent at an output start.

### 10.29 Stage 2, round 1 results (chain 22) and the fixes they led to, 2026-11-13

Build `fu7`, chain 22 (`~/Code/_scratch/manifold-1c-wire/chain22.sh main`, 22:50–01:52), every run gated on HID idle, guarded, launched by
absolute path and quit by PID. Reports: `runs/<run>.w2` (`w2-soft.py --events`), `runs/d22-tr-5994.segs.report`.

**Before the main chain.** S0 (30 min `devclock`, no Manifold): Scarlett +7.861 ppm against the host, built-in +7.471; 0 overloads;
latencies constant and as predicted. The first `devclock` counted the Scarlett's paired ±5–6-frame timestamp wobbles as gaps; a gap is
now half a buffer or more (0 real gaps in S0), wobbles are counted apart. The smoke (`sm22-5994`) found the Pause's delayed stop
firing 39.5 ms late on `asyncAfter`; changed to a strict main-queue timer before the main chain (still late, below).

**An accidental remote connection** (Jump Desktop, Robbie, 23:37) switched the default output to Jump's audio driver for 1.8 s during
`w2-5994`. Stage 2 took it as designed: two `[AUDIO-FLUSH]` re-reads on the old output axis (offset +17.086 ms), two integrator
resets, no position write; `e` stayed inside the run's spread. The run is kept but not counted; `w2b-5994` (chain 23) repeats it.

#### Against the predictions (§10.28)

| # | Result | Verdict |
|---|---|---|
| W1 | `m − w` median +95.29 ms (Mac ahead), ramp +1.108 ms/min, −16.68 ms at each of 2 slips, −48.95 ms at the Pause. The card rate reads `nan` (1c logs no card lines at Computer): the analysis needs another card-rate source for W1 | As predicted |
| W2-5994 (Jump) | spread 0.160 ms, drift −0.0003 ms, ρ − 1 −18.500 against −18.818 ppm (0.32), start 96.5 ms after Play, 0 position writes, 0 timeouts | Pass but for the step count (below); repeated as `w2b` |
| W2b-5994 (chain 23, clean) | spread 0.040 ms, max \|e\| 0.108, drift −0.0002 ms, ρ − 1 −18.664 against −18.870 (0.21), start 96.3 ms after Play, 0 position writes, 0 timeouts, 0 gaps; 1-s medians 0 steps (largest 0.030 ms). The Jump run's 0.160 spread was the incident | **Pass** |
| W2-2398 | spread 0.040 ms, drift −0.0001 ms, ρ − 1 −18.360 against −18.430 (0.07), start 203.0 ms after Play | Pass but for the step count |
| W7-5994 | spread 4.26 ms, max \|e\| 16.70 ms: **a slip** at 1,566 s (below). Before it: e −0.065…+0.025 ms | **Fail** → fixed, re-run |
| W7-2398 | spread 0.086 ms, drift −0.0005 ms, ρ − 1 −17.614 against −17.694 (0.08), start 209.0 ms | Pass but for the step count |
| W3 (both) | 7 starts with the SDI picture each, 0 late, 0 position writes, 0 timeouts; `e` at +2 s within ±0.03 ms after every Play, seek and loop; 3 stops each. Starts 83.4–97.6 ms after Play at 59.94, 188.7–224.8 at 23.976 (one over the predicted 220). The transport cycle's output restart happens **paused**, so W3 never tested a restart while playing; only W6 does | Pass (lag range aside) |
| W4 | 10 of 10 flips: no renderer move, no position write, no `[AUDIO-FLUSH]`; \|Δe\| across each flip 0.001–0.025 ms | Pass |
| W5 | 10 of 10: one flush and one integrator reset per change, \|e\| ≤ 0.19 ms throughout. ρ does not settle in 30 s per device (−21…−22 against −17.5 and −18.5), which leaves e at about +0.1 ms | Pass; ρ not settled |
| W6 | **Fail.** After the first two restarts (made paused), every output start while playing left the Mac silent until the next transport action: 22 renderer moves, 2 starts | **Fail** → fixed, re-run |
| D | Every segment 33–34 samples into its frame at −0.70…−0.72 ms; 1c's runs (f15, f16, f20, v-on) are 25–27 samples at −0.52…−0.58. 0 late edges; 1 run with 965 missing samples. The card read −104 ppm against the host here, against +14…+19 at f20 and −11 at Computer | **Fail?** Control pair in chain 24 |

**The step count was mis-stated.** "0 steps over 0.05 ms between ticks" counts the read's noise, not the sound. Split by term, over
10-s windows: `m` (the synchronizer's interpolated time) carries 9–23 µs rms, `w` (the fitted card line) 1–2 µs, and the picture
synchronizer's read the same as `m`. The sound cannot step without a write. Between 1-s medians (10 ticks) every steady segment of
W2, W5 and W7-2398 has **0 steps over 0.05 ms** (largest 0.031–0.048 ms). `w2-soft.py` now reports both.

**The Pause stop is ~30 ms late.** Every Pause: stop due at the wire's lag (e.g. 97.3 ms), fired 28–33 ms after that, on main
(`DispatchSourceTimer` with `.strict`, queue `.main`): main is busy right after a Pause. The sound ran that much content past the SDI
picture; the next Play starts from where it stopped, so the next run is still exact. Fixed: the timer runs on its own
`.userInteractive` queue and stops the clock there, under a lock a later transport write takes to cancel it (`Stage2StopTicket`).

#### W6: an output start while playing left the sound parked

`moveAudioToOwnClock`'s completion parked the sound's clock and asked for a pending start (`stage2ResolvePending`) while
`cardAudioMoving` was still true, and the resolve drops a pending start while moving. Nothing asked again, so the sound stayed parked
(`held: transport`) until the next Play. The first two restarts of W6 happened paused, so they passed. Fixed: `cardAudioMoving` is
cleared before the resolve. The picture line after an output start arrives from slot 8–9, within ~50 ms of the move.

#### W7-5994: a slip, slewed instead of stepped

At 1,566 s the card was handed pts 1566.197967 twice (slots 94533 and 94534): a slip of the card against the picture clock, which 1c
shows every ~16 min at Computer (W1) and Stage 2 showed once in 2.5 h. The SDI picture's line moved by one frame (φ −10.927583 →
−10.944267 s, −16.684 ms). Stage 2 followed it as designed by steering, not by a write: 16.7 ms is under the 20 ms bound at 59.94 (at
23.976 the frame, 41.7 ms, would have been a write). The controller slewed at up to −1,657 ppm, overshot to −4.2 ms on its integrator,
and took about 2 min to settle; ρ − 1 averaged −27.4 ppm over the run for that reason.

The SDI sound steps with its picture at a slip (a new run, §10.22), so the Mac's sound should too. Fixed: a **new picture line while
steering** is a slip, and an error over 1 ms there (`CardClockStage2.slipBound`) takes one position write to the new line, logged
`re-anchored to the SDI picture at its new line #n (a slip)`, counted apart from the 20 ms coarse writes, integrator held. A test
switch reproduces a slip on demand: `MANIFOLD_DECKLINK_SLIP_AT="120:-1,240:+1"` (DEBUG, `MetalVideoRenderer.deckLinkSlipShiftLocked`)
moves the timed pull's target by whole card frames once the source clock passes each time.

#### Round 2: chain 24, D's control pair on `fu7`, then build `fu8`, 2026-11-13 02:23–03:33

`fu8` = `fu7` + the W6 start fix, the slip write, the off-main Pause stop and the slip test switch. Package tests pass.

| Run | Result | Verdict |
|---|---|---|
| D control, `fu7`, **Stage 2 off** (`d24c-tr-5994`) | segments 33–34 samples into their frame; card +73…+74 ppm against the host | — |
| D, `fu7`, Stage 2 on (`d24s-tr-5994`), straight after | 32–33 samples; card +92…+94 ppm | — |
| D, `fu8` (`d24-tr-5994`) | 32 samples (7 of 7); card −81…−85 ppm | **Pass**: as 1c on the same night |
| W6b, `fu8` | Every one of the 20 output starts made while playing now starts the sound (20 late starts, 0 left parked), `e` within ±0.01 ms after each. But each start was **447–482 ms** into the SDI picture's run: the picture line came within ~50 ms, but the card line's fit needed 0.5 s of stamps | **Fail** (late) → fixed, chain 25 |
| Slip test 59.94 (`sl-5994`, −1 frame at 120 s, +1 at 240 s) | 2 new lines, 2 slip writes at +16.70 and −16.69 ms; `e` at +2 s −0.015 and −0.012, at +10 s −0.022 and +0.011 ms; 0 coarse writes | **Pass** |
| Slip test 23.976 (`sl-2398`) | 2 slip writes at +41.71 and −41.70 ms; `e` at +2 s −0.002 and −0.016, at +10 s +0.010 and −0.010 ms | **Pass** |
| W3b, both rates, `fu8` | 7 starts and 3 stops each, 0 late, 0 position writes, 0 timeouts; starts 83.6–100.6 ms after Play at 59.94, 191.0–228.4 at 23.976 | **Pass** (lag range as measured, not as guessed) |
| W7b-5994, built-in, 30 min, `fu8` | spread 0.073 ms, max \|e\| 0.074, drift −0.0006 ms, ρ − 1 −17.574 against −17.932 (0.36), 1-s medians 0 steps (largest 0.019 ms), 0 gaps, no slip in the run | **Pass** |

**D: the 8 samples are the rig, not Stage 2.** With Stage 2 off, on the same build and the same night, the SDI sound sits 33–34
samples into its frame, as with it on (32–34). The SDI sound's place against its picture has moved by about 7 samples since 1c's runs of
2026-11-11/12 (25–27), and **the card's rate against the host with capture open is not stable**: +14…+19 ppm at f20, −104 at d22,
+73 at d24c, +92 at d24s, −83 at d24, against −10…−11 in every run with capture closed. The card's output clock evidently follows
something on its input side while capture is open (UNKNOWN what; not pursued in this round). Method A records with the SDI input open,
so its runs will see this too; Stage 2 steers to the card whatever its rate (B is 2,000 ppm).

All three D runs: 0 late edges; the session after the output restart reports 926–1,460 missing samples, Stage 2 off as on, as in
1c (f20: 842 and 939; f16: 746 and 837).

**The Pause stop is on time; its log line is not.** Off main the line still reads ~31 ms after the due time, every Pause. The sound's
clock, read in the next ticks, is parked 0.02–0.80 ms past the paused frame's content (w3b, both rates, and w7b): the stop lands on
time, and the ~30 ms is the `rate = 0` call returning (the log is taken after it).

**W6b's late starts.** `CardClockLine.fit` returned nothing until 0.5 s of stamps. Now, under 0.5 s, it holds the rate at 1 and fits
the offset (at ±100 ppm, under 50 µs over that half second, which the steering takes out); 3 paced stamps are still required. New
test `testShortSpanHoldsRate`. Build `fu9`; chain 25 runs W6 at both rates.

#### Round 3: chain 25, build `fu9`, 2026-11-13 03:38–03:50

`fu9` = `fu8` + the short-span card line. Package tests pass (`swifttest-fu9b.log`).

| Run | Result | Verdict |
|---|---|---|
| W6c-5994 | 22 renderer moves each way; 21 starts with the SDI picture and 1 late start of 3.3 ms (under a frame); 0 position writes, 0 timeouts; `e` at +2 s within ±0.036 ms after every start. Silence from the move to the start (the wire's lag): 83.3–99.0 ms | **Pass** |
| W6c-2398 | 22 of 22 starts with the SDI picture; `e` at +2 s within ±0.037 ms; silence 190.7–228.8 ms | **Pass** |

#### Where Stage 2 stands after round 3

Every unattended prediction of §10.28 passes on `fu9`, or on `fu8` for runs the short-span line cannot touch (it acts only in the first
0.5 s after an output start). Exceptions:
- the tick-to-tick step count, mis-stated (the read's noise), replaced by steps between 1-s medians: 0 in every steady run;
- W5's ρ, which does not settle in 30 s per device;
- the Play lag at 23.976, up to 228.8 ms against a guessed 130–220.

Measured, not predicted:
- the wire's lag is 83–101 ms at 59.94 and 189–229 ms at 23.976, and the Mac is silent for that long at an output start;
- the D placement has moved with the rig (33 samples at −0.69 ms tonight, Stage 2 off or on).

Not yet known: K (method A, attended, next) and audibility at an output start (by ear, same session).

#### Method A, attended: the steps (not yet run)

Build `fu9`, destination Computer, 59.94 fixture, `MANIFOLD_SDI_AUDIO_BOTH=1` (SDI gate open at Computer). Left = Manifold's output
(Audio Hijack Application source), right = the SDI loop's embedded audio (Input Device "Blackmagic DeckLink 8K Pro (1)", channel 1).
Analysis: `w2-ah.py <wav> --sdi-offset-ms -0.69 --mac-latency-frames 28 --sdi-in-latency-frames 4000`. The offset is tonight's D
(Stage 2 off and on). The latencies are as reported, not measured: Scarlett output device 14 + safety 14; DeckLink (1) input
device 0 + stream 0 + safety 4,000, buffer 512 not counted. Whether Audio Hijack compensates any of them is UNKNOWN, so the at-taps
figure is the primary result.
