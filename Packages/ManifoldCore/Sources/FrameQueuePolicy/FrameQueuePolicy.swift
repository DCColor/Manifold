/// Two decisions the renderer's frame queue makes about a PAUSED picture, kept here so `swift test` can pin them
/// (docs/BUGS.md, "a paused step or seek can come to rest one or two frames past its target").
///
/// The queue holds decoded frames in ascending presentation time. While a file is paused after a step or seek, the
/// oldest frame is the one the pinned clock is waiting for. Both rules below exist so that frame — and never a later
/// one — is what comes to rest on screen.
public enum FrameQueuePolicy {
    /// Which end of an over-full queue loses frames.
    public enum TrimEnd: Equatable {
        /// Drop the OLDEST: the backstop for a running clock (playback, every live source), where the oldest frames
        /// are the ones already past due, and where a live source's clock is re-anchored from the overflow.
        case oldest
        /// Drop the NEWEST: a paused file. The oldest frame is the one on screen next; the newest are future frames
        /// that matter only if play resumes.
        case newest
    }

    /// The end to trim when the queue has gone over its bound. `paused` is the renderer's paused provider, which every
    /// live route pins to false, so `.newest` is only ever a paused FILE.
    ///
    /// Measured 2026-10-16: on small, fast-decoding frames the pacing renderer accepts 13–15 frames in ~3 ms after a
    /// step, before any display tick has consumed the target. Trimming the oldest at 12 evicted the target itself,
    /// and the picture came to rest 1–3 frames late.
    public static func trimEnd(paused: Bool) -> TrimEnd { paused ? .newest : .oldest }

    /// Whether the paused-seek fallback may draw `nearestPts`, the earliest queued frame, when no queued frame is at
    /// or before the pinned clock `now`.
    ///
    /// The fallback exists for a seek whose first frame lands a FRACTION of a frame past the clock (libav's seek
    /// delivers the first frame at or after the time, so a mid-frame seek gets the next one). A frame a whole
    /// interval or more past the clock is never that: the frame at the clock has not arrived, and drawing the later
    /// one is the overshoot. So it is refused, and the caller waits. The interval is the queue's own, from its first
    /// two frames (`secondPts`); with a single frame queued there is nothing to judge by and it is allowed, as before.
    public static func relaxedRenderAllowed(nearestPts: Double, secondPts: Double?, now: Double) -> Bool {
        guard let second = secondPts else { return true }
        let interval = second - nearestPts
        guard interval > 0 else { return true }
        return nearestPts - now < interval - 1e-6
    }
}
