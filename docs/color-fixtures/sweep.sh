#!/bin/bash
#
# EXPERIMENT 3 sweep — for each candidate layer destination: launch Manifold on the wedge,
# capture the COMPOSITED WINDOW (not the offscreen export), extract raw samples, quit.
#
# Usage:
#   docs/color-fixtures/sweep.sh [output-dir]            # default: ./sweep-out
#   MANIFOLD_APP=/path/to/Manifold.app docs/color-fixtures/sweep.sh
#
# ── HOW THE DESTINATION IS SELECTED, AND WHY IT IS NOT A KEYSTROKE ────────────────────────
#
# MetalVideoRenderer reads /tmp/manifold_debug_cs ONCE, when the renderer is constructed, and
# seeds `debugDestination` from it. So the file is written BEFORE launch and the app is
# relaunched for each destination — which is exactly why this runs with no keystroke injection
# and no Accessibility permission.
#
# ⚠️ THAT ALSO MEANS THE ⌃⌥D SHORTCUT IS IRRELEVANT TO THIS SCRIPT. There are two ⌃⌥D bindings
# in ContentView — destination cycling and the SRT debug connect — and which one wins is
# undefined. The file path is unaffected by that collision, which is precisely why this harness
# uses it. See docs/AIR-COLOUR-TEST.md.
#
# ── WHAT CHANGED FROM THE STUDIO VERSION ──────────────────────────────────────────────────
#
# The original hardcoded a DerivedData path containing a PER-MACHINE HASH
# (…/Manifold-crcjphimfkzmwmbuwuwwtavooiuy/…). That path exists on no other Mac, so the script
# would have failed on the Air at the first line that used it. It now discovers the app,
# preferring an installed /Applications/Manifold.app — which is what the DMG gives you, and the
# DMG is what AIR-COLOUR-TEST.md says to take.
#
# It also runs the extract step, which was a separate manual command on the Studio, and checks
# the build configuration and the window size before trusting a capture.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$PWD/sweep-out}"
WEDGE="${HERE}/wedge.mov"

# ── Locate the app ────────────────────────────────────────────────────────────────────────
find_app() {
    [ -n "${MANIFOLD_APP:-}" ] && { echo "$MANIFOLD_APP"; return; }
    for candidate in \
        "/Applications/Manifold.app" \
        "$HOME/Applications/Manifold.app" \
        "$HOME/Library/Developer/Xcode/DerivedData"/Manifold-*/Build/Products/Profile/Manifold.app \
        "$HOME/Library/Developer/Xcode/DerivedData"/Manifold-*/Build/Products/Debug/Manifold.app
    do
        [ -d "$candidate" ] && { echo "$candidate"; return; }
    done
}
APP="$(find_app)"
[ -n "$APP" ] && [ -d "$APP" ] || {
    echo "Manifold.app not found."
    echo "Install the Profile DMG to /Applications, or set MANIFOLD_APP=/path/to/Manifold.app"
    exit 1
}
BIN="$APP/Contents/MacOS/Manifold"
[ -x "$BIN" ] || { echo "no executable at $BIN"; exit 1; }

[ -f "$WEDGE" ] || {
    echo "wedge.mov missing at ${WEDGE}"
    echo "Regenerate it with:  python3 ${HERE}/make_wedge.py ${WEDGE}    (needs ffmpeg)"
    exit 1
}

mkdir -p "$OUT_DIR"
cd "$OUT_DIR" || exit 1

echo "app:    $APP"
echo "wedge:  $WEDGE"
echo "output: $OUT_DIR"

# ⚠️ THE BUILD MUST BE Debug OR Profile. The Experiment 3 scaffold lives inside `#if DEBUG`;
# a Release build compiles it out entirely, so the layer destination never changes and all
# three captures come back IDENTICAL — which looks like a result ("no difference between
# destinations!") and is not one. Checked rather than assumed, because that failure is silent.
if /usr/bin/strings -a "$BIN" 2>/dev/null | grep -qF '[CSDEBUG]'; then
    echo "build:  scaffold present (Debug or Profile) — good"
else
    echo "build:  ⚠️  NO [CSDEBUG] STRINGS IN THIS BINARY."
    echo "        This is a Release build: Experiment 3 is compiled out, the destination will"
    echo "        never change, and all three captures would come out identical."
    echo "        Use a Profile build (Manifold-*-Profile.dmg) and re-run."
    exit 1
fi

# ── Helpers, compiled on demand ───────────────────────────────────────────────────────────
for tool in getwin extract; do
    if [ ! -x "./$tool" ]; then
        echo "compiling $tool…"
        swiftc -O "${HERE}/${tool}.swift" -o "./$tool" || { echo "failed to compile $tool"; exit 1; }
    fi
done

# ── Sweep ─────────────────────────────────────────────────────────────────────────────────
for idx in 0 1 2; do
    echo "=== destination index $idx ==="
    pkill -f "MacOS/Manifold" 2>/dev/null; sleep 1
    echo "$idx" > /tmp/manifold_debug_cs
    "$BIN" > "run_$idx.log" 2>&1 &
    sleep 4
    open -a "$APP" "$WEDGE"
    sleep 7

    WINFO=$(./getwin)
    WID=$(echo "$WINFO" | cut -d" " -f1)
    if [ -z "$WID" ]; then echo "  no Manifold window found"; continue; fi

    # ⚠️ THE WINDOW MUST BE 1920x1080 or the capture is not 1:1 with the fixture and every
    # patch sample lands somewhere other than the patch it names. Reported rather than
    # silently accepted: a rescaled capture still yields plausible-looking numbers.
    WW=$(echo "$WINFO" | cut -d" " -f4 | cut -d. -f1)
    WH=$(echo "$WINFO" | cut -d" " -f5 | cut -d. -f1)
    if [ "$WW" != "1920" ] || [ "$WH" != "1080" ]; then
        echo "  ⚠️  window is ${WW}x${WH}, NOT 1920x1080 — patch sampling will be wrong."
        echo "      Resize the window to exactly 1920x1080 and re-run this index."
    fi

    screencapture -x -o -l "$WID" "cap_$idx.png"
    echo "  window [$WINFO] -> cap_$idx.png"

    # Extract raw samples + the embedded display profile. Run HERE rather than as a manual
    # follow-up, so a completed sweep always leaves a complete, analysable set behind.
    ./extract "cap_$idx.png" "raw_$idx" | sed 's/^/  /'

    grep -E "\[CSDEBUG\]" "run_$idx.log" | tail -2 | sed 's/^/  /'
done

pkill -f "MacOS/Manifold" 2>/dev/null
rm -f /tmp/manifold_debug_cs

echo ""
echo "done — captures and raw samples in $OUT_DIR"
echo ""
echo "Next:"
echo "  1. characterise the display profile the capture was tagged with — the single most"
echo "     important number in this test:"
echo "       python3 ${HERE}/parse_icc.py ${OUT_DIR}/raw_0.icc"
echo "  2. fit the hypotheses (reads the gamma back out of raw_0.icc itself):"
echo "       python3 ${HERE}/analyze2.py ${OUT_DIR}"
