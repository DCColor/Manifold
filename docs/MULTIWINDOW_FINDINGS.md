# Manifold — multi-window playback: findings and the stage-2 plan

The audit behind the per-window playback work, the measurements that back it, and what stage 2
still has to do. Stage 1 shipped; stage 2 depends on this document, so it records the reasoning
and not just the conclusions.

**The model** (settled before any implementation):

- Each window gets its OWN `FrameEngine`. Windows are independent decks.
- Only one window plays at a time. Switching focus PAUSES the previously-playing window and makes
  the newly-focused one playable. Pause means video and audio.
- A window that owns an exclusive device — DeckLink output, or a live NDI/WHEP/SRT connection —
  trumps that. It keeps playback and audio; every other window's transport is DISABLED, with a
  message naming the owning file and saying to turn it off there.
- Non-owning windows remain fully usable otherwise: paused frame, scopes, inspector, frame export.
  It is PLAYBACK that is gated, not the window.
- When the exclusive device is released, everything is paused. The user presses play wherever they
  want. Nothing auto-resumes.

---

# Part 1 — What multi-window did BEFORE stage 1

Worth recording, because it reframes the whole thing: **multi-window was not merely unarbitrated,
it was broken.** `WindowGroup` gives ⌘N New Window (nothing in `ManifoldApp.commands` replaces
`.newItem`), so two windows were always reachable, and one `FrameEngine` was shared between them.

The engine's consumer hooks are single-assignment, so the second window to run `.onAppear` won
every one of them:

- `engine.onVideoFrame` was repointed at the second window's `MetalVideoRenderer`, so **the first
  window's picture froze.** Metal is the visible surface; the AV reference layer underneath it is
  covered.
- `engine.attach(renderer:)` set `videoRenderer` to the second window's AV renderer and left the
  first permanently added to the synchronizer, timed but never fed.
- `.onDisappear { engine.stop() }` meant **closing either window unloaded the other's file.**
- Both windows aspect-locked to the same `displaySize`, because there was one engine to read it
  from. (Measured on the pre-change build: opening one file produced **two** 1920×1080 windows.
  After stage 1 the same sequence produces one 1920×1080 window and one untouched 1280×720 one.)

Stage 1 replaces a genuinely broken state with a merely *wrong-per-the-model* one.

---

# Part 2 — What stage 1 shipped

### 2.1 `FrameEngine` moved into `ContentView`

`@StateObject private var engine = FrameEngine()` now lives in `ContentView`, not `ManifoldApp`.
The `engine:` parameter is gone. Everything downstream already took it as a parameter
(`InspectorPanel(metadata:engine:)`, `CaptionOverlay(engine:captions:)`), so nothing else changed.

### 2.2 The registration seam — `App/WindowDeck.swift`

The point of stage 1, and the reason it is worth shipping alone. Three types:

- **`WindowDeck`** — one window's identity: its `NSWindow`, engine and renderer. `ObservableObject`
  only so `ContentView` can hold it in a `@StateObject` (which evaluates once per window; `@State`
  would re-run the initializer on every View-struct re-creation — the measured bug already
  documented on `RendererStore`). Nothing on it is `@Published`, deliberately: it is written from
  AppKit callbacks that can land inside a SwiftUI update pass, and no view needs to re-render when
  it changes.
- **`DeckRegistry`** — every open deck, and the one holding the app-wide hooks. Two methods carry
  all the policy: `configure(_:)` (per-window wiring, runs for every deck) and `adoptHost(_:)`
  (the app-wide hooks, one deck at a time).
- **`WindowDeckRegistrar`** — a zero-size `NSViewRepresentable` whose `DeckHostView` overrides
  `viewDidMoveToWindow`.

**Why `viewDidMoveToWindow` and not `.onAppear`.** `.onAppear` fires per view insertion and hands
back no window identity — it cannot key a registry and it cannot deregister.
`viewDidMoveToWindow` fires with the `NSWindow` in hand and again with nil on teardown: exactly the
register/deregister pair, with identity, that a registry needs. It is also the app's existing idiom
(`WindowConfigurator` in `PlayerWindow.swift` reaches for the same window), but without that file's
`DispatchQueue.main.async` hop, which exists only because `view.window` is nil during `makeNSView`.

**All eleven app-wide hooks now live in one method.** Verified by grep — every assignment to
`DeckLinkService/NDIService/WHEPFrameRouter/SRTFrameRouter .shared.{renderer, audioTap,
onWillActivateStream, isCardAudioSilentProvider, systemAudioRouting}` is in `WindowDeck.swift`:

| Hook | Was | Now |
|---|---|---|
| `DeckLinkService.shared.renderer` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |
| `NDIService.shared.renderer` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |
| `WHEPFrameRouter.shared.renderer` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |
| `SRTFrameRouter.shared.renderer` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |
| `NDIService.shared.onWillActivateStream` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |
| `WHEPFrameRouter.shared.onWillActivateStream` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |
| `SRTFrameRouter.shared.onWillActivateStream` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |
| `NDIService.shared.audioTap` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |
| `DeckLinkService.shared.audioTap` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |
| `DeckLinkService.shared.isCardAudioSilentProvider` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |
| `DeckLinkService.shared.systemAudioRouting` | ContentView `.onAppear` | `DeckRegistry.adoptHost` |

**The policy is unchanged: most recently registered deck wins.** That is byte-identical to the old
behaviour (last window to run `.onAppear` won every assignment) and fires at the same frequency
(once per window creation). What changed is only that the rule is written down once instead of
being an accident of ordering.

`ContentView`'s `.onAppear` is now two lines — `armIdleIfNeeded()` and `updateScopeSampling()` —
both genuinely view-scoped.

**Two deliberate departures from a literal transcription**, both behaviour-preserving:

1. **Weak engine captures.** `isCardAudioSilentProvider` and `systemAudioRouting` captured the
   engine *strongly*. That was harmless when the engine was app-lifetime; with per-window engines it
   would pin a closed window's engine — and its audio renderer — inside `DeckLinkService.shared`
   forever. Both are now `[weak engine]`. The `?? true` on the silence provider matches
   DeckLinkService's own default at the call site (`isCardAudioSilentProvider?() ?? true`): with no
   engine to ask, silence is the honest answer.
2. **`audioTap.onFormatChange` is host-only.** The old line set it on `engine.audioTap` — one
   engine, one tap, so exactly one handler existed. Transcribing it literally into a per-window
   context would have been a *new* behaviour: any background window loading a 5.1 file would
   re-establish the DeckLink card out from under the foreground window. It is set in `adoptHost`
   and cleared in `relinquishHost`.

### 2.3 `attach(renderer:)` — the synchronizer leak

`addRenderer` accumulates. `videoRenderer` — which the decode pumps enqueue into — only ever points
at the last one, so a second attach left the previous renderer permanently on the synchronizer's
clock, timed but never fed, and nothing released it. `attach` now removes the previous renderer
first, making it idempotent and the renderer set exactly one element.

### 2.4 `.onOpenURL` moved into `ContentView`

It needs an engine and the App scope no longer has one. See Part 3 for the measured behaviour.

### 2.5 Autoplay gate

`Preferences.shared.autoplayOnLoad` is no longer read directly at load sites. Both load paths
(`.onOpenURL`, the file importer) now use `deck.shouldAutoplayOnLoad`, which is the preference
AND-ed with "this deck is not demonstrably a background window".

**`isBackgroundDeck` is deliberately conservative, and the direction is load-bearing.** It answers
"is some OTHER deck definitely in front", not "am I key". `DeckRegistry.frontmostDeckWindow`
returns nil — meaning *suppress nothing* — in three cases:

- fewer than two decks (a lone window can never be a background window);
- the key/main window is not a deck (Settings, About, an `NSOpenPanel`, a popover) — the user is in
  a panel, which says nothing about which *deck* is front;
- nothing is key or main at all (app in the background, e.g. a Finder open arriving at launch).

---

# Part 3 — Measured results

Method: `Profile` build, run with stdout captured, driven via System Events, windows enumerated
with `CGWindowListCopyWindowInfo` (System Events' window list proved unreliable here — it reported
duplicate entries and stale positions; Quartz is authoritative and ordered front-to-back).

### 3.1 Keyboard shortcuts DO scope to the key window — proven, not assumed

This was flagged as assumed in the audit, and stage 2's disable logic depends on it.

**Instrument:** `⌃⌥E` (export frame). Its log line *differs by window state* — `[EXPORT] wrote …`
when that window's renderer has a frame, `[EXPORT] no rendered frame yet` when it does not — so it
identifies **which** window handled the key, which a same-message shortcut could not.

**Setup:** one window with a file loaded, one empty window.

| Key window | `⌃⌥E` result |
|---|---|
| loaded window (1920×1080) | `[EXPORT] wrote /Users/…/Manifold_frame_….png` |
| empty window (1280×720) | `[EXPORT] no rendered frame yet` |

The empty window's own renderer answered. The shortcut did **not** reach the loaded window.
Repeated on the final build with the same result.

**Conclusion:** SwiftUI `.keyboardShortcut` on zero-opacity `Button`s in `.background` chains
resolves against the key window's hierarchy. Stage 2 can gate per window.

**NOT tested:** whether `.disabled(true)` on those hidden buttons suppresses the shortcut. There is
no existing disabled-plus-shortcut pair in the app to exercise, and adding one purely to test it
would have been shipping test scaffolding. It is standard SwiftUI behaviour (a disabled Button does
not perform its action), but stage 2 should confirm it on the first control it gates rather than
building the whole disable layer on it.

**One methodology warning for whoever repeats this.** An earlier run of this test using the arrow
keys produced *zero* log lines in both windows and briefly looked like a regression in the frame
jog. It was a test artifact — focus was not where `System Events` reported it. Re-run in isolation,
the arrow jog produced 5/5 seeks on the stage-1 build, identical to the pre-change baseline. Verify
the front window with Quartz immediately before each keypress, and use `Cmd-\`` to move key window
(`AXRaise` and `AXMain` both failed to move focus in this app).

### 3.2 `.onOpenURL` with multiple windows — it opens a NEW window

Measured, in sequence:

| Before | Action | After |
|---|---|---|
| 1 window (empty, 1280×720) | Finder-open `wedge.mov` | **2** windows; new 1920×1080 window has the file; the empty one is untouched |
| 2 windows (1 empty, 1 loaded) | Finder-open the same file again | **3** windows; new one has the file; neither existing window changed |

**This is the wanted behaviour, and it is the good case:** a Finder double-click opens a new window
and loads there. It never silently reloads a background deck, and the URL is **not** broadcast to
every window in the group — `FrameEngine: loaded` appears exactly once per open. One file, one
window, one deck.

Two honest caveats:

- **It never reuses an empty window.** The launch window sits there empty while the file opens in a
  new one, so the common "launch, then double-click a file" path leaves a stray empty window. Not a
  correctness problem, mildly untidy. Worth a decision in stage 2, where a real active-deck concept
  exists to reason about it.
- Consequently the window count grows one per opened file, which under the model is right (one deck
  per file) but is a change in feel from a single-window app.

### 3.3 Two windows are genuinely independent decks

- Opening one file produces **one** 1920×1080 window and leaves the other at 1280×720 — per-window
  `displaySize`, i.e. separate engines. (Pre-change, the same action made **both** windows
  1920×1080.)
- Both loaded windows export a real frame (`[EXPORT] wrote` from each in turn), so both have live
  pictures at once. **The old "second window freezes the first" bug is gone.**

### 3.4 The autoplay gate — a real bug found and fixed by testing it

`autoplayOnLoad` is **off** in this machine's defaults, so the gate was initially never exercised
and both builds looked identical. Setting it on exposed a genuine regression:

> With `autoplayOnLoad = YES` and the launch window still open, a Finder-opened file **loaded and
> sat at frame 0**. The gate refused to autoplay the very window it had just been opened into.

**Cause:** SwiftUI creates/targets a window for the opened URL and delivers `.onOpenURL` **before**
that window becomes key. A synchronous frontmost test therefore asks "is the window the user just
asked for in front?" at the one instant the answer is still no — and because the launch window is
almost always still open, this hit the *common* Finder-open path, not a corner.

**Fix:** defer the test (not the meaning of the load) by one main-actor turn, so the receiving
window has become key before `shouldAutoplayOnLoad` is evaluated.

**Re-measured after the fix:** the file autoplays and runs to the end (position 4.0s on a 4.0s
clip). The preference was restored to its original value afterwards.

**NOT tested: the suppression half.** No current code path can load a file into a genuinely
background deck — `.onOpenURL` targets a new/front window and the file importer's sheet is attached
to the front window. The gate is a guard-rail for stage 2 rather than something today's UI can
trigger. Its logic still holds for a background deck (non-key at test time → suppressed).

### 3.5 Volume — the behaviour that shipped

`engine.setVolume(Float(Preferences.shared.playbackVolume))` now runs per deck in
`DeckRegistry.configure`, so **each window's engine has its own output gain**, seeded from the
shared preference at window creation. The volume slider (`ContentView`) still does both things it
did before: it sets *this* engine's gain and writes `Preferences.shared.playbackVolume`.

Net behaviour, stated plainly:

- Moving the fader in window B changes **window B's** playback gain immediately.
- It also overwrites the app-wide stored default, so **the next window to open** starts at B's
  level.
- It does **not** touch window A's live gain. A and B can sit at different levels for the rest of
  the session.

This is the last-writer-wins seeding pattern `WindowChrome` already documents for tray/slot state,
and it is defensible (a per-deck fader that remembers where you last left it). It is called out
because it is a real behaviour change and nobody chose it deliberately — it fell out of moving the
engine. If per-deck faders are wrong, the fix is for the slider to stop writing the preference; that
is a one-line decision for stage 2, not a bug today. Mute is per engine and not persisted, unchanged.

---

# Part 4 — Audio: what is actually true

The finding that most changes stage 2's spec.

**The only system-audio output in the app is `FrameEngine.audioRenderer`.** Verified by grep across
the tree: one `AVSampleBufferAudioRenderer`. Consequences:

- **Construction of a second engine is free and safe.** `AVSampleBufferRenderSynchronizer` and
  `AVSampleBufferAudioRenderer` are ordinary per-instance objects — no process-wide singleton, no
  exclusive device claim, no hardware acquisition until samples are enqueued with rate > 0.
  `AudioTapBuffer` allocates its ring lazily on the first buffer, so an engine with no file holds no
  PCM. Four idle engines cost nothing.
- **Nothing breaks until both play.** Then both feed the default output device and CoreAudio mixes
  them: no error, no exclusivity failure, just two programs audible at once. This is the accepted
  stage-1 intermediate state.
- **Pause is already audio-silence, with no new mechanism needed.** `pause()` → `setShuttleRate(0)`
  → `synchronizer.rate = 0`, and a stopped synchronizer clock stops the audio renderer pulling.
  **Stage 2 must use `pause()`, not a mute.** Muting leaves the clock running and the decoder
  pumping, and adds a second mechanism to keep in step with the first.
- **Live sources produce no desktop audio at all.** NDI's audio goes only to the `AudioTapBuffer`
  for SDI, never to the speakers; WHEP and SRT decode video only. So the model's *"a window owning a
  live connection keeps playback **and audio**"* is, today, a no-op for the audio half. Worth knowing
  before writing UI copy that promises it.

---

# Part 5 — Cost

**The engine is cheap. The pipeline around it is not — and it was already per-window.**

Per `FrameEngine` at rest: two Foundation objects, two `DispatchQueue`s, an empty ring. Kilobytes.
Per loaded file: an `AVAssetReader` decode session, a *second* decode session for
`AVAssetImageGenerator` (scrub preview), a ~768 KB ring at 48k stereo (~2.3 MB at 5.1), and on the
libav path a `LibavFrameSource` **plus** a fully detached `LibavThumbnailSource`.

The dominant term is `MetalVideoRenderer`, one per window since before this work:

- offscreen ring: `rgba16Float`, 8 B/px, ring of 2 → **≈133 MB per window at 4K** (the figure the
  renderer's own comment cites), allocated at source resolution, so a sourceless window pays nothing
- frame queue: `defaultMaxQueued = 12` decoded buffers, ≈25 MB each at 4K 10-bit 4:2:0 → up to
  ~300 MB at full depth (backpressure normally keeps it shallow)
- fixed: Metal device, three command queues, every pipeline, the texture cache, **one CVDisplayLink
  per window**
- DeckLink staging when output is on: ≈44 MB at 2160p

**Four 4K windows all playing — the stage-1-only state — is ~532 MB of offscreen plus up to ~1.2 GB
of queued frames worst case, four display links and four decode pipelines.** Under the finished
model it collapses: three of four decks are paused, so pumps and decode threads idle and queues
drain, leaving 4 × 133 MB of offscreen (still required — the model promises scopes and frame export
keep working on a paused deck) and **one** live decoder.

**The sharpest cost is CPU, not memory.** `LibavFrameSource` sets `thread_count = cores − 1`, and
its comment is a measured war story: `thread_count = 0` starved the Metal scope-compute callbacks by
~190 ms and put the scopes five frames behind the picture — **with one decoder**.
`LibavThumbnailSource` adds `cores/2`. Four DNxHR windows on a 10-core machine is 4 × (9 + 5) = **56
decode threads on 10 cores**, which reproduces that starvation and worse. It does not happen under
the finished model (one decoder runs), but it is the guaranteed symptom of shipping stage 1 alone to
anyone with MXF footage. **Do not put this build in front of someone who will open four MXF files.**

---

# Part 6 — Stage 2

## 6.1 How the app learns which window is active

**Use `NSWindow.didBecomeKeyNotification`, filtered through `DeckRegistry`. Not SwiftUI's
mechanisms.**

- **`@Environment(\.controlActiveState)`** has a disqualifying flaw: when the *application*
  deactivates, **every** window reports `.inactive`, including the one that was key. You cannot
  recover which window was key, so on reactivation you have no idea which deck to make playable. A
  naive reading also pauses playback whenever the user ⌘-Tabs away — wrong for a monitoring tool.
- **`@FocusedValue` / `.focusedSceneValue`** is built for driving menu commands from the key scene
  and inherits the same app-deactivation ambiguity.

**`.hiddenTitleBar` is a non-issue.** It changes the style mask; the window is an ordinary
`NSWindow` and posts key notifications normally. The app already depends on this
(`WindowConfigurator` sets `contentAspectRatio` and the traffic-light alphas).

**Yes, About and Settings would falsely count — and so would more than that.**
`didBecomeKeyNotification` fires for the About window, the Settings window, the `NSOpenPanel` in
`presentCaptionPicker()` and the Preferences export-folder picker (both `runModal()`), and the
`GuidesPanel` popover (`NSPopover` is backed by a window that can take key). Sheets are attached, not
separately key, so `StreamBookmarksSheet` and the diagnostics prompt are safe. `NSMenu` does not
post it, so the toolbar chevrons are fine.

**The rule — and it must not be an exception list:**

> On `didBecomeKeyNotification`, look the window up in `DeckRegistry.entries`. **If it is not a
> registered deck, do nothing at all.**

That handles every auxiliary window present and future, and gives the right UX for free: opening
Settings or a file picker does not pause your playback. Filtering by class or title is a bug farm.

Also needed: on `NSApplication.didResignActiveNotification`, **keep** the active deck (a colourist
⌘-Tabbing to check a note must not lose playback); on `didBecomeActiveNotification`, re-derive from
`NSApp.keyWindow`.

## 6.2 Where arbitration lives

`DeckRegistry` already is the object. Stage 2 extends it with:

```
activeDeck: ObjectIdentifier?                        // the one deck whose transport is live
exclusiveOwner: (deck: ObjectIdentifier, device: ExclusiveDevice)?
```

`ExclusiveDevice` should be an **enum with exhaustive switches**, for the reason `LiveSource`'s own
header gives: adding a device must fail the build, not silently skip a site. Cases `.deckLink`,
`.ndi`, `.whep`, `.srt` — the last three can wrap `LiveSource`.

Registration and deregistration already exist and are already belt-and-braces
(`viewDidMoveToWindow(nil)` plus `NSWindow.willCloseNotification`, weak refs throughout, pruning on
every read).

**Every transition — key change, device claim, device release, registration, deregistration — must
run through ONE method that recomputes the whole picture and applies it.** Model it on
`DeckLinkService.applyAudioRouting()`, whose comment states the principle: *"The SINGLE place the
system-renderer mute is re-evaluated… so a stale destination can never leave desktop audio muted."*

**The case that will bite you: the owning window closes while holding an exclusive device.**
`DeckRegistry.deregister` is written and commented as the place this lands, but stage 1
deliberately does **not** release devices there. Today the device stays claimed, the singletons'
`weak var renderer` goes nil, and the card falls to neutral black — while every surviving window
would (under stage 2) still be transport-disabled, naming a window that no longer exists. Stage 2
must release the device, clear `exclusiveOwner`, and leave everything paused with no auto-resume.

Second edge case: the exclusive owner is also the active deck and it closes. Do **not** auto-promote
another window to playing. Set `activeDeck` to the new key window so its transport is *enabled*, but
leave it paused — the model's no-auto-resume rule should govern window close too.

## 6.3 Which controls to disable

### DISABLE in a non-owning window

| Control | Site (`App/ContentView.swift`) |
|---|---|
| Play/pause button + **Space** | the play `Button` in `controls(showPin:)` |
| Scrubber `Slider` | `controls(showPin:)` |
| **J** / **K** / **L** shuttle | the hidden `.background` buttons |
| **←** / **→** frame jog | the hidden `.background` buttons |
| Loop button | `controls(showPin:)` |
| Mute button + volume slider | `controls(showPin:)` |

Two notes. **K** is "pause" and a gated deck is already paused, so disabling it is harmless while
enabling it is confusing — keep the set coherent. **Mute/volume: disable, don't hide** — a paused
engine is silent by construction so the fader has nothing to act on, and leaving it live lets a
window that cannot play mutate the app-wide stored default (see 3.5).

The arrow keys and J/K/L are mounted **unconditionally** in `.background`, outside the `if hasSource`
branch, so they are live today even with no media (they no-op on the engine). They need an explicit
gate.

### KEEP LIVE — the window stays a usable inspection surface

Frame export (button and `⌃⌥E`), inspector and **I**, scopes tray and `⌃⌥T`, all scope shortcuts
(`⌃⌥X/G/B/1/2/3`), the per-slot scope pickers, guides, the filename overlay **N**, **Tab** pin,
`⌃⌥R` reference-layer A/B, readout-mode cycling, the range override in the inspector, Edit in Flip,
caption load/clear/position, and window resize.

**⚠️ Refresh metadata is a trap.** `reinspect()` looks like a read but calls
`beginReading(from:resumePlaying: isPlaying)` when a colour tag changed — a full reader rebuild. In a
paused deck `isPlaying` is false so it will not start playing, and rebuilding one paused reader is
acceptable. Keep it enabled (it is the whole point of the Flip round-trip), but know it is the one
"safe" control that touches decode.

### NEEDS AN EXPLICIT DECISION — the model does not cover these

1. **Open… / file importer** — should stay enabled (loading a file into a paused deck to inspect it
   is legitimate). The autoplay gate from stage 1 already covers the "it would start playing"
   hazard.
2. **`⌃⌥O` / `⌃⌥⇧O` and the DeckLink split-button** — `DeckLinkService` is a singleton; if window A
   owns the card and window B presses `⌃⌥O`, B takes it. The model says the owner "trumps" but not
   whether a non-owner may *steal*. **Recommendation: disable the device-claim controls in
   non-owning windows**, with the reason in the tooltip, matching the pattern the DeckLink button
   already uses for a below-floor driver. Silent theft of a broadcast output is the worst outcome
   here.
3. **`⌃⌥N` / `⌃⌥⇧N` and the streaming control** — same question, same recommendation.
4. **The Disconnect menu item** calls `LiveSource.retireActive()` from any window. The model's copy
   says *"turn it off there"*, which implies a non-owning window should **not** be able to
   disconnect another window's stream. Disable it to match the copy.

### The message itself

The spec is *"a message naming the owning file and saying to turn it off there"*, so the registry
needs a per-deck display name. `engine.metadata?.fileName` covers files; a stream-owning window has
**no filename** and (per `BUGS.md`) live sources publish very little about themselves —
`ndi.connectedSourceName` or the bookmark name is the best available. Give the deck a computed
`displayName` with an honest fallback rather than letting call sites guess.

**Do not reuse `connectErrorBanner`.** Its own doc comment explains that the single
`whep.lastError ?? srt.lastError ?? engine.playbackNotice` slot works *only* because those are
mutually exclusive — an arbitration message is not. It also auto-dismisses after 9 s, which is wrong
for a standing condition. Build a separate, non-dismissing affordance.

## 6.4 What "this window owns it" requires of each device

All four services are singletons whose renderer is assigned last-writer-wins, and **none has any
concept of which window asked**. Ownership needs, uniformly: the service records *who* claimed it, a
claim while owned is refused with a nameable reason rather than silently succeeding, and release is
idempotent and reachable from window teardown. A small protocol the registry drives —
`claim(by:) -> Bool`, `release(from:)`, `currentOwner` — behind one exhaustive enum.

**DeckLink** is the most contained: the whole bundle (`renderer`, `audioTap`,
`isCardAudioSilentProvider`, `systemAudioRouting`, `onFormatChange`) already moves atomically in
`adoptHost`, so stage 2 only has to gate it. Two specifics: `systemAudioRouting` must be
re-evaluated on transfer (the outgoing owner's engine holds `deckLinkOwnsAudio == true` and would
stay muted forever unless told otherwise), and `sourceColorChanged()` / `sourceFormatChanged(...)`
still fire from **every** window's `.onChange(of: engine.metadata)` — gate them on ownership or a
background window's file load will live-switch the card's output mode. `autoStartOnLaunchIfEnabled()`
self-guards to once per process but fires from whichever window registered first; it belongs at app
scope.

**`LiveSource` is solving a different problem, and should not be overloaded.** Its header is
explicit: it answers *which transport* owns the renderer and how to retire it — mutual exclusion
among the three transports, enforced by the `Arbitration` token whose `fileprivate init` makes
bypassing the funnel a compile error. That is exclusion among transports, **not attribution to a
window**. The two compose rather than merge: `LiveSource` stays the authority on which transport,
`DeckRegistry` becomes the authority on which deck. **Do not add a window parameter to
`LiveSource`'s API** — its safety property comes from being small and having one job. The registry
should record the claiming deck immediately before calling the existing `connectNDI`/`connectWeb`/
`connectSRT` funnels, and clear it after `retireActive()`.

---

# Part 7 — Bigger than it looks

1. **`onWillActivateStream` calls `stop()`, not `pause()` — and `stop()` unloads the file.** It
   zeroes `hasMedia`, `currentURL`, `duration` and `tcInfo`. The model promises non-owning windows
   keep their paused frame, scopes, inspector and frame export; `stop()` destroys all four. Every
   "retire the other source" path in the app is built on it. Stage 2 must introduce a *second,
   softer* retirement — yield the transport, keep the media — and thread it through NDI, WHEP, SRT
   and `SyntheticLiveSource`. **This is the largest hidden item in the plan** and it is invisible
   from the model statement. The three hooks are marked `⚠️ KNOWN-WRONG` in `WindowDeck.swift`.

2. **`LiveDisplayRoute`'s save/restore can cross-wire two windows' clocks.** `activate` saves
   `renderer.clock` and `renderer.isPausedProvider`; `deactivate` restores them. Those closures
   capture a *specific engine*, and the save/restore happens on whichever renderer the singleton
   points at. If a claim and a release straddle a change of host, you restore window A's engine
   closures onto window B's renderer — window B's picture clocked by window A's synchronizer. Not a
   crash; a display running on the wrong clock, which presents as "window B stutters sometimes".
   Two defenses, take both: never re-point a router's `renderer` while it is active, and have
   `LiveDisplayRoute` save the renderer identity alongside the providers and refuse to restore onto
   a different one.

3. **NDI's `disconnect()` calls `renderer?.clearToBlack()` with no early-out** — which is why
   `LiveSource.retireActive` guards on `isConnected` (its warning is explicit). With per-window
   renderers, a claim transfer must not land that `clearToBlack` on a window showing a paused file.
   NDI also drives `renderer.onDisplayTick`, which `LiveDisplayRoute.activate` nils out for push
   sources — cross-transport handoff across two renderers is a state combination nothing has
   exercised.

4. **Stream ownership has no display name.** See 6.3.

5. **Diagnostics has no per-window playback state.** `DiagnosticsExport` never reads the engine (the
   `FrameEngine` matches in it are log-prefix string literals). Not broken by stage 1, but the report
   now cannot say which window was playing, what each held, or which owned the card — a hole in a
   file whose whole purpose is reconstructing what a tester was doing.

6. **`.onOpenURL` never reuses an empty window.** See 3.2.

---

# Part 8 — Known intermediate state after stage 1 (accepted)

- **Two decks both playing means two audio streams mixed to the speakers.** Wrong per the model,
  obvious, and fixed by stage 2.
- **No arbitration**: no pause-on-focus-change, no transport gating, no disabled-transport
  messaging, no device ownership.
- **`onWillActivateStream` still reaches exactly one engine** (the host's) and still calls `stop()`.
  A stream taking the display leaves every other deck playing into a renderer it no longer owns.
- **Devices are not released when the host window closes.**
- **Four DNxHR/MXF windows will thrash the decode threads.** See Part 5.
