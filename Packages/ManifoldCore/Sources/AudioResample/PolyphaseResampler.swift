//
//  PolyphaseResampler.swift
//  AudioResample
//
//  Polyphase windowed-sinc asynchronous sample-rate converter.
//
//  ⚠️ NOTHING IN THE APP CALLS THIS YET. Build step 1 of docs/AUDIO_RESAMPLER_DESIGN.md §7 is
//  deliberately offline: the structure is measured against synthesised material before a line of
//  it is wired into a live path, because §3.1's requirement — a mid-stream ratio change with no
//  discontinuity, at any ratio, at any instant — is a yes/no property and the whole design rests
//  on it.
//
//  ── THE STRUCTURE, AND WHY A RATIO CHANGE IS FREE BY CONSTRUCTION ──────────────────────────
//
//  The ratio appears in exactly one place: `increment`, added to a Q32.32 phase accumulator once
//  per output frame. There is no filter state keyed to the ratio, no buffer to flush, no prime to
//  redo. Writing a new increment between two output frames yields exactly the output that would
//  have been produced had the new ratio always been in force from that frame on — which is the
//  definition of continuity for a time warp.
//
//  That is a property of the structure, not a result that needs re-verifying after an OS update.
//  §3.2–§3.4 reject AVAudioConverter, AudioConverterRef and the Varispeed AU precisely because
//  none of them can say that sentence.
//
//  ── THE ACCUMULATOR IS Q32.32 AND NOT A Double ────────────────────────────────────────────
//
//  A Double phase accumulated across a 30-minute session (48000 × 1800 = 8.64e7 increments) loses
//  low bits monotonically. UInt64 fixed point is exact, and its integer half IS the input sample
//  index with no rounding rule to get wrong. The output PTS axis is derived by COUNTING OUTPUT
//  FRAMES and never from the accumulator — the same discipline as `NDIService.audioPTSTicks` and
//  `SRTFrameRouter.audioPTSTicks`.
//

import Accelerate

public final class PolyphaseResampler {

    /// One Q32.32 unit is one input frame.
    @usableFromInline static let one: UInt64 = 1 << 32

    public let channels: Int
    public let prototype: PolyphasePrototype

    private let taps: Int
    private let branches: Int
    /// `frac >> shift` selects the branch; the remaining bits are the inter-branch fraction.
    private let branchShift: UInt64
    private let muScale: Float

    /// Phase within the current scratch buffer, Q32.32.
    private var phase: UInt64
    /// Phase in absolute input-frame coordinates, never rebased. Diagnostics and the test
    /// harness's reference warp read this; the audio path does not.
    private var absolutePhase: UInt64

    private var increment: UInt64

    /// Per-channel tail: the input frames a future call still needs in its filter window.
    private var tail: [[Float]]

    /// Output frames produced since construction. **This is the PTS axis.**
    public private(set) var outputFrameCount: UInt64 = 0

    /// When true, `phaseTrace` records the absolute Q32.32 phase used for each output frame.
    /// Off by default: it allocates per output frame and has no place in a live path.
    public var capturesPhase = false
    public private(set) var phaseTrace: [UInt64] = []

    /// Group delay, in input frames. Exactly `taps / 2`.
    public var latencyFrames: Int { taps / 2 }

    /// - Parameters:
    ///   - channels: channel count; buffers are per-channel and contiguous (deinterleaved).
    ///   - ratio: output frames per input frame.
    ///   - prototype: the coefficient table.
    public init(channels: Int, ratio: Double = 1.0, prototype: PolyphasePrototype = PolyphasePrototype()) {
        precondition(channels > 0)
        self.channels = channels
        self.prototype = prototype
        self.taps = prototype.taps
        self.branches = prototype.branches

        var shift: UInt64 = 32
        var b = prototype.branches
        while b > 1 { b >>= 1; shift -= 1 }
        precondition(1 << (32 - shift) == UInt64(prototype.branches), "branches must be a power of two")
        self.branchShift = shift
        self.muScale = 1.0 / Float(1 << shift)

        self.increment = Self.increment(forRatio: ratio)
        // ── WHY THE PHASE STARTS AT ONE INPUT FRAME ───────────────────────────────────────
        //
        // The filter window for the reconstruction instant τ spans input indices
        // `floor(τ) - taps/2 + 1 ... floor(τ) + taps/2`. Priming the history with `taps` zeros and
        // starting the phase at 1 puts the first output's τ at exactly `taps/2`, so at ratio 1.0
        // `out[n] == in[n - taps/2]` — the group delay is exactly taps/2 and nothing else has to
        // be booked anywhere. Starting at 0 gives taps/2 + 1, which is the off-by-one this note
        // exists to stop being rediscovered.
        self.phase = Self.one
        self.absolutePhase = Self.one
        self.tail = Array(repeating: [Float](repeating: 0, count: prototype.taps), count: channels)
    }

    /// Output frames per input frame. Writing it takes effect on the next output frame and is
    /// glitch-free by construction — see the file note.
    public var ratio: Double {
        get { Double(Self.one) / Double(increment) }
        set { increment = Self.increment(forRatio: newValue) }
    }

    /// The raw Q32.32 increment, for tests that need the exact rational the ratio was quantised to.
    public var phaseIncrement: UInt64 {
        get { increment }
        set { increment = newValue }
    }

    @inline(__always)
    static func increment(forRatio ratio: Double) -> UInt64 {
        precondition(ratio > 0, "ratio must be positive")
        let inc = (Double(one) / ratio).rounded()
        precondition(inc >= 1 && inc < Double(UInt64.max), "ratio out of representable range")
        return UInt64(inc)
    }

    /// The absolute reconstruction instant, in input frames, of the next output frame.
    public var nextInputPosition: Double { Double(absolutePhase) / Double(Self.one) }

    /// Resample one block.
    ///
    /// - Parameters:
    ///   - input: `channels` arrays of equal length, deinterleaved.
    ///   - output: `channels` arrays, each at least `maximumOutputFrames(for:)` long.
    /// - Returns: frames written to each output channel.
    ///
    /// ⚠️ DEINTERLEAVED, PER CHANNEL, CONTIGUOUS — NOT STRIDED OVER AN INTERLEAVED BUFFER.
    /// §3.6 names the strided-over-Int32-at-stride-16 shortcut as the obvious wrong turn: it is
    /// cache-hostile and it defeats the vector unit. The deinterleave belongs at the integration
    /// seam (build step 3), once per buffer.
    @discardableResult
    public func process(input: [[Float]], output: inout [[Float]]) -> Int {
        precondition(input.count == channels && output.count == channels)
        let inCount = input[0].count
        // ⚠️ FROM THE ACTUAL TAIL, NOT FROM `taps`. The retained tail is always SHORTER than
        // `taps` — the loop stops at the first `idx` with `idx + taps > scratchCount`, so what is
        // left over is `scratchCount - consumed < taps`, typically taps - 1. Writing
        // `taps + inCount` here therefore claims one frame more than the buffer holds, and the
        // loop then runs one extra iteration whose `vDSP_dotpr` reads one element PAST THE END
        // through the unsafe pointer. It does not crash — the overrun lands in allocation slack —
        // and the extra output frame is numerically plausible, so nothing downstream looks wrong.
        //
        // Caught by the streaming-vs-one-shot equivalence check in test 1, which produced 8202
        // frames against the one-shot's 8192 while every compared sample matched exactly. A test
        // that only compared overlapping samples would have passed it.
        let scratchCount = tail[0].count + inCount

        // scratch[c] = tail (taps frames) ++ input
        var scratch = [[Float]](repeating: [], count: channels)
        for c in 0..<channels {
            precondition(input[c].count == inCount, "channels must be the same length")
            var s = [Float](); s.reserveCapacity(scratchCount)
            s.append(contentsOf: tail[c]); s.append(contentsOf: input[c])
            scratch[c] = s
        }

        var produced = 0
        var coefficients = [Float](repeating: 0, count: taps)
        let tapsCount = vDSP_Length(taps)

        prototype.table.withUnsafeBufferPointer { tablePtr in
        prototype.delta.withUnsafeBufferPointer { deltaPtr in
        coefficients.withUnsafeMutableBufferPointer { h in
            while true {
                let idx = Int(phase >> 32)
                // The window is scratch[idx ..< idx + taps]; stop when it would run past the end.
                if idx + taps > scratchCount { break }

                let frac = UInt32(truncatingIfNeeded: phase)
                let branch = Int(UInt64(frac) >> branchShift)
                let mu = Float(UInt64(frac) & ((1 << branchShift) - 1)) * muScale

                // h = table[branch] + mu * delta[branch]   — once per output frame, shared by
                // every channel, which is the whole reason the phase is common.
                var m = mu
                vDSP_vsma(deltaPtr.baseAddress! + branch * taps, 1,
                          &m,
                          tablePtr.baseAddress! + branch * taps, 1,
                          h.baseAddress!, 1, tapsCount)

                for c in 0..<channels {
                    var acc: Float = 0
                    scratch[c].withUnsafeBufferPointer { x in
                        vDSP_dotpr(x.baseAddress! + idx, 1, h.baseAddress!, 1, &acc, tapsCount)
                    }
                    output[c][produced] = acc
                }

                if capturesPhase { phaseTrace.append(absolutePhase) }
                produced += 1
                phase &+= increment
                absolutePhase &+= increment
            }
        }}}

        // Retire the consumed head. What remains is the frames a later window can still reach.
        let consumed = Int(phase >> 32)
        let keep = scratchCount - consumed
        for c in 0..<channels {
            tail[c] = Array(scratch[c][consumed...])
        }
        _ = keep
        phase &-= UInt64(consumed) << 32

        outputFrameCount &+= UInt64(produced)
        return produced
    }

    /// A safe upper bound on the frames `process` can emit for a given input length.
    public func maximumOutputFrames(for inputFrames: Int) -> Int {
        let available = UInt64(inputFrames + taps) << 32
        let start = phase
        guard available > start else { return 0 }
        return Int((available - start) / increment) + 2
    }

    /// Output PTS, in seconds, of the NEXT frame this resampler will emit.
    ///
    /// Counted from output frames. It is never derived from the phase accumulator, and the reason
    /// is §9's transferable lesson: a timing quantity that is exact in one representation can be
    /// unrepresentable in the one it is stored in. Frames are integers.
    public func nextOutputPTS(sampleRate: Double, origin: Double = 0) -> Double {
        origin + Double(outputFrameCount) / sampleRate
    }
}

// MARK: - Reference implementation, for the test harness only

/// Evaluates the SAME time warp by direct windowed-sinc evaluation — no branch table, no
/// inter-branch interpolation, every coefficient computed in Double at the exact fractional delay.
///
/// ⚠️ NOT FOR PRODUCTION USE. Two transcendental calls per tap per output frame, in Double.
/// It exists so the polyphase path can be nulled against something built a different way: a
/// reference that shared the table would only prove the table is self-consistent.
public enum ReferenceSincResampler {

    /// - Parameters:
    ///   - scratch: `taps` frames of history followed by the input, per channel — the same buffer
    ///     the polyphase path sees.
    ///   - phases: absolute Q32.32 reconstruction instants, one per output frame.
    public static func process(scratch: [[Float]],
                               phases: [UInt64],
                               prototype: PolyphasePrototype) -> [[Double]] {
        let taps = prototype.taps
        let half = Double(taps) / 2.0
        let i0beta = besselI0(prototype.beta)
        let channels = scratch.count
        var out = [[Double]](repeating: [Double](repeating: 0, count: phases.count), count: channels)

        var coefficients = [Double](repeating: 0, count: taps)
        for (n, p) in phases.enumerated() {
            let idx = Int(p >> 32)
            let frac = Double(UInt32(truncatingIfNeeded: p)) / 4294967296.0
            var sum = 0.0
            for j in 0..<taps {
                let x = half - 1.0 + frac - Double(j)
                let r = x / half
                let w = besselI0(prototype.beta * (max(0.0, 1.0 - r * r)).squareRoot()) / i0beta
                let v = 2.0 * prototype.cutoff * sinc(2.0 * prototype.cutoff * x) * w
                coefficients[j] = v
                sum += v
            }
            let scale = 1.0 / sum
            for c in 0..<channels {
                var acc = 0.0
                for j in 0..<taps { acc += coefficients[j] * scale * Double(scratch[c][idx + j]) }
                out[c][n] = acc
            }
        }
        return out
    }
}
