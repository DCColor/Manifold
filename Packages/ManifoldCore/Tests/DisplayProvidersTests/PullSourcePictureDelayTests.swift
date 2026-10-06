import XCTest
@testable import DisplayProviders

/// A buffer or frame stamped `t` on NDI's pull clock:
///  - audio is due when the timebase reaches `t`; the timebase is anchored `lead` behind the pull
///    clock, so it is heard at `t + lead`;
///  - the picture is due when the renderer's clock, `pull − delay`, reaches `t`: shown at `t + delay`.
/// So audio minus picture is `lead − delay`, and the audio queue is `lead` in every case.
private func avOffset(lead: Double, delay: Double) -> Double { lead - delay }

final class PullSourcePictureDelayTests: XCTestCase {

    /// §2.5 on NDI: while the desktop plays the programme, the queue is not an A/V offset.
    func testDesktopAudioHoldsThePictureByTheLead() {
        let d = PullSourcePictureDelay.seconds(desktopAudioLead: 0.250, cardOwnsAudio: false)
        XCTAssertEqual(d, 0.250)
        XCTAssertEqual(avOffset(lead: 0.250, delay: d), 0, accuracy: 1e-12)
    }

    /// Before the fix the picture was never held: audio 250 ms late, the measured +252…+262 ms.
    func testTheDefectWasTheWholeLead() {
        XCTAssertEqual(avOffset(lead: 0.250, delay: 0), 0.250, accuracy: 1e-12)
    }

    /// SDI unchanged: with the card owning audio the picture is not held at all.
    func testCardOwningAudioHoldsNothing() {
        XCTAssertEqual(PullSourcePictureDelay.seconds(desktopAudioLead: 0.250, cardOwnsAudio: true), 0)
        XCTAssertEqual(PullSourcePictureDelay.seconds(desktopAudioLead: 0.600, cardOwnsAudio: true), 0)
    }

    /// The Debug lead ladder moves the picture with the audio at every rung.
    func testEveryLadderRungIsInSync() {
        for lead in [0.040, 0.150, 0.250, 0.300, 0.400, 0.600] {
            let d = PullSourcePictureDelay.seconds(desktopAudioLead: lead, cardOwnsAudio: false)
            XCTAssertEqual(avOffset(lead: lead, delay: d), 0, accuracy: 1e-12, "lead \(lead)")
        }
    }

    func testNonsenseLeadHoldsNothing() {
        XCTAssertEqual(PullSourcePictureDelay.seconds(desktopAudioLead: 0, cardOwnsAudio: false), 0)
        XCTAssertEqual(PullSourcePictureDelay.seconds(desktopAudioLead: -1, cardOwnsAudio: false), 0)
        XCTAssertEqual(PullSourcePictureDelay.seconds(desktopAudioLead: .nan, cardOwnsAudio: false), 0)
    }

    /// The queue must hold the whole delay at the fastest rate it is sized for, or drop-oldest
    /// takes the delay back.
    func testQueueBoundHoldsTheDelay() {
        let floor = 12
        XCTAssertEqual(PullSourcePictureDelay.queueBound(delay: 0, floor: floor), floor)
        for delay in [0.040, 0.150, 0.250, 0.600] {
            let bound = PullSourcePictureDelay.queueBound(delay: delay, floor: floor)
            for fps in [23.976, 25, 30, 50, 59.94, 60, 120] {
                let needed = Int((delay * fps).rounded(.up))
                XCTAssertGreaterThanOrEqual(bound, needed + 1, "delay \(delay) at \(fps) fps")
            }
            XCTAssertGreaterThanOrEqual(bound, floor)
        }
        // 250 ms at up to 120 fps: 30 frames + 4.
        XCTAssertEqual(PullSourcePictureDelay.queueBound(delay: 0.250, floor: floor), 34)
    }

    // MARK: - FrameSync audio depth

    /// Pulled audio is the OLDEST in FrameSync's queue, so it is `depth` older than its stamp; the
    /// picture is held that much more and the offset is zero again.
    func testDepthIsAddedToTheHoldAndNullsTheOffset() {
        let d = PullSourcePictureDelay.seconds(desktopAudioLead: 0.250, frameSyncAudioDepth: 0.0466,
                                               cardOwnsAudio: false)
        XCTAssertEqual(d, 0.2966, accuracy: 1e-12)
        // audio heard lead + depth after its content; picture shown `d` after its content
        XCTAssertEqual((0.250 + 0.0466) - d, 0, accuracy: 1e-12)
    }

    /// SDI unchanged: the card owning audio still holds nothing, depth or not.
    func testCardOwningAudioIgnoresDepth() {
        XCTAssertEqual(PullSourcePictureDelay.seconds(desktopAudioLead: 0.250, frameSyncAudioDepth: 0.04,
                                                      cardOwnsAudio: true), 0)
    }

    func testBadDepthCountsAsNone() {
        for bad in [-0.01, Double.nan, Double.infinity] {
            XCTAssertEqual(PullSourcePictureDelay.seconds(desktopAudioLead: 0.250, frameSyncAudioDepth: bad,
                                                          cardOwnsAudio: false), 0.250)
        }
    }

    /// Feed `seconds` of 10 ms pulls with `depth(t)`; return every published value with its time.
    private func run(_ e: inout AudioQueueDepthEstimate, from t0: Double = 0, seconds: Double,
                     depth: (Double) -> Double) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        var t = t0
        while t < t0 + seconds {
            t += 0.010
            if let v = e.add(depthSeconds: depth(t), interval: 0.010) { out.append((t, v)) }
        }
        return out
    }

    func testConstantDepthPublishesOnceAfterWarmup() {
        var e = AudioQueueDepthEstimate()
        let pubs = run(&e, seconds: 60) { _ in 0.036 }
        XCTAssertEqual(pubs.count, 1)
        XCTAssertEqual(pubs[0].0, 1.0, accuracy: 0.011)
        XCTAssertEqual(pubs[0].1, 0.036, accuracy: 1e-9)
    }

    /// The measured shape: a sawtooth between ~700 and ~2800 samples as packets land. The picture
    /// must follow its mean, not its teeth, and move rarely.
    func testSawtoothPublishesItsMeanAndRarely() {
        var e = AudioQueueDepthEstimate()
        let lo = 700.0 / 48000, hi = 2800.0 / 48000, period = 0.0417
        let pubs = run(&e, seconds: 120) { t in
            let phase = t.truncatingRemainder(dividingBy: period) / period
            return hi - (hi - lo) * phase
        }
        XCTAssertEqual(e.mean!, (lo + hi) / 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(pubs.count, 3, "\(pubs)")
        XCTAssertEqual(pubs.last!.1, (lo + hi) / 2, accuracy: 0.0025)
    }

    /// A shift in FrameSync's level (the 28 → 47 ms seen across connections) is followed within a
    /// few τ, in steps of at least the hysteresis.
    func testLevelShiftIsFollowedInHysteresisSteps() {
        var e = AudioQueueDepthEstimate()
        _ = run(&e, seconds: 30) { _ in 0.028 }
        let pubs = run(&e, from: 30, seconds: 60) { _ in 0.047 }
        XCTAssertEqual(e.published!, 0.047, accuracy: AudioQueueDepthEstimate.hysteresis)
        var last = 0.028
        for (_, v) in pubs {
            XCTAssertGreaterThanOrEqual(abs(v - last), AudioQueueDepthEstimate.hysteresis - 1e-12)
            last = v
        }
        let settled = pubs.first { abs($0.1 - 0.047) < AudioQueueDepthEstimate.hysteresis }!.0
        XCTAssertLessThan(settled - 30, 3 * AudioQueueDepthEstimate.tau)
    }

    func testCeilingAndBadInputs() {
        var e = AudioQueueDepthEstimate()
        _ = run(&e, seconds: 2) { _ in 5.0 }                    // absurd reading
        XCTAssertEqual(e.published!, AudioQueueDepthEstimate.ceiling, accuracy: 1e-12)

        var f = AudioQueueDepthEstimate()
        XCTAssertNil(f.add(depthSeconds: .nan, interval: 0.01))
        XCTAssertNil(f.add(depthSeconds: 0.03, interval: 0))
        XCTAssertNil(f.add(depthSeconds: 0.03, interval: 5))    // a stall, not steady state
        XCTAssertNil(f.mean)
    }

    // MARK: - The hold basis: the sender's timecode skew, or the depth (§19.13)

    /// A session as NDIService feeds it: audio pulls every 10 ms (the first sample's stamp and the
    /// sender's timecode for it), video frames at `fps`, each stamped at the next 60 Hz display tick.
    /// Content `c` is stamped `c + audioLag` (audio) and `c + videoLag + tick wait` (video); the
    /// timecodes are `tcA(c)` / `tcV(c)` (nil = undefined). Returns every change with its time.
    private struct Session {
        var audioLag = 0.040, videoLag = 0.004, fps = 24000.0 / 1001
        var tcA: (Double) -> Int64? = { Int64(($0 * 1e7).rounded()) }
        var tcV: (Double) -> Int64? = { Int64(($0 * 1e7).rounded()) }
    }
    @discardableResult
    private func play(_ e: inout PictureHoldBasisEstimate, _ s: Session, from t0: Double = 0,
                      seconds: Double) -> [(Double, PictureHoldBasisEstimate.Basis, Double?)] {
        var out: [(Double, PictureHoldBasisEstimate.Basis, Double?)] = []
        let base = 1000.0                                   // the pull clock is not the content clock
        var nextA = t0, nextV = (t0 * s.fps).rounded(.up) / s.fps
        let tick = 1.0 / 60
        while min(nextA, nextV) < t0 + seconds {
            if nextA <= nextV {
                let c = nextA
                let tc = s.tcA(c) ?? PictureHoldBasisEstimate.undefinedTimecode
                if e.addAudio(stamp: base + c + s.audioLag, timecode: tc, now: base + c + s.audioLag) {
                    out.append((c, e.basis, e.skew))
                }
                nextA += 0.010
            } else {
                let c = nextV
                let arrive = base + c + s.videoLag
                let stamp = (arrive / tick).rounded(.up) * tick   // the display tick that pulls it
                let tc = s.tcV(c) ?? PictureHoldBasisEstimate.undefinedTimecode
                if e.addVideo(stamp: stamp, timecode: tc, now: stamp) { out.append((c, e.basis, e.skew)) }
                nextV += 1 / s.fps
            }
        }
        return out
    }

    /// The expected skew: audio lag minus the video's mean lag (its own plus half a display tick).
    private func expectedSkew(_ s: Session) -> Double { s.audioLag - (s.videoLag + 0.5 / 60) }

    func testTimecodedSenderHoldsByTheSkewAfterWarmup() {
        var e = PictureHoldBasisEstimate()
        let s = Session()
        let changes = play(&e, s, seconds: 60)
        XCTAssertEqual(e.basis, .timecode)
        XCTAssertEqual(e.skew!, expectedSkew(s), accuracy: 0.002)
        // Published once both streams have warmed (1 s each), then only on ≥ 2 ms moves: rarely.
        XCTAssertGreaterThanOrEqual(changes.first!.0, TimecodeOffsetMean.warmup)
        XCTAssertLessThan(changes.first!.0, TimecodeOffsetMean.warmup + 0.1)
        XCTAssertLessThanOrEqual(changes.count, 4, "\(changes)")
        XCTAssertTrue(changes.allSatisfy { $0.1 == .timecode })
    }

    func testUndefinedTimecodesOnEitherStreamKeepTheDepth() {
        for which in ["audio", "video", "both"] {
            var e = PictureHoldBasisEstimate()
            var s = Session()
            if which != "video" { s.tcA = { _ in nil } }
            if which != "audio" { s.tcV = { _ in nil } }
            XCTAssertTrue(play(&e, s, seconds: 30).isEmpty, which)
            XCTAssertEqual(e.basis, .depth, which)
            XCTAssertNil(e.skew, which)
        }
    }

    /// A sender sending timecode 0: video arrives as 0, FrameSync's audio as the block's offset inside
    /// its chunk (measured, §19.13). Neither keeps time, so neither warms: the depth.
    func testConstantTimecodesKeepTheDepth() {
        var e = PictureHoldBasisEstimate()
        var s = Session()
        let chunk = 1001.0 / 24000
        s.tcV = { _ in 0 }
        s.tcA = { c in Int64((c.truncatingRemainder(dividingBy: chunk) * 1e7).rounded()) }
        XCTAssertTrue(play(&e, s, seconds: 30).isEmpty)
        XCTAssertEqual(e.basis, .depth)
        XCTAssertGreaterThan(e.video.restarts, 20)
        XCTAssertGreaterThan(e.audio.restarts, 20)
        // Only one stream constant is enough.
        var f = PictureHoldBasisEstimate()
        var t = Session(); t.tcV = { _ in 0 }
        XCTAssertTrue(play(&f, t, seconds: 30).isEmpty)
        XCTAssertEqual(f.basis, .depth)
    }

    /// Timecodes that stop mid-session (one stream): back to the depth after `staleAfter`, and to the
    /// skew again once they return and re-warm.
    func testTheFallbackIsAutomaticBothWays() {
        var e = PictureHoldBasisEstimate()
        var s = Session()
        play(&e, s, seconds: 20)
        XCTAssertEqual(e.basis, .timecode)
        s.tcV = { _ in nil }
        let off = play(&e, s, from: 20, seconds: 10)
        XCTAssertEqual(off.count, 1)
        XCTAssertEqual(off[0].1, .depth)
        XCTAssertEqual(off[0].0 - 20, PictureHoldBasisEstimate.staleAfter, accuracy: 0.1)
        s.tcV = Session().tcV
        let on = play(&e, s, from: 30, seconds: 10)
        XCTAssertEqual(on.first?.1, .timecode)
        XCTAssertEqual(e.skew!, expectedSkew(s), accuracy: 0.002)
    }

    /// A looped clip whose timecodes restart (both streams jump back 20.02 s): the streams re-warm
    /// and the hold keeps its skew meanwhile: no fall to the depth, no move past the hysteresis.
    func testATimecodeRestartKeepsTheSkew() {
        var e = PictureHoldBasisEstimate()
        let loop = 20.02
        var s = Session()
        s.tcA = { Int64(($0.truncatingRemainder(dividingBy: loop) * 1e7).rounded()) }
        s.tcV = s.tcA
        play(&e, s, seconds: 15)
        let held = e.skew!
        let changes = play(&e, s, from: 15, seconds: 50)
        XCTAssertTrue(changes.allSatisfy { $0.1 == .timecode }, "\(changes)")
        XCTAssertEqual(e.skew!, held, accuracy: PictureHoldBasisEstimate.hysteresis)
        XCTAssertGreaterThanOrEqual(e.audio.restarts, 2)
    }

    /// The skew has the depth's range: never negative, never past the ceiling.
    func testTheSkewIsClampedToTheDepthsRange() {
        var e = PictureHoldBasisEstimate()
        var s = Session(); s.audioLag = 0.0; s.videoLag = 0.050
        play(&e, s, seconds: 10)
        XCTAssertEqual(e.basis, .timecode)
        XCTAssertEqual(e.skew!, 0)
        var f = PictureHoldBasisEstimate()
        var t = Session(); t.audioLag = 1.5
        play(&f, t, seconds: 10)
        XCTAssertEqual(f.skew!, AudioQueueDepthEstimate.ceiling)
    }

    /// The same warm-up and smoothing as the depth: a constant offset is the mean after 1 s.
    func testOffsetMeanWarmsLikeTheDepth() {
        var m = TimecodeOffsetMean()
        var t = 0.0, warmAt: Double?
        XCTAssertFalse(m.add(offset: 5e8 + 0.03, interval: 0))
        while t < 3 {
            t += 0.01
            if m.add(offset: 5e8 + 0.03, interval: 0.01), warmAt == nil { warmAt = t }
        }
        XCTAssertEqual(warmAt!, 1.0, accuracy: 0.011)
        XCTAssertEqual(m.mean!, 5e8 + 0.03, accuracy: 1e-6)
        XCTAssertFalse(m.add(offset: 5e8 + 0.03, interval: 5))       // a stall: skipped
        XCTAssertFalse(m.add(offset: .nan, interval: 0.01))
        XCTAssertFalse(m.add(offset: 5e8 + 0.5, interval: 0.01))     // not keeping time: restart
        XCTAssertNil(m.mean)
        XCTAssertEqual(m.restarts, 1)
    }
}
