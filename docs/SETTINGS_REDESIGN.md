# Settings window redesign and the highlight colour (2026-10-27)

**Brief (Robbie, 2026-10-27):** match the Keyboard Shortcuts window's style and fix the tall, narrow, non-resizable
layout (`SHORTCUTS_UI_REVIEW_2026-10-24.md`: "a tall, skinny window that can't be resized feels wrong"). A toolbar-tabbed
Settings window, resizable within bounds, each pane sized to its content. A new **Highlight colour** setting drives every
use of the app yellow, with the playhead colour as an override. Every other key, default and behaviour unchanged.

Base: `a0474e2` (plus that commit's hash filled into BUGS.md and RELEASE_NOTES.md). Built and run unattended
2026-10-27, Profile. Predictions were written and hashed before any code change:
`build/settings-redesign/predictions.md` (19:50:58 EDT, sha256 `697aa788…8adb8e`), copied in §6.

---

## 1. Inventory: every setting, before and after

HEAD's Settings window was one grouped form, 440 pt wide, not resizable, opening 440 × 552 (measured). Eight sections:
License, I/O and Runtimes, DeckLink Output, Interface Options, Scopes, Frame Export, Framing Guides, Broadcast safe zones.
The tree's file is `App/SettingsView.swift`; HEAD's view was `App/Preferences.swift` 1279–1695 (removed).

| HEAD section | Row (label) | Control | Stored key | Default | Read by | Tree pane |
|---|---|---|---|---|---|---|
| License | Status; key field + Activate, or Deactivate on this machine | status, text field, buttons | Keychain (`storedLicenseKey`); flags `license.activated`, `license.validated`, `license.type` | — | `LicenseManager.swift:580–584` | License |
| I/O and Runtimes | NDI Runtime | status row | none (runtime probe) | — | `NDIService.refreshRuntimeStatus` | Sources |
| | Install / Reinstall NDI Runtime… | button | none | — | `NDIService.runtimeInstallURL` | Sources |
| | DeckLink | status row, + device names | none (driver probe) | — | `DeckLinkService.driverStatus`, `.devices` | DeckLink Output |
| | Download / Update Desktop Video… | button (driver missing or below floor) | none | — | `DeckLinkService.driverInstallURL` | DeckLink Output |
| | Pro Video Formats | status row | none | — | `ProVideoWorkflow.availability` | Sources |
| | Download / Reinstall Pro Video Formats… | button | none | — | `ProVideoWorkflow.downloadURL` | Sources |
| DeckLink Output | Enable output on launch | toggle | `manifold.decklink.enableOnLaunch` | off | `DeckLinkService.swift:838` | DeckLink Output |
| | SDI scaling | segmented | `manifold.decklink.sdiScaling` | Fit to mode | `DeckLinkService.swift:721` | DeckLink Output |
| | SDI output modes | segmented | `manifold.decklink.outputModeSet` | HD/UHD only | `DeckLinkService.swift:716` | DeckLink Output |
| Interface Options | Controls | inline picker | `controlDisplayMode` | overlay | `WindowChrome.swift:240, 273` | General |
| | Playhead | segmented | `manifold.playhead.style` | Line | `TransportScrubber.swift:25` | Playback |
| | Playhead line color (Line only) | colour well | `manifold.playhead.lineColor` | FFE600 | `TransportScrubber.swift` | Playback, **as the override** (§4) |
| | Autoplay on open | toggle | `autoplayOnLoad` | off | `WindowDeck.swift:529` | Playback |
| | Open files in | menu | `manifold.open.destination` | This window | `WindowDeck.swift:955` | Files |
| | Raster size for new windows | menu | `manifold.raster.size` | Automatic | `WindowChrome.swift:235` | General |
| | MXF files / QuickTime movies / MP4 files open in (+ Use Manifold) | status rows, buttons | none (Launch Services) | — | `DefaultHandlerStatus` (`Preferences.swift:994`) | Files |
| Scopes | Scope Scale | menu | `scopeScale` | 10-bit | `WaveformScope.swift:764`, `ParadeScope.swift:202` | Scopes & Guides |
| | Master scope intensity | slider | `globalScopeIntensity` | 1.0 | `WaveformScope.swift:693`, `ParadeScope.swift:135`, `VectorscopeScope.swift:307` | Scopes & Guides |
| Frame Export | Folder; Choose…; Use Desktop | readout, buttons | `exportFolderBookmark` | empty (Desktop) | `Preferences.withExportDirectory` (`Preferences.swift:218`), used by `MetalVideoRenderer.swift:4928`, `LiveVideoDecoder.swift:867`, `DiagnosticsExport.swift:563` | Files |
| Framing Guides | Outside (darken) color; Outside opacity; Guide line color; Guide line width; Social safe zone color, width, opacity | wells, sliders, steppers | `guideDarkenColor` 000000, `guideDarkenOpacity` 0.85, `guideLineColor` FFFFFF, `guideLineWidth` 2, `safeLineColor` FFFF00, `safeLineWidth` 1, `safeLineOpacity` 0.75 | as listed | `FramingGuide.swift:51–57` | Scopes & Guides |
| Broadcast safe zones | color, width, opacity | well, stepper, slider | `broadcastSafeColor` FFFFFF, `broadcastSafeWidth` 1, `broadcastSafeOpacity` 0.75 | as listed | `FramingGuide.swift:58–60` | Scopes & Guides |

**New rows.** General ▸ Highlight color (`manifold.highlightColor`, §4) and *Use Default Highlight* (shown only when
it is not the default); Playback ▸ Playhead color, *Same as highlight* | *Custom* (`manifold.playhead.followsHighlight`),
with *Custom playhead color* under Custom; General ▸ Keyboard ▸ *Open Keyboard Shortcuts…*; Advanced (debug gate only,
read-only): Debug menu, Live audio WAV capture, DeckLink audio trim.

**Settings that live elsewhere, and where they stay.**

| Setting | Where | Key | Decision |
|---|---|---|---|
| Debug menu gate | `defaults` / `MANIFOLD_DEBUG_MENU` only | `manifold.debugMenu` | **Shown read-only in Advanced.** A toggle would be a new way to write a launch-latched switch whose log line already tells the user how to turn it off |
| Live audio WAV capture gate | `defaults` / env only | `manifold.captureLiveAudioWAV` | Read-only in Advanced, same reason |
| DeckLink audio trim | `defaults write` only | `manifold.decklink.audioTrimSeconds` | Read-only in Advanced: a calibration value documented as a `defaults write`; no UI had it |
| Each scope's intensity, trace colour, monochrome, graticule, reference lines, targets | the scope's header in the tray | `waveformIntensity`, `waveformTraceColor`, `paradeMonochrome`, `manifold.vectorscope.*`, `manifold.waveform.line*` … | **Stay.** They are set while looking at the trace; a caption under Master scope intensity says where they are |
| CIE options, meter marker, caption position | the scope or overlay's own menu | `manifold.cie.*`, `manifold.meters.marker.*`, `manifold.caption.positionPreset` | Stay, same reason |
| Guide mode, aspect, social and broadcast percentages | the framing guides popover | `guideMode`, `guideAspect`, `broadcastActionPct` … | Stay: framing decisions, not styling (HEAD's own note) |
| LUT interpolation | the Color control's Interpretation menu | `lutInterpolation` | Stays: chosen with the LUT |
| DeckLink manual output mode | the DeckLink menu | `manifold.decklink.manualOutputMode` | Stays: per session, set with the output |
| Volume, tray, slots, raster per window | the window | `playbackVolume`, `showTray`, `manifold.scope.slot*` … | Stay: window state, not preferences |
| Include file names | Export Diagnostics sheet | none (per export, not stored) | Stays: privacy P1 made it a per-export choice on purpose |
| Keyboard shortcuts | their own window | `manifold.shortcuts` | Stays its own window (brief); General links to it |

## 2. Code map: same key, same default

Every `@AppStorage` in HEAD's `SettingsView` is declared in the tree's pane that shows it with the same key string and
the same default expression (moved verbatim, comments included): `controlDisplayMode`, `RasterSize.defaultsKey`
(General); `OpenDestination.defaultsKey`, `exportFolderBookmark` (Files); `autoplayOnLoad`, `PlayheadStyle.defaultsKey`,
`PlayheadStyle.colorDefaultsKey` (Playback; now `String?`, so absence can be read, default still `FFE600` when read
through `PlayheadStyle.lineHex`); `globalScopeIntensity`, `scopeScale`, the seven guide keys, the three broadcast keys
(Scopes & Guides); `DeckLinkService.enableOnLaunchKey`, `SDIOutputModeSet.defaultsKey`, `SDIScaling.defaultsKey`
(DeckLink Output). The writers outside Settings are untouched; `git diff a0474e2` shows no change to any of the readers
listed in §1 except `TransportScrubber` (the playhead, §4).

The system-state reads HEAD made when Settings opened (NDI runtime, DeckLink devices, Pro Video Formats, the three
default handlers) are made at the same moment (`SettingsRefresh.all`, on the tab view's appear), and again for a pane's
own rows when that pane is chosen.

## 3. Layout

**Tabs, and why they differ from the brief's list.**

| Brief | Tree | Why |
|---|---|---|
| General | **General**: Appearance (highlight), Windows (Controls, Raster size), Keyboard | |
| — | **Files**: Opening Files (Open files in, default apps), Frame Export | General with these was 1 017 pt tall (measured, first run): taller than a pane should open. They are the file in, frame out cluster |
| Playback | **Playback**: Autoplay, Playhead style and colour | |
| Color & Display | **Scopes & Guides**: Scopes, Framing guides, Broadcast safe zones | No colour-management setting is app-wide: colour is per window in the Color menu by design. A tab called Color & Display would promise settings that are not there |
| DeckLink Output | **DeckLink Output**: device status, output settings | The DeckLink status row moved here from I/O and Runtimes |
| Streams | **Sources**: NDI Runtime, Pro Video Formats | No stream setting is app-wide (bookmarks are their own sheet, overrides are per bookmark). What is left is what makes sources available |
| Privacy & Licence | **License** | No privacy setting is stored (Include file names is per export, by design). "License": the app's strings are American English (BUGS.md pre-ship checklist) |
| Advanced | **Advanced**, debug gate only | Read-only (§1). Same predicate as Keyboard Shortcuts' debug section (`ShortcutDebugGate.showsDebugSection`) |

Spelling: the brief says "Highlight colour" and "Playhead colour"; the UI says **color** (American English, as above).

**Size.** Opens 640 pt wide (Keyboard Shortcuts' class; it is 640–700), resizable 560–1000 pt wide and from the pane's
minimum up to the screen in height. Each pane opens at its own content's height; the width is the user's and is kept
across panes. **Visual language** taken from Keyboard Shortcuts: system body text for rows, caption-size secondary text
under the row it explains, section headers, colour only for the highlight and the orange "you can fix this" status.
The panes stay grouped Forms (the standard macOS Settings look; a plain List cannot host these controls well).

**The selected pane is in memory** (`SettingsNavigation`), not a preference, so browsing writes nothing; Settings opens on
the pane last shown in this launch. Manifold ▸ License… selects License, then opens Settings.

## 4. The highlight colour

- **Stored** as `manifold.highlightColor` (6-digit hex, the app's usual `ScopeColorCodec` form). Absent or malformed means
  #FFE600. Written only by General ▸ Highlight color and *Use Default Highlight*, and only when the value changes.
- **One reader**, `AppHighlight.shared` (`Packages/ManifoldCore/Sources/PlayheadSlider/PlayheadSlider.swift`), an
  `@Observable` store: a SwiftUI view that reads `Color.appYellow` or `Color.appYellowText` in its body redraws when it
  changes. 18 drawing sites read it (`grep` of the tree): 15 `Color.appYellow` (control bar on-states ×6 in
  `ContentView.swift`, Color control tint `LiveColorOverride.swift:384`, hold-to-compare badge
  `DisplayTransformControl.swift:151`, field-view marker and its control `FieldViewControl.swift:34, 104`, guides popover
  ×2 `FramingGuide.swift:191, 249`, Inspector track marker `InspectorPanel.swift:468`, bookmark row being edited
  `StreamBookmarksSheet.swift:201`, Keyboard Shortcuts' customised dot `KeyboardShortcutsView.swift:121`), 2 text sites
  through `assertion` (`DisplayTransformControl.swift:283, 339`, now computed), and the playhead (`TransportScrubber`).
  No literal #FFE600 remains outside the default constant. `safeLineColor`'s FFFF00 is the social safe zones' own
  default colour, not the app yellow, and is unchanged.
- **Green is not affected**: live states use `Color.green` (`ContentView.swift:2054, 2198`), which no setting touches.
- **The playhead.** *Playhead color: Same as highlight | Custom* (`manifold.playhead.followsHighlight`, written only when
  the user picks one). Until it is written, the choice is inferred and nothing is migrated: no stored
  `manifold.playhead.lineColor`, or the old default #FFE600, follows the highlight; any other stored colour is the user's
  customisation and stays the playhead's (`PlayheadStyle.followsHighlight`). Choosing Same as highlight keeps the stored
  colour, so Custom brings it back. This install: `manifold.playhead.lineColor` absent, so it follows.
- **Light-appearance text** (the chain readout's override and LUT words): the rule replaces the hand-picked value. Keep the
  hue and scale the three sRGB channels down together, 1/255 of the largest at a time, to the first value with ≥ 4.5:1
  against #D0D0D0 (the darkest light background it is drawn on); a colour already that dark is kept. For #FFE600 this gives
  #645A00, the value it replaces, so a default install draws exactly what it drew (`AppYellow.textOnLight`).
- **Near the live green**: hue 100°–170° (the system green is ~130°–135°) with saturation and brightness ≥ 0.3. General
  then shows "Live states (DeckLink output, a connected stream) also use green." (`AppYellow.isNearLiveGreen`).

## 5. Findings

1. **SwiftUI's Settings scene sizes neither way the brief needs (measured).** With flexible pane frames and
   `.windowResizability(.contentMinSize)` on the scene, every pane opened at 900 × 450 and the window refused every
   resize (AX size 900 × 900, 300 × 200 and 700 × 600 each read back 900 × 450). A grouped Form is a scroll view and
   reports no content height; and SwiftUI clears the window's resizable flag within a second of anything setting it
   (logged: resizable 1 at the fit, 0 one second later). So `SettingsWindowFit` (in `SettingsView.swift`) sets each pane's
   height from its Form's document height plus the title bar and toolbar (88 pt), and observes the style mask to put the
   resizable flag back. It touches the style mask, min/max size and frame only; never the delegate (`WindowSizer.swift`'s
   note on what replacing SwiftUI's delegate does).
2. **The License pane shows the licensee's email** (as HEAD's section did). The run's Accessibility dumps captured it;
   it was redacted from every stored dump and the driver now redacts before writing. Not in this record.
3. **Reopening keeps the size and pane.** Closed at 820 × 700 on Files and reopened: Files, 820 × 700 (measured). The
   opening width of 640 applies to the first open of a launch only; the height is not re-fitted on reopen. That is the
   usual macOS behaviour, so it was left as it is (decision 4).

## 6. Predictions (copied from `build/settings-redesign/predictions.md`, written before any code change)

| # | Prediction | Pass | Fail |
|---|---|---|---|
| S1 | Every setting row in HEAD's window is in a pane of the tree's, by Accessibility label, each bound to the same key and default (code map) | all present, same key | any missing or rebound |
| S2 | 6 tabs (General, Playback, Scopes & Guides, DeckLink Output, Sources, License) with the debug gate off; 7 with `-manifold.debugMenu YES`; the title follows the tab | as stated | otherwise |
| S3 | Resizable; never below 560 pt wide; at least 4 distinct pane heights; every pane 300–820 pt at the opening width; HEAD 440 pt wide, not resizable | as stated | otherwise |
| S4 | Opening and browsing every pane, changing nothing: only `NSWindow Frame` keys differ, on both builds | 0 non-frame differences | any |
| S5 | One accessor for every use of the yellow: 17 sites; no literal FFE600 outside the default. Near-green note with `-manifold.highlightColor 30D158`, none by default | as stated | otherwise |
| S6 | Playhead resolver (unit test): absent or FFE600 follows; other stored colour is the override; an explicit choice wins. This install opens on Same as highlight | as stated | otherwise |
| S7 | The text rule gives #645A00 for #FFE600 and ≥ 4.5:1 on #D0D0D0 over a sweep | as stated | any |
| S8 | 24-file control set, HEAD vs tree: `.rgba16f`, `.v210`, `.v210.json`, PNG, display read-back and three scope images byte-identical; also with `-manifold.highlightColor 00A0FF` on 4 files | every byte | any byte |
| S9 | SDI loop, paused, 2 interlaced fixtures in Weave: read-back = HEAD's, every received frame = the read-back, late = 0 dropped = 0 | 0 different | any |
| G | `swift test` 642 + new, all pass; the same 12 compiler warnings as HEAD | as stated | otherwise |
| D | After the runs the domain is dictionary-equal to the snapshot; licence keys present (3), never written; streamBookmarks unchanged | equal | any |

Estimate: about 3 h (band 2–4½ h).

## 7. Results

Run unattended 2026-10-27, 19:50–20:45 EDT (**about 55 min against the 3 h estimate**, below the 2–4½ h band). HEAD built from a
`git archive` of `a0474e2`. No screenshots: the panes were read by Accessibility, pictures by the export, display
read-back and scope dumps. No keystrokes; every quit a Quit event to the built app's path. Driver and analysis:
`build/settings-redesign/` (`drv-settings.py`, `drv.py`, `drv-loop.py`, `cmp.py`, `ddiff.py`).

| # | Result | Verdict |
|---|---|---|
| S1 | Every HEAD row's label present in the tree's panes (Accessibility, all panes); the one label gone is "Playhead line color", replaced as the brief asks by "Playhead color: Same as highlight / Custom" and "Custom playhead color" (seen with `-manifold.playhead.lineColor FF0000`: Custom selected, the well reads rgb 1 0 0). Code map §2: same keys and defaults | **PASS** |
| S2 | **7 tabs**, not 6: General, Files, Playback, Scopes & Guides, DeckLink Output, Sources, License; + Advanced with `-manifold.debugMenu YES` (read-only rows as designed). Title follows the tab. Files was split from General after the first run measured General at 1 017 pt (§3). Manifold ▸ License… opens on License | **FAIL as predicted** (6); changed by design during the run |
| S3 | HEAD: 440 × 552, every AX resize refused. Tree: opens 640 wide; heights General 559, Files 645, Playback 364, Scopes & Guides **830**, DeckLink Output 545, Sources 493, License 328 (7 distinct). Resize 900 × 900 accepted, 300 × 200 clamped to 560 × 328, 700 × 600 accepted; switching panes keeps the width (700) and re-fits the height. First build: every pane 900 × 450 and no resize (finding 1) | **FAIL on the band** (Scopes & Guides 10 pt over 820); the rest PASS |
| S4 | HEAD: 1 key added (the player window's frame), 0 non-frame. Tree, every run (default, near-green, custom playhead, debug gate, License…): only `NSWindow Frame` keys added or changed, 0 non-frame. No toolbar or tab key written | **PASS** |
| S5 | 18 drawing sites, all through `AppHighlight` (§4); the prediction's count of 17 was a miscount, no site is missed. No literal FFE600 outside the default constant. `-manifold.highlightColor 30D158`: the well reads rgb 0.188 0.820 0.345, the near-green note and *Use Default Highlight* shown; default: neither. **Not measured:** the colour on screen of the other 17 sites (no screenshots; Accessibility does not expose colour). Checklist item 5 | **PASS** (code and AX); on-screen colour by hand |
| S6 | 7 resolver cases pass (`testPlayheadFollowsHighlight`); this install opens on Same as highlight | **PASS** |
| S7 | #FFE600 → #645A00 exactly; 216-colour sweep all ≥ 4.5:1 on #D0D0D0, never lighter, same hue (`testTextOnLightRule`) | **PASS** |
| S8 | 216 / 216 files byte-identical, HEAD vs tree (24 each of PNG, `.rgba16f`, `.v210`, `.v210.json`; 48 display read-back files; 72 scope images). With `-manifold.highlightColor 00A0FF`, 36 / 36 identical to HEAD on 4 files | **PASS** |
| S9 | TFF and BFF fixtures: read-backs byte-identical to HEAD's (4 / 4 files); 130 and 131 received frames = the read-back, 0 different, on both builds; late = 0 dropped = 0; probe read SDI after | **PASS** |
| G | `swift test` **647 / 647** (642 + 5). Clean Profile builds: the same warnings as HEAD's, 13 locations by line and column (the I4 record's 12 counted differently) | **PASS** |
| D | 17 frame keys added and the Settings window's frame key changed by the runs: each read and stashed (`stash/`), the added deleted, the changed written back to the snapshot's value, one `set -e` sequence. Domain then dictionary-equal to the snapshot (1 626 keys); licence keys present (3), values never read, never written; streamBookmarks `18c6da5d…` unchanged | **PASS** |

The final build differs from the measured one by comments only (`SettingsView.swift` header, `ManifoldApp.swift`); it was
rebuilt and the Settings run repeated on it (same sizes, same panes).

**Decisions for Robbie.**
1. The tab set and names (§3): Files split from General; Scopes & Guides instead of Color & Display; Sources instead of
   Streams; License with no privacy rows.
2. Width: opens 640, 560–1000. Scopes & Guides opens 830 tall; splitting it (Scopes / Guides) would bring it near 400 each.
3. The near-green note's wording, its orange, and the hue band (100°–170°); the 4.5:1 rule for the light text variant.
4. Reopening Settings keeps the size and pane you left (finding 3), rather than snapping back to 640.
5. The playhead inference: a stored #FFE600 counts as "never customised" and follows the highlight.

## 8. By-hand checklist for Robbie (about 15 minutes, on the LG)

Build: the tree's Profile build (`.build-cc`). Clicking a colour well opens the system colour panel, which saves its own
window position (an `NSColorPanel` key), as it did before.

1. **Open Settings (⌘,).** Toolbar tabs: General, Files, Playback, Scopes & Guides, DeckLink Output, Sources, License.
   Click through them: each tab's height fits what it holds, nothing is cut off, no tab needs scrolling at its opening size.
   Does it read like the Keyboard Shortcuts window (text sizes, grey captions, spacing)?
2. **Resize** by the edges and corners: it stops at 560 pt wide and 1000 pt wide; switching tabs keeps your width and fits
   the height. Close and reopen: it opens on the last tab you used, at the size you left it (finding 3).
3. **Manifold ▸ License…** opens Settings on the License tab.
4. **Everything you had set is still set**: Controls, raster size, Open files in, export folder, autoplay, playhead style,
   scope scale and intensity, guide and safe-zone colours, DeckLink output options.
5. **Highlight color** (General): pick a blue. Without closing Settings, check that each of these turns blue:
   the playhead (Line style), Loop when on, the pin when pinned, Scopes when open, Captions when on, the file-changed
   reload button, the Color control and the chain readout's override words with an override set, the hold-to-compare
   badge (hold C), the field-view marker and its control (an interlaced file, Field 1), the guides popover's selected
   aspect, the Inspector's monitored-track marker, a stream bookmark being edited, the customised-shortcut dot in Keyboard
   Shortcuts. **Green stays green**: DeckLink output running, a connected stream.
6. **Light appearance** (System Settings ▸ Appearance ▸ Light): the chain readout's override words are a darker blue and
   easy to read on the light popover. Back to your usual appearance afterwards.
7. **Near green**: pick a green. A one-line note appears under the highlight: "Live states … also use green."
   *Use Default Highlight* brings the yellow back.
8. **Playhead** (Playback, Line): *Same as highlight* is selected. Choose *Custom*, pick red: the playhead is red and stays
   red when you change the highlight. Choose *Same as highlight*: it follows the highlight again. Choose *Custom* again: red
   is back. Then set it how you want it.
9. **Decisions** (§7): tab names and grouping (Files split from General; Scopes & Guides; Sources; License), the opening
   width, the near-green note's wording and its orange, the 4.5:1 text rule.
