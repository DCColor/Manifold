//
//  ToneOnsetDetector.swift — SyncCalibration
//
//  Finds the START of each sync-clip tone in a stream of PCM, on the stream's own time axis
//  (docs/AUDIO_RESAMPLER_DESIGN.md §19.2, §19.10). Calibration mode's beep detector: the work behind
//  `AVContentBeepDetector`'s calibration mode, kept here, with no CoreMedia, so `swift test` reaches
//  it.
//
//  ── WHY THE HALF-AMPLITUDE POINT, AND NOT A THRESHOLD ─────────────────────────────────────────
//
//  The `[AV-CONTENT]` probe takes the first sample above 0.05. On the sync clips' 5 ms raised-cosine
//  fade-in that lands ~2.6 ms after the tone starts, and the lag moves with the level: an encoder
//  6 dB quieter moves it by another ~1 ms, and 6 dB more hides the tone entirely. c12 has the same
//  property (+1.708 ms, §19.9 Decisions 1).
//
//  This detector triggers on the 1 kHz tone demodulated over a one-cycle box (cheap, running sums),
//  then measures the RAW capture: I/Q under a 2 ms Hann window per sample (see `analyse` for why not
//  the box), the tone's own plateau, and where the envelope crosses HALF of it. A raised-cosine edge is symmetric about
//  its midpoint, and so is the box, so that crossing is 2.5 ms after the tone starts whatever the
//  level: onset = crossing − 2.5 ms. Measured against verify.py's exact event times in §19.10.
//
//  ── WHAT COUNTS AS A TONE ─────────────────────────────────────────────────────────────────────
//
//  A rise above `trigger` after ≥ 0.3 s below it (the clips' shortest interval is 0.77 s), whose
//  plateau is ≥ 2 × `trigger` and whose half-amplitude width is 4–60 ms (one frame less 5 ms:
//  11.7–36.7 ms on the clips). The −60 dBFS noise floor demodulates to ~0.0002, 20× under the trigger.
//

import Foundation

public struct ToneOnset: Sendable, Equatable {
    /// The tone's start, on the input's time axis (seconds).
    public let time: Double
    /// The plateau's amplitude, linear (the clips: 0.1 = −20 dBFS).
    public let peak: Double
    /// Between the two half-amplitude points: the tone's length less one edge (5 ms).
    public let widthSeconds: Double
}

public final class ToneOnsetDetector {
    /// Demodulated amplitude that starts a capture: −48 dBFS, 28 dB under the clips' tone.
    public let trigger: Double
    public static let quietBeforeOnsetSeconds = 0.3

    private var sampleRate = 0.0
    private var box = 0                         // samples per demodulation box (one 1 kHz cycle)
    private var period = 0                      // samples per whole number of 1 kHz cycles (= sr)
    private var phaseIndex = 0
    private var ringI: [[Double]] = [[], []]
    private var ringQ: [[Double]] = [[], []]
    private var sumI = [0.0, 0.0], sumQ = [0.0, 0.0]
    private var ringPos = 0
    private var filled = 0
    private var quiet = Int.max / 2

    /// The last ~12 ms of raw samples (≤ 2 channels) and their times, so a capture starts before its
    /// trigger: the onset is measured on these, not on the trigger's box.
    private var preT: [Double] = []
    private var preX: [[Float]] = [[], []]
    private var preHead = 0
    private var capT: [Double] = []
    private var capX: [[Float]] = [[], []]
    private var capturing = false
    private var capturePeak = 0.0
    private var capturePeakTime = 0.0
    private var below = 0
    private var usedChannels = 1

    public init(trigger: Double = 0.004) { self.trigger = trigger }

    private func reset(sampleRate sr: Double) {
        sampleRate = sr
        box = max(4, Int((sr / SyncClips.toneFrequency).rounded()))
        period = max(1, Int(sr.rounded()))
        phaseIndex = 0
        ringI = [[Double](repeating: 0, count: box), [Double](repeating: 0, count: box)]
        ringQ = ringI
        sumI = [0, 0]; sumQ = [0, 0]
        ringPos = 0; filled = 0
        quiet = Int.max / 2
        let n = max(8, Int((0.012 * sr).rounded(.up)))
        preT = [Double](repeating: -.infinity, count: n)
        preX = [[Float](repeating: 0, count: n), [Float](repeating: 0, count: n)]
        preHead = 0
        capT = []; capX = [[], []]; capturing = false
    }

    /// Feed interleaved samples. `firstSampleTime` is the first frame's time on the stream's axis.
    /// Returns the tones that ENDED in this call (a tone is reported once its tail is seen).
    public func process(_ samples: UnsafeBufferPointer<Float>, frames: Int, channels: Int,
                        sampleRate sr: Double, firstSampleTime t0: Double) -> [ToneOnset] {
        guard frames > 0, channels > 0, sr > 0, t0.isFinite, samples.count >= frames * channels else { return [] }
        if sr != sampleRate { reset(sampleRate: sr) }
        let used = min(channels, 2)
        if used != usedChannels { usedChannels = used; capturing = false }
        let w = Double(box)
        let centre = Double(box - 1) / 2 / sr
        let omega = 2 * Double.pi * SyncClips.toneFrequency / sr
        let quietNeed = Int(Self.quietBeforeOnsetSeconds * sr)
        var found: [ToneOnset] = []
        for i in 0..<frames {
            let a = omega * Double(phaseIndex)
            phaseIndex += 1
            if phaseIndex == period { phaseIndex = 0 }
            let c = cos(a), s = sin(a)
            var m = 0.0
            for ch in 0..<used {
                let x = Double(samples[i * channels + ch])
                let vi = x * c, vq = x * s
                sumI[ch] += vi - ringI[ch][ringPos]
                sumQ[ch] += vq - ringQ[ch][ringPos]
                ringI[ch][ringPos] = vi
                ringQ[ch][ringPos] = vq
                m += (sumI[ch] * sumI[ch] + sumQ[ch] * sumQ[ch]).squareRoot()
            }
            ringPos += 1
            if ringPos == box {
                ringPos = 0
                // Re-sum once a box so the running sums never accumulate rounding.
                for ch in 0..<used { sumI[ch] = ringI[ch].reduce(0, +); sumQ[ch] = ringQ[ch].reduce(0, +) }
            }
            filled = min(filled + 1, box)
            let ts = t0 + Double(i) / sr
            let x0 = samples[i * channels], x1 = used > 1 ? samples[i * channels + 1] : 0
            guard filled == box else { continue }
            m = m * 2 / w / Double(used)
            let t = ts - centre                 // the box's centre: the trigger's own clock

            if capturing {
                capT.append(ts); capX[0].append(x0); capX[1].append(x1)
                if m > capturePeak { capturePeak = m; capturePeakTime = t }
                below = m < 0.25 * capturePeak ? below + 1 : 0
                let done = (Double(below) / sr >= 0.003 && t - capturePeakTime >= 0.003)
                    || Double(capT.count) / sr > 0.1
                if done {
                    capturing = false
                    if let onset = Self.analyse(times: capT, samples: capX, channels: used, sampleRate: sr,
                                                trigger: trigger) { found.append(onset) }
                }
            } else {
                preT[preHead] = ts; preX[0][preHead] = x0; preX[1][preHead] = x1
                preHead = (preHead + 1) % preT.count
                if m >= trigger && quiet >= quietNeed {
                    capT.removeAll(keepingCapacity: true)
                    capX[0].removeAll(keepingCapacity: true); capX[1].removeAll(keepingCapacity: true)
                    for k in 0..<preT.count {
                        let j = (preHead + k) % preT.count
                        guard preT[j].isFinite else { continue }
                        capT.append(preT[j]); capX[0].append(preX[0][j]); capX[1].append(preX[1][j])
                    }
                    capturing = true
                    capturePeak = m; capturePeakTime = t; below = 0
                }
            }
            quiet = m < trigger ? quiet + 1 : 0
        }
        return found
    }

    /// The tone's envelope on the raw capture, by I/Q demodulation under a 2 ms Hann window centred
    /// on each sample. ⚠️ NOT THE TRIGGER'S ONE-CYCLE BOX: during a ramp the box leaks the 2 kHz
    /// product term, a bias of 65–100 µs that depends on the tone's phase (measured, §19.10). Hann's
    /// spectrum has a zero at 2 kHz for a 2 ms window, and a window half-width (1 ms) under half an
    /// edge (2.5 ms) keeps the half-amplitude point where the edge's symmetry puts it.
    static func analyse(times: [Double], samples: [[Float]], channels: Int, sampleRate sr: Double,
                        trigger: Double) -> ToneOnset? {
        let n = times.count
        let h = max(2, Int((sr / SyncClips.toneFrequency).rounded()))
        guard n > 2 * h + 2 else { return nil }
        let omega = 2 * Double.pi * SyncClips.toneFrequency / sr
        var win = [Double](repeating: 0, count: 2 * h + 1)
        for k in 0...(2 * h) { win[k] = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(2 * h)) }
        let norm = 2 / win.reduce(0, +)
        var xc = [[Double]](repeating: [Double](repeating: 0, count: n), count: channels)
        var xs = xc
        for j in 0..<n {
            let a = omega * Double(j), c = cos(a), s = sin(a)
            for ch in 0..<channels {
                let x = Double(samples[ch][j]); xc[ch][j] = x * c; xs[ch][j] = x * s
            }
        }
        var env: [(Double, Double)] = []
        env.reserveCapacity(n - 2 * h)
        for j in h..<(n - h) {
            var m = 0.0
            for ch in 0..<channels {
                var i = 0.0, q = 0.0
                for k in 0...(2 * h) { i += win[k] * xc[ch][j - h + k]; q += win[k] * xs[ch][j - h + k] }
                m += (i * i + q * q).squareRoot()
            }
            env.append((times[j], m * norm / Double(channels)))
        }
        return halfAmplitudeOnset(env, trigger: trigger)
    }

    /// The half-amplitude crossing on the way up, less half an edge. nil if the capture is not a tone.
    static func halfAmplitudeOnset(_ cap: [(Double, Double)], trigger: Double) -> ToneOnset? {        guard let mx = cap.map({ $0.1 }).max(), mx > 0 else { return nil }
        let plateau = cap.filter { $0.1 >= 0.9 * mx }.map { $0.1 }
        let level = plateau.reduce(0, +) / Double(plateau.count)
        guard level >= 2 * trigger else { return nil }
        let half = level / 2
        guard let up = cap.firstIndex(where: { $0.1 >= half }), up >= 1,
              let down = cap.lastIndex(where: { $0.1 >= half }), down + 1 < cap.count else { return nil }
        func cross(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
            let span = b.1 - a.1
            guard span != 0 else { return a.0 }
            return a.0 + (half - a.1) / span * (b.0 - a.0)
        }
        // The pre-history's oldest entries can be placeholders from before the first sample.
        guard cap[up - 1].0 < cap[up].0 else { return nil }
        let tUp = cross(cap[up - 1], cap[up])
        let tDown = cross(cap[down], cap[down + 1])
        let width = tDown - tUp
        guard width >= 0.004, width <= 0.060 else { return nil }
        return ToneOnset(time: tUp - SyncClips.toneEdgeSeconds / 2, peak: level, widthSeconds: width)
    }
}
