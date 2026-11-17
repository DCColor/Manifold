# Embedded chapters shown as markers: plan (0.9.5)

Status: **Stage 1 built (2026-11-16): fixtures, the libav reader, the pure mapping and their tests. No UI.** Decisions
recorded in §8; measurements on the fixtures and on Resolve's and Premiere's own files in §11. The audit below (§0–§7, §9)
is the plan as first written the same day. Where §11 settles one of its UNKNOWNs, §11 says so.

Goal (Robbie, 2026-11-16): when a file has embedded chapters, they appear the way Manifold's markers do: on the timeline
strip, in the Markers slot and window, and with the navigation keys.

Each claim is marked **CONFIRMED** (a file:line, or a command and its output) or **UNKNOWN** (with the fixture or step
that settles it). Paths are relative to this repo unless they start with `~`. Flip paths are under `~/Code/Flip/Flip`.
No chapter or marker text from client files is quoted anywhere in this plan. The only titles that appear are fixture
titles proposed in §5.

The decisions needed from Robbie are collected in §8.

---

## 0. What Manifold already does with chapters

Manifold already reads chapters, but only for the Inspector.

- **Reader:** `MediaInspector.chapters(for:)`, `Packages/ManifoldCore/Sources/ManifoldCore/MediaInspector.swift:402-421`
  (CONFIRMED).
  - It loads `availableChapterLocales`, takes the first locale or falls back to `Locale.current`, and calls
    `loadChapterMetadataGroups(withTitleLocale:containingItemsWithCommonKeys: [])`.
  - From each group it keeps `timeRange.start.seconds` and the `commonKeyTitle` string.
  - It **substitutes "Chapter" for an empty or missing title** (`:413`).
  - It **drops the duration** that `timeRange` carries.
- **Called from:**
  - `MediaInspector.metadata(for:url:)` (`MediaInspector.swift:78`). That runs as a detached task on the AVFoundation
    path (`FrameEngine.swift:2975-2981`).
  - The container-slack route (`FrameEngine.swift:3376-3388`).
- **Stored as** `ChapterMarker { time: Double, title: String }` (`VideoMetadata.swift:8-11`), in `VideoMetadata.chapters`
  (`VideoMetadata.swift:420`).
- **Shown** only as a count, under the label **"Markers"** (`App/InspectorPanel.swift:181-184`).
  - That label will clash with real markers. Rename it to "Chapters" whatever option is chosen.
- **MXF:** the libav path never reads chapters. `applyLibavMetadata` builds a fresh `VideoMetadata` with no chapters
  (`FrameEngine.swift:3432-3450`).
- **The Markers feature ignores all of this.** `MarkerModel` reads only the App Support store
  (`App/Markers/MarkerModel.swift:100-130`).

---

## 1. Chapter forms

### 1.1 Overview

| Form | Where it lives | Fields it can carry | Written by |
|---|---|---|---|
| **QuickTime chapter track** | A `text` track (QuickTime) or a `text`/`sbtl` track (MP4). A `tref` box of type `chap` in another track (normally the video track) points at it. Each text sample is one chapter. | **Start:** sample time. **Duration:** sample duration. **Title:** sample text, in UTF-8 or a UTF-16 BOM, with an optional `encd` atom. **Language:** the track's `mdhd`. A file can carry one chapter track per language. Optional `href` URL atoms in the sample. Optional **chapter images:** a second track (JPEG/PNG video) that the same `chap` tref also lists. | ffmpeg's mov muxer, from `-map_chapters` or ffmetadata. Reportedly also Compressor, Final Cut Pro, Resolve (Deliver ▸ chapters from markers), Premiere/Media Encoder for H.264, and iTunes-style tools. **Every writer except ffmpeg is UNKNOWN here (step W1).** |
| **Nero `chpl`** | `moov/udta/chpl`. A flat list. | Start in 100 ns units, plus a title of 255 bytes or fewer. **No end, no language, no images.** | ffmpeg's mp4/mov muxer by default; `-movflags disable_chpl` turns it off. Its help text lists that flag for both `mp4` and `mov` (CONFIRMED: `ffmpeg -h muxer=mp4` and `-h muxer=mov` both print `disable_chpl … Disable Nero chapter atom`). Also MP4Box and mp4v2/mp4chaps (neither is installed here). |
| **XMP markers** (`xmpDM:markers` in `xmpDM:Tracks`) | MOV: `moov/udta/XMP_`. MP4: a top-level `uuid` box holding the XMP packet. | startTime, duration, name, comment, **type** (Chapter, Cue, Index, Segmentation, WebLink, FLVCuePoint), cuePointType, cuePointParams, location (URL), and a per-track frameRate. | Premiere Pro and Media Encoder ("Include markers"/XMP). **UNKNOWN on a real file here** (step W1). ffmpeg cannot write it. |
| **Matroska / WebM chapters** | `Chapters` element | start, end, multi-language titles, nesting | Not opened as files today. Manifold's libav build has only the `mov`, `mxf` and `mpegts` demuxers (`scripts/build_ffmpeg.sh:263-265`, CONFIRMED). Out of scope. |
| **MXF** | no standard chapter construct; DMS-1 / text-based descriptive metadata exists | (none that libav maps to chapters, as far as known) | **UNKNOWN** whether libav's MXF demuxer ever fills `AVFormatContext.chapters`. The reader would simply return none. |
| **MPEG-TS** | none | (none) | (none) |

Which forms matter:

1. **The QuickTime chapter track.** This is what Apple tools, Resolve and ffmpeg write, and what QuickTime Player shows.
2. **Nero `chpl`.** ffmpeg writes it beside the track by default. Some files carry nothing else, for example from
   MP4Box/Handbrake-era tools.
3. **XMP markers.** These matter for Premiere users, but **neither AVFoundation nor libav reads them**, and Flip doesn't
   either (§9). If Manifold reads them, it needs a reader of its own. Recommended later, not in 0.9.5 (§7.3).

### 1.2 What ffmpeg writes (from its help text; the box layout is UNKNOWN until fixture F1/F3)

- With chapters in the input (`-map_chapters` / ffmetadata), the mov and mp4 muxers are expected to write **both** a
  chapter text track with `tref chap` and a `chpl`. `disable_chpl` is the only switch, and it removes `chpl` only. No
  flag removes the chapter track (CONFIRMED: no such option in `ffmpeg -h muxer=mp4`).
  - So **ffmpeg alone cannot write a `chpl`-only file.** F2 (§5) makes one with a 4-byte patch.
- The time scale ffmpeg gives its chapter track is **UNKNOWN**. If it is 1/1000, chapter times are quantized to
  milliseconds, and a chapter on a 23.976 frame can land a hair before that frame (§3.1). F1 and F4 measure it.
- How the boxes are verified is a confirmed command, run on the existing marker fixtures:
  `ffmpeg -hide_banner -v trace -i <file> 2>&1 | grep -oE "type:'[a-z0-9 ]{4}' parent:'[a-z0-9 ]{4}'"`. It printed
  `type:'tmcd' parent:'tref'` for `mk-2398-tc.mov` and `type:'elst' parent:'edts'` for both fixtures.

---

## 2. Reading paths

### 2.1 Which path opens which file today (CONFIRMED)

- **`.mxf`:** libav only. Routed by extension (`FrameEngine.swift:2806`, `:2953-2958`). AVFoundation never opens it.
- **`.mov` / `.mp4` whose video track AVFoundation can see:** AVFoundation demuxes it, and the inspection runs through
  `MediaInspector.metadata` (`FrameEngine.swift:2975-2981`).
  - DNxHR in a `.mov` is **decoded** by libav (`useLibav = MediaInspector.requiresLibavDecode(fmt)`,
    `FrameEngine.swift:3062`), but its metadata still comes from AVFoundation.
- **`.mov` whose video track AVFoundation hides (`stsd` slack, `ContainerSlackRoute`):** libav demuxes it. AVFoundation
  still reads chapters, dates and captions through `mergeContainerRouteMetadata` (`FrameEngine.swift:3348-3391`,
  `:3796-3797`).
- **Every path also opens the file a second time with libav, off the main actor, before playback starts:**
  `HDR10MetadataReader.read(url:)` (`FrameEngine.swift:2947`, `HDR10Metadata.swift:319`).
  - So a separate libav open per load is already normal. It costs the moov parse, not a decode.

### 2.2 AVFoundation

- **API:** `AVAsset.load(.availableChapterLocales)`, then
  `loadChapterMetadataGroups(withTitleLocale:containingItemsWithCommonKeys:)` or
  `loadChapterMetadataGroups(bestMatchingPreferredLanguages:)`. Each `AVTimedMetadataGroup` has a `timeRange` (start and
  duration) and items: the title, and, when a common key such as `.commonKeyArtwork` is asked for, the chapter image.
  Async variants are in use today (`MediaInspector.swift:404-407`, CONFIRMED).
- **Time:** `timeRange` is on the **asset timeline**, the same timeline as the engine's `currentTime` on that path. It
  is a `CMTime`, so its timescale (the chapter track's tick) is available.
- **QuickTime chapter track:** read. That is AVFoundation's model. Whether it needs the `tref chap` is **UNKNOWN**; F2
  orphans the track and tests it. Apple's documentation describes chapters only through the reference.
- **Nero `chpl`:** **UNKNOWN**, widely reported as not read. F2 settles it.
- **XMP:** not as chapters. XMP is not exposed through `chapterMetadataGroups`.
- **Language:** the current code takes `locales.first ?? Locale.current` (`MediaInspector.swift:405`). Two things are
  **UNKNOWN** (F6, and W1 for real multi-language files):
  - what a chapter track tagged `und` (ffmpeg's default) returns under `Locale.current`;
  - whether `bestMatchingPreferredLanguages` would be safer.
- **MXF:** not available. AVFoundation cannot open MXF.

### 2.3 libav

- **API:** `AVFormatContext.nb_chapters` / `chapters`. Each `AVChapter` has `id`, `time_base`, `start`, `end`, and
  `metadata` (`title`) (`ThirdParty/ffmpeg/include/libavformat/avformat.h:1224-1229`, `:1365-1366`, CONFIRMED).
  - Times are exact rationals in `time_base`. For the `chpl` form the time base is expected to be 1/10 000 000; for the
    chapter track, that track's time base. Both are **UNKNOWN** until F1 and F2 print them.
- **Filled by the mov demuxer at `avformat_open_input`.** No `avformat_find_stream_info` is expected to be needed.
  **UNKNOWN**: the reader's unit test (§6.3) proves it on F1.
  - The demuxer has an `ignore_chapters` option, default false (CONFIRMED: `ffmpeg -h demuxer=mov`).
  - Flip's tests rely on the mov demuxer finding a MOV's chapters "only through the video track's `chap` tref"
    (`tests/reorder-chapters.test.js:88-89`).
- **`chpl`:** expected to be read. **UNKNOWN** until F2. If a file has both forms, whether libav reports each chapter
  once or twice is **UNKNOWN** until F3.
- **Time base handling:** chapter times are on the demuxer's timeline. The engine's libav timeline subtracts the video
  stream's `start_time` (`LibavFrameSource.swift:359-360`; the frame grid's frame 0 is "the engine timeline's 0",
  `FrameEngine.swift:2172-2177`). So the reader must subtract the **video stream's** `start_time` from each chapter's
  start and end, to land on the same timeline as the frames.
- **Edit lists:** `mk-2398-notc.mp4` carries an `elst` with media time 2002 (two B-frame delays at 1/24000), and libav
  reports `start_time: 0` (CONFIRMED: `ffmpeg -v trace` printed
  `Processing st: 0, edit list 0 - media time: 2002 … stream 0: start_time: 0`). Whether libav's chapter times and
  AVFoundation's agree on such a file is **UNKNOWN**; F4 is built on it to answer exactly that.
- **Language and images:** libav exposes neither for mov chapters, as far as known (**UNKNOWN**). With several chapter
  tracks (one per language), which one libav reads is **UNKNOWN**, and ffmpeg can't write that case (§5).

### 2.4 Reading without touching playback

Both readers can run without touching playback, as a separate read on open, off the main thread:

- **AVFoundation:** a new `AVURLAsset` on the URL. Its loads are async. The AVFoundation path already does this for the
  Inspector, and it never touches the player.
- **libav:** a private `AVFormatContext`, opened, read and closed in one function, exactly as `HDR10MetadataReader`
  does.
- Either one runs as a `Task.detached` started from `MarkerModel.fileChanged` next to the fingerprint
  (`MarkerModel.swift:120-130`), with the same `loadToken` guard so a stale result is dropped.

### 2.5 Recommendation: libav, one reader, every container

**Use libav for every file**, as a new pure reader that returns `[FileChapter]`. Reasons:

1. **The same file shows the same chapters in Manifold and Flip.** Flip's only chapter source is libav's
   `AVFormatContext.chapters`, dumped by its bundled ffmpeg (§9.1). The two apps pin **the same FFmpeg commit**:
   - Manifold: `n8.1.1 = 239f2c733de417201d7ad3b3b8b0d9b63285b2b1` (`ThirdParty/ffmpeg/README.md:127`);
   - Flip: the same tag and commit (Flip `binaries/README.md:13-18`).

   Both CONFIRMED. AVFoundation would follow Apple's rules instead (locale choice, `chpl` support, and possibly title
   decoding), and could disagree with Flip on the same file.
2. **One path for MXF, the container-slack route and the AVFoundation files.** No per-route merge is needed.
3. **Exact rational times and an explicit time base**, which the frame mapping needs (§3.1).
4. **Cost:** one libav header parse per open, off the main thread, like the HDR10 read already on every load.

AVFoundation's reader stays useful as a **cross-check in the fixture tests** (§6.3). Where the two disagree on a
fixture, the plan records it before anything ships.

**The Inspector should count from the same reader**, under the label "Chapters", so the Inspector and the Markers list
never disagree. This means replacing `MediaInspector.chapters` and its use in `mergeContainerRouteMetadata`.

**Known divergence from Flip, on purpose.** Flip does not subtract `start_time` (§9.1). On a file whose video starts
after 0, Manifold's chapter frames would be right for Manifold's own frame numbers and differ from Flip's displayed
seconds by that offset. Both are **UNKNOWN in practice**; F4 shows whether any common file has `start_time ≠ 0`.

---

## 3. Mapping chapters onto markers

### 3.1 Time → frame

A marker's frame `f` is the frame at engine time `f / rate`, counted from the engine timeline's 0. CONFIRMED in three
places:

- markers are added at `round(pts × rate)` (`MarkerModel.swift:208-215`);
- they are drawn at `frame / rate` (`App/Markers/MarkerEditorSheet.swift:245`);
- they are reached by a seek to `(f + 0.25) / rate` (`App/TimecodeEntry.swift:375-379`).

The rate is the file's metadata rate, with the timecode track's rate as the fallback (`MarkerModel.basis`,
`MarkerModel.swift:192-199`). **Chapters use exactly this frame index.** Timecode then comes for free:

- `TimecodeBasis` labels a frame with the file's `tmcd` or container timecode, or with the D6 start override on a file
  without timecode (`Marker.swift:64-97`).
- So a chapter at 10 s in a file whose timecode starts at 01:00:00:00 reads `01:00:10:00` (frame 240 at 23.976, which
  is 10.01 s).
- The override relabels chapters too. **Chapters never store a timecode.**

**The rounding rule, proposed as a pure function** `ChapterMapping.frame(start:timeBase:rate:)`:

- `frame = floor(t × rate + tolerance)`, where:
  - `t` is the chapter start, already moved onto the engine timeline (§2.3);
  - `tolerance = min(one tick of the chapter's own time base, in frames, 0.5) + 1e-6`.
- Computed from the rationals where possible, so 23.976 boundaries are exact.
- **Why floor:** a chapter part-way through a frame names the frame **showing** at that time. Three other things show
  the same frame:
  - what a seek to the chapter's time displays;
  - what `FrameGrid.frame(atSeconds:)` returns (`Packages/ManifoldCore/Sources/FrameGrid/FrameGrid.swift:72-84`);
  - what was on screen when Flip's user pressed **m**. Flip stores `round(seconds × 1000)` at 1/1000
    (Flip `electron/main.js:932-935`).
- **Why the tolerance:** writers quantize. Flip writes 1/1000, `chpl` uses 100 ns, and ffmpeg's chapter-track timescale
  is UNKNOWN (§1.2). For example:
  - Frame 241 at 23.976 is 10.0516… s; stored in milliseconds it becomes 10.051 s, which is 240.99 frames.
  - A plain floor would put a chapter authored on frame 241 onto frame 240.
  - One tick of slack corrects that. It cannot move a genuinely mid-frame chapter by more than one tick.
- **Known inconsistency, not introduced here:** `FrameEngine.currentFrame` **rounds** `currentTime × fps`
  (`FrameEngine.swift:2548-2551`), but the frame grid **floors**. Paused on a frame, both agree. Chapter mapping follows
  the floor, because that is "the frame showing".

**Edge cases** (each a unit test, §6.3):

| Case | Rule |
|---|---|
| Start before 0 (after the `start_time` subtraction) | If its end is after 0, frame 0. Otherwise dropped and counted. |
| **Start past the last frame** (`totalFrames`, `FrameEngine.swift:2553-2558`) | Dropped, never clamped. The notice line says "n chapters start after the end of the file". Same rule as EDL import (`docs/MARKERS_PLAN.md` §6.4: "listed and skipped, not clamped"). |
| End past the end | Clamped to the last frame. |
| Two chapters landing on one frame | Both kept in the list, in file order. The strip draws one flag, with both titles in its tooltip. Navigation stops once. |
| Unsorted chapters in the file | Sorted by frame, ties kept in file order. Flip also sorts by start (Flip `electron/main.js:928`). |
| The rate is not known yet (it can land after the file, `MarkerModel.swift:62-64`) | Mapping waits for `basis`, as thumbnails do (`ThumbnailFeed`). Chapters are kept in seconds until then. |
| Variable-rate file | The marker rule as-is: `metadata.frameRate`. Not worse than markers. |

### 3.2 Fields

| Marker field | From a chapter |
|---|---|
| frame | §3.1 |
| duration | `end − start` in frames, at least 1, when the file states a positive end. Otherwise (no end, or `end ≤ start`, as in Flip's zero-length markers, Flip `electron/main.js:932-935`) it runs up to the next chapter's frame. The last chapter runs to the end of the file. |
| name | The title, made single-line (`Marker.singleLine`, `Marker.swift:46-48`). **An empty title stays empty**, not "Chapter" as the Inspector does today (`MediaInspector.swift:413`). D3 already chose empty names, and Flip keeps empty titles. |
| notes | empty |
| keywords | none on the chapter layer. On Convert, see D-C4 (§8). |
| color | A chapter has none. In Option A it is drawn in a style of its own, not one of the 16 colors (§4.1). On Convert, see D-C4. |

Language, URLs and chapter images are not carried. libav doesn't expose them (§2.3).

### 3.3 One marker per frame (D19)

D19 says no two **markers** start on one frame (`MarkerRules.occupant`, `Marker.swift:183-193`).

- **Option A:** chapters are not markers, so they occupy nothing.
  - M on a chapter's frame adds a user marker there.
  - Both are shown; the user marker's flag is drawn over the chapter's.
  - **Convert** goes through the import merge rule (`ResolveEDL.merge`, `ResolveEDL.swift:317-327`):
    - a chapter on a frame that already has a different marker is skipped and counted;
    - a chapter on a frame whose marker has the same name and empty notes is identical, so it merges.
  - After Convert, a chapter whose frame holds a marker with the **same name** is hidden from the list and the strip as
    "converted", so nothing shows twice.
- **Option B:** an imported chapter is a marker, so D19 applies at import. A chapter on a frame that already has a
  marker is skipped and counted, which can only happen on a re-import.

### 3.4 Fingerprint and storage

**Chapters belong to the file, not to the App Support store.** In Option A:

- They are re-read from the file on every open and never written to `Markers/`.
- They don't depend on the fingerprint; they need only the URL.
- They are therefore shown even when **Remember markers between sessions** is off (D24, `docs/MARKERS_PLAN.md` §5.2),
  since nothing is stored.
- Option B ties them to the fingerprint (§4.2).

---

## 4. Design options

### 4.1 Option A: a read-only chapter layer (recommended)

**What the user sees:**

- **Timeline strip:** a chapter is a flag of the same size as a marker's, at its frame, but **outlined, not filled**:
  - a 1 pt stroke in a fixed neutral (white at 85%), with no fill;
  - **no duration band**, because chapters run end to end and their bands would cover the whole strip.
  - Proposed as `TrackMarker.style = .filled | .outline`, in `Packages/ManifoldCore/Sources/PlayheadSlider/PlayheadSlider.swift:544-555`
    and drawn by the branch at `:612-640`.
  - Outline plus neutral can't be mistaken for any of the 16 filled colors, including Cream (#F6EEE5).
  - The tooltip reads "Chapter · 01:00:10:00 · <title>".
  - A click jumps, as with a marker flag.
  - User markers draw over chapters at the same x.
- **Markers slot and window:**
  - Chapter rows are interleaved with markers in time order.
  - In the color column, a chapter row shows an SF Symbol (`book.closed`) instead of a swatch.
  - The name is shown as for markers; the duration comes from §3.2.
  - Rows are not editable. Double-click jumps, and the editor sheet doesn't open.
  - The context menu has **Convert to Marker** (this row or the selection) and **Convert All Chapters to Markers**.
  - Delete (⌫) skips chapter rows.
  - The window's header count reads "12 markers · 8 chapters".
- **Color filter:** a "Chapters" chip in the filter row (`colorFilter`, `MarkerModel.swift:49`). With a filter active,
  chapters show only if the chip is chosen.
- **Navigation:** **⇧↑/⇧↓ include chapters** (the goal says "navigation keys"). They walk the union of visible marker
  and chapter frames, deduplicated. This needs a change to `goToNeighbour` (`MarkerModel.swift:352-357`). Edit Marker
  (⇧M) ignores chapters, which can't be edited.
- **Show/hide:** View ▸ Show Markers (D25) hides chapters too, since they are drawn in the same places. A separate
  **View ▸ Show Chapters** (default on, no default key) lets someone hide chapters alone. See D-C3.
- **Inspector:** the row is renamed "Chapters" (§0).

**Behaviour:**

| Situation | Option A |
|---|---|
| Re-open | Re-read from the file. Always current. |
| File changed on disk | The next open shows the new chapters. An open file isn't watched; markers aren't either. |
| User edits | None on chapters. Convert first, then edit the marker. |
| EDL / CSV / text export | **User markers only**, so the exporters are untouched (`MarkerFileIO.swift:69-91` passes `model.markers`). To export chapters, Convert first. An "Include chapters" checkbox is an option for later (D-C5). |
| Import (EDL) | Unchanged. Imported markers may land on chapter frames; D19 doesn't involve chapters. |
| Thumbnails (exact-frame cache v3) | Chapter frames join the thumbnailer's frame set (`syncThumbnails`, `MarkerModel.swift:444-448`). The cache is keyed by fingerprint and frame (`MarkerThumbnailCache.swift:24`, `:47`, `:78`), so a chapter and a marker on one frame share one JPEG. `keepOnly` / `sync` (`MarkerThumbnailer.swift:86-94`) must receive the **union** of marker and chapter frames, or deleting a marker would delete a chapter's thumbnail. With Remember off, chapter thumbnails are memory-only, as markers' are (`usesDisk`, `:55-57`). No cache version bump: the picture is unchanged. |
| Delete All Stored Markers… | Deletes the stored markers. Chapters stay, because they come from the file. |
| Privacy | Chapter titles are content from client files: never logged (counts only, as `MarkerLog`), never in Export Diagnostics. A new `MarkerLog` line: `[MARKERS] chapters n=8 dropped-past-end=1 reader=libav`. Nothing new stored, so no PRIVACY_AUDIT §1 row; a §2 Logging line. |

**Risks to markers v1:** low.

- The store, `MarkerDocument`, D19, the editor and the exporters don't change.
- What changes:
  - `MarkerModel` gains a second list;
  - the list views gain a row kind;
  - the strip gains a style;
  - `goToNeighbour` and thumbnail sync take a union.
- The main regression risk is the thumbnail union: a wrong set deletes thumbnails. A unit test covers it (§6.3).
- `PlayheadSliderTests` must still pass with only filled markers (byte-identical Ball style).

### 4.2 Option B: imported once into the store, flagged

**What the user sees:** on the first open, every chapter becomes a normal colored marker, with a "from file" badge, and
can be edited and deleted.

| Situation | Option B |
|---|---|
| Re-open | From the store. A `chaptersImported` flag in `MarkerDocument` stops re-importing, so a deleted chapter stays deleted. |
| File changed on disk | The fingerprint changes (if the first or last 4 MB changed), so this is a new document and the chapters are imported again. The old document is orphaned, as markers are today. If the change keeps the fingerprint, new chapters are **never seen**. |
| User edits | Free; they are markers. The badge stays, or clears on edit (a decision). |
| Export | Included automatically. That can surprise someone exporting "their" notes. |
| Thumbnails | On disk for every chaptered file opened, even ones the user never marked. |
| Remember off | Imported again on every open, in memory only. |
| Delete All Stored Markers… | Deletes them; the next open imports them again. Surprising. |

**Risks to markers v1:** higher.

- A schema change: `Marker.origin` and `MarkerDocument.chaptersImported`. An additive Codable change, but 0.9.4 would
  read imported chapters as plain user markers.
- A store write for files the user never touched: client chapter titles copied into App Support, which needs a new
  PRIVACY_AUDIT §1 row.
- An undo-stack question: is the first-open import undoable?
- D19 skips at import.
- Changes to the files would never be followed.

### 4.3 Recommendation

**Option A**, as Robbie leans.

- Chapters are the file's facts, like its timecode: read every time, never copied without being asked.
- Convert gives Option B's editability on request, through the import merge rule markers v1 already tests.
- Option B's main benefit, editing a chapter, costs the store a schema change and a write on every chaptered file.

---

## 5. Fixtures (specified, not created)

**Location:** `~/Code/Manifold/fixtures/chapters/`.

**Binary:** `/opt/homebrew/bin/ffmpeg` ("ffmpeg version 8.1.1-https://www.martin-riedl.de"), by absolute path, run
only, as for the marker fixtures.

- There is **no ffprobe on PATH** (CONFIRMED: `which ffprobe` → not found), so verification uses `ffmpeg -i` and
  `-v trace`.
- `exiftool` and `mediainfo` are present in `/opt/homebrew/bin` and may be run read-only as a second opinion.

**Base:** the marker fixtures, **stream-copied** (no re-encode), so every frame keeps its burned-in "F n" and timecode
label (`~/Code/Manifold/fixtures/markers/README.txt`).

- Flip's write recipe (`-map 0 -map -0:d -map_chapters 1 -map_metadata 0 -c copy`, Flip `electron/ffmpeg.js:513-519`)
  drops the source tmcd stream.
- Flip's tests show the muxer writes the same tmcd back, drop-frame included (Flip
  `tests/tc-chapters-streams.test.js:7-10`, `:116-134`).
- Every fixture is checked for its timecode after writing anyway.

```sh
FF=/opt/homebrew/bin/ffmpeg
SRC="$HOME/Code/Manifold/fixtures/markers"
OUT="$HOME/Code/Manifold/fixtures/chapters"
mkdir -p "$OUT"

# ffmetadata chapter lists. TIMEBASE 1001/24000 = one frame at 23.976, so START is the frame number.
cat > "$OUT/ch-2398-onframe.ffmeta" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1001/24000
START=0
END=240
title=Opening
[CHAPTER]
TIMEBASE=1001/24000
START=240
END=721
title=Second
[CHAPTER]
TIMEBASE=1001/24000
START=721
END=1200
title=Third
[CHAPTER]
TIMEBASE=1001/24000
START=1200
END=1438
title=Last
EOF

# Milliseconds, not on frames. 10.500 s = 251.748 frames → 251; 20.020 s = 480.0 → 480;
# 30.000 s = 719.28 → 719; 10.051 s = 240.98 (frame 241 quantized to ms) → 241 with the tick tolerance, 240 without;
# 45.000 s with END=START (Flip's zero-length marker); 70.000 s past the 60 s end (dropped).
cat > "$OUT/ch-2398-offgrid.ffmeta" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=10051
title=Zero
[CHAPTER]
TIMEBASE=1/1000
START=10051
END=10500
title=Quantized 241
[CHAPTER]
TIMEBASE=1/1000
START=10500
END=20020
title=Mid frame 251
[CHAPTER]
TIMEBASE=1/1000
START=20020
END=30000
title=Exact 480
[CHAPTER]
TIMEBASE=1/1000
START=30000
END=45000
title=Mid frame 719
[CHAPTER]
TIMEBASE=1/1000
START=45000
END=45000
title=Zero length
[CHAPTER]
TIMEBASE=1/1000
START=70000
END=71000
title=Past the end
EOF

# 25 fps, plain seconds.
cat > "$OUT/ch-25.ffmeta" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/25
START=0
END=250
title=One
[CHAPTER]
TIMEBASE=1/25
START=250
END=751
title=Two
[CHAPTER]
TIMEBASE=1/25
START=751
END=1500
title=Three
EOF

# Long, non-ASCII, and ffmetadata's reserved characters (= ; # \ must be backslash-escaped in ffmetadata).
cat > "$OUT/ch-25-unicode.ffmeta" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/25
START=0
END=250
title=Café Zürich — Ærøskøbing, Łódź, 東京, Ελληνικά, 🎬 a long chapter title that keeps going well past one hundred characters to test truncation and wrapping in the list and the tooltip
[CHAPTER]
TIMEBASE=1/25
START=250
END=1500
title=Reserved \= \; \# \\ characters
EOF

# 29.97 DF across the minute: frame 1800 = 01:01:00;02.
cat > "$OUT/ch-2997df.ffmeta" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1001/30000
START=0
END=1799
title=Before the minute
[CHAPTER]
TIMEBASE=1001/30000
START=1799
END=1800
title=Last frame of minute 0
[CHAPTER]
TIMEBASE=1001/30000
START=1800
END=2097
title=First label after the drop
EOF
```

| # | Fixture | Command | Tests |
|---|---|---|---|
| F1 | `ch-2398-tc-track.mov`: QuickTime chapter track only, tmcd 01:00:00:00 | `"$FF" -i "$SRC/mk-2398-tc.mov" -i "$OUT/ch-2398-onframe.ffmeta" -map 0 -map -0:d -map_chapters 1 -map_metadata 0 -c copy -movflags disable_chpl "$OUT/ch-2398-tc-track.mov"` | Chapter track via tref; timecode labels (frame 240 = 01:00:10:00); the chapter track's time scale (§1.2) |
| F2 | `ch-25-chpl.mp4`: **`chpl` only** (track orphaned) | ffmpeg can't write this (§1.2). Copy F3, then overwrite the 4-byte type `tref` of the video track's `tref` box (the one whose child is `chap`) with `free`, with a short `python3 -I` script kept in `~/Code/_scratch/manifold-chapters/` and deleted afterwards. Same box size, so no offsets move. | libav reads `chpl`; AVFoundation's `chpl` support; both readers' behaviour without a tref (AVFoundation is expected to report none) |
| F3 | `ch-25-both.mp4`: chapter track **and** `chpl` | `"$FF" -i "$SRC/mk-25-notc.mp4" -i "$OUT/ch-25.ffmeta" -map 0 -map_chapters 1 -map_metadata 0 -c copy "$OUT/ch-25-both.mp4"` | Duplicates when both forms are present (each chapter once?) |
| F4 | `ch-2398-offgrid.mp4`: off-frame chapters, H.264 **with an edit list** (CONFIRMED on the source, §2.3) | `"$FF" -i "$SRC/mk-2398-notc.mp4" -i "$OUT/ch-2398-offgrid.ffmeta" -map 0 -map_chapters 1 -map_metadata 0 -c copy "$OUT/ch-2398-offgrid.mp4"` | Rounding and tolerance (251, 241, 480, 719); zero length; past the end; libav vs AVFoundation timeline agreement with `elst` |
| F5 | `ch-2997df-tc.mov`: DF timecode track 01:00:00;00 | `"$FF" -i "$SRC/mk-2997df-tc.mov" -i "$OUT/ch-2997df.ffmeta" -map 0 -map -0:d -map_chapters 1 -map_metadata 0 -c copy "$OUT/ch-2997df-tc.mov"` | DF labels (`01:01:00;02`, never `;00`) |
| F6 | `ch-25-unicode.mp4`: long and non-ASCII titles, escaped characters | `"$FF" -i "$SRC/mk-25-notc.mp4" -i "$OUT/ch-25-unicode.ffmeta" -map 0 -map_chapters 1 -map_metadata 0 -c copy "$OUT/ch-25-unicode.mp4"` | UTF-8 round trip in both readers; the `und` language under `Locale.current` (AVFoundation); Flip's escape gap (§9.3) |
| F7 | zero chapters | **No new file:** `$SRC/mk-25-notc.mp4` as is (CONFIRMED: `ffmpeg -i` printed 0 lines matching `Chapter`) | Nothing shown; no notice; the Inspector row hidden |
| F8 | MXF | **No new file:** `$SRC/mk-2997df-tc.mxf` | libav returns 0 chapters on MXF (UNKNOWN until run) |

**Verify each fixture after writing** (prints only fixture titles):

- `"$FF" -hide_banner -i <f> 2>&1 | sed -n '/Chapters:/,/Stream #0:0/p'` (chapters, times, titles);
- `"$FF" -hide_banner -i <f> 2>&1 | grep timecode`;
- `"$FF" -hide_banner -v trace -i <f> 2>&1 | grep -oE "type:'(tref|chap|chpl|text|elst|tmcd|free)' parent:'[a-z0-9 ]{4}'" | sort | uniq -c`.

A `README.txt` beside the fixtures records all of it, as for the marker fixtures.

**Forms ffmpeg can't write:**

- `chpl` alone (F2 patches one);
- XMP `xmpDM:markers`;
- one chapter track per language;
- a chapter **image** track;
- `href` URLs in chapter samples;
- a chapter track that is disabled or has a `chap` tref to it from a non-video track.

These come from **W1**, an attended step like R1:

- Robbie exports the same 10 s clip with three chapters, one with an accented title, from Resolve (Deliver, chapters
  from markers), Final Cut Pro/Compressor, and Premiere/Media Encoder (chapter markers, and XMP markers).
- The files are saved to `~/Code/Manifold/fixtures/chapters/w1/`.
- Read here with the commands above and with `exiftool -ee -G1` (read-only).

---

## 6. Scope, size, files, tests

### 6.1 Scope

**Files only**, as markers v1. No streams, no MXF chapter work beyond "libav returns what it returns", no XMP, no
writing chapters.

### 6.2 Size (Option A)

About **700–900 lines including tests, 2–3 working days** plus W1 and the attended steps. By part:

| Part | Lines (est.) |
|---|---|
| Pure mapping (`ChapterMapping`) | ~150 |
| libav reader | ~120 |
| `MarkerModel` | ~150 |
| List rows, window, slot | ~150 |
| Strip style | ~40 |
| Commands and settings | ~50 |
| Tests | ~300 |

### 6.3 Files that would change

Package (`Packages/ManifoldCore`):

- `Sources/Markers/ChapterMapping.swift` (**new**, pure, no libav):
  - `FileChapter { start, end: (value: Int64, timeBase: (num, den))?, title }`;
  - `frame(start:timeBase:rate:)` with the tick tolerance;
  - durations, drops and counts (§3.1, §3.2);
  - `convert(_:existing:) -> ResolveEDL.MergeResult` through `ResolveEDL.merge`;
  - the "converted" suppression;
  - the union of navigation frames.
- `Sources/ManifoldCore/ChapterReader.swift` (**new**): libav open, read `chapters`, subtract the video stream's
  `start_time`, close. Returns `[FileChapter]`.
  - **As built (Stage 1): `Sources/ChapterRead/ChapterReader.swift`, a new leaf target `ChapterRead` (CFFmpeg + Markers),
    not ManifoldCore.** No test target links ManifoldCore (it is named only at `Package.swift` product and target lines),
    so a reader inside it could not be tested on real files. This is the same move `FrameRequest` made into FrameGrab
    (MARKERS_PLAN §15). The app links `ChapterRead` in Stage 2.
  - The reader returns the chapters as stated plus the video stream's `start_time`; the subtraction is done exactly in
    `ChapterMapping.map(_:origin:rate:lastFrame:)`, with that `start_time` as the origin. See §11.4 for why the origin
    must depend on the playback path.
- `Sources/ManifoldCore/MediaInspector.swift`: drop `chapters(for:)`, or keep it test-only as the cross-check.
- `Sources/ManifoldCore/VideoMetadata.swift`: `chapters` fed from `ChapterReader` (count only).
- `Sources/ManifoldCore/FrameEngine.swift`: the Inspector's chapter count from the reader on every route (`:3385`, the
  libav metadata path).
- `Sources/Markers/MarkerLog.swift`: the chapters log line (counts only).
- `Sources/PlayheadSlider/PlayheadSlider.swift`: `TrackMarker.style`, outline drawing, no band for chapters.
- `Sources/ShortcutRegistry/ShortcutCatalog.swift` (+ `MenuKeyAudit.menuHomes`): "Convert All Chapters to Markers" (Mark
  menu, no key), "Show Chapters" (View, no key).
- `Package.swift`: no new target if the reader lives in ManifoldCore, which already depends on CFFmpeg
  (`Package.swift:826`).

App:

- `App/Markers/MarkerModel.swift`: `chapters` (published), the read in `fileChanged` beside the fingerprint, mapping on
  `basis`, the union in `goToNeighbour` and `syncThumbnails`, Convert with undo.
- `App/Markers/MarkersScopeView.swift`, `App/Markers/MarkersWindow.swift`: chapter rows, the Chapters chip, the context
  menu, the header count.
- `App/Markers/MarkCommands.swift`: the Convert item. `App/ContentView.swift`: the `TrackMarker` style for chapters.
- `App/Markers/MarkerThumbnailer.swift`: no logic change, but it is given the union (test it).
- `App/InspectorPanel.swift:183`: "Markers" → "Chapters".
- `docs/PRIVACY_AUDIT.md` §2 (a log line); `docs/MARKERS_PLAN.md` (a pointer here).

### 6.4 Tests

**`ChapterMappingTests`** (pure, in `MarkersTests`):

- Frame-exact at 23.976, 25 and 29.97.
- The tick tolerance: 10.051 s at 1/1000 → 241, while a true 10.0505 s mid-frame value at 1/10 000 000 → 240.
- Mid-frame floors: 10.5 s → 251, 30 s → 719.
- Start before 0; past the end, dropped and counted; end clamped.
- Durations: from end; from the next chapter when the end is missing or ≤ start; the last to the file's end.
- Two on one frame; unsorted input.
- Empty titles stay empty; multi-line titles become one line.
- Timecode labels through `TimecodeBasis` with tmcd 01:00:00:00, DF across the minute, and the D6 override.
- Convert: occupied frames skipped, identical ones merged, counts returned.
- The "converted" suppression.
- The navigation union, deduplicated.
- The thumbnail frame union, so deleting a marker keeps a chapter's frame.
- `MarkerLog` chapters line holds no title (sentinel test, as in `MarkerFilesTests`).

**`ChapterReaderTests`** (links libav, as `LibavFrameRequestTests` does, `Package.swift:609-612`):

- Small fixtures under `Tests/…/Fixtures`, made once like `df-bars-2997.mxf`: 160×90, a few frames each, one per form
  F1–F4 and F6.
- Asserts libav's times and titles.
- **Also reads the same files with AVFoundation and records where the two agree or differ.** That is how the UNKNOWNs
  in §2.2–§2.3 get settled before any UI is built.

**`PlayheadSliderTests`:** unchanged results with filled markers only; the outline style draws no band.

**Attended** (guarded launch, as in `docs/MARKERS_PLAN.md` §8.2):

1. F1–F6: flags, rows, ⇧↑/⇧↓, Convert, D19 collisions.
2. The W1 files from Resolve, FCP/Compressor and Premiere.
3. The same W1 files in Flip, read-only: the same chapters, titles and times to the second.

---

## 7. Open items and later

1. **W1:** which tools write which form, and which language, title encoding and images they use. All UNKNOWN.
2. AVFoundation vs libav differences on F2, F3, F4 and F6 (§6.4). If they disagree on a real file, the plan names which
   one is right for that file before shipping.
3. **XMP markers (Premiere/Media Encoder):** a separate reader for `udta/XMP_` and the MP4 XMP `uuid` box, parsing
   `xmpDM:markers`. That is the richer form: duration, comment, and a type that tells chapters from cues. Recommended
   **after** 0.9.5, and **in Flip too**, so the two apps stay the same (§9.4).
4. Streams. Chapters in a live stream are not a thing; ID3/SCTE markers are a separate idea
   (`docs/ROADMAP_IDEAS.md:416-427`, "Embed Chapter Markers", is about *adding* chapters to a stream, not reading them).

---

## 8. Decisions (Robbie, 2026-11-16)

All as recommended.

| # | Decision | Decided |
|---|---|---|
| D-C1 | Option A or B | **A**, a read-only chapter layer (§4.1) |
| D-C2 | Reading path | **libav for all files.** AVFoundation as a test cross-check only (§2.5) |
| D-C3 | Show/hide | View ▸ Show Markers hides both, plus **View ▸ Show Chapters** (no key) |
| D-C4 | Converted chapters | **Blue**, keyword **"chapter"** |
| D-C5 | Chapters in EDL/CSV export | **None in 0.9.5** (Convert first) |
| D-C6 | Navigation | **⇧↑/⇧↓ include chapters; ⇧M doesn't** |
| D-C7 | Rounding | **Floor with a one-tick tolerance** (§3.1). Built so. **See D-C7a** |
| D-C8 | Converted duration | **The chapter's duration** |
| D-C9 | XMP markers | **Later, in both apps.** §11.5 raises its weight |

**Open, from Stage 1's measurements (§11):**

| # | Question | Recommended |
|---|---|---|
| D-C7a | Resolve rounds its chapter times to **milliseconds** before writing them in 1/24000, so one of its four chapters sits two ticks before its frame and D-C7 puts it on the frame before (§11.3) | Tolerance = **max(one tick, 1 ms)**, still capped at half a frame. It catches every quantized value seen (Resolve, ffmpeg, Flip) and moves a genuinely mid-frame chapter only if it is within 1 ms of the next frame. `testRealAppTicksUnderDC7` pins today's answer (57) so the change is deliberate |
| D-C10 | The origin to subtract (§11.4) | **The playback path's own frame 0:** the video `start_time` for a libav-played file, 0 for an AVFoundation-played one. Stage 2 passes it from `FrameEngine` |
| D-C11 | Premiere MP4s carry their chapters **only as XMP** (§11.5) | Bring XMP forward: either into 0.9.5 (Manifold first, Flip after) or keep D-C9 and say in the release notes that Premiere MP4 chapters do not show |

---

## 9. Flip prior art

Read-only, 2026-11-16. Nothing in Flip was modified, built or run.

- The Flip read was done by a delegated read-only search and reported with file:line.
- The central claims below were checked again by reading the cited lines:
  - `electron/ffmpeg.js:448-491`;
  - `electron/main.js:925-936`;
  - `src/player.jsx:320-328`;
  - `tests/reorder-chapters.test.js:84-92`;
  - `binaries/README.md:13-18`;
  - a grep for `xmp|chpl` over `electron src tests scripts`, which found nothing.

### 9.1 How Flip reads chapters

- **One path: libav through its bundled ffmpeg, as ffmetadata.**
  - `readChapters` runs `ffmpeg -hide_banner -i <file> -f ffmetadata pipe:1` (`electron/ffmpeg.js:466`).
  - It splits stdout on `[CHAPTER]` (`:472`).
  - It takes `TIMEBASE`, `START`, `END` and `title` with a line regex (`:474-478`).
  - It computes `startSecs = START × num/den` (`:450-454`, `:479-480`).
  - So Flip shows exactly libav's `AVFormatContext.chapters` from FFmpeg n8.1.1, the same commit Manifold vendors (§2.5).
- **No ffprobe, no linked libav, no AVFoundation, no XMP, and no `chpl` or `tref` code of its own.**
  - Its atom parser does not look at chapters (`electron/parser/atoms.js:7`, the container list).
  - Which forms Flip supports is therefore whatever ffmpeg's mov demuxer reads: the chapter track (through `tref chap`,
    `tests/reorder-chapters.test.js:88-89`) and, presumably, `chpl` (**UNKNOWN**, F2).
- **Fields:** start, end, time base and title. No language, type, color or comment.
- **Times:** seconds, not snapped to frames. Shown as floored `HH:MM:SS`, elapsed, not timecode (`electron/ffmpeg.js:456-461`).
  - The list header says "TIMECODE" but shows elapsed time (Flip `src/App.jsx:3216`, `:3224`).
  - Sorted by start, merged with markers that haven't been written yet (`electron/main.js:925-930`).
  - **No `start_time` subtraction** (§2.5).
- **Display:** a 2×16 px tick per chapter in one accent color on the player's scrub bar, title as tooltip, not clickable
  (`src/player.jsx:320-328`). No chapter navigation keys. **m** adds a marker (`src/player.jsx:98-99`).
- **Flip's own markers** are written as chapters with time base 1/1000 and **`end = start`**, zero length
  (`electron/main.js:932-935`), by a stream-copy remux (`electron/ffmpeg.js:493-519`).

### 9.2 What Flip handles that this plan didn't have

- **Zero-length chapters.** Flip writes them itself, so any file Flip has marked has `END = START` on every Flip marker.
  This plan's duration rule (§3.2: next chapter, else the file's end) and the F4 zero-length chapter come from this.
- **Millisecond time base** for Flip-made chapters. This is where the tick tolerance in §3.1 comes from: a Flip marker
  on frame 241 of a 23.976 file is stored as 10.051 s.
- **Chapters survive rewraps.** Flip's tests pin titles and times through timecode insert and reorder (Flip
  `tests/tc-chapters-streams.test.js:96-113`, `tests/reorder-chapters.test.js:73-92`).
  - Fix `48d12ef`: a reorder of a MOV with chapters failed because `-map 0:d?` picked up the chapter text track (Flip
    `electron/ffmpeg.js:238-270`, `RELEASE_NOTES.md:26`).
  - Relevance here: the fixture recipe in §5 uses Flip's `-map -0:d`, so the muxer rewrites the tmcd.
- **Missing chapters are Flip's release check for a broken ffmpeg build** (Flip `docs/BUILD.md:72-74`). Manifold's
  `ChapterReaderTests` would play the same role for the vendored libav.

### 9.3 Flip's gaps (not to copy)

- **Ffmetadata escapes are not unescaped on read** (`electron/ffmpeg.js:474`) and **not escaped on write** (`:504`). A
  title with `=`, `;`, `#` or `\` shows differently in Flip than in a libav-API reader. F6's second chapter tests this.
  Manifold reads `AVChapter.metadata` directly, so it has no escaping layer.
- Stdout decoded chunk by chunk (`electron/ffmpeg.js:469`): a multi-byte character split across chunks can be garbled.
  F6 would show it.
- Parse failures return `[]` silently (`electron/ffmpeg.js:485-489`).
- Its display string wraps at 24 h (`electron/main.js:935`).

### 9.4 What to reuse, and keeping the apps consistent

- **Reuse the approach, not the code:** read `AVFormatContext.chapters` from the same FFmpeg commit, take start/end/time
  base/title, and sort by start. Manifold calls the libav API directly (Swift, `CFFmpeg`), with no ffmetadata text or
  subprocess. This is the main reason for D-C2.
- **The same file shows the same chapters in both apps when:**
  - both use libav n8.1.1, which is true today (§2.5);
  - both keep empty titles and zero-length chapters;
  - both sort by start.
- **Where they will still differ, on purpose:**
  - Manifold shows **frame-accurate timecode**, Flip whole elapsed seconds; equal to the second.
  - Manifold subtracts the video `start_time`, Flip doesn't; equal when `start_time = 0`, which is the common case and
    F4's case.
  - Titles with ffmetadata-reserved characters: Manifold correct, Flip escaped.
- **Recommended for Flip, not done here:** fix the escape handling, and add XMP markers in both apps together (D-C9) so
  neither shows markers the other doesn't.

---

## 10. Summary

1. **Recommended: Option A**, a read-only chapter layer re-read from the file on every open. Outlined neutral flags with
   no band; chapter rows with a book symbol in the list; ⇧↑/⇧↓ include them; "Convert Chapters to Markers" copies them
   into the store through the existing import merge rule.
2. **Reading path: libav `AVFormatContext.chapters` for every container**, off the main thread at open, beside the
   fingerprint. It is the same FFmpeg commit Flip reads through (CONFIRMED), so the same file shows the same chapters
   in both apps. AVFoundation is kept only as a cross-check in tests.
3. **Mapping:** the marker frame index (`f / rate` from the engine's 0), floor with a one-tick tolerance. Labels come
   from the existing `TimecodeBasis` (tmcd and the D6 override). Past-the-end chapters are dropped and counted.
4. **Already there:** the Inspector reads chapters via AVFoundation and counts them under "Markers"; rename it to
   "Chapters" and feed it from the same reader.
5. **Size:** about 700–900 lines including about 300 of tests, 2–3 days. One new pure mapping file and one libav reader;
   the store, the editor and the exporters are unchanged.
6. **Risks:** the thumbnail frame union (a wrong set deletes thumbnails); libav vs AVFoundation timeline agreement on
   edit-listed files; the strip's byte-identical Ball test.
7. **Fixtures F1–F6** are stream-copied from the marker fixtures with the given ffmpeg commands. `chpl`-only needs a
   4-byte patch, and XMP, multi-language, chapter images and URLs can't be written by ffmpeg (W1 from real apps).
8. **UNKNOWN:** whether libav reads `chpl` and deduplicates when both forms are present; whether AVFoundation reads
   `chpl` or needs the tref; ffmpeg's chapter-track timescale; libav chapter times vs AVFoundation's on edit-listed H.264.
9. **UNKNOWN:** which tools write which form (Resolve, FCP/Compressor, Premiere/Media Encoder); language and multi-track
   behaviour; MXF chapters via libav. All settled by F1–F8 and W1.
10. **Out of scope:** streams, XMP markers (later, in both apps), writing chapters, and EDL export of chapters (Convert
    first).

---

## 11. Stage 1 measurements (2026-11-16)

Everything here was run on this Mac:

- the fixtures with `/opt/homebrew/bin/ffmpeg` (Riedl 8.1.1, run only);
- the reader through the vendored libav n8.1.1;
- the cross-check through AVFoundation, in `ChapterReaderTests`: `testProbe`, with `MANIFOLD_CHAPTER_PROBE_LIST`, prints
  counts, time bases, times and title flags, never a title.

Commands and raw output are in `~/Code/Manifold/fixtures/chapters/README.txt`. Titles below are fixture titles only. For
the W1 files, no title, marker name or comment is quoted.

### 11.1 The fixtures: libav against AVFoundation

"AVF" is Manifold's current Inspector rule: the first available locale, else `Locale.current`.

| # | File | Boxes (`-v trace`) | libav | AVF | Agree? |
|---|---|---|---|---|---|
| F1 | `ch-2398-tc-track.mov` | `tref`→`tmcd` only. **No `chap`**, no `chpl`; the chapter text track is a `mov_text` stream | 0 | 0 | yes (both none) |
| F1b | `ch-2398-track.mov` | `tref`→`chap`, no `chpl` | 4, tb **1/1000**, 0 / 10.010 / 30.072 / 50.050 s | 4, timescale 1000, same times, same titles; locale `en` | yes |
| F2 | `ch-25-chpl.mp4` | `chpl` only (tref patched to `free`) | 3, tb **1/10 000 000**, 0 / 10 / 30.04 s | **0** | **no**: AVF does not read `chpl` |
| F3 | `ch-25-both.mp4` | `tref`→`chap` and `chpl` | 3 (**once each**), tb 1/1000 (the chapter track's) | 3, same | yes |
| F4 | `ch-2398-offgrid.mp4` | both forms; video `elst` media time 2002 | 7, tb 1/1000; video `start_time` 0 | 7, same starts; durations from the track samples | yes |
| F5 | `ch-2997df-tc.mov` | `tref`→`tmcd` only, plus `chpl` | 3, tb 1/10 000 000, 0 / 60.027 / 60.060 s | **0** | **no** (as F2) |
| F6 | `ch-25-unicode.mp4` | both forms | 2; the 178-character non-ASCII title intact; `Reserved = ; # \ characters` unescaped | 2, titles equal to libav's; locale `und` | yes |
| F7 | `mk-25-notc.mp4` | none | 0 | 0 | yes |
| F8 | `mk-2997df-tc.mxf` | MXF | 0 | (cannot open MXF) | n/a |

The small test fixtures (`Tests/ChapterReaderTests/Fixtures`, 160×90) give the same answers. One more, `r-offset.mp4`
(video delayed 1 s by an empty edit), gives a video `start_time` of 1 s in libav, with the chapters left on the movie
timeline (0 / 1 / 2.04 s) in **both** libav and AVF (§11.4).

### 11.2 The §2.2–§2.3 UNKNOWNs

| Question (§) | Answer | Evidence |
|---|---|---|
| ffmpeg writes both forms by default (§1.2) | **CONFIRMED** for mp4. **For a `.mov` with a timecode track, the chapter track is written but not linked**: the video `tref` holds only `tmcd` | F3 boxes; F1, F5 boxes and streams (`mov_text` stream, no `chap`) |
| ffmpeg can't write `chpl`-only (§1.2) | **CONFIRMED.** Made by the 4-byte patch | F2 |
| ffmpeg's chapter-track time base (§1.2) | **CONFIRMED: 1/1000.** Frame 721 at 23.976 is written as 30.072 s | F1b, F4 |
| AVF needs the `tref chap` (§2.2) | **CONFIRMED.** An unlinked chapter track gives 0 | F1, F2, F5 |
| AVF reads `chpl` (§2.2) | **CONFIRMED: no** | F2, F5 |
| AVF with an `und` chapter track (§2.2) | **CONFIRMED.** The current rule (first locale) finds them. `loadChapterMetadataGroups(bestMatchingPreferredLanguages:)` with `["en"] + preferred` returns **0** on every `und` file | F3, F4, F6, Resolve MP4s: `preferred-n=0` |
| libav reads `chpl` (§2.3) | **CONFIRMED**, tb 1/10 000 000 | F2, F5 |
| libav with both forms (§2.3) | **CONFIRMED: each chapter once, from the chapter track** (tb 1/1000 or 1/24000, not 1/10 000 000) | F3, F4, F6, Resolve files |
| Chapters filled at open (§2.3) | **CONFIRMED** with `avformat_open_input` + `avformat_find_stream_info` (the reader's sequence). Whether `find_stream_info` is needed for the chapters alone was not separately tested; it is needed for `start_time` | `ChapterReaderTests` |
| libav vs AVF on an edit-listed file (§2.3) | **CONFIRMED: identical starts** (F4, `elst` media time 2002, `start_time` 0) | F4, `r-offgrid.mp4` |
| libav titles are UTF-8 (§2.3) | **CONFIRMED** for ffmpeg's, Resolve's and Premiere's writers: no U+FFFD, no `Ã`/`Â` mojibake, equal to AVF's | F6, W1 |
| libav language / chapter images | **UNKNOWN.** No fixture has either, and no W1 file has chapter images (`-v trace` lists no second `chap` target) | — |
| MXF chapters via libav | **CONFIRMED: none** on `mk-2997df-tc.mxf`. Whether any MXF writer produces something libav maps to chapters is still **UNKNOWN** | F8 |
| Reader cost | 0–2 ms per file on these, including the 3.7 GB ProRes 4444 (the moov is read, no frames decoded) | probe `read=` |

### 11.3 The real-app files (W1)

`~/Code/Manifold/fixtures/chapters/w1/`, read-only: nothing modified, re-muxed or copied.

- All six are 3840×2160 at 23.976 and 30.03 s long.
- Resolve: tmcd 01:00:00:00. Premiere: 00:00:00:00 (the `.mov`'s tmcd; the MP4s' XMP `StartTimecode`).
- XMP was read with `exiftool -ee -G1 -a -s -XMP-xmpDM:<time and type tags>`, names counted, never printed.

| File | Chapter forms (`-v trace`) | XMP | xmpDM:markers | libav | AVF | Accented title intact | Chapter-track timescale |
|---|---|---|---|---|---|---|---|
| `resolve_chapters - prores.mov` (ProRes 4444) | `tref` with **both `tmcd` and `chap`**, plus `chpl` | none | — | 4, tb 1/24000; frames **0, 57, 254, 545** (§11.3.1) | 4, same times, titles equal; locale `en` | **yes** | 24000 |
| `resolve_chapters - h264.mp4` | the same | none (`udta/meta/ilst` only) | — | the same 4 | the same 4; locale `und` | **yes** | 24000 |
| `resolve_chapters - h265.mp4` | the same | none | — | the same 4 | the same 4; locale `und` | **yes** | 24000 |
| `premiere_chapters - prores.mov` (ProRes HQ) | `tref` → `chap` from **two** tracks (video and audio), `tmcd` ×3, **no `chpl`**. The text track starts 4.2125 s | **`udta/XMP_`** | **3**, type `Chapter` ×3, startTime **101, 280, 532** at `f24000s1001` | 3, tb 1/24000; frames **101, 280, 532** (ticks 101101, 280280, 532532: frame-exact) | 3, same, titles equal; locale `en` | **yes** | 24000 |
| `premiere_chapters - h264.mp4` | **none**: no chapter track, no `chpl` | **root `uuid`** box | **3**, `Chapter` ×3, 101, 280, 532 at `f24000s1001` | **0** | **0** | n/a | — |
| `premiere_chapters - h265.mp4` | **none** | root `uuid` | **3**, the same | **0** | **0** | n/a | — |

"Accented title intact" means:

- the one title per file with non-ASCII characters has no U+FFFD;
- it has no `Ã`/`Â`;
- it is equal in libav and AVF.

Whether it matches what was typed is for Robbie to see on screen in Stage 2.

Premiere's XMP also carries `cuePointParams` (`marker_guid` and `keywordExtDVAv1_…` keys). Its markers have no
`duration` field here, so they are point markers.

#### 11.3.1 Resolve's times are rounded to milliseconds

- Resolve's own `chpl` (100 ns) states 0 / 2.419 / 10.594 / 22.731 s. Its chapter track states 0 / 58056 / 254256 /
  545544 in 1/24000, which is exactly those milliseconds × 24.
- The frames those times were presumably made on (58, 254, 545) start at 58058, 254254 and 545545.
- So the track values sit −2, +2 and −1 ticks from the boundaries.
- Under D-C7, a tolerance of one tick of the container's own base, 545544 → 545 and 254256 → 254, but **58056 → 57**.
- The same chapter read from Resolve's `chpl` (24 190 000 × 100 ns) also gives 57.
- With the D-C7a tolerance, max(tick, 1 ms) = 24 ticks here, all three land on 58, 254 and 545.
- That 58 was the intended frame is an inference from the millisecond pattern, **UNKNOWN until Robbie checks Resolve's
  marker** (one look at the marker's timecode in the Resolve project: 01:00:02:10 is frame 58).

Resolve's file has a fourth chapter at 0 that Premiere's lacks. Whether Resolve adds a start chapter itself, or one was
placed there, is **UNKNOWN** (Robbie).

### 11.4 The origin depends on the playback path

On `r-offset.mp4` the chapters stay on the movie timeline in both readers. libav's video `start_time` is 1 s.

- On the **libav path** the engine makes the first video frame frame 0 by subtracting `start_time`
  (`LibavFrameSource.swift:359-360`). So the chapter at 1 s is frame 0, and the reader's origin is right.
- On the **AVFoundation path** the engine's time is the asset's (`currentFrame` = `round(currentTime × fps)`,
  `FrameEngine.swift:2548-2551`). The asset time includes the empty edit, so the origin there is 0.
  - Which frame number Manifold gives the first picture of such a file is **UNKNOWN**: an engine question that predates
    chapters.
  - Every W1 file and every fixture except `r-offset.mp4` has `start_time` 0, so the two origins agree on them.

Hence **D-C10**: Stage 2 passes the origin from the engine (`useLibav` → the reader's `videoStart`, else 0) rather than
always subtracting.

### 11.5 What this changes in the plan

1. **The chapter track is the form to prioritize.**
   - Resolve (all three containers) and Premiere's ProRes `.mov` carry it, and libav and AVFoundation agree on it
     exactly.
   - `chpl` matters only as a fallback (ffmpeg `.mov` with tmcd, MP4Box-era files). libav covers that and AVFoundation
     does not, which confirms D-C2.
2. **Premiere MP4s carry their markers only as XMP** (`xmpDM:markers`, type Chapter, in the root `uuid` box), with no
   chapter track and no `chpl`.
   - Neither libav nor AVFoundation sees them, and Flip doesn't either.
   - That raises D-C9's importance: a Premiere user exporting H.264/H.265 with "Include Markers" sees no chapters in
     either app. See **D-C11**.
   - The XMP is simple: start in frames at a stated rate (`f24000s1001`), a type, and no duration here. It agrees with
     the chapter track where both exist (Premiere `.mov`: 101 / 280 / 532 both ways).
3. **The rounding rule needs D-C7a.** Resolve's millisecond rounding defeats a one-tick tolerance.
4. **The origin needs D-C10.**
5. **Fixture F1 changed:** ffmpeg cannot link a chapter track beside a timecode track in a `.mov`, so F1 (as specified)
   is an "unlinked chapter track" fixture. F1b covers a linked track. Resolve's files cover a linked track beside a
   tmcd.
6. **The Inspector's chapter count** (stage 2) must not switch to `bestMatchingPreferredLanguages`, which drops `und`
   tracks. It goes to the libav reader anyway (D-C2).
7. **Flip consistency:** Flip reads the same libav list, so on every W1 file and fixture it would show the same chapters.
   This is inferred from §9.1; Flip itself was not run. The exception is Premiere MP4s, where both show none.

### 11.6 Stage 1 as built

| File | Change |
|---|---|
| `Packages/ManifoldCore/Sources/Markers/ChapterMapping.swift` | **New.** `ChapterTime`, `FileChapter`, `MappedChapter`; `exactRate`; `frame(of:origin:rate:)` (D-C7, exact `Int128`); `map` (§3.1–§3.2); `unconverted`; `convert` (D-C4, D-C8, through `ResolveEDL.merge`); `navigationFrames`/`neighbour` (D-C6); `thumbnailFrames` |
| `Packages/ManifoldCore/Sources/Markers/MarkerLog.swift` | `chapters(_:readMs:)` and `chaptersUnreadable()`, counts only |
| `Packages/ManifoldCore/Sources/ChapterRead/ChapterReader.swift` | **New leaf target** `ChapterRead` (CFFmpeg + Markers): the libav reader (§6.3 note) |
| `Packages/ManifoldCore/Package.swift` | `ChapterRead` product and target; `ChapterReaderTests` test target (linked like `LibavFrameRequestTests`) |
| `Packages/ManifoldCore/Tests/MarkersTests/ChapterMappingTests.swift` | **New**, 19 tests |
| `Packages/ManifoldCore/Tests/ChapterReaderTests/ChapterReaderTests.swift` + `Fixtures/` (7 files, 356 KB) | **New**, 9 tests (8 run, plus the opt-in probe, skipped by default) |
| `~/Code/Manifold/fixtures/chapters/` | F1, F1b, F2–F6 (.mov/.mp4) and their `.ffmeta` lists, `README.txt` (outside the repo) |

No app file changed, and nothing links `ChapterRead` yet.

**Results (2026-11-16):**

- **`swift test`:** 1154 tests in 38 bundles, 0 failures, 1 skipped (the opt-in probe). Before this stage: 1126 tests in
  37 bundles, 0 failures. +28 = 19 + 9.
- **Package warnings:** none from the new or changed files (their first compile, and a forced recompile of
  `ChapterReader.swift`). The before run was incremental and printed none.
- **App:** Profile build into `.build-cc`, **BUILD SUCCEEDED**. 19 unique source warnings, all in App files this stage
  did not touch, **identical** to the 2026-11-15 build (`~/Code/_scratch/manifold-fixcheck-build.log`). Not launched.
