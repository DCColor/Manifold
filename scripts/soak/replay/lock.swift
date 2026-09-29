import os
final class UnfairLockBox {
    private let l: os_unfair_lock_t
    init() { l = .allocate(capacity: 1); l.initialize(to: os_unfair_lock()) }
    func lock() { os_unfair_lock_lock(l) }
    func unlock() { os_unfair_lock_unlock(l) }
}
