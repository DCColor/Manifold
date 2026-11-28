## Color and display modes

This chapter covers what you need day to day. For the detail behind each topic, choose **Help ▸ Sync and Color
Guide** and see *Part 2 · Color management*.

### The picture and what your screen shows

Every file and stream says what its color is: Rec. 709, for example, or Rec. 2020 PQ. Manifold builds **the picture**
from that, plus any correction or LUT you add. The picture is what the scopes measure, what goes out over SDI and
HDMI, and what Export Frame saves.

Separately, each window has a **display mode** that decides how the picture looks on your screen. Changing the display
mode changes only the window. The scopes, SDI output and exported frames stay the same.

### Choose a display mode

Click **Display transform** in the controls, or use the **Color** menu:

| Mode | Use it to | Keys |
|---|---|---|
| **macOS** | See what your client sees in QuickTime, Safari and most Mac apps. This is the default. | ⌥⌘1 |
| **Reference** | Judge the picture as a reference monitor shows it (BT.1886). | ⌥⌘2 |
| **Bypass** | Send the picture to the screen with no color management at all, for diagnostics. | ⌥⌘3 |

The control and the Color menu use the same three names, with a second line that says what each is. A window in Bypass
also says so in its title, and while the controls are hidden, windowed or in full screen, **BYPASS** stays in the
picture's top-right corner.

macOS mode looks lighter than a reference monitor for Rec. 709 video. That's the familiar "QuickTime looks
washed out" difference, and it's what your client sees. *Detail: the guide's "The three display transforms".*

### Hold to compare

- **Hold C** to see the other of macOS and Reference.
- **Hold ⇧C** to see Bypass.
- **Hold ⌥C** to see the picture without its LUT.

Let go and the window goes back. While you hold a key, a badge on the picture and the window title say what you're
comparing with.

### See what's happening to the color

Choose **Color ▸ Show/Hide Transform Chain** (⌥⌘4), or **Show Transform Chain…** in the display control. The
**Transform chain** panel shows each step from the file to your screen:

- **Source:** the file's color, and whether the file stated it or Manifold assumed it.
- **Transform:** the display mode and what it's doing.
- **Display:** your display, from its macOS color profile.
- **Headroom:** for HDR, how much brighter than SDR white the display can show, for example "HDR headroom 8.97×
  (all of it)".

A correction or LUT is marked in the panel and in the window title, so a changed picture is never silent.
*Detail: the guide's "Reading the transform chain".*

### Judge the picture on a desk display

Reference mode aims for the light a reference monitor would show. It needs to know about your display, in the
**This display** part of the Transform chain panel:

- **If your display isn't calibrated to BT.1886** (most desk displays), leave **This display is calibrated to BT.1886
  (Rec. 709)** unchecked. Enter your display's white and black levels from its calibration report in **Display white**
  and **Display black**, if you have them.
- **If your display is hardware-calibrated to BT.1886,** check the box. Manifold then sends the picture unchanged.

> **Only check it if the display really is calibrated to BT.1886.** Manifold trusts the setting. If it's wrong,
> Reference mode will be wrong and nothing will tell you.

These settings are remembered for each display, and they apply to SDR in Reference mode only.
*Detail: the guide's "Reference mode and display calibration".*

### HDR

PQ and HLG files show as HDR when HDR is on for the display in macOS. The **Headroom** line in the Transform chain
panel says how much brightness the display offers, in multiples of SDR white: "8.97×" is 8.97 times as bright.
"(all of it)" means Manifold is using everything the display offers; "available, none in use" means HDR is on for the
display but nothing on screen is using it yet; "display is in SDR mode" means HDR is off for that display.

- In **macOS** mode, macOS fits the HDR picture to your display, as QuickTime does.
- In **Reference**, HDR is shown at its true brightness, and anything brighter than the display can show clips.
- **The scopes always show the file**, whatever the mode.

*Detail: the guide's "HDR in the window".*

### Fix a file that's tagged wrong

If a file or stream says the wrong color, or none, correct it from **Tags** in the controls:

1. Click **Tags**.
2. Choose the right color: **Rec.709 (SDR)**, **Rec.2020 PQ (HDR10)**, **Rec.2020 HLG**, **P3-D65 PQ** or
   **Rec.2020 SDR**.

**Auto** goes back to what the file says. **Reset to File's Tags** (or **Reset to Stream's Tags**) does the same, in
the control and in the Color menu. **Next Tag Override**, in both places too, steps to the next correction in the
list, and back to Auto after the last.
The control and the window title show when a correction is on, and the scopes and SDI output follow it.

If a file's video range is wrong, set **Range** in the Inspector (⌘I) to **Full** or **Legal**. While it isn't
**Auto**, the Inspector's Range line reads "→ Full (set)" in yellow and the window title adds "Range: Full (set)".
**Auto** goes back to what the file says. Like a tag correction, it lasts until you open another file.

With the file name showing (**N**), Bypass, a tag correction and a range setting appear after the name, in the
title's words.

- On a file, a correction lasts until you open another file.
- On a saved stream, choose **Save … to “stream name”** to use it every time you connect.

*Detail, including changing one tag at a time: the guide's "Overriding a source's color tags".*

### Use a LUT

1. Click **Tags** and choose **Load LUT…**.
2. Choose a .cube file.

The LUT changes the picture, so the scopes, SDI output and exported frames see it too. It stays on when you open
another file.

- **LUT Outputs** says what color the LUT produces. Leave it at **Same as Source (no change)** for looks and creative
  LUTs. Change it only for a LUT that converts to another color space, such as log to Rec. 709, or Rec. 709 to PQ.
- **Bypass LUT** turns it off without unloading it. **Remove LUT** unloads it.
- **Recent LUTs** brings back a LUT you've used, with its LUT Outputs setting.

LUTs made to calibrate one particular monitor aren't supported here. *Detail: the guide's "LUTs".*

### Quick answers

- **"It looks different in QuickTime."** Switch to **macOS** to see what QuickTime shows. Hold **C** to
  compare with Reference.
- **"I want to judge the grade on my desk display."** Use **Reference**, and set up **This display** honestly.
- **"The scopes didn't change when I switched modes."** That's right. Scopes measure the picture, not your screen.

For more, see the guide's *Quick answers*.
