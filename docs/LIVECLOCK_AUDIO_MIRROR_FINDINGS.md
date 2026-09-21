# LiveClock's audio mirror stops exactly when it is needed most

**A saturation dead band in the mapping-publication gate, found 2026-09-21 when SRT audio drifted
on the Cloudflare path and not on a local one**

*Measured fact, inference, and open question are labelled separately throughout. Companion to
`AUDIO_PATH_FINDINGS.md`, which covers the August meter audit; this document is about the clock.*

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
