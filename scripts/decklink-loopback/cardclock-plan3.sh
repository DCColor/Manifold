#!/bin/zsh
# Does capture move the card's rate? (docs/CARD_CLOCK_FINDINGS.md, P6, P7.) Stops at the first failure or guard trip.
HERE=${0:A:h}; REPO=${HERE:h:h}; O=$REPO/build/cardclock; C=$HERE/cardclock.sh
go() { echo "=== $(date +%H:%M:%S) $*"; zsh $C launch "$@" || { echo "PLAN STOPPED at $*"; exit 1; }; }
PHASES=30 go $O/cc-5994-720s.mov sdi scarlett p6 45 45 45 45
NOCAP=1 go $O/cc-5994-2000s.mov sdi scarlett p7 1900
echo "=== $(date +%H:%M:%S) PLAN3 DONE"
