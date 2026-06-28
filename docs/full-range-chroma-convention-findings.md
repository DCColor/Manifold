# Full-Range Chroma Encoding: Two Incompatible Conventions

**A reproducible measurement of a systematic chroma-scaling difference in full-range Rec.709 exports**

*Prepared for technical review — feedback, correction, and perspective welcome.*

---

## TL;DR

When exporting **full-range (data levels: Full)** Rec.709 material, **DaVinci Resolve appears to write chroma scaled such that the stored values are ~2 codes hot** versus the full-swing ("PC levels," chroma spanning the full 0–255) convention. The Resolve values fit a chroma scale of **255 × 224/219 ≈ 261**, i.e. the legal chroma span (224) expanded by the *luma* full-range factor (255/219), rather than full-swing's ÷255.

A spec-following encoder (FFmpeg, `scale=out_range=full`) writes the full-swing values (chroma scale 255); Resolve writes the ~261-scaled values. Both files are tagged (or untagged) identically as "full range," so **a decoder cannot tell from metadata which chroma scale was used.** The two render ~2–4 code values apart on saturated mid-tones.

> **Note on standards references:** we use "full-swing / PC levels" (chroma in [0,255], the ÷255 path) as the reference convention, which is well-documented and is what FFmpeg's full-range output produces. We have *not* independently verified the exact normative text of ITU-T H.273's full-range chroma quantization, nor identified a standard that endorses Resolve's 255×224/219 scaling. **Confirming which convention (if either) is canonical is one of the questions below** — please correct us if the standards picture is different from how we've framed it.

This is reproducible, codec-independent, and container-independent. It is **not** a ProRes artifact, **not** a container artifact, and **not** (we believe) a decode bug in any specific player — it is a difference in how the *encoder* quantizes full-range chroma.

The practical consequence for a player: there is no single full-range chroma normalization that correctly decodes both a Resolve file and a spec file. The convention has to be a selectable interpretation, because it is undetectable from the file.

We'd value perspective on: (1) whether this characterization is correct, (2) whether one convention is "the" intended one, and (3) how a faithful player *should* handle the ambiguity.

---

## Test methodology

All values below are **raw stored Y′CbCr code values** read directly off the decoded planes, with **no range expansion, no matrix, no display transform** — i.e. the actual quantized values the encoder wrote, decoded at native bit depth and reported as 8-bit equivalents for readability.

- **Pattern:** a uniform **75% red** field (75% red was chosen deliberately — it is mid-saturation, so chroma excursions are well clear of the rails where 100% saturation clips and hides differences).
- **Color:** Rec.709 primaries / transfer / matrix throughout.
- **Decoders used for verification:** Apple VideoToolbox/AVFoundation (for ProRes), and FFmpeg/libavcodec (for DNxHR, MXF). Raw planes were read independently of any rendering pipeline.
- **Reference math:** Rec.709 75% red, through the 709 matrix, quantized per range:
  - Legal range: Y′=51, Cb=109, Cr=212 (luma span 219 → [16,235]; chroma span 224 → [16,240])
  - Full-swing ("PC levels," chroma span 255 → [0,255]): Y′=41, Cb=106, Cr=224
- Note the legal-range luma/chroma asymmetry (219 vs 224) is itself standard — luma uses [16,235] (range 219) and chroma uses [16,240] (range 224). The open question is how full range should scale chroma: to 255 (full-swing, symmetric) or by some other factor.
- Decoded values were cross-checked at 8-bit and native bit depth, and across codecs/containers, to rule out subsampling, container, and quantization artifacts.

---

## The core measurement

75% red, full range, as written by each encoder:

| Source | Codec / container | Y′ | Cb | Cr | Cr vs full-swing (224) |
|---|---|---|---|---|---|
| **FFmpeg** (full-swing) | ProRes 4444 / MOV | 40.5 | 106.0 | **223–224** | on full-swing |
| **Resolve** | ProRes 4444 XQ / MOV | 40.8 | 105.5 | **226.1** | **+2 hot** |
| **Resolve** | DNxHR HQX 10-bit / MOV | 40.8 | 105.5 | **226.0** | **+2 hot** |
| **Resolve** | DNxHR HQX 10-bit / MXF | 40.8 | 105.5 | **226.0** | **+2 hot** |

Legal-range control (75% red), for comparison — all encoders agree, exactly on spec:

| Source | Codec / container | Y′ | Cb | Cr | Cr vs legal spec (212) |
|---|---|---|---|---|---|
| FFmpeg | ProRes 4444 / MOV | 50.8 | 109.0 | 211.2 | on spec |
| Resolve | ProRes 4444 XQ / MOV | 51 | 109 | 212 | on spec |
| Resolve | DNxHR HQX / MOV | 51.0 | 108.8 | 212.0 | on spec |
| Resolve | DNxHR HQX / MXF | 51.0 | 108.8 | 212.0 | on spec |

**Legal range is unambiguous — every encoder, codec, and container produces the spec values.** The divergence is entirely in *full* range.

---

## The chroma-scale decomposition

The difference is explained exactly by which normalization factor is applied to the chroma excursion.

For 75% red, the normalized chroma magnitude is **0.375** (a known quantity). The stored chroma excursion (distance from neutral 128) for each file:

| Convention | Chroma scale | Excursion (0.375 × scale) | Stored Cr (128 + excursion) |
|---|---|---|---|
| **Legal** | 224 | 84 | 212 |
| **Full-swing (FFmpeg)** | 255 | 95 | 224 (223.6) |
| **Full — Resolve** | ~261 (= 255 × 224/219) | 98 | 226 |

The three excursions measured — **84 (legal), 95 (FFmpeg full-swing), 98 (Resolve full)** — land exactly on these three scales.

**The Resolve scale, 255 × 224/219 ≈ 261, is the legal chroma span (224) expanded by the *luma* full-range factor (255/219).** In other words: full-range expansion appears to have been applied to chroma using the luma normalization (219→255) rather than the chroma normalization (224→255). Whether that is intentional or incidental is one of the things we'd like perspective on.

Net difference between the two full-range conventions on a saturated primary: **~2 code values in stored chroma**, which — amplified by the 1.5748 Cr→R coefficient — becomes **~3–4 code values in rendered R** (e.g. 75% red renders ~191 under the Resolve convention and ~195 under the full-swing convention from the *same* Resolve-authored file, or ~190 from a full-swing-authored file decoded full-swing).

---

## Why it's undetectable from metadata

We checked every signaling path:

| Format | Range signaling | Conveys *which* full-range chroma scale? |
|---|---|---|
| **ProRes (MOV)** | **None** — no `FullRangeVideo` extension is written, by Resolve *or* by FFmpeg's `prores_ks` (which ignored `-color_range pc`). ProRes appears to carry no full-range flag through these encoders. | No |
| **DNxHR (MOV)** | Avid **ACLR** atom: Full=2 / Legal=1 — a clean, readable range tag | No — "full" only |
| **DNxHR (MXF)** | Same ACLR (2/1), preserved in the MXF/CDCI descriptor, read identically by libav | No — "full" only |

So:

- **ProRes carries no range tag at all** — a player cannot even tell full from legal without the user asserting it, let alone which chroma convention.
- **DNxHR/MXF carry a trustworthy range tag** (full vs legal), but the tag says *"full range,"* not *"full range, Resolve chroma scale"* vs *"full range, full-swing chroma scale."*

There is no field, in any of these formats, that distinguishes the two full-range chroma conventions. They are byte-different in the essence but identical (or absent) in signaling.

---

## What was ruled out

- **Not a container artifact.** The +2 appears identically in MOV and MXF. The MXF-wrapped and MOV-wrapped DNxHR essence decoded **pixel-for-pixel identical** (226.0 in both) — the container is a pure passthrough.
- **Not a codec artifact.** The +2 appears in ProRes 4444 XQ and DNxHR HQX alike (226.1 vs 226.0). Legal range is spec-exact in both.
- **Not subsampling/precision.** Confirmed at 8-bit and native bit depth (12-bit ProRes, 10-bit DNxHR), and on uniform fields where subsampling is a non-factor.
- **Not the "retain sub-black/super-white" setting.** A retained-vs-non-retained pair decoded byte-identical at these in-range patches (the setting only affects out-of-range excursions, which a 75%/100% pattern doesn't contain).
- **Not a decode/render bug.** These are *stored* values, read raw off the planes by independent decoders (VideoToolbox and libavcodec), before any matrix/expansion/display step. The encoders genuinely wrote different bytes.

---

## The reproduction recipe

To reproduce the spec reference and compare:

```bash
# Spec-correct full-range 75% red (H.273), via FFmpeg:
ffmpeg -f lavfi -i color=c=0xBF0000:s=1920x1080 \
  -vf "format=yuv444p,scale=out_range=full" \
  -c:v prores_ks -profile:v 4 \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range pc \
  -frames:v 1 full_spec.mov
# (Note: prores_ks does not write a FullRangeVideo flag; range is inferred from values.)
```

Then export the *same* 75% red, **data levels: Full**, Rec.709, from Resolve (ProRes 4444 XQ and/or DNxHR HQX, MOV and/or MXF), and read raw Y′CbCr from both with any decoder that exposes pre-matrix planes. The Resolve file's 75%-red Cr will read ~226; the FFmpeg file's ~224.

---

## Questions we'd value perspective on

1. **Is this characterization correct?** Specifically, is the Resolve full-range chroma genuinely scaled by 255/219 (luma factor) rather than 255/224 (chroma factor)? We've measured it consistently, but would welcome confirmation or correction from someone with visibility into the encoder.

2. **What is the canonical full-range chroma convention** — and which standard defines it? We've used "full-swing / PC levels" (chroma scaled to [0,255], the ÷255 path → 224) as our reference because it's well-documented and is what FFmpeg produces, but we have *not* verified the exact normative text (e.g. the relevant ITU-T H.273 quantization equations for full range). Is the ÷255 path the intended one? Is there a competing or historical convention that produces the 255×224/219-style chroma scaling Resolve appears to use? **We'd genuinely value being pointed at the authoritative reference here** — this is the claim we're least certain of.

3. **Round-tripping.** Resolve presumably decodes its own full-range exports with the matching inverse, so its files round-trip correctly *within* Resolve. Is that the intent — a self-consistent internal convention — accepting that other decoders (which follow the full-swing ÷255 path) will read the files ~2 codes hot?

4. **ProRes range signaling.** Is the absence of any full-range flag in ProRes expected/by-design (i.e. ProRes is intended as a legal-range codec and full-range ProRes is out-of-spec), or is there a signaling path we're missing? This bears directly on whether a player should treat full-range ProRes as a supported case at all.

5. **For a faithful player:** given that the convention is undetectable from the file, what is the right default? Match the dominant authoring tool (Resolve) so the common case looks right, at the cost of mis-rendering full-swing-conformant files? Decode full-swing per the documented convention and accept that Resolve deliveries read hot? Expose a user-selectable interpretation? We've leaned toward "selectable, with a sensible default," but would welcome a stronger opinion.

---

## Summary table

| | Legal | Full-swing (FFmpeg) | Full (Resolve) |
|---|---|---|---|
| 75% red Cr | 212 | 224 | 226 |
| Chroma scale | 224 | 255 | ~261 (255×224/219) |
| Renders 75% red R≈ | 191 | 190 | 191* |
| Range tag (ProRes) | none | none | none |
| Range tag (DNxHR/MXF) | ACLR=1 | — | ACLR=2 |
| Distinguishable from metadata? | yes (vs full) | **no — same "full" tag as Resolve** | **no — same "full" tag as full-swing** |

*\*The Resolve file renders ~191 only when decoded with the matching (Resolve) chroma scale; decoded full-swing (÷255) it renders ~195 (hot).*

---

*All measurements are raw stored code values from independent decoders, reproducible with the recipe above. Corrections and perspective genuinely welcome — the goal is to get the color science right, not to assign fault to any tool.*
