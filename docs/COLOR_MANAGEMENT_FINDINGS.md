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

##### ⚠️ Two claims in "Three defects that rendered as something plausible" do not survive re-measurement

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

##### ⚠️ The Source line reports the wrong tier on every STREAM

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
carry the distinction; the tier has to come from `NDIColorInfo.tier`, which already exists and is
already on screen two controls away. Not fixed here.

Incidentally, the **third verdict case is now exercised live**: overriding to PQ produced
`Source declares its transfer outside the rTRC (PQ/HLG); no curve comparison is possible.` §6.8
lists it as written-but-unseen.

**And the Source line does not follow a colorimetry change while the readout is open.** `refresh()`
runs on popover open, on a mode change, and on the two screen notifications; nothing observes the
renderer's source codes. Measured: the override changed the tags and the layer immediately (the log
proves it), and the open readout did not move until it was closed and reopened.

---

#### Still open after Phase 2b — amended after 2c part 1

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
- ~~**The Source line has only been exercised on an UNTAGGED file.**~~ **Exercised on a stream, and
  it is WRONG** — every stream prints `— tagged`, including an assumption and including a user
  override. 2c part 1 has the measurement and the cause. The PQ/HLG verdict case is now seen and is
  correct. The `— partly assumed` spelling is still unseen.
- **The Source line does not follow a colorimetry change while the readout is open.** New, 2c part 1.
- **The pulldown's subtitles do not render, and the Color control does not turn amber.** Both
  measured false in 2c part 1; both were believed fixed / believed working.
- **One fixture, one session.** No colorimeter, 8-bit captures, as everywhere else here.

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
