#!/bin/zsh
# One unattended SRT repro run (README.md, "Local SRT repro"): serve <file.ts> as a local SRT
# listener, launch Manifold with the DEBUG-only MANIFOLD_SRT_DEBUG_URL override (no bookmark, so no
# keychain read), Deny the unsigned build's licence prompt, press ⌃⌥D, and wait for the file to end.
#   zsh scripts/soak/repro/run.sh <label> <file.ts>
# Environment (optional):
#   MANIFOLD_APP  the Manifold.app (default .build-cc/soak-Profile/…); must be a DEBUG (Profile) build
#   READRATE      ffmpeg -readrate (default 1 = real time; 0.99997 = content arriving 30 ppm slow)
#   PES_PAYLOAD   ffmpeg -pes_payload_size (default 0: one AAC frame per PES where frames exceed
#                 170 bytes; "default" leaves ffmpeg's own packing, several frames per PES)
#   STALLS        induced delivery stalls, "<s after connect>:<ms>" pairs, space-separated
#                 (e.g. "60:100 90:200 120:400"): the sender is SIGSTOPped for <ms>, then resumed.
#                 Each is logged with its wall-clock time to <label>.stalls.log.
#   SOAK_OUT      where <label>.manifold.log / .ffmpeg.log go (default ~/Desktop/manifold-soak/repro)
# Needs UI scripting (Accessibility) for the process running it; osascript fails loudly without it.
set -u
LABEL=$1; FILE=$2
REPO=${0:A:h:h:h:h}
APP_BUNDLE="${MANIFOLD_APP:-$REPO/.build-cc/soak-Profile/Build/Products/Profile/Manifold.app}"
APP="$APP_BUNDLE/Contents/MacOS/Manifold"
[[ -x "$APP" ]] || { echo "build missing: $APP_BUNDLE (set MANIFOLD_APP)"; exit 2; }
[[ -f "$FILE" ]] || { echo "no such file: $FILE"; exit 2; }
D="${SOAK_OUT:-$HOME/Desktop/manifold-soak}/repro"; mkdir -p "$D"
LOG="$D/$LABEL.manifold.log"; FLOG="$D/$LABEL.ffmpeg.log"
[[ -e "$LOG" ]] && { echo "$LOG already exists — pick another label"; exit 2; }
say_() { echo "$(date +%H:%M:%S) $*"; }
deny() { osascript -e 'tell application "System Events" to if exists process "SecurityAgent" then tell process "SecurityAgent" to click button "Deny" of window 1' >/dev/null 2>&1; }

pgrep -x Manifold >/dev/null && { say_ "Manifold already running — abort"; exit 2; }
lsof -nP -iUDP:9000 >/dev/null 2>&1 && { say_ "port 9000 busy — abort"; exit 2; }

say_ "launch Manifold → $LOG"
MANIFOLD_SRT_DEBUG_URL='srt://127.0.0.1:9000' caffeinate -dims "$APP" > "$LOG" 2>&1 &
MPID=$!
# Deny licence prompts and wait for the app to be up (its first [LICENSE] or any 10 s of life).
for i in {1..40}; do deny; sleep 1; grep -q "\[LICENSE\]" "$LOG" 2>/dev/null && [[ $i -ge 8 ]] && break; done
for i in {1..5}; do deny; sleep 1; done
# A launch after a forced quit can restore with no window; ⌃⌥D needs one.
for i in {1..3}; do
  n=$(osascript -e 'tell application "System Events" to tell process "Manifold" to count windows' 2>/dev/null)
  [[ ${n:-0} -gt 0 ]] && break
  say_ "no window — ⌘N"
  osascript -e 'tell application "System Events" to tell process "Manifold" to set frontmost to true' -e 'delay 0.5' \
            -e 'tell application "System Events" to keystroke "n" using {command down}'
  sleep 3
done

PESOPT="-pes_payload_size ${PES_PAYLOAD:-0}"; [[ ${PES_PAYLOAD:-0} == default ]] && PESOPT=""
say_ "serve $FILE on srt://127.0.0.1:9000 (listener)"
ffmpeg -hide_banner -loglevel warning -readrate "${READRATE:-1}" -i "$FILE" -map 0:v -map 0:a -c copy ${=PESOPT} -f mpegts \
  'srt://127.0.0.1:9000?mode=listener' > "$FLOG" 2>&1 &
FPID=$!
sleep 2

up=0
for attempt in 1 2 3; do
  deny
  osascript -e 'tell application "System Events" to tell process "Manifold" to set frontmost to true' \
            -e 'delay 0.5' \
            -e 'tell application "System Events" to keystroke "d" using {control down, option down}'
  say_ "⌃⌥D sent (attempt $attempt)"
  for i in {1..20}; do sleep 1; grep -q "\[SRT\] transport up" "$LOG" && { up=1; break; }; done
  [[ $up == 1 ]] && break
done
[[ $up == 1 ]] || { say_ "no SRT connect — abort"; kill $FPID $MPID 2>/dev/null; exit 1; }
say_ "connected"

if [[ -n "${STALLS:-}" ]]; then
  SLOG="$D/$LABEL.stalls.log"
  ( t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    for pair in ${=STALLS}; do
      at=${pair%%:*}; ms=${pair##*:}
      perl -MTime::HiRes=time,sleep -e "my \$d=$t0+$at-time; sleep(\$d) if \$d>0"
      kill -STOP $FPID 2>/dev/null || break
      perl -MTime::HiRes=sleep -e "sleep($ms/1000)"
      kill -CONT $FPID
      echo "$(perl -MPOSIX=strftime -MTime::HiRes=time -e '$t=time; printf "%s.%03d", strftime("%H:%M:%S",localtime $t), ($t-int $t)*1000') stalled ${ms} ms (resumed), +${at}s" >> "$SLOG"
    done ) &
fi

# Keep denying licence re-prompts until the file ends.
while kill -0 $FPID 2>/dev/null; do deny; sleep 5; done
say_ "ffmpeg ended ($(tail -1 "$FLOG" 2>/dev/null))"
sleep 20
osascript -e 'tell application "Manifold" to quit' >/dev/null 2>&1; sleep 5; pkill -TERM -x Manifold 2>/dev/null
for i in {1..10}; do pgrep -x Manifold >/dev/null || break; sleep 1; done
pgrep -x Manifold >/dev/null && pkill -KILL -x Manifold
say_ "done: $(grep -c '\[AV-LAG\]' "$LOG") [AV-LAG] lines"
