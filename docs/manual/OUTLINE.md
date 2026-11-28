# Manifold user manual: delivery, outline and UI inventory

Planning document, read-only pass over HEAD `cec4c30` (2026-11-27). Nothing was built or launched. Every claim cites
`file:line` (repo-relative). UNKNOWN means the code did not settle it. Section 5's inventory was compiled by reading code,
not by driving the app; anything marked "verify" must be checked in a build before it goes into a chapter.

Style for chapters: plain, short, American English, task-first, no internal terms (no "deck", "picture codes", "CICP",
"v210", "WHEP" in body text unless the UI itself shows the word).

Contents: 1 How the Sync and Color Guide ships · 2 Shipping the manual the same way · 3 Outline · 4 UI that is hard to
explain (moved to docs/BUGS.md) · 5 Inventory (menus, Settings, player window, output/streams/markers/export/licensing).

---

## 1. How the Sync and Color Guide ships today

| Step | What happens | Source |
|---|---|---|
| Source | One Markdown file, `docs/guides/manifold-0.9-sync-and-color-guide.md`. A PDF copy, `docs/guides/Manifold-0.9-Sync-and-Color-Guide.pdf`, is also committed (cfe4fd5). How the PDF is made: UNKNOWN (no script in the repo produces it). | `docs/guides/` |
| Build | Build phase "Bundle the guides" runs on **every** build: `/usr/bin/python3 scripts/guide/build_guide.py --src … --slug sync-and-color --out <Resources>/Guides`. A failed conversion fails the build; a missing image is a warning. | `project.yml:333-347` |
| Converter | Stdlib-only Python. Writes `Guides/guide.css` (shared) and `Guides/<slug>/index.html` (+ `images/`). Reads a Markdown subset: ATX headings (each gets an `id` slug), lists, `>` callouts, code, pipe tables, bold/italic, links, images with `@2x` and `-dark` variants. Raw HTML is shown as text. `<!-- IMAGE: … -->` comments become a printed shot list. `{{VERSION}}` is left for the app. One `--src` produces one page. | `scripts/guide/build_guide.py:1-30, 201, 219-224, 370-395` |
| Tests | `scripts/guide/test_build_guide.py` (stdlib unittest). | |
| Bundle | `Manifold.app/Contents/Resources/Guides/sync-and-color/index.html`. Offline, always matches the build. | `App/Help/HelpGuides.swift:4-6, 40-48` |
| Help menu | `CommandGroup(replacing: .help)` lists **every** `HelpGuide` case at the top of Help (replacing the stock "Manifold Help"), then a divider, Keyboard Shortcuts…, Download Sync Clips…, a divider, Export Diagnostics…, Export Frame for Support…. | `App/ManifoldApp.swift:279-302` |
| Window | One single-instance `Window` scene per guide, 820×900, removed from the Window menu (`.commandsRemoved()`). | `App/ManifoldApp.swift:417-422` |
| Viewer | `WKWebView` loading the bundled file with read access to `Guides/` only. The app fills the version (`CFBundleShortVersionString`) and the highlight color (live). Light/dark follow the window. Find is in the toolbar: ⌘F, ⌘G / ⇧⌘G, placeholder "Find in Guide". Links inside `Guides/` open in the same view; http/https/mailto open in the browser; anything else is cancelled. With no page bundled: "The guide isn't included in this build." | `App/Help/HelpGuides.swift:53-94, 103-120, 230-245, 270-280` |
| Images | From `docs/guides/images/`, which **does not exist yet**. The guide has 16 `<!-- IMAGE: -->` shots, none taken, so it ships with no pictures today. | `ls docs/guides`; `grep -c "<!-- IMAGE:"` |

**Could the manual ship the same way? Yes.** The code was written for it: "A NEW GUIDE (the "Manifold User Guide") is a
case of `HelpGuide`, a `Window` scene in `ManifoldApp` and a line in the "Bundle the guides" build phase. The Help menu
lists every case, at its top." (`App/Help/HelpGuides.swift:14-16`; also `project.yml:338`, `App/ManifoldApp.swift:281`).

## 2. Shipping the manual beside the guide: what it takes

**Decisions (Robbie, 2026-11-27).** Help item title **Manifold User Guide**, first in Help, the Sync and Color Guide second.
Accepted: D1 (chapter files combined into one page), D2 (generated contents and a build-time link check), D3 (plain-text
pointers to the guide), D4 (`docs/manual/` in `check-us-spelling.py`, done 2026-11-27). Screenshots (D9) later. The converter
and Help changes are a 0.9.6 code task after the chapters settle. Chapter files: `docs/manual/NN-name.md`, each opening with a
`##` chapter heading and `###` sections, so the generated contents list is the chapter list.

**The minimum (three edits, same mechanism):**

1. **Format and source:** Markdown in `docs/manual/`, in the converter's subset (no raw HTML), with `{{VERSION}}` in the
   title line and `<!-- IMAGE: … -->` shot comments. Images go in `docs/manual/images/` (`name.png`, `name@2x.png`,
   `name-dark.png`).
2. **Bundle:** one more line in "Bundle the guides" (`project.yml:346-347`), e.g.
   `--src "${SRCROOT}/docs/manual/<file>.md" --slug manual --out "$DEST"`. The output is
   `Contents/Resources/Guides/manual/index.html`, using the same `guide.css`.
3. **Help item and window:** a `HelpGuide` case first in the enum (Help-menu order is `allCases` order,
   `HelpGuides.swift:24-26`), its title in `title` (`HelpGuides.swift:31-35`), and a `Window(…) { HelpGuideView(guide: .manual) }`
   scene with `.commandsRemoved()` next to the guide's (`ManifoldApp.swift:417-422`). Help would then read
   *Manifold User Guide*, *Sync and Color Guide*, divider, Keyboard Shortcuts… (the item title is Robbie's call;
   the code comment's working name is "Manifold User Guide").

**Where the manual differs from the guide, and what each difference needs:**

| # | Difference | Why it matters | What it takes |
|---|---|---|---|
| D1 | **Several chapters, not one file.** | The converter takes exactly one `--src` and makes one page (`build_guide.py:384-395`). Find only searches the page that is open (`HelpGuides.swift:120-140`), so one page per chapter would break "find in the manual". | Recommended: chapter files `docs/manual/NN-name.md`, and extend `build_guide.py` to accept several `--src` in order and render **one** page. Keep warnings reporting the real chapter file and line. (Cat-ing the files in the build phase would work but would report wrong file:line in warnings.) Alternative: author one long `docs/manual/manual.md`. |
| D2 | **Length and navigation.** | The guide is about 270 lines; the manual will be several times that. The viewer has no contents sidebar, no back button and no generated table of contents. | A contents list at the top, made of in-page `#slug` links (these already work: headings get ids, `build_guide.py:219-224, 241`). Better: the converter generates the contents list from `##` headings. Either way, add a **link check** to the converter that fails the build when a `#slug` points at no heading, because links pass through unchecked today (`build_guide.py:190-195`). |
| D3 | **Pointers to the Sync and Color Guide.** | Each color and sync chapter ends with a pointer to the guide. A relative link (`../sync-and-color/index.html#…`) is allowed by the navigation policy (`HelpGuides.swift:237-243`), so it would load the guide **inside the manual's window**, with no way back. | v1, no code: plain-text pointers ("For the detail, choose **Help ▸ Sync and Color Guide**, section *Calibrating, step by step*."). Later: the app intercepts a guide-to-guide link in `decidePolicyFor` and opens that guide's own window at the heading. |
| D4 | **Spelling check.** | `scripts/check-us-spelling.py` scans app strings and the release notes only (`check-us-spelling.py:7-9, 247-255`). Neither guide is checked. | Add `docs/manual/` (and `docs/guides/`) to `note_findings`, so `release-mac.sh` (`:216-222`) catches British spellings in the manual. |
| D5 | **Find placeholder** says "Find in Guide" for every guide (`HelpGuides.swift:274`). | Minor wording mismatch in the manual's window. | Optional per-guide placeholder ("Find in Manual"). |
| D6 | **File name.** | The guide's source is version-named (`manifold-0.9-…`), so the build line changes on each version. | Give the manual a version-free name and let `{{VERSION}}` carry the version. |
| D7 | **Shortcuts are user-editable** (Keyboard Shortcuts window) and all defaults live in one catalog (`Packages/ManifoldCore/Sources/ShortcutRegistry/ShortcutCatalog.swift`). | A hand-typed table drifts from the catalog. | State "default" in the manual. Option: generate the Shortcuts chapter's table from the catalog at build time, as the guide is generated from Markdown. |
| D8 | **PDF.** | The guide also has a committed PDF; how it is made is UNKNOWN. | Decide whether the manual needs a PDF too. The bundled HTML does not depend on one. |
| D9 | **Screenshots.** | Neither guide nor manual has images yet; the shot-list mechanism is shared. | One shot pass for both, on the LG (by-eye), capturing the Manifold window only (per CLAUDE.md). |
| D10 | **Converter tests.** | Multi-file input, contents generation and the link check are new behavior. | Cases in `scripts/guide/test_build_guide.py`. |

---

## 3. Outline for docs/manual/

Chapters in task order. "Uses" lists the inventory sections in §5 (5A menus, 5B Settings, 5C player window,
5D output/streams/markers/export/licensing). "Reuse" names existing text worth adapting. The release notes' text is
plain and user-facing by rule (`docs/release-notes/0.9.0.md:2-6`), so most of it can be lifted with tense changes.

Key for the color and sync chapters: **[S]** = summarized in the manual, ends with a pointer to the Sync and Color Guide.
**[G]** = guide-only, the manual names it at most. **[M]** = manual-only (not in the guide).

### Ch. 1 Getting started
- Install, first launch, what Manifold is for (one paragraph).
- Trial (7 days) and activating a license: Settings ▸ License, Manifold ▸ License…, the "trial has ended" screen,
  Deactivate on this machine.
- The player window: empty window ("Open a file — or connect a stream", Open…, Connect Stream…), the control bar
  (floating vs docked, pin), narrow-window layouts and the More menu.
- Play a file: Space, J/K/L, arrows, Home/End, the scrubber, click or type a timecode, the readout modes (Source TC,
  Frames, Elapsed), loop, volume and mute.
- One window plays at a time; clicking a window takes over playback.
- Checking for updates.
- **Uses:** 5A app menu, transport keys; 5B §7 License, §3 Playback; 5C §1.1-1.5, §6 (multiple windows); 5D §5, §6c.
- **Reuse:** none substantial. Licensing behavior from 0.9.0 *Licensing and privacy* (`0.9.0.md:165, 236`).

### Ch. 2 Opening files
- Open…, Open Recent, drag and drop, "Open files in" (this window / a new window), making Manifold the default app
  per type.
- What opens: movies (including MXF), audio-only files, stills; Pro Video Formats; what does not open.
- Stills and audio-only files: what changes in the window.
- The Inspector (and the audio track picker), Refresh metadata, Edit in Flip.
- Interlaced files: Color ▸ Fields (Weave, Field 1, Field 2, Deinterlace; display only).
- Subtitles (.srt), window size (View ▸ 100%…Fit to Screen), full screen, show file name.
- **Uses:** 5A File, View, Color ▸ Fields; 5B §2 Files, §6 Sources (Pro Video Formats); 5C §1.3, §2, §5.2, §6.
- **Reuse:** 0.9.2 *Stills*, *Audio-only files* (`0.9.2.md:32, 38`) and their known limitations (`:67`);
  0.9.3 *Audio-only files* (`0.9.3.md:38`); 0.9.0 *Files and interlaced* (`0.9.0.md:137, 204`).

### Ch. 3 Color and display modes
| Topic | Mark | Manual covers | Guide section |
|---|---|---|---|
| What the picture is vs what the window shows (scopes, SDI, export carry the picture; the display mode changes only the window) | [S] | 3-4 sentences | *The model in one paragraph*, intro callout |
| Choosing a display mode: As macOS Shows It / Reference / Bypass, ⌥⌘1-3, control bar | [S] | one line each, when to use it | *The three display transforms* |
| Gamma 1.96 vs BT.1886, HDR tone mapping, HLG→PQ at 1000 nits | [G] | | same |
| Hold to compare (C, ⇧C, ⌥C) | [S] | the whole topic, short | *Hold to compare* |
| Transform chain readout: how to open it (⌥⌘4), what Source / Display / Headroom mean in a phrase | [S] | | *Reading the transform chain* |
| Reference on a desk display: the "calibrated to BT.1886" checkbox, white/black, the warning | [S] | what to tick and when not to | *Reference mode and display calibration* |
| Per-display memory, SDR-only rule, absolute HDR scaling | [G] | | same |
| HDR in the window: needs macOS HDR on; scopes always show the file | [S] | 2-3 lines | *HDR in the window* |
| Fixing wrong tags: presets, Reset to File's Tags | [S] | | *Overriding a source's color tags* |
| One tag at a time, container vs stream tag disagreement | [G] | | same |
| LUTs: Load LUT…, Bypass LUT, Recent LUTs, the LUT Outputs rule of thumb | [S] | | *LUTs* |
| Interpolation, display/calibration LUTs unsupported | [G] | | same |
| Quick answers ("looks different in QuickTime", etc.) | [S] | reuse in Ch. 11 | *Quick answers* |
- **Uses:** 5A Color; 5C §2.4, §4.1-4.4, §5.3 (color banners).
- **Reuse:** the guide's Part 2 wording, cut down; 0.9.0 / 0.9.1 *Color* sections (`0.9.0.md:69`, `0.9.1.md:74, 94`).

### Ch. 4 Scopes and framing guides
- Open the scopes (⌥⌘S), choose a scope per slot, resize the tray; each window keeps its own.
- One section per scope: Waveform, Parade, YRGB Parade, Vectorscope, CIE, Audio Meters, Markers. What each shows,
  its gear options, intensity and trace color.
- Scope Scale, Master scope intensity, Graticule brightness (Settings ▸ Scopes & Guides).
- Scopes measure the picture, not the display (one line, [S] pointer to the guide's model paragraph).
- Framing guides: broadcast safe zones, aspect guides, social ratios and safe zones; their colors in Settings.
- **Uses:** 5B §4; 5C §3, §5.1; 5A scope keys (assignable, no default).
- **Reuse:** 0.9.5 *Scopes* (`0.9.5.md:74`).

### Ch. 5 SDI and HDMI output
- What you need (Blackmagic DeckLink or UltraStudio, Desktop Video), Settings ▸ DeckLink Output status.
- Start and stop (TV button, ⇧⌘D), choose the device, Audio destination, Output mode (Follow source / a fixed mode).
- Reading the Signal rows; scaling and DCI modes (Settings).
- What goes out: always the picture with any override or LUT, never the display mode; stills send black.
  **[S]** for color labelling and HDR metadata, P3→Rec. 2020 conversion **[G]**.
- Errors: card busy, inactive in connector mapping, SDI sound stopped, another window owns the output.
- **Uses:** 5A File; 5B §5; 5C §1.3 DeckLink, §5.3; 5D §1.
- **Reuse:** 0.9.4 *DeckLink setup* (`0.9.4.md:45`); 0.9.3 SDI sections (`0.9.3.md:18, 28`); 0.9.5 *SDI/HDMI output*
  (`0.9.5.md:84, 105`); guide *What reaches SDI and HDMI*.

### Ch. 6 Live streams
| Topic | Mark | Notes |
|---|---|---|
| Connect an NDI source; the Local Network prompt; install the NDI runtime | [M] | |
| Save a stream (Stream Sources: name, URL, passphrase, audio offset); connect once without saving | [M] | URL decides the type: srt://, .m3u8, otherwise web stream |
| Disconnect; what the orange banner messages mean | [M] | |
| Why a stream can be out of sync; sender side vs Manifold side | [S] | 2-3 sentences |
| The audio offset: sign, range −250 to +500 ms, ⌥] ⌥[ (⇧ for 10 ms), Reset, Save to stream, badge | [S] | day-to-day, in full but short |
| "Can move sound earlier by at most N ms" | [S] | one line, then pointer |
| Calibrating: get the clip (Save Sync Clip…), play it on the sender, Calibrate… ▸ Start, Apply | [S] | 5-6 steps |
| Calibration internals, reading "Pairs found", Measure Again detail | [G] | |
| Sync clip design (flash code, hiss, label), the download set | [G] | manual says where to get them |
| Playing the clip from OBS or DaVinci Resolve | [G] | |
| Per-server notes (Cloudflare, MediaMTX `useAbsoluteTimestamp`), per-transport drift advice | [G] | server-specific; keep out of the manual |
| HLS has no offset or calibration; NDI results last the session | [S] | one line each |
| When sync was right and now isn't | [S] | bullet list in Ch. 11, pointer |
- **Uses:** 5C §1.3 Streaming and A/V, §2.4 Buffer; 5D §2; 5B §6 Sources (NDI).
- **Reuse:** the guide's Part 1 wording, cut down; 0.9.0 *Live streams* (`0.9.0.md:126, 188`).

### Ch. 7 Markers
- Add, edit, delete, navigate (M, ⌥M, ⇧M, ⇧↑/⇧↓), In and Out (I, O, ⌥X), colors.
- The Markers window (⌃⌘M) and the Markers scope; filtering, thumbnails, start timecode.
- Markers from your files (chapters and comments): read-only, Convert to Marker.
- Show Markers / Show File Markers; where markers are kept; Remember markers between sessions; Delete All Stored Markers….
- Importing a DaVinci Resolve marker EDL (the hour-offset prompt).
- Markers work on video files only, not on streams.
- **Uses:** 5A Mark, View; 5B §2 Markers, §4 Marker text size; 5C §3.2 Markers; 5D §3.
- **Reuse:** 0.9.4 *Markers*, *Round trip with DaVinci Resolve*, *Where markers are kept* (`0.9.4.md:18, 26, 33`);
  0.9.5 *Markers from your files*, *Start timecode*, *Markers list* (`0.9.5.md:25, 58, 68`).

### Ch. 8 Export
- Export Frame (⌥⌘E): 16-bit PNG, no dialog, where it goes (Settings ▸ Files ▸ Frame Export, per-clip folders).
- Share Frame (⇧⌘E) and Share Frame (SDR)… for HDR.
- Export Markers: the six formats and their options (keywords to notes/comments).
- What Manifold does not export: clips or video.
- **Uses:** 5A File; 5B §2 Frame Export; 5D §4.
- **Reuse:** 0.9.4 *Sharing and export* (`0.9.4.md:38`); 0.9.5 *Export to Premiere Pro*, *Chapter lists*
  (`0.9.5.md:40, 49`).

### Ch. 9 Settings
- Pane by pane, as a reference: General, Files, Playback, Scopes & Guides, DeckLink Output, Sources, License, with
  each control's label, what it does and its default. Cross-link to the task chapters rather than repeat them.
- Export Settings… / Import Settings… / Restore from Backup… (moves shortcuts and saved streams only).
- **Uses:** 5B entire.
- **Reuse:** 0.9.2 *Settings transfer* and its limitations (`0.9.2.md:22, 74`).

### Ch. 10 Keyboard shortcuts
- Default keys by category, in the Keyboard Shortcuts window's order: Transport, Mark, Timecode Entry, View, Scopes,
  Color, Audio, File, Sources and Output, Help.
- Changing a shortcut: record, Replace/Cancel, Reset, Reset All…, search, Find by Key; keys that can't be changed.
- **Uses:** 5A all tables and "Keyboard Shortcuts window". Generate from the catalog if D7 is taken up.
- **Reuse:** 0.9.0 *Interface and shortcuts* (`0.9.0.md:147, 214`).

### Ch. 11 Troubleshooting
- Help ▸ Export Diagnostics… (three questions; what is removed; where it saves) and Export Frame for Support….
- Streams: banner messages and what to do; NDI shows nothing (check the runtime and Local Network permission);
  "When sync was right and now it isn't" **[S]**.
- Color: the guide's *Quick answers* **[S]**; known limitations (HLG over HDMI has no HLG signal).
- SDI/HDMI: driver states, busy card, connector mapping, sound stopped.
- License messages and what to do; Keychain prompts.
- Known limitations, current release.
- **Uses:** 5D §1c, §2c, §5, §6a; 5C §5.3 banners.
- **Reuse:** each release's *Known limitations* (`0.9.5.md:103`, `0.9.4.md:50`, `0.9.3.md:42`, `0.9.2.md:65`,
  `0.9.1.md:207`, `0.9.0.md:347`); refresh per release.

Not given a chapter: About Manifold / third-party licenses (one line in Ch. 1), Debug menu, test shortcuts and the
Advanced pane (left out by design).

---

## 4. UI that is hard to explain plainly

Moved to `docs/BUGS.md`, *0.9.6 UI polish (from the manual outline)* (2026-11-27), ranked and with file:line, plus items found
while drafting chapters. Add new ones there, not here.

**Naming rule (Robbie, 2026-11-27):** where the app uses two names for one thing, the manual uses the name on screen in the
main place it's used, and the inconsistency goes into that BUGS.md entry.

---

## 5. Inventory

Compiled from code at `cec4c30` by four read-only passes; each part keeps its own path abbreviations (defined at its
top). The Debug menu, debug shortcuts and the Advanced pane are excluded. Each part's "Hard to explain" list was merged
into the docs/BUGS.md entry named in §4.


### 5A. Menus and shortcuts

Read-only inventory for the user manual. Labels are the exact strings in code. Default keys come from the shortcut
registry's catalog unless stated otherwise.

**Path abbreviations**

| Abbrev. | File |
|---|---|
| MA | `App/ManifoldApp.swift` |
| SC | `Packages/ManifoldCore/Sources/ShortcutRegistry/ShortcutCatalog.swift` (the default-key catalog) |
| MKA | `Packages/ManifoldCore/Sources/ShortcutRegistry/MenuKeyAudit.swift` (which menu each registry item lives in) |
| SR | `Packages/ManifoldCore/Sources/ShortcutRegistry/ShortcutRegistry.swift` |
| CTR | `App/Shortcuts/ShortcutCenter.swift` |
| KSV | `App/Shortcuts/KeyboardShortcutsView.swift` |
| RS | `App/RasterSize.swift` |
| DT | `App/DisplayTransform.swift` |
| MC | `App/Markers/MarkCommands.swift` |
| CV | `App/ContentView.swift` (per-window enable rules, `installShortcutHandlers`) |

**How items behave when unavailable (applies to every table).** Most items are `ShortcutMenuItem`s (CTR:214-223). They
are **never grayed out**. Choosing one when the window can't do it now just **beeps** (`runFromMenu`, CTR:153-155). The
exceptions, which really are grayed out, are the View raster sizes (RS:342), the Color display modes (DT:216), Next Tag
Override / Reset Tags to Source (DT:224, 226) and Fields (DT:233, 236). The enable rules quoted in "Condition/notes" come from CV:1730-1858.

**Menu order.** The code declares, after the stock menus: File additions (MA:312), View additions (MA:344 RasterSizeCommands, MA:355
MarkCommands' View group), then the new top-level menus `Color` (DT:209, declared MA:353) and `Mark` (MC:23, declared MA:355),
then the opt-in `Debug` menu (MA:374). Where SwiftUI puts the Color and Mark menus relative to Window and Help is not stated in code. The only
measured menu-bar order in a comment predates Color and Mark (RS:328-330: "Apple, Manifold, File, Edit, View, View, Window, Help").
The exact on-screen order is therefore UNKNOWN. Expected: Manifold, File, Edit, View, Color, Mark, Window, Help.

**Excluded.** The **Debug** menu (MA:356-387, which needs `#if DEBUG` and `DebugMenuGate`, either `MANIFOLD_DEBUG_MENU=1` or the
`manifold.debugMenu` default, MA:483-497) and every debug shortcut (the ⌃⌥ namespace, SC:381-411; gated by `ShortcutDebugGate`,
CTR:36-62, and the `MANIFOLD_CONFIG_DEBUG` tier) are left out. So is the `MANIFOLD_MENU_AUDIT` dev timer (CTR:106-126).

---

#### Manifold (app menu)

| Item | Default shortcut | Condition/notes | Source |
|---|---|---|---|
| About Manifold | none | Replaces the stock About item. Opens the single-instance About window. | MA:206-207, MA:424 |
| Check for Updates… | none | Always shown. Says "up to date" too, when chosen from the menu. | MA:208-211 |
| Settings… | ⌘, (stock) | Supplied by SwiftUI for the `Settings` scene. The label comes from macOS, not this code. ⌘, is listed as macOS-reserved. | MA:393, SR:285 |
| License… | none | Opens Settings on its License pane. Not gated by license state. | MA:220-227 |
| Install NDI Runtime… | none | **Only when the NDI runtime is known to be missing** (`runtimePresence == .notInstalled`). Hidden while that is still unknown. Downloads a .pkg directly. | MA:251-254 |
| NDI Downloads Page… | none | Same condition as above. Opens NDI's web page. | MA:255-258 |
| Download Pro Video Formats… | none | **Only when Pro Video Formats is known to be missing** (`availability == .notInstalled`). | MA:270-276 |
| Keyboard Shortcuts… | none | Placed `before: .systemServices`, i.e. under Settings…. Also in Help. | MA:217-219 |
| Services ▸, Hide Manifold, Hide Others, Show All, Quit Manifold | ⌘H, ⌥⌘H, (none), ⌘Q (stock) | Supplied by macOS. Not in this code. The keys are from the reserved list. | SR:284-285 |

#### File

| Item | Default shortcut | Condition/notes | Source |
|---|---|---|---|
| New Window | ⌘N (stock) | SwiftUI's WindowGroup item. The Open group sits right after it (`after: .newItem`). | MA:312, SR:285 |
| Open… | ⌘O | **Not rebindable** (the only non-fixed, non-debug item that isn't). Lands in an empty window, otherwise in the window chosen by a Settings preference. | MA:313-314, SC:225-226, SC:194 |
| Open Recent ▸ | none | Submenu. | `App/RecentFiles.swift`:124 |
| &nbsp;&nbsp;&nbsp;&nbsp;*(file names)* | none | One row per recent file, showing the last path component. | `App/RecentFiles.swift`:129-147 |
| &nbsp;&nbsp;&nbsp;&nbsp;No Recent Files | none | Disabled placeholder, shown when the list is empty. | `App/RecentFiles.swift`:125-127 |
| &nbsp;&nbsp;&nbsp;&nbsp;Clear Menu | none | Disabled when the list is empty. | `App/RecentFiles.swift`:150-152 |
| Export Frame… | ⌥⌘E | Needs a picture: a renderer and a media kind that feeds it. So no audio-only file. | MA:324, SC:228, CV:1794 |
| Share Frame… / **Share Frame (SDR)…** | ⇧⌘E | Title changes to "Share Frame (SDR)…" while the key window's picture is PQ or HLG. Same gate as Export Frame. Sends an SDR JPEG through the share sheet. | MA:327, `App/FrameShare.swift`:32-37, `Packages/ManifoldCore/Sources/FrameShareFormat/ShareLabel.swift`:18, SC:233, CV:1796 |
| Close / Close All | ⌘W / ⌥⌘W (stock) | macOS items. | SR:286 |
| Import Markers… | none | Needs markers to be active: a **video** file is loaded, its markers are read, and no live source owns the window. | MA:330, SC:235, CV:1780, `App/Markers/MarkerModel.swift`:384-386 |
| Export Markers… | none | Markers active **and** at least one marker. | MA:331, SC:236, CV:1783 |
| Disconnect Live Source | ⌥⌘⌫ | Needs this window to hold the devices **and** have a live source. | MA:338, SC:239, CV:1848-1850 |
| Start/Stop DeckLink Output | ⇧⌘D | **Always shown**, whether or not DeckLink hardware is present. Works when this window holds the devices (`deviceControlsEnabled`), otherwise beeps. One item that toggles. What happens with no card is UNKNOWN (not traced past `startDeckLinkOutput`). | MA:339, SC:240-241, CV:1852-1858 |

Separators: after Open Recent (MA:321), before Import Markers (MA:329), before Disconnect (MA:334).

#### Edit

| Item | Default shortcut | Condition/notes | Source |
|---|---|---|---|
| (stock Edit menu: Undo, Redo, Cut, Copy, Paste, Select All, and so on) | ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A | **No code adds to or replaces the Edit menu**: there is no `CommandGroup` for it in MA:196-388. The keys are from the reserved list. Marker edits register with the window's undo manager, so Undo/Redo apply to markers. | SR:287-288, `App/Markers/MarkerModel.swift`:672 |

#### View

The stock View items (Show Tab Bar, Show All Tabs, Enter Full Screen) are SwiftUI's (RS:324-326). The stock Toggle Sidebar is
emptied out of View (MA:205; a hidden SwiftUI item that keeps no key). Manifold's items are added `after: .toolbar`, in two groups (RS:332, MC:19).
How those two groups are ordered against each other is UNKNOWN (not measured in code).

| Item | Default shortcut | Condition/notes | Source |
|---|---|---|---|
| 100% | ⌘1 | Checkmark toggle. **Grayed out** while the key window has no source. | RS:333-342, RS:102, SC:310 |
| 75% | ⌘2 | Same as 100%. | RS:103, SC:311 |
| 50% | ⌘3 | Same as 100%. | RS:104, SC:312 |
| 25% | ⌘4 | Same as 100%. | RS:105, SC:313 |
| Fit to Screen | ⌘0 | Same as 100%. ("Automatic (fit on open)" and "Custom" exist but are not menu items.) | RS:106, RS:113, SC:314 |
| Show/Hide Inspector | ⌘I | Always works. | RS:348, SC:315, CV:1791 |
| Show/Hide Scopes | ⌥⌘S | Always works. `MenuKeyKeeper` takes ⌥⌘S back from SwiftUI's hidden Toggle Sidebar. | RS:349, SC:334, CTR:249-327 |
| Show/Hide File Name | **N** (bare) | The menu shows a bare N. Typed into a text field, N is just a letter. | RS:350, SC:316-317, CV:1792 |
| Always Show Controls | ⌥⌘T | Needs a source and a window that isn't docked. | RS:351, SC:318, CV:1793 |
| Loop Playback | ⌘L | Files only: needs media and position control. | RS:353, SC:267, CV:1759 |
| **Audio** (section header) | none | A `Section("Audio")` inside View. | RS:355 |
| &nbsp;&nbsp;&nbsp;&nbsp;Volume Up | ⌘↑ | +0.1 of the fader. Repeats while held. Needs transport. | RS:356, SC:372, CV:1844 |
| &nbsp;&nbsp;&nbsp;&nbsp;Volume Down | ⌘↓ | −0.1 of the fader. Repeats while held. | RS:357, SC:373, CV:1845 |
| &nbsp;&nbsp;&nbsp;&nbsp;Mute / Unmute | ⌥⌘↓ | The catalog comment calls this key "UNVERIFIED (§8)". | RS:358, SC:370-374, CV:1843 |
| Show Markers | none | Checkmark toggle. **App-wide and remembered** (not per window). Off hides the timeline flags and the marker lists; nothing is deleted. Adding a marker turns it back on. | MC:20, MC:44-54, SC:319-322 |
| Show File Markers | none | Checkmark toggle, on by default, app-wide and remembered. Hides only the file's own markers (chapters, XMP). Show Markers off hides these too. | MC:21, MC:56-67, SC:323-327 |
| Enter Full Screen (stock) | fn-F (system) | The stock item. Manifold's own **⌘F**, with ⌃⌘F as a fixed alias, is a window key with no menu item of its own. | SC:328-331, CTR:189, CTR:198 |

Separators: before Show/Hide Inspector (RS:347), before Loop Playback (RS:352).

#### Color

A new top-level menu (DT:209). It is **not** debug-gated (MA:351-352).

| Item | Default shortcut | Condition/notes | Source |
|---|---|---|---|
| As macOS Shows It | ⌥⌘1 | One of three checkmark choices, applied to the key window. **Grayed out** until the key window has a source (`colorControlsEnabled`). This is the default mode (DT:113). | DT:210-216, DT:85, SC:347 |
| Reference (BT.1886) | ⌥⌘2 | Same as above. | DT:86, SC:348 |
| Bypass — No Color Management | ⌥⌘3 | Same as above. | DT:87, SC:349 |
| Show/Hide Transform Chain | ⌥⌘4 | Needs a source. Wakes the controls to show the readout. | DT:221, SC:350, CV:1802-1805 |
| Next Tag Override | none | **Grayed out** when the file gives the renderer no picture (audio-only). Also needs device control and a picture. Cycles the interpretation override. | DT:223-224, SC:358, CV:1835 |
| Reset Tags to Source | none | Same as Next Tag Override. | DT:225-226, SC:359, CV:1836-1838 |
| Fields ▸ | none | **Grayed out unless the source is a woven interlaced file** (`fieldsOffered`). | DT:230-236 |
| &nbsp;&nbsp;&nbsp;&nbsp;Weave | none | Checkmark choice. | DT:232, `Packages/ManifoldCore/Sources/FileScan/FieldView.swift`:72 |
| &nbsp;&nbsp;&nbsp;&nbsp;Field 1 (Display Only) | none | Same as Weave. | DT:232, FieldView.swift:73 |
| &nbsp;&nbsp;&nbsp;&nbsp;Field 2 (Display Only) | none | Same as Weave. | DT:232, FieldView.swift:74 |
| &nbsp;&nbsp;&nbsp;&nbsp;Deinterlace (Display Only) | none | Same as Weave. | DT:232, FieldView.swift:75 |

Separators: before Transform Chain (DT:220), before Next Tag Override (DT:222), before Fields (DT:229).

#### Mark

Every item needs markers to be active: a **video** file, markers read, no live source (`MarkerModel.swift`:384-386).

| Item | Default shortcut | Condition/notes | Source |
|---|---|---|---|
| Add Marker | **M** (bare) | Adds on the frame on screen, even while playing. | MC:24, SC:274-275, CV:1762 |
| Add Marker and Edit… | ⌥M | | MC:25, SC:276 |
| Edit Marker… | ⇧M | Edits the marker at the playhead, else the nearest one before it. On a selected file marker (chapter) it shows a "can't be edited" note instead. | MC:26, SC:281-282, CV:1773-1775 |
| Delete Marker | none | Needs a marker at the playhead. No default key, because bare ⌫ belongs to timecode entry. | MC:27, SC:273, SC:277-278, CV:1764 |
| Previous Marker · ⇧↑ | (⇧↑, not a menu key) | **The key is written into the title** (`ShortcutCenter.hint`). The item has no key equivalent, because ⇧+arrow can't be one. | MC:29, MC:6-7, CTR:148-150, SC:286 |
| Next Marker · ⇧↓ | (⇧↓, not a menu key) | Same as Previous Marker. | MC:30, SC:287 |
| Mark In | **I** (bare) | | MC:32, SC:288 |
| Mark Out | **O** (bare) | | MC:33, SC:289 |
| Clear In and Out | ⌥X | | MC:34, SC:290 |
| Convert All File Markers to Markers | none | Needs at least one file marker not yet converted. One undo step. Formerly "Convert All Chapters to Markers". | MC:37, SC:291-295, CV:1787 |
| Show Marker List | ⌃⌘M | Opens or raises the single-instance "Markers" window. Works from anywhere in the app. | MC:39, `App/Markers/MarkersWindow.swift`:116-123, SC:285, MA:411 |

Separators: MC:28, 31, 35, 38.

#### Window

| Item | Default shortcut | Condition/notes | Source |
|---|---|---|---|
| (stock Window menu: Minimize, Zoom, Fill/Center/tiling, window list, and so on) | ⌘M Minimize, ⌥⌘M Minimize All (stock) | **No code adds items.** The single-instance windows (Keyboard Shortcuts, Markers, Sync and Color Guide, About) are deliberately **removed** from the Window menu with `.commandsRemoved()`. Once closed, they are reopened from their own menu items. | MA:404-446, SR:286-287, RS:274-280 |

#### Help

| Item | Default shortcut | Condition/notes | Source |
|---|---|---|---|
| (macOS Help search field) | ⇧⌘/ (system) | Supplied by macOS. | SR:303 |
| Sync and Color Guide | none | Replaces the stock "Manifold Help". One item per `HelpGuide` case; there is one case today. | MA:282-286, `App/Help/HelpGuides.swift`:26, 31-33 |
| Keyboard Shortcuts… | none | Duplicate of the app-menu item. | MA:293 |
| Download Sync Clips… | none | Not gated. Opens the sync-clip download link. | MA:294 |
| Export Diagnostics… | none | Not gated. The audit keeps it, in this order, directly above Export Frame for Support… under one separator. | MA:299-300, MKA:99 |
| Export Frame for Support… | none | Needs a renderer. Saves the diagnostic frame set (PNG, .rgba16f, .v210, .v210.json). | MA:302, SC:377-379, CV:1798-1800 |

Separators: MA:292, MA:299.

---

#### Keyboard Shortcuts window (Help ▸ Keyboard Shortcuts…, also Manifold ▸ Keyboard Shortcuts…)

- Window title "Keyboard Shortcuts". Single instance. Not listed in the Window menu (MA:404-408, KSV:20).
- **Categories, in this order** (SC:113-125, KSV:44): Transport, Mark, Timecode Entry, View, Scopes, Color, Audio, File,
  Sources and Output, Help. A category with no matching rows is hidden (KSV:46). **Debug** appears only when the Debug menu
  is on, headed "Debug hooks (read-only; shown because the Debug menu is on)" (KSV:54-61, CTR:55-61).
- Each row has a subtitle: its **scope** ("Anywhere", "Any window", "Files only", "Live sources only", "While entering
  timecode"), then "Default: …" if customized, then the catalog note (KSV:262-268, SC:140-148).
- **User-editable: yes.** Click a key, then press the new one. "Esc cancels; Delete removes the key." (KSV:134, KSV:196-206).
  - Not editable: Open… (⌘O), fixed rows (timecode entry, K + J / L) and debug hooks (SC:194, KSV:212).
  - A key macOS owns is refused (SR:148, SR:280-306).
  - A clash asks "… is used by …. Replace it there?" with Replace / Cancel (KSV:219-238).
- Reset: "Reset <Category>" appears on a category that has changes (KSV:107-110). "Reset All…" asks first with
  "Reset every shortcut to its default?" (KSV:71-79, KSV:145). Each customized row has a dot marker and a reset arrow (KSV:138, 164-177).
- Search field "Search shortcuts", which matches the title or the key label. "Find by Key" means press a key to see what uses
  it (KSV:88-99, KSV:246-259).
- Saved in one defaults key, `manifold.shortcuts` (`ShortcutStore.swift`:2-4). Settings' settings transfer can include
  "Keyboard shortcuts (N customized)" (`App/SettingsTransferUI.swift`:249). Which Settings pane hosts this is not traced (UNKNOWN).

#### Player-window shortcuts with no menu item (registry defaults)

All of these are `.key`, `.hold` or `.fixed` dispatch: handled by the app's key monitor, not shown in any menu (SC:157-168).

| Action (registry title) | Default key | Scope / notes | Source |
|---|---|---|---|
| Play / Pause | Space | Files only | SC:244 |
| Shuttle Reverse (press again for faster) | J | Files only. Repeats. | SC:245-246 |
| Stop Shuttle | K | Files only | SC:247 |
| Shuttle Forward (press again for faster) | L | Files only | SC:248-249 |
| Hold K, press J or L: one frame; keep holding: ½× play | K + J / L | Fixed. Follows whatever keys are bound to J, K and L. | SC:250-252 |
| Step Back One Frame / Step Forward One Frame | ← / → | Files only. Repeats. Off for audio-only files. | SC:253-256, CV:1751-1752 |
| Step Back One Second / Step Forward One Second | ⇧← / ⇧→ | Files only. Repeats. | SC:257-260 |
| Go to Start / Go to End | Home / End | Files only | SC:261-262 |
| Go to Start (no Fn needed) / Go to End (no Fn needed) | ⌥← / ⌥→ | Files only | SC:263-266 |
| Previous Marker / Next Marker | ⇧↑ / ⇧↓ | Named in Mark-menu titles, but not menu keys | SC:286-287 |
| Type a Timecode (+ or − for relative) | 0–9, +, − | Fixed | SC:298-301 |
| Go to the Typed Timecode | Return (also keypad Enter) | Fixed, only during timecode entry | SC:302-303 |
| Cancel Timecode Entry | Esc | Fixed | SC:304-305 |
| Delete the Last Digit | Delete (also forward delete) | Fixed | SC:306-307 |
| Enter or Exit Full Screen | ⌘F (and ⌃⌘F) | Any window | SC:328-331 |
| Hold to Compare: macOS ↔ Reference | C (hold) | Release to go back | SC:352-353 |
| Hold to Compare with Bypass | ⇧C (hold) | | SC:354-355 |
| Hold to Compare with the LUT Off | ⌥C (hold) | Does nothing with no LUT applied | SC:356-357 |
| Audio Later by 1 ms / Audio Earlier by 1 ms | ⌥] / ⌥[ | **Live sources only.** Repeats. | SC:362-365, CV:1741-1743 |
| Audio Later by 10 ms / Audio Earlier by 10 ms | ⌥⇧] / ⌥⇧[ | Same as the 1 ms keys. | SC:366-369 |
| CIE: Switch xy / u′v′ | none (assignable) | Scopes | SC:335 |
| Vectorscope: Rec. 709 / Source Primaries Graticule | none (assignable) | Scopes | SC:336 |
| Vectorscope: 75% / 100% / Both Boxes | none (assignable) | Scopes | SC:337 |
| Parade: Switch RGB / YRGB | none (assignable) | Scopes | SC:341 |
| CIE: Show/Hide Rec. 709 Triangle / P3 Triangle / Rec. 2020 Triangle | none (assignable) | Scopes | SC:342-344 |

---

---

### 5B. Settings window

Opened with Manifold ▸ Settings… (⌘,). Manifold ▸ License… opens the same window on the License pane (App/ManifoldApp.swift:223-224).
The window has a toolbar of tabs. In a release build there are seven panes, in this order (App/SettingsView.swift:26, 34-41):
General, Files, Playback, Scopes & Guides, DeckLink Output, Sources, License.
The window does not remember which pane was open: it opens on General every launch (App/SettingsView.swift:12-13, 76-78).

**Tooltips:** no control in the Settings panes, the Export or Import sheets, or the License section has a `.help(...)` tooltip.
Each control's explanation is a caption line under it, quoted (shortened) in Notes below. Checked by grep across
App/SettingsView.swift, App/SettingsTransferUI.swift and LicenseManager.swift:816-923.

**DEBUG only (excluded from this inventory):** an eighth pane, "Advanced", exists only in DEBUG builds with the Debug menu gate on. It is read-only:
Debug menu state, Live audio WAV capture, DeckLink audio trim (App/SettingsView.swift:27-29, 63-71, 834-858).
Note: Manifold's CLAUDE.md says Profile, the configuration every build so far has used, has DEBUG=1. So testers' builds can
show this pane when the gate is on. It is shown only when `ShortcutDebugGate.showsDebugSection` is true (App/SettingsView.swift:67).

---

#### 1. General (App/SettingsView.swift:283-371)

| Control | Type & options | Default | Notes (tooltip, condition) | Source |
|---|---|---|---|---|
| **Appearance** section | | | | :316 |
| Highlight color | Color well, no opacity | #FFE600 (`AppYellow.hex`) | Caption: "Used for the playhead, controls, on-picture overlays and override text." | :317-318; default Packages/.../PlayheadSliderTests.swift:327 |
| (warning caption) | Orange text | — | Shown only when the chosen color is close to green: "Live states (DeckLink output, a connected stream) also use green." | :319-322 |
| Use Default Highlight | Button | — | Shown only when the highlight is not the default color | :323-325 |
| **Windows** section | | | | :328 |
| Controls | Picker (inline radio): "Overlay (floating)", "Docked (fixed bar)" | Overlay (floating) | Changes every open window at once (code comment :286-290). Key `controlDisplayMode` | :329-334; labels App/Preferences.swift:38-50 |
| Raster size for new windows | Picker: "Automatic (fit on open)", "100%", "75%", "50%", "25%", "Fit to Screen" | Automatic (fit on open) | Caption: picture size as a percentage of the source raster. Set per window in the View menu (⌘1–⌘4, ⌘0). This setting is what a new window starts at, and it follows the last window you set. Does not change open windows (:299-304) | :336-341; options App/RasterSize.swift:99-118 |
| **Keyboard** section | | | | :345 |
| Keyboard shortcuts → "Open Keyboard Shortcuts…" | Button | — | Caption: "Also in the Manifold and Help menus." | :346-349 |
| **Export and Import** section | | | | :353 |
| Settings → "Export Settings…" | Button, opens the Export sheet (§1a) | — | Caption: "Moves your keyboard shortcuts and saved streams to another Mac. When an import changes your shortcuts, Manifold saves a backup of them first." | :356, :365, :368 |
| Settings → "Import Settings…" | Button, opens a file chooser ("Choose a Manifold settings file"), then the Import sheet (§1b) | — | | :357; App/SettingsTransferUI.swift:56-57 |
| Backups → "Restore from Backup…" | Button, opens a file chooser ("Choose a shortcuts backup"), then the sheet in Restore mode | — | Shown only when at least one shortcuts backup exists | :360-363; App/SettingsTransferUI.swift:40, 67-68 |

##### 1a. Export Settings sheet (App/SettingsTransferUI.swift:213-390)

| Control | Type & options | Default | Notes (tooltip, condition) | Source |
|---|---|---|---|---|
| Keyboard shortcuts (N customized) | Toggle | On | Grayed when there are no customized shortcuts ("You haven't customized any shortcuts, so there's nothing to export.") or the stored shortcuts can't be read | :218, :249-255 |
| Saved streams (N) | Toggle | Off | Grayed when there are no saved streams or they can't be read. With streams off: "A shortcuts file is plain text. It holds no stream addresses, passwords or license details." | :219, :256-263 |
| Password | Secure field, placeholder "At least 12 characters" | empty | Shown only when Saved streams is on. The file is encrypted with it | :279-281; 12 = Packages/ManifoldCore/Sources/SettingsTransfer/SettingsEncryption.swift:25 |
| Confirm password | Secure field, "The same password again" | empty | Shown with Password. Orange warning: "This password can't be recovered. Without it, nobody can open this file, including Graviton." | :282-286 |
| Cancel / Export… | Buttons | — | Export… is grayed until something is selected and, with streams on, the passwords are valid and match | :265-272 |
| (progress) | "Reading stream X of N…" with Cancel; "Encrypting…" | — | | :237-239 |
| Export Without Them / Try Again / Cancel | Buttons | — | Shown only when some streams can't be read ("N streams couldn't be read.", "No file has been written yet.") | :324-349 |

##### 1b. Import Settings / Restore Shortcuts sheet (App/SettingsTransferUI.swift:562-823)

The title is "Import Settings", or "Restore Shortcuts" when opened from Restore from Backup… (:572).

| Control | Type & options | Default | Notes (tooltip, condition) | Source |
|---|---|---|---|---|
| Password + Open / Cancel | Secure field + buttons | empty | Only for an encrypted file: "This file is encrypted. Enter the password it was exported with." | :599-613 |
| (origin line) | Text | — | "Made by Manifold <version>, <date>." | :671-675 |
| Keyboard shortcuts | Toggle | UNKNOWN (set in SettingsImportSession, not read) | Shown when the file has shortcuts | :630 |
| Merge / Replace All | Segmented picker, label hidden | UNKNOWN (session) | Import only, not Restore. Merge: "Adds the file's shortcuts to yours…" Replace All: "Your shortcuts become the file's. Shortcuts the file doesn't mention go back to their defaults." | :631-642 |
| Preview lists | "Will change (N)" (old → new key), "Key already in use (N)", "Not imported (N)" | — | | :677-720 |
| "<command>: use the file's key, <key>" | Toggle, one per conflict | UNKNOWN (session `useFile`) | Caption says which command loses its key, or that this Mac's key is kept | :699-702 |
| Saved streams | Toggle | UNKNOWN (session) | Shown when the file has streams. Lists Added / Renamed / Already here / Not imported. Add-only: existing streams are never changed (:722) | :650-651, :723-764 |
| Cancel / Import (or Restore) | Buttons | — | Grayed with "Nothing to change." when there is nothing to do | :659-667 |
| Undo Import / Undo Restore, Done | Buttons (after import) | — | Undo shown when a backup was made or streams were added. A confirmation alert may follow ("Undo Import" / "Cancel"). Result text includes "Your previous shortcuts were saved first… use Restore from Backup… in Settings." and an A/V offset note pointing to A/V ▸ Calibrate… | :773-804, :584-593 |

---

#### 2. Files (App/SettingsView.swift:376-477)

| Control | Type & options | Default | Notes (tooltip, condition) | Source |
|---|---|---|---|---|
| **Opening Files** section | | | | :389 |
| Open files in | Picker: "This window", "A new window" | This window | Caption: applies to Open… (⌘O) and the Open button. Dragging a file onto a window's picture always replaces that window, and an empty window is always re-used. Key `manifold.open.destination` | :390-395; App/Preferences.swift:18-35 |
| "<type> open in" (one row per file type: MXF files, QuickTime movies, MP4 files, WAV files, AIFF files, MP3 files, M4A files, AAC files) | Read-out of the current default app + "Use Manifold" button | (system state) | The button is hidden when Manifold is already the default (shows "Manifold"). Shows "No app" when nothing claims the type. Caption per row: "At least N apps on this Mac can open <type>." plus the outcome after a claim (orange only on failure). Group caption: Manifold can take an association but can't hand it back; to undo, select a file in the Finder, ⌘I, change "Open with". Rows whose type the system doesn't know are dropped | :415-426; rows App/Preferences.swift:1014-1028; row view App/Preferences.swift:1269-1305 |
| **Frame Export** section | | | | :429 |
| Folder | Read-out of the path | Desktop (shown when no folder is chosen; the "Use Desktop" button implies this) | Key `exportFolderBookmark` | :430-435 |
| Choose… | Button, opens a folder chooser ("Choose a folder for exported frames") | — | | :437, :466-476 |
| Use Desktop | Button | — | Shown only when a folder has been chosen | :438-440 |
| Put exported frames in a folder per clip | Toggle | Off | Caption: "Export Frame saves into a folder named after the clip, or the stream, inside this folder. Share Frame is not affected." | :382, :442-446 |
| **Markers** section | | | | :450 |
| Remember markers between sessions | Toggle | On | Caption: Off means a file's markers last only while it is open and nothing is saved, not even thumbnails. Turning it off deletes nothing already saved; turning it back on applies to files opened afterwards | :384, :451-454 |
| Delete All Stored Markers… | Button → confirmation dialog "Delete all stored markers?" with destructive "Delete All Stored Markers" | — | Dialog text: every file's saved markers and thumbnails are deleted, and markers in open windows are cleared. Cannot be undone. Exported EDL, CSV and text files are not touched | :455-461 |

---

#### 3. Playback (App/SettingsView.swift:481-539)

| Control | Type & options | Default | Notes (tooltip, condition) | Source |
|---|---|---|---|---|
| **Playback** section | | | | :509 |
| Autoplay on open | Toggle | Off | No caption. Users who ever flipped it keep their stored value (App/Preferences.swift:64-77) | :485, :510 |
| **Playhead** section | | | | :513 |
| Playhead | Segmented: "Ball", "Line" | Line | Applies to every window | :516-521; Packages/ManifoldCore/Sources/PlayheadSlider/PlayheadSlider.swift:7-24 |
| Playhead color | Segmented: "Same as highlight", "Custom" | Same as highlight (inferred: follows when no color was stored, or the stored color is the old default #FFE600) | Shown only when Playhead = Line. Caption: "The playhead uses the highlight color (General ▸ Highlight color)." / "The playhead keeps this color whatever the highlight color is." | :523-534; PlayheadSlider.swift:35-42 |
| Custom playhead color | Color well, no opacity | the current highlight color, until one is picked | Shown only when Line + Custom | :529-531, :499-505 |

---

#### 4. Scopes & Guides (App/SettingsView.swift:543-632)

| Control | Type & options | Default | Notes (tooltip, condition) | Source |
|---|---|---|---|---|
| **Scopes** section | | | | :568 |
| Scope Scale | Picker: "8-bit (0–255)", "10-bit (0–1023)", "IRE (0–100)" | 10-bit (0–1023) | No caption. PQ and HLG exist in the enum but are not offered (App/WaveformScope.swift:246-249) | :547, :569-573; labels App/WaveformScope.swift:265-273 |
| Master scope intensity | Slider, 0.25 to 3.0 (no numeric read-out; sun icons at each end) | 1.0 | Multiplies each scope's own intensity (App/Preferences.swift:91-92) | :544, :574-581; range App/Preferences.swift:156 |
| Graticule brightness | Slider, 0 to 2.0 (no read-out; sun icons) | 1.0 | Caption: sets the lines in every scope; at its lowest the lines are off and the labels stay. Each scope's own intensity and trace color are in its header, in the scopes tray. The audio meters don't use it (:582-583) | :545-546, :584-594; range/default Packages/ManifoldCore/Sources/ScopeCompute/ScopeGraticuleBrightness.swift:22-24 |
| Marker text size | Segmented: "Small", "Medium", "Large" | Medium | Caption: "The size of the marker list's text and rows in the Markers scope. Also in that scope's gear." | :549, :595-599; Packages/ManifoldCore/Sources/Markers/MarkerTextSize.swift:12-27 |
| **Broadcast safe zones** section | | | | :604 |
| Broadcast safe zone color | Color well (opacity allowed) | #FFFFFF | | :605; default App/Preferences.swift:139 |
| Broadcast safe zone width: N pt | Stepper, 1–8 pt, step 1 | 1 pt | | :606-607; App/Preferences.swift:140 |
| Broadcast safe zone opacity | Slider 0–100%, with % read-out | 75% | Caption: "Action- and title-safe percentages are set in the framing guides popover." | :608-610; App/Preferences.swift:141 |
| **Frame guide** section | | | | :613 |
| Outside (darken) color | Color well | #000000 | | :553, :614 |
| Outside opacity | Slider 0–100%, % read-out | 85% | | :552, :615-616 |
| Guide line color | Color well | #FFFFFF | | :554, :617 |
| Guide line width: N pt | Stepper, 1–10 pt | 2 pt | | :555, :618-619 |
| **Social safe zones** section | | | | :623 |
| Social safe zone color | Color well | #FFFF00 | | :556, :624 |
| Social safe zone width: N pt | Stepper, 1–8 pt | 1 pt | | :557, :625-626 |
| Social safe zone opacity | Slider 0–100%, % read-out | 75% | | :558, :627-628 |

---

#### 5. DeckLink Output (App/SettingsView.swift:636-718)

| Control | Type & options | Default | Notes (tooltip, condition) | Source |
|---|---|---|---|---|
| **Device** section | | | | :654 |
| DeckLink | Status read-out, one of: "Desktop Video not installed"; "Desktop Video installed (version unknown)"; "Desktop Video <v> — too old"; "N devices found, 0 usable with Desktop Video <v>"; "No device detected (Desktop Video <v>)"; "N device(s) (Desktop Video <v>)" | (system state) | Orange when the user can fix it (not installed, too old, version unreadable), gray otherwise. Caption explains what to do (e.g. "Install Blackmagic Desktop Video <floor> or later, then relaunch Manifold.") | :661-668, :674-675; texts App/DeckLink/DeckLinkService.swift:258-308 |
| Download Desktop Video… / Update Desktop Video… | Button (opens Blackmagic's download page) | — | Shown only when the driver is missing ("Download") or too old ("Update") | :669-673 |
| (device list) | Caption list of device names | — | Shown when ready. A sub-device made inactive by the card's connector mapping is listed grayed, with a note | :676-688 |
| Open Desktop Video Setup… | Button | — | Shown only when Blackmagic's Desktop Video Setup app is installed | :690-692; title App/DeckLink/DesktopVideoSetup.swift:12 |
| **Output** section | | | | :695 |
| Enable output on launch | Toggle | Off | Caption: starts DeckLink output at launch if a capable device is connected. Turning output on/off during a session doesn't change this | :643, :696-697 |
| Audio at launch | Segmented: "SDI (follows video)", "Computer" | SDI (follows video) | Caption: "Audio-only files play on the Mac until a later update." The starting value only; the toolbar picker changes the session and doesn't write it (:644-645) | :646, :698-702; labels Packages/ManifoldCore/Sources/ColorimetryModel/SDIOutputMode.swift:65-81 |
| SDI scaling | Segmented: "Fit to mode", "1:1 pixels" | Fit to mode | Caption changes with the choice. Fit: Follow source picks the closest-size mode at the source's rate and scales to fill, keeping shape, black around. 1:1: picks the smallest mode that holds the picture unscaled; larger pictures are scaled down | :650, :703-709; SDIOutputMode.swift:48-59 |
| SDI output modes | Segmented: "HD/UHD only", "Include DCI" | HD/UHD only | Caption: "Include DCI adds 2048×1080 and 4096×2160, to Follow source and to the output mode picker." | :648, :710-714; SDIOutputMode.swift:34-45 |

No row on this pane is hidden when there is no DeckLink hardware: the Output controls are always shown (:695-715). Only the Device-section buttons are conditional.

---

#### 6. Sources (App/SettingsView.swift:722-830)

| Control | Type & options | Default | Notes (tooltip, condition) | Source |
|---|---|---|---|---|
| **NDI** section | | | | :730 |
| NDI Runtime | Status: "Installed (<version>)" gray, or "Not installed" orange | (system state) | | :731-740 |
| Install NDI Runtime… / Reinstall NDI Runtime… | Button (opens the runtime installer URL) | — | Always shown; wording follows the state | :751-753 |
| NDI downloads page | Link | — | Always shown. Caption: "After installing the NDI runtime, relaunch Manifold to enable NDI sources." | :755-756 |
| **Pro Video Formats** section | | | | :759 |
| Pro Video Formats | Status: "Installed (N components)", "Not installed", "Checking…" (all gray) | (system state) | | :773-788 |
| Download Pro Video Formats… / Reinstall Pro Video Formats… | Button (opens Apple's support page) | — | Hidden while "Checking…" | :796-801 |
| (captions) | Text | — | "Apple's optional package. Adds AVC-Intra, XAVC, IMX, DVCPRO HD, uncompressed and ProRes RAW…" (+ "Relaunch after installing." when absent). Always: "MXF and DNxHR files are decoded by Manifold itself and are not affected by this package." (code marks this TEMPORARY, :813) | :802-826 |

---

#### 7. License (App/LicenseManager.swift:816-923; hosted at App/SettingsView.swift:114)

| Control | Type & options | Default | Notes (tooltip, condition) | Source |
|---|---|---|---|---|
| "Your license couldn't be read" | Orange warning + explanation | — | Shown first, only when the Keychain read failed | LicenseManager.swift:825-833 |
| Status | Read-out, one of: "Checking…"; "Couldn't read the Keychain — status unknown" (orange); "License locked" (orange); "Licensed to <email or 'you'> · <Standard / Beta / NFR / License>[ · registration pending]"; "Trial — N day(s) left"; "Trial expired" (orange) | — | The trial is 7 days (LicenseManager.swift:57) | :864-900; type names :155-162 |
| License key | Text field, label hidden, placeholder "MNFL-…" | empty | Shown only when not licensed and the Keychain read did not fail; hidden while status is undetermined. Return activates. Caption: "Paste your whole key, including "MNFL-"." | :838-848, :902-921 |
| Activate | Button (+ spinner while working) | — | Grayed while working or with an empty field | :914-916 |
| Deactivate on this machine | Destructive button | — | Shown when licensed, or when locked (beside key entry). Hidden while undetermined | :846-853, :860-862 |
| (message line) | Caption | — | Last result message from the license client | :854-856 |

Related, outside Settings: the full-window gate shown when the trial has ended or the license is locked ("Your Manifold trial has ended" / "…license is locked", key field, Activate, "Need a key? Visit graviton.tools"), LicenseManager.swift:927-979.

---

---

### 5C. Player window

Read-only inventory of HEAD (cec4c30). All paths are relative to `~/Code/Manifold/Manifold`. `CV` = `App/ContentView.swift`.
Keyboard shortcuts come from `Packages/ManifoldCore/Sources/ShortcutRegistry/ShortcutCatalog.swift` (`SC` below). Tooltips built with
`keys.helpText(...)` append the shortcut a user has bound, so the exact key shown can change.

**Excluded: DEBUG-only items.** These are the `#if DEBUG` shortcut handlers (CV:1860-1955), the Debug shortcut entries (SC:382-410), the `CommandMenu("Debug")`
(`App/ManifoldApp.swift:374`), and per-view `ScopePerf`/`MenuProbe` counters. Note: CLAUDE.md says Profile builds have `DEBUG=1` and that every build shipped so far is
Profile, so a tester may be able to reach these.

---

#### 1. Control bar (transport)

##### 1.1 Where the bar lives

| Item | What it does (plain words) | Condition | Source |
|---|---|---|---|
| Floating bar (Overlay) | The controls float over the bottom of the picture in a rounded dark panel. They fade out after about 2 s without the pointer moving, and come back when you move the pointer over the window. | Settings ▸ General ▸ Windows ▸ Controls = "Overlay (floating)" (the default) | CV:1283-1296, CV:3797, `App/Preferences.swift:39,46`, `App/SettingsView.swift:321,330` |
| Docked bar | The controls sit in a fixed black bar below the picture. The window grows taller to fit it, and the bar never hides. | Controls = "Docked (fixed bar)" | CV:598-600, CV:1427-1439, `App/Preferences.swift:40,47` |
| Pin button (`pin` / `pin.fill`, yellow when on) | Keeps the floating bar visible all the time. Tooltip: "Pin controls" / "Unpin controls". | Overlay mode only, and only with a source loaded | CV:3604-3612, CV:3773-3778; menu equivalent "Always Show Controls" ⌥⌘T (SC:318) |
| Empty window | Shows a film icon, the line "Open a file — or connect a stream", and two buttons: "Open…" and "Connect Stream…". Connect Stream… is a menu holding an "NDI" submenu and the stream URL items. | No source loaded | CV:3616-3655 |

##### 1.2 Scrubber row (the top line)

| Item | What it does | Condition | Source |
|---|---|---|---|
| Leading readout (playhead) | Shows the current position. Click it, or type digits, to open timecode entry. Tooltip: "Go to timecode — click, or type a number". When the control is grayed, the tooltip says why. | Clicking needs a playback position | CV:3000-3035, CV:3022 |
| Timecode-source glyph | A tiny glyph at the readout's top-right corner when the timecode does not come from a timecode track. Its tooltip names the source. | Source-TC mode only | CV:3833-3843 |
| Scrubber | Drag to scrub. Markers and file chapters appear on it as flags, and clicking a flag jumps to it. Playback pauses while you drag and resumes on release. | Grayed for live streams and stills | CV:3041-3113, `App/Markers/MarkerEditorSheet.swift:246-300` |
| Trailing readout | Shows the duration or end. Click it to cycle the display through Source TC, Frames and Elapsed. Both readouts follow the chosen mode. | Frames is skipped for audio-only files. Source TC falls back to Elapsed when the file has no timecode. | CV:3115-3121, CV:3845-3875, CV:11 |
| Timecode entry overlay | An on-screen entry box. Its title reads "TIMECODE", "POSITION · NO TIMECODE TRACK", "OFFSET" or "OFFSET · TIMECODE". The hint reads "⏎ go ⎋ cancel · …". Clamped entries show "clamped to the first/last frame". | While typing a timecode | CV:3807-3813, `App/TimecodeEntry.swift:475-476,531-543` |
| Still line (replaces the scrubber) | "Still image · W × H · SDR / HDR (PQ) / HDR (HLG) / HDR (gain map)" | A still is open | CV:2936-2941, `App/StillImageSurface.swift:63`, `Packages/ManifoldCore/Sources/StillImageInfo/StillImageInfo.swift:55-58,171` |

##### 1.3 Buttons (Full layout, left to right)

| Item (icon) | What it does | Tooltip (`.help`) | Condition | Source |
|---|---|---|---|---|
| Open (`folder`) | Opens a file into this window | "Open…" + key (⌘O, SC:225) | always | CV:3346-3351 |
| Play/Pause (`play.fill`/`pause.fill`) | Starts or pauses playback | "Play"/"Pause" + Space. When grayed, the reason instead (e.g. "Playback is in another window", "… is a live stream — there is no playback position…", "A still image has no playback position.") | Needs a playback position, and this window must be the active one | CV:3353-3363, `App/WindowDeck.swift:1421-1452` |
| Mute (`speaker.slash/wave.1/wave.2.fill`) + volume | Mutes. A small volume slider appears only while the pointer hovers here. The icon shows the level. | "Mute"/"Unmute" + ⌥⌘↓ | Active window only | CV:3374-3405, CV:3762-3765 |
| Loop (`repeat`, yellow when on) | Loops playback | "Loop playback" (⌘L, SC:267) | file with a position | CV:3412-3419 |
| Framing guides (`viewfinder.rectangular`) | Opens the Framing Guides popover (§5) | "Framing guides" | always | CV:3430-3456 |
| Captions (`textformat`, yellow when shown) + chevron | Main button: shows or hides loaded subtitles, or opens the picker when none are loaded. Chevron menu: "Load subtitles…"/"Load different subtitles…", "Clear subtitles", a Position section ("Title-safe" / "Bottom edge"), and a "<file> — N cues" info row. The picker accepts .srt only. | "Captions on — click to hide" / "Captions off — click to show" / "Load subtitles…". Chevron: "Subtitle options" | Video files only | CV:2395-2448, CV:2451-2461, `App/Captions/CaptionOverlay.swift:12-13` |
| Inspector (`info.circle`) | Shows or hides the Inspector (§2) | "Inspector" + ⌘I | always | CV:3459-3464 |
| Edit in Flip (`f.square`) | Opens the file in Flip. If Flip is not installed, a sheet explains it with "Not Now" and "Get Flip" buttons. | "Edit in Flip" | Hidden for non-video files | CV:3466-3484, CV:3697-3714, CV:981-1007 |
| Refresh metadata (`arrow.clockwise`, yellow when the file changed) | Re-reads the file | "Refresh metadata" / "This file changed on disk — click to reload" / "Editing in Flip — reload to pick up any changes" | a file is open | CV:3510-3524, CV:3755-3759 |
| Export frame (`square.and.arrow.down`) | Saves the current frame | "Export Frame…" + ⌥⌘E | Video only | CV:3535-3541 |
| Share frame (`square.and.arrow.up`) | Opens the share sheet with the frame | "Share Frame…", or "Share Frame (SDR)…" for an HDR picture (⇧⌘E) | Video only; this button appears in the Full layout only | CV:3546-3552, `Packages/ManifoldCore/Sources/FrameShareFormat/ShareLabel.swift:18` |
| Audio track (`waveform` + label) + chevron | Picks the monitored track ("Monitored audio track", rows "1 · …"). The menu ends with the info row "Speakers, meters and SDI all follow this track". | "Audio track — which track you are monitoring (speakers, meters and SDI all follow)" / "…this file has one: …" / "…this source offers no track selection" | Grayed with fewer than 2 tracks | CV:2063-2127 |
| Scopes (`chart.bar.xaxis`, yellow when open) | Opens or closes the scopes tray (§3) | "Scopes tray" + ⌥⌘S | always | CV:3567-3573 |
| DeckLink (`tv`/`tv.fill`, green when on) + chevron | Starts or stops SDI/HDMI output. The chevron has sections "Output device", "Audio" (Audio destination: "SDI (follows video)" / "Computer"), "Output mode" ("Follow source (…)" or a fixed mode), "Signal", "Unavailable" and "Output off". | "DeckLink output — click to start" / "DeckLink output ON — … — click to stop" (⇧⌘D). Chevron: "DeckLink output options" | Grayed while another window owns the device | CV:2177-2340 |
| Streaming (`antenna.radiowaves.left.and.right`, green when live) + chevron | Main button: connects the first NDI source, or disconnects. The chevron holds an "NDI" submenu (sources, "Searching for NDI sources…", or "NDI runtime not installed…"), "Stream URL…", a "Streams" section of saved streams, "Manage…" and "Disconnect". | "Streaming — local mode; click to connect the first NDI source, or use the menu to pick" / "Streaming — <name> — click to stop". Chevron: "Streaming sources" | Grayed while another window owns it | CV:2352-2383, CV:2470-2605 |
| Color interpretation (`paintpalette` + face) | See §4.3 | see §4.3 | file or live source | CV:3165, `App/Live/LiveColorOverride.swift:236-251,290-316` |
| Display transform (`display` + "macOS"/"Reference"/"Bypass") | See §4.1. A Fields control sits beside it for interlaced files. | see §4.1 | a source is loaded | CV:3589-3593, `App/DisplayTransformControl.swift:55-58` |
| A/V offset (`waveform` "A/V", plus a blue badge when not 0) | Live-stream audio offset. Menu: "Sound later +1 ms ⌥]", "Sound earlier −1 ms ⌥[", the ±10 ms rows, "Reset to 0 ms", Save/Revert to saved stream, "Calibrate…", "Save Sync Clip…", "Download ProRes Sync Clips…". On HLS the face reads "A/V offset — not on HLS". | "Audio offset for this stream: … Positive = sound later. ⌥] / ⌥[ = ±1 ms, with ⇧ = ±10 ms." | Live sources only | CV:3598-3602, `App/Live/LiveAudioOffset.swift:194-293` |
| Pin | see 1.1 | | | |

##### 1.4 Narrow-window layouts

The app picks the first of three layouts whose natural width fits. No fixed breakpoints are used (CV:3178-3196; `docs/NARROW_WINDOW_LAYOUT_PLAN.md` §2.2).
Play, the scrubber, Mute, Display transform, DeckLink and Pin appear in every layout (CV:3182-3184).

| Layout | Contents | Moved to More (…) | Source |
|---|---|---|---|
| Full | All of 1.3, in one row | n/a | CV:3125-3180 |
| Compact | Open, Play, Mute, Inspector, Audio track, Scopes, DeckLink, Streaming, Color (short face), Display, A/V, More, Pin | Loop, Framing guides, Captions, Edit in Flip, Refresh, Export, Share | CV:3199-3226 |
| Narrow (two rows) | Row 1: Open, Play, Mute, Audio track, Loop, Inspector, Scopes. Row 2: DeckLink, Streaming, A/V, Color (icon only, "●" when overridden or a LUT is loaded), Display, More, Pin | Framing guides, Captions, Flip, Refresh, Export, Share (Loop stays on the row) | CV:3230-3268, `App/Live/LiveColorOverride.swift:323-325` |
| Still image | Open, Guides, Inspector, Refresh │ Scopes, DeckLink, Streaming, Color (grayed, face "Still"), Display (grayed), Pin. Wraps to two rows when narrow. | no More menu | CV:2954-2995, CV:3526-3532 |

##### 1.5 More menu (`ellipsis.circle`)

Present in the Compact and Narrow layouts. The icon turns yellow when something inside is on. Its tooltip then reads "More — <on-states>", which can be the reload
message, "subtitles shown", "framing guides on" or "loop on" (CV:3271-3338).

| Item | What it does | Condition | Source |
|---|---|---|---|
| Edit in Flip | as the button | Hidden for non-video files; grayed with no file | CV:3274-3278 |
| Refresh Metadata (or the reload message) | as the button | file open | CV:3280-3284 |
| Subtitles ▸ Show Subtitles (toggle) | Shows or hides loaded subtitles | subtitles loaded | CV:3285-3288 |
| Subtitles ▸ Load Subtitles… / Load Different Subtitles… | Opens the .srt picker | video files only | CV:3289, CV:3299 |
| Subtitles ▸ Clear Subtitles, Position | as the chevron menu | subtitles loaded | CV:3290-3296 |
| Export Frame… (+key) | as the button | video only | CV:3300-3301 |
| Share Frame… / Share Frame (SDR)… (+key) | as the button | video only | CV:3304-3305 |
| Framing Guides… | Opens the guides popover, which hangs from More | always | CV:3306, CV:3324-3327 |
| Loop Playback (+key) (toggle) | Loop | Compact layout only (`includesLoop: true`) | CV:3307-3311, CV:3218, CV:3259 |

---

#### 2. Inspector panel

A 280-pt dark panel at the top-right of the picture, titled "Inspector". It shows only when a file is loaded (`engine.hasMedia`). Toggle it with the button,
⌘I, or View ▸ Show/Hide Inspector (CV:1327-1332, `App/InspectorPanel.swift:35`, SC:315). With no metadata it reads "No media loaded" (`InspectorPanel.swift:193`).
Values the file does not actually state (for example "Not declared") appear muted and in italics (`InspectorPanel.swift:333-351`).

##### 2.1 Video file

| Field | What it shows | Condition | Source |
|---|---|---|---|
| File Name | file name | always | InspectorPanel.swift:45 |
| Codec | codec | always | :55 |
| Picture (orange) | Standing warning that the picture is decoded imperfectly on this Mac | only when there is a caveat | :68-70 |
| Resolution | stored (encoded) raster | always | :77 |
| Orientation | e.g. "Rotated 90° clockwise" | only if the file is rotated | :81-83 |
| Clean Aperture / Crop Applied "(rounded)" | declared crop / the crop actually used | only if the file crops | :86-96 |
| Pixel Aspect | always shown, including "not declared" | always | :102 |
| Display Size | size after crop and pixel aspect | only if it differs from Resolution | :105-107 |
| Display Aspect | e.g. 1.78 | when known (absent on the libav/MXF path) | :120-122 |
| Frame Rate | | always | :123 |
| Scan | progressive/interlaced, field order and who said so | always | :126 |
| Window View | how this window shows the fields (display only) | interlaced files that offer field views | :129-131 |
| Start TC | start timecode, with its source note | when known | :133-138 |
| Data Rate, Container | | always | :139-140 |
| Primaries, Transfer, Matrix | the file's color tags, with code numbers | always | :144-146 |
| Range + "Override" segmented control (Auto / Full / Legal) | Range as tagged. The override reads e.g. "Limited → Full (override)". | always | :147-155, :20-27, :380-401, `FrameEngine.swift:38-40` |
| Full Chroma | "Full-swing (spec)" or "Resolve" when full range, else "—" | always | :156-157, `FrameEngine.swift:63-64` |
| nclc | the nclc triple | always | :158 |
| Dolby Vision (orange if a warning) | | Dolby Vision files | :162-165 |
| HDR10 Static Metadata section: Mastering, R/G/B xy, White Point, Max/Min Luminance (or "Primaries not declared" / "Not declared"), MaxCLL, MaxFALL ("Unspecified (0)" or "N nits"), Content Light | | HDR transfer or HDR10 metadata present | :171-176, :417-464 |
| Audio / Audio (N) section: Playback (orange caveat); rows "Track N · codec · layout" plus a second line "rate · bits · data rate". Clicking a row selects the monitored track (tooltip "Monitor this track — speakers, meters and SDI all follow" / "Monitoring this track"). An inferred layout appears in italics. | | file has audio | :267-292, :520-583 |
| Timed Text / Timed Text (N) | embedded caption services, read-only. An empty service is shown in orange. | file has text tracks | :180-187, TextTrackRow |
| Chapters | "N" or "N · M after the end" | file has chapters | :590-600 |
| File section: Software, Creator, Encoded, Added to Disk, Modified | | when present | :297-312 |

##### 2.2 Audio-only file
File Name, Format (e.g. "WAV · 24-bit PCM"), Duration, Container. A Broadcast Wave section appears when there is a BWF chunk, then the Audio and File sections
(`InspectorPanel.swift:208-236`; `Packages/ManifoldCore/Sources/AudioFileInfo/AudioCardText.swift:13-36`).

##### 2.3 Still
File Name, Format, Dimensions ("(rotated)"), Color Profile ("Untagged"), Bit Depth, HDR Type, Headroom, Capture Date, then File: Added to Disk, Modified
(`InspectorPanel.swift:239-264`; `StillImageInfo.swift:168-182`).

##### 2.4 Transform chain readout (popover off the Display control)
Open it with Display ▸ "Show Transform Chain…", with ⌥⌘4, or with Color ▸ Show/Hide Transform Chain (`DisplayTransformControl.swift:208-210`, SC:350, `DisplayTransform.swift:212`).
Title: "Transform chain" (`DisplayTransformControl.swift:294`).

| Row | Example / possible values | Condition | Source |
|---|---|---|---|
| Source | "[1080i59.94 TFF · ]<primaries> · <transfer> · <matrix> · full/limited/range unknown — CICP p-t-m — tagged/assumed/partly assumed/overridden (Override …)". Reads "no source" when empty. The override words appear in yellow. | always | DisplayTransformControl.swift:297, `App/DisplayChainModel.swift:207-227`, `Colorimetry.swift:97-100` |
| Tags | a note on the source's color tags | when present | DisplayTransformControl.swift:298-300 |
| Chroma | e.g. "4:2:2 10-bit (x422) — native", "… — 4:2:0 source, converted at decode", "· DeckLink v210 output: reduced once to 4:2:2 (halfband)", "· software decode", "no picture" | always | :301, `ColorimetryModel/ChromaFormat.swift:200-230` |
| LUT | the LUT line (yellow when applied) | LUT loaded | :302-304 |
| Transform | "As macOS shows it — source colorspace declared to the layer" / "Bypass — no colorspace declared, no conversion" / Reference summaries (e.g. "Reference — BT.1886, …", "Reference — PQ absolute, 1.0 = 100 nits, no tone map", "Reference unavailable — …"). Adds " (held)" during a compare. | always | :305, DisplayChainModel.swift:265-274, `App/ReferencePlan.swift:77-137` |
| Fields | field-view line, or "each picture is one field — shown as stored (no field views)" | interlaced | :306-309, DisplayChainModel.swift:378-380 |
| Display | "<screen> — <curve description>" / "no profile available" / "no screen" | always | :310, DisplayChainModel.swift:278-290 |
| Headroom | "headroom X of Y" ["— none granted"], "display is in SDR mode", "no screen" | always | :311, `ColorimetryModel/HeadroomReadout.swift:51-60` |
| Buffer | live buffer, e.g. "250 ms + SRT 120 ms" | live push sources | :312-314, DisplayChainModel.swift:42 |
| Verdict (icon) | "macOS is converting this picture for this display." / "macOS is passing this picture through unchanged." / "HLG (…) → macOS HLG adjustment · follows display brightness · scopes show the file" / "PQ (…) → macOS HDR10 tone map · …" / "display in SDR mode · above 100 nits clips" / "Source declares its transfer outside the rTRC (PQ/HLG); no curve comparison is possible." | when computable | :316-327, DisplayChainModel.swift:296-330 |
| Display calibration: "This display — <name>", checkbox "This display is calibrated to BT.1886 (Rec. 709)", fields "Display white (cd/m²)" / "Display black (cd/m²)", captions | Per display. Notes: "These settings apply in Reference mode only." / "…apply to SDR sources only. HDR is shown absolute (1.0 = 100 nits)." | always (grayed when not applicable) | DisplayTransformControl.swift:410-447 |
| Footer | "Scopes are unaffected by this setting — they measure the file, not the display." | always | :338-344 |
| Sole line instead of the chain | "Audio-only file" / "Still image: shown as macOS shows it" | audio-only / still | DisplayChainModel.swift:371-372, StillImageSurface.swift:19 |

---

#### 3. Scopes

##### 3.1 Tray, slots, arrangement

| Item | What it does | Condition | Source |
|---|---|---|---|
| Scopes tray | A strip of three equal slots below the picture. The window grows taller to fit it. | toggled by the Scopes button, ⌥⌘S, or View ▸ Show/Hide Scopes | CV:601-605, CV:1517-1530, SC:334, `App/RasterSize.swift:340` |
| Slot picker | Click the scope's name (top-left of each slot, with a small chevron) to choose: Waveform, Parade, YRGB Parade, Vectorscope, CIE, Audio Meters, Markers | each of 3 slots | CV:51-100, CV:13-34 |
| Default slots | Waveform, Parade, CIE | first run | `App/WindowChrome.swift:68-70` |
| Tray height | Drag the hairline at the tray's top edge to resize it. The height is fixed in points and does not scale with the window. Minimum 186 pt. | | CV:1472-1513, WindowChrome.swift:87 |
| Per-window | Each window keeps its own tray and slots. A new window opens with the arrangement of the last window changed ("last writer wins"). | | WindowChrome.swift top comment (lines ~1-40) |
| Common header controls (value scopes and vectorscope) | Gear (options popover), sun icon plus "intensity" slider, color well (trace color), reset arrow | | e.g. `App/WaveformScope.swift:907-935` |
| What scopes measure | The file after any LUT ("picture codes"), never the display transform | | DisplayTransformControl.swift:340; CLAUDE.md color rule |
| Settings ▸ Scopes & Guides | "Scope Scale" (8-bit (0–255) / 10-bit (0–1023) / IRE (0–100)), a global intensity, graticule brightness, "Marker text size" | app-wide | `App/SettingsView.swift:38,568-600`, WaveformScope.swift:247-271 |

##### 3.2 Per scope

| Scope | Header (as shown) | Options (gear and header) | Source |
|---|---|---|---|
| Waveform | "WAVEFORM · luma <matrix> (10-bit)", or "· PQ (nits)" / "· HLG (%·nits)". "*" = forced scale. A still adds a header note. | Gear "Vertical scale & reference markers": section "Vertical scale · transfer" (Auto (follow source) / SDR (%/code) / PQ (nits) / HLG (% + nits)), section "Reference markers" (Marker 1, Marker 2: checkbox plus a value in IRE/code/nits/%). Intensity, trace color, "Reset trace color". | WaveformScope.swift:907-935, 1505-1540, 322-330, 357-366 |
| Parade | "PARADE · RGB (…)" | Same gear as Waveform. Intensity. The color well makes the parade one color; reset tooltip "Reset parade to RGB". | `App/ParadeScope.swift:254-281` |
| YRGB Parade | "YRGB · Y <matrix> · RGB (…)" | Same gear. Intensity. Same color well as Parade; reset tooltip "Reset parades to color". | `App/YRGBScope.swift:233-260` |
| Vectorscope | "VECTORSCOPE · <matrix> · gr Rec. 709 · box 75" | Gear "Vectorscope options": "Graticule reference" (Fixed 709 (reference) / Source primaries), "Target boxes" (75% / 100% / 75% + 100%), "Graticule extras" (Outer ring ticks, Skintone axis (I)), "Reference markers" (Marker 1/2, typed "#RRGGBB or R,G,B", note "Entered as sRGB → placed in <gamut>"). Intensity, trace color, "Reset trace color". | `App/VectorscopeScope.swift:17-50, 430-490, 1040-1070` |
| CIE | "CIE 1976 u′v′" or "CIE 1931 xy" · "<primaries> · <transfer> — tagged/assumed/LUT output", or "no source" | Gear "CIE options": "Mode" (u′v′ (1976) / xy (1931)), "Gamut triangles" (709, P3, 2020). No intensity or color controls. | `App/CIEScope.swift:340-395`, `App/ScopeColorFeed.swift:143-169` |
| Audio Meters | "METERS · N ch dBFS" / "· waiting for audio" / "· no audio track" / "· audio not read" / "· paused" / "· —". Empty-state text: NO AUDIO TRACK, AUDIO NOT READ, WAITING FOR AUDIO, NO SOURCE | Gear "Meter options": "Reference marker" (Marker checkbox plus a dBFS value; the tooltip warns it reads sample peak, not true peak). A red "CLIP" button ("Clear all clip indicators") appears when clipped. Click a channel's clip light to clear it ("Clipped — click to reset" / "No clipping"). Channel tooltip "Channel N — <role> (declared by the file)". | `App/AudioMeterScope.swift:158-177, 516-594, 627-650, 883-937` |
| Markers | "MARKERS · N" or "· shown of N" "· N from file", plus IN/OUT chips | Gear "Markers": "Show" (Thumbnails, Regenerate Thumbnails, color filter swatches, "From File" chip, Show All), "Text size", "Markers" (Open Markers Editor, Import Markers…, Export Markers…), "Start timecode" (Set / Reset). Row right-click: Edit…, Go to Marker, Color, Regenerate Thumbnail, Delete Marker, Convert to Marker, Convert All File Markers to Markers. Empty text: "Markers are for video files.", "No markers. Press <key> to mark the frame on screen.", "Markers are hidden. View ▸ Show Markers … shows them again.", "Nothing in the filter chosen." | `App/Markers/MarkersScopeView.swift:41-118, 156-202, 230-260, 345-380, 590-597` |

Scope keyboard toggles (no default keys): "CIE: Switch xy / u′v′", "Vectorscope: Rec. 709 / Source Primaries Graticule",
"Vectorscope: 75% / 100% / Both Boxes", "Parade: Switch RGB / YRGB", "CIE: Show/Hide Rec. 709/P3/Rec. 2020 Triangle" (SC:335-344; handlers CV:1806-1833).

Histogram: none found. `ScopeKind` has no histogram case (CV:13-15).

---

#### 4. Color and display modes

##### 4.1 Display transform (control bar `display` menu; also the menu bar's Color menu)

| Item | What it does | Condition | Source |
|---|---|---|---|
| As macOS Shows It ("what your client will see"). Face: "macOS" | Default. macOS color-manages the picture for this display. | | DisplayTransformControl.swift:189-192, DisplayTransform.swift:85,113 |
| Reference ("BT.1886, as a reference monitor shows it"). Face: "Reference" | A reference-monitor rendering for this display. It uses the calibration fields. HDR is shown absolute. | | :193-195, ReferencePlan.swift |
| Bypass ("no color management"). Face: "Bypass" plus an orange "BYPASS" badge | No color management (diagnostic). The window title gains " — Bypass". | | :196-199, :132-145, WindowDeck.swift:450 |
| Show Transform Chain… | Opens the readout (§2.4) | | :208-210 |
| Tooltip | "Display transform: as macOS shows it — what your client will see" / "…: Reference — BT.1886 for this display" / "…: BYPASS — no color management. Diagnostic only." When grayed: the readout's single line | | :97-102 |
| Menu bar Color ▸ "As macOS Shows It" ⌥⌘1, "Reference (BT.1886)" ⌥⌘2, "Bypass — No Color Management" ⌥⌘3, "Show/Hide Transform Chain" ⌥⌘4, "Next Tag Override", "Reset Tags to Source", Fields ▸ … | Same state, different words | | `App/DisplayTransform.swift:205-226`, SC:347-359 |
| Grayed | for stills and audio-only files | | CV:3591, StillImageSurface.swift:19 |

##### 4.2 Hold to compare

| Item | What it does | Condition | Source |
|---|---|---|---|
| Hold C | While held, shows the other of macOS and Reference. From Bypass, shows macOS. A yellow badge "COMPARING: Reference" (or "macOS") appears, and the title gains " — COMPARING: …". | key window | SC:352, `App/HoldToCompare.swift:5-9`, DisplayTransformControl.swift:148-163, WindowDeck.swift:449 |
| Hold ⇧C | While held, shows Bypass | | SC:354 |
| Hold ⌥C | While held, takes the LUT off. This also affects the scopes and SDI. Does nothing when no LUT is applied. | LUT applied | SC:356, HoldToCompare.swift:11-13, 49-55 |
| Ends | on key-up, when the window loses key status, when the app loses focus, or when a menu opens | | HoldToCompare.swift:27-30 |

##### 4.3 Color interpretation control (`paintpalette`): colorimetry override and LUT

| Item | What it does | Condition | Source |
|---|---|---|---|
| Face (Full) | e.g. "709 709 · Declared" / "· Assumed" / "· Overridden" / "Override 9·1·6 · Overridden". A live stream shows its tier, or "— · Waiting for the stream". Appends " + LUT" (yellow) or a struck-through "LUT bypassed". The whole control turns yellow when overridden or a LUT is applied. | | LiveColorOverride.swift:319-326, 361-363, 706-725; InterpretationLUT.swift:161-169 |
| Face (Compact) | short, e.g. "709", "2020 PQ", with "●" when overridden | Compact layout | :727-749 |
| Face (Narrow) | icon only, "●" when overridden or a LUT is loaded | Narrow layout | :325 |
| Tooltip | "Color interpretation — Auto trusts the file’s tags; a preset or Override asserts them" (the stream version: "…trusts the stream…"), plus the cycle-presets key | | :312-315 |
| Reset to File’s Tags / Reset to Stream’s Tags | Back to Auto | not already Auto | :430-431 |
| Colorimetry presets | Auto, Rec.709 (SDR), Rec.2020 PQ (HDR10), Rec.2020 HLG, P3-D65 PQ, Rec.2020 SDR. Live streams get a per-transport subset. | | :433-440, `Colorimetry.swift:170-178` |
| Override ▸ Primaries / Transfer / Matrix | Custom triple. Values that cannot be combined are grayed with a reason, e.g. "PQ and HLG need Rec. 2020 or P3 D65 primaries". | | :615-640, Colorimetry.swift:346 |
| LUT section (header "LUT — name · shape → space" / "LUT bypassed — …") | "Load LUT…" (.cube only), "Recent LUTs" ▸ … / "Clear Menu", "Bypass LUT", "Remove LUT", "LUT Outputs" ▸ (Same as Source (no change) / the presets / Custom ▸ Primaries/Transfer/Matrix, plus two info rows), "LUT Interpolation" ▸ Tetrahedral / Trilinear, "LUT: <readout>" | | :485-549, InterpretationLUT.swift:97-101 |
| File / Stream status row | "Tagged <p> · <t> · <m>" / "Tags no colorimetry" / "Declares …" / "Declares no colorimetry" / "Has not stated its color yet" | | :443-445, 752-767 |
| Saved stream rows | "Save <x> to “<name>”", "Revert to Saved (…)", or "Not a saved stream: this override lasts for this connection only" | live sources that save overrides | :446-458 |
| Window title | " — Color 2020 PQ", " — LUT name.cube [(bypassed)]" | | WindowDeck.swift:431-439, InterpretationLUT.swift:161 |
| LUT load failure | banner "Couldn’t load “…”: <reason> Nothing was loaded. …" | | InterpretationLUT.swift:240-244 |
| Grayed | for stills ("Still") and audio-only files ("Audio") | | CV:3526-3532, LiveColorOverride.swift:244-248 |

##### 4.4 HDR/EDR as the user meets it
There is no HDR toggle. A user meets HDR and EDR through:
- the Headroom row and the HDR verdicts in the chain readout (§2.4);
- the calibration note "HDR is shown absolute (1.0 = 100 nits)" (DisplayTransformControl.swift:423);
- the PQ (nits) and HLG (%·nits) scope scales, chosen automatically from the transfer (WaveformScope.swift:333-348);
- the Inspector's HDR10 section;
- "Share Frame (SDR)…" for an HDR picture (ShareLabel.swift:18);
- the still line's "HDR (gain map)" etc. (StillImageInfo.swift:55-58).

##### 4.5 Fields (interlaced files)

| Item | What it does | Condition | Source |
|---|---|---|---|
| Fields menu next to Display: Weave ("both fields woven, as stored"), Field 1, Field 2, Deinterlace | Display only | interlaced and offered | `App/FieldViewControl.swift:29-63`, `Packages/ManifoldCore/Sources/FileScan/FieldView.swift:71-85` |
| Badge "FIELD 1 · DISPLAY ONLY", top-right marker "FIELD 1", title suffix "Field 1 (display only)" | Reminds the user that a field view is on | non-Weave | FieldView.swift:101-105, CV:1264, FieldViewControl.swift:69-95 |
| Tooltip | "Fields: … Scopes, SDI and export read the woven frame." | | FieldViewControl.swift:61-63 |

---

#### 5. Framing guides, overlays, banners, messages

##### 5.1 Framing Guides popover (title "Framing Guides")
These settings are app-wide (`@AppStorage`) (`App/FramingGuide.swift:152-163`).

| Item | What it does | Source |
|---|---|---|
| Broadcast safe zones (toggle) + Action % / Title % | Draws the action-safe and title-safe boxes | FramingGuide.swift:168-177 |
| Frame guide: None | No crop guide | :180-181 |
| Aspect: 1.33, 1.66, 1.77, 1.85, 2.0, 2.35, 2.39, 2.40 | Darkens the area outside a crop at that ratio and draws a line around it | :9-10 (array), :183-188 |
| Custom W × H | A user ratio | :189-206 |
| Social: 9:16, 1:1, 4:5, 2:3, 3:2 | Social-media ratios | :14-15, :208-213 |
| Social safe zones (toggle), "Platform preset" (TikTok, Reels, Shorts, Custom / Manual), Top / Bot sliders | Two horizontal safe lines | :18-21, :216-232 |
| Colors, widths, opacity | Settings ▸ Scopes & Guides: "Broadcast safe zone color", "Outside (darken) color", "Guide line color" | SettingsView.swift:604-620 |
| Opened from | the guides button (Full layout) or More ▸ Framing Guides… | CV:3430-3456, CV:3306 |

##### 5.2 Overlays on the picture

| Item | What it shows | Condition | Source |
|---|---|---|---|
| File name capsule | file name, top center | toggled by N ("Show/Hide File Name") | CV:1333-1346, SC:316 |
| Raster readout | e.g. "100% — 1920×1080", "Fit — 63% — …", "Custom — …", "… (screen limit)" / "(window minimum)". Shows for 1.6 s. | on raster change or live resize; not for audio-only files | CV:1130-1175, CV:1203-1210, RasterSize.swift:155-194 |
| Subtitles | SRT cues | loaded and shown | CV:1256-1261 |
| Field-view marker | top-right | field view on | CV:1264 |
| Audio-only card | waveform icon, file name, format, channels, sample rate, duration | audio-only file | CV:1266-1270, `App/AudioOnlyCard.swift:24-90` |
| Drop highlight | white outline while a file is dragged over the window | drag | CV:1373-1382 |
| Timecode entry / clamp notice | see 1.2 | | CV:3807-3813 |

##### 5.3 Banners (top center, stacked)
Stacking order is from CV:1395-1403.

| Banner | Text (examples) | Dismiss | Source |
|---|---|---|---|
| Another window owns a device (`lock.display`) | "<DeckLink/stream> is running in “<file>”. Turn it off there to play here." | Stays until resolved | CV:2689-2706, WindowDeck.swift:1552-1559 |
| Connection / playback notice (orange) | Stream errors. Also: "This file’s color is 4:2:2, but Manifold is showing it at 4:2:0 (…). The picture, scopes, SDI output and frame export carry 4:2:0 color resolution.", "This file’s 8-bit color could not be decoded exactly…", "This file’s audio track couldn’t be read — playing video only.", "Audio stream #N (…) couldn’t be decoded — still monitoring stream #M.", LUT refusals, saved-stream save errors | × button, or after 9 s | CV:2805-2846, `FrameEngine.swift:2611,3361-3371,5616`, InterpretationLUT.swift:241, LiveColorOverride.swift:189 |
| DeckLink start refused (orange) | the refusal reason | × | CV:2714-2742 |
| SDI sound stopped (`speaker.slash.fill`) | the reason | × | CV:2745-2774 |
| Dolby Vision (orange) | "Dolby Vision Profile N: this file has no compatible base layer, so Manifold can't display it correctly." | × ("Close Dolby Vision warning") | CV:2777-2802, `ColorimetryModel/DolbyVision.swift:41` |

##### 5.4 Other "no source" and status messages
- The scope headers read "no source" (`ScopeColorFeed.swift:150-153`).
- The meters read "NO SOURCE" (`AudioMeterScope.swift:594`).
- The chain readout reads "no source" (`DisplayChainModel.swift:215`).
- A still with no CICP gets a header note such as "Untagged: read as Rec. 709" (`docs/STILLS_AND_AUDIO_ONLY_PLAN.md` §3.5). The exact code string is UNKNOWN: not located.
- The DeckLink menu shows "Still images aren’t sent to SDI or HDMI. Output is black." and "Audio-only files aren’t sent to SDI or HDMI with the card lock off. Output is black." (`WindowDeck.swift:1340,1350`).
- A sync/offset readout exists only for live streams: the A/V badge (§1.3) and the title suffix " — A/V +80 ms" (`WindowDeck.swift:440-442`).

---

#### 6. Window behaviors

| Item | What it does | Condition | Source |
|---|---|---|---|
| Multiple windows | Each window is a separate "deck" with its own file, tray, slots, display transform and LUT. Only one window plays at a time. Other windows gray their transport, and the tooltip says "The transport is in another window — click there, or here to take it over." or "Click this window to make it the active deck." | | CV:2862-2864, WindowDeck.swift:1414-1452 |
| Device ownership | DeckLink output and a live stream belong to one window. Other windows gray those controls and show the lock banner. | | WindowDeck.swift:1415-1416, CV:2689 |
| Opening into empty windows | Opening a file from Finder reuses an existing empty window when there is one | | CV:686-697 |
| Window title | file name or stream label, plus suffixes: " — Color …", " — LUT …", " — A/V …", " — Field 1 (display only)", " — COMPARING: …", " — Bypass". A stream URL is never shown. | | WindowDeck.swift:399-450 |
| Window sizing | The video keeps its aspect ratio. The scopes tray and the docked bar add height below the picture without shrinking it. Dragging the window scales only the video. A window never exceeds the screen; the video shrinks instead. | | `App/WindowSizer.swift:28-37` |
| Raster sizes | View menu: 100% ⌘1, 75% ⌘2, 50% ⌘3, 25% ⌘4, Fit to Screen ⌘0. A manual resize becomes "Custom". A Settings default ("Raster size for new windows") adds "Automatic (fit on open)". | Grayed for audio-only files (16:9 card) | RasterSize.swift:101-118, 332-337; SC:310-314; CV:739-742; SettingsView.swift:333; STILLS plan §5.2 |
| Full screen | ⌘F, "Enter or Exit Full Screen" (system View menu). Sizing constraints are off in full screen. In full screen there is no Bypass, A/V or color marker in the title. | | SC:329, WindowSizer.swift:363,466, WindowDeck.swift:406-407 |
| Drag and drop | Drop a movie, image or audio file to load it into that window. A ".manifoldsettings" file opens a settings-import preview instead. | | CV:1197-1200, CV:1359-1370 |
| File types (Finder) | Movie (public.movie, public.video, QuickTime, MPEG-4, org.smpte.mxf), Audio (public.audio, WAV, AIFF, MP3, M4A, AAC), Image (public.image), all Viewer/Alternate. "Manifold Settings" (.manifoldsettings) Editor/Owner. Which movies actually play is decided at load (e.g. .r3d is refused). | | `project.yml:366-447` |
| Stills | Whatever ImageIO reads opens: PNG, JPEG, TIFF, HEIC, AVIF, EXR, RAW and others. DPX does not. No scrubber, play, loop, audio track or captions; Export and Share are grayed; color controls are grayed; scopes show the file; SDI sends black. | | STILLS plan §3.2-3.5, §4.1-4.2; CV:2954-2995 |
| Audio-only | Shows the card. Normal scrubber, play, loop, mute and audio track. Frames readout and frame step are off. Color controls are grayed. Video scopes blank; Audio Meters works. | | STILLS plan §5.2; CV:1752-1753, CV:3859-3875, CV:3526 |
| Subtitle sidecar | .srt only, loaded per clip from the clip's folder | video files only | CV:2451-2461 |

---

---

### 5D. Output, streams, markers, export, licensing, diagnostics

Repo: `/Users/robbiecarman/Code/Manifold/Manifold` at HEAD `cec4c30`. Read-only: nothing was built or launched.
All paths are relative to the repo. "Shortcut catalog" means `Packages/ManifoldCore/Sources/ShortcutRegistry/ShortcutCatalog.swift`.
Menu items built with `ShortcutMenuItem(id:)` take their label from the shortcut catalog, so both locations are cited.

**DEBUG-only items (not covered below):** the top-level **Debug** menu (`App/ManifoldApp.swift:356-387`, which also
needs `DebugMenuGate.isEnabled`); the Settings **Advanced** pane (`App/SettingsView.swift:27-29, 42-44`); the Settings
section "Debug (read-only; shown because the Debug menu is on)" (`App/SettingsView.swift:840-853`); the debug shortcuts
`debug.*` (shortcut catalog `:94-110, :382+`). The Profile configuration defines DEBUG, so testers on Profile builds can
reach these (`App/ManifoldApp.swift:363-366`).

---

#### 1. DeckLink SDI/HDMI output

##### 1a. Turning it on and choosing a device and mode

| Item | What it does (plain words) | Condition | Source (file:line) |
|---|---|---|---|
| File ▸ **Start/Stop DeckLink Output** (⇧⌘D) | Starts or stops sending the picture to the Blackmagic card. If another window owns the card, it beeps. | Window owns the devices | `App/ManifoldApp.swift:336-339`; shortcut catalog `:241` |
| Control bar **TV button** (`tv` / `tv.fill`) | The same start/stop. Turns green while output is on. Disabled if the driver is blocked or another window owns the card. | Always on the control bar | `App/ContentView.swift:2192-2216` |
| Tooltip "DeckLink output — click to start" / "DeckLink output ON — click to stop" | Tells you the state and the action | Hover | `App/ContentView.swift:2194-2195` |
| Chevron menu "DeckLink output options" | The device, audio, mode and signal menu (rows below) | Click the chevron next to the TV button | `App/ContentView.swift:2218-2323` |
| Section **Output device**: one checkmark row per card | Picks which card or port to use | Devices found | `App/ContentView.swift:2219-2234` |
| Row "Grayed: inactive in the card's current connector mapping" | Explains why a port is grayed out | A device is inactive | `App/ContentView.swift:2237-2239`; `Packages/ManifoldCore/Sources/DeckLinkRefusal/DeckLinkConnectorMapping.swift:55` |
| **Open Desktop Video Setup…** | Opens Blackmagic's setup app | Desktop Video Setup installed | `App/ContentView.swift:2241-2243`; `App/DeckLink/DesktopVideoSetup.swift:12` |
| Section **Audio**, picker "Audio destination": **SDI (follows video)** / **Computer** | Sends the sound to SDI with the picture, or to the Mac | Always | `App/ContentView.swift:2245-2251` |
| Section **Output mode**: **Follow source (<mode>)** plus a list of modes | Follow source picks a mode from the source's size and rate. Otherwise you pick a mode by hand. | Follow source is listed only when it is available | `App/ContentView.swift:2253-2271` |
| "Follow source — unavailable" plus a reason row | Says why Follow source can't be used: "No source is connected." / "This source does not report a frame rate, so the output mode cannot follow it. Pick a mode below." | Follow source unavailable | `App/ContentView.swift:2254-2256, 2268-2270`; `App/DeckLink/DeckLinkService.swift:1667, 1686-1688` |
| Mode labels, e.g. `720p`, `1080p`, `2K DCI p`, `2160p`, `4K DCI p`, `1080i` + rate | Names of the output rasters (8K is excluded) | — | `Packages/ManifoldCore/Sources/ColorimetryModel/SDIOutputMode.swift:89-96, 186` |
| Settings ▸ **DeckLink Output** ▸ Device: "DeckLink" status, **Download Desktop Video…** / **Update Desktop Video…**, device list, **Open Desktop Video Setup…** | Shows the driver state and links to Blackmagic support | Driver missing or too old | `App/SettingsView.swift:654-693`; URL `App/DeckLink/DeckLinkService.swift:72` |
| Settings ▸ Output: **Enable output on launch** | Starts output at launch if a capable card is connected | Default off | `App/SettingsView.swift:696-697`; `App/DeckLink/DeckLinkService.swift:77` |
| Settings ▸ Output: **Audio at launch** (SDI (follows video) / Computer) | Where sound goes when the app starts. Caption: "Audio-only files play on the Mac until a later update." | — | `App/SettingsView.swift:698-702`; `SDIOutputMode.swift:78` |
| Settings ▸ Output: **SDI scaling**: **Fit to mode** / **1:1 pixels** | How Follow source chooses a mode, and whether the picture is scaled to fill it. Each choice has its own caption. | — | `App/SettingsView.swift:703-709`; `SDIOutputMode.swift:58` |
| Settings ▸ Output: **SDI output modes**: **HD/UHD only** / **Include DCI** | Include DCI adds 2048×1080 and 4096×2160 | — | `App/SettingsView.swift:710-714`; `SDIOutputMode.swift:44` |
| Tooltip suffix "Audio: SDI (this session)" / "Audio: Computer (this session)" | Shows that this session's audio choice differs from the launch preference | Session differs from the preference | `SDIOutputMode.swift:84-86`; `App/ContentView.swift:2199-2200` |

##### 1b. Signal options and readouts

| Item | What it does | Condition | Source |
|---|---|---|---|
| Section **Signal**, first row: `<mode> · 10-bit 4:2:2 · <colorspace> · <SDR/PQ/HLG>` | Describes the signal being sent. The format is always 10-bit 4:2:2 (v210): chroma is reduced to 4:2:2 only at this output. | Always | `App/ContentView.swift:2296`; `App/DeckLink/DeckLinkService.swift:82, 177, 202`; EOTF names `Packages/ManifoldCore/Sources/ColorimetryModel/OutputSignal.swift:29-40` |
| Colorspace part, e.g. "Rec. 709" or "<name> (converted from <name>)" | Says when P3 is converted to Rec.2020 for SDI | — | `DeckLinkService.swift:165`; `OutputSignal.swift:249-251` |
| Placement row "SDI <w>×<h><rate> · <summary>" | Shows how the picture sits in the output raster when it isn't native | Not native | `DeckLinkService.swift:185-188`; `App/ContentView.swift:2299-2301` |
| Row "HDMI: mastering <gamut> · <max> / <min> cd/m² … · MaxCLL n · MaxFALL n" | **HDR signalling**: the static HDR metadata sent. Adds "(defaults)" or "(0 = unknown)" when values are missing. There is no user control: it follows the picture. | HDR picture with static metadata | `App/ContentView.swift:2304-2306`; `OutputSignal.swift:254-271`; `DeckLinkService.swift:1585` |
| "⚠️ <advisory>" | Warnings about the source, e.g. interlace field order, or "source rate X fps has no output mode — nearest is …: SDI repeats or drops frames" | Source mismatch | `App/ContentView.swift:2312-2314`; `DeckLinkService.swift:875-920` |
| Raster mismatch line, "source WxH cannot be placed in output WxH — no picture" | The card is locked but sending black | Source too large for the mode | `App/MetalVideoRenderer.swift:5985`; `DeckLinkService.swift:202` |
| Held reasons: "Still images aren't sent to SDI or HDMI. Output is black." / "Audio-only file: SDI and HDMI show its card, with its sound." / "Audio-only files aren't sent to SDI or HDMI with the card lock off. Output is black." | What SDI shows for stills and audio-only files | Still or audio-only file | `App/WindowDeck.swift:1340, 1346, 1350` |
| Section **Unavailable**: blocked reason | Driver problems (1c) | Driver blocked | `App/ContentView.swift:2317-2321` |
| Section **Output off**: "⚠️ <refusal>" | Why the last start failed | Start refused | `App/ContentView.swift:2322-2326` |

##### 1c. Errors and banners

| Item | What it does | Condition | Source |
|---|---|---|---|
| Orange banner with the start refusal (closable) | Shows the refusal on the picture | Start refused, output off | `App/ContentView.swift:2709-2730` |
| "DeckLink output is in use by another application (for example DaVinci Resolve). Start output again when it is free." | The card is busy | EnableVideoOutput busy | `Packages/ManifoldCore/Sources/DeckLinkRefusal/DeckLinkRefusal.swift:19-20` |
| "<device> is inactive in the card's current connector mapping. Choose an active device, or change the mapping in Desktop Video Setup, then start output again." | Start refused: the port is inactive | — | `DeckLinkConnectorMapping.swift:58-60`; `DeckLinkService.swift:1137` |
| "DeckLink output stopped: <device> became inactive when …" / "DeckLink output stopped: the card's connector mapping changed … Start output again." | Output stopped because of a mapping change | Mapping changed | `DeckLinkConnectorMapping.swift:63-69` |
| Banner "SDI sound stopped; restart output" (speaker-slash icon, closable) | SDI audio stalled | Audio callback stalled | `DeckLinkService.swift:479, 1402`; `App/ContentView.swift:2736-2760` |
| Driver headlines: "Desktop Video not installed", "Desktop Video installed (version unknown)", "Desktop Video <v> — too old", "No device detected (Desktop Video <v>)" | Driver state in the Settings and menu | — | `DeckLinkService.swift:260-267` |
| Driver details: "Install Blackmagic Desktop Video <floor> or later, then relaunch Manifold." … "Connect a DeckLink or UltraStudio device." … "please send a diagnostics report …" | What to do about the driver | — | `DeckLinkService.swift:281-308` |
| Tooltip blocked reasons "DeckLink output — requires Blackmagic Desktop Video … (not installed)" etc. | The TV button's tooltip when it is disabled | — | `DeckLinkService.swift:318-327` |
| Arbitration banner "<device> is running in "<window>". Turn it off there to play here." | A second window can't use the card | Another window owns the card | `App/WindowDeck.swift:1550-1558`; `App/ContentView.swift:2690-2705` |

---

#### 2. Live streams (SRT, WHEP "Web Stream", HLS, NDI)

##### 2a. How a user opens a stream

| Item | What it does | Condition | Source |
|---|---|---|---|
| Empty window: **Open a file — or connect a stream**, pill **Connect Stream…** ▸ **NDI** submenu + stream items | First-run route to a stream | Empty window | `App/ContentView.swift:3620-3644` |
| Control bar **antenna button** | Click: connects the first NDI source, or disconnects NDI. Green while live. | — | `App/ContentView.swift:2347-2357, toggleStreaming` |
| Antenna tooltips: "Streaming — local mode; click to connect the first NDI source, or use the menu to pick" / "Streaming — <name> — click to stop" / "Streaming is in another window" | State and action | Hover | `App/ContentView.swift:2365-2369` |
| Chevron "Streaming sources" ▸ **NDI** submenu | Lists NDI sources found on the network. A checkmark marks the connected one. | — | `App/ContentView.swift:2471-2550` |
| NDI row "Searching for NDI sources…" (disabled) | Discovery is running and nothing has been found yet | No sources | `App/ContentView.swift:2526` |
| NDI row "NDI runtime not installed — install it in Settings (⌘,) and relaunch." | The NDI runtime is missing | Runtime absent | `App/ContentView.swift:2520` |
| **Stream URL…** (no saved streams) / Section **Streams** with one row per saved stream + **Manage…** | Opens the Stream Sources sheet, or connects a saved stream | — | `App/ContentView.swift:2588-2601` |
| **Disconnect** (stop icon) in the streaming menu | Disconnects the live source | A source is live | `App/ContentView.swift:2478-2484` |
| File ▸ **Disconnect Live Source** (⌥⌘⌫) | Same | Window owns the devices | `App/ManifoldApp.swift:338`; shortcut catalog `:239` |
| URL type detection: `srt://` → SRT, a path containing `.m3u8` → HLS, otherwise https → Web Stream (WHEP) | Picks the transport from the URL | — | `Packages/ManifoldCore/Sources/StreamBookmarkModel/StreamBookmark.swift:25-29` |
| Type labels "Web Stream", "SRT", "HLS" (deliberately never "WHEP") | Row labels in the sheet | — | `StreamBookmark.swift:32-39` |

##### 2b. Stream Sources sheet (`App/StreamBookmarksSheet.swift`)

| Item | What it does | Condition | Source |
|---|---|---|---|
| Title **Stream Sources**, **Done** | The sheet. Done closes it. | — | `:87-89` |
| Section **Saved**: rows with **Connect**, edit ("Edit this stream"), delete ("Delete this stream") | Manages saved streams | — | `:147, 207, 213, 216` |
| "No saved streams. Add one below." | Empty list | — | `:172` |
| Delete alert "Delete "<name>"?" / "Its saved URL and passphrase will be removed from this Mac. This can't be undone." **Delete** / **Cancel** (Return = Cancel) | Confirms a delete | — | `:115-123`; `StreamBookmark.swift:182-185` |
| "A saved stream couldn't be read" + detail | Keychain read fault | — | `:150` |
| "Your saved streams couldn't be read" + "They're still saved and haven't been changed — … Saving is disabled until a version that can read them runs." | Saved list written by a newer build | — | `:160-167` |
| Composer header **Add a stream** / **Edit stream**; fields "Name (optional — defaults to the host)", "Stream URL (https://… or srt://…)" / "Stream URL — leave blank to keep the saved one" | Adds or edits a stream | — | `:241-243, 291` |
| "Saved: <host>", **Show saved URL** ("Read this stream's URL from your keychain into the field …") | Edit mode: shows the saved host and can load the full URL | Editing | `:360-364` |
| **Audio offset** field. Hint: "Positive = sound later, negative = earlier (−250 to +500 ms)." / "Not for HLS — Apple's player owns the audio." | Per-stream A/V offset | — | `:414-430`; range `Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift:5381-5384`, `StreamBookmark.swift` (−250…+500 comment) |
| Passphrase "Passphrase (optional)" / "Passphrase (unchanged — type to replace)", hold-to-show eye ("Hold to show the passphrase"), **Remove stored passphrase**, "Stored passphrase will be removed when you save." **Undo** | SRT passphrase, kept in the Keychain | SRT URL | `:460-529` |
| "This is no longer an SRT address, so its stored passphrase will be removed when you save." | Warns when an SRT entry is edited into another scheme | — | `:254` |
| **Save** / **Save Changes**, **Cancel**; "Enter a stream URL to save"; drafting notes ("Streams aren't saved until you press Save…", "Unsaved — Done will discard this draft.") | Saving behavior | — | `:267-331` |
| **Connect without saving**: "Paste a URL to connect once", **Paste & Connect**, "Connects this URL for the current session only — it is not saved and won't appear here after you quit." | One-off connect | — | `:619-631` |
| Validation errors: "Enter a stream URL." / "That doesn't look like a URL." / "Unsupported URL scheme "x". Use https://, srt://, or an .m3u8 link." / keychain errors / "Enter the audio offset as a whole number of milliseconds, e.g. 80 or −40." / "The audio offset must be −250 to +500 ms." / store-unreadable text | Shown under the form | — | `App/Preferences.swift:321-353` |
| SRT URL errors: "That isn't an SRT stream URL." / "That SRT address has no host." / "An SRT address needs a port — srt://host:port." / "Listener mode isn't supported yet — Manifold connects to a sender, not the reverse." / "This build dials SRT as a caller; it can't use mode "x"." / latency 20–8000 ms / stream ID too long / "That stream passphrase isn't the right length; SRT requires 10 to 79 characters." | Parse errors | — | `App/SRT/SRTClient.swift:300, 326-355` |

##### 2c. Connection states and messages (orange banner, auto-hides after 9 s, closable)

All transports share one banner (`App/ContentView.swift:2806-2845`, 9 s at `:2840`). NDI publishes no error, so its
failures are log-only (`App/Live/LiveSource.swift:176`).

| Transport | Messages a user may see | Source |
|---|---|---|
| SRT, connecting | "Couldn't start the SRT transport." / "Couldn't find <host>." / "Couldn't open an SRT socket." / "Nothing answered at host:port — SRT is UDP, so a listener that isn't running looks exactly like a blocked port. (<libsrt text>)" / "The stream refused the connection: <libsrt reject reason>. (<libsrt text>)" / raw libsrt error | `App/SRT/SRTSession.m:592-740` |
| SRT, connected | "Connected, but the sender hasn't sent anything yet." / "Connected — still identifying the stream." / "Connected, but no video is arriving from the sender." / "Connected, but still waiting for a keyframe from the sender." | `App/SRT/SRTClient.swift:1108-1125` |
| SRT, content | "That stream is <codec> — Manifold's SRT support is H.264 and HEVC only." / "That stream carries no video." / "This build can't read MPEG-TS." / "This stream reorders its pictures by up to N ms, more than Manifold's largest buffer (N ms) can cover…" / "Ignoring URL parameter(s) this build doesn't use: <names>." / chroma/color fallback banners | `SRTClient.swift:514, 825-826, 1162-1165`; `SRTSession.m:792, 885`; `App/SRT/SRTFrameRouter.swift:1202, 1214, 2619` |
| SRT, ending | "The connection to the stream was lost." / "The stream ended." / "The stream stopped unexpectedly." / "The stream stopped sending video (the broadcaster may have ended it)." | `SRTSession.m:976-984`; `SRTClient.swift:1095` |
| Web Stream (WHEP) | "A web stream is already connected — disconnect it before connecting another." / "That isn't a web stream URL." / "Couldn't start the connection." / "Couldn't reach <host>." / "The stream server gave an unexpected response." / **the server's own message body**, else "The stream server refused the connection (HTTP n)." / "The stream server's response wasn't a valid stream." / "Couldn't negotiate the stream with the server." / "Couldn't find a network route to the stream (it may be behind a firewall)." / "The connection to the stream failed." / "The stream stopped sending video (the broadcaster may have ended it)." | `App/WebRTC/WHEPClient.swift:164-712` |
| HLS | "That stream could not be played — <AVFoundation reason>" / "That stream is not playing yet — it connected, but no video has started after N seconds. Still trying." | `App/HLS/HLSClient.swift:1104-1105, 1551-1552` |
| NDI | No banner. State shows only as the checkmark in the NDI submenu and the green antenna. | `App/ContentView.swift:2541-2547`; `LiveSource.swift:176` |
| Any live source | "<name> is a live stream — there is no playback position to move to." | `App/WindowDeck.swift:1436` |

##### 2d. Audio offset and sync calibration

| Item | What it does | Condition | Source |
|---|---|---|---|
| Control-bar **A/V** menu (waveform icon), badge "A/V +N ms" when non-zero | The live audio offset | Live source | `App/Live/LiveAudioOffset.swift:200-260` |
| Items "Sound later +1 ms ⌥]", "Sound earlier −1 ms ⌥[", "Sound later +10 ms ⇧⌥]", "Sound earlier −10 ms ⇧⌥[", **Reset to 0 ms** | Nudges the offset | — | `LiveAudioOffset.swift:266-271`; shortcut catalog `:362-369` |
| "Save <offset> to "<name>"", "Revert to Saved (<offset>)" / "Not a saved stream: this offset lasts for this connection only" | Stores the offset in the bookmark | Saved stream / one-off | `LiveAudioOffset.swift:274-281` |
| **Calibrate…**, **Save Sync Clip…**, **Download ProRes Sync Clips…** | Calibration entry points | — | `LiveAudioOffset.swift:289-293` |
| HLS: "A/V offset — not on HLS"; "No audio offset on HLS — Apple's player owns the audio." | Offset unavailable on HLS | HLS | `LiveAudioOffset.swift:47, 213` |
| Offset notices: "Can move sound earlier by at most N ms on this stream right now…" / "Can't move sound any earlier on this stream right now — it arrives too close to when it plays…" / "Couldn't change the audio offset on this stream right now." | Limits on how far sound can move earlier | — | `LiveAudioOffset.swift:93-110, 172-184` |
| Sheet **Calibrate A/V**: "Play a Manifold sync clip through your encoder at the stream's frame rate, then press Start…"; states "Not listening." / "Listening…" / "Pairs found: n of 10" / "Waiting for the clip's flashes and beeps." / "The pairs disagree by more than a frame: still listening." / "Waiting for the figure to hold within ±2 ms over five pairs." | Measures A/V offset from a sync clip | Live, not HLS | `App/Live/CalibrationMode.swift:395-488` |
| Results: "Sound is in sync with the picture." / "Sound is heard N ms late/early." / "Nothing to change." / "Not applicable: moving sound N ms earlier needs more of the stream buffered than it has…" / "Applied N ms" + "Start again to check: it should read close to 0 ms." | What calibration found | — | `CalibrationMode.swift:447-518` |
| Buttons **Start**, **Stop**, **Measure Again**, **Apply for Session**, **Apply and Save**, **Cancel**, **Close**, **Get Sync Clip…**, link "Download the sync clips (releases.graviton.tools)" | Calibration controls | — | `CalibrationMode.swift:543-594` |
| "NDI: a result applies to this session only." / "Not a saved stream: a result applies to this connection only." | Scope of the result | — | `CalibrationMode.swift:428-429` |
| Save Sync Clip panel ("Save Sync Clip", "Play it through your encoder, then calibrate while connected.", clip popup) | Saves a bundled clip to disk | Clips bundled | `CalibrationMode.swift:94-120` |
| Alert "Sync clips aren't included in this build." **Download Sync Clips…** / **Cancel** | Offered when no clips are bundled | — | `CalibrationMode.swift:50, 83-92` |
| Help ▸ **Download Sync Clips…** | Opens the zip download in the browser | Always | `App/ManifoldApp.swift:294`; URL `CalibrationMode.swift:40` |

##### 2e. Local network prompt and NDI runtime install

| Item | What it does | Condition | Source |
|---|---|---|---|
| macOS prompt text: "Manifold uses your local network to find NDI video sources to play." | System Local Network permission | First NDI discovery. Discovery starts when the NDI list is opened (`App/ContentView.swift:3655`). | `project.yml:365`; `App/Info.generated.plist:81-82` |
| Manifold menu ▸ **Install NDI Runtime…** / **NDI Downloads Page…** | Downloads Vizrt's .pkg / opens ndi.video/tools | Only when the runtime is known to be missing | `App/ManifoldApp.swift:251-258`; URLs `App/NDI/NDIService.swift:112, 116` |
| Settings ▸ **Sources** ▸ NDI: "NDI Runtime: Installed (v) / Not installed", **Install/Reinstall NDI Runtime…**, link "NDI downloads page", "After installing the NDI runtime, relaunch Manifold to enable NDI sources." | Same, always reachable | — | `App/SettingsView.swift:730-756` |
| No install *alert* exists. The prompt is the menu items and rows above. | — | — | `App/ManifoldApp.swift:251`; no NSAlert in `App/NDI/` (grep) |

---

#### 3. Markers and file markers

Shipped at HEAD: user markers, the Markers window, the Markers scope slot, file markers (embedded chapters plus
Premiere XMP Chapter/Comment markers), EDL import, and export to six formats. **Planned, not shipped:** Final Cut Pro and
Avid export (`docs/MARKER_EXPORT_PLAN.md:1-15`; the `Format` enum has no such case, `App/Markers/MarkerFileIO.swift:20-21`).

| Item | What it does | Condition | Source |
|---|---|---|---|
| Mark menu: **Add Marker** (M), **Add Marker and Edit…** (⌥M), **Edit Marker…** (⇧M), **Delete Marker** (no key) | Marks the frame on screen (even while playing). Edit opens the editor. Delete removes the marker at the playhead. | Files only | `App/Markers/MarkCommands.swift:14-17`; shortcut catalog `:274-281` |
| Mark ▸ **Previous Marker** / **Next Marker** (⇧↑ / ⇧↓) | Moves between markers | — | `MarkCommands.swift:19-20`; catalog `:286-287` |
| Mark ▸ **Mark In** (I), **Mark Out** (O), **Clear In and Out** (⌥X) | Sets In/Out. Shown as "IN"/"OUT" chips in the scope. | — | `MarkCommands.swift:22-24`; catalog `:288-290`; `App/Markers/MarkersScopeView.swift:44-45` |
| Mark ▸ **Convert All File Markers to Markers** | Copies the file's embedded markers into editable markers (one undo) | File has file markers | `MarkCommands.swift:26`; catalog `:295` |
| Mark ▸ **Show Marker List** (⌃⌘M) | Opens the **Markers** window | — | `MarkCommands.swift:28`; catalog `:285`; `App/ManifoldApp.swift:405-410` |
| View ▸ **Show Markers** / **Show File Markers** (toggles) | Hides or shows markers and file markers | — | `MarkCommands.swift:9-11, 33-51`; catalog `:322, 327` |
| Editor sheet **New Marker** / **Marker**: Time, Duration, End, Name, Notes, Keyword ("Separate keywords with commas"), Color; **Set Time and Duration from In and Out**; **Remove Marker**, **Cancel**, **Add** / **Done** | Edits a marker | — | `App/Markers/MarkerEditorSheet.swift:64-123` |
| Editor errors: "The marker would end after the file's last frame." / "This file has no frame rate to place a marker on." / "A marker is already at <tc>. One marker per frame." | — | — | `MarkerEditorSheet.swift:111, 217`; `App/Markers/MarkerModel.swift:519` |
| Colors (16): Blue, Cyan, Green, Yellow, Red, Pink, Purple, Fuchsia, Rose, Lavender, Sky, Mint, Lemon, Sand, Cocoa, Cream | Marker colors (Resolve's set) | — | `Packages/ManifoldCore/Sources/Markers/MarkerColor.swift:15-17` |
| **Markers** window: title "Markers — <file>", toolbar **Filter by Color**, **Regenerate Thumbnails**, **Import…**, **Export…**; "No player window." | List and editor for the key window's file | — | `App/Markers/MarkersWindow.swift:56-107` |
| Markers scope slot "MARKERS" with gear ("Thumbnails, text size, colors shown, start timecode"): Thumbnails, Regenerate Thumbnails, Text size, **Open Markers Editor**, **Import Markers…**, **Export Markers…**, Colors filter + **Show All**, **From File** chip ("Markers embedded in the file: chapters and comments"), Start timecode **Set**/**Reset** | Marker list in the scopes tray | — | `MarkersScopeView.swift:41-203, 585-597` |
| Scope empty states: "Markers are for video files." / "Reading markers…" / "Nothing in the filter chosen." / "No markers. Press M to mark the frame on screen." / "Markers are hidden. View ▸ Show Markers shows them again." | — | — | `MarkersScopeView.swift:232-251` |
| Row context menu: **Edit…**, **Go to Marker**, **Color** ▸, **Regenerate Thumbnail(s)**, **Delete Marker(s)**; for file markers: **Edit…**, **Go to Chapter/Comment**, **Convert to Marker**, **Convert All File Markers to Markers** | — | — | `MarkersScopeView.swift:349-376` |
| List columns: Out, Duration, Color, Name, Notes, Keywords; "no preview" thumbnail ("This frame could not be decoded. Regenerate Thumbnail tries again.") | — | — | `MarkersScopeView.swift:531-558` |
| File markers: kinds **Chapter** and **Comment**; alert "Markers from the file can't be edited in Manifold." **Convert to Marker** / **Cancel**, "Convert to a marker to edit it." | Read-only embedded markers | File has chapters or XMP markers | `Packages/ManifoldCore/Sources/Markers/ChapterMapping.swift:88-91`; `MarkerEditorSheet.swift:232-238`; `docs/CHAPTER_MARKERS_PLAN.md:3-5` |
| Storage: one JSON file per media file (by content fingerprint) in `~/Library/Application Support/com.graviton.manifold/Markers/` | Markers persist between sessions | "Remember markers between sessions" on | `Packages/ManifoldCore/Sources/Markers/MarkerStore.swift:5, 20-22` |
| Settings ▸ Files ▸ Markers: **Remember markers between sessions**, **Delete All Stored Markers…** (confirmation "Delete all stored markers?") | Controls persistence | — | `App/SettingsView.swift:450-460` |
| Settings ▸ Scopes & Guides: **Marker text size** (Small/Medium/Large) | Text size in the marker list | — | `App/SettingsView.swift:595-599`; `MarkerTextSize.swift:22-24` |
| Notices "Markers could not be saved." / "This file could not be read for markers." / "This file's saved markers could not be read. They are left as they are." (toast, 8 s) | — | — | `MarkerModel.swift:211, 217, 703, 707-714` |

##### 3a. Marker import (shipped: Resolve marker EDL only)

| Item | What it does | Condition | Source |
|---|---|---|---|
| File ▸ **Import Markers…**; panel "Choose a DaVinci Resolve marker EDL (Timeline ▸ Export ▸ Timeline Markers to EDL)." | Imports markers | File open | `App/ManifoldApp.swift:330`; `MarkerFileIO.swift:165-171` |
| Alert "No markers in that file." / "Manifold imports Resolve marker EDLs: each event followed by a line with "\|C:ResolveColor…"." | Not a marker EDL | — | `MarkerFileIO.swift:196-197` |
| Alert "N of M markers fall outside this file." … "(Frame.io assumes 01:00:00:00)." **Shift by ±HH:00:00:00** / **Import As Is** / **Cancel** | Offers an hour offset | Markers outside the file | `MarkerFileIO.swift:203-212` |
| Result: "Imported N markers." plus skipped, outside, unknown color ("… are Blue."), drop-frame mismatch and title mismatch lines | Import report | — | `MarkerFileIO.swift:225-243` |

##### 3b. Marker export (see section 4)

---

#### 4. Export

| Item | What it does | Condition | Source |
|---|---|---|---|
| File ▸ **Export Frame…** (⌥⌘E), also the control bar button | Saves the frame on screen as a **16-bit PNG**, color-tagged, native pixels (not desqueezed). No dialog: it goes to the export folder, named "<clip> <HH-MM-SS-FF>" or "<stream> <date time>", with " 2", " 3" added rather than replacing a file. | Window has a renderer | `App/ManifoldApp.swift:324`; catalog `:228`; `App/MetalVideoRenderer.swift:6408-6462, 6596-6605, 6691-6696, 6704-6706` |
| Settings ▸ Files ▸ Frame Export: Folder **Choose…** / **Use Desktop**; **Put exported frames in a folder per clip** | Where frames go (default Desktop) | — | `App/SettingsView.swift:429-444, 472` |
| Notice "Frame exported to the export folder, not to "<clip>": a file with that name is in the way." / "… the folder "<clip>" couldn't be created." | Per-clip folder fallback | — | `Packages/ManifoldCore/Sources/FrameShareFormat/FrameFileName.swift:186-193` |
| File ▸ **Share Frame…** / **Share Frame (SDR)…** (⇧⌘E) | Frame as a JPEG via the macOS share sheet. An HDR (PQ/HLG) picture is tone-mapped to SDR, and the file name ends " SDR". | — | `App/ManifoldApp.swift:327`; catalog `:233`; `Packages/ManifoldCore/Sources/FrameShareFormat/ShareLabel.swift:17-23`; `App/FrameShare.swift:115` |
| Help ▸ **Export Frame for Support…** | Save panel "Export Frame for Support" — "Includes the current frame's picture. Share only with people allowed to see this footage." Writes the PNG plus measurement files (.v210 dump etc.) | — | `App/ManifoldApp.swift:302`; catalog `:375-379`; `App/MetalVideoRenderer.swift:6501-6527, 6708-6711` |
| File ▸ **Export Markers…** (also scope gear and Markers window) | Save panel "Export Markers", prompt **Export**, accessory "Format:" | Markers exist, else "No markers to export." | `App/ManifoldApp.swift:331`; `MarkerFileIO.swift:48-80` |
| Formats: **DaVinci Resolve Marker EDL (.edl)**, **CSV (.csv)**, **Plain Text (.txt)**, **Premiere Pro (XML)**, **Chapter List — ffmpeg (.ffmeta)**, **Chapter List — YouTube (.txt)** | Shipped export formats | — | `MarkerFileIO.swift:20-31` |
| Options: **Add keywords to notes** (EDL only), **Add keywords to comments** (Premiere only); Premiere note "The file contains the media's full path. Markers arrive in Premiere as Comment markers." | Keyword handling | Format-dependent | `MarkerFileIO.swift:260-300` |
| Export results and refusals: "Exported N markers to a Resolve EDL." (+ notes on multi-line, blank lines, keywords, "\|"→"/") / "…to CSV." / "…to text." / "Premiere Pro XML can't state this file's frame rate (x fps). Nothing was written." / "A chapter list can't state this file's frame rate…" / "The markers could not be written there." | — | — | `MarkerFileIO.swift:94-158` |
| Clip or video export | **Does not exist.** No AVAssetExportSession or AVAssetWriter in App or the package sources. | — | grep of `App/` and `Packages/ManifoldCore/Sources` (only a comment at `AudioChannelLayoutBridge.swift:315`) |
| Subtitles: **Load subtitles…** (.srt import for display, not export) | Listed for completeness | Video | `App/ContentView.swift:2384-2421` |

---

#### 5. Licensing

| Item | What it does | Condition | Source |
|---|---|---|---|
| Trial | 7 days from first launch. Setting the clock back by more than 5 minutes voids it. | No license | `App/LicenseManager.swift:47-48, 82-101` |
| Manifold menu ▸ **License…** | Opens Settings on the **License** pane | Always | `App/ManifoldApp.swift:223-226` |
| Settings ▸ License ▸ Status: "Checking…" / "Couldn't read the Keychain — status unknown" / "License locked" / "Licensed to <email or "you"> · Standard/Beta [· registration pending]" / "Trial — N days left" / "Trial expired" | License state | — | `LicenseManager.swift:864-900`; type names `:157-160` |
| Key field (placeholder "MNFL-…"), **Activate**, "Paste your whole key, including "MNFL-"." | Activation | Not licensed | `LicenseManager.swift:906-920` |
| **Deactivate on this machine** | Clears the local activation only. The machine ID is kept. | Activated | `LicenseManager.swift:860-862, 783-808` |
| Gate screen "Your Manifold trial has ended" / "Your Manifold license is locked", "Enter a license key to continue using Manifold.", key field, **Activate**, "Need a key? Visit graviton.tools" | Blocks the player window | Trial expired or locked | `LicenseManager.swift:927-976, 984-995`; applied `App/ManifoldApp.swift:179` |
| Success messages: "Activated. Welcome!" / "Activated. Manifold will finish registering this Mac the next time it can reach the license server." | Online / offline-pending activation | — | `LicenseManager.swift:493, 751` |
| Server and client refusals: "This license is no longer valid. Contact support@graviton.tools." / "This license has expired…" / "Couldn't read this computer's hardware ID…" / "This license is already active on N of M machines. Contact support@graviton.tools to free one." / "This license key was not recognized. Check it and try again." / "Could not reach the license server. Check your connection and try again." / "The license server rejected this request (<code>)." / "Activation failed (<code>). Contact support@graviton.tools." | — | — | `Packages/ManifoldCore/Sources/LicenseClient/LicenseKey.swift:14-43` |
| Local failures: "Activation failed. Quit and reopen Manifold, then try again." / Keychain save failures / "Your stored license key could not be verified. Please re-enter it, or contact support." | — | — | `LicenseManager.swift:660, 763-780` |
| Deactivate messages: "Deactivated on this machine. Note: the server still counts this machine until an admin deregisters it." / Keychain remove failures | — | — | `LicenseManager.swift:793, 801, 805` |
| Keychain fault notice "Your license couldn't be read" + "Manifold couldn't read your license from the Keychain (…). This does not mean your license is gone … send a diagnostics report (Help ▸ Export Diagnostics…) …" | A read fault is not treated as unlicensed | — | `LicenseManager.swift:557-562, 825-833` |
| Offline behavior | Validates at most every 7 days from the last success. Being unreachable changes nothing. Offline activation is "pending" and retried each launch. Only a revoked license (or a signed expiry checked offline) locks. A refused Keychain read fails open. | — | `Packages/ManifoldCore/Sources/LicenseClient/LicenseClient.swift:10-15, 106-110`; `LicenseManager.swift:545-551` |

---

#### 6. Diagnostics, settings transfer, About, updates

##### 6a. Export Diagnostics

| Item | What it does | Condition | Source |
|---|---|---|---|
| Help ▸ **Export Diagnostics…** | Opens the prompt sheet (presented from a player window) | Not gated | `App/ManifoldApp.swift:300`; `App/ContentView.swift:978-979` |
| Sheet **Export Diagnostics**: "This writes a plain text file you can send us. Three questions first…" | — | — | `App/DiagnosticsExport.swift:1063-1071` |
| **Connection** picker (Select… / Wired (ethernet) / Wi-Fi / Other / not sure). Export is disabled until it is set ("Choose a connection type to export"). | Required context | — | `DiagnosticsExport.swift:783-787, 1073-1079, 1118-1131` |
| "City or region" ("…we don't want anything more precise."), "What were you doing?" text box | Optional context | — | `DiagnosticsExport.swift:1081-1097` |
| **Include file names** (default off): "Helps when the problem is with a particular file. Folder names are never included." | Privacy option | — | `DiagnosticsExport.swift:802, 1099-1104` |
| Collection statement: "The file contains your build, machine and display details, and Manifold's log. Stream passphrases, stream IDs, the paths of stream URLs, IP addresses, folder paths, file names (unless you include them), display serial numbers and machine names are removed…" | What it collects and removes | — | `DiagnosticsExport.swift:1106-1115` |
| Save panel "Export Diagnostics", plain text, default name `Manifold-<version>-diagnostics-<timestamp>.txt`. The location is the user's choice; the panel's starting folder is not set (UNKNOWN: system default). | Where it saves | — | `DiagnosticsExport.swift:976-982, 1021-1026` |
| Alert "Couldn't save the diagnostics file." + system error | Write failure | — | `DiagnosticsExport.swift:1047-1051` |
| File footer "REDACTION" lists what was removed and the counts | — | — | `DiagnosticsExport.swift:958-973` |

##### 6b. Export / Import Settings

| Item | What it does | Condition | Source |
|---|---|---|---|
| Settings ▸ General ▸ Export and Import: **Export Settings…**, **Import Settings…**, Backups **Restore from Backup…** | "Moves your keyboard shortcuts and saved streams to another Mac." | — | `App/SettingsView.swift:353-365` |
| Export sheet: "Keyboard shortcuts (N customized)", "Saved streams (N)", password ≥ 12 characters + confirm; "This password can't be recovered…" | Streams are encrypted; a shortcuts-only file is plain | — | `App/SettingsTransferUI.swift:234-303`; `Packages/ManifoldCore/Sources/SettingsTransfer/SettingsEncryption.swift:25` |
| File `.manifoldsettings`, default "Manifold Settings <date>" | — | — | `SettingsFile.swift:19, 118-119`; `SettingsTransferUI.swift:44-46` |
| Import sheet: password, **Merge** / **Replace All**, conflict toggles, results ("N streams added.", "…check sync with A/V ▸ Calibrate…"), **Undo Import** / **Undo Restore**, "Can't Import This File" | — | — | `SettingsTransferUI.swift:120-122, 572-790` |

##### 6c. About and updates

| Item | What it does | Condition | Source |
|---|---|---|---|
| Manifold ▸ **About Manifold** | Window with name, "Version x (build n)", copyright, tabs **Credits** / **Licenses** (third-party attributions and license texts) | Not license-gated | `App/ManifoldApp.swift:207, 418-420`; `App/AboutWindow.swift:551-640` |
| Launch update check | Silent unless a newer version exists. Alert "Manifold <v> is available" (or "… (build n) is available"), "You have x (build n).", release notes ("▸ Show N more"), **Download** / **Not now** | At launch | `App/UpdateChecker.swift:1-15, 225-262, 410`; `App/ManifoldApp.swift:185` |
| Manifold ▸ **Check for Updates…** | The same check, but also says "Manifold is up to date" / "Couldn't check for updates" ("…couldn't reach the update server. Check your internet connection and try again.") | Menu | `App/ManifoldApp.swift:211`; `UpdateChecker.swift:268-285` |
| Download opens the browser to the release page. The app never downloads or installs anything itself. | — | — | `UpdateChecker.swift:1-6, 30` |
| Help menu: **Sync and Color Guide**, **Keyboard Shortcuts…** (also in the app menu) | Bundled guides | — | `App/ManifoldApp.swift:282-293`; `App/Help/HelpGuides.swift:33` |

---

---

## Verify in a build before shipping

Claims in the chapters that were read from code or the inventory but not seen in a running build. Check each in a signed
build on the LG before the manual ships; screenshots (D9) join this list when they are planned. Tick and date each.

- [ ] **05-sdi-and-hdmi-output.md, "What you need":** the DeckLink status line reads like "1 device (Desktop Video 16.4.0)"
      for one device (`App/DeckLink/DeckLinkService.swift:258-272`, `deviceCount`).
- [ ] **06-live-streams.md, "Connect an NDI source":** macOS's Local Network prompt offers **Allow**, and Don't Allow can be
      undone in System Settings ▸ Privacy & Security ▸ Local Network.
- [ ] **09-settings.md, "Move your shortcuts and saved streams":** dragging a .manifoldsettings file onto a Manifold window opens
      the import preview (`App/ContentView.swift:1359-1370`, per the inventory).
