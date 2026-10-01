# WHEP Sender Timestamp Robustness: Post-Release Design

Status: proposed, post-release. Written 2026-09-30, at the close of the WHEP lip-sync investigation (AUDIO_RESAMPLER_DESIGN.md §18.20–§18.25, AV_SYNC_FINDINGS.md §6.7–§6.9).

## 1. The problem

OBS 32.2.2's WHIP output stamps 23.976 fps video about 66.6 ppm fast.

- OBS advances each video frame's RTP timestamp by `round(frame duration × 90000)` (libdatachannel v0.24.2 `getTimestampFromSeconds`).
- A 23.976 frame is exactly 3753.75 ticks. OBS measures it in whole microseconds (41,708 or 41,709 µs), and both round to 3754 ticks, every frame.
- The error is 0.25 / 3753.75 = 66.6 ppm. It accumulates because the rounded steps are summed instead of computed from total elapsed time.
- OBS's canvas runs at the exact rate internally (`24000/1001` in its log). The error is only in the WHIP RTP stamping. OBS recordings are correct.

Measured (Sep 30), video − audio RTP clock rate against wall clock: +66.5, +67.5 and +66.7 ppm in three sessions, against +66.6 ppm predicted. Content moved −92.1, −92.05 and −92.06 ms over 1380 s on the received timestamps, against −91.9 ms predicted.

Expected by arithmetic and simulation of OBS's stamping, not measured:
- 24, 25, 29.97, 30, 50 and 60 fps give whole-tick frames, so no error.
- 59.94 (1501.5 ticks): the µs durations step 16683/16683/16684, which round to 1501/1501/1502 ticks (mean 1501.333). That's a consistent −111 ppm, video stamped slow, so it drifts the opposite way to 23.976, and faster.

Confirmed in source (OBS 32.2.2 `plugins/obs-webrtc/whip-output.cpp` lines 127–134 and 707–713; libdatachannel v0.24.2 `getTimestampFromSeconds` rounds). OBS sends without `FrameInfo`, so the packetizer's elapsed-time path isn't used.

## 2. Effect on the viewer

Whether the viewer sees it depends on the relay, not on Manifold.

- **The relay supplies usable sender reports** (SRs consistent with its timestamps and based on real time). Manifold's SR line fit follows the +66.6 ppm slope and cancels the error, so lip-sync holds.
- **It doesn't.** Lip-sync starts correct and drifts steadily: about 4 ms per minute, about 92 ms at 23 min, and about 240 ms per hour. Reconnecting resets it. A fixed audio offset can't compensate, because the error grows.

| Relay | SR behaviour | Result | Basis |
|---|---|---|---|
| Cloudflare Stream WHEP | re-stamps, SRs consistent | correct (4.5 h; SDI → OBS sender) | measured |
| MediaMTX, `useAbsoluteTimestamp: true` | passes OBS's SRs through | correct (two OBS sources) | measured |
| MediaMTX, default | arrival-time SRs with a one-way ratchet (`internal/ntpestimator`); catches only part of the slope | drifts | measured |
| SFUs that forward or regenerate SRs from real time (Pion-based, e.g. Broadcast Box; LiveKit-style) | smooth, real-time-based | probably correct | guess |
| Relays that drop SRs | none | drifts ~240 ms/h | guess |
| Transcoding relays | depends on how timestamps are rebuilt | unknown | guess |

Not affected: OBS over RTMP or SRT (different timestamp code), and OBS recordings.

## 3. Release handling (current)

- Manifold follows SRs (the SR line fit, §15, plus the staircase handling).
- The level hold is observe-only (§18.20–§18.21; its premise failed on MediaMTX).
- Known limitation (BUGS.md, RELEASE_NOTES.md): default MediaMTX with OBS WHIP at 23.976 drifts. Remedy: `useAbsoluteTimestamp: true`. Cloudflare corrects it automatically.

## 4. Proposed work

### 4.1 Per-track arrival-rate estimation (main item)

Estimate each track's RTP clock rate against Manifold's local receive clock, independently of SRs, so a mis-stamped sender is corrected even when the relay supplies no usable SRs.

- **Method (to evaluate):** fit a line to the minimum-delay envelope of `(local receive time − RTP timestamp / clock rate)` per track, over long windows (≥ 600 s). Queuing delay only adds to it, so the lower envelope tracks the sender's clock while rejecting jitter. This is MediaMTX's ratchet done properly: fitted as a line instead of only ever moving earlier.
- **Arbitration with SRs:**
  - Where the SR slope and the arrival estimate agree within tolerance, keep the SR line. This must not change any verified Cloudflare or MediaMTX-abs result.
  - Where SRs are absent, staircased (an arrival ratchet), or disagree persistently, use the arrival estimate for the A/V slope.
  - Log which source is in use, and why.
- **Risks:**
  - A network rate change or queue build-up (bufferbloat) looks like clock skew.
  - Route changes produce steps.
  - Convergence is slow (minutes).
  - Correcting twice when a relay already corrects.
  - Interaction with LiveClock's video rate control.
- **Logging prerequisite:** per-packet (or sampled) receive time and RTP timestamp per track, DEBUG only. `[WHEP-SR-RAW]` covers SRs only.

### 4.2 OBS 23.976 signature detector (diagnostic)

If every video RTP increment is exactly 3754 at a nominal 23.976, flag "sender video timestamps run 66.6 ppm fast (known OBS WHIP issue)" in the log and stream info.

- It switches itself off: a fixed OBS would alternate 3753/3754 increments and stop triggering it.
- It's preferred as a diagnostic over a targeted correction, since 4.1 corrects the general case.

### 4.3 Report upstream

File with obs-studio (obs-webrtc output, which uses libdatachannel's `getTimestampFromSeconds`). Proposed fix: compute each RTP timestamp from total elapsed time (`pts × 90000 × den / num`, or the equivalent rational) instead of summing per-frame rounded durations. Include the arithmetic and the measured +66.5–67.5 ppm.

### 4.4 Other relays (homelab)

Run SRS and Broadcast Box (Docker on Proxmox) alongside MediaMTX, each with the DeckLink sender:
- at 23.976, and at 25 as a control (expected: no error)
- one 59.94 run, to confirm the predicted −111 ppm

This turns the guesses in §2 into measurements.

### 4.5 Loose ends

- The 16:47 MediaMTX run (Sep 30) held content at −1.3 ms when the bug predicts about −92 ms. Unexplained. Re-examine once per-packet logging (4.1) exists.
- Measurement rig: control 1 read +2.47 ms at 19:06 and +27.81 ms at 20:14 on Sep 30, a 25 ms launch-to-launch difference in the capture chain. Find the cause before relying on absolute figures.
- Level hold: decide whether to remove it or rework it once 4.1 exists. Its premise (queue level = lip-sync) is false wherever timestamps are mis-stamped.

## 5. Acceptance criteria for 4.1

- **Replay:** every logged WHEP session (Cloudflare, MediaMTX default, MediaMTX abs) gives an applied-offset trajectory within ±2 ms of today's fit wherever today's fit was verified correct.
- **Live soak: default MediaMTX, DeckLink sender, OBS WHIP 23.976.** Device B − A within ±10 ms (today: drifts about +44 to +92 ms).
- **Live soak: Cloudflare, DeckLink sender.** Unchanged, B − A within ±10 ms.
- **Live soak: MediaMTX abs.** Unchanged.
- **One 60–90 min session** on default MediaMTX, within ±10 ms throughout.

## 6. References

- AUDIO_RESAMPLER_DESIGN.md:
  - §15: SR line fit
  - §18.20–§18.21: the level hold
  - §18.22: step-free (rejected)
  - §18.23: useAbsoluteTimestamp
  - §18.24: DeckLink → Cloudflare
  - §18.25: root cause
- AV_SYNC_FINDINGS.md §6.7–§6.9
- MediaMTX: absolute timestamps docs; issue #5593 / PR #5597 (fixed, not the cause)
