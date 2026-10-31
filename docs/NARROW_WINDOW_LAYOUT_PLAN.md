# Narrow and vertical windows: control bar and resolution overlay — PLAN ONLY

Status: plan, 2026-10-30 (unattended session). No code changed. For Robbie to judge by eye. Bug: `docs/BUGS.md`, *☐ OPEN 2026-10-29 —
0.9.1 — Narrow/vertical windows: control bar and resolution overlay layout*.

All positions are Accessibility frames in screen points, read from a Profile build of the working tree on the Mac Studio, the
window on the LG (backing scale 1.0), control-bar mode **overlay** (the floating HUD; `controlDisplayMode = overlay`, read, not
written), controls pinned with View ▸ Always Show Controls (`@State`, not persisted). No screenshots. The docked bar was not
measured (switching it writes a preference).

## 1. What happens now

### 1.1 Measured: `IMG_9457.MOV` at the window's minimum

`IMG_9457.MOV` opens at 959 × 1704 on the LG. An Accessibility size change to 100 × 100 stops at **720 × 569** (the picture is 320 × 569,
pillarboxed), as recorded in BUGS.md. View ▸ 25 % gives **720 × 1280** (the readout says "window minimum"). The window spans x = 1440 … 2160
in both.

**The control bar.** The button row lays out at its full natural width and is centred on the window, so it hangs out on both sides:

| element (help text)                     | x … x+w        | inside the window (1440 … 2160)? |
|-----------------------------------------|----------------|----------------------------------|
| Open…                                   | 1261 … 1280    | **no**, 179 pt off the left edge   |
| Play (Space)                            | 1305 … 1317    | **no**                           |
| Mute (button + hover fader area)        | 1355 … 1457    | partly                           |
| Loop playback                           | 1475 … 1492    | yes                              |
| Framing guides, Load subtitles…, Subtitle options, Inspector, Edit in Flip, Refresh metadata, Export frame | 1512 … 1733 | yes |
| Audio track menu ("Stereo")             | 1768 … 1832    | yes                              |
| Scopes tray, DeckLink output, Streaming | 1874 … 1994    | yes                              |
| Colour interpretation ("709 709 · Declared") + chevron | 2035 … 2201 | partly (ends 41 pt past the edge) |
| Display transform                       | 2217 … 2282    | **no**                           |
| Unpin controls                          | 2325 … 2338    | **no**                           |

The row is **1077 pt** wide here (1261 … 2338). In a 2100-pt window with a PQ file it measured **1151 pt** (1344 … 2495), longer
because the colour label is longer ("2020 PQ (ST 2084) · Declared", 209 pt against 147). So the row is about 1080–1150 pt whatever the
window, and below roughly that width plus the HUD's padding, controls are cut off at both edges. **Play is unreachable at the minimum width.**

The scrubber row fits: leading time 1432 (8 pt off the left edge), slider 1530 … 2070 (540 pt), trailing time 2143 … 2168.

**Why the scrubber is 540 and the row is not.** The HUD is `controls(…).padding(12).background(…).frame(maxWidth: 760).padding(16)`
(`ContentView.swift`, overlay branch). The scrubber row is flexible and fills the 760: 760 − 2 × 12 padding − 2 × 86 time readouts −
2 × 12 spacing = 540. The button row (`HStack(spacing: 16)`) is not flexible and overflows the 760 frame, centred, at every window width.

**The resolution overlay** (`rasterReadout`: top-leading on the video region, `.padding(.top, 44)`, `.padding(.leading, 16)`, shown for
1.6 s after a size change). At 25 % the text was `25% — 720×1280 (window minimum)` at **x = 1432**, 8 pt *outside* the window's left
edge, so its first characters and the capsule's left end are clipped.

**One cause, measured three ways.** The HUD's frame is 760 + 2 × 16 = **792 pt**, wider than the 720-pt minimum window, so the video region
(the ZStack the HUD lives in) becomes 792 wide and is centred: it overhangs the window by **36 pt** on each side. Everything anchored to
that region's edges moves out with it:
- the raster readout: expected at 1440 + 16 + 12 = 1468, measured 1432 (−36);
- the Inspector (top-trailing): its values end at x = 2166, 6 pt past the window's right edge. In a 1920-pt window they ended 30 pt inside
  it (2850 against 2880), so again −36;
- the file-name overlay is anchored `.top` (centred) and is unaffected: centred at x = 1800, the window's centre.

### 1.2 Calculated: a 2048 × 1332 MacBook Air screen

Not measured (no Air here); arithmetic from the measurements above, all in points. Layout is in points, so the overflow is the same on any
screen at the same window width.
- A 9 : 16 picture fitted to the Air's usable height (1332 less the menu bar; ~37 pt on a notched Air, **exact visible frame UNKNOWN**)
  gives a window of about **728 × 1295**: effectively the 720-pt minimum.
- Button row ≈ 1077 pt → it overhangs by (1077 − 728) / 2 ≈ **175 pt each side**: Open, Play, Mute, Display transform and Pin are cut off,
  as on the LG.
- HUD frame 792 → overlays shift by (792 − 728) / 2 = **32 pt**: the raster readout and the Inspector are clipped at the edges.
- At the minimum height the window is 720 × 569 there too (BUGS.md, the rotation entry).

## 2. Proposal

### 2.1 First: keep the HUD inside the window (fixes the overlay placement on its own)

Cap the HUD at the window: `.frame(maxWidth: min(760, contentWidth − 32))` (the 16-pt outer padding each side), so the video region is
never wider than the window. With that alone, at 720 pt the raster readout starts at x = 1468 and the Inspector's right edge is back 30 pt
inside, as in wide windows. It does not fix the button row, which still overflows its own frame (2.2).

### 2.2 The control bar: three layouts, chosen by what fits

Use `ViewThatFits(in: .horizontal)` with three variants, widest first, rather than fixed breakpoints: the row's natural width moves with the
colour and audio labels (1077 vs 1151 measured), so a constant would be wrong for some file. Approximate switch points, at today's widths:

| variant | fits from (content width) | button row |
|---|---|---|
| **Full** (today) | ≈ 1140–1210 pt (row + 2 × 12 + 2 × 16) | unchanged |
| **Compact** | ≈ 760 pt | secondary tools move into one **More (…)** menu; colour label shortened |
| **Narrow** (two rows of buttons) | the 720-pt minimum and below | two rows, below the scrubber |

**Never collapses, at any width:** Play/Pause, the scrubber with both time readouts, Mute, Display transform, the DeckLink control
**while output is on** (it is the on-air indicator), and Pin (overlay mode only). Display transform stays because it says how the picture
is being shown: a narrow window is still a comparison instrument.

**Compact: into the More (…) menu, in this order**, the ones used least first: Edit in Flip, Refresh metadata, Load subtitles… + Subtitle
options, Export frame, Framing guides, Loop playback (as a checkmark item). Each keeps its title and shortcut in the menu.
**Colour interpretation:** today's label → short form (icon + primaries only, e.g. "709", "2020 PQ"). If the user has set a preset or an
Override (not Auto), it keeps a visible marker, because a user assertion must stay visible.
Width estimate: 9 fewer controls (≈ 9 × (18 + 16) ≈ 300 pt) and about 100 pt off the colour label bring the row to ≈ 680–750 pt.

**Narrow: two rows of buttons under the scrubber.**
- Row 1 (transport): Open, Play, Mute, Loop | Inspector, Scopes tray.
- Row 2 (output and colour): DeckLink, Streaming | colour (icon only, marker if asserted), Display transform | More (…), Pin.
- Width estimate from the measured frames (Open 19, Play 24 frame, Mute 102, Loop 17, Inspector 17, Scopes 19; spacing 16): row 1 ≈
  300 pt; row 2 ≈ 21 + 17 + 34 + 65 + 20 + 13 + 6 × 16 ≈ 270 pt. Both fit in 720 − 2 × (16 + 12) = 664 pt with room, and down to a
  ~360-pt window if the minimum is ever lowered.
- The scrubber row: the 760 cap gives way to the window (2.1), so the slider shrinks with it (at 720: 664 − 172 − 24 ≈ 468 pt). Below
  ≈ 500 pt, hide the trailing readout's leading zeros, or show remaining time on tap; not needed at today's minimum.
- In overlay mode the HUD grows by one row (~30 pt) over the picture's bottom. On a 720 × 569 vertical window that covers the bottom of a
  320 × 569 picture; acceptable for an auto-hiding HUD. In docked mode `dockedBarHeight` must grow by the same row, or the window sizer's
  chrome height will be wrong (`WindowChrome.dockedControlBarHeight`, `ContentView.swift` chrome height).

### 2.3 The resolution overlay

1. **2.1 fixes the clipping** (the readout is anchored to a region no wider than the window).
2. **Placement for narrow windows (proposal, judge by eye):** when the window is narrower than ≈ 900 pt, show it **top-centre** (as the
   file-name overlay already is, which measured correctly centred) instead of top-leading. On a pillarboxed vertical picture top-leading
   puts it over the black bar rather than the picture; centred, it sits over the picture's top edge.
3. **Length:** `25% — 720×1280 (window minimum)` is 230 pt. If the readout is wider than the window less 32 pt, move the parenthetical to a
   second line instead of truncating it: it is the part that explains why the size is not what was asked for.
4. Not to collide: when the file-name overlay is also shown (top-centre, `.padding(.top, 24)`), stack the readout below it, as the top-edge
   notices are stacked today.

### 2.4 Not in this plan

- The Inspector at narrow widths: once 2.1 lands it is inside the window, but its ~250-pt panel covers most of a 320-pt pillarboxed
  picture. Noted, not proposed.
- The docked bar was not measured; the same three variants should apply to it.

## 3. To check by eye (Robbie)

- 720 × 569 and 720 × 1280 with `IMG_9457.MOV`, overlay and docked: every control reachable, nothing cut off.
- The More (…) menu's contents and order; whether Loop belongs there or in row 1.
- Readout top-centre vs top-leading on the pillarboxed picture.
- A landscape window at 875 × 492 (the landscape minimum, BUGS.md): it should get Compact, not Narrow.
