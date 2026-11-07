#!/bin/zsh
# Stage 1a checks of the card as master clock (docs/CARD_CLOCK_FINDINGS.md §10.8). capture stays closed. Plain Profile build in ./.build-cc.
#   cardlock.sh midplay <fixture> <label> [on-seconds off-seconds cycles]   Play with output off, then start and stop output while it plays
#   cardlock.sh outputoff <fixture> <label> <seconds>                       output never started
#   cardlock.sh transport <fixture> <label> <steps>                         output on, then MANIFOLD_DEBUG_TRANSPORT=<steps>
#   cardlock.sh live - <label> <seconds>                                    output on with a local SRT stream: no card lock
# guard && launch by absolute path, held by PID → quit by PID → guard. AX clicks on named items only; no keystrokes, no screenshots.
set -u
HERE=${0:A:h}; REPO=${HERE:h:h}; OUT=$REPO/build/cardclock; PROC=$REPO/scripts/manifold-proc.sh
DEVCLK=$REPO/build/decklink-loopback/devclock; AXT=$REPO/build/linkpace/linkpace-ax
APPB=$REPO/.build-cc/Build/Products/Profile/Manifold.app
SCARLETT='AppleUSBAudioEngine:Focusrite:Scarlett 18i20 USB:00011706:1,2'
nap() { perl -e "select(undef,undef,undef,$1)"; }
MODE=$1; F=${2:A}; LABEL=$3; T=${F:t}; LOG=$OUT/$LABEL.log; DLOG=$OUT/$LABEL.dev; PID=; DP=
[[ ( -f $F || $MODE == live ) && -x $DEVCLK && -x $AXT ]] || { echo "missing fixture or tool"; exit 1; }
SRTPID=
cleanup() {
  [[ -n $SRTPID ]] && kill $SRTPID 2>/dev/null
  [[ -n $DP ]] && kill $DP 2>/dev/null
  [[ -n $PID ]] && $PROC check $PID 2>/dev/null && $PROC quit $PID
  [[ -n $PID ]] && wait $PID 2>/dev/null
  PID=; DP=
}
fail() { echo "FAILED $LABEL: $*"; cleanup; exit 4; }
$PROC guard || { echo "GUARD: the installed app is running — stopping, nothing launched"; exit 2; }
: > $LOG
$DEVCLK "$SCARLETT" 100000 $DLOG & DP=$!
export MANIFOLD_CARDCLOCK_LOG=1 MANIFOLD_DECKLINK_CADENCE_LOG=1 MANIFOLD_PLAYBACK_STATS=1
[[ $MODE == transport ]] && export MANIFOLD_DEBUG_TRANSPORT=$4
if [[ $MODE == live ]]; then
  ffmpeg -hide_banner -loglevel error -re -f lavfi -i "testsrc2=s=1920x1080:r=60000/1001" -f lavfi -i "sine=f=1000:r=48000" \
    -c:v h264_videotoolbox -b:v 12M -g 60 -c:a aac -f mpegts "srt://127.0.0.1:9000?mode=listener" > $OUT/$LABEL.srt 2>&1 &
  SRTPID=$!; nap 1
  export MANIFOLD_DEBUG_DIAL_URL='srt://127.0.0.1:9000'
fi
"$APPB/Contents/MacOS/Manifold" -manifold.decklink.audioDestination sdi >> $LOG 2>&1 &
PID=$!; nap 7
$PROC check $PID || fail "the build did not come up"
menu() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null; }
press() { $AXT $PID press "$T" "$1" >/dev/null || fail "no $1 button in $T"; }
toggle() { echo "[DRV] OUTPUT $1 host $(perl -MTime::HiRes -e 'printf "%.3f", Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())')" >> $LOG; menu File "Start/Stop DeckLink Output"; }
if [[ $MODE == live ]]; then nap 5
else
  $PROC open $PID $F; nap 3.5
  $AXT $PID place "$T" "ASUS" >/dev/null || fail "window not placed"; nap 1.5
  menu View "Always Show Controls"; nap 1.2
fi
case $MODE in
live)
  toggle on; nap $4; toggle off; nap 2.5
  grep -q 'FAILED\|output start' $LOG || fail "output did not start" ;;
midplay)
  ON=${4:-60}; OFF=${5:-30}; N=${6:-3}
  press Play; echo "[DRV] PLAY" >> $LOG; nap $OFF
  # Stopping output pauses every deck (`[ARBITER] exclusive device released`), so each stop is followed by a Play.
  for i in {1..$N}; do toggle on; nap $ON; toggle off; nap 3; press Play; echo "[DRV] PLAY" >> $LOG; nap $OFF; done
  press Pause ;;
outputoff)
  press Play; echo "[DRV] PLAY" >> $LOG; nap $4; press Pause ;;
transport)
  toggle on
  while ! grep -q '^\[TRANSPORT\] done' $LOG; do nap 1; $PROC check $PID || fail "the build exited"; done
  nap 2; toggle off; nap 2.5 ;;
*) fail "bad mode" ;;
esac
nap 1.5
menu File "Close All"; nap 1.5
$PROC quit $PID; wait $PID 2>/dev/null; PID=
kill $DP 2>/dev/null; wait $DP 2>/dev/null; DP=
[[ -n $SRTPID ]] && kill $SRTPID 2>/dev/null; SRTPID=
$PROC guard || { echo "GUARD tripped after $LABEL"; exit 2; }
python3 -I $HERE/cardlock-summary.py $OUT $LABEL
