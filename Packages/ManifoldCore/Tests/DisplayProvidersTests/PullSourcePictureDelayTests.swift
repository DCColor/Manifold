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
}
