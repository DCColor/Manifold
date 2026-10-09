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
        .library(name: "ManifoldCore", targets: ["ManifoldCore"]),
        // Linked by the APP target directly (project.yml), for App/WebRTC's bridge and
        // depacketizer. ManifoldCore does not use it.
        .library(name: "RTCPWire", targets: ["RTCPWire"]),
        .library(name: "DisplayProviders", targets: ["DisplayProviders"]),
        // Linked by the APP target directly (project.yml), for the saved-stream store and sheet.
        .library(name: "StreamBookmarkModel", targets: ["StreamBookmarkModel"]),
        // Linked by the APP target directly (project.yml), for every live transport's colorimetry,
        // the override picker and the renderer's provenance tier.
        .library(name: "ColorimetryModel", targets: ["ColorimetryModel"]),
        // Linked by the APP target directly (project.yml), for SRT's and WHEP's declared colour.
        .library(name: "SPSColor", targets: ["SPSColor"]),
        // Linked by the APP target directly (project.yml), for App/SRT's audio decoder.
        .library(name: "AACFraming", targets: ["AACFraming"]),
        // Linked by the APP target directly (project.yml), for calibration mode's sheet, the flash
        // detector in the renderer, and the bundled sync clips. ManifoldCore uses it too (the beep tap).
        .library(name: "SyncCalibration", targets: ["SyncCalibration"])
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
        // Step 1 built this offline. Step 3 puts it in the live path, through LiveAudioResample
        // below — never directly from ManifoldCore.
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
        // The ASRC at the live-audio seam (docs/AUDIO_RESAMPLER_DESIGN.md §7 step 3): CMSampleBuffer
        // in, CMSampleBuffers out on a contiguous output axis. `FrameEngine.LiveAudioSink` is its
        // only caller.
        //
        // ⚠️ A LEAF TARGET FOR THE SAME LINKING REASON AS AudioResample. The axis arithmetic this
        // holds — anchor, group-delay compensation, format reset, drain, hole/overlap — is the
        // highest-risk part of the design (§4.1), and it can only be tested by `swift test` if it
        // does not live in ManifoldCore. CoreMedia and Accelerate are system frameworks and link.
        // Same -O as its siblings: the per-sample interleave loop is on the audio path.
        .target(
            name: "LiveAudioResample",
            dependencies: ["AudioResample"],
            path: "Sources/LiveAudioResample",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-O"])
            ]
        ),
        .testTarget(
            name: "LiveAudioResampleTests",
            dependencies: ["LiveAudioResample"],
            path: "Tests/LiveAudioResampleTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-O"])
            ]
        ),
        // The video track's own RTCP (step 4e-1): PLI, Receiver Report, interarrival jitter, and
        // SR selection by SSRC. Pure C, no dependencies. A LEAF TARGET FOR THE SAME REASON AS
        // AudioResample: the byte layouts are only observable at test time, and a test bundle
        // cannot link anything that depends on ManifoldCore. The app reaches it through the
        // RTCPWire product; nothing in this package does.
        .target(
            name: "RTCPWire",
            path: "Sources/RTCPWire"
        ),
        .testTarget(
            name: "RTCPWireTests",
            dependencies: ["RTCPWire"],
            path: "Tests/RTCPWireTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // The save/restore of a video renderer's file-path providers (clock, paused, range) around a
        // live source's session. A leaf target so `swift test` can replay an NDI-shaped session: the
        // renderer and the sources are app code. The app links it through the DisplayProviders
        // product; nothing in this package does. docs/BUGS.md, "NDI and HLS leave the renderer's
        // clock installed after disconnect".
        .target(
            name: "DisplayProviders",
            path: "Sources/DisplayProviders",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "DisplayProvidersTests",
            dependencies: ["DisplayProviders"],
            path: "Tests/DisplayProvidersTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // `StreamType` and `StreamBookmark`, the persisted shape of a saved stream. A leaf target so
        // `swift test` can decode a stored `streamBookmarks` blob with the REAL type, not a copy of it
        // (the per-source audio offset's migration test, docs/AUDIO_RESAMPLER_DESIGN.md §19.8). The
        // store and the sheet are app code; the app links this through the StreamBookmarkModel product.
        .target(
            name: "StreamBookmarkModel",
            path: "Sources/StreamBookmarkModel",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "StreamBookmarkModelTests",
            dependencies: ["StreamBookmarkModel"],
            path: "Tests/StreamBookmarkModelTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // A live source's colorimetry: the three CICP axes and their provenance, the user's override
        // presets with their stable storage strings and per-transport availability, `resolve`, and the
        // renderer's provenance tier (docs/COLOR_MANAGEMENT_FINDINGS.md §6.9, Stage A). A leaf target,
        // no dependencies, so `swift test` reaches what was verified by measurement only. NDI's parse
        // and the CoreVideo tagging stay in the app.
        .target(
            name: "ColorimetryModel",
            path: "Sources/ColorimetryModel",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ColorimetryModelTests",
            dependencies: ["ColorimetryModel"],
            path: "Tests/ColorimetryModelTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // What an H.264 or HEVC SPS declares about colour, per axis, from the VUI's video_signal_type
        // (docs/COLOR_MANAGEMENT_FINDINGS.md §6.9, Stage SPS; §6.10, Stage 2 and decision 4). One
        // result type, one reader per codec, the bit reader shared. SRT and WHEP read it; neither the
        // vendored FFmpeg (no decoders) nor CoreMedia (reserved codes pass as declared) gives a
        // per-axis answer. A leaf target, no dependencies, so `swift test` reaches it with real SPS bytes.
        // Was `H264SPSColor` until HEVC Stage 2; `H264SPSColor` is now the H.264 reader's namespace.
        .target(
            name: "SPSColor",
            path: "Sources/SPSColor",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "SPSColorTests",
            dependencies: ["SPSColor"],
            path: "Tests/SPSColorTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Splits one PES payload into its ADTS frames (docs/BUGS.md, "SRT audio decodes nothing
        // when a PES carries more than one ADTS frame"). A leaf target for the same reason as
        // RTCPWire: `swift test` must reach the byte layouts. The app links it through the
        // AACFraming product; nothing in this package does.
        .target(
            name: "AACFraming",
            path: "Sources/AACFraming",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "AACFramingTests",
            dependencies: ["AACFraming"],
            path: "Tests/AACFramingTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Calibration mode (docs/AUDIO_RESAMPLER_DESIGN.md §19.2, §19.10): the sync clips' tone-onset
        // and flash detectors, the coded-interval matcher, the confidence rules and the proposal. A
        // leaf target, no dependencies, so `swift test` reaches all of it: the matcher's four checks
        // (pairing_check.py's, with the mean score) and the detectors on synthesised clip audio.
        .target(
            name: "SyncCalibration",
            path: "Sources/SyncCalibration",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "SyncCalibrationTests",
            dependencies: ["SyncCalibration"],
            path: "Tests/SyncCalibrationTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // The file audio pumps' tap look-ahead (docs/AUDIO_RESAMPLER_DESIGN.md §19.12): the tap is
        // filled 250 ms past what the system renderer has taken, so SDI never waits on the muted
        // renderer's refill timer. A leaf target (CoreMedia only) for the same linking reason as
        // AudioResample: `swift test` must reach the pump loop and its retire-on-seek rule, and a
        // test bundle cannot link ManifoldCore. Both file pumps (FrameEngine's AVFoundation pump,
        // LibavAudioSource) drive it.
        .target(
            name: "FileAudioLookahead",
            path: "Sources/FileAudioLookahead",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "FileAudioLookaheadTests",
            dependencies: ["FileAudioLookahead"],
            path: "Tests/FileAudioLookaheadTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "ManifoldCore",
            dependencies: ["CFFmpeg", "ScopeCompute", "LiveAudioResample", "SyncCalibration",
                           "FileAudioLookahead"],
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
