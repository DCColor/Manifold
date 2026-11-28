//
//  ConnectionLossWatch.swift
//  Manifold — when a live connection that had started counts as lost (docs/BUGS.md, 0.9.6 UI polish, batch 2 fix 3).
//
//  NDI says nothing when its sender goes away: FrameSync keeps handing out the last frame, so the picture froze, the antenna
//  stayed green and no banner appeared. SRT and WHEP end the session and say so. NDI's receiver does report how many senders
//  it is connected to (`NDIlib_recv_get_no_connections`, "normally 0 or 1"), and this watch turns that count into the same
//  event: a connection that was up, then held at zero for `grace` seconds, is lost.
//
//  The grace is SRT's peer-idle timeout (libsrt's 5 s default, set explicitly in SRTSession.m), so a dropped NDI sender is
//  reported on the same clock a dropped SRT one is. It is not tuned from any one sender's behavior: a count that returns
//  inside it (a brief network drop NDI rides through by itself) is not a loss.
//
//  A receiver that has never connected is not watched: that is a connect failure, reported where the connect happens.
//

public struct ConnectionLossWatch: Equatable, Sendable {

    /// Seconds the count must stay at zero, after having been above it, before the connection counts as lost.
    public static let defaultGrace: Double = 5

    public let grace: Double

    /// The count has been above zero at least once since `init`.
    public private(set) var hasConnected = false
    /// When the count last fell to zero, while it stays there. nil while connected, or before the first connection.
    public private(set) var zeroSince: Double?
    /// `observe` has already returned true; it does so once.
    public private(set) var hasReportedLoss = false

    public init(grace: Double = ConnectionLossWatch.defaultGrace) {
        self.grace = grace
    }

    /// Feed the receiver's connection count, read at `now` (seconds, any monotonic clock). True exactly once: on the first
    /// reading at which a started connection has been at zero for `grace` seconds.
    public mutating func observe(connections: Int, now: Double) -> Bool {
        guard !hasReportedLoss else { return false }
        if connections > 0 {
            hasConnected = true
            zeroSince = nil
            return false
        }
        guard hasConnected else { return false }
        let since = zeroSince ?? now
        zeroSince = since
        guard now - since >= grace else { return false }
        hasReportedLoss = true
        return true
    }
}
