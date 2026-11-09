#!/bin/zsh
# Interleaved freeze hunt (docs/CARD_CLOCK_FINDINGS.md §10.14): one-hour cardlock-hunt.py cycle blocks, alternating the 1b gate, until a
# wall-clock end. Each block is its own launch, guarded, quit by PID (cardlock-hunt.py does all of that). Stops at the first picture freeze
# on either side (HUNT_STOP_FIRST, exit 3; HUNT_STOP_FIRST=0 carries on), or at any other non-zero exit (guard trip, a build that would not quit or come up).
#   cardlock-interleave.sh <first on|off> <end HH:MM> <label prefix>
# HUNT_CYCLE (default 60 here) passes through. `touch build/cardclock/hunt/STOP` ends the current block and the wrapper.
set -u
HERE=${0:A:h}; REPO=${HERE:h:h}; OUT=$REPO/build/cardclock/hunt
side=$1; end=$2; prefix=$3
export HUNT_STOP_FIRST=${HUNT_STOP_FIRST:-1} HUNT_CYCLE=${HUNT_CYCLE:-60}   # HUNT_STOP_FIRST=0: carry on through freezes (watchdog verification, §10.15)
endts=$(date -j -f "%H:%M:%S" "$end:00" +%s)
(( endts <= $(date +%s) )) && endts=$(( endts + 86400 ))   # an end already past today is tomorrow's
n_on=0; n_off=0
while :; do
  now=$(date +%s); left=$(( endts - now ))
  (( left < 120 )) && { echo "$(date +%T) interleave: end reached"; break; }
  [[ -e $OUT/STOP ]] && { echo "$(date +%T) interleave: STOP file"; break; }
  hours=$(python3 -c "print(min(1.0, $left/3600))")
  if [[ $side == on ]]; then n_on=$((n_on+1)); label=$prefix-on$n_on; else n_off=$((n_off+1)); label=$prefix-off$n_off; fi
  echo "$(date +%T) interleave: block $label, gate $side, $hours h"
  python3 $HERE/cardlock-hunt.py cycle $side $label $hours
  rc=$?
  if (( rc != 0 )); then echo "$(date +%T) interleave: $label exited $rc, stopping"; exit $rc; fi
  [[ $side == on ]] && side=off || side=on
done
echo "$(date +%T) interleave: done"
