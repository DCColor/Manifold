## Export

Manifold exports frames and markers. It doesn't export video clips.

### Save the frame on screen

Press **⌥⌘E**, choose **File ▸ Export Frame…**, or click **Export Frame…** in the controls.

Manifold saves the frame straight away, with no dialog:

- **As a 16-bit PNG,** at the file's full quality, HDR included, tagged with its color.
- **In your export folder,** which is the Desktop until you choose another.
- **Named after the clip and its timecode,** for example "MyClip 01-02-14-05", or after the stream and the date and
  time. Saving the same frame again adds " 2" rather than replacing the file.

A short message at the top of the picture names the saved file, with **Show in Finder** to go to it. If the frame
couldn't be saved, the message says why, for example that the folder isn't there anymore or the disk is full, and what
to do.

The frame is the picture, with any color correction or LUT. It isn't changed by the window's display mode.

**To choose the export folder,** choose **Manifold ▸ Settings…**, click **Files**, and under **Frame Export** click
**Choose…**. **Use Desktop** goes back to the Desktop. Turn on **Put exported frames in a folder per clip** to keep
each clip's frames in a folder named after it.

### Share the frame on screen

Press **⇧⌘E**, choose **File ▸ Share Frame…**, or click **Share Frame…** in the controls. Manifold makes a JPEG and
opens the macOS share menu, so you can send it by Mail, Messages, AirDrop and so on.

For an HDR picture the item reads **Share Frame (SDR)…**: the shared JPEG is converted to SDR, and its name ends in
" SDR". To keep the HDR picture, use Export Frame.

If the frame can't be shared, a message at the top of the picture says so. Canceling the share shows nothing.

### Export markers

**File ▸ Export Markers…** saves a file's markers for DaVinci Resolve, Premiere Pro, a spreadsheet, plain text, or a
YouTube or ffmpeg chapter list. See *Markers*.

### For support

- **Help ▸ Export Frame for Support…** saves the frame on screen with measurement files that help support see exactly
  what Manifold is showing and sending. You choose where to save it; a message then names the saved file, as Export
  Frame does. It includes the picture, so share it only with people allowed to see the footage.
- **Help ▸ Export Diagnostics…** saves a text file about your Mac and Manifold. See *Troubleshooting*.

### Move your settings to another Mac

See *Settings*: **Export Shortcuts and Streams…** moves your keyboard shortcuts and saved streams.
