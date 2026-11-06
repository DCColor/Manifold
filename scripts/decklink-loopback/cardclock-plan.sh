#!/bin/zsh
# The card-clock run plan (docs/CARD_CLOCK_FINDINGS.md §2). Stops at the first failure or guard trip. One line per launch to stdout.
HERE=${0:A:h}; REPO=${HERE:h:h}; O=$REPO/build/cardclock; C=$HERE/cardclock.sh
go() { echo "=== $(date +%H:%M:%S) $*"; zsh $C launch "$@" || { echo "PLAN STOPPED at $*"; exit 1; }; }
# Q2: one 30 min session
[[ -e $O/q2-s1.json ]] || go $O/cc-5994-2000s.mov sdi scarlett q2 1800
# Q3: four launches, two sessions each: fresh launch, then stop/start in that launch
for i in 1 2 3 4; do go $O/cc-5994-720s.mov sdi scarlett q3-l$i 300 300; done
# Q1: 600 s each, both rates: no audio, built-in, Scarlett, SDI (default device Scarlett)
for r in 5994 2398; do
  go $O/cc-$r-720s-noaudio.mov computer scarlett q1-$r-noaudio 600
  go $O/cc-$r-720s.mov computer builtin q1-$r-builtin 600
  go $O/cc-$r-720s.mov computer scarlett q1-$r-scarlett 600
  go $O/cc-$r-720s.mov sdi scarlett q1-$r-sdi 600
done
# Q1 extra: destination SDI with the muted renderer named to the built-in: does the muted renderer's own device set the clock?
go $O/cc-5994-720s.mov sdi builtin q1-5994-sdi-builtin 300
echo "=== $(date +%H:%M:%S) PLAN DONE"
