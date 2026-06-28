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

Built with the DNxHD/DNxHR decoder, MOV + MXF demuxers, and swscale — the pieces
the DNxHR decode source (Stage 2b) needs.

## Provenance
Produced by the DNxHR linking spike (`~/manifold-dnxhr-spike/`), which built
FFmpeg `n8.1.1` from source as self-contained static libs (verified `otool -L`
clean, zero Homebrew/user paths) and proved they link + bridge into a Swift
binary. These are the exact `ff/lib` + `ff/include` artifacts from that build.

System libraries the static libs depend on (all OS-provided, linked at the app):
`libz`, `libbz2`, `libiconv`, and the `CoreFoundation` / `CoreServices` /
`Security` frameworks.

## Rebuilding
Re-run the spike's FFmpeg `n8.1.1` static configure/build, then copy its
install-prefix `lib/{libavcodec,libavformat,libavutil,libswscale,libswresample}.a`
and `include/` here. Keep it static and self-contained — never link a Homebrew or
system ffmpeg.
