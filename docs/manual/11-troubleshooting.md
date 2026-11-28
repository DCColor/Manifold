## Troubleshooting

### Send a report to support

Choose **Help ▸ Export Diagnostics…**. Manifold writes a plain text file you can send to support@graviton.tools.

1. Choose your **Connection**: **Wired (ethernet)**, **Wi-Fi** or **Other / not sure**. Manifold won't export
   without it.
2. Optionally, add your **City or region** (nothing more precise) and **What were you doing?**: what you were
   watching, what went wrong, and roughly when.
3. Turn on **Include file names** if the problem is with a particular file. Folder names are never included.
4. Click **Export…** and choose where to save the file.

The file holds your Manifold version, your Mac and display details, and Manifold's log. Stream passphrases, the
private parts of stream addresses, IP addresses, folder paths, file names (unless you include them), display serial
numbers and your Mac's name are removed. Markers are never included.

If the problem is with the picture itself, also choose **Help ▸ Export Frame for Support…** while the frame is on
screen. It includes the picture, so share it only with people allowed to see the footage.

### Files

| Problem | What to do |
|---|---|
| A professional format won't open (AVC-Intra, XAVC, IMX, DVCPRO HD, ProRes RAW) | Install Apple's Pro Video Formats: **Settings ▸ Sources ▸ Download Pro Video Formats…**, then open Manifold again. |
| A DPX image won't open | DPX isn't supported. |
| An orange line in the Inspector, or an orange message about color resolution or 8-bit color | This Mac can't show that file perfectly. The message says what's affected. |
| "This file's audio track couldn't be read — playing video only." | The picture plays without sound. Send a diagnostics report with the file name included. |
| A Dolby Vision message | Some Dolby Vision files have no picture Manifold can show correctly. |

### Color

- **"It looks different in QuickTime."** Switch to **As macOS Shows It** (⌥⌘1). Very saturated PQ colors can still
  differ slightly from QuickTime; colors your display can show match.
- **"The scopes didn't change when I switched modes."** That's right: scopes measure the picture, not your screen.
- **"An override is grayed out."** PQ and HLG need Rec. 2020 or P3-D65 primaries, so other combinations can't be
  shown as stated.
- **"A LUT won't load."** Manifold says why. It loads .cube LUTs only, and not LUTs made to calibrate one monitor.

For more, see the Sync and Color Guide's *Quick answers*.

### Live streams

| Problem | What to do |
|---|---|
| No NDI sources appear, or "No NDI source found on this network within 5 seconds." | Check that an NDI sender is running on the same network, that **Settings ▸ Sources** shows the NDI runtime installed, and that Manifold is allowed in System Settings ▸ Privacy & Security ▸ Local Network. |
| "Couldn't connect to “…”." (NDI) | Check that the NDI sender is still running, then choose it again. |
| "Nothing answered at …" (SRT) | The sender isn't running, or a firewall is blocking it. Check the address and port. |
| "Connected, but no video is arriving from the sender." | The connection works, but the sender isn't sending yet. |
| "That stream is … — Manifold's SRT support is H.264 and HEVC only." | Set the sender to H.264 or HEVC. |
| "The stream server refused the connection" (WHEP) | The server turned Manifold away. Often the broadcast hasn't started; the message may include the server's reason. |
| "Couldn't find a network route to the stream (it may be behind a firewall)." | Check your network and firewall. |
| The message disappeared before you read it | Messages close after a few seconds. Connect again to see it. |
| Sound and picture are out of sync | Calibrate the stream. See *Live streams*. |
| "Can move sound earlier by at most … ms on this stream right now." | Correct the rest at the sender. |

Interlaced streams go out over SDI as progressive, with both fields in each frame.

### SDI and HDMI output

| Problem | What to do |
|---|---|
| "Desktop Video not installed" or "too old" | Install or update Blackmagic Desktop Video from **Settings ▸ DeckLink Output**, then open Manifold again. |
| "No device detected" | Connect the device and check Blackmagic's Desktop Video Setup sees it. |
| "DeckLink output is in use by another application" | Stop output in the other app, such as DaVinci Resolve. |
| "… is inactive in the card's current connector mapping" | Choose another device, or change the mapping in Desktop Video Setup. |
| "SDI sound stopped; restart output" | Stop output and start it again. |
| The DeckLink button is dimmed | Another window has the output, or Desktop Video needs attention. Hold the pointer over the button to see why. |
| The monitor shows black | A still image sends black. Otherwise, check the Signal section of the DeckLink menu for a warning. |

Known limitations:

- Over HDMI, an HLG picture goes out without its HLG signal. SDI carries HLG.
- 2160p above 60 needs dual-link SDI. In a single-link setup, use a 1080p mode for 100 and 119.88.
- Very rarely, one frame can repeat at the start of playback at 59.94, or the picture can pause for a moment.
- Not tested with a genlocked DeckLink card (house reference).

### License

| Message | What it means |
|---|---|
| "Your Manifold trial has ended" | Enter a license key to keep using Manifold. |
| "This license key was not recognized. Check it and try again." | Check you pasted the whole key, including "MNFL-". |
| "This license is already active on … of … machines." | Every Mac on your license is used. Contact support@graviton.tools to free one. |
| "Could not reach the license server. Check your connection and try again." | Check your internet connection. |
| "Activated. Manifold will finish registering this Mac the next time it can reach the license server." | You're activated. Nothing to do. |
| "Your license couldn't be read" | macOS refused Manifold access to its keychain item. This doesn't mean your license is gone. Send a diagnostics report. |
| "This license is no longer valid." | Contact support@graviton.tools. |

### Updates

- **"Couldn't check for updates"**: Manifold couldn't reach the update server. Check your connection, or try
  **Manifold ▸ Check for Updates…** later.
