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
}
