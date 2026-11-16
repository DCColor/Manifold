# Scopes for 0.9.5: YRGB parade, graticule and trace visibility

Read-only audit, 2026-11-16, at `3f05914` (working tree: only `docs/CARD_PULL_MARGIN.md` modified, unrelated). Nothing
was built, launched or changed. Every claim is marked **CONFIRMED** (file:line) or **UNKNOWN**. Paths are relative to
the repo root.

Two pieces of work:

1. **YRGB parade**: a new scope type with four columns, Y | R | G | B. The RGB parade and the Y waveform both stay.
2. **Graticule and trace visibility**: the vectorscope first, then every scope.

---

## Part 1: YRGB parade

### 1.1 How the RGB parade and Y waveform work today

The pipeline is the same for both. A scope model asks the renderer for a GPU histogram of the frame. The renderer runs
a compute kernel over the readable offscreen texture and reads back only that histogram. `ScopeTrace`, a CPU module
compiled with `-O`, turns the histogram into an RGBA image. SwiftUI then draws that image under a `Canvas` graticule.

| Stage | Y waveform | RGB parade |
|---|---|---|
| Texture read | `scopeTexture` = still frame or offscreen (`MetalVideoRenderer.swift:4939`). The offscreen is **rgba16Float** (`MetalVideoRenderer.swift:242`); the kernel comments that say "rgb10a2" are stale (`PassthroughShader.metal:613-621`, `:658-660`) | same texture |
| Params | `WaveformParams {width,height,scopeW,bins,rowStride,kr,kb}` (`PassthroughShader.metal:602-610`) | `ParadeParams {width,height,colW,bins,rowStride}`, with no matrix (`PassthroughShader.metal:650-656`) |
| Kernel | `waveformKernel` (`PassthroughShader.metal:622-645`): `kg = 1-kr-kb`, `luma = kr*r + kg*g + kb*b` (`:635-636`), `bin = clamp(int(luma*(bins-1)+0.5))` (`:638-639`), `bucket = gid.x*scopeW/width` (`:641`), `row = bins-1-bin` (`:642`), 1 atomic per pixel | `paradeKernel` (`PassthroughShader.metal:663-685`): the same rounding for each channel (`:676-678`), 3 atomics per pixel into one buffer laid out as `[R\|G\|B]`, each region `colW*bins` (`:682-684`) |
| Dispatch | `computeWaveformGPU` (`MetalVideoRenderer.swift:4974-4997`) → `dispatchScopeKernel` (`:4854-4898`): blit-zero, 16×16 threadgroups, its own `scopeCommandQueue`, shared-storage readback | `computeParadeGPU` (`MetalVideoRenderer.swift:5002-5022`), same dispatch |
| Buffer | `histogramBuffer` (`MetalVideoRenderer.swift:421`), reused; each model allows one compute in flight | `paradeHistogramBuffer` (`:423`) |
| Histogram size | `scopeW × 1024` (`WaveformScope.swift:576`). `scopeW` is the slot width snapped to 64 and clamped to 256–1024 (`WaveformScope.swift:569-583`, `:38-41`) | `3 × colW × 1024`. `colW` is slot/3 snapped and clamped to 128–512 (`ParadeScope.swift:38-51`, `:44`) |
| Row stride | 1 (full resolution) (`WaveformScope.swift:627`) | 1 (`ParadeScope.swift:72`) |
| Trace build | `ScopeTrace.waveformPixels` (`ScopeCompute.swift:47-78`): sums 1024 rows down to 512 display rows (`WaveformScope.swift:77`), takes the frame's own max, builds a count→brightness LUT, multiplies by the trace color, alpha 255 | `ScopeTrace.paradePixels` (`ScopeCompute.swift:84-132`): the same downsample per channel, **one max shared across R, G and B** (`:101-104`), pure R/G/B or mono-tinted (`:120-128`), alpha 255 |
| Brightness | `brightness = pow(min(count/max·gain,1),1.25)`, set to 0 below 0.008 (`ScopeCompute.swift:20-32`). Gain = `baseGain 2.0` × per-scope intensity × global intensity (`WaveformScope.swift:69`, `:694-696`) | same curve; gain = `baseGain` × `paradeIntensity` × global (`ParadeScope.swift:135-137`) |
| Trace color | `waveformTraceColor`, default `00FF00` (`Preferences.swift:150`, `:152`) | R/G/B, or `paradeMonoColor` (default `FFFFFF`) when `paradeMonochrome` is on (`Preferences.swift:167-168`) |
| Image | CGImage, DeviceRGB, premultipliedLast, `scopeW × 512` (`WaveformScope.swift:750-756`) | `3·colW × 512` (`ParadeScope.swift:187-193`) |
| Draw | ZStack: `Color.black` → trace image (`.interpolation(.none)`, inset by the gutters) → graticule `KeyedCanvas` (`WaveformScope.swift:852-872`) | same (`ParadeScope.swift:283-296`), plus column separators at 1/3 and 2/3 (`ParadeScope.swift:318-327`) |
| Scale and graticule | `drawActiveValueGraticule` (`WaveformScope.swift:1085-1099`): SDR 8-bit, 10-bit or IRE (`:900-928`), PQ nits (`:981-995`), HLG %+nits (`:1002-1024`), then user lines (`:1113-1136`). The ruler follows `scopeScale` (default `.bit10`) and the shared `manifold.scope.verticalScale` (`WaveformScope.swift:767-769`) | the same function and keys (`ParadeScope.swift:204-206`, `:316-317`) |
| Header | `"WAVEFORM" · luma <matrix> (<scale>)` (`WaveformScope.swift:818-822`) | `"PARADE" · RGB (<scale>)` (`ParadeScope.swift:250-253`) |
| Re-sample on pref change | `sampleInputs` = intensity, global, color, columns, **`renderer.pictureMatrixCode`** (`WaveformScope.swift:617-620`) | intensity, global, mono, mono color, colW. No matrix, because the kernel takes none (`ParadeScope.swift:65-68`) |

### 1.2 How the waveform's luma follows the picture codes

- **Math (CONFIRMED).** `computeWaveformGPU` reads `scopeCodes.matrix` (`MetalVideoRenderer.swift:4982`).
  `scopeCodes` is the still's own codes while a still is held, otherwise `pictureMatrixCode`
  (`MetalVideoRenderer.swift:4942-4945`). `ycbcrKrKb` maps the code through `YCbCrMatrix(cicp:)`: 709 for
  nil/2/unknown, 2020 for 9, 601 for 5/6 (`MetalVideoRenderer.swift:184-195`). Picture codes equal the source codes
  unless a LUT states its output (CLAUDE.md, renderer rule).
- **Header (CONFIRMED).** `ScopeColorFeed.refresh` is the only writer of `waveform.sourceMatrixCode`,
  `sourceTransferCode` and `headerNote`. It takes them from the renderer's picture codes, from a still's codes, or
  from the cleared source codes when nothing is loaded (`ScopeColorFeed.swift:121-142`). The header label is
  `ycbcrMatrixLabel(model.sourceMatrixCode)` (`WaveformScope.swift:819`), built from the same `YCbCrMatrix` table
  (`WaveformScope.swift:51-53`).
- **Paused re-weighting (CONFIRMED).** The model re-samples when `pictureMatrixCode` changes, because the code is in
  `sampleInputs` (`WaveformScope.swift:619`, `:645-648`).

**What YRGB must do so its Y is the waveform's Y.** It must read the same `scopeCodes.matrix` through the same
`ycbcrKrKb`, bin with the same expression and rounding, and include `renderer?.pictureMatrixCode` in its own
`sampleInputs`. The parade's `sampleInputs` leaves the matrix out (`ParadeScope.swift:65-68`), so it is the wrong
template to copy here. Its header fields must be written by `ScopeColorFeed` and nothing else (CLAUDE.md rule).

### 1.3 What "pixel for pixel" can mean

- **The histogram can be identical** if Y is binned at the same `scopeW`. That is guaranteed by construction if YRGB
  calls `waveformKernel` itself (option A below).
- **The trace image can be identical** when the column count, gain and color match. The two scopes normalize
  differently: the waveform uses the Y histogram's own max (`ScopeCompute.swift:64-66`), and the parade uses a max
  shared across channels (`ScopeCompute.swift:101-104`). If YRGB put Y under the R/G/B shared max, Y would differ in
  brightness from the standalone waveform. **Proposal:** Y keeps its own max and R/G/B keep their shared max.
  `yrgbPixels` should be built by calling `waveformPixels` and `paradePixels` and interleaving their rows, not by
  copying their code.
- **On screen the two will not match pixel for pixel** in a normal tray. A waveform slot computes 256–1024 columns. A
  YRGB Y column in a slot of the same width gets about a quarter of that. They are the same measurement at different
  horizontal resolution. The plan should promise identity at equal `colW`, and the tests below prove it at that level.

### 1.4 What it takes to add YRGB

**Compute. Option A is recommended: reuse both kernels in one command buffer.**

- Add `computeYRGBGPU(colW:bins:rowStride:)`. It encodes `waveformKernel` with `scopeW = colW` and the `scopeCodes`
  Kr/Kb, then `paradeKernel` with the same `colW`. Both go into one command buffer with one completion that returns
  `(y, rgb)`.
- `dispatchScopeKernel` takes one pipeline (`MetalVideoRenderer.swift:4854-4860`). It needs either a two-dispatch
  variant or a small refactor so it takes a list of `(pipeline, buffer, count, params)`.
- Use **two new buffers**, for example `yrgbLumaBuffer` and `yrgbRGBBuffer`. Do not reuse `histogramBuffer` or
  `paradeHistogramBuffer`. Each model allows only its own compute in flight (`MetalVideoRenderer.swift:4850-4852`),
  so a waveform or parade in another slot would tear a shared buffer.
- Y is bit-identical because it runs the waveform's own kernel and rounding. No shader changes are needed.

**Option B: a fused `yrgbKernel`** that reads the texture once and does four atomics. It saves one texture read per
update. Identity then depends on the luma and bin expressions being written once. They would need moving into shared
`inline` MSL helpers called by all three kernels, so `waveformKernel` and `paradeKernel` would be edited too. FMA
contraction differences between kernels are a theoretical risk the helpers remove. Option B is only worth doing if
measurement shows the second pass matters (§1.5).

**Model, view and drawing** (new file `App/YRGBScope.swift`, modeled on `ParadeScope.swift`):

- `YRGBScopeModel` holds `trace`, `sourceMatrixCode`, `sourceTransferCode` and `headerNote`, all `@Published` and
  written only by the feed.
- Sampling is coupled to render and to preferences, with one compute in flight and `clear()`, exactly as the parade
  does (`ParadeScope.swift:54-167`).
- `colW` = slot/4, snapped, clamped to 128–512. At 4 × 128 that is still ≥ 512 total columns.
- `sampleInputs` = yrgb intensity, global intensity, the mono flag and color, `colW`, and
  `renderer?.pictureMatrixCode`.
- Add `ScopeTrace.yrgbPixels(y:r:g:b:colW:bins:displayRows:gain:yColor:mono:monoColor)` in `ScopeCompute.swift`. It
  calls `waveformPixels(…, scopeW: colW)` and `paradePixels(…)` and places them in columns 0 | 1–3, giving an image
  `4·colW × 512`.
- The view copies `ParadeScopeView`: `ScopeSlotHeader`, `ScopeValueAxisGear`, the intensity slider, mono color and
  reset, the gutters, and `drawActiveValueGraticule`. Separators go at 1/4, 2/4 and 3/4 instead of 1/3 and 2/3
  (`ParadeScope.swift:321`).
- User lines get their own keys, `manifold.yrgb.line1.enabled/position` and `.line2.*`, following
  `ParadeScope.swift:217-220`.
- The vertical scale shares the `manifold.scope.verticalScale` key, which is the point of that key
  (`WaveformScope.swift:1343-1349`).
- **Y trace color is a decision for you.** Resolve's default Y color in its YRGB parade is **UNKNOWN** (not checked
  here). Proposal: Y in neutral gray-white (`E6E6E6`), so it does not read as a fourth color channel. In mono mode all
  four columns take the mono color, as the parade does.
- **Intensity:** proposal is a new `yrgbIntensity` (default 1.0) next to the others (`Preferences.swift:91-94`), with a
  binding like `paradeIntensityBinding` (`:125-127`).

**Where `ScopeKind` must be added and wired**:

- `ScopeKind`: add `case yrgb` after `parade`, with display name "YRGB Parade" (`ContentView.swift:23-37`). Raw value
  `"yrgb"`. An older build that reads `"yrgb"` falls back to its default kind (`WindowChrome.swift:237-239`), so a
  downgrade is safe.
- Slot picker menu: no change needed. It lists `ScopeKind.allCases` (`ContentView.swift:58-60`).
- `ScopeModelStore`: add `let yrgb = YRGBScopeModel()` (`ContentView.swift:289-295`), plus an accessor beside
  `ContentView.swift:472-476`.
- `slotView`: add `case .yrgb` (`ContentView.swift:1525-1534`).
- `updateScopeSampling`: start and stop it (`ContentView.swift:1549-1576`) and add it to the `onFrameRendered`
  fan-out (`:1682-1691`).
- `clearScopes` (`ContentView.swift:1699-1704`), the teardown `stop()` list (`ContentView.swift:751-755`) and the bind
  call (`ContentView.swift:714-715`).
- `ScopeColorFeed`: add a `yrgb` weak reference, a `bind` parameter, the `clear()` on release
  (`ScopeColorFeed.swift:94-97`), and writes of `sourceMatrixCode`, `sourceTransferCode` and `headerNote`
  (`:135-142`).
- `ScopePerf`: give its counters and dump the name `"yrgb"` (`ScopePerf.swift:47`).

**Shortcuts (ShortcutRegistry).**

- Today no shortcut chooses a scope kind. The Scopes category has the tray toggle and CIE and vectorscope overlay
  toggles only (`ShortcutCatalog.swift:320-327`). YRGB needs no shortcut to be complete.
- If one is wanted, the natural action is **"Parade: Switch RGB / YRGB"** (`scopes.yrgbParade`, `.window`). It swaps
  every slot in the key window holding `.parade` ↔ `.yrgb`. It would be wired like `.vectorscopeGraticule`
  (`ContentView.swift:1791-1793`), and the catalog tests cover the new row.
- **Default key: none for now.** The candidate is **⌥⌘Y**:
  - It is free in the catalog: nothing uses the Y key (`ShortcutCatalog.swift:212-391`).
  - It is not in `ShortcutRegistry.reserved` (`ShortcutRegistry.swift:280-306`).
  - It is not in this Mac's `com.apple.symbolichotkeys`: no entry on key code 16, from a read-only check.
  - **Services key equivalents: UNKNOWN.** The catalog's own rule checks Services before taking a key
    (`ShortcutCatalog.swift:225-228`, `:283-284`).
  - Ship ⌥⌘Y only after that check passes. Otherwise ship with no default; the row can still be assigned by the user.

**Settings export and import of slot layouts.**

- Slot selections are **not exported today (CONFIRMED)**. The `.manifoldsettings` file has only the `shortcuts` and
  `streams` sections (`SettingsFile.swift:174-221`). Any other section is reported as `unknown` and skipped
  (`:205-208`).
- Slots are per-window state in `WindowChrome` under `manifold.scope.slot0/1/2` (`WindowChrome.swift:99-101`,
  `:152-154`). The export plan lists the look of scopes as "Out, next" (`docs/SETTINGS_EXPORT_PLAN.md:105`) and does
  not list slots at all.
- YRGB therefore needs **no export work in 0.9.5**. When a "preferences" section is built, its range check for slot
  values must accept `"yrgb"`. An older reader falls back through `ScopeKind(rawValue:) ?? default`.

**Scope headers.** `ScopeSlotHeader(name: "YRGB", suffix: valueScopeHeaderSuffix(lead: "Y \(ycbcrMatrixLabel(model.sourceMatrixCode)) · RGB", …, note: model.headerNote))`.
The matrix label then reads from the same feed-written field as the waveform's, and it changes with a LUT or override
exactly as the waveform's does.

### 1.5 Cost at 4K and 8K per update, against the RGB parade alone

No timing was measured; nothing was built or run. The only measurement on record is GPU utilization from
`IOAccelerator`: parade and vectorscope 13–27 %, waveform and CIE 2–4 %, at frame rates of 23.976 to 59.94
(`docs/BUGS.md:3350`). The clips' resolution is **UNKNOWN**. The parade's cost being 5–7× the waveform's with only
3× the atomics suggests contention on atomics dominates.

| Per update | Parade | YRGB, option A (two passes) | YRGB, option B (fused) |
|---|---|---|---|
| Texture reads, 4K UHD (8.29 Mpx × 8 B rgba16Float) | 66 MB | 133 MB | 66 MB |
| Texture reads, 8K (33.2 Mpx × 8 B) | 265 MB | 531 MB | 265 MB |
| Atomics, 4K / 8K | 24.9 M / 99.5 M | 33.2 M / 132.7 M (+33 %) | 33.2 M / 132.7 M (+33 %) |
| Readback (does not depend on resolution) | `3·colW·1024·4 B` = 6 MiB at colW 512 | `4·colW·1024·4 B`; in the **same slot width** colW is about ¾ of the parade's, so about the same total (6 MiB) | same as A |
| CPU trace build | `3·colW` columns × 512 rows | `4·colW` columns, about the same total for the same slot. Adds one extra max scan and a brightness LUT of length max+1 for Y (≤ ~86 k entries for a flat 8K frame) | same as A |

Estimate: YRGB costs about **parade + waveform ≈ 1.1–1.35 × the parade** in GPU time at either resolution. The CPU
cost is about the same as the parade's. Absolute milliseconds are **UNKNOWN**.

To measure, add `gpuStartTime`/`gpuEndTime` from the scope command buffer to `ScopePerf` (DEBUG only), then repeat
the BUGS.md method for parade alone, YRGB alone, and parade + YRGB, on 4K and 8K sources. With parade and YRGB in the
same tray, RGB is binned twice. That is accepted, because the user chose both.

### 1.6 Tests that prove the identities

There is no `ScopeComputeTests` target today (CONFIRMED: `Packages/ManifoldCore/Tests/` has none, and
`Package.swift:113-119` defines the target without tests). The Metal kernels live in the app's library
(`App/PassthroughShader.metal`), which `swift test` cannot reach.

1. **New `ScopeComputeTests` target** (leaf, `swift test`):
   - `yrgbPixels` column 0 is byte-equal to `waveformPixels(y, scopeW: colW, …)`. Check it over seeded random
     histograms, colW ∈ {128, 192, 512}, displayRows ∈ {512, 1024 (the no-downsample branch, `ScopeCompute.swift:52`)},
     gain ∈ {0.5, 2, 6}, and an all-zero histogram.
   - Columns 1–3 are byte-equal to `paradePixels(r,g,b, …)`, in color and in mono.
   - Y normalization is independent: scaling R/G/B counts ×10 does not change column 0.
2. **GPU histogram identity, DEBUG self-check:** `MANIFOLD_YRGB_SELFCHECK=1`. After each YRGB sample, it dispatches
   `waveformKernel` and `paradeKernel` at the same `colW` into scratch buffers and compares element by element. It logs
   `[YRGB-CHECK] y=equal rgb=equal` or the first mismatch. With option A this is a guard against later refactors; with
   option B it is the proof. Run it across a matrix change (load a 2020 file, then a 601 file, then a LUT that states
   2020) and a still.
3. **Header identity:** a feed unit test, or a `[SCOPE-COLOR]` log check, that the YRGB `sourceMatrixCode` equals the
   waveform's after `refresh` for still, LUT and no-source states. The feed is `@MainActor` app code, so this is a log
   check unless the feed's choice logic is moved into a package.
4. **Image-level check:** `MANIFOLD_SCOPE_DUMP_DIR` (`ScopePerf.swift:39-47`) dumps every published trace. With the
   self-check build, crop YRGB column 0 and compare it to a waveform dump taken at the same `colW`, which needs a
   DEBUG override forcing the waveform's columns.

---

## Part 2: Graticule and trace visibility

### 2.1 Why the graticule reads dim today (findings)

- **Both target displays run at 1×, not Retina** (read-only `system_profiler`). LG: 3840×2160, "UI Looks like"
  3840×2160. ASUS PA147: 1920×550, same at 1×.
  - Most lines are stroked at **0.5 pt**, which is 0.5 px on these displays. Core Graphics anti-aliases a half-pixel
    line to roughly half coverage, so a 0.22 line lands at about 0.11 effective. This is expected CG behavior; the
    exact on-screen values are **UNKNOWN** until measured on the ASUS.
  - Line y-positions are arbitrary fractions (e.g. `WaveformScope.swift:918`), so a line can also straddle two pixel
    rows at about half intensity each.
- **The graticule is drawn on top of the trace with ordinary source-over blending** in every scope
  (`WaveformScope.swift:852-871`, `ParadeScope.swift:283-295`, `VectorscopeScope.swift:497-504`,
  `CIEScope.swift:400-407`).
  - The trace image is fully opaque: alpha 255 even where it is black (`ScopeCompute.swift:75`, `:121-127`, `:231`).
  - So a graticule line washes into a bright trace, and a faint line is lost against it.
- **The vectorscope draws white structure over a white trace by default.** The trace defaults to `FFFFFF`
  (`Preferences.swift:151`), and every vectorscope graticule element is white
  (`VectorscopeScope.swift:574-743`).

### 2.2 Inventory: graticule elements

"Shared" means one of the constants at `WaveformScope.swift:82-93`: `graticuleMajorOpacity` 0.22,
`graticuleMinorOpacity` 0.10, `graticuleLabelFontSize` 11, `graticuleLabelOpacity` 0.6,
`graticuleLabelBackingOpacity` 0.45. Everything else is a hard-coded literal.

**Vectorscope** (`VectorscopeScope.swift`, plain `Canvas` at `:555-748`):

| Element | Color | Alpha | Width | Where | Source |
|---|---|---|---|---|---|
| Boundary circle (r = 0.46·side) | white | 0.14 | 0.5 | `:571-574` (`graticuleCircleFrac` `:156`) | literal |
| Outer ticks, minor every 5° (opt-in, `outerTicks`) | white | 0.42 | 0.5, 4 pt long | `:579-591` | literal |
| Outer ticks, major every 45° | white | 0.58 | 0.5, 8 pt long | `:592` | literal |
| Center crosshair ±6 pt | white | 0.20 | 0.5 | `:596-599` | literal |
| Skin-tone axis 123° (opt-in) | white | 0.50 | 1.0 | `:606-633` | literal, matched to the brackets on purpose (`:625-627`) |
| 75 % / 100 % target brackets (9 pt frame, 0.36 arm) | white | 0.50 | 0.75 | `:642-669` | literal |
| Target hue labels (R, Mg, B…) | white | 0.55 | 8 pt mono text, no backing | `:670-676` | literal |
| User target keyline | white | 0.35 | 0.5 | `:734-735` | literal |
| User target ring (11 pt) | the entered color | 1.0 | 1.5 | `:736-738` | literal |
| User target numeral | white | 0.55 | 8 pt mono | `:741-745` | literal |

**Waveform, parade (and YRGB)** (`WaveformScope.swift`, `KeyedCanvas`):

| Element | Color | Alpha | Width | Where | Source |
|---|---|---|---|---|---|
| SDR minor ticks (6 pt at both plot edges) | white | 0.10 | 0.5 | `:908-914` | shared minor |
| SDR major lines | white | 0.22 | 0.5 | `:917-921` | shared major |
| SDR / PQ / HLG labels (left gutter, dark pill radius 3) | white on black | 0.6 on 0.45 | 11 pt mono | `:953-975` | shared label + backing |
| PQ normal levels | white | 0.22 / label 0.6 | 0.5 | `:505-511`, `:981-995` | shared via `.normal` |
| PQ 100 nit (`.strong`) | white | 0.42 / label 0.8 | 1.0 | `:508` | literal in `graticuleEmphasisStyle` |
| PQ 203 nit (`.key`) and user lines | white | 0.60 / label 0.9 | 1.0 | `:507`, `:1119-1124` | literal in `graticuleEmphasisStyle` |
| HLG % lines | white | 0.22 / label 0.6 | 0.5 | `:1006-1012` | shared |
| HLG nits ticks (28 pt edges) | **cyan** | 0.28 | 0.5 | `:1015-1021` | literal |
| HLG nits labels (right gutter) | white | 0.5 | 11 pt | `:1022` | literal |
| Parade column separators | white | 0.18 | 0.5 | `ParadeScope.swift:318-327` | literal |

**CIE** (`CIEScope.swift`, plain `Canvas` at `:445-488`):

| Element | Color | Alpha | Width | Where |
|---|---|---|---|---|
| Spectral locus | white | 0.35 | 0.75 | `:455` |
| 709 triangle | gray 0.85 (`:164`) | 0.85 | 0.9 | `:464` |
| P3 triangle | cyan (0.35, 0.85, 1.0) (`:165`) | 0.85 | 0.9 | `:464` |
| 2020 triangle | amber (1.0, 0.75, 0.30) (`:166`) | 0.85 | 0.9 | `:464` |
| D65 cross ±4 pt | white | 0.70 | 0.75 | `:472` |
| Legend swatch / text | gamut color | 0.9 | 1.5 / 8 pt mono | `:479-482` |

**Audio meters** (`AudioMeterScope.swift:755-781`): dB ticks use **shared** major 0.22 at 0.5 width. The 0 dBFS line
uses the label opacity 0.6. Labels go through the shared `drawGraticuleLabel`, and the marker uses `.key`. Any change
to the shared constants therefore changes the meters too.

**Text shared by all scopes:** header name and suffix in white 0.5, 9 pt mono (`ContentView.swift:67`, `:75`, `:80`). Panel
border white 0.15 (`WaveformScope.swift:877`, and the same in each scope).

### 2.3 Inventory: trace color, gain and blending

| Scope | Color | Gain | Curve | Blending |
|---|---|---|---|---|
| Waveform | `waveformTraceColor` `00FF00` (`Preferences.swift:150`) | `baseGain 2.0` × `waveformIntensity` × `globalScopeIntensity`; range 0.25–3.0 (`WaveformScope.swift:69`, `Preferences.swift:91-94`, `:122`) | dense: γ 1.25, floor 0.008 (`ScopeCompute.swift:20-32`) | opaque image (α 255) over black, nearest-neighbor, under the graticule |
| Parade | pure R/G/B or mono `FFFFFF` | `baseGain` × `paradeIntensity` × global | dense, max shared across channels | same |
| Vectorscope | `vectorscopeTraceColor` `FFFFFF` (`Preferences.swift:151`) | `baseGain` × `vectorscopeIntensity` × global × `vectorscopeSparseGain 2.0` (`ScopeCompute.swift:143`) | sparse: `log1p(c)/log1p(max)`, 3×3 dot, falloff 1 / 0.6 / 0.3, MAX-blend (`ScopeCompute.swift:189-237`) | same |
| CIE | white, hard-coded (`CIEScope.swift:74`) | `cieGain 6.25`, hard-coded; ignores the global intensity (`CIEScope.swift:64-70`) | sparse, dilation 1 (`:72`) | same |

### 2.4 Proposed first-pass defaults

There are three changes. Each can be checked on its own.

**A. Order: structure under the trace, references and labels over it.**

- Make the trace image carry coverage. Set α = the brightest channel of each pixel instead of 255, at
  `ScopeCompute.swift:75`, `:121-127` and `:231`. RGB is already ≤ that value (`fv · color` with color ≤ 1), so the
  image stays a valid premultiplied image.
- Black parts of the trace become transparent, so lines drawn *under* the trace show through empty areas and are
  covered where there is signal. The trace never takes on the graticule's tint.
- Split each graticule into two layers:
  - **Under the trace** (structure): SDR, PQ and HLG lines and ticks; parade and YRGB separators; the vectorscope
    circle, ticks and crosshair; the CIE locus and D65 cross.
  - **Over the trace** (references you measure against): every label and its pill, user lines, PQ `.strong`/`.key`
    lines, vectorscope brackets and hue labels, the skin-tone axis, user targets, CIE triangles and legend.
- For the value scopes this means giving `drawActiveValueGraticule` a `layer: .structure / .references` parameter and
  drawing two `KeyedCanvas` layers with the same key (`WaveformScope.swift:1062-1080`).
- The vectorscope and CIE `Canvas`es split the same way.
- Labels stay on top. The pill backing is what keeps them readable over a trace (`WaveformScope.swift:942-952`).

**B. Brightness and width.** At 1× all structure moves from 0.5 to **1.0 pt**, with y snapped to `floor(y) + 0.5`
when `displayScale == 1`. Proposed values:

| Constant or literal | Now | Proposed |
|---|---|---|
| `graticuleMajorOpacity` (`WaveformScope.swift:82`) | 0.22 @ 0.5 pt | **0.30 @ 1.0 pt** (about 3× the effective brightness of today's half-covered 0.22) |
| `graticuleMinorOpacity` (`:83`) | 0.10 @ 0.5 | **0.18 @ 1.0** |
| `graticuleLabelOpacity` (`:87`) | 0.60 | **0.85** |
| `graticuleLabelBackingOpacity` (`:88`) | 0.45 | **0.60** |
| `graticuleLabelFontSize` (`:86`) | 11 | 11 (unchanged; gutter sizing depends on it, `:115-126`) |
| `.strong` (`:508`) | 0.42 / 1.0 / 0.8 | **0.55 / 1.0 / 0.9** |
| `.key`, used by user lines and the meter marker (`:507`) | 0.60 / 1.0 / 0.9 | **0.75 / 1.5 / 1.0** |
| HLG nits ticks (`:1021`) | cyan 0.28 @ 0.5 | **cyan 0.45 @ 1.0** |
| HLG nits labels (`:1022`) | 0.5 | **0.7** |
| Parade separators (`ParadeScope.swift:326`) | 0.18 @ 0.5 | **0.30 @ 1.0** |
| Vectorscope circle (`:574`) | 0.14 @ 0.5 | **0.35 @ 1.0** |
| Vectorscope minor / major ticks (`:591-592`) | 0.42 / 0.58 @ 0.5 | **0.45 / 0.65 @ 1.0** |
| Vectorscope crosshair (`:599`) | 0.20 @ 0.5 | **0.40 @ 1.0**, arms ±8 pt |
| Skin-tone axis (`:632`) | 0.50 @ 1.0 | **0.70 @ 1.0** (kept matched to the brackets, `:625-627`) |
| Target brackets (`:669`) | 0.50 @ 0.75 | **0.70 @ 1.0** |
| Target hue labels (`:672-673`) | 0.55, 8 pt, no pill | **0.85, 9 pt, with the shared pill backing** |
| User target keyline / numeral (`:735`, `:743`) | 0.35 / 0.55 | **0.50 / 0.85** |
| CIE locus (`:455`) | 0.35 @ 0.75 | **0.55 @ 1.0** |
| CIE triangles (`:464`) | 0.85 @ 0.9 | **0.90 @ 1.0** |
| CIE D65 cross (`:472`) | 0.70 @ 0.75 | **0.85 @ 1.0** |
| Header text (`ContentView.swift:67`, `:75`, `:80`) | 0.5 | **0.7** |

- Move the vectorscope and CIE literals into named constants beside the shared ones. "Graticule brightness" (§2.5)
  then has one place to apply.
- **The meters inherit B through the shared constants** (`AudioMeterScope.swift:763-768`). That is intended but should
  be checked by eye: their bars are opaque and the lines sit over them.

**C. Hue: keep the structure neutral.** Separating by hue alone is rejected for the first pass, because every
candidate hue already means something somewhere:

- Amber is the CIE 2020 triangle (`CIEScope.swift:166`).
- Cyan is P3 and the HLG nits ruler.
- Green is the waveform trace.
- Red, green and blue are the parade.

Ordering (A) does the separating instead. The one case still weak after A is the white vectorscope trace over white
structure. If it still reads poorly after A and B, the next lever is a cool neutral for vectorscope structure only,
e.g. `B8C4D6`. That is a decision for you, not part of this pass.

### 2.5 How a later "Graticule brightness" control would plug in (not built)

- **Keys:** one per scope: `manifold.waveform.graticuleBrightness`, `manifold.parade.…`, `manifold.yrgb.…`,
  `manifold.vectorscope.…`, `manifold.cie.…`, `manifold.meters.…`. Each is a Double with default 1.0 and range
  0.25–2.0, following the per-scope `manifold.<scope>.` key naming (`ParadeScope.swift:217-220`).
- **Applying it:** one function, `graticuleStyle(_ base: Double, brightness: Double) -> Double = min(1, base ×
  brightness)`, applied to line and label alpha only. The pill backing, widths and positions stay fixed, so the gutter
  sizing (`WaveformScope.swift:143-162`) is untouched.
- **It must go in the canvas key.** Add it to `ValueGraticuleKey` (`WaveformScope.swift:1075-1080`), and give the
  vectorscope and CIE Canvases an equivalent key. A value missing from the key draws stale (`WaveformScope.swift:1060`).
- **It must stay out of `sampleInputs`.** It is overlay-only and needs no GPU re-sample. The defaults observer already
  ignores writes outside `sampleInputs` (`WaveformScope.swift:605-611`).
- **UI:** Settings ▸ Scopes & Guides, `Section("Scopes")` (`SettingsView.swift:564-579`). Add one slider row per scope,
  using the existing `sliderRow` helper.
- **Export:** goes in the future "preferences" section that `docs/SETTINGS_EXPORT_PLAN.md:105` already calls "Out,
  next", as a new section with `version: 1` and a range check on each key. An older reader lists the section as
  `unknown` and skips it (`SettingsFile.swift:205-208`), so it does not need a format bump (`SettingsFile.swift:11-12`).

### 2.6 Visual verification on the LG

**Before anything is launched:**

- Tell Robbie before launching.
- Run `scripts/manifold-proc.sh guard` before and after, and use `guard && <launch>`, never `;`.
- Launch the built binary directly and keep its PID.
- If any `/Applications/Manifold.app` process is running, stop and report it.

**Window and screenshot:**

- Put the Manifold window on the **LG** with the tray open. For the sweep, use three slots: Vectorscope | Waveform |
  Parade (or YRGB).
- Window ID: use `docs/color-fixtures/getwin.swift`, but filter on `kCGWindowOwnerPID == <held PID>`. As written it
  takes the largest window owned by "Manifold" (`getwin.swift:7-13`), which could be a different build.
- Capture with `screencapture -x -o -l <id> ~/Code/_scratch/manifold-scopes095/<step>.png`. Write what each shot shows
  in text, then delete it.
- **By-eye judgments of legibility and separation are made on the LG.** Any byte comparison of screenshots (for
  example, measuring a line's pixel value before and after) is a pixel-value check and goes on the **ASUS**, per
  CLAUDE.md. Trace pixels themselves can be checked independently of any display through `MANIFOLD_SCOPE_DUMP_DIR`.

**Fixtures** (opened read-only, in place):

| Stress | Fixture | Status |
|---|---|---|
| Dark | `docs/color-fixtures/wedge.mov`: 48 flat gray patches, 32 below code 0.25 (`docs/color-fixtures/README.md:34`) | CONFIRMED present |
| High saturation | S0 chart, row 1 = 100 % R G B C M Y (`make_patches.py:3`, `:9`). Built copies are in `build/stream-fixtures/chart_919_*.ts` | Present. Whether a `.ts` opens as a **file** (rather than over SRT/HLS) is **UNKNOWN** |
| Mid saturation | the same chart, row 2 = 50 % R G B C M Y | as above |
| Low saturation / skin | **none found.** The stills `../fixtures/stills/SDR JPEG/IMG_0014.jpeg` and others have **UNKNOWN** content. Proposal: a follow-up `make_patches.py` variant with 10 / 20 / 30 % saturation patches and one on the 123° skin-tone axis | UNKNOWN / gap |
| HDR ruler legibility | `docs/color-fixtures/wedge-pq-24track.mov` (PQ ruler and labels on the LG) | CONFIRMED present |

**Per fixture, record:**

- Can the graticule be followed across the whole plot?
- Do lines disappear under dense trace (expected after A) while the labels stay readable?
- Is the 75 % target box readable with the S0 bars inside it?
- On wedge, does the near-black trace stay distinct from the 0 and 10 % lines?
- Can the waveform, parade and YRGB 0 / 512 / 1023 labels be read at the default tray height of 204
  (`WindowChrome.swift:63`)?

---

## Other findings

- Stale comment: the kernels say the offscreen is rgb10a2 (`PassthroughShader.metal:613-621`, `:658-660`), but it is
  rgba16Float (`MetalVideoRenderer.swift:242`). Values above 1.0 are clamped into the top bin by every kernel
  (`:639`, `:676-678`).
- Stale comment: `WindowChrome.swift:109` says Show/Hide Scopes is ⌘7. The catalog has ⌥⌘S
  (`ShortcutCatalog.swift:321`).
- Stale comment: `MetalVideoRenderer.swift:428` says the CIE mode flips on ⌃⌥X. That row has no default key
  (`ShortcutCatalog.swift:322`).
- The vectorscope and CIE graticules are plain `Canvas`, not `KeyedCanvas` (`VectorscopeScope.swift:556`,
  `CIEScope.swift:446`). This has no per-frame cost since the trace layer split, but the §2.4 A split is the time to
  key them.

---

## Summary

1. **YRGB size:** medium, about 1–1.5 days of code plus half a day of verification. It is a new ~350-line
   `YRGBScope.swift` modeled on the parade, two-pass compute reusing both kernels (~60 lines), `yrgbPixels`
   (~30 lines), about 10 wiring sites, and a new `ScopeComputeTests` target.
2. **Graticule pass size:** small to medium, about 1 day. That covers the constants, the trace alpha at 3 sites, and
   the structure/reference layer split in 4 views. The later brightness control is about half a day once a
   preferences export section exists.
3. **YRGB cost:** estimated 1.1–1.35× the parade's GPU time per update at 4K and 8K. CPU cost is about equal for the
   same slot. Absolute milliseconds are UNKNOWN.
4. **Risk:** YRGB must use its own histogram buffers. Sharing the waveform's or parade's buffer would tear.
5. **Risk:** YRGB's `sampleInputs` must include `pictureMatrixCode`, as the waveform's does. The parade's does not.
6. **Risk:** pixel-for-pixel Y holds at equal `colW`, not across different slot widths. Y must keep its own max,
   separate from RGB.
7. **Risk:** the trace alpha change affects all four image scopes and the `MANIFOLD_SCOPE_DUMP_DIR` dumps. The shared
   constants also move the meters.
8. **Finding:** both displays are 1×, so the 0.5 pt lines render at about half their stated alpha. Moving to 1 pt
   with pixel snapping is the biggest visibility gain.
9. **UNKNOWN:** Resolve's Y trace color; Services key equivalents for ⌥⌘Y; whether a `.ts` opens as a file; the
   content of the stills; absolute GPU timings.
10. **Decisions for you:** the Y color (gray-white proposed), a separate `yrgbIntensity` (proposed), ⌥⌘Y or no default
    key (no default proposed until Services are checked), and whether the vectorscope structure gets a cool tint if A
    and B are not enough.

---

## As implemented: part 2, first pass (2026-11-16)

Robbie's decisions, 2026-11-16:

- The scopes get their own constants; the audio meters must look exactly as they do today.
- No cool tint on the vectorscope.
- No user brightness control in this pass.
- YRGB is not part of this step.

**What was built:**

- `ScopeGraticuleStyle` and `scopeGraticuleEmphasisStyle` (`App/WaveformScope.swift`) hold every scope value.
- `ScopeGraticuleLayer` splits each graticule into an under-trace layer and an over-trace layer.
- `gridAligned` calls `ScopePixelGrid` (`Packages/ManifoldCore/Sources/ScopeCompute/ScopePixelGrid.swift`) to put lines
  on whole device pixels.
- Trace alpha is the brightest channel (`ScopeTrace.coverage`).
- Tests are in `Packages/ManifoldCore/Tests/ScopeComputeTests/`.

**Departures from §2.4:**

- **Header text stays at 0.5.** `ScopeSlotHeader` is shared with the audio meters and the markers list.
- **The `.key` tier is 1.0 pt, not 1.5.** Every scope line is 1 pt so that it lands on the pixel grid. `.key` and
  `.strong` differ by alpha only (0.75 and 0.55).
- **The vectorscope hue names have no pill backing.** `drawGraticuleLabel` anchors labels to an edge only, and a
  centered pill would be a new element. They moved to 9 pt and alpha 0.85.
- **The user-target keyline stays 0.5 pt wide.** At 1 pt it would overlap the 1.5-pt colored ring. Its alpha moved
  from 0.35 to 0.50.
- **The CIE legend is unchanged.**

## As implemented: follow-up after the attended check (2026-11-16)

Robbie, after the attended check on the LG: the vectorscope is right as it is; the waveform and parade graticules are too
intense.

**Lower waveform and parade defaults.** Still 1 pt and pixel-aligned. Each value is half-way between the old and the first-pass
intensity, measured as alpha × width (the ink per unit length):

| Constant | Old (0.5 pt) | First pass (1 pt) | Half-way | Now (1 pt) |
|---|---|---|---|---|
| `majorOpacity` | 0.22 → 0.11 | 0.30 | 0.205 | **0.20** |
| `minorOpacity` | 0.10 → 0.05 | 0.18 | 0.115 | **0.12** |
| `paradeSeparatorOpacity` | 0.18 → 0.09 | 0.30 | 0.195 | **0.20** |

`majorOpacity` also sets the PQ ruler's plain levels (the `.normal` tier) and the HLG % lines, so those follow. Labels, the HLG nits
ticks (0.45), the PQ 100- and 203-nit lines, user lines, the vectorscope and CIE are unchanged.

**Settings ▸ Scopes & Guides ▸ Scopes ▸ Graticule brightness**, directly under Master scope intensity and built the same way:

- **Key and storage.** `@AppStorage` key `scopeGraticuleBrightness` (`Preferences.graticuleBrightnessKey`). The range is 0–2 and the
  default 1.
- **Who reads it.** Each scope view binds it with `@AppStorage`, as `scopeScale` is bound. The value scopes carry it in
  `ValueGraticuleKey`, so their keyed canvases redraw.
- **The scaling.** `ScopeGraticuleBrightness` (ScopeCompute) is a pure function, unit-tested:
  - Lines are base × value, clamped to 0–1.
  - Labels (value labels, PQ/HLG labels, user-line labels, hue names, user-target numerals, CIE legend text) never go
    below 0.60, the pre-0.9.5 label value.
  - The skin-tone axis never goes below 0.50, its pre-0.9.5 value.
- **Not scaled:** the label backing pills and the audio meters.
- **At 0.** The user lines, target brackets and user-target rings go off with the other lines. Their labels stay.
- **Settings export.** Not exported, because Master scope intensity isn't either. See `docs/ROADMAP_IDEAS.md`, "Scope preferences
  in settings export".

**Decisions (Robbie, 2026-11-16, after the above):**

- **HLG nits ticks:** 0.45 → **0.30** at 1×. They follow the slider like the other lines.
- **User lines (waveform and parade) and user targets (vectorscope: ring, keyline, numeral) are the user's own markings, not
  graticule.** They ignore the slider and draw at their own values at every position. This supersedes "At 0" above.
- **Color-bar target brackets** follow the slider with a floor of 0.50, like the skin-tone axis.
  `ScopeGraticuleBrightness.reference` (floor `referenceFloor` 0.50) serves both, and replaces `skintoneAxis`.

## As implemented: part 1, YRGB parade (2026-11-16)

Robbie's decisions, 2026-11-16:

- A new scope, "YRGB Parade": four columns Y, R, G, B. The Waveform and the RGB Parade are unchanged.
- The Y trace is neutral gray-white (`E6E6E6`, `yrgbLumaTraceHex`). R, G and B are pure, as in the parade.
- It has its own intensity (`yrgbIntensity`) in its header.
- Shortcut: no default. The catalog row "Parade: Switch RGB / YRGB" (`scopes.yrgbParade`) is unbound.
- It uses Graticule brightness and the parade's under/over layering.

**What was built (option A, §1.4).**

- **Compute.** `MetalVideoRenderer.computeYRGBGPU` encodes `waveformKernel` (at `scopeW = colW`, with Kr/Kb from
  `scopeCodes.matrix`) and `paradeKernel` into one command buffer with one completion.
  - It has its own buffers, `yrgbLumaHistogramBuffer` and `yrgbRGBHistogramBuffer`.
  - The single-kernel scopes go through the same `commitScopePasses`, with one pass each.
- **Trace.** `ScopeTrace.yrgbPixels` calls `waveformPixels` and `paradePixels` and copies rows. Y keeps its own max;
  R, G and B share theirs.
- **Model and view** (`App/YRGBScope.swift`).
  - `sampleInputs` includes `renderer?.pictureMatrixCode`, as the waveform's does.
  - Its header fields are written by `ScopeColorFeed` only.
  - Separators sit at 1/4, 2/4 and 3/4.
  - User lines use `manifold.yrgb.line1/2.*`.
  - `colW` is slot/4, clamped to 128–512.
- **No mono mode.** The decision named none, so R, G and B are always pure color.
- **Tests.** `YRGBTraceTests` (7) check that, at equal `colW`:
  - Y is byte-equal to `waveformPixels`;
  - R, G and B are byte-equal to `paradePixels`;
  - Y and RGB normalize independently;
  - Y matches the brightness curve directly;
  - an all-zero frame and degenerate sizes are handled.
  The histogram identity holds by construction (the same kernels and parameters), and `swift test` cannot reach the
  GPU.
- **Not built:** the `MANIFOLD_YRGB_SELFCHECK` GPU comparison (§1.6, item 2).
- **GPU cost.** In DEBUG, `MANIFOLD_SCOPE_PERF=1` now adds `gpu.<scope>=<mean ms>/<n>` per second, from each scope
  command buffer's `gpuEndTime − gpuStartTime`. No reading has been taken yet.
