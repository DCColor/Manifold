# Manifold

Native macOS Swift/SwiftUI app. arm64 only. Product slug: `manifold`.

## Build, signing, and release

Procedure is NOT documented in this repo. It lives in the Graviton-Releases repo
(github.com/DCColor/Graviton-Releases, private), checked out somewhere ABOVE this repo —
`release-mac.sh` finds it by walking up, so the exact depth is not fixed. On this machine
it is at `~/Nextcloud/Vibe Code Output/Graviton-Releases`. Read it before answering
anything about build, signing, release, or distribution:

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

## Test environment

- Device-level audio measurement is **Audio Hijack + the OBS recorder instance only**. There is no
  hardware loopback on the Scarlett 18i20, and none will be set up. Never propose hardware
  loopback, a loopback driver, or capturing the interface. Details and each recorder's known limits:
  `docs/AV_SYNC_FINDINGS.md` §1.2.
- The recorder's audio source is re-picked by hand after every Manifold launch. Start Audio Hijack
  only after Manifold has connected: started earlier, it can quit or relaunch Manifold.
- OBS test profiles: `docs/OBS_TEST_PROFILES.md` says what each profile sends. Before an attended OBS
  step, name the profile and check it against its row; afterwards, compare OBS's log with the row.
  Never change a tested profile for an experiment: duplicate it and add a row first. Read OBS's
  settings files read-only, and never copy a URL, stream key or passphrase out of them.

## Rules

- `Profile` is the default build configuration and it has `DEBUG=1` — dev affordances are
  reachable by keystroke. Every build cut to date has been Profile. The configuration in
  the DMG filename is currently the only thing distinguishing a tester build from a public
  one. Do not remove it.
- FFmpeg ships as shared dylibs, not static archives, for LGPL 2.1 §6. Preflight fails if
  a `.a` reappears in `ThirdParty/ffmpeg/lib`. Do not "optimize" this.
- The five dylib soname majors are stated in three places. Bumping the pin means changing
  all three.
- Never write a macOS defaults key without reading it first. `defaults write` REPLACES the
  value wholesale — for an array or a dictionary it does not merge — so writing one key
  destroys whatever was already under it. Read and stash the existing value before any
  write, restore it after. This rule exists because `streamBookmarks` was erased during
  LIVECLOCK verification and there was no way back: no snapshots, no Time Machine, no
  store-side backup. See the stream-bookmark durability item in `docs/BUGS.md`.
- Manifold is server-agnostic. Implement the protocol standard, never a specific server's
  behaviour: no code path may branch on which server or vendor it is talking to. Where a
  server deviates from the standard, fall back to the pre-existing behaviour and log the
  deviation; never special-case it. Cloudflare is one test target, not the target: every
  streaming fix is verified against at least one non-Cloudflare server (local OBS SRT, NDI,
  or MediaMTX for WHIP/WHEP) before it is committed. Constants must not be tuned from a
  single server's traces.
- Source colour changes only through `MetalVideoRenderer.setSourceColorSpace` (and a live teardown
  only through `SavedDisplayProviders.restore`, which clears it). Nothing writes scope colour state
  directly: the scope models' `sourceMatrixCode`, `sourceTransferCode`, `sourcePrimariesCode` and
  `spaceReadout` are written only by `ScopeColorFeed`, from the renderer. A new transport or a
  colorimetry override reaches the scope headers by reaching the renderer. Per-transport scope
  writes are how the headers came to describe a previous source (2026-10-06).
- Chroma is native end to end. Manifold supports 4:2:0, 4:2:2 and 4:4:4 natively: every source is
  decoded at its own chroma resolution (4:2:0 → `x420`, 4:2:2 → `x422`, 4:4:4 → `x444`) and carried
  unchanged to the renderer, scopes, window and export. Scrub and playback take the format from the
  same resolver, so their frames stay byte-identical. Chroma is reduced only where an output requires
  it, once, at that output, with a proper filter. Today that is only the DeckLink output, which uses
  v210 (4:2:2). SDI itself carries 4:4:4; 4:4:4 SDI output is a roadmap idea. Where a Mac or path
  can't keep native chroma, the chain readout and a banner say so. Never silently. Audit and stages:
  `docs/COLOR_MANAGEMENT_FINDINGS.md` §6.10, Stage 3b (decided 2026-10-10).
- Never add Co-Authored-By or any AI authorship trailer to commit messages or PR descriptions.
