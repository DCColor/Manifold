//
//  SavedDisplayProviders.swift
//  DisplayProviders
//
//  The one save/restore of a video renderer's file-path providers, shared by every live source
//  that takes the display: the push sources through LiveDisplayRoute, and NDI and HLS directly.
//
//  ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
//
//  A live source repoints three providers on the window's renderer: `clock`, `isPausedProvider`
//  and `isFullRangeProvider`. The file path installs its own once, at window setup
//  (`WindowDeck.configure`), and nothing reinstalls them when a file loads. So a source that
//  does not put them back leaves the NEXT file clocked by the departed stream.
//
//  NDI and HLS did exactly that from the day they were written (6952b98, 2026-07-14). The clock
//  they left behind is host time since boot, which is later than any file PTS, so the renderer's
//  "newest frame with pts <= now" picked the newest QUEUED frame on every tick: the picture ran
//  ahead of the audio by the reader's queue — measured +195 ms at the device, 2026-09-28 — landing
//  on whichever display tick followed its arrival. The same leak left the paused view after a
//  seek reading "not paused" and a full-range file expanded as video range. docs/BUGS.md,
//  "NDI and HLS leave the renderer's clock installed after disconnect".
//
//  ── WHY A LEAF TARGET ──────────────────────────────────────────────────────────────────
//
//  The renderer and the sources are app code, which `swift test` cannot reach. The discipline
//  that went wrong is small and pure, so it lives here over a protocol, and its tests replay an
//  NDI-shaped session against a stand-in renderer.
//
//  ── MAIN THREAD ONLY ───────────────────────────────────────────────────────────────────
//
//  Every caller saves and restores on main. Not asserted here, so the tests can run it directly;
//  the callers assert.
//
//  ── AND THE ONE PLACE A LIVE SOURCE'S COLOUR IS FORGOTTEN ──────────────────────────────────
//
//  `restore()` is the only point every live teardown passes through: NDI and HLS call it directly,
//  SRT and WHEP through `LiveDisplayRoute.deactivate`, and every error, watchdog and stall path of
//  those clients ends in their `disconnect()`, which reaches it. So it is also where the departed
//  stream's source colour is cleared — the live twin of `FrameEngine.stop()` publishing nil codes.
//  Without it the renderer, the chain readout and the scope headers went on describing a stream
//  that was gone. A source SWITCH (NDI's, HLS's) holds its save and does not come through here,
//  which is right: the incoming source states its own colour at once.
//

/// The three renderer providers a live source replaces, and the colour state it leaves behind.
/// `MetalVideoRenderer` conforms in the app.
public protocol DisplayProviderHost: AnyObject {
    var clock: (() -> Double)? { get set }
    var isPausedProvider: (() -> Bool)? { get set }
    var isFullRangeProvider: (() -> Bool)? { get set }
    /// The live source that held this renderer has let go: forget its source colour.
    func liveSourceReleased()
}

/// Providers saved when a live source takes a renderer, restored VERBATIM when it lets go.
public final class SavedDisplayProviders<Host: DisplayProviderHost> {

    private var clock: (() -> Double)?
    private var isPaused: (() -> Bool)?
    private var isFullRange: (() -> Bool)?
    private var holding = false

    /// WHICH RENDERER THE PROVIDERS CAME FROM. Weak: an identity record, not ownership, so a closed
    /// window's renderer is not kept alive by it.
    ///
    /// ⚠️ THE RESTORE GOES HERE, NOT TO WHATEVER RENDERER THE CALLER HOLDS AT RELEASE. The saved
    /// closures capture one window's engine. Restoring them onto another window's renderer would
    /// clock that window's picture by the first window's synchronizer — silent, and it presents
    /// as "window B stutters sometimes". (LiveDisplayRoute's `savedRenderer`, now this.)
    public private(set) weak var host: Host?

    public init() {}

    /// A save is held and its renderer is still alive.
    public var isHolding: Bool { holding && host != nil }

    /// Take the host's current providers, unless a save is already held.
    ///
    /// ⚠️ A SECOND SAVE WHILE HOLDING IS A NO-OP, AND THAT IS THE POINT. NDI's source switch and
    /// HLS's swap re-enter their start path while still connected. Saving again there would save
    /// the stream's OWN providers as "the file's", and the eventual restore would put the stream
    /// clock back — the leak this type exists to close, reintroduced one level down.
    ///
    /// Returns whether it saved.
    @discardableResult
    public func save(from newHost: Host) -> Bool {
        if isHolding { return false }
        clock = newHost.clock
        isPaused = newHost.isPausedProvider
        isFullRange = newHost.isFullRangeProvider
        host = newHost
        holding = true
        return true
    }

    /// Put the saved providers back on the renderer they came from, forget them, and tell that
    /// renderer its live source has gone (`liveSourceReleased`, once).
    ///
    /// Returns that renderer, or nil when nothing was held (never saved, already restored, or the
    /// renderer is gone). A nil return has written NOTHING — a stray second call must not un-clock
    /// a renderer that is minding its own business, nor clear the colour of whatever it shows.
    @discardableResult
    public func restore() -> Host? {
        defer {
            clock = nil
            isPaused = nil
            isFullRange = nil
            holding = false
            host = nil
        }
        guard holding, let saved = host else { return nil }
        saved.clock = clock
        saved.isPausedProvider = isPaused
        saved.isFullRangeProvider = isFullRange
        saved.liveSourceReleased()
        return saved
    }
}
