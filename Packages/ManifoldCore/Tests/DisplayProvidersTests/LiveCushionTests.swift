import XCTest
@testable import DisplayProviders

/// Stage 0b-2a's rule (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10): max(default, 1.5 × largest PES +
/// 0.08 s), clamped to 1.0 s, grow-only. The fixture figures are the 0b-1 measurements.
final class LiveCushionTests: XCTestCase {

    private let srt = 0.250

    /// One AAC frame per PES (21.3 ms; the sync fixture, OBS's default): the floor stands.
    func testOneFramePerPESLeavesTheDefault() {
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: 0.0213), srt)
        XCTAssertNil(LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 0.0213))
    }

    /// Programme audio packed ~6 frames (128 ms): 0.272 s, a small raise.
    func testProgrammePackingRaisesSlightly() {
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: 0.128), 0.272, accuracy: 1e-12)
    }

    /// hi8 / hi25: 8 frames, 170.7 ms → 0.336 s. lo150: max 17 frames, 362.7 ms → 0.624 s.
    func testTheFixturesPredictedFigures() {
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: 8 * 1024 / 48_000),
                       0.336, accuracy: 1e-12)
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: 17 * 1024 / 48_000),
                       0.624, accuracy: 1e-12)
    }

    /// The measured floor (cushion − 1.41 × PES on ffmpeg's packing) lands at ~95 ms for hi8 and
    /// stays ≥ ~80 ms wherever the factor governs: the reason for the factor.
    func testTheFloorModelStaysPositive() {
        for frames in 6...29 {
            let pes = Double(frames) * 1024 / 48_000
            let floor = LiveCushion.seconds(transportDefault: srt, largestPES: pes) - 1.41 * pes
            XCTAssertGreaterThan(floor, 0.079, "\(frames) frames")
        }
    }

    /// The break-even: 1.5 × PES + 0.08 = 0.25 at PES 113.3 ms; below it the default stands.
    func testBreakEvenIsTheDefault() {
        XCTAssertNil(LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 0.113))
        XCTAssertNotNil(LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 0.115))
    }

    func testClampedToTheCeiling() {
        XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: 2.0), 1.0)
    }

    /// Grow-only: a smaller PES after a larger one never lowers the cushion.
    func testGrowOnly() {
        let raised = LiveCushion.raise(current: srt, transportDefault: srt, largestPES: 0.3627)
        XCTAssertEqual(raised ?? 0, 0.62405, accuracy: 1e-12)
        XCTAssertNil(LiveCushion.raise(current: raised!, transportDefault: srt, largestPES: 0.1707))
        XCTAssertNil(LiveCushion.raise(current: raised!, transportDefault: srt, largestPES: 0.3627))
    }

    /// Two readings of one packing a hair apart are not a raise.
    func testSubMillisecondIsNotARaise() {
        XCTAssertNil(LiveCushion.raise(current: 0.336, transportDefault: srt, largestPES: 0.17070))
    }

    func testNonsensePESAsksForTheDefault() {
        for pes in [nil, 0, -0.1, .nan, .infinity] as [Double?] {
            XCTAssertEqual(LiveCushion.seconds(transportDefault: srt, largestPES: pes), srt)
        }
    }

    // MARK: The readout line

    func testReadoutAtTheDefault() {
        let r = LiveCushion.Report(transport: "SRT", cushion: 0.250, transportDefault: 0.250, transportLatencyMs: 120)
        XCTAssertEqual(r.text, "250 ms + SRT 120 ms")
    }

    /// The figures print whole, and the raise is their difference: 336 − 250 = 86.
    func testReadoutRaised() {
        let pes = 8.0 * 1024 / 48_000
        let r = LiveCushion.Report(transport: "SRT",
                                   cushion: LiveCushion.seconds(transportDefault: 0.250, largestPES: pes),
                                   transportDefault: 0.250, transportLatencyMs: 120, raisedForPES: pes)
        XCTAssertEqual(r.text, "336 ms + SRT 120 ms — raised 86 ms: the sender packs 171 ms of audio per packet")
    }

    /// WHEP has no transport buffer to state and no raise.
    func testReadoutWithoutTransportLatency() {
        XCTAssertEqual(LiveCushion.Report(transport: "WHEP", cushion: 0.400, transportDefault: 0.400).text, "400 ms")
    }

    /// Before the negotiated latency is known the transport term is left out, not printed as 0.
    func testReadoutBeforeTheLatencyIsKnown() {
        XCTAssertEqual(LiveCushion.Report(transport: "SRT", cushion: 0.250, transportDefault: 0.250).text, "250 ms")
    }
}
