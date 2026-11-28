## Getting started

Manifold plays video files and live streams so you can check them: the picture with accurate color, scopes that
measure it, and output to a reference monitor over SDI or HDMI. This chapter gets you from installing it to playing
your first file.

### What you need

- A Mac with Apple silicon, running macOS 15 or later.
- For SDI or HDMI output (optional): a Blackmagic DeckLink or UltraStudio device and Blackmagic Desktop Video. See
  *SDI and HDMI output*.
- For NDI sources (optional): the NDI runtime. See *Live streams*.

### Install Manifold

1. Open the Manifold disk image (.dmg).
2. Drag **Manifold** onto the **Applications** folder.
3. Open Manifold from your Applications folder.

### Your trial and your license

Manifold runs as a free trial for 7 days from the first time you open it. To see how many days are left, choose
**Manifold ▸ Settings…** (⌘,) and click **License**. The status reads, for example, "Trial — 5 days left".

**To activate a license:**

1. Choose **Manifold ▸ License…**.
2. Paste your whole key, including "MNFL-", into the key field.
3. Click **Activate**.

Manifold says "Activated. Welcome!" when it's done. If your Mac is offline, it activates anyway and finishes
registering the next time it can reach the license server.

When the trial ends, the window shows "Your Manifold trial has ended". Paste your key there and click **Activate**.
Need a key? Visit graviton.tools.

**Using your license on more than one Mac.** A license works on up to 4 Macs.

- **On a new Mac,** just activate there with the same key.
- **Reinstalling Manifold, or activating again on the same Mac,** doesn't use up another Mac.
- **If every Mac on your license is used,** Manifold says so when you activate. Contact support@graviton.tools to
  free one.

If you're giving a Mac away, click **Deactivate on this machine** in Settings ▸ License to remove your license
from it.

Manifold doesn't need an internet connection to keep working. It checks your license from time to time when it can.

### The window

A new window shows "Open a file — or connect a stream", with two buttons:

- **Open…** chooses a file to play. You can also drag a file onto the window.
- **Connect Stream…** connects a live stream or an NDI source. See *Live streams*.

Once something is playing, the controls appear in a bar at the bottom of the picture. The bar fades after a couple of
seconds; move the pointer over the window to bring it back.

**To keep the controls showing,** click the pin at the right end of the bar (**Always show controls**), or choose
**View ▸ Always Show Controls** (⌥⌘T). To give the controls their own bar below the picture instead, choose
**Manifold ▸ Settings…**, click **General** and set **Controls** to **Below the picture**.

#### The controls

Hold the pointer over any button to see its name. From left to right in a wide window:

| Button | What it does | More in |
|---|---|---|
| Open… | Opens a file in this window. | *Opening files* |
| Play / Pause | Starts and stops playback. | below |
| Mute | Mutes the sound. Hold the pointer here to show the volume slider. | below |
| Loop playback | Plays the file over and over. | below |
| Framing guides | Safe zones and aspect ratio guides over the picture. | *Scopes and framing guides* |
| Subtitles | Shows subtitles from an .srt file. | *Opening files* |
| Inspector | Shows details about the file: format, color, audio tracks. | *Opening files* |
| Edit in Flip | Opens the file in Flip, if you have it. | *Opening files* |
| Refresh metadata | Reads the file's metadata again, for example after it changed on disk. | *Opening files* |
| Export Frame… | Saves the frame on screen as an image. | *Export* |
| Share Frame… | Sends the frame on screen through the macOS share menu. | *Export* |
| Audio track | Chooses which audio track you hear, when the file has more than one. | *Opening files* |
| Show or hide scopes | Shows the scopes below the picture. | *Scopes and framing guides* |
| DeckLink output | Starts and stops SDI or HDMI output. | *SDI and HDMI output* |
| Streaming | Connects and disconnects live streams and NDI sources. | *Live streams* |
| Tags | Shows the file's color tags and lets you correct them or load a LUT. | *Color and display modes* |
| Display transform | How the picture is shown on your screen: macOS, Reference or Bypass. | *Color and display modes* |
| A/V | Moves a live stream's sound earlier or later. Shown only while a stream plays. | *Live streams* |
| Always show controls | Keeps the controls showing. | above |

In a narrower window, some of these move into the **More** menu (**…**) so the rest still fit. When something in the
More menu is on, such as loop or subtitles, its icon turns to the highlight color.

### Play a file

| To | Press |
|---|---|
| Play or pause | Space |
| Play backward; press again for faster | J |
| Stop | K |
| Play forward; press again for faster | L |
| Step one frame (hold K, then press J or L); keep holding to play at half speed | K + J or K + L |
| Go back or forward one frame | ← or → |
| Go back or forward one second | ⇧← or ⇧→ |
| Go to the start or the end | Home or End (or ⌥← or ⌥→) |
| Turn looping on or off | ⌘L |
| Turn the volume up or down | ⌘↑ or ⌘↓ |
| Mute or unmute | ⌥⌘↓ |

You can also drag the playhead along the scrubber. Playback pauses while you drag and carries on when you let go.

These are the default keys. To change them, choose **Help ▸ Keyboard Shortcuts…**. See *Keyboard shortcuts*.

#### Go to a timecode

1. Click the timecode on the left of the controls, or just start typing numbers.
2. Type the timecode. To move by an amount instead, start with **+** or **−**.
3. Press Return to go there, or Esc to cancel. Delete removes the last digit.

If you type a time outside the file, Manifold goes to the first or last frame and says so.

#### Change what the time shows

Click the time on the right of the controls to switch both readouts between the file's timecode, a frame count and
the time elapsed. If a file has no timecode, Manifold shows the time elapsed.

A small icon at the corner of the timecode means the timecode doesn't come from the file's timecode track. Hold the
pointer over it to see where it comes from.

### Work with more than one window

Choose **File ▸ New Window** (⌘N) to open another window. Each window has its own file, scopes and display settings.

- **Only one window plays at a time.** In the others, the play controls are dimmed. Click a window to play there.
- **SDI or HDMI output and a live stream belong to one window at a time.** Another window shows, for example,
  "DeckLink output is running in “MyClip.mov”. Turn it off there to play here."

### Settings and shortcuts

- **Manifold ▸ Settings…** (⌘,) holds Manifold's preferences, in seven panes. See *Settings*.
- **Help ▸ Keyboard Shortcuts…** lists every shortcut, and lets you change them. See *Keyboard shortcuts*.

### Get help

- **Help ▸ Manifold User Guide** opens this guide. **Help ▸ Sync and Color Guide** explains live stream sync and color
  management in depth.
- **Help ▸ Export Diagnostics…** saves a text file you can send to support when something goes wrong. See
  *Troubleshooting*.

### Updates

When Manifold opens, it checks whether a newer version is out. It says nothing unless there is one. Then it shows
"Manifold 0.9.6 is available", for example, with what's new:

- **Download** opens the download page in your browser. Install the new version as you installed this one.
- **Not now** carries on with the version you have.

To check at any time, choose **Manifold ▸ Check for Updates…**. To see which version you have, choose
**Manifold ▸ About Manifold**.
