# LiveClock's audio mirror stops exactly when it is needed most

**A saturation dead band in the mapping-publication gate, found 2026-09-21 when SRT audio drifted
on the Cloudflare path and not on a local one**

*Measured fact, inference, and open question are labelled separately throughout. Companion to
`AUDIO_PATH_FINDINGS.md`, which covers the August meter audit; this document is about the clock.*

> ## ⚠️ READ §9 FIRST IF YOU ARE HERE ABOUT DISTORTED LIVE AUDIO
>
> §1–§8 were written **mid-investigation**, while the dead band was believed to be the cause of the
> audible distortion on the Cloudflare SRT path. **It was not.** The dead band is a real defect, was
> real, is fixed, and its record below stands — but the gravel had an unrelated cause, found four
> hours later and recorded in **§9**.
>
> **If the symptom is gritty or gravelly live audio with the programme intelligible underneath, and
> every counter in the path reads clean: go straight to §9.** That is the shape of a PTS that does
> not tile, and it has now happened twice — NDI on 2026-09-18, SRT on 2026-09-21.
>
> **If the symptom is a SLIGHT PERIODIC STUTTER every few seconds that sounds like the settling
> blips at connect: go to §11.** Different fault, different half of the path. Every mirror push is
> a ~50 ms mute performed silently by the renderer, and the step that provokes it is the product of
> two constants neither of whose own justification considers it. §11 is also where the depth
> question left open in §7 is finally measured.

---

## TL;DR

`LiveClock` publishes a mapping to the audio mirror only when the control loop's **rate value
changes**. When the P-loop saturates against its ±0.5% slew clamp, consecutive recomputes produce a
**bit-identical `Double`**, so the change test is deterministically false and publication stops
entirely.

The mirror is **edge-driven** — every part of `mirrorLiveAudio` runs inside that callback — so when
publication stops, audio correction stops. The audio timebase is left pinned at whatever rate it
last saw while the video clock runs 0.5% fast. Audio walks away at ~5 ms/s until the position error
crosses a threshold and gets yanked back in one step. That step is a discontinuity in the audio
timebase, and it is audible.

**The failure is inverted, and that is the defect.** Saturation is the condition under which audio
most needs to follow the clock, and it is the one condition that guarantees it will not.

This is **not a regression** — the gate and constants are byte-identical at `7a630c8`, and the
behaviour reproduces there. What changed is the transport, not the code.

---

## 1. The symptom, and the control that isolated it

SRT audio over the Cloudflare relay distorts within about thirty seconds. The same build, minutes
apart, against a local SRT source (OBS in listener mode on loopback) is clean.

| | Cloudflare SRT | Local SRT |
|---|---|---|
| `rate` on `[LIVECLOCK]` | **1.0050 constant**, 25+ consecutive readings | varies 0.9950 – 1.0050 |
| `depth` vs `target` 0.250 | 0.27 – 0.45, never converges | 0.237 – 0.259, converged by +2 s |
| `err` | +0.02 … +0.19 | ±0.013 |
| `[SRT-AUDIO] mirror` mapping changes | **1 in 29 s** | 89 by +10 s, 180 by +20 s (~9/s) |
| `timebase−clock` | −0.2 → **−113 ms**, then snaps to ~0 and repeats | ±4 ms, no trend |
| arrivals per jitter window | 84–95 at connect, then 23–26 | 23–25 throughout |

⚠️ **Note what is NOT different.** After the connect burst, Cloudflare's packet arrival is as steady
as local — `min=23 max=25`. An early hypothesis that "Cloudflare is lumpy throughout" was checked
against the jitter windows and is **false**. What differs is the *depth error*, which is five to ten
times larger, and nothing in the clock explains why.

**Historical baseline**, from the SRT Stage 2 work: **±7 ms `timebase−clock` over 50 s, with 388
mapping changes producing 5 `setRate` calls** — i.e. ~7.8 mapping changes per second. Today's local
figure (~9/s) matches it. Today's Cloudflare figure does not resemble it.

**Bisect:** reproduced at `7a630c8`, before any of 2026-09-21's commits. The `toneLock` move and the
`LiveClock` telemetry gate are exonerated.

---

## 2. The mechanism — the gate, quoted

Publication is drained by `publishMappingIfChanged`, which fires only on a dirty flag
(`LiveClock.swift:535`):

```swift
guard mappingDirty else { … return }
```

`mappingDirty` is set only by `setMappingLocked` (`LiveClock.swift:513-518`), which has **seven call
sites**. Six are coarse or one-shot: the first anchor in `registerFrame` (guarded by
`anchorSenderPTS == nil`), `adjustTargetDepth` (a keystroke), the `forceUnityRate` debug pin, the
snap, the freeze guard, and the overflow re-anchor. **Only one fires continuously** — the P-loop, at
`LiveClock.swift:900-921`:

```swift
let error = depth - targetDepth
let proposed = 1.0 + k * error
let newRate = min(1.0 + maxSlew, max(1.0 - maxSlew, proposed))
…
if newRate != rate {
    let mappedNow = anchorSenderPTS! + (t - anchorHostTime!) * rate
    setMappingLocked(senderPTS: mappedNow, hostTime: t, rate: newRate)
}
```

`if newRate != rate` is the entire gate, and the comment above it states its purpose plainly:
*"Gated to ACTUAL changes so a settled rate doesn't churn the anchor every 10Hz tick."*

**The SRT side is not a factor.** `SRTFrameRouter.swift:506-508` installs an unconditional forwarder
with no filter of its own.

### Why saturation closes the gate permanently

`min(1.0 + maxSlew, max(1.0 - maxSlew, proposed))` maps **every** out-of-range error onto the
identical expression `1.0 + maxSlew`. Once clamped, `newRate` carries the same `Double` bit pattern
as the `rate` written on the previous tick, so `newRate != rate` is **exactly** false — not
approximately, not intermittently. Deterministically.

The gate was written to suppress churn from a *settled* rate. It does not distinguish a settled rate
from a *railed* one, and the two are indistinguishable at the comparison site.

---

## 3. The dead band

With `k = 0.8` and `maxSlew = 0.005` (`LiveClock.swift:86,93`), the rail is reached at

```
|error| ≥ maxSlew / k = 0.005 / 0.8 = 6.25 ms
```

The snap's own threshold is `targetDepth + 0.2` sustained for 0.75 s (`LiveClock.swift:809`; SRT
sets `snapThreshold: 0.2` at `SRTFrameRouter.swift:288-294`).

**So between 6.25 ms and 200 ms of depth error, no call site publishes anything at all.** `err` in
the `[LIVECLOCK]` line is exactly this quantity (`log.depth - log.target`, `LiveClock.swift:1120`),
which makes the band directly observable in any existing log.

The two transports land on opposite sides of it:

| | `err` | `k·err` vs 0.005 | Result |
|---|---|---|---|
| **local SRT** | ±0.013 | 0.010 — crosses the rail, never resides | `newRate` differs nearly every tick → ~9/s at `controlHz = 10` |
| **Cloudflare** | +0.02 … +0.19 | 0.016 … 0.152 — always past it | `newRate == rate` every tick → **zero publications from this site** |

⚠️ **Local SRT is not correct here — it is lucky, and the margin is about 2×.** Its error
oscillates *through* the 6.25 ms boundary rather than sitting past it, so the rate changes often
enough to keep the mirror fed. Any transport that runs persistently deep will close the same gate.

**Measured 2026-09-21, and it is worse than "lucky" suggests.** A healthy loop does not stay out of
the dead band — it enters it constantly and escapes before the error accumulates:

```
local     publication gaps  max 1035 ms · p95  987 ms · over 500 ms: 54
WHEP      publication gaps  max 1435 ms · p95 1300 ms · over 500 ms: 45
local9    publication gaps  max  787 ms · p95  464 ms · over 500 ms: 26
```

Forty-five to fifty-four silences longer than half a second per ninety seconds, with railed spans
reaching 1.0–1.4 s. The cause is structural: **the healthy error envelope (±13 ms) is roughly 2× the
rail threshold (6.25 ms)**, so a healthy loop rails on every excursion. It survives only because a
railed span of ~1 s accumulates ≈5 ms of drift against a 10 ms position tolerance.

⚠️ **The consequence is that this was never a Cloudflare-specific fault.** A factor of two is not a
safety margin. Any transport that runs slightly deeper, or any session where the error envelope
widens modestly, tips a path that was clean the day before — with no code change and nothing in any
log to mark the transition. That is the most plausible account of why 2026-09-18 was clean on the
same binary (§6).

*(This is also why a 500 ms heartbeat interval was tried and rejected: the premise that a healthy
path never goes 500 ms without publishing is false by 45–54 events per 90 s, and the longer interval
cost 2.8× on the saturated case — worst excursion 28.83 ms against 10.22 ms — while buying none of
the healthy-path invariance it was meant to buy. It also coarsened rate steps from 0.565 to
1.24–1.47 cents, making the sparser schedule harsher on the timebase, not gentler.)*

**The 1-per-25 s events on Cloudflare are not a slow publication rate; they are zero from the P-loop
plus occasional coarse re-anchors** (snap, freeze guard, or overflow). Each of those writes
`rate: 1.0`, which makes the *next* control tick's 1.0050 a genuine change. Which of the three fires
is not determinable from counts alone — the `[SRT] snap-to-live:` / freeze-guard / queue-full log
lines distinguish them.

---

## 4. Why the drift is 5 ms/s — the arithmetic

The mirror is edge-driven: the EMA, the position error and the push decision all run **only** inside
the callback (`FrameEngine.swift:2283-2372`). No mapping change means no evaluation, however large
the error has grown.

Worse, the re-anchor that *does* eventually fire re-installs a **stale rate**. The push sends
`rateToPush = mirror.smoothedRate`, not `m.rate`, and the EMA's timestep is clamped
(`FrameEngine.swift:2318`):

```swift
let dt = mirror.haveSmoothed ? max(0.0, min(1.0, m.hostTime - mirror.lastHost)) : 0.0
```

At `tau = 30`, one change per 25 s advances the filter **as though one second had passed**:

```
alpha = 1 - exp(-1/30) = 0.0328
smoothedRate ≈ 1.0000 + 0.0328 × (1.0050 - 1.0000) = 1.00016
clock rate                                          = 1.00500
residual slope = 1.00500 - 1.00016 ≈ 0.0048  →  4.8 ms/s
```

**Measured: −5 ms/s.** The arithmetic and the log agree.

It also explains the sawtooth: `positionError` (77.4 ms, past the 10 ms tolerance) is what triggers
the push, and **the push corrects position only**. The rate needs ~30 changes to converge; at 25 s
apart that is roughly twelve minutes, i.e. never within a session. So position snaps back to ~0 and
immediately resumes walking at the same slope.

> **Inference, not measurement:** that these timebase discontinuities are what is audible. The
> mechanism predicts a step every 15–20 s and the distortion is heard on that cadence, but no
> capture of the enqueued samples was taken on this occasion. The 2026-09-19 WHEP work established
> that a synthesised tone plus a WAV capture of the exact enqueued bytes is the instrument that
> settles this class of question.

---

## 5. Why this is the defect, independent of Cloudflare

A control system whose corrector is disabled by the condition it exists to correct is wrong
regardless of what provoked the condition. Saturation means the clock is working as hard as it can;
that is precisely when the audio timebase most needs to be told. Instead it is the one state in
which it is told nothing.

The slew-site note at `LiveClock.swift:857-900` anticipated this failure *shape*, and its tripwires
did not catch it: **they watch for the slew pinned at unity, not pinned at the rail.** A railed slew
is just as silent as a disabled one, and looks healthier in every log.

⚠️ **The naive fix is wrong.** Publishing on every tick while saturated would churn the anchor at
10 Hz, which is exactly what the gate exists to prevent, and the churn was itself a fixed defect —
routing the P-loop's ±0.5% depth correction straight into the audio renderer was audible **pitch
wobble**, and the smoothed rate (τ ramping 2 s→30 s, warm seed) was built to stop it. Any fix must
preserve that separation: **position/anchor mirroring is what holds `timebase−clock` near zero; the
smoothed rate deliberately does not follow the depth-correction signal.** Audio ignoring
`rate=1.0050` is by design and is not the bug.

---

## 6. Why Friday worked

`BUGS.md` and this session both record 5–7 minute clean Cloudflare SRT sessions on 2026-09-18. The
gate and constants are byte-identical between then and now, and the bisect confirms the behaviour is
present in that code.

**Therefore the depth behaviour of the Cloudflare path changed, not Manifold.** On Friday the error
must have been small enough to keep crossing the 6.25 ms boundary, exactly as the local source does
today.

⚠️ **This is inference from the mechanism, not a measurement of Friday.** No Friday log survives with
`rate=` and `timebase−clock` on a Cloudflare session. It is consistent with everything observed and
it is the only explanation that fits identical code producing two behaviours — but it is not proven,
and the thing that would prove it is the root question below.

**What makes it plausible rather than merely possible is the 2× margin measured in §3.** The
transition from clean to broken does not require the transport to change much. It requires the depth
error to stop crossing back under 6.25 ms often enough — which, against a healthy envelope of ±13 ms,
is a small shift. Nothing in any log marks that crossing, which is why a feature verified over 5–7
minute sessions on 2026-09-18 can fail reproducibly on the same binary three days later.

---

## 7. Open — and this one is the root

**Why does the Cloudflare path sit 20–190 ms deep against a 0.250 s target when a local source sits
within ±13 ms?**

Nothing in the clock explains it. Everything in sections 2–5 is downstream of it. Candidates, none
investigated:

- Jitter or pacing at the **access-unit** level rather than the packet level — arrivals are steady
  but `[SRT-FLOW] depth` still swings 0.21 → 0.47 within a second.
- The reorder budget against `pts − dts`. Every Cloudflare run logs *"reorder delay 0.208 s is within
  75% of targetDepth 0.250 s — the margin protecting the PTS-ordered insert is thin."* Local does
  not carry this warning in the same terms.
- The queue simply never draining to setpoint after the connect burst: the startup anchor discards
  2.1–3.2 s of content with a net clock jump of the same size, and `[SRT-BACKLOG]` shows the surplus
  persisting for the whole session within its stated bound.
- Cloudflare's SRT output is a **transcode** of the WHIP/WebRTC ingest, not a passthrough — so its
  pacing is its encoder's, not OBS's. The local test bypasses that entirely.

⚠️ **Fixing the gate does not fix this**, and should not be mistaken for having done so. It makes the
symptom impossible; the transport still runs deeper than it should, which is a latency cost and may
be a defect of its own.

---

## 8. Instruments that read healthy throughout

Recorded because this document exists to stop the same ground being re-litigated, and because the
list is now long enough to be a pattern rather than an anecdote:

- **`underruns=0`, `short=0`, `resyncs=0`** on `DeckLinkAudio` for the entire session — while
  `drift` climbed to −94 ms and `corr=-2f` fired every window.
- **`undecodable=0 noPTS=0`** on every `[SRT-AUDIO] chain` line. Nothing failed to decode; the
  samples were all present and all correctly timed *relative to each other*.
- **`[SRT-JITTER] worst deficit 0.000s | cushion needed >= 0.000s`**, which reads as "the cushion is
  more than adequate" while the depth error it does not measure was closing the publication gate.
- **`[SRT-BACKLOG] residual +0.099s (bound ±0.102s)`** — inside its own bound on every window, all
  session.
- **The slew-site tripwires**, which watch for the slew pinned at unity and are blind to it pinned at
  the rail.

Every one of those is a correct measurement of the thing it measures. None of them measures the
thing that was wrong. The number that did was `timebase−clock`, which is printed on a line that says
nothing else alarming.

---

## 9. What the gravel actually was — the SRT PTS did not tile

**Found and fixed 2026-09-21, about four hours after §1–§8 were written.** The dead band above is
real and is fixed, and fixing it changed `timebase−clock` from −113 ms to ±4 ms — and the audio was
still gravelly. This is the cause.

### The measurement

A probe on every buffer enqueued to the `AVSampleBufferAudioRenderer`, reporting
`gap = this PTS − (previous PTS + previous duration)`:

```
══ GAP HISTOGRAM ══ 468 gaps over 469 buffers @ 48000 Hz
    EXACTLY ZERO (contiguous) : 0          ← not one
    overlap 10…100 samples    : 312
    hole    10…100 samples    : 156
    worst hole +32.000 · worst overlap −16.000
    SIGN ALTERNATIONS         : 312
    cumulative gap this session: +0.000 ms
```

**Zero contiguous buffers out of 468**, and a cumulative error of exactly zero.

### The cause

The raw PTS values are quantised to **one millisecond**:

```
pts=36.263000   36.284000   36.306000   36.327000   36.348000   36.370000
deltas:            21 ms       22 ms       21 ms       21 ms       22 ms
```

A 1024-frame AAC buffer at 48 kHz is **21.3333 ms**. A millisecond grid can only express 21 or 22,
so the error runs on a three-phase cycle — 21, 21, 22 → **−16, −16, +32 samples** — which is why the
histogram shows 156 holes against 312 overlaps rather than an even split, and why it sums to zero.

The audio PTS was built from the sender's value converted through the stream's declared
`AVStream.time_base`. That conversion was faithful; the information had already been destroyed
upstream, by Cloudflare's muxer.

**The renderer was handed a 16-to-32-sample discontinuity forty-seven times a second, forever.** It
resolved every one. That is the gravel: immediate on connect, continuous, programme intact
underneath.

### Why local SRT was clean on identical code

Measured after the fix, from the first buffer of each connection:

| Source | declared `time_base` | source PTS vs sample-counted axis |
|---|---|---|
| OBS direct (local) | `1/90000` — EXACT | **−0 samples** — tiled exactly, always had |
| Cloudflare | `1/90000` — EXACT | **−32 samples** after one buffer |

⚠️ **The declared timebase is not evidence.** One earlier Cloudflare session declared `1/1000`;
this one declared `1/90000` and still failed to tile. What matters is whether the *values* land on
sample boundaries, and only a sample-counted axis can tell you.

This also answers the question that dominated the day — *"we fixed this on Friday, how can both be
true?"* Both were true. The code was correct on 2026-09-18 and unchanged on 2026-09-21. What changed
was the sender's PTS grid. The one transport with a third party's muxer in the middle is the one
that broke, on a day when nothing in the repository moved.

### The fix

A **sample-counted axis**, following `NDIService.audioPTSTicks` rather than inventing a second
approach to the same problem: one conversion from seconds at the anchor, then
`ptsTicks = anchorTicks + cumulativeFrames`, an integer add, with
`CMTime(value: ticks, timescale: CMTimeScale(sampleRate))`. Consecutive buffers are contiguous **by
construction** rather than by rounding. The axis re-pins to the sender PTS at a 25 ms tolerance
without restarting the counter, and resets on format change and per stream.

Measured after: **470/470 contiguous, zero holes, zero overlaps, zero sign alternations**, on four
consecutive windows, on both transports.

> ⚠️ **A code comment at the old site predicted this exact symptom and dismissed it.** It described
> the desktop crackling "exactly as NDI's did — with the tap, the meters and SDI all still perfect,
> because only the renderer uses per-buffer timing," and then ruled it out on the premise that it
> required 44.1 kHz. It did not: the rounding happened upstream of the line the comment was
> defending. It closed with *"SRT's audio is measured working on the wire and is left alone"* — and
> the wire was never the broken part.

### ⚠️ THE CASUALTY: a decoder swap made on this evidence, and reverted the same night

**While this was being chased, the AAC decoder was swapped from AudioToolbox to libavcodec, and
that swap has been reverted.** It is recorded here rather than quietly undone, because the
inference behind it was reasonable and will look reasonable again.

**The case for it, as it stood:** the feed was gravel; the WAV captured at the handoff to the
renderer was clean to within 1 dB below 20 kHz; `[SRT-AUDIO-PROBE]` read every packet as well-formed
ADTS with `rdblocks = 0`; and the **same bytes decoded cleanly through the ffmpeg CLI**, which is
libavcodec. Clean bytes in, gravel out, and a different decoder handling the identical bytes
correctly. Every one of those observations is true and was correctly measured.

**Why it was wrong:** the fault is the PTS grid, which sits **upstream of every decoder**. No
decoder can see it, none of them caused it, and swapping one for the other could not have fixed it.
The swap appeared to help only because it was judged **by ear**, against a path that was changing
underneath the test.

**The measurement that settled it, after the sample-counted axis landed:** two Profile builds from
one tree, differing in the single selection line, both Developer ID signed, run against the same
sources.

| build | decoder | Cloudflare | local SRT |
|---|---|---|---|
| A | libavcodec | contiguous | contiguous |
| B | **AudioToolbox, all channel counts** | **471/471 contiguous, `axisRePins=0`** | **164/164 contiguous, `axisRePins=0`** |

Clean on both, by ear and by histogram. So AudioToolbox was never shown to mis-decode anything, the
second decoder and its protocol are deleted, and SRT audio is on one decoder again.

⚠️ **THE GENERALISATION, WHICH IS THE PART WORTH CARRYING.** §10 below is about instruments that
aggregate. This is the companion failure: **a remedy that appears to work is not evidence for the
diagnosis that motivated it, when the remedy was judged by the same sense that reported the
symptom.** The decoder swap and the PTS fix were both in flight; the ears could not separate them,
and only a per-event instrument could. Note that the gap histogram — built during this
investigation to convict the PTS grid — is also what exonerated the decoder. Once a per-event
instrument exists, use it to re-test what was concluded without one.

📌 **And one thing that is NOT a reason to re-adopt libav, recorded so it is not confused with
one:** libavcodec has an `aac_latm` decoder and `SRTFrameRouter.handleAudioFormat` refuses
LATM/LOAS outright. That is a real capability gap and a possible reason to revisit libav later —
but it is a **different justification**, needing its own measurement and its own channel-order
work, and it must not ride along on the swap that was just reverted.

---

## 10. Why every instrument missed it — the transferable part

This is the section worth reading if you are debugging something else.

**The defect summed to exactly zero, and every instrument in the path aggregated over a window.**
An alternating ±16/+32-sample error with a cumulative value of zero is invisible to a mean, a total,
a drift figure, a rate, or any per-second rollup. It is visible only to a per-event measurement.

Seven instruments read healthy or actively misled during this investigation:

1. **`undecodable=0`, `noPTS=0`** — correct. The samples were always perfect.
2. **`timebase−clock`** — flat within ±4 ms after the dead-band fix. It measures the mirror's
   position error, not whether consecutive buffers abut.
3. **`[SRT-JITTER] worst deficit 0.000s`** — arrival jitter was genuinely fine.
4. **`[SRT-BACKLOG] residual` within bound** — every window, all session.
5. **A 10-second WAV capture at `LiveAudioSink`'s input** — matched the known-good local capture to
   within 1 dB in every band below 20 kHz, zero repeated blocks, zero samples at the rails. The
   samples *were* clean; only their timestamps were wrong, and a content capture cannot see that.
6. **A system-audio recording of playback** — measured clean, RMS-matched, with *fewer*
   discontinuities than the known-good local capture. A capture concatenates submitted samples; it
   does not observe delivery.
7. **The gap probe itself, in its first version** — it measured gaps in `Double` seconds, which on a
   perfectly tiled 48 kHz stream produces ~3.4e-10-sample residuals. It would have reported 467
   non-contiguous buffers *for a correct fix*. Contiguity is an exact statement about rationals and
   is now decided with `CMTimeCompare(pts, previousEnd) == 0`.

Four hypotheses were also eliminated by test and are recorded so nobody re-runs them: ADTS framing
(probe-verified correct), the AAC decoder (switched to libavcodec — the same library `ffmpeg` uses,
which decodes the stream cleanly — still gravelly; **that switch has since been reverted, see §9's
"THE CASUALTY"**), the renderer's rate (pinned to exactly 1.0 —
still gravelly), and debug-build overhead (Release with `DEBUG=0` — still gravelly).

### The rules this produces

- **A defect that sums to zero is invisible to every aggregate.** When a symptom is continuous but
  every total reads clean, measure per event, not per window.
- **Report distributions, not means.** The histogram that found this prints sign alternations
  explicitly, because 312 alternations and a mean of zero are the same number to a summary line.
- **A content capture cannot diagnose a timing fault.** Neither a WAV of the samples nor a
  system-audio recording observes *when* anything was delivered. Both read clean here, and both
  were correct.
- **Verify the instrument against a known-good case before trusting it on the broken one.** Two of
  the seven above would have lied in the direction of a false positive.
- **When someone says "this feels like something we already fixed", go and read that fix.** That was
  said three times during this investigation, about the NDI PTS work of 2026-09-18, and answered
  each time by addressing the literal words rather than the substance. It was the correct signal and
  it was correct from the first hour.

### Symptom-first index

**Gritty, gravelly or crackly live audio, programme intelligible underneath, immediate on connect,
every counter in the path reading clean →** check whether consecutive audio buffer PTSes tile
exactly at the renderer. Do not trust the declared `time_base`; measure the divergence of the
source PTS from a sample-counted axis over the first buffer.

Seen twice: **NDI, 2026-09-18** and **SRT (Cloudflare), 2026-09-21**. Both fixed the same way.

**A slight periodic stutter every few seconds that sounds like the settling blips at initial
connection, on any transport that mirrors `LiveClock` →** it is not a splice and not the PTS grid.
Count `[*-RENDERER] setRate` rows in the log: each one is a ~50 ms mute performed silently by
`AVSampleBufferAudioRenderer`, and the connect burst is the same event at a denser spacing because
τ is still ramping. The step handed over is `liveAudioRateThreshold × liveAudioRateTau` = 6 ms,
regardless of how far the clock is railed; the rail sets only the cadence. **See §11.** Do not
reach for the WAV tap — it is upstream of the renderer and cannot contain this. Seen on **local
SRT, Cloudflare SRT and WHEP, 2026-09-22** — at 3.0, 7.7 and 4.5 events per minute in steady state,
i.e. on every live transport, including the one that had been used as the clean control.

---

## 11. The periodic stutter — every mirror push is a 50 ms mute, and two constants set its size

**Measured 2026-09-22, three captures of the DEVICE OUTPUT with Robbie streaming from OBS.**
Different symptom from §9, different cause, same file because it is the same mirror.

> **The one-line version.** `liveAudioRateThreshold × liveAudioRateTau = 0.0002 × 30 s = 6 ms`.
> That product — which nothing in the code names, and which neither constant's own justification
> considers — is the media-time step delivered to the audio renderer at **every** rate-threshold
> push. `AVSampleBufferAudioRenderer` resolves each one by **muting for ~50 ms**, silently, with
> no notification of any kind. Measured: **100% of audible events land on a `setRate` push**, on
> all three transports, 67 of 67.

### 11.1 The symptom, and why it is not §9

Reported as "a slight periodic stutter, it sounds like the settling blips at initial connection,
repeating every few seconds", on Cloudflare SRT and WHEP, with local SRT thought clean. It is not
§9: the renderer gap histogram read **`EXACTLY ZERO (contiguous)` 468–501 of 468–501 buffers on
every window of every run, on both transports**. The sample-counted axis is holding, `axisRePins=0`
in all three runs, and nothing in this section is a regression of that fix.

### 11.2 The mechanism, in closed form

`mirrorLiveAudio` pushes when either gate opens (`FrameEngine.swift:2427`):

```swift
shouldPush = positionError > 0.010  ||  rateMoved > 0.0002
```

Take the rate branch. A push occurs when `smoothedRate` has moved `liveAudioRateThreshold` from
what was last pushed. The EMA moves at `(clockRate − smoothed)/τ`, so the interval between pushes
is `threshold·τ / (clockRate − smoothed)`. Over that interval the position error accrues at exactly
`(clockRate − smoothed)`. The residual cancels:

```
media step at every rate-threshold push  =  threshold × τ  =  0.0002 × 30 s  =  6.0 ms  =  288 samples
push interval                            =  6 ms / (clockRate − smoothedRate)
```

**The step does not depend on how far the clock is railed.** The rail sets only the cadence.

⚠️ **AND THAT IS WHY NEITHER CONSTANT'S OWN REASONING CATCHES IT.** `liveAudioRateThreshold`'s
comment justifies 0.0002 on the *rate* step: *"As a STEP it is 0.35 cents, far under the ~5-cent
pitch JND, so each push is individually inaudible."* True, and about the wrong quantity. Every push
also carries a **position** jump, and `setRate(_:time:atHostTime:)` is — in this file's own words at
the slew site — *"an ABSOLUTE re-anchor: it restates 'media time T at host time H' and so WIPES
whatever error had accumulated"*. The two constants were each chosen carefully, separately, and
correctly. **Their product was never anybody's number.**

### 11.3 What the renderer does with it, which is the part nobody had looked at

At **every** push, in the captured device output:

```
  -60ms  -55ms  -50ms  -45ms  -40ms  -35ms  -30ms … +5ms      (5 ms RMS windows)
  0.0881 0.0779 0.0618 0.0362 0.0182 0.0058 0.0000 … 0.0000
                 └── ~20 ms fade ──┘ └── ~50 ms of EXACT DIGITAL ZERO ──┘
```

| | measured, across all three runs |
|---|---|
| core of exact digital silence | **median 50 ms** (range 31–62 ms; 1,655–2,865 samples at bit-zero) |
| full envelope, fade-down to recovery | **median 78 ms** (range 57–99 ms) |
| net content shift across the mute | **±35 samples** — the media position is essentially *preserved* |

So it is **not** a splice and **not** a resample. The renderer ramps to silence, holds bit-zero for
about a frame and a half of video, and ramps back, losing almost nothing of the programme. The core
duration is a property of the **renderer**, not the transport — it is the same on local SRT,
Cloudflare SRT and WHEP.

⚠️ **AN EIGHTH INSTRUMENT READS HEALTHY, AND IT IS THE RENDERER'S OWN.**
`AVSampleBufferAudioRendererWasFlushedAutomatically` — whose SDK header says *"To the listener, this
will sound similar to muting the audio for a short period of time"*, a description that matches this
exactly — **never fired once.** `[*-RENDERER] event` count across all three runs: **zero.** The
renderer does this, does it audibly, and reports nothing. Add it to §10's list.

### 11.4 The measurement

Three runs, 3 minutes each, OBS sending a broadband reference, capture taken at the **device
output** via Audio Hijack (Application → Recorder → Output Device), correlated block-by-block
against the signal sent.

| | mutes/min overall | first 15 s | after 15 s | `setRate` pushes | mute ↔ push |
|---|---|---|---|---|---|
| local SRT | **4.95** | 20.0/min | 3.0/min | 13 | **11/11 (100%)**, lag +1 ms, spread 3 ms |
| Cloudflare SRT | **11.08** | 48.0/min | 7.7/min | 36 | **33/33 (100%)**, lag +103 ms, spread 18 ms |
| WHEP | **7.32** | 40.0/min | 4.5/min | 27 | **23/23 (100%)**, lag +2 ms, spread 4 ms |

Logged media step per push, in samples, **against the predicted 288**:

```
local SRT        median 240   p10  44   p90 326   max 342
Cloudflare SRT   median 269   p10  56   p90 446   max 494
WHEP             median 287   p10  31   p90 355   max 402
```

**The prediction held.** The p90/max excursions above ~350 are the *other* branch firing — the
10 ms position tolerance, i.e. 480 samples — which on Cloudflare SRT it does twice.

⚠️ **LOCAL SRT WAS NEVER CLEAN.** It was *quieter*: 3.0 mutes/min in steady state against
Cloudflare's 7.7. Every earlier session that called it "the clean control" was judging by ear a
difference of a factor of 2.6 in the rate of a 78 ms event. Robbie heard all three on this run.

**Content holes, distinct from the mutes, on the Cloudflare paths only:**
`+837, +676, +439, +85, +76` samples plus several of `+4…+6`, on SRT; `+432, +6, +0` on WHEP; **none
on local**. These do not coincide with pushes and are not this defect — they are transport-side and
are recorded here only so they are not swept into the count.

### 11.5 The connect burst and the steady state are the same event

Question asked directly: does gap-end recovery take the same code path as initial lock? **Yes —
literally the same line**, `FrameEngine.swift:2464`; `origin` differs only as a probe string. Two
things make the burst denser rather than different: `wasMirrored == false` forces
`positionError = .infinity` on the first push, and τ ramps 2 s → 30 s over the first 10 s
(`liveAudioRateRamp`), so `smoothedRate` moves fast and re-crosses the threshold repeatedly.

Measured: the mute envelope in the connect burst is indistinguishable from the steady-state one
(same 50 ms core, same 78 ms envelope). Only the **spacing** differs — 20–48/min in the first 15 s
against 3.0–7.7/min after. **Robbie's description was the mechanism stating itself**, and it was
right before any instrument existed.

### 11.6 Why the P-loop rails, and why that is the tuning and not the transport

The rail is reached at `maxSlew / k = 0.005 / 0.8 = 6.25 ms` of depth error. The depth signal is a
sawtooth of peak-to-peak one frame interval — **41.7 ms at 23.976 fps**
(`MetalVideoRenderer.swift:2273`). **The linear region of the controller is ±6.25 ms inside a signal
whose raw ripple is ±20.8 ms.**

⚠️ **SO THIS IS NOT A P-LOOP THAT OCCASIONALLY SATURATES. IT IS A RELAY CONTROLLER THAT
OCCASIONALLY GOES LINEAR.** Rails alternating sign is the *normal output* of a bang-bang loop, not a
symptom of anything. §3's "local SRT is not correct here — it is lucky, and the margin is about 2×"
is right about the margin and wrong about the character: there is no regime in which this loop
spends most of its time in proportional control.

### 11.7 The heartbeat trade, stated

The heartbeat (2026-09-21, `167f7fe`) is not undone by this and should not be. It fixed a real
failure: publication stopping entirely while railed, the timebase walking ~5 ms/s, and one ~113 ms
yank every 15–20 s. **What it changed is the shape of the cost.** Before, the mirror could not push
during a railed span because it did not run; now it runs at 10 Hz and pushes whenever `smoothedRate`
has crept 0.0002.

⚠️ **AND IT REACHED WHEP THE SAME DAY.** `git show 167f7fe -- App/WebRTC/WHEPFrameRouter.swift` adds
`clock.onMappingTick` on WHEP's seam. WHEP's transport, decoder and PTS path were untouched; its
audio-timebase feed went from "only when the clock's rate changed" — against a measured baseline of
`max 1435 ms · p95 1300 ms · 45 gaps over 500 ms per 90 s` — to **every 100 ms**. If WHEP's stutter
is newer than its transport work, that commit is where it came from.

### 11.8 The depth signal on Cloudflare — the reorder-inflation candidate is ALIVE

§7 and `BUGS.md` both leave open *why* Cloudflare sits 20–190 ms deep. `depth` is
`newestQueuedPTS − now()` — the **PTS extent** of the queue, not its display-order occupancy. For a
queue of `count` frames spaced `D`, the `+D/2` correction makes the expected value exactly
`count × D`. So `depth / (count × D)` is a direct test, and it runs on any log already on disk.

```
local SRT        RATIO median 0.967   range 0.919-1.098    reorder max 0.000 s
Cloudflare SRT   RATIO median 1.301   range 0.905-1.912    reorder max 0.208 s

excess (depth − count×D):  local  median  −8 ms  p90  +18 ms
                           Cloudflare median +51 ms  p90 +135 ms  max +152 ms
```

**Cloudflare's queue holds FEWER frames (median count 4 vs local's 6) while reporting MORE depth.**
That is PTS extent exceeding frame count, which is what reorder looks like, and the excess sits
inside the 0.208 s reorder delay every Cloudflare run already warns about. The starvation line from
run 2 is the same fact from the other end: `rate=1.0050 RAILED err=+0.1120`.

⚠️ **ALIVE, NOT PROVEN.** This is one session, one sender, and a correlation between two numbers in
the same log. It predicts that `targetDepth` on Cloudflare is being asked to absorb the reorder
window twice — once as reorder budget, once as regulated depth — and that a depth signal computed
from display-order occupancy would not rail. Neither of those has been tested. What *is* settled is
the local half: the signal is truthful there, so this is a property of the Cloudflare stream and not
of the measurement.

### 11.9 The instrument

`~/Desktop/manifold-audible-events/`. A broadband aperiodic reference is played by OBS, the device
output is captured, and the two are aligned block-by-block into an **offset track**: a step is a
splice in absolute samples, a step in its slope is a tempo step, and a run of silence is a mute.

⚠️ **THE EXISTING WAV TAP CANNOT SEE THIS, AND IT IS NOT A MATTER OF DEGREE.**
`LiveAudioWAVCapture` copies the bytes handed to `AudioTapBuffer` — **upstream of the renderer**.
The mute is performed *by* the renderer, downstream of every byte that file contains. A renderer
splice or mute **cannot be in that file at any sample rate, for any duration, under any
conditions.** It is §10 item 5 exactly, and it read clean again on 2026-09-22.

Three things this instrument got wrong first, all caught by its own gates before any real capture
was read — recorded because §10's rule is that the instrument is verified before it is believed:

1. **A tone detector cannot do this.** Phase is modulo one period: a 48-sample splice is exactly one
   cycle at 1 kHz and is invisible. Caught by the injected-fault gate, which it failed. Replaced by
   correlation against broadband noise, which has no modulo.
2. **A 4096-sample correlation block manufactures dropouts.** A sustained 6-cent rate offset smears
   the block enough to drop the peak from 0.97 to ~0.4, and the instrument reported **14 spurious
   dropouts** over the 25 s after a rate step it had correctly detected. Block is 2048.
3. **Skipping a block you cannot correlate is how you walk through the fault.** A digitally silent
   block has no correlation peak, so the tracker skipped it — and a mute therefore left a *hole* in
   the offset track rather than an event in it. Silence is now found directly on the capture,
   never inferred from the track. **This is §10 item 7 happening a second time**: an instrument that
   drops the samples it cannot explain reports a clean run over the thing it was built to find.

Validated end to end before the live runs — a 130 s local file played through Manifold and captured
through the whole chain: **median correlation 1.000, zero drift, zero events, per-block noise
0.0005 samples.** The floor is 0.003 samples; a 4-sample splice is unmissable.

⚠️ **AND ONE INSTRUMENT GAP IN THE TREE, FOUND WHILE DOING THIS.**
`LiveAudioRendererProbe.recordRateSet` takes `(rate, mediaTime, origin)` and stamps
`CACurrentMediaTime()` **itself** — it is never given the mapping's `hostTime`, which is what
`setRate(atHostTime:)` actually anchors to. For heartbeats and P-loop rebases those coincide. For
the **first anchor** they do not, because `registerFrame` pins the host anchor `startupDepth` into
the future, so reconstructing the step from the probe row invents a **−249 ms jump that never
happened** — the largest number in an unfiltered run, and pure artefact.

### 11.10 Candidate fixes — NONE APPLIED, and the trade-offs are the point

⚠️ **Read §5 first.** It rules out the obvious one and its reasoning is unchanged: the smoothed rate
deliberately does not follow the P-loop's depth correction, and position/anchor mirroring is what
holds `timebase−clock` near zero. Any fix must preserve that separation.

1. **Do not move the timebase when only the rate changed.** Call `synchronizer.rate = r` instead of
   `setRate(_:time:atHostTime:)` when `positionError` is small, so a rate-threshold push stops being
   a position re-anchor. *Trade:* the re-anchor is currently the **only** thing correcting the
   audio-device-vs-mach crystal divergence — the slew-site note is explicit that nobody designed a
   drift corrector and one fell out of this. Removing it needs the closed-loop re-anchor NDI also
   needs, or WHEP and SRT become unbounded exactly as that note warns.
2. **Raise `liveAudioRateThreshold` toward the position tolerance.** The step is `threshold × τ`, so
   0.00033 × 30 s = 10 ms would make the rate branch fire no more often than the position branch —
   one gate instead of two. *Trade:* fewer, larger mutes. It reduces the count and not the audibility
   of each, and 10 ms is already what the position branch delivers.
3. **Shorten τ.** 30 s was chosen from the measured sender clock (σ = 0.021%, 1.1 cents) against a
   control loop swinging 17.3 cents, and that derivation is sound. τ = 10 s would make the step 2 ms.
   *Trade:* the filter then passes more of the P-loop's depth correction into the audio rate, which
   is the pitch wobble §5 says the smoothing exists to stop. This trades a mute for a warble.
4. **Fix the depth signal (§11.8).** If the Cloudflare rail is an artefact of reorder inflation, a
   depth measured from display-order occupancy would keep the loop off the rail, `smoothedRate`
   would track, and the push rate would fall to something near local's. *Trade:* it does not fix the
   mechanism, it only stops provoking it — local SRT still ran 3.0 mutes/min — and it is a change to
   the video control loop made for an audio symptom, which is how §9's decoder swap happened.
5. **Ramp the correction instead of stepping it.** Feed the position error in as a small temporary
   rate bias, absorbed over ~1 s, so the timebase is never discontinuous. *Trade:* a new mechanism
   between the clock and the renderer, and it must not become a second rate loop fighting the first.
   This is the only candidate that removes the discontinuity rather than rationing it.

⚠️ **WHATEVER IS CHOSEN, THE ACCEPTANCE TEST IS ALREADY WRITTEN**, and it is not ears: the
device-output capture with mutes/min per transport, against these three numbers — **4.95 / 11.08 /
7.32 per minute**, and **3.0 / 7.7 / 4.5 per minute in steady state**. A fix that does not move
those has not been demonstrated to do anything, and a fix judged by listening is the mistake §9's
"THE CASUALTY" is about.
