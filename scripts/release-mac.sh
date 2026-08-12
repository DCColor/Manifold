#!/bin/bash
#
#  release-mac.sh — build, sign, notarize and staple a Manifold DMG.
#
#  USAGE
#      scripts/release-mac.sh [Profile|Release]        (default: Profile)
#
#      MANIFOLD_DIST_DIR=/some/path scripts/release-mac.sh Release
#
#  ── WHY THE DEFAULT IS Profile AND NOT Release ─────────────────────────────────────────
#
#  The TESTER build ships Profile: -O + whole-module with DEBUG defined, so it runs at real
#  speed but keeps the [SRT-FLOW] / [WHEP-FLOW] / depth telemetry that Manifold ▸ Export
#  Diagnostics… depends on. A Release build compiles those lines out, and a tester's
#  diagnostics file would carry the connection lifecycle and nothing else — enough to debug
#  "won't connect", useless for "judders on my machine". Release is for the public build.
#
#  ⚠️ THE SCHEME'S ARCHIVE ACTION IS PINNED TO Release (project.yml, schemes.Manifold.archive).
#  `-configuration` on the command line overrides it, which is what happens below — but that
#  also means Product ▸ Archive IN XCODE SILENTLY GIVES YOU Release. Do not cut a tester build
#  from the GUI. Because the override is a claim rather than a guarantee, step 6 MEASURES the
#  resulting binary instead of trusting the flag.
#
#  ── WHY THE OUTPUT LIVES OUTSIDE THE REPO ──────────────────────────────────────────────
#
#  The repo is under ~/Nextcloud, and Nextcloud's chunked upload has a documented history of
#  corrupting large files on the sibling products. Manifold's DMG is ~6-9 MB so it is very
#  probably under the threshold — but "probably" is not a reason to sync build output at all,
#  so everything lands in ~/Builds/Manifold by default. If you ever point MANIFOLD_DIST_DIR
#  back inside the Nextcloud tree, exclude it from sync first.
#
#  ── THE FAILURE MODE THIS SCRIPT IS BUILT AROUND ───────────────────────────────────────
#
#  On the sibling products, notarization SILENTLY SKIPPED while the build reported success —
#  producing a DMG that looked fine locally and was refused on every other machine. Exit codes
#  alone did not catch it. So every consequential step here asserts its OUTCOME, not its status:
#  the signing authority is read back, the hardened-runtime flag is read back, the notarization
#  verdict is parsed out of notarytool's JSON and required to be literally "Accepted", the
#  submission id is required to be non-empty, and the stapled ticket is validated afterwards.
#  If notarization fails, `xcrun notarytool log` is fetched and printed in full, because
#  "Invalid" with no detail tells you nothing.
#

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════════════════════

CONFIG=""
DO_UPLOAD=1

usage() {
    cat <<'USAGE'
Usage: scripts/release-mac.sh [Profile|Release] [--no-upload]

  Profile      tester build — telemetry compiled in (DEFAULT)
  Release      public build — per-second telemetry compiled out
  --no-upload  build, sign, notarize, staple and verify, but do NOT publish

Environment:
  MANIFOLD_DIST_DIR       where artefacts are written (default: ~/Builds/Manifold)
  GRAVITON_RELEASES_DIR   the Graviton-Releases checkout holding the shared uploader.
                          Default: searched for by walking up from the repo root.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        Profile|Release) CONFIG="$arg" ;;
        --no-upload)     DO_UPLOAD=0 ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; echo >&2; echo "unknown argument: ${arg}" >&2; exit 2 ;;
    esac
done
CONFIG="${CONFIG:-Profile}"

TEAM_ID="8UQ7MDM87B"
IDENTITY="Developer ID Application: Amigo Media LLC (${TEAM_ID})"
NOTARY_PROFILE="graviton-notarytool"
SCHEME="Manifold"
APP_NAME="Manifold"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_YML="${REPO_ROOT}/project.yml"
XCODEPROJ="${REPO_ROOT}/${SCHEME}.xcodeproj"

DIST_DIR="${MANIFOLD_DIST_DIR:-${HOME}/Builds/Manifold}"
# The export options plist is tiny and belongs with the project, per spec. build/ is gitignored.
EXPORT_PLIST="${REPO_ROOT}/build/ExportOptions.plist"

# ── Publishing ─────────────────────────────────────────────────────────────────────────────
# The uploader is SHARED across Graviton products and lives in its own repo, so the R2 layout,
# archive paths and manifest shape have one definition rather than one per product.
PRODUCT_SLUG="manifold"
RELEASES_BASE="https://releases.graviton.tools"
NOTES_FILE="${REPO_ROOT}/RELEASE_NOTES.md"

# ── LOCATING THE SHARED UPLOADER ────────────────────────────────────────────────────────
# This was once a fixed `${REPO_ROOT}/../..`, which silently encoded how deep this repo
# happened to sit under the directory holding Graviton-Releases. Moving the repo one level
# in either direction breaks that with no warning until publish time. So: an explicit env
# override first, then a walk UP the tree looking for the checkout. Every path considered is
# recorded, because the only useful failure message here is the list of places we looked.
UPLOAD_SCRIPT=""
UPLOAD_SCRIPT_SOURCE=""
UPLOAD_SEARCH_TRAIL=()

if [[ -n "${GRAVITON_RELEASES_DIR:-}" ]]; then
    # Explicit override wins outright and is NOT backfilled by the search — if it is set and
    # wrong, saying so beats quietly publishing through a different checkout than intended.
    _cand="${GRAVITON_RELEASES_DIR%/}/upload-release.sh"
    UPLOAD_SEARCH_TRAIL+=("${_cand}   (GRAVITON_RELEASES_DIR)")
    if [[ -f "$_cand" ]]; then
        UPLOAD_SCRIPT="$_cand"
        UPLOAD_SCRIPT_SOURCE="GRAVITON_RELEASES_DIR"
    fi
    unset _cand
else
    # Walk up from the repo root. Terminates at / — `dirname /` is /, so the explicit break
    # is what ends the loop, not the path shrinking.
    _dir="$REPO_ROOT"
    while : ; do
        # %/ so the final iteration reads /Graviton-Releases and not //Graviton-Releases.
        _cand="${_dir%/}/Graviton-Releases/upload-release.sh"
        UPLOAD_SEARCH_TRAIL+=("$_cand")
        if [[ -f "$_cand" ]]; then
            UPLOAD_SCRIPT="$_cand"
            UPLOAD_SCRIPT_SOURCE="found by upward search from the repo root"
            break
        fi
        [[ "$_dir" == "/" ]] && break
        _dir="$(dirname "$_dir")"
    done
    unset _dir _cand
fi

# Left non-empty even on failure so the preflight message below can name a concrete path
# rather than an empty string. Nothing reads it unless the -f test at preflight passes.
UPLOAD_SCRIPT="${UPLOAD_SCRIPT:-<not found>}"

# ══════════════════════════════════════════════════════════════════════════════════════════
# Output helpers
# ══════════════════════════════════════════════════════════════════════════════════════════

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s══ %d. %s ══%s\n' "$BOLD" "$STEP" "$1" "$RESET"; }
ok()   { printf '   %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '   %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
die()  { printf '\n%s✗ FAILED: %s%s\n\n' "$RED" "$1" "$RESET" >&2; exit 1; }

# Collected for the final report so every verification result is printed together at the end.
RESULTS=()
record() { RESULTS+=("$1"); }

# ── ⚠️ ASSERT SUBSTRINGS WITH THIS, NEVER WITH `producer | grep -q`. ────────────────────
#
# THIS FUNCTION EXISTS BECAUSE THAT PATTERN COST A FALSE RELEASE FAILURE, and the failure
# accused a perfectly good artefact of being unsigned.
#
#     codesign -dvv "$DMG" 2>&1 | grep -qF "Authority=..."     # <-- DO NOT
#
# `grep -q` exits the instant it matches. The Authority line is 6th of codesign's 13, so grep
# closes the pipe with 7 lines still to come. codesign writes to STDERR, which is UNBUFFERED —
# every line is its own write() — so the next one lands on a closed pipe and codesign dies of
# SIGPIPE (141). `set -o pipefail` then takes the pipeline's status from the FAILED stage, so a
# SUCCESSFUL match reports failure. Measured on the real DMG:
#
#     PIPESTATUS=(141 0)   pipeline status = 141      <- grep matched; codesign was killed
#
# It is silent on small outputs — `security find-identity | grep -q` survives only because its
# producer buffers everything into one write and exits before grep can close the pipe. That is
# luck, not design, and it evaporates the moment a producer writes more than a pipe buffer.
#
# `case` is a shell builtin: no subprocess, no pipe, no SIGPIPE, and nothing for pipefail to
# misread. The needle is quoted so it is matched LITERALLY and cannot act as a glob.
contains() {   # contains <needle> <haystack>
    case "$2" in
        (*"$1"*) return 0 ;;
        (*)      return 1 ;;
    esac
}

# Case-insensitive variant, for tool output whose capitalisation is not contractual.
# `tr` reads to EOF and never exits early, so this command substitution is SIGPIPE-safe.
contains_nocase() {   # contains_nocase <lowercase-needle> <haystack>
    local lowered
    lowered=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    contains "$1" "$lowered"
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# 0. Preflight — everything that must exist before a single byte is compiled
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Preflight"

case "$CONFIG" in
    Profile|Release) ;;
    *) die "unknown configuration '${CONFIG}' — use Profile (tester) or Release (public)" ;;
esac
ok "configuration: ${CONFIG}"

[[ -f "$PROJECT_YML" ]] || die "project.yml not found at ${PROJECT_YML}"

for tool in xcodegen xcodebuild create-dmg codesign hdiutil python3; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: ${tool}"
done
xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found in the active Xcode"
xcrun --find stapler    >/dev/null 2>&1 || die "stapler not found in the active Xcode"
# `awk NR==1` and not `head -1`: head exits after the first line and SIGPIPEs xcodebuild. See
# the note on `contains` — this is the same hazard, and awk reads to EOF.
ok "toolchain present (Xcode $(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}'))"

# The signing identity. Checked HERE and not at signing time, because discovering it is missing
# after a 3-minute archive is a waste of three minutes.
IDENTITY_LIST=$(security find-identity -v -p codesigning 2>/dev/null || true)
contains "$IDENTITY" "$IDENTITY_LIST" \
    || die "signing identity not found in any keychain: ${IDENTITY}
       Identities available:
$(printf '%s\n' "$IDENTITY_LIST" | sed 's/^/         /')"
ok "signing identity found"

# The notarization credentials. Same reasoning, and this is the step that silently no-ops on a
# misconfigured profile — so it is exercised before anything expensive happens.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool keychain profile '${NOTARY_PROFILE}' is missing or invalid.
       Recreate with:
         xcrun notarytool store-credentials ${NOTARY_PROFILE} \\
           --apple-id <apple-id> --team-id ${TEAM_ID} --password <app-specific-password>"
ok "notarytool profile '${NOTARY_PROFILE}' authenticates"

# ── PUBLISHING PREREQUISITES, checked now rather than after notarization ────────────────
# Everything below is only reachable at step 13, several minutes and one Apple round trip
# later. Finding out then that the uploader is missing wastes the whole run.
if [[ $DO_UPLOAD -eq 1 ]]; then
    [[ -f "$UPLOAD_SCRIPT" ]] \
        || die "shared uploader (upload-release.sh) not found.
       Looked for a Graviton-Releases checkout at, in order:
$(printf '%s\n' "${UPLOAD_SEARCH_TRAIL[@]}" | sed 's/^/         /')
       Fix by either:
         - cloning github.com/DCColor/Graviton-Releases somewhere above this repo, or
         - pointing at an existing checkout:
             GRAVITON_RELEASES_DIR=/path/to/Graviton-Releases $0 ${CONFIG}
       Build without publishing with:  $0 ${CONFIG} --no-upload"
    for tool in wrangler curl; do
        command -v "$tool" >/dev/null 2>&1 || die "required for publishing but not on PATH: ${tool}"
    done
    ok "publishing enabled — uploader at ${UPLOAD_SCRIPT} (${UPLOAD_SCRIPT_SOURCE})"

    # Notes are optional by design (the uploader warns rather than failing), but saying so HERE
    # rather than at step 13 gives a chance to write them before the build runs.
    if [[ ! -f "$NOTES_FILE" ]]; then
        warn "no RELEASE_NOTES.md — the release will publish with an empty notes array"
    fi
else
    ok "publishing DISABLED (--no-upload)"
fi

# ── BUILD INPUTS THAT ARE GITIGNORED, and therefore absent on a fresh clone. Each of these
#    fails deep inside xcodebuild with an error that does not name the real cause.
[[ -d "${REPO_ROOT}/docs/BlackmagicDeckLinkSDK16.0/Mac/include" ]] \
    || die "DeckLink SDK missing: docs/BlackmagicDeckLinkSDK16.0/Mac/include
       It is gitignored — copy it in from the Blackmagic Desktop Video SDK 16.0."
[[ -d "/Library/NDI SDK for Apple/include" ]] \
    || die "NDI SDK headers missing: /Library/NDI SDK for Apple/include
       Install the NDI SDK for Apple (headers only are needed; the runtime is dlopen'd)."
# ⚠️ THE PATTERN IS PER-LIBRARY, AND ffmpeg IS THE ODD ONE OUT. It ships as SHARED libraries
# (*.dylib) for LGPL 2.1 §6 — a user must be able to relink Manifold against a modified FFmpeg,
# which static archives make impossible. libsrt and libdatachannel are still static (*.a).
# A single "*.a" loop here would now fail on ffmpeg and kill every release at preflight, with a
# message telling you to rebuild static libs that must not exist. See ThirdParty/ffmpeg/README.md.
for spec in "ffmpeg:*.dylib" "libsrt:*.a" "libdatachannel:*.a"; do
    lib="${spec%%:*}"; pat="${spec##*:}"
    compgen -G "${REPO_ROOT}/ThirdParty/${lib}/lib/${pat}" >/dev/null \
        || die "vendored libs missing: ThirdParty/${lib}/lib/${pat}
       They are gitignored — rebuild with scripts/build_${lib}.sh (see ThirdParty/${lib}/README.md)."
done
# And the inverse, for ffmpeg only: a leftover archive from before the shared migration would
# be picked up by neither check above, while `-lavcodec` silently prefers the .dylib beside it.
# The danger is not a broken build — it is a build that looks fine and is not §6-compliant.
# (Written as an `if` rather than `compgen … && die`. That form does survive `set -e` here —
# a failure inside a && list is exempt — but this script is written not to depend on shell
# subtleties, and a negative assertion is the last place to start.)
if compgen -G "${REPO_ROOT}/ThirdParty/ffmpeg/lib/*.a" >/dev/null; then
    die "STALE STATIC ARCHIVES in ThirdParty/ffmpeg/lib — these predate the LGPL §6 shared
       migration and must not be shipped. Re-stage with scripts/build_ffmpeg.sh, which purges
       the directory before installing."
fi
ok "gitignored build inputs present (DeckLink SDK, NDI headers, 3 vendored lib trees)"

# ── LGPL §6: THE ABOUT PANEL MAKES A WRITTEN OFFER, AND AN OFFER MUST BE ACTIONABLE ──────
#
# App/AboutWindow.swift offers, in the shipped binary, to supply FFmpeg's corresponding source
# and names both a URL and a contact address. Neither can be checked by the compiler, and both
# fail in the same silent way: the app ships, the notice looks complete, and the offer is void.
# So both are asserted here, before anything is built.
ABOUT_SWIFT="${REPO_ROOT}/App/AboutWindow.swift"
[[ -f "$ABOUT_SWIFT" ]] || die "App/AboutWindow.swift not found — the §6 notice lives there"

# (1) The contact address must be a real one.
#
# ⚠️ THIS PARSES THE ASSIGNED VALUE, NOT THE FILE. An earlier version grepped the whole file for
# the placeholder marker and consequently failed on the DOC COMMENT that explains the placeholder
# — a check that forbids describing itself. Worse, the obvious "fix" for that is to delete the
# comment, which trades a real explanation for a green check. So: extract the string literal and
# assert about the VALUE.
LICENSING_CONTACT=$(sed -nE 's/^[[:space:]]*static let licensingContact[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$ABOUT_SWIFT")
[[ -n "$LICENSING_CONTACT" ]] \
    || die "could not read Attributions.licensingContact from App/AboutWindow.swift.
       The declaration moved or changed shape — this check greps for
         static let licensingContact = \"…\"
       Fix the check rather than removing it: it is the only thing standing between a typo and
       a shipped LGPL §6 offer that nobody can act on."

# .invalid and .example are RFC 2606 reserved and can never be real domains, so an address using
# either is unusable by construction — which is exactly why the placeholder uses one.
case "$LICENSING_CONTACT" in
    *SET-BEFORE-RELEASE*|*.invalid|*.example|*example.com)
        die "the LGPL §6 written offer carries a PLACEHOLDER contact address: ${LICENSING_CONTACT}
       App/AboutWindow.swift → Attributions.licensingContact
       An offer naming an address nobody reads is not an offer, and this build would ship that
       claim to every user, permanently. Set a monitored mailbox — one that will still be
       monitored in three years, which is how long §6(c) binds us — and re-run." ;;
esac
[[ "$LICENSING_CONTACT" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
    || die "Attributions.licensingContact is not a valid email address: ${LICENSING_CONTACT}"
ok "LGPL §6 contact address is set (${LICENSING_CONTACT})"

# (2) The published-source URL in the app must match the one derived from the FFmpeg pin.
#     build_ffmpeg.sh owns the pin; AboutWindow.swift holds a copy for display. A stale copy
#     would have the app offer source at a URL that was never uploaded.
PIN_INFO=$( "${REPO_ROOT}/scripts/build_ffmpeg.sh" --source-info ) \
    || die "could not read the FFmpeg source pin from scripts/build_ffmpeg.sh"
eval "$PIN_INFO"
if ! contains "$SOURCE_URL" "$(cat "$ABOUT_SWIFT")"; then
    ABOUT_URL=$(grep -oE 'https://releases\.graviton\.tools/manifold/source/[^"]*' "$ABOUT_SWIFT" | head -1)
    die "the source URL in the About panel does not match the FFmpeg pin.
       AboutWindow.swift says : ${ABOUT_URL:-<none found>}
       the pin derives        : ${SOURCE_URL}
       The pin moved and Attributions.ffmpegSourceURL was not updated with it. Fix the literal
       in App/AboutWindow.swift — build_ffmpeg.sh is the source of truth, not this copy."
fi
ok "About panel source URL matches the pin (${SOURCE_FILENAME})"

mkdir -p "$DIST_DIR" "${REPO_ROOT}/build"
case "$DIST_DIR" in
    *Nextcloud*) warn "MANIFOLD_DIST_DIR is inside Nextcloud — exclude it from sync or the DMG may corrupt" ;;
esac
ok "output directory: ${DIST_DIR}"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 1. Read MARKETING_VERSION
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Read version from project.yml"

# ⚠️ project.yml IS THE ONLY SOURCE OF TRUTH FOR THE VERSION. App/Info.generated.plist also
# carries a CFBundleShortVersionString, but it is an XcodeGen output holding XcodeGen's default
# of 1.0, and GENERATE_INFOPLIST_FILE=YES makes the BUILD SETTING win. Editing that plist looks
# like it works and changes nothing. Verified against a built Info.plist, not assumed.
#
# The regex anchors on start-of-line so the explanatory comment above the setting — which also
# contains the words MARKETING_VERSION — cannot match.
version_matches=$(grep -cE '^[[:space:]]*MARKETING_VERSION:' "$PROJECT_YML" || true)
[[ "$version_matches" == "1" ]] \
    || die "expected exactly 1 MARKETING_VERSION line in project.yml, found ${version_matches}"

VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$PROJECT_YML")
[[ -n "$VERSION" ]] || die "could not parse MARKETING_VERSION from project.yml"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || die "MARKETING_VERSION '${VERSION}' does not look like a version number"
ok "version ${VERSION}"
record "version:                 ${VERSION}"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 2. Bump CURRENT_PROJECT_VERSION
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Bump build number"

# ⚠️ WHY THIS IS PERSISTED TO project.yml RATHER THAN PASSED ON THE xcodebuild COMMAND LINE.
# CFBundleVersion is what macOS (and Sparkle, and TestFlight-shaped flows) use to decide "is
# this build newer" — CFBundleShortVersionString is a display string and is not compared. A
# build number supplied only at build time would never advance in the repo, so the next release
# would compute the same value and an in-place upgrade would not be recognised as an upgrade.
#
# THIS EDIT REQUIRES THE xcodegen RUN IN STEP 3 TO TAKE EFFECT: project.yml is the source and
# the .xcodeproj is a generated artifact, so the new number does not reach the build until the
# project is regenerated. Step 3 runs unconditionally, so the ordering here is what makes it safe.
build_matches=$(grep -cE '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$PROJECT_YML" || true)
[[ "$build_matches" == "1" ]] \
    || die "expected exactly 1 CURRENT_PROJECT_VERSION line in project.yml, found ${build_matches}"

OLD_BUILD=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?[[:space:]]*$/\1/p' "$PROJECT_YML")
[[ -n "$OLD_BUILD" ]] || die "could not parse CURRENT_PROJECT_VERSION from project.yml"
NEW_BUILD=$((OLD_BUILD + 1))

sed -i '' -E "s|^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)\"?[0-9]+\"?[[:space:]]*\$|\1\"${NEW_BUILD}\"|" "$PROJECT_YML"

# Read it back. A sed that matched nothing exits 0 and changes nothing — the silent-success
# failure mode this whole script is written against.
CHECK_BUILD=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?[[:space:]]*$/\1/p' "$PROJECT_YML")
[[ "$CHECK_BUILD" == "$NEW_BUILD" ]] \
    || die "build-number bump did not take: project.yml still reads '${CHECK_BUILD}', expected '${NEW_BUILD}'"
ok "build ${OLD_BUILD} → ${NEW_BUILD} (written to project.yml — commit this)"
record "build number:            ${NEW_BUILD} (was ${OLD_BUILD})"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 3. Regenerate the Xcode project
# ══════════════════════════════════════════════════════════════════════════════════════════

step "xcodegen generate"

( cd "$REPO_ROOT" && xcodegen generate ) || die "xcodegen failed"
[[ -d "$XCODEPROJ" ]] || die "xcodegen reported success but ${XCODEPROJ} does not exist"
ok "project regenerated"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 4. Archive
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Archive (${CONFIG}, arm64)"

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${DIST_DIR}/${VERSION}-${NEW_BUILD}-${CONFIG}-${STAMP}"
ARCHIVE_PATH="${RUN_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${RUN_DIR}/export"
STAGE_DIR="${RUN_DIR}/dmg-stage"
LOG_DIR="${RUN_DIR}/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR"

# ARCHS/ONLY_ACTIVE_ARCH are pinned on the command line as well as in project.yml: this app is
# Apple-Silicon-only (Float16 pixel paths do not compile for x86_64), and an archive that
# quietly picked up a universal setting would fail late and confusingly.
set +e
xcodebuild archive \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    > "${LOG_DIR}/archive.log" 2>&1
archive_status=$?
set -e
if [[ $archive_status -ne 0 ]]; then
    tail -60 "${LOG_DIR}/archive.log" >&2
    die "xcodebuild archive failed (status ${archive_status}) — full log: ${LOG_DIR}/archive.log"
fi

ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
[[ -d "$ARCHIVED_APP" ]] || die "archive succeeded but contains no app at ${ARCHIVED_APP}"
ok "archived → ${ARCHIVE_PATH}"

# ── ASSERT THE VERSION ACTUALLY LANDED IN THE BUNDLE ───────────────────────────────────
# Reading the BUILT plist, not project.yml, for the reason recorded at step 1.
ARCHIVED_PLIST="${ARCHIVED_APP}/Contents/Info.plist"
GOT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ARCHIVED_PLIST")
GOT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$ARCHIVED_PLIST")
[[ "$GOT_VERSION" == "$VERSION" ]] \
    || die "built CFBundleShortVersionString is '${GOT_VERSION}', expected '${VERSION}'"
[[ "$GOT_BUILD" == "$NEW_BUILD" ]] \
    || die "built CFBundleVersion is '${GOT_BUILD}', expected '${NEW_BUILD}' — did xcodegen run?"
ok "bundle reads ${GOT_VERSION} (build ${GOT_BUILD})"
record "CFBundleShortVersionString: ${GOT_VERSION}"
record "CFBundleVersion:            ${GOT_BUILD}"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 5. Export with Developer ID
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Export archive (Developer ID)"

if [[ ! -f "$EXPORT_PLIST" ]]; then
    cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST
    ok "created ${EXPORT_PLIST}"
else
    ok "using existing ${EXPORT_PLIST}"
fi

set +e
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    > "${LOG_DIR}/export.log" 2>&1
export_status=$?
set -e
if [[ $export_status -ne 0 ]]; then
    tail -60 "${LOG_DIR}/export.log" >&2
    die "xcodebuild -exportArchive failed (status ${export_status}) — full log: ${LOG_DIR}/export.log"
fi

APP="${EXPORT_DIR}/${APP_NAME}.app"
[[ -d "$APP" ]] || die "export succeeded but no app at ${APP}"
APP_SIZE=$(du -sh "$APP" | awk '{print $1}')
ok "exported → ${APP} (${APP_SIZE})"
record "app size:                ${APP_SIZE}"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 6. Verify the app
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Verify the app"

set +e
CS_VERIFY=$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)
cs_status=$?
set -e
printf '%s\n' "$CS_VERIFY" | sed 's/^/       /'
[[ $cs_status -eq 0 ]] || die "codesign --verify --deep --strict failed"
ok "codesign --verify --deep --strict passed"
record "codesign --verify:       passed (deep, strict)"

CS_INFO=$(codesign -dvv "$APP" 2>&1)
printf '%s\n' "$CS_INFO" | sed 's/^/       /'

# ── ASSERT THE AUTHORITY. CODE_SIGN_STYLE is Automatic, so the ARCHIVE may carry an "Apple
#    Development" signature and -exportArchive re-signs with Developer ID. Assert the outcome
#    rather than assume the re-sign happened: an Apple Development signature notarizes as
#    Invalid and, worse, launches fine on this machine.
contains "Authority=${IDENTITY}" "$CS_INFO" \
    || die "app is NOT signed with '${IDENTITY}'.
       Authorities found:
$(printf '%s\n' "$CS_INFO" | grep '^Authority=' | sed 's/^/         /')"
ok "signed by ${IDENTITY}"
record "signing authority:       ${IDENTITY}"

# ── ASSERT HARDENED RUNTIME. Notarization requires it; project.yml sets it, but a setting is
#    a claim and the signature is the fact.
# `=~` is a bash builtin test, so this is a regex match with no pipeline. The pattern is the
# same one the pipeline used: the `runtime` flag inside codesign's `flags=0x…(…)` field, not
# the word "runtime" appearing anywhere in the output.
[[ "$CS_INFO" =~ flags=[^[:space:]]*runtime ]] \
    || die "hardened runtime is NOT enabled on the signed app — notarization would be rejected.
       codesign reported:
$(printf '%s\n' "$CS_INFO" | grep -i 'flags=' | sed 's/^/         /')"
ok "hardened runtime enabled"
record "hardened runtime:        enabled"

# ── ASSERT ENTITLEMENTS: the one we need present, the one that must never ship absent.
codesign -d --entitlements - --xml "$APP" > "${LOG_DIR}/entitlements.plist" 2>/dev/null \
    || codesign -d --entitlements - "$APP" > "${LOG_DIR}/entitlements.plist" 2>/dev/null || true
if grep -q 'com.apple.security.cs.disable-library-validation' "${LOG_DIR}/entitlements.plist"; then
    ok "disable-library-validation present (required: dlopen of libndi, CFBundle load of DeckLinkAPI)"
    record "library-validation:      disabled (required for NDI + DeckLink)"
else
    die "com.apple.security.cs.disable-library-validation is MISSING from the signed app.
       NDI and DeckLink would fail to load in the signed build only — see App/Manifold.entitlements."
fi
if grep -q 'com.apple.security.get-task-allow' "${LOG_DIR}/entitlements.plist"; then
    die "com.apple.security.get-task-allow is PRESENT in the signed app.
       That is the debug entitlement and notarization will reject it. The archive was probably
       cut from a debug-type configuration."
fi
ok "get-task-allow absent (would be an automatic notarization rejection)"
record "get-task-allow:          absent (correct)"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 6b. The embedded libav dylibs
# ══════════════════════════════════════════════════════════════════════════════════════════
#
# ⚠️ WHY THIS BLOCK EXISTS. Manifold ships FFmpeg as SHARED libraries so a user can relink the
# app against a modified FFmpeg (LGPL 2.1 §6 — see ThirdParty/ffmpeg/README.md). That moved five
# Mach-Os out of the app binary and into Contents/Frameworks, and every one of them is now
# separately signed code that Apple inspects.
#
# Two failure modes, both invisible on this machine:
#   * An UNSIGNED or wrongly-signed nested dylib notarizes as Invalid. The app runs fine locally.
#   * A dylib whose install_name is an ABSOLUTE build-tree path resolves here (the path exists)
#     and fails to launch on every other machine. Neither codesign nor notarization catches it.
# So both are asserted on the exported bundle, before the DMG is built.

step "Verify the embedded libav dylibs"

FRAMEWORKS_DIR="${APP}/Contents/Frameworks"
[[ -d "$FRAMEWORKS_DIR" ]] || die "no ${FRAMEWORKS_DIR}.
       The libav dylibs are not embedded. Check the dependencies: block in project.yml
       (embed: true / codeSign: true) and that xcodegen ran."

# The exact five, by their major-suffixed names — the names baked into their install_names.
EXPECTED_DYLIBS=(libavcodec.62.dylib libavformat.62.dylib libavutil.60.dylib
                 libswscale.9.dylib libswresample.6.dylib)

for dylib in "${EXPECTED_DYLIBS[@]}"; do
    [[ -f "${FRAMEWORKS_DIR}/${dylib}" ]] \
        || die "missing from the bundle: Contents/Frameworks/${dylib}"
done

# Nothing MORE than the five, either. An unexpected dylib here is either a second copy of the
# same image under a different name (the unsuffixed link-time symlink is a standing candidate)
# or something that has no business shipping.
FOUND_DYLIBS=$(cd "$FRAMEWORKS_DIR" && ls -1 | sort)
WANT_DYLIBS=$(printf '%s\n' "${EXPECTED_DYLIBS[@]}" | sort)
if [[ "$FOUND_DYLIBS" != "$WANT_DYLIBS" ]]; then
    die "Contents/Frameworks does not hold exactly the five expected dylibs.
       found:
$(printf '%s\n' "$FOUND_DYLIBS" | sed 's/^/         /')
       expected:
$(printf '%s\n' "$WANT_DYLIBS" | sed 's/^/         /')"
fi
ok "exactly the 5 expected libav dylibs are embedded"

for dylib in "${EXPECTED_DYLIBS[@]}"; do
    DYLIB_PATH="${FRAMEWORKS_DIR}/${dylib}"

    # ── install_name must be @rpath-relative. `otool -D` prints the path on line 2.
    DYLIB_ID=$(otool -D "$DYLIB_PATH" | awk 'NR==2')
    [[ "$DYLIB_ID" == "@rpath/${dylib}" ]] \
        || die "${dylib} has install_name '${DYLIB_ID}', expected '@rpath/${dylib}'.
       An absolute install_name WORKS ON THIS MACHINE and on no other. Rebuild with
       scripts/build_ffmpeg.sh (--install-name-dir=@rpath)."

    # ── No dependency may name a build tree or a Homebrew prefix.
    DYLIB_DEPS=$(otool -L "$DYLIB_PATH" | tail -n +2)
    if [[ "$DYLIB_DEPS" =~ (/Users/|/opt/homebrew|/usr/local/lib) ]]; then
        die "${dylib} depends on a path outside the bundle and the system:
$(printf '%s\n' "$DYLIB_DEPS" | grep -E '/Users/|/opt/homebrew|/usr/local/lib' | sed 's/^/         /')"
    fi

    # ── Signed, with Developer ID, hardened runtime, and a secure timestamp. Captured then
    #    asserted — never `codesign … | grep -q`, for the SIGPIPE reason documented at `contains`.
    DYLIB_CS=$(codesign -dvv "$DYLIB_PATH" 2>&1)
    contains "Authority=${IDENTITY}" "$DYLIB_CS" \
        || die "${dylib} is NOT signed with '${IDENTITY}'.
       Notarization would return Invalid for unsigned nested code, while the app runs fine here.
       Authorities found:
$(printf '%s\n' "$DYLIB_CS" | grep '^Authority=' | sed 's/^/         /')
       (if that list is empty, the dylib is unsigned — check codeSign: true in project.yml)"
    [[ "$DYLIB_CS" =~ flags=[^[:space:]]*runtime ]] \
        || die "${dylib} is signed WITHOUT hardened runtime — notarization would reject it."
    contains "Timestamp=" "$DYLIB_CS" \
        || die "${dylib} is signed without a secure timestamp — notarization requires one."

    ok "${dylib}: @rpath id, Developer ID, hardened runtime, timestamped"
done
record "embedded libav dylibs:   5, all @rpath + signed + hardened + timestamped"

# ── The main binary must reference them the same way ────────────────────────────────────
MAIN_DEPS=$(otool -L "${APP}/Contents/MacOS/${APP_NAME}")
MAIN_LIBAV=$(printf '%s\n' "$MAIN_DEPS" | grep -E 'lib(avcodec|avformat|avutil|swscale|swresample)' || true)
[[ -n "$MAIN_LIBAV" ]] \
    || die "the app binary references NO libav dylib. It was linked statically — which is the
       state LGPL §6 compliance requires us NOT to ship. Check OTHER_LDFLAGS and that
       ThirdParty/ffmpeg/lib holds dylibs, not archives."
# Here-string, NOT a pipe into `grep -q`. See the note on `contains`: grep -q exits at the first
# match and SIGPIPEs its producer, which pipefail then reports as the pipeline's status — so the
# check fails precisely because it found something. A here-string is not a pipeline.
MAIN_NON_RPATH=$(grep -vF '@rpath/' <<<"$MAIN_LIBAV" || true)
[[ -z "$MAIN_NON_RPATH" ]] \
    || die "the app binary has a non-@rpath libav reference:
$(printf '%s\n' "$MAIN_NON_RPATH" | sed 's/^/         /')"
ok "app binary references all libav via @rpath ($(printf '%s\n' "$MAIN_LIBAV" | wc -l | tr -d ' ') entries)"

# ── …and carry the rpath that resolves them.
# `otool -l` on this binary emits thousands of lines, so it is CAPTURED ONCE and then matched.
# `otool -l … | grep -A2 LC_RPATH | grep -q …` is the textbook form of the SIGPIPE bug above:
# the second grep exits on the first hit, otool dies of SIGPIPE mid-write, and a correct app is
# reported as missing its rpath. awk reads to EOF, so the capture itself is safe.
MAIN_LOAD_CMDS=$(otool -l "${APP}/Contents/MacOS/${APP_NAME}")
MAIN_RPATHS=$(awk '/LC_RPATH/{f=1} f && / path /{print $2; f=0}' <<<"$MAIN_LOAD_CMDS")
contains '@executable_path/../Frameworks' "$MAIN_RPATHS" \
    || die "LC_RPATH @executable_path/../Frameworks is MISSING — the embedded dylibs cannot be
       found at launch. Check LD_RUNPATH_SEARCH_PATHS in project.yml.
       LC_RPATHs found:
$(printf '%s\n' "${MAIN_RPATHS:-<none>}" | sed 's/^/         /')"
ok "LC_RPATH @executable_path/../Frameworks present"
record "libav linkage:           @rpath + LC_RPATH ../Frameworks (relocatable)"

# ── ASSERT THE CONFIGURATION ACTUALLY TOOK ──────────────────────────────────────────────
# The scheme pins its archive action to Release and we override with -configuration. Rather
# than trust that, measure the property we actually care about: Profile defines DEBUG, so the
# `#if DEBUG || MANIFOLD_TELEMETRY` rollups are compiled IN; Release compiles them OUT.
# Measured: [SRT-FLOW] appears in a DEBUG-defining binary and not in a Release one.
# Scans any sibling dylib too, in case a future Xcode splits the binary as it does for Debug.
TELEMETRY_HITS=0
while IFS= read -r macho; do
    hits=$(strings -a "$macho" 2>/dev/null | grep -cF '[SRT-FLOW]' || true)
    TELEMETRY_HITS=$((TELEMETRY_HITS + hits))
done < <(find "${APP}/Contents/MacOS" -type f)

if [[ "$CONFIG" == "Profile" ]]; then
    [[ "$TELEMETRY_HITS" -gt 0 ]] || die "this is a Profile build but the telemetry lines are NOT in the
       binary ([SRT-FLOW] not found). The -configuration override did not take, and a tester's
       diagnostics export would be missing every per-second rollup. Check schemes.Manifold.archive."
    ok "telemetry present (${TELEMETRY_HITS} marker(s)) — diagnostics export will be complete"
    record "telemetry rollups:       PRESENT (correct for a tester build)"
else
    [[ "$TELEMETRY_HITS" -eq 0 ]] || die "this is a Release build but telemetry markers ARE present
       (${TELEMETRY_HITS}). DEBUG is defined in a build that should not have it."
    ok "telemetry absent — correct for Release"
    record "telemetry rollups:       absent (correct for Release)"
fi

# ══════════════════════════════════════════════════════════════════════════════════════════
# 7. Build the DMG
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Build DMG"

# create-dmg images the ENTIRE source folder, and the export directory also holds
# DistributionSummary.plist / Packaging.log / ExportOptions.plist. Stage a directory that
# contains the app and nothing else.
rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"
cp -R "$APP" "${STAGE_DIR}/"

DMG="${RUN_DIR}/${APP_NAME}-${VERSION}-${NEW_BUILD}-${CONFIG}.dmg"
rm -f "$DMG"

# ── THE VOLUME ICON ────────────────────────────────────────────────────────────────────
#
# Without this the mounted volume, and the .dmg file itself, carry the generic white disk
# icon: the one thing a user sees before they have installed anything looks like it came
# from nobody. `--volicon` writes the image to `.VolumeIcon.icns` at the volume root and
# sets the volume's custom-icon bit.
#
# SOURCED FROM THE BUILT APP, NOT A COPY IN THE REPO. `Contents/Resources/AppIcon.icns` is
# what Xcode compiled from App/Assets.xcassets/AppIcon.appiconset for THIS build, so the
# volume icon cannot drift from the app icon — there is no second asset to forget to
# update. Format is `.icns`; create-dmg takes nothing else.
#
# ASSERTED, NOT ASSUMED. If Xcode ever renames the output or the asset catalog loses its
# AppIcon set, a missing file would otherwise mean silently shipping the generic icon again
# — the exact defect this removes, and invisible in a log nobody reads.
VOLICON="${STAGE_DIR}/${APP_NAME}.app/Contents/Resources/AppIcon.icns"
[[ -f "$VOLICON" ]] || die "volume icon not found at ${VOLICON}
       The DMG would ship with the generic disk icon. Check that the AppIcon set is still
       present in App/Assets.xcassets and that Xcode emitted AppIcon.icns."
ok "volume icon: $(basename "$VOLICON") ($(stat -f%z "$VOLICON") bytes)"

# ── THE WINDOW'S COORDINATE SYSTEM, MEASURED ───────────────────────────────────────────
#
# create-dmg's own help says only "set position of the file's icon", which leaves the two
# questions that actually matter unanswered. Both were settled by cutting an image, mounting
# it, and measuring the rendered window rather than by reading the flag names:
#
#   * `--window-size 540 380` is the CONTENT rect, not the outer frame. Finder reports the
#     mounted window's bounds as 200,120 → 740,500 — exactly 540 × 380 — so the title bar is
#     additional and nothing has to be subtracted from these numbers.
#
#   * `--icon <name> <x> <y>` and `--app-drop-link <x> <y>` position the icon's CENTRE, NOT
#     its top-left corner, in points, in that content rect, with y measured DOWNWARD from the
#     top. Measured on the built image: the app glyph's horizontal centre lands at x = 140 for
#     a specified 140, and the Applications alias at 399 for a specified 400. Vertically the
#     glyph centre sits at ~194 for a specified 190; the ~4 pt is transparent padding in the
#     icon art, not an offset in the coordinate system.
#
# WHICH IS WHY THESE PARTICULAR NUMBERS ARE RIGHT, and they are not arbitrary:
#     y = 190  is the vertical centre of a 380-tall window.
#     x = 140 and x = 400 are symmetric about the 270 centre line, so the pair is balanced
#              and the drag from app to alias is horizontal.
# Change `--window-size` and all three of those have to move with it.
#
# ── IF A BACKGROUND IS EVER ADDED, IT GOES HERE ────────────────────────────────────────
#
# `--background <pic.png>` (png/gif/jpg, per create-dmg --help) would slot in immediately
# after `--volicon` below. There is deliberately none today: the window is plain, and correct
# icon positions plus a real volume icon are the substance of it.
#
# The one thing to know before adding one: the artwork has to be authored against the CONTENT
# rect above (540 × 380 at 1x), because the icon coordinates are in that same space — so a
# background drawn for a different window size will put any "drag me" arrow somewhere other
# than between the two icons. Retina handling is create-dmg's business and is NOT covered by
# the measurements above; check what this version does with a 2x asset before assuming.
#
# ⚠️ create-dmg CAN EXIT NON-ZERO AND STILL PRODUCE A VALID IMAGE — its Finder window-styling
# AppleScript fails on a locked screen, over SSH, or when Finder has no Automation permission.
# Blanket `|| true` would hide a genuine failure, so the exit code is inspected and a non-zero
# result is only tolerated when the image exists AND hdiutil verifies it.
set +e
create-dmg \
    --volname "${APP_NAME} ${VERSION}" \
    --volicon "$VOLICON" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "${APP_NAME}.app" 140 190 \
    --app-drop-link 400 190 \
    --no-internet-enable \
    "$DMG" "$STAGE_DIR" \
    > "${LOG_DIR}/create-dmg.log" 2>&1
dmg_status=$?
set -e

if [[ $dmg_status -ne 0 ]]; then
    if [[ -f "$DMG" ]] && hdiutil verify "$DMG" > "${LOG_DIR}/hdiutil-verify.log" 2>&1; then
        warn "create-dmg exited ${dmg_status} (window styling failed — see ${LOG_DIR}/create-dmg.log)"
        warn "the image itself verifies, so continuing"
    else
        tail -40 "${LOG_DIR}/create-dmg.log" >&2
        die "create-dmg failed (status ${dmg_status}) and produced no verifiable image"
    fi
fi
[[ -f "$DMG" ]] || die "create-dmg reported success but ${DMG} does not exist"

DMG_SIZE=$(du -sh "$DMG" | awk '{print $1}')
ok "built ${DMG} (${DMG_SIZE})"
record "dmg size:                ${DMG_SIZE}"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 8. Sign the DMG
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Sign DMG"

# --timestamp is not optional: notarization rejects a signature without a secure timestamp.
codesign --force --sign "$IDENTITY" --timestamp "$DMG" \
    || die "failed to sign the DMG"

set +e
DMG_VERIFY=$(codesign --verify --strict --verbose=2 "$DMG" 2>&1)
dmg_verify_status=$?
set -e
printf '%s\n' "$DMG_VERIFY" | sed 's/^/       /'
[[ $dmg_verify_status -eq 0 ]] || die "the signed DMG does not verify"

# ⚠️ CAPTURE FIRST, THEN ASSERT. This line was `codesign -dvv "$DMG" 2>&1 | grep -qF …` and it
# failed a correctly signed DMG: grep matched, exited, and SIGPIPEd codesign, which pipefail
# then reported as the pipeline's status. See the note on `contains`. codesign -dvv writes
# everything to STDERR (its stdout is empty — measured), hence the 2>&1, which was never the
# problem. A disk image's output carries `Authority=` in exactly the same form as a bundle's.
DMG_INFO=$(codesign -dvv "$DMG" 2>&1)
printf '%s\n' "$DMG_INFO" | sed 's/^/       /'
contains "Authority=${IDENTITY}" "$DMG_INFO" \
    || die "DMG is NOT signed with '${IDENTITY}'.
       Authorities found:
$(printf '%s\n' "$DMG_INFO" | grep '^Authority=' | sed 's/^/         /')
       (if that list is empty, the image is unsigned)"
ok "DMG signed and verified"
record "dmg signature:           verified, ${IDENTITY}"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 9. Notarize
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Notarize (submit --wait)"

NOTARY_JSON="${LOG_DIR}/notarytool-submit.json"
echo "   submitting ${DMG_SIZE} — this normally takes 1-5 minutes…"

# --wait blocks until Apple reaches a verdict. Its exit code is NOT trusted on its own: the
# documented failure on the sibling products was a step that reported success while doing
# nothing. The verdict is parsed out of the JSON and required to be literally "Accepted".
set +e
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json \
    > "$NOTARY_JSON" 2>"${LOG_DIR}/notarytool-submit.err"
notary_status=$?
set -e

[[ -s "$NOTARY_JSON" ]] || {
    cat "${LOG_DIR}/notarytool-submit.err" >&2
    die "notarytool produced NO OUTPUT (exit ${notary_status}). Notarization did not happen."
}

read -r SUBMISSION_ID NOTARY_VERDICT <<<"$(python3 - "$NOTARY_JSON" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
print(data.get("id", ""), data.get("status", ""))
PY
)"

# An empty id means nothing was ever submitted — the silent-skip case, which an exit code of 0
# would not have revealed.
[[ -n "$SUBMISSION_ID" ]] \
    || die "notarytool returned no submission id. Nothing was submitted; the DMG is NOT notarized.
$(cat "$NOTARY_JSON")"
ok "submission id ${SUBMISSION_ID}"

# The log is fetched WHATEVER the verdict — an Accepted submission can still carry warnings
# worth reading, and on failure "Invalid" with no detail is useless.
NOTARY_LOG="${LOG_DIR}/notarytool-log.json"
xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" "$NOTARY_LOG" \
    >/dev/null 2>&1 || warn "could not fetch the notarization log for ${SUBMISSION_ID}"

if [[ "$NOTARY_VERDICT" != "Accepted" ]]; then
    printf '\n%s── notarization verdict: %s ──%s\n' "$RED" "${NOTARY_VERDICT:-<none>}" "$RESET" >&2
    if [[ -s "$NOTARY_LOG" ]]; then
        printf '%s── notarytool log %s ──%s\n' "$RED" "$SUBMISSION_ID" "$RESET" >&2
        cat "$NOTARY_LOG" >&2
    else
        printf 'no log retrieved; fetch it with:\n  xcrun notarytool log %s --keychain-profile %s\n' \
            "$SUBMISSION_ID" "$NOTARY_PROFILE" >&2
    fi
    die "notarization was not Accepted (status: ${NOTARY_VERDICT:-<none>})"
fi
[[ $notary_status -eq 0 ]] || warn "notarytool exited ${notary_status} despite an Accepted verdict"
ok "notarization Accepted"
record "notarization:            Accepted (id ${SUBMISSION_ID})"

# A clean submission still lists issues sometimes. Surface the count rather than hiding it.
if [[ -s "$NOTARY_LOG" ]]; then
    ISSUE_COUNT=$(python3 - "$NOTARY_LOG" <<'PY'
import json, sys
try:
    issues = json.load(open(sys.argv[1])).get("issues") or []
    print(len(issues))
except Exception:
    print(0)
PY
)
    if [[ "$ISSUE_COUNT" != "0" ]]; then
        warn "notarization succeeded with ${ISSUE_COUNT} issue(s) — see ${NOTARY_LOG}"
        record "notarization issues:     ${ISSUE_COUNT} (non-fatal, see log)"
    else
        record "notarization issues:     none"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════════════════
# 10. Staple
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Staple the ticket"

xcrun stapler staple "$DMG" || die "stapler staple failed — the DMG would require a network
       round trip on every first launch, and would be refused entirely offline."
ok "ticket stapled"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 11. Final verification
# ══════════════════════════════════════════════════════════════════════════════════════════

step "Verify the shipped artefact"

# Positive assertion on the OUTPUT TEXT, not just the exit status — same reasoning as step 9.
set +e
STAPLE_OUT=$(xcrun stapler validate "$DMG" 2>&1)
staple_status=$?
set -e
printf '%s\n' "$STAPLE_OUT" | sed 's/^/       /'
[[ $staple_status -eq 0 ]] || die "stapler validate failed — the ticket is not attached"
contains_nocase 'worked' "$STAPLE_OUT" \
    || die "stapler validate exited 0 but did not report success:
${STAPLE_OUT}"
ok "stapler validate passed"
record "stapler validate:        passed"

set +e
SPCTL_OUT=$(spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1)
spctl_status=$?
set -e
printf '%s\n' "$SPCTL_OUT" | sed 's/^/       /'
[[ $spctl_status -eq 0 ]] || die "spctl rejected the DMG:
${SPCTL_OUT}"
contains_nocase 'accepted' "$SPCTL_OUT" \
    || die "spctl exited 0 without reporting 'accepted':
${SPCTL_OUT}"
ok "spctl assessment accepted"
record "spctl --assess:          accepted (source: Notarized Developer ID)"

# ══════════════════════════════════════════════════════════════════════════════════════════
# 13. Publish
# ══════════════════════════════════════════════════════════════════════════════════════════
#
# ⚠️ LAST, AND ONLY AFTER EVERY VERIFICATION ABOVE HAS PASSED. Signing, notarization, stapling
# and the Gatekeeper assessment all gate this step, so an artefact that failed any of them
# cannot reach a public URL — the script dies before it gets here. Publishing earlier would be
# convenient and would mean a rejected DMG could be downloadable for as long as it took someone
# to notice.

DOWNLOAD_URL="${RELEASES_BASE}/${PRODUCT_SLUG}/mac-arm64"
MANIFEST_URL="${RELEASES_BASE}/${PRODUCT_SLUG}/manifest"

if [[ $DO_UPLOAD -eq 0 ]]; then
    step "Publish — SKIPPED (--no-upload)"
    ok "not published; the verified DMG is at ${DMG}"
    record "published:               no (--no-upload)"
else
    # ══════════════════════════════════════════════════════════════════════════════════════
    # 12b. Corresponding source (LGPL 2.1 §6) — published BEFORE the binary
    # ══════════════════════════════════════════════════════════════════════════════════════
    #
    # The About panel makes a written offer under §6 and NAMES A URL. If that URL does not
    # resolve, the offer is not an offer. So the source goes up first: at no point is a binary
    # downloadable whose licence notice points at a 404.
    #
    # ⚠️ THIS IS KEYED BY THE FFmpeg PIN, NOT BY THE MANIFOLD VERSION. The tarball is FFmpeg's
    # source; it changes only when the pinned commit changes. Re-uploading 11 MB of identical
    # bytes on every release would be waste, so a normal release costs ONE HTTP request and
    # uploads nothing. Bumping the pin changes the filename, the HEAD misses, and exactly one
    # upload happens automatically.
    #
    # The filename carries the short SHA, so the URL the About panel prints and the object in
    # the bucket cannot name different versions — there is one string, derived from one pin.
    step "Corresponding source (LGPL §6)"

    # Read the pin and the key format from build_ffmpeg.sh rather than restating them. That
    # script owns the pin; a second copy here is a second thing to forget to update.
    SOURCE_INFO=$( "${REPO_ROOT}/scripts/build_ffmpeg.sh" --source-info ) \
        || die "could not read the FFmpeg source pin from scripts/build_ffmpeg.sh"
    eval "$SOURCE_INFO"
    [[ -n "${SOURCE_URL:-}" && -n "${SOURCE_OBJECT:-}" ]] \
        || die "scripts/build_ffmpeg.sh --source-info did not yield SOURCE_URL/SOURCE_OBJECT"
    ok "pin ${FFMPEG_TAG} @ ${FFMPEG_SHORT}"
    ok "expects ${SOURCE_FILENAME}"

    # ── Is it already published? One request against the very URL the app will print, which
    #    is a stronger check than asking R2 directly: it also proves the Worker serves it.
    set +e
    SRC_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -I -L --max-time 30 "$SOURCE_URL" 2>/dev/null)
    src_curl_status=$?
    set -e

    if [[ $src_curl_status -eq 0 && "$SRC_HTTP" == "200" ]]; then
        ok "already published (HTTP 200) — nothing to upload"
        record "corresponding source:    already live, ${SOURCE_FILENAME}"
    else
        warn "not published yet (HTTP ${SRC_HTTP:-?}) — building and uploading it now"

        SOURCE_TARBALL="${RUN_DIR}/${SOURCE_FILENAME}"
        "${REPO_ROOT}/scripts/build_ffmpeg.sh" --source-tarball "$SOURCE_TARBALL" \
            > "${LOG_DIR}/source-tarball.log" 2>&1 \
            || { tail -30 "${LOG_DIR}/source-tarball.log" >&2
                 die "could not build the corresponding-source tarball — log: ${LOG_DIR}/source-tarball.log"; }
        [[ -f "$SOURCE_TARBALL" ]] || die "the tarball step reported success but produced no file"
        ok "built $(du -h "$SOURCE_TARBALL" | awk '{print $1}') from the pinned checkout"

        # Same invocation shape the shared uploader uses: the first path component is the
        # bucket, the rest is the key, and --remote means the real bucket rather than a local
        # simulation. Run from REPO_ROOT so wrangler resolves the same account cache.
        ( cd "$REPO_ROOT" && wrangler r2 object put "$SOURCE_OBJECT" --file "$SOURCE_TARBALL" --remote ) \
            > "${LOG_DIR}/source-upload.log" 2>&1 \
            || { tail -20 "${LOG_DIR}/source-upload.log" >&2
                 die "uploading the corresponding source failed — log: ${LOG_DIR}/source-upload.log"; }
        ok "uploaded to ${SOURCE_OBJECT}"

        # ── VERIFY IT IS ACTUALLY SERVED. The upload can succeed while the URL still 404s,
        #    because the Worker only passes through endpoints it knows about.
        set +e
        SRC_HTTP2=$(curl -sS -o /dev/null -w '%{http_code}' -I -L --max-time 30 "$SOURCE_URL" 2>/dev/null)
        set -e
        if [[ "$SRC_HTTP2" != "200" ]]; then
            die "the source uploaded to R2 but ${SOURCE_URL} returns HTTP ${SRC_HTTP2:-?}.
       THIS IS A WORKER ROUTING GAP, NOT A FAILED UPLOAD — and it would ship an app whose
       LGPL §6 offer points at a dead URL.
       The release Worker passes through only 'binaries', 'current' and 'archive'. Add
       'source' in Graviton-Releases/src/index.js:
           if (endpoint === 'current' || endpoint === 'archive' || endpoint === 'source') {
       then redeploy:
           cd '$(dirname "$UPLOAD_SCRIPT")' && wrangler deploy
       and re-run this release."
        fi
        ok "served at ${SOURCE_URL} (HTTP 200)"
        record "corresponding source:    UPLOADED + verified, ${SOURCE_FILENAME}"
    fi

    step "Publish to R2"

    # The uploader is invoked from the repo root so its default RELEASE_NOTES.md lookup and any
    # relative path it forms resolve where they should. Everything Manifold-specific travels as
    # environment, because the DMG is built outside the repo and has no path the shared script
    # could predict.
    (
        cd "$REPO_ROOT"
        RELEASE_MAC_ARM="$DMG" \
        RELEASE_BUILD="$NEW_BUILD" \
        RELEASE_NOTES_FILE="$NOTES_FILE" \
        bash "$UPLOAD_SCRIPT" "$PRODUCT_SLUG" "$VERSION"
    ) || die "upload failed — nothing was published, or the upload is incomplete.
       The verified DMG is still at:
         ${DMG}
       Re-run publishing alone once the cause is fixed:
         cd ${REPO_ROOT} && RELEASE_MAC_ARM='${DMG}' RELEASE_BUILD='${NEW_BUILD}' \\
           RELEASE_NOTES_FILE='${NOTES_FILE}' bash '${UPLOAD_SCRIPT}' ${PRODUCT_SLUG} ${VERSION}"
    ok "upload reported success"

    # ══════════════════════════════════════════════════════════════════════════════════════
    # 14. Verify what is actually live
    # ══════════════════════════════════════════════════════════════════════════════════════
    #
    # ⚠️ THE UPLOADER'S EXIT CODE IS NOT EVIDENCE THAT ANYTHING CHANGED. The failure this guards
    # against is an upload that reports success while the OLD manifest stays live — testers then
    # download yesterday's build and report bugs that were fixed. So the published manifest is
    # fetched back and required to name the version AND build just produced.
    #
    # --fail (or --fail-with-body) IS NOT OPTIONAL. Without it curl writes the error page into
    # the output and exits 0, which on the sibling products meant a 404 page was saved into a
    # file that looked like a binary. --fail-with-body keeps the body for diagnosis while still
    # failing on an HTTP error.
    step "Verify the published manifest"

    LIVE_MANIFEST="${LOG_DIR}/live-manifest.json"
    MANIFEST_OK=0
    LAST_HTTP=""
    for attempt in 1 2 3 4 5; do
        # Cache-buster: the Worker sends no-cache for the manifest, but the edge is entitled to
        # hold a 404 from before this product existed, and a distinct query string is a
        # different cache key.
        set +e
        LAST_HTTP=$(curl -sS --fail-with-body --max-time 30 \
            -o "$LIVE_MANIFEST" -w '%{http_code}' \
            "${MANIFEST_URL}?cachebust=$(date +%s)-${attempt}" 2>"${LOG_DIR}/curl.err")
        curl_status=$?
        set -e
        if [[ $curl_status -eq 0 ]]; then MANIFEST_OK=1; break; fi
        [[ $attempt -lt 5 ]] && { warn "manifest not live yet (HTTP ${LAST_HTTP:-?}), retrying…"; sleep 3; }
    done

    if [[ $MANIFEST_OK -eq 0 ]]; then
        # One failure mode deserves its own message because the fix is not in this repo: the
        # Worker keeps its own product allowlist and rejects anything missing from it BEFORE it
        # consults R2, so the upload can be perfect and every URL still 404.
        if [[ -s "$LIVE_MANIFEST" ]] && contains "Unknown product" "$(cat "$LIVE_MANIFEST")"; then
            die "the release Worker does not know the product '${PRODUCT_SLUG}'.
       The upload to R2 succeeded — this is a Worker configuration gap, not a failed release.
       Add '${PRODUCT_SLUG}' to PRODUCTS in Graviton-Releases/src/index.js and redeploy:
         cd '$(dirname "$UPLOAD_SCRIPT")' && wrangler deploy
       Then re-run just this verification:
         curl --fail-with-body ${MANIFEST_URL}"
        fi
        die "could not fetch the published manifest after 5 attempts (last HTTP ${LAST_HTTP:-?}).
       URL: ${MANIFEST_URL}
$( [[ -s "$LIVE_MANIFEST" ]] && printf '       body: %s\n' "$(head -c 300 "$LIVE_MANIFEST")" )"
    fi

    read -r LIVE_VERSION LIVE_BUILD LIVE_ASSET LIVE_NOTES <<<"$(python3 - "$LIVE_MANIFEST" <<'PY'
import json, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception:
    print("<unparseable> <unparseable> <unparseable> 0"); raise SystemExit
print(m.get("version", "<none>"),
      m.get("build", "<none>"),
      (m.get("assets") or {}).get("mac-arm64", "<none>"),
      len(m.get("notes") or []))
PY
)"

    [[ "$LIVE_VERSION" == "$VERSION" ]] \
        || die "the live manifest reports version '${LIVE_VERSION}', expected '${VERSION}'.
       The upload did not replace the previous manifest — testers would download the old build.
       URL: ${MANIFEST_URL}"
    [[ "$LIVE_BUILD" == "$NEW_BUILD" ]] \
        || die "the live manifest reports build '${LIVE_BUILD}', expected '${NEW_BUILD}'.
       The version matches but the build does not, so this is a STALE manifest from an earlier
       release of the same version. URL: ${MANIFEST_URL}"
    [[ "$LIVE_ASSET" == "$(basename "$DMG")" ]] \
        || die "the live manifest points at asset '${LIVE_ASSET}', expected '$(basename "$DMG")'."

    ok "live manifest reports ${LIVE_VERSION} build ${LIVE_BUILD}"
    ok "live asset: ${LIVE_ASSET}"
    record "published manifest:      ${LIVE_VERSION} build ${LIVE_BUILD} (verified live)"

    if [[ "$LIVE_NOTES" == "0" ]]; then
        warn "the published manifest carries NO release notes — add a '## ${VERSION}' section to"
        warn "${NOTES_FILE} and re-run the uploader if the update dialog should show them"
        record "release notes:           none published"
    else
        ok "${LIVE_NOTES} release note(s) published"
        record "release notes:           ${LIVE_NOTES} entries"
    fi

    # The download endpoint is a 302 to the versioned file in current/. Checked with -I so the
    # 4 MB body is not fetched just to prove the redirect resolves.
    set +e
    DL_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -L -I --max-time 60 "$DOWNLOAD_URL")
    dl_status=$?
    set -e
    if [[ $dl_status -eq 0 && "$DL_HTTP" == "200" ]]; then
        ok "download URL resolves (HTTP ${DL_HTTP})"
        record "download URL:            reachable (HTTP ${DL_HTTP})"
    else
        warn "download URL did not resolve cleanly (HTTP ${DL_HTTP:-?}) — the manifest is live,"
        warn "so this is probably edge propagation; re-check ${DOWNLOAD_URL}"
        record "download URL:            UNVERIFIED (HTTP ${DL_HTTP:-?})"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════════════════
# 15. Report
# ══════════════════════════════════════════════════════════════════════════════════════════

printf '\n%s══════════════════════════════════════════════════════════════════════%s\n' "$BOLD" "$RESET"
printf '%s  RELEASE COMPLETE — %s %s (build %s)%s\n' "$BOLD" "$CONFIG" "$VERSION" "$NEW_BUILD" "$RESET"
printf '%s══════════════════════════════════════════════════════════════════════%s\n\n' "$BOLD" "$RESET"

printf '  %sDMG%s       %s\n' "$BOLD" "$RESET" "$DMG"
if [[ $DO_UPLOAD -eq 1 ]]; then
    printf '  %sDOWNLOAD%s  %s\n' "$BOLD" "$RESET" "$DOWNLOAD_URL"
    printf '  %sMANIFEST%s  %s\n' "$BOLD" "$RESET" "$MANIFEST_URL"
fi
printf '\n'

printf '  Verification results\n'
printf '  --------------------\n'
for line in "${RESULTS[@]}"; do printf '    %s\n' "$line"; done

printf '\n  Artefacts\n'
printf '  ---------\n'
printf '    archive:  %s\n' "$ARCHIVE_PATH"
printf '    app:      %s\n' "$APP"
printf '    logs:     %s\n' "$LOG_DIR"

printf '\n  Next\n'
printf '  ----\n'
printf '    - commit the CURRENT_PROJECT_VERSION bump in project.yml (now %s)\n' "$NEW_BUILD"
if [[ $DO_UPLOAD -eq 0 ]]; then
    printf '    - NOT PUBLISHED (--no-upload). To publish this exact DMG later:\n'
    printf '        cd %s && RELEASE_MAC_ARM=%q RELEASE_BUILD=%q \\\n' "$REPO_ROOT" "$DMG" "$NEW_BUILD"
    printf '          RELEASE_NOTES_FILE=%q bash %q %s %s\n' \
        "$NOTES_FILE" "$UPLOAD_SCRIPT" "$PRODUCT_SLUG" "$VERSION"
fi
if [[ "$CONFIG" == "Profile" ]]; then
    printf '    - this is the TESTER build: telemetry is compiled in, diagnostics export is complete\n'
else
    printf '    - this is the PUBLIC build: per-second telemetry is compiled out by design\n'
fi
printf '\n'
