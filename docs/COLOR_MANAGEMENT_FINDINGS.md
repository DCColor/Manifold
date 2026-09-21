# Color Management: What macOS Actually Hands the Display for SDR

**A byte-level measurement of the transfer function `CVImageBufferCreateColorSpaceFromAttachments` produces, and what it means for a reference monitoring tool**

*A knowledge document. Measured fact, inference, and open question are labelled separately throughout — a reader should never have to guess which is which.*

---

## TL;DR

Manifold tags `CAMetalLayer.colorspace` from `CVImageBufferCreateColorSpaceFromAttachments`
(`MetalVideoRenderer.makeColorSpace`). For a correctly-tagged Rec.709 file that call returns
`kCGColorSpaceCoreMedia709`, whose ICC profile carries **a single power law, gamma 1.9609375** —
not the piecewise BT.709 curve, and not BT.1886's 2.4.

**This is measured, from the profile bytes.** The TRC tags are `curveType` with `count=1`, which is
ICC's one-gamma encoding and is structurally incapable of expressing a piecewise function.

The same approximation applies to **P3**. PQ and HLG get modern v4 profiles that declare their
transfer exactly. So the simplification is **SDR-wide, and inherited rather than chosen** — nothing
in `makeColorSpace` selects it.

**The load-bearing conclusion:** no combination of colour tags can produce a 2.4 SDR display
transform through this call. A reference transform requires applying the EOTF **explicitly in the
shader**, not delegating it to the layer's colorspace.

---

## 1. Method

`makeColorSpace` is a pure function of three CICP integers — it takes no file, no decoder, and no
app state. So it was reproduced outside Manifold rather than instrumented inside it:

1. `makeColorSpace` copied **verbatim** into a standalone binary, calling the same
   `CVImageBufferCreateColorSpaceFromAttachments` with the same attachment constants.
2. `CGColorSpaceCopyName` read, and identity established with **`CFEqual` against the actual
   `CGColorSpace` constants** — never inferred from the name string.
3. `CGColorSpaceCopyICCData` written to disk.
4. Profiles parsed byte-wise by an **independent Python ICC parser** (header, tag table,
   `curv`/`para` discrimination, `cicp`, colorants, `chad`), written without reference to the Swift
   side.

Two independent implementations agreed to the digit. Both are committed
(see [§8](#8-reproduction)), and the committed script regenerates the committed fixture
byte-for-byte (SHA-256 verified).

**Environment:** macOS 26.5.1 (build 25F80), Apple Swift 6.3.3, Python 3.14.3, Apple Silicon.
**Not verified across OS versions.** These profiles are system assets and Apple has revised them
before — the v2.1 SDR profiles are stamped 2007, the v4.0 HDR ones 2022. A future macOS could
change any of this, and the reproduction recipe exists so the claim can be re-checked rather than
trusted.

---

## 2. The core measurement — Rec.709

`makeColorSpace(primaries: 1, transfer: 1, matrix: 1)`:

| Property | Value |
|---|---|
| `CGColorSpaceCopyName` | `kCGColorSpaceCoreMedia709` |
| Identity | `CFEqual` == `kCGColorSpaceCoreMedia709` (**not** `kCGColorSpaceITUR_709`) |
| ICC size / version | 660 bytes, **v2.1** |
| `desc` | `HDTV` |
| `cprt` | `Copyright 2007 Apple Inc.` |
| Tags (12) | `bTRC bXYZ chad cprt desc gTRC gXYZ ndin rTRC rXYZ vcgt wtpt` |
| `rTRC` / `gTRC` / `bTRC` | `curveType 'curv'`, **`count=1`** |
| Encoded gamma | `0x01F6` = 502/256 = **1.9609375 exactly** |

`count=1` is ICC's `u8Fixed8Number` single-gamma form: one byte pair, one power law. **There is no
`para` tag and no piecewise segment, and `curveType count=1` cannot express one** — the absence of
the BT.709 toe is structural, not a matter of coefficient choice.

### Fit against candidate transfer functions

257 samples over [0,1], max absolute deviation:

| Candidate | Max deviation | |
|---|---|---|
| **x^1.961** | **1.17e-05** | ← match |
| piecewise BT.709 EOTF | 1.29e-02 | |
| x^2.2 | 4.23e-02 | |
| sRGB EOTF | 4.96e-02 | |
| x^2.4 (BT.1886) | 7.42e-02 | |

### The peak error understates it

1.3% peak deviation sounds negligible. It is not, because the divergence concentrates in shadow —
exactly where a monitoring judgement gets made:

| Code value | `curv` γ1.9609 | piecewise BT.709 | ratio |
|---|---|---|---|
| 0.010 | 0.000120 | 0.002222 | **18.6×** |
| 0.020 | 0.000466 | 0.004444 | 9.5× |
| 0.040 | 0.001814 | 0.008889 | **4.9×** |
| 0.081 | 0.007238 | 0.017945 | 2.5× |
| 0.200 | 0.042595 | 0.055427 | 1.3× |

At 4% code value the power law calls for roughly **one fifth** the light the piecewise curve does;
at 1%, about **one eighteenth**.

> **Scope of this claim — measured vs. inferred.** These ratios are computed from the two *curves*.
> They are **not** measured light output from a display, and no photometer was involved. What is
> measured is what the profile asks for; what a given display actually emits after ColorSync
> composites through its own profile is a further step **not measured here**.

---

## 3. Scope of the simplification — SDR-wide, not 709-specific

| CICP (primaries, transfer, matrix) | Name returned | ICC | Transfer carried as |
|---|---|---|---|
| (1, 1, 1) — 709 | `kCGColorSpaceCoreMedia709` | v2.1, `HDTV`, 2007 | `curv count=1`, **γ 1.9609375** |
| (12, 1, 1) — P3 | **`nil` — unnamed** | v2.1, `Apple P3`, 2007 | `curv count=1`, **γ 1.9609375** |
| (9, 16, 9) — PQ | `kCGColorSpaceITUR_2100_PQ` | v4.0, 2022 | `cicp` transfer=**16** + `A2B0`/`B2A0` LUTs; **no TRC tag** |
| (9, 18, 9) — HLG | `kCGColorSpaceITUR_2100_HLG` | v4.0, 2022 | `cicp` transfer=**18** + LUTs; **no TRC tag**; `lumi`=203 cd/m² |
| (nil, nil, nil) — untagged fallback | `kCGColorSpaceCoreMedia709` | **byte-identical to (1,1,1)** | as 709 |

Measured details worth recording:

- **P3 is not a special case.** Same curve, wider primaries. It is the *same* 1.9609375 power law.
- **The untagged fallback is byte-identical to the 709 path** — same SHA-256, verified with `cmp`.
  The comment in `makeColorSpace` ("absent / nil / unknown → 709") is accurate, including that it
  inherits the same approximation.
- **The HDR profiles declare their transfer exactly.** A `cicp` tag states the CICP transfer code
  (16 / 18) and the curve lives in an `mAB `/`mBA ` LUT pair. There is nothing approximated to find.
- **The P3 space is anonymous.** `CGColorSpaceCopyName` returns nil, and `CFEqual` matches **none**
  of the tested constants — including `kCGColorSpaceDisplayP3`. Its identity is recoverable only
  from the ICC `desc` string, `Apple P3`.

**Inference (not measured):** the two regimes correspond to two eras of Apple system profile — a
2007 v2 display-profile lineage for SDR (note the `vcgt` and `ndin` tags, which belong to display
profiles rather than content profiles) and a 2022 v4 colorimetric lineage for HDR. That reading is
consistent with the bytes but is not established by them.

### The consequence

**No tag combination reaches a 2.4 SDR display transform through this call.** The SDR arms return a
γ1.9609 profile; the HDR arms return PQ/HLG. There is no input to `makeColorSpace` that yields
BT.1886. A reference transform therefore has to be applied **explicitly in the shader**, with the
layer colorspace used for something else or not at all.

---

## 4. Where 1.9609 comes from

> **This section is sourced from published standards and community documentation. It was NOT
> measured here.** It is recorded because it makes the measurement above legible — an unexplained
> 1.9609375 looks like a bug, and it is not one. Treat the history as context, not as evidence.

BT.709 defines an **OETF** — a camera encoding curve — and deliberately never defined an EOTF.
Apple inverted the camera curve and used the inverse as the display transform. Two derivations
converge on the same number:

- **End-to-end system gamma.** 1.2 / 2.35 = 0.51 ≈ 1/1.9608 — the correction against a 2.35-gamma
  CRT for a 1.2 end-to-end system gamma, the dim-surround convention of the era.
- **Curve fit.** The 709 OETF's piecewise shape is closely approximated by a pure power near 1/1.95.

BT.1886's 2.4 came later, as the reference EOTF modelling actual CRT behaviour — which is why it,
and not the inverted OETF, is what a reference display is expected to implement.

**This is ColorSync, not QuickTime.** It affects every colour-managed client: QuickTime Player,
Preview, Safari, Chrome, Final Cut Pro. Firefox, VLC, and mpv bypass ColorSync and therefore render
closer to the reference — **by accident of architecture, not by intent.**

---

## 5. Video Village Screen — measured behaviour, for comparison

Screen exposes four modes: **Bypass**, **Match QuickTime**, **Embedded**, **Custom**.

**Method:** the same paused frame screenshotted per mode, then compared on a waveform in a
**non-colour-managed Resolve project** (so the comparison path adds no transform of its own). This
is a **visual/waveform comparison, not a byte-level one** — it establishes identity and difference
between modes, not absolute correctness of any mode.

Measured:

| Display profile | Bypass | Match QuickTime | Embedded | Custom @ 709/2.4 |
|---|---|---|---|---|
| **Calibrated to Rec.709 gamma 2.4** | differs, clearly | — identical — | — identical — | — identical — |
| **Switched to sRGB** | differs | — identical — | — identical — | **diverges** |

**Inference from that pattern:** Match QuickTime and Embedded both defer to ColorSync, and therefore
*cannot* differ on SDR content — because ColorSync has exactly one SDR profile, which is the
γ1.9609 one measured in §2. **Custom is Screen's only explicit-transform path.** A destination
display profile that is already 2.4 masks the difference entirely.

Also measured: **Screen's modes diverge dramatically on PQ content.** That is consistent with §3 —
the transfer tag there selects a genuinely different (v4) profile, so the modes have something real
to disagree about. The modes are real upstream; it is only the **SDR display endpoint** that
collapses them.

> **Not verified:** Screen's internals. The "defers to ColorSync" reading is inferred from
> behaviour, not from its source or documentation.

### The trap this created

On a correctly profiled display the entire issue is **nearly invisible** — every mode that matters
agrees, and the difference only appears when the display profile is changed to something that is not
already 2.4. That is why this took a full session to see.

**The design consequence: a reference tool must not depend on the user having already calibrated
their display in order for its transform to be correct.** Correctness that is contingent on the
destination profile is not correctness; it is a coincidence that happens to be common.

---

## 6. Decisions taken

Mode naming for Manifold — **OS / Reference / Bypass**:

| Mode | Behaviour | Notes |
|---|---|---|
| **OS** | Today's behaviour: ColorSync's SDR profile (γ1.9609). | **Default.** What QuickTime, Safari, and Preview show. |
| **Reference** | Explicit BT.1886 2.4 applied **in the shader**. | Correct regardless of display profile. |
| **Bypass** | No colorspace on the layer; code values land wherever the display profile puts them. | |

**Rejected names, and why:**

- **"Embedded"** — reading the file's tags is what *every* mode does. The name points at the wrong
  axis; the axis that actually varies is the display transform.
- **"Match QuickTime"** — loaded, and it names one application for a **system-wide** ColorSync
  behaviour that equally describes Safari, Preview, and Final Cut.

**Deferred:** "Custom" (assert primaries / transfer / matrix explicitly) belongs with the unified
colour-interpretation control, alongside the existing stream colorimetry override. Same family —
it should not be built twice.

⚠️ **When Custom is built, Manifold must keep matrix separable from primaries.** Screen's Custom
does not, and `makeColorSpace`'s enumerated-pair structure does not either (see §7).

---

### 6.1 What the modes are *for* — decided 2026-09-21

*Design decisions, not measurements. Recorded here because the mode set above is meaningless
without them, and because "are we only doing this to be like Screen?" is a question that deserves a
written answer.*

**The modes are a comparison instrument, not a preference.** Each answers a different question, and
the *delta between them* is the output:

| Mode | The question it answers |
|---|---|
| **OS** | What will my client see? |
| **Reference** | What is actually in this file? |
| **Bypass** | What are the numbers, with nothing interpreting them? |

If OS and Reference agree, the file survives the trip to a viewer who is not colour-managed the way
you are. If Reference holds shadow detail that OS lifts, that difference **is** the risk — and on a
mistagged file it can be dramatic. This is the original "QuickTime gamma bump" diagnostic, correctly
understood: it is ColorSync-wide (§4), not a QuickTime quirk.

**Bypass is the mode with no opinion, and that is its job.** OS and Reference both trust the file's
tags, so a mistagged file gets a confidently wrong transform in both and neither will say so. Bypass
is the only path where nothing interprets anything — which makes it the control condition. When OS
and Reference disagree, Bypass tells you which one moved.

⚠️ **Bypass is never *correct*, only diagnostic**, and on a display already calibrated to 709/2.4 it
is close to Reference by coincidence. It needs a standing indicator so nobody judges a picture in it
three days after leaving it there.

**Why this is not Screen's feature.** Screen's mode set was rejected above on naming grounds; the
justification here is independent of Screen entirely. §2 and §3 establish that a tool calling itself
a reference player currently **cannot produce a reference transform on SDR**. Reference mode is how
that claim becomes true.

**On the IDT → working space → ODT framing.** It does not fit a player and should not be forced to.
A working space earns its keep when the image is being *modified* — a player modifies nothing. There
are two stages, not three: how the source is interpreted, and what is sent to the display. **The
mode picker governs only the second.** Interpretation is identical in every mode, which is exactly
why "Embedded" was the wrong name.

---

### 6.2 HDR — the structure extends, the varying axis does not

- **On SDR the modes differ on transfer function** (γ1.9609 vs 2.4). That is the defect.
- **On HDR they should converge.** PQ and HLG get v4 profiles declaring transfer exactly (§3), so
  the OS already does the right thing. `OS ≈ Reference` on PQ is the **expected** result. If they
  diverge, that is a finding worth chasing, not a feature working.
- **What varies on HDR is headroom** — how much of the range the display can show. Different axis.
- **Bypass on HDR is dramatic and useful**: PQ code values with no transform look spectacularly
  wrong, which is precisely what they look like in a player that ignores the tag.

**How this is stated to the user is not parallel with SDR, and shouldn't pretend to be.** Added
2026-09-21. For SDR you can name a target and ask the user to hit it once — *align your display to
Rec.709 with a 2.4 EOTF* — and it stays true until they change something. For HDR you cannot, because
the variable is headroom and headroom moves at runtime: it tracks display brightness, responds to
ambient light, and can change with what else is on screen. There is no calibrate-once equivalent,
because the ceiling is not a property of the display but of the display *right now*.

So the SDR statement is an **instruction** and the HDR statement is a **report**: *be in an HDR mode
your Mac recognises, and judge within the headroom shown — content above it clips, and that is
deliberate.* The second sentence is only honest because of the no-tone-map decision below. If the
picture were quietly squeezed to fit available headroom, the display's state would become invisible
and the user could not distinguish the file from the compensation.

**A precondition the app can see only by its effect.** Desktop HDR requires the macOS HDR switch for
that display — user-set, invisible to the app except through EDR headroom. HDR content arriving at a
display in SDR mode should say so in the chain readout (§6.3) rather than showing a flat picture with
no explanation; `PQ (tagged) → display is in SDR mode` is a complete answer in one line. **Open for
Phase 5:** whether the app can distinguish *capable but switched off* from *not capable*. Those want
different sentences — one is actionable, one is not — and the EDR values may collapse both to
`potential=1.0`.

That mode is also hand-set state that takes seconds to change, which makes it the kind of state that
gets forgotten. A display left in HDR mode from yesterday looks like an ordinary SDR session until
the picture is wrong. Same reasoning as the momentary-compare decision in §6.3: cheap-to-change state
needs to be visible, not because changing it is risky but because forgetting is easy.

⚠️ **This must not reopen the 2026-08-28 decision that the desktop picture is the reference and does
not tone-map.** Showing the user what their display's headroom *is* is information. Mapping the
picture to fit it is a different thing and was decided against. Keep them separate, or the mode
picker grows a fourth entry nobody asked for.

---

### 6.3 UI — decided 2026-09-21

**Scope: per window.** Multi-window shipped, and comparing "what the client sees" against "what the
file is" side by side is arguably the feature itself. Per-window like `WindowChrome`. Retrofitting
this later is the expensive direction.

**Progressive disclosure, four tiers.** The transform chain is the clearest possible explanation and
also the one most likely to put off a buyer who does not want to think about transfer functions. So
it is available, not prominent:

1. **Always visible, small** — the mode name in the control bar. Bypass carries a warning marker.
2. **The pulldown** — plain language, with *meaning* as the subtitle rather than mechanism:

   ```
   As macOS shows it     what your client will see
   Reference             correct for grading
   ──────────────────
   Bypass                no colour management
   ```

   The separator before Bypass says "different kind of thing" before anyone reads a word.
3. **One line inside the popover** — the chain, for people who want it:

   ```
   Rec.709 (tagged)  →  BT.1886 2.4      →  display
   PQ (tagged)       →  PQ, no tone-map  →  display · headroom 4.48
   ```

   This carries the existing three-state honesty model (`tagged` / `assumed` / `overridden`) on the
   left of the first arrow, so interpretation and transform read as two visibly separate stages.
4. **Inspector and Export Diagnostics** — full detail, where the people who need it already look.

**The subtitles do the teaching.** *"What your client will see"* versus *"correct for grading"*
explains the entire feature to someone who never wants to know what an EOTF is, and is more honest
than "OS" and "Reference", which mean nothing until you already know.

**Momentary compare, not only a sticky mode.** If the modes are an instrument, the gesture is
hold-to-compare. A sticky toggle stays, but the hold is what gets used — and it avoids the failure
mode of the sticky output-mode pick (2026-09-18): a control that can be left in a non-default state
and forgotten.

**Home:** the existing Color control, two labelled sections — *Interpretation* (source tags + the
override) and *Display transform* (the three modes). §6's "Custom belongs with the
colour-interpretation control" lands in the first section. Keeping them visibly separate is what
stops "Embedded" creeping back in as a concept.

---

### 6.4 Phasing — decided 2026-09-21

**Phase 0 — measure before building.** A file with real shadow detail, current behaviour vs. no
declared colorspace, look at the bottom 10%. *Done means:* the γ1.9609 defect has been seen on a
real display, or established as invisible there. ✅ **Closed 2026-09-21 — result in §6.5, and it
changes what Phase 1 has to prove.**

**Phase 1 — settle the destination question (§7.1).** A spike, not an opinion: what does the layer
do with a colorspace when the shader has already applied the EOTF, and is there a genuine
"no further conversion" path? *Done means:* a measured answer written into §7 the way §2 was
written. ✅ **Closed 2026-09-21 — result in §6.6. The question was malformed; the answer shrinks
Phase 3 and moves all validation to the ASUS.**

**Phase 2 — infrastructure, with OS and Bypass only.** Mode enum, per-window state, pulldown,
chain readout, momentary shortcut, diagnostics line. OS is today's behaviour made explicit; Bypass
is *removing* an assignment. Neither needs colour science. *Done means:* the defect can be A/B'd on
real files and nothing changed for anyone who does not touch the control.

> This is the strategically important phase: **the diagnostic instrument exists before any of the
> hard part is written**, and what it shows informs Reference.

**Phase 3 — Reference.** The shader EOTF, against a settled destination. The only phase that is
real engineering. *Amended 2026-09-21 from §6.6:* the destination is settled — declare the source
and let ColorSync convert, exactly as today. What remains is the transform itself, plus the policy
question in §6.6, and **every correctness check must run on the ASUS.** The LG is structurally
blind to this class of bug.

**Phase 4 — primaries.** Handle primaries and transfer independently instead of as enumerated
pairs, closing §7.3. *Blocked on* a Rec.2020-SDR fixture — **author one with Flip** rather than
hunting for one, as the HDR10 validation fixtures were authored.

**Phase 5 — HDR headroom readout, and Custom.** Both informational rather than structural.

LUT loading sits after Phase 3 — same shader pipeline, same seam, much easier once the transform
stage exists.

---

### 6.5 Phase 0 — result, measured 2026-09-21

A temporary DEBUG-only spike toggled `CAMetalLayer.colorspace` between the derived value and `nil`
on a paused frame, alongside a probe that dumped the **destination** display profile through the
same ICC parser used for the source in §2. The probe's prediction was recorded **before** the
picture was looked at, on each of two displays.

| Display | Assigned profile rTRC | max abs deviation from source | Predicted | Observed |
|---|---|---|---|---|
| LG TV SSCR2 — the reference desktop | `para` ft=0, γ **1.960999** | **1.145e-05** at x=0.601 | nothing to show | no visible change |
| ASUS PA147 | `curv` count=1024 table; **sRGB to 7.6e-06** | **4.962e-02** at x=0.656 | visible | visible — bypass slightly darker |

Both predictions held. Four findings, in ascending order of how much they matter:

**1. Visibility of the A/B is a property of the destination profile, not the source.** The source
is identical in both rows — same file, same `kCGColorSpaceCoreMedia709`, same 660 bytes. Everything
that varies is downstream.

**2. The reference desktop lands on BT.1886 — half by design, half by nothing.** The panel is set
to the display's built-in **Rec.709 preset**, deliberately, as the base for calibration. That part
is a considered choice and not luck. What is *not* chosen is the other half: macOS's default
profile for that display is a parametric encoding of **γ1.960999**, against the source's `curv`
**γ1.960938** — the same curve to about one hundredth of a 10-bit code. That makes ColorSync's
transform identity in all but name, which is what lets the code values reach the panel untouched so
the chosen preset can do its job.

So two independent decisions compose correctly: one the colourist made in the display's menu, one
Apple made on his behalf in an EDID-derived profile he never opened. **Manifold is aware of
neither, and would not notice if either changed.**

⚠️ **The fragility is the point.** A firmware revision that alters the EDID, a macOS update that
assigns a different default, or one stray click in System Settings → Displays → Colour Profile, and
ColorSync stops being a no-op. The picture shifts, the chosen preset is no longer receiving raw code
values, and nothing in the app says so — the scopes will not move (finding 4), and the source-side
diagnostics will read exactly as they do today. This is §5's design consequence restated as a
concrete failure: **correctness contingent on the destination profile is a coincidence even when
half of it was chosen deliberately.**

**3. Bypass is not Reference, and Phase 0 could not have shown the γ1.9609 defect.** What was
observed on the ASUS is *colour-managed-to-sRGB* versus *not colour-managed at all*. It is **not**
γ1.9609 versus 2.4. On the ASUS, OS mode is arguably the correct one — ColorSync compensating an
sRGB panel to deliver the γ1.9609 intent — and Bypass is the wrong one. What Phase 0 established is
that **the transform is real, observable, and predictable from the profiles in advance**. Whether
the γ1.9609 intent itself is wrong *for a reference tool* remains a claim resting on §2 and §4,
not on anything anyone has seen. No mode in the build applies 2.4, so no A/B in the build can
test it.

**4. Scopes do not move, and that is correct.** They sample decoded code values upstream of the
display transform: they measure what is in the file, not what the display emits. This makes them
the one instrument in the app immune to the mode picker — which is why picture and scopes can
legitimately disagree, and why the scopes stay trustworthy while the picture sits in Bypass. **This
belongs in the UI work (§6.3)**, because a user who sees the picture change and the waveform hold
still will otherwise read it as a bug.

> **Units.** The probe reports "50.76 codes at 10-bit". That is the *linear-light* deviation scaled
> to 10 bits, not a 50-code step in the picture — roughly 14% relative light at x=0.656. A future
> reader will misread it as banding-scale otherwise.

**An instrument bug caught by running it, worth recording for the same reason §5's was.** The
probe's first version compared the two TRCs **as encoding strings**. On the LG that yields
`curv/count=1/gamma=1.960938` against `para/ft=0/[1.960999]` — two ICC spellings of one curve — and
the verdict read "TRCs differ, A/B should be visible." Exactly backwards. The shipped version
evaluates both curves numerically over [0,1]. This is the same failure mode as `recordPTSContinuity`
comparing Doubles while the CMTimes were off-grid: **an instrument that compares representations
instead of values reports healthy or reports alarm for reasons unconnected to the thing being
measured.**

---

### 6.6 Phase 1 — result, measured 2026-09-21

**Closed. The destination question as §7.1 posed it turns out to be malformed, and answering it
shrinks Phase 3 considerably.**

**Method.** Nine patches blitted directly to the drawable — no shader, no sampling — and read back
from the composited framebuffer, on both displays, under four colorspace conditions. The probe was
rebuilt first and re-verified against the two known deviations (LG 1.145e-05, ASUS 4.962e-02) before
any of this was trusted. Everything below is **8-bit**; the capture path is 32BGRA.

**1. `colorspace = nil` performs no conversion.** The LG discriminates here, because sRGB and the
display profile genuinely differ on it — and `nil` tracked the display profile, not sRGB. A
no-conversion model predicts the LG captures to ≤0.37 codes across all nine patches: 139.2 predicted
against 139.0 measured at code 128, with the sRGB round-trip control at 0.00.

> ⚠️ **Inference, not measurement.** "Performs no conversion" and "substitutes the display's own
> profile" are indistinguishable in principle — declaring the destination as the source *is* an
> identity transform, so both models predict every observation. What is settled is that `nil`
> substitutes nothing *else*; sRGB, the plausible candidate, is ruled out. §6.5's pass-through
> assumption is now measured to the limit it can be measured.

**2. Declaring the display's own profile is exact identity** — byte-for-byte with `nil` on both
displays, all nine patches, no rounding drift. Declaring anything else is a real conversion:
declaring γ2.4 on the LG moved the framebuffer by up to 10 codes, ColorSync decoding 2.4 and
re-encoding to the display's 1.961.

> ⚠️ **The trap that follows, and it is the likeliest way to get Phase 3 wrong: a shader that applies
> BT.1886 2.4 and then declares γ2.4 has its work undone.** ColorSync converts straight back to
> display encoding and the net light is as if nothing had happened. It will look like a Reference
> mode that simply does nothing, which is much harder to notice than one that looks broken.

**3. Shader-side encoding and ColorSync conversion are the same operation.** Simulating the
mechanism properly — decode the 709 source, re-encode to the display's own TRC (inverting the ASUS's
1024-entry table numerically), declare `nil` — gives **max |Δ| = 0.0 on both displays** against
today's path. Because capture was requested in sRGB, equal captures mean equal requested
*colorimetry*, not merely equal code values: the two paths ask the display for the same light.

**So the destination question dissolves.** Declaring the source and letting ColorSync convert, versus
encoding in the shader and declaring the destination, are not two designs — they are one operation
written two ways. **Reference mode's value cannot lie in the encoding step.** It lies entirely in
what transform runs *before* it: applying BT.1886 2.4 instead of the source's 1.961. That is a
Phase 3 question, and Phase 3 can keep today's declaration untouched.

---

#### The LG is a policy test, not a correctness test — correcting §7.1

The acceptance criterion written into §7.1 this morning — *Reference must leave the LG picture
unchanged* — **does not discriminate**, and the measurement shows why. The double-apply failure was
induced deliberately (shader-encoded values with `CoreMedia709` still declared):

| | ASUS | LG |
|---|---|---|
| today − broken | **11.0 codes** (8-bit) | **0.0 codes** |

**The LG cannot show this class of bug at all**, because the second application is identity there.
A correct implementation and a doubly-applied one look the same on that display. The criterion
passes either way, which makes it useless as a check even though the reasoning behind it was sound.

What the LG criterion actually encodes is the **policy** choice, not correctness: it says *this
display is calibrated to a standard and its profile does not describe it, so leave the numbers
alone.* That remains a real requirement. It is simply not a test of whether the transform is built
right.

**All mechanism validation must therefore run on the ASUS**, whose profile matches sRGB to 7.6e-06
and which consequently responds to every error the LG absorbs.

---

#### The policy question survives — and it is a user declaration, not an inference

Phase 1 settled the mechanism. It did not settle *which interpretation of the display is correct*,
and cannot, because every measurement above assumes the display honours its profile. The LG is
exactly the case where that assumption is false by deliberate choice.

Trace a display set to a preset its profile does not describe — say an Adobe RGB panel presented
with a Rec.709 profile:

| Profile's relationship to the panel | Pass-through | Profile-derived |
|---|---|---|
| Honestly describes it — factory-profiled laptop, most customers | wrong | **correct** |
| A deliberate stand-in for a calibrated target — the LG, and the reference-monitor convention | **correct** | wrong |
| Neither — Adobe RGB panel, Rec.709 profile | wrong | wrong, **identically** |

In the third row the error is **conserved**: the entire discrepancy lives in the gap between what
the profile claims and what the panel does, and no software policy closes it. The destination policy
does not rescue a lying profile — it only decides behaviour in the two rows where the profile is
*not* lying, and those two rows want opposite answers.

**The two domains are separated by a fact the app cannot detect**: whether the display was calibrated
to a standard target or is merely described by its profile. So it is a declaration, not an inference
— a single statement in the Color preferences (*my display is calibrated to a standard target* versus
*use the display profile*), stated once, with pass-through following from the first and
profile-derived from the second.

⚠️ **One setting, not a fourth entry in the per-window mode picker** — §6.2 already warns about that
picker growing, and this is a property of the user's room, not of the clip in the window.

---

#### Incidental, and worth writing down before it alarms somebody

The LG profile's `wtpt` reads xy=(0.3457, 0.3585). That is **D50, the ICC v4 PCS illuminant**, with
the adaptation carried in `chad`, against the v2.1 source profile's D65. It is a convention
difference, not a white-point difference, and it will look alarming in probe output to anyone who
has not been told.

---

#### Still open after Phase 1

- **8-bit only.** The capture path is 32BGRA, so the LG's 0.0117-codes-at-10-bit deviation sits below
  measurement. "Identity" on the LG means identity *to 8 bits*.
- **No light was measured.** No colorimeter in the loop. "Correct light" here means the framebuffer
  requests the correct colorimetry *assuming the display honours its profile*. Whether the LG's panel
  preset actually applies 2.4 is a stated configuration, not a measurement — and it is precisely the
  step that decides whether the LG's γ1.9609 profile is honest.
- **SDR only.** EDR was inert on the LG for this run; PQ and HLG sources untested, and the EDR opt-in
  changes layer configuration.
- **One source space.** `CoreMedia709` only.
- **Window configuration.** Tested in a fullscreen `.screenSaver`-level opaque window. Whether an
  ordinary windowed layer composites identically is untested.
- **A black-point anomaly.** The γ2.4 declaration model matches to ≤0.5 codes from patch 3 upward but
  diverges at the bottom — 4.3 predicted against 13.0 measured at code 16. Probably black-point
  compensation in `CGColorSpace(calibratedRGBWhitePoint:…)`. Unexplained. It affects only the
  synthetic γ2.4 condition and none of the conclusions above, but it is unexplained behaviour in a
  path Phase 3 will touch.

---

## 7. Open and unverified

1. ~~**The destination question.**~~ ✅ **Answered by Phase 1 — see §6.6.** Recorded here because
   this item drove the phasing and the correction matters.

   The question was *whether Reference mode declares a destination colorspace or reads the display
   profile*. **It was malformed.** Those are the same operation: shader-side encoding to the
   display's TRC and ColorSync's own conversion measured byte-for-byte identical on both displays.
   Reference mode should keep today's declaration and change only the transform that runs before it.

   ⚠️ **The acceptance test written here on 2026-09-21 was wrong and is retracted.** It said a
   correct Reference must leave the LG picture unchanged, and that anything shifting the LG is
   double-applying. The second half is backwards: the double-apply bug measures **0.0 codes on the
   LG** and 11.0 on the ASUS, because the second application is identity on a display whose profile
   matches the source curve. The LG cannot detect this class of bug at all. It remains a valid
   statement of *policy* — leave a calibrated display's numbers alone — but it is not a correctness
   check, and **correctness must be validated on the ASUS**.

   **What is still genuinely open** is the policy underneath it: whether a given display is
   calibrated to a standard or merely described by its profile. The app cannot detect this, the two
   answers require opposite behaviour, and on a display that is neither the error is conserved
   regardless. §6.6 records the reasoning and proposes a single stated preference rather than an
   inference. **That is now the open item, not the destination.**

2. **Actual display light output was never measured.** §2's ratios are curve arithmetic. No
   photometer, no measured display response. The claim is about what the profile asks for.

3. **`makeColorSpace` flattens (9, 1) — Rec.2020 SDR — to `kCGColorSpaceCoreMedia709`**, silently
   dropping 2020 primaries, because the `switch` enumerates *pairs* and (9,1) falls to the default
   arm. **Banked, not fixed:** verifying it needs a 2020-SDR fixture the corpus does not have.
   It belongs with a colour-correctness pass that handles primaries and transfer **independently**
   rather than through enumerated pairs — the same structural problem as the Custom note in §6.

   Added 2026-09-21: **(9,1) is not HLG** — HLG is (9,18,9) and takes the v4 path correctly. As an
   intentional delivery format (9,1) is uncommon; where it actually occurs is **mistagging**, a file
   written with 2020 primaries whose transfer was left at the default. That is exactly the case this
   tool exists to catch, and today it is rendered with 709 primaries with no indication. The defect
   is also **structural, not specific to that pair** — any combination absent from the enumerated
   list falls to the same default arm.

4. **The `[EDR]` log has been blind to P3 all along.** Because the P3 space is unnamed
   (§3), the log line at `MetalVideoRenderer.swift:534` prints `<unnamed>` for every P3 source.
   Cosmetic only — but the ICC `desc` (`Apple P3`) is available as a fallback.

5. **Cross-OS stability unverified.** Measured on macOS 26.5.1 only. These are system assets.

6. **Screen's internals unverified** — see §5.

7. **The provenance of 1.9609 (§4) is documentation, not measurement.** The two derivations agree
   and the number matches to 1.17e-05, which is strong, but no primary Apple source was read.

---

## 8. Reproduction

Fixtures and both probes live in **`docs/color-fixtures/`**:

| File | What it is |
|---|---|
| `709-CoreMedia709.icc` | 660 B — the profile in §2 |
| `P3-AppleP3.icc` | 608 B |
| `PQ-ITUR2100PQ.icc` | 13300 B |
| `HLG-ITUR2100HLG.icc` | 7156 B |
| `dump_colorspaces.swift` | Calls the copied `makeColorSpace`, prints names + `CFEqual` identity, writes the ICC bytes |
| `parse_icc.py` | Independent ICC parser: TRC discrimination, parametric/curve details, candidate fit |

No fixture for the untagged fallback: it is byte-identical to `709-CoreMedia709.icc`
(SHA-256 `a1096ca4…6b1eb29b`), which is itself the finding.

```bash
cd docs/color-fixtures

# Regenerate the profiles from the live system:
swiftc -target arm64-apple-macos15.0 dump_colorspaces.swift -o /tmp/csdump && /tmp/csdump /tmp

# Confirm the system still produces the committed bytes:
shasum -a 256 /tmp/709.icc 709-CoreMedia709.icc

# Read the transfer function out of any profile:
python3 parse_icc.py 709-CoreMedia709.icc
```

Expected, and the single line this whole document turns on:

```
rTRC : curveType 'curv'  count=1  → PURE POWER LAW, gamma=1.960938
         x^1.961 (the forum claim)    max err = 1.172499e-05  ← MATCH
         piecewise BT.709 EOTF        max err = 1.287997e-02
```

---

## Summary

| | Measured | Inferred | Unverified |
|---|---|---|---|
| 709 SDR transfer is γ1.9609375, single power law | ✅ from ICC bytes | | |
| Not piecewise BT.709; `curv count=1` cannot be | ✅ structural | | |
| P3 carries the same curve; untagged == 709 | ✅ byte-identical | | |
| PQ/HLG declare transfer via `cicp` + LUT | ✅ | | |
| No tag combination yields 2.4 through this call | ✅ exhaustive over the arms | | |
| Two-era system-profile lineage | | ✅ from versions/dates | |
| 1.9609 = inverted 709 OETF, dim-surround | | | ⚠️ published refs only |
| Match QuickTime ≡ Embedded on SDR | ✅ waveform | ✅ "both defer to ColorSync" | Screen internals |
| Shader encoding ≡ ColorSync conversion — the destination question dissolves | ✅ 0.0 codes, both displays | | |
| `colorspace = nil` performs no conversion | ✅ to the limit it can be | ✅ vs. "substitutes the display profile" — indistinguishable | |
| Shader 2.4 + declared γ2.4 undoes itself | ✅ 10 codes on the LG | | |
| Double-apply bug is invisible on the LG, 11 codes on the ASUS | ✅ | | |
| Which displays are calibrated vs. merely described | | | ⚠️ **open — undetectable, needs a stated preference (§6.6)** |
| (9,1) Rec.2020-SDR flattens to 709 | | ✅ from code | ⚠️ no fixture — author with Flip |
| A/B visibility is set by the **destination** profile, not the source | ✅ two displays, predicted then observed | | |
| LG desktop profile ≡ source curve → ColorSync is a no-op there | ✅ 1.145e-05 | | |
| That desktop picture lands on BT.1886 | | ✅ chosen 709 panel preset + unchosen no-op ColorSync | ⚠️ panel response not measured |
| γ1.9609 vs 2.4 visible on real material | | | ⚠️ **not established — Bypass ≠ Reference (§6.5)** |
| Actual display light output | | | ⚠️ never measured |

---

*Everything in §2 and §3 is reproducible from `docs/color-fixtures/` in under a minute. If a future
macOS changes these profiles, the recipe will say so — that is what it is for. Corrections welcome,
particularly on §4, which is the section resting on the least of our own evidence.*
