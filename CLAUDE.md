# Manifold

Native macOS Swift/SwiftUI app. arm64 only. Product slug: `manifold`.

## Build, signing, and release

Procedure is NOT documented in this repo. It lives in the Graviton-Releases repo,
checked out as a sibling at `../../Graviton-Releases` (github.com/DCColor/Graviton-Releases,
private). Read it before answering anything about build, signing, release, or distribution:

- `docs/stacks/swift.md` — xcodegen/xcodebuild, direct codesign, notarytool, this app's
  pipeline
- `docs/DISTRIBUTION.md` — R2 layout, manifest.json schema, Worker routing
- `docs/IDENTITY.md` — certificates, renewal dates
- `docs/MACHINE-STATE.md` — build Mac state

Those documents are canonical. If anything here contradicts them, they are correct.

Note the identity string here includes the `Developer ID Application: ` prefix, because
this app calls `codesign` directly. The Electron apps must omit it. Same certificate, two
required spellings — see `IDENTITY.md`. Do not "fix" one to match the other.

## What is specific to Manifold

- `scripts/release-mac.sh` — the entire pipeline, one entry point
- `scripts/build_ffmpeg.sh`, `build_mbedtls.sh`, `build_libdatachannel.sh`,
  `build_libsrt.sh` — vendored dependency builds
- `project.yml` — XcodeGen input; version, build number, signing, embedded dylibs
- `ThirdParty/*/README.md` — provenance for the gitignored vendored libraries

## Rules

- `Profile` is the default build configuration and it has `DEBUG=1` — dev affordances are
  reachable by keystroke. Every build cut to date has been Profile. The configuration in
  the DMG filename is currently the only thing distinguishing a tester build from a public
  one. Do not remove it.
- FFmpeg ships as shared dylibs, not static archives, for LGPL 2.1 §6. Preflight fails if
  a `.a` reappears in `ThirdParty/ffmpeg/lib`. Do not "optimize" this.
- The five dylib soname majors are stated in three places. Bumping the pin means changing
  all three.