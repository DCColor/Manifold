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
  MANIFOLD_DIST_DIR   where artefacts are written (default: ~/Builds/Manifold)
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
# The uploader is SHARED across Graviton products and lives in a sibling repo, so the R2 layout,
# archive paths and manifest shape have one definition rather than one per product.
PRODUCT_SLUG="manifold"
RELEASES_BASE="https://releases.graviton.tools"
UPLOAD_SCRIPT="$(cd "${REPO_ROOT}/../.." 2>/dev/null && pwd)/Graviton-Releases/upload-release.sh"
NOTES_FILE="${REPO_ROOT}/RELEASE_NOTES.md"

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
        || die "shared uploader not found: ${UPLOAD_SCRIPT}
       Expected the Graviton-Releases repo as a sibling of this one.
       Build without publishing with:  $0 ${CONFIG} --no-upload"
    for tool in wrangler curl; do
        command -v "$tool" >/dev/null 2>&1 || die "required for publishing but not on PATH: ${tool}"
    done
    ok "publishing enabled — uploader at ${UPLOAD_SCRIPT}"

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
for lib in ffmpeg libsrt libdatachannel; do
    compgen -G "${REPO_ROOT}/ThirdParty/${lib}/lib/*.a" >/dev/null \
        || die "vendored static libs missing: ThirdParty/${lib}/lib/*.a
       They are gitignored — rebuild with scripts/build_${lib}.sh (see ThirdParty/${lib}/README.md)."
done
ok "gitignored build inputs present (DeckLink SDK, NDI headers, 3 vendored lib trees)"

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

# ⚠️ create-dmg CAN EXIT NON-ZERO AND STILL PRODUCE A VALID IMAGE — its Finder window-styling
# AppleScript fails on a locked screen, over SSH, or when Finder has no Automation permission.
# Blanket `|| true` would hide a genuine failure, so the exit code is inspected and a non-zero
# result is only tolerated when the image exists AND hdiutil verifies it.
set +e
create-dmg \
    --volname "${APP_NAME} ${VERSION}" \
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
         cd $(dirname "$UPLOAD_SCRIPT") && wrangler deploy
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
