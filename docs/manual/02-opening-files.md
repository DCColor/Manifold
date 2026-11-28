## Opening files

### Open a file

- **Choose File ▸ Open…** (⌘O), or click **Open…** in the controls.
- **Drag a file** from the Finder onto the picture. It replaces what that window was showing.
- **Choose File ▸ Open Recent** to open a file you've played before. **Clear Menu** empties the list.

An empty window is always used first. Otherwise, File ▸ Open… opens the file in the window you're using. To open
each file in a window of its own, choose **Manifold ▸ Settings…**, click **Files** and set **Open files in** to
**A new window**. Dragging a file onto a window always replaces that window's file.

#### Make Manifold the app that opens a type of file

1. Choose **Manifold ▸ Settings…** and click **Files**.
2. Under **Opening Files**, find the type, for example **MXF files** or **QuickTime movies**.
3. Click **Use Manifold**.

Manifold can take a file type but can't hand it back. To change it later, select a file of that type in the Finder,
choose **File ▸ Get Info** (⌘I) and change **Open with**.

### What Manifold opens

- **Movies:** QuickTime (.mov), MP4 and MXF files, and other movie formats macOS can play.
- **Audio files:** WAV, AIFF, MP3, M4A and AAC.
- **Still images:** PNG, JPEG, TIFF, HEIC, AVIF, EXR, camera raw and other formats macOS can read. DPX isn't
  supported.

Some professional formats, such as AVC-Intra, XAVC, IMX, DVCPRO HD and ProRes RAW, need Apple's **Pro Video
Formats**. To check whether you have them, choose **Manifold ▸ Settings…** and click **Sources**. If they aren't
installed, click **Download Pro Video Formats…**, install them and open Manifold again. MXF and DNxHR files don't
need them.

### Still images and audio files

**A still image** shows without a scrubber: the controls read "Still image" with its size and whether it's SDR or
HDR. Play, loop, the audio track, captions, Export Frame and Share Frame aren't available, and the color controls are
dimmed. The scopes measure the image. SDI and HDMI output send black while a still is open.

**An audio-only file** shows a card with its name, format, channels, sample rate and length. It plays like a movie,
with the scrubber, play, loop, volume and the audio track. The video scopes are blank, and the **Audio Meters** scope
shows its levels. The time readout can't show frames, and the arrow keys don't step frames. With SDI or HDMI output
on, the card and the sound go to your monitor too.

### See details about a file

Click **Inspector** in the controls, or press **⌘I** (**View ▸ Show/Hide Inspector**). The Inspector shows:

- the file name, in full (a long name wraps onto more lines), codec, size, frame rate and scan (progressive or
  interlaced);
- the start timecode, and where it came from when it isn't the file's timecode track;
- the color the file says it is, and HDR information when the file has it;
- each audio track, and any captions or chapters in the file;
- when the file was made and changed.

Values the file doesn't actually state are shown in gray italics. An orange line means the file can't be shown
perfectly on this Mac, and says why.

### Choose the audio track you hear

When a file has more than one audio track, click **Audio track** in the controls and choose one. You can also click
a track in the Inspector. The speakers, the audio meters and SDI output all follow the track you choose.

### Interlaced files

For an interlaced file, a **Fields** control appears beside the display control, and **Color ▸ Fields** has the same
choices:

- **Both fields (Weave)** shows both fields together, as stored.
- **Field 1** and **Field 2** show one field at a time.
- **Deinterlace** shows a deinterlaced picture.

These change only how the window shows the file. The scopes, SDI output and exported frames always use the frame as
stored. While a single field is showing, the picture is labeled, for example "FIELD 1 · DISPLAY ONLY".

### Subtitles

1. Click **Subtitles** in the controls (or choose **More ▸ Subtitles ▸ Load Subtitles…**).
2. Choose an .srt file.

Click **Subtitles** again to hide or show them. The arrow beside it has **Load different subtitles…**, **Clear
subtitles** and the position: **Title-safe** or **Bottom edge**.

### Window size and full screen

- **View ▸ 100%** (⌘1), **75%** (⌘2), **50%** (⌘3) and **25%** (⌘4) size the picture against the file's own size.
  **Fit to Screen** (⌘0) makes it as large as the screen allows. Drag the window's edge for any other size.
- **Press ⌘F** to enter or leave full screen.
- **Press N** to show or hide the file name over the picture (**View ▸ Show/Hide File Name**). It also shows Bypass, a tag correction and a range setting when one is on. A name too long for the window is shortened in the middle.

To choose the size new windows open at, choose **Manifold ▸ Settings…**, click **General** and set **Window size for
new windows**.

### When the file changes

If the file changes on disk while it's open, the **Refresh metadata** button turns to the highlight color. Click it to
read the file's metadata again: its tags, timecode and the Inspector. If the color tags changed, the picture follows
them. A file whose picture or sound was rewritten needs opening again.

**Edit in Flip** opens the file in Flip, which edits a file's color tags, timecode, audio layout and other metadata and
writes them back to the file. If Flip isn't installed, Manifold offers to get it. When you come back, click **Refresh
metadata** to see the changes.
