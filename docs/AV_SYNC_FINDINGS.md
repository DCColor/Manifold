# Three A/V sync defects, measured — and the one number that hid all of them

**Measured 2026-09-23, to answer open questions 1, 2 and 4 of `docs/AUDIO_RESAMPLER_DESIGN.md`
before build step 1 of that design.**

*Measured fact, inference and open question are labelled separately, as in
`docs/LIVECLOCK_AUDIO_MIRROR_FINDINGS.md`. No app code was changed to produce anything in this
document.*

---

## TL;DR

Three separate defects, on three transports, all of them lip-sync, all of them shipping:

| | what it is | size |
|---|---|---|
| **SRT** | `beginLiveAudio(cushion:)` was passed `targetDepth` at a call site whose own comment predated the correction that says it should be 0 | **audio ~200 ms LATE**, constant — ✅ **FIXED 2026-09-23**, see §3.1 |
| **NDI** | the 250 ms presentation lead is real, deliberate and correctly described in `NDIService`; it was shipped on a `BUGS.md` justification that calls it "monitoring latency", which it is not | **audio ~230 ms LATE**, constant, by design |
| **WHEP** | no RTCP sender-report handling anywhere, so the audio and video RTP clocks are never mapped to a common wall clock — `SSRCs ASSUMED aligned` | **arbitrary per session**, ≥136 ms of spread measured |

⚠️ **AND ONE REASON WHY NONE OF THEM HAS EVER BEEN SEEN.** `liveAudioDrift` returns
`(timebase + cushion) − clockSeconds`. The cushion cancels. The only number in the app that pairs
the audio timebase against the video clock has the suspect term **removed from it by construction**,
and it read **+3.4 to +4.0 ms on every live run in this document**, including the one that was 99 ms
out. It is a correct measurement of the mirror's error and it is not a measurement of lip-sync.

Two further results, from a separate AVFoundation harness:

* **A rate write with an UNCHANGED rate value mutes the renderer, 19/19.** §11.11 measured that
  every rate *change* mutes; it never held the value constant, and that was the open question.
  There is no cheap `setRate`.
* **A muted renderer keeps advancing its timebase and keeps consuming buffers.** Slope change
  across a 20 s mute: −0.4 ppm. Position continuous to 0.023 ms. Consumption flat.

---

## 1. Method

### 1.1 The fixture

`~/Desktop/manifold-avsync/flash-beep-25p-60s.mov` — 1920×1080, 25p, 60 s. One **full-white frame**
and one **40 ms 1 kHz beep** at each whole second, generated together with `ffmpeg`:

```
-vf drawbox=…:enable='eq(mod(n,25),0)'
-i aevalsrc='0.4*sin(2*PI*1000*t)*lt(mod(t,1),0.04)'
```

⚠️ **THE BEEP IS SYNTHESISED PER SAMPLE, NOT GATED PER FRAME, AND THE FIRST VERSION WAS WRONG.**
Gating a `sine` source with `volume=…:enable=…` evaluates the timeline **once per audio frame**, so
the onset quantised to 1024 samples (21.3 ms) and jittered ±10 ms. `aevalsrc` evaluates per sample.

**Measured on the finished fixture: beep onset minus white frame = +0.0417 ms, sd 0.0000** — two
samples, constant. The fixture's own offset is known and subtracted, not assumed away.

An MP4 variant (video stream-copied, audio AAC 192k) exists for Chrome, which will not play PCM in
a MOV container. **Measured: identical intrinsic offset, sd 0.000** — the AAC round trip did not
move the beep relative to the flash.

### 1.2 Capture — two OBS instances, and why

* **Instance 1 — streamer only.** Plays the fixture as a Media Source (Loop on, **Audio Monitoring
  off**, Mic/Aux muted) and sends it: local SRT, WHIP→Cloudflare, SRT→Cloudflare, or NDI.
* **Instance 2 — recorder only.** Display Capture + **macOS Audio Capture** (ScreenCaptureKit) to
  one file. Video and audio in one container on **one clock**, which is the only property the
  measurement actually needs.

⚠️ **THE MONITORING SWITCH IS LOAD-BEARING.** If instance 1 monitors the file it is sending, the
recorder captures the source *and* the player, two sources summing — §11.11's method failure 1,
which voided three recordings and inverted an answer. Verified per run (§1.5).

⚠️ **ffmpeg's avfoundation AUDIO INPUT IS NOT USABLE AS A TIMING INSTRUMENT ON THIS MACHINE, AND IT
FAILS SILENTLY.** Measured: a 10 s capture wrote **9.08 s**, at every setting tried, with every
device at a true 48 kHz. Dropped samples are packed contiguously rather than left as gaps, so the
audio timeline is **compressed** and its alignment to the video is destroyed. It was caught only
because the fixture is a 1 Hz train and a gate checked for that — beeps arrived 0.851 s apart. An
offset measured from such a capture walks, with nothing else reading unhealthy.

### 1.2b The sender probe — the term the player controls cannot remove

⚠️ **ADDED 2026-09-23, AFTER IT WAS NEEDED. Every raw stream figure in §2 carries an unmeasured
sender term, and this is how to remove it.**

A player control (§1.3) subtracts the *player's* compositor and output latency. It cannot subtract
the **sender's own audio-versus-video error**, which is a property of OBS's encoder and mux — or, on
Cloudflare, of its transcoder — and which differs per path and, as measured below, per session.

The probe needs no player, no display, no recorder and no control:

```sh
ffmpeg -y -i "<the stream URL>" -t 40 -c copy ~/Desktop/sender_probe.mkv
```

then measure the fixture's flash-to-beep offset **inside that file, on its own PTS**. What comes out
is the sender's A/V error, full stop.

⚠️ **READ BOTH STREAMS ON THE CONTAINER TIMELINE, WITH `-copyts`.** The probe measured here reported
`Stream #0:0: … start 0.044000` for video against audio at 0. Extracting the two separately without
`-copyts` rebases each to zero and puts that 44 ms straight into the answer. Video PTS come from
`signalstats` under `-copyts`; the audio's first PTS comes from `ashowinfo` and the sample index is
offset by it.

**Measured, OBS local SRT, 2026-09-23 16:45: −82.0 ms, sd 0.0** — OBS sends audio 82 ms *early*.

📌 **AND IT IS NOT A CONSTANT OF THE PATH.** Applying −82.0 ms to the same route's 14:53 run predicts
≈ +131 ms where +203.9 ms was measured, so OBS's local-SRT A/V genuinely differed across an output
restart. The morning's value cannot be recovered. **This is the whole reason §3's conclusions rest
on the arithmetic rather than on the raw measurements** — the arithmetic is computed from Manifold's
own logged quantities and does not contain a sender term at all.

---

### 1.3 Per-player controls

Every player has its own compositor and audio-output latency, and OBS's own capture adds a constant.
**A single absolute number here means nothing.** Each player therefore gets its own zero:

* **Manifold's control** — Manifold playing the fixture from disk. Video and audio are both
  scheduled by the one synchronizer timebase, so its A/V offset is 0 by construction.
  **Measured +29.6 ms, sd 0.0.**
* **Chrome's control** — Chrome playing the MP4 from `file://`. **Measured +47.1 ms, sd 0.1.**

⚠️ **CHROME'S CONTROL IS IMPERFECT AND IS USED ANYWAY.** Chrome plays a local file through
`<video>`/AAC and a WHEP stream through WebRTC/Opus; those are different internal pipelines. The
control captures Chrome's compositor and output latency, which is the dominant common term. It is
good enough to attribute a 99 ms error and is not good enough to resolve 20 ms. Stated, not hidden.

### 1.4 The frame-grid bias — a known, one-sided, uncancelled term

The fixture is 25p; OBS's output for every stream run was **30 fps**; the recorder captures at
30 fps. The 25→30 stage shows the white frame at its next 30 Hz sample, so the flash always reads
**late**, which makes the offset always read **low**.

Measured directly, from flash run-lengths in the captures:

| | flash visible for |
|---|---|
| control — 25p file → Manifold → 30 fps capture | 2 captured frames, 27/27 |
| stream run — 25p → **OBS 30p** → Manifold → 30 fps capture | 1 frame ×32, 2 frames ×9 |

**So every stream-run figure below carries up to +33.3 ms of one-sided bias against the file
control.** It is bounded, it is signed, and it is **common to all four stream runs**, so it cancels
in comparisons *between* transports — which is where the discriminating work is done.

📌 **THE ACCEPTANCE RUNS FOR THE RESAMPLER MUST RETURN TO 23.976, NOT 30.** This is not tidiness.
§11.6 shows the depth sawtooth ripple **is** one frame interval — 41.7 ms at 23.976, 33.3 ms at 30 —
and the rail crossings that set the `setRate` cadence follow from it. Measured here at 30 fps:
**7.1 / 23.1 / 30.5 setRate per minute** on local SRT / Cloudflare SRT / WHEP, against §11.4's
4.3 / 12 / 9 at 23.976. Mutes-per-minute at 30 fps is a different experiment and cannot be compared
with 4.95 / 11.08 / 7.32.

### 1.5 Gates — run before any result is read

Carried from §10's rule (verify the instrument) and §11.11's addition (verify the **subject** is
singular). Every run in §2 passed all of them.

| gate | what it catches | control reading |
|---|---|---|
| **beep count vs duration** | a second source ADDS onsets | 41 beeps in 41.4 s |
| **fit to a free-phase 1.000 Hz grid** | onsets that are not the fixture | median \|residual\| 0.04 ms |
| **one burst per beep within 300 ms** | two players summing | 0/20 doubled |
| **level between beeps** | anything else sounding in the capture | **−240 dBFS, exact digital silence** |
| **injected-offset gate on the analyser** | the analyser itself | 0 / +250 / −120 ms injected → **−0.0 / +250.0 / −120.0, sd 0.0** |

⚠️ **AFTER EVERY MANIFOLD RELAUNCH, RE-PICK MANIFOLD IN THE RECORDER'S APPLICATION AUDIO CAPTURE.**
The recorder's macOS Audio Capture source is scoped to the Manifold *application*, and every run
relaunches Manifold with a new PID. A stale PID gives a **silent audio track while the source's
meter in OBS keeps moving**, because the meter follows the source and the recording follows the
mixer. It cost one full run here, and it presents as "the fix broke audio" — the app's own log read
perfect throughout (2.88 M frames enqueued, `status → rendering`, buffers contiguous).

App-scoped capture is nonetheless the right choice: it makes "nothing else audible" structural
rather than procedural, so a notification sound cannot contaminate a capture.


⚠️ **THE FIRST VERSION OF THE PERIODICITY GATE ASKED THE WRONG QUESTION AND FAILED A GOOD RUN.** It
required 90% of inter-beep **spacings** within 10 ms of 1.000 s — a test of transport jitter, not of
provenance. Cloudflare SRT failed it at exactly 90.0% while its beep **count** was exactly right and
every outlier paired as long-then-short, i.e. a beep *displaced*, never an extra one. **A second
source adds onsets; it does not move ours.** The gate now tests count and grid fit, and reports a
*missed* beep rather than treating it as contamination — on that path a missed beep is most likely a
§11 renderer mute landing on one.

📌 Recorded because it will happen again: the fix was to change the gate's **shape**, not its
threshold. Loosening a threshold until a run passes is the failure this whole line of work is about.

---

## 2. The eight runs

Positive = **audio lags picture**. "vs own control" subtracts that player's own zero (§1.3).
Stream runs carry up to **+33 ms** of one-sided frame-grid bias (§1.4), always reading low.

| # | player / path | raw | **vs own control** | arithmetic | grid resid | sd |
|---|---|---|---|---|---|---|
| 1 | **Manifold, file** | +29.6 | **0** — Manifold's reference | 0 | 0.04 ms | 0.0 |
| 2 | Manifold, local SRT | +233.5 | **+203.9** | **+246.2** | 3.0 ms | 15.7 |
| 3 | Manifold, Cloudflare SRT | +195.4 | **+165.8** | **+246.0** | 2.0 ms | 15.0 |
| 4 | Manifold, WHEP *(ingest A)* | −69.3 | **−98.9** | −3.4 | 1.9 ms | 10.5 |
| 5 | Manifold, NDI | +259.7 | **+230.1** | — | 0.04 ms | 15.7 |
| 6 | **Chrome, file** | +47.1 | **0** — Chrome's reference | — | 0.08 ms | 0.1 |
| 7 | Chrome, WHEP *(ingest B)* | +36.6 | **−10.5** | — | 0.07 ms | 0.1 |
| 8 | Manifold, WHEP *(ingest B)* | +66.3 | **+36.7** | −3.5 | 1.77 ms | 15.4 |

**Runs 7 and 8 are the same Cloudflare ingest, minutes apart, same recorder** — designed that way so
the only variable between them is the player.

⚠️ **EVERY "vs own control" FIGURE IN THIS TABLE CARRIES AN UNMEASURED SENDER TERM, AND THAT IS WHY
THE CONCLUSIONS IN §3 REST ON THE ARITHMETIC COLUMN.** The control subtracts the player's latency;
it does not subtract the sender's own audio-versus-video error (§1.2b), which differs per path and
per session — measured at **−82.0 ms** on OBS local SRT afterwards, and demonstrably different on
the same route ninety minutes earlier. This is exactly the "residuals vary by path (−42, −80,
−95 ms)" noted below, and it has a cause rather than a mystery. The arithmetic column is computed
from Manifold's own logged quantities and contains no sender term, so it is the column that carries
the argument; the measurements corroborate it once the sender is removed, as §3.1 now does.

**"arithmetic"** is the independent cross-check available without touching app code:

```
A/V offset  =  cushion  −  (timebase−clock as logged)
```

`liveAudioDrift` reports `(timebase + cushion) − clock`, so the timebase sits at `clock − cushion + L`
where `L` is the logged value. Video frame with source PTS *P* is presented when `now() == P`; audio
buffer with source PTS *P* is heard when `timebase == P`. The difference is `cushion − L`. It is
exact **for a transport whose audio and video share one timeline** — which is true for SRT and false
for WHEP (§3.3).

⚠️ **NDI HAS NO ARITHMETIC COLUMN** because it does not mirror a `LiveClock` mapping at all; it
anchors directly (`anchorLiveAudio`) and its offset is the `lead` constant. See §3.2.

**NDI is the cleanest of the five Manifold runs** — grid residual 0.04 ms, equal to the file
control — because its sender is on this machine and essentially uncompressed, so it carries almost
no sender-side A/V term. SRT and WHEP carry the sender's own encode, which is why their residuals
(−42, −80, −95 ms against the arithmetic) vary by path: local SRT is OBS's encoder while
Cloudflare's SRT egress is a **transcode** (§9), each with its own relative audio/video delay.

---

## 3. The three defects

### 3.1 SRT — the cushion was a stale value, and audio lagged picture by ~200 ms  ✅ FIXED

`SRTFrameRouter.swift:532`:

```swift
audioSink = beginLiveAudio?(Self.targetDepth)      // 0.250
```

under a comment reading *"the cushion must match the transport whose clock is being mirrored,
because it is the steady-state lead the control loop holds for THIS route."*

**That reasoning is explicitly retracted by `beginLiveAudio`'s own parameter note**, which states
the cushion means *"HOW FAR BEHIND THE MAPPING'S `senderPTS` DOES THIS TRANSPORT STAMP ITS AUDIO
PTS?"* and that *"a transport that stamps absolute sender time passes 0"*. WHEP was corrected from
`targetDepth` to `0` for exactly this reason when its receiver moved to absolute sender time. **SRT
stamps absolute sender time too** — since §9, its sample axis is pinned to the program's own
`sourcePTS` — and its call site was never revisited.

Three independent lines agree:

| line | figure |
|---|---|
| source reading | the cushion should be **0**, so the error should be **+250 ms** |
| arithmetic, from each session's own log | **+246.2 ms** (local), **+246.0 ms** (Cloudflare) |
| measurement | **+203.9 ms** (local), **+165.8 ms** (Cloudflare), both reading low by up to 33 ms of grid bias plus the sender's own A/V term |

**No sender-side encode term is a fifth of a second.** OBS's encoder delays are tens of milliseconds.

#### ✅ FIXED 2026-09-23 — applied, and verified the same way

```swift
audioSink = beginLiveAudio?(Self.targetDepth)   →   audioSink = beginLiveAudio?(0)
```

One functional line at `SRTFrameRouter.swift:532`; the rest of the diff is the comment, rewritten to
`beginLiveAudio`'s parameter note and carrying the before-numbers and the reason `timebase−clock`
cannot catch a regression of it.

**Verified on local SRT, 30 fps, same fixture and recorder as the before-runs.** Figures are
restricted to the single SRT session the capture covers — the log contained three, and pooling them
gave a wrong `setRate` rate on the first pass:

| | before | **after** |
|---|---|---|
| `timebase−clock` median | +3.40 ms | **+1.30 ms** |
| **arithmetic A/V** (`cushion − (timebase−clock)`) | **+246.6 ms** | **−1.3 ms** |
| renderer lead (`depth + cushion − L`) | 495 ms | **249 ms** |
| `setRate` / min | 7.1 | **7.1** |
| buffer contiguity | 3571/3572 | **2840/2841** |
| automatic renderer flushes | 0 | **0** |
| `[LIVECLOCK] depth` | 0.249 s | 0.250 s |

**And the flash-and-beep, with the sender's own error measured and removed:**

```
measured vs control   =  Manifold  +  sender  +  recorder grid
     −122.2 ms        =  Manifold  +  (−82.0) +  (0 … −33.3)
  →  Manifold ≈ −7 to −40 ms,  against an arithmetic prediction of −1.3 ms
```

**Manifold's own A/V error after the fix is within one video frame of zero, where before it was
~250 ms.** The −122 ms raw reading was almost entirely OBS sending audio 82 ms early.

**No crackle or distortion**, on four independent checks: heard clean in the room; **0** automatic
renderer flushes; 2840/2841 buffers contiguous; and the renderer lead is **249 ms**, comfortably
above the ~150 ms floor the NDI lead ladder measured for this same renderer. The lead arithmetic
`depth + cushion − (timebase−clock)` is exact, and both terms are logged — so this is measured, not
argued.

**`setRate`/min is unchanged, and it could not have changed.** `positionError` compares
`target = senderPTS − cushion` against a `predicted` built from a previously-pushed `target`; both
shift by the same constant, so the push gate is algebraically invariant to the cushion, and
`rateMoved` never mentions it.

⚠️ **THE MEASUREMENT CHAIN WAS RE-VALIDATED BEFORE ANY OF THIS WAS BELIEVED.** An 78 ms shift in the
residual appeared first and could have been the chain drifting. **NDI — untouched by this fix — was
re-measured and read +217.4 ms against the morning's +230.1 ms**, a 12.7 ms difference inside the
frame-grid band. The chain was stable; the shift was the sender, and the probe then measured it.

#### Cloudflare SRT — FIXED BY CONSTRUCTION, NOT RE-MEASURED

📌 **Recorded as such deliberately, so nobody later reads a missing number as a missing fix.** The
cushion is a single argument on the one code path both SRT routes share — `SRTFrameRouter` has one
`beginLiveAudio` call site — and both routes measured **+246.2 ms and +246.0 ms** by arithmetic
before the change, i.e. identically. There is no per-route term in the quantity that was wrong.

What is *not* established for Cloudflare is its **sender term**: its SRT egress is a transcode of the
WHIP ingest and will have its own audio-versus-video error, which has never been measured. That is a
property of Cloudflare, not of this fix, and it is characterised with the §1.2b probe against the
egress URL whenever someone wants the absolute number.

#### The fix as it stood before it was applied

One argument, plus rewriting the stale comment above it:

```swift
audioSink = beginLiveAudio?(Self.targetDepth)   →   audioSink = beginLiveAudio?(0)
```

`mirror.cushion` has exactly two consumers — `mirrorLiveAudio`'s `target = m.senderPTS - cushion`
and `liveAudioDrift`, which adds it back — so this is genuinely a one-line change.

⚠️ **AND IT IS SAFE ON THE ONE AXIS THAT COULD BITE, WHICH IS WORTH STATING BECAUSE IT IS NOT
OBVIOUS.** `BUGS.md`'s NDI lead ladder measured this same renderer crackling below ~150 ms of lead.
SRT's renderer currently holds ≈**500 ms**: `now()` runs `targetDepth` (250 ms) behind the sender's
live edge, and the cushion puts the timebase another 250 ms behind that. Removing the cushion leaves
≈**250 ms** — still comfortably above the measured threshold, and equal to the lead NDI chose
deliberately.

### 3.2 NDI — the lead is a lip-sync cost, and the code says so

Measured **+230.1 ms** against a designed **+250 ms**, on the cleanest capture of the set.

**This is not a defect in `NDIService`. The file states the cost correctly**, at
`NDIService.swift:732-742`:

> ⚠️ **THIS IS A LIP-SYNC OFFSET AND IT IS NOT FREE: NDI video is stamped on the same clock and
> presented at the next display tick, so desktop audio lands `lead` LATE against the picture.** SDI
> is unaffected — that path reads the tap keyed to video PTS and never consults this timebase.

The lead exists to keep `lead` seconds of audio queued in the renderer, because the renderer crackles
without it (BUGS.md's 40/150/250/300/400/600 ms ladder). Video is stamped `monotonicNow()` at pull
(`NDIService.swift:718`) and presented at the next display tick, so it is **not** delayed to match.

**What is wrong is the justification that shipped it.** `BUGS.md` reads:

> …costs 250 ms of desktop **monitoring latency** that a QC operator will not notice.

Monitoring latency means picture **and** sound arrive late *together*, and is harmless. This is a
quarter-second **lip-sync** error, and is not. **The code knew; the entry that shipped it did not,
and the entry is what anyone planning from this file reads.** Corrected in place, 2026-09-23.

> **Inference, not measurement:** that ~250 ms is objectionable in use. It is far outside every
> published detectability bound for audio-late (ITU-R BT.1359 puts detectability at about 125 ms
> late), so the inference is strong — but nobody has been asked to judge it.

### 3.3 WHEP — no RTCP sender-report mapping, so lip-sync is arbitrary per session

**The measurement that settles it**, runs 7 and 8, same ingest, minutes apart, same recorder:

| player, same ingest | vs own control |
|---|---|
| Chrome (WebRTC) | **−10.5 ms** |
| Manifold | **+36.7 ms** |

and, on a **different** ingest earlier the same hour:

| | vs own control | `timebase−clock` in that session |
|---|---|---|
| Manifold, ingest A | **−98.9 ms** | +3.40 ms |
| Manifold, ingest B | **+36.7 ms** | +3.45 ms |

**A 136 ms swing between two sessions of the same transport on the same binary, while the app's own
number moved by 0.05 ms.**

**The cause, from source.** The only RTCP anywhere in the WHEP path is `a=rtcp-fb` parsing for PLI
(`WHEPClient.swift:654-669`). **There is no sender-report handling at all.** Video PTS is the video
SSRC's unwrapped RTP timestamp ÷ 90000; audio PTS is the audio SSRC's ÷ 48000. Two independent
bases, related by nothing. `WHEPAudioReceiver` says so in the log, every session:

> `[WHEP-AUDIO] live clock anchored — audio flowing on the SENDER axis (absolute RTP time, not
> rebased through now(); held N packet(s) waiting for the first video frame; **SSRCs ASSUMED
> aligned**)`

RTCP sender reports are the mechanism RTP provides for exactly this: each report carries an NTP
wall-clock time paired with that stream's RTP timestamp, and a receiver maps both streams onto the
common wall clock. Chrome's WebRTC stack consumes them. Manifold does not.

⚠️ **ADDED 2026-09-23, LATER THE SAME DAY: THE CHROME COMPARISON IS WEAKER THAN IT READS ABOVE, AND
A SECOND SERVER IS WHAT SHOWED IT.** Cloudflare's answer gives the two m-sections **different
CNAMEs and different msid stream ids** (`PxgkpBsC` / `CfFlPcUE`). CNAME is what RFC 3550 uses to
declare two streams synchronisable, and Chrome pairs streams for A/V sync by MediaStream — so
**Chrome most likely was not synchronising these two either**, and run 7's −10.5 ms may be one
session's luck rather than evidence that SR consumption fixes the problem. By this document's own
rule, two sessions of the same transport are not a repeat measurement; one session of a second
player is not a mechanism.

**This is not a reason to doubt the defect, and it is a reason to doubt the attribution.** The
defect is established from source and from the 136 ms swing, neither of which involves Chrome. What
is NOT established is that a receiver doing the RTCP work correctly ends up in sync **on this
ingest** — and if Cloudflare's two SRs turn out to be on unrelated clocks, the fix would need
something else. **Cheap test before building anything:** compute the implied offset from several
successive SR pairs; stable to well under a millisecond over a minute means one sender clock and the
alignment is sound.

📌 **AND THE DIFFERENT CNAMEs ARE CLOUDFLARE'S CHOICE, NOT NORMAL WHEP — MEASURED, NOT ASSUMED.**
The local MediaMTX server set up the same day (`docs/BUGS.md`, *"MediaMTX is set up locally as the
second WHIP/WHEP test server"*) answers with **one CNAME and one MediaStream** across both
m-sections. It also produces the **same 1.0/s sender-report cadence**, so the mechanism the fix
depends on exists on both servers.

⚠️ **THE SPREAD IS NOT BOUNDED BY ANYTHING WE MEASURED.** Two sessions gave −99 and +37 ms. Nothing
in the mechanism limits it to that range; the offset is whatever the two senders' RTP bases happen to
differ by after the CDN, on the day. A session could be worse.

---

## 4. Why `liveAudioDrift` cannot see any of this — the transferable part

`FrameEngine.liveAudioDrift`:

```swift
return (timebase + liveAudioCushionValue) - clockSeconds
```

The comment above it is correct about what it is for:

> The timebase deliberately runs `cushion` behind the live clock, so that offset is removed here.
> What remains is the MIRROR ERROR — how far the audio timebase has slipped from the mapping it is
> tracking — which is what this is read for.

**It is the right instrument for the mirror and it is structurally incapable of measuring lip-sync**,
for three separate reasons, one per defect:

1. **SRT.** The cushion is added back, so a *wrong* cushion cancels exactly as a right one does. The
   number reads clean whether the value is 0.250 or 0.
2. **NDI.** It never runs — `liveAudioDrift` is keyed on `mirror.mirrored`, which a directly-anchored
   session does set, but NDI's offset is the `lead`, which this expression does not contain.
3. **WHEP.** It compares the timebase against `LiveClock.now()`, and **both are on the video RTP
   clock**. An audio stream on a differently-based RTP clock is outside the comparison entirely.

Measured across every live run in this document: **+3.40, +3.45, +3.80, +4.00 ms.** Four sessions,
three defects, one of them 99 ms, and the spread of the instrument is 0.6 ms.

### The rules this produces

* **An instrument that subtracts a term cannot test that term.** `liveAudioDrift` removes the
  cushion in order to be readable, which is correct for its purpose and is precisely what makes it
  blind to the cushion being wrong. When a constant is suspect, measure something that does not
  contain it.
* **A/V sync is not measurable from inside one half of the pipeline.** Every number in the app is
  computed on the audio side against the audio side's idea of the clock. The only instruments that
  found these are outside the process entirely.
* **Per-player controls, not absolute numbers.** Three of the eight runs above exist only to
  establish zeros. Without them the other five are unattributable.
* **A second player is the cheapest attribution there is.** One Chrome run split "Manifold is wrong"
  from "the stream is wrong" in forty seconds, after an hour of reasoning could not.
* **Measure the sender, do not model it.** The residual between prediction and measurement was
  written up as "the sender's own encode delay, which cannot be separated from inside Manifold" —
  true about Manifold, and wrong about the problem. `ffmpeg -c copy` of the stream and a
  flash-to-beep measurement on its own PTS gives that term directly, with no player, no display and
  no control to subtract. It took one command and it turned an 78 ms mystery into −82.0 ms with
  sd 0.0. **When a term is called unseparable, check whether it is merely unseparable from where you
  happen to be standing.**
* **Re-validate the chain before believing a surprise.** The 78 ms shift could have been the
  instrument drifting. Re-measuring NDI — untouched by the change under test — against its own
  earlier value settled that in one run, before any effort went into explaining a number that might
  not have been real.
* **Two readings of the same transport on different sessions are not a repeat measurement** — as
  runs 4 and 8 show, they can differ by 136 ms. Same-ingest back-to-back is what makes a comparison
  mean anything.

---

## 5. The AVFoundation harness — open questions 1 and 2

`~/Desktop/manifold-audible-events/harness-fg/` (outside the repo, deliberately: it is a probe of
AVFoundation, not of Manifold). Helper code — reference loading, format and sample-buffer
construction — is **byte-identical to the §11.11 harness, verified by diff**, so case A is
comparable with that table. Same `O_EXLOCK` lockfile, so the two can never run together.

Captured through Audio Hijack (licensed, so no trial-noise injection), **Application → Recorder →
Output Device**, which captures the app rather than the device mix. Gates: **0.0000% energy
15–20 kHz**, **peak correlation 1.000** (two equal sources would read 0.707).

### 5.1 Open question 1 — does a rate write with an UNCHANGED rate value mute? **YES**

| case | what it does | changes | **muted** | core (median) | envelope |
|---|---|---|---|---|---|
| **A** control | rate **changes** 1.0000↔1.0002, ±6 ms step | 10 | **10** | 63 ms | 75 ms |
| **F** | **rate HELD at 1.0**, ZERO position step | 19 | **19** | 63 ms | 82 ms |
| **F+** | **rate HELD at 1.0**, +6 ms position step | 19 | **19** | 63 ms | 78 ms |
| **E** floor | nothing at all | 0 | **0** | — | — |

Control A shows 10 of 19 because the recorder was started 29.4 s into the run; **the analysis found
that offset independently, from the first marker gap, before it was mentioned.** Only changes inside
the recorded window are counted — an early version counted all 19 and made the control read 10/19,
refusing the run on a denominator it had invented.

**§11.11's six cases every one CHANGED the rate.** F and F+ hold it constant and mute just as
reliably, with and without a position step. **It is the write, not the change.** The design's
premise — that the only lever is the *number* of `setRate` calls — is now established from a second
direction.

📌 **F+ WAS ADDED BEYOND THE QUESTION ASKED, AND IT IS THE ONE THAT MATCHES NDI.**
`serviceDesktopAudioAnchor` only fires once its offset has passed tolerance, so NDI's re-anchor is
never a zero step. F and F+ together separate "the rate write" from "the position write" at constant
rate: both mute, identically.

### 5.2 Open question 2 — does a muted renderer keep advancing and consuming? **YES, both**

`renderer.isMuted = true` for 20 s mid-case, **no rate writes at all**, clock sampled at 20 Hz with
the read pair recorded and samples discarded above 200 µs of spread.

| segment | timebase slope | vs mach | buffers/s |
|---|---|---|---|
| before mute (19.0 s) | 1.000007300 | +7.3 ppm | 46.89 |
| **MUTED (17.9 s)** | 1.000006948 | **+6.9 ppm** | **46.86** |
| after mute (18.9 s) | 1.000006804 | +6.8 ppm | 46.93 |

* slope change across the mute: **−0.4 ppm**
* media time projected across the 20 s mute from the 5 s before it: **max error 0.023 ms**
* `isReadyForMoreMediaData` false on **0 of 1200** samples; renderer events: **0**
* `isMuted` does silence the output: 20.00 s core, **960,135 samples at exact bit-zero**

**Consequence for the design: the proposed "suspend the integrator while muted" insurance is
unnecessary and has been removed.** The loop stays valid through a mute.

📌 **INCIDENTAL, AND IT CONTRADICTS AN ASSUMPTION MADE EARLIER THE SAME DAY.** This machine's audio
device crystal reads **+6.8 to +7.3 ppm** against mach time. The HLS work measured **−7.8 ppm** on
another machine — opposite sign, same order. `HLSAudioTap.swift` is explicit that such figures are
properties of the output device; this is the second data point that proves it.

📌 **AND A CORRECTION MADE IN THE SAME SESSION.** On seeing question 1's answer it was claimed that
build step 6 (moving NDI onto the resampler's loop) became urgent, because NDI re-anchors with
`setRate(1.0, …)` and every one is now known to mute. **The NDI log says otherwise: 0 re-anchors in
40 s, 3 `setRate` rows all session.** At ~7 ppm against a 10 ms tolerance that is one re-anchor per
~21 minutes — about 3 mutes an hour. Step 6 is right for correctness and is not urgent.

---

## 6. What is not answered here

* **WHEP's per-session offset has no fix in this document.** It needs RTCP sender-report handling,
  which is a change to the WHEP receive path, not to the audio mirror, and it needs its own
  measurement. Two sessions are not a distribution.
* ✅ **The residuals between arithmetic and measurement vary by path** (−42, −80, −95 ms) — **this
  was listed as unexplained and now has a cause.** Part is the bounded frame-grid bias; the rest is
  the sender's own audio-vs-video error, which is **not** a property of the path but of the session:
  measured at **−82.0 ms** on OBS local SRT, and demonstrably different on the same route ninety
  minutes earlier. The §1.2b sender probe removes it in forty seconds and needs nothing but ffmpeg.
  **The per-run sender terms behind the eight-run table were never captured and cannot be
  recovered**, which is why §3 argues from the arithmetic column.
* **Cloudflare SRT's sender term has never been measured.** Its SRT egress is a transcode of the
  WHIP ingest and will carry its own A/V error. Not needed for the cushion conclusion (§3.1), and
  required for any absolute Cloudflare figure.
* **Nothing here re-measures §11's mutes-per-minute**, and the 30 fps runs must not be read as if it
  did — see §1.4.

---

## 7. Reproducing this

```
# fixture (regenerates identically; verify its own offset before trusting it)
~/Desktop/manifold-avsync/flash-beep-25p-60s.mov
~/Desktop/manifold-avsync/avsync.py <capture.mov> --label "..."

# the analyser's own gate, which must pass before any run is read
ffmpeg -i flash-beep-25p-60s.mov -af "adelay=250|250" -c:v copy gate_250.mkv
python3 avsync.py gate_250.mkv       # must report +250.0 ms, sd 0.0

# the AVFoundation harness (cases A, F, F+, G, E)
~/Desktop/manifold-audible-events/harness-fg/MuteTestFG.app     # launched BY Audio Hijack
~/Desktop/manifold-audible-events/harness-fg/analyse_fg.py --capture <recording.wav>
```

```
# the sender's own A/V error — no player, no display, no control
ffmpeg -y -i "<stream URL>" -t 40 -c copy ~/Desktop/sender_probe.mkv
# then measure flash-to-beep INSIDE it, both streams read with -copyts (see §1.2b)
```

The minimal WHEP reference player used for runs 6–7 is at
`~/Desktop/manifold-avsync/whep-player/` — one HTML file, no libraries, with a stdlib proxy that
holds the endpoint so the page stays same-origin and the URL never reaches the browser.

⚠️ **ONE THING THAT WILL WASTE AN HOUR IF IT IS NOT WRITTEN DOWN.** Cloudflare's WAF returns
**403 with an HTML block page** to a POST carrying `Python-urllib`'s default User-Agent. With a
browser User-Agent the identical request reaches the endpoint, which then answers on its merits
(`400 SDP contains no ice-ufrag` for a junk offer). **The 403 is a firewall verdict on the client,
not on the WHEP request, and it is indistinguishable from "the stream is offline" if you read only
the status code.** The proxy forwards the browser's own User-Agent for this reason.
