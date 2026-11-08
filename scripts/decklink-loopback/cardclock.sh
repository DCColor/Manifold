#!/bin/zsh
# Card-clock measurement runs (docs/CARD_CLOCK_FINDINGS.md). Needs the measurement build:
#   xcodebuild -project Manifold.xcodeproj -scheme Manifold -configuration Profile -derivedDataPath ./.build-cc \
#     'OTHER_SWIFT_FLAGS=$(inherited) -DMANIFOLD_CARDCLOCK' build
# and scripts/decklink-loopback/cardclock-fixtures.sh, devclock, capture, and build/linkpace/linkpace-ax (linkpace.sh builds it).
#
#   cardclock.sh launch <fixture> <dest sdi|computer> <device scarlett|builtin> <label> <seconds> [<seconds> ...]
# One launch. Each <seconds> is one output session in that launch: output start, Play, capture, Pause, output stop. Sessions are
# labelled <label>-s1, -s2. The destination is a launch argument (argument domain: nothing written to defaults). `builtin` names the
# device through MANIFOLD_CARDCLOCK_AUDIO_DEVICE_UID, so the system default output is never changed. `scarlett` is the system
# default. devclock logs the named device's sample clock across the launch.
#
# guard && launch by absolute path, held by PID → quit by PID → guard. AX clicks on named items only; no keystrokes, no screenshots.
set -u
HERE=${0:A:h}; REPO=${HERE:h:h}; OUT=$REPO/build/cardclock; PROC=$REPO/scripts/manifold-proc.sh
CAP=$REPO/build/decklink-loopback/capture; DEVCLK=$REPO/build/decklink-loopback/devclock; AXT=$REPO/build/linkpace/linkpace-ax
APPB=${APPB:-$REPO/.build-cc/Build/Products/Profile/Manifold.app}
SCARLETT='AppleUSBAudioEngine:Focusrite:Scarlett 18i20 USB:00011706:1,2'; BUILTIN=BuiltInSpeakerDevice
nap() { perl -e "select(undef,undef,undef,$1)"; }
[[ ${1:-} == launch ]] || { sed -n '2,14p' $0; exit 1; }
F=${2:A}; DEST=$3; DEV=$4; LABEL=$5; shift 5; T=${F:t}; LOG=$OUT/$LABEL.log; DLOG=$OUT/$LABEL.dev; PID=; DP=; CP=; IP=
[[ -f $F && -x $CAP && -x $DEVCLK && -x $AXT ]] || { echo "missing fixture or tool"; exit 1; }
[[ $DEST == sdi || $DEST == computer ]] || { echo "bad destination"; exit 1; }
case $DEV in scarlett) UID_=$SCARLETT ;; builtin) UID_=$BUILTIN ;; *) echo "bad device"; exit 1 ;; esac
cleanup() {
  [[ -n $CP ]] && kill $CP 2>/dev/null
  [[ -n $IP ]] && kill $IP 2>/dev/null
  [[ -n $DP ]] && kill $DP 2>/dev/null
  [[ -n ${FP:-} ]] && kill $FP 2>/dev/null
  [[ -n $PID ]] && $PROC check $PID 2>/dev/null && $PROC quit $PID
  [[ -n $PID ]] && wait $PID 2>/dev/null
  PID=; DP=; CP=
}
fail() { echo "FAILED $LABEL: $*"; cleanup; exit 4; }
$PROC guard || { echo "GUARD: the installed app is running — stopping, nothing launched"; exit 2; }
: > $LOG
$DEVCLK "$UID_" 100000 $DLOG & DP=$!
FP=; [[ -n ${DEFOUT:-} ]] && { $REPO/build/decklink-loopback/defout 100000 $OUT/$LABEL.defout & FP=$!; }   # DEFOUT=1: log the system default output
if [[ $DEV == builtin ]]; then
  MANIFOLD_CARDCLOCK_AUDIO_DEVICE_UID=$UID_ MANIFOLD_CARDCLOCK_LOG=1 MANIFOLD_DECKLINK_CADENCE_LOG=1 \
    "$APPB/Contents/MacOS/Manifold" -manifold.decklink.audioDestination $DEST >> $LOG 2>&1 &
else
  MANIFOLD_CARDCLOCK_LOG=1 MANIFOLD_DECKLINK_CADENCE_LOG=1 \
    "$APPB/Contents/MacOS/Manifold" -manifold.decklink.audioDestination $DEST >> $LOG 2>&1 &
fi
PID=$!; nap 7
$PROC check $PID || fail "the build did not come up"
menu() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null; }
press() { $AXT $PID press "$T" "$1" >/dev/null || fail "no $1 button in $T"; }
$PROC open $PID $F; nap 3.5
$AXT $PID place "$T" "ASUS" >/dev/null || fail "window not placed"; nap 1.5
[[ $DEV != builtin ]] || grep -q "device read-back: $UID_" $LOG || fail "no device read-back: not the measurement build, or the device was refused"
menu View "Always Show Controls"; nap 1.2
i=0
for SECS in "$@"; do
  i=$(( i + 1 )); S=$LABEL-s$i; before=$(grep -c 'CARDCLOCK-REF\] start' $LOG)
  menu File "Start/Stop DeckLink Output"; nap 3
  (( $(grep -c 'CARDCLOCK-REF\] start' $LOG) == before + 1 )) || fail "output did not start for $S"
  echo "[DRV] BEGIN $S" >> $LOG
  press Play; nap 1
  # INPUT_AT=<s>: a second process opens the Scarlett's input <s> after Play, for INPUT_FOR seconds (default 20): the device restarts its IO (§10.11 B6)
  if [[ -n ${INPUT_AT:-} ]]; then ( nap $INPUT_AT; $REPO/build/decklink-loopback/devinput "$SCARLETT" ${INPUT_FOR:-20} voice >> $LOG 2>&1 ) & IP=$!; fi
  # UNTIL=<file>: run until that file exists, for an attended step of unknown length. <seconds> is then only the upper limit
  if [[ -n ${UNTIL:-} ]]; then for _ in {1..$SECS}; do [[ -e $UNTIL ]] && break; nap 1; done
  elif [[ -n ${NOCAP:-} ]]; then nap $SECS   # NOCAP=1: no capture, so the card's input stays closed and nothing counts the wire
  elif [[ -n ${PHASES:-} ]]; then   # PHASES=<s>: <s> without capture, capture for SECS, <s> without, in one output session
    nap $PHASES; echo "[DRV] CAP-OPEN" >> $LOG
    $CAP --device 0 --seconds $SECS --label $S --marks $OUT/$S.marks > $OUT/$S.cap 2>&1 & CP=$!; wait $CP; CP=
    echo "[DRV] CAP-CLOSED" >> $LOG; nap $PHASES
  else $CAP --device 0 --seconds $SECS --label $S --marks $OUT/$S.marks > $OUT/$S.cap 2>&1 & CP=$!; wait $CP; CP=; fi
  [[ -n ${IP:-} ]] && { wait $IP; IP=; }
  echo "[DRV] END $S" >> $LOG
  $PROC check $PID || fail "the build exited during $S"
  $AXT $PID press "$T" Pause >/dev/null || echo "[DRV] no Pause button: the file had already ended" >> $LOG   # capture can overrun --seconds
  nap 1.5
  menu File "Start/Stop DeckLink Output"; nap 2.5
done
menu File "Close All"; nap 1.5
$PROC quit $PID; wait $PID 2>/dev/null; PID=
kill $DP 2>/dev/null; wait $DP 2>/dev/null; DP=
[[ -n $FP ]] && kill $FP 2>/dev/null
$PROC guard || { echo "GUARD tripped after $LABEL"; exit 2; }
python3 -I $HERE/cardclock-summary.py $OUT $LABEL
python3 -I $HERE/cardlock-1b.py $OUT $LABEL
