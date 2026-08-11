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
| B | `Manifold-0.5.1-diagnostics-2026-07-31-132753.txt` | concurrent ~350 Mbps Aspera pull | 234 s |

**Run B's load condition is specific and reproducible.** The tester was pulling from Aspera at
~350 Mbps on the same wired link while watching the WHEP stream. That matters more than "heavy
network" would:

- Aspera is aggressive multi-stream UDP. It fills the pipe by design and does not back off the
  way TCP does, so it saturates queues and spreads a flow across paths without necessarily
  causing drops. That is a plausible mechanism for **reordering without loss**, which is exactly
  what the counters show (§4).
- It is a realistic post workflow, not a synthetic stress test: pulling dailies while watching a
  review is a normal Tuesday. Anyone reproducing this should start an Aspera transfer, not run
  iperf.

The 350 Mbps figure is the tester's reading of their transfer, not instrumented by us.

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

## 4. Run B — "lost" packets are mostly reordered (VERIFIED against the code)

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

### 4.1 The counter audit — the inference holds

This was previously flagged as inferred from counter names. It has now been read against the
source and it **stands**, more sharply than the names implied. (The check named a
`WHEPRTPReceiver`; no such file exists. The receive plumbing is `App/WebRTC/DataChannelBridge.m`
and `App/WebRTC/H264Depacketizer.c`.)

**Where the counters are incremented.** One place, `H264Depacketizer.c:238-259`:

```c
const int16_t delta = (int16_t)(seq - dp->highestSeq);   // wraps correctly at 65535
if (delta > 1) {
    dp->stats.seqGaps++;
    dp->stats.packetsLost += (uint64_t)(delta - 1);
    MDAbandonFragment(dp);
    dp->highestSeq = seq;
} else if (delta <= 0) {
    dp->stats.packetsReordered++;
    // Deliberately NOT rewinding highestSeq: this packet is late or a duplicate.
} else {
    dp->highestSeq = seq;
}
```

- `packetsLost` is a **forward-declared count**, made at gap-detection time with **zero
  lookahead** — no packets of tolerance, no milliseconds of tolerance — and never revisited.
- `packetsReordered` counts any packet with `seq <= highestSeq`. That is precisely "arrived
  after we had already declared a gap and moved past it". It also catches duplicates
  (`delta == 0`).
- **Nothing decrements `lost` when the packet turns up.** The two counters are independent
  tallies of the same event seen twice.

**What actually happens to the data.** The gap calls `MDAbandonFragment`, which wipes the
in-flight FU-A fragment and its partial NAL. When the late packet arrives it **is** received and
**is** counted — and then hits the early return at `H264Depacketizer.c:120-124`:

```c
} else if (!dp->fragmentActive) {
    // Middle/end fragment with no start: either we joined mid-NAL, or the
    // start packet was the one lost. Counted by the gap detector already.
    return;
}
```

The fragment it would have completed no longer exists, so the packet is discarded. FU-A is
87,351 of Run B's 88,258 packets, so this is the normal path, not an edge case. **The data was
in the process's hands and was thrown away.**

**There is no reorder tolerance anywhere.** Not a jitter buffer, not a reorder window, not a
holdback of any kind:

- `H264Depacketizer.c` says so in its own header: *"A jitter buffer / reorder queue. Gaps and
  out-of-order arrivals are DETECTED and counted; they are not repaired."*
- `DataChannelBridge.m:642-647` calls `ManifoldH264DepacketizerSubmitRTP` directly from
  libdatachannel's track thread. There is no buffer between the wire and the state machine.
- The only inbound handler chained into libdatachannel is `rtcChainRtcpReceivingSession`, which
  does not touch the RTP payload.
- The 400 ms cushion is **downstream of decode**. It buffers frames, not packets, and cannot
  repair a NAL.

**So `lost` means "was not available when we needed it", not "never arrived."** A packet 2 ms
late is counted identically to one that never comes. `lost − reorder` is the closer estimate of
genuine loss, contaminated only by duplicates, which land in the same bucket. On this link that
is **1 packet in 88,258**.

**The decisive evidence is an inversion.** The one window in Run B with a genuine loss cost
nothing:

```
13:23:57.955  [WHEP-RTP]   seqGaps=1 lost=1 reorder=0  |  FU-A dropped=1
13:23:57.913  [WHEP-DECODE] decoded=24/s  errors=0
```

Every one of the eight decode failures came from a window where `lost == reorder`. Real loss was
harmless; reordering was what cost 245 frames. Session totals corroborate the chain end to end:

```
seqGaps=12 lost=95 reorder=94 malformed=0 | FU-A rx=87351 reassembled=5454 dropped=11
| auClosedByTimestamp=0 wrongPt=0 wrongSsrc=0 rtcpInRtp=0
```

`wrongSsrc=0` with `accepted == received` rules out an RTX stream inflating `reorder`.
`fuaDropped=11` against `seqGaps=12` is the causal chain in one line: each gap event destroyed
about one NAL, and eight of those became a decode failure.

**Conclusion:** the loss on this link is largely self-inflicted. The packets arrived; we had
already given up on them.

---

## 5. A separate defect: we submit incomplete access units to the decoder

Surfaced by the same audit. **This is not about reordering** and should be fixed independently of
anything in §8 — a reorder window would make it rarer, not impossible, because genuine loss
produces the same situation.

When a gap destroys a fragment, `MDAbandonFragment` throws away the partial NAL — and that is all
it throws away. **The access unit is not abandoned.** The builder keeps `accessUnitActive` set,
keeps its timestamp and keyframe flag, and goes on appending later NALs to the same buffer.
Nothing in `H264AccessUnitBuilder.c` checks completeness: `MDEmitAccessUnit` emits whatever is in
the buffer and hands it to VideoToolbox.

So we knowingly submit an access unit with a slice missing. In Run B that produced
`-12909` (`kVTVideoDecoderBadDataErr`) eight times, and the router did the right thing with it —
dropped to the next keyframe and sent a PLI.

**But we are relying on VideoToolbox to catch our error, and that is not a guarantee.** `-12909`
is the *good* outcome. An incomplete AU that decoded anyway would be worse in every way: a wrong
picture, presented as correct, with no error to trigger the PLI and no counter to record it. The
failure mode we got is the one where we were lucky about which slice went missing.

The AU should be marked damaged when its fragment is abandoned, and either dropped at the builder
or flagged to the router as suspect. That decision needs its own thinking — dropping the AU costs
a frame, which on a stream with intra refresh may be worse than letting a damaged one through —
but the current behaviour, "hand it over and hope the decoder objects", is not a decision anyone
made.

### 5.1 Two adjacent hazards, neither of which fired in Run B

Recorded because they are live in the code, not because they are implicated in these numbers.
Both are latent, both are cheap to close, and a reorder window changes the odds on both.

**A late middle fragment can be spliced into the wrong NAL.** `H264Depacketizer.c:126` appends a
non-start FU-A fragment to whatever reassembly is active, with no check that it belongs there.
The only continuity test inside a fragmented NAL is the start/end bits — there is no sequence
check. If a late middle fragment arrives while a *different* NAL is being reassembled, its bytes
go into that NAL and the corruption is invisible to every counter we have.
`fuaDropped=11` against `seqGaps=12` says this did not happen in Run B; nothing in the code
prevents it.

**A late packet with an older RTP timestamp can prematurely flush the open AU.** The AU-boundary
safety net at `H264Depacketizer.c:267-272` closes the current access unit whenever an arriving
packet's timestamp differs from the open one. That check does not distinguish "the next frame has
started" from "a straggler from the previous frame just landed", so a straggler would truncate
the frame in flight and open a new AU under the old timestamp. `auClosedByTimestamp=0` for the
whole session confirms it did not occur — all of Run B's reordering stayed within a single
frame's packet run.

---

## 6. There was almost no jitter, even under load

Calm windows in Run B read `min=23 max=25` against a nominal 23.97, and `worst deficit 0.000s`
holds for the entire session.

The nominal arrival rate drifts downward across the run — 23.97 → 22.13 — but that is the
estimator being pulled by the loss gaps rather than a genuine rate change. Worth noting as a
property of the metric.

**Consequence:** the 400 ms cushion is not being earned by arrival variance on this link. What
degrades under load here is loss and reordering, and no cushion size addresses that.

---

## 7. Latency, including the browser comparison

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

## 8. What this changes

**Priority, decided: reorder window first, then NACK, then adaptive depth.**

NACK was originally banked *behind* adaptive depth, on the reasoning that a deep buffer makes
retransmission viable so the two pair naturally. This data inverts that, and the §4 audit
sharpens it further. The failure mode that actually occurred under load was reordering — which
adaptive depth cannot address and NACK addresses only wastefully, by asking the network to resend
packets that already arrived. Jitter, the thing adaptive depth exists to absorb, was effectively
absent. The reorder window is also the cheapest of the three and the only one that does not
depend on the unresolved question below.

Still unanswered and now blocking NACK rather than the reorder window: our SDP offer advertises
`nack`, but whether libdatachannel acts on inbound NACK is unverified.

### 8.1 Design shape for the reorder window

Recorded now so implementation does not relitigate it.

- **Where:** a seq-keyed ring between `DataChannelBridge.m:645` and
  `ManifoldH264DepacketizerSubmitRTP`, holding raw packets. Ahead of the depacketizer, not inside
  it — that keeps the depacketizer's contract at "packets in sequence order" and leaves the
  counters at `H264Depacketizer.c:238-259` as pure instrumentation of what the window failed to
  repair. It also inherits the existing threading discipline unchanged: one producer thread, no
  locking.
- **Release policy: depth-triggered, not timer-triggered.** Release on contiguity — the moment
  the next expected sequence number is present — and force-release the lowest held seq when the
  ring exceeds N. No timer, no thread, no allocation in the steady state, consistent with the
  "never blocks, never allocates, never logs" rule the receive path already keeps.
- **N:** to be chosen from a real trace. Run B's largest single gap was 21 sequence numbers, so
  N=32 is the starting hypothesis, not a conclusion.

**Latency claim — REASONED, NOT MEASURED.** In the steady state the added latency should be
**zero**: in-order packets release on contiguity the instant they land, and the window only holds
anything during a discontinuity. The worst case should be N packet-times of stall (~73 ms at Run
B's ~440 pkt/s with N=32), on the order of a dozen occasions per 234 s, and absorbed by the
existing 400 ms render cushion rather than added to end-to-end latency — visible as a transient
dip in queue depth, not as a latency increase.

That whole paragraph is reasoning from the code, not a measurement. **Measure it against a real
depth trace during implementation**, and specifically confirm that the dip stays inside the
cushion instead of producing the underruns the change is meant to prevent.

### 8.2 Unchanged conclusions

**Adaptive depth's decode-error exclusion is now a measured requirement.** Without it the
feature would actively harm this case.

**The incomplete-AU defect (§5) is independent of all of the above** and should not wait for the
reorder window. Genuine loss produces the same damaged access unit.

**Smaller item:** the 400 ms default may be larger than this link needs, given the measured
absence of jitter. But one run is not licence to change a default that was measured on a
different link — and the reorder window has a claim on some of that cushion.

---

## 9. Honest limits

- Two runs, one tester, one machine, one network path.
- The load is the tester's description: a concurrent Aspera pull reported at ~350 Mbps, not
  instrumented by us. The *mechanism* attributed to it in §1 — multi-stream UDP reordering
  without dropping — is consistent with the counters but was not independently confirmed.
- Screenshot timings are read by eye from burned-in timecode, ±1 frame.
- §4's mechanism is no longer inferred: it has been read against `H264Depacketizer.c` and
  `DataChannelBridge.m` and confirmed, with the session counters corroborating it. What is still
  unmeasured is *how* late the reordered packets were — the exports record that packets arrived
  out of order, not their arrival timestamps, so the window depth N in §8.1 cannot be derived
  from this data.
- The §8.1 latency claim is reasoned from the code, not measured.
- The two hazards in §5.1 are read from the code and did not occur in these runs. They are
  recorded as latent, not observed.
- Run B ended with the media watchdog firing correctly — `no media for 15s on a healthy
  transport — publisher likely stopped` — when the tester stopped OBS. That is expected
  behaviour. A reader seeing the WHEP error state at the top of that export should not read it
  as a fault.
