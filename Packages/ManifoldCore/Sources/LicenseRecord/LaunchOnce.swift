//
//  LaunchOnce.swift
//  LicenseRecord — a once-per-process gate for work that must run once per launch.
//
//  `LicenseManager.bootstrap` hangs off a `.task` on the WindowGroup's content, which runs once per WINDOW, and bootstrap had
//  no guard: a second window (or a restored window set) ran license startup again, with a second Keychain read and a second
//  Keychain prompt (docs/BUGS.md, "the launch update alert freezes the app until clicked, and license startup runs twice",
//  part C; 0.9.5 baseline soak, 2026-11-25). The stream-secret migration and the update check beside it already had a guard;
//  this is the same guard as a tested type.
//
//  It is Manifold's own startup plumbing, not a license rule: the shared client (`LicenseClient`, ported from
//  Graviton-Releases shared/license.js) is not touched, and what bootstrap decides is unchanged.
//

import Foundation

/// Hands out exactly one claim per instance. The first `claim()` returns true; every later one, from any thread, returns false.
///
/// The claim is taken BEFORE the work starts, not after it finishes, so two callers that arrive while the first is still
/// running (two windows opening together, each with its own `.task`) cannot both run it.
public final class LaunchOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    public init() {}

    /// True for the first caller only.
    public func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    /// Whether the claim has been taken.
    public var hasRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimed
    }

    /// Runs `body` for the first caller; later callers return at once, without waiting for it. Returns whether this call ran it.
    @discardableResult
    public func run(_ body: () async -> Void) async -> Bool {
        guard claim() else { return false }
        await body()
        return true
    }
}
