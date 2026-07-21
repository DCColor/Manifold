#!/bin/bash
#
# Build libdatachannel + its bundled deps as ISOLATED, arm64-only static libraries,
# against the Mbed TLS built by scripts/build_mbedtls.sh, and stage them into
# ThirdParty/libdatachannel/.
#
# STEP 2 of 2 — run scripts/build_mbedtls.sh FIRST.
#
#   ./scripts/build_libdatachannel.sh
#
# Produces:
#   ThirdParty/libdatachannel/lib/{libdatachannel,libjuice,libsrtp2,libusrsctp,
#                                  libmbedtls,libmbedx509,libmbedcrypto}.a
#   ThirdParty/libdatachannel/include/rtc/*.h
#
# ── NON-NEGOTIABLE PROPERTIES ───────────────────────────────────────────────
#  * NOTHING via Homebrew. Every dependency from source into an isolated prefix.
#  * CMake is forbidden from discovering /opt/homebrew and /usr/local.
#  * The prefix shares NO directory with ThirdParty/ffmpeg — the custom static
#    FFmpeg is never read or written.
#  * libdatachannel does NOT use FFmpeg (transport + depacketize only,
#    bring-your-own-decoder). If a configure step ever mentions avcodec/avformat/
#    avutil, STOP — that is a bug, and the script asserts against it below.
#  * DTLS backend is MBED TLS. There is no GnuTLS, nettle, gmp, libtasn1 or
#    OpenSSL anywhere in this build — see the rationale in build_mbedtls.sh.
#
set -euo pipefail

# ════════════════════════════════════════════════════════════════════════════
# PIPEFAIL-SAFE MATCHING HELPERS — read before touching any check below.
#
# `producer | grep -q pattern` is a FOOTGUN under `set -o pipefail`:
#   grep -q exits at the FIRST match and closes the read end of the pipe;
#   the producer (nm, strings) is still writing, takes SIGPIPE, and exits 141;
#   pipefail then reports 141 as the PIPELINE's status.
# So the check fails *precisely because the thing it looked for was found* — and
# only when the match comes early enough that the producer hasn't finished. A
# genuinely absent symbol lets the producer finish and exits 1, which looks
# identical. That false negative is what made this script report
#   "✗ Mbed TLS is MISSING DTLS-SRTP"
# against an archive that provably contained all three DTLS-SRTP symbols.
#
# `producer | grep ... | head` is the same shape but worse for the CONTAMINATION
# checks: head exits after N lines and SIGPIPEs upstream, so the pipeline reports
# failure and the check concludes CLEAN exactly when contamination is heaviest.
#
# Fix: capture the producer's output ONCE into a variable, then match with a
# here-string. A here-string is not a pipeline, so nothing can be SIGPIPEd and
# grep's own exit status is the only thing tested. Semantics are unchanged — these
# still fail correctly when a symbol is genuinely absent.
# ════════════════════════════════════════════════════════════════════════════

# has_line <text> <extended-regex>  -> 0 if the pattern occurs, 1 if not.
has_line() { grep -qE -- "$2" <<<"$1"; }

# find_lines <text> <extended-regex> -> prints matching lines (empty if none).
# `|| true` so "no match" (grep exit 1) is not fatal under `set -e`.
find_lines() { grep -E -- "$2" <<<"$1" || true; }

LDC_TAG="v0.24.5"             # libdatachannel — MPL-2.0

# ── Toolchain — MUST match Manifold's app target exactly ────────────────────
# Verified against `xcodebuild -showBuildSettings` for Debug, Release AND Profile:
#   ARCHS = arm64                 MACOSX_DEPLOYMENT_TARGET = 15.0
#   CLANG_CXX_LIBRARY = libc++    CLANG_CXX_LANGUAGE_STANDARD = c++17
# and against project.yml: `deploymentTarget: macOS: "15.0"`.
# 15.0 — NOT 13.0. Mismatching produces "built for newer macOS version than being
# linked" warnings at the Manifold link.
ARCH="arm64"                  # arm64 ONLY — never universal, never x86_64
MACOS_MIN="15.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/ThirdParty/libdatachannel"   # final home, in-repo (gitignored)
WORK="${HOME}/manifold-webrtc-build"            # space-free scratch
PREFIX="${WORK}/prefix"                         # ISOLATED prefix from build_mbedtls.sh

echo "── libdatachannel ${LDC_TAG} (WHEP WebRTC transport) ──────────────────"
echo "  repo    : ${REPO_ROOT}"
echo "  prefix  : ${PREFIX}"
echo "  dest    : ${DEST}"
echo "  arch    : ${ARCH} only"
echo "  min os  : macOS ${MACOS_MIN}"
echo "  dtls    : Mbed TLS (isolated, from ${PREFIX})"
echo "  cmake   : $(command -v cmake) ($(cmake --version 2>/dev/null | sed -n '1p'))"
echo

# ── Preflight: Mbed TLS must be present AND DTLS-SRTP-capable ──────────────
# The DTLS-SRTP check is duplicated from build_mbedtls.sh deliberately. Building
# libdatachannel against an Mbed TLS that cannot negotiate SRTP keys succeeds at
# link time and fails only when WHEP media should start, so this refuses to spend
# the compile at all rather than produce a subtly broken artifact.
if [ ! -f "${PREFIX}/lib/libmbedtls.a" ]; then
  echo "FATAL: ${PREFIX}/lib/libmbedtls.a not found."
  echo "       Run ./scripts/build_mbedtls.sh first."
  exit 1
fi
PREFIX_MBEDTLS_SYMS="$(nm -o "${PREFIX}/lib/libmbedtls.a" 2>/dev/null || true)"
if ! has_line "${PREFIX_MBEDTLS_SYMS}" 'mbedtls_ssl_conf_dtls_srtp_protection_profiles'; then
  echo "FATAL: ${PREFIX}/lib/libmbedtls.a has NO DTLS-SRTP support."
  echo "       WHEP media cannot work against this build. Re-run:"
  echo "         ./scripts/build_mbedtls.sh"
  echo "       and confirm it prints '✓ DTLS-SRTP' before returning here."
  exit 1
fi
echo "  Mbed TLS found in the isolated prefix, DTLS-SRTP present ✓"
echo

mkdir -p "${WORK}"
cd "${WORK}"

# --recursive supplies deps/{libjuice,libsrtp,usrsctp,plog,json} as submodules, so
# ICE/SRTP/SCTP need no separate build and no system packages whatsoever.
if [ ! -d libdatachannel ]; then
  git clone --depth 1 --branch "${LDC_TAG}" --recursive \
      https://github.com/paullouisageneau/libdatachannel.git libdatachannel
fi
cd libdatachannel
git fetch --depth 1 origin tag "${LDC_TAG}" 2>/dev/null || true
git checkout -q "${LDC_TAG}"
git submodule update --init --recursive --depth 1

# ── Configure ───────────────────────────────────────────────────────────────
# BUILD_SHARED_LIBS=OFF makes the `datachannel` target itself a static archive,
# gives it RTC_STATIC as a PUBLIC compile definition, and keeps it covered by the
# install rule. (Do NOT chase the `datachannel-static` target — it is
# EXCLUDE_FROM_ALL with no install rule.) The same switch selects libdatachannel's
# INSTALL_DEPS_LIBS=ON branch so juice/srtp2/usrsctp install alongside it.
#
# CMAKE_POLICY_VERSION_MINIMUM=3.5 is REQUIRED, not cosmetic: CMake 4.x refuses
# projects declaring cmake_minimum_required below 3.5, and deps/usrsctp (3.0) and
# deps/plog (3.0) both do. Without it this fails at configure time.
#
# CMAKE_CXX_EXTENSIONS=OFF is load-bearing: it emits `-std=c++17`, the IDENTICAL
# flag project.yml gives DeckLinkBridge.mm / DeckLinkAPIDispatch.cpp. With it ON
# CMake emits `-std=gnu++17`, which would NOT match.
#
# CMAKE_PREFIX_PATH="${PREFIX}" is what points USE_MBEDTLS at OUR isolated Mbed TLS
# rather than any system or Homebrew copy.
#
# NO_WEBSOCKET=ON: WHEP signalling is a plain HTTP POST of the SDP offer, done with
# URLSession on the Swift side. Flip to OFF if a future transport needs it.
# NO_MEDIA must stay OFF — that is the RTP/SRTP path WHEP video depends on.
rm -rf build
cmake -S . -B build \
  -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_MIN}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_PREFIX_PATH="${PREFIX}" \
  -DCMAKE_FIND_ROOT_PATH="${PREFIX}" \
  -DCMAKE_IGNORE_PATH="/opt/homebrew;/opt/homebrew/lib;/opt/homebrew/include;/usr/local;/usr/local/lib;/usr/local/include;/opt/local;/sw" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local;/sw" \
  -DCMAKE_FIND_FRAMEWORK=LAST \
  -DCMAKE_FIND_APPBUNDLE=NEVER \
  -DPKG_CONFIG_EXECUTABLE= \
  -DUSE_MBEDTLS=ON \
  -DUSE_GNUTLS=OFF \
  -DUSE_NICE=OFF \
  -DUSE_NETTLE=OFF \
  -DPREFER_SYSTEM_LIB=OFF \
  -DNO_WEBSOCKET=ON \
  -DNO_MEDIA=OFF \
  -DNO_EXAMPLES=ON \
  -DNO_TESTS=ON \
  -DLIBSRTP_TEST_APPS=OFF \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_CXX_EXTENSIONS=OFF

cmake --build build --parallel
cmake --install build

# ── Stage into the repo (headers + the exact archives, nothing else) ────────
echo
echo "==> staging into ${DEST}"
mkdir -p "${DEST}"
rm -rf "${DEST}/lib" "${DEST}/include"
mkdir -p "${DEST}/lib" "${DEST}/include"
cp -R "${PREFIX}/include/rtc" "${DEST}/include/"
for a in libdatachannel libjuice libsrtp2 libusrsctp libmbedtls libmbedx509 libmbedcrypto; do
  src="${PREFIX}/lib/${a}.a"
  [ -f "${src}" ] || { echo "FATAL: missing ${src}"; exit 1; }
  cp "${src}" "${DEST}/lib/"
done

# ── Verify before the artifacts ever reach the Manifold linker ──────────────
echo
echo "── verification ───────────────────────────────────────────────────"
fail=0

# Arch check over whatever archives actually landed, not a hardcoded list.
shopt -s nullglob
staged=( "${DEST}"/lib/*.a )
shopt -u nullglob
[ "${#staged[@]}" -eq 0 ] && { echo "  ✗ no archives staged in ${DEST}/lib"; fail=1; }
for a in "${staged[@]}"; do
  info="$(lipo -info "$a")"
  case "$info" in
    *"Non-fat file"*"is architecture: ${ARCH}") printf "  ✓ %-22s %s static\n" "$(basename "$a")" "${ARCH}" ;;
    *) echo "  ✗ $(basename "$a"): $info"; fail=1 ;;
  esac
done

echo
# Brew-leak scan over the staged archives. Capture-then-match; offenders printed
# from a here-string, never `| head` (which would SIGPIPE upstream and report
# CLEAN exactly when contamination was heaviest).
STAGED_STRINGS="$(strings "${DEST}"/lib/*.a 2>/dev/null || true)"
staged_leaks="$(find_lines "${STAGED_STRINGS}" '/opt/homebrew|/usr/local/(lib|include|opt)')"
if [ -n "${staged_leaks}" ]; then
  echo "  ✗ Homebrew/local paths found inside the archives:"
  sort -u <<<"${staged_leaks}" | sed 's/^/      /'
  fail=1
else
  echo "  ✓ no /opt/homebrew or /usr/local paths inside the archives"
fi

echo
# libdatachannel is transport + depacketize only; any av*/sws*/swr* UNDEFINED
# symbol means the isolation leaked and it somehow got wired to FFmpeg.
LDC_UNDEF="$(nm -uo "${DEST}/lib/libdatachannel.a" 2>/dev/null || true)"
ffmpeg_refs="$(find_lines "${LDC_UNDEF}" ' _(av|sws|swr)[a-z_]+')"
if [ -n "${ffmpeg_refs}" ]; then
  echo "  ✗ FFmpeg symbols referenced by libdatachannel — isolation FAILED:"
  sort -u <<<"${ffmpeg_refs}" | sed 's/^/      /'
  fail=1
else
  echo "  ✓ libdatachannel references no FFmpeg symbols"
fi

echo
STAGED_MBEDTLS_SYMS="$(nm -o "${DEST}/lib/libmbedtls.a" 2>/dev/null || true)"
if has_line "${STAGED_MBEDTLS_SYMS}" 'mbedtls_ssl_conf_dtls_srtp_protection_profiles'; then
  echo "  ✓ Mbed TLS built with DTLS-SRTP support"
else
  echo "  ✗ Mbed TLS is MISSING DTLS-SRTP — WHEP media would fail later"; fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "DONE — artifacts staged and verified in ${DEST}"
  echo "NEXT: xcodegen generate, then build Manifold and press ⌃⌥W."
else
  echo "FAILED — see ✗ above."; exit 1
fi
