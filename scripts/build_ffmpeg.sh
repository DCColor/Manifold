#!/bin/bash
#
# Build FFmpeg n8.1.1 as SHARED libraries (dylibs), arm64-only, LGPL-clean, and
# stage them into ThirdParty/ffmpeg/.
#
#   ./scripts/build_ffmpeg.sh                    full build + stage + verify
#   ./scripts/build_ffmpeg.sh --provenance-only  clone at the pin, diff vs the legacy tree, stop
#   ./scripts/build_ffmpeg.sh --verify-only      re-run every assertion against what is ALREADY staged
#   ./scripts/build_ffmpeg.sh --verify-relocatable <path/to/Manifold.app>
#                                                prove the app does not depend on any build-tree path
#   FFMPEG_PIN_BOOTSTRAP=1 ./scripts/build_ffmpeg.sh
#                                                resolve the tag to a commit SHA, print it, stop
#
# Produces:
#   ThirdParty/ffmpeg/lib/libavcodec.62.dylib      (+ libavcodec.dylib     -> symlink, link-time only)
#   ThirdParty/ffmpeg/lib/libavformat.62.dylib     (+ libavformat.dylib    -> symlink)
#   ThirdParty/ffmpeg/lib/libavutil.60.dylib       (+ libavutil.dylib      -> symlink)
#   ThirdParty/ffmpeg/lib/libswscale.9.dylib       (+ libswscale.dylib     -> symlink)
#   ThirdParty/ffmpeg/lib/libswresample.6.dylib    (+ libswresample.dylib  -> symlink)
#   ThirdParty/ffmpeg/include/                     the matching public headers
#
# ══════════════════════════════════════════════════════════════════════════════════════════
# WHY SHARED, AND WHY THIS SCRIPT EXISTS AT ALL
#
# ── WHY DYLIBS: LGPL 2.1 §6 ─────────────────────────────────────────────────
# Manifold links FFmpeg, which makes the app a work that uses the Library under LGPL 2.1 §5.
# §6 requires that a user be able to relink the application against a MODIFIED FFmpeg. Static
# .a linking makes that impossible — the libav code is fused into the app binary and there is
# nothing left to replace. Shipping FFmpeg as shared libraries the user can swap in
# Contents/Frameworks satisfies §6(b).
#
# This is NOT a GPL question and does NOT affect Manifold's own source. The build is LGPL by
# construction and stays that way: CONFIG_GPL 0, CONFIG_NONFREE 0, CONFIG_VERSION3 0, all
# asserted in LAYER 2 below.
#
# ── WHY THIS SCRIPT: THE RECIPE HAD NO HOME ─────────────────────────────────
# Until this file, the FFmpeg build was performed BY HAND in ~/manifold-ffmpeg-srt/ and the
# exact configure line survived only as line 1 of ffbuild/config.log inside that untracked
# directory. The source was an extracted tarball with no .git, no tag, no checksum — so a
# rebuild could silently pick up different source and nothing would notice. Both of those are
# fixed here: the line is a literal array below, and the source is pinned to a commit SHA.
#
# ══════════════════════════════════════════════════════════════════════════════════════════
# ⚠️ --disable-network IS LOAD-BEARING — do not "helpfully" enable it
#
# This build has NO network layer: ff_file_protocol is the only protocol compiled in and
# avformat_network_init() is a no-op stub. Every byte that reaches libavformat arrives through
# a CUSTOM AVIOContext. libsrt owns the SRT socket (ThirdParty/libsrt) and libdatachannel owns
# the WHEP one; FFmpeg demuxes and decodes, and never opens a socket, resolves a host, or
# speaks a protocol.
#
# Enabling it would add a second, competing SRT/UDP/RTP implementation inside the same binary,
# expose an avformat_open_input("srt://…") path that bypasses our entire transport layer and
# its error handling, and drag in TLS/DNS surface this project spent real effort excluding
# (see scripts/build_mbedtls.sh on why there is no OpenSSL or GnuTLS anywhere).
#
# If a future format appears to need it, the answer is another custom AVIOContext.
#
# LAYER 2 and LAYER 3 both assert this, from two independent directions: config.h says exactly
# one protocol is compiled in, and the SHIPPED DYLIB is asked at runtime to enumerate its
# protocols and must answer "file" and nothing else.
#
# ══════════════════════════════════════════════════════════════════════════════════════════
# ⚠️ THE nm RECIPES FROM THE STATIC ERA ARE DEAD. DO NOT RESURRECT THEM.
#
# ThirdParty/ffmpeg/README.md used to verify this build with four nm greps for ff_mov_demuxer,
# ff_dnxhd_decoder, ff_file_protocol and friends. On a SHARED build those all fail — and fail
# in the most misleading way possible, by reporting that the demuxers vanished from a perfectly
# good dylib.
#
# Two independent reasons, both confirmed in ffbuild/config.mak:
#   SHFLAGS carries  -Wl,-exported_symbols_list,libavcodec.ver  — the dylib exports ONLY the
#       public API (av*/sws*/swr*). Every ff_* internal is hidden by construction.
#   STRIP = strip -x, run by install-lib$(NAME)-shared — local symbols are removed on install.
#
# The replacement (LAYER 3) is strictly stronger: instead of grepping a symbol table for a
# proxy, it LOADS THE SHIPPED DYLIB and asks libavformat to enumerate its own demuxers,
# decoders, parsers and protocols. That tests the artifact, not a footprint of it.
# ══════════════════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════════════════
# PIPEFAIL-SAFE MATCHING HELPERS — read before touching any check below.
#
# `producer | grep -q pattern` is a FOOTGUN under `set -o pipefail`:
#   grep -q exits at the FIRST match and closes the read end of the pipe; the producer (nm,
#   otool, strings) is still writing, takes SIGPIPE, and exits 141; pipefail then reports 141
#   as the PIPELINE's status. So the check fails PRECISELY BECAUSE the thing it looked for was
#   found — and only when the match comes early enough that the producer hasn't finished. A
#   genuinely absent match lets the producer finish and exits 1, which looks identical.
#
# Fix: capture the producer's output ONCE into a variable, then match with a here-string. A
# here-string is not a pipeline, so nothing can be SIGPIPEd and grep's own exit status is the
# only thing tested. Same convention as scripts/build_libsrt.sh — see the longer note there.
# ══════════════════════════════════════════════════════════════════════════════════════════

# has_line <text> <extended-regex>  -> 0 if the pattern occurs, 1 if not.
has_line() { grep -qE -- "$2" <<<"$1"; }

# find_lines <text> <extended-regex> -> prints matching lines (empty if none).
find_lines() { grep -E -- "$2" <<<"$1" || true; }

# ── THE SOURCE PIN ──────────────────────────────────────────────────────────
# A TAG IS NOT A PIN. Tags can be moved, and the tree this replaced was an extracted tarball
# with no VCS metadata at all — so "n8.1.1" was, until now, an assertion about a directory
# NAME. The commit SHA below is the actual pin; the tag is a convenience for the clone.
#
# To establish or rotate it:
#     FFMPEG_PIN_BOOTSTRAP=1 ./scripts/build_ffmpeg.sh
# which clones the tag, prints the resolved SHA, and stops WITHOUT building. Paste the SHA
# here. Every later run asserts against it and refuses to build on a mismatch.
FFMPEG_TAG="n8.1.1"
# Resolved 2026-07-28. NOTE: git.ffmpeg.org did not answer ls-remote from here; this came from
# the GitHub mirror, which is upstream's own official mirror. Both remotes are tried in order
# below, so this is a note about the day, not a dependency on GitHub.
FFMPEG_COMMIT="239f2c733de417201d7ad3b3b8b0d9b63285b2b1"
FFMPEG_REPO="https://git.ffmpeg.org/ffmpeg.git"
FFMPEG_REPO_MIRROR="https://github.com/FFmpeg/FFmpeg.git"

# ── Toolchain — MUST match Manifold's app target exactly ────────────────────
# Verified against project.yml (`deploymentTarget: macOS: "15.0"`, `ARCHS: arm64`) and against
# scripts/build_libsrt.sh, which pins the identical pair. 15.0 — NOT 13.0. Mismatching produces
# "built for newer macOS version than being linked" warnings at the Manifold link.
ARCH="arm64"
MACOS_MIN="15.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/ThirdParty/ffmpeg"             # final home, in-repo (gitignored)
WORK="${HOME}/manifold-ffmpeg-build"              # space-free scratch (the repo path has spaces)
SRC="${WORK}/ffmpeg"
PREFIX="${WORK}/prefix"
PROBE_DIR="${WORK}/probe"

# The by-hand build this script replaces. Read-only, and only for the one-time provenance diff.
LEGACY_TREE="${HOME}/manifold-ffmpeg-srt/FFmpeg-n8.1.1"

# The five libraries Manifold actually ships. libavdevice and libavfilter are BUILT by this
# configure (CONFIG_AVDEVICE/CONFIG_AVFILTER are 1) and deliberately NOT staged: nothing in
# App/ or Packages/ references either, and libavformat/libavcodec do not depend on them. That
# is asserted after staging — see "no unstaged inter-library dependency" below.
LIBS=(avcodec avformat avutil swscale swresample)

# Expected soname majors for n8.1.1, read from the source tree's version_major.h / version.h.
# These are asserted against the built dylibs; a mismatch means the pin moved.
#
# A case statement rather than an associative array: macOS ships bash 3.2 (verified —
# /bin/bash is 3.2.57 and there is no newer bash on this machine), which has neither
# `declare -A` nor namerefs. Every helper below is written to that constraint, same as
# release-mac.sh and the other three build scripts.
major_for() {
    case "$1" in
        avcodec)    echo 62 ;;
        avformat)   echo 62 ;;
        avutil)     echo 60 ;;
        swscale)    echo 9  ;;
        swresample) echo 6  ;;
        *) die "major_for: unknown library '$1'" ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# THE CONFIGURE LINE — THE ONE THING IN THIS FILE THAT MUST NOT DRIFT
#
# BASELINE is the line that produced the shipping 0.5.1 static archives, recovered verbatim
# from line 1 of ~/manifold-ffmpeg-srt/FFmpeg-n8.1.1/ffbuild/config.log. It is recorded here
# as documentation and as the thing the deltas are stated RELATIVE TO. It is not executed.
#
#   --prefix=<prefix> --enable-static --disable-shared --disable-programs --disable-doc
#   --disable-autodetect --disable-network --disable-everything
#   --enable-decoder=dnxhd
#   --enable-decoder='pcm_s16le,pcm_s24le,pcm_s32le,pcm_s16be,pcm_s24be,pcm_f32le,aac,aac_latm'
#   --enable-demuxer=mov --enable-demuxer=mxf --enable-demuxer=mpegts
#   --enable-parser=h264 --enable-protocol=file --enable-swscale --disable-x86asm
#
# FOUR NUMBERED CHANGES — FIVE FLAGS, since CHANGE 1 is a pair. NOTHING ELSE MAY DIFFER. Each
# is marked CHANGE n below and all are encoded in the LAYER 1 assertion, so a further difference
# cannot arrive unannounced.
# (That assertion earned its keep immediately: it caught THIS script's first draft passing
# --arch/--extra-cflags outside the array, which is how CHANGE 4 came to be noticed at all.)
#
#   CHANGE 1  --enable-static --disable-shared  ->  --enable-shared --disable-static
#             The LGPL §6 change. Everything else here exists to keep it the ONLY behavioural one.
#
#   CHANGE 2  --enable-decoder=prores
#             Banked for two reasons that both surfaced on 2026-07-28. (a) A libav fallback for
#             AVFoundation-rejected files: A027C021_171116_R022.mov (ProRes 4444, ap4h) is
#             refused by AVFoundation because its video stsd carries 8 trailing zero bytes that
#             parse as a box with SIZE 0; libav reads it without complaint, and the mov demuxer
#             is already compiled in — but there was no ProRes DECODER, so libav could demux it
#             and then have nothing to decode it with. (b) Reuse of this build by Flip.
#             Costs a few hundred KB. Whether an AVFoundation-rejected file SHOULD fall back to
#             libav is a separate product decision; this flag only makes it possible.
#
#   CHANGE 3  --install-name-dir=@rpath
#             REQUIRED BY CHANGE 1, and the reason is worth stating because it is invisible on
#             the build machine. Darwin's SHFLAGS bake the install_name at link time:
#                 -Wl,-install_name,$(INSTALL_NAME_DIR)/$(SLIBNAME_WITH_MAJOR)
#             and INSTALL_NAME_DIR defaults to $(SHLIBDIR) — an ABSOLUTE PATH INTO THIS
#             MACHINE'S HOME DIRECTORY. Shipped unchanged, Manifold would record
#             /Users/<someone>/manifold-ffmpeg-build/prefix/lib/libavcodec.62.dylib and fail to
#             launch on every other machine, WHILE WORKING PERFECTLY HERE.
#             Setting it to @rpath fixes the dylib's own id AND every inter-library dependency
#             record (avcodec->avutil, avformat->avcodec, …) at link time, in one step. The
#             alternative — install_name_tool -id plus -change over every pair afterwards —
#             does the same job later, by hand, with more places to get it wrong.
#             --verify-relocatable is the check that this actually took.
#
#   CHANGE 4  --extra-cflags / --extra-ldflags = -mmacosx-version-min=15.0
#             (Discussed and approved as "the fifth change" — it is the fifth FLAG, and the
#             fourth numbered one, because CHANGE 1 is the two-flag static/shared inversion.)
#             FIXES A PRE-EXISTING DEFECT, and is the one change here that is not a consequence
#             of going shared. The by-hand build passed no deployment target at all, so it
#             inherited the HOST default — the shipping 0.5.1 archives carry LC_BUILD_VERSION
#             minos 26.0 while the app targets macOS 15.0. Measured, not inferred: the 0.5.1
#             archive log contains 226 instances of
#                 ld: warning: object file (…libavformat.a[4](avformat.o)) was built for newer
#                     'macOS' version (26.0) than being linked (15.0)
#             i.e. Manifold ships libav code compiled against an OS newer than the app claims to
#             support. scripts/build_libsrt.sh already pins exactly this pair for the other three
#             vendored libraries and says why in its own comments; the FFmpeg build simply never
#             followed the convention. Going shared makes it more visible (ld checks a dylib's
#             platform at link time), so it is fixed here rather than carried forward.
#
#   NOT ADDED: --arch=arm64. Redundant — configure already detects aarch64 on this host (the
#             baseline build's own log reports "ARCH aarch64 (generic)" with no such flag), and
#             adding it would be a difference that buys nothing. arm64-only is asserted after
#             the build instead, with lipo, on each staged dylib.
#
#   NOT ADDED: --enable-pic. It is unnecessary and would be a further difference. clang defines
#             __PIC__ by default on arm64 Darwin, which configure picks up (configure:6445,
#             enable_weak pic), and it additionally forces pic for shared builds. Measured, not
#             assumed: the PREVIOUS STATIC build already had CONFIG_PIC 1. LAYER 2 asserts
#             CONFIG_PIC is 1, which is a stronger statement than passing the flag would be.
# ══════════════════════════════════════════════════════════════════════════════════════════

CONFIGURE_ARGS=(
    --prefix="${PREFIX}"
    --enable-shared                     # CHANGE 1a  (was --enable-static)
    --disable-static                    # CHANGE 1b  (was --disable-shared)
    --install-name-dir=@rpath           # CHANGE 3
    --disable-programs
    --disable-doc
    --disable-autodetect
    --disable-network                   # LOAD-BEARING — see the banner above
    --disable-everything
    --enable-decoder=dnxhd
    --enable-decoder=prores             # CHANGE 2
    --enable-decoder=pcm_s16le,pcm_s24le,pcm_s32le,pcm_s16be,pcm_s24be,pcm_f32le,aac,aac_latm
    --enable-demuxer=mov
    --enable-demuxer=mxf
    --enable-demuxer=mpegts
    --enable-parser=h264
    --enable-protocol=file
    --enable-swscale
    --disable-x86asm
    --extra-cflags=-mmacosx-version-min=15.0     # CHANGE 4 — see MACOS_MIN
    --extra-ldflags=-mmacosx-version-min=15.0    # CHANGE 4
)

# CHANGE 4's value is written literally above rather than interpolated from ${MACOS_MIN},
# because CONFIGURE_ARGS is the thing LAYER 1 asserts against and an interpolated assertion
# cannot catch a change to what it interpolates. This guard ties the two together instead.
[ "$MACOS_MIN" = "15.0" ] || die "MACOS_MIN is ${MACOS_MIN} but CONFIGURE_ARGS hardcodes 15.0 — change both"

# ── The component sets LAYER 2 and LAYER 3 both assert ──────────────────────
# Enumerated from the PREVIOUS build's config_components.h, plus prores. Stated as exact sets,
# not as "contains" checks: the negative half — that nothing ELSE got enabled — is the half
# that protects --disable-network and --disable-everything.
EXPECTED_DECODERS=(aac aac_latm dnxhd pcm_f32le pcm_s16be pcm_s16le pcm_s24be pcm_s24le pcm_s32le prores)
EXPECTED_DEMUXERS=(mov mpegts mxf)
EXPECTED_PARSERS=(aac_latm h264)        # aac_latm is pulled in by the aac_latm decoder
EXPECTED_PROTOCOLS=(file)
# Demuxer long-names as libavformat reports them at RUNTIME (LAYER 3), which differ from the
# config.h component names: the mov demuxer answers to all the container extensions it handles.
EXPECTED_RUNTIME_DEMUXERS=("mov,mp4,m4a,3gp,3g2,mj2" "mpegts" "mxf")

# ══════════════════════════════════════════════════════════════════════════════════════════
# Output helpers
# ══════════════════════════════════════════════════════════════════════════════════════════

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
say()  { printf '%s\n' "$*"; }
head2() { printf '\n%s── %s %s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '\n%sFATAL: %s%s\n\n' "$RED" "$*" "$RESET" >&2; exit 1; }

FAIL=0
fail() { bad "$*"; FAIL=1; }

# ══════════════════════════════════════════════════════════════════════════════════════════
# Argument parsing
# ══════════════════════════════════════════════════════════════════════════════════════════

MODE="build"
RELOC_APP=""
TARBALL_OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --provenance-only)     MODE="provenance" ;;
        --verify-only)         MODE="verify" ;;
        --verify-relocatable)  MODE="reloc"; RELOC_APP="${2:-}"; shift ;;
        --source-info)         MODE="sourceinfo" ;;
        --source-tarball)      MODE="tarball"; TARBALL_OUT="${2:-}"; shift ;;
        -h|--help)             sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)                     die "unknown argument: $1" ;;
    esac
    shift
done
[ "${FFMPEG_PIN_BOOTSTRAP:-0}" = "1" ] && MODE="bootstrap"

# ══════════════════════════════════════════════════════════════════════════════════════════
# Shared helpers
# ══════════════════════════════════════════════════════════════════════════════════════════

# normalize_config <string> -> one token per line, sorted, single quotes stripped.
#
# WHY QUOTES ARE STRIPPED RATHER THAN REPRODUCED. configure records its own invocation through
# sh_quote() (configure:616), which wraps any value containing a character outside
# [A-Za-z0-9_/.+-] in single quotes. Two of our arguments trip that rule — the comma-separated
# pcm/aac decoder list, and '@rpath' (the @ is not in the safe set) — so the recorded string is
# NOT character-identical to the array above even when it is semantically identical. Stripping
# quotes from both sides is lossless here (no argument legitimately contains one) and makes the
# comparison immune to a quoting rule that is configure's business, not ours.
#
# Sorting makes it immune to ARGUMENT ORDER too, which is deliberate: reordering flags does not
# change the build, and a diff that screams about it would train people to ignore this check.
normalize_config() {
    tr -d "'" <<<"$1" | tr ' \t' '\n\n' | grep -v '^$' | sort
}

# assert_config_line <actual-configuration-string> <source-label>
#
# LAYER 1 of the three-layer verification. Compares what configure RECORDED against the
# CONFIGURE_ARGS array above, and prints the exact flags that drifted in either direction.
assert_config_line() {
    local actual="$1" label="$2"
    local expected="${CONFIGURE_ARGS[*]}"
    local missing extra

    missing="$(comm -23 <(normalize_config "$expected") <(normalize_config "$actual") || true)"
    extra="$(comm -13 <(normalize_config "$expected") <(normalize_config "$actual") || true)"

    if [ -z "$missing" ] && [ -z "$extra" ]; then
        ok "LAYER 1: configure line matches the pinned four-change baseline (${label})"
        return 0
    fi

    bad "LAYER 1: the configure line has DRIFTED from the pinned four-change baseline (${label})"
    [ -n "$missing" ] && { say "      expected but ABSENT:"; sed 's/^/        /' <<<"$missing"; }
    [ -n "$extra" ]   && { say "      present but UNEXPECTED:"; sed 's/^/        /' <<<"$extra"; }
    say ""
    say "      expected: ${expected}"
    say "      actual:   ${actual}"
    say ""
    say "      If a change is intentional, edit CONFIGURE_ARGS in this script AND record it in"
    say "      the four-change banner above. Do not edit only one of the two."
    FAIL=1
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# THE CORRESPONDING-SOURCE TARBALL (LGPL 2.1 §6)
# ══════════════════════════════════════════════════════════════════════════════════════════
#
# §6 requires the Library's complete corresponding source to accompany the work (or a §6(c)
# written offer). The About panel makes the offer and names a URL; this is what that URL serves.
#
# ── IT IS BUILT FROM THE PINNED GIT CHECKOUT, NOT FROM THE OLD BY-HAND TREE ──
# The two were proven byte-identical for every git-tracked file (--provenance-only), so either
# would be *correct*. The checkout is more DEFENSIBLE, for four reasons:
#
#   1. `git archive <SHA>` is a pure function of the commit. Anyone holding the SHA we publish
#      can regenerate the same tree and check ours against it. The offer names a commit, so the
#      tarball should be derivable from that commit and nothing else.
#   2. The by-hand tree carries BUILD OUTPUTS mixed into the source — config.h,
#      config_components.h, ffbuild/, *.o, *.d. Producing a clean source tarball from it means
#      hand-curating exclusions, which is exactly the kind of judgement that silently goes wrong.
#   3. The byte-identity we proved covers git-TRACKED files only. It says nothing about extra
#      files in that tree. Building from the checkout means that proof carries no weight here at
#      all — nothing rests on it.
#   4. The legacy tree is untracked, disposable, and lives in one person's home directory; the
#      commit is permanent. A provenance chain whose root is a local folder is not a chain.
#
# ── AND IT CARRIES BUILD.txt ──
# "Corresponding source" means the source AS BUILT. Upstream source alone does not tell you which
# decoders were compiled in or that the network layer was disabled, so the configure line ships
# inside the tarball rather than only in the About panel.

FFMPEG_SHORT="${FFMPEG_COMMIT:0:12}"
SOURCE_FILENAME="ffmpeg-${FFMPEG_TAG}-${FFMPEG_SHORT}.tar.xz"
# wrangler's objectPath form: the FIRST component is the bucket, the rest is the key. The Worker
# then serves it at /manifold/source/<file> (env.GRAVITON.get("manifold/source/<file>")).
SOURCE_OBJECT="graviton/manifold/source/${SOURCE_FILENAME}"
SOURCE_URL="https://releases.graviton.tools/manifold/source/${SOURCE_FILENAME}"
# The tree prefix inside the tarball.
SOURCE_PREFIX="ffmpeg-${FFMPEG_TAG}"

# The configure line as it belongs in BUILD.txt: every flag EXCEPT --prefix, which is a local
# install path that has no effect on the code produced and would leak a home directory.
configure_line_public() {
    local a
    for a in "${CONFIGURE_ARGS[@]}"; do
        case "$a" in --prefix=*) continue ;; esac
        printf '%s\n' "  $a"
    done
}

write_build_txt() {   # write_build_txt <dest-file>
    cat > "$1" <<BUILDTXT
FFmpeg ${FFMPEG_TAG} — complete corresponding source for Manifold
=================================================================

This archive is the source for the FFmpeg shared libraries distributed inside
Manifold.app/Contents/Frameworks:

    libavcodec.62.dylib   libavformat.62.dylib   libavutil.60.dylib
    libswscale.9.dylib    libswresample.6.dylib

It is provided to satisfy GNU LGPL 2.1 section 6. Those libraries are LGPL-2.1-or-later.
Manifold itself is proprietary and is NOT covered by the LGPL; it merely links these
libraries, which is what section 6 permits and regulates.

WHAT THIS IS
------------
Unmodified upstream FFmpeg. No patch of ours is applied to any file.

    Release tag : ${FFMPEG_TAG}
    Commit      : ${FFMPEG_COMMIT}
    Upstream    : https://git.ffmpeg.org/ffmpeg.git
                  https://github.com/FFmpeg/FFmpeg.git   (official mirror)

Everything here except this BUILD.txt is the exact content of that commit. You can verify
that yourself, without trusting us:

    git clone https://github.com/FFmpeg/FFmpeg.git && cd FFmpeg
    git archive --format=tar --prefix=${SOURCE_PREFIX}/ ${FFMPEG_COMMIT} | tar -tvf - | sort

and compare against the listing of this archive (BUILD.txt aside).

HOW IT WAS BUILT
----------------
"Corresponding source" means the source AS BUILT, so here is the configure line. The
--prefix argument is omitted: it is a local install path and does not affect the code.

  ./configure \\
$(configure_line_public | sed 's/$/ \\/' | sed '$ s/ \\$//')

Built on macOS for arm64 with the clang from Xcode. Note in particular:

  --disable-network   There is no network layer in these libraries at all. The only
                      protocol compiled in is "file". Manifold feeds libavformat through
                      its own AVIOContext; the SRT and WebRTC transports are separate
                      libraries and are not part of FFmpeg.
  --disable-everything plus the explicit --enable-decoder/--enable-demuxer flags: only the
                      listed components are present. This is a deliberately small build.

Neither --enable-gpl nor --enable-nonfree nor --enable-version3 was used, so the LGPL —
not the GPL — applies. config.h in a configured tree will show CONFIG_GPL 0,
CONFIG_NONFREE 0, CONFIG_VERSION3 0.

RELINKING MANIFOLD AGAINST YOUR OWN BUILD
-----------------------------------------
LGPL 2.1 section 6 exists so that you can replace these libraries. Manifold is shipped with
that in mind: the libraries are dynamically linked, embedded as separate dylibs, and loaded
via @rpath. Step-by-step instructions are in Manifold under
Manifold > About Manifold > Licences > FFmpeg.

The short version: build this source with the configure line above, give each dylib an
@rpath install name, copy it into Manifold.app/Contents/Frameworks/, ad-hoc sign the
replacement, then re-sign the app bundle.
BUILDTXT
}

make_source_tarball() {   # make_source_tarball <out.tar.xz>
    local out="$1"
    [ -n "$out" ] || die "--source-tarball needs an output path"
    case "$out" in /*) ;; *) out="$(pwd)/${out}" ;; esac

    head2 "SOURCE TARBALL — ${SOURCE_FILENAME}"

    local stage="${WORK}/tarball-stage"
    rm -rf "$stage"; mkdir -p "$stage"

    # `git archive` rather than a copy of the working tree: the output is exactly the commit's
    # tree, with no build outputs, no .git, and nothing the working directory happens to contain.
    git -C "$SRC" archive --format=tar --prefix="${SOURCE_PREFIX}/" "$FFMPEG_COMMIT" \
        | ( cd "$stage" && tar -xf - )
    ok "extracted the commit's tree ($(find "${stage}/${SOURCE_PREFIX}" -type f | wc -l | tr -d ' ') files)"

    write_build_txt "${stage}/${SOURCE_PREFIX}/BUILD.txt"
    ok "BUILD.txt written (tag, commit, configure line, relink pointer)"

    # System tar, which on macOS is libarchive and compresses xz natively (-J). Deliberately NOT
    # the Homebrew `xz` binary: this needs no dependency that a fresh machine lacks.
    rm -f "$out"
    ( cd "$stage" && tar -cJf "$out" "${SOURCE_PREFIX}" )
    [ -f "$out" ] || die "tar produced no archive at ${out}"
    ok "compressed → ${out} ($(awk -v b="$(stat -f%z "$out")" 'BEGIN{printf "%.2f MB", b/1048576}'))"

    # ── CONTENT ASSERTION. Byte-for-byte reproducibility is not the goal (tar records mtimes and
    #    ownership); PROVING THE CONTENTS ARE THE COMMIT is. So the archive's file list is diffed
    #    against the commit's file list, and only BUILD.txt may differ.
    local in_tar in_commit unexpected missing
    in_tar="$(tar -tf "$out" | sed "s|^${SOURCE_PREFIX}/||" | grep -v '/$' | grep -v '^$' | sort)"
    in_commit="$( (git -C "$SRC" ls-tree -r --name-only "$FFMPEG_COMMIT"; echo "BUILD.txt") | sort)"
    unexpected="$(comm -23 <(printf '%s\n' "$in_tar") <(printf '%s\n' "$in_commit") || true)"
    missing="$(comm -13 <(printf '%s\n' "$in_tar") <(printf '%s\n' "$in_commit") || true)"
    if [ -n "$unexpected" ] || [ -n "$missing" ]; then
        [ -n "$unexpected" ] && { bad "files in the tarball that are NOT in the commit:"; sed 's/^/      /' <<<"$unexpected"; }
        [ -n "$missing" ]    && { bad "files in the commit that are MISSING from the tarball:"; sed 's/^/      /' <<<"$missing"; }
        die "the source tarball does not match the pinned commit"
    fi
    ok "contents == commit ${FFMPEG_SHORT} exactly, plus BUILD.txt ($(printf '%s\n' "$in_tar" | wc -l | tr -d ' ') files)"

    rm -rf "$stage"
}

# ── --source-info is dispatched HERE, ahead of everything that prints ──────────────────────
# Its stdout is consumed by `eval` in release-mac.sh, so it must emit the six assignments and
# NOTHING else. GATE 0 below prints a banner, which would be eval'd as commands — hence this
# runs first and carries its own pin check.
# (--source-tarball is dispatched further down: it calls fetch_source(), defined after GATE 0.)
if [ "$MODE" = "sourceinfo" ]; then
    [ -n "$FFMPEG_COMMIT" ] || die "FFMPEG_COMMIT is empty — bootstrap the pin first"
    printf 'FFMPEG_TAG=%s\n'      "$FFMPEG_TAG"
    printf 'FFMPEG_COMMIT=%s\n'   "$FFMPEG_COMMIT"
    printf 'FFMPEG_SHORT=%s\n'    "$FFMPEG_SHORT"
    printf 'SOURCE_FILENAME=%s\n' "$SOURCE_FILENAME"
    printf 'SOURCE_OBJECT=%s\n'   "$SOURCE_OBJECT"
    printf 'SOURCE_URL=%s\n'      "$SOURCE_URL"
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════════════════
# MODE: bootstrap — resolve the tag to a commit SHA and stop
# ══════════════════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "bootstrap" ]; then
    head2 "PIN BOOTSTRAP — resolving ${FFMPEG_TAG} to a commit SHA"
    say "  Nothing will be built and nothing will be staged."
    say ""
    resolved=""
    for remote in "$FFMPEG_REPO" "$FFMPEG_REPO_MIRROR"; do
        say "  querying ${remote} …"
        # ^{} dereferences an annotated tag to the commit it points at. Without it an annotated
        # tag resolves to the TAG OBJECT's sha, which is not what `git checkout` lands on and
        # would fail the assertion on every subsequent run.
        resolved="$(git ls-remote "$remote" "refs/tags/${FFMPEG_TAG}^{}" 2>/dev/null | awk '{print $1}' | head -1 || true)"
        [ -z "$resolved" ] && resolved="$(git ls-remote "$remote" "refs/tags/${FFMPEG_TAG}" 2>/dev/null | awk '{print $1}' | head -1 || true)"
        [ -n "$resolved" ] && break
    done
    [ -n "$resolved" ] || die "could not resolve ${FFMPEG_TAG} from either remote. Network?"

    ok "${FFMPEG_TAG} = ${resolved}"
    say ""
    say "  Paste that into this script:"
    say ""
    say "      FFMPEG_COMMIT=\"${resolved}\""
    say ""
    say "  Then re-run without FFMPEG_PIN_BOOTSTRAP to build."
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════════════════
# MODE: reloc — prove the app carries no dependency on any build-tree path
# ══════════════════════════════════════════════════════════════════════════════════════════
#
# THE FAILURE MODE THIS EXISTS FOR IS INVISIBLE ON THE BUILD MACHINE. If a dylib's install_name
# is an absolute path into the build prefix, the app resolves it here — the path exists — and
# fails to launch on every other machine. otool -L reads the RECORDED STRINGS and can tell you
# the path looks wrong, but it cannot tell you what dyld would actually do.
#
# So this mode makes the absolute path UNRESOLVABLE and then launches: the build prefix and the
# staging directory are both moved aside, which is precisely what a second machine looks like to
# dyld. DYLD_PRINT_LIBRARIES then reports where each image REALLY loaded from.
#
# Requires no second machine and no second user account.
if [ "$MODE" = "reloc" ]; then
    [ -n "$RELOC_APP" ] || die "--verify-relocatable needs a path to Manifold.app"
    [ -d "$RELOC_APP" ] || die "not a bundle: ${RELOC_APP}"
    APP_BIN="${RELOC_APP}/Contents/MacOS/Manifold"
    [ -f "$APP_BIN" ] || die "no executable at ${APP_BIN}"

    head2 "RELOCATABILITY — static inspection"

    # (1) Nothing anywhere in the bundle may name a path outside the system directories.
    scanned=0
    while IFS= read -r macho; do
        scanned=$((scanned + 1))
        deps="$(otool -L "$macho" 2>/dev/null || true)"
        foreign="$(find_lines "$deps" '^[[:space:]]+/(Users|opt|usr/local|private|tmp|Volumes)')"
        if [ -n "$foreign" ]; then
            fail "$(basename "$macho") loads from outside the system/bundle:"
            sed 's/^/        /' <<<"$foreign"
        fi
    done < <(find "${RELOC_APP}/Contents/MacOS" "${RELOC_APP}/Contents/Frameworks" -type f 2>/dev/null)
    [ "$FAIL" -eq 0 ] && ok "otool -L: ${scanned} Mach-O(s), no /Users, /opt, /usr/local or /Volumes path"

    # (2) Every libav reference from the main binary must be @rpath-relative.
    main_deps="$(otool -L "$APP_BIN")"
    libav_refs="$(find_lines "$main_deps" 'lib(avcodec|avformat|avutil|swscale|swresample)')"
    if [ -z "$libav_refs" ]; then
        fail "the main binary references NO libav dylib — is this a static build?"
    else
        while IFS= read -r ref; do
            case "$ref" in
                *@rpath/*) ;;
                *) fail "libav reference is not @rpath-relative:${ref}" ;;
            esac
        done <<<"$libav_refs"
        [ "$FAIL" -eq 0 ] && ok "every libav reference from the main binary is @rpath-relative"
    fi

    # (3) The rpath that resolves them must be present.
    rpaths="$(otool -l "$APP_BIN" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}')"
    if has_line "$rpaths" '^@executable_path/\.\./Frameworks$'; then
        ok "LC_RPATH @executable_path/../Frameworks present"
    else
        fail "LC_RPATH @executable_path/../Frameworks is MISSING. Found: ${rpaths//$'\n'/ }"
    fi

    head2 "RELOCATABILITY — the dyld test (the one that actually proves it)"
    say "  Moving the build prefix and the staging directory aside, so NO path outside the"
    say "  bundle can satisfy a libav load. This is what a second machine looks like to dyld."
    say ""

    moved=()
    restore() {
        for m in "${moved[@]:-}"; do
            [ -n "$m" ] && [ -d "${m}.away" ] && mv "${m}.away" "$m"
        done
    }
    trap restore EXIT
    for d in "${PREFIX}" "${DEST}/lib"; do
        if [ -d "$d" ]; then mv "$d" "${d}.away"; moved+=("$d"); ok "moved aside: ${d}"; fi
    done

    # Run from a copy OUTSIDE the build tree, carrying a quarantine xattr, exactly as a
    # downloaded build would. TMPDIR is per-user and outside the repo.
    RUN_DIR="$(mktemp -d)"
    cp -R "$RELOC_APP" "${RUN_DIR}/"
    RUN_APP="${RUN_DIR}/$(basename "$RELOC_APP")"
    xattr -w com.apple.quarantine "0081;00000000;Manifold;" "$RUN_APP" 2>/dev/null || \
        warn "could not set the quarantine xattr (non-fatal)"
    ok "copied to ${RUN_APP} (quarantined)"

    say ""
    say "  launching with DYLD_PRINT_LIBRARIES=1 …"
    DYLD_LOG="${RUN_DIR}/dyld.log"
    set +e
    DYLD_PRINT_LIBRARIES=1 "${RUN_APP}/Contents/MacOS/Manifold" >"$DYLD_LOG" 2>&1 &
    launch_pid=$!
    # Long enough for dyld to finish loading and for a load failure to have killed it. A dylib
    # that cannot be found is fatal at launch and immediate — this is not a race.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$launch_pid" 2>/dev/null || break
        /bin/sleep 0.5
    done
    still_running=0
    kill -0 "$launch_pid" 2>/dev/null && still_running=1
    [ "$still_running" = "1" ] && kill "$launch_pid" 2>/dev/null
    wait "$launch_pid" 2>/dev/null
    set -e

    DYLD_OUT="$(cat "$DYLD_LOG" 2>/dev/null || true)"
    loaded_libav="$(find_lines "$DYLD_OUT" 'lib(avcodec|avformat|avutil|swscale|swresample)')"

    if [ "$still_running" = "1" ]; then
        ok "the app LAUNCHED and stayed up with every build-tree path unavailable"
    else
        fail "the app did NOT stay up. Output:"
        sed 's/^/        /' <<<"${DYLD_OUT:-<none>}"
    fi

    if [ -n "$loaded_libav" ]; then
        say ""
        say "  libav images dyld actually loaded:"
        sed 's/^/        /' <<<"$loaded_libav"
        outside="$(find_lines "$loaded_libav" '(manifold-ffmpeg|ThirdParty|/opt/|/usr/local/)')"
        if [ -n "$outside" ]; then
            fail "an image loaded from OUTSIDE the bundle:"
            sed 's/^/        /' <<<"$outside"
        else
            ok "every libav image loaded from inside the app bundle"
        fi
    else
        warn "DYLD_PRINT_LIBRARIES reported no libav image — hardened runtime strips DYLD_* on"
        warn "signed binaries, so this is expected for a SIGNED build. The launch result above"
        warn "is still decisive: with the build tree moved aside, an absolute install_name"
        warn "could not have resolved."
    fi

    restore; trap - EXIT
    rm -rf "$RUN_DIR"
    say ""
    [ "$FAIL" -eq 0 ] && { ok "RELOCATABLE — no dependency on any build-tree path"; exit 0; }
    die "the app is NOT relocatable — see ✗ above"
fi

# ══════════════════════════════════════════════════════════════════════════════════════════
# GATE 0 — the pin must be set (every mode below this point needs source)
# ══════════════════════════════════════════════════════════════════════════════════════════

if [ "$MODE" != "verify" ]; then
    head2 "GATE 0: source pin"
    if [ -z "$FFMPEG_COMMIT" ]; then
        say ""
        bad "FFMPEG_COMMIT is empty — this build has NO source pin."
        say ""
        say "      The tree this script replaces was an extracted tarball with no .git, no tag"
        say "      and no checksum, so a rebuild could silently pick up different source. That"
        say "      is the single largest risk in this rebuild, ahead of anything about linkage."
        say ""
        say "      Resolve the pin once, then paste it into this script:"
        say ""
        say "          FFMPEG_PIN_BOOTSTRAP=1 ${BASH_SOURCE[0]}"
        say ""
        die "refusing to build without a source pin"
    fi
    [[ "$FFMPEG_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "FFMPEG_COMMIT is not a 40-hex-digit SHA: ${FFMPEG_COMMIT}"
    ok "pinned to ${FFMPEG_TAG} = ${FFMPEG_COMMIT}"
fi

# ══════════════════════════════════════════════════════════════════════════════════════════
# Fetch the source at the pin
# ══════════════════════════════════════════════════════════════════════════════════════════

fetch_source() {
    head2 "SOURCE: ${FFMPEG_TAG} @ ${FFMPEG_COMMIT:0:12}"
    mkdir -p "$WORK"

    if [ ! -d "${SRC}/.git" ]; then
        rm -rf "$SRC"
        local cloned=0
        for remote in "$FFMPEG_REPO" "$FFMPEG_REPO_MIRROR"; do
            say "  cloning ${remote} (tag ${FFMPEG_TAG}) …"
            if git clone --depth 1 --branch "$FFMPEG_TAG" "$remote" "$SRC" 2>&1 | sed 's/^/      /'; then
                cloned=1; break
            fi
            rm -rf "$SRC"
        done
        [ "$cloned" = "1" ] || die "could not clone ${FFMPEG_TAG} from either remote"
    else
        ok "reusing existing checkout at ${SRC}"
    fi

    # ── THE PIN ASSERTION. This is the whole point of the pin: not that we ASKED for a tag,
    #    but that the tree on disk IS the commit we recorded. A moved tag, a stale checkout or
    #    a hand-edited working tree all fail here, before a single object is compiled.
    local head_sha
    head_sha="$(git -C "$SRC" rev-parse HEAD)"
    if [ "$head_sha" != "$FFMPEG_COMMIT" ]; then
        bad "SOURCE PIN MISMATCH"
        say "      expected: ${FFMPEG_COMMIT}"
        say "      on disk:  ${head_sha}"
        say ""
        say "      The tag may have moved, or ${SRC} is a stale checkout. Delete it and re-run,"
        say "      or re-bootstrap the pin if the move was intentional."
        die "refusing to build from unpinned source"
    fi
    ok "HEAD == the pinned commit"

    # The working tree must also be clean — a pin on HEAD says nothing about local edits.
    local dirty
    dirty="$(git -C "$SRC" status --porcelain --untracked-files=no)"
    if [ -n "$dirty" ]; then
        bad "the checkout has UNCOMMITTED MODIFICATIONS:"
        sed 's/^/        /' <<<"$dirty"
        die "refusing to build from a modified source tree"
    fi
    ok "working tree clean (no local modifications to tracked files)"

    # RELEASE, not VERSION. VERSION exists in NEITHER tree — it is a build artifact, and the
    # 8.1.1 visible in the legacy directory came from RELEASE all along. RELEASE is git-tracked,
    # so the commit pin already covers it; this is a cheap human-readable cross-check that the
    # SHA points where we think it does.
    local ver
    ver="$(cat "${SRC}/RELEASE" 2>/dev/null || echo '<none>')"
    [ "$ver" = "8.1.1" ] || die "RELEASE reads '${ver}', expected 8.1.1 — the pin does not point at n8.1.1"
    ok "RELEASE reads ${ver}"
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# PROVENANCE DIFF — one-time, against the by-hand tree that produced the shipping archives
# ══════════════════════════════════════════════════════════════════════════════════════════
#
# WHAT THIS ANSWERS, AND WHY IT IS WORTH A MINUTE. The archives shipping in 0.5.1 were built
# from an extracted tarball with no VCS metadata. Nothing suggests it was patched — but nothing
# could PROVE it wasn't, and this is the last moment at which the question can be settled: once
# the .a files are replaced, the old tree is the only remaining evidence and it is untracked.
#
# Method: for every file git tracks at the pinned commit, compare bytes against the legacy tree.
# Comparing git-tracked files ONLY is deliberate — the legacy tree also holds build outputs
# (config.h, ffbuild/, *.o) which are expected to differ and would drown the signal.
provenance_diff() {
    head2 "PROVENANCE — pinned upstream vs. the by-hand tree that built 0.5.1"

    if [ ! -d "$LEGACY_TREE" ]; then
        warn "legacy tree not found at ${LEGACY_TREE} — nothing to compare against."
        warn "This is not a failure; it just means the question cannot be settled on this machine."
        return 0
    fi
    say "  legacy: ${LEGACY_TREE}"
    say "  pinned: ${SRC} @ ${FFMPEG_COMMIT:0:12}"
    say ""

    local tracked total=0 differing=0 absent=0
    local -a diff_list=() absent_list=()
    tracked="$(git -C "$SRC" ls-files)"

    while IFS= read -r f; do
        total=$((total + 1))
        if [ ! -f "${LEGACY_TREE}/${f}" ]; then
            absent=$((absent + 1)); absent_list+=("$f"); continue
        fi
        if ! cmp -s "${SRC}/${f}" "${LEGACY_TREE}/${f}"; then
            differing=$((differing + 1)); diff_list+=("$f")
        fi
    done <<<"$tracked"

    say "  compared ${total} git-tracked files"
    say ""

    if [ "$differing" -eq 0 ] && [ "$absent" -eq 0 ]; then
        ok "IDENTICAL — the by-hand tree was unmodified upstream ${FFMPEG_TAG}"
        say ""
        say "      This retroactively establishes that the static archives shipping in 0.5.1"
        say "      were built from unpatched upstream source — a fact that was NOT available"
        say "      before this run, because that tree carries no VCS metadata."
        printf '%s\n' "$FFMPEG_COMMIT" > "${WORK}/.provenance-verified"
        return 0
    fi

    bad "THE TREES DIFFER — stopping before anything is built"
    say ""
    if [ "$differing" -gt 0 ]; then
        say "      ${differing} file(s) differ in content:"
        printf '        %s\n' "${diff_list[@]:0:40}"
        [ "$differing" -gt 40 ] && say "        … and $((differing - 40)) more"
        say ""
    fi
    if [ "$absent" -gt 0 ]; then
        say "      ${absent} file(s) tracked upstream but ABSENT from the legacy tree:"
        printf '        %s\n' "${absent_list[@]:0:40}"
        [ "$absent" -gt 40 ] && say "        … and $((absent - 40)) more"
        say ""
    fi
    say "      This means the currently-shipping archives are NOT plain upstream ${FFMPEG_TAG}."
    say "      Understand WHY before rebuilding — a local patch that nobody recorded is exactly"
    say "      the kind of thing a rebuild silently discards. Inspect a specific file with:"
    say ""
    say "          diff -u '${LEGACY_TREE}/<file>' '${SRC}/<file>'"
    say ""
    die "provenance diff is dirty — reporting rather than building"
}

if [ "$MODE" = "provenance" ]; then
    fetch_source
    provenance_diff
    say ""
    ok "provenance check complete — nothing was built"
    exit 0
fi

if [ "$MODE" = "tarball" ]; then
    fetch_source
    make_source_tarball "$TARBALL_OUT"
    say ""
    ok "source tarball ready"
    say "  object : ${SOURCE_OBJECT}"
    say "  url    : ${SOURCE_URL}"
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════════════════
# CONFIGURE + BUILD + INSTALL
# ══════════════════════════════════════════════════════════════════════════════════════════

configure_and_build() {
    head2 "CONFIGURE"
    say "  prefix : ${PREFIX}"
    say "  arch   : ${ARCH} only, macOS ${MACOS_MIN} minimum"
    say ""
    printf '  ./configure'
    printf ' %s' "${CONFIGURE_ARGS[@]}"
    printf '\n\n'

    # Purge the previous install so a failed build cannot leave a stale artifact that later
    # steps then stage and verify. Same reasoning as the libsrt script's prefix purge.
    rm -rf "$PREFIX"
    mkdir -p "$PREFIX"

    cd "$SRC"
    # A configured tree from a DIFFERENT configure line is the classic stale-build trap: the
    # command line is right, the artifact is not. distclean makes the tree's state a function of
    # this run alone. It is cheap next to the compile it precedes.
    [ -f ffbuild/config.mak ] && { say "  (distclean — a previously configured tree is present)"; make distclean >/dev/null 2>&1 || true; }

    # NOTHING VIA HOMEBREW. Same isolation requirement as the other three build scripts. FFmpeg's
    # configure does not search prefixes the way CMake does, but --disable-autodetect is what
    # actually guarantees it: no external library is probed for at all, so there is no lookup for
    # a Homebrew copy to win. Asserted afterwards by the zlib/bzlib/iconv checks in LAYER 2.
    # NOTHING is passed here that is not in CONFIGURE_ARGS. That is the whole contract: the
    # array is what LAYER 1 asserts, so a flag added on this line would be invisible to the
    # check that exists to catch exactly that. (It did catch it — see the CHANGE 4 note.)
    if ! ./configure "${CONFIGURE_ARGS[@]}" > "${WORK}/configure.log" 2>&1; then
        tail -40 "${WORK}/configure.log" >&2
        die "configure failed — full log: ${WORK}/configure.log"
    fi
    ok "configure succeeded (log: ${WORK}/configure.log)"

    # ── LAYER 1, RUN NOW — before the compile, not after ────────────────────
    # config.mak records configure's own view of its invocation (FFMPEG_CONFIGURATION, written
    # at configure:8525). Asserting here means a drifted line costs seconds, not a full build.
    head2 "LAYER 1: the configure line"
    local recorded
    recorded="$(sed -nE 's/^FFMPEG_CONFIGURATION=(.*)$/\1/p' "${SRC}/ffbuild/config.mak")"
    [ -n "$recorded" ] || die "could not read FFMPEG_CONFIGURATION from ffbuild/config.mak"
    assert_config_line "$recorded" "ffbuild/config.mak" || die "configure line drift — nothing built"

    assert_config_h

    head2 "BUILD"
    say "  make -j$(sysctl -n hw.ncpu) … (log: ${WORK}/make.log)"
    if ! make -j"$(sysctl -n hw.ncpu)" > "${WORK}/make.log" 2>&1; then
        tail -40 "${WORK}/make.log" >&2
        die "make failed — full log: ${WORK}/make.log"
    fi
    ok "build succeeded"

    if ! make install > "${WORK}/make-install.log" 2>&1; then
        tail -40 "${WORK}/make-install.log" >&2
        die "make install failed — full log: ${WORK}/make-install.log"
    fi
    ok "installed into ${PREFIX}"
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# LAYER 2 — the OUTCOME, read from config.h / config_components.h
# ══════════════════════════════════════════════════════════════════════════════════════════
#
# WHY THIS EXISTS SEPARATELY FROM LAYER 1. A correct command line against a stale or partially
# reconfigured tree produces a WRONG artifact and a PASSING string check. Layer 1 tests what was
# asked for; this tests what was actually configured.
#
# The negative sweeps are the important half. They are written as sweeps rather than blocklists
# so that a component added by a FUTURE FFmpeg — one nobody thought to list here — still fails
# the check instead of slipping through.
assert_config_h() {
    head2 "LAYER 2: the configured outcome (config.h)"
    local ch="${SRC}/config.h" cc="${SRC}/config_components.h"
    [ -f "$ch" ] || die "no config.h at ${ch}"
    [ -f "$cc" ] || die "no config_components.h at ${cc}"

    local defs
    defs="$(cat "$ch" "$cc")"

    # ── Scalars, each with the reason it is asserted ────────────────────────
    local -a want=(
        "CONFIG_SHARED 1"      # CHANGE 1 — the LGPL §6 change itself
        "CONFIG_STATIC 0"      # CHANGE 1 — and its other half
        "CONFIG_NETWORK 0"     # LOAD-BEARING. libavformat must never open a socket.
        "CONFIG_GPL 0"         # LGPL, not GPL. Manifold's own source stays proprietary.
        "CONFIG_NONFREE 0"
        "CONFIG_VERSION3 0"    # LGPL 2.1, not 3 — the licence the About panel ships
        "CONFIG_GPLV3 0"
        "CONFIG_PIC 1"         # stronger than passing --enable-pic; see the NOT ADDED note
        "CONFIG_SWSCALE 1"
        "CONFIG_AVCODEC 1"
        "CONFIG_AVFORMAT 1"
        "CONFIG_SWRESAMPLE 1"
        "CONFIG_ZLIB 0"        # --disable-autodetect: no external library was probed for,
        "CONFIG_BZLIB 0"       # so no Homebrew copy can have been picked up. These three are
        "CONFIG_ICONV 0"       # the observable proof of that.
        "CONFIG_LZMA 0"
    )
    local w name val
    for w in "${want[@]}"; do
        name="${w%% *}"; val="${w##* }"
        if has_line "$defs" "^#define ${name} ${val}\$"; then
            ok "${name} = ${val}"
        else
            local got
            got="$(find_lines "$defs" "^#define ${name} " | awk '{print $3}' | head -1)"
            fail "${name} is '${got:-<undefined>}', expected '${val}'"
        fi
    done

    # ── Component sets: exact, both directions ─────────────────────────────
    assert_component_set "$defs" DECODER  "${EXPECTED_DECODERS[*]}"
    assert_component_set "$defs" DEMUXER  "${EXPECTED_DEMUXERS[*]}"
    assert_component_set "$defs" PARSER   "${EXPECTED_PARSERS[*]}"
    assert_component_set "$defs" PROTOCOL "${EXPECTED_PROTOCOLS[*]}"

    # ── Categories that must be entirely empty ─────────────────────────────
    # A muxer or encoder would mean --disable-everything stopped meaning what it says. The BSF
    # sweep is included because the baseline build had none: if adding the prores decoder ever
    # drags one in, that is a real change to the artifact and we want to be told, not protected.
    local cat n
    for cat in MUXER ENCODER BSF; do
        n="$(find_lines "$defs" "^#define CONFIG_[A-Z0-9_]+_${cat} 1\$" | wc -l | tr -d ' ')"
        if [ "$n" = "0" ]; then
            ok "no ${cat}s enabled"
        else
            fail "${n} ${cat}(s) are enabled and should not be:"
            find_lines "$defs" "^#define CONFIG_[A-Z0-9_]+_${cat} 1\$" | sed 's/^/        /'
        fi
    done

    [ "$FAIL" -eq 0 ] || die "LAYER 2 failed — the configured build is not the one this script describes"
}

# assert_component_set <defs> <CATEGORY> <space-separated expected set>
# The expected set arrives as a flat string (no element contains a space) rather than by
# nameref — bash 3.2, see major_for above.
assert_component_set() {
    local defs="$1" cat="$2" expected="$3"

    local actual want got missing extra
    actual="$(find_lines "$defs" "^#define CONFIG_[A-Z0-9_]+_${cat} 1\$" \
              | sed -E "s/^#define CONFIG_(.*)_${cat} 1\$/\1/" \
              | tr 'A-Z' 'a-z' | sort)"
    want="$(tr ' ' '\n' <<<"$expected" | grep -v '^$' | sort)"

    missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$actual") || true)"
    extra="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$actual") || true)"

    if [ -z "$missing" ] && [ -z "$extra" ]; then
        got="$(tr '\n' ' ' <<<"$actual")"
        ok "${cat}s exactly: ${got%% }"
        return 0
    fi
    fail "${cat} set does not match"
    [ -n "$missing" ] && { say "        expected but MISSING: $(tr '\n' ' ' <<<"$missing")"; }
    [ -n "$extra" ]   && { say "        UNEXPECTEDLY enabled: $(tr '\n' ' ' <<<"$extra")"; }
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# STAGE into the repo
# ══════════════════════════════════════════════════════════════════════════════════════════
#
# make install writes the real file as libavcodec.62.3.100.dylib with two symlinks
# (SLIB_INSTALL_NAME=$(SLIBNAME_WITH_VERSION), SLIB_INSTALL_LINKS=$(SLIBNAME_WITH_MAJOR)
# $(SLIBNAME)). What we stage is narrower and deliberate:
#
#   libavcodec.62.dylib   REAL FILE. Named for the major, because that is exactly the string
#                         baked into its install_name (@rpath/libavcodec.62.dylib) and what
#                         dyld will look for inside Contents/Frameworks. This is the file the
#                         embed phase copies into the bundle.
#   libavcodec.dylib      SYMLINK, LINK TIME ONLY, never embedded. `-lavcodec` in
#                         OTHER_LDFLAGS searches for libavcodec.dylib and would not find a
#                         major-suffixed name. The linker follows it, reads the install_name
#                         off the real file, and records @rpath/libavcodec.62.dylib.
#
# Nothing with a full x.y.z version is staged: three names for one file is three things to keep
# in sync, and the bundle only ever wants one.
stage() {
    head2 "STAGE into ThirdParty/ffmpeg"

    # ⚠️ PURGE FIRST, AND PURGE THE ARCHIVES. If a stale libavcodec.a survives here, `-lavcodec`
    # resolves to the DYLIB when both exist — so the app would look correct — but the leftover
    # archives are exactly how a half-finished migration comes back later. More importantly, if
    # this build had failed midway, stale .a files would let the app keep linking statically and
    # silently stay out of LGPL §6 compliance.
    rm -rf "${DEST}/lib" "${DEST}/include"
    mkdir -p "${DEST}/lib" "${DEST}/include"

    local l major src
    for l in "${LIBS[@]}"; do
        major="$(major_for "$l")"
        src="${PREFIX}/lib/lib${l}.${major}.dylib"
        [ -e "$src" ] || die "expected ${src} — did the shared build actually produce it?"
        # cp (not cp -P) follows the symlink and copies the real file's bytes.
        cp "$src" "${DEST}/lib/lib${l}.${major}.dylib"
        ln -sf "lib${l}.${major}.dylib" "${DEST}/lib/lib${l}.dylib"
        ok "lib${l}.${major}.dylib  (+ lib${l}.dylib -> it)"
    done

    cp -R "${PREFIX}/include/." "${DEST}/include/"
    ok "headers"

    # The headers of libraries we do NOT ship must not be staged either — a header for a dylib
    # that is not in the bundle is an invitation to write code that cannot link.
    rm -rf "${DEST}/include/libavdevice" "${DEST}/include/libavfilter"
    ok "libavdevice / libavfilter headers removed (those dylibs are built but not shipped)"

    local strays
    strays="$(find "${DEST}/lib" -name '*.a' -print)"
    [ -z "$strays" ] || die "static archives survived the purge: ${strays}"
    ok "no .a remains in ThirdParty/ffmpeg/lib"
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# LAYER 3 — interrogate the SHIPPED DYLIBS at runtime
# ══════════════════════════════════════════════════════════════════════════════════════════
#
# This is what replaces the dead nm recipes, and it is stronger than they ever were. It builds a
# probe against the STAGED dylibs — the exact files the embed phase will copy into the bundle —
# and asks libavformat/libavcodec to enumerate themselves.
#
# The protocol enumeration in particular is the best available statement of the --disable-network
# invariant: not "ff_file_protocol appears in a symbol table" but "this library, asked to list
# every protocol it can open, answers `file` and stops".
#
# It also reads avutil_configuration() back out of the dylib and runs it through the SAME
# LAYER 1 assertion. That closes the last gap between the three layers: layers 1 and 2 describe a
# BUILD TREE, and this proves the SHIPPED BINARY came from that tree rather than from a stale
# staging directory.
probe() {
    head2 "LAYER 3: interrogating the staged dylibs"

    mkdir -p "$PROBE_DIR"
    cat > "${PROBE_DIR}/probe.c" <<'PROBE'
/* Interrogates the STAGED libav dylibs. Emits one machine-readable record per line;
   scripts/build_ffmpeg.sh asserts on them. Deliberately uses only public API — the
   whole point is that this is what a shipped dylib still exposes. */
#include <stdio.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/mastering_display_metadata.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

int main(void) {
    void *o;
    const AVInputFormat *ifmt;
    const AVOutputFormat *ofmt;
    const AVCodec *c;
    const AVCodecParser *p;
    const char *name;

    printf("CONFIGURATION\t%s\n", avutil_configuration());
    printf("LICENSE\t%s\n", avutil_license());

    printf("VERSION\tavcodec\t%u\n",    avcodec_version()    >> 16);
    printf("VERSION\tavformat\t%u\n",   avformat_version()   >> 16);
    printf("VERSION\tavutil\t%u\n",     avutil_version()     >> 16);
    printf("VERSION\tswscale\t%u\n",    swscale_version()    >> 16);
    printf("VERSION\tswresample\t%u\n", swresample_version() >> 16);

    o = NULL; while ((ifmt = av_demuxer_iterate(&o))) printf("DEMUXER\t%s\n", ifmt->name);
    o = NULL; while ((ofmt = av_muxer_iterate(&o)))   printf("MUXER\t%s\n",   ofmt->name);

    o = NULL;
    while ((c = av_codec_iterate(&o))) {
        if (av_codec_is_decoder(c)) printf("DECODER\t%s\n", c->name);
        if (av_codec_is_encoder(c)) printf("ENCODER\t%s\n", c->name);
    }

    o = NULL;
    while ((p = av_parser_iterate(&o))) {
        for (int i = 0; i < AV_PARSER_PTS_NB && p->codec_ids[i]; i++) {
            const AVCodecDescriptor *d = avcodec_descriptor_get(p->codec_ids[i]);
            printf("PARSER\t%s\n", d ? d->name : "?");
        }
    }

    /* THE --disable-network ASSERTION, from the artifact itself. */
    o = NULL; while ((name = avio_enum_protocols(&o, 0))) printf("PROTOCOL_IN\t%s\n",  name);
    o = NULL; while ((name = avio_enum_protocols(&o, 1))) printf("PROTOCOL_OUT\t%s\n", name);

    /* The five consumers, reduced to the API surface each one needs. A dylib that enumerates
       correctly but cannot hand back these entry points is still broken. */
    printf("CONSUMER\tdnxhd_decoder\t%d\n",  avcodec_find_decoder_by_name("dnxhd")  != NULL);
    printf("CONSUMER\tprores_decoder\t%d\n", avcodec_find_decoder_by_name("prores") != NULL);
    printf("CONSUMER\taac_decoder\t%d\n",    avcodec_find_decoder_by_name("aac")    != NULL);
    printf("CONSUMER\tavio_alloc_context\t%d\n", avio_alloc_context != NULL);
    printf("CONSUMER\tsws_getContext\t%d\n",     sws_getContext     != NULL);
    printf("CONSUMER\tswr_alloc\t%d\n",          swr_alloc          != NULL);
    /* HDR10: the side-data types FrameEngine reads. These are libavutil ENUM + STRUCT surface
       crossing the dylib boundary, which is the part most exposed to a version mismatch. */
    printf("CONSUMER\thdr10_mastering\t%d\n",
           av_mastering_display_metadata_alloc != NULL && AV_FRAME_DATA_MASTERING_DISPLAY_METADATA >= 0);
    printf("CONSUMER\thdr10_light_level\t%d\n",
           av_content_light_metadata_alloc != NULL && AV_FRAME_DATA_CONTENT_LIGHT_LEVEL >= 0);
    return 0;
}
PROBE

    # -rpath at the staging directory so the probe resolves the @rpath install_names exactly as
    # the app will resolve them from Contents/Frameworks. If CHANGE 3 did not take, this link or
    # this run is where it shows up first.
    if ! clang "${PROBE_DIR}/probe.c" -o "${PROBE_DIR}/probe" \
            -I "${DEST}/include" -L "${DEST}/lib" \
            -lavformat -lavcodec -lavutil -lswscale -lswresample \
            -Wl,-rpath,"${DEST}/lib" \
            -mmacosx-version-min="${MACOS_MIN}" 2>"${PROBE_DIR}/probe-build.log"; then
        sed 's/^/      /' "${PROBE_DIR}/probe-build.log" >&2
        die "the probe failed to link against the staged dylibs"
    fi
    ok "probe linked against the staged dylibs"

    local out
    out="$("${PROBE_DIR}/probe" 2>&1)" || { sed 's/^/      /' <<<"$out" >&2; die "the probe crashed"; }

    # ── The configure line, read back out of the SHIPPED artifact ──────────
    local cfg lic
    cfg="$(find_lines "$out" "^CONFIGURATION"$'\t' | cut -f2-)"
    lic="$(find_lines "$out" "^LICENSE"$'\t' | cut -f2-)"
    assert_config_line "$cfg" "avutil_configuration(), read from the staged dylib" || true
    if [ "$lic" = "LGPL version 2.1 or later" ]; then
        ok "avutil_license() = ${lic}"
    else
        fail "avutil_license() = '${lic}', expected 'LGPL version 2.1 or later'"
    fi

    # ── Majors must match the staged filenames ─────────────────────────────
    local l got want_major
    for l in "${LIBS[@]}"; do
        want_major="$(major_for "$l")"
        got="$(find_lines "$out" "^VERSION"$'\t'"${l}"$'\t' | cut -f3)"
        if [ "$got" = "$want_major" ]; then
            ok "lib${l} reports major ${got}"
        else
            fail "lib${l} reports major '${got}', but it is staged as lib${l}.${want_major}.dylib"
        fi
    done

    assert_probe_set "$out" DEMUXER      "${EXPECTED_RUNTIME_DEMUXERS[*]}"
    assert_probe_set "$out" DECODER      "${EXPECTED_DECODERS[*]}"
    assert_probe_set "$out" PROTOCOL_IN  "${EXPECTED_PROTOCOLS[*]}"
    assert_probe_set "$out" PROTOCOL_OUT "${EXPECTED_PROTOCOLS[*]}"

    local n
    for cat in MUXER ENCODER; do
        n="$(find_lines "$out" "^${cat}"$'\t' | wc -l | tr -d ' ')"
        if [ "$n" = "0" ]; then ok "the dylibs expose no ${cat}s"
        else fail "${n} ${cat}(s) exposed by the shipped dylibs"; fi
    done

    if has_line "$out" "^PARSER"$'\t'"h264$"; then ok "h264 parser registered"
    else fail "the h264 parser is NOT registered — the SRT path needs it"; fi

    # ── The five consumers ─────────────────────────────────────────────────
    local c v
    for c in dnxhd_decoder prores_decoder aac_decoder avio_alloc_context sws_getContext \
             swr_alloc hdr10_mastering hdr10_light_level; do
        v="$(find_lines "$out" "^CONSUMER"$'\t'"${c}"$'\t' | cut -f3)"
        if [ "$v" = "1" ]; then ok "consumer surface: ${c}"
        else fail "consumer surface MISSING: ${c}"; fi
    done

    printf '%s\n' "$out" > "${WORK}/probe-output.txt"
    say ""
    say "  full probe output: ${WORK}/probe-output.txt"
}

# assert_probe_set <probe-output> <RECORD-TAG> <space-separated expected set>
assert_probe_set() {
    local out="$1" tag="$2" expected="$3"
    local actual want missing extra

    actual="$(find_lines "$out" "^${tag}"$'\t' | cut -f2 | sort -u)"
    want="$(tr ' ' '\n' <<<"$expected" | grep -v '^$' | sort -u)"
    missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$actual") || true)"
    extra="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$actual") || true)"

    if [ -z "$missing" ] && [ -z "$extra" ]; then
        ok "${tag} exactly: $(tr '\n' ' ' <<<"$actual")"
        return 0
    fi
    fail "${tag} set does not match what the dylibs expose"
    [ -n "$missing" ] && say "        expected but MISSING: $(tr '\n' ' ' <<<"$missing")"
    [ -n "$extra" ]   && say "        UNEXPECTEDLY present: $(tr '\n' ' ' <<<"$extra")"
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# Mach-O verification of the staged dylibs
# ══════════════════════════════════════════════════════════════════════════════════════════

verify_macho() {
    head2 "MACH-O: install_name, dependencies, architecture"

    local l major f id deps foreign
    for l in "${LIBS[@]}"; do
        major="$(major_for "$l")"
        f="${DEST}/lib/lib${l}.${major}.dylib"

        # arm64 only, never universal — matched to the app target.
        local info; info="$(lipo -info "$f")"
        case "$info" in
            *"Non-fat file"*"is architecture: ${ARCH}") ;;
            *) fail "lib${l}: ${info}" ;;
        esac

        # ── THE install_name. CHANGE 3's entire purpose. ────────────────────
        id="$(otool -D "$f" | awk 'NR==2')"
        if [ "$id" = "@rpath/lib${l}.${major}.dylib" ]; then
            ok "lib${l}.${major}.dylib  id=${id}"
        else
            fail "lib${l}.${major}.dylib has install_name '${id}', expected '@rpath/lib${l}.${major}.dylib'"
            say "        This is the failure that WORKS ON THIS MACHINE and on no other."
            say "        --install-name-dir=@rpath did not take."
        fi

        # ── No absolute path may appear in ANY dependency record. Inter-library references
        #    (avcodec->avutil etc.) are recorded at link time from the dependency's install_name,
        #    so this is where a half-applied CHANGE 3 surfaces.
        deps="$(otool -L "$f" | tail -n +2)"
        foreign="$(find_lines "$deps" '^[[:space:]]+/(Users|opt|usr/local|private|tmp|Volumes)')"
        if [ -n "$foreign" ]; then
            fail "lib${l} depends on a build-tree/absolute path:"
            sed 's/^/        /' <<<"$foreign"
        fi

        # ── Nothing may depend on a library we do NOT ship. libavdevice and libavfilter are
        #    built by this configure and deliberately not staged; if one of the five ever grew a
        #    dependency on them the app would fail to launch with a missing-image error.
        local unstaged
        unstaged="$(find_lines "$deps" 'lib(avdevice|avfilter)')"
        [ -n "$unstaged" ] && { fail "lib${l} depends on an UNSTAGED library:"; sed 's/^/        /' <<<"$unstaged"; }
    done

    [ "$FAIL" -eq 0 ] && ok "every dependency record is @rpath-relative or a system path"

    say ""
    say "  dependency graph as recorded:"
    for l in "${LIBS[@]}"; do
        major="$(major_for "$l")"
        say "    lib${l}.${major}.dylib"
        otool -L "${DEST}/lib/lib${l}.${major}.dylib" | tail -n +2 | sed 's/^/      /'
    done

    # ── Homebrew leak scan, same as the other three build scripts ──────────
    local blob leaks
    blob="$(strings "${DEST}"/lib/*.dylib 2>/dev/null || true)"
    leaks="$(find_lines "$blob" '/opt/homebrew|/usr/local/(lib|include|opt)')"
    if [ -n "$leaks" ]; then
        fail "Homebrew/local paths found inside the dylibs:"
        sort -u <<<"$leaks" | sed 's/^/        /'
    else
        ok "no /opt/homebrew or /usr/local path inside the dylibs"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# Size report
# ══════════════════════════════════════════════════════════════════════════════════════════

report_sizes() {
    head2 "SIZE"
    # awk rather than bc: awk is guaranteed present (release-mac.sh already relies on it) and
    # this needs nothing bc offers.
    local total=0 l major f b
    for l in "${LIBS[@]}"; do
        major="$(major_for "$l")"
        f="${DEST}/lib/lib${l}.${major}.dylib"
        b="$(stat -f%z "$f")"
        total=$((total + b))
        awk -v n="lib${l}.${major}.dylib" -v b="$b" 'BEGIN{printf "    %-26s %8.2f MB  (%d bytes)\n", n, b/1048576, b}'
    done
    awk -v b="$total" 'BEGIN{printf "    %-26s %8.2f MB  (%d bytes)\n", "TOTAL (5 dylibs)", b/1048576, b}'
    say ""
    say "    For comparison, the static archives this replaces totalled 14.27 MB on disk,"
    say "    of which TEXT+DATA — the part that actually reaches a linked binary — was 4.43 MB."
    say "    The shipping 0.5.1 app binary was 7,830,016 B in a 8.6 MB bundle / 4.18 MB DMG."
}

# ══════════════════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════════════════

say ""
say "${BOLD}FFmpeg ${FFMPEG_TAG} — SHARED build for LGPL 2.1 §6 relinking${RESET}"
say "  repo   : ${REPO_ROOT}"
say "  work   : ${WORK}"
say "  dest   : ${DEST}"
say "  mode   : ${MODE}"

if [ "$MODE" = "build" ]; then
    for tool in git clang otool lipo; do
        command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: ${tool}"
    done
    fetch_source
    # One-time, and skipped once it has passed for this exact commit — the answer cannot change
    # while both the pin and the legacy tree stay put.
    if [ "$(cat "${WORK}/.provenance-verified" 2>/dev/null || true)" = "$FFMPEG_COMMIT" ]; then
        head2 "PROVENANCE"
        ok "already verified for ${FFMPEG_COMMIT:0:12} (${WORK}/.provenance-verified)"
    else
        provenance_diff
    fi
    configure_and_build
    stage
fi

if [ "$MODE" = "verify" ]; then
    for l in "${LIBS[@]}"; do
        [ -f "${DEST}/lib/lib${l}.$(major_for "$l").dylib" ] \
            || die "nothing staged: ${DEST}/lib/lib${l}.$(major_for "$l").dylib
       Run without --verify-only to build first."
    done
    # LAYER 2 needs the build tree; if it is gone, LAYER 3 still reads the configure line back
    # out of the dylib itself, which is the stronger of the two anyway.
    if [ -f "${SRC}/config.h" ]; then assert_config_h
    else warn "no build tree at ${SRC} — skipping LAYER 2; LAYER 3 still checks the artifact"; fi
fi

probe
verify_macho
report_sizes

say ""
if [ "$FAIL" -eq 0 ]; then
    say "${GREEN}${BOLD}DONE${RESET} — FFmpeg ${FFMPEG_TAG} staged as shared libraries in ${DEST}"
    say ""
    say "NEXT"
    say "  1. project.yml: the embed phase + LD_RUNPATH_SEARCH_PATHS (see ThirdParty/ffmpeg/README.md)"
    say "  2. xcodegen generate && build"
    say "  3. ./scripts/build_ffmpeg.sh --verify-relocatable <path/to/Manifold.app>"
    say "     ^ the check that catches the absolute-install_name failure WITHOUT a second Mac"
else
    die "verification FAILED — see ✗ above. Nothing here is safe to ship."
fi
