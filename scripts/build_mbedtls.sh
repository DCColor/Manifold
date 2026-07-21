#!/bin/bash
#
# Build Mbed TLS as an ISOLATED, arm64-only static library for Manifold.
# STEP 1 of 2 — run this BEFORE scripts/build_libdatachannel.sh.
#
#   ./scripts/build_mbedtls.sh
#
# Installs into an isolated prefix ($HOME/manifold-webrtc-build/prefix) which
# scripts/build_libdatachannel.sh then points CMAKE_PREFIX_PATH at. Nothing is
# staged into the repo by this script — libdatachannel's script does that.
#
# ── WHY MBED TLS AND NOT GNUTLS OR OPENSSL ──────────────────────────────────
# libdatachannel supports exactly three DTLS backends: OpenSSL (default), GnuTLS,
# and Mbed TLS. Mbed TLS is the only one with NO external dependency tail:
#   * OpenSSL  — Perl-based Configure; largest collision surface with a brew copy.
#   * GnuTLS   — drags in nettle + gmp + libtasn1, each of which would ALSO have
#                to be built from source and kept brew-free. Rejected on exactly
#                that isolation-tail argument.
#   * Mbed TLS — plain CMake, ZERO external deps, ~1 min, Apache-2.0. CHOSEN.
# Consequently there is no nettle, gmp, libtasn1, GnuTLS or OpenSSL anywhere in
# this script or in build_libdatachannel.sh. Apple's Security.framework is not an
# option — libdatachannel has no such backend.
#
# ── VERSION: 3.x, NOT 2.x ───────────────────────────────────────────────────
# libdatachannel calls `find_package(MbedTLS 3 REQUIRED)`. Major version 3 is
# mandatory; a 2.x build will be rejected at configure time.
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
# only when the match occurs early enough that the producer hasn't finished. A
# genuinely absent symbol lets the producer run to completion and exits 1, which
# looks identical. That is a false negative that gets worse the more correct the
# library is, and it is what made these scripts report
#   "✗ Mbed TLS is MISSING DTLS-SRTP"
# against an archive that provably contained all three DTLS-SRTP symbols.
#
# `producer | grep ... | head` has the same shape with an extra edge: head exits
# after N lines, SIGPIPEs its upstream, and the pipeline reports failure — so a
# check for *contamination* would report CLEAN exactly when contamination was
# heaviest. Strictly worse than the symbol case.
#
# Fix: capture the producer's output ONCE into a variable, then match with a
# here-string. A here-string is not a pipeline, so no process can be SIGPIPEd and
# grep's own exit status is the only thing tested. The checks keep their exact
# semantics — they still fail correctly when a symbol is genuinely absent.
# ════════════════════════════════════════════════════════════════════════════

# has_line <text> <extended-regex>  -> 0 if the pattern occurs, 1 if not.
has_line() { grep -qE -- "$2" <<<"$1"; }

# find_lines <text> <extended-regex> -> prints matching lines (empty if none).
# `|| true` so "no match" (grep exit 1) is not fatal under `set -e`.
find_lines() { grep -E -- "$2" <<<"$1" || true; }

MBEDTLS_TAG="v3.6.7"          # Mbed TLS 3.6 LTS — Apache-2.0

# ── Toolchain — MUST match Manifold's app target exactly ────────────────────
# Verified against `xcodebuild -showBuildSettings` for Debug, Release AND Profile:
#   ARCHS = arm64                 MACOSX_DEPLOYMENT_TARGET = 15.0
#   CLANG_CXX_LIBRARY = libc++    CLANG_CXX_LANGUAGE_STANDARD = c++17
# and against project.yml: `deploymentTarget: macOS: "15.0"`.
# 15.0 — NOT 13.0. Mismatching this produces "object file was built for newer
# macOS version than being linked" warnings at the Manifold link.
ARCH="arm64"                  # arm64 ONLY — Manifold is Apple-Silicon-only (Float16)
MACOS_MIN="15.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${HOME}/manifold-webrtc-build"     # space-free scratch (repo path has spaces)
PREFIX="${WORK}/prefix"                  # ISOLATED prefix; no overlap with ThirdParty/ffmpeg
SRC="${WORK}/mbedtls"

# ════════════════════════════════════════════════════════════════════════════
# THE CONFIG SYMBOLS libdatachannel's Mbed TLS BACKEND REQUIRES
#
# Derived by reading libdatachannel v0.24.5 src/impl/dtlstransport.cpp and
# src/impl/certificate.cpp under `#elif USE_MBEDTLS` and mapping every mbedtls_*
# call it makes back to its guarding config symbol.
#
# Of this entire set, exactly ONE ships disabled in the stock 3.6.7
# mbedtls_config.h: MBEDTLS_SSL_DTLS_SRTP. Everything else is already ON by
# default. We still verify the whole set below, because a future Mbed TLS release
# flipping any of these to off-by-default would otherwise fail far downstream,
# at WHEP media time, with a mystifying error.
#
#   MBEDTLS_SSL_DTLS_SRTP    <- OFF BY DEFAULT. The use_srtp extension. Provides
#                               mbedtls_ssl_conf_dtls_srtp_protection_profiles()
#                               and MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_80,
#                               both used at dtlstransport.cpp:376,416. Without
#                               it WebRTC cannot export SRTP keying material and
#                               media never flows, even though everything links.
#   MBEDTLS_SSL_PROTO_DTLS   <- DTLS itself; a hard prerequisite of DTLS_SRTP.
#   MBEDTLS_SSL_PROTO_TLS1_2 <- libdatachannel pins TLS 1.2 (MINOR_VERSION_3).
#   MBEDTLS_SSL_CLI_C /
#   MBEDTLS_SSL_SRV_C        <- MBEDTLS_SSL_IS_CLIENT / IS_SERVER; WebRTC needs both.
#   MBEDTLS_CTR_DRBG_C /
#   MBEDTLS_ENTROPY_C        <- RNG for cert + handshake.
#   MBEDTLS_X509_CRT_WRITE_C /
#   MBEDTLS_X509_CREATE_C    <- self-signed cert generation (mbedtls_x509write_crt_*).
#   MBEDTLS_X509_CRT_PARSE_C <- parsing the peer cert.
#   MBEDTLS_PK_C / _PARSE_C /
#   MBEDTLS_PK_WRITE_C       <- key handling.
#   MBEDTLS_ECP_C /
#   MBEDTLS_ECDSA_C          <- default ECDSA certificate type.
#   MBEDTLS_RSA_C /
#   MBEDTLS_GENPRIME         <- RTC_CERTIFICATE_RSA path.
#   MBEDTLS_SHA1_C           <- DTLS-SRTP KDF + fingerprints.
#   MBEDTLS_SHA256_C /
#   MBEDTLS_SHA512_C         <- fingerprints.
#   MBEDTLS_PEM_PARSE_C /
#   MBEDTLS_PEM_WRITE_C      <- PEM key/cert import-export.
#   MBEDTLS_FS_IO            <- mbedtls_pk_parse_keyfile / x509_crt_parse_file.
#   MBEDTLS_TIMING_C         <- DTLS retransmission timers.
# ════════════════════════════════════════════════════════════════════════════
REQUIRED_SYMBOLS=(
  MBEDTLS_SSL_DTLS_SRTP
  MBEDTLS_SSL_PROTO_DTLS
  MBEDTLS_SSL_PROTO_TLS1_2
  MBEDTLS_SSL_CLI_C
  MBEDTLS_SSL_SRV_C
  MBEDTLS_SSL_TLS_C
  MBEDTLS_CTR_DRBG_C
  MBEDTLS_ENTROPY_C
  MBEDTLS_X509_CRT_WRITE_C
  MBEDTLS_X509_CREATE_C
  MBEDTLS_X509_CRT_PARSE_C
  MBEDTLS_PK_C
  MBEDTLS_PK_PARSE_C
  MBEDTLS_PK_WRITE_C
  MBEDTLS_ECP_C
  MBEDTLS_ECDSA_C
  MBEDTLS_RSA_C
  MBEDTLS_GENPRIME
  MBEDTLS_SHA1_C
  MBEDTLS_SHA256_C
  MBEDTLS_SHA512_C
  MBEDTLS_PEM_PARSE_C
  MBEDTLS_PEM_WRITE_C
  MBEDTLS_FS_IO
  MBEDTLS_TIMING_C
)

# These two build as SEPARATE archives (libeverest.a, libp256m.a) that mbedcrypto
# links PUBLIC. Both features are OFF in the stock config, so mbedcrypto.a contains
# no references to them and they need not be staged or linked. If either is ever
# turned ON, those archives MUST also be copied in build_libdatachannel.sh and added
# to OTHER_LDFLAGS in project.yml, or the Manifold link fails with undefined symbols.
# Asserted below so that change can never happen silently.
MUST_BE_OFF=(
  MBEDTLS_ECDH_VARIANT_EVEREST_ENABLED
  MBEDTLS_PSA_P256M_DRIVER_ENABLED
)

CONFIG_H="include/mbedtls/mbedtls_config.h"

echo "── Mbed TLS ${MBEDTLS_TAG} (DTLS backend for libdatachannel) ──────────"
echo "  repo    : ${REPO_ROOT}"
echo "  prefix  : ${PREFIX}"
echo "  arch    : ${ARCH} only"
echo "  min os  : macOS ${MACOS_MIN}"
echo "  cmake   : $(command -v cmake) ($(cmake --version 2>/dev/null | sed -n '1p'))"
echo

mkdir -p "${WORK}" "${PREFIX}"

# Purge any previously-installed Mbed TLS from the prefix. Without this, a stale
# libmbedtls.a from an earlier/aborted run survives and gets staged by
# build_libdatachannel.sh, which is exactly how a missing MBEDTLS_SSL_DTLS_SRTP
# can appear to "come back" after a fix.
rm -f "${PREFIX}"/lib/libmbed*.a "${PREFIX}"/lib/libeverest.a "${PREFIX}"/lib/libp256m.a
rm -rf "${PREFIX}/include/mbedtls" "${PREFIX}/include/psa" "${PREFIX}/lib/cmake/MbedTLS"

cd "${WORK}"
if [ ! -d "${SRC}" ]; then
  git clone --depth 1 --branch "${MBEDTLS_TAG}" --recursive \
      https://github.com/Mbed-TLS/mbedtls.git mbedtls
fi
cd "${SRC}"

# Make re-runs deterministic. A previous run left mbedtls_config.h modified by
# config.py; restoring it first means "set" always starts from a known state and
# the enabled-symbol audit below reflects reality rather than accumulated edits.
git checkout -- "${CONFIG_H}" 2>/dev/null || true
git fetch --depth 1 origin tag "${MBEDTLS_TAG}" 2>/dev/null || true
git checkout -q "${MBEDTLS_TAG}"
git submodule update --init --recursive --depth 1

# ── Enable DTLS-SRTP ────────────────────────────────────────────────────────
# scripts/config.py is Mbed TLS's own supported mechanism for toggling config
# symbols and is pure-stdlib Python (no pip, no brew python needed). It uncomments
# the `//#define MBEDTLS_SSL_DTLS_SRTP` line in include/mbedtls/mbedtls_config.h,
# which is the header every TU in the library compiles against — so this is a real
# whole-library rebuild toggle, not a per-file flag that could apply inconsistently.
echo "==> enabling MBEDTLS_SSL_DTLS_SRTP"
python3 scripts/config.py set MBEDTLS_SSL_DTLS_SRTP

# Fallback: if config.py silently no-ops on some future layout, append the define
# directly. Harmless when config.py already did the job (the grep below dedupes).
if ! grep -qE "^#define MBEDTLS_SSL_DTLS_SRTP( |$)" "${CONFIG_H}"; then
  echo "    config.py did not take effect — appending the #define directly"
  printf '\n/* Enabled by Manifold scripts/build_mbedtls.sh — required by libdatachannel WHEP */\n#define MBEDTLS_SSL_DTLS_SRTP\n' >> "${CONFIG_H}"
fi

# ── GATE 1: did the `set` land on the header, RIGHT NOW, before any compiling? ──
# This is the cheapest possible failure point. Everything downstream (the full
# symbol audit, cmake configure, the ~1 min build, then the post-build nm assert)
# is wasted if the define is not on disk at this instant. Fails in under a second
# rather than after a full build.
#
# It also pins the source-of-truth explicitly: the file asserted here is the file
# `cmake -S .` compiles, because the working directory is ${SRC} for both and no
# git operation runs between this point and the configure below. If a future edit
# ever introduces a `git checkout` / `git clean` / `git reset` / re-clone after
# this line, THIS assert is what will catch it.
echo
echo "==> GATE 1: verifying the define landed on the header cmake will compile"
echo "    cwd              : $(pwd)"
echo "    config header    : $(pwd)/${CONFIG_H}"
echo "    cmake source dir : $(pwd)   (cmake -S . below — same tree)"
if grep -qE "^#define MBEDTLS_SSL_DTLS_SRTP( |$)" "${CONFIG_H}"; then
  echo "    ✓ $(grep -nE '^#define MBEDTLS_SSL_DTLS_SRTP( |$)' "${CONFIG_H}")"
else
  echo "    ✗ MBEDTLS_SSL_DTLS_SRTP is STILL COMMENTED OUT after config.py set."
  echo
  echo "      Current state of that line:"
  grep -nE "MBEDTLS_SSL_DTLS_SRTP" "${CONFIG_H}" | sed 's/^/        /'
  echo
  echo "      config.py used : $(pwd)/scripts/config.py"
  echo "      MBEDTLS_CONFIG_FILE      = ${MBEDTLS_CONFIG_FILE:-<unset>}"
  echo "      MBEDTLS_USER_CONFIG_FILE = ${MBEDTLS_USER_CONFIG_FILE:-<unset>}"
  echo
  echo "      Aborting BEFORE cmake configure — no build time wasted."
  exit 1
fi

# ── Audit the FULL required set BEFORE spending time compiling ──────────────
echo
echo "==> auditing required config symbols"
missing=0
for s in "${REQUIRED_SYMBOLS[@]}"; do
  if grep -qE "^#define ${s}( |$)" "${CONFIG_H}"; then
    printf "  ✓ %s\n" "${s}"
  else
    printf "  ✗ %s  — NOT ENABLED\n" "${s}"
    missing=1
  fi
done
for s in "${MUST_BE_OFF[@]}"; do
  if grep -qE "^#define ${s}( |$)" "${CONFIG_H}"; then
    printf "  ✗ %s is ON — libeverest.a/libp256m.a must now be staged and linked\n" "${s}"
    printf "      (see the MUST_BE_OFF note in this script and project.yml OTHER_LDFLAGS)\n"
    missing=1
  else
    printf "  ✓ %s off (its archive stays unreferenced)\n" "${s}"
  fi
done
if [ "${missing}" -ne 0 ]; then
  echo
  echo "FATAL: Mbed TLS config does not satisfy libdatachannel's requirements. Not building."
  exit 1
fi

# ── Configure ───────────────────────────────────────────────────────────────
# Brew/system isolation, three independent mechanisms:
#   CMAKE_PREFIX_PATH / CMAKE_FIND_ROOT_PATH — the ONLY place deps may be found
#   CMAKE_IGNORE_PATH / CMAKE_IGNORE_PREFIX_PATH — hard blacklist for brew + /usr/local
#   PKG_CONFIG_EXECUTABLE= — blanks the pkg-config discovery channel entirely
# (/opt/homebrew/bin/cmake is only the BUILD TOOL — never linked into anything —
# but that is exactly why these exclusions are mandatory rather than decorative.)
echo
# ── GATE 2: last check before configure ────────────────────────────────────
# Bracketing GATE 1. Nothing between them should be able to revert the header —
# this exists so that if something ever does, the failure names the exact stage.
if ! grep -qE "^#define MBEDTLS_SSL_DTLS_SRTP( |$)" "${CONFIG_H}"; then
  echo "FATAL: MBEDTLS_SSL_DTLS_SRTP was reverted between GATE 1 and cmake configure."
  echo "       Something between those points rewrote $(pwd)/${CONFIG_H}."
  exit 1
fi
echo "==> GATE 2: define still present immediately before configure ✓"

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
  -DENABLE_TESTING=OFF \
  -DENABLE_PROGRAMS=OFF \
  -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
  -DUSE_SHARED_MBEDTLS_LIBRARY=OFF

cmake --build build --parallel
cmake --install build

# ── Verify ──────────────────────────────────────────────────────────────────
echo
echo "── verification ───────────────────────────────────────────────────"
fail=0

# Arch check over WHATEVER archives actually landed in the prefix, rather than a
# hardcoded list. Mbed TLS builds libmbedtls/libmbedx509/libmbedcrypto plus,
# depending on config, libeverest and libp256m — a fixed list of three produced
# false failures when the extra two appeared.
shopt -s nullglob
archives=( "${PREFIX}"/lib/*.a )
shopt -u nullglob
if [ "${#archives[@]}" -eq 0 ]; then
  echo "  ✗ no archives found in ${PREFIX}/lib"; fail=1
fi
for f in "${archives[@]}"; do
  info="$(lipo -info "$f")"
  case "$info" in
    *"Non-fat file"*"is architecture: ${ARCH}") printf "  ✓ %-20s %s static\n" "$(basename "$f")" "${ARCH}" ;;
    *) echo "  ✗ $(basename "$f"): $info"; fail=1 ;;
  esac
done

# The three Manifold actually links must all be present.
echo
for a in libmbedtls libmbedx509 libmbedcrypto; do
  if [ -f "${PREFIX}/lib/${a}.a" ]; then printf "  ✓ %s.a present\n" "${a}"
  else echo "  ✗ ${a}.a MISSING from ${PREFIX}/lib"; fail=1; fi
done

# ── HARD GATE: the DTLS-SRTP symbol must exist in the compiled archive ──────
# This is the check that previously only ran at the libdatachannel stage, which is
# far too late — libdatachannel would link successfully against a crypto library
# that cannot negotiate SRTP keys. Failing here means one rebuild, not two.
echo
# Capture nm's output ONCE, then match against it. See the pipefail note at the
# top: `nm ... | grep -q` here reported a false negative against a correct archive.
MBEDTLS_SYMS="$(nm -o "${PREFIX}/lib/libmbedtls.a" 2>/dev/null || true)"
if has_line "${MBEDTLS_SYMS}" 'mbedtls_ssl_conf_dtls_srtp_protection_profiles'; then
  echo "  ✓ DTLS-SRTP: mbedtls_ssl_conf_dtls_srtp_protection_profiles present in libmbedtls.a"
else
  echo "  ✗ DTLS-SRTP SYMBOL ABSENT from libmbedtls.a — WHEP media would fail to flow."
  echo
  echo "    Diagnostics:"
  echo "      config header : ${SRC}/${CONFIG_H}"
  grep -nE "MBEDTLS_SSL_DTLS_SRTP" "${CONFIG_H}" | sed 's/^/        /' || echo "        (symbol not found in header at all)"
  echo "      If the #define IS present above, the build did not use this header —"
  echo "      check for a MBEDTLS_CONFIG_FILE or MBEDTLS_USER_CONFIG_FILE env var:"
  echo "        MBEDTLS_CONFIG_FILE=${MBEDTLS_CONFIG_FILE:-<unset>}"
  echo "        MBEDTLS_USER_CONFIG_FILE=${MBEDTLS_USER_CONFIG_FILE:-<unset>}"
  fail=1
fi

# Also confirm the negotiation-result accessor libdatachannel needs is usable.
# Reuses the SAME captured symbol table — no second nm, no second pipeline.
if has_line "${MBEDTLS_SYMS}" 'mbedtls_ssl_get_dtls_srtp_negotiation_result'; then
  echo "  ✓ DTLS-SRTP: negotiation-result accessor present"
else
  echo "  ✗ DTLS-SRTP: mbedtls_ssl_get_dtls_srtp_negotiation_result absent"; fail=1
fi

echo
# Brew-leak scan. Capture-then-match, and print the offenders via a here-string
# rather than `| head` — `| head` would SIGPIPE its upstream on heavy contamination
# and make the pipeline report success, i.e. report CLEAN exactly when dirtiest.
PREFIX_STRINGS="$(strings "${PREFIX}"/lib/*.a 2>/dev/null || true)"
prefix_leaks="$(find_lines "${PREFIX_STRINGS}" '/opt/homebrew|/usr/local/(lib|include|opt)')"
if [ -n "${prefix_leaks}" ]; then
  echo "  ✗ Homebrew/local paths found inside the archives:"
  sort -u <<<"${prefix_leaks}" | sed 's/^/      /'
  fail=1
else
  echo "  ✓ no /opt/homebrew or /usr/local paths inside the archives"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "DONE — Mbed TLS installed to ${PREFIX}"
  echo "NEXT: ./scripts/build_libdatachannel.sh"
else
  echo "FAILED — see ✗ above. Do NOT proceed to build_libdatachannel.sh."
  exit 1
fi
