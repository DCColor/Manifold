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
| FFmpeg (libavformat, libavcodec, libavutil, libswscale, libswresample) | n8.1.1 | LGPL-2.1-or-later | `~/manifold-ffmpeg-srt/FFmpeg-n8.1.1/LICENSE.md`, `COPYING.LGPLv2.1` |
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

## ⚠️ OPEN: FFmpeg is LGPL and statically linked

**Confirmed LGPL, not GPL.** From `~/manifold-ffmpeg-srt/FFmpeg-n8.1.1/config.h`:

```
#define CONFIG_GPL 0
#define CONFIG_NONFREE 0
#define CONFIG_VERSION3 0
```

and the recorded configure line contains no `--enable-gpl`, `--enable-nonfree` or
`--enable-version3`. So FFmpeg's default LGPL-2.1-or-later applies to this build, and no GPL
component was enabled.

**But the linkage is static** (`--enable-static --disable-shared`, and `OTHER_LDFLAGS` names
`.a` archives). LGPL-2.1 §6 permits linking a proprietary application against an LGPL library
only if the user can **relink** the application against a modified version of that library.
Attribution and reproducing the licence — which the About window does — satisfy §6(d) and the
notice requirements. They do **not** satisfy the relinking requirement.

The usual ways to satisfy it, for a decision before release:

1. **Ship dynamically.** Rebuild FFmpeg as dylibs, embed them in the bundle, link against them.
   The user can then swap the dylib. Cleanest legally; costs bundle size, a code-signing and
   `@rpath` story, and notarization of the embedded dylibs.
2. **Ship relinkable object code.** Publish the app's own object files / static archives plus
   linker instructions, so a user can relink against their own FFmpeg build. Legally sufficient,
   operationally unpleasant, and exposes build internals.
3. **Drop FFmpeg** from the shipped configuration.

Also required either way, and cheap: offer the **complete corresponding source of FFmpeg as
built**, including the exact configure line, and state where to get it. The configure line is
recorded above and in `config.h`'s `FFMPEG_CONFIGURATION`.

This is unresolved. Do not ship without picking one.

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
