//
//  LiveAudioSplicer.swift
//  LiveAudioResample
//
//  Build step 5 of docs/AUDIO_RESAMPLER_DESIGN.md §7: the splice (§2.4). A jump of the stage's
//  INPUT read head by ±N frames across an equal-power cross-fade — the audio analogue of the video
//  timeline jump that caused it. Sits in front of the resampler, inside `LiveAudioResampleStage`,
//  one instance per stage session. Pure arithmetic over planar Float; no media types, no clocks.
//
//  ── ONE OPERATION, BOTH DIRECTIONS ────────────────────────────────────────────────────────────
//
//  The content stream arrives in order and is kept in a history ring. Normally everything that
//  arrives is fed on at once. A splice of `delta` frames at read position r0 feeds
//
//      out[i] = cos θᵢ · x[r0 + i]  +  sin θᵢ · x[r0 + delta + i],     θᵢ = (i + ½)/F · π/2,  i < F
//
//  and then carries on from `r0 + delta + F`.
//
//    * delta > 0 — FORWARD (a LiveClock snap, freeze guard or queue-full: the picture discarded
//      content). DROP: `delta` frames of content are never fed. It has to wait for x[r0+delta+F]
//      to ARRIVE, so nothing is fed for about `delta` of real time; the renderer plays that out of
//      its queue, which the event that caused it had over-filled by the same amount.
//    * delta < 0 — BACKWARD (a target raise). INSERT: the read head goes back `|delta|` and replays
//      from the ring. It waits only for x[r0 + F − 1], the fade-out's last frame.
//
//  A DROP IS NOT BOUNDED BY THE RING. It needs only its two fades: the fade-out x[r0 ..< r0+F] is
//  copied aside as soon as it arrives, and the ring may then move on past it while the skipped
//  content streams through unfed; the fade-in x[to ..< to+F] is taken from the ring the moment it
//  lands. So `maximumSplice` bounds INSERTS (which replay from the ring) and a drop may be as long as
//  the caller allows — the starvation recovery's whole-debt cut is up to seconds (§18.19).
//
//  ⚠️ AN INSERT IS REPEATED MATERIAL, NOT SILENCE, AND THAT IS STEP 5's ONE REAL DECISION. Silence
//  is a run of digital zero as long as the jump — at 200 ms, 2.5× the 78 ms mute this step exists
//  to remove, and exactly what the §11.9 harness counts as one. Replay keeps the envelope and the
//  level; its cost is that `|delta|` of programme is heard twice. The report for step 5 has the
//  trade in full.
//
//  ── WHY cos/sin ───────────────────────────────────────────────────────────────────────────────
//
//  cos²θ + sin²θ = 1 at every frame, so two UNCORRELATED signals keep their power through the fade.
//  At the sizes this runs at (≥ 50 ms, the step trigger) the two positions are uncorrelated for
//  programme material. For a steady periodic signal they are correlated at whatever phase `delta`
//  lands on, and the fade can dip (antiphase) or rise up to +3 dB (in phase) for its 10 ms — the
//  known cost of equal-power, stated rather than tuned away.
//

import Foundation

final class LiveAudioSplicer {

    /// A splice as executed, in FED-frame coordinates: from fed frame `fed` on, the content index is
    /// `delta` further than it was. At the fade's midpoint — the fed frame that is half each side.
    struct Mark: Equatable {
        let fed: Int64
        let delta: Int64
        let id: Int
    }

    enum Outcome: Equatable {
        case executed(id: Int, delta: Int64)
        case abandoned(id: Int, delta: Int64, reason: String)
    }

    let channels: Int
    let crossfade: Int
    /// Frames of history kept: the largest splice, its fade, and one sub-chunk.
    let capacity: Int
    /// Input is taken in pieces of at most this, so the ring never has to hold more than one piece
    /// past what a splice needs — a 1 s silence fill for a hole arrives as one planar block.
    let chunk: Int

    private var ring: [[Float]]
    /// Content frames that have arrived (W) and the next content frame to feed (R).
    private(set) var written: Int64 = 0
    private(set) var readHead: Int64 = 0
    /// Frames fed on so far — the resampler's input frame count.
    private(set) var fed: Int64 = 0

    private var queue: [(id: Int, delta: Int64)] = []
    private var active: (id: Int, delta: Int64, r0: Int64)?
    /// An active DROP's fade-out, [channel][k], kept once it has arrived (see the header).
    private var savedFadeOut: [[Float]]?
    private let fadeOut: [Float]
    private let fadeIn: [Float]

    init(channels: Int, crossfade: Int, maximumSplice: Int, chunk: Int = 4096) {
        precondition(channels > 0 && crossfade > 0 && maximumSplice > 0 && chunk > 0)
        self.channels = channels
        self.crossfade = crossfade
        self.chunk = chunk
        self.capacity = maximumSplice + crossfade + chunk
        self.ring = [[Float]](repeating: [Float](repeating: 0, count: capacity), count: channels)
        var o = [Float](repeating: 0, count: crossfade), i = [Float](repeating: 0, count: crossfade)
        for k in 0..<crossfade {
            let theta = (Double(k) + 0.5) / Double(crossfade) * Double.pi / 2
            o[k] = Float(cos(theta)); i[k] = Float(sin(theta))
        }
        fadeOut = o; fadeIn = i
    }

    /// Nothing queued and nothing waiting for content.
    var isIdle: Bool { active == nil && queue.isEmpty }

    /// The fade's gains, for the equal-power test.
    var gains: (out: [Float], in: [Float]) { (fadeOut, fadeIn) }

    /// Queue a splice. It starts at the read position current when every splice before it is done.
    func enqueue(id: Int, delta: Int64) {
        precondition(delta != 0)
        queue.append((id, delta))
    }

    /// Take `count` frames of content (planar, `input[c][0..<count]`), append what is to be fed to
    /// `out[c]`. Returns the marks of splices executed on this call, in fed order, and what became
    /// of each splice that finished (executed or abandoned).
    func process(_ input: [[Float]], count: Int, into out: inout [[Float]])
        -> (marks: [Mark], outcomes: [Outcome]) {
        var marks: [Mark] = [], outcomes: [Outcome] = []
        var start = 0
        repeat {
            let n = min(chunk, count - start)
            if n > 0 { append(input, from: start, count: n) }
            advance(into: &out, marks: &marks, outcomes: &outcomes)
            start += n
        } while start < count
        return (marks, outcomes)
    }

    /// End of this splicer's session (format reset, axis break, retire): every queued or waiting
    /// splice is abandoned, and content held back for one is fed on as it stands, so nothing that
    /// arrived is silently lost.
    func abandonAll(reason: String, into out: inout [[Float]]) -> [Outcome] {
        var outcomes: [Outcome] = []
        if let a = active { outcomes.append(.abandoned(id: a.id, delta: a.delta, reason: reason)) }
        for q in queue { outcomes.append(.abandoned(id: q.id, delta: q.delta, reason: reason)) }
        active = nil; queue = []; savedFadeOut = nil
        var ignored: [Mark] = []
        advance(into: &out, marks: &ignored, outcomes: &outcomes)
        return outcomes
    }

    // MARK: - Internals

    private func append(_ input: [[Float]], from: Int, count n: Int) {
        let at = Int(written % Int64(capacity))
        let first = min(n, capacity - at)
        for c in 0..<channels {
            input[c].withUnsafeBufferPointer { src in
                ring[c].withUnsafeMutableBufferPointer { dst in
                    (dst.baseAddress! + at).update(from: src.baseAddress! + from, count: first)
                    if n > first {
                        dst.baseAddress!.update(from: src.baseAddress! + from + first, count: n - first)
                    }
                }
            }
        }
        written += Int64(n)
    }

    private func copy(from index: Int64, count n: Int, into out: inout [[Float]]) {
        guard n > 0 else { return }
        let at = Int(index % Int64(capacity))
        let first = min(n, capacity - at)
        for c in 0..<channels {
            out[c].append(contentsOf: ring[c][at..<(at + first)])
            if n > first { out[c].append(contentsOf: ring[c][0..<(n - first)]) }
        }
    }

    private func advance(into out: inout [[Float]], marks: inout [Mark], outcomes: inout [Outcome]) {
        while true {
            if active == nil, !queue.isEmpty {
                let q = queue.removeFirst()
                active = (q.id, q.delta, readHead)
            }
            guard let a = active else {
                // Only after an abandoned back-to-back pair can the ring have overwritten content
                // not yet fed; it is gone, so skip it rather than feed stale ring slots.
                readHead = max(readHead, written - Int64(capacity))
                copy(from: readHead, count: Int(written - readHead), into: &out)
                fed += written - readHead
                readHead = written
                return
            }
            let to = a.r0 + a.delta
            if to < 0 {
                outcomes.append(.abandoned(id: a.id, delta: a.delta,
                                           reason: "insert reaches before the session's first frame"))
                active = nil
                continue
            }
            let oldest = written - Int64(capacity)
            // A drop keeps its fade-out aside once it has arrived, so the ring may pass it.
            if a.delta > 0, savedFadeOut == nil, written >= a.r0 + Int64(crossfade), a.r0 >= oldest {
                savedFadeOut = (0..<channels).map { c in
                    (0..<crossfade).map { k in ring[c][Int((a.r0 + Int64(k)) % Int64(capacity))] }
                }
            }
            // Wait for the later of the two fades' last frames.
            guard written >= max(a.r0, to) + Int64(crossfade) else { return }
            if (a.r0 < oldest && savedFadeOut == nil) || to < oldest {
                outcomes.append(.abandoned(id: a.id, delta: a.delta,
                                           reason: "history ring no longer holds the splice's material"))
                active = nil; savedFadeOut = nil
                continue
            }
            let held = savedFadeOut
            let base = out[0].count
            for c in 0..<channels { out[c].append(contentsOf: repeatElement(0, count: crossfade)) }
            for k in 0..<crossfade {
                let p = Int((a.r0 + Int64(k)) % Int64(capacity))
                let q = Int((to + Int64(k)) % Int64(capacity))
                for c in 0..<channels {
                    out[c][base + k] = fadeOut[k] * (held?[c][k] ?? ring[c][p]) + fadeIn[k] * ring[c][q]
                }
            }
            marks.append(Mark(fed: fed + Int64(crossfade / 2), delta: a.delta, id: a.id))
            outcomes.append(.executed(id: a.id, delta: a.delta))
            fed += Int64(crossfade)
            readHead = to + Int64(crossfade)
            active = nil; savedFadeOut = nil
        }
    }
}
