## SDI and HDMI output

Manifold can send the picture and sound to a reference monitor through a Blackmagic DeckLink or UltraStudio device.

### What you need

- A Blackmagic DeckLink or UltraStudio device, connected to your Mac.
- Blackmagic **Desktop Video**, installed.

To check, choose **Manifold ▸ Settings…** and click **DeckLink Output**. The **DeckLink** line shows what Manifold
found, for example "1 device (Desktop Video 16.4.0)".

- **"Desktop Video not installed"** or **"too old":** click **Download Desktop Video…** or **Update Desktop Video…**,
  install it and open Manifold again.
- **"No device detected":** connect the device and check it appears in Blackmagic's Desktop Video Setup.

**Open Desktop Video Setup…** opens Blackmagic's setup app, when it's installed.

### Start and stop output

Click **DeckLink output** (the TV button) in the controls, or press **⇧⌘D** (**File ▸ Start/Stop DeckLink Output**).
The button turns green while output is on. Do the same again to stop.

To start output whenever Manifold opens, turn on **Enable output on launch** in **Settings ▸ DeckLink Output**.

### Choose the device, sound and mode

Click the arrow beside the TV button:

- **Output device:** which device, or which connector, to use. A connector your card's setup has made unusable is
  dimmed, with the reason.
- **Audio destination:** **SDI (follows video)** sends the sound with the picture. **Computer** plays it on the Mac.
  This lasts until you quit. To set where sound goes each time Manifold opens, use **Audio at launch** in
  **Settings ▸ DeckLink Output**.
- **Output mode:** **Follow source** picks a mode that matches the file's size and frame rate. Or choose a mode
  yourself, such as 1080p23.98 or 2160p25.

Under **Signal**, the menu shows what's going out, for example "1080p23.98 · 10-bit 4:2:2 · Rec. 709 · SDR", and any
warning about the source, such as a frame rate with no matching output mode.

#### How Follow source picks a mode

In **Settings ▸ DeckLink Output**:

- **SDI scaling:** **Fit to mode** picks the closest-size mode at the source's frame rate and scales the picture to
  fill it, keeping its shape, with black around it. **1:1 pixels** picks the smallest mode that holds the picture
  without scaling; a picture larger than every mode is scaled down.
- **SDI output modes:** **HD/UHD only**, or **Include DCI** to add 2048×1080 and 4096×2160.

### What goes out

- **Always the picture,** with any color correction or LUT, and never the window's display mode or display settings.
  What you see in Reference mode on your desk is not what decides the signal.
- **Each frame is labeled** with its color (SDR, PQ or HLG), so a monitor that follows the signal switches on its own.
  For PQ, Manifold sends HDR information from the file, or standard values when the file has none. The menu's Signal
  section says which.
- **The output is 10-bit 4:2:2,** whatever the file's own color resolution.
- **A still image sends black.** An audio-only file sends its card, with its sound.

*Detail: the Sync and Color Guide's "What reaches SDI and HDMI".*

### Sound and live streams

With **SDI (follows video)**, the SDI sound follows the audio track you've chosen, and a live stream's audio offset
moves it too. See *Live streams*.

### If output stops or won't start

| Message | What to do |
|---|---|
| "DeckLink output is in use by another application (for example DaVinci Resolve)." | Quit or stop output in the other app, then start output again. |
| "… is inactive in the card's current connector mapping." | Choose another device under Output device, or change the mapping in Desktop Video Setup, then start output again. |
| "SDI sound stopped; restart output" | Stop output and start it again. |
| "DeckLink output is running in “…”. Turn it off there to play here." | Another window has the output. Stop it there, or play in that window. |

See also *Troubleshooting*.
