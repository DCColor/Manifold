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
7. **HEVC 4:2:2 and 4:4:4 are refused at the gate with a banner.** "HEVC 4:2:2 10-bit over SRT" goes
   in `ROADMAP_IDEAS.md`.
8. **Multi-layer HEVC: the base layer (`nuh_layer_id` 0) only.**
9. **A C unit-test harness** for the new HEVC access-unit builder.

#### Staged plan

Run in this order. Each stage ships on its own.

- **Stage 0 — the identification fix (H.264 only).** `max_probe_packets` in `SRTSession.m`. Below.
- **Stage 1 — the HEVC parser in the FFmpeg build.** The gate still refuses HEVC.
  - Predicted: all three layers pass; H.264 `[SRT]` and `[SPS-COLOR]` lines identical to the commit
    before; an HEVC stream's refusal log reads `hevc Main 10 1920x1080` within about 1–2 s.
- **Stage 2 — the HEVC SPS colour reader**, in the renamed codec-neutral target. Package only.
  - Fixtures from x265, VideoToolbox and `hevc_metadata`, expected values from `trace_headers`. They
    cover sub-layers, scaling lists, inter-predicted reference picture sets, the conformance window,
    Extended_SAR, 4:2:2 and the reserved and partial cases.
  - Predicted: every field matches; truncated SPS read undeclared, never a wrong colour; mutants fail
    closed.
- **Stage 3 — the HEVC access-unit builder** (with its C test harness), a codec-selected reader, the
  decoder's VPS, and the gate opens for 4:2:0 HEVC.
  - Predicted: x265 PQ/HLG/709 and VideoToolbox streams decode to `x420` with no promote.
  - `[SCOPE-COLOR]` reads 9-16-9 and 9-18-9.
  - A mid-stream join of x265 starts at the next CRA with RASL dropped and no decode errors.
  - H.264 SRT and WHEP are unchanged.
- **Stage 4 — robustness and sync on HEVC.**
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
