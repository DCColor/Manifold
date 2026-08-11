//
//  LiveDisplaySize.swift
//  Manifold
//
//  What SHAPE is the live picture — the one thing every live transport knows and none of them
//  used to say.
//
//  ── THE BUG THIS CLOSES ────────────────────────────────────────────────────────────────
//
//  `FrameEngine.displaySize` was written ONLY by the file paths (AVFoundation load, and
//  `applyLibavMetadata` for MXF). NDI, WHEP and SRT push decoded frames straight into the shared
//  renderer and never touched it, so for every stream it was nil (or, worse, still holding the
//  size of whatever file the deck had open before the takeover). Two things read it and both
//  degraded silently: `ContentView.videoAspect` fell back to 16:9, so the video rect — and with
//  it the framing guides and the caption overlay, which are attached to that rect — was laid out
//  for a 16:9 picture whatever the stream's real shape; and `WindowConfigurator` returned early,
//  so a streaming window got no aspect lock at all. The PICTURE was never stretched (the layer's
//  drawableSize comes from the pixel buffer), but the RECT was the wrong shape, and a portrait or
//  4:3 source was mis-framed. Invisible until now only because every stream tested had been 16:9,
//  which is exactly the fallback.
//
//  ── WHY ONE SHARED OBJECT AND NOT THREE HOOKS ──────────────────────────────────────────
//
//  `LiveSource` already guarantees AT MOST ONE live source app-wide, and `DeckRegistry` already
//  guarantees at most one deck the routers point at. So there is exactly one live frame size in
//  existence at any moment, and one place it belongs. Three per-router hooks would have been three
//  copies of the same latch and three install sites in `DeckRegistry.init`; this is one of each.
//
//  It is the SAME SEAM SHAPE as `onWillActivateStream`: the transports know a fact, they do not
//  know about decks or windows, and the registry — which does — is the one that routes it. Nothing
//  here imports the deck model, and nothing in the deck model imports a transport.
//
//  ── THREADING ──────────────────────────────────────────────────────────────────────────
//
//  `publish` is called from THREE DIFFERENT THREADS and that is the whole reason for the lock:
//  NDI's from the CVDisplayLink render thread (it is a pull source — see LiveSource), WHEP's from
//  its decode queue, SRT's from its session thread. `UnfairLock` and not `NSLock` for the reason
//  stated on that type: the render thread must never block behind an unboosted lower-priority
//  holder. The critical section is two comparisons and two stores — nothing slow, ever.
//
//  `clear` and `onChange` are MAIN THREAD ONLY, asserted.
//
//  ── THE ORDERING HAZARD, AND THE GENERATION COUNTER THAT CLOSES IT ─────────────────────
//
//  `publish` hops to main to deliver; `clear` already IS on main. So a size published a moment
//  before a disconnect can land AFTER the clear that was supposed to retire it, leaving a dead
//  stream's shape locked onto a window showing nothing. That is not hypothetical ordering
//  pedantry — it is the ordinary shape of every teardown, where the last frame and the disconnect
//  are microseconds apart on two threads.
//
//  `generation` is bumped by `clear`, captured by `publish` at the instant it latches, and checked
//  again on main before delivery. A hop that straddles a clear is dropped. A source that is still
//  running simply re-publishes on its next frame, because `clear` also drops the latched value.
//

import Foundation
import ManifoldCore   // UnfairLock — priority-donating, for the render-thread caller

final class LiveDisplaySize {

    static let shared = LiveDisplaySize()
    private init() {}

    /// Where a size goes once it is known. Installed ONCE, at app scope, by `DeckRegistry.init` —
    /// alongside the `onWillActivateStream` hooks, and for the same reason: the transports must not
    /// learn about decks. Assigned and invoked on MAIN only, which is what makes it lock-free.
    var onChange: ((CGSize?) -> Void)?

    private let lock = UnfairLock()
    /// The last size delivered, so the per-frame call costs one comparison and no hop. nil when
    /// nothing is live.
    private var published: CGSize?

    /// The shape currently on screen, or nil when no live source has stated one. ANY THREAD.
    ///
    /// For the deck that adopts the device hooks WHILE a source is running: `onChange` fires only
    /// on a change, so there is nothing for a late arrival to receive. See `attachDeviceHooks`.
    var current: CGSize? {
        lock.lock(); defer { lock.unlock() }
        return published
    }
    /// Bumped by `clear`. See the ordering note in the header.
    private var generation: UInt64 = 0

    /// ANY THREAD, once per delivered frame. Cheap and idempotent: a stream that has already
    /// published its size does one lock acquisition and one comparison per frame and nothing else.
    ///
    /// PER FRAME, NOT ONCE AT CONNECT, and that is deliberate — see the transport call sites. All
    /// three can change dimensions mid-stream (an H.264 SPS change on WHEP/SRT, a sender or source
    /// switch on NDI), so the size is a running fact, not a connect-time one.
    ///
    /// Non-positive dimensions are ignored rather than published as a degenerate size: `0` reaches
    /// `videoAspect` as a division and `contentAspectRatio` as the invalid geometry that trips
    /// AppKit's internal trap (see the `.zero` note in WindowConfigurator).
    func publish(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let size = CGSize(width: width, height: height)

        lock.lock()
        guard published != size else { lock.unlock(); return }
        published = size
        let stamp = generation
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation
            self.lock.unlock()
            // Straddled a clear — the source this size describes is already gone.
            guard current == stamp else { return }
            self.onChange?(size)
        }
    }

    /// The live source is gone: there is no picture, so there is no shape. MAIN THREAD, and
    /// delivered synchronously rather than through a hop, so it cannot itself be overtaken.
    ///
    /// Idempotent — every transport calls it on a teardown path that may already have run.
    func clear() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        generation &+= 1
        let hadSize = published != nil
        published = nil
        lock.unlock()
        guard hadSize else { return }
        onChange?(nil)
    }
}
