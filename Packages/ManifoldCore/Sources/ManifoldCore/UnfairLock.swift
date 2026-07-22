import os

/// Copy-safe wrapper around `os_unfair_lock`. The primitive is a struct that MUST NOT be copied —
/// a by-value copy is a DISTINCT lock and fails silently — so we heap-allocate exactly one
/// `os_unfair_lock` in init and only ever touch it through this class's stable pointer. Reference
/// semantics mean assigning or capturing the lock can never duplicate the primitive.
///
/// WHY NOT `NSLock`. `NSLock` is a `pthread_mutex`, which does NOT boost its holder's priority.
/// Every lock in this codebase that is taken on the real-time `CVDisplayLink` render thread AND on
/// a lower-priority producer thread is therefore an unbounded priority inversion waiting to happen:
/// the low-priority thread can be descheduled while holding the lock, and the render thread blocks
/// behind it with no mechanism to help it along. `os_unfair_lock` DONATES the waiting thread's
/// scheduling priority to the holder, so the holder is boosted only while holding and releases
/// promptly — which is what dissolves the inversion.
///
/// USAGE RULE — NEVER HOLD THIS ACROSS ANYTHING SLOW. Donation boosts the holder rather than
/// parking the waiter, so a long hold burns real-time priority instead of yielding it, which is
/// worse than the inversion it replaced. No I/O, no logging, no `String(format:)`, no allocation
/// inside a critical section: snapshot the scalars you need, unlock, THEN format and emit.
///
/// WHY IT LIVES IN ManifoldCore. It is used by `LiveClock` here and by the App layer's renderer and
/// WHEP router. App depends on ManifoldCore and never the reverse, so the shared primitive belongs
/// at the bottom of that dependency — one definition, no duplication. (It previously lived in
/// App/MetalVideoRenderer.swift; hoisting it here rather than copying it is deliberate, because two
/// copies of a lock wrapper is exactly how they drift apart.)
///
/// Exposes the same `lock()`/`unlock()` surface as `NSLock`, so call sites are unchanged.
public final class UnfairLock {
    private let _lock: os_unfair_lock_t

    public init() {
        _lock = .allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }

    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }

    @inline(__always) public func lock()   { os_unfair_lock_lock(_lock) }
    @inline(__always) public func unlock() { os_unfair_lock_unlock(_lock) }
}
