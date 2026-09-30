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
  mutes. ~~Cost is a few ms of cross-faded material, once, against today's 78 ms of digital
  silence.~~ **CORRECTED 2026-09-27 by measurement (§16.4):** a splice costs **the jump's size in
  programme**, 200 ms dropped or replayed, and it is different content from what the picture drops,
  because the splice acts at the stage's input, one renderer queue ahead of what is heard. Until the
  splice is heard there are **~0.3–0.5 s of transient offset**. It still writes nothing to the
  renderer: splicing at the output would need a flush (silence until refilled) or a timebase write
  (a mute, §11.11).
* **Transport-agnostic.** It keys off the measured error step, not off `LiveClock.Event`, so it
  works for NDI — which produces no events — and for an input-axis re-pin
  (`SRTFrameRouter.audioPTSTicks`'s 25 ms tolerance), which is the same class of step arriving by a
  different door. **CORRECTED 2026-09-27 (§16.1):** a re-pin under 1 s never steps the error; the
  stage bridges it with its timing kept. See §4.1 item 2.
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

> ~~**Inference, not measurement:** that a 5–10 ms cross-faded splice at snap cadence is preferable to
> a 78 ms mute. It is strongly implied — the mute is 8–15× longer and is *exact digital zero*, while
> a cross-fade preserves envelope — but it has not been captured. The instrument to settle it exists
> (§11.9) and step 5 of the build plan does.~~
>
> **MEASURED 2026-09-27 (§16).** The splice produced **0 mutes** and **no digital-silence run** at the
> device across six forced 200 ms splices, and lip-sync returned to within +0.7 ms of its pre-splice
> value after each direction. The premise of the inference was wrong on cost, though: see the
> corrected bullet above.

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
   **CORRECTED 2026-09-27 (§16.1):** it does not. Since step 3 the stage bridges an input step of up
   to 1 s with a silence fill or a drop and keeps its timing, so `err` never steps and no splice
   results. Only a re-pin past 1 s (a stage axis BREAK) can reach the coarse branch.
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

📌 **FROM 2026-09-28 THE ±20 ms IS GATED ON THE GRID-CORRECTED FIGURE** (decided by Robbie, §18.3).
The 25p fixture rendered by a 23.976 sender reaches the stream up to one frame late, uniformly, so a
live capture averaged over whole 41.7 s grid periods reads **20.0 ms** more audio-early than the
file control (the mean delay of a caught 40 ms flash). "As written" includes that sender artefact;
grid-corrected (whole-period mean + 20.0 ms) does not. Both are reported; the corrected one gates.

📌 **FROM 2026-09-29 THE SESSION'S DRIFT IS GATED FROM THE SESSION START** (decided by Robbie, §18.9).
Lip-sync at +26 min relative to the session start must be within **±10 ms**. It is measured as
(capture B − capture A) + (the log's median queue depth at capture A − its median at 60–120 s after
the connect). The ±20 ms above still gates each capture. Capture A → B is reported, not gated: on
SRs that lag the media, lip-sync has already walked by capture A, and a correction that restores
the session start would fail A → B by exactly that head start.

📌 **FROM 2026-09-29, A STREAM THAT CARRIES ITS OWN A/V OFFSET IS READ AS DEVICE − STREAM** (§18.13).
When the source's own timestamps put audio off its picture (Cloudflare SRT: ~70–80 ms early), the
±20 ms judges Manifold, not the sender: the absolute is reported, and a same-session stream probe
(`probe_av.py`, both streams on the file's PTS) is subtracted for the gate.
- **✅ ACCEPTED 2026-09-30 (Robbie) as the gate**, not only a reading, on one condition: the stream
  offset must have been MEASURED. device − stream is judged only when that session's stream probe
  exists. Without it, nothing is subtracted, and the absolute figure is what the ±20 ms judges.

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

✅ **DONE 2026-09-27 — §16.** Local SRT, forced ±200 ms video jumps: 0 mutes, 1 non-zero `setRate`
per session, every splice matched to its event, device splices equal to the logged frame counts, and
A/V back to within ±1 ms of pre-splice. What was not measured: a splice caused by a real snap, freeze
guard or queue-full (none fired), and any transport but local SRT.

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

✅ **DONE 2026-09-27 — §17.** The dead gate is gone, the heartbeat's reason is re-derived from the
code, and the tripwire now watches ρ at ±B. One deviation, by decision: the 10 ms survives as
`pinnedPositionBranchTolerance`, owned by the pinned back-out switch, which goes in the pre-ship pass
(`BUGS.md`).

### Step 8 — soak and the full matrix

30 minutes per transport, the full §6.3 criteria list, all three §6.1 preconditions verified per run.
Then a multi-hour run on one transport for the drift bound.

**IN PROGRESS — §18.** NDI accepted 2026-09-28, after two NDI fixes the run itself found. Local SRT,
MediaMTX WHEP, HLS, Cloudflare WHEP, Cloudflare SRT and the overnight run are to follow.

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

#### The §13.4 tally, for the B / S / rail-to-coarse decision (updated 2026-09-29)

| # | run | when | delivery at the event | ρ at ±B | peak \|e\| |
|---|---|---|---|---|---|
| 1 | Cloudflare WHEP soak (§13.3) | +1572 s | both streams under-delivered ~3 s, sequence-continuous | ~70 s | +106.6 ms |
| 2 | 4e-2 Cloudflare run 1 (§15.3) | +1652 s | as above | ~50 s | +81.8 ms |
| 3 | local SRT (§16.6, startup rail) | ~+20 s | — | — | — |
| 4 | step 8 MediaMTX WHEP (§18.5) | +430 s | publication starved 3.0 s | 2.4 s | +25 ms |
| 5 | 4.5 h Cloudflare (§18.8) | +7:17 | **both streams paused ~4 s**, sequence-continuous (BUGS.md) | 0 | +19.7 ms (and a 4.0 s mute) |
| 6 | 〃 | +36:15 | video 22/25 per 5-s window, backlog −0.04 s; audio steady 50 pkt/s | 2 windows | +27.1 ms |
| 7 | 〃 | +1:40:26 | video 22/25, backlog −0.08 s; audio steady | 22.4 s (logged) | **+51.8 ms** |
| 8 | 〃 | +2:35:57 | video 21/26, backlog −0.03 s; audio steady | 0 | +23.1 ms |
| 9 | 〃 | +3:38:54 | video 19/27 in one second, backlog −0.04 s; audio steady | 7.1 s (logged) | +32.9 ms |

Every one logged `publication starved ~3 s` with LiveClock at ±0.5 %.

**⚠️ New on 2026-09-29: events 6–9 had no delivery shortfall worth the name.** Each was a jitter burst
of a frame or two, 30–80 ms of backlog, with no underrun and audio arriving at a steady rate. Yet
LiveClock still starved publication for 3 s and railed, the renderer's audio queue dipped to
190–320 ms, and the loop took up to 52 ms of lip-sync error. So in these four, LiveClock's own
reaction to small jitter is the amplifier, not the network. Recorded as observed, not diagnosed.

Rate: 5 in 4.5 h on Cloudflare, about 1.1 per hour.


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

## 16. Step 5 results — the splice, measured 2026-09-27

**Built:** the coarse branch's action is now a splice in the material (§2.4). The triggers are
unchanged: level |e_f| > 250 ms, step |Δe| > 50 ms.
- **`LiveAudioSplicer`** (`Packages/ManifoldCore/Sources/LiveAudioResample/`), one per stage session,
  in front of the resampler. It jumps the stage's INPUT read position by ±N frames across an
  equal-power fade and keeps ~1 s of history for inserts.
- **The output axis is untouched,** because it counts output frames. A splice changes only which
  content those frames carry. **No rate write**, ever; the session's only non-zero `setRate` is the
  first anchor. `e_f` is reset and `i` held, as before.
- **The content-time map follows the splice.** A block whose fed span crosses a splice is recorded as
  two breakpoints, so `inputTime(atOutputTime:)` reports the splice when it is heard, not when it is
  requested. The steering reads `content + spliceCorrectionAhead`, which is continuous across the
  moment it is heard, so a splice needs no settle window and cannot fire a reverse event on itself.
- **Matching (§2.4: an unmatched splice is a defect).** `LiveClock.onPositionJump` reports every
  snap-to-live, freeze-guard, queue-full and target step, **before** it publishes the moved mapping.
  The transports report `axis RE-PINNED`, the stage reports its own `axis BREAK`, and WHEP reports a
  first SR pair that arrived after the gate gave up on it. Each splice takes the newest unused event
  from the 1.5 s before it; with none, its line says `WARNING: UNMATCHED`.
- **Logging:** one `[*-RESAMPLE] SPLICE #n` line per splice: direction, frames and ms, trigger with
  e and e_f, host time, fade, renderer queue depth, and the matched event with its own figures. The
  steering window and END lines add splices (drop / insert), ms spliced, fallbacks and unmatched. The
  `session: writes N = first N + coarse N` prefix is kept, so `step4e2_analyse.py` still parses it;
  `coarse` now counts fallback re-anchors only.
- **Debug-only, pre-ship removal (`BUGS.md`):** Debug ▸ Force Video Jump steps the live push source's
  LiveClock target by ±0.2 s through `adjustTargetDepth`, which re-anchors the mapping as a snap does.
  It is a real video-timeline jump, not an injected error step.
- `swift test`: 74 of 74 (9 splice tests and 4 steering tests new). Profile builds clean.

### 16.1 The decisions

**Which events produce which splice** — from the code and every saved log since step 3 (~5 h):

| event | direction | size | reaches the coarse branch? | seen in the saved logs |
|---|---|---|---|---|
| snap-to-live | forward → **drop** | ≥ 200 ms (fires at target + 0.2 s) | yes | 0 |
| freeze guard | forward → **drop** | to `newest − target` | yes | 0 |
| queue-full | forward → **drop** | depth before − target | yes | 0 |
| target step (⌃⌥[ ⌃⌥], Force Video Jump) | either | ±50 ms / ±200 ms | yes | — |
| late first SR pair (WHEP) | either | the first SR offset | yes | 0 |
| startup realign | either | 2–143 ms | **no**: always before the first anchor (§2.7); not recorded for matching | many |
| SRT/NDI axis re-pin | either | ≥ 25 ms | **no** while under 1 s: the stage's bridge keeps its timing (§11) | SRT 0, NDI 2 (startup) |
| WHEP lost packet | hole | 20/40/60 ms | no: bridged as silence, a content hole | up to 10 per session |

A re-pin is **not** a splice, contrary to §2.4 and §4.1 item 2 as written. Since step 3 the stage
bridges every input step up to 1 s with a silence fill or a drop and keeps the timing, so the
content-time error never steps. The stage cannot tell a re-pin from a lost packet, so step 5 leaves
the bridge as it is; its hard edges are an open follow-up in `BUGS.md`. A re-pin past 1 s is a stage
axis BREAK, which can step the error, so it is on record for matching.

**How each splice is done:**

| decision | choice | why |
|---|---|---|
| what an insert contains | **replayed material**: the read position jumps back \|N\| and replays from history | Cross-faded silence at 50–300 ms is a run of digital zero up to 2.5× the 78 ms mute this step removes, and the §11.9 harness counts it as a mute. Replay keeps level and envelope; its cost is that \|N\| of programme is heard twice (a repeated syllable on speech at 200 ms). Time-stretching (WSOLA) was rejected: material-dependent, and not correct by construction |
| fade | **10 ms equal-power** (cos/sin), 480 frames at 48 kHz | The long end of §2.4's 5–10 ms: half the edge slope of 5 ms. Its costs are small here: 10 ms of two positions overlapping, under the ~20 ms where an overlap reads as a doubled onset, and 10 ms of waiting for material before an insert, against a 250–520 ms renderer queue. Equal-power because at ≥ 50 ms the two positions are uncorrelated on programme; on a steady tone the fade can dip or rise up to +3 dB for its 10 ms |
| too large: \|e\| > 1 s | **fall back to the step-4 re-anchor**, logged `COARSE RE-ANCHOR` and counted | A 1 s replay is a sentence heard twice. The same 1 s sizes the history (3.4 MB at 48 kHz × 16) |
| too large: drop + fade + 50 ms > renderer queue | **fall back**, the same way | A drop feeds nothing while its material arrives, about its own length, and the renderer plays that out of its queue. If the queue runs dry, the output axis falls behind the timebase, every later buffer arrives late, and the loop, which reads what was enqueued, cannot see it. The events that cause drops over-fill the queue by the same amount, so this should not fire |

**Measured in `swift test`:**
- frame counts exact for ±9600 and ±2401-frame splices; outside the fade every sample is input
  tick + N, bit for bit;
- the output axis contiguous through both directions, across 256-frame buffers and back-to-back
  splices;
- cos² + sin² = 1 within 1e-6 at every frame of the fade;
- a 1 kHz sine at A = 0.5 through a drop and an insert landing 82° and 36° out of phase: largest
  sample step **0.087**, against a bound of 1.5 × the sine's own largest step (0.098). A hard cut at
  the same points would step 0.561.

### 16.2 Session A — device output, local SRT (OBS listener), 2026-09-27

**Protocol:** §11.5, with two changes. Audio Hijack was started **after** connecting, so no
disconnect was needed (OBS hangs when Manifold disconnects from its listener, `BUGS.md`). Debug ▸
Force Video Jump alternated BACK and FORWARD every 30 s, six jumps in 211.5 s of capture.

**Gates:**
- Injected-fault gate: PASS, both gates.
- Out-of-band energy above 15 kHz: **0.0000%**.
- One Manifold instance; median block correlation 0.983.

| | result |
|---|---|
| mutes / digital-silence runs | **0** (0.00 / min) |
| dropouts, tempo steps | 0 |
| splices at the device | **6**, 3 of each sign |
| **device vs log, samples** | −9625.0 / +9525.9 / −9651.1 / +9520.9 / −9638.1 / +9555.9 against INSERT 9625 / DROP 9526 / INSERT 9651 / DROP 9521 / INSERT 9638 / DROP 9556 fr. **Equal to the frame** |
| non-zero `setRate` rows | **1**, the first anchor |
| SPLICE lines | 6, 198.4–201.1 ms, each matched to its `target-step` 10–40 ms after it |
| WARNING / fallback / abandoned | 0 / 0 / 0 |
| e across each splice | one ±200 ms trigger read, ±3 ms otherwise; no second coarse event |
| ρ around the splices | within ±220 ppm |

Drops are heard about 0.19 s later than inserts, relative to their requests: the drop waits for its
material to arrive, as designed.

### 16.3 Session B — flash-beep, local SRT (OBS listener), 2026-09-27

**Protocol:** §15.4's. Recorder at 60 fps, beeps −27.9 dB on the preflight, sender at 23.976.
Force Video Jump BACK at 53.0 s and FORWARD at 102.4 s into a 152.1 s capture. The capture was cut
into three windows of **exactly 41.7 s**, one frame-grid period each, so §15.4's ~40 ms sawtooth
averages out. Each post-splice window starts 3 s after its jump.

| window | A/V mean | Δ vs pre | median | sd | pairs |
|---|---|---|---|---|---|
| pre (3.0–44.7 s) | −50.3 ms | — | −51.0 | 12.3 | 40 |
| after BACK (56.0–97.7 s) | −49.6 ms | **+0.7 ms** | −50.7 | 12.6 | 39 |
| after FORWARD (105.5–147.2 s) | −50.0 ms | **+0.3 ms** | −50.9 | 13.1 | 41 |

**Pass: both within ±10 ms.**

**Gates:**
- Analyser injected-offset gate: pre's −50.3 read **+199.7** with +250 injected and **−170.3** with −120,
  sd unchanged.
- Beep count and 1 Hz grid: PASS in every window, residual ≤ 0.58 ms.
- One burst per beep: 0 doubled of 151.
- Level between beeps: exact digital zero.

**Log:** 1 non-zero `setRate` row; SPLICE #1 INSERT 9603 fr / 200.1 ms and SPLICE #2 DROP 9572 fr /
199.4 ms, matched 14 and 34 ms after their target steps; 0 WARNING, fallback or abandoned;
max |ρ−1| 104 ppm.

**At the splices, in the full capture:**
- BACK: the beeps and the flashes each show one 1.2 s gap.
- FORWARD: the flashes show one 0.8 s gap, but the beeps show **1.8 s**. One beep is missing. §16.4
  says why.

### 16.4 ⚠️ CORRECTED — what a splice costs

§2.4 inferred that a splice costs "a few ms of cross-faded material". **Measured, it costs 200 ms of
programme, and briefly the lip-sync:**
- **The programme:** a 200 ms splice drops or replays 200 ms of sound. It is **different content
  from what the picture drops**. The picture jumps at its playhead; the splice acts at the stage's
  input, one renderer queue ahead of what is being heard (317–322 ms at the inserts here, 518–525 ms
  at the drops). Session B's FORWARD drop removed a beep whose flash the picture kept. On programme, a
  forward splice removes 200 ms of sound the picture did not remove, and a backward one repeats
  200 ms the picture merely held on.
- **The lip-sync:** until the splice is heard, about one renderer queue later, the audio is still
  off by the jump: **~0.3–0.5 s of transient offset**, 200 ms at these sizes. The windows in §16.3
  start 3 s after each jump and measure the settled state.

**Why it cannot be done at the output.** Only the material not yet enqueued can be spliced. Removing
or repeating what the renderer already holds means flushing its queue, which is a silence until it
refills, or moving the timebase, which is a rate write, and every rate write mutes (§11.11, 19 of 19).
Either is the mute this step removes. Splicing at the input is the only splice available that writes
nothing to the renderer, and its cost is the queue's depth in delay.

### 16.5 The detector, changed for this step, and its gates

Both changes were gated before any capture was read with them.
1. **Search window ±24000 samples (500 ms), not the default ±6000.**
   - A 200 ms splice is 9600 samples, past the default window. The tracker lost lock at the first
     splice and reported a 27 s dropout and seven "tempo steps" from −1850 to +1271 cents.
   - The runbook's injected-fault gate only goes up to 480 samples, so it could not show this.
   - **Gate:** the same failure on six synthetic ±9600-sample splices at ±6000. At ±24000, all six
     found at exactly ±9600.0, and 0 events on the known-good control.
2. **A self-concatenated reference** (`ref-300s` twice, 600 s), aligned on the single reference and
   tracked on the doubled one.
   - Ref was looping in OBS, so the reference wrapped from 300 s to 0 about 88 s into the capture.
     The tracker cannot follow a −300 s jump.
   - The doubled reference has two identical copies, so coarse alignment on it can pick the second.
     Hence aligning on the single reference and passing that offset in.
   - **Gate:** six synthetic splices across a looped play from 211 s, all six at ±9600.0; the
     known-good looped control, 0 events.

The analyser's own gate also needed fixing: `-itsoffset` with `-c copy` applied no shift, and the
+250 ms file read exactly the same as the unshifted one. The shift is now baked into the audio
samples (`adelay`, and `atrim` for a negative one). Both are in the §11.9 runbook.

### 16.6 For step 8

- **The startup rail, now seen on local SRT — n = 3** with §13.4 and §15.3. About 20 s after the
  session-A connect:
  - LiveClock's depth fell 0.250 → 0.205 s, and the clock pinned at −0.5% with `publication starved`
    for 3.0 s;
  - ρ sat at the −2000 ppm bound for ~20 s; `e` peaked at **+46.7 ms** (audio ahead);
  - `i` overshot to +386.6 ppm on release, and `e` was back inside ±5 ms ~50 s after onset.
  No coarse trigger, correctly. It was before the recording and unrelated to the splices. It is the
  first case on a local, non-Cloudflare path, so it is not a Cloudflare delivery artefact. Session B
  had none (max |ρ−1| 104 ppm). Carried to the step 8 decision on B, S, and whether a sustained
  LiveClock rail should reach the coarse branch.
- **Criterion 12: the absolute A/V figures disagree.** Local SRT read **−50 ms** here (audio early);
  Cloudflare WHEP read **+28 ms** in §15.4. Neither run had a same-session file control, so
  neither is interpretable alone: both include the capture chain's constant. Step 8 needs a
  same-session file control on each transport before any absolute figure means anything. Only the
  step-5 differences (+0.7 / +0.3 ms) are measured.
- **The splice's cost (§16.4)** is a design fact, not a defect. If snaps become frequent in the field,
  the 200 ms per event and the half-second of transient offset are what to weigh against them.

## 17. Step 7 results — dead code out, the heartbeat re-derived, the tripwire re-pointed, 2026-09-27

**No behaviour change on the loop.** `swift test` 77 of 77 (3 new). Profile and Release build; a
clean Release build shows no new warnings.

### 17.1 Removed

| removed | where (pre-step-7 lines) | dead since |
|---|---|---|
| `liveAudioRateThreshold` (0.0002) | `FrameEngine.swift:2553–2564` | step 3: the rate branch was disabled; nothing read it |
| `liveAudioPositionTolerance` (0.010) | `FrameEngine.swift:2566–2570` | step 4d: the loop has no position branch. Its only reader was the pinned back-out switch, so the value moved to `pinnedPositionBranchTolerance`, documented as part of that switch |
| `mirror.pushedRate` | declared :2400; set :2250, :2899, :3071; read :2892 | step 3: 1.0 at every assignment |
| `rateToPush` | :2896, and the first-anchor log :2967 | step 3: a constant 1.0 |

- `predicted` is now `pushedMedia + (host − pushedHost)`, bit-identical to the old form (× 1.0 is
  exact).
- **Kept:**
  - `smoothedRate` and its τ constants, as §2.2's logged comparison figure (the paired probe and the
    mirror's stats line). Their docs now say they feed logs only.
  - `pushedMedia` / `pushedHost`, which the pinned switch reads.
- No debug tool was removed (the pinned switch, the PLI trigger, Force Video Jump, the probes, ⌃⌥U).

### 17.2 The heartbeat's reason, re-derived from the code

Written at `LiveClock.onMappingTick`, with pointers in both routers and in `mirrorLiveAudio`.
- **The original reason is gone.** It was installed because the mirror did all its work only inside
  a callback. Since step 4d the loop evaluates per audio buffer, against a line.
- **The step 7 note's guess is gone too.** `smoothedRate` reaches only logs.
- **What still runs only when the mirror is called:**
  - **WHEP's SR-line offset reaching the loop's target.** This is the load-bearing one: a settled or
    railed clock publishes nothing.
  - The first-anchor gate's 5 s and 1.5 s fallbacks (§2.7).
  - The pinned switch's position branch.
  - Log cadence.
- On SRT and NDI in loop mode, only the gate fallback and the logs depend on it.

### 17.3 Comments that stated a dead reason, corrected

- `mirrorLiveAudio`'s header ("the timebase reads what now() reads") and its "anchor faithfully, rate
  slowly" block.
- `anchorLiveAudio`'s two rationale paragraphs, argued from the removed gate.
- The `smoothedNow` note ("what sizes B"), and the paired probe's "the rate the mirror would PUSH"
  (two places).
- NDI's "the one thing that is actually closed", and its tolerance note, which cited both removed
  constants.
- WindowDeck's NDI-substitution note.
- The ⌃⌥U message ("the renderer's rate converges"; it has run at 1.0 since step 3).
- LiveClock's `publication starved` message. It said "audio is covered", false while railed, and
  "drifting free", false now.
- LiveClock's `maxSlew`, `forceUnityRate` and slew-site notes (§17.4).

### 17.4 The rail tripwire

- **The comments:** the slew-site notes used to warn that pinning the video slew would leave WHEP and
  SRT audio uncorrected. They now say the slew no longer corrects audio, and point at ρ at ±B.
- **The runtime line**, in `LiveAudioResampleSteering`, loop mode:
  - `⚠️ RATIO AT ITS RAIL`, once |ρ−1| has been at B for **5 s** without a break, with ρ−1, e, e_f,
    i and the episode number;
  - `ratio OFF its rail after N s`, with peak |e|, when it leaves — only if the ENTER line was logged.
- **Rate limit:** at most **one ENTER line per 60 s**; an episode inside that is counted, not logged.
  So two lines a minute at most, and none for a touch under 5 s.
- **Totals:** the session END line adds seconds at the rail, episodes ≥ 5 s and how many were not
  logged. The window line is unchanged, so `step4e2_analyse.py` still parses it.
- 5 s is a quarter of the shortest field episode measured (§13.4, §15.3, §16.6: 20–70 s).

⚠️ **Exercised by unit tests only so far.** Three tests: one episode gives one ENTER line (at 5.0 s)
and one OFF line, with no action; a touch under 5 s and a drift inside B log nothing; the 60 s rewarn
holds. No rail occurred in the live check, so the first field reading will be step 8's.

### 17.5 Live check — local SRT, 2026-09-27

The step 7 Profile build, one ~150 s session, Force Video Jump BACK then FORWARD.

| | step 7 | step 5 (§16) |
|---|---|---|
| non-zero `setRate` rows / timebase writes | **1 / 1** | 1 / 1 |
| splices | INSERT 9634 fr / 200.7 ms, DROP 9603 fr / 200.1 ms; both matched to their target-steps | the same shape |
| unmatched / WARNING / fallback / abandoned | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| renderer queue at insert / drop | 318.5 / 521.8 ms | 317–322 / 518–525 ms |
| stage holes / overlaps / breaks / clamps | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| heartbeat | ticking: 300 ticks and 1200 mapping changes by the last stats line, 15 stats lines | — |
| rail tripwire | 0 lines, 0.0 s at the rail (none occurred); max \|ρ−1\| 178 ppm | — |

Log: `~/Desktop/step7-srt.log`. The build is `.build-cc/step7-Profile`.

## 18. Step 8 results — the soak and the full matrix, from 2026-09-28

Plan and order as approved on 2026-09-28: NDI first, then local SRT, MediaMTX WHEP (+ a 5-min HLS log
check), Cloudflare WHEP, Cloudflare SRT, and an overnight MediaMTX run with DeckLink on. Each run: a
same-launch file control, flash-beep captures at +3 and +26 min (recorder at 60 fps, sender 23.976),
and 20 min of reference noise at the device from +5:30 (Audio Hijack) for mutes and pitch.

### 18.1 The instrument, and what it found before any transport was judged

- **Test sources are pinned:** `~/Desktop/Manifold-Test-Sources/` holds copies (same SHA-256) of the
  flash-beep fixture and `ref-1200s.wav`, with a README. The fixture is unchanged since 2026-09-23
  14:01, so every control since then played the same bytes.
- **Grid correction (§6.3):** mean over the largest whole number of 41.7 s grid periods, + 20.0 ms.
  The flash timing is a staircase quantised by the 60 Hz display, not a smooth sawtooth; a free-slope
  fit does not model it and was dropped.
- **A file control has a few ms of loop-to-loop spread** (each loop of the 60 s fixture lands its 25p
  frames at a new phase against the display), so a control is the mean over its loops.
- **⚠️ The first NDI run's control read +218 ms and was VOID.** A/B/C controls: pre-resampler build
  fresh launch +27.0, step 8 build fresh launch +24.2, step 8 build after 60 s of NDI **+219.4**. So no
  regression across steps 3–7, and a pre-existing leak: NDI (and HLS, by reading) left the renderer's
  clock set to host time after disconnect, running the next file's picture ~195 ms ahead. Fixed
  2026-09-28, verified for NDI twice (+0.7, +2.7 ms between controls). docs/BUGS.md, "NDI and HLS
  leave the renderer's clock installed after disconnect".
- **Every file control must still come first in a fresh launch** until HLS is verified.

### 18.2 NDI — the two fixes the run required

1. **The 250 ms desktop audio lead was the lip-sync error** (§2.5; +252…+262 ms against a valid
   control). §2.5's "start the axis early" cannot be met on the audio side of a pull source —
   FrameSync hands out audio for NOW — so the PICTURE is held by the lead instead, while the desktop
   plays the programme. Zero while DeckLink owns audio, so SDI is unchanged. Measured hold: 250.2–262.4
   ms pull → display, median 256.0, 0 skipped.
2. **FrameSync's audio queue** (`framesync_audio_queue_depth`, 28–47 ms, different per connection)
   makes every pulled sample that much older than its stamp. The picture is held by `lead + mean
   depth` (`AudioQueueDepthEstimate`: 1 s warm-up, then τ 10 s, republished at ≥ 2 ms). The depth
   never reaches the pull size (the #NDI-AUDIO defect) or the audio stamps.

### 18.3 NDI soak, 2026-09-28 15:40:38–16:09:08 (28.5 min) — ✅ ACCEPTED

Build `.build-cc/ndifix-Profile` (be983a0 + the two NDI fixes). Log `~/Desktop/step8-ndi-soak.log`;
timeline `soak-ndi-timeline.json` (scratchpad). Run automated over obs-websocket (sender 4455,
recorder relaunched with `--websocket_port 4456`).

| | result |
|---|---|
| **criterion 12, as written** (vs file control +24.3 ms) | **+1.3 ms** (+3 min), **+2.9 ms** (+26 min) |
| **criterion 12, grid-corrected — gates from here on** | **+21.3 / +22.9 ms** — accepted; the ~+22 ms is provisionally a sender (OBS/DistroAV) term, open until a non-OBS NDI sender is measured (BUGS.md) |
| start → end | **+1.6 ms** (±10) |
| FrameSync depth vs hold | depth 38.8–40.7 ms all session; hold followed in seven 2 ms steps, 286.3 → 292.3 ms; frame wait 290–303 ms, 0 skipped |
| criterion 1, mutes at the device (20 min) | 3 mutes (102, 68, 10 ms) and 4 dropouts — **sender delivery gaps, not Manifold**: each on a second where FrameSync's queue fell to 0–4 ms while OBS reported 77 delayed frames; pump 87–89 pulls/s, axis contiguous |
| criterion 2, non-zero `setRate` | 1 (the first anchor) |
| criterion 3, e (±10 ms, trend) | e −0.18…+0.07 ms; PAIRED p99 ≤ 0.066 ms; trend −0.002 ± 0.0005 ppm |
| criterion 4, gap histograms | 172 of 172 contiguous |
| criteria 5–6 | stage holes / overlaps / resets / breaks / clamps 0; coarse 0, splices 0, rail episodes 0 |
| criterion 7, pitch | ρ−1 within 8.1 ppm; heard rate −6.0 ppm median (event windows excluded), p1/p99 −173/+190 ppm, max 550; fastest change 0.197 cents/s (≤ 0.35) |
| integrator | +6.37 ppm, sd 0.14 (plant model: the device crystal, as §13.1) |
| criterion 10, CPU (2 ch) | Manifold mean 23.7 %, max 30.7 % |
| §6.1 gates | one PID; out-of-band 0.11 %; beep-count, grid, one-burst and silence gates passed |

**Not measured on this run:** a second control after NDI (the operator had quit), so the control is
the pre-connect one only — 29 beeps, since the fixture stopped once; its +24.3 ms matches every
fresh-launch control of the day (+23.8…+27.0).

**Carried forward:** the ±4–17-sample steps the tracker sees on NDI (137 in 20 min this morning, ~90
here) are an NDI-path trait not yet explained; they set the pitch spread above and are inaudible.

### 18.4 Local SRT soak, 2026-09-28 16:24:32–16:53:02 (28.5 min) — PASS, at a margin the control limits

OBS "SRT Local" as the listener, streamed and stopped by the orchestrator (the sender stops first).
Same build as §18.3. Log `~/Desktop/step8-srt-soak.log`. Controls before AND after, same launch.

| | result |
|---|---|
| file controls | before **+24.6** (loops +27.9 / +23.6 / +20.6), after **+17.5** (loops +22.5 / +17.9 / +15.9); zero used = their mean, **+21.1** |
| **criterion 12, grid-corrected (gates)** | **+17.2 ms** (+3 min), **+15.6 ms** (+26 min) — PASS (±20) |
| criterion 12, as written | −2.8 / −4.4 ms |
| start → end | **−1.6 ms** (±10) |
| criterion 1, mutes at the device (20 min) | **0**: 0 mutes, 0 dropouts, 0 steps of any size, r 0.983 (the only two exact-zero runs are the noise segment's own edges) |
| criterion 2, non-zero `setRate` | 1 (the first anchor) |
| criterion 3, e (±15 ms, trend) | e −4.84…+5.44 ms; PAIRED p99 ≤ 5.38 ms, 0 windows past ±15; trend +0.04 ± 0.08 ppm |
| criterion 4, gap histograms | 171 of 171 contiguous |
| criteria 5–6 | stage holes / overlaps / resets / breaks / clamps 0; coarse 0, splices 0; no snap, freeze guard, queue-full or starved publication |
| criterion 7, pitch | ρ−1 max 411.6 ppm (first window, the startup relay), slew limit binding in 170 of 170 windows (as §13.2); heard rate −9.3 ppm median, p1/p99 −177/+107, max 257; fastest change 0.091 cents/s |
| startup rail (§16.6, n = 3 before) | **none**: first window ρ −371 ppm, never at B; rail episodes 0 |
| integrator | +7.47 ppm median, window sd 17.3 (no SR line on SRT; §13.1 saw +1…+65) |
| criterion 10, CPU (2 ch) | Manifold mean 16.7 %, max 22.2 % |
| §6.1 gates | one PID; out-of-band 0.11 %; all beep gates passed |

⚠️ **THE CONTROL NOW LIMITS THE VERDICT.** The two same-launch controls differ by 7.1 ms, and both
step down ~4.3 ms per loop of the fixture: each 60 s loop restarts its 25p frames at a new phase
against the 60 Hz display, so a 130 s control samples only 2–3 phases of a 16.7 ms cycle. Against the
after-control alone, capture A reads +20.8 ms grid-corrected — 0.8 ms over. The fix is in the
instrument, not the app: controls long enough to cover the display cycle (≥ 5 loops), or the mean of
both controls, which is what is used above. It also means the ±5 ms "controls agree" check is at
the instrument's floor.

**Both OBS transports now read positive grid-corrected** (NDI ≈ +22, local SRT ≈ +16) with
Manifold's own terms ≈ 0 on each, which fits the provisional OBS sender term of §18.3.

### 18.5 MediaMTX WHEP soak, 2026-09-28 17:11:54–17:40:24 — ❌ FAILS start → end (−89 ms)

OBS "MediaMTX Local" → MediaMTX v1.21.1 (config = the plain one + RTSP/HLS on) → Manifold WHEP. 1 s
keyframes (confirmed on a 40 s RTSP probe). Log `~/Desktop/step8-whep-soak.log`. 5-min controls.

| | result |
|---|---|
| file controls | before **+27.9**, after **+25.3** (Δ 2.6 ms — the 5-min controls work); zero +26.6 |
| criterion 12, grid-corrected | **+1.6 ms** (+3 min) ✅, **−87.6 ms** (+26 min) ❌ |
| criterion 12, as written | −18.4 / −107.6 ms |
| **start → end** | **−89 ms** ❌ (±10) — audio gains on the picture at ≈ −64 ppm |
| sender's own A/V (RTSP probe, no player) | −13.1 ms as written, ≈ +6.9 ms grid-corrected at +1 min |
| criterion 1, mutes (20 min) | **0** (only the noise segment's edges) |
| criterion 3 | e −4.9…+25.0 ms; p99 past ±15 in 2 windows, both in the rail event below; trend −0.17 ± 0.28 ppm |
| criteria 2, 4–6 | 1 non-zero `setRate`; 172/172 contiguous; 1 stage hole (2.5 ms, at connect); coarse 0, splices 0 |
| criterion 7, pitch | heard median +58.5 ppm (the loop following video's clock); transient to 1586 ppm in the rail event (inside ±B); fastest change 0.321 cents/s |
| **rail event** (§13.4 class, **n = 4, first on a local server**) | +430 s: LiveClock railed −0.5 %, publication starved 3.0 s; ρ at B for 2.4 s (under the 5 s tripwire); e peak **+25 ms**, recovered in ~20 s |

**Cause, settled 2026-09-28 by two A/B tests and the raw SR pairs:**
- **Not the MediaMTX config** (test 1: plain config, OBS Advanced → SR fit flat, +0.01 ppm, 7 µs) and
  **not the OBS output mode** (test 2: plain config, OBS Simple → flat, 0.00 ppm, 7 µs). OBS 32.2.2 and
  MediaMTX v1.21.1 are unchanged since before 2026-09-23.
- **The media clocks diverge as always:** video RTP +53.6 ppm vs mach, renderer depth −61.8 ppm
  (423 → 328 ms), `i` −58.7 ppm — §13.3's pre-4e-2 decomposition, unchanged.
- **MediaMTX's SRs carry that slope as a STAIRCASE.** The raw per-pair Δ is flat to 7 µs between
  steps, then jumps: 54 steps of +0.3…+3.5 ms, all positive, +72 ms over 1715 s (≈ +42 ppm).
  §6.2's "±0.5 ms of a straight line" was over shorter sessions; its 4–5 ms/min walk is the same
  staircase seen coarsely.
- **The fit (4e-2) cannot see a staircase.** Its step rule treats each jump as a new level and
  restarts with zero slope in every flat; after five steps it declared UNSTABLE and FROZE on the last
  good line (slope 0) for the rest of the session, rejecting 1416 of 1472 pairs. So on MediaMTX the
  SR line never carried the slope, and nothing else corrected it.

**For the design discussion (Robbie, 2026-09-28):**
1. **Freeze vs restart.** A freeze after small steps is worse than a restart — but here a restart
   refits flat too. What would work: fit the slope across steps (a long-window regression that
   treats steps as data, not as level resets), or treat a run of same-signed steps as slope.
2. **An in-app signal besides the SRs:** the renderer-depth slope read −61.8 ppm, matching `i` and
   the video RTP clock within a few ppm. It is standards-free and server-agnostic.
3. **⚠️ Consequence:** at −62 ppm the WHEP audio queue drains ~98 ms / 27 min and would run dry in
   ≈ 1.9 h from 420 ms. **The overnight run cannot be on MediaMTX WHEP until this is fixed.**
4. CLAUDE.md: whatever the fix, it must follow the standard (an SR's NTP↔RTP mapping), log the
   deviation, and never branch on the server.

### 18.6 HLS check, 2026-09-28 17:54–18:07 — leak fix ✅; playback deferred

Manifold could not open MediaMTX's HLS (`connect failed: Cannot Open` after MediaMTX served an
fMP4 muxer with **H.264 + Opus**, behind a `Secure` cookie-check redirect over plain http). Not a
step 8 finding; criterion 11 is deferred to an HLS source Manifold can open. **The HLS leak fix is
verified:** the connect ran through the provider install and the disconnect restored them — file
controls +23.0 before, **+20.3 after (Δ −2.7 ms, ±5)**. docs/BUGS.md's leak entry: both NDI and HLS
now verified.

### 18.7 The SR fit through a staircase, and the depth-slope fallback — written 2026-09-28 evening, replayed, not yet soaked

**Root cause, confirmed in code and by replay.** The outlier and step bounds were
`5 × max(s, 1/48000 s)`, ≈ 104 µs on a 7 µs sender, so every 0.3–3.5 ms stair was rejected. Eight
rejections that agreed with each other made a "step", and the fit restarted from those 8 pairs with
its slope history discarded and the slope out of use. Replaying §18.5's log through HEAD reproduces
the live session: 5 steps, then UNSTABLE, then 1415 rejections, final state holding at slope 0.

**The change** (`SenderReportLineFit`, header "THE NUMBERS"):
- **The bound floor is 5 ms:** a third of §5.3's ±15 ms, the same basis as the offset-SE bound. It
  is a lip-sync tolerance, not a noise figure: a pair within 5 ms of the line cannot by itself take
  the loop out of its band, so it is data. Accepting a real ≤ 5 ms step as data costs ≤ 12.5 ppm of
  slope bias for one window, ≤ 0.5 ms at the 37.5 s extrapolation.
- **A step re-levels, not restarts:** every stored pair shifts by the run's median residual. The
  slope, its SE and its history survive. The step test uses the trailing 8 rejections, so a noise
  burst that ends on a new level still re-levels.
- **Unstable holds the last good slope, and the offset keeps tracking:** it follows the median
  residual of every recent pair, over as many pairs as its own SE ≤ 5 ms needs (60–600 s). Offset 0
  and slope 0 remain only for a session whose line was never good.
- **A slope that loses its SE is held at its last in-use value, never 0.**
- **Safety net, `SenderReportSlopeCrossCheck`:** `offset_applied − depth = b_true·t + c` whatever
  line was applied. Its Theil–Sen slope over 600 s of steering windows is compared with the applied
  slope, once a minute, and a WARNING is logged when they differ by more than 10 ppm (the fit's own
  slope SE bound; 18 ms / 30 min). The steering now calls its companion every window even when
  windows are not reported, so the WARNING reaches a Release log. (Extended into a control fallback
  below, same evening, by Robbie's decision.)

**Replay** (host log time as x; SR pairs formed as the fit forms them). "Drift" is the predicted
change in lip-sync over 30 min: against the SR data, and against the renderer queue's slope from the
same log (`offset − depth`, independent of the applied line).

| log | fit | slope at end | in use | rejected | steps | unstable | slope 0 after first use | max offset step (all / after 60 s) | drift vs SRs | drift vs queue | cross-check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| §18.5 MediaMTX (staircase) | HEAD | 0 applied (fit −0.06) | holding | 1415 | 5 | 1 | 1490 of 1625 pairs | 1.93 / 1.93 ms | −78.9 ms | **−116 ms** | — |
| | new | **+62.32** | ✅ from 91 s | 0 | 0 | 0 | 0 | 0.13 / 0.13 ms | +0.2 ms | **−37 ms** | 11 of 19 WARN, worst +52 ppm |
| 4e-2 Cloudflare run 1 | HEAD = new | +67.70 | from 216 s | 4 | 0 | 0 | 0 | 2.86 / 2.86 ms | +0.2 ms | +0.7 ms | 0 of 27, worst −5.2 |
| 4e-2 Cloudflare run 2 | HEAD = new | +67.95 | from 177 s | 3 | 0 | 0 | 0 | 6.06 / 2.17 ms | −0.0 ms | +0.4 ms | 0 of 27, worst −1.5 |
| srprobe ffmpeg → MediaMTX | HEAD = new | +0.00 | from 91 s | 0 | 0 | 0 | 0 | 0.004 / 0.001 ms | +0.0 ms | — (no depth logged) | — |
| srprobe OBS → Cloudflare | HEAD = new | +65.89 | from 184 s | 0 | 0 | 0 | 0 | 7.30 / 1.85 ms | +0.1 ms | — | — |
| §13.3 soak (`soak133`) | — | not replayable: that build logged only the first SR, no pairs and no depth | | | | | | | | | |

- Cloudflare and ffmpeg are **bit-identical** before and after: their residual sd puts 5·s above the
  floor, and they never step.
- The HEAD prediction for §18.5 (−116 ms / 30 min = −64 ppm) matches the device-level −89 ms over
  23 min measured in §18.5, which validates the queue-slope predictor.
- **MediaMTX's SRs understate the slope:** in 300 s blocks their slope ran 0…+66 ppm while the queue
  held +57…+68. The new fit follows the SRs exactly (+0.2 ms vs SRs), and the remaining −37 ms is the
  SRs' own deviation, which the cross-check WARNs on. Both A/B sessions of §18.5 (`step8-srtest1`
  session 2, `step8-srtest2`) had flat SRs, 0.00 ppm and 7 µs, against a queue draining at −60 and
  −71 ppm. There the fit applies 0, correctly by the SRs, and only the WARNING sees it.
- Rejected 4 / 3 on Cloudflare in replay against 0 live: the replay's x is log time, not video RTP
  time. The same in both builds.

**Tests:** four shapes (white noise, staircase at +54 / −30 / +8 ppm, clean, ±50 ms and +150 ms steps),
burst-then-new-level, and the cross-check (agree, disagree, inside the bound, rail event, cadence,
Release plumbing). The shape tests FAIL against HEAD's fit (checked on a scratch copy) and pass now.
`swift test` 109 / 109; Profile and Release build clean.

#### The depth-slope fallback (decided by Robbie, 2026-09-28 evening)

Use the renderer queue's slope when the SRs are demonstrably wrong; the SRs stay primary.
Implemented in `SenderReportSlopeCrossCheck`, applied by `SenderReportLineFit.evaluate`.

- **Two slopes per check,** both Theil–Sen over the same 600 s of steering windows:
  - `b_depth` = slope of (applied offset − depth), the media's slope;
  - `b_SR` = slope of the SR-derived offset, level walks included: what the SR line actually
    delivers to the target. On a staircase this is the stairs' rate, not the fit's in-window slope.
- **ENGAGE:** |b_depth − b_SR| > 10 ppm with b_depth's SE ≤ 5 ppm, at every check for 10 min.
  - The SE is MAD-σ / (√n·sd t) × √((1+ρ₁)/(1−ρ₁)), ρ₁ the residuals' lag-1 autocorrelation.
  - 5 ppm puts a 10 ppm disagreement ≥ 2 SE out.
- **Engaged:** target offset = SR offset + a correction walking at (b_depth − b_SR).
  - The SR's level and short-term changes are kept; only its long-run slope is replaced.
  - A slope substituted inside the fit's line would do nothing over time: the offset re-levels onto
    the SRs every pair, so the slope only tilts the line within its 60 s window (a constant ~2 ms).
  - The correction is anchored at the start of the evidence (the first disagreeing check's window
    start), so the error accumulated before engaging is removed as well.
  - That back-correction is caught up at ≤ 150 ppm (the slope clamp), so the target never steps.
  - While the catch-up runs, and for one window after it ends, the rate is held and no disengage
    decision is made.
- **DISENGAGE:** |b_depth − b_SR| < 5 ppm for 10 min. The correction is kept, frozen, since dropping
  it would step the target back. A later SR catch-up shows as the opposite disagreement and
  re-engages to unwind it.
- **Logged:** ENGAGE and DISENGAGE with both slopes; `SR DEVIATION` once per session; the fallback's
  episodes, engaged time and final correction in the fit's session END line.
- **No feedback loop.** `offset_applied − D = b_true·t + c` for any applied offset, so the correction
  moves D and the applied offset together and b_depth does not see it. b_SR is read from the SR
  offset, which excludes the correction. Test (`testEngagedCorrectionLeavesTheDepthSlopeUnbiased`,
  closed loop through the real fit, queue following the applied offset through a first-order lag of
  0 / 10 / 30 s): every check that steers stays within 3 SE of the true slope.
  - Measured on the way: without the catch-up hold, the checks whose window spans the catch-up's
    start or end read 2.6 / 12.7 ppm off at τ = 10 / 30 s. That is a Δr·τ hump, a transient and not
    a loop, but the rate integrates, hence the hold.
- **Tests:**
  - engages once on flat SRs with media at +65 ppm (at 1200 s), then the queue returns within 5 ms of
    its start by 1 h;
  - never engages on Cloudflare-like noise, a staircase, or a clean line (1 h each);
  - hysteresis: engages on flat SRs, disengages once 10 min after the SRs start carrying the slope,
    keeps its correction, with no window-to-window step > 6 ms;
  - no oscillation at the bound: media at +10.3 ppm for 2 h, at most one engagement and no
    disengagement.

**Replay, closed loop.** At each logged window the depth the new line would have produced is rebuilt
from the invariant, `depth_new = offset_new − (offset_old − depth_old)`, and fed back to the check.
Lip-sync walk ∝ depth change. The A/B sessions were 161–170 s, too short for a 600 s check, so they
are EXTRAPOLATED: flat SRs at their own 7 µs, with media at their measured queue slope (+61.4 /
+73.0 ppm) and 1 ms of depth noise (4× theirs).

| session | fallback | start → end (+3 → +26 min, medians of the capture windows) | log-only | steady drift / 30 min | worst excursion from +3 min |
|---|---|---|---|---|---|
| §18.5 MediaMTX, staircase | engaged at 1201 s (SR +52.8 vs queue +66.7 ppm) | **−2.0 ms** | −23.4 ms | catch-up still running at the log's end (1716 s) | −22.1 ms (log-only −25.2) |
| A/B 1, flat, extrapolated 28.6 min | engaged at 1200 s (SR 0.0 vs +61.0) | **+4.3 ms** | −85.2 ms | — | −58.6 ms at 1190 s (log-only −89.9) |
| A/B 2, flat, extrapolated 28.6 min | engaged at 1200 s (SR 0.0 vs +73.4) | **−6.7 ms** | −101.4 ms | — | −69.6 ms at 1190 s (log-only −106.9) |
| A/B 1, flat, extrapolated 1 h | same | +5.3 ms | −85.4 ms | **−1.2 ms** | −58.7 ms (log-only −205 at 1 h) |
| A/B 2, flat, extrapolated 1 h | same | −5.9 ms | −101.5 ms | **−1.2 ms** | −69.7 ms (log-only −244 at 1 h) |
| 4e-2 Cloudflare runs 1 and 2 | never | −2.6 / +0.4 ms, **identical** | same | −1.9 / +0.8 ms | run 1 −115 ms = its +1652 s rail event, identical |
| srprobe ffmpeg, srprobe OBS → Cloudflare | never (no depth logged; cannot engage) | fit figures identical to the table above | | | |

- **Both requirements hold:** Cloudflare and ffmpeg never engage and are unchanged; both MediaMTX
  shapes are within ±10 ms start → end.
- **⚠️ The cost is visible mid-session.** On flat SRs, lip-sync walks until the fallback engages at
  ~20 min (10 min to fill the window, then 10 min of sustain), reaching −59 / −70 ms, and is caught
  up by ~28 min. A +26 min capture lands in the catch-up; the start → end figure passes because it
  compares two instants, not because the middle was right.
- The logged "applied slope" is the fit's slope plus the correction's rate (+76.2 ppm on the
  staircase, where b_SR = +52.8 is below the fit's in-window +62.3). It only extrapolates the target
  between 10 Hz evaluations, ≤ 1 µs here.
- `swift test` 114 / 114; Profile and Release build clean. Not committed.

### 18.8 Cloudflare WHEP, 4 h 32 min unattended, 2026-09-28 22:43 → 2026-09-29 03:15 — ✅ PASS, with one upstream 4 s pause

**Protocol.** Build `.build-cc/srfix-Profile`: the §18.7 fit fix plus the depth-slope fallback,
uncommitted. OBS "WHIP Cloudflare" (VideoToolbox H.264, 1 s keyframes, Opus 256 k), 23.976. DeckLink
output off. Log `~/Desktop/srfix-whep-cloudflare-long.log`.
- **Timeline** (self-contained orchestrator, no operator after +26 min):
  - file control 1 (5 min);
  - connect;
  - capture A at +3 min;
  - noise segment +5:30 → +25:30 (Audio Hijack);
  - capture B at +4 h 30 with the stream still up;
  - then OBS stopped streaming over websocket.
- **End of session:** Manifold's media-stall watchdog tore the session down 16 s later: `no media
  for 15s`, DELETE → HTTP 200, and both session END lines. **First observed firing; works.**
- **Control 2:** in the morning, same launch.

| | result | limit | |
|---|---|---|---|
| file controls | before **+24.3**, after **+27.5** ms (Δ +3.2); zero +25.9 | ±5 | ✅ |
| criterion 12, grid-corrected | **−3.2 ms** (+3 min), **−13.0 ms** (+4 h 30) | ±20 | ✅ |
| criterion 12, as written | −23.2 / −32.9 ms | | |
| **start → end** | **−9.8 ms over 4.5 h** | ±10 | ✅ at the edge |
| criterion 1, mutes (20 min) | **1 × 4.0 s** (upstream pause, below), **2 × 20 ms** (single lost Opus packets, stage HOLE events; BUGS.md PLC item) | 0 | ❌ neither is Manifold's; see the two entries |
| criterion 2, non-zero `setRate` | 1 (the first anchor) | | ✅ |
| criterion 3, `e` | all 12 windows outside ±15 ms are inside the 5 rail events; otherwise within about ±5 ms | ±15 | ✅ outside events |
| criteria 5–6 | coarse 0, splices 0, stage holes 19 × 20 ms (lost packets), 1 axis break (the pause) | | ✅ |
| criterion 7, pitch | ρ−1 per window, rail windows excluded: median −3.8 ppm, p1/p99 −248/+200; max \|ρ−1\| 2000 (at B, in the rail events) | | ✅ outside events |
| **rail events** | **5** (§13.4 tally, events 5–9); ρ at B 32.9 s in total, 2 logged episodes (22.4 s, 7.1 s), peak \|e\| 51.8 ms | | ⚠️ for the tuning decision |
| criterion 10, CPU (2 ch) | Manifold mean **7.8 %**, max 27.3 % (4838 samples) | | ✅ |
| RTP timestamp wrap | **none possible**: video would first wrap at 13.3 h (T_v0 1,786,904), audio at 17.9 h (T_a0 1,210,282,106) | | not exercised |

**The SR fit and the fallback over 4.5 h.**
- **Fit:** slope in use from 252 s, ending at **+65.47 ± 3.24 ppm**; 0 rejections, 0 steps, 0 unstable,
  0 gaps; largest offset step 2.9 ms. The offset walked **+1069 ms** over the session: Cloudflare's
  slope, carried. Without it, that is the lip-sync drift (§13.3).
- **Cross-check, 262 checks:** SR +66.7 vs queue +66.6 ppm (medians); disagreement median −0.08,
  p1/p99 −6.4/+10.7 ppm.
  - 3 WARNINGs, 01:23–01:25, at +10.7…+12.2 ppm. Their windows follow rail event 8, and the
    disagreement fell back within 3 min.
  - **Fallback never engaged** (10-min sustain), as required on Cloudflare.

**Renderer queue by 30-min block (median ms):**

| block | 0–0.5 h | 0.5–1 | 1–1.5 | 1.5–2 | 2–2.5 | 2.5–3 | 3–3.5 | 3.5–4 | 4–4.5 |
|---|---|---|---|---|---|---|---|---|---|
| depth | 419.3 | 420.9 | 421.3 | 420.7 | 421.1 | 417.7 | 418.3 | 417.5 | 416.7 |

Theil–Sen trend after 600 s: **−0.33 ppm (−1.2 ms/h)**.
- The dips are the rail events, down to 190 ms at event 9.
- The integrator settled at +4…+11 ppm per block, 32 at end-of-session.

**Open, carried:**
- the rail events (§13.4 tally): events 6–9 had no real delivery shortfall;
- the upstream pause (BUGS.md);
- concealment of single lost packets (BUGS.md, Opus PLC).

### 18.9 The engage rule: C (300 s window, 5 min sustain) fails the false-engagement test on Cloudflare; A stays — 2026-09-29

**The question.** A (§18.7: 600 s window, 10 min sustain) lets lip-sync walk −59 / −70 ms on flat
SRs before it engages at ~20 min. C (window 300 s, minimum span 270 s, engage sustain 300 s;
disengage unchanged at 5 ppm for 600 s) engages at ~10.5 min, worst walk −25 / −29 ms, and never
engages on the Cloudflare logs or the synthetic noise. But it comes closer: its longest disagreeing run
reaches 0.67 of the sustain on §18.8's log and 0.83 on the synthetic, against A's 0.27 / 0.36.
**Robbie's condition (2026-09-29):** keep C only if a false engagement on Cloudflare peaks at ≤ 10 ms
of lip-sync error and disengages by itself.

**Method.** The closed-loop replay (§18.7) with rule C, and an engagement FORCED at one check whatever
the evidence. The anchor is where a real engagement would put it (the current disagreeing run's
first window start, else the check's own window start), and the rate is the check's disagreement.
Forced at EVERY check, not only the worst one:
- §18.8's 4.5 h Cloudflare log, 267 checks;
- three 10 h seeds of the Cloudflare-like synthetic, 1785 checks. Its SRs carry the true slope
  (+68 ppm) with 9.5 ms white + 2 ms AR(1) noise; queue noise is 1 ms.

Error = the forced run's queue depth − the unforced run's, from the forced check to the log's end.
The SRs are right here, so the unforced run is the reference and the difference is lip-sync error.

| C, forced | worst point | C's own closest approach | peak \|error\|, median / p90 of all points | disengaged by itself | error at the log's end |
|---|---|---|---|---|---|
| 4.5 h log | **+25.9 ms**: check 155, t 9591 s, +29.1 ppm (the window after rail event 8). **Never disengages** | +10.2 ms (check 156, 180 of 300 s sustained). Never disengages | 3.1 / 6.6 ms | **134 of 267** (50 %), median 27 min after | worst +25.3 ms, 1.9 h later |
| 30 h synthetic | **−49.0 ms** (seed 11, −53.8 ppm). Never disengages | −17.5 / +13.3 / +13.6 ms (the three seeds' longest runs, 240 s). Never disengages | 10.2 / 18.8 ms | **111 of 1785** (6 %; seeds 11 and 13: 0), median 70 min after | worst −46.2 ms |
| *A on the 4.5 h log, for comparison* | +15.7 ms (check 153). Disengages after 21 min | — | 1.7 / 4.9 ms | 241 of 262 (92 %), median 21 min | +14.8 ms |

**The condition is not met on either input. A stays; no code change.**

**✅ DECIDED 2026-09-29 (Robbie), for this release:**
- **Rule A ships.**
- **MediaMTX WHEP ships as a KNOWN LIMITATION:** its SRs lag the media (a staircase, or flat).
  - The residual reaches up to ~−28 ms at +26 min (measured −27.8 ms grid-corrected on
    `srfix-whep-mediamtx`). That is outside the ±20 ms gate below; Robbie accepts it as within
    broadcast tolerance.
  - The flat-SR case is bounded by the fallback (§18.7: −59 / −70 ms worst, caught up by ~28 min).
  - ~~The fix is post-release~~ **Rescoped 2026-09-29 (Robbie): the level-based correction is in
    THIS release**, after the SRT items (BUGS.md, "THIS RELEASE: the depth-slope fallback should
    hold the queue's LEVEL"). The limitation stands until it lands.
- **The start → end criterion is restated** (below: +26 min against the session start).
- **No MediaMTX rerun.** Next is the Cloudflare SRT soak only.

**Why, and why it is not C's alone:**
- **Engaged, the correction is a RATE,** re-read every minute from the latest check: r = b_depth − b_SR.
  On correct SRs that number is noise, so the correction random-walks at r × 60 s per check instead
  of returning to 0.
  - The disagreement's sd per 300 s check is 5.3 ppm on the real log and 12 ppm on the synthetic.
- **Disengaging takes 10 consecutive checks under 5 ppm.** 77 % of the real log's checks are, and
  27–31 % of the synthetic's, so it can take tens of minutes or never happen.
- **Disengaging does not remove the error.** By design (§18.7) the correction is kept, frozen, so
  the target does not step back. **A false engagement is permanent for the session under ANY rule
  of this form.** The rule only sets how likely it is and how big.
- A's 600 s window halves the noise and keeps it far from engaging (0.27 / 0.36), but forced, it
  leaves 15 ms too. The fix is the level-based correction (BUGS.md, "THIS RELEASE: the depth-slope
  fallback should hold the queue's LEVEL"; rescoped from post-release 2026-09-29), not a faster or
  slower rule.

**Found on the way: last night's live MediaMTX run on A did not engage, and fails.**
`srfix-whep-mediamtx` ran 2026-09-28 21:51–22:20 on the §18.7 build, with staircase SRs, the fit at
+62.3 ppm and 8 WARNINGs. The run reached 0.73 of A's sustain and broke. Device captures, analysed
2026-09-29 (`c12.py`, all four gates pass):

| | result | limit | |
|---|---|---|---|
| file controls | +22.1 / +21.2 ms (zero +21.7) | ±5 | ✅ |
| criterion 12, grid-corrected | −14.9 ms (+3 min), **−27.8 ms (+26 min)** | ±20 | ❌ at +26 |
| criterion 12, as written | −34.9 / −47.8 ms | | |
| **start → end** | **−12.9 ms** | ±10 | ❌ |
| replay prediction (this log, A) | −15.6 ms start → end | | agrees within 2.7 ms |

So A passes §18.5's staircase (−2.0 ms) and fails this one. On C the same log replays at +3.2 ms
start → end.

**Start → end cannot pass on flat SRs with any fast rule: capture A has a head start.** On flat
SRs lip-sync walks from the connect, so capture A at +3 min is already b × ~140 s off: −8.2 / −10.0
ms of queue depth between 60–120 s and capture A on the two flat sessions (61 / 73 ppm). The
correction is anchored at the start of the evidence, so a rule that finishes its catch-up before +26
min returns lip-sync to the SESSION START, not to capture A.

| start → end (+3 → +26) | srtest1-flat | srtest2-flat | step8-whep-soak (staircase) | srfix-whep-mediamtx (staircase) |
|---|---|---|---|---|
| A | +5.3 | −5.9 | −2.0 | −15.6 |
| C | **+11.0** | **+13.3** | +3.1 | +3.2 |
| **proposed: start → +26 (depth 60–120 s → +26)** | | | | |
| A | −2.9 | **−15.9** | **−11.8** | **−20.3** |
| C | +2.8 | +3.3 | −6.7 | −1.6 |

- **C fails the criterion as written by exactly the head start.** It is right against the session
  start.
- **A passes as written only because +26 min lands mid catch-up** (§18.7: it compares two instants).
- **✅ ADOPTED 2026-09-29 (Robbie):** lip-sync at +26 min relative to the SESSION START, within
  ±10 ms, plus the unchanged ±20 ms absolute gate (criterion 12, grid-corrected) on each capture.
  It replaces capture A → capture B from this date; §6.3 carries the definition.
  - Capture A still measures the absolute, but the start is not capturable at device level: the
    first ~60 s are the startup realign (§10.10).
  - Device-level form: (capture B − capture A) + (queue depth at capture A − queue depth at the
    start), the second term from the log's steering windows. Lip-sync walk ∝ depth change (§18.7).
  - ~~The start window is fixed at 60–120 s after the connect.~~ **From 2026-09-30 (§18.21) the start
    is the SETTLED span the log's "LEVEL REFERENCE set" line names:** the first 60 s with the loop
    unsaturated and its integrator moving < 10 ppm, the SR slope in use, LiveClock within ±10 ms of
    its target, and no hold, splice or write. `depth_term.py` reads it (60–120 s, flagged, for logs
    without the line). The choice of window matters by 2–3 ms (30–90 s gave −5.6 / −18.8 for A on
    the flats).
- On Cloudflare the restatement changes nothing that matters: +0.1…+6.4 ms on every session.
- Capture A → B is still reported, not gated, so earlier runs stay comparable.

**The overshoot, and why a rate cannot give it back** (for the level-based item, in this release):
- **A rate needs a long window to be stable, and a long window integrates a staircase's flat
  stretches.** On a staircase, b_SR over a short window is not the SRs' long-run slope. A flat
  stretch between stairs reads as a large disagreement (§18.5's log: +27, +67, +71, +61, +35, +24
  ppm in successive checks).
- **The rule engages on that and holds the rate** through the catch-up plus one full window.
- **The next stair then jumps the SR offset up, delivering the same slope a second time.** The
  target moves by both, and the correction is never unwound: frozen on disengage, and a stair is a
  step, not the sustained opposite disagreement that would re-engage it.
- **Measured in replay:** B (600 s window, 5 min sustain) on `step8-whep-soak` engages at −21 ms,
  reaches 0 by ~1100 s, then climbs to **+66.5 ms** by the log's end. C on `srfix-whep-mediamtx` is
  +6.4 ms and still rising at the end (1712 s).
- **A level-based correction avoids both failures.** Hold the queue depth at its reference level:
  the stair raises the SR offset, the depth rises with it, and the correction falls by the same. On
  correct SRs the level error is noise around 0, so a false engagement unwinds by itself.

**Replay of the working tree (A), including the two logs not in §18.7's table** (the committed
`scripts/soak/replay`; figures for the earlier logs are unchanged from §18.7):

| session | fallback | start → end (+3 → +26) | log-only | steady drift / 30 min | WARN |
|---|---|---|---|---|---|
| srfix-whep-mediamtx (live on A, staircase) | never (0.73 of sustain) | **−15.6 ms** (device −12.9) | same | −8.5 ms | 8 |
| srfix-whep-cloudflare-long (§18.8, 4.5 h) | never (0.27) | +3.6 ms | same | −0.2 ms | 3 |

- `swift test` 114 / 114. Profile and Release build clean; warnings are the same set as §18.7's
  build. The only additions are vendored-header warnings from a fresh DerivedData.
- Harnesses: the rules matrix and the forced sweep are scratch copies of the cross-check with the
  rule's parameters and a force switch. The committed replay tools run the working tree's rule
  only.


### 18.10 Cloudflare SRT soak, 2026-09-29 12:57–13:37 — ❌ the picture drifts −29 ppm from its own timestamps; Cloudflare's output cleared

**Protocol.** Build `.build-cc/rulecheck-Profile`: HEAD's code, engage rule A. OBS "SRT Cloudflare"
(switched to Advanced output with a 1 s keyframe for this run), 23.976, AAC. The orchestrator ran
`go.sh cloudflare-srt`, its first run: OBS and Manifold both call Cloudflare, and Manifold disconnects
first. It worked end to end. Log `~/Desktop/ruleA-srt-cloudflare.log`.
- Timeline: file control 1, connect at 13:03:43, capture A at +3 min, the noise segment, capture B at
  +26 min, then control 2.

| | result | limit | |
|---|---|---|---|
| file controls | +0.7 / +3.6 ms (Δ +2.9); zero +2.2 | ±5 | ✅ |
| criterion 12, grid-corrected | **−50.5 ms** (+3 min), **−90.5 ms** (+26 min) | ±20 | ❌ |
| criterion 12, as written | −70.5 / −110.5 ms | | |
| **start → end (§6.3, from the session start)** | **−39.0 ms**: capture A → B −40.0, log term +1.0 | ±10 | ❌ |
| gates, both captures | beep count, 1 Hz grid, one burst per beep, digital silence between beeps | | ✅ |
| criterion 1, mutes (20 min) | **0** (the tracker's two hits are the segment's edges) | 0 | ✅ |
| audio loop | `e` median ≈ 0 in every 3-min block; renderer depth flat (Theil–Sen +0.0 ppm after 180 s); ρ−1 median −2.6 ppm | | ✅ |
| audio axis | stamped PTS = the sample count, cumulative +0.000 ms over 80 447 buffers | | ✅ |
| rail events | 1, at connect: LiveClock railed +0.5 % and starved publication 3.0 s; ρ at B 13.2 s, peak \|e\| 31.3 ms, over by +30 s (§13.4 tally) | | ⚠️ |
| LiveClock at ±0.5 % | **~92 % of its `[LIVECLOCK]` lines**, both rails (local SRT §18.4: 21 %; Cloudflare WHEP §18.8: 20 %) | | ⚠️ |

- **The zero moved.** Every earlier file control read +21…+27 ms. Today's read +0.7 / +3.6, the
  same launch, consistent with each other. A capture-chain change moves captures and controls
  together, so this session's numbers stand, but the cause is not known.

**Cloudflare's SRT output is cleared** (2026-09-29 13:48–14:13). With Manifold not running, OBS
streamed to Cloudflare SRT and ffmpeg recorded Cloudflare's playback with no re-encode and
`-copyts`, 1424 s (`~/Desktop/manifold-soak/cfsrt-probe.ts`). Analysed on the file's own
timeline:

| | result |
|---|---|
| flash/beep A/V, +180…310 s | +7.85 ms (grid-corrected +27.85) — ⚠️ WRONG by the 77 ms start gap; corrected −69.15 (§18.13) |
| flash/beep A/V, +1260…1390 s | +7.88 ms (grid-corrected +27.88) |
| **start → end** | **+0.03 ms**; trend over 34 whole grid periods **0.00 ppm** (each period +7.9…+8.3 ms) |
| audio PTS vs the sample count | exact: +0.000 ms over 1424 s, every step 1920 ticks |
| video PTS vs the frame count | within one frame over 1424 s; no rate error |
| **video PTS grid** | **quantised to 1 ms**: steps alternate 3780 / 3690 ticks (42 / 41 ms), not 3753.75 |

- ⚠️ **CORRECTED by §18.11:** the local repro does not reproduce the lag, and restamping changes
  nothing, so the next two bullets are withdrawn as conclusions. They are kept as the reasoning that
  led to the repro.
- **So the −40 ms is Manifold's, on the video side.** Manifold's audio follows the stream's
  timestamps exactly, and the timestamps carry no drift. The picture falls behind its own
  timestamps at about −29 ppm.
- **What the code says** (read 2026-09-29):
  - picture and audio follow one line, LiveClock's `now(t)`;
  - each display tick shows the newest queued frame with PTS ≤ `now()`;
  - SRT's audio target is `now()` itself, with cushion and offset 0.
  - So the lag must come from which frame is chosen against `now()`, or from the present pipeline
    between the tick and the glass.
- **Leading suspect, not shown:** the 1 ms grid.
  - Frame-to-frame the 41/42 ms steps are ±1.2 % of rate, beyond LiveClock's ±0.5 % rail, which
    fits a clock that sits on a rail 92 % of the time.
  - How rail-bouncing becomes a steady picture lag is not established.
  - A 1 ms PTS grid is legal MPEG-TS from any muxer or server, so the fix must handle quantised
    timestamps generally (CLAUDE.md), not Cloudflare.
- **Next: the local repro (§18.11)**, this file served to Manifold over local SRT with telemetry,
  as recorded and restamped to exact 41.708 ms steps.

### 18.11 The local repro, 2026-09-29 15:02–15:51 — ❌ the lag does NOT reproduce; restamping changes nothing

**Protocol (unattended).** Build `.build-cc/avlag-Profile`: HEAD plus the DEBUG-only `[AV-LAG]` line
and the `MANIFOLD_SRT_DEBUG_URL` override (BUGS.md, PRE-SHIP entry). Each run:
- ffmpeg serves the file as a local SRT listener (`-re -c copy -pes_payload_size 0`);
- Manifold launches with the override and the licence prompt is denied by osascript;
- ⌃⌥D is pressed by osascript, and the whole 1424 s file plays.

Two runs:
1. **as recorded:** `cfsrt-probe.ts`, video PTS on Cloudflare's 1 ms grid;
2. **restamped:** video PTS snapped to exact 41.708 ms steps. Each moved by at most ±0.9 ms, and
   audio is untouched (both carry the muxer's constant +1400 ms).

`[AV-LAG]`, once a second: `av` is the audio heard at the moment the picture reached the glass,
minus the picture's PTS. Its parts are frame choice (now − pts), audio against the clock, and tick →
glass (from the drawable's presented time).

| after 180 s, Theil–Sen | now − pts | audio − now | tick → glass | **av** | LiveClock at ±0.5 % |
|---|---|---|---|---|---|
| as recorded | +0.0 ppm | −0.2 ppm | −0.5 ppm | **−0.7 ppm** (−0.8 ms / 20 min) | 79 % of lines |
| restamped | −0.6 ppm | −0.3 ppm | −0.1 ppm | **−0.4 ppm** (−0.5 ms / 20 min) | 82 % of lines |
| **arrival −30 ppm** (as recorded, `-readrate 0.99997`, 16:03–16:27) | +0.3 ppm | +0.3 ppm | −0.9 ppm | **−1.5 ppm** (−1.8 ms / 20 min) | 80 % of lines |

- **av held within ±1.5 ms of +17.8 ms** (3-min block medians) for 23.7 min in both runs. The soak
  drifted −40 ms over the same length.
- Audio was intact in both runs: 0 holes, 0 overlaps, ρ within 30 ppm of 1 at the end.
- **The 1 ms grid is not the cause of the drift.** It is not the cause of the railing either:
  LiveClock rails as much on exact timestamps (82 %) as on the grid (79 %).
- **Corrects §18.10:** "the picture falls behind its own timestamps" was an inference from `e` ≈ 0
  and is not supported. On this file Manifold's picture, its present pipeline and its audio all hold
  to the stream's timestamps within 1 ppm.
- **What the repro does not reproduce, so where the −29 ppm can still be:**
  1. ~~**The arrival clock.**~~ **RULED OUT the same afternoon (third row).** Content arriving
     30 ppm slow against the Mac's clock left A/V at −1.5 ppm. The integrator absorbed it (`i` +25
     … +104 ppm, queue flat at ~208 ms) with 0 holes, 0 overlaps and no rail event.
  2. **Network delivery:** jitter, bursts and loss. Only a live run has them.
  3. **Outside the in-app path:** the device output or the capture chain, whose file-control zero
     moved ~20 ms today (§18.10). Testable with `[AV-LAG]` running during a live Cloudflare SRT soak
     with its device captures, which compares the app's own A/V with the device's in one session.
- Operator events: a desktop click at ~15:05 slid all windows off-screen for a moment. Two samples
  show one extra refresh to the glass (+20 ms tick → glass). The slopes are Theil–Sen, which ignores
  them.
- **A repro artefact, and a real gap:** the first attempt served with ffmpeg's default MPEG-TS
  muxing, about six AAC frames per PES. Manifold's SRT audio decoded none of it (BUGS.md). That
  attempt is void.

### 18.12 Test 3: live Cloudflare SRT with `[AV-LAG]` and a parallel stream capture, 2026-09-29 16:36–17:20 — the drift is in THIS session's stream; Manifold reproduces it

**Protocol.**
- Build `.build-cc/avlag-Profile`. `go.sh cloudflare-srt` with `SOAK_PREFIX=avlag`.
- Connected by ⌃⌥D through `MANIFOLD_SRT_DEBUG_URL` (no keychain prompt).
- For the whole live window (16:41:53–17:10:41), ffmpeg recorded Cloudflare's SRT playback in
  parallel, with no re-encode and `-copyts` (`~/Desktop/manifold-soak/cfsrt-probe-avlag.ts`).
- Log `~/Desktop/avlag-srt-cloudflare.log`.

**The three-way read, A/V change from capture A (16:45:02) to capture B (17:08:02):**

| instrument | A → B | trend |
|---|---|---|
| **stream** (ffmpeg file, flash/beep on its own timestamps, same wall-clock windows) | **−20.3 ms** (+2.50 → −17.84; absolute ⚠️ +81 ms wrong, corrected −78.50 → −99.12, §18.13) | −12 ppm over 12 whole grid periods (beeps are muted during the noise segment) |
| **in-app** (`[AV-LAG]`, audio at the glass − picture PTS) | **−0.6 ms** (+24.62 → +24.05) | −1.1 ppm after 180 s; frame choice, audio − clock and tick → glass all flat |
| **device** (captures, grid-corrected) | **−23.9 ms** (−53.64 → −77.49) | |

- **Device ≈ stream + in-app, within ~3.5 ms. The drift was in the stream this session, and Manifold
  reproduced it faithfully.**
- The stream's timestamps are self-consistent here too: audio PTS = the sample count, and video on
  the 1 ms grid with no rate error. One 167 ms video gap sits at the file's last frame, where the
  capture stopped.
- **So OBS → Cloudflare's A/V slope varies by session:** 0.00 ppm in the §18.10 probe session and
  about −15 ppm here. The §18.10 soak's −29 ppm session was not probed, so its split cannot be
  shown. With §18.11 (off-network replay holds within 1.5 ppm) and this run, the likeliest reading
  is that it was in that session's stream as well.
- Which of OBS and Cloudflare introduces the slope is not separated. That needs a local recording of
  OBS's own output in the same session.

**Other results:**
- **Control 2 is VOID.** The disconnect prompt came while the operator was away. Manifold stayed
  connected until OBS stopped at 17:19:56, so "control 2" recorded the live stream (no loop gaps,
  −93.4 ms).
  - The orchestrator waited 120 s twice, then recorded anyway.
  - **Fixed:** the end-of-session waits have no deadline now and repeat the prompt every 2 min.
  - The zero is control 1 alone, +5.49 ms.
- **criterion 12, grid-corrected:** −59.1 ms (+3 min), −83.0 ms (+26 min). ❌ ±20.
  - The absolute offset is not explained by the stream: the stream's own A/V at capture A is +2.5
    ms as written.
  - The §18.10 soak was similar: −50.5 against a +7.9 ms stream in another session.
  - ~~Not investigated; the absolute gate is open for Cloudflare SRT.~~ Resolved in §18.13: the
    stream figure was wrong by its 81 ms start gap; the stream carries the offset.
- **start → end:** A → B −23.9 ms, which is the stream's drift. The new criterion's log term,
  −44.6 ms, is contaminated by the connect rail event below and was only derived for WHEP. It is
  reported, not gated.
- **Rail event at connect:** LiveClock at +0.5 % with publication starved 3.0 s. ρ was at B for
  **90.8 s**, peak |e| 123 ms, recovered at +91 s, before capture A. The largest connect event
  in the §13.4 tally.
- **LiveClock at ±0.5 %:** 80 % of lines, as in every SRT run today, live or replayed.
- **criterion 1: 9 mutes in 3 clusters, all exact digital zero** (BUGS.md). None is in the
  stream: its decoded audio has no zero run ≥ 5 ms in the noise segment. The resampler logged 0
  holes and 0 overlaps, and the renderer's buffers were contiguous.

| time | mutes | nearby |
|---|---|---|
| 16:56:23 | 6 short zeros (24–106 ms) within 0.5 s | a delivery burst: 19–28 frames/s, a video underrun at 16:56:25 |
| 16:57:29 | 1 × 156 ms | video queue underruns at 16:57:31 (64 ms empty) |
| 17:07:29 | 2 × 18 / 10 ms | nothing logged |

### 18.13 The Cloudflare SRT absolute offset, 2026-09-29 evening (unattended) — ✅ it is in the stream; the stream probe read it +77 ms wrong

**Question (Robbie):** why does Cloudflare SRT read −50 … −83 ms at the device (criterion 12,
grid-corrected) when its stream read +8 ms?

**✅ RECORDED 2026-09-29 (Robbie): the Cloudflare SRT absolute offset is UPSTREAM.** The stream
carries audio ~70–80 ms early on its own timestamps (measured 69–81 ms across two sessions), and
Manifold plays it faithfully (device − stream +4.9 / +1.6 ms, same session). Not a Manifold defect;
nothing is changed in the app (CLAUDE.md, server-agnostic). A user who wants it removed does so with
the per-source audio offset (§19, design only).

**Answer: the stream does not read +8 ms. `probe_av.py` was wrong by exactly the gap between the
file's first video PTS and its first audio PTS.** avsync decodes each stream from its OWN first
frame: luma times start at the first video frame, audio at the first sample. Cloudflare's TS starts
its video 77–81 ms after its audio, so every Cloudflare stream figure read that much too positive.
An ffmpeg mux starts video 21 ms after audio, so the same error was +21 ms there. Fixed:
`probe_av.py` now puts both on the file's PTS (`-copyts` first PTS of each stream).

| file | video starts after audio | old probe_av (as written) | corrected, as written | corrected, +20 grid | device, grid-corrected |
|---|---|---|---|---|---|
| `cfsrt-probe.ts` (§18.10 probe session) | +77.0 ms | +7.85 / +7.88 | **−69.15 / −69.12** | −49.15 / −49.12 | −50.5 (+3 min, the soak: another session) |
| `cfsrt-probe-avlag.ts` (§18.12, same session as the device) | +81.0 ms | +2.50 → −17.84 | **−78.50 → −99.12** | −58.50 → −79.12 | **−53.64 → −77.49** |
| reference: fixture, ffmpeg libx264 + aac | +21.3 ms | +22.13 | **+0.79** | | |

- **Same session, the device tracks the stream's absolute A/V within +4.9 / +1.6 ms at captures A and
  B.** The §18.10 soak's −50.5 matches the probe session's −49.15 within 1.4 ms, across sessions.
- **The whole offset is in Cloudflare's stream: audio ~70–80 ms ahead of its picture on the stream's
  own timestamps.** Size varies by session, like the slope (§18.12). Not separated between OBS and
  Cloudflare. The local OBS SRT soak (§18.4) passed at +17 grid-corrected, so OBS's own output is
  unlikely to carry it; Cloudflare re-stamps both streams (the 1 ms grid) and re-encodes video
  (B-frames, pts−dts up to 208 ms, which OBS's output does not have). Likely Cloudflare; not proven.
- **Nothing to fix in Manifold (CLAUDE.md, server-agnostic):** an MPEG-TS source's A/V is what its
  timestamps say, and Manifold plays exactly that.
- **Criterion 12 on a stream that carries its own offset** should be read as device − stream. On
  that reading Cloudflare SRT passes (+4.9 / +1.6 ms).
- **Also retracted:** the "+22 ms from a 25p → 23.976 conversion" reading, which was this session's
  first probe of an ffmpeg reference. It was the same +21 ms start gap; the conversion's mean is
  +0.8 ms.
- ⚠️ **Probably affected, not re-checkable:** §18.5's MediaMTX RTSP sender probe (−13.1 ms as
  written) used the same avsync decode on an `.mkv`. The file is gone. Any sender probe whose
  streams start at different times read too positive by that gap.

**How it was found: the in-app content A/V.** `[AV-LAG]` checks timestamps only, so it cannot see
content. A DEBUG probe, `[AV-CONTENT]` (pre-ship removal, BUGS.md), logs each fixture beep's onset
on the audio the sink receives (`in`, the transport's axis = content time) and hands the renderer
(`out`, the resampler's output axis), and each flash at the first display tick that shows it with
`now` and `audio−now` (content time, `liveAudioDrift`). "At the glass" is beep(in) − (now +
audio−now) − tick→glass. The output axis carries the ratio's integral by design, so out − in is not
a content shift and is not used. `scripts/soak/analysis/avcontent.py` pairs them. Three local SRT replays through
`repro/run.sh`, 6–7 min each, one AAC frame per PES:

| source | decoded: beep(in) − flash, on Manifold's PTS | same file, same onset rule, on its own PTS (`-copyts`) | at the glass | glass − decoded |
|---|---|---|---|---|
| reference, no B-frames | +1.11 ms | +1.58 ms | −14.71 | −15.82 |
| reference, B-pyramid (pts−dts to 208 ms, as Cloudflare) | +1.10 ms | | −14.78 | −15.88 |
| Cloudflare capture (`cfsrt-probe.ts`, first 7 min) | **−68.78 ms** | **−68.80 ms** | **−84.93** | −16.15 |
| the same, again, on §18.15's build | −68.78 ms | | −84.69 | −15.91 |

- **Manifold's decoded A/V equals the file's to 0.5 ms on both sources.** B-frames change nothing.
- AudioToolbox, fed Cloudflare's AAC packet by packet as `SRTAudioDecoder` does, matches ffmpeg's
  decode to the sample (lag 0, residual 6e-9). The sample-counted axis re-pinned 0 times.
- **The render path is a constant: glass − decoded = −15.8 … −16.2 ms on every run**, whatever the
  source, B-frames or not, and (§18.15) 1, 7 or 17 AAC frames per PES. It holds on both builds. The
  control subtracts it along with the rest of the device chain.
- The first replay attempt was void: see §18.14's note on ffmpeg's PES packing of digital silence.

### 18.14 SRT device mutes, 2026-09-29 evening (unattended) — ✅ the renderer starves when a delivery stall outlasts the AUDIO queue's lead, then drops every late refill whole

**Instruments added** (DEBUG / telemetry, `LiveAudioSink`, pre-ship removal in BUGS.md):
- **`[<PATH>-STARVE]`**: at each enqueue, the renderer's timebase (the steering's own read) against
  the end of everything enqueued before. Past it means the renderer ran dry and played silence for
  at least that long. The line gives the silence's host span, the time since the previous enqueue,
  and where the refill lands against the playhead.
- **`[<PATH>-ZERO]`**: exact-zero runs ≥ 5 ms in what is handed to the renderer, on all channels.
  This separates silence the app wrote from silence the renderer made.
- The renderer probe's existing notifications (automatic flush, `hasSufficientMediaData…` KVO)
  logged nothing in any run: the renderer never flushed.

**Already in §18.12's log, read with those instruments' logic:** the steering window's renderer
queue depth (measured after each enqueue) went **negative** in the windows holding mute clusters
1 and 2: min **−6.9 ms** (window ending 16:56:26.9) and **−40.8 ms** (16:57:37.0), against a
session median of ~205 ms. So audio was enqueued after the renderer had played past it. Cluster 3
(17:07:29, 18 / 10 ms) dipped only to +44.8 ms, which a per-enqueue depth measured after the refill
cannot rule out: a short dry spell followed by a multi-buffer refill ends ahead. `[STARVE]` measures
before the refill and would show it.

**Reproduced, local SRT with induced stalls** (`STALLS=` in `repro/run.sh`: SIGSTOP / SIGCONT on the
ffmpeg sender; reference TS with a −60 dBFS noise floor, so any exact zero is a mute; no catch-up
burst after the stall, so content stays late by the stall's length):

| stall | `[STARVE]` events | silence at the renderer | last starve after resume | video underruns (empty) | `[ZERO]` |
|---|---|---|---|---|---|
| 50–300 ms (6 stalls) | 0 | 0 | — | ≤ 2 (≤ 98 ms) | 0 |
| 400 ms | 59 | 1.0 s | +1.5 s | 69 (2.5 s) | 0 |
| 600 ms | 277 | 5.7 s | +5.9 s | 182 (6.5 s) | 0 |
| 800 ms | 431 | 9.0 s | +9.1 s | 255 (9.3 s) | 0 |
| 1200 ms | 862 | 18.2 s | +17.7 s | 458 (17.1 s) | 0 |
| 2000 ms | 1576 | 33.5 s | +32.3 s | 808 (30.4 s) | 0 |

**Where it starves:**
1. The audio target is LiveClock's `now()`, and the renderer's queue is only as deep as the audio's
   ARRIVAL LEAD over `now()`: **~340 ms here, ~205 ms on Cloudflare live.** That lead is set by the
   sender's mux (how far ahead of its video it interleaves audio) and by the reorder depth: video
   PTS carry pts − dts, audio does not. Manifold does not control it. The 250 ms cushion is sized
   and measured on VIDEO.
2. A stall longer than that lead runs the renderer dry. **The first refill is already behind the
   playhead, and so is every one after it until the clock has fallen back.** Each buffer is dropped
   whole ("ends −35 ms against the playhead"), so the renderer plays exact zero while the resampler
   reports 0 holes and contiguous buffers, because the axis IS contiguous. This is §18.12's
   signature.
3. The mute lasts until `now()` falls back behind arrival: about the deficit at LiveClock's catch-up
   (≈ 16 × the stall excess here). On a live network, SRT redelivers in a burst, the deficit is
   brief, and the mutes are the 24–156 ms seen in §18.12.
- **Nothing app-written:** 0 `[ZERO]` runs in every stall. The zeros are the renderer's.
- **Not a mapping step:** no snap, freeze guard or queue-full re-anchor in the stall windows.
  LiveClock slewed at its rail, as §18.12 shows 80 % of the time.

**Fix options, for decision (none implemented):**
- **A. Hold the audio with the picture.** When the renderer is about to run dry, stop the audio
  timebase (rate 0) and restart it when data arrives. That turns "silence, then drop everything
  late" into a short pause with A/V intact and latency +stall, recovered afterwards by the existing
  slew. Server-agnostic. Costs a pitch-free pause; interacts with the resampler loop's error
  (a known, one-off step).
- **B. Size the cushion on the audio lead,** not the video's. Measure min(audio lead, video lead) and
  keep the target above the observed stall p99. Costs latency on every session.
- **C. Play late audio instead of dropping it:** re-stamp a refill that lands behind the playhead
  onto it (a splice, as step 5 does for jumps). The refill is heard with no mute, and lip-sync takes
  a step the loop then removes.
- A is the only one that removes the minutes-long silence of a long stall. B only moves the
  threshold. C trades mute for A/V error.

### 18.15 The multi-frame AAC must-fix, 2026-09-29 evening — ✅ implemented, verified with ffmpeg as the sender; one residual belongs to §18.14

**Root cause, confirmed:** the vendored libavcodec is configured `--enable-parser=h264` only. With
no AAC parser, libavformat's mpegts demuxer returns each audio PES PAYLOAD as one packet, and
`SRTSession.m`'s comment ("one complete AUDIO frame per AVPacket") was true only of senders that
put one frame in each PES. **Worse than recorded:** ffmpeg rounds `-pes_payload_size 0` up to 170
bytes, so digital-silence AAC frames (~13 bytes) are grouped even when asked for one per PES (17 per
PES in the fixture). The first attempt at §18.13's replays hit exactly that: 1 of 7–13 frames
decoded, 228 `[STARVE]` events. Void, redone with a −60 dBFS noise floor under the fixture audio.

**The fix (BUGS.md outline, as written):**
- `AACFraming.ADTSWalk`, a new leaf target (`swift test`): splits a payload by each header's
  `aac_frame_length`, 7- or 9-byte headers. It stops on a bad length, a missing syncword or a short
  tail, and reports the bytes left and why. Raw AAC and LATM are not walked.
- `SRTAudioDecoder.decode` walks the payload and runs each frame through the existing one-frame
  converter call (`convertOne`). Each decoded frame is handed on as its own buffer. The cookie comes
  from the first frame; a later header that differs is logged once.
- `SRTFrameRouter.handleAudioPacket` stamps frame k at the packet PTS + the samples decoded before
  it from that packet (13818-1: the PES PTS is the first access unit's). The sample-counted axis
  then advances exactly as with one frame per PES. Unwalked bytes and failed frames are counted on
  the chain line (`aacFrames=`, `unwalkedBytes=`) and logged once per session.
- `xcodegen generate` is needed once (new `AACFraming` product in `project.yml`).

**Verification** (`repro/run.sh` with `PES_PAYLOAD=default`, i.e. ffmpeg's own packing, no
`-pes_payload_size 0`; build `.build-cc/aacwalk-Profile`):

| | frames per PES | undecodable | holes / overlaps / axis breaks | re-pins | `[STARVE]` | decoded A/V (§18.13's probe) | `[AV-LAG]` av |
|---|---|---|---|---|---|---|---|
| noise-floor reference, 6 min | 5–7 | **0** | 0 / 0 / 0 | 0 | 0 | **+1.11 ms** (1 frame per PES: +1.11) | −1.2 ppm |
| fixture audio as is (digital silence), 4 min | **17** | **0** | 0 / 0 / 0 | 0 | ⚠️ 7125 | +1.54 ms | ⚠️ −63 ppm |

- `swift test`: 124 / 124, including 10 new `ADTSWalkTests`: 1, 2, 6 and 12 frames per PES; mixed
  lengths including silence-sized frames; CRC headers; a truncated last frame; garbage after a
  valid frame; a short tail; a length shorter than its header; raw AAC and LATM not walked.
- **Every frame decodes in both runs, and on the Manifold timeline its content lands where the
  single-frame run puts it (+1.11 vs +1.11 ms).**
- ⚠️ **Residual, NOT a decode defect: §18.14's starvation, reached through the sender's mux.** 17
  frames is 363 ms of audio per PES, and the muxer holds each PES until it is full, so audio ARRIVES
  up to ~360 ms after its time. The renderer queue swings +300 … −430 ms per chunk. Each chunk lands
  behind the playhead and is dropped; `[AV-LAG]` reads −63 ppm while it lasts. Content A/V at the
  glass still averages −14.8 ms (the other runs: −14.7), but spreads wider. It happens only where the
  audio is near-silent (tiny frames), so it is mostly inaudible, but it can
  clip the first frames when sound resumes. §18.14's options A / B cover it. A real ffmpeg sender with
  programme audio packs ~6 frames (~130 ms) and is clean (row 1).
- **One frame per PES, regression:** Cloudflare's capture replayed on this build: 0 undecodable,
  0 holes, 0 `[STARVE]`, decoded −68.78 ms and glass −84.69 ms (the old build: −68.78 / −84.93).
- ~~**Not yet run:** OBS live over local SRT~~ (done below), and another real sender (vMix, Wirecast,
  hardware) — still not run.

**OBS live over local SRT, regression A/B, 2026-09-29 22:12–22:36 (unattended, log-only).**
- Setup:
  - OBS "SRT Local" (listener, AAC, 23.976) streamed the looping flash-beep fixture.
  - Manifold dialled it through `MANIFOLD_SRT_DEBUG_URL` with the passphrase in the URL (no
    keychain read), connected by ⌃⌥D, for 8 min per build.
  - Previous build `.build-cc/avcontent-Profile` (the same instruments, no ADTS walk), then
    `.build-cc/aacwalk-Profile`. Driven over obs-websocket.
- **OBS sends one AAC frame per PES** (rx 22 640 packets, 23 019 520 frames = 1.00 frame per
  packet), so OBS never exercised the defect. This run checks for regression only.

| | previous build | fix build | |
|---|---|---|---|
| undecodable / unwalked bytes | 0 / — | **0 / 0** | ✅ |
| holes / overlaps / axis breaks / clamps | 0 / 0 / 0 / 0 | **0 / 0 / 0 / 0** | ✅ |
| `[STARVE]` | 0 | 0 | ✅ |
| timebase writes | 1 | 1 | ✅ |
| decoded content A/V (`avcontent.py`, median / mean) | −119.25 / −119.29 ms | **−119.21 / −119.25 ms** | ✅ Δ 0.04 ms |
| at the glass (mean) | −135.08 ms | −134.99 ms | ✅ |
| `[AV-LAG]` audio − now, slope after 180 s | +0.1 ppm | +0.1 ppm | ✅ |

- **A/V is unchanged.** The decoded figure is the fixture's 25p-in-23.976 phase spread (p10/p90
  ±16 ms) plus OBS's sender term. It is identical on both builds.
- The `[AV-LAG]` `av` slope (+13.7 / +24.9 ppm) comes from `tick→glass` alone: +11.6 → +19.9 ms in
  the fix build's last 3-min block, one extra display refresh. Robbie was working in overlapping
  windows during the run. That is the display path, not audio: `audio − now` is flat on both.
- Harness notes:
  - The first attempt at the fix-build run was void (a manual StopStream stopped OBS 5 s in).
  - OBS's SRT listener re-listens when its caller leaves, so the sender must stop first. The
    scratch runner does that now.

### 18.16 The starvation hold (§18.14 option A) — design, 2026-09-29 night

**Decided by Robbie (2026-09-29):** option A. When the renderer is about to run dry, hold the audio
timebase (rate 0) and restart it when data returns. Asked for, before building: how lip-sync
recovers after the resume, how it interacts with the steering loop, the splice and LiveClock, and
proof that the rate is written only during actual starvation.

**First, a correction to §18.14.** Its repro says "no catch-up burst after the stall". That is wrong.
ffmpeg 8's `-readrate` catches up at **1.05×** after a lag (`stall1.ffmpeg.log`: "Resumed reading
at pts 316.462 with rate 1.050 after a lag of 2.117s"). So §18.14's silences (≈ 16–20 × the stall
excess) measure the SENDER's catch-up, not LiveClock falling back. Nothing else in §18.14 changes.

**Second, what the picture does through the same stall.** Option A as written in §18.14 ("A/V intact,
latency +stall") assumed the picture waits too. It does not.
- LiveClock keeps running through a video underrun. `evaluateFreezeGuard`: "an EMPTY queue is an
  underrun, not a freeze … the clock is positioned correctly".
- When frames return, each tick shows the newest frame with PTS ≤ `now()`.
- **Sender caught up (a burst, or fast):** the picture is back on `now()` at once.
- **Sender still late:** the picture shows frames as they arrive, behind `now()`, until the P-loop
  slews `now()` back at ≤ 0.5 %.

So a pause that simply restarts where it stopped leaves audio late against a picture that has
moved on, by the whole time held. The restart point, and a debt the loop steers around, are the
design.

#### The mechanism (`LiveAudioResampleSteering`, "THE STARVATION HOLD")

| step | rule | figure |
|---|---|---|
| **deadline** | re-armed on every enqueue for the host time at which the queue (frontier − timebase) would reach the margin M; a strict dispatch timer, 0.5 ms leeway | M = **20 ms** |
| **hold** | the deadline fires, and a fresh read confirms queue ≤ M + 2 ms outside a settle window → `setRate(0, time: timebase, atHostTime: now)` | write 1 |
| **resume** | the first enqueue that leaves R queued past the held point → `setRate(1.0)` at `at = max(held, min(target, frontier − R))` | R = **100 ms**; write 2 |
| **debt D** | `D = target − content heard at at`, ≥ 0. The loop's target becomes the picture's line − D | D < 20 ms is folded into the loop |
| **recovery** | a forward splice (step 5's drop) of `x = min(D, queue − 100 ms keep − 10 ms fade − 50 ms margin, 1 s)`, taken when x ≥ min(D, 100 ms), at most one per second | 0 writes |

- **Why M is small.** Every hold is two rate writes, and the renderer mutes ~50 ms on each
  (`LIVECLOCK_AUDIO_MIRROR_FINDINGS.md` §11.11). A larger M holds on stalls the queue would have
  ridden out. At 40 ms the tests held on a 280 ms stall over a 340 ms lead, which never ran dry
  before. M must still cover the timer's lateness (sub-ms) and the write's landing (below).
- **The landing is not measured.** `setRate` changes the rate synchronously and the timebase
  asynchronously. The 0.25 s settle is a bound, and `delaysRateChangeUntilHasSufficientMediaData`
  may delay a restart.
  - A landing slower than M lets the renderer run dry for the difference, and no longer. Once the
    hold lands, the timebase is back behind the frontier, so the refill is not behind the playhead
    (test: 30 ms landing → ≤ 10 ms dry).
  - The hold line logs a read-back, and the resume line logs the timebase read against the held
    point. Those two are the measurement.
- **Why the resume point is `max(held, min(target, frontier − R))`.**
  - Burst: the refill covers the target, so the restart is on the target with D = 0. That is what
    a dry renderer eventually reached, but without the dropped refills or the silence after them.
  - Slow sender: the refill reaches only the held point, so the restart is there and D = the time
    held.
  - Never later than the target: never early audio. Never before the held point: never repeated
    audio.
  - A restart past the held point skips content inside the silence the hold already made.

#### 1. How lip-sync recovers after the resume

**The picture's line is the reference** (the loop's target, as everywhere since step 4d). Audio is
never early. It is late by D at most, and D only shrinks.

| sender after the stall | resume | D at resume | brought back by | how fast | worst lip-sync error |
|---|---|---|---|---|---|
| catches up at once (SRT redelivering its buffer, a burst) | on the target | **0** | nothing needed | at the resume | the loop's usual ±ms after the 0.25 s settle |
| catches up at k× (ffmpeg: 1.05) | at the held point | ≈ time held ≈ stall − (queue at the stall − M) + (R − M)/k | recovery drops, ≥ 100 ms each, ≥ 1 s apart, as the queue grows at (k − 1) s/s | ≈ D / (k − 1) + ~4 s: **≈ 20 × D** at 1.05 | **D, audio late**, falling in ≥ 100 ms steps |
| never catches up (content permanently late) | at the held point | ≈ time held | recovery drops once LiveClock slews `now()` back (the loop follows at ±B = 2000 ppm, so the queue grows ~2 ms/s) | slow | small against the picture, which is late too (it shows arrivals behind `now()`); D is owed against `now()`, not against the picture |

- **Compared with the build before it,** with the same stall and sender:
  - The HELD time is silence in both. There is no audio to play.
  - Before: after the stall, silence for as long as the sender took to catch up (the "20 × D"),
    because every refill landed behind the playhead.
  - Now: the audio is heard late by D, and D is removed by splices over the same time.
  - The trade is silence against late audio. The late audio never exceeds the silence it
    replaces, and a burst leaves no debt at all.
- **Worst case, bounded:**
  - |lip-sync error| ≤ D₀ ≤ the time held + (R − M)/k.
  - It is always "audio late". It returns to the loop's band by the time the sender has caught up.
  - At 2 s over a 340 ms lead at 1.05×, D₀ ≈ 1.7 s. The test
    (`testSlowCatchUpRecoversBySplices`) requires the loop back within 2 ms of the target by
    25 × D₀ + 2 s after the stall, and late by no more than the time held + 70 ms.
- **Cost in splices:** ≤ D₀ / 100 ms + 2 drops, each a 10 ms equal-power fade (step 5). A burst
  costs none.

#### 2. Interactions

- **The steering loop.**
  - While held there is no input, so there are no reads: nothing steps or integrates.
  - The resume is a write, handled like every write: e_f reset, i held, 0.25 s settle.
  - Because D comes off the target, the resume causes no step or level trigger. The loop sees
    e ≈ 0, and the ratio does not rail to chase a debt it could only repay at 2 ms/s.
  - A recovery drop moves content + ahead and D by the same amount at the same instant, so e is
    continuous. It is not a coarse event and is not matched against one.
- **The splice.**
  - Recovery drops use the stage's `requestSplice` and step 5's drop guard (drop + fade + 50 ms),
    plus a 100 ms keep, so a recovery never takes the queue back towards the margin.
  - A coarse event during recovery (a LiveClock jump) splices as before against target − D.
  - A coarse fallback write places content on target − D, so D is kept.
  - An anchor (a clock reset, NDI's re-anchor, a Desktop Audio Lead change) places content on the
    target, so D ends.
- **LiveClock.**
  - Nothing is written to it, and nothing new is read from it: the loop's target is its line, as
    before.
  - Its underrun behaviour, snap, freeze guard and rails are unchanged. The picture is NOT held
    (out of scope; a pause of the picture would be a LiveClock change).
  - Rail events move the target, and the loop follows at ±B as before.
- **WHEP's SR fit and fallback.** D sits on top of the SR offset. The cross-check's b_depth is a
  Theil–Sen slope over 600 s, and a recovery (tens of seconds, depth low by up to D) is a transient
  inside it that the median rejects. ⚠️ A cluster of long recoveries inside one window is untested.
- **DeckLink and the meters.** The tap is upstream of the renderer and never sees the hold.
- **Transport-agnostic (CLAUDE.md).** The rule reads only the renderer queue.
  - NDI's pull pump keeps enqueueing through a sender gap, so its queue never falls to M and it
    never holds.
  - Pinned mode (the back-out switch) never holds: it is step 3 exactly.
- **Session hand-over.** A superseded session's steering is retired before the next one owns the
  synchronizer, so a stale deadline cannot hold the new session's timebase. Every write decision is
  serialised with its write: anchor, per-buffer evaluation (resume, fallback) and the deadline
  (hold) share one lock.

#### 3. Proof that the rate is written only during actual starvation

1. **Write sites.** The session writes the timebase at:
   - the first anchor;
   - a coarse fallback;
   - a caller re-anchor;
   - **the hold**;
   - **the resume**.

   Holds and resumes are counted with the others (steering END line, `timebase writes`).
2. **A resume exists only after a hold.** It is decided only while `held` is set.
3. **A hold requires a deadline that no enqueue re-armed first.** Every enqueue re-arms it for
   (queue after the enqueue − M) seconds ahead. So it fires only when no input arrived for as
   long as the queue took to drain to M: the renderer would play dry within M = 20 ms. It then
   re-reads the queue and holds only if it is ≤ M + 2 ms, outside a settle window, and on the loop.
4. **The only non-starvation case is a stall that ends inside those 20 ms,** which the queue would
   have survived.
5. **A healthy stream's queue never comes near M.** Window minima of the renderer queue, measured
   after each enqueue, in every soak log since step 4d (a pre-enqueue low-water is logged from
   this build on):

| log | transport | windows | median depth | **lowest window minimum** | windows < 100 ms |
|---|---|---|---|---|---|
| step8-ndi-soak, step8-ndi | NDI | 359 | 259 ms | 251.9 ms | 0 |
| step8-srt-soak, step5-srt-a/b, step7-srt | local SRT | 244 | 337–340 ms | 222.1 ms | 0 |
| ruleA-srt-cloudflare (§18.10) | Cloudflare SRT | 171 | 201 ms | **105.8 ms** | 0 |
| avlag-srt-cloudflare (§18.12) | Cloudflare SRT | 225 | 204 ms | **−40.8 ms** | **6, the mute clusters: actual starvation** |
| srfix-whep-cloudflare-long (§18.8, 4.5 h) | Cloudflare WHEP | 1631 | 420 ms | 189.6 ms (rail event 9) | 0 |
| step4e2-cloudflare ×2 | Cloudflare WHEP | 442 | 421 ms | 276.7 ms | 0 |
| step8-whep-soak, srfix-whep-mediamtx, srtest1/2 | MediaMTX WHEP | 379 | 385–427 ms | 207.5 ms | 0 |

- The one log whose queue went under 100 ms is the one that muted, and only in its mute windows.
  Everywhere else the lowest reading is 105.8 ms, more than 5 × M.
- **Offline, the rule in a queue model** (`LiveAudioStarvationHoldTests`, 9 tests):
  - leads of 110 / 205 / 340 / 420 ms with 60 ms delivery bursts for 20 min each: 0 holds, 1 write;
  - stalls inside the lead (≤ 280 ms on 340): 0 holds;
  - 0.4 / 1 / 2 s stalls, burst or 1.05×: exactly 1 hold + 1 resume, never dry, D recovered;
  - a deadline fired early holds nothing; pinned and retired steerings never write.

  `swift test` 133 / 133.
- **Live evidence:** §18.17 (the stall runs, with the new low-water line).

## 19. The per-source audio offset — design sketch only (no build), 2026-09-29 night

**✅ IN THIS RELEASE (Robbie, 2026-09-30).** Order: after the level-based WHEP correction (BUGS.md,
"THIS RELEASE: the depth-slope fallback should hold the queue's LEVEL"), which the MediaMTX row of
19.5 depends on. Effort as revised in 19.6: 1–2 calendar days.

**Why it exists.** Some sources carry their own A/V offset in their timestamps, and Manifold plays
timestamps faithfully (CLAUDE.md: no per-server correction):
- Cloudflare SRT: audio ~70–80 ms early (§18.13), with a slope that varies by session (§18.12).
- OBS on either transport: provisionally ≈ +16…+22 ms (§18.3, §18.4).

The user needs a way to correct what the source carries, per source, that Manifold never applies
by itself.

### 19.1 Where the offset is applied: a term in the TARGET, moved by a splice

- **The offset is one more term in the steering's target line,** beside the SR offset and the
  starvation debt D (§18.16):
  - target content = picture's line − cushion/SR offset − D − **O**;
  - **O > 0 = audio heard O later** (the fix for Cloudflare SRT's early audio).
- **A change of O is applied as ONE splice, never through the ratio.** Changing the target by ΔO and
  requesting a splice of −ΔO in the same evaluation keeps content + ahead − target continuous, which
  is exactly the §18.16 recovery drop's bookkeeping.
  - The loop's e does not step, ρ does not move, and the coarse branch does not fire.
  - So the resampler loop is unaffected: it never sees O.
  - Without the splice, a 75 ms change would be a step trigger (a splice anyway, unmatched: a
    WARNING). A < 50 ms change would be walked in by the ratio at ≤ 2 ms/s, i.e. 25 s for 50 ms.
  - Delay (O up): an INSERT of repeated material, always possible; the renderer queue deepens by ΔO.
  - Advance (O down): a DROP, possible only while the queue covers it (step 5's guard). So audio can
    be advanced by at most the audio's arrival lead − ~160 ms: ~40 ms on Cloudflare SRT, ~180 ms
    locally, ~260 ms on WHEP. Past that the UI says so, and the picture would have to wait instead,
    which is a LiveClock change and out of scope.
- **NDI** (no LiveClock): the same term in its anchor line. **HLS** (AVPlayer): out of scope; the
  control is disabled with a note.
- **DeckLink:** the tap feeds SDI by the staged video frame's PTS (`AudioTapBuffer.read(framesStarting
  At:)`). The same O is applied as `startTime − O` there, so SDI and desktop move together. That is
  a second, independent site, with its own test. The meters stay on the source (§4.3).
- **Server-agnostic (CLAUDE.md):** O is the USER's per-source setting. Nothing in the app chooses
  it from the server's identity. Calibration measures it from content and offers it; the user
  applies it.

### 19.2 (a) Calibration mode — productising `[AV-CONTENT]`

- **Detectors:** `AVContentBeepDetector` on the sink's input (content time) and the renderer's
  flash detector (256 luma samples per new frame). Today they are DEBUG and run while the probe is
  on (BUGS.md, pre-ship).
  - They ship in Release, but run ONLY while calibration mode is on (a menu item and a button in
    the bookmark's sheet). Zero cost otherwise.
- **Measurement:** pair each flash with the beep within ± half the pattern's shortest interval.
  - Offset = median of (beep content time − flash content time), on the stream's own PTS: the
    "decoded" column of §18.13, which is what the source carries.
  - Needs ≥ 10 pairs (~15 s), a spread (p90 − p10) under one frame, and a stable ±2 ms median over
    the last 5 pairs; otherwise it keeps listening and says why.
  - The pattern's coding (19.3) rejects a pairing that is off by a whole interval.
- **Report:** "This source's sound is 76 ms EARLY (n = 14, ±3 ms). Apply +76 ms to this bookmark?"
  with [Apply] [Apply for this session only] [Cancel].
  - It also shows the value currently applied, and the residual after it.
  - Re-running calibration with O applied should read ≈ 0 on the decoded axis, plus O.
- **What it does not measure:** Manifold's own render path, a constant −16 ms (§18.13: glass −
  decoded), and the output device. Those are the app's, the same for every source. They belong to a
  file-control calibration of the output chain (post-release), not to a per-source O.

### 19.3 (e) The sync clips we would ship, free

- **One per frame rate, native:** 23.976, 24, 25, 29.97, 30, 50, 59.94.
  - Today's fixture is 25p shown at 23.976, which is why every live figure carries the ±20 ms
    grid correction (§18.1).
- **Frame-aligned:**
  - each flash is exactly one frame, and each beep starts on that frame's boundary and lasts one
    frame period (1 kHz, −20 dBFS, 5 ms raised-cosine edges);
  - events fall on frame counts, not on whole seconds.
- **Coded, not periodic:** intervals cycle through 23 / 29 / 31 / 37 frames.
  - A pairing that is off by one interval cannot fit the sequence, so offsets up to ± half a cycle
    (~2.5 s at 25p) are unambiguous.
  - A periodic 1 s pattern aliases at ±0.5 s.
- **A −60 dBFS noise floor between beeps.** Digital silence packs 17 AAC frames per PES in ffmpeg
  (§18.15) and hides starvation mutes. Also a burnt-in frame counter and the clip's rate in the
  corner.
- **Generated by one committed ffmpeg recipe per rate** (lavfi, no third-party media), in ProRes 422
  and H.264/AAC MP4.
  - The shipped files' A/V is verified at 0.0 ms by `c12.py`'s gates, each release.
- **Optional OBS scene collection:** one scene per rate holding the clip as a looping media source,
  its audio routed to the stream. Import instructions in the user guide.
- **Where they ship:** a free download beside the app (they are data, ~20 MB), linked from
  calibration mode.

### 19.4 (b) Manual control, (c) HUD, (d) per bookmark

- **(b) Manual:** the bookmark sheet gets an "Audio offset" field in ms, −500…+2000, step 1.
  - A live nudge is also available while connected (⌥[ / ⌥], ±1 ms; ⇧ for ±10 ms), applied by the
    19.1 splice.
  - The nudge edits the session. "Save to bookmark" persists it.
- **(c) HUD:** whenever O ≠ 0, a persistent badge in the video corner reads "A/V +76 ms" in the HUD's
  style. It does NOT auto-hide with the HUD, because a hidden correction is how a wrong one
  survives. It is also in the window title's live suffix, and on the session line of the log.
- **(d) Per bookmark:** `StreamBookmark.audioOffsetMs: Int?`, **Optional**, per `Preferences.swift`'s
  rule. A required field makes every stored bookmark undecodable for every user at once.
  - nil = 0. Never written unless the user sets it.
  - The store's existing whole-array write is unchanged. CLAUDE.md's read-before-write rule applies
    to any hand-run `defaults` in its testing: stash `streamBookmarks` first and restore after.
  - **Test:** decode a pre-feature `streamBookmarks` blob, re-encode, compare every existing field.
  - The DEBUG ⌃⌥D path (the URL override) has no bookmark, so it uses a session value.

### 19.5 (f) Does a one-time calibration hold for 90 minutes? Per path, from what is measured

90 min is extrapolated at each run's measured slope. "Holds" means the drift stays within ±10 ms,
the start → end gate of §6.3.

| path | measured | slope | over 90 min | one calibration holds? |
|---|---|---|---|---|
| NDI (OBS/DistroAV) | +1.6 ms / 28.5 min (§18.3) | ~+1 ppm | ≈ +5 ms | ✅ |
| local SRT (OBS) | −1.6 ms / 28.5 min (§18.4) | ~−1 ppm | ≈ −5 ms | ✅ |
| Cloudflare WHEP | −9.8 ms / 4.5 h (§18.8) | −0.6 ppm | ≈ −3 ms | ✅ |
| MediaMTX WHEP | −12.9 ms / 23 min, live on rule A (§18.9) | SR-lag dependent | up to ~−50 ms today; bounded once the level-based correction lands (this release) | ⚠️ not until the level-based correction is verified |
| **Cloudflare SRT (OBS)** | 0.00 / −12…−15 / −29 ppm in three sessions (§18.10, §18.12) | **varies by session, in the stream** | **0 to −157 ms** | ❌ re-calibrate |
| HLS | not measured (§18.6) | — | — | no offset control (AVPlayer) |

- **Cloudflare SRT:** §18.18 (the ffmpeg-published fixture) says whether Cloudflare or OBS makes
  the slope. If ffmpeg's single-clock stream still drifts, the slope is Cloudflare's, and no
  calibration can hold on that path.

**User-guide wording (draft):**

> **Audio offset.** Some streams arrive with their sound slightly ahead of or behind the picture —
> the offset is in the stream itself, and Manifold plays exactly what it receives. If you see it,
> play one of the free Manifold sync clips through your encoder, open **Calibrate A/V** while
> connected, and apply the measured value to that saved stream. A badge in the corner of the video
> shows whenever an offset is active.
>
> **Which transport to use for long sessions.** On Cloudflare Stream we recommend **WHEP**: a single
> calibration holds for 90 minutes and more. **Cloudflare's SRT output can drift during a session**
> (we have measured up to about 40 ms in 25 minutes, varying from session to session), so on long
> sessions over Cloudflare SRT, re-run the calibration every 20–30 minutes, or use WHEP. Local SRT,
> NDI and WHEP from a server that sends accurate sender reports hold a single calibration.

### 19.6 Effort — revised 2026-09-29 (Robbie: 10–12 days was a human-engineer estimate)

At this project's pace (§18.16 was designed, built, tested and verified in ~1 h of work plus
~25 min of runs), the code is hours. Elapsed time is set by real-time verification and by the
decisions only Robbie makes.

| part | work | elapsed, mostly machine |
|---|---|---|
| 19.1 offset term and the splice on change (reuses §18.16's D bookkeeping), NDI anchor line, DeckLink tap read, tests | 1–2 h | — |
| 19.4 bookmark field and migration test, sheet field, live nudge, HUD badge, log line | 2–3 h | — |
| 19.2 calibration mode: pairing with the coded pattern, confidence rules, UI (the detectors exist) | ~½ day, the riskiest part | — |
| 19.3 clips, 7 frame rates: recipe, gates, OBS scene collection | ~2 h | render time |
| verification: one run per transport, plus the 90-min Cloudflare SRT hold check | — | ~6 h unattended |
| **total** | **~1 day** | **1–2 calendar days** |

- **Attended, and so not compressible:** device-level captures (the recorder's audio source is
  re-picked by hand after every launch; Audio Hijack); UI placement and nudge keys; review of the
  clip pattern. The in-app `[AV-CONTENT]` figures cover most of the verification unattended.

- **Dependencies:** §18.16 (the starvation debt D shares the target term and the splice
  bookkeeping); the level-based WHEP correction (for the MediaMTX row of 19.5).
- **Pre-ship list:** the DEBUG `[AV-CONTENT]` code is replaced, not kept beside the shipped
  detectors (BUGS.md's pre-ship entry).

### 18.17 The starvation hold, verified with induced stalls — 2026-09-29 22:37–22:51 (unattended)

**Protocol.** `repro/run.sh` served the noise-floor reference (`ref-nob.ts`, one AAC frame per PES,
−60 dBFS floor, so any exact zero is a mute) with `STALLS="60:300 100:400 150:1000 210:2000"`
(SIGSTOP/SIGCONT on the ffmpeg sender).
- Builds, same file and stalls: `.build-cc/aacwalk-Profile` (baseline) then
  `.build-cc/starve-Profile` (+ the hold).
- ffmpeg catches up at **1.05×** after each stall, so this is the slow-catch-up row of §18.16. A
  burst redelivery was not exercised live.
- Analysis: `stalls.py` (scratch).
  - Renderer silence = the union of `[STARVE]` dry spans.
  - Lip-sync = `[AV-CONTENT]` glass per beep minus its median over the 30 s before the stall.
  - Host ↔ wall from `time.time() − time.monotonic()` at launch (the same mach clock).

| stall | renderer DRY, baseline | renderer DRY, hold | held (silence by design) | D at resume | recovery | worst lip-sync Δ vs the picture, baseline / hold |
|---|---|---|---|---|---|---|
| 300 ms | 0.05 s | **0** | 77 ms | 70 ms | 1 drop, 2.4 s after the resume | 26 / 80 ms |
| 400 ms | 1.89 s | **0** | 138 ms | 131 ms | 1 drop (121 ms), 3.2 s | 148 / 120 ms |
| 1000 ms | 14.1 s | **0** | 772 ms | 758 ms | 7 drops, 15.6 s | 735 / 193 ms |
| 2000 ms | **34.8 s** | **0** | 1752 ms | 1766 ms | 17 drops, 36.2 s | 1775 / 191 ms |

- **The minutes-long silences are gone.** The renderer never ran dry: 0 `[STARVE]` in the hold run,
  against 51 s in the baseline. What is left is the time held, i.e. the stall less the queue it
  had, which is the audio that did not exist yet.
- **Write count: 9 = the first anchor + 4 holds + 4 resumes.** Exactly two per stall.
  - Coarse events 0, splice fallbacks 0, unmatched 0.
  - Stage holes / overlaps / breaks 0.
- **Lip-sync against the PICTURE stayed within 193 ms, although D reached 1.77 s.**
  - The sender is late on video too, so the picture shows arrivals behind `now()`, and the audio,
    held behind `now()` by D, stays near it (§18.16's "never catches up" reasoning holds while the
    catch-up lasts).
  - D is owed against LiveClock's line, not against the picture.
  - The baseline's large figures are where its timebase sat while the renderer played silence.
- **Recovery:** drops of ~100 ms about every 2 s, since the queue grows 50 ms/s at 1.05×. So the
  2 s stall costs 17 skips, each across a 10 ms fade.
  - A tuning choice for Robbie: fewer, larger drops, i.e. a larger `recoveryMinimumDropSeconds`,
    means more time late and fewer skips.
- **Back within ±5 ms of the pre-stall figure:** hold 26 / 24 / — / 80 s; baseline — / 26 / — / 94 s.
  "—" means the next stall came first.
  - Both builds are limited by the same thing: after a stall, LiveClock's line slews at its rail,
    and ρ sits at ±B (86.7 s at the rail with the hold, 103.4 s without).
  - `i` winds to −258 / −297 ppm on both. That is §13.4's rail class, pre-existing, not caused by
    the hold.
- **⚠️ The 300 ms stall is the borderline case.**
  - The baseline ran dry for 50 ms. The hold build held 77 ms and dropped 70 ms 2.4 s later.
  - Add the ~50 ms renderer mute on each of the two rate writes (§11.11; not re-measured, there
    was no device capture tonight), and a borderline stall is slightly WORSE with the hold. Longer
    stalls are far better.
- **⚠️ The hold write returns 33–37 ms after the decision.**
  - Read back afterwards, the timebase is exactly the held point (−0.00 ms), and the resume read
    agrees.
  - The call itself blocks longer than the 20 ms margin. Whether the renderer plays past the
    frontier inside the call cannot be seen from the log (`[STARVE]` saw nothing).
  - A device capture of one stall settles it. If it does, M goes to ~40 ms, trading more
    borderline holds for none dry.
- **Healthy windows:** every window with a pre-enqueue low-water under 150 ms was a stall or its
  recovery. The healthy windows read ≥ 286 ms.
- **OBS live, healthy, on this build** (`obslocal-starve`, 8 min, 22:52–23:01):
  - **0 holds, 1 write**;
  - lowest pre-enqueue queue **280.8 ms**, 14 × the margin;
  - 0 `[STARVE]`;
  - decoded content A/V −119.46 ms (the §18.15 A/B read −119.25 / −119.21), glass −135.37 ms.
- `swift test` 133 / 133; Profile build clean.
- **Not done:** Release build; a device capture of a stall (mutes and the hold write's landing); a
  live burst redelivery; WHEP or NDI with induced stalls.

### 18.18 Cloudflare SRT drift: OBS or Cloudflare? — offline half done 2026-09-29 night; live half waiting for the ingest URL

**Could arrival timing let Manifold see the drift itself? No.**
- On SRT the audio target is LiveClock's line, which is paced by VIDEO timestamps against arrival.
  So the renderer queue (audio frontier − timebase) walks at exactly the rate at which the audio
  timestamps diverge from the video timestamps in real time.
- In both drifting sessions it is flat:

| session | content drift (device / stream) | renderer queue, OLS after 180 s | 5-min block medians |
|---|---|---|---|
| §18.12 `avlag-srt-cloudflare` | −12…−15 ppm (−20 to −24 ms / 23 min) | **+0.25 ± 0.36 ppm** | 204.6 204.3 204.3 204.3 204.6 204.9 204.5 203.5 ms |
| §18.10 `ruleA-srt-cloudflare` | −29 ppm (−40 ms / 23 min) | **−0.45 ± 0.35 ppm** | 200.4 200.8 201.8 202.3 201.7 199.3 ms |
| §18.4 local SRT (reference, no drift) | ~0 | −1.16 ± 0.42 ppm | 341.4 … 340.6 ms |

- A 15–29 ppm divergence of the timestamps would have walked the queue 20–40 ms. It walked ≤ 1 ms.
- With §18.10's probe (audio PTS = the sample count, video PTS = the frame count), this means
  timestamps and arrival agree with each other throughout. **The drift is between the CONTENT and
  its own timestamps**: the picture or the sound slides against its PTS inside the stream.
- Nothing Manifold receives besides the content itself carries it, so only a content probe (§19.2's
  calibration mode) can see it.

**Live half, not run:** publish the flash-beep fixture with ffmpeg (single clock, H.264 + AAC) to
Cloudflare's SRT ingest, record Cloudflare's SRT playback with ffmpeg for 25 min (`-c copy
-copyts`), and measure drift from content (`probe_av.py`) and timestamps (`probe_ts.py`). Waiting
for the ingest URL.

### 18.19 Stall catch-up: one cut for the whole debt, small cuts only while the picture stays late — 2026-09-30

**Decided by Robbie (2026-09-30), option A of the morning's analysis.** The request was "back within
±20 ms in ≤ 3 s after audio resumes". That can be met only when the audio it needs has ARRIVED: a
forward splice can drop only content in hand. So the time to sync is ≥ D / (k − 1) for a sender
catching up at k×, whatever the cut rule. At ffmpeg's default 1.05× that is ≈ 20 × D, and the picture
is late by nearly as much.

#### The rule (`LiveAudioResampleSteering`, header "THE STARVATION HOLD")

| part | rule | figure |
|---|---|---|
| **resume** | once the refill leaves R queued past the held point: at once if it arrives under 2× real time (measured over 15 ms), otherwise wait for up to 100 ms more so a burst lands before the restart is placed | R = 100 ms, window 100 ms |
| **the debt D** | while owed, re-measured on every read as line − content heard, so if LiveClock moves its line during the catch-up the debt moves with it | fold under 20 ms |
| **the picture** | `LiveClock.Mapping.pictureLate` = now() − the newest frame that has arrived, floored at 0; its catch-up rate is measured over 0.5 s from the resume | on the line: ≤ 50 ms |
| **whole-debt cut** | picture on the line, or reaching it within 1 s at its measured rate: ONE drop of D as soon as the queue holds D + keep + fade + margin | up to 4 s (the stage's new drop bound) |
| **tracking cuts** | picture late and staying late: a drop whenever the audio is ≥ 100 ms behind the PICTURE (D − pictureLate), from what the queue holds | ≥ 100 ms, the late-audio detectability threshold (~125 ms, BT.1359) |
| **partial** | picture on the line for 1 s and the whole debt still not queued: drop what the queue holds | ≥ 100 ms |
| **spacing** | the next cut waits for the last one's length + 0.25 s | — |
| **residual** | for 60 s after the debt is repaid (or after a resume that owed nothing): ONE splice (drop or insert) of the error once \|e_f\| > 20 ms, instead of the ratio crawling it back at 2 ms/s | 20 ms |

- **Writes are unchanged:** the hold and the resume, two per stall. Cuts and the residual are splices.
- **A drop is no longer bounded by the ring.** `LiveAudioSplicer` keeps a drop's 10 ms fade-out aside
  once it has arrived. The skipped content streams through unfed, and the fade-in is taken as it
  lands. Inserts stay at 1 s. The coarse branch keeps its own 1 s bound.
- **Healthy streams:** no hold means D stays 0, no watch opens, and `pictureLate` is never read. The
  loop is the loop of §18.16.

#### Offline (`LiveAudioStarvationHoldTests`, queue model)

- ⚠️ **§18.16's offline 1.05× cases were bursts.** The plant accrued catch-up credit through the
  stall, so the first packet after it delivered `stall × catchUp` at once. Fixed: a stalled sender
  accrues nothing. The live §18.17 run was a real 1.05× catch-up and is unaffected.
- The plant now models the picture (same sender, same axis: late = line − sent), inserts, and a
  line LiveClock moves.
- New cases:
  - 3× catch-up: one cut, sync ≤ 2.6 s.
  - 1.05×: tracking cuts, audio never ahead of the picture.
  - Line slewed back 150 ms during recovery: no early audio (fixed bookkeeping left +138 ms live in
    §18.17).
  - One residual splice for a 60 ms line move after a hold, and none without a hold.
  - A 2.5 s drop through the real stage: bit-exact outside the fade, and the fade = cos·x[r0] +
    sin·x[to].
- `swift test` **138 / 138**. Profile build clean (`.build-cc/recut2-Profile`).

#### Live, unattended, local SRT (ffmpeg listener, `ref-nob.ts`, `STALLS="60:300 100:400 150:1000 210:2000"`)

`run.sh` now takes `READRATE_CATCHUP` (ffmpeg `-readrate_catchup`). Analysis: `stalls2.py` (scratch).
- **Silence** = time held + renderer DRY (`[STARVE]`).
- **Sync** = resume → the first `[AV-LAG]` audio − now within ±20 ms of its pre-stall median for 5 s
  (1 s resolution).
- **Lip-sync** = `[AV-LAG]` av and `[AV-CONTENT]` beep − flash on glass, each minus its pre-stall
  median, worst from the resume to the next stall.

**Default 1.05× catch-up** (`recut2-slow`, 14:19–14:26):

| stall | silence | D at resume | sync (measured / from the log) | cuts (ms) | largest | worst lip-sync vs picture (AV-LAG / beeps) |
|---|---|---|---|---|---|---|
| 300 | 0.134 s | 107 ms | 3.5 / 2.5 s | 77 whole + 23 residual | 77 | 104 / 125 ms |
| 400 | 0.183 s | 154 ms | 4.4 / 3.4 s | 119 whole + 26 residual | 119 | 145 / 167 ms |
| 1000 | 0.818 s | 787 ms | 15.4 / 14.8 s | 6 × ~103 tracking, 73 whole, 27 residual | 106 | 171 / 178 ms |
| 2000 | 1.825 s | 1793 ms | 41.0 / 33.4 s | 14 × ~102 tracking, 142 partial, 29 whole, 28 residual | 142 | 151 / 175 ms |

**Burst, `-readrate_catchup 20`** (`recut2-burst`, 14:26–14:33):

| stall | silence | D at resume | sync | cuts | worst lip-sync vs picture |
|---|---|---|---|---|---|
| 300 | 0.186 s | 0 (on target) | 0.3 s | 0 | 11 / 26 ms |
| 400 | 0.230 s | 0 | 0.2 s | 0 | 10 / 27 ms |
| 1000 | 0.849 s | 0 | 0.9 s | 0 | 17 / 23 ms |
| 2000 | 1.866 s | 868 ms | 1.9 s | 1 × 867 ms, whole | 873 / 854 ms (until the cut is heard) |

- **Writes: 9 in both sessions = the first anchor + 4 holds + 4 resumes.** Coarse 0, fallbacks 0,
  unmatched 0, renderer DRY 0.
- **No stalls** (`recut2-healthy`, 14:34–14:40): 0 holds, **1 write**, 0 cuts, 0 residual splices.
  The lowest queue before an enqueue was 283.5 ms, and ρ was never at its rail.
- **Met:** ≤ 3 s and one cut whenever the audio has arrived (every burst row). Never dry. Writes as
  before. Healthy unaffected.
- **Not met at 1.05×, and not meetable:**
  - Time to sync is the sender's catch-up: 15 s at 1000 ms, 33–41 s at 2000 ms.
  - Cuts stay ~100 ms because they track a picture that is late by nearly as much. Lip-sync against
    it stayed within 104–178 ms (§18.17: up to 193).
- **The 2000 ms burst:** 2 s of backlog at 20× did not all land inside the 100 ms window. The
  restart owed 868 ms, and the audio was that far behind the picture until the one cut was heard,
  1.5 s later. The window trades silence against that case; a longer one costs every burst more
  silence.
- ⚠️ **The resume costs more than §18.16's on a slow sender.** Held 134 / 183 / 818 / 1825 ms
  against §18.17's 77 / 138 / 772 / 1752, with a 26 ms content skip at each restart (4.8 ms before).
  - The first ~15 ms of a 1.05× refill arrives faster than 2× (the socket's backlog), so the probe
    reads it as a burst and waits.
  - A tuning item: a longer probe, or a probe that starts after the first refill packet.
  - The first build, with a fixed 100 ms wait, held 219 ms on the 300 ms stall.
- ⚠️ **The residual splice does not end the post-stall excursion at 2000 ms.**
  - LiveClock's line kept moving after the one residual splice, and ρ spent 86 s at its rail over
    the session.
  - That is why the 2000 ms sync reads 41 s measured against 33 s from the log.
  - Pre-existing (§13.4's rail class). One splice per hold, as specified; repeated residual splices
    are the option if wanted.
- **Not done:** the device capture (below); WHEP and NDI with induced stalls; a Release build.

#### Revision 2026-09-30 afternoon (Robbie): no longer hold on a slow refill; repeat the residual splice

- **Burst classification.** The refill is classified once, when it reaches R, by its mean rate since its
  first packet after the stall. Under 2× the restart is placed at once (§18.16's rule). Otherwise the
  100 ms window applies, unchanged. The RESUME line logs the rate and the decision.
- **Residual splices repeat.** Each time |e_f| > 20 ms, at least 2 s apart. Each one extends the watch
  60 s, so it stays open while LiveClock keeps moving its line.
- `swift test` **139 / 139**. Profile build `.build-cc/recut3-Profile`.

**Default 1.05×** (`recut3-slow`, 15:12–15:19):

| stall | held (§18.17) | restart skip | refill rate → decision | D at resume | sync (measured / from the log) | cuts (ms) | worst lip-sync vs picture |
|---|---|---|---|---|---|---|---|
| 300 | 100 ms (77) | +5.0 ms | 1.85× → at the fill | 95 ms | 3.4 / 2.6 s | 78 whole | 84 / 112 ms |
| 400 | 161 ms (138) | +4.8 ms | 1.12× → at the fill | 151 ms | 4.3 / 3.4 s | 123 whole | 121 / 144 ms |
| 1000 | 799 ms (772) | +4.8 ms | 0.79× → at the fill | 783 ms | 15.3 / 15.0 s | 6 × ~103 tracking, 65 whole, 2 × 27 residual | 166 / 188 ms |
| 2000 | 1806 ms (1752) | +4.7 ms | 0.79× → at the fill | 1784 ms | 33.9 / 33.5 s | 14 × ~102 tracking, 124 partial, 24 whole, 4 × 26 residual | 164 / 174 ms |

- **The hold is §18.16's again.** Every restart was placed at the fill, with the same 4.8 ms skip.
- **The extra held time is the sender's.** ffmpeg's lag after SIGCONT was 16 / 17 / 27 / 15 ms longer
  than in §18.17 (0.425 / 0.396 / 1.124 / 2.143 s against 0.409 / 0.379 / 1.097 / 2.128). Each hold
  began at the same queue: 319–324 ms without input, 19.4–19.7 ms queued.
- **The rail: 19.7 s over the session, against 86 s** with one residual splice. The 2000 ms stall's
  measured sync now agrees with the log (33.9 / 33.5 s, against 41.0 / 33.4).
- 9 writes (anchor + 4 holds + 4 resumes). DRY 0.

**Burst, `-readrate_catchup 20`** (`recut3-burst`, 15:19–15:26): ⚠️ **regressed against recut2.**

| stall | held | refill rate → decision | D at resume | sync | cuts | worst lip-sync vs picture |
|---|---|---|---|---|---|---|
| 300 | 185 ms | 3.70× → waited | 0 | 0.5 s | 0 | 10 / 19 ms |
| 400 | 130 ms | 1.64× → at the fill | 123 ms | 1.3 s | 1 × 122 | 126 / 100 ms |
| 1000 | 750 ms | 1.31× → at the fill | 740 ms | 2.1 s | 1 × 739 | 745 / 753 ms |
| 2000 | 1770 ms | 1.08× → at the fill | 1754 ms | 3.1 s | 1 × 1752 | 1761 / 1748 ms |

- **A 20× refill starts slowly.** Its first 100 ms arrived at 1.08–1.64× and only then accelerated.
- **A 1.05× refill can start fast.** 1.85× on the 300 ms stall, its socket backlog.
- **The two ranges overlap, so a rate taken at the fill point cannot separate them.**
  - recut2's 15 ms probe after the fill caught the bursts, but held the slow sender 57 ms longer.
  - Measured from the refill's start, the slow sender is right and the bursts are missed.
- One whole-debt cut per stall, and sync within 3.1 s. But the audio was D behind the picture until
  the cut was heard.
- **No stalls** (`recut3-healthy`, 15:26–15:33): 0 holds, **1 write**, 0 cuts, 0 residual splices.
  The lowest queue before an enqueue was 289.2 ms, and ρ was never at its rail.

#### The device check (`devcheck-2`, 2026-09-30 15:41–15:48, recut3) and option 2 — ✅ CLOSED

**Device check:** local SRT with stalls of 300 / 400 / 1000 / 300 ms, recorded by Audio Hijack and the
OBS recorder, analysed with `scripts/soak/analysis/devicecheck.py`. That script reads the content
lost or repeated in each beep gap, as the gap − its exact-zero time − 1000 ms.
- **Cuts and residual splices are clean on both recorders.** All 12 were heard at their logged sizes,
  none with zeros, and nothing unexplained anywhere in the capture.
- **The hold write loses no programme.**
  - The writes returned 28–35 ms after the decision, longer than the 20 ms margin. The renderer
    played exactly its queue: audio stops +20.0…20.6 ms past the held point, i.e. the 19.4–19.7 ms
    still queued.
  - Then it idled inside the silence. M stays 20 ms.
- **The restart write mutes, per Audio Hijack.** Audio returned 55–79 ms after the logged restart
  point: 35–59 ms of programme lost per stall.
  - The OBS recorder read −17…+11 ms at the same restarts, but it also shortened the held silences
    by 10–25 ms (AV_SYNC_FINDINGS.md §1.2 records both recorders' limits).
  - **Decided by Robbie:** §11.11 is settled (each rate write mutes ~50 ms), and the restart write's
    cost is accepted.
- Both 300 ms refills read just over 2× (2.04 / 2.07) and waited as bursts. That is the classifier
  failure below.

**Option 2 (Robbie, 2026-09-30): no refill classifier; a catch-up WRITE for a burst's debt over 125 ms.**
- **The restart** is §18.16's again: on the first enqueue that leaves R queued, with no
  classification and no wait.
- **The catch-up write.** Taken when the whole debt is in the queue within 1 s of the restart (the
  picture on the line) and the debt is over 125 ms, the late-audio detectability threshold. ONE
  timebase write puts the content heard on the line.
  - A cut is heard only after the late queue in front of it plays out: after a burst, D behind the
    picture for about D.
  - The write costs one ~50 ms mute, accepted.
- A debt under 125 ms, or one that arrives later (a slow catch-up), is still taken by a cut.
- Counted as a write: `WriteOrigin.starvationCatchUp`, and "catch-up" on the END line.
- `swift test` **139 / 139**. Profile build `.build-cc/recut4-Profile`.

**Default 1.05×** (`recut4-slow`, 15:55–16:02):

| stall | silence | time to sync | cuts (ms) | largest | worst lip-sync vs picture (AV-LAG / beeps) |
|---|---|---|---|---|---|
| 300 | 0.083 s | 2.4 s | 48 whole + 22 residual | 48 | 70 / 95 ms |
| 400 | 0.151 s | 4.2 s | 122 whole + 24 residual | 122 | 129 / 152 ms |
| 1000 | 0.784 s | 15.4 s | 6 × ~102 tracking, 72 whole, 2 × 28 residual | 104 | 172 / 165 ms |
| 2000 | 1.791 s | 33.9 s | 14 × ~103 tracking, 106 partial, 32 whole, 4 × 26 residual | 106 | 151 / 161 ms |

- Every restart was placed at the fill, with a 4.8–5.2 ms skip, as §18.16.
- **Writes 9** (anchor + 4 holds + 4 resumes; catch-up 0). DRY 0. ρ at its rail **10.8 s** over
  the session (86 s before the repeat residual splices).

**Burst, `-readrate_catchup 20`** (`recut4-burst`, 16:02–16:09):

| stall | silence | D at resume | action | time to sync | worst lip-sync vs picture (AV-LAG / beeps) |
|---|---|---|---|---|---|
| 300 | 0.067 s | 61 ms | 1 cut, 59 ms | 1.4 s | 59 / 21 ms |
| 400 | 0.120 s | 113 ms | 1 cut, 112 ms | 1.3 s | 115 / 97 ms |
| 1000 | 0.753 s | 743 ms | **1 catch-up write**, 0.26 s after the resume | 1.0 s | 10 / 557 ms (one beep inside the 0.26 s before the write) |
| 2000 | 1.740 s | 1724 ms | **1 catch-up write**, 0.26 s after the resume | 1.0 s | 17 / 33 ms |

- **Writes 11** (anchor + 4 holds + 4 resumes + 2 catch-up). DRY 0. ρ never at its rail.
- **Against recut3's burst run:** the 1000 / 2000 ms stalls were 745 / 1761 ms behind the picture
  until a cut was heard, and synced in 2.1 / 3.1 s. Now it is one write after 0.26 s, and sync in
  1.0 s.
- **Healthy path:** unchanged by option 2, which only acts on a debt. recut3's no-stall session
  stands: 0 holds, 1 write.

**The rule, final:**
- Hold at the 20 ms margin, and restart on the first 100 ms of refill.
- The debt is re-measured against the line on every read.
- A burst's debt over 125 ms, whole within 1 s, is taken by ONE catch-up write.
- Otherwise ONE whole-debt cut once the queue holds it, with ~100 ms cuts only while the picture
  stays late.
- Residual splices over 20 ms, ≥ 2 s apart, while LiveClock moves its line.
- ≤ 3 s is met whenever the audio has arrived. At 1.05× the time to sync is the sender's catch-up.
- **Not done:** WHEP and NDI with induced stalls; a Release build.

### 18.20 The level-based WHEP correction — design, 2026-09-30

**Asked (Robbie, 2026-09-30).** Replace §18.7's rate-based fallback (BUGS.md, "THIS RELEASE: the
depth-slope fallback should hold the queue's LEVEL") so a lagging SR staircase unwinds by itself.
Design first — the control law, the feedback-loop proof, the interactions with rail events, the
buffer target and the stall hold, and why it cannot false-engage on Cloudflare — then an offline
replay of every WHEP log. **Pass:** Cloudflare unchanged; MediaMTX within ±10 ms at +26 min relative
to the session start (§6.3). Report before any live run.

#### Quantities (per 10 s steering window k)

| symbol | what | depends on the correction? |
|---|---|---|
| D_k | the window's median renderer queue depth | yes, one for one (the loop tracks its target) |
| O_SR(x) | the SR line's offset at video time x | no |
| C(x) | the correction the target adds | — |
| O_a = O_SR + C | the offset the target applied | yes |
| u_k = O_a,k − D_k | the media line: b_true·t + c (§18.7's invariant) | **no** (only a transient, below) |
| D_ref | median of D_k over 60–120 s after the connect: the session start (§6.3's start window) | no |

Lip-sync walk ∝ D − D_ref (§18.7). Holding D at D_ref holds lip-sync at the session start, whatever
the SRs do.

#### The control law

1. **The media line, robustly.** Each window: û = the Theil–Sen line of u against x over the trailing
   W = 300 s, evaluated at x.
2. **The level error the SR line alone would give:** E_k = (O_SR(x_k) − û(x_k)) − D_ref. This is the
   queue depth the target would produce with C = 0, less the reference. Both terms exclude C.
3. **Engage** when |E| > E_on = 12 ms at every window for T_on = 180 s.
4. **Engaged, the target offset is the queue's line:** O*(x) = D_ref + û(x). The applied offset is
   Ô(x), which reaches O*(x) at ≤ 150 ppm (§18.7's catch-up rate, the slope clamp) from wherever it
   was. The correction the fit adds is C(x) = Ô(x) − O_SR(x). Then D = Ô − u → D_ref once Ô = O*. The
   SR line drops out of the target, and its stairs drop out with it.
5. **Disengage** when |E| < E_off = 4 ms at every window for T_off = 600 s. Ô then returns to O_SR(x)
   at ≤ 150 ppm, and C → 0. **Nothing is kept:** once released, the SR line is used exactly.

**Why it unwinds by itself.** A stair raises O_SR, but the engaged target does not contain O_SR, so
nothing double-counts. Unlike §18.7, no rate is integrated, so there is no excess to give back. When
the SRs catch up, E returns inside E_off and the correction is released with it.

**A false engagement costs at most the level error, and ends.** Engaged on correct SRs, D is held at
D_ref, which differs from what the SR line would give by E (≤ E_on + the sustain's growth). The
disengage test then sees |E| < 4 ms, and releasing moves lip-sync by < 4 ms. Under §18.7 the same
event left a permanent random walk (15.7 ms under A, 25.9 under C, §18.9).

#### The feedback-loop proof

- **The decision (E) has no feedback path.** O_SR excludes C by construction, and u is independent of
  C in steady state: a correction moves O_a and D together (§18.7's invariant).
- **The target (û) has one path: the resampler loop's lag.** The loop is PI, kp 0.1 s⁻¹, ki 0.0025
  s⁻², critically damped, time constant ≈ 20 s. So D follows O_a through a lag τ ≈ 20–40 s, and u
  carries a transient ≈ τ · dÔ/dx.
- **Small-gain bound.** The map Ô → û is (τ·s) followed by a robust line fit over W, whose response
  to a change of slope Δ in its input is at most ≈ 1.5·Δ·τ/W in level. The loop gain is therefore
  ≤ 1.5·τ/W = **0.15 at τ = 30 s, W = 300 s**. That is < 1, so the loop is stable whatever its phase.
- **Bounded by the slew limit.** |dÔ/dx − b| ≤ 150 ppm, so the transient in u is ≤ τ · 150 ppm =
  **4.5 ms** at τ = 30 s, and it decays with τ once the slew ends. It is never integrated: the next
  fit sees it at ≤ 0.15 gain, and it vanishes.
- Tested closed loop at τ = 0 / 10 / 30 s (the §18.7 harness).

#### Interactions

- **Rail events, pauses, splices.** These move D by up to ~100 ms for tens of seconds (§13.4, §18.8).
  - The Theil–Sen line over 300 s ignores up to 29 % of its 30 points, i.e. an excursion shorter
    than ~85 s.
  - The 180 s sustain rejects anything the fit passes for less than that.
  - The worst case measured is Cloudflare's rail event 9, below.
- **The buffer target: D_ref follows deliberate line moves.** A LiveClock position jump of j (snap,
  freeze-guard, queue-full, target-step; + = the picture moved forward) moves the audio queue by −j
  and leaves O_a unchanged, so u moves by +j.
  - On every jump D_ref −= j, and the stored u points shift by +j. E and the engaged target are then
    unchanged by the jump, and the latency change is kept, not undone.
  - The buffer / latency work (post-release) moves the queue's target through the same jumps, so
    nothing more is needed there.
  - None of the seven WHEP logs has a jump over 23 ms (the 4.5 h run has two freeze-guard re-anchors
    of +23 / 0 ms).
- **The stall hold (§18.19).**
  - A window containing a hold, a recovery debt, a catch-up write, or a splice or fallback is not fed
    to the fit, the sustain or the decision. During recovery D is deliberately off its level, and
    that is the stall's own bookkeeping, not SR error.
  - Engaged or not, the state is kept across the gap.
  - The steering reports these in `WindowFacts`.
- **The SRs stay primary.** Not engaged, the target is the SR line exactly (C = 0). The queue is
  measured in-app, and nothing branches on the server (CLAUDE.md).
- **The slope cross-check's WARNING is unchanged** (log only, §18.7).

#### Why it cannot false-engage on Cloudflare — measured before choosing E_on

The level error E of the SR line alone (C = 0), from the closed-loop replay run log-only on every
WHEP log (300 s Theil–Sen line, against D_ref at 60–120 s):

| session | server, SR shape | max \|E\| | E at +26 min | first \|E\| > 10 / 12 / 15 ms |
|---|---|---|---|---|
| srfix-whep-cloudflare-long (4.5 h) | Cloudflare | **8.5 ms** (9400 s, rail event 9) | +6.0 | never |
| step4e2-cloudflare | Cloudflare | 4.3 ms | +0.9 | never |
| step4e2-cloudflare-2 | Cloudflare | 3.2 ms | +2.6 | never |
| step8-whep-soak (§18.5) | MediaMTX, staircase | 34.2 ms | −33.4 | 240 / 280 / 620 s |
| srfix-whep-mediamtx | MediaMTX, staircase | 24.1 ms | −21.3 | 1111 / 1131 / 1161 s |
| srtest1-flat (extrapolated, 61.4 ppm) | MediaMTX, flat | 100.2 ms | −95.8 | 250 / 290 / 330 s |
| srtest2-flat (extrapolated, 73.0 ppm) | MediaMTX, flat | 118.8 ms | −113.5 | 230 / 260 / 300 s |

- **E_on = 12 ms** is 3.5 ms above the largest level Cloudflare reached in 4.5 h (8.5 ms, at a
  rail event), and a third of the smallest MediaMTX deviation at +26 min.
- The 180 s sustain adds margin in time: Cloudflare would need to hold > 12 ms for 3 minutes; its
  largest excursion does not reach 10.
- **If it did engage, it costs ≤ the level error while engaged, and < 4 ms after release** (above).
  The forced-engagement sweep (§18.9's method) measures that.

#### Built and replayed offline, 2026-09-30 — no live run yet

**Code.**
- `SenderReportSlopeCrossCheck`: the rate state machine is replaced by the level hold above. The
  slope WARNING is unchanged.
- `SenderReportLineFit.evaluate` passes the SR line to `correction(atVideoTime:srOffset:srSlope:)`.
- `WindowFacts.excluded` is set by holds, recovery debt, resumes, catch-up writes, splices, fallbacks
  and caller re-anchors (not the first anchor).
- `FrameEngine.liveAudioPositionJump` forwards every LiveClock jump to `noteLineJump`.
- Two details found in testing:
  - A goal change of ≤ 1 ms is taken as is rather than slewed. Each window's refit moves the goal by
    a fraction of a millisecond, and slewing it made the reported slope ring at ±150 ppm.
  - The excess's slope is capped at what clears it within one window.
- `swift test` **142 / 142**: 8 level-hold tests replace §18.7's fallback tests (flat SRs, loop lag
  0/10/30 s, never engages on three correct-SR shapes, a lagging staircase unwinds and releases with
  nothing kept, a forced false engagement ≤ 10 ms and released, no flapping at the threshold, a line
  jump kept, excluded windows not read). Profile build clean (`.build-cc/level-Profile`).
- Replay tool: `scripts/soak/replay/level/main.swift` (`replay-level`, built by `build.sh`).

**Replay, closed loop, every WHEP log** (§18.7's invariant; start = median depth 60–120 s,
+26 = 1560–1690 s):

| session | engaged | start → +26 min | worst from the start (after 120 s) | SR line alone: start → +26 |
|---|---|---|---|---|
| step8-whep-soak (§18.5, staircase) | 750 s | **−0.8 ms** ✅ | −31.9 ms at 430 s | −23.4 ms |
| srfix-whep-mediamtx (staircase) | 1281 s | **+0.4 ms** ✅ | −20.5 ms at 1221 s | −15.6 ms |
| srtest1-flat (extrapolated, 61.4 ppm) | 479 s | **+0.7 ms** ✅ | −25.3 ms at 480 s | −85.2 ms |
| srtest2-flat (extrapolated, 73.0 ppm) | 479 s | **+0.8 ms** ✅ | −29.7 ms at 480 s | −101.4 ms |
| step4e2-cloudflare | never | −0.4 ms | −113.1 ms (its 1651 s rail event) | **identical** |
| step4e2-cloudflare-2 | never | +2.7 ms | +4.2 ms | **identical** |
| srfix-whep-cloudflare-long (4.5 h) | never | +6.4 ms | −52.1 ms (the 6027 s pause) | **identical** |

- **MediaMTX: all four sessions within ±1 ms of the start at +26 min** (requirement ±10).
  - The worst mid-session excursion is the level at engagement: −20…−32 ms. Under §18.7's rate rule
    it was −59 / −70 ms on the flats.
- **Cloudflare: unchanged, bit for bit.** The replayed queue depth equals the SR-only replay's in
  every window (difference 0.000000000 ms) on all three sessions: the hold never engaged.

**§18.9's forced-engagement sweep** (engaged at every minute from 300 s; error = forced depth −
unforced depth, from the force on):

| log | forced | peak \|error\| worst / median / p90 | released by itself | \|error\| at the log's end |
|---|---|---|---|---|
| step4e2-cloudflare | 32 | 5.7 / 3.2 / 5.7 ms | 16 of 32 (median 10 min) | ≤ 1.1 ms |
| step4e2-cloudflare-2 | 31 | 3.6 / 3.5 / 3.6 ms | 22 of 31 (median 11 min) | ≤ 2.3 ms |
| srfix-whep-cloudflare-long (4.5 h) | 267 | **12.4** / 9.0 / 12.4 ms | 257 of 267 (median 105 min) | ≤ 3.2 ms |
| *§18.9, rule A on the 4.5 h log* | 262 | 15.7 / 1.7 / 4.9 ms | 241 of 262, the error KEPT | worst +14.8 ms |

- ⚠️ **The ≤ 10 ms bar fails on the 4.5 h log, by 2.4 ms. By construction, not by a defect.**
  - Engaged, the hold keeps the queue at the session start. On that log the SR line alone sits
    +6…+8.5 ms off the start for hours (the level table above).
  - So "forced − unforced" there is the SR line's own departure from the start, plus the fit's noise.
    Its median is 9.0 ms because that departure lasts.
  - For the same reason, release (|E| < 4 ms for 10 min) takes a median 105 min.
- **What does hold:**
  - Every forced run is back on the SR line within ≤ 3.2 ms at the log's end, with nothing kept.
    Under A the error was permanent (+14.8 ms).
  - The two 4e-2 sessions stay ≤ 5.7 ms.
- **The question for Robbie:** under §6.3's adopted criterion (lip-sync relative to the session
  start), the forced run on that log is the one nearer the start. Is the sweep's reference the SR
  line (the bar fails at 12.4 ms), or the session start?

**✅ DECIDED 2026-09-30 (Robbie): the forced-engagement sweep is judged against the SESSION START.**
- This is consistent with criterion 12 as adopted (§6.3: lip-sync relative to the session start).
- On the 4.5 h log the device drifted ~−10 ms while following the SR line, which shows the start is
  nearer the truth there. So the 12.4 ms "forced − unforced" above is the SR line's departure from
  the start, not an error of the hold.
- **The measure.** Each forced run's queue level (a 300 s rolling median, so a rail event or pause —
  common to every run, and short — does not count) against the start (60–120 s). Taken from 10 min
  after the force (the catch-up done), while engaged or releasing. Bar: ≤ 10 ms, and back on the SR
  line by itself.

| log | forced | worst \|level − start\| while held | released by itself | \|forced − unforced\| at the log's end |
|---|---|---|---|---|
| step4e2-cloudflare | 32 | **0.8 ms** | 16 of 32 (the rest: the log ended first) | ≤ 1.1 ms |
| step4e2-cloudflare-2 | 31 | **0.4 ms** | 22 of 31 | ≤ 2.3 ms |
| srfix-whep-cloudflare-long (4.5 h) | 267 | **1.1 ms** | 257 of 267 | ≤ 3.2 ms |

- **✅ Passes.** A false engagement holds the session start within 1.1 ms, releases by itself, and
  leaves nothing when released. The "forced − unforced" columns above are kept for comparison with
  §18.9.
- `replay-level sweep` prints both measures.

### 18.21 MediaMTX live run with the level hold applied — ❌ device lip-sync moved +98.6 ms between captures; the hold becomes OBSERVE-ONLY — 2026-09-30

**Run:** `level-whep-mediamtx`, 2026-09-30 16:41–17:24, `.build-cc/level-Profile` (the §18.20 hold,
applied). OBS → MediaMTX (WHIP) → Manifold (WHEP), the soak rig: controls, captures at +3 / +26 min,
noise segment +5:30 → +25:30.

**In the log, the hold did what §18.20 says.**
- **Engaged at 481 s.** The SR line alone had put the queue −16.4 ms off its start level
  (424.3 ms, taken at 60–120 s).
- **Held to the end:** the queue read 424.6–424.9 ms against 424.3.
- **This session's SRs** carried +17.7 ppm (two +5.4 ms re-levels during capture B) against the
  media's ~69 ppm. The SR line alone would have ended −58.5 ms off.
- 1 timebase write, no holds or splices, no LiveClock jumps. Mutes 0 (the tracker's three hits are
  the noise segment's edges).

**At the device it failed** (`c12.py`, every gate passing on every recording; zero = the mean of the
controls, −0.9 / +2.5 → +0.8 ms):

| | grid-corrected | against zero | gate |
|---|---|---|---|
| capture A (+3 min) | −73.5 ms | **−74.3 ms** | ±20 ❌ |
| capture B (+26 min) | +25.2 ms | **+24.4 ms** | ±20 ❌ |
| B − A | | **+98.6 ms** | |
| start → +26: (B − A) + depth term (−10.1 ms) | | **+88.5 ms** | ±10 ❌ |

**The 88 ms is not in anything Manifold measures.** Between A and B the queue moved +10.5 ms, which
is all the lip-sync walk the queue invariant (§18.7) allows. The two readings of which line was the
truth predict:

| if the truth is… | B − A predicted | measured |
|---|---|---|
| the queue (the premise of the hold) | +10.5 ms | +98.6 ms |
| the SR line (so the hold's correction is the error) | ≈ +58.5 ms (+69 with B's re-levels) | +98.6 ms |

Neither fits.
- Capture A's absolute (−74.3 ms) is also far from the previous MediaMTX session at +3 min
  (−14.9 ms, `srfix-whep-mediamtx`), with every gate passing.

**Transient analysis (connect → +5 min, per 10 s window): no transient at the reference or at
capture A.**
- The loop settled by ~50 s: |e_f| ≤ 1 ms, the integrator flat at −53…−71 ppm, never saturated.
- LiveClock's buffer held 394–404 ms against its 400 ms target. Its rate hunts on its ±0.5 % rails
  in every period, as normal on WHEP.
- The SR offset was flat to 3 µs; its slope came into use at 110 s.
- The queue drained at a steady ~−65 ppm from 10 s (431 → 424 → 418.5 → 409.7 ms). That is the
  flat-SR drain itself, with no knee.
- Both the 60–120 s reference and capture A (180–312 s) were taken in steady state. Neither can be
  discarded as mid-transient.

**OBS and MediaMTX logs: no hiccup near either capture, in this run or in the passing one.**
- Sender (4455): no lagged frames (rendering), no skipped frames (encoding), no audio-buffering
  change and no audio-timestamp warning during the session.
- Recorder (4456): no dropped frames during either capture or either control.
- MediaMTX: one publish session and one read session, no reconnects, no warnings, no losses
  reported.
- **The one difference between the runs is the sender's OBS audio buffering: 42 ms here (a fresh
  launch at 16:40), 85 ms on Sep 28** (grown 42 → 64 → 85 ms over that day's session, last step 32
  min before the run; AV_SYNC_FINDINGS.md §1.2).
  - It is constant within each session, so it cannot make a change between A and B.
  - It can shift the absolutes between days.
- The orchestrator's 40 s sender probe at +65 s is shorter than one 41.7 s grid period, so it
  cannot be read. That is the instrument this run lacked.

**The settled-reference rule, applied to this log in hindsight.**
- The first span that qualifies is 120–180 s: SR slope in use from 110 s, the integrator moving
  9.9 ppm, LiveClock within ±4 ms, nothing excluded. Reference 419.6 ms, against 424.2 at 60–120 s.
- The depth term becomes −5.5 ms, and start → +26 +93.1 ms. The rule does not explain the failure
  (none was expected: nothing was unsettled).

**✅ DECIDED 2026-09-30 (Robbie), decision B:**
1. **The level hold is OBSERVE-ONLY this release.**
   - `SenderReportSlopeCrossCheck.levelHoldApplies = false`: one flag, off, not user-facing;
     research builds flip it.
   - Everything is computed and logged: the reference, E, the sustain timers, "WOULD ENGAGE" /
     "WOULD RELEASE" / "WOULD BE OFF", and the session summary says observe-only.
   - `correction` returns zero, so the target, the rate and the splices are untouched.
   - Test `testObserveOnlyHasNoEffectOnOutput`: on a session where the applied hold engages, the
     observe-only run logs WOULD ENGAGE and its queue equals the log-only run's in every window,
     exactly, with the correction 0 throughout.
2. **The settled-reference rule** replaces the fixed 60–120 s, for the hold's reference and for
   §6.3's capture-side start.
   - The reference is the first 60 s of consecutive windows with: the loop unsaturated and its
     integrator moving < 10 ppm across the span; the SR slope in use; LiveClock's picture buffer
     within ±10 ms of its target (new: `LiveClock.Mapping.bufferError`); no hold, splice or write
     (an excluded window) inside.
   - It is logged once per session, as "LEVEL REFERENCE set … span a–b s". `depth_term.py` takes the
     start from that line (60–120 s, flagged, for older logs).
   - Tests: waits for the SR slope, waits for the integrator, restarts on saturation, a LiveClock
     excursion or an excluded window, and a line jump shifts the candidates.
3. **An open research item:** the 88 ms swing, and whether the queue invariant holds on MediaMTX.
   - Next instrument: `go.sh mediamtx --diag`, a 135 s sender probe at capture A and at capture B,
     aligned with them, analysed into `<SOAK_OUT>/soak-<label>-diag/`.
   - Relaunch the sender OBS first (AV_SYNC_FINDINGS.md §1.2).
4. MediaMTX with OBS over WHEP is a known limitation this release (BUGS.md).

`swift test` **148 / 148**. The replay tools opt into the applied hold explicitly (research).

**§18.20's replay, re-run with the settled reference** (the hold's reference is now the settled span;
the tool's "start" is still the 60–120 s median, so a draining flat-SR queue reads a few ms lower):

| session | engaged | start → +26 min (was, §18.20) |
|---|---|---|
| step8-whep-soak | 780 s | −3.3 ms (−0.8) |
| srfix-whep-mediamtx | 1331 s | −3.1 ms (+0.4) |
| srtest1-flat / srtest2-flat | 499 / 479 s | −1.7 / −2.2 ms (+0.7 / +0.8) |
| the three Cloudflare sessions | never | unchanged, bit-identical to the SR line |

All within ±10 ms. None of this is live: the hold is observe-only.
