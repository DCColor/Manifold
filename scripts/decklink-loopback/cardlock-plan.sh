#!/bin/zsh
# Stage 1a, §10.8: every run, short checks first. Stops at the first failure; a tripped guard stops everything.
set -u
HERE=${0:A:h}; REPO=${HERE:h:h}; B=$REPO/build/cardclock; K="zsh $HERE/cardlock.sh"; C="zsh $HERE/cardclock.sh launch"
run() { echo "=== $(date +%H:%M:%S) $*"; "$@" || { echo "PLAN STOPPED at $*"; exit 1; }; }
if [[ ${1:-short} == short ]]; then
run zsh $HERE/cardlock.sh midplay $B/cc-5994-720s-noaudio.mov a4-mid 60 30 3
run zsh $HERE/cardlock.sh outputoff $B/cc-5994-720s.mov a6-off-sound 300
run zsh $HERE/cardlock.sh outputoff $B/cc-5994-720s-noaudio.mov a6-off-noaudio 300
NOCAP=1 run zsh $HERE/cardclock.sh launch $B/cc-5994-720s.mov sdi scarlett a7-on-sound 300
run zsh $HERE/cardlock.sh live - a8-live 40
run zsh $HERE/cardclock.sh launch $B/cc-5994-720s-noaudio.mov sdi scarlett a-stress-5994 300
run zsh $HERE/cardclock.sh launch $B/cc-2398-720s-noaudio.mov sdi scarlett a-stress-2398 300
fi
NOCAP=1 run zsh $HERE/cardclock.sh launch $B/cc-5994-2450s-noaudio.mov sdi scarlett a1-5994-r1 2400
NOCAP=1 run zsh $HERE/cardclock.sh launch $B/cc-2398-2450s-noaudio.mov sdi scarlett a2-2398-r1 2400
NOCAP=1 run zsh $HERE/cardclock.sh launch $B/cc-5994-2450s-noaudio.mov sdi scarlett a1-5994-r2 2400
NOCAP=1 run zsh $HERE/cardclock.sh launch $B/cc-2398-2450s-noaudio.mov sdi scarlett a2-2398-r2 2400
echo "=== $(date +%H:%M:%S) PLAN DONE"
