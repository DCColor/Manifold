//
//  LiveCushion.swift
//  DisplayProviders
//
//  How deep a PUSH source's live cushion (LiveClock's target depth) has to be for the stream it is
//  actually receiving, and the one line the chain readout says about it.
//  docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, "Buffer policy — the review and its decisions" and
//  Stage 0b-2a.
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
//      cushion = min(1.0 s, max(transport default, 1.5 × largest PES this session + 0.08 s))
//
//  WHY A FACTOR AND NOT JUST A MARGIN. The first form (+ 0.15 s, Stage 0b-2a) was measured against
//  ffmpeg's default packing: the settled renderer floor is cushion − 1.41 × the mean PES on every
//  fixture (hi8 80 ms, lo150 30–34 ms), not cushion − 1 PES. The audio runs ~1.4 PES behind its
//  picture, so a fixed margin covers only PES ≲ 0.3 s, and lo150 (341 ms) still broke up. 1.5 × PES +
//  0.08 s lands the floor near the ~80 ms hi8 held with 0 holds (Robbie, 2026-10-08).
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

    /// LiveClock's own ceiling on a target (`maxTargetDepth`). A sender packing more than ~610 ms per
    /// PES gets 1.0 s and still starves, rather than a buffer nobody would call live.
    public static let ceilingSeconds = 1.0

    /// A raise smaller than this is not made: float noise between two readings of the same packing,
    /// not a new figure. One millisecond is below anything the readout prints.
    public static let minimumRaiseSeconds = 0.001

    /// The cushion this packing asks for. A missing or nonsense PES figure asks for the default.
    public static func seconds(transportDefault: Double, largestPES: Double?) -> Double {
        guard let pes = largestPES, pes.isFinite, pes > 0 else { return transportDefault }
        return min(ceilingSeconds, max(transportDefault, packingFactor * pes + packingMarginSeconds))
    }

    /// The new cushion if the packing asks for more than `current`, or nil. Never lower: grow-only.
    public static func raise(current: Double, transportDefault: Double, largestPES: Double?) -> Double? {
        let want = seconds(transportDefault: transportDefault, largestPES: largestPES)
        return want - current >= minimumRaiseSeconds ? want : nil
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
        /// The largest PES behind a raise, seconds; nil when nothing was raised.
        public var raisedForPES: Double?

        public init(transport: String, cushion: Double, transportDefault: Double,
                    transportLatencyMs: Int? = nil, raisedForPES: Double? = nil) {
            self.transport = transport; self.cushion = cushion; self.transportDefault = transportDefault
            self.transportLatencyMs = transportLatencyMs; self.raisedForPES = raisedForPES
        }

        /// Whole milliseconds, as everything else in the readout prints them.
        private static func ms(_ s: Double) -> Int { Int((s * 1000).rounded()) }

        /// "250 ms + SRT 120 ms", and when raised
        /// "321 ms + SRT 120 ms — raised 71 ms: the sender packs 171 ms of audio per packet".
        /// The raise is the difference of the two printed figures, so the line's own arithmetic adds up.
        public var text: String {
            var s = "\(Self.ms(cushion)) ms"
            if let l = transportLatencyMs { s += " + \(transport) \(l) ms" }
            let raised = Self.ms(cushion) - Self.ms(transportDefault)
            if raised > 0, let pes = raisedForPES {
                s += " — raised \(raised) ms: the sender packs \(Self.ms(pes)) ms of audio per packet"
            }
            return s
        }
    }
}
