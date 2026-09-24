// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Absolute path to the vendored static libav headers (ThirdParty/ffmpeg/include),
// derived from this manifest's location so it's robust regardless of the build's
// working directory (SwiftPM CLI or Xcode/DerivedData). Package.swift lives at
// <repo>/Packages/ManifoldCore/Package.swift, so three levels up is the repo root.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Packages/ManifoldCore
    .deletingLastPathComponent()   // Packages
    .deletingLastPathComponent()   // <repo root>
let ffmpegInclude = repoRoot.appendingPathComponent("ThirdParty/ffmpeg/include").path

let package = Package(
    name: "ManifoldCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ManifoldCore", targets: ["ManifoldCore"])
    ],
    targets: [
        // Clang module exposing the vendored static libav headers to Swift. Only
        // the interface — the static archives are linked into the app binary
        // (see project.yml). The -I makes <libavcodec/...> etc. resolve when this
        // module is compiled.
        .target(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I", ffmpegInclude])
            ]
        ),
        // Pure numeric scope trace-build (histogram → RGBA). Compiled -O EVEN IN DEBUG: the
        // hot loops are ~100× slower under -Onone (a Debug-build artifact), which lagged the
        // scopes during development. The -O here (appended after SwiftPM's per-config flags,
        // so it wins) keeps them fast in Debug; Release is unaffected (already -O). Re-exported
        // by ManifoldCore below so `import ManifoldCore` exposes `ScopeTrace`.
        .target(
            name: "ScopeCompute",
            path: "Sources/ScopeCompute",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-O"])
            ]
        ),
        // The polyphase ASRC (docs/AUDIO_RESAMPLER_DESIGN.md §3.6). Pure arithmetic over arrays
        // plus Accelerate — no media types, no libav, no app state.
        //
        // ⚠️ ITS OWN TARGET, NOT A FILE IN ManifoldCore, AND THE REASON IS TESTABILITY RATHER THAN
        // TIDINESS. A test bundle LINKS the targets it depends on, and ManifoldCore resolves libav
        // symbols that are linked into the app binary by project.yml, not by this package — so a
        // test target depending on ManifoldCore cannot link here. Depending on a leaf target with
        // no dependencies is what makes `swift test` work at all. Same shape as ScopeCompute
        // above, and same -O for the same reason: the hot loop is ~100x slower under -Onone, which
        // would make the CPU figures meaningless and the test run glacial.
        //
        // NOTHING DEPENDS ON THIS TARGET YET — build step 1 is deliberately offline. ManifoldCore
        // picks it up at step 3, when the resampler enters the path at ratio 1.0.
        .target(
            name: "AudioResample",
            path: "Sources/AudioResample",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-O"])
            ]
        ),
        .testTarget(
            name: "AudioResampleTests",
            dependencies: ["AudioResample"],
            path: "Tests/AudioResampleTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-O"])
            ]
        ),
        .target(
            name: "ManifoldCore",
            dependencies: ["CFFmpeg", "ScopeCompute"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // So Swift's import of CFFmpeg can also locate the libav headers.
                .unsafeFlags(["-Xcc", "-I", "-Xcc", ffmpegInclude]),
                // ── TELEMETRY / TUNING-HOOK SWITCH, OWNED BY THE PACKAGE ──────────────────────
                //
                // LiveClock's `[LIVECLOCK]` telemetry and its tuning hooks (setDepths /
                // setForceUnityRate, called by the app's DEBUG-only SyntheticLiveSource) are gated
                // on `#if DEBUG || MANIFOLD_TELEMETRY`. This line is the second half of that
                // condition, and it exists because the FIRST half is not reliably reachable.
                //
                // WHY NOT JUST DEBUG. Xcode decides a package target's DEBUG by the configuration
                // NAME, not by the configuration's type: only a config literally named "Debug" is
                // built as SwiftPM `.debug`. Anything else — including this project's "Profile" —
                // is built `.release` with no DEBUG, no matter what type project.yml assigns it.
                // (Verified: with `Profile: debug` the generated project's Profile config carries
                // the full debug preset — SWIFT_OPTIMIZATION_LEVEL -Onone, GCC 0, TESTABILITY YES —
                // and the package STILL compiled without DEBUG.) `#if DEBUG` therefore vanished
                // from this module under Profile while the app still had it, breaking the API
                // across the boundary and silently removing all clock telemetry.
                //
                // WHY IT IS UNCONDITIONAL. `.when(configuration: .debug)` keys off that SAME broken
                // mapping, so it cannot distinguish Profile from Release either. There is no
                // package-side predicate that separates them — the two are indistinguishable here.
                //
                // >>> CONSEQUENCE, STATED PLAINLY: THIS DEFINES MANIFOLD_TELEMETRY IN **RELEASE**
                // >>> TOO. A shipping archive contains the [LIVECLOCK] strings and the two tuning
                // >>> setters — the code is compiled in and the strings are in the binary.
                //
                // ⚠️ EMISSION IS NOW GATED AT RUNTIME, SO THE STRINGS ARE NOT EVIDENCE OF OUTPUT.
                // `LiveClock` carries a flag that defaults to OFF and is captured per clock at
                // construction; only `ManifoldApp.init` turns it on, under `#if DEBUG`. So a
                // Release build compiles the telemetry, ships the format strings, and writes
                // nothing. Do not read `strings | grep LIVECLOCK` on an archive as proof that a
                // build emits — it only proves the code is present, which this line guarantees in
                // every configuration.
                //
                // That gate is the reason the paragraph below is written in the PAST tense.
                //
                // ⚠️ CORRECTED 2026-09-21 BY MEASUREMENT. This paragraph previously read "Nothing
                // in Release can REACH them (SyntheticLiveSource and the whole WHEP stack are
                // `#if DEBUG` in the app and are not compiled in, so no code path installs a
                // LiveClock)". **That was false, and it is the kind of false that gets read once
                // and acted on.** Only `SyntheticLiveSource.swift` is wholly `#if DEBUG` (its
                // directive is on line 1). The live TRANSPORTS are product features and ship:
                //
                //     symbols in the Release build product, measured with nm:
                //       WHEPClient 116 · WHEPFrameRouter 79 · SRTClient 166 · LiveDisplayRoute 28
                //       SyntheticLiveSource 0   ← the only one that is actually absent
                //
                // `WHEPClient.swift`'s first `#if` is at line 450 of 802 and gates a log line, not
                // the file. What `#if DEBUG` removes from Release is the hidden ⌃⌥H / ⌃⌥L
                // SHORTCUTS and the synthetic harness — not the transports, which are reached
                // from the ordinary Stream Sources UI.
                //
                // THE REACHABILITY CHAIN, every link verified ungated:
                //
                //     App/Live/LiveDisplayRoute.swift:168   (no #if anywhere in the file)
                //         → LiveClock(startupDepth:targetDepth:)
                //     LiveClock.swift:676, :677, :999       (ungated) → emit(_:)
                //     LiveClock.swift:1067                  #if DEBUG || MANIFOLD_TELEMETRY
                //                                           ← always true here, because of THIS line
                //     LiveClock.swift:1069                  FileHandle.standardError.write(…)
                //
                // So a Release build WROTE `[LIVECLOCK] depth=… target=… rate=…` to stderr at
                // 1 Hz for as long as any NDI / WHEP / SRT / HLS source was connected. Confirmed in
                // the stripped Release ARCHIVE, not just a build product: five [LIVECLOCK] format
                // strings survive, including the 1 Hz one — and they still do, because the fix was
                // a runtime gate rather than a recompile.
                //
                // FIXED 2026-09-21 by `LiveClock.enableTelemetry()` (see above). The reachability
                // chain is unchanged and still correct — `LiveDisplayRoute` still installs a clock
                // on every connection — but the clock now decides whether to write, and in Release
                // nothing ever turns it on. The structural fix (move emission to the App layer, or
                // a Core-side switch that is not MANIFOLD_TELEMETRY) is still the right end state;
                // the gate is what stopped the bleeding without touching the timing path.
                .define("MANIFOLD_TELEMETRY")
            ]
        )
    ]
)
