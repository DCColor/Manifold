//
//  LiveAudioResampleSteering.swift
//  LiveAudioResample
//
//  Build step 4d of docs/AUDIO_RESAMPLER_DESIGN.md §7: the 4c controller wired to the live path.
//  Per input buffer: a paired read of the timebase (§2.1), mapped to content time through the stage
//  (4a), against the session's target line (§2.8); one controller step (§2.2); the ratio into the
//  stage for the next block. Plus the one coarse branch (§2.4) and the session's only timebase
//  writer.
//
//  ── THE ONE WRITER ────────────────────────────────────────────────────────────────────────────
//
//  Every `setRate` a live-audio session makes after `beginLiveAudio`'s hold goes through `write`
//  here: the first anchor, a coarse event the splice cannot take (below), and — with the ratio
//  pinned — step 3's position branch and NDI's re-anchor. So the count this object logs IS the
//  session's rate-write count, and §7 step 5's "setRate rows with a non-zero rate == 1 per session"
//  can be read off one line rather than reconstructed from several.
//
//  ── THE COARSE BRANCH (§2.4, REVISED 2026-09-25) ──────────────────────────────────────────────
//
//  Two triggers, both on CONTENT-time error, never on the raw timebase — under a working loop the
//  timebase drifts from the target by design, so anything comparing it would fire on a correct
//  loop:
//
//    * level: |e_f| > 250 ms
//    * step:  |e_k − e_(k−1)| > 50 ms between consecutive accepted evaluations
//
//  ACTION (step 5): a SPLICE, never a rate write. The content moves by −e — a drop when the audio
//  is behind (a snap, freeze guard or queue-full moved the picture forward), an insert of repeated
//  material when it is ahead — across the stage's 10 ms equal-power fade, at the stage's input.
//  The output axis stays contiguous. `e_f` is reset and `i` held, exactly as before.
//
//  The splice is heard a renderer-queue later than it is requested. Until then the content heard
//  still carries the old error, so every read adds the stage's `spliceCorrectionAhead` — the part
//  requested and not yet heard. `content + ahead` is continuous through the moment the splice is
//  heard, so no settle window is needed after a splice: nothing was written.
//
//  ⚠️ TWO CASES STILL RE-ANCHOR, LOGGED AND COUNTED, WITH THE PRE-STEP-5 WRITE:
//    * |e| > `maximumSpliceSeconds` (1 s) — past it the material cannot hide the jump;
//    * a DROP larger than the renderer queue can cover (drop + fade + 50 ms > queue depth). A drop
//      feeds nothing for about its own length while the material it jumps to arrives; the renderer
//      plays that out of its queue. If the queue is shorter, the output axis falls behind the
//      timebase, every later buffer arrives late, and the loop — which reads what was ENQUEUED —
//      cannot see it. The events that cause drops over-fill the queue by the drop, so this is a
//      guard, not an expected path.
//  The write is placed so the content heard is the target (`outputTime(atInputTime: target)`),
//  moving the timebase alone, as step 4 did.
//
//  ── MATCHING (§2.4: an unmatched splice is a defect) ──────────────────────────────────────────
//
//  Callers report the events that move content: LiveClock's position jumps (snap-to-live,
//  freeze-guard, queue-full, target-step), an input axis RE-PINNED, the stage's own axis BREAK,
//  and on RTP audio a first SR pair that arrived after the gate gave up on it (the target moves by
//  the first offset).
//  Each splice or fallback takes the newest unconsumed one from the `matchWindowSeconds` before it,
//  and its line names it; with none it says WARNING. LiveClock reports a jump BEFORE it publishes
//  the moved mapping, so the event always precedes the step it causes; the window only has to
//  cover the time from the event to the read that sees it.
//
//  ── THE SETTLE WINDOW ─────────────────────────────────────────────────────────────────────────
//
//  `setRate(_:time:atHostTime:)` updates the rate synchronously and the TIMEBASE asynchronously
//  (see `FrameEngine.LiveAudioRendererState`). A read taken in between still sees the old axis, and
//  the next one the new — which is a step, and would fire a second, reverse coarse event on the
//  write the first one made. So after every WRITE (the anchor, a fallback) the loop ignores
//  `settleSeconds` of reads: no controller step, no trigger, and the first read after it seeds `e_f`
//  afresh. The figure is a bound on that window, not a measurement of it; the reads it discards are
//  counted. A splice writes nothing and takes no settle window.
//
//  ── THE RAIL TRIPWIRE (step 7) ────────────────────────────────────────────────────────────────
//
//  The slew-site tripwires in `LiveClock` used to watch for the video slew pinned at unity, because
//  that slew was audio's drift corrector. Since step 4d this ratio is, and what matters is ρ sitting
//  at its own ±B rail: the target is then moving faster than the audio may follow, and lip-sync
//  error grows (up to 3 ms/s against LiveClock's ±0.5% rail) until the rail releases or the 250 ms
//  level trigger splices. Measured three times so far, 20–70 s at the rail each (§13.4, §15.3,
//  §16.6). The loop is doing all it may, so this is a log, not an action:
//
//    * `⚠️ RATIO AT ITS RAIL` once |ρ−1| has been at B for `railDwellSeconds` (5 s) without a break;
//    * `ratio OFF its rail` when it leaves, if the first was logged, with the time and peak |e|;
//    * at most one ENTER line per `railRewarnSeconds` (60 s): an episode inside that is counted, not
//      logged. So two lines per minute at most, and none for a touch shorter than 5 s.
//  Episodes, suppressed episodes and seconds at the rail are on the session END line.
//
//  ── THE STARVATION HOLD (option A, docs/AUDIO_RESAMPLER_DESIGN.md §18.16) ──────────────────────
//
//  The renderer's queue is only as deep as the audio's ARRIVAL LEAD over the timebase (§18.14),
//  and nothing above reads it between enqueues: a delivery stall longer than that lead ran the
//  renderer dry, and every refill then landed behind the playhead and was dropped whole — exact
//  zero, for as long as the sender took to catch up (33 s after a 2 s stall). So:
//
//    * HOLD: a one-shot host-time deadline, re-armed on every enqueue at the moment the queue would
//      fall to `starvationMarginSeconds`. It fires only if no input arrived before then, i.e. only
//      when the renderer is about to run dry. The timebase is then held (rate 0) where it stands.
//    * RESUME: on the first enqueue that leaves `resumeFillSeconds` queued past the held point. No
//      classification of the sender's refill (§18.19: a rate threshold tuned to one sender's refill
//      profile cannot separate a burst from a slow catch-up). The timebase restarts (rate 1.0) at the LATEST content that still leaves that fill queued, and
//      never later than the target: a burst redelivery resumes on the target (the outcome a dry
//      renderer reached, minus its drops), a sender that is still late resumes late.
//    * RECOVERY (REVISED 2026-09-30, §18.19): what the resume could not reach is `recoveryOffset`,
//      D: the target line the loop steers to is the line less D, so the loop sees no step. While D
//      is owed it is RE-MEASURED against the line on every read (line − content heard), so a line
//      LiveClock moves during the catch-up changes the debt rather than leaving the audio early
//      when it is repaid. It is taken back by forward splices (the step-5 drop) from the queue past
//      `recoveryKeepSeconds` plus the drop guard, by ONE of two rules, on the picture:
//        - the picture is on the line (`Mapping.pictureLate` ≤ 50 ms), or closing on it fast enough
//          to arrive within `recoveryHorizonSeconds`: ONE CUT of the whole debt, as soon as the
//          queue holds it (a burst or a fast catch-up);
//        - the picture is late and staying late (a slow catch-up, ffmpeg's 1.05×): cuts of ≥
//          `recoveryTrackingSeconds` that keep the audio with the late PICTURE, since the audio the
//          line would need has not arrived. 100 ms late is inside the late-audio detectability
//          threshold (~125 ms, ITU-R BT.1359).
//      Under `recoveryFoldSeconds` D is handed to the loop as ordinary error.
//    * CATCH-UP WRITE (option 2, Robbie 2026-09-30): when the whole debt is in the queue within
//      `catchUpWindowSeconds` of the restart (a burst arrived just after it) AND it exceeds
//      `catchUpWriteSeconds` (125 ms, the late-audio detectability threshold), it is taken by ONE
//      timebase write onto the line instead of a cut. A cut is heard only after the late queue in
//      front of it plays out, which after a burst holds the whole debt: the audio would sit D
//      behind the picture for about D. The write costs a renderer mute (~50 ms, §11.11, accepted);
//      a debt under 125 ms, or one that arrives later, is still a cut.
//    * RESIDUAL: for `residualWatchSeconds` after the debt is repaid (or after a resume that owed
//      nothing), a splice takes an |e_f| over `residualSpliceSeconds` instead of the ratio crawling
//      it back at 2 ms/s. It repeats, `residualSpacingSeconds` apart, while LiveClock keeps moving
//      its line after the stall (its rail is 0.5 %, the ratio's 0.2 %), and each one extends the
//      watch, so it closes 60 s after the line has settled.
//  Two writes per starvation episode (hold, resume), three when a catch-up write is taken, all
//  counted with the others; the cuts and the residual splices write nothing. On a stream whose queue never falls to the margin the deadline
//  never fires, D stays 0, no watch opens, and the loop is identical to the one without this. Loop
//  mode only: pinned is step 3 exactly.
//
//  ── THE PER-SOURCE AUDIO OFFSET O (docs/AUDIO_RESAMPLER_DESIGN.md §19.1, stage A) ─────────────
//
//  O > 0 = the audio is heard O LATER. O is IN THE LINE, not a separate steering term: every line
//  handed in (`setReference`, `anchor`) is stored as `media − O`, so D (re-measured against the
//  line, §18.19), the resume and the catch-up write all see it, and D never absorbs it. It is held
//  HERE, not subtracted by the caller, because the caller computes its line on the mapping thread
//  while a change arrives from another: a line computed with the old O landing after the change
//  would step the line back by ΔO and fire the step trigger. Under `lock` the move and the line
//  write are one.
//
//  A change (`setUserOffset`) moves the line by −ΔO and requests the splice of −ΔO in the same
//  step, under `transition`: content + ahead − target is continuous, so e does not step, ρ does not
//  move, no trigger fires and nothing is written. Delay (O up) is an insert; advance (O down) is a
//  drop, taken only if the queue holds it plus the recovery guard (keep + fade + margin), and
//  otherwise REFUSED whole, with the most available now. One splice per change, never chained:
//  the range keeps every change inside the stage's bounds. Pinned mode has no O (step 3 exactly).
//
//  ── PINNED MODE — THE BACK-OUT SWITCH ─────────────────────────────────────────────────────────
//
//  `.pinned` is step 3, exactly: the ratio stays at 1.0, the controller is never stepped, and the
//  coarse branch is off, because the caller's pre-4d 10 ms position branches are back on and write
//  through `reanchor`. The error is still measured and logged, so the two modes read on the same
//  line format and can be A/B'd from the log alone.
//

import Foundation

/// What the steering needs from the stage, as a seam so the trigger and write-count tests can
/// drive the law against loop_sim.py's plant without resampling audio. Internal: the stage is the
/// only conformer outside tests, and `rho` must not become settable from ManifoldCore.
protocol LiveAudioContentClock: AnyObject {
    func inputTime(atOutputTime outputSeconds: Double) -> Double
    func outputTime(atInputTime inputSeconds: Double) -> Double
    var rho: Double { get set }
    func requestSplice(contentSeconds: Double) -> LiveAudioResampleStage.SpliceGrant?
    func spliceCorrectionAhead(ofOutputTime outputSeconds: Double) -> Double
}

extension LiveAudioResampleStage: LiveAudioContentClock {}

public final class LiveAudioResampleSteering: @unchecked Sendable {

    public enum Mode: String, Sendable {
        /// Step 4: the ratio carries the correction; the coarse branch is the only other writer.
        case loop = "LOOP"
        /// Step 3: ratio 1.0, controller idle, coarse branch off; the caller's 10 ms branches write.
        case pinned = "PINNED 1.0"
    }

    public struct Thresholds: Sendable, Equatable {
        /// §2.4 level trigger on |e_f|, seconds.
        public var level: Double
        /// §2.4 step trigger on |e_k − e_(k−1)|, seconds.
        public var step: Double
        /// Reads ignored after a write while the timebase takes the new anchor, seconds.
        public var settle: Double
        public init(level: Double, step: Double, settle: Double) {
            self.level = level; self.step = step; self.settle = settle
        }
        /// §2.4's figures. The settle is a bound, not a measurement (see the header).
        public static let adopted = Thresholds(level: 0.250, step: 0.050, settle: 0.25)
    }

    public enum Trigger: String, Sendable { case level, step }

    /// Why the timebase was written. Carried to the caller's rate-log row and counted here.
    public enum WriteOrigin: Sendable, Equatable {
        /// The session's first anchor (the gate, or NDI's first pull).
        case firstAnchor
        /// §2.4's coarse branch, on the one path a splice cannot take (see the header).
        case coarse(Trigger, errorSeconds: Double)
        /// A deliberate re-anchor by the caller: a pinned-mode position branch, NDI's pinned
        /// re-anchor or a Desktop Audio Lead change, or the anchor after a clock reset.
        case reanchor(String)
        /// The starvation hold's restart (§18.16), after `pausedSeconds` held at rate 0. The hold
        /// itself is the `hold` closure's rate-0 write, not this one.
        case starvationResume(pausedSeconds: Double)
        /// The starvation recovery's catch-up write (§18.19): a debt over 125 ms that arrived whole
        /// within 1 s of the restart, placed onto the line in one write.
        case starvationCatchUp(debtSeconds: Double)

        public var label: String {
            switch self {
            case .firstAnchor: return "FIRST ANCHOR — the session's rate write"
            case let .coarse(t, e):
                return String(format: "COARSE RE-ANCHOR — splice fallback (%@, e %+.1f ms)",
                              t.rawValue, e * 1000)
            case let .reanchor(why): return "re-anchor (\(why))"
            case let .starvationResume(p):
                return String(format: "STARVATION RESUME after %.0f ms held", p * 1000)
            case let .starvationCatchUp(d):
                return String(format: "STARVATION CATCH-UP — %.0f ms debt onto the line in one write", d * 1000)
            }
        }
    }

    /// One tightly paired timebase read (§2.1): two host reads bracketing it. Handed on to the
    /// step-2 paired probe so the timebase is read once per buffer, not twice.
    public struct PairedRead: Sendable {
        public let t0: Double
        public let timebase: Double
        public let t1: Double
    }

    /// §2.1: a read pair spanning more than this is scheduling, not clocks.
    public static let pairingGateSeconds = 200e-6
    public static let windowSeconds = 10.0
    /// Longest `dt` one evaluation may claim. A stalled pump must not hand the integrator or the
    /// slew limiter a second of authority in one step.
    static let maximumStepSeconds = 0.25

    /// How far back from a splice its event may lie. The longest legitimate path from an event to
    /// the read that sees it: a preceding drop, which feeds nothing — so takes no reads — for up to
    /// its own length (≤ 1 s, `maximumSpliceSeconds`); then a settle window if a fallback wrote
    /// (0.25 s); then one input buffer, with room for a bursty one (0.25 s). Events are rare — none
    /// fired in ~5 h of the saved step-4 sessions — so a wide window costs no false matches.
    public static let matchWindowSeconds = 1.5
    /// A drop may take at most the renderer queue less its fade and this margin — one late buffer.
    static let dropQueueMarginSeconds = 0.050
    /// The rail tripwire (see the header): how long ρ must sit at ±B before it is logged, and the
    /// shortest interval between two ENTER lines. 5 s is a quarter of the shortest measured field
    /// episode, and long enough that ρ merely touching B on its way elsewhere does not log.
    static let railDwellSeconds = 5.0
    static let railRewarnSeconds = 60.0

    // ── The starvation hold (§18.16; see the header) ──────────────────────────────────────────────
    /// Queue left when the hold fires. As SMALL as the deadline's lateness (a strict timer, ≤ 1 ms
    /// typical) and the rate write's landing allow, because every hold costs two rate writes and
    /// the renderer mutes ~50 ms on each (§11.11): a larger margin holds on stalls the queue would
    /// have ridden out. The lowest healthy window measured on any transport is ~106 ms after the
    /// enqueue (§18.16), so a stream that is not stalling never comes near it.
    public static let starvationMarginSeconds = 0.020
    /// Queue required past the held point before the timebase restarts: one refill's worth, so a
    /// trickle does not restart and re-hold on every packet.
    public static let resumeFillSeconds = 0.100
    /// The catch-up write (see the header): taken only for a debt over this, which is the late-audio
    /// detectability threshold (~125 ms, ITU-R BT.1359). Below it a cut is inaudible as lip-sync.
    static let catchUpWriteSeconds = 0.125
    /// …and only when the whole debt is in the queue this soon after the restart: a burst. Later
    /// arrivals are a slow catch-up, whose cuts are small and heard soon.
    static let catchUpWindowSeconds = 1.0
    /// Queue a recovery drop must leave behind, on top of the drop guard (fade + 50 ms).
    static let recoveryKeepSeconds = 0.100
    /// While the picture stays late: cut when the audio is this far behind the PICTURE (the
    /// late-audio detectability threshold is ~125 ms), and no smaller. Also the smallest partial cut.
    static let recoveryTrackingSeconds = 0.100
    /// The picture counts as ON the line when it is no later than this (about a frame, plus the
    /// mapping's 100 ms cadence at a 50 ms/s catch-up).
    static let pictureOnLineSeconds = 0.050
    /// A picture that will reach the line within this, at its measured catch-up rate, is treated as
    /// on it: the audio waits for the whole debt rather than tracking a picture about to jump.
    static let recoveryHorizonSeconds = 1.0
    /// The picture's catch-up rate is measured over this, from the first mapping after a resume.
    static let pictureRateWindowSeconds = 0.5
    /// The picture on the line but the whole debt still not in the queue after this: take what is.
    static let recoveryPartialGraceSeconds = 1.0
    /// After a cut of x, the next waits x + this: the queue drains by x while the drop's material
    /// arrives, and the frontier the next decision reads does not show it until then.
    static let recoveryCutSettleSeconds = 0.25
    /// A recovery offset this small is handed to the loop as ordinary error (≈ 10 s at the rail).
    static let recoveryFoldSeconds = 0.020
    /// The residual splice (see the header): taken once |e_f| exceeds this inside the watch.
    static let residualSpliceSeconds = 0.020
    static let residualWatchSeconds = 60.0
    /// Between two residual splices: the last is heard (a queue, ≤ 0.5 s) and the filter refilled.
    static let residualSpacingSeconds = 2.0

    // ── The per-source audio offset O (§19.1; see the header) ─────────────────────────────────────
    /// THE range of O, seconds (Robbie, 2026-10-01). Every change is one splice inside the stage's
    /// bounds: an insert ≤ 0.75 s (bound 1 s), a drop ≤ 0.75 s (bound 4 s).
    public static let userOffsetRange: ClosedRange<Double> = -0.250...0.500
    /// How far back the advance figure looks for the queue's low point: the steering's window.
    static let advanceQueueWindowSeconds = 10.0
    private static let queueHistoryCapacity = 4096

    public let mode: Mode
    private let tag: String
    private let reportsWindows: Bool
    private let clock: LiveAudioContentClock
    private let gains: LiveAudioResampleController.Gains
    private let thresholds: Thresholds
    private let readTimebase: @Sendable () -> Double
    private let hostNow: @Sendable () -> Double
    private let write: @Sendable (_ outputSeconds: Double, _ hostSeconds: Double,
                                  _ origin: WriteOrigin) -> Void
    /// `setRate(0, time: outputSeconds, atHostTime: hostSeconds)`: the starvation hold's write.
    /// nil disables the hold (tests of the pre-§18.16 law, and any caller that cannot stop).
    private let holdWrite: (@Sendable (_ outputSeconds: Double, _ hostSeconds: Double) -> Void)?
    /// Arms the one-shot deadline: call `starvationCheck()` at host time `at` unless re-armed first.
    /// nil = no timer (tests call `starvationCheck()` themselves).
    private let armDeadline: (@Sendable (_ at: Double) -> Void)?
    private let log: (@Sendable (String) -> Void)?
    /// Lines printed right after each window line, on the same utility-queue block so they stay
    /// adjacent: WHEP's `[WHEP-SRFIT]` fit state (step 4e-2) and its slope cross-check. nil on every
    /// other transport. Called every window even when windows are not reported — the cross-check's
    /// WARNING must reach a Release log — with no steering line printed then.
    private let windowCompanion: (@Sendable (WindowFacts) -> [String])?

    private let lock = UnfairLockBox()
    /// Serialises every TIMEBASE WRITE decision with its write: the anchor, the per-buffer
    /// evaluation (resume, coarse fallback) and the starvation deadline (hold). Without it a hold
    /// decided on the timer thread could land after a resume or an anchor decided on another, and
    /// leave the timebase at rate 0 with nothing held. Order: `transition`, then `lock`.
    private let transition = UnfairLockBox()
    /// Set by `retire()`: the renderer belongs to another session now, so nothing here may write.
    private var retired = false

    // ── Session state, under `lock` ─────────────────────────────────────────────────────────────
    private var anchored = false
    private var refMedia = 0.0, refHost = 0.0, refRate = 1.0
    private var state = LiveAudioResampleController.State()
    private var previousError: Double?
    private var lastEvaluationHost = 0.0
    private var settleUntil = -Double.infinity
    private var sessionStart = 0.0

    // The starvation hold (§18.16).
    /// Output-axis end of everything enqueued so far (max over reads), the queue's far end.
    private var frontier: Double?
    private var held: (timebase: Double, host: Double, frontier: Double)?
    /// The last restart's host time: the catch-up write's window is measured from it.
    private var lastResumeHost = -Double.infinity
    private var catchUpWrites = 0
    /// D: seconds the audio is steered behind the picture's line since a resume; 0 otherwise.
    private var recoveryOffset = 0.0
    private var recoveryStartHost: Double?
    private var recoveryPeak = 0.0
    private var nextRecoveryCutHost = -Double.infinity
    private var recoveryLargestCut = 0.0
    private var recoveryTrackingCuts = 0
    /// The picture (§18.19): how far it is behind the line (`Mapping.pictureLate`), since when it
    /// has been on it, and its catch-up rate (s/s, + = closing) — nil until measured after a resume.
    private var pictureLate = 0.0
    private var pictureOnLineSince: Double?
    private var pictureLateMark: (host: Double, late: Double)?
    private var pictureCatchUp: Double?
    /// The residual watch: until this host time, a splice takes an |e_f| > 20 ms residual, at most
    /// one per `residualSpacingSeconds`; each splice extends the watch (§18.19).
    private var residualWatchUntil = -Double.infinity
    private var nextResidualHost = -Double.infinity
    private var residualSplices = 0
    private var residualSplicedSeconds = 0.0
    private var holds = 0
    private var resumes = 0
    private var heldSeconds = 0.0
    private var recoveryDrops = 0
    private var recoveryDroppedSeconds = 0.0
    private var recoveryFolded = 0.0
    /// Lowest queue seen just BEFORE an enqueue (previous frontier − timebase) — the margin the
    /// hold is judged against. Per window, and session-long.
    private var lowWater = Double.infinity
    private var sessionLowWater = Double.infinity
    private var windowHolds = 0

    // The per-source audio offset (§19.1).
    /// O, seconds: subtracted from every line handed in, so `refMedia` already carries −O.
    private var userOffset = 0.0
    private var userOffsetChanges = 0
    private var userOffsetRefusals = 0
    private var userOffsetPinnedLogged = false
    /// The first anchor's saved advance, waiting for playback start to be judged (`anchor`).
    private var startJudgement: (media: Double, host: Double, rate: Double, offset: Double)?
    /// Net O accepted in this window: the WHEP level hold re-bases its reference by it (§19.1).
    private var windowOffsetMoved = 0.0
    /// The advance figure (§19.8, follow-up): the renderer queue just BEFORE each enqueue — its lowest
    /// point in each packet cycle — over the last `advanceQueueWindowSeconds`, as a ring. An advance
    /// is judged, and its "at most" figure stated, from the lowest of these and the queue now, so a
    /// press of the stated size a few seconds later finds at least that much: the momentary figure
    /// swung by a packet (~21 ms on SRT) and could promise what the next press could not get.
    private var queueHistory = [(host: Double, queue: Double)](repeating: (0, 0), count: queueHistoryCapacity)
    private var queueHistoryHead = 0, queueHistoryCount = 0

    // Counters, session-long.
    private var firstAnchors = 0
    private var coarseLevel = 0
    private var coarseStep = 0
    private var reanchors = 0
    private var maxAbsRhoMinusOne = 0.0
    private var spliceDrops = 0
    private var spliceInserts = 0
    private var splicedSeconds = 0.0
    private var spliceFallbacks = 0
    private var unmatched = 0

    // The rail tripwire, session-long.
    private var railSince: Double?
    private var railCounted = false         // this episode reached the dwell and was counted
    private var railLogged = false          // …and its ENTER line was logged
    private var railPeakAbsError = 0.0
    private var lastRailLogHost = -Double.infinity
    private var railEpisodes = 0            // episodes that reached the dwell
    private var railSuppressed = 0          // of those, not logged because of the rewarn interval
    private var railSeconds = 0.0           // time at the rail, all episodes, closed ones only

    /// Content-moving events reported by the callers, newest last. A splice consumes the one it
    /// matches, so one event cannot account for two splices.
    private struct NotedEvent {
        let label: String
        let host: Double
        let jumped: Double?
        let detail: String
        var consumed = false
    }
    private var events: [NotedEvent] = []
    private static let eventCapacity = 32

    // Window. Preallocated: 10 s at 100 Hz is 1000 reads.
    private static let capacity = 4096
    private var errs = [Double](repeating: 0, count: capacity)
    /// "Heard A/V" per accepted read: the picture's line without O, less the content heard (+ = the
    /// audio is heard later). Includes O and D; the loop's e does not include O.
    private var heards = [Double](repeating: 0, count: capacity)
    private var count = 0
    /// Renderer queue depth per accepted read: enqueued output frontier − timebase, seconds.
    /// MEASUREMENT ONLY — nothing reads it but the window line.
    private var depths = [Double](repeating: 0, count: capacity)
    private var depthCount = 0
    private var overflowed = 0
    private var discarded = 0
    private var settling = 0
    private var saturatedSteps = 0
    private var rhoMin = Double.infinity, rhoMax = -Double.infinity
    private var slewMax = 0.0
    private var windowCoarse = 0
    private var windowSplices = 0
    private var windowWrites = 0
    /// Anything in this window that moves the queue depth by the steering's own action (see
    /// `WindowFacts.excluded`).
    private var windowExcluded = false
    private var windowStart = 0.0

    /// - Parameters:
    ///   - readTimebase: `CMTimeGetSeconds(synchronizer.currentTime())`. Called between the two
    ///     host reads and nothing else is.
    ///   - hostNow: `CACurrentMediaTime`.
    ///   - write: `setRate(1.0, time: outputSeconds, atHostTime: hostSeconds)`, plus whatever the
    ///     caller logs about it. Called without this object's lock held.
    ///   - hold: `setRate(0, time: outputSeconds, atHostTime: hostSeconds)` — the starvation
    ///     hold (§18.16). The steering arms its own deadline timer when this is given.
    public convenience init(tag: String, mode: Mode, stage: LiveAudioResampleStage,
                            reportsWindows: Bool,
                            readTimebase: @escaping @Sendable () -> Double,
                            hostNow: @escaping @Sendable () -> Double,
                            write: @escaping @Sendable (Double, Double, WriteOrigin) -> Void,
                            hold: (@Sendable (Double, Double) -> Void)? = nil,
                            log: (@Sendable (String) -> Void)?,
                            windowCompanion: (@Sendable (WindowFacts) -> [String])? = nil) {
        let timer = hold != nil ? StarvationDeadline(hostNow: hostNow) : nil
        self.init(tag: tag, mode: mode, clock: stage, gains: .adopted, thresholds: .adopted,
                  reportsWindows: reportsWindows, readTimebase: readTimebase, hostNow: hostNow,
                  write: write, hold: hold, armDeadline: timer.map { t in { @Sendable host in t.arm(at: host) } },
                  log: log, windowCompanion: windowCompanion)
        timer?.fire = { [weak self] in self?.starvationCheck() }
        deadline = timer
    }

    /// The timer behind `armDeadline` in the app; kept so it lives as long as the steering.
    private var deadline: StarvationDeadline?

    init(tag: String, mode: Mode, clock: LiveAudioContentClock,
         gains: LiveAudioResampleController.Gains, thresholds: Thresholds,
         reportsWindows: Bool,
         readTimebase: @escaping @Sendable () -> Double,
         hostNow: @escaping @Sendable () -> Double,
         write: @escaping @Sendable (Double, Double, WriteOrigin) -> Void,
         hold: (@Sendable (Double, Double) -> Void)? = nil,
         armDeadline: (@Sendable (Double) -> Void)? = nil,
         log: (@Sendable (String) -> Void)?,
         windowCompanion: (@Sendable (WindowFacts) -> [String])? = nil) {
        self.tag = tag; self.mode = mode; self.clock = clock; self.gains = gains
        self.thresholds = thresholds; self.reportsWindows = reportsWindows
        self.readTimebase = readTimebase; self.hostNow = hostNow; self.write = write; self.log = log
        self.holdWrite = hold; self.armDeadline = armDeadline
        self.windowCompanion = windowCompanion
    }

    // MARK: - The target line

    /// The session's target line (§2.8): content time `media` at host `host`, advancing at `rate`.
    /// Mirrored transports push the LiveClock mapping minus cushion on every evaluation; NDI's is
    /// set by its anchor and left. Never writes the timebase — a moved line is an error for the
    /// loop, or, if it moved by more than 50 ms, a step for the coarse branch.
    ///
    /// `pictureLate`: how far the picture is behind this line (`LiveClock.Mapping.pictureLate`),
    /// read only by the starvation recovery. 0 = on the line, which is also what a caller with no
    /// picture clock (NDI) passes.
    public func setReference(media: Double, host: Double, rate: Double, pictureLate late: Double = 0) {
        guard media.isFinite, host.isFinite, rate.isFinite, rate > 0 else { return }
        let l = late.isFinite ? max(0, late) : 0
        lock.lock()
        // O is in the line (§19.1): `media` is the picture's line, the stored line is O behind it.
        refMedia = media - userOffset; refHost = host; refRate = rate
        pictureLate = l
        if l <= Self.pictureOnLineSeconds {
            if pictureOnLineSince == nil { pictureOnLineSince = host }
        } else { pictureOnLineSince = nil }
        if let m = pictureLateMark {
            if host - m.host >= Self.pictureRateWindowSeconds {
                pictureCatchUp = (m.late - l) / (host - m.host)
                pictureLateMark = (host, l)
            }
        } else { pictureLateMark = (host, l) }
        lock.unlock()
    }

    /// A saved advance refused before playback began (`onStartOffsetRefused`). O is 0 for the
    /// session; the caller tells the user and moves the SDI read back.
    public struct StartOffsetRefusal: Sendable, Equatable {
        /// The pending O that was refused (negative: sound earlier), seconds.
        public let requested: Double
        /// The largest advance the queue allowed at playback start (queue − keep − fade − margin, ≥ 0).
        public let available: Double
        /// The queue at playback start with O = 0: what was enqueued past the picture's line.
        public let queue: Double
    }

    /// Called once if the session's saved advance is refused at playback start. Any thread (the
    /// sink's); must not block. Set before the first `sample`.
    public var onStartOffsetRefused: ((StartOffsetRefusal) -> Void)?

    /// How long before the first anchor's host time the saved advance is judged: the queue is all
    /// but full by then, and a rewrite of the anchor still lands before anything plays. Wider than
    /// one AAC frame (21.3 ms), so a buffer always lands inside it on a running sender.
    static let startJudgementLeadSeconds = 0.050

    /// Anchor the timebase so the content heard at `host` is `media`, and make that the target
    /// line. The first call is the session's rate write; later ones are deliberate re-anchors.
    ///
    /// `e_f` is reset and `i` held, exactly as for a coarse event: a re-anchor moves position, and
    /// the drift the integrator learned is a property of the clocks.
    ///
    /// ── A SAVED ADVANCE IS JUDGED AT PLAYBACK START (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, 7) ──
    ///
    /// A negative O set before the anchor (the bookmark's, at connect) used to be placed by this
    /// write and never judged, where every live change of O meets `setUserOffset`'s queue test.
    /// It now meets the same test — but NOT HERE. On a mirrored transport the first anchor is the
    /// picture's: its `host` is a startup fill in the FUTURE, and nothing has been enqueued yet (SRT
    /// drops the audio that precedes the video anchor by design). The 2026-10-08 OBS run showed it:
    /// judged here, the queue was always empty. So the anchor places O as before and leaves the
    /// judgement to the first `sample` within `startJudgementLeadSeconds` of `host`, when the queue
    /// the startup fill built is there to judge (`judgeStartOffsetLocked`). Refused, the anchor is
    /// written again without O — before anything plays — and O is 0 for the session: refused WHOLE,
    /// as any advance is (§19.8), never clamped to a value nobody chose.
    public func anchor(media: Double, host: Double, rate: Double = 1.0, reason: String? = nil) {
        guard media.isFinite, host.isFinite else { return }
        transition.lock(); defer { transition.unlock() }
        lock.lock()
        guard !retired else { lock.unlock(); return }
        // An anchor places the content heard on the target: any hold is over and nothing is owed.
        if let h = held { heldSeconds += max(0, host - h.host); held = nil }
        endRecoveryLocked()
        let first = firstAnchors == 0
        let origin: WriteOrigin = first ? .firstAnchor : .reanchor(reason ?? "caller")
        // O is in the line (§19.1): the content heard at `host` is placed O behind `media`.
        let line = media - userOffset
        refMedia = line; refHost = host; refRate = rate.isFinite && rate > 0 ? rate : 1.0
        anchored = true
        if sessionStart == 0 { sessionStart = host; windowStart = host }
        if first { firstAnchors = 1 } else { reanchors += 1; windowExcluded = true }
        windowWrites += 1
        restartAfterWriteLocked(host: host)
        let judge = first && userOffset < 0 && mode == .loop
        if judge { startJudgement = (media: media, host: host, rate: refRate, offset: userOffset) }
        let o = userOffset
        lock.unlock()
        if judge {
            let tag = self.tag
            emit {
                String(format: "%@ AUDIO OFFSET %+.1f ms (saved) placed by the first anchor — judged against the "
                       + "queue at playback start, %.0f ms before it", tag, o * 1000,
                       Self.startJudgementLeadSeconds * 1000)
            }
        }
        // Outside the lock: the inverse takes the stage's, and the write reaches the synchronizer.
        write(clock.outputTime(atInputTime: line), host, origin)
    }

    /// The saved advance's judgement, once its time has come (see `anchor`). Under `transition`,
    /// from `sample`, with `lock` held on entry and RELEASED on return. Returns the work to do outside
    /// the lock: the rewrite and the callback when refused, a log line either way; nil when it is not
    /// yet due or there is nothing enqueued to judge.
    private func judgeStartOffsetLocked(now t: Double) -> (() -> Void)? {
        guard let j = startJudgement, t >= j.host - Self.startJudgementLeadSeconds, let f = frontier,
              userOffset == j.offset else {
            // Moved by the user since: their change met its own test.
            if let j = startJudgement, userOffset != j.offset { startJudgement = nil }
            lock.unlock()
            return nil
        }
        startJudgement = nil
        lock.unlock()
        let tag = self.tag
        // The queue AT playback start: what is enqueued past the line, plus what a running sender
        // delivers in the ≤ 50 ms still to go (real time). Judged a little early, it must not count
        // those milliseconds against the user.
        let queue = f - clock.outputTime(atInputTime: j.media) + max(0, j.host - t)
        let available = max(0, queue - Self.recoveryKeepSeconds
                            - LiveAudioResampleStage.crossfadeSeconds - Self.dropQueueMarginSeconds)
        let late = t - j.host
        guard -j.offset > available else {
            return { [weak self] in
                self?.emit {
                    String(format: "%@ AUDIO OFFSET %+.1f ms (saved) JUDGED at playback start (%+.0f ms) — queue "
                           + "%.1f ms, %.1f ms of advance available: placed", tag, j.offset * 1000, late * 1000,
                           queue * 1000, available * 1000)
                }
            }
        }
        lock.lock()
        userOffset = 0; userOffsetRefusals += 1
        refMedia = j.media; refHost = j.host; refRate = j.rate
        reanchors += 1; windowExcluded = true; windowWrites += 1
        restartAfterWriteLocked(host: max(t, j.host))
        lock.unlock()
        let refusal = StartOffsetRefusal(requested: j.offset, available: available, queue: queue)
        let needed = -j.offset + Self.recoveryKeepSeconds + LiveAudioResampleStage.crossfadeSeconds
            + Self.dropQueueMarginSeconds
        return { [weak self] in
            guard let self else { return }
            // The anchor again, without O: `media` heard at `host`. Before `host` nothing has played.
            self.write(self.clock.outputTime(atInputTime: j.media), j.host,
                       .reanchor("saved advance refused before playback"))
            self.emit {
                String(format: "%@ AUDIO OFFSET %+.1f ms (saved) REFUSED at playback start (%+.0f ms) — a %.1f ms "
                       + "advance needs %.1f ms of renderer queue (advance + %.0f keep + %.0f fade + %.0f margin) "
                       + "and the queue is %.1f ms: at most %.1f ms of advance is available · O is 0 for this "
                       + "session; the anchor rewritten without it, %@",
                       tag, j.offset * 1000, late * 1000, -j.offset * 1000, needed * 1000,
                       Self.recoveryKeepSeconds * 1000, LiveAudioResampleStage.crossfadeSeconds * 1000,
                       Self.dropQueueMarginSeconds * 1000, queue * 1000, available * 1000,
                       late < 0 ? "before anything played" : "one re-anchor")
            }
            self.onStartOffsetRefused?(refusal)
        }
    }

    // MARK: - The per-source audio offset (§19.1)

    /// What `setUserOffset` did. Seconds throughout; + = the audio heard later.
    public enum UserOffsetOutcome: Sendable, Equatable {
        /// The line moved by −(new − old) and one splice of `spliceSeconds` was granted (+ = a drop,
        /// content forward; − = an insert of repeated material). No timebase write.
        case applied(old: Double, new: Double, spliceSeconds: Double)
        /// Not anchored yet (or held by the caller): stored, and placed by the next anchor.
        case pending(old: Double, new: Double)
        /// An advance larger than the queue allows: refused whole, O unchanged. `available` is the
        /// largest advance the queue allows now (queue − keep − fade − margin), ≥ 0.
        case refusedAdvance(old: Double, requested: Double, available: Double, queue: Double)
        /// The stage refused the splice (no resampled session, a retired stage): O unchanged.
        case refusedByStage(old: Double, requested: Double)
        /// Outside `userOffsetRange`, or not finite: O unchanged.
        case outOfRange(old: Double, requested: Double)
        /// Pinned mode has no O (step 3 exactly).
        case disabledPinned(requested: Double)
        case unchanged(Double)
        case retired
    }

    /// O now (0 in pinned mode, which never takes one).
    public var userOffsetSeconds: Double { lock.lock(); defer { lock.unlock() }; return userOffset }

    /// Change O. Under `transition`, like every write decision, so no evaluation, hold or resume
    /// interleaves with the line move and its splice. Never writes the timebase.
    @discardableResult
    public func setUserOffset(_ requested: Double) -> UserOffsetOutcome {
        let tag = self.tag
        let range = Self.userOffsetRange
        guard requested.isFinite, range.contains(requested) else {
            lock.lock(); let old = userOffset; userOffsetRefusals += 1; lock.unlock()
            emit {
                String(format: "%@ AUDIO OFFSET %+.1f ms REJECTED — outside %+.0f…%+.0f ms · O stays %+.1f ms",
                       tag, requested * 1000, range.lowerBound * 1000, range.upperBound * 1000, old * 1000)
            }
            return .outOfRange(old: old, requested: requested)
        }
        guard mode == .loop else {
            lock.lock()
            let first = !userOffsetPinnedLogged
            userOffsetPinnedLogged = true
            lock.unlock()
            if first {
                emit {
                    String(format: "%@ AUDIO OFFSET %+.1f ms NOT APPLIED — the ratio is PINNED (step 3, the "
                           + "back-out switch), which has no offset; O is 0 for this session (logged once)",
                           tag, requested * 1000)
                }
            }
            return .disabledPinned(requested: requested)
        }
        transition.lock(); defer { transition.unlock() }
        lock.lock()
        guard !retired else { lock.unlock(); return .retired }
        let old = userOffset, delta = requested - old
        guard delta != 0 else { lock.unlock(); return .unchanged(old) }
        guard anchored else {
            // Nothing is playing on a line yet: the next anchor places the content O behind it.
            userOffset = requested; userOffsetChanges += 1
            lock.unlock()
            emit {
                String(format: "%@ AUDIO OFFSET %+.1f → %+.1f ms · not anchored: placed by the next anchor, "
                       + "no splice, no write", tag, old * 1000, requested * 1000)
            }
            return .pending(old: old, new: requested)
        }
        let f = frontier
        lock.unlock()
        let (t, queueNow, queue, available) = advanceFigure(frontier: f)
        let move = -delta          // + = content forward: a drop
        if move > 0, move > available {
            lock.lock(); userOffsetRefusals += 1; lock.unlock()
            emit {
                String(format: "%@ AUDIO OFFSET %+.1f → %+.1f ms REFUSED at host %.3f s — a %.1f ms advance "
                       + "needs %.1f ms of renderer queue (advance + %.0f keep + %.0f fade + %.0f margin) "
                       + "and the queue's low point over the last %.0f s is %.1f ms (now %.1f ms): at most "
                       + "%.1f ms of advance is available · O stays %+.1f ms, no splice, no write",
                       tag, old * 1000, requested * 1000, t,
                       move * 1000, (move + Self.recoveryKeepSeconds + LiveAudioResampleStage.crossfadeSeconds
                                     + Self.dropQueueMarginSeconds) * 1000,
                       Self.recoveryKeepSeconds * 1000, LiveAudioResampleStage.crossfadeSeconds * 1000,
                       Self.dropQueueMarginSeconds * 1000, Self.advanceQueueWindowSeconds, queue * 1000,
                       queueNow * 1000, available * 1000, old * 1000)
            }
            return .refusedAdvance(old: old, requested: requested, available: available, queue: queue)
        }
        guard let g = clock.requestSplice(contentSeconds: move) else {
            lock.lock(); userOffsetRefusals += 1; lock.unlock()
            emit {
                String(format: "%@ AUDIO OFFSET %+.1f → %+.1f ms REFUSED by the stage (no resampled session) · "
                       + "O stays %+.1f ms", tag, old * 1000, requested * 1000, old * 1000)
            }
            return .refusedByStage(old: old, requested: requested)
        }
        lock.lock()
        // The line moves by −ΔO in the same step as the splice's −ΔO: content + ahead − target is
        // continuous, so e does not step and D (line − content) does not change.
        refMedia -= delta
        userOffset = requested
        userOffsetChanges += 1
        // The queue moves by the splice: shallower by a drop, deeper by an insert. The history moves
        // with it, so the next advance is judged on the queue this change leaves.
        shiftQueueHistoryLocked(by: -move)
        windowOffsetMoved += delta
        windowSplices += 1
        windowExcluded = true
        let n = userOffsetChanges, writes = writesLocked(), d = recoveryOffset
        lock.unlock()
        emit {
            String(format: "%@ AUDIO OFFSET %+.1f → %+.1f ms ACCEPTED at host %.3f s (change #%d): one splice, "
                   + "%@ %lld fr / %.1f ms, heard ≈ %.2f s from now · line moved %+.1f ms with it, so e, ρ "
                   + "and D%@ are continuous · renderer queue %.1f ms · no rate write (session writes %d)",
                   tag, old * 1000, requested * 1000, t, n, g.frames > 0 ? "DROP" : "INSERT", abs(g.frames),
                   abs(g.seconds) * 1000, queue, -delta * 1000,
                   d > 0 ? String(format: " (%.1f ms owed)", d * 1000) : "", queue * 1000, writes)
        }
        return .applied(old: old, new: requested, spliceSeconds: g.seconds)
    }

    /// The queue for an advance (a drop must leave the recovery guard behind it): the LOWEST of the
    /// queue now and its pre-enqueue low points over the last 10 s, so the figure a refusal states is
    /// one a later press of that size still finds (§19.8, follow-up). Returns the host time read, the
    /// queue now, the queue judged, and the advance available (queue − keep − fade − margin, ≥ 0).
    private func advanceFigure(frontier f: Double?) -> (Double, Double, Double, Double) {
        let t = hostNow()
        let timebase = readTimebase()
        let queueNow = (f.map { $0 - timebase }).flatMap { $0.isFinite ? $0 : nil } ?? 0
        lock.lock()
        let lowest = lowestRecentQueueLocked(now: t)
        lock.unlock()
        let queue = min(queueNow, lowest ?? queueNow)
        let available = max(0, queue - Self.recoveryKeepSeconds
                            - LiveAudioResampleStage.crossfadeSeconds - Self.dropQueueMarginSeconds)
        return (t, queueNow, queue, available)
    }

    /// The largest advance (sound EARLIER, seconds) `setUserOffset` would accept now: the figure its
    /// refusal states. READ-ONLY — calibration shows a proposed advance beyond it as not applicable
    /// (§19.10). nil when there is no anchored loop session (a change would be pending, or refused).
    public func availableAdvanceSeconds() -> Double? {
        guard mode == .loop else { return nil }
        lock.lock()
        guard !retired, anchored else { lock.unlock(); return nil }
        let f = frontier
        lock.unlock()
        return advanceFigure(frontier: f).3
    }

    /// Record an event that moves content — a LiveClock position jump, an input axis re-pin, a stage
    /// axis break — for the next splice to be matched against. Any thread; takes only this lock.
    ///
    /// - Parameters:
    ///   - label: the event's log name: `snap-to-live`, `freeze-guard`, `queue-full`,
    ///     `target-step`, `axis RE-PINNED`, `axis BREAK`, `late SR pair`.
    ///   - jumped: signed seconds the PICTURE moved (+ = forward), when the event has one.
    ///   - detail: the event's own figures, carried onto the SPLICE line.
    public func noteEvent(_ label: String, host: Double, jumped: Double?, detail: String) {
        lock.lock()
        events.append(NotedEvent(label: label, host: host, jumped: jumped, detail: detail))
        if events.count > Self.eventCapacity { events.removeFirst(events.count - Self.eventCapacity) }
        lock.unlock()
    }

    /// The newest unconsumed event in the window before `host`, consumed. A small forward slack
    /// covers two threads' reads of one host clock; ordering is otherwise guaranteed (see header).
    private func matchEventLocked(host: Double) -> NotedEvent? {
        guard let k = events.lastIndex(where: {
            !$0.consumed && $0.host <= host + 0.005 && host - $0.host <= Self.matchWindowSeconds
        }) else { return nil }
        events[k].consumed = true
        return events[k]
    }

    /// The clock un-anchored (`LiveClock.reset()`): the synchronizer is being held at rate 0, so
    /// there is nothing to steer until the next `anchor`. The ratio and `i` are kept.
    public func hold() {
        transition.lock(); defer { transition.unlock() }
        lock.lock()
        anchored = false
        previousError = nil
        // The caller holds the timebase itself; a starvation hold, if any, is superseded by it.
        if let h = held { heldSeconds += max(0, hostNow() - h.host); held = nil }
        endRecoveryLocked()
        lock.unlock()
    }

    /// This session's renderer is being handed to another (a new session, or the end of this one):
    /// no write of any kind from here on, and the deadline is disarmed.
    public func retire() {
        transition.lock(); defer { transition.unlock() }
        lock.lock()
        retired = true
        anchored = false
        lock.unlock()
        deadline?.cancel()
    }

    // MARK: - Per buffer

    /// One evaluation, per input buffer, on the enqueue thread, AFTER the buffer went through the
    /// stage (so its block is in the content-time map) and before it reaches the renderer.
    ///
    /// Returns the paired read if one was taken, for the step-2 probe. Nothing is read before the
    /// first anchor: the timebase is held at rate 0 and there is no line to compare it with.
    ///
    /// `enqueuedFrontier` is the output-axis END of what the renderer will hold once this call's
    /// buffers are enqueued (the caller enqueues them immediately after). `frontier − timebase` is
    /// the renderer queue's absolute depth, logged per window and never acted on.
    @discardableResult
    public func sample(enqueuedFrontier: Double? = nil) -> PairedRead? {
        transition.lock(); defer { transition.unlock() }
        lock.lock()
        let live = anchored && !retired
        // BEFORE THE FIRST ANCHOR NOTHING IS READ, BUT THE FAR END IS KEPT. The renderer already holds
        // what is enqueued (the timebase sits at rate 0), and the saved-advance judgement at playback
        // start counts it (`anchor`). Only the frontier: no low-water, no window, no decision. (On SRT
        // nothing is enqueued before the anchor; on NDI it can be.)
        if !anchored, !retired, let f = enqueuedFrontier, f.isFinite { frontier = max(frontier ?? f, f) }
        lock.unlock()
        guard live else { return nil }
        // A saved advance waiting for playback start (`anchor`). Before this call's buffers join the
        // frontier: one buffer conservative.
        lock.lock()
        if let work = judgeStartOffsetLocked(now: hostNow()) { work() }

        let t0 = hostNow()
        let timebase = readTimebase()
        let t1 = hostNow()
        let read = PairedRead(t0: t0, timebase: timebase, t1: t1)
        // After the pair, never inside it: these take the stage's lock. `ahead` is splice correction
        // requested and not yet heard (step 5): 0 whenever no splice is in the renderer's queue.
        let content = clock.inputTime(atOutputTime: timebase)
            + clock.spliceCorrectionAhead(ofOutputTime: timebase)

        var newRho: Double?
        var coarse: (Trigger, Double, Double)?     // trigger, e, target
        var windowLine: (() -> (line: String?, facts: WindowFacts))?

        lock.lock()
        if !anchored { lock.unlock(); return read }
        // A held timebase or a debt still owed: this window's depth is the recovery's (§18.20).
        if held != nil || recoveryOffset > 0 { windowExcluded = true }
        // ── The queue's far end, and its low-water mark just before this enqueue (§18.16) ──
        if held == nil, let f = frontier, timebase.isFinite {
            lowWater = min(lowWater, f - timebase); sessionLowWater = min(sessionLowWater, f - timebase)
            noteQueueLocked(host: t1, queue: f - timebase)
        }
        if let f = enqueuedFrontier, f.isFinite { frontier = max(frontier ?? f, f) }
        // ── Held: restart once the refill leaves the resume fill queued past the held point ──
        if let h = held {
            let ready = (frontier ?? -.infinity) - h.timebase >= Self.resumeFillSeconds
            let line = ready ? resumeLocked(host: t1, timebaseRead: timebase) : nil
            windowLine = windowIfDueLocked(now: t1)
            lock.unlock()
            if let line { line() }
            if let w = windowLine { emitWindow(w) }
            return read
        }
        if t1 - t0 > Self.pairingGateSeconds || !content.isFinite {
            discarded += 1
            windowLine = windowIfDueLocked(now: t1)
            lock.unlock()
            if let w = windowLine { emitWindow(w) }
            armDeadlineIfLive(timebase: timebase, host: t1)
            return read
        }
        if let f = enqueuedFrontier, f.isFinite, depthCount < Self.capacity {
            depths[depthCount] = f - timebase; depthCount += 1
        }
        // The picture's line, less what a starvation resume could not reach (D, §18.16). While D is
        // owed it is re-measured against the line (§18.19): a line LiveClock moves during the
        // catch-up changes the debt, so the audio is never left early when it is repaid.
        let line = refMedia + (t1 - refHost) * refRate
        var recoveredByLine: (() -> String)?
        if recoveryOffset > 0, t1 >= settleUntil {
            recoveryOffset = max(0, line - content)
            if recoveryOffset < Self.recoveryFoldSeconds {
                recoveredByLine = endRecoveryByFoldLocked(host: t1, how: "the line came back to the audio")
            }
        }
        let target = line - recoveryOffset
        let e = content - target
        let dt = lastEvaluationHost > 0
            ? max(0, min(Self.maximumStepSeconds, t1 - lastEvaluationHost)) : 0
        lastEvaluationHost = t1

        if t1 < settleUntil {
            settling += 1
        } else {
            if count < Self.capacity {
                errs[count] = e
                // Heard A/V (§19.1): against the picture's line WITHOUT O, so it carries O; e does not.
                heards[count] = line + userOffset - content
                count += 1
            } else { overflowed += 1 }
            if mode == .loop {
                if let p = previousError, abs(e - p) > thresholds.step {
                    coarse = (.step, e, target)
                } else {
                    let before = state.rho
                    state = LiveAudioResampleController.step(state, error: e, dt: dt, gains: gains)
                    if state.saturated { saturatedSteps += 1 }
                    if dt > 0 { slewMax = max(slewMax, abs(state.rho - before) / dt) }
                    // ρ goes to the stage whether or not the level trigger fires: the state now
                    // holds it, and the stage must never disagree with the state.
                    if state.rho != before { newRho = state.rho }
                    if abs(state.filteredError) > thresholds.level {
                        coarse = (.level, e, target)
                    }
                }
            }
            previousError = e
        }
        rhoMin = min(rhoMin, state.rho); rhoMax = max(rhoMax, state.rho)
        maxAbsRhoMinusOne = max(maxAbsRhoMinusOne, abs(state.rho - 1))
        let railLine = mode == .loop ? railTripwireLocked(host: t1, error: e) : nil

        var filteredAtEvent = 0.0
        if let c = coarse {
            filteredAtEvent = state.filteredError
            if c.0 == .level { coarseLevel += 1 } else { coarseStep += 1 }
            windowCoarse += 1
            // e_f reset, i held; the next read seeds the step comparison afresh.
            state = LiveAudioResampleController.coarseEvent(state)
            previousError = nil
        }
        // ── Recovery: take D back by forward splices, on the picture (§18.19; see the header) ──
        var recoveryDrop: (seconds: Double, kind: RecoveryCut)?
        var catchUp: (debt: Double, line: Double)?
        if coarse == nil, recoveryOffset > 0, mode == .loop, t1 >= settleUntil,
           t1 >= nextRecoveryCutHost, let f = enqueuedFrontier, f.isFinite {
            let room = (f - timebase) - Self.recoveryKeepSeconds
                - LiveAudioResampleStage.crossfadeSeconds - Self.dropQueueMarginSeconds
            let d = recoveryOffset, maxDrop = LiveAudioResampleStage.maximumDropSeconds
            let onLine = pictureLate <= Self.pictureOnLineSeconds
            let arriving = !onLine && (pictureCatchUp.map {
                $0 > 0 && pictureLate / $0 <= Self.recoveryHorizonSeconds } ?? false)
            if onLine || arriving {
                if room >= d - Self.recoveryFoldSeconds, d > Self.catchUpWriteSeconds,
                   t1 - lastResumeHost <= Self.catchUpWindowSeconds {
                    catchUp = (d, line)
                } else if room >= d - Self.recoveryFoldSeconds {
                    recoveryDrop = (min(d, room, maxDrop), .whole)
                } else if onLine, let since = pictureOnLineSince,
                          t1 - since >= Self.recoveryPartialGraceSeconds,
                          room >= Self.recoveryTrackingSeconds {
                    recoveryDrop = (min(room, maxDrop), .partial)
                }
            } else if pictureCatchUp != nil {
                // Late and staying late: keep the audio with the picture the viewer sees.
                let behindPicture = d - pictureLate
                if behindPicture >= Self.recoveryTrackingSeconds, room >= Self.recoveryTrackingSeconds {
                    recoveryDrop = (min(behindPicture, room, maxDrop), .tracking)
                }
            }
        }
        var catchUpLine: (() -> String)?
        if let c = catchUp {
            // The write puts the content heard on the line: nothing is owed, the loop restarts.
            let since = recoveryStartHost.map { t1 - $0 } ?? .nan, tag = self.tag
            recoveryOffset = 0; recoveryStartHost = nil; recoveryPeak = 0
            catchUpWrites += 1; windowWrites += 1; windowExcluded = true
            residualWatchUntil = t1 + Self.residualWatchSeconds
            restartAfterWriteLocked(host: t1)
            let writes = writesLocked(), q = (enqueuedFrontier ?? .nan) - timebase
            catchUpLine = {
                String(format: "%@ ⏩ STARVATION CATCH-UP at host %.3f s: %.1f ms debt, all queued %.2f s after "
                       + "the resume (renderer queue %.1f ms) → ONE timebase write onto the line instead of "
                       + "a cut heard a queue later · RECOVERED · session writes %d",
                       tag, t1, c.debt * 1000, since, q * 1000, writes)
            }
        }
        // ── The residual: one splice instead of the ratio crawling it back (§18.19) ──
        var residual: (move: Double, filtered: Double)?
        if coarse == nil, recoveryDrop == nil, catchUp == nil, recoveryOffset == 0, mode == .loop,
           t1 >= settleUntil, t1 < residualWatchUntil, t1 >= nextResidualHost, previousError != nil,
           pictureLate <= Self.pictureOnLineSeconds,
           abs(state.filteredError) > Self.residualSpliceSeconds {
            let move = -e      // + = the audio is behind: a drop, which the queue must cover
            let depth = enqueuedFrontier.flatMap { $0.isFinite ? $0 - timebase : nil } ?? 0
            if move < 0 || move + LiveAudioResampleStage.crossfadeSeconds
                + Self.dropQueueMarginSeconds <= depth {
                residual = (move, state.filteredError)
                // Repeats while LiveClock keeps moving its line; the watch closes 60 s after the last.
                nextResidualHost = t1 + Self.residualSpacingSeconds
                residualWatchUntil = t1 + Self.residualWatchSeconds
                // As for a coarse splice: e_f reset, i held, no step comparison across it.
                state = LiveAudioResampleController.coarseEvent(state)
                previousError = nil
            }
        }
        windowLine = windowIfDueLocked(now: t1)
        lock.unlock()

        if let r = newRho { clock.rho = r }
        if let railLine { emit(railLine) }
        if let (trigger, e, target) = coarse {
            let depth = enqueuedFrontier.flatMap { $0.isFinite ? $0 - timebase : nil }
            coarseAction(trigger: trigger, error: e, filtered: filteredAtEvent, target: target,
                         host: t1, queueDepth: depth)
        }
        if let recoveredByLine { emit(recoveredByLine) }
        if let c = catchUp {
            write(clock.outputTime(atInputTime: c.line), t1, .starvationCatchUp(debtSeconds: c.debt))
            if let catchUpLine { emit(catchUpLine) }
        }
        if let x = recoveryDrop {
            recover(by: x.seconds, kind: x.kind, host: t1, queueDepth: (enqueuedFrontier ?? .nan) - timebase)
        }
        if let r = residual {
            spliceResidual(move: r.move, filtered: r.filtered, host: t1,
                           queueDepth: (enqueuedFrontier ?? .nan) - timebase)
        }
        if let w = windowLine { emitWindow(w) }
        armDeadlineIfLive(timebase: timebase, host: t1)
        return read
    }

    // MARK: - The starvation hold (§18.16)

    /// The deadline fired: no input arrived while the queue drained to the margin. Hold the
    /// timebase where it stands. Called on the deadline's queue (tests: directly). Re-checks
    /// everything under the transition lock, so a deadline that lost a race with an enqueue does
    /// nothing but re-arm.
    public func starvationCheck() {
        guard holdWrite != nil else { return }
        transition.lock(); defer { transition.unlock() }
        lock.lock()
        guard anchored, !retired, mode == .loop, held == nil, let f = frontier else {
            lock.unlock(); return
        }
        lock.unlock()
        let t = hostNow()
        let timebase = readTimebase()
        guard timebase.isFinite else { return }
        let queue = f - timebase
        lock.lock()
        // Not yet at the margin (the deadline ran early, or a write moved the timebase): re-arm.
        // Inside the settle window after a write the timebase may not have taken it yet.
        guard queue <= Self.starvationMarginSeconds + 0.002, t >= settleUntil else {
            lock.unlock()
            armDeadlineIfLive(timebase: timebase, host: t)
            return
        }
        held = (timebase, t, f)
        holds += 1; windowHolds += 1; windowWrites += 1
        previousError = nil
        let n = holds, writes = writesLocked(), tag = self.tag, d = recoveryOffset
        let since = lastEvaluationHost > 0 ? t - lastEvaluationHost : .nan
        lock.unlock()
        holdWrite?(timebase, t)
        // Read straight back: how far the timebase is from the held point once the write returns.
        // The write's landing latency has never been measured (§18.16); this and the resume line's
        // "timebase at the resume read" are the measurement.
        let back = readTimebase() - timebase, backHost = hostNow() - t
        emit {
            String(format: "%@ ⏸ STARVATION HOLD #%d at host %.3f s — no input for %.0f ms, renderer queue %.1f ms "
                   + "(margin %.0f ms): timebase held at %.6f s, rate 0 (session writes %d) · read "
                   + "back %+.2f ms from the held point, %.2f ms after the decision%@",
                   tag, n, t, since * 1000, queue * 1000, Self.starvationMarginSeconds * 1000,
                   timebase, writes, back * 1000, backHost * 1000,
                   d > 0 ? String(format: " · recovery offset %.1f ms carried", d * 1000) : "")
        }
    }

    /// The restart. Under `lock` and `transition`; returns its log line to emit off the lock.
    /// Resumes at the latest content that leaves `resumeFillSeconds` queued, never past the target
    /// and never before the held point; whatever the target is ahead of that becomes D.
    private func resumeLocked(host t: Double, timebaseRead: Double) -> (() -> Void)? {
        guard let h = held, let f = frontier else { return nil }
        let targetFull = refMedia + (t - refHost) * refRate
        let owed = recoveryOffset
        lock.unlock()
        // Outside `lock` (the stage's lock is taken); `transition` still serialises writes.
        let targetOut = clock.outputTime(atInputTime: targetFull - owed)
        let at = max(h.timebase, min(targetOut, f - Self.resumeFillSeconds))
        let heard = clock.inputTime(atOutputTime: at) + clock.spliceCorrectionAhead(ofOutputTime: at)
        lock.lock()
        let paused = t - h.host
        heldSeconds += paused
        held = nil
        resumes += 1; windowWrites += 1; windowExcluded = true
        lastResumeHost = t
        var d = max(0, targetFull - heard)
        var folded = 0.0
        if d < Self.recoveryFoldSeconds { folded = d; recoveryFolded += d; d = 0 }
        recoveryOffset = d
        // The picture's catch-up rate is measured afresh from here: before the resume it was
        // falling behind, which says nothing about how fast it will come back.
        pictureLateMark = nil; pictureCatchUp = nil
        if d > 0 {
            if recoveryStartHost == nil { recoveryStartHost = t }
            recoveryPeak = max(recoveryPeak, d)
            nextRecoveryCutHost = t       // the settle window after the write is the only wait
            residualWatchUntil = .infinity
        } else {
            recoveryStartHost = nil
            residualWatchUntil = t + Self.residualWatchSeconds
        }
        restartAfterWriteLocked(host: t)
        let writes = writesLocked(), n = resumes, tag = self.tag
        let skipped = at - h.timebase, queued = f - at
        return { [write] in
            write(at, t, .starvationResume(pausedSeconds: paused))
            self.armDeadlineIfLive(timebase: at, host: t)
            self.emit {
                String(format: "%@ ▶ STARVATION RESUME #%d at host %.3f s after %.0f ms held (timebase read %+.2f ms "
                       + "from the held point) — restarts at %.6f s (%+.1f ms from the held point), "
                       + "%.1f ms queued · audio %@ · session writes %d", tag, n, t, paused * 1000,
                       (timebaseRead - h.timebase) * 1000, at, skipped * 1000, queued * 1000,
                       d > 0 ? String(format: "%.1f ms BEHIND the picture's line: a catch-up write if "
                                      + "all of it (> 125 ms) is queued within 1 s, else one cut once "
                                      + "the queue holds it, or cuts tracking a picture that stays late",
                                      d * 1000)
                             : String(format: "on the target (%.1f ms folded into the loop)",
                                      folded * 1000),
                       writes)
            }
        }
    }

    /// Which rule took a recovery cut (§18.19; see the header).
    enum RecoveryCut: String {
        case whole = "WHOLE DEBT"
        case tracking = "TRACKING THE LATE PICTURE"
        case partial = "PARTIAL (picture on the line, debt not all queued)"
    }

    /// One recovery drop of `x` seconds. Called without the lock, under `transition`.
    private func recover(by x: Double, kind: RecoveryCut, host t: Double, queueDepth: Double) {
        guard let g = clock.requestSplice(contentSeconds: x) else { return }
        lock.lock()
        let owedBefore = recoveryOffset, late = pictureLate, rate = pictureCatchUp
        recoveryOffset = max(0, recoveryOffset - g.seconds)
        var folded = 0.0
        if recoveryOffset < Self.recoveryFoldSeconds {
            folded = recoveryOffset; recoveryFolded += folded; recoveryOffset = 0
        }
        recoveryDrops += 1; recoveryDroppedSeconds += g.seconds
        recoveryLargestCut = max(recoveryLargestCut, g.seconds)
        if kind == .tracking { recoveryTrackingCuts += 1 }
        nextRecoveryCutHost = t + g.seconds + Self.recoveryCutSettleSeconds
        windowSplices += 1
        let left = recoveryOffset, n = recoveryDrops, tag = self.tag
        let since = recoveryStartHost.map { t - $0 } ?? .nan, peak = recoveryPeak
        if left == 0 {
            recoveryStartHost = nil; recoveryPeak = 0
            residualWatchUntil = t + Self.residualWatchSeconds
        }
        lock.unlock()
        emit {
            String(format: "%@ RECOVERY DROP #%d (%@) at host %.3f s: %lld fr / %.1f ms forward of %.1f ms owed · "
                   + "picture %.1f ms behind the line%@ · renderer queue %.1f ms · heard ≈ %.2f s from now · "
                   + "%@ · no rate write", tag, n, kind.rawValue, t, g.frames, g.seconds * 1000,
                   owedBefore * 1000, late * 1000,
                   rate.map { String(format: " (closing %+.0f ms/s)", $0 * 1000) } ?? "",
                   queueDepth * 1000, queueDepth,
                   left > 0 ? String(format: "%.1f ms still behind", left * 1000)
                            : String(format: "RECOVERED %.1f s after the resume (peak %.1f ms behind, "
                                     + "%.1f ms folded into the loop)", since, peak * 1000,
                                     folded * 1000))
        }
    }

    /// D fell under the fold without a cut (re-measured, §18.19): the rest is the loop's. Under
    /// `lock`; returns the line to emit off it.
    private func endRecoveryByFoldLocked(host t: Double, how: String) -> () -> String {
        let folded = recoveryOffset, since = recoveryStartHost.map { t - $0 } ?? .nan
        let peak = recoveryPeak, tag = self.tag
        recoveryFolded += folded
        recoveryOffset = 0; recoveryStartHost = nil; recoveryPeak = 0
        residualWatchUntil = t + Self.residualWatchSeconds
        return {
            String(format: "%@ RECOVERED %.1f s after the resume without a cut — %@ (peak %.1f ms "
                   + "behind, %.1f ms folded into the loop)", tag, since, how, peak * 1000,
                   folded * 1000)
        }
    }

    /// The residual splice (§18.19): the content moves by `move` (+ drop, − insert of repeated
    /// material). `e_f` was already reset and `i` held under the lock. Called without the lock.
    private func spliceResidual(move: Double, filtered: Double, host t: Double, queueDepth: Double) {
        let g = clock.requestSplice(contentSeconds: move)
        lock.lock()
        if let g {
            residualSplices += 1; residualSplicedSeconds += abs(g.seconds)
            windowSplices += 1
        }
        let tag = self.tag, i = state.integral
        lock.unlock()
        emit {
            guard let g else {
                return String(format: "%@ RESIDUAL SPLICE refused by the stage (%+.1f ms) at host %.3f s — "
                              + "the loop keeps it", tag, move * 1000, t)
            }
            return String(format: "%@ RESIDUAL SPLICE at host %.3f s: %@ %lld fr / %.1f ms (e_f %+.1f ms after "
                          + "the hold) · renderer queue %.1f ms · no rate write · e_f reset, i held at "
                          + "%+.2f ppm", tag, t, g.frames > 0 ? "DROP" : "INSERT", abs(g.frames),
                          abs(g.seconds) * 1000, filtered * 1000, queueDepth * 1000, i * 1e6)
        }
    }

    /// Nothing owed any more (an anchor or a fallback put the content on the target).
    private func endRecoveryLocked() {
        recoveryOffset = 0; recoveryStartHost = nil; recoveryPeak = 0
        residualWatchUntil = -.infinity
    }

    /// Re-arm the deadline for the moment the queue reaches the margin, if a hold is possible.
    private func armDeadlineIfLive(timebase: Double, host t: Double) {
        guard let armDeadline, mode == .loop, timebase.isFinite else { return }
        lock.lock()
        let f = frontier, ok = anchored && !retired && held == nil, settle = settleUntil
        lock.unlock()
        guard ok, let f else { return }
        // Inside a settle window the timebase may not have taken the last write, so a read then
        // can misstate the queue; the deadline waits for the window to close.
        armDeadline(max(settle, t + max(0, f - timebase - Self.starvationMarginSeconds)))
    }

    private func writesLocked() -> Int {
        firstAnchors + spliceFallbacks + reanchors + holds + resumes + catchUpWrites
    }

    /// §2.4's action: splice the content by −e, or — past the bound, or a drop the renderer queue
    /// cannot cover — the pre-step-5 re-anchor. Either way one line, naming the event it matched.
    /// Called without the lock.
    private func coarseAction(trigger: Trigger, error e: Double, filtered: Double, target: Double,
                              host t1: Double, queueDepth: Double?) {
        // + = the content moves forward: a drop. The audio is behind the picture by −e.
        let move = -e
        let fade = LiveAudioResampleStage.crossfadeSeconds
        var refusal: String?
        if abs(move) > LiveAudioResampleStage.maximumSpliceSeconds {
            refusal = String(format: "|e| %.0f ms is past the %.0f ms splice bound", abs(e) * 1000,
                             LiveAudioResampleStage.maximumSpliceSeconds * 1000)
        } else if move > 0, let d = queueDepth, move + fade + Self.dropQueueMarginSeconds > d {
            refusal = String(format: "a %.1f ms drop needs %.0f ms of renderer queue (drop + %.0f ms "
                             + "fade + %.0f ms margin) and the queue holds %.1f ms",
                             move * 1000, (move + fade + Self.dropQueueMarginSeconds) * 1000,
                             fade * 1000, Self.dropQueueMarginSeconds * 1000, d * 1000)
        }
        let grant = refusal == nil ? clock.requestSplice(contentSeconds: move) : nil
        if refusal == nil, grant == nil {
            refusal = "the stage refused it (no resampled session, or under one frame)"
        }

        lock.lock()
        let matched = matchEventLocked(host: t1)
        if matched == nil { unmatched += 1 }
        if let g = grant {
            if g.frames > 0 { spliceDrops += 1 } else { spliceInserts += 1 }
            splicedSeconds += abs(g.seconds)
            windowSplices += 1
        } else {
            spliceFallbacks += 1
            windowWrites += 1
            restartAfterWriteLocked(host: t1)
        }
        let number = spliceDrops + spliceInserts
        let integralPpm = state.integral * 1e6
        let writes = writesLocked()
        lock.unlock()

        // The fallback: place the timebase so the content heard now is the target, as step 4 did.
        if grant == nil {
            write(clock.outputTime(atInputTime: target), t1, .coarse(trigger, errorSeconds: e))
        }

        let tag = self.tag
        let threshold = trigger == .level ? thresholds.level : thresholds.step
        let triggerText = String(format: "trigger %@: e %+.1f ms (e_f %+.1f ms, threshold %.0f ms)",
                                 trigger.rawValue.uppercased(), e * 1000, filtered * 1000,
                                 threshold * 1000)
        let queueText = queueDepth.map { String(format: "%.1f ms", $0 * 1000) } ?? "unknown"
        let matchText: String
        if let m = matched {
            matchText = String(format: "matched: %@%@ at host %.3f s (%.0f ms before) — %@",
                               m.label,
                               m.jumped.map { String(format: " %+.3f s", $0) } ?? "",
                               m.host, (t1 - m.host) * 1000, m.detail)
        } else {
            matchText = String(format: "⚠️ WARNING: UNMATCHED — no snap-to-live / freeze-guard / "
                               + "queue-full / target-step / axis RE-PINNED / axis BREAK / late SR pair in the %.1f s "
                               + "before it; §2.4 calls an unmatched splice a defect",
                               Self.matchWindowSeconds)
        }
        if let g = grant {
            emit {
                String(format: "%@ SPLICE #%d %@ %lld fr / %.1f ms (content %@) · %@ · host %.3f s · "
                       + "%d fr (%.1f ms) equal-power cross-fade · renderer queue %@ · %@ · no rate "
                       + "write (session writes %d) · e_f reset, i held at %+.2f ppm",
                       tag, number, g.frames > 0 ? "DROP" : "INSERT", abs(g.frames),
                       abs(g.seconds) * 1000, g.frames > 0 ? "forward" : "back, repeated material",
                       triggerText, t1, g.crossfadeFrames,
                       Double(g.crossfadeFrames) / g.sampleRate * 1000, queueText, matchText,
                       writes, integralPpm)
            }
        } else {
            let why = refusal ?? "—"
            emit {
                String(format: "%@ COARSE RE-ANCHOR — no splice: %@ · %@ · host %.3f s · renderer "
                       + "queue %@ · %@ · action: one timebase write (session writes %d) · e_f reset, "
                       + "i held at %+.2f ppm",
                       tag, why, triggerText, t1, queueText, matchText, writes, integralPpm)
            }
        }
    }

    /// The rail tripwire's state machine, per accepted read (see the header). Returns the line to
    /// log, formatted off the lock by `emit`, or nil. Loop mode only.
    private func railTripwireLocked(host t: Double, error e: Double) -> (() -> String)? {
        let atRail = abs(state.rho - 1) >= gains.bound * (1 - 1e-9)
        guard atRail else {
            guard let since = railSince else { return nil }
            let duration = t - since
            railSeconds += duration
            railSince = nil
            defer { railCounted = false; railLogged = false }
            guard railLogged else { return nil }
            let tag = self.tag, peak = railPeakAbsError, i = state.integral
            return {
                String(format: "%@ ratio OFF its rail after %.1f s — peak |e| %.1f ms while on it, "
                       + "e %+.1f ms now · i %+.2f ppm", tag, duration, peak * 1000, e * 1000,
                       i * 1e6)
            }
        }
        if railSince == nil { railSince = t; railPeakAbsError = 0 }
        railPeakAbsError = max(railPeakAbsError, abs(e))
        guard let since = railSince, t - since >= Self.railDwellSeconds, !railCounted else {
            return nil
        }
        // Reached the dwell: count the episode once, and log it unless one was logged recently.
        railCounted = true
        railEpisodes += 1
        guard t - lastRailLogHost >= Self.railRewarnSeconds else {
            railSuppressed += 1        // counted, not logged — and so no OFF line either
            return nil
        }
        railLogged = true
        lastRailLogHost = t
        let tag = self.tag, rho = state.rho, bound = gains.bound, ef = state.filteredError
        let i = state.integral, level = thresholds.level, n = railEpisodes, dwell = t - since
        return {
            String(format: "%@ ⚠️ RATIO AT ITS RAIL — ρ−1 %+.0f ppm (B = ±%.0f ppm) for %.1f s: the "
                   + "target is moving faster than the audio may follow, so lip-sync error grows "
                   + "until it lets go. e %+.1f ms, e_f %+.1f ms, i %+.2f ppm (held) · the level "
                   + "trigger splices at %.0f ms · rail episode #%d this session",
                   tag, (rho - 1) * 1e6, bound * 1e6, dwell, e * 1000, ef * 1000, i * 1e6,
                   level * 1000, n)
        }
    }

    /// Counters for the session, for the END line and for tests.
    public struct Totals: Sendable, Equatable {
        public var firstAnchors = 0
        public var coarseLevel = 0
        public var coarseStep = 0
        public var reanchors = 0
        /// Coarse events taken as splices, by direction, and the content they moved in total.
        public var spliceDrops = 0
        public var spliceInserts = 0
        public var splicedSeconds = 0.0
        /// Coarse events the splice could not take, re-anchored instead — each one a write.
        public var spliceFallbacks = 0
        /// Splices and fallbacks with no event in the window before them.
        public var unmatched = 0
        public var splices: Int { spliceDrops + spliceInserts }
        /// `coarseLevel + coarseStep == splices + spliceFallbacks`.
        public var writes: Int { firstAnchors + spliceFallbacks + reanchors + holds + resumes + catchUpWrites }
        /// Catch-up writes (§18.19 option 2): a burst's debt over 125 ms, taken in one write.
        public var catchUpWrites = 0
        public var rho = 1.0
        public var integral = 0.0
        public var filteredError = 0.0
        public var maxAbsRhoMinusOne = 0.0
        /// The rail tripwire: episodes that reached the 5 s dwell, how many of those were not
        /// logged (inside the 60 s rewarn), and seconds at ±B over the session so far.
        public var railEpisodes = 0
        public var railSuppressed = 0
        public var railSeconds = 0.0
        /// The starvation hold (§18.16): holds and resumes are writes (rate 0, rate 1.0).
        public var holds = 0
        public var resumes = 0
        public var heldSeconds = 0.0
        /// Recovery drops after a resume, what they moved, and what was folded into the loop.
        public var recoveryDrops = 0
        public var recoveryDroppedSeconds = 0.0
        public var recoveryFoldedSeconds = 0.0
        /// Of those: the largest single cut, and how many tracked a late picture (§18.19).
        public var recoveryLargestCut = 0.0
        public var recoveryTrackingCuts = 0
        /// Residual splices after a hold, and the content they moved (§18.19).
        public var residualSplices = 0
        public var residualSplicedSeconds = 0.0
        /// D now, and the lowest queue seen just before an enqueue (nil before the second one).
        public var recoveryOffset = 0.0
        public var lowWater: Double?
        /// The per-source audio offset (§19.1): O now, changes taken (each one splice, or placed by
        /// an anchor), and changes refused (out of range, an advance past the queue, the stage).
        public var userOffset = 0.0
        public var userOffsetChanges = 0
        public var userOffsetRefusals = 0
    }

    public var totals: Totals {
        lock.lock(); defer { lock.unlock() }
        return totalsLocked()
    }

    /// End of session: the last partial window, then one summary line.
    public func finish() {
        transition.lock()
        lock.lock()
        retired = true
        let w = windowLocked(final: true)
        let t = totalsLocked()
        lock.unlock()
        transition.unlock()
        deadline?.cancel()
        if let w { emitWindow(w) }
        let tag = self.tag, mode = self.mode
        emit {
            String(format: "%@ steering session END — mode %@ · timebase writes %d (first anchor %d + "
                   + "coarse %d [splice fallbacks] + re-anchor %d) · coarse events %d [level %d, step %d] · "
                   + "splices %d (drop %d, insert %d), %.1f ms spliced, unmatched %d · ρ−1 at end "
                   + "%+.1f ppm, max |ρ−1| %.1f ppm · i %+.2f ppm · ρ at its rail %.1f s, %d "
                   + "episode(s) ≥ 5 s (%d not logged) · starvation: holds %d + resumes %d + catch-up %d (writes), "
                   + "%.0f ms held, recovery drops %d / %.1f ms (largest %.1f ms, %d tracking the "
                   + "picture), %.1f ms folded, D at end %.1f ms, residual splices %d / %.1f ms, "
                   + "queue low-water before an enqueue %@ · audio offset O %+.1f ms (%d change(s), %d refused)",
                   tag, mode.rawValue, t.writes, t.firstAnchors, t.spliceFallbacks, t.reanchors,
                   t.coarseLevel + t.coarseStep, t.coarseLevel, t.coarseStep,
                   t.splices, t.spliceDrops, t.spliceInserts, t.splicedSeconds * 1000, t.unmatched,
                   (t.rho - 1) * 1e6, t.maxAbsRhoMinusOne * 1e6, t.integral * 1e6,
                   t.railSeconds, t.railEpisodes, t.railSuppressed,
                   t.holds, t.resumes, t.catchUpWrites, t.heldSeconds * 1000, t.recoveryDrops,
                   t.recoveryDroppedSeconds * 1000, t.recoveryLargestCut * 1000,
                   t.recoveryTrackingCuts, t.recoveryFoldedSeconds * 1000,
                   t.recoveryOffset * 1000, t.residualSplices, t.residualSplicedSeconds * 1000,
                   t.lowWater.map { String(format: "%.1f ms", $0 * 1000) } ?? "—",
                   t.userOffset * 1000, t.userOffsetChanges, t.userOffsetRefusals)
        }
    }

    // MARK: - Internals

    private func totalsLocked() -> Totals {
        var t = Totals()
        t.firstAnchors = firstAnchors; t.coarseLevel = coarseLevel; t.coarseStep = coarseStep
        t.reanchors = reanchors; t.rho = state.rho; t.integral = state.integral
        t.filteredError = state.filteredError; t.maxAbsRhoMinusOne = maxAbsRhoMinusOne
        t.spliceDrops = spliceDrops; t.spliceInserts = spliceInserts
        t.splicedSeconds = splicedSeconds; t.spliceFallbacks = spliceFallbacks
        t.unmatched = unmatched
        t.railEpisodes = railEpisodes; t.railSuppressed = railSuppressed
        t.railSeconds = railSeconds + (railSince.map { max(0, lastEvaluationHost - $0) } ?? 0)
        t.holds = holds; t.resumes = resumes; t.catchUpWrites = catchUpWrites
        t.heldSeconds = heldSeconds + (held.map { max(0, lastEvaluationHost - $0.host) } ?? 0)
        t.recoveryDrops = recoveryDrops; t.recoveryDroppedSeconds = recoveryDroppedSeconds
        t.recoveryFoldedSeconds = recoveryFolded; t.recoveryOffset = recoveryOffset
        t.recoveryLargestCut = recoveryLargestCut; t.recoveryTrackingCuts = recoveryTrackingCuts
        t.residualSplices = residualSplices; t.residualSplicedSeconds = residualSplicedSeconds
        t.lowWater = sessionLowWater.isFinite ? sessionLowWater : nil
        t.userOffset = userOffset; t.userOffsetChanges = userOffsetChanges
        t.userOffsetRefusals = userOffsetRefusals
        return t
    }

    /// After any write: `e_f` reset, `i` held, no step comparison across the write, and reads
    /// ignored until the timebase has taken the new anchor.
    private func restartAfterWriteLocked(host: Double) {
        state = LiveAudioResampleController.coarseEvent(state)
        previousError = nil
        settleUntil = host + thresholds.settle
        // A write moves the timebase: queue readings from before it describe another queue.
        queueHistoryCount = 0
    }

    // MARK: - The advance figure's queue history (§19.8, follow-up)

    private func noteQueueLocked(host: Double, queue: Double) {
        guard host.isFinite, queue.isFinite else { return }
        queueHistory[queueHistoryHead] = (host, queue)
        queueHistoryHead = (queueHistoryHead + 1) % Self.queueHistoryCapacity
        queueHistoryCount = min(queueHistoryCount + 1, Self.queueHistoryCapacity)
    }

    /// The lowest pre-enqueue queue within `advanceQueueWindowSeconds` of `now`, newest first; nil
    /// when there is none (just after a write).
    private func lowestRecentQueueLocked(now: Double) -> Double? {
        var lowest: Double?
        var k = queueHistoryHead
        for _ in 0..<queueHistoryCount {
            k = (k - 1 + Self.queueHistoryCapacity) % Self.queueHistoryCapacity
            let e = queueHistory[k]
            guard now - e.host <= Self.advanceQueueWindowSeconds else { break }
            lowest = min(lowest ?? e.queue, e.queue)
        }
        return lowest
    }

    private func shiftQueueHistoryLocked(by shift: Double) {
        var k = queueHistoryHead
        for _ in 0..<queueHistoryCount {
            k = (k - 1 + Self.queueHistoryCapacity) % Self.queueHistoryCapacity
            queueHistory[k].queue += shift
        }
    }

    /// What a window hands its companion: the session clock at the window's end and the renderer
    /// queue's median depth over it (nil when no depth was read).
    public struct WindowFacts: Sendable {
        public let elapsed: Double
        public let rendererDepthMedian: Double?
        /// The window saw a starvation hold, a recovery debt, a catch-up write, a recovery or
        /// residual splice, or a coarse splice or fallback: its depth is the steering's own doing, not
        /// the target line's, and the WHEP level hold (§18.20) does not read it.
        public var excluded = false
        /// The loop's state over the window, for the level hold's settled-reference rule: a step
        /// at the ratio's rail in it, and the integrator at its end.
        public var saturated = false
        public var integral: Double?
        /// Net change of the audio offset O accepted in this window (§19.1): the queue deepens by it
        /// from here on, by design, so the level hold re-bases its reference by it. Such a window is
        /// also `excluded`.
        public var offsetMoved = 0.0
        public init(elapsed: Double, rendererDepthMedian: Double?, excluded: Bool = false,
                    saturated: Bool = false, integral: Double? = nil, offsetMoved: Double = 0) {
            self.elapsed = elapsed; self.rendererDepthMedian = rendererDepthMedian; self.excluded = excluded
            self.saturated = saturated; self.integral = integral; self.offsetMoved = offsetMoved
        }
    }

    private func windowIfDueLocked(now: Double) -> (() -> (line: String?, facts: WindowFacts))? {
        guard windowStart > 0, now - windowStart >= Self.windowSeconds else { return nil }
        return windowLocked(final: false, now: now)
    }

    /// Snapshot and reset the window. Only the copy happens under the lock; the sort and the
    /// formatting run in the returned closure, which `emit` runs on a utility queue — the same
    /// discipline as the paired probe, for the same reason: this is the audio thread.
    private func windowLocked(final: Bool, now: Double? = nil)
        -> (() -> (line: String?, facts: WindowFacts))? {
        let n = count
        let hadAnything = n > 0 || discarded > 0 || settling > 0 || windowWrites > 0 || held != nil
            || windowOffsetMoved != 0
        let prints = reportsWindows || windowCoarse > 0 || windowHolds > 0 || final
        guard hadAnything, prints || windowCompanion != nil else {
            resetWindowLocked(now: now); return nil
        }
        let e = Array(errs[0..<n])
        let h = Array(heards[0..<n])
        let d = Array(depths[0..<depthCount])
        let snap = (n: n, disc: discarded, settle: settling, over: overflowed,
                    sat: saturatedSteps, rho: state.rho, rhoMin: rhoMin, rhoMax: rhoMax,
                    slew: slewMax, i: state.integral, ef: state.filteredError,
                    coarse: windowCoarse, splices: windowSplices, writes: windowWrites,
                    total: totalsLocked(), elapsed: (now ?? lastEvaluationHost) - sessionStart,
                    lowWater: lowWater, holds: windowHolds, d: recoveryOffset,
                    o: userOffset, oMoved: windowOffsetMoved,
                    excluded: windowExcluded || windowHolds > 0 || windowSplices > 0 || windowCoarse > 0
                        || held != nil || recoveryOffset > 0)
        resetWindowLocked(now: now)
        let tag = self.tag, mode = self.mode
        return {
            var sorted = e
            sorted.sort()
            let errText = snap.n > 0
                ? String(format: "min %+.2f med %+.2f max %+.2f", sorted[0] * 1e3,
                         sorted[snap.n / 2] * 1e3, sorted[snap.n - 1] * 1e3)
                : "no reads"
            var sortedDepth = d
            sortedDepth.sort()
            let facts = WindowFacts(elapsed: snap.elapsed,
                                    rendererDepthMedian: sortedDepth.isEmpty
                                        ? nil : sortedDepth[sortedDepth.count / 2],
                                    excluded: snap.excluded, saturated: snap.sat > 0,
                                    integral: snap.i, offsetMoved: snap.oMoved)
            guard prints else { return (nil, facts) }
            let depthText = sortedDepth.isEmpty
                ? "—"
                : String(format: "min %.1f med %.1f max %.1f", sortedDepth[0] * 1e3,
                         sortedDepth[sortedDepth.count / 2] * 1e3, sortedDepth[sortedDepth.count - 1] * 1e3)
            var sortedHeard = h
            sortedHeard.sort()
            let heardText = sortedHeard.isEmpty
                ? "—" : String(format: "%+.2f ms", sortedHeard[sortedHeard.count / 2] * 1e3)
            let rhoRange = snap.rhoMin.isFinite
                ? String(format: "%+.1f … %+.1f", (snap.rhoMin - 1) * 1e6, (snap.rhoMax - 1) * 1e6)
                : "—"
            return (String(format: "%@ steering %@ +%.0fs · mode %@ · ρ−1 %+.1f ppm (window %@, "
                          + "slew max %.1f ppm/s) · i %+.2f ppm · e_f %+.2f ms · e ms %@ · n=%d "
                          + "discarded=%d settling=%d%@ · saturated %d · coarse this window %d "
                          + "(splices %d) · writes this window %d · session: writes %d = first %d + "
                          + "coarse %d (splice fallbacks) + re-anchor %d + starvation holds/resumes · coarse events %d (level %d, "
                          + "step %d) · "
                          + "splices %d, %.1f ms, unmatched %d · max |ρ−1| %.1f ppm · "
                          + "renderer depth ms %@ · low-water %@ · holds this window %d, session %d "
                          + "(resumes %d, %.0f ms held) · D %.1f ms · heard A/V med %@ (O %+.1f ms%@)",
                          tag, final ? "END" : "window", snap.elapsed, mode.rawValue,
                          (snap.rho - 1) * 1e6, rhoRange, snap.slew * 1e6, snap.i * 1e6,
                          snap.ef * 1e3, errText, snap.n, snap.disc, snap.settle,
                          snap.over > 0 ? String(format: " OVERFLOW=%d", snap.over) : "",
                          snap.sat, snap.coarse, snap.splices, snap.writes, snap.total.writes,
                          snap.total.firstAnchors, snap.total.spliceFallbacks, snap.total.reanchors,
                          snap.total.coarseLevel + snap.total.coarseStep,
                          snap.total.coarseLevel, snap.total.coarseStep, snap.total.splices,
                          snap.total.splicedSeconds * 1000, snap.total.unmatched,
                          snap.total.maxAbsRhoMinusOne * 1e6, depthText,
                          snap.lowWater.isFinite ? String(format: "%.1f ms", snap.lowWater * 1e3) : "—",
                          snap.holds, snap.total.holds, snap.total.resumes,
                          snap.total.heldSeconds * 1e3, snap.d * 1e3, heardText, snap.o * 1e3,
                          snap.oMoved != 0 ? String(format: ", moved %+.1f ms this window", snap.oMoved * 1e3)
                                           : ""), facts)
        }
    }

    private func resetWindowLocked(now: Double?) {
        count = 0; depthCount = 0; overflowed = 0; discarded = 0; settling = 0; saturatedSteps = 0
        rhoMin = .infinity; rhoMax = -.infinity; slewMax = 0
        windowCoarse = 0; windowSplices = 0; windowWrites = 0; windowExcluded = false
        lowWater = .infinity; windowHolds = 0; windowOffsetMoved = 0
        if let now { windowStart = now }
    }

    private func emit(_ line: @escaping () -> String) {
        guard let log else { return }
        let box = UncheckedLine(make: line)
        DispatchQueue.global(qos: .utility).async { log(box.make()) }
    }

    /// A window line, then its companion's, in one block so nothing interleaves between them. The
    /// companion is read on the utility queue, never on the enqueue thread that closed the window.
    private func emitWindow(_ window: @escaping () -> (line: String?, facts: WindowFacts)) {
        guard let log else { return }
        let box = UncheckedWindow(make: window)
        let companion = windowCompanion
        DispatchQueue.global(qos: .utility).async {
            let w = box.make()
            if let line = w.line { log(line) }
            companion?(w.facts).forEach(log)
        }
    }
}

/// The window closure captures only value snapshots; these let it cross to the utility queue.
private struct UncheckedLine: @unchecked Sendable { let make: () -> String }
private struct UncheckedWindow: @unchecked Sendable {
    let make: () -> (line: String?, facts: LiveAudioResampleSteering.WindowFacts)
}

/// The starvation hold's one-shot deadline (§18.16): a strict dispatch timer on its own
/// high-priority queue, re-armed on every enqueue. Host times are `CACurrentMediaTime`, the same
/// mach clock `DispatchTime.now()` reads.
final class StarvationDeadline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "manifold.liveaudio.starvation", qos: .userInteractive)
    private let timer: DispatchSourceTimer
    private let hostNow: @Sendable () -> Double
    /// Set once, before the first `arm`.
    var fire: (@Sendable () -> Void)?

    init(hostNow: @escaping @Sendable () -> Double) {
        self.hostNow = hostNow
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.fire?() }
        timer.activate()
    }

    func arm(at host: Double) {
        let delay = max(0, host - hostNow())
        timer.schedule(deadline: .now() + delay, leeway: .microseconds(500))
    }

    func cancel() { timer.schedule(deadline: .distantFuture) }

    deinit { timer.cancel() }
}
