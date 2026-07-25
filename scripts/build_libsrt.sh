#!/bin/bash
#
# Build libsrt as an ISOLATED, arm64-only static library, against the Mbed TLS
# already built by scripts/build_mbedtls.sh, and stage it into ThirdParty/libsrt/.
#
#   ./scripts/build_libsrt.sh
#
# Produces:
#   ThirdParty/libsrt/lib/libsrt.a
#   ThirdParty/libsrt/include/srt/*.h      (use as <srt/srt.h>)
#
# ── WHAT THIS IS FOR ────────────────────────────────────────────────────────
# SRT is the next contribution/streaming protocol for Manifold. libsrt provides
# the TRANSPORT only — it hands us an MPEG-TS byte stream. The DEMUX comes from
# the custom static FFmpeg in ThirdParty/ffmpeg (mpegts demuxer + h264 parser),
# fed through a CUSTOM AVIOContext. That is why that FFmpeg is built
# `--disable-network` and must STAY that way: libsrt owns the socket, libavformat
# never opens one. See ThirdParty/ffmpeg/README.md.
#
# ── NON-NEGOTIABLE PROPERTIES ───────────────────────────────────────────────
#  * NOTHING via Homebrew. CMake is forbidden from discovering /opt/homebrew
#    and /usr/local — same three isolation mechanisms as the other two scripts.
#  * NO SECOND CRYPTO LIBRARY. libsrt supports openssl / openssl-evp / gnutls /
#    mbedtls / botan. We use the Mbed TLS ALREADY BUILT for libdatachannel. The
#    isolation-tail argument in build_mbedtls.sh applies here verbatim: OpenSSL
#    has the largest collision surface with a brew copy, GnuTLS drags in
#    nettle + gmp + libtasn1. Neither is being added for SRT's sake.
#  * This script only READS ${HOME}/manifold-webrtc-build/prefix. It installs
#    into its OWN prefix so the WebRTC prefix stays exactly as build_mbedtls.sh
#    and build_libdatachannel.sh left it.
#  * Static only, arm64 only, macOS 15.0 — matched to Manifold's app target.
#  * The Mbed TLS archives are NOT staged into ThirdParty/libsrt. They are
#    already staged under ThirdParty/libdatachannel/lib and linked from there;
#    a second copy would be a second set of paths to keep in sync for no gain.
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
# identical. That false negative is what made the earlier scripts report
#   "✗ Mbed TLS is MISSING DTLS-SRTP"
# against an archive that provably contained all three DTLS-SRTP symbols.
#
# `producer | grep ... | head` is the same shape but worse for the CONTAMINATION
# checks: head exits after N lines and SIGPIPEs upstream, so the pipeline reports
# failure and the check concludes CLEAN exactly when contamination is heaviest.
#
# Fix: capture the producer's output ONCE into a variable, then match with a
# here-string. A here-string is not a pipeline, so nothing can be SIGPIPEd and
# grep's own exit status is the only thing tested. Semantics are unchanged —
# these still fail correctly when a symbol is genuinely absent.
# ════════════════════════════════════════════════════════════════════════════

# has_line <text> <extended-regex>  -> 0 if the pattern occurs, 1 if not.
has_line() { grep -qE -- "$2" <<<"$1"; }

# find_lines <text> <extended-regex> -> prints matching lines (empty if none).
# `|| true` so "no match" (grep exit 1) is not fatal under `set -e`.
find_lines() { grep -E -- "$2" <<<"$1" || true; }

# ── VERSION: v1.5.6, and why ────────────────────────────────────────────────
# v1.5.6 is the newest release on the v1.5.x line (confirmed against the tag list
# on github.com/Haivision/srt). It is pinned rather than tracking master because
# the Mbed TLS backend is the fragile part of this build and the exact source of
# haicrypt/cryspr-mbedtls.c was read before choosing it — see the MBED TLS 3.x
# section below. The v1.6.0 line is not released; ENABLE_AEAD_API_PREVIEW and
# ENABLE_MAXREXMITBW are its previews and are deliberately left OFF.
SRT_TAG="v1.5.6"              # libsrt — MPL-2.0

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
DEST="${REPO_ROOT}/ThirdParty/libsrt"           # final home, in-repo (gitignored)
WORK="${HOME}/manifold-srt-build"               # space-free scratch (repo path has spaces)
PREFIX="${WORK}/prefix"                         # THIS script's install prefix
MBED_PREFIX="${HOME}/manifold-webrtc-build/prefix"   # READ-ONLY: built by build_mbedtls.sh
SRC="${WORK}/srt"

echo "── libsrt ${SRT_TAG} (SRT transport; MPEG-TS demux stays in FFmpeg) ────"
echo "  repo    : ${REPO_ROOT}"
echo "  prefix  : ${PREFIX}          (this script installs here)"
echo "  mbedtls : ${MBED_PREFIX}     (read-only; from build_mbedtls.sh)"
echo "  dest    : ${DEST}"
echo "  arch    : ${ARCH} only"
echo "  min os  : macOS ${MACOS_MIN}"
echo "  crypto  : Mbed TLS (ENABLE_ENCRYPTION=ON, USE_ENCLIB=mbedtls)"
echo "  cmake   : $(command -v cmake) ($(cmake --version 2>/dev/null | sed -n '1p'))"
echo

# ════════════════════════════════════════════════════════════════════════════
# GATE 1 — THE MBED TLS 3.x COMPATIBILITY GATE
#
# THE RISK, precisely. libsrt's Mbed TLS CRYSPR backend (haicrypt/cryspr-mbedtls.c)
# was written against Mbed TLS 2.x. Mbed TLS 3.x moved struct internals behind
# MBEDTLS_PRIVATE and deprecated several entry points. The v1.5.6 backend was read
# line by line against 3.6.7's headers; exactly ONE call in it is a 3.x hazard:
#
#   mbedtls_pkcs5_pbkdf2_hmac(&mdctx, passwd, ..., out)      <- KmPbkdf2
#
# In Mbed TLS 3.x this is DEPRECATED in favour of mbedtls_pkcs5_pbkdf2_hmac_ext(),
# which takes an mbedtls_md_type_t instead of an mbedtls_md_context_t*. It is still
# declared and still compiled INTO libmbedcrypto — but ONLY while
# MBEDTLS_DEPRECATED_REMOVED is off. If a future Mbed TLS build ever enables that
# symbol, this build breaks at link time with an undefined _mbedtls_pkcs5_pbkdf2_hmac
# and the fix is upstream libsrt, not this script.
#
# Everything else the backend touches is API-stable across 2.x and 3.x:
#   mbedtls_aes_setkey_enc/dec, mbedtls_aes_crypt_ecb, mbedtls_aes_crypt_ctr,
#   mbedtls_md_info_from_type, mbedtls_md_setup, mbedtls_entropy_init/func,
#   mbedtls_ctr_drbg_init/seed/random.
# It declares `mbedtls_aes_context` and `mbedtls_ctr_drbg_context` BY VALUE but
# never reads a field of either, so MBEDTLS_PRIVATE does not bite.
#
# So the gate below is not a version-number guess — it asserts the three specific
# conditions that make the 3.x path work, on the actual headers and the actual
# archive this build will use, BEFORE spending a compile.
# ════════════════════════════════════════════════════════════════════════════
echo "==> GATE 1: Mbed TLS 3.x compatibility for libsrt's CRYSPR backend"

if [ ! -f "${MBED_PREFIX}/lib/libmbedcrypto.a" ]; then
  echo "    ✗ ${MBED_PREFIX}/lib/libmbedcrypto.a not found."
  echo "      Run ./scripts/build_mbedtls.sh first — this script never builds crypto."
  exit 1
fi
echo "    ✓ libmbedcrypto.a present in the isolated prefix"

MBED_VER="$(grep -E '^#define MBEDTLS_VERSION_STRING ' "${MBED_PREFIX}/include/mbedtls/build_info.h" 2>/dev/null | tr -d '"' | awk '{print $3}')"
echo "    Mbed TLS version : ${MBED_VER:-<unreadable>}"

gate1=0

# (a) The deprecated-but-required PBKDF2 entry point must still be DECLARED.
if grep -qE 'mbedtls_pkcs5_pbkdf2_hmac\(mbedtls_md_context_t' "${MBED_PREFIX}/include/mbedtls/pkcs5.h"; then
  echo "    ✓ mbedtls_pkcs5_pbkdf2_hmac(mbedtls_md_context_t*) declared in pkcs5.h"
else
  echo "    ✗ mbedtls_pkcs5_pbkdf2_hmac(mbedtls_md_context_t*) is NOT declared."
  echo "      libsrt ${SRT_TAG}'s haicrypt/cryspr-mbedtls.c calls exactly this form."
  gate1=1
fi

# (b) ...and MBEDTLS_DEPRECATED_REMOVED must be OFF, or (a) is compiled out.
if grep -qE '^#define MBEDTLS_DEPRECATED_REMOVED( |$)' "${MBED_PREFIX}/include/mbedtls/mbedtls_config.h"; then
  echo "    ✗ MBEDTLS_DEPRECATED_REMOVED is ENABLED — the PBKDF2 entry point is compiled out."
  echo "      libsrt would fail to link. Rebuild Mbed TLS with it off (the stock default)."
  gate1=1
else
  echo "    ✓ MBEDTLS_DEPRECATED_REMOVED is off (stock default) — the entry point survives"
fi

# (c) ...and it must actually EXIST in the compiled archive, not just the header.
MBEDCRYPTO_SYMS="$(nm -o "${MBED_PREFIX}/lib/libmbedcrypto.a" 2>/dev/null || true)"
if has_line "${MBEDCRYPTO_SYMS}" 'T _mbedtls_pkcs5_pbkdf2_hmac$'; then
  echo "    ✓ _mbedtls_pkcs5_pbkdf2_hmac defined in libmbedcrypto.a"
else
  echo "    ✗ _mbedtls_pkcs5_pbkdf2_hmac is ABSENT from libmbedcrypto.a."
  echo "      SRT passphrase key derivation cannot link against this Mbed TLS."
  gate1=1
fi

# The AES + DRBG primitives the backend uses, in the same archive.
for s in mbedtls_aes_setkey_enc mbedtls_aes_crypt_ctr mbedtls_ctr_drbg_seed mbedtls_md_setup; do
  if has_line "${MBEDCRYPTO_SYMS}" "T _${s}\$"; then
    printf "    ✓ _%s defined\n" "${s}"
  else
    printf "    ✗ _%s ABSENT from libmbedcrypto.a\n" "${s}"
    gate1=1
  fi
done

if [ "${gate1}" -ne 0 ]; then
  echo
  echo "FATAL: this Mbed TLS cannot satisfy libsrt's encryption backend."
  echo "       Aborting BEFORE cmake configure — no build time wasted."
  echo "       Do NOT 'fix' this by turning encryption off; read the block that"
  echo "       scripts/build_libsrt.sh prints on encryption failure first."
  exit 1
fi
echo

# ── The loud failure report, defined once, used for configure AND compile ───
# Requirement: if the Mbed TLS build fails, SAY SO, NAME the fallback, and do NOT
# take it. -DENABLE_ENCRYPTION=OFF does produce a working libsrt — and silently
# deletes SRT passphrase support, which professional contribution feeds use
# routinely. That is a product decision, not a build detail.
encryption_failure_report() {
  local stage="$1"
  echo
  echo "════════════════════════════════════════════════════════════════════════"
  echo " libsrt ${SRT_TAG} FAILED at: ${stage}"
  echo " — with ENABLE_ENCRYPTION=ON / USE_ENCLIB=mbedtls against Mbed TLS ${MBED_VER}"
  echo "════════════════════════════════════════════════════════════════════════"
  echo
  echo " This is the KNOWN RISK for this build. libsrt's Mbed TLS CRYSPR backend"
  echo " was written against Mbed TLS 2.x; 3.x moved struct internals behind"
  echo " MBEDTLS_PRIVATE and deprecated the PBKDF2 entry point it calls."
  echo " GATE 1 above passed, so the specific incompatibility this script knows"
  echo " about is NOT the cause — read the compiler/linker error above."
  echo
  echo " THE SCRIPT HAS NOT DEGRADED THE BUILD, AND WILL NOT. Nothing is staged."
  echo
  echo " ── THE FALLBACK, AND WHAT IT COSTS ─────────────────────────────────"
  echo
  echo "   Rebuilding with  -DENABLE_ENCRYPTION=OFF  works and needs no crypto"
  echo "   library at all. It also REMOVES:"
  echo "     * SRTO_PASSPHRASE / SRTO_PBKEYLEN — AES-128/192/256 stream encryption"
  echo "     * every encrypted SRT caller/listener/rendezvous session"
  echo "   Manifold could still receive UNENCRYPTED SRT. It could NOT receive an"
  echo "   encrypted professional contribution feed, which is the normal case for"
  echo "   a contribution link over the public internet. Connecting to one would"
  echo "   fail at handshake, not degrade gracefully."
  echo
  echo " ── OPTIONS, in preference order ────────────────────────────────────"
  echo
  echo "   1. Report the error upstream / try the next libsrt tag. The fault is"
  echo "      in haicrypt/cryspr-mbedtls.c, not in this script."
  echo "   2. Switch USE_ENCLIB to another backend — REJECTED by default: OpenSSL"
  echo "      has the largest collision surface with a Homebrew copy, GnuTLS drags"
  echo "      in nettle + gmp + libtasn1. Both would have to be built from source"
  echo "      and kept brew-free. See build_mbedtls.sh."
  echo "   3. Build with -DENABLE_ENCRYPTION=OFF and ship without SRT passphrase"
  echo "      support. THIS IS ROBBIE'S CALL, NOT THE SCRIPT'S. If you choose it,"
  echo "      change the flag here deliberately and record it in"
  echo "      ThirdParty/libsrt/README.md so nobody later assumes encryption works."
  echo
  echo "════════════════════════════════════════════════════════════════════════"
}

mkdir -p "${WORK}" "${PREFIX}"

# Purge any previously-installed libsrt from this prefix. Without this a stale
# libsrt.a from an earlier/aborted run survives and gets staged, which is exactly
# how a missing crypto backend can appear to "come back" after a fix.
rm -f "${PREFIX}"/lib/libsrt.a
rm -rf "${PREFIX}/include/srt"

cd "${WORK}"
if [ ! -d "${SRC}" ]; then
  git clone --depth 1 --branch "${SRT_TAG}" https://github.com/Haivision/srt.git srt
fi
cd "${SRC}"
git fetch --depth 1 origin tag "${SRT_TAG}" 2>/dev/null || true
git checkout -q "${SRT_TAG}"

# ── Configure ───────────────────────────────────────────────────────────────
# Brew/system isolation, three independent mechanisms — identical to the other
# two scripts:
#   CMAKE_PREFIX_PATH / CMAKE_FIND_ROOT_PATH — the ONLY place deps may be found
#   CMAKE_IGNORE_PATH / CMAKE_IGNORE_PREFIX_PATH — hard blacklist for brew + /usr/local
#   PKG_CONFIG_EXECUTABLE= — blanks the pkg-config discovery channel entirely
#
# The blanked PKG_CONFIG_EXECUTABLE matters MORE here than it did for the other
# two. libsrt's own scripts/FindMbedTLS.cmake (vendored from obs-studio) opens with
#   find_package(PkgConfig QUIET); pkg_check_modules(_MBEDTLS QUIET mbedtls)
# and then hardcodes  PATHS /usr/include /usr/local/include /opt/local/include
# /sw/include  and  /usr/lib /usr/local/lib /opt/local/lib /sw/lib  into its
# find_path/find_library calls. Left alone, a /usr/local Mbed TLS could be found.
# Blanking pkg-config kills the first channel; CMAKE_IGNORE_PATH kills the second.
#
# Belt and braces on top of that: the four cache variables FindMbedTLS.cmake would
# otherwise search for are PRE-SEEDED to EXACT ABSOLUTE PATHS below. find_path and
# find_library both return immediately when their result variable is already in the
# cache, so no search runs at all and there is no lookup for a Homebrew or
# /usr/local copy to win. This is the same reasoning project.yml uses when it names
# every archive by absolute path instead of -L/-l.
# (MBEDTLS_PREFIX is set too — it is what CMakeLists.txt hands to find_package —
# so the intent is still readable in CMakeCache.txt if the pre-seeding is removed.)
#
# CMAKE_POLICY_VERSION_MINIMUM=3.5: libsrt declares `cmake_minimum_required(VERSION
# 3.5 FATAL_ERROR)`, which CMake 4.x treats as deprecated-to-removed. Same flag,
# same reason, as the other two scripts.
#
# USE_CXX_STD=17 + CMAKE_CXX_EXTENSIONS=OFF: emits `-std=c++17`, the IDENTICAL flag
# project.yml gives DeckLinkBridge.mm / DeckLinkAPIDispatch.cpp and that
# build_libdatachannel.sh already pins. One dialect, one libc++, one binary.
# (USE_CXX_STD=17 makes libsrt set CMAKE_CXX_STANDARD=17 itself; EXTENSIONS=OFF is
# the load-bearing half — ON would emit `-std=gnu++17`, which would NOT match.)
# If libsrt ever fails to compile at strict c++17, dropping USE_CXX_STD entirely
# falls back to the compiler default and the seam is still safe, because srt.h is
# `extern "C"` and no libsrt C++ header is ever parsed by Manifold.
#
# ENABLE_STDCXX_SYNC is left at its POSIX default (OFF) — pthread timing, which is
# what upstream tests on macOS. ENABLE_BONDING stays OFF: socket groups are a
# sender-side redundancy feature Manifold does not use.
rm -rf build
if ! cmake -S . -B build \
  -DCMAKE_OSX_ARCHITECTURES="${ARCH}" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_MIN}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_INCLUDEDIR=include \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_PREFIX_PATH="${MBED_PREFIX}" \
  -DCMAKE_FIND_ROOT_PATH="${MBED_PREFIX}" \
  -DCMAKE_IGNORE_PATH="/opt/homebrew;/opt/homebrew/lib;/opt/homebrew/include;/usr/local;/usr/local/lib;/usr/local/include;/opt/local;/sw" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local;/sw" \
  -DCMAKE_FIND_FRAMEWORK=LAST \
  -DCMAKE_FIND_APPBUNDLE=NEVER \
  -DPKG_CONFIG_EXECUTABLE= \
  -DENABLE_ENCRYPTION=ON \
  -DUSE_ENCLIB=mbedtls \
  -DMBEDTLS_PREFIX="${MBED_PREFIX}" \
  -DMBEDTLS_INCLUDE_DIR="${MBED_PREFIX}/include" \
  -DMBEDTLS_LIB="${MBED_PREFIX}/lib/libmbedtls.a" \
  -DMBEDCRYPTO_LIB="${MBED_PREFIX}/lib/libmbedcrypto.a" \
  -DMBEDX509_LIB="${MBED_PREFIX}/lib/libmbedx509.a" \
  -DENABLE_SHARED=OFF \
  -DENABLE_STATIC=ON \
  -DENABLE_APPS=OFF \
  -DENABLE_EXAMPLES=OFF \
  -DENABLE_TESTING=OFF \
  -DENABLE_UNITTESTS=OFF \
  -DENABLE_BONDING=OFF \
  -DENABLE_AEAD_API_PREVIEW=OFF \
  -DUSE_CXX_STD=17 \
  -DCMAKE_CXX_EXTENSIONS=OFF
then
  encryption_failure_report "cmake configure"
  exit 1
fi

# ── GATE 2: which Mbed TLS did configure actually resolve? ──────────────────
# Read back out of CMakeCache.txt rather than trusting the flags we passed. If a
# future edit removes the pre-seeding, or FindMbedTLS.cmake changes shape, this is
# what catches it — and it catches it BEFORE the compile, not after staging.
echo
echo "==> GATE 2: Mbed TLS resolution recorded in CMakeCache.txt"
CACHE_MBED="$(grep -E '^(MBEDTLS_LIB|MBEDCRYPTO_LIB|MBEDX509_LIB|MBEDTLS_INCLUDE_DIR|MBEDTLS_PREFIX):' build/CMakeCache.txt 2>/dev/null || true)"
if [ -z "${CACHE_MBED}" ]; then
  echo "    ✗ no MBEDTLS_* entries in build/CMakeCache.txt — encryption did not configure."
  encryption_failure_report "cmake configure (no Mbed TLS resolved)"
  exit 1
fi
sed 's/^/    /' <<<"${CACHE_MBED}"
foreign="$(find_lines "${CACHE_MBED}" '=(/opt/homebrew|/usr/local|/opt/local|/sw|/usr/lib|/usr/include)')"
if [ -n "${foreign}" ]; then
  echo "    ✗ Mbed TLS resolved OUTSIDE the isolated prefix:"
  sed 's/^/        /' <<<"${foreign}"
  echo "      Expected everything under ${MBED_PREFIX}"
  exit 1
fi
echo "    ✓ every Mbed TLS path is inside ${MBED_PREFIX}"

if ! cmake --build build --parallel; then
  encryption_failure_report "compile/link"
  exit 1
fi
cmake --install build

# ── Stage into the repo (headers + the one archive, nothing else) ───────────
# Deliberately NOT copying libmbedtls/libmbedx509/libmbedcrypto here. They are the
# same three archives already staged under ThirdParty/libdatachannel/lib, and
# project.yml links them by absolute path from there. Two copies would be two
# things to keep in sync and an invitation to list both in OTHER_LDFLAGS.
echo
echo "==> staging into ${DEST}"
mkdir -p "${DEST}"
rm -rf "${DEST}/lib" "${DEST}/include"
mkdir -p "${DEST}/lib" "${DEST}/include"
[ -f "${PREFIX}/lib/libsrt.a" ] || { echo "FATAL: missing ${PREFIX}/lib/libsrt.a"; exit 1; }
cp "${PREFIX}/lib/libsrt.a" "${DEST}/lib/"
cp -R "${PREFIX}/include/srt" "${DEST}/include/"

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

# The public header Manifold will include must exist under the srt/ subdir, so
# `#include <srt/srt.h>` resolves from ThirdParty/libsrt/include.
echo
for h in srt.h logging_api.h version.h platform_sys.h; do
  if [ -f "${DEST}/include/srt/${h}" ]; then printf "  ✓ include/srt/%s\n" "${h}"
  else echo "  ✗ include/srt/${h} MISSING"; fail=1; fi
done

# ── The API surface Manifold actually calls ─────────────────────────────────
# Capture nm's output ONCE, then match against it. See the pipefail note at the
# top: `nm ... | grep -q` here would report false negatives on a correct archive.
echo
SRT_SYMS="$(nm -o "${DEST}/lib/libsrt.a" 2>/dev/null || true)"
for s in srt_startup srt_create_socket srt_connect srt_recvmsg2 srt_close; do
  if has_line "${SRT_SYMS}" "T _${s}\$"; then
    printf "  ✓ %s present\n" "${s}"
  else
    printf "  ✗ %s ABSENT from libsrt.a\n" "${s}"
    fail=1
  fi
done

# ── HARD GATE: encryption is really compiled in ─────────────────────────────
# crysprMbedtls() is defined by haicrypt/cryspr-mbedtls.c, which enters the build
# ONLY via filelist-mbedtls.maf — i.e. only when ENABLE_ENCRYPTION=ON AND
# USE_ENCLIB=mbedtls. So this one symbol fails an encryption-less build AND an
# accidentally-OpenSSL build, which a generic "does it link" check would not.
# HaiCrypt_Create is the layer above it: present iff haicrypt itself was built.
echo
for s in crysprMbedtls HaiCrypt_Create; do
  if has_line "${SRT_SYMS}" "T _${s}\$"; then
    printf "  ✓ encryption: %s present\n" "${s}"
  else
    printf "  ✗ encryption: %s ABSENT — this libsrt has NO SRT passphrase support\n" "${s}"
    echo "      An encryption-less libsrt must never be staged silently."
    fail=1
  fi
done

# ── It must NOT bundle its own crypto ───────────────────────────────────────
# Two halves, and both are needed:
#   (a) libsrt.a must DEFINE no mbedtls_/OpenSSL symbols — nothing was absorbed.
#   (b) libsrt.a must leave them UNDEFINED — it really defers to an external one.
# (a) alone would also pass for an encryption-less build; (b) is what proves the
# Mbed TLS in the isolated prefix is the thing it resolved against.
echo
SRT_DEFINED_CRYPTO="$(find_lines "${SRT_SYMS}" ' [TDBSC] _(mbedtls_|psa_|EVP_|SSL_|CRYPTO_|gnutls_|botan_)')"
if [ -n "${SRT_DEFINED_CRYPTO}" ]; then
  echo "  ✗ libsrt.a DEFINES crypto symbols — it bundled a crypto library:"
  sort -u <<<"${SRT_DEFINED_CRYPTO}" | sed 's/^/      /'
  fail=1
else
  echo "  ✓ libsrt.a defines no crypto symbols of its own (nothing bundled)"
fi

SRT_UNDEF="$(nm -uo "${DEST}/lib/libsrt.a" 2>/dev/null || true)"
SRT_UNDEF_MBED="$(find_lines "${SRT_UNDEF}" ' _mbedtls_')"
if [ -z "${SRT_UNDEF_MBED}" ]; then
  echo "  ✗ libsrt.a references NO mbedtls symbols at all — encryption is not wired in."
  fail=1
else
  echo "  ✓ libsrt.a leaves Mbed TLS undefined (resolves against the external one)"
fi

# No OpenSSL/GnuTLS/Botan may have crept in as an undefined reference either.
SRT_UNDEF_OTHER="$(find_lines "${SRT_UNDEF}" ' _(EVP_|SSL_|CRYPTO_|gnutls_|botan_)')"
if [ -n "${SRT_UNDEF_OTHER}" ]; then
  echo "  ✗ libsrt.a references a NON-Mbed TLS crypto library:"
  sort -u <<<"${SRT_UNDEF_OTHER}" | sed 's/^/      /'
  fail=1
else
  echo "  ✓ no OpenSSL / GnuTLS / Botan references"
fi

# ── Every Mbed TLS symbol libsrt needs must be satisfiable by the archives ───
# ── Manifold ALREADY links (ThirdParty/libdatachannel/lib/libmbed*.a) ────────
# This is the check that answers "does project.yml need the Mbed TLS archives a
# second time for SRT?" empirically instead of by assumption. If this passes, the
# existing three entries cover libsrt and NOTHING new is added — libsrt.a just has
# to appear BEFORE them in OTHER_LDFLAGS.
echo
if [ -n "${SRT_UNDEF_MBED}" ]; then
  MBED_ALL_SYMS="$(nm -o "${MBED_PREFIX}"/lib/libmbedtls.a "${MBED_PREFIX}"/lib/libmbedx509.a "${MBED_PREFIX}"/lib/libmbedcrypto.a 2>/dev/null || true)"
  # Names only: "path(obj): U _mbedtls_x" -> "_mbedtls_x"; defined side likewise.
  needed="$(awk '{print $NF}' <<<"${SRT_UNDEF_MBED}" | sort -u)"
  provided="$(awk '$(NF-1) ~ /^[TDBSC]$/ {print $NF}' <<<"${MBED_ALL_SYMS}" | sort -u)"
  unmet="$(comm -23 <(printf '%s\n' "${needed}") <(printf '%s\n' "${provided}") || true)"
  if [ -n "${unmet}" ]; then
    echo "  ✗ Mbed TLS symbols libsrt needs that the staged archives do NOT provide:"
    sed 's/^/      /' <<<"${unmet}"
    echo "      The Manifold link would fail. Rebuild Mbed TLS, or add the missing archive."
    fail=1
  else
    echo "  ✓ all $(wc -l <<<"${needed}" | tr -d ' ') Mbed TLS symbols libsrt needs are provided by"
    echo "    libmbedtls.a + libmbedx509.a + libmbedcrypto.a — the SAME three archives"
    echo "    already staged in ThirdParty/libdatachannel/lib. project.yml needs NO"
    echo "    second copy; libsrt.a only has to precede them in OTHER_LDFLAGS."
  fi
fi

# ── libsrt must not have found FFmpeg ───────────────────────────────────────
# libsrt is transport only. The MPEG-TS demux is FFmpeg's job, reached through a
# custom AVIOContext on OUR side of the seam. Any av*/sws*/swr* undefined symbol
# here means the isolation leaked — same assert build_libdatachannel.sh carries.
echo
ffmpeg_refs="$(find_lines "${SRT_UNDEF}" ' _(av|sws|swr)[a-z_]+')"
if [ -n "${ffmpeg_refs}" ]; then
  echo "  ✗ FFmpeg symbols referenced by libsrt — isolation FAILED:"
  sort -u <<<"${ffmpeg_refs}" | sed 's/^/      /'
  fail=1
else
  echo "  ✓ libsrt references no FFmpeg symbols"
fi

# ── Brew-leak scan over the staged archives ─────────────────────────────────
# Capture-then-match; offenders printed from a here-string, never `| head` (which
# would SIGPIPE upstream and report CLEAN exactly when contamination was heaviest).
echo
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
if [ "$fail" -eq 0 ]; then
  echo "DONE — libsrt ${SRT_TAG} staged and verified in ${DEST}"
  echo "       encryption: ON, via Mbed TLS ${MBED_VER} from ${MBED_PREFIX}"
  echo "NEXT: add the project.yml entries listed in ThirdParty/libsrt/README.md,"
  echo "      then xcodegen generate."
else
  echo "FAILED — see ✗ above. Nothing here is safe to link."; exit 1
fi
