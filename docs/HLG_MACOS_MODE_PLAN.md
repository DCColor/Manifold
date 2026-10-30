# HLG in As macOS Shows It — Option B plan (2026-10-30)

**Option B:** As macOS Shows It hands HLG to the system's display-adaptive HLG adjustment
(`CAEDRMetadata.HLGMetadata`). Reference stays strict: BT.2408 anchor, no tone-map, clips at the display's ceiling.
Bypass is unchanged.

**Status: approved 2026-10-30, with three changes (Robbie): HLG only, PQ deferred (§5); the macOS-mode readout line is
Robbie's wording (§3.2 item 9); the clip line is Robbie's wording (§4). Implemented in the working tree, not committed.**
Sections 1–2 are the investigation, with file and line numbers as of `7e0da82`; they are not re-pinned to the change. Other
claims cite an SDK header (macOS 26.5 SDK, `MacOSX26.5.sdk`). Background: `COLOR_MANAGEMENT_FINDINGS.md` §6.11, *HLG on an
SDR-mode display is far too bright* (2026-10-29), and `BUGS.md`, *OPEN 2026-10-29*.

---

## 1. Where the layer's colour state is set or changed

### 1.1 The three properties

| Property | Written at | When | Value today |
|---|---|---|---|
| `toneMapMode` | `MetalVideoRenderer.swift:1178` | once, at construction, on main, before a render thread exists | `.never`, every mode and every source |
| `EDRMetadata` | **nowhere.** Absent on purpose: `:1148-1158` (the comment at `toneMapMode`) and `:2142-2145` (the "E3" note) | — | `nil` (the header's default, `CAMetalLayer.h:131-137`) |
| `colorspace` | `MetalVideoRenderer.swift:3136` | render thread, top of the tick, inside a `CATransaction` (`:3129-3138`) | `PendingColorState.colorSpace` |
| `wantsExtendedDynamicRangeContent` | `MetalVideoRenderer.swift:3137` | the same block | `PendingColorState.wantsEDR` |

Nothing else writes these. `grep` over `App/` and `Packages/` for `metalLayer.<prop> =`, `contentsHeadroom`,
`preferredDynamicRange`, `EDRMetadata`, `toneMapMode` finds only the lines above plus geometry (`MetalSurfaceView.swift:16,26,51,53`;
`MetalVideoRenderer.swift:1109-1142,3126,3625`). `contentsHeadroom` is never set (default 0, untagged; `CALayer.h:472-480`).

### 1.2 How a value reaches the layer (one path, main computes, render thread installs)

1. **Source codes in.** Every transport ends in `setSourceColorSpace(primaries:transfer:matrix:provenance:hdr10:)`
   (`MetalVideoRenderer.swift:2075`): files (`ContentView.swift:791`), file overrides (`FileColorOverride.swift:111,117`), NDI
   (`NDIService.swift:2696-2710`), and the SRT/WHEP/HLS routers. It builds the colorspace (`:2111`, `makeColorSpace`), sets
   `sourceWantsEDR = transfer ∈ {16, 18}` (`:2131`, `:2137`), then calls `resolvePictureCodes()` and `publishColorState()`
   (`:2138-2140`).
2. **LUT in.** `setInterpretationLUT` (`:5513`) also calls `resolvePictureCodes()` (`:1973`), the only writer of the picture
   codes, `pictureDerivedColorSpace` and `pictureWantsEDR` (`:1977-1985`). A LUT that states its output space gets its own
   colorspace and EDR flag (`:1979-1981`). Otherwise the source's object is used (`:1983-1984`).
3. **Mode in.** `setDisplayTransform` (`:1875-1888`) stores the mode and calls `publishColorState()`.
4. **The one decision.** `publishColorState()` (`:1905-1962`) chooses the layer colorspace by mode:
   - `.os` → `installed = cs`, the picture colorspace (`:1920-1922`)
   - `.bypass` → `nil` (`:1923-1925`)
   - `.reference` → `plan.layerColorSpace` and `plan.shader` (`:1926-1938`)

   It parks `PendingColorState` (struct at `:1602-1622`) under `refreshLock` with `wantsEDR: pictureWantsEDR` (`:1951`, the
   same in all three modes), sets `pendingRefresh` and wakes the display link (`:1956-1958`).
5. **Install.** The render thread takes `pendingColorState` at the top of `performDisplayTick` (`:3094-3096`). It writes
   `colorspace` and `wantsEDR` (`:3129-3138`), then `activeReference`, the decode matrix, the output state and the LUT
   (`:3139-3146`). This all happens **before** `nextDrawable()` (`:3708`, `:4003`).

### 1.3 ReferencePlan

`ReferencePlan.make` (`ReferencePlan.swift:61-117`). **PQ and HLG return the source colorspace and no shader: "identical to
OS"** (`:67-74`). This is the line that makes OS and Reference the same for HLG today. Its summary is the chain readout's Transform
line in Reference (`DisplayChainModel.swift:263-267`). Plans are compared with `==` (`ReferencePlan.swift:55-59`), which
drives the `[REFERENCE]` log (`MetalVideoRenderer.swift:1934`).

### 1.4 Mode switching and Hold C

- **Menu, shortcut, pulldown:** `DisplayTransform.swift:250`, `ShortcutCenter.swift:197`, `DisplayTransformControl.swift:255`
  → `DeckRegistry.setDisplayTransform(_:on:temporary:)` (`WindowDeck.swift:859-884`) → `renderer.setDisplayTransform`
  (`:877`). At window creation: `ContentView.swift:714`.
- **Hold C** (`HoldToCompare.swift:68-96`): OS ↔ Reference, Bypass → OS. **⇧C** forces Bypass (`:78-85`). It stamps
  `markCompareEvent` (`:92`) and calls `setDisplayTransform(target, temporary: true)` (`:93`). Release restores the chosen
  mode the same way (`:122-123`). With `temporary: true`, `WindowDeck.swift:860-868` sets `heldDisplayTransform` and calls
  `renderer.setDisplayTransform(held ?? chosen)` (`:865`). **So a hold goes through exactly the same
  `publishColorState` → `PendingColorState` → render-thread install path as a menu pick.** The compare stamp rides in the same
  locked read (`MetalVideoRenderer.swift:3097-3098`, `:3146`).
- **⌥C (LUT off)** (`HoldToCompare.swift:55-64`) bypasses the LUT. That moves the picture codes through `setInterpretationLUT`
  → `resolvePictureCodes` → `publishColorState`, the same path again.

### 1.5 What reads the layer's state back

The `[EDR]` log (`logLayerState`, `MetalVideoRenderer.swift:2007-2026`) and the chain readout's Transform line and verdict
(`DisplayChainModel.swift:259-309`). Neither knows about `toneMapMode` or `EDRMetadata` today.

---

## 2. Does `toneMapMode = .never` stop `HLGMetadata`? What does macOS mode need?

### What the local headers say (quoted, nothing inferred)

- `CALayer.h:39-40`: *"Options that control when to tone map CALayer contents and CAMetalLayer drawables. Defaults to
  CAToneMapModeAutomatic."*
- `CALayer.h:48`, `.never`: *"Never tone map contents."*
- `CALayer.h:44`, `.automatic`: *"Let the OS decide whether to tone map."*
- `CALayer.h:52-54`, `.ifSupported`: *"Tone map whenever supported by the OS. This includes PQ, HLG and extended-range contents
  for CALayer and CAMetalLayers."*
- `CAMetalLayer.h:131-136`, `EDRMetadata`: *"Must be set before calling nextDrawable. If non-nil, content may be tone mapped to
  match the current display characteristics. If nil, samples will be rendered without tone mapping and values above the maximum
  EDR value … may be clamped."*
- `CAEDRMetadata.h:100-105`, `HLGMetadata`: *"Content is scene referred and originally encoded with the ITU-R BT.2100-2 Hybrid Log
  Gamma (HLG) OETF. The system will apply the OOTF based on peak display brightness and ambient. If rendering to a CAMetalLayer
  with a linear colorspace …, the content provider must have already applied the HLG inverse OETF."*
- `CGImage.h:239,257`: *"The image with unknown content headroom will be excluded from tone mapping."*

### Verdict

- **The headers do not state the precedence between `toneMapMode` and `EDRMetadata`.** Neither header mentions the other
  property. There is no local Apple documentation beyond the SDK headers (no DocumentationCache on this Mac). So: **UNKNOWN from
  local sources.**
- **But the plain reading points one way.** `EDRMetadata` says content *"may be tone mapped"*. `.never` says *"Never tone map
  contents"*. The HLG OOTF *"based on peak display brightness"* is a display-adaptive mapping. A header that says "never" gives
  no grounds for expecting it to apply. **Plan as if `.never` blocks it, and measure (§3.6, T1).**
- **Prior evidence does not decide it.** `.never` was measured as ignored on a CGImage-contents `CALayer` (`BUGS.md`, DECISION
  2026-08-28: *"`.never` is not honoured for a CALayer with assigned CGImage `contents`"*). That was a different layer type and
  content path. Whether a `CAMetalLayer` honours it is unmeasured (`MetalVideoRenderer.swift:1170-1174` says so).
- **What macOS mode needs:** `toneMapMode` must not be `.never` while `HLGMetadata` is set. There are two candidates.
  `.ifSupported` is the only value whose header text names HLG and `CAMetalLayer` (`CALayer.h:52-54`), so it is the explicit
  request. `.automatic` is the default and leaves the decision to the OS (`:44`). **Recommendation: `.ifSupported`.** Measure
  `.automatic` alongside it, and pick whichever reproduces the system HLG result (T2 against T3). The deployment floor is
  macOS 15.0 (`project.yml:4-5`), the same as `toneMapMode`'s availability (`CALayer.h:42`), so no availability branch is needed.
- **The colorspace can stay as it is.** The inverse-OETF requirement applies to a *linear* layer colorspace only. Manifold's
  layer is HLG-encoded under `kCGColorSpaceITUR_2100_HLG`, and the shader writes HLG-encoded R′G′B′ (findings §1). **UNKNOWN:**
  whether CA then applies ColorSync's fixed 1000-nit γ1.2 OOTF (the colorspace's own, findings table 2) **and** the metadata's
  adaptive OOTF (a double application), or only the metadata's. T1–T3 settle it: HLG 75 % on the ASUS must land near
  `.forceSDR`'s ≈ 0.59 encoded (findings §5), not lower.
- **Ambient Viewing Environment.** `hlg(ambientViewingEnvironment:)` needs macOS 14 (`CAEDRMetadata.h:98`), which is below the
  floor. Nothing in the app reads `kCMFormatDescriptionExtension_AmbientViewingEnvironment` today (grep: no hits). Phase 1 uses
  the plain `HLGMetadata`, which is the only form that exists for live sources and LUT-stated HLG. File AVE is a follow-up (§3.7).

---

## 3. Implementation plan — As macOS Shows It only

### 3.1 The rule

The two new properties follow **mode × picture transfer code**:

| Mode | Picture transfer | `EDRMetadata` | `toneMapMode` | colorspace / wantsEDR / shader |
|---|---|---|---|---|
| **As macOS Shows It** | **18 (HLG)** | **`CAEDRMetadata.hlg`** | **`.ifSupported`** (or `.automatic`, per T2/T3) | unchanged |
| As macOS Shows It | anything else | `nil` | `.never` | unchanged |
| Reference | any | `nil` | `.never` | unchanged |
| Bypass | any | `nil` | `.never` | unchanged |

The **picture** transfer code drives it, not the source code. It describes the picture handed to the layer (CLAUDE.md, colour
codes rule). So an HLG source under a LUT stated as Rec.709 gets no HLG metadata, and a LUT stated as HLG does.

### 3.2 Exact changes

1. **`PendingColorState`** (`MetalVideoRenderer.swift:1602-1622`): add two fields:
   `let edrMetadata: CAEDRMetadata?` and `let toneMapMode: CALayer.ToneMapMode`. Doc comment: they are installed with the
   colorspace, so a frame is never presented under one and declared under the other.
2. **`publishColorState()`** (`:1905-1962`): compute both in the existing `switch displayTransform`.
   - `.os`: `pictureTransferCode == 18 ? (.hlg, .ifSupported) : (nil, .never)`.
   - `.bypass` and `.reference`: `(nil, .never)`.

   Pass both into `PendingColorState(...)` (`:1951`). No other input changes. `pictureTransferCode` is already current here,
   because `resolvePictureCodes()` runs before every publish that moves it (`:2139-2140`, and the LUT setter).
3. **Render-thread install** (`:3129-3138`): inside the same `CATransaction`, after `colorspace` and `wantsEDR`, write
   `metalLayer.EDRMetadata = colorState.edrMetadata` and `metalLayer.toneMapMode = colorState.toneMapMode`. This is above
   `nextDrawable()` (`:3708`, `:4003`), which `CAMetalLayer.h:132` requires (*"Must be set before calling nextDrawable"*). Read
   both back and log them, as `docs/color-fixtures/edr_bypass_probe.swift:214-220` does for colorspace and EDR. A silent
   rejection must show in the log.
4. **Construction** (`:1178`): keep `metalLayer.toneMapMode = .never` as the initial state, because no colour state exists yet.
   Rewrite the comment block (`:1146-1177`). It now says "This does not vary" and "NOT in the per-source colour block". Under
   Option B it varies by mode and is written by the install block as well. State the new rule and point here.
5. **`.os` guarantee comment** (`:1895-1902`, "`.os` MUST STAY BYTE-IDENTICAL…"): narrow it to "byte-identical for every
   picture whose transfer is not HLG". The pixels stay identical for HLG too: nothing upstream of the drawable changes. Only the
   layer's presentation metadata differs.
6. **E3 note** (`:2142-2145`): replace it with a pointer to this plan. `EDRMetadata` is now set, in OS mode, for HLG only.
7. **`logLayerState()`** (`:2007-2026`): add a third `[EDR]` line, worded from the installed state, never the intent
   (`:2000-2006`). Examples: `[EDR] EDRMetadata = HLG (system OOTF, adapts to display peak) · toneMapMode = ifSupported — AS
   MACOS SHOWS IT`, or `[EDR] EDRMetadata = nil · toneMapMode = never`.
8. **`ReferencePlan.make`** (`ReferencePlan.swift:67-74`): split HLG from PQ. The layer colorspace and shader stay the same,
   but the HLG summary and log line can no longer say "identical to OS". Proposed:
   - summary: `Reference — HLG at BT.2408 (75 % = SDR white), no tone-map; above the display's ceiling clips`
   - log: `[REFERENCE] HLG source on "…": BT.2408 anchor, no tone-map — differs from OS, which applies the system HLG OOTF`

   PQ keeps today's text. `DisplayTransform.swift:55-58` ("PQ and HLG: identical to `.os`") needs the same edit, as does the
   file header (`ReferencePlan.swift:11-12`).
9. **Chain readout, OS mode with the adjustment active** (as approved): the verdict sentence under the rows, not the
   Transform row, reads `HLG (tagged) → macOS HLG adjustment · follows display brightness · scopes show the file`. The
   parenthesis is the source's tier (`tagged` / `assumed` / `overridden`), or `LUT output` when a LUT states HLG. It keys on
   the renderer's `hlgAdjustmentActive`, which is what was published, not on the mode alone. The Transform row is unchanged.
   The verdict is also logged as `[CHAIN] Verdict:` so an unattended run reads it.
10. **Docs to amend in the same commit:** `BUGS.md` DECISION 2026-08-28 (a scoped exception: OS mode, HLG only, desktop only),
    the OPEN 2026-10-29 entry, and `COLOR_MANAGEMENT_FINDINGS.md` §6.2 (*"OS ≈ Reference on PQ is the expected result"* holds
    for PQ and is now deliberately false for HLG).

Unchanged: `setSourceColorSpace`, `resolvePictureCodes`, `makeColorSpace`, the shaders, `ScopeColorFeed`, `OutputSignal`,
DeckLink, export.

### 3.3 How mode switches and Hold C swap the state cleanly

- **One writer, one thread, one instant.** Both new fields travel in `PendingColorState` with the colorspace. They are therefore
  computed in the same `publishColorState()` call, parked under the same `refreshLock`, taken in the same locked read
  (`:3094-3096`) and written in the same `CATransaction` (`:3130-3138`). A frame can never be presented with OS's metadata and
  Reference's (identical) colorspace, or the reverse.
- **Paused pictures update.** `publishColorState` sets `pendingRefresh` (`:1956`). The current frame is re-presented under the
  new state. That is required: properties apply at present time (`:1864-1871`).
- **Hold C, OS → Reference:** the next tick writes `EDRMetadata = nil` and `toneMapMode = .never`, and the re-present shows
  strict BT.2408. **Release:** `.hlg` and `.ifSupported` go back on, then re-present. **⇧C (Bypass):** both are cleared, as in
  Reference.
- **The LUT edge (⌥C or a LUT change)** can move the picture transfer to or from 18 and re-publishes through the same path.
- **No extra writers.** No new call site touches the layer. `toneMapMode` at `:1178` runs once, before any render thread exists.
- **To measure, not assume:** an EDR-metadata change can make WindowServer reconfigure the compositor. The `[COMPARE]` stamps
  already time key → glass (`HoldToCompare.swift:89-92`; `activeCompareStamp`, `MetalVideoRenderer.swift:1636-1643`). T6
  compares hold latency on HLG against an SDR file and checks for a flash or a one-frame black.

### 3.4 SDI and HDMI never pass through this layer — confirmed

- The layer properties act at composite time, on the drawable only. The drawable is acquired at `MetalVideoRenderer.swift:3708`
  (playback) and `:4003` (black frame), and nowhere else.
- **DeckLink (SDI and HDMI)** converts from the offscreen ring: `readableOffscreen()` (`:571`) at `:4576`, with the texture bound
  at `:4621` (native) and `:4727` / `:4751` (placed). The signal tagging comes from `OutputSignal` and `FrameOutputState`, carried
  with the frame (`:1946-1955`), and the HDMI InfoFrame from `DeckLinkBridge.mm:914-915`. None of these reads `CAMetalLayer`.
  `DisplayTransform.swift:31-35` states the same for SDI.
- **Scopes** (`:4112-4284`, all `offscreenTexture`), **frame export** (`:5059`) and the **v210 dump** (`:5241-5253`) also read
  the offscreen.
- **So:** SDI and HDMI output bytes and tags are identical across all three modes before and after Option B. T7 checks this with
  a v210 dump hash.

### 3.5 Accepted consequences (must be written into the DECISION amendment)

1. **In OS mode, the HLG picture and the scopes disagree** above (and, through the OOTF, below) reference white. The waveform
   shows BT.2408 code values; the picture shows the system's adaptive mapping. This is reason 1 of DECISION 2026-08-28, now
   accepted for OS + HLG only. Reference remains the mode in which picture and scopes agree.
2. **The OS-mode HLG picture moves with brightness, ambient light and headroom** (reason 3), by design: *"what your client will
   see"* (§6.3).
3. **OS ≠ Reference on HLG**, for the first time. Hold C becomes a meaningful comparison for HLG.
4. **Side effect, unmeasured:** the scrub overlay already tone-maps HDR (DECISION 2026-08-28 table). In OS mode, HLG scrub and
   HLG playback may now be closer. Record what T4 shows; do not claim it.

### 3.6 Verification plan (for the build session; tell Robbie before any launch; guard before and after)

Fixture: a generated HLG grey ramp (0–100 % in 5 % steps, plus 75 % = code 721), Rec.2020 · HLG · 2020 NCL, written to the
scratchpad with ffmpeg. Also `/Volumes/DCCOLOR/IMG_5070_noDV.mov`, read-only in place. **Pixel values on the ASUS only**,
window-only capture by window ID. **By-eye and HDR checks on the LG only.** A temporary DEBUG-only env switch
(`MANIFOLD_HLG_TONEMAP=never|automatic|ifSupported|off`, removed before commit) runs T1–T4 from one build.

| # | Condition (OS mode, HLG ramp) | Answers |
|---|---|---|
| T0 | `off` (no metadata, `.never`) = today | baseline; it should match findings table 2 clipped at 1.0 |
| T1 | `.hlg` + `.never` | **Does `.never` block `HLGMetadata`?** Same as T0 → yes |
| T2 | `.hlg` + `.automatic` | candidate |
| T3 | `.hlg` + `.ifSupported` | candidate (recommended) |
| T4 | no metadata + `.ifSupported` | control: does `.ifSupported` alone map an unknown-headroom drawable? |
| T5 | T2/T3 winner on the LG, HDR on, two brightness settings | adapts with headroom; no double OOTF (75 % not darker than `.forceSDR`'s shape) |
| T6 | Hold C, HLG and SDR files, `[COMPARE]` lines | latency and no flash on swap |
| T7 | v210 dump in OS, Reference and Bypass, before and after | SDI/HDMI unchanged (FNV-1a identical) |
| T8 | PQ and SDR files in OS | byte-identical layer state to today (`[EDR]` lines, captures) |

Pass for T2/T3 on the ASUS: 75 % lands near `.forceSDR`'s encoded ≈ 0.59, 100 % at or below SDR white, and no patch of
`IMG_5070` at 4.5 s (findings §3 coordinates) is ≥ 1 % clipped.

### 3.6a T0–T4 results, measured 2026-10-30

**Set-up.** The working-tree build (Profile), launched with `scripts/run.sh --no-build` and `MANIFOLD_HLG_TONEMAP` set, one
launch per condition, quit by PID, guard clean before and after each. Fixture: a generated ramp, 2100 × 1080 ProRes 422 HQ,
tagged 9-18-9 limited, 21 bars at Y′ 64 + 43.8·n (`64, 107, … 721, … 940`; 75 % = code 721), with `colr` checked through
AVFoundation. As macOS Shows It. The window was on the **ASUS PA147** (SDR, current = potential = 1.0; `[CHAIN] Headroom: display
is in SDR mode on "ASUS PA147"`), at 1011 × 520. Window-only capture by window ID; the PNGs carry the ASUS profile. G channel at
each bar centre, middle row. The captures were deleted after this table was written; the logs are kept in the session scratchpad.

| HLG % | 0 | 5 | 10 | 15 | 20 | 25 | 30 | 35 | 40 | 45 | 50 | 55 | 60 | 65 | 70 | **75** | 80 | 85 | 90 | 95 | 100 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **T0** off (today) | 0 | 24 | 56 | 83 | 111 | 136 | 161 | 186 | 209 | 233 | **254** | 255 | 255 | 255 | 255 | **255** | 255 | 255 | 255 | 255 | 255 |
| **T1** `.hlg` + `.never` | 0 | 24 | 56 | 83 | 111 | 136 | 161 | 186 | 209 | 233 | **254** | 255 | 255 | 255 | 255 | **255** | 255 | 255 | 255 | 255 | 255 |
| **T2** `.hlg` + `.automatic` | 0 | 9 | 19 | 28 | 39 | 48 | 60 | 71 | 81 | 93 | 103 | 116 | 129 | 146 | 162 | **179** | 195 | 210 | 225 | 241 | 255 |
| **T3** `.hlg` + `.ifSupported` | 0 | 2 | 12 | 24 | 37 | 47 | 59 | 72 | 81 | 94 | 104 | 117 | 129 | 147 | 165 | **187** | 206 | 220 | 233 | 244 | 254 |
| **T4** no metadata + `.ifSupported` | 0 | 2 | 12 | 24 | 37 | 47 | 59 | 72 | 81 | 94 | 104 | 117 | 129 | 147 | 165 | **187** | 206 | 220 | 233 | 244 | 254 |
| *ref.* ColorSync HLG → SDR destination (100 % = white), into the ASUS profile | 0 | 3 | 13 | 25 | 37 | 48 | 60 | 71 | 82 | 93 | 104 | 116 | 130 | 146 | 166 | *188* | 206 | 221 | 233 | 245 | 255 |
| *ref.* AVFoundation `.forceSDR` (QuickTime's path), into the ASUS profile | 0 | 8 | 22 | 34 | 45 | 55 | 64 | 73 | 82 | 90 | 98 | 106 | 116 | 127 | 140 | *154* | 170 | 188 | 208 | 230 | 255 |
| *ref.* BT.2408 anchor clipped at 1.0 (the 2026-10-29 prediction for T0) | 0 | 3 | 16 | 31 | 46 | 61 | 76 | 91 | 107 | 122 | 137 | 153 | 173 | 196 | 223 | *255* | 255 | 255 | 255 | 255 | 255 |

The reference rows were computed from the same file (`AVAssetImageGenerator` `.matchSource` / `.forceSDR`, drawn into the ASUS
profile; for the last row, drawn into extended linear Rec.2020, clamped at 1.0, then into the ASUS profile).

**Findings:**

1. **T1 = T0, byte for byte. `toneMapMode = .never` blocks `CAEDRMetadata.hlg` on a CAMetalLayer**, although the layer read
   the metadata back as set (`[EDR] layer read-back: EDRMetadata HLG · toneMapMode never`). §2's reading of the headers holds.
2. **`.ifSupported` takes effect, and it is one conversion, not two.** T3 matches ColorSync's own HLG → SDR conversion (HLG
   100 % → SDR white) within ±2 codes at every bar. There is no clipping, and 75 % lands at 187. **No double conversion** (a double
   conversion would come out darker than a single one). Neither stop condition is met.
3. **T4 = T3, byte for byte. At headroom 1.0, `CAEDRMetadata.hlg` adds nothing: `toneMapMode = .ifSupported` alone produces
   the mapping.** The plan assumed the metadata was the mechanism. On this display it is the tone-map mode. Whether the metadata
   matters at headroom > 1 (the header's "OOTF based on peak display brightness") is untested; that is T5 on the LG in HDR mode.
4. **T2 (`.automatic`) is a different curve:** shadows lifted (5 % → 9 against 2) and highlights lower (75 % → 179 against 187).
   It also takes effect.
5. **The adjusted picture is brighter than QuickTime's AVFoundation path in the mids:** 75 % → 187 against `.forceSDR`'s 154,
   and 50 % → 104 against 98. Whether QuickTime *playback* on screen equals `.forceSDR` is still unmeasured (findings
   2026-10-29, §5). Robbie's by-eye comparison will settle what matters.
6. **⚠️ T0, today's on-screen HLG, is NOT the BT.2408 anchor.** The measured ramp fits **display-linear = 4·E′²** at every bar
   below the clip (ASUS ≈ γ2.2: 24 → 0.0055 ≈ 4·0.05², 136 → 0.25 = 4·0.25², 254 → 1.0 = 4·0.5²). That is HLG's inverse OETF
   (scene-linear E′²/3) scaled ×12, with no OOTF: **HLG 50 % lands at SDR white, and everything from about 50 % up clips** at
   headroom 1.0. The 2026-10-29 findings predicted the BT.2408 anchor (75 % = SDR white) from ColorSync conversions and listed the
   on-screen value as Open 1, *unmeasured*. Measured on screen, that prediction is wrong for the composite.
   **Consequence for Reference:** Reference installs the same layer state as T0 for HLG (source colorspace, identity copy, no
   metadata, `.never`). So on screen, Reference HLG at headroom 1.0 is **expected** to be T0's curve, not BT.2408. That is
   inferred from the layer state; Reference itself was not captured. If so, Reference's summary (`HLG at BT.2408 (75 % = SDR
   white)`) and the approved clip line (`highlights above reference white (HLG 75 %) clip`) are **wrong on screen** at headroom
   1.0. The clip starts near HLG 50 %. Not changed here: Robbie's call.

### 3.6b Reference HLG and PQ on screen, measured 2026-10-30

Same procedure as §3.6a (default build: `.ifSupported` + `.hlg`; ASUS, headroom 1.0; window-only captures, deleted after
recording). Modes were picked by AX clicks on the Color menu items and confirmed in the log. Logs `r1.log` and `p1.log` are in the
session scratchpad.

**HLG ramp:** As macOS Shows It = T3 exactly. **Reference = T0 exactly** (`0 24 56 83 111 136 161 186 209 233 254 255 …`).
Read-back `EDRMetadata nil · toneMapMode never`. The 0.9.0 Reference bug is measured.

**PQ ramp** (`pq_ramp_14.mov`, generated, 9-16-9 limited, 14 bars; codes 64, 195, 327, 450, **509**, 545, **573**, 609, 636, 674,
**723**, 789, 855, 940 = 0, 1, 10, 50, **100**, 150, **203**, 300, 400, 600, **1000**, 2000, 4000, 10000 nits):

| nits | 0 | 1 | 10 | 50 | **100** | 150 | **203** | 300 | 400 | 600 | **1000** | 2000 | 4000 | 10000 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| As macOS Shows It | 0 | 25 | 89 | 188 | **255** | 255 | **255** | 255 | 255 | 255 | 255 | 255 | 255 | 255 |
| Reference | 0 | 25 | 89 | 188 | **255** | 255 | **255** | 255 | 255 | 255 | 255 | 255 | 255 | 255 |
| *ref.* BT.2408 (203 = 1.0), clipped at 1.0, into the ASUS profile | 0 | 15 | 63 | 136 | *186* | *223* | *255* | 255 | 255 | 255 | 255 | 255 | 255 | 255 |

**PQ 203 nits lands at 255, and so does 100 nits.** On screen, PQ is anchored at **100 nits = 1.0 (SDR white)**. Below the
clip, measured ÷ predicted in linear (ASUS ≈ γ2.2) is 2.15× at 10 nits and 2.04× at 50 nits, ≈ 203/100. That matches
`CAEDRMetadata.h:28-31`, *"1.0 mapping to diffuse white of 100 nits"*. **PQ is off as well. Stopped here, as instructed:** T5 and
the Reference HLG plan wait for Robbie.

### 3.6c T5 — LG, HDR on, by eye against QuickTime, 2026-10-30 (Robbie)

Default build (`.ifSupported` + `.hlg`), `/Volumes/DCCOLOR/IMG_5070_noDV.mov` read in place, As macOS Shows It, on the LG with
HDR on. Log (`t5.log`, scratchpad): `layer read-back: EDRMetadata HLG · toneMapMode ifSupported`, **headroom granted 4.48 of
potential 8.97**, constant for the whole session.

- **As macOS Shows It vs QuickTime Player, same frame, side by side: identical by eye** (Robbie). This is a by-eye sanity check
  on the LG, not a reference judgement.
  Robbie's qualifier: *if Manifold was brighter, it was hard to tell given the content.* That fits the ASUS numbers at headroom
  1.0, where Manifold's adjusted HLG 75 % is 187 against AVFoundation `.forceSDR`'s 154 (§3.6a, finding 5). A small mid-tone
  difference is plausible and not resolved by eye on this clip.
- **Reference, by eye: much brighter, and clipping**, as expected from the 0.9.1 bug (§3.6b; fix in §6). Robbie switched OS ↔
  Reference twice. Each switch installed cleanly (`[EDR] display transform → …` followed by the matching read-back:
  Reference `nil · never`, OS `HLG · ifSupported`).
- **The second brightness setting could not be tested:** the LG has no brightness control on this Mac, only HDR on/off. So
  whether the adjusted picture tracks brightness, and whether `.hlg` changes anything against `.ifSupported` alone at headroom >
  1 (§3.6a finding 3), is **UNKNOWN**. Only headroom 1.0 (ASUS, T3 = T4) and 4.48 (LG, by eye) have been seen.
- No Hold C (T6 waits for the Reference fix).

### 3.8 Step C — PQ in As macOS Shows It, measure only, 2026-10-30

**Why:** decision 3 (Robbie): As macOS Shows It should be what macOS and QuickTime show, and for PQ it clips where QuickTime
tone-maps. This is a pre-existing 0.9.1 bug. Measure only; no fix until Robbie has seen the numbers.

**Set-up.** The same procedure as §3.6a/b: ASUS (headroom 1.0, SDR), window-only captures (deleted after recording), one launch
per condition, quit by PID, guard clean before and after. A second temporary DEBUG switch, `MANIFOLD_PQ_TONEMAP`, applies only to a
PQ picture in As macOS Shows It; remove it before commit. **Fixture:** `pq_ramp_14_hdr10.mov`, the §3.6b PQ ramp re-encoded HEVC
Main 10 through VideoToolbox with HDR10 static metadata (P3-D65 mastering primaries, 1000 / 0.0001 nits, MaxCLL 1000, MaxFALL
400). `mdcv` and `clli` boxes were present, and ffmpeg and Manifold both read them (`HDR10 [...] MDCV via
codecpar.coded_side_data`). Bar codes decoded identical to the ProRes ramp (509 = 100 nits, 573 = 203 nits). Tags 9-16-9. One file
for all three conditions, so only the layer state differs. (ProRes passthrough through AVAssetWriter did not write the boxes,
even with the extensions on the format description; HEVC encode did.)

**Conditions** (read-back in each log):
- (a) today: `EDRMetadata nil · toneMapMode never`
- (b) `MANIFOLD_PQ_TONEMAP=ifSupported`: `nil · ifSupported`
- (c) `MANIFOLD_PQ_TONEMAP=hdr10`: `set · ifSupported`; log `ifSupported + hdr10 (MDCV from file, CLLI from file, scale 100)`.
  `opticalOutputScale` 100 is the header's 1.0 = 100 nits. Whether it matters for a PQ-encoded float drawable is UNKNOWN; only
  100 was tried.

| nits | 0 | 1 | 10 | 50 | **100** | 150 | **203** | 300 | 400 | 600 | **1000** | 2000 | 4000 | 10000 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| (a) today | 0 | 25 | 89 | 188 | **255** | 255 | **255** | 255 | 255 | 255 | **255** | 255 | 255 | 255 |
| (b) `.ifSupported`, no metadata | 0 | 12 | 50 | 104 | **139** | 166 | **189** | 210 | 224 | 239 | **255** | 255 | 255 | 255 |
| (c) `.ifSupported` + `hdr10` (file) | 0 | 12 | 50 | 104 | **139** | 166 | **189** | 210 | 224 | 239 | **255** | 255 | 255 | 255 |
| *ref.* AVFoundation `.forceSDR` (QuickTime's path) | 0 | 15 | 63 | 137 | ***186*** | 213 | ***229*** | 243 | 250 | 254 | *255* | 255 | 255 | 255 |

AVFoundation's result is the same with and without the HDR10 metadata (the ProRes ramp without it gives the same row, ±1).

**Linear light, each condition ÷ AVFoundation** (ASUS ≈ γ2.2; "clip" = 255 where AVFoundation is still below):

| nits | 1 | 10 | 50 | 100 | 150 | 203 | 300 | 400 | 600 | 1000 |
|---|---|---|---|---|---|---|---|---|---|---|
| (a) today | 3.08 | 2.14 | **2.01** | clip | clip | clip | clip | clip | clip | 1.00 |
| (b) and (c) | 0.61 | 0.60 | **0.55** | **0.53** | 0.58 | 0.66 | 0.73 | 0.79 | 0.87 | 1.00 |

**Where 100 and 203 nits land:**
- **(a) today:** 100 nits = **255 (SDR white)**, and 203 is clipped. Mids are ~**2×** QuickTime's: 1.0 = 100 nits.
- **(b) and (c):** 100 nits = **139**, 203 nits = **189**. Mids are ~**0.55×** QuickTime's, roughly half. It rolls off to SDR
  white at about 1000 nits, then clips.
- **AVFoundation:** 100 nits = 186, 203 nits = 229. That is a 203-nit-anchored rendering (186 is exactly where "203 = 1.0" puts
  100 nits), with a roll-off from about 150 nits to white at about 1000.

**Findings:**

1. **The 100 vs 203 doubling appears in both directions.** Today is ~2× QuickTime in the mids (1.0 = 100 nits) and clips from
   100 nits. `.ifSupported` is ~0.5× QuickTime in the mids: it maps toward SDR white at ~1000 nits rather than at 203. **Neither
   matches QuickTime's path.** `.ifSupported` removes the clip but makes the picture darker than QuickTime by about a stop
   below 150 nits.
2. **At headroom 1.0, `CAEDRMetadata.hdr10` with the file's MDCV and MaxCLL changes nothing**: (c) = (b), byte for byte. As with
   HLG (T3 = T4), the tone-map mode switches the mapping on, and the metadata does not shape it on this display. Whether it does at
   headroom > 1 is UNTESTED.
3. **Not run:** headroom > 1 (LG, HDR on) for any PQ condition. Other `opticalOutputScale` values. `.automatic` for PQ.

**Decision (Robbie, 2026-10-30): `.ifSupported` is NOT adopted for PQ.** Today's PQ behaviour is kept for now. The
`MANIFOLD_PQ_TONEMAP` switch is removed. **Priority raised:** a MacBook Air is always at headroom 1.0, so Air users see PQ in
As macOS Shows It ~2× too bright and clipping against QuickTime (`BUGS.md`, the PQ entry).

### 3.9 Core Image `CIToneMapHeadroom` on the PQ ramp — offline, report only, 2026-10-30

**Availability:** `+[CIFilter toneMapHeadroomFilter]` is `NS_AVAILABLE(15_0, 18_0)` (`CoreImage.framework/Headers/CIFilterBuiltins.h:2556`,
macOS 26.5 SDK): **macOS 15.0, equal to the deployment target** (`project.yml`, `macOS: "15.0"`). No availability branch needed.

**Method.** No app was launched. The input is the frame at 1 s of `pq_ramp_14_hdr10.mov` (§3.8 fixture, MaxCLL 1000, mastering peak
1000), fed in two ways: an `AVAssetImageGenerator` `.matchSource` CGImage (`ITUR_2100_PQ`), and a decoded 10-bit pixel buffer with
the file's attachments. The filter ran with `targetHeadroom` 1.0. Output rendered by a `CIContext` (RGBAh working format) into the
ASUS profile, 8-bit, G at each bar centre. The two input paths agree within ±1 in every row.

| PQ nits | 0 | 1 | 10 | 50 | **100** | 150 | **203** | 300 | 400 | 600 | **1000** | 2000+ |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| *ref.* AVFoundation `.forceSDR` (step C) | 0 | 15 | 63 | 137 | ***186*** | 213 | ***229*** | 243 | 250 | 254 | *255* | 255 |
| CI, **no filter** (context render into SDR) | 0 | 15 | 63 | 137 | **186** | 213 | **229** | 244 | 250 | 254 | **255** | 255 |
| `CIToneMapHeadroom`, source **10** (MaxCLL ÷ 100), as specified | 0 | 10 | 42 | 89 | **120** | 141 | **160** | 181 | 194 | 211 | **231** | 255 |
| `CIToneMapHeadroom`, source **4.926** (= 1000 / 203) | 0 | 12 | 50 | 104 | **140** | 166 | **188** | 211 | 224 | 239 | **255** | 255 |
| *ref.* CA `.ifSupported` on the layer (step C (b)) | 0 | 12 | 50 | 104 | *139* | 166 | *189* | 210 | 224 | 239 | *255* | 255 |
| `CIToneMapHeadroom`, source **unset** (reads NaN) | 0 | 15 | 63 | 137 | 187 | 224 | 255 | 255 | 255 | 255 | 255 | 255 |

**Findings:**

1. **Core Image anchors PQ at 203 nits = 1.0**, like ColorSync and unlike the CAMetalLayer composite (1.0 = 100 nits). Both inputs
   report content headroom **4.9261 = 1000/203**. A `sourceHeadroom` of MaxCLL ÷ 100 (= 10) is therefore on the wrong scale for
   CI: it treats ~2030 nits as the peak, and comes out **darker** than everything else (100 nits → 120, 203 → 160; ≈ 0.4× QuickTime
   in the mids). The CI-consistent value is peak ÷ 203.
2. **`CIToneMapHeadroom` with the CI-consistent source (4.926) reproduces CA's `.ifSupported` curve within ±1** (100 → 140, 203 →
   188), the curve already rejected in §3.8 (0.55× QuickTime's mids). So `CIToneMapHeadroom` and `.ifSupported` are evidently the
   same tone curve, and **neither matches QuickTime**.
3. **What matches QuickTime is Core Image's default HDR → SDR render, with no filter:** a PQ CIImage rendered into an SDR colorspace
   equals AVFoundation `.forceSDR` within ±1 at every bar (100 → 186, 203 → 229, 1000 → 255). This is a CPU / CIContext render
   path, not a layer property. Whether it can feed the display layer at frame rate is not assessed. Report only.
4. **Unset `sourceHeadroom` reads NaN**, and the filter then hard-clips at 203 nits (no curve). The value must be set.

### 3.7 Follow-ups, not in this change

- File AVE through `hlg(ambientViewingEnvironment:)` from `kCMFormatDescriptionExtension_AmbientViewingEnvironment`
  (`CAEDRMetadata.h:86-98`). Measure first whether it changes anything against plain `.hlg` for Apple captures.
- `wantsExtendedDynamicRangeContent` is deprecated in the 26 SDK in favour of `preferredDynamicRange` (`CALayer.h:446-457`,
  `:464-470`; the latter needs macOS 26, above the floor). Not touched here.

---

## 4. Reference readout: clipping on a headroom-1.0 display

§6.3's chain readout style is `Source (tier)  →  transform  →  display · headroom` (`COLOR_MANAGEMENT_FINDINGS.md` §6.3, tier
3; §6.2: *"`PQ (tagged) → display is in SDR mode` is a complete answer in one line"*).

**⚠️ Superseded 2026-10-30 (Robbie, decision 4):** Reference at a granted headroom of 1.0, PQ and HLG alike, reads
`display in SDR mode · above 100 nits clips` (and `no headroom granted · above 100 nits clips`). The HLG-only line below is
replaced. The code keeps it until the Reference fix (§6) lands; it changes in that change. The As macOS Shows It line (§3.2
item 9) stays as approved.

**As approved** (Robbie, 2026-10-30), HLG only:

```
display in SDR mode · highlights above reference white (HLG 75 %) clip
no headroom granted · highlights above reference white (HLG 75 %) clip
```

It goes in the verdict slot (`DisplayChainModel.swift`, THE VERDICT). It shows for an HLG picture in Reference, or in As macOS
Shows It without the adjustment, when the granted headroom is 1.0 (`!EDRHeadroom.isGranted`, i.e. `current ≤ 1.0001`).
**Current** is the key, because that is what clips. The first wording is used when `potential` is also ≤ 1.0001
(`isSDRMode`), the second otherwise, so the line never collapses the two (`HeadroomReadout.swift:45-48`). Not shown in Bypass,
which converts nothing. With headroom above 1, no clip line is shown.

The first draft is kept for the record. It was `HLG (tagged) → BT.2408, no tone-map → display in SDR mode · everything above
HLG 75 % clips to white`, and a PQ twin (`… above 203 nits …`). The PQ line is deferred with §5.

---

## 5. PQ, report only: is `CAEDRMetadata.hdr10` the equivalent for macOS mode?

**DEFERRED (Robbie, 2026-10-30).** This round changes HLG only; PQ is untouched in every mode. **Open question before any PQ
work:** the header defines HDR10 metadata as *"1.0 mapping to diffuse white of 100 nits"* (`CAEDRMetadata.h:28-31`), but today
macOS puts PQ 203 nits at 1.0 (findings table 2). Setting `hdr10` may re-anchor reference white about 2× brighter. Measure that
first.

**Structurally yes. Numerically unknown. And PQ differs from HLG in a way that matters.**

- **The API fits.** `hdr10(displayInfo:contentInfo:opticalOutputScale:)` takes the SEI MDCV (24 bytes) and CLLI (4 bytes),
  big-endian (`CAEDRMetadata.h:33-57`). `hdr10(minLuminance:maxLuminance:opticalOutputScale:)` takes the mastering min and max
  nits (`:59-83`). Both say content *"may be tone mapped to match the current display"* once set (`CAMetalLayer.h:133-134`).
- **The data is already in the renderer.** `sourceHDR10: HDR10StaticMetadata?` (`MetalVideoRenderer.swift:1387-1390`) holds
  **parsed** values, not raw SEI bytes (`HDR10Metadata.swift:156-170`). Files get them from libav side data (`:339`, `:379`),
  SRT from SEI (`SRTFrameRouter.swift:1155`), and the rest get nil. The 24-byte form would have to be re-encoded (0.00002 units
  for the primaries, 0.0001 cd/m² for luminance). The min/max initializer needs no encoding. When nothing is declared,
  `displayInfo`/`contentInfo` nil means *"uses system defaults"* (`CAEDRMetadata.h:37,41`). A LUT-stated PQ output must pass nil
  for the source's metadata, as `OutputSignal` already does (`MetalVideoRenderer.swift:1946-1950`).
- **UNKNOWN 1, the anchor.** The header says HDR10 data is *"display referred with 1.0 mapping to diffuse white of 100 nits"*
  (`CAEDRMetadata.h:28-31`). ColorSync anchors PQ 203 nits at 1.0 (findings table 2). Whether setting `hdr10` re-anchors the
  picture (PQ 100 nits → 1.0, about 2× brighter at reference white) is not stated.
- **UNKNOWN 2, `opticalOutputScale`.** It is defined for *linear* extended-range values, and *"if the content … is in a
  normalized pixel format then scale is assumed to be 10,000"* (`:43-52`). Manifold's drawable is `rgba16Float` (not
  normalized) holding **PQ-encoded** values under `ITUR_2100_PQ` (`:200-240`, findings §1). Which scale applies to that
  combination is not stated.
- **The real difference from HLG.** PQ is display-referred. A correct HDR10 mapping need only compress what is above the
  display's ceiling and leave the levels below it alone. HLG's OOTF moves every level. So for PQ, "macOS mode with `hdr10`" would
  differ from Reference only above the ceiling, unless Apple's mapper also moves mid-tones. Whether it does is unmeasured. On a
  headroom-1.0 display the ceiling is 203 nits, so the difference covers most of a graded HDR picture's highlights.
- **The same decision cost as HLG**, reasons 1 and 3, for PQ in OS mode.
- **If pursued:** the same `PendingColorState` fields, with `.os` + transfer 16 → `hdr10(...)`, and the same T0–T8 matrix with
  a PQ ramp (anchor check: 100 and 203 nits). Not part of Option B as stated.

---

## 6. Reference HLG fix — BT.2408 HLG → PQ transcode in the shader (plan, no code; 2026-10-30)

**Governing definition** (Robbie, 2026-10-30; `COLOR_MANAGEMENT_FINDINGS.md` §6.11, end): Reference is absolute display light,
1.0 = 100 nits. PQ maps directly. HLG is transcoded to PQ per BT.2408 at a 1000-nit nominal peak. This is the 0.9.1 bug fix for
Reference HLG (`BUGS.md`, OPEN 2026-10-30). The "÷ 203 into a linear extended layer" route is **withdrawn**.

### 6.1 What changes, in one sentence

For an HLG **picture** in Reference, the display stage's shader converts the offscreen's HLG-encoded R′G′B′ to PQ-encoded R′G′B′
(inverse OETF → OOTF γ 1.2 at Lw 1000 → PQ inverse EOTF), and the layer is tagged with the PQ colorspace of the same primaries,
exactly as a PQ source is. On screen Reference HLG then renders through the same CA path a PQ file does, which is measured
(§3.6b) and, under the definition, correct.

### 6.2 The maths (BT.2100 HLG reference OOTF; BT.2408 transcode, Lw 1000, Lb 0)

Per pixel, on the display stage only:

1. **Inverse OETF**, per channel, on E′ clamped to ≥ 0: `E = E′²/3` for E′ ≤ ½, else `E = (exp((E′ − c)/a) + b)/12`, with
   a = 0.17883277, b = 0.28466892, c = 0.55991073. Scene-linear, [0, 1] for legal signal; E′ above 1.0 (superwhite, codes 941–1019)
   continues the curve and is not clamped here.
2. **OOTF at Lw = 1000, γ = 1.2:** `Ys = kR·R + kG·G + kB·B` (the luminance weights of the **picture primaries**; BT.2020's
   0.2627 / 0.6780 / 0.0593 for primaries 9), then `F = 1000 · Ys^(γ − 1) · E` per channel, in cd/m². This is applied on
   luminance, so hue is preserved (BT.2100 form, not per-channel). With Ys = 0, F = 0 (guard the `pow`).
3. **PQ inverse EOTF** of `F / 10000` per channel, clamped to [0, 1].

Checked numerically (neutral, so Ys = E):

| HLG E′ | scene E | nits | PQ E′ | × SDR white (1.0 = 100 nits) |
|---|---|---|---|---|
| 0.5000 | 0.0833 | 50.7 | 0.4416 | 0.51 |
| **0.6296** | 0.1468 | **100.0** | 0.5081 | **1.00**: clip point at headroom 1.0 |
| **0.7500** | 0.2650 | **203.2** | **0.5808** | 2.03 (BT.2408 reference white) |
| 0.9000 | 0.5818 | 522.1 | 0.6813 | 5.22 |
| 1.0000 | 1.0000 | 1000.0 | 0.7518 | 10.00 |

**Expected on screen after the fix:** HLG 75 % = 203 nits. At headroom 1.0, clipping starts at HLG ≈ 63 % (E′ 0.6296 = 100
nits), the point where a PQ file clips. Below that, the HLG ramp should match the PQ ramp at equal nits (§3.6b's measured PQ row).

### 6.3 Where it goes

- **Shader** (`PassthroughShader.metal`, `displayReferenceFragment`, now mode 0 / else-mode-1 at `:530-538`): add **mode 2 = HLG →
  PQ**. ⚠️ The current `else` treats every non-zero mode as mode 1, so the branch must test `mode == 1` explicitly and add
  `mode == 2`. `ReferenceParams` (80 bytes, matched by `ReferenceShaderParams`, `ReferencePlan.swift:33-43`) has room: kR/kG/kB
  in `row0.xyz`, Lw in `a`, γ in `b`. Keep the struct size and field order; document the mode-2 meanings in both places.
  Output stays `half4`; PQ E′ ≤ 1 fits.
- **The transcode as a pure function** in `ColorimetryModel` (`HLGToPQ`: E′ → nits → PQ E′, plus the luminance weights from
  `ColorimetryTable`), with unit tests pinning the table in §6.2. The shader mirrors it. The test is the arbiter, the same
  pattern as BT.1886.
- **`ReferencePlan.make`** (HLG arm, `ReferencePlan.swift`): return `layerColorSpace` = the **PQ** colorspace of the picture
  primaries, and `shader` = mode-2 params. `make` cannot build a colorspace from codes itself, so the renderer passes it in
  (`MetalVideoRenderer.makeColorSpace(primaries: picturePrimaries, transfer: 16, matrix: pictureMatrix)`, the same constructor
  every PQ source's layer comes from). This goes in a new `pqColorSpace:` argument used only by the HLG arm. Summary:
  `Reference — HLG transcoded to PQ (BT.2408, 1000 nits); absolute, 1.0 = 100 nits`. Log line:
  `[REFERENCE] HLG source on "…": BT.2408 HLG → PQ, Lw 1000, γ 1.2, layer tagged PQ`.
- **Before calibration:** the HLG arm stays ahead of the calibrated-display branch, as PQ's does. Display calibration is an SDR
  BT.1886 concept and does not apply to HDR.
- **`publishColorState`**: no structural change. Reference already installs `plan.layerColorSpace` and `plan.shader` together in
  one `PendingColorState` (`MetalVideoRenderer.swift`, the `.reference` arm). `wantsEDR` is already true for picture transfer
  18. `edrMetadata` stays nil and `toneMapMode` stays `.never` in Reference (§3.1), which is right: the layer is now PQ, the
  measured PQ path.
- **`logLayerState`'s Reference line** reports `ITUR_2100_PQ … — REFERENCE, HLG → PQ shader` from the plan, never the source's
  name, per its own rule (report what reaches the layer).

### 6.4 The cases

- **SDR-mode display (headroom 1.0):** PQ-tagged, no tone-map. Everything above 100 nits clips: HLG ≥ 63 %. That is the definition
  working, and it is identical to a PQ file. Readout (lands with this change, PQ and HLG alike): `display in SDR mode · above 100
  nits clips`.
- **HDR mode (headroom h > 1):** shows up to 100·h nits, and clips above, per the 2026-08-28 decision (no tone-map, `.never`). For
  example, at h = 4.48 everything up to 448 nits shows, which is HLG ≈ 88 %. HLG 100 % (1000 nits) is shown only at h ≥ 10. Above
  the granted headroom it clips; it is never rolled off. With headroom granted, the clip line is not shown (it keys on
  `!isGranted`); the Headroom row states the figures.
- **`no headroom granted`** (HDR mode, potential > 1, current 1.0): the same clip as SDR mode, with the variant wording.
- **LUT stated as HLG:** the plan keys on **picture** codes (CLAUDE.md, colour codes rule), so a LUT whose stated output is HLG
  gets the transcode on the LUT's output. The LUT runs in the offscreen pass, upstream of the display stage, so the order is right.
  A LUT stated as PQ takes the PQ arm unchanged. An HLG source under a LUT stated as Rec.709 takes the SDR arms. "Same as Source"
  on an HLG source is HLG.
- **HLG with non-2020 primaries** (e.g. CICP 1-18-1): the luminance weights come from the picture primaries, and the PQ layer
  colorspace from the same primaries. `makeColorSpace` already has a fallback for PQ with primaries CoreVideo cannot express
  (`ColorimetryTable.swift:333`). If it takes that fallback, the plan must refuse (show as OS, say so), as Reference already
  does for a non-power-law SDR profile. It must never guess.
- **Superwhite** (E′ > 1): passes through steps 1–2 and clamps at PQ 1.0 (10 000 nits). It is invisible below headroom 100 anyway.
- **As macOS Shows It and Bypass:** unchanged. macOS mode keeps the HLG colorspace with `.ifSupported` + `.hlg` (§3). Bypass gets
  nil. **Hold C** swaps HLG-tagged + identity ↔ PQ-tagged + mode-2 shader in one `PendingColorState` install, so there is no torn
  frame. T6 runs after this lands.

### 6.5 Scopes, SDI, HDMI, export: unaffected (confirmed by structure; verify by bytes)

The transcode lives in the **display stage** only. That is the render pass that reads the offscreen and writes the drawable
(`MetalVideoRenderer.swift`, the Reference branch right after `nextDrawable()`). Every other consumer reads the offscreen ring
upstream of it: the scopes (`offscreenTexture`), the DeckLink v210 convert for SDI and HDMI (`readableOffscreen()`), the frame
export, and the v210 dump. The output signal, the SDI tag, the v210 matrix and the export ICC come from the picture codes, which
stay HLG. So the scopes show the file's HLG code values, and SDI carries HLG. Verification: the v210-dump FNV-1a and the export
bytes are identical in OS, Reference and Bypass, before and after (T7).

**One readout consequence:** in Reference the picture is now PQ-tagged while the scopes' headers still say HLG (picture codes).
That is correct, because the scopes describe the file, but the chain readout's Transform line must say "transcoded to PQ" so the
two do not look contradictory.

### 6.6 Verification (when built)

- **ASUS, headroom 1.0:** the HLG ramp in Reference against the PQ ramp in Reference (§3.6b). At matched nits the bars should agree
  within ±2. HLG bars ≥ 65 % should be 255; the 60 % bar (≈ 85 nits) just under. Then HLG 75 % = 255 (clipped, 203 nits) and the
  PQ 203-nit bar = 255.
- **LG, HDR on:** by eye, Reference HLG against a PQ transcode of the same clip made offline (ffmpeg `zscale`, BT.2408, 1000 nits),
  both in Reference.
- **T6** (Hold C latency, no torn frame), **T7** (v210 / export bytes identical), **T8** (PQ and SDR unchanged).
- Unit tests for `HLGToPQ` (table in §6.2) and for the plan's HLG arm (PQ colorspace, mode 2, the refusal case).

### 6.7 Implemented and verified on the ASUS, 2026-10-30 (uncommitted)

**Code:** `HLGToPQ` in `ColorimetryModel/ReferenceTransform.swift`, with 7 tests in `HLGToPQTests.swift` (all pass): the §6.2
table, 75 % within 0.5 nit of 203, 100 nits between 62.9 % and 63.0 %, channel ratios kept, black and bounds, and the refusal for
primaries a PQ layer cannot be tagged with. Shader mode 2 has an explicit branch, with mode 1 now tested explicitly.
`ReferencePlan`'s HLG arm takes a `pqColorSpace` built by `makeColorSpace(…, transfer: 16, …)`. The Transform line reads `Reference — HLG transcoded
to PQ (BT.2408, 1000 nits); absolute, 1.0 = 100 nits`. The Reference readout reads `display in SDR mode · above 100 nits clips`
(PQ and HLG; the `no headroom granted` variant kept). Both DEBUG switches are removed: macOS-mode HLG is hardwired to `.hlg` +
`.ifSupported`, everything else to nil + `.never`.

**Verified** (fixed build, ASUS, headroom 1.0, HLG ramp; Reference set by a Color-menu AX click; capture deleted; log `r2.log`):

| HLG % | 0 | 5 | 10 | 15 | 20 | 25 | 30 | 35 | 40 | 45 | **50** | 55 | **60** | **65** | 70 | **75** | 80–100 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| nits (§6.2) | 0 | 0.4 | 1 | 3 | 6 | 10 | 15 | 21 | 30 | 39 | **51** | 65 | **85** | **112** | 150 | **203** | 275–1000 |
| predicted | 0 | 6 | 26 | 47 | 67 | 87 | 107 | 128 | 148 | 168 | 189 | 210 | 237 | 255 | 255 | 255 | 255 |
| **measured, Reference** | 0 | 5 | 26 | 46 | 67 | 86 | 107 | 128 | 147 | 169 | **188** | 211 | **236** | **255** | 255 | **255** | 255 |

The predictor (nits ÷ 100 in extended linear Rec.2020, clipped at 1.0, converted to the ASUS profile) reproduces the measured PQ
ramp of §3.6b exactly, bar for bar. Results: **within ±1 at every bar.** **HLG 50 % (51 nits) = 188 = the PQ ramp's 50-nit
bar.** **Clipping starts between 60 % (85 nits) and 65 % (112 nits)**, i.e. at ≈ 63 %. **HLG 75 % = 255 = the PQ 203-nit bar**. At
headroom 1.0 both are clipped, so that equality holds trivially; the 50 % match is the informative one. Log: `[REFERENCE] HLG
source on "ASUS PA147": BT.2408 HLG → PQ, Lw 1000, γ 1.2, layer tagged PQ`, read-back `nil · never`, verdict `display in SDR
mode · above 100 nits clips`. As macOS Shows It in the same run = T3.

Not yet done: the LG in HDR mode for Reference, T6 (Hold C), T7 (v210 / export bytes), T8 (PQ and SDR unchanged). Gap found: a
display-transform change does not re-print the `[EDR] layer colorspace` line, so the PQ tag is shown by the curve (an HLG-tagged
layer measures as T0) and the `[REFERENCE]` line, not by a layer read-back.

### 6.8 Reference on the LG (HDR) and T6, 2026-10-30 (final build; log `lg-t6.log`)

**Reference on the LG, HDR on, by eye (Robbie):** `IMG_5070_noDV.mov` is "somewhat clippy, as expected for the headroom". **On
the HLG ramp every bar is distinguishable in both modes, including 90–100 % in Reference.** Log: both windows switched to
`[REFERENCE] HLG source on "LG TV SSCR2": BT.2408 HLG → PQ, Lw 1000, γ 1.2, layer tagged PQ`, read-back `nil · never`. **Granted
headroom: 4.4827 of potential 8.9654, unchanged for the whole session.** It is sampled every 0.5 s and on every screen or window
event, and logged on any change visible at two decimals. None was logged while the ramp was on screen.

**⚠️ Open, not explained.** At 1.0 = 100 nits and current 4.48, the composite should clip above ≈ 448 nits (HLG ≈ 88 %), so the
90 / 95 / 100 % bars (522 / 720 / 1000 nits) should be identical. They were distinguishable. The TV cannot restore a clip made
before the signal leaves the Mac. Candidates (not tested): (1) the compositor's ceiling for this layer is above `NSScreen`'s
`maximumExtendedDynamicRangeColorComponentValue` (at the potential 8.97 the ceiling would be ≈ 897 nits, and every bar would
differ); (2) values above headroom are rolled off rather than clipped despite `.never`. A window-only capture of the ramp in
Reference on the LG, read for pixel values only, would decide it. Not done: needs Robbie's decision under the display rules.

**T6 (Hold C on `IMG_5070_noDV.mov`, LG, chosen mode Reference): passed.** 18 holds and 18 releases, strictly alternating.
Every hold logged `display transform → OS`, read-back `EDRMetadata set · toneMapMode ifSupported`, and the macOS verdict. Every
release logged `display transform → REFERENCE`, the `[REFERENCE] … HLG → PQ` line, read-back `nil · never`, and verdict none
(headroom granted, so no clip line). No stale state. Key → glass 12.7–32.6 ms, median 18.6 (n = 22, 120 Hz); 13 frames reported
no presented time. The `⚠️ AFTER a frame was already on screen` line on each switch is the first-frame check counting presents
since the source loaded. That is expected for a mode change and repaired by the re-present: misleading wording, not a defect.

### 6.9 T7 and T8 against build 21, 2026-10-30

**Build 21 for comparison:** commit `53b4bee` (0.9.0, build 21) exported with `git archive` into `.build-b21/src` (gitignored),
with the gitignored vendored libraries copied and the DeckLink SDK symlinked. Built Profile and launched with that tree's own
`scripts/run.sh`. The installed app was never run. `7e0da82` (HEAD before this change) differs from `53b4bee` in docs only.

**T7: SDI/HDMI and export bytes, HLG: unchanged.** `MANIFOLD_DEBUG_MENU=1`, then Debug ▸ Chroma Scrub Bench in each mode, which
gives two diagnostic exports (playback, scrub): offscreen `.rgba16f`, SDI `.v210` and `.png`. Files were the HLG ramp and
`IMG_5070_noDV.mov`. **SHA-256 of `.rgba16f`, `.v210` and `.png` identical across final build × build 21 × OS / Reference / Bypass ×
playback / scrub, for both files** (ramp: rgba16f `1204372d5d…`, v210 `31b9ee92da…`; IMG_5070: rgba16f `a61fa20eb2…`, v210
`5d256ab665…`). The v210 parameters are identical (BT.2020 kr/kb, 4:2:2), and so is the signal tag (`[DeckLink] signal → HLG ·
Rec. 2020`). ⚠️ The bench writes to the export-folder preference (here ~/Desktop), not `MANIFOLD_FRAME_EXPORT_DIR`, which only
applies to Export Frame for Support. The 96 files were moved from the Desktop to the session scratchpad by the names in the run
logs; none were left.

**T8: PQ and SDR, all three modes, ASUS: unchanged.** Window-only captures, deleted after recording.

| | OS | Reference | Bypass |
|---|---|---|---|
| PQ ramp (14 bars), final = build 21 | `0 25 89 188 255 …` | `0 25 89 188 255 …` | `0 38 77 113 129 141 149 158 167 178 192 211 231 255` |
| SDR ramp (21 bars, 1-1-1), final = build 21 | `0 9 27 42 58 72 86 101 112 127 138 152 162 176 186 198 209 221 232 243 254` | `0 4 13 25 40 52 66 81 93 108 120 134 147 161 174 187 200 214 227 241 254` | `0 12 25 37 51 63 76 90 101 115 127 141 152 166 178 191 203 216 229 242 254` |

Every bar is identical between builds in every mode. The layer state is identical (PQ `ITUR_2100_PQ`, SDR `CoreMedia709`; the same
`[REFERENCE]` plans). The only differences are intended: PQ in Reference now shows `display in SDR mode · above 100 nits clips`,
and the new build logs `[CHAIN] Verdict` and layer read-back lines.
