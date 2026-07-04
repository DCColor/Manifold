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
                .unsafeFlags(["-Xcc", "-I", "-Xcc", ffmpegInclude])
            ]
        )
    ]
)
