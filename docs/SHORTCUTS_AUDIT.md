# Keyboard shortcut audit

Read-only audit, 2026-10-23. Line numbers are those of `HEAD` `6be1fa8`: uncommitted DeckLink edits made during
the audit shift `ContentView.swift` by +1 after line 1337 and by more further down. Nothing was built or launched. Every claim about Manifold cites
`file:line`. A claim reached by reading code and not by running the app says **by reading**. Anything not
established is **UNKNOWN**. Robbie chooses the scheme in §4 before anything is built (BUGS.md:232, *"The shortcut
registry and its window, first of what remains"*).

Notation: ⌘ Command, ⌃ Control, ⌥ Option, ⇧ Shift. "Profile" means the shipped configuration, which defines
`DEBUG` (CLAUDE.md, project.yml:9-10).

---

## 1. Inventory

### 1.1 How shortcuts are built today

Five mechanisms, and nothing ties them together:

| # | Mechanism | Where | Notes |
|---|---|---|---|
| M1 | Menu items with `.keyboardShortcut` | `ManifoldApp.swift:161-301`, `RasterSize.swift:347-358`, `DisplayTransform.swift:190-197` | App-level. Acts on the key window. These are the only shortcuts shown anywhere in the UI. |
| M2 | Zero-opacity `Button` + `.keyboardShortcut` in `.background` | `ContentView.swift:550-640`, `:1269`, `:1657-2011`, `:2964` | Per window: resolves against the key window's hierarchy (measured, MULTIWINDOW_FINDINGS.md §3.1). Gated by `.disabled` (measured to suppress the key, same §). Hidden, so users learn them only from release notes (RasterSize.swift:322-324). |
| M3 | `TransportKeyMonitor`, an `NSEvent` local `.keyDown` monitor, one per window | `TimecodeEntry.swift:348-357`, `:386-432` | Acts only when its deck's window is key (`:387`). Steps aside while a text view is first responder (`:388`, `:483-487`). |
| M4 | `HoldToCompare`, an `NSEvent` local `.keyDown`/`.keyUp` monitor, app-wide | `HoldToCompare.swift:44-79`, installed at `ManifoldApp.swift:45` | Acts on the key deck. Steps aside for `NSText` first responders (`:67`). |
| M5 | `.defaultAction` / `.cancelAction` on sheet buttons | listed in §1.7 | Return and Esc inside sheets. |

Stock items that SwiftUI and AppKit add, which no file in this repo declares: New Window ⌘N, Close ⌘W,
Settings… ⌘, (from the `Settings` scene, `ManifoldApp.swift:305`), Hide ⌘H, Hide Others ⌥⌘H, Quit ⌘Q,
Minimize ⌘M, the Edit menu (⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A), Help search ⌘?. The View menu also gets Show Tab Bar,
Show All Tabs and Enter Full Screen (⌃⌘F); the measured note at RasterSize.swift:339-345 confirms those items
exist. Their exact key equivalents on this build were not read off a running app (**UNKNOWN**). Nothing in
`App/` disables window tabbing: a grep for `allowsAutomaticWindowTabbing` and `tabbingMode` finds nothing.

### 1.2 Menu bar (M1)

| Key | Action | Defined | Scope | DEBUG-only |
|---|---|---|---|---|
| ⌘O | File ▸ Open… | `ManifoldApp.swift:243-244` | app; lands per `DeckRegistry.openFromUserAction` | no |
| none | File ▸ Open Recent | `ManifoldApp.swift:250` | app | no |
| ⌘1 | View ▸ 100% | `RasterSize.swift:119`, applied `:353`, `:383` | key window; greyed with no source (`:357`) | no |
| ⌘2 | View ▸ 75% | `RasterSize.swift:120` | key window | no |
| ⌘3 | View ▸ 50% | `RasterSize.swift:121` | key window | no |
| ⌘4 | View ▸ 25% | `RasterSize.swift:122` | key window | no |
| ⌘0 | View ▸ Fit to Screen | `RasterSize.swift:123` | key window | no |
| none | Color ▸ As macOS Shows It / Reference (BT.1886) / Bypass | `DisplayTransform.swift:190-197`, titles `:80-82` | key window | no |
| none | About, Check for Updates…, License…, Install NDI Runtime…, Download Pro Video Formats…, Export Diagnostics…, Help ▸ Download Sync Clips… | `ManifoldApp.swift:166-233` | app | no |
| ⌃⌥A | Debug ▸ NDI Audio Tone Test (cycles off / 0 dBFS / −6 dBFS) | `ManifoldApp.swift:410` | app | yes: `#if DEBUG` **and** `DebugMenuGate` (`:288`, gate `:341-375`) |
| ⌃⌥⇧B | Debug ▸ Chroma Scrub Bench | `ManifoldApp.swift:433` | key deck | yes, same gate |
| none | Debug ▸ Renderer Input, Desktop Audio Lead, Resampler Ratio, Force Video Jump (×2), Record NDI Audio to WAV | `ManifoldApp.swift:473-546` | app | yes, same gate |

### 1.3 Window shortcuts that ship (M2)

"Ships" means not inside any `#if`. ContentView's only `#if DEBUG` regions are `:259-282`, `:731-733`,
`:1778-2011`, `:2884-2889` and `:2933-2937`.

| Key | Action | Defined | Scope and gate |
|---|---|---|---|
| Space | Play / pause | `ContentView.swift:2964-2965` | Window. Mounted only with a source, inside the control bar. In overlay mode the bar is hidden by opacity, not removed (`:1244`), so Space still works while the HUD is hidden. `.disabled(!position)` (`:2966`). |
| J | Shuttle reverse: −1, −2, −4… (FrameEngine.swift:900-904) | `ContentView.swift:599-600` | Window, mounted with or without media. Gated on transport and position (`:640`). |
| K | Shuttle pause | `ContentView.swift:601-602` | same |
| L | Shuttle forward: 1, 2, 4… (FrameEngine.swift:896-898) | `ContentView.swift:603-604` | same |
| I | Toggle the inspector | `ContentView.swift:552-553` | Window, ungated |
| N | Toggle the file-name overlay | `ContentView.swift:557-558` | Window, ungated |
| Tab | Pin / unpin the overlay HUD | `ContentView.swift:1269-1270`, action `:3326-3331` | Window. The action does nothing when docked or with no source, but the button still takes the key (by reading). |
| ⌃⌥R | Show the `AVSampleBufferDisplayLayer` instead of Metal (M4 render-path A/B) | `ContentView.swift:562-563`, state `:372-376`, effect `:1197` | Window, ungated, **ships** |
| ⌃⌥E | Export the current frame (PNG + `.rgba16f`; in DEBUG also `.v210`, BUGS.md:1118) | `ContentView.swift:567-568` | Window, ungated |
| ⌃⌥T | Toggle the scopes tray | `ContentView.swift:1659` | Window, ungated |
| ⌃⌥X | CIE scope: xy ↔ u′v′ | `ContentView.swift:1665` | Window, ungated |
| ⌃⌥G | Vectorscope graticule: fixed 709 ↔ source primaries | `ContentView.swift:1672` | Window, ungated |
| ⌃⌥B | Vectorscope boxes: 75% → 100% → both | `ContentView.swift:1681` | Window, ungated |
| ⌃⌥1 / ⌃⌥2 / ⌃⌥3 | CIE: toggle the 709 / P3 / 2020 triangle | `ContentView.swift:1685`, `:1687`, `:1689` | Window, ungated |
| ⌃⌥O | Start DeckLink output from this window | `ContentView.swift:1699` | Window. Device-claim gate (`:578`). |
| ⌃⌥⇧O | Stop DeckLink output | `ContentView.swift:1701` | same |
| ⌃⌥N | Connect the first NDI source | `ContentView.swift:1718` | Window. Device-claim gate (`:579`). |
| ⌃⌥⇧N | Retire this window's live source (any transport) | `ContentView.swift:1720` | same |
| ⌃⌥C | Cycle the colour interpretation override (file or live; WindowDeck.swift:291-293) | `ContentView.swift:1725` | Window. Device-claim gate (`:579`); see C5. Documented to users in RELEASE_NOTES.md:40, 42. |

### 1.4 Window shortcuts in Profile (`#if DEBUG`, so in every tester build)

All of these sit in `syntheticLiveShortcuts` (`ContentView.swift:1777-2011`) under the device-claim gate (`:580`).

| Key | Action | Defined |
|---|---|---|
| ⌃⌥W | libdatachannel link smoke test (log line only) | `ContentView.swift:1880` |
| ⌃⌥H | Connect WHEP: `MANIFOLD_STREAM_DEBUG_URL`, else `…_BOOKMARK`, else the first web bookmark | `ContentView.swift:1924` |
| ⌃⌥⇧H | Retire the live source | `ContentView.swift:1926` |
| ⌃⌥⇧E | Export the next decoded WHEP frame to PNG | `ContentView.swift:1933` |
| ⌃⌥D | Connect SRT: `MANIFOLD_SRT_DEBUG_URL`, else the first SRT bookmark, else a built-in target | `ContentView.swift:2004` |
| ⌃⌥⇧D | Retire the live source | `ContentView.swift:2006` |

BUGS.md:695-699 and 750-756 record the still-open question of whether a public build should carry these.

### 1.5 Debug-configuration only (`#if MANIFOLD_CONFIG_DEBUG`, not in Profile)

| Key | Action | Defined |
|---|---|---|
| ⌃⌥L | Start SyntheticLive (replays the loaded file through the live path) | `ContentView.swift:1816` |
| ⌃⌥⇧L | Stop SyntheticLive | `ContentView.swift:1818` |
| ⌃⌥P | Cycle the SyntheticLive preset | `ContentView.swift:1822` |
| ⌃⌥U | Toggle force-unity rate | `ContentView.swift:1833` |
| ⌃⌥S | SyntheticLive sweep | `ContentView.swift:1851` |
| ⌃⌥[ / ⌃⌥] | Live target depth −/+ 50 ms | `ContentView.swift:1964`, `:1966` |

### 1.6 Monitor keys (M3, M4)

| Key | Action | Defined | Scope and gate | Matched by |
|---|---|---|---|---|
| ← / → | Step 1 frame | `TimecodeEntry.swift:421-423`, `:463-480` | Key window = this deck; transport and position gates (`:472-473`) | key code 123/124 |
| ⇧← / ⇧→ | Step 1 second, i.e. `round(rate)` frames (`:476-478`) | same | same | key code + ⇧ |
| ⌥] / ⌥[ | Audio offset +1 / −1 ms | `TimecodeEntry.swift:392-395`, `:437-449` | Only while the window has a live source (`:392`) | physical key code 30/33, with exactly ⌥ |
| ⇧⌥] / ⇧⌥[ | Audio offset +10 / −10 ms | same | same | same, with exactly ⇧⌥ |
| 0–9 | Open timecode entry with that digit | `TimecodeEntry.swift:429` | Any key without ⌘⌃⌥ (`:397-398`); only when the deck accepts entry | character |
| + or = / − or _ | Open relative entry (+ / −) | `TimecodeEntry.swift:430-431`, `:500-501` | same | character |
| Return, keypad Enter | Commit entry | `TimecodeEntry.swift:403` | Entry open | key code 36/76 |
| Esc | Cancel entry | `TimecodeEntry.swift:404` | Entry open; otherwise Esc passes through | key code 53 |
| Delete, Fwd-Delete | Backspace in entry | `TimecodeEntry.swift:405` | Entry open | key code 51/117 |
| every other bare or ⇧ key | Swallowed | `TimecodeEntry.swift:410-415` | Entry open | |
| \ (hold) | Show the other of macOS and Reference until release | `HoldToCompare.swift:34`, `:65-79`, `:96-108` | App-wide, on the key deck; only with a source (`:93`) | **key code 42, any modifiers** (see C3) |
| ⇧\ (hold) | Show Bypass until release | same | same | same |

`HoldToCompare` is temporary by design (`HoldToCompare.swift:10-14`, COLOR_MANAGEMENT_FINDINGS.md:5734 and
:5791, BUGS.md:68-71: *"Pre-ship: the temporary key must be replaced by the registry's choice"*).

### 1.7 Sheets (M5)

| Key | Action | Defined |
|---|---|---|
| Return | Stream bookmarks: Done when the composer is clean, Save when it holds anything | `StreamBookmarksSheet.swift:96`, `:247` |
| Esc | Stream bookmarks: Cancel editing | `StreamBookmarksSheet.swift:250` |
| Esc / Return | Diagnostics export: Cancel / Export… (Return only with a connection) | `DiagnosticsExport.swift:1131`, `:1139` |
| Return | Get Flip sheet: Get Flip | `ContentView.swift:989` |
| Return / Esc | Calibration: Start, Apply (and Save), Cancel, Close | `Live/CalibrationMode.swift:563`, `:570`, `:574`, `:582`, `:587` |
| Return | Licence: Activate | `LicenseManager.swift:1128` |

### 1.8 Actions with no key that the plan expects one for

- Reset of the colour interpretation override: *"Its keyboard shortcut is the shortcut registry's to decide. It has none yet"* (BUGS.md:112, COLOR_MANAGEMENT_FINDINGS.md:6148).
- The display transform modes: menu only (`DisplayTransform.swift:190-197`).
- Markers: ROADMAP_IDEAS.md:52, *"Depends on: shortcut registry (marker keys)"*.
- Go to start and go to end, loop, mute, full-screen viewer: no Manifold binding found. A loop setting exists in the engine protocol (`PlaybackEngine.swift:46`); whether the UI exposes it was not traced (**UNKNOWN**).

---

## 2. Conflicts and hazards

### 2.1 Inside Manifold

- **C1. One action on three keys.** ⌃⌥⇧N (`ContentView.swift:1720`), ⌃⌥⇧H (`:1926`) and ⌃⌥⇧D (`:2006`) all call
  `DeckRegistry.shared.retireLiveIfOwned(by:)`. The ⇧N version ships and retires any transport, not only NDI.
- **C2. "Reference" means two things.** ⌃⌥R toggles `showReferenceLayer`, the AVFoundation render surface that
  bypasses Manifold's renderer (`ContentView.swift:372-376`, `:1197`). It ships ungated. Color ▸ Reference
  (BT.1886) is the display transform (`DisplayTransform.swift:81`). A user told "Reference is ⌃⌥R" gets a
  different picture path. ⌃⌥R is also a Rectangle default (§2.2).
- **C3. The hold-to-compare key ignores modifiers.** `handle` checks only `event.keyCode == 42`
  (`HoldToCompare.swift:65`), and `begin` reads only ⇧ (`:74`). So ⌘\, ⌃\, ⌥\ and ⇧⌘\ also start a hold, and
  the event is consumed (`return … ? nil`). ⇧⌘\ is a common default for Show All Tabs, which the stock View
  menu carries (§1.1). By reading, with a source loaded, that menu item's key is swallowed and the window
  compares against Bypass instead. **Not measured, and the stock key on this build is UNKNOWN** (§1.1).
- **C4. Two independent monitors read bare keys.** While timecode entry is open, `TransportKeyMonitor` swallows
  every bare key (`TimecodeEntry.swift:410-415`), but `HoldToCompare` is a separate monitor. Which runs first,
  and so whether \ during entry starts a hold, is **UNKNOWN**.
- **C5. ⌃⌥C sits behind the device-claim gate.** ⌃⌥C is a per-window interpretation change
  (`WindowDeck.swift:291-293`), but it lives in `ndiShortcuts`, which is disabled in a window that does not own
  the devices (`ContentView.swift:579`). The comment at `:572-576` lists the inspection keys a non-owning
  window keeps, and ⌃⌥C is not among them. On a non-owning window the key silently does nothing (by reading).
- **C6. The code's own key lists are out of date.**
  - `ManifoldApp.swift:280-282` says ⌃⌥A lives in `ContentView.syntheticLiveShortcuts`. It does not: the only
    ⌃⌥A binding is `ManifoldApp.swift:410` (BUGS.md:733 agrees).
  - `RasterSize.swift:113-116` is the hand check that cleared ⌘1–⌘4 and ⌘0. Its list of ⌃⌥ keys (T X G B R E O N
    D) omits C, H, W, A, L, P, U, S, [ and ]. A hand list cannot stay complete, so the registry should do this
    check (BUGS.md:756-758 reaches the same conclusion for dev-path audits).
- **C7. ⇧ on an arrow cannot be a key equivalent.** This was measured: AppKit's matcher collapses ← and ⇧←
  onto one claimant (`ContentView.swift:606-635`, `TimecodeEntry.swift:275-290`). Any scheme that puts ⇧ on an
  arrow (⇧↑/⇧↓ for markers, ⇧←/⇧→) must dispatch it through a monitor, not a menu item. ⇧[ / ⇧] carry the same
  hazard (`TimecodeEntry.swift:389-391`).
- **C8. Tab is taken from keyboard navigation.** A key equivalent is dispatched before the first responder
  (`TimecodeEntry.swift:263-268`), so in a window with a source, Tab never moves focus (by reading). With
  Keyboard navigation or Full Keyboard Access on, Tab and ⇧Tab are how controls are reached (Apple,
  [Full Keyboard Access](https://support.apple.com/guide/mac-help/use-full-keyboard-access-mchlc06d1059/mac)).
- **C9. Keys are matched three different ways.** Hidden buttons match by character, so J/K/L move with the
  layout (on Dvorak they are no longer a cluster). ⌥[ / ⌥] and \ match by physical key code. Digits match by
  character. None of this is visible to the user.
- **C10. Most keys cannot be discovered.** Only ⌘O, ⌘0–⌘4 and the two Debug-menu keys appear in any menu. Every
  other key is a hidden button (`RasterSize.swift:322-324`).
- **C11. J/K/L is partial.** Repeated J/L speeds up by doubling (FrameEngine.swift:896-904), which matches
  Resolve and FCP. Hold K + tap J/L (one frame) and hold K + hold J/L (slow play) are not possible: hidden
  buttons never see key-up (`HoldToCompare.swift:18`). Resolve and FCP both have these (§3).
- **C12. An instrument fault, still unexplained.** On one run, ⌃⌥⇧D *"never reached the app"* (BUGS.md:207).
  The driver was changed to retry. The cause is **UNKNOWN**.

### 2.2 Against macOS and Mac app conventions

- **VoiceOver.** *"By default, you can use either Caps Lock or Control-Option as the VoiceOver modifier"*
  ([Apple, VoiceOver keyboard commands](https://support.apple.com/guide/voiceover/control-your-mac-with-keyboard-commands-vo2681/mac)).
  With VoiceOver on, every ⌃⌥ chord can be taken by VoiceOver. That covers 13 shipping chords (§1.3) and every
  DEBUG hook. Which chords VoiceOver actually consumes was not tested (**UNKNOWN**).
- **The HIG on Control.** *"Avoid using the Control key as a modifier. The system uses Control in many
  systemwide features"*, and *"Prefer the Command key as the main modifier"*, *"Use the Option modifier
  sparingly"* ([HIG, Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)).
  Every shipping Manifold chord except the View menu's is ⌃⌥.
- **Window managers.** In Rectangle's defaults (`Rectangle/WindowAction.swift`, `alternateDefault`,
  [rxhanson/Rectangle](https://github.com/rxhanson/Rectangle)), ⌃⌥ + C, D, E, F, G, I, J, K, R, T and U, plus
  the arrows, =, −, Return and Delete, are all global hotkeys. Global hotkeys win over the app. Six of
  Manifold's are on that list:
  - **⌃⌥C** colour override
  - **⌃⌥E** export frame
  - **⌃⌥G** vectorscope graticule
  - **⌃⌥R** render-layer A/B
  - **⌃⌥T** scopes tray
  - **⌃⌥D** SRT connect (DEBUG)

  Whether Rectangle installs this set or a Spectacle-style set at first launch is UNVERIFIED (research note).
  Either way, ⌃⌥ is the namespace window managers use.
- **⌘Q/W/O/,/H/M.** Manifold does not override any of them. ⌘O is used for its standard meaning.
- **Full screen.** ⌃⌘F is the system's (*"if supported by the app"*,
  [Mac keyboard shortcuts](https://support.apple.com/en-us/102650); HIG standard table). Manifold binds no other
  full-screen key. Esc passes through outside timecode entry (`TimecodeEntry.swift:404` applies only while
  entry is open).
- **Mission Control, Spotlight, input sources.** ⌃↑ and ⌃↓ are Mission Control and App Exposé; ⌘Space is
  Spotlight; ⌃Space and ⌃⌥Space switch input sources ([Mac keyboard shortcuts](https://support.apple.com/en-us/102650)).
  Manifold uses none of these. The arrow monitor passes ⌃ and ⌥ arrows through (`TimecodeEntry.swift:397-398`).
  ⌃←/→ for switching Spaces is not on Apple's page (UNVERIFIED), and Manifold does not use it.
- **Window tiling.** Fn-⌃F, Fn-⌃C and Fn-⌃arrows ([Arrange windows](https://support.apple.com/guide/mac-help/arrange-windows-mchl9674d0b0/mac)).
  Manifold has no conflict.
- **Layouts: backslash.** Key code 42 types something different per layout. This was measured locally with
  UCKeyTranslate during this audit; no web source was found.

  | Layout | Unshifted | Shift |
  |---|---|---|
  | US/ABC, British | \ | \| |
  | German | # | ' |
  | French | dead key | £ |
  | Italian-Pro | ù | |
  | Spanish | ç | |
  | JIS keyboard | ] (¥ is key 93) | } (UNVERIFIED) |

  Because the hold matches the physical key, it does work on every layout. But a help text or menu that says
  "\\" is wrong for German, French, Italian and Spanish users, and on JIS the physical key is labelled "]".
- **Layouts: digits.** On AZERTY the top-row digits need ⇧. Timecode entry still works, because ⇧ is allowed
  (`:397-398`) and the numeric keypad also works. Whether ⌘1–⌘4 work on AZERTY without ⇧ is **UNKNOWN**. The
  HIG says to let the system localise shortcuts.
- **Layouts: [ and ].** ⌥[ and ⌥] are physical keys 33 and 30, which carry Ü and + on German and ^ and $ on
  French. The position is stable but the label differs (not measured beyond the key codes).
- **Fn on laptops.** Home and End are Fn-← and Fn-→, and Page Up and Page Down are Fn-↑ and Fn-↓
  ([Mac keyboard shortcuts](https://support.apple.com/en-us/102650), text editing). Manifold binds none of these
  today. A scheme that uses Home/End needs an Fn-free alias.

---

## 3. Conventions users already know

Sources (the research worked from the primary documents):
- **R20:** [DaVinci Resolve 20 Reference Manual](https://documents.blackmagicdesign.com/UserManuals/DaVinci_Resolve_20_Reference_Manual.pdf). Page numbers are PDF pages.
- **PP:** Adobe Premiere Pro keyboard shortcuts. The current helpx page ([default-keyboard-shortcuts](https://helpx.adobe.com/premiere/desktop/get-started/keyboard-shortcuts/default-keyboard-shortcuts.html), read from the Wayback Machine on 2026-10-14) no longer lists playback rows. Those come from the [older page](https://helpx.adobe.com/premiere-pro/using/keyboard-shortcuts.html), Wayback 2024-05-30. helpx returned 403 to direct fetches.
- **FCP:** [Final Cut Pro keyboard shortcuts](https://support.apple.com/guide/final-cut-pro/keyboard-shortcuts-ver90ba5929/mac) and [Play media](https://support.apple.com/guide/final-cut-pro/play-media-ver90ba4ef0/mac).
- **QT:** [QuickTime Player keyboard shortcuts](https://support.apple.com/guide/quicktime-player/keyboard-shortcuts-and-gestures-qtpa4808515d/mac).

| Action | Resolve | Premiere | Final Cut Pro | QuickTime | Manifold today |
|---|---|---|---|---|---|
| Play / pause | Space (p2992) | Space | Space | Space | Space |
| Shuttle J/K/L | J/K/L; repeat J/L speeds up (p728-729) | J/K/L; ⇧J/⇧L slow | J/K/L; repeat speeds up | none | J/K/L; repeat doubles |
| Hold K + tap J/L = 1 frame | yes (p729) | UNVERIFIED | yes (Play media) | none | no (C11) |
| Hold K + hold J/L = slow play | yes (p729) | UNVERIFIED | yes, ½× | none | no |
| Frame step | ← / → (p728) | ← / → | ← / → | ← / → | ← / → |
| Larger step | ⇧← / ⇧→ = **1 s** (p728) | ⇧← / ⇧→ = **5 frames** | ⇧← / ⇧→ = **10 frames** | none | ⇧← / ⇧→ = 1 s (matches Resolve) |
| Start / end | Home / End (p728) | Home / End | Home / End, or Fn-← / Fn-→ | ⌥← / ⌥→ | none |
| Previous / next edit | ↑ / ↓ (p728) | ↑ / ↓ | ↑ / ↓ | ↑ / ↓ = **volume** | none |
| Mark in / out | I / O (p737) | I / O | I / O | none | **I = inspector** |
| Clear in / out / both | ⌥I / ⌥O / ⌥X (p737) | same | same | none | none |
| Go to in / out | ⇧I / ⇧O (p728) | same | same | none | none |
| Play in to out | ⌥/ (p730) | ⌥K | / | none | none |
| Loop | ⌘/ (p729) | ⌘L | ⌘L | ⌥⌘L | none |
| Full screen | ⌘F or P (manual contradicts itself, p23 vs p679); ⇧F full-screen viewer (p43) | ⌃` full screen; ` maximise frame | ⇧⌘F | ⌘F (Esc exits) | stock ⌃⌘F only |
| Zoom in / out | ⌘= / ⌘− (p2991) | = / − (timeline) | ⌘+ / ⌘− | ⌘+ / ⌘− | none |
| Fit / 100% | ⇧Z / ⌥⇧Z (p2991) | not found | ⇧Z / not found | ⌘3 Fit, ⌘1 Actual, ⌘4 Fill | ⌘0 Fit, ⌘1 100% |
| Add marker | M (p722) | M | M | none | none |
| Previous / next marker | ⇧↑ / ⇧↓ (p728) | ⇧⌘M / ⇧M | ⌃; / ⌃' | none | none |
| Bypass / before | ⇧D bypass grades (p504, p550); ⌘D disable node (p2987) | none found | ⌃⌘6 comparison viewer | none | \ hold (temporary) |
| Wipe / split | ⌘W wipe (p12); ⌥⌘W split (p3003) | none found | none | none | none |
| Grab still / export frame | ⌥⌘G (p12) | none found | none | none | ⌃⌥E |
| Scopes | ⇧⌘W (p552) | none found | ⌘7; ⌃⌘W waveform, ⌃⌘V vectorscope | none | ⌃⌥T |
| Timecode entry | Keypad digits go straight in; top row needs = first; leading + / − is relative (p732-733) | none found | ⌃P; = / − start relative entry | none | bare digits, + / − |
| Volume / mute | none found | none found | ⌃= / ⌃− ±1 dB | ↑ / ↓; ⌥↑ / ⌥↓ max / min | none |

What everyone agrees on:
- Space, J/K/L, ← / → and Home/End (QuickTime aside).
- I and O for marks, M for markers.
- ↑ / ↓ for edit points in the three NLEs.

Where they differ: the size of the ⇧-arrow step, loop, full screen and fit. Manifold's ⌘1 = 100% matches
QuickTime's Actual Size. Its ⌘3 (50%) and ⌘4 (25%) contradict QuickTime's ⌘3 Fit and ⌘4 Fill, and its ⌘0 Fit
matches no app surveyed.

---

## 4. Proposed scheme

### 4.1 Rules the scheme follows

1. **Bare keys for transport and viewing, matching the NLE core in §3.** These are dispatched by one monitor, so
   ⇧-arrows and holds work (C7, C11).
2. **⌘ (+⇧/⌥) for everything else, and every such action is in a menu.** It is then visible, appears in Help
   search, and follows the HIG's modifier advice.
3. **No ⌃⌥ for shipping actions.** ⌃⌥ stays as the namespace for DEBUG hooks only: they are invisible to users,
   and the clash with VoiceOver and window managers then hurts only developers.
4. **Device claims and blind cycles get no default key.** They can be bound in the shortcuts window.
5. **Keys are labelled by what the current layout prints**, never by a hard-coded glyph.

### 4.2 Action → key

| Action | Proposed | Rationale | Change from today |
|---|---|---|---|
| Play / pause | Space | All four apps | — |
| Shuttle reverse / pause / forward | J / K / L | Resolve, PP, FCP | — |
| Hold K + tap J / L: one frame | K+J / K+L | Resolve p729, FCP | new (monitor) |
| Hold K + hold J / L: slow play | K+J / K+L | Resolve, FCP | new; optional |
| Step one frame | ← / → | All four | — |
| Step one second | ⇧← / ⇧→ | Resolve's 1 s (p728). PP (5 frames) and FCP (10 frames) differ; the step size could be a setting | — |
| Go to start / end | Home / End, alias ⌥← / ⌥→ | Home/End in the three NLEs; ⌥←/⌥→ is QuickTime's and needs no Fn on a laptop | new |
| Timecode entry | 0–9, + / − (also = / _), Return, Esc | Matches Resolve's keypad and relative entry (p732-733) and FCP's = / − | — |
| Loop playback | ⌘L | PP, FCP. QuickTime uses ⌥⌘L, Resolve ⌘/ | new (if the UI exposes loop) |
| Mark in / out | I / O, reserved | All three NLEs; needed by the markers roadmap item | **I freed** |
| Add marker / previous / next | M / ⇧↑ / ⇧↓, reserved | M everywhere; ⇧↑/⇧↓ is Resolve's. Needs the monitor (C7). ↑/↓ alone stay free for edit points | reserved |
| Inspector | ⌘I | Frees I for Mark In (all three NLEs). That ⌘I means Inspector / Get Info on the Mac is UNVERIFIED: not in the sources above | **I → ⌘I** |
| File-name overlay | N | No surveyed transport key uses N | — |
| Keep controls visible (pin HUD) | ⌥⌘T, as View ▸ Always Show Controls | Frees Tab for keyboard navigation (C8). ⌥⌘T is the usual Show/Hide Toolbar key; this is UNVERIFIED, as the HIG table read for §3 did not cover it | **Tab → ⌥⌘T** |
| Scopes tray | ⌘7 | FCP's Show/Hide Video Scopes. Resolve uses ⇧⌘W. Clears the Rectangle ⌃⌥T clash | **⌃⌥T → ⌘7** |
| Per-scope toggles (CIE xy/u′v′, graticule, boxes, 709/P3/2020) | no default | Set-and-forget, and better on the scope's own controls. Bindable | ⌃⌥X/G/B/1/2/3 removed |
| Display transform: macOS / Reference / Bypass | ⌥⌘1 / ⌥⌘2 / ⌥⌘3 on the Color menu items | ⌘ main + ⌥ secondary (HIG); sits next to the ⌘1–⌘4 sizes without colliding | new |
| **Hold to compare** (other of macOS ↔ Reference) | **hold D** | See 4.3 | **\ → D** |
| **Hold to compare against Bypass** | **hold ⇧D** | ⇧D is Resolve's Bypass (p504, p550): same meaning, held instead of toggled | **⇧\ → ⇧D** |
| Raster 100% / 75% / 50% / 25% / Fit | keep ⌘1 / ⌘2 / ⌘3 / ⌘4 / ⌘0 | ⌘1 matches QuickTime. **Decision for Robbie:** for QuickTime parity, ⌘3 = Fit, which would push 50% and 25% to other keys | keep, or Fit → ⌘3 |
| Zoom in / out a step | ⌘= / ⌘− | Resolve, FCP, QuickTime | new; only if raster gets a step |
| Full screen | ⌃⌘F (system) | macOS standard. QuickTime's ⌘F could be added as an alias; **Robbie's call** | — |
| Export frame | ⌥⌘E, as File ▸ Export Frame | ⌘-based and visible. Resolve's grab still is ⌥⌘G | **⌃⌥E → ⌥⌘E** |
| Colour override: cycle | no default | Blind cycling of interpretation is risky; the menu shows the choices. Bindable | **⌃⌥C removed** (release notes mention it) |
| Colour override: reset to Auto | no default | BUGS.md:112 leaves it to the registry. A reset is cheap to bind, but ⌥⌘0 would read as a display-transform sibling | new, bindable |
| Audio offset ±1 / ±10 ms (live) | ⌥[ / ⌥], ⇧⌥[ / ⇧⌥] | Keeps the measured physical-key matching | — |
| DeckLink output start / stop | no default | Device claim (rule 4; `ContentView.swift:572-576`) | **⌃⌥O / ⌃⌥⇧O removed** |
| NDI connect first source | no default | Device claim | **⌃⌥N removed** |
| Disconnect live source | no default; one menu item | Collapses C1's three keys into one action | **⌃⌥⇧N removed** |
| Volume up / down, mute | no default | No shared convention (QuickTime ↑/↓ clashes with the NLEs' edit keys) | — |
| Keyboard Shortcuts window | menu item only (Help ▸ Keyboard Shortcuts…) | No surveyed convention | new |
| Stock items (⌘N/W/Q/H/M/,/O, Edit, ⌃⌘F) | unchanged, reserved | Standard; never rebindable | — |

**DEBUG hooks.** These stay on ⌃⌥, registered as `debug` actions. They are not rebindable and not shown unless
`DebugMenuGate` is on:
- Profile: ⌃⌥A, ⌃⌥⇧B, ⌃⌥W, ⌃⌥H, ⌃⌥⇧H, ⌃⌥⇧E, ⌃⌥D, ⌃⌥⇧D.
- Debug configuration: ⌃⌥L, ⌃⌥⇧L, ⌃⌥P, ⌃⌥U, ⌃⌥S, ⌃⌥[, ⌃⌥].

**⌃⌥R (render-layer A/B) moves from shipping to DEBUG** (C2). The open question in BUGS.md:754 (should a
public build carry ⌃⌥H / ⌃⌥D / ⌃⌥⇧E at all) is unchanged by this audit.

### 4.3 The hold-to-compare key

Option A: **hold D / ⇧D (recommended).**
- It is matched by character, so it is labelled "D" on every Latin layout.
- ⇧D already means "bypass" to a Resolve user.
- It must match the modifiers exactly: none, or ⇧ only. That also fixes C3.
- D does not collide with ⌃⌥D, which is DEBUG and differs by modifiers.
- Cost: Resolve's ⇧D is a toggle and this is a hold.
- Bare D is Overwrite in FCP and Select clip in Premiere. Neither is in the §3 sources, so that is UNVERIFIED,
  and neither app is in front while Manifold is.

Option B: **keep the physical key 42**, with modifiers matched exactly, and its label drawn from the current
layout (# on German, ç on Spanish, ] on JIS). Keeps the key that was tested in S2, but there is no convention
behind it.

Either way, the reference/display toggles are the ⌥⌘1/2/3 menu items. The hold is for comparing; the menu is for
choosing.

### 4.4 Registry: one source of truth

- **`ShortcutAction`** is an enum with stable string IDs (`transport.playPause`, `color.holdCompare`, …). Each
  carries:
  - a title and a category;
  - a default `KeyBinding?`;
  - a **scope**: app, key window, window with source, file transport, live, entry open, or sheet;
  - a **dispatch kind**: menu, monitor, or hold;
  - flags: `debugOnly`, `rebindable`, `allowsBareKey`, and a gate closure (the existing `deck.gate.*`).
- **`KeyBinding`** stores the modifiers plus either a character or a physical key code, with the match mode
  explicit. This removes C9's hidden mix. Its display string comes from the current layout via UCKeyTranslate.
- **Storage.** Only overrides are stored, never the defaults: one dictionary under `manifold.shortcuts`,
  `{version, overrides: {actionID: binding | "none"}}`.
  - All reads and writes go through one function that reads the whole dictionary, changes one entry, and writes
    it back. CLAUDE.md: a `defaults write` replaces the dictionary wholesale, as happened with `streamBookmarks`.
  - Unknown IDs are preserved, so an older build does not drop a newer build's bindings.
  - Defaults stay in code, so changing a default reaches every user who has not overridden it.
- **Dispatch.**
  - Menu actions take `.keyboardShortcut(registry.binding(for:))`, so the menu always shows the live key.
  - One app-level monitor replaces `HoldToCompare` and the transport half of `TransportKeyMonitor`. It handles
    bare keys, ⇧-arrows, holds and K+J/L. It keeps the existing rules: key window only, decline while a text
    view is first responder, swallow during entry.
  - The hidden-button groups leave `ContentView`, which is at its type-checker limit (§6.7, comments at
    `ContentView.swift:572` and `HoldToCompare.swift:18-20`).
  - The per-window scoping from MULTIWINDOW_FINDINGS.md §3.1 is kept by resolving the key deck at dispatch.
- **Checks in tests.**
  - No two defaults share a binding in overlapping scopes.
  - No default uses a reserved system key.
  - Every menu-dispatched action is free of ⇧+arrow (C7).
  - Every action has a title.
  - These replace hand lists like `RasterSize.swift:113-116` (C6).

### 4.5 The Keyboard Shortcuts window

It should **show**:
- every non-debug action, grouped by category, with title, current key, default key and scope (e.g. "Live
  sources only");
- the key as the current layout prints it;
- a mark on customised rows.

It should **allow**:
- **Search** by action name, or by pressing a key to find what it does.
- **Rebinding** by recording a key press. Esc cancels recording, and Delete clears to "none".
- **Conflict warnings**, inline before saving:
  - Another action in an overlapping scope already uses the key: offer Replace, which unbinds the other action,
    or Cancel.
  - The key is reserved: refuse it. Reserved means ⌘Q/W/H/M/,/O, ⌘Space, ⌃Space, ⌃⌥Space, ⌃⌘F, ⌃↑/↓, ⌘Tab,
    ⇧⌘3/4/5, and Return and Esc during entry.
  - Warn, but allow: any ⌃⌥ chord (VoiceOver, Rectangle), Home/End/Page keys (need Fn on laptops), ⇧+arrow on a
    menu action (cannot work; route it to the monitor or refuse it), and a key whose character changes between
    layouts.
- **Reset**: one row, a category, or everything.
- **When the debug gate is on**, a separate read-only section lists the DEBUG hooks.

It should not offer import, export, or multiple presets in 1.0: no user need for them was found in this audit.

### 4.6 Decisions for Robbie

1. Scheme §4.2 as a whole. In particular, moving I → ⌘I, Tab → ⌥⌘T, ⌃⌥T → ⌘7, ⌃⌥E → ⌥⌘E, and removing the
   device-claim and ⌃⌥C defaults. ⌃⌥C is in the release notes.
2. The hold-to-compare key: D / ⇧D (A) or physical key 42 (B).
3. Raster keys: keep ⌘0 = Fit, or adopt QuickTime's ⌘3 = Fit.
4. Add ⌘F as a full-screen alias (QuickTime), or not.
5. ⇧-arrow step: fixed at 1 s (Resolve, today), or a setting.
6. Whether K+J/L hold gestures are in 1.0.
7. ⌃⌥R moves to DEBUG.

**Decided (Robbie, 2026-10-23):**
1. §4.2 as proposed.
2. Hold D; hold ⇧D compares against Bypass. Never while a text field has focus; never swallows ⌘D, ⌥D or any
   other modified D.
3. Raster keys stay ⌘1–⌘4 and ⌘0 = Fit.
4. ⌘F is a full-screen alias of ⌃⌘F.
5. The ⇧-arrow step stays fixed at 1 s.
6. K+J/L hold gestures are in 1.0.
7. ⌃⌥R moves to DEBUG.

---

## 5. The registry build: predictions (written 2026-10-23 20:48, before any build)

**Estimated run time:** 6 h, band 4–8 h, from these predictions to the results record.

**How it is measured.**
- No keystroke is ever sent to the app. Dispatch is tested in-process: `swift test` feeds synthesized `NSEvent`s
  through the same adapter and dispatcher the app's one monitor uses.
- In the running app (Profile, HEAD and tree), the measurements are:
  - Accessibility reads of the menu bar: each item's `AXMenuItemCmdChar` and `AXMenuItemCmdModifiers`.
  - Accessibility clicks on named elements.
  - The control set's exports.
- Apps are quit only by a Quit event to the bundle path. No screenshots.
- Defaults are read before any write, and every write sequence stops at its first failure. The snapshot leaves
  out licence keys, which are compared by presence only and never restored.

| # | Prediction | Pass band | Fail |
|---|---|---|---|
| P1 | **Unmoved keys dispatch HEAD's action.** In-process, each key is fed and must reach the same action as at HEAD: Space, J, K, L, N, ← → ⇧← ⇧→, ⌥[ ⌥] ⇧⌥[ ⇧⌥] (live only), 0–9 + − = _ (entry opens), and Return, Esc and Delete in entry. Debug hooks are checked with the debug predicate on: ⌃⌥W, ⌃⌥H, ⌃⌥⇧H, ⌃⌥⇧E, ⌃⌥D, ⌃⌥⇧D, plus the Debug-configuration set ⌃⌥L, ⌃⌥⇧L, ⌃⌥P, ⌃⌥U, ⌃⌥S, ⌃⌥[ and ⌃⌥]. In the app, the menus show ⌘O, ⌘1–⌘4, ⌘0, ⌃⌥A and ⌃⌥⇧B exactly as HEAD does | every key | any key mapped differently, or any menu key changed |
| P2 | **Moved keys work, and the old ones do nothing.** In-process: ⌘I, ⌥⌘T, ⌘7, ⌥⌘E, ⌥⌘1/2/3, ⌘F, ⌘L, Home/End and ⌥←/⌥→ reach their actions. I, Tab, ⌃⌥T, ⌃⌥E, \ and ⇧\ reach nothing, and the event passes through unconsumed. ⌃⌥X, G, B, 1, 2, 3, O, ⇧O, N, ⇧N, C and ⌃⌥R reach nothing with the debug predicate off; with it on, ⌃⌥R reaches the render-layer A/B. In the app, the menu items show ⌘I, ⌥⌘T, ⌘7, ⌥⌘E and ⌥⌘1/2/3. Export Frame, clicked by Accessibility, writes the export set | every key | any |
| P3 | **Hold to compare.** In-process: D down starts a hold on the other of macOS and Reference, and D up releases it. ⇧D compares against Bypass. Auto-repeats are consumed without restarting. ⌘D, ⌥D, ⌃D and ⇧⌘D are not consumed and start no hold. ⌃⌥D starts no hold, and is consumed only as the debug SRT hook. With a text view first responder, D passes through. A hold ends when the window resigns key | all cases | any |
| P4 | **K+J/L** (matching Resolve R20 p729 and FCP *Play media*). Holding K and pressing J or L steps −1 or +1 frame per press. Holding the J or L key past 300 ms with K down plays at −½× or +½×. Releasing J or L, or K, pauses. J, K and L alone keep HEAD's behaviour | all cases | any |
| P5 | **Rebinding.** An override (inspector → ⌥⌘I) is written through the registry's store in-process, and through defaults for the app run: read first, then written. The menu shows ⌥⌘I at launch and again after a relaunch. Reset All, clicked by Accessibility in the Keyboard Shortcuts window, puts the menu back to ⌘I without a relaunch and removes the key. Unknown IDs survive a round trip, and the JSON has sorted keys | exact | any |
| P6 | **Defaults.** A launch with no overrides writes no `manifold.shortcuts` key. After the runs, with each added `NSWindow Frame …` key read and then deleted, the domain is dictionary-equal to the snapshot, and the `streamBookmarks` hash is unchanged | equal | any difference |
| P7 | **Pictures.** The 20-file control set (I1's `control.txt`), exported through Export Frame, tree against HEAD: `.rgba16f`, `.v210` and `.v210.json` byte-identical, and PNG pixels and ICC equal. SDI is measured through the `.v210` export, which is the same convert the DeckLink path uses; no output run. The window is not measured (no screenshots), and `git diff` shows no renderer, shader, export or DeckLink file changed | 20 / 20 | any byte |
| P8 | **`swift test`.** All pass: HEAD's count plus the new registry and dispatch tests | all | any failure |
| P9 | **Warnings.** The Profile build's warning set (sorted, paths normalised) is a subset of HEAD's | ⊆ HEAD | any new warning |
| P10 | **The window.** Help ▸ Keyboard Shortcuts… opens it by Accessibility click. It lists every non-debug action in its categories, with key labels. With the debug gate off there is no debug section. Recording, conflicts and warnings are covered in-process (P1–P5) and by Robbie's checklist (§6) | as stated | any |

---

## 6. By-hand checklist for Robbie

These steps can't be done unattended: they need real key presses, and no keystroke was sent to the app in this
run. Use the Profile build, a file in one window, and the LG for anything you judge by eye. Tick each one and
note anything odd.

**Moved keys.** Each old key should now do nothing (or beep).
- [ ] ⌘I shows and hides the Inspector. Bare I does nothing.
- [ ] ⌥⌘T pins and unpins the overlay controls. Tab does nothing to them, and with Keyboard navigation on, Tab
      moves focus.
- [ ] ⌘7 opens and closes the scopes tray. ⌃⌥T does nothing.
- [ ] ⌥⌘E exports the frame to the Desktop. ⌃⌥E does nothing.
- [ ] ⌥⌘1 / ⌥⌘2 / ⌥⌘3 choose As macOS Shows It / Reference / Bypass, and the Color menu's checkmark follows.
- [ ] ⌃⌥R does nothing unless this is a debug build. In Profile it still toggles the AVFoundation layer
      (it's a debug hook, and Profile is a debug build).

**Hold to compare.**
- [ ] Hold D: the window shows the other of macOS and Reference, with the amber badge. Release: it goes back.
- [ ] Hold ⇧D: the window shows Bypass. Release: it goes back.
- [ ] ⌘D, ⌥D and ⌃D start no comparison.
- [ ] With the cursor in a text field (for example the stream bookmark sheet's name), D types a "d".
- [ ] Hold D, then click another app: the window goes back.
- [ ] \ and ⇧\ do nothing. ⇧⌘\ opens Show All Tabs.

**Transport.**
- [ ] Space, J, K and L work as before. Pressing L again speeds up.
- [ ] Hold K, then tap J or L: one frame back or forward per tap.
- [ ] Hold K and hold L: plays forward at half speed until you let go of L or K. The same with J, in reverse.
- [ ] ← / → step one frame; ⇧← / ⇧→ step one second.
- [ ] Home / End, and ⌥← / ⌥→, go to the first and last frame. On the MacBook Air, also try Fn-← and Fn-→.
- [ ] ⌘L turns looping on and off; the loop button turns green.
- [ ] Typing digits opens timecode entry. While it's open, Space, J/K/L, D and the arrows do nothing behind it.
      Esc cancels and Return goes.
- [ ] ⌘F enters and leaves full screen, like ⌃⌘F and fn-F.

**Live.**
- [ ] On a live stream, ⌥] / ⌥[ move the audio by 1 ms, and ⇧ with them by 10 ms.
- [ ] File ▸ Connect to First NDI Source and File ▸ Disconnect Live Source work.
- [ ] File ▸ Start / Stop DeckLink Output work. In a second window that doesn't own the devices, they beep.
- [ ] Color ▸ Next Color Interpretation and Reset Color Interpretation to Auto work on a file and on a stream.

**The Keyboard Shortcuts window** (Help ▸ Keyboard Shortcuts…).
- [ ] Search "scope": only the scope rows remain.
- [ ] Find by Key, then press ⌘7: only Show/Hide Scopes remains.
- [ ] Click Show/Hide Inspector's key and press ⌥⌘I. The row is marked customised, and View ▸ Show/Hide
      Inspector shows ⌥⌘I at once.
- [ ] Quit and relaunch: still ⌥⌘I.
- [ ] Record ⌘7 on Show/Hide Inspector. It asks "⌘7 is used by Show/Hide Scopes. Replace it there?". Cancel
      keeps both. Replace moves the key, and Scopes then has none.
- [ ] Record ⌘Q: refused ("used by macOS").
- [ ] Record ⌃⌥Y on Mute: accepted, with the VoiceOver / Rectangle warning.
- [ ] Record Page Up on Volume Up: accepted, with the Fn warning.
- [ ] Record bare Y on Show/Hide Inspector: accepted, with "Not shown in the menu". The View menu item then shows
      no key, and Y toggles the Inspector except while you type in a text field.
- [ ] Esc while recording cancels. Delete while recording removes the key (the row shows None).
- [ ] The row reset button, a category's Reset, and Reset All… (with its confirmation) all work. After Reset All,
      `defaults read com.graviton.manifold manifold.shortcuts` says the key does not exist.
- [ ] On a second keyboard layout (German), the audio offset rows read ⌥+ / ⌥Ü, matching the keys you press.
- [ ] With `defaults write com.graviton.manifold manifold.debugMenu -bool YES` (read it first), a read-only
      "Debug hooks" section appears. Remove the key afterwards.

---

## 7. Results (built and run unattended 2026-10-23, base `9e7c9fc`, not committed)

**Estimated** 6 h (band 4–8). **Actual** about 1 h, from the predictions (20:48) to this record (21:40): outside the
band, on the short side. The estimate assumed the window and the dispatcher would need several build rounds; they
needed four, all small.

**How it ran.**
- No keystroke was sent to the app, and no screenshots were taken.
- Every quit was a Quit event to the bundle path. One run that left a confirmation sheet open timed out after
  30 s, and the driver ended it by PID.
- HEAD was built from a worktree in the scratchpad.
- The driver (adapted from I1's), menu dumps, logs and exports are in the session scratchpad, under `run/`.

| # | Measured | Verdict |
|---|---|---|
| P1 | **In-process:** every unmoved key reaches HEAD's action. Those are Space, J, K, L, N, ← → ⇧← ⇧→, ⌥[ ⌥] ⇧⌥[ ⇧⌥], digits, + − = _ opening entry, and Return / Enter / Esc / Delete / ⌦ in entry. With the predicate on, all 14 debug hooks also reach their actions (`KeyDispatchTests`). **In the app:** an Accessibility read of every menu item's key equivalent shows all 48 of HEAD's keyed items unchanged, including ⌘O, ⌘1–⌘4 and ⌘0 | **PASS** |
| P2 | **In-process:** ⌘F, Home, End, ⌥← and ⌥→ reach their actions. I, Tab, ⌃⌥T, ⌃⌥E, ⌃⌥X/G/B/1/2/3, ⌃⌥O, ⌃⌥⇧O, ⌃⌥N, ⌃⌥⇧N, ⌃⌥C, \ and ⇧\ reach nothing and pass through unconsumed, as does ⌃⌥R with the predicate off. ⌘I, ⌥⌘T, ⌘7, ⌥⌘E, ⌥⌘1/2/3, ⌘1, ⌘0, ⌘L and ⌘O fire their items through a real `NSMenu`'s own key matching (`testMenuKeysFireThroughAnNSMenu`). **In the app:** the menus carry 8 new keyed items: File ▸ Export Frame ⌥⌘E; View ▸ Show/Hide Inspector ⌘I, Show/Hide Scopes ⌘7, Always Show Controls ⌥⌘T, Loop Playback ⌘L; Color ▸ the three transforms ⌥⌘1/2/3. File ▸ Export Frame, clicked by Accessibility, wrote `.png`, `.rgba16f`, `.v210` and `.v210.json`, byte-identical to the button's export of the same file | **PASS** |
| P3 | In-process: D holds and releases; ⇧D compares against Bypass; repeats are swallowed. ⌘D, ⌥D, ⌃D, ⇧⌘D, ⌥⇧D, ⌃⌥D, ⌃⇧D and ⌥⌘D are neither consumed nor held (⌃⌥D reaches only the SRT hook, and only with the predicate on). With a text view first responder everything passes through. A missed key-up and a reset (window not key) both end the hold. "Nothing to compare" lets the key go on | **PASS** (in-process; by hand in §6) |
| P4 | In-process: K held + J/L steps −1 / +1 per press, with no shuttle. K held + L held past 300 ms plays at +½×, and releasing L stops it; the same with J at −½×; releasing K stops it too. J, K and L alone keep HEAD's behaviour, including a held L ramping | **PASS** (in-process; by hand in §6) |
| P5 | `manifold.shortcuts` written once (read first) with inspector → ⌥⌘I. Two launches both show View ▸ Show/Hide Inspector ⌥⌘I, and the log says "some customised". In the Keyboard Shortcuts window, Reset All… then the sheet's Reset All (Accessibility clicks) changed the menu to ⌘I in the same run, with no relaunch, and removed the key. In-process: sorted-key JSON is byte-exact, unknown IDs and top-level keys survive, an unreadable value is never overwritten, and an override equal to the default is not stored | **PASS** |
| P6 | No launch without overrides wrote `manifold.shortcuts`. After the runs, the only added keys were `NSWindow Frame …` (19 in all, one of them `keyboard-shortcuts`), with none changed or removed. Each was read, then deleted, stopping at the first failure. The domain is dictionary-equal to the snapshot (1525 keys, plus the 3 licence keys, checked for presence only and never restored), and `streamBookmarks` is still `4466c076` | **PASS** |
| P7 | The 20-file control set (I1's `control.txt`), exported through the Export frame button: `.rgba16f`, `.v210` and `.v210.json` are byte-identical, and PNG pixels and ICC are equal, **20 / 20**. The window was not measured (no screenshots). No renderer, shader, export or DeckLink file is in the diff (`git diff --stat`). The tagged log lines are identical except HEAD's `[COMPARE] … monitor installed` replaced by `[SHORTCUTS] key monitor installed`, and one more `[CHAIN] Source: no source` at startup, a launch-timing line I1 also saw between HEAD runs | **PASS** |
| P8 | `swift test`: **588 / 588** (HEAD 540, plus 48 in `ShortcutRegistryTests`: 26 registry, 22 dispatch) | **PASS** |
| P9 | Profile warnings (paths and line numbers normalised, from a clean rebuild of the app target): HEAD 12 distinct, tree 11, every one in HEAD's set. The one that went is HEAD's `HoldToCompare.swift` "`NSEvent` to `Sendable`", because its monitor was removed | **PASS** |
| P10 | Help ▸ Keyboard Shortcuts… opens the window. Its outline has 62 rows: 8 categories and 54 actions, each with its key as this layout prints it (for example "D (hold)", "⇧D (hold)", "⌥⇧]", "None"). There is no debug section with the gate off | **PASS** |

### Findings

1. **⇧⌘\ is Show All Tabs, measured** in the menu bar (an Accessibility read of HEAD). HEAD's backslash monitor would
   have swallowed it with a source loaded (audit C3). The dispatcher matches exact modifiers, so this cannot happen
   with D.
2. **Enter Full Screen shows fn-F in the View menu**, not ⌃⌘F. Both are the system's; ⌘F is the alias Robbie asked
   for.
3. **A SwiftUI `Button` in a List row exposes no title to Accessibility** (measured: only `AXHelp`). VoiceOver would
   not have said the key. The window's key buttons now carry an accessibility label and value. The same is true of
   the window's other buttons, which is why Reset All… also carries a tooltip.
4. **After a run ended by PID, the next launch restored only the Keyboard Shortcuts window**, with no Manifold
   window. That is window restoration, not defaults. The next launch that opened a file was normal.
5. **Behaviour that is deliberately not HEAD's:**
   - Toggles (Space, N, the view toggles) ignore auto-repeat. Whether HEAD's hidden buttons repeated was never
     measured (**UNKNOWN**).
   - A hold now needs the deck's window to be key.
   - Device and interpretation menu items are always enabled, and beep when the window cannot act. A disabled key
     beeped too.
   - Timecode entry swallows D, as it swallows every bare key.
6. **Old key names are left in comments of files kept out of the diff on purpose**, so that P7's "no renderer,
   shader or DeckLink file changed" holds: `MetalVideoRenderer.swift`, `PassthroughShader.metal`, and
   `DeckLink/DeckLinkService.swift`. Comment-only names also remain in `NDI/NDIService.swift`, `NDI/NDIBridge.h`,
   `Live/LiveSource.swift`, `Live/SyntheticLiveSource.swift`, `Live/LiveVideoDecoder.swift` and `HLS/HLSClient.swift`.
   Every user-visible string that named a removed key now follows the registry: the CIE and vectorscope gear
   headings, the Color control's tooltip, and the control bar's tooltips.
7. **Not measured, and left to §6:** any real key press, K+J/L in the app, recording, conflict and warning lines,
   Find by Key, layout labels on a second layout, and the debug section.
