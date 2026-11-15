# Markers on files, with a Resolve round trip: plan

Status: **v1 BUILT, NOT YET MEASURED IN THE APP** (2026-11-15). Plan written and decided the same day (§9); R0, R1 and R2
done by Robbie (§0.5, §1); v1 built as §10 lists; fixtures generated (§8.0). First attended feedback the same day (§12):
one marker per frame, the Markers window, thumbnails, transport-style timecode fields, Edit Marker, single-click jump;
all built, not yet re-tested in the app. Not committed. Where a claim rests on a file, its path and line are given; where it rests on nothing measurable here it says
**UNKNOWN** and names the step that settles it.

Scope: **files only** for v1. Live streams come later (timecode on streams is not always present, `docs/ROADMAP_IDEAS.md:263`).

Earlier record: `docs/ROADMAP_IDEAS.md:248-265` ("Timecoded markers with EDL export": source timecode, not elapsed
time; round-trips into Resolve without retyping). The keys were reserved in `docs/SHORTCUTS_AUDIT.md:323-324`.

Each section gives a **recommendation** first and **alternatives** after it. The decisions I need from you are collected
in §9.

---

## 0. What the reference files show

`docs/markers/frameio-reference/` holds Frame.io's exports of the same 11 comments on
`Offset_Ep066_Sofrware_Copying.mp4` (HEVC MP4, 23.976, 87 904 frames, per the `.fiojson` `asset` block). Read for this
plan, read-only.

### 0.1 Resolve EDL (`Offset_Ep066_Sofrware_Copying_Resolve.edl`)

```
TITLE: Offset_Ep066_Sofrware_Copying.mp4
FCM: NON DROP FRAME

001  001  C  V  01:00:11:22  01:00:11:22  01:00:11:22  01:00:11:22
@Robbie Carman, Nov 15 15 07:54pm
Need to update title - should be: Reverse Engineering In The Age Of A.I. |C:ResolveColorPurple |M:Robbie Carman |D:0

002  001  C  V  …
```

Byte-level (`od -c`): LF line endings, no CR anywhere, no BOM. Fields on the event line are separated by **two** spaces.
One blank line between events; the file ends with three LFs. Source in = source out = record in = record out.

What it shows:

- **Notes survive**, as the text before ` |C:`. All 11 are single-line.
- **`|M:` is the marker name field**, but Frame.io fills it with the **comment's author** ("Robbie Carman" on all 11),
  because a Frame.io comment has no name. Imported as is, every marker is called "Robbie Carman".
- **`|D:` is a duration in frames**, and Frame.io writes **`|D:0`**, where its own Avid export says length 1
  (`_ATN_CRM_LENGTH` = 1 on all 11). How Resolve reads `D:0` is **UNKNOWN** (step R2).
- **There is no keyword field.**
- **Start timecode is assumed.** Frame.io placed the markers from 01:00:00:00 (frame 286 → `01:00:11:22`, which is
  286 frames at 24 per timecode second). Its Premiere export says the opposite: its sequence `<timecode>` is
  `00:00:00:00` (`…_Premiere.xml:248-255`). Manifold uses the file's own timecode (§2).
- **The `@` line** holds author and a date ("Nov 15 15 07:54pm"). Whether Resolve reads it, ignores it or imports it
  into the note is **UNKNOWN** (step R2).
- **Colour is Frame.io's choice, not the reviewer's.** Frame.io comments carry no colour (the `.fiojson` comment records
  have no colour field). The EDL says **Purple**; the Avid export says **Blue** (`_ATN_CRM_COLOR`); the Premiere export's
  `pproColor` 4294741314 = `0xFFFC8D42`, which read as A,B,G,R is rgb(66, 141, 252), **blue**. Same 11 markers, two
  colours.

**Frame.io's EDL disagrees with Frame.io's other exports by a frame (found 2026-11-15, building the tests).** Five of the
11 events (004, 007, 008, 009, 011) are one frame EARLIER than the same comments' `frame` in the `.fiojson`, the Avid
`_ATN_CRM_TC` and the Premiere `<in>`: e.g. event 004 is `01:11:49:13`, frame 17029, against 17030 in the other three.
The other six agree. Manifold reads what an EDL says; it does not correct Frame.io.

What Resolve's own export looks like is §0.5 (R1). The Frame.io files are examples only; Resolve's own EDL is the model
(Robbie, 2026-11-15).

### 0.2 Premiere xmeml (`…_Premiere.xml`)

- `<marker>` has `<comment>` (the note), `<name>` (author again), `<in>`/`<out>` as **frame counts from the sequence
  start**, and `<pproColor>`.
- `<out>` is `-1` on 8 markers and equal to `<in>` on 3 (lines 117, 152, 173), with nothing in the `.fiojson` to
  explain the difference (`duration` is null on all 11). Treat `-1` as "a point marker".
- Every marker appears **twice**: on the colour-matte generator item (lines 99-175) and on the sequence (lines 269-345).
- **Rate is wrong:** `<timebase>24</timebase><ntsc>FALSE</ntsc>` for a 23.976 file. Manifold must write `ntsc TRUE`.

### 0.3 Avid marker XML (`…_Avid.xml`)

Per marker, one `AvClass id="ATTR"` with seven attributes: `_ATN_CRM_LONG_CREATE_DATE` (Unix time), `_ATN_CRM_COLOR`
(`Blue`), `_ATN_CRM_USER`, `_ATN_CRM_COM` (the note, prefixed `[Author Nov 02, 2026 · 17:13]`), `_ATN_CRM_TC` (**a frame
count**, `286`, not a timecode string), `_ATN_CRM_TRK` (`V1`), `_ATN_CRM_LENGTH` (`1`).

### 0.4 `.fiojson`

Frame.io's own JSON. Final Cut does not import it. Two findings:

- Each comment has `frame` and `timestamp_microseconds`. For the first two comments the microseconds are one frame later
  than `frame` (286 → 11 970 291 µs = (286 + 1) × 1001/24000 s); for the other nine they match `frame` exactly. Anything
  reading `.fiojson` should use `frame`. (Corrected 2026-11-15: the plan's first draft said all were one frame later.)
- ⚠️ **It holds live credentials-like data:** signed asset URLs, an HLS manifest URL with a token, and account, project
  and owner IDs. `docs/markers/` is untracked (`git status`: `?? docs/markers/`). Do not commit the `.fiojson` as is
  (decision D14).

### 0.5 Resolve's own marker EDLs (R1) and Frame.io's EDL in Resolve (R2)

Robbie, 2026-11-15, DaVinci Resolve 21.1. Files: `docs/markers/resolve-reference-2398.edl` (23.976, 5 markers),
`docs/markers/resolve-reference-2997DF.edl` (29.97 DF, 3 markers), `docs/markers/frameio_formating.png` (the marker dialog
after importing Frame.io's EDL). Read byte by byte (`od -c`).

```
TITLE: resolve-reference-2398␍␊
FCM: NON-DROP FRAME␍␊
␍␊
001  001      V     C        01:00:01:16 01:00:01:17 01:00:01:16 01:00:01:17  ␍␊
There is to much higlight on her frace |C:ResolveColorBlue |M:Face |D:1␍␊
␍␊
002  001      V     C        01:00:02:14 01:00:02:15 01:00:02:14 01:00:02:15  ␍␊
The shot gets weird and posterized |C:ResolveColorRed |M:As she turns here |D:24␍␊
␍␊
…
004  001      V     C        01:00:05:21 01:00:05:22 01:00:05:21 01:00:05:22  ␍␊
 |C:ResolveColorLemon |M:good |D:1␍␊
```

| Question | Resolve's own EDL (R1) | Frame.io's EDL |
|---|---|---|
| Line endings | **CRLF** | LF |
| TITLE | the timeline's name, no extension | the file's name with extension |
| FCM spelling | **`NON-DROP FRAME`** / **`DROP FRAME`** | `NON DROP FRAME` |
| Event line | `001  001      V     C        ` (V before C, fixed columns), four timecodes separated by one space, two trailing spaces | `001  001  C  V  `, two spaces between timecodes |
| Out vs in | **out = in + 1, always**, whatever the duration (a `D:24` marker still has in + 1) | out = in |
| Duration | `\|D:` only | `\|D:0` |
| Drop-frame punctuation | **colons**: `01:00:03:07` under `FCM: DROP FRAME` | (no DF example) |
| Empty notes | the line starts with a space: ` \|C:…` | (none) |
| `@` line | **none** | `@Author, date` |
| Default name | Resolve names unnamed markers `Marker 5` | the comment's author |

What R1 and R2 show about the open questions:

- **`D:0`:** Resolve imports it as **one frame** (R2: Duration `00:00:00:01`).
- **The `@` line:** Resolve imports it **into the note, as its first line** (R2: the note reads "@Robbie Carman, Nov 15 15
  07:54pm" then, on a new line, the comment). So every comment line between the event line and the `|C:` line becomes
  a note line, and Resolve's EDL import CAN carry multi-line notes.
- **Keywords: Resolve's EDL export drops them.** R1 had "fix" on 01:00:02:14 and "correct" on 01:00:05:21 (Robbie,
  2026-11-15); neither appears in the EDL.
- **Multi-line notes: Resolve's EDL export flattens them onto one line.** R1's 01:00:04:13 note was typed over two
  lines; the EDL has it as one, and the separator Resolve used is not visible in the text. So **notes that come from
  Resolve arrive single-line in Manifold**, whatever Manifold sent.
- **Accents and emoji:** Resolve's marker dialog refused accented characters, so R1 has none. Whether Resolve's EDL
  IMPORTER accepts a Manifold EDL holding é and an emoji is tested in M1; if it does not, Manifold warns on export
  (not built until M1 says so).
- **Quotes:** marker 003's `''pull'` is how it was typed, not Resolve's doing. A real `"` is tested in M1, both ways.
- **`|`:** not tested in R1. Manifold writes "/" for it regardless (§6.1).

**Settled from these (D10, D11):** Manifold writes Resolve's own layout byte for byte (D11), and writes **no `@` line**
(D10), since Resolve would put it in every note. Reading, Manifold skips a line starting `@` (Frame.io's author line) and
reads any other comment lines above the `|C:` line as note lines, as Resolve does. The writer reproduces both R1 files
byte for byte from their markers (`ResolveEDLTests.testWritesResolve2398ByteForByte`,
`testReadsAndWritesResolve2997DFByteForByte`).

**D13 revised from R2 (Robbie, 2026-11-15):** since Resolve's importer keeps each comment line as a note line, Manifold
writes a multi-line note as several lines, the last one carrying `|C:` (§6.2).

---

## 1. Fields

### Recommendation

Match Resolve's marker exactly. One marker:

| Field | Type | Default | Notes |
|---|---|---|---|
| Time | frame index from the file's first frame (stored); shown as timecode | the frame on screen at the keypress | Stored as an index, never as a timecode string, so a change of start timecode (§2) moves no marker |
| Duration | frames, ≥ 1; typed and shown as timecode | 1 frame | As Resolve's `duration` ("Duration in frames, e.g. 1", Resolve 21.1 scripting stub `DaVinciResolveScript.pyi:337-343`) |
| Name | single-line text | empty | Resolve's dialog default is "Marker 1"; whether Manifold numbers them too is D3 |
| Notes | multi-line text | empty | |
| Keywords | ordered list of short strings | empty | |
| Color | one of 16 | Blue | |

The 16 colours, in Resolve's order and spelling, verified against Resolve 21.1's scripting stub
(`/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/DaVinciResolveScript.pyi:7`):
Blue, Cyan, Green, Yellow, Red, Pink, Purple, Fuchsia, Rose, Lavender, Sky, Mint, Lemon, Sand, Cocoa, Cream. The EDL
token is `ResolveColor<Name>` (§0.1).

**Appearance (R0, Robbie, 2026-11-15).** No text resource in the Resolve 21.1 bundle names them, so they were read from a
screenshot of Resolve's marker dialog (16 flat swatches), converted from the LG's profile to sRGB. Close, not exact;
enough for a swatch, because colours travel between apps by name, never by value (`MarkerColor.hex`):

| Blue | Cyan | Green | Yellow | Red | Pink | Purple | Fuchsia |
|---|---|---|---|---|---|---|---|
| #078AE7 | #08D4D6 | #02B601 | #F2A701 | #E42900 | #FF4DCF | #9B0FFE | #C7347A |

| Rose | Lavender | Sky | Mint | Lemon | Sand | Cocoa | Cream |
|---|---|---|---|---|---|---|---|
| #FFABC1 | #AB9DCF | #9DE6FD | #7DE002 | #E0EC65 | #CB9C69 | #795B4C | #F6EEE5 |

Also stored, not shown as fields: a stable marker id (UUID), created/modified dates (for merge on import), and the
start timecode in force when the marker was made (§2, to warn if the file's timecode later reads differently).

### Alternatives

- **Store the timecode string.** Simpler to export, but a start-timecode override (§2) or a corrected timecode read
  would leave every marker on the wrong frame. Rejected.
- **No keywords in v1.** None of the v1 formats carries them (§6.3), so they could wait. But Resolve's marker has them,
  you asked for an exact match, and CSV/text carry them. Kept.

---

## 2. Timecode

### What Manifold reads today

- **QuickTime / MP4:** `TimecodeReader.readStartTimecode` walks to the `tmcd` track: rate and drop-frame flag from the
  sample description, start frame from the first sample (`Packages/ManifoldCore/Sources/ManifoldCore/TimecodeReader.swift:62-90`,
  `:172-203`).
- **MXF and other libav containers:** the container's `timecode` metadata, format level first, then any stream
  (`LibavFrameSource.swift:390-401`), parsed into the same result (`TimecodeReader.swift:40-60`, `FrameEngine.swift:3442`).
- **The readout:** start frame + round(seconds × exact rate), formatted with the integer rate and `;` for drop-frame
  (`FrameEngine.swift:2663-2671`). Timecode entry uses the same precedence; with no timecode the origin is 0 and
  `hasTimecode` is false (`App/TimecodeEntry.swift:139-178`).
- **Export Frame names** already use exactly this: the source timecode, else elapsed time (`App/WindowDeck.swift:363-368`).

Markers reuse this path. They add no timecode reader of their own.

### Gaps found by reading (not measured), to settle before markers depend on them

1. **The `tmcd` edit list is ignored.** The start is the first sample's value (`TimecodeReader.swift:193-203`); a
   timecode track whose edit list starts later would read early. **UNKNOWN** whether any fixture has one.
2. **Counter mode and the 24-hour wrap.** Flags other than drop-frame are ignored (`:188`); `format` never wraps past
   23:59:59:xx (`:207-234`). An EDL with `24:00:00:00` is invalid.
3. **Only the first `tmcd` track, first sample description** is read.
4. **Files with neither tmcd nor container timecode** (most MP4s from phones and web services, and possibly the Frame.io
   reference file itself: Frame.io says `01:00:00:00` for it, which may be its default) start at 0.

### Recommendation for files without timecode

**Start at 00:00:00:00**, as the transport readout and Export Frame names do now, so every number Manifold shows agrees.
Add a **per-file "Marker start timecode" override**, stored with the markers (not in the file), offered in the marker
list's header and in the export sheet. It changes only the timecodes markers are shown and exported at; the transport
readout stays as it is in v1 (D6).

Drop-frame for a file without timecode: off. A 29.97 file without timecode is shown non-drop, as today.

### Alternatives

- **Default to 01:00:00:00**, Resolve's default timeline start. Imports into a default Resolve timeline line up with no
  change; but the marker list would then disagree with the transport readout and with Export Frame names. Rejected as a
  default; available through the override.
- **Make the override change the transport readout too.** Consistent, but it touches timecode entry and Export Frame
  naming, which are verified and released. Later, if wanted.

---

## 3. Adding markers

### 3.1 Keys

Checked against `ShortcutCatalog.all` (`Packages/ManifoldCore/Sources/ShortcutRegistry/ShortcutCatalog.swift:205-350`),
`ShortcutRegistry.reserved` (`ShortcutRegistry.swift:280-307`) and the audit's reservations (`docs/SHORTCUTS_AUDIT.md:323-324`).

| Action | Key | Scope / dispatch | Free? |
|---|---|---|---|
| Add Marker | **M** | `.fileTransport`, `.menu` (a bare menu key, like N, `ShortcutCatalog.swift:267`) | Free in the catalog. ⌘M is Minimize (`ShortcutRegistry.swift:286`), so only bare M. Reserved for this since the audit |
| Add Marker and Edit… | **⌥M** (proposal) | `.fileTransport`, `.menu` | Free in the catalog and reserved list. On a US layout ⌥M types "µ"; the registry's layout handling (`KeyLayout.swift`) labels it, but this needs the window's recorder check |
| Previous / Next Marker | **⇧↑ / ⇧↓** | `.fileTransport`, **`.key`** | Free. Must be `.key`: ⇧ + an arrow cannot be a menu key equivalent (C7, `docs/SHORTCUTS_AUDIT.md:174-176`, `ShortcutRegistry.swift:14-17`) |
| Mark In / Mark Out | **I / O** | `.fileTransport`, `.menu` | Free; I was freed for this when Inspector moved to ⌘I (`docs/SHORTCUTS_AUDIT.md:323`) |
| Clear In and Out | **⌥X** | `.fileTransport`, `.menu` | Free; Resolve's (audit §3 table, `docs/SHORTCUTS_AUDIT.md:270`) |
| Delete Marker at Playhead | no default key | menu only | A bare ⌫ would conflict with `timecodeBackspace`, whose scope overlaps every scope (`ShortcutCatalog.swift:119`, `:257-258`); ⌥⌘⌫ is Disconnect Live Source (`:218`). In the marker list, ⌫ deletes the selected rows (the list's own key, not the registry's) |

**macOS-reserved and Services.** Bare M, I, O and ⇧↑/⇧↓ cannot be Services keys (a Service's key equivalent always carries
⌘). ⌥M and ⌥X are not in `reserved`. Before shipping, the same check as Share Frame (`ShortcutCatalog.swift:211-213`):
read the build Mac's symbolic hotkeys and each installed Service's key equivalent, **read-only**. Not run for this plan.

Every new `.menu` action needs a home in `MenuKeyAudit.menuHomes` (`MenuKeyAudit.swift:81-90`), or the audit fails.

**Menus.** A new top-level **Mark** menu, Resolve's name for it: Add Marker, Add Marker and Edit…, Delete Marker,
Previous/Next Marker, Mark In, Mark Out, Clear In and Out, Show Marker List. Import and export under **File ▸ Import
Markers… / Export Markers…** (D8).

### 3.2 Which frame "the frame on screen at the keypress" is

During playback the picture can lag the playhead by a frame or two, the render queue's depth (`App/WindowDeck.swift:351-352`).
Export Frame accepts that because frames are taken while paused; a marker added while playing cannot. So:

- **Recommendation:** the marker goes on the **presented** frame, the one whose PTS the renderer last put on the screen
  when the key went down. The renderer already tracks that PTS for its presented-fps count (`lastPresentedPts`,
  `App/MetalVideoRenderer.swift:3851-3856`), on the display-link thread. Markers need it published per window, with the
  key event's timestamp, converted to a frame index with the same exact-rate rule as the readout (`FrameEngine.swift:2640-2662`).
- Paused, presented frame and playhead are the same frame, so the rule changes nothing there.
- Playback keeps running. M never pauses.
- Test: §8, step M3 (burned-in frame numbers, so the frame can be read from the picture).

Alternative: the **playhead** (`engine.currentTime`), as Export Frame uses. Simpler, and one or two frames late while
playing. Rejected, because "the frame I saw" is the point.

### 3.3 The marker editor

A sheet on the player window, laid out like Resolve's marker dialog: Name, Start (timecode, editable), Duration
(timecode, editable), End (read-only, derived), Notes (multi-line), Keywords (token field), Color (16 swatches, Resolve's
names as tooltips and accessibility labels).

- **Time and Duration type exactly as timecode entry does (D21, 2026-11-15)**, through one shared copy of its arithmetic
  (`SMPTETimecode.fillFromRight`, which `TimecodeEntry.fields` now calls; `TypedTimecode`, `TimecodeBasis.typedFrame` and
  `typedDuration`): digits fill from the right ("100" is 00:00:01:00, "1" is one frame, "75" at 24 fps is 3 s 3 f), at
  most eight; a leading "+" (or "=") or "−" makes it relative to the field's current value, as the transport's +/−
  make an entry relative to the playhead; there is no "." in timecode entry, and a typed "." is read as a separator, as
  ":" and ";" are, so a pasted label works. A drop-frame label that does not exist moves forward to the minute's first
  frame, as in timecode entry. The field reformats to full SMPTE on Tab, Return or leaving it; Duration is always a
  non-drop length. **The first build read a bare "100" in Duration as 100 frames and stored it so; fixed.**
- **Duration by marking:** with In and Out set, M adds one marker spanning In → Out (duration = Out − In + 1) and clears
  them (D4). In the editor, "Set from In/Out".
- Return saves, Esc cancels. The editor's text fields take every key: the dispatcher already gives typed keys to a text
  field (`ShortcutRegistry.swift:19-25`).
- Playback while the editor is open: continues (D5).
- Edit ▸ Undo / Redo for add, edit, delete, import, per window.

---

## 4. The marker list and the timeline bar

### 4.1 Two places

**(a) A scope slot option, "Markers".** Add `case markers` to `ScopeKind` (`App/ContentView.swift:23-35`). Adding a
case is safe for stored selections (`:15-18`), and every slot's header menu lists every kind automatically (`:44-52`).
Like `meters`, it is not render-coupled (`:20-22`). Per window, so it always shows that window's file. A slot is narrow:
it shows **timecode, colour, name, duration**; notes as a second line, truncated.

**(b) A floating window, "Markers".** One app-wide window (a `Window` scene like Keyboard Shortcuts,
`App/ManifoldApp.swift:398`) that follows the **key player window's** file, says which file in its title, and shows full
columns: timecode in, out, duration, colour, name, notes, keywords. Editing happens here or in the sheet.

**Built: both (D7 as changed 2026-11-15).** The window is Mark ▸ Show Marker List, ⌃⌘M (`MarkersWindow.swift`). It
follows `DeckRegistry.keyDeck`, the last player window to become key, which stays put while the Markers window is in
front, and is re-read whenever any window becomes key or closes. Its title is "Markers — <file name>", its toolbar holds
the colour filter, Import and Export. A normal window, not always-on-top. Opening the editor from it brings that player
window forward, because the editor is a sheet on the player window.

### 4.2 Behaviour of the list

- Columns: timecode, colour, name, duration (both views); the window adds notes and keywords.
- **Click jumps** the playhead to the marker and selects it alone; **⌘-click** adds or removes it from the selection and
  **⇧-click** selects a range, both without jumping; **double-click** opens the editor (D7, changed 2026-11-15). The rows
  read the click themselves (modifiers and click count at mouse-up), so a click on an already-selected row jumps too, and
  the jump does not wait out the double-click interval.
- Edit: double-click the name/colour cell, or "Edit…" opens the sheet. Delete: ⌫ on the selection, with undo.
- **Filter by colour:** a 16-swatch filter row, multi-select, plus a text filter on name/notes/keywords in the window.
- Sorted by time, always.
- The row at or before the playhead is highlighted as playback passes it.

### 4.3 The timeline bar

The scrubber is `PlayheadScrubber` (`Packages/ManifoldCore/Sources/PlayheadSlider/PlayheadSlider.swift`), wrapped by
`App/TransportScrubber.swift`. Its contract is that of the SwiftUI Slider it replaced, and its tests measure that in Ball
style the control is byte-identical to that Slider (`TransportScrubber.swift:5-12`).

**Recommendation:** draw markers in a **thin strip just above the track**, not on the track: a small flag in the marker's
colour at its frame, and for a duration longer than one frame a translucent band of the same colour from in to out.
Hover shows the name and timecode. Clicking a flag jumps to it. The track, its hit-testing and its tests are untouched.

Alternative: on the track itself, as Resolve's ruler does. Denser, but clicks near a marker become ambiguous (scrub or
jump?), and the byte-identical Ball test would no longer hold.

### 4.4 Thumbnails (D20, built 2026-11-15)

A small picture of each marker's frame: always in the Markers window (96 pt wide), and in the slot behind a gear toggle,
"Thumbnails", on by default (32 pt high, so a tray still shows several rows).

- **Source:** the file at the marker's frame, decoded by a decoder of its own (`FrameEngine.makeFrameProducer`, the same
  route, pixel format and ProRes options as scrub, a separate instance, so its seeks never touch scrub or playback),
  landing a quarter-frame in, as typed seeks do.
- **Picture:** Core Image draws the frame from its own colour tags, HDR tone-mapped to SDR, into sRGB, 108 px high, JPEG.
  Not the display transform. **Not byte-for-byte Export Frame:** Export Frame reads the renderer's offscreen picture,
  which carries a tag override or an interpretation LUT; no off-main path renders an arbitrary frame through the
  renderer, so a thumbnail shows the file's own picture. Pixel aspect and clean aperture are not applied.
- **Never blocks playback:** one frame at a time, utility priority, and nothing new starts while the file plays; the queue
  resumes at the next pause. Made only while a view shows thumbnails.
- **Cache:** in memory, and on disk only in
  `~/Library/Caches/com.graviton.manifold/MarkerThumbnails/v<version>/<fingerprint>/<frame>.jpg` (`MarkerThumbnailCache`).
  A deleted marker's thumbnail is removed; the folder goes with the file's last marker. **Versioned (D23):** the cache
  version is in the path (now 2; the unversioned first build was 1), and every other folder under MarkerThumbnails is
  purged once per launch, so an older build's thumbnails are never shown. Bump `MarkerThumbnailCache.version` whenever
  the picture changes. Not used at all while Remember markers between sessions is off (§5.2).
- **Regenerate (D23):** "Regenerate Thumbnails" in the slot's gear and the Markers window's toolbar (every marker of the
  file), "Regenerate Thumbnail" in a row's context menu (that marker, or the selection). Drops them from memory and disk
  and makes them again through the same queue: off the main thread, never while playing.
- The blank early-frame thumbnails seen in the first test cleared with Clear All; most likely the first build's cache
  (Robbie, 2026-11-15). Not investigated further unless it recurs.

### 4.5 View ▸ Show Markers (D25, built 2026-11-15)

App-wide and remembered (`manifold.markers.show`, default on), ⇧⌥⌘M. Off hides the timeline flags and the Markers slot's
and window's contents (each says "Markers are hidden. View ▸ Show Markers (⇧⌥⌘M) shows them again."); nothing is
deleted, and M, ⌥M, the menus and an import still work. Adding a marker (or importing) while hidden turns it back on.
Key checks (2026-11-15): not in the catalog or `reserved` (⌥⌘M is Minimize All); no symbolic hotkey on M; a Service key
is ⌘ or ⇧⌘ only (⇧⌘M is Terminal's), so none can hold ⇧⌥⌘M.

### 4.6 Wording (D26)

The Markers window's toolbar uses text buttons, "Import…", "Export…" and "Regenerate Thumbnails" (the first build's
icons read as Download and as Share Frame's Share symbol); the filter stays an icon, tooltip "Filter by Colour". The
slot's gear says "Import Markers…" and "Export Markers…", as the File menu does.

---

## 5. Storage

The media file is never written to: no rewrite, no retag, no extended attribute.

### Recommendation: app storage, keyed by a content fingerprint

- **Where:** `~/Library/Application Support/com.graviton.manifold/Markers/`, one JSON file per media file, as the
  Settings Backups folder already is (`Packages/ManifoldCore/Sources/SettingsTransfer/SettingsBackups.swift:24-26`). Not
  UserDefaults: notes are user content, can be long, and the plist is the wrong place for them (§5.1).
- **Key:** a fingerprint of the file's content: SHA-256 over the file size, the first 4 MB and the last 4 MB (the whole
  file if it is 8 MB or less). Computed off the main thread at open; markers appear when it is ready. On a 2.8 GB file
  it reads 8 MB. **Built without the frame count and rate the first draft had:** a later build reading a file's rate or
  length differently would have orphaned every marker on it. Known limit: a change in the middle of a large file, both
  edges untouched, keeps the key (`MarkerFilesTests.testFingerprintFollowsContentNotPath` documents it).
- **Kept beside it, as hints:** the last path and a bookmark (`URL.bookmarkData`) for "Markers for files not found" in
  the window, and for re-linking.
- **Save:** on every change, atomically (write temp, rename).

What survives:

| Change to the media | Fingerprint key | Path key | Sidecar next to the file |
|---|---|---|---|
| Rename in place | ✅ | ❌ | ❌ unless renamed with it |
| Move on the same volume | ✅ | ❌ | ❌ unless moved with it |
| Copy to another volume / another Mac | ✅ on this Mac; ❌ on the other Mac | ❌ | ✅ if the folder is copied |
| Re-render, re-wrap, re-encode | ❌ (correct: a different file; Import Markers brings them over) | ✅ (wrongly) | ✅ (wrongly, if same name) |
| File edited in place (e.g. `tmcd` rewritten by another app) | ❌ if the first or last 4 MB changed (the `moov` is often at one end) | ✅ | ✅ |

### Alternatives

- **Sidecar next to the media** (`<name>.<ext>.markers.json`). Travels with the folder and is visible to collaborators.
  But it writes to media volumes: read-only volumes and client drives fail, SMB/exFAT volumes gain clutter, a Finder
  copy of one file leaves it behind, and under this repo's rules it would write into `/Volumes/DCCOLOR/TEST FLIP`, which
  is never to be modified (CLAUDE.md, Test environment). Offer it only as **Export Markers…** in any format, on request.
- **Extended attribute on the media file.** Not written to the essence, but it is a write to the file, it is lost or
  becomes `._` files on SMB, exFAT and many NAS shares, and it breaks the "never modify the media" rule. Rejected.
- **Path key alone.** Breaks on every rename. Rejected.
- **A per-window session only.** No persistence. Contradicts "per file".

### 5.1 Privacy

Names, notes and keywords are user content.

- **Never logged.** Not in `NSLog`, `os_log`, `print` or stderr: Export Diagnostics captures the app's log stream into
  its "CAPTURED LOG" section (`App/DiagnosticsExport.swift:191`, `:931`). Marker log lines carry counts and outcomes
  only: `[MARKERS] loaded n=11`, `[MARKERS] export edl n=11 joined-lines=2 dropped-keywords=3`. No file names in those
  lines either.
- **Never in Export Diagnostics**, including the redaction-optional file-name parts. A unit test seeds a sentinel note
  and name, builds the report (`DiagnosticsReport.build`, `DiagnosticsExport.swift:808`), and asserts neither appears.
- **Not in Settings Transfer** (`.manifoldsettings`). Markers are not settings (D12).
- **Not synced.** App Support is local; nothing goes to iCloud.
- `docs/PRIVACY_AUDIT.md` gains a row in §1 "Files and caches" (`:161-185`), a line in §2 Logging, and §9 After
  uninstall: the Markers folder remains until deleted.

### 5.2 Remember markers between sessions (D24, built 2026-11-15)

Settings ▸ Files ▸ Markers, default ON (`manifold.markers.remember`).

- **Off:** a file opened while it is off starts with no markers and reads nothing from Markers/; its markers live in
  memory while it is open, and nothing is written to Markers/ or the thumbnail cache (thumbnails are memory-only).
- **Turning it off** deletes nothing stored, and stops writes at once, also for files already open.
- **Turning it on** applies to files opened afterwards. A file already open while it was off keeps its session markers
  unsaved: its stored markers were never read, and saving the session's over them would lose them.
- **Delete All Stored Markers…** beside it, with a confirmation: removes Markers/ and the whole thumbnail cache, and clears
  the markers in open windows (they are the same markers). No undo. Exported files are not touched.

---

## 6. EDL: the Resolve marker EDL

### 6.1 Export

**Built (D10, D11):** Resolve's own layout (§0.5), byte for byte, with no `@` line:

```
TITLE: <clip name, no extension>␍␊
FCM: NON-DROP FRAME␍␊                 (DROP FRAME for a drop-frame file)
␍␊
001  001      V     C        <in> <in+1> <in> <in+1>  ␍␊
<notes> |C:ResolveColor<Color> |M:<name> |D:<frames>␍␊
␍␊
002  …
```

Drop-frame timecodes are written with colons, as Resolve writes them. An empty name is written `|M: |D:1` (D3); how
Resolve reads an empty `|M:` is checked in M1.

- **Timecodes:** the file's start timecode + the marker's frame index (§2), so the EDL lands on the right frames in a
  Resolve timeline that starts at the file's timecode.
- **`|D:`** the duration in frames, ≥ 1 (never `0`).
- **Encoding:** UTF-8, no BOM, CRLF, as Resolve writes it. Non-ASCII in Resolve's importer is **UNKNOWN** (M1 includes an
  accented and an emoji note).
- **Reserved characters:** a `|` in a note or name would corrupt the `|C:`/`|M:`/`|D:` fields. Replace `|` with `/` on
  export, and count it in the export summary.
- **Events:** numbered from 001 in time order. CMX3600 allows 999; above that, Resolve's behaviour is **UNKNOWN**: warn
  and continue numbering (step R3 checks 1000+ only if you want it).

### 6.2 Multi-line notes

**Built (D13, revised 2026-11-15): line breaks are kept.** Each line of a note is written as its own comment line, and
the last line carries `|C:`:

```
003  001      V     C        01:00:04:13 01:00:04:14 01:00:04:13 01:00:04:14  ␍␊
First line of the note.␍␊
Second line of the note. |C:ResolveColorBlue |M:Focus |D:1␍␊
␍␊
```

R2 is the evidence that Resolve's importer reads every comment line above `|C:` as a note line (Frame.io's `@` line
became the note's first line). Rules:

- Blank lines inside a note are left out: a blank line ends an event. The export summary counts them.
- A note line starting `@` is written with one leading space, because Manifold's reader skips an `@` in column 0 on an
  event's first comment line (Frame.io's author line, D10).
- Manifold's reader takes TITLE and FCM only before the first event, so a note line "TITLE: …" stays a note line.
- **Resolve's own EDL export flattens notes (R1),** so notes going Resolve → Manifold arrive single-line.

Superseded options: joining with " / " (the first decision; loses the line breaks), a `¶` mark, one event per line,
truncating.

### 6.3 Keywords

No EDL field, and Resolve's own EDL export drops keywords (R1). Options:

1. **Drop them from the EDL and say so** in the export summary ("3 markers have keywords; EDL has no field for them;
   CSV and text keep them"), with a checkbox **"Add keywords to notes"** (off by default) that appends ` [kw1, kw2]`
   (recommended).
2. Always append as `#kw` tags. Keeps them, pollutes every Resolve note, and Resolve does not turn them into keywords.
3. Put them in `|M:`. Destroys the name.

Built: option 1. On import a trailing ` [a, b]` stays note text: with no `@` line (D10) nothing marks an EDL as
Manifold's.

### 6.4 Import (Timeline ▸ Export ▸ Timeline Markers to EDL, from Resolve)

- Parse permissively: an event line, then any lines up to the next blank line. An event's first comment line starting
  `@` in column 0 is ignored (Frame.io's). The line
  containing `|C:` gives notes (text before ` |C:`), colour, `|M:` name and `|D:` duration. `D:0` or missing → 1.
- Unknown colour token → Blue, counted in the summary.
- Timecodes: `:` or `;` accepted, and FCM read. An EDL that says DROP FRAME on a non-drop file (or the reverse) is
  imported by frame count with a warning.
- **Mapping:** frame = record-in − file start timecode. Markers outside the file are listed and skipped, not clamped.
- **Offset detection:** if every marker falls outside the file but would fit after shifting by a whole hour (the
  Frame.io case: 01:00:00:00 against a file at 00:00:00:00), offer "Shift by −01:00:00:00". Never applied silently.
- TITLE differs from the file name → warn, still importable.
- Merge, not replace: a marker at the same frame with the same name and notes is skipped as a duplicate. The whole
  import is one undo step (D9).
- The EDL carries no rate; the file's rate is used.

### 6.5 CSV and plain text export (v1)

- **CSV:** RFC 4180 quoting and CRLF records, UTF-8 **with BOM** (so Excel on the Mac reads accents; Numbers is fine
  either way). Line breaks inside a quoted note stay LF.
  Columns: `Timecode In, Timecode Out, Duration, Duration Frames, Frame, Color, Name, Notes, Keywords`. Notes keep their
  line breaks inside quotes. Keywords joined with `; `. A header comment is not possible in CSV, so file name, start
  timecode, rate and drop-frame go in the file name: `<clip> markers.csv`.
- **Plain text:** a header (file name, start timecode, rate, DF/NDF, count, date), then one block per marker:

  ```
  01:00:11:22  Purple  1 fr   Title fix
      Need to update title - should be: Reverse Engineering In The Age Of A.I.
      Keywords: titles, graphics
  ```

---

## 7. Formats and order

### v1

Resolve marker EDL export **and** import (§6), CSV export, plain text export.

### Next: Premiere (xmeml) and Avid (marker XML)

Modelled on the reference files (§0.2, §0.3), with the reference's defects fixed: correct `<ntsc>` for NTSC rates,
`<out>` = `-1` for a 1-frame marker and in + duration otherwise, markers on the sequence only (the duplicate on a
colour-matte generator exists for Frame.io's reasons; whether Premiere needs it is **UNKNOWN**, step P1).

**Colour mapping.** 16 colours do not fit in either app's set. Premiere's marker colours and their `pproColor` values,
and Avid's locator colour names, are **UNKNOWN** except Premiere Blue = 4294741314 and Avid `Blue` (the reference
files). They are to be captured from each app (step P1, A1) before a table is fixed. The rule I recommend, once the sets
are known: an exact name where one exists (Blue, Cyan, Green, Yellow, Red, …), then nearest hue (Fuchsia → Magenta,
Rose → Red or Pink, Lavender → Purple, Sky → Cyan or Blue, Mint → Green, Lemon → Yellow, Sand/Cream → Yellow or White,
Cocoa → Orange or Red), with the export summary listing what was mapped. Lossy one way; on import, each app colour maps
back to one fixed Resolve name.

### Later

- **FCPXML** for Final Cut (not `.fiojson`). FCPX markers have no colours, only types (marker, to-do, chapter), so
  colour is lost; but FCPX has real **keywords** (keyword ranges), so keywords survive there and nowhere else.
- **"Send to Resolve"** through the Studio scripting API. What the installed Resolve 21.1 stub says:
  - `AddMarker(frameId, color, name, note, duration, customData)` exists on `MediaPoolItem`, `Timeline` and
    `TimelineItem` (`DaVinciResolveScript.pyi:1993`, `:2134`, `:2356`).
  - **There is no keywords parameter**, and `MarkerInfo` has no keywords field (`:337-343`). So Send to Resolve
    **cannot carry keywords**, contrary to the brief. It can carry multi-line notes (`note: str`) and a Manifold marker
    id in `customData` ("Custom data field not exposed via UI"), which makes later re-sends update rather than duplicate.
  - `MediaPoolItem.AddMarker` puts markers on the **clip** in the Media Pool, by source frame. That is a better match for
    file markers than timeline markers: they follow the clip into every timeline, with no start-timecode alignment at
    all.
  - External scripting is configured in Resolve Studio's Preferences (README.md:40-42); the free version's limit is as
    you stated. Extra only.

---

## 8. Test plan

### 8.0 Fixtures

Cut to `~/Code/Manifold/fixtures/markers/` (CLAUDE.md: fixtures are cut, never client masters). Each has its frame number
("F n", 0-based) and its timecode label **burned into the picture** (`testsrc2` + two `drawtext`s, 640×360), so every
check reads the frame from the pixels. The no-timecode files burn a count from 00:00:00:00, the label Manifold gives them.

| Fixture | Rate | Timecode |
|---|---|---|
| `mk-2398-tc.mov` (ProRes Proxy), 60 s | 23.976 | tmcd `01:00:00:00` NDF |
| `mk-2997df-tc.mov` (ProRes Proxy), 70 s | 29.97 | tmcd `01:00:00;00` **DF** (crosses minute 1, where `;00` and `;01` do not exist) |
| `mk-2997df-tc.mxf` (ProRes Proxy MXF), 70 s | 29.97 | material package `00:59:59;00` DF (crosses the hour) |
| `mk-25-notc.mp4` (H.264), 60 s | 25 | **none** |
| `mk-2398-notc.mp4` (H.264), 60 s | 23.976 | none (the Frame.io case) |

**Generated 2026-11-15 with `/opt/homebrew/bin/ffmpeg`**, run only, by absolute path: `ffmpeg version
8.1.1-https://www.martin-riedl.de`, the Martin Riedl static build the release's sync clips use, which sits in Homebrew's
bin directory (Robbie approved its use as is: nothing copied, moved or installed). It has `drawtext` (libfreetype) and
libx264. No ffprobe beside it, so verified with its `ffmpeg -i`: container timecodes `01:00:00:00` (both tmcd tracks of
`mk-2398-tc.mov`), `01:00:00;00` (`mk-2997df-tc.mov`), `00:59:59;00` (`mk-2997df-tc.mxf`), none on the two `.mp4`s.
Burn-in read from extracted frames: `mk-2997df-tc.mov` F1800 = `01:01:00;02`, `mk-2997df-tc.mxf` F60 = `01:00:01;00`,
`mk-25-notc.mp4` F750 = `00:00:30:00`. An earlier set from the same binary was deleted before this one, and a
`README.txt` beside the fixtures records the same. The 25 fps file has frames 0–1499.

### 8.1 Unit tests (built; `swift test` in Packages/ManifoldCore)

All pass, 2026-11-15 (after the D13 change): the whole package suite, 1046 test cases, 0 failures.

- `SMPTETimecodeTests` (7): `format` unchanged below 24 hours against the pre-move code, sampled over a whole day at seven
  rates; the 24-hour wrap both ways (NDF and DF, `-1` → `23:59:59;29`); every 29.97 DF label for 11 minutes round-trips,
  with `;` and with colons; labels that are not times refused; the lenient parse timecode entry relies on unchanged.
- `ResolveEDLTests` (16): both Resolve EDLs (R1) read, placed and **written back byte for byte**; Frame.io's EDL reads as
  11 Purple one-frame markers named "Robbie Carman" with no `@` line in the notes, and on a no-timecode 23.976 file the
  −1 hour shift is offered and places all 11 (at the EDL's own frames, §0.1); multi-line notes written line by line with
  blank lines counted and left out, `|`, keywords dropped and appended (also on a note-less marker), `D:` ≥ 1;
  **multi-line round trip**: notes with three lines, a first line starting `@`, lines starting `TITLE:` and `FCM:`, a
  `"`, accents and an emoji all come back exactly; empty name and notes; DF minute boundary written with colons; round trip lossless for single-line
  notes at 23.976 and 29.97 DF; an EDL whose FCM differs from the file; across midnight; unknown colour; comment lines
  above `|C:` as note lines; a plain cut EDL refused; merge skips duplicates.
- `MarkerFilesTests` (9): the 16 colours, order, values and tokens; CSV byte for byte; plain text; rate labels; the
  override applies only without timecode; fingerprint follows content, not path; store round trip, removal, path refusal,
  unreadable file throws; **every marker log line holds no user text** (a sentinel in name, notes, keywords and title).
- `ShortcutRegistryTests`: the new rows pass the catalog, conflict, reserved and menu-key audits. Five existing tests
  pinned I and ⇧↑ as free keys or counted the keyed menu actions; they were updated, each with a comment saying I and ⇧↑
  are Mark In and Previous Marker since 2026-11-15.
- `PlayheadSliderTests` (22): unchanged and passing with the marker layer added to the scrubber.
- **Not a unit test:** the Export Diagnostics sentinel check. There is no app test target (`project.yml`), so it is M8.

### 8.2 Attended steps (Robbie)

Run with the usual guards: `scripts/manifold-proc.sh guard && <launch>`, launch the build by its absolute binary path, quit
by PID with `manifold-proc.sh quit <pid>`. I tell you before any launch. Screenshots of Manifold's window only, by ID;
Resolve windows are not captured by me. Every step uses the §8.0 fixtures (once generated) in a Profile build from this
tree (`.build-cc`).

R0, R1 and R2 are done (§0.5, §1).

**M0. Menus and keys (quick).** Mark menu: Add Marker (M), Add Marker and Edit… (⌥M), Delete Marker, Previous/Next Marker
(labelled ⇧↑/⇧↓), Mark In (I), Mark Out (O), Clear In and Out (⌥X). File: Import Markers…, Export Markers…. Keyboard
Shortcuts window: a "Mark" section. Type M, I and O into a stream bookmark's name field: they type letters.

**M1. Manifold → Resolve, per fixture** (all five):
1. In Manifold, show Markers in a scope slot. Add markers: the first frame, the last frame, one while playing (M3), one
   spanning In → Out (I, O, then M), one with a typed duration (⌥M), one of each colour family, one with a **two-line
   note**, one with a note holding a **blank line** between two lines, one with keywords, one with a `|`, one with a
   **double quote** (`He said "pull" it`), one with **é** and one with an **emoji**, one with **no name**.
2. File ▸ Export Markers…, format "DaVinci Resolve Marker EDL". Note the summary line in the slot (it counts multi-line
   notes, blank lines left out, `|` replaced, keywords dropped).
3. In Resolve: a new timeline at the **same start timecode** as the file (00:00:00:00 for the no-timecode fixtures unless
   the override is set), same rate and DF setting; the fixture at the timeline's start.
4. Timeline ▸ Import ▸ Timeline Markers from EDL.
5. For **every** marker: the burned-in frame number at the marker matches Manifold's list; duration; colour (by name in
   the marker dialog); name, and what Resolve shows for the empty one; notes:
   - the two-line note arrives **as two lines** (D13 revised; R2 says it should);
   - the blank-line note arrives as two lines with no blank between;
   - `|` arrives as "/";
   - `"` arrives unchanged;
   - **é and the emoji: does Resolve's importer accept them?** Record exactly what the marker shows (intact, dropped,
     replaced, or the import refused). If not intact, Manifold gets an export warning (to build after this step).
6. Then in Resolve, Timeline ▸ Export ▸ Timeline Markers to EDL from that timeline, save it beside the fixture, and
   read it: the `"` note's text as Resolve writes it back, and (expected, R1) the two-line note flattened.

**M2. CSV and text.** Export both for one fixture. Open the CSV in Numbers (and Excel if you have it): accents, the quoted
multi-line note, keywords. Read the text file.

**M3. Marking while playing.** On `mk-2398-tc.mov` at 1×, press M ten times. Pause and step to each marker (⇧↓): the
burned-in number on the marked frame is the number that was on screen at the press. Record any offset, in frames.

**M4. Resolve → Manifold, per fixture:** in Resolve, 10 markers on the fixture's timeline (same start timecode), with
names, notes (one typed over two lines, one with a `"`), keywords, durations and colours; export the EDL; File ▸ Import
Markers… in Manifold with the fixture open. Each marker on the same burned-in frame, with duration, colour, name and
notes. Expected from R1: the two-line note arrives on **one line**, and keywords do not arrive (Resolve's export drops
them). The `"` arrives as Resolve wrote it in M1 step 6. Import again: "already here, skipped". Undo (⌘Z) removes the
import in one step.

**M5. Drop-frame.** In M1 and M4 for both DF fixtures, include markers at `01:00:59;29`, `01:01:00;02` (the first label
after the drop) and `01:10:00;00` is beyond 70 s, so instead `01:00:00;00` and the last frame. In the editor, typing
`01:01:00;00` turns the field red and Done stays disabled. On the MXF: markers either side of `01:00:00;00`.

**M6. No timecode.** On `mk-2398-notc.mp4`: the list counts from 00:00:00:00. Import Frame.io's EDL
(`docs/markers/frameio-reference/…_Resolve.edl`): the "shift by −01:00:00:00" alert appears; Shift places 11 markers, the
last at the file's frame 84448 if the file were long enough (on this 60 s fixture most fall outside: the alert's count
says so). Set the gear's start timecode to 01:00:00:00: the list relabels, the transport readout does not, and an
export lands in a default Resolve timeline at 01:00:00:00.

**M7. Storage.** Rename the fixture in Finder, then move it within the same volume; reopen: markers are there. Copy it to
another volume; open the copy: markers are there. Re-wrap it (the confirmed FFmpeg, `-c copy`): no markers; Import brings
them back. Delete every marker: `~/Library/Application Support/com.graviton.manifold/Markers/` loses that file. None of
this on `/Volumes/DCCOLOR/TEST FLIP`.

**M8. Privacy.** With a marker whose name and note hold a sentinel word, Help ▸ Export Diagnostics…: the sentinel is
absent from the file. `/usr/bin/log show --last 10m --predicate 'process == "Manifold"' | grep <sentinel>`: nothing.

**M9. Timeline strip.** Flags in the marker colours above the bar in both playhead styles (Settings ▸ Playback), a band
for a marker longer than a frame, a tooltip with timecode and name, a click on a flag jumps to it, and a click or drag
anywhere else scrubs exactly as before.

**P1 / A1 (Next, only if you have Premiere / Avid here).** One marker per colour in each app, exported, saved to
`docs/markers/premiere-reference/` and `avid-reference/`, to fix the colour tables.

---

## 9. Decisions (Robbie, 2026-11-15)

All as recommended, with the choices named below.

| # | Decision | Decided |
|---|---|---|
| D1 | Keys | M add, ⌥M add and edit, ⇧↑/⇧↓ previous/next, I/O mark, ⌥X clear, no default for delete |
| D2 | Which frame while playing | The frame on screen, not the playhead |
| D3 | New marker's default name | **Empty**, so nobody has to delete placeholder text |
| D4 | M with In and Out set | One duration marker from In to Out; the marks are cleared |
| D5 | Playback while the editor is open | Continues |
| D6 | Files without timecode | 00:00:00:00, plus a per-file marker start override; the readout is unchanged |
| D7 | The list | **Changed 2026-11-15:** scope slot AND the Markers window, both now (§4.1). Click jumps; ⌘-click and ⇧-click select without jumping; double-click opens the editor (§4.2) |
| D8 | Menus | A top-level Mark menu; import and export in File |
| D9 | Import | Merge, skip duplicates, one undo step |
| D10 | The `@` line | **Omitted.** R2: Resolve imports it as the note's first line (§0.5) |
| D11 | Whose EDL layout | **Resolve's own**, byte for byte (§0.5). The Frame.io files are examples only |
| D12 | Settings Transfer | Markers stay out |
| D13 | Multi-line notes and keywords in the EDL | **Revised 2026-11-15 after R2:** line breaks kept, one comment line per note line above the `\|C:` line (Resolve's importer keeps them; Resolve's own export flattens them, so Resolve → Manifold notes are single-line). Keywords dropped with a summary line, opt-in "Add keywords to notes" |
| D14 | `docs/markers/frameio-reference/` | Commit the EDL and both XMLs, plus a `.fiojson` reduced to the 11 comments' `frame` and `text` only; never the original |
| D15 | Storage | App storage by content fingerprint; sidecars only by explicit export |
| D16 | Audio-only files and stills | No markers in v1 |
| D17 | Timecode gaps | The 24-hour wrap fixed now (built, §10); the edit-list case measured on a fixture before deciding |
| D18 | Next tier | **Premiere first**, then Avid |
| D19 | One marker per frame (2026-11-15) | No two markers start on one frame: M, ⌥M and an In→Out span open the marker already there; the editor refuses a Time on another marker's frame; an import skips a different marker on an occupied frame and counts it (an identical one merges) |
| D20 | Thumbnails (2026-11-15) | In the Markers window always; in the slot, a gear toggle, on by default (§4.4) |
| D21 | Timecode fields (2026-11-15) | Time and Duration follow timecode entry's rules and reformat to full SMPTE on commit (§3.3) |
| D23 | Thumbnail cache version and Regenerate (2026-11-15) | The cache version in the path, older versions purged at launch; Regenerate Thumbnails (gear, toolbar) and Regenerate Thumbnail (row menu) (§4.4) |
| D24 | Remember markers between sessions (2026-11-15) | Settings, default on; off reads and writes nothing; Delete All Stored Markers… with a confirmation (§5.2) |
| D25 | View ▸ Show Markers (2026-11-15) | Global, remembered, ⇧⌥⌘M; hides, deletes nothing; adding a marker turns it on (§4.5) |
| D26 | Toolbar wording (2026-11-15) | Text buttons Import…, Export…; filter icon "Filter by Colour"; gear "Import Markers…", "Export Markers…" (§4.6) |
| D22 | Edit Marker (2026-11-15) | Mark ▸ Edit Marker…, ⇧M: the marker starting at the playhead, else the nearest one starting before it. Show Marker List ⌃⌘M (⇧⌘M is a Terminal Service on the build Mac) |

---

## 10. What v1 is, as built (2026-11-15, not committed)

Package (`Packages/ManifoldCore`, leaf targets so `swift test` reaches them):

- `Sources/SMPTETimecode/SMPTETimecode.swift` (new): TimecodeReader's arithmetic, moved unchanged, plus the **24-hour
  wrap** (D17), a strict label parser under a stated drop-frame setting (Resolve's colon-punctuated DF), and duration
  labels. `ManifoldCore/TimecodeReader.swift` now forwards `format`, `parse` and `droppedFramesPerMinute` to it, so the
  transport readout, timecode entry, Export Frame names and markers share one copy.
- `Sources/Markers/` (new): `Marker`, `TimecodeBasis`, `MarkerDocument`; `MarkerColor` (names, order, R0 values,
  tokens); `ResolveEDL` (writer, permissive reader, placement with the hour-shift suggestion, merge); `MarkerCSV`,
  `MarkerPlainText`; `FileFingerprint`; `MarkerStore`; `MarkerLog` (count-only log lines). The EDL writer keeps note line
  breaks (D13 revised).
- `ShortcutRegistry`: the Mark category and ten actions (§3.1), menu homes for the `.menu` ones.
- `PlayheadSlider`: a marker layer in `PlayheadScrubber` (flags, spans, tooltips, flag clicks); empty, it draws nothing.

App (`App/Markers/` new, plus wiring):

- `MarkerModel` (per window, owned by `WindowDeck`): loads by fingerprint off the main thread on every file change, adds
  on the presented frame while playing (D2), In/Out, M on a frame that already has a marker opens that marker, undo for
  every change, saves atomically.
- `MarkerEditorSheet` (Resolve's dialog layout, 16 swatches, End, Set from In/Out, Remove Marker), `MarkersScopeView`
  (the slot: list, selection, double-click jumps, ⌫ deletes, context menu, colour filter and the D6 override in the
  gear, the export/import summary line), `MarkerFileIO` (save panel with format and keywords option; import with the
  shift alert and a summary), `MarkCommands` (the Mark menu).
- `MetalVideoRenderer.presentedPTS` (lock-protected, set where a frame is drawn, cleared with the picture);
  `TransportKeyMonitor.seek(toFrame:)` (timecode entry's quarter-frame landing); `ScopeKind.markers`; the scrubber row
  uses `MarkedTransportScrubber`.
- Profile build (`.build-cc`): **BUILD SUCCEEDED**, no new warnings. **Not launched.**
- `docs/PRIVACY_AUDIT.md`: the Markers folder (§1) and marker logging (§2).
- `.gitignore`: Frame.io's original `.fiojson` (D14); the `.reduced.fiojson` beside it (the 11 comments' `frame` and
  `text`) is not ignored.
- Fixtures: §8.0.

Not in v1: the floating Markers window (D7, after), Premiere/Avid/FCPXML, Send to Resolve, live streams, audio-only.

## 11. Questions answered (Robbie, 2026-11-15)

1. R1 had keywords and a two-line note: Resolve's EDL export drops keywords and flattens notes (§0.5). Its dialog refused
   accents; accents and emoji are tested through the importer in M1.
2. Marker 003's `''pull'` was typed so. A real `"` is tested in M1 (both ways).
3. D13 switched to keeping line breaks (§6.2), built.
4. Fixtures: `/opt/homebrew/bin/ffmpeg`, the Riedl build, run only (§8.0).

Open after M1: whether Resolve's importer keeps é and emoji; if not, build the export warning.

## 12. First attended feedback (Robbie, 2026-11-15)

### 12.1 How the duplicates happened

Two markers each on 01:00:01:19 (frame 43) and 01:00:04:03 (frame 99) of `HDR TEST.mov`. Read from the run log's
`[MARKERS]` lines (counts only) and the stored document's frames and dates (no names or notes read out):

| Marker | Frame | `created` (keypress) | inserted (`add` line) | Path |
|---|---|---|---|---|
| 1 | 43 | 21:52:33 | 21:52:33 | M |
| 2 | 43 | 21:52:36 | 21:53:11 | **⌥M**: draft at the keypress, inserted on Done |
| 3 | 99 | 21:53:24 | 21:53:24 | M |
| 4 | 99 (duration 100) | 21:54:45 | 21:55:00 | **⌥M** |

The "a marker starts here, so open it" check was on plain M only; ⌥M (Add Marker and Edit…), the In→Out span and the
editor's Done inserted without asking. Markers 4 and 5 also show the Duration bug: "100" stored as 100 frames. No import
ran in that session. Fixed by D19 (`MarkerRules`, every path) and D21.

### 12.2 Unit tests added

`MarkerEditingRulesTests` (8): "100" at 23.976, 25 and 29.97 DF in Time and Duration; Time against a 01:00:00:00 start and
pasted labels; fill-from-right normalisation; relative entries; the drop-frame forward move; text that is not a timecode;
one marker per frame and Edit Marker's choice; import skipping occupied frames and merging identical ones; the thumbnail
cache's keys and clearing. `ShortcutRegistryTests`: Edit Marker and Show Marker List counted (29 keyed menu actions).
Whole package: 1055 test cases, 0 failures.

### 12.3 Attended steps for these six

On `mk-2398-tc.mov` unless named; guarded launch as §8.2. Delete the old `HDR TEST.mov` markers first if you want a clean
list (they hold the duplicates the old build made; the new build does not merge them).

1. **One per frame.** Pause on a marked frame: M opens that marker; ⌥M opens it; Mark ▸ Add Marker opens it. Set In on a
   marked frame and Out later, press M: the existing marker opens, In/Out stay. In the editor of another marker, type the
   marked frame's Time and Done: "A marker is already at …", the sheet stays. Import an EDL with a different marker on an
   occupied frame: "1 skipped: frame already has a marker".
2. **Markers window.** Mark ▸ Show Marker List (⌃⌘M): the title names the file; columns thumbnail, In, Out, Duration,
   Color, Name, Notes (wrapped), Keywords. Open a second player window with another fixture and click between the two:
   the window follows.
3. **Thumbnails.** In the window and the slot (gear ▸ Thumbnails on and off). Play the file with the window open:
   playback is smooth and no new thumbnail appears until you pause. Check one HDR file (on the LG) and the MXF. Delete a
   marker: its JPEG goes from `~/Library/Caches/com.graviton.manifold/MarkerThumbnails/<fingerprint>/`.
4. **Timecode fields.** ⌥M, Duration "100", Tab: it reads 00:00:01:00 and End is a second on. Duration "1", Return: one
   frame. Time "+10": ten frames later. Repeat Duration "100" on `mk-25-notc.mp4` and `mk-2997df-tc.mov` (25 and 30
   frames). On the DF file type Time "1000000" then "1010000": the second lands on 01:01:00;02. In the transport,
   type 100 ⏎: still one second on, unchanged.
5. **Edit Marker.** Playhead on a marker, ⇧M: that marker. Playhead a few frames after it: ⇧M opens it too (the nearest
   before). Before the first marker: a beep.
6. **Clicks.** In the slot and the window: click a row, the playhead jumps; click it again after moving the playhead, it
   jumps again; ⌘-click two more, no jump, three selected; ⇧-click a range; ⌫ deletes them (⌘Z restores); double-click
   opens the editor.

## 13. Follow-ups (Robbie, 2026-11-15)

Built: D23–D26 above. Unit tests added (`MarkerFollowUpTests`, 4): the cache path holds the version and an older build's
folders (unversioned, and `v1`) are never read and are purged; Regenerate removes only the chosen frames and Delete All
removes everything; `MarkerStore.deleteAll` counts and removes; both preferences default on. `ShortcutRegistryTests`:
Show Markers counted (30 keyed menu actions). Whole package: 1059 test cases, 0 failures. Profile build: succeeded, no new
warnings. Not launched.

Attended steps (guarded launch as §8.2; on `mk-2398-tc.mov` with a few markers):

1. **Regenerate.** Slot gear ▸ Regenerate Thumbnails: the slot's thumbnails go grey and come back. Window toolbar ▸
   Regenerate Thumbnails: the same. Right-click one row ▸ Regenerate Thumbnail: only that one. Press Play first and
   regenerate: nothing is remade until you pause. `ls ~/Library/Caches/com.graviton.manifold/MarkerThumbnails/`: only
   `v2/`.
2. **Remember off.** Settings ▸ Files ▸ Markers: turn Remember off. Open `mk-25-notc.mp4`, add two markers: no new file in
   `~/Library/Application Support/com.graviton.manifold/Markers/`, nothing new under `MarkerThumbnails/v2/`. Close and
   reopen it: no markers. Reopen `mk-2398-tc.mov`: it starts empty (stored ones not read). Turn Remember on, reopen
   `mk-2398-tc.mov`: its stored markers are back.
3. **Delete All Stored Markers…** Cancel first: nothing changes. Then confirm: Markers/ and MarkerThumbnails/ are gone, and
   the open windows' lists are empty.
4. **Show Markers.** View ▸ Show Markers (⇧⌥⌘M) off: flags gone, slot and window say "Markers are hidden…". Quit by PID
   and relaunch: still off. Press M: a marker is added and Show Markers is on again (check the View menu tick).
5. **Wording.** Window toolbar: a filter icon with the tooltip "Filter by Colour", then "Regenerate Thumbnails",
   "Import…", "Export…" as text. Slot gear: "Import Markers…", "Export Markers…".

