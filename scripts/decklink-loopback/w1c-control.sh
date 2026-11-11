#!/bin/zsh
# SDI A/V offset control (docs/CARD_CLOCK_FINDINGS.md §10.16): the same file through `syncout` (no anchor loop: picture n and its samples
# scheduled at the same stream time), captured as w1c-run.py captures Manifold, so the same analysers read both.
#   w1c-control.sh <fixture.mov> <its PCM, s32le stereo> <5994|2398> <label> <seconds>
# SYNCOUT_ARGS: more syncout options (e.g. "--flush-at 10 --flush-every 10", §10.20 C0). No Manifold build is launched. Refuses if any Manifold process runs (the card would be in use), and runs the guard before and after.
set -eu
HERE=${0:A:h}; REPO=${HERE:h:h}; DEV=$REPO/build/decklink-loopback; PROC=$REPO/scripts/manifold-proc.sh
OUT=${W1C_OUT:-$HOME/Code/_scratch/manifold-1c-wire/runs}; mkdir -p $OUT
FX=$1; PCM=$2; RATE=$3; LABEL=$4; SECS=$5
$PROC guard
if pgrep -x Manifold >/dev/null; then echo "a Manifold process is running: stopping"; exit 4; fi
$DEV/capture --device 0 --seconds 99999 --label $LABEL --marks $OUT/$LABEL.marks --audio $OUT/$LABEL.raw --luma > $OUT/$LABEL.cap 2>&1 &
CAP=$!
sleep 2
ffmpeg -nostdin -hide_banner -loglevel error -i $FX -t $SECS -map 0:v -f rawvideo -c:v v210 - \
  | $DEV/syncout --device 0 --rate $RATE --audio $PCM --seconds $SECS ${=SYNCOUT_ARGS:-} > $OUT/$LABEL.log 2>&1 || echo "syncout exit $?"
sleep 1.5
kill -TERM $CAP; wait $CAP || true   # TERM: a background job of a non-interactive zsh ignores INT
$PROC guard
cat $OUT/$LABEL.log
