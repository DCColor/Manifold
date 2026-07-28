# MacBook Air — colour management test

## The question this answers

On the Studio, a γ2.4-tagged `CAMetalLayer` renders **exact 2.4 above code 0.15** and
**identical to today's behaviour below code 0.06**. That floor sits exactly where
Reference mode's value lives — the shadows — so if it's real, option (b) (tag the
layer and let ColorSync convert) is dead and Reference has to be done in-shader.

But the Studio's display profile is **LG TV SSCR2, a pure power law at γ1.960999** —
almost exactly what macOS applies by default. Three explanations fit the data and
they have very different consequences:

| | Consequence |
|---|---|
| ColorSync has a genuine shadow floor | Option (b) is dead everywhere |
| The near-match of source and destination causes it | (b) may work fine on normal displays |
| 8-bit capture is hiding a real difference | (b) works, we just can't see it |

The Air has a **P3 factory profile** — nothing like γ1.961 — so it separates the
first two cleanly.

---

## Before you leave the Studio

**The harness lives in the session scratchpad and will not survive.** Get it into
the repo first, or you'll arrive with no way to run the test:

- `make_wedge.py` — generates the 48-patch step wedge
- `sweep.sh` — drives the destination cycle and captures
- `analyze2.py` — decodes the captures and fits the hypotheses
- the wedge `.mov` itself (or just regenerate it there)

Ask Claude Code to move them to `scripts/` or `docs/color-fixtures/` and commit.
`docs/color-fixtures/parse_icc.py` is already committed and you'll need it.

**Also verify the `⌃⌥D` shortcut.** It was the SRT debug connect, and the
Experiment 3 scaffold also bound it to destination cycling. If they collided, one of
them silently won. Check which, and check that `/tmp/manifold_debug_cs` still drives
the cycle from a shell — that's what lets `sweep.sh` run without keystroke injection.

**Take the DMG**, not a source checkout. `Manifold-0.5.0-3-Profile.dmg` is a Profile
build, so `DEBUG` is defined and the scaffold is live.

---

## Procedure

### 1. Record what the Air's display actually is

Before anything else, dump its profile:

```bash
python3 docs/color-fixtures/parse_icc.py <path to the Air's display profile>
```

Find the profile via System Settings ▸ Displays ▸ Colour Profile, or in
`/Library/ColorSync/Profiles/Displays/` and `~/Library/ColorSync/Profiles/`.

**This is the most important single number in the test.** Record its TRC — whether
it's a `curv` power law or a `para` piecewise curve, and what gamma. If it's near
2.2 rather than 1.961, that's the variable the Studio couldn't change.

### 2. Run the sweep

Same as the Studio: load the wedge, cycle through the three destinations (source
CoreMedia709, `kCGColorSpaceITUR_709`, synthesised γ2.4), capture each with
`screencapture -l <windowID>`, decode raw samples from the PNG data provider —
**not** through CoreGraphics, which would re-run the conversion under test and
manufacture the effect.

Window must be exactly 1920×1080 so capture is 1:1 with the fixture.

### 3. Read the result

The number that matters: **at what code value does the γ2.4 destination stop
tracking 2.4 and collapse to today's behaviour?**

- **Floor at ~0.06 again** → ColorSync has a genuine shadow floor. Option (b) is
  dead, Reference needs the in-shader path, and that's a much bigger arc.
- **Floor moves, or doesn't appear** → the Studio's γ1.961 profile was causing it.
  Option (b) is viable, and Reference mode is close to a config change.
- **Different in some third way** → interesting, and worth capturing before
  theorising.

---

## While you're there — the eyes test

This one needs no scripts and is arguably as valuable.

**Open the same properly-tagged 709 file in Manifold and in QuickTime Player, side
by side.** On the Studio they matched, because Manifold delegates to ColorSync just
like QuickTime does. That should hold here too — but the *picture* should look
noticeably lifted compared to what you're used to seeing on the WOLED, because the
Air's profile isn't doing the correction yours accidentally does.

That's the view your clients actually get. Worth seeing with your own eyes at least
once — it's the whole argument for the feature.

If you have VLC or mpv on the Air, add it as a third. Those bypass ColorSync, so
they show the non-Mac render. Whichever pair matches tells you where Manifold sits.

---

## Free tests while the Air is in your hands

The Air is a clean machine, which makes it the only place several things can be
checked:

- **NDI runtime absent.** If it isn't installed, launch and open the streaming menu.
  It should say something honest, not show an empty source list. This has never been
  tested.
- **No DeckLink attached.** The output button should degrade gracefully.
- **Local network permission prompt.** First NDI discovery should show the string
  we added — "Manifold uses your local network to find NDI video sources to play."
- **Keychain on a fresh signature.** Items get created by the signed build from the
  start, so there should be *no* prompts at all — unlike the Studio, where the
  existing items were made by a differently-signed local build.
- **Gatekeeper.** Downloading the DMG rather than copying it means it carries the
  quarantine attribute — the real test of the stapled ticket.
- **General performance.** An M-series Air is not an M4 Max. Watch `RENDER-PERF`
  `tickMs` and whether scopes cost anything visible.

Export diagnostics once from the Air regardless. It's the first machine that isn't
yours, and the machine section will show a completely different display profile —
useful to see the report working on hardware it wasn't written against.

---

## Record before theorising

Whatever the numbers say, write them down before deciding what they mean. The
Studio result took a full session to interpret and two wrong hypotheses along the
way — including one where decoding the capture through CoreGraphics manufactured the
very effect it was meant to detect.

If the result contradicts the Studio's, that's a finding, not an error. Update
`docs/COLOR_MANAGEMENT_FINDINGS.md` with both.
