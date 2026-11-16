# Manifold (next version), draft

**Version and build to be set at release · Draft, 15 November 2026**

## New

### Markers

- **Mark the frame on screen with M,** even while playing. A marker has a name, notes, keywords, a duration and one of Resolve's 16 colours. There is one marker per frame. ⇧M edits a marker, ⌥M adds one and opens it for editing, and I and O mark a span.
- **Markers are saved per file on this Mac,** never written into your media, and follow the file if it's renamed or moved. You can turn that off in Settings ▸ Files.
- **The Markers list** sits in a scope slot or in its own window (⌃⌘M), with a thumbnail for each marker. Click a marker to jump to it; double-click to edit it.
- **Round trip with DaVinci Resolve.** File ▸ Export Markers… writes a marker EDL that Resolve imports onto a timeline at the file's own timecode, frame-exact, drop-frame included. File ▸ Import Markers… brings Resolve's markers back. Markers also export as CSV and plain text. Keywords don't travel through EDLs (a Resolve limit).
- **Files without timecode** count markers from 00:00:00:00. If your Resolve timeline starts at 01:00:00:00 (Resolve's default), set the marker start timecode in the Markers slot's gear menu before exporting, so the markers land on the right frames. When you import an EDL that's an hour off, Manifold offers to shift it.
- **View ▸ Show Markers** hides markers without deleting anything.

### Sharing and export

- **Share Frame… (⇧⌘E)** sends the current frame as a JPEG through the macOS share menu. HDR (PQ/HLG) pictures are tone-mapped to SDR for sharing; Export Frame still saves the full-quality PNG, HDR included.

<!-- Built in the same work and not yet written up here (docs/ROADMAP_IDEAS.md): the "(SDR)" menu title and " SDR" file name for
     HDR pictures; frame file names "<clip> HH-MM-SS-FF" and "<stream> <date time>"; Settings ▸ Frame Export ▸ "Put exported frames
     in a folder per clip"; "Export Frame…" naming; greyed inactive DeckLink sub-devices; Open Desktop Video Setup…. -->
