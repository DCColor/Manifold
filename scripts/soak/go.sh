#!/bin/zsh
# One soak run per invocation, from your own terminal (README.md):
#   zsh scripts/soak/go.sh mediamtx | cloudflare | cloudflare-long | cloudflare-srt  [--diag] [--abs] [--sender decklink]
#   --diag   diagnostic run (AUDIO_RESAMPLER_DESIGN.md §18.21): a ≥ 130 s sender probe at capture A
#            (+3 min) and capture B (+26 min), aligned with them, analysed into
#            $SOAK_OUT/soak-<label>-diag/. Needs a local probe point: mediamtx only.
#   --abs    MediaMTX with useAbsoluteTimestamp: true on the test path (mediamtx-soak-abs.yml,
#            AUDIO_RESAMPLER_DESIGN.md §18.23): the publisher's own SRs are kept instead of MediaMTX's
#            arrival clock. Label <prefix>-abs-whep-mediamtx. mediamtx only.
#   --sender decklink
#            a realistic sender (README.md, "A realistic sender"): Resolve plays the fixture out over
#            SDI into the DeckLink input, scene DECKLINK_BEEPS. No media source or scene is touched;
#            captures are timed from the file's first beep. Label <prefix>-decklink-<transport>.
#            WHEP only (mediamtx, cloudflare).
# Starts the orchestrator (soak.mjs) in the background, then Manifold in the foreground under
# caffeinate, with its log at $SOAK_LOG_DIR/<label>.log. Quitting Manifold ends this script.
#
# Environment (all optional):
#   MANIFOLD_APP   the Manifold.app to run   (default: .build-cc/soak-Profile/…/Profile/Manifold.app)
#   SOAK_PREFIX    label prefix              (default: soak → soak-whep-mediamtx, …)
#   SOAK_LOG_DIR   where Manifold's log goes (default: ~/Desktop)
#   SOAK_OUT       timelines, probe, watcher (default: ~/Desktop/manifold-soak)
#   MEDIAMTX_DIR   folder with the mediamtx binary (default: ~/Desktop/mediamtx)
set -u
S=${0:A:h}
REPO=${S:h:h}
APP="${MANIFOLD_APP:-$REPO/.build-cc/soak-Profile/Build/Products/Profile/Manifold.app}"
PREFIX="${SOAK_PREFIX:-soak}"
LOG_DIR="${SOAK_LOG_DIR:-$HOME/Desktop}"
export SOAK_OUT="${SOAK_OUT:-$HOME/Desktop/manifold-soak}"
MEDIAMTX_DIR="${MEDIAMTX_DIR:-$HOME/Desktop/mediamtx}"
mkdir -p "$SOAK_OUT"

case "${1:-}" in
  mediamtx)        LABEL=$PREFIX-whep-mediamtx;        TR=whep ;;
  cloudflare)      LABEL=$PREFIX-whep-cloudflare;      TR=whep-cf ;;
  cloudflare-long) LABEL=$PREFIX-whep-cloudflare-long; TR=whep-cf-long ;;
  cloudflare-srt)  LABEL=$PREFIX-srt-cloudflare;       TR=srt-cf ;;
  *) echo "usage: zsh go.sh mediamtx|cloudflare|cloudflare-long|cloudflare-srt"; exit 2 ;;
esac
DIAG=0
CONF=mediamtx-soak.yml
SENDER=scene
ARGS=("${@:2}")
for ((i = 1; i <= ${#ARGS}; i++)); do
  opt=${ARGS[i]}
  case $opt in
    --sender)
      (( i++ )); SENDER=${ARGS[i]:-}
      [[ $SENDER == decklink ]] || { echo "--sender takes: decklink"; exit 2; }
      [[ $TR == whep || $TR == whep-cf ]] || { echo "--sender decklink: WHEP only (mediamtx, cloudflare)"; exit 2; }
      ;;
    --diag)
      [[ $TR == whep ]] || { echo "--diag needs a local sender probe point (MediaMTX's RTSP): mediamtx only"; exit 2; }
      DIAG=1 ;;
    --abs)
      [[ $TR == whep ]] || { echo "--abs is a MediaMTX setting: mediamtx only"; exit 2; }
      CONF=mediamtx-soak-abs.yml; LABEL=$PREFIX-abs-whep-mediamtx ;;
    *) echo "unknown option: $opt (--diag, --abs, --sender decklink)"; exit 2 ;;
  esac
done
# "decklink" goes right after the prefix and any -abs: <prefix>[-abs]-decklink-whep-cloudflare.
if [[ $SENDER == decklink ]]; then
  if [[ $LABEL == $PREFIX-abs-* ]]; then LABEL=$PREFIX-abs-decklink-${LABEL#$PREFIX-abs-}
  else LABEL=$PREFIX-decklink-${LABEL#$PREFIX-}; fi
fi
LOG="$LOG_DIR/$LABEL.log"

[[ -x "$APP/Contents/MacOS/Manifold" ]] || { echo "build missing: $APP (set MANIFOLD_APP)"; exit 2; }
[[ -e "$LOG" ]] && { echo "$LOG already exists — move it aside or set SOAK_PREFIX"; exit 2; }
pgrep -x Manifold >/dev/null && { echo "Manifold is running — quit it first"; exit 2; }
lsof -nP -iTCP:4455 -sTCP:LISTEN >/dev/null 2>&1 || { echo "sender OBS (websocket 4455) is not up"; exit 2; }
lsof -nP -iTCP:4456 -sTCP:LISTEN >/dev/null 2>&1 || { echo "recorder OBS (websocket 4456) is not up"; exit 2; }

if [[ $TR == whep ]]; then
  # The soak's MediaMTX config (mediamtx-soak.yml): the plain one + RTSP (the sender probe) + HLS;
  # with --abs, mediamtx-soak-abs.yml. Restarted if RTSP is not up, or if the running MediaMTX was
  # started with the other config — so an --abs run never reuses the default server, and a default
  # run never inherits --abs.
  if ! lsof -nP -iTCP:8554 -sTCP:LISTEN 2>/dev/null | grep -qi mediamtx \
     || ! ps -axo command | grep -v grep | grep -qF -- "mediamtx $S/$CONF"; then
    [[ -x "$MEDIAMTX_DIR/mediamtx" ]] || { echo "no mediamtx binary in $MEDIAMTX_DIR (set MEDIAMTX_DIR)"; exit 2; }
    pkill -x mediamtx
    for i in {1..10}; do pgrep -x mediamtx >/dev/null || break; sleep 1; done
    (cd "$MEDIAMTX_DIR" && nohup ./mediamtx "$S/$CONF" > "$SOAK_OUT/mediamtx-soak.log" 2>&1 &)
    for i in {1..10}; do lsof -nP -iTCP:8554 -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 1; done
    lsof -nP -iTCP:8554 -sTCP:LISTEN >/dev/null 2>&1 || { echo "MediaMTX did not come up with RTSP"; exit 1; }
    echo "MediaMTX restarted with $CONF (log $SOAK_OUT/mediamtx-soak.log)"
  fi
fi

pgrep -f "$S/watcher.py" >/dev/null || { nohup python3 "$S/watcher.py" >/dev/null 2>&1 & }
(cd "$S" && SOAK_DIAG=$DIAG SOAK_SENDER=$SENDER node soak.mjs "$LABEL" "$LOG" "$TR" > "$SOAK_OUT/soak-$LABEL.out" 2>&1; echo "orchestrator exit $?" >> "$SOAK_OUT/soak-$LABEL.out") &
sleep 2
if ! pgrep -f "soak.mjs $LABEL" >/dev/null; then
  echo "orchestrator stopped at setup:"; cat "$SOAK_OUT/soak-$LABEL.out"; exit 1
fi
echo "orchestrator running (tail -f $SOAK_OUT/soak-$LABEL.out); launching Manifold → $LOG"
cd "$REPO" && caffeinate -dims "$APP/Contents/MacOS/Manifold" > "$LOG" 2>&1
