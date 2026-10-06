//
//  CalibrationMeasurement.swift — SyncCalibration
//
//  One calibration run: flashes and tone onsets in, a figure out only when it can be trusted
//  (docs/AUDIO_RESAMPLER_DESIGN.md §19.2, §19.10). Not thread-safe: one owner (the app's model, on
//  the main actor) feeds it.
//
//  ── WHAT IS MEASURED: THE HEARD FIGURE, O INCLUDED ────────────────────────────────────────────
//
//  Per flash, the renderer reports its PTS f and h, the engine's heard − clock at that tick
//  (`liveAudioHeardMinusClock`, stage A: it carries O), and the line offset ℓ that h added back
//  (`liveAudioCalibrationRead`). The audio heard while that frame is due is content f + h − ℓ on the
//  AUDIO axis, the beeps' axis, so a beep at content b is heard b − (f + h − ℓ) after the flash:
//
//      heard A/V = b − (f + h − ℓ)        + = sound LATER than the picture
//
//  ⚠️ ℓ IS THE SR LINE ON WHEP AND 0 ON SRT AND NDI (§19.15). On WHEP the audio stamped p − ℓ
//  is what plays with picture p, and h is that audio moved onto the video axis. Leaving ℓ out read
//  what is heard − ℓ: a different figure on every connection (the line carries the connection's
//  first-packet epoch) and a walk within one (the line's slope), while playback was right. Every
//  pair keeps its ℓ, so a result can say which line it was measured on.
//
//  That is the decoded A/V (b − f, what the source carries) plus O plus the mirror error. It leaves
//  out Manifold's own render path (frame choice, tick → glass: ≈ −16 ms, §18.13) and the output
//  device, which are the app's, the same for every source (§19.2, "what it does not measure").
//
//  ── PAIRING: THE CODE DECIDES, THE WINDOW RULE PAIRS ──────────────────────────────────────────
//
//  1. LOCK. Until locked, each new event runs `CodedMatcher` (mean score) over the latest ≤ 16
//     flashes, on the audio axis (f + h), and the beeps around them. It locks when the best score is
//     under `lockScoreMax` and every wrong candidate scores ≥ `lockMarginMin`. A missed event inside
//     the window inflates the right shift's score, so such a window simply does not lock; a later
//     clean one does.
//  2. PAIR. Locked at offset d*, each flash takes the beep nearest f + h + d*, within ± half the
//     shortest code interval (§19.2's rule). A missed beep leaves its flash unpaired (its neighbours
//     are ≥ one interval away), never mispaired. d* follows the pairs' median.
//
//  ── CONFIDENCE (the brief, §19.10) ────────────────────────────────────────────────────────────
//
//  A figure is offered only with ≥ 10 pairs, p90 − p10 under one frame, and the last 5 pairs within
//  ±2 ms — read as §19.2 words it, "a stable ±2 ms median over the last 5 pairs": the median, as it
//  stood after each of the last 5 pairs, within ±2 ms of the median now. Until then: progress (pairs,
//  spread), never a number.
//
//  ⚠️ NOT EACH PAIR WITHIN ±2 MS, and that reading was built first and measured (§19.10): on NDI the
//  window median held −66…−71 ms for 3 minutes while single pairs scattered ±3–5 ms (p10–p90
//  5–7 ms), so a per-pair rule never offered a figure there. The scatter is bounded by the spread
//  rule (under one frame); what must be stable is the figure offered.
//
//  ⚠️ THE FIGURE IS THE MOST RECENT 10 PAIRS, NOT EVERY PAIR SINCE START. Measured live (§19.10): on a
//  freshly connected stream the heard figure walks for ~40 s while the steering settles after the
//  connect's re-anchors (+95 → +77 → +80 ms on local SRT). A median over every pair would carry that
//  walk into the result. So the median, the p10–p90 spread and the last-5 test are all taken over
//  the last `minPairs` pairs (≈ 10–13 s of clip): the figure is what is heard NOW, and a transient
//  older than the window cannot set it.
//
//  ⚠️ AND ONE GUARD BEYOND THE BRIEF'S THREE RULES: THE WINDOW MUST NOT BE WALKING. Measured live
//  (§19.10, local SRT 59.94): after the connect's re-anchors the figure walked +46 → 0 ms at
//  ~1–1.5 ms/s, then settled near −5 ms. At 59.94 the last 5 pairs span ~4 s, so a 1 ms/s walk sits
//  inside ±2 ms and the three rules offered +1.5 ms mid-walk; the re-check read −5.3. So no figure
//  while the window's least-squares slope exceeds `maxWalkPerSecond` (0.2 ms/s: ≤ 2 ms across a
//  ~10 s window, the stability bound's own size).
//

import Foundation

public final class CalibrationMeasurement {

    public struct Rules: Sendable {
        public var minPairs = 10
        public var stableCount = 5
        public var stableTolerance = 0.002
        public var lockScoreMax = 0.010
        public var lockMarginMin = 0.040
        /// The window's slope limit, seconds of heard A/V per second of stream.
        public var maxWalkPerSecond = 0.0002
        public var lockMinFlashes = 6
        public var lockWindowFlashes = 16
        public init() {}
    }

    public struct Pair: Sendable, Equatable {
        public let flashPTS: Double
        public let heardMinusClock: Double
        /// ℓ, the line offset `heardMinusClock` added back (0 off WHEP).
        public let lineOffset: Double
        public let beep: Double
        /// b − (f + h − ℓ), seconds.
        public var heard: Double { beep - (flashPTS + heardMinusClock - lineOffset) }
    }

    public enum Waiting: Sendable, Equatable {
        /// Not locked yet: events seen so far.
        case pairing(flashes: Int, beeps: Int)
        /// Locked, fewer than `minPairs`.
        case pairs(Int)
        /// p90 − p10 is not under a frame yet.
        case spread(Double)
        /// The median, as it stood after one of the last 5 pairs, is more than ±2 ms from now's.
        case unstable(worst: Double)
        /// The window's figure is still moving (seconds per second): the stream is settling.
        case walking(Double)
        /// The frame rate is not known yet (the spread rule needs it).
        case frameRate
    }

    public enum Verdict: Sendable, Equatable {
        case waiting(Waiting)
        case confident
    }

    public struct Snapshot: Sendable, Equatable {
        public let flashes: Int
        public let beeps: Int
        /// Pairs found in the whole run.
        public let pairs: Int
        /// The median heard A/V over the window (the last `minPairs` pairs), seconds; nil before any.
        public let median: Double?
        public let p10: Double?
        public let p90: Double?
        public var spread: Double? { p10.flatMap { a in p90.map { $0 - a } } }
        public let verdict: Verdict
        public let frameSeconds: Double?
        /// The median line offset ℓ over the same window, seconds; nil before any pair.
        public let lineOffset: Double?
    }

    public let rules: Rules
    /// One frame of the stream, seconds. The spread rule's yardstick; set as the renderer learns it.
    public var frameSeconds: Double?

    /// Each flash: its PTS and h − ℓ, the audio heard on the beeps' axis minus the clock, and ℓ.
    public private(set) var flashes: [(pts: Double, h: Double, lineOffset: Double)] = []
    public private(set) var beeps: [Double] = []
    public private(set) var pairs: [Pair] = []
    /// The locked offset (beep − (f + h)), nil until the code has decided the pairing.
    public private(set) var lockedOffset: Double?
    public private(set) var lockResult: CodedMatcher.Result?
    private var paired = Set<Int>()       // flash indices
    private var usedBeeps = Set<Int>()

    /// ± half the shortest code interval of any clip.
    public static var pairingTolerance: Double { SyncClips.all.map(\.shortestIntervalSeconds).min()! / 2 }

    public init(frameSeconds: Double?, rules: Rules = Rules()) {
        self.frameSeconds = frameSeconds
        self.rules = rules
    }

    /// A flash, with the heard − clock read at the tick that showed it and the line offset that read
    /// added back (`FrameEngine.LiveAudioCalibrationRead`; 0 where there is no SR line).
    public func addFlash(pts: Double, heardMinusClock h: Double, lineOffset: Double = 0) {
        guard pts.isFinite, h.isFinite, lineOffset.isFinite else { return }
        flashes.append((pts, h - lineOffset, lineOffset))
        update()
    }

    /// A tone onset, on the transport's content axis.
    public func addBeep(_ t: Double) {
        guard t.isFinite else { return }
        beeps.append(t)
        update()
    }

    private func update() {
        if lockedOffset == nil { tryLock() }
        if lockedOffset != nil { pairAll() }
    }

    private func tryLock() {
        guard flashes.count >= rules.lockMinFlashes else { return }
        let window = flashes.suffix(rules.lockWindowFlashes).map { $0.pts + $0.h }
        let half = SyncClips.halfCycleLimitSeconds
        let lo = window.first! - half - 0.5, hi = window.last! + half + 0.5
        let b = beeps.filter { $0 >= lo && $0 <= hi }
        guard b.count >= rules.lockMinFlashes / 2 else { return }
        guard let r = CodedMatcher.match(flashes: window, beeps: b, halfCycle: half,
                                         minPairs: max(rules.lockMinFlashes - 1, window.count / 2)) else { return }
        guard r.best.score <= rules.lockScoreMax, (r.margin ?? .infinity) >= rules.lockMarginMin else { return }
        lockedOffset = r.best.offset
        lockResult = r
    }

    private func pairAll() {
        guard var d = lockedOffset else { return }
        let tol = Self.pairingTolerance
        var changed = false
        for (i, fl) in flashes.enumerated() where !paired.contains(i) {
            let target = fl.pts + fl.h + d
            var best: (Int, Double)?
            for (j, b) in beeps.enumerated() where !usedBeeps.contains(j) {
                let e = abs(b - target)
                if e <= tol, e < (best?.1 ?? .infinity) { best = (j, e) }
            }
            if let (j, _) = best {
                paired.insert(i); usedBeeps.insert(j)
                pairs.append(Pair(flashPTS: fl.pts, heardMinusClock: fl.h + fl.lineOffset,
                                  lineOffset: fl.lineOffset, beep: beeps[j]))
                changed = true
            }
        }
        if changed {
            pairs.sort { $0.flashPTS < $1.flashPTS }
            d = CodedMatcher.median(pairs.map(\.heard))
            lockedOffset = d
        }
    }

    /// Least-squares slope of (t, y); 0 for fewer than two points or no spread in t.
    static func slope(_ p: [(Double, Double)]) -> Double {
        guard p.count >= 2 else { return 0 }
        let n = Double(p.count)
        let mt = p.map(\.0).reduce(0, +) / n, my = p.map(\.1).reduce(0, +) / n
        let sxx = p.reduce(0) { $0 + ($1.0 - mt) * ($1.0 - mt) }
        guard sxx > 0 else { return 0 }
        return p.reduce(0) { $0 + ($1.0 - mt) * ($1.1 - my) } / sxx
    }

    public var snapshot: Snapshot {
        // The window: the most recent `minPairs` pairs (see the header).
        let x = pairs.suffix(rules.minPairs).map(\.heard)
        let med = x.isEmpty ? nil : CodedMatcher.median(x)
        let p10 = x.isEmpty ? nil : CodedMatcher.percentile(x, 10)
        let p90 = x.isEmpty ? nil : CodedMatcher.percentile(x, 90)
        let verdict: Verdict
        if lockedOffset == nil {
            verdict = .waiting(.pairing(flashes: flashes.count, beeps: beeps.count))
        } else if pairs.count < rules.minPairs {
            verdict = .waiting(.pairs(pairs.count))
        } else if let frame = frameSeconds, frame > 0 {
            let spread = p90! - p10!
            // The median as it stood after each of the last 5 pairs (each over its own last-10 window),
            // against the median now: §19.2's "a stable ±2 ms median over the last 5 pairs".
            let all = pairs.map(\.heard)
            let worst = (0..<min(rules.stableCount, all.count)).map { k -> Double in
                let end = all.count - k
                return abs(CodedMatcher.median(Array(all[max(0, end - rules.minPairs)..<end])) - med!)
            }.max() ?? 0
            let walk = Self.slope(pairs.suffix(rules.minPairs).map { ($0.flashPTS, $0.heard) })
            if spread >= frame { verdict = .waiting(.spread(spread)) }
            else if worst > rules.stableTolerance { verdict = .waiting(.unstable(worst: worst)) }
            else if abs(walk) > rules.maxWalkPerSecond { verdict = .waiting(.walking(walk)) }
            else { verdict = .confident }
        } else {
            verdict = .waiting(.frameRate)
        }
        let lines = pairs.suffix(rules.minPairs).map(\.lineOffset)
        return Snapshot(flashes: flashes.count, beeps: beeps.count, pairs: pairs.count, median: med,
                        p10: p10, p90: p90, verdict: verdict, frameSeconds: frameSeconds,
                        lineOffset: lines.isEmpty ? nil : CodedMatcher.median(lines))
    }
}

/// What calibration offers, from a confident figure (§19.10). Manifold never applies it by itself.
public struct CalibrationProposal: Sendable, Equatable {
    /// O in effect while measuring, ms (+ = sound later).
    public let currentMs: Int
    /// The measured heard A/V, ms (+ = sound later than the picture). O is in it.
    public let residualMs: Double
    /// current − residual, rounded to 1 ms, before the range.
    public let unclampedMs: Int
    /// The offer: `unclampedMs` clamped to the range.
    public let proposedMs: Int
    public let range: ClosedRange<Int>
    /// The most the queue lets sound move EARLIER now (the stage B low point), ms; nil when unknown.
    public let availableAdvanceMs: Double?

    public var clamped: Bool { proposedMs != unclampedMs }
    public var change: Int { proposedMs - currentMs }
    /// An advance (sound earlier) of this many ms, or 0.
    public var advanceMs: Int { max(0, -change) }
    /// Nothing to apply.
    public var inSync: Bool { change == 0 }
    /// An advance beyond what the queue allows is not applicable; the figure stays on show.
    public var applicable: Bool {
        guard !inSync else { return false }
        guard advanceMs > 0, let a = availableAdvanceMs else { return true }
        return Double(advanceMs) <= a
    }

    public init(currentMs: Int, residualSeconds: Double, range: ClosedRange<Int>,
                availableAdvanceSeconds: Double?) {
        self.currentMs = currentMs
        residualMs = residualSeconds * 1000
        unclampedMs = Int((Double(currentMs) - residualSeconds * 1000).rounded())
        proposedMs = min(max(unclampedMs, range.lowerBound), range.upperBound)
        self.range = range
        availableAdvanceMs = availableAdvanceSeconds.map { max(0, $0) * 1000 }
    }
}
