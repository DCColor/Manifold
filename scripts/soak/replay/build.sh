#!/bin/zsh
# Build the replay binaries into $SOAK_OUT/replay-bin (README.md):
#   replay-before   open loop, the SR fit at git revision $1 (default 61d6f28, before the staircase fix)
#   replay-after    open loop, the working tree's fit (cross-check log-only)
#   replay-closed   closed loop, the working tree's fit + cross-check + level hold (§18.7 figures)
#   replay-level    closed loop, the level hold's figures (§18.20): start → +26, worst, forced sweep
#   replay-offset-lock  open loop, the fit's applied offset against the candidate offset lock (§18.22)
set -eu
R=${0:A:h}; REPO=${R:h:h:h}
SRC="$REPO/Packages/ManifoldCore/Sources/LiveAudioResample"
BIN="${SOAK_OUT:-$HOME/Desktop/manifold-soak}/replay-bin"; mkdir -p "$BIN"
BEFORE=${1:-61d6f28}
git -C "$REPO" show "${BEFORE}:Packages/ManifoldCore/Sources/LiveAudioResample/SenderReportLineFit.swift" > "$BIN/before-fit.swift"
swiftc -O -o "$BIN/replay-before" "$R/lock.swift" "$BIN/before-fit.swift" "$R/open-loop/main.swift"
swiftc -O -D NEWFIT -o "$BIN/replay-after" "$R/lock.swift" "$SRC/SenderReportLineFit.swift" \
  "$SRC/SenderReportSlopeCrossCheck.swift" "$R/open-loop/main.swift"
swiftc -O -o "$BIN/replay-closed" "$R/lock.swift" "$SRC/SenderReportLineFit.swift" \
  "$SRC/SenderReportSlopeCrossCheck.swift" "$R/closed-loop/main.swift"
swiftc -O -o "$BIN/replay-level" "$R/lock.swift" "$SRC/SenderReportLineFit.swift" \
  "$SRC/SenderReportSlopeCrossCheck.swift" "$R/level/main.swift"
swiftc -O -o "$BIN/replay-offset-lock" "$R/lock.swift" "$SRC/SenderReportLineFit.swift" \
  "$SRC/SenderReportSlopeCrossCheck.swift" "$R/offset-lock/main.swift"
echo "built into $BIN"
