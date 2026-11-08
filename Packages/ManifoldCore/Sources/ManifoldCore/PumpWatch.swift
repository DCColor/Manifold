//
//  PumpWatch.swift
//  ManifoldCore
//
//  ⚠️ PRE-SHIP REMOVAL (docs/BUGS.md, "remove the card-clock measurement hooks"). Measurement build only: `#if MANIFOLD_CARDCLOCK`.
//
//  The card-lock picture freeze (docs/CARD_CLOCK_FINDINGS.md §10.13): the video pump stops being called and nothing logs why. The pump has
//  three ways to go quiet, and this names which one a freeze took:
//    1. the pacing renderer stops calling back, or reports a status or error;
//    2. the pump parks on a full window queue (`VideoSinkGate`) and is never woken;
//    3. the pump takes its end-of-stream branch, mid-file.
//  It also counts the two exits that are meant to be quiet (a superseded session, a released libav source), so a freeze that takes one of
//  those is not missed. The pump queue writes; the engine's watchdog on main reads (`FrameEngine.pumpWatchTick`).
//

#if MANIFOLD_CARDCLOCK
import Foundation
import QuartzCore

public final class PumpWatch: @unchecked Sendable {

    public enum Exit: String, Sendable {
        case notReady = "renderer not ready (waiting for its callback)"
        case parked = "parked on a full window queue"
        case endOfStream = "end-of-stream branch"
        case superseded = "superseded session"
        case released = "source released"
    }

    public struct Snapshot: Sendable {
        public var arms = 0
        public var callbacks = 0
        public var emitted = 0
        public var lastCallbackHost = 0.0
        public var lastEmitHost = 0.0
        public var lastEmitPTS = Double.nan
        public var lastExit: Exit?
        public var lastExitHost = 0.0
        public var parkedSince: Double?
        public var parks = 0
        public var resumes = 0
        public var endsOfStream = 0
        public var superseded = 0
        public var failedLogged = false
    }

    private let lock = NSLock()
    private var s = Snapshot()

    public init() {}

    public func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return s }

    /// A new session armed the renderer's request.
    public func armed() { lock.lock(); s.arms += 1; s.parkedSince = nil; lock.unlock() }

    /// The pump body was entered, from the renderer's callback or a gate resume.
    public func callback() { lock.lock(); s.callbacks += 1; s.lastCallbackHost = CACurrentMediaTime(); lock.unlock() }

    public func emitted(pts: Double) {
        lock.lock(); s.emitted += 1; s.lastEmitHost = CACurrentMediaTime(); s.lastEmitPTS = pts; lock.unlock()
    }

    /// The pump body returned. `detail` is logged with an end-of-stream exit, which is never quiet.
    public func exit(_ e: Exit, detail: @autoclosure () -> String = "") {
        let now = CACurrentMediaTime()
        lock.lock()
        s.lastExit = e; s.lastExitHost = now
        switch e {
        case .parked: s.parkedSince = now; s.parks += 1
        case .endOfStream: s.endsOfStream += 1
        case .superseded, .released: s.superseded += 1
        case .notReady: break
        }
        let pts = s.lastEmitPTS, emitted = s.emitted
        lock.unlock()
        if e == .endOfStream {
            print(String(format: "[PUMPWATCH] video pump took its end-of-stream branch and stopped requesting: %@ · last frame pts %.6f · %d frames emitted",
                         detail(), pts, emitted))
        }
    }

    /// A parked pump was woken. A park that lasted 1 s or more is logged: a running file's queue drains in a fifth of that.
    public func resumed() {
        let now = CACurrentMediaTime()
        lock.lock()
        let since = s.parkedSince
        s.parkedSince = nil; s.resumes += 1
        lock.unlock()
        if let since, now - since >= 1 { print(String(format: "[PUMPWATCH] video pump woken after %.2f s parked on a full window queue", now - since)) }
    }

    /// The renderer read `.failed` at a pump exit. Logged once per watch.
    public func noteFailed(_ describe: () -> String) {
        lock.lock(); let first = !s.failedLogged; s.failedLogged = true; lock.unlock()
        if first { print("[PUMPWATCH] pacing renderer status FAILED at a pump exit: \(describe())") }
    }
}
#endif
