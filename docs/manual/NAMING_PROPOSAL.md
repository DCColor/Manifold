# Naming and wording proposal (0.9.6)

**Status:** proposal only, 2026-11-27. Nothing in the app has been renamed. Source: `docs/BUGS.md`, *0.9.6 UI polish*,
section 3 (items 7–29), section 4's *State the user can't see* (30–37) and *Keys* (43–44), and item 45. Every location
below was re-read from the tree after batch 1 (`06e530e` plus the uncommitted batch 2), so line numbers differ from
BUGS.md's where batch 1 moved code.

**The rule this proposes.** One thing has one name, the one a user would say out loud. Where a longer form adds
information (a standard, a curve), it goes in the tooltip, the Settings caption or the manual, not in a second title.
Menu titles follow macOS (title case, "…" when more input follows); tooltips and captions use sentence case.

---

## Decisions I need from you (shortest first)

| # | Decision | My recommendation |
|---|---|---|
| D1 | Captions, Subtitles or Timed Text? (item 9) | **Subtitles** |
| D2 | "Web stream" or "WHEP stream"? (item 11, 49b) | **Web stream** on screen; "WHEP" only in Settings help and the manual |
| D3 | "Pin Controls" or "Always Show Controls"? (item 13) | **Always Show Controls** (menu), button tooltip says the same |
| D4 | "File markers" or "Chapters"? (item 10) | **Chapters**, because that's what the file and other apps call them |
| D5 | The time readouts: which labeling? (item 45) | **Option A** below: a small mode tag over the right-hand readout |
| D6 | Display modes: short names, or long names everywhere? (item 7) | **Short** (macOS / Reference / Bypass), with the detail as a second line in the menu |
| D7 | Should connection errors stay until closed, not hide after 9 s? (item 31) | **Errors stay until closed; notices (the "Saved" banner, playback notes) hide** |
| D8 | Vendor names in messages: keep them as examples or remove them? (item 29) | **Remove** from errors; keep where the name is the format (Resolve marker EDL) |
| D9 | Engineering words in the transform chain and Inspector: rewrite, or keep and explain? (items 19–21, 27) | **Keep them, add plain words first**: "Rec. 709 (CICP 1-1-1)" |
| D10 | Menu items that can't act: gray them out, or keep the beep? (item 32) | **Gray out** the File, View and Color items; keep the beep for keys with no menu item |
| D11 | Bare-letter keys beside ⌘ letters (I / ⌘I, O / ⌘O, L / ⌘L, M / ⌘M): change any? (item 43) | **Keep**: they're the editing-app convention (Mark In/Out, J/K/L); say so in the shortcuts chapter |

---

## Time readouts (item 45)

**Today.** Two readouts flank the scrubber. The left is the playhead (`leadingReadout`, `App/ContentView.swift:3880`;
shown at `:3060`); clicking it opens timecode entry (`:3082`, tooltip "Go to timecode — click, or type a number",
`:3094`). The right is the end or duration (`trailingReadout`, `:3908`; shown at `:3175`); clicking it cycles **both**
readouts through timecode, frame count and elapsed time (`cycleReadout`, `:3933`; `ReadoutMode`, `:12`). It has no
tooltip. Nothing says which mode is showing. A frame count ("1440") is recognizable, but elapsed time ("1:00:10") and a
timecode whose frame field is cut off cannot be told apart at a glance, and a file without timecode silently shows
elapsed time in timecode mode (`effectiveMode`, `:3922`).

**Option A (recommended).** A small tag above the right-hand readout, as an overlay so the docked bar's measured height
doesn't change (the same technique as the timecode-source glyph, `readoutSourceIndicator`, `:3896`):

```
 00:59:58:12  ━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━   TC
                                            01:00:10:00
```

Tags: **TC**, **FRAMES**, **TIME**. When a file has no timecode and the mode falls back, the tag reads **TIME**, so the
fallback is visible. Tooltip on the right-hand readout: "Timecode — click for frames" / "Frames — click for elapsed time" /
"Elapsed time — click for timecode".

**Option B.** The same tag over both readouts. Clearer when the controls are narrow, but doubles the clutter; both
readouts are always in the same mode, so one tag is enough.

**Option C.** Tooltip only. No visual change, but the problem the item describes (can't tell at a glance) remains.

---

## One thing, several names (items 7–18)

| # | Thing | Names today (where) | Proposed | Why |
|---|---|---|---|---|
| 7 | Display mode: macOS | "macOS" (control face, `App/DisplayTransformControl.swift:172`; `App/DisplayTransform.swift:94`); "As macOS Shows It" (Color menu, `App/DisplayTransform.swift:85`; `ShortcutCatalog.swift:347`; control row, `App/DisplayTransformControl.swift:191`) | **macOS** everywhere; menu second line "What your client sees" | The face can't fit the long form, so it's the one users see most. The second line already exists in the control (`:191`). (D6) |
| 7 | Display mode: Reference | "Reference" (face, `App/DisplayTransformControl.swift:172`); "Reference (BT.1886)" (menu, `App/DisplayTransform.swift:86`; `ShortcutCatalog.swift:348`) | **Reference**; "BT.1886" in the second line | The standard is detail, not a name. (D6) |
| 7 | Display mode: Bypass | "Bypass" (face, `App/DisplayTransformControl.swift:172`); "Bypass — No Color Management" (menu, `App/DisplayTransform.swift:87`; `ShortcutCatalog.swift:349`) | **Bypass**; "No color management" in the second line | As above. (D6) |
| 8 | Reset a tag override | "Reset to File’s Tags" / "Reset to Stream’s Tags" (color control, `App/Live/LiveColorOverride.swift:430`); "Reset Tags to Source" (Color menu, `ShortcutCatalog.swift:359`) | **Reset to File’s Tags** / **Reset to Stream’s Tags** in both, the menu title following the source | Says what you get back. "Source" is a code word here (source vs picture codes). |
| 8 | Step through overrides | "Next Tag Override" (Color menu only, `ShortcutCatalog.swift:358`) | **Next Tag Override**, unchanged; add it to the color control's menu or drop it from the Color menu | A command that exists in one place only looks like a different feature. Needs your call on which. |
| 8 | Two "color" controls | Menu bar **Color** menu = display modes (`App/DisplayTransform.swift:218-226`); control bar color control = interpretation (`App/Live/LiveColorOverride.swift`) | Keep the **Color** menu; call the control-bar control **Tags** in its tooltip and the manual | The control is about what the file's tags say. "Color" is taken by the menu. |
| 9 | Captions / subtitles | "Captions on — click to hide" (button tooltip, `App/ContentView.swift:2406`); "Subtitles", "Show Subtitles", "Load Subtitles…", "Clear Subtitles" (menu, `App/ContentView.swift:3345-3351`); "Timed Text" (Inspector header, `App/InspectorPanel.swift:183`) | **Subtitles** (button, menu); Inspector keeps "Timed Text" as the track type, as a row value, not the header | The menu uses Subtitles four times; the button once. The Inspector reports a track's technical kind, which is fine as data. (D1) |
| 10 | Markers window | "Show Marker List" (Mark menu, `ShortcutCatalog.swift:285`); "Open Markers Editor" (scope gear, `App/Markers/MarkersScopeView.swift:112`); "Markers" (window title, `App/ManifoldApp.swift:411`) | **Show Markers Window** (menu and gear) | Matches the window's title, and "Editor" and "List" describe one window two ways. |
| 10 | Markers from the file | "File Markers" (Convert…, `App/Markers/MarkersScopeView.swift:370-373`; `ShortcutCatalog.swift:295`; `App/Markers/MarkerModel.swift:371`); "Chapters" (Inspector, `App/InspectorPanel.swift:598`); "From File" (filter, `App/Markers/MarkersScopeView.swift:189, 203`) | **Chapters** everywhere: "Convert All Chapters to Markers", filter "Chapters" | The file calls them chapters, and so do QuickTime, YouTube and ffmpeg. "File Markers" sounds like markers saved in a file. (D4) |
| 11 | Web stream | "Web Stream" (stream list type, `Packages/ManifoldCore/Sources/StreamBookmarkModel/StreamBookmark.swift:35`); "WHEP stream" (tooltips and "… is running in …", `App/Live/LiveSource.swift:116`); "A web stream is already connected…" (`App/WebRTC/WHEPClient.swift:166`) | **Web stream** on screen; "Web stream (WHEP)" once, in the add-stream sheet | Users pick the type from the list, which says Web Stream. WHEP is the protocol name the server admin needs, not the viewer. (D2) |
| 12 | Sync clips link | "Download Sync Clips…" (Help, `App/ManifoldApp.swift:294`; calibration alert, `App/Live/CalibrationMode.swift:89`); "Download ProRes Sync Clips…" (A/V menu, `App/Live/LiveAudioOffset.swift:309`) | **Download Sync Clips…** | Same link; two of three already say this. ProRes is in the download page. |
| 13 | Keep the controls visible | "Pin controls" / "Unpin controls" (button tooltip, `App/ContentView.swift:3674`); "Always Show Controls" (View menu, `ShortcutCatalog.swift:318`); "Docked (fixed bar)" (Settings ▸ General ▸ Controls, `App/Preferences.swift:47`) | **Always Show Controls** (menu and tooltip); Settings: **Below the picture** | Pin and Always Show are one per-window toggle. Docked is a different thing (the bar moves below the picture); "Below the picture" says where. (D3) |
| 14 | Scopes tray | "Scopes tray" (button tooltip, `App/ContentView.swift:3635`); "Show/Hide Scopes" (View menu, `ShortcutCatalog.swift:334`) | **Show/Hide Scopes** (menu), tooltip **Show or hide scopes** | Tray is an internal word. |
| 14 | Scope names | Picker "Audio Meters" / "YRGB Parade" (`App/ContentView.swift:40, 37`); headers "METERS" (`App/AudioMeterScope.swift:516`) / "YRGB" (`App/YRGBScope.swift:233`) | Picker and header the same words: **Audio Meters** / **YRGB Parade**, header in caps if that's the style | The header is the picker's label (it opens the picker), so they should match. |
| 14 | Parade color reset | "Reset parade to RGB" (`App/ParadeScope.swift:281`); "Reset parades to color" (`App/YRGBScope.swift:260`) | **Reset parade colors** in both | One setting drives both (item 39). |
| 15 | Frame exports | "Export Frame…" (File, `ShortcutCatalog.swift:228`; More, `App/ContentView.swift:3360`; button, `:3599`); "Share Frame…" / "Share Frame (SDR)…" (`Packages/ManifoldCore/Sources/FrameShareFormat/ShareLabel.swift`); "Export Frame for Support…" (Help, `ShortcutCatalog.swift:379`; panel title, `App/MetalVideoRenderer.swift:6523`) | Keep all three; rename the support one **Export Frame and Measurements…** | Export and Share are distinct, and "(SDR)" is information. "for Support" says who, not what; the files are measurements. |
| 16 | Export Settings | "Export Settings…" moves shortcuts and saved streams only (`App/SettingsView.swift:356`) | **Export Shortcuts and Streams…** | Says what's in the file. Users will expect it to move the settings around it. |
| 17 | Refresh metadata | "Refresh metadata" (button, `App/ContentView.swift:3821`); "Refresh Metadata" (More, `:3340`); "This file changed on disk — click to reload" (tooltip, `:3819`) | **Reload File** (menu title case, tooltip sentence case); tooltip when changed: "This file changed on disk — click to reload it" | It reloads the file, not only its metadata, and "reload" is already the tooltip's word. Verify that claim in code before renaming. |
| 18 | How the color was found | Face: "Declared / Assumed / Overridden" (`App/Live/LiveColorOverride.swift:721`; `Packages/ManifoldCore/Sources/ColorimetryModel/Colorimetry.swift:290-291`); chain: "tagged / partly assumed" (`Colorimetry.swift:97-99`); status row: "Tagged …" (`App/Live/LiveColorOverride.swift:765`); "Override 9·1·6" (`Colorimetry.swift:193`) vs "Custom 9·1·6" for a LUT output (`App/Live/LiveColorOverride.swift:540`) | **Tagged / Assumed / Overridden**, plus **Partly assumed**; LUT output **LUT output 9·1·6** | Tagged is what the file has; Declared is the same thing in a second word. "Custom" for a LUT reads like an override. |

## Engineering words a user can see (items 19–27)

| # | Thing | Words today (where) | Proposed | Why |
|---|---|---|---|---|
| 19 | Transform chain: color codes | "— CICP 1-1-1" (`App/DisplayChainModel.swift:259`) | **Rec. 709 (CICP 1-1-1)** | Name first, code for those who want it. (D9) |
| 19 | Transform chain: macOS mode line | "As macOS shows it — source colorspace declared to the layer" (`App/DisplayChainModel.swift:267`; also `App/ReferencePlan.swift:140`) | **macOS color-manages the picture from its tags** | "Declared to the layer" is a Core Animation term. |
| 19 | Transform chain: PQ/HLG verdict | "…outside the rTRC (PQ/HLG)" (`App/DisplayChainModel.swift:328`) | **…PQ or HLG, which an ICC profile can't describe** | rTRC is an ICC tag name. |
| 19 | Chroma words | "x422", "v210 … (halfband)" (`Packages/ManifoldCore/Sources/ColorimetryModel/ChromaFormat.swift`, filter at `:182-195`) | **4:2:2**; SDI line **4:2:2 for SDI (filtered)** | Pixel-format codes; the chroma ratio is the user's word. |
| 19 | Headroom | "headroom 8.97 of 8.97" (`HeadroomReadout.swift:56`, per BUGS.md; not re-read) | **HDR headroom 8.97× (all of it)** | Unknown unit. UNKNOWN: line not re-verified in this pass. |
| 20 | Inspector | "nclc" (`App/InspectorPanel.swift:158`); "Full-swing (spec)" (`Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift:63`); "Clean Aperture" (`App/InspectorPanel.swift:87`); "MaxCLL" (`:457`) | **Color tags (nclc)**; **Full range (as the spec says)**; **Clean aperture**; keep MaxCLL / MaxFALL with a tooltip | The Inspector is the technical view; keep the terms, add the plain word where one exists. |
| 21 | DeckLink: inactive device | "Grayed: inactive in the card's current connector mapping" (`App/ContentView.swift:2240`; text from `DeckLinkConnectorMapping.inactiveNote`) | **Grayed out: not active in the card's current setup (Blackmagic Desktop Video Setup)** | "Connector mapping" is Blackmagic's term; say where to change it. |
| 21 | DeckLink: Follow source | "Follow source (…)" / "Follow source — unavailable" (`App/ContentView.swift:2275-2279`), defined only in Settings captions (`App/SettingsView.swift:711`) | **Match source (…)**, tooltip "Uses the output format closest to the source's size and frame rate" | Say what it does where it's chosen. |
| 21 | DeckLink: signal row | "10-bit 4:2:2" (`App/DeckLink/DeckLinkService.swift:82`); "(0 = unknown)" (`Packages/ManifoldCore/Sources/ColorimetryModel/OutputSignal.swift:268`) | Keep "10-bit 4:2:2"; **"not stated"** instead of "0 = unknown" | Say what a zero means. |
| 22 | SRT errors | "Nothing answered at … — SRT is UDP, so a listener that isn’t …" (`App/SRT/SRTSession.m:732`); "Connected, but still waiting for a keyframe…" (`App/SRT/SRTClient.swift:1109`) | Drop "SRT is UDP"; **"Connected, but waiting for the sender's first full picture"** | Protocol and codec terms the user can't act on. Keep "listener"/"caller" only where they match the add-stream sheet's mode names. |
| 23 | Errors with no next step | "Couldn’t start the connection." (`App/WebRTC/WHEPClient.swift:191`); "Couldn’t negotiate the stream with the server." (`:714`); "The connection to the stream failed." (`:318`); "Couldn’t save the diagnostics file." (`App/DiagnosticsExport.swift:1048`); "The markers could not be written there." (`App/Markers/MarkerFileIO.swift:158`); Keychain status in brackets (`App/LicenseManager.swift:564`) | Each gets a second sentence with a next step, e.g. "…Check the address, then connect again." / "…Choose another folder." The Keychain code moves to the log and Export Diagnostics | Item 23's complaint. The batch 2 frame-save messages (`FrameSaveFailure.message`) follow this pattern. |
| 24 | Scope headers | "*" for a forced scale (`App/WaveformScope.swift:359-364`); "gr … · box 75" (`App/VectorscopeScope.swift:468`); "Skintone axis (I)" (`:441`); "SAMPLE peak" (`App/AudioMeterScope.swift:884`) | "**(set)**" instead of "*"; "**graticule** … · **boxes 75%**"; "**Skin tone line**"; "sample peak" | Abbreviations and a symbol nobody is told about. |
| 25 | Settings labels | "Raster size for new windows" (`App/SettingsView.swift:336`); "Master scope intensity" (`:574`); "Graticule brightness" (`:584`); "IRE (0–100)" (`App/WaveformScope.swift:269`); "Scope Scale" (`App/SettingsView.swift:569`) | **"Window size for new windows"**; **"Scope brightness"** and **"Grid brightness"**, each with its value shown; keep "IRE (0–100)"; **"Scope scale"** | Sentence case like its neighbors; "raster" is a video-engineering word for what users call window size. |
| 26 | Option names | "Automatic (fit on open)" vs "Fit to Screen" (`App/RasterSize.swift:101, 106`); "Outside (darken) color" (`App/SettingsView.swift:614`); "Social safe zones" (`App/FramingGuide.swift:218`; `App/SettingsView.swift:623`); "1:1 pixels" (`Packages/ManifoldCore/Sources/ColorimetryModel/SDIOutputMode.swift:58`); "SDI (follows video)" (`SDIOutputMode.swift:78`; `App/ContentView.swift:2255`) | **"Fit when opened"** vs **"Fit to Screen"**; **"Color outside the guide"**; **"Social media safe zones"**; **"1:1 pixels (scale down only if larger)"**; **"SDI, with the picture"** | Each says what happens. |
| 27 | Field words | "Weave" (`Packages/ManifoldCore/Sources/FileScan/FieldView.swift:73`; menu, `App/DisplayTransform.swift:232`); "Deinterlace" (`FieldView.swift:76`); "TFF"/"BFF" (`Packages/ManifoldCore/Sources/FileScan/SourceScan.swift:22`; `App/DeckLink/DeckLinkService.swift:1621`) | **"Both fields (Weave)"**; keep "Deinterlace"; **"top field first"** / **"bottom field first"** in readouts | Weave is a term of art; give it words. |

## Vendor or server wording (items 28–29)

| # | Thing | Today (where) | Proposed | Why |
|---|---|---|---|---|
| 28 | Server refusal text | The server's response body is shown in the banner (`App/WebRTC/WHEPClient.swift`, refusal path; BUGS.md cites `:585-589`, not re-read) | Manifold's own sentence first ("The stream server refused the connection."), then the server's text in quotes, shortened | Keeps the useful detail but the wording doesn't change with the server. Server-agnostic rule. |
| 29 | Frame.io in the EDL alert | "…(Frame.io assumes 01:00:00:00)" (`App/Markers/MarkerFileIO.swift:208`) | **"…(many tools assume 01:00:00:00)"** | One vendor named as the reason. (D8) |
| 29 | Resolve in the card-busy message | "…in use by another application (for example DaVinci Resolve)…" (`Packages/ManifoldCore/Sources/DeckLinkRefusal/DeckLinkRefusal.swift:20`) | Drop the example, or keep it: it's the app most likely to hold the card | Your call (D8). The Resolve EDL format name (`App/Markers/MarkerFileIO.swift:25, 170`) stays: it's the format. |
| 29 | Apple in the HLS note | "No audio offset on HLS — Apple’s player owns the audio." (`App/Live/LiveAudioOffset.swift:48, 75`; `App/StreamBookmarksSheet.swift:429`) | **"HLS streams can't take an audio offset."** | The reason is internal; the fact is what matters. |

## State the user can't see (items 30–37)

| # | Thing | Today (where) | Proposed | Why |
|---|---|---|---|---|
| 30 | Connecting | No "Connecting…" string in App (searched); SRT's "Connected, but…" after a grace (`App/SRT/SRTClient.swift:1109-1125`) | Antenna tooltip and button label **"Connecting to <name>…"** while a connect is in flight | The only state with no words. Needs code, not a rename. |
| 31 | Banner timing | Connection banner hides after 9 s (`App/ContentView.swift:2841`) | Errors stay until closed or replaced; the frame-save "Saved" banner and playback notes keep their timers | (D7) An error read too late is gone; the manual says "connect again to see it". |
| 32 | Beeping menu items | A menu item that can't act beeps (`App/Shortcuts/ShortcutCenter.swift:154`) | Gray out (D10) | The menu then says what's available. |
| 33 | DeckLink menu item | "Start/Stop DeckLink Output" with no card, title never says which (`ShortcutCatalog.swift:241`; `App/ManifoldApp.swift:339`) | **Start DeckLink Output** / **Stop DeckLink Output** by state; hidden or grayed with no card | The title should say what a click does. Behavior with no card: UNKNOWN (BUGS.md item 33). |
| 34 | Trial days | Shown only in Settings ▸ License (`App/LicenseManager.swift:93, 125`) | A one-line notice at launch when 3 days or fewer are left: **"3 days left in your trial."** | Nothing warns before "Your Manifold trial has ended" (`App/LicenseManager.swift:951`). |
| 35 | Export Diagnostics with no window | Help ▸ Export Diagnostics… (`App/ManifoldApp.swift:300`) | No rename; verify it works with no window open | UNKNOWN today (BUGS.md item 35). |
| 36 | Range override | Inspector "Range" Auto / Full / Legal (`App/InspectorPanel.swift:147`) changes the picture with no marker | Add **"Range: Full (set)"** to the title markers when not Auto | Same rule as color overrides: a changed picture is never silent. |
| 37 | Badges that hide | Floating bar hides Bypass / COMPARING / A/V badges after 2 s; full screen shows no title markers (`App/WindowDeck.swift:458` for COMPARING in the title) | Keep the badges while the state is on; in full screen show them in the corner | A state that's on should stay visible. |

## Keys (items 43–44)

| # | Thing | Today (where) | Proposed | Why |
|---|---|---|---|---|
| 43 | Bare letters beside ⌘ letters | I / ⌘I (`ShortcutCatalog.swift:288, 315`), O / ⌘O (`:289, 225`), L / ⌘L (`:249, 267`), M / ⌥M / ⇧M / ⌃⌘M (`:274-285`) beside macOS's ⌘M | Keep (D11); add a sentence in the shortcuts chapter | Editing-app convention; changing them costs more than it fixes. |
| 43 | Full screen keys | ⌘F and ⌃⌘F are in no menu (`ShortcutCatalog.swift:329-330`, `.key`); the View menu shows fn-F | Show **⌃⌘F** on View ▸ Enter Full Screen | The menu then names the key the app uses. |
| 43 | Previous / Next Marker | Titles carry "· ⇧↑ / ⇧↓" (`App/Markers/MarkCommands.swift:29-30`, via `ShortcutCenter.hint`) | Drop the key from the title; it's in the shortcuts list | No other item puts its key in its title. ⇧-arrow can't be a menu key equivalent (`MarkCommands.swift:6`), so this is a note, not a key column. |
| 44 | Mute key | "Mute / Unmute" ⌥⌘↓, marked UNVERIFIED (`ShortcutCatalog.swift:371-374`) | No rename; verify the key in a build, then remove the mark | Not a naming problem. |
