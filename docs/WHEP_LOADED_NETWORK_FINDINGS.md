# WHEP under load — findings from a second machine

Two diagnostics exports from Joey D'Anna's machine, 30–31 July 2026, plus four side-by-side
screenshots. First real evidence from a machine that isn't the development one.

The raw exports should live alongside this document. Without them, the extracts below are
unverifiable.

---

## 1. Method and setup

**Tester machine**, from the diagnostics MACHINE section:

```
Mac13,1 · Apple M1 Max · 10 cores · 64 GB · macOS 26.4 (25E246)
Displays: BenQ PV270, LG ULTRAWIDE, Elgato Prom. — 60 Hz (RENDER-PERF tickMs ≈ 16.67)
DeckLink driver installed, Desktop Video 12.8.1 (below our 14.3 floor — output unavailable)
Manifold 0.5.1 build 6, Profile configuration
Connection: wired ethernet
```

Path in both runs: SDI → OBS → WHIP → Cloudflare Stream → WHEP → Manifold.

| Run | File | Conditions | Duration |
|---|---|---|---|
| A | `Manifold-0.5.1-diagnostics-2026-07-30-194412.txt` | quiet network | 200 s |
| B | `Manifold-0.5.1-diagnostics-2026-07-31-132753.txt` | ~350 Mbps background upload | 234 s |

The load figure in Run B is the tester's description, not an instrumented measurement.

---

## 2. Run A — clean baseline on unfamiliar hardware

Session totals:

```
83,942 packets, 83,942 accepted → 4,748 frames (101 key)
seqGaps=4  lost=4  reorder=1  malformed=0
4,748 access units → 4,742 frames decoded, errors=0
```

Zero underruns across the full 200 seconds. `cushion needed >= 0.000s` never moved off zero.
Depth held within 0.393–0.412 against a 0.400 target for the entire run, at a steady 24.0 fps.

**What this establishes:** the pipeline holds on different silicon and a 60 Hz display. Nothing
about the render loop or the clock is specific to the development machine.

**What it does not establish:** anything about behaviour under stress. This is the easy end of
the spread that adaptive depth needs.

---

## 3. Run B — every underrun followed a decode error

This is the most consequential finding here, and it converts a previously-reasoned caveat into
a measured one.

Seven `[WHEP-UNDERRUN]` events. Eight `[WHEP-DECODE] decode failed (-12909)` events. Each
underrun lands 0.5–2 seconds after a decode failure, without exception:

```
13:24:20.993  decode failed (-12909) — dropping to next keyframe, PLI requested
13:24:22.212  UNDERRUN  queue empty for 0.886s,  54 ticks starved

13:24:53.648  decode failed (-12909)
13:24:55.629  UNDERRUN  queue empty for 1.825s, 110 ticks starved

13:24:58.725  decode failed (-12909)
13:24:59.548  UNDERRUN  queue empty for 0.474s,  29 ticks starved

13:25:00.051  decode failed (-12909)
13:25:01.486  UNDERRUN  queue empty for 1.027s,  62 ticks starved

13:25:31.008  decode failed (-12909)
13:25:32.856  UNDERRUN  queue empty for 1.589s,  96 ticks starved

13:25:48.606  decode failed (-12909)
13:25:50.436  UNDERRUN  queue empty for 1.437s,  87 ticks starved

13:25:53.355  decode failed (-12909)
13:25:54.339  UNDERRUN  queue empty for 0.587s,  36 ticks starved
```

**Consequence.** `cushion needed >= 0.400s` is being set by decode-error recovery, not by
lateness. The queue was not empty because frames arrived late — it was empty because there were
no decodable frames while waiting for a keyframe after a PLI. Adaptive depth consuming
`measuredCushionNeeded` here would have raised the target seven times in three minutes, added
latency, and prevented none of these events.

The exclusion of decode-error episodes from adaptive depth's input is therefore a **measured
requirement**, not a precaution.

**An oddity to verify, not a conclusion.** Every underrun reports its recovering frame as
arriving *early* relative to the clock:

```
-0.278s   -0.185s   -0.190s   -0.222s   -0.209s   -0.265s   -0.281s
```

Yet each reports `would have needed cushion >= 0.400s`, which is exactly the current target. A
negative lateness should not yield a cushion requirement equal to the target. This looks like
saturation rather than measurement, and it should be checked in `LiveDepthTelemetry` before
adaptive depth consumes the value.

---

## 4. Run B — "lost" packets are mostly reordered

Session totals:

```
88,258 packets, 88,258 accepted → 5,175 frames (109 key)
seqGaps=12  lost=95  reorder=94  malformed=0
5,175 access units → 4,895 frames decoded
dropped: preIDR=245  noFmt=27 | errors=8
```

**94 of 95 packets counted as lost subsequently arrived, out of order.** The per-window lines
show the same near-identity throughout:

```
13:24:21.955  pkts=398  seqGaps=1  lost=15  reorder=15
13:24:55.954  pkts=420  seqGaps=1  lost=10  reorder=10
13:24:58.922  pkts=385  seqGaps=1  lost=8   reorder=8
13:25:00.921  pkts=354  seqGaps=1  lost=20  reorder=20
13:25:48.955  pkts=439  seqGaps=3  lost=7   reorder=7
13:25:53.953  pkts=394  seqGaps=1  lost=18  reorder=18
```

**Cost:** 245 frames dropped waiting for a keyframe across eight decode failures — roughly 30
frames (~1.25 s) of frozen picture per event, about 10 seconds of a 234 second session.

> ⚠️ **Inferred, not verified.** The mechanism above depends on `reorder` meaning "a packet
> arrived after we had already declared a gap and moved on". That reading has not been confirmed
> against the counter definitions in the depacketizer. If it holds, most of these decode failures
> were avoidable with a modest receiver-side reorder window, and the loss is largely
> self-inflicted. If `reorder` means something else, this finding does not stand.
>
> **The check:** read the `lost` and `reorder` counter semantics in `H264Depacketizer` /
> `WHEPRTPReceiver`, and establish whether any reorder tolerance exists today.

---

## 5. There was almost no jitter, even under load

Calm windows in Run B read `min=23 max=25` against a nominal 23.97, and `worst deficit 0.000s`
holds for the entire session.

The nominal arrival rate drifts downward across the run — 23.97 → 22.13 — but that is the
estimator being pulled by the loss gaps rather than a genuine rate change. Worth noting as a
property of the metric.

**Consequence:** the 400 ms cushion is not being earned by arrival variance on this link. What
degrades under load here is loss and reordering, and no cushion size addresses that.

---

## 6. Latency, including the browser comparison

Four screenshots taken during Run B, each showing DC Color Live in a browser, OBS, and Manifold
with a burned-in timecode. At 23.98 fps, one frame ≈ 41.7 ms.

| Capture | OBS | Browser | Manifold | OBS→browser | OBS→Manifold | browser→Manifold |
|---|---|---|---|---|---|---|
| 13:24 | `02:06:06:19` | `02:06:06:09` | `02:06:06:04` | 10 f | 15 f | 5 f |
| 13:25 | `02:06:44:17` | `02:06:44:07` | `02:06:44:02` | 10 f | 15 f | 5 f |
| 13:26 | `02:07:39:22` | `02:07:39:12` | `02:07:39:07` | 10 f | 15 f | 5 f |
| 13:26 | `02:07:49:22` | `02:07:49:13` | `02:07:49:07` | 9 f | 15 f | 6 f |

```
OBS → browser        9–10 frames   ≈ 375–417 ms
OBS → Manifold      15 frames      ≈ 625 ms
browser → Manifold   5–6 frames    ≈ 208–250 ms
```

**Implication.** With Manifold's cushion at 400 ms and a ~225 ms gap to the browser, Chrome's
effective buffer on this link is roughly **175 ms** — lower than the ~275 ms previously
estimated on the development machine. Different machine, different network; both figures stand
as measurements of their own conditions rather than one superseding the other.

Note also that **400 ms of the 625 ms OBS→Manifold figure is our own cushion** — a parameter we
chose, not path latency. Everything else in the chain (encode, WHIP upload, SFU, WHEP down,
decode) accounts for roughly 225 ms.

Timings are read from burned-in timecode by eye, so accurate to about ±1 frame.

---

## 7. What this changes

**NACK and/or a receiver-side reorder window should move ahead of adaptive depth.**

NACK was banked *behind* adaptive on the reasoning that a deep buffer makes retransmission
viable, so the two pair naturally. This data inverts that. The failure mode that actually
occurred under load was loss and reorder — which adaptive depth cannot address — and it cost
about 10 seconds of frozen picture in a 234 second session. Jitter, which adaptive depth exists
to absorb, was effectively absent.

Open question already on the board and still unanswered: our SDP offer advertises `nack`, but
whether libdatachannel acts on it is unverified.

**Adaptive depth's decode-error exclusion is now a measured requirement.** Without it the
feature would actively harm this case.

**Smaller item:** the 400 ms default may be larger than this link needs, given the measured
absence of jitter. But one run is not licence to change a default that was measured on a
different link.

---

## 8. Honest limits

- Two runs, one tester, one machine, one network path.
- "High network load" is the tester's description. ~350 Mbps of background upload was reported,
  not measured by us.
- Screenshot timings are read by eye from burned-in timecode, ±1 frame.
- §4's mechanism is inferred from counter names and has not been confirmed against the
  depacketizer source.
- Run B ended with the media watchdog firing correctly — `no media for 15s on a healthy
  transport — publisher likely stopped` — when the tester stopped OBS. That is expected
  behaviour. A reader seeing the WHEP error state at the top of that export should not read it
  as a fault.
