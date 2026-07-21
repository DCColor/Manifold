# libdatachannel (static WebRTC transport) — vendored, project-local

Static `.a` archives + headers for **libdatachannel**, Manifold's WebRTC transport
for WHEP. Vendored into the repo and **gitignored**, exactly like
`ThirdParty/ffmpeg/`. Linked statically into the Manifold binary — **no Homebrew,
no `/usr/local`, no system packages, no dlopen, no framework.** `otool -L` on the
built app stays clean.

## What this is
- **libdatachannel `v0.24.5`** (MPL-2.0), built from source, **arm64 only**.
- `lib/`
  - `libdatachannel.a` — the library
  - `libjuice.a` — ICE (bundled submodule)
  - `libsrtp2.a` — SRTP (bundled submodule)
  - `libusrsctp.a` — SCTP for data channels (bundled submodule)
  - `libmbedtls.a`, `libmbedx509.a`, `libmbedcrypto.a` — DTLS backend
- `include/rtc/` — the public headers. Only `rtc/rtc.h` (**pure C**) is used by
  Manifold; the C++ headers are never included by our code.

**libdatachannel does not use FFmpeg.** It is transport + depacketization only —
bring-your-own-decoder. Nothing here touches, reads, or links
`ThirdParty/ffmpeg/`, and `scripts/build_libdatachannel.sh` asserts that no `av*`/`sws*`/`swr*`
symbol appears in `libdatachannel.a`.

## Toolchain — matched to the Manifold app target
Taken from the generated `Manifold.xcodeproj`, so the C++ ABI is identical:

| setting | Manifold app target | this build |
| --- | --- | --- |
| `ARCHS` | `arm64` | `CMAKE_OSX_ARCHITECTURES=arm64` |
| `MACOSX_DEPLOYMENT_TARGET` | `15.0` | `CMAKE_OSX_DEPLOYMENT_TARGET=15.0` |
| `CLANG_CXX_LIBRARY` | `libc++` | Apple clang default (`libc++`) |
| C++ dialect | **`-std=c++17`** | **`-std=c++17`** |
| toolchain | Apple clang (Xcode) | Apple clang (same `/usr/bin/clang`) |

### The C++ dialect match — verified, not assumed
The app target previously left `CLANG_CXX_LANGUAGE_STANDARD` unset, which silently
resolved to **`gnu++14`** while libdatachannel is **C++17**. Both are now pinned to
the identical flag:

- `project.yml` states `CLANG_CXX_LANGUAGE_STANDARD: c++17` explicitly, so it can
  never drift back to a toolchain default. Confirmed via
  `xcodebuild -showBuildSettings` for Debug, Release **and** Profile.
- `scripts/build_libdatachannel.sh` passes `CMAKE_CXX_STANDARD=17` **plus
  `CMAKE_CXX_EXTENSIONS=OFF`**. That second flag is load-bearing: `OFF` emits
  `-std=c++17`, `ON` emits `-std=gnu++17`, which would *not* match. Both
  behaviours were confirmed by configuring a probe project, including the fact
  that the per-target `CXX_STANDARD 17` libdatachannel sets does not override the
  extensions setting.
- Before raising the app, both C++ TUs (`DeckLinkBridge.mm`,
  `DeckLinkAPIDispatch.cpp`) were compiled at strict `-std=c++17` with
  `clang++ -fsyntax-only` — clean, zero errors. The DeckLink SDK 16.0 headers use
  none of the constructs C++17 removed (`register`, `auto_ptr`, `bind1st`/`bind2nd`,
  `ptr_fun`, `random_shuffle`, `unary_function`/`binary_function`, dynamic
  exception specifications).

One dialect, one `libc++`, one binary. Independently of that, the seam is **pure C**,
which is a second layer of protection worth keeping:

- `App/WebRTC/DataChannelBridge.m` is plain **Objective-C** and includes only
  `rtc/rtc.h`, which is `extern "C"` and pulls in nothing but `<stdbool.h>` and
  `<stdint.h>`. **No libdatachannel C++ header is ever parsed by our build**, so
  there is no template or inline entity instantiated across the boundary at all.
- Both sides use the same `libc++`.

The rule to keep: **never `#include` a libdatachannel C++ header from Manifold.**
The dialects now match, so doing so would compile — but the C seam is what keeps
this robust against either side's flags drifting later, and it is free.

## Dependency / licence notes
| component | licence | linkage |
| --- | --- | --- |
| libdatachannel | MPL-2.0 | static |
| libjuice | MPL-2.0 | static |
| plog | MPL-2.0 | header-only |
| libSRTP | BSD-3-Clause | static |
| usrsctp | BSD-3-Clause | static |
| Mbed TLS | Apache-2.0 | static |

MPL-2.0 is **file-level** copyleft: static linking into a proprietary binary is
permitted, with the obligation to make any *modified* MPL source files available.
We modify none. Attribution for all six components belongs in the app's
acknowledgements.

## DTLS backend: Mbed TLS (not OpenSSL)
libdatachannel's default backend is OpenSSL, whose easy path is
`brew install openssl` — **refused**. Mbed TLS was chosen because it is plain
CMake with **zero external dependencies**, builds in about a minute, is
Apache-2.0, and lets `libjuice` build with `USE_NETTLE=OFF` (no crypto dependency
of its own) and libSRTP use its Mbed TLS engine. GnuTLS would have dragged in
nettle + gmp + libtasn1 from source. Apple's Security.framework is not an option:
libdatachannel supports exactly OpenSSL, GnuTLS, and Mbed TLS.

`MBEDTLS_SSL_DTLS_SRTP` is **off by default** in Mbed TLS and is switched on by
`scripts/build_mbedtls.sh` — WebRTC media cannot export SRTP keying material without it.

## Rebuilding
Two scripts, in this order (the second refuses to run without the first):
```sh
./scripts/build_mbedtls.sh          # DTLS backend -> isolated prefix
./scripts/build_libdatachannel.sh   # transport + deps -> isolated prefix -> staged here
```
Both compile in `~/manifold-webrtc-build` (a space-free scratch dir; the repo path
contains spaces) into an isolated prefix that shares no directory with
`ThirdParty/ffmpeg`. The second stages `lib/` + `include/` here and verifies arch,
Homebrew-path cleanliness, FFmpeg-symbol absence, and DTLS-SRTP support.

Everything is built from source. **Never `brew install` any of these** — a
Homebrew copy of OpenSSL or FFmpeg leaking into this build is both a correctness
and a licensing hazard for Manifold *and* for the other products that each ship
their own custom static FFmpeg.
