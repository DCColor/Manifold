#!/bin/bash
#
#  run.sh — build this working tree (Profile) and launch it, for trying a change by hand.
#
#  USAGE
#      scripts/run.sh              xcodegen, build into .build-run/, launch
#      scripts/run.sh --no-build   launch the last .build-run/ build again
#
#  The build is the one the test runs use: xcodebuild, scheme Manifold, configuration Profile (DEBUG=1, so dev
#  affordances are reachable), its own derived-data folder. .build-run/ is gitignored (`.build-*/`) and separate from
#  .build-cc/, so this never collides with a test session's build or with Xcode's Run button.
#
#  The app's output goes to ~/Desktop/manifold-run.log, overwritten on each launch. Not signed for release: the
#  licence Keychain prompt may appear (CLAUDE.md, docs/BUGS.md).
#
#  Refuses to launch while a Manifold from .build-run/ is still running: quit it first (Manifold ▸ Quit). Another
#  Manifold (an installed copy, a .build-cc/ build) does not block it. This script never quits anything.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${REPO_ROOT}/.build-run"
APP="${DERIVED}/Build/Products/Profile/Manifold.app"
BIN="${APP}/Contents/MacOS/Manifold"
LOG="${HOME}/Desktop/manifold-run.log"
BUILD_LOG="${DERIVED}/build.log"

die() { echo "run.sh: $*" >&2; exit 1; }

BUILD=1
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        -h|--help) sed -n '3,17p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
        *) die "unknown option '$arg' (use --no-build, or no option)" ;;
    esac
done

# Checked before the build too: rebuilding replaces the binary under a running copy.
running_pid() { ps -axww -o pid=,command= | grep -F -- "$BIN" | grep -v grep | awk '{print $1}' | head -1; }
PID="$(running_pid)"
[[ -z "$PID" ]] || die "a Manifold from .build-run/ is already running (PID ${PID}). Quit it first, then run this again."

if [[ $BUILD -eq 1 ]]; then
    command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
    mkdir -p "$DERIVED"
    echo "Generating the Xcode project (project.yml)…"
    ( cd "$REPO_ROOT" && xcodegen generate ) > "$BUILD_LOG" 2>&1 \
        || { tail -20 "$BUILD_LOG" >&2; die "xcodegen failed — full output in ${BUILD_LOG}"; }
    echo "Building Profile into .build-run/ (output in ${BUILD_LOG})…"
    ( cd "$REPO_ROOT" && xcodebuild -project Manifold.xcodeproj -scheme Manifold -configuration Profile \
        -derivedDataPath "$DERIVED" build ) >> "$BUILD_LOG" 2>&1
    STATUS=$?
    if [[ $STATUS -ne 0 ]] || ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$BUILD_LOG"; then
        echo "" >&2
        grep -E 'error:|\*\* BUILD FAILED \*\*' "$BUILD_LOG" | sort -u | head -30 >&2
        die "BUILD FAILED (xcodebuild exit ${STATUS}) — nothing launched. Full output in ${BUILD_LOG}"
    fi
    echo "Build succeeded."
fi

[[ -x "$BIN" ]] || die "no build at ${APP} — run without --no-build first"

: > "$LOG" || die "cannot write ${LOG}"
nohup "$BIN" > "$LOG" 2>&1 < /dev/null &
disown

echo "App: ${APP}"
echo "Log: ${LOG}"
