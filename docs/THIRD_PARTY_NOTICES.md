# Third-party notices — status and open obligations

Companion to the About window (`App/AboutWindow.swift`, Manifold ▸ About Manifold). The window
carries the attributions and the reproduced licence texts. This file records where each licence
came from, and the one obligation attribution does **not** discharge.

Licence bodies live in `App/Licenses/` as verbatim copies of upstream files and are bundled as
resources. **Nothing in this repo restates a licence from memory.** If a licence needs updating,
re-copy it from the source tree — do not edit the copy.

---

## Provenance

| Component | Version | Licence | Copied from |
|---|---|---|---|
| FFmpeg (libavformat, libavcodec, libavutil, libswscale, libswresample) | n8.1.1 @ `239f2c733de4` | LGPL-2.1-or-later | `git.ffmpeg.org/ffmpeg.git` at the pinned commit — `LICENSE.md`, `COPYING.LGPLv2.1` |
| libsrt | 1.5.6 | MPL-2.0 | `~/manifold-srt-build/srt/LICENSE` |
| libdatachannel | 0.24.5 | MPL-2.0 | `~/manifold-webrtc-build/libdatachannel/LICENSE` |
| libjuice | 1.7.2 | MPL-2.0 | `…/libdatachannel/deps/libjuice/LICENSE` |
| usrsctp | no version string in tree | BSD-3-Clause | `…/libdatachannel/deps/usrsctp/LICENSE.md` |
| libsrtp2 | 2.8.0 | BSD-3-Clause | `…/libdatachannel/deps/libsrtp/LICENSE` |
| plog | bundled with libdatachannel 0.24.5 | MIT | `…/libdatachannel/deps/plog/LICENSE` |
| Mbed TLS | 3.6.7 | Apache-2.0 (dual, see below) | `~/manifold-webrtc-build/mbedtls/LICENSE` |
| NDI SDK (Vizrt NDI AB) | 6.3.2.0 | proprietary — NDI SDK License Agreement | `/Library/NDI SDK for Apple/licenses/libndi_licenses.txt` |
| Blackmagic DeckLink SDK | 16.0 | per-file notice; SDK under Blackmagic EULA | header of `docs/BlackmagicDeckLinkSDK16.0/Mac/include/DeckLinkAPIDispatch.cpp` |

The three MPL-2.0 files are byte-identical (same SHA-1), so one copy ships as `MPL-2.0.txt` and all
three entries point at it.

`nlohmann/json` is vendored under `libdatachannel/deps/` but is **not** compiled into the shipped
archive (no `nlohmann` symbols in `libdatachannel.a`), so it is not credited.

---

## FFmpeg is LGPL — how §6 is discharged

**Confirmed LGPL, not GPL.** From the configured tree's `config.h`:

```
#define CONFIG_GPL 0
#define CONFIG_NONFREE 0
#define CONFIG_VERSION3 0
```

and the configure line contains no `--enable-gpl`, `--enable-nonfree` or `--enable-version3`.
`scripts/build_ffmpeg.sh` asserts all three on every rebuild, so this cannot drift silently.

LGPL-2.1 §6 permits linking a proprietary application against an LGPL library only on
conditions. There are three, and each is discharged by a different mechanism:

| §6 requirement | How Manifold satisfies it | Where it lives |
|---|---|---|
| **Notice** — state that the Library is used and is covered by this Licence, and supply a copy of the Licence | About panel credits the five libraries, states LGPL-2.1-or-later, and reproduces the full licence text plus FFmpeg's own `LICENSE.md` | `App/AboutWindow.swift`, `App/Licenses/LGPL-2.1.txt` |
| **§6(b) — relinking** | FFmpeg ships as five **shared** dylibs in `Contents/Frameworks`, loaded via `@rpath`, which the user can replace. `disable-library-validation` is what lets a replacement actually load under hardened runtime | `ThirdParty/ffmpeg/README.md`, `App/Manifold.entitlements` |
| **Corresponding source** | The exact source is published as a tarball, *and* a §6(c) written offer is made in the shipped binary | below |

### The corresponding source

Published at a URL keyed by the FFmpeg pin:

```
https://releases.graviton.tools/manifold/source/ffmpeg-n8.1.1-239f2c733de4.tar.xz
```

- **Built from the pinned git checkout**, not from any local working tree — `git archive` at
  `239f2c733de417201d7ad3b3b8b0d9b63285b2b1`, so the tarball is a pure function of the commit we
  publish and anyone can regenerate it.
- **Contains a `BUILD.txt`** at the root carrying the tag, the commit, and the exact configure
  line. "Corresponding source" means the source *as built*: upstream source alone does not tell
  you which decoders were compiled in or that the network layer was disabled.
- **Uploaded once per pin, not per release.** `scripts/release-mac.sh` HEADs the URL; if it is
  already there, nothing is uploaded. Bumping the FFmpeg pin changes the filename, the HEAD
  misses, and exactly one upload happens automatically.
- **Published before the binary**, so no build is ever downloadable whose licence notice points
  at a 404.

### The written offer

Made in the shipped binary, in the About panel's FFmpeg entry:

> For three years from the date this build was published, we will supply the complete
> corresponding source for these libraries to any third party, on request, for no more than the
> cost of physically performing the distribution.

Two facts in that entry cannot be checked by the compiler and are asserted by
`scripts/release-mac.sh` at preflight instead: the contact address must not still be the
placeholder, and the published-source URL must match the pin. Both fail the release loudly.

### The relink instructions, and why they live where they do

**Canonical copy: `App/AboutWindow.swift`, in the FFmpeg entry.** Deliberately not here.

§6(b) is satisfied by shared linking only if a user can actually exercise it, and the user who
needs to is someone holding `Manifold.app` — not someone with a checkout of this repo. A recipe
that lives only in the source tree is, for that person, the same as no recipe. So the commands
ship *inside the binary*, in the one place they can be found without us.

Two secondary pointers, neither of which repeats the commands (a second copy is a copy that
drifts):

- `BUILD.txt` in the source tarball, which says where the full instructions are.
- `ThirdParty/ffmpeg/README.md`, for whoever maintains the build.

The instructions are **tested**, not merely plausible: the replace → ad-hoc sign dylib → re-sign
bundle sequence was run against a signed, exported build, and the relinked app launched. Two
things worth knowing if they are ever revised:

- Replacing a dylib without re-signing leaves `codesign --verify` reporting *"nested code is
  modified or invalid"*. The instructions say so, because a user who runs `codesign --verify`
  and sees that should know it is expected at that point rather than a sign of a broken build.
- Re-signing leaves the app **ad-hoc signed rather than signed by us**. That is correct — it is
  no longer the binary we notarized and should not claim to be — and the instructions say so.

### Is hosting a tarball necessary, or would naming the upstream commit do?

**We host it. Naming an upstream commit alone is not, in my assessment, sufficient** — though
see the confidence split below.

Three reasons:

1. **§6(a) says *accompany*.** The wording is "Accompany the work with the complete corresponding
   machine-readable source code for the Library". A pointer at a third party's server is not
   accompanying the work. Hosting our own copy is what makes 6(a) available to us at all.
2. **§6(c)'s offer has to be one we can actually fulfil, for three years.** If we rely on
   `git.ffmpeg.org` or GitHub remaining up and the tag remaining where it is, our ability to
   honour the offer depends on parties who owe us nothing. Tags can be moved; hosts change.
   Holding the bytes ourselves makes the commitment ours to keep. (During this work
   `git.ffmpeg.org` was in fact unreachable, and the pin had to be resolved from the GitHub
   mirror — a small but concrete illustration.)
3. **Upstream does not record how we built it.** The configure line is part of the corresponding
   source and exists nowhere upstream. `BUILD.txt` carries it.

The cost of hosting is one 11 MB object per FFmpeg bump, so the argument for taking the risk is
weak even where the risk is arguable.

#### Confidence, honestly

**Confident:**

- That shared linking plus a replaceable dylib is the standard, well-understood way to satisfy
  §6(b), and that `disable-library-validation` is required for it to work in practice on a
  hardened-runtime macOS app.
- That the *content* we publish is right: upstream source at an identified commit, plus the
  configure line, plus instructions.
- That hosting our own copy is safer than pointing upstream, and cheap enough that it is not a
  close call.
- That the build is LGPL and not GPL — this is asserted mechanically, not believed.

**Would benefit from a licensing opinion:**

- **When the three-year clock starts and what keeps it running.** "From the date this build was
  published" is our reading. A more conservative reading is three years from the last date we
  distribute *any* copy of that binary. Practically: keep the source objects up permanently —
  they are tiny and never change — which makes the question moot. That is the current intent.
- **The "cost of physically performing the distribution" phrasing**, which LGPL 2.1 wrote with
  physical media in mind. We serve a download at no charge, which is strictly more generous, but
  the offer's wording is inherited from the licence and a lawyer may want it adapted.
- **Whether `scripts/build_ffmpeg.sh` itself must be published** as part of "corresponding
  source". LGPL 2.1 §6(a) says "the complete corresponding machine-readable source code for the
  Library" and, unlike GPLv3, does not define Corresponding Source to include build scripts. We
  publish the configure line, which is the part that determines the output. Including the whole
  script would cost nothing and remove the question — worth doing if an opinion says so.
- **Whether the About panel's notice is sufficiently "prominent"** for §6's notice requirement.
  It is behind Manifold ▸ About Manifold ▸ Licences. That is the conventional place and is where
  every other component's notice lives, but "prominent" is a judgement call.

None of these block shipping in my view; all four are cheap to adjust if an opinion differs.

---

## Not reproduced, deliberately

**NDI SDK License Agreement.** Clause 3(a) designates the SDK and its documentation Confidential
Information; clause 2(d) permits distribution only of files the SDK itself identifies as
distributable. The agreement is therefore linked (<http://ndi.link/ndisdk_license>), not copied.
`licenses/libndi_licenses.txt` *is* identified for distribution — it says so in its own text — so
that ships verbatim.

Requirements the SDK licence does place on us, all met in the About window:

- **3(f) trademarks.** NDI marks may be used only to identify compatibility, must be clearly noted
  as NDI's marks, and must not suggest sponsorship. The window states NDI® is a registered
  trademark of Vizrt NDI AB, that it identifies compatibility only, and that Manifold is not a
  Vizrt product and is not endorsed by them.
- **3(g) / 3(d)(vi) copyright notice.** NDI's copyright must appear alongside ours. The window
  carries "Copyright (C) 2023-2026 Vizrt NDI AB, all rights reserved."
- **libndi_licenses.txt** must accompany distribution of the SDK's binary files. We ship no NDI
  binary — the runtime is loaded dynamically from the user's own installation — but the file
  ships anyway, which is the conservative reading.
- **2(b) currency.** The Bundled Product must be built against the latest SDK available at the
  time. Worth re-checking at release; we are on 6.3.2.0.

**Blackmagic DeckLink SDK EULA.** We redistribute no part of the SDK, so the EULA's
sub-licensing clauses (1.4, 1.5) are not engaged. EULA clause **0.1** explicitly excludes the
files we actually use — `/Mac/Include` — from clauses 1, 4.3, 4.4, 5, 7 and 8, and the licence
for those files is the permission notice in their own headers, which is what the About window
reproduces. That notice's clause (3) requires the notice in all copies **except** where the copy
is "solely in the form of machine-executable object code", which is what we ship — so
reproducing it is good practice rather than a strict obligation. Clause **6.2** permits
"XXX compatible with Blackmagic Design DeckLink" phrasing, which is the only way the mark is used.

**Mbed TLS dual licence.** Apache-2.0 OR GPL-2.0-or-later, user's choice. **We take Apache-2.0.**
The upstream `LICENSE` file contains both texts and is reproduced unedited, so the About window
shows the GPL text too; the note above it states which one we are taking.

---

## Re-checking any of this

Every claim above is checkable against a path in the table. To refresh a licence after a
dependency bump, copy the file again into `App/Licenses/` and update the version in
`Attributions.all`. The About window logs `[ABOUT] ⚠️ licence resource missing from the bundle`
and says so on screen if a file fails to bundle, so a broken copy is visible rather than silent.
