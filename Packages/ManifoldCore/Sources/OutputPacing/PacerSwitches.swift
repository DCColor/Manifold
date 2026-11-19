//
//  PacerSwitches.swift
//  OutputPacing
//
//  The 0.9.5 defaults of the output pacer's two DEBUG switches, and the rule Export Diagnostics uses to count card holds while
//  playing. Pure: the app reads the environment once and hands the values here, so the defaults are testable.
//
//  Decided 2026-11-19 (docs/CARD_PULL_MARGIN.md §18; docs/WINDOW_PRESENT_PATH.md §6, the attended checks on the LG):
//    • `MANIFOLD_PACER_PHASE`: unset means C+ (2). `=0` turns the phase hold off, `=1` is plain option C, `=2` is C+.
//    • `MANIFOLD_PACER_PRESENT_TX`: unset means today's transactional present. Only `=0` selects option B, a DEBUG experiment:
//      it froze the window for ~1 s on a Display Transform switch to Reference while SDI played (docs/BUGS.md).
//

import Foundation

public enum PacerSwitches {
    /// What `MANIFOLD_PACER_PHASE` selects. Unset, empty or anything unrecognised: C+ (2), the 0.9.5 default.
    public static func phaseMode(_ value: String?) -> Int {
        switch value {
        case "0": return 0
        case "1": return 1
        default: return 2
        }
    }

    /// Whether `MANIFOLD_PACER_PRESENT_TX` selects option B's untransacted pacer presents. Only `"0"` does; unset is today's path.
    public static func presentUntransacted(_ value: String?) -> Bool { value == "0" }
}

/// Export Diagnostics' "card holds while playing": which timed card pulls that hand the frame handed last are counted.
///
/// Counted: at a matched rate, a timed pull, after a timed pull, that hands the same frame again, and only once a later timed pull
/// has handed a newer frame (playback went on past it). Not counted:
///   • the first `settle` seconds after an untimed pull, which is how a pull sees a Play from a pause, a seek, a step, a loop's wrap
///     or a shuttle (the opening repeats: night 5 had 16–20 per block, all on the 2nd or 3rd timed pull after one,
///     docs/CARD_PULL_MARGIN.md §18.4 D). `settle` is the soak gate's own exclusion after a transport event (`rc-soak-report.py` EXCL);
///   • repeats still pending when an untimed pull comes (the end of the file: the clock runs past the last frame and stops, and the
///     card repeats the last frame until it does; night 5 had 40–100 per block);
///   • a rate mismatch, where repeats are the cadence.
/// Mutated under the renderer's `deckLinkLock` only.
public struct CardHoldFilter: Sendable {
    public static let settle = 1.0

    private var runStartHost = -Double.infinity
    private var pending = 0
    private var lastHandedPts = Double.nan
    private var lastTimed = false

    public init() {}

    /// One pull, after its selection. Returns the holds this pull confirms (to add to the counter), usually 0.
    public mutating func pull(host: Double, timed: Bool, pts: Double, matched: Bool) -> Int {
        defer { lastHandedPts = pts; lastTimed = timed }
        guard timed else { pending = 0; runStartHost = host; return 0 }
        guard pts.isFinite else { pending = 0; return 0 }   // nothing judged: a pending repeat is dropped, not carried
        guard lastTimed, lastHandedPts.isFinite else { return 0 }
        if pts == lastHandedPts {
            if matched, host - runStartHost > Self.settle { pending += 1 }
            return 0
        }
        let confirmed = pending
        pending = 0
        return confirmed
    }
}
