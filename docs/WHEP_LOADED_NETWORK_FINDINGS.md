# WHEP under load — findings from two tester machines

Four diagnostics exports, plus four side-by-side screenshots.

- **Runs A and B** — Joey D'Anna's machine, 30–31 July 2026, wired ethernet. First real evidence
  from a machine that isn't the development one.
- **Runs C and D** — a second tester machine, Wi-Fi, Herndon VA. The first WHEP-vs-SRT
  comparison taken under one set of conditions, and the pair that settles the streaming
  priority (§10).

The raw exports should live alongside this document. Without them, the extracts below are
unverifiable.

---

## 1. Method and setup

**Machine 1 — runs A and B**, from the diagnostics MACHINE section:

```
Mac13,1 · Apple M1 Max · 10 cores · 64 GB · macOS 26.4 (25E246)
Displays: BenQ PV270, LG ULTRAWIDE, Elgato Prom. — 60 Hz (RENDER-PERF tickMs ≈ 16.67)
DeckLink driver installed, Desktop Video 12.8.1 (below our 14.3 floor — output unavailable)
Manifold 0.5.1 build 6, Profile configuration
Connection: wired ethernet
```

**Machine 2 — runs C and D**, same section:

```
Mac16,12 · Apple M4 · 10 cores · 24 GB · macOS 26.6.2 (25G83)
Built-in Display 1920x1200 @1x, 60 Hz, colour profile "Color LCD"
EDR headroom: current=1.000  potential=2.000
DeckLink driver 15.3.1 — meets the 14.3 floor; no device attached
NDI runtime NOT installed
Manifold 0.6.0 build 9, Profile configuration
Connection: Wi-Fi (Herndon, VA)
```

Two things about machine 2 are worth recording beyond the streaming question:

- **EDR headroom `potential=2.000`.** More headroom than the WOLED reference display, which
  reports `potential=1.000`. Relevant to the colour work rather than to anything here, but this
  is where it was first observed. It may deserve a home in `COLOR_MANAGEMENT_FINDINGS.md`.
- **The NDI runtime is absent.** First machine on which that path has been exercised at all. No
  NDI run is included below; the absence is recorded so a later reader knows the path was
  *present and unexercised* rather than tested and passed.

**Paths — and these are not the same path.** Runs A, B and C are
SDI → OBS → WHIP → Cloudflare Stream → WHEP → Manifold. Run D is OBS → SRT → Manifold,
point-to-point on the LAN. The Wi-Fi hop is common to C and D; the internet leg is not.

⚠️ **Do not read the C/D comparison as WHEP-versus-SRT in the abstract.** It compares a
cloud-relayed path against a local one, and the transport is only one of the differences. §9.2
argues the comparison is probably still fair — the loss signature in Run C looks like wireless
contention rather than internet loss — but that is **inference from the shape of the loss, not
proof**.

| Run | File | Machine | Transport | Conditions | Duration |
|---|---|---|---|---|---|
| A | `Manifold-0.5.1-diagnostics-2026-07-30-194412.txt` | 1 | WHEP | quiet wired network | 200 s |
| B | `Manifold-0.5.1-diagnostics-2026-07-31-132753.txt` | 1 | WHEP | concurrent ~350 Mbps Aspera pull | 234 s |
| C | `Manifold-0.6.0-diagnostics-⟨date⟩-⟨time⟩.txt` | 2 | WHEP | ordinary Wi-Fi | 247 s |
| D | `Manifold-0.6.0-diagnostics-⟨date⟩-⟨time⟩.txt` | 2 | SRT | same Wi-Fi, same OBS source | 268 s |

> **Filenames for C and D are placeholders.** `DiagnosticsReport.suggestedFilename()` builds
> `Manifold-<version>-diagnostics-yyyy-MM-dd-HHmmss.txt` from the *export* time, which is not
> derivable from the run contents. Fill these in when the two exports are placed in `docs/`.

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
anything in §10 — a reorder window would make it rarer, not impossible, because genuine loss
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

## 8. Run C — WHEP over Wi-Fi: genuine bursty loss, and no reordering at all

Session totals over 247 seconds:

```
150,981 packets accepted → 5,456 frames (230 key)
seqGaps=21  lost=203  reorder=0  malformed=0
5,456 access units → 5,276 frames decoded
dropped: preIDR=154  noFmt=19 | errors=7
```

**The key number is `reorder=0`.** Run B was `lost=95 reorder=94` — nearly every packet counted
as lost subsequently arrived. This is the exact opposite: 203 genuine losses, none of which
turned up late.

Given §4's audit of what those counters mean, the two runs are now measuring two different
physical phenomena with the same instrument. In Run B, `lost − reorder = 1`. In Run C,
`lost − reorder = 203`.

### 8.1 The loss is bursty, which is what points at the medium

Loss is not spread across the session. It arrives in one-second windows that are an order of
magnitude worse than their neighbours, against long clean stretches:

```
lost=43     lost=48     lost=39
```

> **TO PASTE:** the full `[WHEP-RTP]` window lines for these three bursts, and two or three
> adjacent clean windows for contrast, in the same format as §4. Not reproduced here because the
> export was not in the repo when this section was written — see the note under §1's run table.

That signature — long quiet periods punctuated by short, deep bursts — is characteristic of
**wireless contention**: a shared medium losing a run of packets while some other station holds
the air, rather than a congested queue steadily shedding load. It is not what Run B's saturated
wired link produced, and it is not what a persistently oversubscribed internet leg would look
like either.

### 8.2 Consequence: a reorder window would have done nothing here

Stated plainly, because it is the finding that moves the roadmap: **a receiver-side reorder
window would not have helped Run C at all.** Not "helped less than in Run B" — *nothing*. There
is no reordering to catch. `reorder=0` is the whole argument.

The cost of the loss, by contrast, is the largest of any run recorded here:

- **154 frames** dropped waiting for a keyframe (≈ **6.4 s** at 23.97 fps)
- **180 frames** not shown in total once `noFmt=19` and `errors=7` are added (≈ **7.5 s**)
- across a 247 s session — roughly **3% of the running time with no new picture**

### 8.3 Underruns, again, every one behind a decode failure

Seven `[WHEP-UNDERRUN]` events, and each one follows a decode failure, without exception —
the same pattern as Run B's seven, on different hardware, a different network, and a different
loss mechanism.

> **TO PASTE:** the seven decode-failure → underrun timestamp pairs, in the two-line format used
> in §3. Same reason as above.

`worst deficit 0.000s` holds throughout, and `cushion needed >= 0.400s` is again set by
decode-error recovery rather than by lateness. This is the third independent confirmation of the
§3 finding; see §10.3.

The nominal arrival rate drifts **23.97 → 23.18** across the session. As in §6, that is the
estimator being pulled by the loss gaps, not a genuine rate change — and it drifts further here
than in Run B (23.97 → 22.13 there over a comparable span) in proportion to the larger gap count.

---

## 9. Run D — SRT over the same Wi-Fi, and it did not drop a frame

Same machine, same Wi-Fi, same OBS source, 268 seconds:

```
172,386 messages, 218,578,952 bytes, recvTimeouts=2
6,417 access units → 6,417 pictures
decode failures: 0
underruns: 0 across 52 jitter windows
```

**Every frame that was sent was decoded and shown.** The two `recvTimeouts` both occurred at
startup, before data began flowing, and are not gaps in the stream.

Deliberate latency was **370 ms**: a negotiated receive latency of 120 ms plus our 250 ms
cushion, logged as `nominal`. That is *less* deliberate buffering than the WHEP path's 400 ms
cushion, and it produced zero underruns where WHEP produced seven.

**The startup anchor behaved exactly as designed on unfamiliar hardware.** The session opened
with a `GAP` anchor: 68 frames / 2.836 s of probe backlog discarded, net clock jump **+2.569 s**
— after which residual held at **≈ -0.005 s for the full 268 seconds**. The July startup-anchor
fix is therefore not tuned to the development machine; it does the same thing on a machine it
has never seen.

### 9.1 Side by side

Same machine, same Wi-Fi, same source, comparable duration:

| | **Run C — WHEP** | **Run D — SRT** |
|---|---|---|
| Path | OBS → WHIP → Cloudflare → WHEP | OBS → SRT, point-to-point on LAN |
| Duration | 247 s | 268 s |
| Received | 150,981 packets accepted | 172,386 messages / 218,578,952 bytes |
| Access units | 5,456 (230 key) | 6,417 |
| Pictures out | 5,276 | 6,417 |
| Frames not shown | **180** (preIDR 154, noFmt 19, err 7) | **0** |
| Genuine loss | `lost=203` (`reorder=0`) | none observed |
| Reordering | `reorder=0` | n/a — retransmitted by the transport |
| Decode failures | 7 | **0** |
| Underruns | **7**, each behind a decode failure | **0** across 52 jitter windows |
| Worst deficit | 0.000 s | 0.000 s |
| Deliberate latency | 400 ms cushion | 120 ms rcv latency + 250 ms cushion = 370 ms |
| Nominal rate | drifts 23.97 → 23.18 | steady |

SRT absorbed, by retransmitting, a loss condition that cost the WHEP path about 3% of its
running time — while carrying *less* deliberate latency.

### 9.2 The caveat, stated where it cannot be missed

**These are not the same path**, and the table above cannot be read as a clean transport
comparison:

- **SRT is point-to-point on the LAN.** Its packets cross the Wi-Fi hop and nothing else.
- **WHEP goes out to Cloudflare and back.** Its packets cross the same Wi-Fi hop *plus* an
  internet leg in each direction.

The Wi-Fi hop is shared between them; the internet leg is not. So the honest statement is that
Run D exonerates the Wi-Fi hop *for SRT's traffic*, not that it proves WHEP's losses happened on
the shared medium.

**The argument that the comparison is nonetheless fair** rests on the *shape* of Run C's loss
(§8.1): short deep bursts against long clean stretches, which looks like contention for a shared
radio rather than congestion on an internet path. If the losses were happening on the Cloudflare
leg, a steadier distribution would be expected.

**That is inference, not proof.** Nothing here measures where in the path Run C's 203 packets
were lost. Establishing that needs a WHEP run on wired ethernet from the same machine, which
would hold the internet leg constant and remove the radio — and which has not been done.

---

## 10. What this changes

**Priority, settled: NACK first, then the reorder window, then adaptive depth.**

This reverses the order recorded here after Runs A and B, which put the reorder window first.
The reasoning has changed as well as the order, so both are set out below rather than just the
verdict.

### 10.1 Three conditions, three signatures — and only one fix covers more than one

The three measured conditions fail in three different ways:

| Condition | Run | Signature | What a reorder window does | What NACK does |
|---|---|---|---|---|
| Wired, saturated | B | reordering (`lost=95 reorder=94`) | **fixes it** | wasteful — resends packets that already arrived |
| Wi-Fi, ordinary | C | genuine bursty loss (`lost=203 reorder=0`) | **nothing** | **fixes it** — the packets are gone and must be resent |
| SRT, same Wi-Fi | D | neither — absorbed in-transport | n/a | (this is what SRT is already doing) |

**The reorder window fixes exactly one of the three signatures.** Run C is the case it cannot
touch, and Run D is a demonstration that retransmission — which is what SRT does and what NACK
would give the WHEP path — absorbs *both* of the failure modes we have measured.

That is the technical half of the argument. It would be enough on its own, but it is not what
decides it.

### 10.2 The product reason, which is what actually decides it

**The real deployment has the encoder and the reviewing client on different networks in
different locations.** That is the whole point of the product: a colourist in one city, a client
in another. The cloud relay path — WHEP — is therefore the **common case**, and the local paths
(SRT, NDI) are the exception, useful on a facility LAN and not the thing most sessions will use.

So the everyday condition is precisely the one that just lost about 3% of its running time on
ordinary domestic Wi-Fi (§8.2), with a failure mode the previously-prioritised fix does not
address. Run B's saturated wired link is a real condition and a plausible post workflow, but it
is not the condition the product will spend most of its life in.

Ranking the fix that covers the common case below the fix that covers the exception was the
error, and it came from prioritising on the evidence that happened to arrive first.

### 10.3 The blocking question — ANSWERED, and the answer moved the work

**Was: "our SDP offer advertises `nack`; whether libdatachannel acts on it has never been
verified."** It is verified now, in three parts. Read against the libdatachannel v0.24.5 sources
(`~/manifold-webrtc-build/libdatachannel`) and the vendored archive's symbol table.

**1. Cloudflare agrees to retransmit.** The answer SDP carries both `a=rtcp-fb:96 nack` and
`a=rtcp-fb:96 nack pli`. An earlier reading of "no feedback lines in the answer" was a PARSER
FAULT, not a server behaviour — `split(separator: "\n")` in Swift compares against the
`Character` `"\n"`, and CRLF is a single extended grapheme cluster, so the split matched nothing
and handed back the whole document as one element. Both parsers are now structural and
payload-type-scoped; see `ManifoldWHEPParseVideoFeedback` in `DataChannelBridge.m`.

**2. libdatachannel has no receive-side requester, in any version.** `rtcpnackresponder.hpp` is
the SEND side. There is no `rtcpnackrequester.hpp` on master. The RTCP wire builders exist and
are exported (`RtcpNack::preparePacket`, `addMissingPacket`) but nothing decides when to send
one. So NACK was never a configuration change; the decision logic had to be written, and now is
— `H264Depacketizer.c` owns which sequence numbers to ask for and when to stop.

**3. And the request cannot currently reach the wire.** This is the finding that changed the
shape of the work, and it is not visible from the headers:

> `impl::Track::outgoing` (`src/impl/track.cpp`) refuses any message on a **RecvOnly** track
> unless its type is `Message::Control`, and the exemption that marks outgoing RTCP as Control
> is guarded by `if (!handler && IsRtcp(*message))` — it applies **only when no media handler is
> chained**. We chain `RtcpReceivingSession`, because that is what makes `rtcRequestKeyframe`
> work. The exemption is therefore disabled *precisely because PLI is enabled*, and the C API
> has no way to type a message as Control.

`rtcRequestKeyframe` escapes this only because `Track::requestKeyframe` calls `transportSend`
directly, bypassing the check. There is no other public route: a custom `MediaHandler` would get
a usable send callback, but the `int`→`shared_ptr<Track>` lookup it needs lives in an anonymous
namespace in `capi.cpp` and is unreachable from another translation unit.

**Resolution.** The `!handler` half of that guard is now removed in Manifold's own build:
`scripts/patches/libdatachannel-recvonly-rtcp.patch`, applied by
`scripts/build_libdatachannel.sh`, which fails loudly if it does not apply and asserts the guard
is actually gone afterwards. It is upstreamable — the condition contradicts the comment on the
line it guards.

The alternative considered and rejected was dropping `RtcpReceivingSession` and hand-rolling
PLI, which needs no patch but stops us sending **receiver reports** — removing the sender's loss
feedback on exactly the lossy links this work exists to improve.

**⚠️ The vendored archive must be rebuilt for any of this to reach the wire**, and the failure
mode without it is silent: requests are built, refused by the library, and never sent. The app
names that specific cause in its refusal log line, and `nacks built` vs `toWire` vs `refused` in
the session summary distinguishes it from a server that simply is not retransmitting.

**§12 supersedes this section for everything that happened afterwards** — the requester as built,
the one measured run, the refuted "invisible receiver" hypothesis, and what the measurement does
*not* say. A second hypothesis raised here and later refuted is recorded in §12.2, not deleted.

### 10.4 The reorder window stays on the board, demoted

**Not withdrawn.** Run B is real, reproducible, and a saturated wired link is a plausible post
workflow — a facility pulling dailies while a review runs. The rationale in §10.5 stands
unchanged and should not be relitigated when it is picked up.

What has changed is only its rank: it fixes one of three measured signatures, and not the one
the common deployment produces. If NACK lands and works, the reorder window's remaining value is
narrower still, because retransmission also repairs Run B's case — at the cost of a round trip
that a local window would not need. That trade is worth measuring once NACK's viability is known,
and not before.


### 10.5 Design shape for the reorder window

Recorded now so implementation does not relitigate it. **Demoted, not withdrawn** — see §10.4.

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

### 10.6 Unchanged conclusions

**Adaptive depth's decode-error exclusion is confirmed by a third independent run.** This is now
the best-supported finding in the document. Across Runs B and C — two machines, two networks,
two *different loss mechanisms* — **every underrun followed a decode failure, without a single
exception**: seven of seven in Run B, seven of seven in Run C. In both, `cushion needed >=
0.400s` was set by keyframe-wait recovery rather than by lateness, while `worst deficit` stayed
at 0.000s.

An adaptive controller consuming `measuredCushionNeeded` unfiltered would have raised the target
fourteen times across the two sessions, added latency each time, and prevented none of the
fourteen events. The exclusion is a **requirement**, not a precaution, and it now rests on
independent confirmation rather than on one run.

Run D adds a negative control from the other direction: zero decode failures, zero underruns,
across 52 jitter windows. Nothing was excluded because nothing needed excluding.

**The incomplete-AU defect (§5) is independent of all of the above** and should not wait for
either NACK or the reorder window. Genuine loss produces the same damaged access unit — and Run
C is now a measured instance of *genuine* loss at scale (`lost=203`, `reorder=0`), which is
exactly the input that defect mishandles. Run B could be argued to have been a reordering
problem wearing a loss costume; Run C cannot.

**Smaller item, now weaker:** the 400 ms default may be larger than the wired link in Runs A/B
needed, given the measured absence of jitter there. But Run D carried 370 ms of deliberate
latency on the Wi-Fi path and used it, and Run C's cushion was being consumed by decode-error
recovery rather than sitting idle. Two runs on one link are not licence to lower a default that
other links are visibly spending.

---

## 11. Honest limits

- **Runs A and B:** two runs, one tester, one machine, one network path.
- **Runs C and D:** two runs, one machine, one Wi-Fi network, one location, one session each.
  Neither has been repeated, and no run on that machine has been done over wired ethernet.
- **Runs C and D are not the same path** (§9.2). SRT was point-to-point on the LAN; WHEP crossed
  an internet leg to Cloudflare and back. The claim that the comparison is nonetheless fair rests
  on the *shape* of Run C's loss looking like wireless contention — inference, not proof. The run
  that would settle it, WHEP over wired ethernet from machine 2, has not been done.
- **Run C's burst windows are quoted from three named one-second windows** (`lost=43`, `48`,
  `39`). The full distribution across the session was not extracted, so "bursty" is characterised
  from the extremes and the clean stretches around them rather than from a computed statistic.
- **Nothing in these runs measures *where* Run C's 203 packets were lost.** Wi-Fi is the
  hypothesis the loss shape supports; the Cloudflare leg is not excluded by measurement.
- **The NDI path remains untested.** Machine 2 has no NDI runtime installed, which is why that
  path is recorded in §1 as present-and-unexercised rather than passing.
- **Run D's transport counters are SRT's own.** `recvTimeouts`, message and byte counts come from
  libsrt, not from our instrumentation, and have not been audited against the source the way §4.1
  audited the RTP counters. "Zero loss" means SRT reported none after its own retransmission, not
  that nothing was lost on the wire.
- The load is the tester's description: a concurrent Aspera pull reported at ~350 Mbps, not
  instrumented by us. The *mechanism* attributed to it in §1 — multi-stream UDP reordering
  without dropping — is consistent with the counters but was not independently confirmed.
- Screenshot timings are read by eye from burned-in timecode, ±1 frame.
- §4's mechanism is no longer inferred: it has been read against `H264Depacketizer.c` and
  `DataChannelBridge.m` and confirmed, with the session counters corroborating it. What is still
  unmeasured is *how* late the reordered packets were — the exports record that packets arrived
  out of order, not their arrival timestamps, so the window depth N in §10.5 cannot be derived
  from this data.
- The §10.5 latency claim is reasoned from the code, not measured.
- The two hazards in §5.1 are read from the code and did not occur in these runs. They are
  recorded as latent, not observed.
- Run B ended with the media watchdog firing correctly — `no media for 15s on a healthy
  transport — publisher likely stopped` — when the tester stopped OBS. That is expected
  behaviour. A reader seeing the WHEP error state at the top of that export should not read it
  as a fault.


---

## 12. NACK — built, landed, and measured once

Written after §10.3 was answered. **Read §12.3 before quoting any number from this section.**

### 12.1 What is proven

**libdatachannel has no receive-side NACK generator, in any version.** `RtcpReceivingSession`
emits PLI, REMB and RR and nothing else; `rtcpnackresponder.hpp` is the SEND side (it replays our
outgoing packets when a remote peer NACKs *us*), and no `rtcpnackrequester.hpp` exists on master.
The RTCP wire builders are there and exported — `RtcpNack::preparePacket`, `addMissingPacket` —
but nothing decides when to send one. **We wrote the requester.** It lives in
`H264Depacketizer.c` (which sequence numbers, when, when to stop), with the RFC 4585 encoding in
`RTCPNack.c` and the arming in `DataChannelBridge.m`.

**Cloudflare Stream does negotiate `nack`.** The answer SDP carries both `a=rtcp-fb:96 nack` and
`a=rtcp-fb:96 nack pli`. The earlier "no `nack` in the answer" conclusion was **our own parser**:
`split(separator: "\n")` in Swift compares against the `Character` `"\n"`, and CRLF is a single
extended grapheme cluster, so the split matched nothing and returned the whole document as one
element. Both parsers are structural and payload-type-scoped now.

**Stream does not use RTX.** It retransmits on the **same SSRC with the original sequence
number**, so a recovered packet arrives as an ordinary out-of-order packet and is claimed by the
existing `delta <= 0` branch. Nothing on the receive side needed changing to accept one, and
`reorder == recovered` is the cross-check that it is happening.

**The blocker was `impl::Track::outgoing`'s `!handler` guard.** It refuses *every* outbound
message sent via `Track::send` / `rtcSendMessage` on a track that has a media handler chained,
unless the message is typed `Message::Control` — and upstream types RTCP as Control only when no
handler is chained. We chain `RtcpReceivingSession` so that PLI works, so upstream, **enabling
keyframe requests disables receive-side NACK.** See §12.4 for the patch.

### 12.2 "We were an invisible receiver" — REFUTED

The hypothesis was that the same guard had also been blocking **Receiver Reports**, leaving
Cloudflare with no loss or jitter feedback from us at all. It is wrong, and the code path says so
plainly.

`pushRR` is called from inside `RtcpReceivingSession::incoming(messages, send)`
(`src/rtcpreceivingsession.cpp:108`) and writes through the `send` callback it is handed. That
callback is built in `impl::Track::incoming`:

```cpp
handler->incomingChain(messages, [weak_this = weak_from_this()](message_ptr m) {
    if (auto locked = weak_this.lock())
        locked->transportSend(m);          // straight to the transport
});
```

It calls `transportSend` **directly**. `Track::outgoing` — the function holding the guard — is
never on that path. The same is true of `pushPLI` and `pushREMB`, and of `rtcRequestKeyframe`,
whose `Track::requestKeyframe` also calls `transportSend` directly. **That is why PLI worked all
along.**

RR, PLI and REMB were never blocked. The guard only ever caught `Track::send`, which is the one
door a hand-built NACK had to use. We were never an invisible receiver.

### 12.3 What is NOT proven — the decode-error improvement is NOT attributable to NACK

⚠️ **State this before quoting anything else from this section.** Between the pre-NACK and
post-NACK Studio runs, decode errors went 13 → 2 and pre-IDR drops went 285 → 44. **NACK did not
cause that**, and the arithmetic is not close:

> The second run had **11× less loss to begin with** — 165 declared lost versus 15. NACK
> recovered **8 packets**. It did not prevent 150 losses, and it cannot: `declaredLost` is written
> at gap-detection time with zero lookahead and is never revised, so a recovered packet leaves it
> untouched by construction.

Two explanations for the loss difference were tested, and **both were refuted**:

- **RRs being unblocked by the patch** — refuted by the code path in §12.2. RRs were always
  being sent.
- **Cloudflare down-shifting its rate** — refuted by measurement. Mean packet rate was **660/s
  before and 663/s after**, from the 1 Hz windows. The sender did not change what it was sending.

So the two runs simply met **different path conditions**. The improvement is real and it is not
attributable. Nothing in these two runs measures NACK's effect on the outcome.

**The pending measurement.** Measuring NACK's effect on the *outcome* requires comparable loss,
and the Studio wired link no longer supplies any. The test is the **MacBook Air over Wi-Fi** —
the Run C path, which produced 203 losses, `reorder=0`, 7 decode failures and 154 pre-IDR drops
in 247 s. Run C is the pre-NACK baseline; the same machine on the same path with the requester
armed is the comparison. **Until that run exists, NACK has no measured effect on picture
quality.**

### 12.4 The one measured run

Studio, wired, ~268 s, requester armed:

```
nacks built=27 seqs=35 toWire=27 refused=0 rateSuppressed=0 gapsTooWide=0
declaredLost=15 (recovered 8 + stillMissing 7 + outstanding 0)
reorder=8 | recoveryUs avg=37523 max=43993 | lateAfterGiveUp=0
```

What this does establish, on its own terms:

- **The requests reach the wire.** `toWire=27, refused=0` is the independent evidence.
  `recovered` and `reorder` are the same arrival counted from two sides and cannot establish it.
- **53% of declared losses were recovered** (8 of 15).
- **`reorder=8 == recovered=8`** — every out-of-order arrival in the run was a packet we had
  asked for. Consistent with same-SSRC retransmission and no RTX.
- **Recovery took ~37.5 ms mean, 44 ms worst.**
- **Neither governor engaged and the window was nowhere near binding**: `rateSuppressed=0`,
  `gapsTooWide=0`, `lateAfterGiveUp=0`, `outstanding=0`. The 400 ms window has ~9× headroom over
  the worst observed recovery.

Sample size is one run, 15 declared losses, 8 recoveries. Treat the 53% as an observation, not a
rate.

### 12.5 The number the latency presets will be built on

**`recoveryUs avg ≈ 37.5 ms`, max 44 ms.**

This is the first direct measurement of a retransmit round trip on this path, and it is the input
the preset work needs. A render cushion of **~100 ms** would still leave room for a retransmit to
complete — the current 400 ms is sized for something else entirely.

Two cautions carried forward: this is one wired run, and the Wi-Fi path (§12.3) has not been
measured at all; and `recoveryWindowMs` and `WHEPFrameRouter.targetDepth` are currently two
independent constants that both happen to read 400. The preset work should make one derive from
the other rather than restate it. See `ManifoldH264LossPolicy` in `H264Depacketizer.h`.

### 12.6 The patch this depends on

`scripts/patches/libdatachannel-recvonly-rtcp.patch` removes the `!handler` half of the guard in
§12.1. It is applied by `scripts/build_libdatachannel.sh`, which fails loudly if it does not apply
and then asserts the guard is actually gone.

**Without it the failure is silent** — NACKs are built, refused by the library, and never sent, so
the symptom is "retransmission does nothing" rather than an error. `nacks built` vs `toWire` vs
`refused` in the session summary is what tells the two apart, and the refusal log line names this
patch by path.

Provenance of the vendored library is an open item — see `docs/BUGS.md`.
