#!/bin/zsh
# SDI frame identity on the wire, for the display-link work (docs/DISPLAY_LINK_PER_WINDOW_PLAN.md §5.2; the 60 Hz-main
# baseline, addition A). Device 0's SDI output looped into device 0's own SDI input (profile 1dfd, one full-duplex
# sub-device, as in COLOR_MANAGEMENT_FINDINGS.md S7-5). Every fixture picture carries its number in the I2 marker band
# (scripts/interlaced/generate-i2.sh, here progressive), and `capture --marks` reads it off every received frame, so a
# repeat or a skip on the wire is counted by identity, not inferred.
#
#   zsh scripts/decklink-loopback/linkpace.sh fixtures
#       → build/linkpace/ : mark-1080p5994-660s.mov, mark-1080p2398-60s.mov, mark-2160p5994-30s.mov, mark-1080p11988-30s.mov
#   zsh scripts/decklink-loopback/linkpace.sh run <app bundle> <fixture> <lg|asus> <seconds> <label>
#       guard && launch the bundle's binary (held by PID), open the fixture, place the window, start DeckLink output
#       (Follow source), Play, capture <seconds> of the loop, stop, quit by PID, guard; then the summary below.
#
# Accessibility clicks on named menu items and buttons only; no keystrokes, no screenshots; never addresses Manifold by
# name or bundle id (scripts/manifold-proc.sh). Changes no display, defaults key or Desktop Video setting. Making the
# ASUS the main display for the baseline is Robbie's step, done by hand before the run.
#
# Summary (python, from the marks file and the app's log): pictures received; on the wire, repeats (the same number as
# the frame before), skips (a jump of more than one) and backs; the card's late / dropped (DeckLink D3); the card-input
# repeats and skips ([CADENCE]); the pacer's interval line ([PACER], new builds only).
set -u
HERE=${0:A:h}; REPO=${HERE:h:h}; OUT=$REPO/build/linkpace; mkdir -p $OUT
CAP=$REPO/build/decklink-loopback/capture
PROC=$REPO/scripts/manifold-proc.sh
AXT=$OUT/linkpace-ax
nap() { perl -e "select(undef,undef,undef,$1)"; }

# The AX helper: press a named button in a named window (window children only; never walks into a menu, whose AX read
# would open it), or place a window on a display found by NAME — so it lands right whichever display is main.
axtool() {
  [[ -x $AXT ]] && return
  cat > $OUT/linkpace-ax.swift <<'SWIFT'
import AppKit
import ApplicationServices
// linkpace-ax <pid> press <window title> <button description>
// linkpace-ax <pid> place <window title> <display name substring>
let a = CommandLine.arguments, pid = pid_t(a[1])!, verb = a[2], title = a[3], arg = a[4]
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func find(_ e: AXUIElement) -> AXUIElement? {
    if (attr(e, kAXRoleAttribute) as? String) == "AXButton", (attr(e, kAXDescriptionAttribute) as? String) == arg { return e }
    if (attr(e, kAXRoleAttribute) as? String) == "AXMenu" { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(c) { return f } }
    return nil
}
for w in (attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? [] where (attr(w, kAXTitleAttribute) as? String) == title {
    if verb == "press", let b = find(w) { print("press:", AXUIElementPerformAction(b, kAXPressAction as CFString).rawValue); exit(0) }
    if verb == "place" {
        guard let s = NSScreen.screens.first(where: { $0.localizedName.contains(arg) }), let main = NSScreen.screens.first else { print("no display \(arg)"); exit(1) }
        var p = CGPoint(x: s.frame.minX + 40, y: main.frame.maxY - s.frame.maxY + 40)   // AX: top-left of the main display
        print("place:", AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!).rawValue); exit(0)
    }
}
print("not found"); exit(1)
SWIFT
  swiftc -O $OUT/linkpace-ax.swift -o $AXT 2>/dev/null || { echo "could not build the AX helper"; exit 1; }
}

band() {   # $1 size WxH, $2 rate, $3 seconds: testsrc2 with the frame number drawn and the 16-bit marker band over rows 0–63
  local w=${1%x*} b=$(( ${1%x*} / 20 )) k="floor(X/$(( ${1%x*} / 20 )))"
  print -r -- "testsrc2=s=${1}:r=${2}:d=${3},drawtext=fontfile=/System/Library/Fonts/Menlo.ttc:text='%{n}':fontsize=200:fontcolor=white:box=1:boxcolor=black:x=160:y=160,format=yuv420p[bg];color=c=black:s=${w}x64:r=${2}:d=${3},format=yuv420p,geq=lum='16+219*if(lt($k\,16)\,bitand(floor(N/pow(2\,$k))\,1)\,eq(mod($k\,2)\,0))':cb=128:cr=128[band];[bg][band]overlay=0:0:shortest=1"
}

case ${1:-} in
fixtures)
  q=(-hide_banner -loglevel error -y)
  ffmpeg $q -f lavfi -i "$(band 1920x1080 60000/1001 660)" -c:v h264_videotoolbox -b:v 20M $OUT/mark-1080p5994-660s.mov
  ffmpeg $q -f lavfi -i "$(band 1920x1080 24000/1001 60)"  -c:v h264_videotoolbox -b:v 12M $OUT/mark-1080p2398-60s.mov
  ffmpeg $q -f lavfi -i "$(band 3840x2160 60000/1001 30)"  -c:v hevc_videotoolbox -b:v 60M -tag:v hvc1 $OUT/mark-2160p5994-30s.mov
  ffmpeg $q -f lavfi -i "$(band 1920x1080 120000/1001 30)" -c:v h264_videotoolbox -b:v 30M $OUT/mark-1080p11988-30s.mov
  ls -l $OUT ;;
run)
  APPB=$2; F=$3; WHERE=$4; SECS=$5; LABEL=$6; T=${F:t}; LOG=$OUT/$LABEL.log; MARKS=$OUT/$LABEL.marks
  [[ -x $CAP ]] || { echo "build the capture first: zsh scripts/decklink-loopback/build.sh capture"; exit 1; }
  axtool
  $PROC guard || { echo "GUARD: the installed app is running — stopping, nothing launched"; exit 2; }
  : > $LOG
  MANIFOLD_DECKLINK_CADENCE_LOG=1 "$APPB/Contents/MacOS/Manifold" >> $LOG 2>&1 &
  PID=$!; nap 7
  $PROC check $PID || { echo "the build did not come up"; exit 3; }
  menu() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null; }
  press() { $AXT $PID press "$T" "$1" >/dev/null || echo "no $1 button in $T"; }
  $PROC open $PID $F; nap 3.5
  if [[ $WHERE == asus ]]; then $AXT $PID place "$T" "ASUS"; else $AXT $PID place "$T" "LG"; fi; nap 1.5
  grep -q 'CGDisplayCopyColorSpace' $LOG && grep 'obtained via' $LOG | tail -1
  menu View "Always Show Controls"; nap 1.2
  menu File "Start/Stop DeckLink Output"; nap 3
  echo "[DRV] BEGIN $LABEL" >> $LOG
  press Play; nap 1
  $CAP --device 0 --seconds $SECS --label $LABEL --marks $MARKS > $OUT/$LABEL.cap 2>&1
  echo "[DRV] END $LABEL" >> $LOG
  press Pause; nap 1.5
  menu File "Start/Stop DeckLink Output"; nap 2.5
  menu File "Close All"; nap 1.5
  $PROC quit $PID; wait $PID 2>/dev/null
  $PROC guard || echo "GUARD tripped after the run"
  python3 -I $HERE/linkpace-summary.py $MARKS $LOG ;;
*) sed -n '2,24p' $0 ;;
esac
