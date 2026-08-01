# Manifold — Build

Stack: Swift / SwiftUI, native macOS. arm64 only, macOS 15.0+
Product slug: `manifold`

---

## Process documentation lives elsewhere

Build, signing, release, and distribution **procedure is not documented here.** It lives in
the Graviton-Releases repo, checked out as a sibling at `../../Graviton-Releases`
(github.com/DCColor/Graviton-Releases, private):

| Document | Covers |
|---|---|
| `docs/stacks/swift.md` | xcodegen/xcodebuild, direct `codesign`, notarytool, this app's pipeline shape |
| `docs/DISTRIBUTION.md` | R2 layout, `manifest.json` schema, Worker routing, public URLs, `upload-release.sh` |
| `docs/IDENTITY.md` | Apple accounts, certificates, renewal dates |
| `docs/MACHINE-STATE.md` | build Mac state, keychain, what is not backed up |

**Those documents are canonical.** If anything in this file contradicts them, they are
correct and this file is stale.

⚠️ **The signing identity string here includes the `Developer ID Application: ` prefix**,
because this app calls `codesign` directly. The Electron products must omit it or
electron-builder rejects the config. Same certificate, two required spellings. Do not
"fix" one to match the other.

Everything below is specific to Manifold.

---

## One entry point

```
scripts/release-mac.sh [Profile|Release] [--no-upload]
```

- `Profile` — tester build, telemetry compiled in. **This is the default.**
- `Release` — public build, per-second telemetry compiled out
- `--no-upload` — build, sign, notarize, staple, and verify, but do not publish

`MANIFOLD_DIST_DIR` overrides the output directory (default `~/Builds/Manifold/`).

The script runs: preflight → version read → build-number bump → `xcodegen generate` →
`xcodebuild archive` → `-exportArchive` → verify app and nested dylibs → build DMG → sign
DMG → notarize → staple → validate → publish → verify the published manifest. Every stage
is a hard failure.

**No CI.** Every release is cut by hand from the build Mac. Mac-only, so there is no
Windows runner and no GitHub Actions workflow in this repo at all.

**Output goes outside the repo** — `~/Builds/Manifold/<version>-<build>-<config>-<stamp>/`
— because the repo lives inside a Nextcloud sync tree whose chunked upload has corrupted
large artifacts on sibling products. This is the pattern the Electron apps should copy.

---

## Prerequisites

Asserted by preflight; none are version-pinned anywhere.

**Tools:** `xcodegen`, `xcodebuild`, `create-dmg`, `codesign`, `hdiutil`, `python3`, and —
when publishing — `wrangler` and `curl`. `notarytool` and `stapler` must be findable in the
active Xcode.

**Machine state:** the Developer ID identity in the login keychain, and a working
`graviton-notarytool` profile. Preflight tests the notarization profile *before* building
rather than discovering it is broken after a 20-minute archive.

**SDKs, copied in by hand, both gitignored:**

- DeckLink SDK 16.0 → `docs/BlackmagicDeckLinkSDK16.0/Mac/include/`. `DeckLinkAPIDispatch.cpp`
  from it is compiled directly into the app target. The runtime is the user's own installed
  `/Library/Frameworks/DeckLinkAPI.framework`.
- NDI SDK for Apple → installed system-wide at `/Library/NDI SDK for Apple/include`.
  **Never vendored** — the licence does not permit it. The runtime `libndi.dylib` is
  `dlopen`'d at `/usr/local/lib/`, so nothing NDI-derived ships. If the user does not have
  it, the app still launches.

**Vendored libraries**, all gitignored, all built by scripts in this repo:

| Thing | Staged to | Built by | Source |
|---|---|---|---|
| FFmpeg — 5 shared dylibs + headers | `ThirdParty/ffmpeg/` | `scripts/build_ffmpeg.sh` | n8.1.1, commit `239f2c733de417201d7ad3b3b8b0d9b63285b2b1` |
| libdatachannel + juice + srtp2 + usrsctp + Mbed TLS | `ThirdParty/libdatachannel/` | `build_mbedtls.sh` → `build_libdatachannel.sh` | v0.24.5 / v3.6.7 |
| libsrt | `ThirdParty/libsrt/` | `scripts/build_libsrt.sh` | v1.5.6 |

Scratch trees live in `$HOME` (`~/manifold-ffmpeg-build`, `~/manifold-webrtc-build`,
`~/manifold-srt-build`) because the repo path contains spaces. **None are backed up.**
They are reproducible from the pins, but reproducing them takes real time.

---

## Pre-release checklist

- [ ] `MARKETING_VERSION` in `project.yml` is the version you intend to ship
- [ ] `RELEASE_NOTES.md` has a `## <version>` section, heading matching `MARKETING_VERSION`
      exactly — the uploader's parser requires it or the manifest ships `"notes": []`
- [ ] All three `ThirdParty/` trees present and built
- [ ] DeckLink SDK in `docs/`, NDI SDK installed
- [ ] Decide `Profile` or `Release` — see the warning below
- [ ] After the release: commit the `CURRENT_PROJECT_VERSION` bump the script wrote

---

## ⚠️ Profile is the default, and Profile ships

`Profile` is a fully optimized build **with `DEBUG=1`**. Every `#if DEBUG` block is live:

- ⌃⌥D SRT connect and ⌃⌥H WHEP connect
- the Experiment 3 colourspace-destination cycling (`[CSDEBUG]` / `[CSPROBE]`), which fires
  on every source load
- `SyntheticLiveSource`
- the `/tmp/manifold_debug_cs` file hook
- per-second `[SRT-FLOW]` / `[WHEP-FLOW]` telemetry that `Export Diagnostics…` depends on

**Unless someone types `Release`, Profile is what gets published to the public
`releases.graviton.tools/manifold/mac-arm64` URL.** Every build cut to date has been
Profile — confirmed from `~/Builds/Manifold/`, which holds 0.5.0 builds 2–4 and 0.5.1
builds 5–6, all Profile.

That is currently fine — everyone downloading is a tester — and stops being fine the moment
a stranger has the link.

`Release` compiles those out and loses the diagnostics that make "judders on my machine"
reportable, which is why Profile was chosen. Nothing is transmitted anywhere; diagnostics
are user-initiated and redacted. The objection is unaudited dev affordances in a public
build, not privacy.

**Before switching the public download to Release you need:** the dev-path audit done, the
Core telemetry leak fixed (below), and a decision about whether some telemetry should
survive into Release so a shipped user can report a stutter at all.

**The DMG filename is the only thing distinguishing the two once published** —
`Manifold-0.5.1-6-Profile.dmg`. The Graviton convention is `<App>-<version>-<arch>.<ext>`;
this deviation is deliberate and load-bearing. It stays until the tester and public
channels are separated — a distinct R2 prefix for testers, with the script refusing
`Profile` → `current/`. Removing it before then removes the last signal.

---

## Versioning

Version and build number live in `project.yml`:

```yaml
MARKETING_VERSION: "0.5.1"
CURRENT_PROJECT_VERSION: "6"
```

The release script reads `MARKETING_VERSION`, increments `CURRENT_PROJECT_VERSION` by one,
and writes it back with `sed`. **The operator commits the bump afterwards** — the script
does not.

`App/Info.generated.plist` carries different values (1.0 / 1). That is intentional:
`GENERATE_INFOPLIST_FILE: YES` makes the build settings win, and the script asserts the
built plist against `project.yml` after archiving.

**Manifold is the only Graviton product with a build number**, which is why the manifest's
optional `build` field exists. `UpdateChecker` uses it as a tie-break when versions match.

Because the build number auto-increments on every run, re-releasing the same version
overwrites its archived artifact in `archive/<version>/`. **A published artifact should
mean a new version number.**

---

## Signing specifics

Signing settings live in `project.yml`, not in a separate config file:

```yaml
CODE_SIGN_STYLE: Automatic
ENABLE_HARDENED_RUNTIME: YES
DEVELOPMENT_TEAM: 8UQ7MDM87B
CODE_SIGN_ENTITLEMENTS: App/Manifold.entitlements
ARCHS: arm64
```

`build/ExportOptions.plist` is gitignored and regenerated by the script if absent, so a
fresh clone is unaffected.

**Entitlements are one key**, because the app loads unsigned third-party dylibs:

```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

**Nested dylibs.** The five FFmpeg dylibs are `embed: true, link: false, codeSign: true`
in `project.yml`, re-signed by `-exportArchive`, then asserted per dylib for install name
(`@rpath/…`), authority, hardened runtime flag, and timestamp — all four, all fatal. This
is the reference implementation for nested-binary verification across Graviton; the
Electron stack was built to match it.

**Unlike Electron, the DMG itself is signed here**, and stapling is explicit rather than
handled by a packaging tool.

---

## LGPL corresponding source

FFmpeg ships as **shared dylibs, not static archives**, to satisfy LGPL 2.1 §6. Preflight
fails if a `.a` reappears in `ThirdParty/ffmpeg/lib`, which would silently undo the
migration. Do not "optimize" this back to static linking.

The release script publishes the corresponding source itself, keyed by the FFmpeg pin
rather than the app version:

```
graviton/manifold/source/ffmpeg-n8.1.1-239f2c733de4.tar.xz
```

A HEAD against the public URL guards it, so a normal release uploads nothing. Two preflight
assertions block a release if the licence posture breaks: `ffmpegSourceURL` in
`App/AboutWindow.swift` must equal the URL derived from the pin, and `licensingContact`
must be a real address.

**This is the mechanism GradeShare needs and does not have** — its About panel offers five
source tarballs that nothing publishes.

---

## Fragilities

**The five dylib soname majors (62 / 62 / 60 / 9 / 6) are stated in three places** —
`project.yml` dependencies, `EXPECTED_DYLIBS` in `release-mac.sh`, and `major_for()` in
`build_ffmpeg.sh`. Bumping the FFmpeg pin means changing all three or the build breaks in
a confusing way.

**Absolute-path `.a` entries in `OTHER_LDFLAGS`** are wrapped as `'"$(SRCROOT)/…"'` because
the repo path contains spaces. Brittle if quoting behaviour changes.

**Hardcoded paths:** `~/Builds/Manifold`, the three `$HOME` scratch trees, the legacy
`~/manifold-ffmpeg-srt/FFmpeg-n8.1.1` provenance tree, `/Library/NDI SDK for Apple/include`,
`/usr/local/lib/libndi.dylib`, `/Library/Frameworks/DeckLinkAPI.framework`, and
`docs/BlackmagicDeckLinkSDK16.0/Mac/include`.

**`UPLOAD_SCRIPT` is derived as `${REPO_ROOT}/../../Graviton-Releases/upload-release.sh`**,
so it depends on the repo sitting exactly two directories below the sibling. Preflight
fails with a clear message if it does not resolve, and `--no-upload` still works.

**`|| true`-style guarded greps appear throughout** and the reason is documented at length:
`producer | grep -q` SIGPIPEs its producer under `set -o pipefail` and reports a successful
match as a failure. The `contains` / `has_line` / `find_lines` helpers exist for that.

**`create-dmg` non-zero exit is tolerated** only if the image exists and `hdiutil verify`
passes — deliberately not a blanket `|| true`. The cause is Finder AppleScript styling
failing over SSH or with a locked screen.

---

## Known gaps

**Core telemetry ships in Release builds.** `MANIFOLD_TELEMETRY` is defined
unconditionally in `Packages/ManifoldCore/Package.swift`, so Core-layer strings like
`[LIVECLOCK]` and two tuning setters are present in a Release archive. The release
script's telemetry assertion greps for `[SRT-FLOW]`, which is an App-layer string gated on
`DEBUG` — so the check is **true but incomplete**. Hygiene rather than behaviour. Fix is to
move emission to the App layer plus an archive build-phase tripwire.

**The dev-path audit is outstanding.** The `#if DEBUG` blocks listed above are the ones we
know about. "Most are gated" is not an audit, and a public Release build should not ship
until one has been done.

**`project.yml` and `release-mac.sh` disagree about the scheme's archive configuration.**
The script's header comment says the archive action is pinned to `Release`; `project.yml`
sets `archive: config: Profile` and its own comment says so deliberately. `project.yml` is
what takes effect. The script's own `-configuration` override means its behaviour is
unaffected, but the comment is wrong and should be corrected.

**Toolchain versions are recorded nowhere.** Nothing pins Xcode, xcodegen, create-dmg, or
wrangler. The archive logs live outside the checkout in `~/Builds/Manifold/*/logs/`.

**No git tags.** Release state lives in the `CURRENT_PROJECT_VERSION` bump commit and the
R2 archive path. Consistent with the rest of the estate.

**`.gitignore` has duplicated stanzas** — `*.xcodeproj/` at two lines,
`docs/Blackmagic Advanced Video Capture and Playback/` at two, `.DS_Store` at two.
Harmless; looks like merge residue.

**Step numbering in `release-mac.sh` is non-monotonic** — headings run 0–11 then
"13. Publish", with a "12b. Corresponding source" block nested inside the publish branch
and executing before it. There is no step 12. Cosmetic.

**Licensing is wired and active.** Setup, key generation, and the activation and validation
endpoints live in the licensing repo, not here. `ROSTER.md` in Graviton-Releases is the
join point between the two.

**TO CONFIRM — `docs/Iris-Scaffold-Step1.md`.** Present in this repo's `docs/`, but the
name suggests it belongs to Scaffold. Confirm whether it is Manifold's or should move.

---

## Troubleshooting

Signing and notarization problems common to every Graviton product are in
`stacks/swift.md` and `IDENTITY.md`. Manifold-specific:

**Preflight fails: "vendored libs missing"**
→ One of the three `ThirdParty/` trees has not been built. Rebuild with the corresponding
`scripts/build_*.sh` and see that library's `ThirdParty/*/README.md`.

**Preflight fails: "STALE STATIC ARCHIVES in ThirdParty/ffmpeg/lib"**
→ A `.a` has reappeared where shared dylibs belong. This guard exists to stop a silent
regression of the LGPL §6 shared-library migration. Rebuild FFmpeg with
`scripts/build_ffmpeg.sh`; do not delete the guard.

**Preflight fails on the notarization profile**
→ `xcrun notarytool history --keychain-profile graviton-notarytool` to test it directly.
Recreate with `store-credentials` if invalid — see `IDENTITY.md`.

**Preflight fails on DeckLink or NDI headers**
→ DeckLink SDK 16.0 must be copied into `docs/BlackmagicDeckLinkSDK16.0/Mac/include`; the
NDI SDK must be installed at `/Library/NDI SDK for Apple`. Both are gitignored and neither
is vendored.

**A dylib assertion fails after export**
→ Install name, authority, hardened runtime flag, or timestamp is wrong on one of the five
FFmpeg dylibs. Usually means `codeSign: true` was dropped from that dependency in
`project.yml`, or the dylib was rebuilt without `--install-name-dir=@rpath`.

**Manifest verification fails after publishing**
→ The uploader wrote a manifest naming a version, build, or filename that does not match
what was just built. Five attempts three seconds apart with cachebusting are already tried,
so this is not edge propagation. Check what actually landed in
`graviton/manifold/current/`.

**Xcode's Product ▸ Archive gives an unexpected configuration**
→ The GUI uses `project.yml`'s `archive: config:`, currently `Profile`. The release script
overrides it explicitly with `-configuration`, so the two can differ. Always release
through the script.
