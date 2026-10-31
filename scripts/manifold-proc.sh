#!/bin/zsh
# manifold-proc.sh — the ONE way test drivers quit a Manifold build, open a file in it, or check for the
# installed app. Every driver and tool goes through this; nothing addresses Manifold by name, path or bundle id.
#
#   manifold-proc.sh guard                      exit 2 (and list them) if any process of /Applications/Manifold.app
#                                               is running, else 0. Never touches what it finds.
#   manifold-proc.sh check <pid>                exit 0 if <pid> is alive (not a zombie) and is a build from this tree, else 1
#   manifold-proc.sh quit <pid> [--no-wait] [--timeout S]
#                                               a Quit Apple event to THAT process only (NSRunningApplication
#                                               terminate), after `check`; then waits up to S s (default 30) for
#                                               it to exit (a zombie counts as exited). --no-wait returns once the event is sent (the driver
#                                               polls its own Popen). Exit 0 sent/exited, 1 refused, 3 still alive.
#   manifold-proc.sh open <pid> <file>...       open files in THAT running build, after `check`: Launch Services
#                                               with the exact bundle of that pid (see below). Refuses if the build
#                                               is not running.
#
# ⚠️ WHY (Robbie, 2026-10-29). `tell application "<path or name>" to quit`, `open -a`, `xctrace --launch` and
# `pkill -x Manifold` all go through Launch Services or match by name. Sent to a build that has already exited,
# a Quit event makes AppleScript LAUNCH the app to deliver it, and Launch Services may resolve the bundle id to
# the installed /Applications/Manifold.app. That copy then rewrites licence values in the real plist
# (2026-10-27, 2026-10-28; docs/BUGS.md, privacy P1). By pid there is nothing to resolve: a pid that has exited
# is reported and left alone, and nothing is ever launched from here.
set -u
REPO="${0:A:h:h}"
INSTALLED="/Applications/Manifold.app/"
BUILD_SUFFIX="/Manifold.app/Contents/MacOS/Manifold"

exe_of() { ps -o comm= -p "$1" 2>/dev/null; }

# Alive means running, not a zombie. A process that has exited stays in the table as a zombie (ps state Z) until its
# parent reaps it, and `kill -0` still succeeds on it. A driver that launched the build itself (Python `Popen`) and
# never waited made this script report "still running after 30 s" for a build that had quit in under a second
# (2026-10-30, docs/BUGS.md slow-quit entry). Drivers must still wait() on their child; this only stops the
# misreport.
alive() { kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }

# A build from this tree: alive, executable under $REPO, ending in Manifold.app/Contents/MacOS/Manifold,
# and never the installed copy.
is_ours() {
  local pid="$1" exe
  [[ "$pid" == <-> ]] || { echo "manifold-proc: not a pid: $pid" >&2; return 1; }
  kill -0 "$pid" 2>/dev/null || { echo "manifold-proc: pid $pid is not running — nothing sent" >&2; return 1; }
  alive "$pid" || { echo "manifold-proc: pid $pid has exited (a zombie its parent has not reaped) — nothing sent" >&2; return 1; }
  exe="$(exe_of "$pid")"
  [[ "$exe" == "$INSTALLED"* ]] && { echo "manifold-proc: pid $pid is the INSTALLED app ($exe) — refused" >&2; return 1; }
  [[ "$exe" == "$REPO/"* && "$exe" == *"$BUILD_SUFFIX" ]] \
    || { echo "manifold-proc: pid $pid is not a build from this tree ($exe) — refused" >&2; return 1; }
  return 0
}

case "${1:-}" in
  guard)
    found="$(ps -axo pid=,comm= | awk -v p="$INSTALLED" 'index($2, p) == 1 {print $1, $2}')"
    if [[ -n "$found" ]]; then
      echo "manifold-proc: GUARD — the installed app is running. Stop and report; do not quit it:" >&2
      echo "$found" >&2
      exit 2
    fi
    exit 0 ;;
  check)
    is_ours "${2:-}" ;;
  quit)
    pid="${2:-}"; shift 2 2>/dev/null; wait=1; timeout=30
    while (( $# )); do
      case "$1" in --no-wait) wait=0 ;; --timeout) timeout="$2"; shift ;; esac; shift
    done
    is_ours "$pid" || exit 1
    r="$(osascript -l JavaScript -e "ObjC.import('AppKit');
      var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid);
      a.isNil() ? 'not-an-app' : (a.terminate ? 'sent' : 'refused')" 2>&1)"
    [[ "$r" == sent ]] || { echo "manifold-proc: quit of pid $pid not sent ($r)" >&2; exit 1; }
    (( wait )) || exit 0
    for _ in {1..$(( timeout * 10 ))}; do alive "$pid" || exit 0; sleep 0.1; done
    echo "manifold-proc: pid $pid still running after ${timeout} s" >&2; exit 3 ;;
  open)
    pid="${2:-}"; shift 2 2>/dev/null
    is_ours "$pid" || exit 1
    (( $# )) || { echo "manifold-proc: open needs a file" >&2; exit 1; }
    # An `odoc` addressed by pid (JXA `Application(pid).open`) is refused with -1743: macOS Automation consent does
    # not cover osascript → Manifold document events (quit, through AppKit, is not affected). So the file goes
    # through Launch Services, but ONLY with the exact bundle of the running pid just checked: never a name or a
    # bundle id. If that pid exits between the check and the open, the worst case is that same build from this
    # tree relaunching, never /Applications; `guard` after the run would still catch anything else.
    bundle="$(exe_of "$pid")"; bundle="${bundle%/Contents/MacOS/Manifold}"
    for f in "$@"; do
      [[ -e "$f" ]] || { echo "manifold-proc: no such file: $f" >&2; exit 1; }
      is_ours "$pid" || exit 1
      open -a "$bundle" "${f:A}" || exit 1
    done ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
