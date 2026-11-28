## Settings

Choose **Manifold ▸ Settings…** (⌘,). Settings has seven panes: General, Files, Playback, Scopes & Guides, DeckLink
Output, Sources and License. It opens on General.

### General

| Setting | What it does | Default |
|---|---|---|
| **Highlight color** | The color of the playhead, controls, on-picture labels and correction text. **Use Default Highlight** puts it back. Green is also used for live states, so Manifold warns if you pick a color close to it. | Yellow |
| **Controls** | **Overlay (floating)** floats the controls over the picture and hides them when the pointer is still. **Below the picture** gives them a bar of their own below the picture. Changes every open window. | Overlay (floating) |
| **Window size for new windows** | The size a new window opens at: **Fit when opened**, **100%**, **75%**, **50%**, **25%** or **Fit to Screen**. It follows the last size you choose in the View menu. Doesn't change open windows. | Fit when opened |
| **Open Keyboard Shortcuts…** | Opens the Keyboard Shortcuts window. | |
| **Export Shortcuts and Streams…**, **Import Shortcuts and Streams…** | Move your keyboard shortcuts and saved streams to another Mac. See below. | |
| **Restore from Backup…** | Puts back the shortcuts you had before an import. Appears once a backup exists. | |

#### Move your shortcuts and saved streams to another Mac

1. Click **Export Shortcuts and Streams…**.
2. Choose what to include: **Keyboard shortcuts** and **Saved streams**.
3. If you include saved streams, type a password of at least 12 characters, twice. The file is encrypted with it.
4. Click **Export…** and save the file.
5. On the other Mac, click **Import Shortcuts and Streams…** and choose the file, or drag the file onto a Manifold window.

> **The password can't be recovered.** Without it, nobody can open the file, including Graviton.

When you import, Manifold shows what will change before it changes anything:

- **Merge** adds the file's shortcuts to yours. **Replace All** makes your shortcuts the file's, and resets the ones the
  file doesn't mention.
- If a key is already used on this Mac, you choose which command keeps it.
- Saved streams are only added. Streams you already have are never changed.

Manifold backs up your shortcuts before an import changes them. **Undo Import** reverses it straight away, and
**Restore from Backup…** reverses it later. Only shortcuts are backed up, so keep your exported file if you might want
your streams back.


### Files

| Setting | What it does | Default |
|---|---|---|
| **Open files in** | **This window** or **A new window**, for File ▸ Open… and the Open button. An empty window is always used first, and dragging a file onto a window always replaces it. | This window |
| **… open in** (one row per file type) | Shows which app opens that type of file. **Use Manifold** makes Manifold open it. To change it back, use the Finder's Get Info. | |
| **Folder** (Frame Export) | Where Export Frame saves. **Choose…** picks a folder, **Use Desktop** goes back to the Desktop. | Desktop |
| **Put exported frames in a folder per clip** | Saves each clip's frames in a folder named after the clip or stream. Share Frame isn't affected. | Off |
| **Remember markers between sessions** | Saves each file's markers on this Mac. Turned off, markers last only while the file is open. | On |
| **Delete All Stored Markers…** | Deletes every file's saved markers and thumbnails. Can't be undone. Exported files aren't touched. | |

### Playback

| Setting | What it does | Default |
|---|---|---|
| **Autoplay on open** | Starts playing as soon as a file opens. | Off |
| **Playhead** | **Ball** or **Line**. Applies to every window. | Line |
| **Playhead color** | For the line: **Same as highlight**, or **Custom** with a color you choose. | Same as highlight |

### Scopes & Guides

| Setting | What it does | Default |
|---|---|---|
| **Scope scale** | **8-bit (0–255)**, **10-bit (0–1023)** or **IRE (0–100)**, for SDR pictures. PQ and HLG pictures use their own scales. | 10-bit (0–1023) |
| **Scope brightness** | Brightens or dims every scope's trace, on top of each scope's own intensity. The number is a multiple of normal. | 1.0× |
| **Grid brightness** | How bright the scale lines (the graticule) are. At the lowest setting the lines go and the labels stay. The audio meters don't use it. The number is a multiple of normal. | 1.0× |
| **Marker text size** | **Small**, **Medium** or **Large**, for the Markers list. | Medium |
| **Broadcast safe zone color**, **width**, **opacity** | How the action-safe and title-safe boxes are drawn. Turn them on, and set their sizes, in the Framing Guides popover. | White, 1 pt, 75% |
| **Color outside the guide**, **Opacity outside the guide** | How the picture outside a frame guide is darkened. | Black, 85% |
| **Guide line color**, **Guide line width** | The line around a frame guide. | White, 2 pt |
| **Social safe zone color**, **width**, **opacity** (under **Social media safe zones**) | How the social media safe zone lines are drawn. | Yellow, 1 pt, 75% |

### DeckLink Output

| Setting | What it does | Default |
|---|---|---|
| **DeckLink** | Shows the Blackmagic devices and Desktop Video version Manifold found, and buttons to download or update Desktop Video when needed. | |
| **Open Desktop Video Setup…** | Opens Blackmagic's setup app. Appears when it's installed. | |
| **Enable output on launch** | Starts output when Manifold opens, if a device is connected. | Off |
| **Audio at launch** | Where sound goes when Manifold opens: **SDI, with the picture** or **Computer**. Change it for this session in the DeckLink menu. | SDI, with the picture |
| **SDI scaling** | How Match source picks a mode: **Fit to mode** scales the picture to fill the closest mode; **1:1 pixels (scale down only if larger)** picks a mode that holds the picture unscaled. | Fit to mode |
| **SDI output modes** | **HD/UHD only**, or **Include DCI** to add 2048×1080 and 4096×2160 modes. | HD/UHD only |

See *SDI and HDMI output*.

### Sources

| Setting | What it does |
|---|---|
| **NDI Runtime** | Shows whether the NDI runtime is installed. **Install NDI Runtime…** gets it; open Manifold again afterwards. |
| **Pro Video Formats** | Shows whether Apple's Pro Video Formats are installed. They add AVC-Intra, XAVC, IMX, DVCPRO HD, uncompressed and ProRes RAW. MXF and DNxHR files don't need them. |

### License

Shows your trial or license, and where you enter a key. See *Getting started*.

| Item | What it does |
|---|---|
| **Status** | For example "Trial — 5 days left", "Licensed to …", or "Trial expired". |
| **License key**, **Activate** | Paste your whole key, including "MNFL-", and click Activate. |
| **Deactivate on this machine** | Removes your license from this Mac, for example before you give it away. |
