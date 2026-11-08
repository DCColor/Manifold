#!/bin/zsh
# The hunt's spindump (cardlock-hunt.py). spindump needs root and the driver has none, so Robbie runs this himself, in his own terminal, for the length of a hunt:
#   sudo zsh scripts/decklink-loopback/spindump-watch.sh
# It waits for a spindump.request the driver writes on a detection, spindumps that pid for 10 s beside it, and hands the file to him. Ctrl-C ends it. Never needed for a run to go ahead.
DIR=${0:A:h:h:h}/build/cardclock/hunt; OWNER=${SUDO_USER:-$USER}
while true; do
  for r in $DIR/*/spindump.request(N); do
    pid=$(<$r); rm -f $r
    [[ $pid == <-> ]] && spindump $pid 10 -file ${r:h}/spindump.txt && chown $OWNER ${r:h}/spindump.txt
  done
  sleep 1
done
