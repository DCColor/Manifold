#!/bin/zsh
# Stage 1b, §10.11: every run, short checks first. Stops at the first failure; a tripped guard stops everything.
#   cardlock-1b-plan.sh short | long
set -u
export MANIFOLD_CARDLOCK_1B=1   # Stage 1b is off without it
HERE=${0:A:h}; REPO=${HERE:h:h}; B=$REPO/build/cardclock; C=$HERE/cardclock.sh; K=$HERE/cardlock.sh
# FROM=<label>: skip every run before the one with that label, to resume a stopped plan.
run() {
  if [[ -n ${FROM:-} ]]; then [[ " $* " == *" $FROM "* ]] && FROM= || return 0; fi
  echo "=== $(date +%H:%M:%S) $*"; "$@" || { echo "PLAN STOPPED at $*"; exit 1; }
}
if [[ ${1:-short} == short ]]; then
TR="wait 15;play;wait 12;pause;wait 3;play;wait 10;seek 300;wait 10;pause;wait 2;step 1;wait 1;step 1;wait 1;step -1;wait 2;play;wait 10;shuttle 2;wait 6;shuttle 1;wait 10;shuttle -1;wait 3;shuttle 0;wait 2;play;wait 10;loop;seek 700;wait 35;pause;wait 2"
FL="wait 15;play;wait 12"; for i in {1..5}; do FL="$FL;dest computer;wait 8;dest sdi;wait 8"; done; FL="$FL;pause;wait 2"
PW="wait 15;play"; for i in {1..16}; do PW="$PW;wait 4;pause;wait 1.5;play"; done; for i in {1..4}; do PW="$PW;wait 3;pause;seek 0;wait 1.5;play"; done; PW="$PW;wait 3;pause;wait 1"
run zsh $K playwire $B/cc-5994-720s.mov b18-5994 "$PW" 125
run zsh $K playwire $B/cc-2398-720s.mov b18-2398 "$PW" 125
run zsh $K midplay $B/cc-5994-720s.mov b7-mid 60 30 3
run zsh $K transport $B/cc-5994-720s.mov b9-transport "$TR"
run zsh $K transport $B/cc-5994-720s.mov b11-flip "$FL"
run zsh $K live - b16-live 40
NOCAP=1 run zsh $C launch $B/cc-5994-720s-noaudio.mov sdi scarlett b15-noaudio 300
NOCAP=1 run zsh $C launch $B/cc-5994-320s.mxf sdi scarlett b12-libav 300
PHASES=30 run zsh $C launch $B/cc-5994-720s.mov sdi scarlett b10-phases 30 30 30 30
run zsh $C launch $B/cc-5994-720s.mov sdi scarlett b10-5994 300
run zsh $C launch $B/cc-2398-720s.mov sdi scarlett b10-2398 300
NOCAP=1 INPUT_AT=200 run zsh $C launch $B/cc-5994-720s.mov sdi scarlett b6-5994 600
NOCAP=1 INPUT_AT=200 run zsh $C launch $B/cc-2398-720s.mov sdi scarlett b6-2398 600
INPUT_AT=100 run zsh $C launch $B/cc-5994-720s.mov sdi scarlett b6w-5994 300
else
NOCAP=1 run zsh $C launch $B/cc-5994-2450s.mov sdi scarlett b1-5994-r1 2400
NOCAP=1 run zsh $C launch $B/cc-2398-2450s.mov sdi scarlett b2-2398-r1 2400
NOCAP=1 run zsh $C launch $B/cc-5994-2450s.mov sdi scarlett b1-5994-r2 2400
NOCAP=1 run zsh $C launch $B/cc-2398-2450s.mov sdi scarlett b2-2398-r2 2400
NOCAP=1 run zsh $C launch $B/cc-5994-2450s.mov computer scarlett b13-computer 1250
run zsh $K outputoff $B/cc-5994-2450s.mov b14-off-sound 1250
run zsh $K outputoff $B/cc-5994-720s-noaudio.mov b14-off-noaudio 300
fi
echo "=== $(date +%H:%M:%S) PLAN DONE"
