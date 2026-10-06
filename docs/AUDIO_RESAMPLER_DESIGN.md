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
> **MediaMTX:** set `useAbsoluteTimestamp: true` on the path you play over WHEP. On its default
> settings MediaMTX replaces the sender's timing reports, and lip-sync can drift over a long session
> (§18.22–§18.25).
>
> **OBS at 23.976 fps over WHIP.** OBS stamps 23.976 video very slightly fast (about a quarter of a
> second an hour). Cloudflare Stream, and MediaMTX with `useAbsoluteTimestamp: true`, correct it and
> sound stays in sync. On MediaMTX's default settings it shows as a slow drift that a reconnect resets.
> 25, 29.97, 30, 50 and 60 fps are not affected (§18.25).

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

### 19.7 Stage A built: the offset term and its splice — 2026-10-01 (unattended; uncommitted)

**Decided by Robbie (2026-10-01):**
- Range −250…+500 ms, one constant (`LiveAudioResampleSteering.userOffsetRange`). One splice per
  change, never chained.
- An advance larger than the queue allows is REFUSED whole. The refusal reports the most available
  now: queue − 100 keep − 10 fade − 50 margin, the recovery guard.
- The existing drift figure stays blind to O. One new log figure, "heard A/V", includes it.
- SDI: a change crossfades. Pinned mode has no O. Sign: O > 0 = audio heard later.

#### What was built

| part | where | rule |
|---|---|---|
| **O in the line** | `LiveAudioResampleSteering.setReference` / `anchor` | every line handed in is stored as `media − O`, so D (re-measured against the line, §18.19), the resume and the catch-up write all see it. D never takes O |
| **the change** | `setUserOffset`, under `transition` | the line moves by −ΔO and `requestSplice(−ΔO)` is granted in the same step. No write, no coarse event, no ρ step. Not anchored yet: stored and placed by the next anchor, with no splice |
| **refusals** | same | outside the range: REJECTED. Advance > queue − 160 ms: REFUSED with the figure. Stage refused: REFUSED. Pinned: NOT APPLIED, logged once. O is unchanged in every case |
| **NDI** | none needed | its anchor goes through the same `anchor`, so it carries O, and a change uses the same entry point. No re-anchor |
| **the app's entry** | `FrameEngine.setLiveAudioOffset` | only an accepted (or pending) O reaches the SDI read |
| **SDI** | `LiveReadOffsetFader` (LiveAudioResample), owned by `AudioTapBuffer` | `read` serves `startTime − O`, a change crossfaded equal power over 10 ms (the stage's fade). Set while a live session is open, cleared in `endLiveAudio`. At O = 0 the read is the old read, untouched |
| **level hold** | `WindowFacts.offsetMoved` → `windowLines(offsetMoved:)` → `noteUserOffsetMove` | the reference is re-based (D_ref + ΔO, u − ΔO) in window order, and the window with the change is excluded, like a recovery window |
| **figures** | see below | `liveAudioDrift` adds O back (blind). `liveAudioHeardMinusClock` does not, and feeds the renderer's `[AV-LAG]` / `[AV-CONTENT]` |
| **log** | steering | one line per change (old → new, splice, queue, accepted or refused with the available figure). The window line ends `heard A/V med … (O …)`; the END line ends `audio offset O … (n change(s), n refused)` |
| **testing hooks** | app, `#if DEBUG` behind `DebugMenuGate`; FrameEngine `liveAudioStartOffset`, `nudgeCurrentLiveAudioOffset` | `MANIFOLD_AUDIO_OFFSET_MS` (the start value); Debug ▸ Audio Offset +10 / −10 / +50 / −50 / Reset. **Remove in stage B** |

- ⚠️ **Where O is subtracted differs from the brief's wording:** inside the steering, not by
  FrameEngine and NDI before they call it.
  - FrameEngine computes its line on the mapping thread. A change arrives from another.
  - A line computed with the old O and landing after the change would step the line back by ΔO
    for one evaluation, and that is a step trigger.
  - Under the steering's `lock`, the line move and the stored line are one write. The effect the
    brief asks for holds: `refMedia` carries −O, which is what D, the resume and the catch-up read.
- ⚠️ **The renderer's at-glass hook now reads the heard figure, not `liveAudioDrift`.**
  - `avcontent.py`'s glass is `beep − (now + audio−now)`, and `audio−now` was `liveAudioDrift`.
  - Made blind, it would have hidden O from the very figure the live gate reads.
  - So `liveAudioDrift` (the routers' `timebase−clock`) and the paired probe's reference stay blind
    (O added back, or taken off the reference). `[AV-LAG]` and `[AV-CONTENT]` show what is heard.
  - Identical at O = 0. While a change sits in the renderer's queue (≤ ~0.5 s), the blind figure
    reads the step the listener has not heard yet.

#### O = 0 is HEAD b35a810

- **`swift test`: 148 / 148 unchanged**, before the new tests were added. With them, **158 / 158**.
- ⚠️ **One pre-existing flake.** `testSteeringCallsItsCompanionWithoutReportingWindows` failed once
  (2 logged vs 3 facts) in one full run under build load.
  - The race is in the test: its wait ends on `facts`, and the companion's line reaches `log` after
    its facts entry.
  - 0 / 40 alone and 0 / 10 full runs, both at HEAD and on this tree. Not changed: the brief says
    existing tests pass unchanged.
- **Replays, before and after, byte-identical.** Built from HEAD and then from the final tree (the
  same `swiftc` lines as `replay/build.sh`), and run on copies of the saved inputs in
  `~/Desktop/manifold-soak/level/`:
  - Sessions: `srfix-whep-cloudflare-long`, `srfix-whep-mediamtx`, `step4e2-cloudflare`,
    `step4e2-cloudflare-2`, `step8-whep-soak`, `step8-srtest1`, `step8-srtest2`, plus `synth` at
    66.6 ppm.
  - Tools, each on every session: `replay-after`, `replay-closed` (fallback and logonly),
    `replay-level` (level and logonly), `replay-offset-lock`.
  - **59 / 59 files identical**: 8 stdout reports and 51 trace TSVs. For example `step8-whep-soak`
    `level`: start → +26 −3.3 ms, worst −31.9 ms at 430 s, end −2.5 ms, before and after.
  - The Python analyses only read logs, so they cannot move.
- **Log formats:** only tails were added (window line, END line, the fit's summary only when a change
  was re-based). `extract.py`, `depth_term.py` and `srfit-live.sh` anchor before them;
  `soaklog.test.mjs` 8 / 8.
- **Builds:** Profile (`.build-cc/offsetA-Profile`) and Release (`.build-cc/offsetA-Release`), no
  errors. No new warnings.

#### Offline (`LiveAudioOffsetTests`, 10 tests, on §18.16's `QueuePlant`)

| test | result |
|---|---|
| 0 → +80 → +200 → −40 → 0 ms | 4 changes = 4 splices of exactly −ΔO, 1 write, 0 coarse / residual / recovery. \|e\| < 0.5 ms through every change. ρ and max \|ρ−1\| equal the no-change run's within 0.5 ppm. D 0 throughout. Heard on the old value 50 ms before each change and on the new one 1 s after, within 0.5 ms |
| start value | pending, then placed by the first anchor: no splice, 1 write, heard = O |
| stall with O = +150 / −100, at 1.05×, a 1000× burst, and 30× (the catch-up write) | 1 hold, never dry, D = 0 at end, writes as with O = 0. Heard − O and e equal the O = 0 run's within 1 ms; the 1.05× residual is the loop's own (−2.65 ms in both). **D = D₀ − O**: 612 / 762 ms (+150), 862 / 762 ms (−100), 978 / 1128 ms on the 30× burst. The physical debt, never O more |
| a change while D is owed (2 s stall, 1.05×, +50 ms at +3 s) | D unchanged within 3 ms across it; recovered, heard = O |
| advance past the guard | −250 at a 340 ms lead: REFUSED, available = queue − 160 ms exactly. −150 accepted. A further −50: REFUSED (queue ≈ 180 ms). 1 splice in all |
| out of range | +501, −251, NaN rejected; +500 accepted |
| pinned | NOT APPLIED; O 0, no splice |
| NDI anchor line | a start O is placed by the first anchor; a change takes one splice and no re-anchor; a later re-anchor keeps O; 2 writes (anchor and the test's re-anchor) |
| SDI read (`LiveReadOffsetFader`) | O = 0 is the plain read, bit-exact. +100 ms: 480 frames cos/sin from the old position to the new, then exact. A fade across two reads carries its position. `clear()` gives the plain read again |
| level hold re-base | +200 ms in the window at 600 s: D_ref 400 → 600 ms, E 0, implied slope 0, no WOULD ENGAGE, no warning. Without the re-base: E +200 ms and WOULD ENGAGE |

#### Live, unattended, non-Cloudflare

Both runs used the Profile build, `MANIFOLD_DEBUG_MENU=1` (no `defaults` written), the
`ref-nob.ts` fixture (23.976, −60 dBFS floor), and the click schedule
`0 → +80 → +200 → −40 → 0`, then a probe of −50 ×4, then 0. Each click is one Debug-menu change,
4 s apart; each plateau ≥ 28 s.
- **At glass** = `avcontent.py`'s `[AV-CONTENT]` glass per beep.
- **Grid-free** = glass − decoded (beep − flash PTS) per pair: the same figure without the fixture's
  beep-to-frame phase, which walks by up to a frame on this file.
- Δ is against the pooled O = 0 plateaus.
- Analysis: `analyze.py` (scratch).

**Local SRT** (`repro/run.sh`, ffmpeg listener, `MANIFOLD_SRT_DEBUG_URL`;
`offsetA-srt.manifold.log`, 18:28–18:34):

| O | at glass Δ (n) | grid-free Δ (p10–p90) |
|---|---|---|
| +80 | +88.2 ms (27) | **+80.4** (+77.8…+84.2) |
| +200 | +207.8 ms (27) | **+200.8** (+197.6…+204.1) |
| −40 | −48.2 ms (25) | **−39.5** (−42.8…−36.2) |
| −150 (probe) | −141.4 ms (18) | **−148.6** (−152.8…−145.5) |
| 0, at end | −0.1 ms (101) | −0.3 |

**ffmpeg → MediaMTX → WHEP** (ffmpeg re-encoding `ref-nob.ts` to H.264 baseline, no B-frames, plus
Opus, published over RTSP; Manifold on the `MediaMTX Whip` bookmark, chosen by UI scripting;
`offsetA-whep.manifold.log`, 18:37–18:43):
- ⚠️ **The MediaMTX was the one already running**, on `mediamtx-soak-abs.yml`
  (`useAbsoluteTimestamp: true`), up since 2026-09-30 19:05 and idle. It was used as it was.

| O | at glass Δ (n) | grid-free Δ (p10–p90) |
|---|---|---|
| +80 | +72.7 ms (26) | **+79.9** (+77.1…+83.7) |
| +200 | +193.6 ms (25) | **+200.4** (+196.5…+204.6) |
| −40 | −31.2 ms (25) | **−39.6** (−43.2…−36.1) |
| 0, at end | +0.1 ms (48) | +0.1 |

| gate | local SRT | MediaMTX WHEP |
|---|---|---|
| changes accepted | 21 | 22 |
| splices executed (stage session totals) / abandoned | **21** / 0 | **22** / 0 |
| timebase writes (END) | **1** (the first anchor) | **1** |
| coarse events / splice fallbacks / unmatched | **0** / 0 / 0 | **0** / 0 / 0 |
| each change: grid-free step − ΔO, worst of all | **5.5 ms** | **4.9 ms** |
| the same at glass, 1–4 beeps a side | 41.7 ms | 24.6 ms |
| refusals | 1: −150 → −200, "a 50.0 ms advance needs 210.0 ms … the queue holds 174.3 ms: at most 14.3 ms … available" | 0 (the ~420 ms WHEP queue covers −200) |
| ρ range inside a change window, widest / quiet windows widest (median) | 173 / 414 (89) ppm | 158 / 466 (109) ppm |
| windows without a change: e med, \|e\| max | −0.9…+3.2 ms, 5.6 ms | −1.8…+3.4 ms, 5.4 ms |
| heard A/V − O (window medians, no change) | −3.2…+0.9 ms | −3.4…+1.8 ms |
| holds, recovery, residual splices, DRY | 0 | 0 |

- **Met:** every change moved what is heard by ΔO, far inside one frame on the grid-free figure. 1
  splice per change, 0 extra writes, 0 coarse events, on both servers.
  - The raw at-glass plateaus are within 8.9 ms. The rest is the fixture's grid phase: the two O = 0
    plateaus of the WHEP run differ by 7.5 ms between themselves.
  - The per-change raw steps (≤ 41.7 ms, 1–4 beeps a side) are the same phase noise. 41.7 ms is one
    frame at 23.976, so the SRT worst sits exactly on the bound on that figure.
- **The integrator** was +98 ppm at 20–30 s on SRT, before the first change, and decayed through
  every change with e_f within ±1.3 ms. It is a start-up transient, not the changes.
- ⚠️ **The level hold was not exercised live.** The WHEP session was 5 min with changes every
  ≤ 30 s, so no settled 60 s span formed. The summary reads "session-start level never set … 13
  window(s) excluded, 13 audio-offset change(s) re-based", and the slope check never ran (it needs
  540 s). The re-base is verified offline only.

#### Not done

- **Attended (Robbie):**
  - NDI from OBS with a change: the anchor line live.
  - DeckLink SDI output during a live session:
    - a change crossfades on the wire;
    - SDI moves with the desktop;
    - the offset is gone on file playback after the session ends;
    - an advance past what the tap holds plays silence and re-anchors the bridge's cursor.
  - A device capture (Audio Hijack and the recorder) of a few changes: what the listener hears,
    and the ~50 ms mute that a change does NOT cost (no rate write).
- **Unattended, not run:**
  - a WHEP session long enough for the level reference (≥ 60 s settled before the first change and
    ≥ 10 min after the last), to see the re-base and the excluded windows live;
  - pinned mode live (the NOT APPLIED line);
  - a change during a starvation hold or recovery, live;
  - a Release-build run (Release has no Debug menu, so it needs stage B's controls).
- **Stage B removes** `MANIFOLD_AUDIO_OFFSET_MS`, Debug ▸ Audio Offset,
  `FrameEngine.liveAudioStartOffset` and `nudgeCurrentLiveAudioOffset`. (Done, §19.8.)

### 19.8 Stage B built: the bookmark field, the live nudge, the indicator — 2026-10-01 (unattended; uncommitted)

On top of stage A (`98d1f69`).

**Decided by Robbie (2026-10-01):**
- Range −250…+500 ms (stage A's constant). O > 0 = sound later.
- Nothing is drawn over the picture, as for the Bypass marker (COLOR_MANAGEMENT_FINDINGS.md §6.8).
  The indicator is a control-bar badge plus the window-title suffix " — A/V +80 ms".
- Full screen has no marker: an accepted limit, as for Bypass.

#### What was built

| part | where | rule |
|---|---|---|
| **the stored value** | `StreamBookmark.audioOffsetMs: Int?` in the new leaf target `StreamBookmarkModel` | Optional, nil = 0. 0 is stored as absent (`StreamBookmarkStore.storedAudioOffset`), so a bookmark reset to 0 is byte-for-byte one that never had an offset |
| **the test's home** | `Packages/ManifoldCore/Sources/StreamBookmarkModel`, `Tests/StreamBookmarkModelTests` | see below |
| **the sheet field** | `StreamBookmarksSheet.audioOffsetField` | "Audio offset [ ] ms". Hint, one line: "Positive = sound later, negative = earlier (−250 to +500 ms)." Parsed and range-checked at Save (`StreamBookmarkStore.parseAudioOffset`) against `FrameEngine.liveAudioOffsetRangeMs`, which is derived from the steering's one constant. The saved value also shows on the bookmark's row ("A/V +80 ms") |
| **the session value** | `LiveAudioOffsetModel`, one per window (`WindowDeck.audioOffset`) | set at connect by `DeckRegistry.connectLive`, the one funnel, from the bookmark (or 0), before the transport opens: the first anchor places it with no splice. `FrameEngine.liveAudioSessionOffset` keeps it for every audio session the connect opens (a transport's own reconnect keeps it) |
| **the nudge** | `TransportKeyMonitor.audioOffsetNudge` | ⌥] / ⌥[ = ±1 ms, ⇧ = ±10 ms, while the window has a live source and no text field is being edited. Exact modifier flags and physical keys (ANSI 30 / 33), not key equivalents |
| **the control** | `AudioOffsetControl`, in the control bar while live | "A/V" menu: the four nudges (keys named in the titles), Reset to 0 ms, **Save +80 ms to "…"**, Revert to Saved. Not a saved stream: "this offset lasts for this connection only" |
| **the badge** | the same view, beside the menu | O ≠ 0 only: filled cyan capsule (sRGB 0.35 / 0.80 / 1.00), black "A/V +80 ms". Nothing at O = 0 |
| **the title** | `WindowDeck.windowTitle`, case 5 | " — A/V +80 ms" before any " — Bypass", while this window owns a live source and O ≠ 0 |
| **refusals** | `LiveAudioOffsetModel.set` → `engine.playbackNotice` | whole or not at all, in plain words, in the window's notice banner (auto-dismisses after 9 s) |
| **HLS** | model `isAvailable`; the control; the sheet field | no offset: the control reads "A/V offset — not on HLS", greyed; the sheet field is disabled with "Not for HLS — Apple's player owns the audio."; a nudge says so |
| **⌃⌥D override** | `ContentView`, ⌃⌥D | no bookmark, so a session value only (the menu has no Save). ⌃⌥D's own bookmark path and ⌃⌥H pass their bookmark |
| **stage A hooks removed** | `ManifoldApp.swift`, `FrameEngine` | `MANIFOLD_AUDIO_OFFSET_MS`, Debug ▸ Audio Offset, `liveAudioStartOffset`, `nudgeCurrentLiveAudioOffset` and the current-engine registry behind it |
| **flaky test** | `docs/BUGS.md`, pre-ship | `testSteeringCallsItsCompanionWithoutReportingWindows`: the race and the fix written up; the test is not changed |

**The test's home: a leaf package target, not an app test target.**
- `StreamType` and `StreamBookmark` moved verbatim from `App/Preferences.swift` into
  `StreamBookmarkModel`, a leaf target the app links as a product, like `DisplayProviders` (and
  `project.yml` lists it).
- So the test decodes with the REAL type, inside `swift test` with the rest, with no app host,
  keychain or licence prompt.
- An app test target would need `xcodebuild test` with the app as host, which raises the unsigned
  build's licence prompt: not something that runs unattended. The store (`StreamBookmarkStore`) stays
  in the app.

**The chord check (asked for before choosing keys): no conflict.**
- ⌥] ⌥[ ⇧⌥] ⇧⌥[ are bound nowhere:
  - none of the `.keyboardShortcut`s in App/ (all ⌃⌥ letters or digits, ⌘ menu items, or bare
    keys);
  - no `CommandMenu` (Debug, Color, View, File) and no macOS standard menu item;
  - `TransportKeyMonitor` passes every ⌘/⌃/⌥ chord through.
- **Nearest neighbours:** ⌃⌥[ / ⌃⌥] step LiveClock's target depth (`stepLiveTargetDepth`). They are
  compiled only in the **Debug** configuration (`MANIFOLD_CONFIG_DEBUG`), not in Profile or
  Release, and carry ⌃, so they are different chords.
- **Two hazards, avoided:**
  - AppKit's key-equivalent matcher ignores ⇧ on the arrow keys (TimecodeEntry.swift records it);
    brackets are the same risk, so the nudge reads the exact flags in the key monitor. Measured
    live: ⌥] → +1, ⌥[ → −1, ⇧⌥] → +10, each one change in the log.
  - ⌥[ types “ in a text field: the nudge is skipped while a field is being edited.
- **For the UI review:** physical keys. On a layout where [ and ] sit elsewhere (German: Ü and +),
  the chord is ⌥ plus the key in the US bracket position.

#### O = 0 is still b35a810

- `swift test`: **161 / 161** (stage A's 158, plus 3 bookmark tests). The pre-existing flake did not
  recur.
- Replays rebuilt from the final tree against the b35a810 outputs (§19.7's set, same tools): **59 /
  59 files byte-identical.**
- Builds: Profile `.build-cc/offsetB-Profile`, Release `.build-cc/offsetB-Release`; no errors, no
  warnings in any file touched.

#### The bookmark round trip

- `StreamBookmarkMigrationTests` (3), on a synthetic pre-feature blob in the stored shape (a real
  blob carries stream URLs, so none is committed):
  - every existing field equal, entry by entry; the new field nil;
  - re-encoded by the new type, byte-identical (sorted keys) to the pre-feature type's encoding,
    with no `audioOffsetMs` key;
  - a set value round-trips and only that entry carries the key; cleared, the key goes;
  - a new blob still decodes as the pre-feature type (going back a build loses nothing).
- **The real stored blob, read-only** (`defaults export`, scratch tool, contents never printed):
  1196 bytes, 7 entries, all four pre-feature keys only; decoded and re-encoded, every field of
  every entry equal; no `audioOffsetMs` key appears.
- **Save to Bookmark, live, against the real key.** `streamBookmarks` was read and stashed first
  (CLAUDE.md), byte for byte.
  - The save wrote `"audioOffsetMs": 80` on the MediaMTX entry only; the other six were field-for-field
    unchanged.
  - The sheet then showed it on the row and in the field (C01).
  - Afterwards, with Manifold quit, the stash was written back and read again: byte-identical
    (sha256 4466c076…).

#### The UI, rendered — screenshots in `~/Desktop/manifold-shots/stageB/`

Window captures (`screencapture -l`). The overlay HUD was woken with a pointer move. Pixel check:
- **Cyan** = the badge's colour, any profile within tolerance (R < 140, G 165–230, B ≥ 225).
- **Amber** = the banner's warning triangle and border. The window's own yellow traffic light alone
  gives 32.

| shot | state | title read back | cyan px (box) | amber px |
|---|---|---|---|---|
| A01 | WHEP, O = 0 | MediaMTX Whip - Locla | **0** | 32 |
| A02 | ⌥] ⌥[ then ⇧⌥] ×8 → +80 | … **— A/V +80 ms** | **1253** (x 1250–1339, y 1032–1050: the control bar) | 32 |
| A03 | the A/V menu after Save: Save and Revert greyed | … — A/V +80 ms | — (rect capture) | — |
| A05 | ⇧⌥[ ×12 → −40 | … **— A/V −40 ms** | 1273 | 32 |
| A06 | ⇧⌥] ×4 → 0 | MediaMTX Whip - Locla | **0** | 32 |
| B02 | SRT (⌃⌥D override), −151 ms, advance refused, banner | SRT debug URL — A/V −151 ms | 1317 | **113** |
| B03 | the menu on a connect with no bookmark: "Not a saved stream: …", no Save | — | — | — |
| B04 | +500, then ⌥] refused: "The audio offset can be set from −250 to +500 ms. It stays at +500 ms." | … — A/V +500 ms | 1351 | 113 |
| D01 | SRT, **"Can move sound earlier by at most 1 ms on this stream right now. It stays at −160 ms."** | … — A/V −160 ms | 1335 | 113 |
| C01 | sheet, editing MediaMTX: field 80, hint; the row shows "A/V +80 ms" | — | — | — |
| C02 | sheet, editing MTX HLS: field greyed, "Not for HLS — Apple's player owns the audio." | — | — | — |
| C03 | sheet, 600 typed, Save Changes: red "The audio offset must be between -250 and +500 ms."; nothing saved | — | — | — |
| C04 | HLS connected: "A/V offset — not on HLS", greyed; no badge | MTX HLS | 0 | 32 |
| C05 | HLS, ⌥]: banner "No audio offset on HLS — Apple's player owns the audio." | MTX HLS | 0 | 113 |

- **Every change was one splice and no write.** A (WHEP): 26 changes, 1 timebase write, 0 coarse
  events. A2: 41 changes, 1 write, 0 coarse events. B, D: each accepted press one `ACCEPTED` line.
- The cyan box is the same 18-pixel-high band on the control bar in every shot. Nothing was
  drawn over the picture.

#### The long WHEP run: the level hold re-bases on a change, live

ffmpeg → MediaMTX → WHEP (`offsetB-whep-level.manifold.log`, 19:36–19:52, 16 min connected).
- **One continuous 30-min fixture.** `ref-nob.ts` ×5 through ffmpeg's concat filter, H.264
  constrained baseline + Opus, published `-c copy`.
- ⚠️ **Why not `-stream_loop`:** the first attempt (`offsetB-whep-long`, 17 min) looped the 360 s
  file. Every wrap jolted the line (i +115 ppm saturated at 340 s, +497 ppm at 721 s), and with
  start-up drift no settled 60 s span formed until 851–911 s, after the last change. **Stage A's
  §19.7 WHEP run used the same loop**, and was too short to reach a wrap. Soaks should use one
  continuous file.
- The changes were keyed to the `LEVEL REFERENCE` line (the same MediaMTX as §19.7, still
  `useAbsoluteTimestamp: true`).

| time | event | renderer depth (window median) | heard A/V | level hold |
|---|---|---|---|---|
| 220 s | **LEVEL REFERENCE: 417.8 ms** (span 160–220 s, integrator moved 6.8 ppm) | 417.8 | −0.3…+0.2 ms | reference set |
| 290 s | +80 (⇧⌥] ×8) | 418 → 499 | +80.7 | window excluded, re-based |
| 591–601 s | −40 (⇧⌥[ ×12) | → 424, then 378 | −40 | excluded, re-based |
| 902–922 s | the refusal probe, ⇧⌥[ to −250 | → 202 at −250 | −220 → −250 | excluded, re-based |

- **Six slope cross-checks after the first change** (one a minute): SR −0.00 ppm against
  renderer-depth +0.13…+0.68 ppm; **queue level −0.2…+0.1 ms from the session start**.
- **The summary:** "session-start level **167.8 ms** … SR-line level error last −0.3 ms / worst
  +0.8 ms, never engaged · 6 window(s) excluded, **6 audio-offset change(s) re-based**".
  - 167.8 = 417.8 + 80 − 120 − 210: the reference moved by every change exactly.
  - Without the re-base, the +80 alone would have read as an 80 ms level error, and WOULD ENGAGE 180 s
    later (the offline test's control case).
- **The steering:** 41 changes, 1 timebase write, 0 coarse events; window e medians within ±1.1 ms
  except the change windows (−2.2 ms).
- **On WHEP the advance never refused.** The ~418 ms queue left ≥ 160 ms even at −250, so the
  range limit answered first. The refusal wording was shown on local SRT (B02, D01).

#### Found — for Robbie's decision, nothing changed for them

1. ⚠️ **"They do not auto-hide" holds for the title, not for the badge.**
   - The badge sits in the control bar. The default overlay HUD auto-hides it after a few seconds
     without the pointer, exactly as it does the Bypass badge (COLOR_MANAGEMENT §6.8, its open
     question).
   - Docked mode shows it permanently. The title suffix is the standing marker.
   - Making the badge standing in overlay mode needs either the HUD staying up while O ≠ 0, or
     drawing over the picture. That is a design call, not made here.
2. ✅ **RESOLVED in the follow-up below.** ~~"At most N ms" is an instantaneous figure.~~
   - D01 said "at most 1 ms" (1.3 ms, queue 161.3 ms). The next 1 ms press, 3 s later, was refused
     (queue 145.7 ms).
   - The queue moves by up to a packet (an AAC frame, ~21 ms on SRT) between enqueues, so the figure
     can promise a few ms the next press cannot get.
   - Options:
     - report from the window's low-water instead of the instantaneous queue (conservative; a stage A
       change);
     - or keep it, and word it "about N ms".
3. **The refusal is shown in the notice banner, which is drawn over the top of the picture** for 9 s,
   as every connect error already is. The no-overlay decision was read as covering the standing
   indicator, not a transient notice. Say if it should go elsewhere.
4. ✅ **RESOLVED in the follow-up below.** ~~The sheet's range error sits at the fold of the 540 pt
   list (C03), and prints "-250" with an ASCII hyphen.~~
5. **One launch stalled** before `[LICENSE]` (an unsigned Profile build; the launch-blocking keychain
   stall in BUGS.md), and a relaunch was clean. Not this change.

#### Follow-up, 2026-10-01 evening (Robbie): the advance figure and the sheet's range error

**1. The advance is judged on the queue's LOW POINT, not the momentary level.**
- **What changed.** `LiveAudioResampleSteering` keeps the renderer queue just BEFORE each enqueue
  (its lowest point in each packet cycle) in a 10 s ring (`advanceQueueWindowSeconds`, the steering's
  window). `setUserOffset` judges an advance on `min(queue now, that low point)`. The refusal and its
  "at most N ms" come from the same number.
- **Two corrections keep the history honest:**
  - it is cleared by every timebase write (anchor, resume, catch-up, fallback), which move the
    timebase;
  - an accepted change shifts it by the splice (−drop, +insert), so the next advance is judged on
    the queue that change leaves.
- The refusal log line now prints both, e.g. "the queue's low point over the last 10 s is 169.9 ms
  (now 192.2 ms)". O = 0 untouched: the ring is written only on the pre-enqueue read the
  low-water already took, and read only by `setUserOffset`.
- **Offline** (`testTheStatedAdvanceIsAcceptedOnALaterPress`, on `QueuePlant`, whose queue
  oscillates by one 21.3 ms packet, SRT's AAC frame):
  - ten request phases across one packet cycle: −150, then −250 refused;
  - exactly the stated whole-ms figure requested 3 s later: **accepted on 10 / 10**;
  - 1 ms more: refused on 10 / 10 (the figure is the most there is);
  - **the stage A (momentary) figure, pressed 3 s later: refused on 9 / 10 phases** — the test's
    teeth.
- **Live, unattended, local SRT repro** (`repro/run.sh`, ffmpeg listener, `MANIFOLD_SRT_DEBUG_URL`;
  `offsetB2-srt-advance.manifold.log`, 20:15–20:22). Each trial: step −10 ms until refused, read the
  figure, then 3 s later press ⌥[ exactly N times (1 ms each), then once more.

| trial | refusal (steering line) | stated | ⌥[ ×N, 3 s later | one more ⌥[ |
|---|---|---|---|---|
| 1 | low point 169.9 ms, **now 192.2 ms** → 9.9 ms available | **9 ms** | **9 / 9 accepted** | refused (1.0 → 0.99996 ms) |
| 2 | low point 164.7 ms, now 187.0 ms → 4.7 ms | **4 ms** | **4 / 4 accepted** | refused (0.7 ms) |
| 3 | low point 166.5 ms, now 178.5 ms → 6.5 ms | **6 ms** | **6 / 6 accepted** | refused (0.4 ms) |

- The momentary queue sat 12–40 ms above the low point. On trial 1 the stage A rule would have
  stated "at most 32 ms" (192.2 − 160) where 9 ms was there: D01's failure, by a larger margin.
- Screenshots: E01 (the trial 1 banner, "at most 9 ms", title "— A/V −130 ms"), E02 (−139 after
  the 9 presses).

**2. The sheet's range error is shown under the field, with a true minus.**
- The field's own errors (not a number, out of range) now REPLACE the hint, directly under the field,
  in red with an icon. They no longer appear with the save errors below the buttons, which sat at the
  fold. Cleared as soon as the field changes.
- **The message:** "The audio offset must be −250 to +500 ms." It is formatted by
  `LiveAudioOffsetModel.signed`, now `nonisolated`.
- **U+2212 everywhere a negative value is printed for the user:**
  - the badge, the title suffix, the refusal and range banners, and the field's not-a-number example
    already used `signed()` / "−" (checked: code point 0x2212);
  - the sheet's range error was the only hyphen, and it is fixed.
- **Screenshot F01** (`F01-sheet-range-error-visible.png`): the sheet with nothing scrolled.
  - Editing MediaMTX, 600 typed, Return (Save Changes): the red line sits between the field and the
    Save Changes / Cancel buttons, 316 red px at y 584–593 of the 720 px window.
  - Read back through accessibility: "The audio offset must be −250 to +500 ms.", the first
    character 0x2212.
  - Nothing saved: `streamBookmarks` sha256 4466c076… before and after.

**Gates:**
- `swift test` **162 / 162**.
- Replays against b35a810: **59 / 59 byte-identical**.
- Profile and Release build with no errors; no new warnings in the files touched.

#### Monday — the attended session (Robbie)

**Build:** `.build-cc/offsetB-Profile/Build/Products/Profile/Manifold.app`.
- Launch it by double-click: deny the licence prompt; allow the stream-passphrase prompt if one
  appears.
- **Stay connected for the whole of each block.** A disconnect starts a new session, and its
  offset with it.

**0. Set-up (≈ 10 min)**
1. Sender OBS (websocket 4455), scene `BLIPS_NOISE`. **Press play on `BEEPS`** (loop on) and
   leave it playing until block 3 ends. Turn on DistroAV's NDI output.
2. Manifold's volume up, not muted.
3. Recorder OBS, profile "Recorder", collection "AV Capture", 60 fps (AV_SYNC_FINDINGS.md §1.2). Do
   not start Audio Hijack yet: started before Manifold connects, it can quit or relaunch Manifold.

**1. NDI from OBS, with changes (≈ 10 min)**
1. Manifold: Connect Stream… (or the streaming chevron) ▸ the OBS NDI source.
   - The log should show `[AUDIO-OFFSET] connect (ndi) — session value 0 ms (no saved stream: this
     connection only)`.
2. Now start Audio Hijack. Re-pick Manifold in the recorder's macOS Audio Capture, and run the
   5-second preflight (beeps about −28 dB).
3. Start recording in the recorder. 60 s at 0. Then, 60 s on each value:
   - ⇧⌥] ×8 → +80;
   - ⇧⌥] ×12 → +200;
   - ⇧⌥[ ×24 → −40;
   - A/V menu ▸ Reset to 0 ms.

   Stop recording.
4. Pass:
   - `c12.py` on the capture: each plateau moves by its ΔO within one frame.
   - The log: one `AUDIO OFFSET … ACCEPTED` per press, and none of `NDI caller re-anchor`. The END
     line: `timebase writes 1` (plus one per Desktop Audio Lead change, if any), coarse 0.
   - Audio Hijack: no mute at the change times (a change writes no rate).
5. Leave NDI connected for block 2.

**2. DeckLink SDI during the live session (≈ 15 min), still on NDI**
1. DeckLink output on (⌃⌥O, or the DeckLink control). DeckLink options ▸ Audio: **SDI**. Watch and
   listen on the SDI monitor.
2. **The crossfade:** ⇧⌥] ×20 → +200, one press a second. Each change should be smooth on SDI: no
   click, no gap.
   - In the log, no `SILENCE · ring empty at the cursor (underrun)` and no `snapping source cursor`
     at the presses.
3. **SDI moves with the desktop.** The two cannot be heard together: the destination is SDI or
   Computer, never both.
   - At +200, judge lip-sync on the SDI monitor: sound clearly late.
   - DeckLink options ▸ Audio: Computer. The same +200 on the Mac.
   - Back to SDI. A/V menu ▸ Reset to 0 ms: both back in sync.
4. **An advance beyond what the tap holds.** From 0, ⇧⌥[ once a second until the banner refuses
   ("Can move sound earlier by at most …").
   - At each step, listen on SDI and watch the log for `SILENCE · ring empty` / `underrun`.
   - Note the most negative O that plays clean on SDI, against the renderer's refusal point. Expected:
     a gap on SDI if the tap's lead is shorter than the renderer's. Not yet measured.
5. **Offset gone after the session.** Leave O at a clearly non-zero value (e.g. +200), then
   disconnect NDI (⌃⌥⇧N).
   - With DeckLink output still on and SDI the destination, open
     `~/Desktop/Manifold-Test-Sources/criterion12-flash-beep-25p-60s.mov` and press play.
   - SDI must be in sync as before the session. The log has no `AUDIO OFFSET` line for the file.

**3. One device capture of a few changes.** Block 1's recorder capture is it. If block 1 was cut short,
repeat its step 3 on MediaMTX WHEP: OBS profile `MediaMTX Local`, Start Streaming, Manifold ▸ the
`MediaMTX Whip` bookmark.

**4. The UI review (≈ 15 min)**
- The badge's place: right of the display-transform control. Its colour (cyan, distinct from Bypass
  amber). And question 1 above: the badge hides with the overlay HUD.
- The keys under the fingers, including holding one down (auto-repeat makes one change per repeat,
  and each is a splice).
- The A/V menu's wording; Save / Revert to Saved; the "not a saved stream" line on NDI.
- The sheet: the field, the hint, the range error under the field (F01), the HLS note.
- The refusal banner's wording and place (question 3); the advance figure now holds for a later
  press (follow-up).
- Full screen: confirm there is no marker (the accepted limit), and that the title marker returns on
  leaving full screen.

**5. Stage D — calibration mode, attended (added 2026-10-01; §19.10). ≈ 2 h 45 min, of which 90 min
is a hold you only check on.**

**Build:** `.build-cc/stageD-Profile/Build/Products/Profile/Manifold.app` (the seven MP4 clips are
bundled). Same launch rules as above: deny the licence prompt; ALLOW the stream-passphrase prompt
(Cloudflare SRT will not dial without it).

**⚠️ Two rules for every block below:**
- **Stay connected from the first Start to the re-check.** A disconnect starts a new session: the
  applied value returns to the saved one and the re-check measures something else.
- **The clip must be playing BEFORE you press Start, and keep playing until the re-check's result.**
  Calibration needs the clip's flashes and beeps; the first figure takes 15–60 s (it waits for the
  stream to settle), the re-check 15–30 s.

**D0. Set-up (≈ 10 min)**
1. The clips: `build/syncclips/manifold-sync-23.976p.mp4` (and `…-29.97p.mp4` if a profile runs
   29.97). Or, once Manifold is connected, A/V ▸ Save Sync Clip… (it picks the stream's rate).
2. Sender OBS: in the scene you stream from, add a Media Source **SYNC** with the clip whose rate is
   the OBS profile's FPS (Settings ▸ Video): Loop ON, "Restart playback when source becomes active"
   ON, **Audio Monitoring OFF**, Mic/Aux muted. Its audio goes to the stream like `BEEPS` did. Hide
   `BEEPS` while SYNC is showing (one clip's audio at a time).
   - Or import `scripts/syncclips/obs-scene-collection.json` (README there; never import-tested,
     §19.9).
3. **Press play:** make SYNC visible (it starts and loops). Leave it playing for D1–D3 and D5.
4. Manifold's volume up, not muted. Recorder OBS ready (AV_SYNC_FINDINGS.md §1.2), **Audio Hijack
   not started yet**.

**D1. OBS → NDI (≈ 10 min)** — NDI applies for the session only, by decision.
1. Manifold: connect the OBS NDI source. Wait 30 s.
2. A/V ▸ **Calibrate…** ▸ **Start**. Watch "Pairs found" climb. Do not touch the nudge keys (a change
   restarts the measurement, and the sheet says so).
3. At the result, note "Sound is heard N ms early/late", the measured figure and "proposed …".
   - Expected from OBS: about −16…−22 ms (OBS's provisional +16…+22 ms, §19 header). ⚠️ But the
     unattended SDK sender, in sync by construction, read −67…−70 ms here (§19.10): D4's capture is
     what says whether NDI's figure is what you hear. Until then, note the figure and apply it only
     for the session.
   - The sheet must offer only **Apply for Session** (no Save), with "NDI: a result applies to
     this session only."
4. **Apply for Session.** The badge and the title show the value.
5. **Start** again. Pass: the re-check reads within ±2 ms ("Sound is in sync" or ±1–2 ms).
6. **Cancel.** Disconnect NDI.

**D2. OBS → Cloudflare SRT (≈ 10 min, then D4 and D5 on the same connection)**
1. OBS: the Cloudflare SRT profile, SYNC playing, Start Streaming.
2. Manifold: the Cloudflare SRT bookmark (allow the passphrase prompt). Wait 30 s.
3. Calibrate… ▸ Start. Expected: sound ~70–80 ms EARLY (§18.13), so proposed ≈ +70…+80 ms.
4. **Apply for Session** (or Apply and Save, if you want to keep it on the bookmark:
   A/V ▸ Reset to 0 ms, then Save 0 ms to "…", removes it again; 0 is stored as absent).
5. Start again. Pass: within ±2 ms. Cancel.
6. **STAY CONNECTED** for D4 and D5.

**D3. OBS → Cloudflare WHEP (≈ 10 min)** — run after D5, or in a second window while D5 holds; only
one window can stream at a time, so after D5 is simplest.
1. OBS: the Cloudflare WHIP profile, SYNC playing, Start Streaming. Manifold: the Cloudflare WHEP
   bookmark. Wait 30 s.
2. Calibrate… ▸ Start ▸ result ▸ Apply for Session ▸ Start ▸ pass within ±2 ms ▸ Cancel.

**D4. One Audio Hijack capture (≈ 10 min), on D2's connection, after its Apply** — and, if time
allows, a second on NDI (D1) after its Apply: the NDI question in §19.10
1. Now start Audio Hijack. Re-pick Manifold in the recorder's macOS Audio Capture; run the 5-second
   preflight (AV_SYNC_FINDINGS.md §1.2; the clip's tone reads about −20 dB less the path's losses;
   −91 dB is silence: stop and fix).
2. Record 60 s. Stop.
3. `python3 scripts/soak/analysis/c12.py <capture.mov>`.
   - ⚠️ c12 reads **+1.708 ms** on these clips by its onset rule (§19.9 Decisions 1). Pass: c12's
     grid-corrected median − 1.7 ms is within one frame of 0 — the applied offset removed
     Cloudflare's ~−75 ms at the device. The coded pattern makes c12's `g_grid` False: expected.

**D5. The 90-minute Cloudflare SRT hold (≈ 90 min, mostly unattended)** — §19.5's ❌ row, measured.
1. Same connection as D2/D4, the applied value in place, SYNC looping, OBS streaming. Do not
   reconnect.
2. At +0 (right after D2's re-check), +30, +60 and +90 min: Calibrate… ▸ Start ▸ note the measured
   figure ▸ **Cancel** (do NOT apply).
3. Read: the figure's walk over 90 min. §19.5 predicts 0 to −157 ms (the slope varies by session).
   Within ±10 ms = one calibration holds; beyond it, the user guide's "re-calibrate every 20–30
   minutes, or use WHEP" stands. The log keeps every run's `[CALIBRATION] RESULT`.
4. Then stop OBS streaming and disconnect.

**D6. The sheet and the menus (≈ 15 min)**
- The A/V menu while live: Calibrate…, Save Sync Clip…, Download ProRes Sync Clips… under the offset
  items (§19.10 screenshot M01).
- Help ▸ **Download Sync Clips…** and A/V ▸ Download ProRes Sync Clips…: both open
  `https://releases.graviton.tools/manifold/manifold-sync-clips-v1.zip` in the browser. It 404s
  until uploaded (BUGS.md pre-ship). Confirm the URL.
- Save Sync Clip…: the save panel's rate line ("This stream is 23.976 fps.") and its rate menu.
- The sheet's wording in each state: progress, result, not applicable (an advance beyond the queue:
  on local SRT, inject +250 ms, §19.10), NDI session-only (D1), HLS (connect `MTX HLS`: the control
  reads "A/V offset — not on HLS", its menu still has Calibrate…, whose sheet says it is not
  available), and "Sync clips aren't included in this build" (`.build-cc/stageD-noclips-Profile/…`).
- Proposed names, button order, and whether Apply and Save should be the default button.

### 19.9 Stage C built: the sync clips — 2026-10-01 (unattended; committed `dfe6463`; decisions below)

§19.3's clips, generated from committed recipes by ffmpeg alone (lavfi `color`, `drawbox`,
`drawtext`, `aevalsrc`; no media in, no other tool). Everything is in `scripts/syncclips/`
(README.md there):
- `recipes.tsv`, `generate.sh` → `build/syncclips/` (gitignored: already under `build/`, now also
  named explicitly);
- `verify.py`, `pairing_check.py`, `obs-scene-collection.json`.

#### What each clip is

| | |
|---|---|
| rates | 23.976, 24, 25, 29.97, 30, 50, 59.94 (exact rationals: 24000/1001 …) |
| length | 60 × round(rate) frames: 60 s, or 60.06 s at the 1001 rates. Every clip is a whole number of frames AND of samples (e.g. 1440 × 2002 = 2 882 880) |
| picture | black (Y 16 / 64); each event frame full-white (235 / 940); a burned-in grey label: "Manifold sync clip 23.976p · code 23-29-31-37 x1 · frame 000024" |
| sound | 1 kHz at −20 dBFS peak, exactly one frame period, phase 0 at the frame's exact boundary, 5 ms raised-cosine edges; a −60 dBFS RMS white-noise floor throughout (independent per channel) |
| code | events at frame F0 + unit × {0, 23, 52, 83} + unit × 120 × c, with F0 = round(rate) ≈ 1 s. Intervals 23 / 29 / 31 / 37 steps, repeating |
| containers | `.mov`: ProRes 422 (prores_ks profile 2, `apl0`), yuv422p10le, PCM s24le. `.mp4`: H.264 High yuv420p CRF 16, AAC-LC 256k, faststart. Both 1920×1080, bt709 / bt709 / bt709 / limited range in the stream and the `colr` atom, 48 kHz stereo |

- **Timing is never rounded.** The tone is computed from the exact boundary time k / rate
  (`aevalsrc`, per sample).
  - At 23.976 / 24 / 25 / 30 / 50 every boundary is an exact sample.
  - At 29.97 and 59.94, four frames in five fall between samples (k × 1601.6, k × 800.8). There the
    waveform is the exactly anchored tone, sampled.
- **Regenerate:** `zsh scripts/syncclips/generate.sh` (all, ~1 min on this Mac), or name labels.
  `FFPROBE=… <python with numpy> scripts/syncclips/verify.py --json out.json`, then `python3
  scripts/syncclips/pairing_check.py out.json`.
- **Nothing was installed** (Robbie, 2026-10-01: nothing system-wide). The tools already on the Mac:
  - ffmpeg 8.1.1 (Homebrew, already present);
  - ffprobe n8.1.1 from `Index/binaries/ffprobe-mac` (no ffprobe on PATH);
  - numpy for `verify.py` and `c12.py` from the existing audible-events venv.
- **Total output: 777 MB** (ProRes 755 MB, MP4 22 MB). §19.3's "~20 MB" holds for the MP4 set alone.
  The ProRes set is 77–171 MB a clip: keep it as the master and ship the MP4s, or shorten the
  ProRes. Robbie's call.

#### Deviations from §19.3 and from "passes c12", found and kept visible

1. **The code's unit is 2 frames at 50 and 59.94** (46 / 58 / 62 / 74 frames).
   - At 1 the shortest interval would be 0.46 s / 0.38 s, and `avsync.beep_times` merges onsets
     closer than 0.5 s: half the beeps would vanish.
   - With 2, every interval at every rate is 0.77–1.54 s, and the ±½-cycle range is ±2.0–2.5 s
     everywhere.
   - One column in `recipes.tsv`; 1 restores the literal frame code.
2. **c12's `g_grid` is False on every clip, by design.** It fits the beeps to a 1.000 Hz grid; the
   coded pattern is uneven so that it cannot be mis-paired. `verify.py` restates the gate for the
   code: the white frames are exactly the coded frames, and the intervals follow the code.
3. **c12's "level between beeps" reads the next tone** whenever an interval is under its fixed
   100–900 ms window: −40.5 dB at 29.97 / 30, −44.5 dB at 59.94, against −57.0 / −57.5 dB elsewhere.
   `verify.py` measures from 10 ms after a tone to 10 ms before the next: −60.0 dBFS RMS (MOV), −60.5
   (MP4).
4. **c12 reads +1.67…+1.69 ms, not 0.0, on every clip** (sd 0.01 ms).
   - avsync's onset is the first sample above 25 % of the peak. On §19.3's 5 ms raised-cosine edge
     that is 1.708 ms after the tone starts (1.713 ms at 29.97 / 59.94, the sub-sample phase), less
     its 0.0417 ms `FIXTURE_OFFSET_MS`.
   - The clips are at 0.0 (below). The detector's definition of an onset is not.
   - **Decided (Robbie, 2026-10-01): c12 stays unchanged.** Its +1.708 ms on these clips is a
     known property of its onset detector, and `verify.py` is the clips' gate. See "Decisions" below.

#### Every clip, both containers — `verify.py` (all 14 PASS)

ffprobe read-back, on every file:
- **Video:** 1920×1080; frame count = the recipe's; r_frame_rate as the recipe; colour tags
  bt709 / bt709 / bt709 / tv.
- **Codecs:** `.mov` is prores Standard yuv422p10le + pcm_s24le; `.mp4` is h264 High yuv420p + aac.
- **Audio:** 48 kHz, 2 channels.

A/V per event = the tone's onset (from its 1 kHz phase over the flat middle, < 1 µs) − the white
frame's pts, both channels.

| clip | frames / duration | events | flash pts − k/rate | A/V worst (MOV / MP4) | tone peak | c12: beeps · pairs · median |
|---|---|---|---|---|---|---|
| 23.976p | 1440 / 60.060 s | 48 | 0.000 µs | 0.156 / 0.314 µs | 0.0998–0.1002 | 48 · 48 · +1.68 / +1.67 ms |
| 24p | 1440 / 60.000 s | 48 | 0.000 µs | 0.118 / 0.182 µs | 0.0998–0.1002 | 48 · 48 · +1.69 ms |
| 25p | 1500 / 60.000 s | 50 | 0.000 µs | 0.175 / 0.231 µs | 0.0998–0.1001 | 50 · 50 · +1.69 / +1.68 ms |
| 29.97p | 1800 / 60.060 s | 60 | 0.000 µs | 0.199 / 0.290 µs | 0.0998–0.1001 | 60 · 60 · +1.67 / +1.68 ms |
| 30p | 1800 / 60.000 s | 60 | 0.000 µs | 0.198 / 0.284 µs | 0.0998–0.1001 | 60 · 60 · +1.67 ms |
| 50p | 3000 / 60.000 s | 50 | 0.000 µs | 0.432 / 0.542 µs | 0.0997–0.1001 | 50 · 50 · +1.69 / +1.68 ms |
| 59.94p | 3600 / 60.060 s | 60 | 0.000 µs | 0.396 / 0.552 µs | 0.0997–0.1002 | 60 · 60 · +1.67 / +1.68 ms |

- **0.0 ms on every event: worst 0.55 µs.**
  - The MP4's AAC priming is compensated by its edit list (ffmpeg honours it): the MP4 worst is the
    MOV worst + < 0.2 µs.
  - Measured on the decoded stream, as a player honouring the edit list hears it.
- **Also on every file:**
  - c12's other gates hold: `g_count` True, `doubled` 0;
  - no burst outside a tone;
  - the floor −60.0 dBFS RMS (−55.2 peak) in MOV, −60.5 (−50.9) in MP4.

**Frame boundaries at 23.976 and 59.94**, where rounding would slip:

| clip | boundary position in samples | events | beep onset − exact boundary, worst | flash pts − k·1001/rate |
|---|---|---|---|---|
| 23.976p .mov / .mp4 | exact (k × 2002) | 48 | 0.156 / 0.314 µs | 0.000 µs |
| 59.94p .mov | +0 sample / +1/5 / +4/5 | 15 / 15 / 30 | 0.295 / 0.252 / 0.396 µs | 0.000 µs |
| 59.94p .mp4 | +0 / +1/5 / +4/5 | 15 / 15 / 30 | 0.426 / 0.333 / 0.552 µs | 0.000 µs |

One sample is 20.8 µs. No boundary slipped by one, at any sample phase.

#### The coded pairing — `pairing_check.py` (a scripted check, all 14 PASS)

A scripted check, not a Swift test: no Swift pairing code exists until stage D's calibration mode,
and a Swift test now would test a stand-in.

On each clip's MEASURED timeline (from `verify.py --json`), beeps shifted by δ (dropping any that
leave the clip), then paired back by the coded matcher. For every index shift s, the offsets
b(i+s) − f(i):
- the score is the median absolute deviation from their median;
- a candidate needs ≥ ½ the flashes and an offset inside ±½ cycle;
- the smallest score wins.

The test, per clip:
1. 101 offsets across ±½ of the shortest interval;
2. a deliberate one-interval mispair: δ = ± each coded interval (8);
3. 399 offsets across the whole ±½ cycle;
4. the same again with ±10 ms of uniform jitter on every beep.

| rate | cycle / shortest interval | recovery, worst (508 offsets) | with ±10 ms jitter | wrong-pairing margin | one-interval mispair (δ = +1 interval) |
|---|---|---|---|---|---|
| 23.976 | 5005.0 / 959.3 ms | 0.006–0.010 µs | 4.87 ms | 41.7 ms | coded +959.3 ms ✓ · nearest-neighbour −250.3 ms ✗ |
| 24 | 5000.0 / 958.3 ms | 0.010–0.024 µs | 4.87 ms | 41.7 ms | +958.3 ✓ · −250.0 ✗ |
| 25 | 4800.0 / 920.0 ms | 0.022 µs | 5.25 ms | 160.0 ms | +920.0 ✓ · −240.0 ✗ |
| 29.97 | 4004.0 / 767.4 ms | 0.006–0.013 µs | 4.97 ms | 33.4 ms | +767.4 ✓ · −200.2 ✗ |
| 30 | 4000.0 / 766.7 ms | 0.021 µs | 4.97 ms | 33.3 ms | +766.7 ✓ · −200.0 ✗ |
| 50 | 4800.0 / 920.0 ms | 0.003–0.039 µs | 5.25 ms | 160.0 ms | +920.0 ✓ · −240.0 ✗ |
| 59.94 | 4004.0 / 767.4 ms | 0.018–0.070 µs | 4.97 ms | 33.4 ms | +767.4 ✓ · −200.2 ✗ |

- **Recovered, every time; no alias anywhere inside ±½ cycle; 0 failures** in 7 112 recoveries
  (14 clips × 508), and 0 with jitter.
- **Every one-interval mispair (all 8 per clip) came back as injected.** Nearest-neighbour pairing,
  shown alongside, got every one wrong, by up to ±333 ms.
- ⚠️ **For stage D (now a requirement, see "Decisions"): the margin is ONE code step at some rates** (41.7 ms at 24, 33.4 ms at 29.97 /
  59.94), not the four steps the interval spread suggests.
  - With a median score, a wrong shift's deviations split between 1 and 7 steps. When the event
    count is not a multiple of four, the median lands on 1.
  - It still separates ±10 ms of jitter cleanly. A capture's ±20 ms frame grid (§18.1) would leave a
    thinner gap at 29.97 / 59.94.
  - A mean-absolute-deviation score gives every wrong shift ≈ 4 steps.

#### The OBS scene collection (optional)

`scripts/syncclips/obs-scene-collection.json`: a TEMPLATE scene collection "Manifold Sync Clips".
- One scene per rate, each holding that rate's `.mp4` as a looping media source (restart on
  activate, audio monitoring off).
- The media paths are `__SYNCCLIPS_DIR__/…`, marked in the file. The README's sed line writes a
  filled COPY to import.
- Robbie's OBS profiles and collections were not touched. **Not import-tested** for that reason;
  the JSON parses and follows OBS's collection layout.

#### Not done

- An OBS import of the template, and a stream of a clip through a real sender (attended, or with
  Robbie's OBS).
- A device capture of a clip played in Manifold.
- ~~Choosing between the two c12 answers in deviation 4; the ProRes size.~~ Decided below.

#### Decisions (Robbie, 2026-10-01)

1. **c12 stays unchanged.**
   - It is the instrument behind every §18 soak result. Changing its onset detection would make
     new readings incomparable with old ones.
   - **`verify.py` is the gate for the sync clips.**
   - ⚠️ **A KNOWN PROPERTY, NOT CLIP ERROR:** on these clips c12 reads a constant **+1.708 ms**
     (raw onset; +1.67…+1.69 ms after its 0.0417 ms `FIXTURE_OFFSET_MS`; +1.713 ms raw at 29.97 /
     59.94, the sub-sample phase), sd 0.01 ms.
     - Its onset is the first sample above 25 % of the tone's peak, and on the clips' 5 ms
       raised-cosine fade-in that is 1.708 ms after the tone starts.
     - The clips themselves are at 0.0 (worst 0.55 µs, `verify.py`).
     - Do not subtract it from, or compare it with, the §18 fixture's readings: that fixture's beep
       had no fade-in.
   - **Stage D's in-app detector is validated against `verify.py`'s exact event times** (the white
     frame's pts, and the tone onset from its 1 kHz phase), not against c12.
2. **The ProRes masters stay full length** (60 s; 77–171 MB each, 755 MB the set). A separate
   download, not bundled. (2026-10-05, §19.11: now whole code cycles, ≥ 60 s; 25p / 50p are 62.4 s;
   742.8 MB the set.)
3. **Distribution:**
   - **The 22 MB MP4 set is bundled in the app.** (Superseded 2026-10-05 by §19.11: the MP4s drifted
     on every loop; the bundled set is now H.264 + PCM `.mov`, 27 MB.)
   - The ProRes masters are a separate download from releases.graviton.tools.
   - **Stage D adds:**
     - **"Save Sync Clip…"** to the control-bar A/V menu: the bundled MP4 for the current rate;
     - **"Download ProRes Sync Clips…"** to the same menu;
     - **"Download Sync Clips…"** to the Help menu;
     - **"Get Sync Clip…"** to the calibration sheet.
   - The download items open the page in the browser. **No in-app downloader.**
4. **Accepted:** the two-frame steps at 50 and 59.94 (deviation 1), and the `recipes.tsv` `unit`
   column that restores the literal frame code.
5. **STAGE D REQUIREMENT: the matcher's score is MEAN-based**, the mean absolute deviation of the
   pair offsets from their centre.
   - With the median-based score of `pairing_check.py` the wrong-pairing margin is one code step at
     24, 29.97 and 59.94 (33–42 ms).
   - With the mean, every wrong shift scores about four code steps (≈ 133–167 ms at ≤ 30 fps), which
     clears a capture's ±20 ms frame grid (§18.1).
   - `pairing_check.py` is unchanged (no code changed for these decisions). Stage D re-runs the same
     four checks with the mean score and records the margin.

### 19.10 Stage D built: calibration mode — 2026-10-01 (unattended; uncommitted)

On top of stages A–C (§19.7–§19.9, through `7395a59`). The brief's decisions (Robbie, 2026-10-01):
the detectors ship but run only while calibration is on; the matcher's score is mean-based (§19.9
Decisions 5); calibration measures the stage A HEARD figure (O included); proposed = O − measured,
rounded to 1 ms, clamped to −250…+500; an advance beyond the queue's low point is shown as not
applicable, with the figure; a figure only with ≥ 10 pairs, p90 − p10 < 1 frame and the last 5 pairs
within ±2 ms; Manifold never applies a value by itself; NDI applies for the session only; HLS has no
calibration; the MP4 set is bundled by the build, not committed.

#### What was built

| part | where | rule |
|---|---|---|
| **the leaf target** | `Packages/ManifoldCore/Sources/SyncCalibration` (new), tests in `Tests/SyncCalibrationTests` | no dependencies, so `swift test` reaches the detectors, the matcher, the rules and the arithmetic. The app links it as a product (`project.yml`), like `StreamBookmarkModel` |
| **the clips, in Swift** | `SyncClips` | the rates, units, file names and event times of `recipes.tsv`; the nearest clip for a stream's rate and whether it is exact (0.05 %: 23.976 and 24 differ by 0.1 %) |
| **the beep detector** | `AVContentBeepDetector` (ManifoldCore, now ungated) in calibration mode → `ToneOnsetDetector` | trigger on the 1 kHz tone demodulated over a one-cycle box; then, on the RAW capture, I/Q under a 2 ms Hann window per sample, the tone's own plateau, and its half-amplitude crossing less 2.5 ms (half the 5 ms raised-cosine edge). Level-independent. The `[AV-CONTENT]` probe's old rule is kept unchanged for the DEBUG print |
| **the flash detector** | `FlashDetector` (replaces the renderer's `avContentMeanLuma`) | the 16 × 16 luma grid, a flash above half scale, once per new frame; the event time is the frame's PTS |
| **off = zero work** | `CalibrationBeepTap` (`FrameEngine.calibrationBeepTap`, handed to every `LiveAudioSink`); `MetalVideoRenderer.calibrationFlash` | both EMPTY unless a run is on: one lock and a nil test per audio buffer and per display tick. No detector object, buffer or timer exists until Start, none after a result, Stop, Cancel, closing the sheet or a disconnect |
| **the counters** | `SyncCalibrationCounters` | buffers scanned, frames sampled, tones and flashes found, since launch. Logged at each run's start and stop and at every live-audio session's end (`[CALIBRATION] live audio session end — detector work this launch: …`). The DEBUG probe's scans are counted apart |
| **the matcher** | `CodedMatcher` | pairing_check.py's `match`, ported, score = the MEAN \|d − centre\| (centre = median d); `.median` kept for the comparison |
| **one run** | `CalibrationMeasurement` | heard A/V per pair = b − (f + h) (header). LOCK: the coded matcher over the latest ≤ 16 flashes and the beeps around them, accepted at score ≤ 10 ms with every wrong candidate ≥ 40 ms. PAIR: each flash takes the beep nearest f + h + d* within ± half the shortest interval (§19.2's rule), so a missed event leaves a flash unpaired, never mispaired. The FIGURE, its p10–p90, the stability test and the walk guard are taken over the most recent 10 pairs (choices 2–4 below) |
| **the offer** | `CalibrationProposal` | current − measured, rounded, clamped (said so); an advance is applicable only up to `FrameEngine.liveAudioAvailableAdvance()` |
| **the advance figure** | `LiveAudioResampleSteering.availableAdvanceSeconds()` | READ-ONLY: the very figure a refusal states (the queue's 10 s low point − keep − fade − margin). `setUserOffset`'s computation moved into one helper both call; the arithmetic is unchanged |
| **the stream's rate** | `SyncCalibrationModel.frameInterval` | the transport's stated rate first (`LiveDisplaySize`, what DeckLink Follow source uses: NDI's declared N/D, SRT's and WHEP's), the renderer's measured PTS interval only as a fallback (choice 6) |
| **the run, per window** | `SyncCalibrationModel` (`WindowDeck.calibration`) | Start installs both taps; events hop to main; a change of O during a run restarts it ("The audio offset changed — measuring again"); a result stops the detectors; the arbiter ends a run whose live source has gone |
| **the sheet** | `CalibrationSheet`, hosted by `CalibrationSheetHost` (a `.background` in ContentView: its body is at the type-checker's limit) | Start / Stop; progress (pairs found of 10, spread, why it is waiting) and never a number; the result ("Sound is heard 80 ms late", the measured figure over the last 10 pairs, "Current offset 0 ms → proposed −80 ms", not applicable with the available figure, clamped); Apply and Save (the default; a line above it names the saved stream), Apply for Session, Cancel, Measure Again. NDI and connects without a saved stream: Apply for Session only. HLS: the offset control's note, Start disabled. After Apply: "Start again to check: it should read close to 0 ms." |
| **the clips** | `SyncClipLibrary` | Get Sync Clip… / Save Sync Clip…: a save panel naming the stream's rate ("This stream is 60 fps: there is no 60 fps clip, 59.94p is the nearest.") with a rate menu preselected. Not bundled: "Sync clips aren't included in this build." with the download link; calibration still runs on a clip from anywhere |
| **the menus** | `AudioOffsetControl`; `ManifoldApp` | A/V: Calibrate…, Save Sync Clip…, Download ProRes Sync Clips… under the offset items. On HLS the greyed "A/V offset — not on HLS" is now a MENU (the note, then the same three items). Help: Download Sync Clips… |
| **the URL** | `SyncClipLibrary.downloadURL` | `https://releases.graviton.tools/manifold/manifold-sync-clips-v1.zip`, marked ⚠️ ROBBIE: CONFIRM BEFORE RELEASE in the source and listed in BUGS.md's pre-ship items |
| **bundling** | `project.yml` "Bundle sync clips" (postBuildScripts); `scripts/release-mac.sh` steps 3b and 6c; `generate.sh` `SYNCCLIPS_FORMATS=mp4` | every build copies `build/syncclips/manifold-sync-<label>p.mp4` (labels from `recipes.tsv`) into `Contents/Resources/SyncClips`, rebuilt each time, before signing. The release generates the MP4 set first (3b), and fails if any clip is missing from the exported app or differs from what 3b made (6c). Preflight requires ffmpeg and the label font |
| **logs** | `[CALIBRATION]` | sheet opened (availability, frame interval), START (O, frame, counters), each tone (time, level, width) and flash (pts, heard − clock), the code's pairing (offset, score, margin), each pair, RESULT, APPLIED (by the user), detectors off (counters) |

**"v1" (the brief):** the download zip's name carries the coded pattern's version
(`SyncClips.patternVersion = 1`). **Any change to the coded pattern** — the code, the unit, the
tone, the flash — **means a new `manifold-sync-clips-v2.zip` and a new URL constant, never replacing
v1.** A user's v1 clips must keep matching what the app pairs, and an old build must keep finding
its own zip.

#### Choices made in building it, each measured — for Robbie's review

1. **The beep onset is the tone's half-amplitude point, not a threshold.** A threshold on the 5 ms
   raised-cosine edge lags the start by ~2.6 ms and moves with the level. The half-amplitude point
   is level-independent by the edge's symmetry. A first version took it on the trigger's one-cycle
   box and read a constant 65–100 µs late (the 2 kHz product term leaks during the ramp), so the
   onset is measured on the raw capture under a 2 ms Hann window. Synthetic clip audio at −12 / 0 /
   +6 dB, uneven buffers: worst 6–23 µs per rate.
2. **The figure is the most recent 10 pairs, not every pair since Start.** On a fresh connect the
   heard figure walks while the steering settles after the connect's re-anchors: +95 → +77 → +80 ms
   over ~40 s on local SRT (`pass1-no-walk-guard/stageD-srt-23.976p-inj80-allpairs-superseded`). A
   median over every pair carries the walk into the result.
3. **A walk guard beyond the brief's three rules: no figure while the 10-pair window's slope exceeds
   0.2 ms/s** (≤ 2 ms across the window). Measured (`pass1-no-walk-guard/stageD-srt-59.94p-inj0`):
   an exponential settle +46 → 0 → −5 ms. At 59.94 the last 5 pairs span ~4 s, the three rules
   offered +1.5 ms mid-walk, and the re-check read −5.29 ms. `testASlowWalkOffersNothingUntilItStops`
   has the teeth: the same feed without the guard offers more than 2 ms off.
4. **"The last 5 pairs within ±2 ms" is read as §19.2 words it: a stable ±2 ms MEDIAN over the last
   5 pairs** (the window median as it stood after each of the last 5 pairs, within ±2 ms of now's).
   The per-pair reading was built first. On NDI the window median held −66…−71 ms for 3 minutes
   while single pairs scattered ±3–5 ms (p10–p90 5–7 ms, `extras-pass1/extras-ndi`), so it never
   offered a figure. The spread rule (under one frame) still bounds the scatter.
5. **Pairing: the code decides, the window rule pairs.** pairing_check.py's index-shift matcher
   assumes no missed events. Live, a missed flash would shift every later pair by one. So the coded
   matcher LOCKS the offset on a clean run of ≤ 16 flashes, and pairs are then taken by §19.2's
   ± half-interval rule around it, which leaves a missed event's partner unpaired.
6. **The stream's rate comes from the transport first.** NDI frames are stamped on host time at
   pull. The renderer's 8-delta median read 41.594 ms (24.04 fps) on a 24000/1001 sender, and Get
   Sync Clip… offered 24p. `LiveDisplaySize` carries NDI's declared N/D (and SRT's and WHEP's
   rates); the renderer's figure is the fallback.
7. **Measured on the stream's PTS, not at the glass.** heard = b − (f + h): f is the flash frame's
   PTS, h the heard − clock at the tick that showed it. Manifold's own render path (frame choice,
   tick → glass, ≈ −16 ms, §18.13) is left out, per §19.2's "what it does not measure". So the
   figure equals the old `[AV-CONTENT]` "glass" figure less that constant.
8. **The HLS control is now a menu** (greyed label, the same note, then Calibrate… / Save Sync
   Clip… / Download ProRes Sync Clips…), so the clips and calibration's own HLS note are reachable on
   HLS. Stage B's C04 had it as plain text.
9. **After Apply the sheet stays open**, says "Start again to check: it should read close to 0 ms",
   and Start runs the re-check. Cancel and Close dismiss. A result stops the detectors; Measure
   Again restarts them.
10. **The counters split the DEBUG probe out.** In Profile the `[AV-CONTENT]` probe scans every live
    buffer whenever telemetry is on (22 002 buffers in one 4-min session). Calibration's own
    counters stay 0 until Start, and the probe's appear apart ("(and N by the DEBUG [AV-CONTENT]
    probe)"). Release has no probe at runtime.

#### Verification

**`swift test`: 173 / 173** (162 + 11 new in `SyncCalibrationTests`). The pre-existing flake
(`testSteeringCallsItsCompanionWithoutReportingWindows`) did not recur.

**Builds:** Profile (`.build-cc/stageD-Profile`) and Release (`.build-cc/stageD-Release`), from the
final tree, with no errors and no new warnings in any file touched; the no-clips Profile is below.

**The four pairing checks, ported, with the MEAN score** (`PairingCheckTests`). On each clip's exact
timeline, 508 injected offsets plain and 508 with ±10 ms jitter, 0 failures at every rate. Every
one-interval mispair came back as injected; nearest-neighbour got each wrong.

| rate | code step | wrong-pairing margin, MEAN score | with ±10 ms jitter | margin, median score (pairing_check.py's) |
|---|---|---|---|---|
| 23.976 | 41.7 ms | **161.4 ms (3.87 steps)** | 159.8 ms | 41.7 ms (1 step) |
| 24 | 41.7 ms | **161.2 ms (3.87)** | 159.6 ms | 41.7 ms (1) |
| 25 | 40.0 ms | **160.0 ms (4.00)** | 158.0 ms | 160.0 ms (4) |
| 29.97 | 33.4 ms | **130.0 ms (3.90)** | 128.5 ms | 33.4 ms (1) |
| 30 | 33.3 ms | **129.9 ms (3.90)** | 128.4 ms | 33.3 ms (1) |
| 50 | 40.0 ms | **160.0 ms (4.00)** | 158.0 ms | 160.0 ms (4) |
| 59.94 | 33.4 ms | **130.0 ms (3.90)** | 128.5 ms | 33.4 ms (1) |

- The mean score gives every wrong shift ≈ 4 code steps everywhere, as §19.9 predicted. Worst
  recovery error 0.000 µs plain, 3.8–4.7 ms with ±10 ms jitter.

**O = 0, calibration off: still b35a810.**
- The replay tools were built from b35a810 and from this tree (the same `swiftc` lines as
  `replay/build.sh`), and run on copies of `~/Desktop/manifold-soak/level/`.
  - Tools: `replay-after`, `replay-closed` (plain and logonly), `replay-level` (plain and logonly),
    `replay-offset-lock`.
  - Sessions: the seven saved sessions, plus `synth` at 66.6 ppm through closed and level.
- **99 / 99 files byte-identical** (44 stdout reports, 55 TSVs). `step8-whep-soak` level reproduces
  §19.7's figures exactly: start → +26 −3.3 ms, worst −31.9 ms at 430 s, end −2.5 ms.
- The only steering change is a read-only accessor; `setUserOffset`'s figure moved into a shared
  helper with its arithmetic unchanged. With calibration off, the sink's and the renderer's slots
  are empty.

**Detector truth: the in-app detectors offline over every bundled MP4, against verify.py.**
- A scratch harness decodes each MP4 with AVFoundation (the edit list honoured) into the
  CMSampleBuffers and NV12 CVPixelBuffers a transport hands on. It runs the shipped
  `AVContentBeepDetector` (calibration mode) and `FlashDetector` on them, and compares with
  `verify.py --json`'s exact event times.

| clip | tones found | onset − verify.py, worst (Float32 / Int16 decode) | mean | flashes | flash pts − verify.py | the whole measurement, h = 0 |
|---|---|---|---|---|---|---|
| 23.976p | 48 / 48 | **13.0 / 13.0 µs** | −4.7 µs | 48 / 48 | 0.000 µs | 48 pairs, −0.005 ms |
| 24p | 48 / 48 | **19.1 / 19.2 µs** | −4.3 µs | 48 / 48 | 0.000 µs | 48 pairs, −0.005 ms |
| 25p | 50 / 50 | **16.8 / 16.8 µs** | −3.1 µs | 50 / 50 | 0.000 µs | 50 pairs, −0.003 ms |
| 29.97p | 60 / 60 | **18.1 / 18.0 µs** | −6.5 µs | 60 / 60 | 0.000 µs | 60 pairs, −0.007 ms |
| 30p | 60 / 60 | **24.0 / 24.0 µs** | −5.2 µs | 60 / 60 | 0.000 µs | 60 pairs, −0.005 ms |
| 50p | 50 / 50 | **27.1 / 27.1 µs** | −9.6 µs | 50 / 50 | 0.000 µs | 50 pairs, −0.010 ms |
| 59.94p | 60 / 60 | **30.4 / 30.4 µs** | −15.9 µs | 60 / 60 | 0.000 µs | 60 pairs, −0.016 ms |

- Half-amplitude widths 11.70–36.73 ms (one frame less 5 ms, as designed). Levels −20.0 / −20.1 dBFS.

**Live, unattended, non-Cloudflare.**
- **Fixtures.** One continuous 300 s file per (rate, injection): the bundled MP4 concatenated ×5 by
  the concat filter, each segment trimmed to exactly its frames and 2 882 880 samples. The audio is
  shifted by the injection (+ = sound LATER). H.264 constrained baseline + AAC, in MPEG-TS
  (`~/Desktop/manifold-soak/stageD/syncD-*.ts`).
  - Measured offline with the same detectors: **+80.33 / +0.33 / −39.67 ms**, spread 0.01 ms.
  - The +0.32 ms is the AAC re-encode.
- ⚠️ **Two fixture faults were found and fixed before any run counted.**
  - Untrimmed concat segments shifted the audio ~15 ms at each join.
  - An MKV's 1 ms timebase rounded 23.976 frames to 41/42 ms, which the stream then reported as
    23.81 fps and which drove queue-full re-anchors.
- **Senders.**
  - (a) Local SRT: an ffmpeg listener serving the TS (`-re`, `-pes_payload_size 0`), Manifold on
    `MANIFOLD_SRT_DEBUG_URL` (no bookmark).
  - (b) ffmpeg → MediaMTX (the running `mediamtx-soak-abs.yml`, `useAbsoluteTimestamp: true`) →
    WHEP: the TS published over RTSP with the audio as Opus, Manifold on the `MediaMTX Whip`
    bookmark.
- **Each run:** connect, 10 s, A/V ▸ Calibrate… ▸ Start, the result, **Apply for Session** (labelled "Apply for This Session" in passes 1–3; relabelled after, same action), 4 s,
  Start again, Cancel. Driven by UI scripting, Profile build. Logs:
  `~/Desktop/manifold-soak/stageD/stageD-<srv>-<rate>p-inj<ms>.*`.
- **Never Apply and Save:** `streamBookmarks` was not written (read-only hash before and after:
  identical, see the end of this section).
- **Pass:** the proposal = −injection within ±1 frame, and the re-check within ±2 ms of 0.

| path | rate | injected (measured) | 1st: heard A/V (pairs, s to result) | proposed | − injection | re-check heard | pass? |
|---|---|---|---|---|---|---|---|
| SRT | 23.976 | +0.33 | −2.01 (19, 48 s) | +2 | +2.3 ms | **+3.13** | ✅ / ❌ (3.13 > 2) |
| SRT | 23.976 | +80.33 | +80.14 (19, 46 s) | −80 | +0.3 ms | −0.03 | ✅ ✅ |
| SRT | 23.976 | −39.67 | −43.12 (33, 66 s) | +43 | +3.3 ms | +1.06 | ✅ ✅ |
| SRT | 59.94 | +0.33 | −2.76 (80, 99 s) | +3 | +3.3 ms | −0.26 | ✅ ✅ |
| SRT | 59.94 | +80.33 | +81.65 (34, 54 s) | −82 | −1.7 ms | +0.15 | ✅ ✅ |
| SRT | 59.94 | −39.67 | −42.77 (72, 91 s) | +43 | +3.3 ms | +0.24 | ✅ ✅ |
| WHEP | 23.976 | +0.33 | +41.44 (10, 12 s) | −41 | −40.7 ms | −1.19 | ✅ (by 1 ms) / ✅ |
| WHEP | 23.976 | +80.33 | +115.50 (19, 23 s) | −116 | −35.7 ms | +0.69 | ✅ ✅ |
| WHEP | 23.976 | −39.67 | −54.60 (14, 17 s) | +55 | +15.3 ms | −0.27 | ✅ ✅ |
| WHEP | 59.94 | +0.33 | −12.18 (10, 10 s) | +12 | +11.7 ms | −0.10 | ✅ ✅ |
| WHEP | 59.94 | +80.33 | +67.67 (10, 10 s) | −68 | +12.3 ms | +0.18 | ✅ ✅ |
| WHEP | 59.94 | −39.67 | −59.01 (10, 10 s) | +59 | +19.3 ms | −0.42 | ❌ (19.3 > 16.7) / ✅ |

- **Re-check: 11 / 12 within ±2 ms; all 12 within ±3.2 ms.** Worst miss: SRT 23.976 / 0.
  - It measured −2.01 and applied +2; 16 s later the heard figure read +3.13.
  - That is the steering's own wander: §19.7 recorded window e medians of −0.9…+3.2 ms on local SRT
    with no change. ±2 ms is at the edge of what that path holds minute to minute.
  - WHEP re-checks are all within ±1.2 ms.
- **The proposal within ±1 frame of the injection: SRT 6 / 6 (worst 3.3 ms); WHEP 5 / 6.**
  - The WHEP figures are off the injection by −40.7 … +19.3 ms, by session. The next block shows
    that this is not calibration's error.
- **Every change was one splice:** `AUDIO OFFSET … ACCEPTED`, one per Apply; no coarse event, no rate
  write.
- **On the final build** (after the relabel and the true minus) two cases were run again for the
  screenshots: SRT 23.976 / +80 → −77, re-check −0.09 ms; WHEP 59.94 / −40 → +59, re-check −0.16 ms,
  and again → +53, re-check +0.47 ms (another session, another SR offset).
- Pass 1 (no walk guard) and pass 2 (the per-pair stability rule) are kept in
  `pass1-no-walk-guard/` and `pass2-per-pair-stability/`. Pass 3 above is the final build.
  - The final build also takes the stream's rate from the transport (choice 6), rebuilt after pass 3.
  - For SRT and WHEP the renderer already read 41.711 / 16.683 ms, so only the rate note's source
    differs.

**⚠️ FOUND: on ffmpeg → MediaMTX → WHEP the audio↔video relation is off by a different amount each
session (−19 … +42 ms here), and it equals the first Sender Report line's offset.**
- Pass 3, for each WHEP session: the excess over the injection, then the same with that session's
  first SR-line offset added back (`[WHEP-SRFIT] FIRST LINE … offset`):

| session | excess over injection | first SR-line offset | excess + offset |
|---|---|---|---|
| 23.976 / 0 | +41.11 | −41.17 | **−0.05** |
| 23.976 / +80 | +35.17 | −39.44 | **−4.27** |
| 23.976 / −40 | −14.93 | +16.63 | **+1.70** |
| 59.94 / 0 | −12.51 | +12.20 | **−0.31** |
| 59.94 / +80 | −12.66 | +12.21 | **−0.45** |
| 59.94 / −40 | −19.34 | +18.84 | **−0.50** |

- **The independent read** (`whepx-1…3`): in each of three sessions, ffmpeg also read MediaMTX's RTSP
  output of the same path and recorded 90 s, while Manifold calibrated over WHEP. ffmpeg aligns RTP
  streams by the SRs too.

| session | Manifold WHEP heard A/V | its first SR-line offset | ffmpeg's RTSP read of the same MediaMTX path, same time |
|---|---|---|---|
| whepx-1 | +29.36 ms | −29.95 ms | −0.25 ms (72 pairs) |
| whepx-2 | +8.61 ms | −8.26 ms | −0.25 ms |
| whepx-3 | +26.06 ms | −26.53 ms | −0.25 ms |

- **So the content and the RTSP side carry 0. Over WHEP the SRs, as Manifold reads them, state an
  audio↔video relation of 8–42 ms that the content does not have, different every session, and
  Manifold plays exactly that.**
  - It is either MediaMTX's WebRTC-side Sender Reports, or Manifold's mapping of them (SR line fit,
    §2.6). Separating the two needs a second WHEP client (e.g. a browser's), which is not
    unattended.
  - Nothing was changed for it: it is not calibration's to correct, and CLAUDE.md forbids tuning to
    a server.
- **What it means for calibration:** it measures this faithfully; every WHEP re-check read within
  ±1.2 ms. But **on this chain a value calibrated in one session does not hold for the next**, and a
  value saved to the bookmark would be wrong after a reconnect.
  - §19.5 does not cover per-session offsets; its MediaMTX row was about drift.
  - **Robbie's decision:** investigate as a WHEP item before the bookmark Save is trusted on
    MediaMTX; Cloudflare WHEP on Monday (D3) says whether it is MediaMTX-only.
- The Release run below read +25.94 ms on the same path: another session, another offset.

#### Is it `useAbsoluteTimestamp: true` with an ffmpeg publisher? — 2026-10-05 11:57–12:15 (unattended; no app change) — ❌ no: the default config is off too

**What Stage D ran on** (checked before running anything):
- **MediaMTX:** PID 9578, up since 2026-09-30 19:05 as `./mediamtx scripts/soak/mediamtx-soak-abs.yml`
  (cwd `~/Desktop/mediamtx`), so `useAbsoluteTimestamp: true` on `live`. Its log has Stage D's WHEP
  publishes (2026-10-02 00:14–00:25), each with the abs mode's "received RTP packet without absolute
  time" drops.
- **The publisher:** ffmpeg over **RTSP/TCP** (RTMP is off in both configs):
  `-re -i syncD-<rate>p-inj<ms>.ts -c:v copy -c:a libopus -b:a 128k -ar 48000 -ac 2 -f rtsp`.
  - The fixture is the bundled MP4 concatenated ×5 into one continuous 300 s TS (above). There is no
    `-stream_loop`.

**Run.**
- **Each reconnect** used Stage D's WHEP protocol (`run.sh`) plus whepx's parallel RTSP read:
  - a fresh ffmpeg publish of `syncD-23.976p-inj80.ts` (+80.33 ms measured), the same command;
  - a fresh Manifold launch on the `MediaMTX Whip` bookmark; calibrate, Apply for Session, re-check,
    Cancel;
  - ffmpeg reading MediaMTX's RTSP output of `live` for 90 s, through the in-app detectors offline
    (`fileprobe`).
- **Build:** Profile from `23e8223`, `.build-cc/monday-Profile`.
- **MediaMTX:** v1.21.1, restarted fresh for each config:
  - (a) `mediamtx-soak-abs.yml`;
  - (b) `mediamtx-soak.yml`, which differs only by not having `useAbsoluteTimestamp`.
- **Logs:** `~/Desktop/manifold-soak/srabs/srabs-<a|b>-<n>.*` and `mediamtx-<a|b>.stdout.log`.

**Predictions (Robbie's, written before the run):**
- If the setting interacts with ffmpeg, (b) reads within ±5 ms of +80 on all 4 reconnects, and (a)
  scatters by tens of ms.
- If both scatter, it is not the setting: the cause is MediaMTX's WebRTC SR generation, or
  Manifold's reading of it.

| reconnect | proposed | heard A/V | − injection (+80.33) | Manifold's first SR-line offset | excess + offset | re-check | ffmpeg RTSP read, same path (pairs; p10…p90) |
|---|---|---|---|---|---|---|---|
| a-1 | −117 | +116.89 | +36.56 | −35.37 | **+1.19** | −2.43 | +79.75 (72; 79.62…80.14) |
| a-2 | −107 | +107.42 | +27.09 | −28.26 | **−1.17** | −0.07 | +79.75 (72; 79.62…80.14) |
| a-3 | −115 | +115.27 | +34.94 | −35.07 | **−0.13** | −1.74 | +79.75 (72; 79.62…80.14) |
| a-4 | −69 | +69.34 | −10.99 | +10.05 | **−0.94** | −1.64 | +79.75 (72; 79.62…80.14) |
| b-1 | −111 | +111.27 | +30.94 | −33.80 | **−2.86** | −0.75 | +78.14 (71; 77.13…79.34) |
| b-2 | −108 | +107.92 | +27.59 | −29.72 | **−2.13** | −0.87 | +78.57 (71; 75.13…79.16) |
| b-3 | −111 | +110.63 | +30.30 | −33.81 | **−3.51** | −2.03 | +78.34 (71; 78.10…79.34) |
| b-4 | −112 | +111.63 | +31.30 | −32.50 | **−1.20** | −1.36 | +79.61 (71; 76.59…80.16) |

(ms; "heard A/V" is calibration's first figure, and the proposal is its negative, rounded.)

**Neither prediction held.**
- **(a) scattered, as both predicted:** −11.0 … +36.6 ms off the injection, a 48 ms range. Stage D
  saw −19 … +42.
- **(b) did not read +80.** All four reconnects were **+27.6 … +31.3 ms** off, a 3.7 ms range: a
  steady bias, not a scatter. So the first prediction fails on (b), and the second fails because
  (b) does not scatter.
- **What the setting changes is the per-session scatter, not whether there is an error.**
  - With it on, the WHEP offset is different on every connect.
  - With it off, it is about +30 ms on every connect.
  - Neither config gives the content's relation over WHEP.

**In every session, both configs, the error is Manifold's first SR-line offset.**
- Excess + offset is −3.5 … +1.2 ms (8 / 8), as in Stage D's six sessions (−4.3 … +1.7).
- Every re-check read within ±2.5 ms, so calibration measured what was played. The error is in
  the relation Manifold received, not in calibration.

**MediaMTX's RTSP output of the same path carries the content's relation in both configs.**
- (a): +79.75 every time, p10…p90 0.5 ms.
- (b): +78.1 … +79.6, with a wider spread (up to 4 ms).
- The RTSP side is read through RTCP SRs too, by ffmpeg. So the stream inside MediaMTX is right,
  and the error appears between its WebRTC output and Manifold's SR-line offset, with or without
  the setting.
  - In (a) that rules out the sender's SRs: their mapping feeds the RTSP output too.
  - The −0.6 ms on the RTSP side (a) is the Opus → AAC re-encode of the read.

**The abs mode's pre-SR drops do not explain the scatter.**
- (a) dropped 487–494 packets per publish, all in the first ~5 s (ffmpeg's first SR on the RTSP
  path came late), against 0 in (b).
- The count was the same every publish while the offset moved 46 ms. The drops end 15+ s before
  Manifold connects.

**So the cause is MediaMTX's WebRTC-side SRs or Manifold's reading of them**, as the second
prediction says, even though (b) did not scatter.
- **Still not separated:** that needs a second WHEP client on the same session. No unattended one
  is installed here: no aiortc, no GStreamer, and ffmpeg 8.1.1 has no WHEP demuxer.
- **(b) is now the easier case for the attended split**, because it is repeatable (≈ +30 ms every
  connect):
  - a browser WHEP read of a (b) session that shows ≈ 0 points at Manifold's mapping;
  - one that shows ≈ +30 points at MediaMTX.
- **What is unchanged:**
  - Calibration on ffmpeg → MediaMTX → WHEP is still per-session in (a), Stage D's config. A value
    saved to the bookmark is wrong after a reconnect.
  - In (b) a saved value would hold across these 4 reconnects (±2 ms), but it would be correcting a
    ~30 ms error that is not in the content.
  - Nothing was tuned: CLAUDE.md forbids constants taken from one server's traces.
- **State after the run:**
  - MediaMTX was restarted on `mediamtx-soak-abs.yml`, as before (new PID 52468). Its stdout is
    appended to `~/Desktop/manifold-soak/mediamtx-soak.log`, and both logs' original bytes are
    intact.
  - The configs are byte-identical to before (sha256).
  - `streamBookmarks` was hashed read-only before and after: identical. No `defaults` was written.

**NDI (an extra, not in the brief's live list): the SDK sender.**
- A scratch sender built on the NDI SDK (`scratchpad/ndi/ndisync.cpp`) synthesises the 23.976 clip
  exactly as generate.sh does. Audio and video go out per frame from one thread, at 24000/1001, with
  no injection.
- Manifold on ⌃⌥N. Four runs, each: calibrate, Apply for Session, re-check:

| build | heard A/V (p10–p90) | proposed | re-check |
|---|---|---|---|
| median rule, rate from the renderer | −68.21 ms (8.2) | +68 | +1.44 ms |
| median rule, rate from the transport | −66.75 ms (7.4) | +67 | −0.49 ms |
| final labels | −68.16 ms (7.5) | +68 | +0.46 ms |
| final (true minus) | −69.80 ms (5.2) | +70 | **+2.88 ms** (p10–p90 6.4) |

- NDI's single pairs scatter ±3–5 ms, so its re-check sits around the ±2 ms bound (3 / 4 within).
- ⚠️ **The sender is in sync by construction, so −67 ms is Manifold's NDI path or NDI's own transport
  timing, not content.**
  - Unlike SRT and WHEP, NDI's heard − clock is on host time (pull stamps, the picture delay, the
    direct anchor), and whether that equals what is heard at the device has not been measured.
  - Calibration offers what it measures: +67 ms.
  - **Monday's D1 device capture decides whether +67 is right.** If a capture with O = +67 is off by
    ~67 ms, NDI's heard figure is not the listener's, and NDI calibration must stay disabled until
    it is.
  - The §19 header's provisional OBS NDI +16…+22 ms (sound late) is a device figure, of the opposite
    sign.

**Release build: no work while off, work while on.**
- `.build-cc/stageD-Release`, WHEP via the `MediaMTX Whip` bookmark (Release has no ⌃⌥D or debug
  URL). `release-proof.*`.

| phase | `[CALIBRATION]` lines | `[AV-CONTENT]` / `[AV-LAG]` lines | counters (since launch) |
|---|---|---|---|
| 120 s connected, calibration OFF | **0** | **0** | at Start: **0 buffers, 0 frames, 0 tones, 0 flashes** |
| a 13 s run (Start → result → Cancel) | 11 tones, 11 flashes, the result (+25.94 ms) | 0 | at stop: **652 buffers, 313 frames, 11 / 11** (50 Opus packets and 24 frames a second) |
| 60 s connected, OFF again; then the session end | — | 0 | at session end: **652, 313, 11, 11: unchanged** |

- Release binary (`strings`):
  - the release script's telemetry marker `enqueued=%.1f/s`: 0 (its Release assertion holds);
  - `[CALIBRATION] RESULT`: present;
  - `[AV-LAG] tick` and `[AV-CONTENT] flash`: 0 (DEBUG, app-side);
  - `[AV-CONTENT] beep`: present, as it was before stage D. ManifoldCore defines
    `MANIFOLD_TELEMETRY` unconditionally, so only the runtime gate (a DEBUG app's telemetry flag)
    keeps that probe off. It stays on BUGS.md's removal list.

**Bundling.**
- Profile and Release logged "Sync clips bundled: 7 of 7"; `Contents/Resources/SyncClips` holds the
  seven MP4s.
- With `build/syncclips` moved aside, a third build (`.build-cc/stageD-noclips-Profile`) logged "0 of
  7" and has no folder. Its sheet says "Sync clips aren't included in this build." with the link
  (C01), and calibration still ran there (+0.25 ms on the clean SRT fixture, C02).
- `SYNCCLIPS_FORMATS=mp4 generate.sh` into scratch: 23 s, and **all seven MP4s byte-identical to the
  stage C set** verify.py passed. On this Mac, release step 3b reproduces the verified clips exactly.
- `release-mac.sh` was syntax-checked (`bash -n`), not run (it signs, notarizes and bumps the build
  number).

**Screenshots** (`~/Desktop/manifold-shots/stageD/`, window or menu captures):

| shot | state |
|---|---|
| S1-srt23976-01 … 05 | SRT, no saved stream: idle; **progress**; **result** (heard 80 ms late → −80); applied; re-check "in sync" |
| S2-whep5994-01 … 05 | WHEP from a bookmark: the same five, with **Apply and Save** offered and the line naming "MediaMTX Whip - Locla" (not pressed) |
| X01-result-not-applicable | +250 injected on SRT: proposed −250 (clamped from −252), "Not applicable … At most N ms is available on this stream right now", Apply disabled |
| N01, N02, N03 | **NDI: session only** — "NDI: a result applies to this session only.", only Apply for Session; re-check |
| H01-hls-av-menu, H02-sheet-hls-disabled | **HLS**: the greyed control's menu; the sheet "No audio offset on HLS — Apple's player owns the audio." / "Calibration isn't available on HLS.", Start disabled |
| C01, C02 | **clips not bundled**: the note and the download link; a run on that build |
| M01-av-menu, M02-help-menu | **the menu items**: A/V ▸ Calibrate… / Save Sync Clip… / Download ProRes Sync Clips…; Help ▸ Download Sync Clips… |

`streamBookmarks`: hashed read-only before the WHEP runs and after all of them; identical. No
`defaults` was written.

#### What `scripts/release-mac.sh` does that affects this (read first, as asked; nothing in its configuration changed)

1. **It ships Profile by default, and project.yml's scheme now pins `archive` to Profile too.**
   - The script's header still says the archive action is pinned to Release. That is stale: the
     scheme comment in project.yml says Profile, and so does the scheme.
   - So the tester build carries DEBUG. The `[AV-CONTENT]` / `[AV-LAG]` probes run beside calibration
     whenever telemetry is on: they print per beep and per flash, and scan every live buffer even
     with calibration off.
   - Calibration's counters keep that apart, but a tester's log will be busier.
   - Not changed: the configuration is a pre-ship decision.
2. **project.yml's scheme comment says the script asserts `[SRT-FLOW]`.** It now asserts the format
   string `enqueued=%.1f/s` (2026-09-21). Stale comment, harmless. Calibration's strings do not
   contain the marker, and the Release check holds (0 hits).
3. **The DMG grows by ~22 MB** (the MP4s do not compress): from ~6–9 MB to ~30 MB.
   - The script's "probably under Nextcloud's threshold" reasoning no longer applies.
   - Its default output is outside Nextcloud (`~/Builds/Manifold`), so nothing breaks.
4. **ffmpeg is now a release build tool** (Homebrew 8.1.1 here, with libx264), as is the label font
   `/System/Library/Fonts/Menlo.ttc`. Both are checked at preflight.
   - The clips' bytes depend on that ffmpeg/x264. On another build Mac they would differ in bytes,
     but not in timing.
   - verify.py is not run by the release: it needs numpy and an ffprobe that are not installed
     system-wide. Adding it would be the stronger gate (Robbie's call).
5. **The clips enter the bundle through an Xcode run-script phase.**
   - It runs before signing, so they are sealed in CodeResources and notarized with the app.
   - `ENABLE_USER_SCRIPT_SANDBOXING` is not set (default off). If a future Xcode turns it on, the
     phase could not read `build/syncclips` and step 6c would fail the release loudly, not silently.
6. **Step 3b regenerates `build/syncclips/*.mp4` every release**, overwriting what is there. The
   ProRes masters there are untouched.

#### Not done

- **Attended (Monday, §19.8 block 5):**
  - OBS → NDI and OBS → Cloudflare SRT / WHEP with a clip;
  - one Audio Hijack capture, which also decides the NDI −67 ms question above;
  - the 90-minute Cloudflare SRT hold;
  - the sheet and menu review.
- **Upload the v1 zip** and confirm the URL (BUGS.md pre-ship).
- **The WHEP per-session SR offset** (above): `useAbsoluteTimestamp` ruled out as the cause
  (2026-10-05). MediaMTX's WebRTC SRs versus Manifold's reading of them is not yet separated: that
  needs an attended browser WHEP read.
- **DeckLink:** the SDI read takes the same O (stage A). Calibration does not measure SDI (§19.2:
  the output chain is not per-source).
- **Not tested live:** a loss of a few events mid-run on a real network. Covered offline: a missed
  flash and a missed beep in `testLocksPairsAndOffersOnlyWhenConfident`.

#### Attended session — 2026-10-05 (Robbie)

**Build:** `.build-cc/monday-Profile` (Profile, `23e8223`, 7 clips bundled). No app code changed.
Each item's prediction and band were written here BEFORE it ran.

**Starting state** (read-only over obs-websocket):
- **Sender OBS:** profile "MediaMTX Local", collection "Manifold Decklink Sender", scene
  DECKLINK_BEEPS (DeckLink input only), 24000/1001, not streaming.
- **Recorder OBS:** profile "Recorder", collection "AV Capture", 60 fps.
- **Audio Hijack** was already running (13:04) before Manifold, so it was quit before Manifold
  launched (CLAUDE.md).

##### 1. OBS → NDI with the 23.976 sync clip

**Prediction** (Robbie; the sign settled before the run):
- **Calibration proposes −45…0 ms.** This is OBS's sender term: provisionally +16…+22 ms sound
  LATE at the device (§19 header), so ≈ −16…−22 proposed.
- **A proposal near +68 ms** would mean Stage D's SDK-sender reading (−67…−70 heard) is real for
  OBS too: Manifold's NDI path, not the sender.
- **The re-check after Apply for Session reads within ±2 ms of 0.**
- **A 60 s Audio Hijack + Recorder OBS capture after the Apply** (`c12.py`, less its +1.708 ms
  onset bias on these clips, §19.10 D4) reads within ±1 frame (±41.7 ms) of calibration's re-check
  figure.
  - That is the device agreeing with calibration.
  - Calibration leaves out Manifold's own render path (≈ −16 ms, choice 7), which fits inside the
    band.
  - If the device reads ≈ −68 ms while calibration reads 0, NDI's heard figure is not the
    listener's, and NDI calibration must stay disabled (§19.10, NDI).

**Calibration result** (Manifold connected at 13:12:08 to "MAC-STUDIO (OBS PGM)" with ⌃⌥N; 30 s
settle; driven by UI scripting; log `~/Desktop/manifold-soak/attended/att-1-ndi.manifold.log`):
- **Sender:** OBS launched 13:01, 42 ms audio buffering (fresh). New scene collection "Untitled",
  scene SYNC: Media Source `manifold-sync-23.976p.mp4`, looping, monitoring off. 24000/1001. DistroAV
  main output.
- **First run:** heard **−24.91 ms** (sound EARLY), last 10 of 22 pairs, p10…p90 −28.22…−17.39
  (10.8 ms), so it proposed **+25 ms**. The sheet offered only Apply for Session, with the NDI
  session-only note.
- **Apply for Session:** `AUDIO OFFSET +0.0 → +25.0 ms ACCEPTED`, one splice (INSERT 1200 fr), no
  rate write.
- **Re-check:** **−1.79 ms** (p10…p90 −4.38…+5.18), so it would propose +27.

| check | band | measured | |
|---|---|---|---|
| proposal | −45…0 | **+25** | ❌ the opposite sign: sound early, not late |
| near +68 (the SDK reading)? | — | no: +25 | the SDK sender's −67…−70 is not what OBS gives |
| re-check | ±2 ms | −1.79 | ✅ |

**Device capture, O = +25 applied, 13:17:15:**
- **Recorder:** OBS "Recorder", 60 fps. macOS Audio Capture was re-picked to Manifold. The
  preflight read max −39.8 dB: the clip's −20 dBFS tone less the recorder's ~19.5 dB loss (§1.2).
- **Files:** `~/Movies/2026-10-05 13-17-15.mov` (70.6 s) and Audio Hijack's
  `~/Music/Audio Hijack/20261005 1317 Recording.wav`.
- **c12.py** (run from a scratchpad venv with numpy; none is installed system-wide):
  - 57 beeps, 57 flashes, 57 pairs, g_count ✅. g_grid False, as expected on the coded clip.
  - **median +94.48 ms** (positive = audio LATE), sd 8.64; windows +90.4 … +97.7.
  - Less c12's +1.708 ms onset bias: **+92.8 ms raw**.
- **Not yet judged against a zero.** The chain's zero moves launch to launch (+2.5 / +27.8 ms,
  §18.24), so the control is taken in this recorder launch, at item 2's end: Manifold plays
  `manifold-sync-23.976p.mp4` from disk after NDI disconnects.
- **Provisionally ❌.** Anywhere in the historical control range, device − zero is ≈ +65…+90 ms
  (sound late), against calibration's −1.8. That is far outside ±1 frame, and near Stage D's SDK
  −67…−70. If the control confirms it, NDI's heard figure is not the listener's.

**The control, 13:32:33 — ❌ confirmed: on NDI, calibration's heard figure is ~70 ms earlier than
the listener's.**
- **Setup:** the same Manifold process (PID 56708), the same recorder launch, Audio Hijack, DeckLink
  audio set to Computer. Manifold played `manifold-sync-23.976p.mp4` from disk at O = 0 (no offset
  on a file, 2d).
- **Files:** `~/Movies/2026-10-05 13-32-33.mov` (68.1 s, max −39.8 dB) and
  `~/Music/Audio Hijack/20261005 1332 Recording.wav`.
- **c12.py `--file`:** 48 / 48 / 48 pairs, g_count ✅, **median +25.17 ms**, sd 4.78. It is inside
  the earlier launches' +2.5…+27.8 (§18.23, §18.24). c12's +1.708 bias is in both figures and
  cancels.

| figure | value |
|---|---|
| NDI capture (O = +25 applied) − control | +94.48 − 25.17 = **+69.3 ms, sound LATE at the device** |
| calibration's re-check, same state | **−1.79 ms** |
| device − calibration | **+71.1 ms (1.7 frames)**: ❌ against ±1 frame |
| implied device figure before the Apply (O = 0) | ≈ +44 ms late, where calibration said 24.9 ms EARLY |

- **The prediction's own wording had the sign wrong** ("if the device reads ≈ −68 while calibration
  reads 0"). The consistent reading is device = calibration + ~70 ms.
  - Stage D's SDK sender, in sync by construction, read heard −67…−70: a listener would hear ≈ 0.
  - Here: heard −24.9, device ≈ +44. Same gap, same direction.
- **So the ~70 ms is Manifold's NDI path, not the sender.** Two different senders (the SDK sender,
  OBS/DistroAV) show the same gap between Manifold's NDI heard − clock (host time: pull stamps, the
  picture delay, the direct anchor) and what reaches the speakers.
- **Consequence:**
  - On NDI, calibration proposes a value ~70 ms wrong, and in the opposite direction from what is
    needed when the true error is small. Today it offered +25 (delay the sound) for sound that was
    already ~44 ms late.
  - §19.10's NDI note applies: **NDI calibration should stay disabled until its heard figure is
    fixed** (Robbie's decision; no app change today). Stage D's NDI −67 ms question is answered.
- **The sender term asked about (−45…0) cannot be read from calibration on NDI.** From the device,
  OBS → NDI at O = 0 is ≈ +44 ms late on this rig today (42 ms OBS audio buffering, fresh launch).
- **c12 on the NDI capture:** sd 8.64 against the control's 4.78. NDI's ±3–5 ms per-pair scatter
  (§19.10) shows at the device too.

##### 2. DeckLink SDI during the item 1 NDI session (O = +25 at the start)

**⏸ ALL OF ITEM 2 IS DEFERRED, NOT FAILED (Robbie, 2026-10-05, mid-session).**
- **The reason:** this machine's SDI monitoring speakers cannot resolve these differences. Robbie: "I'm having a little trouble distinguishing."
- **Deferred to:** the final Release-build confirmation on Robbie's Resolve workstation.
- **No verdict is taken here for 2a–2d.** The ✅ / ❌ / ⚠️ marks below are what was observed, kept as evidence for that confirmation.
- **The log facts stand as recorded and do not depend on the speakers:**
  - 2a: 20 changes with 0 underruns;
  - 2c: the tap's standing shortfall past −30 ms, while the renderer allowed −80;
  - 2d: no offset carried to the file, and DeckLink underruns on file playback.
  The Resolve-workstation run should re-read them.

**Predictions** (Robbie's, each with its own band; the item 1 session stays connected until 2d):
- **2a. A change crossfades on SDI.**
  - ⇧⌥] presses, one a second, with no click and no gap heard on the SDI monitor.
  - In the log: no `SILENCE · ring empty at the cursor (underrun)` and no `snapping source cursor` at
    the presses; one `AUDIO OFFSET … ACCEPTED` per press.
  - Fail: any audible click or gap, or either log line at a press.
- **2b. SDI moves with the desktop.**
  - At O = +200 ms (+175 from item 1's +25), the sound on the SDI monitor is clearly late.
  - Audio ▸ Computer gives the same +200 on the Mac; back to SDI, Reset to 0 ms, and both are in
    sync.
  - Fail: SDI sounds unchanged at +200 (the offset not reaching the tap), or the two differ by
    ear.
- **2c. An advance beyond what the tap holds plays silence and re-anchors.**
  - From 0, ⇧⌥[ once a second until the banner refuses.
  - Past the tap's lead, SDI plays a short silence and re-anchors (`SILENCE · ring empty` /
    `underrun`, then clean). It never plays wrong or stuttering audio for more than the gap.
  - Record the most negative O that plays clean on SDI against the renderer's refusal point.
  - Fail: sustained garbage, repeated underruns after the re-anchor, or a stuck SDI.
- **2d. The offset is gone on file playback after the disconnect.**
  - With O left at a clearly non-zero value, disconnect NDI (⌃⌥⇧N), then play a file with DeckLink
    output on to SDI.
  - SDI is in sync, as before the session, and the log has no `AUDIO OFFSET` line for the file.
  - Fail: a lingering offset, or an `AUDIO OFFSET` line on the file.
  - The file is `manifold-sync-23.976p.mp4`, so the same playback is item 1's device control (above).

**2a — DEFERRED (observed: log clean, no click heard).**
- **Setup:** DeckLink output on with ⌃⌥O at 13:20, 1080p23.98, "video + SDI audio".
- **The presses:** 20 × ⇧⌥], 13:21:16–13:21:40, one every ~1.3 s.
  - The scripted Reset to 0 ms first failed: the A/V menu button was not reachable by
    accessibility with DeckLink on. So the run went **+25 → +225 ms**, not 0 → +200.
  - 20 × `AUDIO OFFSET … ACCEPTED`, each one splice (INSERT 480 fr / 10 ms), no rate write.
- **Log:** no `SILENCE · ring empty`, no `snapping source cursor`. DeckLinkAudio `underruns=0`
  throughout, buffered 179–181 ms, drift within ±2 ms.
- **Robbie, on SDI:** "sounded normal": no click, no gap.

**2b — DEFERRED (observed by ear only, with one comparison note).**
- **SDI, +225 ms:** "clearly late" (Robbie).
- **Audio ▸ Computer** (`audio destination → computer`, O unchanged at +225): **"that seems a bit
  tighter sync vs SDI out"** (Robbie, verbatim).
  - Late on both, but less late on the Mac by ear.
  - Not quantified. It is the direction item 1's capture points to: if the Mac path hears NDI ≈ 65 ms
    earlier than calibration's figure, +225 lands nearer +160 there.
  - SDI's own chain (the 180 ms card buffer, the monitor's processing) is the other candidate.
- **Back to SDI, then A/V ▸ Reset to 0 ms:** `AUDIO OFFSET +225.0 → +0.0 ms ACCEPTED`, one splice
  (DROP 10800 fr). On SDI: **"hard to tell but seems fine"** (Robbie, verbatim).
- **Log:** 56 `SILENCE · transport gate` lines, all between the switch to Computer and the switch
  back: the card is silent by design while the Mac has the audio. PCM from the ring resumed on SDI,
  `underruns=0`.

**2c — DEFERRED (observed in the log: no silence and no re-anchor; the SDI tap sticks in a standing shortfall).**
- **The presses:** from 0, 12 × ⇧⌥[ by script, 13:24:55–13:25:14.
- **The renderer:** 8 accepted (0 → **−80 ms**, each one splice, DROP 480 fr). Then −90 was
  REFUSED: "a 10.0 ms advance needs 170.0 ms of renderer queue … low point over the last 10 s is
  167.2 ms … at most 7.2 ms of advance is available · O stays −80.0 ms". As designed.
- **The DeckLink tap (SDI):**
  - Clean through **−30 ms** (`short` 1 → 5, sched = want).
  - **From the −40 step (13:25:00.9) every callback is short:** want ≈ 935 → 3000 frames, ringAvail
    ≈ 1030; `short` 5 → 1649 by 13:25:35 (~50 a second); `underruns=0`, `resyncs=0`.
  - The card's buffered audio drained 180 → ~138 ms and held there.
  - The tap schedules what the ring has. It inserts no silence and never re-anchors, so "want" keeps
    growing with each further advance and the deficit persists.
- **Robbie, on SDI, at −80 after the run:** "sounds a little weird almost like dropping frame"
  (verbatim). The shortfall is audible.
- **Most negative O clean on SDI: −30 ms**, against the renderer's limit of −80 ms in this session.
  The tap's lead is ~50 ms shorter than the renderer's, as §19.8 block 2 suspected.
- **Against the prediction:** no silence-then-re-anchor. Instead, a persistent deficit in the log
  that sounded off by ear. The verdict is deferred with the rest of item 2; the log behaviour is the
  thing to re-check on the Resolve workstation.
- **Process note:** the script brought Manifold to the front before every press, which kept Robbie
  out of the menus. Later steps leave focus to him.
- **Recovery on return — ✅.** A/V ▸ Reset to 0 ms by Robbie at 13:28:54: `−80.0 → +0.0 ms
  ACCEPTED`, one splice (INSERT 3840 fr).
  - Within a second the tap was full again: sched = want, buffered back to 180 ms, `short` frozen at
    11 683, `resyncs=0`.
  - So the deficit lasts exactly as long as O is beyond the tap's lead (~−30 ms here), and clears by
    itself on return. The shortfall ran 13:25:00 → 13:28:54.
  - Robbie: "sounds a bit better now".
- ⚠️ **Robbie: the SDI ear checks (2a, 2b, 2c) need a retest on a system with better speakers.**
  "I'm having a little trouble distinguishing." The log findings (2a clean; 2c's standing shortfall
  past −30 ms) do not depend on it.

**2d — DEFERRED (observed: the offset does not follow the file; separately, SDI underruns on file
playback in the log).**
- **Steps** (scripted, Robbie hands off):
  - 20 × ⇧⌥] to **+200 ms** (ACCEPTED, 13:30:11);
  - ⌃⌥⇧N: `[NDI] disconnected` 13:30:12, arbiter released NDI, DeckLink "live source gone — holding
    output mode 1080p23.98";
  - `open -a` the build with `manifold-sync-23.976p.mp4`: `[OPEN] loaded into an existing empty
    window` 13:30:17, FILE 23.976, the mode unchanged; Space to play, presented 24.0 fps.
- **Log:** **0** `AUDIO OFFSET` / `[AUDIO-OFFSET]` lines after the disconnect. The +200 stayed with
  the NDI session.
- **Robbie, on SDI:** "I don't sounds as expected to my ear" (verbatim). Read as: sync as expected,
  no dropouts heard. The better-speakers retest above applies.
- ⚠️ **DeckLink tap underruns during file playback:**
  - `!! UNDERRUN — ring has nothing at srcT=… scheduling silence, will re-anchor`, at srcT ≈ −0.03,
    10.03, 11.03, 13.04, 14.04, 15.04, 20.50, ~22 s. Often one a second, on the second boundary.
    The total went 245 → 260 in 22 s.
  - Between them: buffered 180 ms, sched = want, `resyncs=0`.
  - The ~244 before srcT 0 are the gap between the NDI disconnect and the file loading (no source),
    as expected.
  - Not investigated (no app change today). Whether it is new, or happens without a preceding live
    session, is open: a file-only launch with DeckLink on separates the two. Logged for BUGS.md.

##### 3. OBS → Cloudflare SRT and OBS → Cloudflare WHEP with the 23.976 clip

**Predictions** (Robbie; the WHEP sign settled before the run, as in item 1):
- **Cloudflare SRT: calibration proposes +70…+90 ms.** Cloudflare SRT's audio arrives ~70–80 ms
  early (§18.13), so the sound is heard early and the proposal is positive.
- **Cloudflare WHEP: calibration proposes −45…0 ms.** This is the sender term only: OBS sound late,
  as for NDI. WHEP's SR line carries no Cloudflare offset (§18.8, §18.24).
- **Each re-check after Apply for Session reads within ±2 ms of 0.**
- Each runs in its own connection: calibrate, Apply for Session, re-check, Cancel. Never Apply and
  Save.
- Item 1 found NDI's heard figure ~70 ms off the device. SRT and WHEP read heard − clock on the
  stream's PTS (choice 7), not on host pull stamps, so their figures are not expected to share
  that error. No device capture is in item 3's brief.

**3 · SRT result — ❌ sound LATE, not early; the proposal could not be applied (no advance budget);
a starvation hold then added its debt.**
- **Connection:** OBS profile "SRT Cloudflare", collection "Untitled", scene SYNC. Manifold, the same
  process as items 1–2, ▸ "DC Color Live  - SRT" (by Robbie). `[AUDIO-OFFSET] connect (srt) —
  session value 0 ms (from the saved stream's setting)`, transport up 13:41:32.
- **Settle:** steering at its ±2000 ppm rail for the first ~35 s (e_f −27 … −33 ms). Settled by
  +50 s (e_f +2.2, then within ±4 ms).
- **Run 1, Start 13:42:09 (+37 s), RESULT 13:42:35:** heard **+26.75 ms** (sound LATE), last 10 of
  20 pairs, p10…p90 +25.28…+27.34. **Proposed −27 ms · NOT APPLICABLE: "at most 0.0 ms available"**.
  - The sheet said so, and Robbie reported it: "moving sound 27 ms earlier needs more of the stream
    buffered than it has. At most 0 ms is available on this stream right now".
  - The 10 pairs (+53…+63 s) fall after the settle, so the figure is valid.
- **Why there is no advance budget:**
  - An advance needs advance + 100 keep + 10 fade + 50 margin ms of renderer queue.
  - This session's renderer depth: min 164, median 198, max 243 ms; **low-water 143 ms**.
  - Even 0 ms of advance (160 needed) does not fit, so on this path calibration can never apply a
    negative value.
- **⏸ STARVATION HOLD #1 at 13:42:41.38**, 6 s after run 1's result: "no input for 190 ms, renderer
  queue 19.7 ms". It resumed after 36 ms held, +5.1 ms from the held point, with 100 ms queued.
  No other hold, cut or catch-up.
- **Run 2, measure only (Start 13:49:26, Cancel):** heard **+61.44 ms** (25 pairs, p10…p90
  +59.53…+62.84), proposed −61 · NOT APPLICABLE (0.0 ms).
  - **+34.7 ms later than run 1, about the hold's 36 ms.**
  - ~~**The hold's debt went into lip-sync and has not been repaid**, as §18.22 modelled (the
    catch-up needs the whole debt queued, which this queue never has).~~ **WRONG, corrected the same
    day** ("Two findings re-examined" below).
    - The log has the debt repaid: `RECOVERY DROP #1 (WHOLE DEBT)` 26.2 of 26.2 ms, "RECOVERED 0.3 s
      after the resume", D 0.0 in every window afterwards.
    - The +34.7 ms is the MP4 loop sawtooth (7 loops between the two readings).
- **No Apply, so no re-check.** The re-check band (±2 ms) could not be tested.

| check | band | measured | |
|---|---|---|---|
| proposal | +70…+90 | **−27** (run 1), **−61** (run 2, after the hold) | ❌ the opposite sign: sound late |
| apply | — | not applicable: 0.0 ms of advance available | — |
| re-check | ±2 ms | not run | — |

- **Against §18.13** (Cloudflare SRT audio ~70–80 ms early, 2026-09-29): this session reads the
  other way.
  - §18.12 found Cloudflare SRT's offset varies by session.
  - Today's sender also differs: a fresh OBS, a new collection, the SYNC clip, not BEEPS.
  - Whether "~70–80 early" is a stable property of Cloudflare SRT is now in doubt.
- **For the user guide:** on a path whose queue sits near its floor, sound-late results can never
  be corrected by calibration, only measured. The advance budget is the queue's own lead.

**3 · WHEP result — proposal ✅ in band; first re-check ❌ (+14.6); the relation wandered ±12 ms over
the first ~2½ min; a second cycle passed (−1.9).**
- **Connection:** OBS profile "WHIP Cloudflare", scene SYNC. Manifold ▸ "DC Color Live - WHEP" (by
  Robbie), replacing the SRT connection.
  - `[AUDIO-OFFSET] connect (web) — session value 0 ms (from the saved stream's setting)`, connected
    13:51:18.5.
  - SDP CNAMEs differ (the SR line is applied anyway, as designed). First SR line offset +0.011 ms;
    windows −6.2 → −1.5…−2.0 ms; the slope not yet in use (fewer than 4 × 30 s batches).

| run | time (since connect) | O | heard A/V (pairs; p10…p90) | O-corrected (heard − O) | action |
|---|---|---|---|---|---|
| 1 | 13:51:42 → :57 (+24…+39 s) | 0 | **+40.26** (10; 39.36…41.49) | +40.3 | proposed **−40**, Apply for Session: one splice, DROP 1920 fr |
| 2, re-check | 13:52:02 → :24 | −40 | **+14.57** (15; 13.62…15.43) | +54.6 | ❌ ±2 |
| 3, measure only | 13:52:48 → 13:53:02 | −40 | +12.88 (10; 11.28…13.51) | +52.9 | Cancel |
| 4 | 13:53:18 → :32 | −40 | +24.59 (10; 23.88…25.96) | +64.6 | proposed −65, Apply: one splice, DROP 1200 fr |
| 5, re-check | 13:53:37 → :54 | −65 | **−1.93** (12; −3.24…−1.23) | +63.1 | ✅ ±2 |

- **The steering did exactly what was applied.**
  - Its own heard figure moved −1.4 → −40.3 ms at the first Apply, then held −40.2…−40.8.
  - e_f within ±1.7 ms from +20 s. No starvation hold, cut or re-anchor; SR-line offset steady at
    −1.5…−2.0 ms.
- **So the content relation itself moved** by +24 ms between runs 1 and 2 and by +12 ms between runs
  3 and 4. Nothing in Manifold's log moved with it.
  - Each run's own 10 pairs were tight (p10…p90 ≤ 2.1 ms) and passed the walk guard.
  - The wander is slower than a 10-pair window and larger than the ±2 ms re-check band.
  - Candidates, not separated: Cloudflare's WebRTC side, whose SR pair noise is 4–9 ms (§18.22),
    or OBS's WHIP output early in a stream. A longer session would show whether it settles.

| check | band | measured | |
|---|---|---|---|
| proposal (run 1) | −45…0 | **−40** | ✅ |
| re-check (run 2) | ±2 ms | **+14.57** | ❌ |
| second cycle re-check (run 5, not in the brief) | ±2 ms | −1.93 | ✅ |

- **Reading:**
  - The sender-term sign and size were predicted right: OBS's sound is late on WHEP.
  - But a single calibration taken in the first minute was off by 25 ms.
  - For the sheet: consider requiring ≥ 60 s connected (not the 10 s settle), or a longer pair
    window on WHEP (Robbie's decision; no change today).
- The session is left at O = −65 ms (session only, not saved).
- **DistroAV's NDI output stayed on through both runs** (Robbie asked whether it matters). The sender
  log shows no load effect:
  - audio buffering stayed at 42 ms, with no 21 ms additions;
  - SRT output: 0.0 % bytes dropped, 0.0 % retransmitted (so SRT's 190 ms input gap was downstream
    of OBS);
  - NDI render lag 23 / 43 125 frames (0.1 %).
  - Item 3 was not re-run. NDI stays on for item 4's NDI states (N01–N03) and is turned off
    after them, before item 6.
- **Addendum, found during item 4 (13:58): the WHEP relation kept moving, by −58 ms in 4 min, and
  the SR-line fit's slope entering use is the visible change.**
  - O-corrected relation, the same session: +40.3 (13:51:57) → +54.6 → +52.9 → +64.6 → +63.1
    (13:53:54) → **+4.5 (13:58:21)**.
  - **Steering:** heard A/V med −63.7…−68.3 ms throughout (= O), e_f within ±1.5 ms after 13:54. No
    hold, splice, coarse event or re-anchor; holes 1 (960 fr) at 13:53:59 only. One incomplete
    keyframe at 13:54:53 (PLI sent): video only.
  - **The SR-line fit:**
    - Its slope was "not in use (fewer than 4 × 30 s batches)" until ~13:55, then in use at
      +94…+116 ppm.
    - The window offset ramped **+6.6 → +32.5 ms** between 13:53:59 and 13:58:09. That is OBS's
      23.976 video-timestamp error (+66.6 ppm, §18.25) as Cloudflare's SRs carry it, plus the
      fit's early slope estimate.
  - **Not resolved live:** the content moved −58 ms while the line offset moved +26 ms. Sorting
    out signs and terms (applied line, content on Cloudflare's timestamps, the slope's entry into
    use) needs this session's SR pairs replayed offline (`replay-offset-lock`-style).
  - **What it means for calibration on Cloudflare WHEP:** a result taken before the fit's slope is
    in use (~2–4 min after connect) does not hold.
    - Run 1's −40 was taken at +39 s; even the passing re-check at +2 min 36 s was off by ~60 ms
      four minutes later.
    - Candidate rule (Robbie's decision): calibration waits for `[WHEP-SRFIT]` slope in use, or
      ≥ 4 min connected, on WHEP.
    - §18.8's 4.5 h hold says the fit is stable once established. That should be re-checked on
      this session's later readings.

##### ⚠️ Found during item 4 (14:02–14:07): THE BUNDLED MP4 CLIPS DRIFT A/V BY ONE AAC PAD PER LOOP IN OBS — today's live readings were taken on a stepping sender

**The check** (Robbie's go-ahead). The sender OBS recorded its own output, `~/Movies/2026-10-05
14-02-15.mov`, 14:02:15 → ~14:07, while it streamed to Cloudflare WHEP. Meanwhile Manifold ran six
measure-only calibrations, 40 s apart, at O = +47 (Cancel, no apply).
- **The recording, through the shipped detectors** (`fileprobe`, DUMP, 231 pairs; 20 s bins):
  - flat within ±0.02 ms inside each 60 s loop;
  - **+14.67 ms at every loop**: +38.12 → +52.79 → +67.45 → **+8.79** → +23.45 ms;
  - after four steps it wraps by −58.7 ms. OBS's media source resyncs; the threshold was not
    looked up.
- **Manifold over WHEP, the same minutes:**
  - heard +19.9, +30.4, +42.1, +39.8, **−21.4**, −9.9 ms (14:03:01 → 14:06:26);
  - three steps of +11…+12 ms, then −61 ms, the wrap ~30 s after the recording's, i.e. the
    transport.
  - So the WHEP "wander" in item 3 and item 4's addendum is mostly the sender.

**The cause:**
- `manifold-sync-23.976p.mp4`'s video is 1440 frames = 60 060.000 ms.
- Its AAC audio decodes to 2 883 584 samples = **60 074.667 ms**: whole 1024-sample frames, the last
  one padded.
- The edit list trims it to 2 882 880 samples (`elst` duration), but an ffmpeg-based player ignores
  the end trim. OBS's Media Source is one.
- So every loop the audio runs **704 samples = 14.667 ms** long and falls that much later.

| clips | decoded audio, 60 s clip | extra per loop |
|---|---|---|
| MP4 (AAC) 23.976, 29.97, 59.94 | 60 074.667 ms vs 60 060 | **+14.667 ms** |
| MP4 (AAC) 24, 25, 30, 50 | 60 010.667 ms vs 60 000 | **+10.667 ms** |
| **ProRes .mov (PCM s24le), all seven** | equal to the video | **0** |

- **Stage D's fixture fault was the same thing:** "untrimmed concat segments shifted the audio ~15 ms
  at each join" (§19.10).
- **For the product (Robbie's decision; nothing changed today):**
  - The sheet, the README and §19.8 D0 all say to loop the clip in OBS. With the MP4s that moves
    the measured relation 10.7–14.7 ms per minute, by sawtooth.
  - Options:
    - ship / recommend the ProRes `.mov` for OBS;
    - make each MP4's audio a whole number of AAC frames (e.g. 23.976: a multiple of 512 frames,
      since 2002 × N must be a multiple of 1024);
    - or carry the end trim in a form OBS honours.
  - Whether a length change is a "v2" under the pattern-version rule is Robbie's call. The code,
    unit, tone and flash would not change.
- **What it does to today's readings:**
  - Every live figure in items 1 and 3 was taken at an unknown loop phase. Each can be off by up to
    ~59 ms, and two figures minutes apart are not comparable.
  - **Item 1:** the 71 ms device − calibration gap compared readings 4 minutes apart (13:13 against
    13:17), so it is confounded. **Stage D's SDK result (−67…−70, no loop) still stands and
    supports it, but item 1 alone does not prove it.**
  - **Item 3:** the SRT and WHEP proposals and re-checks are confounded the same way. WHEP's
    +14.6 re-check fail and the later −58 ms wander are explained in large part.
    - The SR-fit observation stands as an observation.
    - So does SRT's +34.7 after the hold, which was within one loop: run 2 came 7 min after run 1,
      so not certainly.
- **For the rest of the session:** switch SYNC to `build/syncclips/manifold-sync-23.976p.mov`
  (ProRes, PCM), which loops exactly.

##### 4. The sheet and menu review (Robbie, on the live app)

**Brief:** walk each state in §19.10's screenshot list on the live app; Robbie's comments are noted
verbatim. There is no pass/fail band; it is a review. Never Apply and Save (no `defaults` written).

**Order** (the fewest reconnects):
1. **On the Cloudflare WHEP bookmark (connected):**
   - M01, the A/V menu while live;
   - M02, Help ▸ Download Sync Clips… (opens the v1 zip URL; 404 until uploaded);
   - Save Sync Clip…, the panel's rate line;
   - the S2 sheet states: idle, progress, result with Apply and Save offered and the line naming
     the bookmark, applied, re-check.
2. **X01, not applicable:** seen live on Cloudflare SRT in item 3 (Robbie read the wording out). Noted
   from that.
3. **NDI** (⌃⌥N): N01–N03, session only (the NDI note; only Apply for Session).
4. **HLS** (`MTX HLS`): H01, the greyed control's menu; H02, the sheet's HLS note with Start
   disabled.
5. **Clips not bundled** (`.build-cc/stageD-noclips-Profile`): C01, the note and the download link.
   It needs a relaunch, so it comes last and is optional.

**Robbie's comments, verbatim:**
- **M01, the A/V menu (live, Cloudflare WHEP, O = −65):** "I think the wording works well"
- **M02, Help ▸ Download Sync Clips…:** "yes that URL launched but 404 as expected". The URL is
  confirmed (`…/manifold/manifold-sync-clips-v1.zip`). The upload is still a BUGS.md pre-ship item.
- **Save Sync Clip… (the panel's rate line and rate menu, 23.976 stream):** "yes I think thats fine"
- **S2, the sheet on the WHEP bookmark (idle → Start → progress → result; Apply and Save offered,
  not pressed):** "looks and operates fine".
  - Robbie's run 22, 13:58:07 → :21: heard **−60.50 ms** at O = −65 (11 pairs, p10…p90
    −61.26…−59.16), proposed −5. O-corrected **+4.5 ms**, against +63.1 at 13:53:54. See the item 3
    addendum.
  - `streamBookmarks` hash unchanged after it.

##### Session stopped at 14:10 (Robbie), after the MP4 loop finding — items 4 (rest), 5 and 6 not run

- **Item 4:** M01, M02, Save Sync Clip… and S2 reviewed (comments above). Not reviewed: X01 (seen
  live on SRT, wording read out by Robbie), N01–N03, H01–H02, C01.
- **Item 5** (the browser cross-check of MediaMTX WHEP) and **item 6** (the 90-min Cloudflare SRT
  hold): not started. Item 6 must use the ProRes `.mov` (or MP4s fixed per the finding above),
  or its 30-min readings are sawtooth-confounded.
- **Pending re-runs on a loop-exact sender:** items 1 and 3.
- **State left:**
  - Manifold (monday-Profile, PID 56708) connected to Cloudflare WHEP, at a session-only O = +47.
  - The sender OBS streaming ("WHIP Cloudflare") with the NDI output on.
  - MediaMTX untouched (abs config).
  - `streamBookmarks` hash unchanged.
  - Nothing of OBS changed by Claude.


#### Two findings re-examined: SDI file underruns and the SRT hold debt — 2026-10-05 afternoon (unattended; no app change)

**The question:** is each a regression since b35a810 (before Stage A), pre-existing, or an artefact
of the MP4 loop drift?

**Predictions (Robbie, written before the investigation):**
- SDI underruns are pre-existing in file playback and unrelated to Stage A, since the tap read
  applies O only during live sessions.
- The unrepaid debt is an artefact of the clip stepping +14.7 ms per loop under the recovery; with
  a loop-free sender, D repays to within ±5 ms.

**Which held:**
- **The first: yes.**
- **The second: half.** The "unrepaid debt" was the clip, and in fact D had been repaid. But with a
  loop-free sender, D does not always repay within ±5 ms. After stalls of 1 s or more, 10–18 ms
  stays late for 20–50 s, at O = 0 and O ≠ 0, on today's build and on b35a810 alike.

**Builds:**
- `.build-cc/pre-stageA-Profile`: b35a810, built from a scratch worktree with the gitignored
  `ThirdParty/*/{include,lib}` and the DeckLink SDK symlinked in from the main tree. 0 errors.
- `.build-cc/monday-Profile`: `23e8223`, today's.

##### 1. SDI tap underruns during file playback — PRE-EXISTING (b35a810 has them, more); not Stage A; not the clip drift

**The code.** Stage A's read cannot run during file playback.
- `AudioTapBuffer.read` takes the `LiveReadOffsetFader` branch only when it is not the identity
  (O ≠ 0 or a fade in progress). Otherwise it calls `readLocked`, which is b35a810's read unchanged.
- The fader is set only by `FrameEngine.applyLiveAudioOffset`, which needs the session's steering.
  It is cleared in `beginLiveAudio` and in `endLiveAudio` (`clearLiveReadOffset()`: O = 0, any fade
  dropped).
- After a session ends there is no steering to set it again.
  - In today's log `endLiveAudio` ran at 13:30:12.499, after the last change (13:30:11).
  - The file was opened at 13:30:17.
- `DeckLinkBridge.mm` is unchanged since b35a810.

**Measured, unattended, no SDI listening** (`DeckLinkAudio: buffered … underruns=N short=M` counters):
- Each run: launch, open the file into the empty window, ⌃⌥O (1080p23.98, "video + SDI audio"),
  Space, 65 s, then read the counters.
- No stream and no live session in the launch.
- Builds alternated. Logs: `~/Desktop/manifold-soak/sdi-underrun/`.

| file | build | underruns (whole file) | short reads |
|---|---|---|---|
| `manifold-sync-23.976p.mp4` (AAC) | monday | 8, 23 | 49, 38 |
| same | **b35a810** | **39, 43** | 41, 61 |
| `manifold-sync-23.976p.mov` (ProRes, PCM) | monday | 4 | 7 |
| same | **b35a810** | **6** | 7 |

- **Pre-existing:** b35a810 underruns at least as often.
- **No live session is needed:** these launches had none (today's attended case followed one).
- **The clip drift is not involved:** Manifold plays the file once, and the drift is OBS's loop.
- **It depends on the source:** 4–6 per minute on PCM ProRes, 8–43 on the AAC MP4.
  - They fall anywhere in the file, e.g. srcT 0.01, 28.7 and 49.1 s.
  - Between them: buffered 180 ms, sched = want, `resyncs=0`. The log prints a sample, not every
    one.
- **Cause not investigated.** The ring has no audio at the card's read position. A candidate is the
  file path's tap feed arriving in bursts (AAC decode), not the card. That is a file-playback /
  DeckLink item for BUGS.md, not a Stage A one.

##### 2. The SRT starvation-hold "debt" — NOT unrepaid: the steering repaid it in 0.3 s; the +34.7 ms was the clip. A real, smaller, pre-existing remainder shows after ≥ 1 s stalls

**Today's log** (`att-1-ndi.manifold.log`, Cloudflare SRT, 13:41:32–13:50:53):

| time | line |
|---|---|
| 13:42:41.380 | `⏸ STARVATION HOLD #1` — no input for 190 ms, queue 19.7 ms, write 2; read back −0.00 ms, 27.77 ms after the decision |
| 13:42:41.390 | `▶ STARVATION RESUME #1` after 36 ms held, +5.1 ms from the held point, 100 ms queued · **audio 27.2 ms BEHIND the picture's line** = D at resume |
| 13:42:41.669 | `RECOVERY DROP #1 (WHOLE DEBT)` **1260 fr / 26.2 ms forward of 26.2 ms owed** · picture 0.0 ms behind · queue 224.8 ms · **RECOVERED 0.3 s after the resume** (0.0 folded) · no rate write |
| every window after | **D 0.0 ms**; steering heard A/V med −4.6…+0.9 ms (O +0.0); low-water 143.0–148.1 ms |

- **There were no refusals:** one recovery cut, accepted. The guard figures are on the line (queue
  224.8 ms against a 26.2 + 160 ms need).
- **O was 0** throughout: the session value 0, and calibration run 1 was not applicable, so it was
  not applied. So "D never takes O" was not exercised here; it is exercised in the repro below.
- **The low-point ring:**
  - `restartAfterWriteLocked` clears it (`queueHistoryCount = 0`) on every timebase write: anchor,
    coarse fallback, hold, resume.
  - For ≤ 10 s after a write, the advance figure rests on post-write lows only.
  - No interaction here. The 0 ms budget stood before the hold: low-water 135–145 ms against the
    160 ms guard. The second reading came 7 min after it.
- **The +34.7 ms between calibration runs 1 and 2** (13:42:35 → 13:49:58, 443 s ≈ 7.4 loops of the
  60.07 s MP4) is the sawtooth.
  - After 7–8 loops (+14.667 ms per step, −58.67 ms per wrap), the net move can only be +29.3, +44,
    −14.7 or −44 ms.
  - +34.7 sits nearest +29.3 (7 loops, 1 wrap).
  - The steering's own heard figure did not move.

**The repro, loop-free, unattended** (`repro/run.sh`; `syncD-23.976p-inj0.ts`, the clip ×5 as one
continuous 300 s file with trimmed joins, so no per-loop step):
- `STALLS="90:400 150:1000 210:2000"`, ffmpeg's default 1.05× catch-up.
- O set by ⇧⌥] after the first anchor.
- Per event: heard = beep(in) − (flash PTS + audio−now), calibration's b − (f + h), from the
  `[AV-CONTENT]` lines, in 10 s bins, minus O.
- Logs: `~/Desktop/manifold-soak/stalldebt/repro/`.

| run | pre-stall heard − O | 400 ms stall | 1000 ms stall | 2000 ms stall |
|---|---|---|---|---|
| monday, O = 0 | +20.4…+21.7 | D 140.8 → cut 126.0 + residual 25.8 → **back to baseline** ✅ | cut **139.0 of 158.7** owed + 2 residuals → **+12…+14 ms for ~30 s**, then baseline | cut **109.5 of 127.3** + 4 residuals → **+11…+15 ms until the file ended (~50 s)** |
| monday, **O = +80** | +1.1…+2.0 | D 109.2 → cut 97.8 + residual → **baseline** ✅ | cut **67.6 of 77.5** + 2 residuals → **+13…+16 ms ~20–30 s** | cut **131.0 of 147.7** + 4 residuals → **+12…+18 ms ~40 s**, then baseline |
| **b35a810**, O = 0 | −1.3…+0.5 | cut 29.0 of 37.0 + residual → **baseline** ✅ | cut **61.8 of 81.7** + 2 residuals → **+11…+15 ms ~30 s** | cut **29.7 of 42.6** + 4 residuals → **+12…+16 ms ~50 s** |

- **The same on both builds and at both O, so it is not a regression and does not depend on O.**
  - D at resume is the physical debt at O = +80 as at O = 0 (123 / 691 / 1702 ms against
    159 / 741 / 1755; the held times differ with the sender). D never takes O, live.
- **Why the remainder is left:**
  - The whole-debt cut is `min(D, room, maxDrop)`, taken once `room ≥ D − recoveryFoldSeconds`
    (20 ms).
  - With the queue up to 20 ms short of D, it cuts what fits, and `recover` folds the rest (< 20 ms)
    "into the loop" and logs RECOVERED.
  - The residual splice fires only at |e_f| > 20 ms.
  - So a 10–20 ms remainder sits inside both thresholds, which matches the
    lingering +11…+18 ms. Folded per cut: 8.0–19.9 ms. The 400 ms stalls folded 8–15 ms too, and
    their residual splice and the loop took it back.
  - The residual drops that do fire (~26 ms at e_f −20) are matched by the integrator winding
    (i −786 → −952 ppm): §13.4's rail class, as §18.19 recorded.
- **By §18.19's own definition this is in band** (sync = within ±20 ms). It is not within the ±5 ms
  the prediction asked.
  - A tighter fold or residual threshold (e.g. 5–10 ms) is the lever. That is Robbie's decision; no
    change today.
- **Also seen, pre-existing (both builds), not the question:**
  - On this fixture over local SRT, the first anchor came ~38 s after transport-up.
  - Then 7–8 coarse level re-anchors in ~1.5 s (e −3…−4.4 s, queue 3.6–5.7 s). Settled before any
    stall.

**Summary for BUGS.md (not edited today):**
1. The DeckLink file-playback tap underruns: pre-existing, AAC-heavy.
2. The ≤ 20 ms post-stall remainder (fold + residual threshold): a tuning decision.
3. The ~38 s first anchor with coarse re-anchors on the TS fixture over local SRT.
4. None is a Stage A–D regression.


### 19.11 The bundled sync clips loop sample-exactly: H.264 + PCM `.mov`, four whole code cycles — 2026-10-05 (uncommitted)

**The problem** (§19.10, attended section):
- The bundled H.264 / AAC MP4s decode to whole 1024-sample AAC frames: 2 883 584 samples against the
  video's 2 882 880 at 23.976.
- The edit list trims the end, but an ffmpeg-based player ignores the end trim, and OBS's Media
  Source is one. So every loop moved the sound **+14.667 ms** (23.976 / 29.97 / 59.94) or
  **+10.667 ms** (24 / 25 / 30 / 50), wrapping when OBS resynced.
- The ProRes masters (PCM) were exact.

**Decided (Robbie, 2026-10-05):**
- The bundled clips must loop with zero A/V drift in OBS's Media Source.
- The coded pattern stays exactly as is (still v1; the zip is not uploaded).
- The ProRes masters are unchanged.
- ffmpeg only.

#### Options considered

| option | loops exactly? | bundled set | why not / why |
|---|---|---|---|
| AAC MP4, 60 s (as shipped) | ❌ one AAC pad a loop | 22 MB | the defect |
| AAC with the audio a multiple of 1024 samples | only if every player honours the priming skip, and the encoder's flush adds no frame | — | needs lcm(1024-sample frames, 120-frame cycles): 1920 frames = 80 s at 23.976. Fragile and lossy |
| ALAC in `.mov` | yes in principle (a short last frame) | ~15–20 MB | one more codec path, untested in OBS; PCM fits the budget |
| PCM in `.mp4` | yes | — | poor support (QuickTime, the mp4 muxer's ipcm) |
| ProRes, shortened | yes | ~25–55 MB a clip | too large to bundle |
| **H.264 + PCM in `.mov`, 60 s** | yes | ~80 MB | over the 50 MB budget; and 60 s is 12.5 cycles at 25 / 50, so the code breaks at the seam |
| **H.264 + PCM s16le in `.mov`, 4 whole code cycles — CHOSEN** | **yes, by construction** | **27.1 MB** | PCM has no codec padding; whole cycles are whole frames AND samples at every rate; the code runs on across the seam |

- **PCM 16-bit, not 24:** the clip's floor is −60 dBFS. 16-bit quantisation (−98 dBFS) is far below
  it, and the tone's timing does not depend on the word length. 24-bit would be ~42 MB.
- **No B-frames** (`-bf 0`): no composition offset, so the video's edit list starts at media time 0,
  like the audio's (checked: both `media time: 0`, full duration).
- **The name is `manifold-sync-<label>p-h264.mov`,** so it never collides with the master
  `manifold-sync-<label>p.mov`, in build/syncclips/ or in a user's folder.

#### The length: four whole code cycles

- A cycle is 120 × unit frames. 120 is a multiple of 5, and 5 frames is a whole number of 48 kHz
  samples at 29.97 / 59.94 (5 × 1601.6, 5 × 800.8). So any whole number of cycles is whole frames
  AND whole samples at every rate.
- **Across the seam:** events at F0 + unit × {0, 23, 52, 83} + C·c. The last event of the last cycle
  is 37 steps before (clip length + F0), the next pass's first event. The closing interval is the
  code's own 37, and F0 < 37 × unit at every rate (24…60 frames against 37 / 74). `swift test`
  asserts both for every clip.
- `generate.sh` checks the sample count is whole, then cuts the audio to exactly that many samples
  (`atrim=end_sample`, after a 0.1 s longer `aevalsrc`).

| clip | frames | samples | length | events | file |
|---|---|---|---|---|---|
| 23.976p | 480 | 960 960 | 20.020 s | 16 | 4.24 MB |
| 24p | 480 | 960 000 | 20.000 s | 16 | 4.22 MB |
| 25p | 480 | 921 600 | 19.200 s | 16 | 4.06 MB |
| 29.97p | 480 | 768 768 | 16.016 s | 16 | 3.45 MB |
| 30p | 480 | 768 000 | 16.000 s | 16 | 3.44 MB |
| 50p | 960 | 921 600 | 19.200 s | 16 | 4.14 MB |
| 59.94p | 960 | 768 768 | 16.016 s | 16 | 3.53 MB |
| **set** | | | | | **27.1 MB** (≤ 50 MB target) |

- At 23.976 and 59.94 the looped clip's events are exactly the old 60 s clip's (60 s was 12 / 15
  whole cycles there).
- The DMG grows by ~5 MB against the MP4 set, not ~22.

#### What changed (no change to the pattern, the detectors, the matcher or the masters)

| file | change |
|---|---|
| `scripts/syncclips/recipes.tsv` | a `cycles` column (4) |
| `scripts/syncclips/generate.sh` | formats `mov` (the ProRes master, unchanged) and `h264` (the bundled clip); the `mp4` branch removed |
| `scripts/syncclips/verify.py` | two kinds of clip by name; an EXACT LENGTH gate (decoded samples and frames = the recipe's); `--loop N`, the loop test; the default set is `.mov` only |
| `scripts/release-mac.sh` | 3b generates `SYNCCLIPS_FORMATS=h264` and **fails a clip that does not decode to exactly its frames and samples with PCM audio** (ffmpeg only; tested on the set, and on an AAC re-wrap, which it rejects); 6c checks `-h264.mov` |
| `project.yml` | "Bundle sync clips" copies `-h264.mov` |
| `SyncClips.swift` | `loopCycles`; `frameCount` = the bundled clip's; `durationSeconds`; `mp4Name` → `bundledName` |
| `CalibrationMode.swift` (Save Sync Clip…) | the bundled `.mov` name, the panel's type `.quickTimeMovie`. Wording unchanged (reviewed by Robbie, §19.10) |
| `obs-scene-collection.json` | the seven sources play `-h264.mov` |
| `SyncCalibrationTests` | the catalogue (16 events; 480 / 960 frames; whole samples; the seam interval); the measurement tests feed the LOOPED clip over the same 60 / 120 s spans as before |
| `scripts/syncclips/README.md` | both kinds of clip, the loop test, why not MP4 |

#### Verification

**`verify.py --loop 20`, every bundled clip: 7 / 7 PASS.** The legacy 23.976 MP4 FAILS as the
control.

| clip | events in sync | A/V worst | decoded length | loop ×20: drift (last − first pass) | per-pass median |
|---|---|---|---|---|---|
| 23.976p | 16 / 16, flash frames and code exact | 0.119 µs | 480 / 480 fr, 960 960 / 960 960 smp | **−0.000 µs** | +0.00 µs, every pass |
| 24p | 16 / 16 | 0.113 µs | exact | **−0.000 µs** | +0.03 µs, every pass |
| 25p | 16 / 16 | 0.123 µs | exact | **−0.000 µs** | −0.04 µs, every pass |
| 29.97p | 16 / 16 | 0.132 µs | exact | **−0.000 µs** | −0.01 µs, every pass |
| 30p | 16 / 16 | 0.114 µs | exact | **−0.000 µs** | +0.04 µs, every pass |
| 50p | 16 / 16 | 0.228 µs | exact | **−0.000 µs** | −0.03 µs, every pass |
| 59.94p | 16 / 16 | 0.293 µs | 960 / 960 fr, 768 768 / 768 768 smp | **−0.000 µs** | −0.01 µs, every pass |
| *legacy 23.976 MP4 (control)* | 48 / 48 | 0.314 µs | 2 883 584 / 2 882 880 smp ❌ | pass 1 → 2: **+14 666.66 µs** | ❌ |

- **The loop test:** decode once, append 20× (audio sample after sample; video frame after frame,
  each pass the decoded frames × 1 / rate later), and fit every event of every pass.
  - The control's pass 2 reads +14 666.66 µs, exactly its 704 extra samples.
  - Its later passes (≥ 29 ms off) fall outside the fit's ±20 ms search window, so the figures
    printed there are not readings; the per-pass drift is the 704 samples.
- **Also on every clip:**
  - flash pts − k / rate 0.000 µs; tone peak 0.0998–0.1001;
  - floor −60.0 dBFS RMS / −55.2 peak; no bursts outside tones;
  - Rec.709 tags as §19.9;
  - c12 16 / 16 / 16 with g_count True, median +1.67…+1.69 ms (§19.9's known onset rule; its
    gap_rms −40 / −44 dB at 29.97 / 30 / 59.94 is §19.9 deviation 3).
- **`pairing_check.py` (median score):** 7 / 7 PASS, 0 failures in 508 offsets each, margins as
  §19.9 (33.3–41.7 ms).
- **The in-app detectors** (the stage D harness `fileprobe`, AVFoundation decode): **16 / 16 flashes
  and tones on every clip**, heard A/V median −0.014…+0.001 ms.

**In OBS (OBS 32.2.2, the sender instance, Media Source on loop).**
- Robbie set the existing "Media" source in his "Untitled" collection to
  `manifold-sync-23.976p-h264.mov`. No source and no collection was added.
- Claude started and stopped recording over the websocket (the profile's own recording settings):
  `~/Movies/2026-10-05 15-10-51.mov`, 250 s.

| loop | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 (½) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| A/V median (ms) | −50.276 | −50.275 | −50.275 | −50.276 | −50.275 | −50.276 | −50.277 | −50.276 | −50.276 | −50.276 | −50.275 | −50.276 | −50.276 |
| Δ vs loop 0 (µs) | 0 | +1 | +1 | 0 | +1 | 0 | −1 | 0 | 0 | 0 | +1 | 0 | +1 |

- **12.5 loops, 200 events: zero drift** (per-loop medians within ±0.001 ms, all 200 pairs
  −50.287…−50.264 ms). Loop starts are exactly 20.02 s apart.
- Against the MP4 earlier that day, in the same OBS: +14.67 ms at every loop, wrapping after four.
- **The constant −50.3 ms is OBS's own A/V in its recording** (sound early). It is the same on every
  loop, so it is not the clip. Not investigated. OBS's audio buffering was 42 ms that launch.

**`swift test`: 173 / 173.** The same count as before: the catalogue test was rewritten, no test was
added or removed.

**Profile build** (`.build-cc/syncloop-Profile`): 0 errors, no new warnings in the touched files.
"Sync clips bundled: 7 of 7". `Contents/Resources/SyncClips` holds exactly the seven
`-h264.mov`, 26 MB on disk.

#### Not done

- Save Sync Clip… was not exercised through its panel on the live app. The code path is a rename
  and a content type; the build bundles 7 / 7.
- The 25 / 50 / 59.94 clips were looped only offline, not in OBS (23.976 in OBS).
- ~~The ProRes masters keep their 60 s length. At 25 and 50 that is 12.5 cycles, so a looped master's
  seam breaks the code there.~~ Done the same day: see "The masters, loop-exact too" below.
- Robbie's "Media" source still points at the new clip. Setting it back is his choice.

#### The masters, loop-exact too — 2026-10-05 (uncommitted; the v1 zip still unuploaded; pattern unchanged, still v1)

**The rule:** each master is `master_cycles` whole code cycles (a new `recipes.tsv` column), the fewest
that reach 60 s.
- 60 s already was whole cycles at five rates.
- At 25 and 50 a cycle is 4.8 s, so 60 s was 12.5 cycles, and the code broke at the loop seam (and
  the old clip ended mid-cycle).
- 12 cycles (57.6 s) and 13 (62.4 s) are equally near 60 s. **13 was chosen so every master stays ≥
  60 s.** Whole cycles are whole frames and whole samples (a cycle is a multiple of 5 frames), and the
  code runs on across the seam as for the bundled clip.
- `generate.sh` checks the sample count is whole. `release-mac.sh` 3b and `verify.py` read the new
  column.

| master | cycles | frames | samples | length | events | size | vs before |
|---|---|---|---|---|---|---|---|
| 23.976p | 12 | 1440 | 2 882 880 | 60.060 s | 48 | 79.4 MB | **byte-identical** |
| 24p | 12 | 1440 | 2 880 000 | 60.000 s | 48 | 76.7 MB | byte-identical |
| **25p** | **13** | **1560** | **2 995 200** | **62.400 s** | **52** | **82.3 MB** | was 1500 fr / 60 s |
| 29.97p | 15 | 1800 | 2 882 880 | 60.060 s | 60 | 94.6 MB | byte-identical |
| 30p | 15 | 1800 | 2 880 000 | 60.000 s | 60 | 91.6 MB | byte-identical |
| **50p** | **13** | **3120** | **2 995 200** | **62.400 s** | **52** | **146.8 MB** | was 3000 fr / 60 s |
| 59.94p | 15 | 3600 | 2 882 880 | 60.060 s | 60 | 171.5 MB | byte-identical |
| **set** | | | | | | **742.8 MB** (742 831 977 bytes) | |

- **"Byte-identical"** is a sha256 against the masters generated before the change.
- **§19.9's "755 MB"** is not reproducible from today's files: the two old masters are overwritten,
  and the five unchanged ones plus the two new ones total 742.8 MB. The 742.8 MB is measured; BUGS.md's
  zip item now carries it.
- **The bundled clips are unchanged:** regenerated after the edit, all seven are byte-identical, and
  the release loop gate passes on the five-column recipe.

**`verify.py --loop 20` on every master: 7 / 7 PASS.**
- Every event in sync: worst 0.118–0.432 µs; flash pts − k / rate 0.000 µs.
- At 25p and 50p, 52 / 52 events, flash frames exact, the intervals follow the code.
- **The exact length on every master:** decoded frames and samples = the recipe's (2 995 200 /
  2 995 200 at 25p and 50p).
- **Loop ×20: drift −0.000 / +0.000 µs on all seven**, and each master's per-pass median constant
  (−0.02 … +0.01 µs).
- c12 52 / 52 / 52 at 25p and 50p, median +1.69 ms (§19.9's known onset rule).
- Masters were checked offline only, not in OBS. They share the bundled clips' audio construction
  (PCM, exact sample count), which OBS looped with zero drift.

### 19.12 SDI tap underruns during file playback: the muted renderer starves the tap — 2026-10-05 (diagnosed 15:30–16:42; fix implemented 16:45–17:50, uncommitted)

**The question (BUGS.md, open):** what an underrun puts on the wire, when underruns happen, why AAC
has more of them than PCM, and which setting removes them, at what cost. All measured from the tap's
own counters, with no listening.

**Predictions (Robbie, written before the investigation):**
- The underruns are a fill-ahead margin too small for AAC's 1024-sample delivery: the tap's lead
  over the read cursor dips under one codec frame.
- Raising the tap's fill-ahead (or the bridge's audio depth) by one codec frame (~21 ms) brings
  both formats to 0 underruns with no change to A/V alignment on SDI.

**Which held:**
- **The first: only "the lead dips to zero".** The ring does run dry at the cursor, but codec
  frames play no part.
  - The AVF reader delivers 8192- and 7168-frame buffers (171 / 149 ms) for AAC and PCM alike.
  - The tap's lead collapses by up to ~150 ms, not ~21 ms. The **muted** system renderer lets its
    queue drain past the playhead before it asks for more, and the tap is filled only when the
    renderer asks.
- **The second: no.**
  - Raising the bridge's audio depth by 21 ms makes it worse: the cursor reads that much later.
  - A ~21 ms fill-ahead is short of the ~95 ms deficit.
  - Any fill-ahead on the current 2 s ring adds a new underrun at the start of play.
  - What reaches 0 / 7 is a 250 ms tap look-ahead plus a 4 s ring. It does not move the card's
    cursor (by the bridge's own model; not checked on a device).

**Setup.**
- **Build:** `.build-cc/tapinstr-Profile`, HEAD `a350dd8`, from a scratch worktree with the
  gitignored `ThirdParty/*/{include,lib}` and the DeckLink SDK symlinked in, as for §19.10.
- **Instrumentation:** `TAPI` lines on one clock (mach uptime) for:
  - the AVF audio pump: every wake, every `copyNextSampleBuffer` with its duration, and every "renderer full";
  - every tap append: pts, frames, the new head;
  - every tap read: start, want, got, the head, the tail of the 2 s window, and lead = head − start;
  - every card audio callback: buffered, vq, want, staged pts, ideal, cursor, got;
  - every video frame completion.
- **Three scratch knobs (env, default off):**
  - `MANIFOLD_DL_AUDIO_DEPTH`: the bridge's `kAudioTargetDepthSeconds`.
  - `MANIFOLD_TAP_LOOKAHEAD`: the AVF pump reads this far past what the renderer accepted, ingests
    it into the tap now, and enqueues it at the renderer's next wake.
  - `MANIFOLD_TAP_WINDOW`: the tap ring's `windowSeconds`.
- **The patch:** `~/Desktop/manifold-soak/sdi-underrun-1912/scratch-instrument-and-knobs.patch`.
  It also has `MANIFOLD_MUTE_VIA_VOLUME`, below.
- **Runs:** §19.10's driver unchanged. Launch, open the file into the empty window, ⌃⌥O
  (1080p23.98, video + SDI audio), Space, 65 s.
  - No stream, no defaults written.
  - The same two files as §19.10 (sha256 unchanged): `build/syncclips/manifold-sync-23.976p.mp4`
    (AAC) and `manifold-sync-23.976p.mov` (ProRes, PCM).
  - Logs: `~/Desktop/manifold-soak/sdi-underrun-1912/`.
- **The instrumentation does not visibly perturb it:** baseline counts of 8–45 underrun callbacks
  on the MP4 and 1–9 on the MOV, against §19.10's 8–43 and 4–6.

#### Q1. What an underrun is, and what goes on the wire

- `AudioTapBuffer.readLocked` returns 0 in two different cases. The bridge cannot tell them apart:
  - **Dry:** `start ≥ head`. The tap holds nothing yet at the cursor.
  - **Overrun:** `start < tail`. The 2 s window has already overwritten the cursor's samples.
  - Both were measured (Q2).
- **On the wire: digital silence, then a skip.** On `got == 0`, `RenderAudioSamples` schedules
  `want` frames of zeros (~20–35 ms) and drops the anchor.
  - The next callback snaps the cursor to `ideal`, which is already past the dry head. So it
    underruns again, 1–4 callbacks in a row, until the renderer's next wake refills the tap.
  - The source audio under the gap is skipped for good, not delayed.
  - Example: `base-mp4-1` at srcT 7.147 s, three callbacks (1573 + 923 + 995 frames).
    - The wire carries 73 ms of silence.
    - The read resumes at 7.229 s, so 82 ms of programme is lost.
  - Not a repeat, and not a short buffer. The short-read path (`0 < got < want`) puts nothing
    wrong on the wire: it schedules what exists and the 200 ms card buffer covers the rest.
  - **This is audible on SDI by construction:** a 20–100 ms hole in the programme.
- **The `underruns=` counter counts callbacks, not events.** `base-mp4-1`: 45 callbacks, 20 events,
  1158 ms of silence in 60 s.

#### Q2. When they happen

**Mid-file (the dry case): a steady rate, one per renderer refill cycle. Not decode, and not the card.**
- 68 mid-file events across the six baseline runs and three depth runs.
- Every one starts **893–996 ms after an AVF pump wake** and ends **0–19 ms before the next wake**.
- `copyNextSampleBuffer` never took more than 3.0 ms in any run, so decode bursts are not involved.
- The card is steady throughout: vq = 4, `buffered` ~180 ms, `resyncs=0`, no late or dropped frames.

**The mechanism, from the `wake` lines.** While SDI owns the audio, `applyAudioMute` sets
`audioRenderer.isMuted` (`deckLinkOwnsAudio`).
- The muted renderer wakes the pump on a **0.5 s or 1.0 s** grid and takes ~0.9 s of buffers.
- It then sleeps until its queue has drained to around the playhead:
  - head − sync at each wake, `base-mp4-1`: min −144, median −44, max +475 ms;
  - `base-mov-1`: min −148, median +15, max +477 ms.
- The card's cursor reads at **sync − 53…−54 ms** (median, every baseline run):
  `ideal = stagedPts + audioDepth − videoDepth`, i.e. ~180 ms − 5 × 41.7 ms, minus the staged
  frame's quantisation.
- Every wake whose head has fallen below ~sync − 54 ms ends in an underrun just before the wake.

**Unmuted control** (no DeckLink, the renderer audible, MP4, 40 s, `nodl-mp4-1`):
- head − sync at every wake is **+1240…+1613 ms**. It never comes near the playhead.
- §4.5 found that a muted renderer keeps the same clock and consumption rate. True, but its
  *refill* policy is different, and the tap inherits that.
- So the effect is SDI-only: the desktop renderer is muted whenever it starves.

**At the start of play (the overrun case).**
- Before Space, the renderer prefills **1.64–2.01 s** (six baseline runs). The tap window is
  exactly **2.0 s**.
- When prefill + the cursor's start offset exceeds 2 s, the file's first samples are overwritten
  before the card reads them.
  - That is §19.10's `srcT=0.014` underrun.
  - Here: one at srcT 0.034 in each `d221-mp4` run.

**After seeks: not measured.** These runs have no seeks. A seek calls `reset()`, and the bridge's
post-seek silence is designed behaviour (`got <= 0`, "post-seek gap").

#### Q3. Why AAC has more than PCM

- **Not codec frame size.** Same reader buffer sizes:

  | file | reader buffers (`base-*-1`) |
  |---|---|
  | MP4 | 288 × 8192, 60 × 7168, 25 × 2048, 10 others |
  | MOV | 262 × 8192, 135 × 2048, 51 × 7168, 20 others |

- **Not where the card reads:** the same cursor − sync on both (−53 / −54 ms).
- **The difference is where the head lands at each wake.** The renderer accepts whole buffers up to
  its high-water mark, then sleeps a fixed 0.5 / 1.0 s, so the head at the next wake beats against
  the buffer grid.
  - The MP4's grid sat in long runs at −80…−143 ms (e.g. −127, −123, −120, −119, −114, −112 at
    34–39 s, one underrun per second).
  - The MOV's hovered around 0 ± 60 ms.
- So AAC loses more often on these two files, but both formats have the same failure, and the
  counts vary run to run:

  | file | events | underrun callbacks | silence in 60 s |
  |---|---|---|---|
  | MP4 | 20, 6, 6 | 45, 23, 8 | 1158, 546, 237 ms |
  | MOV | 1, 2, 5 | 1, 9, 8 | 36, 200, 233 ms |

#### Q4. Settings tried, and their cost

| setting | runs | events / run | mid-file min lead (0.5–59.5 s) | cursor − sync | card min depth | verdict |
|---|---|---|---|---|---|---|
| baseline (depth 200 ms, window 2 s) | 3 + 3 | MP4 6–20, MOV 1–5 | **0 ms** (all 6) | −53…−54 ms | 60–117 ms | — |
| depth **0.221** (+1 AAC frame, the prediction) | 2 + 1 | MP4 **11, 14**, MOV 5 | 0 ms | **−32 ms** | 65–112 ms | **worse:** the cursor reads 21 ms later |
| depth **0.100** | 2 + 1 | 1 (start; cursor < 0) | **9.8**, 21, 45 ms | **−153 ms** | **70–75 ms** | mid-file events gone, but a 10 ms margin and half the card cushion. Rejected |
| window **4 s** only | 1 | MP4 4 (13 cbs) | 0 ms | −53.5 ms | 65 ms | no effect: the dry case is untouched |
| look-ahead **0.25 s**, window 2 s | 3 + 3 | 1 or 0, all **at start**: 23–27 cbs, ~0.5 s | 184–265 ms | −53 ms | 163–172 ms | mid-file fixed, but the head reaches 2.47 s before play, so the start is overrun |
| **look-ahead 0.25 s + window 4 s** | **4 + 3** | **0 (all 7)** | **232–275 ms** | **−53.0…−54.0 ms** | **158–172 ms** | ✅ |
| renderer volume 0 not `isMuted`, window 2 s | 2 + 1 | **83–88** (16.5–17.9 s of silence) | — | −45 ms | — | the unmuted renderer runs ~1.5 s ahead and overruns a 2 s ring at every wake |
| renderer volume 0 not `isMuted`, window 4 s | 2 + 1 | **0 (all 3)** | 561–573 ms (max 2.43 s, over a 2 s ring) | −53.3…−53.7 ms | 162–172 ms | ✅ also, but rests on undocumented renderer behaviour |

- **The look-ahead + 4 s window costs no latency.**
  - The bridge is untouched: same cursor − sync, vq = 4, same depth target.
  - The bridge's own alignment error (ideal − cursor, anchored callbacks): median −0.37…−1.08 ms,
    |p99| 24–27 ms, against baseline −3.05…+1.40 ms and 29–34 ms. Baseline's tail is wider because
    of its re-anchors.
  - **Device-level A/V on SDI was not measured.** That needs the attended OBS recorder, and an
    unchanged cursor is the argument here, not a capture.
- **Its other costs:**
  - Memory: the ring doubles. 1.5 MB for stereo 48 kHz, 12 MB for 16 ch.
  - Up to 250 ms more decoded audio held in the pump.
  - The max mid-file lead is 1.96 s, so a 4 s ring leaves ~2 s of headroom.

#### Proposed fix (for Robbie to decide; no shipped code changed)

1. **The AVF audio pump keeps a 250 ms look-ahead into the tap**, independent of the renderer's
   refill policy.
   - After each `while isReadyForMoreMediaData` loop, read ahead until the buffers held total
     ≥ 250 ms. `ingest` each into the tap at read time, and enqueue the held buffers first at the
     next wake.
   - The held buffers belong to the closure, so a seek or track switch (new token) drops them with it.
2. **Raise `AudioTapBuffer.windowSeconds` from 2.0 to 4.0.**
   - Needed with (1): the renderer's 1.6–2.0 s prefill plus the look-ahead overruns a 2 s ring at
     the start.
   - The 2 s ring is already marginal on its own: one baseline prefill reached 2.005 s.

Measured effect of 1 + 2 in the scratch build: **0 underruns, 0 mid-file short reads, mid-file lead
≥ 232 ms in 7 / 7 runs** (4 MP4, 3 MOV), against 6–20 / 1–5 events per baseline run.

The alternative (mute by `volume = 0`, plus the 4 s window) also measured 0 / 3. It is not
recommended:
- it depends on an undocumented difference between the renderer's muted and unmuted refill;
- the renderer keeps rendering to the device;
- on a 2 s ring it is far worse than today.

#### Not done

- **The libav path** (MXF and others, `LibavAudioSource`): not examined. It feeds the same tap
  from its own pump. Whether it inherits the muted renderer's refill the same way is the next check.
- **Seeks, pause / resume, loop wrap:** not exercised.
- **Device-level A/V on SDI with the fix:** needs the attended recorder.
- **A secondary bridge item, not changed:** after a dry read, the bridge re-anchors forward to
  `ideal`, past a head that cannot have moved yet. One underrun becomes 2–4 consecutive silent
  callbacks. With the fix there are none to compound.

#### Implemented — 2026-10-05 16:45–17:50 (unattended; uncommitted)

**Decided (Robbie, 2026-10-05):**
- A 250 ms tap look-ahead in both file pumps, whether or not the renderer is muted.
- `windowSeconds` 2.0 → 4.0.
- The bridge unchanged, so no added SDI latency.
- Rejected: volume 0 instead of mute, and raising the card's audio depth.

**What changed:**
- **`FileAudioLookahead` (new leaf target, CoreMedia only)**, with `TapLookahead.seconds = 0.250`
  (the one constant) and `TapLookaheadPump<Buffer>`, the pump loop both file pumps now run. One per
  arm. Each renderer wake:
  1. Hand the renderer the held buffers first, then fresh decodes, while it is ready.
  2. Decode on until 250 ms is held, ingesting each buffer into the tap at decode time.
  - The renderer receives the identical sequence, at its own wakes; only the decode time moves.
  - It is a leaf target for the same linking reason as `AudioResample`: `swift test` cannot link
    ManifoldCore.
- **AVFoundation pump** (`FrameEngine.beginAudioReading`): the `while isReadyForMoreMediaData` loop
  is replaced by `lookahead.service(…)`.
  - `copyNextSampleBuffer` and `tap.ingest` are as before; `stopRequestingMediaData` on `.ended` or
    `.retired`, as before.
- **libav pump** (`LibavAudioSource.arm`): the same.
  - `onAudioFrame` now only enqueues. A new `onDecoded` tees to the tap at decode time.
  - `FrameEngine.beginLibavReading` wires both.
- **No stale look-ahead audio:**
  - The held buffers belong to the arm, i.e. the closure of the session token. Every event that moves
    the read position already retires the arm through `teardownAudioReading()`: token bump, renderer
    flush, `audioTap.reset()`. That covers seek, frame step, scrub release (`exactSeek` → `seek`),
    loop (`beginReading(from: 0)`), audio track and libav stream switch, and file switch.
  - The retired arm's held buffers are dropped the first time its block sees the stale token. Their
    tap copies went with the `reset()`.
  - `isCurrent` is re-tested after each decode and before the ingest, so a decode in flight at the
    teardown does not land in the freshly reset tap. That window existed before the change too, and is
    now closed.
  - Pause and fast shuttle move no read position and flush nothing; the card's transport gate
    silences them as before.
- **`AudioTapBuffer.windowSeconds` 2.0 → 4.0.** The comment states why: prefill 1.64–2.01 s, mid-file
  lead to 1.96 s, unmuted 2.43 s. Memory: 768 KB per channel at 48 kHz (1.5 MB stereo, 12.3 MB at 16 ch).
- **Bridge: the event-level underrun counter only.**
  - `m_underrunEvents` is one run of consecutive empty-ring callbacks.
  - `!! UNDERRUN EVENT #n ended — began at srcT=…, k callbacks, …f of silence (… ms)` is printed
    once per event, when it ends.
  - `events=` is added to the periodic line, and `underrunEvents=` to the stop summary.
  - Nothing parses those lines. The scratch instrumentation and env knobs are not carried over.

**Verify** (logs: `~/Desktop/manifold-soak/sdi-underrun-fix/`; build `.build-cc/lookahead-Profile`;
driver as in §19.10):

*File playback, DeckLink on, file-only launches, 65 s:*

| file | path | fixed build | pre-fix (`monday-Profile`) |
|---|---|---|---|
| `manifold-sync-23.976p.mp4` (AAC) | AVF | **0 events, 0 underrun callbacks, 4 / 4 runs** | 6–20 events / run (above) |
| `manifold-sync-23.976p.mov` (ProRes, PCM) | AVF | **0, 4 / 4** | 1–5 events / run |
| DNxHR SQ MXF, 24-bit PCM, made from the `.mov` with ffmpeg (same content, 60.06 s) | **libav** | **0, 4 / 4** | **0, 2 / 2** |

- Every fixed-run stop summary: `underruns=0 underrunEvents=0`.
  - `real` = 2 882 047–2 882 698 of the file's 2 882 880 samples reached SDI.
  - `shortReads=2`, both at end of file.
  - No late or dropped video frames.
- **The libav path did not reproduce the underruns on this MXF before the fix either.** Its `0` is
  therefore not evidence that the look-ahead was needed there, only that it does no harm. The same
  renderer drives it, so the AAC-like case on libav is untested rather than excluded.

*Transport, fixed build, MP4* (`transport.sh`: slider clicks via CGEvent, Space, a drag, the loop
button, `open -a` of the `.mov` into the window). Same script on the pre-fix build:

| event | fixed: underrun events (silence) | pre-fix: underrun callbacks |
|---|---|---|
| steady play | **0** | (above) |
| pause / resume × 5 | **0** | 0–3 |
| 5 seeks while playing (slider clicks) | **1–2 per seek, 20–100 ms each** | **52–115 per seek** (1–2 s of silence each) |
| scrub drag + release | **1, 139 ms** | 75 |
| loop seam (play-through at 60.06 s) | **1, 109 ms** | 171 (with the seek to 95 %) |
| file switch (`.mov` into the playing window) | **0** (one cursor resync) | 265 |

- **The brief's "0 across seeks, scrub release and loop" is NOT met.**
- What remains is one silence per discontinuity: the time from the seek to the new reader's first
  audio reaching the tap. The card keeps reading through it.
  - It is not stale audio: the tap holds nothing from before the seek.
  - It is not a dropout inside continuous programme.
  - Pre-fix, the same gap was 1–2 s, because the renderer's ~2 s prefill overran the 2 s ring after
    every seek: §19.12's start-of-play mechanism.
- **Not relabelled.** Gating the card while the new arm is empty would print gate silence instead of
  an underrun, with the same zeros on the wire. That hides the gap, it does not remove it.
  - Removing it needs the card to hold the last picture's audio position until the new reader has
    primed, or to delay the post-seek picture on SDI by the same ~100 ms. **Decided: accepted as
    designed behaviour** (see "Decisions" below).
- **Separately, a pre-existing oddity:** each slider click first stages a scrub frame at **pts 0** on
  SDI (`[V210] drag … SDI frontPts 0.000`). The card's anchor briefly reads srcT −0.03 s, which is
  where one of the 1–2 events per seek begins. That is the scrub producer's pts on the SDI staging
  path; it is not investigated here. **Kept open, "check before release"** (see "Decisions" below).

*DeckLink off (renderer unmuted), MP4, 30 s, fixed and pre-fix:*
- no `[PLAYBACK]` warnings and no renderer failure; one tap format line, no discontinuities.
- The renderer path is identical by construction: the same buffers, in the same order, enqueued only
  at the renderer's own wakes, with decode earlier.
- `testRendererGetsTheSameSequenceAndTheTapLeadsByTheLookahead` checks the sequence.
- **What the system output plays was not captured** (Audio Hijack, attended).

*Live:*
- **Replays against b35a810: 99 / 99 files byte-identical** (44 stdout reports, 55 TSVs; the §19.7
  gate's `cmp.sh`).
  - The replay tools compile only `LiveAudioResample` sources, which this change does not touch.
- **Local SRT with SDI owning the audio** (`scripts/soak/repro/run.sh`, `syncD-23.976p-inj0.ts`, 300 s;
  ⌃⌥O after connect; O stepped +40 → −40 → 0 ms in 10 ms steps; one 1000 ms stall at +150 s;
  `srt-fix-1`), and the same session on the pre-fix build (`srt-pre-1`):

  | | fixed | pre-fix |
  |---|---|---|
  | O changes | **16 / 16 ACCEPTED** (each one splice; SDI read moved by `LiveReadOffsetFader`) | 16 / 16 |
  | SDI across the O changes (srcT ≈ 30–90 s) | **0 events, 0 short reads, 0 resyncs** | 0 underruns, 0 short |
  | start: the first anchor plus the harness's 6 coarse re-anchors (3–5 s jumps, §19.10's open observation) | **1 event at the first anchor** (1 callback, 200 ms), then 12 cursor resyncs | **15 underrun callbacks**, 1 resync |
  | the 1000 ms stall | 36 short reads (no audio was sent), 0 events, 6 resyncs | 41 short, 5 resyncs |

  - The first-anchor event is the card's first read before that time's audio had arrived. It was not
    present pre-fix, which instead underran 15 callbacks at the coarse re-anchors that follow.
  - With the 4 s ring, the card finds audio at each jumped-to time and snaps rather than going silent.
    **Recorded as an observed improvement** (see "Decisions" below).
  - **The crossfade itself is not observable from the counters.** It is shown by "no hole at any of 16
    changes" and by the unit tests (`LiveReadOffsetFader`'s, in `swift test`), not by a capture.
- **Device-level A/V on SDI is DEFERRED** to the Release-build check on Robbie's Resolve workstation.
  Not measured here.

**Tests:** `swift test` **180 / 180**: 173 before, plus 7 in `FileAudioLookaheadTests`:
- the renderer's sequence is unchanged and the tap leads by the look-ahead;
- the tap stays ahead of a starving renderer;
- **seek retires the held look-ahead, and the new arm starts clean**;
- a decode in flight at the seek is not ingested, both in the renderer loop and in the look-ahead loop;
- end of file drains the held buffers;
- PCM duration.

**Builds:** Profile and Release with no errors, and no new warnings in the files touched.

**Not done:**
- the scrub frame at pts 0 on SDI (open, "check before release": see below);
- system-output capture with DeckLink off;
- device A/V on SDI (deferred);
- an AAC file on the libav path.

#### Decisions (Robbie, 2026-10-05) — recorded; no code changed

1. **The gap at a seek, scrub release or loop seam: ACCEPTED as designed behaviour.**
   - What it is: 20–140 ms of digital silence on SDI at the jump. MEASURED on the fixed build:
     - seeks while playing: 1–2 events per seek, 20–100 ms each;
     - a scrub release: 139 ms;
     - the loop seam: 109 ms.
   - It is the time from the jump to the new reader's first audio reaching the tap. The tap holds
     nothing from before the jump, so it is silence at the cut, not stale audio and not a dropout
     inside continuous programme.
   - The same as any player or NLE at a cut. Pre-fix the same gap was 1–2 s.
   - **Rejected: holding the card's audio position until the new reader has primed.**
     - The post-seek picture is already on SDI by then, so the audio after the cut would start late
       against it by the priming time (up to ~140 ms).
     - The anchor loop would then have to resync it back.
     - That trades a silence at the cut for an A/V error just after it, on a reference output.
   - **Rejected: delaying the post-seek SDI picture by the same amount.**
     - It adds up to ~140 ms of transport latency to the reference picture at every jump.
     - SDI would trail the desktop after each one.
     - That is new machinery and a slower reference output, to remove a silence every player has at a cut.
   - **Not relabelled either:** gating the card during the gap would print gate silence instead of
     underrun events, with the same zeros on the wire. The event counter therefore logs one line per
     jump, and that is expected.
2. **The pts-0 scrub frame on SDI: kept open as its own BUGS.md entry, "check before release".**
   - Separate from the gap.
   - The question, to answer read-only: is the frame's CONTENT wrong (a wrong picture briefly on SDI,
     a reference-output defect), or only its timestamp (harmless bookkeeping)?
3. **Live start-up: an observed improvement.**
   - In the local SRT session (`srt-fix-1` against `srt-pre-1`), the harness's start-up coarse
     re-anchors (3–5 s timebase jumps) used to leave the card reading outside the 2 s ring:
     **15 silent underrun callbacks** pre-fix.
   - With the 4 s ring the card finds audio at each jumped-to time and **snaps its cursor instead
     (12 resyncs)**, with no silence.
   - The one remaining event is the card's very first read at the first anchor (1 callback, 200 ms).

### 19.13 NDI reads sound ~70 ms early: one frame is the Stage D sender, ~27 ms is the depth term in the picture hold (H1 + H3; the device agrees) — 2026-10-05 evening (unattended, then one attended capture; no shipped code changed)

**The question (§19.10):**
- Stage D's SDK sender read heard A/V −67…−70 ms, though it was "in sync by construction".
- Item 1's OBS reading was confounded by the MP4 loop drift.
- Item 1's device capture read ~71 ms later than calibration.
- Where does the ~70 ms enter?

**Hypotheses (Robbie, written before the investigation):**
- **H1, sender artefact:** the sender's own stamps are ~70 ms apart.
- **H2, measurement only:** the heard figure mis-accounts the hold. What is heard is in sync, and
  the device reads ~0.
- **H3, real:** the hold is wrong, and the device reads the error.

**Which held, so far:**
- **H1 holds for one frame of Stage D's −70.** Stage D's sender submitted audio chunk k, then a
  *clocked* `send_video` of frame k. That call stamps on entry and then blocks a frame, so the video
  went out 41.7 ms after its audio.
- **The remaining ~27 ms (23.976; ~14 ms at 59.94) is a hold term.** The picture is held
  lead + mean `framesync_audio_queue_depth`. That depth overstates how much later the pulled audio is
  stamped than the video of the same instant.
- **H3, confirmed at the device** (step 4, 20:09). With the hold corrected, the device read
  **−0.67 ms** against a disk control in the same recording, and calibration read +2.55 ms. H2 is
  rejected: it predicted ≈ +27 ms. Item 1's 71 ms gap is not NDI's: it predicted ≥ +56 ms.

#### Setup

- **Sender:** `ndiclip` (scratch, NDI SDK). It plays the §19.11 loop-exact clips, decoded once to
  1280×720 UYVY and float PCM: 480 frames / 960 960 samples at 23.976, 960 / 768 768 at 59.94.
  Looped sample-exactly.
  - **paced:** its own mach deadline per frame. At t0 + k·T it submits audio chunk k (one chunk per
    frame), then video frame k. Explicit timecodes on one content axis (tc = content time).
    `clock_video` is off.
  - **legacy:** Stage D's order: audio chunk k, then the clocked `send_video`. Timecodes are
    synthesised by the SDK.
  - It logs every submission (mach), each flash frame's timecode, and each beep onset's timecode
    (found in the bytes it sends).
- **Manifold:** scratch build `wt-ndi/.build-cc/ndi1913-Profile` (HEAD `109cfc3`, Profile).
  - It logs every NDI pull to one trace on mach: video pull time, SDK timestamp and timecode, and
    the stamp Manifold gives the frame. Each audio pull's time, depth, want/got, SDK
    timestamp, timecode, and the PTS of its first sample.
  - `MANIFOLD_NDI_SOURCE` picks the sender by name. The OBS sender's NDI output stayed up and was
    not touched.
- **Runs:** one fresh launch per session, ⌃⌥N, 25 s, then two calibrations (Start → result →
  Cancel; nothing applied) by UI scripting. No `defaults` were written.
- **Logs:** `~/Desktop/manifold-soak/ndi1913/`: `<tag>.{sender.log,trace,manifold.log,driver.log}`,
  the patches, `ndiclip.cpp`, `ana1913.py` (the decomposition below), and the drivers.
- Audio Hijack was quit before the first launch (CLAUDE.md).
- ⚠️ The Stage D UI helpers addressed `window 1`. That is now macOS's `WindowSharingSessionButton`
  overlay, so the copy points at the standard window.

#### 1. The sender, proven from its own submission log

| | 23.976 (73 flashes) | 59.94 (94 flashes) |
|---|---|---|
| \|tc audio − tc video\| on each flash frame | **0.000 ms** | **≤ 0.017 ms** (800.8 samples a frame, rounded to a sample) |
| beep onset − flash, timecodes | +0.19 ms (the log's onset rule; the clip is exact, §19.11) | +0.19 ms |
| video submit − audio submit, flash frames | **≤ 0.11 ms** | **≤ 0.15 ms** |
| SDK timestamp as received, audio − video | −0.03 ms | −0.02 ms |

- **PASS:** in sync within 1 ms by its own stamps, at both rates.
  - Over all frames, 3 of 2197 (23.976) and 7 of 5631 (59.94) had a submission gap over 1 ms (worst
    2.7 ms). Those were wake jitter on non-event frames.
- **The legacy (Stage D) order is not provably in sync.**
  - Received video's SDK timestamp equals the *entry* to the clocked `send_video` (ts − entry 0.00 ms).
    The call then blocks 41.72 ms (median) before it returns.
  - So the timestamps say audio and video left together, while the video reached FrameSync a frame
    after its audio.
  - Its synthesised timecodes disagree with the content too (below).

#### 2. Manifold's figures on one timeline (paced sender, the shipped hold)

FrameSync passes the sender's timecode through on both pulls (audio: the first returned sample's). So
every pulled block's content time is known. Stamps are relative to the sender's t0, at which content 0
was submitted (≈ +3.9 / +2.5 ms submission latency).

| figure (median) | 23.976 (`p23-1`) | 59.94 (`p59-1`) |
|---|---|---|
| audio stamp − content | **+39.99** (p10–p90 0.6 ms) | **+30.16** |
| video stamp − content | **+11.66** (p10–p90 8.9: the 60 Hz pull tick) | **+9.72** |
| ⇒ audio stamped after video, same instant | **+28.33** | **+20.44** |
| FrameSync depth at pull | 56.5 (39.9…73.4) | 36.0 (29.3…42.7) |
| depth term in the hold (published) | **55.2** → hold 305.2 ms | **36.3** → hold 286.3 ms |
| calibration h (heard − clock) | **+55.24** (= the depth term) | **+34.28** |
| calibration b − f | +28.95 | +21.57 |
| heard per pair, b − f − h | −26.3 | −12.8 |
| **calibration RESULT** | **−25.57 / −28.42** | **−12.33 / −14.21** |
| `[AV-LAG]` audio−now / now−pts / tick→glass | +55.22 / +2.4 / +11.6 | +34.28 / +6.6 / +11.6 |

**Where the error enters:**
- **Not a sign error, and not a double count.**
  - h is the depth term exactly (+55.24 against 55.2 published). The audio timebase sits at
    now − lead, and the renderer clock at now − lead − depth.
  - So calibration subtracts exactly the hold the picture is given.
  - b − f from the calibration's own events equals the trace's stamp-axis figure within 1 ms.
- **Not "lead minus something".** The lead is exact on both sides.
- **It is the depth estimate.** The depth term should be the audio's stamp lag over the video's, which
  is +28.3 / +20.4 ms. Mean FrameSync depth reads +55.2 / +36.3. **The excess, 27 / 14 ms, is the
  heard error.**
- **Why depth overstates it:**
  - Audio arrives in chunks, one per frame from this sender. The newest queued sample is a whole
    chunk ahead of the moment it landed.
  - Stamp − content = depth + (arrival latency) − T_chunk / 2, on average over the pulls.
  - 23.976: 56.5 + 3.9 − 20.9 = 39.5 against 40.0 measured. 59.94: 36.0 + 2.5 − 8.3 = 30.2 against
    30.2.
  - The picture also waits for the next display tick (+7.7 / +7.2 ms over its submission). Depth
    cannot see that.
  - Both terms depend on the sender: its chunk size and its timing. So no constant can correct them.
- **Stage D's −70, decomposed** (`l23-1`, the legacy order, this clip):
  - calibration −69.17 / −69.13, so Stage D reproduces;
  - b − f −10.5 against the paced +29.0: **−40 ms from the sender's clocked-video order (H1)**;
  - **−27 ms from the depth term**, as on the paced sender.

#### 3. The scratch fix: the hold by the sender's timecodes

- **The term:** `mean(audio PTS − tc) − mean(video PTS − tc)`, read from the first returned sample of
  every audio pull and every new video frame.
  - Each mean is an EMA, τ 10 s. It publishes after 1 s on each stream, then on a ≥ 2 ms move.
  - It replaces the depth term in `PullSourcePictureDelay`.
  - The sender's clock and its offset from mach cancel in the difference, so this is NDI's own
    per-frame timecode, used as the standard defines it. Nothing branches on the sender.
  - Undefined timecodes (FrameSync manufactures audio with tc = INT64_MAX at start-up) fall back to
    the depth term.
  - `MANIFOLD_NDI_HOLD=depth` gives the shipped hold in the same binary.
- **Pass: calibration within ±1 frame of 0 on the in-sync sender, at both rates, over ≥ 3
  reconnects.**

| session | hold term (skew / depth it replaced) | RESULT 1, 2 (ms) | per-pair median |
|---|---|---|---|
| f23-1 | 29.6 / 57.5 | **+0.17, −2.16** | −0.99 |
| f23-2 | 30.2 / 56.8 | **+1.03, −1.17** | −0.19 |
| f23-3 | 27.3 / 54.5 | **+1.92, −0.23** | +0.79 |
| f59-1 | 19.0 / 34.8 | **+0.11, +1.77** | +1.17 |
| f59-2 | 19.5 / 36.1 | **+3.29, +1.55** | +2.71 |
| f59-3 | 20.3 / 34.7 | **+1.77, +2.59** | +2.36 |

- **✅ All 12 within −2.2…+3.3 ms** (±1 frame is ±41.7 / ±16.7). The skew settles at 27–30 ms
  (23.976) and 19–20 ms (59.94). In each session it equals the trace's stamp-axis figure within 1–2 ms.
- **The legacy sender on the fix** (`fl23-1`) reads **−25.42 / −23.07**. That is now the sender's own
  statement: its synthesised timecodes put audio and video that far apart against what it sent. The
  calibration offer would correct it.
- **What the fix does not touch:**
  - SDI: the hold is zero while the card owns audio, unchanged. SDI still carries FrameSync's term,
    as BUGS.md records.
  - The pull size and the audio stamps.
- **Not measured:**
  - an OBS / DistroAV sender on the fix (it sends 1024-sample audio frames, so its depth excess
    should be smaller);
  - a sender with undefined timecodes (the fallback path).
- **Tests:** `swift test` 180 / 180 on the main tree, which is unchanged.

#### Why H2 and H3 are not separated in the app

- Every term of the heard figure is the term presentation uses:
  - b and f are the PTS the renderers schedule by;
  - h is the hold the renderer's clock applies (`[AV-LAG]` audio−now = the published term);
  - `[AV-LAG]` now−pts (+2…+7 ms) shows frames selected at their PTS on the held clock.
- The rest is the render path, which SRT validated against the device (§18.13, device − stream
  +1.6 / +4.9 ms).
- And 2026-09-28's change of the hold moved the device 1:1 (+38.6 → +1.3 ms for a ~40 ms depth term,
  BUGS.md).
- **That argues H3.** But item 1's device reading is ≥ 56 ms from calibration in the same session:
  - 71 ms as measured;
  - 56 or 115 if the MP4 loop drift stepped between the two readings, 13:13 → 13:17;
  - the drift cycle is +14.67 ×3 then −44.0, so no drift phase reaches 0.
- **Only the device can settle that**, so step 4 is the one capture below.

#### 4. The attended capture — run 2026-10-05 20:09 (Robbie) — ✅ H3: the device equals calibration

- **One recording, ~70 s, in one Manifold process and one recorder launch** (`capture1913.sh`):
  1. 35 s of NDI: the paced sender at 23.976, the fixed build, O = 0.
  2. Then NDI off and the 23.976 ProRes master from disk for 35 s: the chain's zero, in the same file.
     That removes the launch-to-launch drift of the zero (+2.5…+27.8 ms, §18.23–24) that confounded
     item 1.
- The script calibrates once before the recording, so the in-app figure is from the same session.
  The DEBUG `[AV-CONTENT]` probe logs every flash during it.
- **Analysis:** split at the logged switch; `c12.py` on the NDI part, and `c12.py --file` on the
  file part. Device = NDI − file.
- **Predictions (written before it runs):**
  - **H3, the fix is right:** device = in-app heard (≈ 0) within ±10 ms.
  - **H2, the 27 ms was measurement only:** device ≈ +27 ms (+17…+37), sound late. The fix would then
    make lip-sync worse by what it removed from the hold.
  - **Item 1's gap is real and NDI-wide:** device ≈ +56…+115 ms.

**Result.**
- **Files:** `~/Movies/2026-10-05 20-09-25.mov` (119 s, 60 fps) and
  `~/Music/Audio Hijack/20261005 2009 Recording.wav`.
- **The split, from the driver's marks:** NDI 2–69 s (`ndi1913/cap1-ndi.mov`) and disk 80–112 s
  (`cap1-file.mov`). The switch was at 71 s, and the file played from 78 s.
- **In-app, this session:** calibration +2.55 ms (last 10 of 15 pairs, p10 −2.22, p90 +4.94) at
  20:09:59, inside the recording. The hold term was the timecode skew, 27.2 ms (depth 56.5).

| segment | c12 (beeps / flashes / pairs, g_count) | median | mean over whole periods | sd |
|---|---|---|---|---|
| NDI, fixed build, O = 0 | 54 / 54 / 54 ✅ | +28.14 ms | +27.12 | 6.23 |
| disk control (the 23.976 ProRes master) | 25 / 25 / 25 ✅ | +28.81 ms | +28.04 | 5.21 |
| **device = NDI − control** | | **−0.67 ms** | **−0.92** | |

- c12's onset bias is in both figures and cancels.
- **Device − calibration: −3.2 ms. H3 holds (band ±10).**
  - What the app measures on NDI is what the listener hears.
  - The shipped depth term is a real lip-sync error: ~27 ms sound-early at 23.976, ~14 ms at 59.94,
    on an in-sync sender.
  - The timecode skew removes it.
- **H2 rejected** (predicted ≈ +27).
- **Item 1's "≥ 56 ms" was not NDI's:** this capture, on the same kind of chain, agrees with the
  app to 3 ms. What made item 1 disagree (the MP4 sender's drift beyond the model, OBS, or that
  session's control) is not re-examined here.
- **Housekeeping:**
  - The driver's `kill` missed the sender, so it was stopped by hand afterwards. Its submission
    log is therefore incomplete; the device result does not use it.
  - Audio Hijack and the recorder are as Robbie left them.

#### Not done

- ~~For Robbie's decision: the product change.~~ Decided and built the same night: see "Shipped" below.
- ~~An OBS → NDI run on the fix.~~ Done below, on a 60 fps OBS canvas.
- BUGS.md's NDI calibration entry: fixed (`a159fd3`).

#### Shipped: the NDI picture hold by the sender's timecodes — 2026-10-05 night (committed `a159fd3`)

**Decided (Robbie, 2026-10-05):**
- Hold the picture by the sender's own NDI timecodes on both streams: the mean of (audio PTS − tc)
  minus the mean of (video PTS − tc).
- Fall back to the FrameSync depth term when a sender leaves timecodes undefined.
- NDI calibration stays enabled (session-only).

**What was built (on `ec1b86e`):**

| part | where | rule |
|---|---|---|
| **one stream's mean** | `TimecodeOffsetMean` (DisplayProviders, `PullSourcePictureDelay.swift`) | (stamp − timecode). **The same rules as `AudioQueueDepthEstimate`, by reference to its constants:** a time-weighted mean over the first 1 s, then an EMA with τ 10 s; a reading after a gap > 1 s is skipped. **Plus one rule:** a reading > 200 ms from the running mean restarts the warm-up, so the timecode must keep time |
| **the basis** | `PictureHoldBasisEstimate` (same file) | **TIMECODE** while both streams have fed a warmed mean within the last 2 s; **DEPTH** otherwise, per stream and automatically. The skew republishes on a ≥ 2 ms move (the depth's hysteresis) and is clamped to 0…200 ms (the depth's range). A re-warm (a timecode restart on a loop) keeps the last skew |
| **the frames** | `NDIBridge` | `timecode` on `NDIVideoFrame` and `NDIAudioFrame` (the first returned sample's, as FrameSync hands it on) |
| **the feed** | `NDIService` | the display tick feeds each new frame's stamp and timecode; the audio pump feeds each block's first-sample stamp and timecode. Under `pictureDelayLock`, reset per session in `start(with:)` |
| **the hold** | `NDIService.applyPictureDelay` | lead + (the skew on TIMECODE, the depth on DEPTH). `PullSourcePictureDelay.seconds` is unchanged, so it is still **0 while DeckLink owns audio** |
| **the log** | `[NDI] picture hold basis this session: TIMECODE / DEPTH …` | Once a session, when the basis settles: the skew has published, or 3 s (warm-up + staleness) after the first hold term without it. Then `… switched to …` on every change. The `picture held` line names the term in use |

- **Why "keeps time" and not "is defined":**
  - A sender cannot send an undefined timecode. `INT64_MAX` on send means "synthesise".
  - The receive side's `INT64_MAX` appears only on audio FrameSync manufactures (start-up, sender
    gaps).
  - A sender that sends timecode **0**, measured: video arrives as 0 on every frame. FrameSync's
    audio arrives as the block's offset inside its chunk, 0…41.7 ms. Both are "defined", and
    neither means anything.
  - The keep-time rule catches both. Their (stamp − timecode) walks 1 s per second and trips the
    200 ms gate before the 1 s warm-up completes.
- **Scratch instrumentation:** none of it is in the shipped change. The scratch worktree is removed;
  its patch stays at `ndi1913/scratch-instrument-and-tcskew.patch`.
- **Test-only change to the scratch sender:** a timecode mode (`explicit` | `zero` | `zero-audio` |
  `zero-video`), so it can leave timecodes meaningless. Copies are in `~/Desktop/manifold-soak/ndihold/`.

**Verification.** Profile build `.build-cc/ndihold-Profile` (shipped code only, no errors, no new
warnings in touched files). The UI-scripted driver of §19.13. Logs:
`~/Desktop/manifold-soak/ndihold/`. No `defaults` were written.

| session | sender | basis logged | calibration RESULT 1, 2 (ms) | hold, settled |
|---|---|---|---|---|
| t23-1 | in sync, 23.976 | TIMECODE (once) | **−0.27, −2.63** | 250 + skew 28.8 |
| t23-2 | | TIMECODE | **+0.69, −1.01** | 250 + 30.8 |
| t23-3 | | TIMECODE | **−0.10, +1.93** | 250 + 27.8 |
| t59-1 | in sync, 59.94 | TIMECODE | **+2.47, +1.45** | 250 + 19.4 |
| t59-2 | | TIMECODE | **+0.99, −0.17** | 250 + 19.8 |
| t59-3 | | TIMECODE | **+0.46, +1.61** | 250 + 19.1 |
| z23-1 | timecode 0, both streams | **DEPTH** (once, at 3 s) | **−27.23, −25.93** | 250 + depth |
| z59-1 | timecode 0, both, 59.94 | **DEPTH** | **−14.64, −13.35** | 250 + depth |
| za23-1 | timecode 0, audio only | **DEPTH** | **−24.97, −27.36** | 250 + depth |

- **✅ In sync, both rates, 3 reconnects: 12 / 12 within −2.63…+2.47 ms** (±1 frame = ±41.7 /
  ±16.7). The scratch build read −2.2…+3.3.
- **✅ The fallback is today's behaviour.** On a sender whose timecodes keep no time, the shipped
  build's hold read −25.6 / −28.4 (23.976) and −12.3 / −14.2 (59.94), §19.13. The fallback reads
  −27.2 / −25.9 and −14.6 / −13.4. **Per stream:** one stream without timecodes is enough
  (−25.0 / −27.4).
- **The skew settles.** The first published value is the 1 s warm-up mean and caught FrameSync's
  start-up (11.4 … 50.9 ms in different sessions). The skew then walks to its level in 2 ms steps
  over ~10–20 s, as the depth did (§18.3: seven 2 ms steps). Calibration runs at ≥ 25 s, after it.
- **✅ DeckLink owning audio** (`dl23-1`, ⌃⌥O 20 s then ⌃⌥⇧O): on TIMECODE, the card taking audio
  gives `picture held 0.0 ms … (DeckLink owns audio — SDI unchanged, not held)`. Handing it back
  restores 280.6 ms (250 + skew). As before, §18.2.
- **✅ The replay gate against b35a810: 99 / 99 files byte-identical** (`cmp.sh` of §19.7, seven
  sessions plus synth).
- **✅ `swift test`: 187 / 187**, which is 180 + 7 new in `PullSourcePictureDelayTests`:
  - a timecoded sender holds by the skew after the warm-up;
  - undefined on audio, video or both keeps the depth;
  - constant timecodes keep the depth;
  - the fallback goes both ways, in `staleAfter`;
  - a timecode restart keeps the skew;
  - the clamp;
  - the offset mean warms like the depth.
  - **Checked for teeth:** with the 200 ms gate disabled, the constant-timecode and restart tests
    fail.

**OBS / DistroAV, the customer case** (Robbie's sender OBS, NDI output "MAC-STUDIO (OBS PGM)",
Media source `manifold-sync-23.976p-h264.mov` looping):
- ⚠️ **The stream is 60 fps.** NDI declares 60/1, and the sheet said "This stream is 60 fps … 59.94p is
  the nearest". So OBS's canvas is 60 fps and the 23.976 clip goes out with pulldown.

| reconnect | basis | calibration RESULT 1, 2 (p10…p90 of RESULT 1) | skew / depth it replaced |
|---|---|---|---|
| obs23-1 | **TIMECODE**, 0 switches | **+11.83, +11.53** (+6.0…+20.6) | 14.0 / 28.5 |
| obs23-2 | TIMECODE, 0 switches | **+13.24, +11.91** (+7.4…+19.1) | 13.1 / 29.9 |
| obs23-3 | TIMECODE, 0 switches | **−5.49, −2.31** (−10.5…+2.2) | 14.4 / 28.7 |

- **DistroAV sends timecodes, and they keep time.** TIMECODE on every reconnect, no switch. Its skew
  (13–14 ms) is half the depth (28.5–29.9). On the old hold the same sender would read ~15 ms lower.
- **Prediction (−45…0 ms, stable): ❌ in part.** Reconnect 3 is inside the band; 1 and 2 read +12 ms
  (sound late).
  - The reconnects spread 18.7 ms, about one 60 fps output frame.
  - Each run's own p10–p90 is 10–15 ms, against 4–7 ms on the SDK sender.
- **Likely, not tested:** the 60 fps canvas.
  - Each 23.976 flash lands on the next 60 fps output frame (0…16.7 ms late).
  - That phase walks 0.2 frame per 20.02 s loop (1201.2 output frames).
  - So a ~13 s calibration window reads a different grid phase each time: the "+20 ms grid" term of
    §18.3 and BUGS.md, now visible because nothing else in the path scatters.
  - A run with the OBS canvas at 23.976 would remove it. That is Robbie's call; OBS was not changed.

**OBS / DistroAV again, with OBS's output at 23.976** (Robbie set it; NDI declares 24000/1001, frame
41.719 ms; the same Media source and clip). Logs: `ndihold/obs2398-{1,2,3}.*`.

**Prediction (written before the run):**
- The spread across reconnects falls from ~19 ms to within ±5 ms.
- Each run's own scatter falls to ~4–7 ms, as on the SDK sender.
- The absolute value is OBS's own sender offset; no band is predicted for it.

| reconnect | basis | calibration RESULT 1, 2 (p10…p90) | hold (skew) / depth |
|---|---|---|---|
| obs2398-1 | **TIMECODE**, 0 switches | **−76.68** (−80.15…−74.45), **−77.81** (−80.33…−74.90) | 250 + 40.2 / 29.1 |
| obs2398-2 | TIMECODE, 0 switches | **−76.18** (−78.87…−73.73), **−75.53** (−78.74…−71.05) | 250 + 39.2 / 27.4 |
| obs2398-3 | TIMECODE, 0 switches | **−76.95** (−81.37…−73.23), **−77.54** (−79.66…−74.87) | 250 + 39.2 / 33.4 |

- **✅ Prediction met.**
  - All six readings fall in −75.53…−77.81 ms: **2.3 ms across reconnects** (±1.2), against 18.7
    on the 60 fps canvas.
  - Each run's own p10–p90 is **4.6–7.7 ms**, against 10–15 at 60 fps and 4–7 on the SDK sender.
  - So the 60 fps spread was the canvas grid, as suspected.
- **DistroAV sends timecodes that keep time at 23.976 too.** TIMECODE throughout, no switch.
- **The absolute: OBS → NDI reads sound ~77 ms early** (calibration would offer ≈ +77 ms,
  session-only on NDI). That is OBS's own sender offset as its timecodes state it.
  - Same sign as the constant −50.3 ms in OBS's own recording of this clip (§19.11), though not the
    same size.
  - Not investigated; no band was predicted.
- **⚠️ Here the skew (39–40 ms) is LARGER than the depth (27–33 ms).** At 60 fps it was the reverse
  (13–14 against 29).
  - Changing OBS's output rate moved DistroAV's audio-to-video timing by ~25 ms in the skew, and the
    heard figure by ~85 ms (+12 / −4 → −77).
  - On the old depth hold this sender would read ≈ −66 ms (the hold ~10 ms shorter).
  - Both are sender behaviour; nothing in Manifold changed between the two runs.
- **For the sheet** (BUGS.md, a small UI item; not built): the 60 fps run shows what a rate mismatch
  costs. When a stream's rate matches no clip exactly, the sheet should say so and recommend
  matching the sender's output to the clip's rate.

**A second sender: Omniscope over NDI** (2026-10-05, 21:37–21:46).
- **Setup:** OBS's NDI output off. Omniscope playing `manifold-sync-23.976p-h264.mov` on loop, its
  NDI output on at 23.976.
- **Manifold** connected by ⌃⌥N to the only source, "MAC-STUDIO (NobeOmniScope)", 1920×1080.
  Shipped build `.build-cc/ndihold-Profile` (`a159fd3`'s code).
- **Same protocol** as the OBS runs. Logs: `ndihold/omni-{1,2,3}.*`.

**Predictions (written before the run):**
- calibration completes and offers a value on every reconnect;
- the spread across reconnects is within ±5 ms, per-run scatter ~4–8 ms, whatever the basis;
- the absolute is Omniscope's own sender offset, no band;
- DEPTH is fine if its timecodes don't keep time.

| reconnect | frame (Manifold) | basis | held | calibration RESULT 1 (p10…p90, pairs) | RESULT 2 |
|---|---|---|---|---|---|
| omni-1 | 41.708 ms (23.976) | **TIMECODE**, 0 switches | skew **0.0 ms** (depth 34.1) | **−2.73** (−6.01…+0.52, 24) | **−1.30** (−28.46…+2.06, 13) |
| omni-2 | 41.708 ms | TIMECODE, 0 switches | skew **0.0 ms** (depth 33.7) | **−7.61** (−10.71…−3.06, 51) | **+1.31** (−0.50…+7.68, 11) |
| omni-3 | 41.708 ms | TIMECODE, 0 switches | skew **0.0 ms** (depth 34.2) | **−3.50** (−8.04…+0.11, 26) | **+3.13** (−0.51…+7.61, 10) |

**Which held:**
- **✅ Calibration completes and offers a value on every reconnect:** 6 / 6, none missed.
- **❌ Spread across reconnects within ±5 ms: just outside.** −7.61…+3.13 ms, a 10.7 ms range (±5.4).
- **Per-run scatter ~4–8 ms: 5 of 6.** p10–p90 6.5, 7.7, 8.2, 8.1 and 8.2 ms.
  - The exception is omni-1's second run: **30.5 ms** (p10 −28.46). One or more pairs ~25 ms early
    sat in its window, and the spread rule (under one frame, 41.7) still let it through.
- **Within every reconnect the second calibration reads later than the first** (+1.4, +8.9,
  +6.6 ms). The first runs also needed more pairs before offering (24 / 51 / 26 against 13 / 11 / 10).
  Observed only.
- **Absolute:** Omniscope reads close to in sync, −7.6…+3.1 ms (median of the six ≈ −2 ms). That is
  its own sender offset on this path.
- **Basis: TIMECODE**, so Omniscope's timecodes keep time. **⚠️ But the skew sat at the clamp, 0.0 ms,
  all session, every reconnect.**
  - Omniscope's timecodes state the audio stamped *earlier* than the picture of the same instant,
    by an amount the clamp hides. So the hold here is the lead alone.
  - The depth term would have held 34 ms more.
  - The unclamped value is not logged, so how far below 0 it sits is unknown.
  - **For Robbie:** whether the skew's lower clamp should stay at 0 (the depth's range) or follow a
    sender that says audio leads. Not investigated, as the brief says.
- **Stopped here, as briefed** (the spread is outside ±5 ms). Not investigated further.

**Follow-up (2026-10-05 late): the negative skew, and the within-session settling.**

*1. The clamp (Robbie's decision: the skew may be negative down to −100 ms; +200 stays).*
- **Built (uncommitted):**
  - `PictureHoldBasisEstimate.skewFloor = −0.100`, `skewCeiling = 0.200`. `rawSkew` keeps the
    unclamped value, current even while a bound is in force, and `clamp` names the bound.
  - A change of clamp state counts as a change.
  - `PullSourcePictureDelay.seconds(desktopAudioLead:timecodeSkew:cardOwnsAudio:)`: lead + skew, never
    below 0, 0 while the card owns audio. The depth keeps `seconds(…frameSyncAudioDepth:…)` and its
    0…200 ms.
  - Log: the basis line carries `raw …` and `CLAMPED at the floor/ceiling`. A separate
    `[NDI] timecode skew CLAMPED at … / back inside its bounds` line logs on each change of clamp
    state.
- **Tests:**
  - `testANegativeSkewIsHeld`: −28 ms held as is, hold = lead + skew; the depth still floors at 0.
  - `testTheSkewIsClampedToItsBounds`: floor, ceiling, raw kept, leaving a bound reported. It caught
    a stale `rawSkew` while clamped; fixed.
  - `swift test` **188 / 188**. Replays against b35a810 **99 / 99 identical**. Profile build
    `.build-cc/ndihold2-Profile`, clean.

*2. The settling, read-only (`settle.py` over every session's DEBUG `[AV-CONTENT]` pairs; heard =
beep − (flash + audio−now), calibration's formula).*
- **Second calibration against the first:**
  - On the SDK sender (`p`, `f`, `t`, `z`; 14 sessions) and OBS at 23.976 (3), the second reads
    **−2.9…+2.0 ms** from the first, mixed in sign.
  - The first runs needed 10–16 pairs.
  - **Not "later every time".** Only Omniscope showed it (+1.4, +8.9, +6.6; 24 / 51 / 26 pairs).
- **Over the session, by 15 s bins:**
  - **A small start-up effect, common to every sender on the TIMECODE basis.** The first published
    skew is the 1 s warm-up mean; the hold then walks to its level in 2 ms steps.
    - That moves heard by **4–10 ms over the first ~20–50 s.** 23.976 `f23-1`: −9.0 → +2.8.
      `t23-2`: −5.8 → +3.3. 59.94 `f59-1`: +10.4 → +3.7. OBS `obs2398-2`: −67.3 → −73.5.
    - It is in hand by the ~40 s calibration start, with exceptions: the hold still stepped at
      53 s (`obs2398-1`) and 71 s (`obs2398-2`), by 2 ms.
    - On the DEPTH basis (`z23-1`) heard is flat from the start, ±0.8 ms.
  - **Omniscope: a different, larger thing.** Steps of **25–35 ms**: `omni-2` +28…+32 for 30 s, then
    −6; `omni-3` +11…+23 for 60 s, then 0.
    - In the longer runs below it keeps wandering **±20 ms for the whole 3–4 min**, in steps. The
      hold is constant all the while.
    - It is not start-up and not the hold: it is on Omniscope's path. Not investigated.

*3. Omniscope again, on the new clamp* (`ndihold/omniB-{1,2,3}`, 3 reconnects, two calibrations,
then a 90 s tail).

| reconnect | basis | raw skew | held | calibration RESULT 1 (p10…p90, pairs) | RESULT 2 |
|---|---|---|---|---|---|
| omniB-1 | TIMECODE | **−1 791 251 394.7 s** | −100.0 ms (floor) | **+137.87** (+134.04…+142.94, 47) | **+115.33** (+110.35…+122.01, 20) |
| omniB-2 | TIMECODE | **−1 791 251 639.9 s** | −100.0 ms (floor) | **+94.21** (+91.04…+96.62, 44) | **+101.31** (+99.33…+105.55, 39) |
| omniB-3 | TIMECODE | **−1 791 251 884.7 s** | −100.0 ms (floor) | **+129.70** (+126.61…+132.73, 26) | **+108.93** (+103.74…+113.18, 23) |

- **Omniscope's two streams carry timecodes on different clocks.**
  - Each keeps time on its own, so the basis is TIMECODE.
  - Their difference is −1.79 × 10⁹ s and grows with wall time between reconnects (+245 s each):
    one stream is stamped on a Unix-epoch clock and the other near zero.
  - The skew between them is meaningless.
- **On the 0 floor (`a159fd3`) that was hidden.** The skew sat at 0 and the hold was the lead alone,
  which reads near sync (−7.6…+3.1). On −100 ms the picture is held 150 ms and sound reads
  **~+94…+138 ms late**. Calibration offers −94…−138, "not applicable" past the queue.
- **Neither floor is following Omniscope's timecodes.** Both are a fixed number standing in for a
  relation the sender never stated.

**Which held:**
- **❌ Raw skew −5…0 ms:** it is −1.79 × 10⁹ s: no common clock.
- **❌ The spread tightens to ±5 ms:** +94.2…+137.9 ms. Worse, and wandering within each session as
  above.
- **❌ The settling is common to all senders:**
  - What is common is small: the hold's 2 ms-step settle, 4–10 ms over ≤ 50 s, mostly before the
    calibration starts.
  - The second-reads-later pattern and Omniscope's 25–35 ms steps belong to Omniscope alone, and do
    not settle.

**Proposed (not built) — for Robbie:**
1. **A skew past a bound is not a sender stamping audio ahead: it is two clocks.**
   - Recommend: past a plausibility bound the basis falls back to DEPTH and says so, instead of
     clamping. For example |raw| > 1 s, or simply outside −100…+200.
   - "The streams' timecodes are not on one clock" joins "a stream's timecode does not keep time" as
     a fallback reason.
   - It is the rule already applied per stream, extended to the pair. It needs no special case for
     any sender.
   - **Until decided, the uncommitted −100 floor makes Omniscope read ~+100 ms late, against ~0 on
     `a159fd3`.** It should not be committed as is.
2. **Calibration and the start-up settle:**
   - Calibration starts ≥ 40 s after connect in these runs, and a user's run starts later still. The
     common settle is ≤ 10 ms and mostly over by then. A minimum time since connect is therefore not
     needed for it.
   - The cheaper guard: offer no figure while the hold has moved in the last 10 s. The walk guard
     already covers a slope; a 2 ms step is below it.
   - Optional, and only if Robbie wants it.


**Decided and built (Robbie, 2026-10-05 late; uncommitted): the clamp is replaced by a fallback.**
- **The rule:** a skew inside −100…+200 ms is used as is. Outside, the two streams' timecodes are NOT
  on one clock, and the session falls back to the depth for good:
  - `PictureHoldBasisEstimate.notOnOneClock` latches;
  - `rawSkew` keeps the value that showed it;
  - the log reads `picture hold basis this session: DEPTH: timecodes not on one clock (raw skew …,
    outside −100…+200 ms) — FrameSync's depth for this session`.
- **No extra calibration wait** (Robbie).
- **The clamp, its state and its log line are gone.** The negative-skew hold
  (`seconds(…timecodeSkew:…)`) stays.
- **Tests:**
  - a skew just inside the floor (−95 ms) is used as is;
  - outside either bound falls back;
  - **two streams on different clocks** (audio on a Unix-epoch clock, video near zero) never hold
    by the skew;
  - the fallback is latched for the session (a fresh one re-evaluates);
  - the negative-skew test is kept.
  - `PullSourcePictureDelayTests` 24 / 24. **`swift test` 191 / 191.** Replays against b35a810
    **99 / 99 identical**. Profile `.build-cc/ndihold3-Profile`, clean.

**Omniscope, two sets of 3 reconnects** (two calibrations each, then a 90 s tail;
`ndihold/omniC-*` with Clocked video output ON, `omniD-*` with it OFF, set by Robbie).

**Predictions (written before the run):**
- DEPTH in both sets, "not on one clock".
- (a) ON: the ±20 ms wander and the later-second-reading pattern remain.
- (b) OFF: the wander drops to the ~4–8 ms per-run scatter of the other senders, and the spread
  across reconnects falls within ±5 ms.

| set | reconnect | basis, why | held | RESULT 1 (p10…p90; pairs) | RESULT 2 (p10…p90; pairs) | heard, 15 s bins, ~3–3.5 min |
|---|---|---|---|---|---|---|
| (a) ON | omniC-1 | DEPTH: not on one clock, raw −1 791 252 431.9 s | 250 + 33.3 | **−91.08** (−94.12…−87.68; 62) | **−85.96** (−90.04…−83.47; 12) | −59.9…−95.0 |
| | omniC-2 | DEPTH: same, raw −1 791 252 657.5 s | 250 + 32.9 | **−77.03** (−104.89…−73.72; 31) | **−84.34** (−86.87…−81.07; 41) | −66.6…−96.4 |
| | omniC-3 | DEPTH: same, raw −1 791 252 902.8 s | 250 + 31.7 | **−101.20** (−104.50…−93.31; 18) | **−84.65** (−90.33…−80.39; 10) | −67.5…−108.6 |
| (b) OFF | omniD-1 | DEPTH: not on one clock, raw **−2 068.6 s** | 250 + 35.0 | **+1.35** (−11.27…+6.60; 14) | **−5.73** (−12.11…−0.40; 27) | −14.9…+6.9 |
| | omniD-2 | DEPTH: same, raw −2 268.8 s | 250 + 32.4 | **−10.46** (−16.33…−0.11; 10) | **+1.88** (−13.81…+5.82; 19) | −11.2…+20.7 |
| | omniD-3 | DEPTH: same, raw −2 470.2 s | 250 + 31.7 | **+12.91** (+5.16…+16.52; 34) | **−4.72** (−8.25…+1.75; 22) | −5.8…+15.9 |

**Which held:**
- **✅ DEPTH in both sets, "not on one clock", on all six reconnects.** The new rule does what it says.
  - Clocked ON: the raw skew is epoch-scale, as before.
  - Clocked OFF it is −2 069 … −2 470 s. That is still two clocks, growing ~200 s a reconnect with the
    wall time.
- **(a) ON: the wander remains ✅; the later-second pattern ❌.**
  - Over a session heard spans 35–41 ms in 15 s bins: ±20 ms and more.
  - The second calibration was +5.1, −7.3 and +16.6 ms from the first: mixed. First runs needed
    62 / 31 / 18 pairs.
- **(b) OFF: ❌ on both counts.**
  - The wander does not drop to 4–8 ms: 15 s bins span 21.8 / 31.9 / 21.7 ms. Per-run p10–p90 is
    10.0–19.6 ms.
  - The spread across reconnects is −10.46…+12.91 ms, 23.4 ms (±11.7): not within ±5.
- **What did change with Clocked OFF is the absolute:**
  - ON reads ~−85 ms (sound early), OFF ~0 (median of the six ≈ −1.7 ms), both on the same depth
    hold (31.7–35.0 ms).
  - That ~85 ms is Omniscope's own output timing.
- ⚠️ **The ON absolute also differs from the earlier runs.**
  - `omni-*` read ~0 on the lead-only hold (the old 0 clamp). Adding the 33 ms depth should give
    ≈ −33; this set reads ≈ −85.
  - So Omniscope's own offset moved by ~50 ms between those runs and this set, in the same
    "Clocked ON" mode.
  - Not investigated.
- **Reading:**
  - Manifold's side behaves the same on Omniscope as on the SDK and OBS senders: the depth hold, flat
    start-up on DEPTH.
  - Omniscope's NDI output wanders ±10–20 ms within a session in either mode.
  - Its absolute offset depends on its clocking mode and has moved between launches.
  - Calibration on Omniscope therefore gives a value good to about ±10–20 ms at best, and only for
    that session. The NDI "session only" rule already covers that.

### 19.14 Cloudflare on the loop-exact clip: WHEP per connection, SRT sound late, and the 90-minute SRT hold (§19.8 D2/D3/D5) — 2026-10-06 (unattended after set-up; no app code changed)

**The question:**
- §19.10 item 3's Cloudflare readings used the drifting MP4 clip. Re-run D3 (WHEP) and D2 (SRT) on
  the loop-exact `.mov` (§19.11).
- Then D5: does one SRT calibration hold for 90 minutes? §19.5's ❌ row had never been measured.

**Predictions (Robbie, written before the runs):**
- **WHEP:** the spread across reconnects is within ±5 ms. The value is OBS's own WHIP sender offset
  (no band).
- **SRT:** sound is heard 70–80 ms EARLIER than on WHEP from the same stream (Cloudflare's SRT output,
  §18.13). The spread across reconnects is within ±10 ms (its offset varied by session before).
- **Both re-checks after applying:** within ±2 ms of 0.
- **The hold:** within ±10 ms of the +0 reading at +90 means one calibration holds for a session.
  Beyond that, the guide's "recalibrate every 20–30 minutes, or use WHEP" stands. §19.5 predicted a
  walk of 0 to −157 ms over 90 min.

**Sign convention:** the calibration sheet's. Heard A/V **+** = sound heard **late**, and the
proposal is its negative. **−** = sound heard **early**.

**Which held:**

| prediction | measured | |
|---|---|---|
| WHEP spread across reconnects within ±5 ms | **42.2 ms** between connection means (−35.6 / +6.6 / −0.9); 44.6 ms over all six readings | ❌ |
| WHEP value = OBS's sender offset, one value | It varies by connection. Each connection's value equals Manifold's SR-line offset at the time of calibration plus a constant **−4.8 ms** (range 0.8 ms; below) | ❌ as a single value |
| SRT sound 70–80 ms earlier than on WHEP | Sound **late** on SRT, **+41 ms**; about 40 ms LATER than WHEP connections 2–3 | ❌ opposite sign |
| SRT spread across reconnects within ±10 ms | **5.7 ms** over all seven readings (+37.7…+43.4); 3.6 ms over the six measure-only ones | ✅ |
| WHEP re-check within ±2 ms | **−2.50 ms** | ❌ by 0.5 ms |
| SRT re-check within ±2 ms | not run: "NOT APPLICABLE", 0.0 ms of advance available on every reading | — |
| hold within ±10 ms of +0 at +90 | **+41.27 → +0.54 ms: −40.7 ms**. One step of −44.3 ms between +30 and +60; flat within 3 ms on either side | ❌ |

#### Setup

- **Build:** Profile from HEAD `dff06a0`, `.build-cc/cf-Profile`. It was built from a clean tree after
  `xcodegen generate` (project.yml was newer than the generated project). Unsigned.
- **The sender:** OBS, scene SYNC, the Media Source looping `manifold-sync-23.976p-h264.mov` (§19.11),
  output 23.976. NDI output off.
  - WHEP legs: the Cloudflare WHIP profile.
  - SRT legs: the Cloudflare SRT profile, the same scene and clip (see "SRT from a WHIP ingest" below).
- **Manifold:** one fresh launch per connection, on the saved streams "DC Color Live - WHEP" and
  "DC Color Live  - SRT".
  - Each connect logged `[AUDIO-OFFSET] connect … session value 0 ms (from the saved stream's setting)`.
  - Calibrations ran by UI scripting (§19.13's helpers): Calibrate… ▸ Start ▸ RESULT ▸ Cancel.
    Apply for Session only. Never Save, so no `defaults` were written.
- **Settle before the first calibration:**
  - WHEP: at least 240 s connected AND a `[WHEP-SRFIT]` window with the slope IN USE, per §19.10 item
    3's addendum. All three settled at +242…+243 s.
  - SRT: 60 s.
- **Keychain:** the licence prompt was denied by script, and only that prompt (the helper matches the
  prompt's text). Robbie allowed the SRT passphrase prompt once with Always Allow before the run.
- **Logs:** `~/Desktop/manifold-soak/cf1914/`: `<whep|srt>-<n>.manifold.log`, `run.driver.log`,
  `preflight.*`, and `srt-0-whip-ingest-nobytes.manifold.log`. The drivers are in the session
  scratchpad (`run1914*.sh`, `lib.sh`).
- ⚠️ **Driver bug, caught live:** `ensure_window` assigned a global `n`, which overwrote the connection
  number inside the driver. Every WHEP connection was labelled "1" in `run.driver.log`, and the Apply on
  the third would have been skipped.
  - The driver was stopped during WHEP-3's second calibration. Manifold kept running, and a fixed driver
    resumed it. The log file names were always right.
  - No calibration was lost or repeated. `run.driver.log` marks the restart.

#### 1. WHEP — three connections (12:03–12:20)

| connection | connected | cal 1 heard (p10…p90) | cal 2 heard (p10…p90) | first SR-line offset (session start) | SR-line offset at cal 1 (window, video t = 251 s) | heard₁ + offset at cal 1 |
|---|---|---|---|---|---|---|
| 1 | 12:03:53 | **−34.50** (−35.66…−33.44) | **−36.75** (−37.58…−34.93) | +4.211 | +29.331 | −5.17 |
| 2 | 12:09:12 | **+7.83** (+5.81…+8.75) | **+5.33** (+4.71…+6.73) | −26.597 | −12.226 | −4.40 |
| 3 | 12:14:32 | **+0.08** (−0.88…+0.69) | **−1.79** (−3.10…−0.79) | −12.225 | −4.785 | −4.71 |

(ms; 10 pairs each; each connection's slope +62…+80 ppm IN USE at the time of calibration.)

- **Within a connection the two readings agree within 2.5 ms. Across connections the means span 42.2 ms.**
  - Connection 1: sound **heard ~35 ms early**.
  - Connections 2 and 3: within ±8 ms of 0.
  - This is not §19.10's early-settle wander: every calibration came at +4 min, with the slope in use.
- **Apply on connection 3** (a third calibration, 12:19:52): heard −4.38 → proposed **+4 ms**, Apply for
  Session. One splice, INSERT 192 fr / 4.0 ms, "line moved −4.0 ms with it".
- **Re-check, 12:20:10:** heard **−2.50 ms** (p10…p90 −3.29…−1.93), "Sound is heard 2 ms early",
  proposed +6. ❌ ±2 by 0.5 ms.
- No starvation hold, recovery drop or cut on any WHEP connection.

**The per-connection difference against the SR-line offset (Robbie's read-only check, as in the MediaMTX
`whepx`/`srabs` sessions, §19.10):**
- **Against the offset at session start (the FIRST LINE): ❌.**
  - heard₁ + first offset = −30.29 / −18.77 / −12.15 ms, an 18.1 ms range.
  - Between connections: heard moved +42.33 and +34.58 ms (1→2, 1→3). The first offset moved −30.81 and
    −16.44, and its negatives (+30.81, +16.44) miss the heard differences by 11.5 and 18.1 ms.
- **Against the offset in use when calibration ran: ✅, within 0.8 ms.**
  - heard₁ + offset at cal 1 = −5.17 / −4.40 / −4.71 ms.
  - Between connections: heard +42.33 / +34.58 ms; −Δoffset +41.56 / +34.12 ms.
- **Why the two differ on Cloudflare and did not on MediaMTX:**
  - MediaMTX's calibrations ran ~10 s after connect, while the first line was still the line in use.
  - Here the line moved +25.1 / +14.4 / +7.4 ms between the first SR pair and t = 251 s. That is the
    window offset ramp §19.10's addendum saw, as the slope comes into use.
- ⚠️ **Superseded by §19.15 §3.** Calibration's figure on WHEP omits the SR-line offset Manifold
  applies: it reads what is heard − offset(t). What was heard was ≈ −4.8 ms on all three connections,
  and the per-connection spread is in the reading. The reading below is kept as written.
- **What it says:**
  - As on MediaMTX, what differs between Cloudflare WHEP connections is the audio↔video relation
    Manifold's SR line states, not the content.
  - The content relation through Cloudflare WHEP was the same on all three connections: **≈ −4.8 ms**
    (sound ~5 ms early) once the line is subtracted.
  - Whether the SRs or Manifold's fit makes the per-connection offset is not separated (the open
    MediaMTX item; it needs a second WHEP client).
  - Not investigated further, per the brief.

#### 2. SRT from a WHIP ingest: no data (12:20–12:21)

- The brief had SRT read "the same OBS stream", still published over WHIP.
- Cloudflare's SRT output accepted the encrypted connection and sent **0 bytes in 32 s**, then closed
  it: `connection lost … end of stream`, then "Couldn't identify the stream's contents".
- Every Cloudflare SRT session on record (§18.10–§18.13, §19.10 item 3) published over SRT.
- **Inference, not checked against Cloudflare's documentation:** Cloudflare does not serve a
  WHIP-published live input on its SRT output.
- Robbie switched OBS to the Cloudflare SRT profile (same scene, clip and 23.976) at ~13:15. So WHEP and
  SRT here are two ingests from the same OBS and clip about an hour apart, not one stream read two ways.
- Kept as `srt-0-whip-ingest-nobytes.manifold.log`.

#### 3. SRT — three connections (13:17–13:25)

| connection | cal 1 heard (p10…p90; pairs) | cal 2 heard (p10…p90; pairs) | proposal |
|---|---|---|---|
| 1 | **+39.79** (+38.65…+40.35; 10) | **+41.34** (+39.57…+42.57; 10) | −40 / −41 · NOT APPLICABLE, 0.0 ms available |
| 2 | **+42.17** (+40.42…+42.76; 10) | **+41.35** (+40.76…+41.87; 10) | −42 / −41 · NOT APPLICABLE, 0.0 ms |
| 3 | **+41.45** (+40.86…+43.71; 10) | **+43.42** (+41.93…+44.39; 16) | −41 / −43 · NOT APPLICABLE, 0.0 ms |
| 3, for Apply | **+37.73** (+36.63…+39.22; 14) | — | −38 · NOT APPLICABLE, 0.0 ms: **nothing applied** |

- **Sound heard ~41 ms LATE**, steady across reconnects: seven readings within 5.7 ms.
- **Against §18.13's "~70–80 ms early": ❌, the second session in a row.** §19.10 item 3 (10-05, on the
  drifting MP4) also read late: +26.75 on its first reading.
- **Against WHEP:** sound is about 40 ms later on SRT than on WHEP connections 2–3, and ~77 ms later
  than WHEP connection 1. The prediction was 70–80 ms *earlier*.
- **No Apply was possible**, so there was no re-check.
  - A sound-late result needs an advance, and on this path the renderer queue never has the 160 ms
    keep + fade + margin plus the advance (§19.10 item 3).
  - Every reading said "at most 0.0 ms available".
- **One starvation hold on connection 3:** 13:24:20, "no input for 196 ms". It held 66 ms, then
  `RECOVERY DROP #1 (WHOLE DEBT)` 58.5 of 58.5 ms, "RECOVERED 0.3 s after".
  - It fell inside cal 1's window, which still read +41.45 with p10…p90 2.9 ms.
  - No other hold on SRT connections 1–2.

#### 4. The 90-minute hold on SRT connection 3 (13:25–14:56)

- **The brief's condition could not be met:** no value could be applied (§3). The hold ran at O = 0 ms,
  the saved value, on the same connection with no reconnect.
- So it measures the walk of Cloudflare SRT's own offset over 90 min, which is the quantity §19.5's ❌ row
  is about. It does not test an applied value.

| reading | time | heard A/V (p10…p90; pairs) | − (+0) | sheet |
|---|---|---|---|---|
| +0 | 13:25:48 | **+41.27** (+38.96…+43.10; 10) | — | sound 41 ms late · NOT APPLICABLE, 0.0 ms |
| +30 | 13:55:50 | **+44.19** (+41.93…+46.10; 10) | +2.92 | sound 44 ms late · NOT APPLICABLE, 0.0 ms |
| +60 | 14:25:55 | **−0.14** (−1.95…+1.23; 10) | **−41.41** | in sync, nothing to apply |
| +90 | 14:56:04 | **+0.54** (−0.34…+1.61; 16) | **−40.73** | proposed −1 · NOT APPLICABLE, 0.0 ms |

(ms; O = 0 throughout; Cancel each time.)

**Starvation holds over the session:** 9, every one "no input for" 45–239 ms at a renderer queue of
~19.5 ms, except #4.
- **#4–#5, 14:04:20–22: a 1.48 s input gap**, then 81 ms more. `⏩ STARVATION CATCH-UP` put the whole
  1 547.9 ms debt onto the line in one timebase write, RECOVERED. `timebase−clock` was back within
  ±3.5 ms a second later.
- **The other seven:** `RECOVERY DROP (WHOLE DEBT)` each, RECOVERED 0.3 s after. One exception: #3
  (14:02:11) dropped 36.7 of 39.5 ms owed, 2.8 ms short.
- Five of the nine fell at hh:m4:20 (13:24:20, 13:34:20, 14:04:20, 14:44:20, 14:54:20). Noted, not
  investigated.
- The 1.48 s gap is the only large event in the log between +30 and +60. Calibration readings alone
  cannot say whether the −44 ms step happened at it.
- **Not investigated**, per the brief ("record the measured figure").

**Reading:**
- **One calibration does not hold for a session on Cloudflare SRT. ❌, by four times the band.**
- **The way it failed differs from §19.5's model.** It was not a slope: +2.9 ms over the first 30 min,
  then +0.7 ms over the last 30 min.
- **It was one step of −44 ms (sound ~44 ms earlier), in a span that had a 1.48 s input gap.**
  - Before the step: sound ~41–44 ms late, not correctable here.
  - After it: in sync.
  - Had a +41 ms correction been applicable and applied at +0, sound would have read ~44 ms early
    after the step.
- **§19.5's predicted walk was 0 to −157 ms over 90 min.** −40.7 ms is inside that range in size and
  sign, but as a step, not a slope.
- **Sign, plainly:** sound was heard **late** by ~41 ms for the first ~40–60 min. It ended **in sync**
  (within 1 ms).

#### What changes

- **User guide (`USER_GUIDE_SYNC.md`):**
  - The Cloudflare SRT lines now say the offset has gone both ways between sessions. Sound late, the
    case measured in the last two sessions, cannot be corrected from Manifold on this path.
  - "Recalibrate every 20–30 minutes, or use WHEP" stands. It now names a step, not only a slow drift.
  - Cloudflare WHEP: the reading can differ by connection (tens of ms). Calibrate after each connect, a
    few minutes in, and apply it for the session rather than saving it.
  - The editor notes record what was measured here.
- **For Robbie, not decided here:**
  - WHEP's per-connection SR-line offset now has two servers. Whether it is the servers' SRs or
    Manifold's fit stays open. A browser WHEP read of one Cloudflare connection would split it, as
    planned for MediaMTX.
  - Until then, Save on a WHEP bookmark stores a value that is right only for the connection it was
    measured on.
  - Calibration on WHEP is better read after the slope is in use (~4 min), as done here: the line still
    moves 7–25 ms in the first minutes.
- No app code changed. No `defaults` were written.

### 19.15 One start-up root cause behind the Cloudflare SRT step and the WHEP per-connection offsets? — ❌ no: SRT's 41 ms is in the received timestamps, and on WHEP calibration omits the SR-line offset Manifold applies — 2026-10-06 evening (read-only; one local run; no code changed)

**Hypothesis (Robbie, 2026-10-06):** one root cause behind three findings. Manifold's audio/video
alignment at the START of a network session is off by a session-dependent amount, and it becomes
correct only when the alignment is re-established later.
- **Cloudflare SRT (§19.14):** sound +41 ms late from connect. Within 1 ms of sync after the catch-up
  write at 14:04, which followed a 1.48 s input gap.
- **Cloudflare WHEP (§19.14) and MediaMTX WHEP (§19.10):** per-connection offsets that equal
  Manifold's SR-line offset in use, while the content relation is constant.

**Predictions (Robbie, written before the investigation):**
- The SRT first anchor and the catch-up anchor use different rules or different reference points.
  Their difference ≈ the 41 ms step.
- The WHEP line's early movement is Manifold's fit converging from too few SR pairs, not the SRs
  changing.
- Local SRT (item 4): the start is already correct, so a forced catch-up re-anchor makes no step.

**Which held:**

| prediction | measured | |
|---|---|---|
| SRT first anchor and catch-up differ by ≈ 41 ms | **Same rule, same reference, 0 ms apart.** Both put the audio's own PTS on LiveClock's line at offset +0.000. `heard − clock` was −3.1…+3.3 ms before 14:04 and −1.2…−0.5 after. The 41 ms and its step are in the RECEIVED timestamps: beep PTS − flash PTS +40.7…+41.0 → −0.8 ms | ❌ |
| SRT connections 1–2: first anchor off by the same rule | All three anchored identically (offset +0.000). On each, the 41 ms is in the received PTS (+40.7…+41.0), not in the alignment (−1.5…+1.4) | ❌ (no anchor error to repeat) |
| WHEP line's early move = fit converging, not the SRs changing | **Mostly the SRs.** Video RTP runs +61…+62 ppm on NTP (OBS 23.976, §18.25), so the pair offset genuinely ramps ~17–19 ms over 251 s. First-pair noise adds −9.3…+6.0 ms on top | ❌ (~¾ real ramp, ~¼ first-pair noise) |
| Local SRT: no step at a forced catch-up | **+0.17 / +0.73 → +0.98 / +0.50 / +0.25 ms** around a 1 214.6 ms catch-up write | ✅ |

**What the WHEP finding actually is (not in the brief's hypotheses):**
- Calibration's figure on an RTP path omits the SR-line offset Manifold applies.
- Its reading = what is heard − offset(t). So the per-connection spread is in the reading, not in
  playback. Below, §3.

#### Method

Read-only on the §19.14 logs (`~/Desktop/manifold-soak/cf1914/`), plus one local run (item 4). Two
scratch scripts (session scratchpad), offline over the logs:
- **`split1915.py`** splits every calibration run into its two terms.
  - `[CALIBRATION] tone` is the beep's time on the AUDIO transport's axis (`CalibrationBeepTap` scans
    the transport's buffer before the resampler, `FrameEngine` sink `enqueue`).
  - `[CALIBRATION] flash pts` is the video sender PTS (`LiveClock.registerFrame` returns `senderPTS`
    unchanged).
  - The flash line's `heard−clock` is `liveAudioHeardMinusClock`.
  - The calibration figure is `beep − flash − (heard − clock)`, last 10 pairs, median.
  - The split reproduces every §19.14 RESULT within 0.3 ms.
- **`srraw1915.py`** refits the raw SR pairs (`[WHEP-SR-RAW]`: audio and video SRs share each NTP
  instant). The per-pair offset relative to pair 0 is `Δa_rtp/48000 − Δv_rtp/90000`, and each RTP
  clock's rate is taken against NTP.

#### 1. Cloudflare SRT, connection 3: the first anchor and the 14:04 catch-up

**The first anchor** (13:22:56):
- **Video:** `[SRT] startup anchor: GAP` (waited 0.043 s; discarded 71 frames, net clock jump
  +2.802 s), then `queue-full re-anchor` (depth 0.334 → 0.250, +0.084 s).
- **Audio:** 142 AAC frames from before the video anchor were dropped. Then `timebase MIRRORED — first
  anchor: senderPTS=357.448s … offset=+0.000 ms (the transport's constant cushion) …
  timebase=357.448s`.
  - The audio PTS is the TS packet PTS × the stream time base, on the program's single 90 kHz clock.
    No origin is subtracted (`SRTFrameRouter` audio ingest).
  - The video PTS is the same clock, through `registerFrame` (an identity).
  - So audio at PTS p plays when the picture at PTS p is due, with no lead or cushion term.
- **The gate:** `first mapping +280 ms · first presentation +288 ms · anchor +310 ms · audio after
  picture 22 ms`. That is start-up timing, not an offset in the line.

**The 14:04 catch-up** (`⏩ STARVATION CATCH-UP … 1547.9 ms debt … ONE timebase write onto the line`):
- The same line, the same zero offset, after holds #4–#5.
- `[SRT-AUDIO] chain … timebase−clock` was −1408.3 ms before it and +0.9 ms one second after.

**Numerically, the difference between the two rules is 0 ms.** Calibration's two terms, every reading
on connection 3:

| reading | time | beep PTS − flash PTS (received) | heard − clock (Manifold's alignment) | figure |
|---|---|---|---|---|
| cal 1 | 13:24 | +41.03 | −0.60 | +41.6 |
| cal 2 | 13:24 | +40.95 | −2.35 | +43.3 |
| for Apply | 13:25 | +41.04 | +3.26 | +37.8 |
| hold +0 | 13:25 | +40.87 | −0.17 | +41.0 |
| hold +30 | 13:55 | +40.87 | −3.14 | +44.0 |
| **hold +60** | 14:25 | **−0.82** | −0.53 | −0.3 |
| **hold +90** | 14:56 | **−0.82** | −1.20 | +0.4 |

(ms, medians of the last 10 pairs.)

- **The 41 ms was in the timestamps Cloudflare delivered, and so was the step.**
  - Manifold's alignment stayed within ±3.3 ms throughout.
  - The step is −41.7 ms: **exactly one frame at 23.976** (41.71 ms).
- **The audio side is continuous.** Audio PTS − the decoded sample count stayed at 357 585.5 ±0.2 ms
  for the whole 93 min (5 515 `chain` lines). So the frame moved on the video side of the received
  stream, upstream of Manifold.
  - Whether OBS's SRT output or Cloudflare re-stamped is not separable from these logs.
  - Not investigated further.
- The hold's starvation events (§19.14 §4) are Manifold's and were all repaid. None moved `heard − clock`.

#### 2. SRT connections 1 and 2

| connection | first anchor | beep − flash (received) | heard − clock |
|---|---|---|---|
| 1 | offset +0.000 (constant cushion) | +40.95 / +41.03 | +1.39 / −0.26 |
| 2 | offset +0.000 | +40.70 / +40.70 | −1.46 / −0.61 |
| 3 | offset +0.000 | +41.03 / +40.95 | −0.60 / −2.35 |

- The same rule on all three, and no anchor error on any.
- Each connection received the same +41 ms in the stream's timestamps, and Manifold played it as
  received.
- This is SRT's design (§19.1: Manifold plays what it receives). Calibration measures it correctly
  here, because on SRT both axes are the one 90 kHz clock.

#### 3. WHEP: how the first SR line forms, why it moves, and what calibration reads

**Formation:**
- `FIRST LINE from the first SR pair at video t≈0.7–0.9 s: offset … (provisional until 10 pairs verify
  it)`: one pair.
- Then windowed fits every 10 s. The slope stays out of use until 4 × 30 s batches and an SE under
  10 ppm. Here it entered at video t = 221 / 221 / 211 s.

**Why it moves 7–25 ms in the first four minutes**, from the raw SR pairs:

| connection | pairs | video RTP vs NTP | audio RTP vs NTP | pair-offset slope (whole session) | first-pair error (adds to the ramp) | ramp 0 → 251 s | ramp + first-pair error | Manifold's line moved (§19.14) |
|---|---|---|---|---|---|---|---|---|
| 1 | 286 | +61.1 ppm | −14.0 ppm | 75.1 ppm | 6.0 ms | 18.8 ms | **24.9** | **25.1** |
| 2 | 286 | +61.4 | −7.6 | 69.0 | −4.7 | 17.3 | **12.6** | **14.4** |
| 3 | 342 | +62.3 | −4.5 | 66.8 | −9.3 | 16.8 | **7.5** | **7.4** |

(Signs in Manifold's convention. Pair residual sd 8.6–9.1 ms; p01…p99 −16…+21 ms.)

- **Mostly the SRs themselves.** OBS stamps 23.976 video ~62 ppm fast (§18.25), and Cloudflare's SRs
  carry it. The A/V offset the SRs state genuinely ramps ~17 ms in four minutes, and the line follows
  it, correctly.
- **The rest is the first line's single pair.**
  - One pair carries the pair noise: sd ≈ 9 ms, tails to ~±20 ms.
  - Here the first pair was off by −9.3…+6.0 ms.
  - A line from 1 pair allows ±9 ms (1 sd), from 2 pairs ±6 ms, and from the 10 pairs that verify it
    ±3 ms.
  - This is the only genuine start-up alignment error found. It is real in playback, bounded by the
    pair noise, and gone within ~10 s.

**What calibration reads on WHEP. The per-connection offsets are a measurement error, not a playback
error:**
- **What the SR line does to playback.** On WHEP the SR-line offset takes the cushion's slot
  (`FrameEngine.mirrorLiveAudio`: `target = senderPTS − offset`, `SenderReportLineFit.reference`).
  The audio stamped `p − offset` is played with the picture at `p`, which corrects the audio epoch
  latched on the first packet.
- **What `heard − clock` reports.** `liveAudioHeardMinusClock` returns
  `(timebase + appliedOffset) − clock`: the audio converted to the video axis, i.e. the steering error.
  It reads ≈ 0 (−3.0…+0.4 ms here) whatever the offset.
- **The beep is never converted.** Calibration's beep time is on the AUDIO axis, unconverted. So:
  - `figure = beep − flash − (heard − clock)`;
  - what is heard = `beep + offset − flash − (heard − clock)`;
  - **so the figure = what is heard − offset(t).**
- **The check, using §19.14's numbers:** figure + offset in use = **−5.17 / −4.40 / −4.71 ms** on the
  three connections. That is one heard relation, ≈ −4.8 ms (sound ~5 ms early), on every connection.
- **Within a connection, too.** WHEP-3's figure walked +0.08 → −4.38 ms in 61 s while its line rose
  ~3.8 ms (62 ppm).
- **It agrees with every earlier measurement that had a reference:**
  - §18.24's device-tested model: "device = applied + content on the received timestamps", held five
    times. Calibration's figure is the second term alone.
  - §19.10's MediaMTX sessions: figure + first offset = injection −3.5…+1.2 ms (8 / 8), and MediaMTX's
    RTSP output of the same path, read by ffmpeg, = the injection.
  - So the "8–42 ms that the content does not have … and Manifold plays exactly that" (§19.10) is
    calibration's reading. Playback was right, and RTSP agreed with playback.
- **SRT and NDI are not affected.** Both pass a cushion of 0 (`SRTFrameRouter`, `NDIService`:
  `beginLiveAudio?(0)`), and NDI's figure was device-checked in §19.13. WHEP is affected once a line
  exists; before the first SR pair, its offset is 0 too.

**What it means for what was done and written today:**
- **§19.14's WHEP per-connection spread** (−35.6 / +6.6 / −0.9) is the reading. What was heard was
  ≈ −4.8 ms each time.
  - The +4 ms applied on connection 3 happened to land near the truth.
  - Applying connection 1's proposal (+37) would have made sound ~32 ms late, and the re-check would
    still have read ~0: the same −offset is in both readings.
  - **The re-check cannot catch this error.**
- **`USER_GUIDE_SYNC.md`'s WHEP lines written today** ("can be different every time you connect … 36 ms
  early, 7 ms late and 1 ms early"; "apply for the session") **rest on the reading.** So do its
  MediaMTX "calibrate each session" lines and the 10-05 "give it a few minutes".
  - Not changed here (read-only brief). They should be revisited once the fix below is verified.
- The Cloudflare WHEP four-minute wait still has a reason, but a smaller one: the first-pair noise
  (±9 ms). The ramp affects the reading, not playback.

#### 4. Local SRT, loop-exact fixture, a forced catch-up re-anchor

**Run:**
- **Fixture:** `manifold-sync-23.976p-h264.mov` ×18 through the concat demuxer, video copied, PCM →
  AAC 192 k, MPEG-TS, 360 s (scratchpad `fix/sync1915-23976.ts`). Every segment is whole code cycles
  (§19.11), so the joins are exact.
- **Driver:** `repro/run.sh` on the `cf-Profile` build (HEAD `dff06a0`), `READRATE_CATCHUP=20
  STALLS="150:1500"`.
- **Calibrations:** two before the stall (+60 s) and three after (+175 s on), each measure-only.
- **Logs:** `~/Desktop/manifold-soak/cf1915/repro/local-stall-{1,2}.*`.
- **`local-stall-1`:** one calibration before the stall (−0.03 ms). The rest were lost to a
  UI-scripting miss on the A/V menu ("Can't get item 7 of every menu button"). Its `[AV-CONTENT]`
  `audio−now` (heard − clock at each flash) read −0.39 ms before the hold, +0.47 ms in the 60 s after a
  1 241 ms catch-up write, and +0.03 ms thereafter.
- **`local-stall-2`:** re-run with a menu retry (every menu click needed a second try).
  - `STARVATION HOLD #1` (no input 368 ms), then `⏩ STARVATION CATCH-UP` of **1 214.6 ms** debt in
    one write, at 17:21:20.

| reading | when | beep − flash | heard − clock | figure |
|---|---|---|---|---|
| pre-1 | connect +88 s | −0.00 | −0.74 | **+0.73** |
| pre-2 | connect +129 s | −0.01 | −0.17 | **+0.17** |
| post-1 | write +90 s | −0.00 | −1.00 | **+0.98** |
| post-2 | write +150 s | −0.00 | −0.50 | **+0.50** |
| post-3 | write +200 s | −0.00 | −0.25 | **+0.25** |

- **✅ No step.** Before and after a catch-up write of the same kind as Cloudflare's, the figure is
  within 1 ms of 0, and the first anchor was the same `offset=+0.000`.
- **The start-up rule is right in general on SRT.** The Cloudflare step was in what Cloudflare
  delivered.
- CLAUDE.md's non-Cloudflare check: this run is it, on SRT.

#### The fix that is clear — described, not built (built and verified the same evening: "The fix, built and verified" below)

**Calibration on RTP paths: measure in the video axis.** Either form gives the same number:
- in the flash tap, read `timebase − clock` (`liveAudioHeardMinusClock` without the `appliedOffset`
  term) instead of the mirror error; or
- add the offset in use at the flash, `figure = beep + appliedOffset − flash − (heard − clock)`.

**Expected effect:**
- **WHEP calibration reads what is heard.**
  - §19.14's three Cloudflare connections would have read −5.2 / −4.4 / −4.7 ms, not −35 / +7 / −1.
  - §19.10's MediaMTX sessions would have read the injection within −3.5…+1.2 ms, as ffmpeg's RTSP
    read did.
  - The within-connection walk with the SR ramp disappears.
- **SRT, NDI and WHEP before its first SR pair are unchanged** (offset 0).
- **Save on a WHEP bookmark becomes meaningful.** The value would no longer carry the connection's
  epoch latch.
- **Verify before trusting it:** one Audio Hijack capture on WHEP against calibration, on two
  connections with different first offsets, on MediaMTX (non-Cloudflare, CLAUDE.md) and on Cloudflare.
  It predicts: device − own control ≈ figure (fixed), and ≈ figure + offset (today's build).

**Not a fix, noted:**
- The first line from one SR pair is off by up to the pair noise (±9 ms, 1 sd) for its first ~10 s.
  Waiting for 2–3 pairs before the first line halves that, at the cost of 1–2 s on the first anchor
  gate.
- Robbie's decision; it is the only start-up alignment error this investigation found.

- No app code changed. No `defaults` were written. Manifold was quit after each local run.

#### The fix, built and verified — 2026-10-06 evening (uncommitted)

**Decided (Robbie):** calibration and its re-check measure on the video timeline: they add back the
SR-line offset Manifold applies on WHEP. SRT and NDI are unchanged (offset 0). No playback code
changes.

**Built:**
- **`FrameEngine.liveAudioCalibrationRead(against:)`**
  - Returns `liveAudioHeardMinusClock`'s figure and the `appliedOffset` it used, from one read:
    readiness and offset under one lock, the timebase read once.
  - `appliedOffset` is the `offset` `mirrorLiveAudio` hands the steering with its reference, so it is
    the line playback is steering to at that instant.
  - The corrected term, heard − clock − ℓ, is exactly `timebase − clock`. The offset cancels by
    construction and cannot lag.
  - `liveAudioHeardMinusClock` itself is unchanged; `[AV-LAG]` and `[AV-CONTENT]` read it.
- **`CalibrationMeasurement.addFlash(pts:heardMinusClock:lineOffset:)`**, with ℓ defaulting to 0.
  - It stores h − ℓ, so the code-lock window, the pairing target and the figure are all on the beeps'
    axis.
  - Each `Pair` keeps its ℓ, and `Snapshot.lineOffset` is the window's median ℓ.
- **The renderer's flash tap** carries the read. `CalibrationMode` logs `line offset` on every flash
  line.
  - On WHEP each RESULT is followed by `[CALIBRATION] RESULT on the SR line: line offset … (median over
    the same pairs), added back · without it the figure would read …`.
  - The RESULT line's own format is unchanged.
- **Test:** `testWHEPReadsTheContentOffsetNotContentMinusTheSRLine`, a synthetic WHEP session.
  - The audio is stamped p − Δ(p) for picture p. Δ₀ is +29.3 / −26.6 / −12.2 / 0 ms, with and without
    a 62 ppm slope.
  - Contents are +80 and −4.8 ms. Playback is on the target with ±0.6 ms of loop error, and h is
    (timebase + ℓ) − clock.
  - Calibration reads the content within 1 ms. The pre-fix call (ℓ left out) reads content − Δ.

**Verified, unattended:**

| check | prediction | result | |
|---|---|---|---|
| replays against b35a810 (§19.8's set: 7 sessions + synth, 6 tools) | byte-identical | **99 / 99** | ✅ |
| `swift test` | pass | **192 / 192** (191 + the new test) | ✅ |
| MediaMTX default config, 4 reconnects, +80 file (§19.10's command) | +80 ± 5 ms every calibration | **+75.11 … +80.10** (8 / 8) | ✅ |
| MediaMTX `useAbsoluteTimestamp`, 4 reconnects | +80 ± 5 ms | **+78.17 … +79.64** (8 / 8) | ✅ |
| §19.14's Cloudflare WHEP, first calibration per connection, re-read from the logs | −5.2 / −4.4 / −4.7 ms | **−4.83 / −4.45 / −4.47** | ✅ |

**MediaMTX per reconnect** (ms; build `.build-cc/whepcal-Profile`; two measure-only calibrations at
+15 s; ffmpeg reading the same path over RTSP for 90 s alongside; logs
`~/Desktop/manifold-soak/cf1916/mtx-<a|b>-<n>.*`):

| reconnect | first line ℓ | calibration 1 / 2 (fixed) | without the fix | RTSP read |
|---|---|---|---|---|
| b-1 | +11.09 | +80.10 / +79.11 | +69.25 / +68.42 | +80.16 |
| b-2 | −7.94 | +77.52 / +76.78 | +85.88 / +85.32 | +77.81 |
| b-3 | −30.84 | +76.23 / +75.73 | +107.06 / +106.56 | +77.61 |
| b-4 | −31.65 | +75.80 / +75.11 | +107.44 / +106.26 | +77.31 |
| a-1 | −28.00 | +79.13 / +78.17 | +107.12 / +106.16 | +79.75 |
| a-2 | −6.28 | +79.64 / +78.89 | +85.92 / +85.17 | +79.75 |
| a-3 | −28.00 | +78.83 / +78.18 | +106.82 / +106.17 | +79.75 |
| a-4 | −6.29 | +79.02 / +79.05 | +85.30 / +85.33 | +79.75 |

- **Calibration matches the RTSP read on every reconnect, within 0.1–2.2 ms.** It no longer follows the
  line: ℓ ranged over 42.7 ms, and the fixed figures over 5.0 ms.
- The default config's RTSP read also moved (+80.2 → +77.3 ms). That is in MediaMTX's stream, not
  Manifold's.
- MediaMTX was restarted fresh per config and left on `mediamtx-soak-abs.yml`, as found, with stdout
  appended to `~/Desktop/manifold-soak/mediamtx-soak.log`. The config files' hashes are unchanged.

**§19.14 Cloudflare, all runs re-read** (`recal1916.py`, scratch: ℓ per flash = the last
`[WHEP-SRFIT]` line before it, along its slope when in use):

| run | as logged | ℓ | corrected |
|---|---|---|---|
| WHEP-1 cal 1 / 2 | −34.50 / −36.75 | +29.63 / +30.33 | **−4.83 / −6.28** |
| WHEP-2 cal 1 / 2 | +7.83 / +5.33 | −12.03 / −11.94 | **−4.45 / −6.48** |
| WHEP-3 cal 1 / 2 / for Apply | +0.08 / −1.79 / −4.38 | −4.45 / −3.94 / −1.15 | **−4.47 / −5.60 / −5.54** |
| WHEP-3 re-check (O = +4) | −2.49 | +0.22 | **−2.71** |

- **All eight lie in −6.5…−2.7 ms (sound ~5 ms early), against −36.8…+7.8 as logged.**
- The +4 ms applied on WHEP-3 happened to be near the truth. Applying WHEP-1's +37 would have made
  sound ~32 ms late.

**At the device** (`cap1916.sh`: one Manifold process; MediaMTX `useAbsoluteTimestamp`; the +80
file):
- **The recording:** connection 1 (35 s), ⌃⌥⇧N, connection 2 (calibrated, 35 s), then the 23.976 ProRes
  master from disk (35 s) as the chain's zero. Audio Hijack and the recorder OBS ran throughout.
- **Analysis:** `c12.py` per segment, cut at the driver's marks with 2 s margins. Device = WHEP
  segment − disk segment, so c12's onset bias cancels.
- **Prediction:** device and calibration agree within ±5 ms on both connections.

| capture | connection (ℓ) | calibration (fixed) | without the fix | c12 WHEP / disk | device | device − calibration |
|---|---|---|---|---|---|---|
| `cap1` (recorder at **23.976**) | 1 (−39.45) | +75.57 | +115.01 | +73.51 / +0.35 | +73.16 | −2.4 |
| | 2 (−3.58) | +79.75 | +83.33 | +73.18 / +0.35 | +72.83 | **−6.9** |
| **`cap2` (recorder at 60, as §1.2)** | 1 (−39.45) | +76.73 | +116.18 | +105.50 / +27.10 | **+78.40** | **+1.7** ✅ |
| | 2 (−29.33) | +81.09 | +110.42 | +108.65 / +27.10 | **+81.55** | **+0.5** ✅ |

- **✅ `cap2` passes on both connections** (+1.7 / +0.5 ms; means +1.0 / +0.5). The unfixed formula would
  have been off by 37.8 / 28.9 ms. c12 found 24–25 / 25 / 25 pairs, every gate held, and 0 doubled.
- **`cap1` is not counted.** The recorder was at 23.976, against AV_SYNC_FINDINGS.md §1.2's 60. The
  instructions left the check out.
  - Each segment then carries a recorder-phase bias of up to one 41.7 ms frame, which does not average
    out within 32 s.
  - Its connection 2 missed the band by 1.9 ms.
  - Its relative result stands: the two connections played within 0.3 ms of each other at the device,
    where the unfixed formula claimed 31.7 ms apart.
- **The disk zero moved** +0.35 → +27.10 ms between the two recorder launches. That is the
  measurement chain's launch-to-launch drift (§18.24), and why every absolute is taken against its
  own control.
- **Files:**
  - `cap1`: `~/Movies/2026-10-06 17-57-57.mov`, `~/Music/Audio Hijack/20261006 1757 Recording.wav`.
  - `cap2`: `~/Movies/2026-10-06 18-11-28.mov`, `~/Music/Audio Hijack/20261006 1811 Recording.wav`.
  - c12 ran on the recorder's file. The Audio Hijack files are kept, not analysed.
  - Segments and logs: `~/Desktop/manifold-soak/cf1916/cap{1,2}*`.

**What changes:**
- WHEP calibration can be saved to a bookmark. On both servers tested it read the same within ~5 ms on
  every reconnect.
- `USER_GUIDE_SYNC.md` is corrected (its WHEP and MediaMTX lines were taken from the faulty reading).
  `BUGS.md`: the bug is FIXED, and the 2026-10-01 MediaMTX entry is resolved as this bug.
- ⚠️ **Not changed: `[AV-LAG]` / `[AV-CONTENT]`** (DEBUG telemetry) still compare beeps on the audio axis
  with heard − clock on the video axis, so on WHEP they carry the same −ℓ. Earlier WHEP figures from
  them, and analyses built on them, need ℓ added.

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

**MediaMTX's SRs follow arrival at the relay, not capture (read-only analysis, 2026-09-30 evening).**
This is the cause of the MediaMTX staircase SRs (§18.5, §18.7). It does not explain the device swing.
AV_SYNC_FINDINGS.md §6.8 carries the short form.

- **How MediaMTX v1.21.1 builds them.** With the default `useAbsoluteTimestamp: false` (the soak
  config does not set it), OBS's own SRs are discarded. MediaMTX builds each track's NTP on its own
  packet-arrival wall clock (`internal/ntpestimator`):
  - the first packet's arrival time is the anchor;
  - later packets get the anchor plus their RTP advance;
  - the anchor resets to the current arrival when a packet arrives earlier than that prediction (or
    more than 5 s late), so it only ever moves earlier.
  - Each SR is the last packet's (RTP, NTP) pair, extrapolated by wall time (gortsplib `rtpsender`,
    1 s period).
- **So the SR A/V relation is the difference of each track's earliest arrival at the relay**, not
  of their capture. Nothing Manifold does can recover capture from it.
- **Measured on this run.** From capture A to capture B the SR Δ moved **+44.0 ms** (−22.30 →
  +21.73 ms). The flash-beep content on the raw RTP timestamps (`[AV-CONTENT]` decoded) moved
  **−1.3 ms** (−72.6 → −73.9 ms). Sep 28 `srfix-whep-mediamtx`: +75.3 ms of SR movement.
- **The signature, in all three MediaMTX sessions** (this run, `srfix-whep-mediamtx`,
  `step8-whep-soak`): every change in Δ arrives on a video SR and is upward, i.e. the video anchor
  stepping earlier. There are 46 / 55 / 63 steps of 0.1–5 ms, totalling +57 / +88 / +72 ms. Audio SRs
  never moved Δ.
- **Not issue #5593** (mixed RTP domains when WebRTC egress rewrites audio timestamps). It was fixed
  in PR #5597 (merged 2026-03-21), which v1.21.1 contains. One residual path remains: an incoming
  audio timestamp gap under 500 ms would still shift the audio mapping. It would show as Δ moving on
  audio SRs, which never happened here.
- **The RTSP output (the `--diag` sender probe) uses the same per-track NTP**, so a probe read with
  RTCP sync inherits the same error. MediaMTX's SRT/MPEG-TS output is stamped from the RTP timestamps
  instead (one fixed start offset), and a sender-side OBS recording is independent of the relay.
- **Why it does not explain the swing:** the SR movement (+44 ms) is not the device movement
  (+98.6 ms), and on Sep 28 the SRs moved +75 ms while the device moved −12.9 ms.
- **Instrument added:** `[WHEP-SR-RAW]` (DEBUG, pre-ship removal in BUGS.md) logs every SR per track
  with NTP, RTP and local receive time. On a same-machine relay `ntp − rx_wall` reads the relay's
  per-track anchor directly.

**The applied hold caused this run's device swing (read-only analysis, 2026-09-30 evening).**

- **The at-glass estimate cannot see a target move, by design.** `[AV-CONTENT]`'s at-glass figure
  uses `audio−now`, which is `FrameEngine.liveAudioDrift`. That adds `appliedOffset` back before
  reporting, so it reads only the error around the target. `appliedOffset` is the SR line's offset
  plus the hold's correction (`SenderReportLineFit.evaluate`), so neither the SR line's moves nor the
  hold's reach the estimate.
- **What else the hold did between A and B:** 0 timebase writes (the session's one was the first
  anchor), 0 splices, 0 coarse events. Every action went through the target offset.
- **Applied offset:** −22.3 ms at A (SR line, hold not engaged) → +77.7 ms at B. At B that is the
  SR line's +20.9 ms plus the hold's +56.8 ms (queue −0.3 ms from its start level, against −57.1 ms on
  the SR line alone).
  - A → B: **+100.0 ms**, of which ~+10.8 ms is the SR line before the hold engaged (481 s) and
    ~+89 ms is the hold.
- **The gap between the recorded device A/V and the at-glass estimate** grew +22.0 → +122.3 ms:
  **+100.35 ms, 1:1 with the applied-offset move, same sign.**
- **Device prediction:** applied move (+100.0) + content move on the raw RTP timestamps (−1.3) =
  **+98.7 ms**, against **+98.6 ms** measured.
- **Why the hold did this: its premise fails on MediaMTX.** The hold assumes queue level =
  lip-sync. Here the queue drains at ~65 ppm while the content on the RTP timestamps stays put
  (−1.3 ms over 23 min). Holding the queue level therefore moved the target, and lip-sync with it,
  at ~70 ppm.
- **Unresolved: Sep 28 `srfix-whep-mediamtx`** (no hold, a build without `[AV-CONTENT]`).
  - Its applied offset (the SR line, slope in use) moved +76.0 ms from A to B, but the device moved
    −12.9 ms, close to the queue-depth change (−15.8 ms).
  - Reconciling it with the relation above needs about **−89 ms** of content movement on the RTP
    timestamps that day, which that build could not measure.

### 18.22 Offset lock — replay of every logged WHEP session (no app change) — 2026-09-30 evening

**Hypothesis.** On MediaMTX the SR offset's steps are artefacts of the relay's arrival anchor ratcheting
(§18.21), not A/V changes, so following them walks lip-sync. **Candidate: the offset lock.**
- Take the SR offset once, at the reference span.
- After that, only the slope comes from the SRs, and the offset never re-levels on a step.
- A re-level is still allowed on a real discontinuity: an RTP timestamp jump, a restart, or an SSRC
  change.

**Tool.** `replay/offset-lock/main.swift` → `replay-bin/replay-offset-lock`, open loop. It runs the
working tree's fit (hold observe-only, as shipped) and the candidate on the logged SR pairs of each
session.
- **The figure is the applied offset**, not queue depth: on MediaMTX lip-sync moves 1:1 with the
  applied offset and the queue is not lip-sync (§18.21).
- **Reference span:** 60–120 s. None of these logs has a "LEVEL REFERENCE set" line.
- **Step:** a pair-to-pair jump over max(50 µs, 8σ) that persists over the next 5 pairs. σ is the MAD
  of the session's own first differences, so the threshold is relative to each server's noise, not
  tuned to either one.
- **Sessions:** 18 sessions in 14 logs (`step8-srtest1`'s first, 42 pairs, is skipped). Eight are long
  enough for the A → B figures.
- **Discontinuities:** no session contains an RTP timestamp jump, SSRC change or restart inside it
  (a restart is a new session here), so that re-level path is not exercised.

**The SRs of the two servers differ in kind:**
- **MediaMTX + OBS:** Δ pair noise ~10 µs.
  - Every long session is a staircase: 38 / 53 / 53 confirmed upward steps. These account for all of
    Δ's movement (+57.1 / +88.4 / +72.3 ms, against +57.2 / +88.6 / +72.5).
- **MediaMTX + ffmpeg sender:** no step at all (Δ flat for 31 min).
- **Cloudflare:** Δ pair noise 4–9 ms and a steady ~66–68 ppm ramp.
  - Its "jumps" are 1–2-pair spikes that return. **No persistent step in any Cloudflare session.**
  - The one candidate, the 4.5 h run's upstream pause at 6022 s, is a −1.0 to −1.8 ms level change
    on 900–1800 s windows. That is inside the SR noise.

**Four forms of the lock were replayed.** They differ only in how the slope reaches the applied
offset.

| form | MediaMTX + OBS (3 sessions) | Cloudflare (4 long sessions) |
|---|---|---|
| **integrate** the trailing-600 s step-free slope | flat within 0.1 ms | early slope noise is integrated for good: up to 10 ms off the fit; −8.3 ms at +26 min on the 4.5 h run |
| **gated** (the same, slope used once SE ≤ 10 ppm) | flat | worse: 12–23 ms behind (no slope while waiting, and nothing re-levels) |
| **anchored** line through the reference, slope over everything since | flat within 0.2 ms | ≤ 5 ms on 30-min sessions; **10.3 ms behind at +4 h 30** (a whole-session slope lags a drifting one) |
| **step-free**: the fit itself, fed the step-free Δ 5 pairs late | flat within 0.2 ms | **= the fit**: mean difference 0.00 ms, sd 0.4–0.6 ms, ≤ 0.2 ms at every capture point |

The literal lock (offset once, slope only) is not transparent on Cloudflare. Its offset cannot recover
from the slope's acquisition error. **Step-free** keeps the offset the SRs give and removes only the
steps.

**Applied offset, current fit against step-free** (movement in ms):

| session | server | length | fit: ref → end | step-free: ref → end | fit: A → B (+3 → +26) | step-free: A → B |
|---|---|---|---|---|---|---|
| level-whep-mediamtx (today) | MediaMTX | 31 min | +56.6 | **+0.1** | +43.6 | **+0.1** |
| srfix-whep-mediamtx | MediaMTX | 29 min | +89.1 | **+0.2** | +75.9 | **+0.2** |
| step8-whep-soak | MediaMTX | 29 min | +71.7 | **+0.1** | +64.2 | **+0.1** |
| srprobe-ffmpeg-mediamtx | MediaMTX (ffmpeg) | 31 min | 0.0 | 0.0 | 0.0 | 0.0 |
| srfix-whep-cloudflare-long | Cloudflare | 4.5 h | +1081.0 | +1084.1 | +101.8 | +101.9 |
| srprobe-obs-cloudflare | Cloudflare | 32 min | +126.8 | +125.6 | +98.6 | +98.8 |
| step4e2-cloudflare | Cloudflare | 37 min | +141.1 | +141.0 | +90.4 | +90.5 |
| step4e2-cloudflare-2 | Cloudflare | 37 min | +142.0 | +142.3 | +91.7 | +91.6 |

- **The sessions under 4 min** (4e1 ×2, srtest1/2, the six 2026-09-23 probes): MediaMTX flat in both;
  the 4e1 Cloudflare session +10.5 fit / +10.3 step-free.
- **The 4.5 h run at its own capture B (+4 h 30):** fit − step-free = +0.12 ms.
- Traces: `<session>.offset-lock-<form>.trace.tsv` (x, Δ, fit applied, candidate applied, slope).

**What any step-rejecting rule gives up** (synthetic persistent steps added to `step4e2-cloudflare` at
900 s):

| injected real step | +5 ms | +20 ms | +40 ms | +100 ms |
|---|---|---|---|---|
| current fit follows | +5.0 | +20.0 | +40.0 | +100.0 |
| step-free follows | +5.0 | +20.0 | +40.0 | **−6.4 (missed)** |
| anchored follows | +7.1 | +28.6 | +57.2 | −9.1 (missed) |

- **Below the noise-relative threshold** (~50 ms on Cloudflare), step-free follows a real step
  exactly.
- **Above it**, a real A/V step with no RTP timestamp jump, restart or SSRC change is ignored.
- **On MediaMTX the threshold is ~0.08 ms**, so there any real step without such a signal is ignored.

**What the lock does not fix.**
- **The absolute offset.** It is locked at the relay's arrival anchor, which differs per session
  (first-pair Δ −22.3 / −42.9 / −20.2 ms). Today's capture A (−74.3 ms against zero, SR offset
  −22.3) would have been the same under the lock.
- **The queue drain.** With the offset held, the queue keeps draining at the media's ~65 ppm.
  - Rebuilt from the logged windows: −66.3 / −64.0 ppm on `srfix-whep-mediamtx` / `step8-whep-soak`.
  - ~~It reaches the 250 ms coarse level at ~39–46 min.~~ **Corrected 2026-09-30:** the coarse
    branch triggers on content-time error (|e_f| > 250 ms), not on queue depth, so a draining queue
    never reaches it. What the drain reaches is the starvation hold; see "Step-free rejected" below.
  - Not rebuildable for today's run: the windows record the SR-line offset, not the hold-corrected
    one.
- **§6.3's restated criterion** ((B − A) + depth term) reads that drain as lip-sync, so under the lock
  it must not be used on MediaMTX; B − A is the figure.

**Step-free rejected: the drain is OBS's, and the sender's timestamps are not consistent across days
(analysis 2026-09-30 evening, logs and replay only).**

- **OBS delivers audio ~66 ppm slower than video.** The invariant (applied offset − queue depth) moves
  at +66.0 / +66.4 / +68.0 ppm on `step8-whep-soak` / `srfix-whep-mediamtx` / today (before the hold
  engaged), and +66.4 ppm on the 4.5 h Cloudflare run.
- **The steps are the relay's ratchet and do not carry the drain.**
  - The skew is the same in windows where Δ is flat (+60.1…+69.0 ppm) as in windows where it steps
    (+66.3…+66.4 ppm).
  - The steps accumulate at a different, bursty rate: 31 / 42 / 52 ppm (112 / 152 / 186 ms/h).
  - Removing them leaves the drain untouched.
- **Device move = applied-offset move + content move on the RTP timestamps.** It fits all three
  MediaMTX sessions:

| session | applied A → B | content A → B | predicted device | measured device B − A |
|---|---|---|---|---|
| `step8-whep-soak` (Sep 28) | ≈ 0 (the fit froze on a slope-0 line, §18.5) | ≈ −89 | ≈ −89 | −89 |
| `srfix-whep-mediamtx` (Sep 28) | +76.0 | ≈ −89 | ≈ −13 | −12.9 |
| `level-whep-mediamtx` (Sep 30) | +100.0 | −1.3 (measured) | +98.7 | +98.6 |

- **OBS's timestamps were inconsistent on Sep 28 and honest on Sep 30.**
  - On Sep 28 the content drifted ~−64 ppm against OBS's own RTP timestamps, tracking the arrival
    skew. On Sep 30 it held (−1.3 ms over 23 min), with the same 66 ppm skew.
  - The one sender-side difference on record is OBS's audio buffering (85 ms after a day's running
    on Sep 28; 42 ms on a fresh launch on Sep 30, AV_SYNC_FINDINGS.md §1.2). It is a lead, not a
    proven cause.
  - This resolves §18.21's "−89 ms unresolved" for `srfix-whep-mediamtx`.
- **`step8-whep-soak` was effectively a step-free run, and it failed by −89 ms** at +26 min. Step-free
  holds the applied offset, which is right only on a Sep 30-type day.
- **The consequence for long sessions, even on a Sep 30-type day** (a model from the replayed drain
  and the steering's constants; the steering was not run out to 90 min):
  - **The drain.** The queue falls ~238 ms/h from ~424 ms, to ~74 ms at 90 min.
  - **What fires: the starvation hold, not the coarse branch.**
    - It arms when the queue's low point before an enqueue reaches `starvationMarginSeconds`
      (20 ms): ~98 min on smooth arrival.
    - A delivery stall of d ms brings it forward to when the median reaches d + 20 ms. Today's log
      has a session low-water of 199 ms, i.e. a ~225 ms stall, which would mean ~45 min.
  - **Each hold** is a timebase write, with the renderer's ~50 ms mute. The resume waits for 100 ms
    of refill, so the audio restarts ~80–100 ms behind the picture.
  - **The debt cannot be repaid.** A cut needs debt + 100 ms queued, and the catch-up write needs the
    whole debt queued within 1 s; under a steady drain neither happens.
  - **So device lip-sync moves audio-later by ~80–100 ms per hold**, with a hold every ~16 min. Once
    the arrival lead is spent, audio cannot play before it arrives, so lip-sync walks at the arrival
    skew whatever offset is chosen.
  - **Holding lip-sync on a Sep 30-type day** would need the picture slowed to the audio's arrival
    rate, with latency growing ~238 ms/h. Nothing in Manifold does that.
- **Cloudflare, for contrast:** the same 66 ppm arrives as a smooth SR slope. The fit follows it, the
  queue stays level (−0.3 ppm), and the device held within 10 ms over 4.5 h (§18.8).
- **Decision: step-free is rejected, and was not implemented.** The level hold stays observe-only.

**Conclusion.** Default-configured MediaMTX (`useAbsoluteTimestamp: false`) discards the sender's SRs
and restamps from its own arrival clock (§18.21). Whatever A/V correction the sender's SRs carried is
lost before Manifold sees the stream. On the same sender, the correct offset trajectory was flat on
Sep 30 and −64 ppm on Sep 28, while the SRs Manifold received looked alike. **No rule using only the
received SRs can recover it**: not the fit, not the level hold, not step-free. Default-configured
MediaMTX with OBS over WHEP stays a known limitation (§18.21 decision 4). §18.23 tests whether keeping
the sender's SRs helps.

### 18.23 MediaMTX with `useAbsoluteTimestamp: true` — does OBS's own SR mapping hold A/V? — prepared 2026-09-30

**Setup.** `go.sh mediamtx --abs` runs MediaMTX on `scripts/soak/mediamtx-soak-abs.yml`. It is
identical to `mediamtx-soak.yml` except for `useAbsoluteTimestamp: true` on `live`, and runs with
label `<prefix>-abs-whep-mediamtx`. The default config is unchanged. `go.sh` restarts MediaMTX
whenever the running config is not the one asked for.

**From the source** (MediaMTX v1.21.1, gortsplib v5.6.6, OBS 32.2.2, which bundles libdatachannel
v0.24.2):
- **Yes: the WebRTC output's SRs are mapped from OBS's own SR NTP.**
  - With the setting on, `ToStream` stamps each inbound packet with
    `rtpreceiver.PacketNTP` = NTP of that track's latest OBS SR + (packet RTP − SR RTP) / clock rate.
    It is re-anchored on every OBS SR (1 s).
  - The stream keeps that NTP (no `ntpestimator`). The WebRTC output's `rtpsender` builds its SRs from
    the last packet's (RTP, NTP), so they carry OBS's mapping.
  - Video RTP timestamps pass through. Audio is re-stamped on output as a contiguous count with the
    matching NTP (the #5597 fix). If OBS's audio timestamps jumped by < 500 ms, the audio mapping would
    shift by the jump; it would show as a Δ change on an audio SR.
- **Packets are dropped before the first OBS SR, but in practice ~none.**
  - Until a track's first SR arrives, each of its packets is dropped and logged: `WAR received RTP
    packet without absolute time, skipping it`. This is per track and per packet.
  - libdatachannel's `RtcpSrReporter` sends an SR on the first outgoing batch, because its
    last-report time starts at the clock epoch, then every ≥ 1 s. So the first SR travels with each
    track's first RTP packets.
  - If that SR were lost, the track would lose up to 1 s. On video that would also delay the first
    decodable frame to the next keyframe (1 s GOP).
  - Check the MediaMTX log for the warning after the run.
- **What OBS's SRs are:** libdatachannel stamps NTP = `system_clock::now()` at send, with the RTP
  timestamp of the packet just sent. They are send-time mappings, each track's own encode-to-send
  latency included.
  - They carry the ~66 ppm skew as a smooth slope, as Cloudflare's do, and a constant offset of the
    tracks' latency difference.
  - They are right about content only on a day when OBS's timestamps drift with the skew (a
    Sep 28-type day).

**Prediction** (observe-Profile, hold observe-only, so the applied offset is the SR line; A = +3 min,
B = +26 min):

| figure | prediction | pass band |
|---|---|---|
| SR Δ | a smooth ramp at ~+66 ppm with ms-level per-pair jitter; **no staircase** (0 confirmed upward steps) | ramp +55…+75 ppm; any staircase = fail of the premise |
| applied offset A → B | follows the ramp: ~+91 ms | +75…+105 ms |
| queue depth A → B | level, as on Cloudflare | within ±15 ms |
| content on RTP timestamps (`[AV-CONTENT]` decoded) A → B | measured, not predicted: ≈ 0 on a Sep 30-type day, ≈ −89 on a Sep 28-type day | classify: \|x\| ≤ 10 → Sep 30-type; −70…−105 → Sep 28-type |
| device B − A, grid-corrected | = applied + content | see below |

- **OBS's own SRs are correct if** device B − A is within **±10 ms**, i.e. applied + content ≈ 0.
  That is expected only on a Sep 28-type day (content ≈ −89).
- **They are not correct if** device B − A ≈ the applied move (**+75…+105 ms**) while content stays
  within ±10 ms (a Sep 30-type day). Given how libdatachannel stamps them, that is the expected
  outcome on a freshly launched OBS.
- **Either way the queue stays level.** A pass here would mean lip-sync and queue both hold on that
  day, but not that OBS's SRs are right on every day.
- **Also check:** 0 packets dropped before the first SR (MediaMTX log), and the §18.21 staircase gone
  from Δ.

#### Result: `observe-abs-whep-mediamtx`, 2026-09-30 19:05–19:47 — ✅ lip-sync held (B − A +3.9 ms), and this OBS session DRIFTED

**Run.** observe-Profile (hold observe-only, applied offset = the SR line), `go.sh mediamtx --abs`, OBS →
MediaMTX v1.21.1 (`useAbsoluteTimestamp: true`) → Manifold WHEP. Connect 19:11:30. Capture A +180 s,
capture B +1560 s.
- **Sender OBS:** launched 18:57:20. Audio buffering 42 ms from 18:57:21 (sources Atem, Decklink), no
  change during the stream (19:11:10–19:47:27). Scene BLIPS_NOISE.

| figure | §18.23 band | measured | |
|---|---|---|---|
| SR Δ shape | smooth ramp, no staircase | ramp; pair noise 4.2 ms (MAD); 0 persistent steps; fit: 0 steps, 0 rejected, 0 unstable | ✅ |
| SR Δ slope | +55…+75 ppm | **+60.55 ± 1.48 ppm** (fit, session end); Δ +15.7 → +131 ms | ✅ |
| applied offset A → B | +75…+105 ms | **+92.6 ms** (+27.9 → +120.5) | ✅ |
| queue depth A → B | ±15 ms | **+1.5 ms** (428.6 → 430.0; session 425.4–432.2) | ✅ |
| content on RTP timestamps A → B | classify | **−92.1 ms** (−35.1 → −127.2) → **drifting (Sep 28-type)** | |
| device B − A, grid-corrected | drifting: ±10 ms | **+3.9 ms** | ✅ |

- **Device detail** (`c12.py`, controls by `fc.py`):
  - Controls: +2.47 / +4.29 ms, 1.8 apart (±5 ✅), zero +3.38.
  - Capture A +14.58, B +18.51 grid-corrected, i.e. **+11.2 / +15.1 against zero** (±20 ✅ both).
  - All capture gates pass. The controls' grid gate fails by construction (a looped file), which is
    why `fc.py` reads them.
- **The model holds a fourth time:** applied + content = +92.6 − 92.1 = +0.5 ms predicted, +3.9
  measured.
- **The at-glass estimate** moved −92.2 ms (−58.6 → −150.7) while the device moved +3.9. The gap grew
  +96.1 ms against an applied move of +92.6. That is §18.21's blind spot, as expected.
- **MediaMTX log:** 2 × "received RTP packet without absolute time, skipping it", both at 19:11:11
  when publishing started, before OBS's first SR and 19 s before Manifold connected. None afterwards.
  No other warnings.
- **No audio-SR step.** Δ moves on every SR on both tracks, but that is OBS's send-time jitter: per-pair
  NTP − receive sd 8 ms audio, 3–4 ms video. No persistent step on either track at the 33 ms
  (8σ) threshold.
- **Per track, OBS's SR NTP sits flat against arrival** (`[WHEP-SR-RAW]`, same Mac clock): audio
  +1.4 → +2.4 ms, video −7.3 → −7.3 ms, slopes −2.9 / +0.6 ppm.
  - So OBS's SRs map each packet to about when it arrived, as libdatachannel's code says.
  - The ramp is OBS's audio RTP timestamps advancing ~60 ppm slower than that clock.

**Reading.**
- **"A freshly launched OBS is honest" is refuted.** This session and §18.21's (16:40) had the same
  logged sender state: fresh launch, 42 ms, BLIPS_NOISE, the same 60–68 ppm arrival skew. Content held
  on the RTP timestamps in one (−1.3 ms) and drifted with the skew in the other (−92.1 ms). Neither
  launch age nor audio buffering predicts it; it has to be measured per session.
- **OBS's own SRs were right for lip-sync in this session**, because the content drifted exactly with
  the arrival skew they carry. On the 16:40 session the same SRs would have been wrong by ~+90 ms
  (applied ≈ +91, content −1.3). They are send-time mappings: right when OBS's timestamps drift with
  delivery, wrong when its timestamps are honest.
- **For the DeckLink → Cloudflare run** (README.md, "A realistic sender"):
  - The prediction table stands with both outcomes. The note that a fresh OBS would be honest is
    withdrawn.
  - The sender recording is what classifies the session.
  - The DeckLink path removes OBS's media-source playback entirely. Whether the honest/drifting
    alternation belongs to that playback, or to OBS's output for any source, is what the run can show.

### 18.24 A realistic sender: Resolve → SDI → DeckLink → OBS → Cloudflare WHEP — ✅ lip-sync held (B − A +4.15 ms); the sender was honest — 2026-09-30 20:13–20:58

**Run.** `observe-decklink-whep-cloudflare`, observe-Profile (hold observe-only, applied offset = the
SR line), `go.sh cloudflare --sender decklink` (scripts/soak/README.md, "A realistic sender").
- **Picture and sound came from one card.** A Resolve workstation played
  `decklink-flash-beep-noise-2398-45m.mov` (the BLIPS_NOISE schedule on one timeline, verified every
  frame and sample) out over SDI into this Mac's DeckLink. OBS sent scene DECKLINK_BEEPS (the
  DeckLink input alone, 0 dB) to Cloudflare over WHIP.
- **Timing.** Connect 20:19:55. The file anchor (first beep received) was 20:20:08, 3 s after the
  prompt. Captures at anchor +180 / +1560 s, which is session time 192–324 / 1572–1704 s.
- **The anchor checks out.** The noise segment starts at 20:25:37 in the Audio Hijack capture,
  against 20:25:38 expected.
- **Sender recording** (OBS's own output, stream encoder, on OBS's own timestamps):
  `~/Movies/2026-09-30 20-20-08.mov`.

| figure | measured | |
|---|---|---|
| **sender recording A → B** (`probe_av.py … 180 1560`, grid-corrected) | **+0.02 ms** (−27.12 → −27.10 as written; −7.1 ms grid-corrected at both; trend +0.1 ms over 23 min) | **honest**: OBS's output held A/V on OBS's timestamps |
| SR Δ shape | smooth ramp, pair noise 6.8 ms (MAD); two one-pair spikes; no persistent step; fit: 0 steps, 1 rejection, 0 unstable | ✅ |
| SR Δ slope | **+66.01 ± 1.58 ppm** (fit, session end) | the same skew as with OBS's file playback |
| applied offset A → B | **+93.1 ms** (+11.2 → +104.3; s × 1380 s = +91.1) | ✅ |
| queue depth A → B | **+1.9 ms** (419.6 → 421.5; session 416.0–424.2) | ✅ level |
| content on the RECEIVED (Cloudflare's) RTP timestamps A → B | **−92.05 ms** (−57.71 → −149.76) | drifts on Cloudflare's timestamps |
| **device B − A, grid-corrected** | **+4.15 ms** (−3.61 → +0.54) | ✅ ±10 |

- **The model holds a fifth time:** device = applied + content on the received timestamps =
  +93.1 − 92.05 = **+1.05 ms** predicted, **+4.15** measured.
- **Absolutes:** −31.4 / −27.3 ms against the zero, outside ±20. Not read as Manifold's:
  - The zero is control 1 alone. Control 2 was lost (below).
  - The sender chain itself reads −7.1 ms grid-corrected.
  - The controls moved 25 ms between launches tonight (next bullet).
- **The controls move between launches, in the measurement chain.** Control 1 read **+2.47 ms at
  19:06** (`observe-abs-whep-mediamtx`) and **+27.81 ms at 20:14** (this run). A file played from disk
  by Manifold, the same recorder and fixture, so the 25 ms is the measurement chain launch to launch,
  not Manifold's live path. It is why every absolute is taken against the same launch's controls,
  and why B − A is the figure.
- **Mutes:** 2 × 20 ms exact-zero gaps in the noise segment. They match audio sequence gaps at
  20:29:44 and 20:37:07: single Opus packets lost upstream, as in §18.8. Manifold: 0 holes, 0
  starvation holds, 0 splices, 1 timebase write.
- **Control 2 was lost to an orchestrator race, now fixed.**
  - Manifold logged the deck release 645 ms *before* WHEP's DELETE; at 19:42 it had come 41 ms after.
  - `soak.mjs` searched for the release only after the DELETE and waited forever.
  - It now scans for both from where the wait began (`scripts/soak/soaklog.mjs`, tested on both
    runs' real lines in `soaklog.test.mjs`).
- **The prediction (README, "A realistic sender") was wrong for the honest case.** It expected
  content on the received timestamps to follow the sender recording, so that a 66 ppm ramp would
  fail by ~+91 ms. Cloudflare re-stamps the stream: its timestamps drift against the content by the
  skew, and its SR slope corrects exactly that.

**Conclusion: what matters is whether the received SRs match the received timestamps, not whether the
sender is honest.**
- **OBS's output carries ~66 ppm audio-slow delivery even from a single SDI card.** So it is not OBS's
  media-source playback. Senders and relays differ in whether their *timestamps* carry it.
- **Cloudflare re-stamps consistently.** Its SRs correct its own timestamps, so following them held
  lip-sync with an honest sender (here, +4.15 ms) and over 4.5 h (§18.8).
- **Default MediaMTX does not.** It passes the sender's timestamps through but replaces the SRs with
  its arrival ratchet (§18.21, §18.22).
- **MediaMTX with `useAbsoluteTimestamp: true`** passed in the one session tested, which drifted
  (§18.23). It is untested on a session where the received timestamps are honest.

**Withdrawn.**
- The inference that the 4.5 h Cloudflare pass needed a drifting OBS: Cloudflare works with an honest
  sender too.
- That a freshly launched OBS predicts honesty (already refuted by §18.23).

**Open research.** `go.sh mediamtx --sender decklink`, with and without `--abs`.
- **What it separates:** MediaMTX re-stamps the audio on output (a contiguous count, §18.21), so
  "content on the received timestamps" on MediaMTX includes MediaMTX's own audio re-stamping, not
  only OBS's timestamps.
- **What it gives:** the sender recording (OBS's timestamps) and the received content side by side in
  one session.

### 18.25 MediaMTX `useAbsoluteTimestamp: true` with the DeckLink sender — ✅ B − A −5.45 ms — and the root cause: OBS stamps 23.976 video 66.6 ppm fast — 2026-09-30 21:10–21:51

**Run.** `observe-abs-decklink-whep-mediamtx`, observe-Profile (hold observe-only, applied offset = the
SR line), `go.sh mediamtx --abs --sender decklink`.
- **Chain:** Resolve → SDI → DeckLink → OBS (scene DECKLINK_BEEPS, input at 0 dB) → MediaMTX v1.21.1
  (`mediamtx-soak-abs.yml`; the instance running since 19:05 was reused, as the config matched) →
  Manifold WHEP.
- **Timing:**
  - Connect 21:17:17.97.
  - File anchor 21:17:29 as noticed. The noise check puts the real file start ~5 s earlier (noise at
    21:22:54 against 21:22:59): the spoken-prompt delay, inside the capture margins and now fixed
    (below).
  - Captures at session 191–323 / 1571–1703 s.
- **Both controls ran.** The release-line fix (§18.24) worked: "live session ended and deck released"
  13 s after the prompt.

| figure | measured | |
|---|---|---|
| sender recording A → B (OBS's own timestamps, `probe_av.py … 180 1560`) | **+0.02 ms** (−26.80 → −26.78; −6.8 grid-corrected at both; trend +0.1 ms over 23 min) | honest |
| SR Δ shape | smooth ramp, pair noise 4.0 ms (MAD); one one-pair spike at 1120 s (−34.9 then back); fit: 0 steps, 0 rejected, 0 unstable | ✅ |
| SR Δ slope | **+61.87 ± 1.52 ppm** | |
| applied offset A → B | **+91.5 ms** (+11.7 → +103.2) | |
| queue depth A → B | **−0.2 ms** (428.8 → 428.6; session 426.4–431.8) | ✅ level |
| content on MediaMTX's received timestamps A → B | **−92.06 ms** (−44.85 → −136.91) | |
| **device B − A, grid-corrected** | **−5.45 ms** (A +13.15, B +7.70) | ✅ ±10 |
| absolutes against the zero | **−13.1 / −18.5 ms** | ✅ ±20 |

- **Controls:** +27.18 / +25.30 ms, 1.9 apart (±5 ✅), zero +26.24.
- **The model holds a sixth time:** +91.5 − 92.06 = −0.56 ms predicted, −5.45 measured.
- **Per track, OBS's SR NTP stays flat against arrival:** audio +1.19 → +1.04 ms, video −5.95 → −5.45.
- **MediaMTX:** 2 packets dropped before OBS's first SR at publish (21:17:03, before Manifold
  connected). Nothing else.
- **Mutes:** none (segment edge only). Manifold: 1 timebase write, 0 splices, 0 starvation holds.

**The root cause: OBS 32.2.2's WHIP output stamps 23.976 video +66.6 ppm fast.**
- **The mechanism.** OBS advances each video frame's RTP timestamp by `round(frame duration × 90000)`
  (`WHIPOutput::Send` → libdatachannel v0.24.2 `RtpPacketizationConfig::getTimestampFromSeconds`,
  `uint32_t(int64_t(round(seconds × clockRate)))`).
  - A 23.976 frame is 3753.75 ticks. OBS measures it in whole microseconds (41 708 or 41 709 µs, from
    `dts_usec`): 3753.72 or 3753.81 ticks, rounded to 3754 every frame.
  - +0.25 / 3753.75 = **+66.6 ppm**, accumulating, because the rounded steps are summed.
  - Audio is exact: 20 ms Opus = 960 samples.
- **Measured: the received RTP clocks against the wall clock** (`[WHEP-SR-RAW]` RTP against receive
  time, OLS over the session):

| run | video RTP vs wall | audio RTP vs wall | video − audio |
|---|---|---|---|
| `observe-abs-whep-mediamtx` (19:05, BLIPS_NOISE, §18.23) | +71.9 ppm | +5.4 ppm | **+66.5 ppm** |
| `observe-decklink-whep-cloudflare` (20:13, §18.24) | +60.8 ppm | −6.7 ppm | **+67.5 ppm** |
| `observe-abs-decklink-whep-mediamtx` (21:10, this run) | +60.1 ppm | −6.6 ppm | **+66.7 ppm** |

  - The common ±6–7 ppm is the wall clock (NTP-disciplined) against the Mac's host clock. The difference
    is what counts: +66.6 predicted.
  - Over 1380 s that is −91.9 ms of content against the received timestamps; measured −92.1, −92.05 and
    −92.06 ms.
- **What it explains:**
  - **"Audio delivered ~66 ppm slow"** (§18.22–§18.24, AV_SYNC_FINDINGS §6.9 before revision) is the
    same fact seen from the other side: the video is stamped fast.
  - **OBS's recordings are honest** (§18.24, this run): a recording stamps frames by count, not by
    summed rounded steps.
  - **Default MediaMTX's video-only upward staircase** (§18.21, §18.22): video timestamps run ahead of
    arrival, so its arrival anchor keeps re-anchoring earlier on the video track only.
  - **Cloudflare's +66 ppm SR slope, and OBS's own SRs under `useAbsoluteTimestamp: true`** (+60.5,
    +61.9 ppm): both map the timestamps to real time, so following them cancels the error. That is
    why both pass.
  - **The queue drain at ~65 ppm** under a flat applied offset (§18.22), and the level hold's walk on
    MediaMTX (§18.21).
  - **Sep 28's −89 ms** at +26 min (`step8-whep-soak`, `srfix-whep-mediamtx`, §18.22).
- **One unexplained case:** `level-whep-mediamtx` (Sep 30 16:47, §18.21).
  - Its content on the received timestamps held at −1.3 ms where this predicts ≈ −92, with the same
    66–68 ppm arrival skew.
  - §18.22's "OBS's timestamps were inconsistent on Sep 28 and honest on Sep 30" now rests on this
    session alone.
- **Ruled out: MediaMTX's audio re-stamping** (the open research of §18.24). The received audio RTP
  clock is within ±7 ppm of wall time in every run; the error is in the video timestamps.
- **Other frame rates, by arithmetic, not measured** (OBS's whole-microsecond frame durations × 0.09,
  rounded):
  - **No error:** 24, 25, 29.97, 30, 50 and 60 fps. Every rounded step equals the exact tick count
    (3750, 3600, 3003, 3000, 1800, 1500).
  - **59.94** (1501.5 ticks): durations step 16 683, 16 683, 16 684 µs, rounding to 1501, 1501, 1502,
    a mean of 1501.333. That is **−111 ppm** (video stamped slow), not merely "mixed".
- **Post-release work** (per-track arrival-rate estimation, a 23.976 signature detector, the upstream
  report, other relays): `docs/WHEP_TIMESTAMP_ROBUSTNESS.md`. Not duplicated here.

**Orchestrator: the DeckLink anchor is now the beep's own time.**
- `soak.mjs` converts the first `[AV-CONTENT] beep in` line's `host=` (CACurrentMediaTime) to wall
  time, using Node's `process.hrtime`, which reads the same mach clock (checked: the two interleave to
  the millisecond). It no longer uses the moment it noticed the line.
- The prompt is spoken in the background.
- `soaklog.mjs` `beepWallMs`, tested on this run's real line in `soaklog.test.mjs`.
