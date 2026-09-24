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

The ratio is **the same signal the synchronizer is given today** — `mirror.smoothedRate`, the τ=30 s
EMA whose derivation from the measured sender clock (§11.10 candidate 3, `FrameEngine.swift:2242`)
is sound and is not being reopened — plus a slow feedback trim that finally closes the loop the
slew-site note in `LiveClock.updateDepthLocked` says is open. **Nothing about the control law's
bandwidth changes. Only the place the multiply happens changes.** That is what keeps §5's separation
intact rather than merely "similar".

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

### 2.2 The control law

```
ratio = clamp( r_ff * (1 + k_p * e_f + i) ,  1 - B ,  1 + B )

  r_ff = 1 / smoothedRate          feed-forward, τ = 30 s EMA, UNCHANGED from today
  e_f  = EMA(err, τ_e = 5 s)       filtered position error, seconds
  i    = integrator, di/dt = k_i * e_f, clamped to ±B/2
  B    = 0.001                     ±0.1% = ±17.3 cents
```

Plus a hard **slew limit on `ratio` itself** of 2 ppm per 10 ms of host time, so no control action
can produce a glide faster than 0.035 cents/s regardless of what the terms above compute.

#### Why the ratio is `1 / smoothedRate` and not something new

`mirrorLiveAudio` today calls `synchronizer.setRate(Float(rateToPush), …)` with
`rateToPush = mirror.smoothedRate` (`FrameEngine.swift:2464`). Setting the *renderer's* rate to `s`
and resampling the *material* by `1/s` are the same operation applied at two ends of the same
pipeline: in both cases one media second of source content occupies `1/s` seconds of renderer
media time. **The bandwidth of the correction is bit-identical, because it is the same filter
output.**

That matters more than it sounds. §5's constraint is *"position/anchor mirroring is what holds
`timebase−clock` near zero; the smoothed rate deliberately does not follow the depth-correction
signal"*, and the τ=30 s derivation (`FrameEngine.swift:2242-2252`) rests on a measured
decomposition: `[WHEP-DRIFT]` puts the genuine sender ratio at **σ = 0.021%, 1.1 cents total
spread**, against a control loop swinging the full **±0.5%, 17.3 cents peak-to-peak** at 10 Hz — so
~94% of the rate signal is buffer-depth correction, not clock tracking. Reusing the same filter
output means that decomposition is preserved exactly and does not have to be re-argued.

#### What the feedback term adds, and why it is new capability rather than a knob

The slew-site note at `LiveClock.swift:1110-1150` states the gap plainly:

> `mirrorLiveAudio`'s push gate is OPEN-LOOP — its `predicted` comes from what it last pushed plus
> host time, never from `synchronizer.currentTime()` — so it CANNOT SEE that divergence. Nothing in
> the audio path detects it. Nothing corrects it. […] **Nobody designed a drift corrector; one fell
> out of the video path.** WHEP and SRT are bounded by ACCIDENT.

The divergence in question is the audio device crystal against mach time, measured at **−7.8 ppm**
on one machine (`HLSAudioTap.swift:48`) and explicitly *"a property of the output device, not a
constant"*. The feedback term measures it directly, on the only reading in the system taken on that
clock. **This is the first closed loop on the SRT and WHEP audio paths.** NDI already has one —
`serviceDesktopAudioAnchor` (`NDIService.swift:1918`) — and step 6 of the build plan folds it into
this one rather than leaving two.

#### The numbers, and what each is derived from

| quantity | value | derivation |
|---|---|---|
| ratio bound `B` | **±0.001 (±0.1%, 17.3 cents)** | 2.4× the worst measured sender offset (§5, 420 ppm). Below LiveClock's own ±0.5% rail by 5×, so the resampler can never chase a railed clock. |
| ratio slew limit | **2 ppm/s (0.035 cents/s)** | A continuous glide, not a step. §11.2's `liveAudioRateThreshold` comment correctly notes 0.35 cents is far under the ~5-cent pitch JND *as a step*; a glide three orders slower than that is not a candidate for audibility at all. |
| `k_p` | **0.05 s⁻¹** | Closed-loop position time constant 1/k_p = **20 s**. 200× slower than the P-loop's 0.1 s update and ~20× slower than the ~1 s depth wobble — the same separation-of-timescales argument τ=30 s already rests on. At 20 ms of error the P term alone reaches the rail. |
| `k_i` | **0.002 s⁻²** | Integrator time constant ~500 s. Removes the residual droop the feed-forward does not cover (δ ≈ 10 ppm / k_p ≈ 0.2 ms). Slow enough that it cannot participate in any transient. |
| `τ_e` | **5 s** | Above the depth sawtooth's fundamental (one frame interval, 41.7 ms p-p at 23.976 fps — §11.6) and above the ~1 s depth wobble, below the loop's own 20 s. |
| splice threshold | **50 ms** (see §2.4) | An order above the healthy error envelope (±13 ms local, §3) and an order below the coarse events it exists to catch (snap fires at `targetDepth + 0.2`). |

⚠️ **RESPONSE TIME IS DELIBERATELY SLOW AND THAT IS THE POINT.** At the rail the loop absorbs
1 ms of position error per second. A 6 ms error — today's typical push step (§11.2) — takes 6 s. A
10 ms error takes 10 s. **Those stop being events.** The entire class of correction that §11
measures as a 78 ms mute becomes a bias so small and so slow that no instrument other than the log
can see it happen.

### 2.3 How this avoids fighting the LiveClock P-loop

Four independent reasons, in descending order of how much they would survive a refactor:

1. **The coupling is one-way by construction.** LiveClock's only input is the video queue depth,
   pushed from `MetalVideoRenderer`'s tick (`MetalVideoRenderer.swift:2273`). The resampler touches
   neither the video queue nor `now()` nor any LiveClock state. There is no path by which a ratio
   change can reach the P-loop's error. Compare candidate 4 in §11.10, which the findings correctly
   flag as *"a change to the video control loop made for an audio symptom, which is how §9's decoder
   swap happened"*.
2. **Timescale separation, stated in numbers.** P-loop: 0.1 s update, ±0.5% authority. Resampler:
   20 s closed-loop time constant, ±0.1% authority, 2 ppm/s slew limit. The resampler's fastest
   possible action is 500× slower than the P-loop's update interval and its authority is 5× smaller.
   Even if it *were* coupled, it could not participate in the P-loop's dynamics.
3. **The feed-forward is the existing filter, not a second one.** There is one τ=30 s EMA and it
   remains the only thing that decides how much of the depth correction reaches audio.
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
  r_ff    =  (1 / smoothedRate) * (1 + srRate)
```

* **The OFFSET replaces `cushion` on this transport** — same slot, same sign convention, no longer a
  constant. `beginLiveAudio`'s parameter note already defines `cushion` as *"how far behind the
  mapping's senderPTS does this transport stamp its audio PTS?"*, which is exactly what the fit
  measures. The note needs no rewriting; the value simply stops being a guess.
* **The RATE joins the feed-forward term**, where a 60 ppm correction costs nothing. Correcting it
  by position instead would mean a `setRate` every few seconds — §5.1's mute, forever — which is the
  single strongest argument for doing this here rather than in the mirror.

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

⚠️ **AND THE OTHER THREE TRANSPORTS HAVE NO SUCH INPUT AND NEED NONE.** SRT, NDI and HLS each carry
audio and video on ONE timeline already — that is exactly why §3.1's SRT fix was a single argument.
This subsection is WHEP-only, and the fit must be absent rather than neutral on the others: a
degenerate fit over a stream that never reports would be a silent source of noise.

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
the 17-cent warble at 10 Hz that §5 says the smoothing exists to stop. It reaches the ratio only
through the τ=30 s feed-forward, attenuated exactly as today.

⚠️ **AND THE CLOUDFLARE DEPTH EXCESS IS NEITHER OF THESE.** §11.8 measures `depth − count×D` at
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
| 7 | **Pitch: ratio within ±0.1% and rate-of-change under 0.05 cents/s** | steady tone from OBS, FFT of the device capture in 5 s windows |
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

### Step 4 — close the loop

Feed-forward `1/smoothedRate` plus the PI trim, clamped, slew-limited. Position branch tolerance
raised to 250 ms so only a coarse event can still trigger a `setRate`.

**Measured:** `timebase − clock` bounded over 30 min with zero trend, per path, against §5.3;
`setRate` rows with non-zero rate fall to 1 + (coarse events); mutes/min falls to the coarse-event
count; pitch trace (criterion 7).

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

### Step 6 — NDI onto the same loop

Retire `serviceDesktopAudioAnchor`'s periodic re-anchor into the resampler's feedback term. NDI has
no LiveClock, so feed-forward is 1.0 and the loop is pure feedback — which makes this the cleanest
possible validation of the feedback term in isolation.

**Measured:** `[NDI-AUDIO] desktop timebase RE-ANCHORED` count → 0 over 30 min; device-output
mutes/min → 0 against step 2's baseline; the crystal ppm the loop settles at agrees with the ppm
those re-anchor lines used to report (they already print it — *"the implied ppm says by how much"*).

⚠️ **If open question 1 comes back "a same-valued `setRate` does not mute", this step is optional
rather than required** — but it is still worth doing, because it removes the last open-loop
re-anchor in the app and it is the one path where the feedback term can be measured without the
feed-forward confounding it.

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
