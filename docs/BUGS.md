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

### ⚠️ THE COUNTS ABOVE ARE UNDERCOUNTS — the 2026-08-27 scan could not see inside `"""` blocks

Added 2026-09-06. The scan that produced the table and the frequencies matched single-line `"…"`
literals only, so **every multi-line string in the app was invisible to it** — and multi-line is
exactly where the long user-facing prose lives: attribution notes, trademark notices, Keychain
fault messages, the diagnostics explainers. Treat the "5 inside a SwiftUI construct" and "15 other
string literals" rows as floors, not totals.

A multi-line-aware re-scan of `App/` + `Packages/` on 2026-09-06 found **six more hits in
`AboutWindow.swift`, `LicenseManager.swift` and `DiagnosticsExport.swift` alone, five of them
user-facing** — none of which the original scan had reported:

- `AboutWindow.swift:466` — the DeckLink trademark notice in `requiredNotices`, "reproduced under
  **Licences**". Rendered permanently in the Credits pane, not behind a popup, so it was the most
  visible hit in the file.
- `AboutWindow.swift:365` — the NDI attribution note, "The SDK **licence** itself is at …".
- `AboutWindow.swift:387` — the DeckLink attribution note, "the **licence** carried in that file's
  own header".
- `LicenseManager.swift:525` — `userFacingKeychainFault`, TWICE in one paragraph.
- `LicenseManager.swift:735` — the `lastMessage` shown when activation succeeds but the Keychain
  write fails.
- `DiagnosticsExport.swift:873` — "**labelled** COARSE" in the WHEP round-trip explainer.

Those six are FIXED. What is not fixed is the METHOD: the re-scan was heuristic (it tracks the
triple-quote delimiter by counting occurrences per line), and it re-derived only the
STRING-LITERAL rows — the comment, docs and scripts counts have never been checked against
multi-line content at all. One multi-line hit is known and deliberately left,
`SRT/SRTFrameRouter.swift:1325` ("today's behaviour"), because it is an `NSLog`.

**So: re-run a MULTI-LINE-AWARE scan before closing this item.** A single-line scan returning zero
proves nothing — it returned zero for these three files on 2026-09-06, hours before the six above
were found by looking properly.

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

**Done means:** a MULTI-LINE-AWARE scan (see the ⚠️ above — a single-line one is not evidence)
returns zero hits in user-facing strings, and the remaining source and doc hits have been
converted or consciously left with a reason. Re-run the scan to confirm rather than declaring
it finished.

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

⚠️ **THE AVPlayerItemVideoOutput SPIKE PASSED 2026-08-29 AND IT DOES NOT CLOSE THIS ENTRY. Do not
mark this fixed when that route is built.** See *"⏸ BANKED: feed the scrub gesture from
`AVPlayerItemVideoOutput`"* below. What it removes is the **disagreement between two decoders** —
with one decoder there is nothing left to disagree, so the mismatch CLASS goes away. What it does
NOT remove is **tolerance**, which is this entry's other half. Measured on that route: the delivered
frame is up to **10.4 frames** from the one requested on 4K H.264, and **26 of 40** positions in a
20 Hz drag return the frame already on screen. That is not a regression — the shipping ±0.5 s
overlay measured **up to 11 frames apart in both directions** — and on all-intra the route is exact
to the nearest frame (0.5 mean, 1.0 max). **But "one decoder" and "frame-accurate scrub preview"
are different claims, and only the first one is on offer.**

⚠️ **A RELEASE SETTLE THEREFORE SURVIVES THE OVERLAY'S DELETION, ON LONG-GOP ONLY.** The scrub
producer seeks at infinite tolerance and `exactSeek` does not, so the seek's first frame can differ
from the frame the drag was showing: **zero on MXF by construction** (exact seek, all-intra —
measured 0.5 mean / 1.0 max on every fixture), effectively zero on ProRes, **up to 10.4 frames on
4K H.264**. There is a deferred way out — seek playback to the frame the producer actually
DELIVERED rather than to `scrubValue` — and it is a **Stage 3 decision requiring its own
measurement**, not an assumption, because it changes which frame a release lands on and therefore
interacts with this entry directly. See *"📐 SCOPED, NOT BUILT: two producers, one destination"*
§2 below.

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

~~**The signal is `MetalVideoRenderer.onFirstPresentAfterFlush`**, a new one-shot that fires when
`presentsSinceFlush` goes **0 → 1**. Every seek flushes (`FrameEngine.beginReading`, and the libav
path) and `flush()` zeroes that counter, so the edge means exactly *"the first frame of the seek I
just started has been presented"*. Two properties carry it:~~

> ⚠️ **STRUCK 2026-08-30 — THE SIGNAL NO LONGER EXISTS.** `onFirstPresentAfterFlush` was removed at
> **Stage 4** of *"📐 two producers, one destination — deleting the scrub overlay"* below, having
> been unconsumed since Stage 3. It is struck rather than deleted because this whole fix section
> describes a mechanism the staged rewrite replaced, and **the entry is owed a proper rewrite** —
> until then, read "What was built" as history rather than as a description of the code. The two
> properties below described the one-shot accurately while it existed. ⚠️ **`presentsSinceFlush`
> itself SURVIVES** — its `[EDR]` reader is untouched — so do not read this strike as retiring the
> counter.

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
gets" below.** ~~Part 3 (DNx/MXF) DELIBERATELY NOT DONE; HDR previews for those formats stay SDR,
see "recorded choice" below.~~ → ✅ **PART 3 CLOSED 2026-08-30 at Stage 3 — see "HOW PART 3 ACTUALLY
CLOSED" below.** ⚠️ **And the whole entry is now superseded in a way the fix above does not
describe:** parts 1 and 2 patched the overlay, Stage 2 and Stage 3 *deleted* it. There is no
`CGImage` in the scrub path on any codec. Read "TWO DISTINCT DEFECTS, ONE DELETION" before quoting
anything above as the current cause. **Reported:** 2026-08-27 by Joey. **Blocks:** judging highlights while scrubbing an HDR deliverable — the one operation where
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
   ⚠️ **MEASURED 2026-08-30: it does not need a float CGImage path, it needs to stop returning a
   CGImage.** The same libav decode converted to the app's x420 `CVPixelBuffer` instead carries PQ
   and HLG tags onto the buffer and preserves the 10-bit luma codes **losslessly over the whole
   raster** — for 11.4 ms at 4K, inside the drag budget. See *"✅ THE MXF HALF, MEASURED
   2026-08-30"* under the `AVPlayerItemVideoOutput` entry below. **Part 3 as scoped here — a float
   path feeding the same overlay — would be building a second producer for a surface that route
   deletes.** It closes at **Stage 3** of *"📐 SCOPED, NOT BUILT: two producers, one destination"*,
   by deleting the 8-bit RGBA path rather than giving it a float variant.

Parts 1 and 2 cover ProRes/H.264 (the AVFoundation path). Part 3 is separable and can be deferred
with the consequence stated: HDR DNx/MXF previews stay SDR.

### ⚠️ REJECTED: routing scrub preview through the real decode path

**Someone will have this idea again — it was had, scoped and measured on 2026-08-27, and it is
rejected.**

⚠️ **READ THIS FIRST: WHAT IS REJECTED HERE IS A SECOND `AVAssetReader`, NOT THE IDEA OF ROUTING
SCRUB THROUGH THE DISPLAY PATH.** A different implementation of that idea —
`AVPlayerItemVideoOutput` on a scrub-only `AVPlayer` — was **spiked 2026-08-29 and PASSED**, and it
beats the `exactSeek` table below on every fixture: **6.7 vs 27.4 ms mean on ProRes 422 HQ, 9.3 vs
117.7 ms worst case, and 14.8 vs 53.7 ms on the H.264 that failed outright here.** See *"⏸ BANKED:
feed the scrub gesture from `AVPlayerItemVideoOutput` — one decoder, one display path"* below,
which also records why each of the four grounds below does not transfer. **The four grounds remain
correct about the thing they measured.** Do not use this section to reject that one. The proposal: drop the generator-to-`CGImage` overlay and drive scrub preview through
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

### ✅ HOW PART 3 ACTUALLY CLOSED — 2026-08-30, Stage 3

**Not the way it is scoped above.** The float pipeline was never built. `LibavThumbnailSource` was
**deleted**, and `LibavScrubProducer` decodes the same libav frame into the app's own x420
`CVPixelBuffer` via `LibavPixelConversion` — the identical conversion the playback path uses. That
is exactly what the 2026-08-30 measurement predicted when it said the fix "does not need a float
CGImage path, it needs to stop returning a CGImage".

**Confirmed at the renderer, not inferred:** an MXF PQ fixture's scrub buffer now arrives as
`x420 trc=SMPTE_ST_2084_PQ pri=ITU_R_2020 mtx=ITU_R_2020` (`[SCRUB-GEOM]`), into a layer the log
confirms is `kCGColorSpaceITUR_2100_PQ` with `wantsExtendedDynamicRangeContent = true`. And the
picture during the drag is **bit-identical to the played picture** at the same position — 0.00
codes over the video rect. The preview is no longer *like* the played frame; it **is** it.

**Confirmed BY EYE on the HDR display**, which is the check the measurements cannot make: on the
Mac Studio driving the **LG 42-inch WOLED in HDR mode**, in **both SDR and HDR**, the dim on scrub
is gone. ⚠️ The dim had **also been present on the MacBook Air**, which matters for the next
section.

### ⚠️ TWO DISTINCT DEFECTS, ONE DELETION — READ THIS BEFORE RE-DERIVING EITHER

**This is the part most likely to be lost, because the deletion fixed both at once and the entry
above only explains one of them.** Anyone who reads only the EDR explanation will be unable to
account for the MacBook Air, and will go looking for a second bug that is not there.

**Defect 1 — COMPOSITING. Visible only where there IS headroom.** The overlay's `CGImage` carried
`contentHeadroom = 4.9261084`, derived from the PQ colorspace and **not clearable** — measured in
`docs/scrub-fixtures/hrprobe.swift`: `CGImageCreateCopyWithContentHeadroom(0.0, …)` is silently
ignored, and even plain `CGImageCreate` returns an image reporting it. A PQ `CGImage` on a `CALayer`
is therefore pinned to Core Animation's **tone-mapped** path, while the Metal layer — which declares
no headroom and no `edrMetadata` — is excluded from it. Two different colour-management modes on one
screen. That divergence is what the 2026-08-28 split confirmed by eye.

**Defect 2 — CODEC VALUES. Visible everywhere, including with no headroom at all.** On the libav
path the preview was swscaled to `AV_PIX_FMT_RGBA` **with range already expanded**, into 8 bits.
That is a pixel-value defect and it has nothing to do with EDR: it is wrong on an SDR panel, on a
laptop, on any display, because the codes are wrong before compositing ever begins. The playback
path deliberately preserves stored range and expands **in the shader**; the thumbnail path did the
opposite because a `CGImage` has no shader behind it.

⚠️ **ON A DISPLAY WITH NO HEADROOM, TONE-MAPPING CANNOT BE THE VISIBLE EFFECT.** So the dim seen on
the MacBook Air was defect 2, not defect 1. Both were real, they had different mechanisms, and they
were fixed by the same deletion — removing the `CGImage` removed the tone-mapped compositing path
*and* the 8-bit range-expanded conversion together. **Do not collapse them into one cause.** If a
similar report ever returns, the first question is which display it was seen on, because that alone
separates the two.

**Related:** the compositing half is recorded in full at
*"✅ DECISION 2026-08-28: the desktop picture is the REFERENCE and does not tone-map"*.

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
   construction rather than by matching.** It also closes the stale-scopes defect at the same time.

   ✅ **SPIKED 2026-08-29 AND IT PASSED — for this entry's use, without qualification.** Numbers in
   that entry. What matters here: the scrub frame reaches the **completed offscreen** in 7.7–8.4 ms
   on 4K ProRes and 16.1 ms on 4K H.264, against a 50 ms budget, and the shader stage that carries
   it there costs about **1 ms**. So the overlay can stop existing as a separate path, and this
   entry's mismatch stops being something to reconcile — **there is only one path left to be in a
   mode.** ⚠️ **The route's three properties are recorded in that entry and NONE of them is a colour
   property** — they are long-GOP frame CHOICE, network IO, and 6K margin. **This entry's defect is
   fully closed by the route; the scrub-POSITION entry's is not.** Do not carry the qualification
   across.
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

  ⚠️ **DEAD AS OF 2026-08-30 (Stage 2/3). IT IS NOW A TRAP, AND A NULL FROM IT IS NOT EVIDENCE.**
  The split drew the **overlay** on the left half and the **Metal layer** on the right. Both halves
  now come from the same path — there is no overlay on any codec — so the seam has nothing to
  straddle and **it will return a clean null on every file regardless of whether a divergence
  exists**. That is not a passing result; it is an instrument that can no longer detect the thing
  it was built to detect.

  **This is the same failure shape as `../color-fixtures/sweep.sh`'s PNG capture**, which
  `wincap.swift` was built to replace (see below): an instrument blind to the effect, returning a
  confident negative. The difference is that this one *used* to work, which makes it more dangerous
  — the entry above vouches for it. It is scheduled for removal in Stage 4 of *"two producers, one
  destination"*; until then, **do not use it and do not cite a null from it.**
- `docs/scrub-fixtures/hrprobe.swift` — the headroom-is-the-colorspace measurement.
- `docs/scrub-fixtures/scrubmeas.swift MODE=pixdiff` — generator vs decoder pixel values, with
  resolution removed as a variable rather than corrected for.
- `docs/scrub-fixtures/wincap.swift` — HDR window capture via ScreenCaptureKit. ⚠️ Built because
  `screencapture` has **no HDR option** (checked) and `../color-fixtures/sweep.sh`'s PNG capture
  would have returned a clean null from an instrument that could not detect the effect — the same
  failure shape as the three dead instruments recorded above.

---

## ⏸ BANKED: feed the scrub gesture from `AVPlayerItemVideoOutput` — one decoder, one display path

**Status:** **✅ SPIKE PASSED 2026-08-29 — on all three uses. Still BANKED and NOT BUILT.** The
gate is cleared; the work is not scheduled. **Raised:** 2026-08-28, out of the HDR scrub
investigation. **Spiked:** 2026-08-29 with `docs/scrub-fixtures/avpvomeas.swift` — see *"✅ SPIKE
RESULT 2026-08-29"* below.

⚠️ **THE IMPLEMENTATION IS NOW SCOPED — see *"📐 SCOPED, NOT BUILT: two producers, one
destination — deleting the scrub overlay"* below.** ⚠️ **Read it before starting: it corrects the
seam this entry names.** `renderPixelBuffer` is private and render-thread-only; the public seam is
`enqueue`, selection is `pts <= clock()`, and during a paused drag that clock is pinned at the
pre-drag position — so a scrub frame is selected dragging BACKWARDS and rejected dragging FORWARDS.
The live producers get away with `enqueue` because they also replace the clock. A scrub producer
cannot.

⚠️ **AND THE MXF HALF WAS MEASURED SEPARATELY ON 2026-08-30, BECAUSE THE ROUTE ABOVE CANNOT OPEN
MXF AT ALL.** `AVPlayerItemVideoOutput` covers ProRes, H.264 and HEVC and covers **nothing** in MXF
— AVFoundation has no MXF demuxer. The same destination with a **libav producer** was measured with
`docs/scrub-fixtures/libavmeas.swift` and **it passes too, with ~2× margin — provided `thread_type`
is set to `FF_THREAD_SLICE` on the scrub decoder.** In the configuration that ships today it does
NOT pass. See *"✅ THE MXF HALF, MEASURED 2026-08-30"* below. **Read the two together: the overlay
cannot be deleted on the strength of either one alone.** ⚠️ **The numbers are the part that makes the case, not the verdict**;
the comparison against the `exactSeek` figures is what turns "it might be fast enough" into a
decision. **Precondition for:** the colour-management mode work
(`docs/COLOR_MANAGEMENT_FINDINGS.md` §6) — see the last section here, this is NOT a parallel task —
**and for HLS as a source**, see *"⏸ BANKED: HLS as a source"* below.

⚠️ **THIS SPIKE IS NOT ABOUT THE SCRUB PREVIEW ALONE. It is the same mechanism three features
need**, and its result should be read as a decision about all three rather than one: (1) the scrub
preview's colour mode, (2) live scopes during a drag, (3) **HLS ingest** — where `AVPlayer` gives
the picture nearly free and the entire work is getting frames out of it and into our shader,
offscreen, scopes and SDI. A cost that looks marginal against the scrub preview alone may be
obviously worth paying against all three; measure once, decide once.

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

⚠️ **AND A FOURTH THING DEPENDS ON THE SAME MECHANISM, THOUGH IT IS NOT A PROBLEM THIS FIXES:**
**HLS as a source** — see *"⏸ BANKED: HLS as a source — a VIEWER/QC feature on the egress side"*
below. `AVPlayer` plays HLS natively, so that feature is almost entirely "get the frames out of
`AVPlayer` and into the offscreen ring", which is exactly what this route does. **Note it stresses
the two risks DIFFERENTLY and more gently: no drag, so per-seek latency does not matter, and the
source is a network stream rather than a second decode of a local 8K file. HLS could therefore
survive a spike result that kills the scrub use** — so record the two risks separately per use
rather than reaching one verdict.

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

> **✅ BOTH ANSWERED 2026-08-29. Risk 1 passes with margin; risk 2 is a non-event for memory and a
> real cost for IO.** The two risk statements below are kept as written because they are the
> QUESTIONS, and the result only means something against them. The measurements are in *"✅ SPIKE
> RESULT 2026-08-29"* immediately after.

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

**Fallback if it measures badly — ✅ NOT NEEDED, and kept only so it is not re-derived:** drive
`VTDecompressionSession` directly off a passthrough `AVAssetReader`. Full control, vends
`CVPixelBuffer`, no AVPlayer — but it means owning keyframe tracking and GOP walking ourselves.
**Substantial, and only worth it if the AVPlayer route fails on one of the two risks above.**
Neither risk failed. ⚠️ **The one case that could revive this is the unmeasured one — 8K ProRes off
a network volume; see *"What was NOT measured"* below.**

### ✅ SPIKE RESULT 2026-08-29 — both risks measured, both pass

**Harness:** `docs/scrub-fixtures/avpvomeas.swift`. Build line, modes and **four traps** (three of
which return plausible wrong numbers) are in `docs/scrub-fixtures/README.md`. It builds no app and
links no app code.

**Conditions, because two of the three qualifications below are conditioned on them:** M4 Max,
64 GB, macOS 26.5.1. `/Volumes/DCCOLOR` is SMB 3.1.1 reached over a **25GBase-CR** link (`en8`).
Decode format **x420 throughout** — `FrameEngine.videoPixelFormat` / `FileFrameSource.defaultPixelFormat`
— so this measures the app's own decode contract and not a cheaper one, and the buffers are
directly consumable by `renderPixelBuffer`.

#### RISK 1 — latency at drag rate: **PASSES**, and not narrowly

Seek at `.positiveInfinity` tolerance both sides, then poll until a `CVPixelBuffer` **for a frame
not already seen** is in hand. 40 positions per file, spread across the duration and jittered off
the frame grid by the same golden-ratio sub-frame offset `scrubmeas.swift` uses. Copy only, ms:

| fixture | transport | COLD mean / max | WARM back-to-back | **WARM @20 Hz — mean / p50 / p90 / max** | over 50 ms |
|---|---|---|---|---|---|
| ProRes 422 HQ 4K, 53 Mb/s | local | 11.2 / 27.5 | 4.1 / 4.5 | **6.7 / 6.8 / 7.5 / 9.3** | 0/40 |
| ProRes 4444 4K, 23 Mb/s | local | 11.4 / 18.6 | 4.4 / 5.1 | **7.0 / 7.1 / 8.1 / 8.9** | 0/40 |
| H.264 4K, 31 Mb/s | local | 17.6 / 22.3 | 12.4 / 16.7 | **14.8 / 15.6 / 20.1 / 20.4** | 0/14 |
| ProRes 422 HQ 4K, **730 Mb/s** | local | 13.4 / 29.3 | 5.0 / 5.9 | **7.1 / 7.1 / 8.3 / 10.7** | 0/40 |
| ProRes 422 HQ 4K, 53 Mb/s | SMB | 12.5 / 31.1 | 4.4 / 5.0 | **6.0 / 5.5 / 7.6 / 9.2** | 0/40 |
| ProRes 4444 4K, 23 Mb/s | SMB | 12.4 / 19.8 | 4.8 / 5.5 | **6.8 / 6.9 / 7.7 / 8.0** | 0/40 |
| H.264 4K, 31 Mb/s | SMB | 20.3 / 26.0 | 13.1 / 17.9 | **15.0 / 15.2 / 20.1 / 20.6** | 0/14 |
| ProRes 4444 4K PQ, **1085 Mb/s**, 8.1 GB | SMB | 20.8 / 28.5 | 9.4 / 10.3 | **10.1 / 10.5 / 11.6 / 12.8** | 0/40 |
| ProRes 4444 4K **59.94p**, 431 Mb/s, 7.5 GB | SMB | 11.0 / 11.6 | 6.4 / 7.8 | **8.0 / 8.2 / 8.8 / 9.5** | 0/40 |
| HEVC **5760×3240**, 255 Mb/s, 5.2 GB | SMB | 36.4 / 47.9 | 30.2 / 42.3 | **31.3 / 33.1 / 36.9 / 42.1** | 0/40 |

**Zero timeouts in every run, on every file.** ⚠️ The three SMB rows for the small fixtures were
**cache-warm** — those files had been copied locally first — so they are not network evidence. The
8.1 GB, 7.5 GB and 5.2 GB rows cannot be meaningfully cached and are.

**COLD is genuinely cold: a fresh `AVPlayer` per trial**, not the first seek on a player that is
already up. The one-off install cost (`AVURLAsset` → `readyToPlay`) is separate and is **not part
of the per-seek budget**: 11.9–47.1 ms mean, worst single first-ever load 215.6 ms.

#### ⚠️ THE COMPARISON THAT MAKES THE CASE

Against the `exactSeek` table in *"⚠️ REJECTED: routing scrub preview through the real decode
path"* (in the HDR scrub entry above) — **same three fixtures, same rasters, same 40 positions**:

| fixture | reader rebuild (mean / p50 / p90 / max) | **this route, warm @20 Hz** | verdict then | verdict now |
|---|---|---|---|---|
| ProRes 422 HQ | 27.4 / 24.2 / 28.6 / **117.7** | **6.7 / 6.8 / 7.5 / 9.3** | fits at mean, **not** worst case | **fits everywhere** |
| ProRes 4444 | 31.4 / 29.2 / 34.8 / 72.0 | **7.0 / 7.1 / 8.1 / 8.9** | fits at mean, **not** worst case | **fits everywhere** |
| H.264 | **53.7** / 52.6 / 67.0 / 83.5 | **14.8 / 15.6 / 20.1 / 20.4** | **fails outright** | **fits everywhere** |

**4× on the mean, 4–13× on the max, and the 118 ms that killed that route does not reappear
anywhere in the corpus.** The prediction in *"Why the three measured objections do NOT apply"*
above — that 27/118 was the cost of a reader REBUILD and not of a seek against a warm decoder —
holds, and long-GOP inverts exactly as predicted: it is the codec that gained the most.

**It also beats the path it would REPLACE.** `AVAssetImageGenerator` measures 15 ms and does it at
**960×540**; this is 6.7–7.1 ms at the **full 4K raster**. ⚠️ **This was never a decode-cost problem
— the root is a return type**, as recorded above, and the spike confirms the replacement is not
paying for the fix. It is faster and larger at the same time.

#### RISK 1 for the SCOPES is a different number, and it was measured separately

The picture needs a `CVPixelBuffer`; **the scopes need it in the offscreen ring**
(`MetalVideoRenderer.renderPixelFormat`: *"Display, export, DeckLink and the SCOPES all read this
target"*). So `SHADER=1` carries each frame the rest of the way — two `CVMetalTextureCache` plane
textures and a render into an `rgba16Float` offscreen, **waited to GPU completion**, because a
number that stopped at `commit()` would leave out the part that has to finish.

**The stage costs +0.6 to +1.1 ms mean; the worst single sample in the whole corpus was 2.8 ms.**
Totals to a COMPLETED offscreen at 20 Hz: **7.7–8.4 ms** on 4K ProRes (all four fixtures),
**16.1 ms** on 4K H.264, **32.4 ms** on 6K HEVC. ⚠️ **The scopes are therefore not a second
decision — they ride for about a millisecond.**

#### RISK 2 — memory is a non-event; **IO is the real cost**

Three phases in one process: playback alone, playback **plus** a live scrub player dragging at
20 Hz, playback again with the scrub player released. Cost of the second pipeline = P2 − P1:

| fixture | physical footprint | CoreMedia pool (the decoder) | IOSurface mapped | playback frames lost |
|---|---|---|---|---|
| 4K ProRes HQ 730 Mb/s, local | **+27 MB** | +18 MB | +48 MB | **none** — 492 → 498 |
| 4K ProRes 4444 1085 Mb/s, SMB | **+25 MB** | +20 MB | +71 MB | **none** — 517 → 517 |
| 6K HEVC, SMB | −19 MB | −26 MB | +107 MB | **none** — 496 → 498 |

Process peak RSS 173 → 206 MB (local) and 279 → 320 MB (the 8 GB SMB file). **Fully returned when
the scrub player was released** — checked in P3, not assumed. **Playback never lost a frame to the
second pipeline in any run**, which was the specific fear.

⚠️ **`resident_size` and `phys_footprint` CANNOT SEE THE PIXEL BUFFERS.** A decoder's
`CVPixelBufferPool` is IOSurface-backed and charged elsewhere — the first smoke run reported RSS
34 MB for a pipeline decoding 4K ProRes, which is obviously not the whole story. The table above is
read from `vmmap --summary` by region type instead. **A verdict taken off RSS alone would have been
read from the one number that cannot see the thing being measured.**

**The cost is in IO, and it is large:**

| fixture | playback alone | + scrub @20 Hz | delta |
|---|---|---|---|
| 4K ProRes HQ, local (block IO) | 95 MB/s | 161 MB/s | **+69%** |
| 4K ProRes 4444 1085 Mb/s, SMB (network) | 139 MB/s = **1.11 Gb/s** | 236 MB/s = **1.89 Gb/s** | **+774 Mb/s** |
| 6K HEVC, SMB (network) | 32 MB/s | 91 MB/s | **+186%** |

A 20 Hz drag pulls roughly a second full-rate read of the same file. That is the honest shape of
"a second decode pipeline against the same file over the same link", and it is what property 2
below is about.

**Latency UNDER PLAYBACK LOAD** — the case that actually happens — measured in the same phase:
4K ProRes local **7.4 mean / 30.3 max**; 4K ProRes 4444 over SMB **11.1 / 15.8**; 6K HEVC over SMB
**31.9 / 57.3**. Load roughly triples the worst case on local ProRes and still leaves it inside the
budget.

### ⚠️ THREE PROPERTIES OF THIS ROUTE — not caveats to be resolved later

**These are what the route IS. None of them is a defect to be fixed in a follow-up, and describing
them that way is how a known trade turns into a surprise.**

**1. It will NEVER be frame-accurate scrub preview, and it must not be described as fixing that.**
Infinite tolerance is what makes long-GOP cheap — that is the trade, stated above and confirmed —
and the bill is arriving at a frame that is not the one asked for:

| fixture | delivered frame − requested, abs frames (mean / max) | positions returning the frame ALREADY on screen |
|---|---|---|
| ProRes (all four fixtures) | 0.5–0.6 / **1.0** | 0/40 |
| H.264 4K | 4.4 / **10.4** | **26 of 40** |
| HEVC 6K | 5.9 / **11.8** | 0/40 |

**⚠️ 65% of a 20 Hz drag on 4K H.264 returns the frame that is already displayed.** ⚠️ **This is NOT
a regression** — the shipping ±0.5 s overlay was measured putting preview and reader **up to 11
frames apart, in BOTH directions** — so the route does not make position worse, and on all-intra it
is exact to the nearest frame. **But it does not close the scrub-POSITION defect either.** See
*"⚠️ UNCONFIRMED: scrub release jumps the picture once, on ProRes"* above, which stays open on its
own terms; what this route removes is the DISAGREEMENT between two decoders, not the tolerance.

**2. The IO cost is conditioned on the LINK, and this is the finding most likely to bite a USER
rather than us.** +774 Mb/s measured on a **25 GbE** SMB share, where it is invisible. It would not
be on 1 GbE. **Above roughly 400 Mb/s of source, a drag does not fit alongside playback on a 1 GbE
link** — playback alone already occupies most of it, and the drag asks for the same again. The
media above that line is ordinary facility media, not an edge case: every ProRes 422 HQ or 4444 4K
master in the corpus is over it. ⚠️ **Nothing in a local-disk or 10 GbE+ test can show this. Do not
re-measure on this machine and conclude it is fine.**

**3. 6K HEVC over SMB with playback running hit 57.3 ms — the only sample over the 50 ms budget
anywhere in the spike.** ⚠️ **Raster plus codec, NOT transport:** the same file measured 30.2 ms
back-to-back with nothing else running, and the ProRes 4444 file at **four times the bitrate** over
the same link measured 15.8 ms under the same load. **Record this as the point where the route
stops having margin, not as a failure** — it did not time out, drop a frame, or fail to deliver.
Above 4K on long-GOP the budget is spent rather than comfortable.

### ⚠️ WHAT WAS NOT MEASURED — and why it must not be extrapolated

**THERE IS NO 8K ProRes IN THE CORPUS.** The whole share was searched; the largest raster found is
the 5760×3240 HEVC camera original used above. **Risk 2 as written in this entry names "8K ProRes
off a network volume" and THAT CASE REMAINS OPEN.**

⚠️ **The 6K HEVC must not be read as standing in for it, in EITHER direction.** It is a different
codec with a different decode cost — and it is precisely the one fixture that got near the budget,
so it is the worst possible thing to extrapolate from. Reading it as an upper bound would be
optimistic (8K ProRes is 2.3× the pixels and a far higher data rate); reading it as proof of
failure would be pessimistic (every ProRes fixture, including one at 1085 Mb/s, beat it by 3×).
**Neither reading is supported. The measurement is simply absent, and it is the one case that could
still revive the `VTDecompressionSession` fallback.**

**The playback baseline is a MODEL, not the app.** It is an `AVAssetReader` decoding x420 in real
time with each frame rendered through the shader — no audio reader, no `AVSampleBufferDisplayLayer`,
no DeckLink staging, no scopes. **So the absolute footprints above are a FLOOR, and the DELTAS are
the measurement.** The second pipeline's cost does not depend on what else is resident, which is why
the delta transfers to the app and the absolute number does not.

### ✅ THE MXF HALF, MEASURED 2026-08-30 — the libav path reaches the same destination, and it PASSES

⚠️ **THE ROUTE ABOVE COVERS ONLY PART OF THE CORPUS, AND THE PART IT MISSES IS NOT A NICHE.**
`FrameEngine.loadMXF`: *"AVFoundation has no MXF demuxer, so it can't open the file at all — MXF
routes DIRECTLY to libav."* Confirmed per file by the harness rather than assumed from the
extension: **every MXF tested reports `AVFoundation can open it: NO`.** So
`AVPlayerItemVideoOutput` handles ProRes, H.264 and HEVC and handles **nothing** in MXF. If the
overlay is to stop existing — one picture path, one HDR behaviour, no `CGImage` anywhere — MXF needs
the **same destination with a different producer**: libav seeking, decoding one frame, and pushing a
`CVPixelBuffer` to `renderPixelBuffer` exactly where `AVPlayerItemVideoOutput` would.

That seam needs no new architecture: `renderPixelBuffer` already accepts frames from arbitrary
producers, which is how NDI, WHEP and SRT work. **The only open question was how long libav takes,
and it is now measured.**

**Harness:** `docs/scrub-fixtures/libavmeas.swift` (+ `build-libavmeas.sh`). It links the app's own
vendored libav through the app's own `CFFmpeg/include/shim.h`, and its conversion is copied from
`LibavFrameSource.convert`; its shader stage is byte-identical to `avpvomeas.swift`'s. Modes, and
**four traps**, are in `docs/scrub-fixtures/README.md`. Same machine and link as the spike above.

#### ⚠️ THE RESULT IS A ONE-LINE CHANGE, AND THE SHIPPING CONFIGURATION IS THE THING THAT FAILS

**Neither `LibavFrameSource` nor `LibavThumbnailSource` sets `thread_type`.** Both set only
`thread_count`, so both get libav's default, which prefers `FF_THREAD_FRAME`. `avcodec.h:1577`
states the bill in one line:

> *"Use of FF_THREAD_FRAME will increase decoding delay by one frame per thread."*

For **continuous playback** that delay is free — it is a pipeline and it fills once. For a
**single-frame seek** it is not: `avcodec_flush_buffers` empties the pipeline, so getting ONE frame
out costs `thread_count` frames of decode. Measured on 4K DNxHR HQX, 30 positions at 20 Hz,
seek → decode → x420 `CVPixelBuffer` in hand:

| `thread_count` | `thread_type` = **default** (what ships) | `thread_type` = **`FF_THREAD_SLICE`** |
|---|---|---|
| 1 | 52.0 mean / 77.2 max | 51.3 / 73.2 |
| 2 | 45.6 / 62.4 | 32.0 / 42.7 |
| 4 | 46.7 / 60.3 | 23.5 / 32.8 |
| **8** (`LibavThumbnailSource`) | **47.4 / 63.1** | **19.2 / 22.7** |
| **15** (`LibavFrameSource`) | **56.6 / 85.4** | **17.4 / 19.9** |
| 16 | 57.4 / 77.1 | 16.8 / 20.2 |

**More threads makes the shipping configuration SLOWER, monotonically, because each extra thread is
one more frame of delay on a flushed decoder.** The give-away in the raw output is
`packets read per seek: 17` — seventeen packets to produce one frame of an **all-intra** codec.

⚠️ **THIS IS A PROPERTY OF THE EXISTING APP, NOT ONLY OF THE PROPOSED ROUTE.** `LibavFrameSource`
runs `cores−1` threads and flushes on every `seekOnPump`, so **every MXF seek in shipping playback
pays the same 15-frame pipeline refill** — ~57 ms at 4K where ~17 ms was available. It has never
been measured and it is not what this entry is about, but it is the same mechanism and it is
recorded here so it is not re-derived. **Do not extend the recommendation below to playback without
measuring the other side of the trade:** frame threading costs a one-time `thread_count`-frame delay
per seek and buys steady-state throughput, and only the first half is measured here.

#### RISK 1 — latency at drag rate: **PASSES**, with `FF_THREAD_SLICE`

40 positions per file, spread across the duration and jittered off the frame grid by the same
golden-ratio sub-frame offset `scrubmeas.swift` and `avpvomeas.swift` use. t0 = `av_seek_frame`;
t1 = an x420 `CVPixelBuffer` in hand, converted, colour attachments set — the same span the spike
above timed. `thread_count` 8, `FF_THREAD_SLICE`. ms:

| fixture | transport | COLD mean / max | WARM back-to-back | **WARM @20 Hz — mean / p50 / p90 / max** | over 50 ms |
|---|---|---|---|---|---|
| DNxHR 10-bit 4K, 701 Mb/s, 4.27 GB | SMB | 21.3 / 28.0 | 16.4 / 19.7 | **20.3 / 22.0 / 23.4 / 24.3** | 0/40 |
| DNxHR 10-bit 4K **PQ/2020**, 701 Mb/s | SMB | 17.3 / 19.4 | 15.6 / 19.2 | **19.6 / 20.3 / 22.8 / 23.4** | 0/40 |
| the same file, copied local | local | 18.4 / 20.7 | 16.5 / 20.4 | **19.6 / 20.6 / 22.9 / 23.5** | 0/40 |
| DNxHR 10-bit 4K, 713 Mb/s | SMB | 20.6 / 22.9 | 16.2 / 20.2 | **16.4 / 16.5 / 18.7 / 19.4** | 0/40 |
| DNxHD 8-bit 1080p, 131 Mb/s, **41.86 GB / 42 min** | SMB | 6.4 / 8.1 | 6.0 / 7.9 | **10.4 / 11.2 / 14.7 / 15.8** | 0/40 |
| DNxHD 8-bit 1080p 29.97, **26.42 GB** | SMB | 7.0 / 8.6 | 5.5 / 7.9 | **10.4 / 10.5 / 13.1 / 15.5** | 0/40 |
| DNxHR **12-bit** 1080p, 13 streams | SMB | 8.2 / 9.6 | 5.1 / 7.0 | **9.9 / 10.3 / 12.4 / 14.9** | 0/40 |

**Zero failures on every file. Nothing anywhere near 50 ms — the worst single sample in the whole
corpus is 24.3 ms, less than half the budget.**

**Where the time goes, and it is NOT the seek:**

| component | 4K DNxHR | 1080p DNxHD |
|---|---|---|
| `av_seek_frame` + `avcodec_flush_buffers` | **0.01 ms** | 0.03 ms |
| decode one frame | 8.1 ms | 5.9 ms |
| swscale → x420 `CVPixelBuffer` | **11.4 ms** | 4.4 ms |
| shader → `rgba16Float` offscreen | 0.9 ms | 0.8 ms |

⚠️ **THE SEEK IS FREE AND THE CONVERSION IS THE LARGEST SINGLE COST.** DNxHR being all-intra is not
merely "an exact seek should be cheap" — the seek does no measurable work at all, because the MXF
index resolves the position and the essence read is one KLV. At 4K, `sws_scale` from `yuv422p10le`
to P010 costs **more than the decode**. Any future effort to make this faster belongs there, not in
the seek. **Caching the `sws` context is NOT that effort:** `LibavFrameSource` builds a fresh
`sws_getContext` per frame and freeing/rebuilding it measured within noise of reusing one
(10.4 vs 10.8 ms at 1080p; 19.6 vs 19.6 at 4K), so that is a tidy-up, not a saving.

**COLD is genuinely cold — a fresh `AVFormatContext` + decoder per trial.** The install cost is
reported separately because it is **not** in the per-seek budget: 2.0–33.6 ms total, of which
`avformat_find_stream_info` is 85–99%. The scrub decoder is opened once at load
(`LibavThumbnailSource.openAsync`) and held, so a drag never pays it.

#### RISK 1 for the SCOPES — the same "rides for about a millisecond" as the AVPlayer route

Carrying the frame into the `rgba16Float` offscreen, waited to GPU completion, costs **+0.8 to
+1.0 ms mean** across every fixture. Totals to a completed offscreen at 20 Hz: **20.5–21.4 ms** at
4K, **10.9–11.6 ms** at 1080p. Identical conclusion to the spike above, and the shader stage is the
identical code, so the two are directly comparable.

#### ⚠️ WHAT A "WARM CONTEXT" IS ON THIS PATH — a weaker property than AVPlayer's, and it does not matter

The AVPlayer route's whole premise is a decoder that stays warm across a drag. **libav's equivalent
is weaker and must not be described the same way.** A held libav context keeps the demuxer and its
index, the open file handle, the decoder's threads and tables, the pixel-buffer pool and the swscale
context. It does **not** keep decoder STATE: `avcodec_flush_buffers` after every `av_seek_frame`
discards it, by design and by necessity. **So in the strict sense every libav seek IS cold** — and
on all-intra that costs nothing, because there is no reference state to lose. `frames decoded and
discarded to reach the target` measured **0.5 mean / 1.0 max** on every fixture in the corpus.

The measurable difference between held and per-request is therefore **entirely the install cost**,
and it is decisive at 4K: COLD 17–21 ms **plus** a 30–34 ms `find_stream_info` ≈ **50 ms, the whole
budget, for the open alone**. **A path that opened its own `AVFormatContext` per scrub request would
not fit. One that holds it does, with 2× margin.**

**Can it be held across a drag without disturbing playback? Yes — and the app already does exactly
that.** `LibavThumbnailSource` opens its own context at load, holds it for the file's lifetime and
closes it at unload, precisely *"so thumbnail seeks/decodes never disturb playback"*. **That comment
is now measured rather than asserted** (see RISK 2): with a 20 Hz drag running for 25 s against live
playback, playback decoded **775 frames vs 773 with no drag**, and **late frames went 1 → 0**. A
seek-to-renderer path needs no new lifecycle — it needs the existing one to return a different type.

#### RISK 2 — memory is a non-event; IO is the real cost, and its shape depends on the gesture

Three phases in one process: playback alone, playback **plus** a 20 Hz drag, playback with the drag
released. The playback model is a libav pump pinned to `LibavFrameSource`'s real settings
(`cores−1` threads, libav's **default** `thread_type`) so the experiment's setting cannot leak into
the thing it contends with. Cost of the second pipeline = P2 − P1:

| fixture | physical footprint | IOSurface mapped | playback frames | late frames | scrub latency UNDER LOAD |
|---|---|---|---|---|---|
| DNxHD 1080p, **26.42 GB**, SMB | **+16 MB** | +6 MB | 773 → **775** | 1 → **0** | 7.5 mean / 13.1 max |
| DNxHD 1080p, **41.86 GB**, SMB | **+18 MB** | +6 MB | 620 → **621** | 1 → **0** | 6.7 / 13.4 |
| DNxHR 4K, 4.27 GB, SMB | **+67 MB** | +24 MB | 505 → 501 | 1 → **0** | 19.1 / 35.3 |
| DNxHR 4K PQ, 1.46 GB, local | **+26 MB** | +24 MB | 497 → **501** | 2 → **1** | 16.9 / 21.9 |

**Playback never lost a frame to the drag in any run**, and latency under playback load stayed
inside budget everywhere — **35.3 ms was the worst single sample in the whole exercise**, on the 4K
SMB file, and it is still 30% under. Memory returns on release (checked in P3, not assumed).

⚠️ **`CoreMedia memory pool` is absent from `vmmap` on this path and the table has no such column.**
libav's decoder is not CoreMedia; its frames land in libav's own buffers and then in our
`CVPixelBufferPool`, which vmmap accounts under `IOSurface`. The spike table above HAS that column
because *its* decoder is VideoToolbox's. **The two tables do not have the same rows** — do not read
a missing row as a failed measurement.

**The IO, and the finding is that the gesture shape matters more than the transport:**

| | playback alone | + drag @20 Hz | delta |
|---|---|---|---|
| DNxHD 1080p 159 Mb/s, **26.42 GB**, SMB — clean P2 − P1 | 20 MB/s | 53 MB/s | **+33 MB/s (+165%)** |
| DNxHR 4K 701 Mb/s, SMB — **`scatter`**, measured directly | 88 MB/s (= the bitrate) | +130–151 MB/s | **+1.0–1.2 Gb/s** |
| DNxHR 4K 701 Mb/s, SMB — **`sweep`**, measured directly | 88 MB/s | +28–36 MB/s | **+224–290 Mb/s** |

⚠️ **`scatter` AND `sweep` ARE NOT THE SAME MEASUREMENT AND ONLY ONE IS A GESTURE ANYBODY MAKES.**
`scatter` jumps to a pseudo-random position every tick — the worst case for read-ahead, and what the
P2 − P1 phases do. `sweep` walks forward ~2 frames per tick, which is what a hand does to a
scrubber. **The realistic shape is 4–5× cheaper**, and at 4K it turns a drag that asks for more than
the file's own bitrate into one that asks for a third of it. Per seek, `scatter` pulled ~7.5 MB for
a 3.66 MB frame: **read-ahead amplification of ~2×, which is the cost of the random access, not of
the decode.**

⚠️ **THE 4K NUMBERS ARE MEASURED DIRECTLY BECAUSE THE SUBTRACTION IS INVALID THERE, AND THIS IS AN
INSTRUMENT LIMIT, NOT A CHOICE.** Every 4K MXF in the corpus is 1.4–4.3 GB on a 64 GB machine, so
`MODE=memory`'s P1 caches the file it is about to measure P2 against. The long-form 1080p files are
immune and give the clean delta above; `sudo purge` is not available to the harness. `MODE=io`
therefore measures the drag alone on files no earlier phase has touched, and both modes **print an
explicit warning on any phase that moved ~0 bytes** rather than let a cached row read as "free".

⚠️ **THE LOCAL BLOCK-IO DELTA COULD NOT BE ISOLATED AT ALL, FOR THE SAME REASON.** Once playback has
read a local file it is in the page cache, and the drag then moves **zero** bytes of block IO —
observed, and flagged by the harness as carrying no information. The one clean local datapoint is
first-touch playback at 57 MB/s. **On local media the honest statement is that the second decode
costs no IO on a machine with headroom and is bounded above by 20 × the frame size; it is not that
the cost was measured to be zero.**

⚠️ **Property 2 of the AVPlayer route transfers, and MXF makes it worse.** Above roughly 400 Mb/s of
source a drag does not fit alongside playback on a 1 GbE link. **Every 4K DNxHR fixture in this
corpus is 701 Mb/s**, and playback alone already exceeds a 1 GbE link's practical throughput on
those — so on 1 GbE the file does not play, with or without this feature. The drag's marginal
+224–290 Mb/s (`sweep`) is a real addition on 10 GbE and invisible on this machine's 25 GbE. **Do
not re-measure on this machine and conclude it is fine.**

#### HDR — the pixel-buffer path is HDR-correct by construction, and it is measured, not argued

`LibavThumbnailSource.makeCGImage` swscales to **8-bit RGBA in `DeviceRGB` with `dstRange = 1`** —
SDR by construction, and the recorded reason Part 3 of the HDR preview fix was deliberately not done
and DNx/MXF HDR previews stay SDR. What the decode actually produces, and what the destination costs:

| | PQ / Rec.2020 4K | HLG / Rec.2020 4K | 12-bit 1080p | 8-bit 1080p |
|---|---|---|---|---|
| decoded pixel format | `yuv422p10le`, **10-bit** | `yuv422p10le`, 10-bit | `yuv422p12le`, **12-bit** | `yuv422p`, 8-bit |
| range | legal/MPEG | legal/MPEG | legal/MPEG | legal/MPEG |
| frame side data | **mastering-display PRESENT** | absent | absent | absent |
| → x420 buffer attachments | `ITU_R_2020` / `ITU_R_2020` / **`SMPTE_ST_2084_PQ`** | `ITU_R_2020` / `ITU_R_2020` / **`ITU_R_2100_HLG`** | 709 / 709 / 709 | 709 / 709 / 709 |
| luma, source vs x420, whole raster | **max \|diff\| 0 — LOSSLESS** | **max \|diff\| 0 — LOSSLESS** | max \|diff\| 1 (12→10 bit) | — |
| conversion cost | 11.4 ms | 10.6 ms | 3.0 ms | 2.8 ms |

**So reaching x420 costs the swscale already priced above — 11.4 ms at 4K — and costs nothing in
fidelity on the 10-bit sources: the luma codes arrive unchanged, over the whole raster, with no
range remap and no truncation, and the PQ and HLG transfer tags land on the buffer.** That is the
same P010 destination `LibavFrameSource` already uses for playback, so **the scrub frame and the
playback frame are byte-identical by construction** — which is the property this whole line of work
is buying, and it is stronger than "the two paths agree".

⚠️ **TWO LOSSES ARE REAL AND ARE SHARED WITH PLAYBACK, NOT INTRODUCED BY THIS ROUTE.** x420 is a
**10-bit 4:2:0** container: a **12-bit** DNxHR source is truncated (measured: ±1 code), and 4:2:2
chroma is subsampled vertically. `LibavFrameSource.convert` does both today, so the scrub frame
matches what is on screen exactly. **Stated so it is a known shared property rather than a later
discovery** — and note that a route which "fixed" it on the scrub path alone would REINTRODUCE the
divergence this work exists to remove.

⚠️ **MASTERING-DISPLAY METADATA IS PRESENT ON THE PQ FIXTURE AND THIS PATH DOES NOT CARRY IT.** It
is decoded as frame side data and then dropped: `LibavFrameSource.convert` sets three attachments
(matrix, primaries, transfer) and no mastering-display. That matters for E3 (`edrMetadata`) in the
colour-management work, not for this gate — but it is the one thing `AVPlayerItemVideoOutput` gets
for free from the container that this producer would have to carry deliberately.

#### VERDICT — MXF does NOT need a different answer

**The libav path reaches `renderPixelBuffer` at drag rate, with roughly 2× margin, on every MXF in
the corpus including a 42-minute 41.86 GB file over SMB — provided `thread_type` is set to
`FF_THREAD_SLICE` on the scrub decoder.** In the shipping configuration it does not: 47–57 ms mean
at 4K, over budget on more than half of a 40-position drag. **The difference between failing and
passing this gate is one field neither existing libav client sets.**

Read against the AVPlayer route, on the two things that decide whether the overlay can be deleted:

| | `AVPlayerItemVideoOutput` (ProRes/H.264/HEVC) | **libav (MXF)** |
|---|---|---|
| warm @20 Hz, mean / max | 6.7–31.3 / 8.9–42.1 ms | **9.9–20.3 / 14.9–24.3 ms** |
| under playback load, max | 30.3 / 15.8 / **57.3** ms | **13.1 / 13.4 / 35.3 ms** |
| shader → offscreen (the scopes) | +0.6 to +1.1 ms | **+0.8 to +1.0 ms** |
| delivered frame − requested | 0.5–5.9 mean, **up to 11.8** frames | **0.5 mean / 1.0 max, every fixture** |
| positions returning the frame already shown | 0–**26 of 40** | **0** |

⚠️ **THE LAST TWO ROWS ARE THE INTERESTING ONES AND THEY GO THE OTHER WAY.** Property 1 of the
AVPlayer route — *"it will NEVER be frame-accurate scrub preview, and it must not be described as
fixing that"* — **does not apply to the libav producer.** libav is asked for an exact position, not
a toleranced one, and DNxHR is all-intra, so it lands on the requested frame every time. **That is
not a reason to prefer it; it is a reason not to describe the two producers with one sentence.**
Whatever is written about scrub accuracy after this work will be **true of MXF and false of H.264**,
and a single claim covering both will be wrong about one of them.

**No fallback is needed and none is proposed. `VTDecompressionSession` was never available here
anyway — VideoToolbox rejects DNxHR with −12906, which is why this path exists.**

⚠️ **WHAT THIS DOES NOT SAY.** It does not say the route is built, and it does not say the mode
picker can be built — both remain gated exactly as the entry above states. It measures the
mechanism on the corpus that exists. **`.mov`-wrapped DNx is NOT measured** (all 109 `.mov` files on
the share were checked; none carries `AVdh`/`AVdn`/`dnxh`/`dnxd`), and **JPEG 2000 MXF has no route
in Manifold at all** — `The_Righteous_Gemstones_404.mxf` fails `avcodec_find_decoder` because the
vendored build enables only `dnxhd` and `prores`. Neither is a scrub question; both are recorded in
`docs/scrub-fixtures/README.md` so the sweep that found them is not repeated.

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

**✅ RESOLVED 2026-08-29 — IT SUCCEEDED. The mode picker can be designed for ONE steerable display
path.** That is the branch this entry was written to decide, and it is decided. ⚠️ **The picker
still cannot be built until the route is actually BUILT** — the spike measured the mechanism, it did
not ship it, and a picker shipped against a scrub path that is still a `CGImage` on a `CALayer`
ships the silently-ignored control described above regardless of what the spike says.
---

## 📐 two producers, one destination — deleting the scrub overlay

**Status:** ~~SCOPED 2026-08-30. **Not started.**~~ → **BUILT 2026-08-30. Stages 0, 1, 2 and 3 are
DONE and verified; Stage 4 (scaffolding removal) is DONE 2026-08-30 — the callback it was waiting
on can now be deleted, and the measurement instruments are deliberately kept.** The title's
"SCOPED, NOT BUILT" is struck rather than rewritten so the entry still reads as what it was —
reasoning written before any code — with the outcome appended. Per-stage results are in
*"✅ MEASURED 2026-08-30 — Stage 3: the libav scrub producer, and the end of the CGImage path"*
below; the AVFoundation stages' numbers are in the Stage 1 and Stage 2 checkpoints as annotated.
**There is now ONE scrub mechanism and one destination.** Both measurement gates had passed — see
*"⏸ BANKED: feed the scrub gesture from `AVPlayerItemVideoOutput`"* above for the AVFoundation half
(spiked 2026-08-29) and *"✅ THE MXF HALF, MEASURED 2026-08-30"* inside it for the libav half. This
entry is the **implementation shape and the reasoning behind it**, written before any code so the
decisions are arguable rather than archaeological.

**The shape, in one line:** two producers, one destination.

| corpus | producer | measured, warm @20 Hz |
|---|---|---|
| AVFoundation-openable (ProRes, H.264, HEVC) | `AVPlayerItemVideoOutput` on a scrub-only `AVPlayer` | 6.7–31.3 ms mean |
| MXF (AVFoundation cannot open it at all) | libav seek + decode, **`FF_THREAD_SLICE`** | 9.9–20.3 ms mean |

Both hand a `CVPixelBuffer` in the app's x420 contract to the Metal renderer, so the scrub frame
goes through the same shader, the same offscreen, the same layer and the same SDI convert as
playback. **The `CGImage` overlay stops existing.**

---

### ⚠️ THE SEAM CORRECTION — `renderPixelBuffer` IS NOT THE SEAM, AND THE DIFFERENCE IS A DESIGN DECISION

Every prior entry describing this route says "push it to `renderPixelBuffer`". **That is not
reachable and it was never the seam.** `MetalVideoRenderer.renderPixelBuffer` is `private` and
render-thread-only; its only callers are the three branches inside `performDisplayTick`.

The public producer seam is **`enqueue(_ sampleBuffer:)`**, and what happens next is the part that
matters:

```
// performDisplayTick, MetalVideoRenderer.swift
guard let now = clock?() else { return }
for (i, frame) in frameQueue.enumerated() { if frame.pts <= now { chosen = … } else { break } }
```

and, for file playback (`WindowDeck.configure`):

```
renderer.clock = { engine.currentSyncTime().seconds }     // the AVSampleBufferRenderSynchronizer
```

⚠️ **`FrameEngine.scrubSeek` NEVER MOVES THE SYNCHRONIZER.** It sets the published `currentTime` —
the readout — and nothing else, deliberately ("just track the target and show it on the clock,
WITHOUT rebuilding the reader every tick"). The drag also pauses transport. **So for the entire
duration of a drag the renderer's clock is pinned at the position the picture was at when the
scrubber was grabbed.**

**CONSEQUENCE, and it is not a corner case:** a scrub frame enqueued at the scrub position is

* **SELECTED when the user drags BACKWARDS** (`pts <= now`), and
* **REJECTED when the user drags FORWARDS** (`pts > now`).

The `pendingSeekRender` relaxed branch below the strict gate looks like the answer and is not: it is
a **one-shot armed by `flush()`**, sized for a decoder overshooting a seek target, and it fires at
most once per flush. A 20 Hz drag issues hundreds of positions.

⚠️ **"THE RENDERER ALREADY ACCEPTS FRAMES FROM ARBITRARY PRODUCERS" IS TRUE AND INCOMPLETE.** NDI,
WHEP and SRT do push into `enqueue` — **and every one of them also replaces the clock**
(`renderer.clock = { Self.monotonicNow() }` in `NDIService`, `{ clock.now() }` in
`LiveDisplayRoute` and `SyntheticLiveSource`). They are not "producers on the file clock"; they are
producers that brought their own. Reading the NDI/WHEP/SRT precedent as "the seam is open" and
skipping this is the single most likely way to start building and discover the problem on a forward
drag.

#### The three ways to fix it, and why (a) wins

**(a) A new one-shot render entry point — `presentImmediate(pixelBuffer:pts:)`. ✅ CHOSEN.**
Bypasses `frameQueue` and the clock gate entirely; renders the buffer on the next display tick.

- **The pattern already exists in the file.** `pendingRefresh` re-renders `lastPixelBuffer` off the
  clock when a range override changes while paused, and `pendingSeekRender` renders the earliest
  queued frame off the clock after a paused seek. A third off-clock one-shot is the same shape as
  two things already there, guarded by the same `refreshLock`, obeying the same "MAIN COMPUTES, THE
  RENDER THREAD INSTALLS" discipline.
- **It touches nothing playback reads.** The clock, the synchronizer, the queue and the strict gate
  are untouched, so nothing about normal playback, seeking, shuttle or the live routes can change
  behaviour as a side effect.
- **It is trivially reversible.** One method, one one-shot flag. If the route is abandoned the
  method is deleted and nothing else moves.

**(b) Move the pinned synchronizer clock during the drag. ✗ REJECTED.**
Superficially the "correct" fix — make the clock tell the truth and the existing gate just works.
But `synchronizer` is also the **audio master**, the source of the periodic time observer that
publishes `currentTime` and drives the end-of-file/loop logic, and the thing `isPausedNow()` reads.
Moving it 20 times a second during a drag puts a transport-level mutation on the hot path of a
gesture, to solve a display-selection problem. **The blast radius is the whole transport for a
benefit confined to one surface.**

**(c) Substitute the clock for the duration of the drag, like the live sources. ✗ REJECTED.**
Symmetric with existing code, which is its only argument. It requires save/restore of `clock` and
`isPausedProvider` around a *gesture* — and `LiveDisplayRoute` and `SyntheticLiveSource` already do
their own save/restore of exactly those two fields. **Two nested save/restore protocols over the
same two mutable fields, one of them entered and left by a mouse drag, is a re-entrancy problem
being created on purpose.** A drag that begins while a live route is standing up, or a route that
tears down mid-drag, would have to be reasoned about; with (a) neither interaction exists.

---

### 1. WHAT GETS DELETED, AND WHAT IS LOAD-BEARING FOR SOMETHING ELSE

> ✅ **DONE 2026-08-30. Every item on the "Deleted" list below is gone**, across Stages 2 and 3, plus
> three the list did not anticipate: `usesLibavScrub` (added at Stage 2 as the two-mechanism
> selector and retired with it), `holdScrubOverlayUntilPresented` (the MXF-only remnant of the
> handoff — see the Stage 2/3 note under `presentsSinceFlush` in the STAYS list), and the Stage 0
> `presentImmediate` probe with its ⌃⌥⇧P binding. **The "STAYS" list held with one amendment**, also
> noted below. `LibavThumbnailSource`'s only consumer was confirmed to be `previewImage` before
> deletion, as this list says — checked, not assumed.

**Deleted.** All of it exists to hold a `CGImage` until the real frame lands:

- `ScrubPreviewSurface` + `ScrubPreviewHostView` (`App/MetalSurfaceView.swift`), including
  `logEDRState`, the legacy-EDR opt-in A/B and the `contentsRect` split machinery
- the overlay branch in `ContentView.body`
- `scrubPreviewImage`, `previewRequestInFlight`, `lastPreviewTime`, `scrubHandoff`, `scrubHoldTask`,
  `splitLatched`
- `requestScrubPreview(at:final:)`, `beginScrubHandoff()`, `endScrubHandoff(framePresented:)`,
  `cancelScrubHandoff()`, the 400 ms timeout
- `FrameEngine.previewImage(at:)`, `imageGenerator`, `makeScrubPreviewGenerator` — **including
  `dynamicRangePolicy = .matchSource`**, the fix from the HDR scrub entry. Checked: **one call
  site**, no other consumer anywhere in the app.
- **`LibavThumbnailSource` in its entirety.** Its only consumer is `previewImage`. Its *design*
  survives as the libav producer — own `AVFormatContext`, private serial queue, opened at load — but
  the class does not.
- `ScrubDebug.overlayDisabled` / `.forceLegacyEDR` / `.splitEnabled`, `dismissScrubSplit`,
  `logScrubSplitArmed`, `codecIsAllIntra`, `scrubSplitFurniture`, the ⌃⌥⇧S binding, `[EDRDIAG]`

**⚠️ STAYS — and this is the list that matters, because each of these LOOKS like scrub machinery:**

- **`pendingSeekRender` and the paused-seek relaxed branch.** Serves **every** paused seek — arrow
  step, timecode entry, the Flip refresh path — not scrub. Deleting it with the overlay would break
  paused seeking on files whose decoder overshoots, which is a different entry entirely.
- **`presentsSinceFlush`.** The *callback* that used to trip it had exactly one consumer (the
  handoff) and went with it. The *counter* has a second consumer — the `[EDR]` "colour state
  installed after N present(s) of this source" report — and stays.
  > ⚠️ **AMENDED 2026-08-30, and CLOSED at Stage 4.** The callback did **not** go with the handoff,
  > and it took two further stages. Stage 2 deleted the AVFoundation handoff but kept an MXF-only
  > hold on it (`holdScrubOverlayUntilPresented`), because MXF still had no producer and its Metal
  > layer held the pre-drag frame for the whole gesture — the "the layer already shows the release
  > frame" reasoning simply did not reach it. Stage 3 deleted that too, once `LibavScrubProducer`
  > made the reasoning true for MXF and the settle measured zero, which left the callback unconsumed
  > but still standing. **Stage 4 removed it.** The counter, its reset in `flush()`, its increment
  > after `presentDrawable` and the `[EDR]` line that reads it are all untouched — which is what
  > this bullet was always about.
- **`pendingRefresh` / `setNeedsRefresh()`.** Range-override change while paused.
- **`isScrubbing` and `scrubValue`.** Still drive the slider binding, the `displayTime` readout and
  the HUD auto-hide guard. Only their *overlay* role goes.
- `flush()` / `onFlush`, `wasPlayingBeforeScrub`, `MediaInspector.requiresLibavDecode` / `useLibav`
  (which now selects the **producer** instead of the thumbnail source).

#### ⚠️ ONE DELETED THING CARRIES A MEASURED FACT THAT MUST NOT GO WITH IT

`makeScrubPreviewGenerator` sets **`apertureMode = .encodedPixels`**, and the comment there records
why: the property defaults to nil, which behaves as clean-aperture, so `AVAssetImageGenerator`
applied **both the pixel aspect ratio and the clean-aperture crop** and returned an image at the
file's DISPLAY geometry — while the Metal path renders the full encoded buffer and lets the layer
scale it. Two geometry rules, disagreeing the moment a file carried either tag.

**MEASURED on ARRI open-gate ProRes 4444 XQ (encoded 2944×2160, clean aperture 2880×2160, pasp 1:1):
default mode returned 720×540 — clean-aperture cropped, 32 px lost each side — and `.encodedPixels`
returned 736×540.**

Deleting the generator deletes the *problem*, not the *fact*. Both new producers vend the decoder's
own buffer, so they should agree with the Metal path by construction — `AVPlayerItemVideoOutput`
hands back the decoded `CVPixelBuffer`, and libav hands back the decoded `AVFrame`, neither of which
applies an aperture rule.

⚠️ **THAT IS A PREDICTION, NOT A MEASUREMENT, AND IT MUST BE CHECKED ON THAT FIXTURE.** The ARRI
open-gate ProRes 4444 XQ file named above is the one that exposed the difference; it is the one to
scrub in Stage 1. A route that silently reintroduced the 32-px-per-side crop would look like a
slightly soft preview, not like a geometry bug, and the old harness (`scrubmeas.swift` `MODE=pixdiff`
with `maximumSize = .zero`) is no longer measuring that path.

The same reasoning retires — but does not disprove — the PAR note on the overlay's `.aspectRatio`
pin. The pin exists because *the two preview producers disagreed about pixel aspect ratio*
(`AVAssetImageGenerator` applied PAR, `LibavThumbnailSource` ignored `sample_aspect_ratio`
entirely). With both producers gone the disagreement evaporates; the pin stays on the Metal surface
because that is the video rect's authority, which was always a separate argument.

---

### 2. WHAT REPLACES THE 2026-08-28 POSITION FIX

The release path currently does four ordered things — `isScrubbing = false`, `beginScrubHandoff()`,
`requestScrubPreview(at: scrubValue, final: true)`, `exactSeek(to: scrubValue)` — and the ORDER is
the fix. Both of the premises it was built on are gone, **but for different reasons, and one leaves
a residue.**

**The final un-throttled request: absorbed, not deleted.** Its stated job was to close a staleness
floor created by a **media-time DISTANCE** gate (`> 0.05` s = 1.20 frames at 23.976, never re-asked
at the release point). Once the throttle is a latest-wins coalescer (§3) there is no distance floor:
the last position requested is always the current one. What survives is the **in-flight latch** — at
release one request may still be outstanding at a marginally older position. So the release path
still issues one request at `scrubValue`, but it is **the coalescer's pending slot being flushed**,
not a corrective request aimed at a second decoder. No `final:` parameter, no generation stamp, no
"guard handoff == scrubHandoff" — the reason for all three is gone.

**The hold-until-presented signal: deleted with nothing in its place, and that is correct.** There
is no second surface to keep alive. On release the Metal layer is **already showing the release
frame**, because it got there through the ordinary present path during the drag. `exactSeek` →
`beginReading` → `flush()` clears the queue, and a `CAMetalLayer` keeps its last presented drawable,
which is the scrub frame. **The hold now happens by default instead of by machinery** — which is
what "one display path" buys, stated concretely.

#### ⚠️ THE FAILURE MODE INVERTS, AND IT DOES NOT REACH ZERO ON LONG-GOP

The old risk was *the overlay is held too long*. The new risk is **the seek's first frame is not the
frame the drag was showing** — because the scrub producer seeks at infinite tolerance and
`exactSeek` does not.

| corpus | delivered frame − requested (measured) | release settle |
|---|---|---|
| **MXF / DNxHR** | **0.5 mean / 1.0 max, every fixture; 0 same-frame returns** | ~~zero, by construction~~ → **zero, MEASURED 2026-08-30** (Stage 3): **+0.00 frames and 0.00 codes** across 7 consecutive releases on 4K DNxHR, and the same on DNxHR PQ and on the 42-minute DNxHD — same display-side instrument Stage 2 used. The by-construction reasoning is why: libav is asked for an exact position and DNxHR is all-intra, so the scrub seek and `exactSeek` land on the *same frame*, not merely a near one |
| ProRes (AVPlayer route) | 0.5–0.6 mean / **1.0 max** | effectively zero on all-intra |
| **4K H.264** | 4.4 mean / **10.4 max**; **26 of 40** positions return the frame already on screen | **a one-frame-class settle SURVIVES this work** |
| 6K HEVC | 5.9 / **11.8** | as above |

⚠️ **SO: "no jump at release" IS TRUE OF MXF AND ProRes AND IS NOT TRUE OF H.264/HEVC.** Any release
note, commit message or code comment that states it unqualified will be wrong about part of the
corpus. This is the same trap as *"Property 1"* in the entry above — one sentence covering two
producers with different accuracy characteristics — and it is recorded here so it is not written
twice.

**THE DEFERRED WAY OUT, AND IT IS A STAGE 3 DECISION REQUIRING A MEASUREMENT, NOT AN ASSUMPTION.**

> ⏸ **STILL DEFERRED AFTER STAGE 3 — NOT DECIDED, NOT CLOSED. 2026-08-30.**
> Stage 3 was scheduled to decide this and did not, for a reason worth stating rather than leaving
> as a gap: **the MXF settle measured exactly zero**, so on the corpus Stage 3 actually touched the
> change buys nothing at all. What is left is the case it was proposed for — 4K H.264, where the
> settle measured 4.80 frames mean / 10.26 max — and there the cost is not a decode question but a
> PRODUCT one: the transport would land on the frame the tolerance chose rather than the frame the
> user chose, and the timecode readout would have to say something honest about that. That needs its
> own measurement on 4K H.264, exactly as the paragraph below says. **Deferring it costs the
> long-GOP settle and nothing else; adopting it silently would change what "release" means on every
> codec to fix a defect that only two of them have.**

On release, seek playback to **the frame the scrub producer actually delivered** — its
`itemTimeForDisplay` (AVPlayer) or its frame PTS (libav) — rather than to `scrubValue`. The settle
becomes zero by construction on every codec, and the position readout stops claiming a frame that
was never displayed.

⚠️ **Do not fold this into Stage 1 as an obvious improvement.** It changes what "release" means: the
transport would land on the frame the *tolerance* chose rather than the one the *user* chose, which
is a different product decision and interacts with the still-open *"⚠️ UNCONFIRMED: scrub release
jumps the picture once, on ProRes"* entry. It needs its own measurement — does the delivered-frame
target actually eliminate the settle on 4K H.264, and what does the timecode readout say while it
does — before it is adopted.

---

### 3. THE THROTTLE — a coalescer, not a number, and NOT per producer

Today there are **two gates and neither is a rate limit**:

```
guard !previewRequestInFlight else { return }          // in-flight latch — drops the position
guard abs(time - lastPreviewTime) > 0.05 else { return }   // MEDIA-TIME distance — 1.20 frames
```

The distance gate is the staleness the position fix was written against: it is a *media* distance,
so a slow drag suppresses requests outright, and a fast drag makes it irrelevant while the latch
drops everything that arrives mid-decode.

**What it becomes:**

- keep the in-flight latch — one decode at a time per producer is a real constraint
- **delete the media-distance gate entirely**
- a position arriving while a request is in flight **overwrites a single pending slot** (latest
  wins) and is issued when the in-flight request completes
- cap at **one issue per display refresh** — producing faster than the layer presents is wasted
  work, and the scopes sample per render anyway

The producer then self-paces at exactly its own throughput: ~7 ms → bounded by the slider's event
rate and the refresh cap; ~20 ms → ~50 Hz. **There is no constant to tune.**

#### ⚠️ IT SHOULD *NOT* DIFFER BY PRODUCER, AND THAT IS THE ARGUMENT FOR A COALESCER OVER A NUMBER

The obvious alternative — a wall-clock interval per producer, ~10 ms for AVPlayer and ~25 ms for
libav — is worse for a specific reason: **it is two constants that must stay in agreement with two
measured latencies on two codec families on hardware we do not control.** A machine slower than the
M4 Max moves both numbers; a 6K HEVC file moves one of them by 4×. A latest-wins coalescer is
correct on every machine and every codec without being told anything, because the decoder's own
completion is the clock.

What *is* producer-specific: libav decodes synchronously on its own serial queue, while AVPlayer
does an async seek plus a poll. So "in flight" is defined per producer — but **the coalescer sits
above both, in the producer seam, not in `ContentView`.** The view's job shrinks to handing over a
position. The current gates live in the view only because the overlay's state does.

---

### 4. PRODUCER LIFECYCLE — the part commit `8896163` is about

**Where: on the deck's `FrameEngine`.** Not `ContentView`, not app-wide. There is one engine and one
renderer per deck (`WindowDeck.configure`), and the overlay lives in the view today only because a
`CGImage` is view state. A `CVPixelBuffer` producer is not.

**The engine already has the right lifecycle. Keep it; change only what the object is.**
`libavThumbnailSource` is created in `loadAsset`'s PHASE 2 (commit) and in `loadMXF`, and released in
`stop()` and at the top of the next `loadAsset` commit. That is exactly the shape a scrub producer
needs, and the engine already knows `useLibav`, so producer selection is one branch at a site that
already exists.

**Start: at load, both sites, non-blocking.**
⚠️ **NOT lazily on first drag, and NOT released at drag end.** Both are tempting and both throw away
the measured result: the warm-vs-cold gap **is** the install cost — 30–34 ms of
`avformat_find_stream_info` for libav at 4K, and 11.9–47.1 ms mean (215.6 ms worst first-ever) for
`AVURLAsset` → `readyToPlay`. A per-drag lifecycle pays it on every grab, where it is a visible
stall on the first movement of the scrubber. At load it is invisible.

**Stop: `FrameEngine.stop()` and the top of the next `loadAsset` commit** — the two places
`libavThumbnailSource?.close()` already runs. Deck teardown routes through `stop()`.

#### The invariant `8896163` established, restated for a new producer

That commit fixed `reader?.cancelReading()` racing an in-flight `copyNextSampleBuffer()` because
cancellation ran on whatever queue happened to call `stop()`. The fix was engine-owned stable serial
queues (`videoPumpQueue`, `audioPumpQueue`) with teardown **serialized behind them**. The rule to
carry forward:

> **A producer's teardown is enqueued onto the same serial queue its decode runs on, and that queue
> is owned by the engine and outlives the producer.**

`LibavThumbnailSource` already satisfies it — `thumbQueue` is a `let`, `close()` is
`thumbQueue.async`. **The AVPlayer producer has a different version of the same hazard:** AVPlayer
delivers seek completions and item KVO on the **main queue** (documented as trap 3 in
`docs/scrub-fixtures/README.md`), so its teardown must not block main, and an in-flight seek
completion can arrive after teardown has been requested.

#### ⚠️ THE THREE GENERATION RACES DO NOT DISAPPEAR. THEY RELOCATE.

Deleting `beginScrubHandoff` removes `scrubHandoff` and with it three checks — the late final
preview, the renderer's one-shot, and the timeout. **It is tempting, and wrong, to describe this as
"we removed the concurrency".** The asynchrony that made those checks necessary is a property of
having an out-of-band frame producer, and the producer is not going away — it is moving from a
`CGImage` generator behind a `Task` to a `CVPixelBuffer` producer behind a seek completion or a
serial queue.

**What actually happens: three ad-hoc counters in the view are replaced by ONE engine-owned
`SessionToken`, sitting beside the two that already exist** (`sessionToken` for the video pump,
`audioSessionToken` for the audio pump). A third — call it the scrub token — is bumped on producer
teardown and on every load commit; every async completion captures it and bows out if superseded.

That is a genuine simplification: one token, one idiom, in the file where the other two already live
and are already understood. **But it is a RELOCATION, not a removal, and recording it as a removal
is exactly how it ships under-tested.** The tests that matter are the same ones the handoff needed:
a completion arriving after teardown, and a completion arriving after a *different file* has loaded.

#### ⚠️ THE TOKEN CHECK IS ON THE DELIVERY SIDE, NOT THE REQUEST SIDE

A scrub frame decoded from the OLD file can reach the renderer **after** the new file's
`setSourceColorSpace(...)` has been installed on the layer — old pixels drawn through the new file's
colour state. This is not hypothetical: the renderer already has a diagnostic for exactly this
condition, printing *"⚠️ AFTER a frame was already on screen; that frame was drawn through the
previous colour state"* when colour state installs late.

So the token must be checked **at the point the buffer is handed to `presentImmediate`**, not only
when the request is issued. A check at request time is necessary and not sufficient: the window that
matters is the one between the decode starting and the pixels landing, which is precisely the window
a load can slip into.

**Mid-drag source change, concretely.** A drop, an Open, a Recent pick or a Flip advance can land
while the scrubber is held. Rules:

1. `loadAsset`'s commit phase bumps the scrub token — same place it already retires
   `libavThumbnailSource`.
2. In-flight scrub frames from the old file fail the delivery-side check and are dropped.
3. `ContentView` clears `isScrubbing` from the same `onChange(of: engine.currentURL)` that resets
   other per-file view state — otherwise the slider keeps driving a `scrubValue` that now means a
   position in a different file with a different duration.

---

### 5. STAGING — smallest first, and MXF deliberately last

#### ✅ Stage 0 — the renderer entry point. No behaviour change. **DONE 2026-08-30.**

Add `presentImmediate(pixelBuffer:pts:)` with its own `refreshLock`-guarded one-shot, alongside
`pendingRefresh` and `pendingSeekRender`. Prove it with the existing overlay untouched, driven from
a DEBUG keystroke.

**Checkpoint:** a buffer pushed while paused, at a pts FORWARD of the pinned clock, reaches the
offscreen; `onFrameRendered` fires (scopes) and `pushDeckLinkConvert` fires (SDI). Playback,
seeking, shuttle and the live routes are byte-identical.

#### ✅ Stage 1 — AVFoundation producer behind a flag; the overlay is still authoritative. **DONE 2026-08-30.**

Introduce the producer seam and the `AVPlayerItemVideoOutput` implementation: engine-owned,
load/unload lifecycle, scrub token, latest-wins coalescer. Feed `presentImmediate`. **Keep the
`CGImage` overlay running on top**, so the two paths are directly comparable — reuse
`MANIFOLD_SCRUB_SPLIT`'s half-width `contentsRect` trick before deleting it, since this is the last
moment it can be used for its designed purpose.

**Checkpoint:**
- the drag updates the Metal layer at the measured rate on ProRes and 4K H.264
- **the scopes move during the drag** — they never have; this is the fix for the third problem in
  the entry above, and it should be seen working before anything is deleted
- the split shows the two paths agreeing on all-intra
- **the ARRI open-gate ProRes 4444 XQ fixture scrubs at the correct geometry** (see the
  `apertureMode` note in §1 — this is the check that turns a prediction into a measurement)
- the SDI behaviour change is confirmed working and understood (see below)
- **the v210 conversion cost during a drag is measured** (see the open item below)

#### ✅ Stage 2 — flip the default for AVFoundation files. MXF UNCHANGED. **DONE 2026-08-30.**

Delete the overlay branch, `ScrubPreviewSurface`, the handoff, the three races, `previewImage`'s
AVFoundation branch and the generator. **`useLibav` files keep `LibavThumbnailSource` and the
overlay path exactly as they are today.** This is the releasable "AVFoundation working, MXF
untouched" increment.

✅ **RESOLVED AT STAGE 3 — THERE IS NOW ONE MECHANISM AND ONE DESTINATION.** The paragraph below
described the window Stage 2 opened on purpose; that window is closed. `LibavScrubProducer` put MXF
on the same seam, `LibavThumbnailSource` and the overlay branch are deleted, and `useLibav` now
selects between two PRODUCERS rather than between a producer and a `CGImage`. The reasoning is kept
because it is the argument for splitting a two-decoder change into two releases, and that argument
is reusable; the state it describes is historical.

⚠️ **THIS LEAVES TWO SCRUB MECHANISMS ALIVE AT ONCE, SELECTED BY `useLibav`, AND THAT IS A
DELIBERATE CHOICE — NOT AN ACCIDENT OF SEQUENCING.** Landing both producers together doubles the
surface under test in a single change, across two decoders, two lifecycles and two accuracy
characteristics. Splitting it means the AVFoundation half can ship and be used on real work while
the libav half is still being written.

**What makes it safe is one line that is already there:** the overlay is gated on
`if let preview = scrubPreviewImage`, **not** on `isScrubbing`. That gate was introduced as part of
the 2026-08-28 position fix — *"⚠️ THE GATE IS THE IMAGE, NOT `isScrubbing` — AND THAT IS THE FIX,
NOT A TIDY-UP"* — for an unrelated reason, and it happens to be exactly the property this staging
needs: on the AVFoundation path no image is ever produced, so the overlay is structurally
unreachable rather than conditionally suppressed. **A boolean mode flag would not have been
equivalent, and if that gate is ever "tidied up" into an `isScrubbing` check, this staging stops
being safe.**

> ✅ **2026-08-30, Stage 3: the gate is gone with the thing it gated.** `scrubPreviewImage`,
> `requestScrubPreview` and the overlay branch are deleted, so there is no second mechanism to keep
> structurally unreachable. The property was real and it did its job for exactly one release; it is
> recorded here as the reason that release was safe, not as live code to protect.

**Checkpoint:** HDR PQ ProRes scrubs without the mode change (closes the HDR scrub entry's Parts 1
and 2 by removing their subject); no jump at release on all-intra; the H.264 release settle
characterised and recorded rather than treated as a regression; MXF behaves exactly as it does
today, verified rather than assumed.

#### ✅ Stage 3 — libav producer for MXF. **DONE 2026-08-30.**

Second implementation of the same seam: `FF_THREAD_SLICE`, held `AVFormatContext`, own serial queue,
same scrub token. Retires `LibavThumbnailSource`. ~~**Decide the release-seek-target question from
§2 here**, with its own measurement.~~ **NOT decided — see the deferral recorded at that question.**

**Checkpoint — all met.** ~20 ms drag on 4K MXF (measured **20.0 ms mean**); **HDR PQ/HLG MXF
previews stop being SDR**, which closes the deliberately-deferred Part 3 of the HDR scrub entry by
deleting the 8-bit RGBA path rather than giving it a float variant; scopes live on MXF. Numbers and
what remains open are in *"✅ MEASURED 2026-08-30 — Stage 3"* below.

⚠️ **ONE CHECKPOINT ITEM WAS NOT DONE AS WRITTEN.** "Re-run `libavmeas MODE=memory` against the real
app" was replaced by Xcode's memory gauge on the real app during repeated drags — a different
instrument answering a narrower question. See the memory row in the Stage 3 entry, which says which
instrument produced the number.

#### ✅ Stage 4 — scaffolding removal. **DONE 2026-08-30.**

~~`ScrubDebug`'s three env vars, `codecIsAllIntra`, `[EDRDIAG]`, the split furniture~~ — **all
already gone**, pulled forward into Stage 2. What remained was one deletion and one decision. Both
are now made.

**1. `onFirstPresentAfterFlush` is REMOVED.** What went: the `refreshLock`-guarded property, its
backing store, the fire-and-clear block in `renderPixelBuffer`, and the rationale comment on the
declaration. Its only consumer was ever the scrub-release handoff — the AVFoundation one (deleted
at Stage 2), then the MXF-only `holdScrubOverlayUntilPresented` (deleted at Stage 3, once the MXF
settle measured exactly zero) — so it had been unconsumed for a full stage before it was retired.

> **ZERO ARM SITES ANYWHERE IN THE TREE — CHECKED, NOT ASSUMED.** The symbol had six occurrences in
> the entire repository and all six were inside `MetalVideoRenderer.swift`: the declaration, its two
> accessors, the backing store, and the two lines of the fire-and-clear. The only two ASSIGNMENTS
> were the setter's own store and the `= nil` that cleared the one-shot as it fired — both internal
> plumbing, neither an arm. **Nothing in `ContentView`, no test and no fixture assigned it after
> Stage 3.** That is what made this a self-contained deletion rather than a careful one, and it was
> established by search before the edit, not inferred from the Stage 3 note.

⚠️ **`presentsSinceFlush` SURVIVES, DELIBERATELY, WITH ITS `[EDR]` READER INTACT.** The declaration,
the reset under `refreshLock` in `flush()`, the increment immediately after `presentDrawable` — with
the "counted HERE and not in `presentDrawable`" rationale that keeps a teardown black frame out of
the count — and the `[EDR]` *"colour state installed on the layer after N present(s) of this
source"* report all stand unchanged. The only counter-related thing that went is the
`presentsSinceFlush == 1` edge test that gated the one-shot: the counter now runs purely for the
colour-state report. The `renderImmediateFrame` doc comment was reworded where it described that
report as the counter's *"OTHER"* reader, since it is now the only one.

**2. THE INSTRUMENTS ARE KEPT PAST STAGE 4 — DECIDED, NOT DEFAULTED.** `[SCRUB]`, `[SCRUB-GEOM]`,
`[SETTLE]`, `[V210]` and `ScrubProducerFlags.stats` (`MANIFOLD_SCRUB_STATS=1`) all stay. The
section above asked for this to be decided here rather than by default; this is that decision.

**The reason is a live open item, not a general preference for keeping instruments.** Open item 1
of the Stage 3 entry stands: `thread_count = cores − 1` is a **16-core Studio result** — 8 and 15
threads measured there, 15 shipped — being applied to a **4P/6E MacBook Air M4**, where the same
arithmetic gives 9 threads spread across cores that are not interchangeable, and **nothing has run
on that part.** `MANIFOLD_SCRUB_STATS` is the instrument that closes that question. Deleting it now
would mean rebuilding it to answer it.

Two supporting facts, neither of which is the reason on its own:

- **They cost nothing when off.** All of it is env-gated and **off by default**: a tester's build
  carries the code and never the output.
- **`[SCRUB-GEOM]` has a second, permanent job.** It is the standing ARRI open-gate check — the
  producers' encoded-geometry contract made arithmetic — and it is what would catch a reintroduced
  clean-aperture crop, which is 32 px per side on the fixture that exposed it and reads as a
  slightly soft preview rather than as a geometry bug.

**The removal condition, so this is a decision and not a deferral: they come out when the thread
count is characterised on a small part.** That measurement retires the open item and the instrument
that exists to serve it, together.

**The colour-management mode picker's precondition is met at this point and not before** — see the
last section of the entry above. ⚠️ **As of Stage 3 the precondition is in fact already met**: there
is one display path and it is steerable. Stage 4 removes scaffolding, not a blocker.

---

### ✅ DECISION: THE SDI FEED FOLLOWS THE DRAG

**Decided 2026-08-30. Recorded because it is a behaviour change to an output somebody may be
watching, and because the alternative is defensible enough that it will be re-proposed.**

`pushDeckLinkConvert` is called from inside `renderPixelBuffer`, so any frame that reaches the
offscreen reaches SDI. **Today a drag leaves the SDI feed frozen on the pre-drag frame** — the
overlay is a `CALayer` above the Metal layer and never touches the offscreen. After Stage 1 the SDI
output will track the scrub.

**This is correct and it is the intended behaviour.** It matches the desktop picture and the scopes.
**A reference tool showing three different frames on three surfaces — desktop, scopes, SDI — is
worse than one that moves**, and the scopes-are-stale problem recorded in the entry above is the
same defect on a different surface. Fixing two of three and leaving the third frozen would be a
strictly worse outcome than either fixing all three or fixing none.

⚠️ **IT IS STILL A BEHAVIOUR CHANGE AT STAGE 1, AND SOMEONE MAY BE MONITORING THAT FEED.** A grade
suite watching SDI on a broadcast monitor will now see the picture move while a colourist scrubs. It
must appear in **release notes**, not be discovered by a tester who reports it as a fault. Stage 1's
checkpoint includes confirming it works as intended, not merely that it happens.

### ⚠️ OPEN ITEM FOR STAGE 1'S CHECKPOINT — the v210 conversion cost during a drag is UNMEASURED

Every frame that reaches `renderPixelBuffer` triggers a v210 convert for DeckLink. A 20 Hz drag
therefore adds ~20 conversions per second **on top of playback's**, at source raster, on a path that
already has a 33 ms budget called out as at-risk from raster, codec and storage together.

**Neither spike measured it** — `avpvomeas.swift` and `libavmeas.swift` both stop at the
`rgba16Float` offscreen, which is the right boundary for the scope question and the wrong one for
this. It is bounded above by the one-issue-per-display-refresh cap in §3, and the drag is seconds
long rather than minutes, so it is unlikely to be a problem — **but "unlikely" is not a measurement,
and this is the one cost on the whole route that nothing has looked at.** Measure it at Stage 1,
with the card active, on 4K, before Stage 2 deletes the fallback.

> ✅ **MEASURED at Stage 1, 2026-08-30 — and it is not a problem.** 4K (3840×2160), DeckLink 8K Pro
> at 2160p23.98, drag at 22.3 Hz: **offered 91, converted 91, skipped 0**, GPU **0.10 ms mean /
> 0.18 max**, encode→GPU-done 0.30 ms. The playback baseline on the same file seconds earlier was
> identical (145/145, 0.10 ms mean). The convert is ~1 % of the ~11 ms decode it rides behind, and a
> drag is *less* v210 work than playing the file because 22 Hz is below 24 fps. Instrument: `[V210]`
> in `MetalVideoRenderer.debugFlushV210Stats`, flushed at the drag's two edges.

---

## ✅ MEASURED 2026-08-30 — Stage 3: the libav scrub producer, and the end of the CGImage path

**What this is:** the numbers Stage 3 of *"two producers, one destination"* was verified with, kept
separate from what they imply. Every row under MEASURED was produced by an instrument named in the
row; every row under INFERRED was not measured and is marked as such. Same discipline as
`docs/COLOR_MANAGEMENT_FINDINGS.md`.

**What shipped:** `LibavScrubProducer` (`FF_THREAD_SLICE`, held `AVFormatContext`, own serial queue,
own context — never the playback one), feeding `presentImmediate` through the same `ScrubCoalescer`
and the same delivery-side scrub token as the AVFoundation producer. `LibavThumbnailSource`, the
overlay branch, `scrubPreviewImage`, `requestScrubPreview`, `previewImage` and
`holdScrubOverlayUntilPresented` are deleted. **There is no `CGImage` anywhere in the scrub path.**

### MEASURED

| what | result | instrument |
|---|---|---|
| **Drag rate, 4K DNxHR** (`Lip Sync DNX.mxf`, 701 Mb/s, SMB) | 90 issued, 88 delivered, 0 coalesced; **21.3 Hz**; seek→deliver **20.0 ms mean / 20.5 p50 / 22.5 p90 / 24.3 max** | `[SCRUB]`, `ScrubCoalescer.flushStats` |
| **Drag rate, DNxHR PQ** (`cs2020_pq.mxf`) | 41 issued, 40 delivered; **18.8 ms mean / 32.6 max** | " |
| **Drag rate, 1080p DNxHD, 41.86 GB / 42 min** | 91 issued, 90 delivered, 0 coalesced, 0 empty; **21.5 Hz**; **7.1 ms mean / 6.7 p50 / 7.4 p90 / 27.7 max** | " |
| **Release settle, MXF** | **+0.00 frames, 7 consecutive releases on 4K DNxHR**; same on DNxHR PQ and on the 42-min DNxHD. Picture across the release **0.00 codes / 0.0 % of pixels** | `[SETTLE]` (`MetalVideoRenderer.reportSettleIfArmed`) + screen-diff over the video rect |
| **Scopes move during an MXF drag** | Stage 2, same fixture and same gesture: **0.00 codes / 0.0 %** (bit-identical, frozen). Stage 3: **0.40 / 0.8 %** on that fixture, **1.11→5.47** and **3.05→16.79 codes** on content-varied ones | screen-diff of the scope tray, before/after A/B |
| **SDI follows an MXF drag** | card front-buffer source time swept **2.002 → 48.465 s** across a 91-position drag; **89 of 89 converts, 0 skipped**; v210 GPU **0.11 ms mean** | `[V210]` front-pts span, DeckLink 8K Pro at 2160p23.98 |
| **HDR buffer tags, MXF PQ** | scrub buffer arrives `x420 trc=SMPTE_ST_2084_PQ pri=ITU_R_2020 mtx=ITU_R_2020`; layer `kCGColorSpaceITUR_2100_PQ`, `wantsExtendedDynamicRangeContent = true`; picture during drag **bit-identical** to the played picture | `[SCRUB-GEOM]` + `[EDR]` + screen-diff |
| **HDR, by eye** | dim on scrub **gone**, Mac Studio → LG 42-inch WOLED in HDR mode, **both SDR and HDR** content. The dim had also been present on the MacBook Air | direct observation |
| **Geometry** | producer dimensions == playback offscreen on every fixture (3840×2160, 1920×1080; and 2944×2160 on the ARRI open-gate ProRes at Stage 1) | `[SCRUB-GEOM]` |
| **Memory, 42 GB file** | ceiling **under 700 MB**, **519.2 MB at sample**, across repeated drags at varied speeds | ⚠️ **Xcode's memory gauge on the running app — NOT `libavmeas MODE=memory`.** A different instrument answering a narrower question than the checkpoint asked for |
| **No regressions** | MXF playback **24.0 fps**; six paused frame steps → **five `[ScopeSeek]` relaxed renders**, zero spurious settle lines; matched-size resize round-trip while paused returns the picture at **0.09 codes** | `[Play]`, `[ScopeSeek]`, screen-diff |

### INFERRED, NOT MEASURED

- **Why the 42 GB file is the *fastest* case.** It is 1080p DNxHD, not 4K DNxHR — a smaller decode.
  The reading that file size and duration cost a held context nothing is consistent with the
  numbers but was not isolated: no 4K fixture of comparable size exists to separate raster from
  size.
- **That the held context is what makes a 42-minute seek cheap.** Not A/B'd against a per-request
  context in the app; the per-request cost is from `libavmeas`, on the model rather than the app.

### ⚠️ STILL OPEN — recorded rather than omitted

1. **`thread_count = cores − 1` is tuned on a 16-core machine and is UNCHARACTERISED on a small
   part.** The SLICE-vs-FRAME measurement ran 8 and 15 threads on a 16-core Studio (19.2 vs 17.4 ms)
   and the shipping value resolved to 15 there. On a **4P/6E MacBook Air M4** that arithmetic gives
   9, spread across cores that are not interchangeable, and nothing has run there. The choice to
   leave one core free is defensible on both — it exists so the Metal scope-compute completions get
   scheduled — but the *number* is a 16-core result being applied to a part with a different
   topology.
2. **The coalescer's latest-wins path was never exercised on the libav side.** Every MXF run
   reported `coalesced=0`: libav never backed the queue up at the rates a mouse-driven drag
   produces. So the pending-slot logic is **shared code with only one of its two callers stressing
   it** — the AVFoundation side coalesced 53 of 70 on a deliberately violent drag, the libav side
   never once. Not a defect; a gap in coverage, and the kind that surfaces on slower hardware.
3. **`LibavPixelConversion` moved the PLAYBACK path and played MXF colour was not diffed against a
   pre-Stage-3 binary.** The conversion, the colour-attachment mapping and the pool factory were
   extracted from `LibavFrameSource` so both libav clients share one definition — which is the point
   — but that means the playback path now runs through moved code. ⚠️ **No measurement in this stage
   can catch a regression there**, because the scrub side and the played side would have shifted
   *together*: every "the preview is bit-identical to the played picture" result would still read
   0.00 with both halves equally wrong. The check that would catch it is a played-frame export from
   an MXF diffed against a pre-Stage-3 build, and it has not been done.

### Threading invariant — a deviation, stated

`Decoder.close()` enqueues teardown onto the decode queue (`scrubQueue.async { self?.freeOnQueue() }`),
which satisfies the first half of the `8896163` invariant. Two departures from how §4 states it:
**`deinit { freeOnQueue() }` runs synchronously on whatever thread releases the last reference**,
not on the queue; and **the queue is owned by the `Decoder`, not by the engine**, so it does not
outlive the producer. ⚠️ `LibavThumbnailSource` had the identical shape — `private let thumbQueue`,
`close()` doing `thumbQueue.async`, `deinit { freeContexts() }` — so §4's claim that it "already
satisfies" the invariant was already using a looser reading than the invariant's own wording. The
new producer matches that precedent exactly and does not match the literal statement. **The deinit
race was reasoned about, not tested.**

---

## ⏸ BANKED: HLS as a source — a VIEWER/QC feature on the egress side, gated on the AVPlayer spike

**Status:** BANKED, not built. **✅ THE GATE IS PASSED — 2026-08-29, and this is the use it passed
most cleanly.** **Raised:** 2026-08-28. **Was gated on:** *"⏸ BANKED: feed the scrub gesture from
`AVPlayerItemVideoOutput` — one decoder, one display path"* above — see "Why this is now coupled",
and the result immediately below.

**What exists today:** `StreamType.hls` in `App/Preferences.swift` — detection only. A URL whose
path contains `.m3u8` is recognised, saved, listed, and shown **disabled** with an honest reason:

```swift
var isSupported: Bool { self == .web || self == .srt }
case .hls: return "HLS — not yet supported"
```

`type` has been stored per bookmark from the beginning precisely so this line can change without a
migration, exactly as it did for `.srt` in stage 3e. There is no HLS code beyond that.

### ⚠️ WHAT THIS IS FOR — QC ON EGRESS, AND IT IS NOT A SUBSTITUTE FOR SRT

**HLS is the EGRESS side. It shows what the platform actually PUBLISHED — after its transcode, at
its latency.** The value is putting Manifold's scopes on a live delivery feed and checking what
went out: colour, frame rate, whether the transcode mangled anything. **That is a QC question and
nothing else answers it the same way** — you are measuring the platform's output, not your own.

**⚠️ SRT IS THE CONTRIBUTION PATH AND ARRIVES UNTOUCHED. DO NOT TRADE ONE AGAINST THE OTHER WHEN
SETTING PRIORITIES.** They answer different questions and neither substitutes for the other:

| | SRT | HLS |
|---|---|---|
| side of the chain | **contribution** — into the platform | **egress** — out of the platform |
| what you are looking at | what you SENT, untouched | what the platform PUBLISHED, transcoded |
| latency | sub-second, monitorable in the room | segment-bound, seconds |
| the question it answers | "is my feed good?" | "did the platform wreck it?" |

A build that has SRT is not part-way to having HLS, and a build that has HLS has not made SRT less
necessary. The confusion is easy to make because both are "a stream URL in a box", and the entries
are worth keeping adjacent so it does not get made.

### Why this is now coupled to the AVPlayer spike

**AVPlayer plays HLS natively, so the PICTURE is nearly free. The work is getting frames OUT of it
and into our shader, offscreen, scopes and SDI — which is the same mechanism the scrub spike is
testing.** A picture that only reaches an `AVPlayerLayer` is worth very little here: the entire
point is the scopes, and the scopes read the offscreen ring
(`MetalVideoRenderer.renderPixelFormat`: *"Display, export, DeckLink and the SCOPES all read this
target"*). Without `AVPlayerItemVideoOutput` → `CVPixelBuffer` → `renderPixelBuffer`, HLS would be
a picture with no instruments attached to it, which is the opposite of the feature.

> **ONE MECHANISM, THREE OUTCOMES.** If the spike measures well, the same route yields: the scrub
> preview fixed (colour mode consistency), live scopes during a drag, **and HLS as a source.**
> If it measures badly, **HLS gets harder too** — the alternative is demuxing and decoding HLS
> ourselves, which means segment fetching, playlist refresh, discontinuity handling and a decoder,
> against a vendored FFmpeg that has no HTTP protocol at all (`PROTOCOL_IN exactly: file`) and no
> H.264 decoder (only the parser).

### ✅ MEASURED 2026-08-29 — the mechanism works, and this is the strongest of the three uses

⚠️ **THIS WAS MEASURED SEPARATELY AND NOT INFERRED FROM THE FILE NUMBERS.** Nothing in a local-file
seek measurement answers "does `AVPlayerItemVideoOutput` vend buffers from an HLS item at all" —
that is a different mechanism against a different source, and it is the whole feature. Run with
`MODE=hls` in `docs/scrub-fixtures/avpvomeas.swift`, against public adaptive test streams, as a
~60 Hz pull loop — the shape a `CVDisplayLink`-driven consumer would have, not seek-and-wait.

| | 4K adaptive ladder, 25 s | 29.97p ladder, 20 s |
|---|---|---|
| frames pulled | 597 = **23.9 fps** | 596 = **29.8 fps** |
| vended pixel format | **x420** | **x420** |
| empty pulls | **0** | **0** |
| display times repeated / backwards | **0 / 0** | **0 / 0** |
| `copyPixelBuffer` cost | **0.1 ms** mean, 4.7 max | **0.1 ms** mean, 1.9 max |
| shader → completed offscreen | 0.7 ms mean, 8.4 max | 0.7 mean, 4.8 max |
| network | 81 Mb/s | 16 Mb/s |
| process footprint | 555 MB | 317 MB |

**The buffer arrives as `x420` — the app's own decode contract, unchanged** (`FrameEngine.videoPixelFormat`),
so it goes to `renderPixelBuffer` with no conversion and reaches the offscreen ring the scopes read.
**Full frame rate sustained, zero dropped pulls, and zero repeated display times over 25 seconds** —
a repeat would be a frame the scopes showed twice, which is the specific way this could have been
useless while looking like it worked.

**Why this use is the strongest, exactly as this entry predicted:**

- **The two risks that qualify the scrub use do not apply here.** There is no drag, so per-seek
  latency is irrelevant — and the pull cost that IS on the hot path is **0.1 ms**. There is no
  second decode of a local file, so the **+774 Mb/s IO amplification** recorded against the scrub
  use has no analogue: HLS is one stream, decoded once, at the ladder's own bitrate.
- **Memory is the AVPlayer stack itself, not an increment on top of something.** 555 MB for a 4K
  ladder is the whole cost of the feature, not a second pipeline's delta.

⚠️ **Seeking an HLS VOD item is SLOW — 188 ms mean, 624 ms worst** (segment fetch, measured). **This
does not touch the QC use**, which is live monitoring with no scrubber. Recorded so nobody discovers
it while building a transport for HLS and reads it as a defect in this route.

⚠️ **The ABR ladder settled at 1280×720 inside a 25 s window** on the 4K stream. That is the ladder
ramping, not a ceiling of the mechanism — but it means **the raster of a live HLS feed is not under
our control and will change during a session.** Anything that assumes a fixed source size, including
the offscreen sizing, has to handle it changing mid-stream. This is a REAL constraint on the feature
and it was not visible before this measurement.

**Spike the AVPlayer route FIRST, and read its result as a decision about three features rather
than one.** The two risks it must answer are stated in that entry (latency at drag rate; memory and
IO of a second decode pipeline on large sources). The HLS case actually stresses them *differently*
and more gently: there is no drag, so per-seek latency does not matter, and the source is a network
stream rather than a second reader against a local 8K file. **So HLS could survive a spike result
that kills the scrub use, and that is worth measuring for rather than assuming either way.**

### ⚠️ PLATFORM REALITY — read this before scoping, so nobody scopes it expecting YouTube

**Plain HLS, would work:** Twitch, Vimeo, most broadcasters, and anything self-hosted — a fetchable
`.m3u8` you can paste. This is the ordinary case and it is the whole of what this entry proposes.

**YouTube live is OUT OF SCOPE, and it is a different problem rather than a limitation of this
one.** YouTube live is DASH-first with no stable fetchable HLS manifest. Watching a YouTube stream
means URL extraction from a page — a scraping problem that breaks whenever they change something,
carries its own terms-of-service question, and has nothing to do with HLS ingest. **If someone asks
for "watch a YouTube stream", that is a separate entry, not a bug in this one.** Recording it here
so the request is recognised rather than absorbed.

### What "done" would mean

- An `.m3u8` bookmark connects from the same UI SRT and WHEP already use, with `isSupported`
  admitting it — no migration, by construction.
- The picture reaches the **offscreen ring**, so waveform / parade / vectorscope / CIE all read it
  and DeckLink can embed it. A picture without the scopes does not count as done.
- Colour tags travel: HLS carries CICP in-band, and `setSourceColorSpace` already takes primaries /
  transfer / matrix from whatever source publishes them.
- Latency is REPORTED, not hidden. Segment-bound latency is inherent to the transport and a viewer
  needs to know what it is looking at is seconds old — the same honesty the SRT connect line already
  applies to its negotiated latency.
---

## ⏸ BANKED: an unrecognised CICP primaries code silently becomes 709, and the fallback is written twice

**Status:** BANKED, not fixed. **NOT an HLS bug** — pre-existing, app-wide, and deliberately left
alone while HLS was built. **Found:** 2026-09-08, on the first live HLS run, which is the first
thing that ever made it visible. **Belongs to:** the colour-management work
(`docs/COLOR_MANAGEMENT_FINDINGS.md`), not to the transport that surfaced it.

**What happens:** a source declaring CICP primaries **6** (SMPTE-C) is treated as **1** (Rec.709) by
every instrument in the app. The raw code is stored and reported honestly — `sourcePrimariesCode`
keeps it, and the `[HLS] colour signalling` / `[EDR] source tags` lines print `primaries=6` — but
nothing downstream distinguishes it. SMPTE-C and 709 primaries genuinely differ (green ≈ 0.310,0.595
vs 0.300,0.600; red also moves), so the CIE gamut triangle and the layer colorspace are drawn for a
gamut the source did not declare. Small, and this is a QC instrument.

**⚠️ THE MATRIX AXIS IS NOT AFFECTED, AND THAT IS THE PART THAT WOULD HAVE MATTERED.**
`ycbcrKrKb(forMatrixCode:)` has an explicit `case 6: return (0.299, 0.114) // Rec.601`, so the
shader's YCbCr→RGB conversion and the waveform's luma weights DO follow a 601 declaration. Decoding
601-matrixed chroma with 709 coefficients is a visible error; that does not happen. What collapses
is only the primaries/gamut axis.

### Why HLS is what exposed it

Every previous source declares its colorimetry ONCE, at open. **ABR renditions are tagged
individually**, so an HLS ladder is the first source that can change its declared primaries
*mid-session* — and the first that shows two different declarations in one session. Measured on
Apple's bipbop stream: `primaries=6 matrix=6` on the 416×234 rendition, stepping to
`primaries=1 matrix=1` on the HD rungs. Before this, a 601-tagged SD file would have been quietly
mis-plotted too; nothing put the two side by side where the difference could be noticed.

### ⚠️ THE FALLBACK IS WRITTEN TWICE, AND THAT IS THE ACTUAL DEFECT TO FIX

Two independent switches decide what a primaries code means, and they must agree:

| site | what it decides | codes it knows |
|---|---|---|
| `MetalVideoRenderer.makeColorSpace` | the LAYER colorspace | `(12,_)`, `(9,16)`, `(9,18)`, `(1,1)` → else 709 |
| `CIEScope.gamut(forPrimariesCode:)` | the CIE GAMUT TRIANGLE | `9`, `11`, `12` → else 709 |

They do not even agree today about which codes are *recognised* — `makeColorSpace` keys off a
`(primaries, transfer)` PAIR while `gamut` keys off primaries alone, so 11 and 12 are one case in
one and split in the other. They currently reach the same answer for code 6 by both falling
through, which is agreement by coincidence rather than by construction.

**DO NOT FIX THIS BY ADDING `case 6:` TO BOTH SWITCHES.** That leaves exactly the
two-copies-must-agree problem that two earlier extractions in this codebase exist to remove:

> `LibavPixelConversion` — *"The libav→CoreVideo mapping, in ONE place because there are now two
> clients of it… Two copies of a colour table is how that stops being true silently: a file with an
> unusual transfer would render one way while playing and another way while scrubbing, and nothing
> would say so."*

> `VectorscopeScopeModel.plotPoint` — *"Extracted at the second real caller rather than the third:
> two copies of a placement rule is how a 'custom target' ends up a few points off the box it was
> placed relative to, with nothing in the source to say which of them is wrong."*

The same argument applies here and is stronger, because the two consumers are the PICTURE and the
INSTRUMENT MEASURING THE PICTURE. Two copies drifting means the scope and the display disagree about
what gamut is on screen — the one disagreement a QC tool must not have, and the one it is least
able to reveal, since both would look internally consistent.

**What the fix should be:** ONE place that answers *"what does this CICP primaries code mean"* —
chromaticities, a colorspace name, and a label — with `makeColorSpace`, `gamut(forPrimariesCode:)`,
`gamutPrimariesLabel` and `VectorscopeScopeModel.graticuleKrKb` all deriving from it. Then a
primaries code is handled ONCE and every consumer inherits it, including the next one. Note
`CIEScope.gamut` already carries half the argument in its own doc comment — it derives the shader's
RGB→XYZ matrices from its chromaticities *"so deriving is what keeps ONE statement of where each
primary actually is"* — so the pattern is established and this is an extension of it, not a new
idea. `docs/COLOR_MANAGEMENT_FINDINGS.md` §6 is where the shape of that work is already being
argued.

**Until then it is a KNOWN, BOUNDED inaccuracy:** wrong gamut triangle and layer primaries on
SMPTE-C/601-tagged sources, correct matrix, correct transfer, and honest reporting of the raw code
in the logs so the discrepancy is at least discoverable.
---

## DeckLink devices are invisible on Desktop Video 14.x — we ask for an interface their driver has never heard of

**Status:** ✅ **CONFIRMED and RESOLVED for the reported case, 2026-08-28.** Cause was identified
from the SDK headers at ~85% confidence; it is now **measured, not inferred**. **Reported:**
2026-08-27 by a tester (Joey). **Blocks:** nothing today — see *What would reopen this* before
assuming that is permanent.

### ✅ THE CONFIRMATION (2026-08-28)

**The tester updated Desktop Video 14.5.0 → 16.x and his device was recognised immediately.** Same
hardware, same Thunderbolt chassis, same machine, same boot path — **only the driver changed.**

That is the whole diagnosis, tested directly. The IID table below predicted exactly this: a newer
driver serves old IIDs, an older driver cannot serve an IID that did not exist yet, so moving the
driver forward — and nothing else — had to fix it. It did. The ~85% was the gap between "the
headers say this must be true" and "we watched it happen"; that gap is now closed.

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

### ✅ THE FLOOR CHANGE IS VALIDATED — this is the case it was written for

The fork below resolved toward **bump the floor and say so honestly**, and the confirmation
validates that choice against the actual failure rather than against a prediction.

On build 13 the tester would have read:

> Desktop Video 14.5.0 can see 1 device, but this build of Manifold needs Desktop Video 16.0 or
> later to open an output on it. **This is a driver version problem, not a hardware or cabling
> problem.** Update Desktop Video, then relaunch Manifold.

— instead of the silence he actually got. He would have updated and been working **without a
diagnosis session at all**: no export, no code read, no IID table. The comment at
`DeckLinkService.swift:188` calls this "THE SENTENCE THIS WHOLE CHANGE EXISTS FOR", and this is the
case that proves it, because the recovery it describes is exactly the one that happened — just
several days and one investigation later than it needed to.

Note what the message got right that a bare version warning would not: it names the device count
FIRST, so the reader knows their hardware was *seen*. The failure the old wording produced was a
tester checking cables. Naming the count is what stops that.

**THE FORK AS IT STOOD:**

- **Bump the floor to 16.0 and say so honestly in the UI.** ✅ **TAKEN.** Cheap, immediately
  correct, and it converts a silent failure into an actionable message. Cost: anyone whose hardware
  cannot run 16.x loses DeckLink output entirely.
- **Query versioned IIDs throughout the output path.** 🏦 **BANKED — deliberately not scheduled.**
  Preserves old hardware. Costs a real compatibility layer across enumeration,
  `IDeckLinkVideoBuffer` and the metadata extensions, plus a way to test it that does not exist on
  the build Mac today.

### 🏦 BANKED: the versioned-IID branch, and what would reopen it

**Why it is banked rather than scheduled.** Requiring current Blackmagic drivers for a new
application is a defensible system requirement — it is what the SDK is built against, and it is
what Blackmagic themselves expect. The one tester who hit this **could** update, and when he did,
it worked. Building and testing a compatibility layer across three interfaces to serve a
population currently measured at zero would be work spent against a hypothesis.

**⚠️ WHAT WOULD REOPEN IT — a user who CANNOT update.** Two concrete shapes, and neither is a
thought experiment:

- **Hardware that Desktop Video 16.x dropped support for.** Blackmagic retires older devices from
  new driver releases. A user on such a device is on 14.x *by necessity*, and for them
  old-driver support is a requirement rather than a courtesy.
- **A facility that pins driver versions.** Post houses hold a qualified driver across a room or a
  whole floor because a working setup — a colour suite, a review theatre, a QC bay — depends on
  it. "Just update Desktop Video" is not available to that user at any price; the pin is the
  room's stability policy and one application does not get to override it.

**This is ordinary in post, not an edge case, which is why this entry stays findable rather than
being closed.** One report of either shape moves this from banked to scheduled — and the IID table
above is the work already done, so the reopening cost is implementation, not diagnosis.

### ✅ CLOSED — the device is identified

**DeckLink Mini Monitor: a PCIe card in a Thunderbolt expansion chassis.** The tester's own
diagnostics were right and the "UltraStudio 3G" relay was wrong.

This closes the second half of the question too. **The Thunderbolt-2 concern is moot** — that
worry applied only to the *UltraStudio* Mini Monitor, a different product, and it is not what he
has. The DeckLink Mini Monitor works on Desktop Video 16.x on Apple Silicon, which is now observed
rather than argued: there was never a second, independent reason it could not work.

On the part that IS settled: all three are **playback-only devices, which is exactly what the
filter is looking for** — such a device vends `IDeckLinkOutput` and no `IDeckLinkInput`. There is
no capture-only trap here. The filter's logic is right; only the IID it asks for is wrong.

### What was asked, and what came back — all answered 2026-08-28

Kept rather than deleted: these were the two questions that decided the fork, and the record of
which one settled it is worth more than the list of asks.

1. **The verbatim model name** → **DeckLink Mini Monitor**, PCIe in a Thunderbolt chassis. Ruled
   out the UltraStudio Thunderbolt-2 scenario, and with it the possibility of a second independent
   cause that IID work would not have fixed.
2. **Can Desktop Video update to 16.0.1?** → **Yes, and the device appeared immediately.** This
   was written as "confirms the diagnosis outright and unblocks him the same day", and that is
   precisely what it did. The alternative branch — Setup refusing, or the device disappearing
   after the update — did not happen, which is why the fork resolved toward the floor rather than
   toward versioned IIDs.
3. **Does Resolve still see it after the driver change?** → Not needed. It was a control for the
   case where the update did *not* fix it; the update fixed it.
4. **Not worth asking:** cables, ports, replugging. This held. The failure was version-shaped, not
   connection-shaped, and enumeration lifetime was already ruled out — the afternoon the old
   wording would have cost in cable-checking is the cost the floor message now prevents.

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

---

## ✅ CAUSE CONFIRMED 2026-08-29 — the Refresh highlight cannot see a Flip edit, and no metadata fingerprint can

**Status:** ✅ **CAUSE CONFIRMED 2026-08-29.** **NOT a regression in Manifold** — nothing in this
app's history touched the path, and the code is byte-identical to the day it landed. **NOT a defect
in Flip either** — the behaviour that defeats us is deliberate there and documented. **FIX LANDED
2026-08-29:** the highlight is now armed from INTENT (the Edit in Flip press) as well as from
detection. **Found:** 2026-08-28, during a demo. **Blocked, until the fix:** the Flip round-trip —
a file edited externally has to be noticed, and the highlight is the only signal.

### ⚠️ THE ENTRY THAT STOOD HERE BEFORE WAS WRONG ON ITS MOST CONFIDENT LINE

It said, in bold, that this is "a regression, not a never-worked", and called that the most useful
line in the entry. It was the least useful one. **The highlight was never unconditional.** It has
always fired only for the subset of Flip edits that change the file's byte LENGTH, so which file
and which edit you demo with decides the outcome — not which build. That is why "when did it break"
had no answer and a bisect would have found nothing. The observation "I have seen it work" was
true and was not evidence of a regression.

Kept, rather than deleted, because the wrong inference is the instructive part: *"it used to work"*
is a report about two sessions with different inputs, not about two builds.

### The cause, in one line

**Flip restores the file's modification date after every in-place write, writes in place so the
inode never changes, and preserves the file's length wherever it can — which is all three fields
the fingerprint compares.**

`App/SourceFileWatcher.swift` names this exact case in its own comment as the one thing that slips
through: *"an edit that rewrites the bytes in place, keeps the length, and then restores the
modification date."* That is a precise description of Flip.

| fingerprint field | what Flip's in-place write does to it |
|---|---|
| modification date | **restored to its pre-write value**, explicitly |
| size | unchanged for a same-size overwrite, and for a grow absorbed by an adjacent `free`/fill atom; MXF header writes are size-invariant *by assertion* |
| inode (`st_ino`) | unchanged — the file is opened `r+`, never replaced |

Flip's three write sites, for whoever checks this next:

- `electron/parser/patch.js:27-35` — `preserveMtime` stats, writes, then
  `fs.utimesSync(filePath, mtimeMs/1000, mtimeMs/1000)`. Every patch write is wrapped in it.
- `electron/parser/moov.js:310` and `:636` — `writeMoovBack` ends in
  `fs.utimesSync(filePath, atime, mtime)`. This is the colour-tag / HDR10 / track-name / language
  path, i.e. the one this feature exists for.
- `electron/parser/mxf.js:1058` — MXF goes through `preserveMtime` too, and MXF header edits
  absorb growth from KLV fill under an assertion that the new buffer length equals the old.

**Verified, not inferred.** The real `SourceFileWatcher` class was extracted and run standalone
against a replica of Flip's write shape (open `r+`, same-size overwrite, restore mtime):
`mtime same: true  size same: true  inode same: true` → `changedOnDisk = false`. The same harness
run against `replaceItemAt` — a write-temp-then-rename atomic replace — reported
`changedOnDisk = true`.

**That kills the atomic-replace hypothesis the previous entry led with.** The watch is path-based
polling, not a descriptor or inode watch; `Fingerprint(of:)` re-stats the PATH every tick. An
atomic replace was always caught. It was never the problem.

### ⚠️ FLIP PRESERVING THE MTIME IS DELIBERATE. DO NOT OPEN A BUG AGAINST IT

A metadata edit is not a content change, and the file's modification date carries information a
facility depends on — when the master was made, not when someone last corrected a colour tag.
Flip restoring it is the correct behaviour for the product it is.

**Flip already documents the consequence, in as many words** — `electron/scan/scan.js:292-297`:

> THE LIMIT OF mtime, stated plainly: Flip's own MOV writers RESTORE the modification time after
> writing (writeMoovBack ends in fs.utimesSync; patch.js wraps every write in preserveMtime), and
> an instant write usually leaves the size unchanged too. So this catches Resolve, Finder, another
> user, another app — **but it CANNOT catch Flip.** A batch runner must therefore invalidate the
> rows it wrote itself, from its own knowledge of what it wrote, rather than trusting a re-stat to
> notice. That is not a gap this module can close.

Flip reached the same conclusion about its own folder-audit staleness check and solved it the same
way this entry proposes: **act on what you know you did, rather than re-statting to find out.**
Two products, the same wall, the same door through it.

### ⚠️ THE SMB FINDING — WHY `ctime` IS NOT THE ESCAPE HATCH, AND WHY NOTHING ELSE IS EITHER

`st_ctime` (inode change time) is the obvious fourth field, and the obvious next thing anyone will
reach for. `utimes(2)` bumps it and it cannot be forged without raw device access, so on a local
APFS volume it does catch a Flip write. It is exposed to us as
`URLResourceKey.attributeModificationDateKey`.

**It does not survive the network — but only on SOME servers, and that is worse than "never".**

MEASURED 2026-08-29 on this machine, across every writable mount, by replicating Flip's exact write
shape (open `r+`, 16-byte same-size overwrite at a fixed offset, `fsync`, then `utimes` restoring
the original mtime) and comparing `stat` before and after:

| mount | server | dialect | mtime | size | inode | **ctime** |
|---|---|---|---|---|---|---|
| local | APFS | — | same | same | same | **MOVED** — detectable |
| `/Volumes/DCCOLOR` | 10.25.2.125 | SMB 3.1.1 | same | same | same | **MOVED** — detectable |
| `/Volumes/Qbit` | 10.25.2.125 | SMB 3.1.1 | same | same | same | **MOVED** — detectable |
| `/Volumes/Photon` | 10.0.1.200 | SMB 3.0.2 | same | same | same | **SAME — INVISIBLE** |

All four shares report `OS_X_SERVER TRUE`, `UNIX_SUPPORT TRUE` and `FILE_IDS_SUPPORTED TRUE`
(`smbutil statshares -a`), so the capability flags do NOT predict the difference — the server
implementation does.

**THE MECHANISM ON THE FAILING MOUNT, since a bare "it doesn't move" invites a retest that proves
nothing:** against 10.0.1.200, smbfs reports **`ctime` as a MIRROR of `mtime`** — the two are
byte-identical before the write and byte-identical after it, across repeated trials. It is not a
separate field that happens to stay put; there is no independent ctime to read. Restoring the mtime
restores the ctime with it, necessarily and every time.

⚠️ **A SECOND, INDEPENDENT HOLE ON THE SAME MOUNT:** timestamps there have **whole-second
granularity** (`1788040016.000000`), not the sub-second precision `SourceFileWatcher`'s design note
relies on APFS for. So on that server even a write that DOES move the mtime is invisible if it
lands in the same second as the baseline — which a metadata edit immediately after a load easily
does. Two different reasons the fingerprint fails there, and fixing either would not fix the other.

*Still visible on that mount:* a **size** change (verified as a control — 4096 → 4128 with the mtime
restored). That is the one field that survives everywhere, and it is why the watcher catches the
subset of Flip edits that change the file's length.

**Why this decided the approach rather than merely complicating it.** The failure is not universal,
and that is precisely the problem: `ctime` would have made the feature work on the machine it was
developed on and fail silently on a customer's NAS, with no error, no log line, and no way for
anyone to tell the two apart from the outside. A hint that is right in the office and wrong on site
is worse than one that does not depend on the server at all.

**THE CONSTRAINT THIS PUTS ON ANYTHING ANYONE TRIES HERE LATER, stated as a general fact rather
than as a fact about Flip:**

> **No metadata fingerprint can see an in-place, same-size write with a restored mtime on network
> storage.** mtime is restored, size is unchanged, the inode is unchanged, and ctime does not move.
> That exhausts what `stat` gives you.

What remains is content hashing, and it is off the table for the reason the watcher already
states: hashing a 40 GB master every two seconds is not a trade anyone wants. So the answer is not
a better fingerprint. **There is no better fingerprint.**

⚠️ Anyone arriving here with *"just add ctime"* has already been answered. Please leave this
paragraph in place rather than re-deriving it against an SMB volume.

### The watcher STAYS, and what it is still for

Nothing above is an argument for deleting `SourceFileWatcher`. It still catches everything Flip's
own note lists — **Resolve, Finder, another user, another app** — plus the Flip edits that *do*
change the file's length (a MOV grow with no adjacent `free` atom to absorb it, which is a real and
common case). Those are writes by things that do not restore the mtime, which is most things.

What it structurally cannot see is a Flip edit, and that is the one case a colourist hits daily.

### The fix, landed 2026-08-29

**The highlight is armed when the user presses Edit in Flip.** Handing a file to Flip is a strong
signal of intent to modify it — nobody opens a file in Flip to LOOK at it, since Manifold already
shows the metadata. It costs nothing, needs no polling or hashing, and behaves identically on local
and network storage, which the fingerprint demonstrably does not.

**SUPPLEMENT, NOT REPLACEMENT.** Two independent reasons for the same highlight, cleared by the
same read: the watcher covers writers that move the mtime — Resolve, Finder, another user, another
app — and the Edit in Flip arm covers the writer that does not. Neither subsumes the other, and
the watcher was not touched except to add the second flag alongside the first.

What landed:

- `SourceFileWatcher.sentForEditing`, a second published flag, plus `isHighlighted` (either
  reason) and `noteSentForEditing()`. **Two flags, not one, because the tooltip has to be able to
  say which reason it is holding** — `changedOnDisk` is observed, `sentForEditing` is inferred from
  a button press, and one sentence cannot serve both without over-claiming on the weak case.
- `rebaseline()` clears both. **Nothing expires.** Send to Flip, never save, and the highlight
  stands until a read clears it — one wasted press, against a timeout that would be a guess about
  how long someone spends in Flip and would fail silently when it guessed short.
- `poll()` still guards on `changedOnDisk` ALONE, so a window lit only by the inferred reason keeps
  taking readings and **upgrades** to the observed one if the write turns out to be visible.
- `ContentView.editInFlip()` arms in the `NSWorkspace.open` completion handler **on `error == nil`
  only** — not at the top of the function, which would also light the button in the Flip-not-
  installed case, the one a new user hits on their very first press.
- One green for both, two tooltips: *"This file changed on disk — click to reload"* wins over
  *"Editing in Flip — reload to pick up any changes"*, because an observation beats an inference.

Builds clean in Debug, Profile and Release.

### ⚠️ THE COMMIT MESSAGE THAT INTRODUCED THIS FEATURE IS WRONG — DO NOT GO LOOKING

`ebb23bf` ("Refresh metadata button highlights when the file changes on disk") ends its subject
line with **"…with alias re-resolution across atomic replaces"**. There is no alias or bookmark
resolution in that commit, in `SourceFileWatcher.swift`, or anywhere this feature touches:
`grep -i 'alias\|bookmark'` over the entire diff hits nothing but an unrelated stream-bookmarks
sheet. The message describes a design that did not ship.

It matters because it points at machinery that would be the obvious place to look for this bug —
and it is not there to find. The atomic-replace case is handled by re-stat'ing the PATH every tick,
which needs no alias resolution at all, and which **was verified working** (see the harness result
above). The commit is published and its message cannot be rewritten, so the correction is recorded
here and in `SourceFileWatcher.swift`'s header, which is where a reader who followed that line
will land.


---

## ⚠️ CAUSE CONFIRMED 2026-09-08 — the clean aperture is applied to the window's SHAPE and never to the PIXELS, so every ARRI open-gate file draws 1.1% narrow

**Status:** ⚠️ **CAUSE CONFIRMED 2026-09-08, by measurement.** **FIX DECIDED** (Option A, below)
**and NOT YET LANDED.** **Found:** 2026-09-07, while chasing black bars that appeared after the
pixel-aspect fix. **NOT a regression from that fix** — the defect is as old as clean-aperture
support; the fix only changed the drawable's shape and made it visible. **Blocks:** nothing
user-facing hard-stops, but every instrument in the app mis-reports on any file with a cropping
`clap`, silently, and has done since before anyone looked.

### The defect

**Every ARRI open-gate file has been drawn about 1.1 percent narrow, and every scope has been
reading 32 columns of black at each end.** The waveform, the parade, the vectorscope, the CIE
plot, the DeckLink v210 output and the ⌃⌥E frame export all read the offscreen ring, and the
offscreen ring is the encoded 2944-wide raster including the codec-alignment padding.

It became visible only when honouring the pixel aspect ratio changed the drawable's aspect. Before
that the window was shaped 4:3 from `naturalSize`, which also applies the clean aperture, so the
same proportional inset was present and read as "the picture" rather than as bars.

### MEASURED, not inferred — the padding is in the FILES

One frame pulled from each fixture at full encoded geometry, with libav's own `clap` crop disabled
(`ffmpeg -apply_cropping 0`), then scanned column by column:

| fixture | encoded | first non-black col | last | active width |
|---|---|---|---|---|
| `A001C025_190913_R1HE.mov` (ProRes 4444, pasp 2:1) | 2944×2160 | **32** | **2911** | **2880** |
| `M001C008_161207_R00H.mov` (ProRes 4444 XQ, pasp 1:1) | 2944×2160 | **32** | **2911** | **2880** |

Columns 0–31 and 2912–2943 are **literal zero** in both files. The active picture is columns
32–2911 — 2880 wide at offset 32, which is the declared clean aperture, centred.

**ARRI's own metadata inside the file agrees:** `com.arri.camera.sensor.PhotoSites: 2880x2160`,
sitting in a 2944 raster. ARRI documents the padding publicly — the Alexa Mini LF writes 4480
around a 4448 active image. **This is not damaged media and not a decode fault. It is alignment
padding, and no instrument should report it.**

#### ⚠️ 32 IS THE PER-SIDE OFFSET, NOT THE ALIGNMENT — and the alignment the two samples support is 128

Easy to conflate, because 32 is the number you measure at the left edge. It is `(2944 − 2880) ÷ 2`,
a consequence of centring, and it is not even constant across the two files: the Mini LF's per-side
offset is 16, not 32.

**The alignment has to be a width the ACTIVE image violates and the PADDED width satisfies**, or
there would be nothing to pad. That rules out 32 and 64:

| width | ÷32 | ÷64 | ÷128 |
|---|---|---|---|
| 2880 active (open gate) | 90 ✓ | 45 ✓ | 22.5 ✗ |
| **2944 padded** | 92 ✓ | 46 ✓ | **23 ✓** |
| 4448 active (Mini LF) | 139 ✓ | 69.5 ✗ | 34.75 ✗ |
| **4480 padded** | 140 ✓ | 70 ✓ | **35 ✓** |

Both active widths are already multiples of 32, so 32-alignment would require padding neither. And
2880 is `64 × 45`, so 64-alignment would not require padding the open-gate file either. **128 is
the smallest alignment that both files support** — it is the only one of the three that both active
widths violate and both padded widths satisfy.

**Stated as inference, not as documentation.** 128 is what two samples support; it is not a figure
read out of an ARRI specification, and two points do not establish a rule. A third fixture could
rule it out.

**Nothing about the fix depends on any of this.** The `clap` atom declares WHERE the picture is,
and the crop follows that declaration regardless of WHY the padding exists. The alignment question
is provenance for the entry, not an input to the code.

### The mechanism — one application, to the wrong quantity, not two

**The clean aperture is applied exactly once, to the display SHAPE, and never to the pixels.**

- `MediaInspector.presentationSize` calls `CMVideoFormatDescriptionGetPresentationDimensions(fmt,
  usePixelAspectRatio: true, useCleanAperture: true)`. That value becomes `FrameEngine.displaySize`,
  which shapes the video rect (`ContentView.videoAspect`) and the window (`WindowSizer.setGeometry`),
  and through the view's bounds it shapes the drawable.
- The pixel path never crops. The offscreen is sized from `CVPixelBufferGetWidth/Height` — the
  encoded 2944 — and `displayCopyVertex` stretches uv 0…1 across all of it onto the drawable.
  There is no `setViewport` or `setScissorRect` anywhere in the project, and nothing reads
  `kCVImageBufferCleanApertureKey`.

**Both earlier readings of this were right and neither contradicted the other.** Applying a
clean-aperture SHAPE to a full stretch of ENCODED pixels is arithmetically identical to scaling the
picture by clap ÷ encoded. That is why one audit called it a full-viewport stretch with no aspect
preservation and another called it a horizontal scale. Same fact, two ends.

### The arithmetic, which is what identified it

| quantity | predicted | measured on screen |
|---|---|---|
| black per side, in a 2880-wide drawable | 2880 × 32 ÷ 2944 = **31.3 px** | 31–32 px |
| picture width | 2880 × 2880 ÷ 2944 = **2817 px** | ~2812 px |

**That measurement is what found this.** Every value in the display path reported correct — host
view bounds, layer bounds, drawable size, contents gravity, pipeline present, all consistent at
2880×1080 — and four successive hypotheses (a layout inset above the video region, stale layer
bounds from a re-parented host view, a `contentsGravity` of `resizeAspect`, and the scope tray's
chrome height) were **all wrong.** The ratio in the black bars was the only thing that pointed
anywhere, and it pointed at `clap ÷ encoded` exactly.

### ✅ DECISION 2026-09-08: crop everywhere, at the offscreen (Option A)

The padding is codec alignment and no instrument should report it, so the crop belongs upstream of
every consumer rather than on the display alone.

- **Option A (CHOSEN).** `ensureOffscreenTexture` allocates the ACTIVE picture — 2880 wide — and
  the offscreen pass samples the cropped uv range. One crop. The display copy needs **no change**
  (its uv stays 0…1), and the four scope kernels, the v210 convert and the export inherit it for
  free, because every one of them already derives its geometry from `src.width`/`src.height`.
- **Option B (rejected).** The offscreen stays the literal decoded 2944 buffer and seven consumers
  each apply the crop themselves.

**The argument is the DEFAULT, not the edit count.** After A, a consumer added later is correct for
free. After B, it reads the padding unless its author knows better — which is exactly the failure
that produced this defect. B also acquires an unenforceable second rule ("every consumer must
exclude the padding") with no compiler behind it.

A costs, in exchange: one real bug fix (below), one rewritten check, one rewritten rule, and a new
per-source aperture hand-off into the renderer — which today never sees a format description, so
the aperture must be parked main→render the way `pendingColorState` already is.

### ✅ DECISION 2026-09-08: the frame export stays at NATIVE pixels; the aspect travels as metadata

A consequence of A, decided with it: after A the ⌃⌥E export is the OFFSCREEN's geometry — the
active picture at **encoded pixel dimensions** (2880×2160 on both ARRI fixtures) — and it is
**NOT desqueezed**, even on a 2:1 anamorphic file whose display size is 5760×2160.

**The argument is consistency, and it is the same one that sizes the offscreen.** The offscreen is
source pixels, the scopes read source pixels, SDI carries source pixels, and the desqueeze is a
DISPLAY transform that stops at the drawable (`displayCopyFragment`). An export that baked in a
display decision would be the one thing in the pipeline that did. It is also what a frame export is
FOR — dropping into Resolve or Flip, comparing against the file, reading a value off a pixel — and
every one of those reads the metadata itself.

**But an anamorphic export looks wrong in a dumb viewer**, so the ratio travels with the file two
ways, and the two are gated DIFFERENTLY on purpose:

| | written when | states |
|---|---|---|
| PNG `pHYs` chunk | `pasp` **declared**, including 1:1 | the exact ratio |
| `_par2-1` in the filename | declared **AND not square** | "this needs a desqueeze" |

**Three-state honesty applies to the chunk.** `.undeclared` writes **NO CHUNK AT ALL** — omission is
the carry-through of "the file said nothing". A declared 1:1 **does** write one. A viewer treats a
chunk-less PNG as square either way, so the rendered result is identical; the STATEMENT is not, and
inventing a declaration the source never made is what `DeclaredPixelAspect`'s third state exists to
prevent.

The filename tag is gated on *anamorphic* rather than *declared* because it answers one question
("does this need desqueezing?"), not the three-state one. Always-on would put `_par1-1` on every
ordinary export — noise on the common case, and it would make the marker's presence mean nothing.
Only-when-anamorphic makes its presence informative. It earns its place beside `pHYs` because a
filename survives being copied, emailed and dropped into a folder of stills, which `pHYs` does not,
and because a human can read it when a viewer silently ignores the chunk.

#### ⚠️ MEASURED, BECAUSE THE OBVIOUS ImageIO KEYS SILENTLY DO NOTHING

- **`kCGImagePropertyPNGXPixelsPerMeter` / `…YPixelsPerMeter` are IGNORED ON WRITE.** They produce
  **no `pHYs` chunk at all** — verified by writing a file and walking its chunk list. No error, no
  warning, just no chunk.
- **The top-level `kCGImagePropertyDPIWidth` / `DPIHeight` DO write one**, unit=1 (metre).
- **ImageIO converts DPI → px/m as `round(dpi / 0.0254)`**, so the naive 72/144 dpi pair for a 2:1
  squeeze lands on **2835/5669** and states a ratio of **1.99965, not 2**.

So the code picks the INTEGER px/m pair first and expresses it back as DPI (`ppm × 0.0254`), which
round-trips exactly. `pHYs` is pixels PER METRE, so the axis with the WIDER pixels has the LOWER
density: `yPPM / xPPM == h / v`. A scale factor anchors the larger density at 72 dpi so the nominal
figure stays in a sane print range; the ratio is exact for any factor.

**Verified against the shipped `DeclaredPixelAspect`, on the real 16-bit/709 image shape:**

| declared | filename | `pHYs` |
|---|---|---|
| undeclared | `Manifold_frame_….png` | **omitted** |
| 1:1 | `Manifold_frame_….png` | x=2835 y=2835 → 1.0 exact |
| 2:1 | `…_par2-1.png` | x=1417 y=2834 → 2.0 exact |
| 4:2 | `…_par2-1.png` | x=1417 y=2834 → 2.0 exact (reduced — same declaration, same name) |
| 3:2 | `…_par3-2.png` | x=1890 y=2835 → 1.5 exact |
| 40:33 | `…_par40-33.png` | x=2310 y=2800 → 1.212121… exact |

**The renderer had no `pasp` and needed the same hand-off the `clap` got.** `MetalVideoRenderer`
held the CICP codes and (after A) the aperture, but the pixel aspect lived only in
`VideoMetadata.pixelAspect` — the inspection task's product, which reaches `InspectorPanel` and the
window shape and never the renderer. Rather than add a third per-source channel, A's hand-off was
widened: `onSourceCleanAperture` → **`onSourceGeometry`**, carrying encoded size + `clap` + `pasp`,
read off the same format description in the same main-actor turn. `SourceAperture` →
**`SourceGeometry`**, whose doc states the split that matters: **the crop IS applied to pixels, the
pixel aspect NEVER is.**

### ⚠️ THE OFFSCREEN RULE IS NARROWED, NOT VIOLATED, AND THE DISTINCTION MATTERS

The rule on `ensureOffscreenTexture` says the offscreen stays at SOURCE resolution because the
scopes, the v210 convert and the frame export all read it and all mean source pixels — *"a waveform
that changed when the window was resized would be a measurement bug. The window's size reaches the
drawable and stops there."*

**The quantity that rule forbids the offscreen from depending on is the LAYOUT.** The active
picture is a per-source constant: it does not move with the window, the tray, the display, or the
raster percentage. Resize the window and the waveform is byte-identical. The invariant the rule
exists to protect is untouched.

What A changes is the REFERENT of "source resolution" — from the encoded raster to the active
picture. That makes the rule's own stated rationale **truer than it is today**, because 32 columns
of alignment padding were never source pixels in the sense that sentence intends.

**What the rule should say afterwards:** the offscreen is sized from the SOURCE and never from the
layout — specifically from the source's ACTIVE PICTURE, the encoded raster with the declared clean
aperture removed, which is a per-source constant. Plus the new prohibition the current text does
not cover and which the blit fallback is currently violating:

> **Nothing may assume `offscreen.width == CVPixelBufferGetWidth(buffer)`.**

### Two traps, with file and line, so tomorrow does not rediscover them

**1. The blit fallback reads past the end of the texture.**
`App/MetalVideoRenderer.swift:2086-2092` copies FROM the offscreen using the PIXEL BUFFER's extent:

```swift
} else if let blit = cmdBuffer.makeBlitCommandEncoder() {
    blit.copy(from: offscreen, ...
              sourceSize: MTLSize(width: width, height: height, depth: 1),   // 2944
```

With a 2880-wide offscreen that is a read 64 px past the end. **It fires only when
`displayCopyPipelineState == nil`, which essentially never happens — so it would ship untested and
fail on somebody else's machine.** It must move to the texture's own dimensions in the same change.
`App/MetalVideoRenderer.swift:2010` has the same shape in the pre-layout drawable fallback: harmless
(the next layout pass supersedes it) but it would be stating something false.

**2. A non-integral clap offset is undecided policy.**
A `clap` offset is a rational and need not be integral, and the decode is 4:2:0, so an odd offset
cannot be honoured exactly on the chroma plane. **32 is even and integral, so on these files the
crop stays bit-exact 1:1** — texel centres still align and the offscreen pass introduces no
resample. The policy for a non-integral offset — round and record, or decline to crop — does not
exist yet, and A is what forces the decision.

### Two consequences to VERIFY rather than assume

**`[SCRUB-GEOM]` would fire a false warning on every clap file, every drag.**
`App/MetalVideoRenderer.swift:507-535` compares the producer's buffer against the offscreen, and its
own doc comment states the premise A retires: *"the offscreen is sized from the playback buffer, so
it IS the encoded raster."* Producer 2944×2160 against a 2880×2160 offscreen gives `Δ -32 px/side`
and a message accusing the scrub path of precisely the crop the renderer now performs deliberately.
It should compare against a STORED encoded size instead — which makes it assert two things (the
producer handed over encoded geometry, AND the offscreen is that minus twice the padding) where it
asserts one today.

**The DeckLink native-res guard changes its left-hand side for every cropping-clap file.**
`App/MetalVideoRenderer.swift:2655-2656` tests `src.width != outSize.w || src.height != outSize.h`,
where `outSize` is only ever 3840×2160 or 1920×1080.

- **No effect on ARRI open gate.** Refused at 2944 against a 3840 mode; still refused at 2880. The
  mode itself does not move either — `sourceFormatChanged` is fed `meta.width/height`
  (`ContentView.swift:772`), which are the ENCODED dimensions and are not what A changes.
- **But a file whose clean aperture is exactly 1920×1080 inside a padded 1088 coded raster flips
  from refused to passing.** That flip is CORRECT — the guard is currently refusing such a file on
  padding alone — but it is a behaviour change on the SDI path and **wants a fixture.**
- Trap specific to B, recorded in case A is ever reconsidered: crop in the v210 kernel while the
  guard still tests `src.width` and the guard is judging the wrong number.

### ✅ THE TEMPORARY DIAGNOSTICS ARE OUT, 2026-09-08 — they were the instruments, and they served their purpose

**Removed after the fix landed, not with it.** They were the instruments that produced every number
in this entry, and they were deliberately kept through the implementation so the fix could be
verified against them. `[GEOM-DIAG]`, `[WINPROBE]` and `geomDiagSeen` now return **no hits in
`App/` or `Packages/`.**

| tag | file | what came out |
|---|---|---|
| `[GEOM-DIAG]` | `App/MetalSurfaceView.swift` | the comment block, the static `geomDiagSeen`, and the print at the top of `layout()`. **The `layout()` override itself STAYS** — it sizes the metal layer and reports the drawable size, which is real work. |
| `[GEOM-DIAG]` | `App/SampleBufferSurfaceView.swift` | the **entire `layout()` override**, which this class never had and which existed only to print, plus its static set. |
| `[GEOM-DIAG]` | `App/MetalVideoRenderer.swift` | the `geomDiagSeen` property and the layer-state block in `performDisplayTick` — with it, the render-thread reads of `contentsGravity` / `bounds` / `contentsScale` that were the diagnostic liberty this file's threading rule forbids. |
| `[WINPROBE]` | `App/PlayerWindow.swift` | the whole `WindowLayoutProbe` enum, its call in `updateNSView`, and the **four stored properties** on `WindowConfigurator` (`trayVisible`, `trayHeight`, `barDocked`, `barHeight`) that nothing sized from. |
| `[WINPROBE]` | `App/ContentView.swift` | the four matching arguments at the `WindowConfigurator` call site. The four *terms* stay — they still feed `chromeHeight`; only the probe-only arguments went. |
| `[WINPROBE]` | `App/DiagnosticsExport.swift` | the tag registration in `LogPartitioner.manifoldTags`. |

**EXPERIMENT 3 came out in the same sweep**, per its own `DELETE WHOLESALE` banner: the
`DebugDestination` enum, `debugDestination` and its `/tmp/manifold_debug_cs` seed,
`sourceDerivedColorSpace`, `cycleDebugDestination()`, `logCSDebug`, the synthesised g2.4 ICC
(`synthesisedGamma24ColorSpace`), `resolvedDestinationColorSpace(_:)`, and the ⌃⌥D keystroke in
`ContentView`. `setSourceColorSpace` now hands the source-derived space to the layer directly
(`PendingColorState(colorSpace: cs, …)`) with no override interposed.

- The block's own removal note cited "the `applyLayerColorSpace()` call sites in
  `setSourceColorSpace`". **That function no longer exists** — it had already gone when the colour
  state moved to the main→render parking pattern. The note was stale; nothing was missed.
- `[CSDEBUG]` was emitted only from inside that block, so its tag registration came out too. The
  tag list audits clean against its own documented regeneration grep: nothing emitted-but-unlisted,
  and the only listed-but-unemitted entries are the composed-tag exceptions the file already
  documents.
- ⚠️ **`docs/color-fixtures/sweep.sh` IS NOW DEAD** and was deliberately left in place — it is the
  harness that ran the experiment and it records how the captures were taken. It greps `[CSDEBUG]`
  and already self-reports `⚠️ NO [CSDEBUG] STRINGS IN THIS BINARY` rather than producing a
  misleading result, so it fails loudly. Delete it whenever E3's captures stop mattering.

**⚠️ `[CSPROBE]` WAS NOT TOUCHED, AND THE DISTINCTION IS EASY TO GET WRONG.** The `[CSPROBE]`
colourspace dump (`dumpColorSpaceDiagnostic`) carries its own "TEMPORARY DIAGNOSTIC — DELETE
WHOLESALE" banner and **predates this arc entirely** — a grep for that phrase hits it. It is not
part of this work and was left exactly as it was, tag registration included.

**`[CLAP]` and `[EXPORT]` are PERMANENT**, not diagnostics, and stay registered in
`LogPartitioner.manifoldTags`. `[CLAP]` is the only place outside the inspector where an inexact
crop becomes visible; `[EXPORT]` states what actually went into the written PNG.

### Shipped alongside, and unrelated to the defect above

**The pixel aspect ratio is now honoured on the AVFoundation path**, and the inspector reports
**resolution, clean aperture, pixel aspect and display size as four separate declarations** rather
than one conflated number. `naturalSize` applies the clean aperture and NOT the pixel aspect, so an
anamorphic file and a square-pixel one were indistinguishable downstream and both drew at 4:3.

**A declared 1:1 is distinguished from no `pasp` atom at all** — the three-state
`DeclaredPixelAspect`. **Proved, not assumed:** a file was authored with the atom renamed to `free`
and the format-description extension confirmed to read ABSENT rather than defaulting to 1:1.

### ⏸ OPEN CONVENTION QUESTION, undecided: 5760×2160 or 2880×1080?

`GetPresentationDimensions` returns **5760×2160** for a 2:1 anamorphic file — it expands the width.
Screen presents the same file as **2880×1080** — it halves the height. Same aspect, different
raster.

- **5760×2160** preserves every stored sample, and implies a width the file does not have.
- **2880×1080** keeps the number inside the source's own pixel count, and makes the raster
  percentages reachable on a 3840-wide display.

**No AVFoundation call returns the second form**, so adopting it would be a deliberate
reinterpretation rather than a bug fix. Left open on purpose.

---

## ⚠️ CAUSE CONFIRMED 2026-09-08 — VideoToolbox plug-in codecs and MediaToolbox plug-in format readers are OPT-IN PER PROCESS, and Manifold never opts in. "AVFoundation cannot open MXF" is false.

**Status:** ⚠️ **CAUSE CONFIRMED 2026-09-08, by measurement, from a plain unsigned CLI.**
**NOTHING DECIDED AND NOTHING BUILT.** **Found:** 2026-09-08, while investigating why
`Mixed Captions.mxf` (DNxHR 444 12-bit) renders green and magenta. **Blocks:** nothing today,
because nothing depends on it yet. **Invalidates:** the premise under the entire libav/MXF path —
see the site list below, and re-read those comments before trusting them.

### The finding

Two **public** functions, present since macOS 10.9 and 10.10 respectively:

```
VTRegisterProfessionalVideoWorkflowVideoDecoders()    VideoToolbox/VTProfessionalVideoWorkflow.h
MTRegisterProfessionalVideoWorkflowFormatReaders()    MediaToolbox/MTProfessionalVideoWorkflow.h
```

Plug-in codecs and plug-in container readers are **not available to a process until it asks for
them**. ProRes, H.264 and HEVC are built into VideoToolbox and need no opt-in, which is why every
control in this investigation passed while every DNxHR test failed — the difference was never the
file, the container, the signature or the API.

**Manifold calls neither.** No source reference in `App/` or `Packages/`, and the shipped
`Manifold.app` binary imports neither symbol. **Both working clients import both**
(`nm -u`): Screen (`co.videovillage.Screen`) imports the decoder, encoder and format-reader
registrations; QuickTime Player imports the decoder and format-reader registrations.

### MEASURED — plain unsigned CLI, no notarization, no bundle, no entitlement

| what | before registration | after registration |
|---|---|---|
| `VTDecompressionSessionCreate` for `'AVdh'` | **−12906** (`kVTCouldNotFindVideoDecoderErr`) | **0** — decoder found |
| `AVURLAsset.load(.tracks)` on `Mixed Captions.mxf` | **−11828** "Cannot Open" | **3 tracks, 30.03 s** — `vide 'AVdh'`, `soun 'lpcm'`, `tmcd` |

With both registered, `AVAssetReader` requesting `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`
— **the same `x420` the pipeline already asks for** — decoded all three:

| fixture | codec | result |
|---|---|---|
| `Mixed Captions.mxf` | DNxHR **444 12-bit**, `ACT=1` | 3840×2160 `x420`, **natural colour** |
| `OP1A Test.mxf` | DNxHR HQX 422 10-bit | 3840×2160 `x420`, correct |
| `DNX As MOV 10bit.mov` | DNxHR HQX 422 10-bit | 3840×2160 `x420`, correct |

**The 444 frame renders in natural colour where libav renders green and magenta.** The Avid
decoder handles the variable ACT flag that libav's `dnxhd` refuses (`Unsupported: variable ACT
flag.`, identical output across FFmpeg 5.2 → 8.1.1 → trunk 2025-07, byte-for-byte). **So this is a
correctness fix, not a performance one**, and it covers both profiles.

### ⚠️ WHAT THIS INVALIDATES — every one of these carries a premise that was never tested

"AVFoundation cannot open MXF" is **not a property of AVFoundation**. It is a property of not
having made one call. It is the stated justification at all of these sites, and each needs
re-reading rather than trusting:

| site | what it asserts |
|---|---|
| [`FrameEngine.swift:1516`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1516) | `loadMXF` — "AVFoundation has no MXF demuxer, so it can't open the file at all" |
| [`FrameEngine.swift:1374`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1374) | the `isMXF` branch that routes straight to libav, bypassing `MediaInspector` |
| [`FrameEngine.swift:1540`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1540) | `applyLibavMetadata` — exists because AVFoundation "supplies nothing" |
| [`FrameEngine.swift:1630`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1630) | `applyLibavAudioTrack` and its `videoTrack == nil` guard |
| [`FrameEngine.swift:1673`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1673) | `applyLibavTextTracks` — same guard, same reasoning, written 2026-09-08 |
| [`FrameEngine.swift:200`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L200), [`:217`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L217), [`:276`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L276), [`:441`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L441) | the `audioPresence` / `audioTracks` / `selectedAudioTrackIndex` notes |
| [`FrameEngine.swift:1309`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1309), [`:1529`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1529), [`:1813`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1813) | "there is nothing to ask it" / "blind to MXF for scrub" / "blind to the container" |
| [`MediaInspector.swift:214`](../Packages/ManifoldCore/Sources/ManifoldCore/MediaInspector.swift#L214) | `requiresLibavDecode` — routes `AVdh AVdn dnxh dnxd` away from VideoToolbox unconditionally |
| [`ScrubFrameProducer.swift:28`](../Packages/ManifoldCore/Sources/ManifoldCore/ScrubFrameProducer.swift#L28), [`LibavScrubProducer.swift:8`](../Packages/ManifoldCore/Sources/ManifoldCore/LibavScrubProducer.swift#L8) | the scrub seam's whole reason for a libav half |
| [`LibavFrameSource.swift:48`](../Packages/ManifoldCore/Sources/ManifoldCore/LibavFrameSource.swift#L48) | `StreamInfo`'s container-sourced facts "when AVFoundation can't open the file" |
| [`CaptionPresence.swift:334`](../Packages/ManifoldCore/Sources/ManifoldCore/CaptionPresence.swift#L334) | `CaptionPresenceReader` — "containers AVFoundation cannot open" |
| [`ContentView.swift:2016`](../App/ContentView.swift#L2016) | the audio-track-count face label |

⚠️ **`requiresLibavDecode` is the sharper one.** `DNXDecoder.bundle` declares exactly `AVdh` and
`AVdn`; the set also lists `dnxh` and `dnxd`, which **no installed plug-in declares at all**. So
two of the four fourCCs are routed away from a decoder that exists and two from one that does not.

### ⚠️ THE FALSE TRAILS — do not re-run these, all were the wrong variable

Recorded because each cost real time and each looked convincing:

- **Notarization.** Hypothesised as the gate. A probe signed Developer ID + hardened runtime +
  Apple secure timestamp, **submitted to Apple's notary service (Accepted), stapled, verified
  `source=Notarized Developer ID`**, failed identically — `−12906`, run both directly and via
  LaunchServices. Also failed on `v210`, which is not DNxHR at all.
- **File provenance.** Hypothesised that VideoToolbox only accepts format descriptions from
  Apple's own demuxers. A **Resolve-authored** `.mov` (`FormatName = Avid DNxHR HQX 10-bit`,
  proper `ACLR` + `ADHR` atoms) failed exactly like an ffmpeg-remuxed one.
- **The format description.** Varied across empty extensions, the real container's, `Vendor=AVID`,
  `FormatName='Avid DNxHR'`, and an injected `AvidDNxHRDescriptionExtension` carrying the ADHR
  atom. No change.
- **Signing.** Unsigned, ad-hoc, Developer ID, Developer ID + hardened runtime. No change.
- **Process shape.** Bare binary, `.app` bundle, real `NSApplication` with a visible window and an
  `AVPlayerLayer`, shell launch and LaunchServices launch. No change.
- **API surface.** `AVAssetReader`, `AVPlayerItemVideoOutput`, hand-built `VTDecompressionSession`;
  six pixel formats; four decoder specifications. No change.
- **`VTCopyVideoDecoderList` as evidence.** It does **not** enumerate plug-in codecs — AVC-Intra,
  DVCPRO HD, IMX and Uncompressed are all equally absent from it despite being installed. Any
  reasoning built on that list is void.

⚠️ **THE METHOD THAT WORKED, AND IT WAS ASKED FOR REPEATEDLY BEFORE IT WAS DONE:** read what the
working clients import. `nm -u` on Screen and QuickTime Player named both functions in one step.
Every attempt to capture a working client's call by attaching was blocked by hardened runtime
(`flags=0x10000`, no `get-task-allow`) — but the **import table needed no attach at all**.

### What Pro Video Formats installs, and what Manifold cannot open today

`com.apple.pkg.ProVideoFormats`, in `/Library/Video/Professional Video Workflow Plug-Ins/`.
Eleven bundles — ten codecs plus `AppleMXFImport`, which is a **container reader**
(`com.apple.mediatoolbox.pluginformatreader`), not a codec. fourCCs read from each bundle's own
`CMMatchingInfo → VTCodecType`:

| bundle | decodes |
|---|---|
| `DNXDecoder` (Avid Technology) | `AVdh` `AVdn` — DNxHR / DNxHD |
| `AppleAVCIntraCodec` | `ai12…ai5q` (AVC-Intra 50/100/200), `ai42` `ai44`, `aivx` (XAVC Intra), `Xfi8` `Xfia` `xf4a` `xf4c` (XF-AVC Intra) |
| `AppleAVCLGCodec` | `avlg` `xalg` `Avc1` `xfg8` `xfga` `xfi8` `xfia` `ailt` |
| `AppleDVCPROHDCodec` | `dvhp dvhq dvh6 dvh5 dvh3 dvh2` |
| `AppleHEVCProCodec` | `he22` — HEVC 10-bit 4:2:2 |
| `AppleIMXCodec` | `mx3n mx4n mx5n mx3p mx4p mx5p` — MPEG IMX |
| `AppleIntermediateCodec` | `icod` |
| `AppleProResRAWCodec` | `aprh aprn` |
| `AppleUncompressedCodec` | `2vuy v210 R10k` |
| `AppleMXFImport` | *(format reader — MXF)* |

⚠️ **Manifold can open none of these today except DNxHR/DNxHD, and that one only through libav.**
The vendored FFmpeg is built `--disable-everything` with decoders `dnxhd, prores, pcm_*, aac` only,
so nothing else on that list has a libav decoder either — and without the registration call the
AVFoundation path cannot reach them regardless of container. **Measured for `v210`:**
`VTDecompressionSessionCreate` returns `−12906` before registration. The rest is the same
mechanism, not separately measured.

### ⚠️ TWO CONSTRAINTS, NOT FOOTNOTES

**1. It is a deliberate declaration, not a free upgrade.** The header says a caller "indicates to
VideoToolbox that it wishes to support Media Extension video decoders" and explicitly warns it "is
not recommended for network-facing applications such as web browsers, messaging clients, mail
clients". Manifold is a QC tool and is squarely the intended audience — but it also carries NDI,
WHEP, SRT and HLS transports, so the network-facing caveat deserves a decision rather than an
assumption.

**2. It depends on Pro Video Formats being installed**, which is a user-installable Apple package
Manifold does not ship and cannot assume. **libav must remain the fallback**, and any design has
**two paths for MXF from the outset** — not one path with a rescue. The ACT defect is unfixable on
the libav path on a machine without the package, so a file can be correct on one machine and green
and magenta on another with the same build.

### Nothing is decided

This entry records what was measured and what it invalidates. It does not propose a route, a
staging, or a change to `requiresLibavDecode`. The working probes are in the session scratchpad
(`reg.swift`, `mtreg.swift`, `final.swift`) and are three files of about forty lines each if they
need re-running.

---

## ⚠️ CAUSE CONFIRMED 2026-09-09 — `LicenseManager.bootstrap` blocks the main actor for the whole of launch, and the trial gate's opening frame accuses a valid trial of being expired

**Status:** ⚠️ **CAUSE CONFIRMED 2026-09-09, from the code, against one observed stall.**
**NOTHING DECIDED AND NOTHING BUILT.** **Found:** 2026-08/09, during the Open Recent work, as
"the app came up with no window at all". **Blocks:** nothing today. **Invalidates:** the
attribution recorded at the time — that this was the unsigned build's `SecurityAgent` prompt. That
is true of the **trigger** and false of the **shape**, and the shape ships.

### What was observed, and what was derived — kept apart

**OBSERVED**, once, on a `.build-cc` unsigned build: the app launched with no window, and `sample`
on the stalled process showed the main thread parked in
`ManifoldApp.body → LicenseManager.bootstrap → KeychainStore.read → SecItemCopyMatching`.

**DERIVED FROM THE CODE 2026-09-09**, everything below. The call counts, the isolation, the
ordering and the gate's opening frame are read off the source and are checkable by inspection.
**The signed-build stall conditions in the last section are predicted from the mechanism and have
NOT been reproduced** — they are named so the shape is recognisable, not asserted as measured.

### The isolation, which is the part that makes it straight-line blocking

`KeychainStore.read` — `App/KeychainStore.swift:196` — is not `async`, has no completion handler
and no queue. `SecItemCopyMatching` is a synchronous C entry point that does a cross-process round
trip to `securityd` and blocks the calling thread until it answers.

`KeychainStore` is a plain `struct` with no isolation annotation, in a file with none, so `read` is
**nonisolated**. ⚠️ **That is not an escape hatch.** `nonisolated` changes where *async* functions
run; a nonisolated *synchronous* function called from an actor-isolated context is an ordinary
function call executed inline on that actor's thread. Nothing hops off.

`bootstrap()` is `async`, which is misleading. `App/LicenseManager.swift:453` declares
`@MainActor final class LicenseManager`, so `bootstrap` is main-actor-isolated. `.task` at
`App/ManifoldApp.swift:50` takes a `@Sendable` nonisolated closure (`SWIFT_VERSION: "5.0"`,
`project.yml:280`), so the task body starts off-main, hops **onto** the main actor at
`await license.bootstrap()`, and does not leave it again until the first suspension point that
executes.

⚠️ **ON THE TRIAL PATH THERE IS NO SUCH POINT.** `bootstrap` spans `LicenseManager.swift:540-624`
and contains exactly **one** `await` — `await refreshValidation()` at `:608` — inside the
`if let key = keyRead.value, case .success` branch, which returns at `:609`. A user with no stored
key never reaches it: step 1 reads `.absent` at `:550`, step 2 evaluates the trial at `:571`, step
3's condition fails, step 4 runs, the function ends at `:623`. **From entry to return it is
straight-line blocking main-thread work.**

### Four to eight synchronous `securityd` round trips, before anything can paint

| path | blocking `SecItem*` calls before the first `await` that executes |
|---|---|
| **trial / unlicensed** | **5** — `read(storedLicenseKey)` `:550`; then `TrialManager.recordLaunchAndEvaluate` `:571` reads `trial.firstLaunch`, `trial.voided`, `trial.lastSeen` and **writes** `trial.lastSeen`. Never suspends. |
| **first-ever launch** | **4** — `read(firstLaunch)`, then two `set` calls, each a `SecItemUpdate` → `SecItemAdd` pair. |
| **licensed** | **6–8** — the four above, plus `readActivationRecord` `:628`, optionally the record write + read-back (`:683`, `:691`), then `refreshValidation` at `:771` does **a fifth read of `storedLicenseKey`** — the item already read at `:550` — before `await LicenseService.validate` finally yields. |

The `#if DEBUG` `LicenseCrypto.runRoundTripSelfCheck()` at `:541` runs ahead of all of it, on the
main thread, in **every Profile build** — which per `CLAUDE.md` is every build cut to date. Cheap,
but first in the queue.

### Why "no window", not "a blank window"

`.task` runs after the view-graph update, but "the view appeared" in SwiftUI's sense is not "the
window is flushed to screen". `NSWindow` creation, `orderFront`, and the run-loop turns that
actually paint the first frame are all main-thread work. Once the task body is on the main actor
and never suspends, **the main run loop does not turn again until `bootstrap` returns.** The window
is gated on the thread, not on any licensing state. The second `.task` —
`UpdateChecker.checkAtLaunch()`, `ManifoldApp.swift:55` — is main-actor too and cannot start.

### ⚠️ A SECOND, SEPARATE DEFECT: the gate's opening frame accuses a valid trial

**This is not the blocking bug and would SURVIVE a fix that only made the keychain call async.**
Record it as its own thing.

`.licenseGate(license)` at `ManifoldApp.swift:49` reads `isUsable`:

```swift
var isUsable: Bool {
    (licenseActivated && licenseValidated) || trial.active || keychainFaultStatus != nil
}
```

At first render `trial` is still its **initializer value** — `LicenseManager.swift:475`,
`TrialStatus(active: false, daysRemaining: 0, expired: true)` — and `keychainFaultStatus` is nil.
So for anyone whose plist does not already say activated **and** validated, all three clauses are
false and **the first composed frame is `LicenseGateView`: "Your Manifold trial has ended."** It
stays that way until `bootstrap` assigns `trial` at `:571`.

On a fast keychain nobody ever sees it, because it is the same run-loop turn. **On a slow one it
tells a user in a perfectly valid trial that their trial is over — and does it while the app is
unresponsive, so they cannot dismiss it, activate, or quit cleanly.** The false accusation and the
hang arrive together and reinforce each other: the app looks like it has gated them and died.

Note the irony to preserve when this is fixed: `LicenseGateView` already carries a careful
`userFacingKeychainFault` branch so that a *refused* read never reads as an accusation. None of
that helps here, because at this instant the read has not been refused — it has not been **made**.

### ⚠️ THE UNSIGNED PROMPT IS THE CHEAPEST REPRODUCTION, NOT A SEPARATE PROBLEM

The trigger is understood and is genuinely build-specific: on a `.build-cc` unsigned build the
item's ACL does not list the calling binary, so `securityd` suspends the call and asks
`SecurityAgent`, and the call blocks for as long as the dialog is up. Launching from Xcode, which
signs with a stable development identity, never triggers it. Signing with the team certificate
makes the partition list match — `teamid:8UQ7MDM87B`, documented at `KeychainStore.swift:136`.

**That removes exactly one trigger. It does not make the call asynchronous, bounded or
cancellable.** The latency of `SecItemCopyMatching` is `securityd`'s latency, and that is not
something the app controls. Signed-build conditions that produce the same stall:

- **A locked login keychain — the one most likely to reach a customer.** The write path sets
  `kSecAttrAccessibleAfterFirstUnlock` (`KeychainStore.swift:173`), but that is an iOS
  data-protection attribute; a generic-password item in `login.keychain-db` on macOS is governed by
  the keychain's own lock state. The login keychain desynchronises from the login password after a
  **password change, an MDM-driven reset, or a FileVault/admin recovery** — ordinary support
  scenarios — and it locks on schedule with lock-after-inactivity or lock-on-sleep enabled. In
  every one of those states the call raises an unlock dialog and blocks until it is answered. Same
  stall, different dialog, signed build.
- **First keychain access after login.** Unlocking `login.keychain-db` for the session is a real
  credential operation — tens to hundreds of milliseconds under contention. Launch is exactly when
  it is cold, and Manifold does four to eight of these back to back.
- **Network home directory.** `login.keychain-db` lives in `~/Library/Keychains/`. On an AD/OD
  mobile account or a home redirected over SMB/NFS, that file is on the network and `securityd`
  reads it through the file system. Keychain latency inherits network latency; a hung mount blocks
  without bound. Enterprise and education facilities are exactly the population with this setup.
- **Login-time system load.** `securityd` is one process per session and serialises. Spotlight,
  Time Machine, MDM agents and every other launch agent hitting it at once is the normal condition
  at login, which is the normal time to launch an app.
- **iCloud Keychain.** These items are not `kSecAttrSynchronizable` and do not sync, but enabling,
  repairing, or joining the circle puts `securityd` into work that delays unrelated requests to the
  same daemon. Lower probability; not zero.
- **A damaged or oversized `login.keychain-db`**, and the repair path macOS runs against one.

### ⚠️ WHAT THE THREE-WAY `KeychainRead` DESIGN CANNOT COVER

`KeychainStore.swift` is careful and correct about a **refused** read: three cases, fail open, hold
everything, explain it to the user. **All of that reasoning pays off only after the call returns.**
There is no equivalent for a **slow** read, and there cannot be, because a synchronous call has no
way to express "has not answered yet". From the main thread, refused and not-yet-answered are
indistinguishable: one returns an `OSStatus`, the other simply never returns.

The severity is entirely in the tail. The median signed launch on a healthy local keychain is a few
milliseconds and invisible. What ships is a launch path with **no ceiling and no timeout**, whose
worst case presents as a hang rather than a delay, with the trial-expired gate on top of it.

### A second launch-time keychain caller, and it runs BEFORE licensing

`App/ContentView.swift:336` is a **stored property initializer** on the `ContentView` struct:

```swift
@ObservedObject private var bookmarks = StreamBookmarkStore.shared
```

So `StreamBookmarkStore.shared` is constructed the first time `ContentView()` is evaluated, inside
the `WindowGroup` content closure, on the main thread — **before the `.task` at
`ManifoldApp.swift:50` is even attached.** `StreamBookmarkStore.init` ends with
`migratePassphrasesToKeychain()` at `App/Preferences.swift:466`.

That migration walks every bookmark and, only for ones whose persisted `urlString` still carries
`?passphrase=`, calls `KeychainStore.streams.write` — `SecItemUpdate`, then `SecItemAdd` on
not-found. So:

- **Zero keychain calls for most users**, which is why it has never appeared in a sample.
- **One to two synchronous round trips per legacy bookmark** for anyone who saved SRT URLs with
  inline passphrases before the migration shipped — on the main thread, ahead of licensing. These
  are **writes**, which prompt on a locked keychain exactly as reads do.
- ⚠️ **Permanent for anyone whose keychain refuses.** The strip is gated on a confirmed write
  (`Preferences.swift:484`) and a failure leaves the entry byte-for-byte alone, so the migration
  **retries at every launch, forever, and never converges.** That gate is right — it exists so a
  failed write cannot destroy the only copy of a credential — but it means a broken keychain buys a
  permanent launch cost rather than a one-time one.

The stream passphrases **themselves are read lazily, on connect, not at launch**:
`StreamBookmarkStore.connectURL(for:)` at `Preferences.swift:852` is the only read of
`KeychainStore.streams` and it is on the dial path. The bookmark *list* is eager; the secrets are
not.

Everything else is clean: `DiagnosticsExport.presence` (`:646`) reads three accounts on
user-initiated export only; `activate` / `deactivate` are user-initiated.

**So launch touches the keychain in two subsystems, both on the main thread, in this order:**
`StreamBookmarkStore`'s migration (usually zero calls, non-zero for legacy users, **writes**), then
`bootstrap`'s four to eight.

### ⚠️ THE APP ALREADY MADE THIS JUDGEMENT, IN THE OTHER DIRECTION, AND WROTE IT DOWN

`App/StreamBookmarksSheet.swift:391` deliberately **declines** a keychain read. It shows the
passphrase-removal control for every SRT bookmark without first checking whether one is stored,
and the comment states the reason:

> ⚠️ SHOWN FOR EVERY SRT BOOKMARK, WITHOUT FIRST CHECKING WHETHER ONE IS STORED. The obvious gate —
> `KeychainStore.streams.get(id) != nil` — is a Keychain READ, and these items live in the
> ACL-guarded file keychain (verified: they are in login.keychain-db), where a read can raise an
> authorization prompt. A password dialog appearing because someone clicked a pencil would make the
> app feel like it was doing something it had not been asked to do.

It accepted a redundant `SecItemDelete` rather than take a synchronous keychain read on a UI path,
**to avoid a prompt on a pencil click.** The launch path takes four to eight of them, on the main
thread, holding the first window's paint. The same judgement, applied consistently, argues against
the launch path far more strongly than it argued against the sheet — a prompt on a pencil click is
at least attributable by the user; one before the first window is not.

### Nothing is decided

This entry records what was observed, what was derived, and what it invalidates. It proposes no
route and no change to `bootstrap`, `KeychainStore`, `isUsable`, or the migration. Two defects are
recorded here on purpose — the **blocking** and the **gate's opening frame** — because they are
independent, and a fix that only moves the keychain call off the main actor closes the first and
leaves the second exactly where it is.
