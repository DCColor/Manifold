# Card clock findings: what the SDI slip fix must be designed around

**Result in brief (2026-11-06).**

- **The slips are real, and rarer than §7.9 implied.** Left alone, this card runs at −11.67 ppm against the host, steady, and a file with
  sound follows the Mac's audio device at about +5.9 ppm. That is +17.6 ppm apart: one skip every 948 s at 59.94, measured 947 s.
- **§7.9's "the card's rate differs per session" was caused by the measurement.** `capture` opening the card's input on the loop moves
  the card's output clock, to a different value each time, up to about ±125 ppm. When it closes, the card returns to −11.7.
- **The file clock follows the audio device,** even with destination SDI, where that device is muted and nobody hears it.

Step 1 of the card-clock investigation: **measure only**. No fix and no design here. The bug is `BUGS.md`, *SDI from a file slips
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
