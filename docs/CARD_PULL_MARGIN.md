# The card pull's margin over the window swap

Read-only audit, 2026-11-16, for `BUGS.md` *AFTER 0.9.4: the card pull's margin over the window swap is under one refresh in many
Plays, so one late frame is a repeat*. No code was changed, built or launched. Line numbers are HEAD `537726a` (working tree clean).

**Labels.** **CONFIRMED** = read in the code (file:line), a log line, or a count over the soak logs by the method in §0.
**UNKNOWN** = not established; where a likely answer exists it is given as "UNKNOWN (inference: …)". Options, predictions and
specifications in §7–§10 are proposals, not findings.

## Summary

1. **The 9aaff2d due-frame selection still runs on every timed pull, but at a matched rate §10.30 widened its "would repeat" band
   from 2 ms to half a card frame** (`MetalVideoRenderer.swift:5730-5731`, `:5750`). The pull now takes the frame after the one
   handed last as soon as that frame is in the ring and due within half a frame of the target. So in steady play the card takes
   each frame at the first pull after the window swaps it in. CONFIRMED (§1).
2. **The "late swap" is not a missed tick, a slow render or decode starvation.** In all three holds the output pacer's tick, which
   runs on the host clock, was drifting against the frame due times on the content clock, which card lock puts on the card. The
   drift is about 12 µs/s, the card's rate against the host. The tick crossed a due time, and from then on every frame rendered
   one tick later. CONFIRMED in 0.9.3 and 0.9.4 (§5).
3. **Exposure is lower than BUGS.md's 38 %.** `swapAgo` is measured from the newest swap. When the card is already a frame behind
   the window, a late swap cannot cause a hold. Measured from the handed frame's own swap, **76 of 525 steady-play segments
   (14 %)** were exposed. 62 of those 76 are exposed only because of the half-frame band. CONFIRMED (§2.4).
4. **The "display refresh" in BUGS.md is the output pacer's period** (`P = frame / k`: 8.34, 13.90, 13.33 ms), not a display's.
   With output on, no display drives the window (`OutputPacer.swift:1-11`; the logs' `[PACER] started … P 13.90 ms (k 3, 71.93 Hz)`).
   CONFIRMED.
5. **Recommendation: option C.** Keep the output pacer's phase fixed against the content clock's frame grid while a file plays,
   and guard the phase at Play. It is behind a DEBUG switch, off by default, and comes after a logging-only measurement build.
   It removes the one cause seen, and it touches only the pacer and one measurement in the tick. It leaves alone the pull, card
   lock, SDI audio, Stage 2, slips, the watchdog and the decode pump. It does not shrink the 14 % exposure: a late swap from any
   other cause would still hold. None was seen in about 10 video-block hours (§5). §8 has the reasons.

---

## 0. Method

- **Logs, read only:** 0.9.4 soak `~/Code/_scratch/manifold-rc094-soak/` (`rc-5994-sdi-1/2`, `rc-2398-cmp-1/2`, `rc-gop25-sdi-1`);
  0.9.3 soak `~/Code/_scratch/manifold-rc-soak/` (`rc-5994-sdi-1/2`, `rc-2398-cmp-1/2`, `rc-noaudio-sdi-1`). The WAV blocks have no
  window picture and were not analyzed.
- **Lines used:** `[CADENCE] #idx host … pts … swapAgo … clock …`, one per pull (`DeckLinkService.swift:1194-1198`), and `[CADENCE-SWAP] host … pts …`,
  one per ring publish (`MetalVideoRenderer.swift:5451`, `:5571`). Also `[PACER]`, `[PLAYBACK-STATS]`, `[CARDLOCK]` and `[RENDER-PERF]`.
- **Steady-play segment:** a run of ≥ 100 consecutive pulls in which the clock advances one frame (±25 %) per pull. A Play is split at its
  loop wrap, so a block gives 105 segments, not its 63 Plays. The first 50 and the last 15 pulls of each segment are dropped.
- **swap − due:** the content clock at a swap minus that frame's pts. The clock at the swap is the next pull's logged clock less the
  host time between them (valid at 1×). It equals (tick − due) + (tick → ring). The pacer logs tick → ring: median 0.93–1.05 ms,
  max 1.63–3.30 ms (`[PACER] desktop 10 s … tick → SDI ring` near each hold).
- **Lead:** pull host minus the host of the latest `[CADENCE-SWAP]` *of the handed pts*. This differs from `swapAgo`, which is
  measured from the newest swap of any pts.
- **Late swap:** a swap more than P/2 above the 10th percentile of its segment's swap − due. **Crossing:** a segment that has late swaps.
- The analysis scripts were throwaway, in the session scratchpad, and are not kept. Each figure below says how it was computed.

---

## 1. The pull today

### 1.1 Card lock on (default)

The path, CONFIRMED by code:

1. The SDK's fill calls `copyLatestDeckLinkFrame` (`DeckLinkService.swift:1184-1188` → `MetalVideoRenderer.swift:5637`). It reads the clock
   and host time and calls `deckLinkPullSlotLocked` (`:5677`).
2. For a file, `deckLinkPullByTime` is true (`DeckLinkService.swift:1484`). The slot timeline is the minimum of the paced pulls'
   offsets (`:5698`).
3. Paused or a pause landing (`:5709`): the newest frame, reached one frame per pull. A step, seek, loop wrap or shuttle (`:5718`):
   the newest frame.
4. **Playing at 1×, a timed pull:** `target = clock − (host − slotHost) − margin` (`:5721`), with margin = median tick interval + 10 ms
   (`:5263-5267`). With output on, the tick is the pacer's, so margin = P + 10 ms: 18.34 ms at 59.94, 23.90 at 23.976, 23.33 at 25.
   - `due` = the newest ring frame with `floor ≤ pts ≤ target` (`:5736-5739`).
   - **The would-repeat branch** (`:5749-5750`): if `due` is the frame handed last, take the next frame if `pts[next] ≤ target + band`.
   - **`band` = half a card frame at a matched rate, 2 ms at a mismatch** (`:5730-5731`).
   - If the next frame is not in the ring, hold the frame handed last (`:5757-5758`): **the repeat**.
5. The ring holds only frames the window has rendered: the convert is pushed from the window's render completion
   (`MetalVideoRenderer.swift:4182`), and a slot is chosen only after its convert publishes (`:5354`, `:5429-5433`).

**So, at a matched rate, which frame does the card get?** Under card lock the target advances exactly one frame per slot, so the
handed frame keeps a fixed phase to the target for the whole Play. The half-frame band lets that phase settle up to F/2 *after*
the target. From then on the card takes frame N+1 at the first pull after it reaches the ring: **the frame the window last
swapped in**, or the one before it when the window is already a frame ahead. CONFIRMED by the code above. The logs agree:

- At every steady-play pull, the handed frame was the window's newest or exactly one behind it. Never two:
  - `rc-5994-sdi-1`: 106,640 newest, 87,882 one behind.
  - `rc-2398-cmp-1`: 62,787 newest, 10,960 one behind.
  - `rc-gop25-sdi-1`: 65,904 newest, 11,289 one behind.
  - Tally: newest `[CADENCE-SWAP]` pts at each pull against the handed pts.
- In the 0.9.4 hold Play, the handed frame trailed the clock by 11.7 ms at each pull (`rc-2398-cmp-1.log:181783`, clock 986.413624, pts
  986.402083). Its margin target was at least 23.90 ms behind the clock, so the frame sat at least 12.2 ms after the target: outside
  a 2 ms band, inside a 20.85 ms one. The other two holds are the same: 14.1 ms (`rc-gop25-sdi-1.log:58247`) and 9.8 ms
  (0.9.3 `rc-2398-cmp-2.log:112668`), against margins of 23.33 and 23.90 ms.

**Was 9aaff2d's selection bypassed?** No. It runs on every timed pull. At a matched rate it was **narrowed in effect**: its
margin no longer sets the lead.

- **Where:** `CARD_CLOCK_FINDINGS.md` §10.30 ("Fix (`MetalVideoRenderer.deckLinkPullSlotLocked`)"), build `fu11` = `fu10` + this change +
  card lock on by default (`CARD_CLOCK_FINDINGS.md:2115`).
- **The commit:** the half-frame band (`MetalVideoRenderer.swift:5725-5731`, `:5750-5751`) is from `537a3516` (2026-11-14, the
  0.9.3 candidate); the surrounding due-frame selection (`:5732-5749`) is unchanged from `9aaff2d`. CONFIRMED by git blame (Robbie,
  2026-11-16).
- **It shipped in 0.9.3:** CONFIRMED. The 0.9.3 soak's hold Play handed a frame 9.8 ms behind the clock with a 23.90 ms margin,
  which only the half-frame band allows. The 0.9.3 candidate is `537a351` (`Manifold-BUILD.md:124`).
- **Why it was done** (§10.30, code comment `:5725-5729`): 6 of 101 output restarts at 59.94 held one frame. The margin, a tick plus 10 ms, was
  1.65 ms more than a 59.94 frame, so the handed frame sat about 1.8 ms past the target. It was taken only through the 2 ms band,
  and a pull that wobbled past that band's edge re-handed a frame. The half-frame band fixed it: `h27-5994`, 0 holds in 107 starts.
  §10.30 did not look at what the wider band does to the lead at Play.

### 1.2 `MANIFOLD_CARDLOCK_1B=0`

- **Pull code: identical.** `deckLinkPullSlotLocked` never reads the gate; the band depends only on `deckLinkSourceFrame` against
  `deckLinkCardFrame` (`:5730`). CONFIRMED by code.
- **Clock:** for a file with sound, card lock does not apply (`FrameEngine.swift:927-934`; `CardClockAudio.swift:16-17`). The clock
  is the audio device's. A file with no sound is still locked (1a: `audioPresence == .absent`, `:933`). An audio-only file has no
  virtual timeline and plays on the Mac (`:928-930`).
- **What follows:** UNKNOWN (inference). The card still takes each frame once it reaches the ring, so the card holds the window's
  frame as it does with the lock on. The frame-to-slot phase walks at the card-against-device rate, about 17.6 ppm on this rig
  (§10.11). Each time it passes a band edge the card slips: a repeat or a skip, the known unlocked behavior. The tick-to-frame
  phase walks at the device-against-host rate, about +6 to +7 ppm on this rig (§10.12 B1). That is opposite in sign to the locked
  case, so a crossing would move a swap one tick *earlier*, which cannot cause a hold. No `=0` soak exists at HEAD, so none of
  this is measured.

---

## 2. Where the lead comes from

### 2.1 What sets the phase

Three timelines meet at the pull. CONFIRMED by code:

| Timeline | Set by | When it is set |
|---|---|---|
| Card slots | The card. The pull's slot timeline is its minimum offset (`MetalVideoRenderer.swift:5689-5698`) | Output start; continuous across Plays |
| Frame due times on the host | `setTransportRate` → `synchronizer.rate = rate` (`FrameEngine.swift:1090-1092`), on main, with no reference to slots. Card lock then latches φ and holds this phase (§10.1 "Latch") | **Each Play** |
| Window ticks (with output on: the pacer) | `OutputPacer.loop`: a resume sets `deadline = now + step` (`OutputPacer.swift:116-120`); then `deadline += step` on the host clock (`:131`) | **Each wake.** The pacer stops after 0.5 s paused with nothing to draw (`MetalVideoRenderer.swift:809-845`, `idleAfter` `:706`). The wake restarts its phase (`:747-755`). `[IDLE] display link stopped` appears 109 times in `rc-2398-cmp-1.log` |

- The window renders frame N at the first tick whose clock reading is at or past its pts. A pacer tick selects at the clock as read,
  with no glass lead (`OutputPacing.swift:108-116`; `MetalVideoRenderer.swift:3636-3672`). The convert finishes about 1 ms later.
- Since §1.1, the card takes N at the first pull after that publish. So the lead is the time from swap to next pull. It is set by
  where Play put the frame grid against the slots, plus where the wake put the ticks against the frame grid.
- **Both are set afresh at each Play, independently. That is why the lead is random per Play.** CONFIRMED by code. The spread is
  CONFIRMED by measurement (BUGS.md's table; §2.4).

### 2.2 Is the window's frame chosen with any regard to the card?

**No.** CONFIRMED by code.

- Selection is "newest frame with pts ≤ selectNow" (`MetalVideoRenderer.swift:3664-3676`), and `selectNow` is the clock as read
  (`OutputPacing.swift:108-116`).
- The pacer's period comes from the frame rates (`OutputPacing.swift:24-30`); its phase comes from the wake.
- The only link between the window and the pull runs the other way: the pull's margin reads the tick interval
  (`noteDeckLinkTick`, `:5249-5257`).

### 2.3 The lead within a Play

- The lead is fixed within a Play only roughly. The pacer runs on the host; under card lock the content clock and the pulls run on
  the card.
- The card ran at −10.5 to −10.9 ppm against the host in every 0.9.4 block (median of `[CARDLOCK] card … ppm`). So each frame's
  tick lands about 11 µs/s earlier relative to its due time, and the lead grows by that amount.
- That is about 0.5 ms over a 45 s Play: too little to matter to the lead, but enough to carry a tick across a due time (§5).

### 2.4 Exposure, measured two ways (0.9.4)

| Block | P | Segments | `swapAgo` median < P (BUGS.md's method) | Handed frame's own lead < P | Card mostly a frame behind the window |
|---|---|---|---|---|---|
| 59.94 SDI (1) | 8.34 | 105 | 54 | 10 | 46 |
| 59.94 SDI (2) | 8.34 | 105 | 46 | 7 | 43 |
| 23.976 Computer (1) | 13.90 | 105 | 35 | 20 | 16 |
| 23.976 Computer (2) | 13.90 | 105 | 32 | 20 | 13 |
| 25p SDI | 13.33 | 105 | 30 | 19 | 14 |
| **Total** | | **525** | **197 (38 %)** | **76 (14 %)** | 132 |

- **The two methods differ when the card is already a frame behind the window.** Frame N+1 is then in the ring before the pull
  whatever happens to N+2's swap, so a late swap cannot cause a hold. CONFIRMED in the logs: Plays with hundreds of late swaps and
  the card one behind had 0 repeats (§5.2).
- **What makes a segment exposed** (handed frame's median clock − pts at the pull, against margin − 2 ms):
  - **62 of the 76** were exposed only because of the half-frame band. A 2 ms band would have handed one frame later.
  - **14** would have been exposed under 9aaff2d's 2 ms rule too, with leads of about 9 ms up to P. The margin of P + 10 ms covers
    the first tick after due plus the render; it never covered a tick late.
- **All three holds were in band-only segments:** clock − pts of 11.7, 14.1 and 9.8 ms (§1.1).

---

## 3. What is in the ring at pull time

**A frame is converted for the card only when the window renders it.** CONFIRMED.

- `pushDeckLinkConvert(sourcePts:)` runs only from the window's render completion (`MetalVideoRenderer.swift:4182`). It converts the
  window's readable offscreen (`:5358-5361`), the picture after the color pipeline.
- The window renders only frames with pts ≤ clock (`:3670`).
- So the ring never holds a frame the window has not shown, and a frame due at a slot cannot be converted first.

**Converting the due frame from the decoded queue instead** is `SDI_OUTPUT_TIMING.md` §3, "the full fix", stages 1–3:

1. Split `renderPixelBuffer` into an offscreen pass and a present pass.
2. Read the frame queue without consuming it: today the window's tick removes frames (`:3680-3682`).
3. Drive an off-screen render-for-output from the card's slots, choosing "the frame due at slot n" by 9aaff2d's rule, with the ring
   as the fallback.

Its own risk list (`SDI_OUTPUT_TIMING.md:125-133`) covers paused priming, seek renders, scopes, live clocks and SDI audio's anchor.

**What it costs:**

| Cost | Value | Status |
|---|---|---|
| GPU at 1080p | A second offscreen pass + v210 per frame while the window is visible. One render today: `gpuMs` 0.06–0.08 ms (`[RENDER-PERF]` near each hold) | CONFIRMED for one pass; ×2 is arithmetic |
| GPU at 4K / 8K | Not in these logs | UNKNOWN |
| Memory | A second offscreen ring. Assuming rgba16Float (the E1 note on `rgba16FloatToRGBA16`): 66 MB per 4K texture, 265 MB per 8K. The v210 ring is already 4 × 22 MB at 4K and 4 × 88 MB at 8K (row bytes rounded to 128) | Arithmetic, not measured |
| Latency | Any margin can be chosen, up to the decode queue's lead over the clock. That lead is not logged here | UNKNOWN |
| Lead | The card would no longer depend on the window's swap. The swap-to-pull question disappears, but the card and the window could then show different frames: a new invariant to hold | Design |

---

## 4. The three holds

| Hold | Pull that repeated | Next frame converted? | Next frame decoded? | Window `late` / `dropped` that second |
|---|---|---|---|---|
| 0.9.4 Computer 23.976, `rc-2398-cmp-1.log:181796` (#84158) | 986.402083 again | **No.** 986.443792 published 3.28 ms after the pull (`:181797`) | **Not due at the tick before.** That tick's clock was ~0.0x ms short of 986.443792 (§5.1). Whether the frame sat in the queue then: UNKNOWN | 0 / 0 (`[PLAYBACK-STATS] t=987.208`) |
| 0.9.4 SDI 25p, `rc-gop25-sdi-1.log:58250` (#27075) | 261.480000 again | **No.** 261.520000 published 0.43 ms after the pull (`:58251`) | Same as above | 0 / 0 (`t=262.120`) |
| 0.9.3 Computer 23.976, `rc-2398-cmp-2.log:112669` (slots 52149/52150) | 933.057125 again | **No.** 933.098833 published 5.15 ms after the pull (`:112670`) | Same as above | 0 / 0 (`t=933.224`) |

- **Why "not due" and not "not decoded":** `late` counts a frame selected although it was already due at the previous tick
  (`MetalVideoRenderer.swift:1641`, `pts <= prevNow`). It was 0 in each hold's second.
- So the previous tick ran before the frame's due time: not decode starvation. Had the frame been due and missing from the queue,
  `late` would have counted it. CONFIRMED.
- What the logs cannot say is whether the frame was already decoded and queued at that earlier tick. **To answer it:** stamp each
  queued frame's enqueue host time (DEBUG) and log it at each late swap with the previous tick's clock. Specified in §9.1.

---

## 5. The late swap

### 5.1 Evidence

The window's swap − due in each hold's Play, by 5 s bins. Min / median / max in ms; "late" = bins' swaps more than P/2 above the bin minimum:

| s into Play | 0.9.4 23.976 Computer (`:179949`) | 0.9.4 25p SDI (`:56516`) | 0.9.3 23.976 Computer (`:110567`) |
|---|---|---|---|
| 0–5 | 1.20 / 1.33 / 7.89 | 0.82 / 1.28 / 6.17 | 0.86 / 1.41 / 1.70 |
| 10–15 | 0.97 / 1.18 / 1.75 | 0.73 / 1.18 / 1.37 | 0.74 / 1.26 / 1.81 |
| 20–25 | 0.63 / 1.06 / 1.28 | 0.67 / 1.11 / 1.92 | 0.67 / 1.10 / 1.40 |
| 25–30 | 0.88 / 1.01 / 1.70 | 0.71 / 1.03 / 1.54 | 0.58 / 1.08 / 1.29 |
| 30–35 | 0.62 / 0.95 / 14.93, **14 late** | 0.60 / 14.32 / 15.09, **82 late** | 0.57 / 0.94 / 1.34 |
| 35–40 | 0.89 / **14.81** / 15.25, 116 late | 14.20 / 14.33 / 16.59 | 0.46 / 0.97 / 15.02, **15 late** |
| 40–45 | 14.29 / 14.75 / 15.19 | (one more crossing back and forth) | 0.87 / **14.81** / 15.43, 116 late |
| Hold | 34.3 s (first late swap) | 31.0 s | 39.1 s |

Each Play shows the same pattern. CONFIRMED:

- **A steady drift.** The median swap − due falls by about 12 µs/s: 1.33 → 0.95 ms over 30 s. That matches the card's −10.5 to
  −11.9 ppm against the host (§2.3), and has the right sign: the content clock is slower, so each due time arrives later on the host.
- **The crossing.** Once swap − due reaches the tick → ring time (~0.93 ms), the tick is at the due time. For a few seconds the
  frames split between two ticks. Then every frame renders one tick later (swap − due ≈ P + 0.9 ms).
- **The window's own cadence breaks while it dithers.** Swap intervals of 55.7 then 27.6 ms at 23.976
  (`rc-2398-cmp-1.log`: swaps at .156750, .184396).

**The other causes, ruled out for these holds:**

| Candidate | Evidence | Verdict |
|---|---|---|
| Missed tick | The pacer, not CVDisplayLink, ticks with output on. `[PACER] … missed deadlines 0` and run interval max 14.01 / 13.42 / 13.97 ms in all three hold blocks. The 10 s lines around each hold: max 13.93, 13.36, 13.92 ms, missed 0 | **Ruled out.** CONFIRMED |
| A render over one tick | tick → SDI ring max 1.63, 3.30, 1.56 ms in those 10 s lines; `latMs` 0.61–0.70 (`[RENDER-PERF]`) | **Ruled out.** CONFIRMED |
| Main-thread stall | The tick runs on the pacer thread, and no main-thread wait was found in it (`displayTick` `:3403-3431`) | UNKNOWN (not logged; inference: not in the path) |
| Decode starvation | `late` 0 in each hold's second (§4) | **Ruled out.** CONFIRMED |
| **Tick crossing a due time by drift** | The tables above | **The cause, all three.** CONFIRMED |

### 5.2 Every late swap in both soaks was a crossing

The method of §0 over all 10 video blocks: every segment with late swaps had swap − due near 0 or near P + 0.9 ms, the
due-time boundary. No late swap occurred anywhere else. CONFIRMED.

| Soak / block | Segments with a crossing | Exposed at the crossing | Holds |
|---|---|---|---|
| 0.9.4 59.94 SDI (1) | 6 | 0 (leads 13–22 ms, P 8.34) | 0 |
| 0.9.4 23.976 Computer (1) | 3 | 1 (lead 10.6 ms) | **1** |
| 0.9.4 25p SDI | 1 | 1 (lead 13.0 ms, P 13.33) | **1** |
| 0.9.4 59.94 SDI (2) | 0 | – | 0 |
| 0.9.4 23.976 Computer (2) | 0 | – | 0 |
| 0.9.3 59.94 SDI (1) | 3 | 0 | 0 |
| 0.9.3 59.94 SDI (2) | 4 | 0 | 0 |
| 0.9.3 no sound SDI | 2 | 0 | 0 |
| 0.9.3 23.976 Computer (1) | 2 | 0 | 0 |
| 0.9.3 23.976 Computer (2) | 4 | 1 (lead 8.6 ms) | **1** |
| **Total** | **25 in 1,050 segments** | **3** | **3** |

- A crossing with the card already a frame behind gave 0 repeats, even with hundreds of late swaps (e.g. 0.9.4 23.976 (1) segment 16:
  434 late swaps, lead 52.8 ms, 0 repeats). CONFIRMED.
- The hold count is crossings × exposure at the crossing. Why some blocks had none: UNKNOWN (inference: chance; every block's card ran
  at the same rate).

### 5.3 What a measurement build must log to tell the causes apart

The full specification is §9.1. Per late swap it needs:
- the previous tick's clock minus the frame's pts (a crossing: small and negative);
- the frame's enqueue host time against that tick (decode);
- the pacer's interval before the tick (missed tick);
- tick → ring for that frame (render);
- the tick's duration from `watchTickBegan`/`watchTickEnded` (`:3430`, `:3441`) and a main-thread heartbeat lag (main stall).

---

## 6. Invariants any fix must keep

| # | Invariant | Where it is held today |
|---|---|---|
| I1 | **Window and card on the same frame within card lock's bounds.** Measured today: the card's frame is the window's newest or exactly one behind at every steady-play pull (§1.1). By construction: at destination Computer the Mac's sound follows the SDI picture (Stage 2), not the window. So the window's picture against the Mac sound already varies per Play by up to about one frame plus one tick, because the swap-to-pull lead does. UNKNOWN at a device; CONFIRMED by construction | `deckLinkPullSlotLocked` `:5677-5762`; Stage 2 `stage2Tick` `FrameEngine.swift:1235` |
| I2 | **SDI audio aligned to `currentDeckLinkSourcePts`.** The anchor is the handed frame and its slot. So SDI picture and sound move together whatever frame is handed | `MetalVideoRenderer.swift:5607-5613`, `:5653-5658`; `currentDeckLinkHanded` `:5586`; bridge `noteHandedFrame`/`handedFrame` `DeckLinkBridge.mm:1289-1296`, `:1931`; picture line `:1810`; run end "off the line on a timed pull" `:1748-1751` |
| I3 | **Slip writes and the Mac-sound re-anchor.** A new picture line re-anchors the Mac's sound once (`… re-anchored to the SDI picture at its new line #n (a slip)`). The test switch `MANIFOLD_DECKLINK_SLIP_AT` moves the pull target | `FrameEngine.swift:1281-1297`; `MetalVideoRenderer.swift:510-520`, `:5663-5675`, `:5721` |
| I4 | **Stage 2 alignment.** `e = m − (w + K)`; coarse and slip bounds; the start with the SDI picture; rate mismatch on the picture clock | `FrameEngine.swift:1178` (`stage2ResolvePending`), `:1235` (`stage2Tick`), `:1090-1100` (`setTransportRate`) |
| I5 | **Card-lock clock (1a/1b)** | `cardClockTick` `FrameEngine.swift:1342-1376`; `CardClockAudio.swift:16-17` |
| I6 | **Paused, step, seek, shuttle, loop wrap.** Paused: newest, one frame per pull. Step, seek, wrap, shuttle: newest. Wrap or seek back: the floor resets | `MetalVideoRenderer.swift:5709-5718`, `:5734` |
| I7 | **Stills and audio-only on SDI.** The held picture and B5's virtual pulls bypass the ring and the pull | `DeckLinkService.swift:1165-1183` (`copyHeldPicture`); `noteDeckLinkVirtualPull` `MetalVideoRenderer.swift:5174` |
| I8 | **Freeze containment.** The pacing-renderer watchdog and near-miss | `FrameEngine.swift:1621` (`nearMissAfter`), `:1641` (`rendererWatchdogTick`), `[RENDERER-NEARMISS]`, `[RENDERER-RECOVER]` `:1718` |
| I9 | **Decode pumps** | `FileFrameSource.swift:138`, `:185`; `LibavFrameSource.swift:513` |
| I10 | **No repeats traded for skips.** 0 skips in both gates; a fix must keep 0 | gate tables, `Manifold-BUILD.md:139-147`, `:190-199` |
| I11 | **The pacer contract:** a stop waits for a tick in flight; a missed deadline is skipped, never made up in a burst | `OutputPacer.swift:13-17`, `:58-65`, `:131-137` |

---

## 7. Fix options

The user's three named cases are pacer rates at a matched card and source rate, not display mismatches:
- 25p: P 13.33 ms, k 3, 75 Hz.
- 23.976: P 13.90 ms, k 3, 71.93 Hz.
- 59.94: P 8.34 ms, k 2, 119.88 Hz.

The true rate mismatch is C6, e.g. a 25p file on 1080p59.94: P 8.34 ms (k 2 of the card frame), 4.8 ticks per source frame,
band 2 ms (`:5731`). No C6 block ran in either soak, so the hold rate at C6 is UNKNOWN.

### A. Restore due-frame selection on the card's slot timeline

**How it works.** At a matched rate, the lock-step phase is set only by the strict rule: on the first timed pull after a Play, step,
seek or wrap, the next frame is taken only if `pts ≤ target`. After that the half-frame band stays, as hysteresis against wobble,
so §10.30's edge holds stay fixed.

Two variants:
- **A1:** also raise the margin to cover one late tick: 2P + 5 ms.
- **A2 (establishment guard):** keep the margin, but at establishment take the next frame only if its swap was at least P + 2 ms
  before the pull. That needs each ring slot's publish host time.

A plain revert of the band to 2 ms is excluded: it brings back §10.30's 6-in-101 holds at 59.94.

**Code touched.**
- `deckLinkPullSlotLocked` (`:5677-5762`); `deckLinkPullMarginLocked` (`:5263`) for A1; per-slot publish time
  (`publishDeckLinkSlotLocked` `:5240`) for A2.
- The margin also feeds `deckLinkPullDueNow` (`:5723`), the C6 line.
- **Untouched:** card-lock clock, SDI audio code, Stage 2 code, slip and re-anchor code, the watchdog, the decode pumps, the pacer.
- **Behavior they see changes:** the handed frames, and so the bridge's picture line (I2), Stage 2's `w` (I4) and the slip detector (I3),
  all shift with it.

**Latency.**
- Today's band-only segments (≈ 62 of 525 in 0.9.4) would hand one frame later: +F.
- A1 also adds about P + 5 ms everywhere, so the card would be up to two frames behind the window (I1 widens).
- SDI A/V: unchanged by construction (I2). Re-verify it on the loop; it does not need re-measuring.
- **Destination Computer:** the Mac sound follows the SDI picture, so the window's picture against the Mac sound moves later by the
  same amount. That must be measured and decided by Robbie.

**Risks.**
- It changes the code path whose patterns 9aaff2d and §10.30 fixed. Holds at establishment are possible if a target wobbles at
  the first pull: the §10.30 signature, log `[CADENCE]` same pts twice at Play.
- Play start latency grows by a slot in the affected Plays: more "start latency" repeats at Play.
- C6's due line moves (A1).

**Rate cases.**
- 59.94: margin 18.34 is F + 1.66, so the card is 1–2 frames behind; the §10.30 restart stress must be repeated.
- 23.976 / 25: margin ≈ 0.57 F.
- C6: unchanged for A2; for A1 the due line moves.

**Switch:** `MANIFOLD_PULL_ESTABLISH=strict|guard` (env, DEBUG), default off. Off = today's branch, unchanged.

**Effect on exposure** (inference from §2.4): A2 → about 0 % for one late tick; A1 → about 0 %; strict establishment alone →
14 of 525 (2.7 %).

### B. A fixed lead of one tick plus slack, imposed on the window

**How it works.** The window's selection gets a per-Play look-ahead λ, so that each swap lands P + slack before the card's pull.

**Code touched:** `WindowPresentTiming.selectionTime`, the pacer, and a new read of the card's slot timeline by the window. The
window would then depend on the card.

**Latency.** Under card lock the frame-to-slot phase is random per Play (§2.1), so λ ∈ [0, F) per Play: up to 41.7 ms at 23.976.
The window would show each frame up to a frame before its clock says, by a different amount each Play. At Computer the window's
picture against the Mac sound would then vary per Play by up to a frame, on top of I1's variation. SDI A/V: unchanged (I2).

**Risks.**
- It changes the window's picture timing, which output-off playback shares through the same selection code.
- It couples the window to card state at every Play.
- Rate cases: λ up to F, at all three rates. At C6 it is undefined, because there is no fixed frame-to-slot phase.

**Verdict: not recommended.**

### C. Hold the output pacer's phase against the frame grid (recommended)

**How it works.**
1. **Measure.** At each pacer tick that selects a new frame while playing at 1× at a matched rate, take x = selectNow − chosenPts:
   how long after its due time this tick is. It sits in [0, P). (`performDisplayTick`, after the selection at `:3664-3681`; the
   values are already in hand.)
2. **Set the reference.** At the first such tick after a wake, a re-rate or a clock discontinuity, x_ref = the median of the first 8 x.
   **Guard:**
   - x_ref < 0.5 ms → x_ref = 0.5 ms: the ticks move later by ≤ 0.5 ms, the lead shrinks by ≤ 0.5 ms.
   - x_ref > P − 0.5 ms → x_ref = P − 0.5 ms: the ticks move earlier, the lead grows.
   - 0.5 ms is about 8× the dither width seen at the crossings: about 5 s at 12 µs/s ≈ 60 µs (§5.1).
3. **Follow.** Each tick, the pacer adds a correction to its next deadline: c = clamp(−(x̄ − x_ref), ±20 µs), with x̄ the median of
   the last 8 new-frame ticks.
   - The drift is about 0.16 µs per tick at 23.976 for 11.7 ppm. ±20 µs covers rates up to about 1,400 ppm and never moves a tick
     visibly.
   - So the tick-to-due phase stays where Play put it, and no tick ever crosses a due time from drift.
4. **Inactive** while paused, stepping, seeking, shuttling, at a rate mismatch (the same `matched` test as `:5730`), with no pacer
   (output off), and for a live source. There the pacer is exactly today's.

**Code touched.**
- `App/OutputPacer.swift`: the deadline (`:116-137`) takes a signed correction; a pure `nextDeadline(previous:step:correction:)`
  and `phaseCorrection(...)` go in `Packages/ManifoldCore/Sources/OutputPacing/OutputPacing.swift`, unit-tested.
- `App/MetalVideoRenderer.swift`: one measurement after selection, handed to the pacer.
- **Untouched:**
  - the card-lock clock (1a/1b: `FrameEngine.swift:1342-1376`);
  - SDI audio scheduling (1c: `DeckLinkBridge.mm`);
  - Stage 2 Mac audio;
  - slip writes and the re-anchor;
  - the pacing-renderer watchdog;
  - the decode pumps;
  - the pull selection (`:5677-5762`) and its margin. The median tick interval moves by ≤ 20 µs, so the margin does not move.

**Latency.** None in the mean.
- The card's choice rule is unchanged, so the lead keeps today's distribution: uniform per Play, at most 0.5 ms shorter through the
  guard.
- The window's tick phase within its frame is today's random draw, then held.
- SDI A/V: unchanged by construction (I2, the pull is untouched). No re-measure needed. A loop check is cheap and is in the plan.
- At Computer: the window's picture against the Mac sound keeps today's per-Play spread (I1).

**What it removes.**
- The only late-swap cause seen in 0.9.3 and 0.9.4: 25 crossings, 3 holds.
- The window's cadence dither at a crossing.

**What it does not remove.**
- The 14 % exposure. A one-tick-late swap from any other cause would still hold. None was seen in about 10 video-block hours (§5.2).
- A2 can be stacked later, behind its own switch, if one appears.

**Risks against §6.**
- I11, the pacer contract:
  - A signed correction on an unsigned mach deadline could underflow and stop the ticks. That stalls the window and SDI together:
    `[IDLE] ⚠️ WATCHDOG: no tick in 500 ms after a wake`, a frozen `[CADENCE]` pts, `[PACER] … missed`.
  - Mitigation: the clamp, signed arithmetic in the pure function, and unit tests at the boundaries.
- A sign error in the correction would push ticks *onto* due times and make crossings on every frame. It would show as
  `[LATE-SWAP] crossing` lines in on-blocks, window `late` 0 but swap-interval errors, and holds in exposed Plays: the 9aaff2d-like
  repeat pattern, read from `[CADENCE]`.
- The guard's ≤ 0.5 ms later move at Play could turn a lead of under 0.5 ms into a hold right after Play: a `[CADENCE]` repeat
  within 1 s of Play together with a `[PACER-PHASE] guard` line. Such Plays already dither today, so this moves an existing
  hold rather than adding one. UNKNOWN (inference).
- Freeze and renderer-recovery rate: no known path from the pacer's tick timing to the pacing renderer, which the decode pump
  feeds. Watch `[RENDERER-RECOVER]` and `[RENDERER-NEARMISS]` against switch-off.

**Rate cases.**
- 59.94 (k 2, P 8.34): x held in [0.5, 7.84] ms.
- 23.976 (k 3, P 13.90) and 25p (k 3, P 13.33): the same with their P.
- C6: inactive, today's behavior.

**Switch:** `MANIFOLD_PACER_PHASE=1` (env, read once into a `static let`, inside `#if DEBUG`, as `cadenceLog` is at `:509`).
Default off. Off means the correction is never computed and the loop's `deadline += step` runs as at `537726a`.

**Proving switch-off identical to 537726a:**
- **(a) Code.** The off path adds one Bool read per tick; a unit test asserts `nextDeadline(previous, step, 0) == previous + step`
  and that `phaseCorrection` returns 0 when disabled.
- **(b) Logs.** Off-blocks against the HEAD baseline blocks must match:
  - `[PACER]` interval median, p99 and max within 0.01 ms;
  - the swap − due slope per segment, −(card ppm) ± 2 µs/s;
  - the crossing rate (Poisson-consistent);
  - the lead distribution (two-sample KS, p > 0.01);
  - every gate count.
  - Plus 0 `[PACER-PHASE]` lines with the switch off.
- **Byte-identity of a timing-driven run cannot be shown by replay:** two runs of HEAD differ. So (b) is a statistical identity, and
  (a) is the code-level proof.

### D. Decouple the output render from the window (SDI_OUTPUT_TIMING.md §3)

§3 above. It removes the dependence on the swap entirely. It touches render, queue consumption, scopes, priming and seek renders,
and costs a second render per frame. It is a 1.1 roadmap item, not a fix for this entry.

---

## 8. Recommendation

**C, behind `MANIFOLD_PACER_PHASE`, default off, after the logging-only measurement build (§9.1) has confirmed the crossing
classification prospectively.**

- C is the only option whose mechanism is tied to the measured cause (§5).
- It touches the fewest of the protected paths: none of card lock, 1c, Stage 2, slips, the watchdog or the decode pump, and not the
  pull.
- It needs no A/V re-measurement, and it cannot trade repeats for skips, because the pull's choice rule is untouched.

**Resolved since the audit:** the commit. The half-frame band (`MetalVideoRenderer.swift:5725-5731`, `:5750-5751`) is from
`537a3516` (2026-11-14, the 0.9.3 candidate); the surrounding due-frame selection (`:5732-5749`) is unchanged from `9aaff2d`.
CONFIRMED by git blame (Robbie, 2026-11-16).

**What blocks the decision, UNKNOWN:**
- Whether any non-crossing late swap occurs. None in about 10 video-block hours, but the logs cannot see an earlier-tick decode
  state (§4). The measurement build answers it.
- Whether the guard's ≤ 0.5 ms move at Play ever lands on a lead under 0.5 ms in practice.
- The hold rate at C6, where C is inactive.
- The direction and size of the card-against-host drift on other Macs and on a genlocked card. C does not depend on either.

If the measurement build shows other causes, A2 is the next candidate. It shifts the window's A/V at Computer and needs Robbie's
decision on that. If neither is wanted, leaving it as is costs about 0.3 holds per video hour on this rig, each recovered with sound
following: 3 holds in about 10 video-block hours.

---

## 9. Specifications (not built)

### 9.1 Measurement build (logging only, DEBUG, `MANIFOLD_DECKLINK_CADENCE_LOG=2`; `=1` keeps today's lines unchanged)

**At each Play**, at the first timed pull after a resume to 1×: `[PULLPHASE] play`, with:
- P, k, F, matched;
- the margin and the band;
- x0 (median tick − due over the first 8 new-frame ticks);
- the establishing branch: due, or next-by-band;
- u = handed pts − target;
- lead0;
- newest − handed in frames;
- the last `[CARDLOCK]` card ppm.

**At each pull:** `[PULLPHASE] pull`, with:
- idx, host, clock, target, handed pts;
- the branch: paused, untimed, due, would-repeat taken, would-skip, held, earliest;
- for the frame after the one handed last:
  - in the frame queue? (and since when, as an enqueue host stamp);
  - converted? (and its publish host, stored per ring slot in DEBUG);
  - its tick's clock minus its pts;
- lead from the handed frame's own swap;
- whether the handed frame is the window's newest.

**At each new-frame tick:** `[TICKPHASE]` with x = selectNow − chosenPts, prevNow − chosenPts, the pacer interval, the tick duration
(`watchTickBegan`/`Ended`), tick → ring when its convert publishes, and the frame's enqueue host.

**At each late swap** (more than P/2 above its segment's running cluster): `[LATE-SWAP]`, with one class:
- `crossing`: the previous tick was before due by less than 0.2 ms;
- `decode`: the frame was due at the previous tick but not queued;
- `render`: tick → ring above P − x;
- `pacer`: the interval before the tick above 1.5 P;
- `main`: a main heartbeat lag above P at that tick, from a 4 ms main-queue timer;
- `other`.

Then whether the card held on it.

**At each Pause:** `[PULLPHASE] summary` with the x slope (µs/s), crossings, late swaps by class, exposed pulls (handed is newest
and lead < P), and holds.

### 9.2 Forced-late-swap switch

`MANIFOLD_DECKLINK_LATE_SWAP_AT="120,247:2,374:ms6"`. DEBUG only, parsed like `MANIFOLD_DECKLINK_SLIP_AT` (`:510-520`). Each entry is
content seconds, then an optional mode:
- **`n` (default 1) ticks:** the first new frame with pts ≥ at, while playing at 1× with output on, is withheld from selection for n
  pacer ticks: `selectNow` is clamped below its pts. It renders, presents and converts n ticks late, as a crossing does. The window
  shows the previous frame that much longer, and the window's `late` counts it, which tells it apart from a natural crossing.
- **`msN`:** that frame's ring publish is delayed by N ms on the DeckLink completion queue. This models a slow convert; the window is
  unaffected.

Each entry fires once and logs `[LATE-SWAP-TEST] pts … held n tick(s) at clock …` or `… publish delayed N ms`. For a soak, spread
the entries at a spacing that is not a multiple of a frame or of the transport cycle (e.g. every 7.3 s).

### 9.3 Test plan

**Predictions, written now (2026-11-16), before any run.** Rig, fixtures and rules as in the 0.9.4 gate (`Manifold-BUILD.md:171-183`):
- capture closed, Scarlett the default output;
- Resolve closed, 10 min HID idle;
- guard before and after; launched by absolute path; quit by PID.

**Stage 0: baseline, unmodified HEAD `537726a`.** The 0.9.4 soak as is: seven 60-min blocks by `soak.sh`. Predictions:
- 0 freezes, 0 unrecovered, 0 skips; renderer recoveries 0.
- Holds 0–3, each with the crossing signature: swap − due falling about 11 µs/s to the tick → ring time, then P + 0.9 ms.
- Crossing segments 0–6 per video block, about 12 in all.
- Exposed segments 10–20 % by §2.4's method; `swapAgo` < P in 30–50 %.

**Stage 1: measurement build** (§9.1, plus §9.2 available, no behavior switch).

| Block | Duration | Predictions |
|---|---|---|
| 23.976 Computer | 60 min | Every natural `[LATE-SWAP]` is class `crossing`; 0 in `decode`, `render`, `pacer` or `main`. `[PACER]` intervals and window late/dropped not above Stage 0's same block (the logging does not perturb) |
| 25p SDI | 60 min | Same as above |
| 23.976 Computer with `LATE_SWAP_AT` every 7.3 s | 30 min, ~245 events | **Ticks mode, n = 1:** a hold exactly when, at the forced frame, the handed frame was the window's newest and lead < P. 0 holds otherwise. Each hold: one repeat, a new picture line, the Mac sound re-anchored once. 0 skips |
| 59.94 SDI with `LATE_SWAP_AT` every 7.3 s | 30 min, ~245 events | Same as above, plus at SDI an SDI-AUDIO run end and a re-latch at each hold |
| 59.94 SDI, `ms6` entries | 15 min | A hold exactly when lead < 6 ms |

**Pass:** the predictions above.

**Stage 2: A/B on the C build, overnight.**
- Eight 60-min blocks alternating off and on: 23.976 Computer, 25p SDI, 59.94 SDI, 23.976 Computer, the second four in on/off order.
- Then three 30-min identity blocks with the switch on, where C must be inactive: the WAV to SDI, a C6 block (25p file on
  1080p59.94), and output off.
- Predictions:
  - Off-blocks: crossings ≥ 5 in all (from 25 in 1,050 segments).
  - **On-blocks: 0 crossings, 0 holds.**
  - |x − x_ref| ≤ 0.1 ms at p99.
  - Lead distribution: on and off indistinguishable (KS p > 0.01).
  - `[PACER]` median P ± 0.01 ms, p99 ≤ P + 0.05 ms.
  - Identity blocks: 0 corrections applied, and gate counts as their Stage 0 or 0.9.4 equivalents.
  - Forced test repeated on one on-block: holds as Stage 1. C does not change exposure.

**Pass:**
- The full 0.9.4 gate on every block. For on-blocks the "late window frame repeated once" exception is removed: 0 holds.
- Renderer recoveries and near-misses not above switch-off. 0 freezes.
- On-blocks 0 crossings, against off-blocks ≥ 5. With fewer than 5 off-block crossings the night is inconclusive and is repeated,
  not passed: with λ ≈ 8 the chance of 0 on-block crossings by luck is 0.03 %.

**After a pass:** the switch becomes the default only on Robbie's decision.

---

## 10. Corrections for BUGS.md (for Robbie or a session in this repo)

- **"Display refresh"** in the margin table is the output pacer's period. With output on, the window is not ticked by a display.
- **"119 of 315 Plays (38 %) had less than one refresh of margin"** counts `swapAgo` from the newest swap. Measured from the handed
  frame's own swap, 76 of 525 steady-play segments (14 %) were exposed (§2.4).
- **"Why a swap is occasionally one refresh late: UNKNOWN"** is now answered for all three holds: the host-clock pacer tick drifts
  across a frame's due time on the card-locked clock (§5). It is not random.
- **"The lead is fixed within a Play and set afresh at each one"** holds. The reasons: the pacer's phase restarts at each wake,
  the clock starts at Play with no slot reference, and the half-frame band lets the swap set the card's phase (§1, §2).

---

## 11. Measurement build (built 2026-11-16; Stage 1 night 1 in §12)

**Commit `3f05914`** (the measurement build's code; its docs are `d105e81`). **Candidate binary:** `.build-pullphase`, a plain Profile
build, unsigned, written 2026-11-16 12:19:11, sha256 `fcb2a2edaa4c6a0d901db4cee874261f5a609c866695fac7782997d1ac31fd8f`.
CONFIRMED: no file under `App/`, `Packages/ManifoldCore/Sources/` or `project.yml` is newer than that binary.

Logging and one DEBUG test switch, as §9.1 and §9.2 specify, with the deviations listed below. No behavior change with the switches
unset. Line numbers in this section are the working tree after this build, not HEAD `537726a`.

### 11.1 Step 1: is the 0.9.4 soak a valid Stage 0 baseline?

**Verdict: the 0.9.4 soak logs are a valid Stage 0 baseline.**

The 0.9.4 gate soaked a Profile build of `7b99b09` (`Manifold-BUILD.md:175`), `.build-rc094`, binary written 2026-11-15 21:36:16.
The commits from there to HEAD are `e8c4696`, `fbb67a8`, `5b1c59a` and `537726a`. That list is from the session's git status
snapshot; no git command was run.

Files modified after that binary, from file times (`find -newer`):

| File | On the playback/output runtime path? | What changed |
|---|---|---|
| `project.yml` | No | The version: the soaked binary's Info.plist reads 0.9.3 (26), `project.yml:458-459` now reads 0.9.4 (27). CONFIRMED. The rest of its diff: UNKNOWN without git (inference: none, from the commit messages) |
| `Manifold.xcodeproj/*` | No | Generated by xcodegen and gitignored (`.gitignore:61`, `:64`), so in no commit |
| `App/DisplayTransformControl.swift` | No: the Display Transform panel's caption | "Tick only if the monitor itself applies BT.1886…" (soaked binary, `strings`) → "Check only if …" (`:434`). CONFIRMED |
| `scripts/check-us-spelling.py` | No: the release preflight | Now scans the release notes (`:8`, `:202-204`) |
| `RELEASE_NOTES.md`, `docs/release-notes/*`, `docs/BUGS.md`, `docs/Manifold-BUILD.md`, `docs/CARD_PULL_MARGIN.md` | No | Docs |

### 11.2 What was built

| File | What |
|---|---|
| `Packages/ManifoldCore/Sources/OutputPacing/CardPullMeasurement.swift` (new) | The pure pieces, unit-tested: `LateSwapSchedule.parse`; `PullOutcome.branch`; `LateSwapBaseline` (the running cluster); `LateSwapClassifier`; `SlopeFit` |
| `Packages/ManifoldCore/Tests/OutputPacingTests/CardPullMeasurementTests.swift` (new) | 21 tests |
| `App/CardPullPhaseLog.swift` (new, whole file `#if DEBUG`) | The record buffer, the drain that joins and formats, and the main heartbeat |
| `App/MetalVideoRenderer.swift` | The gated hooks listed in §11.5, plus the §9.2 switch (`lateSwapLimitLocked` `:5781`, `lateSwapPublishDelay` `:5811`) |
| `App/DeckLink/DeckLinkService.swift` | `cadenceLog` (`:1784`) is true for `=1` and `=2` |
| `scripts/decklink-loopback/rc-soak.py` | An optional trailing `env NAME=VALUE …` on `block`, allowed only for `MANIFOLD_DECKLINK_CADENCE_LOG` (1 or 2) and `MANIFOLD_DECKLINK_LATE_SWAP_AT`. Without it, the launch environment and every other behavior are as before |

### 11.3 Switches

Both are read once, at the renderer's init (`MetalVideoRenderer.swift:1229-1234`).

**`MANIFOLD_DECKLINK_CADENCE_LOG`**
- Unset and `=1`: as before.
- `=2`: today's `[CADENCE]`, `[CADENCE-SWAP]` and bridge completion lines, plus the lines in §11.4. `CardPullPhaseLog.enabled` (`App/CardPullPhaseLog.swift:25`).

**`MANIFOLD_DECKLINK_LATE_SWAP_AT="120,247:2,374:ms6"`** (DEBUG). Comma-separated `seconds[:mode]`. An item that does not parse is
dropped, as `MANIFOLD_DECKLINK_SLIP_AT` drops its own.
- Ticks mode `n` (1–16, default 1): the first new frame at or past `seconds`, while the output pacer ticks and the clock runs at 1×,
  is withheld from the window's selection for `n` pacer ticks. Its render, present and convert all come `n` ticks late.
- `msN` (0 < N ≤ 1000): the first frame at or past `seconds`, not paused, reaches the DeckLink ring N ms late. The convert's
  completion sleeps before publishing, so the window is unaffected.
- Each entry fires once. Entries already passed when one fires (a seek, a loop wrap, a Play from further on) fire with it, and the
  line names the latest.
- Each firing logs `[LATE-SWAP-TEST] pts … held n tick(s) at clock … · entry … s` or `[LATE-SWAP-TEST] pts … publish delayed N ms · entry … s`.
  The line is formatted on a utility queue.

### 11.4 The lines (`=2`)

All are formatted on the drain queue (`com.graviton.manifold.pullphase`, utility QoS, every 100 ms). Times are host seconds; values
"rel" are milliseconds relative to the line's own host time.

**`[PULLPHASE] pull`**, one per card pull:
- `#idx host clock timed|untimed target band margin handed branch`;
- `next <pts> (ring|nominal)`: the frame after the one handed last, from the ring if converted, else the handed pts plus one source frame;
- `queued` (enqueue host rel, or `no`) and `converted` (publish host rel, or `no`) for that next frame;
- `tick-x`: the tick − due of the tick that rendered it;
- `lead`: pull host − publish host of the handed frame;
- `newest` or `behind n`: the handed frame against the newest converted frame.

**`[PULLPHASE] play`**, once per Play, after its 8th new-frame tick and its first new handed frame:
- `P k F matched margin band`;
- `x0`: the median tick − due of the first 8 new-frame ticks;
- `establish <branch>`, `u` (handed − target), `lead0` and `behind` at the first new frame handed;
- `previous-play content-clock-vs-host` ppm.

**`[PULLPHASE] summary`**, at the first untimed pull after a Play (a Pause, seek, step, wrap or shuttle):
- `duration pulls timed holds exposed (%)`;
- `x-slope` (µs/s, with x unwrapped across a crossing);
- `late-swaps` by class, and `crossings` (runs of crossing-class late swaps);
- `content-clock-vs-host ppm`;
- `dropped-records`.

**`[TICKPHASE]`**, one per pacer tick that chose a new frame, written when that frame publishes, or after 0.5 s with `ring none`:
- `pts host x prev-to-due interval prev-tick ring queued main-ago`;
- `prev-to-due` is the tick before's clock minus pts. Negative means the frame was not yet due then.

**`[LATE-SWAP]`**, a swap more than half a tick above the 10th percentile of the previous 48 in its Play (`LateSwapBaseline`):
- `pts class s baseline x prev-to-due queued-before-prev-tick ring interval main-ago held`;
- `held yes` when a timed repeat pull fell between the tick before and this publish;
- class by `LateSwapClassifier`, first match wins:
  - `pacer`: the interval before the tick was over 1.5 P;
  - `decode`: due at the tick before but not queued by then;
  - `crossing`: the tick before was short of due by ≤ 0.2 ms;
  - `render`: tick − due under P, with ring past the next tick boundary;
  - `main`: main-ago over P;
  - `other`.

**Deviations from §9.1, and why:**
- **The pull's branch is reconstructed from its outcome** (`PullOutcome.branch`: the handed frame, the frame handed before, the
  target, the ring). It is not recorded inside `deckLinkPullSlotLocked`, because instrumenting the branches would change the
  protected function.
- **The target** is read back as `deckLinkPullDueNow − 0.002`, the pull's own `due = target + hysteresis` (`:5723` at HEAD).
- **The card ppm** in the play line is replaced by the content clock against the host, fitted from the pulls of the previous Play.
  Under card lock that is the card's rate. Reading `[CARDLOCK]` from the engine would have meant touching `FrameEngine`; that line
  stays in the log for joining.
- **Tick duration** is the tick before's (`watchTickEnded − watchTickBegan`), captured at the start of the next tick.
- **Main stall** is "time since the 4 ms main heartbeat last ran", read at the tick.

**Hot path, which method.** Preallocated buffer, formatted off-thread. Each hook copies numbers into a fixed-size `Record` and
appends it to a buffer of 16,384, reserved at creation, under one `NSLock` (`CardPullPhaseLog.append`). No allocation while there is
room; a full buffer counts drops rather than growing. Nothing is formatted on the pacer thread, the SDK fill callback, the convert
completion or the frame intake. The two `[LATE-SWAP-TEST]` lines are formatted on a global utility queue.

Today's `[CADENCE]` lines still format inline in the fill callback (`DeckLinkService.swift:1192-1198`), unchanged, so that `=2`
keeps what `rc-soak.py` and `rc-soak-report.py` read.

### 11.5 Step 4: proof of no change with the switches unset

**Tests: `swift test` passes.** HEAD 1,072 XCTest tests in 36 bundles, 0 failures; this build 1,093 (the 21 new), 0 failures,
0 warnings either way.

**Profile build warnings: HEAD 63 warning lines (62 unique), this build 63 (62 unique).** The normalized sets are identical; the only
difference is the timestamp on the AppIntents metadata line.

**Release:**
- This build's Swift files compile in Release with no warning naming a new symbol.
- In Release the binary is not linked: **`App/DeckLink/DeckLinkBridge.mm` fails to compile.** It uses `os_unfair_lock` at `:2132`,
  but `<os/lock.h>` is included only under `#if DEBUG` (`:20-22`); the five further errors follow on (`:479`, `:614`, `:721-727`).
- That file is untouched here (last modified 2026-11-15 13:26), and its compile depends only on its own includes (`DeckLinkBridge.h`,
  the SDK header, system headers), none of which this build changed. So this failure does not depend on this build. CONFIRMED.
- That HEAD fails the same way follows from that (by construction); no Release build of HEAD was run. It is a protected path, so it is
  not fixed here. It matters before any Release build (`PRIVACY_AUDIT.md` item 8).

**Protected paths: unmodified files.** CONFIRMED by file times, all before this session:
- `FrameEngine.swift` (card lock, Stage 2, slips, re-anchor, the renderer watchdog): 2026-11-15 18:00;
- `DeckLinkBridge.mm` (1c): 2026-11-15 13:26;
- `OutputPacer.swift` (deadline arithmetic): 2026-11-04;
- `FileFrameSource.swift`: 2026-11-08;
- `LibavFrameSource.swift`: 2026-11-08.

**The pull selection.**
- `deckLinkPullSlotLocked`, `deckLinkPullMarginLocked` and `noteDeckLinkTick` are unedited.
- The only new instruction on the pull path with the switch unset is one Bool test after the handed frame is recorded
  (`MetalVideoRenderer.swift:5745`).

**Every new branch tests a static let read once:**

| Site (`MetalVideoRenderer.swift`) | Test when unset |
|---|---|
| Init `:1232-1233` | `CardPullPhaseLog.enabled`; `lateSwapArmed` read (parses an empty string once) |
| Frame intake `:3219` | `CardPullPhaseLog.enabled` |
| `displayTick` `:3446` | `CardPullPhaseLog.enabled` |
| `performDisplayTick` `:3698`, `:3710`, `:3844` | `enabled ‖ lateSwapArmed`; `lateSwapArmed`; `enabled`. The selection compares against `selectLimit` (`:3728`), which is `selectNow` unless `lateSwapLimitLocked` ran (`:3689-3691`, `:3711`), so the frame chosen is the same |
| Convert completions `:5481`/`:5620` (before the lock), `:5502`/`:5636` (inside, beside the existing DEBUG swap stamp), `:5522`/`:5652` (after the unlock) | `lateSwapArmed`; `enabled`; `enabled`. Publish order and content unchanged |
| Pull `:5745` | `enabled` |

**Nothing is created when unset.** `CardPullPhaseLog.shared`, and with it the drain timer and the 4 ms main heartbeat, is created
only inside `if CardPullPhaseLog.enabled` (`:1232`). Every other use of `.shared` is inside the same test (`:3222`, `:3848-3849`,
`:5525`, `:5655`, `:5774` via `:5745`).

**Log text at unset and `=1` is byte-identical.** `cadenceLog` (`:510`; `DeckLinkService.swift:1784`) is false for unset and true
for `=1`, as before. Every new line is printed only from `CardPullPhaseLog` (`enabled`) or from the two `[LATE-SWAP-TEST]` sites
(`lateSwapArmed`). The bridge's `getenv` test (`DeckLinkBridge.mm:969`) is unchanged.

**Release:** `CardPullPhaseLog` exists only under `#if DEBUG`, and every reference to it is inside `#if DEBUG`.
`OutputPacing/CardPullMeasurement.swift` has no log text.

This is a code-level argument. A behavioral comparison needs a run; §11.6's timing check is that comparison for `=2`.

### 11.6 Stage 1 soak plan (written, not run; waits for Robbie's go)

**Folder:** `~/Code/_scratch/manifold-cardpull-s1/`: `common.sh`, `soak.sh`, `timing-check.py`.

**Candidate:** commit `3f05914`; `.build-pullphase`, a plain Profile build, unsigned, binary written 2026-11-16 12:19:11, sha256
`fcb2a2edaa4c6a0d901db4cee874261f5a609c866695fac7782997d1ac31fd8f`. Built with:

```
xcodegen generate
xcodebuild -project Manifold.xcodeproj -scheme Manifold -configuration Profile -derivedDataPath ./.build-pullphase \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

**Rig:** as for the 0.9.4 gate: capture closed, the Scarlett the default output, Resolve closed, 10 min HID idle before each block,
same fixtures. Process checks read `ps -axo comm=` with exact matches; no `pgrep -f`.

**Each block:**
1. `manifold-proc.sh guard` before and after (`guardp`), and again inside `rc-soak.py`. A tripped guard stops the night.
2. Launched by absolute path (`$APP`), held by PID, quit by PID through `manifold-proc.sh quit`.

**Start:** `~/Code/_scratch/manifold-cardpull-s1/soak.sh main`. Its preflight (`need`) stops the night unless `$APP`'s sha256 is the
`3f05914` candidate's. **Stop:** `touch …/STOP`.

| # | Label | Invocation (`blk` → `rc-soak.py block $APP <fixture> 1920 <mode> <dest> <label> <minutes> …`) | Env added by `rc-soak.py` |
|---|---|---|---|
| 1 | `pp-2398-cmp` | `w1c-2398-1920s.mov 1080p23.98 computer 60 markers 5` | `MANIFOLD_DECKLINK_CADENCE_LOG=2` (replaces `=1`) |
| 2 | `pp-gop25-sdi` | `gop25-h264-1920s.mp4 1080p25 sdi 60 markers 5` | `MANIFOLD_DECKLINK_CADENCE_LOG=2` |
| 3 | `pp-2398-cmp-lst` | `w1c-2398-1920s.mov 1080p23.98 computer 30` | `=2`, `MANIFOLD_DECKLINK_LATE_SWAP_AT=$LST` (7.3, 14.6, … 1905.3: 262 entries, one tick each) |
| 4 | `pp-5994-sdi-lst` | `w1c-5994-1920s.mov 1080p59.94 sdi 30` | `=2`, `LATE_SWAP_AT=$LST` |
| 5 | `pp-5994-sdi-ms6` | `w1c-5994-1920s.mov 1080p59.94 sdi 15` | `=2`, `LATE_SWAP_AT=$MS6` (the same times, `:ms6`) |

`rc-soak.py` still sets `MANIFOLD_DEBUG_TRANSPORT` and `MANIFOLD_PLAYBACK_STATS=1`, and strips every other `MANIFOLD_*`.

**Afterwards, `soak.sh` runs:**
- `rc-soak-report.py` (the gate counts);
- **the timing check** (`timing-check.py`), which compares each block with the 0.9.4 blocks of the same file and destination.

**The timing check's criteria** (fixed now). If any block fails, the night's results do not count:
- `[PACER]` run interval median within ±0.01 ms of each 0.9.4 reference;
- p99 no more than the reference's + 0.02 ms;
- max no more than the reference's + 0.5 ms;
- missed deadlines no more than the reference's;
- window late + dropped per hour no more than 2 × the reference's. Blocks 1–2 only: the forced blocks add window `late` by design.

**The 0.9.4 references, by the same reading:**

| 0.9.4 block | Pacer run median / p99 / max (ms) | Missed deadlines | Window late / dropped |
|---|---|---|---|
| `rc-2398-cmp-1` | 13.91 / 13.92 / 14.01 | 0 | 13 / 3 |
| `rc-2398-cmp-2` | 13.91 / 13.92 / 13.97 | 0 | 9 / 3 |
| `rc-gop25-sdi-1` | 13.34 / 13.35 / 13.42 | 0 | 25 / 22 |
| `rc-5994-sdi-1` | 8.35 / 8.36 / 8.46 | 0 | 11 / 12 |
| `rc-5994-sdi-2` | 8.35 / 8.36 / 16.68 | **2** | 10 / 11 |

The 2 missed deadlines in `rc-5994-sdi-2` correct nothing in §5: the three hold blocks had 0.

**Predictions** (§9.3 Stage 1, restated against these lines; written 2026-11-16, before any run):

| # | Prediction |
|---|---|
| P1 | Blocks 1–2: every `[LATE-SWAP]` has class `crossing`; 0 `decode`, `render`, `pacer` or `main` |
| P2 | Blocks 1–2: crossings 0–6 per block. Each crossing Play's summary shows `x-slope` within ±3 µs/s of −(its content-clock ppm) |
| P3 | Blocks 1–2: holds 0–2. Each hold falls on a crossing Play whose `[PULLPHASE] pull` lines read `newest` with `lead` under P just before it, and its `[LATE-SWAP]` reads `held yes` |
| P4 | Blocks 3–4 (ticks): a hold within 2 pulls of a `[LATE-SWAP-TEST]` exactly when the pull before it read `newest` with `lead` < P. 0 holds otherwise. Each hold: one repeat, a new picture line, the Mac sound re-anchored once (block 3, Computer) or an SDI run end and re-latch (block 4). 0 skips. Window `late` +1 per firing |
| P5 | Block 5 (ms6): a hold exactly when `lead` < 6 ms at the delayed frame. 0 skips |
| P6 | All blocks: 0 freezes, 0 renderer recoveries, `dropped-records 0` in every summary; the timing check passes |
| P7 | `[TICKPHASE] queued` negative (in the queue before its tick) for every frame of steady play |

**Unknown going in:**
- The log volume at `=2`: roughly 3× today's lines per pull, plus one `[TICKPHASE]` per frame. Inference: ~100 MB per hour at 59.94.
- Whether that much stdout write perturbs anything. The timing check decides it.

---

## 12. Stage 1, night 1 (failed timing check)

Run 2026-11-16, 19:35–23:10, by `~/Code/_scratch/manifold-cardpull-s1/soak.sh main`, candidate `3f05914` (sha256 checked by `need`).
All five blocks ran to the end; guard clean before and after each and after the night. **The timing check failed on all five blocks**
(`timing.report`), so by §11.6's rule the night's results do not count. This section is a read-only analysis of why, and of which
findings stand regardless. Nothing was built, launched or written except this section. Host times are converted to wall clock from
`mach` seconds; checked against `NSLog` timestamps in the same logs to within 0.06–0.3 s (the drain's lag).

**The failures, as `timing-check.py` printed them:**

| Block | Pacer median / p99 / max (ms) | Missed | Failed on |
|---|---|---|---|
| `pp-2398-cmp` | 13.91 / 13.92 / 27.81 | 3 | max > 14.01 + 0.5; missed > 0 |
| `pp-gop25-sdi` | 13.34 / 13.35 / 26.68 | 6 | max > 13.42 + 0.5; missed > 0 |
| `pp-2398-cmp-lst` | 13.91 / 13.92 / 27.81 | 3 | max; missed > 0 |
| `pp-5994-sdi-lst` | 8.35 / 8.36 / 16.69 | 47 | missed > 2 |
| `pp-5994-sdi-ms6` | 8.35 / 8.36 / 16.70 | 26 | missed > 2 |

Every failing max is one missed deadline (≈ 2 P). Median and p99 passed everywhere; window late+dropped passed on blocks 1–2.

### 12.1 The rig was not the 0.9.4 rig

**Slot layout. The keys** (domain `com.graviton.manifold`): `manifold.scope.slot0`, `.slot1`, `.slot2` (`App/WindowChrome.swift:99-101`),
read at window creation with fallbacks `waveform`, `parade`, `cie` (`:238-240`); also `showTray`, `manifold.scope.trayHeight`
(`:98`, `:103`) and `manifold.markers.slotThumbnails` (`App/Markers/MarkersScopeView.swift:28`, default on). Written only when a slot is
picked (`WindowChrome.swift:152-154`); `rc-soak.py` writes no defaults (`scripts/decklink-loopback/rc-soak.py:11`, `:16`).

**Read with `defaults read` at 23:35 (nothing written):** `slot0 = yrgb`, `slot1 = meters`, `slot2 = meters`, `showTray = 1`,
`trayHeight = 440.3203125`, `controlDisplayMode = overlay`; `manifold.markers.slotThumbnails` absent (so on). Plist last modified 22:52:52,
during the ms6 block's launch.

- **The soak binary has no YRGB scope.** CONFIRMED: `nm` finds 0 YRGB symbols in `.build-pullphase` (219 `WaveformScope`, 37
  `MarkersScopeView`); `App/YRGBScope.swift` was written 17:40, the binary 12:19. A stored `yrgb` falls back to slot 0's default,
  `waveform` (`WindowChrome.swift:238`; `App/ContentView.swift:20-21` documents the fallback).
- **So Stage 1 ran Waveform | Audio Meters | Audio Meters, with no Markers slot.** CONFIRMED for the values as read; that they were
  the same at 19:45 is UNKNOWN (inference: yes — the last session that picked slots is `~/Code/_scratch/manifold-scopes095/yrgb-perf2.log`,
  last written 18:37, whose `[SCOPE-PERF]` lines open with Parade, Waveform and YRGB and later show `AudioMeterScopeView`; nothing in the
  soak writes them).
- **The hypothesis's layout, Waveform | Parade | YRGB, was the start of that 18:37 session, not the stored end state.**
- **Markers slot NOT FOUND: explained.** CONFIRMED: no slot held `markers`, so `rc-soak-ax gear` found no gear (`rc-soak.py:129-131`),
  and all 12 Regenerates were `no-gear`. Stage 1 therefore did *less* thumbnail work than 0.9.4, not more.
- **0.9.4's layout: one slot was Markers** (CONFIRMED: "Markers slot open" in every 0.9.4 video block, 0.9.4 `soak.out`). **The other two
  are UNKNOWN.** No log line names slot kinds, `[SCOPE-PERF]` was off on both nights (`App/ScopePerf.swift:19` needs
  `MANIFOLD_SCOPE_PERF=1`), and no stash of the keys exists under `~/Code/_scratch` or `docs/`.

**Signing and licence: a second rig difference, not in the hypothesis.** CONFIRMED:
- The 0.9.4 candidate (`.build-rc094`) is Developer ID signed (TeamIdentifier `8UQ7MDM87B`); the Stage 1 candidate is ad-hoc, built with
  `CODE_SIGNING_ALLOWED=NO` (§11.6).
- Every Stage 1 launch: the licence keychain read took 7.2 s and returned −128, `[LICENSE] state: KEYCHAIN UNREADABLE`, twice per launch
  (the second 20 s into the first Play, in every block; no missed deadline within 40 s of it). `rc-soak.py` denies that prompt (`:53-57`) at launch and every
  30 s while SecurityAgent runs (`:196`). Use is still permitted (`App/LicenseManager.swift:530`). 0.9.4: `LICENSED (Standard)` in 0.46 s.
- Whether SecurityAgent stayed alive during the blocks: UNKNOWN (not running at 23:36).

**Display: the same on both nights, not a rig difference.** CONFIRMED from the `[LINK]` lines, 3 per log, in all 10 0.9.4 logs
(7 blocks, 3 setups) and all 5 Stage 1 logs:
- The window opens on display 5 `"LG TV SSCR2" (120.000 Hz)` (`window shown`; e.g. `rc-5994-sdi-1.log:10`, `:22`);
- ~10 s later `rc-soak.py` moves it to display 3 `"ASUS PA147" (59.936 Hz)` (`window moved`; `rc-5994-sdi-1.log:70`). That is
  before output starts (`[PACER] started`, `:79`), and no later `[LINK]` line follows in any block.
- The move is `sh(AXT, str(pid), "place", title, "ASUS")` (`scripts/decklink-loopback/rc-soak.py:123`; `:229` in markers-setup), in the
  driver since `94dc2de` (2026-11-14), before both nights.
- So every timed block on both nights (0.9.4 and Stage 1) ran its window on the ASUS at 59.936 Hz. The saved window position plays no part.
  Resolution: not logged (UNKNOWN from the logs).

**Time:** 19:45–23:10 against 0.9.4's 23:00–06:08.

### 12.2 Where the missed deadlines are, and what they coincide with

A missed deadline is a pacer tick whose `tick()` ran past the next deadline (`App/OutputPacer.swift:131-136`); the next interval is 2 P.
`[TICKPHASE]` is written for new-frame ticks only and carries that tick's interval and the previous tick's duration (§11.4), so a miss is
pinned exactly when the tick after the gap chose a new frame.

| | 23.976 / 25 blocks (12 misses) | 59.94 blocks (73 misses) |
|---|---|---|
| Pinned by `[TICKPHASE]` | 0 | 73 |
| The tick that overran | a new-frame tick, by elimination (an overrun repeat tick would show as a 2 P interval on the next new-frame tick; none did) | a repeat tick (no new frame) in 72 of 73 |
| Its duration | not recorded | 8.4–16.2 ms; that block's repeat ticks: median 0.007 / 0.178 ms, p99 2.49 / 2.73 ms |
| `nextDrawable` max in the miss's window | 0.03 ms | ≤ 0.34 ms |

What a repeat tick does at 59.94: serves a present the present gate deferred (`App/MetalVideoRenderer.swift:3481-3482`;
`servePacedPresent`, `:4455-4485`: `makeCommandBuffer`, `nextDrawable`, `encodeDisplayStage`, `commit`). So **in every block the tick
that overran is the tick that does the desktop present**. Only `nextDrawable` is timed, and it was fast; which call took the time is
UNKNOWN.

**The desktop present path behaved differently this night at 59.94** (`[PACER] desktop` lines, playing windows only):

| | Windows with in-flight holds | Misses in those windows | Presented/s median |
|---|---|---|---|
| `pp-5994-sdi-lst` | 154 of 186 (83 %) | 45 of 47 | 56.9 |
| `pp-5994-sdi-ms6` | 87 of 101 (86 %) | 25 of 26 | 59.4 |
| 0.9.4 `rc-5994-sdi-1` | 120 of 356 (34 %) | 0 | 59.9 |
| 0.9.4 `rc-5994-sdi-2` | 89 of 356 (25 %) | 1 of 2 | 59.9 |

In-flight holds alone do not cause misses (0.9.4 had them without). At 23.976/25 neither night had any.

**Render cost did not rise.** `[RENDER-PERF]` p99, Stage 1 against 0.9.4, same file and destination: draw 0.03–0.04 against 0.03–0.04 ms;
render GPU 0.18–0.24 against 0.18–0.23 ms at 24/25, and 0.46 / 0.39 against 0.67 / 0.68 ms at 59.94 (lower).

**Scope compute: UNKNOWN.** Not logged on either night. Scopes encode on their own queue, from the render's completion
(`MetalVideoRenderer.swift:4218`, `:4906`), not on the pacer thread; they can reach the pacer only through GPU or compositor contention.
Stage 1's effective layout had one GPU scope (Waveform) and two Audio Meters, which draw on their own timer (`App/ContentView.swift:23-25`);
0.9.4 had 0–2 GPU scopes (UNKNOWN which).

**The measurement build itself: not excluded.** Against it: the 59.94 overruns are on repeat ticks, which record nothing; the drain holds
its lock only for a buffer swap (`App/CardPullPhaseLog.swift:98-102`). For it: `=2` writes 3.5–4.3× the 0.9.4 log volume (48–50 MB/h at
24/25, 122–134 MB/h at 59.94, against 0.9.4's 14 and 31 MB/h and §11.6's ~100 MB/h inference) in one `print` per 100 ms (`:108`), while `[RENDER-PERF]` and
`[PLAYBACK-STATS]` print from the tick thread (`MetalVideoRenderer.swift:4598`, `:1680`), and a 4 ms main-queue heartbeat runs only at
`=2`. Neither side is measured.

**Other processes: nothing logged. UNKNOWN.**

**Time of day: no pattern.** The 59.94 misses run at 1–2 a minute through both blocks (22:21–22:51, 22:54–23:07). The 12 others:
19:52, 20:11, 20:45, 20:58, 21:04, 21:07, 21:08, 21:28, 21:33, 21:50, 22:06, 22:18 — none within 5 min of 20:00. When the NAS backup
actually ran: UNKNOWN. Spotlight: the fixtures' contents date from Nov 10 and Nov 15 (mtime), not today; their ctime changes at each
launch. Whether Spotlight indexed the growing `.log` files: UNKNOWN.

**Verdict on the cause: UNKNOWN.** The overruns are on the present path, at a time the present path was slower, under a window state that
differed from 0.9.4 (tray contents, possibly tray height) and a build that differed (logging, signing). The data points at the window's
presentation, not the pull or the logging hooks, but a run is needed to separate the two (§12.6).

### 12.3 The three holds

| Block, time | `[LATE-SWAP]` | Missed deadline | Pull before |
|---|---|---|---|
| `pp-gop25-sdi` 21:44:22.43, pts 1908.36 repeated | `crossing`, `held yes`, interval 13.333 ms | none within 0.2 s | `newest`, lead 8.73 ms < P 13.33 |
| `pp-5994-sdi-lst` 22:37:44.97, pts 12.262 repeated | `pacer`, `held yes`, interval 16.684 ms | yes, pinned (the same tick) | `newest`, lead 7.68 ms < P 8.34 |
| `pp-5994-sdi-lst` 22:43:26.58, pts 7.774 repeated | `pacer`, `held yes`, interval 16.675 ms | yes, pinned (the same tick) | `newest`, lead 7.59 ms < P 8.34 |

- **One crossing, two pacer misses.** None is at a forced event.
- **All three share the precondition of §4–§5:** the handed frame was the newest and its lead under P, so a swap one tick late meant
  the card repeated. Each recovered on the next pull (`branch due`).
- **New:** a missed pacer deadline is a second source of the one-tick-late swap. §5 knew only crossings. Option C (§7) removes crossings,
  not these.

`[PULLPHASE] summary` `holds` counts every `held`-branch pull, about one per Play (the Play's opening repeat). It is not the gate's
hold count, which is `rc-soak-report.py`'s slot rule.

### 12.4 Every natural `[LATE-SWAP]`, by class

Joined to its `[TICKPHASE]` by pts and file order. "Near a miss": within ±2 ticks of a pinned miss, or in the `[RENDER-PERF]` second of an
unpinned one. "Forced": within ±1 tick of a `[LATE-SWAP-TEST]` frame (listed for completeness, not natural).

| Block | Away from misses | Near a miss | At a forced event |
|---|---|---|---|
| `pp-2398-cmp` | crossing 183 | 0 | – |
| `pp-gop25-sdi` | crossing 47 | 0 | – |
| `pp-2398-cmp-lst` | crossing 52 | 0 | main 1, other 6 |
| `pp-5994-sdi-lst` | 0 | pacer 14 | main 5, other 3 |
| `pp-5994-sdi-ms6` | crossing 210 | pacer 19 | render 9 |

**Away from misses: 492 of 492 are crossings. Near misses: 33 of 33 are `pacer`. Natural `decode`, `render`, `main`, `other`: 0.**

Crossing Plays: 4, 1, 1, 0, 3 per block. The summary's `crossings` field counts runs (18, 6, 9, 0, 50): one crossing is split into
several runs as the 48-swap baseline catches up, so it over-counts.

### 12.5 The forced swaps

33 firings, 11 per block, not §9.3's ~245. §11.3's semantics fire all entries already passed as one event, and the transport's
random seeks pass most entries at once ("236 / 193 / 113 earlier entries passed"). 6 are **catch-up** firings on a Play's first new frame
(the pull before was the paused hold, lead ≈ 2 s; the prediction does not apply). 27 are **steady**, in only two Plays per block.

| Block | Steady events | Pull before the forced frame | Prediction | Outcome | Lead at first take |
|---|---|---|---|---|---|
| `pp-2398-cmp-lst` (P 13.90) | 6 + 3 | lead 57.2–57.6 ms `behind 1`; 29.8–30.0 ms `newest` | no hold | no hold, 9/9 | 43.5–43.7; 15.8–16.1 ms |
| `pp-5994-sdi-lst` (P 8.34) | 6 + 3 | 15.6–16.1 ms `newest`; 23.3–23.5 ms `newest` | no hold | no hold, 9/9 | 7.4–7.8; 15.4–15.5 ms |
| `pp-5994-sdi-ms6` (6 ms) | 6 + 3 | 15.6–17.0 ms `newest`; 23.3–23.5 ms `newest` | no hold | no hold, 9/9 | 9.1–10.3; 15.9–16.0 ms |

- **27 of 27 steady events match the prediction, all in its "no hold" half.** Every Play that got events had lead ≥ P (≥ 6 ms for
  ms6), so the half that predicts a hold was never exercised. **P4 and P5 are untested, not passed.**
- **The forced delay consumed what it should:** about P per event in ticks mode (13.6–14.0 ms; 8.1–8.4 ms), and 6.5–7.5 ms for ms6.
- **No forced event was within ±2 ticks of a missed deadline.**
- Window `late` +1 per firing (P4): not checked here.

### 12.6 Against the predictions (§9.3, §11.6), and what survives

| # | Result | Survives the perturbation? |
|---|---|---|
| P1 | Blocks 1–2: 230 of 230 late swaps `crossing`, none near a miss | **Yes.** Each is classified on its own evidence, away from any miss |
| P2 | Crossing Plays 4 and 1 (within 0–6). Slope against **−ppm: 0 of 5. Against +ppm, the sign as logged: 5 of 5** within ±3 µs/s (9 of 9 over all blocks; 273 of 280 steady Plays). The prediction had the sign wrong; the mechanism (x drifts at the card's rate) holds | **Mechanism: yes. Counts: no** (rig-dependent) |
| P3 | 1 hold in blocks 1–2, a crossing with exactly P3's shape | **Shape: yes. Count: no** |
| P4 | Ticks mode: 18 of 18 steady events no hold, as predicted; 0 skips; the hold half untested | **Untested** |
| P5 | ms6: 9 of 9 no hold, as predicted; the hold half untested | **Untested** |
| P6 | 0 freezes, 0 renderer recoveries or near-misses, `dropped-records 0` in every summary; **timing check FAILED** | Buffer and gate counts: yes. "`=2` does not perturb": **not established** |
| P7 | `queued` negative on 369,555 of 369,555 new-frame ticks | **Yes** |

**Survives:** every natural late swap away from a missed deadline is a crossing (492/492); a crossing's drift is the card's rate; a hold
needs a newest frame with lead under P and then a one-tick-late swap (3/3); every frame is queued before its tick; the forced switch
delays by what it says; the measurement buffer never overflowed.

**Does not survive:** that `=2` leaves timing unperturbed; all rates and counts (holds, crossings per block, late per hour, exposure);
the 59.94 result of 0 crossings in `pp-5994-sdi-lst`; anything about P4/P5's hold half.

### 12.7 Rerun

**Needed: all five blocks.** All failed the timing check, and the forced blocks cannot test P4/P5's hold half as built. Robbie's
decisions before the rerun:

1. **Layout.** 0.9.4's other two slots are UNKNOWN, so they cannot be restored, only fixed from now on. Proposed: Waveform | Parade |
   Markers. Waveform and Parade are the code defaults for slots 0 and 1, and Markers is needed for the gate's markers check. Record the
   chosen values here and use them on every later night.
2. **A same-night control**, because the 0.9.4 references were taken under an unknown layout: one 30-min `pp-5994-sdi` block with
   `=1` (or the signed `.build-rc094`) under the restored layout, before the `=2` blocks. 59.94 is where the misses are. If the control
   also misses deadlines, the rig is the cause; if it does not, the logging is. This adds a reference to criteria fixed before the run.
3. **Signing:** sign the candidate as 0.9.4 was (no keychain prompt, `LICENSED`), or keep it ad-hoc and accept the difference.
4. **Forced blocks:** with these semantics and random seeks, expect about 11 events per block in about 3 Plays. To exercise the hold half
   needs events in Plays with lead < P: either a switch that re-arms its entries at each Play (a DEBUG-only code change) or many more
   Plays.

**Restore sequence (not executed).** Run with no Manifold build running. Every write is preceded, in the same `&&` chain, by a read that
succeeded; the chain stops at the first failure.

```zsh
D=com.graviton.manifold; R=$HOME/Code/Manifold/Manifold
ST=$HOME/Code/_scratch/manifold-cardpull-s1/prefs-stash-$(date +%Y%m%d-%H%M%S).txt
$R/scripts/manifold-proc.sh guard \
 && s0=$(defaults read $D manifold.scope.slot0) \
 && s1=$(defaults read $D manifold.scope.slot1) \
 && s2=$(defaults read $D manifold.scope.slot2) \
 && st=$(defaults read $D showTray) \
 && [[ -n $s0 && -n $s1 && -n $s2 && $st == 1 ]] \
 && print -r -- "manifold.scope.slot0 $s0"$'\n'"manifold.scope.slot1 $s1"$'\n'"manifold.scope.slot2 $s2" > $ST \
 && [[ $(wc -l < $ST) -eq 3 ]] \
 && defaults write $D manifold.scope.slot0 -string waveform \
 && defaults write $D manifold.scope.slot1 -string parade \
 && defaults write $D manifold.scope.slot2 -string markers \
 && [[ $(defaults read $D manifold.scope.slot0) == waveform ]] \
 && [[ $(defaults read $D manifold.scope.slot1) == parade ]] \
 && [[ $(defaults read $D manifold.scope.slot2) == markers ]] \
 && echo "set; stash $ST"
```

To put the afternoon's values back after the rerun (`ST` = that stash file):

```zsh
D=com.graviton.manifold; R=$HOME/Code/Manifold/Manifold; ST=<stash file>
$R/scripts/manifold-proc.sh guard \
 && [[ -s $ST ]] \
 && c0=$(defaults read $D manifold.scope.slot0) && c1=$(defaults read $D manifold.scope.slot1) && c2=$(defaults read $D manifold.scope.slot2) \
 && o0=$(awk '$1=="manifold.scope.slot0"{print $2}' $ST) && o1=$(awk '$1=="manifold.scope.slot1"{print $2}' $ST) \
 && o2=$(awk '$1=="manifold.scope.slot2"{print $2}' $ST) \
 && [[ -n $c0 && -n $c1 && -n $c2 && -n $o0 && -n $o1 && -n $o2 ]] \
 && defaults write $D manifold.scope.slot0 -string $o0 \
 && defaults write $D manifold.scope.slot1 -string $o1 \
 && defaults write $D manifold.scope.slot2 -string $o2 \
 && [[ $(defaults read $D manifold.scope.slot0) == $o0 && $(defaults read $D manifold.scope.slot1) == $o1 \
       && $(defaults read $D manifold.scope.slot2) == $o2 ]] \
 && echo restored
```

`manifold.scope.trayHeight` (440.32 now; 0.9.4's UNKNOWN) and `controlDisplayMode` are left as they are.

---

## 13. Stage 1, night 2 (rerun; timing check passed)

Run 2026-11-16 23:59 to 2026-11-17 03:45, by `~/Code/_scratch/manifold-cardpull-s1r/soak.sh main <stash>`, candidate `3f05914`
(sha256 `fcb2a2ed…` checked by `need`). All four blocks ran to the end. The guard was clean before and after each block and at
exit, and no zoom.us process was running at setup or before any block. **The timing check passed on all four blocks**
(`timing.report`), with §11.6's criteria unchanged, so the night's results count. Rig state is recorded in `RIG.md` in that folder.

### 13.1 Rig

| | Night 1 (§12) | Night 2 |
|---|---|---|
| Slots | yrgb (→ Waveform) \| meters \| meters, no Markers (§12.1) | **Waveform \| Parade \| Markers**, set by §12.7's sequence; the earlier values stashed in `prefs-stash-20261116-235904.txt` and restored at exit (`soak.out`: "slots restored: yrgb \| meters \| meters", re-read afterwards) |
| Signing | ad-hoc, licence prompt denied | ad-hoc, unchanged (CONTROL is the same binary) |
| Zoom | **running, no windows** (Robbie) | closed; `ps -axo comm=` at setup and before each block (`zoomcheck`) |
| Window display | ASUS PA147, 59.936 Hz (§12.1) | ASUS PA147, 59.936 Hz in all 4 blocks (`<label>.json` `window_display`, from `[LINK]`). `system_profiler` at each block start: ASUS PA147 **1920 × 550** @ 60.00 Hz; LG TV SSCR2 3840 × 2160 @ 120 Hz, main (`soak.out`) |
| Markers | `no-gear` in all 12 Regenerates | Markers slot open in all 4 blocks; 21 Regenerates, all remade 5, none made while playing (MARKERS PASS, `soak.report:108`) |
| Forced blocks | 3 | none |
| Time | 19:45–23:10 | 00:09–03:45 (0.9.4: 23:00–06:08) |

The ASUS is 1920 × 550, not 1920 × 1080 class. That was true on both earlier nights too (same panel, §12.1).

Driver change for this night: `scripts/decklink-loopback/rc-soak.py` gained an opt-in `RC_EXPECT_DISPLAY` check after the window is
placed. It logs the window's display, and if the window is on any other display it quits by PID and the block is skipped (exit 8).
Unset, nothing changes. Uncommitted.

### 13.2 The control against the logged blocks

Read with `analyze.py` (same folder), which reproduces §12.2's figures from night 1's logs (154 of 186, 45 of 47, 56.9/s). Misses are
summed from the `[PACER]` 10 s lines, which print at `=1` and `=2` alike. "In-flight" means playing 10 s windows whose paired
`[PACER] desktop` line shows in-flight holds.

| Block | Log | Min | Pacer median / p99 / max (ms) | Missed | Missed / h | Playing windows with in-flight holds | Presented/s median | Window late / dropped |
|---|---|---|---|---|---|---|---|---|
| `ctl-5994-sdi` **CONTROL** | `=1` | 30 | 8.35 / 8.36 / 8.45 | **0** | 0 | 37 of 186 (20 %) | 59.9 | 3 / 4 |
| `pp-5994-sdi` | `=2` | 60 | 8.35 / 8.36 / 16.68 | **2** | 2 | 101 of 356 (28 %) | 59.9 | 15 / 6 |
| `pp-2398-cmp` | `=2` | 60 | 13.91 / 13.92 / 13.98 | 0 | 0 | 0 | 24.0 | 21 / 3 |
| `pp-gop25-sdi` | `=2` | 60 | 13.34 / 13.36 / 13.43 | 0 | 0 | 0 | 25.0 | 16 / 34 |
| *0.9.4 `rc-5994-sdi-1` / `-2`* | `=1` | 60 | 8.35 / 8.36 / 8.46 · 16.68 | *0 / 2* | *0 / 2* | *120 / 89 of 356* | *59.9* | *11 / 12 · 10 / 11* |
| *Night 1 `pp-5994-sdi-lst` / `-ms6`* | `=2` | 30 / 15 | 8.35 / 8.36 / 16.69 · 16.70 | *47 / 26* | *94 / 104* | *154 of 186 / 87 of 101* | *56.9 / 59.4* | *18 / 5 · 3 / 4* |

**Against the criteria written before the run (`RIG.md`):**
- CONTROL had 0 misses, and block 2 had 2 in 60 min, the same as 0.9.4's `rc-5994-sdi-2`. So the rig-cause branch ("CONTROL similar to
  block 2") does not apply: both are at 0.9.4's level. The logging-cause branch ("CONTROL ~0 **and block 2 many**") does not apply either:
  block 2 did not have many.
- **Verdict: `=2` logging does not perturb the window's timing.** It ran at 2 misses an hour at 59.94 and 0 at 23.976 and 25, all
  within the 0.9.4 references. **Night 1's 85 misses came from the rig, not the logging.** Night 2 changed several rig factors together:
  the slots (Waveform | Parade | Markers instead of Waveform | Meters | Meters), Zoom closed, the time of night. So which of them was
  the cause is UNKNOWN. Signing and display did not change between the nights.
- Desktop presentation is back at 0.9.4's level: 59.9 presented/s, and in-flight holds in 20–28 % of playing windows at 59.94
  (0.9.4: 25–34 %; night 1: 83–86 %).

**The 2 misses in `pp-5994-sdi`**, both pinned by `[TICKPHASE]` (interval > 1.5 P):
- `pp-5994-sdi.log:65390`, ~00:46:54: interval 16.673 ms, prev-tick 9.156 ms.
- `:640229`, ~01:27:16: interval 16.674 ms, prev-tick 8.457 ms.

The tick before each one overran, as on night 1. Neither produced a `[LATE-SWAP]` or a hold. Wall times are converted from host
seconds using the `[ARBITER]` NSLog line against `[PULLPHASE] pull #0` (±0.5 s).

### 13.3 Every late swap, by class (natural only; no forced events tonight)

| Block | crossing | pacer | decode | render | main | other | Crossing Plays | `dropped-records` |
|---|---|---|---|---|---|---|---|---|
| `pp-5994-sdi` | 400 | 0 | 0 | 0 | 0 | 0 | 5 | 0 |
| `pp-2398-cmp` | 240 | 0 | 0 | 0 | 0 | 0 | 5 | 0 |
| `pp-gop25-sdi` | 178 | 0 | 0 | 0 | 0 | 0 | 4 | 0 |

- **818 of 818 late swaps are crossings.** With 2 misses on the whole night there are no `pacer` swaps. CONTROL (`=1`) has no
  `[LATE-SWAP]` lines.
- The summaries' `crossings` field (85, 32, 24 runs) over-counts, as §12.4 explains.
- **P2, slope against +ppm within ±3 µs/s: 13 of 14 crossing Plays.**
  - 59.94 SDI and 25 SDI: 9 of 9, within 0.6 µs/s.
  - 23.976 Computer: 4 of 5. All five sit about 2 µs/s below +ppm (−1.85 to −2.12), and one is 4.95 below. Night 1 did not show this
    offset at 23.976 Computer. Why is UNKNOWN: it was not looked into tonight.
- **P7:** `queued` was negative on 365,670 of 365,671 new-frame ticks. The one exception (`pp-5994-sdi.log:423519`, `queued +0.53 ms`)
  is the first frame after a seek (`prev-to-due −670336 ms`), not steady play.

### 13.4 The holds, by cause

The gate counts 2 holds, both in `pp-2398-cmp` (`soak.report:37-39`). That is the GATE's FAIL line: 0 freezes, 0 unrecovered,
0 skips. 0.9.4's gate counted its holds the same way. §5 and §12.3 describe these holds as expected cadence events, not defects.

| Block, time (~) | Held pts | `[LATE-SWAP]` | Pull before (`branch next-by-band`) | Missed deadline |
|---|---|---|---|---|
| `pp-2398-cmp` 02:04:47 | 1650.273625 (`:125823`) | `:125825` **crossing**, prev-to-due −0.001 ms, interval 13.915 ms, `held yes` | `newest`, lead **6.18 ms** < P 13.90 | none (0 in the block) |
| `pp-2398-cmp` 02:24:26 | 627.460167 (`:241316`) | `:241318` **crossing**, prev-to-due −0.000 ms, interval 13.903 ms, `held yes` | `newest`, lead **8.31 ms** < P 13.90 | none |

- **Crossing 2, pacer 0.** Both have exactly P3's shape: a newest frame with lead under P, then a swap one tick late from a crossing.
  The next pull recovers. Night 1's two pacer holds (§12.3) needed a missed deadline, and tonight had none near a hold.
- P3's count (0–2 per block): 0, 2, 0. Within range.

### 13.5 What this changes

- **§12.2's open verdict is resolved in part:** the measurement build is cleared as the cause. Night 1's present-path overruns were a rig
  state, and night 2 did not reproduce them. Of the factors night 2 changed, which one caused them is UNKNOWN (§13.2).
- **Night 1's findings stand** (§12.6): crossings away from misses, drift at the card's rate, the hold precondition, P7. Night 2 also
  gives counts that can be used: 4–5 crossing Plays per hour per block, and 0–2 holds per block, all crossings.
- **Unchanged:** P4/P5's hold half is untested (no forced blocks). The "pacer" source of one-tick-late swaps (§12.3) exists, but needs
  a missed deadline that lands on a newest frame with lead < P. Tonight's 2 misses did not.
- **For later nights:** keep Waveform | Parade | Markers, Zoom closed, and the window display check. To find which rig factor caused
  night 1, change one factor per block, for example by putting the Meters slots back for one 59.94 block with everything else the same.

---

## 14. Option C, built behind `MANIFOLD_PACER_PHASE` (2026-11-17; A/B night run, §15; establishment guard added 2026-11-18, §14.4)

Built in the working tree on `fb553d3` (uncommitted). Candidate: `.build-pacerphase`, Profile, ad-hoc linker-signed, written 2026-11-17
11:52, sha256 `86eceab65975c90ee824a95c563efc3c2af21936ca5d89e97bcfc189897aac65`. No file under `App/`, `Packages/ManifoldCore/Sources/`
or `project.yml` is newer than it. Nothing was launched.

### 14.1 What was built

| File | What |
|---|---|
| `Packages/ManifoldCore/Sources/OutputPacing/OutputPacing.swift` | `PacerPhaseSample`; `PacerPhase.nextDeadline(previous:step:correction:)` (signed, saturating; 0 → `previous + step`), `phaseCorrection(enabled:phase:reference:)` (clamp ±20 µs), `reference(firstTicks:period:)` (median of 8, 0.5 ms guard at both edges), `isMatched` (the pull's test, verbatim), `isUnitRate` (±1 %); `PhaseDeviationStats`; `PacerPhaseFollower` (the state, the logging text) |
| `Packages/ManifoldCore/Tests/OutputPacingTests/PacerPhaseTests.swift` (new) | 20 tests |
| `App/OutputPacer.swift` | An optional `phaseSample` closure (nil with the switch off), `setPeriod(_:phaseMatched:)`, `followPhase`, the `[PACER-PHASE]` lines |
| `App/MetalVideoRenderer.swift` | `pacerPhaseEnabled` (`static let`, `:552`, `false` in Release `:557`); the sample after the selection (`:3757`, `:3857`); `takePacerPhaseSample`/`pacerPhaseSampleNow` (`:3483-3501`); the pacer made with or without the closure (`:3413-3449`) |
| `scripts/decklink-loopback/rc-soak.py` | `MANIFOLD_PACER_PHASE=1` allowed in `env`; a `nooutput` keyword (output never started) |

**How it runs (switch on).**
- The pacer calls `displayTick` synchronously. The renderer leaves a sample for the pacer to take right after the tick returns, on
  the same thread: `.active(x: selectNow − chosenPts)`, `.active(x: nil)` (no new frame), or `.inactive`.
- **Inactive** when any of these holds:
  - it is not a pacer tick (`tickGlassHost` set);
  - a live-clock hold is in place;
  - the pause provider does not say false;
  - the clock's rate since the previous tick is outside 1 ± 1 % (step, seek, shuttle, wrap, discontinuity);
  - a live route is installed: every live route installs one of `onDisplayTick`, `onDepthSample`, `presentationHoldFloor` or
    `onQueueOverflow`, and the file route none;
  - the rates are mismatched (`PacerPhase.isMatched`, computed in `schedulePacer` from the same read of the two rates, and handed to
    the pacer at start and re-rate).
- An inactive tick drops the reference. A wake or a re-rate drops it too (the pacer's `resumed`).
- x outside [0, P) is counted as an outlier and not used.

**One deviation from §7 C's text, and why.** x̄ is the median of the last eight x, each re-expressed at the corrections applied since
it was taken (`PacerPhaseFollower.tick`). Taken literally, a correction applied at every tick would be applied again at each tick until
the median of eight caught up with it: an overshoot of up to about four times, and ringing. With the re-expression the formula
c = clamp(−(x̄ − x_ref), ±20 µs) is unchanged, applied at every tick as §7 C says, and a step settles without overshoot
(`testAStepIsCorrectedWithoutOvershootOrRinging`). 10 h of 23.976 at −11.7 ppm stays within 5 µs of x_ref
(`testDriftNeverCrossesADueTime`).

**Logging (switch on only):**
- `[PACER-PHASE] armed · …matched…` at each pacer start and re-rate.
- `[PACER-PHASE] reference set · x_ref … · median … · guard none|applied (…) · P …`.
- Every 10 s: `new-frame ticks · inactive ticks · outliers · |x − x_ref| p50 p99 max · corrections applied (net) · clamp hits ·
  references set (guard)`.
- A `run:` line of the same counts at pacer stop.

### 14.2 Proof the switch-off path is unchanged

**Code.** With `MANIFOLD_PACER_PHASE` unset, any other value, or in Release:
- **The pacer.** It is made without a closure (`MetalVideoRenderer.swift:3446`; Release `:3449`), so `phaseSample` is nil.
  - Per tick, the loop does one nil test (`OutputPacer.swift:159`), then `deadline += step` (`:162`), the same statement as before.
    The missed-deadline arithmetic after it (`:164-168`) is untouched.
  - Outside the tick: one nil test in the resume path (`:143`, only on a wake or re-rate) and one at thread exit (`:171`).
  - At init, two stores and one nil test (`:64-66`). `setPeriod(_:)` is unchanged (`:87-89`); re-rate calls it, not the new overload
    (`MetalVideoRenderer.swift:3432`).
- **The renderer's tick.** Two reads of the same `static let` (`:3757`, `:3857`). Both are in the window's selection, which is not a
  protected path; the `nil` and the sample computation behind them do not run.
- **`schedulePacer`.** One read of the same `static let` (`:3415`).
- **No protected path is edited.**
  - File times: `FrameEngine.swift` (card lock 1a/1b, Stage 2, slips and re-anchor, the watchdog) 2026-11-15 18:00;
    `DeckLinkBridge.mm` (1c) 2026-11-15 13:26; `FileFrameSource.swift` and `LibavFrameSource.swift` (decode pumps) 2026-11-08.
  - In `MetalVideoRenderer.swift` the edits are at `:550-557`, `:3413-3501`, `:3757` and `:3857`. `noteDeckLinkTick` (`:5486`),
    `deckLinkPullMarginLocked` and `deckLinkPullSlotLocked` (`:6014`, its `matched` at `:6067`) are not among them.
- The files changed today are exactly these four: `OutputPacer.swift`, `MetalVideoRenderer.swift`, `OutputPacing.swift` and
  `PacerPhaseTests.swift` (`find -newer`).

**Tests.** `nextDeadline(p, s, 0) == p + s` across the range; `phaseCorrection(enabled: false, …) == 0`. Boundaries:
- underflow (a correction of a whole step or `Int64.min` still moves forward one unit);
- saturation at `UInt64.max`;
- the clamp at both signs, and exactly at ±20 µs;
- the guard at both edges and just inside and outside them;
- sign.

**Counts.**
- `swift test`: before 1,154 tests in 38 bundles, 0 failures, 1 skipped, 0 warnings; after 1,174 (the 20 new), 0 failures, 1 skipped,
  0 warnings.
- Profile build, clean: before 63 warning lines, after 63. With line numbers stripped the sets are identical except the AppIntents
  line's timestamp. No warning names a changed file's new code. Logs: `~/Code/_scratch/manifold-pacerphase-ab/build-logs/`.

**Not built:** Release. It does not link for the pre-existing `DeckLinkBridge.mm` reason (§11.5, `BUGS.md`). Every new reference is
inside `#if DEBUG` or is defined in both configurations (`pacerPhaseEnabled`, `logPacerPhaseArmed`). That is a code-level statement,
not a compile.

**Behavioral identity (§7 C (b))** is the A/B night's: the off-blocks' 0 `[PACER-PHASE]` lines and their gate and pacer counts.

### 14.3 The A/B night (run 2026-11-17/18; results in §15)

`~/Code/_scratch/manifold-pacerphase-ab/`: `RIG.md` (rig, blocks, and the criteria, written before any run), `common.sh`, `soak.sh`,
`ab-check.py`.
- **Blocks:** 23.976 Computer off/on, 25p SDI on/off, 59.94 SDI off/on, 60 min each, `=2` throughout. Then three 20-min identity
  blocks with the switch on: WAV to SDI, 25p on 1080p59.94, and output off.
- **Duration:** about 7 h 20 min.
- **Not judged on two identity blocks:** the gate's holds and skips are defined only at a matched rate with output on
  (`rc-soak-report.py:4`), so they are not judged on the rate-mismatch block or the output-off block (`RIG.md`, criterion 1).

### 14.4 The establishment guard (2026-11-18; built, not run)

Option C was committed after the night as `3413a6e`. This change is in the working tree on HEAD `a6f541c`, uncommitted.

**Why.** After a loop wrap in `ab-5994-sdi-on`, the 8 ticks that set x_ref sat on the due time (x ≈ 8.336 ms at P 8.3417 ms).
Until x_ref is set, nothing moves the ticks, so they dithered across the due time and produced 4 crossings (§15.3). The guard
applied to x_ref only once the eighth tick set it.

**What.** `PacerPhase.establishmentCorrection(x:period:)`, a pure function in `OutputPacing.swift`.
- It runs at every new-frame tick from the first one after a wake, a re-rate, a wrap or a discontinuity (anything that drops the
  reference) until x_ref is set.
- **x < 0.5 ms → moved later, to 0.5 ms. x > P − 0.5 ms → moved earlier, to P − 0.5 ms.** This is the same rule and the same edges
  as the reference's guard (`reference(firstTicks:period:)`).
- The move is made in **one step, at most 0.5 ms**. It is not clamped to 20 µs: at 20 µs a tick, 0.5 ms takes 25 ticks, which is
  longer than the 8-frame window being protected.
- **Dead band:** no move within 20 µs past either edge (x in [0.48, 0.5) ms, or in (P − 0.5, P − 0.48] ms). So a phase that has
  settled on an edge is not moved again by its own jitter. Such a phase is still ≥ 0.48 ms from a due time.
- Outliers (x outside [0, P)), a non-finite x and a bad period all give 0.

**The follower** (`PacerPhaseFollower.tick`, establishing branch):
- Each first sample is stored as x − (the moves applied so far), the same convention as the follow's ring. At the eighth sample the
  median is taken of the eight re-expressed at the current moves, so x_ref is the median of the phase *as moved*, not of the raw first
  sample. The A/B wrap gives x_ref ≈ P − 0.5 ms, not a median that still includes 8.336 ms.
- **`applied` is one continuous total** from the reference's drop: the establishment moves, then the follow's corrections. Only
  `reset()` restarts it (a wake, a re-rate, any inactive tick); setting x_ref does not.
  - The first build restarted it at 0 when x_ref was set, as §14.1's follower did. In the app that was only bookkeeping: the deadline
    did not move back, and the follow's phase (ring median + `applied`) stayed correct.
  - But `applied` is the follower's public total, and `testAWrapOnADueTimeIsMovedOffItAtTheFirstTick` models the phase as
    u + `applied`. There the restart read as a 0.497 ms jump back onto the due time, and the follow then walked x down at its 20 µs
    clamp (8.3405 → 7.9635 ms). That test failed in Robbie's first `swift test`. A line-for-line Python replay reproduced its x values
    exactly; with the total kept continuous, the replay and the test pass.
- **The first move's direction is locked for its establishment.** x near 0 and x near P are both on a due time, one each side of
  it, and both trigger the guard. After a first move (say earlier, from x near P), a later sample read on the other side of the due
  time (x near 0, which alone would move later) is not moved back across it. A further sample on the first side still moves, the
  same way. `reset()` and setting x_ref clear the lock. Without it the guard could fight itself across the wrap, but only if a
  sample jumped 0.48 ms or more after a move. That never happened in the test or on the A/B night.
- Moves are counted apart from the follow's corrections (`Counts.nudges`, `nudgeNet`), so "corrections applied" keeps its meaning.
- After x_ref is set, nothing has changed: the follow, its 20 µs clamp and the re-expression are as in §14.1.

**Logging (switch on only):**
- A new event line: `[PACER-PHASE] establishment guard · x … ms within 0.5 ms of a due time · moved ±… ms · P … ms`
  (`OutputPacer.followPhase`).
- The 10 s and `run:` lines end with `· establishment nudges N (net ±… ms)`. `ab-check.py`'s `run:` regex still matches, and it now
  reads the nudges too.

**Switch-off path: unchanged.**
- The new function is called only from `PacerPhaseFollower.tick`.
- The new log line is inside `followPhase`.
- Both run only with `phaseSample` set. That is `MANIFOLD_PACER_PHASE=1`, DEBUG.
- §14.2's switch-off sites (`OutputPacer.swift` nil tests, `deadline += step`, `MetalVideoRenderer.swift`) are not edited.
- Files changed: `OutputPacing.swift`, `OutputPacer.swift` (a header comment and the log line), `PacerPhaseTests.swift`.

**Tests** (`PacerPhaseTests.swift`, 26 now, 6 of them new):
- `testEstablishmentCorrectionAtTheEdgesAndInside`:
  - x = 0 → +0.5 ms;
  - x = P − 1 ns, and the A/B night's 8.336 ms → moved to P − 0.5 ms;
  - normal phases (1, 4, 7.5 ms) and both dead bands → 0, with 21 µs past each edge → moved;
  - outliers, NaN, ∞ and bad periods → 0;
  - the 23.976 P.
- `testAWrapOnADueTimeIsMovedOffItAtTheFirstTick`: the A/B wrap with ±10 µs jitter straddling the due time. There is 1 move, at the
  first tick. After it, no x is within 0.4 ms of a due time. x_ref is within 15 µs of P − 0.5 ms.
- `testAPhaseOnTheDueTimeFromAfterIsMovedLater`: x = 0 → +0.5 ms once. x_ref = 0.5 ms. 0 follow corrections.
- `testANormalPhaseIsUntouchedWhileEstablishing`: 0 moves, and x_ref is the plain median of the eight, as before.
- `testTheFirstMovesDirectionIsLockedForItsEstablishment`:
  - after a move earlier from x = 8.339 ms, a sample at x = 2 µs is not moved and gives no event;
  - a further sample at 8.339 ms moves earlier again (2 moves, no x_ref yet);
  - the mirror: after a move later from x = 2 µs, a sample at 8.339 ms is not moved;
  - after an inactive tick the next establishment moves earlier again.
- `testEveryRestartGuardsItsOwnEstablishment`: an inactive tick drops x_ref and the moves. The next establishment is guarded afresh.
  Outliers while establishing do not move anything.
- **Changed:**
  - `testNothingHappensWithoutEightNewFrames` now uses x = 4 ms. Its old x = 0.1 ms is now moved by design.
  - `testReferenceEventAndGuardMovesTheTicksLaterInClampedSteps` now uses x = 0.49 ms (the dead band: no move; x_ref raised; one
    10 µs follow step), plus a 0.3 ms step after x_ref that is closed in clamped steps.
  - `testDeviationStatsAndReport` checks the line's new suffix.

**`swift test`** (run by Robbie; this session's permission classifier refuses it):
- **Run 1** (5 new tests): 1 failure, `testAWrapOnADueTimeIsMovedOffItAtTheFirstTick`. The cause is the `applied` restart above.
- **Run 2** (after the fix): passed, with no failures reported. Its totals were not passed on, so they are UNKNOWN here.
- **Run 3** (after the direction-lock test): **1,270 tests, 0 failed, 2 skipped.** That is the suite's 1,264 before this change (after
  the marker / Premiere work; §14.2's 1,174 is stale) plus the 6 new tests. Which tests are skipped is not recorded here; 2 skipped
  against §14.2's 1 is not explained by this change, which adds no skip.

**Build.**
- `.build-pacerphase-2`, Profile, `CODE_SIGNING_ALLOWED=NO`, ARCHS arm64: **BUILD SUCCEEDED** (this compiles `OutputPacing`'s
  sources, not its tests).
- sha256 `5fdb90a44e782738b4d9812c07b3cd034ec5cf7e9d8353471f36f6152ac6e6a2`, the rebuild after the `applied` and direction-lock fix
  (the first build was `00bf0585…`). The direction-lock test is test-only, so it does not change the app binary.
- The first build (clean): 63 warning lines, the same count as §14.2's. None names `OutputPacing.swift` or `OutputPacer.swift` (they name ContentView,
  DeckLinkService, FrameEngine, FrameShare, InterpretationLUT, LibavAudioSource, LicenseManager, MetalVideoRenderer,
  SyntheticLiveSource, WindowSizer).
- The set differs from §14.2's list in some `AVSampleBufferAudioRenderer` Sendable lines. HEAD has moved since `fb553d3`, and those
  lines come from files not changed here.
- The rebuild was incremental and recompiled `OutputPacing.swift` and the app target. It printed 53 warning lines (only those of the
  recompiled files), none in `OutputPacing.swift` or `OutputPacer.swift` (`profile-build-fix1.log`).
- Logs: `~/Code/_scratch/manifold-pacerphase-ab/build-logs-2/`. Nothing was launched.

**Risks, against §7 C:**
- One pacer interval moves by up to 0.5 ms (at 59.94, one tick of about 7.84 ms instead of 8.34 ms). §7 C's 20 µs clamp was chosen so
  a tick "never moves visibly". This is a single step, once per establishment, and only when the phase is within 0.5 ms of a due time.
  Its effect on the window's present path ("two waiting presents above 61 Hz", `6581dcd`) is UNKNOWN. Watch it in the next A/B.
- Moving later at x ≈ 0 shrinks the card's lead by up to 0.5 ms right after Play or a wrap. That is §7 C's guard risk (`:442-444`),
  now taken at the first tick instead of after 8 frames.

---

## 15. Option C A/B night (run 2026-11-17/18): **FAIL**

Started by hand at 20:37 on 2026-11-17 (`soak.sh main`). The first block began at 20:49:54 and the last ended at 03:58:46, and
`ENDED` was written at 03:58. All 9 blocks ran to the end (`"ended": "done"` in every `<label>.json`) and none was skipped. Analysed
2026-11-18 with `ab-check.py` against `RIG.md`'s criteria, which were written before the run. Re-running it on the logs gives output
byte-identical to the night's own `ab.report`. Paths below are relative to `~/Code/_scratch/manifold-pacerphase-ab/`. Host times are
converted to wall times through each block's `<label>.defout` (host, UTC) pair, to about ±1 s.

**Verdict: FAIL.** 6 criteria failed (`ab.report`, "== criteria"). Criterion 3 was met: 483 off-block crossings, against 5 needed.
So the night is not inconclusive.

### 15.1 Rig

- **Checked before every block: passed 9 of 9** (`rig.log`, one entry per block, 20:49:53 to 03:38:04). Each entry shows:
  - zoom.us none, capture closed, default output Scarlett (also in each `<label>.defout`);
  - sha256 `86eceab65975c90e…` ok;
  - slots `waveform | parade | markers`;
  - `RC_EXPECT_DISPLAY` ASUS PA147;
  - signing `flags=0x20002(adhoc,linker-signed)`, `TeamIdentifier=not set`;
  - displays: ASUS PA147 1920 × 550 @ 60 Hz, LG TV SSCR2 3840 × 2160 @ 120 Hz.
- **Window display:** ASUS PA147 at 59.936 Hz in all 9 blocks (`<label>.json` `window_display`, `window_display_hz`).
- **`MANIFOLD_PACER_PHASE`:** the `.json` files show `"1 entries"`. That is `rc-soak.py:108` redacting the value, not the value
  itself. The on-blocks' `[PACER-PHASE] armed` lines confirm the switch was on, and the off-blocks have 0 `[PACER-PHASE]` lines.
- **Slots restored: yes.** Read on 2026-11-18, `com.graviton.manifold` `manifold.scope.slot0/1/2` are `yrgb | meters | markers`.
  That is exactly the stash `prefs-stash-20261117-203721.txt`. `restore()` is the only thing in the night that writes those keys, and
  it writes them only after its own `manifold-proc.sh guard` passes. So the guard was also clean at exit.
- **Not on file:** `soak.out` does not exist. The night was started by hand without a redirect, so `soak.sh`'s stdout went to the
  terminal. That stdout held the `guardp` "after" results, the idle-gate lines, the `setslots` line and the `restore` lines. Their text
  is therefore UNKNOWN.
  - Each "after" guard is implied: a guard trip exits 2 before the next block (`soak.sh` `blk`), and all 9 blocks ran.
  - The last "after" guard (block 9) is UNKNOWN (inference: clean, because the restore's guard passed moments later).
  - For later nights: `soak.sh main > soak.out 2>&1`.

### 15.2 Per block

Crossings are `[LATE-SWAP] class crossing`. Holds and skips are the gate's counts (`soak.report`).

| # | Block | Crossings | All `[LATE-SWAP]` by class | Holds | Skips | Freezes | Renderer recov. / near-miss | Window late / dropped | Markers |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `ab-2398-cmp-off` | **128** | crossing 128 | 0 | 0 | 0 | 0 / 0 | 11 / 3 | PASS |
| 2 | `ab-2398-cmp-on` | **0** | — | 0 | 0 | 0 | 0 / 0 | 16 / 4 | PASS |
| 3 | `ab-gop25-sdi-on` | **0** | — | 0 | 0 | 0 | 0 / 0 | 18 / 25 | PASS |
| 4 | `ab-gop25-sdi-off` | **89** | crossing 89 (1 held) | 1 | 0 | 0 | 0 / 0 | 23 / 26 | PASS |
| 5 | `ab-5994-sdi-off` | **266** | crossing 266, pacer 41 (0 held) | 1 | 0 | 0 | 0 / 0 | 19 / 6 | PASS |
| 6 | `ab-5994-sdi-on` | **4** | pacer 36 (5 held), render 18, decode 4, crossing 4 | **28** | **4** | 0 | **1** / 0 | 15 / 31 | PASS |
| 7 | `id-ao48-sdi-on` | 0 | — | 0 | 0 | 0 | 0 / 0 | 0 / 0 (no video) | (none) |
| 8 | `id-gop25-at-5994-on` | 662 | other 6723, render 2925, main 810, crossing 662 | 37568 (not judged) | 26881 (not judged) | 0 | 0 / 0 | 12 / 7 | **FAIL** |
| 9 | `id-5994-nooutput-on` | 0 | — | 0 (not judged) | 0 (not judged) | 0 | 0 / 0 | 1 / 78 | PASS |
| | **Off (1, 4, 5)** | **483** | | 2 | 0 | 0 | **0** / 0 | | |
| | **On (2, 3, 6)** | **4** | | 28 | 4 | 0 | **1** / 0 | | |
| | **Night** | | | 37598 | 26885 | **0** | 1 / 0 | 115 / 180 | 1 failing |

**Pacer** (`[PACER] stopped … intervals over the run`). P is computed from the `[PACER] started` line's rates and k (criterion 7).

| # | Block | P (ms) | n | Median | p99 | Max | Missed deadlines | Playing 10 s windows with in-flight holds | Presented/s median | Crit. 7 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2398 off | 13.9028 | 245526 | 13.91 | 13.92 | 27.81 | 2 | 0 of 357 | 24.0 | PASS |
| 2 | 2398 on | 13.9028 | 245532 | 13.91 | 13.92 | 27.80 | 3 | 0 of 357 | 24.0 | PASS |
| 3 | gop25 on | 13.3333 | 256194 | 13.34 | 13.36 | 26.67 | 10 | 0 of 357 | 25.0 | PASS |
| 4 | gop25 off | 13.3333 | 256209 | 13.34 | 13.36 | 13.42 | 0 | 0 of 357 | 25.0 | PASS |
| 5 | 5994 off | 8.3417 | 409177 | 8.35 | 8.36 | 16.70 | **91** | **275 of 357** | 58.8 | PASS |
| 6 | 5994 on | 8.3417 | 409175 | 8.35 | 8.36 | 25.02 | **100** | **270 of 357** | 53.9 | PASS |
| 7 | ao48 (id) | 8.3417 | 135526 | 8.35 | 8.36 | 8.43 | 0 | — | — | PASS |
| 8 | gop25 @ 59.94 (id) | 8.3417 | 136519 | 8.35 | 8.36 | 16.70 | 21 | 1 of 119 | 25.0 | PASS |
| 9 | no output (id) | — | no pacer | | | | | | | n/a |

The in-flight and presented/s columns use §13.2's method: the `[PACER] desktop` 10 s lines with rendered > 0. The misses on the
59.94 blocks are spread evenly through each hour (per 10 min: off 16, 19, 10, 12, 14, 20; on 16, 19, 16, 15, 16, 18).

**`[PACER-PHASE]` on the on-blocks** (`run:` line):

| Block | \|x − x_ref\| p50 / p99 / max (ms) | n | Corrections applied (net) | Clamp hits | References set (guard) | Crit. 6 |
|---|---|---|---|---|---|---|
| 2398 on (`:357587`) | 0.005 / **0.042** / 0.370 | 79335 | 58595 (+42.765 ms) | 230 | 132 (15) | PASS |
| gop25 on (`:372208`) | 0.005 / **0.075** / 0.419 | 82856 | 59231 (+35.060 ms) | 1026 | 126 (9) | PASS |
| 5994 on (`:864572`) | 0.004 / **0.018** / 0.435 | 199947 | 144637 (+32.264 ms) | 227 | 130 (12) | PASS |

**Identity blocks:**
- **7 `id-ao48-sdi-on`:** armed "not matched: inactive". Corrections applied 0 in the run line (`:78350`) and 0 summed over the 10 s
  lines. References 0, inactive ticks 135547.
- **8 `id-gop25-at-5994-on`:** armed "not matched: inactive". Corrections applied 0 in the run line (`:222530`) and 0 summed over the
  10 s lines. References 0, inactive ticks 136555.
- **9 `id-5994-nooutput-on`:** 0 `[PACER-PHASE]` lines and no `[PACER]` run line.
- **Criterion 9 (switch off prints nothing):** 0 `[PACER-PHASE]` lines on blocks 1, 4 and 5.

### 15.3 The holds, by cause

| Block, time (~) | Holds / skips | Cause | Evidence |
|---|---|---|---|
| `ab-gop25-sdi-off` 00:32:30 | 1 / 0 | **Crossing**, the late window frame repeated once: the gate's named exception | `:238890` (swapAgo 46 ms), `:238906` `class crossing … held yes` |
| `ab-5994-sdi-off` 01:25:39 | 1 / 0 | **Missed pacer tick, with no `[LATE-SWAP]` line printed** | See the note below this table |
| `ab-5994-sdi-on` 02:02:33 | **23 / 4** | **Pacing-renderer stall** (AVFoundation), recovered | See the note below this table |
| `ab-5994-sdi-on` 02:17:23, 02:22:23, 02:23:02, 02:40:32, 02:50:17 | 5 / 0 | **Missed pacer tick**, each a `[LATE-SWAP] class pacer … held yes`, interval 16.68–16.70 ms | `:308288`, `:378964`, `:388664`, `:638078`, `:776624` |
| `id-gop25-at-5994-on` | 37568 / 26881 | 25p on 59.94: the expected cadence, not judged (criterion 1) | — |

- **The `ab-5994-sdi-off` hold.** `[TICKPHASE]` `:441628`: interval 16.679 ms, prev-tick 10.842 ms, `ring none`. The swap landed at
  host .870130, 4 µs after the pull at .870126 (`:441473-441474`). In mechanism it is a late window frame repeated once. With no
  `[LATE-SWAP]` line it is not the named exception as criterion 1 defines it, so `ab-check.py` fails this block's gate. Why no
  `[LATE-SWAP]` line was printed is UNKNOWN (inference: the `ring none` tick).
- **The `ab-5994-sdi-on` stall.**
  - `[RENDERER-RECOVER] attempt 1` `:96749`: no pump callback for 0.538 s, renderer status 1, `ready false`.
  - The picture moved again 46 ms after the re-arm, 0.393 s after the stall began (`:96772`).
  - Then 4 `class decode` late swaps (`:96778-96787`). Window dropped/late 9 + 18 (`ab-5994-sdi-on.json` `latedrop`).
  - The 4 skips (+9, +5, +9, +4 frames) are the catch-up.
  - The pacer's ticks continued throughout. Whether option C contributed is UNKNOWN. §7 C names no path from tick timing to the
    pacing renderer. One stall in one block cannot separate the switch from chance.

**The 4 on-block crossings** (`ab-5994-sdi-on.log:118094-118103`) held nothing. All four are in one cluster just after a loop wrap
(~02:04:03):
- The first 8 new-frame ticks after the wrap sat at x ≈ 8.336 ms, at the due time (P 8.34).
- `[PACER-PHASE] reference set` (`:118063`) then applied the guard: x_ref 7.842 ms, "lowered to P − 0.5 ms".
- The 4 crossings are in that reference window, before any correction. 18 `class render` late swaps follow (`:118106-118193`). In
  them x steps from 8.12 down to 7.84 ms and then holds there: the follow at the clamp, walking to x_ref.
- So option C leaves the phase unguarded until x_ref is set, and a Play or wrap whose phase lands on a due time crosses during those
  ticks. CONFIRMED by these lines. §7 C's risk list covered the guard moving ticks later at Play (`:442-444`), not this case.

**The block 8 markers failure** (`soak.report:178`, `id-gop25-at-5994-on.json` `regens[0]`). Of the 5 remade thumbnails, 1 counts as
made while playing. It was made at host 365728.241, 3.6 ms before that Regenerate's Pause at 365728.2446. That is a near tie. Criterion
1 exempts block 8 only from holds and skips, so this fails its gate.

### 15.4 Against the criteria

| # | Criterion | Result |
|---|---|---|
| 1 | 0.9.4 gate on every block | **FAIL on 3 blocks:** 5 (1 hold, no `[LATE-SWAP]`), 6 (28 holds, 4 skips), 8 (markers). PASS on 1, 2, 3, 4 (named exception), 7, 9 |
| 2 | On-blocks: 0 crossings, 0 holds | PASS on 2 and 3. **FAIL on 6** (4 crossings, 28 holds) |
| 3 | Off-blocks ≥ 5 crossings | **Met: 483** (128 + 89 + 266) |
| 4 | Renderer recoveries + near-misses, on ≤ off | **FAIL:** on 1, off 0 |
| 5 | 0 freezes, 0 skips | Freezes 0 everywhere. **FAIL:** 4 skips on block 6 |
| 6 | \|x − x_ref\| p99 ≤ 0.1 ms on 2, 3, 6 | PASS: 0.042, 0.075, 0.018 |
| 7 | Pacer median P ± 0.01, p99 ≤ P + 0.05 | PASS on all 8 blocks with output |
| 8 | Identity: 0 corrections; block 9 no pacer | PASS |
| 9 | Switch off prints nothing | PASS |

### 15.5 What this shows (not part of the verdict)

- **At 23.976 Computer and 25p SDI, option C did what it claims.** Crossings went from 128 and 89 to 0 and 0. Holds were 0, and
  |x − x_ref| p99 was 0.042 and 0.075 ms. The 25p on-block's 10 misses (against 0 off), and its max interval of 26.67 ms, produced no
  late swap. Its 1026 clamp hits are about 4× the other on-blocks'. Why is UNKNOWN.
- **The 59.94 pair ran under a degraded present path on both sides.** Misses were 91 off and 100 on, against night 2's 2 (§13.2).
  In-flight holds were in 77 % and 76 % of playing windows (night 2: 28 %, night 1: 83 %), and there were pacer late swaps (41, 36)
  where night 2 had none. Every rig item checked was the same as night 2's, so the cause is UNKNOWN. The 25p and 23.976 blocks on the
  same night had 0 in-flight windows. Presented/s on the on-block was 53.9, against 58.8 off. Whether that gap comes from option C or
  from the rig state is UNKNOWN.
- **The failures, by origin:**
  1. one pacing-renderer stall, cause UNKNOWN (23 holds, 4 skips, the recovery behind criterion 4);
  2. 5 holds from missed pacer ticks in the degraded 59.94 state. Off had 41 pacer late swaps and none held; on had 36 and 5 held.
     Why is UNKNOWN;
  3. 4 crossings in the reference window after a wrap: a gap in option C itself (§15.3);
  4. one unclassified miss hold on an off-block;
  5. one markers near-tie on an identity block.
- **Open:**
  - Guard the phase during the reference window. **Built 2026-11-18, not run: §14.4.**
  - Find what degraded the 59.94 present path tonight.
  - Repeat the 59.94 pair under night 2's present-path state before the comparison is read.
  - Have `[LATE-SWAP]` print for a `ring none` tick.

### 15.6 The same night, by cause (`ab-check.py` as updated 2026-11-18)

`ab-check.py` now classifies every gate hold and skip by cause. The night's copy is kept as `ab-check-20261117.py`. The classes are:
- **renderer stall:** within a `[RENDERER-RECOVER]` stall's stated span, plus 0.5 s;
- **the `[LATE-SWAP]` class:** the held frame's successor has a `held yes` swap;
- **pacer (no `[LATE-SWAP]`):** no swap line, but the successor's `[TICKPHASE]` interval is over 1.5 P;
- **unclassified:** none of the above.

The script then prints two verdicts. The pre-registered one is unchanged; re-run, its output differs from the night's `ab.report`
only in the verdict line's label. The second judges option C on crossings and crossing-caused holds. On this night the classes match
§15.3's hand count exactly:

| Block | Crossing | Pacer (`[LATE-SWAP]`) | Pacer (no `[LATE-SWAP]`) | Renderer stall | Unclassified |
|---|---|---|---|---|---|
| `ab-gop25-sdi-off` | 1 hold | | | | |
| `ab-5994-sdi-off` | | | 1 hold | | |
| `ab-5994-sdi-on` | | 5 holds | | 23 holds, 4 skips | |
| every other block where defined | | | | | none |

- **Option C, judged by cause:** on-blocks 0 crossings and 0 crossing-caused holds or skips; 0 freezes; criteria 6–9; and criterion 3
  for inconclusive.
- **Reported, not judged in this verdict:** non-crossing holds and skips, markers, and criterion 4 (renderer recoveries and
  near-misses).
- **Result: FAIL, on 1 criterion:** `ab-5994-sdi-on`'s 4 crossings. They caused no holds, and they are what §14.4 addresses.
- **The pre-registered verdict stays FAIL** (6 criteria). The by-cause verdict does not replace it. It is the reading to take into the
  next night's criteria, which must be written before that night runs.
