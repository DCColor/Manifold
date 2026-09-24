//
//  KaiserPrototype.swift
//  AudioResample
//
//  The windowed-sinc prototype and its polyphase decomposition.
//
//  Pure arithmetic over arrays, no Foundation, no audio types — so it can be measured
//  offline against synthesised material before anything is wired in. See
//  docs/AUDIO_RESAMPLER_DESIGN.md §3.6 and §7 step 1.
//

/// Modified Bessel function of the first kind, order zero. Series expansion, which converges
/// quickly for the β range a Kaiser window uses (β ≤ ~20) and is exact to double precision
/// long before the loop bound bites.
@inline(__always)
func besselI0(_ x: Double) -> Double {
    var sum = 1.0
    var term = 1.0
    let halfSquared = (x * 0.5) * (x * 0.5)
    var k = 1.0
    while k < 64 {
        term *= halfSquared / (k * k)
        sum += term
        if term < sum * 1e-18 { break }
        k += 1
    }
    return sum
}

/// `sin(πx)/(πx)`, with the removable singularity handled.
///
/// ⚠️ THE `x == 0` CASE IS THE ONLY ONE THAT NEEDS SPECIAL HANDLING, AND THE INTEGER CASES
/// DELIBERATELY DO NOT. At cutoff 0.5 and branch 0 the argument is an exact integer, where the
/// true value is zero; `sin(Double.pi * n)` returns ~1e-16 rather than 0 because π is not
/// representable. That residue is ~1e-17 after the division and is far below Float's 1.2e-7
/// epsilon, so it cannot affect a Float table. Forcing it to zero would be a lie about the
/// arithmetic that happens to be invisible — and the identity test proves the point empirically
/// rather than by construction.
@inline(__always)
func sinc(_ x: Double) -> Double {
    if x == 0 { return 1.0 }
    let pix = Double.pi * x
    return _sin(pix) / pix
}

@inline(__always) private func _sin(_ x: Double) -> Double {
    // Foundation-free: the platform libm symbol.
    return Foundation_sin(x)
}

#if canImport(Darwin)
import Darwin
@inline(__always) private func Foundation_sin(_ x: Double) -> Double { Darwin.sin(x) }
#else
import Glibc
@inline(__always) private func Foundation_sin(_ x: Double) -> Double { Glibc.sin(x) }
#endif

/// The polyphase coefficient table, plus the per-branch first differences that linear
/// inter-branch interpolation consumes.
public struct PolyphasePrototype: Sendable {

    /// Filter length in input samples. 64 per the design.
    public let taps: Int
    /// Number of polyphase branches. **1024** — see the note on `init`.
    public let branches: Int
    /// Lowpass cutoff in cycles per input sample. 0.5 is Nyquist.
    public let cutoff: Double
    /// Kaiser β, derived from the requested stopband attenuation.
    public let beta: Double

    /// `(branches + 1) * taps` floats, branch-major.
    ///
    /// THE GUARD BRANCH IS WHY IT IS `branches + 1`. Linear inter-branch interpolation at branch
    /// `p` reads `p` and `p + 1`; at `p == branches - 1` that is branch `branches`, which is
    /// fractional delay exactly 1.0. It is generated from the same formula rather than aliased to
    /// branch 0, because branch 0 shifted by one sample is only *equal* to it when the table is
    /// symmetric, and depending on that identity is how an off-by-one hides.
    public let table: [Float]

    /// `branches * taps` floats: `table[p + 1] - table[p]`, precomputed so the per-frame
    /// coefficient build is one `vDSP_vsma` rather than a subtract and a multiply-add.
    public let delta: [Float]

    /// - Parameters:
    ///   - taps: filter length in input samples.
    ///   - branches: polyphase branch count.
    ///   - cutoff: lowpass cutoff in cycles per input sample. **0.5 (Nyquist) is the right value
    ///     for this application and is the default** — see the note below.
    ///   - stopbandDB: target stopband attenuation, which sets Kaiser β.
    ///
    /// ── ⚠️ WHY THE DEFAULT CUTOFF IS 0.5 AND NOT THE DESIGN'S 0.45 ──────────────────────────
    ///
    /// `docs/AUDIO_RESAMPLER_DESIGN.md` §3.6 says "cutoff at 0.45·fs (21.6 kHz)". That value is
    /// carried over from general rate conversion, where the filter must also suppress content that
    /// decimation would fold. **This resampler never decimates**: §5.2 bounds the ratio at
    /// ±500 ppm, so it is a fractional-delay interpolator, and pulling the cutoff below Nyquist
    /// buys nothing while costing the top of the audio band.
    ///
    /// Two of the step-1 acceptance targets are unreachable at 0.45, for one arithmetic reason. A
    /// Kaiser design of length N has transition width Δf ≈ (A − 8) / (2.285 · 2π · N); at N = 64
    /// and A = 100 dB that is **0.100 cycles/sample, i.e. 4.8 kHz**. Centred on 21.6 kHz the
    /// passband edge therefore lands at **19.2 kHz** — so 20 kHz sits *inside the transition band*
    /// and the passband-ripple target cannot be met, no matter how the rest is built.
    ///
    /// At cutoff 0.5 the passband edge is 21.6 kHz, 20 kHz is well inside it, and the images that
    /// actually matter are unaffected: a tone at f has its nearest image at fs − f, which for
    /// f ≤ 20 kHz is ≥ 28 kHz and sits above the 26.4 kHz stopband edge.
    ///
    /// **And cutoff 0.5 is what makes branch 0 an exact unit impulse**, because `sinc(n)` is zero
    /// at every non-zero integer. That is the identity property at ratio 1.0. At 0.45 branch 0 is a
    /// lowpass filter and ratio 1.0 is NOT a pass-through — measured in the test suite, not argued.
    /// ── ⚠️ WHY THE DEFAULT BRANCH COUNT IS 1024 AND NOT THE DESIGN'S 512 ────────────────────
    ///
    /// Linear interpolation BETWEEN branches leaves an error that falls as 1/P² — **12 dB per
    /// doubling** — and it, not the prototype's stopband, is what sets the resampler's effective
    /// resolution. §3.6 attributed the figure to the stopband, which is not the binding constraint.
    ///
    /// Measured on a full-scale 20 Hz–20 kHz sweep (§9.3), against a > 20-bit target:
    ///
    ///     P =  512   SNR 119.5 dB   19.6 bits    <- the design's value: MISSES
    ///     P = 1024   SNR 131.3 dB   21.5 bits    <- this default
    ///     P = 2048   SNR 140.7 dB   23.1 bits
    ///
    /// 512 → 1024 gains 11.8 dB, which is the 1/P² law to within the measurement. 1024 → 2048
    /// gains only 9.4 dB because it is running into the 143 dB Float-arithmetic floor, so **2048
    /// is roughly where more branches stop buying bits in a Float pipeline** — worth knowing
    /// before anyone reaches for it.
    ///
    /// **The per-frame cost is unchanged.** The branch index is a shift of the phase accumulator,
    /// not a search, and the coefficient build is still one `vDSP_vsma` over `taps`. What doubles
    /// is the table: 256 KB plus a 256 KB difference table, against 128 + 128 KB at P = 512.
    public init(taps: Int = 64, branches: Int = 1024, cutoff: Double = 0.5, stopbandDB: Double = 100) {
        precondition(taps > 0 && taps % 2 == 0, "taps must be positive and even")
        precondition(branches > 0, "branches must be positive")
        precondition(cutoff > 0 && cutoff <= 0.5, "cutoff is in cycles per input sample, (0, 0.5]")
        self.taps = taps
        self.branches = branches
        self.cutoff = cutoff

        // Kaiser β from stopband attenuation (Kaiser's empirical formula).
        let a = stopbandDB
        if a > 50 {
            beta = 0.1102 * (a - 8.7)
        } else if a >= 21 {
            beta = 0.5842 * _pow(a - 21, 0.4) + 0.07886 * (a - 21)
        } else {
            beta = 0
        }

        let i0beta = besselI0(beta)
        let half = Double(taps) / 2.0
        var t = [Float](repeating: 0, count: (branches + 1) * taps)

        for p in 0...branches {
            let frac = Double(p) / Double(branches)
            var row = [Double](repeating: 0, count: taps)
            var sum = 0.0
            for j in 0..<taps {
                // Position of tap j relative to the reconstruction instant. The window's support
                // is exactly |x| <= taps/2, and this expression stays inside it for every branch:
                // j = 0 gives 31 + frac <= 32, j = taps-1 gives -32 + frac >= -32.
                let x = half - 1.0 + frac - Double(j)
                let ratio = x / half
                let w = besselI0(beta * _sqrt(max(0.0, 1.0 - ratio * ratio))) / i0beta
                let v = 2.0 * cutoff * sinc(2.0 * cutoff * x) * w
                row[j] = v
                sum += v
            }
            // ── PER-BRANCH DC NORMALISATION ────────────────────────────────────────────────
            //
            // Each branch is scaled to sum exactly 1. Without it, the branch sums vary by ~1e-5
            // and the gain therefore wobbles as the fractional phase sweeps — a slow amplitude
            // ripple that is inaudible but lands squarely in the effective-resolution figure.
            //
            // It cannot disturb the identity property: at cutoff 0.5 branch 0 already sums to
            // 1 ± 1e-16, so its scale factor is unity to within double rounding.
            let scale = 1.0 / sum
            for j in 0..<taps { t[p * taps + j] = Float(row[j] * scale) }
        }
        table = t

        var d = [Float](repeating: 0, count: branches * taps)
        for p in 0..<branches {
            for j in 0..<taps {
                d[p * taps + j] = t[(p + 1) * taps + j] - t[p * taps + j]
            }
        }
        delta = d
    }
}

@inline(__always) private func _pow(_ x: Double, _ y: Double) -> Double {
    #if canImport(Darwin)
    return Darwin.pow(x, y)
    #else
    return Glibc.pow(x, y)
    #endif
}

@inline(__always) private func _sqrt(_ x: Double) -> Double {
    #if canImport(Darwin)
    return Darwin.sqrt(x)
    #else
    return Glibc.sqrt(x)
    #endif
}
