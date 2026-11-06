#!/bin/zsh
# Follow-up to the plan (docs/CARD_CLOCK_FINDINGS.md): how often a launch's file clock is on the host, per destination, and the
# card's rate per output start with its input closed. No capture in any of these. Stops at the first failure or guard trip.
HERE=${0:A:h}; REPO=${HERE:h:h}; O=$REPO/build/cardclock; C=$HERE/cardclock.sh
export NOCAP=1
go() { echo "=== $(date +%H:%M:%S) $*"; zsh $C launch "$@" || { echo "PLAN STOPPED at $*"; exit 1; }; }
for i in 1 2 3 4 5 6 7 8; do
  go $O/cc-5994-720s.mov sdi scarlett r-sdi-$i 30
  go $O/cc-5994-720s.mov computer scarlett r-com-$i 30
done
go $O/cc-5994-720s.mov sdi scarlett r-nocap 30 30 30 30 30 30 30 30
echo "=== $(date +%H:%M:%S) PLAN2 DONE"
