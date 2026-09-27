#!/bin/zsh
# Step 4e-1 live verification helper. Temporary: remove with MANIFOLD_DEBUG_PLI_EVERY_S.
#
# `new` runs this checkout's Profile build (.build-cc). `head` runs an untouched 9692f90 Profile
# build in a scratch worktree ($SCRATCH/head) — machine-local, and gone if that directory is.
#
#   verify-4e1.sh sender              ffmpeg → WHIP → MediaMTX, 20 s GOP (so an IDR inside 3 s of a
#                                     PLI is an answer, not the sender's own schedule)
#   verify-4e1.sh new  <log> [N]      4e-1 build, a PLI every N s (default 5), log tee'd to <log>
#   verify-4e1.sh head <log>          untouched HEAD 9692f90 build, for the A/V + steering compare
#   verify-4e1.sh mtx  <file>         poll the MediaMTX API every 10 s into <file> (Ctrl-C to stop)
#   verify-4e1.sh summary <log>       what the run showed
#   verify-4e1.sh compare <headlog> <newlog>   steering / A/V lines side by side

REPO="/Users/robbiecarman/Nextcloud/Vibe Code Output/Manifold/Manifold"
SCRATCH="/private/tmp/claude-501/-Users-robbiecarman-Nextcloud-Vibe-Code-Output-Manifold-Manifold/6dc017b2-3055-4478-af24-2d3545731f3a/scratchpad"
NEW="$REPO/.build-cc/Build/Products/Profile/Manifold.app/Contents/MacOS/Manifold"
OLD="$SCRATCH/head/.build-cc/Build/Products/Profile/Manifold.app/Contents/MacOS/Manifold"

case "$1" in
  sender)
    exec ffmpeg -hide_banner -re \
      -f lavfi -i "testsrc2=size=1280x720:rate=30" \
      -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
      -c:v libx264 -profile:v baseline -bf 0 -g 600 -keyint_min 600 -sc_threshold 0 \
      -tune zerolatency -b:v 2M \
      -c:a libopus -ar 48000 -ac 2 -b:a 128k \
      -f whip "http://127.0.0.1:8889/live/whip" ;;
  new)
    [[ -n "$2" ]] || { echo "usage: $0 new <log> [seconds]"; exit 1; }
    MANIFOLD_DEBUG_PLI_EVERY_S="${3:-5}" "$NEW" 2>&1 | tee "$2" ;;
  head)
    [[ -n "$2" ]] || { echo "usage: $0 head <log>"; exit 1; }
    "$OLD" 2>&1 | tee "$2" ;;
  mtx)
    [[ -n "$2" ]] || { echo "usage: $0 mtx <file>"; exit 1; }
    while true; do
      { echo "=== $(date +%T)"
        curl -s http://127.0.0.1:9997/v3/paths/list
        echo
        curl -s http://127.0.0.1:9997/v3/webrtcsessions/list
        echo; } | tee -a "$2"
      sleep 10
    done ;;
  summary)
    L="$2"; [[ -f "$L" ]] || { echo "no log: $L"; exit 1; }
    echo "── PLI"
    echo "sent:        $(grep -c '\[WHEP-PLI\] PLI #[0-9]* sent' "$L")"
    echo "answered:    $(grep -c '\[WHEP-PLI\] PLI #[0-9]* answered' "$L")"
    echo "UNANSWERED:  $(grep -c 'UNANSWERED' "$L")"
    grep -o 'IDR emitted [0-9]* ms' "$L" | awk '{print $3}' | sort -n |
      awk '{a[NR]=$1} END {if (NR) printf "answer ms:   min %d  med %d  max %d  (n=%d)\n", a[1], a[int((NR+1)/2)], a[NR], NR}'
    echo "── RR / RTCP"
    grep -m1 '\[WHEP-RR\] first' "$L" | cut -c1-260
    grep '\[WHEP-RTCP\] session summary' "$L" | cut -c1-400
    grep '\[WHEP-BRIDGE\] RTCP on track' "$L" | cut -c1-160
    echo "── SR probe"
    grep -E '\[WHEP-SR\] (✅ FIRST PAIR|session summary)' "$L" | cut -c1-300
    echo "── failures (should be empty)"
    grep -E 'FAILED|REFUSED|UNANSWERED|rtcpInRtp=[1-9]' "$L" | grep -v 'errors=0' | head -20
    echo "── decode errors (non-zero ticks)"
    grep '\[WHEP-DECODE\]' "$L" | grep -v 'errors=0' | head -5
    echo "── steering windows: $(grep -c 'steering window' "$L")  (last 2)"
    grep 'steering window' "$L" | tail -2 | sed 's/.*steering window/steering window/' | cut -c1-420 ;;
  compare)
    for L in "$2" "$3"; do
      echo "════ $L"
      grep 'steering window' "$L" |
        sed -E 's/.*window \+([0-9]+)s.*e_f ([-+0-9.]+) ms · e ms min ([-+0-9.]+) med ([-+0-9.]+) max ([-+0-9.]+).*coarse this window ([0-9]+).*/+\1s e_f \2  e min \3 med \4 max \5  coarse \6/' | head -20
      grep 'steering session END' "$L" | sed 's/.*steering session END/END/' | cut -c1-260
      grep -E '\[WHEP-SR\] session summary|timebase−clock' "$L" | tail -3 | cut -c1-260
    done ;;
  *)
    sed -n '2,11p' "$0" ;;
esac
