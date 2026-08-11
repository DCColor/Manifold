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

    /// SRT. PUSH, like `.web`: LiveClock + the depth control loop, through the same
    /// LiveDisplayRoute. Added in stage 3d, and adding it broke every switch below until each was
    /// handled — which is exactly what this type exists to guarantee.
    case srt

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
        case .srt: return SRTClient.shared.isConnected
        }
    }

    /// Is this source live? THE DELIBERATE RE-ADDITION the note above invites, and stage 2 is the
    /// stage that genuinely needs it: `DeckRegistry` reconciles its record of who claimed a device
    /// against what the device actually reports, so it has to be able to ask.
    ///
    /// ⚠️ NOT FOR VIEWS, AND THE REASON IS THE ONE ABOVE. This reads the singletons, which does NOT
    /// subscribe a SwiftUI `View` to their `@Published` changes: a `body` gated on it renders
    /// correctly once and then never updates again, silently. The registry is not a View — it is an
    /// AppKit-driven arbiter that recomputes on explicit triggers — which is what makes reading it
    /// there safe. Views ask `ContentView.activeLiveSource`, which observes and therefore
    /// invalidates correctly.
    var isLive: Bool { isConnected }

    /// The live source, or nil. Same non-view warning as `isLive`.
    static var connected: LiveSource? { allCases.first { $0.isConnected } }

    /// Plain-speak name for the arbitration message and tooltips ("NDI stream is running in …").
    /// Exhaustive, so a fourth transport cannot be added without naming itself to the user.
    var displayLabel: String {
        switch self {
        case .ndi: return "NDI stream"
        case .web: return "WHEP stream"
        case .srt: return "SRT stream"
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
    ///   * `SRTClient.disconnect()` is safe in the same way WHEP's is — flag first, then
    ///     `guard let session else { return }` — but it also BLOCKS: it joins the session thread
    ///     (bounded by one SRTO_RCVTIMEO period, 200 ms) before releasing the display, which is
    ///     what lets it tear down in the strict order WHEP cannot. Called on main, so that join is
    ///     a main-thread block of up to ~200 ms. That is the deliberate trade: a bounded pause at
    ///     teardown in exchange for no window in which a producer and `route.deactivate` overlap.
    private func disconnect() {
        switch self {
        case .ndi: NDIService.shared.disconnect()
        case .web: WHEPClient.shared.disconnect()
        case .srt: SRTClient.shared.disconnect()
        }
    }

    /// Retire whatever live source owns the renderer. The teardown half of the "one active source"
    /// invariant; `connectNDI` / `connectWeb` / `connectSRT` below are the standing-up half, and
    /// between them they are the only members of this type visible outside this file.
    ///
    /// Iterates `allCases`, so the teardown order is declaration order — NDI, then web, then SRT —
    /// which is the order every hand-written chain this replaces already used, extended. The `isConnected` guard is
    /// load-bearing; see the warning on `disconnect()` before touching it.
    ///
    /// `except` keeps one source running: for a caller that is about to hand over to that same
    /// source and whose own connect path performs the handover. The three `connect*` funnels below
    /// are the callers that pass it, and each documents WHY it excepts what it does. Passing nil
    /// retires everything.
    ///
    /// A no-op when nothing is live.
    static func retireActive(except keep: LiveSource? = nil) {
        for source in allCases where source != keep && source.isConnected {
            source.disconnect()
        }
    }

    /// Retire this source's error BANNER. Distinct from `disconnect()`, and NOT gated on
    /// `isConnected` — which is the whole reason it exists: the source holding a stale message is
    /// usually one that already tore itself down when it failed.
    private func clearBanner() {
        switch self {
        // NDI publishes no `lastError` — its failures are log-only, so it has no banner to retire.
        // If that changes, this switch stops compiling, which is the point.
        case .ndi: break
        case .web: WHEPClient.shared.clearError()
        case .srt: SRTClient.shared.clearError()
        }
    }

    /// ── WHY STANDING A SOURCE UP MUST RETIRE THE OTHERS' BANNERS ────────────────────────────
    ///
    /// `connectErrorBanner` shows `whep.lastError ?? srt.lastError` — ONE slot, first non-nil wins.
    /// Neither client clears its message on teardown, and that is deliberate: SRT's unsupported
    /// -codec refusal sets the message and then calls `disconnect()`, relying on the message
    /// outliving its own teardown to be read at all.
    ///
    /// Correct within one source, wrong across two. A WHEP connect that failed an hour ago leaves
    /// `whep.lastError` set forever; the user then connects SRT, SRT fails, and the `??` shows the
    /// STALE WEB message while the live SRT one sits behind it — a banner describing a transport
    /// the user has moved on from, blaming the wrong thing.
    ///
    /// Each client already clears its OWN banner on a fresh attempt (`retireError`, `lastError =
    /// nil`). Nobody cleared anyone else's, because until arbitration existed there was no single
    /// place that knew a DIFFERENT source was taking over. There is now, so this is that place.
    ///
    /// Runs AFTER `retireActive` in every funnel, so a message a teardown might itself raise is
    /// cleared too rather than being reinstated a line later.
    private static func clearBanners(except keep: LiveSource) {
        for source in allCases where source != keep { source.clearBanner() }
    }

    // MARK: - Arbitration: the one way a live source is stood up

    /// PROOF THAT ARBITRATION RAN. Every client's `connect` demands one of these, and its only
    /// initializer is `fileprivate` — so this file is the only place one can be made, and a call
    /// site in the view layer cannot construct the argument. `WHEPClient.shared.connect(to:)` and
    /// its siblings are therefore not merely *discouraged* outside this funnel: from anywhere else
    /// they DO NOT COMPILE.
    ///
    /// THAT IS WHAT THIS BUYS OVER A COMMENT, and the bug it closes was real and invisible. ⌃⌥D
    /// called `SRTClient.connect` directly, so a live WHEP session was never retired and both push
    /// sources fed `MetalVideoRenderer.enqueue` — the exact double-source flashing this file
    /// exists to prevent. ⌃⌥H had the same shape. Nothing about either call site looked wrong; it
    /// just skipped a step, and skipping a step was spelled the same as not needing one.
    ///
    /// It is a token, not a lock: it proves the caller came through this file, not that any
    /// particular teardown happened. The teardown is `retireActive`, three lines above.
    struct Arbitration {
        fileprivate init() {}
    }

    /// NDI, to a specific discovered source — the picker's action.
    ///
    /// `except: .ndi`, because NDI ALREADY SWAPS ITSELF and does it better than a retire-then-
    /// connect would: `NDIService.connect(to:)` tears the old receiver down and starts the new one
    /// in the SAME main-thread turn, so `isConnected` never dips to false and the control bar and
    /// empty state never flicker. Retiring it here first would throw that property away and buy
    /// nothing.
    static func connectNDI(to source: NDISource) {
        retireActive(except: .ndi)
        clearBanners(except: .ndi)
        NDIService.shared.connect(to: source, arbitratedBy: Arbitration())
    }

    /// NDI, first discovered source — ⌃⌥N and the streaming button's main click. `except: .ndi`
    /// for the reason above; the guards inside `connectToFirstSource` handle "already connected".
    static func connectNDIFirstSource() {
        retireActive(except: .ndi)
        clearBanners(except: .ndi)
        NDIService.shared.connectToFirstSource(arbitratedBy: Arbitration())
    }

    /// WHEP / WebRTC.
    ///
    /// `except: .web` PRESERVES TODAY'S WEB→WEB BEHAVIOUR EXACTLY, which is a refusal:
    /// `WHEPClient.connect` early-outs on `guard session == nil`, logs, and shows nothing. That is
    /// a known gap and it is deliberately NOT closed here — SRT's equivalent refusal was removed in
    /// the same pass because a bounded, joinable teardown makes an SRT swap safe to define, and
    /// WHEP's teardown is the one that cannot be joined (see the ORDER note in `SRTClient.disconnect`).
    /// Making web→web a swap is a real change to WHEP's lifecycle, not a side effect of arbitration.
    static func connectWeb(to url: URL) {
        retireActive(except: .web)
        clearBanners(except: .web)
        WHEPClient.shared.connect(to: url, arbitratedBy: Arbitration())
    }

    /// SRT.
    ///
    /// NOTHING IS EXCEPTED — not even `.srt`, and that is the whole point. A second SRT connect is a
    /// SWAP, on the same full-replacement rule a stream-over-file takeover already follows: the old
    /// session is torn down completely and the new one stood up fresh, with no state carried across.
    /// `SRTClient.connect` used to refuse this case; the refusal is gone, and what makes its removal
    /// safe is the line below rather than anything inside the client. `SRTClient.disconnect()` joins
    /// the session thread, so by the time `connect` runs the old session is provably finished — not
    /// merely asked to stop.
    static func connectSRT(to url: URL) {
        retireActive()
        clearBanners(except: .srt)   // SRT clears its own via `retireError` on the next line but one
        SRTClient.shared.connect(to: url, arbitratedBy: Arbitration())
    }
}
