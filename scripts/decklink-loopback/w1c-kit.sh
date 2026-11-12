#!/bin/zsh
# Assemble a kit to run the 100-restart stress (capture closed) on another Mac with a DeckLink (docs/CARD_CLOCK_FINDINGS.md §10.26).
#   zsh scripts/decklink-loopback/w1c-kit.sh <kit dir> <fixture.mov>
# The kit mirrors this tree's layout, so `manifold-proc.sh` (which only quits or opens a build under its own tree) and `w1c-run.py`
# (which finds the build at .build-cc/Build/Products/Profile/) work there unchanged. It carries the measurement build as built here
# (.build-cc, Profile, -DMANIFOLD_CARDCLOCK), the run and process scripts, `defout` and `probe` (build them first with
# `build.sh probe` and `defout.swift`), `linkpace-ax`, the fixture, and `run-other.sh`. Nothing in it writes defaults: the
# destination is a launch argument. Copy the kit with rsync or a disk, not AirDrop (which quarantines the app).
set -eu
REPO=${0:A:h:h:h}
KIT=${1:?kit dir}; FX=${2:?fixture .mov}
APP=$REPO/.build-cc/Build/Products/Profile/Manifold.app
for f in $APP $REPO/build/decklink-loopback/defout $REPO/build/decklink-loopback/probe $REPO/build/linkpace/linkpace-ax $FX; do
  [[ -e $f ]] || { echo "missing: $f" >&2; exit 1; }
done
mkdir -p $KIT/.build-cc/Build/Products/Profile $KIT/scripts/decklink-loopback $KIT/build/decklink-loopback $KIT/build/linkpace $KIT/fixtures $KIT/runs
rm -rf $KIT/.build-cc/Build/Products/Profile/Manifold.app
ditto $APP $KIT/.build-cc/Build/Products/Profile/Manifold.app
cp $REPO/scripts/manifold-proc.sh $KIT/scripts/
cp $REPO/scripts/decklink-loopback/w1c-run.py $KIT/scripts/decklink-loopback/
cp $REPO/build/decklink-loopback/defout $REPO/build/decklink-loopback/probe $KIT/build/decklink-loopback/
cp $REPO/build/linkpace/linkpace-ax $KIT/build/linkpace/
[[ -e $KIT/fixtures/${FX:t} ]] || ln $FX $KIT/fixtures/ 2>/dev/null || cp $FX $KIT/fixtures/   # a hard link on the same volume
cat > $KIT/run-other.sh <<'EOF'
#!/bin/zsh
# 100 DeckLink output stops and starts while a 59.94 file plays, gate on, capture CLOSED (CARD_CLOCK_FINDINGS.md §10.26).
#   zsh run-other.sh [label]        (from anywhere; about 30 minutes; leave the Mac alone while it runs)
set -u
K=${0:A:h}; LAB=${1:-other-nc-5994}; mkdir -p $K/runs
zsh $K/scripts/manifold-proc.sh guard || { echo "the installed Manifold is running: quit it yourself, then run again"; exit 2; }
ps -axo comm= | grep -q '/DaVinci Resolve.app/Contents/MacOS/' && { echo "DaVinci Resolve is running: close it (it holds the card)"; exit 3; }
$K/build/decklink-loopback/probe > $K/runs/$LAB.probe.txt 2>&1
{ sw_vers; sysctl -n hw.model; system_profiler SPHardwareDataType | grep -E "Chip|Memory"; } > $K/runs/$LAB.host.txt 2>&1
W1C_NOCAP=1 W1C_OUT=$K/runs python3 $K/scripts/decklink-loopback/w1c-run.py restarts $K/fixtures/w1c-5994-1920s.mov on $LAB 100
r=$?
zsh $K/scripts/manifold-proc.sh guard || echo "!! the installed Manifold is running now: report it, do not quit it"
L=$K/runs/$LAB.log
echo "w1c-run exit $r · output starts $(grep -c 'audio preroll:' $L) · sound with its picture $(grep -c 'started with its picture' $L) · silent starts $(grep -c 'sound did not start' $L) · recovered by an output restart $(grep -c 'restarting the whole output' $L) · not restarted $(grep -c 'NOT restarted' $L) · off its picture $(grep -c 'started off its picture' $L)"
echo "send back: $K/runs/$LAB.log  $K/runs/$LAB.defout  $K/runs/$LAB.probe.txt  $K/runs/$LAB.host.txt"
EOF
chmod +x $KIT/run-other.sh
du -sh $KIT
echo "kit ready: $KIT"
