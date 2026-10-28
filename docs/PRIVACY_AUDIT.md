# Manifold — data-handling audit (for the privacy policy)

**Audit:** 2026-10-18, read-only, at `106e1d6`. **Stage P1 decided and built:** 2026-10-19. P1 is
uncommitted as of this writing; results are in `docs/BUGS.md`, *PRE-SHIP: privacy hardening*.
**Stage P2 (stream secrets) built and tested unattended:** 2026-10-23, on `9bedbe6`, committed `3c5526d`. The
real install has NOT been migrated: that is an attended step (`docs/BUGS.md`, same entry, *P2*).

This is the input to the privacy policy. **The policy may describe only behaviour that has
shipped.** Each finding below is marked:
- **P1** — changed in stage P1;
- **P2** — changed in stage P2;
- **later** — a decided later stage;
- **open** — no decision yet;
- no mark — unchanged and fine to describe as is.

Line references are to `106e1d6` unless they name P1 code.

---

## Decisions (Robbie, 2026-10-19)

Stage **P1**:
1. **Licence data.** Stop writing `license.email` and `license.machineId` to UserDefaults; keep
   them only in the Keychain `activationRecord`; the UI reads them from there. On the first launch
   after upgrade, delete the plist values ONLY after the record has been read back and matches. If
   the Keychain read fails, leave the plist values alone and log it. A licensed user must never be
   de-activated by this migration.
2. **Disk cache.** The licence, updater, WHEP and HLS-playlist requests use a URLSession with no URL
   cache. Report separately what AVFoundation's HLS playback caches, without changing AVPlayer. On
   upgrade, delete `~/Library/Caches/com.graviton.manifold/Cache.db`.
3. **Logs.** Redact at the source and keep NSLog (diagnostics and the test harness depend on it):
   the ICE candidate pair's IPs, plain SRT stream ids (fix the bypass), and NDI source addresses.
   NDI source names may stay unless they embed a host or IP; say which.
4. **Diagnostics.** The redactor also strips IPv4/IPv6 addresses, `/Volumes/` and other absolute
   paths, and display serial numbers. Stop printing the serial. File names are redacted by default,
   with an "Include file names" checkbox (off by default).
5. **NDI discovery** starts only when the user opens the NDI source list or connects to an NDI
   source, not from the empty start screen. The list shows "Searching…" until sources appear.

**Later stages, not in P1:**
- audit item 2, stream secrets in `streamBookmarks` — **built as P2, 2026-10-23** (below);
- item 7, the licensing port to the shared client's rules;
- item 8, shipping Release builds rather than Profile.

**Decided after the first P1 results (Robbie, 2026-10-19):**
1. Make the default URL cache memory-only at launch, so AVFoundation's HLS playback writes no
   `Cache.db`.
2. Move NDI under "Connect Stream…" into a submenu; discovery starts when the NDI submenu opens.
3. Turn off `manifold.captureLiveAudioWAV` in the real prefs.
4. Add a CLAUDE.md rule: no keystrokes to quit or control an app.

All four are done; results are in `docs/BUGS.md`.

**How P1 resolved the open points:**
- **NDI source names embed a host.** NDI names a source `MACHINE (Source)`, and MACHINE is the
  sending computer's host name (seen here as `MAC-STUDIO (E8 Bars)`). In logs the host is withheld
  and the stream name kept (`LogRedaction.ndiSourceName`).
- **"Other absolute paths"** means everything outside `/System`, `/Library`, `/usr`, `/bin`, `/sbin`,
  `/dev`, `/Applications` and `/opt`, which hold no user data and name the NDI runtime and DeckLink
  framework a report needs.
- **The disk cache** is removed at every launch, not only the first: it is idempotent, and it also
  catches the empty `Cache.db` AVFoundation creates (below).

**Stage P2 (brief from Robbie, 2026-10-23; built unattended the same night):** every stream secret
moves out of UserDefaults into the Keychain, by P1's pattern (copy, read back and compare, only then
remove; a failure leaves that bookmark's plist entry alone and is logged without the secret;
idempotent, resumable, safe on a machine that never had the secret). One Keychain service, one item
per bookmark keyed by its stable id; deleting a bookmark deletes its item, renaming keeps it.

**How P2 resolved the brief against this document and the code** (the document wins where they differ):
- **This document did not define P2** beyond "audit item 2". The brief's definition was used.
- **The service and item already existed.** Before P2, `tools.graviton.manifold.streams` held one SRT
  passphrase per bookmark UUID. P2 keeps that service and that account and widens the item: it now
  holds the bookmark's whole secret, `{"kind":"manifold.stream-secret","v":1,"url":…,"passphrase":…}`
  (`StreamSecret`, Packages/ManifoldCore/Sources/StreamBookmarkModel/StreamSecrets.swift). A value
  that is not that shape is read as a pre-P2 passphrase.
- **"The Stage D IDs."** Stage D's `storageID` is the colour-override preset id
  (`StreamBookmark.colorOverride`), not a bookmark id. The stable per-bookmark id is
  `StreamBookmark.id` (a UUID), already the Keychain account. That is what P2 uses.
- **What is secret.** The whole URL, not a chosen part: a WHEP or HLS path can be the stream key, an
  SRT `streamid` can be one, a query can carry a token, the user part of a URL a password, and no
  rule can tell which path segment is the key. The plist keeps `address` (`scheme://host[:port]`,
  which the list shows and §2 already logs) and `secretRef` (the account). `urlString` is written
  empty, so an older build cannot dial a migrated entry at all, rather than dialling the bare host,
  which would be a different stream.
- **WHEP/WHIP bearer tokens:** none exist. Manifold sends no Authorization header (§5) and does not
  publish (no WHIP). **NDI:** nothing is saved; NDI sources are not bookmarks.
- **Diagnostics, bookmark export/import, "copy URL"** (each path checked; `docs/BUGS.md`, *P2*):
  the export carries no bookmark field, only the captured log (redacted) and a new count line; there is
  no bookmark export or import, and no pasteboard write anywhere in `App/`.
- **The edit form no longer shows the URL on Edit.** Since the URL is in the Keychain, showing it
  means a Keychain read, and pressing the pencil must not do one (`StreamBookmarksSheet.swift`,
  `passphraseRemovalControl`: a read can raise an authorization prompt). The field starts blank,
  blank keeps the saved URL, and "Show saved URL" reads it on request. Chosen as the conservative
  option overnight; Robbie to confirm.

---

## 1. Local storage

**Bundle ID:** `com.graviton.manifold` (`project.yml:331`). The app is **not sandboxed**: the only
entitlement is `com.apple.security.cs.disable-library-validation` (`App/Manifold.entitlements:49`).

### UserDefaults — `~/Library/Preferences/com.graviton.manifold.plist` (unencrypted)

| Key | Holds | Status |
|---|---|---|
| `license.email` | The licensee's full email (0.8.4 `LicenseManager.swift:783`) | **P1**: no longer written; removed once the Keychain record reads back equal (`LicenseRecordSync.swift`) |
| `license.machineId` | Random UUID sent to the licence server (0.8.4 `:610`, `:660-661`) | **P1**: as above |
| `license.activated`, `license.validated`, `license.type` | Licence state flags and type | **License client port**: no longer written or read; left in place (0.8.4 does not need them) |
| `streamBookmarks` | Saved streams: `id`, `name`, `type`, `audioOffsetMs`, `colorOverride`, and since P2 `address` (`scheme://host[:port]`) and `secretRef` (the Keychain account), with `urlString` empty (`StreamBookmark.swift`). Before P2 `urlString` held the whole URL but the passphrase, and a WHEP/HLS path or SRT `streamid` can be the stream key | **P2**: the URL and passphrase are in the Keychain; existing entries move at launch, each only after its item reads back equal |
| `recentLUTs` | Up to 10 entries: absolute `.cube` path, plain bookmark, output space (`InterpretationLUT.swift:286`, `:300`) | unchanged |
| `exportFolderBookmark` | Security-scoped bookmark to the chosen export folder (`Preferences.swift:195`, `:204`) | unchanged |
| `displayCalibrations` | Keyed by display vendor-model-**serial**, with the display name (`DisplayCalibrationStore.swift:35`, `:53`) | unchanged (P1 stopped *logging* the serial) |

About 70 other keys hold UI preferences only. AppKit adds `NSWindow Frame …` keys, one per build.

### Keychain — login keychain, generic passwords

- Every item is `kSecAttrAccessibleAfterFirstUnlock` (`KeychainStore.swift:172`) and never
  synchronizable, so nothing goes to iCloud.
- **Service `tools.graviton.manifold.license`:**
  - `storedLicenseKey`: the signed `MNFL-…` key.
  - `activationRecord`: JSON. **P1:** the only home of the email and the machine id. **Since the
    license client port** it holds every field the client writes (`licenseActivated`,
    `licenseMachineId`, `licenseMachineIdSource`, `licenseLastValidatedAt`, the pending fields, …)
    beside the five 0.8.4 reads (`activated, validated, email, type, machineId`, and `v`, now 2),
    which mirror them (`LicenseRecordStore.swift`). The machine id is written before every
    activation request and never cleared; deactivation clears the email and type and keeps the id,
    so re-activating reuses the machine slot. A record that cannot be read is never overwritten.
  - `trial.firstLaunch`, `trial.lastSeen`, `trial.voided`: these deliberately outlive the app
    (`LicenseManager.swift:84-85`).
- **Service `tools.graviton.manifold.streams`:** one item per bookmark UUID. **P2:** the item holds
  the bookmark's full URL and SRT passphrase (`StreamSecret`); before P2 it held the passphrase only,
  and only for bookmarks that had one. The list and the migration of an already-migrated list read no
  item; an item is read to connect, to show the saved URL in the edit form, and to save an edit.

### Files and caches

- **The app writes nothing to Application Support, Caches or tmp.** There is no thumbnail or
  waveform cache, and no WebKit.
- **`~/Library/Caches/com.graviton.manifold/Cache.db` (+ `-wal`, `-shm`, `fsCachedData`)** was the
  `URLSession.shared` disk cache.
  - At the audit it held:
    - the licence server's `/activate` and `/validate` replies (the activate reply likely carries
      the email);
    - the update manifest;
    - WHEP request URLs, whose paths are stream keys.
  - **P1:** the app's own requests use `PrivateURLSession` (ephemeral, `urlCache = nil`), and these
    files are removed at every launch.
  - AVFoundation's HLS loader runs in-process and opens the default URL cache. It had created an
    **empty** `Cache.db` (0 responses). **P1 (decided 2026-10-19):** the default cache is memory-only
    from launch. Measured: 40 s of HLS, no `Cache.db`.
- **`~/Library/HTTPStorages/com.graviton.manifold/`** is CFNetwork's cookie, HSTS and Alt-Svc store.
  - After P1 the app's own requests no longer add to it.
  - HLS playback (AVFoundation) wrote one `alt_services` row; there were no cookies.
- **Saved Application State** may be created by macOS (window restoration).
- **Recent documents** are opened files only, kept by macOS in
  `…/com.apple.sharedfilelist/…ApplicationRecentDocuments/com.graviton.manifold.sfl*`
  (`RecentFiles.swift:76`).

### Exports (user-initiated)

| What | Where |
|---|---|
| Frame still PNG (pixels, ICC, optional DPI) | The export folder, else `~/Desktop`, with no panel (`MetalVideoRenderer.swift:4186-4196`) |
| Diagnostics `.txt` | Save panel (`DiagnosticsExport.swift:976-986`) |
| Sync clip `.mov` | Save panel |
| v210/rgba16f dump next to each still; live and NDI WAV captures to `~/Desktop` | **Debug builds only — which every Profile build is** (item 8, later) |

---

## 2. Logging

- **The app uses no `os_log` or `Logger`.**
  - It has about 556 `NSLog` calls (to stderr and the unified log) and about 208 `print` calls
    (stdout only).
  - No log files are written. `LogTap` keeps stdout/stderr in memory only (128 KiB head + 3,968 KiB
    tail) for the diagnostics export.
- **Measured 2026-10-19:** in the unified log every Manifold NSLog line is stored as
  `(Foundation) <private>`, so the message text is not persisted unless private-data logging is
  enabled on the Mac. It still reaches stderr and a diagnostics export.
- **Redacted at the source in P1:**
  - the WHEP selected ICE pair (both addresses);
  - SRT stream ids: a plain id is withheld whole, and of an `#!::` id only `m` and `t` are kept;
  - NDI discovery listing: no addresses, host withheld;
  - NDI connect lines: host withheld;
  - libdatachannel's log callback: IPs.

  All of these go through `PrivacyRedaction.LogRedaction`.
- **P2:** the stream-secrets migration logs counts, and a kept entry by its position in the list
  ("entry 3 of 7: … left in the preferences plist"), never its URL, host or name.
- **Still logged in full (not in P1's list):**
  - the SRT host and port (`SRTClient.swift:490`, `SRTSession.m:580`);
  - the WHEP endpoint host (path withheld);
  - the HLS host;
  - opened file names.

  The diagnostics redactor removes them from an export.

---

## 3. File access

- **Reads:**
  - media is fully decoded for playback (AVFoundation, libav);
  - MXF, timecode and `stsd` are parsed from headers only;
  - embedded creator, author and software metadata is read into memory only.
- **Nothing is ever written to a media file or a sidecar.** FFmpeg is built with no muxers and the
  `file` protocol only.
- **"Edit in Flip"** (`ContentView.swift:3146-3181`) calls
  `NSWorkspace.open([url], withApplicationAt:)` for bundle `tools.graviton.flip`. It passes the file
  URL only, with no URL scheme, Apple Events, pasteboard or network.

---

## 4. Network — Graviton services

| Request | Endpoint | Details | When |
|---|---|---|---|
| Update check | GET `https://releases.graviton.tools/manifold/manifest` | No body | Every launch, and from the menu. No opt-out (`UpdateChecker.swift:17`) |
| Activate | POST `https://license.graviton.tools/manifold/activate` | `{"key","machineId","version","platform":"darwin"}`, 15 s | When a key is entered; **every launch** while an offline activation is pending |
| Validate | POST `…/manifold/validate` | `{"key","version"}`, 8 s | At most every 7 days from the last success; every launch while locked |

- Every request carries the default User-Agent (app, build, CFNetwork and Darwin versions) and the
  user's IP address.
- The updater is custom: no Sparkle, so no system-profile reporting.

---

## 5. Network — live streams

- **No listening sockets.** Every connection is outbound, to an address the user supplies.
- **NDI:**
  - The runtime is the user's own install (dlopen `/usr/local/lib/libndi.dylib`), loaded with the
    v6.3 SDK headers.
  - Receive only: no sender, tally, metadata or advertising.
  - Receiver name NULL, so the runtime names it after the app.
  - **P1:** discovery starts only when an "NDI" submenu opens (in the toolbar menu and in the empty
    state's "Connect Stream…"), or on connect. Measured: no `libndi` mapped and 0 UDP sockets for
    30 s at launch, with or without a file open. Opening "Connect Stream…" alone loads nothing.
    If the submenu cannot be watched (a future macOS), discovery falls back to starting when
    "Connect Stream…" opens, and logs a FALLBACK line (`NDIMenuOpenWatcher`).
  - Opening Settings loads and initialises the runtime (no discovery).
- **SRT:** caller only (`SRTSession.m:702-705`); no listener or rendezvous.
- **WHEP:**
  - libdatachannel 0.24.5 (libjuice, libsrtp2, usrsctp, Mbed TLS 3.6.7).
  - **No STUN/TURN** (`WHEPClient.swift:186`).
  - The endpoint is always supplied by the user.
  - Requests: POST and DELETE, no Authorization header.
  - The offer carries the Mac's local host candidates (LAN IPs) to that server, with no mDNS
    obfuscation (**open**).
- **HLS:** AVFoundation playback plus one playlist GET (P1: `PrivateURLSession`).
- **Info.plist:** `NSLocalNetworkUsageDescription` only. There is no `NSBonjourServices` (**open**).

---

## 6. DeckLink

- Local hardware output only, through the Desktop Video driver's
  `/Library/Frameworks/DeckLinkAPI.framework`.
- No network calls from the app side.

---

## 7. Third-party code

- **Linked or loaded:**
  - FFmpeg n8.1.1 (shared dylibs, `--disable-network`);
  - libsrt 1.5.6;
  - libdatachannel 0.24.5 and its dependencies;
  - Mbed TLS 3.6.7;
  - NDI runtime (user-installed);
  - DeckLink SDK 16.0 dispatch.
- **No remote Swift packages.**
- **None of:** Sentry, Crashlytics, Firebase, MetricKit, TelemetryDeck, Amplitude, Mixpanel,
  PLCrashReporter, Bugsnag, AppCenter, PostHog, Datadog, Sparkle. `MANIFOLD_TELEMETRY` means local
  log lines only.
- **Closed source, not verifiable here:** the NDI runtime and the Desktop Video driver.

---

## 8. Licensing compared with the shared client (item 7)

**Done: Manifold runs a port of the shared client** (`Packages/ManifoldCore/Sources/LicenseClient`,
2026-10-28), so every rule below is the shared client's. Its tests are the port of
Graviton-Releases `tests/license.test.js`. The column on the right is what 0.8.4 did, and what
installed copies do until they update.

| Rule | Shared client (Manifold since the port) | 0.8.4 |
|---|---|---|
| Validation interval | At most every 7 days from the last success | Every launch |
| No offline lockout | Yes | Yes |
| Lock only on `revoked` (and a signed expiry, offline) | Yes; persisted; offline while locked stays locked | `revoked` or `invalid_key`; not persisted (the next launch reset it from the signature); signed expiry never checked |
| Offline activation | Pending, retried every launch, locks on `max_machines` | Rejected; no pending state |
| Deactivation local only | Yes; keeps the machine id | Yes; deleted the record (and, in P1 builds before the D7 fix, could delete it when the id had not been read) |
| Machine id | Existing installs keep their stored UUID; new installs SHA-256 of IOPlatformUUID, 32 hex | Random UUID |
| Request bodies | `version` on both; `platform: darwin` on activate; no machine id on validate | `{key, machineId}` on both |
| Messages | The shared client's, with the worker's real machine counts | Own wording; "maximum of 4" hardcoded |
| Diagnostics | Presence only for key, email and record | Masked email and a key fingerprint |

---

## 9. After uninstall

| Remains | Path |
|---|---|
| Preferences | `~/Library/Preferences/com.graviton.manifold.plist` (`defaults delete com.graviton.manifold`) |
| Caches | `~/Library/Caches/com.graviton.manifold/`, `~/Library/HTTPStorages/com.graviton.manifold/` |
| Window state | `~/Library/Saved Application State/com.graviton.manifold.savedState/` |
| Keychain | Services `tools.graviton.manifold.license` (key, record, **trial clock**) and `tools.graviton.manifold.streams` (since P2, every saved stream's URL and passphrase) |
| Recent files | `…/ApplicationRecentDocuments/com.graviton.manifold.sfl*` |
| The user's exports | Export folder, Desktop, wherever diagnostics were saved |
| Machine registration | On the licence server |

---

## Plain-language summary (true once P1 ships; bracketed parts need the named stage)

> **Manifold does not collect analytics, usage data or crash reports, and contains no third-party
> tracking or advertising code.**
>
> **What Manifold sends to Graviton.** When it starts, and when you choose Check for Updates,
> Manifold downloads a small version file from releases.graviton.tools. When you activate a license,
> Manifold sends your license key and a machine identifier to license.graviton.tools, and checks the
> license with that server [every launch — item 7 changes this to at most weekly]. These requests
> reveal your IP address and app version to Graviton's servers, as any web request does. Your
> license email is stored only in your macOS Keychain.
>
> **Your media.** Manifold opens media files only to play and inspect them. It never modifies,
> uploads or copies them. "Edit in Flip" asks macOS to open the current file in Flip; nothing else
> is sent.
>
> **Live streams.** Manifold connects only to stream addresses you enter, or NDI sources on your
> local network. It never accepts incoming connections, and it does not announce itself as a source.
> It looks for NDI sources only when you open the NDI source list or connect to one. For WebRTC
> (WHEP) streams it uses no third-party STUN or TURN server. The server you connect to sees your IP
> address and, for WHEP, your Mac's local network addresses. The NDI runtime and Blackmagic's driver
> are third-party software with their own terms.
>
> **What stays on your Mac.** Settings, saved streams, recent files and recent LUTs are stored on
> your Mac. Saved stream addresses, stream keys and stream passwords, and your license, are kept in
> the macOS Keychain; Manifold's preferences file keeps only each saved stream's name and server name
> [true once P2 ships]. Manifold's own network responses are not cached to disk.
> Diagnostics reports are created only when you choose Export Diagnostics, saved where you choose,
> and never sent automatically. Network addresses, folder paths, machine names and display serial
> numbers are removed, and file names unless you include them. Your trial start date is kept in the
> Keychain and remains after you delete the app.
>
> **Removing your data.** Delete the app. Then remove
> `~/Library/Preferences/com.graviton.manifold.plist`, `~/Library/Caches/com.graviton.manifold`,
> `~/Library/HTTPStorages/com.graviton.manifold`, and the Keychain items named
> `tools.graviton.manifold`. To free a license seat, contact support.

## Open questions

1. CFNetwork still records an HTTP/3 Alt-Svc host in `~/Library/HTTPStorages/com.graviton.manifold`
   during HLS playback (one row, no cookies). Accept it, or clear the folder at launch?
2. Which build ships publicly (item 8). Profile builds carry the debug-only file writes above.
3. What the NDI runtime itself sends (Vizrt's documentation).
4. `NSBonjourServices` (e.g. `_ndi._tcp`) for NDI discovery on macOS 15+.
5. The hardware-UUID machine id (item 7) will differ from every existing id: does the server need a
   migration path?
6. The shared client's trial rules.
7. What the licence server logs, and for how long.
