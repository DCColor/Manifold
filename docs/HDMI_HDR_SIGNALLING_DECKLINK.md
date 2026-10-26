# DeckLink 8K Pro: HDR signalling on HDMI (HLG and SDR)

**From:** Robbie Carman (DC Color / Manifold)
**Asking:** whether what we see is expected HDMI / CTA-861 behaviour, a DeckLink driver limitation, or an artefact of our test setup.

## Short version

Our player sends per-frame HDR signalling to a DeckLink 8K Pro. On **SDI** everything arrives correctly: PQ, HLG and SDR, including ST 2108-1 static metadata on PQ. On **HDMI**, PQ arrives exactly (EOTF, colorimetry and all static-metadata values), but:

1. **HLG is never signalled.** No HLG EOTF reaches the receiver; it keeps the previous PQ state.
2. **SDR after PQ is often not signalled when the colorimetry also changes.** For example, Rec.2020 PQ followed by Rec.709 SDR: the receiver keeps reporting the old PQ infoframe values, except when the link drops for long at the change (13–14 frames rather than 1–2; see *A clue*, below). Rec.2020 PQ followed by Rec.2020 SDR does reset correctly.

We can't tell whether the card isn't sending the change or whether our receiver (the same card's HDMI input) is latching the old values.

## Setup

- **Card:** Blackmagic DeckLink 8K Pro, in a Thunderbolt 3 PCIe chassis on a Mac Studio.
- **Profile:** `1dfd`, one full-duplex sub-device with SDI and HDMI in both directions (device 0). HDMI ports are HDMI 2.0 on the daughter card; cable is rated 48 Gb/s.
- **Driver:** Desktop Video 16.4 (macOS).
- **SDK headers compiled against:** Desktop Video SDK 16.0.
- **Loopback:** HDMI out of device 0 into HDMI in of device 0, and separately SDI out into SDI in. Captured through the SDK.
- **Receiver EDID:** the card's HDMI output reads the EDID of its own input: 256 bytes, manufacturer `BMD`, name "BMD HDMI". Its HDR static metadata block lists **traditional HDR (EOTF 1)** and **PQ**, but **not HLG**.
- **Input selection:** for the HDMI captures the input connection was set to HDMI per run via `IDeckLinkConfiguration` (`bmdDeckLinkConfigVideoInputConnection`), never written to preferences, and restored to SDI afterwards.

## What the player sets per frame

Through the SDK's frame metadata extensions, on every scheduled frame:

- **Colorspace:** Rec.709 or Rec.2020 (`bmdDeckLinkFrameMetadataColorspace`).
- **EOTF:** 0 = SDR, 2 = PQ, 3 = HLG (`bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc`).
- **HDR flag** (`bmdFrameContainsHDRMetadata`): set on PQ frames, with the static metadata fields filled (mastering display primaries, white point, max/min luminance, MaxCLL, MaxFALL). Cleared on HLG and SDR frames.

Pixel format is 10-bit YCbCr 4:2:2 (v210).

## Results

### Picture

Byte-identical on both outputs: HDMI 939/939 frames and SDI 529/529 frames matched what the player handed the card. HDMI carried the full 10 bits, even though the card's HDMI output status reports "8-bit".

### Signalling, as read back from the input

| Source sent | SDI received | HDMI received |
|---|---|---|
| Rec.2020 PQ with metadata (file values) | Correct; ST 2108-1 packet (VANC line 9) with exact values | Correct; all 12 static-metadata values exact |
| Rec.2020 PQ, no file metadata (player defaults) | Correct, defaults in ST 2108-1 | Correct, defaults |
| Rec.2020 HLG (EOTF 3, flag clear) | HLG, no ST 2108-1 packet | **Previous PQ state** (EOTF 2, flag set, previous file's values) |
| Rec.2020 SDR (EOTF 0, flag clear), after PQ | SDR | **Previous PQ state** in our main run (see below) |
| Rec.709 SDR (EOTF 0, flag clear), after PQ | SDR | **Previous PQ state** |

## What we tried for HLG

With a small standalone test-signal tool (player closed), on HDMI:

- EOTF 3 with the HDR flag **clear** and **set**.
- With static metadata filled, absent, and explicitly zeroed.
- At Rec.2020 and at Rec.709 colorspace.
- With the card's Rec.2020 output configuration held on for the test only.

**None produced HLG at the HDMI input.** EOTF 1 (traditional HDR) *does* arrive, and EOTF 1 is in the input's EDID while HLG is not.

On SDI, the same test signal arrived as HLG.

**Our guess:** the card only sends EOTFs the sink's EDID advertises (as CTA-861 expects of a source), so HLG is withheld from this particular receiver. Not established; we didn't write the input's EDID to test it.

## What we tried for SDR after PQ

The obvious "reset" is to tag SDR frames with the **HDR flag set and EOTF 0**, so the card sends a DRM InfoFrame saying SDR. Measured within one output session:

| Change | Flag clear (current) | Flag set + EOTF 0 |
|---|---|---|
| Rec.2020 PQ → Rec.2020 SDR | Resets to SDR | Resets to SDR |
| Rec.2020 PQ → Rec.709 SDR | Stays on old PQ state | **Stays on old PQ state** |
| Rec.2020 HLG → SDR | Stays on old PQ state | **Stays on old PQ state** |

So the flag makes no difference. (An earlier result suggesting "flag set resets it" turned out to be the card passing its input through between separate test sessions, not a real reset.) On SDI, setting the flag on SDR frames is harmless: no ST 2108-1 packet, signal unchanged.

Restarting output between files didn't reliably reset the HDMI input either: PQ → HLG stayed on PQ every time, and
PQ → Rec.709 SDR reset only when the link dropped for long (next sections). The one exception is **HLG → Rec.2020 SDR,
which does reset across an output restart** (4 of 4: our test tool and our player, each under both idle settings),
though never within one session.

## Another HDMI observation

A same-mode **colorimetry** change drops the HDMI signal at the input briefly: Rec.2020 → Rec.709 loses either 1–2 frames or 13–14 (below); Rec.709 → Rec.2020 loses about 14 frames, then two partially written frames before a clean one. EOTF-only changes cause no dropout. SDI shows no dropout.

## The card's idle-output setting

We also checked whether the card's **idle output** setting (`bmdDeckLinkConfigVideoOutputIdleOperation`: black, or
last frame) explains any of this. It was held at each value for a block of runs by a small tool (read first, never
written to preferences, restored after; the card's own setting is black), and the same cases were run under each:
PQ → Rec.709 SDR, PQ → HLG and PQ → HLG → Rec.2020 SDR, within one output session and across an output stop and
restart, with the test tool and with our player.

**Every case read the same under both settings.** It does not explain the stale signalling.

One limit of the loopback: while a capture is running, the card passes its HDMI input back out of its output during a
stop (`bmdDeckLinkConfigCapturePassThroughMode` is clean pass-through). So during a stop the input sees itself, not
the idle setting, and a loopback cannot show what the idle setting does to a real display.

## A clue: the dropout's length predicts the reset

PQ Rec.2020 → SDR Rec.709 at the same mode was run 18 times (within a session and across a restart, test tool and
player, both idle settings). The signal sent was the same each time. What the input reported afterwards followed
**how long the link dropped at the change**, and nothing else we varied:

| Dropout at the change | Runs | Input afterwards |
|---|---|---|
| 13–14 frames | 10 | **SDR** (EOTF 0, no values) — every time |
| 1–2 frames | 8 | **previous PQ state** — every time |

Within one session, the test tool's 12 runs were long 3 of 6 times with idle = black and 4 of 6 with idle = last
frame: the setting does not choose the length either.

Since the transmitted signalling did not change between runs, this points at the **receiving side**: after a long
loss of lock the input re-reads the InfoFrames; after a short one it keeps what it had latched. That fits
possibility 2 below. It is a clue, not a proof: the transmitter's own resync could also differ between short and long
dropouts.

## The two possibilities we can't separate

Because the same card is on both ends, we can't tell:

1. **The card isn't sending the change.** It sends no DRM InfoFrame for HLG, and doesn't send EOTF 0 when colorimetry changes alongside the EOTF.
2. **The card is sending it, but its HDMI input latches the last infoframe** it saw and keeps reporting it until the link drops. The input did keep reporting old values until relock, which fits this.

## Questions

1. Under CTA-861, should a source send a DRM InfoFrame with **EOTF 3 (HLG)** to a sink whose EDID HDR static metadata block doesn't list HLG? Does the DeckLink follow the sink's EDID for this?
2. When a source switches from PQ to SDR on HDMI, is it expected to **send EOTF 0 for a period** before stopping the DRM InfoFrame, or simply stop? What does a typical TV do when the infoframe just stops?
3. Is there anything in the DeckLink SDK (configuration items, HDMI-specific settings) that controls DRM InfoFrame behaviour that we might have missed?
4. Does the DeckLink HDMI **input** latch the last DRM InfoFrame when the source stops sending it? Is it a reliable receiver for this kind of test?
5. Is the signal dropout on a same-mode colorimetry change (AVI InfoFrame change) normal for HDMI receivers?

## Next step on our side

Parked until we can change the receiver or the machine. Then:

- Over HDMI into an LG TV that advertises HLG: play PQ, then HLG, then Rec.709 SDR, and watch whether the TV's HDR indicator and picture mode follow each change.
- The same loopback on a second Mac with a DeckLink, to separate this card and machine from the behaviour.
- With the SDK headers updated to match the installed Desktop Video 16.4 driver (we compile against 16.0).

An HDMI analyser, if available, would settle what's actually on the wire.
