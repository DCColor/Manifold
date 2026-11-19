//
//  PlaybackCounters.swift
//  Manifold
//
//  Process-wide playback counts for Export Diagnostics (Help ▸ Export Diagnostics…, section PLAYBACK COUNTERS), in every build.
//  Counts only, no behavior: each is one increment under a leaf lock, made in the branch that already detects the event (a missed
//  pacer deadline; a card hold during steady play, `CardHoldFilter`). Nothing reads them on a hot path. Since launch, so one
//  soak block (one launch) is one set of counts. The same text is printed once when DeckLink output stops (`logLine`), so a soak
//  can check the export's numbers against its log without driving the export's save panel.
//
//  Late swaps by class are NOT here: the classifier (`LateSwapClassifier`) runs only in the DEBUG card-pull measurement
//  (`MANIFOLD_DECKLINK_CADENCE_LOG=2`). Renderer recoveries are `RendererRecoveryStats` (ManifoldCore), repeated here for reading.
//

import Foundation
import ManifoldCore

enum PlaybackCounters {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pacerMissedDeadlines = 0
    nonisolated(unsafe) private static var cardHoldsWhilePlaying = 0

    /// The output pacer's thread, in its missed-deadline branch: the deadlines that tick skipped (`OutputPacer.loop`).
    static func addPacerMissedDeadlines(_ n: Int) {
        guard n > 0 else { return }
        lock.lock(); pacerMissedDeadlines += n; lock.unlock()
    }

    /// The card's fill callback, `deckLinkLock` held (this lock is a leaf under it): holds that `CardHoldFilter` (OutputPacing)
    /// confirmed on this pull. Counted: at a matched rate, a timed pull after a timed pull handed the same frame again, more than
    /// `CardHoldFilter.settle` (1 s) after the last untimed pull, and a later timed pull then handed a newer frame. Timed means
    /// playing at 1×: a Play from a pause, a step, a seek, a loop's wrap or a shuttle makes a pull untimed
    /// (`MetalVideoRenderer.deckLinkPullSlotLocked`). So the opening repeats after Play or a seek, the last frame repeated at the end
    /// of the file, and a rate mismatch's cadence are not counted, and a normal session reads 0 (0.9.5; night 5 read 40–120 per block
    /// before, docs/CARD_PULL_MARGIN.md §18.4 D).
    static func addCardHoldsWhilePlaying(_ n: Int) {
        guard n > 0 else { return }
        lock.lock(); cardHoldsWhilePlaying += n; lock.unlock()
    }

    static var snapshot: (pacerMissed: Int, cardHolds: Int) {
        lock.lock(); defer { lock.unlock() }
        return (pacerMissedDeadlines, cardHoldsWhilePlaying)
    }

    /// The export's lines.
    static var lines: [String] {
        let s = snapshot
        return [
            "Pacer missed deadlines : \(s.pacerMissed) (output pacer deadlines skipped because a tick ran past them, since launch)",
            "Card holds while playing: \(s.cardHolds) (SDI repeated a frame during steady 1× play at a matched rate, since launch; "
                + "not counted: the first 1 s after Play, a seek, a step or a loop wrap, the end of the file, a rate mismatch's cadence)",
            "Late swaps by class    : not counted in this build (the DEBUG card-pull measurement only)",
            "Renderer recoveries    : \(RendererRecoveryStats.summary)",
        ]
    }

    /// One line for the log, printed when DeckLink output stops: the export's numbers.
    static var logLine: String {
        let s = snapshot
        return "[DIAG] playback counters since launch (as in Export Diagnostics): pacer missed deadlines \(s.pacerMissed) · "
            + "card holds while playing \(s.cardHolds) · renderer \(RendererRecoveryStats.summary)"
    }
}
