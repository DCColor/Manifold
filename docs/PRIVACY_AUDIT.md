# Manifold — data-handling audit (for the privacy policy)

**Audit:** 2026-10-18, read-only, at `106e1d6`. **Stage P1 decided and built:** 2026-10-19. P1 is
uncommitted as of this writing; results are in `docs/BUGS.md`, *PRE-SHIP: privacy hardening*.

This is the input to the privacy policy. **The policy may describe only behaviour that has
shipped.** Each finding below is marked:
- **P1** — changed in stage P1;
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
- audit item 2, stream secrets in `streamBookmarks`;
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

---

## 1. Local storage

**Bundle ID:** `com.graviton.manifold` (`project.yml:331`). The app is **not sandboxed**: the only
entitlement is `com.apple.security.cs.disable-library-validation` (`App/Manifold.entitlements:49`).

### UserDefaults — `~/Library/Preferences/com.graviton.manifold.plist` (unencrypted)

| Key | Holds | Status |
|---|---|---|
| `license.email` | The licensee's full email (`LicenseManager.swift:606`) | **P1**: no longer written; removed once the Keychain record reads back equal |
| `license.machineId` | Random UUID sent to the licence server (`:610`, `:661`) | **P1**: as above |
| `license.activated`, `license.validated`, `license.type` | Licence state flags and type | unchanged |
| `streamBookmarks` | Saved streams: `id`, `name`, `urlString`, `type`, `audioOffsetMs`, `colorOverride` (`StreamBookmark.swift:87-110`). The SRT passphrase goes to the Keychain; **the rest of the URL is plaintext**, and a WHEP/HLS path or SRT `streamid` can be the stream key | **later** (item 2) |
| `recentLUTs` | Up to 10 entries: absolute `.cube` path, plain bookmark, output space (`InterpretationLUT.swift:286`, `:300`) | unchanged |
| `exportFolderBookmark` | Security-scoped bookmark to the chosen export folder (`Preferences.swift:195`, `:204`) | unchanged |
| `displayCalibrations` | Keyed by display vendor-model-**serial**, with the display name (`DisplayCalibrationStore.swift:35`, `:53`) | unchanged (P1 stopped *logging* the serial) |

About 70 other keys hold UI preferences only. AppKit adds `NSWindow Frame …` keys, one per build.

### Keychain — login keychain, generic passwords

- Every item is `kSecAttrAccessibleAfterFirstUnlock` (`KeychainStore.swift:172`) and never
  synchronizable, so nothing goes to iCloud.
- **Service `tools.graviton.manifold.license`:**
  - `storedLicenseKey`: the signed `MNFL-…` key.
  - `activationRecord`: JSON `{activated, validated, email, type, machineId, v}`. **P1:** this is the
    only home of the email and the machine id. Activation reserves the machine id here before
    calling the server; deactivation keeps an unactivated record (machine id, no email) so that
    re-activating reuses the machine slot.
  - `trial.firstLaunch`, `trial.lastSeen`, `trial.voided`: these deliberately outlive the app
    (`LicenseManager.swift:84-85`).
- **Service `tools.graviton.manifold.streams`:** one SRT passphrase per bookmark UUID.

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
| Activate | POST `https://license.graviton.tools/manifold/activate` | `{"key","machineId"}`, 12 s timeout | When a key is entered |
| Validate | POST `…/manifold/validate` | Same | **Every launch** with a verified key (**later**, item 7) |

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

## 8. Licensing compared with the shared client (item 7, later)

| Rule | Shared client | Manifold |
|---|---|---|
| Validation interval | At most every 7 days from the last success | Every launch |
| No offline lockout | Yes | Yes |
| Lock only on `revoked` | Yes | `revoked` or `invalid_key` (`LicenseManager.swift:1018`); revocation is not persisted |
| Offline activation | Pending, retried every launch, locks on `max_machines` | Rejected; no pending state |
| Deactivation local only | Yes | Yes (P1: it keeps the machine id in an unactivated record) |
| Machine id | SHA-256 of the hardware UUID, 32 hex | Random UUID — Keychain-only since P1 |

---

## 9. After uninstall

| Remains | Path |
|---|---|
| Preferences | `~/Library/Preferences/com.graviton.manifold.plist` (`defaults delete com.graviton.manifold`) |
| Caches | `~/Library/Caches/com.graviton.manifold/`, `~/Library/HTTPStorages/com.graviton.manifold/` |
| Window state | `~/Library/Saved Application State/com.graviton.manifold.savedState/` |
| Keychain | Services `tools.graviton.manifold.license` (key, record, **trial clock**) and `tools.graviton.manifold.streams` |
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
> your Mac. Stream passwords and your license are kept in the macOS Keychain [stream keys inside
> saved stream addresses — item 2]. Manifold's own network responses are not cached to disk.
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
