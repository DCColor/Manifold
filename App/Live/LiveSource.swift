//
//  LiveSource.swift
//  Manifold
//
//  Which live (non-file) source owns the renderer, and the ONE place that retires it.
//
//  ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
//
//  "One active source" used to be enforced by hand-written PAIRWISE chains — an
//  `if ndi.isConnected { … }` followed by an `if whep.isConnected { … }` — restated at every
//  site that takes the display: the file importer, the Disconnect menu item, the stream
//  connect path, and ManifoldApp's .onOpenURL. Two sources meant two lines per site. Three
//  means three, at every site, and the failure mode of missing one is NOT a compile error —
//  it is two sources feeding MetalVideoRenderer.enqueue at once, which is exactly the
//  double-source flashing those call sites' own comments describe.
//
//  So the enumeration lives HERE, once, and every site asks it instead of restating it.
//  Adding SRT is one case below plus one line in each switch — and a non-exhaustive switch
//  FAILS THE BUILD, which is the guarantee the hand-written chains could not give.
//
//  ── WHAT THIS IS DELIBERATELY NOT ──────────────────────────────────────────────────────
//
//  NOT a FrameSource abstraction, and not an attempt at one. NDI is a PULL source
//  (renderer.onDisplayTick, free-running monotonic clock, no LiveClock at all) and WHEP is a
//  PUSH source (LiveClock plus a depth control loop). Abstracting over "who owns the clock"
//  across both is the hard, low-payoff part and it is not attempted here. This type answers
//  exactly two questions — WHICH source is live, and how do I retire it — and both answers
//  are identical for a pull source and a push source, which is why this much factors cleanly
//  and the rest does not. The clock-shaped sharing lives in LiveDisplayRoute, on the PUSH
//  axis only.
//

import Foundation

/// A live (non-file) source that can own the renderer. At most one is ever connected — that is
/// the invariant `retireActive` maintains.
enum LiveSource: CaseIterable {

    /// NDI receive. PULL: `renderer.onDisplayTick` + a free-running monotonic clock.
    case ndi

    /// WHEP / WebRTC. PUSH: LiveClock + the depth control loop (see LiveDisplayRoute).
    case web

    // STAGE 2 ADDS `case srt` HERE. It is a PUSH source like `.web`, so it uses
    // LiveDisplayRoute the same way. Adding the case makes every switch below fail to compile
    // until it is handled — that is the point of the switches being exhaustive rather than
    // defaulted.

    /// PRIVATE, AND IT MUST STAY PRIVATE — this is the whole safety property of the type.
    ///
    /// It reads the singletons, which does NOT subscribe a SwiftUI `View` to their `@Published`
    /// changes. A `body` gated on it would render correctly ONCE and then never update again —
    /// silently, with no warning and no crash. There is no way to make that read safe in a body,
    /// so it is not reachable from one: `retireActive` below is the only member visible outside
    /// this file, it returns `Void`, and a verb cannot be mistaken for view state.
    ///
    /// Views ask `ContentView.activeLiveSource`, which reads the `@ObservedObject` instances and
    /// therefore invalidates correctly.
    ///
    /// An earlier draft also exposed a `static var active` for symmetry. Nothing called it; it
    /// existed only to carry a warning comment. Deleted rather than documented — if a future stage
    /// genuinely needs to ask "which source", add it back deliberately, with the SwiftUI question
    /// answered at that call site.
    private var isConnected: Bool {
        switch self {
        case .ndi: return NDIService.shared.isConnected
        case .web: return WHEPClient.shared.isConnected
        }
    }

    /// Retire this source. PRIVATE for the same reason as `isConnected`: `retireActive` is the
    /// entry point, and it is the thing that knows a disconnect must be guarded.
    ///
    /// ⚠️ NOT SAFE TO CALL WHEN THE SOURCE IS NOT CONNECTED — which is exactly why `retireActive`
    /// guards on `isConnected` rather than just calling this unconditionally. The guard is
    /// CORRECTNESS, not log hygiene, and it must not be "simplified" away:
    ///
    ///   * `NDIService.disconnect()` calls `renderer?.clearToBlack()` with no early-out. Calling
    ///     it while NDI is idle blacks the renderer — and its own comment ("a file still playing
    ///     repaints over the black on its next frame") only holds for a PLAYING file. A PAUSED
    ///     one has no next frame and would simply go black.
    ///   * `WHEPClient.disconnect()` is genuinely safe — it clears its flag and then
    ///     `guard let session else { return }`. Only the NDI path has the sharp edge, which is
    ///     precisely why a per-source guard beats trusting "they're all idempotent".
    private func disconnect() {
        switch self {
        case .ndi: NDIService.shared.disconnect()
        case .web: WHEPClient.shared.disconnect()
        }
    }

    /// Retire whatever live source owns the renderer. THE single "one active source" entry point,
    /// and the ONLY member of this type visible outside this file.
    ///
    /// Iterates `allCases`, so the teardown order is declaration order — NDI, then web — which is
    /// the order every hand-written chain this replaces already used. The `isConnected` guard is
    /// load-bearing; see the warning on `disconnect()` before touching it.
    ///
    /// `except` keeps one source running: for a caller that is about to hand over to that same
    /// source and whose own connect path performs the handover. `connectToStreamURL` passes
    /// `.web` because WHEP retires the loaded FILE itself, via
    /// `WHEPFrameRouter.activate()`'s `onWillActivateStream`, and refuses a second concurrent
    /// session in `WHEPClient.connect`. Passing nil retires everything.
    ///
    /// A no-op when nothing is live.
    static func retireActive(except keep: LiveSource? = nil) {
        for source in allCases where source != keep && source.isConnected {
            source.disconnect()
        }
    }
}
