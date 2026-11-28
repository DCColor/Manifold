## Markers

Markers note a frame or a span in a video file: a name, notes, keywords and a color. You can send them to DaVinci
Resolve or Premiere Pro, or export them as a chapter list, a spreadsheet or plain text.

Markers work on video files. Live streams, still images and audio-only files don't have markers.

### Add a marker

**To mark the frame on screen,** press **M** (**Mark ▸ Add Marker**). It works while the file plays.

**To add a marker and name it right away,** press **⌥M** (**Mark ▸ Add Marker and Edit…**). The marker opens for
editing as soon as it's added.

There's one marker per frame. Pressing M on a frame that already has a marker opens that marker instead of adding a
second one.

**To mark a span:**

1. Go to the first frame and press **I** (**Mark ▸ Mark In**).
2. Go to the last frame and press **O** (**Mark ▸ Mark Out**).
3. Press **M**. Manifold adds one marker covering the span and clears the In and Out.

To clear an In and Out without adding a marker, press **⌥X** (**Mark ▸ Clear In and Out**).

On the scrubber, each marker shows as a flag in its color, and a marker longer than one frame shows as a band. Click
a flag to go to it.

### Edit or delete a marker

**To edit a marker,** go to it and press **⇧M** (**Mark ▸ Edit Marker…**). This opens the marker at the playhead, or
the nearest one before it. You can also double-click a marker in the Markers list.

In the marker window you can set:

- **Time** and **Duration.** Type them as you would a timecode: digits fill from the right, so 100 is one second and
  1 is one frame. Start with + or − to move or lengthen by an amount. **End** shows where the marker finishes.
- **Name** and **Notes.**
- **Keywords.** Separate them with commas.
- **Color.** One of 16: Blue, Cyan, Green, Yellow, Red, Pink, Purple, Fuchsia, Rose, Lavender, Sky, Mint, Lemon,
  Sand, Cocoa and Cream. These are DaVinci Resolve's marker colors.

If you've set an In and Out, **Set Time and Duration from In and Out** makes the marker cover that span. Click
**Done** to keep your changes.

**To delete a marker,** go to it and choose **Mark ▸ Delete Marker**, click **Delete Marker** in the marker window,
or select it in the Markers list and press Delete.

Changes to markers can be undone with **Edit ▸ Undo** (⌘Z).

### Move between markers

- **⇧↑** goes to the previous marker, **⇧↓** to the next (**Mark ▸ Previous Marker** and **Next Marker**).
- In the Markers list, click a marker to go to it.

### The Markers list

The Markers list shows every marker in the file, with a thumbnail of its frame. It can sit in the scopes or have a
window of its own.

- **In the scopes:** open the scopes (⌥⌘S), click a scope's name and choose **Markers**.
- **In its own window:** choose **Mark ▸ Show Marker List** (⌃⌘M). The **Markers** window follows the window you're
  playing in.

In the list:

- Click a marker to go to it. Double-click it to edit it.
- Hold the pointer over a marker to see its color, timecode, name, the first line of its notes and its keywords.
- Right-click a marker to edit it, go to it, change its color, or delete it.
- Select a marker and press Delete to remove it. ⌘-click to select more than one.

The gear in the Markers scope has more:

- **Thumbnails** shows or hides the pictures. **Regenerate Thumbnails** makes them again. Thumbnails show the file's
  own picture, without a LUT or color override, and HDR is shown as SDR. They're for finding your place, not for
  judging the picture.
- The color swatches show only markers of the colors you choose. **Show All** shows every marker again.
- **Text size** (Small, Medium, Large) makes the list easier to read in a small scope. It's also **Marker text size**
  in **Settings ▸ Scopes & Guides**.
- **Open Markers Editor** opens the Markers window.
- **Import Markers…** and **Export Markers…**: see below.

The Markers window has the same controls in its toolbar: **Filter by Color**, **Regenerate Thumbnails**,
**Import…** and **Export…**.

**To hide markers without deleting them,** choose **View ▸ Show Markers** so it's unchecked. They come back when you
check it again, or when you add a marker. This applies in every window.

### Markers from your files

Some files carry markers of their own: QuickTime and MP4 chapters, and the Comment and Chapter markers Premiere Pro
writes when you export with markers included. Manifold shows them in the Markers list and on the scrubber, beside
your own markers.

They belong to the file, so you can't edit them in Manifold, and they're never written anywhere. **To make editable
markers from them:**

- For one: right-click it in the Markers list and choose **Convert to Marker**.
- For all of them: choose **Mark ▸ Convert All File Markers to Markers**.

Converting twice adds nothing new. A converted marker is one frame long, unless the file gives it a duration.
Premiere's colors carry over; chapters with no color become Blue.

- **To hide the file's markers,** choose **View ▸ Show File Markers** so it's unchecked.
- **To show only the file's markers,** click **From File** in the Markers scope's gear.

Only your own markers are exported. Convert file markers first if you want them in an export.

### Export markers

Choose **File ▸ Export Markers…**, pick a **Format** and click **Export**. **Export Markers…** is also in the Markers
scope's gear and, as **Export…**, in the Markers window.

| Format | Use it for |
|---|---|
| DaVinci Resolve Marker EDL (.edl) | Markers on a Resolve timeline. |
| CSV (.csv) | A spreadsheet. Keeps keywords. |
| Plain Text (.txt) | Notes you can read or paste anywhere. Keeps keywords. |
| Premiere Pro (XML) | A Premiere sequence with your clip and its markers. |
| Chapter List — ffmpeg (.ffmeta) | Chapters that ffmpeg can add to a file. |
| Chapter List — YouTube (.txt) | Chapters for a YouTube description. |

**To export markers for DaVinci Resolve:**

1. Choose **File ▸ Export Markers…** and set **Format** to **DaVinci Resolve Marker EDL (.edl)**.
2. Click **Export**.
3. In Resolve, choose **Timeline ▸ Import ▸ Timeline Markers from EDL**.

The markers land on the file's own timecode, frame for frame. An EDL has no place for keywords. To keep them, turn on
**Add keywords to notes**, which adds them to the end of each note.

**To export markers for Premiere Pro:**

1. Choose **File ▸ Export Markers…** and set **Format** to **Premiere Pro (XML)**.
2. Click **Export**.
3. In Premiere, choose **File ▸ Import** and open the file. It arrives as a sequence holding your clip and its markers.

Names, notes and durations carry over. Every marker arrives as a Comment marker, and a note's line breaks become
spaces. Manifold's 16 colors become the nearest of Premiere's 8. The XML file contains the full path to your media.
To keep keywords, turn on **Add keywords to comments**.

**To make chapters for YouTube:** export as **Chapter List — YouTube (.txt)** and paste the result into the video's
description. If the list breaks one of YouTube's chapter rules (the first chapter at 00:00, at least three chapters,
each at least 10 seconds long), Manifold tells you after the export.

Chapter lists count time from the file's first frame, not from its timecode, as YouTube and ffmpeg expect.

### Import markers from DaVinci Resolve

1. In Resolve, choose **Timeline ▸ Export ▸ Timeline Markers to EDL**.
2. In Manifold, open the same file and choose **File ▸ Import Markers…**.
3. Choose the EDL and click **Import**.

Manifold reports how many markers it imported and anything it skipped. Importing the same EDL twice adds nothing
new, and an import can be undone in one step with **Edit ▸ Undo**.

If the markers are an hour off from the file, for example because the timeline started at 01:00:00:00, Manifold
offers to shift them: click **Shift by** the amount shown, **Import As Is**, or **Cancel**.

Manifold imports marker EDLs from Resolve. It doesn't read Premiere, Final Cut Pro or Avid marker files.

### When a file has no timecode

A file without timecode starts at 00:00:00:00. Some files take their start from other information in the file, which
may not match your timeline. If the timeline you're sending markers to starts somewhere else, for example at
01:00:00:00 (Resolve's default), set the file's start before you export:

1. In the Markers scope, click the gear.
2. Under **Start timecode**, type the start and click **Set**.

Manifold then uses that start everywhere: the time readout, Export Frame names, markers and marker exports. **Reset**
goes back to the file's own start. **Start timecode** appears only when the file has no timecode of its own. If a
file has a timecode track, or timecode stored in the file, Manifold always uses it.

### Where markers are kept

Manifold saves each file's markers on this Mac. They're never written into your media, and they follow the file if
you rename or move it.

- **To stop saving markers,** for example on a shared Mac, choose **Manifold ▸ Settings…**, click **Files** and turn
  off **Remember markers between sessions**. Markers then last only while the file is open.
- **To delete every saved marker,** click **Delete All Stored Markers…** in the same place. This can't be undone.
  Files you've exported aren't touched.
