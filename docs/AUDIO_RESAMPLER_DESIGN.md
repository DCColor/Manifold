# The §11 real fix — an adaptive resampler, so the synchronizer's rate is written once

**Design only. No code in this document is in the tree.**
Companion to `docs/LIVECLOCK_AUDIO_MIRROR_FINDINGS.md`, whose §11.11 is the constraint every choice
here answers to, and to `docs/AV_SYNC_FINDINGS.md`, which answers open questions 1, 2 and 4 of this
document by measurement (2026-09-23) and adds three lip-sync defects the design has to account for. Written 2026-09-23.

*Measured fact, inference and open question are labelled separately throughout, as in the findings
document. Where a number is carried over from there it is cited to its section rather than
restated as new.*

---

## TL;DR

`AVSampleBufferAudioRenderer` mutes for ~50 ms on **every** write to the synchronizer's rate —
`setRate(_:time:atHostTime:)` with a step, `setRate` with a deliberately zero step, and the bare
`synchronizer.rate = r` property set, 19/19, 19/19 and 18–19/19 respectively (§11.11). There is no
cheap call. The only fix that can work is one that stops writing the rate.

So: **apply the rate to the material instead of to the renderer.** Put an asynchronous
sample-rate converter in `LiveAudioSink.enqueue`, between the tap and the renderer, and make its
ratio the thing the control loop moves. `synchronizer.setRate` is then called exactly once per
session, at the first anchor, and never again for the life of the connection.

The ratio is steered by **the measured position error**: the paired read of §2.1, taken per
buffer on the audio thread and fed through a slow PI loop (§2.2). The closed loop's time constant is
10 s, 100× slower than LiveClock's 0.1 s P-loop update, and that separation is what keeps §5 intact.

⚠️ **REVISED 2026-09-25 from steps 2–3.** This paragraph used to make the ratio `1 / smoothedRate`
plus a trim. Step 3 measured that `smoothedRate` is not the slope of the line the audio has to
follow: +60…+130 ppm against +5 realised on SRT, and +1073 → −123 within one Cloudflare session
(11.2). It no longer reaches the ratio at all.

A ratio change in a polyphase resampler is one addend in a phase accumulator. It is glitch-free
**by construction**, not by measurement — which is the one property this whole fix depends on, and
the reason the recommendation is our own vDSP implementation rather than any Apple converter object.

---

## 1. Where it sits

### 1.1 The seam, and why there is exactly one

Every push transport that is audible on the desktop reaches the renderer through **one function**:

```swift
// FrameEngine.swift:2086-2094
public func enqueue(_ sampleBuffer: CMSampleBuffer) {
    probe?.willEnqueue(sampleBuffer)      // DEBUG || MANIFOLD_TELEMETRY
    tap.ingest(sampleBuffer, path: path)
    renderer.enqueue(sampleBuffer)
}
```

The three call sites are, verbatim:

| transport | call site | what it hands over |
|---|---|---|
| **SRT** | `SRTFrameRouter.swift:1325` — `sink.enqueue(sb)` | Int32 interleaved, PTS = `audioPTSTicks` on `CMTimeScale(sampleRate)`, pinned to the program's 90 kHz `sourcePTS` (§9) |
| **WHEP** | `WHEPAudioReceiver.swift:241` — `sink.enqueue(sb)` | Int32 interleaved, PTS = absolute RTP sample count / 48000, 960-frame Opus packets |
| **NDI** | `NDIService.swift:2077` — `sink.enqueue(sb)` (inside the shared `push` closure) | Int32 interleaved, PTS = `audioPTSTicks` on the sample rate's own timescale, pinned to `monotonicNow()` |

**One shared component, instantiated per session by `beginLiveAudio`, living in `ManifoldCore`
beside `LiveAudioSink`.** Not one per transport. Three reasons, and the third is the one that
matters:

1. The error signal is the *same quantity* for all three — `synchronizer.currentTime()` against a
   target — differing only in how the target is computed, which is already parameterised by
   `cushion` and by the mirror-versus-direct-anchor split.
2. The state it needs (sample rate, channel count, format-change reset) is session state, and
   `beginLiveAudio` already owns exactly that lifecycle.
3. ⚠️ **Per-transport copies of audio-path logic have diverged twice in this file's history and
   both times the divergence was invisible.** `LiveAudioSink`'s hardcoded `.whep` path label
   mislabelled an entire SRT session; §9's PTS-grid defect was fixed in NDI on 2026-09-18 and
   shipped again in SRT on 2026-09-21 because the two paths each had their own timestamp code.
   A second resampler is a second place for the phase accumulator to be written in the wrong
   representation.

### 1.2 The exact insertion point — AFTER the tap, BEFORE the renderer

```
sink.enqueue(sb)
  ├─ probe.willEnqueue(...)    ← MOVES to the resampler's output (see §4.1)
  ├─ tap.ingest(sb, path:)     ← UNCHANGED. Original samples, original PTS axis.
  ├─ resampler.process(sb)     ← NEW
  └─ renderer.enqueue(out)     ← resampled, new contiguous output axis
```

⚠️ **THE ORDER IS NOT A TIDINESS QUESTION AND THE EXISTING COMMENT UNDERSTATES IT.** The doc
comment at `FrameEngine.swift:2084` reads *"Tee to the tap, then to the renderer — the SAME order
and the same two consumers the file pump feeds, so metering, SDI embedding, routing and mute all
apply unchanged."* With a resampler in the path that ordering becomes load-bearing for a new
reason: **the tap and the renderer are on different clocks and must receive different audio.**
See §4.2. The comment must be rewritten, not merely preserved.

### 1.3 File playback is untouched by construction, not by care

The file paths — `beginAudioReading` (AVFoundation), `LibavAudioSource`, `FileFrameSource`,
`LibavFrameSource` — each enqueue into `audioRenderer` **directly**, driving their own
`requestMediaDataWhenReady` + `while isReadyForMoreMediaData` pump. None of them constructs a
`LiveAudioSink`; none of them calls `beginLiveAudio`. The resampler is reachable only from
`LiveAudioSink.enqueue`, so a file cannot reach it however the code is later edited.

That is a stronger guarantee than a flag, and it should stay that way: **do not add a
`if isLive` branch to a shared enqueue path to get this.**

### 1.4 HLS — no change, and the reason is not "not yet"

`HLSPull` → `HLSAudioTap` → `AudioTapBuffer`, and audio is played by `AVPlayer` against the
`AVPlayerItem`'s own timebase. Nothing in the HLS path opens `beginLiveAudio`, obtains a
`LiveAudioSink`, or touches the synchronizer (`HLSClient.swift:334-338`). There is no rate write to
remove, so there is nothing for a resampler to fix.

⚠️ **AND THE STANDING INSTRUCTION AT `HLSAudioTap.swift:30-76` FORBIDS ADDING ONE.** Verbatim:
*">>> IF YOU ARE HERE TO ADD A `LiveClock`, A SENTINEL, A CUSHION, AN EPOCH LATCH, A DRIFT PID OR A
RATE SLEW: STOP."* It is backed by a measurement — 238 consecutive callbacks, item↔host mapping flat
to a −7.8 ppm residual that never accumulates because the mapping is re-read rather than integrated.
Audio and video out of an `AVPlayerItem` are two reads of one clock. **HLS appears in the acceptance
matrix only as a control that must not change.**

### 1.5 `SyntheticLiveSource`

Substitutes `renderer.clock` and drives the video renderer; it never opens a live-audio session.
Untouched. Its depth-grid sweep (`docs/LIVECLOCK_PRESETS.md`) must remain reproducible, which it
does because nothing in this design writes LiveClock state.

---

## 2. What steers it

### 2.1 The measurable, and how tightly it can be read

§11.11 settled the reader question directly. Read tightly, `synchronizer.currentTime()` is good to
**0.97 µs sd — 0.047 samples at 48 kHz** — and quantises at 0.062 samples. The 83 µs residual on
the 1 Hz series is *sampling* jitter (host read spread reaching 1.1 ms on a sleeping thread), not
timebase noise.

**So the pairing is the instrument, not the reader.** The error is evaluated on the enqueue thread,
per input buffer, with nothing between the two reads:

```
t0     = CACurrentMediaTime()
actual = CMTimeGetSeconds(synchronizer.currentTime())     // device-clock axis
t1     = CACurrentMediaTime()
target = mapping.senderPTS + (t1 - mapping.hostTime) * mapping.rate - cushion
err    = actual - target                                   // + = audio timebase AHEAD
```

Two disciplines, both from §10's rule that an instrument is verified before it is believed:

* **Discard the sample if `t1 - t0 > 200 µs`.** A preempted read pair produces an error reading
  dominated by scheduling, and §11.11 measured exactly that failure at up to 1.1 ms — a hundred
  times the quantity being measured.
* **Evaluate the mapping locally rather than calling `LiveClock.now()`.** `now()` takes LiveClock's
  lock, which the 10 Hz control tick also holds; the mirror already caches `senderPTS`, `hostTime`
  and `rate`, and evaluating that line at `t1` is exact. This keeps the audio path from ever
  blocking on the video control loop — a property worth having independently of jitter.

Evaluation cadence is **per input buffer**: 21.3 ms (AAC 1024), 20 ms (Opus 960), 10 ms (NDI pump).
That is 47–100 Hz, against the current 10 Hz heartbeat — more samples, tighter pairing, and on the
thread that already owns the audio.

⚠️ **REVISED 2026-09-25 — ONCE THE RATIO MOVES, `actual` IS CONTENT TIME, NOT THE TIMEBASE.** Through
step 3 the ratio was pinned at 1.0 and the stage compensated its own delay, so output tick k carried
input sample k and `synchronizer.currentTime()` *was* the content time being heard. At any other
ratio the timebase counts OUTPUT seconds on the device clock, and it is *meant* to drift from the
target by exactly the ppm the loop is absorbing: about 60 ppm on MediaMTX, which is 250 ms in about
70 minutes. The quantity to null is the input-axis time of the sample being heard:

```
actual = stage.inputTime(atOutputTime: CMTimeGetSeconds(synchronizer.currentTime()))
```

The stage already owns the output↔input relationship (anchor, emitted count, phase accumulator). It
keeps a short ring of (output tick, input position) breakpoints, one per buffer because the ratio is
constant within a buffer, and answers by linear interpolation. At ratio 1.0 it returns its argument,
so step 3's measurements carry over unchanged, and that identity is step 4's first regression test.
**Anything that still compares the raw timebase with a target after step 4 is measuring the
correction, not the error.** Both existing position branches do exactly that (§2.4).

### 2.2 The control law — REVISED 2026-09-25 from steps 2–3

```
e    = actual − target                   §2.1 (content time) and §2.8 (target per transport),
                                          per input buffer, 47–100 Hz
e_f  = EMA(e, τ_e)
u    = k_p · e_f + i                      di/dt = k_i · e_f, integrated only while |u| < B
ρ    = slew( clamp(1 − u, 1 − B, 1 + B), S )     ρ = input seconds consumed per output second

k_p = 0.1 s⁻¹   k_i = 0.0025 s⁻²   τ_e = 2 s   B = 0.002 (±3.5 cents)   S = 200 ppm/s (0.35 cents/s)
```

The sign: `e > 0` means the audio content is ahead of the picture, and `ρ < 1` consumes content more
slowly so the picture catches up. `i` does not integrate while `u` is at the clamp (anti-windup),
and it is held across a coarse event (§2.4).

**There is no feed-forward term.** The superseded law was
`ratio = clamp(r_ff · (1 + k_p·e_f + i))` with `r_ff = 1 / smoothedRate`. Step 3 removed its premise:

| | realised drift at ratio 1.0 (11.2) | `smoothedRate`: step 2 median / step 3 range |
|---|---|---|
| NDI | +7.1 ppm | none (no mapping) |
| SRT local | +5 | +60 / +60 … +130 |
| WHEP MediaMTX | −60 | +106 / +80 … +250 |
| WHEP Cloudflare | +14 | −81 / +1073 → −123 within one session |

`smoothedRate` is the τ = 30 s EMA of LiveClock's *rate field*, which is the depth controller's output
(§10.3). Over minutes, that field is not the slope of the mapping. The mapping also moves by position
(realigns, snaps, re-anchors), and the filter still carries the relay. Fed forward, it would inject
tens to hundreds of ppm of error for the feedback to cancel at the loop's own speed.

**Why no feed-forward is needed, not merely why it is risky.** The plant is an integrator,
`de/dt = (ρ − 1) − d`, where `d` is the net slope of the target against the device clock (§2.8). A PI
controller on an integrating plant is a type-2 loop, so a constant `d` is nulled with **zero**
steady-state error by the integrator alone, without the loop being told `d`. Every drift steps 2 and 3
measured is constant on the loop's timescale. The largest is 65 ppm, 3% of B.

**What survives of feed-forward: nothing in the ratio.** The one quantity that looked like
feed-forward, the WHEP audio↔video slope from RTCP Sender Reports, moves into the **target** (§2.6).
It describes what the picture is doing, not how fast audio should be consumed, and the type-2 loop
nulls a sloped target the same way it nulls a constant `d`. `smoothedRate` is still computed and
logged as the comparison figure for steps 2–3, but it has no path to the ratio. If a feed-forward is
ever reintroduced, it has three conditions:
- it must be a *measured slope of the target line* (the SR fit's rate is the only candidate)
- it is gated on that fit's standard error being under 10 ppm
- it is clamped to **±150 ppm** (2.3× the largest measured drift), so a bad estimate costs at most
  150 ppm for the integrator to cancel

#### What the feedback term adds, and why it is new capability rather than a knob

The slew-site note at `LiveClock.swift:1110-1150` states the gap plainly:

> `mirrorLiveAudio`'s push gate is OPEN-LOOP — its `predicted` comes from what it last pushed plus
> host time, never from `synchronizer.currentTime()` — so it CANNOT SEE that divergence. Nothing in
> the audio path detects it. Nothing corrects it. […] **Nobody designed a drift corrector; one fell
> out of the video path.** WHEP and SRT are bounded by ACCIDENT.

The feedback term measures that divergence directly, on the only reading in the system taken on the
device clock. **It is the first closed loop on the SRT and WHEP audio paths, and it replaces NDI's
open-loop re-anchor rather than sitting beside it (§2.8).**

#### The numbers, from a simulation of this loop against the measured disturbances

A discrete simulation at one update per 20 ms (the Opus buffer). The measured error is the true
error plus the ±1.5 ms sawtooth seen within step 3's PAIRED windows. Each disturbance is one
§10 or §11 measured:

| disturbance (where measured) | superseded gains: k_p 0.05, k_i 0.002, τ_e 5 s | **adopted** |
|---|---|---|
| steady −65 ppm (MediaMTX, 11.2) | 0 steady error | **0 steady error**; ratio ripple 24 ppm p-p (0.04 cents) |
| post-presentation relay: mapping at +5000 ppm for 2 s, a 10 ms move (§10.10) | peak 9.9 ms; settles below 2 ms in **76 s** (ζ = 0.56) | peak 9.8 ms; **settles in 14 s** |
| jitter recovery: mapping at −5000 ppm for 16 s, an 80 ms move (§10.3, n = 1) | peak 60–69 ms; 118–158 s | **peak 59 ms; 92 s** |

**Why each gain has the value it has:**
* **`k_p` = 0.1 s⁻¹** is §10.5's "aggressive end, still fits". The closed-loop time constant is
  10 s: still 100× slower than the P-loop's update and 10× slower than the ~1 s depth wobble.
* **`k_i` = k_p²/4** makes the loop critically damped. The superseded 0.002 against 0.05 gave
  ζ = 0.56 and a 76 s tail on a 10 ms relay.
* **`τ_e` = 2 s** keeps the sawtooth's ratio ripple at 24 ppm while `k_p·τ_e` = 0.2 adds little lag.
* **B = 0.002** (±2000 ppm). The steady need is ≤ 65 ppm; B exists only for transients, and §10.10
  changed which transients those are:
  - §10.10's startup realign removed the cold-connect excursion (+3700–4000 ppm) at its source.
  - What remains is the post-presentation relay: up to 2133 ppm in the smoothed rate, but only about
    10 ms of actual movement. At `k_p` = 0.1 it asks for 1000 ppm and never reaches B.
  - Jitter recovery also remains. It moves the picture at 5 ms/s, faster than any bound this design
    would call inaudible can follow, so B only sets how much of it becomes lip-sync error: peak
    **59 ms** at 0.002, **47 ms** at 0.003 (with S = 500 ppm/s), and 80 ms uncorrected.
  - B is still 2.5× under LiveClock's own ±0.5% rail, so the resampler cannot chase a railed clock
    at full depth.
* **S = 200 ppm/s** (0.35 cents/s) is the original text's "2 ppm per 10 ms"; the table here used to
  say 2 ppm/s, which contradicted it. At 100 ppm/s a 10 ms relay settles in 15 s; at 29 ppm/s
  (criterion 7's old 0.05 cents/s) it takes 67 s, and the jitter peak reaches 76 ms. Above 200 ppm/s,
  S only matters for jitter recovery.

⚠️ **ONE TRADE FOR ROBBIE: lip-sync during jitter recovery against pitch.** B 0.002 with S 200 ppm/s
peaks at 59 ms of audio *lead* during a 16 s rail. B 0.003 with S 500 ppm/s peaks at 47 ms, at
5.2 cents and 0.87 cents/s. The usual detectability threshold for audio lead is about 45 ms, so
neither is clean, but 0.003 nearly is. The event is n = 1 (once in 10 min, loopback SRT, §10.3).
**Adopted: 0.002 / 200**, the conservative pitch choice, to be revisited with step 8's multi-hour
data.

⚠️ **RESPONSE TIME IS DELIBERATELY SLOW, AND THAT IS STILL THE POINT.** A 10 ms error closes in
about 20 s with the ratio never past 1000 ppm (1.7 cents). The whole class of correction that §11
measured as a 78 ms mute becomes a glide too slow for anything but the log to see.

### 2.3 How this avoids fighting the LiveClock P-loop

Four independent reasons, in descending order of how much they would survive a refactor:

1. **The coupling is one-way by construction.** LiveClock's only input is the video queue depth,
   pushed from `MetalVideoRenderer`'s tick (`MetalVideoRenderer.swift:2273`). The resampler touches
   neither the video queue nor `now()` nor any LiveClock state. There is no path by which a ratio
   change can reach the P-loop's error. Compare candidate 4 in §11.10, which the findings correctly
   flag as *"a change to the video control loop made for an audio symptom, which is how §9's decoder
   swap happened"*.
2. **Timescale separation, stated in numbers.** P-loop: 0.1 s update, ±0.5% authority. Resampler
   (REVISED 2026-09-25): 10 s closed-loop time constant, ±0.2% authority, 200 ppm/s slew limit. The
   resampler's time constant is 100× the P-loop's update interval and its authority is 2.5× smaller.
   Even if it *were* coupled, it could not participate in the P-loop's dynamics.
3. **There is no feed-forward (REVISED 2026-09-25).** LiveClock's rate field has no path to the
   ratio. The depth correction reaches audio only as movement of the mapping's *position*, seen
   through a 10 s loop, and that movement is the picture's, so audio has to follow it.
4. **The rail is benign here, and §3's lesson does not transfer.** §3's dead band was catastrophic
   because a *gate* closed at the rail and publication stopped. The resampler has no gate: at the
   rail it applies its maximum correction continuously, and the consequence is a bounded residual
   position offset, not silence. The failure mode §3 describes — *"a control system whose corrector
   is disabled by the condition it exists to correct"* — is structurally unavailable.

### 2.4 The one thing the resampler must NOT try to absorb

LiveClock makes **discontinuous position moves**: the snap (`targetDepth + 0.2` sustained 0.75 s),
the freeze guard, the overflow re-anchor, and the first anchor. These are genuine jumps in the video
timeline — the snap discards content — and audio must follow them or lip-sync breaks permanently by
the size of the jump.

At the ±0.1% rail a 200 ms snap takes **200 seconds** to absorb. That is not a correction, it is a
three-minute lip-sync fault.

So: **a second, explicit branch.** When `|err|` steps by more than 50 ms between consecutive
evaluations, splice **in the material** — drop (forward jump) or insert (backward jump) the
corresponding number of input frames across a short equal-power cross-fade, and keep the output PTS
axis contiguous. Reset `e_f`, hold the integrator.

Three properties, all of which matter:

* **No rate write.** The output axis never breaks, so §9's invariant holds and the renderer never
  mutes. Cost is a few ms of cross-faded material, once, against today's 78 ms of digital silence.
* **Transport-agnostic.** It keys off the measured error step, not off `LiveClock.Event`, so it
  works for NDI — which produces no events — and for an input-axis re-pin
  (`SRTFrameRouter.audioPTSTicks`'s 25 ms tolerance), which is the same class of step arriving by a
  different door.
* **Countable and correlatable.** Each splice logs its size and host time, and must line up with a
  `[SRT] snap-to-live:` / freeze-guard / queue-full line, or with an `axis RE-PINNED` line. A splice
  with no matching event is a defect, and that cross-check is only possible because both sides
  already log.

⚠️ **REVISED 2026-09-25 — WHAT REPLACES THE 10 ms POSITION BRANCH AT STEP 4, BEFORE THE SPLICE
EXISTS.** Two branches write the rate today, and both compare the **timebase**, not content time:
- the mirror's position branch (10 ms, `FrameEngine.mirrorLiveAudio`)
- NDI's `serviceDesktopAudioAnchor` (10 ms, `NDIService.swift:1954`)

Under a working loop the timebase drifts from the target by design (§2.1), so both would fire on a
correct loop: every ~70 min at 250 ms on MediaMTX, and every ~24 min at 10 ms on NDI. **Both are
replaced by one coarse branch, keyed on content-time `e`, with two triggers:**

* **level:** `|e_f| > 250 ms`, §7's figure;
* **step:** `|e_k − e_(k−1)| > 50 ms` between consecutive evaluations, which is this section's splice
  trigger.

The step trigger is needed at step 4, not only at step 5. A LiveClock snap discards at least 200 ms
(it fires at `targetDepth + 0.2`), which is under the 250 ms level. At B = 0.002 the loop would
absorb it at 2 ms/s: **100 s of lip-sync error.**

At step 4, either trigger takes the existing action: drain the stage, then re-anchor its axis and the
timebase with one `setRate(1.0, time:atHostTime:)`. That is one mute per coarse event, logged as
`[*-RESAMPLE] COARSE` with its size and trigger, and counted. `e_f` is reset and `i` is held. Step 5
replaces the action with the splice and removes the write; the triggers stay the same.

> **Inference, not measurement:** that a 5–10 ms cross-faded splice at snap cadence is preferable to
> a 78 ms mute. It is strongly implied — the mute is 8–15× longer and is *exact digital zero*, while
> a cross-fade preserves envelope — but it has not been captured. The instrument to settle it exists
> (§11.9) and step 5 of the build plan does.

---

### 2.5 ⚠️ THE TARGET LEAD IS NOT ALLOWED TO BE AN A/V OFFSET

**This is a hard requirement, and it is here because the app has shipped this mistake twice.**

The resampler holds a target lead — some amount of enqueued-but-unplayed audio sitting in the
renderer, because a renderer with no queue crackles (the 40/150/250 ms ladder in `BUGS.md`). That
lead is a queue depth. **It must not also delay the audio against the picture.**

Measured 2026-09-23 (`docs/AV_SYNC_FINDINGS.md`), both of these are live in the shipping build:

* **NDI** anchors its timebase `lead` behind the audio sample axis, while video is stamped on the
  same clock and presented at the next display tick. The queue depth and the lip-sync offset are
  **the same 250 ms**. `NDIService.swift:732` states this correctly; `BUGS.md` shipped it as
  "monitoring latency", which it is not. **Measured +230.1 ms of audio lag.**
* **SRT** gets ~500 ms of renderer queue as a side effect of a cushion that should be 0, and pays
  ~250 ms of it in lip-sync. **Measured +203.9 ms (local), +165.8 ms (Cloudflare).**

In both cases the queue was obtained by **moving the audio timebase backwards**, which buys depth
and lip-sync error in one move at a fixed exchange rate of 1:1.

**The rule for this design: the lead is obtained by starting the axis early, never by holding the
timebase late.** At connect, the output PTS axis is anchored so that the first buffer's media time
is `lead` AHEAD of the timebase — the renderer receives `lead` seconds of audio before any of it is
due, and the steady-state relationship between an audio sample's source time and the video frame
carrying the same source time is **zero**. The lead lives in how far the enqueued frontier runs
ahead of `currentTime()`, which is exactly the quantity §2.1's error term already measures, and
nowhere else.

⚠️ **AND THE INSTRUMENT THAT WOULD CATCH A REGRESSION HERE DOES NOT EXIST IN THE APP.**
`liveAudioDrift` returns `(timebase + cushion) − clock`, so it cancels the cushion and reads a clean
±4 ms whether the lead is an A/V offset or not — it read +3.40 to +4.00 ms across four sessions and
three separate lip-sync defects. **A lead that became an offset would not appear in any log.** That
is why §6.3 criterion 12 is a device-level A/V measurement and not a number from inside the process.

---

### 2.6 The WHEP input — an SR-derived line, not an assumption

⚠️ **ADDED 2026-09-23, FROM MEASUREMENT. THIS SUBSECTION EXISTS BECAUSE §2.1's `target` LINE IS
WRONG ON WHEP TODAY, AND NOTHING IN THE APP COULD SEE IT.**

`target = mapping.senderPTS + (t1 − mapping.hostTime) * mapping.rate − cushion` evaluates the VIDEO
LiveClock mapping, and `cushion` is a **constant** — 0 for WHEP (`WHEPFrameRouter.swift:350`). That
is correct only if the audio buffers being compared against it are stamped on the same axis as
`senderPTS`. On WHEP they are not: video PTS is the video SSRC's RTP timestamp rebased at its first
access unit, audio PTS is the audio SSRC's rebased at its first packet, and **the two SSRCs have
independent random bases** (`AV_SYNC_FINDINGS.md` §3.3).

`AV_SYNC_FINDINGS.md` §6 measured the gap. It is **not a constant**, in two different ways depending
on the server:

| | offset per session | rate | per-SR-pair noise |
|---|---|---|---|
| MediaMTX | spread **37.9 ms** over 3 sessions | **~60 ppm**, significant | 0.4 ms |
| Cloudflare | spread **60.3 ms** over 3 sessions | none measurable | **6 ms** |

**So the WHEP input to this loop is a LINE, fitted from RTCP Sender Reports, and both of its
parameters are needed:**

```
  offset(t), rate      = least-squares fit of Δ over a sliding window of SR pairs
  Δ(pair)              = [ ntp_a + (T_a0 − rtp_a)/48000 ] − [ ntp_v + (T_v0 − rtp_v)/90000 ]

  target  =  mapping.senderPTS + (t1 − mapping.hostTime) * mapping.rate  −  offset(t1)
  offset(t) = a + b · (t − t_fit)          a, b from the fit; b is the audio↔video rate
```

* **The OFFSET replaces `cushion` on this transport** — same slot, same sign convention, no longer a
  constant. `beginLiveAudio`'s parameter note already defines `cushion` as *"how far behind the
  mapping's senderPTS does this transport stamp its audio PTS?"*, which is exactly what the fit
  measures. The note needs no rewriting; the value simply stops being a guess.
* **The RATE enters through the target's slope, not the ratio** (REVISED 2026-09-25; this bullet
  used to put it in the feed-forward term, which no longer exists). §2.2's loop is type 2, so the
  ~60 ppm MediaMTX slope is nulled with zero steady error by the integrator, and nothing multiplies
  the ratio. The reason for doing it here rather than in the mirror still stands: correcting it by
  position would mean a `setRate` every few seconds, §5.1's mute forever.
* **Each new SR pair moves the fit**, so `offset(t)` steps by roughly the per-pair noise over √N
  (Cloudflare: 6 ms / √N). That is well under the 50 ms step trigger (§2.4), so the loop absorbs it
  as ordinary position error: a noisy fit costs a slow glide toward the new line, never a write.
* **A WHEP sender that sends no SRs is a deviation from the standard** (RFC 3550 §6.4.1 requires
  them of active senders). Fall back to the pre-existing behaviour, offset = 0 (today's rebased-axis
  assumption), log the deviation once, and never branch on which server it is.

**Three properties this buys, and one it does not:**

1. **Server-agnostic by construction.** Nothing branches on the vendor; the two servers simply land
   in different parts of the same two-parameter space. Required by `CLAUDE.md`'s server-agnostic
   rule, and reached from measurement rather than from principle.
2. **Noise and drift are handled by one mechanism.** The fit averages Cloudflare's 6 ms scatter down
   by √N and tracks MediaMTX's slope.
3. **No latched Δ, ever.** §6.6: latching at the first SR pair is 215–240 ms out after an hour on a
   ~60 ppm server.
4. ❌ **It does NOT remove the startup hold.** Audio still waits for the first SR pair before it can
   be stamped at all. Measured: **19–35 ms on MediaMTX, 928–956 ms on Cloudflare** (§6.5), against
   the 400 ms `targetDepth` the picture is already holding.

⚠️ **THE WINDOW LENGTH IS NOT CHOSEN AND SHOULD NOT BE GUESSED HERE.** It is a direct trade between
averaging Cloudflare's noise and tracking MediaMTX's rate, and it depends on §6.7 — whether that
~60 ppm belongs to OBS or to the relay. Pick it from a measurement, with a non-OBS sender through
MediaMTX, not from this document.

**UPDATED 2026-09-26 — the non-OBS run is in (`AV_SYNC_FINDINGS.md` §6.7): the ~60 ppm is OBS's, and
the window is noise-limited, not wander-limited.**
- **What the run measured:** ffmpeg → MediaMTX, 31 min, 3,728 SR pairs.
  - Slope +0.003 ± 0.001 ppm.
  - Per-pair sd 6.7 µs.
  - W-second block means about the full-run line scale like white noise out to 300 s: 7.8 µs at
    10 s, 3.3 at 60 s, 1.6 at 300 s. There is no wander to trade against, at least on this path.
- **So the window is set by per-pair noise**, of which the worst measured is Cloudflare's ~6 ms
  (§6.3). A least-squares fit over W seconds at one pair per second gives:
  - **offset:** sd ≈ σ/√W. 1 ms needs W ≈ 36 s; 0.5 ms needs W ≈ 144 s.
  - **slope:** SE ≈ σ·√12 / W^1.5. 5 ppm needs W ≈ 260 s; 2 ppm needs W ≈ 475 s.

  At OBS's 0.4 ms (§6.2) both are met within a minute.
- **Proposal: two timescales.**
  - The offset comes from a short window, so a step in Δ is tracked quickly.
  - The slope comes from a long one, so the ~60 ppm OBS slope is known to a few ppm.
  - Both window lengths are sized from the fit's own measured residual sd, so a noisier sender gets a
    longer window. That adapts to a measured protocol quantity. **The window is never selected by
    which server it is**, as `CLAUDE.md`'s server-agnostic rule requires.
- ~~⚠️ **The window is still not chosen.** Before it is, the OBS → Cloudflare comparison on the probe
  build has to show whether Cloudflare's SRs carry the slope its RTP timestamps do.~~ Done; see
  below.

**✅ FIT WINDOW CHOSEN, 2026-09-26, after the OBS → Cloudflare probe run (`AV_SYNC_FINDINGS.md` §6.7).**
That run found Cloudflare's SRs carry OBS's slope (+69.2 ± 0.3 ppm, against +66.5 by arrival).
- **Offset: about 60 s.**
  - Cloudflare's residual is not white. Block means fall from 4.2 ms at 10 s to 2.0 ms at 60 s,
    then level off at **1.7–1.9 ms out to 300 s**, where white noise would give 0.55 ms.
  - That ~2 ms wander floor is why a longer offset window buys nothing.
  - ffmpeg → MediaMTX (6.7 µs, white) is far inside it.
- **Slope: 300 s or longer.** Cloudflare gave ±3–5 ppm per 5-min block (per-pair sd 9.5 ms).
- **Both are sized from the fit's own measured residual sd, never by server.** A clean sender meets
  its target sooner, and a noisy one gets the full length.
- **Fitted fresh each session; no prior is carried over.**
  - OBS's slope varies between sessions, from about 0 to 70 ppm (§6.7), so any carried value would
    be wrong in some sessions.
  - Until the slope window fills, the integrator absorbs the remainder, as it does today.

**4e DECISION (a) — the video RTCP path: option c2.**
- **We own the video PLI and RR on the C API.** `RtcpReceivingSession` comes off the video chain.
- **libdatachannel is unmodified.** PLI and RR are sent through `rtcSendMessage`, the path NACK
  already uses. `rtcRequestKeyframe`'s one call site becomes our own PLI.
- **The video SR is parsed in the video message callback,** on the same receive thread as the audio
  SR. That is the path the probe build ran on both servers.
- **SRs are parsed by matching SSRC.** A compound packet can reach both tracks, and today's parser
  takes the first SR regardless of SSRC.
- **Rejected:**
  - (a) needs the bridge ported to the C++ API;
  - (b) needs a second patch to a library with no provenance chain;
  - the C API's media interceptor is broken at v0.24.5 (it forwards moved-from messages).

**4e DECISION (b) — CNAME: apply the SR line whenever both streams send SRs.**
- **When the SDP CNAMEs differ,** log one line per session. Cloudflare does this, while stamping
  bit-identical NTP in both SRs.
- **Fall back to offset 0, with a logged line, if the fit is unstable.** "Unstable" means a residual
  or jump bound derived from the fit's own measured sd.
- **Keyed on stream behaviour, never on the server.**

**For the post-4e soak: an unexplained ~15 ppm.** On the OBS → Cloudflare run, the audio lead
drained at −84 ± 2 ppm, while the SR audio↔video slope was 69.2 ± 0.3.
- The lead is reconstructed from wall-clock-timed frame counts, so the Mac's NTP frequency correction
  is one candidate.
- Check it with 4e's queue-depth log line (absolute enqueued frontier − `currentTime()` per steering
  window). It removes the wall-clock reconstruction.
- After 4e the lead should be flat. A residual drift near 15 ppm would mean something beyond the SR
  slope moves the queue.

**Where it enters the build:** step 4e (§7), after a measurement run picks the fit window. Until then
WHEP runs step 4 with today's constant offset. The integrator still absorbs the slope; only the
absolute lip-sync stays as arbitrary per session as it is today (`BUGS.md`, "WHEP lip-sync is
ARBITRARY PER SESSION").

⚠️ **AND THE OTHER THREE TRANSPORTS HAVE NO SUCH INPUT AND NEED NONE.** SRT, NDI and HLS each carry
audio and video on ONE timeline already — that is exactly why §3.1's SRT fix was a single argument.
This subsection is WHEP-only, and the fit must be absent rather than neutral on the others: a
degenerate fit over a stream that never reports would be a silent source of noise.

### 2.7 The first anchor waits for the first presentation — ADDED 2026-09-25

**Measured (11.4 note 2; 11.5).** On every WHEP connect the mirror anchored on the first mapping.
§10.10's startup realigns then moved the mapping by **67.9–110.5 ms** before the picture started, and
each move reached the mirror as a position write: 1–3 per connect, with the first two equal to the
realigns to 0.1 ms. One was audible as a 60 ms mute on MediaMTX. Under the step-4 loop they would
stop being writes, but they would become 70–110 ms of error to absorb at ≤ 2 ms/s, which is a minute
of lip-sync error at every connect.

**Rule: the session's one rate write happens at LiveClock's first presentation, not at its first
mapping.** That is exactly when §10.10's realign window closes (`hasPresentedOnce`), so the mapping
the audio anchors to is the one the picture actually uses.
- On WHEP, the anchor also waits for the first SR pair (§2.6 item 4) and takes the later of the two.
- The rule is keyed on LiveClock's own event and on the SR's presence, never on the transport or the
  server.
- SRT has 0 realigns by construction (§10.10), so there the rule costs only the 4–6 ms between the
  anchor and the first presentation.

Audio enqueued before the anchor waits in the renderer at rate 0. At the anchor,
`setRate(1.0, time: target)` starts playback at the target, and the renderer discards whatever is
already late, with no second write. **Cost to measure at step 4b:** in the logs from 11.1 and 11.5
every realign fell within 0.35 s of the first mapping, so WHEP audio should start up to about 0.35 s
later than today. That is inside the 400 ms `targetDepth` the picture is already holding.

### 2.8 The target, per transport — and NDI's +7 ppm — ADDED 2026-09-25

With no feed-forward, every transport runs the identical law and differs only in its target line,
and so in the net slope `d` the integrator learns:

| transport | `target(t)` | what `d` is | measured `d` at ratio 1.0 (11.2) |
|---|---|---|---|
| SRT | the video mapping line; cushion 0 (§3.1) | device crystal against the video sender | +5 ppm |
| WHEP | the video mapping line − SR `offset(t)` (§2.6) | the above, plus the audio↔video SSRC slope | MediaMTX −60; Cloudflare +14 |
| NDI | the anchor line `mediaNow − lead` on the pull clock, the same axis `serviceDesktopAudioAnchor` checks today | device crystal against mach | **+7.1** (+6.680 ± 0.003, §10.4) |

**NDI's +7 ppm is covered.**
- **Today** it is corrected only by `serviceDesktopAudioAnchor`: a 10 ms re-anchor about every
  24 min, each one a rate write and so a mute (§8 Q1).
- **Under this loop** it is 0.35% of B. The integrator settles to it within about 40 s (four
  closed-loop time constants), `e` is held at zero in steady state (type 2), and nothing is left for
  the coarse branch to catch.
- NDI's 10 ms re-anchor is retired into the coarse branch (§2.4). It has to be: it compares the
  timebase, which under the loop keeps drifting at the device's +7 ppm by design, so left alone it
  would keep firing every 24 min on a loop that is working.

**This folds build step 6 into step 4.** Step 6 was separate because NDI was "the one path where the
feedback term can be measured without the feed-forward confounding it". With no feed-forward
anywhere, that reason no longer exists.

---

## 3. How it resamples

### 3.1 The requirement that eliminates most of the field

**A ratio change, mid-stream, must be free of any discontinuity — at every ratio, at every instant,
without bound on how often it happens.** Everything else (quality, CPU, latency) is a budget
question. This one is a yes/no.

### 3.2 `AVAudioConverter` — NO

`AVAudioConverter` converts between two `AVAudioFormat`s whose sample rates are **fixed at
construction**. There is no ratio property. Changing the ratio means constructing a new converter,
which discards the sample-rate converter's internal filter state and its prime frames — i.e. a
discontinuity at exactly the moment we are trying to eliminate one. `primeMethod` /
`primeInfo` control how the *start* of a conversion is handled; they do not make a rebuild
transparent.

⚠️ **AND IT WOULD BE THE §11.11 MISTAKE IN A NEW COSTUME.** A converter rebuild per ratio change,
at 2 ppm/s with a sensible quantisation, is a few rebuilds per minute — the same cadence as today's
rate writes, with a splice in place of a mute. The lever §11.11 identifies is *the number of
discontinuities*, and this does not move it.

### 3.3 `AudioConverterRef` (AudioToolbox C API) — NO, same reason

The ratio is implied by the input and output ASBDs handed to `AudioConverterNew`. There is no
`kAudioConverterProperty…` that retunes the sample-rate stage of a live converter.
`kAudioConverterSampleRateConverterComplexity` selects quality, not ratio.

This is not a gap in the documentation: this is the API the SRT AAC decoder already uses
(`SRTAudioDecoder`, AudioToolbox / `AudioConverter` — see BUGS.md's *"one decoder again"*), and the
decoder's ratio is constant by nature. It is the right tool for that job and the wrong one for this.

### 3.4 An `AudioUnit` — `kAudioUnitSubType_Varispeed` / `kAudioUnitSubType_NewTimePitch` — POSSIBLE, NOT RECOMMENDED

`kVarispeedParam_PlaybackRate` is a settable AU parameter and AUs ramp parameters, so this is the
one Apple object that *can* take a changing ratio. Against it:

* **Pull, not push.** It renders through an input callback; `LiveAudioSink.enqueue` pushes
  unconditionally (`FrameEngine.swift:2551` is explicit that the live path *"consults neither
  `isReadyForMoreMediaData` nor `requestMediaDataWhenReady`"*). Inverting that at the one seam every
  live transport shares is a larger change than the resampler itself.
* **Glitch-freeness would have to be measured, not reasoned about.** The AU's behaviour on a
  parameter change mid-render is not specified at the µs level this needs, so we would build the
  offline harness anyway — and then have a component we cannot reason about when it misbehaves at
  3am.
* **16 channels.** Varispeed's channel handling at 16 in is not something to discover late.

⚠️ **The decisive argument is not that it would fail — it is that it cannot be shown correct by
construction.** §11.10 candidate 1 was killed by measurement after it looked obviously right;
§9's decoder swap was reasonable and wrong. A component whose central property has to be
established empirically is a component that can quietly lose that property in a macOS update.

### 3.5 Linear interpolation (`vDSP_vlint` and friends) — NO, and it is the tempting one

At ratios near unity the fractional phase sweeps slowly through 0→1. Linear interpolation at
fractional delay *d* has magnitude response `|(1−d) + d·e^{−jω}|`, which at *d* = 0.5 is
`|cos(ω/2)|` — **−11.5 dB at 20 kHz** at 48 kHz, and 0 dB at *d* = 0 or 1.

So the top octave is swept by a slowly-varying comb, over and over, forever. That is audible on
cymbals and room tone as a swishing, and — this is the part that makes it dangerous — it is
**invisible to a gap histogram, to `timebase−clock`, to the WAV tap and to every counter in §8's
list**, because nothing is discontinuous and nothing sums wrong. It is exactly §10's shape.

### 3.6 RECOMMENDED — our own polyphase windowed-sinc ASRC, vDSP inner product

```
ratio r (output frames per input frame), P = 1024 polyphase branches, N = 64 taps

  phase accumulator:  Q32.32 fixed point, 64-bit, incremented by round(2^32 / r)
  per output frame:   idx  = acc >> 32                     (integer input index)
                      frac = acc & 0xFFFFFFFF              (fractional position)
                      p    = frac >> 22                    (branch, 0..1023)
                      µ    = remaining bits                (inter-branch fraction)
                      h    = table[p] + µ * dtable[p]      64 taps, ONCE per output frame
                      out[c] = dot(h, history[c] + idx)    once per CHANNEL
```

**Why a ratio change is glitch-free by construction.** The ratio appears in exactly one place: the
increment added to the phase accumulator. There is no filter state keyed to the ratio, no buffer to
flush, no prime to redo. Changing the increment between two output samples produces the same output
as if the new ratio had always been in force from that sample on — which is the definition of
continuity for a time-warp. **This is a property of the structure, not a result to be re-verified
after every OS update.**

**Why the accumulator is 64-bit fixed point and not a `Double`.** §9's transferable lesson is that a
timing quantity can be exact to twelve decimal places in one representation and unrepresentable in
the one it is stored in. A `Double` phase accumulated over a 30-minute session
(48000 × 1800 = 8.64e7 increments) loses low bits monotonically; Q32.32 is exact, and the integer
part *is* the input sample index with no rounding rule to get wrong. The output PTS axis is derived
by counting output frames, never from the accumulator — same discipline as
`NDIService.audioPTSTicks` and `SRTFrameRouter.audioPTSTicks`.

**Quality.** Kaiser-windowed sinc prototype, **cutoff at 0.5·fs (Nyquist)**, β chosen for a
−100 dB stopband, N = 64, **P = 1024** with linear inter-branch interpolation.

⚠️ **BOTH OF THOSE NUMBERS WERE CORRECTED BY THE STEP-1 MEASUREMENT, 2026-09-24. This paragraph
previously read "cutoff at 0.45·fs (21.6 kHz)" and "P = 512", and each of those cost one acceptance
target.** Full numbers in §9.3 and §9.4; the reasons in one line each:

* **Cutoff 0.5, not 0.45.** This resampler never decimates — §5.2 bounds the ratio at ±500 ppm — so
  it is a fractional-delay interpolator and there is nothing to buy below Nyquist. At N = 64 and
  A = 100 dB the Kaiser transition width is 4.8 kHz, so a cutoff at 21.6 kHz puts the passband edge
  at **19.2 kHz** and 20 kHz lands inside the transition band. **And only an exactly-Nyquist cutoff
  makes branch 0 a unit impulse** (`sinc(n) = 0` at every non-zero integer), which is the identity
  property at ratio 1.0. Measured at 0.45: identity error **0.56**, ripple at 20 kHz **0.113 dB**.
* **P = 1024, not 512.** The binding constraint on resolution is the linear interpolation BETWEEN
  branches, whose error falls as 1/P² — 12 dB per doubling — not the prototype's stopband. Measured:
  512 → 19.6 bits (misses), 1024 → **21.5 bits**. The per-frame cost is identical; only the table
  doubles.

| property | design target | **measured, step 1 (§9.1)** | why it is achievable here |
|---|---|---|---|
| passband ripple to 20 kHz | **≤ ±0.02 dB** | **0.0000 dB** | the ratio is within ±0.1% of unity, so the filter is being asked to do near-identity work; at a Nyquist cutoff the passband edge is 21.6 kHz and 20 kHz is well inside it |
| alias / image rejection | **≥ 95 dB** | **103.6 dB** | for content below 20 kHz the nearest image is at fs − f ≥ 28 kHz, above the 26.4 kHz stopband edge |
| effective resolution | **> 20 bits** | **21.5 bits** | 1024 branches with linear inter-branch interpolation; the 1/P² law and the P sweep that measured it are in §9.3 |

**CPU at 16 channels.** Per output frame: one 64-tap coefficient build (≈192 flops, shared across
channels because the phase is common) plus one 64-tap dot product per channel (128 flops).

```
16 ch:  192 + 16 × 128  = 2240 flops/frame  ×  48000  ≈  107 Mflop/s
```

⚠️ **MEASURED AT 1.84% OF ONE CORE AT 16 CHANNELS, NOT THE "under 1%" THIS PARAGRAPH CLAIMED**
(§9.4). 0.383 µs per output frame at 16 ch; 0.013 / 0.022 / 0.155 µs at 1 / 2 / 8 ch. The flop count
is right and it is not what dominates: the per-channel pointer and call overhead inside the frame
loop is, which is what the 2 ch → 8 ch step shows (7× for 4× the channels). Still comfortably
affordable, and recoverable at step 3 by hoisting one deinterleaved scratch block out of the frame
loop.

Comparable to the scalar
per-sample conversion loops `AudioTapBuffer.ingest` already runs on the same thread. Deinterleave
once per buffer into per-channel float scratch (vDSP), process contiguous, re-interleave and clamp
to Int32 with the same clamp `ingest` uses. **Do not run the dot product strided over interleaved
Int32 at stride 16** — it is cache-hostile and it is the obvious shortcut.

**Added latency: N/2 samples = 32 / 48000 = 0.67 ms, constant.** It is absorbed once into the
initial anchor and never changes, so it does not appear in the control loop at all. Against NDI's
250 ms presentation lead and SRT's 250 ms target depth it is not a number anyone will notice.

**And it is testable without the app.** The prototype filter, the accumulator and the process loop
are pure functions over arrays. Step 1 of the build plan measures all three properties above against
synthesised material, offline, before a line of it is wired in — which is what §10 means by
verifying the instrument against a known-good case first.

### 3.7 What is explicitly NOT on the table

**Drop/insert of whole samples.** At the measured 420 ppm worst case that is 20 splices per second,
forever. It is the mechanism the §9 gravel *was*, arriving deliberately.

---

## 4. What it breaks or touches

### 4.1 The §9 sample-counted PTS axis

There are now **two** axes, and keeping them straight is the single highest-risk part of this design.

| | input axis | output axis |
|---|---|---|
| owner | the transport (`SRTFrameRouter.audioPTSTicks`, `NDIService.audioPTSTicks`, WHEP's RTP counter) | the resampler |
| pinned to | the source PTS / the wall clock, at a 25 ms tolerance | nothing — free-running, spliced only by §2.4 |
| who reads it | `AudioTapBuffer`, and through it the meters and SDI | `AVSampleBufferAudioRenderer` |
| contiguity | already exact by construction (§9) | `outTicks = outAnchor + cumulativeOutputFrames`, integer add, `CMTimeScale(sampleRate)` — exact by the same construction |

Three consequences to act on:

1. ⚠️ **`LiveAudioRendererProbe.willEnqueue` MUST MOVE to the resampler's output.** It sits at
   `FrameEngine.swift:2090`, before the tee. §9's headline result — *470/470 contiguous, zero holes,
   zero overlaps* — was measured at that point, and after this change that point is no longer where
   the renderer's input is. Leaving it would produce a gap histogram that reads perfect about a
   buffer stream the renderer never sees. **That is §10 item 7 for the third time**, and it is
   avoidable by moving one line.
2. **An input-axis re-pin becomes a position step, and that is an improvement.** Today
   `audioPTSTicks` re-pinning at 25 ms silently hands the renderer a stepped PTS. With the
   resampler it arrives as a 25 ms step in `err`, which §2.4's branch handles explicitly and logs.
   The re-pin logic itself is unchanged.
3. **Format change resets both.** A rate or channel change already restarts the input axis; it must
   also reset the resampler's history, accumulator and integrator, and re-anchor the output axis —
   **as a state reset only, never as a rate write.**

### 4.2 DeckLink / SDI — which clock does SDI follow, and must it see resampled audio?

**SDI follows the VIDEO clock, and it must see ORIGINAL audio. This is not a preference.**

The chain, from source:

```swift
// DeckLinkService.makeAudioConfig
sourceTime: { self?.renderer?.currentDeckLinkSourcePts() ?? .nan }   // the STAGED VIDEO FRAME's pts
read:       { startTime, n, dst in tap.read(framesStartingAt: startTime, frameCount: n, into: dst) }
```

`currentDeckLinkSourcePts()` (`MetalVideoRenderer.swift:3330`) returns the source PTS of the frame
in the front v210 staging buffer — the frame on the wire. The card's audio callback asks the tap for
the samples at that source time, ~50 times a second, and the card plays them out on **its own
genlock/crystal**. The synchronizer's timebase is not consulted anywhere in that path.

So there are three independent clocks in play and the resampler corrects exactly one relationship:

| pair | corrected by |
|---|---|
| sender ↔ Mac audio device | **the resampler** (this design) |
| sender ↔ DeckLink card | the card's own scheduled-playback machinery, reading the tap by source PTS |
| Mac audio device ↔ DeckLink card | nothing, and nothing should — they are never both the programme output (`deckLinkOwnsAudio` makes them mutually exclusive) |

⚠️ **RESAMPLING FOR THE MAC'S AUDIO DEVICE AND THEN EMBEDDING THAT ON SDI WOULD BE ACTIVELY WRONG.**
It would apply one machine's headphone-output crystal offset to a broadcast signal. The current
SDI instruments read `underruns=0, short=0, resyncs=0` for whole sessions (§8); putting the
resampler before the tap would be visible there first and would be blamed on the card.

Everything else on the SDI side is untouched *because* the tap is untouched:

* `AudioTapBuffer.append`'s 50 ms discontinuity tolerance and its re-anchor (which drops the
  retained window) — unchanged, still on the input axis;
* `isSupportedForSDI`'s 48 kHz-only refusal — unchanged; the resampler does not change the declared
  sample rate;
* `onFormatChange` → `audioFormatChanged` → card re-establish — fires from the tap, upstream of the
  resampler, unchanged;
* the `audioTrimSeconds` trim and the silence path — unchanged.

### 4.3 The meters

`AudioMeterScope` reads the tap (`peaksOfNewest` on live paths, `peaks(endingAt:)` on file). Original
audio, original levels, original clip detection. **Deliberately so:** a well-designed resampler can
overshoot on intersample peaks by a few tenths of a dB, and `clipThresholdInt32` is a −0.1 dBFS
threshold. Metering the resampler's output would turn a filter artefact into a clip indication on
material the source never clipped.

The resampler's own output clamp (same clamp as `AudioTapBuffer.ingest`) must **count** its clamps
and report them per window. A non-zero count is a real finding about the material or the filter; it
must not be silent.

### 4.4 The audio channel picker

`selectAudioTrack` (`FrameEngine.swift:1062`) rebinds the libav/AVF *file* decoder and is not
reachable on a live path — live sources publish only a channel count, through
`liveAudioEstablished(channels:)`. So the picker is untouched.

What *is* touched is the thing behind it: `selectAudioTrack` → `teardownAudioReading()` →
`audioRenderer.flush()` + `audioTap.reset()`, and `beginLiveAudio` calls `teardownAudioReading()`
first. The resampler must be constructed and destroyed on exactly that boundary and must not
survive it.

⚠️ **AND `AudioTapBuffer`'s roles-only format change must NOT reset the resampler.** The tap
deliberately distinguishes a late channel-layout declaration (an ADTS stream clarifying itself
mid-flight) from a shape change, and does not fire `onFormatChange` for the former — see the long
note at `AudioTapBuffer.swift:318-340`. The resampler keys on rate and channel **count** only, the
same two fields the card keys on. A relabel must not cost a splice.

### 4.5 Mute

`applyAudioMute` sets `audioRenderer.isMuted` (`FrameEngine.swift:686`), downstream of the
resampler. Untouched, and the volume fader, the off-speed shuttle gate, `deckLinkOwnsAudio` and
`externalAudioOutput` all reach the same decision by the same path.

✅ **MEASURED 2026-09-23, AND THE PROPOSED INSURANCE IS NOT NEEDED.** This section previously said
to suspend the integrator while `isMuted` is true, pending a measurement. The measurement has been
made (`docs/AV_SYNC_FINDINGS.md` §5.2) and the loop stays valid through a mute:

| segment | timebase slope | vs mach | buffers consumed/s |
|---|---|---|---|
| before a 20 s `isMuted` window | 1.000007300 | +7.3 ppm | 46.89 |
| **while muted** | 1.000006948 | **+6.9 ppm** | **46.86** |
| after | 1.000006804 | +6.8 ppm | 46.93 |

Slope change **−0.4 ppm**; media time projected across the mute from the 5 s before it is continuous
to **0.023 ms**; `isReadyForMoreMediaData` false on **0 of 1200** samples. A muted renderer keeps
advancing its timebase and keeps consuming at the same rate. **No suspension, no wind-up, no
correction on unmute — the integrator runs straight through.**

### 4.6 Connect and disconnect

| moment | today | with the resampler |
|---|---|---|
| `beginLiveAudio` | `synchronizer.rate = 0` (hold), probe records `rate: 0` | unchanged; construct the resampler here |
| first mapping / first anchor | `setRate(smoothedRate, time:atHostTime:)` | **`setRate(1.0, time: anchor, atHostTime: t)` — THE ONE RATE WRITE OF THE SESSION** |
| every subsequent correction | `setRate` at 3.0–7.7/min (§11.4) | **none** — ratio and splices only |
| un-anchored mapping (`nil`) | `synchronizer.rate = 0` | unchanged — holding is still correct, and it is a legitimate second write. Count it; it should be zero in a healthy session. |
| `endLiveAudio` | `rate = 0`, `flush()`, `tap.reset()` | unchanged; destroy the resampler here |
| reconnect | end + begin | a new session, a new single write |

So the acceptance criterion in §6 is stated precisely as **exactly one `[*-RENDERER] setRate` row
carrying a non-zero rate per session**, not "one setRate row" — `beginLiveAudio`'s and
`endLiveAudio`'s rate-0 writes bracket the session and mute nothing, because no audio is enqueued
across them.

⚠️ **`liveAudioDrift` KEEPS WORKING AND KEEPS MEANING THE SAME THING**, which is worth stating
because it is the number on every `chain` heartbeat line. It reads
`(timebase + cushion) − clockSeconds` from main-actor state and is independent of how the timebase
got where it is.

---

## 5. Sender-clock drift — the ppm the resampler must absorb

### 5.1 What has actually been measured

| pair | figure | source |
|---|---|---|
| sender vs receiver, WHEP | **σ = 0.021% (210 ppm), \|err\| max 0.042% (420 ppm)** — 1.1 cents total spread | `[WHEP-DRIFT]`, quoted at `FrameEngine.swift:2242` |
| sender vs pull, NDI | `cum = 48006.6 Hz` against `sndR = 48015.5 Hz` over 72 s → **≈ 185 ppm**; pull vs nominal **+137 ppm** | BUGS.md, "the pump's clock is fine" |
| audio device crystal vs mach | **−7.8 ppm** (≈ 28 ms/hour), explicitly *"a property of the output device, not a constant"* | `HLSAudioTap.swift:48` |
| LiveClock rail | **±5000 ppm** | `maxSlew = 0.005`, `LiveClock.swift:93` |
| **WHEP audio SSRC vs video SSRC, via MediaMTX** | **+57.7 to +66.3 ppm**, >30σ, residuals within ±0.5 ms of the line | `AV_SYNC_FINDINGS.md` §6.2, three sessions |
| **WHEP audio SSRC vs video SSRC, via Cloudflare** | **no drift distinguishable from zero** (±25 ppm standard errors), but **~6 ms per-pair scatter** | `AV_SYNC_FINDINGS.md` §6.2, three sessions |

⚠️ **THE LAST TWO ROWS ARE A DIFFERENT PAIR FROM EVERY ROW ABOVE THEM, AND THAT IS THE POINT.**
Everything else here is *sender against receiver* — one programme timeline against this machine's
clock. Those two are **one sender's audio clock against its own video clock**, which no instrument in
this app could read until §6's probe existed, and which the resampler must absorb separately because
it is not shared by the two streams it is trying to align.

### 5.2 The design bound, and what is deliberately excluded

**Absorb: ±500 ppm steady state.** That covers the 420 ppm worst sender case plus the device
crystal plus margin. The ±0.001 ratio bound gives **2.4× headroom** over the worst figure ever
measured on this app's transports.

**Do NOT absorb: the ±5000 ppm rail.** That is the video depth corrector, it is bang-bang
(§11.6: *"a relay controller that occasionally goes linear"*), and feeding it into a resampler is
the 17-cent warble at 10 Hz that §5 says the smoothing exists to stop. ~~It reaches the ratio only
through the τ=30 s feed-forward, attenuated exactly as today.~~ **REVISED 2026-09-25:** there is no
feed-forward any more. The rail reaches audio only as movement of the mapping's position, through
the 10 s closed loop and the ±0.2% bound (§2.2).

⚠️ **AND THE CLOUDFLARE SRT DEPTH EXCESS IS NEITHER OF THESE.** It is an SRT figure. Cloudflare WHEP
has no reorder and an excess of −12 ms median, flat over 30 min (§13.3). §11.8 measures `depth − count×D` at
**+51 ms median, +135 ms p90, +152 ms max** on Cloudflare against **−8 ms median** locally. That is a
position offset caused by reorder inflation, not a rate, and no resampler can or should absorb it:
absorbing it would mean varispeeding the programme to chase a measurement artefact. It remains §7's
open root cause. The resampler makes it stop producing mutes; it does not make it stop existing.

### 5.3 Steady-state A/V offset the loop should hold

The loop holds the *mean*; the residual instantaneous offset is the depth ripple, because that
ripple is genuinely present in the video's own presentation timing. So the bound is a property of
the transport, not of the resampler, and must be stated per transport:

| path | target bound on `timebase − clock` | rationale |
|---|---|---|
| local SRT | **±15 ms p99 over 30 min, no trend** | the healthy error envelope is ±13 ms (§3); the historical Stage-2 baseline was ±7 ms over 50 s with 388 mapping changes |
| WHEP | **±15 ms p99** | same envelope class |
| NDI | **±10 ms p99** | no depth loop at all; error is pure crystal, and `desktopAudioAnchorTolerance` already runs tighter |
| Cloudflare SRT | **±60 ms p99**, and a stated dependency on §11.8 | the +51/+135 ms depth excess sets the floor; a tighter number here would be a promise about somebody else's muxer |

**Drift bound, all paths: zero trend over 30 minutes.** At 420 ppm uncorrected the offset would
reach 756 ms in 30 minutes; the acceptance test is that a linear fit over the run has a slope
indistinguishable from zero at the measurement floor.

---

## 6. Acceptance test

⚠️ **NOT EARS.** §9's "THE CASUALTY" is the record of what happens when a remedy is judged by the
same sense that reported the symptom. Every number below comes from an instrument.

### 6.1 Preconditions on every run — non-negotiable, from §11.11

Three gates, all of which have already voided recordings once:

1. **`O_EXLOCK` singleton.** Audio Hijack launches the target application itself; a second copy
   launched from the terminal filled in every mute the first one made and the experiment reported
   the exact opposite of the truth. Confirm a **single** correlation peak at r ≈ 1.000, not two at
   r ≈ 0.707.
2. **Out-of-band energy check.** The reference is brick-walled at 14 kHz by construction. Any
   capture carrying > 0.5% of its energy above 15 kHz is the capture tool injecting noise and the
   run is void.
3. **Injected-fault gate on the detector** before the run, not after.

### 6.2 The matrix

Device-output capture, `~/Desktop/manifold-audible-events/`, 3 min per cell for the mute counts and
30 min per cell for the drift bound.

| | baseline mutes/min overall (§11.4) | baseline steady state | **target** |
|---|---|---|---|
| local SRT | 4.95 | 3.0 | **0.0 / 0.0** |
| Cloudflare SRT | 11.08 | 7.7 | **0.0 / 0.0** |
| WHEP | 7.32 | 4.5 | **0.0 / 0.0** |
| NDI | not yet measured — **measure the baseline in build step 2** | | **0.0 / 0.0** |
| HLS | control — must not change | | unchanged |

⚠️ **NDI HAS NO BASELINE IN §11 AND THAT IS A HOLE IN THE EVIDENCE.** §11 measured three transports;
NDI re-anchors through `anchorLiveAudio` at `setRate(1.0, …)` on a closed-loop cadence
(`NDIService.swift:1918`), which is a rate *write* even though the rate *value* does not change. It
is not known whether that mutes (see open question 1). Measure it before step 6, not after.

### 6.3 The full pass criteria

| # | criterion | instrument |
|---|---|---|
| 1 | **0 mutes/min in steady state** on local SRT, Cloudflare SRT, WHEP and NDI at the device output | §11.9 offset-track harness; silence found directly on the capture, never inferred from the track |
| 2 | **Exactly one `[*-RENDERER] setRate` row with a non-zero rate per session**, on every transport | existing probe log, filtered on `rate != 0` |
| 3 | **`timebase − clock` within §5.3's per-path bound, p99, over 30 minutes, zero trend** | existing 1 Hz `[*-AUDIO] chain` / `[LIVECLOCK]` series, linear fit |
| 4 | **Gap histogram 100% `EXACTLY ZERO (contiguous)`** on the resampler's output, all windows, all transports; `axisRePins = 0` | `LiveAudioRendererProbe`, **moved to the output side** (§4.1) |
| 5 | **No new content holes.** Local must stay at zero. Cloudflare's existing `+837, +676, +439, +85, +76` samples and WHEP's `+432, +6, +0` must not grow in count or size | offset-track step events, §11.4 |
| 6 | **Splice events ≤ the count of LiveClock coarse events**, each matched to a `snap-to-live` / freeze-guard / queue-full / `axis RE-PINNED` line | new splice log line, cross-referenced |
| 7 | **Pitch (REVISED 2026-09-25): steady-state ratio within ±0.1%; transient within ±B (±0.2%); rate of change ≤ 0.35 cents/s (the 200 ppm/s slew limit).** The old wording, "within ±0.1% and under 0.05 cents/s", is a loop that takes 67 s to follow a 10 ms relay (§2.2) | steady tone from OBS, FFT of the device capture in 5 s windows |
| 8 | **SDI unchanged**: `underruns=0, short=0, resyncs=0` for a full session with DeckLink output on | existing `DeckLinkAudio` counters |
| 9 | **Meters unchanged**: peak and clip-run readings match a pre-change capture on identical material | `AudioTapBuffer.peaksOfNewest` |
| 10 | **CPU**: total process CPU increase < 2% at 16 channels, 48 kHz | Instruments, NDI 16 ch source |
| 11 | **HLS control**: unchanged on every instrument above that applies to it | — |
| 12 | **A/V SYNC, at the device, per transport** — see below | flash-and-beep fixture + two-instance OBS capture |

#### Criterion 12, stated in full, because it is the one the app cannot measure itself

Method and instrument: `docs/AV_SYNC_FINDINGS.md` §1. The fixture puts one white frame and one
40 ms 1 kHz beep on each whole second, coincident to **+0.0417 ms, sd 0.0000**; a second OBS
instance records Display Capture + macOS Audio Capture into one container on one clock; the
analyser passes an injected-offset gate at **0 / +250 / −120 ms → −0.0 / +250.0 / −120.0, sd 0.0**.

| | requirement |
|---|---|
| **control** | Manifold playing the fixture from disk, in the same session, as that run's zero |
| **file playback** | unchanged from the pre-resampler control, within ±5 ms |
| **local SRT, Cloudflare SRT, WHEP, NDI** | **within ±20 ms of the file control**, median over 30 s |
| **stability** | sd ≤ 20 ms, and no trend over 30 minutes |
| **frame rate** | **23.976 throughout** — see §1.4 of the findings; 30 fps is a different experiment and cannot be compared with §11's baselines |
| **gates** | beep count vs duration, 1.000 Hz grid fit, one burst per beep, digital silence between beeps — all four, every run |

⚠️ **THE PRE-RESAMPLER BASELINE FOR THIS CRITERION IS ALREADY MEASURED AND IT IS NOT ZERO**
(`AV_SYNC_FINDINGS.md` §2): local SRT **+203.9 ms**, Cloudflare SRT **+165.8 ms**, NDI
**+230.1 ms**, WHEP **−98.9 / +36.7 ms** on two sessions. So this criterion is not "did the
resampler avoid breaking lip-sync" — three transports are already broken, and the resampler is where
the lead is finally owned in one place. A run that leaves any transport outside ±20 ms has not met
§2.5.

📌 **WHEP CANNOT PASS THIS UNTIL ITS OWN DEFECT IS FIXED, AND THAT IS NOT THE RESAMPLER'S JOB.** Its
offset varies by ≥136 ms between sessions because no RTCP sender-report mapping exists (BUGS.md,
2026-09-23). Until that lands, WHEP's criterion 12 is **reported and not gated**, and the run must
record which ingest it used.

⚠️ **Criterion 1 alone is not sufficient and that is deliberate.** A resampler that simply stopped
enqueueing would pass it. Criteria 3, 4 and 5 are what distinguish "no mutes" from "no audio
problems", and they are the three that §10's list shows would otherwise read healthy.

---

## 7. Build plan

Eight steps. Each one is separately testable, each one states what is measured, and the app is
shippable at the end of every one of them.

### Step 1 — the ASRC, offline, nothing in the app

Build the polyphase resampler as a standalone type in `ManifoldCore` with a command-line or
`swift test` driver. Nothing calls it.

**Measured:** passband ripple to 20 kHz; alias/image rejection; effective bit depth against a
synthesised full-scale sweep; **continuity across a ratio change** (null a ramped-ratio pass against
a reference built from the same warp, sample by sample — the residual must be at the arithmetic
floor, not merely small); CPU in µs/frame at 1, 2, 8 and 16 channels; accumulator exactness over
8.64e7 increments.

**Gate:** the ratio-change null. If it is not at the floor, the structure is wrong and nothing
downstream is worth building.

### Step 2 — instrument the existing path, change nothing audible

Add the tightly-paired `(target, currentTime())` read and its 200 µs pairing gate, per buffer, on
all three push transports, behind the existing `DEBUG || MANIFOLD_TELEMETRY` gate. Log the implied
ppm per 10 s window. Take the **NDI mute baseline** (§6.2) with the §11.9 harness.

**Measured:** the real ppm range on this machine and these senders, per transport, over 30 minutes —
which §5 currently has to infer from three figures taken in three different investigations. The
ratio bound and `k_p` should be set from *this* number, not from the table in §5.1.

⚠️ **This is also the step that answers open question 3**, because a 30-minute trace of the paired
error tells you what the A/V offset actually does today, which is what any bound has to be
negotiated against.

### Step 3 — resampler in the path at ratio 1.0, loop open

Insert at the seam. Output on the new contiguous axis. Ratio **pinned to exactly 1.0**. Move the
probe to the output side. `synchronizer.setRate` written once at the first anchor; the mirror's
**rate** branch disabled; the **position** branch left enabled at its current 10 ms tolerance so the
session cannot drift catastrophically during the test.

**Measured:** gap histogram still 100% contiguous on the output axis; SDI counters unchanged; meters
unchanged; mutes/min dropped to the position branch's rate alone; and — the confirming number —
**the A/V offset now drifts at exactly the ppm rate step 2 predicted**, because nothing is
correcting it. A drift that does not match step 2's prediction means the plumbing is wrong, and that
is worth more than a clean run.

### Step 4 — close the loop (REVISED 2026-09-25)

The law in §2.2, on content time (§2.1), with the first-anchor hold (§2.7), one coarse branch
(§2.4) and every transport including NDI (§2.8). No feed-forward. Built in this order, each part
separately testable:

**4a. Content-time error.** The stage keeps (output tick, input position) breakpoints and answers
`inputTime(atOutputTime:)`, and the paired probe's `actual` switches to it. *Test:* identity at
ratio 1.0 (step 3's PAIRED figures reproduce), and exact inversion under a ramped ratio, using
step 1's warp fixture in `swift test`.
✅ **The paired probe now reports content time** (2026-09-26): `[*-PAIRED]` `err` is
`inputTime(atOutputTime: timebase) − target`, mapped after the second host read, never inside the
pair. It is the identity while the ratio is pinned at 1.0, so step 3's figures are unchanged.

**4b. First anchor at first presentation**, and at the first SR pair on WHEP. *Measured:* startup
position writes on WHEP go from 1–3 per connect to **0**, over cold and warm connects on MediaMTX and
Cloudflare. Audio-start delay is logged and must stay under the 400 ms `targetDepth`.

**4c. The controller as a pure function** (`e` → `ρ`, with clamp, slew and anti-windup), in the
`LiveAudioResample` target so it tests without ManifoldCore. *Tests* replay §2.2's three disturbances
and assert its table: 0 steady error at 65 ppm, a 10 ms relay settled within 20 s, and the jitter
peak ≤ 60 ms. A windup test holds 60 s at the rail, then releases: **≤ 4 ms overshoot after the
release, with the integrator held (≤ 500 ppm)** (REVISED 2026-09-26 from "no overshoot over 2 ms";
measured 3.65 ms and 448 ppm, against 68.9 ms and 9379 ppm without anti-windup). The residual is the
critically damped loop's recovery from B/k_p = 20 ms, where it leaves the rail, not windup.

**4d. Wire it.** The ratio goes into the stage per buffer. One coarse branch on `e` (level 250 ms,
step 50 ms) replaces the mirror's position branch and NDI's `serviceDesktopAudioAnchor`. Its action
is drain plus re-anchor, logged as `[*-RESAMPLE] COARSE`. NDI's target is its anchor line. The rate
branch is already off.

**4e. The WHEP SR line into the target** (§2.6), after one measurement run picks the fit window
(a non-OBS sender through MediaMTX, §2.6's open item). The SR parse already exists, log-only
(`af4ebe0`). Until 4e lands, WHEP runs with today's constant offset.

**Measured, 30 minutes per transport (local SRT, MediaMTX, Cloudflare WHEP, NDI):**
- `e_f` p99 within §5.3's per-path bounds, with zero trend. It is now measured on content time,
  which is what §5.3 meant by `timebase − clock`.
- **The integrator's settled value confirms the plant model:** about the realised drift of 11.2
  (SRT +5, MediaMTX −60, Cloudflare +14, NDI +7 ppm, with §2.2's sign). A different value means
  `target` or `actual` is wrong.
- `setRate` rows with a non-zero rate: 1 + COARSE count.
- Device-output mutes/min equal the COARSE count, measured with the §11.9 harness using 11.5's
  protocol (connect, reconnect, measure the reconnect).
- The ratio trace meets criterion 7 as restated.
- NDI `RE-ANCHORED` count: 0.
- Criterion 12, per transport.

✅ **THE TARGET THIS LOOP NULLS AGAINST IS NOW CORRECT ON SRT.** Open question 4 was answered on
2026-09-23 — the cushion put desktop audio ~200 ms behind its picture — and the one-line fix
(`SRTFrameRouter.swift:532` → `0`) was applied and verified the same day, leaving SRT's arithmetic
A/V at −1.3 ms. This step no longer carries it as a prerequisite. **The principle still stands and
still applies to NDI, which is ~230 ms out:** a loop that nulls its error against the wrong target
holds the wrong offset forever and reports zero. §2.5, `docs/AV_SYNC_FINDINGS.md` §3.1.

**Also measured at this step:** criterion 12, against the pre-resampler baselines
(local SRT +203.9 ms, Cloudflare SRT +165.8 ms, NDI +230.1 ms). This is the first step at which the
lead is owned by the resampler, so it is the first step at which those numbers should move.

### Step 5 — the splice branch

Replace the remaining large-position-error `setRate` with a material splice (drop/insert across a
short equal-power cross-fade), output axis contiguous.

**Measured:** `setRate` rows with non-zero rate == **1 per session**; mutes/min == **0**; splice
events counted, sized, and each one correlated with a LiveClock coarse-event log line; the offset
track shows a step of the expected size **with no run of silence in it**.

This is the step that makes criterion 1 and criterion 2 true. Everything before it is scaffolding.

### Step 6 — NDI onto the same loop — FOLDED INTO STEP 4 (2026-09-25)

With no feed-forward, NDI runs the same law as every other transport against its own target line,
and its 10 ms re-anchor must go at step 4 anyway, because it would fire on a working loop (§2.8).
What this step used to measure moves to step 4's list:
- the `RE-ANCHORED` count → 0
- device-output mutes/min → 0 against the NDI figure from 11.5 (0.0 / 0.0)
- the settled integrator agreeing with the +7 ppm those re-anchor lines used to imply

### Step 7 — remove what is now dead, and re-point the tripwires

`liveAudioRateThreshold` (0.0002), `liveAudioPositionTolerance` (0.010) and the rate branch of
`shouldPush` go. §11.2's 6 ms product ceases to exist as a quantity in the codebase.

⚠️ **THE HEARTBEAT (`onMappingTick`) STAYS, AND ITS JUSTIFICATION CHANGES — WRITE THE NEW ONE
DOWN.** It was installed at `167f7fe` because *"everything in this function — the EMA, the position
error, `shouldPush` — runs ONLY inside this call"* and a railed clock published nothing. With the
resampler evaluating per buffer on the audio thread, that is no longer true: the loop runs at 47–100
Hz regardless of whether the clock publishes. The heartbeat's remaining job is to keep
`mirror.smoothedRate` fed at a steady cadence so the τ=30 s EMA's `dt` stays small — which is real
and load-bearing, and is not the reason written in the comment today. **A comment that states a
reason which has stopped being true is how §9's PTS defect survived for three days.**

⚠️ **REVISED 2026-09-25: AND AFTER STEP 4 THAT REASON LAPSES TOO.** `smoothedRate` no longer reaches the
ratio (§2.2); it is a logged comparison figure. The heartbeat's remaining job is whatever the mirror
still needs a steady cadence for: publishing the mapping the paired probe evaluates. Re-derive it at
this step from the code as it then stands, and write down that reason, not either of the two
above.

Likewise the slew-site tripwires, which §5 records as having watched *"for the slew pinned at unity,
not pinned at the rail"*: re-point them at the quantity that now matters, which is the resampler's
ratio sitting at its own rail.

### Step 8 — soak and the full matrix

30 minutes per transport, the full §6.3 criteria list, all three §6.1 preconditions verified per run.
Then a multi-hour run on one transport for the drift bound.

---

## 8. Open questions — only Robbie can answer these

1. ✅ **ANSWERED 2026-09-23 — YES, IT MUTES. A same-valued rate write is not free.**
   Measured (`docs/AV_SYNC_FINDINGS.md` §5.1), device-output capture, gates passed
   (0.0000% out of band, correlation 1.000):

   | case | | changes | **muted** | core |
   |---|---|---|---|---|
   | A control | rate **changes** 1.0000↔1.0002, ±6 ms step | 10 | **10** | 63 ms |
   | **F** | **rate HELD at 1.0**, ZERO position step | 19 | **19** | 63 ms |
   | **F+** | **rate HELD at 1.0**, +6 ms position step | 19 | **19** | 63 ms |
   | E floor | nothing at all | 0 | **0** | — |

   §11.11 showed every rate *change* mutes; F and F+ hold the value constant and mute just as
   reliably, with and without a position step. **It is the write, not the change.** The design's
   premise — that the only lever is the NUMBER of `setRate` calls — now has two independent proofs.

   ⚠️ **AND A CORRECTION TO WHAT WAS INFERRED FROM IT ON THE DAY.** It was claimed that this makes
   build step 6 urgent, because NDI re-anchors with `setRate(1.0, …)`. The NDI log says otherwise:
   **0 re-anchors in 40 s, 3 `setRate` rows all session.** At this machine's ~7 ppm against a 10 ms
   tolerance that is one re-anchor per ~21 minutes — about 3 mutes an hour. **Step 6 is right for
   correctness and is not urgent.**

2. ✅ **ANSWERED 2026-09-23 — YES TO BOTH, so no suspension is needed and §4.5 has been changed.**
   20 s `isMuted` window, no rate writes at all, clock sampled at 20 Hz with the read pair recorded:

   | segment | slope | vs mach | buffers/s |
   |---|---|---|---|
   | before | 1.000007300 | +7.3 ppm | 46.89 |
   | **muted** | 1.000006948 | **+6.9 ppm** | **46.86** |
   | after | 1.000006804 | +6.8 ppm | 46.93 |

   Slope change **−0.4 ppm**; media time continuous across the mute to **0.023 ms**;
   `isReadyForMoreMediaData` false on **0 of 1200** samples; renderer events **0**. `isMuted` does
   silence the output (20.00 s core, 960,135 samples at exact bit-zero) without affecting the clock
   or the queue. **The integrator runs straight through a mute.**

   📌 Incidental: this machine's device crystal reads **+6.8 to +7.3 ppm** against mach time, where
   the HLS work measured **−7.8 ppm** on another — opposite sign, same order. Second data point for
   `HLSAudioTap.swift`'s warning that this is a property of the output device, and it is inside
   §5.2's ±0.1% bound by a factor of 140.

3. **What A/V offset is acceptable for this tool?** §5.3 proposes ±15 ms p99 on the healthy paths
   and ±60 ms on Cloudflare. That is a product judgement about what a colourist will accept, not a
   measurement, and it sets `k_p`, the splice threshold and the pass/fail line for criterion 3. A
   tighter answer makes the loop faster and the ratio noisier; a looser one makes it gentler.

4. ✅ **ANSWERED 2026-09-23 — NO, IT IS NOT CORRECT. SRT desktop audio lags its picture by ~200 ms.**
   Full write-up `docs/AV_SYNC_FINDINGS.md` §3.1; BUGS.md entry opened the same day. Three
   independent lines agree:

   | line | local SRT | Cloudflare SRT |
   |---|---|---|
   | flash-and-beep, against a file-playback control | **+203.9 ms** | **+165.8 ms** |
   | arithmetic `cushion − (timebase−clock)`, each session's own log | **+246.2 ms** | **+246.0 ms** |
   | predicted from source | +250 ms | +250 ms |

   Measured figures read low by up to 33 ms of a known one-sided frame-grid bias plus the sender's
   own audio-vs-video encode delay. **No sender-side term is a fifth of a second.**

   **The fix is one argument** — `beginLiveAudio?(Self.targetDepth)` → `beginLiveAudio?(0)` at
   `SRTFrameRouter.swift:532`, plus rewriting the stale comment — and it is **safe on the axis that
   looks risky**: SRT's renderer currently holds ≈500 ms of queue, and removing the cushion leaves
   ≈250 ms, still well above the ~150 ms crackle threshold the NDI lead ladder measured.

   ✅ **APPLIED 2026-09-23 and verified.** After: arithmetic **−1.3 ms**; renderer lead
   **495 → 249 ms** (above the ~150 ms crackle floor); `setRate`/min **unchanged at 7.1**;
   2840/2841 buffers contiguous; 0 automatic flushes. Flash-and-beep read −122.2 ms raw, but a
   40 s `ffmpeg -c copy` probe measured **OBS itself sending audio 82.0 ms early**, leaving
   **Manifold within one video frame of zero**. Cloudflare SRT is fixed by construction (one
   argument, one shared call site, both routes +246 ms by arithmetic before) and was not
   re-measured. `docs/AV_SYNC_FINDINGS.md` §3.1.

   **NDI is still ~230 ms out**, so §2.5 remains the general rule this design owns; only SRT's
   instance of it has been closed.

   ⚠️ **AND THE WARNING IN THE ORIGINAL QUESTION WAS RIGHT, WHICH IS THE PART WORTH CARRYING.**
   `liveAudioDrift` returns `(timebase + cushion) − clock`, so the cushion cancels and the number
   reads clean whether the value is right or wrong. It measured **+3.40, +3.45, +3.80, +4.00 ms**
   across four sessions covering **three separate lip-sync defects**, one of them 99 ms. An
   instrument that subtracts a term cannot test that term.

   📌 **TWO DEFECTS WERE FOUND BY THE SAME MEASUREMENT AND NEITHER WAS PREDICTED:**
   - **NDI is +230 ms and working as designed.** `NDIService.swift:732` describes the cost
     correctly; `BUGS.md` shipped it as "monitoring latency", which it is not. Corrected in place.
     This is the direct evidence behind §2.5.
   - **WHEP's lip-sync is arbitrary per session** — −98.9 ms on one ingest, +36.7 ms on the next,
     while Chrome on that same ingest reads −10.5 ms. Cause: no RTCP sender-report handling exists,
     so the audio and video RTP bases are never mapped to a common clock. **Not the resampler's
     job**, and it is why criterion 12 reports WHEP rather than gating it.

5. **Is an audible splice acceptable at snap cadence?** §2.4 proposes a 5–10 ms cross-faded
   drop/insert for coarse events, against today's 78 ms mute. The alternative is to absorb a snap at
   the ±0.1% rail, which takes 200 s for a 200 ms snap and holds lip-sync badly the whole time.
   Video already jumps at a snap. Confirm that matching it in audio is wanted.

6. **Fix §11.8's Cloudflare depth inflation first, or ship the resampler against it?** The
   resampler makes the mute symptom vanish either way. But the +51/+135 ms depth excess then
   presents as an A/V offset wobble rather than as mutes, and §5.3 has to state a wider bound for
   that path. Fixing the depth signal first would let one bound cover every transport.

7. **Should the resampler's target lead be a new control, or inherit `cushion`?** NDI's presentation
   lead is 250 ms and is already runtime-adjustable by keystroke (`Debug ▸ Desktop Audio Lead`),
   with BUGS.md explicit that the true threshold is between 40 and 150 ms *on one machine and one
   interface*. The resampler adds 0.67 ms of constant group delay, which is nothing — but it is a
   natural moment to decide whether the lead is one concept or three.

8. **Scope: is the resampler allowed to do format rate conversion?** A near-unity ASRC and a
   44.1 → 48 kHz converter are the same code with a different ratio. Doing both would make
   `isSupportedForSDI`'s 48 kHz-only refusal — which today disables SDI audio entirely for a
   44.1 kHz source — unnecessary. That is a real feature, and it is also scope creep into a fix
   whose whole justification is a mute count. **Recommendation: build the component so it can, ship
   it so it does not**, and take the format question separately with its own measurement.

9. **Is there a second machine to measure the device-crystal δ on?** −7.8 ppm is one Mac with one
   Scarlett 18i20, and `HLSAudioTap.swift` is explicit that such figures are properties of the
   output device. The ±0.1% bound has enormous headroom over it, so this does not block anything —
   but a second reading would turn an assumption into a range.

---

## 9. Step 1 results — the ASRC, measured offline, 2026-09-24

**Built and measured, nothing wired in.** `Packages/ManifoldCore/Sources/AudioResample/` — a leaf
target with no dependencies — plus `Tests/AudioResampleTests`, run with `swift test -c release`.
Nothing in the app references it.

📌 **ITS OWN TARGET RATHER THAN A FILE IN `ManifoldCore`, FOR A LINKING REASON.** A test bundle
LINKS the targets it depends on, and `ManifoldCore` resolves libav symbols that `project.yml` links
into the app binary rather than the package. A test target depending on it cannot link here at all.
Depending on a leaf target is what makes `swift test` possible; it is the same shape as
`ScopeCompute`, and for the same reason it carries the same `-O`.

### 9.1 Results against targets

**Final parameters: N = 64 taps, P = 1024 branches, cutoff 0.5·fs, Kaiser β for a −100 dB
stopband.** Two of those differ from §3.6 as first written, and §9.3 / §9.4 are why.

| # | measurement | target | measured | |
|---|---|---|---|---|
| 1 | identity at ratio 1.0 | out[n] = in[n−32] to float rounding | **max error 0.000e+00** over 8160 frames, delay exactly 32 | ✅ |
| 2 | passband ripple to 20 kHz | ≤ ±0.02 dB | **0.0000 dB** worst over 20 Hz–20 kHz | ✅ |
| 3 | alias / image rejection | ≥ 95 dB | **103.6 dB** worst over ±0.1% and 1–20 kHz | ✅ |
| 4 | effective resolution, full-scale sweep | > 20 bits | **21.5 bits** (SNR 131.3 dB) | ✅ |
| 5 | **GATE** — ratio-change continuity | residual at the floor, no spikes at change points | **change-instant RMS / overall = 1.013**; per floor 1.012 and 1.041 | ✅ **PASSED** |
| 6 | accumulator exactness, 8.64e7 increments | integer index matches the exact rational | **exact, all four ratios** | ✅ |
| 7 | CPU, µs per output frame | (reported, no target) | 1 ch 0.013 · 2 ch 0.022 · 8 ch 0.155 · **16 ch 0.383** | — |

**Seven of seven.** `swift test -c release`, 7 tests, 0 failures.

### 9.2 The gate — passed, and what "at the arithmetic floor" turned out to mean

200 ratio writes, one every 10 ms, along a ±0.1% ramp with random steps, nulled against a reference
built by **direct windowed-sinc evaluation in Double** — no branch table, no inter-branch
interpolation, every coefficient recomputed at the exact fractional delay. A reference sharing the
table would only have proved the table is self-consistent.

```
residual vs direct-sinc reference : max 7.294e-07   RMS 1.426e-07   (131.0 dB below signal)
residual AT the 200 change points : max 5.690e-07   RMS 1.444e-07
change-instant RMS / overall RMS  : 1.013
```

**A ratio write is not merely small in its effect; it is not detectable at all.** The single worst
residual in the run is **not** at a change point, and the change-instant RMS matches the whole-run
RMS to 1.3%.

⚠️ **AND 1.013 IS NOT "SLIGHTLY WORSE THAN 1.000" — IT IS 1.000 AT THIS SAMPLE COUNT.** The
change-instant figure is an RMS over 200 × 5 = 1000 samples against 95,000 for the whole run, and
an RMS estimated from *n* samples carries a relative spread of about 1/√(2n) — **2.2% here**. So
1.013 is 0.6σ and the per-floor 1.041 is 1.8σ. At P = 512 the same three numbers came out at 0.948,
0.951 and 0.983, i.e. the same distance *below* 1.0. **Reading either sign of that scatter as a
result would be reading the noise**, which is why the threshold is 1.15 and not 1.00.

§3.6's claim that continuity is a property of the structure rather than a result to re-verify is
now measured as well as argued.

⚠️ **BUT THE GATE'S WORDING HAS TWO CLAUSES AND ONLY ONE OF THEM IS ACHIEVABLE AGAINST THAT
REFERENCE.** "The residual must sit at the arithmetic floor" cannot be met by *any* polyphase
implementation compared against direct evaluation, because the two differ by the branch
interpolation error at **every** sample, change or no change. Decomposing the residual by running
the same table and the same branch arithmetic in Double separates them:

| floor | max | RMS | below signal |
|---|---|---|---|
| branch quantisation + linear inter-branch interpolation | 7.196e-07 | 1.383e-07 | 131.3 dB |
| Float arithmetic (64-tap dot product) | 2.017e-07 | 3.473e-08 | 143.3 dB |

So the total residual sits **12 dB above** the arithmetic floor, and it is the static interpolation
floor — present uniformly, not produced by ratio changes. The clause that actually tests continuity
was therefore applied to **each floor separately**, and neither is disturbed: change-instant /
overall is **1.012** on the interpolation floor and **1.041** on the arithmetic floor, both inside
the 2.2% sampling spread above.

📌 **THE GAP NARROWED FROM 24 dB TO 12 dB WHEN P DOUBLED, WHICH IS THE POINT OF §9.3.** The Float
arithmetic floor did not move — 143.3 dB before and after, as it must, since the dot product is
unchanged. Only the interpolation floor moved, by the 12 dB the 1/P² law predicts. Two independent
measurements of the same step.

📌 **RECORDED BECAUSE THE WORDING WILL BE READ AGAIN.** "Null against a reference and demand the
arithmetic floor" is the right instinct and the wrong bound when the reference is a *different
algorithm*. The bound that means something is "indistinguishable at a change point", per floor.

### 9.3 ✅ Target 4 — resolved by P = 1024, after a measured miss at 512

**The design's P = 512 missed the > 20-bit target at 19.6 bits.** It was reported as a miss rather
than tuned around, characterised, and then fixed by a decision — which is the order that matters.

The floor is the branch interpolation measured in §9.2, and it is a pure function of the branch
count: linear interpolation between branches has an error falling as 1/P², i.e. **12 dB per
doubling**. Measured rather than assumed, on the same full-scale sweep:

| P | SNR | effective bits | table size | |
|---|---|---|---|---|
| 512 (§3.6 as first written) | 119.5 dB | **19.6** | 128 KB | ❌ misses > 20 bits |
| **1024 (adopted)** | **131.3 dB** | **21.5** | 256 KB | ✅ |
| 2048 | 140.7 dB | 23.1 | 512 KB | — |

512 → 1024 gains 11.8 dB, which is the 1/P² law to within the measurement. 1024 → 2048 gains only
9.4 dB because it is starting to run into the 143 dB Float-arithmetic floor from §9.2 — so **P =
2048 is roughly the point past which more branches stop buying bits in a Float pipeline**, and that
is worth knowing before anyone reaches for it.

**What §3.6 got wrong.** It justified > 20 bits with *"512 branches + inter-branch interpolation
puts the interpolation error floor well below the 64-tap stopband"*. The stopband is not the binding
constraint; the inter-branch interpolation is, and it is 12 dB per doubling of P regardless of how
good the prototype is. Corrected in place.

**What P = 1024 costs.** Nothing per frame: the branch index is a shift of the phase accumulator,
not a search, and the coefficient build is still one `vDSP_vsma` over 64 taps. Measured CPU is
unchanged within run-to-run scatter (16 ch: 0.385 µs/frame at P = 512, 0.383 at P = 1024). What
doubles is the table — **256 KB plus a 256 KB difference table**, against 128 + 128 KB. Both are
built once at construction and are read-only thereafter.

📌 **The option deliberately NOT taken: cubic inter-branch interpolation**, whose error falls as
1/P⁴. It would reach the same place with a smaller table and triple the per-frame coefficient build.
Against a 512 KB table on a machine with tens of gigabytes, that is the wrong trade — but it is the
right answer if this component is ever asked to run somewhere small.

### 9.4 Two corrections to §3.6, both forced by measurement

**The cutoff is 0.5, not 0.45.** §3.6 specifies *"cutoff at 0.45·fs (21.6 kHz)"*, carried over from
general rate conversion where the filter must also suppress what decimation would fold. **This
resampler never decimates** — §5.2 bounds the ratio at ±500 ppm — so it is a fractional-delay
interpolator and the cutoff belongs at Nyquist. At 0.45, two targets are unreachable for one
arithmetic reason: a Kaiser design of length N has transition width Δf ≈ (A − 8)/(2.285·2π·N), which
at N = 64 and A = 100 dB is 0.100 cycles/sample = **4.8 kHz**. Centred on 21.6 kHz that puts the
passband edge at **19.2 kHz**, so 20 kHz sits inside the transition band. Both measured:

| | cutoff 0.50 | cutoff 0.45 |
|---|---|---|
| identity at ratio 1.0 | **0.000e+00** | **5.6e-01** — branch 0 is a lowpass, not an impulse |
| passband ripple at 20 kHz | **0.0000 dB** | **0.1126 dB** |

The identity property is the decisive one and it is structural: `sinc(n)` is zero at every non-zero
integer **only** when the cutoff is exactly Nyquist, which is what makes branch 0 an exact unit
impulse. At 0.45 there is no ratio at which this resampler is a pass-through.

**CPU is 1.84% of a core at 16 channels, not "under 1%".** §3.6 estimates 107 Mflop/s and calls it
*"under 1% of one performance core"*. Measured **0.383 µs/frame at 16 channels = 1.84%**
(1 ch 0.013 · 2 ch 0.022 · 8 ch 0.155 µs). The
estimate counted flops and not the per-channel pointer and call overhead in the inner loop, which is
what the 2 ch → 8 ch step (0.022 → 0.155 µs, 7.0× for 4× the channels) is showing. It is still
comfortably affordable and it is not the figure the design claims. A single deinterleaved scratch
block with one `withUnsafeBufferPointer` outside the frame loop would recover most of it; that is
step-3 work and is not done here.

### 9.5 One real defect, found by a test that nearly wasn't written

The streaming path retained a tail **shorter than `taps`** (the loop stops at the first `idx` with
`idx + taps > scratchCount`, so the leftover is always `< taps`), while `process` computed
`scratchCount = taps + inCount` from the constant. The claimed buffer was therefore one frame longer
than the real one, the loop ran one extra iteration per call, and its `vDSP_dotpr` **read one
element past the end of the array through an unsafe pointer**.

It did not crash — the overrun lands in allocation slack — and the extra output frame was
numerically plausible. It was caught only by the streaming-vs-one-shot equivalence check, which
compared **frame counts as well as samples**: 8202 frames against 8192, with every compared sample
matching to 0.000e+00. A test that compared only the overlap would have passed it, and the bug would
have shipped into step 3 as an occasional one-frame surplus.

📌 **The transferable part: when a test compares two runs, compare their LENGTHS first.** Every
sample agreeing is not the same as the two runs agreeing.

### 9.6 What step 1 does NOT establish

* **Nothing has been heard.** §6's "NOT EARS" rule applies in both directions: these are offline
  numbers against synthesised material, and they say nothing about the renderer, the tap, the
  meters or the SDI path.
* **The ratio has only ever been driven by a test.** Step 4's control loop is untouched.
* **No real programme material.** Sweeps and noise, not decoded Opus or AAC.
* **16 channels is a CPU figure, not a correctness one.** Channel handling at 16 has been timed,
  not audited against a real layout.

---

## 10. Step 2 results — the paired error and the real ppm, measured 2026-09-24

**Instrument built, four transports traced, nothing audible changed.**
`Packages/ManifoldCore/Sources/ManifoldCore/LiveAudioPairedProbe.swift`, called from
`LiveAudioSink.enqueue` — the one seam SRT, WHEP and NDI already share, so all three are
instrumented by one call rather than three copies that could drift apart. Behind
`DEBUG || MANIFOLD_TELEMETRY`, created only when `LiveClock.telemetryIsEnabled`.

**10 minutes per transport, not 30.** The 30-minute soaks stay in step 8 as the acceptance test;
what step 2 needs is the ppm range and whether there is a trend, and §10.4 shows 10 minutes settled
that on every transport — including NDI, which was the one expected to need a longer lever arm.

### 10.1 What each transport measures — and they are NOT the same quantity

| | reference line | what `err`'s slope is |
|---|---|---|
| SRT, WHEP | `(senderPTS − cushion, hostTime, rate)`, refreshed at 10 Hz | a **sawtooth**: accumulates between rate pushes, reset by them. Its slope is the instantaneous mismatch, not a clock ratio. |
| NDI | `(mediaTime, hostTime, 1.0)`, set once and left | the **audio device crystal against mach**, accumulating freely |

Do not pool them. The code says so at both push sites.

### 10.2 Steady state — t ≥ 200 s, which is >5τ past the EMA seed

| | smoothed ppm min/med/max | err median ms | err p99 max | trend ppm/min |
|---|---|---|---|---|
| **SRT local** | −1776 / **+60** / +144 | −3.4 / −0.0 / +7.8 | +11.0 | +24.1 ± 33.9 (0.7σ) |
| **WHEP MediaMTX** | −137 / **+106** / +226 | −2.8 / +0.2 / +8.1 | +10.7 | +6.9 ± 4.7 (1.5σ) |
| **WHEP Cloudflare** | −155 / **−81** / −9 | −8.1 / −4.4 / −0.1 | +1.7 | −1.3 ± 2.1 (0.6σ) |
| **NDI** | n/a — no mapping | accumulates +0.03 → +4.11 ms | — | **+6.680 ± 0.003 ppm** |

**Steady-state smoothed rate is inside ±250 ppm on all three mirrored transports**, which vindicates
§5.2's "absorb ±500 ppm steady state" — for steady state. The SRT −1776 ppm is one excursion (§10.3),
not the distribution.

📌 **CLOUDFLARE IS THE TIGHTEST OF THE THREE, WHICH IS NOT WHAT ANYONE WOULD HAVE GUESSED.** Its
p99 never leaves +1.7 ms and its error envelope is half the other two's, on the longest path in the
set. Worth remembering the next time a figure is attributed to "the CDN" without measurement.

**The pairing gate discarded 3.90–4.06% on the mirrored transports and 0.021% on NDI** — 57,585
samples with 12 discards. NDI's pump thread is simply not preempted the way the network transports'
threads are. The gate is doing real work and its cost is known.

### 10.3 TWO regimes take the smoothed rate outside `B`, for two different reasons

`B = 0.001` is ±1000 ppm. Both of these exceeded it, on the two quietest links available — one
loopback, one localhost.

**1. Connect-time rail — +3834 ppm (MediaMTX), +3775 ppm (Cloudflare), decaying with τ ≈ 32 s.**

```
+10s +3377   +40s +2184   +70s  +809   +100s +372
+20s +3834   +50s +1613   +80s  +580   +110s +287
+30s +3033   +60s +1149   +90s  +523   +120s +226   ← settled
```

⚠️ **THIS WAS FIRST ATTRIBUTED TO THE SEED, AND THAT ATTRIBUTION IS RETRACTED — §10.8.** The
first pass read window 1's `inst +5000.0` as the first mapping landing on the rail and blamed
`mirror.smoothedRate = m.rate`. But `inst` is the clock's rate at the END of the 10 s window, not
at the first mapping. On a fresh connection the first mapping is always exactly 1.0 (`registerFrame`
anchors at `rate`, which is 1.0 on a constructed or `reset()` clock), so the old seed already WAS
1.0. Measured on 6 of 6 connects. What actually happens: **the P-loop rails within the first
~0.1–2 s, following the connect burst, and the fast end of the τ ramp (τ = 2 s at t = 0) follows the
rail by design** — the ramp note in `FrameEngine.swift` exists precisely so the mirror tracks the
startup rail rather than accruing 4 ms/s of position error. The peak is set by how long the rail
lasts (6 connects: 1331–3972 ppm, both signs), not by the seed. The "SRT seeded near unity (+164
ppm)" remark rests on the same window-1 misreading and is withdrawn with it.

**2. Jitter recovery — −1776 ppm (SRT, t ≈ 380 s).** A one-second arrival deficit
(`[SRT-JITTER] window arrivals min=22 max=25` against 23.98) drained the depth 0.233 → 0.156 s
against its 0.250 target. LiveClock pinned the rate at **0.9950 — `maxSlew`, the −5000 ppm rail —
for 16 seconds continuously**, and the τ=30 s filter dragged `smoothedRate` to −1776 ppm, recovering
over ~60 s. `underruns=0`, no content lost, nothing audible.

⚠️ **THIS IS THE ONE THAT MATTERS, BECAUSE IT IS NOT A STARTUP ARTEFACT AND CANNOT BE DESIGNED
AWAY.** The rail is legitimate control action against a real buffer excursion. §5.2 says the rail
must not be absorbed and "reaches the ratio only through the τ=30 s feed-forward, attenuated exactly
as today" — but attenuated is not eliminated: 16 seconds of rail is 1.8× outside `B`.

### 10.4 The trend question, and a retraction

**No transport shows a resolved trend.** 10 minutes was sufficient everywhere, including NDI.

⚠️ **THE FIRST PASS REPORTED CLOUDFLARE AT −14.27 ± 2.87 ppm/min, 5.0σ, "RESOLVED". THAT WAS AN
ARTEFACT OF MY OWN WINDOW SELECTION AND IT IS RETRACTED.** Steady state had been selected by VALUE
(`|smoothed| ≤ 300 ppm`) rather than by TIME, so the tail of the τ≈32 s startup decay — which
crosses 300 ppm at ~90 s and keeps falling — was inside the "steady" set and looked exactly like a
drift. Excluding by time instead:

| from | ppm/min | σ |
|---|---|---|
| 0 s | −14.27 ± 2.87 | **5.0** |
| 150 s | −4.21 ± 1.84 | 2.3 |
| 200 s | −1.32 ± 2.08 | 0.6 |
| 300 s | +1.74 ± 2.87 | 0.6 |

It evaporates monotonically, which a real trend does not. **The transferable rule: a settling
transient selected on its own value is indistinguishable from a trend. Exclude on time, and state
the time.** Same failure shape as §9.2's change-instant scatter, one section apart.

📌 **NDI's "trend" IS the measurement, and 10 minutes resolved it at 2326σ.** The accumulated error
ran +0.029 → +4.105 ms over 609 s in a line with **4 µs of residual scatter**:
**+6.680 ± 0.003 ppm**. An independent estimate from the per-window slopes gives **+6.80 ppm**
(sd 0.61, median r² 0.829), and `AV_SYNC_FINDINGS.md` §5.2 measured this machine at **+6.8 to
+7.3 ppm**. Three methods, one answer. §5.1's row for the device crystal is no longer a figure
borrowed from another investigation.

**NDI re-anchored once in ten minutes** (0.10/min), exactly the ~1-per-21-minutes that
`AV_SYNC_FINDINGS.md` predicted from 7 ppm against a 10 ms tolerance.

### 10.5 What this says about `B` and `k_p` in §2.2

**`k_p` — propose 0.05 s⁻¹, derived rather than chosen.** Steady-state position error to be nulled
is **≤ 11 ms p99 on every mirrored transport** (§5.3's bound is ±15 ms, so the existing mirror is
already inside its own target). `k_p` has units of 1/time: a 10 ms error closed over T seconds needs
a ratio offset of `0.010/T`. At T = 20 s that is **500 ppm of ratio authority, half of `B`**, and
`k_p = 1/T = 0.05`. The §2.2 slew limit (2 ppm per 10 ms = 200 ppm/s) reaches 500 ppm in 2.5 s, so
it does not bind. `k_p = 0.1` (T = 10 s) is the aggressive end and still fits.

**`B` — 0.001 is right for steady state and is NOT enough for the transients. Two options, and they
are not alternatives:**

1. ~~✅ **Fix the seed, first and regardless.**~~ **Tried, measured to change nothing on the
   connect path, and reverted — §10.8.** The old seed already was 1.0 on every fresh connection, so the +3834 ppm excursion is untouched. **It is the τ ramp following a real
   connect-time rail, and it is a `B` question like item 2, not a defect:** 6 connects put the
   startup peak at **1331–3972 ppm**, 4.0× `B = 0.001` at worst and still 2.0× the proposed
   `B = 0.002`. Options, none taken here: let the ratio saturate at `B` during the first ~2 min and
   leave the residual to position error; or feed the resampler from the τ = 30 s filter only after
   the ramp; or size `B` for it (0.004). Choosing among them belongs to step 3/4.
2. ⚠️ **`B` has to cover jitter recovery, and 0.001 does not.** Measured −1776 ppm from an
   ordinary 16 s rail on a loopback link. **Proposal: `B = 0.002`** — 1.1× the worst measured
   excursion, and in pitch terms ±3.5 cents against ±1.7 at 0.001. Both are inaudible on programme.

⚠️ **AND §6.3 CRITERION 7 HAS TO MOVE WITH IT, OR BE RESTATED.** It requires "ratio within ±0.1%",
which is `B = 0.001` by another name. Steady state measures **±250 ppm = ±0.025%**, comfortably
inside — so the criterion should be rewritten to bound the **steady state** at ±0.1% and allow the
transient to reach `B`, rather than bounding an instantaneous value the loop is deliberately allowed
to swing during a recovery. Bounding the instantaneous ratio at 0.1% and setting `B` at 0.2% would
be a criterion the design is built to violate.

### 10.6 Nothing audible changed

`setRate`/min, the only in-app proxy (mutes are not measurable from inside the process — §4, and
§5.2 measured a muted renderer advancing its timebase and consuming buffers normally):
**2.37/min local SRT · 3.82 MediaMTX · 3.38 Cloudflare**, against §11.4's 4.3/min baseline for local
SRT at 23.976. Lower, not higher, and the spread between transports is larger than any effect a
read-only probe could have. **Stated no more strongly than that**: the real argument is structural —
the probe takes only its own lock, reads two clocks, and returns — and this measurement is
consistent with it rather than proof of it. The mute count itself comes from the device capture in
§10.7.

⚠️ **ONE INSTRUMENT DEFECT WAS FOUND AND FIXED BEFORE ANY RUN.** The first version called `NSLog`,
and ran a sort and a least-squares fit, **on the enqueue thread**. `LiveAudioRendererProbe` already
states the rule — *"an `NSLog` there is a syscall on the exact path whose timing is under
investigation"* — and hops to `qos: .utility` for exactly this reason. An instrument that perturbs
its own measurement is the failure this whole line of work exists to avoid. The critical section is
now two array copies; everything else is off-thread.

### 10.7 Still outstanding from step 2

* **The NDI mute baseline (§6.2) is NOT measured.** It needs a device-output capture through Audio
  Hijack with the §11.9 offset-track harness and all three §6.1 preconditions, against the broadband
  reference — **not** the flash-beep fixture, because a tone detector cannot see a splice (phase is
  modulo one period, §11.9 item 1). Until it exists, §6.2's NDI row stays empty and step 6 has no
  before-figure to be judged against.
* **One session per transport.** Two of the four excursions here were single events; §10.3's
  jitter-recovery figure in particular is n=1 and its 1.8×-outside-`B` conclusion rests on it.

### 10.8 The seed fix — measured before and after, 2026-09-24

**Change tested, then REVERTED the same day because it fixed no measured problem:**
`mirrorLiveAudio`'s first-mapping branch seeded `smoothedRate = 1.0` instead of `= m.rate`. The
code is back to `= m.rate`; this section is the record. **Why 1.0 rather than a short average excluding railed samples:** it is the value the
τ-ramp note was written around; every measured steady state is within ±250 ppm of it, so its worst
error is 20× smaller than a railed sample's; and it adds no state and no threshold. A rail-excluding
average would need both, and — as the result shows — would have had nothing to exclude, because
the first sample is not railed.

**Method:** WHEP via MediaMTX (OBS → WHIP → MediaMTX → WHEP), Profile build, telemetry on, one app
launch per build, 3 connects each, 190 s per connect timed from the first mapping, ~15 s between.
Session origin is the first `[WHEP-AUDIO] mirror` line (it fires on the first mapping); setRate
times are the renderer probe's own host stamps. **Settle** = the first 10 s paired-probe window
whose whole `smoothed` range sits inside ±250 ppm; the crossing lies in the window before, so each
figure is a 10 s bracket.

| | seed (`clockRate` at 1st mapping) | peak \|smoothed\| ≤ 100 s | settled inside ±250 ppm | setRate ≤ 120 s |
|---|---|---|---|---|
| before 1 | 1.00000 | **+3885** ppm | (130, 140] s | 35 |
| before 2 | 1.00000 | **−1331** ppm | (40, 50] s | 16 |
| before 3 | 1.00000 | **−1935** ppm | (60, 70] s | 18 |
| after 1 | 1.00000 | **+3972** ppm | (150, 160] s | 36 |
| after 2 | 1.00000 | **+2552** ppm | (70, 80] s | 23 |
| after 3 | 1.00000 | **+2073** ppm | (90, 100] s | 17 |

📌 **THE CHANGE IS BIT-IDENTICAL ON THIS PATH, SO THE SPREAD ABOVE IS SESSION-TO-SESSION, NOT
BEFORE-VERSUS-AFTER.** With `m.rate == 1.0` at the first mapping, both versions store 1.0. The after
column is higher only because its three connects railed positive and longer; the before set had
two negative ones. The first-30 s push traces show the mechanism directly: the first push is at
+0 ppm on all six, then pushes step out by ~200–250 ppm each, 0.1 s apart at first, as the τ = 2 s
end of the ramp follows a rail that is already on.

**What it would have done:** removed a latent hazard on any path where the mirror begins against
a clock that is already running — `beginLiveAudio` after the clock has anchored and moved. Not
observed on WHEP. **Not measured on SRT or on an audio-only restart**; whether those paths exist is
unverified.

**One real steady-state number from this run:** after the decay, `smoothed` stayed within
±250 ppm on 5 of 6 connects out to 185 s (worst 249); after-1 touched +268 ppm at ~180 s. Consistent with §10.2.

### 10.9 Why LiveClock rails at connect — the startup anchor, not the gain (2026-09-24)

**Read-only analysis of the six §10.8 WHEP/MediaMTX sessions and `step2-srt-local.log`.** The
excursion §10.8 left open is the P-loop railing within ~0.1 s of the first mapping. Every rail traces
to an offset CREATED AT THE ANCHOR, which the loop can then only remove by rate.

**Depth at the first control tick, and ~1 s later** (target 0.400 s WHEP, 0.250 s SRT; the first
`[LIVECLOCK]` line is the first `updateDepth` call after the anchor):

| session | decoder setup before the anchor frame | first tick | ~1 s later | mirror peak |
|---|---|---|---|---|
| WHEP before-1 (cold) | **104 ms** | −0.6 ms, 1 frame | **+103 ms, 13 frames** | +3885 ppm |
| WHEP after-1 (cold) | **101 ms** | +37 ms, 2 frames | **+135 ms, 13 frames** | +3972 ppm |
| WHEP 2 & 3, both builds (warm) | 2–6 ms | −5.2…−5.6 ms, 1 frame | −12…+10 ms, 9–10 frames | ±1331…2552 ppm |
| SRT local (cold) | 87 ms | +17.8 ms, 6 frames | −6.0 ms | −290 ppm |

"Decoder setup" = `format description built` → `session created` / `keyframe acquired`. "Cold" = the
first connect after app launch.

**Three mechanisms, in order of size:**

1. **Arrival burst behind a late anchor frame — the large excursions.** `registerFrame` anchors on
   the keyframe's arrival. On the first connect after launch, creating the hardware decode session
   takes ~100 ms; frames received meanwhile queue behind the keyframe and are delivered in a burst
   straight after it. The anchor is pinned to the one late frame, so depth lands at target + the
   setup time: **+103/+135 ms against 104/101 ms of setup.** Warm (2–6 ms of setup) there is no
   burst. At `maxSlew` the loop drains 5 ms/s, so this is 20–27 s on the rail, then the τ = 30 s
   decay: +3900 ppm peak, 130–160 s to settle, 35–36 setRates in 2 min.
2. ~~**Anchor phase — every connect.**~~ ⚠️ **RETRACTED BY §10.10's MEASUREMENT.** This claimed the
   anchor pins depth at the top of the per-frame sawtooth, starting every connect up to half a frame
   low. Two things were wrong with it. The renderer already adds Δ/2 to the depth span
   (`MetalVideoRenderer.swift`, "STRUCTURAL-OFFSET CORRECTION") once the frame interval is seeded, so
   there is no persistent half-frame bias. And the instrumented before-build shows warm connects
   were ALREADY at target when the picture started (−1.9 and −0.1 ms): the small warm offset is
   slewed out inside the 0.4 s fill. **The warm-connect excursions happen AFTER presentation** —
   see item 3 and §10.10.
3. **Gain — why it is ALWAYS the rail, and on warm connects the whole story.** k = 0.8 rails at 6.25 ms of error
   (§11.6), smaller than either offset. But removing an offset D by rate needs ∫(rate − 1) dt = D
   whatever k is: a lower k trades height for duration with the same area and a longer settle.
   Retuning the loop moves the excursion; it does not remove it. **On warm connects there is no
   anchor offset left to remove** (item 2): the ±800–1400 ppm comes from the relay running
   one-sided for 1–3 s on the 5–17 ms of post-presentation sawtooth error, which the mirror's
   τ ramp (τ = 2 s at the start) then follows almost in full.

**SRT has the same mechanisms at smaller scale:** +18 ms with 6 frames already queued at the first
tick, self-cancelling within ~1 s, so the relay ran two-sided and the mirror peaked at −290 ppm with
4 setRates in 2 min. n = 1.

**Steady state is quiet on every WHEP run** — 0–1 setRate in 120–180 s — so nearly all of the 16–36
setRates in the first 2 minutes are this startup offset being removed by rate.

**The fix at the cause — correct the offset by POSITION during the startup fill.** Until the first
frame is presented (`!hasPresentedOnce`, with queue edges present), nothing is on screen and the
audio is waiting on the same anchor, so the clock can be re-anchored in EITHER direction invisibly.
The snap's arithmetic (`setMappingLocked(mappedNow + (depth − target), t, 1.0)`), both signs, gated
to the fill window; the slew is untouched from the first presentation on. The synthetic harness
passes no queue edges and stays inert. Predicted: the connect blips go, connect setRates fall to about
steady-state plus the fill-window position pushes, and `B` no longer has to cover connect. **Stated
risk:** a burst that lands AFTER the first presentation would still be drained by rate. **Measured
in §10.10: true for COLD connects only.** Warm connects are unchanged, for the reason item 2's
retraction gives.

📌 **Aside, stats only:** `mirror.ticks` was not reset in `beginLiveAudio`, so reconnects printed
"533 / 599 / 998 heartbeat tick(s)" on their first mapping line.

### 10.10 The startup-fill realign — measured, 2026-09-24

**Change:** `LiveClock.updateDepthLocked` — while `!hasPresentedOnce` and queue edges are present,
the depth offset is removed by re-anchoring position at rate 1.0 (either sign, at `controlHz`,
≥ 1 ms), instead of by slewing. It is reported as a new `Event.startupRealign`, so the surplus
ledger's `recordClockJump` sees it, and both routers log it. The slew is untouched after the first
presentation. The synthetic harness passes no edges, so it is inert there. **Also:** `mirror.ticks`
is now reset in `beginLiveAudio` (a stats fix). **Instrument (both builds):** two `[LIVECLOCK]
startup:` lines per stream, giving depth at first presentation and the arrival lead of every frame
against the first frame's arrival schedule, before and for 2 s after presentation.

**Protocol:** as §10.8 — Profile, telemetry on, 190 s per connect from the first mapping. Per build:
a fresh launch, then 1 cold connect (the first decoder session in the process) and warm reconnects.
The before build is the same tree minus the fix (instrument and ticks fix included). "Settled" uses
10 s brackets.

| run | decoder setup | realigns (net) | err at 1st presentation | setRate ≤ 120 s | mirror peak ≤ 100 s | settled ±250 ppm |
|---|---|---|---|---|---|---|
| MediaMTX before, cold | 87 ms | — | **+88.7 ms** | **34** | **+3734** | (130, 140] s |
| MediaMTX before, warm | 4 ms | — | −1.9 ms | 8 | −760 | (30, 40] s |
| MediaMTX before, warm | 5 ms | — | −0.1 ms | 5 | +234 | (0, 10] s |
| MediaMTX **after**, cold | 83 ms | 4 (+84.3 ms) | **−1.1 ms** | **9** | **+356** | **(10, 20] s** |
| MediaMTX after, warm | 6 ms | 4 (+8.8 ms) | −0.5 ms | 9 | +790 | (70, 80] s |
| MediaMTX after, warm | 3 ms | 4 (+32.5 ms) | −1.3 ms | 14 | −1377 | (50, 60] s |
| SRT local after, cold | 82 ms | **0** | +17.2 ms | 5 | +449 | (20, 30] s |
| SRT local after, warm | 4 ms | **0** | +15.1 ms | 10 | −1098 | (60, 70] s |
| Cloudflare after, cold | 99 ms | 3 (+96.1 ms) | +8.2 ms | 21 | +2133 | (70, 80] s |
| Cloudflare after, warm | 6 ms | 3 (+19.4 ms) | +2.0 ms | 6 | +549 | (30, 40] s |

The setRate count includes the fill-window position pushes: 2–5 in the first 0.5 s on every run.

✅ **COLD CONNECT, WHICH WAS THE DOMINANT CASE, IS FIXED.** On MediaMTX the first-presentation error
drops from +88.7 to −1.1 ms, setRates from 34 to 9, the peak from +3734 to +356 ppm, and settle from
~135 s to ~15 s. The cold decoder's ~100 ms burst was fully present before the picture started on
all three WHEP cold runs (the pre-presentation arrival lead was +98.9 / +118.9 ms), and the realign
absorbed it: +98.0 ms on MediaMTX, +78.7 + 19.6 ms on Cloudflare.

✅ **THE STATED RISK DID NOT MATERIALISE.** No burst frame arrived after the first presentation on any
run. Arrival-lead growth over the 2 s after presentation was +1.9 / −0.3 / +2.8 ms (MediaMTX after),
+3.4 / +1.8 ms (Cloudflare) and +11–15 ms (MediaMTX before, SRT). The before build's warm runs, which
had no burst at all, set the jitter floor at +11–12 ms, and every figure is well under one frame
interval.

⚠️ **WARM CONNECTS ARE NOT IMPROVED, AND COULD NOT HAVE BEEN.** The before build's warm connects were
already at target at presentation (−1.9 / −0.1 ms). Their excursions — and the after build's, of the
same size (+790, −1377, +549 ppm; 6–14 setRates) — come from the relay after presentation (§10.9
item 3). n = 2 per build is too few to call the after-build's warm spread worse than the before's;
the mechanism is identical.

⚠️ **CLOUDFLARE COLD STILL REACHED +2133 ppm.** The realign removed 96 ms, but the picture came due
between two 10 Hz ticks with +8.2 ms still outstanding. The relay then rode the + rail for ~2 s
(pushes 1.1–3.1 s), and the τ = 2 s end of the mirror's ramp followed it to +2050 ppm. That is the
warm-connect mechanism, starting from a slightly larger residual.

**SRT: INERT BY CONSTRUCTION.** SRT's own startup anchor (`SRTFrameRouter`, "startup anchor: GAP")
anchors on the first network-bound frame with the decode backlog already queued, and backlog frames
are immediately eligible. The first presentation is 4–6 ms after the anchor, so the fill window closes
on the first tick and there were 0 realigns on both runs. SRT's +15–17 ms offset is still slewed as
before. On the warm SRT run you reported "maybe a small glitch at connect, could have been where I
came in"; there was no realign on that run, and the only startup action was SRT's existing backlog
discard (77 frames), the same as on the cold run.

**Picture and audio start: normal on every after-build run, by eye and ear** — MediaMTX cold and
warm, SRT cold, Cloudflare cold (with the SRT warm caveat above). No snap, freeze-guard or queue-full
event on any run.

**What this does to `B`.** The cold-decoder excursion (+3700–4000 ppm) is gone. The connect transient
that remains is the relay after presentation, followed through the fast start of the τ ramp:
**up to 2133 ppm (Cloudflare cold), 1377 (MediaMTX warm), 1098 (SRT warm)**. That is 1.07× the
proposed B = 0.002 at worst, so B = 0.002 still does not cover the connect transient on its own. The
next cause at the source is the relay (§11.6: a 6.25 ms linear range inside a ±20 ms sawtooth) or
the mirror's τ = 2 s start, not the anchor.

## 11. Step 3 results — the resampler in the path at ratio 1.0, measured 2026-09-25

⚠️ **Unqualified §11.x references elsewhere in this document mean `LIVECLOCK_AUDIO_MIRROR_FINDINGS.md`
§11, as the header says, and they still do.** This section refers to its own subsections without the
§ sign ("11.3 below"), so neither can be read as the other.

**Built:** `LiveAudioResampleStage` (`Packages/ManifoldCore/Sources/LiveAudioResample/`, its own leaf
target so a test bundle can link it), inserted in `LiveAudioSink.enqueue` between the tap and the
renderer. Ratio pinned at exactly 1.0; the resampler's 32-frame delay compensated so input sample
k lands on output tick k; input holes and overlaps up to 1 s bridged with silence or dropped, larger
jumps treated as an axis break; one stage per session, retired at `endLiveAudio`. The mirror calls
`setRate(1.0, time:atHostTime:)` once at the first anchor, the rate branch is off, and the position
branch stays at 10 ms. `smoothedRate` is still computed and logged. NDI's `anchorLiveAudio` is
unchanged. `swift test`: 12 of 12.

**Protocol:** the Profile build, unsigned (`.build-cc/step3-Profile`), telemetry on, a fresh launch
per transport, the flash-beep fixture. Each run: connect, 3 min, disconnect, reconnect, 60 s, quit,
timed from the first-mapping row. OBS on this Mac for every sender. Logs:
`~/Desktop/step3-{srt,whep-mediamtx,whep-cloudflare,ndi}.log`, and after the WHEP fix (11.3 below)
`~/Desktop/step3-whepfix-{mediamtx,cloudflare}.log`.

### 11.1 Results against step 3's measured list

| | SRT local | WHEP MediaMTX | WHEP Cloudflare | NDI (DistroAV "OBS PGM") |
|---|---|---|---|---|
| Heard and seen | smooth, no distortion | normal | clean | fine |
| First anchor per connect | 1 + 1 | 1 + 1 | 1 + 1 | 1 + 1 (`anchorLiveAudio`) |
| Position writes, first 3 s | 0 | 3 + 0 | 3 + 1 | — |
| Position writes, steady state | **0** | **1 at +123 s; 1 at +74 s** | **0** | **0 re-anchors** |
| Clamps / passthrough / build failures | **0 / 0 / 0** | **0 / 0 / 0** | **0 / 0 / 0** | **0 / 0 / 0** |
| Format resets / axis breaks | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| Real input holes / overlaps | 0 | one 2.5 ms startup hole per session | the same | 0 |
| One-frame holes / overlaps | 0 | **943 pairs** (11.3) | **878 pairs** (11.3) | 0 |
| Renderer gap histogram, contiguous | 11 954 | 13 355 | 12 728 | 23 875 |
| Renderer holes / overlaps / cumulative gap | 0 / 0 / +0.000 ms | the same | the same | the same |

✅ **The output axis is exact.** 61 912 buffers reached the renderer across eight sessions with no
hole and no overlap, and the cumulative gap stayed at +0.000 ms throughout. Clamps were zero on every
window; a non-zero clamp at ratio 1.0 would mean a plumbing defect.

✅ **Mutes per minute dropped to the position branch's rate alone,** as the plan required. Step 2
measured 2.37 / 3.82 / 3.38 `setRate` a minute on SRT / MediaMTX / Cloudflare (§10.6). In steady
state here it was 0 / ~0.5 / 0, and each write was at 1.0.

**The 2.5 ms (120-frame) hole** is at the start of every WHEP session and nowhere else. It is most
likely the first Opus packet decoding short (pre-skip). The stage fills it with silence, so every
later sample stays at its original time.

**Measured separately:** mutes by device capture are in 11.5 below. The SDI counters were checked
over HDMI to the ATEM on SRT and MediaMTX. Step 3 did not change them, and the one start-up resync
is older than step 3 (`docs/BUGS.md`, "DeckLink card start"). The meters were checked by eye only.
There was one session and one reconnect per transport.

### 11.2 The drift criterion — met, but against the clocks, not against §10.2's `smoothed`

The plan says the A/V offset should now drift at the ppm step 2 predicted, and that a mismatch means
the plumbing is wrong. Taken literally against §10.2's `smoothed` medians, **three of four
transports miss.** Against the physical clock pairs, all four match.

With the rate pinned, `err` (timebase − mapping) is no longer a sawtooth (§10.1). It accumulates
freely between position writes. So the change in its median across windows, excluding the first
20 s and any window containing a write, is the realised drift:

| | realised drift (step 3) | §10.2 `smoothed` median | independent clock figure |
|---|---|---|---|
| **NDI** | **+7.1 ppm** (both sessions, r² ≈ 0.85 per window) | n/a | **+6.680 ± 0.003 ppm**, device crystal vs mach (§10.4) |
| **SRT local** | **+5 ppm** (+10 on the 50 s reconnect) | +60 | audio and video share one TS clock, so only the device term: **≈ +7** |
| **WHEP MediaMTX** | **−65 ppm** (−59 on the reconnect) | +106 | audio vs video SSRC **+57.7 to +66.3 ppm** (`AV_SYNC_FINDINGS.md` §6.2), plus the device term |
| **WHEP Cloudflare** | **+14 ppm** | −81 | SSRC drift **indistinguishable from zero** (±25 ppm), plus the device term |

The first and last columns agree on every transport. The magnitude on MediaMTX matches §6.2, but its
sign convention (audio − video) has not been re-derived against `err`'s here, so the agreement is
stated in magnitude only. **The audio side carries exactly one clock, the device crystal.** NDI
isolates it and reproduces §10.4 to within 0.4 ppm, and the pinned stage adds nothing to it. Where
the mirrored transports differ, the difference is in the reference, which step 3 does not touch.

**So the plumbing passes, and the prediction was the wrong quantity.** On SRT the prediction was
most clearly wrong: sender and receiver share a clock, the realised drift is +5 ppm, and `smoothed`
read +60 to +130 throughout. That is item 1 of 11.4, and it matters more for step 4 than anything
else here.

### 11.3 One defect found, and fixed: WHEP audio PTS truncation

On both WHEP servers the stage logged a steady stream of **one-frame** overlaps, each followed one
buffer later by a one-frame hole, about 6 a second, while RTP reported no loss. The per-window counts
ran 35, 35, 14, 54, 33, … identically in both Cloudflare sessions and the MediaMTX reconnect, so they
were deterministic, not network.

**Cause:** `WHEPAudioReceiver` stamped its PTS as
`CMTime(seconds: ticks / 48000, preferredTimescale: 90_000)`. That call truncates, so about 7% of
960-multiple timestamps came out one 90 kHz tick low (701 of 10 000, reproduced in isolation). The
renderer absorbed that as an 11 µs jitter, but the stage keys its axis on the sample tick and made
each one a dropped real sample plus an inserted zero. **Fix:** stamp the integer RTP count on the
48 kHz timescale. Full entry in `docs/BUGS.md`.

**Verified the same day,** one 2-minute connect per server:

| | before | after |
|---|---|---|
| MediaMTX | 943 pairs in 4.5 min | **holes 1, overlaps 0** in 125 s — the 2.5 ms startup hole; 6252 contiguous, 0 / 0 |
| Cloudflare | 878 pairs in 4.2 min | **holes 1, overlaps 0** in 125 s — the same startup hole; 6236 contiguous, 0 / 0 |

The rest of 11.1 was measured before the fix. Nothing else in it depends on the WHEP PTS: the
renderer axis was exact either way, and the drift in 11.2 is a median over thousands of samples.

### 11.4 For step 4 — four things this run established

1. **`smoothed` is not a usable feed-forward ratio.** It disagreed with the realised drift on all
   three mirrored transports (11.2 above): +60 to +130 against +5 on SRT, and a swing from +1073 to −123
   within one 3-minute Cloudflare session, still moving past the first minute. Driving the resampler
   with it would add tens of ppm of error rather than remove it. It is the τ = 30 s filter of
   LiveClock's rate field. That field is the depth controller's output (§10.3), and over minutes it
   is not the slope of the mapping that `err` is measured against. Step 4's feed-forward needs a
   different estimator, for example the fitted slope of the paired `err` itself. Alternatively it
   can drop the feed-forward and let `k_p` carry the steady ppm, which at ≤ 70 ppm is well inside
   the §10.5 authority.
2. **Hold WHEP's first anchor until the mapping settles.** On every WHEP connect the mirror anchored
   on the first mapping, and then 1–3 position writes followed within 2.6 s. The first write was
   the largest, at 67.9–110.5 ms across six connects (the two after the fix included), and each was a "mapping change". **They are §10.10's startup
   realigns reaching the mirror after it had already anchored.** On the Cloudflare first connect
   the realigns moved +78.6 and +17.6 ms, and the first two position writes carried err 78.6 and
   17.6 ms, identical to the tenth of a millisecond. A later 10 ms write at ~2.6 s came after the
   first presentation, so that one is the relay (§10.10). None were heard, but each one is a
   renderer position jump. The first anchor belongs after the first presentation, when the realign
   window closes, rather than on the first mapping. SRT (0 realigns by construction, §10.10) and
   NDI showed none.
3. **NDI's +7 ppm is uncorrected.** With nothing in the NDI path correcting it, the error grew in a
   straight line (+1.36 ms by 194 s) and would reach the 10 ms re-anchor in about 24 minutes. That is
   §10.4's figure and the reason step 6 exists. It is recorded here because step 3 is the first
   build where no other mechanism was going to mask it.
4. **SRT starts each connect with a different ±3–4 ms offset.** Session 1 settled at −1.7 to
   −2.5 ms and the reconnect at +3.8 to +4.2 ms, both inside the 10 ms branch, so nothing acted on
   them. A closed loop with `k_p = 0.05` will null this in about 20 s. That is the right behaviour,
   provided the offset is an error and not the startup depth being deliberately carried. Check
   which before step 4 treats it as something to null.

### 11.5 Device-output mutes — measured 2026-09-25, against §6.2

**Method:** §6.2 and `LIVECLOCK_AUDIO_MIRROR_FINDINGS.md` §11.9, on the HEAD build:
- **Source:** OBS played `ref-300s.wav` as its only audio source, with Mic/Aux muted and monitoring off.
- **Capture:** Audio Hijack, Application (Manifold) → Recorder, at the device output.
- **Detector:** `reference_track.py`, unmodified.
- **Counting and matching:** `summarise_runs.py`'s rules and its mute ↔ `setRate` offset solve. Before
  any live capture was read, this reproduced the 09-22 local SRT result exactly (11 mutes, 11/11
  matched).

**All three §6.1 gates held:**
- **Injected-fault gate:** passed at 20:48, before run 1 (5 of 5 injected faults found, zero false
  events).
- **Single instance:** one Manifold PID was confirmed at every connect.
- **Out-of-band energy:** ≤ 0.0015% above 15 kHz on every capture.

The single-source test is the tracker's median block correlation (0.979–1.000; two sources read
~0.707). The `analyse_fg` peak-r gate only searches the first 120 s of the reference, so it can fail
on a clean capture that starts later in the file. It read r = 0.103 on the 09-22 local capture,
which begins 230 s into the reference.

**Two protocol constraints this instrument imposes, found on the first attempt:**

1. **Audio Hijack starts its file on the first non-silent audio, and records only while Manifold is
   producing audio.** The first connect after pressing Record is therefore never captured, and a
   16 s disconnect came out as 2.4 s of silence. Every run below is a **connect, then a disconnect
   and reconnect while recording**, and the reconnect session is the one measured. A renderer mute
   still delivers zero-valued buffers, so it is captured; that is how §11.4 saw its 50 ms mutes.
2. **The disconnect gap breaks tracker lock,** because the reference jumps by the silence Audio
   Hijack dropped. Each capture was split at the gap and the reconnect session tracked on its own:
   100% of blocks locked on all four.

**The baselines, recomputed.** `summarise_runs.py` divides by the time of the *last event*, not the
capture length. That overstates every §11.4 rate, and most of all on the quietest run. The same
captures, divided by programme time with "first 15 s" counted from the first audible sample:

| | §11.4 as published | recomputed |
|---|---|---|
| local SRT | 4.95 / 20.0 / 3.0 | **3.45 / 24.0 / 1.70** |
| Cloudflare SRT | 11.08 / 48.0 / 7.7 | **9.92 / 44.0 / 7.06** |
| WHEP (Cloudflare) | 7.32 / 40.0 / 4.5 | not recomputable: the 09-22 capture does not align with `ref-300s` (coarse r = 0.10) |

**Results — mutes/min overall / first 15 s / after 15 s, reconnect session, ~3 min each:**

| | step 3 | baseline (§11.4) | §6.2 target | every mute ↔ `setRate` |
|---|---|---|---|---|
| **local SRT** | **0 / 0 / 0** (184 s) | 4.95 / 20.0 / 3.0 | 0.0 / 0.0 | none to match; the only row is the FIRST ANCHOR |
| **WHEP MediaMTX** | **0.65 / 4.0 / 0.35** (185 s, 2 mutes) | none (§11.4's WHEP row is Cloudflare) | 0.0 / 0.0 | **2/2**: both are 10 ms position-branch writes (err 10.1 ms), lag +0 and +2 ms |
| **WHEP Cloudflare** | **0 / 0 / 0** renderer mutes (183 s) | 7.32 / 40.0 / 4.5 | 0.0 / 0.0 | no `setRate` after the FIRST ANCHOR |
| **NDI** | **0 / 0 / 0** (184 s) | **none; this is the first NDI measurement** | 0.0 / 0.0 | the only row is `anchorLiveAudio` at connect |

No splices on any run.

**Heard vs detected.** Every event Robbie heard matched a detected event, and nothing he didn't hear
was detected:
- **MediaMTX:** a glitch "a few seconds after the reconnect", which is the 60 ms mute at +2.8 s from
  the startup position write (step-4 note 2 in 11.4). The blip "right at the end" is the 71 ms mute
  at +181 s from a steady-state position write.
- **Cloudflare:** two quick glitches about 1:47 into the recording. These are **not renderer mutes.**
  They are two 20 ms silences 0.32 s apart, matching `input axis HOLE 20.00 ms` at 21:28:01.342 and
  .657 (RTP `seqGaps=5 declaredLost=7` in that window): two Opus packets the path lost, filled with
  silence by the stage exactly as designed (11.1). Before step 3 the renderer played the same loss
  as a PTS gap. They are transport loss and are kept out of the mute count, as §11.4 kept its
  content holes out.

**What this establishes:**
1. **The periodic stutter is gone** wherever the position branch stayed quiet: SRT, Cloudflare WHEP
   and NDI all read 0.0 / 0.0, against 3.0–4.5 mutes/min steady state before.
2. **What remains is the position branch, one mute per write, 2 of 2.** Step 3 keeps that branch on
   purpose (§7), so this is the expected residue, not a defect. On MediaMTX it fired twice in 3 min:
   once at startup and once from the ~−60 ppm drift of 11.2 reaching 10 ms. Step 4's loop removes
   the steady one; the startup one is 11.4 note 2.
3. **The first anchor, the session's one rate write, produced no separable mute on any transport.**
   It lands before the renderer's first audible sample, so this is "not separable", not "proved
   silent". §11.4's filter excluded the same 0.2 s.
4. **NDI now has a figure: 0.0 / 0.0 over 184 s.** It does **not** answer §8 open question 1
   (whether an `anchorLiveAudio` re-anchor mutes), because at +7 ppm the first re-anchor is ~24 min
   away (11.4 note 3). That needs a run long enough to reach one.

**Limits:** n = 1 session per transport, 3 minutes each. The captures are in
`~/Desktop/manifold-audible-events/step3/`, and the logs are `~/Desktop/step3-mutes-*.log`.

## 12. Step 4b results — the first anchor at first presentation, measured 2026-09-26

**Built:** the session's one `setRate(1.0)` now waits for LiveClock's first presentation on every
mirrored transport (SRT, WHEP), and on RTP audio (WHEP) also for the first audio RTCP Sender Report.
It takes the later of the two (§2.7).
- **The presentation signal** is `LiveClock.onFirstPresentation`, fired once per stream where
  `hasPresentedOnce` flips, carrying the mapping the picture started on.
- **The SR signal** is the bridge's one-shot `onAudioSenderReport`. The SR parse was already
  compiled into Release, so the gate behaves the same in every configuration.
- **Keyed on the protocol, not the transport or server.** `beginLiveAudio(awaitsSenderReport:)` is
  true for WHEP because RFC 3550 §6.4.1 requires SRs of RTP senders. Nothing branches on the server.
- **Two fallbacks, each logged:**
  - no SR within 2 s of the first presentation → anchor on today's constant offset and log a sender
    deviation; an SR that comes later is logged as LATE;
  - no presentation within 5 s of the first mapping → anchor on the pre-4b first-mapping rule.
- **Unchanged:** the controller is not wired (4d), the 10 ms position branch stays, and NDI's
  `anchorLiveAudio` is untouched.
- `swift test`: 21 of 21. Profile and Release build clean.

**Protocol:** the Profile build, unsigned (`.build-cc/step4b`), telemetry on, OBS on this Mac as the
sender. A fresh launch per transport. Each run: cold connect, 60 s, disconnect, 5 s, warm reconnect,
60 s, quit. Logs: `~/Desktop/step4b-{whep-mediamtx,whep-cloudflare,srt-local}.log`. Every time below
is from the `[*-AUDIO] FIRST-ANCHOR GATE` line, in ms after `beginLiveAudio`.

### 12.1 Results

| | MediaMTX cold | MediaMTX warm | CF cold | CF warm | SRT cold | SRT warm |
|---|---|---|---|---|---|---|
| Startup realigns before the picture | 2 | 4 | 2 | 4 | 0 | 0 |
| **Startup position writes** (step 3: WHEP 1–3) | **0** | **0** | **0** | **0** | **0** | **0** |
| `setRate` rows per session | hold, anchor, end | same | same | same | same | same |
| First mapping | +496 | +998 | +1292 | +706 | +300 | +215 |
| First presentation | +787 | +1395 | +1597 | +1104 | +302 | +221 |
| First audio SR | +9 | +16 | +1097 | +1127 | no RTCP | no RTCP |
| Anchor (audio starts) | +794 | +1403 | +1604 | +1131 | +302 | +222 |
| What opened the gate | picture | picture | picture | **SR** | picture | picture |
| **Audio start after the first picture** | 7 ms | 8 ms | 7 ms | 27 ms | 0 ms | 1 ms |
| Added against the first-mapping rule | 298 ms | **405 ms** | 311 ms | **425 ms** | 2 ms | 7 ms |
| Fallback fired | no | no | no | no | no | no |
| Mirror `posErr` after the anchor, max | 5.3 ms | 8.0 ms | 4.8 ms | 7.4 ms | 0.9 ms | 3.3 ms |
| Heard and seen at start (Robbie) | clean; flash then beep | same | clean | clean, tight | picture slightly first | same |

- **The target is met.** Startup position writes on WHEP went from 1–3 per connect to **0** on all
  four WHEP connects. Every realign fell before the anchor, so the mirror anchored once on the
  settled line, and `posErr` stayed inside the 10 ms branch for the rest of each session.
- **SRT did not regress.** It has no startup realigns (§10.10), so the gate cost 2–7 ms there.
- **Audio-start delay against `targetDepth`: at the limit on warm WHEP connects.** Both warm WHEP
  connects added about 0.4 s, over §2.7's "up to about 0.35 s". The cause is the video startup fill:
  first frame to first presentation took 397–398 ms on both. Audio then followed the picture within
  27 ms on every connect, so the extra is the picture's wait, not the audio gate's. §2.7's estimate
  came from realign timing, which does not bound the fill.

### 12.2 The SR gate

- **Once, the SR was the last thing awaited.** On the Cloudflare warm connect the first SR arrived
  23 ms after the first presentation. The gate held for it, and audio started 27 ms after the picture.
- **Otherwise the SR arrived first.** MediaMTX sent its first SR within 16 ms of the session opening,
  long before any picture. Cloudflare took ~1.1 s on both connects, which is about as long as the
  picture takes, so on the cold connect the SR still came 500 ms early. **The prediction that
  Cloudflare's SR would add 0.3–0.6 s after the picture was wrong.** It had used
  `AV_SYNC_FINDINGS.md` §6.5's 928–956 ms without the picture's own startup time beside it.
- **Neither fallback has been exercised.** The 2 s SR bound is a limit on silence, not a measured
  figure. It cannot tell a sender that never sends SRs from one that is merely slow, and RFC 3550
  §6.2 allows ~6 s between compliant reports. Re-derive it at 4e, when the SR is applied rather
  than only waited for.
- **The gate fixes the start only.** WHEP's running A/V offset is still arbitrary per session (§2.6,
  `BUGS.md`) until 4e puts the SR line into the target. "Tight" on the Cloudflare warm connect is
  therefore a heard start, not a measured offset.

### 12.3 ⚠️ UNRESOLVED — the picture reads slightly first at the start

**Heard on SRT and MediaMTX:** the picture appears a little before the audio at connect. "Right
after the first beep everything was spot on." Nothing else was seen or heard.

**The log does not explain it.** Audio started 0–8 ms after the picture on those connects. On SRT,
4b moved the anchor by only 2–7 ms, so whatever was seen there at the start was already there in
step 3.

**Two candidate causes, neither visible from inside the process:**
1. **The first beep is clipped.** At the anchor the renderer discards audio that is already late.
   If the fixture's first beep straddles the anchor, its onset is lost and it is heard late.
2. **The output starts late.** The device takes some time to produce sound after the synchronizer
   goes from rate 0 to 1, and no in-app timestamp includes that.

Both are inference. **Settle it with the criterion-12 device capture (§6.3):** record a connect at
the device output (Audio Hijack, as in 11.5) and measure the flash-to-beep offset of the FIRST beep
against later ones. Cause 1 shows a truncated first beep at the correct time. Cause 2 shows a
complete first beep that starts late.

**Limits:** n = 1 cold and 1 warm connect per transport, judged by ear and eye, with no device
capture. NDI was not run, because it does not go through the mirror.

---

## 13. Step 4d results — the loop closed, measured 2026-09-26

**Built:** `LiveAudioResampleSteering` (`Packages/ManifoldCore/Sources/LiveAudioResample/`), one per
session.
- **Per input buffer**, in `LiveAudioSink.enqueue` after the stage:
  - one paired read of the timebase, gated at 200 µs;
  - `actual` mapped to content time (4a), against the session's target line (§2.8);
  - one controller step (4c), and ρ into the stage for the next block.
- **It is the session's only timebase writer.** The first anchor, a coarse event and a re-anchor
  all go through it, so its count IS the `setRate` count.
- **Replaced:**
  - the mirror's 10 ms position branch and NDI's `serviceDesktopAudioAnchor` re-anchor are off;
  - the mirror now only anchors and hands the steering the mapping line.
- **The coarse branch (§2.4):**
  - triggers: `|e_f| > 250 ms` (level) or `|e_k − e_(k−1)| > 50 ms` (step), both on content time;
  - `e_f` reset and `i` held after each event.
- **In every configuration.** This is the product's drift correction now, not an instrument.

**Three departures from §2.4, stated so they are not read as the design:**
1. **The coarse action moves the timebase only.** It places the timebase at
   `outputTime(atInputTime: target)`, a new inverse of the content-time map, so the content heard
   is the target. It does not drain the stage or re-anchor its axis: re-anchoring the output axis
   would restart it at the next input tick while the renderer still holds buffers on the old one,
   overlapping or gapping them by the offset the loop has accumulated. The result is the same
   single write step 3's position branch made.
2. **A 0.25 s settle window after every write.** `setRate` updates the timebase asynchronously, so
   the reads just after a write see the old axis and then the new. Without the window, the first
   stale read seeds `e_f` at the old error and fires a second, LEVEL event on the write's own
   step. A test shows exactly that at settle 0. The 0.25 s is a bound, not a measurement.
3. **`liveAudioDrift` reads content time.** Compared raw, it would report the ratio's correction
   as drift (§2.1).

**Back-out switch** (DEBUG only, absent from the Release binary):
- how to set it: `MANIFOLD_PIN_RESAMPLER_RATIO=1` at launch, or Debug ▸ Resampler Ratio, taking
  effect from the next connect;
- what "pinned" is: exactly step 3 — ratio 1.0, controller idle, coarse off, and both 10 ms
  branches back on;
- no defaults key is written.

`swift test`: 29 of 29. The new steering tests cover:
- the step trigger (±49 ms does not fire, ±51 ms does);
- the level trigger (a 5000 ppm drift fires once; a 240 ms offset does not);
- one write per session over 10 min at each of the four measured drifts, with `i` landing on
  +5 / −60 / +14 / +7 ppm;
- a 200 ms snap as exactly one step event, with `i` held;
- pinned mode never moving the ratio;
- the inverse map round-tripping on the real stage.

Profile and Release build clean.

**Protocol:** the Profile build, unsigned (`.build-cc/step4d`), telemetry on, OBS on this Mac as
the sender, the flash-beep fixture. A fresh launch per transport: connect, about 3 min, quit. Run
order MediaMTX, Cloudflare, NDI, SRT, with SRT last because disconnecting local SRT hangs OBS.
Logs: `~/Desktop/step4d-{mediamtx,cloudflare,ndi,srt}.log`.

### 13.1 Results

| | Local SRT | WHEP MediaMTX | WHEP Cloudflare | NDI (DistroAV "OBS PGM") |
|---|---|---|---|---|
| Session length | 193 s | 194 s | 192 s | 183 s |
| **`i` at end** (realised drift, 11.2) | +8.4 ppm; wandered +1 … +65, ≈ +12 over the last 100 s (**+5**) | **−58.5 ppm**; −48 … −63 from 70 s (**−65**, −59 on the reconnect) ✅ | **−63.5 ppm**; −43 … −63 from 140 s (**+14**) ❌ | **+6.48 ppm**, settled by ~100 s (**+7.1**; §10.4 +6.68) ✅ |
| `e` per 10 s window, whole session | −2.3 … +3.8 ms | −3.2 … +3.0 ms | −3.7 … +7.3 ms (first window); ±3.7 after | −0.16 … +0.07 ms |
| §5.3 bound | ±15 ms ✅ | ±15 ms ✅ | ±15 ms ✅ | ±10 ms ✅ |
| `e` p-p within a window | 2.3–4.7 ms | 1.9–3.6 ms | 1.9–9.0 ms (the 9 in the first window) | ≈ 0.03 ms |
| Max \|ρ − 1\| | 259 ppm (first window) | 195 ppm | **613 ppm** (first 10 s) = 1.06 cents | 7.9 ppm |
| Slew max | 200 ppm/s — the limit — in almost every window | 200 ppm/s, the same | 200 ppm/s, the same | 86.5 ppm/s in the first window, ≤ 8.2 after |
| Controller saturated | 0 | 0 | 0 | 0 |
| **`setRate` rows with a non-zero rate** | **1** (first anchor) | **1** | **1** | **1** |
| Coarse events | 0 | 0 | 0 | 0 |
| NDI `RE-ANCHORED` | — | — | — | **0** |
| Heard and seen (Robbie) | picture and audio slightly late at connect, not objectionable | fine; the connect landed on the fixture's black gap | no problems | no problems |

- **The write criterion is met on every transport.** Each session has exactly three rate rows —
  the hold, the first anchor, the end — so non-zero writes = 1 = 1 + COARSE (0).
- **NDI's retired re-anchor did not come back.** 0 `RE-ANCHORED` lines, and the loop held `e`
  within ±0.16 ms.
- **The plant model holds where there is no depth loop.** NDI's integrator settled on +6.48 ppm,
  within 0.2 ppm of §10.4's independent device-crystal figure. MediaMTX landed on its step-3 drift.
- **SRT's startup offset (11.4 item 4) is now nulled.** The first window's median `e` was
  +2.2 ms; it was gone within ~20 s. Whether that offset was error or deliberately carried depth
  is still the open question 11.4 asked.
- **The late start on SRT and MediaMTX is connect latency, not an A/V offset.** Picture and audio
  were late *together*. Audio started 0 ms (SRT) and 7 ms (MediaMTX) after the picture, and the
  first-window median `e` was +2.2 and +1.3 ms. §12.3's start question is unchanged by this step.
- **The first-anchor gate behaved as in §12:**

  | | first mapping | first presentation | first SR | anchor |
  |---|---|---|---|---|
  | MediaMTX | +506 | +822 | +7 | +829 |
  | Cloudflare | +894 | +1185 | +1096 | +1192 |
  | SRT | +294 | +296 | no RTCP | +296 |

  All times are ms after `beginLiveAudio`. No fallback fired.
- **The pairing gate discarded about 4%** of reads on the mirrored transports (18–21 per window)
  and none on NDI.

### 13.2 ⚠️ The ratio ripple is 5–10× the simulation's, and S = 200 ppm/s is binding

§2.2's simulation put the steady ratio ripple at **24 ppm p-p**. On the three mirrored transports
the measured ρ swung **50–250 ppm within a 10 s window**, and the slew limiter hit 200 ppm/s in
almost every window. On NDI the ripple was ≈ 1 ppm and the slew stayed under 8.2 ppm/s after the
first window.

**Cause:**
- The measured disturbance is the picture's own depth wobble. Within a window, `e` spans 2–4 ms on
  SRT and WHEP against 0.03 ms on NDI, which has no depth loop.
- The simulation modelled that as a ±1.5 ms sawtooth at 1 Hz. The amplitude was about right, but
  the real wobble is slower and passes the τ_e = 2 s filter instead of being averaged out.
- At `k_p` = 0.1 s⁻¹, each 1 ms of filtered error commands 100 ppm. The command then moves faster
  than 200 ppm/s, so the slew limit, not the gain, sets how fast ρ follows.

**This is the audio following the picture, not a fight.** It is the movement §2.3 item 3 says
audio has to follow.

Correlation per 10 s window, from the third window on:

| | LiveClock rate vs ρ − 1 | LiveClock rate vs `i` | depth error vs median `e` |
|---|---|---|---|
| SRT | −0.12 | −0.17 | +0.21 |
| MediaMTX | +0.13 | 0.00 | −0.32 |
| Cloudflare | **+0.47** | +0.11 | **−0.58** |

The integrator never follows LiveClock's rate (|r| ≤ 0.17). The controller never saturated, and
`e` never grew; nothing ran away.

**It is inaudible, and was not heard:**
- 250 ppm is 0.43 cents, and 200 ppm/s is 0.35 cents/s;
- the largest excursion, 613 ppm, was 1.06 cents, in Cloudflare's first 10 s.

**What it changes:** S = 200 ppm/s is not headroom. It is a binding constraint in steady state on
every LiveClock transport. §2.2's ripple figure and its reasoning for τ_e are therefore
understated for those transports.

⚠️ **Do not retune from these runs.** Three minutes per transport cannot separate a better τ_e
(more filtering, more lag) from a lower `k_p`. Criterion 7 needs to be read against a real ratio
trace. Step 8's 30-minute runs are where τ_e and S get decided, with this section's ripple as the
number to beat.

**ADDED 2026-09-26 — the binding does not come from the sender.**
- **The run:** ffmpeg → MediaMTX, the cleanest sender measured: 6.7 µs SR scatter, loopback, zero
  loss, 31 min (`AV_SYNC_FINDINGS.md` §6.7).
- **The result:** the slew limit still hit 200 ppm/s in **185 of 185** windows, and max |ρ−1| was
  269 ppm. The Cloudflare soak (§13.3) hit it in 154 of 190.
- **So the binding comes from LiveClock's own depth wobble,** passed through the τ_e filter, as the
  cause list above says. It is not network or sender noise.
- **What follows:** a quieter link or sender will not relieve S. Only τ_e, `k_p`, S itself, or the
  depth loop can.

### 13.3 ✅ RESOLVED 2026-09-26 — Cloudflare's integrator settled near −60 ppm, not +14: a real audio↔video slope

§7 step 4 says a settled integrator away from the realised drift "means `target` or `actual` is
wrong". Cloudflare's `i` fell from +135 ppm (20 s) through 0 (60 s) to −43 … −63 ppm over the last
50 s, and ended at −63.5. Step 3 measured +14 ppm on the same path (11.2).

**Two hypotheses, neither established:**

1. **The target line's position moved, not a clock.**
   - Over a 3-minute session the integrator learns the *net slope of the target*. That includes
     any net movement of the mapping's position by the depth loop, not just clocks.
   - On Cloudflare the depth is the least settled: §11.8's +51 ms median / +135 ms p90 excess, and
     the reorder inflation behind it. ⚠️ **Miscited:** §11.8 measured Cloudflare **SRT**. This
     session is Cloudflare WHEP, which logs `reorder=0`, and its excess is **−12 ms median**, flat
     over the 30-min soak below. A net mapping creep of ≈ 13 ms over 3 minutes would read as
     −75 ppm.
   - Cloudflare is also where the loop tracks the depth loop most: +0.47 against LiveClock's rate,
     −0.58 between depth error and `e`.
   - If this is it, the value is right for this session and would average toward +14 over longer
     runs.
2. **A real audio↔video slope on this session.**
   - `AV_SYNC_FINDINGS.md` §6.2 measured Cloudflare's SSRC drift as indistinguishable from zero,
     but with ±25 ppm standard errors, over three sessions.
   - A session-specific slope, or one that belongs to the OBS sender rather than the relay (§6.7),
     would move `d` directly.
   - Until 4e puts the SR line into the target (§2.6), the loop cannot tell that slope from the
     video's.
   - ⚠️ **CORRECTED 2026-09-26 — the two bullets above are wrong about what `i` can see.** With no SR
     offset in the target, `target` is the video mapping line and `actual` is audio content time
     consumed at ρ × the device clock. So `i` settles on **the video clock against the device
     clock**, plus any mapping creep: `i = δd − δv − c`. The audio clock does not appear in it.
     An audio↔video slope moves `i` only through its video half. Its audio half appears as a
     **drift of the audio lead**: audio arrives at its own rate but is consumed at the video's.

**Against a WHEP plumbing error:** MediaMTX, on the same `target` and `actual` code, landed on its
step-3 drift. **Against reading the value as settled at all:** `i` was still moving at 140 s and
swung ±10 ppm window to window after that.

**Settle it with:**
- a 30-minute Cloudflare run, with `i` read over the last 20 minutes against the mapping's net
  position change over the same span (hypothesis 1 predicts they account for each other);
- and/or the SR slope logged beside it once 4e's fit exists (hypothesis 2 predicts `i` tracks it).

#### ✅ SETTLED 2026-09-26 by a 30-minute soak — a real audio↔video slope of ~65 ppm, not creep

**Protocol:**
- **Build:** HEAD `e8f822e`, Profile, unsigned (`.build-cc/soak-e8f822e`), rebuilt from the clean
  tree rather than reusing `.build-cc/step4d`, which predates the commit.
- **Run:** OBS → Cloudflare WHIP → Manifold WHEP, flash-beep fixture, unattended, 1902 s, ended by
  `kill -TERM` at 32 min, so the END lines are absent. Log: `~/Desktop/soak133-cloudflare.log`.
- **Analysis:** `~/Desktop/soak133_analyse.py`, log only, with nothing added to HEAD's logging.
- **Span:** t ≥ 600 s, excluding the +1565–1770 s event (§13.4).

**The decomposition.** In ppm against mach, `i = δd − δv − c`:
- `δd` is the device crystal, +6.48 ppm from step 4d's NDI run (§13.1);
- `δv` is the video RTP clock, the mean of `[WHEP-DRIFT] senderRate`. It is a per-window
  minimum-offset difference, so the mean telescopes;
- `c` is mapping creep against arrivals, `−D·d(count)/dt` from the `[LIVECLOCK] depth= … count=`
  lines, equivalently `d(excess − depth)/dt`.

The same decomposition was first checked against step 4d's 3-minute MediaMTX log. It gives
`δv` +69, which predicts `i` ≈ −62; the measured `i` was −58.5 (step 3: −65). So the sign
convention holds.

| term | value | source |
|---|---|---|
| `i` | **−59.9 ppm**; trend −0.11 ± 0.34 ppm/min; 5-min blocks −58.5 / −61.9 / −57.6 / −58.8 | steering windows |
| `δv` | **+61.9 ppm** (220 windows) | `[WHEP-DRIFT]` |
| `c` | **+4.1 ± 1.8 ppm**; count·D flat at 392–401 ms per 5-min block | `[LIVECLOCK]` count |
| excess `depth − count·D` | **−12 ms median**, trend −0.2 ± 1.5 ppm | `[LIVECLOCK]` |
| `δd − δv − c` | **−59.5 ppm**, within 0.4 ppm of `i` | |
| audio lead drift | **−70 ± 2 ppm** over the span; **−142 ms over the 1902 s session** | resampler `out` frames against the device clock, wall-timed |

**Hypothesis 1 (creep) is ruled out.**
- To carry −60 ppm for 16 min, the queue would have had to lose about 112 ms, or 2.7 frames. It
  moved about 6 ms.
- `i` did not relax toward +14. It held at −60 in every 5-min block.
- The reorder mechanism behind hypothesis 1 is absent on WHEP (above).

**Hypothesis 2, as corrected, is what happened:**
- **The video RTP clock runs about +62 ppm against mach, and that is what `i` learned.**
- **Audio does not share it.** The lead drains at −70 ppm. With ρ − 1 ≈ +60 ppm and
  `δd` +6.5, that puts audio arrival within a few ppm of mach. Precision is limited by the lead
  being wall-clock timed, so the Mac's NTP frequency correction enters it.
- **The audio↔video slope is therefore about 65 ppm**, the same size as MediaMTX's (§6.2 of
  `AV_SYNC_FINDINGS.md`; step 4d's MediaMTX gave `δv` +69).
- The video-SR probe build was not needed. The decomposition closed without it.

**What it means:**
- **The loop is right, and real lip-sync still drifts.** The loop holds audio content time on
  the video RTP line. Those two timelines run about 65 ppm apart, so audio gains roughly
  **117 ms on the picture per 30 min** while `e` shows zero trend. `e` cannot see this. Only 4e's
  SR line in the target (§2.6) removes it. See `BUGS.md`, "WHEP lip-sync drifts with the sender's
  audio/video clock slope; e cannot see it".
- **The same slope eats the audio queue:** −142 ms over this session. The queue's absolute depth
  is not logged, so how long a session runs before the renderer starves is unknown. No
  starvation was seen here.
- **Step 3's +14 ppm on Cloudflare is now the outlier.** Both 4d-era Cloudflare sessions settled
  near −60, as MediaMTX does. That leans toward §6.7's reading, that the ~60 ppm belongs to the OBS
  sender rather than to the relay. **n = 1 soak; a lean, not a result.** A non-OBS sender through
  both servers would settle it.

**§5.3 on this run (WHEP, ±15 ms p99, zero trend):**
- **p99 over the full 30 min fails.** 8 of 190 windows have p99 > 15 ms, peaking at +106.6 ms,
  all in the §13.4 event. Pooled p99 is about +70 ms or more.
- **Excluding the event:** worst window p99 **+7.25 ms** (median +1.39); worst p01 −4.41 ms
  (−7.1 in the first window).
- **Trend passes:** −0.11 ± 0.10 ppm, event excluded. This is blind to the audio↔video slope
  above.

**Other figures:**
- max |ρ−1| **2000 ppm**, at B, during the event; 8 windows saturated;
- the slew limit binds in 154 of 190 windows, which confirms §13.2;
- `setRate`: 1 non-zero write, the first anchor;
- COARSE: 0 (level 0, step 0);
- pairing discards: 4.0%.

### 13.4 Still unmeasured at step 4d

These runs were 3-minute quick connects, n = 1 per transport, judged by ear. Not measured:
- **device-output mutes/min** with the §11.9 harness, using 11.5's protocol (connect, reconnect,
  measure the reconnect). "Mutes = COARSE count" is shown by the rate rows, not by device capture;
- **criterion 12**, the device-level A/V offset, against the pre-resampler baselines (SRT
  +203.9 ms, Cloudflare SRT +165.8 ms, NDI +230.1 ms). This is the first step at which those
  numbers should move, and it is not yet known whether they did;
- **the 30-minute p99 and zero-trend checks** against §5.3. The bounds above are per-window
  minima and maxima over 3 minutes, not p99 over 30. *Since measured for Cloudflare WHEP only,
  by the 2026-09-26 soak (§13.3): trend passes, and p99 fails on the event below.* Still unmeasured
  on SRT, MediaMTX and NDI;
- **criterion 7 against a real ratio trace**, which §13.2 makes the more important of the open
  criteria;
- **any coarse event in the field.** None fired, so the step and level triggers, the settle
  window and the inverse-map write are verified only by `swift test`, not against a real snap,
  freeze guard or axis break;
- **the pinned back-out switch in the app.** It was not exercised in these runs;
- **a reconnect.** Every run was a single connect, so the steering's per-session construction and
  teardown across a reconnect were not observed;
- **the SDI counters and the meters.** Not checked at this step.

#### ⚠️ The first field case of jitter recovery under the loop — the 2026-09-26 soak, +1572 s

Seen in the 30-minute Cloudflare WHEP soak (§13.3), unattended, so nobody was there to hear it.

**What happened.** At +1572 s (20:25:28 wall time), **both streams under-delivered for about 3 s**:
- video arrived at 23/22 frames per s and audio at 48/45 packets per s;
- there were zero sequence gaps and zero reorder, so the shortfall came from the sender or
  Cloudflare, not the network;
- `[WHEP-BACKLOG]` content fell about 0.17 s behind wall time and stayed there;
- depth dropped 0.372 → 0.253 s (count 9 → 6).

LiveClock pinned at **−0.5% for about 30 s** to rebuild depth, and logged `publication starved` for
3 s. The picture was genuinely running slow for that time.

**What the loop did.**
- **Peak:** `e` rose to **+106.6 ms (audio ahead)**. The mapping slowed at 5000 ppm, and the
  resampler can follow at only B = 2000 ppm.
- **Recovery:** ρ sat at the bound for about 70 s. `e_f` was back near zero about 85 s after onset,
  and every sample was inside ±5 ms by about 100 s.
- **The integrator:** `i` was held at +54.8 ppm while saturated, overshot to +330 ppm on release,
  and was back near −60 within about 2 min.

**No coarse trigger fired, correctly by the rules as written.**
- The move was a ramp, so no step between consecutive evaluations reached 50 ms.
- The level never reached 250 ms.
- The rate rows show one write for the session.

**This exceeds what §2.2 simulated.** §2.2's jitter-recovery case was an 80 ms move over 16 s at
−5000 ppm, with a predicted peak of 59 ms. This one moved about 150 ms and peaked at 106.6 ms,
well past the ~45 ms threshold for audible audio lead, for about a minute.
- It is the §2.2 "one trade for Robbie" (B 0.002 / S 200 against lip-sync during recovery) arriving
  in the field.
- It also produced every window of this soak that failed §5.3.

**Revisit at the step 8 soak.** Decide there, with multi-hour data:
- B and S;
- whether a sustained LiveClock rail should reach the coarse branch (a splice at step 5) rather than
  be glided through.

The event count and size per hour are what that decision needs. n = 1 so far.

## 14. Step 4e-1 results — Manifold owns the video RTCP, measured 2026-09-27

**No presentation change.** The SR fit stays log-only. This step moves who sends and reads the video
track's RTCP, so the video SR is available on every session for step 4e.

**What changed:**
- **`RtcpReceivingSession` is no longer chained** on the video track. The
  `MANIFOLD_WHEP_SR_PROBE_UNCHAIN_VIDEO_RTCP` macro and its dead branch are deleted. Video RTCP now
  reaches `-ingestRTP:` and is taken before the depacketizer.
- **Our own PLI** (RFC 4585 §6.3.1) replaces the one `rtcRequestKeyframe` call site, sent through
  `rtcSendMessage` like NACK. Every trigger and the 1 s throttle are unchanged.
- **Our own RR** (RFC 3550 §6.4.2), one per received video SR, sent immediately. That is the
  library's cadence, restricted to SRs for the video SSRC.
  - LSR from that SR; DLSR measured.
  - Extended highest sequence and cumulative loss from the depacketizer's existing NACK accounting
    (wrap cycles and base sequence added).
  - Interarrival jitter per RFC 3550 A.8, 90 kHz.
- **SRs are selected by SSRC** on both tracks. Under BUNDLE libdatachannel hands a compound packet
  to every track whose SSRC appears in it, so "the first SR in the packet" could be the other
  stream's. Audio latches its SSRC from its first RTP packet.
- **The video SR parse is always on** and feeds the log-only Δ probe.
- **The steering window line gains `renderer depth ms min/med/max`**: enqueued output end minus the
  timebase, per accepted read. Measurement only.
- The builders and the SR parser are a leaf C target, `RTCPWire`, with 14 byte-layout tests
  written from the RFC diagrams (`swift test`: 43 of 43).

**Step 0's finding — nothing was lost by unchaining.** In v0.24.5 `RtcpReceivingSession` sent
exactly three things: an RR per received SR, a PLI per `rtcRequestKeyframe`, and a REMB only after
`rtcRequestBitrate`. Manifold has never called `rtcRequestBitrate`, so **REMB was never sent**. The
library's RR was also largely wrong:
- **jitter and DLSR were always 0**;
- **the sequence fields were swapped** — 0 in the highest-sequence field, `mMaxSeq` in the cycles
  field;
- its base sequence stayed 0 (the probation path that sets it never ran), so cumulative loss was
  meaningless;
- it answered **every** SR on the track, including audio SRs carried in a BUNDLEd compound packet,
  reporting against whichever SSRC it had latched last.

### 14.1 Results

Four ~3-minute runs, loopback MediaMTX and real Cloudflare. The 4e-1 runs had a debug trigger
sending a PLI every 5 s (`MANIFOLD_DEBUG_PLI_EVERY_S`). The publishers used long keyframe intervals
(ffmpeg 20 s, OBS 20 s) so that an IDR within 3 s of a PLI would read as an answer.

**PLI:**

| | ffmpeg → MediaMTX | OBS → Cloudflare |
|---|---|---|
| HEAD `9692f90` (`rtcRequestKeyframe`) | join PLIs unanswered; first IDR on the 20 s schedule | join PLIs unanswered; first IDR on the 19 s schedule |
| 4e-1 (own PLI) | 52 sent, 0 refused; every IDR on the 20 s schedule | 56 sent, 0 refused; every IDR on the 19 s schedule |

Neither build ever got a PLI-driven IDR. MediaMTX's API shows our PLIs arriving (the reader's
`rtcpPacketsReceived` rose by 12 per 10 s: 10 RR + 2 PLI), and its RTCP to the ffmpeg publisher held
at 25 per 10 s before, during and after — it does not forward a reader's PLI. On Cloudflare the
IDRs followed OBS's schedule only. Tracked in `docs/BUGS.md` ("Keyframe requests (PLI) are not
honoured…").

**RR and SR selection (4e-1):** MediaMTX 206 video SRs, 206 RRs sent; Cloudflare 222 and 222. None
refused, and no SR for the other stream's SSRC on either track.

**A/V and steering against HEAD:**

| | MediaMTX HEAD | MediaMTX 4e-1 | Cloudflare HEAD | Cloudflare 4e-1 |
|---|---|---|---|---|
| `FAILED` / `REFUSED` | 0 | 0 | 0 | 0 |
| steering windows, coarse | 19, 0 | 19, 0 | 19, 0 | 20, 0 |
| timebase writes | 1 | 1 | 1 | 1 |
| per-window `e` median range | −0.98 … +3.08 ms | −0.71 … +1.21 ms | −2.08 … +6.11 ms | −3.80 … +2.23 ms |
| max \|ρ−1\| | 362.2 ppm | 168.6 ppm | 734.3 ppm | 462.1 ppm |
| `timebase−clock` at end | −1.2 / −2.0 ms | −1.1 / −0.8 ms | −1.0 / −0.5 ms | +0.1 / −0.2 ms |
| audio decode failures | 0 | 0 | 0 | 0 |
| Δ probe | no Δ (video SRs absorbed) | Δ −12.592 ms, spread 0.340 ms | no Δ | Δ +17.996 ms, spread 41.2 ms |

The differences are within session-to-session variation (n = 1 per cell) and none leans against
4e-1. The Cloudflare spread is §13.3's OBS audio↔video slope, not this step.

**First renderer-depth figures:** MediaMTX about **403–439 ms** (median ~422); Cloudflare about
**373–403 ms** (median ~387).

### 14.2 The PLI acceptance criterion, as replaced

The brief's criterion — every PLI we send is followed by an IDR — cannot be met by either publisher
under test, and HEAD fails it identically. **It was replaced by:**
1. **byte-identical to the library's PLI** — PT 206, FMT 1, length 2, the video SSRC in both SSRC
   fields — pinned by the `RTCPWire` tests;
2. **never refused** by `rtcSendMessage` (0 of 108);
3. **arrival confirmed** on MediaMTX's reader counters;
4. **downstream behaviour identical to HEAD** on both servers.

A publisher that honours PLI (Chrome over WHIP is the untested candidate) is still needed to see a
PLI-driven IDR at all.

## 15. Step 4e-2 results — the WHEP SR line in the target, measured 2026-09-27

**Built:** `SenderReportLineFit` (`Packages/ManifoldCore/Sources/LiveAudioResample/`), one per WHEP
session, fitted fresh with no prior.
- **Input:** every Sender Report for the audio or video SSRC, selected by SSRC, with T_a0 and T_v0.
  The bridge now sends them all to Swift instead of firing once on the first audio SR.
- **Δ per pair as the probe computes it:** the NTP difference in 32.32, then the RTP difference as one
  exact integer ratio over 48000 × 90000, both before any double. Each SR is used in one pair only
  (both streams fresh), not re-paired on every SR as the probe does. The formula is unchanged.
- **The abscissa is video content time,** `(rtp_v − T_v0)/90000`, the axis of the mapping's
  `senderPTS`. No host clock enters the fit.
- **Into the target** (`FrameEngine.mirrorLiveAudio`):
  - `target = senderPTS − offset(senderPTS)`, in `cushion`'s slot with its sign convention;
  - the slope enters the reference rate as `rate · (1 − b)`, never the ratio;
  - no line (before the first pair, or the gate's fallback) → the constant, 0 on WHEP;
  - `liveAudioDrift` adds back the applied offset, as it added the cushion.
- **The sign of b, derived** at `SenderReportLineFit.reference`: dΔ/dp = 1 − (1+ε_a)/(1+ε_v) ≈
  ε_v − ε_a. b > 0 means the audio belonging with the picture advances slower than the picture.
  - A test pins it: +69 ppm of Δ slope gives < 20 µs of audio↔video drift over 600 s, on a frozen
    line and through a 600 s SR outage; the opposite sign fails by > 80 ms.
  - The line is frozen in that test on purpose. While pairs arrive every second the offset is
    re-levelled, so even the wrong sign would only saw-tooth by 138 ppm × 1 s.
- **Absent, not neutral,** on SRT and NDI: no fit object is constructed. Every session logs one
  `[*-SRFIT] session:` line naming its case; HLS logs its line at connect.
- **Logging:** a `[WHEP-SRFIT] window` line after every steering window, and a session summary on
  close.
- `swift test`: 62 of 62 (19 new). Profile and Release build clean.

### 15.1 The derived numbers

| | value | where it comes from |
|---|---|---|
| slope window / offset window | **600 s / 60 s** | "≥ 300 s" (§2.6); 60 s from Cloudflare's wander floor (§2.6) |
| **slope SE bound** | **10 ppm**; released above 20; clamp ±150 ppm | The slope reaches lip-sync only by extrapolating the offset from its window's centre: ≤ 30 s plus one SR interval (≤ 7.5 s, RFC 3550 §6.3.1). 2σ × 10 ppm × 37.5 s = 0.75 ms, under half of Cloudflare's ~2 ms wander floor and 1/20 of §5.3's ±15 ms. Also §2.2's condition for a measured slope |
| slope SE | white-noise OLS SE × √v, v the batch-means ratio of the residuals in 30 s batches, ≥ 4 batches | Cloudflare's residual is not white (§2.6); a white-noise SE would claim precision the data does not have |
| **outliers** | rejected beyond **5 × max(s, 1/48000 s)** once 10 pairs are in the fit; counted | Gaussian false rejection 5.7e-7 per pair, ~1 per 20 days at 1 pair/s. The floor is one audio sample |
| a step in Δ | **8 consecutive** rejections whose own sd is within the bound → the fit restarts on the new level | |
| **unstable** | offset SE > **5 ms**, or ≥ **5 scattered** rejections in the last 20, or 8 consecutive rejections that disagree with each other → the **last good line** (verified by ≥ 10 pairs), **else 0** | 5 ms is a third of §5.3's ±15 ms; Cloudflare measures ~1.2 ms |
| gap | no pair for **10 s** of video content time → logged; the line extrapolates on its slope | beyond the 7.5 s longest compliant SR interval |
| **SR gate** | **1.5 s** after the first presentation (was 2 s, §12.2) | below |

**The gate, re-derived now that it needs both streams.**
- Measured over eight earlier WHEP connects:
  - both servers send SRs on both streams at exactly 1.0 per second;
  - the first pair was computable +27 … +37 ms after the session opened on MediaMTX, +1106 … +1108 ms
    on Cloudflare (which sends both SRs in one compound packet);
  - the latest first SR against the first presentation was +23 ms.
- A sender at a 1 s interval randomised ×1.5 reports within 1.5 s of starting a stream, and each
  stream starts ≥ 0.29 s before the first presentation. The two streams run in parallel, so waiting
  for both does not lengthen it.
- The fallback logs the missing stream(s) against RFC 3550 §6.4.1 and anchors at offset 0. A late
  pair then starts the fit, and the target moves by the first offset: loop error, or one coarse
  write if it is > 50 ms.

**The largest single update step on Cloudflare's noise.**
- **Predicted before the runs**, by replaying the recorded 30-min OBS → Cloudflare Δ series through
  this code: 4.2 ms at pair 2, 2.2 ms after the first 60 s (the slope switching into use), p99
  0.65 ms. In theory pair 2's step has sd 6.7 ms (≈ 20 ms at 3σ); once the offset window is full a
  step is bounded by 2 × 5 × s / 60 ≈ 1.6 ms.
- **Measured:** 2.4 ms (run 1) and **5.6 ms** (run 2, inside the first 60 s); 2.4 and 2.3 ms after
  60 s. Median per window 0.37 and 0.35 ms. All far below the 50 ms step trigger. 0 coarse events.
- **The replay found one defect before any run.** On the 4e-1 MediaMTX log, a real 0.3 ms shift in Δ
  was called "unstable" (5 of 20 rejected) before the step test could see 8 consecutive. The rate
  check now excludes the current consecutive run.
- **A unit test found another:** the SDP CNAME parser never split lines. SDP ends lines in CRLF, and
  Swift reads `"\r\n"` as one `Character`.

**Known cost:** until the slope qualifies (191–220 s on Cloudflare here; ~90 s on a clean sender) the
offset lags a 69 ppm line by ≤ 69 ppm × 30 s ≈ 2 ms. The integrator absorbs the rest.

### 15.2 Two OBS → Cloudflare WHEP runs

**Protocol:** Profile build, unsigned (`.build-cc/step4e2-Profile`), telemetry on. OBS on this Mac at
23.976 ("24 NTSC") over WHIP to Cloudflare, looping the flash-beep fixture. One connect, about 37 min,
disconnect, quit. Logs: `~/Desktop/step4e2-cloudflare.log` (run 1, 2225 s),
`~/Desktop/step4e2-cloudflare-2.log` (run 2, 2209 s). Analysis:
`~/Desktop/manifold-avsync/step4e2_analyse.py`. Tail figures are t ≥ 600 s.

| | run 1 | run 2 | before 4e-2 (§13.3) |
|---|---|---|---|
| **fitted slope** (session end) | **+67.66 ± 1.94 ppm** | **+68.04 ± 1.82 ppm** | +69.2 ± 0.3 (probe, §2.6) |
| slope in use from | video t = 220 s | 191 s | — |
| pairs accepted / rejected | 601 / 0 | 600 / 0 | — |
| steps · unstable · gaps | 0 · 0 · 0 | 0 · 0 · 0 | — |
| offset, start → end | −41.7 → +115.3 ms | −69.3 → +88.1 ms | — (not applied) |
| **integrator `i`** | **+4.8 ppm** (median +5.0), event excluded; 5-min blocks +11.2 / +2.0 / +6.6 / −2.7 / −3.2 / +13.0 | **+6.3 ppm** (−39 … +60) | **−59.9** |
| **renderer depth** | **+1.7 ms over 2122 s** (+0.78 ± 0.16 ppm), event excluded; −4.0 ms whole session | **+1.1 ms over 2149 s** (+0.53 ± 0.10 ppm); 418.5 … 423.3 ms | −142 ms over 1902 s |
| **`e` p99 (§5.3: ±15 ms)** | 6 windows fail, **all in the event**; otherwise max +14.46, p01 min −11.29 ms | **max +10.16 ms**, p01 min −3.91; none fail | worst window +7.25, event excluded |
| writes · coarse · non-zero `setRate` | 1 · 0 · 1 | 1 · 0 · 1 | 1 · 0 · 1 |
| slew limit binding | 211 of 222 windows | 207 of 220 | 154 of 190 |

- **Every log criterion passes on run 2**, and on run 1 outside its one event.
- **OBS did not send ~0 ppm on either run** (+67.7 and +68.0), so both exercised the fix.
- **The offset moved 157 ms (run 1) and 157 ms (run 2) over the session.** That is 67–68 ppm × ~2200 s:
  the lip-sync drift §13.3 found uncorrected, now carried in the target.
- **The integrator now settles where the plant says.** With the SR line, `i = δd − ε_a − c`
  (§13.3's decomposition with the video half cancelled). +4.8 and +6.3 ppm fall in the predicted
  +5 … +10, against −60 before.
- **SDP CNAMEs differed on both runs** ("DIpWmpWy" / "TrzVKtzp", "SDGkBGCW" / "VwMYQWtN"). Logged
  once, applied anyway (§2.6 decision b).

**The ~15 ppm gap (§2.6, "for the post-4e soak") is resolved, by inference.**
- The absolute renderer depth, which uses no wall clock, drifts **0.78 and 0.53 ppm**.
- The −84 ppm lead drain against the +69.2 ppm SR slope came from the lead *reconstructed* from
  wall-clock-timed frame counts. That reconstruction carries the Mac's NTP frequency correction.
- So the ~15 ppm was most likely a wall-clock artefact of the old instrument, not something moving
  the queue. Inference: the depth figure removes the wall clock; it does not measure the correction.

**Startup gate:**

| | run 1 | run 2 |
|---|---|---|
| first mapping | +607 ms | +1290 |
| first presentation | +921 | +1577 |
| first SR pair | +1108 | +1079 |
| anchor | +1115 | +1584 |
| opened on | **the SR pair** | the presentation |
| **audio after picture** | **194 ms** | 7 ms |
| first offset | −41.737 ms | −69.300 ms |

- **Run 1 is the first measured connect on which the SR pair was the last thing awaited by more than
  a few ms:** it came 187 ms after the first presentation, so audio started 194 ms after the picture.
  The previous worst was +23 ms (§12.2). Still 8× inside the 1.5 s bound. No fallback fired.
- Run 2 opened on the picture, with the pair already 498 ms old.

### 15.3 ⚠️ Run 1's +1652 s event — the second field case of §13.4

The same class as §13.4's 2026-09-26 case, and unrelated to the SR line (the fit logged 0 rejections,
0 unstable, and no offset step over 2.4 ms in the session).
- **What happened:** depth fell from ~420 to 306 ms; LiveClock pinned at −0.5% with `publication
  starved` for 3.0 s.
- **What the loop did:** ρ at the −2000 ppm bound for ~50 s (6 saturated windows); `e` peaked at
  **+81.8 ms** (audio ahead); every window was inside ±5.7 ms from +1722 s, ~70 s after onset. `i`
  was held at +133.8 ppm while saturated and overshot to +413.6 ppm on release, back near +40 about
  80 s after release.
- **No coarse trigger fired**, correctly by the rules: a ramp, not a step, and under the 250 ms level.
- **It caused every window of run 1 that failed §5.3.**

**n = 2 now** (§13.4: peak +106.6 ms; this one: +81.8 ms), in about 106 min of Cloudflare WHEP
across the three long runs. Carried to the step 8 decision on B, S, and whether a sustained
LiveClock rail should reach the coarse branch.

### 15.4 Criterion 12 — device-level A/V, start against end of the same session

**Protocol (run 2):** the §1.2 recorder (OBS profile "Recorder", collection "AV Capture"), Display
Capture + macOS Audio Capture scoped to Manifold, at **60 fps**. Two 120 s captures, started at about
+6 min and +34 min, about 1700 s apart. Analysed with `avsync.py`; the two gates it does not print
(one burst per beep, level between beeps) computed with its own functions. The analyser's
injected-offset gate passed first: 0 / +250 / −120 ms → −0.0 / +250.0 / −120.0, sd 0.0.

| | start | end |
|---|---|---|
| audio present | max −27.8 dB | max −27.8 dB |
| gate: beep count | 124 in 124.5 s ✅ | 125 in 124.7 s ✅ |
| gate: 1 Hz grid | median residual 0.35 ms ✅ | 1.02 ms ✅ (one step, below) |
| gate: one burst per beep | 0 of 124 doubled ✅ | 0 of 125 doubled ✅ |
| gate: level between beeps | −105.6 dB RMS, peak −90.8 ✅ | the same ✅ |
| usable pairs | 119 | 113 (6 excluded, below) |
| **A/V offset, mean** | **+27.75 ± 1.13 ms** | **+28.44 ± 1.26 ms** |

**Start → end: +0.69 ± 1.69 ms (mean), +1.5 ms (median). Pass (≤ 10 ms).** Without the SR line the
same interval would have drifted about **−115 ms** (68 ppm × 1700 s, audio gaining on the picture).

- **Why the mean, not the median.** Within each capture the offset is a ~40 ms sawtooth with a ~41 s
  period (10 s means in the end capture: +7, +18, +41, +31, +20, +14, +44, …). That is §1.4's
  frame-grid term: the 25p fixture's whole-second flash slides through the 23.976 stream's frame grid
  by 0.024 frame per second, one 41.7 ms frame every 41.7 s. A 124 s capture spans 2.97 periods, so
  the mean averages it out; the median is pulled ~6 ms low by the sawtooth's shape. Both captures
  carry it identically.
- **Excluded: one recorder-side audio step.** About 5 s into the end capture one beep spacing is
  1021.3 ms and the rest are 1000.0 — a single step of 1024 samples, the recorder's AAC frame, not
  Opus's 960. Manifold's renderer axis was contiguous through it (every buffer `gap=+0.0 µs`,
  cumulative 0, no coarse event, no axis break). The 6 beeps before it are excluded. Included, the
  result is −0.8 ms: a pass either way.
- **What this does not measure:** the absolute ±20 ms against a same-session file control. The
  absolute **+28 ms is suggestive only.** It sits near the +29.6 ms file control of 2026-09-23
  (`AV_SYNC_FINDINGS.md` §1.3), but that was another day with a 30 fps recorder, and every absolute
  figure here carries the capture chain's constant.
- **A first attempt at this capture (run 1) was void:** both audio tracks were digital silence
  (−91.0 dB) because the recorder's audio source still named a previous Manifold PID (§1.5's known
  failure). Manifold's log showed 2224 s of audio decoded and rendering. The protocol now has a
  preflight for it (`AV_SYNC_FINDINGS.md` §1.2).

### 15.5 For step 8

- **The integrator is noisier than before 4e-2.** Window-to-window sd of `i`: **31 ppm** (run 1,
  event excluded) and **18 ppm** (run 2), against about ±10 ppm on the pre-4e soak (§13.3).
  - Cause, by inference: each re-levelling of the offset (median 0.35 ms per window) reaches the loop
    as error, and the integrator follows it.
  - Inaudible at these sizes. It is a tuning figure, alongside §13.2's slew binding, which rose from
    154 of 190 windows to 207–211 of ~220.
- **The §13.4 rail event, n = 2** (§15.3): B, S, and the coarse branch.
- **MediaMTX verification of the SR line is pending.** Both runs here are Cloudflare; `CLAUDE.md`
  requires every streaming fix verified against a non-Cloudflare server. Folded into the step 8 soak.
