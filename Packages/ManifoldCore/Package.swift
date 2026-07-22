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
                // >>> TOO. A shipping archive currently contains the [LIVECLOCK] strings and the
                // >>> two tuning setters. Nothing in Release can REACH them (SyntheticLiveSource
                // >>> and the whole WHEP stack are `#if DEBUG` in the app and are not compiled in,
                // >>> so no code path installs a LiveClock), but the code and its strings are in
                // >>> the binary. See the archive tripwire discussion in the review notes for how
                // >>> to catch it, and the "move emission to the App layer" plan for removing it.
                .define("MANIFOLD_TELEMETRY")
            ]
        )
    ]
)
