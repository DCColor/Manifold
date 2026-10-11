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

Split into two on delivery:

- **Phase 2a — the mode reaches the layer.** Mode enum, per-window state, a plain menu item.
  ✅ **Closed 2026-09-22 — result in §6.7.** The A/B is live on real files and OS is measured
  byte-identical to the build before it. It also produced a finding nobody was looking for: the
  LG's no-op status is **conditional on the macOS HDR switch**, which §6.7 records.
- **Phase 2b — the control-bar surface.** The pulldown with §6.3's meaning-carrying subtitles, the
  chain readout, the momentary-compare gesture, the diagnostics line, and the standing Bypass
  indicator §6.1 requires. ⚠️ **Read §6.7's constraint before starting**: every change of mode must
  go through `DeckRegistry.setDisplayTransform`.
  ✅ **Closed 2026-09-22 — result in §6.8.** Pulldown, standing Bypass indicator and chain readout
  are live; both control surfaces agree in both directions and OS is still 0 codes against `c34a17c`.
  **Two items from the list above did NOT ship and are carried forward:** the momentary-compare
  gesture, and `didChangeScreenProfileNotification` is wired but untested live (exercising it means
  changing a macOS display setting). §6.8 also raises a design question the placement created — the
  standing indicator inherits the control bar's auto-hide in overlay mode.
- **Phase 2c part 1 — the title marker, the profile-change path, and the metric question.**
  Recorded inside §6.8. The HDR toggle was performed by the operator and the readout follows it; the
  Bypass marker now also appears in the window title, which does not auto-hide (full screen has no
  marker at all, by decision). It also found three things measured false: the pulldown's subtitles,
  the Color control's amber, and the Source line's tier on any stream.

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

> ⚠️ **Added 2026-09-22 — the ASUS validates mechanism, never accuracy.** The ASUS is in its
> built-in Rec.709 preset and is otherwise **uncalibrated**. "Its profile matches sRGB to 7.6e-06" is
> a statement about the *profile*, not about the *panel*: whether that profile describes what the
> panel actually emits is unknown, and earlier text in this document that called it "a display
> whose profile is honest" overstated what was measured.
>
> That does not weaken its use here, because the two kinds of validation need different things:
>
> | Question | Measured in | Needs |
> |---|---|---|
> | **Mechanism** — is the transform applied, applied once, in the right place? | framebuffer code values | any display whose profile *differs from the source curve*, so ColorSync performs a real conversion |
> | **Accuracy** — does the emitted light match the standard? | light, with a probe | a calibrated display, measured |
>
> The ASUS qualifies for the first and not the second. It is the stand-in for **other people's
> monitors** — the uncalibrated, vendor-profiled case most customers are in — which is exactly what
> mechanism testing should be aimed at. **No colour-accuracy conclusion may be drawn from it.**
> Accuracy belongs to the LG, and even there it has never been measured with a probe (§7.2).

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

### 6.7 Phase 2a — result, measured 2026-09-22

**Closed. The mode reaches the layer, OS is byte-identical to the build before it, and the LG's
no-op status turns out to be conditional on a switch nobody had varied.**

**What shipped.** A per-window `DisplayTransformMode` with two cases — `os` and `bypass`, no
Reference case, because an unreachable arm invites a stub. State on `WindowChrome`; a new top-level
`CommandMenu("Color")`; the mode applied in one place, `MetalVideoRenderer.publishColorState()`,
which is the only thing that decides what reaches the layer. `PendingColorState.colorSpace` became
optional, and **`nil` is a value there, not an absence** — it is Bypass being installed.

#### MEASURED

Every capture below is `screencapture -o -l <windowID>` — window-id, never a region grab. All 8-bit;
the capture path is 32BGRA. Fixture `docs/color-fixtures/wedge.mov` unless stated.

| what | result | why it is the check |
|---|---|---|
| **LG, OS vs Bypass** (HDR off) | **0 codes, 0.00 % of pixels** | ColorSync is identity there (§6.5), so identical is the *prediction*, not a pass |
| **ASUS, OS vs Bypass** | **21 codes, 93.69 %**, worst **170 → 149** at x≈0.667 | §6.5 predicted the worst deviation at **x = 0.656**. The mode reaches the layer |
| **OS vs the PRE-CHANGE build**, ASUS | **0 codes, 0.00 %** | the no-regression guarantee, measured rather than argued |
| **Bypass across relaunch** | resets to OS | §6.1 — Bypass must not be left on and forgotten |
| **Two windows, different modes, same display, same instant** | **21 codes apart** | §6.3's side-by-side comparison is the feature; per-window is real |

**The no-regression test is the one worth describing, because "byte-identical" is the kind of claim
that is usually asserted.** The work was stashed, `HEAD` was built into a separate derived-data
path, the same fixture was captured at the same window geometry **on the ASUS** — the display that
responds to every error the LG absorbs — and compared. 0 codes. The baseline binary has no Color
menu, which is what confirms the right binary was measured.

> ⚠️ **The ASUS numbers are MECHANISM, NEVER ACCURACY**, exactly as the 2026-09-22 note in §6.6
> requires. That display is in its built-in Rec.709 preset and is otherwise uncalibrated; whether
> its panel emits what its profile claims is unknown and unmeasured. 21 codes says the transform is
> applied, applied once, and in the right place. **It says nothing whatever about whether any of
> these pictures is correct.** No colour-accuracy conclusion may be drawn from this table.

#### Occlusion immunity — proved, because the first attempt at proving it was broken

Captures were contaminated by a window left over the app early on, so the method was changed to
window-id capture and then **tested rather than trusted**: an opaque window was parked over the
Manifold window and confirmed present (a region grab of that rect returned the occluder's colour),
and the `-l` capture taken at that moment came back **0 codes** against the unoccluded one, with
**0 occluder pixels** in it.

⚠️ **The first version of that test proved nothing and looked like it had passed.** The occluder had
no run loop, so it never rendered; the capture matched because there was nothing on top. Same
failure as §6.5's probe comparing ICC encodings as strings — *an instrument that is not doing what
its name says reports success for reasons unconnected to the thing being measured.* The value above
is from the fixed version, with the occluder verified on screen first.

Independently: the contaminated-era OS capture is **0 codes** against a clean re-run, so the earlier
figures were never affected.

#### ⚠️ The LG stops being a no-op when macOS HDR is switched ON — and this was not being looked for

§6.5 warned that the LG's identity transform is "a coincidence even when half of it was chosen
deliberately", and listed the ways it could break. **One of them is a toggle in System Settings, and
it does break it.** With HDR ON for the LG:

| LG display profile | rTRC | OS vs Bypass on the SDR wedge |
|---|---|---|
| HDR **off** (§6.5) | `para` ft=0, γ **1.960999** | **0 codes** |
| HDR **on** (measured 2026-09-22) | `curv` count=1024 table, **sRGB to 7.648334e-06** | **21 codes, 93.71 %**, worst 170 → 149 |

`7.648334e-06` is the ASUS's number to every digit — in HDR mode macOS hands the LG a profile with
**the same transfer curve as the ASUS**, and the delta becomes the ASUS's delta. The ICC bytes still
differ (primaries and white point), but the TRC does not.

> ⚠️ **WHICH METRIC `7.648334e-06` IS.** `max |curve(x) − sRGB(x)|` over [0,1], sampled at
> **`i/256`, 257 points** — `parse_icc.py`'s grid, which `[CSPROBE]` shares. The shipping readout
> reports the same quantity on a **1025-point** grid and prints one significant figure, so the same
> profile reads **9.1e-06** there. Both are lower bounds on the same supremum (≈9.52e-06) and
> neither is a different definition of sRGB. §6.8's "Which metric each number uses" has the
> arithmetic.

**Bypass is invariant across the switch** — the same 149 in both states, which is what "performs no
conversion" predicts and is a second, independent confirmation of §6.6's finding. **It is OS that
moves**, 149 → 170.

> ⚠️ **THE CONSEQUENCE FOR THE REFERENCE DESKTOP, STATED PLAINLY.** §6.5 described two independent
> decisions composing correctly — a chosen Rec.709 panel preset, and an unchosen EDID-derived
> γ1.9609 profile that makes ColorSync a no-op. **Turning on macOS HDR destroys the second one**,
> ColorSync starts doing real work, and the code values the chosen preset is there to receive no
> longer arrive. The picture shifts by 21 codes and **nothing in the app says so** — the scopes will
> not move (§6.5 finding 4) and the source-side diagnostics read exactly as before. This is no
> longer a hypothesised fragility; it is a reproducible one with a known trigger.
>
> ⚠️ It also means **§6.5's "the LG is a policy test, not a correctness test" holds only in SDR
> mode.** In HDR mode the LG discriminates mechanism exactly as the ASUS does. Phase 3's rule —
> validate on the ASUS — is unaffected, but the *reason* given for it now has a stated precondition.

#### HDR on: what `colorspace = nil` does under an EDR opt-in

`docs/color-fixtures/edr_bypass_probe.swift`, four conditions, patches blitted straight to the
drawable. EDR read from **the window's own screen** (§BUGS.md's hazard rule 3), potential before
current (rule 1).

- **`maxPotentialEDR = 8.965394`** with HDR on — the display genuinely offers headroom. (It reads
  **1.0** with HDR off, which is why the first run of this probe could establish nothing about EDR.)
- **`colorspace = nil` with `wantsExtendedDynamicRangeContent = true` is ACCEPTED.** Both properties
  read back exactly as set, in every condition, on a display that is actually offering headroom.
  The layer does not reject the nil, and does not silently clear the opt-in.
- **Bypass shows raw PQ code values, uninterpreted**, and identically with HDR on or off:

  | PQ code | PQ declared | **Bypass** |
  |---|---|---|
  | 0.50 | 245 | **127** |
  | 0.58 | 255 | **148** |
  | 0.75 | 255 | **191** |
  | 1.00 | 255 | **255** |

  0.58 × 255 = 147.9. That is §6.2's requirement met: PQ diffuse white shows as 58 % grey rather
  than white — "precisely what they look like in a player that ignores the tag".

- **In the real app on a PQ file, HDR on: OS vs Bypass = 127 codes over 97.40 % of pixels**, worst
  **255 → 128**. §6.2's "dramatic and useful" is not an overstatement.

> ⚠️ **WHAT THIS DOES NOT ESTABLISH, AND THE TEMPTATION IS TO SAY IT DOES.** `maxEDR(now)` read
> **1.0 in every condition**, including the known-good `PQ + EDR` control, and also in the shipping
> app on a PQ source with HDR on. **No layer in any of these runs won a headroom grant**, so nothing
> here measures what the EDR opt-in does when it is actually granted headroom — only that a nil
> colorspace does not prevent it being requested. Why no grant was won is unexplained and is the
> first thing to chase in Phase 5.
>
> ⚠️ **And a capture is not light.** These are 8-bit SDR-referred captures; values above SDR white
> cannot be represented, so every 255 above is clipped *in the capture*. That is evidence about the
> composite, not about the panel. No colorimeter has been in the loop at any point in this document.

#### ⚠️ Scope of the HDR-on run

**Scope of the HDR-on run:** switching macOS HDR on also moves the LG into its HDR hardware preset,
which has not been calibrated or validated. The measurements above are framebuffer code values set
by the profile macOS assigns and are independent of the panel preset. They stand as mechanism
findings. Nothing here says anything about how the LG looks in HDR mode; on that path the LG is an
unvalidated display, equivalent to the ASUS: mechanism only, never accuracy.

#### ⚠️ A constraint Phase 2b must honour

**Every change of mode must go through `DeckRegistry.setDisplayTransform`.** That function writes
the owning `WindowChrome` *and* forwards to that deck's renderer.

This is deliberately unlike every other per-window value, which reaches its consumer by `ContentView`
observing the `@Published`. That route is **not available**: `ContentView`'s modifier chain is at
the Swift type-checker's limit, and adding one more `.onChange` fails the build outright with
*"unable to type-check this expression in reasonable time"* — hit twice while building this, and the
same constraint that file already documents on `transportKeys.attach`.

**So a write to `chrome.displayTransform` that does not go through that function moves the menu
checkmark and not the picture, and there is no observer to catch it.** If 2b's pulldown writes the
property directly, it will look like it works. The fix, should it ever be needed, is to break up
`ContentView`'s body far enough to afford the `.onChange` — **not** to add a second forwarding path.

#### Shipped alongside, because Bypass would have made it a bug

**`MetalVideoRenderer.swift:3303` — the PNG export tagged its output from the LAYER.** It read
`metalLayer.colorspace ?? itur_709`, which was correct only while those two could not disagree. In
Bypass the layer holds `nil` by design, that fallback fires, and **a P3 or PQ file exports tagged
709** — a wrong tag on a written file, caused by a display setting, with nothing saying so. It now
reads the source-derived colorspace.

The export reads the offscreen, which is upstream of the layer, so its pixels never depended on the
mode and its tag must not either. **Same boundary the scopes and SDI sit on**, and both were
verified to need no change: the scopes sample the offscreen ring (§6.5 finding 4), and SDI tags from
the source's primaries through `BMDColorspaceForPrimaries`, a path that never touches a
`CGColorSpace` or reads the layer. Stated in the code at each boundary rather than left as a
coincidence.

#### Incidental, and it will mislead somebody during Phase 5

**The app's own `[EDR] headroom` line asserts the wrong thing on an HDR display.** It appends
`<<< NO HEADROOM — EDR is inert on this display` whenever `current <= 1.0001`, ignoring `potential`
entirely — so with HDR on it printed that sentence while `potential = 8.9654`. That is precisely the
inference `docs/BUGS.md`'s EDR measurement hazard was written to prevent ("*that conclusion was
WRONG; the display was in SDR mode for the entire probe*"), now emitted by the app's own diagnostic.
**Not fixed here** — out of scope for 2a — but it should key on `potential`, and say "no grant" when
`potential` is high rather than "inert on this display".

#### Still open after Phase 2a

- **No grant was ever won**, so the EDR opt-in's actual effect remains unmeasured. Above.
- **8-bit, and no light measured.** Unchanged from §6.6.
- **Why macOS assigns an sRGB-TRC profile in HDR mode** is observed, not explained.
- **The HDR-on measurements are one session on one machine**, with the switch toggled by hand.

---

### 6.8 Phase 2b — result, measured 2026-09-22

**Closed. The pulldown, the standing Bypass indicator and the chain readout are live, both control
surfaces agree in both directions, and OS is still byte-identical to Phase 2a.**

**What shipped.** `DisplayTransformControl` — §6.3's tiers 1–3 — in the per-window control bar,
beside the existing Color control and deliberately *not* merged with it (§6.3: "keeping them
visibly separate is what stops 'Embedded' creeping back in as a concept"). Its own file, its own
`View` structs, and **no new modifiers on `ContentView`'s body**, which §6.7 records as being at the
type-checker's limit. Plus `ICCTransferCurve`, a shipping ICC rTRC parser, and `DisplayChainModel`,
one per window.

⚠️ **Still no Reference, not even disabled.** Phase 3. A greyed row advertising a mode that cannot
be chosen is a support question, and a placeholder is how a stub gets written.

#### MEASURED

All captures `screencapture -o -l <windowID>`; every window identified by the NSScreen **name** it
was on, never inferred from coordinates. Fixture `docs/color-fixtures/wedge.mov`. HDR off on both
displays throughout, verified before and after.

| what | screen | result |
|---|---|---|
| **OS vs Bypass, switched via the PULLDOWN** | ASUS PA147 | **21 codes, 93.69 %**, worst **170 → 149** |
| **Color menu checkmark after the pulldown set Bypass** | — | followed — OS unchecked, Bypass ✓ |
| **Pulldown after the COLOR MENU set OS** | ASUS PA147 | followed — badge cleared (**0 amber px**), label back to "macOS" |
| **OS vs the Phase 2a build `c34a17c`** | ASUS PA147 | **0 codes, 0.00 %** |
| **OS → Bypass → OS round trip** | ASUS PA147 | **0 codes** against the original OS capture |
| **Bypass across relaunch** | — | resets to OS, through the new write path too |

The 21 codes and the worst point reproduce §6.7's numbers exactly, from a different control surface
— which is the check that the pulldown reaches the layer rather than merely redrawing itself.

> ⚠️ **ASUS = MECHANISM, NEVER ACCURACY**, as §6.6 and §6.7 both require. That display is
> uncalibrated and in its built-in Rec.709 preset; these numbers say the transform is applied, once,
> in the right place, and say nothing about whether any picture is correct.

#### The chain readout, as it actually prints

**On the LG (`LG TV SSCR2`), mode OS:**

```
Source     Rec. 709 · Rec. 709 · no CICP — assumed
Transform  As macOS shows it — source colorspace declared to the layer
Display    LG TV SSCR2 — pure power law, gamma 1.961
           macOS is passing this picture through unchanged.
```

**On the ASUS (`ASUS PA147`), mode OS:**

```
Source     Rec. 709 · Rec. 709 · no CICP — assumed
Transform  As macOS shows it — source colorspace declared to the layer
Display    ASUS PA147 — sampled table, 1024 entries — matches sRGB to 9.1e-06
           macOS is converting this picture for this display.
```

⚠️ **`9.1e-06` is `max |curve(x) − sRGB(x)|` over [0,1] on a 1025-point grid, printed to one
significant figure.** §6.7 records `7.648334e-06` for the same curve; that is the same metric on
`parse_icc.py`'s 257-point grid. See "Which metric each number uses" below — the two numbers are
not a disagreement.

**On the LG, mode Bypass** (no verdict line: the question only applies in OS):

```
Source     Rec. 709 · Rec. 709 · no CICP — assumed
Transform  Bypass — no colorspace declared, no conversion
Display    LG TV SSCR2 — pure power law, gamma 1.961
```

Both readings are the right way round against this document: the LG's profile IS the source curve
(§6.5), so "passing through unchanged"; the ASUS's is sRGB, so "converting".

**`Rec. 709 · Rec. 709 · no CICP — assumed` is correct, and the wedge really is untagged.** The
renderer publishes `primaries=nil transfer=nil matrix=nil` for it. The line names the curve the
renderer is USING — `makeColorSpace` resolves absent codes to the full 709 set — while carrying the
provenance separately, which is §6's honesty model. An earlier version printed `—` for the curve;
that was wrong, because the picture is emphatically not being rendered through a dash, and §2
measured the untagged fallback as byte-identical to the 709 profile.

#### Screen change — tested. Profile change — NOT tested, and why

**The window was moved from the LG to the ASUS with the chain readout OPEN, and the readout updated
live**: the Display line changed to the ASUS's sampled table and the verdict flipped from "passing
through unchanged" to "converting". That is `NSWindow.didChangeScreenNotification` working.

A **real mouse drag** from the ASUS back to the LG was also performed, and the readout is correct
afterwards — but the popover **dismisses** during a genuine window drag (ordinary AppKit behaviour),
so the live-update-while-open demonstration is the programmatic move, which posts the same
notification. Both are recorded rather than the stronger one implied.

⚠️ **`NSWindow.didChangeScreenProfileNotification` is wired and UNTESTED LIVE.** Exercising it means
changing a display's assigned profile — a macOS display setting — and this work was done under an
explicit instruction not to touch any. It is the path §6.5's "one stray click in System Settings ▸
Displays ▸ Colour Profile" arrives on, and §6.7 measured the macOS HDR switch doing exactly that to
the LG, so it is worth exercising deliberately at some point. **Not claimed as working.**

> **AMENDED 2026-09-22 by 2c part 1 § C below.** It was exercised, on a real macOS HDR toggle, and
> the readout follows a profile change with the window stationary. But the toggle also posts
> `didChangeScreenNotification` — macOS replaces the `NSScreen` objects — and both names route to
> one `refresh()`, so **this specific notification is still not individually demonstrated.** The
> heading above should be read as "profile change — the READOUT is tested, the notification is
> not isolable".

#### Three defects that rendered as something plausible

Recorded because each one *looked* fine and was caught only by measuring the rendered result — the
same class as §6.5's probe comparing ICC encodings as strings.

1. **Both menu rows drew a checkmark, and neither subtitle rendered.** The first version drew its
   own `Image(systemName: "checkmark")` at `.opacity(checked ? 1 : 0)` with the subtitle in a
   `VStack`. AppKit does not honour a zero-opacity image in a menu item, and a `VStack` label is
   flattened to its first `Text`. **§6.3 is explicit that "the subtitles do the teaching"**, so this
   removed the point of the control while leaving it apparently working. Fixed by using `Toggle`
   (AppKit draws a real checkmark — the mechanism `RasterSizeCommands` and the Color menu already
   use) with a second `Text` for the subtitle.

   > ⚠️ **THE SECOND HALF OF THAT IS WRONG, AND THIS ENTRY IS THE REASON IT MATTERS.** The
   > checkmark was fixed. **The subtitle was not** — the second `Text` silently drew nothing, and
   > this document recorded it as fixed for a day because the fix was verified by LOOKING at the
   > menu, where a row with no subtitle looks like a row that was never meant to have one. A
   > glyph-edge scan of the subtitle band finds **0 text pixels**. Measured and fixed in 2c part 2
   > below, which also records the three other constructions that drew nothing.
   >
   > An entry about defects that render as something plausible, whose own fix rendered as something
   > plausible. The lesson it already states was not applied to it.
2. **The Bypass badge rendered as plain white text.** It was inside the `Menu`'s label;
   `.menuStyle(.borderlessButton)` strips a label's background and foreground, so the amber capsule
   and black text were discarded and the control bar's own white won. Caught by sampling the capture
   — **zero non-grey pixels in the indicator region** — not by looking, because bold white
   "⚠ BYPASS" looks deliberate. Fixed by making the badge a sibling of the menu; it now measures
   **1041 amber pixels** when Bypass is active and **0** when it is not.
3. **"Show Transform Chain…" did nothing.** Setting the popover's presentation flag synchronously
   inside a menu action loses the race with the menu's own dismissal. Deferred one runloop turn.

#### ⚠️ The standing indicator inherits the control bar's auto-hide, and §6.1 should be read again

The indicator is on the control bar, which is where it was asked for — but this window's control
bar defaults to the **overlay** HUD, which auto-hides. **So in overlay mode the "standing" marker
hides with the bar**, and is visible only while the HUD is awake. In **docked** mode
(`WindowChrome.controlMode == .docked`) the bar is permanent and so is the marker.

§6.1 wants the indicator "so nobody judges a picture in it three days after leaving it there", and a
marker that disappears after a few seconds of no mouse movement does not obviously satisfy that.
**Not changed here** — the placement was specified, and moving it would be a design decision, not an
implementation one. Flagged as the open question it is.

#### The 2b constraint was honoured, and extended rather than bypassed

Every mode change still goes through `DeckRegistry.setDisplayTransform`; there are **no writes to
`chrome.displayTransform`** anywhere in the new control. The function gained an optional
`on deck:` parameter — nil still means the key deck, which is what the Color menu needs, while the
pulldown names its own deck. The pulldown is physically inside one window, so its target is not in
question, and naming it removes any dependence on what `NSApp.keyWindow` reports while an `NSMenu`
is tracking. **One mutator, two callers** — which is what §6.7's constraint requires.

---

#### Phase 2c part 1 — measured 2026-09-22, after 2b closed

Three pieces of work, recorded here because each one lands directly on something §6.8 left open:
the Bypass marker moves out of the auto-hiding control bar and into the window title, the
profile-change path is finally exercised on a real macOS HDR toggle, and the two different numbers
this document prints for one curve are reconciled. It also carries **two corrections to the section
above** and one defect in the Source line, all found while reporting on the colorimetry pulldown
that shares the control-bar section with the display-transform one.

##### B — the Bypass marker in the window title

**What changed.** `WindowDeck.windowTitle` gained a fourth case: whatever the name resolves to,
Bypass appends `" — Bypass"`. `DeckRegistry.setDisplayTransform` — still the one mutator, §6.7's
constraint intact — calls `applyWindowTitle()` after writing the mode. **Synchronously, and
deliberately not through `setNeedsWindowTitle()`:** that hop exists because `@Published` fires from
`willSet`, so a title derived inside such a sink reads the previous value. This is not a sink; the
assignment has already completed. The control-bar badge is unchanged.

**Why the title.** §6.8 records the standing indicator inheriting the overlay HUD's auto-hide, so
the "standing" marker is visible only while the bar is awake. The Window menu and Mission Control do
not auto-hide. And the constraint this placement was chosen under is that **nothing may be drawn
over the picture** — the title bar is hidden (`.hiddenTitleBar`), so nothing is.

MEASURED, two windows in different modes at the same instant, read from `kCGWindowName`:

| stream window | file window |
|---|---|
| `MAC-STUDIO (Manifold Colour Test) — Bypass` | `wedge.mov` |
| `MAC-STUDIO (Manifold Colour Test)` | `wedge.mov — Bypass` |

Both directions, both windows, and the Window menu lists both spellings at once. **Nothing new is
drawn over the picture, measured rather than asserted:** the same window captured in Bypass and in
OS differs by **0 pixels above the control bar**, and all **11 431** differing pixels lie inside the
bar. (0 in the picture is also the §6.5 prediction for the LG in SDR, so that half of the capture is
a null result twice over; the point here is the *location* of the differences, not their count.)

> ⚠️ **FULL SCREEN HAS NO BYPASS MARKER AT ALL, AND THAT IS ACCEPTED.** The title bar is hidden, the
> control bar auto-hides, and the only remaining surface is the picture. **Decided: nothing goes
> over the picture.** So in full screen a window can be in Bypass with no standing indication
> anywhere — a known, accepted limit, not an oversight. It narrows §6.1's requirement rather than
> satisfying it: the marker now survives the HUD's auto-hide in windowed mode, and is absent in full
> screen.

##### C — `didChangeScreenProfileNotification`, exercised on a real macOS HDR toggle

§6.8 records this path as wired and untested, because exercising it means changing a macOS display
setting. It was exercised: HDR was switched **on and then off for the LG**, by the operator, with
`wedge.mov` on the LG and the chain readout open. No display setting was changed by the tooling.

MEASURED — the window stayed on the LG throughout (macOS nudged its origin, 60,1120 → 22,1221 →
168,1187; it never changed display):

| | Display line | verdict |
|---|---|---|
| HDR **off** (before) | `LG TV SSCR2 — pure power law, gamma 1.961` | passing through unchanged |
| HDR **on** | `LG TV SSCR2 — sampled table, 1024 entries — matches sRGB to 9.1e-06` | **converting** |
| HDR **off** (return) | `LG TV SSCR2 — pure power law, gamma 1.961` | passing through unchanged |

**The readout matches itself.** The HDR-on LG prints `matches sRGB to 9.1e-06` — character for
character the ASUS's line, captured minutes earlier on the second window. §6.7's "in HDR mode macOS
hands the LG the same transfer curve as the ASUS" now reproduces through the shipping readout, on a
different code path from the probe that first found it.

**And the probe agreed at the same instant**, from the log: profile sha `3527727a…` → `2e0f5927…`,
`para ft=0 γ1.960999` → `curv count=1024`, `sRGB max err = 7.648e-06`, verdict flipping from
"TONE CURVES DO NOT [differ]" to "max |source − dest| = 4.962e-02 at x=0.656 → 50.7623 codes at
10-bit". `maxPotentialEDR` for the LG read **8.965394** with HDR on and **1.0** with it off —
§6.7's figure to every digit. The return leg restored all of it exactly.

⚠️ **WHAT THIS DOES *NOT* ESTABLISH, AND THE TEMPTING CLAIM IS THAT IT DOES.** Two things.

1. **The popover does not stay open across the toggle**, so "updates live while open" was not
   demonstrated for this trigger. Measured separately: the popover survives a menu-bar interaction
   (Control Center was opened and closed with it open and it stayed) but **not another application
   becoming active** — and the HDR switch lives in System Settings. This is the same limitation
   §6.8 already records for a real window drag, arrived at from a different direction. The readout
   was reopened **without moving the window**, which is what the table above is.
2. **`didChangeScreenProfileNotification` still cannot be isolated.** The log shows the toggle
   posting `didChangeScreenParameters` *and* **three `NSWindow.didChangeScreenNotification`** —
   macOS replaces the `NSScreen` objects on a display reconfiguration, so the *screen* notification
   fires although no window changed display. `DisplayChainModel` observes both names into the same
   `refresh()`. So the honest status changes from **"untested"** to **"covered but
   indistinguishable"**: the model's observer set demonstrably covers the HDR trigger, and which of
   the two names carried it is not decidable from this evidence. Telling them apart needs a log line
   inside `refresh()` naming the notification, which was not added.

Not re-measured this round: the OS-vs-Bypass **code-value** A/B under HDR on. §6.7's 21 codes and
Bypass's invariance across the switch stand on that section's measurement, not on this one.

##### D — which metric each number uses

The ASUS reads `matches sRGB to 9.1e-06` in the readout while §6.7 records `7.648334e-06` for the
same curve. **Same profile, same sRGB definition, same metric — only the sampling grid differs**,
and the readout additionally prints one significant figure. Reproduced on the ASUS's live profile
(`CGDisplayCopyColorSpace`, `curv count=1024`), `max |curve(x) − sRGB(x)|` over [0,1]:

| grid | used by | max err | at x |
|---|---|---|---|
| `i/256`, 257 points | `parse_icc.py`, `[CSPROBE]` | **7.648334e-06** | 0.035156 |
| `i/1024`, 1025 points | `ICCTransferCurve.bestMatch` (shipping readout) | **9.062397e-06** → printed `9.1e-06` | 0.032227 |
| `i/65536` | neither — the supremum, for reference | 9.524365e-06 | 0.032272 |

Both are lower bounds on one supremum; the denser grid is the tighter one. The sRGB definition is
byte-identical in both implementations (`x ≤ 0.04045 ? x/12.92 : ((x+0.055)/1.055)^2.4`), and both
interpolate the 1024-entry table linearly, as the ICC spec prescribes. **Neither number is wrong and
they are not in conflict** — but a document that prints both without saying which grid produced
which invites exactly the reading that they are, which is why §6.7 and this section now both name
the metric at the point of use.

##### ⚠️ Two claims in "Three defects that rendered as something plausible" do not survive re-measurement — BOTH FIXED IN PART 2

Both were re-checked on the live build while capturing the control bar for the report above, by the
same method that caught them originally — sampling the rendered pixels, not looking at the menu.

1. **The pulldown's subtitles are still not rendering.** §6.8 says the `Toggle` + second-`Text` form
   fixed them. It did not. A luminance scan across the open menu shows the rows are **two-line
   height** — AppKit reserved the space — but the subtitle band is background only: title text peaks
   at **227**, the band beneath it at **75**, which is the menu's own gradient. So the fix bought
   the row height and not the text. **§6.3 is explicit that "the subtitles do the teaching"**, so
   the control is still missing its point while looking deliberate — which is precisely what that
   defect entry warns about, reintroduced by its own fix.
2. **The Color control does not turn amber on an override**, and this one was never a 2b claim — it
   is `ContentView.colorControl`'s own documented behaviour ("an override turns the control amber:
   something on screen is a human assertion, not a reading"). With `2020 PQ (ST 2084) · Overridden`
   on screen, **max(r − b) = 0 across the whole face region**: not one non-neutral pixel. The cause
   is §6.8's defect 2 verbatim — `.foregroundStyle(…)` wraps an `HStack` whose children are two
   `Menu`s with `.menuStyle(.borderlessButton)`, which strips a label's foreground and lets the
   control bar's own white win. The same failure, in the control next door, found by the same
   measurement. **Neither is fixed here** — this was a read-only report.

##### ⚠️ The Source line reports the wrong tier on every STREAM — FIXED IN PART 2

§6.8 lists the Source line as exercised only on an untagged **file**. Exercised on an NDI stream it
is wrong, in both directions:

```
stream declares nothing, override Auto →  Source  Rec. 709 · Rec. 709 · CICP 1/1 — tagged
override = Rec.2020 PQ              →  Source  PQ (ST 2084) · Rec. 2020 · CICP 9/16 — tagged
```

The log for the same stream reads `color signaling (NOT declared — assuming SDR Rec.709)` and then
`primaries=Rec.2020 code 9 (OVERRIDE)`. The cause: the NDI path resolves before it publishes, so
`renderer.setSourceColorSpace` always receives **non-nil** codes, and `DisplayChainModel`'s
`(pCode, tCode)` switch therefore always lands on `case let (pc?, tc?)` → `— tagged`. **§6's
three-tier honesty model — `tagged` / `assumed` / `overridden` — collapses to one tier the moment
the source is a stream**, and a *user assertion* is printed as a *sender's declaration*. The same
line is correct for a file, because a file's absent CICP arrives as nil. The renderer's codes cannot
carry the distinction; the tier has to come from `NDIColorInfo.tier` [now `SourceColorimetry.tier`], which already exists and is
already on screen two controls away. Not fixed here.

Incidentally, the **third verdict case is now exercised live**: overriding to PQ produced
`Source declares its transfer outside the rTRC (PQ/HLG); no curve comparison is possible.` §6.8
lists it as written-but-unseen.

**And the Source line does not follow a colorimetry change while the readout is open.** `refresh()`
runs on popover open, on a mode change, and on the two screen notifications; nothing observes the
renderer's source codes. Measured: the override changed the tags and the layer immediately (the log
proves it), and the open readout did not move until it was closed and reopened.

---

#### Phase 2c part 2 — the five defects, fixed and measured 2026-09-22

Part 1 was a read-only report and left five things broken. All five are fixed; each one below is
stated with the measurement that proves it, because **three of the five rendered as something
plausible while being wrong**, and one of them had already been recorded as fixed once.

##### 1 · The provenance tier now comes from the source's own resolution

`DisplayChainModel` inferred the tier from whether the CICP codes were nil. That is correct for a
file, SRT and HLS-from-buffer — their undeclared axes genuinely arrive as nil — and **wrong for NDI
and WHEP, which resolve before they publish**: an assumption and a user override both arrive as
three non-nil codes and both read "tagged".

A `SourceColorProvenance` (`tagged` / `assumed` / `partlyAssumed` / `overridden`) is now carried on
the renderer beside the codes, and `setSourceColorSpace` takes it as a **required** parameter with
no default — a default is how the next source in would re-introduce this silently. Every one of the
seven call sites states its own answer: the two file sites and HLS-from-buffer pass `.fromCodes(…)`,
which names the condition under which reading the codes is legitimate; NDI passes
`NDIColorInfo.sourceProvenance` [now `SourceColorimetry.sourceProvenance`], which existed the whole time and simply was not being passed on;
WHEP's `assumedRec709SDR` and both connect-time defaults pass `.assumed`; SRT derives from its
axes' own `declared` flags.

MEASURED, all four tiers:

| source | Source line |
|---|---|
| `wedge.mov`, untagged | `Rec. 709 · Rec. 709 · Rec. 709 · limited — CICP 1-1-1 — assumed` |
| `wedge-pq-24track.mov`, tagged | `Rec. 2020 · PQ (ST 2084) · Rec. 2020 · limited — CICP 9-16-9 — tagged` |
| NDI, declares nothing, Auto | `Rec. 709 · Rec. 709 · Rec. 709 · limited — CICP 1-1-1 — assumed` |
| NDI, overridden to HDR10 | `Rec. 2020 · PQ (ST 2084) · Rec. 2020 · limited — CICP 9-16-9 — overridden` |

##### 2 · The Source line is live

`refresh()` ran on popover open, on a mode change and on the two screen notifications. Nothing
watched the source. The renderer now posts `sourceColorStateDidChange` (object: the renderer) and
`DisplayChainModel` observes it, filtered on its own renderer exactly as the screen observers filter
on their own window. `ContentView`'s existing `effectiveIsFullRange` observer gained one line so a
**range** override reaches the line too — no new modifier, which is the only shape that file can
take (§6.7).

MEASURED: with the readout OPEN and never reopened, ⌃⌥C from Auto to Rec.2020 PQ moved the Source
line from the `1-1-1 — assumed` spelling to the `9-16-9 — overridden` one, and the verdict with it.

> ⚠️ **AND THE FIRST VERSION OF THIS FIX RENDERED AS SOMETHING PLAUSIBLE.** The notification was
> posted where the codes are stored, which is **before** `sourceDerivedColorSpace` is rebuilt. The
> readout then recomputed from a new source line and a stale colorspace: it said
> `PQ (ST 2084) … CICP 9-16-9 — overridden` above the verdict *"macOS is passing this picture
> through unchanged"* — the 709 answer, under a PQ heading, with nothing on screen to suggest a
> problem. Caught by reading the whole popover instead of the line that had just been changed.
> The post is now a `defer`, so it fires after the colorspace is installed on every exit path.

##### 3 · The subtitles draw — and §6.8's claim that they already did was wrong

**The "Three defects that rendered as something plausible" entry above records the subtitle fix as
made. It was not.** The second-`Text` form is the documented way to give a menu item a subtitle and
it silently drew nothing. That claim stood in this document for a day because the fix was verified
by *looking at* the menu, where a row with no subtitle looks like a row that was never meant to have
one — the same mistake the entry it belongs to is about.

**How it was caught:** not by looking, but by scanning the rendered menu while capturing the control
bar for part 1's report. Text has hard horizontal edges; the menu's vibrancy gradient does not.
Counting pixel pairs with |Δ| ≥ 25 across the subtitle band separates them completely:

| band | 2b's second-`Text` form | 2c's `AttributedString` form |
|---|---|---|
| row 1 subtitle, "what your client will see" | **0 glyph edges**, strongest Δ = 3 | **337 glyph edges**, strongest Δ = 53 |
| row 2 subtitle, "no colour management" | **0 glyph edges**, strongest Δ = 3 | **331 glyph edges**, strongest Δ = 54 |
| row 1 TITLE — the control, text known present | 589 | 587 |

The control row is what makes the zeros mean something: the same scan finds ~588 edges in the title
band of both captures, so it detects text where text is known to be, and found none at all where the
subtitle was supposed to be.

**Four constructions were measured in an isolated harness before anything was written here** — a
second `Text`, a `Label` with two `Text`s, a plain `"\n"` inside one `Text`, and an
`AttributedString`. Both two-`Text` forms drew nothing. The newline drew both lines but in one
style, so the subtitle read as a second title. Only the `AttributedString` drew a real subtitle —
smaller, secondary-coloured — and it keeps `Toggle`'s own checkmark, which §6.8 chose deliberately.
**Nothing reserved-but-empty ships**: the failing forms left the row at single-line height, so there
was not even blank space to mistake for a near miss.

##### 4 · The Color control turns amber on an override

`.foregroundStyle(…)` wrapped the `HStack` containing the two `Menu`s, and
`.menuStyle(.borderlessButton)` strips a label's foreground exactly as it strips its background —
§6.8's Bypass-badge defect, one control to the left.

Five constructions measured in the harness: `.foregroundStyle` inside the label (stripped),
`.foregroundColor` on the leaves (the `Text` colours, the `Image` does **not** — a half-orange
control), `.tint` on the `Menu` (colours both, but also repaints the menu's own **selection
highlight**, which is the system accent's job), `HStack { Text(Image); Text }` (colours both and
then **swallows the readout entirely**), and one concatenated `Text` with a per-run font, which is
what shipped.

> ⚠️ **THE SWALLOWED-TEXT TRAP IS THE ONE `colorControl` ALREADY DOCUMENTED, FROM THE OTHER SIDE.**
> Its own comment warns that a borderless menu "reserves and clips a trailing region for its
> disclosure indicator", so a chevron at a rich label's trailing edge disappears. Wrapping the
> symbol in a `Text` makes the label a MIXED one — a text-like element beside a view — and the same
> clip then eats the READOUT instead. **This was shipped into a build and measured**: the face
> dropped from 214 pt wide to 28, the palette glyph alone, with the label gone. A single `Text` is
> not a mixed label and is not clipped.

MEASURED on the face region, same rect both times:

| state | max(r − b) | pixels with r − b > 30 |
|---|---|---|
| Auto | **1**, on a pixel reading (237, 236, 236) — a neutral antialiased edge, not colour | **0** |
| Overridden to Rec.2020 PQ | **208**, peak pixel (255, 146, 47) | **637** |

And the control bar was captured before and after the change at identical window geometry: the
face occupies the same span, and the display-transform control beside it stays white. **No layout
change.**

##### 5 · The Source line format

Full CICP, in CICP's own order, with the words in the same order as the numbers:

```
Rec. 709 · Rec. 709 · Rec. 709 · limited — CICP 1-1-1 — assumed
Rec. 2020 · PQ (ST 2084) · Rec. 2020 · limited — CICP 9-16-9 — overridden
```

The earlier form printed **transfer first and primaries second** while calling the numbers
"CICP p/t", so the words and the numbers disagreed about which axis was which — readable only by
someone who already knew the answer. Matrix was absent entirely, and so was range.

Matrix and range come from the same resolution as primaries and transfer: `sourceMatrixCode` is the
code the DeckLink encoding matrix is already chosen from, and range is read from
`isFullRangeProvider` — **the same closure the shader reads**, so the readout cannot disagree with
the picture, and it already folds in the user's range override. **`nil` prints "range unknown"**
rather than "limited": a renderer with no provider has no answer, and printing one would be a guess
wearing a fact's clothes.

An absent axis still prints the code the renderer is USING rather than a dash — §6.8's existing
rule, and why the untagged wedge reads `CICP 1-1-1` and not `CICP ---`. The tier carries the
absence, which is the whole point of separating them.

##### Byte identity against the commit before it — measured, and this is the strong form

§6.7 and §6.8 both establish `.os` as **0 codes** against the build before them, by stashing,
building `HEAD` into a separate derived-data path and capturing at matched geometry. That was done
again here, against `2443151` (2c part 1), on the **same fixture, same window geometry, both
displays**, with the pointer warped off the window so the HUD bar auto-hides and the frame is
picture only.

| comparison | result |
|---|---|
| **CONTROL** — HEAD, LG, OS vs itself 5 s later | **0 codes** |
| **CONTROL** — tree, LG, OS vs itself 5 s later | **0 codes** |
| **HEAD vs tree — LG TV SSCR2, OS** | **0 codes, 0.00 %** (1500×844) |
| **HEAD vs tree — ASUS PA147, OS** | **0 codes, 0.00 %** (924×520) |
| **HEAD vs tree — ASUS PA147, Bypass** | **0 codes, 0.00 %** (924×520) |
| **SANITY** — tree, ASUS, OS vs Bypass | **21 codes, 93.69 %**, worst **170 → 149** |

The two controls are what make the zeros mean something: the picture is stable across time in both
builds, so a 0 is "nothing moved" rather than "nothing was measured". And the sanity row reproduces
§6.7's **21 codes, 93.69 %, worst 170 → 149** to the digit, three phases later, from a build with a
rewritten source path — so the instrument still sees a difference when there is one.

The two binaries differ in size and SHA-256, which is the check that two different builds were
actually compared rather than one twice.

> ⚠️ **AN EARLIER, SLOPPIER RUN OF THIS CHECK GAVE 12 CODES / 91.41 % AND IS SUPERSEDED.** That one
> was captured with the control bar PINNED, so the HUD was composited over the bottom of the
> picture and the window was a different size. The bar is chrome, not picture; including it makes
> the number describe the capture rather than the transform. The table above is the corrected run.

##### ⚠️ The ONE behaviour change outside the readout, and it is in the no-op guard

`setSourceColorSpace` compares the incoming values against the stored ones and returns early when
nothing moved. **The provenance is now part of that comparison**, and it has to be: without it, an
override to the preset the stream was already assumed to be — **Auto → Rec.709 (SDR) on an untagged
709 stream** — moves no code at all, is swallowed by the guard, and the readout goes on calling a
user assertion "assumed". The `defer` that announces the change is after the guard, so the guard
term is load-bearing for the fix.

The consequence, measured on exactly that transition:

```
[NDI] colorimetry override → Rec.709 (SDR)
[NDI] colorimetry CHANGED (Assumed → Overridden): … code 1 (OVERRIDE) …      ← pre-existing
[EDR] source tags: primaries=1 transfer=1 matrix=1 (MID-SOURCE CHANGE …)      ← NEW
[EDR] layer colorspace = kCGColorSpaceCoreMedia709  (wideGamut=false)         ← NEW
[EDR] wantsExtendedDynamicRangeContent = false  (SDR source → EDR OFF …)      ← NEW
[EDR] colour state installed on the layer after 276 present(s) of this source ← NEW
      — ⚠️ AFTER a frame was already on screen … Re-rendering to repair it.
```

So that one transition now does a **redundant republish**: the same `CGColorSpace` object, the same
EDR flag, and one re-present of the current frame. **No pixel changes** — it installs what was
already installed, and the byte-identity table above covers the rendered result. The NDI-side lines
are not new; `NDIColorInfo` [now `SourceColorimetry`] is `Equatable` over its axes' provenance, so the receive path always saw
Assumed → Overridden as a change and always re-tagged. Only the renderer used to swallow it.

⚠️ **The new `[EDR]` block carries a warning line that will mislead somebody**: "AFTER a frame was
already on screen; that frame was drawn through the previous colour state. Re-rendering to repair
it." In this case there is nothing to repair — the previous and new colour states are identical.
Left as-is rather than special-cased, because a guard that decides which republishes are "real" is
how the swallowing comes back; but it is worth knowing before it turns up in a log during Phase 3.

##### ⚠️ One gap this format makes visible, NOT fixed here

`Rec.2020 SDR` (transfer code **14**) has no entry in `MediaInspector.transferName`, so that preset
prints `Rec. 2020 · — · Rec. 2020 · limited — CICP 9-14-9 — overridden`. **Measured.** The hole is
pre-existing — the old format had it in the same axis — and it is in ManifoldCore, shared with the
inspector, so it is left alone here rather than widened into a change nobody asked for. The number
is right; the word is missing.

---

#### Still open after Phase 2b — amended after 2c parts 1 and 2

- ~~**`didChangeScreenProfileNotification` untested live.**~~ **Amended:** the path was exercised on
  a real macOS HDR toggle and the readout follows a profile change with the window stationary. What
  remains is narrower and different: `didChangeScreenNotification` fires at the same toggle, both
  route to one `refresh()`, and **which name carried it is not decidable** without a log line inside
  `refresh()`. See 2c part 1 § C.
- **The auto-hide interaction with the standing indicator** — **partly answered.** The window title
  now carries the marker and does not auto-hide (2c part 1 § B). **Full screen still has no marker
  at all, by decision.** The control-bar badge's own auto-hide is unchanged.
- **§6.3's momentary compare (hold-to-compare) is not built.** It is named in §6.3 as the gesture
  that actually gets used, and in §6.4's 2b list. Only the sticky modes exist.
- ~~**The Source line has only been exercised on an UNTAGGED file.**~~ ~~**Exercised on a stream,
  and it is WRONG.**~~ **FIXED in 2c part 2** — all four tiers measured, on a file and on a stream.
  The `partly assumed` spelling is still unseen: no source in hand declares some axes and not
  others.
- ~~**The Source line does not follow a colorimetry change while the readout is open.**~~ **FIXED
  in 2c part 2**, measured with the readout open and never reopened.
- ~~**The pulldown's subtitles do not render, and the Color control does not turn amber.**~~ **BOTH
  FIXED in 2c part 2**, each proven by a pixel scan rather than by looking.
- **`Rec.2020 SDR` (transfer 14) has no name in `MediaInspector`**, so that one preset prints a dash
  where the transfer word goes. Pre-existing, now visible, deliberately not fixed. 2c part 2.
- **One fixture, one session.** No colorimeter, 8-bit captures, as everywhere else here.

### 6.9 Colorimetry override audit — 2026-10-06

**The question:** what it takes to give SRT, WHEP and HLS the colorimetry override NDI already has.
This was a reading audit, not a measurement. File:line references are against `946417a`.
Stage A later renamed the types and moved them into the `ColorimetryModel` package target:
`NDIColorimetryOverride` → `ColorimetryOverride`, `NDIColorInfo` → `SourceColorimetry`, `NDIColorAxis` →
`ColorimetryAxis`, `NDIColorProvenance` → `ColorAxisProvenance`. `SourceColorProvenance` kept its name
and moved too. The app-side extension (NDI parse, CoreVideo tagging, log wording) is now
`App/Live/SourceColorimetry+App.swift`. The new names are given in brackets below; the line numbers
still describe the audited commit.

**Superseded before it was written down.** The audit's scope-header findings were fixed by `946417a`
(`ScopeColorFeed`), which landed before this section was written. The findings were: WHEP and HLS
never wrote scope colour, nothing reset it on teardown, and toggling the scopes tray reloaded the
last file's metadata during a live stream. Scopes now follow the renderer's source state, and only
`ScopeColorFeed` writes it (CLAUDE.md). An override on any transport reaches the scopes by going
through `setSourceColorSpace`, and needs no scope work of its own. They are recorded here so the
audit reads complete, not as open items.

**Wrong in the audit:** it said SRT reads its colour from the bitstream. It does not. Every SRT stream
arrives UNDECLARED on all three axes, because the vendored FFmpeg has the H.264 parser and no decoder,
and `codecpar->color_*` is filled by decoding. Measured; see BUGS.md, *"SRT colour always reads
UNDECLARED"*. The comments that say otherwise (`App/SRT/SRTFrameRouter.swift:159-185`,
`App/Live/LiveDisplayRoute.swift:66-71`, `App/WebRTC/WHEPFrameRouter.swift:489`) are corrected in
Stage SPS, below.

#### Findings

1. **The override exists on NDI only, and it is process-wide.**
   - Type: `NDIColorimetryOverride` [now `ColorimetryOverride`, in the `ColorimetryModel` package],
     `App/NDI/NDIColorInfo.swift:66`. Its presets are at `:79-88`, and `NDIColorInfo.resolve`
     [now `SourceColorimetry.resolve`] (`:180`) is the only place a preset meets a declaration.
   - Held on the `NDIService` singleton: published value at `App/NDI/NDIService.swift:164`, lock
     mirror at `:308`, setter at `:320`, reset to `.auto` on every connect at `:723`.
   - It reaches the renderer at `NDIService.swift:2652`, carrying `effective.sourceProvenance`, so
     the readout says `overridden`.
   - UI: the Color control, `App/ContentView.swift:2153`, shown only when NDI is the live source
     (`:3163`). Picker at `:2230`, binding at `:2260`, keyboard cycle at `:1986`.
   - The type is NDI-named but is not NDI-specific. `SRTFrameRouter.swift:163-200` already says so.
2. **SRT has no override hook.** Its colour is fixed at activate:
   - `SRTFrameRouter.StreamColorimetry` (`App/SRT/SRTFrameRouter.swift:206`, provenance at `:237`)
     goes through `LiveDisplayRoute.Colorimetry` (`App/Live/LiveDisplayRoute.swift:72`), and from
     there to the renderer once, at `LiveDisplayRoute.swift:223`.
   - Because of the FFmpeg defect above, the tier is always `assumed`.
3. **WHEP has no hook and reads nothing.** It passes the constant `.assumedRec709SDR`
   (`App/WebRTC/WHEPFrameRouter.swift:491`; the constant is at `LiveDisplayRoute.swift:88`), because
   its RTP depacketizer does not parse the SPS VUI.
4. **HLS re-reads its colour per frame, so an override has to win over a rendition change.**
   - It starts on assumed 709 (`App/HLS/HLSClient.swift:870`).
   - Each buffer's attachments are read through `cicp(of:)` (`:1537`), and
     `publishColorTagsIfChanged` (`:1267`) calls `setSourceColorSpace` whenever the codes change.
   - With an override active, that publisher must not overwrite it. It should keep tracking the
     declared value for the Color control's "Stream" line.
5. **HLS maps two codes differently from the rest of the app.**
   - **P3-D65 → 11** (`HLSClient.swift:1551`). CICP 11 is DCI-P3. The NDI preset (`NDIColorInfo.swift:85` [now `ColorimetryOverride.p3d65PQ`])
     and `makeColorSpace` (`App/MetalVideoRenderer.swift:1506`, `case (12, _)`) use 12. An 11 falls to
     `makeColorSpace`'s default arm (`:1520`), so the layer is tagged 709 primaries. The scope headers
     treat 11 and 12 alike and say "P3" (`App/CIEScope.swift:180`, `App/WaveformScope.swift:63`).
     So a P3-D65 HLS stream would be drawn as 709 while its scopes say P3. Read from the code, not
     yet observed. Decision 6 fixes it.
   - **BT.2020 transfer → 1** (`HLSClient.swift:1566`). The comment there says this is on purpose,
     so the curve gets named. The NDI `Rec.2020 SDR` preset sets 14 (`NDIColorInfo.swift:86` [now `ColorimetryOverride.rec2020SDR`]). The
     same signal therefore gets a different code depending on transport, and the readout and headers
     show the difference: 14 has no name in `MediaInspector` (§6.8 *Still open*).
6. **Rec.2020 SDR does not do what it says on any transport.** `makeColorSpace` handles (9,16) and
   (9,18). (9,1) and (9,14) both fall to the default arm, which tags 709 primaries (§7.3). An NDI
   user who picks Rec.2020 SDR gets 2020 maths in the scopes and 709 primaries on the layer.
   Offering the same preset on three more transports would spread that defect further.
7. **The audio offset is the persistence pattern to copy.**
   - `LiveAudioOffsetModel` is one per window (`App/WindowDeck.swift:259`). It is seeded from the
     bookmark in `DeckRegistry.connectLive` (`WindowDeck.swift:1595-1600`) and saved or reverted
     from the live menu only (`App/Live/LiveAudioOffset.swift:118`, `:130`, `:246`).
   - It is persisted as an optional field, `StreamBookmark.audioOffsetMs`
     (`Packages/ManifoldCore/Sources/StreamBookmarkModel/StreamBookmark.swift:98`). When the field is
     nil it is left out of the JSON.
   - `StreamBookmark` uses synthesized `Codable` (`:87`). A new enum-typed field that meets a raw
     value this build does not know (a preset added later, then a downgrade) would fail decoding for
     the whole bookmark. Store a raw string instead, and decode it tolerantly.
8. **No transport shows an override in the window title.** `windowTitle`
   (`App/WindowDeck.swift:322`) appends the A/V suffix and the Bypass suffix. The only standing
   sign of an override is the Color control's amber tint (`ContentView.swift:2221`), and it
   auto-hides with the control bar.

#### Findings 9–16, missing from the first write-up

These were in the original audit and left out when the section above was rebuilt. Each reference was
checked against `5fabcea`. No app code changed between `946417a` and `5fabcea`, so findings 1–8 still
hold. Where the audit's line number had drifted, the corrected one is given below.

9. **Nothing here has a unit test.**
   - The app has one target, `Manifold` (`project.yml:137-138`), and no test bundle.
   - `NDIColorInfo` [now `SourceColorimetry`] (`App/NDI/NDIColorInfo.swift`), `SourceColorProvenance`
     (`App/MetalVideoRenderer.swift:135`) and `DisplayChainModel` (`App/DisplayChainModel.swift`)
     all live in `App/`, which `swift test` does not reach.
   - The NDI override and the readout tiers were verified by measurement only, all in §6.8 2c
     part 2: the tier table (#1), the amber pixel scan (#4) and the byte-identity captures.
   - Stage A's move into a package is what makes them testable.
10. **Two colour inputs have to move together.**
    - The shader takes its YCbCr matrix from each frame's buffer tags: `colorParams(for:)`, at
      `App/MetalVideoRenderer.swift:3680` (the audit had ~3662), called at `:2681`.
    - Everything else takes its colour from `setSourceColorSpace`: the layer colorspace, EDR, the
      scope maths, the CIE codes, DeckLink tagging (`App/DeckLink/DeckLinkService.swift:711`) and
      PNG export (`sourceDerivedColorSpace`, `MetalVideoRenderer.swift:3568`).
    - NDI updates both from one `effectiveColorInfo` (`App/NDI/NDIService.swift:2605`). It tags the
      buffer with `tagOutput` (`:2664`, called at `:794`) and sets the renderer at `:2652`.
    - **Every override stage must update both.** If it doesn't, the picture is decoded with one
      matrix while the scopes, readout and outputs describe another.
11. **When Phase 3 Reference lands, it must choose its curve from the renderer's
    `sourceTransferCode`** (`MetalVideoRenderer.swift:933`). That value carries the override. If
    Reference read the buffer tags instead, an override would apply to everything except the
    display transform. `App/DisplayTransform.swift:13-23` is where Reference will be built.
12. **A live stream never moves between windows**, so a per-window override never has to follow it:
    it ends when the stream ends.
    - The device hooks are not re-pointed while anything is live (`App/WindowDeck.swift:1244-1247`).
    - Closing the owning window releases the stream (`:875-880`).
    - A claim from another window is refused (`:1530-1535`).
    - What happens when a second stream of the same type is connected in the same window:

      | Swap | What happens | Override |
      |---|---|---|
      | NDI → NDI | Swapped in place. | Reset, because `start(with:)` calls `resetColorimetry()` (`NDIService.swift:518`, `:714`). |
      | SRT → SRT | Full teardown, then a new session (`App/SRT/SRTClient.swift:442-474`). | Starts fresh. |
      | HLS → HLS | Swapped in place (`App/HLS/HLSClient.swift:800-831`). | Stage E must decide whether it carries over or resets. |
      | WHEP → WHEP | Refused while a session runs (`App/WebRTC/WHEPClient.swift:135-153`). | Not reached. |
13. **The Color control and its amber indicator are NDI-only.**
    - The control is shown only when NDI is live: `App/ContentView.swift:3163`, not ~3236 as the
      audit had it.
    - Its label (`:2245`), tint (`:2221`) and binding (`:2260`) all read `ndi.*`.
    - Generalising it must not add modifiers to `ContentView`'s body, which is at the type-checker's
      limit (§6.7).
14. **Menu-row subtitles on any new preset picker must use the `AttributedString` form.** The
    two-`Text` form draws nothing (§6.8 2c part 2, #3).
15. **HLS colour changes land one frame late, by design** (`App/HLS/HLSClient.swift:1236-1266`).
    Override changes on HLS will do the same. As on the rendition path, the next tick re-presents the
    frame under the new state.
16. **SRT and WHEP are H.264-only.**
    - SRT refuses HEVC with a visible error (`App/SRT/SRTClient.swift:772-787`).
    - WHEP negotiates only H.264 (`App/WebRTC/WHEPClient.swift:648-649`).
    - So 10-bit HDR on these paths can only arrive as 10-bit H.264. That is why the 10-bit H.264
      decode measurement must be done before Stage B. If it doesn't decode, an HDR override on SRT
      or WHEP would only ever be applied to 8-bit pictures.

#### Decisions (Robbie, 2026-10-06)

1. **Where the override lives.** SRT, WHEP and HLS keep it on the owning window, following the
   `LiveAudioOffsetModel` pattern, and set it up in `connectLive`. NDI keeps it on `NDIService`,
   for the session only, and changes only to use the shared type.
2. **HLS is saved per bookmark** too, the same as SRT and WHEP.
3. **Rec.2020 SDR is hidden on SRT, WHEP and HLS until §7.3 is fixed in Phase 4.** NDI keeps it for
   now. BUGS.md records that NDI's Rec.2020 SDR is flattened to 709 primaries; it is enabled
   everywhere once §7.3 is fixed.
4. **An active override adds a window-title suffix on all four transports**, NDI included. It sits
   alongside the Bypass and A/V suffixes.
5. **The Stream Sources sheet gets no edit field.** Save and Revert are in the live menu only, as
   for the audio offset.
6. **The HLS P3-D65 code fix (11 → 12) is its own commit, ahead of Stage E.** It is verified with a
   P3-tagged HLS test stream (ffmpeg and a local server).
7. **WHEP reads declared colour from the H.264 SPS colour signalling** (revised from the audit's
   question). One shared SPS colour reader serves WHEP and also fixes the SRT defect in BUGS.md.
   The FFmpeg build does not change.

#### Staged plan, revised

Run in this order.

- **Stage A — shared type.**
  - Move the override type into a ManifoldCore package target and point NDI at it.
  - Add unit tests.
  - No behaviour change.
- **Stage SPS — shared H.264 SPS colour reader for SRT and WHEP.** Done 2026-10-07, below, OBS
  re-check included.
  - SRT and WHEP report declared or assumed for each axis.
  - Correct the "SRT can state the truth" comments.
  - Check again whether OBS → SRT really declares nothing.
- **Stage B — SRT override, per session.**
  - The override goes through `setSourceColorSpace(…, provenance: .overridden)`.
  - The scopes need no extra work: they follow the renderer since `946417a`.
- **Stage C — WHEP override, per session.** Same pattern as Stage B.
- **Stage D — save per bookmark for SRT, WHEP and HLS.**
  - Add an optional raw-string field to `StreamBookmark`, decoded tolerantly.
  - Add migration tests.
  - Save and Revert in the live menu.
- **Stage E — HLS override.** The P3 code fix (decision 6) lands before it.

**Measured before Stage B ships:** both answered in Stage SPS, below.
- Does VideoToolbox convert pixels when SRT or WHEP source buffers are tagged PQ, HLG or 2020? If
  it does, an override changes the pixels as well as their interpretation. **No.**
- Does 10-bit H.264 decode on these paths? **Yes, on both.**

#### Stage A — done 2026-10-06, measured as no behaviour change

**What moved:** the override presets, `resolve`, the provenance and tier mapping and the tier wording,
under transport-neutral names (above), into the `ColorimetryModel` package target, with per-transport
preset availability and Stage D storage strings. 13 unit tests.

**Method.** Unattended runs with the scratch NDI SDK sender sending static SMPTE HD bars and no colour
metadata. The window was on the ASUS PA147 at 875×492. The sequence: connect, ⌃⌥C through every preset
and back to Auto, then disconnect. HEAD (`0ea88e0`) was run twice (H1, H2; H2 is the control) and the
Stage A build twice (T1, T2). The two binaries differ in SHA-256. Predictions with pass/fail bands were
written before the code changed.

**T1 is void, as a harness drop.** Its first ⌃⌥C logged nothing at all, and every later step landed one
preset behind. Every line it did log had the right values for its preset. T2, with the same binary,
landed every keystroke.

| Check | Method | Result |
|---|---|---|
| `[NDI]` and `[EDR]` lines | NSLog prefix stripped. Periodic timing lines dropped (`fps received`, `picture held`, `picture hold basis`, `first audio`). The present count in `colour state installed … after N present(s)` masked. Compared **per step, per thread**: each step's `[NDI]` lines in their own order, then its `[EDR]` lines in theirs. | H1, H2 and T2 identical, 97 lines each. The full line sets also match. |
| `[SCOPE-COLOR]` lines | Exact sequence | T2 identical to H1 and H2. H1 matched all ten predicted lines. |
| OS mode, ASUS | §6.8 byte-identity method: window capture, HUD hidden, 8-bit per-channel compare | **T2 vs H1 and vs H2: 0 codes, 0.00 %** for Auto and for the 2020 PQ override. Controls (each build 5 s apart, H1 vs H2): all 0. **Sanity, Auto vs PQ: 228 codes, 83.02 %.** |
| Color control | Control bar shown, the control's region compared, amber pixels counted | HEAD vs Stage A: 0 codes, 0 px in every state. Auto: `709 709 · Assumed`, white, 0 amber px. Rec.709: `709 709 · Overridden`, amber (240 px). 2020 PQ: `2020 PQ (ST 2084) · Overridden`, amber (348 px). Same tint on both builds (commonest pixel 255,146,48). |

**Why per thread.** The `[NDI] x422 output tags` pair is logged by the tagging on the display-link pull.
The `[EDR]` lines are logged on main. The interleave between the two is not ordered: HEAD varies it from
step to step within one run, and H1 against H2 differ at connect. A strict line-order comparison fails
on HEAD against itself. **Reuse this comparison for Stages B–E.**

**The Rec.709 case** is overridden but has the same codes as Auto. It shows that amber follows the
override's tier, not the codes, on both builds.

#### Stage SPS — done 2026-10-07

**What changed.** SRT and WHEP read declared colour per axis from the stream's own SPS VUI. An axis the
SPS leaves absent, unspecified (2) or reserved is undeclared and keeps the assumed-709 behaviour. The
FFmpeg build did not change.

- **The reader:** `H264SPSColor`, a new leaf target in ManifoldCore, with 13 unit tests.
- **Shared with the app:** `StreamColorimetry` (App/Live) replaces `SRTFrameRouter.StreamColorimetry`.
  It turns one SPS reading into the renderer's codes and tier, the buffer tags and the log line.
  Both halves of finding 10 come from that one value.
- **The hook:** `LiveVideoDecoder.onSPSColor`. It fires once per change of SPS bytes, on the decode
  thread, before the access unit carrying the SPS is decoded. Decode is synchronous, so every frame
  after it is tagged with the colour it was encoded with.
- **SRT** activates its route on the first SPS reading instead of at `onVideoFormat`. It costs no
  picture, because nothing decodes before an SPS, and audio before the video anchor is dropped
  anyway. The codec gate still runs at `onVideoFormat`.
- **WHEP** still activates before media exists, stating assumed 709. What the SPS declares replaces it
  when the first picture is presented.
- **A later SPS** that changes the colour re-tags buffers from the next decoded frame. The renderer
  hears through the new `LiveDisplayRoute.updateColorimetry`, which calls `setSourceColorSpace` and
  which Stage B will reuse. That hop is timed for the presentation of the first new-colour frame, so
  the ~0.25 s (SRT) or ~0.4 s (WHEP) of old frames still queued are not drawn under the new colour.
- **The log:** `[SPS-COLOR]` once per change, per axis, with the SPS's raw number beside the verdict.
  It also gives `video_full_range_flag` against the range in use. Range is still each transport's
  own: SRT from codecpar, WHEP pinned limited. Nothing acts on the flag.
- **The comments** that said libavformat fills `codecpar->color_*` on SRT are corrected in
  `SRTFrameRouter`, `LiveDisplayRoute` and `WHEPFrameRouter`. So is the matching SAR claim in SRT's
  `deliver`, which rested on the same reasoning and is now marked unmeasured.

##### Step 1 — CoreMedia was measured first, and is not reliable per axis

`CMVideoFormatDescriptionCreateFromH264ParameterSets` with fixture SPS bytes, and VideoToolbox decoding
the first IDR to `x420` and to its native format:

| SPS declares | Format description extensions | Decoded buffer attachments |
|---|---|---|
| 709 · 709 · 709 | 709 · 709 · 709 | same |
| 2020 · PQ · 2020 / 2020 · HLG · 2020 | correct | same |
| 6 · 6 · 6 (BT.601) | SMPTE_C · **ITU_R_709_2** · 601 (transfer 6 respelled 709) | same |
| nothing (no VUI / no signal type / no colour description) | none | **SMPTE_C · 709 · 601, invented** |
| 2 · 2 · 2 (explicit unspecified) | none | **SMPTE_C · 709 · 601, invented** |
| 3 · 0 · 3 (reserved) | `ColorPrimaries#3` · none · `YCbCrMatrix#3`: reserved passed as declared | partly |
| 200 · 100 · 99 (reserved) | `#200` · `#100` · `#99`: all passed as declared | same |
| 12 · 13 · 0 | P3_D65 · sRGB · **none (matrix 0, a declaration, dropped)** | same |
| `video_full_range_flag` absent vs 0 | `FullRangeVideo` 0 in both | — |

So the format description fails the per-axis rule (reserved counts as undeclared), and the decoded
buffers are worse than nothing: they turn "undeclared" into a confident 601. Hence the parser.

##### Unit tests — prediction 1, PASS

**Fixtures:** 22 real SPS, from the system ffmpeg (libx264, libopenh264, h264_videotoolbox), with
`h264_metadata` used for the unspecified, partial and reserved cases. They cover:

- 709, PQ/2020, HLG/2020, 601 and 470BG;
- no VUI; VUI with no signal type; signal type with no colour description;
- Baseline, High, High 4:4:4 (chroma 3), High 10, interlaced and cropped;
- Extended_SAR putting `00 00 03` inside the VUI before the colour fields;
- 2/2/2, 9/2/9, 3/0/3, 200/100/99, matrix 0 and 11/4/14.

**Scaling lists:** x264 writes scaling matrices only in the PPS. So lists were spliced into x264's
PQ SPS: an explicit 4×4 list, a use-default list and an explicit 8×8 list. FFmpeg reads 9/16/9 after
them, and its decode differs from the flat-matrix original, so the lists are live.

**Expected values:** FFmpeg's reading, not this reader's. ffprobe is not installed, so
`ffmpeg -bsf:v trace_headers` was used: libavcodec's CBS parser, which prints every SPS field.

**Result:** every field of every fixture matches. Every prefix of five SPS reads either the exact
colour or undeclared, never a different colour. SPS-typed garbage, an all-zero SPS and an oversized
one all return. Two deliberate mutants, no emulation-prevention removal and scaling lists not walked,
each fail 6 of 13 tests. Both failed *closed*, reading undeclared and never a wrong colour.

##### The pixel question — answered before any wiring, because a yes was a stop

Same slices with the SPS VUI varied by `h264_metadata`, 1280×720 SMPTE bars. Every byte of every plane
was compared, in the §6.8 shape, with a control and a sanity case:

| comparison | bytes differing |
|---|---|
| CONTROL: decode → `x420`, 709 SPS twice | 0 / 2 764 800 |
| decode → `x420`: 709 SPS vs PQ/2020, vs HLG/2020, vs no colour description | **0, 0, 0** |
| CONTROL: promote (VTPixelTransferSession 420v → `x420`), source tagged 709 twice | 0 |
| promote with the SOURCE tagged 709 vs PQ/2020, vs HLG/2020 | **0, 0** |
| SANITY: the same re-tag into 32BGRA | **895 416 / 3 686 400 (24.29 %)**, worst Δ 13 |
| SANITY: decode straight to 32BGRA, 709 SPS vs PQ SPS | 24.29 % |

**Neither VideoToolbox step changes a pixel because of the colour tags. The instrument does see a
difference when one exists.** The promote carries the tags through to its output. And in every live
run below, VT honoured `x420` (`decoded as 'x420' — … no promote needed`), so the promote did not run
at all.

**10-bit H.264 (High 10):**

- **Offline:** decodes to `x420`, bit-exact against ffmpeg's decode (921 600 luma samples, 0 differ).
- **SRT, live:** decodes, 180/180 access units, ~25 fps, `x420`, tagged 9-16-9.
- **WHEP via MediaMTX, live:** also decodes, ~25 fps, 0 errors, tagged 9-16-9, even though our offer
  says `profile-level-id=42e01f` (Constrained Baseline). MediaMTX sent High 10 regardless. That is the
  server's choice, not a guarantee. Predicted not to decode: **miss**.

So an HDR override on SRT or WHEP will not be limited to 8-bit pictures (finding 16), at least with
MediaMTX as the WHEP server.

##### Device runs — predictions 2–6

**Rig:** unattended, unsigned Profile builds.

- **Builds:** HEAD `c14a1d8`, SHA-256 `7144fa65…`, against the tree, `d7674e5f…`.
- **SRT:** an ffmpeg listener, connected with ⌃⌥D and `MANIFOLD_SRT_DEBUG_URL`.
- **WHEP:** ffmpeg publishing SRT into the idle local MediaMTX, read back over WHEP from its saved
  bookmark. Audio was Opus, for WebRTC.
- **Streams:** 1280×720/25 with AAC. Baseline, plus a High profile with B-frames for SRT.
- **Defaults:** the domain was exported before the first launch, and `streamBookmarks` stashed. After
  the last quit the domain was restored and verified dictionary-equal (1 141 keys).
  `streamBookmarks` was never written.

| stream | SRT `[SCOPE-COLOR] source` on connect | WHEP `source` on connect | readout | result |
|---|---|---|---|---|
| PQ/2020 | 1: `Rec. 2020 · PQ (ST 2084) — tagged (CICP 9-16-9)` | 2: `assumed (1-1-1)`, then the tagged line | `… · limited — CICP 9-16-9 — tagged` | PASS |
| HLG/2020 | 1: `… HLG — tagged (9-18-9)` | 2 | `9-18-9 — tagged` | PASS |
| 709-declared | 1: `… — tagged (1-1-1)` | 2 | `1-1-1 — tagged` | PASS |
| untagged | **0** (HEAD: 0) | 1: `assumed (1-1-1)` (HEAD: same) | `1-1-1 — assumed` | see below |
| PQ, High + B-frames (SRT) | 1, tagged 9-16-9, 0 decode failures | — | — | PASS |
| HEAD, PQ | **0. `[SRT] colorimetry: primaries=UNDECLARED …` on every axis**: the defect | `assumed (1-1-1)` only | — | the before |

**Disconnect:** every row gave exactly 1 `source` line (cleared, `assumed (–-–-–)`) and 1 `released`.
The untagged SRT row gave 0 + 1, because its state already equals the cleared one.

**The earlier scope run's rows 9 and 10, SRT PQ then killing the sender: PASS.** 1 source on connect,
then 1 source + 1 released on the drop.

**Untagged SRT — a miss in the prediction, not in the build.** I predicted 1 `source` line. The
undeclared SRT state (nil, nil, nil, assumed) is the cleared state, so the renderer's no-op guard
swallows it. HEAD does the same: 0 lines on connect, 1 `released` on drop. The scope run's row 11
had predicted exactly that. The part that mattered is identical to HEAD.

**[SPS-COLOR]:** exactly one line per stream, matching the row. `video_full_range_flag` was 0 on every
x264 stream that wrote a signal type, and the range in use was limited, so it agreed every time. The
untagged streams carry no `video_signal_type` (flag absent). **No disagreement was seen.**

**The Color control:** absent on SRT and WHEP before and after, as predicted (NDI-only, finding 13).
The scope headers agreed with the readout. Waveform `luma Rec. 2020` for 9-x-9 and `luma Rec. 709`
otherwise. The CIE header is the `[SCOPE-COLOR]` text. The parade and waveform rulers read `HLG *`
on every source, because that machine's `manifold.scope.verticalScale` is `hlg`: forced, not followed.

**Mid-stream SPS change — prediction 4, PASS on both transports.**

**The stream:** one continuous stream, 10 s declared 709 then 10 s PQ/2020, looping, served without
disconnecting. MediaMTX passes the in-band SPS change through to WebRTC.

**The result:** each change gave exactly one `[SPS-COLOR]` and one `source` line. The chain readout
followed.

| | SPS read → renderer switched | |
|---|---|---|
| SRT (target 0.25 s) | +0.300 s, +0.263 s (earlier build: +0.280, +0.282) | |
| WHEP (target 0.40 s) | +0.433 s (first reading), +0.450 s, +0.455 s | |

The renderer moves when the first new-colour frame is due, so the buffer tags and the renderer's codes
describe the same pictures to within the hop.

**Regression — prediction 6, PASS.** `[SCOPE-COLOR]` and `[NDI] colorimetry override` lines, HEAD
against the tree, diffed by machine:

- **NDI:** the scratch NDI SDK sender, no colour metadata; connect, ⌃⌥C through all six presets back
  to Auto, disconnect. 15 lines each, **identical**.
- **HLS:** Apple bipbop. 5 lines each, **identical**: assumed 1-1-1, tagged 1-1-1, cleared, released.

All these lines are logged on main, so no per-thread split was needed.

##### A defect the device run caught, fixed before the results above

The first WHEP run logged `[SPS-COLOR] … → tagged` and then never told the renderer. A PQ stream
stayed `assumed (1-1-1)` for the whole connection.

**Cause:** the hop's delay was computed from a `now()` read *before* `registerFrame`. The first frame
of a stream is the one that anchors the clock, so that read was the unanchored clock's −∞, and the
delay was +∞. SRT's mid-stream path had the same shape latently. SRT's own first reading activates
the route directly, so it never hit it.

**Fix:** `LiveDisplayRoute.secondsUntilDue` reads the clock after registration and treats a
non-finite delay as now. All results above are from the fixed build. SRT was re-run on it.

##### The OBS re-check — attended (Robbie), 2026-10-07

**Rig:** OBS, profile "SRT Local 2" (a duplicate of "MediaMTX Local"), publishing SRT to the local
MediaMTX at `srt://127.0.0.1:8890?streamid=publish:live&pkt_size=1316`. Not Cloudflare. Manifold read
`…?streamid=read:live` through ⌃⌥D and `MANIFOLD_SRT_DEBUG_URL`. A second ffmpeg reader recorded 15 s
of each setting for FFmpeg's `trace_headers`.

**Profile:** NV12 (8-bit 4:2:0) · Range Limited · 23.98 fps (checked after the profile switch) · Apple
VT H.264 Hardware Encoder · 1920×1080. The SPS is Main profile (77), 8-bit, and carries **no timing
info**, so the frame rate is not declared there.

| OBS Color Space | SPS, every one of 16 in 15 s (FFmpeg) | Manifold `[SPS-COLOR]` / `[SCOPE-COLOR]` |
|---|---|---|
| Rec. 709 | colour description present · 1 / 1 / 1 · `video_full_range_flag` 0 | 1 · 1 · 1 declared → tagged · `Rec. 709 · Rec. 709 — tagged (CICP 1-1-1)` · range flag agrees |
| Rec. 2100 (PQ) | colour description present · **9 / 16 / 9** · flag 0 | 9 · 16 · 9 declared → tagged · `Rec. 2020 · PQ (ST 2084) — tagged (CICP 9-16-9)` · agrees |

**The stage-2 spike's "a real OBS→SRT feed declares nothing" is wrong**, at least for this OBS and this
encoder. OBS declares its Color Space setting explicitly in the SPS. The spike read every axis as
unspecified from codecpar, which this build never fills (BUGS.md). The comments that relied on it
are corrected in `SRTFrameRouter`.

**What OBS's PQ stream is, which matters for Stage B:**

- **8-bit:** OBS warned "Rec. 2100 should use a format with more precision" and streamed anyway, as
  8-bit PQ in H.264 Main. Expect banding.
- **No HDR10 static metadata:** the only SEI in the recording is payload type 5 (user data
  unregistered). There is no mastering-display SEI (137) and no content-light-level SEI (144).

The chain-readout screenshot for the PQ case missed: the window had resized to 1920×1080 and the
scripted clicks fell on the picture. The `[SCOPE-COLOR]` line is the one that matched the readout
exactly in every earlier 9-16-9 run.

**Defaults:** exported before Manifold launched and restored after it quit. The domain is
dictionary-equal (1 141 keys); `streamBookmarks` was not written.

##### Still open after Stage SPS

- **Declared codes the app has no vocabulary for.** An SPS can now declare codes the renderer's
  tables do not have, for example matrix 5 (BT.470BG, the 625-line 601 matrix), matrix 0 (identity),
  transfer 4 or primaries 11. They reach the renderer and the readout as `tagged`. But
  `SourceColorimetry.matrixAttachment` and the renderer's Kr/Kb know only 1, 6 and 9, so a matrix-5
  stream is decoded with 709 coefficients under a `tagged` label. Before Stage SPS the same stream was
  decoded the same way, labelled `assumed`. Recorded in BUGS.md; not fixed here. **Decided (Robbie,
  2026-10-07):** matrix 5 maps to the 601 matrix in its own commit, after Stage SPS. **Done 2026-10-07:**
  one `YCbCrMatrix` table (ColorimetryModel) behind the renderer's Kr/Kb, the scope labels and the live
  buffer tags. On the ASUS in OS mode a matrix-5 SRT stream is byte-identical to the same frame sent
  as matrix 6, and HEAD differs by 51 codes. Lookups and measurements are in the BUGS.md entry. Matrix
  0, transfer 4 and primaries 11 are unchanged.
- **SRT taking the display at the first SPS** rather than at `onVideoFormat`: accepted (Robbie,
  2026-10-07).
- **MediaMTX's HLS of the Baseline test stream** failed to open in AVFoundation (CoreMedia −12927).
  It was not investigated; bipbop was used for the HLS regression instead.

### 6.10 HEVC over SRT — audit and decisions, 2026-10-07

**Why here:** HEVC is how 10-bit HDR (Main 10, PQ and HLG) reaches Manifold over SRT. OBS's H.264
PQ is 8-bit (§6.9, *The OBS re-check*). Decided (Robbie, 2026-10-07): HEVC on SRT lands before
override Stage B. WHEP HEVC is out of scope (`ROADMAP_IDEAS.md`).

#### The audit — read-only, with offline measurements against the vendored dylibs

- **The gate** (`SRTClient.swift`, `guard codec == "h264"`) is a policy over real gaps:
  - the access-unit builder is H.264-only;
  - the decoder builds its format description from SPS and PPS only;
  - the SPS colour reader accepts NAL type 7 only;
  - the FFmpeg build has no HEVC parser.
- **Demux.**
  - The vendored mpegts demuxer maps stream type 0x24 to HEVC in every build.
  - Without an HEVC parser, `avformat_find_stream_info` reports 0×0 with no profile and waits the
    whole window: 2 MB, or 5 s of stream at low bitrate.
  - In four HEVC test streams (x265 PQ, HLG and 150 kb/s; VideoToolbox PQ) every packet held exactly
    one picture, but only because ffmpeg's muxer and VideoToolbox write one picture per PES.
  - **On H.264 too, the one-packet-is-one-access-unit rule is the H.264 parser's guarantee.**
    `H264AccessUnitBuilder` never splits access units.
- **Decode, offline.**
  - `CMVideoFormatDescriptionCreateFromHEVCParameterSets` (VPS, SPS and PPS; 4-byte lengths) worked
    on all four streams.
  - VideoToolbox decoded each first access unit to `x420` at 1920×1080, applying VideoToolbox's own
    1088-line conformance window, with the PQ and HLG tags carried.
  - **VideoToolbox drops in-band MDCV and CLL SEI.** It attaches neither to the format description
    nor to the decoded buffers.
- **Random access.**
  - x265's default stream has one IDR, then a CRA at every keyframe, with RASL pictures after each
    CRA (NAL types `20:1 21:8`, `8:23` in 200 frames).
  - VideoToolbox's encoder uses IDR only (`20:8`).
  - So an IDR-only start would never start on a joined x265 stream.
- **Colour.**
  - The HEVC SPS VUI colour fields follow `profile_tier_level`, the conformance window, the
    sub-layer ordering loop, HEVC scaling lists, PCM, the short-term reference picture sets (with
    inter-set prediction) and the long-term references.
  - The SPS extension flags come **after** the VUI, so they need no parsing.
  - The SPS syntax differs for `nuh_layer_id > 0`.
  - ffmpeg's `hevc_videotoolbox` from the command line declared only the matrix (2/2/9) despite the
    flags, so it is not a colour-test sender without `hevc_metadata`.
- **HDR10 SEI.** x265 `hdr10=1` sends MDCV (payload 137) and CLL (payload 144) as prefix SEI at every
  keyframe. The SEI orders primaries G, B, R, where libav orders R, G, B. Nothing in the app consumes
  HDR10 metadata today: the file inspector shows it, and EDR does not use it (§6.2, no tone-map).
- **OBS 32.2.2.**
  - Its VideoToolbox HEVC encoder forces Main 10 for P010.
  - Its plugin imports `kVTCompressionPropertyKey_MasteringDisplayColorVolume` and
    `ContentLightLevelInfo`.
  - Predicted: it sends HDR10 SEI. To be verified with `trace_headers` in Stage 6.
- **Stream identification (BUGS.md, slow identification) — the cause is the audio probe, not the
  byte count.**
  - For stream type 0x0F (AAC) the demuxer sets `request_probe = 50`. While it is set, libav holds
    **every** packet, video included.
  - This build compiles no `aac`, `loas` or `mp3` demuxer, so the probe cannot succeed. It ends only
    at `probesize` (2 MB of buffered packets) or after `max_probe_packets` (2500) audio packets.
  - Offline, H.264 at 150 kb/s with AAC: ≈ 177 s of stream at today's settings, ≈ 1.1 s with
    `max_probe_packets = 1`, and 1.5 s with no audio at all.
  - The audio parameters came out identical either way. The probe can only ever confirm AAC here.

#### Decisions (Robbie, 2026-10-07)

1. **Enable the HEVC parser** in the FFmpeg build: the fifth configure change, carried through all
   three verification layers and the README.
2. **Ship Stage 0 (the probe fix) on its own**, before any HEVC work.
3. **Stage 0 sets `max_probe_packets` only.** Identifying at the first SPS (skipping
   `avformat_find_stream_info`) is not scheduled.
4. **One codec-neutral SPS reader target** replaces `H264SPSColor`. It holds the H.264 and HEVC
   readers and the shared bit reader.
5. **HEVC decoding starts on any random-access picture** (IDR, CRA, BLA). It drops the RASL pictures
   that follow until the next random-access picture.
6. **HDR10 SEI is logged only:** `[HDR10-SEI]` on change, filling `HDR10StaticMetadata` for later
   display.
7. ~~**HEVC 4:2:2 and 4:4:4 are refused at the gate with a banner.** "HEVC 4:2:2 10-bit over SRT"
   goes in `ROADMAP_IDEAS.md`.~~ **Revised (Robbie, 2026-10-07):** HDR shouldn't be shown at 4:2:0
   when the stream carries 4:2:2.
   - **HEVC 4:2:2 10-bit is a pre-release stage, Stage 3b**, after Stage 3. **Widened (Robbie,
     2026-10-09):** Stage 3b is now "4:2:2 end to end", files included (see Stage 3b below).
   - **The fallback**, where a Mac can't decode or carry 4:2:2: show it as 10-bit 4:2:0, **never
     silently**. The chain readout and a banner both say the picture was converted.
   - **4:4:4 stays refused**, with a banner.
8. **Multi-layer HEVC: the base layer (`nuh_layer_id` 0) only.**
9. **A C unit-test harness** for the new HEVC access-unit builder.

#### Staged plan

Run in this order. Each stage ships on its own.

- **Stage 0 — the identification fix (H.264 only).** `max_probe_packets` in `SRTSession.m`. Below.
- **Stage 0b — SRT audio break-up with coarse sender packing (H.264 and all SRT).** **Decided (Robbie,
  2026-10-07):** fixed before Stage 1. Pre-existing and codec-independent. BUGS.md, *SRT audio
  breaks up when the sender packs ≥ ~170 ms of AAC into each PES*. Its design, and the buffer policy
  it has to fit inside (defaults held for 1.0; trials L1 and L2 in 1.0, L3 after Stage 3), are in
  *Buffer policy — the review and its decisions, 2026-10-08*, below: 0b-2a, then 0b-2b (the reorder
  term), then L1 and L2.
- **Stage 1 — the HEVC parser in the FFmpeg build.** The gate still refuses HEVC. **Done 2026-10-09
  (uncommitted), below; every prediction met.**
  - Predicted: all three layers pass; H.264 `[SRT]` and `[SPS-COLOR]` lines identical to the commit
    before; an HEVC stream's refusal log reads `hevc Main 10 1920x1080` within about 1–2 s.
- **Stage 2 — the HEVC SPS colour reader**, in the renamed codec-neutral target. Package only.
  **Done 2026-10-09 (uncommitted), below: target `SPSColor`; every prediction met.**
  - Fixtures from x265, VideoToolbox and `hevc_metadata`, expected values from `trace_headers`. They
    cover sub-layers, scaling lists, inter-predicted reference picture sets, the conformance window,
    Extended_SAR, 4:2:2 and the reserved and partial cases.
  - Predicted: every field matches; truncated SPS read undeclared, never a wrong colour; mutants fail
    closed.
- **Stage 3 — the HEVC access-unit builder** (with its C test harness), a codec-selected reader, the
  decoder's VPS, and the gate opens for 4:2:0 HEVC. **Done 2026-10-09 (uncommitted), below: every
  prediction met except item 6's Follow-source switch, which needs one attended click.**
  - Predicted: x265 PQ/HLG/709 and VideoToolbox streams decode to `x420` with no promote.
  - `[SCOPE-COLOR]` reads 9-16-9 and 9-18-9.
  - A mid-stream join of x265 starts at the next CRA with RASL dropped and no decode errors.
  - H.264 SRT and WHEP are unchanged.
- **Stage 3b — 4:2:2 end to end** (HEVC 4:2:2 10-bit over SRT, and 4:2:2 files) (decision 7,
  revised). Pre-release. Moved here from `ROADMAP_IDEAS.md`. **Widened (Robbie, 2026-10-09):** the
  4:2:2 file half of the interlaced work merges in here, so the renderer, scope and DeckLink work is
  done and measured once (`INTERLACED_FINDINGS.md` §7–8). Per-field 4:2:0 colour is NOT part of
  this stage; it stays with the interlaced work (I3).
  - **Why:** contribution encoders send 4:2:2 10-bit, and HDR shouldn't be shown at 4:2:0 when 4:2:2
    is available. Today the SRT promote path converts anything that isn't 10-bit 4:2:0 to `x420`,
    which would resample 4:2:2 to 4:2:0 without saying so. Files have the same loss: the decode
    contract is `x420` on both file paths. That halves vertical chroma on every 4:2:2 master (BUGS.md,
    the `x420` "TWO LOSSES" note), and on interlaced masters it blends the two fields' chroma in the
    frame the scopes and SDI read.
  - **What, SRT:** decode HEVC Main 4:2:2 10 to a 4:2:2 pixel format and carry it end to end: the
    renderer, the scopes, DeckLink.
  - **What, files:** decode 4:2:2 sources to `x422`: AVFoundation through VideoToolbox, libav through
    sws to P210, and the DNx VideoToolbox decoder. Scrub and playback change together, so the scrub
    frame stays byte-identical to the playback frame. The renderer already samples `x422`
    (`MetalVideoRenderer.isTenBit`; chroma plane size taken from the buffer). Measured, not assumed.
  - **Measured once, for both halves:** the field-split fixture (`INTERLACED_FINDINGS.md` P6) and a
    progressive 4:2:2 chroma-detail check, through export (the texture SDI reads), on files and SRT.
  - **The fallback**, where the Mac can't decode or carry 4:2:2: convert to 10-bit 4:2:0, and say
    so in the chain readout and in a banner. Never silently.
  - **4:4:4 stays refused**, with a banner.
  - **Open questions:**
    - which Macs' VideoToolbox decodes HEVC 4:2:2 10-bit, and to which pixel formats — measured,
      not assumed;
    - whether every consumer of the live buffer (renderer, scopes, DeckLink v210, the promote) takes
      4:2:2 as is;
    - the 8 MB access-unit cap: an all-intra 4:2:2 10-bit frame can legitimately approach it.
- **Stage 4 — robustness and sync on HEVC.** **Run 2026-10-09 (uncommitted), below:** frame rate from the
  stream's declared timing; loss recovery and the soak met. The B-frame startup episode was found.
  Follow source and Cloudflare are attended.
  - A mid-stream colour change gives one `[SPS-COLOR]` and one `source` line, hop as in §6.9.
  - Recovery at the next random-access picture after loss.
  - A 30-minute soak and calibration, non-Cloudflare first.
- **Stage 5 — `[HDR10-SEI]`.** x265 `hdr10=1` gives one line: mastering 0.0001–1000 nits,
  MaxCLL/MaxFALL 1000/400. Nothing is logged without SEI.
- **Stage 6 — the OBS customer pass and the docs.**
  - OBS P010, Rec. 2100, VideoToolbox HEVC Main 10 → MediaMTX.
  - Predicted: 10-bit, 9-16-9, MDCV and CLL present.
  - The user guide and the tester notes stop saying "H.264 only".
- **Then override Stage B** (§6.9).

#### Stage 0 — the identification fix: predictions, written 2026-10-07 before the code changed

**Builds:** HEAD `f9d8495` (unsigned Profile, `.build-cc/s0head-Profile`) against the tree with the
one-line change. **Senders:** a local ffmpeg listener through `scripts/soak/repro/run.sh`, unattended;
then Cloudflare SRT from OBS, attended.

| # | what | HEAD, predicted | Stage 0, predicted | pass band |
|---|---|---|---|---|
| 1 | 150 kb/s H.264 + AAC bars, ffmpeg's default PES packing: transport up → first presentation | no picture within 60 s | ≈ 1–3 s | **pass ≤ 3.5 s**; fail > 6 s |
| 2a | 8 Mb/s, transport up → `[SRT] video:` | ≈ 2.4 s | ≈ 1.2 s | **faster by 0.8–1.6 s** |
| 2b | 25 Mb/s, same | ≈ 0.8–1.0 s (2 MB arrives in ≈ 0.7 s) | about the same | **faster by 0–0.5 s; never slower by more than 0.2 s** |
| 3 | `[SRT] container`, `stream`, `video:` and `audio` lines (codec, profile, size, rate, audio parameters) | — | identical text | **identical**, timestamps aside |
| 4 | `syncD-23.976p-inj0.ts` (507 kb/s, one AAC frame per PES): first anchor, startup discard, coarse and queue-full re-anchors in the first 120 s | ≈ 33–38 s to identify; startup CAP discarding ≈ 9 s of content; queue-full and coarse re-anchors | identify ≤ 2 s; first anchor ≤ 3 s after transport up; discard ≤ 1 s | **pass:** first anchor ≤ 3 s, discard ≤ 1 s, 0 coarse re-anchors at start |
| 5 | Local soak ≥ 30 min (loop-exact 23.976 clip, ffmpeg listener): calibration at +1, +16, +32 min, `[AV-CONTENT]` | last recorded local SRT soak: −1.6 ms / 28.5 min, ≈ −1 ppm (AUDIO_RESAMPLER_DESIGN.md §19.5, §18.4) | the same band | **pass:** every figure within ±2 ms, end − start within ±5 ms (±10 ms is the §6.3 gate) |
| 6 | Cloudflare SRT from OBS (attended): identification, startup discard, a ≥ 15 min soak | identify 3.2–3.9 s after transport up; discard 68–71 frames (2.8–3.0 s), §19.14 | identify ≤ 2 s; discard not larger | **pass:** identification faster by ≥ 1 s; calibration in the §19.14 band |
| 7 | One local SRT calibration with the sync clip | last recorded: +0.17…+0.98 ms (§19.15, item 4) | the same | **pass:** within ±2 ms |

**What could invalidate earlier SRT measurements.** Every SRT session until now released the probe
backlog in one burst at identification: ~2 MB, or 2500 audio packets. So start-up figures were taken
in that state: time to first anchor, the startup discard, early re-anchors, initial queue depth and
calibrations near connect. Steady-state drift figures should not change.

#### Stage 0 — results, 2026-10-07 (unattended, local ffmpeg listener)

**Builds:** HEAD `f9d8495` (binary `930b5549…`) and Stage 0 (`c4732b4b…`), both unsigned Profile.
**Driver:** `scripts/soak/repro/run.sh`. **Logs:** `~/Desktop/manifold-soak/s0/repro/`.
Times are from `[SRT] transport up`. "Picture" is the `[SRT] startup anchor:` line, which comes
≤ 30 ms before the first presentation.

| # | result | verdict |
|---|---|---|
| 1 | 150 kb/s bars + AAC (ffmpeg's default packing): HEAD identified at **149.5 s**, only when the 150 s file ended. Stage 0 identified at 0.50 s, picture at **0.87 s**. | **PASS** (≤ 3.5 s) |
| 2a | 8 Mb/s, ×2 each: HEAD identify 2.02 / 2.03 s, Stage 0 0.40 / 0.40 s, so **1.62–1.63 s faster** (picture 2.39 → 0.67 s) | **MISS, high side:** the band was 0.8–1.6 s. The video analysis takes 0.4 s, not the 1.2 s predicted. |
| 2b | 25 Mb/s, ×2 each: HEAD 0.68 s, Stage 0 0.40–0.41 s, so **0.27 s faster** | **PASS** (0–0.5 s) |
| 3 | `[SRT] container`, both `stream` lines, `[SRT] video:` and `[SRT-AUDIO] stream`: **identical text** in all 9 HEAD/Stage 0 pairings | **PASS** |
| 4 | `syncD-23.976p-inj0.ts`: HEAD identify 37.86 s, first anchor 38.49 s, CAP discarding 10.14 s, 22 coarse and 48 queue-full re-anchors. Stage 0: identify 0.53 s, first anchor **0.77 s**, GAP discarding **1.04 s**, **0 / 0** | **PASS**, but one sub-band missed by 43 ms: discard ≤ 1 s. Every Stage 0 run discards 1.00–1.04 s, which is the GAP rule's live-edge cost, not backlog. |
| 5 | 33.4 min soak, loop-exact 23.976 clip ×100, one AAC frame per PES. Calibrations (measure-only) at +1 / +2 / +16 / +32 min: **+0.23 / −1.45 / +2.50 / −0.16 ms**. End − start −0.39 ms. `[AV-LAG]` A/V slope after 180 s **+0.1 ppm**. 0 starvation holds, 0 coarse re-anchors, 0 splices. | **PASS** on drift (±5 ms; last recorded local SRT ≈ −1 ppm, §19.5). **MISS by 0.5 ms** on the per-reading ±2 ms band (+2.50, p10…p90 +0.45…+3.89). This soak is log-measured; §18.4's was device-measured with the Recorder OBS. |
| 6 | Cloudflare SRT, attended (Robbie). OBS sender "SRT Cloudflare" at 24000/1001, scene looping the 23.976 sync clip; Manifold on the saved stream; logs `~/Desktop/manifold-soak/s0/cf/`. **HEAD, same day:** identify 3.73 s, picture 4.00 s, GAP discarding 71 frames (2.96 s); calibration at +60 s **−87.82 ms**. **Stage 0, 17 min:** identify **1.48 s**, picture **1.66 s**, GAP discarding 24 frames (1.13 s); calibrations at +1 / +2 / +8 / +16 min **−86.29 / −92.04 / −90.76 / −86.14 ms** (end − start +0.15 ms); `[AV-LAG]` slope −0.3 ppm; 0 starvation holds, 0 coarse, 0 queue-full, 0 splices. | **PASS:** 2.25 s faster, discard smaller. **The calibration half of the band was wrong:** today's HEAD reads −88 ms (sound early), where §19.14 read +41 ms (late), so Cloudflare's offset changed between days, on both builds. Stage 0 sits within ~4 ms of same-day HEAD. Most of HEAD's ~3 s Cloudflare startup discard (§19.14) was the probe backlog, not Cloudflare's own burst. |
| 7 | Local calibration +0.23 ms (§19.15: +0.17…+0.98) | **PASS** (±2 ms) |

**Found on the way, pre-existing and not Stage 0's:** ffmpeg's default mpegts packing puts 8–16 AAC
frames in each PES when the audio is a simple tone, and SRT's 0.25 s audio target starves between
lumps. Audible at the device. HEAD does it too. See BUGS.md, *SRT audio breaks up when the sender
packs ≥ ~170 ms of AAC into each PES*.

**Gates:** `swift test` (ManifoldCore) 225 / 225; `node --test scripts/soak/soaklog.test.mjs` 8 / 8;
the Stage 0 Profile build succeeded. `defaults`: the domain was exported before the first launch.
After the last quit it was restored, and is dictionary-equal (1 141 keys). The runs had only added
13 `NSWindow Frame` keys. `streamBookmarks` was never written.

#### Stage 0b-1 — packing instrumentation: predictions, written 2026-10-08 before the build

**What changes:** `[SRT-AUDIO] packing` is logged when the AAC frame count per PES changes (frames,
PES duration from the decoded samples, the previous count, the session maximum). At most one line
per second; changes not logged are counted on the next line. The `[SRT-AUDIO] session end` line
gains `packing: <PES>, <mean> frames per PES (<ms>) mean, max <n> (<ms>), <k> change(s)`. Nothing
else changes.

**Builds:** c32c074's code (HEAD `92f9c52` is docs-only on top of it), unsigned Profile,
`.build-cc/s0b1base-Profile`; the 0b-1 tree, `.build-cc/s0b1-Profile`. **Driver:**
`scripts/soak/repro/run.sh` with ffmpeg's default packing for lo150 / hi8 / hi25 and
`-pes_payload_size 0` for the sync fixture, as in Stage 0. Unattended, local ffmpeg listener only.

**Measured offline first** (the fixtures remuxed with the sender's own flags, ADTS frames counted
per PES): lo150 16 frames in 438 of 440 PES (17 first, 8 last), mean 15.98 = 341 ms; hi8 and hi25
8 frames in 263 of 264 (7 last), mean 8.00 = 170.6 ms; `syncD-23.976p-inj0.ts` 1 frame in every
PES. The predictions below are Robbie's figures; the bands cover both.

| # | what | predicted | pass band |
|---|---|---|---|
| 1 | lo150 session-end packing | 15.9 frames / ~338 ms mean, max 17 | mean 15.5–16.1 frames and 330–345 ms; max 17 (≤ 363 ms) |
| 2 | hi8 and hi25 session-end packing | 7.8 frames / ~167 ms mean, max 8 | mean 7.6–8.05 frames and 162–172 ms; max 8 (170.7 ms) |
| 3 | sync fixture packing | 1.0 frame / ~21 ms, max 1 | exactly 1.00 / 21.3 ms, max 1, 1 change (the first PES) |
| 4 | packing lines | one at the first PES, then one per real change | lo150 ≤ 3, hi8 / hi25 ≤ 2, sync fixture 1; 0 "not logged" |
| 5 | every other line | identical to c32c074 | the same line kinds (numbers masked) on each thread; deterministic lines (`[SRT] container` / `stream` / `video:`, `[SRT-AUDIO] stream`, layout, cookie) **identical text**; the session-end line identical up to ` · packing:` |
| 6 | starvation holds, steering, calibration | no change (instrumentation only) | each figure inside the spread of c32c074's own runs on the same fixture (Stage 0: hi8 6–10 holds, hi25 3–10); rail time within ±5 s; sync fixture `[AV-CONTENT]` audio − now median within ±2 ms |

**The soak fixture (one frame per PES, predicted 1.0 / ~21 ms) is not run in this stage**: the brief
lists lo150, hi8, hi25 and the sync fixture.

**One diagnostic run, for the rail-drain question:** `hi8fine.ts`, the same hi8 content remuxed
with one AAC frame per PES in the FILE, still sent with ffmpeg's default packing. On the wire the
audio is the same 8-frame lumps, but the sender's video stops arriving in bursts (offline: video
arrival gaps max 57 ms, against 114 ms and 213 gaps over 60 ms for hi8). Run on c32c074 only.
Predicted, if the drain is LiveClock shedding a startup video depth that the bursts inflated:
**no `RATIO AT ITS RAIL` line; `[LIVECLOCK]` rate off its ±0.5 % rail after the first ~5 s; the
renderer low-water steady (no ~44 ms fall over 30 s); 0–2 starvation holds** against hi8's 6–10.
Fail: a rail episode of ≥ 10 s, or ≥ 6 holds.

#### Stage 0b-1 — results, 2026-10-08 (unattended, local ffmpeg listener)

**Builds:** baseline (c32c074's code) `841d46d8…`; 0b-1 first build `f84ca602…`; 0b-1 as left in the
tree, `s0b1v2` `28369d8f…`. All unsigned Profile. **Logs:** `~/Desktop/manifold-soak/s0b1/repro/`.
Baseline and first build ran alternately (hi8 twice each); v2 ran all four fixtures afterwards.

| # | result | verdict |
|---|---|---|
| 1 | lo150: 438 PES, **16.00 frames (341.4 ms) mean, max 17 (362.7 ms)**, 2 changes | **PASS** |
| 2 | hi8 ×3, hi25 ×2: 262 PES, **8.00 frames (170.7 ms) mean, max 8**, 1 change. The 7-frame last PES of the file never arrives before the session ends. | **PASS** |
| 3 | sync fixture ×2: 14 070 PES, **1.00 (21.3 ms), max 1**, 1 change | **PASS** |
| 4 | **First build: MISS.** On lo150 the 17 → 16 change at PES #2 came inside the 1 s spacing, was counted, and was never logged, so the count the sender settled on was missing from the log. **Fixed in v2:** a held-back change is logged at the first PES after the spacing. v2 logs `17 … at PES #1` and `16 … at PES #6, last logged 17`. hi8 / hi25 / sync: 1 line each, 0 "not logged". | **PASS on v2** |
| 5 | Every baseline / 0b-1 pair (5 on the first build, 4 on v2): deterministic lines identical text (compared as a multiset: video and audio announce on different threads, and their order swaps between runs of the same build); the session-end line identical up to ` · packing:`, counts included; line kinds otherwise the same. The only kinds on one side of a pair are event lines that vary between runs of one build: `STARVATION CATCH-UP` (lo150: 2 of 3 runs, both builds, and the Stage 0 build), `SPLICE … ABANDONED — session ended` (also on the Stage 0 build's `lo150-s0`). | **PASS** |
| 6 | Holds — lo150 272 base / 273, 258 new; hi8 5, 7 base / 7, 5, 8 new; hi25 7 base / 6, 5 new; sync 0 / 0. Steering rail — hi8 21.2, 20.3 s base / 19.6, 20.6, 21.0 s new; hi25 20.3 / 19.3, 21.8 s. Sync fixture `[AV-CONTENT]` audio − now median **−0.01 ms base, −0.14 and −0.06 ms new**. | **PASS** |
| D | hi8fine (smooth video, the same 8-frame audio lumps): **no rail episode** (0.8 s on the rail in total), but **3 holds**, and the renderer low-water starts at **34.9 ms** (hi8: 63.5–68.2 ms) and ends at 19.5 ms, the same place as hi8. | **Half right — see below** |

**The soak fixture was not run** (not in this stage's list). **Gates:** `swift test` (ManifoldCore)
225 / 225; `node --test scripts/soak/soaklog.test.mjs` 8 / 8; both Profile builds succeeded. No new
unit test: the change is in the app target, which has none. **`defaults`:** exported before the first
launch. The runs added 15 `NSWindow Frame` keys and changed nothing else (`streamBookmarks` equal).
`defaults import` of the snapshot merged rather than replaced, so the 15 run-added keys were then
deleted by name, each checked absent from the snapshot. The domain is dictionary-equal to the
snapshot (1 141 keys). No temporary probe was added; nothing goes on the pre-ship cleanup list.

#### The rail drain — what it is

**In plain terms: the rail drain spends startup slack that the stream never had to keep. It is not
what starves the audio.**

1. **The sender's video arrives in bursts.** ffmpeg re-reading a file whose audio is already packed
   eight frames to a PES holds video back until the next audio lump is read. Measured offline on the
   sender's output (UDP, no Manifold): hi8's video arrives with 213 gaps over 60 ms in 637 frames
   (max 114 ms); the same content with fine audio packing in the file has none (max 57 ms). Sending
   with `-pes_payload_size 0` does not remove the bursts: they come from the input, not the output
   packing. lo150's bursts are about twice the size.
2. **The clock starts on a burst's last frame.** The GAP startup anchor starts the clock on the frame
   after a delivery gap. On a bursty sender that is the latest-arriving frame of the cycle, so every
   other frame arrives early: `[LIVECLOCK] startup … max arrival lead=+184…188 ms` on hi8, +128 ms on
   hi8fine, +25 ms on the sync fixture. The video queue therefore sits 20–60 ms deeper than its
   250 ms target (`[LIVECLOCK] err=+0.02…+0.08`), and LiveClock runs at its +0.5 % rail for about 30 s
   to shed the excess.
3. **The audio follows the picture and pays for it.** The audio's target is LiveClock's line, which
   now advances 5 ms/s faster than real time. The steering can follow at +2000 ppm (2 ms/s) at most,
   so it sits on its rail for ~20 s with the audio up to 40–46 ms behind the picture. Every
   millisecond it catches up comes out of the renderer queue: low-water 63.5 → 46.4 → 23.6 → 20.9 ms
   in the hi8 windows, and the holds start once it reaches the 20 ms margin.
4. **Without the bursts, the queue ends in the same place.** hi8fine has no rail episode, but it
   starts with 35 ms of low-water instead of 64 and still holds. Every hi8 run, bursty or not, ends at
   19.5–21 ms. The bursts gave the audio ~30–45 ms of slack at startup, and the rail drain took that
   slack back. The floor itself is set by 170 ms lumps arriving against a 250 ms cushion. This is the
   BUGS.md entry's "starts with more slack, then ends up in the same place".

**Does 0b-2 (the adaptive cushion) fix it?** **The starvation, yes; the rail episode, no.**
- **The starvation is 0b-2's to fix.** With the cushion sized on the observed packing, the floor
  after the drain is the floor 0b-2 chose. **One constraint for 0b-2:** size it from the PES
  duration, or from the queue after LiveClock has settled. The first 30 s of low-water on a bursty
  sender overstates the floor by up to ~45 ms.
- **The rail episode is not 0b-2's, and it does not need its own fix now.** For 20–30 s after
  connect, the audio is up to ~40 ms behind the picture, because LiveClock may slew at ±0.5 % and
  the audio at only ±0.2 %. It is pre-existing, the `RATIO AT ITS RAIL` tripwire already reports it,
  and it needs a sender whose video arrives in bursts. Here that is a harness artefact (ffmpeg
  re-reading a coarse-packed file); no real sender has shown it. **Recorded, not scheduled.**
- **For 0b-2's tests,** run hi8fine beside hi8: it separates coarse audio from bursty video.
  `hi8fine.ts` is
  `ffmpeg -i hi8.ts -map 0 -c copy -pes_payload_size 0 -f mpegts hi8fine.ts`.

#### Buffer policy — the review and its decisions, 2026-10-08

**Why here:** Stage 0b-2 raises the SRT cushion, and the brief for it asked what the cushion is, what
it costs, and where it can come down: per transport, the lowest latency that runs without audible or
visible artefacts. The review was read-only (code, docs, every log on disk). Its tables are kept
below because 0b-2, L1 and L2 are judged against them. Kept in §6.10 rather than a new section,
because the stage plan that uses them is here; the audio-side detail it cites is in
`AUDIO_RESAMPLER_DESIGN.md` §18–§19.

**Decided (Robbie, 2026-10-08):**
1. **Hold every default for 1.0:** SRT 0.250 floor, WHEP 0.400, NDI desktop-audio lead 0.250. Lower
   only through the trials below.
2. **0b-2 gets a reorder term** (Stage 0b-2b).
3. **No cushion growth from repeated starvation holds** for 1.0.
4. **Automatic only**, plus the readout. ⌃⌥[ / ⌃⌥] stay Debug-only.
5. **The chain readout shows the cushion**, and any raise with its reason.
6. **The three messages that send users to ⌃⌥] are rewritten** (in 0b-2a).
7. **A saved advance (negative O) is checked against the queue at the first anchor** (in 0b-2a).
- **Trials:** L1 (WHEP 0.30) is in 1.0, after 0b-2b. L2 (NDI lead 0.20) is in 1.0, and also finds the
  renderer's crackle threshold between 40 and 150 ms of lead on the Scarlett and the built-in output.
  L3 (SRT floor 0.20) waits until after HEVC Stage 3.

##### The inventory, sender to glass and SDI

The audio has no target of its own. It follows LiveClock's `now()` (`beginLiveAudio(0)` is an axis
offset, not a buffer: `FrameEngine.swift` ~2296–2313), so the renderer queue is the cushion plus the
sender's audio/video interleave, and **every audio margin moves one-for-one with the cushion**.

| stage | SRT | WHEP | NDI | HLS | file |
|---|---|---|---|---|---|
| network | TSBPD, libsrt's 120 ms unless `?latency=` (20–8000 ms; the handshake takes the larger side) | no jitter buffer: reorder counted, not held (`H264Depacketizer.c`); NACK window 400 ms, 2 retries | NDI FrameSync, SDK-internal; its audio depth estimated (EMA, ceiling 0.2 s) | AVPlayer's; no forward-buffer or live-offset property set | — |
| demux | `max_probe_packets` 1, probesize 2 MiB, 5 s cap; audio before the video anchor dropped | audio held until the anchor; first anchor waits ≤ 1.5 s for an RTCP SR | — | — | — |
| reorder | in the cushion: needs **cushion > max(pts − dts)**; measured per AU, warned at 0.75 ×, never corrected | no B-frames | — | AVPlayer | Apple |
| **cushion** | **0.250** (`SRTFrameRouter.swift` `targetDepth`); rate ±0.5 %, snap at +0.2 s | **0.400** (`WHEPFrameRouter.swift`) | no LiveClock; lead **0.250** (`NDIService.swift`), picture hold = lead + FrameSync depth | — | — |
| renderer | ≈ cushion + interleave; hold at 20 ms with no input, resume at 100 ms | same | lead | AVPlayer's | Apple's |
| display | Metal queue 30 frames (SRT/WHEP), 12 otherwise | | NDI bound from its hold | 12 | 12 |
| SDI | 4 prerolled frames (~208 ms at 24p) + 0.200 s card audio; tap ring 4 s. **Fixed, independent of the cushion** | same | same; no picture hold when the card owns audio | same | + 0.250 tap look-ahead |

##### What the logs show (every `*.manifold.log` on disk, 2026-09-29 → 10-08)

| path | video, target → lowest | audio queue, lowest (hold at 20) | holds | |
|---|---|---|---|---|
| SRT local, 1 frame/PES | 250 → **224** | **258** (median 350; ~90 ms above the cushion) | 0 / 34 min (`s0/repro/soak-s0`) | ~240 ms spare in audio |
| **SRT Cloudflare** | 250 → **181** | 84.5 at +10 s (`s0/cf/cf-s0`, :389) is startup; **127–143 steady**; median ~202, ~50 ms *below* the cushion | **9 / 94 min** (`cf1914/srt-3`), each on a 45–239 ms input gap, five at hh:m4:20 | **the edge**: reorder 0.208 s against 0.250; advance budget 0 |
| SRT hi8 / hi25 (171 ms per PES) | 205–229 | at the 20 ms hold; post-enqueue minimum ~43 | 3–8 / 70 s | 0b-2's |
| SRT lo150 (341 ms, max 363) | dips to 105 | −67 unheld | ~260 / 3 min | 0b-2's |
| WHEP MediaMTX | 400 → **304** (a rail event); usually 370–392 | 199–383 | 0 | ~100 ms unused at worst |
| WHEP Cloudflare | 400 → **319** | 190 (4.5 h) – 226 | 0; one 4 s upstream pause muted (beyond any cushion) | ~80 ms unused at worst |
| NDI | — | 228 at +10 s, **242–247** steady | 0 in 43 short runs | ~210 ms above the hold |
| HLS, on-screen file | **no data** | | | |
| file → SDI tap (§19.12 fix) | — | tap 232–275, card 158–172 | 0 underruns | |

**The floor that matters is the renderer's, not the hold's.** The NDI lead ladder found this
`AVSampleBufferAudioRenderer` crackly at 40 ms of lead and clean at 150 ms, threshold not narrowed and
device-specific (BUGS.md, the NDI desktop-audio entry). Cloudflare SRT already runs steady at
127–143 ms, below the last value measured clean. L2 narrows it.

##### Where 0.25 came from

- **SRT's cushion**: `e4210e6`, 2026-07-26, "an ARGUED starting value, not a measured one": TSBPD does
  the de-jitter, so 0.25 covers reorder, decode jitter and margin. **Never re-derived;** the instrument
  for it (⌃⌥[ / ⌃⌥]) went Debug-only a month later (`0b6a91c`).
- **WHEP's 0.400 was measured** (`0c1752d`, 2026-07-21): lateness max 162 ms at a 0.2 target, cushion
  ≥ 0.362. That predates the NACK work; since then unrecovered loss shows as keyframe waits, which
  depth does not prevent (`WHEP_LOADED_NETWORK_FINDINGS.md`, the decode-error exclusion).
- **NDI's lead copied SRT** as the smallest lead measured clean (`786c0d8`).
- **Other 0.25s are unrelated and must not move with the cushion:** LiveClock `freezeGuardHold`, the
  steering's `maximumStepSeconds` and `recoveryCutSettleSeconds`, the file tap look-ahead.
- **One value for every transport does not fit, and was never one value.** The floor is set by
  reordering and sender packing on SRT, network lateness and the NACK round trip on WHEP, and the
  renderer's lead on NDI. Within SRT, server-agnosticism means the per-stream part has to come from
  measuring the stream, never from a per-server constant.

##### What a cushion change does to everything else

- **Relative A/V and calibration: unaffected.** Flash and beep both sit on axes tied to `now()`; the
  stored per-bookmark O is a property of the sender. §18.24/25, §19.5, §19.13–15 and the AV_SYNC device
  figures stay valid.
- **Every absolute queue, stall and advance figure moves one-for-one**, and is invalidated by any
  change: §18.14's stall table, §18.16's lowest-window table (and its "healthy lows are > 5 × M"),
  §18.17/§18.19's "held at 319–324 ms", the §19.8 advance trials, the 0b-1 low-water floors, and the
  "370 ms deliberate" budget line.
- **The advance budget** (queue's 10 s low point − 160 ms) drops one-for-one; Cloudflare SRT's is
  already 0. **A saved negative O was placed at the first anchor with no check** (decision 7).
- **Holds** trigger on a stall of (queue − 20 ms). **Whole-debt catch-up** needs queue ≥ debt + 160 ms.
- **B-frames:** the reorder delay comes out of the cushion; Cloudflare's 0.208 s rules out any SRT
  cushion below ~0.21 s. **HEVC Stage 3 does not plan for deeper reordering** (4–8 B-frame pyramids
  can exceed 0.25 s at 24p): that is 0b-2b's reason.
- **Drift, SR fit, level hold:** slopes, re-based on every clock jump, so the level does not matter,
  provided a raise goes through `LiveClock` with `onPositionJump`, and the depth ledger
  (`LiveDepthTelemetry`) is told.

##### Defaults, and the trials that may lower them

| path | today | 1.0 | margin behind it | trial |
|---|---|---|---|---|
| SRT | 0.250 | **0.250 floor + 0b-2** | Cloudflare: video low 181, audio 127, reorder 0.208 (42 ms) | L3, floor 0.20 with 0b-2b, after HEVC Stage 3 |
| WHEP | 0.400 | **0.400** | video low 304 / 319: 80–100 ms unused; the NACK window is tied to it | **L1, 0.30**, after 0b-2b |
| NDI | lead 0.250 | **0.250** | 242–247 steady; clean at 150, crackly at 40 | **L2, 0.20** + the threshold |
| HLS | AVPlayer | unchanged | no data | — |
| file / SDI | 0.25 look-ahead; 4 frames + 0.2 s card | unchanged | tap 232–275, card 158–172 | — |

##### Stage 0b design (confirms the 0b audit)

- **Signal:** the PES duration (`[SRT-AUDIO] packing`'s seconds, decoded from the PES), not the queue
  low-water. The first ~30 s of low-water on a bursty sender overstates the floor (*The rail drain*).
- **Rule:** cushion = max(transport default, largest PES this session + 0.15 s), clamped to 1.0 s.
  **Grow-only** within a session. A digital-silence PES counts like any other.
- **Set before the first anchor** when the packing is already known: the startup fill and the target
  both take it, so there is no step. `notePacking` runs on decode, ahead of the pre-anchor audio drop,
  so the first PES usually lands before the anchor.
- **Growth after the anchor goes through `LiveClock`** (`onPositionJump` fires, the audio splice
  matches it as a `target-step`), the depth ledger is told, and **calibration restarts** if a step lands
  mid-measurement.
- **0b-2b** adds the reorder term (max(pts − dts) + margin); its margin is set in that stage.

**Staged:** 0b-2a (the rule, SRT only; the readout; the messages; the saved-advance check) → 0b-2b →
L1 → L2 → the rest of §6.10 from Stage 1. L3 after Stage 3.

#### Stage 0b-2a — predictions, written 2026-10-08 before the code changed

**What changes:**
- **The rule** in `SRTFrameRouter`, SRT only, from `notePacking`. Before the clock anchors, a raise
  moves both the startup fill and the target (new `LiveClock.raiseTargetDepth`, no jump); after it, the
  same re-anchor `adjustTargetDepth` makes, with `onPositionJump` and a `[LIVECLOCK] targetDepth … (raised:
  …)` line. The depth ledger's cushion follows a pre-anchor raise; a post-anchor one is a clock jump in
  the ledger, as the manual step is. The renderer's queue bound grows with the cushion (30 frames is
  "five times the target" at 24p, and a 0.513 s cushion at 60p would otherwise hit it).
- **One `[SRT-BUFFER]` line** per decision: the rule's figure, the PES behind it, before or after the
  anchor. Nothing logged when the floor stands.
- **The readout:** a Buffer row on SRT and WHEP: "250 ms + SRT 120 ms"; raised, "321 ms + SRT 120 ms —
  raised 71 ms: the sender packs 171 ms of audio per packet". Logged as `[SRT-BUFFER] readout: …` when
  it changes, so it is checkable from the log.
- **Calibration** restarts on a post-anchor raise ("The buffer was raised — measuring again.").
- **The three messages:** the `[SRT] latency budget` verdicts, the `[SRT-AU]` reorder line, and the
  comments behind the reorder banner stop pointing at ⌃⌥[ / ⌃⌥].
- **The saved-advance check — REFUSE, through the existing refusal.** At the steering's first anchor,
  a pending negative O is judged against the queue then (enqueued frontier − the line without O) less
  keep, fade and margin, as `setUserOffset` judges any advance. Too large → O = 0 for the session, the
  refusal line and banner, the SDI read back to 0, the bookmark untouched. **Why refuse and not clamp:**
  every advance in this app is "whole or not at all" (§19.8, decided at stage B), and a clamp at the
  anchor would apply a value nobody chose, from a single-instant queue reading, which is the figure
  §19.8's D01 showed over-promising. The saved value stays in the bookmark; *Revert to Saved* retries it
  later through the normal 10 s low-point test. Pre-anchor frontier tracking is added for this; a
  session with nothing enqueued at the anchor keeps today's behaviour and says so in the log.

**Builds:** HEAD `d20ff96` (= the 0b-1 code) and the 0b-2a tree, unsigned Profile. **Driver:**
`scripts/soak/repro/run.sh`, the 0b-1 fixtures and sender flags; the calibration and bookmark runs
through the Stage 0 UI helpers. Unattended, local ffmpeg listener only.

| # | what | predicted | pass band |
|---|---|---|---|
| 1 | syncD (1 frame / PES) | cushion 0.250, no `[SRT-BUFFER]` raise | no raise line; `[AV-CONTENT]` audio − now median within ±2 ms of 0b-1 (−0.14…−0.01); 0 holds |
| 2 | hi8, hi25, hi8fine (8 frames, 170.7 ms) | raised to **0.321** before the anchor | raise line says before the anchor, 0.321 (±0.001); **≤ 1 hold, none after +60 s**; renderer low-water after +60 s **45–110 ms** |
| 3 | lo150 (16–17 frames, max 362.7 ms) | raised to **0.513** before the anchor | **≤ 2 holds**; low-water after +60 s **120–260 ms** |
| 4 | set before the anchor | every raise in 2–3 is before the first anchor | 0 `target-step` position jumps and 0 `targetDepth … (raised` re-anchors after the first presentation; depth ledger never OVER |
| 5 | one local calibration, soak fixture | as Stage 0 (+0.23 / −1.45 ms) | within ±2 ms |
| 6 | 30 min local soak, 1 frame / PES | unchanged against `soak-s0` | cushion 0.250, no raise; 0 holds; audio low-water after +60 s within ±25 ms of Stage 0's 257.7; video lowest within ±25 ms of 224; calibrations at +1 / +16 / +32 min within ±2 ms |
| 7 | saved advance: a local SRT bookmark at **−250 ms** | queue at the anchor ≈ 340 ms, so ~180 ms available: **refused** | refusal line at the first anchor; O 0 for the session; banner; bookmark still −250 after quit; 0 holds |
| 7b | the same bookmark at **−100 ms** | placed at the anchor as today | accepted line; O −100; 0 holds; `[AV-CONTENT]` audio − now about −100 ms |
| 8 | the readout | syncD "250 ms + SRT 120 ms"; hi8 "321 ms + SRT 120 ms — raised 71 ms: the sender packs 171 ms of audio per packet" | exact text in the `[SRT-BUFFER] readout` line |
| 9 | gates | — | `swift test` all pass (new `LiveClock` raise tests included); `soaklog.test.mjs` 8 / 8; Profile build |

**What this stage could invalidate:** only the absolute queue figures of a sender that packs > 100 ms
per PES (the 0b-1 floors), which is the point. A one-frame-per-PES sender must read exactly as before
(items 1, 5, 6). Attended afterwards, one step at a time: local OBS with real programme audio (the
first real-sender packing figure), then Cloudflare SRT.

#### Stage 0b-2a — results, 2026-10-08 (unattended, local ffmpeg listener)

**Build:** the 0b-2a tree on `d20ff96`, unsigned Profile, `.build-cc/s0b2a-Profile`. **Logs:**
`~/Desktop/manifold-soak/s0b2a/repro/`. Baselines are the 0b-1 v2 logs (`s0b1/repro/`) and Stage 0's
soak (`s0/repro/soak-s0`), not re-run.

| # | result | verdict |
|---|---|---|
| 1 | syncD: cushion 250, no raise; 0 holds; `[AV-CONTENT]` median **−0.10 ms** (0b-1 −0.06); low-water 273.1 (0b-1 271.6); session end `· cushion 250 ms` | **PASS** |
| 2 | hi8 ×2, hi25, hi8fine: raised **250 → 321 ms before the first anchor** in every run (0.07–0.15 s before it), queue bound 39; **0 holds** (0b-1: 5–8); low-water **79.4 / 80.0 / 83.7 / 80.5 ms**. These fixtures play < 60 s, so the "after +60 s" band is read on the whole session | **PASS** |
| 3 | lo150: raised **250 → 513 ms before the anchor** (largest PES 362.7 ms). The steering then sat at its rail for ~75 s, draining the bursty-video startup excess (*The rail drain*), low-water 144 → 22 ms; from +82 s it is settled (e ≈ 0) at **30–34 ms**, and holds recur on every lump: **115 holds** (0b-1: ~260) | **FAIL** (band ≤ 2 holds, 120–260 ms) |
| 4 | every raise in 2–3 before the anchor; **0 `target-step` jumps** in any log; depth ledger **0 OVER** | **PASS** |
| 5 | soak calibrations at +1 / +2 min: **−1.64 / +0.17 ms** (Stage 0: +0.23 / −1.45) | **PASS** |
| 6 | 33.4 min soak (1 frame / PES): cushion 250, no raise; **0 holds**; low-water **263.7** (Stage 0 257.7); video lowest after +60 s **229** (224); `[AV-CONTENT]` median −0.01 ms over 1 600 flashes (−0.04); calibrations +1 / +2 / +16 / +32 min **−1.64 / +0.17 / +2.13 / +0.15 ms** (Stage 0: +0.23 / −1.45 / +2.50 / −0.16) | **PASS**, with +2.13 at +16 min 0.13 ms outside ±2 — Stage 0 read +2.50 at the same point |
| 7 | **not run unattended.** ⌃⌥D on the "Local SRT" bookmark reads its keychain item, and the unsigned build raised the login-keychain prompt for `tools.graviton.manifold.streams`. That prompt is Robbie's; the run stopped, Manifold was quit (the request withdrawn, not denied) | **moved to the attended part** |
| 8 | `[SRT-BUFFER] readout: Buffer 250 ms + SRT 120 ms` (syncD, soak) and `Buffer 321 ms + SRT 120 ms — raised 71 ms: the sender packs 171 ms of audio per packet` (hi8); lo150 `513 ms + SRT 120 ms — raised 263 ms: the sender packs 363 ms of audio per packet` | **PASS** (log text; the popover itself not screenshotted) |
| 9 | `swift test` **242 / 242** (225 + 12 `LiveCushionTests` + 5 new offset tests); `soaklog.test.mjs` 8 / 8; Profile build, no new warnings in the touched files | **PASS** |

**Why lo150 failed — the rule's margin, not its mechanism.** On every fixture the settled low-water
fits **floor ≈ cushion − 1.41 × mean PES**: hi8 321 − 1.41 × 170.7 = 80 (measured 79.4–83.7), lo150
513 − 1.41 × 341.4 = 32 (measured 30–34). hi8fine reads like hi8, so the extra ~0.4 PES comes from
ffmpeg's OUTPUT packing, not the input file. The rule's + 0.15 s covers that only while 0.41 × PES
< ~0.13 s, i.e. PES ≲ 0.3 s. The prediction was wrong for the same reason: it took 0b-1's −67 ms as
lo150's unheld floor, and that run held almost continuously, so it was not one. **The decision is
Robbie's** (put to him 2026-10-08, with these results): whether the rule should scale with the PES (e.g. 1.5 × PES +
0.15 s: hi8 0.406, lo150 0.662), and whether lo150 (16–17 frames, 150 kb/s, a harness fixture) is a
sender 1.0 has to cover. Real programme audio is ~6 frames (~130 ms), where either form gives ~0.28 s.

**Defaults:** exported before the first launch. After the last quit: 8 run-added `NSWindow Frame`
keys, each checked absent from the snapshot and deleted by name; `streamBookmarks` written back from
the snapshot's bytes after the item 7 attempt; the domain is dictionary-equal to the snapshot (1 141
keys).

#### Stage 0b-2a — attended, 2026-10-08 evening (Robbie): OBS, and the saved advance that was never judged

- **Local OBS with real programme audio** (the "Local SRT" bookmark, passphrase-protected, so the
  saved-advance check ran against OBS rather than ffmpeg): `[SRT-AUDIO] packing — 1 AAC frame(s) per
  PES (21.3 ms)`. **The first real-sender packing figure: OBS packs one frame per PES**; the cushion
  stays 250 ms. Log `s0b2a/repro/obs-bm250.manifold.log`.
- **Item 7 FAILED AS BUILT: the check never judged.** The steering logged "placed at the first anchor
  WITHOUT a queue check — nothing enqueued yet" on both connects. On SRT the steering's first anchor is
  the picture's, made at the video anchor, and the audio that precedes it is dropped by design, so the
  queue at the first anchor is EMPTY BY CONSTRUCTION. The unit tests passed because their harness
  enqueued audio before anchoring, which the SRT path never does.
- **And the latent bug, heard:** −250 ms placed unchecked left the renderer queue at a **median 87 ms**
  (window minima 51–66, low-water ~42) for 200 s, **0 holds** — and Robbie heard the audio **breaking
  up**. This renderer crackles somewhere between 87 and 150 ms of lead on the Scarlett (the NDI lead
  ladder: 40 crackly, 150 clean). That is evidence for trial L2, and it is why the 160 ms reserve is
  the right bar.
- **Cloudflare SRT** (OBS "SRT Cloudflare" profile, 23.976, SYNC scene; the "DC Color Live - SRT"
  bookmark; 0b-2a build; 17:38–17:48, `s0b2a/cf/cf-1`): **Cloudflare's egress packs 1 frame per PES
  too**, so the cushion stays 250 ms and the readout reads "250 ms + SRT 120 ms". **0 holds** in 10 min;
  renderer low-water 92 ms at +10 s, then a steady **145–152 ms**; the reorder warning as always
  (0.208 s against 0.250 — 0b-2b's). Calibrations +1 / +2 / +8 min **−56.24 / −55.44 / −97.62 ms**:
  a 42 ms step between +2 and +8 min with **no Manifold event between them** (0 raises, target steps,
  splices, holds, re-pins, snaps), the size of the step §19.14–§19.15 found in Cloudflare's received
  timestamps. Cloudflare's, not this build's; the level differs again from 2026-10-07's −86…−92 ms.
- **Fix, built after the run:** the judgement moved to PLAYBACK START. The first anchor's host is a
  startup fill in the future; the audio arrives during it. The first buffer within 50 ms of that host
  judges the queue (enqueued past the picture's line, plus the real-time arrival still to come before
  the start) with the same 160 ms reserve; refused, the anchor is written again without O, before
  anything has played. Unit-tested on an SRT-shaped start (`srtStart`: nothing enqueued at the anchor,
  0.34 s at playback start): −100 placed, −150 placed, −200 and −250 refused, a shallow lead refuses
  −50, a delay is never judged.

#### Stage 0b-2a v2 — predictions, written 2026-10-08 before the rule changed

**Decided (Robbie, 2026-10-08):** cushion = max(transport default, **1.5 × largest PES + 0.08 s**),
clamped to 1.0 s, grow-only. Derived from the measured floor ≈ cushion − 1.41 × mean PES, aiming at
the ~80 ms floor hi8 measured with 0 holds. Not waiting for OBS: 64 kb/s AAC and digital silence pack
~360 ms.

**The rule as written gives lo150 0.624 s, not ~0.59 s:** its LARGEST PES is the 17-frame first one
(362.7 ms); 0.59 is the mean (341 ms). By the floor model 0.624 settles at ~143 ms, above Robbie's
60–110 band. Both bands are recorded; a miss on the high side is margin, not starvation.

| # | what | predicted | pass band |
|---|---|---|---|
| 1 | hi8, hi25, hi8fine | raised to **0.336** before the anchor; floor ≈ 336 − 241 = **95 ms** | **0 holds**; low-water 60–130 ms |
| 2 | lo150 | raised to **0.624** before the anchor (queue bound 75); floor ≈ 624 − 481 = **143 ms** after the rail drain | **≤ 2 holds**; low-water: Robbie's 60–110, mine 100–180 |
| 3 | syncD | unchanged: 250, no raise | 0 holds; `[AV-CONTENT]` within ±2 ms of 0b-2a's −0.10 |
| 4 | one soak calibration (soak fixture, +60 s) | as 0b-2a (−1.64 / +0.17) | within ±2 ms |
| 5 | readout | hi8 "336 ms + SRT 120 ms — raised 86 ms: the sender packs 171 ms of audio per packet"; lo150 "624 ms + SRT 120 ms — raised 374 ms: the sender packs 363 ms of audio per packet" | exact text |
| 6 | saved advance, attended (OBS, queue ~337 ms at start) | −250: REFUSED at playback start, ~177 ms available, banner, clean sound; −100: placed, no banner | the refusal line before playback; O 0; no break-up by ear; bookmark unchanged |
| 7 | gates | — | `swift test` all pass; soaklog 8 / 8; Profile build |

#### Stage 0b-2a v2 — results, 2026-10-08 (unattended, local ffmpeg listener)

**Build:** `.build-cc/s0b2a2-Profile` (the rule at 1.5 × PES + 0.08 s, the judgement at playback start).
**Logs:** `s0b2a/repro/v2-*`.

| # | result | verdict |
|---|---|---|
| 1 | hi8 / hi25 / hi8fine: **336 ms** before the anchor (0.07–0.14 s before it), queue bound 41; **0 holds** each; low-water **95.1 / 97.1 / 94.2 ms** (model 95) | **PASS** |
| 2 | lo150: **624 ms** before the anchor, queue bound 75; **0 holds** (v1 115, 0b-1 ~260). The startup drain is longer at this depth (~110 s, low-water 256 → 64 ms), then settled at **64–66 ms**; video holds ~502 ms against the 624 target | **PASS** on holds and on Robbie's 60–110 band; **MISS** on mine (100–180): the floor model over-predicted lo150 by ~80 ms (audio ~1.64 PES behind at this depth, not 1.41) |
| 3 | syncD: 250, no raise; 0 holds; `[AV-CONTENT]` **−0.16 ms** (v1 −0.10); low-water 271.5 | **PASS** |
| 4 | soak fixture, calibration at +60 s: **+0.23 ms** (Stage 0 +0.23, v1 −1.64); 0 holds | **PASS** |
| 5 | readout: hi8 "336 ms + SRT 120 ms — raised 86 ms: the sender packs 171 ms of audio per packet"; lo150 "624 ms + SRT 120 ms — raised 374 ms: the sender packs 363 ms of audio per packet" | **PASS** |
| 6 | the saved advance live | attended, below |
| 7 | `swift test` **244 / 244** (225 + 13 `LiveCushionTests` + 6 saved-advance); soaklog 8 / 8; Profile build, no new warnings in touched files | **PASS** |

**Defaults** after the v2 batch: 9 run-added `NSWindow Frame` keys deleted by name; dictionary-equal to
the snapshot (1 141 keys).

#### Stage 0b-2a v2 — attended, 2026-10-08 18:20–18:40 (Robbie): the saved advance live, and hi8 by ear

**Part A — the saved advance, OBS local listener ("Local SRT" bookmark), v2 build:**

| | logged | heard | queue | holds |
|---|---|---|---|---|
| **−250 ms** | "REFUSED at playback start (+39 ms) — … the queue is 329.6 ms: at most 169.6 ms of advance is available · O is 0 for this session"; banner "The saved audio offset (−250 ms) needs more buffered sound than this stream has — it can move sound earlier by at most 169 ms right now. Playing at 0 ms; the saved stream keeps −250 ms." | **clean** | median **343 ms** (was 87 unchecked, and broke up) | 0 |
| **−100 ms** | "JUDGED at playback start (+41 ms) — queue 335.6 ms, 175.6 ms of advance available: placed"; no banner | **clean** | median **238 ms** | 0 |

- **PASS.** The bookmark kept its value through both sessions (read after quit); restored to the
  snapshot's bytes afterwards.
- ⚠️ **Judged 39–41 ms AFTER playback start, not before.** On SRT the first audio buffer reaches the
  steering only after the first anchor's host (the anchor waits for the first presentation, so its host
  is not as far ahead as the design assumed). A refusal is therefore one re-anchor ~40 ms into the session
  rather than a silent rewrite. Robbie heard the −250 start as clean. Recorded, not changed.
- **Logs:** `s0b2a/repro/v2-obs-bm250`, `v2-obs-bm100`.

**Part B — hi8 by ear, Audio Hijack, v2 build.** Fixture `hi8x5.ts`: hi8 looped five times with
`-stream_loop 4 -c copy` (3 min 45 s; hi8 alone plays only ~48 s, too short to start the recorder after
connect). Cushion **336 ms** before the anchor; **0 holds**; renderer low-water 85–97 ms in every window
after the startup drain except **31.1 ms at +91 s**, the fixture's second join (the unattended run of the
same file showed it too, 33.5 ms).
- **Recording:** `~/Music/Audio Hijack/20261008 1836 Recording.wav` (206 s). A 1 ms RMS envelope, gaps
  = runs ≥ 3 ms more than 30 dB below the median level: **6 gaps** — four of 30–31 ms at 24.6 / 69.6 /
  114.6 / 159.7 s (exactly 45.0 s apart), one of 5 ms 0.3 s before the second, and 2.1 s at 204.3 s (the
  stream ending before the recorder stopped).
- **The fixture's own audio**, decoded from `hi8x5.ts` with the same detector, has **30–31 ms gaps at
  every join** (45.02 / 90.06 / 135.09 / 180.13 s). So the four are the file's.
- **The same detector on the 2026-10-07 recording of the bug** (`20261007 1433 Recording.wav`, HEAD):
  **28 gaps in 10.8 s** (BUGS.md's count was 24 in 9.5 s). At that rate 206 s would hold ~530.
- **PASS: Manifold added no gap in 3 min 24 s of hi8.**

**Committed as `6132970`.**

#### Stage 0b-2b — the reorder term: predictions, written 2026-10-08 before the code changed

**Decided (Robbie, 2026-10-08, buffer review decision 2):** SRT cushion = max(0.250, 1.5 × largest PES
+ 0.08 s, **largest observed max(pts − dts) + 0.05 s**), clamped to 1.0 s, grow-only. The mechanics
are 0b-2a's: set before the first anchor when known (the first GOP usually is enough), otherwise a
`LiveClock` re-anchor with the matched audio splice; telemetry follows; calibration restarts on a
mid-measurement step. The readout names the term that raised it ("the stream reorders 209 ms of
pictures"). The reorder warning stays only for a stream the 1.0 s clamp cannot cover, and points at no
shortcut. The 75 % "within reach" line goes: with the cushion following the reorder, every B-frame
stream would trip it (Cloudflare 0.208 against 0.258 is 81 %).

**What changes:**
- `LiveCushion`: the third term, and a `Reason` (packing / reorder) carried to the readout. The
  readout names the winning term; a tie names the packing.
- `SRTFrameRouter.recordReorderDelay`: a new maximum asks for the cushion BEFORE the access unit is
  judged, so the picture that revealed a deeper reorder is compared against the raised target.
  `[SRT-BUFFER]` lines name the term.
- **The warning:** the log line and the banner fire when the reorder needs more than the ceiling
  (max(pts − dts) + 0.05 s > 1.0 s), or when a picture actually arrives at or beyond the target. The
  banner wording states the limit and the loss; it names no key.
- **One measurement probe, DEBUG only:** SRT installs the renderer's existing `onFrameSelected` hook
  and counts pictures discarded unseen (`skipped`), logged at release as `[SRT-FLOW] pictures
  discarded unseen`. The exceedance counter is the model's count of late pictures; this is the
  renderer's. Added to the existing pre-ship entry for that hook.

**Measured offline first** (`framecrc` of each fixture after the sender's own remux, `-c copy
-pes_payload_size 0`; 90 kHz):

| fixture | built with | max(pts − dts) | reorder term |
|---|---|---|---|
| `syncD-23.976p-inj0.ts`, `soak33.ts` | — | **0** (no B-frames) | 0.050 |
| hi8, hi25, lo150 | x264 defaults, 25 fps | **200.0 ms** (5 frames) | 0.250, = the floor: no raise |
| `b3nopyr` | x264 `bframes=3:b-pyramid=none`, 23.976 | 125.1 ms | 0.175: no raise |
| `b3pyr` | `bframes=3:b-pyramid=normal`, 23.976 | **208.5 ms** (5 frames, as Cloudflare's OBS) | **0.2585** |
| `b8pyr` | `bframes=8:b-pyramid=normal:b-adapt=0`, 23.976 | **417.1 ms** (10 frames) | **0.4671** |
| `b16pyr` | `bframes=16:b-pyramid=normal:b-adapt=0`, 23.976 | **750.8 ms** (18 frames) | **0.8008** |
| `b16at15` | the same at 15 fps | **1200 ms** (18 frames) | 1.25 → **clamped 1.0** |

The B-frame fixtures are 60 s of `testsrc2` 1080p at 8 Mb/s with a 1 kHz tone, AAC 128 kb/s, one AAC
frame per PES (packing term 0.112 s, below the floor), so the reorder term is the only one in play.

**Builds:** HEAD `6132970` (`.build-cc/s0b2bhead-Profile`) and the 0b-2b tree
(`.build-cc/s0b2b-Profile`), unsigned Profile. **Driver:** `scripts/soak/repro/run.sh`, sender at
`-pes_payload_size 0` except hi8 (ffmpeg's default packing, as in 0b-2a). Unattended first; then
Cloudflare SRT attended, one step at a time.

| # | what | predicted | pass band |
|---|---|---|---|
| 1 | syncD, both builds | cushion 250, no raise, no reorder line | no `[SRT-BUFFER] cushion` line; readout `Buffer 250 ms + SRT 120 ms`; 0 holds; `[AV-CONTENT]` median within ±2 ms of HEAD's same-day run (6132970 measured −0.16) |
| 2 | soak fixture, one calibration at +60 s | as 6132970 (+0.23 ms) | **within ±2 ms of +0.23**; cushion 250; 0 holds |
| 3 | `b3nopyr` (shallow) | no raise | as item 1; 0 discarded unseen |
| 4 | `b3pyr` | **258.5 ms** (readout **259 ms**), raised before the anchor; readout "259 ms + SRT 120 ms — raised 9 ms: the stream reorders 209 ms of pictures". HEAD: 250, the 75 % line, 0 exceedances | raise line says BEFORE the first anchor, 0.2585 ± 0.001; **0 target-step jumps; 0 exceedances; 0 discarded unseen; 0 reorder warnings or banner; 0 holds** |
| 5 | `b8pyr` | **467.1 ms**, before the anchor; queue bound 57. **HEAD: the shortfall banner, ~150 exceedances in 60 s** (every 10th-frame P at 417 ms) | as item 4, at 0.4671 ± 0.001. HEAD must show the loss (exceedances > 0), or the fixture proves nothing |
| 6 | `b16pyr` | **800.8 ms**, before the anchor; queue bound 97; the first picture ~0.55 s later than at 250 (the startup fill) | as item 4, at 0.8008 ± 0.001 |
| 7 | `b16at15` (beyond the clamp) | **1.0 s** before the anchor; the warning line and banner, once; exceedances ≈ 45 (the 1.2 s pictures); discarded unseen ≈ the same | cushion 1000; exactly one warning line and one banner, naming 1200 ms and the 1000 ms limit, no key named; exceedances and discarded-unseen both > 0 |
| 8 | hi8 (coarse packing) | packing wins: **336 ms**, readout identical to 6132970 ("raised 86 ms: the sender packs 171 ms of audio per packet") | raise line as 6132970; 0 holds; no reorder line; low-water 60–130 ms |
| 9 | Cloudflare SRT (attended, OBS "SRT Cloudflare", 23.976) | **~258.5 ms** before the anchor (the reorder is logged ~0.1 s before it in `cf-1`); readout "259 ms + SRT 120 ms — raised 9 ms: the stream reorders 209 ms of pictures"; renderer low-water ~8 ms higher than `cf-1` (145–152 → ~153–161) | **no B-frame warning; 0 holds; 0 target-step jumps; 0 discarded unseen**; calibrations within Cloudflare's recent range (−98…−55 ms on 2026-10-08, −92…−86 on 10-07; it moves by day), no step at the raise |
| 10 | gates | — | `swift test` all pass (new `LiveCushionTests` for the reorder term and the readout); soaklog 8 / 8; Profile build, no new warnings in touched files |

**What this stage could invalidate:** only absolute queue figures on B-frame SRT senders, which move
up by (reorder + 50 ms − 250 ms) when that is positive: Cloudflare's by ~8.5 ms. A stream without
B-frames, or with a reorder ≤ 200 ms, must read exactly as 6132970 (items 1–3, 8).

**For HEVC Stage 3 (deeper reordering):** HEVC encoders run deeper pyramids than H.264's defaults
(x265's `bframes` 4 by default and 8 in its slower presets, hierarchical GOP-8/16 in hardware and
broadcast encoders). The measurement is codec-independent — max(pts − dts) on the access unit — so
Stage 3 inherits the term without code: a GOP-8 pyramid at 23.976 asks for ~0.47 s (item 5's
figure), GOP-16 ~0.80 s (item 6), and only a stream that reorders more than 0.95 s meets the clamp
(item 7). What Stage 3 must still check: (a) that the first HEVC GOP's deepest picture arrives before
the anchor, as H.264's does, or else count on one post-anchor `target-step`; (b) the startup delay a
raised cushion adds (the startup fill is the cushion); (c) that L3 (SRT floor 0.20) is judged with
the term in place: it lowers only the floor, so a B-frame stream keeps its reorder + 50 ms.
**Added after the results below:** (d) every reorder test needs ≥ 240 s, since a too-shallow cushion only
loses pictures once the startup over-fill (≈ the reorder) has drained, ~100 s at 0.75 s; (e) deep pyramids
spend that long on LiveClock's rail, with the audio steering following — a longer rail drain on every HEVC
B-frame connect; (f) the rule is conservative at depth (a 1.2 s reorder played clean at 1.0 s): **decided (Robbie,
2026-10-08), revisit the term's depth on deep pyramids in Stage 3, with 240 s+ runs.**

#### Stage 0b-2b — results, 2026-10-08 (unattended, local ffmpeg listener)

**Builds:** HEAD `6132970` (`.build-cc/s0b2bhead-Profile`); the tree (`.build-cc/s0b2b-Profile`); and a
scratch variant of the tree with the reorder term switched off (`.build-cc/s0b2bnoreorder-Profile`,
`considerCushion` passing no reorder; never in the source tree), built to test the premise below.
**Logs:** `~/Desktop/manifold-soak/s0b2b/repro/` (`head-*`, `off-*`, the rest the tree). **Fixtures:** the
table above, plus 240 s versions of `b8pyr`, `b16pyr` and `b16at15` (same encoder settings; same
reorder figures).

| # | result | verdict |
|---|---|---|
| 1 | syncD: HEAD and tree both 250, no raise, no reorder line, readout `Buffer 250 ms + SRT 120 ms`, 0 holds; `[AV-CONTENT]` median **−0.77 (HEAD) / −0.75 ms (tree)**; low-water 272.8 / 274.0 | **PASS** |
| 2 | soak fixture, calibration at +60 s: **−1.08 ms** (6132970 +0.23; Δ 1.31); cushion 250; 0 holds | **PASS** |
| 3 | `b3nopyr`: no raise; 0 holds; 0 out of order; 18 discarded unseen (the baseline, below) | **PASS** |
| 4 | `b3pyr`: **250 → 259 ms BEFORE the first anchor** (83 ms ahead of it), queue bound 32; readout exact ("259 ms + SRT 120 ms — raised 9 ms: the stream reorders 209 ms of pictures"); 0 target-steps, 0 exceedances, 0 out of order, 17 unseen, 0 warnings, 0 holds. HEAD: 250, the 75 % line, 0 exceedances, as predicted | **PASS** |
| 5 | `b8pyr`: **467 ms before the anchor** (121 ms ahead), queue bound 57; 0 / 0 / 0, 13 unseen, 0 holds. HEAD: the ⚠️ line and the shortfall banner | **PASS** — but 60 s does not show HEAD's loss; see *steady state* |
| 6 | `b16pyr`: **801 ms before the anchor**, queue bound 97; 0 / 0 / 0, 4 unseen, 0 holds. **MISS on the side prediction:** the first picture is NOT later (anchor +0.75 s as every run); the startup backlog fills the deeper queue (startup depth 1.23 s against 0.80) | **PASS** on the cushion |
| 7 | `b16at15`: **1000 ms before the anchor** (clamped), queue bound 120; exactly one ⚠️ line and one banner, naming 1200 ms and the 1000 ms limit, no key; model count 45 (60 s) / 180 (240 s). **The renderer lost nothing in either run:** 0 out of order, 12 unseen | **PARTLY:** the warning behaves as specified; the predicted loss did not happen — see *the model* |
| 8 | hi8 (ffmpeg's default packing): **336 ms** before the anchor; the `[SRT-BUFFER]` lines **byte-identical** to 6132970's; no reorder line (200 ms → 0.250, the floor); 0 holds; low-water 94.8 (6132970 95.1) | **PASS** |
| 9 | Cloudflare | attended, below |
| 10 | `swift test` **252 / 252** (244 + 8 new `LiveCushionTests`); `soaklog.test.mjs` 8 / 8; Profile build, no warnings in the touched files | **PASS** |

**The baseline of the unseen count.** The probe counts every picture the display tick passed over, not
only reorder losses: syncD (no B-frames, 300 s) 19, the soak fixture 19, `b3nopyr` (60 s) 18. It is a
fixed per-session figure (the same over 60 s and 300 s), so the frames already queued behind the startup
anchor; read only counts above ~19, and "shown out of order", as loss.

**Steady state: the requirement is real, and 60 s does not reach it.** On a B-frame stream the newest
queued PTS is a P-frame that runs ahead of the others by about the reorder delay, so the startup depth
exceeds the target by about that much, and LiveClock drains it at its ±0.5 % rail: ~20 s at 417 ms of
reorder, ~100 s at 751 ms. Until then no B-frame is late, so the 60 s fixtures showed no loss even with the
term off (`off-b8pyr`, `off-b16pyr`: clock on its +0.5 % rail throughout, err +0.01…+0.5 s). At 240 s:

| 240 s | cushion | shown out of order | unseen (baseline ≤ 19) | model count | holds |
|---|---|---|---|---|---|
| `b8pyr`, term off | 250 | **756** | **149** | 600 | 1 |
| `b8pyr`, tree | 467 before the anchor | **0** | 13 | 0 | 0 |
| `b16pyr`, term off | 250 | **446** | **124** | 660 | 1 |
| `b16pyr`, tree | 801 before the anchor | **0** | 4 | 0 | 0 |
| `b16at15`, tree | 1000 (clamped) | **0** | 12 | 180 | 0 |

So a cushion below the reorder loses ~13–20 % of the pictures once the clock settles, with a hold at the
moment it does, and the term removes the loss completely. HEAD's banner on `b8pyr` was right about the
stream; the loss just starts after the over-fill drains.

**The model is an indicator, not a count.** `reorderExceedances` (per access unit, pts − dts ≥ target)
under-counted the loss at 250 ms (600 against ~900 lost on `b8pyr`) and counted 180 where nothing was lost
at the 1.0 s ceiling (`b16at15`: a 1.2 s reorder played clean, though the clock settled to err −0.32 s). The
real threshold sits between the cushion and max(pts − dts) and depends on the GOP's shape, which is why
the rule's `max(pts − dts) + 0.05 s` is on the safe side. Consequences, both in the tree:
- **The banner and the ⚠️ line say "may".** "This stream reorders its pictures by up to 1200 ms, more than
  Manifold's largest buffer (1000 ms) can cover. Some pictures may arrive too late to be shown." The log's
  shortfall line says "a model count, not the renderer's". A definite "are discarded" was false on the one
  case the warning exists for.
- **Decided (Robbie, 2026-10-08): the term stays as is** (max(pts − dts) + 0.05 s). Its depth on deep
  pyramids (`b16pyr` got 801 ms; the real need is somewhere above 250) is revisited in HEVC Stage 3, with
  240 s+ runs.

**Also fixed on the way:** the `[SRT-FLOW]` line printed `budget` from the configured 0.250, not the live
target, since 0b-2a (hi8 at 336 read "budget 0.250"). It prints the clock's target now ("budget 0.467").

**Pre-existing, recorded:** every B-frame run starts with that over-fill, so the clock and the audio steering
spend the first 20–100 s on their rails, and the renderer low-water falls ~2 ms/s meanwhile (HEAD included).
It is §6.10's *rail drain* with a second cause (the reorder lead instead of bursty delivery). Not 0b-2b's.

**Defaults:** exported before the first launch; after the last quit, 21 run-added `NSWindow Frame` keys,
each checked absent from the snapshot and deleted by name; the domain is dictionary-equal to the snapshot
(1 141 keys). `streamBookmarks` was never read or written (every run dialled `MANIFOLD_SRT_DEBUG_URL`).

#### Stage 0b-2b — attended, 2026-10-08 23:14–23:25 (Robbie): Cloudflare SRT

OBS "SRT Cloudflare" profile, 23.976, SYNC scene; Manifold `.build-cc/s0b2b-Profile` on the "DC Color Live
- SRT" bookmark; one 10-minute session, measure-only calibrations (Cancel each time). Log
`~/Desktop/manifold-soak/s0b2b/cf/cf-1.manifold.log`.

| | predicted | measured | verdict |
|---|---|---|---|
| cushion | ~0.2585, before the anchor | **250 → 258 ms, 82 ms before the first anchor**, no step; reorder **208.0 ms** (today's timestamps; 0.208 also on 2026-10-08 17:38) | **PASS** (±0.001) |
| readout | "259 ms + SRT 120 ms — raised 9 ms: … 209 ms of pictures" | "**258 ms + SRT 120 ms — raised 8 ms: the stream reorders 208 ms of pictures**" | **PASS**: the 1 ms is the stream's figure, not the rule's |
| B-frame warning | none | **none**: no 75 % line, no ⚠️ line, no banner | **PASS** |
| holds, target-steps, coarse, splices | 0 | **0, 0, 0, 0** | **PASS** |
| pictures | — | 18 unseen of 14 404 (the baseline), **0 out of order**; `[SRT-FLOW]` "reorder max=0.208s (budget 0.258s)" | **PASS** |
| renderer low-water | ~153–161 steady (`cf-1` of 0b-2a 145–152, + ~8) | 194 at +10 s, then **145–161 ms, mostly 150–158** | **PASS**, near the band's floor: a ~5 ms rise, within window noise |
| calibrations | Cloudflare's recent range (−98…−55 ms) | **−57.76 (+1:45) / −57.93 (+2:10) / −54.23 ms (+8 min)**; packing 1 frame per PES | **PASS**: at the range's top end, close to 0b-2a's −56.24 / −55.44 on the same day; no step at the raise (there was none) |

The +1 and +2 min calibrations ran at +1:45 and +2:10: step 2 began 104 s after connect, when Robbie gave
the go. **Defaults:** exported before the launch (equal to the first snapshot); one run-added `NSWindow
Frame` key deleted by name; the domain is dictionary-equal to the snapshot (1 141 keys). The bookmark's
keychain item was read for the passphrase; `streamBookmarks` was not written.

**Stage 0b-2b: every prediction met except the two side predictions recorded above** (startup delay on
`b16pyr`, the unseen-count baseline) and the clamp case's loss, which the renderer showed does not happen
at 1.2 s against 1.0 s.

**Committed as `5d623af`.**

#### Stage 1 — the HEVC parser: predictions, written 2026-10-09 before the build changed

**What changes (decision 1):** `--enable-parser=hevc`, the fifth numbered configure change, carried
through the baseline banner, `CONFIGURE_ARGS` (LAYER 1), `EXPECTED_PARSERS` (LAYER 2), a LAYER 3
check beside the h264 one, and `ThirdParty/ffmpeg/README.md`. Same pin (`239f2c733de4`). **Two more
places the audit did not list:** the configure line printed in the About panel's FFmpeg licence
text (`App/AboutWindow.swift`, "Configured exactly as follows"), which must match the shipped build;
and the gate's refusal line, which today prints only the codec (`[SRT] stream is hevc — …`), so it
gains the profile and size. Log-only: the gate, the banner and the teardown do not change.

**Read from the pinned configure before the build:** `hevc_parser_select="hevcparse hevc_sei"`;
`hevcparse` selects `golomb`, `hevc_sei` selects `atsc_a53 golomb`. `golomb` and `atsc_a53` are
already 1 (the h264 parser selects them). So config.h gains **`CONFIG_HEVCPARSE` and
`CONFIG_HEVC_SEI`**, config_components.h **`CONFIG_HEVC_PARSER`**, and nothing else. New objects in
libavcodec: `hevc/parser.o`, `hevc/parse.o`, `hevc/ps.o`, `hevc/data.o`, `hevc/sei.o`,
`dynamic_hdr_vivid.o` (`h2645_parse`, `h2645_sei`, `h2645_vui` are already in, from H.264).

**Builds:** HEAD `9e10a57` with the July dylibs (`.build-cc/s1head-Profile`), and the tree with the
rebuilt dylibs (`.build-cc/s1-Profile`), both unsigned Profile. **Driver:** `scripts/soak/repro/run.sh`
(unattended, local ffmpeg listener). **Fixtures:** `syncD-23.976p-inj0.ts`; hi8 (ffmpeg's default
packing); the soak fixture with one measure-only calibration at +60 s; the audit's four HEVC streams
(12 s each at 8.3 Mb/s: x265 PQ, x265 HLG, VideoToolbox PQ; and `hevc_lo`, 40 s at 165 kb/s; all
Main 10, 1920×1080, 25 fps, with AAC).

| # | what | predicted | pass band |
|---|---|---|---|
| 1 | the three layers | all pass | LAYER 1: the recorded line equals the five-change array. LAYER 2: `CONFIG_GPL 0`, `NONFREE 0`, `VERSION3 0`, `NETWORK 0`; parsers exactly `aac_latm h264 hevc`; no muxer, encoder or BSF. **config.h / config_components.h differ from July's in exactly 3 defines** (the three above), plus the configuration string. LAYER 3: `hevc` and `h264` parsers registered; decoders, demuxers and protocols unchanged; `LGPL version 2.1 or later` |
| 2 | H.264 SRT, syncD and hi8, HEAD against the tree | no change | `[SRT] container` / `stream` / `video:`, `[SRT-AUDIO] stream` and `[SPS-COLOR]` lines **identical text** (timestamps masked); cushion: syncD 250 with no `[SRT-BUFFER] cushion` line, hi8 **336** with `[SRT-BUFFER]` lines identical to 5d623af's; **0 holds** on both; syncD `[AV-CONTENT]` median within ±2 ms of 5d623af's −0.75 |
| 3 | one local H.264 calibration (soak fixture, +60 s) | as 5d623af (−1.08 ms) | **within ±2 ms of −1.08** (−3.08…+0.92) |
| 4a | HEVC refusal, the tree: x265 PQ, x265 HLG, VT PQ | identified ≈ 0.4–0.6 s after transport up (H.264 at 8 Mb/s: 0.40 s in Stage 0) | refusal line reads **`hevc Main 10 1920x1080`**, stream line `hevc 1920x1080`; **≤ 2.0 s** after `transport up`; the banner unchanged ("That stream is HEVC (H.265) — Manifold’s SRT support is H.264 only."); no decoder created, no `[SRT] video:` line |
| 4b | `hevc_lo` (165 kb/s), the tree | ≈ 0.5–1.0 s | as 4a, **≤ 2.0 s** |
| 4c | the same four on HEAD (no parser) | 8.3 Mb/s: ≈ 2.0 s (2 MB `probesize` at 8.3 Mb/s); `hevc_lo`: ≈ 5 s (`max_analyze_duration`); stream line `hevc 0x0` | refused, `0x0`; slower than the tree by ≥ 1 s |
| 5 | the dylibs | same set, same majors | five dylibs, `62 / 62 / 60 / 9 / 6`, `@rpath` ids, `minos 15.0`, arm64 only, no `.a`; **libavcodec +40…+200 KB**, the other four within ±16 KB (only the embedded configuration string changes); the release preflight (release-mac.sh step 1, run on its own) passes |
| 6 | deployment-target warnings | the 0.5.1 static archives' 226 were fixed by CHANGE 4 in July; none now | **0** `built for newer 'macOS' version` in `make.log` and in the app link; the FFmpeg link's only warnings are configure's own `-single_module is obsolete` (7, one per library, July's count) |

#### Stage 1 — results, 2026-10-09 (unattended, local ffmpeg listener)

**Builds:** `.build-cc/s1head-Profile` (HEAD `9e10a57`, July dylibs, embedded libavcodec `31526f07…`) and
`.build-cc/s1-Profile` (the tree, rebuilt dylibs, libavcodec `37cf9f30…`), unsigned Profile, both with
the same 11 Swift warnings. **Logs:** `~/Desktop/manifold-soak/s1/repro/` (`head-*` is HEAD).
**Screenshots:** `~/Desktop/manifold-shots/s1/`.

| # | result | verdict |
|---|---|---|
| 1 | `build_ffmpeg.sh`: LAYER 1 matches the five-change line, both from `config.mak` and read back out of the staged libavutil. LAYER 2: `CONFIG_GPL 0`, `NONFREE 0`, `VERSION3 0`, `GPLV3 0`, `NETWORK 0`; parsers exactly `aac_latm h264 hevc`; decoders, demuxers and protocols unchanged; no muxer, encoder or BSF. **config.h / config_components.h against July: exactly `CONFIG_HEVCPARSE`, `CONFIG_HEVC_SEI`, `CONFIG_HEVC_PARSER` 0 → 1**, plus `FFMPEG_CONFIGURATION`. LAYER 3: `h264` and `hevc` parsers registered, `LGPL version 2.1 or later`, all consumer surfaces present. `--verify-only` passes again afterwards. | **PASS** |
| 2 | syncD and hi8, HEAD against the tree: the `[SRT] container` / `stream` / `video:` / `colorimetry` / `decoded as`, `[SRT-AUDIO] stream`, `[SPS-COLOR]` and `[SRT-BUFFER]` lines are **identical text** (9 / 9 and 11 / 11). syncD: 250, no raise, 0 holds, `[AV-CONTENT]` median **−0.77 (HEAD) / −0.81 ms (tree)** (5d623af −0.75). hi8: **250 → 336 before the anchor**, the `[SRT-BUFFER]` text identical to 5d623af's own hi8 log, 0 holds, low-water ends at 97.0 / 94.9 (5d623af 94.8). Unseen 19 / 19 and 16 / 16, 0 out of order. | **PASS** |
| 3 | soak fixture, calibration at +60 s: **−0.70 ms** (p10 −3.18, p90 +0.46; 5d623af −1.08, Δ +0.38); cushion 250; 0 holds | **PASS** |
| 4a | the tree, refusal after `transport up`: x265 PQ **0.396 s**, x265 HLG **0.396 s**, VT PQ **0.485 s**. Each refusal line reads `[SRT] stream is hevc Main 10 1920x1080 — this build decodes H.264 only; refusing`; the stream line `hevc 1920x1080`; no `[SRT] video:` line, nothing decoded | **PASS** |
| 4b | `hevc_lo` (165 kb/s): **0.469 s**, same lines | **PASS** (≤ 2.0 s; under the 0.5–1.0 s guess: the parser needs only the first IRAP's parameter sets, which arrive in the first PES) |
| 4c | HEAD: 1.677 / 1.689 / 1.963 s at 8.3 Mb/s, **4.654 s** on `hevc_lo`; stream line `hevc 0x0`; refusal line `stream is hevc` | **PASS**: 1.2–4.2 s slower than the tree |
| 4d | the banner, read from a screenshot after the refusal on both builds (x265 PQ): "That stream is HEVC (H.265) — Manifold’s SRT support is H.264 only." **The same on both**; the window returns to the empty state | **PASS** |
| 5 | Five dylibs, majors `62 / 62 / 60 / 9 / 6`, `@rpath` ids, no dependency outside the bundle or the system, `minos 15.0`, arm64 only, no `.a`, headers byte-identical to July's. **libavcodec 842 104 → 908 712 B (+66 608)**; the other four exactly the same size (their bytes differ only in the configuration string). libavcodec's own exported symbols are identical; it gains three re-exported libavutil imports (`av_dynamic_hdr_plus_alloc`, `av_dynamic_hdr_plus_from_t35`, `av_dynamic_hdr_vivid_alloc`, from the HEVC SEI code), which libavutil 60 already exports. `--verify-relocatable` on the tree's app first printed **RELOCATABLE on no evidence** (see *the Gatekeeper prompt*, below); after the fix it passes on evidence: all five dylibs mapped from the bundle. The tree's app passes every non-signing check of release-mac.sh step 6 (exactly the five dylibs, `@rpath`, `LC_RPATH ../Frameworks`, telemetry present). **release-mac.sh step 1 (Preflight), run on its own: passes**, including the About-panel URL check against the pin | **PASS**: the static checks (`otool`) and, re-run after the fix, the dyld test |
| 6 | **0** `built for newer` in `make.log` (only 7 × `-single_module is obsolete`, July's count) and **0** in both app builds | **PASS** — see below |
| gates | `swift test` (ManifoldCore) **252 / 252**; `soaklog.test.mjs` 8 / 8 | **PASS** |

**The "~209 deployment-target warnings" note is stale.** It describes the static by-hand build:
those archives carried `minos 26.0` (no `-mmacosx-version-min` was passed, so they took the host's SDK
default) and the app link warned once per archive member, 226 times as measured in July. CHANGE 4
(2026-07-28, `--extra-cflags/--extra-ldflags=-mmacosx-version-min=15.0`) fixed it. The July shared build
and this one both produce 0. Nothing to fix.

**Found on the way — the published corresponding source would have gone stale. Decided (Robbie,
2026-10-09) and done:** the source tarball's filename carries a build revision, `-rN`, bumped for any
change to the configure line, and a published tarball is never overwritten. Keyed by the pin alone,
the next release would have found the July tarball at the same URL (HTTP 200), uploaded nothing, and
left a `BUILD.txt` without `--enable-parser=hevc` behind the About panel's offer.
- `build_ffmpeg.sh`: `SOURCE_REVISION=2` → `ffmpeg-n8.1.1-239f2c733de4-r2.tar.xz` (r1, the July
  file, keeps its unsuffixed name, which shipped builds print). `SOURCE_REVISION_CONFIG` holds the
  sha256 of the public configure line (r1 `995cb106…`, r2 `c401bdce…`); the build, `--source-info`
  and `--source-tarball` all refuse when the line no longer matches. Tested on a scratch copy with an
  extra flag: exit 1, nothing on stdout, the new hash printed.
- `release-mac.sh` uploads only when the URL answers **404 with the Worker's `Not found` body**;
  `wrangler r2 object put` overwrites silently, so an unrouted 404 (`Unknown endpoint`), a 5xx or a
  timeout now stops the release. Exercised against the live endpoints (read-only): the r1 URL → 200,
  nothing to upload; the r2 URL → 404 `Not found`, upload branch; an unrouted path → refused.
- `Attributions.ffmpegSourceURL` → the r2 URL; release preflight (step 1 alone) passes with it. The
  r2 tarball, built locally to the scratchpad only, matches the commit plus `BUILD.txt`, and its
  `BUILD.txt` carries `--enable-parser=hevc`. **Nothing was uploaded**: the next release uploads r2.

**The Gatekeeper prompt — "Manifold.app is damaged and can't be opened", found by Robbie on return.**
- **Cause: my `--verify-relocatable` run at 11:53.** It copies the app to a `mktemp -d` directory,
  writes `com.apple.quarantine "0081;00000000;Manifold;"` (agent "Manifold", date 0: hence
  "Manifold downloaded this file on an unknown date"), and launches the binary. The system log has
  it: 11:53:09.847 `GK performScan … (team: (null))` after `-67062` (unsigned), 11:53:10.189
  `GK evaluateScanResult: 1 … (id: Manifold), (bundle_id: com.graviton.manifold)`, then
  `Prompt shown (1, 0), waiting for response` and CoreServicesUIAgent `present code-evaluation
  prompt`.
- **Why "damaged":** the bundle is an unsigned Profile build (`CODE_SIGNING_ALLOWED=NO`). Only the
  linker's ad-hoc signature is on the main binary, so `codesign --verify --deep --strict` and
  `spctl --assess` both say "code has no resources but signature indicates they must be present".
  Quarantined, Gatekeeper calls that damaged. `.build-cc/s1head-Profile` and `s0b2b-Profile` give the
  identical result, so **the FFmpeg rebuild did not cause it**. No step replaced a dylib inside a
  signed bundle. `build_ffmpeg.sh` stages only into `ThirdParty/ffmpeg`; nothing in `scripts/` or
  `project.yml` writes into `Contents/`; `release-mac.sh` re-signs only the DMG, after export. The
  only quarantine writer in the repo is this check.
- **The verdict it printed was void.** A process held at the Gatekeeper prompt exists, so the
  check's `kill -0` "stayed up" test passed while the app never ran. The empty `DYLD_PRINT_LIBRARIES`
  output was blamed on hardened runtime, which this unsigned build does not have. So Stage 1's
  relocatability rests on the static `otool` checks only. The temporary copy was deleted by the
  script itself.
- **Not a stale build directory.** Nothing to delete. `.build-cc/s1-Profile` is unquarantined and
  launches normally (every batch run used it).
- **The installed 0.8.4 (19) in /Applications is fine.** `codesign --verify --deep --strict`: valid
  on disk, satisfies its Designated Requirement. `spctl`: accepted, `source=Notarized Developer ID`.
  All five dylibs are signed with Developer ID, hardened runtime. It opened with no prompt
  (`GK evaluateScanResult: 3`) and quit cleanly. Defaults were exported before, and the one
  run-added `NSWindow Frame` key was deleted by name; the domain is dictionary-equal to the original
  snapshot again.
- **Fixed (decided by Robbie, 2026-10-09), in `build_ffmpeg.sh --verify-relocatable`:**
  1. The copy is quarantined **only when the bundle is Developer ID–signed** (`codesign -dvv`:
     a `Developer ID Application` authority and a TeamIdentifier).
  2. A quarantined copy, whether the flag was added or inherited from the source bundle, is
     **assessed with `spctl` before launch, and never launched if rejected.** That is the check
     failing, with the reason.
  3. **It passes only on evidence of loading:** `lsof` on the running process must show all five
     libav dylibs mapped from the copy's own `Contents/Frameworks`. lsof works under hardened
     runtime, where DYLD_* is stripped; a process held at a prompt maps nothing. When
     `DYLD_PRINT_LIBRARIES` prints anything (unsigned builds), it must agree. Any syspolicyd
     `Prompt shown` during the launch fails the check. The process is killed as soon as the five
     are mapped, and a trap removes the copy and puts the moved directories back.
- **Re-run, `.build-cc/s1-Profile` (unsigned, not quarantined):** **RELOCATABLE.** All five dylibs
  were mapped from `/private/var/folders/…/tmp.a9bIcHPICQ/Manifold.app/Contents/Frameworks` with
  `~/manifold-ffmpeg-build/prefix` and `ThirdParty/ffmpeg/lib` moved aside; `DYLD_PRINT_LIBRARIES`
  agrees; no Gatekeeper prompt was logged. Both directories were restored, the copy removed, no
  Manifold process left behind, and `defaults` untouched (1 141 keys, no change): the app is killed
  before it opens a window.
- **The false-pass scenario now FAILS:** the same check on a quarantined copy of that unsigned build
  (scratchpad, `0081;00000000;Manifold;`). It said "not Developer ID–signed — no quarantine flag",
  found the flag inherited on the copy, `spctl` rejected it ("code has no resources but signature
  indicates they must be present"), and it **failed without launching**: exit 1, no Manifold
  process, 0 Gatekeeper prompts in the log. Nothing in either test was launched quarantined.
- **Still open (BUGS.md pre-ship list):** run it on the exported, notarized release build, the one
  path these tests could not reach (quarantined, `spctl` accepted, lsof under hardened runtime).

**User-visible:** none in behaviour. The About panel's FFmpeg licence text gains one configure flag
and the source URL gains `-r2`; not a release-notes item. **Defaults:** exported before the first launch; afterwards 15 run-added
`NSWindow Frame` keys, each checked absent from the snapshot and deleted by name; the domain is
dictionary-equal to the snapshot (1 141 keys). `streamBookmarks` was never written (every run dialled
`MANIFOLD_SRT_DEBUG_URL`).

#### Stage 2 — the HEVC SPS colour reader: predictions, written 2026-10-09 before the code

**What changes (decision 4).** The `H264SPSColor` target becomes **`SPSColor`**: one codec-neutral
target holding the shared bit reader and emulation-prevention removal, one result type `SPSColor`
(`reach`, the three codes, `videoFullRangeFlag`, the per-axis verdicts and declared tables), and two
readers that return it, `H264SPSColor.parse(nal:)` (the existing code, moved unchanged) and
`HEVCSPSColor.parse(nal:)` (new). `H264SPSColor` stays as the H.264 reader's namespace, so its tests
change only their `import`. The app's four users and project.yml follow the rename; nothing in the
app calls the HEVC reader yet.

**The HEVC reader (H.265 §7.3.2.2.1, §7.3.3, §7.3.4, §7.3.7, §E.2.1).** Only NAL type 33 with
`nuh_layer_id` 0 and a non-zero `nuh_temporal_id_plus1` (decision 8: base layer only; anything else is
`.notAnSPS`). It walks `profile_tier_level` with the sub-layer flags, the 2-bit padding and each
sub-layer's 88-bit profile and 8-bit level; chroma format (and `separate_colour_plane_flag`); the size;
the conformance window; bit depths; `log2_max_pic_order_cnt_lsb_minus4`; sub-layer ordering; the
coding/transform block sizes; HEVC `scaling_list_data()`; PCM; every `st_ref_pic_set()`, inter-set
prediction included (it keeps `NumDeltaPocs` per set, because a predicted set's flag count is the set
before it plus one); the long-term reference pictures (`lt_ref_pic_poc_lsb_sps` at the POC LSB
width); then the VUI to `matrix_coefficients`, and stops. Each count and range is checked against
the standard's bound; a short, odd or out-of-range SPS returns `.malformed`, never a colour.

**Fixtures, measured offline first** (each SPS's expected values generated from FFmpeg 8.1.1's
`trace_headers`, never from this reader):
- **x265 4.2 (real):** 709, PQ (with `hdr10`), HLG, 601, `5 / 6 / 5` (matrix 5), no colour
  description, full range with no colour description, `temporal-layers=3` (3 sub-layers; sub-layer
  profile/level flags 0, so the 2-bit padding path), `scaling-list=default` (enabled, no list data),
  Main 4:2:2 10, Main 4:4:4 10, HLG at `preset slower`.
- **VideoToolbox (real):** 8-bit plain (writes 2/2/2), Main 10 with PQ flags (writes **2/2/9**: only
  the matrix, as the audit found), the same through `hevc_metadata` (9/16/9). All 1920×1088 with a
  4-row conformance window, 4 explicit reference picture sets (`NumDeltaPocs` 4/1/2/3),
  `scaling_list_enabled` 1 with no data, no sub-layer ordering info.
- **`hevc_metadata` on x265 (real bitstreams, rewritten VUI):** 2/2/2, 9/2/9, 3/0/3, 200/100/99,
  12/13/0, and `sample_aspect_ratio=256/1` (Extended_SAR).
- **Synthetic, where no encoder here writes the syntax.** **x265 4.2 writes no SPS reference picture
  sets** (`num_short_term_ref_pic_sets` 0 at every preset and GOP tried; its RPS go in slice headers),
  so the brief's "x265's default inter-predicted RPS" do not exist in this x265. Also absent from every
  encoder: PCM, long-term refs, scaling-list data, sub-layer profile/level bodies, no VUI, no
  video_signal_type. Nine SPS were written field by field from x265 PQ's values (`scratchpad/s2/synth.py`):
  HM's random-access GOP-8 RPS inter-predicted (7 predicted sets, two entries not used by the current
  picture) and the same 8 sets explicit; 3 sub-layers with profile/level bodies; explicit scaling lists
  (explicit, predicted and default matrices, DC coefficients); PCM; 3 long-term refs; no VUI; no
  video_signal_type; and all of them at once with Extended_SAR and HLG. **Each is accepted by two
  independent FFmpeg parsers**, CBS (`trace_headers`, which supplies the expected values) and the hevc
  decoder's own SPS parser (no overread or error at `-loglevel debug`). A control with one bit flipped
  inside the RPS made the decoder report "Overread in VUI", so the check would have caught a desync.
  Same precedent as the H.264 `scalingLists` fixture.

Every fixture has `00 00 03` in its `profile_tier_level`, before the colour fields.

| # | what | predicted | pass band |
|---|---|---|---|
| 1 | every fixture (21 real, 9 synthetic) | each field equals `trace_headers` | `reach`, the three codes and `videoFullRangeFlag`, **and every walked field** (sub-layers, chroma format, size, conformance window, bit depths, POC LSB width, scaling-list flags, PCM, `NumDeltaPocs` per set, inter-predicted count, long-term count, SAR) equal for all 30. Any mismatch fails |
| 2 | every prefix of every fixture | undeclared or exact | **0 prefixes read a different colour**; every prefix that ends before `matrix_coefficients` is `.malformed` |
| 3a | mutant: emulation prevention not removed, all 30 | fails closed | **0 wrong colours**: every fixture reads undeclared (the 2–3 escape bytes shift the parse by 16–24 bits) |
| 3b | mutant: `st_ref_pic_set()` not walked (the count read, the sets skipped) | fails closed on the 6 fixtures with SPS RPS; the other 24 unaffected | the 6 (3 VideoToolbox, `synth_interRPS`, `synth_explicitRPS`, `synth_all`) read undeclared; **0 wrong colours** |
| 3c | mutant (added): inter-set prediction read as explicit | fails closed on the 2 inter-predicted fixtures | **0 wrong colours** |
| 4 | the H.264 tests after the rename | unchanged | the test file's diff is the `import` line; every test passes |
| 5 | the app | builds and behaves identically | Profile build; syncD on HEAD `f4b6746` and the tree: `[SPS-COLOR]`, `[SRT] container` / `stream` / `video:` / `colorimetry` and `[SRT-AUDIO] stream` lines **identical text**; 0 holds on both |
| 6 | gates | — | `swift test` all pass (252 + the new HEVC tests); soaklog 8 / 8 |

#### Stage 2 — results, 2026-10-09 (unattended)

**Code.** `Packages/ManifoldCore/Sources/SPSColor/`: `SPSColor.swift` (result type, CICP tables,
`unescape`, `BitReader`, the shared `video_signal_type` tail), `H264SPSColor.swift` (the H.264
reader, its logic unchanged, now a namespace returning `SPSColor`), `HEVCSPSColor.swift` (new).
Moved with `git mv`, so history follows. The app's four users import `SPSColor` and take `SPSColor`
values; `LiveVideoDecoder` still calls `H264SPSColor.parse(nal:)`. Nothing calls the HEVC reader yet.
**Fixtures:** `Tests/SPSColorTests/HEVCSPSColorTests.swift`; generators in the session scratchpad
(`s2/gen.sh`, `s2/synth.py`, `s2/swiftfx.py`, which writes the Swift literals from `trace_headers`).
**Builds:** HEAD `f4b6746` = `.build-cc/s1-Profile` (built from the Stage 1 tree 6 min before the
commit; its binary carries all three committed app changes, and no app file changed since);
the tree = `.build-cc/s2-Profile`. **Logs:** `~/Desktop/manifold-soak/s2/repro/`.

| # | result | verdict |
|---|---|---|
| 1 | All 30 fixtures: `reach`, codes, `videoFullRangeFlag` **and the whole walk** equal `trace_headers` (VideoToolbox `NumDeltaPocs` 4/1/2/3; GOP-8 4/3/4/4/4/4/4/4 with 7 inter-predicted; 3 long-term refs; Extended_SAR 256/1). Per axis: VideoToolbox PQ reads `nil / nil / 9`, 9/2/9 reads `9 / nil / 9`, 12/13/0 reads `12 / 13 / 0`, 2/2/2 and both reserved sets undeclared | **PASS** |
| 2 | Every prefix of all 30 fixtures: the exact reading, or `.malformed` / `.notAnSPS`; 0 different colours | **PASS** |
| 3a | No emulation-prevention removal: all 30 read undeclared, 0 colours | **PASS** |
| 3b | RPS not walked: the 6 fixtures with SPS RPS read undeclared; the other 24 read their true colour | **PASS** |
| 3c | Inter-prediction read as explicit: `synth_interRPS` and `synth_all` undeclared; the other 28 true | **PASS** |
| 4 | `H264SPSColorTests.swift`: the diff is the `import` line; 13 / 13 pass | **PASS** |
| 5 | syncD, HEAD against the tree: the `[SRT]`, `[SRT-AUDIO] stream`, `[SPS-COLOR]` and `[SRT-BUFFER]` lines **identical text** (9 / 9); `[SPS-COLOR] SRT: primaries=1 (Rec.709) declared · transfer=1 … · matrix=1 … → tagged \| video_full_range_flag=0, range in use limited — agrees` on both; 0 holds on both; `[AV-CONTENT]` median −0.83 / −0.82 ms. Profile build, the same warnings as Stage 1's | **PASS** |
| 6 | `swift test` **263 / 263** (252 + 11 new); `soaklog.test.mjs` 8 / 8 | **PASS** |

**The tests were shown to fail.** Every test passed on the first run, so the reader was broken on
purpose twice and restored byte-for-byte afterwards. (a) One reserved_zero_2bits pair dropped from
the sub-layer padding: `x265_tl`, `synth_subLayers` and `synth_all` failed field and colour checks.
(b) The scaling-list coefficient count off by one: `synth_scalingLists` and `synth_all` failed.
Both broken readers still failed closed, reading `.malformed`, not a wrong colour.
**Garbage:** 18 400 random SPS-typed buffers (4–95 bytes): 18 391 `.malformed`, **0 with any
declared axis**.

**Found on the way, recorded for Stage 3:**
- **x265 4.2 writes no SPS reference picture sets**; its RPS are in the slice headers. The audit's
  x265 random-access findings (CRA, RASL) are unaffected, but Stage 3's access-unit builder will meet
  `short_term_ref_pic_set_sps_flag` 0 on every x265 slice. The SPS-level inter-predicted path is
  covered by synthetic fixtures only.
- **VideoToolbox HEVC Main 10 writes 2/2/9 when asked for PQ** (only the matrix), as the audit
  found from the command line: a VideoToolbox sender's PQ arrives undeclared on primaries and
  transfer unless something rewrites the VUI. OBS's path (Stage 6) may differ; it sets the
  properties through VideoToolbox directly.

**Defaults:** exported before the first launch; after the last quit, 2 run-added `NSWindow Frame`
keys, each checked absent from the snapshot and deleted by name; the domain is dictionary-equal to
the snapshot (1 141 keys). `streamBookmarks` was never written (every run dialled
`MANIFOLD_SRT_DEBUG_URL`).

#### Stage 3 — the HEVC access-unit builder, decoder and gate: predictions, written 2026-10-09 before the code

**What changes.**
- **`App/H264/HEVCAccessUnitBuilder.[ch]`** (new, pure C, beside the H.264 builder): the two-byte NAL
  header; VPS and SPS held one each (latest wins), **PPS held by id, all 64** (a 64 × 1 KB table is
  cheap, and VideoToolbox takes every PPS in the format description); the PPS table is cleared when the
  SPS bytes change; Annex B → 4-byte lengths; `nuh_layer_id` > 0 dropped and counted (decision 8);
  prefix and suffix SEI passed through unparsed (Stage 5 parses them); AUD and filler dropped; reserved
  and unspecified non-VCL types (41–63) dropped and counted. The AU says whether it holds a
  random-access picture (types 16–23, and which) and whether it is RASL (8, 9).
- **The random-access gate (decision 5) as a small C state machine in the same file,** so the harness
  tests the rule the app runs: closed until any random-access picture; after opening on a CRA (or a
  reserved IRAP), its RASL pictures are dropped until the next random-access picture; after a BLA,
  always; after an IDR, none. Closed again by a decode error or a new session ("the same rule after
  loss").
- **C harness (decision 9)**: `scripts/ctest/hevc_access_unit_builder_test.c`, run by
  `scripts/ctest/run.sh` (clang, `-Wall -Wextra -Werror`, ASan + UBSan). Synthetic NAL streams through
  the real scanner and reader.
- **`SRTAccessUnitReader`** takes a codec at creation; `ManifoldSRTAccessUnit` gains the codec, the VPS,
  the packed PPS list, the random-access type and the RASL flag. `SRTSession.m` picks the codec from
  `codec_id`.
- **`LiveVideoDecoder`**: a codec at init (default H.264, so WHEP's construction is unchanged); the VPS
  and the extra PPS as defaulted arguments to `decode` (WHEP's call unchanged); VPS and every PPS in the
  changed-parameter-set check; `CMVideoFormatDescriptionCreateFromHEVCParameterSets`; `x420` requested as
  for H.264; `HEVCSPSColor` for `[SPS-COLOR]`; RASL drops counted.
- **The gate**: identification passes `h264` and `hevc`. Then each new HEVC SPS is read with a new
  `HEVCSPSColor.format(nal:)` (profile, chroma format, bit depths, from the walk Stage 2 already does)
  **before** it reaches the decoder: HEVC Main and Main 10 at 4:2:0 are accepted; 4:2:2 and 4:4:4 are
  refused with a banner saying they are not supported yet; anything else (4:0:0, 12-bit, other RExt) is
  refused naming what it is. A refused stream is never decoded, so it can never be resampled.
- **Wording**: "waiting for an IDR" → "waiting for a keyframe" (on HEVC, any random-access picture). This
  changes the `[SRT-AU]` waiting line on H.264 too, on purpose; it is not in item 8's compared set.
- Session totals log HEVC's own NAL counts (VPS/SPS/PPS, IDR/CRA/BLA, RASL/RADL, trailing, SEI, layer > 0)
  and the decoder's RASL drops.

**Measured offline first** (`nals.py` in the session scratchpad: ffmpeg's own demux, `-c copy -copyinkf`,
NAL types per access unit; 90 kHz):

| fixture | built with | first AU | random access | RASL per CRA | max(pts − dts) |
|---|---|---|---|---|---|
| `hevc_pq_x265`, `hevc_hlg_x265` (Stage 1's) | x265 Main 10, 25p, 12 s | IDR | IDR, then CRA every 25 | 4 | **240 ms**, first reached at AU 2 |
| `x265_709` | x265 Main (8-bit), 1/1/1 | IDR | IDR, one CRA at 246 | 4 | 240 ms |
| `hevc_pq_vt` (Stage 1's) | VideoToolbox Main 10, VUI 2/2/9 | IDR | IDR only, every 26 | — | 0 |
| `vt_pq_meta` | VideoToolbox Main 10 + `hevc_metadata` 9/16/9 | IDR | IDR only, every 12 | — | 0 |
| `x265_join_cut` | x265 Main 10 PQ, keyint 25, 60 s, cut at a TS packet boundary 12.25 % in, served with `-copyinkf` | **TRAIL** | **11 AUs (0.44 s of DTS) before the first CRA** | 4 | 240 ms |
| `x265_r240` | x265 Main 10 HLG, `preset fast` (bframes 4, B-pyramid), 25p, 240 s | IDR | CRA ~ every 250 | 4 | **240 ms** at AU 2 |
| `x265_b8_240` | x265 Main 10 PQ, `bframes=8:b-adapt=0`, 23.976, 240 s | IDR | CRA ~ every 250 | 6 | **417.1 ms** at AU 2 |
| `x265_422`, `x265_444` | x265 Main 4:2:2 10, Main 4:4:4 10 (profile `Rext`) | IDR | as 709 | 4 | 240 ms |
| through MediaMTX (`x265_join` published, a reader joining at +3.3 s) | — | **CRA** (MediaMTX starts a joining SRT reader at a random-access point) | CRA every 25 | 4 | 240 ms |

ffmpeg's stream copy drops leading non-key packets unless told `-copyinkf`, so `run.sh` gains a
`COPYINKF=1` switch for the join fixture; without it the sender itself starts at the CRA.

**Builds:** HEAD `fd657f7` (`.build-cc/s3head-Profile`, built from the clean tree before any edit, 11
warnings) against the tree (`.build-cc/s3-Profile`), unsigned Profile. **Senders:** the local ffmpeg
listener through `scripts/soak/repro/run.sh`; MediaMTX v1.21.1's SRT (`publish:live` / `read:live`,
the instance already running); WHEP from MediaMTX with an ffmpeg RTSP publisher. Everything unattended.

| # | what | predicted | pass band |
|---|---|---|---|
| 1 | C harness | all pass, sanitizers clean | every case passes: NAL splitting (3- and 4-byte start codes, AUD dropped, both SEI kept, emulation prevention intact, lengths exact); two-byte header (an HEVC TRAIL is not read as H.264 type 2, a CRA is random access); parameter sets out of band, repeats not a change, a changed PPS a change, two PPS ids both held in id order, a new SPS clearing the PPS table; layer > 0 dropped (a layer-1 SPS does not replace the base one); the gate: closed until random access, RASL dropped after a starting CRA and after any BLA, kept after a mid-stream CRA, none after an IDR, re-closed by loss; malformed (1-byte, forbidden bit) counted, ignored. **Shown to fail:** the builder broken twice on purpose (H.264's type read; the gate without the RASL rule) fails the harness each time |
| 2 | x265 PQ, HLG, 709 and VideoToolbox + `hevc_metadata`, over the ffmpeg listener and over MediaMTX | decoded, tagged, no promote | `[SRT] video: hevc Main 10 1920x1080 @ 25.000 fps` (709: `hevc Main`); one HEVC SPS line, accepted, 4:2:0; format description 1920x1080; **`[SRT] decoded as 'x420' — … no promote needed`** on every run, the 8-bit 709 included (VideoToolbox is asked for `x420`); `[SPS-COLOR]` all three declared → tagged; **`[SCOPE-COLOR] source: … tagged (CICP 9-16-9)`**, **9-18-9**, **1-1-1**, VT 9-16-9; the chain readout's tier "tagged"; **0 decode errors**; 0 out of order; RASL dropped **0** on the listener (it starts at the IDR; a mid-stream CRA's RASL are decodable) and **exactly 4** on MediaMTX (it starts at a CRA); x265 cushion **290 ms before the first anchor** ("raised 40 ms: the stream reorders 240 ms of pictures"), VT 250 with no raise |
| 3 | VideoToolbox without the metadata fix (`hevc_pq_vt`) | matrix only | `[SPS-COLOR]` primaries=2 unspecified → undeclared, transfer=2 unspecified → undeclared, matrix=9 declared → **partly assumed**; never a declared 2020 primaries or PQ |
| 4 | mid-way join, `x265_join_cut` (listener, `COPYINKF=1`) | waits 0.44 s of stream, starts at the CRA, drops its RASL | the first 11 AUs dropped before the gate (no parameter sets yet: `droppedNoFormatDescription` 11); the gate opens on **CRA (21)**; **exactly 4 RASL dropped** (the starting CRA's), none after; **0 decode errors**; first picture **≤ 1.0 s** after the first access unit |
| 5 | reorder, 240 s: `x265_r240`, `x265_b8_240` | the cushion follows before the clock starts | `x265_r240` **290 ms**, `x265_b8_240` **467 ms** (queue bound 57, as `b8pyr`), both BEFORE the first anchor (raised at AU 2); 0 target-steps, **0 shown out of order**, unseen within the baseline (**≤ 19**), 0 holds, no reorder warning. The 0b-2b depth question is answered with the settled clock error and the low-water, not by changing the term |
| 6 | frame rate and DeckLink | 25.000 / 23.976 declared; Follow source available | `[SRT-FORMAT] frame rate 25.000 fps declared` (23.976 for `b8`); `DeckLink D4a: LIVE source format 1920x1080 @ 25.000 fps → mode 1080p25`. The persisted manual pick (1080p23.98) still wins, as it does for H.264; to see Follow source engage, the pick is cleared through the menu and restored afterwards, the key read and stashed first: **`mode → 1080p25 via follow source`** |
| 7 | `x265_422`, `x265_444` | refused at the first SPS | identified as `hevc Rext 1920x1080`; the HEVC SPS line names 4:2:2 (4:4:4) 10-bit and refuses; **a banner saying 4:2:2 (4:4:4) is not supported yet**, naming what does play; no format description, no decode, no route, no `[SPS-COLOR]` line, nothing resampled; the window returns to the empty state |
| 8 | regression: H.264 SRT (syncD, hi8) and WHEP, HEAD against the tree; one H.264 calibration | unchanged | SRT: `[SRT] container` / `stream` / `video:` / `colorimetry` / `decoded as`, `[SRT-AUDIO] stream`, `[SPS-COLOR]`, `[SRT-BUFFER]` **identical text**; syncD 250, 0 holds, `[AV-CONTENT]` median within ±2 ms of HEAD's same-day run; hi8 336 before the anchor. WHEP: `[WHEP]` connect/format lines, `[WHEP-DECODE]` and `[SPS-COLOR]` **identical text** (timestamps and ids masked). Calibration (soak fixture, +60 s): **within ±2 ms of Stage 1's −0.70** |
| 9 | gates | — | `swift test` all pass (263 + the new format tests); `soaklog.test.mjs` 8 / 8; the C harness; Profile build with no new warnings in the touched files |

**What this stage could invalidate:** nothing measured on H.264. On HEVC, nothing exists to invalidate:
every HEVC run before this one was refused at the gate.

#### Stage 3 — results, 2026-10-09 (unattended)

**Code.** `App/H264/HEVCAccessUnitBuilder.[ch]` (builder and gate); `SRTAccessUnitReader` takes the
codec (`ManifoldSRTVideoCodec`, also on `ManifoldSRTVideoFormat`, from one `srtVideoCodec()` in
`SRTSession.m`); `LiveVideoDecoder(logTag:codec:)`; `SRTFrameRouter`'s HEVC format gate
(`admitHEVCFormat`, before the decoder); `SRTClient.handleFormatRefused`; `HEVCSPSColor.format(nal:)` and
`HEVCSPSFormat` in the `SPSColor` target; the C harness `scripts/ctest/`; `run.sh`'s `COPYINKF`.
**Builds:** `.build-cc/s3head-Profile` (HEAD `fd657f7`, built from the clean tree before the first edit)
and `.build-cc/s3-Profile` (the tree), unsigned Profile, the same 11 warnings each (the warning sets are
identical). **Logs:** `~/Desktop/manifold-soak/s3/` (`repro/` listener, `mtx/` MediaMTX, `mtx-looped/`
the first MediaMTX attempt, `whep/`); screenshots `~/Desktop/manifold-shots/s3/`.

| # | result | verdict |
|---|---|---|
| 1 | **200 checks, 0 failed**, clang `-Wall -Wextra -Werror`, ASan + UBSan clean. **Shown to fail:** the builder with H.264's one-byte type read fails 67 checks; the gate without the RASL rule fails 10 (`after loss`, `reserved IRAP`, …). Both broken copies were scratch files; the tree's builder was never edited for this | **PASS** |
| 2 | **Listener** — x265 PQ, HLG, 709 (Main, 8-bit), VT + `hevc_metadata`: identified 0.39–0.49 s after `transport up`; one `[SRT] HEVC SPS: … 4:2:0 … → accepted` line each; `format description built (HEVC) — 1920x1080, VPS 24 bytes, SPS 43–47 bytes, 1 PPS`; **`[SRT] decoded as 'x420' — already in the renderer's 10-bit domain, no promote needed` on all four, 8-bit 709 included**; `[SPS-COLOR]` all three declared → tagged; `[SCOPE-COLOR] source:` **9-16-9, 9-18-9, 1-1-1, 9-16-9, all "tagged"**; **0 decode errors**, 0 out of order, 0 holds; RASL skipped **0** (started at the IDR; the 44 RASL of the 11 later CRAs decoded); x265 cushion **290 ms BEFORE the first anchor** ("raised 40 ms: the stream reorders 240 ms of pictures"), VT 250, no raise. **MediaMTX** (single publish, reader joining live): the x265 three **opened on a CRA ("keyframe acquired (CRA, NAL 21) … its RASL pictures will be skipped") and skipped exactly 4 RASL**, 0 decode errors, x420, tags as the listener; VT opened on its IDR, 0 skipped. The chain readout was not read off the window: in playback the window shows no chrome, and the AX read failed (see *the drivers*). The readout's tier is the renderer's `sourceColorProvenance`, which is what `[SCOPE-COLOR]` prints | **PASS**, but the chain readout's tier is taken from the log line that prints the same value, not from the window |
| 3 | `hevc_pq_vt`: `[SPS-COLOR] SRT: primaries=2 unspecified → undeclared · transfer=2 unspecified → undeclared · matrix=9 (Rec.2020) declared → partly assumed`; `[SCOPE-COLOR] source: Rec. 709 · Rec. 709 — partly assumed (CICP –-–-9)` | **PASS** |
| 4 | `x265_join_cut`, `COPYINKF=1`: `transport up` → identified 0.634 s → **keyframe acquired (CRA, NAL 21) 0.743 s** → first decoded 0.745 s; 1313 AUs → 1298 pictures, so 11 dropped before the format description (1313 − 1298 − 4; the totals line does not print that counter separately), **RASL skipped 4**, 0 awaiting-keyframe drops after it, **0 decode errors**, 0 out of order, 3 unseen | **PASS** |
| 5 | `x265_r240`: **290 ms BEFORE the first anchor**, queue bound 35; `x265_b8_240` (23.976): **467 ms BEFORE the first anchor**, queue bound 57; both: 0 target-steps, **0 shown out of order**, unseen **14 / 10**, 0 holds, no reorder warning, 0 decode errors, 5998 / 5753 pictures from as many AUs. The depth question: renderer low-water settles at **141–144 ms** (290 ms cushion) and **~238 ms** (467 ms), clock error median ~0 after +120 s. The term keeps about half its depth in hand with no loss: conservative, as 0b-2b found at 1.2 s. No change to the term | **PASS** |
| 6 | `[SRT-FORMAT] frame rate 25.000 fps declared` (23.976 on `b8_240`), on every listener run; **`DeckLink D4a: LIVE source format 1920x1080 @ 25.000 fps → mode 1080p25`**: the source-derived mode is computed, which is what makes Follow source available. **Engaging it was not shown:** the persisted manual pick (1080p23.98) won as it does for H.264, and three attempts to click "Follow source" through accessibility found no reachable DeckLink menu in the playback window. Nothing was clicked and nothing written: `manifold.decklink.manualOutputMode` read `1080p23.98` before and after each attempt | **PARTLY**: the rate and the derived mode pass; the switch to Follow source is unverified (one click, attended) |
| 7 | `x265_422` / `x265_444`: identified `hevc Rext 1920x1080 @ 25.000 fps`; `[SRT] HEVC SPS: Format Range Extensions (general_profile_idc 4), 4:2:2 (4:4:4), 10-bit luma / 10-bit chroma → refusing: … nothing is resampled to fit`; **banners (screenshots): "That stream is HEVC 4:2:2 10-bit — Manifold doesn’t play HEVC 4:2:2 over SRT yet. HEVC 4:2:0 (Main and Main 10) plays."**, and the same for 4:4:4; no format description, no decode (1 AU in, 0 pictures), no `[SPS-COLOR]`, no scope source; the window back at the empty state | **PASS** |
| 8 | **SRT:** syncD 9 / 9 and hi8 11 / 11 lines **identical text** (`[SRT] container` / `stream` / `video:` / `colorimetry` / `decoded as`, `[SRT-AUDIO] stream`, `[SPS-COLOR]`, `[SRT-BUFFER]`); syncD 250, 0 holds, `[AV-CONTENT]` median **−0.07 (HEAD) / −0.04 ms (tree)**; hi8 **250 → 336 BEFORE the first anchor** on both, 0 holds. **WHEP** (MediaMTX, ffmpeg RTSP publisher, H.264 Constrained Baseline + Opus, the saved local WHEP bookmark): 29 / 29 structural lines; `[WHEP-DECODE] format description built — 1920x1080, SPS 27 bytes, PPS 4 bytes`, `keyframe acquired`, `[SPS-COLOR] WHEP: … → tagged` and the colorimetry line **identical**; the only differences are values that vary run to run (MediaMTX's answer SDP 1826 / 1822 bytes, the ephemeral ICE port, three startup realign depths, and the join moment: noFmt 34 / 33, so 1423 / 1424 frames of 1457), 0 errors on both. **Calibration** (soak fixture, +60 s): **−0.21 ms** (p10 −3.80, p90 +1.51) | **PASS** |
| 9 | `swift test` **266 / 266** (263 + 3 format tests); `soaklog.test.mjs` 8 / 8; the C harness 200 / 200; Profile build, 11 warnings, the same set as HEAD's | **PASS** |

**The first MediaMTX attempt was invalid: my sender lost its own IDR.** It published each file twice with
`-stream_loop 1`. **ffmpeg's stream copy drops the second pass's IDR**: a local `-stream_loop 1 -c copy`
of `hevc_pq_x265` has 599 AUs and one IDR. So every x265 stream through MediaMTX lost a picture
everything after it referenced. Manifold did what the rule says: one `-12909`, the gate re-closed, a
mid-stream post-anchor cushion step (the junction's timestamps read as a 302 ms reorder), and decoding
resumed at the next CRA. `x265_709` has a CRA only every ~10 s, so it lost 244 pictures. The VT stream,
IDR-only with no reordering, came through clean. Kept in `mtx-looped/` as a recovery-after-loss sample;
Stage 4 owns that test. The table's MediaMTX results are the single-publish re-run.

**Found on the way — MediaMTX makes up DTS for an HEVC stream with no reordering; the guess is 50 fps.**
Through the running MediaMTX (v1.21.1, the `-abs` config) the VideoToolbox stream, whose source has
`dts = pts` at 3600-tick steps, arrives with DTS alternating 1800- and 5400-tick steps (`dts ≠ pts`).
`av_guess_frame_rate` reads that as **50.000 fps**. The x265 streams arrive at 25.000. The listener gives
25.000 for both. That is the server's timestamping, not the HEVC path. Under the server-agnostic rule
nothing here special-cases it. **Open for Robbie:** a VideoToolbox-encoded HEVC sender through MediaMTX
would make DeckLink's Follow source pick 1080p50. Whether the rate should come from the SPS or VPS VUI
timing first (when present) is a design question, not a Stage 3 change. Not checked: the default
MediaMTX config, and H.264 over MediaMTX SRT.

**Found on the way — the earlier stages' `[AV-CONTENT]` medians were the negative half only.** The
scratch regex used from Stage 0b-2b on (`audio−now=([-\d.]+)`) cannot match a leading `+`, and the log
prints positive figures with one, so every positive reading was dropped. Recomputed from the same logs
with both signs (240 readings each):

| run | recorded | negative half (reproduces the recorded figure) | all readings |
|---|---|---|---|
| 0b-2b syncD, HEAD `6132970` / tree | −0.77 / −0.75 | −0.77 / −0.75 | **−0.09 / −0.03** |
| Stage 1 syncD, HEAD / tree | −0.77 / −0.81 | −0.77 / −0.81 | **−0.04 / −0.10** |
| Stage 2 syncD, HEAD / tree | −0.83 / −0.82 | −0.83 / −0.82 | **−0.15 / −0.06** |

Every verdict stands: each band was relative (±2 ms of the other build), and both builds carried the
same bias. 0b-2a's −0.10 and 0b-1's −0.06 are true medians. The calibration figures are unaffected
(they are the app's own `[CALIBRATION] RESULT`). Stage 3's figures above use both signs.

**The unseen count at 25 fps.** The 12 s listener runs discarded 14–21 pictures unseen with 0 out of
order (`pq` 20, `hlg` 21). 0b-2b's baseline of ≤ 19 was measured at 23.976 with 250 ms. The 240 s
runs, judged against that baseline, read 14 and 10. It is the startup figure, not loss.

**The drivers.** AppleScript's `entire contents of (first window whose subrole is "AXStandardWindow")`
fails with −1700 in this window state, so the window-text reads and the DeckLink clicks failed. The
helpers that address `group 1 of` the same window (the calibration sheet, the Connect Stream menu)
worked. The banners were read from screenshots, as in Stage 1.

**Defaults:** exported before the first launch (1 141 keys; `manifold.decklink.manualOutputMode` =
`1080p23.98` stashed). After the last quit: 29 run-added `NSWindow Frame` keys, each absent from the
snapshot, deleted by name; nothing removed or changed; the domain is dictionary-equal to the snapshot
(1 141 keys). `streamBookmarks` was read (the WHEP bookmark, from the menu) and never written.

**Stage 3: items 1–5 and 7–9 met. Item 6 is partly met: the rate and the derived mode pass, and the
switch to Follow source needs one attended click.**

#### Stage 4 — robustness, sync, frame rate: predictions, written 2026-10-09 before the code changed

**Decided (Robbie, 2026-10-09):** frame rate for HEVC and H.264 over SRT uses the stream's own declared
timing (SPS VUI, or the HEVC VPS) when present, falls back to the measured rate when absent, and logs once
when they disagree. Server-agnostic: no per-server rules.

**What changes.**
- **`SPSTiming`** (new, in the `SPSColor` target): `H264SPSColor.timing(nal:)` continues the same walk past
  the colour fields to `chroma_loc_info` and `timing_info` (rate = `time_scale` / 2 `num_units_in_tick`);
  `HEVCSPSColor.timing(nal:)` continues to `default_display_window` and `vui_timing_info` (rate =
  `time_scale` / `num_units_in_tick`); `HEVCSPSColor.vpsTiming(nal:)` reads `vps_timing_info`. A stream with
  `field_seq_flag` 1 declares a field rate, which is not taken as a frame rate. Same fail-closed rules as the
  colour reader: truncated or out of range → no declaration.
- **`SRTFrameRouter`:** "measured" is today's `av_guess_frame_rate` figure, unchanged. On each new SPS (HEVC:
  SPS, then VPS if the SPS has none) the declared rate, if plausible (1–240 fps), replaces it as the
  published rate (DeckLink Follow source). One `[SRT-FORMAT]` line per new declared value; one line per
  session when the stream declares nothing; **one line per session when declared and measured disagree by
  more than 0.05 %**. The startup anchor's gap threshold stays on the measured rate (it is set before the
  first SPS, and a threshold is not what the decision is about). `[SRT] video: … @ N fps` is the demuxer's
  line and keeps the measured figure.
- **The loss harness:** the repo had none for SRT (the WHEP work used real networks and Network Link
  Conditioner, which needs an admin password). Added: `scripts/soak/repro/lossrelay.py`, a UDP relay between
  Manifold and the listener that drops every packet, both directions, for given windows; `run.sh` gains
  `LOSS="<s after connect>:<ms> …"`, which routes the session through it. An outage longer than the
  120 ms SRT latency cannot be repaired by retransmission, so it reaches the demuxer as lost TS packets.

**Measured offline first: who declares timing** (`trace_headers` on the first second of each stream):

| sender | file | declared | rate |
|---|---|---|---|
| x265 (ffmpeg libx265, build 215) | `hevc_pq_x265`, `x265_b8_240`, and `x265_709` through MediaMTX | **SPS VUI**: 1/25, 1001/24000; VPS: none | 25.000, 23.976 |
| VideoToolbox HEVC (ffmpeg `hevc_videotoolbox`) | `hevc_pq_vt`, `vt_pq_meta`, and `vt_pq_meta` through MediaMTX | **nothing** (VUI present, `vui_timing_info_present_flag` 0; VPS 0) | — |
| x264 (ffmpeg libx264, core 165) | `syncD-23.976p-inj0`, `h264_lo` | **SPS VUI**: 1001/48000, 1/50 | 23.976, 25.000 |
| OBS 32.2.2, Apple VT H.264 | `obs-709.ts`, `obs-pq.ts` (§6.9, the OBS re-check) | **nothing** (`timing_info_present_flag` 0) | — |
| OBS → Cloudflare SRT output | `cfsrt-probe.ts` (2026-09-29; High profile, no encoder string in band) | **SPS VUI**: 1001/48000, `fixed_frame_rate_flag` 1 | 23.976 |
| OBS VideoToolbox HEVC | — | not measured unattended; predicted **nothing** (the same VT encoder) | attended / Stage 6 |

**Consequence, stated before the build: the rule as decided cannot fix the MediaMTX VideoToolbox case.** That
stream declares no timing, so it falls back to the measured 50.000 (MediaMTX's made-up DTS). Item 1a below
is therefore predicted to MISS. A sender that does declare is fixed through the same server
(`vt_tick25`, item 1d).

**Fixtures** (session scratchpad `s4/fx`): `cchange` (x265 Main 10, 10 s 709 1-1-1 / 10 s PQ 9-16-9, ×2 by
concat, 3 changes, each at an IDR); `vt_tick25` (`vt_pq_meta` with `hevc_metadata=tick_rate=25/1`, VPS +
VUI); `x265_tick50` (`hevc_pq_x265` with a wrong 50/1 written in); `hevc_soak` (the 33.4 min loop-exact
23.976 soak clip `soak33.ts`, video re-encoded x265 Main 10 PQ, keyint 48 with `scenecut=0`, the AAC copied);
`hevc_sync100` / `h264_sync100` (its first 100 s and the H.264 original's). Offline (`nals.py`): `hevc_sync100` IDR then a CRA every 45–50 AUs (~2 s), 0–3 RASL per CRA, max(pts − dts) **208.5 ms at AU 1**; `cchange` an IDR at each segment start and a CRA every 25 with 4 RASL, max(pts − dts) 240 ms.

**Builds:** HEAD `a2e5ce1` (`.build-cc/s4head-Profile`, built from the clean tree before any edit) against
the tree (`.build-cc/s4-Profile`), unsigned Profile. **Senders:** `run.sh` (listener), the running
MediaMTX's SRT (`mtxrun.sh` from Stage 3). Unattended. Defaults exported before the first launch.

| # | what | predicted | pass band |
|---|---|---|---|
| 1a | `vt_pq_meta` through MediaMTX (Robbie's item: its true rate, not 50) | **50.000**, from the measured fallback: the stream declares nothing | Robbie's band: `[SRT-FORMAT]` and the D4a mode at 25.000 / 1080p25. **Predicted MISS.** Mine: the "declares no timing" line, published 50.000, identical to Stage 3 |
| 1b | x265 on the listener (`hevc_pq_x265`, `x265_b8_240`) and through MediaMTX (`x265_709`) | declared 25.000 / 23.976 / 25.000, agreeing with measured | `[SRT-FORMAT] … declared by the stream (SPS VUI …)`; **no disagreement line**; D4a `→ mode 1080p25` / `1080p23.98`, as Stage 3 |
| 1c | H.264: `syncD` (x264, declares) and `obs-709.ts` replayed on the listener (OBS VT, declares nothing) | syncD declared 23.976; OBS falls back to measured 23.976 | both publish 23.976 as at HEAD; D4a lines identical to HEAD; OBS: one "declares no timing" line; no disagreement line on either |
| 1d | `vt_tick25` through MediaMTX | declared 25.000 (VPS + VUI), measured 50.000 | exactly **one** disagreement line naming 25.000 declared and 50.000 measured; published **25.000**; D4a `→ mode 1080p25` |
| 1e | `x265_tick50` on the listener (a sender that declares the wrong rate) | declared 50.000, measured 25.000 | one disagreement line; published 50.000 (the rule takes the declaration); playback itself unchanged (pacing is by PTS): 0 holds, 0 decode errors |
| 2 | `cchange` on the listener: 3 mid-stream colour changes on HEVC | one `[SPS-COLOR]` and one `[SCOPE-COLOR] source:` line per change; the renderer moves when the first new-colour frame is due | **4 `[SPS-COLOR]` lines** (first + 3) and **4 `source:` lines**, alternating 1-1-1 / 9-16-9; SPS read → `source:` hop **0.25–0.36 s** (§6.9 SRT: 0.263–0.300 at a 250 ms cushion; this stream's x265 reorder raises the cushion to ~290 ms); 0 decode errors, 0 RASL skipped, 0 holds, 0 out of order |
| 3 | loss: `hevc_sync100` with `LOSS="20:300 40:600 60:1000"` | each outage loses TS packets; VideoToolbox fails a damaged picture or one that references it, the gate re-closes, and decoding resumes at the next CRA with its RASL skipped | per outage: **either** a decode error followed by `keyframe acquired (CRA …)` ≤ 2.2 s of stream after the outage ends (keyint 48 at 23.976 = 2.0 s) with that CRA's RASL skipped (0–3 per CRA in this fixture, offline) and **0 decode errors after it**, **or** no error at all (VideoToolbox concealed; recorded as such, and it would mean no RASL is skipped). Audio: holes ≈ the outage (±150 ms), ≤ 1 starvation hold per outage, 0 coarse re-anchors, 0 splices abandoned; `[AV-CONTENT]` median over 15 s after each recovery **within ±2 ms** of the median before the first outage |
| 3b | the same with `vt_pq_meta`-style IDR-only stream? | — | **not run**: VideoToolbox's IDR-only streams have no RASL, and Stage 3's `mtx-looped` already shows IDR recovery |
| 4 | 30-min HEVC soak, `hevc_soak` (one AAC frame per PES), listener; measure-only calibrations at +1 / +2 / +16 / +32 min | as the H.264 soaks (Stage 0 `soak-s0`, 0b-2a v2) | every calibration **within ±2 ms**; end − start **within ±5 ms**; `[AV-LAG]` slope after 180 s **within ±1 ppm** (H.264: +0.1); **0 starvation holds**, 0 coarse re-anchors, 0 splices; `[AV-CONTENT]` median within ±2 ms; 0 decode errors; cushion **258–259 ms BEFORE the first anchor** (offline: max(pts − dts) 208.5 ms, first reached at AU 1; + 50 ms), no later raise |
| 5 | calibration, the sync clip as HEVC against H.264, same path, same day: `h264_sync100` ×2 and `hevc_sync100` ×2, alternating, each measure-only at +60 s | the same figure | **mean of the HEVC pair within ±2 ms of the mean of the H.264 pair** |
| 6 | Cloudflare | **No.** Cloudflare's Stream Live docs name H.264 + AAC as the only ingest codecs (RTMPS and SRT) | attended: OBS VT HEVC Main 10 P010 Rec. 2100 PQ to the Cloudflare SRT ingest. If Cloudflare refuses or never outputs it, recorded plainly, no workaround. If it plays, one session with a calibration |
| 7 | regression: syncD and hi8, HEAD against the tree | unchanged | `[SRT] container` / `stream` / `video:` / `colorimetry` / `decoded as`, `[SRT-AUDIO] stream`, `[SPS-COLOR]`, `[SRT-BUFFER]` **identical text**; the `[SRT-FORMAT]` lines differ on purpose (wording) and publish the same rate; syncD 0 holds, `[AV-CONTENT]` within ±2 ms of HEAD's same-day run |
| 8 | gates | — | `swift test` all pass (266 + the new timing tests, field by field against `trace_headers`, plus truncation); `soaklog.test.mjs` 8 / 8; C harness 200 / 200; Profile build with the same warning set as HEAD |

**Attended afterwards, one step at a time:** DeckLink Follow source (Stage 3's item 6), then Cloudflare.
**What this stage could invalidate:** nothing measured on H.264 except the `[SRT-FORMAT]` wording; the
published rate changes only where a stream's declaration disagrees with the demuxer's measurement.

#### Stage 4 — results, 2026-10-09 (unattended)

**As built, two changes from the plan above.**
- **H.264 timing is read by the reader WHEP already had,** `ManifoldH264ParseSPSTiming`
  (`App/H264/H264SPSTiming.c`, behind WHEP's Follow source since 0.6). It was found after the first build.
  The first build carried a Swift H.264 reader beside it, a duplicate, and it was removed. `SPSTiming`
  in the `SPSColor` target is HEVC only: `HEVCSPSColor.timing(nal:)` (SPS VUI) and `vpsTiming(nal:)`. The
  rule is WHEP's rule. Only the threshold differs: 0.05 % here against WHEP's 2 %, because WHEP's
  measurement is an estimate with a 2 % spread gate, and SRT's is libavformat's exact rational.
- **Builds:** HEAD `.build-cc/s4head-Profile`; the first tree build `.build-cc/s4-Profile` (Swift H.264
  reader), which ran every item below; the final tree `.build-cc/s4b-Profile` (the C reader for H.264),
  on which the H.264 rate runs were repeated (*the final build*, below). The HEVC path is the same code
  in both. All unsigned Profile, 11 warnings each, the same set as HEAD.
- **Logs:** `~/Desktop/manifold-soak/s4/` (`repro/` listener, `mtx/` MediaMTX). Scripts and fixtures:
  the session scratchpad `s4/`.

**Who declares timing: the table above stands as measured** (x265 SPS VUI only; VideoToolbox HEVC
nothing; x264 SPS VUI; OBS 32.2.2's Apple VT H.264 nothing; OBS through Cloudflare's SRT output SPS VUI,
`fixed_frame_rate_flag` 1). OBS's VideoToolbox HEVC is still unmeasured.

| # | result | verdict |
|---|---|---|
| 1a | `vt_pq_meta` through MediaMTX: `[SRT-FORMAT] frame rate 50.000 fps measured …`, then `the stream's SPS/VPS gives no frame rate — it declares no timing; publishing 50.000 fps measured`; D4a `→ mode 1080p50` | **MISS on Robbie's band, as predicted.** The decided rule cannot fix a stream that declares nothing. Mine: PASS |
| 1b | x265 listener: `hevc_pq_x265` declared **25.000** (`SPS VUI num_units_in_tick=1 time_scale=25`), `x265_b8_240` **23.976** (1001/24000); through MediaMTX `x265_709` **25.000**, against a measured 25.000 (MediaMTX does not rewrite DTS on a stream with B-frames). No disagreement line. D4a `1080p25` / `1080p23.98` / `1080p25` | **PASS** |
| 1c | `syncD` (x264): declared 23.976 (1001/48000, `fixed_frame_rate_flag=0`), measured 23.976. `obs-709.ts` (OBS VT H.264): `the stream's SPS gives no frame rate — it declares no timing; publishing 23.976 fps measured`. D4a lines **identical to HEAD** on both, and on hi8 (x264, 1/50 → 25.000) | **PASS** |
| 1d | `vt_tick25` through MediaMTX: measured **50.000**, `declared 25.000 fps (SPS VUI num_units_in_tick=1 time_scale=25)`, **one** line `declared 25.000 fps and measured 50.000 fps disagree — using the declared rate`; D4a `→ mode 1080p25` | **PASS** |
| 1e | `x265_tick50` on the listener: declared 50.000, measured 25.000, one disagreement line; published 50.000 (D4a `1080p50`); 0 holds, 0 decode errors | **PASS** (the rule takes the declaration, even a wrong one) |
| 2 | `cchange`: **4 `[SPS-COLOR]` and 4 `[SCOPE-COLOR] source:` lines**, alternating 1-1-1 / 9-16-9; each new SPS a new format description that the session accepted (`kept`); 0 decode errors, 0 RASL skipped (each change is at an IDR), 0 holds. **Hops 0.342 / 0.320 / 0.236 s** | **PASS on the lines; MISS on the hop band** (0.25–0.36), by 14 ms low on the third. The band assumed a fixed 290 ms queue. This fixture's video arrives in bursts, so LiveClock spent the session on its ±0.5 % rail and the video queue swung **0.236–0.444 s**. Each hop equals the queue depth at that change (about 0.36, 0.35, 0.24 s from the 1 Hz `[LIVECLOCK]` lines). The renderer switches when the first new-colour frame is due, as designed. The 0.25–0.30 s figure of §6.9 was a quiet-queue figure |
| 3 | `hevc_sync100`, outages 313 / 613 / 1014 ms (relay: 22 / 95 / 127 packets dropped towards Manifold), run twice (`loss`, `loss2`), H.264 control on the H.264 clip (`loss-h264`). See *loss*, below | **Video PASS** (both runs). **Audio: the ±2 ms band FAILS, and is the wrong test.** See below |
| 7 | syncD 9 / 9, hi8 11 / 11 and `obs-709` 9 / 9 lines **identical text** HEAD against the tree; syncD `[AV-CONTENT]` median **−0.13 (HEAD) / −0.12 ms (tree)**, 0 holds each; hi8 336 before the anchor on both; D4a identical | **PASS** |

##### Loss (item 3)

**The harness is a finding in itself: below about 0.6 s, an outage is not loss on SRT.** The 313 and
613 ms outages lost nothing. Every AU and every AAC frame arrived after the outage: libsrt's sender kept
them and resent them, and the receiver had nothing later to skip them for. They reach Manifold as
delivery stalls. Only the 1014 ms outage lost data on HEVC: 5 video AUs (2394 received of 2399) and
4 AAC frames (`input axis HOLE 85.33 ms`). On the H.264 clip (428 kb/s against the HEVC clip's 910),
even the 1 s outage was recovered in full: 2394 / 2394 AUs, 0 holes.

**Video, both HEVC runs identical:** the stalls cost nothing but the hold. After the 1 s outage:
`decode failed (-12909) — dropping to next keyframe` → `keyframe acquired (CRA, NAL 21) … its RASL
pictures will be skipped` 3 ms later in arrival time (the backlog after the outage arrives at once, so
the next CRA was already in hand) → session totals `dropped awaiting keyframe=8, RASL skipped=1, decode
errors=1`. **One decode error, none after the CRA.** 2384 pictures from 2394 AUs.

**Audio: one starvation hold per outage, each closed by one catch-up write, on both codecs.**

| run | holds (held ms) | catch-up debt, ms | `[AV-CONTENT]` median, before the 1st outage / 15 s after each |
|---|---|---|---|
| `loss` (HEVC) | 3 (220, 410, 943) | 190, 410, 911, each `RECOVERED` | **+24.21** / −13.93 / +6.41 / −2.01 |
| `loss2` (HEVC) | 3 | 187, 415, 785 | **+26.67** / −11.35 / +7.63 / −3.28 |
| `loss-h264` | 3 | 65 (a whole-debt recovery drop), 253, 672 | +0.87 / −1.27 / +5.27 / +2.79 |

0 coarse re-anchors, 0 splices abandoned, in all three. **The HEVC audio was 24–27 ms off BEFORE any
outage**, so the band cannot isolate what loss does. That offset is not loss (next section). What the
outages share across codecs: after the 613 ms stall both codecs sit ~5–8 ms late for the next 15 s.
That is the catch-up's known residue (BUGS.md, *after a starvation hold of ≥ 1 s, 10–20 ms of the debt
is folded*). It is not HEVC's.

##### Found: on a stream with B-frames, LiveClock starts on its rail and the audio runs ~25 ms off for ~30 s

Every session of the HEVC sync clip, with no loss at all, reads `[AV-CONTENT]` **+23 to +31 ms for the
first ~20 s**, +8 to +10 ms at 23–40 s, and **−1 to −3 ms at 40–80 s**. The H.264 sync clip reads
within ±1 ms throughout (`cal-*` runs, 10 to 20 s windows).

- **The clock runs slow to refill a queue it reads as short.** LiveClock starts at depth 0.298 s,
  target 0.259, and within a second reads 0.17–0.24 s (err −40 to −90 ms). It sits at its −0.5 % rail
  for ~25–30 s (`[LIVECLOCK] publication starved … RAILED`; `[SRT-RESAMPLE] RATIO AT ITS RAIL — ρ−1
  −2000 ppm`). The audio may follow at only ±0.2 %, so it ends up ahead of the picture until the clock
  comes off the rail. This is the rail drain of 0b-1, in the other direction.
- **The depth reads are noisy by about a B-frame.** HEVC's 1 Hz depth samples scatter ±40 ms around the
  target. H.264 baseline's scatter ±12 ms.
- **Hypothesis, not yet tested:** the depth is sampled on the most recently DECODED picture. On a
  reordered stream that is often a B-frame up to 2–3 frames older in presentation order than the newest
  picture queued. So the queue reads short, by up to the stream's typical reorder (median pts − dts here
  is 83 ms).
- **The control: it is the B-frames, not HEVC.** H.264 High with B-frames (`h264b_160`: the same clip,
  x264 `-bf 3`, timestamps kept, and the same reorder shape as the HEVC clip: max 208.5 ms at AU 1,
  median 83.4 ms) does the same. Its first-second depth minimum is 0.175 s, its sd ~30 ms, and it shows
  the rail lines. The baseline clip has none of this (0.241 s, 6 ms, no rail).

| run | `[AV-CONTENT]` median, ms: 3–20 s | 20–40 | 40–60 | 60–90 | 90–150 |
|---|---|---|---|---|---|
| H.264 baseline ×2 | +0.89 / +1.03 | +0.13 / −0.07 | −0.34 / −0.32 | +0.08 / −0.14 | −0.03 / −0.04 |
| **H.264 + B-frames ×2** | **+35.97 / +37.55** | +16.73 / +18.01 | −1.51 / −1.94 | −2.40 / −2.41 | −0.42 / −0.43 |
| **HEVC ×2** | **−35.36 / −36.63** | −19.82 / −22.41 | +1.75 / +0.63 | +3.06 / +3.29 | +0.93 / +0.73 |
| HEVC soak | +32.05 | +12.33 | −3.09 | −1.50 (60–120) | +0.11 (after 60 s, whole soak) |

- **Its sign varies by session** (+32 in the soak, −35 in `cal2-hevc` on the same fixture), and so
  does the rail direction. Its size does not: ~35 ms for the first 20 s, ~20 at 20–40 s, ≤ 3 ms by 60 s,
  < 1 ms by 90 s. No hold, splice or coarse event marks it, and the calibration's advance budget reads
  0.0 ms meanwhile (`NOT APPLICABLE: … at most 0.0 ms available` at +1 and +16 min in the soak).
- **Pre-existing, and not Stage 4's to fix.** It applies to any B-frame stream on SRT: x264 with
  B-frames, OBS x264 (as far as its default profile uses them), and x265. The SRT H.264 measurements
  until now used Constrained Baseline or Apple VT H.264 (Main, no B-frames), which is why no earlier
  stage saw it. Stage 3's x265 runs were not looked at below +120 s. Recorded in BUGS.md. The hypothesis
  above (the depth sampled on the newest decoded picture, not the newest presentation time queued) is
  the place to start.

##### Items 4 and 5, and the fixture I got wrong first

**My first HEVC sync fixture was 20.38 ms off, and item 5's first run measured my fixture.** `gen.sh`
re-encoded `soak33.ts` without `-copyts`, so ffmpeg re-based each stream separately. The video now
started **41.711 ms** after the audio, where the source's video starts **21.333 ms** after it: the picture
had moved **20.38 ms later** in the content. The first alternating calibrations read H.264 **−0.35 /
−1.27 ms** and HEVC **−20.07 / −17.29 ms**, which is that shift plus the startup episode above. Every
later HEVC sync run uses `hevc_soak2.ts`: `-copyts -enc_time_base:v demux -fps_mode passthrough
-muxdelay 0 -muxpreload 0`, the first video PTS 127920 as in the source, the same start offsets. The
first `loss` / `loss2` runs used the shifted fixture. The video verdict and the clock-side
`[AV-CONTENT]` figures do not depend on content alignment: `[AV-CONTENT]` read −0.35 on the shifted HEVC
fixture against +0.16 on H.264, run for run.

| # | result | verdict |
|---|---|---|
| 4 | `hevc_soak2`, 33.4 min, listener, one AAC frame per PES: cushion **250 → 259 ms BEFORE the first anchor** (208.5 ms reorder + 50); calibrations at +1 / +2 / +16 / +32 min **+1.36 / −0.41 / +1.34 / +1.59 ms**, end − start **+0.23 ms**; `[AV-LAG]` slope after 180 s **+0.2 ppm** (audio−now +0.1); **0 starvation holds**, 0 coarse, 0 splices; `[AV-CONTENT]` audio−now median after 60 s **+0.11 ms** (p10 −1.84, p90 +2.04); **47 998 / 47 998 pictures, 0 decode errors**, 0 RASL skipped; one rail episode, 16.2 s at the start (the B-frame episode) | **PASS**, every band |
| 5 | Re-run on timestamp-exact 160 s cuts (`h264_160`, `h264b_160`, `hevc_160`), alternating ×2, measure-only at +60 and +120 s. **+60 s:** H.264 −0.30 / −0.39 (mean −0.35); H.264 + B **+1.86 / +1.96** (mean +1.91); HEVC **−3.59 / −2.16** (mean −2.88). **+120 s:** H.264 −0.65 / −0.14 (−0.40); H.264 + B −0.76 / −1.04 (−0.90); HEVC −1.18 / −0.82 (**−1.00**). The soak, same path: +1.36 at +60 s, −0.41 at +120 s | **+60 s: MISS by 0.5 ms** (HEVC − H.264 = −2.53 ms; band ±2). H.264 with B-frames misses the same way on the other side (+2.26), so the residue is the B-frame startup episode, not HEVC. **+120 s: HEVC within 0.60 ms of H.264**, and within 0.10 ms of H.264 + B |
| 8 | Final tree: `swift test` **273 / 273** (266 + 7 HEVC timing tests); `soaklog.test.mjs` 8 / 8; C harness 200 / 200; Profile build, 11 warnings, the same set as HEAD. **The timing tests were shown to fail:** with `neutral_chroma_indication_flag` removed from the HEVC walk, the sender and truncation tests fail (the run then trapped on a force-unwrap, since replaced by `XCTUnwrap`); the tree's reader was restored and re-run green | **PASS** |
| 6 | Cloudflare | **not run** (attended) |

**Item 5's 2.53 ms was a miss on the band as written.** It was read at +60 s, where the band put it.
**Decided (Robbie, 2026-10-09): +120 s is item 5's comparison point** (HEVC within 0.60 ms: **PASS**). The
B-frame start-up episode is a pre-release fix of its own, right after Stage 4 is committed (BUGS.md).

#### Stage 4 — decisions after the unattended report (Robbie, 2026-10-09)

1. **The fallback measurement changes:** with no declared timing, the rate comes from presentation
   timestamps (e.g. the median interval of displayed pictures), not decode timestamps. Declared timing
   still wins. Re-run 1a (MediaMTX VideoToolbox HEVC should read 25); declaring senders and H.264 unchanged.
2. **Item 5 at +120 s; the B-frame start-up offset is a pre-release fix**, its own item after Stage 4.
3. **SRT shows the DeckLink menu warning** when declared and measured disagree, as WHEP does.

1 and 3 after the attended steps.

#### Stage 4 — attended, 2026-10-09 20:41–20:46 (Robbie)

**Step 1, DeckLink Follow source (Stage 3's item 6): PASS, on the card.** `.build-cc/s4b-Profile`, `x265_r240`
(25p) on the listener; log `~/Desktop/manifold-soak/s4/att/repro/follow.manifold.log`. Source-derived mode
`1080p25` while the saved manual pick (`1080p23.98`) held. Robbie picked the 1080p25 row on the way
(`operator picked output mode 1080p25`), turned output on — `StartScheduledPlayback … free-running at
1080p25`, 0 late, 0 dropped — then **Follow source (1080p25)**: `operator cleared the manual pick —
following the source again (1080p25)` · `mode stays 1080p25 via follow source`. The stream ended before
the re-pick of 1080p23.98 reached the app, so Follow source had cleared the key; after quit it was written
back with the snapshot's value (read first: absent; snapshot `1080p23.98`), and one run-added `NSWindow
Frame` key deleted. The domain is dictionary-equal to the original snapshot (1 141 keys).

**Step 2, Cloudflare (item 6): NO. Cloudflare's SRT ingest does not carry HEVC.** Recorded plainly; no
workaround. OBS 32.2.2, a duplicate of the "SRT Cloudflare" profile with P010, Rec. 2100 (PQ), Limited,
Apple VT HEVC Hardware Encoder, Main 10, keyframe 2 s, 23.976. OBS reported connected at first, while
the Cloudflare dashboard showed the input **connecting and disconnecting repeatedly**. Then OBS did the
same, then **errored and would not reconnect**. This matches Cloudflare's Stream Live documentation: H.264
and AAC are the only ingest codecs, for RTMPS and SRT alike. Manifold never dialled: the bookmark's
passphrase read ended `OSStatus -128` when the app was quit with the keychain prompt open. So nothing was
measured on the output side, and no calibration was possible. Log `s4/att/cf-hevc.manifold.log`. Defaults
after: one run-added `NSWindow Frame` key deleted, dictionary-equal to the snapshot. **For Stage 6 and the
user guide: HEVC over SRT needs a server that carries it (MediaMTX, a local listener); Cloudflare Stream
Live does not.**

#### Stage 4 — decisions 1 and 3: predictions, written 2026-10-09 before the build

**What changes** (`SRTFrameRouter`): `av_guess_frame_rate` is no longer published; it stays in the startup
anchor's gap threshold only, and is logged as the demuxer's guess. **Published = declared, else measured
from presentation timestamps, else nil.** The measurement (`SRTPresentationRate`) takes the first 96 decoded
pictures, sorts them into presentation order, and measures intervals ÷ span over the gaps that sit on one
grid (WHEP's span method); it refuses when fewer than 75 % do. Until it settles (~4 s at 24p), a stream that
declares nothing publishes no rate, as WHEP does. When declared and measured disagree by more than 0.05 %:
one `[SRT-FORMAT] ⚠️` line and **the DeckLink menu advisory, WHEP's wording** ("Source declares … but is
sending … — output follows the declared rate."), cleared at `deactivate` and by DeckLink when the source goes.

| # | what | predicted | pass band |
|---|---|---|---|
| D1 | 1a again: `vt_pq_meta` through MediaMTX | measured from PTS **25.000** after 96 pictures | `measured from presentation timestamps` 25.000 ± 0.01; D4a `→ mode 1080p25`; **never 1080p50**; no rate published before the measurement (the D4a line waits ~4 s) |
| D2 | `vt_tick25` through MediaMTX | declared 25, measured 25 | **no disagreement line now** (Stage 4's line was MediaMTX's DTS, not the sender); D4a 1080p25 |
| D3 | declaring senders: `hevc_pq_x265`, `x265_b8_240` (listener), `x265_709` (MediaMTX), syncD, hi8 | declared, published at once as before; the measurement agrees | `[SRT-FORMAT] … declared` and D4a lines **identical to the first Stage 4 build**; a `measured from presentation timestamps` line within 0.05 % of the declaration; no disagreement; syncD / hi8 identical-text set as HEAD |
| D4 | H.264 that declares nothing: `obs-709.ts` | 23.976 measured, published ~4 s later than at HEAD | measured 23.976 ± 0.01; D4a ends at `1080p23.98` as HEAD; **the one change on H.264: the rate arrives after the measurement, not at the first picture** |
| D5 | `x265_tick50` (declares 50, sends 25) | disagreement | exactly one `⚠️ declared 50.000 fps and measured 25.000 fps` line; published 50 (declared wins). The advisory itself is UI: dispatched in the same branch; seen in the DeckLink menu only attended |
| D6 | the Cloudflare grid: the first 60 s of `cfsrt-probe.ts` (Cloudflare's SRT output, PTS on a 1 ms grid, declares 1001/48000) | measured within 0.05 % of 23.976 | **no false disagreement**; measured 23.976 ± 0.012 |
| D7 | gates | — | `swift test` 273 / 273; soaklog 8 / 8; C harness 200 / 200; Profile build, the same 11 warnings |

#### Stage 4 — decisions 1 and 3: results, 2026-10-09 21:00–21:40 (unattended)

**Builds:** `.build-cc/s4c-Profile` (the first build), then `.build-cc/s4d-Profile`, the final tree, after
D6 failed on s4c. 11 warnings each, the same set as HEAD. **Logs:** `~/Desktop/manifold-soak/s4/dec/` (s4c)
and `s4/dec2/` (s4d).

**D6 failed on the first build, and the fix is in the final one.** On Cloudflare's output the measurement
REFUSED: `only 61 of 95 intervals on one grid (median 42.00 ms) — not one cadence`. Cloudflare stamps
video on a 1 ms grid, so a 23.976 stream's gaps are 41, 42 and 43 ms. That is 2.4 % off the median, and
the grid-fit band had WHEP's 2 % (right for 90 kHz RTP ticks, wrong for a 1 ms grid). A Cloudflare stream
that declared nothing would have published no rate. The band is now ±15 % of an interval: it covers a
1 ms grid to ~100 fps and stays far from the midpoint between multiples. The precision comes from the
~4 s span (±1 ms is ~0.025 %), not from the band.

**And the 12 s MediaMTX fixtures were too short for the measurement.** `mtxrun.sh` joins ~9 s into the
publish, so the s4c MediaMTX runs saw 45–65 pictures, short of the 96 the window needs. They measured
nothing, and the VT stream published no rate. That is correct behaviour on too little stream, but it
tests nothing. The final build's MediaMTX runs use 60 s fixtures: `vt60` (VideoToolbox, the recipe of
`vt_pq_meta`, declares nothing), `vt60_tick25` (+ `hevc_metadata=tick_rate=25/1`, VPS and VUI), and Stage 3's
`x265_join` (60 s, declares 25).

| # | result (final build unless stated) | verdict |
|---|---|---|
| D1 | `vt60` through MediaMTX: demuxer's guess 50.000 (logged, `startup anchor only`); `declares no timing; the rate will be measured …`; **`frame rate 25.000 fps measured from presentation timestamps (96 pictures …, median interval 40.000 ms, 95 of 95 intervals on the grid)`**; D4a **`→ mode 1080p25`**, the first and only D4a format line; no 1080p50 anywhere but the demuxer's own `[SRT] video:` report | **PASS: 1a now reads 25** |
| D2 | `vt60_tick25` through MediaMTX: declared 25.000, measured 25.000, **no disagreement line** | **PASS** |
| D3 | declared and measured agree, no disagreement, D4a as before: `hevc_pq_x265` 25/25, `hi8` 25/25, `x265_join` (MediaMTX) 25/25 on the final build; `x265_b8_240` 23.976/23.976 and syncD 23.976/23.976 on s4c (the measurement on 90 kHz timestamps is the same on both builds: 95 of 95 on the grid) | **PASS** |
| D4 | `obs-709.ts` (OBS VT H.264, declares nothing): measured **23.976** (median 41.711 ms, 95 of 95); D4a `1080p23.98`, as HEAD. **The rate now arrives after 96 pictures (~4 s), not with the first picture**, the one change on H.264 | **PASS**, with that change |
| D5 | `x265_tick50`: declared 50.000, measured 25.000, exactly one `⚠️ declared 50.000 fps and measured 25.000 fps (presentation timestamps) disagree — using the declared rate`; D4a `1080p50` | **PASS** on the log. The menu advisory is dispatched in the same branch; **not yet seen in the menu** (attended) |
| D6 | `cf60` (Cloudflare's output, 1 ms grid, declares 1001/48000): **measured 23.976, 95 of 95 on the grid, no disagreement** (s4c: refused, above) | **PASS on the final build** |
| D7 | `swift test` 273 / 273; soaklog 8 / 8; C harness 200 / 200; Profile build, 11 warnings, the same set as HEAD | **PASS** |

0 starvation holds in every run. **Defaults:** 18 run-added `NSWindow Frame` keys, each absent from the
snapshot, deleted by name; dictionary-equal to the snapshot (1 141 keys).

#### OBS profiles: what the attended sessions actually sent, and a change of plan (2026-10-09)

**Audit.** Read-only, from OBS's logs and profile files, against what Manifold received. The profile
table is `docs/OBS_TEST_PROFILES.md`.
- **Every attended session in §6.10 received what its step said it sent:** 1920×1080 23.976, Rec. 709
  1-1-1 limited, AAC-LC 48 kHz stereo, one AAC frame per PES, the SYNC scene.
- **The encoders differed.**
  - **Local OBS sessions** (SRT Local: 0b-2a, 0b-2a v2): Apple VT H.264 **Main**, B-frames off,
    **0 ms** reorder.
  - **Every Cloudflare SRT session** (Stage 0 item 6; 0b-2a `cf-1`; 0b-2b `cf-1`): OBS **x264 veryfast**,
    CBR 6000, keyframe 1 s, no x264 options. That is x264's default **3 B-frames with a pyramid**. Manifold
    received H.264 **High**, reordering up to **0.208 s**.
- **The 0.208 s is real reordering, not an offset.** In Cloudflare's recorded output (`cfsrt-probe.ts`,
  same profile): pts − dts takes 0 / 41 / 83 / 125 / 166 / 208 ms; 1 259 of 2 880 pictures carry a PTS
  earlier than the picture before them in decode order; B-slices are present;
  `max_num_reorder_frames` is 2.

**Corrections to this section.**
- Wherever §6.10 calls the 0.208 s reorder **Cloudflare's** (the buffer review's inventory, its
  margins table, 0b-2b's prediction), it is **OBS x264's B-frames, passed through Cloudflare**.
- 0b-2a's "local OBS with real programme audio" was the **sync clip** (scene SYNC). The packing figure
  stands: it comes from OBS's audio encoder, not the content.

**Change of plan (Robbie, 2026-10-09): the SRT Cloudflare profile is unified with the others.** Apple VT
H.264 Hardware, CBR 6000, keyframe 1 s, Main, B-frames off, AAC.
- **Cloudflare SRT sessions before 2026-10-09 used x264 veryfast with B-frames (0.208 s reorder).**
  Cloudflare figures from now on are **not directly comparable** with them: reorder, cushion (259 ms),
  start-up, and calibrations inside the first minute (the B-frame start-up episode in BUGS.md).
- **B-frame coverage comes from the ffmpeg fixtures from now on:** `x265_*`, `h264b_160`, `hevc_160`,
  `b*pyr`.
- **Verified in OBS's files at ~22:00:** the profile holds those settings except the bitrate, which is not
  stored (OBS's default applies: CBR 6000 by the evidence in `OBS_TEST_PROFILES.md`, flag 2). Not yet
  streamed with them.
- **HEVC SRT created** (Robbie, 2026-10-09 21:53) for Stage 6: Apple VT HEVC Main 10, 12000, keyframe 1 s,
  B-frames off, P010 / Rec. 2100 (PQ) / Limited, SDR white 203, peak 1000, 23.976, publishing to the
  local MediaMTX. Verified ~22:00; not yet run.
- The HEVC attempt earlier that evening was made in this profile itself and had left it on Apple VT
  HEVC. **The rule from now on:** never modify a tested profile for an experiment; duplicate it
  (`OBS_TEST_PROFILES.md`, which also proposes "HEVC Local" for Stage 6).

#### Stage 4, decision 3 attended, and the disagreement rule reversed: predictions, written 2026-10-09 before the code changed

**Attended (Robbie, 2026-10-09 ~22:04): the DeckLink menu warning, seen.** `.build-cc/s4d-Profile`,
`join_tick50` (x265 60 s, 25 fps sent, `tick_rate=50/1` declared) on the listener; log
`s4/att/repro/advisory.manifold.log`. The menu showed the row **"Follow source (1080p50)"** and at the
bottom **"⚠️ Source declares 50.000 fps but is sending 25.000 fps — output follows the declared rate."**
The signal line read the saved manual pick, `1080p23.98 · 10-bit 4:2:2 · Rec. 709`. **D5's advisory:
PASS**, seen in the UI.

**Decided (Robbie, 2026-10-09): measured wins when declared and measured clearly disagree** (beyond
0.05 %), switching once when the measurement settles. Declared stays the fallback when the measurement
refuses (an irregular cadence). The warning says the output follows the measured rate. Why: under
declared-wins, a stream that says 50 and carries 25 goes to SDI as 1080p50 with every picture twice;
measured-wins puts the cadence actually on the wire on SDI. Its cost: one mode switch at start on a
mislabelled stream. The untested pulldown case (23.976 coded, 29.97 declared) is in BUGS.md.

**What changes:** `settlePublishedRate` publishes the measured rate when the two disagree; the log line
and the advisory say "measured". Before the measurement settles, the declared rate is published, so the
first D4a format is the declared one.

**Fixtures** (x264, 60 s, testsrc2 + 1 kHz AAC; the declarations rewritten with `h264_metadata`): `d5994_s2997`
(29.97 sent, 59.94 declared), `d60_s30` (30 sent, 60 declared), `i5994_frame` (1080i59.94, MBAFF top
field first, x264's own timing: 60000/1001 ticks = **29.97 frames declared**), `i5994_field` (the same
stream, the field rate labelled as the frame rate: **59.94 declared**). Offline, every one sends a
picture every 3003 (3000) ticks. Interlaced is coded as frames here, two fields per access unit.

**The DeckLink mode table has no interlaced modes** (`resolveOutputMode` maps a rate to the nearest
progressive mode), so 1080i59.94, the correct output for the interlaced pair, is not reachable under any
rule.

| # | stream | predicted Follow source (D4a source-derived mode) | pass band |
|---|---|---|---|
| R1 | `join_tick50` (50 declared, 25 sent) | **1080p50** at the first picture, then **1080p25** once the measurement settles (~4 s, plus the 2 s live-mode settle) | exactly one disagreement line saying the measured rate is used; D4a: one `1080p50` then one `1080p25`, no other mode |
| R2 | `d5994_s2997` | 1080p59.94 → **1080p29.97** | as R1 |
| R3 | `d60_s30` | 1080p60 → **1080p30** | as R1 |
| R4 | `i5994_frame` | **1080p29.97** throughout (agree) | no disagreement; **MISS against the correct 1080i59.94, by construction** |
| R5 | `i5994_field` | 1080p59.94 → **1080p29.97** | one disagreement; **MISS against 1080i59.94**, by construction |
| R6 | regression: `hevc_pq_x265`, `hi8`, `cf60`, syncD (declare and agree); `obs-709` (declares nothing); `vt60` and `vt60_tick25` through MediaMTX | unchanged from the final build of decisions 1 and 3 | the same `[SRT-FORMAT]` and D4a lines; no disagreement |
| R7 | gates | — | `swift test` 273 / 273; soaklog 8 / 8; C harness 200 / 200; Profile build with the same 11 warnings |

#### The disagreement rule reversed: results, 2026-10-09 22:09–22:40 (unattended)

**Build:** `.build-cc/s4e-Profile` (measured wins a clear disagreement), 11 warnings, the same set as HEAD.
**Logs:** `~/Desktop/manifold-soak/s4/rev/`. The saved manual pick (1080p23.98) was in force and DeckLink output
was OFF throughout. So the D4a "LIVE source format → mode" lines are the mode Follow source offers and would
apply, and the card itself did not change.

| # | stream | declared → measured | Follow source (D4a) | verdict |
|---|---|---|---|---|
| R1 | `join_tick50` | 50.000 → 25.000 | **1080p50** at the first picture, then `1080p25; holding 2.0s` → `live mode 1080p25 settled` | **PASS**: one disagreement line (`— using the measured rate`), one switch |
| R2 | `d5994_s2997` | 59.940 → 29.970 | 1080p59.94 → **1080p29.97** (settled) | **PASS** |
| R3 | `d60_s30` | 60.000 → 30.000 | 1080p60 → **1080p30** (settled) | **PASS** |
| R4 | `i5994_frame` (1080i59.94, MBAFF, 29.97 frames declared) | 29.970 → 29.970, agree | **1080p29.97** throughout | as predicted; **MISS against the correct 1080i59.94**, by construction: no interlaced modes (BUGS.md) |
| R5 | `i5994_field` (the same stream, 59.94 declared) | 59.940 → 29.970 | 1080p59.94 → **1080p29.97** (settled) | as predicted; **MISS against 1080i59.94** (BUGS.md) |
| R6 | `hevc_pq_x265` 25/25, `hi8` 25/25, `cf60` 23.976/23.976, syncD 23.976/23.976; `obs-709` (measured 23.976); `vt60` (MediaMTX, measured 25.000); `vt60_tick25` 25/25 | unchanged | D4a as on the decisions 1 and 3 build: 1080p25 / 1080p25 / 1080p23.98 / 1080p23.98 / 1080p23.98 / 1080p25 / 1080p25 | **PASS**: no disagreement anywhere, 0 holds in every run |
| R7 | `swift test` 273 / 273; soaklog 8 / 8; C harness 200 / 200; Profile build, the same 11 warnings | | | **PASS** |

- **Every 2× case lands on the measured rate after one settled switch.** Every R run decoded with 0 holds
  and 0 decode errors.
- **The menu text is now "output follows the measured rate."** The log line says the same; it was not
  re-read in the UI.
- **New in BUGS.md:** interlaced live sources reach DeckLink as progressive (1080p29.97 for 1080i59.94).
  The pulldown case (23.976 coded, 29.97 declared) is untested.
- **Defaults:** 13 run-added `NSWindow Frame` keys (this run and the advisory session), each absent from the
  snapshot, deleted by name; dictionary-equal to the snapshot (1 141 keys; `manualOutputMode` `1080p23.98`).

##### The final build

The H.264 path moved to `ManifoldH264ParseSPSTiming` after the runs above, so it was built again
(`.build-cc/s4b-Profile`) and the rate runs were repeated: `b-syncD`, `b-hi8`, `b-obs709` (listener),
`b-pq`, and `b-vtmeta` / `b-vttick25` (MediaMTX). Every `[SRT-FORMAT]` and D4a line reads as on the first
build, word for word (the C reader gives the same three fields the Swift one did). syncD, hi8 and
`obs-709` match HEAD's lines exactly (9 / 9, 11 / 11, 9 / 9). syncD `[AV-CONTENT]` **−0.08 ms**. 0 holds in all six.

##### Defaults

Exported before the first launch (1 141 keys; `manifold.decklink.manualOutputMode` `1080p23.98`). After
the last quit: 33 run-added `NSWindow Frame` keys and nothing else. Each was checked absent from the
snapshot and deleted by name. The domain is dictionary-equal to the snapshot (1 141 keys).
`streamBookmarks` was never read or written.

**Stage 4, unattended:**
- **Met:** items 1b–1e, 4 and 7–8, and item 3's video half.
- **Missed as predicted:** item 1a. The MediaMTX VideoToolbox stream declares no timing, so the decided
  rule keeps the measured 50.
- **Missed:** item 2's hop band, which was the wrong model; item 3's audio band, where pre-existing
  effects swamp what it measures; item 5 at +60 s, by 0.5 ms. HEVC is within 0.6 ms of H.264 at +120 s.
- **Found:** the B-frame startup episode, for H.264 and HEVC alike.
- **Attended:** Follow source, then Cloudflare.

#### The B-frame start-up offset (pre-release fix): step 1, the cause — 2026-10-10 (unattended; no code changed)

**Verdict.**
- **The cause is found and confirmed.** It is not the one hypothesised in BUGS.md. The depth is not
  sampled on the newest decoded picture: the renderer reads the newest PRESENTATION time in its
  PTS-sorted queue.
- **The cause is how the clock is STARTED on a reordered stream.** It anchors on one decoded picture.
  It then regulates the mean of a depth signal whose sawtooth is a mini-GOP wide, not one frame.
- **The fix is not contained to how the clock or steering reads depth.** The model below shows that a
  depth-reading change alone halves the error on one kind of start and doubles it on the other.
- **Stopped after step 1, as the brief says.** No step-2 predictions were written and no code was
  changed.

**Builds and runs.**
- **Build:** HEAD `0ab5684` (`.build-cc/bfhead-Profile`), unsigned Profile, the same 11 warnings as Stage 4.
- **Runs:** one 240 s run per fixture on the listener (`run.sh`, one AAC frame per PES), unattended.
- **Logs:** `~/Desktop/manifold-soak/bf/repro/head-*`.
- **Fixtures, scripts and the analyser (`an.py`):** the session scratchpad `bf/`.

**Fixtures.**
- **Source:** the loop-exact 23.976 sync clip `soak33.ts`, first 240 s.
- **Timestamps kept:** `-copyts -enc_time_base:v demux -fps_mode passthrough -muxdelay 0
  -muxpreload 0`, the `hevc_soak2` recipe, so `[AV-CONTENT]` reads on every run.
- **Encoding:** keyint 48, `scenecut=0`, AAC copied.
- **Timestamps measured offline:** `framecrc`, decode order, 90 kHz.

| fixture | encoder | max(pts − dts) | the newest PTS advances | in steps of (median / mean) |
|---|---|---|---|---|
| `ctl_240` (control) | the source, copied (no B-frames) | 0 | every picture | 41.7 / 41.7 ms |
| `h264_b3p_240` | x264 `bframes=3:b-pyramid=normal` | 208.5 ms | every 3.7 pictures | 166.8 / 154.0 ms |
| `hevc_b3p_240` | x265 Main 10 `bframes=3:b-pyramid=1` | 208.5 ms | every 3.8 pictures | 166.8 / 158.8 ms |
| `h264_b8_240` | x264 `bframes=8:b-pyramid=normal:b-adapt=0` | 417.1 ms | every 6.9 pictures | 375.4 / 286.1 ms |
| `hevc_b8_240` | x265 `bframes=8:b-pyramid=1:b-adapt=0` | 417.1 ms | every 7.7 pictures | 375.4 / 322.8 ms |

**Results** (HEAD; the Stage 4 `cal2-*` logs on `h264b_160` / `hevc_160` read the same way and are included
in the model check below):

| run | anchored on (decode order) | start error: model / measured 1–3.5 s | clock slew 0.5–20 s | steering on its ±2000 ppm rail | `[AV-CONTENT]` median, ms: 3–10 · 10–20 · 20–40 · 40–60 · 60–90 · 90–150 · 150–240 |
|---|---|---|---|---|---|
| `ctl` | picture 25, pts − dts 0 | −2.5 / +1.0 ms | +8.4 ms | never | −2.14 · +0.16 · −0.17 · +1.99 · +0.88 · −0.32 · −0.48 |
| `h264_b3p` | picture 25, the leading P (pts − dts 208.5) | **−72.0 / −69.7 ms** | −55.1 ms | 16–29 s (−) | +26.53 · **+39.38** · +12.53 · −1.99 · −2.65 · −0.45 · −0.19 |
| `hevc_b3p` | picture 25, a B-ref (pts − dts 83.4) | **+56.3 / +41.5 ms** | +42.5 ms | 16–33 s (+) | −27.42 · **−40.76** · −20.02 · +1.78 · +3.53 · +1.24 · +0.37 |
| `h264_b8` | picture 25, a B (pts − dts 41.7) | **+192.5 / +112.4 ms** | +69.0 ms (+125 by 40 s) | 16–99 s (+) | −28.70 · −53.20 · −82.84 · **−83.64** · −55.78 · −0.21 · +1.83 |
| `hevc_b8` | picture 24, a B (pts − dts 0) | **+237.5 / +185.2 ms** | +96.7 ms (+139 by 40 s) | 16–123 s (+) | −29.07 · −55.56 · −96.57 · **−113.55** · −93.98 · −19.99 · +1.63 |

- **Every run kept the rules:** cushion raised BEFORE the first anchor to the same values as 0b-2b
  (259 / 467 ms), 0 shown out of order, 10–21 unseen (the baseline), 0 holds, 0 coarse events,
  0 splices.
- **The measured 1–3.5 s error trails the model** because the clock is already on its rail by then
  (5 ms/s).
- **The model gets every sign right.** Its size is within ~30 % on bframes 3. On bframes 8 the
  measurement trails it further, because the clock has been on its rail longer by then.
- **All fourteen B-frame runs sort into the model's two classes.** These are the four above and ten
  older ones: Stage 4's `cal2-h264b-*`, `cal2-hevc-*`, `soak-hevc`, `loss`, `loss2` and `b8_240`, and
  0b-2b's `b3pyr` and `b8pyr`. Each start-up summary's "max arrival lead" decides the class: ≤ 26 ms
  means a negative error, ≥ 131 ms a positive one.
- **The model's lead figures match the summaries:** +0.0 against +2.9–8.4 measured on leading-P starts,
  and +125.1 against +131–133 on B-ref starts.

**The cause, with references.**
1. **The anchor is one decoded picture.**
   - The SRT router anchors `LiveClock` on the first picture it had to wait for
     (`SRTFrameRouter.swift:2086`, `anchorOrDefer` → `registerFrame` at `:2158`). `registerFrame` puts
     `now()` at that picture's PTS minus the cushion (`LiveClock.swift:538`).
   - Decode is synchronous, so pictures arrive in decode order (`LiveVideoDecoder.swift:42–52`).
   - **The anchored picture's position in the mini-GOP decides everything.** Every run here anchored
     on decode-order picture 24–25: the end of the ~1 s `find_stream_info` backlog. So the class is
     set by the stream's GOP phase at the join, not by chance. x264 put a leading P there and x265 a
     B-ref, on the same content. That is why "the sign varies by session": it varies by sender and
     join point.
2. **The depth the loop regulates is a mini-GOP-wide sawtooth.**
   - `MetalVideoRenderer.swift:2306`: span = newest queued PTS − `now()` + Δ/2, where Δ is the
     median gap between PTS-sorted neighbours (`:1982–1991`).
   - On a reordered stream the newest PTS does not advance every picture. The leading picture (P or
     reference B) jumps it by a whole step, then the B-frames fill in behind it. So the span falls for
     a step (167 ms at bframes 3, 375 ms at bframes 8) and then jumps back up.
   - **The Δ/2 correction assumes one-frame steps.** The regulated mean therefore sits (step − Δ)/2
     below the top of the sawtooth: ~62 ms at bframes 3 and ~167 ms at bframes 8.
   - **So the steady state the loop seeks is not where the anchor put the clock.**
     - **Anchored on the leading picture** (the top): the depth reads ~(step − Δ)/2 short, and the
       clock runs slow.
     - **Anchored on a B-picture:** the depth reads deep by the leading picture's lead over it, less
       that bias, and the clock runs fast.
3. **The start-up realign that exists for exactly this never runs on SRT.**
   - `LiveClock.swift:1445` removes the anchor's offset BY POSITION, but only while
     `!hasPresentedOnce`.
   - On SRT, the backlog pictures queued before the anchor are already due, so a picture is presented
     on the first tick and `hasPresentedOnce` flips (`LiveClock.swift:1518`).
   - Every SRT log here, Baseline included, says `first presentation +0.00x s after first frame ·
     startup realigns=0`.
   - On Baseline that costs nothing, because the anchor is the newest picture (error −2.5 ms).
4. **So the error is removed by rate.**
   - The P-loop (k 0.8, `LiveClock.swift:1466`) rails at ±0.5 % (`:98`) for any error above ~6 ms. It
     takes ~12 s to remove 60 ms, and 40–60 s to remove 120–190 ms.

**Why it settles over 20–90 s, and why the sound is what is off.**
- **The clock's rate moves the picture.**
  - `now()` runs 0.5 % slow or fast, so each picture is shown progressively later or earlier: ~55 ms
    of picture latency over the first 12 s on `h264_b3p`, and ~140 ms over the first 40 s on `hevc_b8`.
  - The picture's end position is the steady state's, and the change is invisible as motion.
- **The sound follows the same line but may move only ±0.2 %** (the steering's bound,
  `LiveAudioResampleSteering.swift:1381`). While the clock is on its rail, the gap between them grows at
  ~3 ms/s:
  - `h264_b3p`: +39 ms by +11 s;
  - `hevc_b8`: −114 ms by +50 s.
- **The steering then sits on its own rail until it has caught up:** 18 s on bframes 3, 88–112 s on
  bframes 8.
- **Its integral term overshoots** (i ≈ ±120 ppm when it leaves the rail). That leaves 2–4 ms of the
  other sign at 40–90 s, which decays by ~90–150 s. That tail is BUGS.md's "≤ 3 ms by 60 s, < 1 ms by
  90 s".
- **In short:** the picture is moved (by design, slowly) and the sound arrives late at the same place.
  The A/V offset is the sound's lag behind a picture move. **BUGS.md's ~35 ms is bframes 3. At
  bframes 8 it is ~85–115 ms and lasts ~2 minutes.**

**Steady state, after the episode.**
- **The same sawtooth keeps the clock bang-bang.** On a rail in 74–95 of 118 s on bframes 3 and
  112–114 on bframes 8, against 49 on the control. 1 Hz err sd 15–17 / 53–62 ms, against 7.
- **It costs the sound nothing measurable.** `[AV-CONTENT]` over 150–240 s: sd 1.0–1.5 ms on every
  B-frame run, against 1.7 ms on the control.

**Interaction with the 0b-2b reorder term.**
- **The term itself is untouched.** It raises the cushion before the anchor, to the same values as in
  0b-2b.
- **But the router's arithmetic assumes `now ≈ P − targetDepth` for the leading picture P**
  (`SRTFrameRouter.swift:182`). The loop actually holds `now` (step − Δ)/2 further back: ~62 ms at
  bframes 3, ~167 ms at bframes 8.
- **So every B-frame margin measured since 0b-2b has included that hidden slack.** It is the likely
  reason `b16at15` (1.2 s of reorder at the 1.0 s clamp) played clean.
- **Any fix that changes the steady state must re-measure the reorder term.** A fix that only corrects
  the start, and leaves the depth reading and the steady state alone, keeps every 0b-2b figure valid.

**Interaction with calibration.**
- **Inside the episode, a calibration reads the episode:**
  - Stage 4 item 5's +60 s readings were the overshoot tail (+1.9 / −2.9 ms), and the advance budget
    read 0.0 ms.
  - On bframes 8, +60–75 s reads −65 / −103 ms and +105–120 s still reads −2.4 / −33 ms.
- **From +120 s on bframes 3 and +150 s on bframes 8, it is within the control's own scatter.**

**Why a depth-reading fix alone is not enough** (the model, same anchors):

| | start error today | with Δ/2 replaced by half the newest-PTS step |
|---|---|---|
| leading-P start (`h264_b3p`, `cal2-h264b`) | −72.0 ms | **−9.4 ms** |
| B-ref start (`hevc_b3p`, `cal2-hevc`) | +56.3 ms | **+118.9 ms** |
| B start, bframes 8 (`h264_b8`) | +192.5 ms | **+359.3 ms** |

- **No definition of depth can fix both classes.** The error is the anchored picture's own reorder
  against the stream's leading picture, and only the anchored picture's role decides it.
- **The anchor position has to be corrected.** That is start-up and anchor logic, which the brief
  excluded.

**What a fix would be (for decision).**
- **Recommended:** let the start-up realign (`LiveClock.swift:1445`) work on SRT.
  - Measure the depth's mean over one newest-PTS step and move the clock by position, before the first
    picture is shown.
  - The cushion always spans at least one step, since step ≲ reorder + Δ and cushion = reorder +
    50 ms. So this costs no start-up time beyond withholding the pre-anchor backlog from the screen.
  - It changes neither the depth reading nor the steady state, so 0b-2b's margins stand.
  - **What it changes:** whether the pre-anchor backlog is presented (`hasPresentedOnce`); and the
    position that the anchor and the audio's first mapping are given.
- **Not recommended alone:**
  - the half-step depth correction (the table above);
  - a slower depth filter: it moves every live transport's loop and invalidates `LIVECLOCK_PRESETS.md`.
- **For the brief's prediction 1, a band to reconsider:** today's control alone had 24 of 183
  `[AV-CONTENT]` readings outside ±3 ms from +10 s (max 6.1 ms, a 40–75 s wander on a 1-frame
  sawtooth). Stage 4's Baseline runs had 0, so the spread varies by session. A ±3 ms band per reading
  would fail on HEAD's control.

**The x264 Cloudflare calibrations (taken at +1:45 or later) do not need re-reading.**
- **Those sessions were the `h264_b3p` class:** OBS x264 veryfast, 3 B-frames with a pyramid, 208 ms
  of reorder.
- **On the B-frame bframes 3 runs, the window a +1:45 calibration measures reads −1.23 and +0.29 ms,**
  against −0.74 on the control. By +2:10 it reads −0.47 and +1.88.
- **So the +1:45, +2:10 and +8 min figures (−57.76 / −57.93 / −54.23 ms) carry at most ~1–2 ms of the
  episode.** That is inside the control's own ±2 ms, and far inside Cloudflare's day-to-day range.
- **Caveat:** a Cloudflare calibration started before ~+90 s, or any session with a deeper pyramid,
  would need re-reading.

**Gates.** `swift test` 273 / 273; `soaklog.test.mjs` 8 / 8; C harness 200 / 200; Profile build, 11 warnings,
the same set as Stage 4.

**Defaults.**
- **Before the first launch:** exported (1 142 keys).
- **After the last quit:** 5 run-added `NSWindow Frame` keys and nothing else. Each was checked absent
  from the snapshot, read, and deleted by name.
- **The domain is dictionary-equal to the snapshot** (1 142 keys). `streamBookmarks` was never read or
  written: every run dialled `MANIFOLD_SRT_DEBUG_URL`.

#### The B-frame start-up offset, step 2 — the windowed start-up realign: predictions, written 2026-10-10 before the code changed

**Decided (Robbie, 2026-10-10):**
- Let the start-up realign run on SRT, by position, once one full step of depth has been seen and before
  the first picture is shown.
- The pre-anchor backlog is no longer put on screen.
- The depth reading and the steady state are unchanged.

**What changes.**
- **`LiveClock`: an opt-in window**, `setStartupRealignWindow(_:)`. 0 is today's behaviour, and WHEP,
  NDI and the synthetic harness keep it.
  - With a window W > 0, from the anchor until the realign, the clock HOLDS the picture.
  - It averages the raw depth samples (the same signal the loop regulates) over W from its first
    sample.
  - It then moves itself by position, mean − target, at unity rate: one `startupRealign` event, the
    existing path, before the first presentation.
  - Nothing else runs during the hold: no P-loop slew, no snap.
  - A target step or a queue-full re-anchor during the hold restarts the window.
- **The renderer: a hold seam.** While the clock holds, the tick selects nothing and presents nothing,
  but still samples depth.
  - Queued pictures that cannot become due even if the realign moves the clock back by a whole window
    (pts ≤ now − W) are discarded unseen. That pre-anchor backlog is what HEAD put on screen at once.
  - The seam is installed and removed by `LiveDisplayRoute` with the depth hook.
- **`SRTFrameRouter`: W = one full step.** That is the largest advance of the newest PTS among the
  pictures decoded before the anchor (decode order), capped at the cushion, and at least one nominal
  frame interval. It is set before `registerFrame` anchors, and stated on the anchor line.
  - Every SRT stream gets the hold, B-frames or not: one rule.
- **The audio needs no change.** Its first anchor already waits for the first presentation (§2.7), so
  it starts on the realigned line. `liveAudioPositionJump` already ignores start-up realigns.

**What it does not change, against the brief's premise.**
- **The hidden slack is not removed.** The loop still regulates the same mean, so the steady state
  keeps the extra (step − Δ)/2 behind the leading picture.
- **What goes is the start-up phase:**
  - leading-P starts no longer begin ~60 ms short of that steady state;
  - B starts no longer begin up to ~190 ms past it.
- **So item 3 tests the reorder margins with the start-up over-fill gone.** That over-fill gave B starts
  extra room for 20–100 s. Item 3 does not test them with the slack gone.

**Fixtures:** the step-1 set (`ctl_240`, `h264_b3p_240`, `hevc_b3p_240`, `h264_b8_240`, `hevc_b8_240`);
`syncD`; `soak33` (the one-frame soak fixture); 0b-2b's `b8pyr240`, `b16pyr240`, `b16at15x240`; 0b-2a's
`hi8`, `hi25`, `lo150`; Stage 4's `hevc_soak2` for the 30-minute soak.

Steps measured offline over each fixture's first 26 pictures (≈ the pre-anchor backlog):

| fixture | largest step | the hold W predicted |
|---|---|---|
| syncD, soak33, ctl | 41.7 ms | **41.7 ms** |
| `*_b3p_240`, `hevc_soak2` | 166.8 ms | **166.8 ms** |
| hi8, hi25 | 160 ms (median 80) | **160 ms** |
| lo150 | 160 ms | **160 ms** |
| `*_b8_240`, `b8pyr240` | 375.4 ms | **375.4 ms** |
| `b16pyr240` | 709 ms | **709 ms** (cushion 801) |
| `b16at15x240` | 1 133 ms | **1 000 ms** (capped at the 1.0 s cushion) |

**Builds:** HEAD `0ab5684` (`.build-cc/bfhead-Profile`, from step 1) against the tree (`.build-cc/bf-Profile`),
unsigned Profile. **Runs:** HEAD gets syncD, soak33 with one calibration at +60 s, and the 30-minute
soak; the tree gets everything. Unattended.

| # | what | predicted | pass band |
|---|---|---|---|
| 1 | B-frame fixtures, 240 s: H.264 and HEVC, bframes 3 and 8 | `startup realigns=1` on each, moved by about step 1's start error: **h264_b3p −55…−75 ms; hevc_b3p +35…+60; h264_b8 +110…+200; hevc_b8 +180…+240**. Afterwards no clock rail episode and no steering rail | **Robbie's band**, against the tree's own `ctl` run in the same batch: `[AV-CONTENT]` from +10 s, **median within ±2 ms of the control's median**, and **max \|x\| ≤ the control's max \|x\| + 3 ms**. Also: the log says `startup realigns=1`; no `RATIO AT ITS RAIL` line in the first 60 s |
| 2 | No-B control: syncD and soak33, against HEAD's runs today | One realign line, **\|moved\| ≤ 15 ms** (a mean over 1 frame at 60 Hz ticks is ±Δ/4). Everything else as HEAD: cushion 250, no raise; 0 holds; the `[SRT]` / `[SRT-AUDIO]` / `[SPS-COLOR]` / `[SRT-BUFFER]` identical-text set. **One frame more start-up: the first picture comes ~42 ms + up to one tick after the anchor, not ~5 ms.** "No extra start-up delay" is met to one frame, not literally | syncD: `[AV-CONTENT]` median within ±2 ms of HEAD's same-day run; 0 holds; identical-text set. soak33: the +60 s calibration within ±2 ms of HEAD's same-day figure. First picture ≤ anchor + 0.042 s + 2 ticks |
| 3 | Reorder margins at 240 s: `h264_b3p_240` (bframes 3), `b8pyr240`, `b16pyr240`, `b16at15x240` | Cushion as 0b-2b, before the anchor: **259 / 467 / 801 / 1000 ms**. **0 shown out of order, 0 holds** (0b-2b: 0 / 0 / 0 / 0). The risk is the first minute only, where B starts used to have the over-fill | **0 out of order, 0 holds on every one.** If any fails: stop and report (the reorder term may need adjusting) |
| 4 | Calibrations at +60 and +120 s: `h264_b3p_240`, `hevc_b3p_240`, `h264_b8_240`, `hevc_b8_240` (`cal.sh`, measure-only) | +60 s reads as +120 s: the episode is gone | **\|(+60) − (+120)\| ≤ 2 ms** on each of the four |
| 5 | 30-minute soak, `hevc_soak2` (B-frames, 208.5 ms reorder), HEAD and tree, calibrations at +1 / +2 / +16 / +32 min | Drift and holds unchanged. The tree's +1 min calibration no longer carries the episode | End − start within ±2 ms of HEAD's; `[AV-LAG]` slope after 180 s within ±0.5 ppm of HEAD's; **0 holds** on both; cushion 259 before the anchor on both. The tree's +1 / +2 min within ±2 ms of its +32 min |
| 6 | First picture time | **≈ anchor + W + ≤ 1 display tick** (table above), against HEAD's ~anchor + 0.005 s | `first presentation` − anchor **≤ W + 2 display ticks (33 ms)** on every run, i.e. no later than HEAD by more than one step |
| 7 | Coarse packing: hi8, hi25, lo150 (ffmpeg's default packing) | Cushions unchanged: **336 / 336 / 624 ms** before the anchor (the packing wins; reorder 200 ms → 250). The realign runs (x264 B-frames) | Cushion values exact; **0 holds**; low-water: hi8 / hi25 in 60–130 ms (0b-2a v2: 95.1 / 97.1), lo150 settled in 60–110 ms (64–66) |
| 8 | gates | — | `swift test` all pass (273 + new `LiveClock` tests for the windowed realign: the hold, the mean, one event, no slew during it, restart on a target step, window 0 = today); soaklog 8 / 8; C harness 200 / 200; Profile build, the same 11 warnings |

**What this stage could invalidate:**
- the start-up figures of every B-frame SRT session (that is the point);
- the unseen-picture baseline (~19 per connect at HEAD). Backlog discarded during the hold is not
  counted by the DEBUG probe, so that baseline will fall;
- the first-picture time on every SRT stream, by one step.

Steady-state figures should not move.

#### The B-frame start-up offset, step 2 — results, 2026-10-10 16:35–19:20 (unattended)

**As built.**
- The three pieces predicted above, and one addition: the window's arithmetic lives in a new leaf target,
  `StartupRealign` (`StartupRealignWindow`), with 5 tests.
  - The reason: `LiveClock` reads the host clock, and its module links libav, which no test bundle can
    link. That is the same reason `FileAudioLookahead` is a leaf.
  - The tests cover: one full step gives the sawtooth's mean at every phase; half a step depends on the
    phase; the completing sample is excluded; restart; disabled.
  - **Shown to fail:** with the completing sample folded into the mean, 3 of the 5 fail.
- The hold, the release and "no slew during the hold" are not unit-tested. They are seen in the runs:
  `startup realigns=1`, and `rate=1.0000` at the first presentation.
- **Builds:**
  - HEAD `.build-cc/bfhead-Profile`;
  - the tree `.build-cc/bf-Profile`;
  - a scratch probe variant `.build-cc/bfprobe-Profile`: the tree plus a per-tick depth and per-arrival
    log for the first 6 s. Never in the source tree; the file was restored and checked after the build.
  - All unsigned Profile, 11 warnings, the same set as HEAD.
- **Logs:** `~/Desktop/manifold-soak/bf/repro/` (`bf-*` tree, `head-*` HEAD, `probe-*`).
- **Run order:** the tree batch was stopped once, after `bf-hevc_b3p`, to run the probe (*Why*, below).
  It then resumed on the same build, with a second control on each build added.

| # | result | verdict |
|---|---|---|
| 1 | Realigns, before the first presentation, `startup realigns=1` each: **h264_b3p −50.3 ms, hevc_b3p −44.5 ms, h264_b8 +205.5 ms, hevc_b8 +203.6 ms** (hevc_b3p anchored on a P this time: picture 24, pts − dts 208.5; HEAD's run anchored on a B-ref). No steering `RATIO AT ITS RAIL` line in any tree run; HEAD had one at ~+16 s in every B-frame run. `[AV-CONTENT]` from +10 s, median / max \|x\|: **h264_b3p −0.36 / 10.06; hevc_b3p −0.27 / 8.72; h264_b8 +0.11 / 3.08; hevc_b8 −0.06 / 2.90** (HEAD: −0.37 / 40.94, +0.66 / 42.07, +0.12 / 88.42, −12.84 / 115.35). Tree controls: `bf-ctl` −0.68 / 9.98, `bf-ctl2` −0.32 / 7.31 | **PASS on Robbie's band**, all four, against either tree control. The realign sizes MISSED the predicted ranges by ~5 ms on h264_b3p and h264_b8; hevc_b3p was predicted on HEAD's anchor, not the one it took. **Against HEAD's controls (max 4.55 / 6.14) the bframes 3 runs would not pass:** their 3–10 s medians are +10.07 / +9.31 ms |
| 2 | **syncD:** cushion 250, no raise; 0 holds; the identical-text set **7 / 7 identical** to HEAD's; `[AV-CONTENT]` median −0.32 ms over the session (HEAD −0.03 / −0.00 in two same-day runs); first picture +0.060 s after the anchor. **But one realign of +19.4 ms, and the start is worse:** 3–10 s median **+14.11 ms** (HEAD +0.78 / +3.95), max \|x\| from +10 s **11.62** (HEAD 3.58 / 3.50). **Control `ctl_240`, twice on each build:** realigns +15.1 / +14.2 ms; 3–10 s **+13.87 / +9.88** (HEAD −2.14 / −3.04); max from +10 s **9.98 / 7.31** (HEAD 6.14 / 4.55). **soak33 at +60 s:** +0.44 ms (HEAD +0.46) | **Written band: PASS** (median, holds, text, soak33 within ±2 ms, first picture ≤ 75 ms). **Realign \|moved\| ≤ 15 ms: FAIL** on syncD (19.4) and one control (15.1). **"Identical to HEAD apart from the realign line": FAIL.** Every no-B start is now ~10–14 ms off for its first ~10 s, where HEAD's was within ~4 ms |
| 3 | 240 s margins: `h264_b3p_240` cushion 259, `b8pyr240` 467, `b16pyr240` 801, `b16at15x240` 1000, each BEFORE the anchor. **0 shown out of order and 0 holds on every one.** Unseen 2 / 13 / 26 / 23. `b16at15x240`: the model's late count 180, as 0b-2b | **PASS** |
| 4 | +60 / +120 s calibrations: h264_b3p **+1.11 / −1.51** (Δ 2.62); hevc_b3p −1.17 / −0.93 (0.24); h264_b8 −0.71 / +0.48 (1.19); hevc_b8 −0.18 / −0.71 (0.53). HEAD at +60 s on bframes 8 read −65 / −103 ms (step 1) | **3 of 4 PASS; h264_b3p MISSES by 0.62 ms.** Its +60 s figure is the start's residual: after the realign the clock still read −48 ms (mean, 1–3.5 s) and slewed −34 ms by +20 s to remove it |
| 5 | 30-minute soak, `hevc_soak2` (33.4 min), tree then HEAD, same day. Calibrations +1 / +2 / +16 / +32 min: **tree +0.91 / −0.68 / +0.32 / +0.56 ms**, HEAD **−4.09** / −0.30 / +0.82 / +0.28. End − start: tree −0.35, HEAD +4.37. +2 → +32 min: tree +1.24, HEAD +0.58. `[AV-LAG]` slope after 180 s: tree +0.02 ppm, HEAD +0.01 (this session's script; Stage 4's method read +0.2 on its run). **0 holds** on both; cushion 259 before the anchor on both; 0 out of order; tree realign +78.8 ms | **Slope, holds, cushion: PASS.** Tree +1 / +2 min within ±2 ms of its +32 min: **PASS.** **End − start within ±2 ms of HEAD's: MISS (4.72 apart)**, and the band was the wrong test: HEAD's own +1 min figure (−4.09) is the B-frame episode this stage removes. On the drift itself (+2 → +32 min) the two builds are 0.66 ms apart |
| 6 | First picture after the anchor: ctl +0.064 / +0.065, syncD +0.060 (W 41.7); b3 +0.177 / +0.189 (166.8); b8 +0.398 / +0.400, b8pyr240 +0.397 (375.4); b16pyr240 +0.723 (709.0); b16at15x240 **+1.021** (1000, capped); hi8 +0.180, hi25 +0.178, lo150 +0.176 (160.0). HEAD: +0.002 to +0.008 s | **PASS**: every one ≤ W + 33 ms. b16at15 shows nothing for a full second |
| 7 | hi8 / hi25: **336 ms** before the anchor; realign +69.6 / +74.2 ms; **0 holds**; low-water 84.7–90.1 / 83.5–92.6 ms. **lo150: 624 ms** before the anchor; realign **+278.2 ms**; **7 starvation holds, at +1.6 to +6.0 s**; low-water 23.6 → 38.1 → 57.4 → 62.0 → **65–72 ms from +60 s** | hi8 / hi25 **PASS** (60–130). **lo150 FAILS on holds** (0b-2a v2: 0). Settled low-water in band (60–110) |
| 8 | `swift test` **278 / 278** (273 + 5 `StartupRealignTests`, shown to fail above); soaklog 8 / 8; C harness 200 / 200; Profile build, 11 warnings, the same set as HEAD | **PASS** |

**Why the no-B starts got worse, and lo150 held: one step is one tooth, and one tooth is not the mean.**
- **The probe** (`probe-h264_b3p`: per-tick depth and arrivals) shows the hold doing exactly what it
  should:
  - 22 samples at 120 Hz across one full 167 ms tooth, then one move by position, then release.
  - `rate=1.0000` throughout the hold.
- **The teeth are not alike.** The leading pictures arrive with jitter: their arrival leads run +59, +75,
  +91, +110, +111, +120, +127 ms. Each tooth's height moves by that much.
- **How long a window has to be.** Rebuilt rate-free from the probe's arrivals, a window's mean against
  the long-run mean (1–6 s):
  - **one step: sd 19.6 ms, max 48.9;**
  - two steps: sd 12.1;
  - four steps: sd 9.1;
  - six steps (1.0 s): sd 7.1;
  - twelve steps (2.0 s): sd 3.7, max 7.8.
- **So a one-step window removes the structural B-frame offset (60–200 ms) and leaves a ±20 ms residual
  of arrival jitter.** That is the bframes 3 result: 40 ms → ~10 ms.
  - On bframes 8 the structural offset dominates and the tooth is longer, so the residual is
    proportionally small: 115 ms → 3 ms.
- **On a stream without B-frames the window is ONE FRAME.** It is taken from the pre-anchor backlog, which
  is decoded in a burst, so every step there is one frame. But this sender delivers pictures in PAIRS (the
  probe's arrivals: 0.092 / 0.093, 0.175 / 0.177, …), so the live tooth is ~83 ms.
  - A 42 ms window sees its top half, ~+Δ/2 high. That is the systematic **+14…+19 ms** realign on all
    three no-B runs, and the +10–14 ms first ten seconds.
  - HEAD's no-B starts were within a few ms, because the anchor there is the newest picture, and the loop
    removes the pair's ripple by rate.
- **lo150 is bursty, low-rate video (150 kb/s).** One 160 ms step measured a burst. The realign overshot:
  the clock read −152 ms just after the release, then −72…−112 for ~8 s.
  - That moved the picture's line ~100 ms closer to the audio's lumpy arrivals (363 ms per PES), hence the
    holds until the clock and steering pulled back (low-water 24 → 65 ms by +60 s).

**What would fix it (for decision; not built).** Each option keeps the decided mechanism: a hold, then one
move by position.
- **A. A longer window: k steps, or at least ~1 s.**
  - Error falls as above, to ±7 ms at 1 s.
  - The cost is start-up time: the picture is held that long.
  - It cures the no-B pair case, and probably lo150, since six bursts average out.
  - Prediction 6's band would have to become "≤ max(W, 1 s)".
- **B. Whole live teeth, not a time.** Start the window at the first advance of the newest PTS after the
  anchor, and end it at the first advance at least W later.
  - This makes the mean period-exact whatever the live tooth (pairs included).
  - It fixes the no-B bias with a ~2-tooth hold (≤ ~170 ms there), but not jitter: a bframes 3 stream
    still gets ±20 ms.
- **C. B with a floor in teeth.** At least N whole teeth, e.g. N = 4: ±9 ms. That is 0.67 s at bframes 3,
  1.5 s at bframes 8, ~0.33 s with no B-frames.
- **D. Keep this build, but hold and realign only on a stream that reorders (max pts − dts > 0 at the
  anchor).**
  - No-B streams would go back to HEAD's behaviour exactly, backlog shown.
  - B-frame streams keep this result.
  - lo150 (x264 with B-frames) would still hold, so D alone is not enough.

**Recommendation:** C with N = 4, and D's exemption unless the decision is to hold every stream alike. Both
are changes to the decided "one full step", so they are not built.

**Defaults.**
- **Before the first step-2 launch:** exported (1 142 keys, dictionary-equal to step 1's restored domain).
- **After the last quit:** 25 run-added `NSWindow Frame` keys and nothing else. Each was checked absent
  from the snapshot, read, and deleted by name.
- **The domain is dictionary-equal to the snapshot** (1 142 keys). `streamBookmarks` was never read or
  written: every run dialled `MANIFOLD_SRT_DEBUG_URL`.

**Step 2, unattended, in one list:**
- **Met:**
  - 1: Robbie's band, all four B-frame fixtures;
  - 3: margins at bframes 3 / 8 / 16 and `b16at15`, 0 out of order, 0 holds;
  - 6: first picture ≤ one step;
  - 7 on hi8 / hi25;
  - 8: gates;
  - the written bands of 2;
  - 5's drift, slope and holds.
- **Missed:**
  - 2's "identical to HEAD": every no-B start is ~10–14 ms worse for ~10 s, and the realign was over
    15 ms on two of three no-B runs;
  - 4 on h264_b3p (2.62 against 2);
  - 7 on lo150 (7 holds);
  - 5's end − start, a band that measured HEAD's episode.
- **Cause of every miss:** a one-step window is one tooth. On a no-B stream it is half of the sender's
  real (paired) tooth.
- **Not committed. The window needs a decision** (*What would fix it*, above).

#### The B-frame start-up offset, step 3 — four whole teeth, and no hold without reordering: predictions, written 2026-10-10 before the code changed

**Decided (Robbie, 2026-10-10):**
1. The start-up realign averages **at least 4 whole live teeth, counted from arrivals** (≈ 0.33 s no-B,
   0.67 s bframes 3, 1.5 s bframes 8). Prediction 6's one-step start-up limit is relaxed accordingly.
2. **Streams with no B-frames (no reordering seen before the anchor) skip the hold** and start exactly
   as HEAD does.

**What changes against step 2.**
- **`StartupRealignWindow` counts teeth, not seconds.** A tooth starts where the newest queued PTS
  advances, so this is counted from arrivals.
  - The window opens at the first advance after the anchor and closes at the 4th advance after that.
    The sample on the closing advance is excluded, so the mean covers exactly 4 whole teeth whatever
    their length: pairs, adaptive B-frames, jitter.
- **The hold's discard floor** becomes now − cushion: the realign can never move the clock back by more
  than the cushion, since the mean depth is ≥ 0. The window no longer has a known length.
- **A safety cap of 5 s on the hold.** It applies only if the teeth do not arrive (a stall at connect).
  At the cap the picture is released with no realign, and the start-up line reads `startup realigns=0`.
- **`SRTFrameRouter`:** if no decoded picture before the anchor came out of presentation order, the
  window is 0. The clock then runs HEAD's path exactly: no hold, the backlog shown, the old first-tick
  realign gated as at HEAD. One `[SRT] startup hold:` line says which applies.

**Fixtures and builds:**
- **Fixtures:** the step-1/2 fixtures. HEAD comparisons are today's runs (`head-*`), already recorded.
- **Builds:** the tree `.build-cc/bf3-Profile`. Unsigned Profile, unattended.
- **Estimated run time ≈ 45 min:**
  - 4 × 240 s B-frame runs;
  - syncD (300 s);
  - hi8, hi25 (45 s each);
  - lo150 (150 s);
  - 2 calibration runs to +120 s;
  - the build and gates.

| # | what | predicted | pass band |
|---|---|---|---|
| S1 | `h264_b3p_240`, `hevc_b3p_240`, `h264_b8_240`, `hevc_b8_240` | `startup realigns=1`. Hold = wait for the first advance (≤ 1 tooth) + 4 teeth: **~0.7–0.9 s** on bframes 3, **~1.5–1.9 s** on bframes 8. The 4-tooth mean's error ~±9 ms (1 sd, the probe), so a 3–10 s `[AV-CONTENT]` of a few ms, not ~10 | Against this batch's syncD (the no-B control, now HEAD's behaviour): from +10 s, **median within ±2 ms of the control's, max \|x\| ≤ the control's max + 3 ms**; `startup realigns=1`; no steering `RATIO AT ITS RAIL` line |
| S2 | syncD | **No hold, no realign**: one `[SRT] startup hold:` line saying none; `startup realigns=0`; first picture +0.00x s after the anchor, as HEAD | `startup realigns=0` and no `startup realign` line; first presentation − anchor ≤ 0.010 s; the identical-text set 7 / 7 against `head-syncD`; `[AV-CONTENT]` from +10 s median within ±2 ms of HEAD's (−0.04 / −0.09), max ≤ HEAD's max + 3 ms (3.58 → 6.58); 3–10 s median within HEAD's range ±3 ms (+0.78 / +3.95); 0 holds |
| S3 | hi8, hi25, lo150 (default packing; x264 B-frames, so held) | Cushions **336 / 336 / 624 ms**. hi8 and lo150 use adaptive B-frames, so 4 teeth may span as little as ~4 frames: the hold may be short (0.2–0.7 s). lo150's overshoot should shrink with 4 teeth | Cushion values exact; **0 holds in the first 10 s** on all three (lo150 step 2: 7); hi8 / hi25 0 holds over the run |
| S4 | Calibrations +60 / +120 s: `h264_b3p_240` (step 2: 2.62 ms) and `h264_b8_240` | +60 s reads as +120 s | **\|(+60) − (+120)\| ≤ 2 ms** on both |
| S5 | First picture after the anchor, each fixture | B-frame: ~hold length (S1). No-B: as HEAD (+0.002–0.008 s) | Reported against HEAD; no band beyond S2's (decision 1 relaxes it) |
| S6 | gates | — | `swift test` all pass (the window's tests rewritten for teeth, including a paired-arrival case, and shown to fail); soaklog 8 / 8; C harness 200 / 200; Profile build, the same 11 warnings |

**Not re-run:**
- the 30-min soak and soak33: the steady state is unchanged;
- the margins at bframes 8 and 16, which depend on the steady state.
- `b16at15`'s hold is now ~4 teeth of up to 1.13 s each, so it may reach the 5 s cap. Not tested here;
  recorded as open.

#### The B-frame start-up offset, step 3 — results, 2026-10-10 19:56–20:42 (unattended)

**Build:**
- `.build-cc/bf3-Profile`, 11 warnings, the same set as HEAD. Logs `~/Desktop/manifold-soak/bf/repro/s3-*`.
- The window's tests were rewritten for teeth: 6 tests, including the paired-arrival case.
- **Shown to fail:** with the closing sample folded into the mean, 3 fail; with the window opening
  without an advance, all 6 fail (13 assertions). Both restored and re-run green.
- **HEAD comparisons:** today's `head-*` runs.

| # | result | verdict |
|---|---|---|
| S1 | `startup realigns=1` on all four: **h264_b3p −61.2 ms, hevc_b3p +69.0, h264_b8 +180.5, hevc_b8 +222.7**. No steering `RATIO AT ITS RAIL` line (HEAD: one at ~+16 s in each). `[AV-CONTENT]` 3–10 s median / from +10 s median / max \|x\|: **h264_b3p +0.75 / +0.17 / 3.42** (HEAD +26.53 / −0.37 / 40.94; step 2 +10.07 / −0.36 / 10.06); **hevc_b3p −0.22 / +0.27 / 2.94** (HEAD −27.42 / +0.66 / 42.07); **h264_b8 −4.84 / +0.42 / 7.63** (HEAD −28.70 / +0.12 / 88.42; step 2 max 3.08); **hevc_b8 −2.19 / +0.36 / 7.16** (HEAD −29.07 / −12.84 / 115.35; step 2 max 2.90). This batch's control (`s3-syncD`): median −0.00, max 3.76, so the band is median ±2, max ≤ 6.76 | **bframes 3: PASS, both**, now within the control's own spread from the start. **bframes 8: MISS, both, on max** (7.63 and 7.16 against 6.76, by 0.9 / 0.4 ms); medians pass. A −2…−5 ms start residual for the first ~10 s; step 2's single 375 ms tooth happened to land closer on its two runs |
| S2 | `s3-syncD`: `[SRT] startup hold: none — no picture before the anchor came out of presentation order…`; **`startup realigns=0`, no realign line; first picture +0.005 s** (HEAD +0.005 / +0.002); identical-text set **7 / 7**; `[AV-CONTENT]` from +10 s median −0.00, max 3.76 (HEAD −0.04 / −0.09, max 3.58 / 3.50); 3–10 s +3.15 (HEAD +0.78 / +3.95); 0 holds; low-water 272.9–275.8 (HEAD 269–277) | **PASS**, every band: starts as HEAD does |
| S3 | hi8 / hi25 / lo150: cushions **336 / 336 / 624 ms** before the anchor; realigns +82.7 / +78.2 / +214.8 ms; **0 holds on all three, over the whole run** (lo150 step 2: 7 in its first 6 s). lo150 low-water per 10 s window: **48.4** (to +10 s), 55.2, 60.9, then 61.6–68.6 from +40 s; hi8 76.3–90.9, hi25 82.7–89.7 | **PASS** on cushions and holds. lo150's first-window low-water (48.4) is below 0b-2a v2's settled band (60–110), with no hold; in band from +30 s |
| S4 | h264_b3p: **−1.19 / +0.16 ms** (Δ 1.35; step 2 2.62). h264_b8: the batch's +120 s calibration did not run (Robbie clicked elsewhere on the desktop and took focus from the driver's menu click); its +60 s read −2.78. Re-run: **−1.90 / +0.55** (Δ 2.45) | **h264_b3p PASS. h264_b8 MISS by 0.45 ms**: S1's residual, still in the +60 s figure (−1.9 / −2.8 in two runs) |
| S5 | First picture after the anchor (HEAD today): syncD **+0.005** (+0.002–0.005); h264_b3p **+0.844**, hevc_b3p **+0.804** (+0.006 / +0.000); h264_b8 **+1.016**, hevc_b8 **+1.055** (+0.006 / +0.002); hi8 **+0.420**, hi25 **+0.251**, lo150 **+0.704** (0b-2a v2, HEAD then: +0.001 each) | Reported (decision 1 relaxes the limit). bframes 8 is under the ~1.5 s estimate because its steps average 286 ms, not 375 (GOP boundaries) |
| S6 | `swift test` **279 / 279** (273 + 6 `StartupRealignTests`); soaklog 8 / 8; C harness 200 / 200; Profile build, 11 warnings, the same set as HEAD | **PASS** |

**Reading it.**
- **The no-B regression of step 2 is gone.** Those streams start exactly as HEAD does.
- **lo150's holds are gone.**
- **bframes 3 now starts within the control's spread:** max 2.9–3.4 ms from +10 s, against HEAD's 41–42.
- **bframes 8 is down from 88–115 ms to ~7 ms, but misses the band by under 1 ms on max, and the
  calibration band by 0.45 ms.**
- **The cause of both misses is one thing:** the four-tooth mean's predicted residual (~±9 ms, 1 sd),
  showing as −2…−5 ms for the first ~10 s.
- **A longer window would close it:** the probe's figures give ~±7 ms at 1 s and ~±4 at 2 s. That is a
  decision, not built.

**Defaults:**
- **Before the first launch:** exported (1 142 keys).
- **After:** 11 run-added `NSWindow Frame` keys and nothing else, each checked absent, read, and deleted by
  name.
- **Dictionary-equal to the snapshot** (1 142 keys). `streamBookmarks` never read or written.

**Step 3, in one list:**
- **Met:** S2, S3, S6; S1 and S4 on bframes 3.
- **Missed by under 1 ms:** S1 on bframes 8 (max), and S4 on h264_b8.
- **Not committed.**

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

   Added 2026-10-06: (9,14), the NDI `Rec.2020 SDR` preset, falls to the same arm. Until this is
   fixed in Phase 4 the preset is hidden on SRT, WHEP and HLS (§6.9, decision 3).

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
