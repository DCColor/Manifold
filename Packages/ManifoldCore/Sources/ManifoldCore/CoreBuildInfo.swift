/// What ManifoldCore itself was compiled with — reported by the app's `[BUILD]` banner.
///
/// WHY THIS EXISTS, AND WHY THE APP CANNOT ANSWER IT. The app and this package get their telemetry
/// capability from DIFFERENT symbols through DIFFERENT mechanisms:
///
///   * the APP is gated on `DEBUG`, set per-configuration by project.yml's
///     SWIFT_ACTIVE_COMPILATION_CONDITIONS — which reaches app targets and nothing else;
///   * THIS PACKAGE is gated on `DEBUG || MANIFOLD_TELEMETRY`, where `MANIFOLD_TELEMETRY` is
///     defined by Package.swift, because Xcode maps a configuration to a SwiftPM build
///     configuration by NAME — only a config literally named "Debug" is `.debug` — so no setting in
///     project.yml can give this package `DEBUG` under a config named "Profile".
///
/// Two independent switches means they can disagree, and one of the two failure modes is silent:
/// app ON with core OFF compiles and runs, emits every `[WHEP-*]` line, and emits NO `[LIVECLOCK]`
/// line at all. That build looks instrumented and is not. It is exactly the state the "Profile"
/// configuration was in before `MANIFOLD_TELEMETRY` existed, and it was caught only because
/// SyntheticLiveSource happened to call a `#if DEBUG`-gated API and failed to compile. Without that
/// accident it would have produced a plausible, half-instrumented measurement run.
///
/// So the app must not ASSERT this — it has no way to know. This constant is compiled INSIDE the
/// package under the SAME condition the telemetry itself uses, so it is an observation of what
/// actually happened, and `core=OFF` becomes the first line of the log instead of an inference from
/// missing output.
public enum ManifoldCoreBuild {

    /// True when this package's `[LIVECLOCK]` telemetry and tuning hooks (`setDepths`,
    /// `setForceUnityRate`) were compiled in.
    ///
    /// KEEP THIS CONDITION CHARACTER-FOR-CHARACTER IDENTICAL to the guards in LiveClock.swift. It is
    /// a proxy for them, and a proxy that can drift from what it reports is worse than no proxy: it
    /// would print `core=ON` for a build with no telemetry, which is the one thing this is here to
    /// make impossible.
    public static let telemetryEnabled: Bool = {
        #if DEBUG || MANIFOLD_TELEMETRY
        return true
        #else
        return false
        #endif
    }()

    /// Which symbol turned it on, for the banner. Distinguishes "this is a Debug build" from "this
    /// is Profile/Release and the package-owned switch is what carried it", which is the difference
    /// that took a whole evening to find.
    public static var telemetrySource: String {
        #if DEBUG && MANIFOLD_TELEMETRY
        return "DEBUG+MANIFOLD_TELEMETRY"
        #elseif DEBUG
        return "DEBUG"
        #elseif MANIFOLD_TELEMETRY
        return "MANIFOLD_TELEMETRY"
        #else
        return "none"
        #endif
    }
}
