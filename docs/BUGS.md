# Manifold — known bugs

Shipping defects that are understood but not yet fixed. Each entry states what is wrong, why
nobody has reported it (if that is the interesting part), and what it blocks.

A FIXED entry stays here, marked, until the fix has been through a real session — the write-up is
what makes a regression recognisable, and deleting it the day the patch lands is how the same bug
gets rediscovered from scratch.

The file opens with a **pre-ship checklist** — work that is required before public launch but is
not a defect — and the numbered defect entries follow it.

---

# Pre-ship checklist

**Not defects.** Work that must happen before public launch, kept here because the entries below
are where the evidence for it accumulated. Each item states what "done" means, so it can be closed
rather than left open by default.

---

## ☐ PRE-SHIP: American English sweep across all user-facing text

**Status:** OPEN, required before public launch. **Raised:** 2026-08-27. **Scope:** user-facing
strings are **REQUIRED**; internal docs and comments are **PREFERRED**, for consistency.

British spellings have crept into the docs and **have reached shipping strings — confirmed, not
suspected.** Scanned 2026-08-27 across `App/` and `Packages/` (excluding `ThirdParty/`):

| where | line hits | verdict |
|---|---|---|
| inside a SwiftUI user-facing construct (`Text`, `Label`, …) | **5** | **REQUIRED** |
| other string literals, several user-visible | **15** | **REQUIRED** where user-visible |
| `NSLog` / `print` diagnostics | 4 | required-ish — testers read these |
| comments and prose in source | 243 | preferred |
| `docs/*.md` | 90 | preferred |
| `scripts/` | 12 | preferred |

Word frequency in `App/` + `Packages/`, highest first — **note that `colour` is not the biggest
one**, which is why a `colour`-only sweep would miss most of it:

`licence` 82 · `colour` 64 · `behaviour` 30 · `centre` 26 · `honour` 22 · `grey` 17 ·
`recognis*` 14 · `optimis*` 7 · `analys*` 6 · `defence` 3 · `normalis*` 2 · `serialis*` 2 ·
`synchronis*` 2 · `minimis*` 1 · `initialis*` 1 · `artefact` 1

**The list to check is not closed.** Beyond the obvious pairs (colour/color, licence/license,
behaviour/behavior, normalise/normalize, catalogue/catalog, grey/gray, centre/center,
analyse/analyze, initialise/initialize, artefact/artifact) the whole **`-ise`/`-isation` family**
is in play — `recognise`, `organise`, `optimise`, `customise`, `serialise`, `visualise`,
`synchronise` — plus `-our` words (`honour`, `favour`, `flavour`) and `defence`. This file's own
introduction contains `recognisable`.

### The confirmed user-facing hits

Required. These are what a customer reads:

- `App/AboutWindow.swift:586` — `Text("Licences").tag(Tab.licences)` — an About-panel **tab name**
- `App/AboutWindow.swift:642` — `Text("Full licence texts are under “Licences” above.")`
- `App/AboutWindow.swift:699` — `Text("All licences")` — a picker entry
- `App/AboutWindow.swift:619` — the missing-licence-text warning
- `App/LicenseManager.swift:826` — `Label("Your licence couldn’t be read", …)` — an **error state**
- `App/LicenseManager.swift:618` — *"Your stored **licence** key could not be verified. Please
  re-enter it, or contact support."* — an **error message**, and the most visible of the lot
- `App/DiagnosticsExport.swift:689,692` — `"no colour profile"` / `"      colour profile: …"`,
  which land in every diagnostics report a tester sends

### ⚠️ DO NOT BLANKET-REPLACE. The identifiers are already American and must not move.

The direction is **British → American ONLY**, and **not inside symbol names, file paths, or
third-party API names**. The codebase is full of correctly-American identifiers that a global
substitution would corrupt — measured counts of tokens that must be left alone:

`color` 133 · `license` 101 · `colorimetry` 94 · `colorspace` 57 · `Color` 56 · `NDIColorInfo` 44 ·
`CGColorSpace` 30 · `center` 25 · `licenseType` 20 · `LicenseManager` 20 · `colorMatrixCode` 19 ·
`setSourceColorSpace` 18 · `colorPrimariesCode` 17

Also off-limits: `NDIColorimetryOverride`, `colorSpace`, `docs/COLOR_MANAGEMENT_FINDINGS.md`,
`docs/color-fixtures/`, `App/Licenses/`, `App/LicenseManager.swift`, `App/NDI/NDIColorInfo.swift`,
and every `LICENSE` / `LICENCE` filename inside `ThirdParty/` and `App/Licenses/` — those are
third-party artifacts and their names are part of the licence obligation, not our prose.

**`AboutWindow.swift:347` is the trap in one line**, and worth reading before starting:

> `+ "licence to take it under — WE TAKE APACHE-2.0. The upstream LICENSE file "`

The first word is our prose and **must change**; `LICENSE` is a filename in someone else's
repository and **must not**. A regex cannot tell them apart. `App/LicenseManager.swift` is the
same hazard at file scale: an American filename and American identifiers throughout, wrapping
British user-facing strings.

**So: change prose, leave code.** Every hit gets looked at.

### Surfaces to cover

Menu items · error and alert messages · tooltips and `.help(…)` · the About panel (including the
attribution and licence tiers) · the diagnostics export · release notes · the Stream Sources and
inspector labels · the manual, when it exists.

### Known doc hits to fix with it

`docs/BUGS.md` alone: **"centre channel" in the downmix entry → "center channel"** (`:1015`,
`:1053`, `:1094`), plus `colourist` (`:863`) and `re-centred` (`:61`).

**Done means:** the scan above returns zero hits in user-facing strings, and the remaining source
and doc hits have been converted or consciously left with a reason. Re-run the scan to confirm
rather than declaring it finished.

---

## ☐ PRE-SHIP: dev-path audit — the ungated debug triggers

**Status:** OPEN, required before public launch. **Raised:** 2026-08-27, out of the
`MANIFOLD_CONFIG_DEBUG` gating work.

Every trigger that reaches a `LiveClock` setpoint mutator is now behind `#if
MANIFOLD_CONFIG_DEBUG` — ⌃⌥L, ⌃⌥⇧L, ⌃⌥P, ⌃⌥U, ⌃⌥S, ⌃⌥[ and ⌃⌥] — and that was done because
Profile defines `DEBUG`, so `#if DEBUG` never gated anything in a tester's hands. **Six triggers
in the same hidden group were deliberately left ungated** because none of them touches clock
state, and removing them is a product decision rather than a safety one:

- **⌃⌥W** — libdatachannel link smoke test. Inert; writes a log line.
- **⌃⌥⇧E** — exports the next decoded WHEP frame to a PNG.
- **⌃⌥H / ⌃⌥⇧H** and **⌃⌥D / ⌃⌥⇧D** — connect/retire WHEP and SRT through `DeckRegistry`, i.e.
  the same funnel the shipping menu already uses. They are speed paths over saved bookmarks, not
  new capability.

**Decide before launch whether a public build should carry them at all.** The gate to use is
`MANIFOLD_CONFIG_DEBUG`, not `#if DEBUG` — see the comment at `ContentView.syntheticLiveShortcuts`
for why, and do not "simplify" it back.

**Also on this list:** `LiveClock.setDepths(startup:target:)` is `public` and documented *"NOT for
production paths"*. It is now only reachable from the gated ⌃⌥S, but nothing in the type system
says so.

---

## Live sources never publish their frame size, so every stream is framed as 16:9

**Status:** FIXED 2026-08-11 (see "What landed" below). **Found:** 2026-08-10, during the
window-sizing audit. **Blocked:** the window-sizing arc (Arc B).

`engine.displaySize` is nil for every live source. NDI, WHEP and SRT all push decoded frames
straight into the shared renderer and never set it — the only writers are the file paths:

- `FrameEngine.swift` — set on AVFoundation load, and in `applyLibavMetadata` for the MXF/libav
  path; cleared to nil on stop.
- `AVPlayerEngine.swift` — same, for the AVPlayer engine.

Two things read it, and both degrade quietly:

1. `ContentView.videoAspect` falls back to **16:9** whenever `displaySize` is nil. So the video
   rect, and with it the framing-guide overlay and the caption overlay (both attached to that
   rect), are laid out for a 16:9 picture regardless of the stream's actual shape.
2. `WindowConfigurator.updateNSView` returns early on a nil `displaySize`, so a streaming window
   gets **no aspect lock at all** and keeps whatever shape it last had.

The picture itself is not stretched — the CAMetalLayer's `drawableSize` is set from the pixel
buffer, so the decoded frame is scaled into whatever rect SwiftUI computed. The bug is that the
rect is the wrong shape: a portrait or 4:3 stream is letterboxed inside a 16:9 box instead of
being framed to its own aspect, and the guides and captions land on the wrong lines.

**Why nobody has reported it:** every stream tested to date has been 16:9, which is exactly the
fallback. The bug is invisible until someone points a phone-shaped or SD source at it.

**One correction to the diagnosis above.** `displaySize` was NOT "cleared to nil on stop" —
`FrameEngine.stop()` cleared `duration`, `tcInfo`, `hasMedia` and `currentURL` and left
`displaySize` standing. Only `abandonLoad` cleared it. So on a deck that had a file open, a stream
takeover did not leave the size nil at all: it left the DEPARTED FILE's size in place, and the
window locked to a 4:3 file's aspect over a 16:9 stream. Worse than the nil case, because it looks
deliberate.

**What landed (2026-08-11).**

- `App/Live/LiveDisplaySize.swift` — one shared latch, mirroring `onWillActivateStream`: the
  transports state a size from their own threads, `DeckRegistry` routes it to the HOST deck's
  engine. One object rather than three hooks because `LiveSource` already guarantees one live
  source and the registry one host deck. Carries a generation counter so a size hopping to main
  cannot land after the teardown that retired it.
- `FrameEngine.setLiveDisplaySize(_:)` — the way in from outside; the file paths still inspect and
  publish from within. `stop()` now clears `displaySize`, for the reason its own comment already
  gives about `duration`/`tcInfo`.
- NDI publishes per FRAME (`xres`/`yres` live on the frame; a source switch rebuilds the receiver
  without a disconnect). WHEP and SRT publish per DECODED BUFFER, after the active guard — not from
  the format description, which an in-band SPS change can move under them.
- `WindowConfigurator` now compares the aspect as a RATIO. It compared raw sizes, so any change of
  RESOLUTION re-locked and re-centred the window — harmless at one value per file open, not
  harmless when a sender switches spatial layer mid-stream.

**Still assumed: SQUARE PIXELS.** The file value is `naturalSize × preferredTransform` —
rotation-corrected, not PAR-corrected — and the live value is the decoded buffer's geometry, which
is the honest equivalent. Of the three transports, WHEP genuinely cannot do better (SAR is in the
SPS VUI and the RTP depacketizer does not parse the VUI); the other two could, and neither is
plumbed: NDI's `NDIlib_video_frame_v2_t.picture_aspect_ratio` is not exposed by `NDIBridge`, and
`codecpar->sample_aspect_ratio` is not in `ManifoldSRTVideoFormat`. Both call sites say so.

---

## A file's first frame is presented before the layer knows what colour it is

**Status:** FIXED 2026-08-11. **Found:** 2026-08-11, from the "sometimes a file opens looking flat
and lifted, then snaps right on playback" report.

`metalLayer.colorspace` and `wantsExtendedDynamicRangeContent` were set ONLY from
`.onChange(of: engine.metadata)`. `metadata` comes from a detached inspection Task that the load
path spawns and never awaits — its own track load, frame rate, data rate, a SECOND open of the file
through libav for HDR10, audio tracks, text tracks, timecode, chapters, common metadata — and even
once it lands, `.onChange` runs a SwiftUI update pass later. Frames meanwhile come from
`beginReading`, at the bottom of the same function. Whoever got there first decided what the first
frame was drawn through.

**Why it looked like a gamma error, and why it stuck.** A `CAMetalLayer` applies its colorspace at
PRESENT time. So the wrong state is not a flash — the presented drawable keeps the interpretation it
was presented under, and nothing in a paused deck presents again. With no colorspace at all the
rgba16Float drawable is read as LINEAR, which lifts the whole picture: flat, milky, log-like.
Playback was the fix because playback is a new present.

**Measured, from outside the app** (step-wedge fixture, screen captures sampled with no ColorSync,
mid-grey patch, on the LG TV SSCR2 profile):

| | 0.10 | 0.19 | 0.50 | 1.00 |
|---|---|---|---|---|
| correct (PQ-tagged file, settled) | 13.28 | 38.17 | 244.69 | 255.00 |
| first frame, race lost | 79.03 | 112.17 | 179.05 | 254.89 |
| …after 15 s | 79.03 | 112.17 | 179.05 | 254.89 |
| …after moving the window | 79.03 | 112.17 | 179.05 | 254.89 |
| …after clicking ▶ | 13.28 | — | — | — |

⚠️ **A WINDOW NUDGE DOES NOT CORRECT IT** — the obvious test, and it fails. Re-compositing a window
is not re-presenting its drawable. Only a new present applies a newly-installed colorspace, which is
why the symptom is specifically "corrects on playback" and not "corrects when you touch it".

**Reproducing it on demand.** The race is normally won or lost by luck (2 of 6 launches, and 0 of 6
once the page cache was warm — which is the "not every time"). It becomes deterministic, 5 of 5, if
`MediaInspector.metadata` is given real work: `docs/color-fixtures/wedge.mov` re-tagged PQ
(`setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc`) with **24 audio tracks
muxed in**, opened with autoplay OFF. Multi-track masters are ordinary for this audience, so this is
a realistic file and not a contrived one.

**What landed.**

- `FrameEngine.onSourceColorTags` — a direct main-actor callback, wired per deck in
  `DeckRegistry.configure` beside `onVideoFrame`/`onFlush`. Called from `loadAsset` at the point the
  video track's format description is in hand (the one the range determination already loads) and
  BEFORE `beginReading`, which is the only thing that can produce a frame; and from
  `beginLibavReading` after `source.open()` for the MXF path, before its pump is armed.
- `MediaInspector.colorCodes(for:)` — the codes alone, DELEGATING to the same `colorTags` the full
  inspection uses, so the early value and the inspector's value cannot drift apart.
- The layer's colour properties are now written **on the render thread only**, at the top of
  `performDisplayTick`, from a state handed over under `refreshLock`. Writing them from main inside
  a `CATransaction` was only ever accidentally safe: a transaction orders a mutation against the
  layer-tree commit, not against another thread inside `nextDrawable`. It becomes a live hazard now
  that a second colour change mid-session is ordinary (an NDI source switch, an in-band SPS change
  on WHEP/SRT).
- A `pendingRefresh` rides with every colour change, so a state that arrives late still reaches a
  frame that is already on screen instead of waiting for the user to press play.
- `stop()` and `abandonLoad` publish nil codes: a failed open, or an emptied deck, no longer leaves
  the previous file's colour space on the layer for the next source's first frame to be drawn
  through.
- `[EDR] colour state installed on the layer after N present(s) of this source` — ungated, like the
  rest of the `[EDR]` family. N is counted from the last `flush()`, i.e. from the source boundary,
  so it stays truthful for the second and third file opened into the same deck. `N > 0` on a fresh
  source means this regressed.

**Not covered by the measurement:** the EDR opt-in half. The build Mac's display reports
`headroom current=1.0000` — EDR is inert on it — so `wantsExtendedDynamicRangeContent` could not be
observed to do anything either way here. It is fixed by the same ordering change; it has not been
seen to matter on a display with headroom.

---

## ⚠️ UNCONFIRMED: scrub release jumps the picture once, on ProRes

**Status:** **FIXED 2026-08-27, awaiting confirmation from Joey — not reproduced in-house, so
the fix is verified against the MECHANISM, not against the report.** Tolerance mechanism REFUTED by
measurement 2026-08-27; staleness mechanism matches the report in full — magnitude and sign — and
is what was fixed.
**Reported:** 2026-08-27 by Joey on 0.6.2; **direction corrected by him the same day.** **Not
seen** on the build Mac. **Blocks:** nothing; it is a trust problem — a
colourist who sees the picture move after they let go stops believing the scrub.

**The report:** scrubbing a ProRes file, on release the picture jumps once — *"almost backs up a
frame"*. Timecode matches the picture after the jump.

⚠️ **CORRECTED 2026-08-27 — "BACKWARDS" WAS NEVER PART OF THE REPORT.** This entry was built
around *"consistently BACKWARDS"*, and that word came from a RETELLING of the report rather than
from Joey. Asked directly, he says the picture just jumps and **he cannot say which way**. The
phrase that IS his — *"almost backs up a frame"* — describes a MAGNITUDE, about one frame, and was
read as if it described a sign.

**Every conclusion this entry drew about direction was an artefact of that retelling**, including
the one that kept the staleness mechanism from being a complete account. See *"the direction is not
an anomaly"* below.

**⚠️ SEPARATE FROM the HDR scrub defect** — *"Scrubbing an HDR file collapses the picture to SDR
luminance"* below. Same gesture and the same overlay, two unrelated causes: this entry is about
WHICH FRAME is shown, that one is about HOW IT IS LIT. Fixing either does not fix the other. **A
single change was proposed to fix both — routing scrub preview through the real decode path — and
it is REJECTED on four grounds recorded in that entry.** Read them before proposing it again.

### The reading that SURVIVED measurement: PREVIEW ACCURACY, not a seek bug

Timecode agreeing after the jump means the final seek lands where it was asked to. So the frame
the user ends on is the correct one, and the frame they were looking at during the drag was not.
Nothing is wrong with the seek; the scrub preview is the inaccurate half. That much holds.

⚠️ **But the original FORM of this reading — "the preview was running a frame AHEAD of the
requested time and the release corrected it" — is refuted below.** On ProRes the preview is the
exactly correct frame *for the time it was asked for*. What is wrong is that it was asked for a
STALE time and never asked again. **The preview LAGS the drag; it does not lead it.**

The readout corroborates this rather than contradicting it. During a drag the timecode is driven
by `FrameEngine.scrubSeek(to:)`, which does **no decode at all** — it assigns `currentTime =
clamped` and returns. So the readout tracks the slider exactly while the picture is whatever the
preview generator chose to hand back. On release `exactSeek` goes to that same `scrubValue`, so
**the timecode does not move at all** — only the picture does. "Timecode matches the picture after
the jump" is exactly the signature this predicts.

⚠️ **STILL UNCONFIRMED AS A WHOLE.** The mechanisms below are measured; the DEFECT is not
reproduced. The staleness figures come from replaying the real throttle gates against a synthetic
drag at measured generator latency — that is an analysis of the shipping logic, **not an
observation of the running app**. No frame-accurate capture of Joey's session exists.

### The two paths ARE different mechanisms — CONFIRMED FROM THE CODE

Checked rather than inferred from the factory's existence:

| | scrub preview | release |
|---|---|---|
| trigger | `Slider` `set:` → `requestScrubPreview(at:)` (`ContentView.swift:2884`) | `onEditingChanged(false)` → `engine.exactSeek(to:)` (`ContentView.swift:2525`) |
| engine call | `FrameEngine.previewImage(at:)` (`:874`) | `exactSeek` → `seek(to:)` → `beginReading(from:resumePlaying:)` |
| decoder | **`AVAssetImageGenerator`**, `generateCGImagesAsynchronously` | **`AVAssetReader`**, `timeRange = CMTimeRange(start: start, duration: .positiveInfinity)` |
| surface | a `CGImage` drawn as an OVERLAY above the video layer (`ContentView.swift:1009`) | the Metal playback path itself |

Two decoders, and the overlay is torn down (`scrubPreviewImage = nil`) in the same closure that
starts the reader. They are genuinely different mechanisms, which is what made the tolerance
theory worth testing at all — but note what the measurement below then found: **two different
decoders that nevertheless pick the SAME frame on all-intra.** Being different mechanisms turned
out not to imply different frame selection.

### MEASURED 2026-08-27 — the tolerance mechanism is REFUTED on ProRes

40 scrub positions per file, spread across the duration, deliberately off frame boundaries (only
2 of 40 landed on a grid PTS), on two ProRes fixtures — `MONO_STEREO_51.mov` (`apch`, 23.976,
121 frames) and `SYNC CHECK.mov` (`ap4h`, 23.976, 243 frames). For each position: the frame
`AVAssetImageGenerator` actually returned (its `actualTime`), and the frame `AVAssetReader`
delivers for the same request.

| tolerance | preview frame − frame containing request | RELEASE − PREVIEW | sign |
|---|---|---|---|
| `before=0.5  after=0.5` (SHIPPING) | 0.000 (sd 0.000) | **0.000 (sd 0.000)** | 80 identical |
| `before=0.5  after=.zero` | 0.000 (sd 0.000) | **0.000 (sd 0.000)** | 80 identical |
| `before=.zero after=.zero` | 0.000 (sd 0.000) | **0.000 (sd 0.000)** | 80 identical |

**Zero difference, in all 80 positions, under every tolerance setting.** The generator returns the
frame CONTAINING the requested time, exactly, and so does the reader. On all-intra ProRes every
frame is a sync sample, so the ±0.5 s window buys the generator nothing and it never uses it.

**This is a null result and it is not partial. BOTH tolerance hypotheses were wrong, and neither
was half-right:**

- **"The tolerances are unset, so the generator is free to return any convenient frame."** Wrong
  twice over. They ARE set — ±0.5 s, not the `kCMTimePositiveInfinity` default — and even at
  ±0.5 s the generator returns the exact containing frame anyway. The window is present and
  never used.
- **"The reader floors to the containing frame while the generator's `+After` tolerance lets it
  land later, giving a backwards correction every time."** Wrong. Both floor to the SAME frame,
  so there is no ceiling to floor against and no correction of either sign.

The tolerance does not put the preview a frame ahead, does not produce a jump of either sign, and
cannot account for the report on this codec. Anything built on it would have been built on air.

**Consequently the asymmetric change is a no-op on this codec.** Setting
`requestedTimeToleranceAfter = .zero` and leaving `Before` at 0.5 s eliminates nothing on ProRes,
because there is nothing to eliminate. Latency was unchanged too (15.5 / 14.0 / 14.2 ms per
request across the three settings) — on all-intra, exact seeking is already what happens.

### The long-GOP side, measured rather than reasoned

`H264.mp4` (`avc1`, 23.976, 279 frames, GOP ≈ 21), same 40 positions:

| tolerance | RELEASE − PREVIEW (frames) | sign | generator latency |
|---|---|---|---|
| `before=0.5  after=0.5` (SHIPPING) | mean +1.92, sd 5.99, range −11…+10 | 14 back / 25 fwd | **31.7 ms** |
| `before=0.5  after=.zero` | mean +3.82, sd 3.96, range 0…+10 | **0 back** / 25 fwd | 38.6 ms |
| `before=.zero after=.zero` | **0.000 (sd 0.000)** | 40 identical | **46.0 ms** |

So on long-GOP the shipping tolerance *does* cause large preview errors — up to 11 frames, **both
signs**, which is what a symmetric window predicts. The asymmetric setting removes every backwards
error but leaves forward ones up to 10 frames, because `Before = 0.5 s` still lets the generator
fall back to the preceding keyframe. Only both-to-zero is exact, and it costs **+45% generator
latency (31.7 → 46.0 ms)** on this file. On ProRes it costs nothing.

### The throttle, and why it fits the report better than tolerance does

`ContentView.requestScrubPreview(at:)` has two gates, and **neither is a wall-clock interval**:

```swift
guard !previewRequestInFlight else { return }
guard abs(time - lastPreviewTime) > 0.05 else { return }
```

The slider's range is `0...engine.duration`, so `time` is **media seconds**. The `0.05` gate is
therefore a media-time DISTANCE gate — **1.20 frames at 23.976** — not a rate limit.

**No final preview request is issued on release.** The release closure (`ContentView.swift:2524`)
calls `exactSeek`, clears `isScrubbing`, nils `scrubPreviewImage` and resets `lastPreviewTime`. A
request still in flight at release is discarded (`if isScrubbing` fails). So the last preview the
user SAW is the last request that COMPLETED, whose requested time can be behind the release point.

Replaying those exact gates against a 60 Hz slider with the measured generator latency:

| drag speed | staleness at release |
|---|---|
| 0.25× realtime | 1.00 frames |
| 0.5× / 1× | 1.20 frames |
| 2× | 1.60 frames |
| 5× | 2.00 frames (ProRes) / 4.00 (H.264) |
| 20× | 7.99 / 15.98 frames |
| 100× | 39.96 / 79.92 frames |

**Floor of ~1.2 frames at any speed** (the media-time gate), rising with drag speed once the
in-flight latch dominates — so **yes, it is speed-bounded above ~2×**, and a fast scrub does end
further behind than a slow one. The floor persists even if the user pauses before releasing,
because a stationary slider never re-arms the distance gate.

**Magnitude match:** 1.0–1.2 frames is *"almost backs up a frame"*. The tolerance mechanism
contributes exactly 0.

### The direction is NOT an anomaly — a jump of EITHER sign is what staleness predicts

Both gates use `abs()`; the tolerance is symmetric. **Staleness makes the preview lag the drag, so
its sign is just the sign of the last net movement** — a drag ending forward produces a FORWARD
jump, one ending backward a backward one. Either sign, varying between drags, is the ordinary
output of a lagging preview.

⚠️ **THIS SECTION PREVIOUSLY RECORDED THE DIRECTION AS UNEXPLAINED. It was answering a question
nobody had asked.** It reasoned that a CONSISTENTLY backwards jump would require the user's final
movement to be consistently backwards — behaviour, not code — and filed the gap as the one open
anomaly standing between staleness and a complete account. **That premise was the retelling's, not
the report's.** Joey claims no direction, so there is no consistency to explain.

**Nothing about the report is unexplained now.** Staleness accounts for it whole: ~1.2 frames at
ordinary drag speed, which is the magnitude he describes, in whichever direction the drag last
moved, which is a sign he does not describe. No assumption about user behaviour is required, and
the mechanism needs no companion.

⚠️ **WHAT IS STILL UNCONFIRMED IS THE DEFECT, NOT THE MECHANISM.** The staleness figures are a
replay of the shipping gates against a synthetic drag — an analysis of the code, not an
observation of Joey's session. That distinction is unchanged by this correction.

### Relative magnitudes

- **On ProRes — the reported codec — staleness is the whole effect: ~1.2 frames vs tolerance's
  0.** Not "both contribute".
- **On long-GOP both contribute**, tolerance the larger (up to ±11 frames, sd 6.0) and staleness
  1.2–16 frames depending on speed.

### The fix, as BUILT 2026-08-27

The mechanism that matches points at the throttle, not the tolerance. Two parts, and the second is
why this was not a small change:

1. **Issue a final, UN-THROTTLED preview request on release**, at `scrubValue`, bypassing both
   gates. That is what closes the ~1.2-frame staleness floor.
2. **Hold the overlay until the reader's frame lands**, instead of nil-ing `scrubPreviewImage` at
   `ContentView.swift:2524`.

⚠️ **(2) IS AN ORDERING PROBLEM AND IT IS THE REASON THIS IS NOT ONE LINE.** Today the overlay is
torn down in the SAME closure that starts the seek — **it goes away before the reader has
delivered anything.** So (1) on its own would compute the correct final preview and then throw it
away before it could be seen; the user would still see the jump. Doing (2) needs a signal that the
reader's first frame is actually on screen, which the release closure does not currently have.

#### What was built

**Both parts, together, in `ContentView`. Neither works alone** — a corrected final preview that is
torn down before it can be seen is not seen, and holding a stale overlay longer just shows the wrong
frame for longer.

1. **`requestScrubPreview(at:final:)`** — the release passes `final: true`, which bypasses the
   in-flight latch and the 0.05 media-second distance gate and asks for `scrubValue` itself.
2. **A HANDOFF replaces the teardown.** The overlay's gate changed from `isScrubbing` to
   `scrubPreviewImage != nil`, so release no longer implies removal. `beginScrubHandoff()` holds it
   until the seeked-to frame is on screen.

**The signal is `MetalVideoRenderer.onFirstPresentAfterFlush`**, a new one-shot that fires when
`presentsSinceFlush` goes **0 → 1**. Every seek flushes (`FrameEngine.beginReading`, and the libav
path) and `flush()` zeroes that counter, so the edge means exactly *"the first frame of the seek I
just started has been presented"*. Two properties carry it:

- **It is an EDGE, not a level.** Arming happens mid-generation, while the pre-drag frame is still
  up and the count is already non-zero, so nothing that repaints the OLD generation can satisfy it.
- **"Presented" is literal.** The counter is incremented immediately after `presentDrawable`, which
  does `waitUntilScheduled()` plus a committed `CATransaction` around `present()`. The frame is with
  the compositor before the overlay is removed, so no turn exists on which neither surface has
  content — no flash, no gap.

⚠️ **THE PAUSED-SEEK BRANCH (`MetalVideoRenderer.swift`) IS NOT THE HOOK, THOUGH IT LOOKS LIKE IT.**
It is a FALLBACK that runs only when the decoder overshoots the pinned clock *while paused*. A seek
whose first frame lands at `pts <= now` is taken by the strict gate above it and never reaches that
branch — so an overlay hung off it would sit until the timeout in the ordinary case. Both selection
branches funnel through `renderPixelBuffer`, which is why the counter there catches both with one
condition.

#### The bounded fallback — what happens when the seek fails or is slow

**A 400 ms timeout, unconditionally armed alongside the one-shot.** `beginReading` can return before
it ever flushes (no asset, no video track, no renderer) and can fail after flushing (`AVAssetReader`
create failure); in neither case does a frame arrive, so the one-shot alone would pin the overlay
forever. 400 ms is **>3× the worst measured** first-frame latency (118 ms ProRes, 84 ms H.264) and
short enough to read as a hesitation rather than a freeze. **On timeout the overlay is simply
dropped — which is the OLD behaviour, i.e. a possible one-frame jump.** Degrading to the bug is
acceptable; degrading to a stuck picture is not.

Three races are closed by a **generation counter** (`scrubHandoff`), bumped on every release, every
new grab and every completion; the one-shot, the timeout and the in-flight final preview each stamp
themselves with it and a late answer from any of them is discarded:

- the **generator losing to the reader** (~15 ms vs ~27 ms typical, tails overlapping) — a late
  final preview would otherwise put a stale frame back on top of the correct one and leave it there;
- a **new grab** starting while a handoff is still running — its one-shot or timeout would otherwise
  clear the overlay mid-drag;
- the **cancelled-sleep trap** — a cancelled `Task.sleep` throws, `try?` swallows it, and the
  timeout body would otherwise run immediately when the frame arrives first.

**NOT VERIFIED AGAINST THE REPORT.** The defect is still not reproduced in-house. What is verified
is that both configurations build and that the mechanism the measurements identified is closed.

### ⚠️ Three measurement traps, recorded because they are the reusable part

Every one produced a clean, plausible, WRONG number before it was caught:

1. **`AVAssetReader` with a trimmed `timeRange` emits a leading EMPTY MARKER buffer** —
   `numSamples == 0`, duration 0, PTS clamped to the range start. Counting it as a frame and
   taking "next PTS minus one" produced **−1 frame in 39/40** — a textbook confirmation of the
   hypothesis under test, entirely manufactured.
2. **The first real buffer's PTS is TRIMMED to the range start in both output modes**, so it
   cannot identify the frame. Nearest-matching that trimmed value flips to the next frame whenever
   the request lands in the later half of a frame — which fabricated a **+1** with mean +0.525,
   i.e. a uniform [0,1) distribution that is just the sub-frame phase of the sample times.
3. **Passthrough output is not faithful on long-GOP** — compressed samples can only start at a
   sync sample, so it returns the preceding keyframe, which is not what is displayed.

The rule that survives all three: **the SECOND decompressed buffer is untrimmed and on the natural
grid; the delivered frame is one grid step before it.** Cross-checked against the passthrough true
PTS on all-intra, where both methods are valid and agree.

**THE HARNESS IS KEPT, IN THE REPO:** `docs/scrub-fixtures/scrubmeas.swift`, with its own
`README.md`. Following `docs/color-fixtures/`, it is a standalone tool, not part of the app target
— `project.yml`'s `sources:` is `App` plus one explicit DeckLink `.cpp`, so nothing under `docs/`
compiles into any configuration and no `xcodegen` run is needed.

```bash
cd docs/scrub-fixtures && xcrun swiftc -O -o scrubmeas scrubmeas.swift
N=40 ./scrubmeas "/path/to/clip.mov"
```

It reports, per scrub position, the frame each path returns and the signed difference in frames,
under all three tolerance settings, plus the staleness replay. **The three traps below are
documented at the sites where they bite, inside that file** — whoever runs it next will hit all
three.

**Running it on JOEY'S ACTUAL FILE is still the most useful single measurement — but no longer for
the direction, which is a withdrawn question.** Two in-house ProRes fixtures gave exactly zero
across 80 positions, so what his media would settle is whether the tolerance path contributes
anything at all on it. Silence there would leave the throttle as the sole mechanism, which is where
the magnitude already points.

### Before touching it, get the missing facts

Not reproduced in-house, and the report is under-specified in the ways that decide the fix:

- **Frame rate and duration of Joey's file**, and whether it reproduces on a short clip.
- **Is it exactly one frame, or "almost"?** A sub-frame shift and a one-frame shift have different
  causes; *"almost backs up a frame"* does not separate them.
- ~~**Which DIRECTION was the last movement before he let go?**~~ **WITHDRAWN 2026-08-27.** It was
  decisive only while this entry believed the jump was consistently backwards. It is not — see the
  correction at the top. Staleness predicts the sign of the last net movement, so every possible
  answer is consistent with the mechanism and none of them discriminates between causes.
- **How fast was the drag?** Staleness is ~1.2 frames at ≤2× realtime and grows with speed; a
  larger reported jump would point at a fast scrub, a strictly one-frame one at the gate floor.
- **Does it reproduce on H.264 as well as ProRes?** No longer a yes/no check but a discriminator:
  tolerance contributes 0 on all-intra and up to ±11 frames on long-GOP, so a much LARGER and
  double-signed jump on H.264 would say tolerance is live there while the throttle drives ProRes.
- **Does it reproduce with the preview overlay disabled** — still the cleanest single
  discriminator, because it removes both the generator and the throttle from the picture at once.

**Related:** the HDR scrub defect is *"Scrubbing an HDR file collapses the picture to SDR
luminance"* below — same gesture, unrelated cause, and it holds the rejected shared-fix proposal;
the generator is `FrameEngine.makeScrubPreviewGenerator(for:)`; the preview request is
`ContentView.requestScrubPreview(at:)`; the release path is `FrameEngine.exactSeek(to:)` →
`beginReading`; the no-decode readout during the drag is `FrameEngine.scrubSeek(to:)`.

---

## Scrubbing an HDR file collapses the picture to SDR luminance

**Status:** **FIXED 2026-08-27 for the AVFoundation path (ProRes/H.264) — parts 1 and 2, across
the WHOLE supported OS range (macOS 15+).** ⚠️ **The macOS 15–25 half is UNVERIFIED — written from
the header contract and never executed, because the build Mac runs 26.5.1. See "what each OS range
gets" below.** Part 3 (DNx/MXF) DELIBERATELY NOT DONE; HDR previews for those formats stay SDR, see
"recorded choice" below. **Reported:** 2026-08-27 by Joey. **Blocks:** judging highlights while scrubbing an HDR deliverable — the one operation where
the picture and the luminance have to be trusted together.

**The report:** scrubbing a PQ/HLG file drops the picture to SDR luminance. **Highlights clamp,
colour stays correct, and it returns on release.**

**⚠️ SEPARATE FROM the scrub-POSITION defect** — *"⚠️ UNCONFIRMED: scrub release jumps the picture
once, backwards, on ProRes"* above. Same gesture, same overlay, two unrelated causes: that one is
about WHICH FRAME is shown, this one is about HOW IT IS LIT. Neither fix implies the other. They
are cross-referenced because a single change was proposed to fix both, and that change was
rejected — see the bottom of this entry before proposing it again.

### The cause is ONE LAYER EARLIER than the compositing explanation

The obvious reading — "the overlay isn't EDR-capable, so it clamps" — is true but **second-order**.
The image is already SDR before compositing is involved:

**`AVAssetImageGenerator.dynamicRangePolicy` defaults to `.forceSDR`**, which the SDK documents as:

> Force standard dynamic range by **converting PQ or HLG transfer functions to 709, while
> maintaining color primaries and matrix**.

That is the reported symptom stated as an API contract: luminance collapses to 709, highlights
clamp, and colour still looks right because primaries and matrix are preserved.

**`FrameEngine.makeScrubPreviewGenerator(for:)` never sets it.** `grep dynamicRangePolicy` across
`App/` and `Packages/` returns **zero hits**. The property is `macos(15.0)`, so it is available at
our deployment target — this is an unset default, not a missing capability.

The compositing half is nevertheless real, and matters for the fix: the Metal layer is **covered,
not hidden** (`Image(decorative:)` sits above `MetalSurfaceView` in the same ZStack,
`ContentView.swift:1008`), and the Metal layer is the EDR-capable one —
`wantsExtendedDynamicRangeContent = isHDRTransfer` is set per source for PQ (16) and HLG (18) in
`MetalVideoRenderer.setSourceColorSpace`. On release the overlay is nil'd and the EDR surface is
revealed, which is why **it returns on release**.

### Scope of a fix: THREE parts, and none of them is a one-liner

⚠️ **Setting the policy alone does NOT fix this.** `CALayer` tone-maps ITU-R 2100 content to SDR
unless the layer opts in, so a correctly-tagged HDR `CGImage` handed to the current overlay is
still tone-mapped. All three parts are needed for full coverage:

1. **`dynamicRangePolicy = .matchSource`** on the scrub generator (macOS 15.0+, available to us).
   Necessary, not sufficient.
2. **An EDR-capable host layer for the overlay.** SwiftUI's `Image` exposes **no** dynamic-range
   API, so the overlay has to become an `NSViewRepresentable` hosting a layer that opts in. This
   is the part that makes it not a one-liner. **Which API to opt in with is now settled — write it
   against `preferredDynamicRange` and leave the renderer alone; see the follow-up at the end of
   this entry, which also records what must be TESTED before this part is scheduled.**
3. **A float path in `LibavThumbnailSource`** if DNx/MXF HDR is to be covered at all. It currently
   swscales to `AV_PIX_FMT_RGBA` and builds an 8-bit `CGImage` — **SDR by construction**, and no
   layer opt-in can rescue 8-bit RGBA. This is a second producer, and it needs its own pipeline.

Parts 1 and 2 cover ProRes/H.264 (the AVFoundation path). Part 3 is separable and can be deferred
with the consequence stated: HDR DNx/MXF previews stay SDR.

### ⚠️ REJECTED: routing scrub preview through the real decode path

**Someone will have this idea again — it was had, scoped and measured on 2026-08-27, and it is
rejected.** The proposal: drop the generator-to-`CGImage` overlay and drive scrub preview through
the real decode path (reader → `CVPixelBuffer` → the Metal renderer), which would be EDR-correct
by construction AND collapse this entry and the frame-mismatch half of the scrub-position entry
into one fix. It fails on four independent grounds, any one of which is sufficient.

**1. The latency premise was wrong, and the corrected numbers do not fit.** The figures cited in
support (15.5 / 14.0 / 14.2 ms) were **`AVAssetImageGenerator` latency under the three tolerance
settings — the cost of the path being REMOVED.** `exactSeek` had never been measured. Measured
since: build reader at `t`, `startReading`, first decoded frame in the app's `x420` format, 40
positions, all 4K:

| fixture | mean | p50 | p90 | max | vs the 50 ms throttle budget |
|---|---|---|---|---|---|
| ProRes 422 HQ `apch` | 27.4 ms | 24.2 | 28.6 | **117.7** | fits at mean, **not** worst case |
| ProRes 4444 `ap4h` | 31.4 ms | 29.2 | 34.8 | 72.0 | fits at mean, **not** worst case |
| H.264 `avc1` | **53.7 ms** | 52.6 | 67.0 | 83.5 | **fails outright** |

All-intra fits on average and blows the budget on its worst case; long-GOP fails at the mean.
**These are a FLOOR** — they exclude audio-reader teardown (`beginReading` moves both readers), the
synchronizer re-anchor, the renderer flush, and session-token churn.

**2. The real path is ~1.8× SLOWER than the generator it would replace** — 27 ms against 15 ms on
ProRes. The generator wins because it decodes to 960×540 and reuses one warm instance per asset,
while a scrub-driven reader is rebuilt per position. The proposal is a performance regression on
the codec it supposedly serves best.

**3. It would produce THREE decoders, not one.** Long-GOP still needs the overlay (ground 1) and
DNx/MXF still needs `LibavThumbnailSource` (VideoToolbox rejects DNxHR), so the reader path would
be a THIRD producer serving all-intra only — and the frame mismatch would be fixed on the
all-intra half alone. **The stated appeal of the proposal — "one decoder, no mismatch" — inverts
into three decoders and a partial fix.**

**4. It walks back a decision made to stop a crash.** Commit `8896163` introduced `videoPumpQueue`
/ `audioPumpQueue` and serialized `cancelReading()` because reader teardown could overlap an
in-flight `copyNextSampleBuffer()` during scrub — its own title is *"fix reader teardown race …
fixes scrub and close-while-playing crashes"*. And the policy predates even that: `scrubSeek`
carried *"During a scrub drag: just track the target and show it on the clock, WITHOUT rebuilding
the reader every tick (that storms the decoder)"* before the overlay existed. **The proposal
reintroduces that churn at up to 20 Hz continuously** — the load the serialization was written to
survive occasionally.

**What this means for sequencing:** the two scrub defects are independent and must be fixed
independently. Fixing the HDR one does not fix the frame mismatch, and there is no shared change
that does both.

### FOLLOW-UP 2026-08-27 — the EDR API decision, scoped. And a CORRECTION.

The note that stood here said an EDR-capable overlay layer would be written against *"whichever
of the two APIs the renderer settles on"* — deferring a decision into the entry instead of
recording one, and leaving part 2 unscoped. Settled below, from the SDK headers.

#### ⚠️ CORRECTION: the renderer is NOT using a deprecated API. There is no forced migration.

The note below previously said `wantsExtendedDynamicRangeContent` is deprecated as of macOS 26 and
that `MetalVideoRenderer` still uses it. **The first half is true only of a DIFFERENT property on a
different class.** There are two separate declarations:

| declaration | availability |
|---|---|
| `CALayer.wantsExtendedDynamicRangeContent` | **`API_DEPRECATED("Use preferredDynamicRange instead", macos(14.0, 26.0))`** |
| `CAMetalLayer.wantsExtendedDynamicRangeContent` | `API_AVAILABLE(macos(10.11), ios(16.0))` — **not deprecated** |

`MetalVideoRenderer` holds `let metalLayer = CAMetalLayer()` and sets the property on **that**, so
it is using the CAMetalLayer declaration, which carries no deprecation and no removal path. **The
renderer migration is optional and not on a clock.** It should not be bundled into the HDR fix on
urgency grounds, and the "the migration overlaps this fix" framing below is weaker than it was
stated to be.

#### What `preferredDynamicRange` actually requires

`CALayer.preferredDynamicRange` (macOS 26.0+) defaults to `CADynamicRangeStandard`; values are
`.automatic`, `.standard`, `.constrainedHigh`, `.high`. It *"controls the dynamic range used to
render CGColors and `contents` of the layer **that have headroom tagging greater than 1.0**"*.

**Headroom tagging is a RATIO, not a flag** — `kIOSurfaceContentHeadroom` defines it as *"the ratio
of nominal peak luminance ("peak white") to nominal diffuse luminance ("reference white" or
"diffuse white")"*. Content qualifies by exactly one of three routes:

- a **`CGImageRef` with content headroom** — `CGImageCreateWithContentHeadroom` /
  `…CreateCopyWithContentHeadroom`, read via `CGImageGetContentHeadroom` (macOS 26.0), with
  `kCGDefaultHDRImageContentHeadroom` as the supplied typical value;
- an **`IOSurfaceRef` carrying `kIOSurfaceContentHeadroom`** (macOS 15.0);
- or **`CALayer.contentsHeadroom`** set explicitly (macOS 26.0). Defaults to **0, meaning
  untagged**; values above 0 and below 1.0 are **undefined**. Its own doc notes *"CAMetalLayers can
  use this value to define how much headroom is needed by their MTLDrawables."*

**Does `MetalVideoRenderer` currently carry it? NO.** `grep` for `contentsHeadroom`,
`ContentHeadroom`, `preferredDynamicRange` and `toneMapMode` across `App/` and `Packages/` returns
**zero hits**. The renderer renders into a CAMetalLayer drawable, sets no `contentsHeadroom`, and
attaches no IOSurface headroom key — so under `preferredDynamicRange` semantics its content is
**untagged and would not activate EDR at all**.

#### Substitution or pipeline change? PIPELINE CHANGE — and this is the answer that matters

The two APIs have different activation models, which is why this is not a call swap:

- `wantsExtendedDynamicRangeContent` is a **boolean opt-in that requires no tagging**. Set it, and
  values above 1.0 survive to the display. That is why the current code works with no headroom
  metadata anywhere.
- `preferredDynamicRange` **activates only on tagged content**. Setting it while the content stays
  untagged changes nothing — it would be a silent no-op, which is the worst failure shape for this
  particular pipeline.

So migrating the renderer means **deciding and writing a headroom number**, not swapping a call.
That number is a real quantity (peak ÷ diffuse white), and choosing it for PQ and for HLG is a
colour decision of the same kind as the `edrMetadata` question already deferred in
`setSourceColorSpace` — **not a detail to settle inside a mechanical migration.**

#### Do the overlay and the renderer need the same API? NO — and they legitimately differ

They are different layer classes with independently-versioned properties, so different APIs is the
*correct* outcome, not an inconsistency:

- **Renderer — `CAMetalLayer`.** Its `wantsExtendedDynamicRangeContent` is current. Keep it. No
  reason to touch this as part of the HDR fix.
- **Overlay — a plain `CALayer` hosting a `CGImage` as `contents`.** Its
  `wantsExtendedDynamicRangeContent` *is* the deprecated one, so a newly-written overlay layer
  should use **`preferredDynamicRange`** plus headroom-tagged contents, and should not adopt the
  deprecated property just to match the renderer.

**This resolves part 2's open question:** write the overlay against `preferredDynamicRange`, leave
the renderer alone.

#### ⚠️ NOT DETERMINED — these need running code, and are not inferred here

State them as open rather than guessing, because each would otherwise be built on:

1. **Whether `preferredDynamicRange` governs CAMetalLayer DRAWABLES at all.** The headers disagree
   with themselves: `preferredDynamicRange` speaks only of *"CGColors and `contents`"* (a drawable
   is neither), `contentsHeadroom` says CAMetalLayers use it for their MTLDrawables, and
   `toneMapMode` explicitly covers *"CALayer contents and CAMetalLayer drawables"*. **Not
   determinable from the headers.** It only matters if the renderer migration is ever taken up.
2. ~~**Whether an `AVAssetImageGenerator` CGImage produced with `.matchSource` carries content
   headroom.**~~ **MEASURED 2026-08-27 — IT DOES. See the result below; `contentsHeadroom` is NOT
   needed and part 2 stayed the size it was scoped at.**
3. **When the deprecated `CALayer` property stops working.** The header gives a deprecation
   version and **no removal version**, and deprecation is not removal. Not determinable from here.
   Moot for the renderer, which does not use that declaration.
4. **What headroom VALUE is correct for our PQ and HLG content.** A policy decision, not a lookup.

**Priority consequence:** since the renderer is not on a removal path, **the migration is optional
and can wait**. The HDR fix was scoped to the overlay alone, and it stayed there.

### MEASURED 2026-08-27 — the headroom question, answered

`AVAssetImageGenerator`, one frame at mid-duration from
`docs/color-fixtures/wedge-pq-24track.mov` (`SMPTE_ST_2084_PQ` / `ITU_R_2020`, 1920×1080), both
policies, reading `CGImage.contentHeadroom`:

| policy | CGImage colorSpace | `UsesITUR_2100TF` | **contentHeadroom** |
|---|---|---|---|
| `.forceSDR` (was shipping) | **nil** | false | **1.0** |
| `.matchSource` (now shipping) | `kCGColorSpaceITUR_2100_PQ` | **true** | **4.9261084** |

**4.9261084 is exactly `kCGDefaultHDRImageContentHeadroom`.** So the generator's output is TAGGED,
the CGImage route into `preferredDynamicRange` is live, and **the overlay does not need
`contentsHeadroom` set explicitly.** The fix stayed at the two parts it was scoped at.

**Control:** an SDR fixture (`wedge.mov`, untagged transfer) returns 1.0 under BOTH policies. So
`.matchSource` follows the source rather than forcing headroom onto content that has none — which
also means this change is a no-op on every SDR file.

⚠️ **API NOTE:** the C function named in the plan, `CGImageGetContentHeadroom`, no longer compiles
against the current SDK — *"has been replaced by property `CGImage.contentHeadroom`"*. Same value,
different spelling.

### What was built, 2026-08-27

**Part 1 — `FrameEngine.makeScrubPreviewGenerator`:** `dynamicRangePolicy = .matchSource`. Not
availability-guarded; the property is macos(15.0) and this target's floor is 15.0.

**Part 2 — `ScrubPreviewSurface` / `ScrubPreviewHostView` (`App/MetalSurfaceView.swift`):** an
`NSViewRepresentable` hosting a plain `CALayer`, replacing `Image(decorative:)` in ContentView's
ZStack. Written against **`preferredDynamicRange = .high`**, guarded `if #available(macOS 26.0, *)`
— below 26 the overlay behaves exactly as before (tone-mapped), which is the correct degradation:
the picture is still right, only the highlights are held. `.high` and not `.constrainedHigh`, to
match the unconstrained `wantsExtendedDynamicRangeContent` on the CAMetalLayer underneath — the
whole point is that the overlay and the revealed layer look the same, and a constrained overlay
would just move the brightness step from release to grab.

**The renderer was NOT touched**, per the decision above: its `wantsExtendedDynamicRangeContent` is
the CAMetalLayer declaration, which is current.

Two details in the new layer that are not cosmetic:

- **`contentsGravity = .resize`**, because the caller still pins the aspect with
  `.aspectRatio(videoAspect, contentMode: .fit)` — the video rect's authority, deliberately not the
  image's own PAR (the two preview producers disagree about it). The layer's job is to fill the rect
  that pin produces, which is what `.resizable()` did before.
- **Implicit animations disabled** on `contents`, twice over (an `actions` dictionary AND a
  `CATransaction.setDisableActions(true)` in the setter). Without it every preview swap during a
  drag cross-fades through CALayer's default 0.25 s `contents` animation — a visible smear on a
  control whose entire purpose is to answer "which frame am I on". The transaction is belt-and-
  braces for the `updateNSView` case, where an enclosing SwiftUI animation may be in flight.

### ⚠️ WHAT EACH OS RANGE GETS — read this before filing "the HDR fix doesn't work"

**Both branches ship. There is no OS in the supported range with no opt-in.**

| range | opt-in used | result | verified? |
|---|---|---|---|
| **macOS 26+** | `preferredDynamicRange = .high` | EDR preview | **YES** — build Mac is 26.5.1 |
| **macOS 15–25** | `wantsExtendedDynamicRangeContent = true` | EDR preview | ⚠️ **NO — see below** |

#### ⚠️ THE 15–25 PATH HAS NEVER BEEN EXECUTED. Say so when reporting on it.

**The build Mac runs macOS 26.5.1, so the `else` branch has never run on real hardware.** It is
written from the header contract alone. Every claim about it in this entry is READ, not OBSERVED —
and that distinction must survive: if this path turns out to misbehave, the entry should not read as
though someone had checked. **No macOS 15–25 machine was available.** Getting one in front of a PQ
file is the outstanding verification for this fix.

What IS established, from the SDK headers:

- `CALayer.wantsExtendedDynamicRangeContent` is `API_DEPRECATED("Use preferredDynamicRange instead",
  macos(14.0, 26.0))` — **available FROM 14.0, deprecated AS OF 26.0.** Across 15–25 it is the only
  opt-in that exists, and deprecation is not removal.
- **It is the UNCONSTRAINED one, which is what matches the 26+ branch.** Its header says contents
  "can be displayed up to its NSScreen's `maximumExtendedDynamicRangeColorComponentValue`" — the
  display's full headroom, no modulation. That is `CADynamicRangeHigh` ("provides the best HDR
  quality"), NOT `CADynamicRangeConstrainedHigh` ("brightness is **modulated** to optimize for
  co-existence with other composited content"). The boolean has no modulated mode at all, so the two
  branches cannot silently diverge on this axis.
- Unconstrained is also what the picture UNDERNEATH does — `MetalVideoRenderer.setSourceColorSpace`
  sets the CAMetalLayer's (current, non-deprecated) `wantsExtendedDynamicRangeContent`. So on 15–25
  the overlay and the layer revealed on release use literally the same property.
- Swift emits **no deprecation warning**: the availability checker narrows the `else` of
  `if #available(macOS 26.0, *)` to < 26.0, where the property is not yet deprecated. Verified in
  both configurations.

#### ⚠️ WHAT PART 1 DOES ON ITS OWN — CLIP vs TONE-MAP, and they are not the same thing

Relevant to any OS where the layer opt-in fails or is absent, and to reading the history of this
entry correctly.

`dynamicRangePolicy` is `API_AVAILABLE(macos(15.0))` — the whole supported range — and is NOT
guarded in our code, so `.matchSource` applies everywhere:

| | before (`.forceSDR`) | after (`.matchSource`), no layer opt-in |
|---|---|---|
| what the CGImage is | colorSpace **nil**, PQ→709 **converted**, headroom 1.0 | **PQ-tagged** `ITUR_2100_PQ`, headroom 4.93 |
| what reaches the screen | highlights **CLIPPED** by the transfer conversion | highlights **TONE-MAPPED** (roll-off) |
| colour | primaries/matrix preserved | primaries/matrix preserved |

Documented, not inferred — `wantsExtendedDynamicRangeContent`'s own header comment: *"If NO,
contents are clipped or tonemapped to 1.0 (SDR). `contents` with a CGColorSpaceRef conforming to
ITU-R 2100 (`CGColorSpaceUsesITUR_2100TF`) will be tonemapped."* The measurement above confirms our
image takes that branch (`UsesITUR_2100TF == true`).

**Both land on an SDR picture, so part 1 alone never fixed the report.** But they are not the same
operation, and **an un-opted-in layer must not be described as "what it did before this change"** —
that phrasing was in the code comment briefly and is wrong. Part 1 is also the precondition for
either opt-in: both properties act on HDR-TAGGED content, and tagging it is what part 1 does.

### ⚠️ MEASUREMENT HAZARD — `maximumExtendedDynamicRangeColorComponentValue` AND DISPLAY MODE

**Recorded because it already cost us a working instrument once, on 2026-08-27, and it will do it
again to whoever reads only the layer properties.**

While diagnosing why the HDR fix did not work on the build Mac, `NSScreen`'s
`maximumExtendedDynamicRangeColorComponentValue` was probed across every candidate layer
configuration — including `wantsExtendedDynamicRangeContent = true`, the property
`MetalVideoRenderer` uses to produce demonstrably correct EDR in this app. It read **exactly 1.0000
for all of them, including that known-good control.** The conclusion drawn was "the metric is inert
on this machine; do not judge the fix by it", and the field was labelled NOT-AN-INDICATOR in the
diagnostic.

**That conclusion was WRONG. The display was in SDR mode for the entire probe.** A screen not in HDR
mode grants no headroom to anything, so 1.0 everywhere was the correct answer to a question asked
under the wrong conditions. With the display in HDR mode the same field reads real values — **4.4827
was observed during a drag** on the same machine.

**The rules that follow:**

1. **Read `potential` before reading `current`.** `potential=1.0` means the display cannot do EDR at
   that moment, and NOTHING about any layer can be inferred from the line. Only when `potential` is
   high (8.9654 here) does `current` say anything about whether a layer won a grant.
2. **The display's mode is not under the test's control and changes between runs.** Two readings
   minutes apart on this machine gave `potential=8.9654` and `potential=1.0000`.
3. **This machine has TWO displays** — an LG TV (3840×2160) and an ASUS PA147. `NSScreen.main` is
   the LG. A probe that opens its own window may sample a different screen than the app does;
   `MetalVideoRenderer.logEDRHeadroom` uses `NSApp.mainWindow?.screen` and the scrub diagnostic uses
   the host view's own `window?.screen`. Same property, potentially different screen.
4. **A separate instrument IS genuinely unavailable and this correction does not rescue it:**
   `CARenderer` renders NOTHING in this environment — an opaque red background into a `bgra8Unorm`
   target reads all zeros, which has nothing to do with EDR or display mode. Do not confuse the two
   failures. The CARenderer route to reading rendered pixel values is closed; the NSScreen route is
   open whenever the display is in HDR mode.

---

#### On the earlier "not the deprecated property" note

That decision — recorded above, before the branch existed — was about not COPYING the renderer's API
for consistency's sake on a newly written layer, and it was reasoned entirely from which declaration
a new `CALayer` picks up. **Back-deployment was never part of it**, and the deployment-target
consequence was not noticed at the time: taken literally it would have left most of the supported OS
range with no opt-in at all. The two properties are compatible and each is current for its own
range, so an availability branch is the ordinary resolution, not a compromise.

**Where it is NOT fixed — a recorded choice, not an oversight.**

⚠️ **Part 3 (`LibavThumbnailSource`, the DNx/MXF producer) was deliberately left out of this pass,
and HDR previews for those formats therefore STAY SDR.** It swscales to `AV_PIX_FMT_RGBA` and builds
an **8-bit** CGImage — SDR by construction, and no layer opt-in can rescue 8-bit RGBA. Fixing it
means a float pipeline in a second, independent producer, which is its own change with its own
colour decisions. Deferring it costs exactly what this line says it costs and nothing more: the
AVFoundation path (ProRes/H.264) is correct, DNx/MXF is unchanged.

**Related:** the scrub-POSITION defect is *"⚠️ UNCONFIRMED: scrub release jumps the picture once,
backwards, on ProRes"* above — same gesture, unrelated cause; the generator is
`FrameEngine.makeScrubPreviewGenerator(for:)`; the overlay is `ContentView.swift:1008`; the EDR
opt-in is `MetalVideoRenderer.setSourceColorSpace`; the second preview producer is
`LibavThumbnailSource.makeCGImage(from:)`; the harness that produced the latency numbers is
`docs/scrub-fixtures/`.

---

## MEASURED 2026-08-28 — the split, four eliminations, and one correction that mattered

The side-by-side split (`MANIFOLD_SCRUB_SPLIT=1`, `ScrubDebug.splitEnabled`) put the overlay and the
Metal layer on the **same frame, in the same window, at the same instant** — left half overlay, right
half Metal, seam down the middle. Every earlier comparison in this investigation was SEQUENTIAL
(Metal during playback → overlay during the drag → Metal on release), and other things change
alongside: the engine pauses, a flush happens, the frame changes. The split removes all of them.

**Confirmed by eye, on ProRes 4444 PQ, frame 616, display in HDR mode (maxEDR 4.483,
potential 8.965): the halves clearly differ.** Right (Metal) is brighter and holds highlight
detail; left (overlay) is flatter and rolls off earlier. Same data, two renderings.

⚠️ The frame-correspondence guarantee is codec-scoped and was already measured — see *"the tolerance
mechanism is REFUTED on ProRes"* above. Generator and reader select the SAME frame in 80/80
positions on all-intra; on long-GOP the shipping ±0.5 s tolerance puts them up to **11 frames**
apart. **The split is a valid instrument on all-intra and is NOT one on long-GOP.** It prints the
codec and a VALID/INVALID verdict on its own `[SPLIT] ARMED` line for that reason.

### Four display-side controls, individually eliminated

Each with its readback confirmed in `[EDRDIAG]` BEFORE the seam was read — the discipline that
made each result mean one thing:

| control | how tested | readback | result |
|---|---|---|---|
| `CALayer.contentsHeadroom` | deleted the assignment | `contentsHeadroom=0.0` | halves still differ |
| `CALayer.toneMapMode` | set `.never` | `toneMap=CAToneMapModeNever` | halves still differ |
| `preferredDynamicRange` vs `wantsExtendedDynamicRangeContent` | `MANIFOLD_SCRUB_EDR_LEGACY=1` | — | no change |
| the CGImage's own `contentHeadroom` | `CGImageCreateCopyWithContentHeadroom(0.0, …)` | **still 4.9261084** | **the call is a no-op — see below** |

### ⚠️ A PQ image's content headroom cannot be cleared — it is DERIVED FROM the colorspace

`docs/scrub-fixtures/hrprobe.swift`, on `wedge-pq-24track.mov`:

```
  source              : headroom=4.9261084 cs=kCGColorSpaceITUR_2100_PQ
  headroom 0.0        : headroom=4.9261084   ← IGNORED. Not NULL, a new object, tag unchanged.
  headroom 1.0        : headroom=1.0
  headroom 2.0        : headroom=2.0
  headroom 8.0        : headroom=8.0
  plain CGImageCreate : headroom=4.9261084   ← an API with NO headroom parameter AT ALL
```

**The last line is the finding.** An image built by an API that cannot express headroom still
reports 4.9261084 (= `kCGDefaultHDRImageContentHeadroom`). The headroom is not metadata we attach;
it is derived from the PQ colorspace. `0.0` does not mean "clear the tag" — it means "no explicit
override", and the fallback is the colorspace's implied default. Only values ≥ 1.0 take.
`copy(colorSpace:)` with the same PQ space preserves it too.

**There is no way to obtain a PQ-tagged CGImage with unknown headroom.** CGImage.h documents a 0.0
case — *"The headroom value of 0.0f means 'headroom unknown'. The image with unknown content
headroom will be excluded from tone mapping"* — and that case is **unreachable through this API.**

### ⚠️ THE CORRECTION, and it is the reusable part

Asked whether Core Animation's tone-map is driven by the image's headroom tag or by the
ITUR_2100_PQ colorspace alone, this investigation answered **"the headroom tag, not the
colorspace"**, from two header sentences:

- `CALayer.h:464` — `preferredDynamicRange` *"Controls the dynamic range used to render CGColors and
  `contents' of the layer that have **headroom tagging greater than 1.0**. This only effects the
  tonemapping of the receiving layer."*
- `CALayer.h:437` — the ITU-R 2100 tone-map clause sits inside the **`If NO`** branch of
  `wantsExtendedDynamicRangeContent`, so it governs layers that are NOT opted in. Ours are.

Both sentences are accurate. Read together they describe headroom tagging and colorspace as two
independent properties, and **for PQ content they are one property.** The distinction kept options
alive that were never alive: "strip the tag, keep PQ" is not a thing that can be done, because PQ
*is* the tag.

**The method failure is the point: this was a READING of two correct sentences, and it took a
five-line probe to refute it.** The same shape as the `maximumExtendedDynamicRangeColorComponentValue`
error recorded above (a real instrument discarded on a measurement taken under the wrong conditions)
and the three dead instruments recorded below it. Prefer the probe to the paragraph.

### Creation vs composition: the pixel diff — CREATION IS CLEARED (with one stated gap)

`MODE=pixdiff docs/scrub-fixtures/scrubmeas <file>` compares **PQ code values** — the space both
paths actually hand to a PQ-tagged layer, neither having applied an EOTF. It replicates
`passthroughFragment`'s arithmetic on the decoder's `x420` buffer rather than asking CoreGraphics to
convert anything (a `CGBitmapContext` draw would apply a colour transform and measure that instead).

**Resolution was handled by removing it, not by correcting for it.** PASS 1 sets
`maximumSize = .zero` so the generator returns the full encoded raster — 1:1 with the decoder, and
**nothing is resampled on either side**, so no difference it finds can be a filter artefact. PASS 2
then runs the shipping 960×540 cap separately.

`wedge-pq-24track.mov` (`apch`, 1920×1080, PQ/2020), t = 1.0 s, 74 250 pixels:

| | PASS 1 (native, 1:1) | PASS 2 (shipping 960×540) |
|---|---|---|
| fit `gen = m·dec + b` | **m = 1.000001, b = 0.000001, r = 1.000000** | m = 0.999027, b = −0.000060 |
| max abs difference | **0.00114 = 1.17 ten-bit codes** | 0.0298 = 30.5 codes |
| resample-immune subset (flat 3×3) | **max 0.00019 = 0.20 codes** | max 0.0226 |
| binned shape | no curve; bins ±0.00006, alternating sign | monotone, one-sided, ≤1 code mean |
| clipped at ≥1.0 | 4725 gen / 4725 dec — identical | 5031 / 5400 |

**PASS 1 is identity to within half-float quantisation.** The generator produces the same PQ code
values as the decoder. **Creation is cleared as the site of the difference the split shows.** The
1.17-code maximum is accounted for by the generator's half-float storage (`float=true`, ULP ≈ 0.0005
near 1.0) plus chroma bilinear at edges — the flat-neighbourhood subset falls to 0.20 codes, which
is the quantisation floor and not a colour effect. PASS 2's larger, one-sided, monotone difference
is a **downsample**, not a transform: averaging pulls values toward the local mean and softens the
clipped plateau (5031 vs 5400 at the ceiling), and its per-bin mean never exceeds one code.

### ⚠️ THE GAP THIS FIXTURE CANNOT CLOSE — superwhite, and it is the live hypothesis

`wedge-pq-24track.mov` peaks at **exactly 1.000000**, so it cannot exercise the one asymmetry the
two paths have by construction:

- Legal-range expansion maps code 940 → 1.0, so **codes 941–1023 expand ABOVE 1.0.**
- **Metal keeps them.** `passthroughFragment` returns `half4` into an `rgba16Float` target, and the
  shader says so: *"NOT clamped: the rgba16Float target carries >1.0 and negatives, which is the
  whole point of E1."*
- **The generator cannot.** CGImage.h, PQ/HLG float case: *"16-bit or 32-bit float image components
  values will be **clipped to [0.0, 1.0] range**."*

On content graded above legal white the overlay is therefore **clipped where the Metal layer is
not** — a creation-side difference no layer property can undo, and one that would read exactly as
"right holds highlight detail, left rolls off earlier". The file that produced the report is
**deliberately over-cranked**, which is precisely the condition that puts values there.

`pixdiff` now prints an explicit `SUPERWHITE PRESENT` / `superwhite: NONE` line for this reason. A
`NONE` result **does not clear the mechanism** — it says the file could not test it.

**NEXT: run `MODE=pixdiff` on the over-cranked file that produced the report.** If the decoder
exceeds 1.0 where the generator sits pinned at 1.0, that is the answer and the site is the
generator's float clip.

### Instrument, and what it costs

`ScrubDebug.splitEnabled` — DEBUG-only, `let`, folded away in Release (asserted against the built
binaries: Profile carries the `[SPLIT]` strings, Release carries zero). The half is taken with
`contentsRect`, **deliberately not a mask, `clipped()` or `masksToBounds`** — all three add a clip
to the compositing path and at least one can force an offscreen pass, which is the exact class of
operation suspected of flattening this layer's EDR. `logEDRState`'s ancestor walk already flags
`masks` / `compFilter` / `filters` / `RASTERIZE!` on the chain; adding one on purpose would be
tripping our own wire. `contentsRect` is a source-side crop where the image is sampled — no extra
pass, and the EDR configuration is reached identically.


---

## ✅ DECISION 2026-08-28: the desktop picture is the REFERENCE and does not tone-map

**This closed as a colour decision, not as a scrub bug.** The investigation began as "scrubbing an
HDR file looks different from playing it" and assumed throughout that the Metal path was correct
and the overlay had to be made to match it. The side-by-side split inverted that: with the Metal
layer hidden (⌃⌥R), **the scrub overlay and the `AVSampleBufferDisplayLayer` agree with each
other**, and the Metal layer is the outlier. Two independent Core Animation paths agree; the
drawable path does not.

### What each of the three paths ends up with

| path | colour state actually set | headroom | tone-mapped? |
|---|---|---|---|
| **CAMetalLayer** (playback) | `colorspace = ITUR_2100_PQ`, `wantsExtendedDynamicRangeContent = true` — [MetalVideoRenderer.swift:1444](../App/MetalVideoRenderer.swift) | **none** (`contentsHeadroom` 0.0, no `edrMetadata` — both verified absent) | **NO** |
| **scrub overlay** (CALayer, CGImage) | `contentsFormat`, `contents`, `preferredDynamicRange = .high` | 4.9261084, **derived from the PQ colorspace and unclearable** | YES |
| **AVSampleBufferDisplayLayer** (reference surface) | `videoGravity`, `backgroundColor` — **no EDR properties at all** | none set; sample buffers carry PQ attachments | YES |

⚠️ **The CAMetalLayer and the AVSampleBufferDisplayLayer have effectively IDENTICAL explicit EDR
configuration — and render differently.** Neither sets `toneMapMode` (both default `.automatic`);
neither sets `contentsHeadroom`. The discriminator is not a property either one sets: it is the
CONTENT PATH. A tagged PQ sample buffer gets AVFoundation's HDR presentation; a CAMetalLayer
drawable is raw pixels plus a colorspace with unknown headroom, and CGImage.h's rule — *"The image
with unknown content headroom will be excluded from tone mapping"* — excludes it.

**This also resolves the `toneMapMode = .never` null recorded above.** Had `.never` been honoured on
the overlay, the overlay would have moved TOWARD the Metal layer. It did not move at all, and it now
sits with the AVSampleBufferDisplayLayer. The only consistent conclusion is that **`.never` is not
honoured for a CALayer with assigned CGImage `contents`.** That measurement was not a dead end; it
was evidence that could not be read until this result arrived.

### THE DECISION, and the reasoning

**The desktop picture does not tone-map. Metal is the reference. The scrub overlay is approximate
during the gesture.** Three reasons, in the order they carry weight:

1. **⚠️ THE SCOPES READ THE SAME OFFSCREEN THE DISPLAY PATH DOES, AND THIS IS DECISIVE ON ITS OWN.**
   `MetalVideoRenderer.renderPixelFormat`'s own comment: *"Display, export, DeckLink and the SCOPES
   all read this target."* The waveform, parade, vectorscope and CIE are fed the shader's PQ code
   values. A picture that rolls a highlight off while this app's own waveform shows it hard against
   the ceiling **contradicts itself**, and the operator has no way to tell which to believe. For a
   tool that ships scopes, that is disqualifying by itself.
2. **DeckLink reads it too, so SDI and desktop must agree.** The SDI feed is the actual reference
   path to an actual reference monitor. Desktop and SDI are fed the same values and should not
   diverge. This is also what settles what the product IS.
3. **A display-adaptive tone-map is not reproducible.** Measured on the build Mac during this
   investigation: granted headroom **4.483** against a potential of **8.965**. It moves with display
   brightness, ambient light and whatever else is composited. **A picture that changes when you
   nudge the brightness slider is not a reference picture.**

#### The counter-argument, and why the scopes answer it

**Clipping at the display ceiling hides whether there is detail above the ceiling.** That is true and
it is the real cost of this decision: where a tone-map would show a roll-off preserving highlight
RELATIONSHIPS, this shows a flat clipped plateau, and you cannot tell by eye whether anything is up
there.

**The scopes are the answer.** They read the offscreen — the unclamped PQ code values, upstream of
every display mapping — so what is above the display's ceiling is fully visible on the waveform even
when the picture clips. The information is not lost; it is in the instrument built for reading it.
"This is beyond what your display can show" is also a fact a colourist wants stated plainly rather
than smoothed away, and a roll-off that varies with ambient light states it differently every time.

### ⚠️ THE LIMITATION, RECORDED HONESTLY

**During a scrub gesture on an HDR source, the preview is tone-mapped by Core Animation and the
played picture is not, so the two differ.** The overlay is dimmer and rolls highlights off earlier;
the played picture is brighter and clips. This is a real, visible, user-facing inconsistency and it
is being accepted, not fixed.

**⚠️ IT IS NOT FIXABLE BY ANY LAYER PROPERTY — but see option E below, which does not use one.**
Do not reopen the PROPERTY question without reading why each was eliminated:

- **`contentsHeadroom` — eliminated.** Deleted from the overlay; readback confirmed `0.0`; halves
  still differed.
- **`toneMapMode` — eliminated.** Set to `.never` on the overlay; readback confirmed
  `CAToneMapModeNever`; halves still differed. Now understood to be ignored on a CGImage-contents
  layer (see above).
- **`preferredDynamicRange` vs `wantsExtendedDynamicRangeContent` — eliminated.** A/B'd via
  `MANIFOLD_SCRUB_EDR_LEGACY=1`; no change.
- **The image's own headroom — UNCLEARABLE, because it IS the colorspace.** `hrprobe.swift` measured
  it: `CGImageCreateCopyWithContentHeadroom(0.0, …)` is silently ignored, and **plain
  `CGImageCreate` — an API with no headroom parameter at all — still yields 4.9261084.** The
  headroom is derived from `kCGColorSpaceITUR_2100_PQ`. There is no such thing as a PQ-tagged
  CGImage with unknown headroom.
- **Pixel values — identical.** `MODE=pixdiff` at 1:1 with no resampling: slope 1.000001, r =
  1.000000, resample-immune max 0.20 ten-bit codes. The generator and the decoder produce the same
  values. The difference is entirely in presentation.

**No setting makes a CALayer's CGImage take the drawable path.** That is the shape of the wall.

#### The three options that remain, and their disposition

1. **✅ ACCEPT AND DOCUMENT — TAKEN.** The mismatch exists only during the drag, on HDR sources, on
   a preview whose job is "which frame am I on". The played picture — the one being judged — is
   correct and is the reference. Cost: a visible brightness step at grab and release on HDR files.
2. **⚠️ OPTION E — feed the scrub frame into the EXISTING display path. RE-OPENED 2026-08-28, AND
   MOVED TO ITS OWN ENTRY:** *"⏸ BANKED: feed the scrub gesture from `AVPlayerItemVideoOutput` —
   one decoder, one display path"* below. **Do not plan from this paragraph — the reasoning, the
   risks and the spike gate are all there.**

   The short form: the original rejection measured ONE implementation (a second `AVAssetReader`
   path — 27 ms mean / 118 ms worst, long-GOP failing, and the reader-teardown race commit
   `8896163` fixed) and generalised from it. `AVPlayerItemVideoOutput` on a scrub-only `AVPlayer`
   has none of those three problems, vends a `CVPixelBuffer` instead of a `CGImage`, and would put
   the scrub frame through the same shader, offscreen and layer as playback — **identical by
   construction rather than by matching.** It also closes the scrub-POSITION defect and the stale-
   scopes defect at the same time. ⚠️ **UNMEASURED on two counts that must be spiked first;** see
   the entry.
3. **⏸ SUPPRESS THE OVERLAY ON HDR SOURCES — DEFERRED, and it trades one defect for an older one.**
   Technically trivial (`ScrubDebug.overlayDisabled` already does exactly this globally). But the
   overlay exists to fix the scrub-POSITION defect — without it, `scrubSeek` does no decode and the
   screen shows the PRE-DRAG frame for the whole gesture, which is the bug the overlay was built to
   remove. Trading a brightness mismatch for "the picture doesn't follow the scrubber" is a worse
   deal on a tool whose scrubber is its primary control.

### Made explicit in code, and VERIFIED, 2026-08-28

`MetalVideoRenderer`'s init sets `metalLayer.toneMapMode = .never`.

**✅ VERIFIED BY MEASUREMENT, NOT ASSUMED: the split was run with this set and THE SEAM WAS
UNCHANGED.** That null is the expected and desired result, and it is what closed this decision.
The line changes nothing today because the correct behaviour was already in force by another
route — this layer declares no `contentsHeadroom` and no `edrMetadata`, so its drawables have
UNKNOWN headroom and CGImage.h's rule excludes them from tone mapping.

**It is kept because the correct behaviour was a SIDE EFFECT of two ABSENT properties**, which any
future change could remove without anyone noticing. The line states the intent so that adding a
headroom tag later cannot quietly start tone-mapping the reference picture.

⚠️ `.never` may well be ignored on a `CAMetalLayer` exactly as it was measured to be ignored on the
scrub overlay's `CALayer` — the unchanged seam is consistent with BOTH "honoured and redundant" and
"ignored", and the two cannot be told apart while the behaviour is already correct. It is kept for
its declarative value under either reading. **If it is ever found to be honoured, it becomes
load-bearing and must not be removed.**

### If this decision is ever revisited — what E3 actually is

E3 is `metalLayer.edrMetadata`, marked "deliberately NOT set" in `setSourceColorSpace` since the E2
work. Three candidate spellings, and they are **not** equivalent:

- **`toneMapMode = .ifSupported`** — one line, macOS 15.0 (floor), and the header names it: *"Tone
  map whenever supported by the OS. This includes PQ, HLG and extended-range contents for CALayer
  and CAMetalLayers."* Blunt, and may be ignored as `.never` was.
- **`contentsHeadroom`** — the header says *"CAMetalLayers can use this value to define how much
  headroom is needed by their MTLDrawables"*, so it is documented for exactly this. But it is
  **macos(26.0)**, needs an availability branch, and leaves 15–25 unfixed — the same gap that has
  already bitten this feature once.
- **✅ `edrMetadata = CAEDRMetadata.hdr10(minLuminance:maxLuminance:opticalOutputScale:)` — the
  principled version, and CHEAPER THAN THE "NOT SET" COMMENT IMPLIES.** It needs mastering-display
  luminance, and **the app already parses it**: `MasteringDisplayInfo.maxLuminance` / `.minLuminance`
  in `ManifoldCore/HDR10Metadata.swift`, read at `FrameEngine.swift:1300` into `metadata.hdr10`, and
  already trusted enough to be shown in the Inspector. It is not plumbed to the renderer, so this is
  a ROUTING job, not a new colour input.

**If E3 is ever done, do it with the file's real mastering metadata, not a generic switch.** A
tone-map keyed to what the content was actually mastered for is defensible and reproducible; one
keyed to whatever headroom the display happens to be granting at that moment is precisely what
reason 3 above rules out. Note that `hdr10(minLuminance:maxLuminance:)`'s own header says *"Any
content greater than `maxNits' may be clamped when displayed"* — so even that route clips, it just
clips at a content-referred point instead of a display-referred one.

### ⚠️ THE REFRAMING THAT LOCATES THIS PROPERLY — it is a COLOUR MANAGEMENT CONSISTENCY defect

The same file opened in Video Village Screen, which exposes explicit colour-management modes,
behaves like this:

- **"Embedded"** shows the blown-out over-cranked grade — **what our Metal layer shows.**
- **"Match QuickTime"** tone-maps to an SDR-ish image — **what our overlay shows.**
- **Each mode HOLDS.** The picture changes between modes and stays put within one.

**So neither of our two paths is broken. Both are legitimate colour-management modes. Manifold is
simply in TWO MODES AT ONCE — and the defect is that one of them switches on whenever a hand is on
the scrubber.** The overlay's Core Animation tone-map is not a rendering fault to be hunted; it is a
different, defensible mode, arrived at by accident.

This also explains why QuickTime has no such problem, and the explanation is not that QuickTime is
better: **QuickTime is consistently in one mode.** Consistency is the property that matters here,
not which mode is chosen.

#### THE REQUIREMENT, stated so it can be tested

> **Whatever mode is active, the picture HOLDS — through play, pause, scrub, export and SDI.**

That is the invariant this defect violates, and it is the one to check any future change against.
Note that three of those five already agree by construction: export, SDI and the scopes all read the
same offscreen (see reason 1 above). It is the SCRUB path, and only the scrub path, that leaves the
set.

#### Cross-reference: this belongs with the banked colour-management work

`docs/COLOR_MANAGEMENT_FINDINGS.md` §6 already decided a mode picker for Manifold, with names:
**OS / Reference / Bypass**. Two notes for whoever picks that up:

- ⚠️ **The names above are Screen's, not ours, and ours were chosen deliberately against them.** §6
  explicitly REJECTED "Embedded" ("reading the file's tags is what *every* mode does — the name
  points at the wrong axis") and "Match QuickTime" ("loaded, and it names one application for a
  system-wide ColorSync behaviour that equally describes Safari, Preview, and Final Cut"). Use
  OS / Reference / Bypass when this is built; the Screen names are used here only because they are
  the vocabulary the comparison was made in.
- ⚠️ **This finding adds an AXIS §6 does not currently cover.** That table is about the SDR display
  transform (ColorSync's γ1.9609 vs an explicit BT.1886 2.4 vs none). What this investigation found
  is an **HDR headroom/tone-map** axis: whether the path adapts PQ to the display's granted headroom
  or maps it absolutely and clips. The two are related — both answer "what does the display path do
  to the values" — but a mode picker built only on the §6 axis would not resolve this defect.
  §5 already saw the same thing from the other side: *"Screen's modes diverge dramatically on PQ
  content"*, while collapsing to identical on SDR.

**§5's design consequence is the same argument as reason 3 above, already written down:** *"a
reference tool must not depend on the user having already calibrated their display in order for its
transform to be correct. Correctness that is contingent on the destination profile is not
correctness; it is a coincidence that happens to be common."* A tone-map keyed to a headroom that
moves with brightness and ambient light is exactly that kind of coincidence.

#### Does a supported Match-QuickTime-equivalent mode make the overlay CORRECT?

**Partly, and the distinction matters.**

**Yes** — in an OS-deferring mode, the overlay's Core Animation tone-map is not merely acceptable,
it is very close to *what that mode is asking for*. The overlay would stop being a defect and become
one path that happens to already implement the mode.

**But the problem does NOT reduce to "the two paths must agree on which mode is active", because
one of them cannot be steered.** Every mechanism for telling the overlay which mode to be in has
been eliminated by measurement (see the limitation above): its headroom is the colorspace and cannot
be cleared, `contentsHeadroom` and `toneMapMode` are both ignored on that path. So:

- In an OS-deferring mode, the paths agree only if the **Metal** path is made to tone-map — which is
  E3, and is achievable (`edrMetadata` with real mastering metadata).
- In Reference/Embedded-style modes, the paths agree only if the **overlay stops existing as a
  CGImage on a CALayer** — which is the scrub-architecture question below, not a colour setting.

**So the correct statement of the requirement is: every path must be STEERABLE to the active mode.**
Today the Metal path is steerable (E3 exists, and `toneMapMode = .never` now states its current
intent) and the overlay path is not steerable at all — it is pinned to one mode by the platform.
**That is the real defect, and it is why this is an architecture question rather than a colour
setting.** A mode picker built while the overlay remains a CGImage-on-CALayer would ship a control
that one of the paths ignores.

**The decision above stands unchanged.** The desktop picture is the reference and does not tone-map
— that is what the Embedded/Reference family means, and it is the correct DEFAULT. What this
reframing changes is where the fix lives (the colour-management mode work, plus the scrub
architecture) and what "fixed" means (every path steerable to the active mode, and the picture
holding across all five of play / pause / scrub / export / SDI).

### Instruments this produced, all kept

- `ScrubDebug.splitEnabled` (`MANIFOLD_SCRUB_SPLIT=1`) — the side-by-side split. **The only
  instrument in this investigation that produced a true result**, and it did so by removing
  sequencing: same frame, same window, same instant. Every earlier comparison was sequential and
  three of them returned confident wrong answers.
- `docs/scrub-fixtures/hrprobe.swift` — the headroom-is-the-colorspace measurement.
- `docs/scrub-fixtures/scrubmeas.swift MODE=pixdiff` — generator vs decoder pixel values, with
  resolution removed as a variable rather than corrected for.
- `docs/scrub-fixtures/wincap.swift` — HDR window capture via ScreenCaptureKit. ⚠️ Built because
  `screencapture` has **no HDR option** (checked) and `../color-fixtures/sweep.sh`'s PNG capture
  would have returned a clean null from an instrument that could not detect the effect — the same
  failure shape as the three dead instruments recorded above.

---

## ⏸ BANKED: feed the scrub gesture from `AVPlayerItemVideoOutput` — one decoder, one display path

**Status:** BANKED, not built, **not yet spiked.** **Raised:** 2026-08-28, out of the HDR scrub
investigation. **Precondition for:** the colour-management mode work
(`docs/COLOR_MANAGEMENT_FINDINGS.md` §6) — see the last section here, this is NOT a parallel task.

**It has its own entry because it is the common fix for THREE separate recorded problems**, and
buried inside the HDR argument it would read as a colour fix, which is the least of what it does.

### The three problems it closes at once

1. **HDR scrub mode divergence** — *"✅ DECISION 2026-08-28: the desktop picture is the REFERENCE and
   does not tone-map"* above. The overlay is a `CGImage` on a `CALayer` and is therefore pinned to
   Core Animation's tone-mapped path; the Metal layer is not. Routing the scrub frame through the
   existing display path makes them **identical by construction rather than by matching two
   pipelines** — which matters because every mechanism for matching them has been eliminated by
   measurement.
2. **Scrub-position frame mismatch** — *"⚠️ UNCONFIRMED: scrub release jumps the picture once, on
   ProRes"* above. Two decoders select frames independently; on long-GOP the shipping ±0.5 s
   generator tolerance was measured putting preview and reader **up to 11 frames apart, in both
   directions**. **With one decoder there is nothing left to disagree.** The whole class goes away
   rather than being narrowed.
3. **⚠️ THE SCOPES ARE STALE FOR THE ENTIRE SCRUB GESTURE — NOT RECORDED ANYWHERE BEFORE THIS, AND
   ARGUABLY THE WORST OF THE THREE.** The scrub overlay is a `CGImage` composited over the video
   rect; it **never reaches the offscreen ring**. The waveform, parade, vectorscope and CIE all read
   that ring (`MetalVideoRenderer.renderPixelFormat`: *"Display, export, DeckLink and the SCOPES all
   read this target"*). So for the whole drag they display the **pre-drag frame** while the picture
   shows a different one. **A colourist scrubbing to find a shot with a waveform up is reading a
   measurement of a frame they are no longer looking at, and nothing on screen says so.** No one
   reported it and no one had noticed it; it was found while arguing about colour. Any route that
   puts the scrub frame through the shader fixes it for free.

### The route

`AVPlayerItemVideoOutput` on a scrub-only `AVPlayer`, used as a **decoder and never as a transport**:
a warm decoder, AVPlayer's own toleranced seek — which is what QuickTime does when you drag — and
`copyPixelBuffer(forItemTime:)`, which vends a **`CVPixelBuffer`**. Hand it to
`MetalVideoRenderer.renderPixelBuffer` and the scrub frame goes through the same shader, the same
offscreen and the same layer as playback.

⚠️ **THE ARCHITECTURE ALREADY WORKS THIS WAY AND THE OVERLAY IS THE EXCEPTION.** Playback runs one
decoder into two surfaces: every decoded `CMSampleBuffer` goes to `vRenderer.enqueue(sb)` (the
`AVSampleBufferDisplayLayer`) **and** to the `onVideoFrame` tap the Metal renderer consumes —
`FrameEngine.swift:107`, `:1411`. The scrub overlay is the only thing in the app that adds a second
decoder and a third surface. `onVideoFrame` is also the clean seam for this: it already establishes
that the renderer accepts frames from an arbitrary producer rather than owning its source, so a
scrub producer needs no cooperation from the engine.

⚠️ **THE ROOT IS A RETURN TYPE, NOT DECODE COST.** `AVAssetImageGenerator` is already warm, already
fast (15 ms measured), already tolerant, and already handles long-GOP. It vends `CGImage` and only
`CGImage`, and that is what forces the Core Animation content path. Nothing about the current
preview is slow; it is the wrong shape.

### ⚠️ Why the three measured objections to "option E" do NOT apply

The original rejection measured **one** implementation — building a second `AVAssetReader` path —
and generalised from it. Against this route:

- **Reader churn / the teardown race fixed by commit `8896163`** — there is no `AVAssetReader` to
  rebuild or tear down. That failure mode is structurally absent, not mitigated.
- **27 ms mean / 118 ms worst** — that was the cost of a **reader rebuild**. This is a seek against a
  decoder that stays warm across the whole drag.
- **Long-GOP failing** — inverted here. **Tolerance is what makes long-GOP cheap on this route**,
  not what breaks it. It is the same trade the overlay already makes at ±0.5 s and the same one
  QuickTime makes; on all-intra it is exact anyway (measured, 80/80).

### ⚠️ `AVPlayerEngine` is already in the tree, unused, with this seek in it

`ManifoldCore/AVPlayerEngine.swift` conforms to `PlaybackEngine`, is currently used by nothing
(superseded by `FrameEngine`), and its `scrubSeek` is literally:

```swift
player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
```

That is the QuickTime scrub behaviour, sitting in the repository. **Manifold traded it away for
frame accuracy, timecode, SDI and scopes — which it needed more, and that trade was correct.** What
was not noticed at the time is that it also gave up the **single-decoder property**, and all three
problems above are the bill for that. This entry is not a proposal to undo the trade; it is a
proposal to get the property back without it.

### ⚠️ SPIKE FIRST — two unmeasured risks, before any implementation

**Neither is known, and an implementation started before they are answered is a bet.**

1. **Latency at drag rate.** AVPlayer's seek is async and must be coalesced (seek-in-flight plus a
   pending target — the standard AVPlayer scrubbing pattern). Whether it keeps up at ~20 Hz, and
   what it does on a fast drag, is unmeasured. Compare against the 15 ms the generator currently
   achieves; `docs/scrub-fixtures/scrubmeas.swift` is the harness to extend, since it already
   measures generator latency per request and replays the throttle against a synthetic drag.
2. **Memory and IO of a second decode pipeline on large sources — specifically 8K ProRes off a
   network volume.** That case is already called out in `MetalVideoRenderer` as the one where a
   33 ms budget is at risk from raster, codec and storage together. A second full decode pipeline
   against the same file over the same link is exactly the wrong thing to add there, and it may be
   the finding that kills this route for large media even if latency is fine on local ProRes.
   Measure both, on a network volume, before writing anything.

**Fallback if it measures badly:** drive `VTDecompressionSession` directly off a passthrough
`AVAssetReader`. Full control, vends `CVPixelBuffer`, no AVPlayer — but it means owning keyframe
tracking and GOP walking ourselves. **Substantial, and only worth it if the AVPlayer route fails on
one of the two risks above.**

### ⚠️ THE REQUIREMENT THAT SHOULD GOVERN THE COLOUR-MANAGEMENT WORK

> **Every path must be STEERABLE to the active mode — not merely agree with the other paths today.**

Agreement is a property of the current configuration and can be true by accident; steerability is a
property of the architecture. Measured state today:

| path | steerable to a mode? |
|---|---|
| CAMetalLayer (playback) | **yes** — E3 (`edrMetadata` with real mastering metadata) exists, and `toneMapMode = .never` now states its current intent |
| scrub overlay (CGImage on CALayer) | **NO — by nothing.** Headroom is the colorspace and cannot be cleared; `contentsHeadroom` and `toneMapMode` are both ignored on that path. All measured, see the DECISION entry |

**CONSEQUENCE, and it is the reason this is a precondition rather than a parallel task: a mode
picker shipped while the scrub preview is still a `CGImage` on a `CALayer` would ship a control that
one path SILENTLY IGNORES.** The user selects a mode, the picture obeys it, and the moment a hand
touches the scrubber the picture is in a different mode with nothing saying why. **That is worse
than the defect the picker was built to fix**, because a control that looks like it works is harder
to diagnose than a known inconsistency — and this investigation is itself the evidence for how long
that takes to unpick.

**So: spike this route BEFORE building the mode picker.** If it succeeds, the overlay stops existing
as a separate path and the picker has one display path to steer. If it fails on either risk, the
mode picker has to be designed around a permanently unsteerable scrub path — which is a different
design, and one nobody should discover halfway through building the other one.
---

## DeckLink devices are invisible on Desktop Video 14.x — we ask for an interface their driver has never heard of

**Status:** OPEN, cause identified from the SDK headers at **~85% confidence**, one fact still
needed before the fix direction can be chosen. **Reported:** 2026-08-27 by a tester (Joey).
**Blocks:** DeckLink output entirely, for anyone not on Desktop Video 16.x.

**The report:** the tester's device is seen by macOS, by Blackmagic Desktop Video and by Resolve —
and not by Manifold. Diagnostics:
`docs/Manifold-0.7.0-diagnostics-2026-08-27-195926.txt`.

```
DeckLink driver  : installed
DeckLink version : 14.5.0 [output floor: 14.3 — met]
DeckLink devices : none enumerated
DeckLink output  : unavailable — No device detected (Desktop Video 14.5.0)
```

Machine: Mac16,12 (M4), macOS 26.6.2. **Not an enumeration-lifetime problem** — the tester
relaunched the app and rebooted with the device attached, same result, so this is not a
sleep/wake or hot-plug gap.

### The cause: a versioned IID we ask for that his driver predates

We build against **DeckLink SDK 16.0.1** and `enumerateOutputDevices` filters every device through
`QueryInterface(IID_IDeckLinkOutput, …)` (`DeckLinkBridge.mm:848`). **`IDeckLinkOutput` is a
VERSIONED interface**, and its IID has changed repeatedly. From the SDK 16.0 headers — this table
is the evidence:

| interface | IID | vended by |
|---|---|---|
| `IID_IDeckLinkOutput_v10_11` | `CC5C8A6E-3F2F-4B3A-87EA-FD78AF300564` | ≤ 10.11 |
| `IID_IDeckLinkOutput_v11_4` | `065A0F6C-C508-4D0D-B919-F5EB0EBFC96B` | 11.0–11.4 |
| `IID_IDeckLinkOutput_v14_2_1` | `BE2D9020-461E-442F-84B7-E949CB953B9D` | 11.5–14.2.1 |
| `IID_IDeckLinkOutput_v15_3_1` | `1A8077F1-9FE2-4533-8147-2294305E253F` | **14.3–15.3.1** |
| **`IID_IDeckLinkOutput` (current)** | **`5F227C95-39D7-46C7-8B7D-9C81795FBBE4`** | **16.0+** |

A versioned header preserves the interface as it was at the version it is named for. So the
existence of `_v15_3_1` means **`IDeckLinkOutput` changed again in 16.0**, and drivers from 14.3
through 15.3.1 vend `1A8077F1`.

**The asymmetry is the whole bug. A NEWER driver serves OLD IIDs — that is what the versioned
headers exist for — but an OLDER driver cannot serve an IID that did not exist yet.** The
tester's 14.5.0 driver has never heard of `5F227C95`, so `QueryInterface` returns `E_NOINTERFACE`,
the device is silently dropped by the filter, the array comes back empty, and the app reports "no
output-capable device connected."

**His hardware is fine.** This is consistent with both machines: the build Mac runs 16.0.1 and
works; his runs 14.5.0 and does not.

⚠️ **This is NOT a one-line fix.** Two more interfaces the output path queries —
`IID_IDeckLinkVideoBuffer` (`:645`, `:1007`) and `IID_IDeckLinkVideoFrameMutableMetadataExtensions`
(`:661`) — exist **only in the current header, with no versioned variants at all**. So even a
repaired enumeration would hit the same wall one layer down. **Supporting 14.x means querying
versioned interfaces throughout the output path, not just for enumeration.**

### ⚠️ THE 14.3 FLOOR IS STALE AND FAILS UNSAFE — act on this regardless of the above

The floor was **reasoned from the SDK changelog, not measured.** SDK 14.3 is where
`IDeckLinkVideoBuffer`, `IDeckLinkMacOutput` and the `IDeckLinkOutput` revision landed (added
`CreateVideoFrameWithBuffer` / `RowBytesForPixelFormat`, removed
`SetVideoOutputFrameMemoryAllocator`) — which is exactly what the code comment means by *"the
IOSurface/zero-copy floor"*. That is a legitimate basis. **But nothing in the repo records a test
against any 14.3–15.x driver, and no such driver is available on the build Mac to test with.**

**It fails in the unsafe direction.** The floor ADMITS drivers 14.3–15.3.1 that the code cannot
actually talk to, so a tester on 14.5.0 is told **"floor: 14.3 — met"** and then watches a device
that silently does not work. A floor that passes a machine which cannot function is worse than no
floor, because it redirects the investigation away from the version.

**For an app built against SDK 16.0, the effective floor is 16.0.**

**THE CHOICE IS OPEN, and it is a real fork:**

- **Bump the floor to 16.0 and say so honestly in the UI.** Cheap, immediately correct, and it
  converts a silent failure into an actionable message. Cost: anyone whose hardware cannot run
  16.x loses DeckLink output entirely.
- **Query versioned IIDs throughout the output path.** Preserves old hardware. Costs a real
  compatibility layer across enumeration, `IDeckLinkVideoBuffer` and the metadata extensions, plus
  a way to test it that does not exist on the build Mac today.

**Which one is correct depends on whether Desktop Video 16.x still supports the affected
hardware — and that is NOT verifiable from this repo.** If 16.x dropped it, the tester is on
14.5.0 *by necessity* and old-driver support becomes a requirement rather than a courtesy.

### ⚠️ OPEN QUESTION — resolve before choosing, the model name is not established

**The tester's own diagnostics say "decklink mini monitor", twice** (Location, and "what they were
doing"). It was relayed as an **UltraStudio 3G**. Those are different products and the difference
decides the fix:

- **DeckLink Mini Monitor** — PCIe card. Cannot attach to a Mac16,12 laptop except through a
  Thunderbolt PCIe chassis.
- **UltraStudio Mini Monitor** — Thunderbolt 2, and **unsupported on Apple Silicon at all**. If it
  is this, that is a SECOND, INDEPENDENT reason it cannot work, and fixing the IIDs would not help.
- **UltraStudio Monitor 3G** — USB-C, current, fine on Apple Silicon.

**Get the verbatim model name from Blackmagic Desktop Video Setup before deciding anything.**

On the part that IS settled: all three are **playback-only devices, which is exactly what the
filter is looking for** — such a device vends `IDeckLinkOutput` and no `IDeckLinkInput`. There is
no capture-only trap here. The filter's logic is right; only the IID it asks for is wrong.

### What to ask the tester

1. **The verbatim model name** — the single most valuable answer, per the open question above.
2. **Can Desktop Video update to 16.0.1?** If it can and the device still appears afterwards, that
   confirms the diagnosis outright and unblocks him the same day. If Setup refuses, or the device
   disappears, his hardware is 14.x-bound and the fork above resolves toward versioned IIDs.
3. **Does Resolve still see it on the same boot, after any driver change?** Keeps the comparison
   clean.
4. **Not worth asking:** cables, ports, replugging. This failure is version-shaped, not
   connection-shaped, and enumeration lifetime is already ruled out.

**Related:** the enumeration filter is `DeckLinkBridge.enumerateOutputDevices` (`:833`); the floor
is `kDeckLinkFloorMajor`/`Minor` (`:785`); the reason this took a code read rather than a log read
is the next entry, *"DeckLink enumeration diagnostics cannot distinguish two different failures"*.

---

## DeckLink enumeration diagnostics cannot distinguish two different failures

**Status:** OPEN. **Found:** 2026-08-27, while diagnosing the entry above. **Blocks:** nothing at
runtime — it costs diagnosis time, and it cost a full code read this week.

Two messages describe the DeckLink device state, and they read **the same filtered array**, so
they cannot tell apart two genuinely different faults:

- `"DeckLink devices : none enumerated"` — `DiagnosticsExport.swift:720`, from
  `probeDriverStatusAndDevices()`
- `"no output-capable device connected"` — `DeckLinkService.swift:723`, from `.noDevice`, which is
  nothing more than `guard deviceCount > 0` (`DeckLinkService.swift:166`)

Both counts come from `DeckLinkBridge.enumerateOutputDevices`, which appends a device **only** if
it survives an output-capability filter:

```objc
while (iterator->Next(&device) == S_OK) {
    IDeckLinkOutput *output = NULL;
    HRESULT hr = device->QueryInterface(IID_IDeckLinkOutput, (void **)&output);
    if (hr == S_OK && output != NULL) { ...append... }
    device->Release();
    index++;                     // increments even when the filter rejects
}
```

**A rejected device is dropped silently, and the RAW ITERATOR COUNT IS NEVER RECORDED ANYWHERE.**
So these two states are indistinguishable in every log and every diagnostics export:

1. The iterator returned **nothing** — no hardware visible to the driver at all.
2. The iterator returned **a device that failed `QueryInterface`** — hardware present, interface
   mismatch. **This is what actually happened** in the entry above, and the output was identical
   to (1).

The `HRESULT` that would have named the difference is read into `hr`, tested, and thrown away.

### The fix, when it is done

- **Report the raw iterator count alongside the output-capable count.** `"3 device(s) seen, 0
  output-capable"` names the fault on sight; `"none enumerated"` actively misdirects toward cabling
  and hot-plug.
- **Log the `HRESULT` when the filter rejects a device**, with the model name, which is readable
  from `IDeckLink` before the `QueryInterface`. `E_NOINTERFACE` against a known model is the whole
  diagnosis in one line.

### ⚠️ THE PATTERN, which is worth more than this instance: three instruments this week

This is the **third** time in one week that an instrument looked like it was reporting and was
not. Each one cost real investigation, and each failed in the same shape — **a readout that stays
plausible after the thing it measures stops being connected to it.**

1. **`timebase−clock` returned `nil` for an entire 125 s verification run.** `liveAudioDrift`
   guarded on `liveAudioAnchor`, whose only writer (`anchorLiveAudio(at:)`) had been replaced by
   the mirror — so the guard was keyed to a field frozen at nil and printed `timebase−clock=n/a`
   throughout. As the source now says, that was *"precisely the number that was supposed to prove
   the mirror was holding"* (`FrameEngine.liveAudioDrift`).
2. **The `[DIAG]` byte count described the PREVIOUS export.** It is emitted after the text is
   written, so it can never describe its own file. Per commit `0b6a91c`, it *"misled two readers
   into diagnosing a truncation cap that does not exist."*
3. **This entry** — an enumeration count that reports the filtered result as though it were the
   raw one, so an interface mismatch is indistinguishable from absent hardware.

**What they have in common:** none of them was wrong about a value it computed. Each reported
faithfully on a quantity that was no longer the quantity a reader would assume — a stale predicate,
a stale ordering, a filtered count presented as a raw one. **A reading that is plausible and
unrelated is worse than a missing one**, because a gap prompts a question and a plausible number
ends the enquiry.

**The habit this argues for:** when an instrument is the thing that will prove a fix worked, check
what still writes its input before trusting the run — and prefer reporting BOTH the raw and the
derived quantity, since the disagreement between them is usually the diagnosis. All three of these
would have been caught by one extra number printed next to the one already there.

**Related:** the failure this masked is *"DeckLink devices are invisible on Desktop Video 14.x"*
above; the enumeration is `DeckLinkBridge.enumerateOutputDevices` (`:833`); the `[DIAG]` fix is
commit `0b6a91c`; the drift-readout fix is documented on `FrameEngine.liveAudioDrift`.

---

## A failed WHEP connect puts the server's entire HTML error page into the UI and the diagnostics file

**Status:** OPEN. **Found:** 2026-08-24, during Run C of the Wi-Fi streaming tests
(`docs/WHEP_LOADED_NETWORK_FINDINGS.md` §8).

The first WHEP connect of that session failed with **HTTP 403**, because the URL pasted was a
Slack permalink rather than the WHEP endpoint. That much is user error and the right outcome.

**The teardown was correct and is not the bug.** The route was released and the arbiter released
the device, exactly as designed. This entry is only about what the failure *said*.

**The bug is that the response body is treated as an error message.** Slack answered the request
with a full HTML page — a login/permission interstitial, roughly **78 KB** — and that body was
carried verbatim into:

1. **A user-facing banner**, which is now 78 KB of markup where a sentence should be. Nothing
   legible reaches the user; the actual fact ("403") is buried at the front of a wall of `<div>`s.
2. **The diagnostics export**, which is most of why that export is **241 KB**. A diagnostics file
   that is three-quarters someone else's HTML is materially harder to read and to attach to a
   report, and it dwarfs the streaming counters it exists to carry.

**Why nobody has reported it:** pasting a non-WHEP URL is an unusual mistake, and the failure is
still *technically* correct — it fails, it says 403, it cleans up. The damage is to legibility,
which nobody files a bug about; they just paste the right URL the second time.

**The fix has two halves, and the second one matters more.**

- **Detect an HTML response and do not show it.** A `Content-Type` of `text/html` (or a body
  starting `<!DOCTYPE`/`<html`) means the endpoint is not a WHEP server. Say that — "this URL
  returned a web page, not a WHEP endpoint; check that you pasted the publish/playback URL" — and
  discard the body.
- **Cap what any transport error can put into a banner or the diagnostics file**, independently of
  the HTML check. HTML is the case that turned up; a server returning a large JSON blob or a
  plain-text stack trace would do the same thing. A few hundred bytes is more than enough for any
  message a user can act on, and the cap belongs at the point the message is stored, not at each
  display site.

The second half is the one that generalises. Fixing only the HTML detection leaves the same defect
one unusual server response away.

---

## The vendored libdatachannel has no provenance chain, and it now carries a required patch

**Status:** OPEN. **Found:** 2026-08-25, during the WHEP NACK work.

`scripts/build_libdatachannel.sh` is supposed to be the reproducible recipe for
`ThirdParty/libdatachannel/`. **It does not currently complete on this machine** — the submodule
fetch fails — so the archive that shipped in every build to date was produced by *something other
than what the script reproduces*. Nobody can say from the repo what is actually in it.

This is unlike FFmpeg, where `ThirdParty/ffmpeg/README.md` plus `build_ffmpeg.sh` do establish a
chain from source to artifact. Here there is no chain, only an artifact.

**Why it now matters more than it did.** The library is no longer stock upstream. WHEP loss
recovery depends on `scripts/patches/libdatachannel-recvonly-rtcp.patch`, which removes the
`!handler` half of a guard in `impl::Track::outgoing`; without it a recvonly track refuses every
outbound RTCP sent via `Track::send`, so NACKs are built, refused, and never reach the wire. See
§12.1 and §12.6 of `docs/WHEP_LOADED_NETWORK_FINDINGS.md`.

**The failure is silent.** An unpatched library produces no error — retransmission simply does
nothing, which looks identical to a server that is not retransmitting. Three things guard against
it, none of which is a provenance chain:

1. `build_libdatachannel.sh` applies the patch right after the tag checkout, fails loudly if it
   does not apply, and then asserts the guard is actually gone from the source.
2. The refusal branch of `-sendNackForSequences:count:ssrc:` in `DataChannelBridge.m` names this
   patch by path in its log line.
3. `nacks built` vs `toWire` vs `refused` in the session summary separates "the library refused
   it" from "the server did not retransmit".

**State as of 2026-08-25.** Both working trees — `~/manifold-webrtc-build/libdatachannel` (the
script's own) and `~/ldc-nack` (a manual clone) — are patched, and the patched archive is staged
in `ThirdParty/libdatachannel/lib/`. That state was reached by a hand-driven build, not by a
script run, which is exactly the gap this entry is about.

**What would close it:** a `build_libdatachannel.sh` run that completes end to end on a clean
checkout, and a `ThirdParty/libdatachannel/README.md` that records the resulting artifact
hashes the way the FFmpeg one records its own.

**Blocks:** nothing today. It blocks *confidence* — specifically the ability to answer "is the
NACK patch in the library this DMG shipped with?" from anything other than a live test.

---

## NDI discovery publishes once a second whether or not anything changed, and every consumer of arbitration inherits the heartbeat

**Status:** OPEN. **Found:** 2026-08-26, while diagnosing the Window menu losing its
window-scoped items. **Blocks:** nothing today.

`NDIService.startDiscovery` polls on a 1 s loop and assigns the result unconditionally:

```swift
self.discoveredSources = NDIBridge.refreshDiscoveredSources()
```

`@Published` fires `objectWillChange` on every assignment, equal or not. `DeckRegistry.observe()`
sinks that publisher into `setNeedsArbitration()`, so **`applyArbitration` runs about once a second
for the life of any session with a window open** — discovery is reference-counted from
`ContentView`'s empty state and its streaming control, so in practice it is always running.

Nothing is wrong with the arbitration pass itself: it recomputes from current facts and is
idempotent by design. The problem is that it is a 1 Hz heartbeat that every future consumer
inherits, and each consumer has to work out for itself that it must not act on a change that
did not happen.

**What it has already cost.** `RasterMenuState.refresh` — reached from the pass — assigned its two
`@Published` mirrors unconditionally. `RasterSizeCommands` holds that object as an
`@ObservedObject`, so each no-op publish invalidated the app's `Commands` and SwiftUI rebuilt the
main menu. AppKit injects the window-scoped Window-menu items (Fill, Center, Move & Resize, Full
Screen Tile, Move to *display*, Arrange in Front, the tab section) only while the menu bar is
engaged, and a SwiftUI rebuild discards them for the rest of that tracking session. MEASURED,
probing `NSApp.windowsMenu.items` every 25 ms across a menu open:

```
menuBEGIN    MENU(8)     ← AppKit has not injected yet
track+25ms   MENU(26)    ← injected: the full set
…
RasterMenuState.refresh PUBLISHES (percent100 -> percent100, true -> true)
track+175ms  MENU(8)     ← SwiftUI rebuilt; the injected items are gone
```

The key window was unchanged throughout (`isKeyWindow=1`, `NSApp.keyWindow` non-nil at every
probe). From the outside this looks exactly like the window resigning key when the menu opens,
which is the wrong diagnosis and cost a full investigation to rule out.

That symptom is fixed at the consumer, in `RasterMenuState.refresh` (equality guards, with the
reasoning inline). This entry is about the publisher.

**⚠️ THE OBVIOUS FIX DOES NOT WORK, AND THAT IS THE POINT OF WRITING THIS DOWN.**

`if newSources != discoveredSources { discoveredSources = newSources }` suppresses nothing.
`NDISource` is an ObjC `NSObject` subclass (`NDIBridge.h:77`, `NDIBridge.mm:240`) with **no
`-isEqual:` and no `-hash`**, so it inherits pointer identity — and `refreshDiscoveredSources`
allocates a fresh instance per source on every poll (`NDIBridge.mm:422`). Array `!=` therefore
compares pointers and is true every tick, forever. Closing this means giving `NDISource` value
equality on `name` + `url` first (or comparing a derived key), and that is the part that would
otherwise be rediscovered the hard way.

**Related sites, from a scan done at the same time.**

- `SRTClient` — ALREADY DEFENDED, and its comment (`SRTClient.swift:102`) states this exact
  hazard: "`@Published` fires objectWillChange on every write, nil-to-nil included, and an
  unguarded assignment would re-render the view once a second for the life of the session."
- `WHEPClient.clearError()` / `SRTClient.clearError()` — unguarded, but only reached from
  user actions and connect attempts, never a repeated path. Not instances.
- `engine.volume = 1.0` written to an engine already at 1.0 — found separately during the
  SwiftUI "publishing changes from within view updates" work, same week.

Three sightings in one week, each defended (or not) at a different site. The pattern worth
naming: **a publisher that emits on a timer must compare before it assigns, because a consumer
cannot tell a real change from a heartbeat.**

**What would close it:** value equality on `NDISource`, then a compare-before-assign in the
discovery loop. Optionally a sweep of the remaining `@Published` writers that sit on timers or
polls, applying the same rule at the source rather than at each consumer.

---

## WHEP tears under packet loss, and we ship it on purpose

**Status:** ACCEPTED — WONTFIX, decided 2026-08-26. Not awaiting a fix; see the reopen condition
below. **Found:** 2026-08-26, in a conditioned-loss run. **Blocks:** nothing.

Under packet loss a WHEP stream shows **visible tearing** — bands of a previous frame's content
in an otherwise current picture. It is not a decode failure and no counter records it as one:
the run that surfaced it reported **0 decode errors** while tearing on screen.

**Mechanism.** An access unit missing a slice is detected and skipped rather than submitted (that
part is deliberate and is a large improvement — see the table in the findings doc). But skipping a
picture leaves a hole in the reference chain, and every later picture that references it is decoded
against a picture VideoToolbox never received. VideoToolbox returns `noErr` and hands back a wrong
image. `kVTVideoDecoderReferenceMissingErr` (-17694) exists but is never raised on this path, so
there is nothing to detect after the fact — it has to be predicted at skip time or not at all.

**Why it is not fixed.** The fix is to request a keyframe whenever a *reference* picture is
skipped. It is rejected because our encoder emits **no** disposable pictures: an offline census
found a low-latency x264 encode is 100% reference frames, and disposable frames require B-frames
or temporal layers. B-frames are unavailable — disabled in the OBS profile, and found to break
playback on Cloudflare's WHIP/WHEP path during DC Color Live's development, which is a **platform
constraint rather than a settings choice**. So every skipped frame is a reference frame, the fix
degenerates to "request a keyframe on every loss", and that is the behaviour removed the previous
day for costing ~22 frames per loss event.

The choice is therefore binary — tearing or freezing — and both were viewed side by side:

| | frames to screen |
|---|---|
| tearing (**shipping**) | 92% |
| freezing (keyframe wait) | 83% |

Tearing was judged substantially better. That is a viewing judgement, made by watching both.

**Why nobody has reported it:** it needs real loss to appear at all. Every clean-link session
looks perfect, and the tearing scales with packet loss, so a wired tester never sees it.

**What would reopen it:** a sender that emits disposable pictures — Cloudflare's B-frame handling
changing, or support for a non-Cloudflare WHEP endpoint using B-frames or temporal layers. Decide
it on the evidence, not on the argument: the `nal_ref_idc` census ships and costs nothing, and the
teardown line `[WHEP-RTP] reference census — …` reports the disposable share directly.
`disposable=0` means this entry still stands.

**Full reasoning, the measurements, and the two things still on the board** (a bounded reorder
buffer, and a provable tightening of the head-loss over-drop):
`docs/WHEP_LOADED_NETWORK_FINDINGS.md` §13.

---

## WHEP and SRT carry no audio at all, so a remote stream cannot be monitored or metered

**Status:** OPEN. **Found:** 2026-08-26, during the audio-meter audit. **Blocks:** audio
monitoring and metering on the two remote-contribution paths.

⚠️ **This is not a meter limitation.** The meters will correctly report "NO AUDIO TRACK" on these
sources, and that report is accurate — there is no audio to meter, because these transports
decode none. Fixing the meters would change nothing. The defect is upstream, in the transports.

**Correction to a natural assumption: NDI is NOT in this category.** NDI has a complete audio
path — a dedicated pump thread (`NDIService.startAudioPump`, started on connect regardless of
DeckLink) pulls from the framesync via `captureAudioFrameForMaxSamples:` and pushes interleaved
Int32 into the shared `AudioTapBuffer`. NDI plays audio and meters correctly today. The gap is
WHEP and SRT only.

**WHEP.** Audio is negotiated and then deliberately thrown away. The offer carries
`m=audio 9 UDP/TLS/RTP/SAVPF 111` / `a=rtpmap:111 opus/48000/2`, and the track's message callback
is `ManifoldWHEPDiscardMessage` — packets are received and dropped so libdatachannel's queue does
not back up. There is no Opus decoder anywhere in the app.

**SRT.** Audio elementary streams are identified at demux and skipped, with the reason stated in
the log: *"stream %u: %s / %s (ignored — audio is a later arc)"* (`SRTSession.m`).

**Why it matters more than it looks.** This is arguably where metering matters MOST. A colourist
reviewing a local file can hear it, scrub it, or open it in something else; a colourist on a
remote stream has no other instrument at all. "Is the feed carrying audio, and on which channels"
is a question they currently cannot answer from inside Manifold — and cannot answer by any other
means either, because the stream is ephemeral.

**Why nobody has reported it:** both transports were built as picture-first arcs and the audio
omission is documented in their own source, so it reads as known-and-intended rather than as a
defect. Nothing in the UI said otherwise until the meters gave the absence somewhere to show.

**What would close it.** Neither needs a new dependency — but the reason is not the one first
recorded here.

> ### ⚠️ CORRECTION (2026-08-27) — this section previously claimed the vendored FFmpeg has a native Opus decoder. IT DOES NOT.
>
> The original wording was *"FFmpeg is already vendored and has a native Opus decoder, which was
> the part that looked expensive."* **False.** Upstream FFmpeg has a native Opus decoder; **our
> build does not contain it.** `--disable-everything` strips every built-in decoder, and the
> configure line re-enables 10 by name — `opus` is not among them. Verified by loading the shipped
> dylib and enumerating it, not by inference:
>
> ```
> decoder opus : MISSING
> --- all registered decoders (10) ---
>   dnxhd  prores  aac  aac_latm
>   pcm_f32le  pcm_s16be  pcm_s16le  pcm_s24be  pcm_s24le  pcm_s32le
> ```
>
> **How the error was made, because the method is the reusable part:** the check was
> `strings libavcodec.62.dylib | grep -i opus`, which hits `Opus (Opus Interactive Audio Codec)`.
> That string lives in `libavcodec/codec_desc.c` — an **unconditional** object file listing the
> name of every codec ID FFmpeg knows, independent of build configuration. The same dylib also
> contains `Apple ProRes RAW` and `Canopus HQ/HQA`. **A capability check must read something that
> changes when the build changes** — `--verify-only`, or `config_components.h`. Full write-up:
> `ThirdParty/ffmpeg/README.md` → *"`strings` is the same mistake wearing a different hat"*.
>
> **This cost real planning.** A rebuild of all five vendored dylibs was scoped on the strength of
> it, and would have shipped a decoder nothing calls. It is not needed — see the decided path
> below.

### ✅ DECIDED: WHEP audio decodes Opus via AudioToolbox. Do not reopen libopus vs. libavcodec.

**macOS decodes Opus natively**, so the expensive-looking part does not exist. Verified on this
machine rather than assumed — `kAudioFormatProperty_DecodeFormatIDs` returns 51 formats and
`kAudioFormatOpus` is one of them; `AudioConverterNew(Opus → LPCM int32)` succeeds. Apple documents the constant as available since macOS 10.13 — far below our 15.0 deployment
target — so there is no availability guard to write. (The 10.13 figure is from Apple's
documentation; what was verified here is that it works at the target we actually ship.)

**Three options were on the table. Two are closed:**

| Option | Verdict |
|---|---|
| **AudioToolbox `AudioConverter`** | **CHOSEN.** No dependency, no build change, no licence entry. |
| Vendor `libopus` | **Rejected.** A whole new vendored dependency — build script, provenance, `THIRD_PARTY_NOTICES` — for something the OS already does. |
| `--enable-decoder=opus` in vendored FFmpeg | **Rejected.** Viable, but costs a full rebuild of all five dylibs plus the five-consumer verification pass, for a second decoder no call site would use. |

**It is measured, not merely working.** 101 raw Opus packets (2.02 s of a 1 kHz tone, libopus-encoded
at 96 kbps, Ogg pages stripped so the input matches what RTP delivers):

| | peak |
|---|---|
| source tone before encoding | −21.1 dBFS |
| FFmpeg's own decode (reference) | −21.0 dBFS |
| **this path (AudioToolbox)** | **−21.0 dBFS**, 96840 frames = 2.018 s |

Level-accurate to 0.1 dB against FFmpeg, and the right duration. Implementation:
`App/WebRTC/WHEPAudioDecoder.swift` (`WHEPOpusDecoder`), driven by `App/WebRTC/WHEPAudioReceiver.swift`.

**What remains:**

- **WHEP:** an RTP Opus depacketizer (RFC 7587 — one Opus frame per packet, essentially no
  reassembly, far simpler than the H.264 case), then `WHEPOpusDecoder` →
  `AudioTapBuffer.pushInterleavedInt32`. Replace `ManifoldWHEPDiscardMessage` on the audio track
  with a real handler.
- **SRT:** stop skipping the audio PID, decode it with the vendored FFmpeg (AAC or MP2 on a
  typical TS contribution feed), and tee to the same seam. **This one genuinely does use libav** —
  `aac` and `aac_latm` are in the 10, so it needs no build change either. MP2 is **not** in the
  build; if a feed turns out to carry MP2, that is a real gap to re-scope, not an assumption to
  make now.

  ⚠️ **THE SRT AUDIO PATH MUST NOT ASSUME STEREO. WHEP CAN; SRT CANNOT.** These two are not
  symmetric and building them from one template would design multichannel out of the product
  before anyone noticed. **WHEP audio is stereo BY CONSTRUCTION** — Cloudflare answers
  `opus/48000/2` with no channel mapping family, so that path can never carry more than two
  channels no matter what the publisher does (and what happens when a publisher tries is its own
  entry, *"A publisher configured for 5.1 against a stereo Opus negotiation produces pure
  NOISE…"* below). **SRT is different: MPEG-TS carries multichannel AAC with the layout declared
  in the mux.** A 5.1 or 7.1 contribution feed over SRT is ordinary, the declaration is there to
  be read, and the decode must carry the channel count and the layout through to
  `AudioTapBuffer` rather than folding or truncating to two on the way. Written here rather than
  on the fold entry so it is in front of whoever builds this.

Both are additive, both end at the same `AudioTapBuffer` the file and NDI paths already feed, and
neither touches the video path. Once either lands, its meters light up with no change to the
meter code — the tap is the seam.

**Related:** the meters themselves are `App/AudioMeterScope.swift`; the audio path audit that
found this is summarised there and in `AudioTapBuffer.peaks(endingAt:)`. The full discovery chain
— this was the first of four gaps found from one feature request — is `docs/AUDIO_PATH_FINDINGS.md`.

---

## A publisher configured for 5.1 against a stereo Opus negotiation produces pure NOISE, with a completely clean log

**Status:** OPEN — trigger known, mechanism inferred, detection unsolved. **Found:** 2026-08-27, on a detour from the
multichannel fold scoping. **Blocks:** nothing structurally; what it costs is diagnosability. A
tester who hits this sends a log that says nothing is wrong.

**Reproduction:** set OBS's audio output to 5.1 while its publish to Cloudflare has negotiated
`opus/48000/2`. Manifold's audio is noise — not distorted programme, not intermittent, noise.

**Diagnostics:** `NOISE.txt` (Desktop/MBA_ManifoldTests), first session `16:12:00 → 16:14:17`.

### Every counter reads healthy. That is the defect worth recording.

| | first session |
|---|---|
| audio packets | **6055** (121.10 s decoded) |
| `failed` / `sbFail` | **0 / 0** |
| `malformed` | **0** |
| audio `seq gap(s)` | **0** |
| decoded audio vs wall clock | **1:1 — 75.8 s of audio at `pts=75.835s`** |
| `timebase−clock`, steady state | **mean −0.84 ms, σ 1.69 ms** (n=100, after the ramp) |

Even the startup shape matches: the first ~20 s ramp (`+253 ms` at the first sample, decaying
through `−60.9 ms` before the mirror's first push pulls it back) is the same ramp the known-good
run shows (`+86.5 ms` → `−66.9 ms` over its first 13 s). After it, the noise run holds
`−5.1 … +3.2 ms`.

There is no observable difference from a correct session anywhere in the log except that the
output is noise. The decoder is handed packets, accepts them all, produces full-length output at
the right rate, and the clock mirror tracks perfectly. **Everything downstream of the payload is
behaving correctly** — which is what the inferred mechanism predicts: the payload is structurally
valid Opus, just not the Opus the decoder was configured for, so nothing in the chain has anything
to complain about. That mechanism is INFERRED from the trigger and from the decoder's silence; it
is not yet confirmed against the packets.

### ⚠️ Detection at negotiation: REFUTED, checked rather than assumed

The read going in was that this is knowable at negotiation rather than from payloads, since Opus
multichannel requires `channel_mapping=1` in the fmtp line. **Checked against both logs, and it
does not hold on this topology.** The audio m-section is byte-identical between the noise run and
a known-good run:

```
a=rtpmap:111 opus/48000/2
a=fmtp:111 minptime=10;useinbandfec=1
```

— the server's answer m-section (`NOISE.txt:314`) and the negotiated track description
(`:337`), against `…120716_MBA12.txt:314` and `:337` for the good run. Same two lines, in both
places, in both runs. No `channel_mapping`, no `num_streams`, no `stereo=` / `sprop-stereo=`
anywhere in either. (Manifold's own offer is not logged verbatim for audio, so the comparison is
of what came back — which is the half that would have had to carry the signal.)

### Can the receiving side know the source channel count at all? NO — and that changes the approach

**We do not negotiate with the publisher.** The answer Manifold applies comes from Cloudflare, and
it describes what Cloudflare will send us. Nothing in it describes OBS's local audio
configuration, and there is no field in which that could arrive — the publisher's mistake is made
on the far side of a relay that has already told us, correctly, that we are getting `opus/48000/2`.

So there is no negotiation-time check to write. **Any detection must come from the payload or from
the decoded audio, or it does not exist**, and neither has been tested. What would test the first:
read the Opus TOC byte on arrival and check whether the frame is a mapping-family-1 multistream
packet rather than the stereo packet the decoder was configured for. That is a real experiment and
it is not done — do not write it up as a plan until it has been run against this capture.

Note what the alternative would cost even if it worked: the honest fallback is a UI statement
about publisher configuration, not a check. That is a worse outcome, which is why the payload
experiment is worth running before settling for it.

### ⚠️ The payload-size heuristic: REFUTED, and the arithmetic is why

Recorded here because the refutation is more useful than the hypothesis was. The observation that
prompted it — noise mean **542 B/pkt**, σ **240.5**, min **15.0**, against a good run's mean
**626.3**, σ **77.5** — is arithmetically correct and **compares the wrong things**. Both figures
are whole-FILE pools, and neither file holds one uniform session:

| sample | n (per-second) | mean B/pkt | σ | min |
|---|---|---|---|---|
| `NOISE.txt` **whole file** (3 sessions) | 148 | 542.0 | 240.5 | 15.0 |
| `NOISE.txt` **session 1 — the noise one** | 121 | **652.9** | **47.1** | 500.2 |
| `NOISE.txt` sessions 2 + 3 (9 s, 18 s, near-silent) | 27 | 44.9 | — | 15.0 |
| `…MBA12.txt` **good run, whole file** | 776 | 626.3 | 77.5 | 3.0 |
| `…MBA11.txt` good run, no silence window | 55 | 626.3 | 35.8 | 533.1 |

**Like for like, the noise session's distribution is TIGHTER than the good run's** — σ 47.1
against 77.5 — and its mean is 4% higher, not lower. The pooled σ 240.5 is produced entirely by
two short near-silent sessions at the end of the file, and the good run's σ 77.5 is inflated by
its own known 5-second silence window (§14.5 of `WHEP_LOADED_NETWORK_FINDINGS.md`). Strip both and
the two runs are indistinguishable on this measure.

The byte accounting is the same in both builds — `_audioBytes += (end - headerLength)`,
`DataChannelBridge.m:1211`, payload only — so the comparison is valid; it is the *pooling* that
was wrong, not the units. **There is no payload-size signature here**, and the "three times the
variance" reading should not be carried forward.

(It remains true that OBS was encoding different input in the two runs, so even a surviving
difference would not have been controlled. That caveat is now moot but worth keeping: the
experiment that would settle it needs the same source content on both sides.)

### What is left

- **Run the TOC-byte experiment** against `NOISE.txt`'s capture before designing anything.
- **If it is not detectable, say so in the UI rather than silently playing noise** — this is the
  one failure mode in the WHEP path where every instrument reads healthy, so the instruments
  cannot be the answer.

**Related:** the negotiation and decode path is `App/WebRTC/WHEPAudioReceiver.swift` and
`WHEPAudioDecoder.swift`; the stereo-by-construction consequence for multichannel work is on
*"BANKED: an OPTIONAL stereo fold for multichannel tracks…"* below; the run's own timing evidence
is §14 of `docs/WHEP_LOADED_NETWORK_FINDINGS.md`.

---

## SDI carries the monitored track's channels discretely, in FILE order, and never states the mapping

**Status:** OPEN. **Found:** 2026-08-26, during the DeckLink audio-path audit that preceded the
track selector. **Blocks:** trustworthy surround monitoring over SDI. (It does **not** block
stereo monitoring over SDI — that is an optional capability, not a defect; see the BANKED entry
below.)

⚠️ **Two things that sound like this bug are NOT true, and were checked in the code before this
entry was written.** Getting them wrong points the fix in the wrong direction:

- **The DeckLink path does not downmix. It never has.** The entire channel mapping is
  `d[c] = s[c]` for `c` in `0..<srcChannels` (`DeckLinkBridge.mm`, `RenderAudioSamples`). Source
  channels are written to wire channels 1..n in file order; the padding to the SDK-legal count
  (2/8/16/32/64) fills the remainder with digital silence. No summing happens anywhere in the
  path — not in `AudioTapBuffer`, not in the bridge. Nothing uses
  `AVAssetReaderAudioMixOutput`; the file path uses `AVAssetReaderTrackOutput` and
  `audioOutputSettings` takes `AVNumberOfChannelsKey` from the track's own ASBD.
  **MEASURED 2026-08-26** with a purpose-built file whose FIRST audio track is 5.1 (needed
  because track 1 of the three-track test file is mono):
  `AudioTap[AVF]: format → 48000Hz · 6ch (→ 8ch on SDI)` — **six channels, not two.** A downmix
  would have produced 2; and the mono track of the other file produced 1ch, which a stereo
  downmix could not do either.
- **There is no `MAX_AUDIO_CHANNELS` constant, and the bridge does not assume stereo.** Both
  scratch buffers are sized from the runtime counts (`m_srcScratch` from `srcChannels`,
  `m_outScratch` from `dlChannels`), `scheduleSilence` clears `frames * dlChannels`, and the
  frame arithmetic is per-sample-frame, so it is channel-count agnostic. A 6-channel track already
  reaches SDI as six discrete channels today, and the start log reports it as
  `"source %u ch, %u padded silent"`.

**What is actually wrong** is the inverse, and it has been true since the audio arc shipped:

**1. NOT A DEFECT — discrete pass-through is the correct default, and it stays.** ⚠️ **This item
previously read as a defect ("there is no downmix, and there should be a choice"). That framing
was wrong and is retracted.** SDI usually feeds an amp and speakers expecting six discrete
channels, and folding to stereo by default would send a stereo mix into a surround room with half
of it in the centre speaker. A stereo fold on SDI is a real want for a real case — a colourist
with a stereo monitoring pair on the SDI output, working a 5.1 or 7.1 deliverable — but it is an
**optional** per-destination capability for a non-default room, scoped in *"BANKED: an OPTIONAL
stereo fold for multichannel tracks…"* below, not a fix owed here. Items 2 and 3 are the actual
defects in this entry.

**2. The mapping is never stated.** Whichever behaviour is active, nothing in the UI or the
inspector says what is on the wire. A discrete 6-channel feed and a stereo downmix are different
signals and the user cannot tell which they are receiving.

**3. Channel ORDER is file order, with no layout awareness.** Nothing in `AudioTapBuffer`,
`DeckLinkService` or `DeckLinkBridge.mm` reads an `AudioChannelLayout` — `AudioTapBuffer.Format`
carries `sampleRate`, `channelCount`, `deckLinkChannelCount`, `path` and no roles. So a
Film-ordered 5.1 (`L C R Ls Rs LFE`) goes to the wire in that order, putting **C on SDI 2** (read
as R) and **LFE on SDI 6** (read as Rs). SMPTE-ordered 5.1 (`L R C LFE Ls Rs`) happens to be
correct, which is why this has not bitten yet.

**Note the desktop path is not affected by (3).** `audioOutputSettings` requests the source's own
`AVChannelLayoutKey` (`FrameEngine.swift`), the renderer receives buffers carrying that layout, and
CoreAudio does the role→speaker mapping. The same buffer is therefore mapped correctly to the Mac's
output and written blind to SDI. The tap is where the roles are dropped.

**Desktop and SDI legitimately differ, and anything built here must allow that.** Mac speakers are
stereo whatever the file is; the SDI monitor usually feeds a surround room. "Downmix" is not a
global mode — it is a per-destination choice, and the correct default for one is not the correct
default for the other. Both defaults were measured on 2026-08-27 and both are correct: CoreAudio
already folds for the desktop, SDI passes through discretely. See the BANKED entry.

**So the fix here is: send all channels — correctly ordered — and state the mapping.** The channel
count is not the open question; the ROLE ORDER is, and so is the fact that nothing tells the user
what is on the wire.

**Gated on the `chan` atom layout work.** Fixing (3), and stating the mapping honestly for (2),
both mean reading per-channel roles — without them the wire order is a guess dressed as a mapping. The good news is that the derivation already exists and is
correct: `MediaInspector.channelRoles(from:)` walks
`kAudioChannelLayoutTag_UseChannelDescriptions` per-channel descriptions properly (with a correct
flexible-array-member offset and a bounds check) and falls back to known tags via `roleSequence`,
and `layoutName(forRoles:)` already distinguishes `"L R C LFE Ls Rs"` → 5.1 SMPTE from
`"L C R Ls Rs LFE"` → 5.1 Film **by sequence**. It is `private`, lives in `MediaInspector`, and
terminates in a display string. The work is to publish it, carry the role array on
`AudioTapBuffer.Format`, and replace `d[c] = s[c]` with a role→wire-index table.

Undeclared files remain unfixable and must be labelled rather than guessed: a 6-channel track with
no `chan` atom yields no roles, gets `"5.1 (inferred)"` as a name from the count, and can only
honestly be sent in source order.

**Also missing, and cheap to add with it:** the app never queries
`IDeckLinkProfileAttributes` / `BMDDeckLinkMaximumAudioChannels`, so it does not know what the card
supports — a too-wide `EnableAudioOutput` fails and aborts the whole output start rather than
degrading. And it passes `bmdVideoConnectionUnspecified`, so it cannot tell SDI (up to 16 channels)
from HDMI (up to 8).

**One phase-1 consequence to fold in.** The track selector switches which track feeds the tap, so a
switch that changes the channel count (mono → 5.1) fires `AudioTapBuffer.onFormatChange` →
`DeckLinkService.audioFormatChanged`, which re-establishes the output — and that stop/start takes
the SDI **video** with it, so the monitor blinks. The card's rate and channel count are fixed at
`EnableAudioOutput` and genuinely cannot change under a running stream, so the fix belongs here:
enable at a count sized to the file's **widest** track and pad the narrower ones, after which no
track switch changes the enabled format and SDI never re-establishes.

**Related:** the mapping itself is `DeckLinkBridge.mm` `RenderAudioSamples`; the role derivation to
publish is `MediaInspector.channelRoles(from:)`; the multi-track gap that has to land first is
*"A file's second and third audio tracks are unreachable…"* above; the chain that found all of it,
with the measurements and the test-file recipe, is `docs/AUDIO_PATH_FINDINGS.md`.

---

## A file's second and third audio tracks are unreachable, while the inspector reports all of them

**Status:** OPEN. **Found:** 2026-08-26, during the audio-meter audit. **Blocks:** monitoring any
audio track but the first — which for a mixed-deliverable file is most of them.

`FrameEngine` takes `loadTracks(withMediaType: .audio).first` and builds a single
`AVAssetReaderTrackOutput` from it. A file carrying mono, stereo and 5.1 mixes plays the first;
the other two are **not decoded, not rendered, not tapped, and not sent to SDI**. The libav path
has the same shape — `LibavAudioSource.open()` scans streams and `break`s on the first audio one.

⚠️ **This is a PLAYBACK gap, not a display gap**, and it was found by mistaking it for one. The
meters showed a single mono bar for `MONO_STEREO_51.mov` and the meters were *right* — they were
correctly describing what the engine was playing.

**The defect is the app disagreeing with itself.** `MediaInspector.audioTracks` enumerates the
asset directly and correctly reports "Audio (3)" while playback offers one, so the inspector and
the transport describe different things with no indication that they differ. Of the two the
inspector is the honest one.

(The *inverse* asymmetry also exists and is documented on `FrameEngine.audioPresence`: on MXF,
AVFoundation cannot open the container so the inspector is blind while the decoder is right.
Neither surface is authoritative on its own — which is exactly why the disagreement has to be
resolved rather than papered over by trusting one of them.)

**Measured** on `/Volumes/DCCOLOR/TEST FLIP/MONO_STEREO_51.mov` (ProRes HQ 4K 23.98p; three PCM
24-bit/48 kHz tracks — mono, stereo, 5.1):

```
FrameEngine: loaded — duration 5.005s, audio tracks: 3 (monitoring #1)
AudioTap[AVF]: format → 48000Hz · 1ch (→ 2ch on SDI)
```

**The phase-1 plan** (audited as workable; not yet implemented):

- A **track selector in the control bar**, first in the group with scopes / DeckLink / streaming.
  It governs **playback**, not just metering — a colourist with mono, stereo and 5.1 in one file
  needs to *hear* each of them — so it belongs with the output controls, not inside a scope slot
  that may not be open.
- **Mirrored in the inspector's Audio section**, where the tracks are already described. Same
  state, two entry points.
- **The meters follow the monitored track** for free: the tap is teed off the same enqueue that
  feeds the audio renderer (`tap.ingest(next)` and `aRenderer.enqueue(next)` are adjacent lines),
  so one selection governs speakers, meters and SDI with no further wiring. A separate "all
  tracks" option in the meter header stays **display-only**, for inspection, so *"what am I
  hearing"* and *"what is in the file"* remain separate questions with separate controls.
- **Switching rebuilds the reader at the current position.** `AVAssetReader` outputs must all be
  added before `startReading()` and cannot be added after, so switching tracks means a new reader
  — which is exactly what `beginReading` is, and what `seek(to:)` already calls for every scrub.
  A switch therefore costs precisely what a seek to the current position costs. Position and play
  state are preserved and A/V sync is re-anchored at the same time; the visible cost is a brief
  re-decode hitch, short on intra-frame codecs and longer on long-GOP, where the reader must
  decode from the preceding keyframe.

**Two consequences to design for, not discovered late:**

- **A cheaper switch exists but changes the failure modes.** Adding every track's output to the ONE
  reader up front and re-pointing the pump would leave the video untouched entirely — but
  `startReading` is all-or-nothing, and one malformed track would take the others down with it.
  The existing retry (see the ARRI ALEXA `0xFFFF0000` note in `beginReading`) drops *all* audio on
  failure and would need to degrade per-track instead.
- **The libav path cannot offer the choice.** MXF/DNxHR files hold no `AVAssetTrack` list, so a
  multi-track MXF still cannot be switched. That is a separate implementation, not a wiring gap,
  and the UI must say so rather than offering a control it cannot honour.

**Related:** the SDI half of this is *"SDI carries the monitored track's channels discretely…"*
above; the chain that found it is `docs/AUDIO_PATH_FINDINGS.md`.

---

## BANKED: an OPTIONAL stereo fold for multichannel tracks, per destination

**Status:** BANKED — optional capability, not scheduled, **not a defect on either destination.**
**Raised:** 2026-08-27, once the track selector made choosing a 5.1 track possible.
**Rewritten:** 2026-08-27, after the measurement below removed the defect from both halves.
**Pairs with:** *"SDI carries the monitored track's channels discretely…"* above, which holds the
SDI-side mapping and layout work this would sit on top of.

⚠️ **This entry used to describe a defect on the desktop and a defect on SDI. Neither survived
measurement. Both defaults are correct and both stay.** What remains is one optional feature for
a room Manifold cannot see and is never told about — read it as a capability request, not as
something broken.

### The desktop default is already right — MEASURED 2026-08-27

Local file playback in Manifold: a 6-channel file with signal isolated to C, monitored on the
Mac's own stereo output. **The centre channel is audible** — dialogue is clearly heard through the
stereo speakers.

The meters corroborate that the buffers really are six discrete channels with the signal only on
C, so the fold is happening downstream of them and not by accident of the file: 6 ch with the
roles read from the file (`L R C LFE Ls Rs`), **C at ≈ −6 dBFS, L and R at ≈ −57 dBFS**.

So CoreAudio's output unit already folds a layout-tagged multichannel buffer to stereo on the real
playback path (`AVSampleBufferAudioRenderer` → CoreAudio). **Dialogue is not being lost on the
desktop today.** The desktop side of this feature is therefore about **CONTROL** — choosing *not*
to fold, or choosing the coefficients — and it is **low priority**, because the default behaviour
is the one you would pick anyway.

### ⚠️ The near-miss, recorded because the method is the reusable part

The measurement that motivated this entry was **correct and irrelevant**, which is the more
dangerous combination.

MEASURED earlier on 2026-08-27: `AudioConverter` asked to take 6 ch tagged 5.1 SMPTE down to
stereo **discards rather than mixes** — with signal on one channel at a time, only L and R
survive; C, LFE, Ls and Rs all come out at **−99 dB**. That number is real and reproducible. It is
also about a component **the real playback path never calls.** Playback runs through
`AVSampleBufferAudioRenderer` into CoreAudio's output unit, which has its own multichannel→stereo
matrix behaviour, and which is what the listening test above actually exercised.

A whole feature — "restore the lost dialogue on the desktop" — was scoped on a measurement of the
wrong component. **What caught it was this entry's own instruction to verify before building.**
The test cost one minute: play a 5.1 file with signal only on C, on a stereo output device, and
listen.

**Keep that pattern.** Every claim here that a destination is or is not folding must be settled by
listening to the destination, on the path a user actually uses, before anything is built on it.
Measuring a component in isolation says what that component does, not what the app does.

### The SDI default is already right too — discrete pass-through stays

`d[c] = s[c]` is deliberate and correct for the room SDI usually feeds: an amp and speakers
expecting six discrete channels. **Folding there by default would be wrong** — it would send a
stereo mix into a surround room and put half of that mix in the centre speaker. Pass-through is
the default and stays the default.

### The feature: an optional per-destination stereo fold

The real and specific case it serves: **a colourist with a stereo monitoring pair on the SDI
output, working on a 5.1 or 7.1 deliverable**, who wants to hear the whole mix — dialogue included
— without rewiring the room.

**Manifold does not know the room's layout and never asks.** It cannot infer it, and no counter or
declaration in the file can tell it. **This setting is how the user says.** That is the entire
justification for the control: not that anything is broken, but that the correct signal for a
surround room and the correct signal for a stereo pair are different signals, and only the person
in the room knows which one they are in.

**The choice is PER-DESTINATION, not global.** Mac speakers are stereo whatever the file is; the
SDI monitor is usually a surround room and sometimes is not. Two settings that happen to share a
control, not one setting — and the correct default for one is not the correct default for the
other.

**Where it belongs:** alongside the track selector in the control bar — it is the same question,
*"what am I listening to"*. Probably a second line in that menu, appearing only once a
multichannel track is selected, and stating the active mapping without needing to be opened.

### Only local files and SDI can exercise this — WHEP structurally cannot

**WHEP audio is stereo by construction.** Cloudflare answers `opus/48000/2` with no channel
mapping family, so the WHEP path can never carry more than two channels and can never exercise a
fold at all. Do not design or test this feature against a WHEP source; it will always look like
stereo because it is. See *"A publisher configured for 5.1 against a stereo Opus negotiation
produces pure NOISE…"* above for what happens when someone tries.

SRT is a different matter and is **not** stereo by construction — that note lives on the SRT
bullet of *"WHEP and SRT carry no audio at all…"* above, where the SRT audio work will see it,
rather than buried here.

### A correct fold needs ROLES, not counts

Folding `L C R Ls Rs LFE` correctly means knowing which channel is C. Channel COUNT cannot tell
you: 5.1 SMPTE is `L R C LFE Ls Rs` and 5.1 Film is `L C R Ls Rs LFE` — same six channels in a
different order, and a fold that assumes the wrong one puts dialogue into a surround leg and the
LFE into the centre image.

**7.1 must be supported too** — it is common in delivery and handling only 5.1 would be an
arbitrary gap. It carries the same ordering hazard plus one of its own: it distinguishes SIDE
surrounds from BACK surrounds, and the two **fold at different coefficients**, so folding requires
knowing which is which and not merely that there are eight channels.

### Does the chan-atom walk already distinguish side from back? PARTLY — four findings

**1. Camp B (per-channel descriptions): YES, the distinction is read.**
`MediaInspector.roleName(for:)` maps `kAudioChannelLabel_LeftSurround` → `"Ls"` and
`kAudioChannelLabel_RearSurroundLeft` → `"Lss"`. These are distinct Apple labels producing
distinct strings, so a file describing its channels individually is fully resolvable.

**2. ⚠️ BUT THE STRING NAMES ARE A TRAP, AND A FOLD TABLE KEYED ON THEM WOULD INVERT SIDE AND
BACK.** `"Lss"` reads as "left SIDE surround" in common usage; here it is
`kAudioChannelLabel_RearSurroundLeft` — Apple's **rear** — and the source comments the remap
(`// Apple Rls -> Flip Lss`). Meanwhile `"Ls"` (`kAudioChannelLabel_LeftSurround`) is, in a 7.1
context, the SIDE surround. So the name that looks like "side" means back, and the name that
looks generic means side. There is also a third label in play,
`kAudioChannelLabel_LeftSurroundDirect` → `"Lsd"`, which is the side surround in some Apple 7.1
families. **Key the coefficients on the raw `AudioChannelLabel`, NEVER on the display string** —
the strings exist for the inspector and the meter, and they are a presentation vocabulary.

**3. Camp A (layout tags): MOSTLY NO — this is the additional work.**
`roleSequence(forTag:)` handles five tags: Mono, Stereo, `MPEG_5_1_A`, `MPEG_5_1_C`, and for 7.1
only `MPEG_7_1_C`. Everything else hits `default: return nil` — including `MPEG_7_1_A`,
`MPEG_7_1_B`, `AudioUnit_7_1`, `AudioUnit_7_1_Front`, `DTS_7_1`, `EAC3_7_1_A`, the ITU variants
and the `.4`-height layouts. A 7.1 file declaring any of those yields **no roles at all** and
falls through to count inference. Extending this table is the bulk of the layout work.

**4. Channel BITMAPS are discarded entirely, and needn't be.** `channelRoles(from:)` ends with
*"Bitmap or unknown tag: no role info we trust"* and returns nil for
`kAudioChannelLayoutTag_UseChannelBitmap`. But `mChannelBitmap` is fully role-bearing —
`kAudioChannelBit_LeftSurround` and `kAudioChannelBit_RearSurroundLeft` are separate bits, so it
distinguishes side from back perfectly well. Adding a bitmap camp is cheap and widens coverage
before any tag-table work.

### What to do with a file that declares no roles

**Do not guess, and do not silently fall back.** The three options and why only one is right:

- **Infer from count** (6 → assume SMPTE) — this is exactly the inference the app already refuses
  at tier 2 for *naming*, and here the consequence is audible rather than cosmetic. Rejected.
- **Fold the first pair only** — folding L and R and dropping the rest is not a fold; it looks
  like one while losing the dialogue it was enabled to recover. Rejected.
- **Offer the control, DISABLED, with the reason stated** — *"this file declares no channel roles,
  so a fold would be a guess"* — plus a per-file manual layout ASSERTION for a user who knows what
  the file is. That matches the app's existing pattern for exactly this shape of problem
  (`rangeOverride`, `NDIColorimetryOverride`): Auto follows the declaration, a preset asserts, and
  the assertion is marked as an assertion rather than dressed as a reading. **This is the answer.**

**Never an inferred fold.** A destination whose roles are unknown keeps its default — discrete on
SDI, CoreAudio's own fold on the desktop.

### Also to settle when this is built

- **Which fold.** ITU-R BS.775 / ATSC A/85 give `Lo = L + 0.707·C + 0.707·Ls`; Dolby Lo/Ro and
  Lt/Rt are different answers again. Whichever is chosen must be **STATED in the UI**, for the same
  reason the SDI mapping must be — see the entry above.
- **LFE is excluded by default.** Folding it at unity is the usual cause of a fold that clips.
- **Headroom.** `L + 0.707·C + 0.707·Ls` can exceed full scale on legitimate material; whether
  that is handled by attenuation or limiting is a decision, not a detail, on a reference tool.
- **7.1 folds both surround pairs**, conventionally with the back pair at a lower coefficient than
  the side pair — which is precisely why finding (2) above matters.

**Related:** the SDI mapping and layout work this sits on is the entry above; the track selector it
hangs off is `FrameEngine.selectAudioTrack`; the role derivation is
`MediaInspector.channelRoles(from:)`; the discovery chain and measurements are
`docs/AUDIO_PATH_FINDINGS.md`.
