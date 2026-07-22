import Foundation
import ManifoldCore   // ManifoldCoreBuild — the package reporting its OWN telemetry state

/// The one line that says, unambiguously, what this binary IS.
///
/// WHY THIS EXISTS. The .xcodeproj is XcodeGen-generated and gitignored, so a scheme's run
/// configuration set by hand in Xcode does not survive `xcodegen generate` — it reverts to whatever
/// project.yml says, silently, with no diff to notice. A whole session's worth of performance logs
/// were analyzed without anyone being able to state which configuration produced them. A log that
/// does not identify its own build is not evidence, and `[BUILD]` is what makes every future log
/// self-identifying: paste it anywhere and the configuration comes with it.
///
/// NOTHING HERE IS GUESSED. The three facts on the line come from three independent sources:
///
///   * CONFIGURATION — the `MANIFOLD_CONFIG_*` compilation condition injected per config by
///     project.yml's `settings.configs` block. Swift compilation conditions are booleans, so one
///     flag per config is the only way to carry a NAME into `#if`.
///   * DEBUG — `#if DEBUG` directly. Note this is NOT redundant with the configuration: Profile is
///     a release-type config that DELIBERATELY defines DEBUG, so the telemetry survives at -O.
///   * OPTIMIZATION — a runtime probe, not an assumption. `assert` is compiled OUT under `-O` and
///     retained under `-Onone`, so whether the closure runs IS the optimization level, observed
///     rather than declared. This is the only one of the three that cannot drift from reality when
///     someone edits project.yml.
///
/// THE CROSS-CHECK IS THE POINT. Because the config name and the optimization level come from
/// independent sources, they can be compared — and a mismatch means project.yml's
/// `SWIFT_OPTIMIZATION_LEVEL` no longer matches what the config name implies. That prints loudly
/// rather than quietly producing another set of unattributable numbers.
enum BuildInfo {

    /// Configuration name, from the per-config compilation condition. "Unknown" is reachable only
    /// if a config was added to project.yml without a matching `MANIFOLD_CONFIG_*` flag — and it is
    /// deliberately loud rather than defaulted to something plausible.
    static var configuration: String {
        #if MANIFOLD_CONFIG_DEBUG
        return "Debug"
        #elseif MANIFOLD_CONFIG_PROFILE
        return "Profile"
        #elseif MANIFOLD_CONFIG_RELEASE
        return "Release"
        #else
        return "Unknown"
        #endif
    }

    /// True when `DEBUG` is defined for the App module. Profile defines it on purpose.
    static var debugDefined: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// OBSERVED optimization level for THIS module. `assert`'s condition autoclosure is evaluated
    /// only when assertions are live, which is exactly `-Onone` (and `-Ounchecked` strips them like
    /// `-O`). So the side effect firing is a direct measurement of how this module was compiled.
    ///
    /// SCOPE NOTE — THIS MEASURES THE APP MODULE ONLY. ManifoldCore is built by SwiftPM, which maps
    /// an Xcode configuration to `.debug` only when it is literally NAMED "Debug" — so the package
    /// is `-Onone` under Debug and `-O` under both Profile and Release. Under the two configurations
    /// that matter for measurement the two modules therefore agree, and a `-Onone` reading here
    /// means the App layer is unoptimized, which invalidates a measurement on its own: the renderer,
    /// the display tick and the WHEP router all live there. (`ScopeCompute` is the one deliberate
    /// exception — `-O` even in Debug, via `.unsafeFlags` in Package.swift.)
    static var isOptimized: Bool {
        var assertionsLive = false
        assert({ assertionsLive = true; return true }())
        return !assertionsLive
    }

    /// Whole-module vs per-file, from the `MANIFOLD_SWIFT_WMO` flag set beside
    /// `SWIFT_COMPILATION_MODE` in project.yml.
    ///
    /// THE ONE DECLARED FIELD. Swift exposes no macro for the compilation mode, so unlike `-O`
    /// (observable via `assert`) and the C level (observable via `__OPTIMIZE__`) this one is
    /// asserted by project.yml and could drift if the two lines are edited apart. It is reported
    /// anyway because `-O` WITHOUT whole-module is a materially different build — no cross-file
    /// inlining or specialization — and a measurement config that quietly lost it would look
    /// identical in every other field.
    static var wholeModule: Bool {
        #if MANIFOLD_SWIFT_WMO
        return true
        #else
        return false
        #endif
    }

    /// OBSERVED C/ObjC optimization level, from `App/BuildInfoC.c` — a real TU compiled with the
    /// app target's C flags, reading `__OPTIMIZE__` / `__OPTIMIZE_SIZE__`.
    ///
    /// WHY THIS IS A SEPARATE PROBE AND NOT AN INFERENCE. `GCC_OPTIMIZATION_LEVEL` is a different
    /// build setting on a different compiler, and the Swift probe above is blind to it. That gap is
    /// dangerous in THIS project specifically: `H264Depacketizer.c` receives every RTP packet and
    /// `DataChannelBridge.m` produces the arrival timestamps that the jitter, underrun and backlog
    /// measurements are all derived from. Swift at -O with C at -O0 would satisfy every other check
    /// on this line and still yield numbers that mean nothing.
    static var cOptimization: String { String(cString: ManifoldCOptimizationLevel()) }
    static var cIsOptimized: Bool { ManifoldCIsOptimized() != 0 }

    /// Emit the banner. Call FIRST, before any other startup logging, so it heads every log.
    static func logAtStartup() {
        let swiftLevel = (isOptimized ? "-O" : "-Onone") + (wholeModule ? " +WMO" : "")

        // TWO TELEMETRY STATES, REPORTED SEPARATELY, BECAUSE THEY ARE TWO SWITCHES.
        //
        // APP: gated on DEBUG. App/WebRTC/* and App/Live/SyntheticLiveSource.swift are wrapped in
        // `#if DEBUG` in their ENTIRETY, so without it the live paths are not merely silent — they
        // are absent from the binary and ⌃⌥H / ⌃⌥L do nothing.
        //
        // CORE: gated on `DEBUG || MANIFOLD_TELEMETRY` inside ManifoldCore, and OBSERVED from the
        // package rather than assumed here — the app has no way to know what the package was
        // compiled with (see ManifoldCoreBuild). This is the field that would have been OFF, alone,
        // in the half-instrumented Profile build.
        let appTelemetry = debugDefined
        let coreTelemetry = ManifoldCoreBuild.telemetryEnabled

        NSLog("[BUILD] configuration=%@  swift=%@  c=%@  (DEBUG=%d)",
              configuration, swiftLevel, cOptimization, debugDefined ? 1 : 0)
        NSLog("        telemetry: app=%@ core=%@ (core via %@)",
              appTelemetry ? "ON" : "OFF",
              coreTelemetry ? "ON" : "OFF",
              ManifoldCoreBuild.telemetrySource)

        // THE ASYMMETRY THAT MATTERS. app=ON with core=OFF is the silent half-instrumented build:
        // every [WHEP-*] line appears, no [LIVECLOCK] line ever does, and the run looks valid. It
        // is announced here rather than left to be inferred from output that never arrives.
        if appTelemetry && !coreTelemetry {
            NSLog("""
                          <<< HALF-INSTRUMENTED: the app has telemetry but ManifoldCore does NOT, \
                  so NO [LIVECLOCK] line will ever be emitted and the clock is unobservable. \
                  MANIFOLD_TELEMETRY is missing from ManifoldCore's swiftSettings in Package.swift \
                  — note that no project.yml setting can supply it, because Xcode maps a package's \
                  build configuration by NAME and only "Debug" is .debug.
                  """)
        }
        // The converse is the known, accepted state of a shipping build: the package-owned switch is
        // unconditional, so Core's telemetry is compiled into Release. Nothing can reach it there —
        // no live source is built in — so this is a note, not a warning.
        if !appTelemetry && coreTelemetry {
            NSLog("        note: core telemetry is compiled in but unreachable (no live source in this configuration)")
        }

        // THE WARNING KEYS ON OPTIMIZATION, NOT ON DEBUG — and on BOTH languages. Profile is
        // DEBUG=1 and fully valid; Debug is DEBUG=1 and is not, so keying on DEBUG would libel
        // Profile and let the one case that matters through. Either language being unoptimized is
        // disqualifying on its own: the render path is Swift, the RTP path is C, and a measurement
        // needs both. Inline in the log so a pasted excerpt carries the warning with it.
        if !isOptimized || !cIsOptimized {
            let which: String
            switch (isOptimized, cIsOptimized) {
            case (false, false): which = "Swift and C/ObjC are both unoptimized"
            case (false, true):  which = "Swift is unoptimized (the render/display path)"
            default:             which = "C/ObjC is unoptimized (the RTP receive/timestamp path)"
            }
            NSLog("        <<< PERFORMANCE MEASUREMENTS FROM THIS BUILD ARE NOT VALID — %@", which)
        }

        // Independent sources disagreeing means project.yml drifted — the exact silent-misconfig
        // failure this whole file exists to prevent, so it is reported as loudly as the numbers it
        // would otherwise corrupt. Checked per language, because they are set by different keys
        // (SWIFT_OPTIMIZATION_LEVEL vs GCC_OPTIMIZATION_LEVEL) and can drift independently.
        let expectOptimized = (configuration == "Profile" || configuration == "Release")
        if configuration != "Unknown", expectOptimized != isOptimized {
            NSLog("""
                  [BUILD] <<< MISMATCH: configuration=%@ implies Swift %@ but the binary measures \
                  %@. project.yml's SWIFT_OPTIMIZATION_LEVEL and its MANIFOLD_CONFIG_* flag \
                  disagree — treat this build as unattributable until that is reconciled.
                  """,
                  configuration, expectOptimized ? "-O" : "-Onone",
                  isOptimized ? "-O" : "-Onone")
        }
        if configuration != "Unknown", expectOptimized != cIsOptimized {
            NSLog("""
                  [BUILD] <<< MISMATCH: configuration=%@ implies optimized C/ObjC but the binary \
                  measures %@. project.yml's GCC_OPTIMIZATION_LEVEL for this config is wrong — note \
                  a debug-TYPE config defaults it to 0, which is exactly how this is usually lost.
                  """, configuration, cOptimization)
        }
        if configuration == "Unknown" {
            NSLog("""
                  [BUILD] <<< UNKNOWN CONFIGURATION: no MANIFOLD_CONFIG_* flag is defined. A config \
                  was added to project.yml without adding its flag to settings.configs — this build \
                  cannot name itself.
                  """)
        }
    }
}
