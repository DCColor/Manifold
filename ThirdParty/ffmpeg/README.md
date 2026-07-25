# FFmpeg (static libav) — vendored, project-local

These are **static** libav archives + headers, vendored into the repo and
**gitignored** (like Flip's `binaries/`). They are linked statically into the
Manifold binary — **no Homebrew, no `/usr/local`, no system ffmpeg, no PATH
lookup.** The build is fully self-contained; `otool -L` on the built app stays
clean (only `@rpath`/`/usr/lib`/`/System/Library`).

## What this is
- **FFmpeg 8.1.1** (`n8.1.1`), built from source as static `.a` libraries.
- `lib/`: `libavcodec.a`, `libavformat.a`, `libavutil.a`, `libswscale.a`,
  `libswresample.a`
- `include/`: the matching public headers.

Built with:
- the **DNxHD/DNxHR decoder**, **MOV + MXF demuxers** and **swscale** — the pieces
  the DNxHR decode source (Stage 2b) needs;
- the **mpegts demuxer** and the **h264 parser** — the pieces the SRT source needs
  (added 2026-07-25).

## ⚠️ `--disable-network` is DELIBERATE and LOAD-BEARING — do not "helpfully" enable it
This build has **no network layer at all**: `ff_file_protocol` is the only protocol
compiled in, and `avformat_network_init()` is a no-op stub. That is on purpose.

**Every byte that reaches `libavformat` arrives through a custom `AVIOContext`.** The
SRT transport is `ThirdParty/libsrt` (libsrt owns the socket, hands us an MPEG-TS byte
stream); the WHEP transport is `ThirdParty/libdatachannel`. FFmpeg's job here is
**demux and decode only** — it never opens a socket, resolves a host, or speaks a
protocol.

Turning network support back on would:
- add a **second, competing SRT/UDP/RTP implementation** inside the same binary,
  linked alongside libsrt and libdatachannel;
- expose an `avformat_open_input("srt://…")` / `("http://…")` path that silently
  bypasses the transport layer, its lifecycle, and its error handling;
- pull in TLS/DNS dependency surface that this project has spent real effort keeping
  out (see `scripts/build_mbedtls.sh` on why there is no OpenSSL or GnuTLS anywhere).

If a future format appears to need it, the answer is another custom `AVIOContext`, not
`--enable-network`.

## Provenance
Originally produced by the DNxHR linking spike (`~/manifold-dnxhr-spike/`), which built
FFmpeg `n8.1.1` from source as self-contained static libs (verified `otool -L` clean,
zero Homebrew/user paths) and proved they link + bridge into a Swift binary.

**Rebuilt 2026-07-25 in `~/manifold-ffmpeg-srt/`** to add the **mpegts demuxer** and
**h264 parser** for the SRT source, keeping `--disable-network` and everything the
DNxHR path already relied on. The archives here are that build's artifacts.

System libraries the static libs depend on (all OS-provided, linked at the app):
`libz`, `libbz2`, `libiconv`, and the `CoreFoundation` / `CoreServices` /
`Security` frameworks.

## Rebuilding
Re-run the `~/manifold-ffmpeg-srt/` FFmpeg `n8.1.1` static configure/build, then copy
its install-prefix
`lib/{libavcodec,libavformat,libavutil,libswscale,libswresample}.a` and `include/`
here. Keep it static and self-contained — never link a Homebrew or system ffmpeg, and
**keep `--disable-network`** (see above).

After any rebuild, confirm the four things this project depends on are still in the
archives — and that the network layer still is not:

```sh
nm -o lib/libavformat.a | grep -E ' [TDSC] _ff_(mpegts|mov|mxf)_demuxer$'
nm -o lib/libavcodec.a  | grep -E ' [TDSC] _ff_(h264_parser|dnxhd_decoder)$'
nm -o lib/libavformat.a | grep -E ' [TDSC] _avio_alloc_context$'
nm -o lib/libavformat.a | grep -E ' [TDSC] _ff_[a-z0-9_]+_protocol$'   # must be ff_file_protocol ONLY
```
