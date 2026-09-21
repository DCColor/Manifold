//
//  AudioMirrorRatePin.swift
//  ManifoldCore
//
//  One preference, one variable: pin the audio mirror's rate to exactly 1.0.
//
//  ── THE HYPOTHESIS THIS EXISTS TO TEST ─────────────────────────────────────────────────────────
//
//  `AVSampleBufferAudioRenderer` consumes at the rate the synchronizer is set to, which is
//  `mirror.smoothedRate`. Measured: 1.0 for files (clean), ~1.0007 on local SRT (clean), ~1.0014
//  on Cloudflare (gravel). Above unity the renderer consumes faster than a live source supplies
//  and starves.
//
//  ⚠️ AND IT EXPLAINS WHY EVERY CAPTURE SO FAR READ CLEAN. A system-audio capture concatenates
//  SUBMITTED samples; it does not observe real time. Correct-but-late delivery is therefore
//  indistinguishable from correct delivery in a capture file, and audible in the room. That is the
//  asymmetry that kept "the bytes are fine" true at every upstream stage while the output was
//  gravel — the bytes ARE fine, and when they arrive is not.
//
//  ── ⚠️ WHY THIS AND NOT `forceUnityRate` ───────────────────────────────────────────────────────
//
//  `LiveClock.forceUnityRate` pins the CLOCK. The renderer's rate follows it only through the
//  mirror's τ=30 s EMA, so the variable under test would move ~30–60 s after the keystroke — and
//  the same flag disables the video depth loop, so buffer depth drifts at the same time. Two
//  variables, one delayed. This pins the rate the renderer actually runs at, immediately, and
//  touches nothing else: not `LiveClock`, not `forceUnityRate`, not the depth loop.
//
//  ── ⚠️ COMPILED INTO RELEASE, AND DELIBERATELY SO. READ THIS BEFORE SHIPPING. ───────────────────
//
//  There is NO `#if` around this. The runtime preference is the entire gate, and that is a
//  departure from how `[LIVECLOCK]` and the WAV capture are arranged, made for one reason: the
//  hypothesis has to be testable in a RELEASE build, tonight, and `MANIFOLD_TELEMETRY` cannot
//  distinguish Release from Profile (see `Package.swift`). A compile gate that excluded Release
//  would have excluded half the experiment.
//
//  So a shipping build contains this code path. It is inert unless someone writes the preference,
//  it defaults to off, it has no UI and nothing in the app turns it on. **It is still a
//  behaviour-changing switch inside a shipping binary, which is different in kind from a telemetry
//  string that merely exists.** If it outlives the investigation it should either be removed or be
//  moved behind `#if DEBUG` — and it should not be left here by default simply because it is
//  harmless when unset.
import Foundation

public enum AudioMirrorRatePin {
    public static let defaultsKey = "manifold.pinAudioMirrorRate"

    /// ⚠️ LATCHED ONCE, AT FIRST READ. `static let` with an initialiser closure is evaluated
    /// exactly once and is thread-safe. The read must not be repeated per buffer: a value that
    /// could change under a running session would make the log's claim about what was in force
    /// untrue for part of the recording, which is the one thing a diagnostic may not do.
    ///
    /// `ManifoldApp.init` touches this at launch so the latch happens — and the line below is
    /// printed — before any transport exists, rather than at the first audio buffer.
    public static let isEnabled: Bool = {
        let on = UserDefaults.standard.bool(forKey: defaultsKey)
        guard on else { return false }
        NSLog("""
              [AUDIO-MIRROR] ⚠️ RATE PIN ARMED via the %@ preference — the audio mirror's smoothed \
              rate is held at EXACTLY 1.0 for this launch, so the renderer consumes at real time \
              rather than at the control loop's rate. THIS IS A DIAGNOSTIC AND IT CHANGES \
              BEHAVIOUR: lip sync is no longer corrected by the rate, so audio and picture will \
              drift apart over a long session. Turn it off with: defaults delete \
              com.graviton.manifold %@
              """, defaultsKey, defaultsKey)
        return true
    }()

    /// The rate that is pushed when the pin is armed. Exactly 1.0 — not "approximately unity",
    /// not the clock's rate rounded. The whole point is that one variable is held at a known
    /// constant while everything else runs as it always did.
    public static let pinnedRate = 1.0
}
