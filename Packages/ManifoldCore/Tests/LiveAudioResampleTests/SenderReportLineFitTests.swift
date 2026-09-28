//
//  SenderReportLineFitTests.swift
//  LiveAudioResampleTests
//
//  Build step 4e-2 of docs/AUDIO_RESAMPLER_DESIGN.md §7: the WHEP SR line (§2.6).
//
//  ⚠️ THE SENDER IS SYNTHESISED FROM CLOCKS, NOT FROM Δ. Each test builds the SRs a real sender
//  would emit — a video RTP clock at (1 + ε_v) and an audio RTP clock at (1 + ε_a) against one NTP
//  clock, 32-bit wrapping timestamps, random origins — and feeds them through the same entry point
//  the bridge uses. So the Δ arithmetic, the unwrap and the pairing are under test too, and the truth
//  every assertion compares against is the physical one: the audio PTS captured at the same NTP
//  instant as the video PTS being shown.
//

import XCTest
@testable import LiveAudioResample

/// Deterministic noise: SplitMix64 and Box–Muller.
struct TestRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func count(containing s: String) -> Int { all.filter { $0.contains(s) }.count }
}

/// One sender: an NTP clock, and two RTP clocks running at (1 + ε) against it.
struct SyntheticSender {
    var epsV = 0.0
    var epsA = 0.0
    /// NTP seconds of the session start (an integer, so the 32.32 value is exact).
    var ntpStart: UInt64 = 3_900_000_000
    /// NTP instants (s after start) of the first video access unit and the first audio packet.
    var nv0 = 0.100
    var na0 = 0.112
    var tv0: UInt32 = 0x1234_5678
    var ta0: UInt32 = 0x9ABC_DEF0

    func ntp(_ n: Double) -> UInt64 {
        let whole = n.rounded(.down)
        return ((ntpStart + UInt64(whole)) << 32) + UInt64(((n - whole) * 4_294_967_296).rounded())
    }
    func videoRTP(_ n: Double) -> UInt32 {
        tv0 &+ UInt32(truncatingIfNeeded: Int64((90_000 * (1 + epsV) * (n - nv0)).rounded()))
    }
    func audioRTP(_ n: Double) -> UInt32 {
        ta0 &+ UInt32(truncatingIfNeeded: Int64((48_000 * (1 + epsA) * (n - na0)).rounded()))
    }
    /// Video content time at NTP instant n.
    func videoPTS(_ n: Double) -> Double { (1 + epsV) * (n - nv0) }
    /// The audio PTS captured at the same NTP instant as video PTS p — what lip-sync needs.
    func audioPTS(withVideoPTS p: Double) -> Double { (1 + epsA) * (p / (1 + epsV) + nv0 - na0) }
    /// Δ at video PTS p: the offset the fit should report.
    func trueOffset(atVideoPTS p: Double) -> Double { p - audioPTS(withVideoPTS: p) }
    /// dΔ/dp.
    var trueSlope: Double { 1 - (1 + epsA) / (1 + epsV) }
}

final class SenderReportLineFitTests: XCTestCase {

    typealias Fit = SenderReportLineFit

    func makeFit(_ sink: LogSink = LogSink()) -> Fit {
        Fit.make(timeline: .rtpSenderReports, tag: "[TEST-SRFIT]", reportsWindows: true,
                 log: { sink.append($0) })!
    }

    /// Feed SRs at 1 per second per stream (Cloudflare and MediaMTX both measured 1.0/s) from NTP
    /// second `from` to `to`. `deltaNoise(n)` is added to the AUDIO SR's NTP field, which moves Δ by
    /// exactly that amount. `drop(stream, n)` loses an SR.
    func feed(_ fit: Fit, _ s: SyntheticSender, from: Double, to: Double, step: Double = 1.0,
              deltaNoise: (Double) -> Double = { _ in 0 },
              drop: (Fit.Stream, Double) -> Bool = { _, _ in false },
              each: ((Double) -> Void)? = nil) {
        var n = from
        while n < to {
            if !drop(.video, n) {
                fit.noteSenderReport(.video, ntp: s.ntp(n), rtp: s.videoRTP(n),
                                     audioOrigin: s.ta0, videoOrigin: s.tv0)
            }
            let na = n + 0.004
            if !drop(.audio, n) {
                fit.noteSenderReport(.audio, ntp: s.ntp(na + deltaNoise(n)), rtp: s.audioRTP(na),
                                     audioOrigin: s.ta0, videoOrigin: s.tv0)
            }
            each?(n)
            n += step
        }
    }

    // MARK: - The fit

    func testWhiteNoiseSlopeAndOffset() {
        var s = SyntheticSender(); s.epsV = 69e-6
        var rng = TestRNG(state: 1)
        let fit = makeFit()
        feed(fit, s, from: 1, to: 601, deltaNoise: { _ in 0.0004 * rng.gaussian() })
        let snap = fit.snapshot
        XCTAssertTrue(snap.slopeInUse)
        XCTAssertEqual(snap.slopeFit, s.trueSlope, accuracy: max(3 * snap.slopeSE, 1e-6))
        XCTAssertEqual(snap.rejected, 0)
        let p = s.videoPTS(600)
        XCTAssertEqual(fit.evaluate(atVideoTime: p)!.offset, s.trueOffset(atVideoPTS: p), accuracy: 0.0003)
        // White residuals: the batch-means inflation stays near 1 and the SE near σ√12/W^1.5.
        XCTAssertLessThan(snap.inflation, 1.4)
        XCTAssertEqual(snap.slopeSE, 0.0004 * 12.0.squareRoot() / pow(600, 1.5), accuracy: 0.2e-6)
        // A clean sender qualifies its slope within the first few batches, not at 300 s.
        XCTAssertLessThan(snap.slopeFirstInUseAt ?? .infinity, 130)
    }

    /// Cloudflare as measured (§2.6): ~9.5 ms per-pair sd, plus a ~2 ms wander that does not average
    /// down past 60 s.
    func testCloudflareLikeNoiseWithWander() {
        var s = SyntheticSender(); s.epsV = 69e-6
        var rng = TestRNG(state: 7)
        var wander = 0.0
        let a = exp(-1.0 / 60)                   // AR(1), τ = 60 s, stationary sd 2 ms
        let fit = makeFit()
        var maxErrLate = 0.0
        var whiteSE = 0.0
        feed(fit, s, from: 1, to: 1801, deltaNoise: { _ in
            wander = a * wander + (1 - a * a).squareRoot() * 0.002 * rng.gaussian()
            return wander + 0.0095 * rng.gaussian()
        }, each: { n in
            if n > 900, let e = fit.evaluate(atVideoTime: s.videoPTS(n)) {
                maxErrLate = max(maxErrLate, abs(e.offset - s.trueOffset(atVideoPTS: s.videoPTS(n))))
            }
            if n == 1800 {
                let snap = fit.snapshot
                whiteSE = snap.residualSD * 12.0.squareRoot() / pow(600, 1.5)
            }
        })
        let snap = fit.snapshot
        XCTAssertTrue(snap.slopeInUse)
        XCTAssertLessThan(snap.slopeFirstInUseAt!, 600, "a 9.5 ms sender reaches 10 ppm inside 600 s")
        XCTAssertEqual(snap.slopeFit, s.trueSlope, accuracy: 10e-6)
        XCTAssertGreaterThanOrEqual(snap.slopeSE, whiteSE * 0.999, "never claims better than white")
        XCTAssertLessThanOrEqual(snap.rejected, 2)
        XCTAssertEqual(snap.unstableEpisodes, 0)
        XCTAssertEqual(snap.steps, 0)
        // The offset follows Δ to within the wander (2 ms sd) and the 60 s mean's noise
        // (9.5/√60 = 1.2 ms): combined sd 2.3 ms, bounded here at 3.5σ over 900 evaluations.
        XCTAssertLessThan(maxErrLate, 0.008)
        // ⚠️ THE NUMBER THE LOOP SEES: once past the first 60 s, no single update moves the target by
        // more than a few ms — far below the steering's 50 ms step trigger.
        XCTAssertLessThan(snap.maxOffsetStepSteady, 0.005)
        XCTAssertLessThan(snap.maxOffsetStep, 0.025)
    }

    func testOutliersRejectedAndCounted() {
        var s = SyntheticSender(); s.epsV = 69e-6
        var rng = TestRNG(state: 3)
        let outlierAt: Set<Int> = [40, 75, 130, 170, 222, 260, 301, 350, 400, 480]
        let fit = makeFit()
        feed(fit, s, from: 1, to: 601, deltaNoise: { n in
            (outlierAt.contains(Int(n)) ? 0.200 : 0) + 0.0004 * rng.gaussian()
        })
        let snap = fit.snapshot
        XCTAssertEqual(snap.rejected, outlierAt.count)
        XCTAssertEqual(snap.unstableEpisodes, 0)
        XCTAssertEqual(snap.steps, 0)
        XCTAssertEqual(snap.slopeFit, s.trueSlope, accuracy: 1e-6)
        XCTAssertEqual(snap.state, .tracking)
    }

    // MARK: - SR loss, gaps, wrap

    func testRandomSRLossStillFits() {
        var s = SyntheticSender(); s.epsV = 69e-6
        var rng = TestRNG(state: 11)
        var noise = TestRNG(state: 12)
        let fit = makeFit()
        feed(fit, s, from: 1, to: 601, deltaNoise: { _ in 0.0004 * noise.gaussian() },
             drop: { _, _ in rng.uniform() < 0.3 })
        let snap = fit.snapshot
        XCTAssertGreaterThan(snap.pairs, 200)
        XCTAssertTrue(snap.slopeInUse)
        XCTAssertEqual(snap.slopeFit, s.trueSlope, accuracy: 2e-6)
        XCTAssertEqual(snap.gaps, 0)
    }

    func testVideoSROutageIsAGapThatHoldsTheLine() {
        var s = SyntheticSender(); s.epsV = 69e-6
        let sink = LogSink()
        let fit = makeFit(sink)
        var worstInGap = 0.0
        feed(fit, s, from: 1, to: 901, drop: { stream, n in stream == .video && n >= 400 && n < 700 },
             each: { n in
                 guard n >= 400, n < 700 else { return }
                 let p = s.videoPTS(n)
                 let e = fit.evaluate(atVideoTime: p)!
                 worstInGap = max(worstInGap, abs(e.offset - s.trueOffset(atVideoPTS: p)))
             })
        let snap = fit.snapshot
        XCTAssertEqual(snap.gaps, 1)
        XCTAssertEqual(sink.count(containing: "SR GAP"), 1)
        XCTAssertEqual(sink.count(containing: "the VIDEO SRs stopped"), 1)
        XCTAssertEqual(sink.count(containing: "RESUMED"), 1)
        // 300 s on the extrapolated line, noise-free: the in-use slope keeps it on Δ.
        XCTAssertLessThan(worstInGap, 0.0001)
    }

    func testRTPTimestampWrapBothStreams() {
        // No clock slope here, on purpose: the slope's own switch-on moves the offset by
        // b × 30 s (2 ms at 69 ppm), which would hide nothing a wrap does but blunts the bound. A wrap
        // bug moves it by 2³²/90000 = 47,722 s or 2³²/48000 = 89,478 s.
        var s = SyntheticSender()
        // Both counters wrap within the first minute.
        s.tv0 = UInt32.max - 90_000 * 20
        s.ta0 = UInt32.max - 48_000 * 35
        let fit = makeFit()
        var worst = 0.0
        feed(fit, s, from: 1, to: 301, each: { n in
            let p = s.videoPTS(n)
            if let e = fit.evaluate(atVideoTime: p) {
                worst = max(worst, abs(e.offset - s.trueOffset(atVideoPTS: p)))
            }
        })
        // Only RTP tick quantisation (≤ 1/90000 + 1/48000 s) remains.
        XCTAssertLessThan(worst, 0.00005, "no discontinuity across either wrap")
        XCTAssertEqual(fit.snapshot.rejected, 0)
        XCTAssertEqual(fit.snapshot.steps, 0)
    }

    /// Longer than 2³¹ video ticks (6.6 h): a signed 32-bit difference from the origin would flip
    /// sign here. The extended unwrap does not.
    func testSessionLongerThanHalfTheVideoCounter() {
        var s = SyntheticSender(); s.epsV = 69e-6
        let fit = makeFit()
        feed(fit, s, from: 1, to: 7 * 3600, step: 10)
        let p = s.videoPTS(7 * 3600 - 10)
        XCTAssertGreaterThan(p * 90_000, Double(Int32.max))
        XCTAssertEqual(fit.evaluate(atVideoTime: p)!.offset, s.trueOffset(atVideoPTS: p), accuracy: 0.0001)
        XCTAssertEqual(fit.snapshot.rejected, 0)
    }

    // MARK: - The sign

    /// +69 ppm of Δ slope (the video clock 69 ppm fast of the audio clock, as on the Cloudflare run)
    /// must give ZERO drift of the audio content the target asks for against the audio that truly
    /// belongs with the picture.
    ///
    /// ⚠️ TESTED WHERE THE SLOPE IS THE ONLY THING HOLDING THE LINE. While pairs keep arriving, the
    /// offset is re-levelled every second, so even the wrong sign would only saw-tooth by
    /// 138 ppm × 1 s. So the line is frozen — one reference line, extended 600 s with no update, and a
    /// 600 s SR outage under 10 Hz mapping updates — and the wrong sign is shown to fail by ~83 ms.
    func testPlus69ppmSlopeGivesZeroAudioVideoDrift() {
        var s = SyntheticSender(); s.epsV = 69e-6; s.epsA = 0
        XCTAssertEqual(s.trueSlope, 69e-6, accuracy: 0.01e-6)
        let fit = makeFit()
        feed(fit, s, from: 1, to: 901)
        XCTAssertTrue(fit.snapshot.slopeInUse)
        XCTAssertEqual(fit.snapshot.slopeFit, 69e-6, accuracy: 0.1e-6)

        // The mapping: the picture shows video PTS S at host H, advancing at r (LiveClock's rate,
        // here the video clock against the host: 1 + ε_v with NTP as the host clock).
        let r = 1 + s.epsV
        let h0 = 900.0
        let S = s.videoPTS(h0)
        let e = fit.evaluate(atVideoTime: S)!
        let line = Fit.reference(videoMedia: S, rate: r, offset: e.offset, slope: e.slope)
        let wrong = (media: line.media, rate: r * (1 + e.slope))

        var worst = 0.0, worstWrong = 0.0
        for k in 0...600 {
            let t = h0 + Double(k)
            let shown = S + (t - h0) * r                         // video PTS on screen
            let belongs = s.audioPTS(withVideoPTS: shown)        // the audio that goes with it
            worst = max(worst, abs(line.media + (t - h0) * line.rate - belongs))
            worstWrong = max(worstWrong, abs(wrong.media + (t - h0) * wrong.rate - belongs))
        }
        XCTAssertLessThan(worst, 0.00002, "zero drift over 600 s on one frozen line")
        XCTAssertGreaterThan(worstWrong, 0.080, "the opposite sign drifts 138 ppm × 600 s")

        // The same through a 600 s SR outage, with the mapping re-stated at 10 Hz as the mirror does.
        var worstGap = 0.0
        for k in 0...6000 {
            let t = h0 + Double(k) * 0.1
            let m = S + (t - h0) * r
            let ev = fit.evaluate(atVideoTime: m)!
            let ref = Fit.reference(videoMedia: m, rate: r, offset: ev.offset, slope: ev.slope)
            let later = ref.media + 0.05 * ref.rate              // between two mapping updates
            worstGap = max(worstGap, abs(later - s.audioPTS(withVideoPTS: m + 0.05 * r)))
        }
        XCTAssertLessThan(worstGap, 0.00002)
    }

    // MARK: - Into the loop

    /// The fit's line as the steering's target, against the real steering and step 4d's plant, for
    /// 30 minutes of Cloudflare-like SR noise (9.5 ms white + 2 ms wander) on §13.3's clocks: video
    /// RTP +67 ppm and audio RTP −2 ppm against the host, device +6.5 ppm.
    ///
    ///   * offset updates reach the loop as ERROR: one write in the session, the first anchor;
    ///   * the integrator settles on δd − ε_a = +8.5 ppm (it settled on δd − δv ≈ −60 before 4e,
    ///     §13.3 — the video clock, because the target was the video line);
    ///   * the heard audio against the audio that belongs with the picture has no trend.
    func testFitDrivenTargetIsErrorNotWritesAndNullsTheLipSyncDrift() {
        var snd = SyntheticSender(); snd.epsV = 67e-6; snd.epsA = -2e-6
        let plant = SimPlant(); plant.device = 6.5e-6
        let steer = LiveAudioResampleSteering(
            tag: "[TEST-STEER]", mode: .loop, clock: plant, gains: .adopted, thresholds: .adopted,
            reportsWindows: false, readTimebase: { plant.timebase }, hostNow: { plant.host },
            write: { o, h, why in plant.write(o, h, why) }, log: nil)
        let fit = makeFit()
        var rng = TestRNG(state: 21)
        var wander = 0.0
        let a = exp(-1.0 / 60)
        let r = 1 + snd.epsV                                     // the mapping's rate
        var anchored = false
        var nextSR = 1.0, nextRef = 1.0
        var lip: [(t: Double, e: Double)] = []
        var iTail: [Double] = []
        var t = 1.0
        while t < 1801 {
            plant.host = t
            if t >= nextSR {
                let n = nextSR
                wander = a * wander + (1 - a * a).squareRoot() * 0.002 * rng.gaussian()
                let noise = wander + 0.0095 * rng.gaussian()
                fit.noteSenderReport(.video, ntp: snd.ntp(n), rtp: snd.videoRTP(n),
                                     audioOrigin: snd.ta0, videoOrigin: snd.tv0)
                fit.noteSenderReport(.audio, ntp: snd.ntp(n + 0.004 + noise),
                                     rtp: snd.audioRTP(n + 0.004),
                                     audioOrigin: snd.ta0, videoOrigin: snd.tv0)
                nextSR += 1
            }
            if t >= nextRef {
                // The mirror: the mapping, the fit at its senderPTS, the reference line.
                let sPTS = snd.videoPTS(t)
                let e = fit.evaluate(atVideoTime: sPTS)
                let ref = Fit.reference(videoMedia: sPTS, rate: r, offset: e?.offset ?? 0,
                                        slope: e?.slope ?? 0)
                if !anchored {
                    steer.anchor(media: ref.media, host: t, rate: ref.rate); anchored = true
                } else {
                    steer.setReference(media: ref.media, host: t, rate: ref.rate)
                }
                nextRef += 0.1
            }
            steer.sample()
            if t > 600, Int(t * 50) % 50 == 0 {
                let heard = plant.inputTime(atOutputTime: plant.timebase)
                lip.append((t, heard - snd.audioPTS(withVideoPTS: snd.videoPTS(t))))
                iTail.append(steer.totals.integral)
            }
            t += 0.02
        }
        let totals = steer.totals
        XCTAssertEqual(plant.writes, [.firstAnchor], "offset updates are error, never writes")
        XCTAssertEqual(totals.coarseStep + totals.coarseLevel, 0)
        let iMean = iTail.reduce(0, +) / Double(iTail.count)
        XCTAssertEqual(iMean * 1e6, (plant.device - snd.epsA) * 1e6, accuracy: 3,
                       "i settles on δd − ε_a, not on δd − δv")
        // Lip-sync over the last 20 minutes: a least-squares trend indistinguishable from zero at the
        // fit's own precision, and bounded by the SR noise the offset window leaves (§5.3: ±15 ms).
        let n = Double(lip.count)
        let mt = lip.map(\.t).reduce(0, +) / n, me = lip.map(\.e).reduce(0, +) / n
        let slope = lip.map { ($0.t - mt) * ($0.e - me) }.reduce(0, +)
            / lip.map { ($0.t - mt) * ($0.t - mt) }.reduce(0, +)
        XCTAssertLessThan(abs(slope), 3e-6, "no lip-sync trend: before 4e it was ~69 ppm")
        XCTAssertLessThan(lip.map { abs($0.e) }.max()!, 0.010)
        print(String(format: "[4e-2] 30 min, CF-like SR noise: writes %d, i %+.2f ppm (δd − ε_a %+.1f), "
                     + "lip-sync trend %+.2f ppm, max |lip| %.2f ms, fitted b %+.2f ppm",
                     totals.writes, iMean * 1e6, (plant.device - snd.epsA) * 1e6, slope * 1e6,
                     lip.map { abs($0.e) }.max()! * 1e3, fit.snapshot.slopeFit * 1e6))
    }

    // MARK: - Startup and fallbacks

    func testNoSenderReportsNoLine() {
        let fit = makeFit()
        XCTAssertNil(fit.evaluate(atVideoTime: 10))
        XCTAssertTrue(fit.missingForFirstPair.contains("EITHER"))
    }

    func testOnlyAudioSRsNamesTheVideoStream() {
        let s = SyntheticSender()
        let fit = makeFit()
        feed(fit, s, from: 1, to: 6, drop: { stream, _ in stream == .video })
        XCTAssertNil(fit.evaluate(atVideoTime: 5))
        XCTAssertTrue(fit.missingForFirstPair.contains("NO VIDEO"), fit.missingForFirstPair)
    }

    /// MediaMTX sends its first SRs before the first media arrives (§12.2): an SR taken before its
    /// origin is known must still pair once the origin arrives, and the first line fires once.
    func testFirstPairFromSRsThatPrecedeTheOrigins() {
        let s = SyntheticSender()
        let fit = makeFit()
        let fired = LogSink()
        fit.onFirstLine = { fired.append("first") }
        fit.noteSenderReport(.audio, ntp: s.ntp(0.05), rtp: s.audioRTP(0.05),
                             audioOrigin: nil, videoOrigin: nil)
        fit.noteSenderReport(.video, ntp: s.ntp(0.06), rtp: s.videoRTP(0.06),
                             audioOrigin: nil, videoOrigin: nil)
        XCTAssertNil(fit.evaluate(atVideoTime: 0))
        XCTAssertTrue(fit.missingForFirstPair.contains("not received yet"))
        // The next SR carries both origins: the stored video SR is unwrapped and pairs with it.
        fit.noteSenderReport(.audio, ntp: s.ntp(1.05), rtp: s.audioRTP(1.05),
                             audioOrigin: s.ta0, videoOrigin: s.tv0)
        let e = fit.evaluate(atVideoTime: s.videoPTS(0.06))
        XCTAssertNotNil(e)
        XCTAssertEqual(e!.offset, s.trueOffset(atVideoPTS: s.videoPTS(0.06)), accuracy: 0.0001)
        feed(fit, s, from: 2, to: 10)
        XCTAssertEqual(fired.all.count, 1)
    }

    func testStepInDeltaRestartsTheFit() {
        var s = SyntheticSender(); s.epsV = 69e-6
        var rng = TestRNG(state: 5)
        let sink = LogSink()
        let fit = makeFit(sink)
        feed(fit, s, from: 1, to: 601, deltaNoise: { n in
            (n >= 300 ? 0.080 : 0) + 0.0004 * rng.gaussian()
        })
        let snap = fit.snapshot
        XCTAssertEqual(snap.steps, 1)
        XCTAssertEqual(snap.unstableEpisodes, 0)
        XCTAssertEqual(sink.count(containing: "Δ STEPPED"), 1)
        let p = s.videoPTS(600)
        XCTAssertEqual(fit.evaluate(atVideoTime: p)!.offset, s.trueOffset(atVideoPTS: p) + 0.080,
                       accuracy: 0.0005)
        XCTAssertTrue(snap.slopeInUse, "re-qualified on the new level")
    }

    func testNoiseBurstHoldsTheLastGoodLine() {
        var s = SyntheticSender(); s.epsV = 69e-6
        var rng = TestRNG(state: 9)
        let sink = LogSink()
        let fit = makeFit(sink)
        var worstHeld = 0.0
        var sawHolding = false
        feed(fit, s, from: 1, to: 601, deltaNoise: { n in
            (n >= 300 && n < 420 ? 0.100 : 0.0004) * rng.gaussian()
        }, each: { n in
            guard n >= 310, n < 420 else { return }
            let p = s.videoPTS(n)
            let e = fit.evaluate(atVideoTime: p)!
            if case .holding = e.state { sawHolding = true }
            worstHeld = max(worstHeld, abs(e.offset - s.trueOffset(atVideoPTS: p)))
        })
        XCTAssertTrue(sawHolding)
        XCTAssertLessThan(worstHeld, 0.001, "the held line, extrapolated on its slope")
        XCTAssertGreaterThanOrEqual(sink.count(containing: "FIT UNSTABLE"), 1)
        XCTAssertGreaterThanOrEqual(sink.count(containing: "LAST GOOD LINE"), 1)
        XCTAssertGreaterThanOrEqual(sink.count(containing: "STABLE again"), 1)
        XCTAssertEqual(fit.snapshot.state, .tracking)
    }

    func testUnstableFromTheStartFallsBackToZero() {
        let s = SyntheticSender()
        var rng = TestRNG(state: 13)
        let sink = LogSink()
        let fit = makeFit(sink)
        feed(fit, s, from: 1, to: 31, deltaNoise: { _ in 0.100 * rng.gaussian() })
        let e = fit.evaluate(atVideoTime: s.videoPTS(30))!
        guard case .holding = e.state else { return XCTFail("expected holding, got \(e.state)") }
        XCTAssertEqual(e.offset, 0)
        XCTAssertEqual(e.slope, 0)
        XCTAssertEqual(sink.count(containing: "falling back to offset 0"), 1)
    }

    func testDifferentCNAMEsLoggedOnceAndApplied() {
        let s = SyntheticSender()
        let sink = LogSink()
        let fit = makeFit(sink)
        fit.noteSDPCNAMEs(audio: "PxgkpBsC", video: "CfFlPcUE")
        fit.noteSDPCNAMEs(audio: "PxgkpBsC", video: "CfFlPcUE")
        feed(fit, s, from: 1, to: 20)
        XCTAssertEqual(sink.count(containing: "CNAMEs DIFFER"), 1)
        XCTAssertEqual(sink.count(containing: "CNAME"), 1)
        XCTAssertNotNil(fit.evaluate(atVideoTime: s.videoPTS(19)))
    }

    func testSDPCNAMEParse() {
        let sdp = """
        v=0\r
        m=audio 9 UDP/TLS/RTP/SAVPF 111\r
        a=ssrc:1160771747 cname:PxgkpBsC\r
        a=ssrc:1160771747 msid:a b\r
        m=video 9 UDP/TLS/RTP/SAVPF 96\r
        a=ssrc:4197164732 cname:CfFlPcUE\r
        """
        let names = Fit.sdpCNAMEs(sdp)
        XCTAssertEqual(names.audio, "PxgkpBsC")
        XCTAssertEqual(names.video, "CfFlPcUE")
        XCTAssertNil(Fit.sdpCNAMEs("v=0\r\nm=audio 9 x 111\r\n").audio)
    }

    // MARK: - Absent on the other transports

    func testAbsentWhereAudioAndVideoShareATimeline() {
        for why in ["MPEG-TS over SRT: one program clock", "NDI: one host clock",
                    "HLS: AVPlayer, one media timeline"] {
            XCTAssertNil(Fit.make(timeline: .oneTimeline(why), tag: "[X]", reportsWindows: true,
                                  log: nil), why)
            let line = Fit.sessionLine(tag: "[X-SRFIT]", timeline: .oneTimeline(why))
            XCTAssertTrue(line.contains("NO SR line fit exists"), line)
            XCTAssertTrue(line.contains(why))
        }
        XCTAssertNotNil(Fit.make(timeline: .rtpSenderReports, tag: "[X]", reportsWindows: true, log: nil))
        XCTAssertTrue(Fit.sessionLine(tag: "[X]", timeline: .rtpSenderReports).contains("ACTIVE"))
    }

    // MARK: - Logging

    func testWindowAndSummaryLines() {
        var s = SyntheticSender(); s.epsV = 69e-6
        let sink = LogSink()
        let fit = makeFit(sink)
        feed(fit, s, from: 1, to: 200)
        let w = fit.windowLine()!
        for field in ["offset", "slope", "SE", "residual sd", "N ", "rejected", "IN USE"] {
            XCTAssertTrue(w.contains(field), "\(field) missing from: \(w)")
        }
        fit.finish()
        XCTAssertEqual(sink.count(containing: "session END"), 1)
        let quiet = Fit.make(timeline: .rtpSenderReports, tag: "[Q]", reportsWindows: false, log: nil)!
        XCTAssertNil(quiet.windowLine())
    }
}
