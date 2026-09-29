#!/bin/zsh
# The SR fit's state in a running (or finished) Manifold log: its events, the latest window line,
# the latest cross-check, and the session END lines. Read-only.
#   zsh scripts/soak/srfit-live.sh ~/Desktop/soak-whep-mediamtx.log
L=${1:?log}
echo "── events"
grep -a -E "\[WHEP-SRFIT\] (FIRST LINE|slope IN USE|slope LEFT|⚠️|line STABLE|SR pairs RESUMED)" "$L" | cut -c12-260 | tail -15
echo "── latest window"
grep -a "\[WHEP-SRFIT\] window" "$L" | tail -1 | cut -c12-400
echo "── cross-check (INFO every 60 s once 540 s are in; WARNING when > 10 ppm)"
grep -a -E "slope cross-check|WARNING SLOPE CROSS-CHECK" "$L" | tail -3 | cut -c12-400
echo "   warnings so far: $(grep -a -c 'WARNING SLOPE CROSS-CHECK' "$L")"
echo "── renderer depth (last 3 windows)"
grep -a "steering window" "$L" | tail -3 | sed -E 's/.*steering window (\+[0-9]+s).*renderer depth ms (.*)/\1  \2/'
echo "── END"
grep -a -E "SRFIT\] session END|steering session END" "$L" | cut -c12-700
