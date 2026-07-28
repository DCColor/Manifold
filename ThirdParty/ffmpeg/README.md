# FFmpeg (shared libav) — vendored, project-local

> ## ⚠️ OUTSTANDING — LGPL 2.1 §6 is not finished
>
> Shipping the dylibs (below) satisfies **§6(b)** — the user can relink. Two obligations are
> deliberately **NOT yet done**, split out to keep the shared-library change reviewable:
>
> 1. **The source obligation.** §6 requires the Library's complete corresponding source to
>    accompany the work, or a §6(c) written offer valid for three years. We now have an exact
>    pin (`n8.1.1` @ `239f2c733de417201d7ad3b3b8b0d9b63285b2b1`, see below), so the cheapest
>    compliant form is a written offer plus that tag/commit published with the release.
>    `App/Licenses/` already carries `LGPL-2.1.txt` and `FFmpeg-LICENSE.md.txt`, and
>    `App/AboutWindow.swift` already surfaces attributions — that is where it goes.
> 2. **Relink instructions.** §6(b) is about a user *being able* to relink. Replacing a dylib in
>    `Contents/Frameworks` breaks the app bundle's signature seal, so the practical recipe is
>    "replace the dylib, ad-hoc sign it (`codesign -s - libavcodec.62.dylib`), re-sign the
>    bundle". That works because `com.apple.security.cs.disable-library-validation` is set —
>    see below. Without written instructions the mechanism exists but is undiscoverable.
>
> Until both land, the app ships a §6-capable binary without the paperwork that makes §6 real.

These are **shared** libav dylibs + headers, vendored into the repo and **gitignored**. They are
embedded in `Manifold.app/Contents/Frameworks` and resolved via `@rpath` — **no Homebrew, no
`/usr/local`, no system ffmpeg, no PATH lookup, and no absolute path into anyone's build tree.**

## Why shared and not static — this is a licence requirement, not a preference

Manifold links FFmpeg, which under **LGPL 2.1 §5** makes the app a work that uses the Library.
**§6** then requires that a user be able to **relink the application against a modified FFmpeg**.
Static `.a` linking makes that impossible: the libav code is fused into the app binary and there
is nothing left to replace. Shipping the dylibs where a user can swap them satisfies **§6(b)**.

**Manifold's own source stays proprietary either way — this is not a GPL question.** The build is
LGPL by construction and stays that way: `CONFIG_GPL 0`, `CONFIG_NONFREE 0`, `CONFIG_VERSION3 0`,
all asserted on every rebuild.

> **Reverting these to static archives would put the shipping app out of compliance while
> changing nothing observable.** That is exactly why `scripts/release-mac.sh` fails preflight if
> it finds a `.a` in `ThirdParty/ffmpeg/lib`.

## What this is

- **FFmpeg 8.1.1** (`n8.1.1`), built from source as shared libraries by
  `scripts/build_ffmpeg.sh`.
- `lib/` — the five libraries Manifold ships:

  | real file | link-time symlink | embedded in bundle |
  |---|---|---|
  | `libavcodec.62.dylib` | `libavcodec.dylib` | ✅ |
  | `libavformat.62.dylib` | `libavformat.dylib` | ✅ |
  | `libavutil.60.dylib` | `libavutil.dylib` | ✅ |
  | `libswscale.9.dylib` | `libswscale.dylib` | ✅ |
  | `libswresample.6.dylib` | `libswresample.dylib` | ✅ |

  The **major-suffixed name is the real file** and is what dyld looks for, because it is the
  string baked into each `install_name` (`@rpath/libavcodec.62.dylib`). The **unsuffixed symlink
  is link-time only** — `-lavcodec` searches for `libavcodec.dylib` and would not find a
  major-suffixed name — and is deliberately **not** embedded.
- `include/` — the matching public headers. `libavdevice` and `libavfilter` are **built** by this
  configure but neither staged nor shipped; their headers are removed at staging so nothing can
  be written against a library that is not in the bundle.

Built with the **DNxHD/DNxHR** and **ProRes** decoders, **MOV + MXF + MPEG-TS** demuxers, the
**h264 parser**, the pcm/aac audio decoders, and **swscale**.

## ⚠️ `--disable-network` is DELIBERATE and LOAD-BEARING — do not "helpfully" enable it

This build has **no network layer at all**: `ff_file_protocol` is the only protocol compiled in,
and `avformat_network_init()` is a no-op stub. That is on purpose.

**Every byte that reaches `libavformat` arrives through a custom `AVIOContext`.** The SRT
transport is `ThirdParty/libsrt` (libsrt owns the socket, hands us an MPEG-TS byte stream); the
WHEP transport is `ThirdParty/libdatachannel`. FFmpeg's job here is **demux and decode only** — it
never opens a socket, resolves a host, or speaks a protocol.

Turning network support back on would:
- add a **second, competing SRT/UDP/RTP implementation** inside the same binary, linked alongside
  libsrt and libdatachannel;
- expose an `avformat_open_input("srt://…")` / `("http://…")` path that silently bypasses the
  transport layer, its lifecycle and its error handling;
- pull in TLS/DNS dependency surface this project has spent real effort keeping out (see
  `scripts/build_mbedtls.sh` on why there is no OpenSSL or GnuTLS anywhere).

If a future format appears to need it, the answer is another custom `AVIOContext`.

The rebuild script asserts this from **two independent directions**: `config.h` says exactly one
protocol is compiled in, and the **shipped dylib is asked at runtime** to enumerate its protocols
and must answer `file` and nothing else.

## ⚠️ THE OLD `nm` VERIFICATION RECIPES ARE DEAD — do not resurrect them

This file used to verify the build with four `nm` greps for `ff_mov_demuxer`, `ff_dnxhd_decoder`,
`ff_file_protocol` and friends. **On a shared build those all fail**, and they fail in the most
misleading way possible: by reporting that the demuxers vanished from a perfectly good dylib.

Two independent reasons, both visible in `ffbuild/config.mak`:

- `SHFLAGS` carries `-Wl,-exported_symbols_list,libavcodec.ver` — the dylib exports **only the
  public API** (`av*`/`sws*`/`swr*`). Every `ff_*` internal is hidden by construction.
- `STRIP = strip -x`, run by `install-lib$(NAME)-shared` — local symbols are removed on install.

**The replacement is stronger than what it replaced.** Instead of grepping a symbol table for a
proxy, it loads the shipped dylib and asks libavformat to enumerate its own demuxers, decoders,
parsers and protocols:

```sh
./scripts/build_ffmpeg.sh --verify-only
```

## Provenance

**Pinned**, which it was not before. The source is a git checkout asserted against a commit SHA:

```
n8.1.1 = 239f2c733de417201d7ad3b3b8b0d9b63285b2b1
```

A tag is not a pin — tags can be moved. The SHA is the pin; `scripts/build_ffmpeg.sh` refuses to
build if `HEAD` does not match it or if the working tree has local modifications.

### What came before, and what was settled

Until 2026-07-28 this build was performed **by hand** in `~/manifold-ffmpeg-srt/`, from an
**extracted tarball with no `.git`, no tag and no checksum**. The exact configure line survived
only as line 1 of `ffbuild/config.log` inside that untracked directory. Both gaps are now closed.

That left one open question: were the archives shipping in 0.5.1 actually built from *unmodified*
upstream? It could not be answered from the tree itself. `--provenance-only` settled it by
comparing every git-tracked file at the pin against that legacy tree:

> **10,133 files compared — byte-identical.** The by-hand tree was unmodified upstream `n8.1.1`.

## The configure line — four numbered changes (five flags) from the 0.5.1 baseline

The baseline is recorded verbatim in `scripts/build_ffmpeg.sh`. **Nothing else may differ**, and a
further difference cannot arrive unannounced — the script asserts the line against a literal array
and prints exactly which flags drifted. (CHANGE 1 is a pair of flags, which is why four numbered
changes are five flags.)

| # | change | why |
|---|---|---|
| 1 | `--enable-static --disable-shared` → `--enable-shared --disable-static` | The LGPL §6 change itself. Two flags. |
| 2 | `+ --enable-decoder=prores` | Makes a libav fallback possible for AVFoundation-rejected ProRes (see below). Costs a few hundred KB. |
| 3 | `+ --install-name-dir=@rpath` | **Required by 1.** Darwin bakes `install_name` at link time from `$(SHLIBDIR)` — an absolute path into the build machine's home directory. Shipped unchanged, the app would work here and fail to launch everywhere else. Also fixes every inter-library reference in one step. |
| 4 | `+ --extra-cflags/--extra-ldflags=-mmacosx-version-min=15.0` | **Fixes a pre-existing defect.** The by-hand build passed no deployment target, so it inherited the host default: the 0.5.1 archives carry `minos 26.0` against an app targeting macOS 15.0, producing **226** `built for newer 'macOS' version` linker warnings. `scripts/build_libsrt.sh` already pins this pair for the other three vendored libraries. Now **0** warnings. |

**Not added: `--enable-pic`** — unnecessary. clang defines `__PIC__` by default on arm64 Darwin
and configure picks it up; the *previous static* build already had `CONFIG_PIC 1`. The script
asserts `CONFIG_PIC 1` instead, which is a stronger statement than passing the flag.

**Not added: `--arch=arm64`** — redundant; configure already detects aarch64. arm64-only is
asserted with `lipo` on each staged dylib instead.

## Rebuilding

```sh
./scripts/build_ffmpeg.sh                 # clone at the pin, configure, build, stage, verify
./scripts/build_ffmpeg.sh --verify-only   # re-run every assertion against what is staged
./scripts/build_ffmpeg.sh --provenance-only
FFMPEG_PIN_BOOTSTRAP=1 ./scripts/build_ffmpeg.sh   # rotate the pin
```

Never link a Homebrew or system ffmpeg, and **keep `--disable-network`**.

### Three-layer verification, and why there are three

1. **The configure line** — asserted against a literal array, quoting- and order-agnostic.
   Runs *before* the compile, so drift costs seconds rather than a full build.
2. **The configured outcome** (`config.h`) — because a correct command line against a stale tree
   produces a wrong artifact and a *passing* string check. Includes negative sweeps: every
   protocol except `file`, every demuxer except the three, and all muxers/encoders/bsfs must be
   `0`. Written as sweeps rather than blocklists so a component added by a future FFmpeg still
   fails instead of slipping through.
3. **The shipped dylib** — a probe links against the staged dylibs and interrogates them, then
   reads `avutil_configuration()` back out and runs it through assertion 1 again. That closes the
   gap between the first two (which describe a *build tree*) and what actually ships.

### After building the app

```sh
./scripts/build_ffmpeg.sh --verify-relocatable /path/to/Manifold.app
```

**This is the check that catches the absolute-`install_name` failure without a second Mac.** That
failure is invisible on the build machine — the path resolves here and nowhere else — and
`otool -L` only reads recorded strings, so it cannot tell you what dyld would actually do. The
mode moves the build prefix *and* `ThirdParty/ffmpeg/lib` aside, which is precisely what a second
machine looks like to dyld, then launches a quarantined copy from outside the build tree.

(`DYLD_PRINT_LIBRARIES` is stripped by hardened runtime on a signed binary, so it reports nothing
for a release build. The launch result is still decisive: with the build tree unavailable, an
absolute `install_name` could not have resolved.)

## How this is wired into the app

- **`project.yml` → `dependencies:`** — five `framework:` entries with `embed: true`,
  `link: false`, `codeSign: true`. `link: false` is deliberate: linking still happens through the
  `-lavformat`/`-lavcodec`/… flags in `OTHER_LDFLAGS`, unchanged from the static era. These
  entries do embedding and signing only.
- **`project.yml` → `LD_RUNPATH_SEARCH_PATHS`** — `@executable_path/../Frameworks`. Xcode supplies
  this by default for a macOS app target, but it is stated explicitly because the dylibs do not
  load without it.
- **Signing** — Code Sign On Copy signs each dylib into the archive with the development identity;
  `xcodebuild -exportArchive` re-signs the nested code with Developer ID. Verified on the exported
  bundle: all five carry `Developer ID Application: Amigo Media LLC`, `flags=0x10000(runtime)` and
  a secure timestamp. `release-mac.sh` asserts each of those, because unsigned nested code
  notarizes as **Invalid** while the app still runs perfectly on this machine.
- **`com.apple.security.cs.disable-library-validation`** (`App/Manifold.entitlements`) — was there
  for the NDI `dlopen` and the DeckLink `CFBundle` load. It is **now additionally what lets a
  user's replacement libav dylib load at all** under hardened runtime, i.e. the runtime half of
  the §6 relinking right. Do not remove it on the grounds that NDI/DeckLink no longer need it.
- **`Packages/ManifoldCore/Package.swift`** — unchanged; it only supplies the header search path.

## Size, measured

Static → shared, Profile archive, like for like:

| | 0.5.1 (static) | now (shared) | delta |
|---|---|---|---|
| main binary | 7,830,016 B | 4,957,328 B | **−2.87 MB** |
| `Contents/Frameworks` | — | 3,364 KB | +3.28 MB |
| app bundle | 8,764 KB | 9,324 KB | **+560 KB** |
| DMG (UDZO) | 4,384,593 B | 4,995,424 B | **+611 KB** |

The bundle grows by far less than the dylibs weigh, because the binary loses everything the
archives used to contribute. The five dylibs total **3.21 MB** on disk against 14.27 MB of
archives — most of that 14.27 MB was per-object symbol tables and relocations that never reached
a linked binary anyway.

## Banked: what `--enable-decoder=prores` was for

Added in this rebuild, **not yet used by anything shipping.** The narrow decoder list closed off
an option twice on the same day (2026-07-28):

1. **A libav fallback for AVFoundation-rejected files.** `A027C021_171116_R022.mov` (ProRes 4444,
   `ap4h`) is refused by AVFoundation — its video `stsd` carries 8 trailing zero bytes that parse
   as a box with SIZE 0, so the sample description is rejected and the video track is dropped from
   the asset entirely. Quick Look fails on it for the same reason; libav reads it without
   complaint. Routing such files to the libav path we already have would be the natural rescue —
   the `mov` demuxer is compiled in — except there was **no ProRes decoder**, so libav could demux
   it and then have nothing to decode it with. That is now possible.
2. **Reuse of this build by Flip**, which spawns an `ffmpeg` CLI and needs muxers, filters and
   stream-copy that `--disable-everything` strips. (Separate problem — this build also produces no
   CLI at all, per `--disable-programs`.)

**The decision to make first is whether an AVFoundation-rejected file should fall back to libav at
all.** The flag only makes it possible.

## System libraries

All OS-provided, and now carried by the dylibs themselves rather than declared at the app link:
`libSystem`, plus the `CoreFoundation` / `CoreVideo` / `CoreMedia` frameworks (from
`EXTRALIBS-avutil`).

Note `CONFIG_ZLIB`, `CONFIG_BZLIB` and `CONFIG_ICONV` are all **0** — a consequence of
`--disable-autodetect`, which is also the proof that no external library was probed for and no
Homebrew copy could have been picked up. The `-lz -lbz2 -liconv` still in `OTHER_LDFLAGS` are
therefore dead weight for libav's sake; they are left alone as out of scope for this change.
