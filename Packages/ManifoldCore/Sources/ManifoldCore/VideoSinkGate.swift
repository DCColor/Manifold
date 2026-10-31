//
//  VideoSinkGate.swift
//  ManifoldCore
//
//  THE DISPLAY QUEUE'S BACKPRESSURE ON A FILE'S DECODE PUMP (0.9.1, docs/BUGS.md, "A 119.95 fps iPhone clip plays audio but
//  the picture freezes").
//
//  A file's pump reads while the hidden pacing renderer `isReadyForMoreMediaData`, and that renderer buffers by TIME
//  (≈ 105–195 ms measured). The window's renderer keeps a queue bounded in FRAMES. At 96 fps and above the pacing lead
//  is more frames than the queue holds, and the queue made room by evicting its oldest frame: the next one due. Every
//  eviction pushed the queue further into the future until nothing was ever due, and the picture froze.
//
//  So the pump also asks the renderer's queue: while it is full, the pump PARKS instead of decoding, and the renderer
//  resumes it when it consumes a frame. A full queue then holds the frames about to come due, the clock reaches its
//  oldest, the tick takes it, and the pump runs again: nothing is evicted, at any frame rate, by construction.
//
//  One gate per engine, shared by whichever source is current: a retired session's resume runs its pump body, which
//  checks the session token and bows out, as it does for every other late callback.
//

import Foundation

public final class VideoSinkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRoomProvider: (() -> Bool)?
    private var parkedResume: (() -> Void)?

    public init() {}

    /// The renderer's answer to "may another frame be queued?". nil (no renderer wired) always has room.
    public func setHasRoom(_ provider: (() -> Bool)?) {
        lock.lock(); hasRoomProvider = provider; lock.unlock()
    }

    public var hasRoom: Bool {
        lock.lock(); let provider = hasRoomProvider; lock.unlock()
        return provider?() ?? true
    }

    /// Pump side, on the pump queue: the queue is full, so stop decoding until `roomAvailable`. Re-checks after parking,
    /// so room freed between the caller's check and the park is not missed (that would park the pump for good).
    public func park(resume: @escaping () -> Void) {
        lock.lock(); parkedResume = resume; lock.unlock()
        if hasRoom { roomAvailable() }
    }

    /// Renderer side, any thread: the queue lost a frame. Resumes a parked pump once; a no-op when none is parked.
    public func roomAvailable() {
        lock.lock(); let resume = parkedResume; parkedResume = nil; lock.unlock()
        resume?()
    }
}
