# Raster size — how large the picture is drawn

**IMPLEMENTED.** The counterweight to the window-sizing arc: chrome is additive there, so a UHD file
with the scopes open asks for a window taller than most displays, and the screen cap then shrinks the
picture on the user's behalf. This is the control that lets them make that decision themselves.

⚠️ **NAMING.** `docs/ARC-C-SCOPE-DIVIDER.md` already claims the name "Arc C" for the draggable scope
divider. This work was also handed over as "Arc C"; the two are different arcs and this document
avoids the letter entirely.

Where it lives:

| Concern | File |
| --- | --- |
| The state, the readout's text, the View menu | `App/RasterSize.swift` |
| Per-window storage + seeding | `App/WindowChrome.rasterSize` |
| Percentage → window geometry | `App/WindowSizer` (`RasterRequest`, `rasterContentWidth`, `setGeometry`) |
| The readout, the measurement, the triggers | `App/ContentView` (`rasterReadout`, `drawnVideoPixels`) |
| Menu → key window | `DeckRegistry.keyDeck` / `setRasterSize` |
| The default for new windows | Settings ▸ Interface Options |

## The model

* **100% is one source pixel per source pixel.** A 3840×2160 file at 100% occupies 1920×1080 POINTS
  on a 2× display. The division by `backingScaleFactor` happens in exactly one place
  (`WindowSizer.rasterContentWidth`) and is the whole definition; removing it would draw each source
  pixel across a 2×2 block and label it 100%.
* **The percentage is measured against DISPLAY geometry** (`FrameEngine.displaySize`), not encoded
  pixels — it is a framing control, and display geometry is what the user sees. It is also the same
  value that shapes the window, so the picture cannot be sized against one shape while the window is
  built for another.
* **It sizes the VIDEO.** Chrome is still added below, so 50% with the tray open is a half-size
  picture and a full-size tray.
* **Fit to Screen is a MODE, not a one-shot** — it re-fits when the chrome changes, which is the only
  reading of "largest size that fits, chrome included" that stays true afterwards.
* **A manual edge-drag is permitted and produces `custom`.** No snapping to the nearest preset.
* **The screen cap remains the backstop** and is unchanged: `constrainedContentSize` is still the
  only place a picture is allowed to shrink.

## Decisions worth recording

**A View menu, not a control-bar item.** The bar already carries the transport, scrubber, two
readouts, volume, scopes, guides, captions, output and the inspector affordances, and it has to
survive a narrow window. Raster size is set a handful of times per session, and what a bar item would
really have bought — "what am I at right now" — is what the transient readout provides at the moment
it is wanted. The menu also carries the accelerators visibly, which no other shortcut in this app
does.

**`CommandGroup(after: .toolbar)`, not `CommandMenu("View")`.** SwiftUI already synthesizes a View
menu for a `WindowGroup`; a same-titled `CommandMenu` does not merge with it. Measured: the running
app's menu bar read `Apple, Manifold, File, Edit, View, View, Window, Help`.

**`automatic` is a real state, and it is the default.** It is the app's original opening rule (fit the
source into 80% of the visible frame, never past 1:1). Keeping it means this arc changes nothing about
how a window opens until the user asks it to, and it gives Settings a way back. It is deliberately not
in the View menu: the rule only acts when a source first sizes a window, so an item saying "do that
now" would have nothing to do.

**`custom` is never persisted.** It is the absence of a policy, not a size. The stored key keeps the
last size actually chosen, which is both the useful seed and the honest answer for the Settings
picker that reads it.

**No source, no policy — including Fit.** Fit can compute a width without a source and must still
decline. Measured: without that guard, relaunching with Fit stored opened the *empty* launch window at
the full visible frame, while a stored percentage (which cannot be computed without a source) left it
at the 1280-pt default — two opening sizes for a window in the same condition.

**Settings does not reach open windows,** unlike the Controls picker beside it. That one adopts
external writes because it is the only surface overlay-vs-docked has; raster size has a per-window
control, and `WindowChrome`'s own note says adopting a global write would then stomp a window's local
choice.

## The one place the picture pays for chrome, and why it is not a new exception

Under `fitToScreen` the picture is DEFINED as "whatever is left after the chrome", so the scope
divider's ceiling cannot be measured against the current picture — that is circular, and it produces a
stuck control (a fitted window is already at the cap, so the room left for chrome computes as exactly
the chrome already there: the divider could shrink and never grow). Under Fit only,
`maxChromeHeight` measures against the SMALLEST legal picture instead, and the tray's growth is paid
for by the picture **through the existing screen cap** — route 2 in `WindowSizer`'s header, the one
documented exception. It is not a second exception, and it is what the user asked for when they chose
a size defined as "as large as fits, chrome included".

## Measured, on a 3840×2160 display at 1× (scale=1.0), tray open at 366 pt

| Action | Asked | Window content | Video |
| --- | --- | --- | --- |
| UHD 3840×2160 @ 100% | 3840 | 3135×2130 | 3135×1763 — screen cap, reported as such |
| UHD @ 75% | 2880 | 2880×1987 | 2880×1620 |
| UHD @ 50% | 1920 | 1920×1447 | 1920×1080 |
| UHD @ 25% | 960 | 960×907 | 960×540 |
| UHD, Fit | unbounded | 3135×2130 | 3135×1763 (82%) |
| Anamorphic 2048×858 encoded / 2389×858 display @ 100% | 2389 | 2389×1225 | 2389×858 |
| HD 1920×1080 @ 25% | 480 | 720×772 | 720×405 — window minimum, reported as such |

50% of a UHD source on a 1× display is the same geometry 100% produces on a 2× display: 1920 points,
3840 device pixels drawn from a 3840-pixel source.

## Two bugs this work found, both in code it reused

1. **`.greatestFiniteMagnitude` is finite.** `isFinite` waved the unbounded Fit request through to
   `Int(_:)`, which trapped. `WindowSizer.isUnbounded` is the test now. (Crashed on the first click of
   Fit to Screen.)
2. **A cancelled `try? await Task.sleep` falls straight through.** `.task(id:)` auto-hide timers were
   therefore clearing the message they had just been restarted for. This made the readout invisible
   (it publishes twice within ~10 ms) and it was already latent in `connectErrorBanner`, where two
   connect errors landing close together would wipe the second. Both now guard on `Task.isCancelled`.
