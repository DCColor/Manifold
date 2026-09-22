# Manifold — known bugs

Shipping defects that are understood but not yet fixed. Each entry states what is wrong, why
nobody has reported it (if that is the interesting part), and what it blocks.

A FIXED entry stays here, marked, until the fix has been through a real session — the write-up is
what makes a regression recognisable, and deleting it the day the patch lands is how the same bug
gets rediscovered from scratch.

The file opens with a **pre-ship checklist** — work that is required before public launch but is
not a defect — and the numbered defect entries follow it.

---

## ⚠️ 2026-09-21 — AN ENTRY IS ONLY AS GOOD AS ITS LAST VERIFICATION DATE. READ THIS BEFORE PLANNING FROM THIS FILE.

**Every OPEN / PARTLY FIXED / UNCONFIRMED / RECORDED-NOT-FIXED / BANKED entry was audited against
the source on 2026-09-21.** The result is worth recording as a property of the file rather than as a
list of corrections, because the same thing will happen again:

- **Nine entries claimed "not built" / "not fixed" / "nothing changed in the app" for work that had
  already shipped** — the audio track selector (both halves), WHEP and SRT audio, the live SDI
  output mode, the DeckLink enumeration diagnostics, the `AVPlayerItemVideoOutput` scrub route, HLS
  as a source, the clean-aperture crop, the pro-workflow plug-in registration, and the narrow MXF
  decode plan. Several had been closed for three to four weeks.
- **The unreliable entries cluster in one window: 2026-08-26 to 2026-09-09.** Everything recorded
  from 2026-09-17 onward checked out accurate, including the two that were already honestly marked
  PARTLY FIXED.

**The mechanism is not carelessness, it is ordinary.** An entry is written at the moment of
diagnosis, when it is most valuable and most detailed. The fix lands days later in a different
session, and the code is what gets updated. Nothing in the workflow walks back to the status line.
The richer the entry, the less likely anyone rewrites it — and the entries here are very rich.

**The consequence is specific to this file: it is PLANNED FROM.** A feature-freeze push scoped off
these status lines would have carried nine phantom items. A stale FIXED is a missed regression; a
stale OPEN is wasted work, and it is the more expensive of the two here.

**So: a status line carries a date, and a date that predates the last touch of the code it
describes is a claim, not a fact.** When an entry matters to a decision, re-read the source before
acting on it. Line references rot too — several in this file pointed into files that had since
grown by hundreds of lines.

---

# Pre-ship checklist

**Not defects.** Work that must happen before public launch, kept here because the entries below
are where the evidence for it accumulated. Each item states what "done" means, so it can be closed
rather than left open by default.

⚠️ **NOTHING HERE IS A BLOCKER AS OF 2026-09-21.** This paragraph used to promote one item —
*"the Release configuration does not compile"* — on the grounds that it removed an option people
assume exists. `d76bb21` fixed that the same afternoon and both configurations have built
repeatedly since, so the item is back to being a checklist line and the audit half of it is what
remains open. The promotion is recorded rather than deleted because raising an item to blocker was
the right call at the time and the mechanism is worth reading before touching any `#if DEBUG`
declaration.

---

## ☐ PRE-SHIP: American English — a RECURRING DRIFT, not a one-time sweep

**Status:** OPEN, required before public launch. **Raised:** 2026-08-27 as a sweep.
**REFRAMED 2026-09-21, after re-scanning: this is not a task, it is a leak.** **Scope:**
user-facing strings are **REQUIRED**; internal docs and comments are **PREFERRED**, for
consistency.

### ⚠️ THE 2026-09-21 RE-SCAN — THE SWEEP WORKED AND THE PROBLEM CAME BACK

Both halves of that sentence are load-bearing, and the second is why this entry changed shape.

**Every one of the seven named user-facing hits below was fixed.** That part is done and verified —
see the strikethroughs in *"The confirmed user-facing hits"*.

**And British spellings have landed in user-facing strings since**, in code written after the
original scan. The clearest is the DNxHR picture caveat from the 2026-09-09 MXF work:

```
"Colour unreliable — needs Pro Video Formats"          ManifoldCore/DNxHRVideoToolboxDecoder.swift:77
"…renders with the wrong colour…"                      ManifoldCore/DNxHRVideoToolboxDecoder.swift:80-82
```

Also `ManifoldCore/FrameEngine.swift:1378` (a refusal message), and several `NSLog`/`print`
diagnostics that testers read — `App/MetalVideoRenderer.swift:1725`, `:1730`;
`App/HLS/HLSClient.swift:1262`, `:1279`; `App/NDI/NDIService.swift:507`;
`ManifoldCore/LibavFrameSource.swift:264`.

**And the prose counts have roughly DOUBLED**, which is the real finding: the codebase grew by
several features and every one of them was written in British English.

### ⚠️ SO A MANUAL PASS WILL NOT HOLD. THIS WANTS A CHECK IN THE RELEASE SCRIPT.

A one-time sweep is the wrong instrument for a defect whose rate of arrival is "every time anyone
writes a string". It was swept once, on 2026-08-27, and by 2026-09-21 there were new hits in
shipping strings — including one, `DNxHRVideoToolboxDecoder.PictureCaveat`, in a message written
specifically to be shown to users.

**What to build instead, and it is small:** a preflight check in `scripts/release-mac.sh` that
fails the build on a British spelling inside a user-facing construct. It already has the right
shape for this — the preflight that fails when a `.a` reappears in `ThirdParty/ffmpeg/lib` is the
precedent, and it is there for the same reason: a rule nobody can be relied on to remember by hand.

Three things it must get right, all of them derived from the work below rather than invented:

1. **Scan user-facing constructs, not the whole file.** The REQUIRED set is `Text`, `Label`,
   `Button`, `Toggle`, `Picker`, `.help(…)`, `navigationTitle`, `alert`, `confirmationDialog`, and
   the string constants they are built from (`PictureCaveat` is a `static let`, not an inline
   `Text`, and a construct-only scan would have missed it — so also flag British spellings in any
   `static let` whose value is a sentence).
2. **It must be MULTI-LINE AWARE.** See the ⚠️ below: the 2026-08-27 scan could not see inside
   `"""` blocks and undercounted. A single-line grep is not evidence.
3. **It must not touch identifiers, paths or third-party names.** See *"DO NOT BLANKET-REPLACE"*
   below — the codebase is full of correctly-American identifiers, and `App/LicenseManager.swift`
   is an American filename wrapping British prose.

Comments and docs stay PREFERRED, not required, and should not fail a build.

### The original 2026-08-27 scan, kept for the method

Scanned 2026-08-27 across `App/` and `Packages/` (excluding `ThirdParty/`):

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

**RE-MEASURED 2026-09-21**, same corpus, case-insensitive occurrence count over `*.swift` in `App/`
and `Packages/` excluding build products (`grep -rio <word> App Packages --include="*.swift"`):

`colour` **159** · `behaviour` **47** · `centre` **43** · `licence` **62** · `grey` **31** ·
`honour` **25** · `recognis*` **22** · `optimis*` **11** · `initialis*` **7** · `normalis*` **6** ·
`analys*` **4** · `serialis*` **3** · `artefact` **2** · `defence` **2** · `synchronis*` **2** ·
`minimis*` **1**

⚠️ **READ THE TWO ROWS TOGETHER — THEY SAY TWO DIFFERENT THINGS, AND BOTH MATTER.**

- **`licence` FELL, 82 → 62.** That is the sweep working. It was the word with the user-facing
  hits, it got attention, and the count moved in the right direction.
- **Everything else ROSE, most of it sharply** — `colour` 64 → 159, `behaviour` 30 → 47, `centre`
  26 → 43, `grey` 17 → 31. Nobody re-introduced these; they arrived with new code, in new files
  written between 2026-08-27 and 2026-09-21.

**That is the whole argument for automating it.** A word that gets swept stays swept. A word that
is simply how the author writes comes back at the rate new code is written, and the rate is high.

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

### ✅ The confirmed user-facing hits — ALL SEVEN FIXED, verified 2026-09-21

Required. These are what a customer reads. **Every one of them is now American**, which is the
half of this entry that worked:

- ~~`App/AboutWindow.swift:586` — `Text("Licences").tag(Tab.licences)`~~ → now
  `Text("Licenses")`. ⚠️ **The `Tab.licences` case name is still British and that is CORRECT** —
  it is an identifier, not prose. This one line is the entry's own "do not blanket-replace" rule in
  miniature: the string changed, the symbol did not.
- ~~`App/AboutWindow.swift:642` — `Text("Full licence texts are under “Licences” above.")`~~ → gone
- ~~`App/AboutWindow.swift:699` — `Text("All licences")`~~ → gone
- ~~`App/AboutWindow.swift:619` — the missing-licence-text warning~~ → gone
- ~~`App/LicenseManager.swift:826` — `Label("Your licence couldn’t be read", …)`~~ → gone
- ~~`App/LicenseManager.swift:618`~~ → now `App/LicenseManager.swift:811`, reading *"Your stored
  **license** key could not be verified. Please re-enter it, or contact support."* — the most
  visible of the lot, and fixed.
- ~~`App/DiagnosticsExport.swift:689,692` — `"no colour profile"` / `"      colour profile: …"`~~
  → gone from the diagnostics export.

⚠️ **AND THE LIST IS NOW OUT OF DATE IN THE OTHER DIRECTION.** Fixing these seven did not close
the entry, because new hits arrived behind them — see the 2026-09-21 re-scan at the top. **Do not
read a fully-struck list as "done".** That is exactly the reading this file's 2026-09-21 staleness
note warns about.

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

⚠️ **THE LINE NUMBERS THIS SECTION CARRIED WERE STALE AND HAVE BEEN RE-DERIVED 2026-09-21.** It
cited `:1015`, `:1053`, `:1094`, `:863` and `:61` in this file; `docs/BUGS.md` has since grown by
thousands of lines and every one of those pointed somewhere else. **Search for the text, not the
line** — which is the general lesson, not a note about this section.

`docs/BUGS.md` alone, re-measured 2026-09-21:

- **"centre channel" in the downmix entry → "center channel"** — one occurrence, now in the
  *"BANKED: an OPTIONAL stereo fold"* entry (search `centre channel`).
- **`colourist`** — **13** occurrences, up from the single one originally cited.
- **`re-centred`** — one occurrence, in the raster-size discussion.

**Done means** — **REDEFINED 2026-09-21, because the old definition was unachievable:**

The old wording was *"a scan returns zero hits in user-facing strings, and the remaining hits have
been converted or consciously left"*. That describes a **state**, and this defect does not hold a
state — it was reached on 2026-08-27 and lost again by 2026-09-21 without anyone doing anything
wrong.

So done means **a MECHANISM, not a scan result**:

1. A multi-line-aware check in `scripts/release-mac.sh` **fails the build** on a British spelling
   inside a user-facing construct or a sentence-valued `static let`.
2. The identifier/path/third-party exclusions below are encoded in that check, not remembered.
3. The current hits are cleared so the check passes on first run.

Comments and docs remain PREFERRED and are explicitly **out of scope for the build failure** —
they are noise in a gate, and gating on them is how a useful check gets disabled.

---

## ☐ PRE-SHIP: the dev-path audit is outstanding. (The Release compile half is FIXED.)

**Status:** ☐ **OPEN as a checklist item — NO LONGER A BLOCKER, lowered 2026-09-21.** The blocking
half is fixed and verified; the audit half is untouched and stays open. **Raised:** 2026-08-27 as
the dev-path audit, out of the `MANIFOLD_CONFIG_DEBUG` gating work.

**These were two items and they are one item**, because they have a single cause: **Profile defines
`DEBUG=1`, Profile is what every build to date has been, and so the Release configuration had never
been exercised — not for gating, and not even for compilation.** Splitting them would have two
entries proposing two fixes to the same untested configuration. That is still true of the half that
remains.

---

### ✅ THE BLOCKING HALF IS FIXED — `d76bb21`, verified 2026-09-21

**`xcodebuild -configuration Release` SUCCEEDS.** `d76bb21`, *"fix: make Release compile by ungating
`toneLock` declaration"*, moved the declaration out of the `#if DEBUG` block that its Release-side
uses sat outside of. Both configurations have been built repeatedly through the evening of
2026-09-21 — Profile and Release, signed, from a clean `-derivedDataPath` — as a side effect of the
SRT audio work, so this is not one green run.

⚠️ **THE FIX LANDED THE SAME AFTERNOON AND THE STATUS LINE DID NOT MOVE WITH IT.** The blocker was
raised at 14:59 and `d76bb21` was committed at 15:07 — eight minutes — yet this entry went on saying
"there is no working Release path today" for the rest of the day while every build in the room
disagreed. That is the shape the banner at the top of this file describes, arriving inside one
session rather than over weeks, which makes it worse rather than better: nothing about a slow-moving
file explains it. The original diagnosis is kept below because the *mechanism* is still the thing to
understand before touching any `#if DEBUG` declaration; only the claim about today's state was
wrong.

---

### The original diagnosis, kept for the mechanism

**At the time it was found, `xcodebuild -configuration Release` FAILED.** Six errors, all the same,
all in one file:

```
App/NDI/NDIService.swift:814:9:  error: cannot find 'toneLock' in scope
App/NDI/NDIService.swift:822:9:  error: cannot find 'toneLock' in scope
App/NDI/NDIService.swift:1838:9: error: cannot find 'toneLock' in scope
App/NDI/NDIService.swift:1842:9: error: cannot find 'toneLock' in scope
App/NDI/NDIService.swift:1906:9: error: cannot find 'toneLock' in scope
App/NDI/NDIService.swift:1910:9: error: cannot find 'toneLock' in scope
```

**The cause, exactly.** `private let toneLock = UnfairLock()` is declared at
`App/NDI/NDIService.swift:1082`, **inside a `#if DEBUG` block that opens at `:1012`**. Its uses
split cleanly:

| use sites | enclosing directive | Release |
|---|---|---|
| `:1109`, `:1112`, `:1123` | `#if DEBUG` at `:1012` | compiled out with the decl — fine |
| `:1216`, `:1219` | `#if DEBUG` at `:1168` | fine |
| `:1326` | `#if DEBUG` at `:1276` | fine |
| `:2064` | `#if DEBUG` at `:2063` | fine |
| **`:814`, `:822`, `:1838`, `:1842`, `:1906`, `:1910`** | **none — ungated** | **the six errors** |

**Present at HEAD.** It predates the colour-bypass spike and is unrelated to it; the spike touched
`MetalVideoRenderer.swift` and `ContentView.swift` only, and that Release run reported no errors in
either.

### ⚠️ AND THE FOUR UNGATED SITES ARE NOT DEBUG AFFORDANCES. THEY ARE THE SHIPPING NDI AUDIO PATH.

This is the part that makes it more than a build break. The six failing uses live in three
functions, and two of them are production code:

- **`serviceDesktopAudioAnchor(mediaNow:wallNow:)`** (`:1906`, `:1910`) — the desktop-audio
  timebase anchor. Reads `desktopAudioLead` under the lock *"per call rather than captured"*.
  Without it NDI is silent, not merely drifting — its own comment says so.
- **`reportRendererStateIfDue(now:)`** (`:1838`, `:1842`) — the renderer-state diagnostic, whose
  doc comment is *"A DIAGNOSTIC THAT CAN BE SUPPRESSED BY THE THING IT IS DIAGNOSING IS NOT A
  DIAGNOSTIC."*
- **`cycleDesktopAudioLead()`** (`:814`, `:822`) — this one *is* a debug affordance (Debug ▸
  Desktop Audio Lead), and it is the one that explains how the shape arose.

⚠️ **THE STATE IS UNGATED; ONLY THE LOCK IS NOT.** Checked rather than assumed —
`desktopAudioLead` (`:793`), `desktopAudioLeadChanged` (`:795`), `desktopAudioLeadLadder` (`:800`)
and `rendererForceReport` (`:1795`) are **all declared outside any `#if`**. So the situation is:
**cross-thread-shared production state, guarded by a lock that only exists in debug builds.**

**That means "move the declaration out of the `#if DEBUG`" is the correct fix and must not be
mistaken for a mechanical one.** It is restoring thread safety that Release does not currently
have, to a path where main writes the lead and the pump thread reads it. A build fix that made
Release compile by deleting the lock calls would produce a *silently* racy audio anchor instead of
a loud compile error — strictly worse.

### The consequence, stated plainly

**There is currently no working Release path, so "cut Release for the paid build" is not an option
that exists today.** It is not a switch that has been left unflipped; it is a configuration that
does not build. Anyone scoping a public build on the assumption that Release is available — for
stripping dev affordances, for the telemetry gate, or for anything else — is scoping against
something that has to be *made to work first*.

**And it cannot be assumed to be six lines of work.** The compile stopped at these six errors; it
is **unmeasured** whether fixing them reveals more. Swift type-checks a module as a unit and this
one has never been type-checked with `DEBUG` undefined, so the honest position is "at least this,
and the next error is unknown until the first fix lands". ⚠️ **Do not quote a Release cut as a small task
on the strength of this entry.**

### Why it went unnoticed, which is the reusable part

Per `CLAUDE.md`: *"`Profile` is the default build configuration and it has `DEBUG=1` — dev
affordances are reachable by keystroke. Every build cut to date has been Profile."* So Release was
never compiled, by anyone, as a matter of routine. **A configuration nobody builds is a
configuration that rots**, and it rots silently because there is no signal — exactly the
instrument-that-stopped-reporting shape this file records three times over in the DeckLink
enumeration entry.

**The cheap standing fix is a build, not a rule:** add `xcodebuild -configuration Release` as a
preflight in `scripts/release-mac.sh`, alongside the check that fails when a `.a` reappears in
`ThirdParty/ffmpeg/lib`. It needs to build, not ship — compiling the configuration is the whole of
what is being asked, and it would have caught this the day it landed.

### Related, and part of the same untested-configuration story

`docs/Manifold-BUILD.md` → *"Known gaps"* already pairs these two, and its telemetry note belongs
with this entry: **`MANIFOLD_TELEMETRY` is defined unconditionally in
`Packages/ManifoldCore/Package.swift`**, so Core-layer strings like `[LIVECLOCK]` and two tuning
setters are present in a Release archive, and the release script's assertion greps for
`[SRT-FLOW]` — an App-layer string gated on `DEBUG` — so **the check is true but incomplete.**

⚠️ **THAT CHECK IS ALSO A CHECK NOBODY HAS BEEN ABLE TO RUN**, for the reason above: it asserts
against a Release archive, and Release does not build. The `#if DEBUG || MANIFOLD_TELEMETRY` gates
across `App/Live/LiveDepthTelemetry.swift`, `App/SRT/SRTSession.m`, `App/DiagnosticsExport.swift`
and `App/BuildInfo.swift` have therefore never been evaluated in the configuration they exist for.
**Fix the compile first; the telemetry question cannot even be asked until then.**

*(There is no separate MANIFOLD_TELEMETRY entry in this file — it is documented in
`docs/Manifold-BUILD.md` under "Known gaps", and is folded in here rather than filed separately,
same root cause.)*

**Done means, for this half:** `xcodebuild -configuration Release` completes, a Release preflight
exists in `scripts/release-mac.sh`, and the telemetry assertion has been re-checked against an
archive it can actually inspect.

---

### ☐ THE CHECKLIST HALF: the dev-path audit

**RE-AUDITED 2026-09-21: still true, with one trigger pair since gated and a FOURTH SURFACE that
did not exist when this was written.** See *"⚠️ THE FOURTH SURFACE"* at the end of this entry —
the audit's scope was incomplete, which matters more than any single trigger, because an audit that
names five things and misses the sixth reads as finished.

⚠️ **AND NOTE WHAT THE HALF ABOVE DOES TO THIS ONE.** Much of the reasoning below turns on
"`#if DEBUG` does not gate anything because Profile defines DEBUG". That is true, and the Release
breakage adds a second edge to it: **the `#if DEBUG` blocks in this codebase have never been
compiled in the configuration where they are FALSE.** Gating something behind `#if DEBUG` has, to
date, been an untested claim in both directions — it does not remove the affordance from a Profile
build, and nobody has confirmed the remaining code still builds without it. `toneLock` is that
second failure, and there is no reason to think it is the only one.

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

### ✅ VERIFIED 2026-09-21 — what moved, and what did not

**The six ungated triggers are all still ungated**, inside `#if DEBUG` only — which, as this entry
says, is no gate at all in a Profile build:

| trigger | site | state |
|---|---|---|
| ⌃⌥W — libdatachannel link smoke test | `App/ContentView.swift:1831` | still ungated |
| ⌃⌥H / ⌃⌥⇧H — WHEP connect / retire | `App/ContentView.swift:1857`, `:1859` | still ungated |
| ⌃⌥⇧E — export next WHEP frame to PNG | `App/ContentView.swift:1866` | still ungated |
| ⌃⌥D / ⌃⌥⇧D — SRT connect / retire | `App/ContentView.swift:1928`, `:1930` | still ungated |

**One pair WAS gated since this was written:** ⌃⌥[ and ⌃⌥] now sit inside
`#if MANIFOLD_CONFIG_DEBUG` at `App/ContentView.swift:1895-1899`. The entry's line *"The ⌃⌥[ / ⌃⌥]
block further down is the one that was not"* is therefore **out of date and the block is now
gated.**

### ⚠️ THE FOURTH SURFACE — THE DEBUG MENU, WHICH THIS AUDIT PREDATES ENTIRELY

**This entry was written on 2026-08-27, when every dev affordance was a hidden keystroke. It is no
longer true that they all are.** A top-level **Debug** menu shipped in build 18, sitting in the
menu bar between View and Window, and it is a categorically more exposed affordance than a chord
nobody can find by accident. Behind it:

- a **tone generator that REPLACES programme audio** (⌃⌥A, which the menu item now solely owns),
- a **recorder that writes `.wav` files to the Desktop**,
- a **renderer-input A/B**,
- the **desktop-audio lead ladder**.

**It is now gated, and the gate is the right shape** — `DebugMenuGate`,
`App/ManifoldApp.swift:279-325`, consulted at `App/ManifoldApp.swift:220`:

- `defaults write com.graviton.manifold manifold.debugMenu -bool YES` — the primary, because it
  survives relaunch and works with an ordinary double-click launch. Same shape as
  `DeckLinkService.audioTrimKey`.
- `MANIFOLD_DEBUG_MENU=1` — a single run that leaves nothing behind. Same shape as
  `ScrubFrameProducer.stats`.
- **Latched once at first read** (`static let` with an initialiser closure), so a menu cannot
  disappear while a keyboard shortcut it owns stays live.
- It announces itself in the log when on, and is silent when off.

Commit `4114995`, *"fix: gate the Debug menu behind an explicit opt-in"*.

⚠️ **SO WHAT IS LEFT FOR THIS ENTRY IS THE DECISION, NOT THE GATING.** The Debug menu is handled.
The four hidden-keystroke triggers in the table above are not, and the pre-launch question is
unchanged and still unanswered: **should a public build carry them at all?** Note that ⌃⌥⇧E
(writes a PNG) and ⌃⌥H / ⌃⌥D (open network connections from saved bookmarks) have side effects of
the same kind that justified gating the menu — they are just harder to trigger.

⚠️ **AND THE GENERAL LESSON, WHICH IS THE REUSABLE PART:** this entry enumerated a closed set and
was then overtaken by a surface that did not exist when it was written. **A dev-path audit is not a
list, it is a recurring check** — the same conclusion the American English entry above reached
independently, and for the same reason. Both want a preflight, not a memory.

---

## ☐ PRE-SHIP: stream bookmarks have no durability story — no backup, no export, one key

**Status:** OPEN, required before public launch. **NOT a blocker** — nothing ships broken, and the
app does not lose the list on its own. **Raised:** 2026-09-21, after the `streamBookmarks` defaults
key was erased during LIVECLOCK verification and there was no way back: no snapshots, no Time
Machine, no store-side backup. **Done means:** a user can get their saved streams out of the app
and back in — see *What "done" means* below.

### What exists, and what does not

`StreamBookmarkStore` (`App/Preferences.swift`) holds the entire saved-stream collection as one
JSON blob under a single `UserDefaults` key, `streamBookmarks`, in
`~/Library/Preferences/com.graviton.manifold.plist`. There is:

- **no backup** — no second copy, anywhere, at any point;
- **no export** — no way to get the list out of the app, for support, for a move to another Mac,
  or for a user who just wants their own connection details written down;
- **no import** — so even a user who has the bytes has nothing to do with them.

**The whole collection lives or dies with that one key**, and `defaults write` replaces a key's
value wholesale rather than merging into it. One wholesale write — from a script, from a terminal
one-liner, from a well-meant automation — takes every saved connection at once. That is what
happened on 2026-09-21. The corresponding rule now lives in `CLAUDE.md`.

### ⚠️ THE STORE'S EXISTING PROTECTION IS REAL AND DOES NOT COVER THIS

This is worth stating precisely, because the code reads as though the problem is already solved.
`storedDataUnreadable` and the `persist()` guard are a careful piece of work: if the key exists and
this build cannot decode it, the list shows empty, `add` refuses with `.storeUnreadable`, and
nothing is written over the original bytes. The write-up on that flag is right about the failure it
describes.

**But every one of those defenses is against THE APP destroying the list.** The store watches its
own writes. It has no view of, and no defense against, a write to that key from outside the
process — which is both the cheaper failure to cause and the one that has actually occurred. The
bytes it so carefully declines to overwrite are simply gone, and `init` then takes the fresh-install
branch: no key, empty list, `storedDataUnreadable` false, nothing in the log. **The loss is
indistinguishable from never having saved anything.**

### The passphrases are a second half, and losing the key ORPHANS them

`migratePassphrasesToKeychain` moves SRT passphrases out of the plist and into the Keychain, keyed
by `bookmark.id.uuidString`. That is right on its own terms and should not change. It does mean:

- **Losing the defaults key strands the Keychain items.** They survive the erasure intact and are
  unreachable forever, because the only thing that knew their UUIDs was the list that is gone.
  Nothing collects them; they sit in the user's keychain as anonymous entries.
- **An export has two halves with different rules.** The bookmark rows are ordinary data. The
  passphrases are secrets, and an export file carrying them in cleartext re-creates, on the user's
  Desktop, exactly the exposure the Keychain migration existed to end. The default should be to
  export WITHOUT passphrases and to say so plainly in the file and in the UI, with import prompting
  for the ones it needs. A passphrase-carrying export, if it is ever wanted, is a separate decision
  and needs encryption, not a checkbox.

### Why this is a pre-ship item and not a nice-to-have

A tester or a customer who loses every saved connection **has no recovery path at all** — not a
worse one, none. They cannot be talked through a restore, because there is nothing to restore from;
the best available answer is "re-enter them from memory". For anyone running more than a handful of
feeds, that answer is a support problem, and the fact that the app had no opinion about their data
is a trust problem. It is the kind of thing that gets described once, in public, in terms the
feature list does not recover from.

It is not a blocker because nothing is broken in a shipped build and no user action inside the app
triggers it. It is on this list because the day it bites, it is unfixable after the fact.

### ⚠️ EXPORT/IMPORT IS THE CHEAPER HALF AND SHOULD GO FIRST

Not just cheaper — **better value per unit of work**, and it should not wait on the backup design.

`StreamBookmark` is already `Codable` and the store already encodes the whole array to JSON on
every `persist()`. Export is a file writer over bytes that exist; import is a decode, a merge
decision, and one `persist()`. There is no scheduler, no retention policy, no background task, no
question of when a restore is safe.

And it answers the three questions a backup does not:

- **Support.** "Send me your export" is a diagnosis; "your list is gone" is not.
- **Moving Macs.** Today the only migration path is Migration Assistant carrying the whole plist.
- **The user's own copy.** Some people want their connection details in a file, in a repo, in a
  team's shared folder, independent of any one machine.

**The backup half is the one with the design questions** — where it lives, how often, how many
generations, what triggers a restore, and whether restoring merges or replaces (replacing is
itself a wholesale write, which is how this entry started). It is worth doing. It is not worth
blocking the export on.

### What "done" means

**For this item, before public launch:** a user can export their saved streams to a file and import
that file back, on this machine or another one, with everything round-tripping except passphrases,
which are named but not carried and are re-entered on import. Import states clearly whether it
merges or replaces, and a replace is confirmed rather than silent.

**Tracked separately, not required for launch:** an automatic backup of the key with at least one
prior generation, and a restore path that does not depend on the user having thought about this in
advance.

---

## ✅ FIXED 2026-09-22 — SRT killed a healthy stream ~17 s after reconnecting, blaming the broadcaster

**Status:** ✅ **FIXED 2026-09-22. Not yet through a real session** — the entry stays until it has
been. **Affects:** SRT only. **WHEP does not have it** and the reason is structural, below.

### The symptom

Connect to an SRT source, watch it for a while, disconnect, reconnect — and about **17 seconds**
later the stream dies with

> The stream stopped sending video (the broadcaster may have ended it).

Picture and audio are perfect for those 17 seconds. The broadcaster has not stopped. Reconnecting
again reproduces it, and again, until eventually one session survives and runs indefinitely.

### What was actually happening — measured 2026-09-22

Three consecutive Cloudflare reconnects were killed at **+17.00 s, +17.04 s and +16.01 s**. In every
one, at the instant of the teardown:

- **bytes were still arriving** — the final second of the first session delivered 697 KB
- **access units were still arriving** — 378 → 401 in that same second
- **pictures were still being decoded** — the session totals read `AUs=401 → 401 pictures`
- `recvTimeouts` was flat, and `[LIVECLOCK]` reported healthy depth 0.4 s before the kill

Nothing had stalled. The watchdog was wrong.

### The cause: two resets at two different times, on one counter that outlives the session

`SRTClient`'s media-stall watchdog compares `SRTFrameRouter.shared.picturesDecoded` against a
high-water mark, and tears down when the count fails to advance for `mediaStallWindow` (15 s). Both
halves are sound. The pairing was not:

| what | where it was reset | when that is |
|---|---|---|
| the watchdog's high-water mark | `startStatsTimer()` | **at connect** |
| `picturesDecoded` itself | `prepareDecoder()` | **at stream identification**, 2.9–5.4 s later |

`SRTFrameRouter` is a **process-lifetime singleton**, so between those two moments `picturesDecoded`
still holds the *previous* session's total. The 1 Hz tick at +1 s therefore saw a large non-zero
count, armed the watchdog on it, and stamped the clock. Identification then zeroed the counter, and
this session's pictures had to climb past a high-water mark **they had never set**. They never did,
the 15 s ran out, and the banner blamed the broadcaster.

The arithmetic fits every session in the log to the tick:

| session | inherited mark | new session's final count | outcome |
|---|---|---|---|
| local `127.0.0.1`, 95 s | **0** — first SRT session of the process | 2269 | survived |
| Cloudflare #1 | 2269 | 401 | killed +17.00 s |
| Cloudflare #2 | 401 | 375 | killed +17.04 s |
| Cloudflare #3 | 375 | 322 | killed +16.01 s |
| Cloudflare #4 | 322 | 2712 | **survived** — overtook 322 about a second before the deadline |

### ⚠️ Why it looked intermittent, and why nobody caught it sooner

**It is not intermittent. It is a race between two counters, and the loser is decided by how long
the previous session ran.**

A session survives only if the new count overtakes the inherited mark before the 15 s expires —
roughly `identify_delay + previous_count / fps < 16 s`. So:

- The **first** SRT session after launch always survives: nothing is inherited.
- A reconnect after a **short** session usually survives: the mark is small.
- A reconnect after a **long** session is always killed: at ~24 fps, anything over ~360 pictures
  (≈15 s of previous viewing) cannot be overtaken in time.
- Cloudflare #4 above survived by **under a second**, which is exactly the kind of margin that makes
  a deterministic bug present as a flaky one.

It also hid behind a plausible story. The banner names the broadcaster, the timing is consistent,
and on a real remote stream "the sender dropped out" is a perfectly ordinary thing to believe —
especially when reconnecting sometimes works.

### The fix

Both changes are in `App/SRT/SRTClient.swift`; neither touches `mediaStallWindow`, `firstPictureGrace`
or the 1 Hz tick.

1. **The baseline is re-taken in `handleVideoFormat`**, at the same instant and for the same reason
   the counter is zeroed. `prepareDecoder` runs inline on the session thread immediately before the
   main-thread hop into `handleVideoFormat`, so by that line the counter is provably this session's.
   This also covers a **mid-session re-identification**: a format change calls `prepareDecoder`
   again and zeroes the counter again, which would otherwise reproduce the same stale comparison
   *inside* one connection.
2. **The watchdog will not arm before `haveVideoStream`.** The stale count is never read at all,
   rather than read and then corrected. This restores what the code's own comment already claimed —
   *"a connection that never delivers one is left to the graces below, not killed here"* — which
   a non-zero inherited count had quietly made false.

### ⚠️ WHEP DOES NOT HAVE THIS, and the line that proves it

`WHEPClient` runs the identical watchdog shape (`WHEPClient.swift:421-431`) but reads
`decoder.snapshot().framesDecoded` from a **per-connection object**: `WHEPClient.swift:189` builds
`LiveVideoDecoder(logTag: "WHEP-DECODE")` fresh on every connect and `WHEPClient.swift:794` drops it
at teardown, so the counter starts at 0 with the baseline and there is no window in which a previous
session's total is visible. `logDecodeStatsTick` also opens with `guard let decoder else { return }`,
so the watchdog cannot run before that object exists.

**The difference is ownership, not logic.** SRT's counter lives on a singleton router; WHEP's lives
on an object whose lifetime *is* the connection. Any future transport that watches a counter it does
not own inherits this bug — the question to ask is not "is the watchdog right" but "does the counter
die with the session".

---

## ✅ FIXED 2026-09-21 — SRT audio distortion. TWO defects, one symptom, and the loud one was not the cause.

**Status:** ✅ **BOTH FIXED, 2026-09-21. Not yet through a real session** — the entry stays until it
has been. **Affects:** WHEP and SRT, the two transports that mirror a `LiveClock` mapping to the
audio timebase. **NDI and HLS do not** — neither drives the mirror (NDI uses `anchorLiveAudio`; HLS
holds its own clock). The PTS half is SRT-only.

### ⚠️ READ THIS BEFORE REUSING ANY OF IT: the investigation found TWO defects and closed both

They are separate, they were fixed separately, and conflating them re-tells the story wrong.

**1. THE MIRROR STOPPED EVALUATING WHEN THE P-LOOP SATURATED.** Publication is gated on the rate
*changing*; a clamped rate is bit-identical to the previously clamped one, so while the loop sat on
its ±0.5% rail nothing was published and `mirrorLiveAudio` — which is edge-driven — stopped running
entirely. Audio walked at ~5 ms/s to −113 ms, then got yanked back in one step, every 15–20 s.
**Fixed by `LiveClock.onMappingTick`**, a heartbeat at the control cadence that re-states the mapping
at the current instant whether or not it changed; the publication gate is untouched. A starvation
tripwire and a publication-gap histogram were added so the same silence cannot recur unnoticed.

⚠️ **FULL MECHANISM, MEASUREMENTS AND ARITHMETIC FOR THIS HALF: `docs/LIVECLOCK_AUDIO_MIRROR_FINDINGS.md`**,
including its §5, which rules out the obvious fix. That document is canonical for defect 1 and this
entry does not restate it.

**2. THE AUDIBLE DISTORTION WAS SOMETHING ELSE ENTIRELY — the sender's PTS grid.** Defect 1 was real,
measurable and worth fixing, and fixing it **did not stop the gravel**. The renderer probe then found
**ZERO contiguous buffers out of 468**: every audio `CMSampleBuffer` PTS was quantised to a 1 ms grid
while a 1024-frame buffer is 21.3333 ms, so consecutive buffers stepped 21 or 22 ms and missed by −16
or +32 samples in a repeating three-phase cycle, cumulative ≈ 0.
`AVSampleBufferAudioRenderer` schedules by PTS exactly, so it spliced **every single buffer, ~47
times a second** — continuous distortion rather than clicks.

**Fixed by sample-counting the PTS axis** (`SRTFrameRouter.audioPTSTicks`), following
`NDIService.audioPTSTicks` rather than inventing a second approach to the same problem: one
conversion from seconds at the anchor, then `ptsTicks = anchorTicks + cumulativeFrames`, stamped as
`CMTime(value: ticks, timescale: CMTimeScale(sampleRate))`. Buffers then tile **by construction** for
any frame size and any rate. The axis is pinned to the SOURCE PTS (not the wall clock, as NDI's is)
because SRT's video is paced from that same sender timeline, with the same 25 ms tolerance and
re-pin-without-restarting-the-counter shape.

⚠️ **FULL MECHANISM FOR THIS HALF: `docs/LIVECLOCK_AUDIO_MIRROR_FINDINGS.md` §9**, with §10 on why
every instrument missed it. Note that document's own banner: **§1–§8 were written mid-investigation,
while the dead band was believed to be the cause of the audible distortion, and it was not.** Read §9
first if you are here about distorted live audio. `SRTFrameRouter.audioPTSTicks` carries the same
reasoning at the code; `NDIService.audioPTSTicks` carries the precedent.

### ⚠️ THE REUSABLE PART, AND IT IS NOT THE FIX

**The comment block that predicted this was already sitting on the broken line.** `makeAudioSampleBuffer`
carried a note arguing a 90 kHz audio PTS was safe "by two coincidences" at 48 kHz, warning that at
44.1 kHz "every buffer boundary would be rounded and the desktop would crackle exactly as NDI's did —
with the tap, the meters and SDI all still perfect, because only the renderer uses per-buffer
timing", and closing: *"SRT's audio is measured working on the wire and is left alone."*

The prediction was exactly right and the premise was wrong. **It never needed 44.1 kHz**, because the
rounding did not happen on that line — it happened in the sender's muxer, before the value arrived,
and `preferredTimescale: 90_000` then faithfully preserved a number that could not tile. And "working
on the wire" was true and irrelevant: the wire was never the broken part, which is precisely what the
comment's own list of unaffected consumers should have suggested.

**A correct prediction filed under the wrong trigger reads as a hazard already handled.** This one
cost the evening: the WAV capture, the decoder swap to libavcodec and the renderer probe were all
built to find a fault that this paragraph had described in advance.

### What each fix is worth on its own

- **Defect 1 was not wasted work.** It is a real starvation bug, it affects WHEP as well as SRT, and
  the drift it produced was measured. It simply was not what was audible.
- **Defect 2 is the one that was heard.** A stream whose sender emits sample-exact PTS never
  triggered it, which is why local SRT sounded clean — see the open question below about whether
  local was contiguous all along or merely quantised more kindly.

### ✅ CONFIRMED IN A REAL SESSION, 2026-09-21 (was: STILL TO CONFIRM)

The renderer probe's histogram was the stated acceptance test — **`EXACTLY ZERO (contiguous)` for
essentially every buffer, with no sign alternations** — and it passed on both transports and on
both decoders then in the tree: **471/471 contiguous on Cloudflare and 164/164 on local SRT, with
`axisRePins=0`**, measured on a signed Profile build. The PTS fix is decoder-independent, which is
what made the same histogram usable as the instrument that exonerated AudioToolbox — see the
decoder-reversion entry below.

The probe's own gap comparison was corrected to use `CMTimeCompare` rather than
`Double` seconds — measured in `Double`, a perfectly tiled 48 kHz stream at a ~36 s PTS shows
residuals of ~3.4e-10 samples, which would have reported a correct fix as 467 non-contiguous
buffers.

### Superseded: the gate, the dead band and the consequence

These were written out here while defect 1 was open and are now in
`docs/LIVECLOCK_AUDIO_MIRROR_FINDINGS.md` §2–§4, which is canonical for them. They are removed
rather than left in place because this entry now says it does not restate the derivation, and a
copy that says so while carrying one is the thing this file keeps warning about.

### ⚠️ AND DEFECT 1 WAS PREDICTED TOO — by an enumeration that missed the case that happened

The NDI entry below (*"NDI had no desktop playback path"*, its section **"WHICH MEANS WHEP AND SRT
ARE ONE 'OPTIMISATION' AWAY FROM THE SAME DEFECT"**) stated this failure exactly, down to the
symptom: *"If `LiveClock` ever stops slewing, WHEP and SRT silently become unbounded too."* It then
enumerated three ways the slew could stop — `forceUnityRate`, `maxSlew = 0`, an early return on
stable depth. **All three are code changes somebody would have to make on purpose. None of them
happened.**

The fourth way is that the slew never stops at all — it saturates, and a railed rate publishes
nothing for the same reason a settled one does not. **A correct enumeration of the ways a mechanism
can be disabled by a future edit is not an enumeration of the ways it can stop working.** The
tripwires guard the code; this failure needed no edit to the code.

---

## ✅ CLOSED BY REVERSION 2026-09-21 — SRT AAC decode went to libavcodec on a premise that turned out to be wrong, and is back on AudioToolbox

**Status:** CLOSED — **one decoder again, `SRTAudioDecoder` (AudioToolbox / AudioConverter), for
every channel count.** **Raised and closed the same day, 2026-09-21.** This entry replaced one
titled *"SRT AAC decode is SPLIT between two decoders"*, which described the split as deliberately
deferred work. It is not deferred; it is undone. **Kept as a record rather than deleted,
because the reasoning that produced the split was sound and will reproduce.**

⚠️ **THE POINT OF THIS ENTRY IS THE INFERENCE, NOT THE CODE.** The code is a small revert. What is
worth a future reader's time is that a correct-looking chain of measurements pointed confidently at
the wrong stage, and nothing in the evidence said so.

### What was built, and why it was reasonable

For part of one evening the tree carried two AAC decoders behind a protocol:

| stream | decoder |
|---|---|
| ≤ 2 channels | `SRTAudioDecoderLibav` (libavcodec + libswresample) |
| > 2 channels | `SRTAudioDecoder` (AudioToolbox / AudioConverter) |

The case for the swap, as it stood at the time:

- The Cloudflare SRT feed was audibly gravel, immediately on connect, continuously.
- A WAV captured at the handoff to the renderer was **clean** — peak, RMS, sample-to-sample
  continuity and spectrum all matching a known-good local capture to within 1 dB below 20 kHz.
- `[SRT-AUDIO-PROBE]` read every packet as well-formed: 7-byte ADTS header, `frame_length` matching
  the packet, `rdblocks = 0`, 1024 frames × 2 ch.
- The **same bytes decoded cleanly through the ffmpeg CLI**, which is libavcodec.
- Local SRT was clean on identical code; only the transport with a third party's muxer failed.

Clean bytes in, gravel out, and a different decoder handling the same bytes correctly. That is a
decoder fault by every reading available at the time, and the swap was measured to help.

### Why it was wrong

**The distortion was upstream of both decoders.** Cloudflare's muxer quantised the audio PTS to a
1 ms grid, which cannot express a 1024-frame step at 48 kHz (21.3333 ms). The renderer was handed a
16-to-32-sample discontinuity 47 times a second and resolved every one. See the SRT audio
distortion entry above, and `docs/LIVECLOCK_AUDIO_MIRROR_FINDINGS.md` §9 for the full mechanism —
including §10 on why seven instruments read healthy throughout.

⚠️ **The libav swap appeared to help because it was measured against ears, over a path that also
changed.** It never addressed the PTS grid, and could not have: no decoder sees it.

### The measurement that closed it

After the sample-counted PTS axis (`SRTFrameRouter.audioPTSTicks`) landed, two signed Profile
builds were cut from the same tree, differing only in the selection line, both Developer ID signed,
and run against the same sources:

| build | decoder | Cloudflare | local SRT |
|---|---|---|---|
| A | libavcodec (`useLibav = channelCount <= 2`) | contiguous | contiguous |
| B | **AudioToolbox (`useLibav = false`)** | **471/471 contiguous, `axisRePins=0`** | **164/164 contiguous, `axisRePins=0`** |

**Build B was clean on Cloudflare and on local, by ear and by histogram.** The premise that put
libav in the tree — that AudioToolbox mis-decodes this feed — is therefore not merely unproven but
**tested and false**.

### What was removed

- `App/SRT/SRTAudioDecoderLibav.swift` — deleted, and with it the `[SRT-AUDIO-PROBE] pkt%d libav.*`
  packet probe that lived in it.
- `App/SRT/SRTAudioDecoding.swift` — the protocol, deleted. `SRTFrameRouter.audioDecoder` is the
  concrete `SRTAudioDecoder?` again, with no `any` existential and no selection branch.
- The `[SRT-AUDIO] decoder: …` log line — deleted. It existed to name which of two indistinguishable
  decoders ran; with one decoder it reports a compile-time constant, and the `[SRT-AUDIO] stream …`
  line already carries the rate, channel count and framing.

`SRTAudioDecoder`'s ADTS machinery (`parseADTS`, `audioSpecificConfig`, `esds`, the cookie state
machine) was never removed and is now the only path again.

### ⚠️ What did NOT get closed by this, and must not be read as closed

The superseded entry carried a channel-order section that looked like new work created by the
split. **It was not new.** The split added a second, libav-specific channel-order question, and
that question died with the libav decoder. What survives is the **original 2026-08-26 item, which
predates all of this and is untouched by it**:

> **SDI carries the monitored track's channels discretely, in FILE order, and never states the
> mapping** — see that entry below. `d[c] = s[c]` at `App/DeckLink/DeckLinkBridge.mm:585`, no role
> table, roles published at the seam (`AudioTapBuffer.Format.roles`) and consumed by nothing in
> `App/DeckLink/`.

**That was true before tonight and is still true.** It is a property of the SDI output path, not of
the AAC decoder, and reverting the decoder neither helped nor hurt it.

Within `SRTAudioDecoder` itself the ask-then-verify sequence for AAC channel order is intact and is
the thing to trust: translate the mux's mask to CoreAudio positions, REQUEST that order from the
converter, **read the property back**, and label from what came back — because
`AudioConverterSetProperty` returning `noErr` says the property was accepted, not that the decoder
reordered. Any failure at any step means no layout at all and channel numbers on the meters.

### 📌 NOTED, NOT ACTIONED — the one argument for libav that this evening did not test

libavcodec has an **`aac_latm`** decoder (confirmed in the vendored build's decoder enumeration:
`aac aac_latm dnxhd pcm_* prores`), and `SRTFrameRouter.handleAudioFormat` **refuses LATM/LOAS
outright** — an MPEG-TS feed with PMT stream type 0x11 gets a loud refusal and no audio.

**That is a real capability gap and a legitimate reason to revisit libav later.** It is recorded
here so it is not lost, and deliberately not folded into this entry as work:

⚠️ **It must not ride along on the swap that was just reverted.** A LATM decoder is a different
justification, it would need its own measurement, and — if it were ever to handle more than stereo
— its own channel-order derivation, established by measurement on a fixture with identifiable
content per channel rather than read out of libav's headers. Re-deriving channel order at speed is
how the 5.1 mislabelling arrives: dialogue on Left, LFE on a surround, six correctly-labelled
meters, nothing looking broken anywhere.

### The transferable part

**A decoder swap that "fixes" an audible fault is not evidence that the decoder was broken**, when
the swap was evaluated by listening and the real fault is a timing property that no decoder can
see. The A/B that settled it took two signed builds differing in one line, run against a
per-event instrument (the renderer gap histogram) rather than against ears — and it was only
possible to state the result cleanly because the histogram measures each buffer boundary instead of
aggregating. The instrument that exonerated AudioToolbox is the same one that convicted the PTS
grid.

---

## 🔍 OPEN — the Cloudflare SRT path runs 20–190 ms deep against a 0.250 s target, and nothing explains why

**Status:** OPEN — **UNEXPLAINED. Not investigated.** Measured 2026-09-21 across three Cloudflare
runs against one local control run. **Filed separately on purpose** — see the boundary below.

### The measurement

| | depth error vs `targetDepth` 0.250 s | P-loop rate |
|---|---|---|
| local SRT source | within **±13 ms** | modulates freely, 0.9950…1.0050 |
| Cloudflare SRT | **+20 ms to +190 ms**, continuously | pinned at 1.0050 on nearly every line |

Packet arrival is **equally steady on both**. The depth is not explained by anything the clock can
see, and `[SRT-FLOW] depth` still swings 0.21 → 0.47 within a second while arrivals stay even.

### ⚠️ THE BOUNDARY, AND IT IS THE REASON THIS IS NOT FOLDED INTO THE ENTRY ABOVE

**Fixing the publication gate does not fix this, and must not be recorded as having done so.** The
gate fix makes the *audio symptom* impossible. The transport still runs deeper than it should, which
is a latency cost on its own terms and may be a defect of its own. Two changes, two verifications.

The relationship runs one way: this is the **root**, the dead band is the **mechanism**, the audio
drift is the **consequence**. That ordering is what makes them separable — a stream that sat within
±13 ms would never enter the dead band, and a stream that never left the dead band would drift even
with a perfect transport.

### Candidates, none investigated

Carried from §7 of `docs/LIVECLOCK_AUDIO_MIRROR_FINDINGS.md`, which is where any evidence should
accumulate:

- **Access-unit-level pacing** rather than packet-level — steady arrivals, uneven presentation units.
- **The reorder budget against `pts − dts`.** Every Cloudflare run logs *"reorder delay 0.208 s is
  within 75% of targetDepth 0.250 s — the margin protecting the PTS-ordered insert is thin."* The
  local path does not carry that warning in the same terms.
- **The queue never draining to setpoint after the connect burst** — the startup anchor discards
  2.1–3.2 s, and `[SRT-BACKLOG]` shows the surplus persisting all session within its stated bound.
- **Cloudflare's SRT egress is a TRANSCODE of the WHIP/WebRTC ingest, not a passthrough** — so the
  pacing is its encoder's, not the sender's. The local test bypasses that stage entirely, which is
  exactly why it is a weak control for this question.

⚠️ **The local run is a good control for the CLOCK and a poor one for the TRANSPORT.** It settled
which half of the system was at fault, and that was worth having. It cannot tell us anything about
what Cloudflare's transcoder does to pacing, because it never touches it.

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

## ⚠️ UNMEASURED: scrub release jumps the picture once, on ProRes — and the fix that closed it no longer exists

**Status:** ⚠️ **UNMEASURED ON CURRENT CODE. Do not read this entry as "fixed, awaiting
confirmation" — it was, and that is no longer what it is.** **Reported:** 2026-08-27 by Joey on
0.6.2; **direction corrected by him the same day.** **Never reproduced** on the build Mac.
**Blocks:** nothing; it is a trust problem — a colourist who sees the picture move after they let
go stops believing the scrub.

> ### ⚠️ RESTATED 2026-09-21 — THE ENTRY WAS DESCRIBING A MECHANISM THAT HAS BEEN DELETED
>
> **What happened, in order:**
>
> 1. **2026-08-27** — the tolerance mechanism was REFUTED by measurement; the staleness mechanism
>    matched the report in magnitude and sign; a two-part fix was built in `ContentView`
>    (`requestScrubPreview(at:final:)` plus a handoff that held the overlay until the seeked-to
>    frame was on screen). Status became "FIXED, awaiting confirmation from Joey".
> 2. **2026-08-30** — Stages 3 and 4 of *"two producers, one destination"* **deleted the entire
>    mechanism that fix lived in.** `scrubPreviewImage`, `requestScrubPreview`,
>    `beginScrubHandoff`, `holdScrubOverlayUntilPresented`, `previewImage`, `LibavThumbnailSource`
>    and `onFirstPresentAfterFlush` are all gone. A grep for `scrubPreview` across `App/` and
>    `Packages/` returns **nothing**. There is no `CGImage` in the scrub path at all.
> 3. **Nobody re-asked the question.** The status line stayed at "FIXED 2026-08-27, awaiting
>    confirmation" for three weeks, describing a fix to code that no longer exists.
>
> **So the honest state is: the original report has never been confirmed, and the current code has
> never been tested against it.** The 2026-08-27 fix is not "still in"; it is not anywhere. What
> replaced it is a different mechanism with different failure modes.
>
> ⚠️ **AND THIS IS NOT MERELY BOOKKEEPING — THE ENTRY ITSELF PREDICTED A SURVIVING RESIDUE.**
> Read *"A RELEASE SETTLE THEREFORE SURVIVES THE OVERLAY'S DELETION, ON LONG-GOP ONLY"* below,
> written before the deletion: the scrub producer seeks at infinite tolerance and `exactSeek` does
> not, so the seek's first frame can differ from the frame the drag was showing — **zero on MXF by
> construction, effectively zero on ProRes, up to 10.4 frames on 4K H.264.** That is a *prediction*
> about the current code and it has never been checked against the gesture.
>
> **Joey's report was on ProRes**, which is the case that prediction says should be clean. That is
> encouraging and it is not evidence.
>
> ### What would settle it — and it is cheap
>
> 1. **Ask Joey to re-test on a current build.** The report is 0.6.2; the scrub path has been
>    rewritten twice since. This costs one message and is the single highest-value action here.
> 2. **Run the `[SETTLE]` instrument on ProRes.** It was kept deliberately
>    (`MetalVideoRenderer.reportSettleIfArmed`) and it is exactly the measurement this needs —
>    Stage 3 used it to report **+0.00 frames across 7 consecutive releases on MXF**. The same run
>    on a ProRes fixture either closes this entry or reopens it with a number.
> 3. **If it is non-zero on long-GOP, the deferred way out is already scoped**: seek playback to the
>    frame the producer actually DELIVERED rather than to `scrubValue`. See §2 of the
>    two-producers entry.
>
> **Everything below this line is the 2026-08-27 investigation**, kept in full: the measurements are
> sound, the three measurement traps are reusable, and the refutation of the tolerance mechanism is
> still a correct result about a real mechanism. Read *"The fix, as BUILT 2026-08-27"* as history —
> it already carries its own strike, added 2026-08-30.

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
mark this fixed when that route is built.** See *"✅ BUILT 2026-08-30 — feed the scrub gesture from
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
interacts with this entry directly. See *"📐 two producers, one destination"*
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
   deletes.** It closes at **Stage 3** of *"📐 two producers, one destination"*,
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

⚠️ **The app's OWN `[EDR] headroom` line made exactly this misreading, and is FIXED (2026-09-22).**
It appended `<<< NO HEADROOM — EDR is inert on this display` whenever `current <= 1.0001`, ignoring
`potential` — a claim about the DISPLAY made from a number about the LAYER — and was observed
printing it on the LG in macOS HDR mode while `potential = 8.9654`. `logEDRHeadroom` now reports
three separate states (no headroom / available but not granted / granted), so rule 1 above is
enforced by the instrument instead of relying on whoever reads it. See
`docs/COLOR_MANAGEMENT_FINDINGS.md` §6.7.

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
   MOVED TO ITS OWN ENTRY:** *"✅ BUILT 2026-08-30 — feed the scrub gesture from `AVPlayerItemVideoOutput` —
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

## ✅ BUILT 2026-08-30 — feed the scrub gesture from `AVPlayerItemVideoOutput` — one decoder, one display path

**Status:** ✅ **BUILT 2026-08-30. No longer banked.** **Spiked:** 2026-08-29 with
`docs/scrub-fixtures/avpvomeas.swift`; **implemented** across Stages 0–4 of *"📐 two producers, one
destination — deleting the scrub overlay"* below. **Raised:** 2026-08-28, out of the HDR scrub
investigation. **Closed in the audit of 2026-09-21**, which found the status line still reading
"BANKED and NOT BUILT" three weeks after the work landed.

> ### ✅ WHAT CLOSED IT
>
> The producer is selected on the decode path and both halves exist:
>
> ```swift
> let producer: ScrubFrameProducer = useLibav
>     ? LibavScrubProducer(url: url, pixelFormat: videoPixelFormat)
>     : AVPlayerScrubProducer(url: url, pixelFormat: videoPixelFormat)
> ```
>
> — `ManifoldCore/FrameEngine.swift:1229-1231`, with
> `ManifoldCore/AVPlayerScrubProducer.swift` and `ManifoldCore/LibavScrubProducer.swift` behind the
> `ScrubFrameProducer` protocol. **The `CGImage` overlay no longer exists**: `scrubPreviewImage`,
> `requestScrubPreview`, `previewImage`, `holdScrubOverlayUntilPresented` and
> `LibavThumbnailSource` are all deleted, and a grep for `scrubPreview` across `App/` and
> `Packages/` returns nothing.
>
> **Everything below this line is the reasoning as it stood before the work**, kept because the
> three-uses argument is what justified the cost and is the part worth re-reading if the route is
> ever revisited. Per-stage results are in *"✅ MEASURED 2026-08-30 — Stage 3"* below.

⚠️ **THE IMPLEMENTATION IS NOW SCOPED — see *"📐 two producers, one
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
**and for HLS as a source**, see *"✅ SHIPPED — HLS as a source"* below.

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
**HLS as a source** — see *"✅ SHIPPED — HLS as a source — a VIEWER/QC feature on the egress side"*
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
*"✅ BUILT 2026-08-30 — feed the scrub gesture from `AVPlayerItemVideoOutput`"* above for the AVFoundation half
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

## ✅ SHIPPED — HLS as a source — a VIEWER/QC feature on the egress side

**Status:** ✅ **SHIPPED.** Picture, audio, metering, SDI and frame-rate detection all landed across
2026-09-08 → 2026-09-18. **Raised:** 2026-08-28. **Was gated on:** *"feed the scrub gesture from
`AVPlayerItemVideoOutput`"* above — the gate passed 2026-08-29 and the route was built 2026-08-30.
**Closed in the audit of 2026-09-21**, which found this entry still reading "BANKED, not built…
There is no HLS code beyond that" against roughly 148 KB of shipping HLS source.

> ### ✅ WHAT CLOSED IT
>
> - `App/HLS/HLSClient.swift` — the client, on `AVPlayer` exactly as "Why this is now coupled"
>   below argued it would be, with frames pulled out into the app's own shader/offscreen/scopes/SDI
>   path rather than left on an `AVPlayerLayer`.
> - `App/HLS/HLSAudioTap.swift` — audio metered, embedded on SDI and monitored on the item's own
>   clock; see *"✅ WHAT LANDED, 2026-09-17 — HLS audio"* below.
> - `App/Preferences.swift:309` — the gate this entry named is now `var isSupported: Bool { true }`,
>   and the honest-refusal seam is deliberately kept for a fourth transport
>   (`App/Preferences.swift:304` records why). The `"HLS — not yet supported"` string survives
>   nowhere but in that comment, describing its own removal.
> - `App/HLS/HLSClient.swift:1262` — the `[HLS] colour signalling` line, which is what exposed the
>   CICP primaries entry below.
>
> **The SRT-vs-HLS table below is the part still worth reading** — it is about what each transport
> is FOR, which shipping one of them did not settle. It is kept verbatim.

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

## ✅ FIXED — DeckLink enumeration diagnostics cannot distinguish two different failures

**Status:** ✅ **FIXED — both recommendations, implemented as written.** **Found:** 2026-08-27,
while diagnosing the entry above. **Closed in the audit of 2026-09-21.** **Blocked:** nothing at
runtime — it cost diagnosis time, and it cost a full code read the week it was found.

> ### ✅ WHAT CLOSED IT
>
> - **The raw iterator count is now carried out of the loop.** `NSInteger total = 0` at
>   `App/DeckLink/DeckLinkBridge.mm:985`, incremented on every `Next()` at `:997` regardless of the
>   output filter, and returned alongside the usable list in a `DeckLinkEnumerationResult`.
> - **Every rejected device carries its `HRESULT` and its model name.** `App/DeckLink/DeckLinkBridge.mm:1027-1031`
>   builds a `DeckLinkRejectedDeviceInfo`; the model is read from `IDeckLink` *before* the
>   `QueryInterface`, on both branches, precisely because "the device worth naming is the one whose
>   output interface is not reachable" — the bridge comment at `:1000-1006` states that reasoning.
> - **Both counts are printed in one line, always, even when they agree.**
>   `App/DiagnosticsExport.swift:744-752` — `"N enumerated, M usable"`, with `"none enumerated (no
>   device returned by the driver)"` reserved for a genuine zero; `:759-762` appends one
>   `rejected …` line per filtered device.
>
> That is exactly the `"3 device(s) seen, 0 output-capable"` shape this entry asked for, plus the
> `E_NOINTERFACE`-against-a-known-model line that is the whole diagnosis at a glance.

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

### The fix, as it was scoped — and it is what was built

- **Report the raw iterator count alongside the output-capable count.** `"3 device(s) seen, 0
  output-capable"` names the fault on sight; `"none enumerated"` actively misdirects toward cabling
  and hot-plug.
- **Log the `HRESULT` when the filter rejects a device**, with the model name, which is readable
  from `IDeckLink` before the `QueryInterface`. `E_NOINTERFACE` against a known model is the whole
  diagnosis in one line.

**Both landed.** See "WHAT CLOSED IT" at the top of this entry for the file:line evidence.

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

## PARTLY FIXED — A failed WHEP connect puts the server's entire HTML error page into the UI and the diagnostics file

**Status:** **PARTLY FIXED — the cap landed, the HTML detection did not.** **Found:** 2026-08-24,
during Run C of the Wi-Fi streaming tests (`docs/WHEP_LOADED_NETWORK_FINDINGS.md` §8).
**Re-audited 2026-09-21.**

> ### ✅ WHAT LANDED — the generalising half, at the right place
>
> This entry argued that the cap *"belongs at the point the message is stored, not at each display
> site"*. **That is where it is.**
>
> - `App/WebRTC/WHEPClient.swift:495-511` — `serverMessage(fromBody:)` caps at **200 characters**
>   with an ellipsis, and it is the single funnel: `:559-561` is where `lastError` is assigned, so
>   the banner and the diagnostics export inherit the cap without either knowing about it.
> - **JSON is handled better than the entry asked for.** A JSON body is parsed for a known human
>   field (`errorDescription`, `error`, `message`, `detail`, `reason`) and, failing that, returns
>   `nil` rather than dumping raw JSON at the user — `App/WebRTC/WHEPClient.swift:501-509`.
> - The log is separately capped at 500 characters (`:556`), and the doc comment records that the
>   body is the server's own text and is never concatenated with our endpoint URL.
>
> The 241 KB diagnostics file and the 78 KB banner cannot recur. **That was correctly identified as
> the half that matters more, and it is done.**
>
> ### ❌ WHAT REMAINS — HTML detection, and 200 characters of markup is not an error message
>
> **There is no `Content-Type: text/html` check and no `<!DOCTYPE` / `<html` body sniff anywhere in
> `App/WebRTC/WHEPClient.swift`.** So the Slack case now produces a banner that is **200 characters
> of `<div>`** instead of 78 KB of it.
>
> ⚠️ **THAT IS A SMALLER FAILURE OF THE SAME KIND, NOT A FIX.** The cap solved *legibility of the
> file*; it did not solve *legibility of the message*. A user who pastes a Slack permalink still
> gets a wall of markup where a sentence should be — shorter, and no more actionable. The original
> recommendation stands unchanged and is now the entire remaining scope:
>
> > Say *"this URL returned a web page, not a WHEP endpoint; check that you pasted the
> > publish/playback URL"* and discard the body.
>
> It is a few lines at the same site the cap already occupies (`serverMessage(fromBody:)` sees the
> body; the response's `Content-Type` is available at `:555`), and it is worth doing precisely
> because pasting the wrong URL is the most likely first-run mistake a new user makes.

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

- ❌ **Detect an HTML response and do not show it.** A `Content-Type` of `text/html` (or a body
  starting `<!DOCTYPE`/`<html`) means the endpoint is not a WHEP server. Say that — "this URL
  returned a web page, not a WHEP endpoint; check that you pasted the publish/playback URL" — and
  discard the body. **NOT DONE — this is the whole of what is left.**
- ✅ **Cap what any transport error can put into a banner or the diagnostics file**, independently
  of the HTML check. HTML is the case that turned up; a server returning a large JSON blob or a
  plain-text stack trace would do the same thing. A few hundred bytes is more than enough for any
  message a user can act on, and the cap belongs at the point the message is stored, not at each
  display site. **DONE — 200 characters, at the storage point.** See the status block above.

The second half is the one that generalises. Fixing only the HTML detection leaves the same defect
one unusual server response away.

⚠️ **THE ORDER THEY LANDED IN IS WORTH NOTING, BECAUSE IT READS AS DONE AND IS NOT.** The
generalising half went in first, which was the right call — it is the one that protects against
responses nobody has seen yet. But it also removed the *visible* symptom, and a 200-character
banner of markup is quiet enough that the remaining half can sit indefinitely. **A cap is not a
diagnosis.**

---

## The vendored libdatachannel has no provenance chain, and it now carries a required patch

**Status:** OPEN — **still true, and the README the fix called for now exists and states the gap
itself.** **Found:** 2026-08-25, during the WHEP NACK work. **Re-audited 2026-09-21.**

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

### ⚠️ RE-AUDITED 2026-09-21 — HALF THE ARTIFACT EXISTS, AND IT DOCUMENTS ITS OWN ABSENCE

**`ThirdParty/libdatachannel/README.md` now exists**, and it is a good document: it records the tag
(`v0.24.5`, MPL-2.0, arm64), the archive inventory, the patch and why it is load-bearing, and a
verified C++ dialect match against the app target including the `CMAKE_CXX_EXTENSIONS=OFF` detail
that makes `-std=c++17` rather than `-std=gnu++17`.

**What it does NOT contain is the thing this entry is about.** Its own *Provenance* section,
`ThirdParty/libdatachannel/README.md:65-70`, says so in as many words:

> ⚠️ **There is no provenance chain for this directory.** `scripts/build_libdatachannel.sh`
> does not currently complete on this machine (submodule fetch fails), so the archives here
> were produced by a hand-driven build rather than by the script. Unlike `ThirdParty/ffmpeg/`,
> nothing in the repo establishes what is actually in them. See the entry in `docs/BUGS.md`.

**No hashes are recorded** — a search of that README for `sha256` / `shasum` / `hash` returns
only that Provenance heading.

⚠️ **SO THE TWO DOCUMENTS NOW POINT AT EACH OTHER AND NEITHER CLOSES ANYTHING.** That is not
useless — a documented gap is better than a silent one, and anyone who opens the README learns the
truth immediately. But it is worth being exact about what changed: **the gap is now discoverable,
and it is the same size it was.**

**The remaining work is unchanged and both halves are still required:**

1. A `build_libdatachannel.sh` run that completes end to end on a clean checkout — the submodule
   fetch is the blocker and has not been touched.
2. Artifact hashes recorded in that README, the way `ThirdParty/ffmpeg/README.md` records its own.

**Blocks:** nothing today. It blocks *confidence* — specifically the ability to answer "is the
NACK patch in the library this DMG shipped with?" from anything other than a live test. The three
guards listed above (the script's own assertion, the bridge's refusal log line, and the
`nacks built / toWire / refused` split in the session summary) are what stands in for it, and none
of them is a provenance chain.

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

## ✅ FIXED — WHEP and SRT carry no audio at all, so a remote stream cannot be monitored or metered

**Status:** ✅ **FIXED on both transports.** **Found:** 2026-08-26, during the audio-meter audit.
**Closed in the audit of 2026-09-21**, which found the status line still reading OPEN long after
both decoders shipped. **Blocked:** audio monitoring and metering on the two remote-contribution
paths — which, as "Why it matters more than it looks" below argues, is where metering matters most.

> ### ✅ WHAT CLOSED IT
>
> **WHEP decodes Opus via AudioToolbox, exactly as the DECIDED section below specifies** — the
> libopus-vs-libavcodec question was never reopened and the vendored dylibs were never rebuilt.
>
> - `App/WebRTC/WHEPAudioDecoder.swift:93` — `WHEPOpusDecoder(channelCount:)`, an
>   `AudioConverter` over `kAudioFormatOpus`.
> - `App/WebRTC/WHEPAudioReceiver.swift:43` holds it; `:102` constructs it at negotiation; `:112`
>   logs `"no Opus decoder — audio disabled for this session"` when the platform declines.
> - `ManifoldWHEPDiscardMessage` is gone — packets are delivered to `receive(_:rtpTimestamp:)`
>   (`App/WebRTC/WHEPAudioReceiver.swift:138`) rather than dropped.
>
> **SRT decodes its audio elementary stream.**
>
> - `App/SRT/SRTAudioDecoder.swift:40` — the decoder; `App/SRT/SRTFrameRouter.swift:1026`
>   constructs it from the demuxed format.
> - The log line this entry quoted as evidence of the gap —
>   `"stream %u: %s / %s (ignored — audio is a later arc)"` — **no longer exists anywhere in the
>   tree.**
>
> **NDI was correctly excluded from this entry and still is**, though its audio path turned out to
> have a defect of its own — see *"⚠️ #NDI-AUDIO — FrameSync was asked for the queue depth"* below,
> which is a different failure and not a reopening of this one.

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

**Status:** OPEN — **still true at the wire, and one of its consequences has gone from
hypothetical to LIVE.** **Found:** 2026-08-26, during the DeckLink audio-path audit that preceded
the track selector. **Re-audited 2026-09-21.** **Blocks:** trustworthy surround monitoring over SDI.
(It does **not** block stereo monitoring over SDI — that is an optional capability, not a defect;
see the BANKED entry below.)

> ### ⚠️ RE-AUDITED 2026-09-21 — what moved, and the one thing that changed status
>
> **The defect itself is untouched.** The mapping is still `d[c] = s[c]` at
> `App/DeckLink/DeckLinkBridge.mm:585` — source channels to wire channels 1..n in file order, no
> role table, no stated mapping. `IDeckLinkProfileAttributes` / `BMDDeckLinkMaximumAudioChannels`
> are still never queried, and `bmdVideoConnectionUnspecified` is still passed
> (`App/DeckLink/DeckLinkBridge.mm:296`, `:1135`), so the app still cannot tell SDI from HDMI.
>
> **But half the groundwork this entry scoped has landed on its own.** The work item was *"publish
> the role derivation, carry the role array on `AudioTapBuffer.Format`, and replace `d[c] = s[c]`
> with a role→wire-index table"* — **the first two are done:**
>
> - `ManifoldCore/AudioTapBuffer.swift:54` — `public var roles: [String] = []` on `Format`, with
>   the contract stated at `:256-262`: the producer's DECLARED per-channel roles in interleave
>   order, empty when it declares none.
> - `ManifoldCore/AudioChannelLayoutBridge.swift` — the derivation, extracted and published, fed
>   at `ManifoldCore/AudioTapBuffer.swift:237-243`.
>
> **So what remains is the third step alone: a role→wire-index table in `RenderAudioSamples`.** The
> roles are already at the seam; nothing consumes them on the DeckLink side yet — `roles` does not
> appear anywhere in `App/DeckLink/`.
>
> ### ⚠️ AND THE "PHASE-1 CONSEQUENCE" BELOW IS NOW LIVE, NOT HYPOTHETICAL
>
> The last section of this entry reads *"One phase-1 consequence to fold in"* and describes the SDI
> monitor blinking when a track switch changes the channel count. **It was written in the future
> tense because the track selector did not exist yet. It ships now** — see
> *"✅ FIXED — A file's second and third audio tracks are unreachable"* below, closed in this same
> audit.
>
> **Which means a user can reach it today:** open a file whose tracks differ in width (the
> `MONO_STEREO_51.mov` fixture is exactly this — mono, stereo, 5.1), have SDI output running, and
> switch tracks. The count change fires `AudioTapBuffer.onFormatChange` →
> `DeckLinkService.audioFormatChanged`, the card re-establishes, **and the stop/start takes the SDI
> VIDEO with it.** The monitor blinks.
>
> **The fix is already stated below and has not changed:** enable at a count sized to the file's
> **widest** track and pad the narrower ones, after which no track switch changes the enabled
> format and SDI never re-establishes. It belongs here rather than in the track-selector entry,
> because the card's rate and channel count are fixed at `EnableAudioOutput` and genuinely cannot
> change under a running stream.
>
> ⚠️ **This is the ordinary shape of a dependency closing: the blocking entry got fixed and its
> consequence landed in THIS entry without anyone editing this entry.** Worth noting as a pattern —
> a "gated on X" note becomes live the day X closes, and nothing announces it.

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

## ✅ FIXED — A file's second and third audio tracks are unreachable, while the inspector reports all of them

**Status:** ✅ **FIXED — BOTH halves, AVFoundation and libav.** **Found:** 2026-08-26, during the
audio-meter audit. **Closed in the audit of 2026-09-21**, which found the status line still reading
OPEN with the plan marked "not yet implemented". **Blocked:** monitoring any audio track but the
first — which for a mixed-deliverable file is most of them.

> ### ✅ WHAT CLOSED IT
>
> **The phase-1 plan below was built essentially as written**, including the two entry points and
> the rebuild-at-the-playhead switch.
>
> - **One shared selection.** `ManifoldCore/FrameEngine.swift:325` —
>   `@Published private(set) var selectedAudioTrackIndex`, deliberately NOT branched per path, with
>   the invariant *row N is decoded stream N* stated on the declaration.
> - **The AVFoundation half.** `ManifoldCore/FrameEngine.swift:355` resolves the monitored
>   `AVAssetTrack` from that index; `:2607` builds the reader from it. `loadTracks(…).first` is
>   gone. `selectAudioTrack(_:)` at `:1066` rebuilds the audio reader **at the playhead, not at
>   zero** — exactly the cost of a seek to the current position, as predicted.
> - **The libav half.** `ManifoldCore/LibavAudioSource.swift:203-214` makes **one pass over
>   `nb_streams` collecting every audio stream rather than breaking at the first** — the comment
>   says so in those words. `selectStream` (`:435`) and `rebindOnPump` (`:481`) rebind the decoder
>   to a different `AVStream` of the same file, positioned at the playhead, with the demuxer, video
>   source, video renderer and `synchronizer.rate` all untouched.
>   `ManifoldCore/FrameEngine.swift:1110` translates the UI's array POSITION through
>   `streams[N].streamIndex`, inside the engine, so no UI carries a libav detail.
> - **Failure is handled rather than assumed away.** `revertLibavAudioSelection`
>   (`ManifoldCore/FrameEngine.swift:1147`) puts the selection back when a stream has no usable
>   decoder — a real state, because `open()` enumerates from `codecpar` and never asks whether a
>   decoder exists.
> - **Both entry points, mirrored.** Toolbar picker:
>   `App/ContentView.swift:2026` (`audioTrackBinding` → `engine.selectAudioTrack`). Inspector:
>   `App/InspectorPanel.swift:147-152`, which marks the monitored row and gates row selectability on
>   `engine.audioTrackCount` — deliberately NOT on `metadata.audioTracks.count`, so the inspector's
>   list stays COMPLETE even where the engine can bind nothing.
> - **The app no longer disagrees with itself**, which this entry correctly identified as the actual
>   defect: `audioTrackCount` (`ManifoldCore/FrameEngine.swift:349-352`) counts what a decoder can
>   be BOUND TO, per path, and the inspector reports what the file CONTAINS. Two questions, two
>   numbers, neither pretending to be the other.

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
- ~~**The libav path cannot offer the choice.** MXF/DNxHR files hold no `AVAssetTrack` list, so a
  multi-track MXF still cannot be switched. That is a separate implementation, not a wiring gap,
  and the UI must say so rather than offering a control it cannot honour.~~
  ⚠️ **STRUCK — THIS WAS CORRECT AS A SCOPING NOTE AND IS FALSE AS A STATEMENT ABOUT THE CODE.**
  It was right that the libav path is a *separate implementation* rather than a wiring gap. It was
  wrong to conclude that the choice therefore could not be offered: the separate implementation was
  **built**. `LibavAudioSource` selects by `AVStream` index
  (`ManifoldCore/LibavAudioSource.swift:435`) and the engine translates array position to stream
  index at `ManifoldCore/FrameEngine.swift:1110`, so **a multi-track MXF switches today** and the
  UI honours the control on both paths. The residual truth in the original bullet is narrower and
  still worth knowing: the counts come from different sources per path
  (`FrameEngine.audioTrackCount` branches on `useLibav` because counting `audioTracks` reported 0
  while four MXF streams were selectable), and the `.mov`-DNxHR sub-path takes AVFoundation's rows
  with a nil `sourceStreamIndex`.

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

## ✅ FIXED — the clean aperture was applied to the window's SHAPE and never to the PIXELS, so every ARRI open-gate file drew 1.1% narrow

**Status:** ✅ **FIXED — Option A LANDED.** Cause confirmed 2026-09-08 by measurement; the fix is in
the tree. **Found:** 2026-09-07, while chasing black bars that appeared after the pixel-aspect fix.
**NOT a regression from that fix** — the defect was as old as clean-aperture support; the fix only
changed the drawable's shape and made it visible. **Closed in the audit of 2026-09-21**, which found
the status line still reading "FIX DECIDED … and NOT YET LANDED". **Blocked:** nothing
user-facing hard-stopped, but every instrument in the app mis-reported on any file with a cropping
`clap`, silently, and had done since before anyone looked.

> ### ✅ WHAT CLOSED IT — the crop reached the PIXELS
>
> - **A `CropRect` is applied to the sampled texture**, derived from the declared `clap` against the
>   encoded raster — `App/MetalVideoRenderer.swift:2068-2073`, with `CropRect.identity` as the
>   explicit no-crop case for "a source that declares no cropping `clap`, which is nearly all of
>   them".
> - **The offscreen ring is now the clean-aperture raster, not the encoded one.**
>   `App/MetalVideoRenderer.swift:530` records the new invariant directly: a 2880×2160 offscreen
>   "is the CORRECT state on every `clap` file, and the old form" is not. Since the waveform,
>   parade, vectorscope, CIE plot, v210 SDI convert and ⌃⌥E export all read that ring, **every
>   instrument inherited the fix at once** — which is the shape the defect had in reverse.
> - **The declaration and the transform are kept separate**, which is what stops this recurring:
>   `ManifoldCore/VideoMetadata.swift:342` holds the `clap` atom as declared,
>   `:437 cleanApertureCrops` answers whether it actually crops anything, and the inspector reports
>   the declaration rather than the result (`:324-326`).
> - Producers that have already cropped are handled rather than double-cropped —
>   `App/MetalVideoRenderer.swift:849`, `:870`: a bare `CVPixelBuffer` carries no `clap`, so the
>   raster the `clap` was declared against is passed explicitly. A LIVE source, which has no `clap`
>   to declare, clears it (`:1125`).

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

## ✅ BUILT — VideoToolbox plug-in codecs and MediaToolbox plug-in format readers are OPT-IN PER PROCESS, and Manifold never opted in. "AVFoundation cannot open MXF" is false.

**Status:** ✅ **BUILT.** Cause confirmed 2026-09-08 by measurement from a plain unsigned CLI;
**Manifold now opts in.** **Found:** 2026-09-08, while investigating why `Mixed Captions.mxf`
(DNxHR 444 12-bit) renders green and magenta. **Closed in the audit of 2026-09-21**, which found the
status line still reading "NOTHING DECIDED AND NOTHING BUILT". **Invalidated:** the premise under
the entire libav/MXF path — see the site list below, and re-read those comments before trusting
them, because the finding itself has not been undone by the fix.

> ### ✅ WHAT CLOSED IT
>
> **`App/ProVideoWorkflow.swift`** — a small type whose entire job is this entry. Both registrations
> are called once, at launch:
>
> ```swift
> VTRegisterProfessionalVideoWorkflowVideoDecoders()      // ProVideoWorkflow.swift:101
> MTRegisterProfessionalVideoWorkflowFormatReaders()      // ProVideoWorkflow.swift:102
> ```
>
> ⚠️ **AND IT DOES NOT CONFUSE ASKING WITH HAVING**, which is the trap this finding sets. Both
> functions return `void`, cannot fail, and succeed identically on a machine without Pro Video
> Formats installed. So presence is **probed** separately — `ProVideoWorkflow.Availability` is a
> three-state `unknown / installed(bundles:) / notInstalled`, with `.unknown` meaning *the probe has
> not finished* rather than *absent*, and the file's own header says `.installed` is a gate and
> never a guarantee that a decode will succeed.
>
> The measured cost the entry was owed: **7.4–10.0 ms** for the decoder registration and
> **4.1–5.0 ms** for the format readers, **12–15 ms combined** (`ProVideoWorkflow.swift:86-87`).
>
> **What this enabled:** the narrow MXF decode route — see *"✅ MEASURED 2026-09-09 — the narrow MXF
> plan is VIABLE"* below, which is now also built.

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

> ⚠️ **ANSWERED 2026-09-09 — see *"the narrow MXF plan is VIABLE"* at the end of this file.** The
> open question here was whether the decode step could be routed to the Avid decoder *without*
> giving up libav's demuxing. It can: libav's `AVdh` packets decode through a hand-built
> `VTDecompressionSession` bit-identically to `AVAssetReader`, with no AVFoundation container open.
> **That entry also retires two of the false trails above.** "File provenance" and "the format
> description" were both measured *before* registration, when nothing reached a decoder at all, so
> neither carried information — and after registration the format description turns out to matter
> enormously. **One atom, `ADHR`, is necessary and sufficient.** Do not read those two bullets as
> settled; the rest of the list stands.

---

## ✅ FIXED 2026-09-09 — `LicenseManager.bootstrap` blocks the main actor for the whole of launch, and the trial gate's opening frame accuses a valid trial of being expired

**Status:** ✅ **FIXED 2026-09-09, in three separate changes.** Built clean; **not yet through a
real session**, so this entry stays until it has been. **Found:** 2026-08/09, during the Open
Recent work, as "the app came up with no window at all". **Invalidates:** the attribution recorded
at the time — that this was the unsigned build's `SecurityAgent` prompt. That is true of the
**trigger** and false of the **shape**, and the shape ships.

> ⚠️ **THE DIAGNOSIS BELOW IS PRESERVED IN THE PRESENT TENSE AND NO LONGER DESCRIBES THE CODE.**
> It is kept because it is what makes a regression recognisable — the shapes it names are the ones
> to watch for coming back. **What actually landed, and why each route was chosen over its
> alternative, is at the end under "✅ WHAT LANDED".** Read that before acting on anything here.
>
> ⚠️ **AND READ "WHAT IS STILL TRUE" IN THAT SECTION.** This did not make the Keychain fast. The
> stall is not fixed and cannot be; what changed is where it lands.

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

### ~~Nothing is decided~~ — SUPERSEDED 2026-09-09

The original entry proposed no route. Three changes were then made, in the order below. Two defects
were recorded here on purpose — the **blocking** and the **gate's opening frame** — because they are
independent, and a fix that only moved the Keychain call off the main actor would have closed the
first and left the second exactly where it was. ⚠️ **Worse than left alone: it would have made the
second one VISIBLE.** That is why the order matters and why it is recorded.

---

## ✅ WHAT LANDED, 2026-09-09 — three changes, in this order

Three changes and not one. They are independent in mechanism, in affected population, and in blast
radius, and bundling them would have put a credential-losing risk inside a commit about launch
speed.

### 1 — The gate's fourth state (FIRST, and the order is the whole point)

⚠️ **THIS HAD TO LAND BEFORE THE ASYNC WORK, NOT AFTER.** Today the trial-ended frame was
constructed and never seen, because the main actor never turned the run loop to paint it. Making
the Keychain call async paints the window immediately — and what it would paint, for every trial
user, is that accusation, held for exactly as long as the Keychain is slow. Fixing the blocking
first would have shipped a regression more visible than the bug it fixed, to precisely the users
the fix existed for.

**Built:** `LicenseState` gained `case indeterminate` as the initial value of `state`; `trial` now
initialises to `TrialStatus.unknown` instead of `TrialStatus(active: false, daysRemaining: 0,
expired: true)`; and a new three-way `GateDecision { open, gated, undetermined }` is what
`LicenseGate` reads.

**⚠️ THE ROUTE NOT TAKEN, AND WHY.** The one-line version is `|| state == .indeterminate` inside
`isUsable`, and it was rejected. `isUsable` answers *"is this user entitled to work?"* — every one
of its clauses is a **reason to say yes**. "We have not looked yet" is not a reason to say yes; it
is a refusal to answer. Putting it there would have pushed the exact collapse this change removes
down one level, into the property every future caller reads, where it would be inherited silently.
`isUsable` therefore keeps its two cases and is simply not consulted until it can be answered.

This is `KeychainRead`'s own doctrine one layer up: absent and refused are different answers and
must not collapse. The gate needed the same discipline applied to **time** — not-yet-answered is
not an answer.

**⚠️ THREE RENDER SITES, NOT ONE.** All three corrected:

| site | what it did while undetermined |
|---|---|
| `LicenseGate` | rendered the opaque, hit-capturing `LicenseGateView` — the accusation itself |
| `LicenseSettingsSection.statusRow` | final `else` rendered **"Trial expired"** in Settings |
| the control block under it | fell into its `else` and offered **"Deactivate on this machine"** — proposing to tear down a licence never confirmed to exist. Needed a third branch rendering neither control, not a clause on the first |
| `DiagnosticsExport.LicenseContext` | wrote a confident, wrong **`TRIAL EXPIRED`** into a tester's diagnostics file — a support artefact that reads as evidence |

That last row is why this change was **independently correct before any async work**: the
diagnostics path could already produce the false claim with the blocking still in place.

**What renders before `bootstrap` answers: nothing.** Not a spinner, not a "Checking your
license…" line, not the gate. Most launches resolve in milliseconds, so any such affordance would
flash on every one of them to serve the rare slow case, and would turn an ordinary launch into a
visible licensing interrogation. The app renders, ungated; the gate appears only on a *determined*
negative. Settings is the one place that gets a neutral "Checking…" line, because a
`LabeledContent("Status")` has to say something and it is a window the user deliberately opened.

**⚠️ `.undetermined` LEAVES THE APP CONTENT ENABLED, DELIBERATELY.** `LicenseGate` drives
`.disabled()` from the same decision, so launch is briefly interactive before any verdict exists.
The alternative buys nothing — an empty deck with no file open has nothing to misuse — and costs a
real hazard: a `bootstrap` that never returns would leave the app permanently dead, every control
disabled, with no gate on screen to say why. It is also the call `isUsable` already makes one
clause up, where a **refused** read fails open; not-yet-asked is a strictly weaker claim than
could-not-read and cannot warrant a harsher response.

### ⚠️ THE INVARIANT THIS CREATED — read before adding an early return to `bootstrap`

`state` now doubles as the **"has bootstrap answered?"** flag. That was deliberate: every exit path
in `bootstrap` already assigns `state` before returning, so the invariant is
**not `.indeterminate` ⟺ bootstrap has answered**, with one source of truth. A separate `Bool`
would be a second fact about the same thing, and two facts can disagree.

**The cost is that it fails silently.** An early return added to `bootstrap` later that leaves
`state` as `.indeterminate` does not crash, does not log, and does not gate. It leaves the app
**ungated forever, with no gate on screen to explain it** — indistinguishable, from the outside,
from a working unlicensed launch. Any new `return` in that function must assign `state` first. The
obligation is documented on the property itself.

### 2 — The blocking

**Built:** a new `LicenseKeychain` — a nonisolated `enum` facade over the **unchanged**
`KeychainStore`, dispatching to a dedicated **serial `DispatchQueue`**. `bootstrap` now does one
batched off-actor gather, publishes state, and only then runs its best-effort tails.

**⚠️ MARKING THE METHODS `async` WOULD HAVE DONE NOTHING.** An `async` function with no suspension
inside it runs on its **caller's** executor, so `read` declared `async` and called from
`@MainActor bootstrap` would have gone on blocking the main thread exactly as before — while
looking, in the diff, exactly like the fix. Only an executor change relocates work. Record this:
it is the plausible non-fix that would have survived review.

**⚠️ WHY A WRAPPER, NOT AN `async` OR `actor` `KeychainStore`.** Either would relocate the work,
and both would turn roughly a dozen call sites in `Preferences.swift` and `StreamBookmarksSheet.swift`
into suspension points — several of which cannot `await` without themselves becoming `async`
(`StreamBookmarkStore.add`, `.update`, `.delete`, the passphrase migration, and `connectURL`, a
plain `static func` on the dial path). A button handler that writes a passphrase has no reason to
be `async`. `KeychainStore` stays synchronous, three-way and correct; the wrapper carries the one
path that has to leave the main actor.

**⚠️ WHY A `DispatchQueue`, NOT AN `actor` OR `Task.detached`.** All three leave the main actor;
only the queue is honest about the thread it blocks. `SecItemCopyMatching` is synchronous,
cross-process and unbounded — the whole premise is that it can sit for seconds behind an unlock
dialog. An actor's executor and `Task.detached` both run on Swift's **cooperative thread pool**,
roughly one thread per core and explicitly not to be blocked; parking one of those on a modal
dialog **trades a main-thread stall for pool starvation**, which is a worse bug somewhere harder to
see. Serial rather than concurrent, because `securityd` serialises anyway and a concurrent queue
would let two launches race the trial clock's read-modify-write.

**⚠️ ONE GATHER, NOT TWELVE AWAITS.** Every suspension point is a main-actor re-entry and SwiftUI
can compose a frame at each one, so N awaits would be N chances to render half-decided licensing
state — manufacturing the flicker class this work exists to remove. `gatherAtLaunch` returns one
`Sendable` value and `bootstrap` then runs its entire decision tree on the main actor with **no I/O
left in it**.

**The three boundaries, in order:** gather off-actor → **publish `state`, which is where the gate
unblocks** → then the tails, `reconcileActivationRecord()` and `refreshValidation(key:)`. Neither
tail feeds `gateDecision`, so neither has any business holding the first frame; on the licensed
path the record reconcile alone was a read, a write and a read-back sitting between the Keychain
and the window.

`recordLaunchAndEvaluate` moved **whole**, writes included — it stamps `firstLaunch`/`lastSeen` and
can set `voided`, so this was never a read-gathering exercise. Its rule that the trial is not
evaluated when the key read was refused moved with it intact; that rule is load-bearing, not an
optimisation, because stamping a clock we were not allowed to read is the exact tamper the Keychain
placement prevents.

**Also removed:** `refreshValidation` re-read `storedLicenseKey`, which `bootstrap` had already read
and still held. It now takes the key as a parameter — one fewer `securityd` round trip and one
fewer chance to prompt on every licensed launch.

**Found while building:** `activate(key:)` was a second caller of `readActivationRecord()`. It must
**not** get the machine-id restore — it has just registered this machine on the server under the
*current* `machineId`, so adopting a different id from an old record would leave the local id
disagreeing with the slot the server holds. The read was split back out so both call sites keep
their exact prior semantics.

**Left synchronous on purpose:** `activate`'s key write and `deactivate`'s deletes. Both are
user-initiated button presses with the window already up and `isWorking` driving a spinner —
attributable, expected, and outside the launch path.

### ⚠️ WHAT IS STILL TRUE — this made launch RESPONSIVE, not FASTER

**Do not read this entry as saying the stall is fixed.** It is not, and it cannot be from here.
`securityd` still serialises. The calls take exactly as long as they always took. The
`SecurityAgent` prompt on an unsigned build, and the unlock dialog on a locked login keychain,
still appear whenever the conditions in the section above call for them — **every one of those
conditions is still live.**

What changed is where the dialog lands. An OS keychain dialog is a legitimate thing to show; it
must not be shown *instead of* a window. It now arrives **on top of a live, painted app** the user
can attribute it to, rather than behind a window that never existed. The failure mode moved from
"the app is hung" to "the system is asking me for my keychain password" — which is the whole of the
win, and it is worth having, but it is not speed.

### 3 — The migration, deferred rather than made async

**Built:** `migratePassphrasesToKeychain()` was removed from `StreamBookmarkStore.init` and is now
called from a `.task` on the `WindowGroup` content, guarded to one attempt per process. **The
migration's own body is byte-identical** — verified by diffing the function range.

**⚠️ WHY DEFERRED AND NOT SPLIT.** The async route was the dangerous one. The migration is **not
pure I/O**: it maps over `bookmarks`, which is `@Published` on an `ObservableObject`. An async
version has to carry the correlation between *which write confirmed* and *which entry may be
stripped* across a suspension point — and getting that correlation wrong **strips a passphrase
whose write failed, destroying the only copy of a credential the user may never have written
down.** That is the one place in this entire line of work where a mistake loses user data, and it
was not worth taking inside a change about launch responsiveness. Deferring achieves the actual
goal — the migration is off the launch path — without touching one line of its logic.

**⚠️ THE CONFIRMED-WRITE GATE AND ITS NON-CONVERGENCE ARE UNTOUCHED.** A keychain that keeps
refusing still retries at every launch, forever, and never converges. That is the **price** of the
gate, which exists so a failed write can never destroy the only copy of a credential. It is not a
defect and must not be "fixed" by dropping the retry or relaxing the gate.

**Where the trigger went, and why that point is after the first frame.** `init` ran from
`ContentView`'s **stored property initialiser** (`ContentView.swift:336`), i.e. inside the
`WindowGroup` content closure, before the scene's `.task` modifiers were attached at all — earlier
in launch than licensing, which is why no restructuring of `bootstrap` could reach it. `.task`
cannot run before the view appears, so the Keychain work can no longer precede the window's
existence. ⚠️ Stated precisely, because the limit matters: `.task` means "after the view appears",
**not** a hard "after the first pixel", and the migration is still synchronous on the main actor
when it does run. For a legacy user that is a brief hitch after the window is up rather than a hang
before it exists. That categorical change is the fix; sub-frame precision is not claimed. It is the
same seam `UpdateChecker.checkAtLaunch` already uses, with the same stated contract.

**The guard is on the ATTEMPT, not on success**, because `.task` fires per window — without it a
second deck would re-run the migration and raise a second dialog on a prompting keychain. Guarding
the attempt reproduces `init`'s exact cadence: one attempt per process, failures retried next
launch.

**If the app is quit before the deferred migration runs, nothing is lost and nothing changes.** An
unmigrated bookmark still carries its passphrase inline in `urlString`. `connectURL` reads the
Keychain, gets `.absent` — **not** `.failed`, so the refuse-to-dial path is not taken — and returns
the stored URL unchanged, still carrying `?passphrase=` for `SRTClient.parse` to lift back out. The
stream dials and works exactly as before. The migration runs at the next launch. That safety is
load-bearing for the whole deferral, and it is the three-way `KeychainRead` distinction that
provides it.

### Still open

- **Not yet through a real session.** Built clean; no launch has been measured against a slow or
  locked keychain. The unsigned `.build-cc` prompt remains the cheapest way to reproduce the
  condition on demand and is the obvious regression test.
- **The `#if DEBUG` `LicenseCrypto.runRoundTripSelfCheck()`** still runs on the main actor at the
  top of `bootstrap`, ahead of the gather, in every Profile build. Sub-millisecond, knowingly left.

---

## ✅ BUILT — the narrow MXF plan was VIABLE and SHIPPED. libav's `AVdh` packets decode through a hand-built `VTDecompressionSession`, bit-identically, and ONE ATOM is what makes it work

**Status:** ✅ **MEASURED 2026-09-09, two fixtures, bit-exact — AND BUILT.** **Found:** by
re-running the `vtdnx.c` probe from the 2026-09-08 registration investigation with
`VTRegisterProfessionalVideoWorkflowVideoDecoders()` called first. **Closed:** the open question
left by *"VideoToolbox plug-in codecs … are OPT-IN PER PROCESS"* above, which recorded the cause and
deliberately proposed no route. **Corrected in the audit of 2026-09-21**, which found this entry
still reading "NOTHING BUILT AND NOTHING CHANGED IN THE APP" against a shipping decoder.

> ### ✅ WHAT SHIPPED — the narrow plan, built as designed
>
> **The plan was: keep the MXF path exactly as it is and route ONLY the decode step.** That is what
> landed, and the narrowness held.
>
> - **`ManifoldCore/DNxHRVideoToolboxDecoder.swift`** — the hand-built `VTDecompressionSession`,
>   including the synthesised 28-byte `ADHR` atom the measurement identified as the one thing that
>   makes it work (libav reports 0 bytes of `extradata` and a `0x00000000` `codec_tag` on every MXF
>   fixture, so both are supplied).
> - **Engaged only for the profile libav cannot handle** —
>   `ManifoldCore/LibavFrameSource.swift:254-256` constructs it behind
>   `DNxHRVideoToolboxDecoder.isProfile444(codecID:profile:)`. Everything else stays on libav.
> - **libav still demuxes, and the rest of the path is untouched** — range detection, captions,
>   audio streams and geometry are all where they were.
> - **The absent-plug-in case is stated to the user rather than rendered wrong in silence.**
>   `DNxHRVideoToolboxDecoder.PictureCaveat` carries a standing inspector row and a one-shot banner
>   (`ManifoldCore/LibavFrameSource.swift:337-338`, `:485`, `:503`;
>   `ManifoldCore/FrameEngine.swift:1917-1931`), worded as capability and never as error — nothing
>   is the user's doing and nothing is wrong with their file.
>
> ⚠️ **One user-facing string from this work is British and is on the American-English sweep's
> list** — `"Colour unreliable — needs Pro Video Formats"`,
> `ManifoldCore/DNxHRVideoToolboxDecoder.swift:77`, plus the banner at `:80-82`. It is a *new* hit,
> landed after the 2026-08-27 scan, and it is the clearest single illustration of why that entry has
> been reframed from a one-time sweep to recurring drift.

### The narrow plan, and the finding

The plan under test: **keep the MXF path exactly as it is** — libav demuxing, range detection,
captions, audio tracks, geometry — and **route ONLY the decode step** to the Avid decoder, and only
for the profile libav cannot handle. That needs compressed packets from libav to reach a VT session.

**They do.** Compressed `AVdh` packets demuxed by libav from the original MXF reach a hand-built
`VTDecompressionSession` and decode **bit-identically to `AVAssetReader`** — max |Δ| = 0, mean
|Δ| = 0.00000, **0.0000 % differing samples on every plane of both fixtures** — with **no
AVFoundation container open anywhere in the path**. `x420` can be requested and is delivered, which
is [the app's existing decode contract](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift)
unchanged. Sustained decode runs at **42 fps on 4K 444 12-bit including the SMB read**.

⚠️ **The cost the alternative route would have carried is therefore NOT incurred.** Opening the
whole container through AVFoundation would have cost the range tag and the ANC captions. Nothing in
this path opens the container through AVFoundation, so nothing is lost.

### The measurement

Both fixtures on `//10.25.2.125/DCCOLOR` over SMB. Frame index 10 in both cases; the libav packet
PTS and the `AVAssetReader` sample PTS were **asserted equal before any pixel was compared**
(0.4171 s on both files, both paths). Reference and test decode ran **in the same process**, both
asked for `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`.

| fixture | codec | libav | packet | result vs `AVAssetReader` |
|---|---|---|---|---|
| `Mixed Captions.mxf` (5.26 GB, 30.030 s) | DNxHR **444 12-bit**, `ACT=1` | `profile=5`, `bits_per_raw=12` | 7,286,784 B | **max \|Δ\| = 0, both planes** |
| `OP1A Test.mxf` (1.46 GB, 16.642 s) | DNxHR **HQX 422 10-bit** | `profile=4`, `bits_per_raw=10` | 3,641,344 B | **max \|Δ\| = 0, both planes** |

⚠️ **The 444 fixture is the one that matters, because libav is known-incorrect on it.** libav prints
`Unsupported: variable ACT flag.` and renders green and magenta; this path renders natural colour
and is bit-identical to the decoder that `docs/mxf-fixtures/README.md` already treats as the
reference. **So this is a correctness fix, not a performance one** — the same conclusion the
registration entry reached, now established for a route that keeps libav demuxing.

Decoded 10-bit code ranges, identical across every arm that produced a frame:

| fixture | plane0 (luma) | plane1 (chroma, interleaved) |
|---|---|---|
| `Mixed Captions.mxf` | `[78..908]` | `[273..596]` |
| `OP1A Test.mxf` | `[63..940]` | `[401..630]` |

### ⚠️ ONE ATOM IS NECESSARY AND SUFFICIENT — `ADHR`, 28 bytes, and nothing else

Not `ACLR`, not `mtdt`, not `FormatName`, `Depth`, `CVFieldCount` or the three `CVImageBuffer…`
colour keys. Apple's MXF reader hands out a format description with **seven** extension keys; six of
them are decoration as far as the decoder is concerned.

Measured, every row on `Mixed Captions.mxf`, all with codec `'AVdh'` and 3840×2160:

| format-description extensions | `VTDecompressionSessionCreate` | decode |
|---|---|---|
| **NULL** | **0** | callback **−17696**, no frame — *and see the crash section* |
| **empty dictionary** | **0** | callback **−17696**, no frame — *same* |
| `FormatName` + `Depth` + `CVFieldCount` + the 3 colour keys, no atoms | **−12902** | — |
| atoms = `{ACLR}` only | **−12902** | — |
| atoms = `{mtdt}` only | **−12902** | — |
| atoms = **`{ADHR}`** only | **0** | **bit-identical** |
| atoms = `{ACLR, ADHR, mtdt}` | **0** | **bit-identical** |
| all 7 keys, live off the `AVAssetTrack` | **0** | **bit-identical** |
| all 7 keys, rebuilt from a binary plist | **0** | **bit-identical** |
| **hand-built `{ADHR}`, 28 bytes, nothing from the container** | **0** | **bit-identical** |

⚠️ **Note the two shapes of failure and do not confuse them.** An extensions dictionary that is
NULL or empty **opens the session and then fails at decode**. One that is non-empty but lacks
`ADHR` **fails at session create with −12902**. Session-create success is therefore *not* the gate
to test a format description against.

### The `ADHR` field table — derived by bisection, undocumented

28 bytes: ASCII `"0002"` followed by six big-endian `uint32`.

| fixture | libav `profile` | CID | f2 | f3 | f4 | f5 | f6 |
|---|---|---|---|---|---|---|---|
| `Mixed Captions.mxf` — DNxHR 444 12-bit | 5 | **1270** | 2 | 3 | `0x00010000` | 0 | 2 |
| `OP1A Test.mxf` — DNxHR HQX 10-bit | 4 | **1271** | 0 | 2 | 0 | 0 | 1 |

`CID` is the DNxHR compression ID and **maps 1:1 onto libav's `profile`** (5 → 1270 = 444,
4 → 1271 = HQX). The semantics of f2, f3, f4 and f6 are **not known** — they were established as
load-bearing by zeroing one field at a time and reading the failure:

| field zeroed | on `Mixed Captions.mxf` | on `OP1A Test.mxf` |
|---|---|---|
| **CID** | **−12907** `kVTCouldNotCreateInstanceErr` at create | **−12907**, same |
| **f2** | **−12910** `kVTVideoDecoderUnsupportedDataFormatErr` at create | already 0, not testable |
| **f3** | **−12910** at create | **−12910** at create |
| **f4** | create **0**, then callback **−12909** `kVTVideoDecoderBadDataErr` | already 0, not testable |
| **f5** | already 0, not testable | already 0, not testable |
| **f6** | **−12910** at create | **−12910** at create |

⚠️ **`f4` is the trap.** It is the only field whose absence lets the session open and then fails at
decode, and on the 444 fixture it is the only non-zero one of the four unknowns. A `CID`-only atom
with everything else zeroed fails on **both** fixtures — **the compression ID alone is not enough**,
which is the obvious wrong guess.

### Provenance is decisively NOT the blocker, and the description can be synthesised

The 2026-09-08 entry lists **file provenance** and **the format description** among its false
trails. Both were measured *before* registration, when nothing reached a decoder at all, so neither
result carried any information. **Re-established here, after registration:**

**A completely hand-built `ADHR` — 28 bytes assembled in the probe, nothing lifted from the
container, no Apple demuxer involved — decodes bit-identically on both fixtures.** Provenance is
not a blocker. The description does not have to come from Apple's MXF reader; it can be
**synthesised from libav's stream parameters**, which is what makes the narrow plan narrow.

⚠️ **Two libav gaps to code around**, both confirmed on both fixtures:

- **`extradata` is 0 bytes.** There is no ACLR/ADHR to lift; the atom must be constructed.
- **`codec_tag` is `0x00000000`.** libav reports no fourCC for this stream, so **`'AVdh'` must be
  supplied as a constant** rather than passed through from the container.

### ⚠️ A WRONG FORMAT DESCRIPTION SEGFAULTS APPLE'S DECODER, AND THE WEDGE IS WORSE THAN THE CRASH

**`DNXDecoder`'s `parse_metadata` calls `CFDictionaryGetValue` with no null check** and dies inside
`VTDecoderXPCService`. Measured, `SIGSEGV`, `KERN_INVALID_ADDRESS at 0x0000000000000000`:

```
CoreFoundation   __CF_IS_OBJC
CoreFoundation   CFDictionaryGetValue
DNXDecoder       parse_metadata(opaqueCMFormatDescription const*, DNX_CompressedParams_t&,
                                decodeColorMapping_t&, bool&)
DNXDecoder       ???
VideoToolbox     ???
libxpc.dylib     _xpc_connection_call_event_handler
```

**24 crash reports on the build Mac on 2026-09-09**, all from this investigation, all from a NULL
or empty extensions dictionary.

⚠️ **VideoToolbox surfaces this as −17696 `kVTVideoDecoderUnknownErr`, which reads like a soft
failure. It is not.** After it, **`VTDecompressionSessionInvalidate` blocks forever** in
`xpc_connection_send_message_with_reply_sync` → `mach_msg2_trap`, waiting on a reply from a process
that is already dead. **Measured at seven minutes at 0 % CPU** before the probe was killed; there is
no evidence it would ever return.

⚠️ **ANYTHING BUILT ON THIS PATH NEEDS THE DESCRIPTION RIGHT *AND* A WATCHDOG AROUND TEARDOWN.**
Getting the description right is necessary but not sufficient as a safety argument: a future file
whose parameters produce an atom the decoder rejects turns a decode failure into a hung teardown on
a real user's machine. `−17696` should be treated as "the decoder process died", and session
teardown should not be allowed to block a thread that matters.

### Pixel formats — `x420` is available, and so is everything else asked for

On a correct format description, every requested format was delivered, `Mixed Captions.mxf`:

| requested | delivered | shape |
|---|---|---|
| `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` | **`x420`** | 3840×2160, 2 planes, stride 7680 |
| `…422YpCbCr10BiPlanarVideoRange` | `x422` | 2 planes, chroma 1920×2160 |
| `…444YpCbCr10BiPlanarVideoRange` | `x444` | 2 planes, chroma 3840×2160 stride 15360 |
| `kCVPixelFormatType_32BGRA` | `BGRA` | packed |
| `kCVPixelFormatType_422YpCbCr10` | `v210` | packed |
| **nothing requested** | **`b64a`** | packed 16-bit RGBA — the decoder's native for 444 |

Colour attachments come back tagged `ITU_R_709_2` on primaries, transfer and matrix.

### Sustained decode, not one frame

**60 consecutive libav packets pushed through ONE session** built from a synthesised `ADHR`, 4K
DNxHR 444 12-bit off SMB: **60 decoded, 0 failed**, 1.42 s total, **23.7 ms/frame, 42.1 fps** —
and that figure *includes* the SMB read and the libav demux, so the decode itself is faster. Above
real time for 24000/1001. No session rebuild between frames, no format-description change.

### ⚠️ WHAT IS UNTESTED — the `ADHR` semantics are pinned for two profiles only

**HQX 422 10-bit and 444 12-bit. That is all.** `DNxHD` (`AVdn`) and the DNxHR **LB, SQ and HQ**
profiles each need their own field values, and f2/f3/f4/f6 cannot be predicted from two samples —
`CID` can, the rest cannot. That is bounded work, not open-ended, but it is work and it is not done.

**The fallback is proven and needs no reverse engineering:** lifting the extensions off an
`AVAssetTrack` decodes bit-identically, including **rebuilt from a binary plist**, so the atom does
not even have to be used live. The cost is **a second container open** — AVFoundation opens the file
alongside libav purely to read the description, then closes. That keeps the demux, captions, range
and audio on libav and still costs nothing from the picture. It is the safety net if a profile's
fields resist.

### Unchanged constraints — neither is affected by this result

1. **Pro Video Formats is a user-installable Apple package** (`com.apple.pkg.ProVideoFormats`) that
   Manifold does not ship and cannot assume. **libav stays as the fallback**, and any design has two
   paths for MXF from the outset. **The ACT defect stays unfixable on a machine without the
   package** — a file can be correct on one machine and green and magenta on another with the same
   build.
2. **The network-facing caveat in the registration header still deserves its own decision.** The
   header warns that opting in "is not recommended for network-facing applications". Manifold is a
   QC tool and is the intended audience, but it also carries NDI, WHEP, SRT and HLS. Nothing here
   changes that; it is still a deliberate declaration, not a free upgrade.

### One loose thread, promoted to its own entry

`ADHR` field 6 carries the range convention, and on `Mixed Captions.mxf` it says full where libav
reports `AVCOL_RANGE_UNSPECIFIED`. It does **not** touch this plan — f6 is required for the session
to open and is supplied verbatim either way — so it is not chased here.

**It is a shipping defect, has its own entry, and is now FIXED:** *"an MXF whose range libav reports
as UNSPECIFIED rendered as legal range"*, **below**. ⚠️ **Two things that entry establishes matter
back here:** `ACLR` is **not** the range tag (a matched full/legal pair carries byte-identical
`ACLR` atoms), and **neither `ADHR` nor `ACLR` is in the MXF at all** — Apple's reader synthesises
both from the SMPTE picture descriptor, which is where the range actually lives and what the fix
reads. It also corrects a published row in
[`full-range-chroma-convention-findings.md`](full-range-chroma-convention-findings.md).

### The probe

Four phases — `ref`, `try`, `cmp`, `seq` — in a single-file `clang -fobjc-arc` Objective-C source
linking `libavformat`/`libavcodec`/`libavutil` plus `AVFoundation`, `VideoToolbox` and
`MediaToolbox`. ⚠️ **The phase split is not tidiness; it is required.** A decoder crash wedges the
process that caused it, so the reference capture, each format-description attempt and the comparison
must run as separate processes or one bad variant takes the whole run with it. `try` sets
`alarm(60)` and `_exit`s rather than calling `VTDecompressionSessionInvalidate`, for the same reason.

⚠️ **It lives in the 2026-09-09 session scratchpad and is NOT committed**, same as the `reg.swift` /
`mtreg.swift` / `final.swift` probes the registration entry names. If this work proceeds, the
comparison belongs in [`docs/mxf-fixtures/`](mxf-fixtures/) alongside `mxfmeas.swift`, whose
conventions it already follows — one file, built on demand, binary not committed, not in the app
target.

---

## ✅ FIXED 2026-09-09 — an MXF whose range libav reports as UNSPECIFIED rendered as legal range, and the inspector positively claimed "Video (Legal)". `.untagged` was unreachable on the libav path

**Status:** ✅ **FIXED 2026-09-09.** Built clean into `.build-cc`; **compile-verified and
parser-verified against the four fixtures, but NOT through a real session** — no picture has been
captured through the running app — so this entry stays until it has. **Found:** incidentally, while
measuring the DNxHR decode route — see *"the narrow MXF plan is VIABLE"* above. **Was breaking:**
the three-state honesty the app enforces everywhere else, on the one axis where a wrong answer
changes pixels.

> ⚠️ **THE DIAGNOSIS BELOW IS PRESERVED IN THE PRESENT TENSE AND NO LONGER DESCRIBES THE CODE.** It
> is kept because it is what makes a regression recognisable. **What actually landed is at the end
> under "✅ WHAT LANDED".**

### ⚠️ TWO PREMISE CORRECTIONS, AND THE SECOND ONE INVALIDATED THIS ENTRY'S OWN PROPOSED FIX

Opened twice on a wrong mechanism. Both recorded, because each looked settled:

1. **`ACLR` carries the range and libav drops it.** ❌ Disproved by a controlled fixture pair — see
   *"What ACLR is not"* below. It also **corrected a published row** in
   [`full-range-chroma-convention-findings.md`](full-range-chroma-convention-findings.md).
2. **⚠️ `ADHR` field 6 carries the range, so read f6 off the MXF.** ❌ **IMPOSSIBLE — AND THE FIRST
   VERSION OF THIS ENTRY PRESCRIBED IT AS THE FIX.** **`ADHR` IS NOT IN THE CONTAINER AT ALL.**
   Grepping all four fixtures for the literal bytes `ADHR` and `ACLR` finds **neither, anywhere**.
   Apple's MXF reader **synthesises** both atoms from the MXF descriptor. Reading `ADHR` would
   therefore require AVFoundation to open the container — exactly what the libav path exists to
   avoid. **What `ADHR` f6 *encodes* IS in the container, and that is what is read instead.**

**The consequence stated originally was right throughout. Only the mechanism moved.**

### The chain — as it actually is

1. **The MXF declares the range in its picture descriptor**, and there are **two descriptor kinds**:
   - **`CDCIDescriptor`** (Y′CbCr) — `BlackRefLevel` (`0x3304`), `WhiteRefLevel` (`0x3305`),
     `ColorRange` (`0x3306`), `ComponentDepth` (`0x3301`).
   - **`RGBADescriptor`** (4:4:4) — `ComponentMinRef` (`0x3407`), `ComponentMaxRef` (`0x3406`),
     `PixelLayout` (`0x3401`, which is where the bit depth lives).
2. **libav sets `color_range` at `avformat_open_input`, from the `CDCIDescriptor`.** ⚠️ **MEASURED,
   and it matters: `color_range` is already final after `open_input` and is NOT changed by
   `avformat_find_stream_info`.** So the DNxHD decoder is not the source, and **the `Unsupported:
   variable ACT flag.` decode failure is NOT the cause of the silence** — the obvious wrong guess.
3. **⚠️ libav does not map the `RGBADescriptor`'s ref levels.** `Mixed Captions.mxf` is 4:4:4 and
   carries an `RGBADescriptor` **instead of** a `CDCIDescriptor` — it has no CDCI set at all — so
   libav has nothing to read and reports `AVCOL_RANGE_UNSPECIFIED`. **That is the entire cause.**
4. **`LibavFrameSource` collapsed three states into two** — `isFullRange: range == AVCOL_RANGE_JPEG`
   into a `Bool`. `UNSPECIFIED` and `MPEG` both became `false`, indistinguishably.
5. **`FrameEngine` turned that `Bool` back into a three-state enum that could hold only two of its
   cases** — `sourceRange = info.isFullRange ? .full : .videoLegal`, and the same ternary for the
   inspector string.

⚠️ **THIS IS MUCH NARROWER THAN "MXF RANGE IS DROPPED", AND THE NARROWNESS IS THE POINT.** **libav
was correct on three of the four fixtures** and is not to be treated as unreliable here. It is
silent on **one descriptor kind**, and the fix had to fill that silence without touching the cases
that already worked.

### What the containers actually say — parsed directly out of the MXF, no AVFoundation

| fixture | descriptor kind | the declaration | depth | libav `color_range` |
|---|---|---|---|---|
| `TEST OMNISCOPE_FULL.mxf` | **CDCI** | `BlackRef=0  WhiteRef=1023  ColorRange=1023` | 10 | **2** `JPEG` (full) ✅ |
| `TEST OMNISCOPE_LEGAL.mxf` | **CDCI** | `BlackRef=64  WhiteRef=940  ColorRange=897` | 10 | **1** `MPEG` (legal) ✅ |
| `OP1A Test.mxf` | **CDCI** | `BlackRef=64  WhiteRef=940  ColorRange=897` | 10 | **1** `MPEG` (legal) ✅ |
| `Mixed Captions.mxf` | **RGBA** | **`ComponentMinRef=0  ComponentMaxRef=4095`** — full, explicitly | **12** | **0 `UNSPECIFIED`** ❌ |

`Mixed Captions.mxf`'s `PixelLayout` is `52 0c 47 0c 42 0c 46 04` — `R`12 `G`12 `B`12 `F`ill 4. At
12 bits, `0…4095` is the **full** excursion; legal would be `256…3760`. ⚠️ **The file states full
range plainly. Nothing about it is ambiguous, untagged, or a matter of inference.**

### ⚠️ THIS CORROBORATES THE `ADHR` f6 INFERENCE RATHER THAN INVALIDATING IT

The f6 reading previously rested on four fixtures in which `Mixed Captions.mxf` differed from the
OMNISCOPE pair in **both** f6 **and** subsampling — a real confound, flagged at the time. **The
container now states full independently of `ADHR`**, so `f6 = 2` ⇒ full is **corroborated by a
second, independent source**. `ADHR` f6 remains the correct reading of what Apple's reader vends; it
is simply not the right thing to *read*, because it is not in the file.

### Two defects, kept apart — and only one of them changes pixels

⚠️ **Do not merge these. Different consequences, different fixes.**

| | what it is | does it change the picture? |
|---|---|---|
| **A. The false claim** | `UNSPECIFIED` collapsed to `.videoLegal`, so the inspector printed **"Video (Legal)"** about a file that had said nothing | ⚠️ **NO.** Under the default `.auto`, [`updateEffectiveRange`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1738) computes `isFull = (sourceRange == .full)`, so `.untagged` and `.videoLegal` behave **identically**. This half was purely a false statement about the file |
| **B. The render defect** | a file **declaring full** whose declaration never arrived, so `sourceRange` became `.videoLegal` and the shader **expanded legal→full on codes that were already full** | ✅ **YES.** The picture was wrong, not merely mislabelled |

**And the metadata that would have said otherwise is in the container.** ⚠️ **This is NOT the ProRes
case, where the range tag is genuinely absent from the file.** Here it is present in the MXF, and it
was absent **only from the reader we use**. An absent tag is a fact about the file; a dropped tag is
a fact about us.

### What `ACLR` is NOT — and a correction to a published document

**`ACLR` does not carry the range convention.** `TEST OMNISCOPE_FULL.mxf` and
`TEST OMNISCOPE_LEGAL.mxf` carry **byte-identical `ACLR` atoms** —
`41434c52 30303031 00000001 00000000`, i.e. f1 = 1 — while being full and legal respectively. A
field that does not change across a matched full/legal pair is not the range field. `ACLR` f1 = 2
appears only on `Mixed Captions.mxf`, the only 4:4:4 12-bit fixture, so it plausibly tracks
colour/subsampling; **that has not been established and is not chased here.** ⚠️ And like `ADHR`,
`ACLR` is **synthesised by Apple's reader** — it is not in the MXF either.

⚠️ **[`full-range-chroma-convention-findings.md`](full-range-chroma-convention-findings.md)'s summary
table carries the row `Range tag (DNxHR/MXF): ACLR=1 (legal) … ACLR=2 (Resolve full)`. That row is
contradicted by the OMNISCOPE pair and has been corrected in place.** It matters because that
document is externally facing and prepared for technical review.

### Why this is a defect and not a rounding of a display string

The app enforces three-state honesty deliberately and in writing, everywhere the distinction exists
— and this axis is the one where the third state is not cosmetic, because `.auto` acts on it:

| precedent | the third state, and what it refuses to say |
|---|---|
| [`DeclaredPixelAspect`](../Packages/ManifoldCore/Sources/ManifoldCore/VideoMetadata.swift#L30) | `pasp 1:1` **is a declaration**; no `pasp` is an absence. Its own doc comment names `colorRange` as the same pattern — *"Untagged is not Video (Legal)"* |
| [`LayoutConfidence`](../Packages/ManifoldCore/Sources/ManifoldCore/VideoMetadata.swift#L11) | `declared` / `inferred` / `undeclared` — a guess from channel count is marked as a guess |
| [`CaptionDataPresence`](../Packages/ManifoldCore/Sources/ManifoldCore/CaptionPresence.swift#L48) | `unknown` is *"nobody looked"*; `measured(carrying: 0, …)` is *"we looked and found none"* |
| [`KeychainRead`](../App/KeychainStore.swift#L41) | `.absent` is *"nothing is stored"*; `.failed` is *"something may be stored and we could not see it"* — and only `.absent` may be acted on |

⚠️ **`DeclaredPixelAspect`'s comment cites this exact axis as settled precedent.** The rule was
already written down and the libav path did not follow it. **Unspecified and legal are different
answers.**

---

## ✅ WHAT LANDED, 2026-09-09 — one new file, two edited, and `updateEffectiveRange` untouched

Its 2→1 mapping was correct; the loss was upstream of it.

**1. [`MXFDeclaredRange.swift`](../Packages/ManifoldCore/Sources/ManifoldCore/MXFDeclaredRange.swift)
— NEW.** Reads the declared range straight off the MXF picture descriptor, **CDCI and RGBA both**.
Bounded read: it takes `HeaderByteCount` from the header partition pack rather than guessing, so it
reads ~262 KB on these fixtures and never scans the essence. It is **self-gating** — the partition
pack key is checked first, so a non-MXF costs 0.4 ms and returns `.untagged` without sniffing the
extension. ⚠️ **It never guesses:** only the two standard excursions map to an answer; anything else
— no descriptor, absent ref levels, an excursion matching neither convention — returns `.untagged`,
a real answer meaning *the file did not say*.

**2. `LibavFrameSource` — the `Bool` route is gone.**
[`StreamInfo.declaredRange`](../Packages/ManifoldCore/Sources/ManifoldCore/LibavFrameSource.swift#L52)
replaces `isFullRange: Bool`. ⚠️ **`isFullRange` survives only as a
[computed getter](../Packages/ManifoldCore/Sources/ManifoldCore/LibavFrameSource.swift#L74) that
re-collapses the three states ON PURPOSE**, so reaching for it reads as a deliberate choice at the
call site rather than as the only route available — the exact shape and reasoning of
`KeychainRead.value`. Also fixed: `rangeName` returned `Full (ACLR=2/JPEG)` / `Legal (ACLR=1/MPEG)`,
encoding the **disproved** mapping in every log line and pointing the next reader at the wrong atom.
It now reports the resolved state plus its provenance, e.g.
`Full (libav silent, MXF picture descriptor)`.

**3. `FrameEngine` — three states carried through, both halves.**
[`:1570`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1570) is defect **A**
(the inspector row; no pixels change).
[`:1799`](../Packages/ManifoldCore/Sources/ManifoldCore/FrameEngine.swift#L1799) is defect **B**
(`sourceRange`, which reaches the shader).

### ⚠️ THE FALLBACK IS CONSULTED ONLY WHEN LIBAV IS SILENT, AND THAT IS A CHOICE

[`LibavFrameSource.swift:222`](../Packages/ManifoldCore/Sources/ManifoldCore/LibavFrameSource.swift#L222)
sits in the `default:` branch of a switch on `AVColorRange` — `JPEG` and `MPEG` are taken from libav
and the container is **never consulted**.

**So the two readers cannot disagree. There is no precedence rule because there is no contest**, and
that is deliberate rather than accidental: **libav was right on every fixture where it spoke**, so
letting a second parser override a *stated* answer would risk files that are correct today in order
to fix files that are not. The fallback **fills silence**; it does not arbitrate.

⚠️ **The parser was nonetheless tested against all four fixtures, including the three it is never
asked about — and it agrees with libav independently on all three CDCI files.** That is what makes
"no contest" a measurement rather than an assumption: the fallback-only choice is not concealing a
disagreement. Cross-checking libav against the container on **every** open is a separate decision
and was deliberately not taken.

### Verified — `MXFDeclaredRange.read`, against the real files

Compiled against the shipping source, not a reimplementation:

| input | result | time |
|---|---|---|
| `TEST OMNISCOPE_FULL.mxf` | **Full** | 4.2 ms |
| `TEST OMNISCOPE_LEGAL.mxf` | **Video (Legal)** | 2.2 ms |
| `OP1A Test.mxf` | **Video (Legal)** | 2.6 ms |
| `Mixed Captions.mxf` | **Full** — was "Video (Legal)" | 1.9 ms |
| a ProRes `.mov` (not MXF) | **Untagged** | 0.4 ms |
| a nonexistent path | **Untagged** | 0.0 ms |

⚠️ **NONE OF THE FOUR FIXTURES PRINTS "Untagged", AND THAT IS THE SURPRISE.** The fix makes
`.untagged` **reachable** on the libav path for the first time — but the file that looked untagged
turns out to **declare full range explicitly**; libav simply does not read RGBA descriptors. **An
MXF that declares nothing at all would now print "Untagged", and there is no fixture that does.**

### Still open

- ⚠️ **NOT THROUGH A REAL SESSION. No picture has been captured through the running app**, so
  defect **B**'s correction — `Mixed Captions.mxf` no longer double-expanding — is verified by
  construction and by the parser, **not by eye**. That file is the obvious regression test.
- **Breadth.** Four fixtures, all DNxHR. Whether libav's `UNSPECIFIED` tracks 4:4:4 specifically or
  the `RGBADescriptor` more generally across other codecs is **not** established — the mechanism
  says the latter; one fixture cannot confirm it.
- **`.untagged` has no fixture.** The state is now reachable and untested end-to-end.
- **RGB vs Y′CbCr.** `Mixed Captions.mxf`'s `PixelLayout` declares R/G/B components. Whether the
  essence is genuinely RGB — and what that implies for the shader's **matrix**, as distinct from its
  range flag — was **not** investigated.

---

## ⚠️ The NDI runtime is dlopened and `NDIlib_initialize()`d at LAUNCH, on every machine, from the first view body — which is what `NDIService` explicitly forbids

**Status:** ⚠️ **RECORDED 2026-09-09, NOT FIXED, and deliberately so** — found while making the NDI
menu item conditional, which is a different change and did not need this one. **Found:** by an A/B
launch measurement and a backtrace. **Blocks:** nothing. **Affects:** every launch, including users
who never touch NDI.

### What happens

[`ContentView.swift:2548`](../App/ContentView.swift#L2548) calls `NDIBridge.loadRuntime()` directly,
inside `ndiSourceListItems` (the `@ViewBuilder` begins at
[`ContentView.swift:2542`](../App/ContentView.swift#L2542)). That builder is reached from the
**empty state's stream menu**, which is what every launch renders — so the call runs during the
FIRST `ContentView.body`, on the main thread, inside `main`. **MEASURED**, backtrace at first load:

> ⚠️ **LINE REFERENCE CORRECTED 2026-09-21: this entry said `:2442`, and `ContentView.swift` has
> since grown past it.** The call site itself is **unchanged** — same builder, same direct bridge
> call, same comment describing it as an ordering-safe fallback — so the entry is still accurate;
> only the coordinate had rotted. Re-verified: `NDIBridge.loadRuntime()` has five call sites, four
> of them inside `NDIService` (`:295`, `:331`, `:386`, `:431`) and this one.

```
main → ContentView.body → videoRegion → emptyState → Menu → ndiSourceListItems
     → +[NDIBridge loadRuntime] → NDILoadOnce
```

Confirmed by removing the (unrelated) launch probe added the same day and relaunching: the
`[NDI] runtime loaded: /usr/local/lib/libndi.dylib` line still appears, so this is pre-existing and
not caused by that work.

### Why it is a defect and not a detail

⚠️ **It is the exact thing the API's own doc comment forbids.**
[`NDIService.refreshRuntimeStatus`](../App/NDI/NDIService.swift#L266) says *"Call it lazily (Settings
opening, streaming UI appearing), **NOT at app launch**"*, and
[`runtimeAvailable`](../App/NDI/NDIService.swift#L99) documents detection as lazy and relaunch-only.
The rule is followed everywhere it is stated and broken by a call that does not mention it.

⚠️ **AND `loadRuntime` IS NOT A PROBE.** `NDILoadOnce` `dlopen`s the runtime, resolves a loader
symbol, calls `load()`, **and then `lib->initialize()`** — standing NDI's machinery up (threads,
discovery infrastructure) for users who never touch NDI. The time is small (**2.7 ms measured, with
the runtime present**) and the time is not the objection; the side effect is.

### The second half, which is worse for callers

⚠️ **That call site bypasses the publish.** `refreshRuntimeStatus()` and `startDiscovery()` both set
`runtimeAvailable` from their load result; this one calls the bridge directly and sets nothing. **So
the runtime is loaded while `runtimeAvailable` is still `false`** — the flag is not merely stale, it
is wrong in the direction that reads as "NDI is unavailable".

The window closes when the empty state's `.onAppear` reaches `startDiscovery()`, and the comment at
the call site is explicit that the direct call exists as *"an ordering-safe fallback should the
empty state render before the flag publishes"* — so the ordering hazard was known. **What was not
weighed is that the fallback's side effect is enormously larger than the question it answers**: it
initialises the whole runtime to decide which of two disabled menu labels to draw.

⚠️ **This already cost something.** `NDIService.runtimePresence` — the three-state filesystem check
added 2026-09-09 for the conditional menu item — exists **because `runtimeAvailable` could not be
trusted at launch**. A cheap `fileExistsAtPath` was the right tool for that job anyway, but the
reason it had to be written at all is this entry.

### Not fixed on purpose

The obvious shapes are to publish through `NDIService` instead of calling the bridge directly, or to
have the empty state use `runtimePresence` for its "runtime not installed" label and stop calling
`loadRuntime` in a view body at all. **Neither is attempted here** — it is a live UI path, the
current behaviour is at least self-consistent, and nothing depends on changing it today.

---

## ✅ WHAT LANDED, 2026-09-17 — HLS audio: metered, SDI-fed, audible, and on the item's own clock

**Status:** LANDED, built and verified against Apple's `bipbop_16x9` ladder on macOS 26.5.1 (25F80).
**Preceded by:** *"✅ SHIPPED — HLS as a source"* above, whose picture half shipped in 0.8.2.

HLS was picture-only: `player.isMuted = true`, no tap, meters flat, SDI silent. It now feeds the
shared `AudioTapBuffer`, and the stream is audible on the default output device.

**New file** `App/HLS/HLSAudioTap.swift`; edits to `HLSClient`, `WindowDeck` (`DeckRegistry`),
`AudioTapBuffer` (a `.hls` case on `SourcePath`) and `FrameEngine` (one new seam, below).

### The seam is `pushInterleavedInt32`, and THERE IS NO FLOAT PATH

⚠️ **A "float path that already existed for NDI and had no caller" DOES NOT EXIST — do not go
looking for it.** `AudioTapBuffer` has exactly two entry points: `ingest(_:path:)` (a
`CMSampleBuffer`) and `pushInterleavedInt32(...)`. **NDI uses the latter and always has**
(`NDIService.runAudioPump`), so it is neither float nor uncalled. The ring itself is
`private var ring: [Int32]` — "card-ready" Int32 is the buffer's stated contract, `ingest`
converts float32 to Int32 internally, and DeckLink embeds Int32.

The tap delivers **Float32 NON-INTERLEAVED**, so `HLSAudioTap` interleaves and converts to Int32
in the process callback and calls `pushInterleavedInt32` — the same call NDI makes, same arguments
in the same order. The conversion arithmetic is copied from `ingest` clamp-for-clamp on purpose:
the meters' clip detector keys off `clipThresholdInt32` (−0.1 dBFS as an Int32 magnitude), so a
different rounding would make HLS meter differently from every other producer for the same signal.
Verified against an independent recomputation of channel 0: **0 mismatches**.

### ⚠️ THE CLOCK WAS FREE, AND IT WAS MEASURED. DO NOT ADD RECONCILIATION LATER.

**Audio and video out of an `AVPlayerItem` are two reads of ONE clock.** The item's timebase drives
both, and its source clock is the audio output device itself — the probe printed
`FigClock[AudioDeviceClock(deviceID=154, trackDefaultDevice=true)]`. **AVFoundation is already
doing the lip-sync.** There is nothing to reconcile.

Measured, 238 consecutive callbacks over 20 s:

- the tap's `timeRangeOut` is on the **item's timeline** — started at 0.0000, advanced 0.08533 s
  per callback, **0 backwards steps, 0 discontinuities > 2 ms**;
- it leads presentation by a **constant render-ahead** — `range.start` minus
  `CMTimebaseGetTime(item.timebase)`, read at the same instant inside the callback, was +0.2910,
  +0.2909, +0.2910 … flat to ±0.1 ms after the first few callbacks;
- the item↔host mapping is flat too: `hostTime − itemTime` moved **−0.000266 s over 39.7 s with
  zero steps > 10 ms**, a −7.8 ppm residual that is the audio device crystal against mach time and
  which **never accumulates**, because the mapping is re-read per buffer rather than integrated.

The entire clock handling is one subtraction on the drain thread:

```swift
pts = itemTime + (hostAtCallback - output.itemTime(forHostTime: hostAtCallback).seconds)
```

— the same `itemTime(forHostTime:)` mapping `HLSPull.capture()` already queries every display tick,
used to put audio on the same host axis video is stamped with (which DeckLink's
`read(framesStartingAt:)` requires, since it keys off the video frame's PTS). One reading, no state,
no filter, no loop. Verified live: audio PTS advances at exactly 1.0 against the host clock, never
backwards, and **A/V agree to a mean of +1.8 ms**.

> **NO `LiveClock`, NO SENTINEL, NO CUSHION, NO EPOCH LATCH, NO DRIFT PID, NO RATE SLEW.** WHEP
> needed those because its audio and video arrive on separate SSRCs with independent random RTP
> bases — hence its stage-1 "SSRCs ASSUMED aligned" assumption and the `-.infinity` `LiveClock`
> sentinel fix. SRT took three stages for its own reasons. **NEITHER APPLIES HERE.** If you are
> about to add reconciliation to this path, re-measure first; do not add it because the other two
> have it.

⚠️ **THE RENDER-AHEAD AND THE BUFFER SIZE ARE PROPERTIES OF THE OUTPUT DEVICE, NOT OF HLS.** Here:
`maxFrames` 4096 (85.3 ms) and +291 ms lead against a Scarlett 18i20 at 48 kHz. Both have been seen
much smaller elsewhere (1024 frames, ~164 ms) — **the two co-vary and neither is a constant to
pin.** Nothing in the code hardcodes either: the frame count comes from the callback argument and
the lead falls out of the mapping. A figure baked in from one machine's interface is a bug waiting
for a different one.

**What "no drift" does NOT mean is "no discontinuity".** Over 292 callbacks the PTS never went
backwards, but took four steps past `AudioTapBuffer`'s 50 ms tolerance: three during the first
~250 ms (+0.085, +0.085, +0.120 s — the render-ahead ramping in) and **one of +0.817 s mid-stream**
(a rebuffer or rendition change; the item timeline genuinely jumped and the PTS correctly followed).
Each makes `append` re-anchor and drop its window, so **a rendition change costs a brief SDI audio
dropout**. That is the ring doing its job, not a clock fault.

### ⚠️ THE TAP SITS *AFTER* THE MUTE — MEASURED, AND THIS CORRECTS AN EARLIER CLAIM

The claim that "the tap sits before the mute, so buffers carry signal with `isMuted` true" is
**false and was measured false three independent times.**

| condition | result |
|---|---|
| `isMuted = true`, PostEffects | **238 of 238 buffers ALL ZERO**, peak exactly 0.0 |
| `isMuted = true`, PreEffects | **239 of 239 ALL ZERO** — Pre/Post is about the MIX's effects, not the player's mute stage |
| `isMuted = false` | 200 zero / 38 signal, peak −1.8 dBFS (bipbop is beeps with silent gaps) |
| `volume = 0.02` | same source buffer at **−35.7 dBFS** vs −1.8 at 1.0 — a 33.9 dB drop against the 33.98 dB the volume implies |

So **`AVPlayer.isMuted` and `AVPlayer.volume` both sit UPSTREAM of the tap.** Leaving the mute on
would have failed in the worst available way: callbacks firing, format published, meters sized,
DeckLink re-establishing its audio stream — and every sample silence, with every status line
reporting success. `player.isMuted = false` and `player.volume = 1.0` are now **pinned**, and the
monitoring decision is applied at the tap's OUTPUT instead.

### Passthrough does not disturb capture — verified, not assumed

Two 20 s runs, identical but for whether the tap returns its frames or returns 0:

|  | returns 0 frames | passes through |
|---|---|---|
| callbacks | 238 | 238 |
| all-zero buffers | 200 | 200 |
| signal buffers | 38 | 38 |
| session peak | **0.8164637** (−1.8 dBFS) | **0.8164637** (−1.8 dBFS) |
| loudest 10 | #213 @ 18.176 s, #96 @ 8.192 s, … | identical indices, times, dB |

**What the tap RECEIVES is independent of what it RETURNS**, so the meters and the SDI embed read
identically either way and this decision can be reversed without touching them.

### The attachment is a WILDCARD trackID, and the documented form is the one that fails

`AVMutableAudioMixInputParameters(track:)` — the form every example uses — produces a tap that
**never fires** on an HLS item. Isolated 20 s cells: bound to the item's audio `assetTrack`
(trackID 1) → **0 callbacks**; bare `AVMutableAudioMixInputParameters()`
(`kCMPersistentTrackID_Invalid`) → **235 callbacks**; bare params with `.trackID` set explicitly →
**0 callbacks**. It is not the initializer — **any non-invalid trackID silences it.** An HLS
`AVURLAsset` vends no `AVAssetTrack`s at all (`asset.tracks.count == 0`) and the synthesised
`AVPlayerItemTrack.assetTrack.trackID` is **not stable across sessions** (1 in one run, 5 in
another), so it is not an identity worth keying to. Do not "fix" this by looking the track up.

### Channel count is carried; roles are measured-absent

Derived from `mNumberBuffers` **every callback**, never cached from `prepare`, because an ABR
rendition switch can move the format **with the tap still alive** — measured: switching audio
rendition mid-stream produced no `unprepare`, no re-`prepare`, and the callbacks continued. The
count is passed straight through so `AudioTapBuffer`'s own comparison fires `onFormatChange` →
`DeckLinkService.audioFormatChanged`, the existing path that re-establishes the SDI stream. Wider
than 16 channels is **refused and counted**, never folded.

⚠️ **bipbop is stereo and nothing wider was testable. The multichannel path is written but
unexercised — do not read it as verified.**

Roles come back empty, and that is **measured absence, not an unimplemented feature**: the HLS
`AVURLAsset` vends no `AVAssetTrack`s, the item's synthesised audio track carries **no
`AudioChannelLayout`** (checked at runtime — its format description reports 22050 Hz AAC and a nil
layout), and the tap's ASBD has none either. Empty means the meters show NUMBERS, which is this
codebase's stated answer for a source that declares nothing.

### Threading and teardown

The process callback is AVFoundation's **real-time thread** — one dedicated thread for the whole
session, never main, never migrating, QoS unspecified. `MTAudioProcessingTap.h` forbids allocation
and blocking calls there, and `pushInterleavedInt32` → `append` both allocates on a format change
and takes an `NSLock` **that DeckLink's audio callback also takes at 50 Hz**. So the callback
follows **WHEP's rule** (`WHEPAudioReceiver.receive`: *"Copies and gets off immediately"*) with a
preallocated target, handing off to a drain thread modelled on **NDI's** `startAudioPump` /
`stopAudioPump`. Both disciplines already existed; neither was invented.

**Teardown** is `HLSClient`'s existing shape: `retired` flag first (an in-flight callback reads it
and returns having touched nothing), then **join the drain thread** — we own that one, so a join
*is* available and is taken — then detach the mix. The tap's own callback thread is never joined
and does not need to be.

⚠️ **THE RETAIN CYCLE, FOUND IN REVIEW AND FIXED.** A C function pointer cannot capture context, so
the tap is handed `Unmanaged.passRetained(self)` as `clientInfo` — **the tap holds a +1 on
`HLSAudioTap`**, while `HLSAudioTap` holds the tap (`tapRef`, and again via `audioMix`). The
balancing `release()` lives in `finalize`, which AVFoundation runs only once the **last** reference
to the tap goes away — so keeping ours meant finalize never fired and **every HLS connect leaked
the object and its 4 MB relay.** `detach(from:)` now drops all three references, and a `deinit` log
line proves the chain completed.

⚠️ **THE RELEASE IS IN `finalize`, NOT `unprepare`, AND THE REASON IS THE CONTRACT RATHER THAN A
THREAD HAZARD.** `MTAudioProcessingTap.h` specifies finalize is *"called exactly once when the
`MTAudioProcessingTap` object is finalized"*, which is the only correct balance point for a
`passRetained`. `unprepare` is explicitly **paired and repeatable** — *"the callback may be called
multiple times"* — so releasing there would over-release on the second prepare/unprepare cycle. The
object unretained is `HLSAudioTap`, not `HLSClient`; `HLSClient` is never retained by the tap.

### The audio controls DO reach it — `FrameEngine.externalAudioOutput`

**This was going to be filed as a defect and was instead fixed the same day**, so it is recorded
here rather than below. HLS is the only transport whose audio never enters the engine's shared
`AVSampleBufferAudioRenderer`, so `applyAudioMute` could not govern it: the toolbar mute, the volume
fader and the SDI/Computer destination all missed it, and with DeckLink enabled the program would
have been audible from the card and the Mac at once.

`applyAudioMute()` now publishes its **already-combined** decision —
`isMuted || offSpeed || deckLinkOwnsAudio`, plus the fader — through a new
`FrameEngine.externalAudioOutput` seam, which `DeckRegistry` routes to
`HLSClient.applyAudioOutput` → `HLSPull.setMonitor` → `HLSAudioTap.setMonitor`. **One rule,
computed once, applied to two outputs** — the callee never re-derives the terms, which is what
keeps it from becoming a second control. The hook is on the **decision, not the connect**, so a
change made after connect reaches a running player; `didSet` fires it once at wiring time, and
`HLSClient` caches the last value so a stream connected while already muted comes up correct.

⚠️ **IT IS APPLIED AT THE TAP'S OUTPUT, NOT AT `player.isMuted` / `player.volume`** — forced by the
measurements above, which would otherwise blank or attenuate the meters and the SDI ring. **And
the fader had to stay pre-fader to match files:** `FrameEngine`'s file pump does
`tap.ingest(next)` *then* `aRenderer.enqueue(next)`, with the fader on `audioRenderer.volume`
applied inside the renderer — so **a file's meters are pre-fader and keep moving while muted.**
Putting the gain on `player.volume` would have made HLS the one source whose meters fall when you
turn monitoring down. `AVPlayer.volume` and `AVSampleBufferAudioRenderer.volume` are documented in
identical words (0.0 silence, 1.0 full) with no curve on either, so the scale needed no conversion;
only the insertion point mattered.

Verified: at gain 0.25 the relay saw 0.8164637 (−1.8 dBFS) while the output carried 0.20411593
(−13.8 dBFS) — **ratio exactly 0.2500**; when muted the relay still saw 0.8164637 while the output
carried zero frames on all 259 callbacks.

### Not verified

- **Nothing has been run inside the app.** Every measurement above is from standalone probes
  against the live stream. The assembled path compiles and its pieces are verified individually;
  the meters lighting up in Manifold itself has not been observed here.
- **The desktop audio has not been confirmed by ear from within the app**, only that the samples
  leaving the tap carry signal at the expected level.
- **Live (non-VOD) playlists.** bipbop is a 1800 s VOD; a sliding-window live playlist is untested,
  and live is the actual use case for this feature.
- **Multichannel**, as above.

---

## FIXED — NDI had no desktop playback path: five stacked defects, each masking the next
<!-- Original title, kept because other entries cite it: "NDI has no desktop playback path at
     all — the pump meters, feeds SDI, and drops the audio". -->

**Status:** FIXED 2026-09-18, after **five stacked defects** — see "The chain" immediately below,
which is the part worth reading. The presentation lead is now **250 ms**, an evidence-backed floor;
the true threshold is between 40 and 150 ms and is not narrowed. The analysis further down is kept
because it is the reasoning the fix rests on.

### ⚠️ THE CHAIN — FOUR BUGS, EACH ONE HIDING THE NEXT

Nothing here was discovered until the one in front of it was fixed. That is the whole lesson of this
entry, and it is why each fix looked complete and each next symptom looked like a new problem.

| # | defect | symptom while it was on top | what it hid |
|---|---|---|---|
| 1 | FrameSync asked for `framesync_audio_queue_depth`, so it **manufactured 82% of the samples** (8.1M delivered against 1.44M sent) | meters read levels off invented audio | everything |
| 2 | the pull was sized from the **nominal** poll interval, not measured elapsed — a 44030 Hz consumer declared against a 48000 Hz stream | `cum=44030Hz`, `depth` sawtooth, ring re-anchoring ~2/s | the clock was declared unusable on this evidence |
| 3 | the desktop PTS was a **wall-clock read per pull**, while the sample count came from a different elapsed measurement inside the bridge | crackle — mean \|residual\| 0.15–0.57 ms (7–27 samples), ~50 gaps + ~40 overlaps per second | #4, entirely |
| 4 | the PTS was built with **`preferredTimescale: 90_000`**, which cannot represent a 48 kHz sample position unless the sample count is a multiple of 8 | crackle again, finer — ≤0.27 samples, 7 buffers in 8 | #5 |
| 5 | the desktop presentation lead was **40 ms**, far below what this renderer needs | crackle again — and now with every buffer provably perfect | — |

⚠️ **#1 IS WHY THE ENTRY ORIGINALLY SAID THE PUMP'S CLOCK WAS UNUSABLE** ("not a timebase an
`AVSampleBufferAudioRenderer` can be anchored to"). That was a conclusion drawn from a broken pump
and it sent the design down a resample/drop-pad/slave-the-timebase path that was never needed. It is
retracted below.

### ⚠️ #5 — THE RENDERER HAD BEEN REPORTING IT SINCE THE FIRST SESSION AND NOTHING READ IT

`AVSampleBufferAudioRenderer.hasSufficientMediaDataForReliablePlaybackStart` read **NO on every
sample of every session** while `status` read `rendering` — the renderer playing while permanently
below its own declared threshold. It was there for the whole investigation. Nothing on the live path
has ever consulted it, or `status`, or `error`, or `isReadyForMoreMediaData`: `LiveAudioSink.enqueue`
is `tap.ingest` then `renderer.enqueue`, unconditionally. **Every FILE path in this app does the
opposite** — `LibavAudioSource`, `FileFrameSource`, `LibavFrameSource` and `beginAudioReading` each
drive a `requestMediaDataWhenReady` + `while isReadyForMoreMediaData` pump. The live path is the only
consumer in the codebase that pushes blind, so this class of failure is structurally invisible on it.

**MEASURED** with a runtime-adjustable lead (`Debug ▸ Desktop Audio Lead`), real programme,
reproducible in both directions:

| lead | result |
|---|---|
| 40 ms | crackly |
| **150 ms** | **clean** |
| 250 / 300 / 400 / 600 ms | clean |
| back to 40 ms | crackly again |

Shipped default: **250 ms**, which is SRT's `targetDepth` — the smallest lead anywhere in this app
measured clean through this same renderer. **An evidence-backed floor, not a measured optimum.**

**The true threshold is between 40 and 150 ms on this machine, and was deliberately not narrowed**,
because nothing depends on the exact value: 250 ms is comfortably above it, matches a lead already
proven in this app, and costs 250 ms of desktop monitoring latency that a QC operator will not
notice. Narrowing it would have bought precision nobody can spend — and the figure would be specific
to this output device anyway.

⚠️ **DO NOT DERIVE THIS FROM THE +291 ms RENDER-AHEAD THE HLS WORK MEASURED.** That was the leading
hypothesis for the mechanism and **150 ms being clean refutes it** — the threshold is nowhere near
291. The render-ahead may be why *a* lead is needed at all; it does not set the size of one.

### ⚠️ RETRACTED: `sufficientForStart=NO` WAS NEVER EVIDENCE OF STARVATION

This entry briefly framed `hasSufficientMediaDataForReliablePlaybackStart` reading NO as the
renderer reporting its own starvation. **That framing is wrong and is withdrawn.** Re-run with
working instrumentation, it reads **NO at every rung — 40, 150, 250, 300, 400 and 600 ms — while
only 40 ms is audibly distorted.** It does not track the threshold, it does not track audible
cleanliness, and on this path it appears to read NO unconditionally.

It looked like evidence for exactly one reason: **it was first observed at the only rung that was
also broken.** A constant mistaken for a measurement because it was sampled once, where the fault
was.

**So no adaptive loop.** Growing the lead until that property flips was the obvious next step and
would have been machinery built on a coincidence — a control loop driven by a signal that never
changes. Fixed 250 ms is the honest answer.

The instrumentation failure that delayed this is worth its own note: the `renderer:` line was nested
inside the push closure, behind `if let sink`, behind `guard let sb`, and in grouped mode behind "a
group completed this tick". It printed five lines, all at 40 ms, then stopped at the first lead
change — so the first ladder run had **no reading at any clean rung** and the correlation looked
plausible because nothing contradicted it. It now runs from the pump loop, outside every one of those
guards, and forces a reading at each new rung.

### ⚠️ THE MOST TRANSFERABLE THING THIS INVESTIGATION PRODUCED — FOUR INSTRUMENTS THAT READ THE SAME WHETHER OR NOT THE FAULT WAS PRESENT

Every one of these was trusted at the time. Every one of them read "fine" across a defect it was
positioned to catch. **The recurring failure in this chain was not bad reasoning about audio — it was
believing instruments nobody had ever watched respond to a known change.**

| instrument | what it read | what it was blind to |
|---|---|---|
| **the meters** | plausible levels | 82% of the samples were synthesised by FrameSync (#1) — a level is a level whoever made it |
| **`cum` / `real=Nf` / `underruns=0`** | 48000 Hz, ring read, no underruns | *whether the bytes were right*. These count transactions, not contents. "SDI plays this cleanly" rested on them and was never true as stated — nobody had listened |
| **`recordPTSContinuity`** | `0.000 ms` residual | it compared `Double`s, and #4 was a rounding that happened in `CMTime`. A PTS can be exact to twelve decimals in seconds and unrepresentable on its own timescale — which is how #4 hid behind the fix for #3 |
| **`hasSufficientMediaDataForReliablePlaybackStart`** | `NO` | everything. It reads NO at every lead, clean or broken (#5) |

The rule that falls out, and the one worth carrying to the next investigation: **before trusting an
instrument, make it respond to a change you control.** The tone test, the WAV capture and the lead
ladder all earned their answers precisely because they were A/B-able — the WAV settled bytes-versus-
playback in one listen after four rounds of inference had failed to.

And a corollary specific to this file: **a diagnostic that can be suppressed by the thing it is
diagnosing is not a diagnostic.**

The Debug lead ladder stays in the build for the same family of reasons: the lead is a property of
the output device, 150 ms clean is one machine and one interface, and the next person on different
hardware needs to check it by stepping it live rather than by trusting this table.

⚠️ **#3 AND #4 ARE THE SAME SYMPTOM AT TWO SCALES, AND THAT IS WHY #4 SURVIVED THE FIX FOR #3.**
Both are splices. Fixing #3 took the residual from 7–27 samples to zero *as measured in `Double`
seconds* — and the instrumentation measured Doubles, so it reported `0.000 ms` and looked clean while
the audio was still crackling. **A PTS can be exact to twelve decimal places in seconds and
unrepresentable on the timescale it is stored at.** The grid check that catches this now prints the
PTS as raw `value/timescale` with the rounding error in ticks and samples, because in seconds it is
invisible.

### ⚠️ THE GENERAL RULE: AN AUDIO CMTime BELONGS ON THE SAMPLE RATE'S TIMESCALE

```swift
CMTime(value: anchorTicks + cumulativeFrames, timescale: CMTimeScale(sampleRate))
```

Not 90 kHz, which is the video/mux grid, and not seconds. On the sample rate's own timescale a
sample position is a tick by definition, `duration` is `1/sampleRate` on the same scale, and buffer
n's end is bit-identical to buffer n+1's start rather than merely equal as a `Double`. There is
nothing left to round, at any frame size and any sample rate.

**90000/48000 = 1.875**, so `n/48000` lands on an integer 90 kHz tick exactly when `n` is a multiple
of 8. This is the test to apply to any audio PTS on a foreign timescale.

⚠️ **WHEP AND SRT BOTH PASS THIS TEST BY COINCIDENCE, AND NEITHER IS SAFE BY DESIGN.** Audited, and
noted in a comment at each call site:

* **WHEP** — Opus at 48 kHz is **960 samples** per packet and the PTS is a running multiple of 960.
  960 % 8 == 0, so every value lands on the grid. Any other packetisation breaks it silently.
* **SRT** — the PTS *is* a 90 kHz value (`packet.pts × 1/90000`), so nothing is rounded on the way
  in; and AAC-LC's **1024** frames → 1920 ticks at 48 kHz, HE-AAC's 2048 → 3840. Both integral.
  ⚠️ **At 44.1 kHz it would NOT be**: 1024 × 90000/44100 = 2089.79… ticks, and SRT would crackle
  exactly as NDI did.
* **The file path already does it correctly** — `LibavAudioSource` stamps on the stream's own
  timebase, whose denominator is the sample rate for audio. That was the pattern to copy and it was
  in the repo the whole time.
* Video PTS at 90 kHz (`HLSClient`, `NDIService`, `SRTFrameRouter`, `WHEPFrameRouter`) and the
  synchronizer anchors in `FrameEngine.mirrorLiveAudio` / `anchorLiveAudio` are **not** affected:
  none of them is a sample-exact splice point.

⚠️ **AND THE WRONG NUMBER IN A COMMENT IS WHAT PROPAGATED IT.** `WHEPAudioReceiver.makeSampleBuffer`
said 48 kHz frames land on 90 kHz ticks "only every 15 samples". It is every 8. That comment is why
the timescale looked safe to reuse for NDI. It has been corrected in place (comment-only; WHEP's
behaviour is untouched). **This is the third time in this file that a confident, mechanism-shaped
comment has been the actual propagation vector for a bug** — see also the two inverted
`framesync_audio_queue_depth` claims. Treat prose here as a claim to check.

**Found:** 2026-09-17, while comparing transports for the HLS audio work. **Re-diagnosed:**
2026-09-18, from source, after the pump was fixed. **Blocks:** monitoring an NDI source on a machine
with no DeckLink card.

`NDIService.runAudioPump` pulls with `captureAudioFrameForInterval:`, pushes interleaved Int32
into the shared `AudioTapBuffer`, and **stops there**. The ring feeds the meters and the SDI embed;
nothing enqueues into `FrameEngine`'s `audioRenderer`, so **an NDI source is silent on the Mac** no
matter what the fader says. `WindowDeck` stated it plainly at the wiring site: NDI *"feeds the tap
alone (metered and SDI-capable, but silent on the desktop)"*. ⚠️ **That comment no longer exists** —
the wiring site now carries the four desktop-audio seams and a note that the tap is the FALLBACK
route. The quote is the code as it stood before commit `786c0d8`.

**Manifold is a desktop player first, so this is a defect and not a scoping choice.** A colourist
without a card can see an NDI feed and cannot hear it.

### ⚠️ AS FOUND (2026-09-17): WHEP AND SRT ARE *NOT* THE SAME SHAPE — NDI IS THE ONLY SILENT ONE

**This section describes the state that motivated the work. NDI is no longer silent** — see the
chain above. It is kept because the per-transport shapes, and the warning about lumping them
together, are still correct and still the thing people get wrong.

This is the correction that matters for anyone sizing the work, and it is easy to get wrong because
all three are "live sources":

| transport | audible on the desktop? | how |
|---|---|---|
| **NDI** | ~~**No**~~ → **Yes** (2026-09-18) | ~~tap only~~ → `beginLiveAudio` → `LiveAudioSink` → shared `audioRenderer`, with a **250 ms** presentation lead and a direct timebase anchor instead of a LiveClock mirror |
| **WHEP** | **Yes** | `beginLiveAudio` → `LiveAudioSink` → shared `audioRenderer` |
| **SRT** | **Yes** | same, since its stage 2 |
| **HLS** | **Yes** | `AVPlayer`'s own output (a pull source owns one) |

`WHEPFrameRouter.startAudio` and `SRTFrameRouter` both call `beginLiveAudio(...)` and enqueue
through `FrameEngine.LiveAudioSink`, which tees to the tap and then to the renderer. SRT's own
header records the transition: *"STAGE 2: AUDIBLE ON THE LIVE CLOCK … the only new consumer is the
speaker."* **Any comment claiming SRT is "tap only / stage 1" is stale.**

### ⚠️ THE OLD FRAMING WAS WRONG AND IS RETRACTED — THE PUMP'S CLOCK IS FINE

This entry used to say NDI's pull-time `monotonicNow()` stamp *"is **not** a timebase an
`AVSampleBufferAudioRenderer` can be anchored to"*, and that the decision to make was **resample vs
drop/pad vs slaving the timebase to a mapping NDI does not produce**. **That was written while the
audio pump was broken** — it was drawing 5.6× manufactured samples on a cadence that meant nothing
(see #NDI-AUDIO), so of course its clock looked unusable. It was a property of the defect, not of NDI.

With the pump fixed, measured over 72 s: `cum=48006.6Hz`, `sndR=48015.5Hz` from the sender's own
timestamps, `dev` +0.01..+1.02 ms, **zero ring re-anchors**. And `monotonicNow()` is
`CACurrentMediaTime()` (`NDIService.monotonicNow()`) — literally the axis
`AVSampleBufferRenderSynchronizer.setRate(_:time:atHostTime:)` takes as `atHostTime`. **NDI's PTS
axis is not the problem and never needed a resampler.** None of the three options above is the
decision to make. Strike the question.

### What it actually needs — a RE-ANCHOR DRIVER, which is the one thing NDI has no source for

The seams exist and are proven twice over, but `beginLiveAudio` → `LiveAudioSink` **on its own
produces silence, not drift**, and then drift once it is made to play. Four findings from source:

1. **`beginLiveAudio` parks the synchronizer at rate 0 and holds it there.**
   `FrameEngine.swift:2160` — `synchronizer.rate = 0 // held until the first mirrored mapping
   arrives`. The only thing that ever starts it is `mirrorLiveAudio`, which takes a
   `LiveClock.Mapping`. **NDI produces no mappings, so NDI audio would never begin.** Not a subtle
   failure — total silence.

2. **NDI cannot even fabricate one.** `LiveClock.Mapping` (`LiveClock.swift`, the `Mapping` struct) declares three
   `public let`s and **no explicit `public init`**, so its memberwise initialiser is internal to
   `ManifoldCore`. `NDIService` is in the app module. This is a compile-time wall, not a style
   preference.

3. **⚠️ THE SYNCHRONIZER'S TIMEBASE RUNS ON THE AUDIO DEVICE CLOCK, NOT ON MACH TIME.** From the SDK
   header, `AVSampleBufferRenderSynchronizer.h:31-33`, verbatim: *"By default, this timebase will be
   driven by the clock of an added `AVSampleBufferAudioRenderer`. If no `AVSampleBufferAudioRenderer`
   has been added, the source clock will be the host time clock."* `FrameEngine.swift:476` does
   `synchronizer.addRenderer(audioRenderer)` unconditionally at init, **so the first clause is the
   one in force for every live session.** A mach-axis PTS stream therefore drifts against this
   timebase at the two crystals' offset — the same **−7.8 ppm** the HLS work measured
   (`HLSAudioTap.swift:48`), ≈ 28 ms/hour on that machine, and NOT a constant to assume elsewhere:
   that file is explicit that such figures are properties of the output device.

4. **⚠️ AND THE PUSH DECISION IS OPEN-LOOP, SO IT CANNOT SEE THAT DRIFT.** `mirrorLiveAudio`'s
   gate (`FrameEngine.swift:2336-2341`) is

   ```swift
   let predicted = mirror.pushedMedia + (m.hostTime - mirror.pushedHost) * mirror.pushedRate
   let positionError = wasMirrored ? abs(target - predicted) : .infinity
   ```

   `predicted` is computed **entirely from what was last pushed plus host time**. It never reads
   `synchronizer.currentTime()`. Both `target` and `predicted` live on the mach axis, so the device
   crystal is invisible to `shouldPush` by construction.

### So why don't WHEP and SRT drift? Incidentally — and that is the finding

Every `setRate(rate, time:atHostTime:)` is an **absolute re-anchor**: per the same header, *"the
timebase is adjusted so that its time will be (or was) `time` when host time is (or was)
`hostTime`"*. It wipes whatever device-clock drift had accumulated since the last one.

WHEP and SRT get those re-anchors **for free, as a side effect of something else**: `LiveClock`
slews `rate` continuously within ±0.5% to regulate *video* buffer depth, `rateMoved >
liveAudioRateThreshold` (0.02%) fires, and a push lands. Nobody wrote a drift corrector — the
video-depth P-loop is one, accidentally, because its output happens to be routed through an
absolute-anchoring API. `FrameEngine`'s own estimate of the worst case is *"a full minute between
pushes costs 12 ms"*, i.e. the design already tolerates ~12 ms of open-loop error **between**
re-anchors. The point is that for WHEP and SRT it is bounded by the next rate change, and there is
always a next one.

### ⚠️ WHICH MEANS WHEP AND SRT ARE ONE "OPTIMISATION" AWAY FROM THE SAME DEFECT

**If `LiveClock` ever stops slewing, WHEP and SRT silently become unbounded too.** Nothing in the
audio path would notice, because nothing in the audio path is looking: `mirrorLiveAudio`'s gate is
open-loop (finding 4 above), so the error lives on an axis none of its counters measure.

The ways to stop the slew all look like improvements and none of them mentions audio:

* pinning `rate` at unity for a **low-latency mode** — `forceUnityRate` already exists and does
  exactly this, today, as a ⌃⌥U diagnostic;
* setting **`maxSlew = 0`** to "disable the video control loop";
* an early return on **"depth is stable, stop correcting"**.

**The only symptom would be slow lip-sync drift over a long session, with every counter reading
clean.** `[WHEP-AUDIO] mirror` would report `0 setRate call(s)` — which is what a settled, healthy
clock is *supposed* to look like — and `liveAudioDrift` reports the timebase against `LiveClock`,
which is precisely the pair that stays in agreement while both drift away from the output device.

⚠️ **THE COMMENT AT THE SLEW SITE IS THE PRIMARY RECORD OF THIS, NOT THIS ENTRY.** See
`LiveClock.updateDepthLocked`, with pointers from `maxSlew` and `forceUnityRate`. That placement is
deliberate and the precedent is in this same file: the inverted `framesync_audio_queue_depth`
guidance survived for as long as it did because it was wrong **at the call site**, which is the only
place anyone looked. A caveat that lives only in `docs/` is a caveat that will be discovered
afterwards.

⚠️ **NDI INVERTS THIS, AND THE INVERSION IS THE WHOLE ANSWER TO "IS RATE 1.0 SIMPLY TRUE FOR NDI?".**
Yes — nothing slews NDI's rate, so the *"ASSUMPTION WITH A KNOWN EXPIRY"* never expires. **But the
slew is exactly what was doing the correcting.** A transport that genuinely runs at 1.0 pushes
once and never again — identity mapping in, `positionError == 0` forever out — and then integrates
the crystal offset with nothing to reset it. **Removing the thing that made the assumption false is
what makes the drift unbounded.** WHEP and SRT are bounded by accident; NDI would be unbounded by
correctness.

### Does FrameSync's TBC cover it? No — it reconciles the wrong seam

FrameSync's time-base corrector resamples the **sender's** audio to match **our consumption rate**,
and after the pump fix we consume at exactly 48000 per mach-second. That closes sender ↔ us, and it
is why `sndR` and `cum` both read 48000. It says nothing about **us ↔ the output device**, which is
a seam entirely outside the NDI SDK. Each transport does reconcile drift at a different layer, as
suspected — but NDI's layer stops one seam short of the speaker, and no other layer picks it up.

### ~~The decision — SHIP THREE, NOT FOUR~~ → SUPERSEDED: the fourth was built

**The closed-loop option below was implemented on 2026-09-18.** What landed, and where:

* `FrameEngine.anchorLiveAudio(mediaTime:hostTime:)` — a `nonisolated` sibling to `mirrorLiveAudio`
  that sets the timebase unconditionally at rate 1.0. **A `public init` on `LiveClock.Mapping` was
  considered and rejected: it does not work.** An identity mapping makes the mirror's `predicted ==
  target` by construction, so `positionError` is 0 at every call and `shouldPush` is false after the
  first — a non-slewing transport would anchor once and never again, which is the very drift being
  fixed. The mirror cannot serve a transport that does not slew.
* **The read side needed no new seam at all** — `FrameEngine.currentSyncTime()` was already
  `public nonisolated`, and it is the only reading in the system taken on the audio device's clock.
* `NDIService.serviceDesktopAudioAnchor` — the loop, on the existing ~10 ms pump thread. Checks at
  **1 Hz**, re-anchors past a **10 ms** tolerance (`FrameEngine.liveAudioPositionTolerance`'s number,
  so both live-audio paths correct at one threshold), and logs every correction with the interval
  and the implied ppm, so **a machine whose crystals are further apart shows up as a higher
  correction rate rather than silently**. The ppm is nowhere pinned as a constant.
* The pump now enqueues through `LiveAudioSink` (Int32 → `CMSampleBuffer`, the same shape as
  `WHEPAudioReceiver.makeSampleBuffer`) **instead of** `pushInterleavedInt32` — the sink already tees
  to the tap, and keeping both would double-feed the ring. The direct tap push survives only as the
  fallback for an unwired seam, so meters and SDI cannot regress to silence.
* Mute, fader and `deckLinkOwnsAudio` now govern NDI for free, because it finally passes through
  `audioRenderer`.

⚠️ **THE 40 ms PRESENTATION LEAD IS THE OPEN NUMBER.** The timebase is anchored 40 ms behind the
pull clock so the renderer holds a queue — at zero lead a buffer is due the instant it is enqueued
and every pump hiccup is a gap. 40 ms is ~4 pull periods and ~40× the largest per-push deviation the
`[NDI-AUDIO]` trace has measured (+1.02 ms), **but it is also 40 ms of desktop lip-sync offset and
that has not been checked by ear.** SDI is unaffected — it reads the tap keyed to video PTS and
never consults this timebase.

The options as they were assessed, kept because the rejected ones explain the shape of the one that
landed:

* an **unconditional periodic re-anchor** (say 1 Hz identity mapping) is strictly worse than the
  mirror, not better — it injects a micro-discontinuity into a playing renderer every second, which
  is precisely why the mirror smooths `rate` and only moves position past a 10 ms tolerance;
* a **closed-loop re-anchor** — compare `CMTimeGetSeconds(synchronizer.currentTime())` against
  `monotonicNow()` on the existing ~10 ms audio pump thread and re-anchor past a tolerance — is the
  correct minimum. At 7.8 ppm it is one 10 ms correction every ~21 minutes. **But reading the actual
  timebase is something neither WHEP nor SRT does**, so it is a new mechanism, and it would need its
  own seam in `ManifoldCore` (both a `public init` on `LiveClock.Mapping` and a push path that
  bypasses `shouldPush`, or a dedicated entry point beside `mirrorLiveAudio`);
* a **rate slew** that nulls the offset properly is a PLL and is more machinery still.

Of the three, the middle one landed. The seam cost in `ManifoldCore` was **one method**, not the
two-part change anticipated here — because `currentSyncTime()` already existed.

**HLS is not a template for this.** It avoided the question entirely by having `AVPlayer` own the
output path — and note *why* that works, because it is the same mechanism in a different place:
`AVPlayerItem`'s timebase source clock **is the audio output device** (measured, printed by the
probe as `FigClock[AudioDeviceClock(...)]`, `HLSAudioTap.swift:36-37`), so there is no mach-vs-device
seam to cross at all. NDI is a push source with no player and cannot inherit that.

---

## WHEP SDI audio settles at a +68 ms drift plateau with the corrector saturated

**Status:** OPEN, and **PRE-EXISTING — today's SDI work exposed it, it did not introduce it.**
**Measured:** 2026-09-18, on the WHEP SDI audio verification run immediately after the sender-axis
fix landed (the same run that produced `real=1071435f`). **Affects:** WHEP only. SRT and HLS on the
same path are clean.

### The measurement

`DeckLinkAudio` periodic lines, one run:

| `srcT` | `drift` | `corr` |
|---|---|---|
| 5.340 s | +10.37 ms | +2f |
| 11.433 s | +35.98 ms | +2f |
| 17.506 s | +54.14 ms | +2f |
| 23.581 s | +66.97 ms | +2f |
| 26.605 s | **+67.90 ms** | +2f |

It **ramps and plateaus near +68 ms with `corr` pinned at +2f throughout**. The same path, same
build: **SRT stayed within ±2.5 ms oscillating around zero, HLS was sub-millisecond.** So this is a
property of WHEP, not of the SDI audio path.

⚠️ **`corr=+2f` IS THE RAIL, NOT A COINCIDENCE.** `kAudioMaxCorrectionFrames = 2`
(`DeckLinkBridge.mm`), the per-callback skip/duplicate limit. Pinned there for the whole run means
**the corrector is saturated**: it has enough authority to ARREST the growth — which is why the ramp
flattens rather than running away — but none left over to PULL THE OFFSET BACK. A plateau is what a
saturated corrector looks like, and it is easy to misread as "settled".

### Why WHEP and not the other two

From the same run:

```
[WHEP-DRIFT] senderRate=90085 tps (+0.094% vs receiver) | clockRate=1.0050 (+0.500%, RAIL)
             | depthCreep -0.0044 s/s observed vs -0.0041 predicted
             | REAL DRIFT — creep matches the measured sender rate
             | need maxSlew ≥ 0.094% + margin
```

Three facts, and the third is the one that matters:

1. **The sender and receiver clocks genuinely differ** — +0.094%, and the observed depth creep
   (−0.0044 s/s) matches the creep predicted from that rate (−0.0041 s/s), which is what the
   `REAL DRIFT` verdict tests. It is a clock offset, not a measurement artefact.
2. **`LiveClock` is at its rail**: `clockRate=1.0050` against `maxSlew = 0.005`. The control loop has
   no authority left either.
3. ⚠️ **THE LOG LINE IS THE CODE ASKING FOR A LARGER `maxSlew`.** `need maxSlew ≥ 0.094% + margin` is
   emitted by `WHEPFrameRouter` and its own comment says so: *"the slew the loop must be ABLE to reach
   just to break even. Whatever maxSlew is chosen must exceed this, with margin on top for the loop to
   have correction authority left over rather than sitting on a new rail."* **That line exists to be
   read as a request, and nobody had read it.**

### ⚠️ AN ASSUMPTION IN THE CORRECTOR'S OWN COMMENT THAT THIS MEASUREMENT CONTRADICTS

The drift-correction band in `DeckLinkBridge.mm` justifies its authority like this:

> 2 f/callback × 50 Hz ≈ 100 f/s ≈ 2 ms/s of authority — **~40× the ~50 ppm the clocks actually
> drift**, and each individual correction is a 20–40 µs skip/repeat (inaudible).

**The measured WHEP sender offset is +0.094% = 940 ppm — roughly 19× the ~50 ppm that sizing
assumed**, and `LiveClock` sitting on its +0.5% rail puts another 5000 ppm into the same budget,
which is well past the stated ~2000 ppm of authority. That is consistent with the observed
saturation.

⚠️ **BUT THIS DATA DOES NOT SEPARATE THE TWO CONSTRAINTS.** Whether the binding limit is the
corrector's ±2-frame authority, `LiveClock`'s ±0.5% rail, or both together is **not** established by
these five lines — both are provably saturated at the same time. Do not fix one and assume the
plateau moves. Instrument which one releases first.

### Is it shippable?

**+68 ms is ~1.6 frames at 24p.** That is inside broadcast acceptability, and it is audio LEAD, which
is the direction a careful ear picks up sooner than lag. It is a real defect and it is not a blocker.

### What it is NOT

⚠️ **NOT introduced by the 2026-09-18 SDI audio work.** That work is what made it *visible*: before
it, no live transport had ever embedded audio on SDI (see *"FIXED — `applyAudioMute` silenced SDI
audio for EVERY live source"*), so there was no wire on which a WHEP audio offset could be observed
at all. The sender/receiver clock offset and the railed `LiveClock` both predate it, and the
`[WHEP-DRIFT]` accountant that measures them was already in the build, already printing, already
asking for a bigger `maxSlew`.

---

## 📐 REFERENCE — the four live transports: which clock each one rides, and what `cushion` means

Not a defect. These are the facts that had to be re-derived from source three times during the
2026-09-18 NDI audio work because they lived only in scattered comments. **If you are about to reason
about live A/V sync, read this table first.**

### Which clock each transport's audio and video actually ride

| transport | video PTS | audio PTS | audio timebase driver | `cushion` passed to `beginLiveAudio` | desktop lead |
|---|---|---|---|---|---|
| **NDI** | `CACurrentMediaTime()` at the display tick | **sample-counted**: `anchorTicks + cumulativeFrames`, on the **sample rate's own timescale**, pinned to the wall clock | `anchorLiveAudio` — a direct anchor, re-anchored by NDI's own closed loop | **0** — it stamps on the axis the timebase sits on | **250 ms** |
| **WHEP** | `LiveClock.now()` | absolute sender time (`unwrap(rtpTimestamp) / 48000`) | `mirrorLiveAudio` — LiveClock's mapping | **0** — the receiver stamps sender-axis | LiveClock `targetDepth` **400 ms** |
| **SRT** | `LiveClock.now()` | the mux's 90 kHz PCR (`packet.pts × 1/90000`) | `mirrorLiveAudio` | **0.250** — it stamps on the `now()` axis, a depth behind the sender timeline | LiveClock `targetDepth` **250 ms** |
| **HLS** | the `AVPlayerItem` timebase | the same item timebase | none — `AVPlayer` owns its output | n/a | n/a |

⚠️ **NDI IS THE ODD ONE AND IT IS NOT AN OVERSIGHT.** It has no `LiveClock`, because FrameSync
already owns the jitter buffer and rate conversion, so there is no buffer depth to regulate. That is
why it anchors the audio timebase directly instead of mirroring a mapping — and why it needs its own
closed loop, since the incidental re-anchoring WHEP and SRT get from LiveClock's slew does not exist
for it. See the slew-site note in `LiveClock.updateDepthLocked`.

### ⚠️ `cushion` IS NOT A BUFFER DEPTH. THE NAME IS A TRAP.

`FrameEngine.beginLiveAudio(cushion:path:)` has exactly two consumers — `mirrorLiveAudio`'s
`let target = m.senderPTS - cushion`, and `liveAudioDrift`, which adds it back. In both, what it
means is:

> **HOW FAR BEHIND THE MAPPING'S `senderPTS` DOES THIS TRANSPORT STAMP ITS AUDIO PTS?**

It puts the synchronizer timebase on the **same axis as the PTS the caller will feed it**. A
transport stamping absolute sender time passes **0**. One stamping on `LiveClock.now()` — which is
held `startupDepth` behind the sender timeline — passes that depth.

**Pass the wrong one and desktop audio is early or late by exactly the difference, while every log
continues to read healthy.** It happened to equal the buffer depth for WHEP only because the receiver
once rebased through `now()`; when that changed to absolute sender time, WHEP's correct value became
0 and passing `targetDepth` would have traded the SDI bug for 400 ms of lip-sync error. The value is
per-session state (`mirror.cushion`), so one transport's answer can never reach another's.

---

## 📐 REFERENCE — the frame-rate ladder, and why NDI alone gets no cross-check

All four transports now declare a rate (2026-09-18). **They do not all declare it the same way, and
the differences decide how much you can trust each one.**

| transport | source | exactness | cross-checked against |
|---|---|---|---|
| **NDI** | the sender's `frame_rate_N`/`frame_rate_D` | **exact rational** — best of the four | ⚠️ **nothing** |
| **WHEP** | SPS VUI `time_scale / (2 × num_units_in_tick)` | exact | a 120-frame arrival estimator |
| **HLS** | `FRAME-RATE` in the master playlist | declared, packager-supplied | a 120-frame estimator |
| **SRT** | `av_guess_frame_rate` | a guess from the demuxer probe | nothing, but it is already a measurement |

Every one of them screens against the same plausible range, `1.0...240.0`, and publishes **nil**
rather than a garbage rate — deliberately identical refusals, so the card's behaviour does not depend
on which transport happened to connect.

⚠️ **NDI HAS NO CROSS-CHECK AND THAT IS STRUCTURAL, NOT UNFINISHED WORK.** Frames arrive through
FrameSync, which buffers, repeats and drops to keep our clock fed — `captureVideoFrame` dedups on
timestamp, so we do not even see every repeat. Inter-arrival gaps measured on this side describe the
CVDisplayLink tick and FrameSync's smoothing, **not the sender's cadence**, so an estimator here
would produce a confident number about the wrong thing and disagreements with it would be
meaningless. The sender's 100 ns `timestamp` could in principle carry one, but it would be checking
an exact rational the sender states against a derivative of that same sender's clock — not the
independent witness HLS's playlist-vs-media or WHEP's VUI-vs-arrival is.

### ⚠️ THE HLS ESTIMATOR HAS A PRECISION FLOOR THAT NO FORMULA CAN AVERAGE AWAY

This is why HLS reads the playlist at all, and why **WHEP's fit gate must never be ported to HLS**.

Capture instants are snapped to the **display tick**. Over a span of N intervals each endpoint
carries up to half a tick, so precision is `~(tick / span)` and improves **only with a longer span**.
Modelled against the real beat pattern:

```
N=120   4.0 s  ±0.415%  two modes      N=480  16.0 s  ±0.104%  two modes
N=240   8.0 s  ±0.208%  two modes      N=600  20.0 s  ±0.083%  ONE MODE
N=360  12.0 s  ±0.139%  two modes      N=900  30.0 s  ±0.056%  ONE MODE
```

~600 samples (20 s) is where a single stable mode appears. **Left at 120 deliberately** — it trades
4 s to a first answer for 20 s, and the playlist now supplies the declared rate anyway.

**The 60 Hz beat.** At 23.976 fps against a 60 Hz tick the frame interval is **2.5 ticks**, so
capture instants alternate 2 and 3 ticks (33.3 / 50.0 ms) forever. No integer multiple of any median
fits both, so `fitResidual` measures **~20% on a perfectly healthy stream, by construction**, and raw
`spread` runs 33% (23.98) to 50% (29.97). Porting WHEP's 2% gate here would refuse every healthy HLS
stream. The `[0.5×, 2.0×]` trim was investigated and exonerated on this: `nearDbl=0`, `disc=0` across
all 1018 windows.

---

## A sticky manual output-mode pick silently overrides a correct auto-detection

**Status:** PARTLY FIXED 2026-09-18 — the UI half is fixed; the persistence question is open.
**Found:** 2026-09-18, while closing the SDI video table for NDI.

`DeckLinkService.manualMode` is persisted (`manifold.decklink.manualOutputMode`) and **wins over any
source-derived mode until the operator clears it**. That is correct as designed, and it is also a
trap: a mode picked by hand during one session to work around a transport that could not state a
rate is still in force in the next session, against a source that now states one perfectly well. The
output is then wrong in a way that looks deliberate, and the picker shows it as chosen — because it
was, once, weeks ago.

**The UI half that WAS fixed:** "Follow source — unavailable" was rendered **checked and selectable**
while its own subtitle told the operator to pick something else, leaving the card on whatever
preferences last held — 2160p23.98 against a 1080 source, i.e. a black picture under a checkmark
saying everything was fine. It is now a disabled `Button` rather than a tagged `Picker` option, and
the binding reports `currentMode` so the checkmark names the mode the card is **actually** on.

⚠️ **AUTO-ADOPTING THE MODE AS A MANUAL PICK WAS CONSIDERED AND REJECTED**, and the reason generalises:
**HLS publishes its raster long before its measured rate**, so adopting on "no rate yet" would
permanently disable follow-source on HLS after every single connect. The selection is therefore
presentational and reversible — `manualMode` stays nil and the selection returns to Follow source on
its own once a rate arrives.

**Still open:** nothing expires or re-prompts a stored pick. Options are to scope it to the session,
to expire it, or to surface it more loudly when it disagrees with an available source-derived mode.
Not decided.

---

## FIXED — `applyAudioMute` silenced SDI audio for EVERY live source (confirmed by instrumentation)

**Status:** CONFIRMED by measurement, then FIXED. **Raised:** 2026-09-17, during the HLS audio work,
as UNSETTLED ("the code reads this way but a report says HLS SDI audio works"). **Settled:**
2026-09-17 — the code reading was right, the report was not. **Affects (before the fix):** NDI, WHEP,
SRT and HLS equally.

### The defect

`FrameEngine.applyAudioMute` ended with:

```swift
setCardAudioSilent(isMuted || shuttleRate != 1)
```

**`shuttleRate` is 0 for every live source.** Its only writer is `setShuttleRate`, reachable only
from play / pause / JKL — all file transport controls — and `stop()`, which a live takeover calls,
zeroes it. So `shuttleRate != 1` was true, `isCardAudioSilent()` returned true,
`DeckLinkBridge.mm`'s `RenderAudioSamples` took its `if (silent)` branch, and the card was fed
`scheduleSilence(want)`.

**No live transport had ever embedded audio on SDI.**

### ⚠️ THE EVIDENCE, AND WHY THE EXISTING COUNTERS COULD NOT PRODUCE IT

The first attempt to settle this read the stopped summary and got

```
DeckLinkAudio: stopped — scheduled=337324f underruns=0 shortReads=0 resyncs=0
```

and took it for healthy audio. **It is not evidence of audio at all.** Every schedule — real PCM and
digital silence alike — goes through the one `scheduleFrames()` call that advances the audio stream
time, so `scheduled` counts both. And the three counters beside it are all incremented *inside* the
real path, **after** the gate has returned: a run that scheduled nothing but silence reports zeroes
for all three. `337324f / 0 / 0 / 0` is exactly what total silence looks like.

Settling it therefore required new instrumentation, which is now permanent:

* a **branch trace** in `RenderAudioSamples` (`#ifdef DEBUG`) naming which of the four exits each
  callback took, and on the real one the frames the ring actually supplied — first 20 callbacks
  verbatim, then ~1/s;
* a **real-vs-silence split** of the scheduled total (`m_pcmFramesScheduled` /
  `m_silenceFramesScheduled`, deliberately NOT DEBUG-gated), so the stopped summary now reads
  `scheduled=Nf TOTAL = real=Nf + silence=Nf` and prints an explicit "NO audio reached SDI this run"
  line when `real == 0`.

**MEASURED, live HLS source, 2026-09-17:** `2025545` audio frames scheduled, **`real=0f`**, every
sampled callback on `silent=true → SILENCE · transport gate`. The reading was correct; the reports of
working HLS SDI audio were of the meters and the `audio format → …; re-establishing output` log
line, not of the wire — exactly as the video-half entry below predicted they would turn out to be.

### ⚠️ THE CONSEQUENCE THAT MADE IT URGENT: NO AUDIO ANYWHERE

This was not "SDI is silent, monitor on the Mac instead". With DeckLink output enabled and the
destination at `.sdi` (the default), `ownsSystemAudio` is true, `setDeckLinkOwnsAudio(true)` reaches
the engine, and `deckLinkOwnsAudio` enters `effectiveMute` — which **silences the desktop path on
purpose**, so the program cannot be heard from the card and the Mac at once. With the card ALSO
silent, the user got **silence on the wire and silence on the desktop simultaneously.** Enabling a
broadcast output made a live source completely inaudible, and nothing in any log said so.

### The fix

```swift
setCardAudioSilent(isMuted || (hasMedia && shuttleRate != 1))
```

`ManifoldCore/FrameEngine.swift:723`. `isMuted` stays unconditional. The rate term is now
conditioned on a FILE being the source.

**⚠️ THE FIX IS NOT UNIFYING THE TWO EXPRESSIONS, AND MUST NEVER BECOME THAT.** `shuttleRate != 1`
is a PROXY for *"the source's time is frozen"*. That proxy is sound for a paused file — the card
asks for samples at ~50 Hz at a frozen source time, so serving PCM would re-send the same window
forever (a drone), and silence is the honest answer. **That behaviour is deliberate and survives
unchanged.** The proxy is simply false for a live feed, whose ring is being filled in real time.

**`hasMedia` is the term, and it already existed** — no new flag was invented:
`ManifoldCore/FrameEngine.swift:94`, written at exactly three sites (`stop()` → false;
AVFoundation load → true; MXF/libav load → true). No live path sets it, and
`DeckRegistry.liveStreamWillActivate` (`App/WindowDeck.swift:1473`) calls `engine.stop()` on the
deck a stream takes over. The app already reads it as the file/live discriminator —
`App/ContentView.swift:430` (`engine.hasMedia || activeLiveSource != nil`).

Three candidates were rejected, and the reasons are worth keeping:

* **`liveAudioActive`** (`ManifoldCore/FrameEngine.swift:2420`, set by `beginLiveAudio`) covers
  **only WHEP and SRT**. NDI is tap-only (`App/WindowDeck.swift:1244`, *"Deliberately NOT
  `beginLiveAudio`"*) and HLS never calls it (`App/HLS/HLSAudioTap.swift:25`). Using it would have
  left HLS — the very transport measured above — still silenced, and the fix would have looked
  correct in review.
* **`currentSource`** (`ManifoldCore/FrameEngine.swift:399`) is nil for the whole DNxHR/libav path
  (that uses `libavSource`) and transiently nil across every seek
  (`ManifoldCore/FrameEngine.swift:2602`) — it would have dropped SDI audio on DNxHR entirely and
  blipped it on every scrub.
* **`liveStreamWillActivate`** sets no engine state of its own; its effect on the engine *is*
  `stop()`, i.e. `hasMedia = false`.

### ⚠️ `hasMedia` NOW CARRIES A `didSet`, AND IT IS LOAD-BEARING

`hasMedia` is an INPUT to the gate, so a change to it changes the answer and the callback-thread
mirror must be recomputed — hence `didSet { applyAudioMute() }`
(`ManifoldCore/FrameEngine.swift:95`).

Without it the fix would have been **order-dependent and half-working**: `stop()` calls
`applyAudioMute()` while `hasMedia` is still true and only clears it afterwards
(`ManifoldCore/FrameEngine.swift:973`), so a live takeover leaves the gate latched at `true`.
Connecting the stream *then* enabling DeckLink happens to recompute it (`setDeckLinkOwnsAudio` →
`applyAudioMute`); enabling DeckLink *then* connecting does not, and nothing else would ever
recompute it for the life of the stream. A tester following one order would report a fix and a
tester following the other would report the bug unchanged.

### ⚠️ DO NOT TIDY `offSpeed` TO MATCH — ITS `!= 0` CONJUNCT IS LOAD-BEARING THE OTHER WAY

`ManifoldCore/FrameEngine.swift:687`:

```swift
let offSpeed = shuttleRate != 0 && shuttleRate != 1
```

The two expressions now look gratuitously different and **they must stay that way.** `offSpeed`
governs the DESKTOP outputs, and its `!= 0` conjunct is precisely why HLS audio survives on the Mac
at `shuttleRate == 0` — which is every moment of every live HLS session. Making it match the card
term would silence HLS on the desktop. One expression protects live audio by EXCLUDING rate 0; the
other now protects it by excluding live sources from the rate test altogether. Same goal, two
outputs, two different mechanisms.

### ⚠️ THE DESTINATION TERM — WHICH THIS ENTRY PREVIOUSLY DID NOT MENTION

The transport gate is **not** the only input to the card's silence decision, and the original entry
missed this. `DeckLinkService.makeAudioConfig`'s `isSilent` block
(`App/DeckLink/DeckLinkService.swift:684-685`) is a conjunction of two independent terms:

```swift
if !self.sdiIsAudioDestination() { return true }
return self.isCardAudioSilentProvider?() ?? true
```

`sdiIsAudioDestination()` (`App/DeckLink/DeckLinkService.swift:309`) reads a lock-guarded mirror of
the `.sdi` / `.computer` destination picker (`App/DeckLink/DeckLinkService.swift:301`, default
`.sdi`). **The fix changes ONLY the second term.** The destination term is untouched and still
short-circuits first, so:

* **destination `.computer` → the card is still silenced**, for every source, file or live — via the
  same `scheduleSilence()` path, so the stream stays continuous and the card never starves, never
  re-prerolls and never drops video. Confirmed unchanged.
* destination `.sdi` + live source + unmuted → real PCM, which is the behaviour this fix restores.
* destination `.sdi` + paused FILE → silence, unchanged.

### ⚠️ NO DOUBLE-MONITORING ONCE THE CARD IS LIVE — VERIFIED PER TRANSPORT

The card going audible makes "program from the card AND the Mac at once" reachable for the first
time. It does not occur, because `deckLinkOwnsAudio` already reaches all four transports — checked
individually rather than assumed:

* **WHEP** — audible through the shared `audioRenderer` (`beginLiveAudio` wired at
  `App/WindowDeck.swift:1255-1257`), silenced by `audioRenderer.isMuted = effectiveMute`
  (`ManifoldCore/FrameEngine.swift:689`), and `effectiveMute` includes `deckLinkOwnsAudio`
  (`ManifoldCore/FrameEngine.swift:688`). ✅
* **SRT** — same path, wired at `App/WindowDeck.swift:1279-1281`
  (`App/SRT/SRTFrameRouter.swift:513`). ✅
* **HLS** — does NOT pass through `audioRenderer` (`AVPlayer` owns its own output), so it is governed
  through the `externalAudioOutput` seam instead: `ManifoldCore/FrameEngine.swift:694` hands it the
  SAME already-combined `effectiveMute`, wired at `App/WindowDeck.swift:1237-1239` →
  `HLSClient.applyAudioOutput` (`App/HLS/HLSClient.swift:391`). ✅
* **NDI** — ⚠️ **THIS BULLET CHANGED ON 2026-09-18 AND THE REASON IT PASSES CHANGED WITH IT.** It
  used to pass vacuously ("no desktop audio path at all: it feeds the tap alone, so there is nothing
  to double-monitor"). NDI now routes through `FrameEngine.LiveAudioSink` → `audioRenderer` like
  WHEP and SRT, so it passes for the SAME reason they do — `audioRenderer.isMuted = effectiveMute`,
  and `effectiveMute` includes `deckLinkOwnsAudio`. ✅

The earlier note that this condition "is not currently reachable, precisely because the card is
silent for live sources" is now spent — it became reachable with this fix, and the four checks above
are what covers it.

### Re-verifying

The branch instrumentation is deliberately kept. A correct run now shows
`silent=false → PCM · read from the ring (ringRead=Nf of want=Nf)` in the burst, and a stopped summary
with a non-zero `real=Nf`. A regression shows `real=0f` and the explicit "NO audio reached SDI this
run" line. See the instrumentation notes in `App/DeckLink/DeckLinkBridge.mm` (`logAudioBranch`).

---

## ✅ FIXED 2026-09-18 — Live SDI output carries NEUTRAL at a stale or default display mode — ALL FOUR live transports, not just HLS

**Status:** ✅ **FIXED 2026-09-18.** **Found:** 2026-09-17, while tracing why HLS SDI behaviour did
not match expectations. **Affected:** NDI, WHEP, SRT and HLS equally. **Blocked:** SDI monitoring of
any live source — which is most of the point of a broadcast output on a QC tool. **Re-confirmed
closed in the audit of 2026-09-21**, which found the status line still reading OPEN.

> ### ✅ WHAT CLOSED IT — the call that did not exist now exists
>
> - **`DeckLinkService.liveFormatChanged(_:)`** — `App/DeckLink/DeckLinkService.swift:922`. Its own
>   doc comment at `:908-914` states the diagnosis this entry reached, in the same terms: *"THIS IS
>   THE CALL THAT DID NOT EXIST, AND ITS ABSENCE WAS THE BUG… One missing call, black picture AND
>   silence."*
> - **Routed from the one place that already knows which deck owns the stream** —
>   `WindowDeck.liveDisplayFormatChanged(_:)` at `App/WindowDeck.swift:593-597`, which feeds both
>   consumers from a single published value (`hostDeck?.engine?.setLiveDisplaySize` and the card),
>   so the transports still publish once; also `App/WindowDeck.swift:1367`.
> - **The nil-rate case is handled deliberately rather than by guessing.**
>   `App/DeckLink/DeckLinkService.swift:916-921`: a raster without a rate updates *nothing* except
>   the reason string the menu shows, because setting a broadcast output to a cadence no source has
>   would be worse than a stale mode — it would look deliberate.
> - Commit `264929b`, *"feat(decklink): follow live source format for output mode selection"*.
>
> ⚠️ **The CADENCE half below closed with it**, since the mode is now a (family, rate) pair derived
> from the live source. The related audio-side failure this entry describes — the ring failing its
> anchor with *"no staged video PTS to anchor to"* — closed at the same time and for the same
> reason.
>
> **Not closed by this:** the stale-manual-pick trap, which is its own entry — *"A sticky manual
> output-mode pick silently overrides a correct auto-detection"* above, still PARTLY FIXED.

**A live source never sets the DeckLink output mode.** The card is enabled at whatever mode the
last FILE established, or at the built-in default if no file has been opened this session, and the
picture is then withheld because the raster does not match. **The wire carries a valid, lockable
signal containing black.**

### The chain, end to end

`DeckLinkService.resolveOutputMode(width:height:frameRate:)`
(`App/DeckLink/DeckLinkService.swift:429`) derives the mode from
**both** raster and rate: the family from height (`height >= 1620` → 3840×2160, else 1920×1080) and
the rate by nearest match against the eight `standardRates`
(`App/DeckLink/DeckLinkService.swift:405-414`).

Its only input is `sourceFormatChanged(width:height:frameRate:)`
(`App/DeckLink/DeckLinkService.swift:742`), and **that function has exactly one caller** —
`App/ContentView.swift:780`, inside
`.onChange(of: engine.metadata)` (`App/ContentView.swift:746`):

```swift
DeckLinkService.shared.sourceFormatChanged(width: meta.width, height: meta.height,
                                           frameRate: meta.frameRate)
```

⚠️ **`engine.metadata` IS FILE-ONLY.** Its three writers are
`ManifoldCore/FrameEngine.swift:543`
(re-inspect), `ManifoldCore/FrameEngine.swift:1435`
(AVFoundation load) and
`ManifoldCore/FrameEngine.swift:1640` (libav load). **No
live path writes it.** So the observer never fires for a stream, `sourceFormatChanged` is never
called, and `currentMode` retains the last file's value — or
`OutputMode.default2160p2398` (`App/DeckLink/DeckLinkService.swift:418`,
`App/DeckLink/DeckLinkService.swift:396` — **3840×2160 @ 23.976**) on a session where no
file was ever opened.

Note what this is *not*: `resolveOutputMode`'s own `frameRate <= 0 → standardRates[0]` fallback
(`App/DeckLink/DeckLinkService.swift:438-439`) is **never reached**, because the
function is never invoked on a live path. The mode is stale, not defaulted-from-zero.

### ⚠️ THE FAILURE IS WORSE THAN A LOCK FAILURE, BECAUSE IT LOOKS LIKE WORKING OUTPUT

The card is enabled at a **valid** mode, so a downstream monitor, scope or recorder **locks
cleanly** — to the wrong mode. What goes missing is the picture:
`App/MetalVideoRenderer.swift:2871-2872` refuses the copy
on a raster mismatch —

```swift
guard deckLinkFrameReady, deckLinkStaging.count == 2,
      let outSize = deckLinkOutputSize, outSize.w == width, outSize.h == height else { return false }
```

— and the caller fills neutral. The path says so out loud at
`App/MetalVideoRenderer.swift:2789`:

```
DeckLink D-real: source 1920x1080 != output 3840x2160 — native-res only, holding neutral (scaling is a later stage)
```

**CONFIRMED IN A REAL RUN, 2026-09-17:** mode `2160p23.98` selected for a **1080p30 HLS source**,
with exactly that line in the log. A tester reading "output enabled, 2160p23.98, locked" would call
this working.

### And the CADENCE is wrong even when the raster is right

Raster is the only thing the mismatch guard checks. Where the family happens to match — a 1080p
stream against a session whose last file was 1080p — the picture DOES reach the wire, **clocked at
the last file's rate**. A 25 fps stream emitted at 23.976 is the ordinary case, and it produces
repeated/dropped frames on the wire with no log line at all, because nothing is mismatched from the
copy guard's point of view.

⚠️ **NO FRAME RATE IS PUBLISHED FOR ANY LIVE SOURCE, BY ANY PATH.** `LiveDisplaySize` carries width
and height only, and `setLiveDisplaySize(_ size: CGSize?)`
(`ManifoldCore/FrameEngine.swift:989`)
takes a `CGSize` — **there is nowhere to put a rate.** This is the structural half of the defect and
it is not fixable inside any one transport.

### What is NOT wrong here — the 2026-08-11 size fix was picked up

Worth stating because it is the natural first suspicion and it is false. **HLS publishes its size
correctly**, per frame, exactly as the other three do:
`App/HLS/HLSClient.swift:658`
(`LiveDisplaySize.shared.publish(width:height:)`), cleared at
`App/HLS/HLSClient.swift:940`. It is routed through
`App/WindowDeck.swift:569` → `liveDisplaySizeChanged`
`App/WindowDeck.swift:583-584` → `setLiveDisplaySize`, with a mid-stream adoption
seed at `App/WindowDeck.swift:1303-1304`. `engine.displaySize` for a connected HLS
source is the decoded raster, not nil.

**One stale comment, no behaviour:** the `displaySize` doc at
`ManifoldCore/FrameEngine.swift:77`
enumerates `LIVE (NDI / WHEP / SRT)` and omits HLS — an enumeration a fourth transport joined
without the comment following, which is the same shape as the `isLive` enumeration bug recorded
above. Comment-only.

### ⚠️ INTERACTION: live SDI has TWO INDEPENDENT DEFECTS, and this one HID the other

See *"FIXED — `applyAudioMute` silenced SDI audio for EVERY live source"* above. That entry records
the AUDIO half: `setCardAudioSilent(isMuted || shuttleRate != 1)` with `shuttleRate` pinned at 0 for
every live source, which held the card's audio stream silent. **It has since been CONFIRMED by
measurement (live HLS: 2025545 frames scheduled, real=0f) and FIXED.**

**The two are independent and they compound.** This entry is the VIDEO half. Together they mean a
live source on SDI produces black pictures and silence — and **the video defect is why the audio
one went unnoticed for so long: there was never a live SDI picture to monitor against.** Nobody
sits watching a black raster wondering why it is also silent.

⚠️ **DO NOT FIX ONE AND DECLARE LIVE SDI WORKING — AND THE AUDIO HALF IS NOW THE ONE THAT IS
FIXED.** The audio gate has been corrected; **this VIDEO entry is still OPEN**, so a live source on
SDI still carries black at a stale mode. Verifying the audio fix by ear therefore still requires
working around this one (feed the card a mode the source matches, or verify from the branch trace
and `real=Nf` rather than from a monitor).

That entry's open question — *"is the code reading wrong, or has live SDI audio never worked?"* —
resolved as **"never worked"**, exactly as predicted here: the reports it contradicted were of the
meters and the `audio format → …; re-establishing output` log line rather than of the wire, which is
what someone had to fall back on with no picture to confirm.

### Scoping the fix — ⚠️ THE SHAPE IS A DECISION NOT YET MADE

Two candidate shapes. **Neither is obviously right, and they are not increments of each other.**

**(a) Publish a rate on the live path and let the mode follow the source.** A rate field on
`LiveDisplaySize`, or a sibling latch, feeding `sourceFormatChanged` the way file metadata does.

What it costs:

- ⚠️ **HLS ABR MOVES THE RASTER MID-STREAM, SO "MODE FOLLOWS SOURCE" MEANS RE-ESTABLISHING THE SDI
  OUTPUT ON EVERY RENDITION STEP.** The 2026-09-17 run stepped **416×234 → 960×540 → 1920×1080**;
  the earlier measurement in *"✅ SHIPPED — HLS as a source"* recorded a 4K ladder settling to
  1280×720 inside 25 s. Each step would stop scheduled playback and restart the card — a visible
  glitch on the wire, several times, during the first seconds of every connect. **This needs a
  latching or hysteresis policy** (settle time, highest-seen rung, or operator pin), and that
  policy is itself the design work. ✅ **DONE** — `DeckLinkService.liveModeSettleSeconds` (2.0 s),
  with the first mode of a connection applied immediately and every later change held for the settle
  window. The family test (`height >= 1620`) also absorbs most of a ladder for free: 416×234, 960×540
  and 1920×1080 all resolve to the same 1080p mode, so that measured ladder now causes **zero**
  re-establishes once the rate is known.
- ~~**Rate availability differs per transport, and one of them has nothing.**~~ ⚠️ **SUPERSEDED
  2026-09-18 — ALL FOUR NOW DECLARE A RATE.** The survey below is kept only as the starting state;
  every "not available today" in it has since been closed. Current state:
  - **SRT** — `guessedFrameRate` (`av_guess_frame_rate`, 0 when unknown), screened against
    `1.0...240.0` and published or refused. Unchanged since this was written.
  - **NDI** — ✅ **plumbed 2026-09-18.** `NDIVideoFrame` now exposes `frameRateN`/`frameRateD` as the
    sender's exact rational, divided and plausibility-screened in `NDIService.declaredFrameRate`
    against the *same* `1.0...240.0` range SRT uses. **The best rate signal of the four** — an exact
    rational the sender states outright — and the only one with no independent measurement to
    cross-check it against (see the ladder entry below).
  - **WHEP** — ✅ **parsed 2026-09-18.** H.264 SPS VUI `time_scale / (2 × num_units_in_tick)`, exact,
    latched once per connection, with a 120-frame estimator running underneath as a cross-check.
  - **HLS** — ✅ **read 2026-09-18.** `FRAME-RATE` from the master playlist, cross-checked against the
    estimator.
  - **HLS** — no declared rate either; `AVPlayerItemVideoOutput` vends buffers, not a cadence.
    It would have to be inferred from presentation timestamps.

**(b) An explicit operator-chosen output mode, plus the scaling stage the code already defers.**
The mismatch guard's own log names the missing piece — *"scaling is a later stage"*
(`App/MetalVideoRenderer.swift:2789`) — and
`resolveOutputMode`'s comment says the same
(`App/DeckLink/DeckLinkService.swift:423-425`).

What it costs: it **depends on work that is currently parked**. But it is the colourist-facing
answer — a reference output is normally pinned to the room's mode, not re-negotiated by the source
— and it makes ABR raster hopping a **non-issue**, because the output mode stops tracking the
source at all.

⚠️ **STATE PLAINLY: (a) ALONE DOES NOT SOLVE HLS, AND (b) DEPENDS ON PARKED WORK.** (a) leaves HLS
re-establishing the card repeatedly through every ABR ramp and still needs a rate HLS does not
declare; (b) cannot ship until scaling does. **So the decision is which of the two the feature
actually needs, and it should be made before any code is written.** Building (a) because it is the
smaller diff would spend the effort on the transport that needs it least (SRT, which already has
its rate) and leave the worst case (HLS) worse.

### Not verified

**Whether `startOutputOnQueue` has some other guard that refuses to start when no source matches,
rather than enabling the card and emitting neutral.** The per-frame copy
(`App/MetalVideoRenderer.swift:2871-2872`) and the mode
resolution (`App/DeckLink/DeckLinkService.swift:429`) were traced;
the full output-start sequence was not. If such a guard exists the symptom would be "output refuses
to start on a live source" rather than "output starts and carries black" — a different report, same
root cause.

---

## ⚠️ #NDI-AUDIO — FrameSync was asked for the queue depth, so it MANUFACTURED audio: 8.1M samples delivered against 1.44M sent, and the meters read levels off the difference

**Status:** **BOTH FIXES ARE IN THE CODE. ONE OF THEM HAS NEVER BEEN RE-MEASURED.** Cause confirmed
by measurement and by the SDK header. First fix landed 2026-09-18 and **was** measured — it made
the audio authentic but left an 8.3% rate deficit; the second fix landed the same day (see "The
second defect" below) and **has not been measured.** **Found:** 2026-09-18, while diagnosing why the
DeckLink audio callback underran on ~99% of callbacks. **Affects:** NDI only — SRT, HLS and WHEP
are measured working on the wire and share none of this code. **Re-audited 2026-09-21.**

> ### ⚠️ THE DISTINCTION THIS ENTRY NEEDS, MADE EXPLICIT — 2026-09-21
>
> **What is open here is a MEASUREMENT, not a code state.** Those are different things and this
> entry was readable as either. Source audit:
>
> **Fix 1 — stop asking FrameSync to manufacture audio. PRESENT.**
> `captureAudioFrameForMaxSamples:` is gone. The API is now
> `-[NDIBridge captureAudioFrameForInterval:]` (`App/NDI/NDIBridge.h:241`), sized from elapsed real
> time rather than from the queue depth. The queue depth survives as a **diagnostic only**, and the
> header says so at `App/NDI/NDIBridge.h:94-95`: *"deliberately not used to size anything (it was,
> and that was the defect)"*.
>
> **Fix 2 — the 8.3% rate deficit. PRESENT.**
> `_audioLastPullTime` and `_audioSampleCarry` (`App/NDI/NDIBridge.mm:287-289`) carry the
> sub-sample remainder across pulls *"so that truncation cannot accumulate into a rate error"*.
>
> **And the authenticity check that would catch a regression is built in**, which is the part worth
> keeping: `App/NDI/NDIBridge.h:86-92` documents the sender timestamp as the one quantity FrameSync
> cannot invent — across consecutive pulls it must advance by `frameCount / sampleRate`, and the
> `[NDI-AUDIO]` trace prints exactly that ratio.
>
> ### ❌ So the only thing outstanding is: RUN IT.
>
> A 30 s NDI run, reading the `[NDI-AUDIO]` push trace, checking that `cum` sits at **48000 Hz**
> rather than the ~270000 Hz that started this, and that sent-vs-delivered sample counts agree.
> That is the whole of it.
>
> ⚠️ **AND DO NOT ACCEPT `real=Nf` / `underruns=0` AS THE ANSWER.** The entry's own closing
> section already makes this point and it applies directly here: those are transaction counters,
> they prove the ring was read and the cursor kept up, and they say **nothing about what was in
> it**. This defect's entire character was that every counter read healthy while the audio was
> synthesised. **What settled it the first time was writing the bytes to a `.wav` and listening.**
> Settle it the same way.

**The SDI underrun was the symptom that got this looked at. It is not the serious half.** The
serious half is that **the meters and the shared `AudioTapBuffer` have been fed synthesised audio
for the entire life of the NDI audio path**, and a reference tool reporting levels off manufactured
samples is a correctness failure of a different order than "SDI is quiet". Nothing in any log said
so. The `AudioTap[NDI]` line reported a plausible sample rate, plausible channel count and a
plausible held-frame count throughout, because every number in it is computed from our own sample
count against our own clock — and both were consistent with the lie.

### The measurement

NobeOmniScope 1080p24, 30 s run, via the `[NDI-AUDIO]` push trace:

| quantity | measured | expected |
|---|---|---|
| samples sent by the source | 1.44M | — |
| samples delivered into the tap | **8.1M** | 1.44M |
| effective sample rate (`cum`) | **~270000 Hz** | 48000 Hz |
| `n` per pull | sawtooth 540 → 4800, reset, repeat | flat 480 |
| `dev` (ring PTS axis vs sample axis) | monotonically **negative**, [−110 ms .. 0] | ~0 |
| `AudioTapBuffer` re-anchors | **~57/s** (129 in the first 2.2 s) | ~0 |
| DeckLink real frames scheduled | 13165 of 1168810 (**1.1%**) | ~100% |

**At least 82% of every sample that ever entered the NDI audio path was synthesised by FrameSync's
resampler rather than sent by the source.** That is arithmetic from the two totals, not inference,
and it holds regardless of whether the synthesised material turns out to be time-stretched or
literally re-served.

### The cause — an inverted reading of `no_samples`

`App/NDI/NDIBridge.mm` sized every pull as `min(4800, framesync_audio_queue_depth(...))` and passed
that as `no_samples` to `NDIlib_framesync_capture_audio`, on the premise that the parameter is a
**ceiling**. It is not. `Processing.NDI.FrameSync.h`, verbatim:

> This function will pull audio samples from the frame-sync queue. This function will **always
> return data immediately, inserting silence if no current audio data is present**. You should call
> this **at the rate that you want audio** and it will **automatically adapt the incoming audio
> signal to match the rate at which you are calling by using dynamic audio sampling**.

`no_samples` is therefore an **instruction about the consumer's clock**, and FrameSync satisfies it
by manufacturing whatever it does not hold. Asking for a queue depth of up to 4800 every 10 ms
announced a consumer running at up to **480 kHz**. FrameSync obliged. The queue was never drained by
the amount requested — it is drained by FrameSync's own time-base correction against our *call
rate* — which is why the depth sawtoothed up to the request ceiling instead of sitting near zero.

The header also warns against this exact use of the depth function, in its own words:

> you should treat the results of this function with some care because **in reality the frame-sync
> API is meant to dynamically resample audio to match the rate that you are calling it**. If you
> have an inaccurate clock then this function can be useful.

### ⚠️ THE OLD COMMENT ASSERTED THE EXACT OPPOSITE OF THE HEADER, AND THAT IS WHY IT SURVIVED

`NDIBridge.mm`'s pull comment, as it stood before commit `03899dd` (the line numbers it occupied
have since moved, and the comment itself is gone), read:

> Requesting no more than what's buffered means FrameSync never pads silence; the remainder stays
> queued (and FrameSync bounds/ages its own queue), and the >nominal cap gives headroom to catch up.

Every clause is false, and it is a *confident, mechanism-shaped* falsehood — the kind that gets
read, believed, and skipped over on the next visit. It pads whenever the request exceeds what it
holds; there is no "remainder stays queued" because the request is not a ceiling; the cap does not
buy headroom, it sets the upper bound on how much audio gets invented. **It was also load-bearing
in the wrong direction**: it explained away the very symptom that would have exposed the bug.

The comment's second paragraph was a real fix to a real earlier bug — draining the depth on the
*CVDisplayLink tick* coupled pull size to tick interval and collapsed fps 10→7→…→1 — and moving the
pull to a dedicated thread genuinely fixed that. The mistake was keeping the depth-based sizing
after the move, and writing a rationale for it.

### The SDK's own examples — none of them do this

`/Library/NDI SDK for Apple/examples` contains five framesync audio examples. **`grep` for
`audio_queue_depth` across all of them returns zero hits.** Every one computes `no_samples` from the
consumer's own cadence:

| example | `no_samples` |
|---|---|
| `NDIlib_Recv_FrameSync.cpp:71` | fixed `1600`, with `sleep_for(33ms)` → exactly 48000/s |
| `NDIlib_Recv_FrameSync_Audio.cpp:42` | the CoreAudio device callback's `frameCount` |
| `NDIlib_Recv_FrameSync_resend.cpp:86` | computed from the video frame's duration |
| `NDIlib_Recv_FrameSync_timing.cpp:133` | computed from the video frame's duration |
| `NDIlib_FreeAudio.cpp:251` | the device callback's `frameCount` |

`NDIlib_Recv_FrameSync_Audio.cpp:48-50` then reads exactly `frameCount` samples out of the returned
frame **without checking `no_samples`** — the SDK's own example relies on getting back precisely
what it asked for. That is the "exactly this many" contract confirmed by usage, not just prose.

### What landed, 2026-09-18

Three files, all NDI-only:

- **`NDIBridge.h` / `NDIBridge.mm`** — `captureAudioFrameForMaxSamples:` → **`captureAudioFrameForInterval:`**.
  The caller passes its **poll interval**; the bridge asks for `round(seconds * sampleRate)` — 480
  at 48 kHz for the 10 ms pump. The signature changed deliberately rather than the body alone: the
  old name invited a ceiling and the new one cannot be passed one.
- **The format query is no longer per-pull.** The zero-parameter `capture_audio` that reads the
  native rate/channels ran on every iteration, making this a *second* `capture_audio` call at 200/s
  against a library whose whole job is inferring the consumer's clock from its call rate. It is now
  cached and re-queried once a second. ⚠️ **It cannot simply run once:** we pull at the source's
  native rate/channels, and the header is explicit that any requested format is converted to — so a
  source moving 2ch → 8ch would be silently **downmixed** to the cached count with no error and no
  short read. One second bounds that; never re-querying would not.
- **`NDIService.swift`** — the pump passes `pollInterval`; the `[NDI-AUDIO]` trace gained two
  columns (below). Its pacing comment, which restated the same inverted premise, was replaced.

`framesync_audio_queue_depth` is **kept, as a diagnostic only**, carried out on
`NDIAudioFrame.queueDepthAtPull` and used to size nothing. It earns its place as the only view of
the SDK side of the seam: low and flat means FrameSync is consuming what it hands us, and a sawtooth
climbing toward the request is this defect recurring.

### ⚠️ HOW TO TELL IF IT IS ACTUALLY FIXED — `sndR`, AND NOTHING ELSE

**`cum` reading 48000 does not prove the audio is real.** It is our sample count over our clock, and
it read a perfect 48000 through the entire broken period whenever the ring had just re-anchored.
Any fix verified on `cum` alone is unverified.

The trace now prints **`sndR` = `frameCount` ÷ Δ(NDI sender submit timestamp)**. The sender's 100 ns
timestamp comes from outside this process and FrameSync cannot invent it:

- `sndR ≈ 48000` → sender time advances by `n/48000` per pull. **The samples are authentic.**
- `sndR ≈ 48000/k` → the audio is stretched k×. The old defect would have read ~8500.
- `sndR = n/a` → the sender supplies no timestamp (`NDIlib_recv_timestamp_undefined`). Legal, and it
  leaves the question **unanswerable** — record that, do not record it as a pass.

Also expect: `n` flat at 480, `depth` low and flat, `dev` near zero with `re-anchors` at ~0/s.

### MEASURED 2026-09-18 — the stretching is gone, and it exposed a second defect underneath

NobeOmniScope 1080p24, 48 s:

| quantity | before | after the first fix | verdict |
|---|---|---|---|
| `n` per pull | sawtooth 540 → 4800 | **480 flat** | fixed |
| per-push `sndR` | (not instrumented) | **48000 Hz at `sndΔ`=10.00 ms** | **the samples are AUTHENTIC** |
| `cum` | ~270000 Hz | **44030 Hz** | still wrong, and by a new mechanism |
| `depth` | sawtooth to the ceiling | sawtooth 250..2280f | still wrong |
| `dev` | negative to −110 ms | **positive**, climbing to +50 ms | sign flipped: now UNDER-consuming |
| re-anchors | ~57/s | ~2/s | better, not fixed |

**`sndR = 48000` is the result that matters: the manufactured audio is gone.** Everything below is a
rate error on real samples, which is a far smaller defect than the one this entry opens with.

### The second defect — a nominal interval that was never the real period

`44030 = 480 / 0.0109`, exactly. `NDIService.runAudioPump` sleeps `pollInterval` at the **bottom** of
its loop, so the true period is `pollInterval + pull + convert` — measured ~10.9 ms against a
nominal 10 ms. Requesting one NOMINAL interval's worth while calling 91.7 times a second declares a
44030 Hz consumer and leaves 8.3% of the stream unconsumed. The queue grows at ~4 kHz (the `depth`
sawtooth) and the tap's PTS axis runs ahead of its sample axis until it re-anchors (the climbing
positive `dev`).

⚠️ **AND THE FIRST FIX'S OWN COMMENT FORBADE THE CORRECT ANSWER.** `NDIBridge.h` carried: *"DO NOT
'IMPROVE' THIS BY DERIVING THE COUNT FROM MEASURED ELAPSED TIME … a second controller measuring the
same thing would fight [the TBC]."* Wrong, and wrong the same way the comment this entry opens with
was wrong — **a confident mechanism-shaped claim resting on an unstated assumption**, here that the
pump's period equalled `pollInterval`. It never did. Measuring elapsed time does not fight the TBC,
it feeds it: `elapsed × rate` makes our draw exactly `rate` per second by our own clock, which is
the quantity the TBC reconciles against the sender's. The SDK examples use fixed counts because
theirs are driven by an audio device callback or a video frame duration — cadences that ARE exact.
A sleeping thread's is not. **Two comments in one file have now asserted the opposite of the truth
about this API; treat prose here as a claim to check, not a finding.**

What landed: `captureAudioFrameForInterval:` now sizes from `CACurrentMediaTime()` elapsed since the
previous pull, carrying the sub-sample remainder so truncation cannot accumulate (at 10.9 ms each
pull owes 523.2 samples and dropping the .2 would leak ~0.04%). A 250 ms clamp bounds a stall —
beyond that the samples are gone from the queue and asking would only make FrameSync invent them.
The pump additionally sleeps `pollInterval − workElapsed`, which is tidiness only: the sleep cannot
go negative, so any hiccup past the interval would reintroduce the deficit. **The elapsed-derived
count is the robust half.**

### Also fixed: the trace's aggregate line was lying, and the per-push lines were not

The 1 Hz aggregate printed `sndR=0.0Hz` while every per-push line read a correct 48000 Hz. **The
format string was fine** — the mean was poisoned. A pull whose `timestamp` comes back **zero** (the
struct is `memset`, so a frame FrameSync does not stamp reads 0, not the `NDIlib_recv_timestamp_undefined`
sentinel) makes the NEXT difference the whole Unix epoch, ~1.7e9 seconds. One of those swamps a
window and drives the mean to ~0. The guard now requires a stamp to be strictly positive AND not the
sentinel AND the gap to be under one second, and the line reports how many pulls it averaged over
when any were dropped.

**The general lesson is the one worth keeping: a single bad sample in a mean is invisible until the
mean is the only number anyone reads.** The per-push lines were correct the whole time and nobody
reads 100 lines a second.

### Not verified

- ~~**Re-measurement after the SECOND fix.**~~ ✅ **DONE 2026-09-18, and it passes on every
  criterion this list set in advance.** Measured over 72 s: **`cum` = 48006.6 Hz**,
  **`sndR` = 48015.5 Hz** from the sender's own timestamps, **`dev` +0.01..+1.02 ms**, **zero ring
  re-anchors**. A later run during the desktop-audio work gave `dev` +0.00..+0.00 ms and
  **`real` = 1068271f with `underruns` = 0** in the DeckLink summary.
  ⚠️ **BUT READ THE `real=Nf` CRITERION AGAIN — IT DOES NOT MEAN WHAT THIS LIST ASSUMED.** A large
  `real` and zero underruns prove the ring was READ and the cursor kept up. They say **nothing about
  what was in it**; they are transaction counters, not content checks. "These samples play cleanly on
  SDI" rested on exactly this number for most of 2026-09-18 and was never verified by ear. What
  finally settled it was writing the bytes to a `.wav` and listening — see the four-instrument table
  in the desktop-audio entry.
- **Whether the synthesised audio was time-stretched or literally duplicated.** The header's silence
  path ("if no current audio data is present") does not apply — the queue was deep — so dynamic
  resampling is the strong reading, but the two were never distinguished. `sndR` on a *pre-fix*
  build would settle it, if it is ever worth knowing.
- **Whether the SDI underrun is fully explained by this.** It is necessary — a ring re-anchoring
  57×/s cannot serve a continuous cursor — but a second, independent finding from the same
  investigation is still open: the DeckLink cursor `ideal = stagedPts + (audioDepth − videoDepth)`
  appears to sit *ahead* of the ring head by a margin of ~10–30 ms that depends on an unmeasured
  render latency, with `audioDepth` 180 ms against a `videoDepth` of 125–167 ms from a 4-frame pool.
  That may resolve itself once the ring stops being wiped, or it may not. **Re-measure before
  touching the DeckLink side.**


---

## Preferences are declared in twelve files, and eight keys are declared more than once

**Status:** OPEN — **latent, not live. Nothing is broken today and the shape is how it breaks.**
**Found:** 2026-09-21, during the board audit, while confirming whether "the unified preferences
system" had shipped. **Blocks:** nothing. **Costs:** the ability to answer "what are this app's
preferences, and what are their defaults" from one place.

`App/Preferences.swift` looks like the answer to that question — a single `Preferences:
ObservableObject` with `@AppStorage` properties and a `SettingsView`. **It is about half of it.**

**Measured 2026-09-21**, counting distinct `@AppStorage` keys across `App/`:

| | count |
|---|---|
| distinct keys in the app | **63** |
| declared in `Preferences.swift` | 33 |
| **declared only OUTSIDE `Preferences.swift`** | **30** |
| `@AppStorage` declarations outside `Preferences.swift` | 118, across 12 files |

Where the outside declarations live: `FramingGuide.swift` 31 · `WaveformScope.swift` 17 ·
`ContentView.swift` 14 · `VectorscopeScope.swift` 13 · `LicenseManager.swift` 9 · `CIEScope.swift` 9 ·
`ParadeScope.swift` 7 · `WindowChrome.swift` 6 · `AudioMeterScope.swift` 6 · `WindowDeck.swift` 2 ·
`DeckLink/DeckLinkService.swift` 2 · `Captions/CaptionOverlay.swift` 2.

### ⚠️ SOME OF THIS SPLIT IS DELIBERATE AND MUST NOT BE "TIDIED" INTO `Preferences.swift`

Read this before consolidating anything — three of the twelve files are outside on purpose, and
each has its reasoning written at the site:

- **`WindowChrome.swift` (6 keys, including `showTray`) — PER-WINDOW BY DESIGN.** These were
  `@AppStorage` on `ContentView` and that was the bug: opening the scopes tray in one window opened
  it in every window. The class exists to finish that split, with last-writer-wins seeding
  documented in its header. **Centralising these would re-create the defect it was written to
  remove.** The keys are deliberately unchanged from the `@AppStorage` era so an existing install's
  arrangement survives upgrade.
- **`DeckLinkService.swift` (2 keys) — `defaults write` affordances**, `manifold.decklink.manualOutputMode`
  and the audio trim key. They are operator escape hatches, documented as such, and not Settings
  rows.
- **`LicenseManager.swift` (5 `license.*` keys) — licence state, not user preference.** It is
  stored the same way and it is not the same kind of thing. Worth leaving where it is; worth
  knowing it is not in the preferences inventory.

### ❌ And some of it looks accidental

The **scope instrument settings** are the bulk of it: waveform and parade guide lines, vectorscope
targets, graticule and box amplitude, CIE gamut toggles, meter markers, and the shared
`manifold.scope.verticalScale`. Plus `FramingGuide.swift`'s 31 declarations and the caption position
preset. Nothing at those sites argues for being outside; they read as having been written where they
were needed.

### ⚠️ THE ACTUAL HAZARD: EIGHT KEYS ARE DECLARED IN MORE THAN ONE PLACE

This is the part worth acting on, and it is **not** a tidiness complaint. `@AppStorage` carries its
own default at each declaration site, so N declarations of one key are N independent statements of
what that preference defaults to — and nothing checks that they agree.

| key | declarations |
|---|---|
| `scopeScale` | **4** — `ParadeScope.swift:178`, `Preferences.swift:94`, `Preferences.swift:1308`, `WaveformScope.swift:734` |
| `guideMode` | **3** — `FramingGuide.swift:38`, `FramingGuide.swift:150`, `Preferences.swift:99` |
| `manifold.scope.verticalScale` | **3** — `ParadeScope.swift:180`, `WaveformScope.swift:736`, `WaveformScope.swift:1261` |
| `autoplayOnLoad` | 2 — `Preferences.swift:70`, `Preferences.swift:1305` |
| `globalScopeIntensity` | 2 — `Preferences.swift:90`, `Preferences.swift:1307` |
| `manifold.caption.positionPreset` | 2 — `ContentView.swift:408`, `Captions/CaptionOverlay.swift:34` |
| `manifold.vectorscope.boxAmplitude` | 2 — `VectorscopeScope.swift:348`, `ContentView.swift:391` |
| `manifold.vectorscope.graticule` | 2 — `VectorscopeScope.swift:344`, `ContentView.swift:388` |

✅ **CHECKED 2026-09-21: ALL EIGHT AGREE TODAY.** Every declaration of every one of these keys
states the same default and the same type. **There is no defect in the build.** That is why this is
recorded as latent, and it is the reason to write it down now rather than after it breaks.

**How it breaks, concretely:** someone changes `scopeScale`'s default from `.bit10` to `.bit12` in
`Preferences.swift`, because that is where preferences obviously live. `ParadeScope.swift:178` and
`WaveformScope.swift:734` still say `.bit10`. The key is unset on a fresh install, so **whichever
view constructs first wins**, and the parade and the waveform can disagree about the scale they are
drawing at — on a QC tool, where the whole point is that the instruments agree. Nothing logs it and
both views look internally consistent.

⚠️ **THAT FAILURE SHAPE IS ALREADY RECORDED TWICE IN THIS FILE**, which is why it is worth
pre-empting a third time: *"an unrecognised CICP primaries code … the fallback is written twice"*
above makes exactly this argument about two colour-table copies (*"a file with an unusual transfer
would render one way while playing and another way while scrubbing, and nothing would say so"*),
and `VectorscopeScopeModel.plotPoint` was extracted at its second caller for the same reason. **The
established pattern in this codebase is to extract at the second copy, and these keys are at four.**

### What would close it

**Not a rewrite.** Two cheap steps, in order:

1. **Single-source the DEFAULTS.** `Preferences.swift` already does this internally for the
   broadcast-safe values (`Preferences.defaultBroadcastActionPct` and friends, `:120-137`) — the
   pattern exists and is documented as existing so *"the `@AppStorage` declarations at every site"*
   cannot drift. Extend it to the eight keys above. This removes the hazard without moving a single
   preference or changing any behaviour.
2. **Then decide, separately, whether the scope-instrument keys belong in `Preferences.swift`** — a
   presentation question with no correctness content, and not urgent.

**Do not do step 2 first**, and do not touch the three deliberate exclusions above while doing
either.

---

## ❌ DROPPED: borderless window with square corners — considered, not built

**Status:** **DROPPED — decided 2026-09-21. Not awaiting a fix; see the reopen condition below.**
**Raised:** during the window-chrome work. **Blocks:** nothing.

macOS rounds the corners of a standard titled window **unconditionally**. There is no API to opt
out: the rounding is applied by the window server to the frame, not drawn by us, so no amount of
work inside the content view reaches it. **A picture displayed at native resolution therefore has
its four corner pixels masked**, and on a QC tool that is a real observation rather than a cosmetic
one — the app's whole claim is that what is on screen is what is in the file.

**The only way to get true square corners is a `.borderless` `styleMask`.** That is not a flag, it
is a different kind of window, and it takes the rest of the titled window's behaviour with it:

- **The traffic lights go.** They would have to be re-added by hand, and then drawn into both
  control modes — the floating HUD and the docked bar — because the window has two arrangements.
- **`canBecomeKey` and `canBecomeMain` must be overridden.** A borderless window returns `false`
  from both by default, so without the overrides the window cannot take focus or become main at
  all.
- **⌘W and ⌘M need menu backstops.** Close and minimise are behaviours of the title bar's buttons
  as much as of the menu; losing the frame loses the standard handling and each has to be
  re-established and then kept working.

**Against that cost: nobody has ever mentioned it.** Three to four months of testing, by people who
look at pictures professionally and are paid to notice exactly this class of thing, produced **not
one report** about corner pixels being masked. That is the strongest evidence available and it
points one way.

**So the trade is: a meaningful amount of window-management machinery, permanently, against a defect
that the target audience has demonstrably not noticed over months of real use.** Declined.

⚠️ **THE REASONING IS RECORDED BECAUSE THE CONCLUSION IS NOT OBVIOUS FROM THE OUTSIDE.** "Just
make the window borderless" reads like a one-line change, and it is the kind of thing that gets
proposed, scoped, and half-built before the three overrides above surface. Anyone reaching for it
should reach this entry first.

**What would reopen it:**

- **A user reports it.** One report changes the evidence this was decided on, which was the absence
  of any.
- **A use case appears where the corner pixels are load-bearing** — a fixture, a test pattern, or a
  QC procedure that puts information in the extreme corners of the frame. That would move this from
  a cosmetic question to a correctness one, and the cost calculation changes with it.

**Not related to:** the docked-vs-overlay control mode (`WindowChrome.controlMode`,
`App/WindowChrome.swift:151-158`), which shipped and is a different thing entirely. The audit of
2026-09-21 could not tell from source whether "borderless" named that shipped work or something
else; this entry exists so the next reader does not have to ask.
