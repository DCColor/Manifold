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

### 14.4 The establishment guard (2026-11-18; run on A/B night 4, §16)

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

---

## 16. Present-path night (A/B night 4, run 2026-11-18): C **PASS**, G **FAIL**, P complete

Started by hand (`soak.sh main > soak.out 2>&1`). The slots were set at 13:19:52. The first block began at 13:30:24, after the
10 min idle wait, and the last ended at 18:36:03. `ENDED` was written at 18:36 and there is no `STOP` file. All 5 blocks ran to the
end (`"ended": "done"` in every `<label>.json`, `block … exit 0` in `soak.out`), and none was skipped. Analysed 2026-11-18 with
`ab-check.py` against `RIG.md`'s criteria, which were written before the run. Re-run on the logs (through symlinks, so the night's
`present.report` was not overwritten), `ab-check.py`, `present.report` and `rc-soak-report.py`'s output are byte-identical to the
night's `ab.report`, `present.report` and `soak.report`. Paths below are relative to `~/Code/_scratch/manifold-pacerphase-ab3/`.
Host times are converted to wall times through each block's `<label>.defout` (host, UTC) pair, to about ±1 s.

**Verdicts (`ab.report`):**
- **C (option C with the establishment guard, by cause): PASS.** Criteria 1–7 passed, and criterion 8 was met: 340 crossings on the
  off-block, against 5 needed. So the night is not inconclusive.
- **G (the 0.9.4 gate, every block): FAIL on 2 blocks.** Block 1 had 2 holds and block 5 had 1. All 3 are `pacer` holds, each a
  missed pacer tick (§16.3). Blocks 2, 3 and 4 passed. There were 0 skips and 0 freezes on every block.
- **P (the present path): measurement complete on all 5 blocks.** Each has a `total` line, 0 dropped records, and as many `miss`
  lines as its total's count. The findings are in `WINDOW_PRESENT_PATH.md` §5. In short: the step that overran is
  `CATransaction.commit` on 239 of 245 missed ticks, and the bad state (in-flight holds in more than 50 % of playing windows)
  appeared on all three 59.94 blocks, the first block of the night included.

### 16.1 Rig

- **Checked before every block: passed 5 of 5** (`rig.log`, one entry per block, 13:30:24 to 17:34:56). Each entry shows:
  - zoom.us none, capture closed, default output Scarlett (also in each `<label>.defout`);
  - sha256 `681b7cf7ed38bd4a…` ok;
  - slots `waveform | parade | markers`;
  - `RC_EXPECT_DISPLAY` ASUS PA147;
  - signing `flags=0x20002(adhoc,linker-signed)`, `TeamIdentifier=not set`;
  - displays: ASUS PA147 1920 × 550 @ 60.00 Hz, LG TV SSCR2 3840 × 2160 @ 120.00 Hz.
- **HID idle at each block start** (`soak.out`): 628, 4296, 7964, 11633 and 15300 s. Resolve was closed each time.
- **Window display:** ASUS PA147 at 59.936 Hz in all 5 blocks (`<label>.json` `window_display`, `window_display_hz`; `soak.out`
  "window display" lines).
- **Switches:** `extra_env` now shows the values (§15.1's `"1 entries"` is fixed). The on-blocks have `MANIFOLD_PACER_PHASE: 1`, the
  off-block does not, and all 5 have `MANIFOLD_DECKLINK_CADENCE_LOG: 2` and `MANIFOLD_PRESENT_TIMING: 1`. The on-blocks' `[PACER-PHASE]
  armed` lines confirm the switch was on (`:81`, `:70`, `:137`, `:70`), and the off-block has 0 `[PACER-PHASE]` lines.
- **Guards:** "guard after …: clean" for all 5 blocks (`soak.out` 14:31:31, 15:32:39, 16:33:47, 17:34:55, 18:36:03). `guardp` before
  each block prints only when it trips and then stops the night, and all 5 blocks ran.
- **Slots restored: yes.**
  - `setslots` (13:19:52): "slots set: waveform | parade | markers; were yrgb | meters | markers", stash
    `prefs-stash-20261118-131952.txt`.
  - At exit (18:36:16): "slots at the end of the night: waveform | parade | markers", then "slots restored: yrgb | meters | markers".
    `restore()` prints that line only after its own guard, the three writes and a read-back all succeed (`soak.sh` `restore`).
  - Read again in this session, `com.graviton.manifold` `manifold.scope.slot0/1/2` are `yrgb | meters | markers`, which is exactly the
    stash.
- **`soak.out` was kept** (169 lines). Its first line is the `setslots` line. It carries no note from Robbie about launches earlier in
  the evening.
- **Recorded, never stopping the night** (`rig.log`):

| # | Block | Keychain prompts denied tonight before it (earlier launches) | Denied in it | SecurityAgent processes before | Memory free before / after | `ASEProcessing` per minute (end − 6 to end − 1 min) | Thermal |
|---|---|---|---|---|---|---|---|
| 1 | `n4-5994-sdi-on-1` | **0 (0)** | 2 (13:30:33, 13:31:11) | 0 | 85 % / 85 % | 3281 | no warning recorded |
| 2 | `n4-2398-cmp-on` | 2 (1) | 2 | 0 | 85 % / 86 % | 2543 | the same |
| 3 | `n4-gop25-sdi-on` | 4 (2) | 2 | 0 | 86 % / 87 % | 2646 | the same |
| 4 | `n4-5994-sdi-off` | 6 (3) | 2 | 0 | 86 % / 87 % | 3279 | the same |
| 5 | `n4-5994-sdi-on-2` | **8 (4)** | 2 | 0 | 86 % / 87 % | 3279 | the same |

- **Not covered:** launches and prompts before `soak.sh` started are UNKNOWN. `soak.out` has no note about them. The unified log cannot
  recover them either: `/usr/bin/log show --predicate 'process == "SecurityAgent"'` returns 0 lines for 12:10–13:30:20, and also 0
  for 13:30:25–13:31:20, which contains a denial that `soak.out` records. So that store does not keep these prompts.

### 16.2 Per block

Crossings are `[LATE-SWAP] class crossing`. Holds and skips are the gate's counts (`soak.report`).

| # | Block | Crossings | All `[LATE-SWAP]` by class | Holds | Skips | Freezes | Renderer recov. / near-miss | Window late / dropped | Card late / dropped | Markers |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `n4-5994-sdi-on-1` | **0** | pacer 32 (2 held) | **2** | 0 | 0 | 0 / 0 | 17 / 7 | 1 / 3 | PASS |
| 2 | `n4-2398-cmp-on` | **0** | — | 0 | 0 | 0 | 0 / 0 | 16 / 7 | 0 / 0 | PASS |
| 3 | `n4-gop25-sdi-on` | **0** | — | 0 | 0 | 0 | 0 / 0 | 22 / 27 | 0 / 0 | PASS |
| 4 | `n4-5994-sdi-off` | **340** | crossing 340 (0 held), pacer 36 (0 held) | 0 | 0 | 0 | 0 / 0 | 12 / 10 | 0 / 0 | PASS |
| 5 | `n4-5994-sdi-on-2` | **0** | pacer 24 (1 held) | **1** | 0 | 0 | 0 / 0 | 10 / 10 | 0 / 0 | PASS |
| | **On (1, 2, 3, 5)** | **0** | | 3 | 0 | 0 | 0 / 0 | | | |

Markers: 30 Regenerates, all 150 thumbnails remade, 0 made while playing, 0 finished after Play (`soak.report`, "== MARKERS").
Recorded and not judged: `edge APPENDED by the card` lines 8, 0, 0, 21, 14 (`soak.report`, "SDI bridge").

**Pacer** (`[PACER] stopped`; P from the `[PACER] started` line). In-flight holds and presented/s use §13.2's method (`[PACER] desktop`
lines with rendered > 0).

| # | Block | P (ms) | n | Median | p99 | Max | Missed deadlines | Playing windows with in-flight holds | Presented/s median, holding / clean windows | Crit. 6 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 5994 on-1 (`:865327`) | 8.3417 | 409199 | 8.35 | 8.36 | 16.70 | **77** | **267 of 357 (74.8 %)** | 56.1 / 59.9 | PASS |
| 2 | 2398 on (`:358280`) | 13.9028 | 245516 | 13.91 | 13.92 | 27.81 | 6 | 0 of 357 | — / 24.0 | PASS |
| 3 | gop25 on (`:372782`) | 13.3333 | 256201 | 13.34 | 13.36 | 26.68 | 8 | 0 of 357 | — / 25.0 | PASS |
| 4 | 5994 off (`:865163`) | 8.3417 | 409208 | 8.35 | 8.36 | 25.03 | **77** | **276 of 357 (77.3 %)** | 53.8 / 59.9 | PASS |
| 5 | 5994 on-2 (`:865337`) | 8.3417 | 409193 | 8.35 | 8.36 | 25.02 | **79** | **264 of 357 (73.9 %)** | 56.7 / 59.9 | PASS |

**`[PACER-PHASE]` on the on-blocks** (`run:` line):

| Block | \|x − x_ref\| p50 / p99 / max (ms) | n | Corrections applied (net) | Clamp hits | References set (guard) | Establishment nudges (net) | Guard event lines | Crit. 4 |
|---|---|---|---|---|---|---|---|---|
| 5994 on-1 (`:865326`) | 0.004 / **0.018** / 0.153 | 199929 | 143316 (+33.865 ms) | 69 | 136 (7) | 13 (+0.466 ms) | 13 | PASS |
| 2398 on (`:358279`) | 0.005 / **0.039** / 0.209 | 79331 | 58495 (+38.911 ms) | 77 | 132 (2) | 8 (+1.851 ms) | 8 | PASS |
| gop25 on (`:372781`) | 0.005 / **0.023** / 0.235 | 82881 | 57855 (+32.758 ms) | 108 | 120 (6) | 11 (+1.713 ms) | 11 | PASS |
| 5994 on-2 (`:865336`) | 0.004 / **0.017** / 0.476 | 199840 | 143222 (+33.348 ms) | 70 | 148 (16) | 16 (+0.741 ms) | 16 | PASS |

The nudge count in each `run:` line equals the number of `[PACER-PHASE] establishment guard` lines in that log.

### 16.3 The holds and skips, by cause

`ab-check.py` (`causes`, night 3's classifier unchanged) puts all 3 holds in `pacer`. There are 0 skips. No hold is a crossing, a
renderer stall, unclassified, or any other class. Read by hand, all 3 have the same shape: a **missed repeat tick** that served the
held present on its second call, with 1 present in flight, whose `CATransaction.commit` took 10–12 ms. The next new-frame tick then
ran 16.68 ms after the previous tick instead of 8.34 ms, and its frame reached the ring late.

| Block, time (~) | `[PRESENT-TIMING] miss` | Tick (ms) | Overran | Next interval (ms) | `[LATE-SWAP]` | Hold (`[CADENCE]`) |
|---|---|---|---|---|---|---|
| `n4-5994-sdi-on-1` 14:00:50 | `:429978`, repeat tick, tick's 2nd call presented (in flight 1) | 10.227 | `CATransaction.commit` 10.070 ms | 16.677 | `:429989` `class pacer … x 13.097 ms … held yes` | `:429971`, pts 41.141100 repeated |
| `n4-5994-sdi-on-1` 14:08:07 | `:533739`, the same | 10.509 | `CATransaction.commit` 10.362 ms | 16.681 | `:533742` `class pacer … x 16.171 ms … held yes` | `:533720`, pts 17.784433 repeated |
| `n4-5994-sdi-on-2` 18:09:53 | `:494050`, the same | 12.302 | `CATransaction.commit` 12.097 ms | 16.685 | `:494053` `class pacer … x 15.679 ms … held yes` | `:494031`, pts 23.556867 repeated |

- The 14:00:50 hold is 9 s after Regenerate 3's press at 14:00:41 (`soak.report` counts it under "around the press ±10 s:
  holds 1"). The other two are not near a Regenerate. Whether the Regenerate contributed is UNKNOWN. The tick has the same shape as
  the other two.
- **Off-block 4 had no hold at all**, so the gate's named exception (a crossing `held yes`) was not needed. Its 340 crossings and 36
  pacer late swaps held nothing.

### 16.4 Against the criteria

**C** (`RIG.md` C1–C8; on-blocks 1, 2, 3, 5):

| # | Criterion | Result |
|---|---|---|
| 1 | 0 crossing-caused holds or skips on each on-block | PASS: 0, 0, 0, 0 |
| 2 | Any cause except renderer stall and pacer: 0 | PASS: none. The 3 `pacer` holds are reported, not counted (§16.3) |
| 3 | Crossings ≤ 2 per on-block | PASS: 0, 0, 0, 0. Establishment nudges 13, 8, 11, 16 beside them |
| 4 | \|x − x_ref\| p99 ≤ 0.1 ms | PASS: 0.018, 0.039, 0.023, 0.017 |
| 5 | 0 freezes, 0 unrecovered, every block | PASS |
| 6 | Pacer median P ± 0.01, p99 ≤ P + 0.05, every block | PASS on all 5 |
| 7 | Switch off prints nothing (block 4) | PASS: 0 `[PACER-PHASE]` lines |
| 8 | Block 4 ≥ 5 crossings | Met: 340 |

**C: PASS.**

**G** (0.9.4 gate per block): blocks 1 and 5 **FAIL** (2 and 1 `pacer` holds), blocks 2, 3 and 4 PASS. Renderer recoveries +
near-misses: on-blocks 0, off-block 0. **G: FAIL.** As `RIG.md` states, G does not decide C.

**P** (completeness only): PASS on all 5. `miss` lines 77, 6, 8, 76, 78 match their `total` lines, with 0 dropped records in the 10 s
and `total` lines. **Complete.**

- The measurement's misses equal the pacer's on blocks 1–3 and are one fewer on blocks 4 and 5 (76 against 77, 78 against 79). Each of
  those two blocks has one tick that ended past two deadlines (next interval 25.03 and 24.97 ms, overran `perform`, §16.5). The pacer
  counts that as 2 missed deadlines, `(after − deadline) / step + 1` (`App/OutputPacer.swift:166-169`). The measurement writes one
  `miss` line per tick.

### 16.5 The present path (summary; full findings in `WINDOW_PRESENT_PATH.md` §5)

- **What overran on each missed tick** (`present.report`):

| Block | Misses | `CATransaction.commit` (min / median / max ms) | `waitUntilScheduled` | `perform` |
|---|---|---|---|---|
| 5994 on-1 | 77 | 74 (8.10 / 10.07 / 15.28) | 3 (6.6–7.0 ms) | 0 |
| 2398 on | 6 | 6 (13.78 / 14.05 / 14.98) | 0 | 0 |
| gop25 on | 8 | 8 (13.12 / 14.10 / 16.78) | 0 | 0 |
| 5994 off | 76 | 75 (8.10 / 10.32 / 16.06) | 0 | 1 (18.1 ms) |
| 5994 on-2 | 78 | 76 (8.21 / 10.11 / 15.35) | 1 (6.1 ms) | 1 (20.2 ms) |

- **Only repeat-tick misses reach the card.** A pacer late swap follows 31 of 32, 36 of 37 and 23 of 25 missed repeat ticks
  (blocks 1, 4, 5). In the other direction, 31 of 32, 36 of 36 and 23 of 24 pacer late swaps follow a missed tick within 40 log lines.
  The two that do not (`n4-5994-sdi-on-1.log:287799`, `n4-5994-sdi-on-2.log:728220`, the second just after a Pause) held nothing.
  New-frame-tick misses are 45, 39 and 53. They delay only the next tick, a repeat tick, which renders nothing.
- **The bad state appeared on all three 59.94 blocks** (74.8 %, 77.3 %, 73.9 % of playing windows; the measurement's own count 266,
  287, 275 of 379). It did not appear on 23.976 or 25 (0 of 357). By sixth of each block: on-1 59 80 81 62 80 87, off 61 82 69 82 85
  85, on-2 68 77 68 82 73 77.

### 16.6 What this shows (not part of the verdicts)

- **Option C with the establishment guard did what §14.4 claims, on every on-block, including 59.94.** There were 0 crossings on all
  four on-blocks, against 340 on the off-block of the same night. Night 3's on-block 59.94 had 4, all in one post-wrap reference
  window (§15.3). The guard moved ticks 8–16 times a block. The 0.5 ms move's effect on the window path, §14.4's open risk, is not
  separable tonight: the on-blocks and the off-block are in the same degraded state at the same share.
- **G fails for the reason §15.5 left open, not because of option C.** All 3 holds are missed pacer ticks in the degraded 59.94 state,
  each caused by a `CATransaction.commit` block on a repeat tick.
- **A count to watch, with no mechanism shown:** over nights 3 and 4, pacer late swaps were held on the on-blocks 8 times in 92 (5/36,
  2/32, 1/24), and on the off-blocks 0 times in 77 (0/41, 0/36). If held and not-held swaps were equally likely on both sides, all 8
  falling on-side has a one-sided probability of about 0.007. Their `x` and `baseline` values overlap the not-held ones' ranges
  (held x 11.5–16.2 ms against 7.4–16.4 ms), so nothing logged separates them. UNKNOWN. Do not read it as an effect of option C
  without a mechanism. **Resolved in §17.2:** the lead separates them completely, C does not shift the lead, and the 8 / 0 is where
  the misses landed.
- **Clamp hits fell** from night 3's 230, 1026 and 227 (§15.2) to 77, 108, 69 and 70. Why is UNKNOWN (inference: the guard removes the
  post-wrap walks to x_ref at the clamp that §15.3 describes).
- **The rig question (`WINDOW_PRESENT_PATH.md` §2.3, §4.4) is answered for this night: the state did not build up.** Block 1, with 0
  denied prompts and 0 earlier launches tonight, was already degraded (74.8 %, 59 % in its first sixth). Block 5, after 8 denials
  and 4 launches, was degraded about the same (73.9 %). Launches before `soak.sh` are UNKNOWN (§16.1).
- **Open:**
  - The present path: see `WINDOW_PRESENT_PATH.md` §5.6.
  - Option C's verdict stands on this night. Whether to commit or ship it is a decision for Robbie; this section does not make it.
  - The G failures need the present-path fix, not a change to option C.

---

## 17. Why held pacer late swaps fell on the on-blocks, and a lead-maximizing x_ref ("C+") (analysis 2026-11-18; nothing built)

Read-only. No build, no launch, no git. Logs: night 3 `~/Code/_scratch/manifold-pacerphase-ab/` (`ab-*`) and night 4
`~/Code/_scratch/manifold-pacerphase-ab3/` (`n4-*`), the 11 matched-rate output blocks. The scripts (`lead.py` and the follow-ups) are in
the session scratchpad and are not kept. Code lines are at HEAD `b752fac`.

**Method.**
- **Lead:** §0 and §2.4's definition, pull host minus the publish host of the handed frame. It is read from each `[PULLPHASE] pull`
  line's `lead` field, which is computed exactly that way (`App/CardPullPhaseLog.swift:203-205`).
- **Segment:** §0's rule. A run of timed pulls, ended by an untimed pull (Pause, seek, wrap), of at least 100 pulls. The first 50 and
  the last 15 are dropped. Each block gives 105 segments.
- **Exposed segment:** the median lead is under P and the card is on the window's newest frame (median `behind` 0). This is §2.4's
  method. `[PULLPHASE] summary`'s per-pull `exposed` count uses the same test per pull (`CardPullPhaseLog.swift:227`).
- **x:** each `[TICKPHASE]` line's tick − due, joined by host.
- **A:** the slot clock minus the handed pts, read from the pull line as `target + margin − handed`. The target is
  `clock − (host − slotHost) − margin` (`App/MetalVideoRenderer.swift:6200`), so A is where the card's slot sits on the frame grid,
  measured from the frame it takes.

### 17.1 Lead and exposure, per block and per rate: option C does not shift them

| Rate | Block | C | Exposed segments | Card a frame behind | Segment lead q10 / q50 / q90 (ms) | Exposed pulls | Segment x q10 / q50 / q90 (ms) |
|---|---|---|---|---|---|---|---|
| 23.976 (P 13.90) | `ab-2398-cmp-off` | off | 21 / 105 (20 %) | 12 | 6.51 / 25.89 / 42.37 | 19.9 % | 2.00 / 9.59 / 11.95 |
| | `ab-2398-cmp-on` | on | 26 (25 %) | 21 | 8.30 / 27.52 / 44.88 | 24.9 % | 0.51 / 9.11 / 12.18 |
| | `n4-2398-cmp-on` | on | 25 (24 %) | 12 | 8.50 / 25.05 / 45.01 | 23.8 % | 0.85 / 8.49 / 11.81 |
| 25 (P 13.33) | `ab-gop25-sdi-off` | off | 20 (19 %) | 15 | 9.76 / 23.53 / 43.20 | 18.6 % | 0.50 / 4.57 / 10.73 |
| | `ab-gop25-sdi-on` | on | 16 (15 %) | 14 | 10.85 / 28.61 / 41.36 | 15.3 % | 0.68 / 4.05 / 10.91 |
| | `n4-gop25-sdi-on` | on | 18 (17 %) | 15 | 8.29 / 25.91 / 42.04 | 17.1 % | 0.63 / 4.34 / 10.55 |
| 59.94 (P 8.34) | `ab-5994-sdi-off` | off | 8 (8 %) | 49 | 8.55 / 16.19 / 22.93 | 7.8 % | 0.93 / 4.79 / 7.65 |
| | `n4-5994-sdi-off` | off | 9 (9 %) | 47 | 8.39 / 16.20 / 22.85 | 8.1 % | 0.97 / 5.44 / 7.66 |
| | `ab-5994-sdi-on` | on | 6 (6 %) | 43 | 8.79 / 14.73 / 22.43 | 4.8 % | 0.90 / 4.97 / 7.67 |
| | `n4-5994-sdi-on-1` | on | 7 (7 %) | 45 | 9.31 / 15.47 / 22.30 | 5.6 % | 1.18 / 5.14 / 7.51 |
| | `n4-5994-sdi-on-2` | on | 4 (4 %) | 43 | 9.74 / 15.17 / 22.04 | 3.9 % | 0.87 / 4.60 / 7.71 |

Pooled per rate, off against on (two-sample Kolmogorov–Smirnov over segment median leads and segment median x):

| Rate | Exposed off / on | Lead: D, p | x: D, p | Median lead off / on (ms) | Median x off / on (ms) |
|---|---|---|---|---|---|
| 23.976 | 21 / 105 (20.0 %) against 51 / 210 (24.3 %) | 0.138, 0.13 | 0.143, 0.11 | 25.89 / 25.42 | 9.59 / 8.65 |
| 25 | 20 / 105 (19.0 %) against 34 / 210 (16.2 %) | 0.133, 0.15 | 0.105, 0.41 | 23.53 / 26.97 | 4.57 / 4.26 |
| 59.94 | 17 / 210 (8.1 %) against 17 / 315 (5.4 %) | 0.067, 0.62 | 0.079, 0.39 | 16.20 / 15.41 | 5.08 / 4.81 |

- **C does not shift the lead distribution or the exposure at any rate.** No difference reaches p < 0.1. At 59.94, the rate where every
  held pacer swap was, the on-blocks were *less* exposed (5.4 % against 8.1 % of segments; 3.9–5.6 % against 7.8–8.1 % of pulls).
  CONFIRMED by these counts.
- **Neither the guard nor x_ref's median moves the lead in bulk.** The guard shows only as x's q10: 0.51–0.85 ms on the 23.976 on-blocks,
  against 2.00 off (a phase near 0 raised to 0.5 ms). That narrows the lead by at most 0.5 ms in those Plays. x's median is unchanged:
  C holds x where Play put it, as §7 C intended.
- **The lead is fixed by A and x** (17.3). Per segment with the card on the newest frame, lead = A − x − c, where c is 0.74–0.76 ms at
  59.94, 0.82–0.83 at 23.976 and 0.92–0.94 at 25: the tick → ring time. The spread q05–q95 is within 0.1 ms at 23.976 and 25, and within
  0.45 ms at 59.94. CONFIRMED on all 11 blocks. A modelled lead (A − x − c < P) reproduces the measured exposed segments exactly at
  23.976 and 25 (21, 26, 25; 20, 16, 18), and within 3 segments at 59.94.

### 17.2 Every pacer late swap against its own lead

For each `[LATE-SWAP] class pacer` the lead was read as the median over the 20 timed pulls before that frame's tick. The last pull
before the tick cannot be used. For a held swap it is the repeat pull itself, whose lead is that of the frame before, about F + lead
(22–24 ms in all 8). All 169 are at 59.94: 92 on-blocks (36 + 32 + 24), 77 off-blocks (41 + 36).

| | Lead < P | Lead ≥ P |
|---|---|---|
| On-blocks: held | **8** (lead 5.01, 5.55, 5.84, 6.39, 6.41, 6.51, 7.03, 7.89 ms) | **0** |
| On-blocks: not held | **0** | **84** (lowest 8.57, 8.63, 8.72 ms) |
| Off-blocks: held | 0 | 0 |
| Off-blocks: not held | **2** (8.322 and 8.323 ms, both `n4-5994-sdi-off`) | 75 (next lowest 8.80 ms) |

- **Lead < P explains held against not held completely on the on-blocks**, with a gap: 7.89 ms held, 8.57 ms not held. CONFIRMED.
- **The off-blocks' two exceptions are 0.02 ms under P** (P 8.3417 ms), inside the slot clock's ~0.4 ms wobble (`:6218`). The swap's
  own delay over its baseline was 8.02 and 8.37 ms. d over the 169 pacer swaps: median 8.09, q90 8.46, q99 8.88, max 9.89 ms.
  Inference: not exposed in fact.
- **The 8 held swaps** (block, pts, lead): `ab-5994-sdi-on` 1427.993233 7.89, 586.469217 6.41, 631.914617 6.39, 662.645317 5.55,
  5.071733 7.03; `n4-5994-sdi-on-1` 41.157783 5.84, 17.801117 6.51; `n4-5994-sdi-on-2` 23.573550 5.01.
- **So the 8 / 92 against 0 / 77 is about where the misses landed, not about C changing what a miss does.**
  - On-blocks: 5.3 % of steady pulls were in exposed segments, and 9 of 91 joinable misses fell there. 4.9 were expected if misses are
    spread evenly over time.
  - Off-blocks: 7.1 % of steady pulls were exposed, and 2 of 77 misses fell there (the two at 8.32 ms). 5.5 were expected.
  - Conditional on 11 misses in exposed segments, the chance of 9 or more on the on side is 0.021 (binomial, p = 0.47).
  - The misses come in clusters (1.3 s to 5 min apart, §16.5; two exposed on-segments took 2 each), so the independent count overstates
    that. The mechanism that would put misses preferentially into exposed segments under C is UNKNOWN; none is known. Inference:
    chance, with §16.6's 0.007 overstated because it treated held as a coin flip, when lead decides it.

### 17.3 C+: choose x_ref to maximize the lead

**What the pull does** (`deckLinkPullSlotLocked`, `:6156-6235`). At a timed pull at a matched rate, the frame after the one handed last
is taken when it is in the ring and `pts ≤ target + band` (`:6229`), with target = slot clock − margin (`:6200`). The margin is the median
tick interval + 10 ms (`:5641`). The band is F/2 (`:6210`). So frame N is taken at the first pull that is both after its publish and at
least G = margin − band after its pts:
- 59.94: G = 18.34 − 8.34 = 10.00 ms;
- 23.976: G = 23.90 − 20.85 = 3.05 ms;
- 25: G = 23.33 − 20.00 = 3.33 ms.

Measured A is never below G: minimum 10.12, 3.42, 6.93 ms. Under card lock the slot clock advances exactly one frame per slot (§1.1),
so A is fixed for a Play, apart from the slot clock's wobble. A has two stable states:
- [G, G + F): the card is on the newest frame;
- about [G + F, G + 3F/2): the card is a frame behind. The anti-skip branch (`:6230`) keeps it there.

**Lead = A − x − c**, CONFIRMED (17.1). Moving x earlier (smaller) moves the swap earlier by the same amount. The pull that takes the
frame does not change, because the pull one frame earlier is at A − F < G and is not eligible. So moving x earlier lengthens the lead by
the same amount and changes nothing on the card. Moving x later past A − c makes the frame miss its pull: it is then taken one
pull later, with the card one frame further behind.

**At 59.94 every Play can be made unexposed.** x + c ≤ P − 0.5 + 0.75 < G, so the near pull is always the one that takes the frame, and
lead = A − x − c ≥ G − x − c. With x ≤ A − c − P − s_L, the lead is at least P + s_L. That is feasible while x stays inside the guard
band [s_x, P − s_x] whenever A ≥ P + c + s_L + s_x. In the worst Play (A = G = 10.00 ms) the two margins share G − P − c = 0.91 ms. With
s_x = 0.5 ms (the guard) the worst Play keeps a lead slack of 0.41 ms, and every Play with A ≥ 10.09 ms keeps s_L = 0.5 ms. That s_L
covers the measured delay of a one-tick-late swap at q99 (8.88 ms, against P + 0.5 = 8.84).

**At 23.976 and 25 (k = 3) it helps less.** When A < P + c + s_L + s_x (about 15.5 ms at 23.976; A starts at 3.05), moving earlier cannot
reach the slack. The only cure for those Plays is to move x later, so that the swap lands after the near pull, and the card takes the
frame one pull later.

**Counterfactual, from each segment's measured A, x and c** (s_x 0.5 ms, s_L 0.25 ms; "high" needs the swap ≥ 0.5 ms after the pull):

| Rate | Segments | Exposed today | C+ (move earlier only) | C+ with the later move too | Plays moved one pull later (card +1 frame) |
|---|---|---|---|---|---|
| 23.976 | 315 | 72 (22.9 %) | 28 (8.9 %) | 6 (1.9 %) | 22 (7.0 %) |
| 25 | 315 | 54 (17.1 %) | 34 (10.8 %) | 9 (2.9 %) | 25 (7.9 %) |
| 59.94 | 525 | 34 (6.5 %) | **0** (worst lead slack +0.25 ms) | 0 | 0 |

Applied to the held swaps: all 8 were in segments that C+ (earlier only) makes unexposed at 59.94. Inference: under C+ none of night 3
and night 4's 8 pacer holds would have held, because each delay (7.95–8.54 ms) is under P + s_L. Untested.

**Is the pull phase known to the pacer at Play? No.**
- The pacer gets only `PacerPhaseSample` x, through `takePacerPhaseSample` (`:3485-3489`) and `pacerPhaseSampleNow` (`:3496-3503`).
- The slot timeline is in the renderer: `deckLinkSlotOffsets` (`:478`), `slotHost` (`:6177`) and the target (`:6200`). They are written
  on the SDK's fill thread under the DeckLink lock, from the first timed pull after Play. That is within one card frame of Play, and
  well before the 8th new-frame tick that sets x_ref (133 ms at 59.94, 333 ms at 23.976): about 8 pulls by then.
- The lead itself is computed only in the DEBUG log (`CardPullPhaseLog.swift:205`). It uses ring publish hosts that are recorded only
  while `CardPullPhaseLog.enabled` (`deckLinkSlotPublishHostDbg`, `:519`, `:5815`, `:5949`).
- So C+ needs one new read: the handed frame's lead (or A) from the pull, passed to the pacer thread.

**The change (C+; `MANIFOLD_PACER_PHASE=2`, DEBUG; `=1` stays C exactly):**
1. **Record** the ring publish host whenever the phase switch is on, not only with the card-pull log (`:5815`, `:5949`). At each timed
   pull where the handed frame advanced by one, store its lead and `behind` in a small ring under the DeckLink lock
   (`deckLinkPullSlotLocked`'s caller, not the selection itself, which stays unedited as in §11.5).
2. **At reference set** (`PacerPhaseFollower.tick`, `OutputPacing.swift:340-351`), the follower takes L, the median lead of this Play's
   pulls so far with `behind` 0 (if `behind` ≥ 1, do nothing: that state is not exposed). The renderer hands it over beside x in the
   sample. If L < P + s_L:
   x_ref' = max(s_x, x_ref − (P + s_L − L)).
   This is a pure function, `PacerPhase.leadReference(xRef:lead:period:)`, unit-tested like `reference(firstTicks:period:)`.
3. **Move there** in steps of at most 0.5 ms a tick. That is the establishment guard's step, already run 8–16 times a block on night 4
   (§16.2). The largest move is P − 1 ms, so at most 15 ticks (125 ms at 59.94). Then the follow holds x at x_ref' as today.
4. **Re-check every 10 s window.** If L has fallen under P + s_L (unlocked clock, or a slow walk), move earlier again within the band.
   Moves only go earlier and never leave [s_x, P − s_x].
5. **Log:** `[PACER-PHASE] lead guard · lead … ms < P + s_L · x_ref … → … ms`, and `lead moves N (net …)` on the 10 s and `run:` lines.
6. **The later move** (k = 3, card +1 frame in about 7–8 % of Plays) is **not** in this change. It alters the card's latency against the
   clock per Play, which is Robbie's decision (I1).

**Does C+ keep the guard's no-crossing property? Yes, by construction.**
- x_ref' lies in [s_x, x_ref], inside [0.5, P − 0.5].
- A move from x_ref to x_ref' goes earlier within the band and never passes 0 or P, which is the due time. CONFIRMED by the arithmetic.
- The follow's |x − x_ref| p99 was 0.017–0.039 ms on night 4, max 0.153–0.476 ms (§16.2). So at x_ref' = 0.5 ms the worst observed
  excursion leaves 24 µs. That happens only in Plays with A within 0.4 ms of G, about 2–3 % at 59.94.

**Risks.**
- **Window timing:** the window shows each frame up to P − 1 ms sooner after its due time in the moved Plays: ≤ 7.3 ms at 59.94,
  ≤ 12.9 ms at k = 3. That is inside today's per-Play spread (x uniform in [0, P)), but biased early. At Computer, the window picture
  against the Mac sound shifts by the same, within today's spread (I1).
- **Card, SDI audio, Stage 2, slips:** unchanged for the earlier-only move. The handed frame is the same, because A does not change.
- **The pull margin:** a 15-tick ramp moves the median tick interval by nothing.
- **Hot path:** one store per publish when the switch is on.
- **c varies per frame** (tick → ring, max 1.6–3.3 ms, §5.1). A frame whose render is slow uses up the slack, but that is a `render`
  late swap, a different class.
- **No effect on the present path.** C+ removes the exposure that turns a miss into a hold. It does nothing about the misses
  (`WINDOW_PRESENT_PATH.md` §4).

**Test** (criteria to be written before the night, `ab-check.py` extended):
- 59.94 blocks with `=2`: the summary's `exposed` is 0 in every segment; steady-pull lead p01 ≥ P + 0.25 ms; 0 crossings; |x − x_ref|
  p99 ≤ 0.1 ms; lead-guard lines present; and **0 held pacer late swaps** while misses still occur (if the present-path fix is off,
  night 4's rate of about 30 a block gives the test its events).
- One 23.976 Computer block with `=2`: exposed segments ≤ 12 % (against 20–25 % today).
- Nights 3 and 4's on-blocks stand as the C comparator. Exposure is set by A's distribution, which was stable across those nights
  (17.1).

---

## 18. A/B night 5 (C+ and option B, run 2026-11-18/19): C+ **FAIL** (one hold, a two-period stall), B **PASS**, G **FAIL**, D **PASS**, P complete

Started by hand (`soak.sh main > soak.out 2>&1`). The slots were set at 21:10:37. The first block began at 21:21:09, after the 10 min idle
wait, and the last ended at 02:01:26. `ENDED` was written at 02:01 and there is no `STOP` file. All 6 blocks ran to the end (`"ended":
"done"` in every `<label>.json`; `block … exit 0` in `soak.out`), and none was skipped. Analysed 2026-11-19 with `ab-check.py` against
`RIG.md`'s criteria, which were written before the run. Re-run in this session, `ab-check.py`'s output is byte-identical to the night's
`ab.report`. The re-run also rewrote the night's `present.report` in place: unlike §16, no symlinks were used. The script writes that
file from the logs alone, and the new file has the original's size (25,781 bytes). Paths below are relative to
`~/Code/_scratch/manifold-pacerphase-ab4/`. Host times are converted to wall times with one offset per night: the median of
(wall − host) over the night's Regenerate presses (`<label>.json` `regens`, 24 anchors, spread 2.45 s), so about ±2 s. No build, no
launch, no git.

**Candidate** (`RIG.md`): `.build-pacerphase-4`, Profile, 0.9.4 (27), HEAD `b752fac` plus C+ (`MANIFOLD_PACER_PHASE=2`), option B
(`MANIFOLD_PACER_PRESENT_TX=0`) and the production `PlaybackCounters`, uncommitted at the time. HEAD is now `7de17c5`, whose subject
describes the same changes. Whether its tree equals the candidate was not checked, since no git was run in this session. sha256
`926c1efa…`, ad-hoc linker-signed. Every block had `MANIFOLD_PACER_PHASE=2`, `MANIFOLD_DECKLINK_CADENCE_LOG=2` and
`MANIFOLD_PRESENT_TIMING=1`, and the B-on blocks also had `MANIFOLD_PACER_PRESENT_TX=0` (`ab.report:1-7`, from each `<label>.json`
`extra_env`). Each block ran 45 min (16 cycles of 175 s).

**Verdicts (`ab.report`):**
- **C+: FAIL** (`:32`). Criteria 1, 2a and 3 passed on every block that has them. Criterion 2 failed on block 1: 1 hold and 1 skip, both
  `pacer (no [LATE-SWAP])` (`:28`). That pair is one missed pacer tick whose `CATransaction.commit` blocked for 16.8 ms, two periods. The
  pacer dropped the frame due at that tick, so no lead could have covered it (§18.3). Block 3 passed criterion 2 with 68 missed deadlines
  and 29 pacer late swaps, 0 of them held (`:30`).
- **B: PASS** (`:49`). Pacer missed deadlines were 0, 1 and 1 on the three B-on blocks, against 70 and 68 on the B-off ASUS blocks.
  There were 0 pacer late swaps, and 0 presents went through `CATransaction.commit`. Present-path findings are in
  `WINDOW_PRESENT_PATH.md` §6.
- **G: FAIL** (`:60`), on block 1 only (the C+ pair above). Blocks 2–6 passed, and there were 0 freezes on every block.
- **D: PASS** (`:68`). On all 6 blocks, the `[DIAG] playback counters` line agrees exactly with the log.
- **P: complete on all 6** (`:82-88`).
- **The LG block** (reported, not judged): the bad state did not appear (0 of 272 playing windows). There were 7 missed deadlines, and
  1 tick overran in `CATransaction.commit` (`:51`).

### 18.1 Rig

- **Checked before every block: passed 6 of 6.** `rig.log` has one entry per block, 21:21:08 to 01:14:45, and `soak.out` has them at
  `:4`, `:27`, `:50`, `:73`, `:96` and `:119`. Each entry shows zoom.us none, capture closed, default output Scarlett, sha256
  `926c1efa25aa8f15…` ok, slots `waveform | parade | markers`, and signing `flags=0x20002(adhoc,linker-signed)`, `TeamIdentifier=not set`.
- **Display placement, per block: as planned.**

| # | Block | `RC_PLACE` / `RC_EXPECT_DISPLAY` (rig entry) | Window display at output start (`soak.out`) | `<label>.json` |
|---|---|---|---|---|
| 1 | `n5-5994-sdi-boff-1` | ASUS / ASUS PA147 at 59.936 Hz | `:11` ASUS PA147 at 59.936 Hz (window moved) | ASUS PA147, 59.936 |
| 2 | `n5-5994-sdi-bon-1` | the same | `:34` the same | the same |
| 3 | `n5-5994-sdi-boff-2` | the same | `:57` the same | the same |
| 4 | `n5-5994-sdi-bon-2` | the same | `:80` the same | the same |
| 5 | `n5-2398-cmp-bon` | the same | `:103` the same | the same |
| 6 | `n5-5994-sdi-lg-boff` | LG / LG TV SSCR2 at 120 Hz | `:126` LG TV SSCR2 at 120.000 Hz (window shown) | LG TV SSCR2, 120.000 |

- **Display modes, logged before every block** (`common.sh:24` prints `Resolution` · `UI Looks like`):
  - LG TV SSCR2: `3840 x 2160` · `3840 x 2160 @ 120.00Hz`. The "looks like" mode equals the resolution, so the LG ran at **120 Hz,
    unscaled**, on all 6 entries. CONFIRMED.
  - ASUS PA147: `1920 x 550` · `1920 x 550 @ 60.00Hz` (measured by the window at 59.936 Hz).
- **HID idle at each block start** (`soak.out` `:3`, `:26`, `:49`, `:72`, `:95`, `:118`): 611, 3415, 6217, 9021, 11824 and 14626 s. So the Mac
  was not touched during the night. Resolve was closed each time.
- **Guards:** "guard after …: clean" for all 6 blocks (`soak.out` `:23`, `:46`, `:69`, `:92`, `:115`, `:138`).
- **Slots restored: yes.**
  - `setslots` (21:10:37, `soak.out:1`): "slots set: waveform | parade | markers; were yrgb | meters | markers", stash
    `prefs-stash-20261118-211037.txt`.
  - At exit (02:01:41, `:170-171`): "slots at the end of the night: waveform | parade | markers", then "slots restored: yrgb | meters |
    markers".
  - Read again in this session, `com.graviton.manifold` `manifold.scope.slot0/1/2` are `yrgb | meters | markers`, which is exactly the
    stash.
- **Recorded, never stopping the night** (`rig.log`):

| # | Block | Keychain prompts denied tonight before it (earlier launches) | Denied in it | SecurityAgent before | Memory free before / after | `ASEProcessing` per minute (end − 6 to end − 1 min) | Thermal |
|---|---|---|---|---|---|---|---|
| 1 | `boff-1` | 0 (0) | 2 | 0 | 88 % / 87 % | 3280 | no warning recorded |
| 2 | `bon-1` | 2 (1) | 2 | 0 | 87 % / 87 % | 3281 | the same |
| 3 | `boff-2` | 4 (2) | 2 | 0 | 87 % / 87 % | 3282 | the same |
| 4 | `bon-2` | 6 (3) | 2 | 0 | 87 % / 87 % | 3282 | the same |
| 5 | `2398-cmp-bon` | 8 (4) | 2 | 0 | 87 % / 87 % | 2490 | the same |
| 6 | `lg-boff` | 10 (5) | 2 | 0 | 87 % / 87 % | **26** | the same |

- With the window on the LG, WindowServer logged 26 `ASEProcessing` lines a minute, against 3280 with the same file on the ASUS. See
  `WINDOW_PRESENT_PATH.md` §6.4.
- **Not covered:** launches and prompts before `soak.sh` started are UNKNOWN. `soak.out`'s first line is the `setslots` line, and it
  carries no note.

### 18.2 Per block

Holds and skips are the gate's counts (`soak.report`). Late swaps are `[LATE-SWAP]` by class, as `ab-check.py` counts them (`ab.report:1-7`).

| # | Block | B | Pacer n / median / p99 / max (ms) | Missed deadlines | `[LATE-SWAP]` (held) | Holds / skips | Freezes | Renderer recov. / near-miss | Window late / dropped | Card late / dropped | Markers |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `n5-5994-sdi-boff-1` | off | 311770 / 8.35 / 8.36 / 33.35 | **70** | pacer 26 (0) | **1 / 1** | 0 | 0 / 0 | 12 / 11 | 0 / 0 | PASS |
| 2 | `n5-5994-sdi-bon-1` | on | 311826 / 8.35 / 8.36 / 8.73 | **0** | none | 0 / 0 | 0 | 0 / 0 | 11 / 4 | 0 / 0 | PASS |
| 3 | `n5-5994-sdi-boff-2` | off | 311778 / 8.35 / 8.36 / 25.03 | **68** | pacer 29 (0) | 0 / 0 | 0 | 0 / 0 | 8 / 9 | 0 / 0 | PASS |
| 4 | `n5-5994-sdi-bon-2` | on | 311829 / 8.35 / 8.36 / 16.68 | **1** | none | 0 / 0 | 0 | 0 / 0 | 8 / 6 | 0 / 0 | PASS |
| 5 | `n5-2398-cmp-bon` | on | 187093 / 13.91 / 13.92 / 27.80 | **1** | none | 0 / 0 | 0 | 0 / 0 | 8 / 5 | 0 / 0 | PASS |
| 6 | `n5-5994-sdi-lg-boff` | off | 311832 / 8.35 / 8.36 / 25.03 | **7** | none | 0 / 0 | 0 | 0 / 0 | 12 / 4 | 0 / 0 | PASS |

There were 0 crossings on every block. Markers: 24 Regenerates, all 120 thumbnails remade, 0 made while playing (`soak.out:143`).
Recorded and not judged: `edge APPENDED by the card` lines 16, 11, 1, 9, 0 and 7 (`soak.report`, "SDI bridge").

**The pacer's count against the measurement's `miss` lines** (70/67, 0/0, 68/66, 1/1, 1/1, 7/5). The difference is fully accounted for
by ticks that ended past more than one deadline. The pacer counts `(after − deadline) / step + 1` (`App/OutputPacer.swift:177-179`), so
a next interval of 3P counts 2 and 4P counts 3. Block 1 has one at 25.04 ms and one at 33.35 ms (+1, +2). Block 3 has two at 25.02
and 25.03 ms, and block 6 two at 25.02 and 25.03 ms (+1 each). CONFIRMED from `present.report`.

**`[PACER-PHASE]` (`run:` line; lead guard from `[PACER-PHASE] lead guard` lines):**

| Block | \|x − x_ref\| p50 / p99 / max (ms) | Corrections applied (net) | Clamp hits | References set (guard) | Establishment nudges (net) | Lead moves (net) | Lead-guard lines (at band edge) |
|---|---|---|---|---|---|---|---|
| boff-1 | 0.004 / **0.017** / 0.565 | 111248 (+25.434 ms) | 58 | 111 (11) | 9 (+0.922 ms) | 69 (−28.052 ms) | 19 (0) |
| bon-1 | 0.004 / **0.016** / 7.011 | 110928 (+26.015 ms) | 34 | 120 (5) | 7 (+1.039 ms) | 38 (−16.734 ms) | 8 (0) |
| boff-2 | 0.004 / **0.037** / 0.958 | 112135 (+25.997 ms) | **782** | 107 (8) | 12 (−1.698 ms) | 42 (−19.757 ms) | 9 (1) |
| bon-2 | 0.004 / **0.034** / 0.161 | 112205 (+25.908 ms) | 329 | 100 (4) | 9 (+0.025 ms) | 58 (−25.499 ms) | 17 (0) |
| 2398-cmp-bon | 0.005 / **0.046** / 0.144 | 45055 (+30.064 ms) | 126 | 90 (3) | 9 (−1.153 ms) | 222 (−105.126 ms) | 21 (**11**) |
| lg-boff | 0.004 / **0.019** / 0.174 | 111298 (+25.640 ms) | 143 | 110 (9) | 13 (−0.076 ms) | 50 (−21.909 ms) | 10 (0) |

- **bon-1's max of 7.011 ms** is one tick in one 10 s window (`n5-5994-sdi-bon-1.log:201806`, that window's p99 0.030 ms). Its cause
  is UNKNOWN. No hold or skip came of it.
- **boff-2's 782 clamp hits** came almost entirely from five 10 s windows within one stretch of the block (`:504533` to `:518977`), and
  246 of its 10 s windows had 0. Why is UNKNOWN.

**Lead and exposure** (§17's method; steady segments from `ab-check.py` `night5`):

| Block | P (ms) | Steady segments | Exposed segments | Exposed steady pulls | Newest-frame lead p01 (ms) | §17.3's target p01 ≥ P + 0.25 |
|---|---|---|---|---|---|---|
| boff-1 | 8.3417 | 80 | **0** | 568 of 148143 (0.38 %) | 8.535 | 8.59: under by 0.06 |
| bon-1 | 8.3417 | 80 | **0** | 327 of 148142 (0.22 %) | 8.676 | met |
| boff-2 | 8.3417 | 80 | **0** | 409 of 148145 (0.28 %) | 8.743 | met |
| bon-2 | 8.3417 | 80 | **0** | 509 of 148146 (0.34 %) | 8.499 | under by 0.09 |
| lg-boff | 8.3417 | 80 | **0** | 346 of 148141 (0.23 %) | 8.526 | under by 0.07 |
| 2398-cmp-bon | 13.9028 | 80 | **9 (11.3 %)** | 6090 of 56120 (10.9 %) | 2.897 | — |

- **At 59.94, C+ did what §17.3 predicted for segments: 0 of 400 exposed**, against 4–9 % on nights 3 and 4 (§17.1). Exposed steady pulls
  fell from 3.9–8.1 % (§17.1) to 0.22–0.38 %. A segment's median lead is above P, but 1 pull in 300–450 still falls under it. Inference:
  the slot clock's ~0.4 ms wobble (§17.2), against a lead held 0.5 ms or less above P.
- **§17.3's per-pull target (p01 ≥ P + 0.25 ms) was missed by 0.06–0.09 ms on 3 of the 5 59.94 blocks.** It is not one of `RIG.md`'s
  criteria, which judge segments (2a), so this is reported, not judged.
- **At 23.976, exposure fell to 11.3 % of segments**, under §17.3's ≤ 12 % and against 20–25 % on nights 3 and 4. 11 of the 21 lead-guard
  lines stopped at the band's edge, which is §17.3's k = 3 limit: moving earlier cannot reach the slack in Plays with small A.

### 18.3 The hold and the skip (block 1)

| | Log | What it shows |
|---|---|---|
| Steady play before | `[PULLPHASE] pull #47044`–`#47059` | `newest`, lead 9.12–9.77 ms (P 8.34), so above P by about 0.8–1.4 ms, as C+ intends |
| The missed tick | `present.report` (`n5-5994-sdi-boff-1.log:185976`), host 430921.5596 | repeat tick, tick's 2nd call presented (in flight 1), tick 16.910 ms, **overran `CATransaction.commit` 16.799 ms**, next interval 25.039 ms (3P) |
| The frame due next | `[TICKPHASE]` | pts 790.856733 at host …551272, then **790.890100** at …584660 (interval 25.039 ms, prev-tick 16.910 ms). **No tick rendered 790.873417** |
| Hold | `[PULLPHASE] pull #47060` (host …578034), `[CADENCE] #47060` | `branch held`, handed 790.856733 again (`soak.report:4`, 21:34:29) |
| Skip | `[PULLPHASE] pull #47061`, `[CADENCE] #47061` | handed 790.890100: 790.856733 → 790.890100, frames +2 (`soak.report:5`) |

- **The mechanism is not the one C+ addresses.** C+ lengthens the lead so that a swap **one** period late still lands before the pull
  (§17.3). Here the commit blocked for two periods. The pacer skips a missed deadline rather than catching up (`App/OutputPacer.swift:16`),
  so frame 790.873417 was never rendered. With no frame in the ring, the card had to repeat and then jump, whatever the lead.
  `ab-check.py` classifies it as `pacer (no [LATE-SWAP])` because no swap happened that could be late. CONFIRMED from the lines above.
- **The 55 one-period pacer late swaps on blocks 1 and 3 held nothing** (26 + 29, held 0; `ab.report:28`, `:30`). On nights 3 and 4 the
  on-blocks held 8 of 92 (§17.2). Inference: the part of C+ that §17.3 predicts worked. The remaining failure needs the present-path
  fix.
- **Of the 4 multi-period ticks on the B-off ASUS blocks, only this one held.** It is the only one on a repeat tick. The other three
  (block 1 33.35 ms, block 3 25.02 and 25.03 ms) were new-frame ticks. They delayed only the following repeat tick, as night 4 found
  for new-frame misses (`WINDOW_PRESENT_PATH.md` §5.3). The hold is not near a Regenerate (regen 1 at 21:31:25, `soak.out`) or a CCC
  run (§18.6).

### 18.4 Against the criteria

**C+** (`RIG.md`, every block; criterion 2 on the B-off ASUS blocks 1 and 3):

| # | Criterion | Result |
|---|---|---|
| 1 | 0 crossing-caused holds or skips, every block | PASS: 0 on all 6 (0 crossings) |
| 2 | Blocks 1, 3: 0 pacer-caused holds or skips (with misses) | **FAIL on block 1**: 2 (1 hold, 1 skip; 70 missed deadlines, 26 pacer late swaps, 0 held). PASS on block 3: 0 (68 missed, 29 pacer late swaps, 0 held). Tested on both, not UNTESTED |
| 2a | Blocks 1, 3: 0 exposed steady segments at 59.94 | PASS: 0 of 80, 0 of 80 |
| 3 | \|x − x_ref\| p99 ≤ 0.1 ms, every block | PASS: 0.017, 0.016, 0.037, 0.034, 0.046, 0.019 |

**C+: FAIL**, as the criteria were written. §18.3 shows the failing pair is a two-period present stall, which no lead can cover.

**B** (B-on blocks 2, 4, 5):

| # | Criterion | Block 2 | Block 4 | Block 5 |
|---|---|---|---|---|
| 1 | Missed deadlines ≤ 2 | PASS: 0 | PASS: 1 | PASS: 1 |
| 2 | 0 pacer late swaps | PASS: 0 | PASS: 0 | PASS: 0 |
| 3 | `CATransaction.commit` absent: 0 misses overran by it; transactional presents ≤ 0.1 % | PASS: 0; 0 of 141082 | PASS: 0; 0 of 141607 | PASS: 0; 0 of 61345 |
| 4 | `nextDrawable` p50 / p99 / max (reported) | 0.011 / 0.030 / 0.310 ms | 0.011 / 0.030 / 0.281 ms | 0.013 / 0.021 / 0.247 ms |

B-off for comparison: 0.014 / 0.036 / 0.272 (block 1), 0.014 / 0.036 / 0.238 (block 3), 0.014 / 0.022 / 7.008 ms (LG block 6).

**B: PASS.** The B-on blocks' 2 misses were each the first new-frame tick after a seek, which overran in `perform` (§18.5,
`WINDOW_PRESENT_PATH.md` §6.2).

**G** (the 0.9.4 gate): block 1 **FAIL** (1 hold, 1 skip, `pacer (no [LATE-SWAP])`). Blocks 2–6 PASS. Renderer recoveries and near-misses
were 0 on every block. **G: FAIL.** As `RIG.md` states, G does not decide C+ or B.

**D** (Export Diagnostics' counters; `[DIAG] playback counters` against the log):

| Block | Pacer missed deadlines (DIAG / `[PACER] stopped`) | Card holds while playing (DIAG / timed-after-timed repeats) | Gate holds | Renderer recoveries (DIAG / attempt lines) |
|---|---|---|---|---|
| boff-1 | 70 / 70 | 118 / 118 | 1 | 0 / 0 |
| bon-1 | 0 / 0 | 113 / 113 | 0 | 0 / 0 |
| boff-2 | 68 / 68 | 113 / 113 | 0 | 0 / 0 |
| bon-2 | 1 / 1 | 120 / 120 | 0 | 0 / 0 |
| 2398-cmp-bon | 1 / 1 | 40 / 40 | 0 | 0 / 0 |
| lg-boff | 7 / 7 | 112 / 112 | 0 | 0 / 0 |

**D: PASS.** Read with care: "card holds while playing" counts 40–120 per block where the gate counts 0–1. The production counter
includes each Play's opening repeat and the repeats around transport, which the gate excludes. In a block with 48 Plays and 48 seeks
that is about 2 per Play. The repeats come in bunches at the same offsets in each 175 s cycle (§18.6). A tester's Export Diagnostics will therefore show a non-zero card-hold count after ordinary playback. Inference.

**P:** complete on all 6. Each block has a `total` line, 0 dropped records, and `miss` lines equal to the total: 67, 0, 66, 1, 1, 5
(`ab.report:82-87`).

### 18.5 Where the misses were (summary; detail in `WINDOW_PRESENT_PATH.md` §6)

| Block | Misses (lines) | `CATransaction.commit` | `perform` | `waitUntilScheduled` |
|---|---|---|---|---|
| boff-1 | 67 | 67 | 0 | 0 |
| bon-1 | 0 | — | — | — |
| boff-2 | 66 | 65 | 1 | 0 |
| bon-2 | 1 | 0 | 1 (14.38 ms) | 0 |
| 2398-cmp-bon | 1 | 0 | 1 (26.49 ms) | 0 |
| lg-boff | 5 | 1 | 2 | 2 |

All 5 `perform` misses of the night (boff-2 `:577125`, bon-2 `:604927`, 2398 `:29280`, lg `:481640`, `:646069`) come within 400 log lines
after a `[TRANSPORT] seek` and its `[CADENCE-SWAP]`. They are each the first new-frame tick after a seek, the shape of night 4's two
(`WINDOW_PRESENT_PATH.md` §5.3). CONFIRMED.

### 18.6 Missed deadlines and holds against the Carbon Copy Cloner runs (nights 1, 3, 4, 5)

**Source.** CCC's privileged-helper log, `/Library/Application Support/com.bombich.ccc/pht_debug.log` (world-readable; the history
databases are not plain SQLite and were not read). Each run's line `exit_status=… start_time=… end_time=… data_copied=…` gives its
real times. Every run from 2026-11-16 03:30 to 2026-11-19 11:30 started at its scheduled :30:00 and ended 64–82 s later. Night 1's
19:30 run copied 8.23 GB (19:30:00–19:31:21).

**Method.**
- **Misses:** every `[PACER] … intervals 10 s: … · missed N` line (`App/OutputPacer.swift:221`), placed at the last host stamp before
  it. The 10 s counts sum to each block's `[PACER] stopped` total, less the final partial window: one fewer on 2 of 26 blocks
  (`id-gop25-at-5994-on`, `n5-5994-sdi-boff-2`). On nights 4 and 5, each miss in a window was also timed exactly from `present.report`.
- **Holds:** all of the gate's holds and skips, from `rc-soak-report.py`'s `analyse()` (the call `ab-check.py` `causes` uses). Note that
  `soak.report` lists at most 20 per block.
- **Window:** CCC start ± 3 min, over the blocks' wall-clock spans. A 10 s window overlapping the edge counts as inside.
- **Expected:** that block's own miss rate times the window's length inside it. A night-wide rate would mix B-on blocks (≈ 0 misses)
  with B-off blocks (≈ 70).
- Scripts in the session scratchpad, not kept.

**Which CCC starts fall within ±3 min of a block:**

| Night | Blocks span | CCC starts in or next to it | Overlapping block(s) | Data copied |
|---|---|---|---|---|
| 1 (`manifold-cardpull-s1`) | 11-16 19:45:52 – 23:10:24 | 19:30 (ended 19:31:21, **14.5 min before** the first block); 23:30 (19.6 min after the last) | **none** | 8.23 GB; 2.56 GB |
| 3 (`manifold-pacerphase-ab`) | 11-17 20:49:54 – 11-18 03:58:46 | 23:30; 03:30 | `ab-gop25-sdi-on` (22:52–23:53); `id-gop25-at-5994-on` (03:17–03:38) | 0.84 MB; 0 |
| 4 (`manifold-pacerphase-ab3`) | 11-18 13:30:25 – 18:36:03 | 15:30 | `n4-2398-cmp-on` (window 339 s, to its end at 15:32:39); `n4-gop25-sdi-on` (18 s, from 15:32:42) | 3.0 MB |
| 5 (`manifold-pacerphase-ab4`) | 11-18 21:21:09 – 11-19 02:01:26 | 23:30 | `n5-5994-sdi-boff-2` (22:54–23:41) | 1.5 MB |

**Every missed deadline within ±3 min of a CCC start:**

| Night | Block (block total) | CCC | Misses in the window, time from CCC start | In window / expected at block rate |
|---|---|---|---|---|
| 1 | — | — | none (no block overlaps a window) | — |
| 3 | `ab-gop25-sdi-on` (10) | 23:30 | 1, in the 10 s window ending 23:30:01 (−9 to +1 s) | 1 / 0.98 |
| 3 | `id-gop25-at-5994-on` (21; 20 in the 10 s lines) | 03:30 | 4, in 10 s windows ending at −147, +27, +107, +170 s | 4 / 5.79 |
| 4 | `n4-2398-cmp-on` (6) | 15:30 | none | 0 / 0.55 |
| 4 | `n4-gop25-sdi-on` (8) | 15:30 | none | 0 / 0.04 |
| 5 | `n5-5994-sdi-boff-2` (68) | 23:30 | 7, exactly (`present.report`): −157.1, −128.4, −52.8, −13.5, −12.0, +83.2, +163.2 s | 7 / 8.49 |
| | **All** | | **12** | **12 / 15.85** |

**Every hold within ±3 min of a CCC start: none.**
- The gate's judged holds and skips: night 1 3, night 3 34, night 4 3, night 5 2. That is 42, and **0** fell in a window. The nearest
  was 39.7 min from a CCC start (night 3 `ab-5994-sdi-on`, which has no window).
- `id-gop25-at-5994-on` (25p on 59.94, whose repeats are the cadence and are not judged, §15, `:1508`) had 64,449. 19,286 of them
  (29.9 %) fall in its window, which covers 28.9 % of the block: no excess.
- The card-hold repeats on night 4's and night 5's windowed blocks (`[PULLPHASE]` timed-after-timed, the D counter's rule) were 5 against
  4.99 expected (`n4-2398-cmp-on`), 0 against 0.08 (`n4-gop25-sdi-on`) and 16 against 14.53 (`n5-5994-sdi-boff-2`). The bunches at
  −51.7 s and +121.4 s recur at the same offsets on both nights. Inference: Plays after the soak's transport steps, not CCC.

**Spread, not clustered.** CONFIRMED by the counts above.
- 12 misses fell in the windows against 15.85 expected at each block's own rate. No block exceeds its expectation by more than 0.02.
- The misses in a window are spread across its 6 minutes. Only 2 of the 12 can lie in the 65–68 s the run itself lasted, both on night 3
  and both known only to ±10 s.
  - `ab-gop25-sdi-on`'s miss falls between −9 and +1 s. That block's 10 misses come about every 6 min through its hour (10 s windows
    ending 22:57, 23:04, 23:10, 23:11, 23:16, 23:23, 23:30, 23:42, 23:45, 23:48).
  - `id-gop25-at-5994-on`'s miss falls between +17 and +27 s. That block has a miss every 20–120 s from 03:18 to 03:37, with or without
    CCC.
- On night 5, where the times are exact, none of the 7 fell inside the run (0 to +68 s). `n5-5994-sdi-boff-2`'s misses per 6 min, from
  its start, were 10 12 10 9 7 9 5 4, and the CCC start falls in the 6th bin (9).
- **Limits:** the four runs that overlapped a block copied 0 to 3 MB. The two large runs (8.23 GB on 11-16 19:30, 6.65 GB on 11-17 15:30)
  overlapped no block. So a large CCC copy's effect on the pacer is UNTESTED. What these nights show is that a routine run (about 1 min,
  a few MB) did not cluster misses or holds.

### 18.7 What this shows (not part of the verdicts)

- **B removed the misses that matter to the card.** At 59.94 on the ASUS: 70 and 68 missed deadlines with B off, against 0 and 1 with B
  on, in the same degraded state (72–76 % holding windows on all four blocks, `WINDOW_PRESENT_PATH.md` §6.3). There were 55 pacer late
  swaps with B off and 0 with B on. B's one 59.94 miss was a post-seek `perform` overrun.
- **C+ removed the exposure at 59.94** (0 of 400 segments) and every one-period pacer hold (55 swaps, 0 held). It cannot cover a
  two-period stall, which drops the frame at the pacer (§18.3). With B on there were no present stalls to cover. Inference: on this
  night's evidence, the two changes together leave the 59.94 card path without a held pacer frame. Each covers what the other cannot.
  Untested together on a B-on block with a two-period stall, because none occurred.
- **The LG block at 120 Hz, unscaled, did not enter the bad state** (0 holding windows; misses 7, of which 2 are post-seek `perform`
  overruns). The same binary, file and night on the ASUS was degraded in every block. Whether the degraded state belongs to the ASUS
  mode (1920 × 550 at 59.936 Hz) rather than to the build or the night is suggested by this, but one block does not settle it.
  Inference. `WINDOW_PRESENT_PATH.md` §6.4.
- **Open:**
  - Whether to commit or ship C+ or B is a decision for Robbie; this section does not make it. B's attended checks (`WINDOW_PRESENT_PATH.md`
    §4.5: live resize, Display Transform switches, HLG and PQ on the LG) have not been run, and the soak exercised no state tick under B
    (0 transactional presents, §6.2 there).
  - The per-pull lead target (p01 ≥ P + 0.25 ms) was missed by under 0.1 ms on 3 blocks. Whether s_L should be larger is open.
  - boff-2's clamp hits and bon-1's 7 ms excursion: UNKNOWN.

## 19. A/B night 6 (0.9.5 defaults against plain B, run 2026-11-19): defaults **PASS**, B **FAIL** (B1 on the LG block only), D **PASS**, P complete. B as the 0.9.5 default: **NO**

Started by hand (`soak.sh main > soak.out 2>&1`). The slots were set at 19:00:14. The first block began at 19:11:17, after the 10 min idle
wait, and the last ended at 23:51:33. `ENDED` was written at 23:51 and there is no `STOP` file. All 6 blocks ran to the end (`"ended":
"done"` in every `<label>.json`; `block … exit 0` at `soak.out:27`, `:52`, `:77`, `:102`, `:127`, `:152`), and none was skipped. That
is 4.27 h played (`soak.report`). The verdicts are `ab-check.py`'s, run by `soak.sh` at exit against `RIG.md`'s criteria, which were
written before the run. They were not re-run in this session. Paths below are relative to `~/Code/_scratch/manifold-pacerphase-ab5/`.

Wall times come from the clock pairs `rig.log` records before and after each block. The two pairs' offsets differ by −0.014 to +0.028 s
per block (`ab.report:1-7`), so the mapping holds to well under a second. That rests on an inference: Python's `time.monotonic()` reads
the clock behind the logs' host stamps. Window times in `windows.report` are the end of a 10 s window. No build, no launch, no git.

**Candidate** (`RIG.md`): `.build-pacerphase-5`, Profile, 0.9.4 (27), built from HEAD `e80dc2b` (C+ the default; plain B behind
`MANIFOLD_PACER_PRESENT_TX=0`). sha256 `114efe07dc4f1d87…`, ad-hoc linker-signed. `MANIFOLD_PACER_PHASE` was unset in every block, so C+
ran as shipped. Every block had `MANIFOLD_DECKLINK_CADENCE_LOG=2` and `MANIFOLD_PRESENT_TIMING=1`, and blocks 2, 4, 5 and 6 also had
`MANIFOLD_PACER_PRESENT_TX=0` (`ab.report:1-7`, from each `<label>.json` `extra_env`). Each block ran 45 min (16 cycles of 175 s).

**Verdicts (`ab.report`):**
- **The 0.9.5 defaults (B-off blocks 1 and 3): PASS** (`:26`).
  - DEF1, DEF2 and DEF4: 0 crossings, 0 crossing-caused holds or skips, 0 freezes.
  - DEF5: 0 holds or skips of any cause, 0 unrecovered events, markers met. So exception (b) was never needed (DEF3: none accepted, none
    to accept).
  - The gate's ≥ 6 h is not tested by 1.5 h of B-off blocks (`RIG.md`).
- **B (B-on blocks 2, 4, 5, 6): FAIL** (`:54`), on one criterion in one block: **B1 on the LG block, with 4 pacer missed deadlines against
  ≤ 2** (`:46`). Every other B row passed: B1 on blocks 2, 4 and 5 (0 each); B2 (0 pacer late swaps on all four); and B3 (0 holds or
  skips on all four). Section 19.3 says what the 4 were.
- **D: PASS** (`:64`). On all 6 blocks, the `[DIAG] playback counters` line agrees exactly with the log. **Card holds while playing were
  0 in every block, against the gate's 0.** This is the first night with `CardHoldFilter`, and the counter now equals the gate's hold
  count. Night 5's binary read 112–120 (§18.2).
- **P: complete on all 6** (`:65`): 2, 0, 52, 0, 0 and 2 misses.
- **The verdict rule** (`:66-71`). Window holds (gate timeouts + nil drawables) passed on all four B-on blocks: 0, 1, 0 and 0, against
  the B-off maximum of 1 (blocks 2 and 4), or against 0 (blocks 5 and 6). B's verdict is FAIL, so **"B AS THE 0.9.5 DEFAULT: NO (B FAIL;
  window holds PASS)"** (`:71`). As the rule was written, B stays off for 0.9.5.

### 19.1 Rig

- **Checked before every block: passed 6 of 6.** `rig.log` has one entry per block, and `soak.out` has them at `:4`, `:29`, `:54`, `:79`,
  `:104` and `:129`. Each entry shows zoom.us none, capture closed, default output Scarlett, `MANIFOLD_PACER_PHASE` unset, sha256
  `114efe07dc4f1d87…` ok, slots `waveform | parade | markers`, and signing `flags=0x20002(adhoc,linker-signed)`, `TeamIdentifier=not
  set`.
- **Display placement: as planned.**
  - Blocks 1–5: the ASUS PA147 at 59.936 Hz ("window moved": `soak.out:12`, `:37`, `:62`, `:87`, `:112`).
  - Block 6: the LG TV SSCR2 at 120.000 Hz ("window shown": `:137`).
  - Each `<label>.json` `window_display` agrees.
  - Before every block the LG read `3840 x 2160` · `3840 x 2160 @ 120.00Hz` (unscaled) and the ASUS read `1920 x 550` · `1920 x 550 @
    60.00Hz`.
- **HID idle at each block start** (`soak.out:3`, `:28`, `:53`, `:78`, `:103`, `:128`): 612, 3415, 6218, 9021, 11824 and 14627 s. The
  Mac was not touched, and Resolve was closed each time.
- **Guards:** "guard after …: clean" for all 6 blocks (`soak.out:24`, `:49`, `:74`, `:99`, `:124`, `:149`).
- **Slots restored: yes.**
  - `setslots` (19:00:14, `soak.out:1`): "were yrgb | meters | markers", stash `prefs-stash-20261119-190014.txt`.
  - At exit (23:51:53, `:188-189`): "slots at the end of the night: waveform | parade | markers", then "slots restored: yrgb | meters |
    markers".
  - Read again in this session (read only), `com.graviton.manifold` `manifold.scope.slot0/1/2` are `yrgb | meters | markers`, which is
    exactly the stash.
- **Recorded, never stopping the night** (`rig.log`):

| # | Block | Keychain prompts denied before it (earlier launches) | Denied in it | SecurityAgent before | Memory free before / after | `ASEProcessing` per minute | Thermal | Clock-pair drift |
|---|---|---|---|---|---|---|---|---|
| 1 | `boff-1` | 0 (0) | 2 | 0 | 86 % / 86 % | 3284 | no warning recorded | +0.002 s |
| 2 | `bon-1` | 2 (1) | 2 | 0 | 86 % / 86 % | 3284 | the same | +0.027 s |
| 3 | `boff-2` | 4 (2) | 2 | 0 | 86 % / 85 % | 3281 | the same | −0.014 s |
| 4 | `bon-2` | 6 (3) | 2 | 0 | 85 % / 86 % | 3282 | the same | +0.020 s |
| 5 | `2398-cmp-bon` | 8 (4) | 2 | 0 | 86 % / 86 % | 2569 | the same | +0.028 s |
| 6 | `lg-bon` | 10 (5) | 2 | 0 | 86 % / 86 % | **25** | the same | −0.013 s |

- `ASEProcessing` repeats night 5 (§18.1): about 3280 a minute with the window on the ASUS, and 25 with it on the LG.
- **Not covered:** launches and prompts before `soak.sh` started are UNKNOWN. `soak.out`'s first line is the `setslots` line, and it
  carries no note.

### 19.2 Per block

Holds, skips, freezes and late/dropped counts are the gate's (`soak.report`). Pacer and late-swap counts are `ab-check.py`'s
(`ab.report:1-7`). Window holds are from `windows.report`.

| # | Block | B | Pacer n / median / p99 / max (ms) | Missed deadlines | Pacer `[LATE-SWAP]` (held) | Holds / skips | Freezes | Window late / dropped | Card late / dropped | Gate timeouts / nil drawables | Presented / rendered | Markers |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `n6-5994-sdi-boff-1` | off | 311852 / 8.35 / 8.36 / 16.76 | 2 | 1 (0) | 0 / 0 | 0 | 10 / 4 | 0 / 0 | 1 / 0 | 98.0 % | PASS |
| 2 | `n6-5994-sdi-bon-1` | on | 311824 / 8.35 / 8.36 / 8.79 | **0** | 0 | 0 / 0 | 0 | 6 / 5 | 0 / 0 | 0 / 0 | 99.5 % | PASS |
| 3 | `n6-5994-sdi-boff-2` | off | 311790 / 8.35 / 8.36 / 25.03 | **53** | 25 (0) | 0 / 0 | 0 | 13 / 6 | 0 / 0 | 1 / 0 | 92.8 % | PASS |
| 4 | `n6-5994-sdi-bon-2` | on | 311826 / 8.35 / 8.36 / 8.73 | **0** | 0 | 0 / 0 | 0 | 9 / 4 | 0 / 0 | 1 / 0 | 93.4 % | PASS |
| 5 | `n6-2398-cmp-bon` | on | 187085 / 13.91 / 13.92 / 14.36 | 0 | 0 | 0 / 0 | 0 | 11 / 1 | 0 / 0 | 0 / 0 | 100 % | PASS |
| 6 | `n6-5994-sdi-lg-bon` | on | 311840 / 8.35 / 8.36 / 25.03 | **4** | 0 | 0 / 0 | 0 | 10 / 3 | 0 / 0 | 0 / 0 | 100 % | PASS |

- **Markers:** 24 Regenerates pressed, all remade, 0 made while playing. Near them: holds and skips 0, late or dropped 4 (all window).
- **SDI bridge `!!`:** only "edge APPENDED by the card", 14 / 14 / 14 / 12 / — / 10 on the six blocks, with 0 late edges. The counts are the
  same with B on and off (`soak.report`).

### 19.3 B1 on the LG block: the 4 missed deadlines are 2 post-seek `perform` ticks

`present.report` lists 2 missed ticks on the LG block. Each one overran by two periods (next interval 25.02 ms, 3P), so it counts 2 missed
deadlines, which makes the `[PACER] stopped` line's 4 (`ab.report:7`, pacer max 25.03).

| Log line | Wall ≈ | Tick | Overran | Before it |
|---|---|---|---|---|
| `n6-5994-sdi-lg-bon.log:29480` | 23:07:13.7 | 22.177 ms | `perform` 22.081 ms | `[TRANSPORT] seek 1895.00` (`:29460`) 24 ms earlier, made while paused (the pulls before it read `branch paused`); the first new-frame tick after it |
| `n6-5994-sdi-lg-bon.log:111675` | 23:12:59.8 | 21.986 ms | `perform` 21.820 ms | `[TRANSPORT] seek 1895.00` (`:111664`) 31 ms earlier |

- **In both, every present part is under 0.2 ms** (`nextDrawable` 0.016–0.019, `commit` 0.009–0.012, `colorTx` 0). The time is in
  `perform`, which is `performDisplayTick`'s work outside its present attempts (`App/PresentTimingLog.swift:16`, `:316`). That is the
  first frame's render after a seek, not the present path that B changes.
- **The same tick class occurs with B off:**
  - tonight's block 3 at the same seek (`n6-5994-sdi-boff-2.log:358437`, 21.309 ms, `perform` 17.727 ms, 27 ms after `[TRANSPORT] seek
    1895.00` at `:358425`);
  - night 5's B-off LG block: 2 `perform` misses (`../manifold-pacerphase-ab4/present.report:145-146`) among 7 missed deadlines.
    That is more than B1's ≤ 2 allows;
  - night 5's `boff-2` (`:131`).
  - With B on, it also occurred on night 5's `bon-2` and `2398-cmp-bon` (`:138`, `:140`). That was B's one 59.94 miss in §18.7.
  - Every block tonight had 48 seeks.
- No hold and no skip followed either tick, at the card or by the gate.
- **So B1 failed on a tick the B switch does not touch** (inference from the parts). That doesn't change the verdict: B1 was written as ≤ 2
  missed deadlines per B-on block, with no exception for seeks, and `RIG.md` named the LG block as a B-on block in every B criterion.
  Whether to re-state B1 (for example as "≤ 2 outside a seek's first tick", or "no more than the B-off LG count") is Robbie's call. It is
  not applied here.

### 19.4 Window holds and the Carbon Copy Cloner runs

**The three gate timeouts of the night each fall inside a Regenerate**, one per block in 1, 3 and 4. They are the only window holds; there
are 0 nil drawables anywhere.

| Block | B | `windows.report` row (window end) | Rendered / presented in that 10 s | Regenerate in progress (`soak.out`) |
|---|---|---|---|---|
| `boff-1` | off | `n6-5994-sdi-boff-1.log:429592` (19:41:41) | 600 / 571 | #3, pressed 19:41:33, done 19:42:04 |
| `boff-2` | off | `n6-5994-sdi-boff-2.log:571931` (21:25:07) | 590 / 559 | #4, 21:25:00 → 21:25:26 |
| `bon-2` | **on** | `n6-5994-sdi-bon-2.log:429537` (22:01:51) | 600 / 570 | #3, 22:01:43 → 22:02:13 |

- Each shows about 30 frames not presented in that window. That is about 0.5 s, one `presentGateTimeout`.
- The gate timeout is in the window path and around a Regenerate pause. It happened once with B on and twice with B off.
- That 1 against 1 is what the verdict rule's window-hold row compares.

**CCC (`ccc.log`, 2 runs since 19:00:13, `soak.out:154`):**

| Run | Start → end | Copied | Block | In it |
|---|---|---|---|---|
| 1 | 19:30:00 → 19:31:06 | 1,265,903 bytes | `boff-1` (B off) | no missed tick (block 1's misses at 19:12:03 and 19:33:51), no gate timeout, no hold. The 10 s windows show presents held in flight up to 19:30:39 and none from 19:30:49 to 19:31:19, a pattern that comes and goes all block. |
| 2 | 23:30:00 → 23:31:05 | 0 bytes | `lg-bon` (B on) | no missed tick (block 6's at 23:07 and 23:12), no gate timeout, no held present. Rendered = presented in every window. |

- Both were routine runs (about 1 min, ≤ 1.3 MB) and overlapped a block without effect, as on night 5 (§18.6).
- A large copy remains UNTESTED.

### 19.5 What this shows (not part of the verdicts)

- **The defaults pass the 0.9.5 gate's terms on 1.5 h** (0 holds, 0 crossings, 0 freezes), with C+ as shipped and the
  transactional present.
  - Block 3 reproduced night 5's ASUS miss rate: 53 missed deadlines from 52 missed ticks. 50 were `CATransaction.commit` overruns and 2
    were `perform` (`present.report`). There were 25 pacer late swaps, 0 held.
  - Block 1 had only 2 misses in the same mode, both `CATransaction.commit`. Why the two B-off blocks differ by 26× is UNKNOWN; night 5's were 70 and 68.
- **On the ASUS, B again removed the present-path misses**: 0 and 0 on blocks 2 and 4, against 2 and 53. With B on there were 0 pacer late
  swaps, 0 transactional presents, and `nextDrawable` max ≤ 0.47 ms. The held-in-flight degraded state was unchanged (36–78 % of
  windows with B on, 44–80 % with it off; `WINDOW_PRESENT_PATH.md` §8).
- **B's only failing row is a post-seek render tick** that B-off blocks show too (§19.3).
- **Open, for Robbie:**
  - whether the rule stands as written (B off for 0.9.5) or B1 is re-stated and judged again on these logs;
  - why boff-1 and boff-2 differ so much;
  - the Regenerate gate timeouts, which B neither caused nor removed.

## 20. Night 7 (B-only, plain B in every block, run 2026-11-20): B **PASS**, 0.9.5 gate **PASS** as `ab-check.py` computes it, D **PASS**, P complete. Two SDI sound faults the gate's tools do not count (§20.4)

Started by hand (`soak.sh main > soak.out 2>&1`). The slots were set at 00:30:44. The first block began at 00:41:16, after the 10 min idle
wait, and the last ended at 06:48:06. `ENDED` was written at 06:48 and there is no `STOP` file. All 6 blocks ran to the end (`"ended":
"done"` in every `<label>.json`; `block … exit 0` at `soak.out:31`, `:60`, `:89`, `:118`, `:147`, `:163`), and none was skipped. That
is 5.60 h played, 6 h 07 min of block wall time (`soak.report`, TOTAL). The verdicts are `ab-check.py`'s, run by `soak.sh` at exit
against `RIG.md`'s criteria, which were written before the run (2026-11-20 00:30). They were not re-run in this session. Paths below are
relative to `~/Code/_scratch/manifold-pacerphase-ab6/`. No build, no launch, no git.

**Candidate:** night 6's binary, unchanged (`.build-pacerphase-5`, Profile, 0.9.4 (27), from `e80dc2b`; sha256 `114efe07dc4f1d87…`,
checked before every block; ad-hoc linker-signed). Every block had `MANIFOLD_PACER_PRESENT_TX=0` (plain B), `MANIFOLD_DECKLINK_CADENCE_LOG=2`
and `MANIFOLD_PRESENT_TIMING=1`, and no `MANIFOLD_PACER_PHASE` (C+ as shipped). `ab.report:2-7` reads `B on True` for all six, from each
`<label>.json` `extra_env`. Each block ran 21 cycles of 175 s (61.25 min).

**Verdicts (`ab.report`):**
- **B: PASS** (`:46`). All six blocks pass "B on", B1, B2 and B3.
  - **B1 (re-stated, Robbie 2026-11-20: post-seek first-frame `perform` misses reported, not counted):** counted 0, 0, **1**, 0, 0, 0
    (`ab.report:17`, `:22`, `:27`, `:32`, `:37`, `:42`). The LG block's 2 missed deadlines are one post-seek `perform` tick, reported and
    not counted (§20.3). The GOP block's 1 is counted (§20.3).
  - **B2:** 0 pacer late swaps on all six. **B3:** 0 holds and 0 skips on all six (`ab.report:8-14` "holds and skips by cause": none).
- **G, the 0.9.5 gate as written, under B: PASS** (`:54`). On all six blocks: 0 freezes, 0 unrecovered (as `rc-soak-report.py` counts
  them), 0 holds or skips of any cause, 0 card drops (so the frame #0 start-drop exception was not needed), 0 card late, markers met on
  the five video blocks. The gate's ≥ 6 h: 5.60 h playing in 6 h 07 min of blocks, the same as 0.9.3's accepted 5.60 h in 6 h 07 min
  (`Manifold-BUILD.md`). `ab-check.py` does not judge the duration (`RIG.md`).
  - **Not counted by the gate's tools, and gate-relevant: SDI sound lost for 55 min on block 5, never recovered within the output session,
    and 65 s of SDI sound missing after a seek on the GOP block (§20.4).** `rc-soak-report.py` counts only silent *starts* as unrecovered
    sound events, so G reads PASS. Whether these fail the gate's "0 unrecovered events" is Robbie's call. My reading: block 5's is an
    unrecovered event in substance.
- **D: PASS** (`:83`). On all six blocks the `[DIAG] playback counters` line agrees exactly with the log: pacer missed deadlines 0, 0, 1, 2,
  0, 0 against the `[PACER] stopped` lines; card holds while playing 0 against the gate's 0; renderer recoveries 0 against 0.
  **The WAV block printed its own `[DIAG]` line and passed D** (`:82`). `RIG.md` had left that UNKNOWN; it is not a failure of any kind.
- **P: complete on all six** (`:84`), including the WAV block (0 misses each, its `[PRESENT-TIMING] total` present). Misses: 0, 0, 1, 1, 0,
  0 (`present.report`).
- B as the 0.9.5 default is not computed (`RIG.md`): night 6's rule compared B-on blocks with B-off blocks, and tonight had none.

### 20.1 Rig

- **Checked before every block: passed 6 of 6** (`soak.out:4`, `:33`, `:62`, `:91`, `:120`, `:149`; `rig.log`): zoom.us none, capture
  closed, default output Scarlett, `MANIFOLD_PACER_PHASE` unset, **`MANIFOLD_PACER_PRESENT_TX=0` passed** (the new `bcheck`), sha256
  `114efe07dc4f1d87…` ok, slots `waveform | parade | markers`, signing `flags=0x20002(adhoc,linker-signed)` (6 of 6 entries).
- **Display placement: as planned.** Blocks 1, 2, 3, 5, 6 on the ASUS PA147 at 59.936 Hz ("window moved": `soak.out:12`, `:41`, `:70`,
  `:128`, `:157`); block 4 on the LG TV SSCR2 at 120.000 Hz ("window shown": `:99`). The WAV's window was placed and checked like the
  others. Before every block the LG read `3840 x 2160 @ 120.00Hz` and the ASUS `1920 x 550 @ 60.00Hz`.
- **HID idle at each block start:** 626, 4295, 7963, 11632, 15300, 18969 s (`soak.out:3`, `:32`, `:61`, `:90`, `:119`, `:148`). The Mac
  was not touched; Resolve was closed each time.
- **Guards:** "guard after …: clean" for all 6 (`soak.out:28`, `:57`, `:86`, `:115`, `:144`, `:160`).
- **Slots restored: yes.** Set at 00:30:44 ("were yrgb | meters | markers", `soak.out:1`, stash `prefs-stash-20261120-003044.txt`); at
  exit "slots at the end of the night: waveform | parade | markers", then "slots restored: yrgb | meters | markers" (`:199-200`). Read
  again in this session (read only): `manifold.scope.slot0/1/2` are `yrgb | meters | markers`, exactly the stash.
- **Recorded, never stopping the night** (`rig.log`; `ab.report:2-7` for drift):

| # | Block | Denied before (earlier launches) | Denied in it | SecurityAgent before | Memory free before / after | `ASEProcessing` / min | Thermal | Clock-pair drift |
|---|---|---|---|---|---|---|---|---|
| 1 | `bon-1` | 0 (0) | 2 | 0 | 86 % / 86 % | 3281 | no warning recorded | +0.051 s |
| 2 | `2398-cmp-bon` | 2 (1) | 2 | 0 | 86 % / 86 % | 2547 | the same | +0.027 s |
| 3 | `gop25-sdi-bon` | 4 (2) | 2 | 0 | 86 % / 86 % | 2606 | the same | −0.024 s |
| 4 | `lg-bon` | 6 (3) | 2 | 0 | 86 % / 85 % | **24** | the same | +0.053 s |
| 5 | `bon-2` | 8 (4) | 2 | 0 | 86 % / 85 % | 3279 | the same | +0.014 s |
| 6 | `ao48-sdi-bon` | 10 (5) | 2 | 0 | 86 % / 85 % | **0** | the same | −0.034 s |

- `ASEProcessing` repeats nights 5–6 on the ASUS and the LG. The WAV block, with no window picture, had 0.
- **Not covered:** launches and prompts before `soak.sh` started are UNKNOWN (`soak.out:1` is the `setslots` line, with no note).

### 20.2 Per block

Holds, skips, freezes, late/dropped, SDI and markers are the gate's (`soak.report`). Pacer and window figures are `ab-check.py`'s.

| # | Block | Pacer n / median / p99 / max (ms) | Missed deadlines (counted) | Pacer late swaps | Holds / skips | Freezes | Window late / dropped | Card late / dropped | Gate timeouts / nil drawables | Presented / rendered | SDI `!!` lines | SDI missing samples | Markers |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `bon-1` | 409249 / 8.35 / 8.36 / 8.84 | 0 (0) | 0 | 0 / 0 | 0 | 18 / 6 | 0 / 0 | 0 / 0 | 94.2 % | 16 appended edges | 19,572 | PASS |
| 2 | `2398-cmp-bon` | 245547 / 13.91 / 13.92 / 14.23 | 0 (0) | 0 | 0 / 0 | 0 | 15 / 2 | 0 / 0 | 0 / 0 | 100 % | none | 0 | PASS |
| 3 | `gop25-sdi-bon` | 256214 / 13.34 / 13.35 / 26.67 | 1 (1) | 0 | 0 / 0 | 0 | 20 / 21 | 0 / 0 | 0 / 0 | 100 % | 4 appended edges | **3,123,840** | PASS |
| 4 | `lg-bon` | 409256 / 8.35 / 8.36 / 25.02 | 2 (0) | 0 | 0 / 0 | 0 | 11 / 10 | 0 / 0 | 0 / 0 | 100 % | 11 appended edges | 18,877 | PASS |
| 5 | `bon-2` | 409261 / 8.35 / 8.36 / 8.69 | 0 (0) | 0 | 0 / 0 | 0 | 10 / 8 | 0 / 0 | 0 / 0 | 92.8 % | 1 appended edge, **4,139 `no audio callback`** | 1,741 | PASS |
| 6 | `ao48-sdi-bon` | 406585 / 8.35 / 8.36 / 8.41 | 0 (0) | 0 | 0 / 0 | 0 | — (no window picture) | 0 / 0 | 0 / 0 | — | 20 appended edges | 69,868 | (no markers) |

- **Markers:** 30 Regenerates pressed, all remade, 0 made while playing. Near them: holds and skips 0, late or dropped 7 (all window).
- **Totals:** 378 Plays, 378 seeks, 126 loop wraps, 944,224 card pulls while playing, 0 missed slots, 6 output starts all with sound,
  0 silent starts.

### 20.3 B1: the three missed deadlines of the night

| Block | Log line | Wall ≈ | Tick | Overran | Before it | B1 |
|---|---|---|---|---|---|---|
| `lg-bon` | `n7-5994-sdi-lg-bon.log:851537` | 04:44:44 | 21.648 ms, new-frame, next 25.02 ms (3P → 2 deadlines) | `perform` 21.574 ms | a `[TRANSPORT] seek` 29 ms earlier, no new frame between | post-seek first frame: **reported, not counted** |
| `gop25-sdi-bon` | `n7-gop25-sdi-bon.log:355028` | 03:41:39 | 16.288 ms, **repeat** tick, next 26.62 ms (2P → 1 deadline) | `perform` 16.237 ms | `[TRANSPORT] seek 767.40` while paused (`:355018`), 35 ms earlier | **counted** (`RIG.md`'s rule requires a new-frame tick) |

- The GOP tick is the same post-seek render cost as the LG one: a seek made while paused, so the first tick after it has no new frame to
  show and is tagged a repeat tick. That is inference from the parts (`perform` is all of it; no present attempt). It is counted as the
  rule was written, and B1 still passes (1 ≤ 2).
- No missed tick was a present-path step: 0 `CATransaction.commit`, 0 `waitUntilScheduled` overruns all night. No hold or skip followed
  either tick.

### 20.4 Two SDI sound faults the gate's tools do not count

**Block 5 (`bon-2`): the card's audio callbacks stopped at 04:51:38 and never resumed in that output session (55 min).**
- The last `[SDI-AUDIO] runs` line is `n7-5994-sdi-bon-2.log:78387` (≈ 04:51:37). From `:78876` (frame 20112, ≈ 04:51:39) to the end of
  the block, the video callback logs `[SDI-AUDIO] !! no audio callback in the last 48 frames … callbacks 16722, audio buffered 0` every
  48 frames: 4,139 lines, to frame 218,736 (`:865481`). The stop line reads `audio callbacks 16722` (`:865583`).
- So the bridge's audio callback (`RenderAudioSamples`) stopped coming, and the card drained its audio buffer to 0. This is the diagnostic
  added after chain11 (`CARD_CLOCK_FINDINGS.md` §10.22, D7 follow-up) firing for the first time. It answers chain11's open question for
  this case: the callback stopped, not the card refusing samples. Unlike chain11 and `BUGS.md`'s output-start failures, there was no
  output restart: this was mid-session, while playing, about 6 s after a loop wrap's re-latch (`:77008`–`:77049`, latch #11).
- Video ran normally to the end: completions every frame, 0 late, 0 dropped, 0 holds. The Mac side kept going: 57 more Plays, 95 card-lock
  `Stage 2` starts and 95 latches after the stall. The SDI bridge made **0 latches and 0 `runs` lines** after it (11 latches before). So
  the SDI wire carried picture without sound for 57 Plays (inference from the bridge's counters; the wire was not recorded).
- **What else happened at that second:** nothing in Manifold's log. In the unified log, System Events (pid 7550, started by the block's
  accessibility driver) exited at 04:51:37.162 after 353 s. But System Events exited about 6 min into **every** block tonight (00:47:03,
  01:48:12, 02:49:20, 03:50:29, 04:51:37, 05:52:46, `loginwindow` `applicationQuit`), and sound was lost only once. So that exit is not
  enough to explain it. No DeckLink, Desktop Video or kernel line appears between 04:51:33 and 04:51:42.
- **Cause: UNKNOWN.** Whether B has anything to do with it: UNKNOWN. B changes the window's present path (`WINDOW_PRESENT_PATH.md` §4.5),
  and the audio callback is the card driver's thread, so a link is not expected (inference). It is 1 occurrence in the 10 B-on SDI blocks
  of nights 5–7 (2, 3 and 5), and 0 in every earlier soak log searched (`manifold-rc-soak`, `manifold-rc094-soak`, `manifold-pacerphase-ab`, `-ab3`,
  `-ab4`, `-ab5`: 0 `no audio callback` lines).
- **Why the gate missed it:** `rc-soak-report.py` counts silent output *starts* and renderer GAVE UP as unrecovered. A mid-session loss of
  SDI sound is not detected. The `!!` line is in `soak.report`'s SDI line (`'no audio callback in the last N frames': 4139`), but nothing
  judges it.

**Block 3 (`gop25-sdi-bon`): 65 s of SDI sound missing after one seek while playing (02:44:45–02:45:55).**
- The block's SDI missing count is 3,123,840 samples (`soak.report`), against 5,760–15,360 on every earlier GOP block
  (`../manifold-rc094-soak/rc-gop25-sdi-1.log`, `../manifold-pacerphase-ab/ab-gop25-sdi-on.log`, `-off.log`,
  `../manifold-pacerphase-ab3/n4-gop25-sdi-on.log`). Almost all of it, 3.06 M, accrues at about 48,000 a second in two streaks:
  `n7-gop25-sdi-bon.log:5936-10658` and `:10787-12890`.
- It starts at a seek while playing, `[TRANSPORT] seek 978.16` at `:5674` (from 1165.03 s). The bridge re-latched correctly onto the new
  picture: latch #3, `pts 978.240000` (`:5744`). But the audio tap, which read ahead from 979 s, ran on to 1166.805 s within a few seconds
  and stopped there (`AudioTap` pts 1166.805 from about `:6500` until the next seek), near the position *before* the seek. The bridge
  needed 978–1043 s, which the tap's 8 s ring (`held≈384000f`) no longer held. So every sample was missing for the rest of that Play
  (to the Pause at `:10587`, 45 s) and the next Play (`:10752`–`:12859`, 20 s). The seek to 1895 at `:12970` brought the tap back in step.
- Inference: after this seek, the tap kept its pre-seek read limit. That is not checked in the code here. It happened at 1 of the block's 63
  seeks (21 while playing). Picture, holds and the window were unaffected. Whether the Mac's own sound was affected is UNKNOWN (the Mac path
  reads through AVFoundation, not the tap's ring; inference).

### 20.5 Window holds and the Carbon Copy Cloner run

- **Window holds: 0 all night.** 0 gate timeouts and 0 nil drawables in every block (`ab.report` B4). So **no run-2-style hold of
  ≈ 0.5 s recurred**, and the three Regenerate-time gate timeouts of night 6 (§19.4) did not recur in tonight's 30 Regenerates.
  Every playing 10 s window, with its wall time, is in `windows.report`. Details in `WINDOW_PRESENT_PATH.md` §9.
- **CCC (`ccc.log`, 1 run since 00:30:44, `soak.out:165`):** 03:30:00 → 03:31:06, 286,020 bytes, inside block 3 (`gop25-sdi-bon`). In it:
  no missed tick (block 3's one miss is at 03:41:39), no hold, no gate timeout. Rendered = presented in every 10 s window from 03:29:54 to
  03:31:27, with 0 held (`windows.report`). Routine size again; a large copy remains UNTESTED.

### 20.6 What this shows (not part of the verdicts)

- **Plain B passed every B criterion on a gate-style mix of 6 blocks and 5.60 h**, with B1 as re-stated. The present path had 0 overruns
  all night; the only misses were post-seek `perform` ticks (one counted under the rule's letter).
- **Plain B passed the 0.9.5 gate as `ab-check.py` computes it**: 0 holds of any cause, 0 freezes, 0 card drops, markers met, D exact.
- **But the night is not clean for SDI sound.** Block 5 lost SDI sound for 55 min with no recovery (cause UNKNOWN, first occurrence), and
  the GOP block lost 65 s after one seek. Neither is B's path (inference), and neither is counted by the gate's tools.
- **Open, for Robbie:**
  - whether block 5's SDI sound loss fails the 0.9.5 gate's "0 unrecovered events" (my reading: yes, in substance);
  - whether the GOP block's post-seek repeat-tick miss should count under B1 (it does as written; it passes either way);
  - follow-ups, not made: a mid-session SDI-sound check in `rc-soak-report.py` (the `no audio callback` line and a missing-samples rate);
    the tap's read limit after a seek while playing; whether the audio-callback stop recurs, with B off.

## 21. The rehearsal hold against C+'s choice: geometry, a C+ change, and a pull-side alternative (analysis 2026-11-21; nothing built)

Read-only. No build, no launch; git only `log` and `diff`. The rehearsal hold is `Manifold-BUILD.md`, "0.9.5 rehearsal result" and its
follow-up (`r95-5994-sdi-1.log` line 231206). Logs: nights 5–7 `~/Code/_scratch/manifold-pacerphase-ab4|ab5|ab6/` (`[PULLPHASE]` on),
the rehearsal `~/Code/_scratch/manifold-rc095-rehearsal/` (`[PULLPHASE]` off). Scratch scripts (this session's scratchpad, not kept):
`geom.py` (headroom and pull phase per Play), `wrap.py` (the phase across a wrap) and `replay.py` (held pulls near the band edge).

### 21.1 The pull code is unchanged since night 7's binary

`git diff e80dc2b..HEAD` shows the following:
- **`App/MetalVideoRenderer.swift`:** plain B's DEBUG guards removed, and log spelling changes. It has no change to
  `deckLinkPullSlotLocked` (`:6293-6380`: slot timeline `:6314`, target `:6337`, band `:6347`, would-repeat `:6366`, hold
  `:6373`), `deckLinkPullMarginLocked` (`:5757`) or `noteDeckLinkTick` (`:5744`).
- **`OutputPacing.swift`:** one doc comment. `PacerPhase.leadReference`, `leadSlack` and the follower's `leadStep` are unchanged.
- **`PacerSwitches.swift`:** only `presentUntransacted`, the B default.

The rehearsal candidate `fb9b1e6` therefore pulls and chooses x exactly as nights 6–7's `e80dc2b` did.

### 21.2 Geometry

Notation: F is the card frame, P = F/k the pacer tick, M = P + 10 ms the pull margin (the median tick + 10 ms), and B = F/2 the band
at a matched rate. A is the slot's place past the handed frame's pts (fixed for a Play under card lock, §17.1). c is the tick → ring
time and δ = host − slotHost. Then:

- **Pull phase** pp = lead + x = A − c (§17.1). C+ sets lead(x) = pp − x, for x in its band [0.5, P − 0.5] ms.
- **Would-repeat headroom.** While a Play runs in the next-by-band state (the handed frame is past the target and is taken
  only through the band), H = target + B − pts[next] = A − δ − (M − B). In terms of the pull phase,
  **H = pp − (M − B) + (c − δ)**. M − B is 10.00 ms at 59.94, 3.05 ms at 23.976 and 3.33 ms at 25.
- **Measured offset c − δ, per Play** (`geom.py`; segment medians, next-by-band Plays, nights 5–7): +0.731 ms at 59.94
  (379 Plays, range +0.32…+0.86); +0.796 at 23.976 (67 Plays); +0.919 at 25 (24 Plays). Against the pull phase printed on the
  lead-guard line (the renderer's median), the five night 5–7 guard-edge Plays give +0.886…+1.039.
- **H does not depend on x.** x appears in neither the target nor the frame grid.
  - Measured: across 202 lead-guard moves on nights 5–7, H after the move differed from H before by a median of 0.015 ms.
  - The one large difference (4.6 ms, `n6-5994-sdi-bon-1.log` from line 259429) is a seek that my segmenting missed (handed pts
    464.9 → 867.2 between pulls 6 and 7). Within the Play after it, the guard moved x by 6.8 ms and the lead rose 1.7 → 9.5 ms
    while H went 0.816 → 0.830 ms.
  - Across wraps: the phase after a wrap is not set by A − x before it. (A_after − (A_before − x_before)) mod F is spread over
    the whole frame at 59.94 (341 wraps; octile counts 37, 31, 38, 53, 51, 50, 44, 37 mod P).
- **Wobble within a Play:** H dips below its Play's median by a median of 0.028 ms, p95 0.06, p99 0.09, max 0.121 (379 Plays).
  The source is δ: clock − target swings about ±0.08 ms pull to pull (e.g. 18.36–18.54 ms at margin 18.34, same log). So a Play
  whose H starts under about 0.1 ms can hold.

| | 59.94 (k = 2) | 23.976 (k = 3) | 25 (k = 3) |
|---|---|---|---|
| P / B / M − B | 8.34 / 8.34 / 10.00 ms | 13.90 / 20.85 / 3.05 ms | 13.33 / 20.00 / 3.33 ms |
| Guard reaches lead ≥ P + 0.5 iff | pp ≥ 9.34 ms | pp ≥ 14.90 ms | pp ≥ 14.33 ms |
| Would-repeat edge (H = 0) at | pp ≈ 9.27 (segment scale), ≈ 9.07 (guard-line scale) | pp ≈ 2.25 | pp ≈ 2.41 |
| Lead at that edge, x = 0.5 | ≈ 8.6–8.8 ms (measured 8.66–8.83; rehearsal 8.547) | ≈ 1.7 ms (measured min 1.305, `n6-2398` H 0.285) | ≈ 1.9 ms |

**What the geometry shows:**
- **At 59.94, "the guard cannot reach slack" and "H is small" are the same inequality on pp.** On the guard line's scale, the guard
  stops at its edge exactly when H < ~0.27 ms. That is why every night 5–7 guard edge at 59.94 had H 0.098–0.255 ms (`n5-5994-sdi-boff-2`
  0.098, `n6-5994-sdi-bon-2` 0.105 and 0.197, `n7-5994-sdi-bon-1` 0.116 and 0.255). It is also why the rehearsal's edge came with a
  hold: its guard-line pp of 9.047 ms gives **H ≈ −0.07…+0.09 ms**, on the edge. The 0.13 ms in `Manifold-BUILD.md` came from the
  `[CADENCE]` stamps, which are taken after the fill's copy; that reconstruction's bias is inferred, not measured. The correlation of
  §20's edge Plays with C+ is a common cause (pp), not C+'s doing.
- **At k = 3 the guard is at its edge for every Play with pp < 14.3–14.9 ms**, which is why edges are common at 23.976 and 25. There,
  a Play near the would-repeat edge also has a small lead (~1.3–1.9 ms). Both margins are set by pp, and x moves neither toward
  safety: it already gives the most lead.
- **Which phase maximizes the distance from the would-repeat edge when slack is out of reach? None does better than another:** H is
  the same for every x in the band. The distance from the crossing (lead − P) is largest at x = 0.5 ms, the band's edge.
- **So "stop at the band edge" is never the worst choice.** It is the best for the crossing and neutral for the would-repeat edge.
  Going under 0.5 ms would give more lead but would put the tick within the establishment guard's 0.5 ms of a due time (§15.3),
  the dithering crossing that guard exists to stop.

### 21.3 The C+ change, replayed: no effect

**Proposed:** when lead ≥ P + 0.5 cannot be reached, choose x to maximize min(distance to the crossing guard, distance to the
would-repeat edge).
- **Its result:** the second distance is the same for every x (§21.2), so the rule picks x = 0.5 ms, which is today's choice. For a
  guard that can reach slack it changes nothing, because H is again the same for every x.
- **Replay:** there were 319 lead-guard lines in all: night 5 84, night 6 64, night 7 108 and the rehearsal 63. 69 of them stopped at
  the band's edge (12, 11, 23 and 23). On every one the proposal gives today's x. **0 Plays
  change, and none lands closer to an edge.** Latency: none. No-crossing guarantee: unchanged, since x is unchanged.
- **The rule cannot help,** because nothing C+ controls moves H: not x within a Play (§21.2), and not x before a wrap (§21.2, the
  wrap test).

### 21.4 The smallest change that does reach the edge: a sticky would-repeat band (pull side, not C+)

**The change:** after the first timed pull of a Play (the existing `wasTimed`, `MetalVideoRenderer.swift:6323`: the pull before was timed), the would-repeat
test at a matched rate becomes `pts[next] <= target + band + 0.0005` (`:6366`). The establishing pull keeps the plain band. Rate
mismatch (2 ms band) and the would-skip test (`:6367-6368`) are unchanged. This is one expression and no new state.

**Effects:**
- **Which frame is handed:** in steady state, the same frame as today on every pull that is not at the edge. A Play established within
  0.5 ms of the edge keeps its phase through wobble (max 0.121 ms measured), where today it drops one frame back after the first pull
  that wobbles past.
- **Latency:** none in steady state. At the edge, the Play keeps today's lower-latency phase instead of falling one frame back.
- **No-crossing guarantee: unchanged.** `next` is searched only among frames already in the ring (`:6360-6364`), so an unpublished
  frame can never be chosen. The handed frame and its publish time are the same as today, so its lead is unchanged.
- **Real drift** (a file with sound when card lock does not apply, `CARD_PULL_MARGIN.md` §1.2): the phase's one slip comes after 0.5 ms
  more drift, no extra hold. At 20 ppm that is about 25 s later.
- **Replay against nights 5–7** (`replay.py`, 18 blocks): held pulls whose next frame was in the ring and within 0.5 ms past the band:
  - **Steady state: 0.**
  - At establishment (the first ≤ 8 timed pulls after a Play, seek or wrap): 17. The sticky band does not apply to these, so they
    are unchanged.
  - **So 0 pulls change on nights 5–7, and no Play lands closer to an edge.** The other steady-state holds are untouched: "held
    (ring)" with excess > 0.5 ms, and "held (nominal)" with no next frame in the ring.
- **Rehearsal** (no `[PULLPHASE]`): its hold Play's H ≈ −0.07…+0.09 ms plus wobble ≤ 0.12 ms is inside 0.5 ms. So the change would
  have kept #113767 on 11.628283. This is inferred from §21.2's calibration; the pull's own excess was not logged.
- **Cost:** the pull code changes, so the 0.9.5 soak evidence (0.9.4's and nights 5–7's) no longer covers it as shipped. It needs
  its own soak. `deckLinkPullSlotLocked` lives in the app target, so a unit test would first need the selection extracted into
  `OutputPacing`.

### 21.5 Verdict

- **The C+ change: small and safe, but useless.** C+ has no lever on the would-repeat edge. Not recommended.
- **The sticky would-repeat band: small (one expression), and safe by the replay.** It changes no pull on 18 blocks of nights 5–7,
  leaves the no-crossing guarantee and latency as they are, and would have absorbed the rehearsal's hold (inferred).
- **Open, for Robbie:** whether it goes into 0.9.5, which means a new soak, or 0.9.6. If not, whether the 0.9.5 gate treats an edge
  hold of the half-frame band as a named exception, like 0.9.4's: about 1 Play in 100 at 59.94 starts within 0.1 ms of the edge
  (H is uniform over (0, B]; 1 of 379 next-by-band Plays measured). Holds of this kind so far: 0 on nights 5–7 and 1 on the
  rehearsal.

### 21.6 Decision (Robbie, 2026-11-21)

- **0.9.5 ships today's pull code.** The 0.9.5 gate gets a narrow exception: at most one edge-start hold per night, at 59.94, in a Play
  whose C+ lead guard stopped at its band edge. `rc-soak-report.py` implements it; the wording is in `Manifold-BUILD.md`, 0.9.5 release
  gate. Self-test: `~/Code/_scratch/manifold-rc095-rehearsal/tests/run-tests.sh`.
- **The sticky would-repeat band (§21.4) is the 0.9.6 candidate,** with its own soak. That soak runs per-pull logging
  (`MANIFOLD_DECKLINK_CADENCE_LOG=2`, `[PULLPHASE]`), so that each pull's branch, headroom and next-frame state are recorded. That is
  needed to confirm the change does what §21.4 infers: no steady-state pull changes, and an edge-start Play keeps its phase.
- `BUGS.md` carries it as a LOW known limitation for the 0.9.5 notes; `ROADMAP_IDEAS.md` lists the sticky band under 0.9.6.
