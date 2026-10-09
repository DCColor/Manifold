//
//  LiveCushion.swift
//  DisplayProviders
//
//  How deep a PUSH source's live cushion (LiveClock's target depth) has to be for the stream it is
//  actually receiving, and the one line the chain readout says about it.
//  docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, "Buffer policy — the review and its decisions" and
//  Stages 0b-2a (the packing term) and 0b-2b (the reorder term).
//
//  ── WHY THE PES DURATION AND NOT THE QUEUE ─────────────────────────────────────────────────
//
//  An SRT sender that packs several AAC frames into each PES delivers its audio in lumps: nothing for
//  one PES duration, then all of it. The renderer queue has to cover that gap, and the queue IS the
//  cushion plus the sender's interleave, so a 171 ms PES against the 250 ms cushion runs the queue to
//  the starvation hold (docs/BUGS.md, "SRT audio breaks up when the sender packs ≥ ~170 ms of AAC into
//  each PES"). The packing is a property of the sender, known from the first PES and stated on every
//  one after it. The queue's low-water is not a substitute: on a sender whose video arrives in bursts
//  its first ~30 s overstate the floor by up to ~45 ms (§6.10, "The rail drain").
//
//  ── THE RULE ───────────────────────────────────────────────────────────────────────────────
//
//      cushion = min(1.0 s, max(transport default,
//                                1.5 × largest PES this session + 0.08 s,
//                                largest max(pts − dts) this session + 0.05 s))
//
//  WHY A FACTOR AND NOT JUST A MARGIN. The first form (+ 0.15 s, Stage 0b-2a) was measured against
//  ffmpeg's default packing: the settled renderer floor is cushion − 1.41 × the mean PES on every
//  fixture (hi8 80 ms, lo150 30–34 ms), not cushion − 1 PES. The audio runs ~1.4 PES behind its
//  picture, so a fixed margin covers only PES ≲ 0.3 s, and lo150 (341 ms) still broke up. 1.5 × PES +
//  0.08 s lands the floor near the ~80 ms hi8 held with 0 holds (Robbie, 2026-10-08).
//
//  THE REORDER TERM (0b-2b). The picture side has its own requirement: the clock presents a frame
//  with PTS P at about P − cushion after its arrival, so a B-frame that arrives d = pts − dts after
//  the frame it follows in decode order is already behind the renderer's sweep unless cushion > d,
//  and is discarded unseen (SRTFrameRouter, "THE REORDER WINDOW"). Cloudflare's OBS egress reorders
//  208 ms; deeper pyramids reach 0.4–0.8 s at 24p. The 50 ms covers decode and promote jitter on top.
//  Measured on every access unit from the first GOP, which arrives before the clock anchors.
//
//  GROW-ONLY within a session: a raise is a re-anchor the viewer sees once, and shrinking would be a
//  forward discard on evidence that the sender has merely gone quiet. A digital-silence PES counts
//  like any other: silence packs MORE frames per PES, and it is exactly the lump that starves.
//

import Foundation

public enum LiveCushion {

    /// The cushion per second of the largest PES, and the margin above it: the 0b-2 rule (Robbie,
    /// 2026-10-08, revised the same evening from + 0.15 s on the 0b-2a measurements).
    public static let packingFactor = 1.5
    public static let packingMarginSeconds = 0.080

    /// The margin above the largest observed reorder delay, max(pts − dts): the 0b-2b term (Robbie,
    /// 2026-10-08, buffer review decision 2).
    public static let reorderMarginSeconds = 0.050

    /// LiveClock's own ceiling on a target (`maxTargetDepth`). A sender packing more than ~610 ms per
    /// PES gets 1.0 s and still starves, rather than a buffer nobody would call live.
    public static let ceilingSeconds = 1.0

    /// A raise smaller than this is not made: float noise between two readings of the same packing,
    /// not a new figure. One millisecond is below anything the readout prints.
    public static let minimumRaiseSeconds = 0.001

    /// Which term asked for a cushion above the default, and the stream's figure behind it.
    public enum Reason: Equatable, Sendable {
        /// The largest PES this session, seconds of audio.
        case packing(Double)
        /// The largest max(pts − dts) this session, seconds.
        case reorder(Double)
    }

    /// A usable figure, or nil: missing, non-finite, zero or negative all mean "nothing to say".
    private static func figure(_ x: Double?) -> Double? {
        guard let x, x.isFinite, x > 0 else { return nil }
        return x
    }

    /// What the packing term alone asks for, nil without a usable PES.
    public static func packingTerm(largestPES: Double?) -> Double? {
        figure(largestPES).map { packingFactor * $0 + packingMarginSeconds }
    }

    /// What the reorder term alone asks for, nil without a usable reorder delay. Unclamped, so a
    /// caller can see that the ceiling does not cover it.
    public static func reorderTerm(largestReorder: Double?) -> Double? {
        figure(largestReorder).map { $0 + reorderMarginSeconds }
    }

    /// The cushion this stream asks for, and the term behind it when that is above the default. A
    /// missing or nonsense figure contributes nothing. A tie between the two terms names the packing.
    public static func wanted(transportDefault: Double, largestPES: Double?,
                              largestReorder: Double? = nil) -> (seconds: Double, reason: Reason?) {
        var best = transportDefault
        var reason: Reason?
        if let pes = figure(largestPES), let p = packingTerm(largestPES: pes), p > best {
            best = p; reason = .packing(pes)
        }
        if let d = figure(largestReorder), let r = reorderTerm(largestReorder: d), r > best {
            best = r; reason = .reorder(d)
        }
        return (min(ceilingSeconds, best), reason)
    }

    /// The cushion this stream asks for.
    public static func seconds(transportDefault: Double, largestPES: Double?,
                               largestReorder: Double? = nil) -> Double {
        wanted(transportDefault: transportDefault, largestPES: largestPES, largestReorder: largestReorder).seconds
    }

    /// The new cushion and its reason if the stream asks for more than `current`, or nil. Never lower:
    /// grow-only.
    public static func raise(current: Double, transportDefault: Double, largestPES: Double?,
                             largestReorder: Double? = nil) -> (seconds: Double, reason: Reason)? {
        let want = wanted(transportDefault: transportDefault, largestPES: largestPES,
                          largestReorder: largestReorder)
        guard want.seconds - current >= minimumRaiseSeconds, let reason = want.reason else { return nil }
        return (want.seconds, reason)
    }

    /// True when the reorder term asks for more than the ceiling: even the largest cushion leaves less
    /// than the margin, and at a reorder ≥ the ceiling pictures are discarded. The one case the user is
    /// warned about.
    public static func reorderBeyondCeiling(largestReorder: Double?) -> Bool {
        guard let r = reorderTerm(largestReorder: largestReorder) else { return false }
        return r > ceilingSeconds
    }

    /// What the chain readout's Buffer row says about one push source.
    public struct Report: Equatable, Sendable {
        /// "SRT", "WHEP": the transport's name as the readout prints it.
        public var transport: String
        /// The cushion the clock holds now.
        public var cushion: Double
        /// The transport's default; `cushion` above it is a raise.
        public var transportDefault: Double
        /// The transport's own buffer, when it has one and has stated it (SRT's negotiated latency).
        public var transportLatencyMs: Int?
        /// The term behind a raise; nil when nothing was raised.
        public var raisedBy: Reason?

        public init(transport: String, cushion: Double, transportDefault: Double,
                    transportLatencyMs: Int? = nil, raisedBy: Reason? = nil) {
            self.transport = transport; self.cushion = cushion; self.transportDefault = transportDefault
            self.transportLatencyMs = transportLatencyMs; self.raisedBy = raisedBy
        }

        /// Whole milliseconds, as everything else in the readout prints them.
        private static func ms(_ s: Double) -> Int { Int((s * 1000).rounded()) }

        /// "250 ms + SRT 120 ms", and when raised
        /// "336 ms + SRT 120 ms — raised 86 ms: the sender packs 171 ms of audio per packet" or
        /// "259 ms + SRT 120 ms — raised 9 ms: the stream reorders 209 ms of pictures".
        /// The raise is the difference of the two printed figures, so the line's own arithmetic adds up.
        public var text: String {
            var s = "\(Self.ms(cushion)) ms"
            if let l = transportLatencyMs { s += " + \(transport) \(l) ms" }
            let raised = Self.ms(cushion) - Self.ms(transportDefault)
            if raised > 0, let reason = raisedBy {
                s += " — raised \(raised) ms: " + Self.because(reason)
            }
            return s
        }

        /// The reason, in the readout's words.
        public static func because(_ reason: Reason) -> String {
            switch reason {
            case .packing(let pes): return "the sender packs \(ms(pes)) ms of audio per packet"
            case .reorder(let d):   return "the stream reorders \(ms(d)) ms of pictures"
            }
        }
    }
}
