# libsrt (static SRT transport) — vendored, project-local

Static `libsrt.a` + headers for **libsrt**, Manifold's SRT transport. Vendored into
the repo and **gitignored**, exactly like `ThirdParty/ffmpeg/` and
`ThirdParty/libdatachannel/`. Linked statically into the Manifold binary — **no
Homebrew, no `/usr/local`, no system packages, no dlopen, no framework.** `otool -L`
on the built app stays clean.

## What this is
- **libsrt `v1.5.6`** (MPL-2.0), built from source, **arm64 only**, static only.
- `lib/libsrt.a` — the library. That is the **only** archive here; see
  *No second copy of Mbed TLS* below.
- `include/srt/` — the public headers, included as **`<srt/srt.h>`**. `srt.h` is
  `extern "C"` and pulls in nothing but `version.h`, `platform_sys.h`,
  `logging_api.h`, `<string.h>` and `<stdlib.h>`.

## Transport only — the demux is FFmpeg's job
libsrt gives us an **MPEG-TS byte stream**, nothing more. The demux comes from the
custom static FFmpeg in `ThirdParty/ffmpeg/` (mpegts demuxer + h264 parser), fed
through a **custom `AVIOContext`**: libsrt owns the socket, `libavformat` never
opens one.

That is exactly why `ThirdParty/ffmpeg` is built `--disable-network` and **must stay
that way**. Enabling FFmpeg's network layer would add a second, competing SRT/UDP
implementation inside the binary and an `avformat_open_input("srt://…")` path that
bypasses everything here. See `ThirdParty/ffmpeg/README.md`.

`scripts/build_libsrt.sh` asserts that no `av*`/`sws*`/`swr*` symbol is referenced by
`libsrt.a`, the same way `build_libdatachannel.sh` does for libdatachannel.

## Toolchain — matched to the Manifold app target
| setting | Manifold app target | this build |
| --- | --- | --- |
| `ARCHS` | `arm64` | `CMAKE_OSX_ARCHITECTURES=arm64` |
| `MACOSX_DEPLOYMENT_TARGET` | `15.0` | `CMAKE_OSX_DEPLOYMENT_TARGET=15.0` |
| `CLANG_CXX_LIBRARY` | `libc++` | Apple clang default (`libc++`) |
| C++ dialect | **`-std=c++17`** | **`-std=c++17`** (`USE_CXX_STD=17` + `CMAKE_CXX_EXTENSIONS=OFF`) |
| toolchain | Apple clang (Xcode) | Apple clang (same `/usr/bin/clang`) |

`CMAKE_CXX_EXTENSIONS=OFF` is the load-bearing half of the dialect match: `OFF`
emits `-std=c++17`, `ON` emits `-std=gnu++17`, which would *not* match. Same
reasoning, same flags, as `ThirdParty/libdatachannel/README.md`.

Independently of that the seam is **pure C** — `srt.h` is `extern "C"` — so no
libsrt C++ header is ever parsed by our build and nothing is instantiated across
the boundary. The rule to keep: **never `#include` a libsrt C++ header from
Manifold.** The dialects match, so it would compile; the C seam is what keeps this
robust against either side's flags drifting later, and it is free.

## Encryption: Mbed TLS, reusing the one already built
Configured with `-DENABLE_ENCRYPTION=ON -DUSE_ENCLIB=mbedtls` against the **existing**
isolated Mbed TLS 3.6.7 in `~/manifold-webrtc-build/prefix` — the same one
`scripts/build_mbedtls.sh` built for libdatachannel's DTLS. No second crypto library
is built, and **no OpenSSL and no GnuTLS enter this project**: OpenSSL has the
largest collision surface with a Homebrew copy, GnuTLS drags in nettle + gmp +
libtasn1, each of which would also have to be built from source and kept brew-free.
That is the same isolation-tail argument `build_mbedtls.sh` documents.

This buys `SRTO_PASSPHRASE` / `SRTO_PBKEYLEN` — AES-128/192/256 stream encryption,
which professional contribution feeds use routinely. `build_libsrt.sh` asserts the
symbol `crysprMbedtls` is present in `libsrt.a`; that function is compiled **only**
via `filelist-mbedtls.maf`, so the assert fails both an encryption-less build and an
accidentally-OpenSSL one, which a plain "does it link" check would not.

### The Mbed TLS 3.x hazard, and why v1.5.6 is safe
libsrt's Mbed TLS CRYSPR backend (`haicrypt/cryspr-mbedtls.c`) was written against
Mbed TLS **2.x**; 3.x moved struct internals behind `MBEDTLS_PRIVATE` and deprecated
several entry points. The v1.5.6 backend was read against 3.6.7's headers. Exactly
one call in it is a 3.x hazard:

```c
mbedtls_pkcs5_pbkdf2_hmac(&mdctx, passwd, …, out)   /* KmPbkdf2 */
```

In 3.x this is **deprecated** in favour of `mbedtls_pkcs5_pbkdf2_hmac_ext()` — but it
is still declared and still compiled into `libmbedcrypto` while
`MBEDTLS_DEPRECATED_REMOVED` is off, which is the stock default our build uses.
Everything else the backend touches is API-stable across 2.x and 3.x
(`mbedtls_aes_setkey_enc/dec`, `mbedtls_aes_crypt_ecb/ctr`, `mbedtls_md_*`,
`mbedtls_entropy_*`, `mbedtls_ctr_drbg_*`), and although it declares
`mbedtls_aes_context` and `mbedtls_ctr_drbg_context` **by value** it never reads a
field of either, so `MBEDTLS_PRIVATE` does not bite.

`build_libsrt.sh` GATE 1 asserts all three of those conditions — the declaration, the
`MBEDTLS_DEPRECATED_REMOVED` state, and the symbol's presence in the compiled
`libmbedcrypto.a` — **before** spending a compile. If the encryption build ever fails
anyway, the script prints a loud block naming the `-DENABLE_ENCRYPTION=OFF` fallback
**and what it costs**, and exits without taking it. Disabling SRT encryption is a
product decision, not a build detail.

## No second copy of Mbed TLS
`ThirdParty/libsrt/lib/` deliberately contains **only** `libsrt.a`.

`libsrt.a` leaves every `mbedtls_*` symbol undefined and resolves against
`ThirdParty/libdatachannel/lib/{libmbedtls,libmbedx509,libmbedcrypto}.a`, which
`project.yml` already links by absolute path. `build_libsrt.sh` verifies this
symbol-by-symbol: it diffs libsrt's undefined `mbedtls_*` set against everything
those three archives define, and fails if anything is unmet. So **`project.yml` adds
no new Mbed TLS entries** — `libsrt.a` only has to appear *before* them in
`OTHER_LDFLAGS`, because in static linking each provider must follow its consumers.

A second copy of those archives here would be a second set of paths to keep in sync,
and an invitation to list both in `OTHER_LDFLAGS`.

## Dependency / licence notes
| component | licence | linkage |
| --- | --- | --- |
| libsrt | MPL-2.0 | static |
| Mbed TLS | Apache-2.0 | static (shared with libdatachannel) |

MPL-2.0 is **file-level** copyleft: static linking into a proprietary binary is
permitted, with the obligation to make any *modified* MPL source files available. We
modify none. Attribution belongs in the app's acknowledgements alongside
libdatachannel's.

Build options left **off** on purpose: `ENABLE_BONDING` (socket groups — sender-side
redundancy Manifold does not use), `ENABLE_AEAD_API_PREVIEW` and `ENABLE_MAXREXMITBW`
(unreleased v1.6.0 previews), `ENABLE_APPS` / `ENABLE_EXAMPLES` / `ENABLE_TESTING` /
`ENABLE_UNITTESTS`, and `ENABLE_SHARED`.

## Rebuilding
```sh
./scripts/build_mbedtls.sh          # only if the isolated prefix is missing
./scripts/build_libsrt.sh           # libsrt -> its own prefix -> staged here
```
`build_libsrt.sh` compiles in `~/manifold-srt-build` (a space-free scratch dir; the
repo path contains spaces) and installs into `~/manifold-srt-build/prefix`. It only
**reads** `~/manifold-webrtc-build/prefix`, so the WebRTC prefix stays exactly as
`build_mbedtls.sh` and `build_libdatachannel.sh` left it, and it shares no directory
with `ThirdParty/ffmpeg`.

It verifies, before anything is staged: arch (`arm64`, non-fat), the
`srt_startup` / `srt_create_socket` / `srt_connect` / `srt_recvmsg2` / `srt_close`
API surface, encryption really compiled in, that `libsrt.a` bundles **no** crypto of
its own and references no OpenSSL/GnuTLS/Botan, that every Mbed TLS symbol it needs is
provided by the already-staged archives, that no FFmpeg symbol is referenced, and that
no `/opt/homebrew` or `/usr/local` path appears inside the archive.

Everything is built from source. **Never `brew install` any of these** — a Homebrew
copy of OpenSSL or FFmpeg leaking into this build is both a correctness and a
licensing hazard for Manifold *and* for the other products that each ship their own
custom static FFmpeg.

## Gitignore
`lib/` and `include/` here are build outputs, not source, and are gitignored:

```
ThirdParty/libsrt/lib/
ThirdParty/libsrt/include/
```

**This README and `scripts/build_libsrt.sh` stay tracked** — they are the only record
of how the binaries were produced.
