# Manifold — known bugs

Shipping defects that are understood but not yet fixed. Each entry states what is wrong, why
nobody has reported it (if that is the interesting part), and what it blocks.

A FIXED entry stays here, marked, until the fix has been through a real session — the write-up is
what makes a regression recognisable, and deleting it the day the patch lands is how the same bug
gets rediscovered from scratch.

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

## ⚠️ UNCONFIRMED: scrub release jumps the picture once, backwards, on ProRes

**Status:** OPEN. **Tolerance mechanism REFUTED by measurement 2026-08-27; staleness mechanism
matches the magnitude but NOT the direction. Still not reproduced in-house.** **Reported:**
2026-08-27 by Joey on 0.6.2. **Not seen** on the build Mac. **Blocks:** nothing; it is a trust problem — a
colourist who sees the picture move after they let go stops believing the scrub.

**The report:** scrubbing a ProRes file, on release the picture jumps once, consistently
BACKWARDS — *"almost backs up a frame"*. Timecode matches the picture after the jump.

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

### Neither mechanism has a code-level directional bias — this is still unexplained

Both gates use `abs()`; the tolerance is symmetric. **Staleness makes the preview lag the drag, so
its sign is the sign of the last net movement** — dragging forward ends with a FORWARD jump,
dragging backward with a backward one. A consistently backwards correction therefore requires the
user's final movement to be consistently backwards (overshoot, then settle back), which is
behaviour, not code, and is not established. **Do not record the direction as explained.**

### Relative magnitudes

- **On ProRes — the reported codec — staleness is the whole effect: ~1.2 frames vs tolerance's
  0.** Not "both contribute".
- **On long-GOP both contribute**, tolerance the larger (up to ±11 frames, sd 6.0) and staleness
  1.2–16 frames depending on speed.

### The implied fix — UNSCHEDULED, and not a one-liner

The mechanism that matches points at the throttle, not the tolerance. Two parts, and the second is
why this is not a small change:

1. **Issue a final, UN-THROTTLED preview request on release**, at `scrubValue`, bypassing both
   gates. That is what closes the ~1.2-frame staleness floor.
2. **Hold the overlay until the reader's frame lands**, instead of nil-ing `scrubPreviewImage` at
   `ContentView.swift:2524`.

⚠️ **(2) IS AN ORDERING PROBLEM AND IT IS THE REASON THIS IS NOT ONE LINE.** Today the overlay is
torn down in the SAME closure that starts the seek — **it goes away before the reader has
delivered anything.** So (1) on its own would compute the correct final preview and then throw it
away before it could be seen; the user would still see the jump. Doing (2) needs a signal that the
reader's first frame is actually on screen, which the release closure does not currently have.

**Not scheduled.** The defect is not reproduced in-house and the direction is unexplained, so this
would be built against an inferred cause.

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

**Running it on JOEY'S ACTUAL FILE is the single measurement most likely to settle the direction.**
Two in-house ProRes fixtures gave exactly zero across 80 positions; a real directional bias on his
media would show up immediately, and its absence would move the whole question onto the throttle
where the magnitude already points.

### Before touching it, get the missing facts

Not reproduced in-house, and the report is under-specified in the ways that decide the fix:

- **Frame rate and duration of Joey's file**, and whether it reproduces on a short clip.
- **Is it exactly one frame, or "almost"?** A sub-frame shift and a one-frame shift have different
  causes; *"almost backs up a frame"* does not separate them.
- **Which DIRECTION was the last movement before he let go?** This is now the decisive question,
  because staleness explains the magnitude and only the drag direction can explain the sign.
- **How fast was the drag?** Staleness is ~1.2 frames at ≤2× realtime and grows with speed; a
  larger reported jump would point at a fast scrub, a strictly one-frame one at the gate floor.
- **Does it reproduce on H.264 as well as ProRes?** No longer a yes/no check but a discriminator:
  tolerance contributes 0 on all-intra and up to ±11 frames on long-GOP, so a much LARGER and
  double-signed jump on H.264 would say tolerance is live there while the throttle drives ProRes.
- **Does it reproduce with the preview overlay disabled** — still the cleanest single
  discriminator, because it removes both the generator and the throttle from the picture at once.

**Related:** the generator is `FrameEngine.makeScrubPreviewGenerator(for:)`; the preview request is
`ContentView.requestScrubPreview(at:)`; the release path is `FrameEngine.exactSeek(to:)` →
`beginReading`; the no-decode readout during the drag is `FrameEngine.scrubSeek(to:)`.

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
