//
//  SyncClips.swift — SyncCalibration
//
//  The Manifold sync clips as calibration mode knows them (docs/AUDIO_RESAMPLER_DESIGN.md §19.3,
//  §19.9, §19.10). ONE source of truth in Swift for what `scripts/syncclips/recipes.tsv` generates:
//  the rates, the code's unit, the file names, and where the code's events fall.
//
//  ⚠️ KEEP IN STEP WITH recipes.tsv. The clips are generated from that file and bundled from
//  build/syncclips/; this table names the files the app looks for and the timeline the tests rebuild.
//  A change to the coded pattern is a new clip set: a new download (…-v2.zip, never replacing v1)
//  and a new `SyncClips.patternVersion` (§19.10).
//

import Foundation

public enum SyncClips {

    /// The coded pattern's version. The download zip carries it in its name (`…-v1.zip`), so a
    /// changed pattern is a new zip and a new URL constant, never a replaced v1.
    public static let patternVersion = 1

    /// Steps between events, repeating: a pairing off by one interval cannot fit (§19.3).
    public static let codeSteps = [23, 29, 31, 37]
    /// Steps per cycle (23 + 29 + 31 + 37).
    public static let cycleSteps = 120
    /// Event offsets inside one cycle, in steps.
    public static let eventStepsInCycle = [0, 23, 52, 83]

    public struct Clip: Sendable, Equatable {
        /// "23.976", "24" … as in recipes.tsv and the file names.
        public let label: String
        /// The exact rational rate.
        public let num: Int
        public let den: Int
        /// Frames per code step (2 at 50 and 59.94, §19.9 deviation 1).
        public let unit: Int

        public var rate: Double { Double(num) / Double(den) }
        public var frameSeconds: Double { Double(den) / Double(num) }
        /// round(rate): 24, 25, 30, 50, 60.
        public var nominal: Int { (num + den / 2) / den }
        /// 60 × round(rate) frames.
        public var frameCount: Int { 60 * nominal }
        /// The first event, ≈ 1 s in.
        public var firstEventFrame: Int { nominal }
        public var cycleSeconds: Double { Double(SyncClips.cycleSteps * unit) * frameSeconds }
        public var shortestIntervalSeconds: Double { Double(SyncClips.codeSteps.min()! * unit) * frameSeconds }
        /// "manifold-sync-23.976p.mp4", as generate.sh writes it.
        public var mp4Name: String { "manifold-sync-\(label)p.mp4" }
        /// "23.976p".
        public var displayName: String { "\(label)p" }

        /// Every event frame in one clip, in order.
        public var eventFrames: [Int] {
            var out: [Int] = []
            var c = 0
            while true {
                for s in SyncClips.eventStepsInCycle {
                    let k = firstEventFrame + unit * (s + SyncClips.cycleSteps * c)
                    if k >= frameCount { return out }
                    out.append(k)
                }
                c += 1
            }
        }

        /// Every event's exact time, k / rate (the flash's pts and the tone's start, §19.9).
        public var eventTimes: [Double] { eventFrames.map { Double($0) * frameSeconds } }
    }

    /// The bundled set, in recipes.tsv's order.
    public static let all: [Clip] = [
        Clip(label: "23.976", num: 24000, den: 1001, unit: 1),
        Clip(label: "24", num: 24, den: 1, unit: 1),
        Clip(label: "25", num: 25, den: 1, unit: 1),
        Clip(label: "29.97", num: 30000, den: 1001, unit: 1),
        Clip(label: "30", num: 30, den: 1, unit: 1),
        Clip(label: "50", num: 50, den: 1, unit: 2),
        Clip(label: "59.94", num: 60000, den: 1001, unit: 2),
    ]

    /// The largest |offset| the coded matcher accepts: half the SHORTEST cycle of any clip (30p's
    /// 4.0 s cycle: ±2.0 s). Inside it every clip's pairing is unambiguous, so calibration does not
    /// need to know which clip is playing.
    public static var halfCycleLimitSeconds: Double { all.map(\.cycleSeconds).min()! / 2 }

    /// The longest single interval of any clip (37 steps at 24p: 1.542 s). Two consecutive intervals
    /// are never shorter than 52 steps (1.73 s at 30p), so a gap longer than this between two flashes
    /// or two beeps means an event was missed.
    public static var longestIntervalSeconds: Double {
        all.map { Double(codeSteps.max()! * $0.unit) * $0.frameSeconds }.max()!
    }

    /// The tone's fade-in: 5 ms raised cosine. Its half-amplitude point is 2.5 ms after the tone's
    /// start, by symmetry — what the onset detector measures and takes back off.
    public static let toneEdgeSeconds = 0.005
    public static let toneFrequency = 1000.0

    /// What a stream's frame rate maps to.
    public struct Match: Sendable, Equatable {
        public let clip: Clip
        /// The stream's rate is the clip's (within `exactTolerance`).
        public let exact: Bool
    }

    /// Relative tolerance for "the same rate". 23.976 and 24 differ by 0.1 %; a 90 kHz pts stream
    /// measures 59.94 as 1501 / 1502 ticks, 0.03 % off. 0.05 % separates the two cases.
    public static let exactTolerance = 0.0005

    /// The clip for a stream at `rate` frames per second: the nearest supported rate, and whether it
    /// is the stream's own. nil for a rate that is not positive and finite.
    public static func clip(forRate rate: Double) -> Match? {
        guard rate.isFinite, rate > 0 else { return nil }
        let best = all.min { abs($0.rate - rate) / rate < abs($1.rate - rate) / rate }!
        return Match(clip: best, exact: abs(best.rate - rate) / rate <= exactTolerance)
    }
}
