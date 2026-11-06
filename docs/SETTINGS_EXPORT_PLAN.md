# Export/Import Settings (shortcuts + streams) — PLAN

Status: revised 2026-11-03 after Robbie's decisions. **A1 and A2 (shortcuts end to end) are built and passed their attended
check. A3 and A4 (the encrypted file and streams) are built and passed the attended sandbox pass, on fake URLs, and the Studio-to-Air
round trip with a real stream, 2026-11-05 (§8). The stream design (§2.4–§4.2) is settled, R1–R6 below.** First version at `884cce3`, and line
references are to that commit unless they name new code. **By reading** means established from the code and not run.
**Measured** means run on this Mac (M4 Max, macOS 26.7.1). **UNKNOWN** means not established. Companion:
`docs/STILLS_AND_AUDIO_ONLY_PLAN.md`.

## 0. Decisions (Robbie, 2026-11-03)

1. **Streams are exported complete,** URLs and SRT passphrases included, protected by a password chosen at export and
   entered at import. This replaces "secrets never exported".
2. **Any file with streams is encrypted.** There is never a plaintext file with stream URLs or passphrases. A
   shortcuts-only file stays plain JSON with no password.
3. **Apple crypto only:** CryptoKit AES-GCM-256, key from CommonCrypto PBKDF2-HMAC-SHA256, random 16-byte salt, iteration
   count in the header. A plaintext header and one encrypted payload. Stream names and hosts are inside the encrypted part.
4. **Password:** entered twice at export, minimum length stated, plain warning that it cannot be recovered. Import: one
   prompt. A wrong password or a modified file gives the same message, "Wrong password, or the file has been changed",
   and writes nothing.
5. **Export reads the Keychain** (reverses the earlier D2). §3.2 says what happens per stream.
6. **Stream import is add-only.** It never modifies or deletes an existing stream or its Keychain item, and asks no
   per-stream questions. Same name and same URL: skipped (but see R2). Same name, different URL: added as " (copy)", " (copy 2)"…
   The preview lists added, renamed and already here. Imported streams are saved as a new stream is, and connect without
   asking for anything. Undo Import removes only what the import added. **Replace for streams is removed.**
7. **The automatic backup covers shortcuts only** and never holds a secret.
8. **Shortcuts keep** Replace all / Merge, set-level validation and the backup.
9. Earlier decisions: D3 accepted (now inside the encrypted part); D5 scope, D6 no File menu items, D7 double-click opens
   the preview, D8 backup location and count, D9 roadmap updated, all as recommended. D1 and D4 no longer apply.

**What this removes from the first version:** per-stream secret prompts, `secretPending`, the "Enter Stream URLs…" window, the
first-connect prompt, conflict rows, and `id` in the file. Decision 6 is a much smaller design.

### Stream design points settled (Robbie, 2026-11-03)

- **R1. Re-importing a file (§4.2).** The URL is compared against the whole family ("A", "A (copy)", "A (copy 2)"…), so a repeat
  import reports "already here".
- **R2. Same name and URL, different passphrase (§4.2).** Changed from the first rule: the entry is **added** as " (copy)", and the
  preview says "passphrase differs". The file's passphrase is never silently dropped.
- **R3. An existing stream whose URL cannot be read during the comparison (§4.2).** Treated as different. The worst case is a
  duplicate "(copy)" the user can delete, and the preview says the comparison could not be made.
- **R4. Iterations and password length (§2.5).** 1,000,000 iterations, 12 characters. The count is frozen (Robbie, 2026-11-03; reasoning in §2.5).
- **R5. Undo Import (§4.4).** Lasts while the summary is open. After that, stream removal is by hand and shortcuts use Restore from
  Backup…
- **R6. Damaged JSON (§2.5).** A file that cannot be read as a header is refused before any prompt with "This file is damaged, or it
  isn't a Manifold settings file." Everything after the prompt gets the one message.

---

## 1. Inventory

### 1.1 Shortcuts

| Part | Where | Format | Secret |
|---|---|---|---|
| Overrides | One defaults key, `manifold.shortcuts` (`ShortcutStore.swift:21`) | A JSON **string**, sorted keys: `{"overrides":{…},"version":1}` (`:4-7`, `:85-87`) | No |
| One binding | Inside `overrides` | `{"key":"i","modifiers":[…]}`, or `{"code":30,"modifiers":[…]}` for a physical key, or `null` for "no key" (`:7`, `:91-105`) | No |
| Defaults | `ShortcutCatalog`, in code | Not stored, and only differences from them are | No |

**Action ids are stable strings** such as `view.inspector` (`ShortcutCatalog.swift:10-93`). Rules that affect import:

- Only rebindable rows take an override: not `.fixed`, not debug rows, not `file.open`
  (`ShortcutCatalog.swift:175`, `ShortcutRegistry.swift:49-50`). Stored keys for other rows are ignored and kept.
- Ids this build does not know stay in defaults untouched (`ShortcutStore.swift:13`, `:44-45`).
- A stored value that does not parse is never overwritten (`ShortcutStore.swift:15`, `:61-65`).
- `.character` matches what the layout types and `.code` the physical key (`KeyChord.swift:6-8`). Conflicts compare a
  code as the character it types on **this** layout (`ShortcutRegistry.swift:257-261`), so a file can be valid on one
  Mac and conflict on another.
- Debug actions count as conflicts only when their tier is on (`ShortcutRegistry.swift:153-159`), so the answer can
  differ between a Profile and a Release build.

### 1.2 Saved streams

`StreamBookmark` has exactly eight stored fields (`StreamBookmark.swift:88-120`). The list is one defaults key,
`streamBookmarks` (`Preferences.swift:345`). `StreamSecret` is one Keychain item per bookmark in service
`tools.graviton.manifold.streams` (`KeychainStore.swift:183`, `StreamSecrets.swift:28-32`).

| Field | Lives in | Secret? | In a file with streams |
|---|---|---|---|
| `id` (UUID) | plist | No. It is also the Keychain account name | No. Import mints a new one |
| `name` | plist | Not by definition, but it is user text. Blank falls back to the host (`Preferences.swift:603`) | Encrypted |
| `type` (`web`/`srt`/`hls`) | plist | No | Encrypted |
| `address` (`scheme://host[:port]`) | plist | No per P2 (`PRIVACY_AUDIT.md:82-83`) | Not stored: it is derived from the URL. The host is encrypted as part of it |
| `audioOffsetMs` | plist, absent when 0 | No | Encrypted, when set |
| `colorOverride` (raw string) | plist, absent for Auto | No | Encrypted, when set, verbatim |
| `urlString` | plist | **SECRET.** Empty after P2; on a pre-P2 entry it is the whole URL without the passphrase | Never as a field. Read through `resolve`, as the URL below |
| `secretRef` | plist | No, it equals `id` | No |
| Full URL | Keychain item | **SECRET**: path, query, `streamid`, user and password part | **Encrypted** |
| SRT passphrase | Keychain item | **SECRET** | **Encrypted** |

A shortcuts-only file holds none of these.

**WHEP/WHIP bearer tokens:** none exist, as Manifold sends no Authorization header (`PRIVACY_AUDIT.md:86`). **NDI:**
nothing is saved, because NDI sources are not bookmarks (`:87`, `LiveColorOverride.swift:24`).

**Other per-stream settings:** none found. The only store writers beyond add, edit and delete are `setAudioOffset`
(`Preferences.swift:821`) and `setColorOverride` (`:836`), and the only outside users of a bookmark id are those two
models (`LiveAudioOffset.swift:139-148`, `LiveColorOverride.swift:181-183`).

### 1.3 Other settings that could travel

| Group | Keys (where) | Recommendation for 0.9.2 | Reason |
|---|---|---|---|
| Highlight color | `manifold.highlightColor` (`PlayheadSlider.swift:68`) | **Out, next** | One key, but it invites "why not the rest?" |
| Look of scopes, guides, safe zones | `Preferences.swift:91-118`, `:136-141`, `:166-182`; per-scope keys (`WaveformScope.swift:778-781`, `ParadeScope.swift:215-218`, `VectorscopeScope.swift:377-404`, `CIEScope.swift:330-333`, `AudioMeterScope.swift:496-497`) | **Out, next** | About 50 keys, each needing a range check. Valuable as one reviewed "Preferences" section later |
| Windows, Files, Playback tabs | `controlDisplayMode`, `manifold.raster.size`, `manifold.open.destination`, `autoplayOnLoad`, `manifold.playhead.style` (`SettingsView.swift:289`, `:303`, `:355`, `:438`, `:442`) | **Out, next** | Harmless, but not what moving workstations needs first |
| DeckLink behavior | `manifold.decklink.outputModeSet`, `.sdiScaling` (`SDIOutputMode.swift:38`, `:52`) | **Out** | Describes the room and its monitors |
| DeckLink per machine | `.enableOnLaunch`, `.audioTrimSeconds`, `.manualOutputMode` (`DeckLinkService.swift:70`, `:525`, `:610`), `.audioDestination` (`SDIOutputMode.swift`, `DeckLinkAudioDestination.defaultsKey`) | **Never** | Tied to one card and signal path. Starting a broadcast output because of an imported file is the wrong surprise |
| Per-display calibration | `displayCalibrations` (`DisplayCalibrationStore.swift:35`) | **Out** | See below |
| Machine-bound paths | `exportFolderBookmark` (`Preferences.swift:196`), `recentLUTs` (`RecentLUTs.swift:31`) | **Never** | Bookmarks to this Mac's paths |
| Licence | Keychain and `license.*` keys | **Never** | Brief, and `PRIVACY_AUDIT.md:23-27` |
| Debug and session state | `manifold.debugMenu`, `manifold.captureLiveAudioWAV`, `playbackVolume`, window frames | **Never** | Not settings a person chose to carry |

**Per-display calibration on another Mac.** The key is vendor-model-serial, and the entry says what one physical display
does in one room (`DisplayCalibrationStore.swift:4-6`, `:50-54`). It stays out of 0.9.2. If it ever travels:

- exact key match: apply only with a tick in the preview, off by default;
- same vendor and model, other serial: list it, never apply it, because it is a different panel;
- no match: ignore it and say so.

The raw serial must not be in the file, since P1 stopped logging it and diagnostics strip it
(`DisplayCalibrationStore.swift:56-59`, `PRIVACY_AUDIT.md:34-36`). A later design has to hash it.

---

## 2. File format

### 2.1 Name and type

- Extension: **`.manifoldsettings`**, for both kinds of file. Suggested name: `Manifold Settings 2026-11-03.manifoldsettings`.
- UTI (stage A5): **`com.graviton.manifold.settings`**, conforming to `public.json` and `public.data`, declared in
  `UTExportedTypeDeclarations` beside `CFBundleDocumentTypes` (`project.yml:336`), with a document entry at rank `Owner`. The
  `Alternate` rule (`project.yml:376-380`) concerns other people's media types. **Built in A5**, role Editor. The panels still ask for the
  type by its extension, which now resolves to this identifier, and still works on a build Launch Services doesn't know.

### 2.2 A shortcuts-only file (built)

Plain JSON, no password. Any text editor opens it.

```json
{
  "appBuild": "24",
  "appVersion": "0.9.2",
  "exportedAt": "2026-11-03T18:30:00Z",
  "formatVersion": 1,
  "kind": "com.graviton.manifold.settings",
  "sections": {
    "shortcuts": {
      "overrides": {
        "view.fileName": null,
        "view.inspector": { "key": "i", "modifiers": ["command", "option"] }
      },
      "version": 1
    }
  }
}
```

`overrides` is the stored document's object verbatim, so it is lossless and keeps ids this build does not know. No machine
name, user name, email, path or display identity is written.

### 2.3 Where the code is

`SettingsTransfer` (Foundation, CryptoKit, CommonCrypto, Security, and `StreamBookmarkModel` for the secret types) holds the file,
its reader and refusals, the backups, the encryption (`SettingsEncryption.swift`) and the stream rules (`StreamTransfer.swift`). The
set-level judge is `ShortcutImport.swift` in `ShortcutRegistry`, because it needs that target's rules.
`App/SettingsTransferUI.swift` presents plans and applies them. Nothing in the package touches defaults, and it reaches the Keychain
only through a `StreamSecretStore` the app passes in.

**Two readers:** `SettingsFile.inspect` takes either kind of file, for a file the user chose. `SettingsFile.read` takes plain files
only, which is what a backup is, and refuses an encrypted file by name. `parseSections` is one parser for a `sections` object. It
reads `streams` from a decrypted payload only: a plain file's `streams` section is listed as "Not encrypted, so not imported".

### 2.4 A file with streams (built)

```json
{
  "appBuild": "24",
  "appVersion": "0.9.2",
  "encryption": {
    "cipher": "AES-GCM-256",
    "iterations": 1000000,
    "kdf": "PBKDF2-HMAC-SHA256",
    "nonce": "<base64, 12 bytes>",
    "salt": "<base64, 16 bytes>"
  },
  "exportedAt": "2026-11-03T18:30:00Z",
  "formatVersion": 1,
  "kind": "com.graviton.manifold.settings",
  "payload": "<base64: ciphertext then 16-byte tag>",
  "sections": {
    "shortcuts": { "count": 3, "version": 1 },
    "streams": { "count": 12, "version": 1 }
  }
}
```

The payload decrypts to `{"sections":{"shortcuts":{…},"streams":{"entries":[…],"version":1}}}`. All sections selected at export
go inside it, shortcuts included, so there is one payload. Each stream entry:

```json
{ "audioOffsetMs": 80, "colorOverride": "rec709", "name": "Studio A",
  "passphrase": "…", "type": "srt", "url": "srt://encoder.example.net:9000?streamid=…" }
```

`StreamExportEntry` is its own `Codable` struct with exactly these six fields. `StreamBookmark` is never encoded. `url` is
`StreamSecret.url`, without the passphrase, which has its own field. No `id`: import mints a new one, as `add` does.

### 2.5 Crypto

| Item | Value | Note |
|---|---|---|
| Cipher | AES-GCM-256, CryptoKit `AES.GCM` | Measured: 12-byte nonce, 16-byte tag |
| KDF | `CCKeyDerivationPBKDF`, `kCCPRFHmacAlgSHA256`, 32-byte key | CommonCrypto |
| Salt, nonce | 16 and 12 random bytes, fresh for every export | `SecRandomCopyBytes` |
| Iterations | **1,000,000 (R4), frozen** | OWASP's current figure for PBKDF2-HMAC-SHA256 is 600,000. The cost is once per export or import, so going above it is cheap, and the file may sit somewhere for years |
| Accepted on import | 600,000 to 10,000,000 | Outside this, the one failure message, with no KDF run. The ceiling stops a tampered header from hanging the app |
| Password | **At least 12 characters (R4)**, no composition rules, Unicode NFC before UTF-8 | NFC so the same password typed on two Macs gives the same bytes |
| Authenticated data | The header: every top-level field except `payload`, as sorted-keys JSON, pinned by a frozen test vector | Changing any header field fails the open, including the salt, count or iterations |

**Measured time, one derivation, median of five:**

| Iterations | This Mac (M4 Max) |
|---|---|
| 600,000 | 82 ms |
| 1,000,000 | 134 ms |
| 2,000,000 | 272 ms |

The KDF is single-threaded, and it stays off the main thread regardless.

**Frozen at 1,000,000 (Robbie, 2026-11-03). The Air measurement is not needed.** The Air is an M4, with the same cores as the Studio, so
a single-threaded derivation should take about the 134 ms measured here. The slowest supported Mac, an M1, works out to roughly 220 ms.
That is an estimate, not a measurement, and it is paid once per export or import. The count is stated in the header, so raising it later
needs no format change.

**Failure:** `AES.GCM.open` cannot tell a wrong password from a changed file, which is why the message is one message. Nothing is
written, and nothing distinguishes the cases in the log (R6 for what happens before the prompt).

**The password** is never stored, logged or put in the Keychain. Swift strings cannot be reliably wiped, so the password and
decrypted URLs live in ordinary memory until released. That is the same exposure a connect has.

### 2.6 Compatibility

| Case | Rule |
|---|---|
| Unknown key anywhere | Ignored, never an error |
| Unknown section | Listed as "From a newer Manifold, not imported". The rest imports |
| `formatVersion` higher than this build knows | The whole file is refused before any preview or password |
| Section `version` higher than known | That section is refused and the others import |
| Unknown shortcut id | Skipped and listed |
| Unknown `colorOverride` | Kept verbatim, reads as Auto here (`StreamBookmark.swift:107-109`) |
| Unknown stream `type` | The entry is judged from its `url`, because `add` re-detects the type. `type` is display only in the preview |
| Older file, newer Manifold | Every shipped version stays readable, with a frozen fixture per version in the tests |
| Manifold before 0.9.2 | The type is not claimed. A drop is declined by `acceptsForLoad` (`ContentView.swift:1168-1171`). Nothing is read |

`formatVersion` goes up only when an older reader would misread a file. New optional fields and sections do not raise it.

---

## 3. Secrets

### 3.1 Export (stage A4)

The export sheet gains "Saved streams (N)". Ticking it requires a password: two fields, a stated minimum, and this warning, always
visible: **"This password can't be recovered. Without it, nobody can open this file, including Graviton."** The file's contents are
named: "Stream names, addresses, URLs and passphrases are in this file, encrypted with your password."

### 3.2 Reading the Keychain, per stream

After the password is confirmed, one pass in list order, off the main thread, through `StreamSecrets.resolve` (the same read
as a connect, `Preferences.swift:906-922`), with "Reading stream 3 of 12…" shown.

| Read | What happens |
|---|---|
| Found | Included. A pre-P2 entry resolves from its `urlString` and is included in the encrypted payload only |
| Prompt raised, Allow | Included. A build whose signature does not match the item's ACL raises a macOS prompt, potentially once per stream. Unsigned builds do this (memory: unsigned-build Keychain prompts). A signed build reading its own items should not, which A6 confirms |
| Prompt raised, Deny or Cancel | That stream is **left out**. The pass continues, so one refusal does not end the export |
| Keychain locked or read fails (`.failed`) | Left out, as above |
| No item, or unusable (`.missing`, `.unusable`) | Left out: there is no URL to export |

A stream is in the file complete or not at all, never name-only. If any were left out, a sheet lists them by name with the reason
("Couldn't read this stream's URL") and offers **Try Again**, **Export Without Them** and **Cancel**. No file exists until the
user chooses. Header counts state what is actually in the file. The log carries counts and positions only.

### 3.3 Import

One password prompt, then decrypt, validate and preview. Imported streams are saved through `StreamBookmarkStore.add`, the
path every new stream takes: Keychain write, read back, then the list (`Preferences.swift:590-642`). `add` gains an optional
`colorOverride` parameter, and nothing else about it changes. So they connect without asking for anything, and no new field is
needed on `StreamBookmark`.

---

## 4. Import UX

### 4.1 Flow

Choose a file, or double-click one (A5) → read the header → password, if encrypted → validate → **preview** → Import → backup of
shortcuts, read back, if shortcuts are included → apply → summary with Undo Import.

Refused before the preview: unreadable JSON, wrong `kind`, over 1 MB, higher `formatVersion`. Refused per section with the reason
shown: streams while `storedDataUnreadable` is true (`Preferences.swift:400`), shortcuts while the stored value cannot be read
(`ShortcutStore.swift:61-65`). The preview has a checkbox per section and writes nothing.

### 4.2 Streams: add-only (built)

No per-stream questions. For each entry, in file order:

| Existing streams | Outcome | Preview says |
|---|---|---|
| No stream of this name | Added under its own name | Added |
| Same name, different URL | Added as "Name (copy)", then "Name (copy 2)"… using the first free name | Renamed |
| Same name, same URL, same passphrase | Skipped | Already here |
| Same name, same URL, different passphrase (R2) | Added as "Name (copy)"… | Renamed: passphrase differs |
| Entry invalid | Skipped with its reason | Not imported |

- **"Same URL"** compares `StreamSecret.url` exactly, and the passphrase beside it, reading the existing item. Only streams of the
  same name are read, so a fresh Mac raises no Keychain read, and reads happen before the preview.
- **R1:** "same name" for this comparison means the family: the entry's name and its " (copy)" and " (copy N)" forms. Otherwise a
  second import of one file never stops adding.
- **R2:** a different passphrase alone is a different entry, so a file's passphrase is never dropped. The existing stream and its
  item are untouched, as always. A family member matching on URL and passphrase still makes the entry "already here".
- **R3:** a refused read counts as different, and the row says "Couldn't compare with the existing stream".
- Two entries inside one file follow the same rules against the list as it will be.

Validation per entry, each failure costing that entry only: `url` passes `validate` (`Preferences.swift:570`); a passphrase is
10–79 characters and on an SRT URL (`:615`); `audioOffsetMs` is in range (`:824`); `name` is trimmed, has no control
characters, is at most 200 characters, and if blank falls back to the host as `add` does; `colorOverride` is a string of at most 64
characters. Anything unknown in an entry is ignored and never stored.

Applying: `add` per entry. A failed Keychain write costs that entry and is listed in the summary. Nothing else changes, because
nothing existing is touched. A stream connected at the time keeps running. The whole section is refused while
`storedDataUnreadable` is true, as `add` already refuses (`:598`).

### 4.3 Shortcuts (built)

**Merge** (default): this Mac's overrides with the file's on top. **Replace All:** defaults plus the file. Either way
`ShortcutRegistry.importPlan` builds the **resulting** set first, then judges each file binding against it with the checks
that now live in `unusableReason` and `conflicts`, which `propose` also calls. `ShortcutRegistryTests` is unchanged and passes.
Judging uses this Mac's layout and this build's debug tiers.

| File binding | Result |
|---|---|
| Valid | Listed under "Will change", old and new keys |
| Valid with warnings | As above, with the warning (the Fn warning matters on the Air) |
| Reserved or unusable | **Never imported.** Listed with its reason |
| Clash with a fixed row, a debug row in force, or an alias | Never imported, listed |
| Same key as another binding in the file | Both never imported, listed |
| Clash with a binding not in the file | Default keeps this Mac's key. "Use the file's key" unbinds the other action, as Replace does in the Shortcuts window |
| Malformed | Listed. Stricter than `ShortcutStore.decode`: rejects a Boolean `code`, and a control or whitespace `key` |
| Unknown id, or a row that cannot be rebound | Skipped and listed |

Keeping a key can put an action back where a second file binding wanted to go, so judging repeats until nothing changes. One
`store.apply` writes the result, which reads first and keeps entries this build cannot read. A plan made before the bindings moved
is refused (`plan.revision`).

### 4.4 Undo

**Shortcuts (built):** before writing, the current overrides are exported to
`~/Library/Application Support/com.graviton.manifold/Settings Backups/` and read back. If that fails, nothing is imported.
The last 10 are kept. "Undo Import" in the summary restores the backup. **Restore from Backup…** under Export and Import opens one
through the same preview, with no Merge, and it takes its own backup first.

**Streams (built):** the import keeps the ids it added. Undo Import deletes those through `delete`, entry and Keychain item, and
touches nothing else. A stream the import did not add cannot be affected. Lasts while the summary is open (R5). Since 0.9.2 it asks first
when it would delete a stream, in its own words because the file can bring them back, and Cancel leaves the whole import in place
(`docs/BUGS.md`).

### 4.5 What import never touches

The licence, and any existing stream or its Keychain item. Import writes only through `ShortcutRegistry.applyImport` and, later,
`StreamBookmarkStore.add`. `KeychainStore.license` is not reachable from the new target. A6 checks licence-related keys around an
import by presence only.

---

## 5. Where it lives (built)

**Settings ▸ General**, section "Export and Import", after Keyboard (`SettingsView.swift`):

- `Export Settings…`: a sheet with "Keyboard shortcuts (N customized)", then a save panel. Empty sections are disabled. A4 adds the
  streams row and password.
- `Import Settings…`: an open panel, then §4.
- `Restore from Backup…`: shown once a backup exists.

No File menu items (D6). **Built in A5:** a double-click or Open With (D7) is caught at the top of `.onOpenURL`, before media routing and
before anything retires a stream, and a drop at the top of the picture's `.dropDestination`. Both only ever open the preview, through
`SettingsTransferModel.previewFile`.
- Each window has its own model and `SettingsImportHost`, the same sheet and refusal Settings uses.
- SwiftUI makes a new window for an opened file. `DeckRegistry.previewSettingsFile` shows the preview on another window if one is free,
  even one that is playing, and closes the new one.
- One import at a time, across every window: a second file is declined with a beep, and the window showing the import comes forward.
- Nothing opens while the licence gate is up, because the sheet would sit on top of it.

---

## 6. Saved A/V offsets

They travel unchanged. Offsets are mostly sender-side, and the range and start-refusal logic already protects the session
(`LiveAudioOffset.swift:126-137`). What differs between Macs is the monitoring path.

**Suggest a re-check once, in the summary only**, when at least one added stream has a non-zero offset: "N streams kept their saved
A/V offsets. If this Mac monitors differently, check sync with A/V ▸ Calibrate…" (`CalibrationMode.swift:4`). No prompt on connect.
HLS entries keep their value and it stays ignored there (`LiveAudioOffset.swift:60-65`).

---

## 7. Privacy

`docs/PRIVACY_AUDIT.md` records these decisions now, marked **later**, and the shortcuts file and backups as built. It is updated
for streams when they ship, because the policy may describe only shipped behavior (`:8-9`).

Rules for streams:

- **Secrets leave the Keychain only inside an encrypted file,** and only when the user exports with a password they chose.
- **The file is only as strong as its password.** It can be attacked offline, without limit, wherever it ends up. That is the reason
  for the minimum length, the iteration count and the warning.
- **Readable without the password:** app version, export date, section names, counts, KDF parameters, salt. No name, host or URL.
- **Manifold never sends the file anywhere,** and never stores the password.
- **The automatic backup never holds a secret,** so nothing with stream data is written without the user choosing a place for it.
- **Diagnostics never include an export or a backup.** Nothing in `DiagnosticsExport` opens the backup folder. A test asserts it.
- **Logs:** `[SETTINGS]` lines carry counts and positions only: no name, host, URL, path or password.
- **Decrypted values** exist in memory only between the open and the Keychain write.

The shipped plain-language summary (`PRIVACY_AUDIT.md:341-345`) gains, when streams ship: "If you export saved streams, their
addresses and passwords are written to a file encrypted with a password you choose. Anyone with that file and that password can read
them. Manifold can't recover the password."

---

## 8. Test plan

Rules for every launch: tell Robbie first, `manifold-proc.sh guard && <launch>`, run the binary directly, quit by PID. Real URLs only
in the sandbox: `MANIFOLD_DEBUG_STREAMS_SANDBOX` redirects defaults and Keychain (`Preferences.swift:347-363`). Shortcut tests
stash `manifold.shortcuts` first and restore it after, read before write, chained with `&&` (CLAUDE.md).

**Built and passing (`swift test`):**

| Area | Check |
|---|---|
| Round trip | Export then read gives equal sections, stable bytes, and the same binding for every action on a second store |
| Fixed fields | Golden test on the exact top-level and section keys |
| Unreadable and tampered | Truncated, not JSON, empty, a JSON array, over 1 MB, 100,000-deep nesting, wrong `kind`, `formatVersion` as string, Boolean, 1.5 or 0, wrong `sections` type |
| Schema | Newer `formatVersion` refused with the file's version. Newer or damaged section costs that section. Unknown keys ignored, unknown sections listed. Frozen v1 file reads. An encrypted file is refused by name |
| Shortcuts | A swap passes. Merge and Replace All give the expected set. Reserved, ⇧+arrow on menu, ⌘ on hold, fixed clash and two-on-one-key refused. Conflict keeps this Mac's key, or unbinds when chosen. Cascade after giving up a binding. Nine malformed shapes reported. Non-rebindable and unknown skipped. Debug tier changes the verdict. Default-equal stores nothing. Stale plan refused |
| Store | Nothing written over an unreadable stored value. Entries this build cannot read survive Replace All |
| Backup | Read back, newest first, two in one second, keeps 10 and touches nothing else, failed folder stops it, restore gives the exact prior state |

**Unit, stream stages (A3, A4), built and passing.** The frozen vector was made by Python's `hashlib` and `cryptography`, so the
KDF, the authenticated header and the payload are checked against a second implementation. `DiagnosticsBoundaryTests` (A5) holds the
§7 rule. The report is app code a test can't link, so it reads the source: `DiagnosticsExport.swift` names no settings file or backup,
lists no directory and reads no file, and only `SettingsTransferUI.swift` reaches `SettingsBackups`.

| Area | Check |
|---|---|
| Round trip | Encrypt then decrypt gives equal sections. Fresh salt and nonce each export. Frozen test vector for the KDF, the authenticated header and the payload |
| Wrong password | The one message, nothing written, same result as tampering |
| Tampered ciphertext | One bit flipped in the payload, in the tag, and at each end |
| Truncated | Payload cut short (one message). File cut mid-JSON (refused before the prompt, R6) |
| Header tampering | Each of: `kind`, `formatVersion`, `appVersion`, `exportedAt`, `sections` counts, salt, nonce, iterations, cipher, kdf. All give the one message or, where the reader acts first, a refusal. None writes. Iterations out of range do not run the KDF |
| No plaintext | Canary strings planted in a URL path, query token, `streamid`, user:password, passphrase, stream name and host, and a pre-P2 `urlString`. **None appears in the file bytes** of an encrypted file. A shortcuts-only file holds none under any path. Export refuses to write a plain file with streams: there is no such code path, and a test pins that |
| Fixed fields | Golden test on the exact key set of a stream entry |
| Password | Under the minimum, mismatch, NFC and NFD forms of one password open the same file |
| Add-only | Every row of §4.2. Copy naming past "(copy 2)", and when "(copy)" already exists. Repeat import adds nothing (R1). Different passphrase adds a copy marked "passphrase differs", and a repeat of that adds nothing (R2). Refused read (R3). Existing entries and items byte-identical afterwards |
| Keychain reads at export | Found, refused, absent, unusable, on the in-memory `StreamSecretStore`: left-out list and header count correct |
| Undo | Removes exactly the added ids and items, nothing else |

**Attended:**

Shortcuts, on this build (A2), once you say go:

1. Stash `manifold.shortcuts`. Change two shortcuts. Export. Read the file in a text editor against §2.2.
2. Reset, import with Merge, then Replace All. Check the menus and a bare key take effect with no relaunch.
3. A conflict, both choices. A hand-edited file with a reserved key and a nonsense id: listed, not imported.
4. Undo Import. Restore from Backup…. Confirm files in the backup folder, and the 11th prunes the oldest.
5. Restore the stash, and compare.

Result, steps 1-5, 2026-11-03 (Robbie attended, Profile build of 0.9.1 (23) plus the uncommitted A1+A2 work): passed. The exported
file matched §2.2. Six backups were written, and ten seeded ones proved the limit: the six oldest were pruned, leaving ten. Undo
returned the exact earlier overrides. The key was absent before and after the pass. The Test 2 conflict ran from a state where
Inspector was on ⌥⌘Y, and Robbie confirmed Replace All was selected; Merge against an action on its default key is covered by
the unit test only. Bug found: the save panel suggested `….manifoldsettings.manifoldsettings`, repeated on a second
export with the name untouched. The panel now gets the name without the extension, and an attended export confirmed one extension.

Streams, sandbox only (A6):

6. Round trip with real URLs against a local OBS SRT and MediaMTX target, not only Cloudflare. They connect with no prompt, and the
   items read back.
7. Export with a Keychain prompt Denied on an unsigned build: left-out list, Try Again, Export Without Them.
8. Wrong password. A file edited by hand in the payload and in the header.
9. Undo Import. `streamBookmarks` of the real install unchanged, by presence check.

Result, steps 6-9, 2026-11-03 (Robbie attended, Profile, sandboxes `xfer-a` and `xfer-b`, fake URLs and passphrases only): passed, with
one limit. A Keychain prompt Denied gave the left-out sheet, Export Without Them wrote 3 streams, and Try Again with Allow wrote 4.
Both files decrypted in Python, with entries and header counts correct and no stream text in the file bytes. Wrong password, a changed
payload and a changed header gave the one message; cut JSON was refused before the prompt. The preview showed Added, Renamed
(different URL, passphrase differs, could not compare), Already here and Not imported. Undo returned the list to the four seeded streams.
Into an empty sandbox: 4 added, a repeat said Already here (4), all four dial URLs matched by hash, and no stream prompt appeared. The
real `streamBookmarks`, the 8 real stream items and the licence key names were unchanged by hash and name.

**Limit:** with fake URLs, step 6's real connection did not run in this pass. A connect to a fake host read its item with no prompt and
failed at DNS, as expected. The Studio-to-Air round trip connected to a real stream, 2026-11-05 (below). No run against local OBS SRT and
MediaMTX by name is recorded.

Found and fixed in the pass: the password fields' hints read as labels and Export gave no reason for being greyed. Both fields now have a
title above them and a line says what Export is waiting for. The Export and Import caption now names streams.

The Air, signed build (A6):

10. ~~Run the PBKDF2 timing probe.~~ **Not needed:** the count is frozen at 1,000,000 (§2.5).
11. Export on the Studio, import on the Air, and the reverse. Streams connect with nothing asked.
12. Confirm a signed build reads its own items without a prompt.
13. `.code` nudge binding and the Fn warning on the Air's keyboard. Licence unaffected on both, by presence only.

Result, step 11, 2026-11-05 (Robbie, attended): passed. Streams exported with a password on one Mac, imported on the other, and connected
to a real stream with no URL, passphrase or Keychain prompt. This also gives the real connection the sandbox pass couldn't (step 6).

Result, step 12, 2026-11-05 (Robbie, attended; 0.9.2 build 24, signed Developer ID build installed in `/Applications`): import PASSED. Importing an
encrypted streams file asked only for the file's password, with no Keychain prompt.

**Observation, same build:** on the Mac Studio, the development Mac, Export asked for Keychain access once per saved stream: 7 prompts for 7
streams. Likely cause, not verified: those items were last written by unsigned local Profile builds, so their access lists don't include the
Developer ID signature. **Open check:** an export on a Mac that has only run signed builds (the Air) should not prompt.

Step 13 has no result recorded.

**A5 result, 2026-11-04** (Profile, `.build-cc`, one windowed launch, sandbox `a5`, fixtures only, no keystrokes; real double-clicks and
drags from a Finder window by synthesized pointer events):
- **Type:** `com.graviton.manifold.settings`, not dynamic, kind "Manifold Settings", conforms to `public.json` and `public.data`, not
  `public.movie`. **Icon:** the system's generic text document labelled MANIFOLDSETTINGS. No document artwork exists.
- **Double-click:** encrypted asked for the password first, then the preview. Plain (through Launch Services to the pid) went straight to the
  preview. Either way one process and one window: the window SwiftUI made closed, and the sheet was on the existing one. Damaged: the refusal
  on the player window. A second file while a preview was up: declined, no stray window.
- **Drop on the picture:** plain gave the preview, encrypted the password.
- **Nothing written until Import:** `streamBookmarks`, `manifold.shortcuts`, the backup folder, the sandbox list and items, and the fixtures,
  compared at each step, were unchanged through every preview, Cancel and refusal. Import wrote 3 streams; Undo removed them.
- The new "Undo this import?" wording read exactly as specified, with Cancel the default. No media route ran, no log line named a fixture, and
  no recent-items list named one.
- All stores matched the baseline after cleanup. The real `streamBookmarks` and the 8 real stream items were unchanged.

**Limits.** A cold double-click (no build running) did not run in this launch: nothing can start a build by double-click inside the sandbox, and
the driver's attempt to imitate it arrived too early (`-600`). Robbie ran it by hand instead and it passed, 2026-11-04: one window, preview shown,
Cancel, real stores unchanged. A preview over a live stream did not run; by reading, the route returns before the retire.
A scripted `tell application "Finder" to open` did not reach the app and left a system dialog ("does not have permission to open"); a real
double-click of the same file worked, so this looks like the script's, and it was not investigated further.

**Launch Services note.** A build that changes the app registers it, and this type's only claimant is then that build. A double-click with no
build running would start the dev build outside the sandbox. The run unregistered `.build-cc`. A rebuild that changes nothing skips registration
(seen 2026-11-04); `lsregister -f <app>` is what registers it.

---

## 9. Stages

Effort is in working sessions, and is a guess, not a measurement.

| Stage | Content | Effort | State |
|---|---|---|---|
| A1 Shortcuts core | `SettingsTransfer`, file format, set-level judge, backups, tests | 1 | **Done** |
| A2 Shortcuts UI | Settings section, export sheet, import preview, Undo, Restore | 1 | **Done, attended pass passed** |
| A3 Encrypted file | Header, KDF, seal and open, password sheets, tests | 1 | **Built, sandbox pass passed** |
| A4 Streams | Export entry and Keychain pass, left-out sheet, add-only plan, preview, apply, Undo | 1.5 | **Built, sandbox pass passed; connected to a real stream in the Studio-to-Air round trip, 2026-11-05** |
| A5 Identity | UTI, double-click, drop, PRIVACY_AUDIT | 0.5 | **Built, sandbox pass passed. Cold-launch double-click passed by Robbie, 2026-11-04. Pending: a live stream under a preview** |
| A6 Attended | Sandbox pass, Air pass | 0.5 | **Sandbox pass passed; iteration count frozen, no Air measurement needed (§2.5). Studio-to-Air round trip passed, 2026-11-05 (step 11). Signed-build import passed on 0.9.2 build 24 (step 12). Open: export with no prompt on a Mac that has only run signed builds; no result recorded for step 13** |

Sources for the iteration figure: [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
