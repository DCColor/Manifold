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
