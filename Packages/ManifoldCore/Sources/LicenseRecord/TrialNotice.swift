//
//  TrialNotice.swift
//  LicenseRecord — the launch notice near the end of the trial (docs/BUGS.md, 0.9.6 UI polish item 34, batch 4).
//
//  Trial days left appeared only in Settings ▸ License, so nothing warned before "Your Manifold trial has ended." When 3
//  days or fewer are left, one window shows this once per launch, as a notice that hides on its timer.
//
//  Manifold's own trial (App/LicenseManager.swift, `TrialManager`), not a license rule: the shared client (`LicenseClient`,
//  ported from Graviton-Releases shared/license.js) has no trial and is not touched. The notice is asked for only in the
//  trial state, so a licensed key, a beta key (licensed, type Beta) and every other state never show it.
//

public enum TrialNotice {

    /// Notice from this many days left, down to the last day.
    public static let fromDaysLeft = 3

    /// "3 days left in your trial." / "1 day left in your trial.", or nil when more than `fromDaysLeft` are left or none
    /// are (an ended trial has its own screen).
    public static func text(daysRemaining: Int) -> String? {
        guard (1...fromDaysLeft).contains(daysRemaining) else { return nil }
        return daysRemaining == 1 ? "1 day left in your trial." : "\(daysRemaining) days left in your trial."
    }
}
