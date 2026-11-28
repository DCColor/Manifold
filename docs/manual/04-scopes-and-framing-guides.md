## Scopes and framing guides

### Show the scopes

Click **Show or hide scopes** in the controls, or press **⌥⌘S** (**View ▸ Show/Hide Scopes**). Three scopes appear in a strip
below the picture, and the window grows to make room.

- **To change a scope,** click its name at the top left and choose another.
- **To make the scopes taller or shorter,** drag the line along the top of the strip.

Each window keeps its own scopes. A new window starts with the scopes you set up last.

The scopes measure the picture: the file, with any color correction or LUT. They don't change with the display mode.
*Detail: the Sync and Color Guide's "The model in one paragraph".*

### The scopes

| Scope | What it shows |
|---|---|
| **Waveform** | Brightness across the picture, from left to right. |
| **Parade** | Red, green and blue side by side. |
| **YRGB Parade** | Brightness, red, green and blue side by side. |
| **Vectorscope** | Hue and saturation. |
| **CIE** | The picture's colors on a chromaticity chart, with the edges of Rec. 709, P3 and Rec. 2020. |
| **Audio Meters** | The level of each audio channel. |
| **Markers** | The file's markers. See *Markers*. |

#### Controls on each scope

Most scopes have, along their top edge:

- a **gear** with that scope's options;
- an **intensity** slider (the sun icon) that makes the trace brighter or dimmer;
- a **color well** that sets the trace color, and an arrow that resets it.

#### Waveform, Parade and YRGB Parade

The scale follows the picture: SDR is shown in code values or IRE, PQ in nits, and HLG in percent and nits. In the
gear, under **Vertical scale · transfer**, you can choose **Auto (follow source)** or a fixed scale. One setting covers
all three scopes. "(set)" after the scale in the header means you've chosen a fixed scale.

Under **Reference markers**, turn on **Marker 1** or **Marker 2** and type a level to draw a line at it.

Picking a trace color on Parade or YRGB Parade turns both parades one color. The reset arrow brings back red, green
and blue.

#### Vectorscope

In the gear:

- **Graticule reference:** **Fixed 709 (reference)** or **Source primaries**.
- **Target boxes:** **75%**, **100%**, or **75% + 100%**.
- **Graticule extras:** **Outer ring ticks** and **Skin tone line**.
- **Reference markers:** type a color (for example #FF8000 or 255,128,0) to mark where it falls.

#### CIE

In the gear, choose the chart (**u′v′ (1976)** or **xy (1931)**) and which gamut triangles to show: **709**, **P3**
and **2020**.

#### Audio Meters

Levels are in dBFS. When a channel clips, its clip light stays on: click it to reset that channel, or click **CLIP** to
reset them all. In the gear, turn on **Marker** to draw a line at a level you choose. The meters read sample peaks,
not true peaks.

### Scope settings for every window

Choose **Manifold ▸ Settings…** and click **Scopes & Guides**:

- **Scope scale:** **8-bit (0–255)**, **10-bit (0–1023)** or **IRE (0–100)**, for SDR pictures.
- **Scope brightness:** brightens or dims every scope's trace.
- **Grid brightness:** how bright the scale lines (the graticule) are. At the lowest setting the lines go and the labels stay.
- **Marker text size:** the size of the Markers list.

### Framing guides

Click **Framing guides** in the controls (or **More ▸ Framing Guides…**) to draw guides over the picture:

- **Broadcast safe zones:** action-safe and title-safe boxes. Set their sizes, as a percentage of the picture, in
  **Action** and **Title**.
- **Frame guide:** darkens the picture outside an aspect ratio and outlines it. Choose 1.33, 1.66, 1.77, 1.85, 2.0,
  2.35, 2.39 or 2.40, a social ratio (9:16, 1:1, 4:5, 2:3 or 3:2), or **Custom** with your own width and height.
  **None** turns it off.
- **Social media safe zones:** lines that mark where a platform puts its buttons and captions. Choose a **Platform preset**
  (TikTok, Reels or Shorts), or choose **Custom / Manual** and set **Top** and **Bot** yourself.

Framing guides apply to every window.

To change their colors, line widths and opacity, choose **Manifold ▸ Settings…** and click **Scopes & Guides**.
