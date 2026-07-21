# Manifold — LiveClock Design

**Status:** Design draft for review. No code yet.
**Purpose:** The general live-clock foundation for streaming input. WHEP is the first consumer; SRT and HLS inherit it. This is the one piece of genuinely new engineering in the streaming arc — NDI got all of it free from FrameSync; every other source must bring its own.
**Scope of this doc:** the clock, the jitter buffer, drift correction, the A/V-sync consequences, the synthetic test harness, and where it seams into the existing renderer/audio/source architecture. Networking, RTP depacketization, and the WHEP handshake are explicitly *out of scope* — they sit on top of this and are validated separately.

---

## 1. The problem, stated precisely

A live source hands us frames stamped with the *sender's* timeline (for WHEP, RTP timestamps mapped to a media clock). We must present those frames on *our* display at the right real-world moments, keeping audio and video locked, for a session that may run for hours.

Three things make this hard, and all three are absent from the codebase today:

1. **No shared timebase.** The sender's clock and our host clock are independent crystals. They will drift — a sender nominally at 23.976 fps is really at 23.976-plus-or-minus-a-few-ppm relative to our `CACurrentMediaTime()`. Over an hour, a few ppm is tens of milliseconds to whole frames of accumulated skew.
2. **Network jitter.** Frames don't arrive on a clean cadence; they clump and gap. We must absorb that without it reaching the screen.
3. **No end, no seek.** A live gap must never read as end-of-stream, and there is no timeline to seek within. Every file-shaped assumption in `FrameEngine` (duration, EOS at `t >= duration`, seek clamps) is invalid here.

The recon confirmed the codebase has exactly one non-file clock precedent: NDI installs `renderer.clock = { CACurrentMediaTime() }` and stamps each pulled frame with `monotonicNow()` microseconds before the tick reads the clock — so `pts <= now` always accepts the newest frame. That works for NDI because **FrameSync already did the jitter buffering, timing, and rate conversion inside the SDK.** We are rebuilding that layer.

---

## 2. The core idea: a clock that recovers the sender's rate from buffer depth

Rather than trying to directly measure "how fast is the sender's crystal vs. mine" (fragile — you're differencing two noisy timestamp streams), we use the **jitter buffer's depth as the control signal.** This is the standard robust approach to adaptive clock recovery, and it unifies jitter absorption and drift correction into one mechanism.

The intuition:

- Frames arrive and go into a buffer, ordered by their sender PTS.
- The clock advances, and the renderer pulls the frame whose PTS has come due (`pts <= now`).
- If the buffer is **draining** (depth trending down over time), our clock is running *faster* than the sender is producing — we're consuming faster than we're being fed. Slow the clock down.
- If the buffer is **filling** (depth trending up), our clock is *slower* than the sender — speed it up.
- Hold the buffer at a **target depth** (our chosen latency). The control loop that keeps it there *is* the drift correction, automatically, forever, without ever explicitly computing a rate ratio.

This is elegant because drift and jitter stop being two problems. Jitter is a transient buffer-depth wobble the buffer absorbs; drift is a persistent buffer-depth trend the control loop corrects. Same buffer, same signal.

---

## 3. Anchor and target latency

**Anchor.** When the first frame arrives with sender-PTS `T0` at local host-time `H0`, we establish the mapping. Presentation time is then, to first approximation:

> `now() = T0 + (hostTime() − H0) × rate`

with `rate` starting at 1.0 and being gently adjusted by the control loop (Section 4). The first frame presents after a deliberate startup delay (the target buffer depth) rather than immediately — we let the buffer fill to target before starting the clock, so there's headroom to absorb the first jitter without starving.

**Target latency is the key tunable, and the requirement is LOW.** This is the driving product decision, and it is settled: **near-live, lowest latency the network tolerates.** The use case is remote review-and-approval — a colorist and client on a call, "bring the shadows up," and the client seeing the change *now*. This becomes the DC Color Live playback client's core value; every 100ms of buffer is 100ms of "did it change yet?" friction. Latency is not a nicety here, it is the product.

That inverts the tuning from a comfortable-buffer design to a **minimum-viable-depth** design:

- Target depth is set as shallow as the network's jitter allows — the *minimum* depth that survives normal jitter without constant starving, not a safe cushion.
- Operating near the starve edge is deliberate, so the starve/recover path (last-frame-repeat, no EOS) must be graceful and *frequent-tolerant*, not a rare-failure afterthought.
- The control loop must be **more responsive** — a shallow buffer drains fast, so the rate correction has to react to drift trends before the buffer empties. Responsive loops have more room to over-correct or oscillate, so they demand careful validation (Section 7 is where we earn this).

We find the real floor numerically with the test harness: inject deterministic jitter and drift, and discover the lowest target depth at which a clean feed stays pinned and realistic jitter still survives. That's how we get *lowest latency that's still solid* instead of guessing on a live network.

**Adaptive target depth is the v2 refinement, not v1.** The mature version measures live jitter and sets depth just above it dynamically — the true "lowest latency current conditions allow." v1 is a fixed shallow target tuned via the harness; we just architect so adaptive depth can drop in later (the control loop already has depth as its setpoint — v2 makes the setpoint itself adaptive).

---

## 4. Drift correction: gentle clock slew, and why video is smooth by construction

The control loop adjusts `rate` (the multiplier in the anchor equation) to hold the buffer at target depth. Critically, **the slew is tiny and rate-limited** — we're correcting crystal drift of a few ppm plus slow network trends, so `rate` lives within a hair of 1.0 (think 0.999–1.001, and changing slowly). This is a leaky-integrator / PLL-style loop: measure buffer-depth error, nudge rate proportionally, clamp the nudge so it can never lurch.

**Why this is invisible on video.** The renderer selects frames by `pts <= now`. Slewing the clock by 0.05% just makes each frame come due a few microseconds earlier or later — sub-frame, sub-perceptual. There's no frame drop or repeat in steady state; the same frames present in the same order, imperceptibly re-timed. Video judder from drift correction only happens if you correct *discretely* (drop/repeat frames) or *aggressively* (large rate steps). We do neither. Frame drop/repeat is reserved for the failure cases only: a true starve (buffer empty, nothing to show → repeat last) or a flood (buffer overflowing past a hard cap → drop oldest).

**The audio consequence, and why Manifold's architecture helps.** Slewing a playback clock classically shifts audio pitch, because audio slaved to the clock plays faster/slower. Here's the architectural fact that saves us, from the recon: **for SDI output, the DeckLink audio callback pulls `tap.read(startingAt: <staged video frame PTS>)`.** Audio is fetched *relative to the video frame currently going out the card.* So when the video timeline slews, the audio read positions slew with it — audio stays locked to video **by construction**, because it's pulled against video's PTS, not played on an independent audio clock.

That reframes the whole audio-drift question. We are not slewing an independent audio clock (which would pitch-shift). We are pulling audio to match a slewing video timeline. The residual issue is narrower and manageable: the DeckLink card consumes 48 kHz at *its* hardware rate, while the source produces 48 kHz at the *sender's* drifting rate, so over time the tap's source-side fill and the card's consumption rate differ by the same few ppm. That's an audio-sample-rate reconciliation, and it's handled in the tap/read path, not the clock:

- **Simplest (v1):** the tap already re-anchors on >50ms PTS discontinuity (recon, `AudioTapBuffer`). Slow drift accumulates until it trips that re-anchor, causing an occasional tiny audio resync. Might be inaudible; might click once every several minutes. We measure it.
- **Correct (if v1 clicks):** a slow resampler in the audio read path that stretches/compresses by the same ppm the clock is slewing — driven by the *same* rate value the control loop computes. Since the clock already knows the correction rate, we hand that rate to the audio resampler and both domains drift-correct in lockstep, no pitch shift, no clicks. This is the "audio resamples, video slews, both track the corrected timeline" answer — the most-correct option from our earlier discussion — and Manifold's pull-audio-against-video-PTS design makes it a natural extension rather than a separate mechanism.

**Recommendation:** build v1 with clock-slew + the tap's existing re-anchor, *measure* whether audio drift is audible over a long session, and add the rate-driven resampler only if it is. We may get away without it; if we don't, the hook (the control loop's `rate`) is already there to drive it. This keeps v1 tractable and defers the hardest audio work behind a measurement, rather than building a resampler we might not need.

**For Mac-speaker output** (recon: NDI doesn't feed the system renderer at all today): if WHEP needs speaker output, that's a separate path — enqueue to an `AVSampleBufferAudioRenderer`, which has its own sync semantics. I'd treat SDI-out as the reference path for v1 (it's how the review workflow actually runs) and speaker output as a secondary follow-up, not part of the core clock work.

---

## 5. The jitter buffer and the `pts <= now` contract

The buffer is the existing `MetalVideoRenderer.frameQueue` (PTS-sorted, bounded) plus the discipline of the live clock feeding `renderer.clock`. What's new is the *policy* around it:

- **Ordering:** frames enter stamped with sender PTS (mapped to our presentation timeline via the anchor). The queue stays PTS-sorted, exactly as today.
- **Selection:** unchanged — `displayTick()` reads `now = clock()`, picks the newest frame with `pts <= now`. The live clock *is* the only change to how selection behaves.
- **Depth measurement:** the control loop needs buffer depth as a smoothed signal. Depth = (newest queued PTS − now), i.e. how much presentation-time runway we have buffered. We low-pass this (it's noisy per-frame) and feed the trend to the rate loop.
- **Starve (empty buffer):** repeat the last frame (NDI already does this via FrameSync's repeat; we do it explicitly). Do **not** treat as EOS. Log it — persistent starving means target latency is too low for this network.
- **Flood (buffer past hard cap):** drop oldest frames to the cap. Persistent flooding means either the loop is mistuned or the sender is genuinely ahead; the loop should be correcting it, so a flood is a warning sign during development.
- **Gap vs. EOS:** a live source never signals EOS from a gap. EOS only comes from an explicit disconnect/teardown. This must be enforced at the source/clock boundary so no file-shaped `t >= duration` logic leaks in.

---

## 6. The seam: where LiveClock sits

`LiveClock` is a small, standalone object. It does not know about WHEP, networking, or codecs. Its entire contract:

- **Input:** "a frame arrived with sender-PTS `T` at host-time `now`" (called by whatever source feeds it), and a way to read current buffer depth.
- **Output:** `now() -> Double` — the presentation-time closure handed to `renderer.clock`. Plus the current `rate` (for the optional audio resampler) and buffer-depth telemetry (for validation/HUD).
- **Internally:** the anchor, the control loop, the rate slew.

It sits exactly where NDI's `{ CACurrentMediaTime() }` closure sits — it *replaces* that closure with a smarter one. Everything downstream (`MetalVideoRenderer.enqueue`, the `pts <= now` selection, `AudioTapBuffer`, the DeckLink SDI pull) is unchanged and source-agnostic, as the recon confirmed. WHEP, SRT, and HLS each construct a `LiveClock`, feed it their frames' timestamps, and install its `now()` as `renderer.clock`. Identical integration for all three — which is the entire point of building it once, first.

The source model generalization (the `ActiveSource` work) is *separate* from this and comes later in the arc; `LiveClock` doesn't depend on it.

---

## 7. The synthetic test harness — validating the clock with zero network

This is why we build the clock first and in isolation. We validate every property of `LiveClock` before a single byte of WHEP exists, using a **synthetic source** that feeds it re-timestamped local frames.

The harness: take a local file (decoded through the existing libav path), and instead of playing it on the file timeline, **re-emit its frames into the live-clock path as if they were arriving live** — stamp them with a synthetic "sender" timeline and hand them to `LiveClock` + `renderer.enqueue`. This exercises the entire live path (clock, buffer, selection, audio tap, SDI out) with no network variables.

Then we can inject, deterministically, the exact conditions that are impossible to reproduce on a real network on demand:

- **Clean feed:** synthetic sender at exactly local rate. Validates the anchor and steady-state — should be rock-solid, buffer pinned at target, rate ≈ 1.0. Validate on scopes (a known test pattern should be pixel-stable) and on the waveform (audio in sync).
- **Deliberate drift:** synthetic sender at 1.001× or 0.999× local rate. Validates the control loop *actually converges* and holds the buffer at target without visible video judder. Watch the rate telemetry settle; watch the buffer depth return to target; confirm no frame drops in steady state.
- **Injected jitter:** clump and gap the synthetic arrivals. Validates the buffer absorbs jitter without it reaching the screen at the chosen target depth.
- **Starve:** stop feeding briefly. Validates last-frame-repeat, no EOS, clean recovery when frames resume.
- **A/V sync under drift:** the decisive test — feed drifting synthetic audio+video, output to SDI, and **screenshot Manifold's output vs. a reference into a non-color-managed Resolve project on the waveform** (your established decisive instrument), plus check lip-sync on a countdown/clap clip. This is where we learn whether the tap's re-anchor is enough or whether we need the rate-driven resampler.

Every one of these is a numeric, repeatable validation on your existing tools (scopes, Resolve waveform, the SDI countdown lip-sync test you used for D4b) — no "watch it for an hour and see if it drifts." That's the payoff of clock-first: the hardest, subtlest component is proven deterministically before WHEP can muddy it.

---

## 8. Build sequence within the clock arc

1. `LiveClock` object: anchor + `now()` closure, rate fixed at 1.0 (no correction yet).
2. Synthetic source harness feeding re-timestamped local frames into the live path.
3. Validate clean-feed steady state (scopes + waveform).
4. Add the buffer-depth control loop (drift correction). Validate convergence under injected drift.
5. Validate jitter absorption and starve/recover.
6. The decisive A/V-sync-under-drift test to SDI; decide on the audio resampler based on what we measure.
7. Only then: `LiveClock` is proven, and WHEP (networking + RTP + VideoToolbox decode) plugs into a known-good foundation.

---

## Decisions (settled)

1. **Latency: near-live, lowest the network tolerates.** Driving use case is remote review-and-approval (DC Color Live playback client). Minimum-viable-depth design; find the floor with the harness. Adaptive depth is v2.
2. **Audio: measure-first.** Ship v1 with clock-slew + the tap's existing re-anchor; measure audible drift over a long session; add the rate-driven resampler only if needed (the loop's `rate` is the hook to drive it). *[Robbie's default accepted — revisit if measurement shows clicks.]*
3. **Reference path: SDI-out for v1.** Mac-speaker output deferred (matches NDI, which has none today).
4. **Drift correction: continuous, via buffer-depth control loop + gentle clock slew.** Video smooth by construction; audio follows via the staged-video-PTS-keyed tap read.
