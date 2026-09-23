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
| **SRT** | `beginLiveAudio(cushion:)` is passed `targetDepth` at a call site whose own comment predates the correction that says it should be 0 | **audio ~200 ms LATE**, constant |
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

### 3.1 SRT — the cushion is a stale value, and audio lags picture by ~200 ms

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

#### The smallest fix — NOT APPLIED

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
* **The residuals between arithmetic and measurement vary by path** (−42, −80, −95 ms). Part is the
  bounded frame-grid bias; the rest is the sender's own audio-vs-video encode delay, which cannot be
  separated from inside Manifold. A reference-player run per transport, as done for WHEP, is what
  would separate it.
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

The minimal WHEP reference player used for runs 6–7 is at
`~/Desktop/manifold-avsync/whep-player/` — one HTML file, no libraries, with a stdlib proxy that
holds the endpoint so the page stays same-origin and the URL never reaches the browser.

⚠️ **ONE THING THAT WILL WASTE AN HOUR IF IT IS NOT WRITTEN DOWN.** Cloudflare's WAF returns
**403 with an HTML block page** to a POST carrying `Python-urllib`'s default User-Agent. With a
browser User-Agent the identical request reaches the endpoint, which then answers on its merits
(`400 SDP contains no ice-ufrag` for a junk offer). **The 403 is a firewall verdict on the client,
not on the WHEP request, and it is indistinguishable from "the stream is offline" if you read only
the status code.** The proxy forwards the browser's own User-Agent for this reason.
