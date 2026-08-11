# Arc C — the draggable scope divider

**IMPLEMENTED.** Built as recorded below (the second option; the first stays rejected). The design
notes are kept because the rejected option is the one someone will re-propose.

Where it lives: `WindowChrome.trayHeight` (per-window state + persistence),
`ContentView.effectiveTrayHeight` / `clampedTrayHeight` / `scopeTrayDivider` / `DividerHandle` (the
control), `WindowSizer.maxChromeHeight(openingFor:)` (where it stops).

Three things the build learned that this document did not predict — each is commented at its site:

1. **The line you grab does not move.** The picture's size is fixed by the window's WIDTH, so the
   video/tray boundary is pinned at `videoHeight` below the window's top edge. What moves is the
   window's BOTTOM. The usual split-pane sign is therefore unavailable, and dragging DOWN grows the
   tray so that the only moving edge travels with the pointer.
2. **A SwiftUI `DragGesture` cannot own this drag.** `isMovableByWindowBackground = true` makes
   AppKit start a window drag on mouse-down first — measured: the divider moved the window from
   y=242 to y=30 and never touched the tray. `DividerHandle` overrides `mouseDownCanMoveWindow`.
3. **Clamping only during the drag is not enough.** A stored height that no longer fits (mode
   switch, smaller display) has to be clamped on USE, and `sizeToSource` had to stop charging chrome
   against the picture's opening budget — it was shrinking a 1920×1080 source to 1163×654 at launch.

Not done in this pass: **no Settings control for the default.** The last-writer-wins seeding means
the default is simply the last height any window was left at, which needs no separate UI; add one
only if a discoverable reset turns out to be wanted.

## The invariant this must not break

> **CHROME NEVER REDUCES THE VIDEO'S SIZE.** The single exception is the screen cap, where the
> display genuinely cannot fit the window.

Stated in full in the `VideoBox` header in `App/WindowSizer.swift`, where it is enforced by scope
rather than by convention, and restated at `ContentView.body`, which is the layout half. Everything
below is a consequence of it.

## The design — the divider sets the TRAY height; the window grows to match

A horizontal handle between the video region and the scopes tray. Dragging it sets the tray's
height. The window's height follows:

    contentH = contentW / videoAspect + chromeH        (chromeH includes the new tray height)

so **the picture never changes size while the divider moves.** The window's bottom edge follows the
drag; the video is untouched. The divider **stops** when the window cannot grow any further — i.e.
at the screen cap — rather than continuing and taking the difference out of the picture.

That stop is the whole design. It is honest (the user can see the window has run out of screen), it
needs no new geometry (the existing `constrainedContentSize` cap already produces it), and it
refuses the one thing that would violate the invariant.

### Why the window grows rather than the picture shrinking

It is the same rule Arc B already enforces everywhere else: chrome is additive. A divider that
resized the picture would make "how tall are my scopes" and "how big is my picture" the same
control, which is exactly the coupling Arc B removed.

## REJECTED — redistributing within a fixed window

The obvious alternative: hold the window height constant and re-apportion it between the video and
the tray, so dragging the divider down grows the scopes and shrinks the picture.

**Rejected. It reintroduces pillarboxing through the back door — the exact thing Arc B removed.**

The mechanism is worth spelling out, because the option looks harmless:

1. The window's height is fixed, so growing the tray shrinks the video region's *height* only.
2. Its *width* is unchanged, so the region's aspect ratio changes — it gets wider than the source.
3. `.aspectRatio(videoAspect, contentMode: .fit)` then fits a 1.78 picture into a wider box and
   **puts black down both sides**.

That is precisely the failure the arc exists to remove: with the old proportional tray at 33% of a
16:9-locked window the video's box became 2.65:1, the picture filled 67% of the width, and 16.5% of
the window was black down each side. A redistributing divider recreates it *continuously and under
the user's finger* — the pillars grow as you drag. It is the same bug with a nicer interface.

Note that "the picture shrinks a bit" is a symptom nobody reports. It reads as the window being
slightly off, not as a defect, which is why the invariant is enforced in the type system rather than
left to review.

## What it costs to build

`chromeHeight` (`ContentView`) already carries a non-constant term — `dockedBarHeight` is a measured
`@State` fed back from `onGeometryChange` — so a term the *user* owns is not a new architectural
category and the plumbing exists.

1. **`WindowChrome` gains `@Published var trayHeight: CGFloat`**, persisted, same last-writer-wins
   per-window seeding as `showTray`. Seeds from `WindowChrome.trayHeight`'s current value.
   ⚠️ `defaults.double(forKey:)` returns `0` for a missing key — the `bool(forKey:)` trick the other
   properties use does not transfer. Needs an explicit `object(forKey:) == nil` check or a fresh
   install gets a zero-height tray.
2. **`ContentView.chromeHeight` reads `chrome.trayHeight`** instead of the static. One line.
3. **Clamps.** Floor ≈ 120 pt (22 header + 20 inset + a plot that can still carry a graticule).
   Hard stop at the screen cap, so the picture never silently starts shrinking mid-drag.
4. **⚠️ THE PER-EVENT COST, AND THE REASON THIS WAITS.** A divider drag fires at the pointer's
   report rate — **measured at 72/s** during Arc B's window-resize testing — and each event runs
   `setGeometry` → `applyConstraint` → `window.setFrame(display: true)`. That is a programmatic
   window resize per event. `isResizable()` will **not** stop it: that guard tests
   `window.inLiveResize`, and a divider drag is not a window live-resize. This path must be sound
   before the divider is built on top of it.

## Sizing, for whoever picks this up

At a 1920-wide window each tray slot is ~639 pt wide, but the vectorscope and CIE scopes are
`.aspectRatio(1, .fit)` and so are capped by the tray's height (~210 pt of plot at
`trayHeight = 204`). **The square scopes use about a third of their slot's width; the rest is black.**
Every point added to the tray is a point of vectorscope diameter until the tray reaches slot width —
around 670 pt at that window size. That is the range the divider needs to cover, and it is the
reason a single app-wide constant was never going to be right.

The waveform has a separate, lower threshold: its trace image is `waveformDisplayRows = 512` rows, so
below ~256 pt of plot height (≈298 pt of tray) it is being decimated rather than upscaled.
