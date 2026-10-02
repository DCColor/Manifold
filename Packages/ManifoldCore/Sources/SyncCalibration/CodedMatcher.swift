//
//  CodedMatcher.swift — SyncCalibration
//
//  §19.3's coded-interval matcher, in Swift (docs/AUDIO_RESAMPLER_DESIGN.md §19.9 Decisions 5,
//  §19.10). The port of `scripts/syncclips/pairing_check.py`'s `match`, with ONE change, which §19.9
//  made a requirement: the score is MEAN-based.
//
//  For each index shift s between the flash and beep sequences, the pairs (f_i, b_{i+s}) give offsets
//  d_i. The coded intervals make every d_i equal only at the right s. A candidate needs ≥ `minPairs`
//  pairs and its centre (the median d_i) inside ±`halfCycle`; the smallest score wins.
//
//    * score .mean   — the mean |d_i − centre|. Every wrong shift scores ≈ 4 code steps.
//    * score .median — pairing_check.py's: the median |d_i − centre|. Kept for the comparison only:
//      at 24, 29.97 and 59.94 its wrong-pairing margin is ONE code step (33–42 ms), because a wrong
//      shift's deviations split between 1 and 7 steps and the median lands on 1.
//
//  The MARGIN is the smallest score of any wrong candidate: how far the code is from aliasing.
//

import Foundation

public enum CodedMatcher {

    public enum Score: Sendable { case mean, median }

    public struct Candidate: Sendable, Equatable {
        /// The centre of the pair offsets: beep − flash, seconds.
        public let offset: Double
        /// The spread score, seconds.
        public let score: Double
        public let shift: Int
        public let pairs: Int
    }

    public struct Result: Sendable, Equatable {
        public let best: Candidate
        /// Every other candidate that met the rules.
        public let wrong: [Candidate]
        /// The smallest wrong score; nil when no other candidate met the rules.
        public var margin: Double? { wrong.map(\.score).min() }
    }

    public static func match(flashes f: [Double], beeps b: [Double], halfCycle: Double, minPairs: Int,
                             score: Score = .mean) -> Result? {
        var cands: [Candidate] = []
        if b.isEmpty || f.isEmpty { return nil }
        for s in -b.count..<b.count {
            var d: [Double] = []
            for i in 0..<f.count where i + s >= 0 && i + s < b.count { d.append(b[i + s] - f[i]) }
            guard d.count >= minPairs, d.count > 0 else { continue }
            let m = median(d)
            guard abs(m) <= halfCycle else { continue }
            let dev = d.map { abs($0 - m) }
            let sc = score == .mean ? dev.reduce(0, +) / Double(dev.count) : median(dev)
            cands.append(Candidate(offset: m, score: sc, shift: s, pairs: d.count))
        }
        // pairing_check.py compares (spread, median, shift, n) tuples; the same order here.
        let sorted = cands.sorted {
            ($0.score, $0.offset, $0.shift, $0.pairs) < ($1.score, $1.offset, $1.shift, $1.pairs)
        }
        guard let best = sorted.first else { return nil }
        return Result(best: best, wrong: Array(sorted.dropFirst()))
    }

    /// statistics.median: the mean of the middle two for an even count.
    public static func median(_ x: [Double]) -> Double {
        let s = x.sorted()
        let n = s.count
        guard n > 0 else { return .nan }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// numpy's default percentile (linear between closest ranks), p in 0…100.
    public static func percentile(_ x: [Double], _ p: Double) -> Double {
        let s = x.sorted()
        guard !s.isEmpty else { return .nan }
        let r = p / 100 * Double(s.count - 1)
        let lo = Int(r.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
    }
}
