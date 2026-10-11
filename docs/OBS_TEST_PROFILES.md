# OBS test profiles

What each OBS profile on the test Mac sends. Read 2026-10-09 ~21:50 and **re-verified ~22:00, after
Robbie's changes**, read-only, from
`~/Library/Application Support/obs-studio/basic/profiles/*/` (`basic.ini`, `streamEncoder.json`,
`recordEncoder.json`, and only the service type from `service.json`). The effective values are
cross-checked against OBS's own logs (`…/obs-studio/logs/`) wherever a session logged them. OBS 32.2.2.

**No server URLs, stream keys, bearer tokens or passphrases appear here. Keep it that way.** A
destination is described by what it is, never by its address.

## The rule

**Never modify a tested profile for an experiment. Duplicate it** (Profile ▸ Duplicate), give the copy a
name that says what it is for, and add a row here before the first session that uses it. A profile
changed for one test and not changed back makes every later session on it measure something else.
This happened on 2026-10-09: the HEVC-to-Cloudflare attempt was made in *SRT Cloudflare* itself, and
that profile was left on Apple VT HEVC.

**Before an attended OBS session:** check the profile against its row here, and after the session
compare OBS's log for that stream (encoder block, `format:`, `YUV mode:`, audio block) with the row.
Record any difference in the session's findings.

## Profiles

Shared by every profile below unless stated otherwise:
- Canvas and output: **1920×1080, 23.976 (24000/1001)**.
- Video colour: **NV12 / Rec. 709 / Limited ("Partial")**, except HEVC SRT. SDR white level 300 and HDR
  nominal peak 1000 are stored, but unused at Rec. 709.
- Audio: **48 kHz stereo**.
- Output mode: Advanced.

| Profile | Purpose | Service / output | Video encoder and settings | Colour (format / space / range) | FPS | Audio encoder, bitrate, rate | Scene for tests |
|---|---|---|---|---|---|---|---|
| **SRT Local** | The local SRT path. Manifold's "Local SRT" bookmark dials OBS; the saved-advance sessions (§6.10, 0b-2a and v2) | Custom; SRT **listener** on all interfaces, passphrase set | Apple VT H.264 Hardware; CBR **6000**; keyframe **1 s**; profile **Main**; **B-frames off** | NV12 / 709 / Limited | 23.976 | CoreAudio AAC, **320** kb/s, 48 kHz stereo | SYNC |
| **SRT Local 2** | SRT publish to the local MediaMTX (§6.9 OBS colour re-check) | Custom; SRT **caller** to local MediaMTX (`publish` stream id) | Apple VT H.264 Hardware; CBR **6000**; keyframe **1 s**; **Main**; **B-frames off** | NV12 / 709 / Limited | 23.976 | CoreAudio AAC, **320**, 48 kHz | SYNC |
| **SRT Cloudflare** | Cloudflare Stream Live over SRT. **Unified with the others from 2026-10-09** (below) | Custom; SRT **caller** to Cloudflare, passphrase set | **Apple VT H.264 Hardware; keyframe 1 s; Main; B-frames off** (verified ~22:00). Rate control and bitrate **not stored**, so OBS's defaults apply: CBR, and 6000 by the evidence below. ⚠️ Flag 2 | NV12 / 709 / Limited | 23.976 | CoreAudio AAC, **160**, 48 kHz | SYNC |
| **HEVC SRT** | HDR over SRT: Stage 6 and any HDR session. Created 2026-10-09 21:53 | Custom; SRT **caller** to local MediaMTX, `publish` stream id (**the same path as SRT Local 2**: never stream both at once) | **Apple VT HEVC Hardware; Main 10; bitrate 12000** (rate control not stored: CBR by default); keyframe **1 s**; **B-frames off** | **P010 / Rec. 2100 (PQ) / Limited**; SDR white **203**, HDR peak **1000** | 23.976 | CoreAudio AAC, **320**, 48 kHz | SYNC |
| **WHIP Cloudflare** | Cloudflare over WHIP (WHEP tests) | WHIP to Cloudflare | Apple VT H.264 Hardware; keyframe **1 s**; Main; **B-frames off**; bitrate not stored (logged **CBR 6000** on 2026-10-06) | NV12 / 709 / Limited | 23.976 | **FFmpeg Opus, 256**, 48 kHz | SYNC |
| **MediaMTX Local** | WHIP to the local MediaMTX (WHEP tests) | WHIP to local MediaMTX | **Apple VT H.264 Hardware**; keyframe **1 s**; Main; **B-frames off**; bitrate not stored. ⚠️ Flag 3 | NV12 / 709 / Limited | 23.976 | **FFmpeg Opus, 160**, 48 kHz | SYNC |
| **NDI Bars (P2)** | §6.10 Stage 3b S1, P2: NDI chroma siting (attended 2026-10-10 21:44–21:47). **Sends NDI, not a stream.** Added 2026-10-10 after the session; verified ~22:10 (below) | **Nothing streamed:** the WHIP service it inherited (type `whip_custom`) was not started. The test path is DistroAV's **NDI Main Output "OBS PGM"**, which is global to OBS (`user.ini [NDIPlugin]`), not part of the profile | Inherited, unused: Apple VT H.264 Hardware; keyframe 1 s; Main; B-frames off; bitrate not stored | NV12 / 709 / Limited (the NDI output's own conversion is not established; Manifold received UYVY, 4:2:2) | 23.976 | Inherited, unused: FFmpeg Opus 256 | **Bars** (one Image source "Image": `build/chroma-fixtures/p2-bars.png`) |
| **Recorder** | The Audio Hijack / device-measurement recorder instance (CLAUDE.md, *Test environment*; AV_SYNC_FINDINGS.md §1.2) | **Simple** mode, recording only | x264 veryfast, 6000 (Simple mode, recording quality "same as stream"), output **1280×720** | NV12 / 709 / Limited | 23.976 | AAC 160, 48 kHz | **AV Capture** (collection "AV Capture") |

**Scenes.** Every streaming profile uses the scene collection **"Untitled"**.
- **SYNC**, the scene of every attended session in §6.10, holds one media source, "Media": the bundled
  `manifold-sync-23.976p-h264.mov`, looping.
- In the same collection, **BLIPS_NOISE** has a source "BEEPS" pointing at `manifold-sync-23.976p.mp4`,
  which no longer exists. OBS logs `Failed to open media` for it at every launch. It is not in SYNC.

**Two recording settings that are not test paths.** SRT Local and SRT Local 2 record with Apple VT HEVC
(`main42210`, 7000). WHIP and MediaMTX Local have a Simple-mode Opus fallback. Neither is used by any test.

**Evidence for the defaults.** No VT profile stores a rate-control mode, and every VT session in the logs
shows `rate_control: CBR`. WHIP Cloudflare stored no bitrate and logged `bitrate: 6000 (kbps)` on
2026-10-06. Confirm both in the encoder block of the first log of any session that relies on them.

## Flags: differences from what the §6.10 sessions used

1. **SRT Cloudflare is not what any §6.10 Cloudflare session sent, by decision.** Every Cloudflare SRT session up to
   2026-10-08 (§6.10 Stage 0 item 6; 0b-2a; 0b-2b) streamed with **x264 veryfast, CBR 6000, keyframe 1 s,
   no x264 options**. That is x264's default of **3 B-frames with a pyramid**. Manifold received H.264
   **High**, reordering up to **208 ms** (Cloudflare's output, measured: pts − dts takes 0 / 41 / 83 / 125
   / 166 / 208 ms, B-slices present, `max_num_reorder_frames` 2). On 2026-10-09 the profile was used for
   the HEVC attempt (Apple VT HEVC Main 10, P010, Rec. 2100 PQ) and left on Apple VT HEVC. It now reads
   Apple VT **H.264**, Main, B-frames off, keyframe 1 s: the change of plan below, **verified ~22:00**. No
   HEVC remains in it.
2. **SRT Cloudflare does not store its bitrate.** The plan says CBR 6000. Today that relies on OBS's
   default (above). To make it explicit and match SRT Local, set Bitrate 6000 in Settings ▸ Output ▸
   Streaming, then check the first session's log.
3. **MediaMTX Local changed encoder.** Its last logged stream (2026-10-06 19:49, WHIP to MediaMTX) used
   **x264 veryfast, CBR 6000** with Opus 160. Its encoder settings were rewritten on 2026-10-09 21:10, and
   it now reads Apple VT H.264, Main, B-frames off. No §6.10 session used it (§6.10's WHEP runs published
   with ffmpeg), but WHEP figures in `AUDIO_RESAMPLER_DESIGN.md` §18–§19 taken with this profile were
   x264.
4. **SRT Local, SRT Local 2, WHIP Cloudflare and Recorder match their logged sessions** (re-verified
   ~22:00). Their encoder
   settings files are unchanged since 2026-09-25, 2026-10-07, 2026-09-27 and 2026-10-06. Past slip, now
   gone: SRT Local 2 was left at P010 / Rec. 2100 PQ after the §6.9 re-check (2026-10-07 12:50) until
   2026-10-08 18:21, when OBS refused to start it with the H.264 encoder and it was set back. No session
   streamed with it in that state.

## Change of plan: SRT Cloudflare unified with the other profiles (Robbie, 2026-10-09)

**SRT Cloudflare is Apple VT H.264 Hardware, CBR 6000, keyframe 1 s, Main, B-frames off, AAC**, like SRT
Local. **Verified in OBS's files at ~22:00**, except the bitrate, which is not stored (flag 2).

- **Cloudflare SRT sessions before 2026-10-09 used x264 veryfast with B-frames** (up to 208 ms of
  reordering). Cloudflare figures from now on are **not directly comparable** with them. In particular:
  - the reorder term and the 259 ms cushion;
  - the "reorder 0.208 s" margins in §6.10's buffer review;
  - Cloudflare calibrations taken inside the first minute.
- **B-frame coverage now comes from the ffmpeg fixtures:** `x265_*`, `h264b_160`, `hevc_160` and `b*pyr`
  (§6.10).

## HEVC SRT: created, against its proposal

Proposed here as "HEVC Local", a duplicate of SRT Local re-pointed at the local MediaMTX. **Created by
Robbie on 2026-10-09 as "HEVC SRT"** and verified ~22:00 against the proposal:

| Setting | Proposed | In OBS |
|---|---|---|
| Destination | SRT caller, publish to local MediaMTX | ✅ SRT caller, `publish` to local MediaMTX (same path as SRT Local 2) |
| Encoder | Apple VT HEVC Hardware, Main 10, keyframe 1 s, B-frames off | ✅ |
| Bitrate | 6000 (from SRT Local) | **12000** (Robbie's "higher bitrate"); rate control not stored, CBR by default |
| Color Format / Space / Range | P010 / Rec. 2100 (PQ) / Limited | ✅ |
| SDR white / HDR peak | 203 / 1000 | ✅ |
| FPS, output | 23.976, 1920×1080 | ✅ |
| Audio | CoreAudio AAC 320, 48 kHz | ✅ |
| Scene | SYNC | ✅ (scenes are global to the collection) |

**Not yet run.** Expected at Manifold in its first session, to be checked:
- `hevc Main 10`, 4:2:0, `[SPS-COLOR]` 9-16-9.
- MDCV and CLL SEI present (§6.10, Stage 5 and Stage 6).
- Declared timing: predicted none, like ffmpeg's `hevc_videotoolbox`. If so, the frame rate is measured
  from presentation timestamps.

Changing its name, destination or any value is a new row, not an edit to this one.

## NDI Bars (P2): verified after its session

Created by Robbie on 2026-10-10 at 21:41:41 (OBS log: `Created profile 'NDI Bars (P2)' (duplicate,
NDI_Bars_P2)`) for §6.10's Stage 3b S1 P2, and used once, 21:44–21:52. Its row was added afterwards,
not before the session as the rule above asks. Read ~22:10, read-only, from the profile's files and that
session's log (`2026-10-10 21-41-16.txt`):
- **A duplicate of WHIP Cloudflare.** `basic.ini` (secrets excluded from the read) and
  `streamEncoder.json` are identical to WHIP Cloudflare's except `Name`; `service.json` is
  `whip_custom`. The log shows **no stream output** in the session, so none of those settings were used.
- **What was sent:** DistroAV (NDI runtime 6.0.1) **Main Output "OBS PGM"**, started 21:44:16, stopped
  21:52:37, 12 014 frames. Canvas 1920×1080, 24000/1001, `format: NV12`, `YUV mode: Rec. 709/Partial`.
  The NDI output is set in `user.ini`, not in the profile, so **any** profile sends it while it is on.
- **Scene:** "Bars", added 21:41:58 to the collection "Untitled", holding one Image source "Image" with
  `p2-bars.png` (two Media sources were added and removed first). It is not SYNC.
- **Matches §6.10.** S1's results name the profile "NDI Bars (P2)" and the Image source `p2-bars.png`;
  both are right.
