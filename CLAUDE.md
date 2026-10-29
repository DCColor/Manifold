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
- Displays on the Mac Studio. **LG**: a calibrated, HDR-capable UI/desktop display (SDR and HDR). Close to
  reference, but NOT a reference monitor and not used for grading. Use it for any HDR viewing and for
  by-eye checks, which are sanity checks, never reference judgements. **ASUS (PA147)**: Rec. 709 SDR only,
  uncalibrated. Use it only for pixel-value checks (the OS-mode byte comparisons, the γ1.961 double-apply
  check), never for judging colour or HDR. A plan or prediction that puts an HDR or by-eye check on the
  ASUS is wrong; move it to the LG. **True reference monitoring is over SDI to a reference monitor**; no
  desktop display is the reference.
- Test media under `/Volumes/DCCOLOR/TEST FLIP` may have had its colour metadata changed on purpose (Flip demos),
  so a file's name may not match its tags. The file's own tags are the truth; its name is only a hint. Report a
  name/tag mismatch as a finding, not a defect (e.g. `MXF NCLc Matrix/cs709-g24.mxf`, `docs/color-fixtures/README.md`).
  **Never modify, retag or rewrite files on that volume**: open them read-only, in place.
- Screenshots capture the Manifold window only, by its window ID (`screencapture -x -o -l <id>`, the id
  from `CGWindowListCopyWindowInfo` for the owner "Manifold"), never the whole desktop: other windows on
  this Mac hold private conversations and credentials. If the window cannot be found, take no screenshot.
  Delete a screenshot once what it shows is recorded in text.
- Never send ⌘Q, or any keystroke, to quit or control an app. A keystroke (`System Events … keystroke`,
  `key code`) goes to whatever app is in front, not to the process named in the script: a ⌘Q meant for
  Manifold quit VS Code mid-session (2026-10-19). Drive Manifold through accessibility clicks on named
  elements, never keystrokes. Close an open menu with `perform action "AXCancel"` on that menu, not
  Escape: a Quit event waits while a menu is open.
- **Launch a build only by executing its binary directly, so the driver holds its PID. Quit it only by
  that PID, through `scripts/manifold-proc.sh quit <pid>`.** The helper checks the PID is alive and is a
  build from this tree, then sends a Quit event to that process alone. Open files in a running build with
  `manifold-proc.sh open <pid> <file>`. Never address Manifold by name, path or bundle id: no `tell
  application "…" to quit`, no `open -a` / `open -b`, no `xctrace --launch`, no `pkill`/`killall` by
  name. Sent to a build that has already exited, a by-name or by-path Quit makes AppleScript launch the
  app, and Launch Services can resolve it to the installed `/Applications/Manifold.app` (0.8.4). That
  copy rewrites licence values in the real plist (2026-10-27, 2026-10-28; `docs/BUGS.md`, privacy P1).
- **Guard every run:** `manifold-proc.sh guard` before and after. If any process of
  `/Applications/Manifold.app` is running, stop and report it. Never quit it yourself.
- **Tell Robbie before launching any build**, unless he has started an attended step that launches it:
  a launched build takes focus, and his typing goes to it.

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
- Any command sequence that writes macOS defaults must stop at the first failure: chain with
  `&&` or run under `set -e`, never `;`. Every `defaults write` must be preceded, in the same
  sequence, by a read that succeeded. A `;` chain once let a write run after its input had
  failed to build, and it wrote an empty value (colour S5, 2026-10-13; the stash restored it).
- Manifold is server-agnostic. Implement the protocol standard, never a specific server's
  behaviour: no code path may branch on which server or vendor it is talking to. Where a
  server deviates from the standard, fall back to the pre-existing behaviour and log the
  deviation; never special-case it. Cloudflare is one test target, not the target: every
  streaming fix is verified against at least one non-Cloudflare server (local OBS SRT, NDI,
  or MediaMTX for WHIP/WHEP) before it is committed. Constants must not be tuned from a
  single server's traces.
- The renderer carries two sets of colour codes. **Source codes** (`source*Code`, what the source is)
  change only through `MetalVideoRenderer.setSourceColorSpace` (and a live teardown only through
  `SavedDisplayProviders.restore`, which clears it). They drive the Source line, an override's decode
  matrix and provenance. **Picture codes** (`picture*Code`, what the picture is) are the Interpretation
  LUT's stated output space while a LUT is loaded, otherwise the source codes. The LUT and its output
  space change only through `MetalVideoRenderer.setInterpretationLUT`, and only `resolvePictureCodes`
  (called by those two setters) writes the picture codes. The picture codes drive the layer colourspace,
  EDR, the scope headers and scope maths, the SDI tag, the v210 matrix, the export ICC, Reference's plan
  and the CIE scope. The one exception: a frame converted from P3-D65 or DCI-P3 to Rec.2020 primaries for SDI is
  encoded with the BT.2020 NCL matrix, to match its Rec.2020 signal (`OutputSignal.sdiMatrixCode`, S7 follow-up 1). With no LUT, or at Same as Source, the two sets are identical. Code that describes
  the picture reads picture codes; code that describes the source reads source codes
  (`docs/COLOR_MANAGEMENT_FINDINGS.md` §6.11, S6 D3, amended in L2). Nothing writes scope colour state
  directly: the scope models' `sourceMatrixCode`, `sourceTransferCode`, `sourcePrimariesCode` and
  `spaceReadout` are written only by `ScopeColorFeed`, from the renderer's picture codes (with no source,
  `WindowDeck.hasSource` false, from its cleared source codes, the header reading "no source"; L3). A new
  transport, a colorimetry override or a LUT reaches the scope headers by reaching the renderer.
  Per-transport scope writes are how the headers came to describe a previous source (2026-10-06).
- Chroma is native end to end. Manifold supports 4:2:0, 4:2:2 and 4:4:4 natively: every source is
  decoded at its own chroma resolution (4:2:0 → `x420`, 4:2:2 → `x422`, 4:4:4 → `x444`) and carried
  unchanged to the renderer, scopes, window and export. Scrub and playback take the format from the
  same resolver, so their frames stay byte-identical. Chroma is reduced only where an output requires
  it, once, at that output, with a proper filter. Today that is only the DeckLink output, which uses
  v210 (4:2:2). SDI itself carries 4:4:4; 4:4:4 SDI output is a roadmap idea. Where a Mac or path
  can't keep native chroma, the chain readout and a banner say so. Never silently. Audit and stages:
  `docs/COLOR_MANAGEMENT_FINDINGS.md` §6.10, Stage 3b (decided 2026-10-10).
- Never add Co-Authored-By or any AI authorship trailer to commit messages or PR descriptions.
