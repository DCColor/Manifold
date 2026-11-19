//
//  PlaybackCounters.swift
//  Manifold
//
//  Process-wide playback counts for Export Diagnostics (Help ▸ Export Diagnostics…, section PLAYBACK COUNTERS), in every build.
//  Counts only, no behavior: each is one increment under a leaf lock, made in the branch that already detects the event (a missed
//  pacer deadline; a timed card pull that handed the frame it handed last). Nothing reads them on a hot path. Since launch, so one
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

    /// The card's fill callback, `deckLinkLock` held (this lock is a leaf under it): a timed pull, after a timed pull, handed the
    /// same frame again. Timed means playing at 1×: a pause, a step, a seek, a loop's wrap or a shuttle makes a pull untimed
    /// (`MetalVideoRenderer.deckLinkPullSlotLocked`), so neither that pull nor the first timed pull after it is counted.
    static func noteCardHoldWhilePlaying() {
        lock.lock(); cardHoldsWhilePlaying += 1; lock.unlock()
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
            "Card holds while playing: \(s.cardHolds) (a timed card pull handed the frame it handed last, since launch)",
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
