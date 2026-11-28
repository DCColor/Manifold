# Marker export: Premiere Pro in 0.9.5; Final Cut Pro and Avid in the next build: plan

Read-only audit, 2026-11-17. No code was changed, nothing was built or launched.

**Updated 2026-11-17 (same day):**

- Robbie's decisions are recorded in §8. **0.9.5 ships the Premiere export only.**
- Robbie's P0 capture settles most Premiere UNKNOWNs (§1.3, §6.3).
- The Final Cut (§2) and Avid (§3) sections stay as research for the next build. Robbie will first supply sample files
  with embedded markers from both apps.

**Updated 2026-11-25:** Joey's Media Composer samples and Abba's Final Cut document are read in §10–§15 (read-only; nothing
built or launched). Where §10–§15 disagree with §2–§3, §10–§15 are newer. New label **S:** seen in those samples.

**Sources.**

- **This repo:** the files cited inline.
- **Reference files:** Frame.io's Premiere xmeml and Avid XML in `docs/markers/frameio-reference/` (read for structure only).
- **Vendor documentation**, cited by URL. helpx.adobe.com and Avid's sites refused direct fetches, so those facts come
  from search excerpts of the cited pages.

**Labels.**

- **DOC:** confirmed by vendor documentation.
- **REF:** seen in a reference file in this repo.
- **P0:** measured in Robbie's Premiere exports, `~/Code/Manifold/fixtures/markers/premiere-p0.xml` (23.976) and
  `premiere-p0-df.xml` (29.97 DF). They were read for structure only. No marker name or comment is quoted in this
  plan. Which Premiere version wrote them is not recorded in the files.
- **UNKNOWN:** not confirmed; each one names the attended step that settles it.

**On this Mac (2026-11-17).**

- Premiere Pro 25.6.6, 26.5.3 and 27.0.0 are installed.
- **Final Cut Pro and Media Composer are not installed** (Spotlight finds no bundle). The FCP and Avid attended steps
  need a Mac that has them.
- Nothing may be installed here (CLAUDE.md).

## 0. The promise

`docs/release-notes/0.9.4.md:57`, under the markers limits:

> - **Exports to Premiere, Avid and Final Cut** aren't available yet. They're planned.

What the wording commits to:

- **It names three apps, Avid included.** It names no version and no date.
- **Decided (Robbie, 2026-11-17, §8): 0.9.5 ships Premiere only.**
  - **0.9.5's release notes must say the Final Cut and Avid exports are still planned.**
  - Otherwise the 0.9.4 line has quietly lost two apps.
- **It says "exports to" the apps.** Delivering it means each app opens Manifold's file and shows the markers at the
  right frames. A file in the app's format is not enough on its own. The attended round trip (§6.3) is therefore the
  acceptance test, not the golden files.
- **`docs/release-notes/next.md`** has no marker entry yet.

## 1. Premiere Pro: import paths

| Path | Exists? | Fields that survive | Timecode | Needs media? |
|---|---|---|---|---|
| **FCP 7 XML (xmeml)**, File ▸ Import | **Yes, DOC.** Adobe: "Premiere Pro retains the sequence markers, sequence settings, track layout, locked tracks, and sequence timecode start points" ([importing XML](https://helpx.adobe.com/premiere-pro/using/importing-xml-project-files-final.html)) | Sequence markers: name, comment, in/out (DOC by the xmeml spec). Colour as `<pproColor>` (P0). Type: **not written** (P0) | Sequence `<timecode>` start is retained (DOC) | **Not required by DOC**: Frame.io's file has no `<file>` at all, only a colour-matte generator (REF, `…_Premiere.xml:52`). Whether a sequence with no media imports with markers: **UNKNOWN** (P2) |
| Clip markers in xmeml (`<marker>` inside a `<clipitem>`) | **UNKNOWN.** Adobe documents sequence markers only; forum reports conflict. P0 had no clip marker, so it doesn't settle this. It's not needed: Manifold writes sequence markers only | — | — | — |
| **OpenTimelineIO**, File ▸ Import | **Yes**, in current Premiere. The helpx release notes say Premiere "now supports importing and exporting OpenTimelineIO (OTIO) projects" ([release notes](https://helpx.adobe.com/premiere/desktop/whats-new/release-notes.html)). Adobe staff list **sequence markers: start, duration, name, colour** ([announcement](https://community.adobe.com/announcements-732/now-released-otio-import-and-export-311699)) | Name, duration, colour; comment **UNKNOWN** | **UNKNOWN** | **UNKNOWN** |
| CSV | **No import documented.** Only a 2023 feature request exists ([idea](https://community.adobe.com/t5/premiere-pro-ideas/csv-markers-file-import-to-sequence-or-clip/idi-p/13515885)). Export to CSV exists (forum; Adobe documents it for Prelude) | — | — | — |
| EDL | **No.** No Adobe documentation says EDL comments become markers; forum reports say they do not | — | — | — |
| XMP in the media file | **Yes**, Premiere reads clip markers from a file's XMP ([media preferences](https://helpx.adobe.com/premiere/desktop/get-started/preferences-and-settings/media-preferences.html); Manifold reads them too, CHAPTER_MARKERS_PLAN §12) | All, typed, coloured | Frames from the first frame (§12.6) | It *is* the media |
| Frame.io comments | Yes (DOC), but a service path, not a file | — | — | — |

**Rejected.**

- **XMP:** writing XMP would mean rewriting the user's media file, or writing a sidecar that only some formats honour.
  Manifold never modifies media.
- **CSV and EDL:** Premiere does not import them as markers.

**Recommendation: xmeml with sequence markers.**

- It is the one path Adobe documents for markers.
- It works in every installed Premiere (25.6 to 27.0) and in older ones.
- Frame.io's export shows the shape (MARKERS_PLAN §0.2).

**OTIO is the alternative, kept for later.**

- Its colour and comment encoding for Premiere are UNKNOWN.
- Its first stable Premiere version is UNKNOWN: a search excerpt says 26.2.2, a third-party source says 25.6.
- One P0 export from 26.5 settles both, and OTIO would also open in Resolve. It is not needed for 0.9.5.

### 1.1 What the xmeml must hold

From Apple's FCP 7 XML reference
([elements](https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/FinalCutPro_XML/Elements/Elements.html),
[basics](https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/FinalCutPro_XML/Basics/Basics.html)),
and Frame.io's file:

- **`<marker>`** may sit in `clip`, `clipitem` or `sequence`. Its children are `name`, `comment`, `in`, `out` and
  `color` (`red`/`green`/`blue`/`alpha`) (DOC).
  - Premiere writes colour instead as **`<pproColor>`**, one integer in A,B,G,R byte order (P0; all eight in §4.1).
    - **Green writes no `<pproColor>` at all** (P0).
    - Premiere writes no `<color>` element (P0).
    - Whether Premiere *reads* `<pproColor>` back from xmeml is **UNKNOWN** (P2).
- **`in` / `out`** are frame counts at the sequence rate, counted from the sequence start, 0-based (DOC, P0).
  - **A one-frame marker writes `out = -1`** (P0, every point marker in both files).
  - A ranged marker writes its end frame. P0 is consistent with `out = in + duration` (exclusive), but the drawn length
    isn't recorded, so the exact form is confirmed only by P2.
- **`<rate>`:** `<timebase>` is the integer rate and `<ntsc>TRUE</ntsc>` marks a 1000/1001 rate (DOC).
  - Frame.io wrote `ntsc FALSE` for 23.976, which is wrong (REF, MARKERS_PLAN §0.2). Manifold writes TRUE.
- **`<timecode>`** carries `rate`, `string`, `frame` and `displayformat` (`DF` / `NDF`) (DOC).
  - DOC: DF is valid only at timebase 30.
  - 29.97 DF is settled (P0, §1.3). 59.94 DF in xmeml is **UNKNOWN** (P3).
- **`<file><pathurl>`** must start with `file://localhost/` or `file:///` and be RFC 2396-escaped (DOC).
  - Premiere writes `file://localhost/` with `%20` for spaces (P0).
- **`version`:** Premiere writes `<xmeml version="4">` after `<!DOCTYPE xmeml>` (P0), as Frame.io does (REF).

### 1.3 What P0 showed

There are two files, both written by Robbie's Premiere. Each holds one sequence with one clip and 11 sequence markers.
The markers are:

- eight one-frame markers, one per Premiere colour;
- one ranged marker;
- one marker named as the chapter;
- one more one-frame marker that the brief didn't describe. It is Green and has a longer comment.

**Structure.**

- **File:** UTF-8 **with a BOM**, LF line endings, `<!DOCTYPE xmeml>` with no DTD, `<xmeml version="4">`.
- **Where markers go:** directly under `<sequence>`, after the sequence `<timecode>` and before `<labels>`. They are
  not inside any clipitem.
- **Order:** not by time. The importer can't depend on order and the exporter needn't sort, but Manifold sorts anyway
  so the golden files are stable.
- **Children:** `<comment>`, `<name>`, `<in>`, `<out>`, then `<pproColor>` when the colour isn't Green.
  - Every marker has a `<comment>`, written empty when there is none.
  - **No type element.** Nothing marks the chapter marker as a Chapter except its name. **xmeml does not carry marker
    type.**
- **One-frame:** `out = -1`.
- **Ranged:** `out` = the end frame. In the 23.976 file the range is 72 frames.

**Comment line breaks.**

- The comment Robbie entered on two lines comes out with **no CR or LF**. Its characters are letters, digits, spaces
  and `.,` only.
- So Premiere either flattened the break when it exported, or never stored it. Which one is **UNKNOWN**.
- Either way, nothing shows Premiere *importing* a line break. Until P4 shows that it does, the exporter **replaces each
  run of line breaks in notes with a single space**. That costs nothing Premiere would have shown.

**Sequence timecode.**

- 23.976: `<rate><timebase>24</timebase><ntsc>TRUE</ntsc>`, `<string>01:00:00:00</string>`, `<frame>86400</frame>`,
  `<displayformat>NDF</displayformat>`.
- 29.97 DF: `<timebase>30</timebase><ntsc>TRUE</ntsc>`, `<displayformat>DF</displayformat>`, `;` separators in
  `<string>`.
- **`<frame>` is a plain frame count at the timebase, and `<string>` is that count labelled in the display format.**
  - The DF file's start is the same instant as the 23.976 file's. Premiere's `MZ.ZeroPoint` is 915372057600000 ticks
    = 3603.6 s in both.
  - At 30 frames per second that is `<frame>108000</frame>`, which Premiere labels `01;00;03;18` in DF.
  - So for 01:00:00;00 DF, Manifold writes `frame` = 107892, the DF count, which is `basis.startFrame`, and
    `string` = `01;00;00;00`.
  - That is what §4.2 already proposed.
  - Whether Premiere's import trusts `frame` or `string` when they disagree is **UNKNOWN**. Manifold never makes them
    disagree.
- **Caveat:** the DF sequence holds the **23.976 clip** (same file, same `<file>` timecode, 24 NDF), so a DF clip in a
  DF sequence is still untested. Its markers are the 23.976 positions re-timed to 30 fps.

**Media and audio.**

- **`<file>`:** written in full on its first use, then referenced as `<file id="file-1"/>` on the linked clips.
- **Audio:** the stereo clip comes out as **two mono-exploded audio clipitems**. They sit on A1 and A2 with
  `premiereChannelType="stereo"`, one `<sourcetrack><trackindex>` each, and `<link>` blocks that tie video and both
  audio items together.
- **Ticks:** `<pproTicksIn>`/`<pproTicksOut>` sit on each clipitem, at 254016000000 ticks per second. Manifold can omit
  them. Frame.io does (REF). Whether import needs them is settled by P2.
- **Premiere-only attributes:** `MZ.*` and `TL.*` attributes, `<labels>`, `<logginginfo>` and `<colorinfo>` are UI
  state. Manifold omits them.

### 1.2 Proposed layout (corrected against P0, §1.3)

One sequence named after the clip. E3 is decided: the sequence holds the media clip.

- **Sequence:** rate and duration from the file; `<timecode>` = the file's start (§4.2).
- **One video clipitem:** the media file itself, with `<file>` / `<pathurl>`, `start` 0, `end` = frames, `in` 0,
  `out` = frames.
  - The editor then gets the picture under the markers.
- **Audio, when the file has audio:** Premiere's own layout (P0). For stereo, that is two clipitems on A1 and A2 with
  `premiereChannelType="stereo"`, `<sourcetrack>` 1 and 2, and `<link>`s to the video item.
  - Other channel counts are **UNKNOWN**: P0 had stereo only. P2 checks a mono file and a multichannel file.
- **Markers on the sequence only,** after the sequence `<timecode>`, as Premiere writes them:
  - Frame.io duplicates them onto the generator item (REF); MARKERS_PLAN §7 already decided against that.
  - Each marker writes, in Premiere's order:
    - `<comment>`: the notes with line breaks flattened (§1.3), plus `[a, b]` keywords when E2's checkbox is on; empty
      when there are none;
    - `<name>`;
    - `<in>` = frame;
    - `<out>` = `-1` for 1 frame, or frame + duration for more;
    - `<pproColor>` (§4.1), omitted for Green.
- **File:** UTF-8, LF, with the BOM as Premiere writes it. `version="4"`.

## 2. Final Cut Pro: FCPXML (next build, not 0.9.5)

**Deferred (Robbie, 2026-11-17, §8).**

- The Final Cut export moves to the build after 0.9.5.
- Before any code, Robbie supplies a **sample FCPXML with embedded markers exported from Final Cut itself**. It takes
  the place that P0 took for Premiere.
- That sample settles F1's version and format-name questions and F3's duration and note encoding, before anything is
  written. Save it as `~/Code/Manifold/fixtures/markers/fcp-sample.fcpxml` (or `.fcpxmld`), read-only, and never quote
  its marker text.
- **E1 is decided for when it's built:** no colour becomes a to-do.
- **E4** (the start override) is deferred with it.
- Everything below is the research, kept as is so that build starts from it.

**Versions (DOC).**

- Current FCP is **12.4** (2026-09-29) ([support](https://support.apple.com/en-us/102825)).
- FCP 12.0 writes FCPXML **1.14**, 11.0 writes 1.13, 10.8 writes 1.12, and 10.6 writes 1.10, the version that
  introduced the `.fcpxmld` bundle.
- **The only DTD Apple publishes online is 1.10**
  ([DTD](https://developer.apple.com/documentation/professional-video-applications/document-type-definition)).
- "If the document does not match the DTD, Final Cut Pro rejects the import operation completely" (same page).
- Which older versions 12.4 imports is not documented: **UNKNOWN** (F1).

**Target: FCPXML 1.10, as a single `.fcpxml` file** (not a bundle).

- Manifold can validate against a DTD it has actually read.
- It covers FCP 10.6 and later.
- If F1 shows 12.4 refuses it, use the 1.14 DTD from [Apple's FCP support page](https://support.apple.com/final-cut-pro)
  and re-validate.
- Whether a plain `.fcpxml` still imports in 12.4: **UNKNOWN** (F1).

**Markers (DTD 1.10, DOC).**

- `marker`:
  - `start` (required), `duration`, `value` (required: the name), `note`;
  - `completed`: `0` makes a to-do and `1` a completed to-do; without the attribute it is a standard marker.
- `chapter-marker`: `start`, `duration`, `value`, `note`, `posterOffset`.
- Markers attach to `asset-clip`, `clip`, `gap`, `ref-clip`, `sync-clip`, `mc-clip`, `title`, `video` and `audio`.
  They cannot attach to `spine` or `sequence`.
- **An `asset-clip` placed directly in an `<event>`** (no project) may carry markers. The DTD allows it, and Apple's
  sample 2 puts asset-clips straight into an event
  ([items](https://developer.apple.com/documentation/professional-video-applications/describing-final-cut-pro-items-in-fcpxml)).
- **`keyword`** (`start`, `duration`, `value` = comma-separated keywords, `note`) is a range on the same clip.
  - So Manifold's keywords survive here, as keyword ranges over each marker's span, and nowhere else (MARKERS_PLAN §7).
- **Colours:** none. FCP has types only: standard blue, chapter orange, to-do red, completed green
  ([markers](https://support.apple.com/guide/final-cut-pro/intro-to-markers-ver397279dd/mac)). The DTD has no colour
  attribute (DOC).
- **Duration:** Apple says markers in FCPXML have "a duration equal to a single video frame"
  ([metadata](https://developer.apple.com/documentation/professional-video-applications/associating-ratings-keywords-markers-and-metadata-with-media)).
  - Whether FCP keeps a longer `duration` on import: **UNKNOWN** (F3).
  - If it does not, a ranged marker's length survives only in the keyword range.

**Time (DOC).**

- Times are rational seconds: `1001/24000s`, `5s`.
- **A clip's `start` is its local (source) time, and a marker's `start` is in that same local time.**
  - In Apple's sample, an asset starting at 10 s with a marker at 18 s puts the marker 8 s into the media.
  - So: asset `start` = the media's start timecode in seconds, and marker `start` = asset `start` + frame ×
    frameDuration.
  - Always exact multiples of frameDuration, so no rounding arises. Whether FCP requires frame-aligned times: **UNKNOWN**,
    and moot, since they always are.
- `tcFormat="DF"` or `"NDF"` goes on the `asset-clip`.
- **frameDuration:** 1001/24000s (23.976), 1/24s, 1/25s, 1001/30000s, 1/30s, 1/50s, 1001/60000s, 1/60s.
  - Non-standard or variable rates: **UNKNOWN** (F5).

**Minimal file.** Apple names the required parts; this exact file is not yet imported anywhere:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.10">
  <resources>
    <format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
    <asset id="r2" name="<clip>" start="<startTC s>" duration="<frames×1001/30000s>" hasVideo="1" hasAudio="1"
           format="r1" audioSources="1" audioChannels="2" audioRate="48000">
      <media-rep kind="original-media" src="file:///…/clip.mov"/>
    </asset>
  </resources>
  <event name="<clip> markers">
    <asset-clip name="<clip>" ref="r2" format="r1" start="<startTC s>" duration="…" tcFormat="DF">
      <marker start="…" duration="1001/30000s" value="<name>" note="<notes>"/>
      <chapter-marker start="…" duration="1001/30000s" value="<name>"/>
      <keyword start="…" duration="…" value="titles,graphics"/>
    </asset-clip>
  </event>
</fcpxml>
```

- **Import result (DOC):** importing creates the event and copies or links the media per the user's preference.
- **Empty events are refused (DOC):** "Events must contain at least one clip or project."
- **`<format>`:** Apple's `name` strings (`FFVideoFormat1080p2997`) are optional in the DTD. Whether FCP accepts a
  nameless format with explicit width, height and frameDuration: **UNKNOWN** (F1).
- **Wrong audio attributes:** whether FCP reconforms or rejects the asset is **UNKNOWN** (F4). Manifold writes what the
  demuxer reports.
- **Missing or offline media:** undocumented. A forum shows FCP can make an offline clip given "sufficient data".
  Whether its markers survive is **UNKNOWN** (F6).

## 3. Avid Media Composer (next build, not 0.9.5)

**Deferred (Robbie, 2026-11-17, E5).** Robbie will supply a Media Composer marker export (XML, and TXT if possible)
with embedded markers. It stands in for step A1 below: `~/Code/Manifold/fixtures/markers/avid-sample.*`, read-only.

**Two routes.**

- **Tab-delimited text** (Markers window ▸ Import Markers).
  - Avid's own MediaCentral help calls it a "tab-delimited text file (.txt) that you can import into Media Composer"
    ([IPC help](https://resources.avid.com/supportfiles/attach/interplay_central/ipc_help/InterplayCentral_Help/UG_Logging.20.14.html)).
  - The field layout is not documented anywhere fetched: **UNKNOWN**.
  - Third-party tools (InqScribe, editools) describe the legacy line as
    `User⇥HH:MM:SS:FF⇥Track⇥Colour⇥Comment`, for example `Manifold⇥01:00:10:00⇥V1⇥red⇥Check grade`.
  - Legacy colours: white, red, yellow, green, cyan, blue, magenta, black.
  - A duration column, `A1`/`TC` tracks, line endings and encoding (Mac Roman vs Latin-1 for accents) are all UNKNOWN.
- **Marker XML** (`Avid:StreamItems`, `_ATN_CRM_*` attributes).
  - Frame.io writes it (REF, MARKERS_PLAN §0.3): colour name, user, comment, `_ATN_CRM_TC` as a **frame count**,
    track `V1` and length.

**Media Composer 2024.6 changed both (DOC, search excerpts of
[What's New 2024.6](https://resources.avid.com/SupportFiles/attach/WhatsNew_MediaComposer_v24.6.pdf)).**

- Marker colours went to **16**. The new ones are Purple, Violet, Pink, Denim, Forest, Orange, Gold and Grey.
- The name field split into **Marker Name** and **User**.
- **Avid recommends XML for backward compatibility:** older versions map the new colours to the original eight. In
  **TXT** "all expanded colors will default to a single color and the Marker Name field will be ignored".
- So the TXT layout changed in 2024.6, and its new columns are UNKNOWN.

**Known import failures (forum, UNKNOWN):**

- markers import onto a **sequence**, not a source clip;
- a start-timecode mismatch or a track the sequence lacks makes the import fail ("offset past the end of the
  sequence").

**Recommendation: marker XML, not TXT, and only after a template exists.**

- The template is one marker list exported from a current Media Composer, one marker per colour, saved to
  `docs/markers/avid-reference/` (MARKERS_PLAN step A1).
- Without Media Composer on hand this cannot be verified, so it is not proposed for 0.9.5.
- Avid's 16 colours fit Manifold's 16 better than any other app's (§4.1). The exact names are UNKNOWN until A1.

## 4. Mapping Manifold markers to each format

Manifold marker (`Packages/ManifoldCore/Sources/Markers/Marker.swift:13-31`):

- `frame`, `duration` (≥ 1);
- `name` (one line), `notes` (multi-line), `keywords`;
- `color`, one of Resolve's 16 (`MarkerColor.swift:16-18`);
- the file's `TimecodeBasis`: start frame, nfr, rate, DF, and whether the file has timecode, with the per-file start
  override (`Marker.swift:76-104`).

The FCPXML and Avid columns are for the next build (§2, §3).

| Field | Premiere xmeml (0.9.5) | FCPXML (next) | Avid (next) |
|---|---|---|---|
| Frame | `<in>` frames from the sequence start (exact; P0) | `start` = asset start + frame × frameDuration (exact) | TC or frame count (XML: frame count) |
| Duration | `<out>` = `-1` for 1 frame (P0), else frame + duration (P2 confirms) | `duration`; kept by FCP: **UNKNOWN** (F3) | length (XML) |
| Name | `<name>` | `value` | Marker Name (2024.6+) |
| Notes | `<comment>`, line breaks flattened to a space (P0, §1.3); P4 may allow keeping them | `note`, line breaks as `&#10;`: kept **UNKNOWN** (F3) | comment; line breaks **UNKNOWN** |
| Keywords | No field. **E2: appended as `[a, b]` to the comment when the keywords checkbox is on** (off by default, as the EDL's D13) | **Kept** as `<keyword>` ranges over each marker's span | Lost |
| Colour | 16 → 8 (§4.1) as `<pproColor>`, Green omitted (P0); read back **UNKNOWN** (P2) | **Lost**: types only (§4.3) | 16 → Avid's 16 (A1) |
| Type | **Not carried by xmeml** (P0): everything imports as Premiere's default type | `chapter-marker` for markers with the keyword "chapter" (§4.3) | — |
| Start TC | Sequence `<timecode>` (§4.2) | asset `start` (§4.2) | Must match the sequence's |
| Media path | `<pathurl>` | `media-rep src` (required) | None |

### 4.1 Colours: 16 → Premiere's 8

**Premiere's palette.**

- 8 colours, in its dialog order: **Green, Red, Purple, Orange, Yellow, White, Blue, Cyan**.
  - CHAPTER_MARKERS_PLAN §12.5 (recorded).
  - ExtendScript `setColorByIndex` 0–7 has the same names in the same order
    ([ppro-scripting](https://ppro-scripting.docsforadobe.dev/print_page/), Adobe's guide, community-hosted).
- The import table §12.5 decided (D-C13), as built in `XMPMarkers.swift:39-56`: Green→Green, Red→Red, Purple→Lavender,
  Orange→Sand, Yellow→Yellow, White→Cream, Blue→Blue, Cyan→Cyan.

**Proposed export table.**

- It is the exact reverse of that table, so those eight round-trip with no change.
- The other eight Resolve colours go through **the hue rule Manifold already uses** to name an unmeasured Premiere value
  (CHAPTER_MARKERS_PLAN §16.1): White when saturation < 0.12; Red < 12° or ≥ 330°, Orange < 40°, Yellow < 75°,
  Green < 160°, Cyan < 200°, Blue < 250°, Purple < 330°.
- That rule is applied to Manifold's own swatches (`MarkerColor.hex`). Hues were computed for this plan.
- Run on the eight reverse rows too, it gives the same answer for each, so export and import agree.

| Manifold (Resolve) | Swatch | Hue | Premiere | How | `<pproColor>` written |
|---|---|---|---|---|---|
| Green | #02B601 | 120° | **Green** | reverse of D-C13 | *(none)* |
| Red | #E42900 | 11° | **Red** | reverse | 4281740498 |
| Lavender | #AB9DCF | 257° | **Purple** | reverse | 4289825711 |
| Sand | #CB9C69 | 31° | **Orange** | reverse | 4280578025 |
| Yellow | #F2A701 | 41° | **Yellow** | reverse | 4281049552 |
| Cream | #F6EEE5 | sat 0.07 | **White** | reverse | 4294967295 |
| Blue | #078AE7 | 205° | **Blue** | reverse | 4294741314 |
| Cyan | #08D4D6 | 181° | **Cyan** | reverse | 4292277273 |
| Pink | #FF4DCF | 316° | Purple | hue rule | 4289825711 |
| Purple | #9B0FFE | 275° | Purple | hue rule | 4289825711 |
| Fuchsia | #C7347A | 331° | Red | hue rule | 4281740498 |
| Rose | #FFABC1 | 344° | Red | hue rule | 4281740498 |
| Sky | #9DE6FD | 194° | Cyan | hue rule | 4292277273 |
| Mint | #7DE002 | 87° | Green | hue rule | *(none)* |
| Lemon | #E0EC65 | 65° | Yellow | hue rule | 4281049552 |
| Cocoa | #795B4C | 20° | Orange | hue rule | 4280578025 |

**Premiere's eight `<pproColor>` values, all measured (P0).**

Robbie placed the markers in Premiere's dialog order and gave them ascending frames. The two files agree value for
value.

| Premiere | `<pproColor>` | Hex (A,B,G,R) | RGB | Agrees with |
|---|---|---|---|---|
| Green | **not written** | — | — | three other uncoloured markers in the same files, which are Premiere's default colour |
| Red | 4281740498 | FF362CD2 | #D22C36 | §12.5 measured |
| Purple | 4289825711 | FFB18BAF | #AF8BB1 | §12.5 measured |
| Orange | 4280578025 | FF246FE9 | #E96F24 | §12.5 measured |
| Yellow | 4281049552 | FF2BA1D0 | #D0A12B | new |
| White | 4294967295 | FFFFFFFF | #FFFFFF | new |
| Blue | 4294741314 | FFFC8D42 | #428DFC | Frame.io (REF) |
| Cyan | 4292277273 | FFD6F419 | #19F4D6 | new |

- **Green is the absence of `<pproColor>`.** The exporter omits the element for Green. An importer treats a missing
  element as Green.
  - Writing an explicit Green integer is not an option, because no measured value exists.
- **The hue rule (§16.1) names all seven measured colours correctly.** Red 356°, Orange 23°, Yellow 43°, Cyan 172°,
  Blue 216°, Purple 297°, White by saturation. So the import side's fallback agrees with Premiere's own palette.
- **Follow-up, outside this plan:** the XMP reader (`XMPMarkers.swift:39-56`) knows only three measured integers.
  Yellow, White, Cyan and Blue can now be added to its table as exact matches. That is a separate change, made under
  CHAPTER_MARKERS_PLAN, and it needs to confirm that XMP uses the same integers as xmeml.

**The export notice** counts what changed, for example "5 markers took the nearest of Premiere's 8 colours". It never
names a marker.

### 4.2 Timecode and the start override

**Premiere.**

- **Sequence `<timecode>`:**
  - `frame` = `basis.startFrame`;
  - `string` = `basis.label(0)` (`;` before the frames for DF);
  - `displayformat` = DF/NDF;
  - `rate` timebase = `basis.nfr`, with `ntsc` TRUE when `rate` is not an integer.
  - P0 confirms this encoding for 23.976 NDF and 29.97 DF: `frame` is the plain count, and `string` is its label
    (§1.3).
- **Marker `<in>`** = `marker.frame`. It is relative, so the start timecode never enters the marker itself.
- **A file without timecode, with an override (D6/D-C17):**
  - The **sequence** takes the override, so the markers read in Premiere's sequence exactly as in Manifold.
  - The **clip** in it reads Premiere's own interpretation of the file (00:00:00:00). That is correct, and the help text
    says so.
- **59.94/50 DF** is UNKNOWN in xmeml (P3).

**FCP.**

- Asset `start` = the file's own start timecode in seconds (`basis.startFrame × frameDuration`, exact, DF included,
  because `startFrame` is a frame count).
- **The start override is not applied for FCP.**
  - FCP reads the media's own start when it links the asset.
  - An asset `start` that disagrees with the media is **UNKNOWN** (F2): it might be rejected, reconformed or trusted.
  - Recommended: write the media's own start (0 for a file without timecode) and say so in the export notice when an
    override is set.
  - Since marker times are relative to the asset start, the markers still land on the right frames.
  - If F2 shows FCP honours a stated asset `start`, the override can be applied later.

**Avid.** The import fails when start timecodes disagree (forum), which is one more reason to wait for A1.

### 4.3 Types: FCP and Premiere

**FCP.**

- A marker with the keyword **"chapter"** becomes a `chapter-marker`.
  - That keyword is exactly what Convert gives a file's chapters (CHAPTER_MARKERS_PLAN §16.1, D-C4).
  - So converted chapters come out as chapters.
- Every other marker becomes a standard `marker`.
- **Decision for Robbie (E1):** should any colour become a **to-do** (`completed="0"`)? FCP's to-do is red.
  - Recommended: **no**. A colour means whatever the colourist chose, and guessing "red means to-do" invents
    meaning.
  - All other markers stay standard. Colour loss is stated in the notice: "Final Cut has no marker colours; 12 colours
    were dropped."

**Premiere.**

- **xmeml carries no marker type (P0).** Premiere exported its own Chapter marker as a plain marker, recognisable only
  by its name.
- So every exported marker imports as Premiere's default type (Comment). Converted chapters arrive as Comment markers
  that keep their name and their "chapter" keyword in the comment, if E2's checkbox is on.
- The export notice doesn't mention type; nothing changed from the user's point of view.

### 4.4 File markers (chapters and XMP)

**D-C5 applies to every new format:** export writes **user markers only**.

- The exporters receive `model.markers`, as `MarkerFileIO.swift:68-69` does today.
- A file's chapters or Premiere XMP markers reach an export only after **Mark ▸ Convert**.
- The export notice adds one line when the file has unconverted file markers: "This file's 6 file markers were not
  exported; convert them first."

## 5. UI, naming, inputs, privacy

**Where it goes: Export Markers… (File menu, the slot gear, the Markers window toolbar).**

- The save panel's format pop-up (`ExportAccessory`, `MarkerFileIO.swift:197-231`) gains, in 0.9.5, one entry:
  **"Adobe Premiere Pro XML (.xml)"**. "Final Cut Pro XML (.fcpxml)" follows in the next build.
- `MarkerFileIO.Format` is an `Int` raw-value enum stored in `manifold.markers.exportFormat`
  (`MarkerFileIO.swift:18-31`). **New cases go at the end**: Premiere is 3, and FCP later takes 4. A saved choice
  keeps its meaning.
- The keywords checkbox:
  - is enabled for the EDL and for Premiere (E2 decided: keywords into comments, opt-in, off by default);
  - will be disabled for FCP, which keeps keywords natively.

**File names** follow the existing rule `"<clip> markers.<ext>"` (`MarkerFileIO.swift:52`): `<clip> markers.xml`, and
later `<clip> markers.fcpxml`.

**New inputs.**

- **The export needs the media file's URL** (both formats, when FCP comes). Today it is `MarkerModel.fileURL`, which
  is private (`MarkerModel.swift:81`).
  The model gains a read-only accessor.
- **They also need from the engine:**
  - frame count (the model already keeps `lastFrame` for chapter mapping);
  - width and height;
  - audio presence, channel count and rate (FCP's asset).
- Export is refused for no file, or for a file whose rate Manifold cannot express (F5), with a notice. It never writes
  a guessed rate.

**Privacy (MARKERS_PLAN §5.1).**

- Names, notes, keywords and the **media path** go only into the exported file.
- **Logging:**
  - `MarkerLog` gains `xmeml` and `fcpxml` formats with counts only: n, colours mapped, keywords dropped or kept,
    chapters written, override ignored.
  - A sentinel test asserts the log line holds no name, note or path, like `XMPMarkersTests.testXMPLogLineHoldsCountsOnly`.
- **Notices** show counts. Panels and alerts may show the user's own words to the user, as today.
- **The exported file holds the media's absolute path.** That is inherent to both formats. The help text says so,
  because a user sending the XML to someone sends their folder structure with it.

## 6. Test plan

### 6.1 Fixtures

Use `~/Code/Manifold/fixtures/markers/` (README there). Each frame burns in its frame number and timecode label, so a
marker's frame can be read off the picture in any app:

| Fixture | What it tests |
|---|---|
| `mk-2398-tc.mov` | 23.976, 01:00:00:00 NDF |
| `mk-2997df-tc.mov` | 29.97 DF from 01:00:00;00, crossing minute 1 |
| `mk-2997df-tc.mxf` | DF, crossing the hour |
| `mk-25-notc.mp4` | 25, no timecode |
| `mk-2398-notc.mp4` | 23.976, no timecode: the override case |

Plus `~/Code/Manifold/fixtures/chapters/w1/premiere_chapters - prores.mov`, for the chapter-keyword → `chapter-marker`
path.

**Missing:** a 59.94 file with timecode, for P3 and F5. Cut one into `fixtures/markers/` the same way, recording the
command in that README.

### 6.2 Unit tests (`swift test`, Packages/ManifoldCore)

New `PremiereXMLTests` beside `ResolveEDLTests` in 0.9.5, and `FCPXMLTests` in the next build. The FCP items below
apply then. The writers are pure functions in the Markers target, like `ResolveEDL.export`.

- **P0 structure test:** the writer's output for P0's case has the same element order and placement as
  `premiere-p0.xml`. It compares structure only, never marker text. That file is outside the repo, so the test skips
  with a message when the file is absent.

- **Golden files**, one per format per case, in `Tests/MarkersTests/Fixtures/`. The cases:
  - 23.976 NDF from 01:00:00:00;
  - 29.97 DF from 01:00:00;00;
  - 25 with no timecode;
  - 23.976 with no timecode and override 01:00:00:00 (Premiere sequence TC shows the override; FCP asset start stays 0);
  - 59.94.
- **Golden files start as the writer's output and become the reference only after P2/F1 import them.** Until then they
  catch regressions only.
- **Exactness:**
  - FCP marker `start` = asset start + frame × frameDuration, as reduced rationals, checked at frame 0, the last frame,
    and across DF minute and hour boundaries;
  - xmeml `<in>` = frame;
  - 1-frame and ranged durations.
- **Escaping:**
  - `& < > " '`, emoji, combining accents, a 1000-character name, notes with CR, LF and blank lines;
  - a path with spaces, `#`, `%`, `?` and non-ASCII characters, as `pathurl` / `src`, RFC 2396 / file URL;
  - every output parses with `XMLParser`.
- **FCPXML DTD validation** with `/usr/bin/xmllint --noout --dtdvalid <fcpxml-1.10.dtd>` on every golden file.
  - Whether Apple's DTD may be committed is **UNKNOWN**. Until that is settled, keep it under
    `~/Code/Manifold/fixtures/fcpxml/`, and have the test skip with a message when the file is absent.
- **Colours:**
  - the 16 → 8 table (§4.1);
  - `export(import(p)) == p` for all eight Premiere colours (the reverse property);
  - the hue rule applied to `MarkerColor.hex` gives the table;
  - the `<pproColor>` integers (P0, §4.1), with Green writing no element.
- **Comments:** CR, LF and CRLF runs flatten to one space (§1.3); an empty comment writes `<comment></comment>`.
- **Rules:**
  - chapters are never exported unconverted (D-C5);
  - the "chapter" keyword → `chapter-marker`;
  - keywords → `<keyword>` ranges (FCP) or dropped and counted (Premiere);
  - no export for an empty marker list (the existing guard).
- **Log sentinel:** counts only, for both formats.

### 6.3 Attended steps (Robbie)

**Premiere** (installed: 25.6.6, 26.5.3, 27.0.0; use 26.5.3 first).

**P0: reference capture. DONE 2026-11-17 (Robbie).**

- Files: `~/Code/Manifold/fixtures/markers/premiere-p0.xml` (23.976, start 01:00:00:00) and `premiere-p0-df.xml`
  (29.97 DF). They hold 11 sequence markers:
  - eight one-frame markers, in Premiere's eight colours, in dialog order;
  - one ranged marker, with the comment entered on two lines;
  - one Chapter marker;
  - one extra Green marker.
- Findings are in §1.3 and §4.1.

| Question | Answer |
|---|---|
| Eight `<pproColor>` values | **Settled.** Green is omitted; the other seven integers are in §4.1 |
| `out` for a one-frame marker | **Settled:** `-1` |
| Ranged marker | `out` = end frame. Exclusive `in + duration` is **likely, confirmed by P2** |
| `version` | **Settled:** `4`, with a BOM |
| Marker type | **Settled: not written.** The Chapter marker exports as a plain marker |
| Comment line break | **None in the export.** Whether import keeps one: **P4** |
| Sequence timecode NDF / 29.97 DF | **Settled:** `frame` = count, `string` = label, `DF`/`NDF` |
| Audio layout | **Settled for stereo:** two exploded clipitems, A1 and A2 |
| Clip marker | **Not captured** (none in the files). Not needed |
| A DF clip in a DF sequence | **Not captured.** The DF file holds the 23.976 clip; P2 covers it |
| OTIO | Not captured. Optional, not needed |

**The writer exists (2026-11-17):** `Packages/ManifoldCore/Sources/Markers/PremiereXML.swift`, tests
`PremiereXMLTests`, golden files `Tests/MarkersTests/Fixtures/premiere-*.xml`. The golden files are the writer's own
output until P2 imports them. Save every export below to `~/Code/Manifold/fixtures/markers/p2/` (create it), never into
the repo. Record answers here by marker **count and colour only**, never a marker's name or comment.

**Common to P2–P4 (Premiere 26.5.3 first).**

- **Import:** File ▸ Import… (⌘I), choose the `.xml`, Import. Premiere adds a bin named after the `.xml` holding the
  sequence and the clip. If a "missing media" or "translation" report appears, record its text word for word.
- **Open the sequence:** double-click it in that bin.
- **Markers:** Window ▸ Markers. Set the panel to show sequence markers (the timeline is active, not the Source monitor).
  The list shows In, Out, Duration, Name and Comment. Double-click a marker in the timeline ruler to open its dialog,
  which shows Name, Duration, Comments, the colour swatches and the marker type.
- **Start timecode:** the timecode at the timeline's left edge with the playhead on the first frame (Home).

**Expected colours (§4.1)**, Manifold → Premiere: Green, Mint → Green; Red, Fuchsia, Rose → Red; Lavender, Pink, Purple →
Purple; Sand, Cocoa → Orange; Yellow, Lemon → Yellow; Cream → White; Blue → Blue; Cyan, Sky → Cyan.

**P2: import.**

1. **Colours and DF.** In Manifold, open `~/Code/Manifold/fixtures/markers/mk-2997df-tc.mov` (29.97 DF from 01:00:00;00,
   no audio). Add 16 one-frame markers, one per colour, on frames 100, 200, … 1600 (Time field: type the frame's
   label from the burn-in). Add one ranged marker of 30 frames at frame 1790 (it crosses 01:01:00;00). Export Markers…,
   Format **Premiere Pro (XML)**, keywords off.
2. Import it in Premiere 26.5.3 and check:
   - **(a)** one sequence named `mk-2997df-tc`, with the clip on V1 and no audio tracks used. The start timecode reads
     **01;00;00;00** and the timeline shows `;` separators (DF). The sequence is 29.97.
   - **(b)** the Markers panel lists **17** markers.
   - **(c)** step to each marker (⇧M / ⇧⌘M, or click it in the panel): the burn-in's "F n" equals the Manifold frame,
     and the Program monitor timecode equals the burn-in's label. The ranged marker's In reads **01;00;59;20** (F1790),
     and its Out **01;01;00;22** (F1820; the fixture README has F1800 = 01:01:00;02).
   - **(d)** each marker's colour in its dialog matches the table above. Any marker that shows Green when it should not
     means Premiere ignores `<pproColor>` on import: record which.
   - **(e)** every marker's type in its dialog is **Comment** (§4.3).
   - **(f)** the ranged marker: Duration reads **00;00;01;00** (30 frames), and its Out is the frame after its last
     covered frame, as Manifold's. If Duration reads 31 frames (or 29), `<out>` is inclusive (or off by one the other way):
     record it. This settles exclusive `out`.
3. **Audio (stereo).** Open `~/Code/Manifold/fixtures/chapters/w1/premiere_chapters - prores.mov` (stereo PCM, 23.976,
   01:00:00:00). Add two markers, export, import. Check:
   - **(g)** the clip's audio is on **A1 and A2**, linked to the video (selecting the video selects both), and plays in
     sync. Then right-click the A1 item ▸ Modify ▸ Audio Channels: record the clip channel format (Stereo, or Mono ×2)
     and which source channel each track uses. P0's own layout is two mono-exploded items: if Premiere shows something
     else, record it.
   - If the import reports an audio error, or the clip comes in with no audio, record the message. **The audio layout
     stays UNKNOWN until this passes.**
4. Repeat steps 1–3 in **25.6.6** and **27.0.0**; record only differences.
5. **Mono and multichannel:** no fixture exists (every marker and chapter fixture is silent or stereo). Cut a mono and a
   6-channel file into `fixtures/markers/` first (record the command in its README), then repeat step 3 with each.
   Until then those layouts are UNKNOWN.
6. The generator variant is dropped: E3 decided the sequence holds the media clip.

**P3: 59.94 DF and the start override.**

1. **59.94 DF.** Needs a 59.94 DF fixture with timecode, which doesn't exist yet (§6.1). Cut it into
   `fixtures/markers/` first. Then export as in P2 step 1 (three markers are enough: frame 0, a ranged marker of 8
   frames crossing minute 1, and the last frame) and import. Check:
   - the import is accepted, the sequence is **59.94** and its start reads **01;00;00;00** with `;` separators;
   - each marker sits on its burn-in frame.
   - If Premiere refuses the file or shows NDF, record its words: Manifold then writes 59.94 NDF, or refuses, in a
     later build.
2. **Start override.** Open `~/Code/Manifold/fixtures/markers/mk-2398-notc.mp4` (no timecode). In the Markers window,
   set the start to **01:00:00:00**. Add a marker at frame 0 and one at frame 240. Export and import. Check:
   - the sequence start reads **01:00:00:00**, and the two markers read 01:00:00:00 and 01:00:10:00 in the Markers panel;
   - open the clip in the Source monitor (double-click it in the bin): it reads **00:00:00:00** at its first frame. That
     is correct (§4.2): the override is the sequence's, not the clip's.

**P4: line breaks in comments.**

1. Copy P2 step 1's `.xml` to `p4-linebreak.xml` in the same folder. In a text editor, in the first `<comment>` that has
   text, replace one space with `&#10;`. Save it as UTF-8 (keep the BOM).
2. Import `p4-linebreak.xml` in Premiere 26.5.3 and open that marker's dialog. Check:
   - does the Comments field show **two lines**? Record yes or no.
   - Also look at the Markers panel's Comment column, and export the sequence back out (File ▸ Export ▸ Final Cut Pro
     XML…, to the same folder): does Premiere's own `<comment>` keep a break? Record yes or no.
3. Yes in the dialog: a later build may keep line breaks. No: flattening stays.

**Final Cut Pro: next build.** It isn't on this Mac. Robbie's FCP sample file (§2) comes first, then F1–F6 on a Mac
with FCP 12.x.

**F1:**

1. In FCP 12.4, File ▸ Import ▸ XML…, and choose Manifold's `mk-2997df-tc markers.fcpxml`.
2. Check:
   - **(a)** the import is accepted. If not, record FCP's message word for word: it rejects a DTD mismatch outright;
   - **(b)** an event "mk-2997df-tc markers" holds one clip;
   - **(c)** the clip's start timecode reads 01:00:00;00.
3. Also try a nameless `<format>`.

**F2:** the same with `mk-2398-notc.mp4` and an override set. Manifold writes asset start 0. Record what the clip's
timecode reads. Then a hand-edited copy with start = 01:00:00:00: is it accepted, and what does the clip read?

**F3:**

- Open the clip and check each marker sits on the frame named by its burn-in (Index ▸ Tags).
- The marker named "chapter" shows as a chapter (orange).
- Check the marker durations, and that the two-line note kept its break.
- The keywords show as keyword ranges in the browser.

**F4:** a file with no audio. Import `mk-25-notc.mp4` (Manifold writes `hasAudio="0"`) and confirm no error.

**F5:** the 59.94 fixture.

**F6:** move the media away, then import. Is there an offline clip, and are its markers present?

**Avid (A1, later):** on a Mac with Media Composer 2024.6 or later:

1. Make a sequence from `mk-2997df-tc.mov`.
2. Add one marker per colour (16).
3. Export Markers as XML and as TXT to `docs/markers/avid-reference/`.

### 6.4 As built (2026-11-17)

- **Writer:** `PremiereXML.export` (pure, Markers target). Structure per §1.2 and P0. The sequence `<uuid>` is a fresh UUID per
  export (fixed in tests).
- **Audio layout, UNKNOWN until P2 step 3:** one clipitem per source channel, each on its own audio track with
  `<sourcetrack>` = that channel, all linked to the video. For exactly 2 channels it adds `premiereChannelType="stereo"`
  and link group 1, which is P0's stereo layout. Channels are summed across the file's audio tracks. P0's `MZ.*`,
  `outputchannelindex`, `<outputs>` and ticks are omitted.
- **Ranged `<out>`:** frame + duration (exclusive), pending P2(f). **59.94 DF:** written as DF at timebase 60, pending P3.
  **Comments:** line-break runs → one space, ends trimmed, pending P4.
- **Rates:** integer rates and NTSC (1000/1001) rates only. Any other rate refuses the export with a notice; nothing is
  written.
- **Path:** `file://localhost` + the path in NFC, bytes outside RFC 2396's unreserved set and `/` escaped. Which Unicode
  form Premiere writes for a non-ASCII path is UNKNOWN (P0's was ASCII).
- **Zero markers:** Export Markers… stays refused with "No markers to export.", as for EDL, CSV and text. The writer itself
  writes a valid sequence with no markers (golden `premiere-25-empty.xml`), so the decision is the app's alone.
- **XMP reader (follow-up from §4.1):** the color table now holds all seven measured integers. An XMP marker with no color
  converts to Green, Premiere's colorless default. A chapter-track or `chpl` chapter, which never has one, stays D-C4's
  Blue. The layer agrees: an XMP marker with no color is drawn with a Green outline and band, while chapter-track and `chpl`
  chapters stay neutral (`MappedChapter.layerColor`, CHAPTER_MARKERS_PLAN §16.1).

## 7. Size and order

Line counts are estimates from the existing EDL writer (`ResolveEDL.swift`, 328 lines with its reader) and its tests.

| Item | Code | Tests | Attended | Blocked by |
|---|---|---|---|---|
| Shared: format cases, media URL and info accessors, notices, log formats | ~120 lines (App) | log sentinel | — | — |
| **Premiere xmeml** writer and colour table (0.9.5) | ~220 lines (ManifoldCore) | ~250 lines, 5 golden files, P0 structure test | P2–P4 (~1 h) | Nothing. P0 is done |
| **FCPXML 1.10** writer, keywords, chapter type (next build) | ~260 lines | ~300 lines, 5 golden files, DTD validation | F1–F6 (~1 h) | Robbie's FCP sample file, then **FCP on some Mac** for F1 |
| Avid marker XML (next build) | ~150 lines | ~150 lines | import check | Robbie's Avid sample file |
| OTIO for Premiere (alternative) | ~200 lines | ~200 | — | not needed |

**Order (decided 2026-11-17).**

1. **0.9.5: Premiere xmeml** and the shared plumbing, then P2–P4. It is unblocked now.
2. **0.9.5 release notes:** the Premiere export, plus "Exports to Final Cut and Avid are still planned" (§0).
3. **Next build:** Robbie's FCP and Avid sample files, then FCPXML and Avid marker XML, each checked against its
   sample before its writer is designed in detail.

## 8. Decisions (Robbie, 2026-11-17)

**Scope:** 0.9.5 ships the **Premiere export only**.

- Final Cut (FCPXML) and Avid move to the next build.
- Robbie will supply sample files with embedded markers from both apps first.
- **0.9.5's release notes must say the Final Cut and Avid exports are still planned.**

| # | Question | Decision |
|---|---|---|
| E1 | Map any colour to FCP to-do? | **No to-dos.** Applies when FCP is built: standard markers, plus `chapter-marker` for the "chapter" keyword |
| E2 | Keywords into Premiere comments? | **Yes, opt-in:** the EDL's keywords checkbox, off by default |
| E3 | Premiere sequence with the media clip, or media-less like Frame.io? | **The sequence holds the media clip** |
| E4 | FCP start override | **Deferred with FCP** |
| E5 | Avid in 0.9.5? | **No, deferred** to the next build, after Robbie's sample file |

## 9. Summary

1. **Promise** (`docs/release-notes/0.9.4.md:57`) names Premiere, Avid and Final Cut. **0.9.5 ships Premiere only**, and
   its notes must say Final Cut and Avid exports are still planned (§0, §8).
2. **Premiere: FCP 7 XML (xmeml), sequence markers, with the media clip in the sequence (E3).** It keeps name, comment,
   frame and duration. About 220 + 250 lines, unblocked.
3. **Colours, all eight measured (P0):** Green writes no `<pproColor>`. Red 4281740498, Purple 4289825711, Orange
   4280578025, Yellow 4281049552, White 4294967295, Blue 4294741314, Cyan 4292277273. Resolve's 16 map to these
   through §4.1.
4. **Encoding (P0):** one-frame `out = -1`; markers under `<sequence>` after its `<timecode>`; `version="4"`, UTF-8
   with a BOM; stereo audio as two exploded clipitems.
5. **xmeml carries no marker type (P0):** everything imports as Comment, Chapter included.
6. **Line breaks:** Premiere exported none, so notes are flattened to one space unless P4 shows import keeps them.
7. **Timecode (P0):** `<frame>` = plain count and `<string>` = its label, for 23.976 NDF and 29.97 DF. The start
   override goes on the sequence.
8. **Keywords (E2):** appended to the comment, opt-in, off by default. **Chapters and file markers** are not exported
   until converted (D-C5).
9. **UNKNOWN, Premiere, still open:** whether import reads `<pproColor>` back, and whether exclusive ranged `out`
   holds (P2); import of a line break (P4); 59.94 DF and a DF clip in a DF sequence (P3/P2); mono and multichannel
   audio layouts (P2). Clip markers are not needed.
10. **Final Cut and Avid: next build,** after Robbie's sample files. E1 (no to-dos) is decided for then; E4 is
    deferred. §2 and §3 keep the research.

## 10. Avid Media Composer: Joey's samples (2026-11-25)

**Files** in `~/Code/Manifold/fixtures/markers/avid/` (outside the repo; read-only). Marker text and the user name are
not quoted here beyond what a field needs.

| File | What it is | Size |
|---|---|---|
| `AVID MARKERS TEXT.txt` | Markers window ▸ Export Markers, text. 4 lines | 173 B |
| `AVID MARKERS XML.xml` | The same 4 markers as marker XML | 15 412 B |
| `MARKER TEST.aaf` | The sequence as AAF. Writer: "Avid Media Composer 25.12.2" (a UTF-16 string in the file) | 643 072 B |
| `Screenshot 2026-11-24 at 4.19.23 PM.png` | Markers window over the timeline | 1289×752 |

### 10.1 What the screenshot shows (S)

- **Markers window columns:** #, colour, User, Marker Name, TC, End, Track, Part, Creation Date, Comment. Marker Name is
  there, so this is the 2024.6+ layout (§3).
- **Four markers**, one per track: TC1 (timecode track, Green), V1 (Green), V2 (Yellow), A1 (Red). All one user, all
  created 11/20/2026 3:11 PM. **Marker Name is empty on all four**, Part is empty, each comment is its track's name.
- **End = TC + 1 frame** on every row (e.g. `…:10:23` → `…:11:00`). So End is exclusive, and a length of 1 is a
  one-frame marker.
- **Rate:** frame numbers reach 23 and roll to 00, so the sequence is 24 or 23.976. Which one, and DF/NDF: **UNKNOWN**
  (no field in the TXT or XML says). The ruler suggests a 10:00:00:00 start: **UNKNOWN**, not stated in any file.
- Every TXT and XML field below matches what the window shows, row for row. Nothing shown in the window is missing from
  the XML except Part (empty here). The TXT lacks the creation date.

### 10.2 The tab-delimited text (S)

`od -c` of the file:

- **ASCII, LF line endings, a final LF, no BOM, no header line.** One line per marker, sorted by TC.
- **8 tab-separated columns:**

| # | Column | Sample | How it's known |
|---|---|---|---|
| 1 | User | the Avid login | matches the User column |
| 2 | TC | `10:10:10:23` (`:` separators) | matches TC |
| 3 | Track | `TC1`, `V1`, `V2`, `A1` | matches Track |
| 4 | Colour | `Green`, `Yellow`, `Red` | matches the swatch |
| 5 | Comment | the track name; **two of the four end in a space** | matches Comment |
| 6 | Length | `1` | End − TC |
| 7 | *(empty)* | — | **Inferred: Marker Name**, empty in the window. UNKNOWN until a named marker |
| 8 | Colour again | same as column 4 | **Inferred: the 16-colour name**, column 4 the legacy 8. UNKNOWN until a new colour (Pink, Denim…) |

- The trailing spaces match the `/13` in the XML (§10.3): **inferred** that the comment had a carriage return and the
  TXT writes it as a space. UNKNOWN until J1.
- A tab or line break inside a comment cannot survive this format.
- **Duration** is column 6, in frames.

### 10.3 The marker XML (S)

- **Envelope** (`AVID MARKERS XML.xml:1-7`): `<?xml version="1.0" encoding="UTF-8" standalone="no" ?>`, `<!DOCTYPE
  Avid:StreamItems SYSTEM "AvidSettingsFile.dtd">` (the DTD is not supplied), `<Avid:StreamItems
  xmlns:Avid="http://www.avid.com">`, `<Avid:XMLFileData>`, `DomainMagic` = `Domain`, `DomainKey` = `1480739396x`.
  - Frame.io writes `DomainKey` as `58424a44` (REF). That is the same number, 0x58424A44, in hex. Media Composer's form
    is decimal with a trailing `x`. Manifold copies Media Composer's.
- **ASCII, LF, no BOM, no CR anywhere.** Non-ASCII handling is UNKNOWN (Frame.io uses `&#183;`, REF).
- **One `<AvClass id="ATTR">` per marker,** in TC order, each with `__OMFI:ATTR:NumItems` = **12** (`:9`) and a `<List
  id="OMFI:ATTR:AttrRefs">` of 12 `<ListElem>`s plus **one trailing empty `<ListElem/>`** (`:71`).
- Each `<ListElem>` holds `OMFI:ATTB:Kind` (`1` int, `2` string), `OMFI:ATTB:Name`, and `OMFI:ATTB:IntAttribute` or
  `OMFI:ATTB:StringAttribute`.
- **The 12 attributes, in Media Composer's order:**

| Attribute | Kind | Sample | Meaning |
|---|---|---|---|
| `_ATN_CRM_ID` (`:13`) | string | `060a2b34…-c50f` | SMPTE-UMID-style id. Its tail is a machine identifier (privacy, §13) |
| `_ATN_CRM_LONG_CREATE_DATE` | int | `1795205469` | Unix seconds = 2026-11-20 20:11 UTC = the window's 3:11 PM US Eastern |
| `_ATN_CRM_USER` | string | the login | User |
| `_ATN_CRM_DATE` (`:28-29`) | string | `11//20//2026` | the window shows `11/20/2026`: **`/` is written `//`** |
| `_ATN_CRM_TIME` | string | `15:11` | local 24 h |
| `_ATN_CRM_COLOR_EXTENDED` (`:38`) | string | `Green` | the 16-colour name (2024.6+) |
| `_ATN_CRM_COLOR` | string | `Green` | the legacy 8-colour name |
| `_ATN_CRM_COM` (`:49`) | string | track name, two ending **`/13`** | Comment |
| `_ATN_CRM_LONG_MOD_DATE` | int | Unix seconds | modified |
| `_ATN_CRM_TC` (`:58`) | string | `10:10:10:23` | **a timecode string** |
| `_ATN_CRM_TRK` | string | `TC1`, `V1`, `V2`, `A1` | Track |
| `_ATN_CRM_LENGTH` (`:68`) | int | `1` | duration in frames |

- **`/` is an escape character (inferred):** `//` is a literal slash (the date), and `/13` is character 13, a carriage
  return. The TXT's trailing spaces sit on the same two markers. Neither is confirmed: **J1**.
- **No Marker Name attribute** appears, because every name was empty. Its key (likely `_ATN_CRM_NAME`, a guess) and
  where it goes in the order: **UNKNOWN until J1**.
- **Differences from Frame.io's Avid XML (REF, MARKERS_PLAN §0.3):** Frame.io writes 7 attributes (no ID, DATE, TIME,
  COLOR_EXTENDED, LONG_MOD_DATE), `NumItems` 7, and **`_ATN_CRM_TC` as a frame count** (`286`). Media Composer 25.12
  writes a timecode string. Whether Media Composer imports Frame.io's frame-count form: **UNKNOWN** (J3).
- **No rate, no sequence name, no start timecode anywhere in the file.** The import takes the TC string in the receiving
  sequence's own rate.

### 10.4 The AAF (S, string scan only)

- A Structured Storage file. Its strings name `CommentMarker` (10), `DescriptiveMarker` (1), `EventMobSlot` (1), and
  the same `_ATN_CRM_*` keys four times each (`_ATN_CRM_TIME` three times). So **AAF markers are CommentMarkers in an
  event slot carrying the same tagged values as the XML**. The XML loses nothing the AAF has for markers.
- It also holds 13 `file://` URLs with a network host (media locations), the clip and sequence names, and the user
  (§13).
- **AAF stays out.** A writer needs a Structured Storage and AAF object model (no library here, nothing may be
  installed), a whole composition and mob references to media. It would carry no marker field the XML lacks. No strong
  case.

### 10.5 Recommendation: write the marker XML

- **XML, not TXT, for the first build.**
  - It carries the 16-colour name *and* the legacy name (Avid's own recommendation, §3), the comment with an escape for
    line breaks, and the length.
  - The TXT has two inferred columns, can't carry a tab or a break, and Avid says it drops Marker Name and the extended
    colours (§3, DOC).
  - TXT is cheap (~60 lines) and kept in reserve: build it only if J2 shows the XML failing on some Media Composer
    version (AV1).
- **Write Media Composer 25.12's shape, not Frame.io's**: the same envelope, attribute order, `NumItems`, trailing empty
  `<ListElem/>`, LF, no BOM.
- **Attributes Manifold writes (11):** all of §10.3's except `_ATN_CRM_ID` (Frame.io omits it; Media Composer assigns
  ids; whether it requires one is **UNKNOWN**, J2). `NumItems` = 11. If J2 rejects that, generate an id of the same
  shape.

### 10.6 Field map (Manifold → Avid XML)

| Manifold | Avid | Rule |
|---|---|---|
| `frame` | `_ATN_CRM_TC` | `basis.label(frame)`: the file's start TC (or the override) + frame, `HH:MM:SS:FF`. DF separator (`;` or `:`) **UNKNOWN** (J1 with a DF sequence) |
| `duration` | `_ATN_CRM_LENGTH` | frames, as is (End = TC + LENGTH, §10.1). Whether import keeps length > 1: **UNKNOWN** (J2) |
| `name` | Marker Name | Key UNKNOWN (J1). **Until then, name goes into the comment** (AV4) |
| `notes` | `_ATN_CRM_COM` | Line breaks flattened to one space (as Premiere) until J2 shows `/13` imports as a break. `/` → `//` |
| `keywords` | — | Lost, or appended as `[a, b]` with the existing checkbox (E2's rule) |
| `color` | `_ATN_CRM_COLOR_EXTENDED` + `_ATN_CRM_COLOR` | §10.7 |
| — | `_ATN_CRM_USER` | **`Manifold`** (AV3). Never the macOS user |
| — | `_ATN_CRM_TRK` | **`V1`** (AV2) |
| `created`, `modified` | `LONG_CREATE_DATE`, `LONG_MOD_DATE`, `DATE`, `TIME` | Unix seconds; `MM//DD//YYYY` and `HH:MM` local, as in the sample. Locale dependence **UNKNOWN** |

**Edge cases.**

- **Empty name and empty notes:** `_ATN_CRM_COM` written empty. Media Composer's acceptance of an empty comment is
  **UNKNOWN** (every sample comment had text; J2).
- **Empty name, notes present:** the comment is the notes alone.
- **Name and notes (until AV4 is settled):** `name — notes` in the comment; name alone when there are no notes.
- **Escaping:** XML `& < > "` as entities; `/` → `//`; non-ASCII as numeric references (`&#233;`), as Frame.io does,
  until J1 shows what Media Composer writes for an accent.
- **The start TC must equal the receiving sequence's.** Markers go on a sequence, not a source clip (§3, forum). The
  export notice says: "Import onto a sequence that starts at 01:00:00:00" (the file's start, or the override).
- **A sequence with no V1** (audio-only): the import fails or drops the marker, UNKNOWN (J2).

### 10.7 Colours: Manifold's 16 → Avid's 16

Avid's 16 (§3, DOC excerpt): legacy White, Red, Yellow, Green, Cyan, Blue, Magenta, Black; 2024.6 adds Purple, Violet,
Pink, Denim, Forest, Orange, Gold, Grey. **The sample confirms only `Green`, `Yellow`, `Red` and their capitalisation**;
the other spellings and every swatch value are UNKNOWN until J1.

| Manifold | `COLOR_EXTENDED` | `COLOR` (legacy) | Note |
|---|---|---|---|
| Blue | Blue | Blue | same name |
| Cyan | Cyan | Cyan | same name |
| Green | Green | Green | same name (S) |
| Yellow | Yellow | Yellow | same name (S) |
| Red | Red | Red | same name (S) |
| Pink | Pink | Magenta | same name |
| Purple | Purple | Magenta | same name |
| Fuchsia | Magenta | Magenta | nearest |
| Rose | Pink | Magenta | **shares Pink** |
| Lavender | Violet | Magenta | nearest |
| Sky | Denim | Cyan | nearest light blue |
| Mint | Forest | Green | nearest second green |
| Lemon | Gold | Yellow | nearest second yellow |
| Sand | Orange | Yellow | nearest |
| Cocoa | Orange | Red | **shares Orange**; Avid has no brown |
| Cream | White | White | nearest |

- 14 Avid colours are used; Black and Grey never. Two pairs collapse (Rose/Pink, Cocoa/Sand), counted in the notice.
- **The legacy column is a guess.** J1 shows what Media Composer itself writes in `_ATN_CRM_COLOR` for each new colour;
  that replaces this column.
- Import (§12) uses the reverse: Avid's 13 chromatic names to their row's Manifold colour; Black, Grey → Cream (nearest
  neutral, UNKNOWN fit), White → Cream.

### 10.8 Size and tests

- **Writer:** `AvidMarkerXML.export`, pure, Markers target: ~160 lines. TXT writer if AV1 says so: ~60.
- **Unit tests (~200 lines):** golden files per §6.2's cases; a **structure test against Joey's XML** (attribute set,
  order, `NumItems`, trailing `<ListElem/>`, envelope; skips when the fixture is absent; compares structure, never
  values); escaping (`/`, `//`, `&`, CR, LF, tab, emoji, accents); DF labels across minute and hour; the colour table;
  log sentinel (counts only).
- **Attended, Joey, Media Composer 25.12.2:**
  - **J1, a second reference export** (from Joey, before the writer is designed in detail): a 29.97 DF sequence with
    one marker per colour (16), one **named** marker, one ranged marker (30 frames), one comment with a line break,
    one with `/`, one with an accent, and one with nothing typed. Export XML and TXT. Settles the Marker Name key, the
    16 spellings and legacy fallbacks, DF separators, `/13`, non-ASCII, TXT columns 7–8.
  - **J2, import Manifold's XML** onto a sequence cut from `mk-2997df-tc.mov` (we send the fixture; Joey's own media
    not needed). Count, frames against the burn-in, colours, length, a `/13` comment, an empty comment, a file with no
    `_ATN_CRM_ID`. Record any error message word for word.
  - **J3, import Frame.io's XML** (frame-count TC) onto any sequence: does Media Composer accept it? This says whether
    Frame.io's form is a usable fallback.
  - **J4, an older Media Composer** (pre-2024.6) if Joey has one: import J2's file; colours should fall back to legacy.

## 11. Final Cut Pro: Abba's document (2026-11-25)

**File:** `~/Code/Manifold/fixtures/markers/fcpx/Final Cut Pro Markers A Technical Overview for Manifold.docx` (read
with `textutil`). It is a **research write-up** (bylined Abba Shapiro, 2026-11-25), citing Apple, Intelligent
Assistance, FCP Cafe and others. **It is not an FCPXML exported from Final Cut**, so it is documentation, not a sample:
§2's prerequisite (a real FCP export) is still open (FC4). Its claims are labelled **ABBA** below and are not
re-verified here.

### 11.1 What it adds to §2

- **Versions (ABBA):** FCP **13.0 writes FCPXML 1.15**; 12.0 wrote 1.14, 11.0 1.13. §2's "current FCP is 12.4" is
  out of date. FCP exports the current or the previous DTD version. Whether it **imports** 1.10: not stated, UNKNOWN.
- **DTDs (ABBA):** Apple publishes only 1.10 online; each later DTD ships inside the FCP app bundle. FCP 13 also has an
  undocumented `Contents/MacOS/fcptool` with `xml validate` (FCP Cafe). On a Mac with FCP, that validates Manifold's
  file without an import.
- **Marker kinds (ABBA, matches §2 DOC):**
  - Standard: `marker` with no `completed` (blue).
  - To-do: `marker completed="0"` (red). Completed: `completed="1"` (green).
  - Chapter: `chapter-marker`, with optional `posterOffset` (orange). Whether `posterOffset` is relative to the marker
    or on the clip's timeline is unknown even to Abba.
- **Placement (ABBA):** markers attach to clips only, never to `sequence` or `spine`. Allowed parents: `asset-clip`,
  `clip`, `ref-clip`, `sync-clip`, `mc-clip`, `video`, `audio`, `title`, `gap`, `transition`.
- **Time (ABBA):** rational seconds; a marker's `start` is on its clip's local timeline;
  timeline position = clip `offset` + (marker `start` − clip `start`), applied at each nesting level. `tcStart` and
  `tcFormat` on the sequence give the timeline's start TC and DF/NDF.
- **Colours:** none, types only (as §2).
- **Delivered files (ABBA):** FCP writes **chapter markers only**, as a QuickTime chapter text track, when "Include
  chapter markers" is on. No XMP, no sidecar, nothing in source media.

### 11.2 Recommendation: FCPXML 1.10, one browser clip in an event

Unchanged from §2, with two amendments:

- **Smallest import:** `<fcpxml>` → `<resources>` (one `<format>`, one `<asset>` with a `<media-rep>`) → `<event>` → one
  `<asset-clip>` holding the markers (§2's file). No project, no spine: markers ride on the clip and follow it into any
  timeline it is edited into (FC2).
- **Version:** 1.10 stays the target (the only DTD readable here). If FCP 13 refuses it, or `fcptool xml validate`
  flags it, move to 1.13 (oldest one FCP 13 might still export, readable from the app bundle on Abba's Mac) (FC3).

**Frame rates and DF:** `frameDuration` per §2 (`1001/24000s` … `1/60s`); `tcFormat="DF"` on the `asset-clip` for
29.97/59.94 DF. Marker `start` = asset `start` + frame × frameDuration, exact. Asset `start` = the file's own start TC
in seconds (§4.2; E4's override still deferred).

### 11.3 Field map (Manifold → FCPXML)

| Manifold | FCPXML | Rule |
|---|---|---|
| `frame` | `start` | asset start + frame × frameDuration |
| `duration` | `duration` | frames × frameDuration. Whether FCP keeps > 1 frame: UNKNOWN (F3) |
| `name` | `value` (required) | Empty name: write `value=""`. Whether FCP accepts it: UNKNOWN (B0/F3). Fallback: first line of the notes, else `Marker` |
| `notes` | `note` | Breaks as `&#10;`; kept: UNKNOWN (F3) |
| `keywords` | `<keyword>` range over the marker's span | as §2 |
| "chapter" keyword | `chapter-marker` | as §4.3 |
| `color` | — | **Dropped and counted** (FC1). Option: also write the colour name as a keyword range, so an editor can filter by it |
| type | `marker`, no `completed` | E1: never a to-do |

### 11.4 Size, tests, UNKNOWNs

- **Writer:** ~260 lines, tests ~300 (§7, unchanged).
- **Unit tests:** §6.2's FCP items, plus empty-name handling and the colour-keyword option if FC1 takes it.
- **Attended, Abba (FCP 13.0):**
  - **B0, a real reference export** (needed before code): a project with one clip of `mk-2997df-tc.mov`, holding one
    standard, one to-do, one completed and one chapter marker, a ranged marker, a two-line note, and a marker whose
    name was cleared. File ▸ Export XML at 1.15 and at the previous version; also Share a `.mov` with chapter markers
    on. Save to `~/Code/Manifold/fixtures/markers/fcpx/`.
  - **B1:** `fcptool xml validate` on Manifold's golden 1.10 files, if the tool runs; then §6.3's F1–F6 in FCP 13.
- **UNKNOWN until B0/F1–F6:** 1.10 import in FCP 13; nameless `<format>`; empty `value`; duration > 1 frame; note line
  breaks; asset `start` that disagrees with the media (F2); audio attribute mismatch (F4); offline media (F6); 59.94 DF.

## 12. Reading markers from Avid and Final Cut

| Source | Exists? | Manifold today | Size |
|---|---|---|---|
| **FCP chapter markers in a delivered `.mov`/`.mp4`** | Yes (ABBA): a QuickTime chapter text track | Already read by the chapter layer (CHAPTER_MARKERS_PLAN §11.6, §14) | **None** beyond a fixture from B0 and one test that its chapters appear |
| FCP standard/to-do markers in delivered media | **No** (ABBA) | — | — |
| **FCPXML import** (an editor sends their export) | Yes | No | **Large: ~350 lines + ~300 tests.** Walk nested clips, apply `offset`/`start` per level, map the project timeline onto the opened file via `tcStart`; refuse `timeMap`/`conform-rate` with a notice. Types map to Manifold colours (to-do → Red, completed → Green, chapter → "chapter" keyword). MarkersExtractor (open source) is a reference to read, not copy (its license UNKNOWN) |
| **Avid markers embedded in delivered MXF/MOV** | **UNKNOWN.** AAF holds them as CommentMarkers (§10.4); whether Media Composer writes them into an exported OP1a MXF or a QuickTime is not documented and not in any sample. libav's MXF demuxer exposes no markers | No | Ask Joey for an OP1a MXF and a MOV export of the marker sequence (J5). If present: an own MXF KLV parse, **large (~500+ lines)**; if absent, nothing |
| **Avid marker XML / TXT import** | Yes (§10) | No | **Small: ~150 lines + ~150 tests** for XML, ~60 for TXT. TC strings → frames through the opened file's basis (`StartTimecode`), which must share the sequence's start; neither file carries a rate, so the file's rate is assumed and stated in the notice |
| AAF import | Yes | No | Out: same reasons as §10.4 |

**So reading is import of their export files**, except FCP chapters, which Manifold already reads. Nothing from either
app resembles Premiere's XMP.

## 13. Privacy and fixtures

**Nothing is at risk today:** all five sample files sit in `~/Code/Manifold/fixtures/`, outside the repo. The risk is
copying them into `docs/markers/`.

| File | Holds | Commit? |
|---|---|---|
| Avid TXT | the Avid login (every line); comments are track names | **Reduced copy only** |
| Avid XML | the login (4×); `_ATN_CRM_ID`s whose tail looks like a VM network adapter id (a machine identifier); timestamps | **Reduced copy only** |
| Avid AAF | 13 network `file://` URLs (host, share, folders), the client clip name, sequence and bin names, the login | **Never.** No reduced form (binary; no AAF tool here) |
| Screenshot | the login, the client clip name, bin and sequence names | **Never.** §10.1 records what it shows |
| Abba's `.docx` | research text and Abba's byline; no client data | Not needed: §11 summarises it. Commit only if Abba agrees |

**Proposed reduced fixtures** (as D14 did for Frame.io), in `docs/markers/avid-reference/`:

- `avid-mc25.12.txt`: the TXT byte for byte (tabs, trailing spaces, LF) with the login replaced by `editor`.
- `avid-mc25.12.xml`: the XML with the login replaced by `editor` and each `_ATN_CRM_ID` replaced by the same shape
  filled with zeros and a counter. Everything else byte for byte (`//`, `/13`, order, envelope).
- J1's and B0's exports get the same treatment before any copy enters the repo; B0's FCPXML also has its `media-rep`
  paths replaced with `file:///fixtures/…`.
- Made by a sed script recorded in that folder's README, run on a copy; originals never touched.

## 14. Decisions (Robbie, 2026-11-25)

**All accepted as recommended.** P1 is done: `docs/markers/avid-reference/avid-mc25.12.txt` and `avid-mc25.12.xml`,
made as its README records (login → `editor`, ids → counter; sizes unchanged).

| # | Question | Decision |
|---|---|---|
| AV1 | Avid format: XML, TXT, or both? | **XML only.** TXT only if J2/J4 show a version that needs it |
| AV2 | Track for every marker | **`V1`** (every video sequence has it; `TC1` needs a timecode track) |
| AV3 | User field | **`Manifold`**, never the macOS user name |
| AV4 | Marker Name before its key is known | **Wait for J1** before the writer is designed; if it can't wait, name goes into the comment as `name — notes` |
| AV5 | Line breaks in comments | **Flatten** until J2 shows `/13` imports as a break |
| FC1 | FCP colours | **Drop and count** in the notice; colour-as-keyword as an opt-in later if wanted |
| FC2 | FCP file shape | **One asset-clip in an event**, no project |
| FC3 | FCPXML version | **1.10**; 1.13 if FCP 13 or `fcptool` refuses it |
| FC4 | Is Abba's document enough to start? | **No:** it's research. B0 (a real FCP 13 export) still comes first, as §2 required |
| R1 | Import of Avid XML / FCPXML | **Avid XML import with the Avid writer** (small, shares the parser); FCPXML import later, only if colourists receive them |
| R2 | Ask Joey for a delivered MXF/MOV (J5) | **Yes**, one export, to close §12's embedded-marker question |
| P1 | Commit reduced Avid TXT/XML per §13; never the AAF or PNG | **Yes** |

## 15. Summary (2026-11-25)

1. **Avid samples (Media Composer 25.12.2, Joey):** 4 one-frame markers on TC1, V1, V2, A1; TXT, XML, AAF and the
   screenshot agree field for field. No file states a rate or start timecode.
2. **Avid: write the marker XML** in Media Composer's own shape: 11 of its 12 `_ATN_CRM_*` attributes (no ID),
   `_ATN_CRM_TC` as a TC string (not Frame.io's frame count), `LENGTH` in frames, user `Manifold`, track `V1`.
3. **Avid colours:** both `COLOR_EXTENDED` (16) and legacy `COLOR` (8) are written; Manifold's 16 map onto 14 of Avid's,
   two pairs shared. Only Green, Yellow, Red spellings are confirmed.
4. **Avid escapes (inferred):** `/` → `//`, a carriage return → `/13`; TXT turns the return into a space. Confirmed by J1.
5. **Avid UNKNOWNs:** Marker Name key, DF separator, non-ASCII, `/13` on import, ID required, empty comment, length > 1.
   J1 (Joey's second export) and J2 (import of ours) settle them. **AAF is out**: same marker fields, far more work.
6. **FCP: Abba's file is a research document, not an FCPXML export.** It confirms §2's model and adds FCP 13 / FCPXML
   1.15, DTDs in the app bundle, and `fcptool xml validate`. A real export (B0) is still needed before code.
7. **FCP: FCPXML 1.10, one asset-clip in an event,** markers as `marker` (standard, never to-do) and `chapter-marker`
   for the "chapter" keyword; colours dropped and counted; keywords kept as keyword ranges.
8. **Reading:** FCP chapters in delivered files are already read by the chapter layer. Everything else is import of
   export files: Avid XML small (~150 + 150), FCPXML large (~350 + 300). Avid markers in delivered MXF/MOV: UNKNOWN (J5).
9. **Privacy:** the AAF (network paths, client clip name) and the screenshot must never be committed; TXT and XML go in
   only as reduced copies with the login and ids replaced.
10. **Decisions:** AV1–AV5, FC1–FC4, R1–R2, P1 in §14, all accepted as recommended (2026-11-25); the reduced Avid
    fixtures are in `docs/markers/avid-reference/`.
