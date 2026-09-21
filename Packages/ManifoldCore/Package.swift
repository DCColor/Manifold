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
                // >>> setters, AND THE TELEMETRY IS REACHABLE AND WILL EMIT.
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
                // So a Release build writes `[LIVECLOCK] depth=… target=… rate=…` to stderr at
                // 1 Hz for as long as any NDI / WHEP / SRT / HLS source is connected. Confirmed in
                // the stripped Release ARCHIVE, not just a build product: five [LIVECLOCK] format
                // strings survive, including the 1 Hz one.
                //
                // This is a defect and it is independent of which configuration ships — Profile and
                // Release both emit it. The fix is the "move emission to the App layer" plan, or a
                // Core-side switch that is not MANIFOLD_TELEMETRY. Until then, do not read this
                // block as saying the telemetry is dormant. It is not.
                .define("MANIFOLD_TELEMETRY")
            ]
        )
    ]
)
